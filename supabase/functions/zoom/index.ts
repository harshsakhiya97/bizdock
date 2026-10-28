// zoom: the workspace's Zoom accounts (Server-to-Server OAuth apps).
//
// From the database (header x-cron-secret):
//   { action: 'sync', kind: 'meeting' | 'event', id }       create / move the Zoom meeting (or webinar) of a CRM meeting / calendar event
//   { action: 'delete', account, zoom_id, kind, clear?, clear_event? }   remove it from Zoom (and clear it on the row)
//   { action: 'cron' }                                        pull attendance / Q&A / chat for everything that has ended
//   { action: 'create_adhoc', tenant_id, account?, topic, start, duration }   workflow step → { id, join_url, password, start_url }
// From the app (the caller's login decides what they may do):
//   { action: 'test', id }                                    check an account's keys (Settings & integrations)
//   { action: 'pull', kind, id }                              fetch attendance / comments now
//   { action: 'sync', kind, id }                              retry creating the Zoom meeting
//
// Keys never reach the browser. Times are India time.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

type Account = {
  id: string
  tenant_id: string
  name: string
  account_id: string
  client_id: string
  client_secret: string
  host_email: string | null
  cloud_record: boolean
}
type Row = Record<string, unknown>

class ZoomError extends Error {
  constructor(message: string, public status = 0, public code = 0) {
    super(message)
  }
}

// ---------------- Zoom API ----------------
const tokens = new Map<string, { token: string; until: number }>()

