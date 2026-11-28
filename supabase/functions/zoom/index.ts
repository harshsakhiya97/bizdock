// zoom: the workspace's Zoom accounts (Server-to-Server OAuth apps, or connected with Zoom through BizDock's app — zoom-oauth).
//
// From the database (header x-cron-secret):
//   { action: 'sync', kind: 'meeting' | 'event', id }       create / move the Zoom meeting (or webinar) of a CRM meeting / calendar event
//   { action: 'delete', account, zoom_id, kind, clear?, clear_event? }   remove it from Zoom (and clear it on the row)
//   { action: 'cron' }                                        pull attendance / Q&A / chat for everything that has ended
//   { action: 'rec_find' }                                    find the cloud recordings of what ended (→ meeting_recordings)
//   { action: 'rec_work' }                                    copy recordings into storage, then transcript + summary (Gemini)
//   { action: 'create_adhoc', tenant_id, account?, topic, start, duration }   workflow step (no lead) → { id, join_url, password, start_url }
//   { action: 'book_meeting', meeting_id, account?, topic? }  workflow step: the Zoom meeting of a CRM meeting it just added
//   { action: 'register', event_id, email?, first_name, last_name?, phone }   workflow step (Register for webinar): a registrant of the date's
//                                                             Zoom meeting (no email → <phone>@noemail.bizdock.in) → { registrant_id, join_url }
// From the app (the caller's login decides what they may do):
//   { action: 'test', id }                                    check an account's keys (Settings & integrations)
//   { action: 'pull', kind, id }                              fetch attendance / comments now
//   { action: 'start', kind, id }                             Join as the host: a fresh start link (+ the account's host key)
//   { action: 'sync', kind, id }                              retry creating the Zoom meeting
//   { action: 'rec_ai', id, copy? }                           make a recording's transcript / summary again (and copy again)
//
// Anyone with the link (no login):
//   { action: 'watch', tenant_id, zoom_id }                    a meeting's / webinar's recording → { title, recorded_at, duration_sec, video_url, audio_url, summary, transcript }
//                                                             (links valid 6 hours) — <app>/zoom/<meeting-id>
// Keys never reach the browser. Times are India time.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

// deno-lint-ignore no-explicit-any
type Db = SupabaseClient<any, any, any>
/** a connection the caller may manage (row security: System Connections), read with its keys by the server (the browser can't read keys) */
// deno-lint-ignore no-explicit-any
async function ownRow(asCaller: Db, admin: Db, id: string, provider: string, cols: string): Promise<{ data: any }> {
  const { data: ok } = await asCaller.from('integrations').select('id').eq('id', id).eq('provider', provider).maybeSingle()
  if (!ok) return { data: null }
  const { data } = await admin.from('integrations').select(cols).eq('id', (ok as { id: string }).id).maybeSingle()
  return { data }
}

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
  /** connected with Zoom (BizDock's app): its tokens are in zoom_oauth_tokens */
  oauth: boolean
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
  if (a.oauth) return oauthToken(a)
  const res = await fetch(`https://zoom.us/oauth/token?grant_type=account_credentials&account_id=${encodeURIComponent(a.account_id.trim())}`, {
    method: 'POST',
    headers: { Authorization: `Basic ${btoa(`${a.client_id.trim()}:${a.client_secret.trim()}`)}` },
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok || !body.access_token) throw new ZoomError(`Zoom login failed: ${body.reason ?? body.error ?? res.status}. Check the Account ID, Client ID and Client secret.`, res.status)
  tokens.set(a.id, { token: body.access_token, until: Date.now() + (Number(body.expires_in) || 3600) * 1000 })
  return body.access_token
}

/**
 * A connected-with-Zoom account's token: the saved one while it lasts, else renewed with its refresh key (which Zoom
 * replaces each time; if another call renewed it meanwhile, that one is used). Removed from Zoom → "Reconnect".
 */
