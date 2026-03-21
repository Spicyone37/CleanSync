-- ═══════════════════════════════════════════════════════════════
-- CleanSync — Script SQL Supabase (version corrigée)
-- À exécuter dans : Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------
-- NETTOYAGE (si tables déjà créées avec l'ancienne version)
-- ---------------------------------------------------------------
drop table if exists public.sms_logs     cascade;
drop table if exists public.reservations cascade;
drop table if exists public.logements    cascade;
drop table if exists public.societes     cascade;
drop table if exists public.settings     cascade;
drop table if exists public.profiles     cascade;

-- ---------------------------------------------------------------
-- 1. profiles — liée à auth.users
-- ---------------------------------------------------------------
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  plan       text not null default 'free',
  created_at timestamptz default now()
);

-- Trigger : crée un profil automatiquement à l'inscription
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------
-- 2. societes — UUID auto-généré par défaut
-- ---------------------------------------------------------------
create table public.societes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id) on delete cascade not null,
  nom        text not null,
  contact    text,
  tel        text not null,
  tarif      text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------
-- 3. logements — UUID auto-généré par défaut
-- ---------------------------------------------------------------
create table public.logements (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete cascade not null,
  nom          text not null,
  adresse      text not null,
  code         text,
  societe_id   uuid references public.societes(id) on delete set null,
  ical_airbnb  text,
  ical_booking text,
  last_sync    timestamptz,
  created_at   timestamptz default now()
);

-- ---------------------------------------------------------------
-- 4. reservations — UUID auto-généré par défaut
-- ---------------------------------------------------------------
create table public.reservations (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete cascade not null,
  logement_id     uuid references public.logements(id) on delete cascade,
  societe_id      uuid references public.societes(id) on delete set null,
  platform        text,
  voyageur        text,
  checkin         date not null,
  checkin_h       text default '15:00',
  checkout        date not null,
  checkout_h      text default '11:00',
  status_checkin  text default 'pending',
  status_checkout text default 'pending',
  uid_ical        text unique,
  source          text default 'manual',
  created_at      timestamptz default now()
);

-- ---------------------------------------------------------------
-- 5. sms_logs — UUID auto-généré par défaut
-- ---------------------------------------------------------------
create table public.sms_logs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete cascade not null,
  societe_nom text,
  logement_nom text,
  type        text,
  message     text,
  sent_at     timestamptz default now()
);

-- ---------------------------------------------------------------
-- 6. settings — clé primaire = user_id (1 ligne par utilisateur)
-- ---------------------------------------------------------------
create table public.settings (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  proxy_url         text default 'https://api.allorigins.win/raw?url=',
  template_checkin  text,
  template_checkout text,
  updated_at        timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — chaque utilisateur ne voit QUE ses données
-- ═══════════════════════════════════════════════════════════════
alter table public.profiles     enable row level security;
alter table public.societes     enable row level security;
alter table public.logements    enable row level security;
alter table public.reservations enable row level security;
alter table public.sms_logs     enable row level security;
alter table public.settings     enable row level security;

-- Profiles
create policy "profiles_own" on public.profiles for all using (auth.uid() = id);

-- Societes
create policy "societes_own" on public.societes for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Logements
create policy "logements_own" on public.logements for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Reservations
create policy "reservations_own" on public.reservations for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- SMS logs
create policy "sms_logs_own" on public.sms_logs for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Settings
create policy "settings_own" on public.settings for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ═══════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════
create index if not exists idx_societes_user     on public.societes(user_id);
create index if not exists idx_logements_user    on public.logements(user_id);
create index if not exists idx_reservations_user on public.reservations(user_id);
create index if not exists idx_reservations_co   on public.reservations(checkout);
create index if not exists idx_sms_user          on public.sms_logs(user_id);

-- ═══════════════════════════════════════════════════════════════
-- PASSER UN COMPTE EN PREMIUM (à exécuter manuellement si besoin)
-- ═══════════════════════════════════════════════════════════════
-- UPDATE public.profiles SET plan = 'premium' WHERE email = 'votre@email.com';