async function tokenFor(a: Account): Promise<string> {
  const hit = tokens.get(a.id)
  if (hit && hit.until > Date.now() + 60_000) return hit.token
  const res = await fetch(`https://zoom.us/oauth/token?grant_type=account_credentials&account_id=${encodeURIComponent(a.account_id.trim())}`, {
    method: 'POST',
    headers: { Authorization: `Basic ${btoa(`${a.client_id.trim()}:${a.client_secret.trim()}`)}` },
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok || !body.access_token) throw new ZoomError(`Zoom login failed: ${body.reason ?? body.error ?? res.status}. Check the Account ID, Client ID and Client secret.`, res.status)
  tokens.set(a.id, { token: body.access_token, until: Date.now() + (Number(body.expires_in) || 3600) * 1000 })
  return body.access_token
}

async function zoom(a: Account, method: string, path: string, payload?: unknown) {
  const res = await fetch(`https://api.zoom.us/v2${path}`, {
    method,
    headers: { Authorization: `Bearer ${await tokenFor(a)}`, ...(payload ? { 'Content-Type': 'application/json' } : {}) },
    body: payload ? JSON.stringify(payload) : undefined,
  })
  if (res.status === 204) return {}
  const text = await res.text()
  let body: Row = {}
  try {
    body = text ? JSON.parse(text) : {}
  } catch {
    body = { message: text }
  }
  if (!res.ok) throw new ZoomError(String(body.message ?? `Zoom error ${res.status}`), res.status, Number(body.code) || 0)
  return body
}

/** every page of a Zoom list */
async function zoomAll(a: Account, path: string, key: string) {
  const out: Row[] = []
  let next = ''
  for (let i = 0; i < 20; i++) {
    const sep = path.includes('?') ? '&' : '?'
    const page = await zoom(a, 'GET', `${path}${sep}page_size=300${next ? `&next_page_token=${encodeURIComponent(next)}` : ''}`)
    out.push(...((page[key] as Row[]) ?? []))
    next = String(page.next_page_token ?? '')
    if (!next) break
  }
  return out
}

const hostOf = (a: Account) => encodeURIComponent((a.host_email ?? '').trim() || 'me')
const hms = (t: string) => (t.length === 5 ? `${t}:00` : t.slice(0, 8))
const minutesBetween = (a: string, b: string) => {
  const [h1, m1] = a.split(':').map(Number)
  const [h2, m2] = b.split(':').map(Number)
  return Math.max(15, h2 * 60 + m2 - (h1 * 60 + m1))
}

// ---------------- create / update / delete ----------------
async function upsertZoom(a: Account, kind: 'meeting' | 'webinar', zoomId: string | null, topic: string, date: string, start: string, end: string | null) {
  const body = {
    topic: topic.slice(0, 200),
    type: kind === 'webinar' ? 5 : 2,
    start_time: `${date}T${hms(start)}`,
    timezone: 'Asia/Kolkata',
    duration: end ? minutesBetween(start, end) : 60,
    settings:
      kind === 'webinar'
        ? { auto_recording: a.cloud_record ? 'cloud' : 'none', question_and_answer: { enable: true } }
        : { join_before_host: true, waiting_room: false, auto_recording: a.cloud_record ? 'cloud' : 'none' },
  }
  const base = kind === 'webinar' ? 'webinars' : 'meetings'
  if (zoomId) {
    try {
      await zoom(a, 'PATCH', `/${base}/${zoomId}`, body)
      const got = await zoom(a, 'GET', `/${base}/${zoomId}`)
      return { id: zoomId, join_url: String(got.join_url ?? ''), start_url: String(got.start_url ?? ''), password: String(got.password ?? '') }
    } catch (e) {
      if (!(e instanceof ZoomError) || (e.status !== 404 && e.code !== 3001)) throw e
      // gone in Zoom (or another account) → create a new one
    }
  }
  const made = await zoom(a, 'POST', `/users/${hostOf(a)}/${base}`, body)
  return { id: String(made.id), join_url: String(made.join_url ?? ''), start_url: String(made.start_url ?? ''), password: String(made.password ?? '') }
}

/** a Zoom account = a System Connections row (integrations, provider 'zoom') */
const toAccount = (r: Row): Account => {
  const c = (r.config ?? {}) as Record<string, string>
  return {
    id: String(r.id),
    tenant_id: String(r.tenant_id),
    name: String(r.label ?? 'Zoom'),
    account_id: c.account_id ?? '',
    client_id: c.client_id ?? '',
    client_secret: c.client_secret ?? '',
    host_email: c.host_email ?? null,
    cloud_record: (c.cloud_record ?? 'Yes') !== 'No',
  }
}

async function loadAccount(admin: SupabaseClient, id: unknown): Promise<Account | null> {
  if (!id) return null
  const { data } = await admin.from('integrations').select('*').eq('id', String(id)).eq('provider', 'zoom').maybeSingle()
  if (!data || !data.is_enabled) return null
  return toAccount(data)
}

async function syncMeeting(admin: SupabaseClient, id: string) {
  const { data: m } = await admin.from('meetings').select('*, lead:leads(first_name, last_name)').eq('id', id).maybeSingle()
  if (!m || !m.zoom_account_id || m.mode !== 'online' || m.status === 'cancelled') return { skipped: true }
  const a = await loadAccount(admin, m.zoom_account_id)
  if (!a) return { skipped: true }
  const who = [m.lead?.first_name, m.lead?.last_name].filter(Boolean).join(' ') || 'guest'
  try {
    const z = await upsertZoom(a, 'meeting', m.zoom_meeting_id, `Meeting with ${who}`, m.meeting_date, m.start_time, m.end_time)
    await admin
      .from('meetings')
      .update({ zoom_meeting_id: z.id, link: z.join_url || m.link, zoom_start_url: z.start_url, zoom_password: z.password, zoom_error: null, zoom_pull_count: 0, zoom_pulled_at: null })
      .eq('id', id)
    return { ok: true, zoom_id: z.id }
  } catch (e) {
    await admin.from('meetings').update({ zoom_error: (e as Error).message }).eq('id', id)
    return { error: (e as Error).message }
  }
}

async function syncEvent(admin: SupabaseClient, id: string) {
  const { data: ev } = await admin.from('events').select('*').eq('id', id).maybeSingle()
  if (!ev || !ev.zoom_account_id || ev.is_cancelled || !ev.start_time) return { skipped: true }
  const a = await loadAccount(admin, ev.zoom_account_id)
  if (!a) return { skipped: true }
  try {
    const topic = ev.topic ? `${ev.title} — ${ev.topic}` : ev.title
    const z = await upsertZoom(a, ev.zoom_kind === 'webinar' ? 'webinar' : 'meeting', ev.zoom_webinar_id, topic, ev.event_date, ev.start_time, ev.end_time)
    await admin
      .from('events')
      .update({ zoom_webinar_id: z.id, meeting_link: z.join_url || ev.meeting_link, zoom_start_url: z.start_url, zoom_password: z.password, zoom_error: null, zoom_pull_count: 0, zoom_pulled_at: null })
      .eq('id', id)
    return { ok: true, zoom_id: z.id }
  } catch (e) {
    await admin.from('events').update({ zoom_error: (e as Error).message }).eq('id', id)
    return { error: (e as Error).message }
  }
}

async function removeZoom(admin: SupabaseClient, b: Row) {
  const a = await loadAccount(admin, b.account)
  if (a && b.zoom_id) {
    try {
      await zoom(a, 'DELETE', `/${b.kind === 'webinar' ? 'webinars' : 'meetings'}/${b.zoom_id}`)
    } catch (e) {
      if (!(e instanceof ZoomError) || e.status !== 404) console.log('zoom delete', (e as Error).message)
    }
  }
  if (b.clear) await admin.from('meetings').update({ zoom_meeting_id: null, zoom_start_url: null, zoom_password: null, zoom_error: null }).eq('id', String(b.clear))
  if (b.clear_event) await admin.from('events').update({ zoom_webinar_id: null, zoom_start_url: null, zoom_password: null, zoom_error: null }).eq('id', String(b.clear_event))
  return { ok: true }
}

// ---------------- attendance / comments ----------------
const norm = (s: unknown) => String(s ?? '').trim().toLowerCase()

/** "00:12:05 From Asha to Everyone:\n\tHello" / "00:12:05\t From  Asha : Hello" (elapsed time in the cloud recording chat file) */
function parseChat(text: string, startedAt: number) {
  const out: { name: string; body: string; at: string | null }[] = []
  const head = /^(\d{1,2}):(\d{2}):(\d{2})\s+From\s+(.+?)(?:\s+to\s+(.+?))?\s*:\s*(.*)$/i
  for (const raw of text.split(/\r?\n/)) {
    const m = raw.match(head)
    if (m) {
      const secs = Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3])
      out.push({ name: m[4].trim(), body: m[6].trim(), at: startedAt ? new Date(startedAt + secs * 1000).toISOString() : null })
    } else if (out.length && raw.trim()) {
      const last = out[out.length - 1]
      last.body = last.body ? `${last.body}\n${raw.trim()}` : raw.trim()
    }
  }
  return out.filter((c) => c.body)
}

