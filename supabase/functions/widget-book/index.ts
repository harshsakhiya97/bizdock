// widget-book: a visitor books a slot on a Booking Calendar widget (public, no login).
//
//   POST { code, start (ISO), name, phone, email, answers? }  (answers: the widget's own fields, by key)
//     → holds the slot (widget_book: still free? round robin among the free team members)
//     → posts the booking to the widget's webhook (a BizDock workflow's own webhook, or any URL)
//     → { ok, booking_id, thank_you, redirect_url }
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

/** India date + HH:MM of a moment */
const ist = (iso: string) => {
  const s = new Date(Date.parse(iso) + 330 * 60_000).toISOString()
  return { date: s.slice(0, 10), time: s.slice(11, 16) }
}
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const niceDate = (d: string) => {
  const [y, m, dd] = d.split('-').map(Number)
  return `${dd} ${MONTHS[m - 1]} ${y}`
}
const niceTime = (hm: string) => {
  const [h, mi] = hm.split(':').map(Number)
  return `${h % 12 === 0 ? 12 : h % 12}:${String(mi).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Send JSON.' }, 400)
  }
  const code = String(body.code ?? '')
  const start = String(body.start ?? '')
  if (!/^[a-z0-9]{6,20}$/i.test(code) || Number.isNaN(Date.parse(start))) return json({ error: 'Pick a time first.' }, 400)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  // the widget's own fields (Your Details, after name / phone / email): checked before the slot is taken
  const { data: wd } = await admin.from('widgets').select('config').eq('code', code).eq('is_active', true).is('archived_at', null).maybeSingle()
  const fields = ((wd?.config as { fields?: unknown } | null)?.fields ?? []) as { key: string; label: string; type: string; required?: boolean; options?: string[] }[]
  const given = (body.answers && typeof body.answers === 'object' ? body.answers : {}) as Record<string, unknown>
  const answers: Record<string, string> = {}
  for (const f of Array.isArray(fields) ? fields : []) {
    // never over a field the booking sends itself
    if (!f?.key || ['name', 'phone', 'email', 'meeting_start', 'meeting_end', 'member_email', 'widget'].includes(f.key)) continue
    const v = String(given[f.key] ?? '').trim().slice(0, 2000)
    if (f.required && !v) return json({ error: `Please fill in ${f.label}.` }, 400)
    if (v && f.type === 'select' && Array.isArray(f.options) && f.options.length && !f.options.includes(v)) return json({ error: `Please pick ${f.label} from the list.` }, 400)
    // several picks, as one text: "Coach, Creator"
    if (v && f.type === 'multiselect' && Array.isArray(f.options) && f.options.length && v.split(',').some((x) => !f.options!.includes(x.trim())))
      return json({ error: `Please pick ${f.label} from the list.` }, 400)
    answers[f.key] = v
  }
  const { data: b, error } = await admin.rpc('widget_book', {
    p_code: code,
    p_start: new Date(start).toISOString(),
    p_name: String(body.name ?? ''),
    p_phone: String(body.phone ?? ''),
    p_email: String(body.email ?? ''),
  })
  if (error) return json({ error: error.message }, 400)

  const s = ist(b.starts_at)
  const e = ist(b.ends_at)
  const member = (b.member ?? null) as { id: string; name: string; email: string; phone: string } | null
  // what the webhook gets: the visitor, the slot (India time) and the team member it went to (by email: the
  // workflow's Create Zoom meeting finds them by it)
  const payload: Record<string, string> = {
    name: String(body.name ?? '').trim(),
    phone: String(body.phone ?? '').trim(),
    email: String(body.email ?? '').trim().toLowerCase(),
    meeting_start: `${s.date} ${s.time}`,
    meeting_end: `${e.date} ${e.time}`,
    member_email: member?.email ?? '',
    widget: String(b.widget_name ?? ''),
    // the widget's own fields, under their names
    ...answers,
  }
  if (Object.keys(answers).length) await admin.from('widget_bookings').update({ answers }).eq('id', b.booking_id)

  // where it goes: a BizDock workflow's own webhook (straight to the lead-webhook function) or the pasted URL
  const hook = (b.webhook ?? {}) as { type?: string; workflow_id?: string; url?: string }
  let url = ''
  if (hook.type === 'workflow' && hook.workflow_id) {
    const { data: h } = await admin.from('workflow_hooks').select('webhook_key').eq('workflow_id', hook.workflow_id).maybeSingle()
    if (h?.webhook_key) url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/lead-webhook?key=${encodeURIComponent(h.webhook_key)}`
  } else if (hook.type === 'url' && /^https?:\/\//i.test(String(hook.url ?? ''))) url = String(hook.url).trim()

  let status: number | null = null
  let failed: string | null = url ? null : 'No webhook set on the widget.'
  if (url) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(15_000),
      })
      status = res.status
      if (!res.ok) failed = (await res.text().catch(() => '')).slice(0, 300) || `HTTP ${res.status}`
    } catch (err) {
      failed = (err as Error).message.slice(0, 300)
    }
  }
  await admin.from('widget_bookings').update({ webhook_status: status, webhook_error: failed }).eq('id', b.booking_id)

  // no name given: "Thanks {{name}}!" reads "Thanks!"
  const fill = (t: string) =>
    t
      .replace(payload.name ? /\{\{\s*name\s*\}\}/g : /\s*\{\{\s*name\s*\}\}/g, payload.name)
      .replace(/\{\{\s*date\s*\}\}/g, niceDate(s.date))
      .replace(/\{\{\s*time\s*\}\}/g, niceTime(s.time))
      .replace(/\{\{\s*end_time\s*\}\}/g, niceTime(e.time))
      .replace(/\{\{\s*member_name\s*\}\}/g, member?.name ?? '')
  return json({
    ok: true,
    booking_id: b.booking_id,
    thank_you: fill(String(b.thank_you ?? '') || 'Thanks! Your call is booked for {{date}} at {{time}}.'),
    redirect_url: /^https?:\/\//i.test(String(b.redirect_url ?? '')) ? String(b.redirect_url) : null,
  })
})
