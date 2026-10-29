// Bibbles billing Worker — Dodo Payments subscriptions for the Mac app.
//
// The Dodo API key and webhook secret live ONLY here, as Worker secrets.
// The Mac app never sees them: it asks this Worker for a checkout link with
// the user's Supabase token, and Dodo tells this Worker (by signed webhook)
// when a subscription starts, renews, or ends.
//
// Routes
//   GET  /v1/billing/plans      (anyone)     -> Alpha / Sigma / Omega with live Dodo prices
//   POST /v1/billing/checkout   (signed in)  {plan} -> { checkout_url } or { changed: true }
//   POST /v1/billing/portal     (signed in)  -> { url }   manage / cancel
//   GET  /v1/billing/status     (signed in)  -> plan, subscription, plan_history
//   POST /v1/billing/cancel-for-deletion (signed in) -> { cancelled, had_subscription }
//        Stops all future charges before the account is deleted (called by bibbles-api).
//   GET  /v1/billing/return     (browser)    -> "back to Bibbles" page
//   POST /v1/webhooks/dodo      (Dodo only)  -> verified subscription events
//   GET  /health

const DODO_BASE = { live: "https://live.dodopayments.com", test: "https://test.dodopayments.com" };
const WEBHOOK_TOLERANCE_SECONDS = 5 * 60;
const SUBSCRIPTION_EVENTS = new Set([
  "subscription.active", "subscription.renewed", "subscription.updated", "subscription.plan_changed",
  "subscription.past_due", "subscription.on_hold", "subscription.paused", "subscription.unpaused",
  "subscription.cancelled", "subscription.expired", "subscription.failed",
]);

export default {
  async fetch(request, env, ctx) {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      if (error instanceof HttpError) {
        const body = error.status >= 500 ? { error: error.code } : { error: error.code, message: error.message };
        return json(body, error.status);
      }
      // Never log request bodies, tokens or billing identifiers.
      console.error("billing_error", error && error.name, error && error.message);
      return json({ error: "server_error" }, 500);
    }
  },
};

export async function route(request, env, ctx) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  if (request.method === "OPTIONS") return new Response(null, { status: 204 });
  if (path === "/health") return json({ ok: true, mode: dodoMode(env) });

  if (path === "/v1/webhooks/dodo" && request.method === "POST") return handleWebhook(request, env);
  if (path === "/v1/billing/return" && request.method === "GET") return returnPage(url, env);
  if (path === "/v1/billing/plans" && request.method === "GET") return json({ plans: await publicPlans(env) });

  if (path === "/v1/billing/checkout" && request.method === "POST") {
    const user = await authenticate(request, env);
    const body = await request.json().catch(() => ({}));
    return createCheckout(user, url, env, body && body.plan);
  }
  if (path === "/v1/billing/portal" && request.method === "POST") {
    const user = await authenticate(request, env);
    return createPortal(user, url, env);
  }
  if (path === "/v1/billing/cancel-for-deletion" && request.method === "POST") {
    const user = await authenticate(request, env);
    return json(await cancelForDeletion(env, user.id));
  }
  if (path === "/v1/billing/status" && request.method === "GET") {
    const user = await authenticate(request, env);
    return json(await billingStatus(env, user.id));
  }
  return json({ error: "not_found" }, 404);
}

// ---------------------------------------------------------------- auth

