-- ═══════════════════════════════════════════════════════════════
-- CleanSync — Migration v4 : abonnements Stripe
-- Additif, sûr à exécuter sur une base déjà en production.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.subscriptions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid references auth.users(id) on delete cascade not null unique,
  stripe_customer_id    text unique,
  stripe_subscription_id text unique,
  plan                  text not null default 'starter' check (plan in ('starter','pro','business')),
  status                text not null default 'incomplete'
                          check (status in ('incomplete','trialing','active','past_due','canceled','unpaid')),
  logement_limit        int, -- null = illimité (Business)
  current_period_end    timestamptz,
  created_at            timestamptz default now(),
  updated_at            timestamptz default now()
);

alter table public.subscriptions enable row level security;

-- Le gestionnaire peut UNIQUEMENT lire son propre abonnement.
-- Aucune policy insert/update/delete pour les utilisateurs standards :
-- seules les Edge Functions (via la clé service_role, qui contourne le
-- RLS) peuvent modifier ces lignes. Un client ne doit jamais pouvoir
-- s'auto-attribuer un plan payant sans passer par Stripe.
create policy "subscriptions_self_read" on public.subscriptions for select
  using (user_id = auth.uid());

create index if not exists idx_subscriptions_user on public.subscriptions(user_id);
create index if not exists idx_subscriptions_stripe_customer on public.subscriptions(stripe_customer_id);
create index if not exists idx_subscriptions_stripe_sub on public.subscriptions(stripe_subscription_id);
