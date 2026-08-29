// supabase/functions/send-sms/index.ts
//
// Envoie un vrai SMS automatisé via Twilio (remplace l'ouverture
// manuelle de l'app Messages). Le message est reconstruit ici,
// côté serveur, à partir des données de la réservation — le client
// ne fait que demander "envoie le SMS d'entrée pour cette réservation",
// il ne peut pas dicter le numéro de destination ni le contenu.
//
// Variables d'environnement à configurer AVANT déploiement :
//   supabase secrets set TWILIO_ACCOUNT_SID=xxxx
//   supabase secrets set TWILIO_AUTH_TOKEN=xxxx
//   supabase secrets set TWILIO_FROM_NUMBER=+33xxxxxxxxx
//
// Déploiement : `supabase functions deploy send-sms`

import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*', // à restreindre à ton domaine en prod
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const DEF_TPL = {
  checkin: "Bonjour {contact}, une entrée est prévue au {logement} le {date} à {heure}. Voyageur : {voyageur} ({plateforme}). Code d'accès : {code_acces}. Adresse : {adresse}. Merci !",
  checkout: "Bonjour {contact}, un ménage est à prévoir au {logement} suite au départ du {date} à {heure} ({plateforme}). Merci !",
};

function fmtDateFR(iso: string) {
  if (!iso) return '';
  const d = new Date(iso);
  return d.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

function buildMessage(tmpl: string, ctx: {
  logement?: string; adresse?: string; code?: string; voyageur?: string;
  date?: string; heure?: string; plateforme?: string; contact?: string;
}) {
  return (tmpl || '')
    .replace(/{logement}/g, ctx.logement || '')
    .replace(/{adresse}/g, ctx.adresse || '')
    .replace(/{code_acces}/g, ctx.code || 'À confirmer')
    .replace(/{voyageur}/g, ctx.voyageur || 'N/A')
    .replace(/{date}/g, fmtDateFR(ctx.date || ''))
    .replace(/{heure}/g, ctx.heure || '')
    .replace(/{plateforme}/g, ctx.plateforme || '')
    .replace(/{contact}/g, ctx.contact || '');
}

// Conversion basique numéro français local -> E.164.
// Adapter cette fonction si l'activité s'étend hors de France.
function toE164(tel: string): string {
  const cleaned = (tel || '').replace(/[\s.\-()]/g, '');
  if (cleaned.startsWith('+')) return cleaned;
  if (cleaned.startsWith('0') && cleaned.length === 10) return '+33' + cleaned.slice(1);
  return cleaned;
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

    const { reservation_id, type } = await req.json();
    if (!reservation_id || !['checkin', 'checkout'].includes(type)) {
      return new Response(JSON.stringify({ error: 'reservation_id ou type invalide' }), { status: 400, headers: CORS_HEADERS });
    }

    // RLS garantit que ces lectures ne renvoient des lignes QUE si
    // elles appartiennent à l'utilisateur authentifié.
    const { data: resa, error: resaErr } = await supabase
      .from('reservations')
      .select('id, logement_id, societe_id, checkin, checkout, checkin_h, checkout_h, voyageur, platform')
      .eq('id', reservation_id)
      .single();
    if (resaErr || !resa) {
      return new Response(JSON.stringify({ error: 'Réservation introuvable ou non autorisée' }), { status: 404, headers: CORS_HEADERS });
    }

    const { data: societe } = await supabase
      .from('societes')
      .select('nom, contact, tel')
      .eq('id', resa.societe_id)
      .single();
    if (!societe?.tel) {
      return new Response(JSON.stringify({ error: 'Aucun numéro de téléphone pour cette société' }), { status: 400, headers: CORS_HEADERS });
    }

    const { data: logement } = await supabase
      .from('logements')
      .select('nom, adresse, code')
      .eq('id', resa.logement_id)
      .single();

    const { data: settings } = await supabase
      .from('settings')
      .select('template_checkin, template_checkout')
      .eq('user_id', user.id)
      .single();

    const tmpl = type === 'checkin'
      ? (settings?.template_checkin || DEF_TPL.checkin)
      : (settings?.template_checkout || DEF_TPL.checkout);

    const message = buildMessage(tmpl, {
      logement: logement?.nom,
      adresse: logement?.adresse,
      code: logement?.code,
      voyageur: resa.voyageur,
      date: type === 'checkin' ? resa.checkin : resa.checkout,
      heure: type === 'checkin' ? resa.checkin_h : resa.checkout_h,
      plateforme: resa.platform,
      contact: societe.contact,
    });

    const to = toE164(societe.tel);
    const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!;
    const authToken = Deno.env.get('TWILIO_AUTH_TOKEN')!;
    const fromNumber = Deno.env.get('TWILIO_FROM_NUMBER')!;

    const twilioRes = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
      {
        method: 'POST',
        headers: {
          'Authorization': 'Basic ' + btoa(`${accountSid}:${authToken}`),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ To: to, From: fromNumber, Body: message }),
      }
    );
    const twilioData = await twilioRes.json();

    if (!twilioRes.ok) {
      return new Response(JSON.stringify({ error: `Twilio: ${twilioData.message || twilioRes.status}` }), { status: 502, headers: CORS_HEADERS });
    }

    // Journalisation + mise à jour du statut, toujours scopées à l'utilisateur
    await supabase.from('sms_logs').insert({
      user_id: user.id,
      societe_nom: societe.nom,
      logement_nom: logement?.nom || '—',
      type,
      message,
    });
    await supabase.from('reservations').update(
      type === 'checkin' ? { status_checkin: 'sent' } : { status_checkout: 'sent' }
    ).eq('id', resa.id);

    return new Response(JSON.stringify({ success: true, sid: twilioData.sid, message }), {
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
