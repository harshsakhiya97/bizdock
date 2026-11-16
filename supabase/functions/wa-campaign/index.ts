// wa-campaign: sends WhatsApp campaigns (WhatsApp → Campaign).
//
//   POST { action: 'cron' } + header x-cron-secret   → sends the due campaigns, about 1 message a second
//     (called by pg_cron every minute while one is due, and straight away when a send-now campaign is made;
//      the secret is the workflow runner's: public.workflow_cron_secret())
//
// Each call runs up to ~50 seconds; a campaign is locked for 90 seconds while it is being sent, and the next
// call carries on with its numbers still queued. Every message is kept in whatsapp_logs (source 'campaign'),
// so delivered / read / replies come from the WATI webhook; a lead's copy goes on its WhatsApp tab.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const RUN_MS = 50_000
const GAP_MS = 1_000

type Campaign = { id: string; tenant_id: string; name: string; template: string; template_body: string | null; status: string }
type Recipient = { id: string; phone: string; lead_id: string | null; params: Record<string, string> }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: secret } = await admin.rpc('workflow_cron_secret')
  if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'Not allowed' }, 401)

  const started = Date.now()
  let sent = 0
  const done: string[] = []
  while (Date.now() - started < RUN_MS - GAP_MS) {
    const { data: claimed, error } = await admin.rpc('wa_campaign_claim')
    if (error) return json({ error: error.message }, 500)
    const c = (claimed as Campaign[] | null)?.[0]
    if (!c) break
    sent += await sendCampaign(admin, c, started)
    done.push(c.id)
  }
  return json({ ok: true, campaigns: done.length, sent })
})

async function sendCampaign(admin: SupabaseClient, c: Campaign, started: number): Promise<number> {
  let n = 0
  let wati: Wati
  try {
    wati = await connect(admin, c.tenant_id)
  } catch (e) {
    // not connected: every number fails with the reason, the campaign is done
    await admin.from('wa_campaign_recipients').update({ status: 'failed', error: (e as Error).message }).eq('campaign_id', c.id).eq('status', 'queued')
    await admin.from('wa_campaigns').update({ status: 'done', finished_at: new Date().toISOString(), locked_until: null }).eq('id', c.id)
    return 0
  }
  const broadcast = `bizdock_${c.name}`.replace(/[^a-zA-Z0-9_]+/g, '_').slice(0, 60)

  while (Date.now() - started < RUN_MS - GAP_MS) {
    const { data: batch } = await admin
      .from('wa_campaign_recipients')
      .select('id, phone, lead_id, params')
      .eq('campaign_id', c.id)
      .eq('status', 'queued')
      .order('id')
      .limit(10)
    const list = (batch ?? []) as Recipient[]
    if (!list.length) {
      await admin.from('wa_campaigns').update({ status: 'done', finished_at: new Date().toISOString(), locked_until: null }).eq('id', c.id).eq('status', 'sending')
      return n
    }
    // cancelled meanwhile?
    const { data: now } = await admin.from('wa_campaigns').select('status').eq('id', c.id).maybeSingle()
    if (now?.status !== 'sending') return n

    for (const r of list) {
      if (Date.now() - started >= RUN_MS - GAP_MS) break
      const t0 = Date.now()
      await sendOne(admin, wati, c, r, broadcast)
      n++
      const wait = GAP_MS - (Date.now() - t0)
      if (wait > 0) await sleep(wait)
    }
  }
  // out of time: the next call carries on
  await admin.from('wa_campaigns').update({ locked_until: null }).eq('id', c.id)
  return n
}

type Wati = { base: string; token: string }
async function connect(admin: SupabaseClient, tenantId: string): Promise<Wati> {
  const { data: integ } = await admin.from('integrations').select('config, is_enabled').eq('tenant_id', tenantId).eq('provider', 'whatsapp').maybeSingle()
  if (!integ) throw new Error('WhatsApp is not connected (System Connections).')
  if (!integ.is_enabled) throw new Error('WhatsApp is paused in System Connections.')
  const cfg = (integ.config ?? {}) as Record<string, string>
  if (cfg.vendor !== 'wati') throw new Error('Only WATI can send campaigns for now.')
  const base = (cfg.api_endpoint ?? '').trim().replace(/\/+$/, '').replace(/\/api\/v\d.*$/, '')
  const token = (cfg.access_token ?? '').trim().replace(/^Bearer\s+/i, '')
  if (!/^https:\/\/[^/]+\/\w+/.test(base) || !token) throw new Error('The WATI API endpoint or access token is missing (System Connections).')
  return { base, token }
}

async function sendOne(admin: SupabaseClient, wati: Wati, c: Campaign, r: Recipient, broadcast: string) {
  const parameters = Object.entries(r.params ?? {}).map(([name, value]) => ({ name, value: String(value ?? '').trim() || '-' }))
  const values = Object.fromEntries(parameters.map((p) => [p.name, p.value]))
  const body = String(c.template_body ?? '').replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (m, k) => values[k] ?? m)
  const logRow = {
    tenant_id: c.tenant_id,
    direction: 'out',
    phone: r.phone,
    lead_id: r.lead_id,
    template: c.template,
    body: body || null,
    params: values,
    source: 'campaign',
    campaign_id: c.id,
  }
  try {
    const res = await fetch(`${wati.base}/api/v1/sendTemplateMessage?whatsappNumber=${r.phone}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${wati.token}`, accept: 'application/json', 'content-type': 'application/json' },
      body: JSON.stringify({ template_name: c.template, broadcast_name: broadcast, parameters }),
    })
    const text = await res.text()
    let out: Record<string, unknown> = {}
    try {
      out = text ? JSON.parse(text) : {}
    } catch {
      out = { info: text.slice(0, 300) }
    }
    if (res.status === 401 || res.status === 403) throw new Error('WATI refused the access token.')
    if (!res.ok || out.result === false) {
      const why = out.info ?? out.message ?? out.error
      throw new Error(why ? `WATI: ${String(why)}` : `WATI rejected the message (${res.status}): check +${r.phone} is on WhatsApp.`)
    }
    const { data: log } = await admin
      .from('whatsapp_logs')
      .insert({ ...logRow, status: 'sent', wati_id: out.local_message_id ? String(out.local_message_id) : null })
      .select('id')
      .single()
    await admin.from('wa_campaign_recipients').update({ status: 'sent', log_id: log?.id ?? null, sent_at: new Date().toISOString() }).eq('id', r.id)
    if (r.lead_id) await admin.from('lead_messages').insert({ tenant_id: c.tenant_id, lead_id: r.lead_id, channel: 'whatsapp', title: c.template, body, via: 'campaign' })
  } catch (e) {
    const msg = (e as Error).message.slice(0, 300)
    const { data: log } = await admin.from('whatsapp_logs').insert({ ...logRow, status: 'failed', error: msg }).select('id').single()
    await admin.from('wa_campaign_recipients').update({ status: 'failed', error: msg, log_id: log?.id ?? null, sent_at: new Date().toISOString() }).eq('id', r.id)
  }
}