async function pull(admin: SupabaseClient, kind: 'meeting' | 'event', id: string) {
  const table = kind === 'meeting' ? 'meetings' : 'events'
  const { data: row } = await admin.from(table).select('*').eq('id', id).maybeSingle()
  const zoomId = kind === 'meeting' ? row?.zoom_meeting_id : row?.zoom_webinar_id
  if (!row || !zoomId) return { error: 'No Zoom meeting on this one yet.' }
  const a = await loadAccount(admin, row.zoom_account_id)
  if (!a) return { error: 'Its Zoom account was removed or switched off.' }
  const isWebinar = kind === 'event' && row.zoom_kind === 'webinar'
  const notes: string[] = []

  // 1. who joined (several joins of one person are added up)
  let participants: Row[] = []
  try {
    participants = await zoomAll(a, `/report/${isWebinar ? 'webinars' : 'meetings'}/${zoomId}/participants`, 'participants')
  } catch (e) {
    // 3001 "Meeting does not exist" = not held yet, or Zoom hasn't made the report yet
    notes.push(
      e instanceof ZoomError && (e.code === 3001 || e.status === 404)
        ? 'Attendance: Zoom has no report yet — the meeting hasn’t been held, or ended only a few minutes ago.'
        : `Attendance: ${(e as Error).message}`,
    )
  }
  const people = new Map<string, { name: string; email: string; join: string | null; leave: string | null; secs: number; sessions: number }>()
  for (const p of participants) {
    const email = norm(p.user_email)
    const name = String(p.name ?? '').trim()
    const key = email || `name:${norm(name)}`
    const cur = people.get(key) ?? { name, email, join: null, leave: null, secs: 0, sessions: 0 }
    const j = p.join_time ? String(p.join_time) : null
    const l = p.leave_time ? String(p.leave_time) : null
    if (j && (!cur.join || j < cur.join)) cur.join = j
    if (l && (!cur.leave || l > cur.leave)) cur.leave = l
    cur.secs += Number(p.duration) || 0
    cur.sessions++
    if (!cur.name && name) cur.name = name
    people.set(key, cur)
  }

  // leads to match: the meeting's lead, or leads of the event's business, by email
  const emails = [...people.values()].map((p) => p.email).filter(Boolean)
  const leadByEmail = new Map<string, string>()
  if (emails.length) {
    let q = admin.from('leads').select('id, email').eq('tenant_id', row.tenant_id).in('email', emails)
    if (row.business_id) q = q.eq('business_id', row.business_id)
    const { data: ls } = await q
    for (const l of ls ?? []) leadByEmail.set(norm(l.email), l.id)
  }
  let meetingLead: { id: string; email: string; first: string } | null = null
  if (kind === 'meeting') {
    const { data: l } = await admin.from('leads').select('id, email, first_name').eq('id', row.lead_id).maybeSingle()
    if (l) meetingLead = { id: l.id, email: norm(l.email), first: norm(l.first_name) }
  }
  const leadFor = (email: string, name: string) => {
    if (email && leadByEmail.has(email)) return leadByEmail.get(email)!
    if (meetingLead && ((email && email === meetingLead.email) || (!email && meetingLead.first && norm(name).startsWith(meetingLead.first)))) return meetingLead.id
    return null
  }

  const att = [...people.values()].map((p) => ({
    tenant_id: row.tenant_id,
    meeting_id: kind === 'meeting' ? id : null,
    event_id: kind === 'event' ? id : null,
    lead_id: leadFor(p.email, p.name),
    name: p.name || null,
    email: p.email || null,
    join_time: p.join,
    leave_time: p.leave,
    minutes: Math.round(p.secs / 60),
    sessions: p.sessions,
  }))
  const nameToEmail = new Map(att.filter((p) => p.name && p.email).map((p) => [norm(p.name), p.email!]))

  // 2. Q&A (webinars; meetings where Zoom has it)
  const comments: Row[] = []
  try {
    // webinars: past_webinars (scope webinar:read:past_qa:admin), else the report
    const qa = isWebinar
      ? await zoom(a, 'GET', `/past_webinars/${zoomId}/qa`).catch(() => zoom(a, 'GET', `/report/webinars/${zoomId}/qa`))
      : await zoom(a, 'GET', `/report/meetings/${zoomId}/qa`)
    for (const q of (qa.questions as Row[]) ?? []) {
      const email = norm(q.email)
      const name = String(q.name ?? '').trim()
      for (const d of (q.question_details as Row[]) ?? []) {
        if (!d.question) continue
        comments.push({
          kind: 'qa',
          name: name || null,
          email: email || null,
          lead_id: leadFor(email, name),
          body: String(d.question),
          answer: d.answer ? String(d.answer) : null,
          said_at: d.create_time ? String(d.create_time) : null,
        })
      }
    }
  } catch (e) {
    if (isWebinar) notes.push(`Q&A: ${(e as Error).message}`)
  }

  // 3. chat, from the cloud recording
  let chatFound = false
  try {
    const rec = await zoom(a, 'GET', `/meetings/${zoomId}/recordings`)
    const started = rec.start_time ? Date.parse(String(rec.start_time)) : 0
    for (const f of ((rec.recording_files as Row[]) ?? []).filter((f) => f.file_type === 'CHAT' && f.download_url)) {
      const res = await fetch(`${f.download_url}${String(f.download_url).includes('?') ? '&' : '?'}access_token=${await tokenFor(a)}`)
      if (!res.ok) continue
      chatFound = true
      for (const c of parseChat(await res.text(), f.recording_start ? Date.parse(String(f.recording_start)) : started)) {
        const email = nameToEmail.get(norm(c.name)) ?? ''
        comments.push({ kind: 'chat', name: c.name, email: email || null, lead_id: leadFor(email, c.name), body: c.body, answer: null, said_at: c.at })
      }
    }
  } catch (e) {
    if (!(e instanceof ZoomError) || e.status !== 404) notes.push(`Chat: ${(e as Error).message}`)
  }

  // keep the fresh copy (only replace what Zoom gave back)
  if (att.length) {
    await admin.from('zoom_attendance').delete().eq(kind === 'meeting' ? 'meeting_id' : 'event_id', id)
    await admin.from('zoom_attendance').insert(att)
  }
  const qaRows = comments.filter((c) => c.kind === 'qa')
  const chatRows = comments.filter((c) => c.kind === 'chat')
  for (const [k, rows, got] of [['qa', qaRows, qaRows.length > 0], ['chat', chatRows, chatFound]] as const) {
    if (!got) continue
    await admin.from('zoom_comments').delete().eq(kind === 'meeting' ? 'meeting_id' : 'event_id', id).eq('kind', k)
    if (rows.length)
      await admin.from('zoom_comments').insert(rows.map((c) => ({ ...c, tenant_id: row.tenant_id, meeting_id: kind === 'meeting' ? id : null, event_id: kind === 'event' ? id : null })))
  }

  // the first pull writes "attended" on each matched lead
  if (row.zoom_pull_count === 0 && att.length) {
    const what = kind === 'meeting' ? 'the Zoom meeting' : `${row.title} (Zoom)`
    const acts = att
      .filter((p) => p.lead_id)
      .map((p) => ({ tenant_id: row.tenant_id, lead_id: p.lead_id, kind: 'note', note: `Attended ${what} · ${p.minutes} min` }))
    if (acts.length) await admin.from('lead_activities').insert(acts)
  }

  // Zoom's report can lag a few minutes after the end: with nothing back yet, the first pull is tried again
  // on the next run (every 5 minutes) for up to 2 hours after the end
  const endAt = Date.parse(
    kind === 'meeting'
      ? `${row.meeting_date}T${String(row.end_time).slice(0, 8)}+05:30`
      : `${row.end_date ?? row.event_date}T${String(row.end_time ?? row.start_time ?? '23:00').slice(0, 8)}+05:30`,
  )
  const retry = !att.length && (row.zoom_pull_count ?? 0) === 0 && Date.now() - endAt < 2 * 3_600_000
  await admin
    .from(table)
    .update({
      zoom_pulled_at: new Date().toISOString(),
      zoom_pull_count: retry ? 0 : (row.zoom_pull_count ?? 0) + 1,
      zoom_error: notes.length && !att.length && !retry ? notes.join(' · ') : null,
    })
    .eq('id', id)
  return { ok: true, attendees: att.length, questions: qaRows.length, chat: chatRows.length, chat_found: chatFound, notes }
}

