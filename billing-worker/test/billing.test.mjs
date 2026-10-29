// Run with: node --test billing-worker/test
import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker, { verifyWebhook, hasAccess, subscriptionRow, plansConfig, syncExpiry } from "../src/index.js";

const USER = "11111111-2222-4333-8444-555555555555";
const SECRET_BYTES = Buffer.from("bibbles-test-webhook-secret-32b!");
const SECRET = `whsec_${SECRET_BYTES.toString("base64")}`;
const PRODUCT = "pdt_monthly";

const env = {
  DODO_PAYMENTS_API_KEY: "test_key", DODO_WEBHOOK_SECRET: SECRET, DODO_ENV: "test",
  DODO_PRODUCT_ID: PRODUCT, PLAN_NAME: "sigma", FREE_PLAN_NAME: "alpha",
  SUPABASE_URL: "https://proj.supabase.co", SUPABASE_ANON_KEY: "anon", SUPABASE_SERVICE_ROLE_KEY: "service",
};

// ---- in-memory Supabase (PostgREST subset) + Dodo fake --------------------
function fakeBackend() {
  const tables = { subscriptions: [], billing_plan_periods: [], billing_checkouts: [], billing_webhook_events: [],
    profiles: [{ id: USER, plan: "alpha", plan_expires_at: null }] };
  const dodoCalls = [];
  const dodoState = { product: "pdt_sigma", next: new Date(Date.now() + 30 * 86_400_000).toISOString() };
  const keys = { subscriptions: "user_id", billing_checkouts: "session_id", billing_webhook_events: "id" };
  let seq = 0;

  function filters(params) {
    const out = [];
    for (const [k, v] of params) {
      if (["select", "limit", "order", "on_conflict"].includes(k)) continue;
      out.push((row) => {
        if (v.startsWith("eq.")) return String(row[k]) === decodeURIComponent(v.slice(3));
        if (v === "is.null") return row[k] == null;
        if (v === "not.is.null") return row[k] != null;
        throw new Error(`filter ${k}=${v}`);
      });
    }
    return (row) => out.every((f) => f(row));
  }

  async function handler(input, init = {}) {
    const url = new URL(typeof input === "string" ? input : input.url);
    const method = init.method || "GET";
    const body = init.body ? JSON.parse(init.body) : undefined;
    const ok = (data, status = 200) => new Response(data === undefined ? null : JSON.stringify(data), { status });

    if (url.host === "proj.supabase.co" && url.pathname === "/auth/v1/user") {
      return init.headers.Authorization === "Bearer good-token"
        ? ok({ id: USER.toUpperCase(), email: "mo@example.com" }) : ok({ msg: "bad" }, 401);
    }
    if (url.host === "proj.supabase.co" && url.pathname.startsWith("/rest/v1/")) {
      assert.equal(init.headers.apikey, "service");
      assert.equal(init.headers.Authorization, undefined, "sb_secret keys must not be sent as a Bearer token");
      const table = tables[url.pathname.slice(9)];
      const match = filters(url.searchParams);
      if (method === "GET") {
        let rows = table.filter(match);
        const order = url.searchParams.get("order");
        if (order) { const [col, dir] = order.split("."); rows.sort((a, b) => (a[col] > b[col] ? 1 : -1) * (dir === "desc" ? -1 : 1)); }
        const limit = url.searchParams.get("limit");
        return ok(limit ? rows.slice(0, Number(limit)) : rows);
      }
      if (method === "POST") {
        const key = keys[url.pathname.slice(9)];
        const existing = key && table.find((r) => r[key] === body[key]);
        if (existing) {
          if ((init.headers.Prefer || "").includes("merge-duplicates")) Object.assign(existing, body);
        } else table.push({ id: ++seq, created_at: new Date(Date.now() + seq).toISOString(), ...body });
        return new Response(null, { status: 201 });
      }
      if (method === "PATCH") { table.filter(match).forEach((r) => Object.assign(r, body)); return new Response(null, { status: 204 }); }
    }
    if (url.host === "test.dodopayments.com") {
      assert.equal(init.headers.Authorization, "Bearer test_key");
      dodoCalls.push({ method, path: url.pathname + url.search, body });
      if (url.pathname === "/checkouts") return ok({ session_id: "cks_1", checkout_url: "https://checkout.dodopayments.com/session/cks_1" });
      if (url.pathname.endsWith("/customer-portal/session")) return ok({ link: "https://customer.dodopayments.com/portal" });
      if (url.pathname.startsWith("/products/")) {
        const id = url.pathname.split("/")[2];
        const amount = { pdt_sigma: 49900, pdt_omega: 99900, pdt_monthly: 29900 }[id];
        return amount ? ok({ product_id: id, name: id, price: { type: "recurring_price", price: amount, currency: "INR",
          payment_frequency_interval: "Month", payment_frequency_count: 1, tax_inclusive: true } }) : ok({}, 404);
      }
      if (url.pathname.endsWith("/change-plan")) {
        if (dodoState.pending) return ok({ code: "PENDING_PLAN_CHANGE_EXISTS", message: "A pending plan change already exists" }, 409);
        if (dodoState.noLinks && body.collect_via_payment_link) {
          return ok({ code: "PLAN_CHANGE_PAYMENT_LINK_DISABLED", message: "Plan change with a payment link is disabled for this business" }, 422);
        }
        dodoState.product = body.product_id;
        return ok({ payment_id: null, payment_link: null });
      }
      if (method === "PATCH" && url.pathname.startsWith("/subscriptions/")) {
        if (dodoState.patchFails) return ok({ code: "INTERNAL", message: "down" }, 500);
        if (body.status && !dodoState.ignoreCancel) dodoState.status = body.status;
        return ok({});
      }
      if (method === "GET" && url.pathname.startsWith("/subscriptions/")) {
        return ok({ subscription_id: url.pathname.split("/")[2], status: dodoState.status || "active", product_id: dodoState.product,
                    next_billing_date: dodoState.next, customer: { customer_id: "cus_1", email: "mo@example.com", name: "mo" },
                    metadata: {}, created_at: "2026-10-11T00:00:00Z" });
      }
    }
    throw new Error(`unexpected fetch ${method} ${url}`);
  }
  return { tables, dodoCalls, dodoState, handler };
}

