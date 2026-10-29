-- Bibbles billing tables. Run once in Supabase → SQL Editor.
-- Only the billing Worker (service role) writes these. Signed-in users can
-- read their own subscription and plan history; the Mac app already looks
-- for a `subscriptions` table with `user_id`, `plan`, `status`,
-- `started_at`, `access_ends_at` and `renews_at`.

create table if not exists public.subscriptions (
  user_id               uuid primary key references auth.users (id) on delete cascade,
  plan                  text not null,
  status                text not null,
  dodo_subscription_id  text unique,
  dodo_customer_id      text,
  product_id            text,
  started_at            timestamptz,
  renews_at             timestamptz,
  access_ends_at        timestamptz,
  last_event_at         timestamptz,
  updated_at            timestamptz not null default now()
);
create index if not exists subscriptions_customer_idx on public.subscriptions (dodo_customer_id);

-- Completed and current paid periods (ended_at is null while active).
create table if not exists public.billing_plan_periods (
  id                    bigint generated always as identity primary key,
  user_id               uuid not null references auth.users (id) on delete cascade,
  plan                  text not null,
  started_at            timestamptz not null,
  ended_at              timestamptz,
  end_reason            text,
  dodo_subscription_id  text
);
create index if not exists billing_plan_periods_user_idx on public.billing_plan_periods (user_id, ended_at);

-- Every checkout the app opened, so a payment can be tied back to the account.
create table if not exists public.billing_checkouts (
  session_id  text primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  email       text,
  created_at  timestamptz not null default now()
);
create index if not exists billing_checkouts_email_idx on public.billing_checkouts (email, created_at desc);

-- Webhook deliveries already applied (Dodo retries; each id is applied once).
create table if not exists public.billing_webhook_events (
  id           text primary key,
  type         text,
  received_at  timestamptz not null default now()
);

alter table public.subscriptions          enable row level security;
alter table public.billing_plan_periods   enable row level security;
alter table public.billing_checkouts      enable row level security;
alter table public.billing_webhook_events enable row level security;

drop policy if exists "read own subscription" on public.subscriptions;
create policy "read own subscription" on public.subscriptions
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "read own plan periods" on public.billing_plan_periods;
create policy "read own plan periods" on public.billing_plan_periods
  for select to authenticated using (auth.uid() = user_id);
-- billing_checkouts and billing_webhook_events: no policies = service role only.