async function oauthToken(a: Account): Promise<string> {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const read = async () => (await db.from('zoom_oauth_tokens').select('*').eq('integration_id', a.id).maybeSingle()).data as { access_token: string; refresh_token: string; expires_at: string } | null
  const keep = (t: { access_token: string; expires_at: string }) => {
    tokens.set(a.id, { token: t.access_token, until: Date.parse(t.expires_at) })
    return t.access_token
  }
  const reconnect = async (why: string) => {
    const msg = `Zoom connection lost (${why}): press Reconnect in System Connections.`
    await db.from('integrations').update({ status: 'error', last_error: msg }).eq('id', a.id)
    return new ZoomError(msg, 401)
  }
  const t = await read()
  if (!t) throw await reconnect('no login saved')
  if (Date.parse(t.expires_at) > Date.now() + 60_000) return keep(t)
  const id = (Deno.env.get('ZOOM_OAUTH_CLIENT_ID') ?? '').trim()
  const secret = (Deno.env.get('ZOOM_OAUTH_CLIENT_SECRET') ?? '').trim()
  const res = await fetch(`https://zoom.us/oauth/token?grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}`, {
    method: 'POST',
    headers: { Authorization: `Basic ${btoa(`${id}:${secret}`)}` },
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok || !body.access_token) {
    // renewed by another call in the meantime?
    const now = await read()
    if (now && now.refresh_token !== t.refresh_token && Date.parse(now.expires_at) > Date.now() + 60_000) return keep(now)
    throw await reconnect(String(body.reason ?? body.error ?? res.status))
  }
  const next = { access_token: String(body.access_token), refresh_token: String(body.refresh_token ?? t.refresh_token), expires_at: new Date(Date.now() + (Number(body.expires_in) || 3600) * 1000).toISOString() }
  await db.from('zoom_oauth_tokens').update({ ...next, scope: body.scope ?? null, updated_at: new Date().toISOString() }).eq('integration_id', a.id).eq('refresh_token', t.refresh_token)
  return keep(next)
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

/** a lead without an email is registered on Zoom as <phone>@noemail.bizdock.in */
const placeholderEmail = (phone: unknown) => {
  let d = String(phone ?? '').replace(/\D/g, '')
  if (d.startsWith('00')) d = d.slice(2)
  if (d.length === 11 && d.startsWith('0')) d = d.slice(1)
  if (d.length === 10) d = `91${d}`
  return d.length >= 11 ? `${d}@noemail.bizdock.in` : ''
}
const hostOf = (a: Account) => encodeURIComponent((a.host_email ?? '').trim() || 'me')
const hms = (t: string) => (t.length === 5 ? `${t}:00` : t.slice(0, 8))
const minutesBetween = (a: string, b: string) => {
  const [h1, m1] = a.split(':').map(Number)
  const [h2, m2] = b.split(':').map(Number)
  return Math.max(15, h2 * 60 + m2 - (h1 * 60 + m1))
}

// ---------------- create / update / delete ----------------
async function upsertZoom(a: Account, kind: 'meeting' | 'webinar', zoomId: string | null, topic: string, date: string, start: string, end: string | null, registration = false) {
  const body = {
    topic: topic.slice(0, 200),
    type: kind === 'webinar' ? 5 : 2,
    start_time: `${date}T${hms(start)}`,
    timezone: 'Asia/Kolkata',
    duration: end ? minutesBetween(start, end) : 60,
    settings:
      kind === 'webinar'
        ? {
            auto_recording: a.cloud_record ? 'cloud' : 'none',
            question_and_answer: { enable: true },
            // a webinar of a Webinar business: people are registered by the workflow (approved straight away), each with their own link
            ...(registration ? { approval_type: 0 } : {}),
          }
        : registration
          ? {
              // a date of a webinar (Webinar business): a Zoom meeting with registration required, people registered by the
              // workflow (approved straight away, each with their own link); Zoom's own emails off; other settings Zoom's defaults
              approval_type: 0,
              registrants_email_notification: false,
              registrants_confirmation_email: false,
              auto_recording: a.cloud_record ? 'cloud' : 'none',
            }
          : { join_before_host: true, waiting_room: false, auto_recording: a.cloud_record ? 'cloud' : 'none' },
  }
  /** registration form: first name and email (always), last name and phone required too */
  const questions = async (id: string) => {
    if (kind !== 'meeting' || !registration) return
    try {
      await zoom(a, 'PATCH', `/meetings/${id}/registrants/questions`, {
        questions: [
          { field_name: 'last_name', required: true },
          { field_name: 'phone', required: true },
        ],
      })
    } catch (e) {
      console.log('zoom registrant questions', id, (e as Error).message)
    }
  }
  const base = kind === 'webinar' ? 'webinars' : 'meetings'
  if (zoomId) {
    try {
      await zoom(a, 'PATCH', `/${base}/${zoomId}`, body)
      await questions(zoomId)
      const got = await zoom(a, 'GET', `/${base}/${zoomId}`)
      return { id: zoomId, join_url: String(got.join_url ?? ''), start_url: String(got.start_url ?? ''), password: String(got.password ?? '') }
    } catch (e) {
      if (!(e instanceof ZoomError) || (e.status !== 404 && e.code !== 3001)) throw e
      // gone in Zoom (or another account) → create a new one
    }
  }
  const made = await zoom(a, 'POST', `/users/${hostOf(a)}/${base}`, body)
  await questions(String(made.id))
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
    oauth: c.auth === 'oauth',
  }
}

async function loadAccount(admin: SupabaseClient, id: unknown): Promise<Account | null> {
  if (!id) return null
  const { data } = await admin.from('integrations').select('*').eq('id', String(id)).eq('provider', 'zoom').maybeSingle()
  if (!data || !data.is_enabled) return null
  return toAccount(data)
}

/** the workspace's default Zoom account (else the first one switched on) */
async function defaultAccount(admin: SupabaseClient, tenantId: string): Promise<Account | null> {
  const { data } = await admin.from('integrations').select('*').eq('tenant_id', tenantId).eq('provider', 'zoom').eq('is_enabled', true).order('connected_at')
  const rows = (data ?? []) as Row[]
  const pick = rows.find((r) => (r.config as Record<string, string>)?.is_default === 'Yes') ?? rows[0]
  return pick ? toAccount(pick) : null
}

async function syncMeeting(admin: SupabaseClient, id: string) {
  const { data: m } = await admin.from('meetings').select('*, lead:leads(first_name, last_name)').eq('id', id).maybeSingle()
  if (!m || !m.zoom_account_id || m.mode !== 'online' || m.status === 'cancelled') return { skipped: true }
  const a = await loadAccount(admin, m.zoom_account_id)
  if (!a) return { skipped: true }
  const who = [m.lead?.first_name, m.lead?.last_name].filter(Boolean).join(' ') || 'guest'
  // a team (internal) meeting: its title
  const topic = m.kind === 'team' ? String(m.title || 'Team meeting') : `Meeting with ${who}`
  try {
    const z = await upsertZoom(a, 'meeting', m.zoom_meeting_id, topic, m.meeting_date, m.start_time, m.end_time)
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
    const z = await upsertZoom(a, ev.zoom_kind === 'webinar' ? 'webinar' : 'meeting', ev.zoom_webinar_id, topic, ev.event_date, ev.start_time, ev.end_time, !!ev.webinar_id)
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

async function pull(admin: SupabaseClient, kind: 'meeting' | 'event', id: string, manual = false) {
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
    // the report (scope report:read:…:admin); an account connected without it (e.g. Connect with Zoom): the past
    // meeting / webinar participants (scope meeting:read:list_past_participants / webinar:read:list_past_participants)
    const w = isWebinar ? 'webinars' : 'meetings'
    participants = await zoomAll(a, `/report/${w}/${zoomId}/participants`, 'participants').catch((e) =>
      e instanceof ZoomError && /scope/i.test(e.message) ? zoomAll(a, `/past_${w}/${zoomId}/participants`, 'participants') : Promise.reject(e),
    )
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
  // a team (internal) meeting has no leads to match
  if (emails.length && !(kind === 'meeting' && row.kind === 'team')) {
    let q = admin.from('leads').select('id, email').eq('tenant_id', row.tenant_id).in('email', emails)
    if (row.business_id) q = q.eq('business_id', row.business_id)
    const { data: ls } = await q
    for (const l of ls ?? []) leadByEmail.set(norm(l.email), l.id)
  }
  // a webinar date: the leads registered for it (by the email they registered with)
  if (kind === 'event' && row.webinar_id) {
    const { data: regs } = await admin.from('webinar_registrations').select('lead_id, leads(email, phone)').eq('event_id', id)
    for (const r of (regs ?? []) as unknown as { lead_id: string; leads: { email: string | null; phone: string | null } | null }[]) {
      // the email they registered with: their own, else the placeholder from their phone
      for (const e of [norm(r.leads?.email), placeholderEmail(r.leads?.phone)]) if (e && !leadByEmail.has(e)) leadByEmail.set(e, r.lead_id)
    }
  }
  let meetingLead: { id: string; email: string; first: string } | null = null
  if (kind === 'meeting' && row.lead_id) {
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
      : await zoom(a, 'GET', `/report/meetings/${zoomId}/qa`).catch(() => zoom(a, 'GET', `/past_meetings/${zoomId}/qa`))
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

  // 2b. polls (webinars, and the meetings of webinar dates): each answer kept as question → answer
  let pollsFound = false
  if (isWebinar || (kind === 'event' && row.webinar_id)) {
    try {
      const pl = isWebinar
        ? await zoom(a, 'GET', `/past_webinars/${zoomId}/polls`).catch(() => zoom(a, 'GET', `/report/webinars/${zoomId}/polls`))
        : await zoom(a, 'GET', `/past_meetings/${zoomId}/polls`).catch(() => zoom(a, 'GET', `/report/meetings/${zoomId}/polls`))
      pollsFound = true
      for (const q of (pl.questions as Row[]) ?? []) {
        const email = norm(q.email)
        const name = String(q.name ?? '').trim()
        for (const d of (q.question_details as Row[]) ?? []) {
          if (!d.question) continue
          comments.push({
            kind: 'poll',
            name: name || null,
            email: email || null,
            lead_id: leadFor(email, name),
            body: String(d.question),
            answer: d.answer != null ? String(d.answer) : null,
            said_at: d.date_time ? String(d.date_time) : null,
          })
        }
      }
    } catch (e) {
      if (!(e instanceof ZoomError) || (e.status !== 404 && e.code !== 3001 && e.code !== 12702)) notes.push(`Polls: ${(e as Error).message}`)
    }
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
  const pollRows = comments.filter((c) => c.kind === 'poll')
  for (const [k, rows, got] of [['qa', qaRows, qaRows.length > 0], ['chat', chatRows, chatFound], ['poll', pollRows, pollsFound && pollRows.length > 0]] as const) {
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
  // the cloud recording (copied, transcribed and summarised by rec_work)
  let recording = false
  try {
    const f = await findRecording(admin, kind, id)
    recording = f.found
    if (!f.found && f.note && Date.now() - endAt > 30 * 60_000) notes.push(f.note)
    // Refresh: a recording whose video wasn't copied (e.g. it was over the upload limit) is copied again
    if (f.found && manual) {
      const { data: again } = await admin
        .from('meeting_recordings')
        .update({ copy_status: 'waiting', copy_tries: 0 })
        .eq(kind === 'meeting' ? 'meeting_id' : 'event_id', id)
        .eq('source', 'zoom')
        .is('video_path', null)
        .like('copy_error', 'Video not copied%')
        .select('id')
      if (again?.length) notes.push('copying the video again (a few minutes)')
    }
  } catch (e) {
    notes.push(`Recording: ${(e as Error).message}`)
  }
  return { ok: true, attendees: att.length, questions: qaRows.length, polls: pollRows.length, chat: chatRows.length, chat_found: chatFound, recording, notes }
}

// ---------------- recordings (meeting_recordings, bucket meeting-recordings) ----------------
const REC_BUCKET = 'meeting-recordings'
const SUPA_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const VIDEO_PREF = ['shared_screen_with_speaker_view', 'shared_screen_with_speaker_view(CC)', 'active_speaker', 'speaker_view', 'shared_screen_with_gallery_view', 'gallery_view', 'shared_screen']

/** Zoom's recording of a meeting / webinar date → one meeting_recordings row to copy (once its files are ready) */
async function findRecording(admin: SupabaseClient, kind: 'meeting' | 'event', id: string): Promise<{ found: boolean; note?: string }> {
  const table = kind === 'meeting' ? 'meetings' : 'events'
  const { data: row } = await admin.from(table).select('*').eq('id', id).maybeSingle()
  const zoomId = kind === 'meeting' ? row?.zoom_meeting_id : row?.zoom_webinar_id
  if (!row || !zoomId) return { found: false }
  await admin.from(table).update({ rec_checked_at: new Date().toISOString() }).eq('id', id)
  const a = await loadAccount(admin, row.zoom_account_id)
  if (!a) return { found: false }
  let rec: Row
  try {
    rec = await zoom(a, 'GET', `/meetings/${zoomId}/recordings`)
  } catch (e) {
    // 3301: no recording (not recorded, or not cloud recording)
    if (e instanceof ZoomError && (e.status === 404 || e.code === 3301)) return { found: false, note: 'Recording: none on Zoom (was cloud recording on?).' }
    return { found: false, note: `Recording: ${(e as Error).message}` }
  }
  const files = ((rec.recording_files as Row[]) ?? []).filter((f) => f.download_url)
  const media = files.filter((f) => f.file_type === 'MP4' || f.file_type === 'M4A')
  if (!media.length) return { found: false, note: 'Recording: none on Zoom yet.' }
  if (media.some((f) => f.status && f.status !== 'completed')) return { found: false, note: 'Recording: Zoom is still processing it.' }
  const uuid = String(rec.uuid ?? `${zoomId}-${rec.start_time ?? ''}`)
  const { data: have } = await admin.from('meeting_recordings').select('id').eq('tenant_id', row.tenant_id).eq('zoom_uuid', uuid).maybeSingle()
  if (have) return { found: true }
  const keep = files
    .filter((f) => ['MP4', 'M4A', 'TRANSCRIPT'].includes(String(f.file_type)))
    .map((f) => ({ id: f.id, file_type: f.file_type, recording_type: f.recording_type, file_size: f.file_size, file_extension: f.file_extension, download_url: f.download_url }))
  const { error } = await admin.from('meeting_recordings').insert({
    tenant_id: row.tenant_id,
    meeting_id: kind === 'meeting' ? id : null,
    event_id: kind === 'event' ? id : null,
    source: 'zoom',
    title: String(rec.topic ?? row.title ?? 'Zoom recording'),
    zoom_uuid: uuid,
    zoom_files: keep,
    recorded_at: rec.start_time ?? null,
    duration_sec: rec.duration ? Number(rec.duration) * 60 : null,
    copy_status: 'waiting',
    ai_status: 'waiting',
  })
  if (error && !/duplicate/i.test(error.message)) return { found: false, note: `Recording: ${error.message}` }
  return { found: true }
}

/** a file from a URL streamed straight into our bucket (no full copy in memory) → its size */
async function streamToStorage(url: string, path: string, mime: string): Promise<number> {
  const res = await fetch(url)
  if (!res.ok || !res.body) throw new Error(`download answered ${res.status}`)
  const len = res.headers.get('content-length')
  const up = await fetch(`${SUPA_URL}/storage/v1/object/${REC_BUCKET}/${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY, 'Content-Type': mime, 'x-upsert': 'true', ...(len ? { 'Content-Length': len } : {}) },
    body: res.body,
    duplex: 'half',
  } as RequestInit)
  if (!up.ok) {
    const t = await up.text().catch(() => '')
    if (up.status === 413 || /maximum allowed size|too large/i.test(t))
      throw new Error('the file is bigger than the storage upload limit (Supabase → Storage → Settings → Upload file size limit)')
    throw new Error(`storage answered ${up.status} ${t.slice(0, 200)}`)
  }
  return Number(len) || 0
}

/** Zoom's transcript (WebVTT) as readable lines: [mm:ss] Name: text */
function vttText(vtt: string) {
  const out: string[] = []
  for (const block of vtt.replace(/\r/g, '').split(/\n\n+/)) {
    const lines = block.split('\n').filter(Boolean)
    const ti = lines.findIndex((l) => l.includes('-->'))
    if (ti < 0) continue
    const m = /(\d+):(\d+):(\d+)/.exec(lines[ti])
    const at = m ? `${String(Number(m[1]) * 60 + Number(m[2])).padStart(2, '0')}:${m[3]}` : ''
    const text = lines.slice(ti + 1).join(' ').trim()
    if (text) out.push(`[${at}] ${text}`)
  }
  return out.join('\n')
}

const REC_PROMPT = `This is the recording of a business meeting in India (usually a sales or client meeting; it may be in Hindi, English or Hinglish).
Return JSON with:
- "transcript": the full conversation, one line per turn: "[mm:ss] Speaker: words". Use people's names when they are said, else "Host" / "Client" / "Speaker 1". Write Hindi in Roman script (Hinglish), as spoken.
- "summary": in simple English, Markdown bullets under these bold headings: **Purpose**, **Key points**, **What the client asked / objections**, **Prices and offers mentioned**, **Decisions**, **Next steps** (who does what, by when). Use only what was said; write "—" where nothing was said.`
const SUMMARY_PROMPT = `Below is the transcript of a business meeting in India (it may be in Hindi, English or Hinglish).
Return JSON with "summary": in simple English, Markdown bullets under these bold headings: **Purpose**, **Key points**, **What the client asked / objections**, **Prices and offers mentioned**, **Decisions**, **Next steps** (who does what, by when). Use only what was said; write "—" where nothing was said.

TRANSCRIPT:
`

/** the workspace's Gemini connection, or why AI can't run */
async function geminiFor(admin: SupabaseClient, tenantId: string) {
  const { data: conn } = await admin.from('integrations').select('id, config').eq('tenant_id', tenantId).eq('provider', 'gemini').eq('is_enabled', true).order('updated_at', { ascending: false }).limit(1).maybeSingle()
  const cfg = (conn?.config ?? {}) as Record<string, string>
  const key = String(cfg.api_key ?? '').trim()
  if (!conn || !key) return { error: 'Connect Gemini AI in System Connections for the transcript and summary.' }
  const limit = Number(cfg.monthly_limit || 0)
  if (limit > 0) {
    const ist = new Date(Date.now() + 330 * 60_000)
    const start = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), 1) - 330 * 60_000).toISOString()
    const { data } = await admin.from('ai_usage').select('input_tokens, output_tokens').eq('tenant_id', tenantId).not('model', 'ilike', 'claude%').gte('created_at', start).limit(100000)
    const rows = (data ?? []) as { input_tokens: number; output_tokens: number }[]
    const spent = rows.reduce((t, r) => t + Number(r.input_tokens) * Number(cfg.price_in || 0) + Number(r.output_tokens) * Number(cfg.price_out || 0), 0) / 1e6
    if (spent >= limit) return { error: `This month’s AI limit (₹${limit}) is used up.` }
  }
  return { id: String(conn.id), key, model: String(cfg.model || 'gemini-flash-latest') }
}

/** our stored file → Gemini's Files API (streamed), ready to use */
async function toGemini(key: string, path: string, size: number, mime: string) {
  if (!size) {
    const info = await fetch(`${SUPA_URL}/storage/v1/object/info/${REC_BUCKET}/${path}`, { headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY } })
    const j = await info.json().catch(() => ({}))
    size = Number(j?.size ?? j?.metadata?.size ?? 0)
  }
  if (!size) throw new Error('could not read the file size')
  const start = await fetch(`https://generativelanguage.googleapis.com/upload/v1beta/files`, {
    method: 'POST',
    headers: {
      'x-goog-api-key': key,
      'X-Goog-Upload-Protocol': 'resumable',
      'X-Goog-Upload-Command': 'start',
      'X-Goog-Upload-Header-Content-Length': String(size),
      'X-Goog-Upload-Header-Content-Type': mime,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ file: { display_name: path.split('/').pop() } }),
  })
  const uploadUrl = start.headers.get('x-goog-upload-url')
  if (!start.ok || !uploadUrl) throw new Error(`Gemini upload: ${start.status} ${(await start.text()).slice(0, 200)}`)
  const src = await fetch(`${SUPA_URL}/storage/v1/object/${REC_BUCKET}/${path}`, { headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY } })
  if (!src.ok || !src.body) throw new Error(`reading the recording: ${src.status}`)
  const up = await fetch(uploadUrl, {
    method: 'POST',
    headers: { 'Content-Length': String(size), 'X-Goog-Upload-Offset': '0', 'X-Goog-Upload-Command': 'upload, finalize' },
    body: src.body,
    duplex: 'half',
  } as RequestInit)
  const j = await up.json().catch(() => ({}))
  type GFile = { name: string; uri: string; state?: string; mimeType?: string }
  if (!up.ok || !j?.file?.uri) throw new Error(`Gemini upload: ${up.status} ${JSON.stringify(j).slice(0, 200)}`)
  let file = j.file as GFile
  for (let i = 0; i < 40 && file.state === 'PROCESSING'; i++) {
    await new Promise((r) => setTimeout(r, 3000))
    file = await (await fetch(`https://generativelanguage.googleapis.com/v1beta/${file.name}`, { headers: { 'x-goog-api-key': key } })).json()
  }
  if (file.state === 'FAILED') throw new Error('Gemini could not read the recording')
  return file
}

async function geminiJson(g: { key: string; model: string }, parts: unknown[], props: Record<string, unknown>) {
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(g.model)}:generateContent`, {
    method: 'POST',
    headers: { 'x-goog-api-key': g.key, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      contents: [{ role: 'user', parts }],
      generationConfig: { temperature: 0.2, maxOutputTokens: 60000, responseMimeType: 'application/json', responseSchema: { type: 'OBJECT', properties: props, required: Object.keys(props) } },
    }),
  })
  const d = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(d?.error?.message ? `Gemini: ${d.error.message}` : `Gemini error ${r.status}`)
  const text = ((d?.candidates?.[0]?.content?.parts ?? []) as { text?: string; thought?: boolean }[]).filter((p) => !p.thought).map((p) => p.text ?? '').join('')
  const u = d?.usageMetadata ?? {}
  let out: Record<string, string> = {}
  try {
    out = JSON.parse(text)
  } catch {
    throw new Error(`Gemini gave no usable answer (${d?.candidates?.[0]?.finishReason ?? 'empty'})`)
  }
  return { out, inTok: Number(u.promptTokenCount ?? 0), outTok: Number(u.candidatesTokenCount ?? 0) + Number(u.thoughtsTokenCount ?? 0) }
}

const extOf = (p: string) => p.split('.').pop()?.toLowerCase() ?? ''
const mimeOf = (p: string) => ({ mp4: 'video/mp4', m4a: 'audio/mp4', mp3: 'audio/mpeg', wav: 'audio/wav', webm: 'video/webm', mov: 'video/quicktime', ogg: 'audio/ogg', aac: 'audio/aac' })[extOf(p)] ?? 'application/octet-stream'

/** one claimed recording: copy its files, then the transcript and summary (and the note on the lead) */
async function workRecording(admin: SupabaseClient, id: string, deadline: number) {
  const { data: r } = await admin.from('meeting_recordings').select('*').eq('id', id).maybeSingle()
  if (!r) return
  // 1. copy from Zoom
  if (r.copy_status === 'waiting') {
    try {
      const parent = r.meeting_id
        ? (await admin.from('meetings').select('zoom_account_id').eq('id', r.meeting_id).maybeSingle()).data
        : (await admin.from('events').select('zoom_account_id').eq('id', r.event_id).maybeSingle()).data
      const a = await loadAccount(admin, parent?.zoom_account_id)
      if (!a) throw new Error('its Zoom account was removed or switched off')
      const files = (r.zoom_files ?? []) as Row[]
      const withToken = async (u: unknown) => `${u}${String(u).includes('?') ? '&' : '?'}access_token=${await tokenFor(a)}`
      const d = new Date(r.recorded_at ?? r.created_at)
      const base = `${r.tenant_id}/${d.getUTCFullYear()}/${String(d.getUTCMonth() + 1).padStart(2, '0')}/${r.id}`
      const patch: Row = {}
      const notes: string[] = []
      const audio = files.find((f) => f.file_type === 'M4A')
      if (audio) {
        patch.audio_size = (await streamToStorage(await withToken(audio.download_url), `${base}-audio.m4a`, 'audio/mp4')) || Number(audio.file_size) || null
        patch.audio_path = `${base}-audio.m4a`
      }
      const videos = files.filter((f) => f.file_type === 'MP4')
      const video = VIDEO_PREF.map((t) => videos.find((f) => f.recording_type === t)).find(Boolean) ?? videos[0]
      if (video) {
        try {
          patch.video_size = (await streamToStorage(await withToken(video.download_url), `${base}-video.mp4`, 'video/mp4')) || Number(video.file_size) || null
          patch.video_path = `${base}-video.mp4`
        } catch (e) {
          // the audio is enough for the transcript; the video can be retried later
          if (!audio) throw e
          notes.push(`Video not copied: ${(e as Error).message}`)
        }
      }
      const vtt = files.find((f) => f.file_type === 'TRANSCRIPT')
      if (vtt) {
        const t = await fetch(await withToken(vtt.download_url))
        if (t.ok) patch.transcript = vttText(await t.text()) || null
      }
      await admin.from('meeting_recordings').update({ ...patch, copy_status: 'done', copy_error: notes.join(' · ') || null }).eq('id', id)
      Object.assign(r, patch, { copy_status: 'done' })
    } catch (e) {
      const tries = Number(r.copy_tries) + 1
      await admin.from('meeting_recordings').update({ copy_tries: tries, copy_error: (e as Error).message.slice(0, 300), copy_status: tries >= 5 ? 'error' : 'waiting' }).eq('id', id)
      return
    }
  }
  // 2. transcript and summary
  if (r.copy_status !== 'done' || r.ai_status !== 'waiting' || Date.now() > deadline - 150_000) return
  const g = await geminiFor(admin, r.tenant_id)
  if ('error' in g) {
    await admin.from('meeting_recordings').update({ ai_status: 'skipped', ai_error: g.error }).eq('id', id)
    return
  }
  let gfile: { name: string; uri: string; mimeType?: string } | null = null
  try {
    let transcript = String(r.transcript ?? '').trim()
    let summary = ''
    let inTok = 0
    let outTok = 0
    if (transcript) {
      const res = await geminiJson(g, [{ text: SUMMARY_PROMPT + transcript.slice(0, 600_000) }], { summary: { type: 'STRING' } })
      summary = String(res.out.summary ?? '')
      inTok = res.inTok
      outTok = res.outTok
    } else {
      const path = String(r.audio_path || r.video_path || '')
      if (!path) {
        await admin.from('meeting_recordings').update({ ai_status: 'skipped', ai_error: 'No recording file to read (a link only).' }).eq('id', id)
        return
      }
      const size = Number((r.audio_path ? r.audio_size : r.video_size) ?? 0)
      const gf = await toGemini(g.key, path, size, mimeOf(path))
      gfile = gf
      const res = await geminiJson(g, [{ file_data: { mime_type: gf.mimeType ?? mimeOf(path), file_uri: gf.uri } }, { text: REC_PROMPT }], { transcript: { type: 'STRING' }, summary: { type: 'STRING' } })
      transcript = String(res.out.transcript ?? '')
      summary = String(res.out.summary ?? '')
      inTok = res.inTok
      outTok = res.outTok
    }
    await admin.from('ai_usage').insert({ tenant_id: r.tenant_id, integration_id: g.id, model: g.model, feature: 'meeting_summary', input_tokens: inTok, output_tokens: outTok, member_id: null })
    await admin.from('meeting_recordings').update({ transcript: transcript || null, summary: summary || null, ai_status: 'done', ai_error: null, ai_at: new Date().toISOString() }).eq('id', id)
    // the summary as a note on the meeting's lead (once)
    if (summary && r.meeting_id && !r.note_added) {
      const { data: m } = await admin.from('meetings').select('lead_id, meeting_date, kind').eq('id', r.meeting_id).maybeSingle()
      if (m?.lead_id && m.kind !== 'team') {
        const day = new Date(`${m.meeting_date}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })
        await admin.from('lead_activities').insert({ tenant_id: r.tenant_id, lead_id: m.lead_id, kind: 'note', note: `Meeting summary (${day}, from the recording)\n\n${summary}` })
        await admin.from('meeting_recordings').update({ note_added: true }).eq('id', id)
      }
    }
  } catch (e) {
    const tries = Number(r.ai_tries) + 1
    await admin.from('meeting_recordings').update({ ai_tries: tries, ai_error: (e as Error).message.slice(0, 300), ai_status: tries >= 3 ? 'error' : 'waiting' }).eq('id', id)
  } finally {
    if (gfile?.name) await fetch(`https://generativelanguage.googleapis.com/v1beta/${gfile.name}`, { method: 'DELETE', headers: { 'x-goog-api-key': g.key } }).catch(() => null)
  }
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
    if (action === 'rec_find') {
      const { data: due } = await admin.rpc('recording_due', { p_limit: 10 })
      const done = []
      for (const d of (due ?? []) as { kind: 'meeting' | 'event'; id: string }[]) {
        try {
          done.push({ ...d, ...(await findRecording(admin, d.kind, d.id)) })
        } catch (e) {
          done.push({ ...d, error: (e as Error).message })
        }
      }
      return json({ done })
    }
    if (action === 'rec_work') {
      // up to ~4.5 minutes: claim a recording, work on it, let it go, next
      const deadline = Date.now() + 270_000
      let n = 0
      while (Date.now() < deadline - 60_000) {
        const { data: id } = await admin.rpc('recording_claim')
        if (!id) break
        try {
          await workRecording(admin, String(id), deadline)
        } finally {
          await admin.from('meeting_recordings').update({ lease_until: null }).eq('id', String(id))
        }
        n++
      }
      return json({ worked: n })
    }
    if (action === 'book_meeting') {
      const { data: m } = await admin.from('meetings').select('*, lead:leads(first_name, last_name)').eq('id', String(b.meeting_id)).maybeSingle()
      if (!m) return fail('Meeting not found.')
      let acc: Account | null = await loadAccount(admin, b.account)
      if (!acc) acc = await defaultAccount(admin, m.tenant_id)
      if (!acc || acc.tenant_id !== m.tenant_id) return fail('No Zoom account switched on. Add one in System Connections.')
      const who = [m.lead?.first_name, m.lead?.last_name].filter(Boolean).join(' ') || 'guest'
      try {
        const z = await upsertZoom(acc, 'meeting', null, String(b.topic || `Meeting with ${who}`), m.meeting_date, m.start_time, m.end_time)
        await admin
          .from('meetings')
          .update({ zoom_account_id: acc.id, zoom_meeting_id: z.id, link: z.join_url, zoom_start_url: z.start_url, zoom_password: z.password, zoom_error: null })
          .eq('id', m.id)
        return json(z)
      } catch (e) {
        await admin.from('meetings').update({ zoom_account_id: acc.id, zoom_error: (e as Error).message }).eq('id', m.id)
        return fail((e as Error).message)
      }
    }
    if (action === 'register') {
      // Register for webinar: the lead on this date's Zoom webinar → their own join link
      const { data: ev } = await admin.from('events').select('*').eq('id', String(b.event_id ?? '')).maybeSingle()
      if (!ev) return fail('Webinar date not found.')
      if (!ev.zoom_webinar_id) return fail(ev.zoom_error ? `The Zoom webinar isn't made yet: ${ev.zoom_error}` : "The Zoom webinar isn't made yet.")
      const acc = await loadAccount(admin, ev.zoom_account_id)
      if (!acc) return fail('The webinar’s Zoom account was removed or switched off.')
      // no email → a placeholder from the phone (Zoom's own emails are off); no last name → "-"
      let email = String(b.email ?? '').trim().toLowerCase()
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) email = placeholderEmail(b.phone)
      if (!email) return fail('The lead has no email or phone: Zoom needs one to register them.')
      const body: Row = {
        email,
        first_name: String(b.first_name ?? '').trim().slice(0, 64) || 'Guest',
        last_name: String(b.last_name ?? '').trim().slice(0, 64) || '-',
        phone: String(b.phone ?? '').trim() || '-',
      }
      try {
        const r = await zoom(acc, 'POST', `/${ev.zoom_kind === 'webinar' ? 'webinars' : 'meetings'}/${ev.zoom_webinar_id}/registrants`, body)
        if (!r.join_url) return fail('Zoom gave no join link for the registration.')
        return json({ registrant_id: String(r.registrant_id ?? r.id ?? ''), join_url: String(r.join_url) })
      } catch (e) {
        return fail((e as Error).message)
      }
    }
    if (action === 'create_adhoc') {
      let acc: Account | null = await loadAccount(admin, b.account)
      if (!acc) acc = await defaultAccount(admin, String(b.tenant_id))
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

  // ---- anyone with the link: <app>/zoom/<meeting-id> ----
  if (action === 'watch') {
    const zid = String(b.zoom_id ?? '').replace(/\D/g, '')
    const tid = String(b.tenant_id ?? '')
    if (zid.length < 9 || !/^[0-9a-f-]{36}$/i.test(tid)) return fail('Recording not found.', 404)
    const [{ data: m }, { data: ev }] = await Promise.all([
      admin.from('meetings').select('id').eq('tenant_id', tid).eq('zoom_meeting_id', zid).limit(1).maybeSingle(),
      admin.from('events').select('id').eq('tenant_id', tid).eq('zoom_webinar_id', zid).limit(1).maybeSingle(),
    ])
    if (!m && !ev) return fail('Recording not found.', 404)
    const { data: rec } = await admin
      .from('meeting_recordings')
      .select('title, recorded_at, duration_sec, video_path, audio_path, summary, transcript')
      .eq('tenant_id', tid)
      .eq(m ? 'meeting_id' : 'event_id', (m ?? ev)!.id)
      .eq('copy_status', 'done')
      .order('recorded_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    if (!rec || (!rec.video_path && !rec.audio_path)) return fail('The recording isn’t ready yet — please check again a little later.', 404)
    const sign = async (path: string | null) => (path ? (await admin.storage.from(REC_BUCKET).createSignedUrl(path, 6 * 3600)).data?.signedUrl ?? null : null)
    return json({ title: rec.title, recorded_at: rec.recorded_at, duration_sec: rec.duration_sec, video_url: await sign(rec.video_path), audio_url: await sign(rec.audio_path), summary: rec.summary ?? null, transcript: rec.transcript ?? null })
  }

  // ---- from the app ----
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)

  if (action === 'test') {
    // only people who can read the keys (row security)
    const { data: row } = await ownRow(asCaller, admin, String(b.id), 'zoom', '*')
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

  if (action === 'rec_ai') {
    // the caller must be able to see the recording; it's queued (the worker runs every minute)
    const { data: seen } = await asCaller.from('meeting_recordings').select('id').eq('id', String(b.id)).maybeSingle()
    if (!seen) return fail('Not found.', 404)
    await admin.from('meeting_recordings').update({ ai_status: 'waiting', ai_tries: 0, ai_error: null, ...(b.copy ? { copy_status: 'waiting', copy_tries: 0, copy_error: null } : {}) }).eq('id', String(b.id))
    return json({ ok: true })
  }

  if (action === 'start') {
    // Join (as the host): Zoom's start link lasts ~2 hours, so a fresh one each time; plus the host key to claim host
    const kind = b.kind === 'event' ? 'event' : 'meeting'
    const table = kind === 'meeting' ? 'meetings' : 'events'
    const { data: seen } = await asCaller.from(table).select('id').eq('id', String(b.id)).maybeSingle()
    if (!seen) return fail('Not found.', 404)
    const { data: row } = await admin.from(table).select('*').eq('id', String(b.id)).maybeSingle()
    const zoomId = kind === 'meeting' ? row?.zoom_meeting_id : row?.zoom_webinar_id
    const a = await loadAccount(admin, row?.zoom_account_id)
    if (!row || !zoomId || !a) return fail('No Zoom meeting on this one.')
    const { data: integ } = await admin.from('integrations').select('config').eq('id', a.id).maybeSingle()
    const hostKey = String((integ?.config as Row | null)?.host_key ?? '').trim() || null
    try {
      const m = await zoom(a, 'GET', `/${kind === 'event' && row.zoom_kind === 'webinar' ? 'webinars' : 'meetings'}/${zoomId}`)
      const startUrl = String(m.start_url ?? '')
      return json({ start_url: startUrl || null, join_url: m.join_url ?? null, host_key: hostKey })
    } catch (e) {
      return json({ start_url: null, join_url: null, host_key: hostKey, error: (e as Error).message })
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
      const r = await pull(admin, kind, String(b.id), true)
      return 'error' in r ? fail(String(r.error)) : json(r)
    } catch (e) {
      return fail((e as Error).message)
    }
  }
  return fail('Unknown action')
})