function call(path, { method = "GET", token, body, headers = {}, useEnv = env } = {}) {
  const h = { ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  return worker.fetch(new Request(`https://bibbles-billing.example.workers.dev${path}`, { method, headers: h, body }), useEnv, {});
}

function signed(event, id = `msg_${Math.random()}`, ts = Math.floor(Date.now() / 1000)) {
  const raw = JSON.stringify(event);
  const sig = createHmac("sha256", SECRET_BYTES).update(`${id}.${ts}.${raw}`).digest("base64");
  return { body: raw, headers: { "webhook-id": id, "webhook-timestamp": String(ts), "webhook-signature": `v1,${sig}` } };
}

function subEvent(type, data, timestamp = new Date().toISOString()) {
  return {
    business_id: "bus_1", type, timestamp,
    data: {
      payload_type: "Subscription", subscription_id: "sub_1", product_id: PRODUCT,
      customer: { customer_id: "cus_1", email: "mo@example.com", name: "mo" },
      metadata: { bibbles_user_id: USER }, created_at: "2026-10-11T00:00:00Z", ...data,
    },
  };
}

const future = (days) => new Date(Date.now() + days * 86_400_000).toISOString();

let backend;
test.beforeEach(() => { backend = fakeBackend(); globalThis.fetch = backend.handler; });

// ---- tests -----------------------------------------------------------------
test("signature: valid, tampered, stale, and multi-signature headers", async () => {
  const s = signed({ hello: "world" }, "msg_a");
  const h = { id: "msg_a", timestamp: s.headers["webhook-timestamp"], signature: s.headers["webhook-signature"] };
  assert.equal(await verifyWebhook(SECRET, h, s.body), true);
  assert.equal(await verifyWebhook(SECRET, h, s.body.replace("world", "w0rld")), false);
  assert.equal(await verifyWebhook(SECRET, { ...h, signature: `v1,bogus ${h.signature}` }, s.body), true);
  assert.equal(await verifyWebhook(SECRET, h, s.body, Number(h.timestamp) + 600), false);
  assert.equal(await verifyWebhook(SECRET, { ...h, id: "msg_b" }, s.body), false);
});

test("checkout requires sign-in", async () => {
  assert.equal((await call("/v1/billing/checkout", { method: "POST" })).status, 401);
  assert.equal((await call("/v1/billing/checkout", { method: "POST", token: "bad" })).status, 401);
});

test("checkout creates a Dodo session tied to the user, never exposing the key", async () => {
  const res = await call("/v1/billing/checkout", { method: "POST", token: "good-token" });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.checkout_url, "https://checkout.dodopayments.com/session/cks_1");
  assert.ok(!JSON.stringify(out).includes("test_key"));
  const sent = backend.dodoCalls[0].body;
  assert.deepEqual(sent.product_cart, [{ product_id: PRODUCT, quantity: 1 }]);
  assert.equal(sent.customer.email, "mo@example.com");
  assert.equal(sent.metadata.bibbles_user_id, USER);
  assert.equal(sent.return_url, "https://bibbles-billing.example.workers.dev/v1/billing/return");
  assert.equal(backend.tables.billing_checkouts[0].user_id, USER);
});

