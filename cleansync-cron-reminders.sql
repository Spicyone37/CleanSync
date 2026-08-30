-- ═══════════════════════════════════════════════════════════════
-- Planification du rappel SMS J-1 automatique
-- Additif, sûr à exécuter sur une base déjà en production.
-- ═══════════════════════════════════════════════════════════════

-- Active les extensions nécessaires (pg_cron pour planifier, pg_net
-- pour faire un appel HTTP sortant depuis Postgres)
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- Remplace les deux valeurs ci-dessous avant d'exécuter :
--   <TON_CRON_SECRET>   → la même valeur que celle définie via
--                          `supabase secrets set CRON_SECRET=...`
--   <TON_PROJET>        → la référence de ton projet Supabase
--                          (ex. kwwfdhrlvbfdmkmxpwde)
--
-- Choix de l'heure : 18h00 UTC = 19h00 (hiver) ou 20h00 (été) heure
-- de Paris. Ajuste selon le moment où tu veux que les rappels partent.
select cron.schedule(
  'send-reminders-daily',
  '0 18 * * *', -- tous les jours à 18h00 UTC
  $$
  select net.http_post(
    url := 'https://<TON_PROJET>.supabase.co/functions/v1/send-reminders-cron',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', '<TON_CRON_SECRET>'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Pour vérifier que le job est bien programmé :
-- select * from cron.job;

-- Pour voir l'historique d'exécution :
-- select * from cron.job_run_details order by start_time desc limit 20;

-- Pour supprimer le job si besoin :
-- select cron.unschedule('send-reminders-daily');