/** Validates the app's Supabase access token by asking Supabase who it belongs to. */
export async function authenticate(request, env) {
  const header = request.headers.get("Authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) throw new HttpError(401, "unauthorized", "Please sign in.");
  const response = await fetch(`${supabaseURL(env)}/auth/v1/user`, {
    headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new HttpError(401, "unauthorized", "Please sign in.");
  const user = await response.json();
  if (!user || !user.id) throw new HttpError(401, "unauthorized", "Please sign in.");
  return { id: String(user.id).toLowerCase(), email: user.email || null };
}

// ---------------------------------------------------------------- checkout / portal

async function createCheckout(user, url, env, requestedPlan) {
  requireConfig(env, ["DODO_PAYMENTS_API_KEY"]);
  const plan = choosePaidPlan(env, requestedPlan);
  const existing = await getSubscriptionRow(env, user.id);

  if (existing && hasAccess(existing)) {
    if (existing.plan === plan.id) {
      throw new HttpError(409, "already_subscribed", `You’re already on ${plan.name}.`);
    }
    // Sigma ⇄ Omega: switch the running subscription; Dodo prorates the difference.
    // The customer pays the difference on a Dodo payment page (like the first
    // purchase) instead of a silent card charge, which banks — especially Indian
    // cards — often hold for approval.
    const changePath = `/subscriptions/${encodeURIComponent(existing.dodo_subscription_id)}/change-plan`;
    const base = {
      product_id: plan.product_id,
      quantity: 1,
      proration_billing_mode: "prorated_immediately",
      on_payment_failure: "prevent_change",
    };
    const pending = () => new HttpError(409, "plan_change_pending",
      "Your last plan change is still being processed. Finish its payment page, or try again in a few minutes.");
    let change;
    try {
      change = await dodo(env, "POST", changePath, {
        ...base,
        collect_via_payment_link: true,
        cancel_older_payment_link: true,
        return_url: `${publicBase(url, env)}/v1/billing/return`,
      });
    } catch (error) {
      if (error && error.dodoCode === "PENDING_PLAN_CHANGE_EXISTS") throw pending();
      if (!(error && error.dodoCode === "PLAN_CHANGE_PAYMENT_LINK_DISABLED")) throw error;
      // This Dodo business can't collect plan changes on a page: charge the card on file.
      try {
        change = await dodo(env, "POST", changePath, base);
      } catch (fallbackError) {
        if (fallbackError && fallbackError.dodoCode === "PENDING_PLAN_CHANGE_EXISTS") throw pending();
        throw fallbackError;
      }
    }
    if (change.payment_link) return json({ checkout_url: change.payment_link, plan: plan.id });
    // Don't wait for the webhook: read the subscription back and apply it now.
    await refreshFromDodo(env, existing, { force: true });
    return json({ changed: true, plan: plan.id });
  }
  if (!user.email && !(existing && existing.dodo_customer_id)) {
    throw new HttpError(400, "email_required", "Your account needs an email address to buy a plan.");
  }

  const body = {
    product_cart: [{ product_id: plan.product_id, quantity: 1 }],
    customer: existing && existing.dodo_customer_id
      ? { customer_id: existing.dodo_customer_id }
      : { email: user.email, name: user.email.split("@")[0] },
    return_url: `${publicBase(url, env)}/v1/billing/return`,
    metadata: { bibbles_user_id: user.id, bibbles_plan: plan.id },
  };
  const session = await dodo(env, "POST", "/checkouts", body);
  if (!session.checkout_url) throw new HttpError(502, "checkout_unavailable", "Checkout is unavailable right now.");

  // Remembered so a webhook can be tied to this user even if metadata is missing.
  await supabase(env, "POST", "billing_checkouts", {
    body: { session_id: session.session_id, user_id: user.id, email: user.email },
    prefer: "resolution=merge-duplicates,return=minimal",
    query: "on_conflict=session_id",
  });
  return json({ checkout_url: session.checkout_url, session_id: session.session_id, plan: plan.id });
}

// ---------------------------------------------------------------- plans

const DEFAULT_PLANS = [
  { id: "alpha", name: "Alpha", tagline: "Try Bibbles free", free: true,
    features: ["Voice, typed chat and dictation", "Screen help", "Monthly starter allowance"] },
  { id: "sigma", name: "Sigma", tagline: "For everyday work",
    features: ["Everything in Alpha", "More monthly asks", "Deep tasks"] },
  { id: "omega", name: "Omega", tagline: "For power users", highlight: true,
    features: ["Everything in Sigma", "Highest monthly limits", "Most deep tasks"] },
];

/** Plans from `PLANS` in wrangler.toml (array or JSON string), else the defaults. */
export function plansConfig(env) {
  let plans = env.PLANS;
  if (typeof plans === "string" && plans.trim()) {
    try { plans = JSON.parse(plans); } catch { plans = null; }
  }
  if (!Array.isArray(plans) || !plans.length) {
    plans = DEFAULT_PLANS.map((plan) => ({ ...plan }));
    // Older single-plan setup: DODO_PRODUCT_ID + PLAN_NAME.
    const single = plans.find((plan) => plan.id === paidPlan(env)) || plans[1];
    if (env.DODO_PRODUCT_ID) single.product_id = env.DODO_PRODUCT_ID;
  }
  return plans.map((plan) => ({
    id: String(plan.id || "").toLowerCase(),
    name: String(plan.name || plan.id || ""),
    tagline: plan.tagline ? String(plan.tagline) : "",
    features: Array.isArray(plan.features) ? plan.features.map(String).slice(0, 8) : [],
    product_id: plan.product_id ? String(plan.product_id) : null,
    free: !!plan.free || !plan.product_id,
    highlight: !!plan.highlight,
  })).filter((plan) => plan.id);
}

function choosePaidPlan(env, requested) {
  const paid = plansConfig(env).filter((plan) => !plan.free);
  if (!paid.length) {
    console.error("billing_missing_config", "PLANS product_id");
    throw new HttpError(503, "billing_not_configured", "Payments are not set up yet.");
  }
  if (!requested) return paid[0];
  const plan = paid.find((p) => p.id === String(requested).toLowerCase());
  if (!plan) throw new HttpError(400, "unknown_plan", "That plan isn’t available.");
  return plan;
}

export function planForProduct(env, productId) {
  if (!productId) return null;
  return plansConfig(env).find((plan) => plan.product_id === productId) || null;
}

function planRank(env, id) {
  return plansConfig(env).findIndex((plan) => plan.id === id);
}

const priceCache = new Map(); // product_id -> { at, price }
const PRICE_TTL_MS = 10 * 60 * 1000;

/** The plans the app shows, with prices read from Dodo (cached 10 minutes). */
export async function publicPlans(env) {
  const plans = plansConfig(env);
  return Promise.all(plans.map(async (plan) => ({
    id: plan.id, name: plan.name, tagline: plan.tagline, features: plan.features,
    free: plan.free, highlight: plan.highlight,
    price: plan.free ? { amount: 0, currency: null, interval: null, interval_count: null }
                     : await productPrice(env, plan.product_id),
  })));
}

async function productPrice(env, productId) {
  if (!productId || !env.DODO_PAYMENTS_API_KEY) return null;
  const cached = priceCache.get(productId);
  if (cached && Date.now() - cached.at < PRICE_TTL_MS) return cached.price;
  try {
    const product = await dodo(env, "GET", `/products/${encodeURIComponent(productId)}`);
    const p = product && product.price;
    const price = p && Number.isFinite(p.price) ? {
      amount: p.price,                       // minor units (paise, cents)
      currency: p.currency || null,
      interval: p.payment_frequency_interval || null,
      interval_count: p.payment_frequency_count || 1,
      tax_inclusive: p.tax_inclusive ?? null,
    } : null;
    priceCache.set(productId, { at: Date.now(), price });
    return price;
  } catch {
    return cached ? cached.price : null;
  }
}

async function createPortal(user, url, env) {
  requireConfig(env, ["DODO_PAYMENTS_API_KEY"]);
  const row = await getSubscriptionRow(env, user.id);
  if (!row || !row.dodo_customer_id) {
    throw new HttpError(404, "no_subscription", "There is no Bibbles subscription on this account yet.");
  }
  const returnURL = encodeURIComponent(`${publicBase(url, env)}/v1/billing/return?from=portal`);
  const portal = await dodo(env, "POST",
    `/customers/${encodeURIComponent(row.dodo_customer_id)}/customer-portal/session?return_url=${returnURL}`);
  if (!portal.link) throw new HttpError(502, "portal_unavailable", "Billing management is unavailable right now.");
  return json({ url: portal.link });
}

function returnPage(url, env) {
  const appURL = new URL(env.APP_RETURN_URL || "bibbles-auth://billing");
  const status = url.searchParams.get("status");
  if (status && /^[a-z_]{1,24}$/.test(status)) appURL.searchParams.set("status", status);
  if (url.searchParams.get("from") === "portal") appURL.searchParams.set("from", "portal");
  const target = appURL.toString();
  const failed = status && ["failed", "cancelled", "expired"].includes(status);
  const title = failed ? "Payment not completed" : "You’re all set";
  const line = failed
    ? "No charge was made. You can close this tab and try again from Bibbles."
    : "Head back to Bibbles — your plan updates in a few seconds.";
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Bibbles</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0c11;color:#fff;
font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:420px;padding:32px;text-align:center}
h1{font-size:24px;margin:0 0 10px}p{color:#ffffffa0;line-height:1.5}a{display:inline-block;margin-top:18px;padding:11px 22px;
border-radius:999px;background:linear-gradient(90deg,#6b9eff,#a88cff,#fa94db);color:#000;font-weight:600;text-decoration:none}</style>
</head><body><main><h1>${title}</h1><p>${line}</p><a href="${escapeHTML(target)}">Open Bibbles</a></main>
<script>setTimeout(function(){location.href=${JSON.stringify(target)}},600)</script></body></html>`;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
}

// ---------------------------------------------------------------- status

export async function billingStatus(env, userId) {
  // Self-healing: if a webhook was missed or is late, Dodo's own record wins.
  const row = await refreshFromDodo(env, await getSubscriptionRow(env, userId));
  const periods = await supabase(env, "GET", "billing_plan_periods", {
    query: `user_id=eq.${userId}&ended_at=not.is.null&select=plan,started_at,ended_at,end_reason&order=ended_at.desc&limit=100`,
  });
  const active = !!row && hasAccess(row);
  const plan = active ? row.plan : freePlan(env);
  return {
    plan,
    has_access: active,
    manage_available: !!(row && row.dodo_customer_id),
    subscription: row ? {
      plan,
      status: row.status,
      started_at: row.started_at,
      access_ends_at: row.access_ends_at,
      renews_at: active ? row.renews_at : null,
    } : null,
    plan_history: Array.isArray(periods) ? periods : [],
  };
}

/** Whether a stored subscription row should unlock the paid plan right now. */
export function hasAccess(row, now = Date.now()) {
  if (!row || !row.status) return false;
  const ends = row.access_ends_at ? Date.parse(row.access_ends_at) : null;
  switch (row.status) {
    case "active":
      return ends === null || ends > now;
    case "past_due":
    case "cancelled":
      return ends !== null && ends > now;
    default:
      return false;
  }
}

const SYNC_AFTER_MS = 20_000;

/** Re-reads the user's subscription from Dodo (at most every 20 s unless forced)
 *  and applies it exactly like a webhook. Never throws: on any problem the
 *  stored row is kept. */
export async function refreshFromDodo(env, row, { force = false } = {}) {
  if (!row || !row.dodo_subscription_id || !env.DODO_PAYMENTS_API_KEY) return row;
  if (!force && row.updated_at && Date.now() - Date.parse(row.updated_at) < SYNC_AFTER_MS) return row;
  try {
    const sub = await dodo(env, "GET", `/subscriptions/${encodeURIComponent(row.dodo_subscription_id)}`);
    if (!sub || !sub.subscription_id) return row;
    console.log("dodo_sync", sub.status, sub.product_id, "card_on_file:", sub.has_payment_method);
    await applySubscriptionEvent(env, {
      type: "subscription.synced",
      timestamp: new Date().toISOString(),
      data: { ...sub, metadata: { ...(sub.metadata || {}), bibbles_user_id: row.user_id } },
    });
    return (await getSubscriptionRow(env, row.user_id)) || row;
  } catch (error) {
    console.error("dodo_sync_failed", error && error.message);
    return row;
  }
}

// ---------------------------------------------------------------- account deletion

/** Subscription states in which Dodo may still charge the card. */
const CHARGEABLE = new Set(["active", "pending", "past_due", "on_hold", "paused"]);

/** Cancels the user's subscription at Dodo immediately so no further payment is
 *  taken, then records it. Safe to call more than once. Throws (502) if Dodo
 *  can't confirm, so the caller must NOT delete the account in that case. */
export async function cancelForDeletion(env, userId) {
  const stored = await getSubscriptionRow(env, userId);
  if (!stored || !stored.dodo_subscription_id) return { cancelled: false, had_subscription: false };
  requireConfig(env, ["DODO_PAYMENTS_API_KEY"]);
  const id = encodeURIComponent(stored.dodo_subscription_id);
  // Read Dodo's real state; the stored row can lag behind webhooks.
  const live = await dodo(env, "GET", `/subscriptions/${id}`);
  const status = String((live && live.status) || stored.status || "").toLowerCase();
  if (CHARGEABLE.has(status)) {
    await dodo(env, "PATCH", `/subscriptions/${id}`, { status: "cancelled" });
    const check = await dodo(env, "GET", `/subscriptions/${id}`);
    if (CHARGEABLE.has(String((check && check.status) || "").toLowerCase())) {
      throw new HttpError(502, "cancel_not_confirmed", "Your subscription could not be cancelled. Please try again.");
    }
  }
  const now = new Date().toISOString();
  await supabase(env, "PATCH", "subscriptions", {
    query: `user_id=eq.${userId}`,
    body: { status: "cancelled", access_ends_at: now, updated_at: now },
    prefer: "return=minimal",
  });
  await supabase(env, "PATCH", "billing_plan_periods", {
    query: `user_id=eq.${userId}&ended_at=is.null`,
    body: { ended_at: now, end_reason: "account_deleted" },
    prefer: "return=minimal",
  });
  await syncPlanColumn(env, userId, freePlan(env), null);
  console.log("billing_cancelled_for_deletion", status);
  return { cancelled: CHARGEABLE.has(status), had_subscription: true };
}

// ---------------------------------------------------------------- webhooks

async function handleWebhook(request, env) {
  requireConfig(env, ["DODO_WEBHOOK_SECRET"]);
  const raw = await request.text();
  const id = request.headers.get("webhook-id");
  const ok = await verifyWebhook(env.DODO_WEBHOOK_SECRET, {
    id, timestamp: request.headers.get("webhook-timestamp"), signature: request.headers.get("webhook-signature"),
  }, raw);
  if (!ok) return json({ error: "invalid_signature" }, 401);

  // Dodo retries deliveries; each webhook-id is applied once.
  const seen = await supabase(env, "GET", "billing_webhook_events", { query: `id=eq.${encodeURIComponent(id)}&select=id` });
  if (Array.isArray(seen) && seen.length) return json({ ok: true, duplicate: true });

  const event = JSON.parse(raw);
  if (SUBSCRIPTION_EVENTS.has(event.type) && event.data) {
    await applySubscriptionEvent(env, event);
  }
  await supabase(env, "POST", "billing_webhook_events", {
    body: { id, type: String(event.type || "") },
    prefer: "resolution=ignore-duplicates,return=minimal",
  });
  return json({ ok: true });
}

/** Standard Webhooks: HMAC-SHA256 over `${id}.${timestamp}.${body}`, key = base64(secret without whsec_). */
export async function verifyWebhook(secret, headers, rawBody, nowSeconds = Math.floor(Date.now() / 1000)) {
  const { id, timestamp, signature } = headers;
  if (!secret || !id || !timestamp || !signature) return false;
  const ts = Number(timestamp);
  if (!Number.isFinite(ts) || Math.abs(nowSeconds - ts) > WEBHOOK_TOLERANCE_SECONDS) return false;
  const keyBytes = base64ToBytes(secret.startsWith("whsec_") ? secret.slice(6) : secret);
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${rawBody}`));
  const expected = bytesToBase64(new Uint8Array(mac));
  return signature.split(" ").some((part) => {
    const [version, value] = part.split(",");
    return version === "v1" && value && timingSafeEqual(value, expected);
  });
}

export async function applySubscriptionEvent(env, event) {
  const sub = event.data;
  if (!sub.subscription_id) return;
  const plan = planForProduct(env, sub.product_id);
  if (!plan || plan.free) return; // not a Bibbles plan product
  const eventTime = event.timestamp || new Date().toISOString();
  const userId = await resolveUser(env, sub);
  if (!userId) {
    console.warn("billing_unmatched_subscription", event.type);
    return;
  }

  const previous = await getSubscriptionRow(env, userId);
  // Ignore events older than what we already applied for this subscription (out-of-order delivery).
  if (previous && previous.dodo_subscription_id === sub.subscription_id && previous.last_event_at
      && Date.parse(previous.last_event_at) > Date.parse(eventTime)) return;

  const next = subscriptionRow(env, userId, sub, eventTime, previous, plan.id);
  await supabase(env, "POST", "subscriptions", {
    body: next, query: "on_conflict=user_id", prefer: "resolution=merge-duplicates,return=minimal",
  });

  const had = !!previous && hasAccess(previous);
  const has = hasAccess(next);
  if (!had && has) {
    await supabase(env, "POST", "billing_plan_periods", {
      body: { user_id: userId, plan: next.plan, started_at: next.started_at, dodo_subscription_id: sub.subscription_id },
      prefer: "return=minimal",
    });
  } else if (had && has && previous.plan !== next.plan) {
    // Sigma ⇄ Omega: close the old period and open the new one.
    const now = new Date().toISOString();
    await supabase(env, "PATCH", "billing_plan_periods", {
      query: `user_id=eq.${userId}&ended_at=is.null`,
      body: { ended_at: now, end_reason: planRank(env, next.plan) > planRank(env, previous.plan) ? "upgrade" : "downgrade" },
      prefer: "return=minimal",
    });
    await supabase(env, "POST", "billing_plan_periods", {
      body: { user_id: userId, plan: next.plan, started_at: now, dodo_subscription_id: sub.subscription_id },
      prefer: "return=minimal",
    });
  } else if (had && !has) {
    const reason = sub.status === "expired" ? "expiry" : sub.status === "cancelled" ? "cancellation" : "payment_issue";
    await supabase(env, "PATCH", "billing_plan_periods", {
      query: `user_id=eq.${userId}&ended_at=is.null`,
      body: { ended_at: new Date().toISOString(), end_reason: reason },
      prefer: "return=minimal",
    });
  }
  // Keep the table the main Worker reads (e.g. profiles.plan) in step on every
  // event, so renewals also move the expiry forward.
  await syncPlanColumn(env, userId, has ? next.plan : freePlan(env), has ? syncExpiry(next) : null);
}

export function subscriptionRow(env, userId, sub, eventTime, previous, planId = paidPlan(env)) {
  const status = String(sub.status || "").toLowerCase();
  const nextBilling = isoOrNull(sub.next_billing_date);
  const cancelAtEnd = !!sub.cancel_at_next_billing_date;
  let accessEnds = null;
  let renews = null;
  if (status === "active") {
    if (cancelAtEnd) accessEnds = isoOrNull(sub.expires_at) || nextBilling;
    else renews = nextBilling;
  } else if (status === "past_due") {
    accessEnds = isoOrNull(sub.past_due_ends_at) || nextBilling;
  } else if (status === "cancelled") {
    // Paid-for time is kept until the end of the current period.
    accessEnds = nextBilling || isoOrNull(sub.cancelled_at);
  } else {
    accessEnds = isoOrNull(sub.expires_at) || isoOrNull(sub.cancelled_at) || eventTime;
  }
  const sameSub = previous && previous.dodo_subscription_id === sub.subscription_id && previous.plan === planId;
  return {
    user_id: userId,
    plan: planId,
    status,
    dodo_subscription_id: sub.subscription_id,
    dodo_customer_id: (sub.customer && sub.customer.customer_id) || (previous && previous.dodo_customer_id) || null,
    product_id: sub.product_id || null,
    started_at: (sameSub && previous.started_at)
      || (previous && previous.dodo_subscription_id === sub.subscription_id ? eventTime : null) // switched plan
      || isoOrNull(sub.created_at) || eventTime,
    renews_at: renews,
    access_ends_at: accessEnds,
    last_event_at: eventTime,
    updated_at: new Date().toISOString(),
  };
}

async function resolveUser(env, sub) {
  const fromMetadata = sub.metadata && sub.metadata.bibbles_user_id;
  if (fromMetadata && /^[0-9a-f-]{36}$/i.test(fromMetadata)) return fromMetadata.toLowerCase();
  const bySub = await supabase(env, "GET", "subscriptions",
    { query: `dodo_subscription_id=eq.${encodeURIComponent(sub.subscription_id)}&select=user_id&limit=1` });
  if (Array.isArray(bySub) && bySub[0]) return bySub[0].user_id;
  const customerId = sub.customer && sub.customer.customer_id;
  if (customerId) {
    const byCustomer = await supabase(env, "GET", "subscriptions",
      { query: `dodo_customer_id=eq.${encodeURIComponent(customerId)}&select=user_id&limit=1` });
    if (Array.isArray(byCustomer) && byCustomer[0]) return byCustomer[0].user_id;
  }
  const email = sub.customer && sub.customer.email;
  if (email) {
    const byEmail = await supabase(env, "GET", "billing_checkouts",
      { query: `email=eq.${encodeURIComponent(email)}&select=user_id&order=created_at.desc&limit=1` });
    if (Array.isArray(byEmail) && byEmail[0]) return byEmail[0].user_id;
  }
  return null;
}

/** Optional: mirror the plan into a table your main Worker already reads (e.g. profiles.plan). */
async function syncPlanColumn(env, userId, plan, expiresAt) {
  if (!env.PLAN_SYNC_TABLE) return;
  const column = env.PLAN_SYNC_COLUMN || "plan";
  const userColumn = env.PLAN_SYNC_USER_COLUMN || "id";
  const body = { [column]: plan };
  if (env.PLAN_SYNC_EXPIRES_COLUMN) body[env.PLAN_SYNC_EXPIRES_COLUMN] = expiresAt;
  await supabase(env, "PATCH", env.PLAN_SYNC_TABLE, {
    query: `${userColumn}=eq.${userId}`, body, prefer: "return=minimal",
  });
}

const RENEWAL_GRACE_MS = 2 * 86_400_000;

/** When paid access ends: the known end date, or the next renewal plus a short
 *  grace so a renewal that is processed a little late never drops the plan. */
export function syncExpiry(row) {
  if (row.access_ends_at) return row.access_ends_at;
  if (row.renews_at) return new Date(Date.parse(row.renews_at) + RENEWAL_GRACE_MS).toISOString();
  return null;
}

// ---------------------------------------------------------------- helpers

async function getSubscriptionRow(env, userId) {
  const rows = await supabase(env, "GET", "subscriptions", { query: `user_id=eq.${userId}&select=*&limit=1` });
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

async function dodo(env, method, path, body) {
  const response = await fetch(`${DODO_BASE[dodoMode(env)]}${path}`, {
    method,
    headers: { Authorization: `Bearer ${env.DODO_PAYMENTS_API_KEY}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    const detail = (await response.text().catch(() => "")).slice(0, 400);
    console.error("dodo_error", method, path.split("?")[0].replace(/cus_[A-Za-z0-9]+/, "cus_…"), response.status, detail);
    const error = new HttpError(502, "payments_unavailable", "Payments are unavailable right now. Please try again.");
    try { error.dodoCode = JSON.parse(detail).code; } catch { /* not JSON */ }
    throw error;
  }
  return response.json();
}

async function supabase(env, method, table, { query = "", body, prefer } = {}) {
  requireConfig(env, ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"]);
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  const headers = { apikey: key, "Content-Type": "application/json", Accept: "application/json" };
  // Legacy service_role keys are JWTs (eyJ…) and also go in Authorization;
  // new secret keys (sb_secret_…) must only be sent as `apikey`.
  if (key.startsWith("eyJ")) headers.Authorization = `Bearer ${key}`;
  if (prefer) headers.Prefer = prefer;
  const response = await fetch(`${supabaseURL(env)}/rest/v1/${table}${query ? `?${query}` : ""}`, {
    method, headers, body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    const detail = (await response.text().catch(() => "")).slice(0, 400);
    console.error("supabase_error", method, table, response.status, detail);
    throw new HttpError(500, "server", "Billing storage error.");
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function dodoMode(env) { return env.DODO_ENV === "test" ? "test" : "live"; }
function paidPlan(env) { return (env.PLAN_NAME || "sigma").toLowerCase(); }
function freePlan(env) { return (env.FREE_PLAN_NAME || "alpha").toLowerCase(); }
function supabaseURL(env) { return String(env.SUPABASE_URL || "").replace(/\/+$/, ""); }
function publicBase(url, env) { return (env.PUBLIC_BASE_URL || url.origin).replace(/\/+$/, ""); }

function requireConfig(env, keys) {
  const missing = keys.filter((key) => !env[key]);
  if (missing.length) {
    console.error("billing_missing_config", missing.join(","));
    throw new HttpError(503, "billing_not_configured", "Payments are not set up yet.");
  }
}

function isoOrNull(value) {
  if (!value) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : null;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function base64ToBytes(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
