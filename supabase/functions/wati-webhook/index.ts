// wati-webhook: WATI's webhook for a workspace (POST …/wati-webhook?key=<the workspace's key>), added in WATI → Webhooks.
//
//   a message the customer sent           → a reply in WhatsApp logs (Chats)
//   templateMessageSent                   → WATI's ids (id, wamid, local id) kept on the log of that send
//   sentMessageDELIVERED / sentMessageREAD / templateMessageFailed … → delivered / read time or failure on the log
//     (these carry no number: matched on WATI's ids, else the number inside the wamid and that number's latest send)
//
// Always answers 200 (WATI retries otherwise); unknown events are ignored.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const ok = (body: unknown = { ok: true }) => new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } })
type Row = Record<string, unknown>
type Log = { id: string; status: string; wati_ids: string[] | null }

/** 98XXXXXXXX / +91 98… → 9198XXXXXXXX */
const waNumber = (raw: unknown) => {
  let d = String(raw ?? '').replace(/\D/g, '')
  if (d.startsWith('00')) d = d.slice(2)
  if (d.length === 11 && d.startsWith('0')) d = d.slice(1)
  if (d.length === 10) d = `91${d}`
  return d.length >= 11 ? d : ''
}
/** the number inside a WhatsApp message id: wamid.<base64 of 0x1C 0x18 <length> <digits> …> */
const wamidNumber = (raw: unknown) => {
  const m = String(raw ?? '').match(/^wamid\.(.+)$/)
  if (!m) return ''
  try {
    const bin = atob(m[1])
    const digits = bin.match(/\d{10,15}/)
    return digits ? waNumber(digits[0]) : ''
  } catch {
    return ''
  }
}
/** WATI times: ISO, or epoch seconds as a string */
const when = (raw: unknown) => {
  const v = String(raw ?? '').trim()
  if (/^\d{9,11}$/.test(v)) return new Date(Number(v) * 1000).toISOString()
  if (/^\d{12,}$/.test(v)) return new Date(Number(v)).toISOString()
  const t = Date.parse(v)
  return Number.isNaN(t) ? new Date().toISOString() : new Date(t).toISOString()
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return ok({ ok: true, note: 'Use POST' })
  const key = new URL(req.url).searchParams.get('key') ?? ''
  if (!/^[a-f0-9]{20,64}$/.test(key)) return ok({ ok: false, error: 'Bad key' })
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: hook } = await admin.from('whatsapp_hooks').select('tenant_id').eq('key', key).maybeSingle()
  if (!hook) return ok({ ok: false, error: 'Unknown key' })
  const tenant = String(hook.tenant_id)

  let b: Row
  try {
    b = await req.json()
  } catch {
    return ok({ ok: false, error: 'Send JSON' })
  }
  await admin.from('whatsapp_hooks').update({ last_event_at: new Date().toISOString() }).eq('tenant_id', tenant)

  const event = String(b.eventType ?? b.event ?? '').trim()
  const phone = waNumber(b.waId ?? b.whatsappNumber ?? b.phone ?? b.from) || wamidNumber(b.whatsappMessageId)
  const ids = [b.id, b.whatsappMessageId, b.localMessageId, b.messageId].map((x) => String(x ?? '').trim()).filter(Boolean)
  const at = when(b.timestamp ?? b.created)

  /** the log this event is about: by WATI's id, else that number's latest send */
  const findLog = async (maxAgeHours: number) => {
    if (ids.length) {
      const { data } = await admin.from('whatsapp_logs').select('id, status, wati_ids').eq('tenant_id', tenant).in('wati_id', ids).limit(1).maybeSingle()
      if (data) return data as Log
      const { data: d2 } = await admin.from('whatsapp_logs').select('id, status, wati_ids').eq('tenant_id', tenant).overlaps('wati_ids', ids).limit(1).maybeSingle()
      if (d2) return d2 as Log
    }
    if (!phone) return null
    const { data } = await admin
      .from('whatsapp_logs')
      .select('id, status, wati_ids')
      .eq('tenant_id', tenant)
      .eq('phone', phone)
      .eq('direction', 'out')
      // a send whose WATI ids are known (and aren't these) is another message
      .eq('wati_ids', '{}')
      .gte('sent_at', new Date(Date.now() - maxAgeHours * 3_600_000).toISOString())
      .order('sent_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    return (data as Log | null) ?? null
  }
  /** WATI's ids of this message added to the log (so its next events match it exactly) */
  const withIds = (log: Log) => ({ wati_ids: [...new Set([...(log.wati_ids ?? []), ...ids])] })

  // a message from the customer
  const incoming = event === 'message' || (b.owner === false && !/^sentMessage|^templateMessage/i.test(event))
  if (incoming) {
    if (!phone) return ok()
    const { data: lead } = await admin
      .from('leads')
      .select('id')
      .eq('tenant_id', tenant)
      .or(`phone.ilike.%${phone.slice(-10)},whatsapp.ilike.%${phone.slice(-10)}`)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    const text = String(b.text ?? b.finalText ?? (b.data as Row | undefined)?.text ?? '').trim() || (b.type ? `[${String(b.type)}]` : '')
    await admin.from('whatsapp_logs').insert({
      tenant_id: tenant,
      direction: 'in',
      phone,
      lead_id: lead?.id ?? null,
      body: text,
      source: 'reply',
      status: 'received',
      wati_id: ids[0] ?? null,
      sent_at: at,
    })
    return ok()
  }

  // WATI accepted a template send: keep its ids on our log (by our local id, else that number's latest send without them)
  if (/^templateMessageSent/i.test(event) || /^sessionMessageSent/i.test(event)) {
    if (!ids.length) return ok()
    let log: Log | null = null
    const { data: exact } = await admin.from('whatsapp_logs').select('id, status, wati_ids').eq('tenant_id', tenant).in('wati_id', ids).limit(1).maybeSingle()
    log = (exact as Log | null) ?? null
    if (!log && phone) {
      const { data } = await admin
        .from('whatsapp_logs')
        .select('id, status, wati_ids')
        .eq('tenant_id', tenant)
        .eq('phone', phone)
        .eq('direction', 'out')
        .eq('wati_ids', '{}')
        .gte('sent_at', new Date(Date.now() - 15 * 60_000).toISOString())
        .order('sent_at', { ascending: false })
        .limit(1)
        .maybeSingle()
      log = (data as Log | null) ?? null
    }
    if (log) await admin.from('whatsapp_logs').update(withIds(log)).eq('id', log.id)
    return ok()
  }

  const status = String(b.statusString ?? '').toUpperCase()
  const kind = /READ/i.test(event) || status === 'READ' ? 'read' : /DELIVERED/i.test(event) || status === 'DELIVERED' ? 'delivered' : /FAIL/i.test(event) || status === 'FAILED' ? 'failed' : ''
  if (!kind) return ok({ ok: true, ignored: event })
  const log = await findLog(72)
  if (!log) return ok()
  if (kind === 'read') await admin.from('whatsapp_logs').update({ status: 'read', read_at: at, ...withIds(log) }).eq('id', log.id)
  else if (kind === 'delivered') await admin.from('whatsapp_logs').update({ ...(log.status === 'read' ? {} : { status: 'delivered' }), delivered_at: at, ...withIds(log) }).eq('id', log.id)
  else
    await admin
      .from('whatsapp_logs')
      .update({ ...withIds(log), status: 'failed', error: String(b.failedDetail ?? b.failedCode ?? b.error ?? 'WhatsApp couldn’t deliver it').slice(0, 300) })
      .eq('id', log.id)
  return ok()
})