test("forged webhook is rejected and changes nothing", async () => {
  const s = signed(subEvent("subscription.active", { status: "active", next_billing_date: future(30) }));
  s.headers["webhook-signature"] = "v1,AAAA";
  const res = await call("/v1/webhooks/dodo", { method: "POST", ...s });
  assert.equal(res.status, 401);
  assert.equal(backend.tables.subscriptions.length, 0);
});

test("full lifecycle: activate → status → duplicate → checkout blocked → portal → cancel at period end → expire", async () => {
  const renew = future(30);
  const act = signed(subEvent("subscription.active", { status: "active", next_billing_date: renew }), "msg_act");
  assert.equal((await call("/v1/webhooks/dodo", { method: "POST", ...act })).status, 200);

  let status = await (await call("/v1/billing/status", { token: "good-token" })).json();
  assert.equal(status.plan, "sigma");
  assert.equal(status.has_access, true);
  assert.equal(status.subscription.renews_at, renew);
  assert.equal(status.subscription.access_ends_at, null);
  assert.equal(status.manage_available, true);
  assert.equal(backend.tables.billing_plan_periods.length, 1);

  // Same delivery again: applied once.
  const dup = await (await call("/v1/webhooks/dodo", { method: "POST", ...act })).json();
  assert.equal(dup.duplicate, true);
  assert.equal(backend.tables.billing_plan_periods.length, 1);

  assert.equal((await call("/v1/billing/checkout", { method: "POST", token: "good-token" })).status, 409);

  const portal = await (await call("/v1/billing/portal", { method: "POST", token: "good-token" })).json();
  assert.equal(portal.url, "https://customer.dodopayments.com/portal");
  assert.match(backend.dodoCalls.at(-1).path, /^\/customers\/cus_1\/customer-portal\/session\?return_url=/);

  // Customer cancels in the portal: keeps access until the paid period ends.
  const cancel = signed(subEvent("subscription.updated",
    { status: "active", cancel_at_next_billing_date: true, next_billing_date: renew }), "msg_cancel");
  await call("/v1/webhooks/dodo", { method: "POST", ...cancel });
  status = await (await call("/v1/billing/status", { token: "good-token" })).json();
  assert.equal(status.has_access, true);
  assert.equal(status.subscription.access_ends_at, renew);
  assert.equal(status.subscription.renews_at, null);

  const expire = signed(subEvent("subscription.expired", { status: "expired", expires_at: new Date().toISOString() }), "msg_exp");
  await call("/v1/webhooks/dodo", { method: "POST", ...expire });
  status = await (await call("/v1/billing/status", { token: "good-token" })).json();
  assert.equal(status.plan, "alpha");
  assert.equal(status.has_access, false);
  assert.equal(status.plan_history.length, 1);
  assert.equal(status.plan_history[0].end_reason, "expiry");

  // After expiry they can buy again with the same Dodo customer.
  await call("/v1/billing/checkout", { method: "POST", token: "good-token" });
  assert.deepEqual(backend.dodoCalls.at(-1).body.customer, { customer_id: "cus_1" });
});

test("out-of-order: an older event cannot undo a newer one", async () => {
  const newer = signed(subEvent("subscription.active", { status: "active", next_billing_date: future(30) }, "2026-10-11T10:00:00Z"));
  const older = signed(subEvent("subscription.on_hold", { status: "on_hold" }, "2026-10-11T09:00:00Z"));
  await call("/v1/webhooks/dodo", { method: "POST", ...newer });
  await call("/v1/webhooks/dodo", { method: "POST", ...older });
  assert.equal(backend.tables.subscriptions[0].status, "active");
});

