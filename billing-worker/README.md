# Bibbles payments (Dodo Payments)

In the Mac app, **Settings → Account → Upgrade** opens a **Choose your plan** window with three cards: **Alpha** (free), **Sigma** and **Omega**. Prices come live from Dodo. Choosing Sigma or Omega opens Dodo's secure checkout in the browser. Someone already on Sigma who picks Omega (or the reverse) gets switched, with the price difference prorated, not a second subscription.

```
Mac app ──(Supabase token)──▶ bibbles-billing Worker ──(secret API key)──▶ Dodo checkout
                                     ▲                                        │
                                     └──────── signed webhook ◀───────────────┘
                                     │
                               Supabase `subscriptions` table ──▶ app shows Premium
```

The **Dodo API key never goes in the Mac app**. Anyone can unpack an app and read keys out of it. The key lives only in this Worker, as an encrypted Cloudflare secret.

## One-time setup (about 15 minutes)

### 1. Create the two paid products in Dodo
Dodo dashboard → **Products → Create product → Subscription**. Do this twice, with **monthly** billing:

- **Bibbles Sigma**, at your Sigma price
- **Bibbles Omega**, at your Omega price

Copy each product ID (`pdt_…`) into the `PLANS` list at the bottom of `wrangler.toml`:

```toml
  { id = "sigma", ..., product_id = "pdt_SIGMA_ID", ... },
  { id = "omega", ..., product_id = "pdt_OMEGA_ID", ... },
```

You can also edit each plan's tagline and feature lines there. **Prices are never typed here.** The app always shows the price set in Dodo, so to change a price, change it in Dodo. A paid plan without a product ID shows as "Coming soon".

### 2. Create the database tables
Supabase dashboard → **SQL Editor** → paste all of [`schema.sql`](schema.sql) → **Run**.

### 3. Deploy the Worker
In Terminal, from this `billing-worker` folder:

```bash
npx wrangler login
npx wrangler deploy
```

It deploys to `https://bibbles-billing.bibbles.workers.dev`, which is the address the app already uses. If yours comes out different, add `BibblesBillingURL` with that address to `Resources/Info.plist`.

### 4. Add the secrets (typed in, never committed)

```bash
npx wrangler secret put DODO_PAYMENTS_API_KEY      # your Dodo API key
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY  # Supabase → Settings → API keys → service_role / secret
```

### 5. Point Dodo's webhook at the Worker
Dodo dashboard → **Developer → Webhooks → Add endpoint**:

- URL: `https://bibbles-billing.bibbles.workers.dev/v1/webhooks/dodo`
- Events: all `subscription.*` events

Copy the endpoint's **signing secret** (`whsec_…`), then:

```bash
npx wrangler secret put DODO_WEBHOOK_SECRET
```

### 6. Check it's up
Open `https://bibbles-billing.bibbles.workers.dev/health`. You should see `{"ok":true,"mode":"live"}`.

## 7. Give paying users their limits (main `bibbles-api` Worker)

This step needs your main Worker's code. Until it's done, payment and the Premium badge both work, but usage limits stay at Alpha. In `GET /v1/me`, and wherever you choose limits, look up the plan like this:

```js
async function paidPlan(env, userId) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/subscriptions?user_id=eq.${userId}&select=plan,status,started_at,renews_at,access_ends_at`, {
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` },
  });
  const [row] = r.ok ? await r.json() : [];
  if (!row) return null;
  const ends = row.access_ends_at ? Date.parse(row.access_ends_at) : null;
  const active = row.status === "active" ? (ends === null || ends > Date.now())
    : ["past_due", "cancelled"].includes(row.status) && ends !== null && ends > Date.now();
  return active ? row : null;   // row.plan is "sigma" or "omega"; also return it as `subscription` in /v1/me
}
```

Shortcut: if your main Worker already reads the plan from a table column (e.g. `profiles.plan`), uncomment the `PLAN_SYNC_*` lines in `wrangler.toml`. This Worker will then write `alpha`, `sigma` or `omega` there whenever a plan starts, switches or ends.

The plan `id`s (`alpha`, `sigma`, `omega`) must match the names your main Worker uses for limits.

## Testing without real money
Set `DODO_ENV = "test"` in `wrangler.toml` and use your Dodo **test-mode** API key and webhook secret. Then pay with Dodo's test cards. Switch back to `live` (and the live key/secret) before launch.

## Endpoints

| Route | Who calls it | Does |
| --- | --- | --- |
| `GET /v1/billing/plans` | Mac app | Alpha / Sigma / Omega, with live prices from Dodo |
| `POST /v1/billing/checkout` | Mac app (signed in) | `{"plan":"sigma"}`: Dodo checkout, or a Sigma ⇄ Omega switch |
| `POST /v1/billing/portal` | Mac app (signed in) | Opens Dodo's portal: change card, invoices, cancel |
| `GET /v1/billing/status` | Mac app (signed in) | Plan, renewal/expiry dates, history |
| `GET /v1/billing/return` | Browser after paying | "Back to Bibbles" page that reopens the app |
| `POST /v1/webhooks/dodo` | Dodo | Verified subscription events → `subscriptions` table |

How it behaves:

- **Webhook checks:** every webhook is signature-checked (Standard Webhooks, 5-minute replay window) and applied once. Out-of-order deliveries can't undo newer ones.
- **Cancellations:** a cancelled plan keeps Premium until the paid month ends. A failed renewal keeps it through Dodo's grace period.

## Tests

```bash
npm test     # 15 tests: plans & prices, checkout, plan switching, signatures, lifecycle, duplicates, ordering
```
