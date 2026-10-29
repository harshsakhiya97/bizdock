// workflow-runner: runs workflows step by step (first version).
//
//   POST { action: 'cron' } + header x-cron-secret   → takes the due runs and moves each one forward
//     (called by pg_cron every minute and straight after a form submission starts a run;
//      the secret lives in the vault: public.workflow_cron_secret())
//
// Steps done now: WhatsApp (approved template through WATI), Bulk WhatsApp (several templates, each a set
// time after the run started, with an optional stop condition), Generate link (<app>/<code> for the lead,
// kept for later steps as {{generated_link}}), Create Zoom meeting ({{zoom_link}}, optionally as a short link) and Wait. Email, Call, Wait for event and
// Go to workflow are skipped (logged), Yes/No and Switch stop the run — they come later.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

type Node = { id: string; type: string; data: Record<string, unknown> }
type Edge = { source: string; target: string; sourceHandle?: string | null }
type Run = {
  id: string
  tenant_id: string
  workflow_id: string
  lead_id: string | null
  submission_id: string | null
  node_id: string
  log: LogLine[]
  /** started by hand with typed-in details (Test run) */
  is_test: boolean
  test_data: Record<string, string> | null
  /** started by a post to the workflow's own webhook: the post's fields (no lead) */
  payload: Record<string, unknown> | null
  created_at: string
  /** progress inside a step that runs over time */
  state: { bulk?: { node: string; i: number } | null; vars?: Record<string, string> } | null
}
type LogLine = { at: string; node_id: string; kind: string; status: 'ok' | 'skipped' | 'failed' | 'waiting' | 'stopped'; detail: string }

const MAX_STEPS = 25
/** a field name as a message variable: "Company Name" → company_name (same as the builder) */
const varKey = (k: string) => k.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')
const extraVars = (o: Record<string, unknown> | null | undefined) =>
  Object.fromEntries(Object.entries(o ?? {}).filter(([, v]) => v != null && typeof v !== 'object').map(([k, v]) => [varKey(k), String(v)]))
const UNIT_MS: Record<string, number> = { minutes: 60_000, hours: 3_600_000, days: 86_400_000 }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: secret } = await admin.rpc('workflow_cron_secret')
  if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'Not allowed' }, 401)

  let done = 0
  // a few batches per call, so a burst of submissions doesn't wait for the next minute
  for (let batch = 0; batch < 4; batch++) {
    const { data: runs, error } = await admin.rpc('workflow_claim_runs', { p_limit: 25 })
    if (error) return json({ error: error.message }, 500)
    if (!runs?.length) break
    for (const run of runs as Run[]) {
      try {
        await advance(admin, run)
      } catch (e) {
        await admin.from('workflow_runs').update({ status: 'failed', error: (e as Error).message, updated_at: new Date().toISOString() }).eq('id', run.id)
      }
      done++
    }
  }
  return json({ ok: true, runs: done })
})