test("user is found via checkout email when metadata is missing; other products are ignored", async () => {
  await call("/v1/billing/checkout", { method: "POST", token: "good-token" });
  const other = subEvent("subscription.active", { status: "active", product_id: "pdt_other", next_billing_date: future(30) });
  await call("/v1/webhooks/dodo", { method: "POST", ...signed(other) });
  assert.equal(backend.tables.subscriptions.length, 0);

  const noMeta = subEvent("subscription.active", { status: "active", next_billing_date: future(30) });
  noMeta.data.metadata = {};
  await call("/v1/webhooks/dodo", { method: "POST", ...signed(noMeta) });
  assert.equal(backend.tables.subscriptions[0].user_id, USER);
});

test("access rules for past_due grace and cancelled", () => {
  assert.equal(hasAccess({ status: "past_due", access_ends_at: future(2) }), true);
  assert.equal(hasAccess({ status: "past_due", access_ends_at: future(-1) }), false);
  assert.equal(hasAccess({ status: "on_hold", access_ends_at: null }), false);
  const row = subscriptionRow(env, USER, { subscription_id: "s", status: "cancelled", next_billing_date: future(10) }, new Date().toISOString(), null);
  assert.equal(hasAccess(row), true);
});

test("return page sends the browser back to the app", async () => {
  const res = await call("/v1/billing/return?status=active&subscription_id=sub_1");
  const html = await res.text();
  assert.match(html, /bibbles-auth:\/\/billing\?status=active/);
  assert.ok(!html.includes("sub_1"));
});

test("missing secrets give a clear 503, not a crash", async () => {
  const res = await worker.fetch(new Request("https://x.workers.dev/v1/billing/checkout",
    { method: "POST", headers: { Authorization: "Bearer good-token" } }), { ...env, DODO_PAYMENTS_API_KEY: "" }, {});
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, "billing_not_configured");
});

// ---- three plans ------------------------------------------------------------
const env3 = {
  ...env, DODO_PRODUCT_ID: undefined, PLAN_NAME: undefined,
  PLANS: [
    { id: "alpha", name: "Alpha", tagline: "Free", free: true, features: ["Basics"] },
    { id: "sigma", name: "Sigma", product_id: "pdt_sigma", features: ["More"] },
    { id: "omega", name: "Omega", product_id: "pdt_omega", highlight: true, features: ["Most"] },
  ],
};

function sub3(type, data, ts) {
  const e = subEvent(type, data, ts);
  e.data.product_id = data.product_id;
  return e;
}

test("plans endpoint lists Alpha/Sigma/Omega with live Dodo prices", async () => {
  const res = await call("/v1/billing/plans", { useEnv: env3 });
  assert.equal(res.status, 200);
  const { plans } = await res.json();
  assert.deepEqual(plans.map((p) => p.id), ["alpha", "sigma", "omega"]);
  assert.equal(plans[0].free, true);
  assert.equal(plans[0].price.amount, 0);
  assert.deepEqual(plans[1].price, { amount: 49900, currency: "INR", interval: "Month", interval_count: 1, tax_inclusive: true });
  assert.equal(plans[2].highlight, true);
  assert.ok(!JSON.stringify(plans).includes("pdt_"), "product ids are not exposed");
});

test("PLANS from wrangler.toml as a JSON string also works", () => {
  const ids = plansConfig({ PLANS: JSON.stringify(env3.PLANS) }).map((p) => p.id);
  assert.deepEqual(ids, ["alpha", "sigma", "omega"]);
});

test("checkout uses the chosen plan's product; unknown/free plans are refused", async () => {
  const body = JSON.stringify({ plan: "omega" });
  const res = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body, useEnv: env3 });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).plan, "omega");
  assert.deepEqual(backend.dodoCalls.at(-1).body.product_cart, [{ product_id: "pdt_omega", quantity: 1 }]);
  for (const plan of ["alpha", "gold"]) {
    const bad = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body: JSON.stringify({ plan }), useEnv: env3 });
    assert.equal(bad.status, 400);
  }
});