// ---------------- handler ----------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  let b: Row
  try {
    b = await req.json()
  } catch {
    return fail('Bad request')
  }
  const action = String(b.action ?? '')

  // ---- from the database / workflow runner ----
  const cronHeader = req.headers.get('x-cron-secret')
  if (cronHeader) {
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || cronHeader !== secret) return fail('Not allowed', 401)
    if (action === 'sync') return json(b.kind === 'event' ? await syncEvent(admin, String(b.id)) : await syncMeeting(admin, String(b.id)))
    if (action === 'delete') return json(await removeZoom(admin, b))
    if (action === 'cron') {
      const { data: due } = await admin.rpc('zoom_due', { p_limit: 10 })
      const done = []
      for (const d of (due ?? []) as { kind: 'meeting' | 'event'; id: string }[]) {
        try {
          done.push({ ...d, ...(await pull(admin, d.kind, d.id)) })
        } catch (e) {
          await admin.from(d.kind === 'meeting' ? 'meetings' : 'events').update({ zoom_error: (e as Error).message, zoom_pull_count: 2 }).eq('id', d.id)
          done.push({ ...d, error: (e as Error).message })
        }
      }
      return json({ done })
    }
    if (action === 'create_adhoc') {
      let acc: Account | null = await loadAccount(admin, b.account)
      if (!acc) {
        const { data } = await admin.from('integrations').select('*').eq('tenant_id', String(b.tenant_id)).eq('provider', 'zoom').eq('is_enabled', true).order('connected_at')
        const rows = (data ?? []) as Row[]
        const pick = rows.find((r) => (r.config as Record<string, string>)?.is_default === 'Yes') ?? rows[0]
        acc = pick ? toAccount(pick) : null
      }
      if (!acc || acc.tenant_id !== b.tenant_id) return fail('No Zoom account switched on. Add one in System Connections.')
      const start = String(b.start ?? '') // "2026-11-02T16:00"
      const date = start.slice(0, 10)
      const time = start.slice(11, 16) || '11:00'
      const dur = Number(b.duration) || 60
      const endMin = Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5)) + dur
      const end = `${String(Math.floor(endMin / 60) % 24).padStart(2, '0')}:${String(endMin % 60).padStart(2, '0')}`
      try {
        return json(await upsertZoom(acc, 'meeting', null, String(b.topic ?? 'Meeting'), date, time, endMin < 24 * 60 ? end : null))
      } catch (e) {
        return fail((e as Error).message)
      }
    }
    return fail('Unknown action')
  }

  // ---- from the app ----
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)

  if (action === 'test') {
    // only people who can read the keys (row security)
    const { data: row } = await asCaller.from('integrations').select('*').eq('id', String(b.id)).eq('provider', 'zoom').maybeSingle()
    if (!row) return fail('Account not found.', 404)
    const acc = toAccount(row)
    tokens.delete(acc.id)
    try {
      const u = await zoom(acc, 'GET', `/users/${hostOf(acc)}`)
      await admin.from('integrations').update({ status: 'connected', last_error: null }).eq('id', acc.id)
      return json({ ok: true, user: { name: [u.first_name, u.last_name].filter(Boolean).join(' '), email: u.email, type: u.type } })
    } catch (e) {
      await admin.from('integrations').update({ status: 'error', last_error: (e as Error).message }).eq('id', acc.id)
      return fail((e as Error).message)
    }
  }

  if (action === 'pull' || action === 'sync') {
    const kind = b.kind === 'event' ? 'event' : 'meeting'
    // the caller must be able to see it
    const { data: seen } = await asCaller.from(kind === 'meeting' ? 'meetings' : 'events').select('id').eq('id', String(b.id)).maybeSingle()
    if (!seen) return fail('Not found.', 404)
    try {
      if (action === 'sync') {
        const r = kind === 'event' ? await syncEvent(admin, String(b.id)) : await syncMeeting(admin, String(b.id))
        return 'error' in r ? fail(String(r.error)) : json(r)
      }
      const r = await pull(admin, kind, String(b.id))
      return 'error' in r ? fail(String(r.error)) : json(r)
    } catch (e) {
      return fail((e as Error).message)
    }
  }
  return fail('Unknown action')
})
