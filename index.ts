// supabase/functions/sync-ical/index.ts
//
// Remplace le proxy public "api.allorigins.win" : le fetch du fichier
// .ics se fait ici, côté serveur, donc pas de problème CORS et
// aucune URL de calendrier ne transite plus par un service tiers.
//
// Sécurité : le client Supabase est créé avec le JWT de l'utilisateur
// appelant (pas la clé service_role), donc le Row Level Security de
// Postgres continue de s'appliquer normalement — impossible de
// synchroniser le logement d'un autre utilisateur.
//
// Déploiement : `supabase functions deploy sync-ical`

import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*', // à restreindre à ton domaine en prod
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function parseIcal(text: string) {
  const evts: { uid: string | null; summary: string; start: string; end: string }[] = [];
  const re = /BEGIN:VEVENT([\s\S]*?)END:VEVENT/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const blk = m[1];
    const get = (k: string) => {
      const r = new RegExp(k + '[^:]*:([^\r\n]+)').exec(blk);
      return r ? r[1].trim() : null;
    };
    const ds = get('DTSTART'), de = get('DTEND');
    if (ds && de) {
      evts.push({
        uid: get('UID'),
        summary: (get('SUMMARY') || '').replace(/\\n/g, ' ').replace(/\\,/g, ','),
        start: icalISO(ds),
        end: icalISO(de),
      });
    }
  }
  return evts;
}
function icalISO(d: string) {
  const c = d.replace(/[TZ\s]/g, '');
  return `${c.slice(0, 4)}-${c.slice(4, 6)}-${c.slice(6, 8)}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Non authentifié' }), { status: 401, headers: CORS_HEADERS });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) {
      return new Response(JSON.stringify({ error: 'Session invalide' }), { status: 401, headers: CORS_HEADERS });
    }

    const { logement_id } = await req.json();
    if (!logement_id) {
      return new Response(JSON.stringify({ error: 'logement_id manquant' }), { status: 400, headers: CORS_HEADERS });
    }

    // RLS garantit que ce select ne renvoie le logement QUE s'il
    // appartient à l'utilisateur authentifié.
    const { data: logement, error: logErr } = await supabase
      .from('logements')
      .select('id, societe_id, ical_airbnb, ical_booking')
      .eq('id', logement_id)
      .single();

    if (logErr || !logement) {
      return new Response(JSON.stringify({ error: 'Logement introuvable ou non autorisé' }), { status: 404, headers: CORS_HEADERS });
    }

    let imported = 0;
    const errors: string[] = [];

    const platforms: [string | null, string][] = [
      [logement.ical_airbnb, 'Airbnb'],
      [logement.ical_booking, 'Booking'],
    ];

    for (const [url, plat] of platforms) {
      if (!url) continue;
      try {
        const ctl = new AbortController();
        const tid = setTimeout(() => ctl.abort(), 15000);
        const res = await fetch(url, { signal: ctl.signal });
        clearTimeout(tid);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const events = parseIcal(await res.text());
        for (const ev of events) {
          if (!ev.start || !ev.end) continue;

          const { data: existing } = await supabase
            .from('reservations')
            .select('id')
            .eq('uid_ical', ev.uid)
            .maybeSingle();
          if (existing) continue;

          const { error: insErr } = await supabase.from('reservations').insert({
            user_id: user.id,
            logement_id: logement.id,
            societe_id: logement.societe_id || null,
            platform: plat,
            voyageur: ev.summary || `Réservation ${plat}`,
            checkin: ev.start,
            checkout: ev.end,
            checkin_h: '15:00',
            checkout_h: '11:00',
            uid_ical: ev.uid,
            source: 'ical',
          });
          if (insErr) throw insErr;
          imported++;
        }
      } catch (e) {
        errors.push(`${plat}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    await supabase.from('logements').update({ last_sync: new Date().toISOString() }).eq('id', logement.id);

    return new Response(JSON.stringify({ imported, errors }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }), {
      status: 500,
      headers: CORS_HEADERS,
    });
  }
});