test("Sigma subscriber switching to Omega changes the plan instead of a second subscription", async () => {
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_sigma", next_billing_date: future(30) }, "2026-10-11T10:00:00Z")) });
  assert.equal(backend.tables.subscriptions[0].plan, "sigma");

  const same = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body: JSON.stringify({ plan: "sigma" }), useEnv: env3 });
  assert.equal(same.status, 409);

  const res = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body: JSON.stringify({ plan: "omega" }), useEnv: env3 });
  assert.deepEqual(await res.json(), { changed: true, plan: "omega" });
  const last = backend.dodoCalls.find((c) => c.path.endsWith("/change-plan"));
  assert.equal(last.path, "/subscriptions/sub_1/change-plan");
  assert.equal(last.body.product_id, "pdt_omega");
  assert.equal(last.body.proration_billing_mode, "prorated_immediately");
  assert.equal(last.body.collect_via_payment_link, true, "the difference is paid on a Dodo page");
  assert.match(last.body.return_url, /\/v1\/billing\/return$/);

  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.plan_changed", { status: "active", product_id: "pdt_omega", next_billing_date: future(30) }, "2026-10-11T11:00:00Z")) });
  const status = await (await call("/v1/billing/status", { token: "good-token", useEnv: env3 })).json();
  assert.equal(status.plan, "omega");
  assert.equal(status.plan_history.length, 1);
  assert.equal(status.plan_history[0].plan, "sigma");
  assert.equal(status.plan_history[0].end_reason, "upgrade");
  assert.equal(backend.tables.billing_plan_periods.filter((p) => !p.ended_at).length, 1);
});

test("a webhook for a product that isn't a Bibbles plan is ignored", async () => {
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_someone_else", next_billing_date: future(30) })) });
  assert.equal(backend.tables.subscriptions.length, 0);
});

test("profiles.plan and plan_expires_at follow buy → renew → switch → expire", async () => {
  const envSync = { ...env3, PLAN_SYNC_TABLE: "profiles", PLAN_SYNC_COLUMN: "plan",
                    PLAN_SYNC_USER_COLUMN: "id", PLAN_SYNC_EXPIRES_COLUMN: "plan_expires_at" };
  const profile = () => backend.tables.profiles[0];
  const r1 = future(30);
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: envSync,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_sigma", next_billing_date: r1 }, "2026-10-11T10:00:00Z")) });
  assert.equal(profile().plan, "sigma");
  assert.equal(profile().plan_expires_at, syncExpiry({ renews_at: r1 }));
  assert.ok(Date.parse(profile().plan_expires_at) > Date.parse(r1), "renewal grace keeps access through a late renewal");

  const r2 = future(60);
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: envSync,
    ...signed(sub3("subscription.renewed", { status: "active", product_id: "pdt_sigma", next_billing_date: r2 }, "2026-10-11T11:00:00Z")) });
  assert.ok(Date.parse(profile().plan_expires_at) > Date.parse(r2), "renewal moves the expiry forward");

  await call("/v1/webhooks/dodo", { method: "POST", useEnv: envSync,
    ...signed(sub3("subscription.plan_changed", { status: "active", product_id: "pdt_omega", next_billing_date: r2 }, "2026-10-11T12:00:00Z")) });
  assert.equal(profile().plan, "omega");

  await call("/v1/webhooks/dodo", { method: "POST", useEnv: envSync,
    ...signed(sub3("subscription.expired", { status: "expired", product_id: "pdt_omega", expires_at: new Date().toISOString() }, "2026-10-11T13:00:00Z")) });
  assert.equal(profile().plan, "alpha");
  assert.equal(profile().plan_expires_at, null);
});

test("switching plans applies at once even if Dodo's webhook never arrives", async () => {
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_sigma", next_billing_date: future(30) }, "2026-10-11T10:00:00Z")) });
  const res = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body: JSON.stringify({ plan: "omega" }), useEnv: env3 });
  assert.deepEqual(await res.json(), { changed: true, plan: "omega" });
  // No webhook delivered — status already reads Omega from Dodo's record.
  const status = await (await call("/v1/billing/status", { token: "good-token", useEnv: env3 })).json();
  assert.equal(status.plan, "omega");
  assert.equal(status.plan_history[0].plan, "sigma");
});

test("status re-reads Dodo for a missed webhook, but not on every request", async () => {
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_sigma", next_billing_date: future(30) }, "2026-10-11T10:00:00Z")) });
  const reads = () => backend.dodoCalls.filter((c) => c.method === "GET" && c.path.startsWith("/subscriptions/")).length;
  await call("/v1/billing/status", { token: "good-token", useEnv: env3 });
  assert.equal(reads(), 0, "fresh row: no extra Dodo call");
  backend.tables.subscriptions[0].updated_at = new Date(Date.now() - 60_000).toISOString();
  await call("/v1/billing/status", { token: "good-token", useEnv: env3 });
  assert.equal(reads(), 1, "stale row: one Dodo read");
});

