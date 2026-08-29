-- ═══════════════════════════════════════════════════════════════
-- Patch : archivage des logements au lieu de suppression destructrice
-- Sûr à exécuter sur une base déjà en production (aucun DROP TABLE).
-- ═══════════════════════════════════════════════════════════════

-- 1. Ajoute la colonne d'archivage (ne supprime plus jamais un logement,
--    on le masque juste de la liste active)
alter table public.logements add column if not exists archived boolean not null default false;

-- 2. Remplace la suppression en cascade des réservations par un
--    détachement (set null) : si un logement est malgré tout supprimé
--    en base, l'historique des réservations et des SMS reste intact.
alter table public.reservations drop constraint if exists reservations_logement_id_fkey;
alter table public.reservations
  add constraint reservations_logement_id_fkey
  foreign key (logement_id) references public.logements(id) on delete set null;