async function advance(admin: SupabaseClient, run: Run) {
  const log: LogLine[] = Array.isArray(run.log) ? [...run.log] : []
  const note = (n: Node, status: LogLine['status'], detail: string) =>
    log.push({ at: new Date().toISOString(), node_id: n.id, kind: n.type, status, detail })
  const state = { ...(run.state ?? {}) }
  const save = (patch: Record<string, unknown>) =>
    admin.from('workflow_runs').update({ ...patch, log, state, updated_at: new Date().toISOString() }).eq('id', run.id)

  const { data: wf } = await admin.from('workflows').select('id, name, is_active, archived_at, nodes, edges, funnel_id').eq('id', run.workflow_id).maybeSingle()
  if (!wf) return save({ status: 'stopped', error: 'The workflow was deleted.' })
  if (wf.archived_at) return save({ status: 'stopped', error: 'The workflow was deleted.' })
  // a test run works while the workflow is off
  if (!wf.is_active && !run.is_test) return save({ status: 'stopped', error: 'The workflow was switched off.' })
  const nodes = (wf.nodes ?? []) as Node[]
  const edges = (wf.edges ?? []) as Edge[]
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const nextOf = (id: string) => {
    const e = edges.find((x) => x.source === id && !x.sourceHandle) ?? edges.find((x) => x.source === id)
    return e ? byId.get(e.target) ?? null : null
  }

  const ctx = await context(admin, run, (wf.funnel_id as string | null) ?? null)
  // values made by earlier steps of this run (generated links)
  Object.assign(ctx.vars, state.vars ?? {})
  let at = run.node_id
  // waiting inside a Bulk WhatsApp step: carry on with that step
  let resume = byId.get(at)?.type === 'bulk_whatsapp' && state.bulk?.node === at
  for (let i = 0; i < MAX_STEPS; i++) {
    const n = resume ? byId.get(at)! : nextOf(at)
    resume = false
    if (!n) return save({ status: 'done', node_id: at, error: null })
    const d = n.data ?? {}

    if (n.type === 'whatsapp') {
      try {
        const detail = await sendWhatsApp(admin, run, wf.name as string, d, ctx)
        note(n, 'ok', detail)
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
    } else if (n.type === 'bulk_whatsapp') {
      // messages in time order; each one is due this long after the run started
      const rows = ((d.rows ?? []) as Record<string, unknown>[])
        .map((r, idx) => ({ r, idx, min: (Number(r.amount) || 0) * ((UNIT_MS[String(r.unit)] ?? UNIT_MS.minutes) / 60_000) }))
        .sort((a, b) => a.min - b.min || a.idx - b.idx)
      const start = new Date(run.created_at).getTime()
      let k = state.bulk && state.bulk.node === n.id ? state.bulk.i : 0
      while (k < rows.length) {
        if (d.stop_on && run.lead_id && !run.is_test && (await matches(admin, run.lead_id, d.stop as Cond))) {
          note(n, 'stopped', `Stop condition met before message ${k + 1} of ${rows.length}; the rest aren't sent.`)
          state.bulk = null
          return save({ status: 'stopped', node_id: n.id, error: null })
        }
        const due = start + rows[k].min * 60_000
        if (due > Date.now() + 5_000) {
          state.bulk = { node: n.id, i: k }
          note(n, 'waiting', `Message ${k + 1} of ${rows.length} at ${new Date(due).toISOString()}`)
          return save({ status: 'waiting', node_id: n.id, next_at: new Date(due).toISOString() })
        }
        try {
          const detail = await sendWhatsApp(admin, run, wf.name as string, rows[k].r, ctx)
          note(n, 'ok', `${k + 1}/${rows.length}: ${detail}`)
        } catch (e) {
          // one message failing doesn't stop the rest
          note(n, 'failed', `${k + 1}/${rows.length}: ${(e as Error).message}`)
        }
        k++
      }
      state.bulk = null
    } else if (n.type === 'generate_link' || n.type === 'short_link') {
      try {
        const made = await makeShortLink(admin, run, d, ctx)
        state.vars = { ...(state.vars ?? {}), ...made.vars }
        Object.assign(ctx.vars, made.vars)
        note(n, 'ok', `Made ${made.short} → ${made.url}`)
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
    } else if (n.type === 'zoom_meeting') {
      try {
        const made = await makeZoomMeeting(admin, run, n, d, ctx)
        // the Zoom link (with its passcode) as a short link too ({{zoom_short_link}}, {{zoom_short_link_code}})
        const short = d.short_link ? await makeShortLink(admin, run, { url: made.vars.zoom_link, var: 'zoom_short_link', base_url: d.base_url }, ctx) : null
        const vars: Record<string, string> = { ...made.vars, ...(short?.vars ?? {}) }
        state.vars = { ...(state.vars ?? {}), ...vars }
        Object.assign(ctx.vars, vars)
        note(n, 'ok', `Meeting on ${made.when}${made.host ? ` with ${made.host}` : ''} · Zoom ${made.id}: ${made.vars.zoom_link}${short ? ` · short link ${short.short}` : ''}`)
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
    } else if (n.type === 'wait') {
      const ms = Math.max(1, Number(d.amount) || 1) * (UNIT_MS[String(d.unit)] ?? UNIT_MS.days)
      const until = new Date(Date.now() + ms)
      note(n, 'waiting', `Waiting until ${until.toISOString()}`)
      return save({ status: 'waiting', node_id: n.id, next_at: until.toISOString() })
    } else if (n.type === 'condition' || n.type === 'switch') {
      note(n, 'stopped', 'Yes / No and Switch steps are not running yet.')
      return save({ status: 'stopped', node_id: n.id, error: 'Reached a Switch step (not running yet).' })
    } else {
      note(n, 'skipped', `${n.type} steps are not running yet.`)
    }
    at = n.id
  }
  return save({ status: 'stopped', node_id: at, error: 'Too many steps in one go.' })
}

type Cond = { field: string; op: string; value: string }

/** older saved conditions ("is" / "is not", "Form field is filled") in today's terms */
function normalizeCond(c: Cond): Cond {
  if (c.field === 'field_filled') return { field: `x:${c.value}`, op: c.op === 'is_not' ? 'empty' : 'not_empty', value: '' }
  return { field: c.field, op: c.op === 'is' ? 'eq' : c.op === 'is_not' ? 'neq' : c.op, value: String(c.value ?? '') }
}

const LEAD_COLS: Record<string, string> = {
  first_name: 'first_name', last_name: 'last_name', phone: 'phone', email: 'email', city: 'city', purpose: 'purpose', notes: 'notes',
  stage: 'stage_id', source: 'source_id', owner: 'owner_id', temperature: 'temperature',
  estimated_amount: 'estimated_amount', required_hours: 'required_hours', required_on: 'required_on', created_at: 'created_at',
  utm_source: 'utm_source', utm_medium: 'utm_medium', utm_campaign: 'utm_campaign', utm_term: 'utm_term', utm_content: 'utm_content',
}
const NUMBER_FIELDS = new Set(['estimated_amount', 'required_hours'])
const DATE_FIELDS = new Set(['required_on', 'created_at'])

/**
 * Does the lead (as it is now) match a condition: any lead field or extra field (equals, not equals, empty,
 * not empty, and > >= < <= for numbers / dates), its tags, or whether it has a meeting / a payment.
 */
async function matches(admin: SupabaseClient, leadId: string, raw: Cond | undefined) {
  if (!raw?.field) return false
  const c = normalizeCond(raw)
  const op = c.op

  if (c.field === 'meeting' || c.field === 'payment') {
    let has = false
    if (c.field === 'meeting') {
      const { count } = await admin.from('meetings').select('id', { count: 'exact', head: true }).eq('lead_id', leadId).neq('status', 'cancelled')
      has = (count ?? 0) > 0
    } else {
      const { data: bk } = await admin.from('bookings').select('id').eq('lead_id', leadId).neq('status', 'cancelled')
      const ids = (bk ?? []).map((b) => b.id as string)
      if (ids.length) {
        const { count } = await admin.from('booking_payments').select('id', { count: 'exact', head: true }).in('booking_id', ids).eq('status', 'paid')
        has = (count ?? 0) > 0
      }
      if (!has) {
        const { count } = await admin.from('lead_submissions').select('id', { count: 'exact', head: true }).eq('lead_id', leadId).eq('result', 'payment')
        has = (count ?? 0) > 0
      }
    }
    return op === 'not_exists' ? !has : has
  }
  if (c.field === 'attendance') return false // not tracked yet

  const { data: l } = await admin.from('leads').select('*').eq('id', leadId).maybeSingle()
  if (!l) return false
  const lead = l as Record<string, unknown>

  if (c.field === 'tag') {
    const tags = ((lead.tags ?? []) as string[]).map((t) => t.trim().toLowerCase())
    if (op === 'empty') return tags.length === 0
    if (op === 'not_empty') return tags.length > 0
    const has = tags.includes(c.value.trim().toLowerCase())
    return op === 'neq' ? !has : has
  }

  // the lead's value for the field
  let v: string
  if (c.field === 'name') v = [lead.first_name, lead.last_name].filter(Boolean).join(' ')
  else if (c.field === 'landing_page') v = String(lead.webhook_id ?? lead.landing_page_id ?? '')
  else if (c.field.startsWith('x:')) {
    const key = c.field.slice(2)
    const extra = (lead.extra ?? {}) as Record<string, unknown>
    const hit = extra[key] ?? Object.entries(extra).find(([k]) => varKey(k) === varKey(key))?.[1] ?? lead[key]
    v = hit == null || typeof hit === 'object' ? '' : String(hit)
  } else if (c.field === 'created_at') {
    // the day it was added, India time
    v = lead.created_at ? new Date(new Date(String(lead.created_at)).getTime() + 330 * 60_000).toISOString().slice(0, 10) : ''
  } else v = String(lead[LEAD_COLS[c.field] ?? c.field] ?? '')
  v = v.trim()
  const want = c.value.trim()

  if (op === 'empty') return v === ''
  if (op === 'not_empty') return v !== ''
  if (c.field === 'landing_page' && op === 'eq') return lead.webhook_id === want || lead.landing_page_id === want
  if (c.field === 'landing_page' && op === 'neq') return lead.webhook_id !== want && lead.landing_page_id !== want

  const isDate = DATE_FIELDS.has(c.field)
  const isNum = NUMBER_FIELDS.has(c.field) || (c.field.startsWith('x:') && ['gt', 'gte', 'lt', 'lte'].includes(op))
  if (['gt', 'gte', 'lt', 'lte'].includes(op) || ((isNum || isDate) && (op === 'eq' || op === 'neq'))) {
    if (v === '') return op === 'neq'
    let a: number
    let b: number
    if (isDate) {
      a = Date.parse(`${v.slice(0, 10)}T00:00:00Z`)
      b = Date.parse(`${want.slice(0, 10)}T00:00:00Z`)
    } else {
      a = Number(v.replace(/[,\s₹]/g, ''))
      b = Number(want.replace(/[,\s₹]/g, ''))
    }
    if (Number.isNaN(a) || Number.isNaN(b)) return op === 'neq'
    if (op === 'eq') return a === b
    if (op === 'neq') return a !== b
    if (op === 'gt') return a > b
    if (op === 'gte') return a >= b
    if (op === 'lt') return a < b
    return a <= b
  }

  // text: no case; phone numbers by their last 10 digits
  const same =
    c.field === 'phone' ? v.replace(/\D/g, '').slice(-10) === want.replace(/\D/g, '').slice(-10) : v.toLowerCase() === want.toLowerCase()
  return op === 'neq' ? !same : same
}

type Ctx = { vars: Record<string, string>; leadPhone: string | null; tenantId: string }

async function context(admin: SupabaseClient, run: Run, workflowFunnel: string | null): Promise<Ctx> {
  if (run.is_test || run.payload) {
    // test run: the typed-in details; webhook run: the post's fields — with the workflow's funnel and business
    const t = (run.is_test ? run.test_data : run.payload) ?? {}
    const { data: f } = workflowFunnel ? await admin.from('funnels').select('name, business_id').eq('id', workflowFunnel).maybeSingle() : { data: null }
    const { data: b } = f?.business_id ? await admin.from('businesses').select('name').eq('id', f.business_id).maybeSingle() : { data: null }
    const name = String(t.name ?? '').trim()
    const extra = extraVars(t)
    return {
      tenantId: run.tenant_id,
      leadPhone: t.phone == null || t.phone === '' ? null : String(t.phone),
      vars: {
        ...extra,
        first_name: String(t.first_name ?? '').trim() || (name.split(/\s+/)[0] ?? ''),
        name,
        phone: String(t.phone ?? ''),
        email: String(t.email ?? ''),
        city: String(t.city ?? ''),
        funnel: f?.name ?? '',
        landing_page: '',
        business: b?.name ?? '',
        event_title: '',
        event_date: '',
        event_time: '',
        event_link: '',
      },
    }
  }
  const { data: lead } = run.lead_id
    ? await admin.from('leads').select('first_name, last_name, phone, whatsapp, email, city, business_id, funnel_id, landing_page_id, purpose, extra').eq('id', run.lead_id).maybeSingle()
    : { data: null }
  const [{ data: biz }, { data: funnel }, { data: page }] = await Promise.all([
    lead?.business_id ? admin.from('businesses').select('name').eq('id', lead.business_id).maybeSingle() : Promise.resolve({ data: null }),
    lead?.funnel_id ? admin.from('funnels').select('name').eq('id', lead.funnel_id).maybeSingle() : Promise.resolve({ data: null }),
    lead?.landing_page_id ? admin.from('landing_pages').select('name').eq('id', lead.landing_page_id).maybeSingle() : Promise.resolve({ data: null }),
  ])
  const first = (lead?.first_name ?? '').trim()
  return {
    tenantId: run.tenant_id,
    leadPhone: lead ? lead.whatsapp || lead.phone : null,
    vars: {
      // extra fields saved on the lead (form / sheet columns), then the standard ones
      ...extraVars(lead?.extra as Record<string, unknown> | null),
      purpose: lead?.purpose ?? String((lead?.extra as Record<string, unknown> | null)?.purpose ?? ''),
      first_name: first,
      name: [first, lead?.last_name ?? ''].join(' ').trim(),
      phone: lead?.phone ?? '',
      email: lead?.email ?? '',
      city: lead?.city ?? '',
      funnel: (funnel as { name?: string } | null)?.name ?? '',
      landing_page: (page as { name?: string } | null)?.name ?? '',
      business: (biz as { name?: string } | null)?.name ?? '',
      event_title: '',
      event_date: '',
      event_time: '',
      event_link: '',
    },
  }
}

/** a link for this lead: <app>/<code> → the step's URL with the lead's fields ({field} or {{field}}) filled in */
async function makeShortLink(admin: SupabaseClient, run: Run, d: Record<string, unknown>, ctx: Ctx) {
  const raw = String(d.url ?? '').trim()
  // a field at the very start is a whole URL (kept as it is); fields inside are URL-encoded
  const url = raw.replace(/\{\{?\s*([a-zA-Z0-9_]+)\s*\}\}?/g, (_m, k, at: number) => {
    const vars: Record<string, string> = { full_name: ctx.vars.name ?? '', fname: ctx.vars.first_name ?? '', ...ctx.vars }
    const v = vars[varKey(k)] ?? vars[k] ?? ''
    return at === 0 ? v.trim() : encodeURIComponent(v)
  })
  if (!/^https?:\/\/[^\s]+$/i.test(url)) throw new Error(`Not a valid URL after filling in the lead's fields: "${url.slice(0, 120)}"`)
  const key = varKey(String(d.var ?? '')) || 'generated_link'
  const base = String(d.base_url ?? '').replace(/\/+$/, '')
  // 8 characters, no look-alikes (0/O, 1/I/L); unique across all workspaces
  const abc = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
  for (let tries = 0; tries < 5; tries++) {
    const bytes = crypto.getRandomValues(new Uint8Array(8))
    const code = Array.from(bytes, (b) => abc[b % abc.length]).join('')
    const { error } = await admin.from('short_links').insert({
      tenant_id: run.tenant_id,
      code,
      url,
      lead_id: run.lead_id,
      workflow_id: run.workflow_id,
      run_id: run.id,
    })
    if (!error) {
      const short = base ? `${base}/${code}` : code
      return { short, url, vars: { [key]: short, [`${key}_code`]: code } }
    }
    if (!String(error.message).includes('duplicate')) throw new Error(error.message)
  }
  throw new Error('Could not make a unique link; try again.')
}

/** a date-time a form / booking tool sent: ISO with a zone, "2026-11-02 16:00" (India time), or epoch s / ms */
function parseWhen(raw: unknown): number | null {
  const v = String(raw ?? '').trim()
  if (!v) return null
  if (/^\d{12,}$/.test(v)) return Number(v)
  if (/^\d{9,11}$/.test(v)) return Number(v) * 1000
  if (/(Z|z|[+-]\d\d:?\d\d)$/.test(v)) {
    const t = Date.parse(v.replace(' ', 'T'))
    return Number.isNaN(t) ? null : t
  }
  const m = v.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?/)
  if (!m) return null
  const t = Date.parse(`${m[1]}T${m[2].padStart(2, '0')}:${m[3]}:${m[4] ?? '00'}+05:30`)
  return Number.isNaN(t) ? null : t
}
/** India date + HH:MM of a moment */
const istParts = (t: number) => {
  const iso = new Date(t + 330 * 60_000).toISOString()
  return { date: iso.slice(0, 10), time: iso.slice(11, 16) }
}
const plusMinutes = (date: string, time: string, mins: number) => istParts(Date.parse(`${date}T${time}:00+05:30`) + mins * 60_000)

/**
 * Create Zoom meeting step. When: the date-time the webhook sent (its start / end fields), or the date and
 * start / end time picked on the step (India time). For a lead it adds the meeting (with the team member: the lead's owner,
 * one person, or round robin) and creates its Zoom meeting; a test run only creates the Zoom meeting.
 */
async function makeZoomMeeting(admin: SupabaseClient, run: Run, n: Node, d: Record<string, unknown>, ctx: Ctx) {
  // used only when no end time is known
  const duration = Math.max(15, Number(d.duration) || 60)
  let date: string
  let time: string
  let endDate: string
  let endTime: string
  if (d.use_webhook) {
    let sent: Record<string, unknown> = (run.is_test ? run.test_data : run.payload) ?? {}
    if (!run.is_test && !run.payload && run.submission_id) {
      const { data: sub } = await admin.from('lead_submissions').select('data').eq('id', run.submission_id).maybeSingle()
      sent = (sub?.data ?? {}) as Record<string, unknown>
    }
    const startKey = String(d.start_var || 'meeting_start')
    const t0 = parseWhen(sent[startKey])
    if (t0 == null) throw new Error(`The webhook didn't send a readable date-time in "${startKey}".`)
    ;({ date, time } = istParts(t0))
    const t1 = d.end_var ? parseWhen(sent[String(d.end_var)]) : null
    ;({ date: endDate, time: endTime } = t1 != null && t1 > t0 ? istParts(t1) : istParts(t0 + duration * 60_000))
  } else {
    // the date and the start / end time picked on the step
    time = /^\d{2}:\d{2}$/.test(String(d.time ?? '')) ? String(d.time) : '11:00'
    date = String(d.date ?? '')
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error('Pick the date of the Zoom meeting.')
    const end = String(d.end_time ?? '')
    if (/^\d{2}:\d{2}$/.test(end) && end > time) {
      endDate = date
      endTime = end
    } else ({ date: endDate, time: endTime } = plusMinutes(date, time, duration))
  }
  // a meeting stays within its day
  if (endDate !== date || endTime <= time) endTime = '23:59'
  const topic = fill(String(d.topic ?? '').trim() || 'Meeting with {{name}}', ctx.vars).trim() || 'Meeting'
  const { data: secret } = await admin.rpc('workflow_cron_secret')
  const callZoom = async (body: Record<string, unknown>) => {
    const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/zoom`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-cron-secret': String(secret ?? '') },
      body: JSON.stringify(body),
    })
    const z = await res.json().catch(() => ({}))
    if (!res.ok || !z.join_url) throw new Error(z.error ?? `Zoom error ${res.status}`)
    return z as { id: string; join_url: string; password?: string }
  }
  const vars = (z: { id: string; join_url: string; password?: string }) => ({
    zoom_link: String(z.join_url),
    zoom_meeting_id: String(z.id),
    zoom_password: String(z.password ?? ''),
    zoom_date: date,
    zoom_time: time,
  })

  // test run / no lead: only the Zoom meeting
  if (!run.lead_id || run.is_test) {
    const mins = Math.max(15, (Date.parse(`${date}T${endTime}:00+05:30`) - Date.parse(`${date}T${time}:00+05:30`)) / 60_000)
    const z = await callZoom({ action: 'create_adhoc', tenant_id: run.tenant_id, account: d.account || null, topic, start: `${date}T${time}`, duration: mins })
    return { id: String(z.id), when: `${date} ${time}`, host: null as string | null, vars: vars(z) }
  }

  // who takes it
  const { data: lead } = await admin.from('leads').select('id, tenant_id, business_id, sub_business_id, funnel_id, owner_id').eq('id', run.lead_id).maybeSingle()
  if (!lead) throw new Error('The lead was deleted.')
  let host: string | null = null
  if (d.meet_mode === 'single' || d.meet_mode === 'round_robin') {
    const picked = ((d.meet_members ?? []) as string[]).filter(Boolean)
    const { data: act } = picked.length ? await admin.from('tenant_members').select('id').in('id', picked).eq('status', 'active') : { data: [] }
    const ok = new Set((act ?? []).map((m) => m.id as string))
    const pool = picked.filter((id) => ok.has(id))
    if (pool.length && d.meet_mode === 'single') host = pool[0]
    else if (pool.length) {
      const { data: turn } = await admin.rpc('workflow_next_turn', { p_workflow: run.workflow_id, p_node: n.id })
      host = pool[((Number(turn) || 1) - 1) % pool.length]
    }
  } else host = lead.owner_id ?? null
  let sub = lead.sub_business_id
  if (!sub && lead.funnel_id) {
    const { data: f } = await admin.from('funnels').select('sub_business_id').eq('id', lead.funnel_id).maybeSingle()
    sub = f?.sub_business_id ?? null
  }

  const { data: m, error } = await admin
    .from('meetings')
    .insert({ tenant_id: run.tenant_id, business_id: lead.business_id, sub_business_id: sub, lead_id: lead.id, meeting_date: date, start_time: time, end_time: endTime, mode: 'online', assigned_to: host })
    .select('id')
    .single()
  if (error) throw new Error(`Could not add the meeting: ${error.message}`)
  const z = await callZoom({ action: 'book_meeting', meeting_id: m.id, account: d.account || null, topic })
  const { data: who } = host ? await admin.from('tenant_members').select('profiles(full_name)').eq('id', host).maybeSingle() : { data: null }
  const hostName = ((who as { profiles?: { full_name?: string } } | null)?.profiles?.full_name ?? null) as string | null
  await admin.from('lead_activities').insert({
    tenant_id: run.tenant_id,
    lead_id: lead.id,
    kind: 'note',
    note: `Meeting booked by workflow for ${date} ${time}${hostName ? ` · with ${hostName}` : ''} · Zoom ${z.join_url}`,
  })
  return { id: String(z.id), when: `${date} ${time}`, host: hostName, vars: vars(z) }
}

const fill = (s: string, vars: Record<string, string>) => s.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (_, k) => vars[k] ?? '')

/** 98XXXXXXXX / +91 98XXX XXXXX / 091... → 9198XXXXXXXX (WATI wants the country code, no +) */
function waNumber(raw: string | null | undefined) {
  let d = (raw ?? '').replace(/\D/g, '')
  if (d.startsWith('00')) d = d.slice(2)
  if (d.length === 11 && d.startsWith('0')) d = d.slice(1)
  if (d.length === 10) d = `91${d}`
  return d.length >= 11 ? d : null
}

async function sendWhatsApp(admin: SupabaseClient, run: Run, workflowName: string, d: Record<string, unknown>, ctx: Ctx) {
  const template = String(d.template ?? '').trim()
  if (!template) throw new Error('No template picked. A free message can only go to someone who wrote to you in the last 24 hours — pick an approved template.')

  // who it goes to
  let to: string | null
  if (d.to === 'team') {
    const { data: m } = d.member_id ? await admin.from('tenant_members').select('user_id').eq('id', String(d.member_id)).maybeSingle() : { data: null }
    const { data: p } = m?.user_id ? await admin.from('profiles').select('phone').eq('id', m.user_id).maybeSingle() : { data: null }
    to = waNumber(p?.phone)
    if (!to) throw new Error('The team member has no phone number on their profile.')
  } else if (d.to === 'custom') {
    to = waNumber(String(d.custom_phone ?? ''))
    if (!to) throw new Error('The custom number is not a valid 10-digit number.')
  } else {
    to = waNumber(ctx.leadPhone)
    if (!to) throw new Error('The lead has no valid phone number.')
  }

  // the workspace's WATI connection
  const { data: integ } = await admin.from('integrations').select('config, is_enabled').eq('tenant_id', ctx.tenantId).eq('provider', 'whatsapp').maybeSingle()
  if (!integ) throw new Error('WhatsApp is not connected (System Connections).')
  if (!integ.is_enabled) throw new Error('WhatsApp is paused in System Connections.')
  const cfg = (integ.config ?? {}) as Record<string, string>
  if (cfg.vendor !== 'wati') throw new Error('Only WATI can send from workflows for now.')
  const base = (cfg.api_endpoint ?? '').trim().replace(/\/+$/, '').replace(/\/api\/v\d.*$/, '')
  const token = (cfg.access_token ?? '').trim().replace(/^Bearer\s+/i, '')
  if (!/^https:\/\/[^/]+\/\w+/.test(base) || !token) throw new Error('The WATI API endpoint or access token is missing (System Connections).')

  const params = (d.params ?? {}) as Record<string, string>
  const parameters = Object.entries(params).map(([name, value]) => ({ name, value: fill(String(value ?? ''), ctx.vars).trim() || '-' }))
  const broadcast = `bizdock_${workflowName}`.replace(/[^a-zA-Z0-9_]+/g, '_').slice(0, 60)

  const res = await fetch(`${base}/api/v1/sendTemplateMessage?whatsappNumber=${to}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, accept: 'application/json', 'content-type': 'application/json' },
    body: JSON.stringify({ template_name: template, broadcast_name: broadcast, parameters }),
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
    const why = out.info ?? out.message ?? out.error ?? out.raw
    throw new Error(
      why
        ? `WATI: ${String(why)}`
        : `WATI rejected the message (${res.status}): check the template "${template}" is approved, its variables are filled, and +${to} is on WhatsApp.`,
    )
  }

  // keep a copy on the lead (WhatsApp tab)
  if (run.lead_id && (!d.to || d.to === 'lead')) {
    const body = fill(String(d.template_body ?? d.message ?? ''), { ...ctx.vars, ...Object.fromEntries(parameters.map((p) => [p.name, p.value])) })
    await admin.from('lead_messages').insert({ tenant_id: run.tenant_id, lead_id: run.lead_id, channel: 'whatsapp', title: template, body, via: 'workflow' })
  }
  return `Sent "${template}" to +${to}`
}