test("a stuck earlier switch gives a clear 'still processing' answer, not 'payments unavailable'", async () => {
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_sigma", next_billing_date: future(30) }, "2026-10-11T10:00:00Z")) });
  backend.dodoState.pending = true;
  const res = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body: JSON.stringify({ plan: "omega" }), useEnv: env3 });
  assert.equal(res.status, 409);
  assert.equal((await res.json()).error, "plan_change_pending");
});

test("when Dodo has payment-link plan changes turned off, the switch falls back to the card on file", async () => {
  await call("/v1/webhooks/dodo", { method: "POST", useEnv: env3,
    ...signed(sub3("subscription.active", { status: "active", product_id: "pdt_sigma", next_billing_date: future(30) }, "2026-10-11T10:00:00Z")) });
  backend.dodoState.noLinks = true;
  const res = await call("/v1/billing/checkout", { method: "POST", token: "good-token", body: JSON.stringify({ plan: "omega" }), useEnv: env3 });
  assert.deepEqual(await res.json(), { changed: true, plan: "omega" });
  const changes = backend.dodoCalls.filter((c) => c.path.endsWith("/change-plan"));
  assert.equal(changes.length, 2);
  assert.equal(changes[1].body.collect_via_payment_link, undefined);
  assert.equal(changes[1].body.return_url, undefined);
});

// ---- account deletion -------------------------------------------------------
const delEnv = { ...env, PLAN_SYNC_TABLE: "profiles", PLAN_SYNC_COLUMN: "plan", PLAN_SYNC_USER_COLUMN: "id",
                 PLAN_SYNC_EXPIRES_COLUMN: "plan_expires_at" };
function paidRow(extra = {}) {
  backend.tables.subscriptions.push({ user_id: USER, plan: "sigma", status: "active", dodo_subscription_id: "sub_1",
    dodo_customer_id: "cus_1", renews_at: future(20), access_ends_at: null, ...extra });
  backend.tables.billing_plan_periods.push({ user_id: USER, plan: "sigma", started_at: future(-10), ended_at: null });
  backend.tables.profiles[0].plan = "sigma";
}
const cancel = (token = "good-token") => call("/v1/billing/cancel-for-deletion", { method: "POST", token, useEnv: delEnv });

test("deletion: active subscription is cancelled at Dodo, stored and plan reset", async () => {
  paidRow();
  const res = await cancel();
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { cancelled: true, had_subscription: true });
  const patch = backend.dodoCalls.find((c) => c.method === "PATCH");
  assert.equal(patch.path, "/subscriptions/sub_1");
  assert.deepEqual(patch.body, { status: "cancelled" });
  assert.equal(backend.tables.subscriptions[0].status, "cancelled");
  assert.ok(backend.tables.billing_plan_periods[0].ended_at);
  assert.equal(backend.tables.billing_plan_periods[0].end_reason, "account_deleted");
  assert.equal(backend.tables.profiles[0].plan, "alpha");
});

test("deletion: no subscription means nothing to cancel and no Dodo call", async () => {
  const res = await cancel();
  assert.deepEqual(await res.json(), { cancelled: false, had_subscription: false });
  assert.equal(backend.dodoCalls.length, 0);
});

test("deletion: already cancelled at Dodo is not cancelled again", async () => {
  paidRow({ status: "cancelled", access_ends_at: future(5) });
  backend.dodoState.status = "cancelled";
  const res = await cancel();
  assert.deepEqual(await res.json(), { cancelled: false, had_subscription: true });
  assert.equal(backend.dodoCalls.filter((c) => c.method === "PATCH").length, 0);
});

test("deletion: Dodo failure or unconfirmed cancel returns an error and keeps the plan", async () => {
  paidRow();
  backend.dodoState.patchFails = true;
  let res = await cancel();
  assert.equal(res.status, 502);
  assert.equal(backend.tables.subscriptions[0].status, "active");
  backend.dodoState.patchFails = false;
  backend.dodoState.ignoreCancel = true;
  res = await cancel();
  assert.equal(res.status, 502);
  assert.equal((await res.json()).error, "cancel_not_confirmed");
  assert.equal(backend.tables.profiles[0].plan, "sigma");
});

test("deletion: requires the user's own sign-in", async () => {
  paidRow();
  const res = await cancel("bad-token");
  assert.equal(res.status, 401);
  assert.equal(backend.dodoCalls.length, 0);
});
