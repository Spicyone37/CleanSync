-- ═══════════════════════════════════════════════════════════════
-- CleanSync — Migration v3 : module Agents / Prestataires / Prestations
-- Isolation multi-tenant STRICTE : chaque gestionnaire (client) ne voit
-- que ses propres prestataires, agents, logements, prestations, incidents.
-- À exécuter APRÈS cleansync-supabase-v2.sql
-- Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------
-- NETTOYAGE (si une version précédente de ce module existe déjà)
-- ---------------------------------------------------------------
drop view if exists public.v_recap_mensuel;
drop view if exists public.v_prestations;
drop view if exists public.v_agents;
drop view if exists public.v_prestataires;
drop table if exists public.incidents          cascade;
drop table if exists public.photos_prestation  cascade;
drop table if exists public.prestations        cascade;
drop table if exists public.agent_logements    cascade;
drop table if exists public.agents             cascade;
drop table if exists public.prestataires       cascade;

-- ═══════════════════════════════════════════════════════════════
-- 1. PRESTATAIRES — entreprises sous-traitantes de ménage
-- ═══════════════════════════════════════════════════════════════
create table public.prestataires (
  id             uuid primary key default gen_random_uuid(),
  gestionnaire_id uuid references auth.users(id) on delete cascade not null,
  nom            text not null,
  email          text,
  telephone      text,
  adresse        text,
  siret          text,
  notes          text,
  actif          boolean not null default true,
  created_at     timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════
-- 2. AGENTS — collaborateurs de terrain (se connectent via OTP)
--    user_id = leur PROPRE identité auth.users (créée par l'edge
--    function admin-create-agent-secure), différente du gestionnaire.
-- ═══════════════════════════════════════════════════════════════
create table public.agents (
  id              uuid primary key default gen_random_uuid(),
  gestionnaire_id uuid references auth.users(id) on delete cascade not null,
  user_id         uuid references auth.users(id) on delete set null unique,
  prestataire_id  uuid references public.prestataires(id) on delete set null,
  nom             text not null,
  telephone       text,
  email           text,
  actif           boolean not null default true,
  created_at      timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════
-- 3. AGENT_LOGEMENTS — logements assignés à un agent
-- ═══════════════════════════════════════════════════════════════
create table public.agent_logements (
  id              uuid primary key default gen_random_uuid(),
  gestionnaire_id uuid references auth.users(id) on delete cascade not null,
  agent_id        uuid references public.agents(id) on delete cascade not null,
  logement_id     uuid references public.logements(id) on delete cascade not null,
  created_at      timestamptz default now(),
  unique (agent_id, logement_id)
);

-- ═══════════════════════════════════════════════════════════════
-- 4. PRESTATIONS — passages de ménage effectués
-- ═══════════════════════════════════════════════════════════════
create table public.prestations (
  id              uuid primary key default gen_random_uuid(),
  gestionnaire_id uuid references auth.users(id) on delete cascade not null,
  logement_id     uuid references public.logements(id) on delete cascade not null,
  agent_id        uuid references public.agents(id) on delete set null,
  heure_debut     timestamptz not null,
  heure_fin       timestamptz,
  statut          text not null default 'en_cours'
                    check (statut in ('en_cours','terminee','incident')),
  notes           text,
  created_at      timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════
-- 5. PHOTOS_PRESTATION
-- ═══════════════════════════════════════════════════════════════
create table public.photos_prestation (
  id              uuid primary key default gen_random_uuid(),
  gestionnaire_id uuid references auth.users(id) on delete cascade not null,
  prestation_id   uuid references public.prestations(id) on delete cascade not null,
  storage_path    text not null,
  type            text not null check (type in ('prestation','incident')),
  ordre           int default 0,
  created_at      timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════
-- 6. INCIDENTS
-- ═══════════════════════════════════════════════════════════════
create table public.incidents (
  id              uuid primary key default gen_random_uuid(),
  gestionnaire_id uuid references auth.users(id) on delete cascade not null,
  prestation_id   uuid references public.prestations(id) on delete cascade not null,
  type_incident   text,
  description     text,
  gravite         text default 'normale' check (gravite in ('faible','normale','urgente')),
  resolu          boolean not null default false,
  created_at      timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════
-- TRIGGERS — auto-remplissage de gestionnaire_id depuis la ligne
-- parente. Empêche un client (ou un bug front) de forger un
-- gestionnaire_id différent du sien à l'insertion.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.set_gestionnaire_from_agent()
returns trigger language plpgsql as $$
begin
  select gestionnaire_id into new.gestionnaire_id
  from public.agents where id = new.agent_id;
  return new;
end;
$$;

create trigger trg_agent_logements_gest
  before insert on public.agent_logements
  for each row execute function public.set_gestionnaire_from_agent();

create or replace function public.set_gestionnaire_from_logement()
returns trigger language plpgsql as $$
begin
  select user_id into new.gestionnaire_id
  from public.logements where id = new.logement_id;
  return new;
end;
$$;

create trigger trg_prestations_gest
  before insert on public.prestations
  for each row execute function public.set_gestionnaire_from_logement();

create or replace function public.set_gestionnaire_from_prestation()
returns trigger language plpgsql as $$
begin
  select gestionnaire_id into new.gestionnaire_id
  from public.prestations where id = new.prestation_id;
  return new;
end;
$$;

create trigger trg_photos_gest
  before insert on public.photos_prestation
  for each row execute function public.set_gestionnaire_from_prestation();

create trigger trg_incidents_gest
  before insert on public.incidents
  for each row execute function public.set_gestionnaire_from_prestation();

-- ═══════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- ═══════════════════════════════════════════════════════════════
alter table public.prestataires      enable row level security;
alter table public.agents            enable row level security;
alter table public.agent_logements   enable row level security;
alter table public.prestations       enable row level security;
alter table public.photos_prestation enable row level security;
alter table public.incidents         enable row level security;

-- Prestataires : réservé au gestionnaire propriétaire
create policy "prestataires_gestionnaire" on public.prestataires for all
  using (gestionnaire_id = auth.uid()) with check (gestionnaire_id = auth.uid());

-- Agents : le gestionnaire gère tout ; l'agent peut lire sa propre fiche
create policy "agents_gestionnaire" on public.agents for all
  using (gestionnaire_id = auth.uid()) with check (gestionnaire_id = auth.uid());
create policy "agents_self_read" on public.agents for select
  using (user_id = auth.uid());

-- Agent_logements : le gestionnaire gère tout ; l'agent lit ses assignations
create policy "agent_logements_gestionnaire" on public.agent_logements for all
  using (gestionnaire_id = auth.uid()) with check (gestionnaire_id = auth.uid());
create policy "agent_logements_self_read" on public.agent_logements for select
  using (agent_id in (select id from public.agents where user_id = auth.uid()));

-- Prestations : le gestionnaire gère tout ; l'agent gère UNIQUEMENT
-- ses propres prestations, sur des logements qui lui sont assignés
create policy "prestations_gestionnaire" on public.prestations for all
  using (gestionnaire_id = auth.uid()) with check (gestionnaire_id = auth.uid());
create policy "prestations_agent_select" on public.prestations for select
  using (agent_id in (select id from public.agents where user_id = auth.uid()));
create policy "prestations_agent_insert" on public.prestations for insert
  with check (
    agent_id in (select id from public.agents where user_id = auth.uid())
    and logement_id in (
      select logement_id from public.agent_logements
      where agent_id = prestations.agent_id
    )
  );
create policy "prestations_agent_update" on public.prestations for update
  using (agent_id in (select id from public.agents where user_id = auth.uid()))
  with check (agent_id in (select id from public.agents where user_id = auth.uid()));

-- Photos : le gestionnaire gère tout ; l'agent lit/ajoute sur ses prestations
create policy "photos_gestionnaire" on public.photos_prestation for all
  using (gestionnaire_id = auth.uid()) with check (gestionnaire_id = auth.uid());
create policy "photos_agent_select" on public.photos_prestation for select
  using (prestation_id in (
    select id from public.prestations
    where agent_id in (select id from public.agents where user_id = auth.uid())
  ));
create policy "photos_agent_insert" on public.photos_prestation for insert
  with check (prestation_id in (
    select id from public.prestations
    where agent_id in (select id from public.agents where user_id = auth.uid())
  ));

-- Incidents : même logique que les photos
create policy "incidents_gestionnaire" on public.incidents for all
  using (gestionnaire_id = auth.uid()) with check (gestionnaire_id = auth.uid());
create policy "incidents_agent_select" on public.incidents for select
  using (prestation_id in (
    select id from public.prestations
    where agent_id in (select id from public.agents where user_id = auth.uid())
  ));
create policy "incidents_agent_insert" on public.incidents for insert
  with check (prestation_id in (
    select id from public.prestations
    where agent_id in (select id from public.agents where user_id = auth.uid())
  ));

-- ═══════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════
create index if not exists idx_prestataires_gest   on public.prestataires(gestionnaire_id);
create index if not exists idx_agents_gest          on public.agents(gestionnaire_id);
create index if not exists idx_agents_user          on public.agents(user_id);
create index if not exists idx_agents_prest         on public.agents(prestataire_id);
create index if not exists idx_agentlog_gest        on public.agent_logements(gestionnaire_id);
create index if not exists idx_agentlog_agent       on public.agent_logements(agent_id);
create index if not exists idx_agentlog_logement    on public.agent_logements(logement_id);
create index if not exists idx_prestations_gest     on public.prestations(gestionnaire_id);
create index if not exists idx_prestations_agent    on public.prestations(agent_id);
create index if not exists idx_prestations_logement on public.prestations(logement_id);
create index if not exists idx_prestations_debut    on public.prestations(heure_debut);
create index if not exists idx_photos_gest          on public.photos_prestation(gestionnaire_id);
create index if not exists idx_photos_prestation    on public.photos_prestation(prestation_id);
create index if not exists idx_incidents_gest       on public.incidents(gestionnaire_id);
create index if not exists idx_incidents_prestation on public.incidents(prestation_id);

-- ═══════════════════════════════════════════════════════════════
-- VUES — security_invoker=true est OBLIGATOIRE : sans ce réglage,
-- une vue Postgres s'exécute avec les droits de son créateur et
-- IGNORE le RLS des tables sous-jacentes, ce qui romprait
-- complètement l'isolation entre clients.
-- ═══════════════════════════════════════════════════════════════

create view public.v_prestataires
with (security_invoker = true) as
select
  p.*,
  (select count(*) from public.agents a where a.prestataire_id = p.id) as nb_agents,
  (select count(distinct al.logement_id)
     from public.agents a
     join public.agent_logements al on al.agent_id = a.id
     where a.prestataire_id = p.id) as nb_logements,
  (select count(*) from public.prestations pr
     join public.agents a on a.id = pr.agent_id
     where a.prestataire_id = p.id
       and pr.heure_debut >= date_trunc('month', now())) as prestations_ce_mois
from public.prestataires p;

create view public.v_agents
with (security_invoker = true) as
select
  a.*,
  pr.nom as prestataire_nom,
  (select count(*) from public.prestations p
     where p.agent_id = a.id
       and p.heure_debut >= date_trunc('month', now())) as prestations_ce_mois
from public.agents a
left join public.prestataires pr on pr.id = a.prestataire_id;

create view public.v_prestations
with (security_invoker = true) as
select
  p.*,
  l.nom as logement_nom,
  a.nom as agent_nom,
  pt.nom as prestataire_nom,
  case when p.heure_fin is not null
    then round(extract(epoch from (p.heure_fin - p.heure_debut)) / 60)
    else null
  end as duree_minutes,
  (select count(*) from public.photos_prestation ph where ph.prestation_id = p.id) as nb_photos,
  (select count(*) from public.incidents inc where inc.prestation_id = p.id) as nb_incidents
from public.prestations p
left join public.logements l on l.id = p.logement_id
left join public.agents a on a.id = p.agent_id
left join public.prestataires pt on pt.id = a.prestataire_id;

create view public.v_recap_mensuel
with (security_invoker = true) as
with prest_agg as (
  select
    date_trunc('month', p.heure_debut) as mois,
    p.agent_id,
    count(*) as nb_prestations,
    count(distinct p.logement_id) as nb_logements_distincts,
    round(sum(extract(epoch from (p.heure_fin - p.heure_debut))) / 3600.0, 1) as total_heures
  from public.prestations p
  where p.statut in ('terminee','incident') and p.heure_fin is not null
  group by date_trunc('month', p.heure_debut), p.agent_id
),
inc_agg as (
  select
    date_trunc('month', p.heure_debut) as mois,
    p.agent_id,
    count(inc.id) as total_incidents
  from public.prestations p
  join public.incidents inc on inc.prestation_id = p.id
  group by date_trunc('month', p.heure_debut), p.agent_id
)
select
  pa.mois,
  pa.agent_id,
  a.nom as agent_nom,
  pt.nom as prestataire_nom,
  pa.nb_prestations,
  pa.nb_logements_distincts,
  pa.total_heures,
  coalesce(ia.total_incidents, 0) as total_incidents
from prest_agg pa
join public.agents a on a.id = pa.agent_id
left join public.prestataires pt on pt.id = a.prestataire_id
left join inc_agg ia on ia.mois = pa.mois and ia.agent_id = pa.agent_id;

-- ═══════════════════════════════════════════════════════════════
-- STORAGE — bucket des photos de prestation + politiques RLS
-- Chemin utilisé par le code : {prestation_id}/prest_xxx.jpg
-- Sans ces politiques, un bucket "public" exposerait les photos
-- (intérieurs de logements clients) à n'importe qui avec le lien.
-- ═══════════════════════════════════════════════════════════════
insert into storage.buckets (id, name, public)
values ('prestations-photos', 'prestations-photos', false)
on conflict (id) do update set public = false;

create policy "photos_storage_gestionnaire" on storage.objects for all
  using (
    bucket_id = 'prestations-photos'
    and exists (
      select 1 from public.prestations p
      where p.id::text = (storage.foldername(name))[1]
        and p.gestionnaire_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'prestations-photos'
    and exists (
      select 1 from public.prestations p
      where p.id::text = (storage.foldername(name))[1]
        and p.gestionnaire_id = auth.uid()
    )
  );

create policy "photos_storage_agent" on storage.objects for all
  using (
    bucket_id = 'prestations-photos'
    and exists (
      select 1 from public.prestations p
      join public.agents a on a.id = p.agent_id
      where p.id::text = (storage.foldername(name))[1]
        and a.user_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'prestations-photos'
    and exists (
      select 1 from public.prestations p
      join public.agents a on a.id = p.agent_id
      where p.id::text = (storage.foldername(name))[1]
        and a.user_id = auth.uid()
    )
  );
