// workflow-runner: runs workflows step by step (first version).
//
//   POST { action: 'cron' } + header x-cron-secret   → takes the due runs and moves each one forward
//     (called by pg_cron every minute and straight after a form submission starts a run;
//      the secret lives in the vault: public.workflow_cron_secret())
//
// Steps done now: WhatsApp (approved template through WATI), Bulk WhatsApp (several templates, each a set
// time after the run started, with an optional stop condition), Generate link (<app>/<code> for the lead,
// kept for later steps as {{generated_link}}), Create Zoom meeting ({{zoom_link}}, optionally as a short link), Get lead
// details, Wait, Wait for event (until some time before / after a date-time field such as the Zoom meeting's start),
// Switch / Yes-No and Go to workflow (with fields passed as the next workflow's variables); for Webinar businesses Register
// for webinar (the lead on the coming date, with their own Zoom join link), Wait until Zoom data is in and Get webinar
// analytics (attendance, Q&A, chat, polls → Super Hot / Hot / Warm / Cold). Before / After webinar runs carry their date
// (event_id). Email and Call are skipped (logged) — they come later.
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
  /** Before / After webinar: the date (calendar event) this run is for */
  event_id: string | null
  created_at: string
  /** progress inside a step that runs over time */
  state: { bulk?: { node: string; i: number } | null; vars?: Record<string, string>; hops?: number; lead_found?: boolean; event_id?: string; tries?: number } | null
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

  const { data: wf } = await admin.from('workflows').select('id, name, is_active, archived_at, nodes, edges, funnel_id, event_id, webinar_id').eq('id', run.workflow_id).maybeSingle()
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
  // a Get lead details step found the lead earlier in this run: its fields (they win over same-named webhook fields)
  if (state.lead_found && run.lead_id) {
    const info = await leadInfo(admin, run.lead_id)
    Object.assign(ctx.vars, info.vars)
    ctx.leadPhone = info.leadPhone
  }
  // the webinar date of the run (Before / After webinar, or registered earlier in it): its title, times and the lead's link
  const evId = run.event_id ?? state.event_id ?? null
  if (evId) {
    const { data: ev } = await admin.from('events').select('*').eq('id', evId).maybeSingle()
    if (ev) Object.assign(ctx.vars, await webinarVars(admin, ev, run.lead_id))
  }
  // values made by earlier steps of this run (generated links)
  Object.assign(ctx.vars, state.vars ?? {})
  // when this workflow started (the form post / trigger), India time: "2026-10-30 10:59"
  if (!ctx.vars.submitted_at) {
    const p = istParts(Date.parse(run.created_at))
    ctx.vars.submitted_at = `${p.date} ${p.time}`
  }
  let at = run.node_id
  // waiting inside a Bulk WhatsApp step: carry on with that step
  let resume = byId.get(at)?.type === 'bulk_whatsapp' && state.bulk?.node === at
  // a Switch / Yes-No step picks the next step itself
  let jump: Node | null | undefined
  for (let i = 0; i < MAX_STEPS; i++) {
    const n = resume ? byId.get(at)! : jump !== undefined ? jump : nextOf(at)
    resume = false
    jump = undefined
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
      // what the times count from (the run's start, the event, the lead's meeting or a date-time field), before or after it
      let start: number
      try {
        start = await bulkBase(admin, run, wf as Record<string, unknown>, d, ctx)
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
      // each message's own before / after (older steps: the step's one setting); the start is always "after"
      const sign = (r: Record<string, unknown>) => (d.anchor && d.anchor !== 'start' && (r.dir ?? d.direction) === 'before' ? -1 : 1)
      // messages in time order; each one is due this long before / after that moment
      const rows = ((d.rows ?? []) as Record<string, unknown>[])
        .map((r, idx) => ({ r, idx, min: sign(r) * (Number(r.amount) || 0) * ((UNIT_MS[String(r.unit)] ?? UNIT_MS.minutes) / 60_000) }))
        .sort((a, b) => a.min - b.min || a.idx - b.idx)
      const entering = !(state.bulk && state.bulk.node === n.id)
      let k = entering ? 0 : state.bulk!.i
      // "Skip messages already past": on reaching the step, the ones whose time has gone (e.g. "1 day before" for someone
      // who registered an hour before the webinar) aren't sent
      if (entering && d.skip_past) {
        const from = k
        while (k < rows.length && start + rows[k].min * 60_000 < Date.now() - 60_000) k++
        if (k > from) note(n, 'skipped', `${k - from} message${k - from > 1 ? 's' : ''} already past when the step started: not sent.`)
      }
      while (k < rows.length) {
        const stop = d.stop as Cond | undefined
        const stopNow = d.stop_on && !run.is_test && (stop?.field?.startsWith('v:') ? matchVar(stop, ctx.vars) : !!run.lead_id && (await matches(admin, run.lead_id, stop)))
        if (stopNow) {
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
    } else if (n.type === 'lead_lookup') {
      // Get lead details: the newest lead of this workflow's sub-business with that phone / email; from here on the run is that lead's
      try {
        let found: { id: string; by: string; value: string; added?: boolean }
        try {
          found = await findLead(admin, run, (wf.funnel_id as string | null) ?? null, d, ctx)
        } catch (e) {
          // "If not found, add the lead": a new lead in the workflow's funnel (e.g. someone who booked without filling the form)
          if (!d.create_missing || !/^Lead not found/.test((e as Error).message)) throw e
          found = { ...(await addLead(admin, (wf.funnel_id as string | null) ?? null, d, ctx, wf.name as string)), added: true }
        }
        run.lead_id = found.id
        state.lead_found = true
        await admin.from('workflow_runs').update({ lead_id: found.id }).eq('id', run.id)
        const info = await leadInfo(admin, found.id)
        Object.assign(ctx.vars, info.vars)
        ctx.leadPhone = info.leadPhone
        note(
          n,
          'ok',
          found.added
            ? `No lead with that phone or email: added ${info.vars.name || 'the lead'}${info.vars.phone ? ` (${info.vars.phone})` : ''} to the funnel`
            : `Found ${info.vars.name || 'the lead'}${info.vars.phone ? ` (${info.vars.phone})` : ''} by ${found.by} ${found.value}`,
        )
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
    } else if (n.type === 'goto') {
      // continue in another workflow (from its first step), passing the step's fields as its variables
      const target = String(d.workflow_id ?? '')
      const { data: next } = target
        ? await admin.from('workflows').select('id, name').eq('id', target).eq('tenant_id', run.tenant_id).is('archived_at', null).maybeSingle()
        : { data: null }
      if (!next || target === run.workflow_id) {
        const why = !target ? 'No workflow picked.' : target === run.workflow_id ? 'A workflow can’t go to itself.' : 'The workflow to go to was deleted.'
        note(n, 'failed', why)
        return save({ status: 'failed', node_id: at, error: why })
      }
      const hops = (state.hops ?? 0) + 1
      if (hops > 10) {
        note(n, 'failed', 'Stopped: more than 10 “Go to workflow” in a row (a loop?).')
        return save({ status: 'failed', node_id: at, error: 'Too many Go to workflow steps in a row.' })
      }
      const pass = Object.fromEntries(
        ((d.fields ?? []) as { name?: string; value?: string }[])
          .filter((f) => varKey(String(f.name ?? '')))
          .map((f) => [varKey(String(f.name)), fill(String(f.value ?? ''), ctx.vars)]),
      )
      // only the fields picked on the step go to the next workflow
      const carried = run.is_test ? null : pass
      // the next workflow's own webhook: waiting for a test → this hand-over is its test (the run doesn't start);
      // no test yet → it becomes the sample, so its builder shows the passed fields
      const { data: hook } = await admin.from('workflow_hooks').select('id, test_mode_until, sample_at').eq('workflow_id', next.id).maybeSingle()
      const sample = pass
      if (hook && hook.test_mode_until && Date.parse(hook.test_mode_until) > Date.now()) {
        await admin.from('workflow_hooks').update({ sample, sample_at: new Date().toISOString(), test_mode_until: null }).eq('id', hook.id)
        note(n, 'ok', `"${next.name}" was waiting for a test: these fields are its test now (${Object.keys(pass).join(', ') || 'none'}); it doesn't run this time`)
        return save({ status: 'done', node_id: n.id, error: null })
      }
      if (hook && !hook.sample_at) await admin.from('workflow_hooks').update({ sample, sample_at: new Date().toISOString() }).eq('id', hook.id)
      const { error: insErr } = await admin.from('workflow_runs').insert({
        tenant_id: run.tenant_id,
        workflow_id: next.id,
        lead_id: run.lead_id,
        is_test: run.is_test,
        test_data: run.is_test ? pass : null,
        payload: carried && Object.keys(carried).length ? carried : null,
        state: { hops },
      })
      if (insErr) {
        note(n, 'failed', insErr.message)
        return save({ status: 'failed', node_id: at, error: insErr.message })
      }
      const names = Object.keys(pass)
      note(n, 'ok', `Went to "${next.name}"${names.length ? ` · passed ${names.join(', ')}` : ''}`)
      return save({ status: 'done', node_id: n.id, error: null })
    } else if (n.type === 'register_webinar') {
      try {
        const r = await registerWebinar(admin, run, wf as Record<string, unknown>, d, ctx)
        if ('wait' in r) {
          state.tries = (state.tries ?? 0) + 1
          if (state.tries > 8) {
            note(n, 'failed', r.wait)
            return save({ status: 'failed', node_id: at, error: r.wait })
          }
          // the Zoom webinar of a just-added date is being made: try again shortly
          return save({ status: 'waiting', node_id: at, next_at: new Date(Date.now() + 20_000).toISOString() })
        }
        state.tries = 0
        state.event_id = r.eventId
        state.vars = { ...(state.vars ?? {}), ...r.vars }
        Object.assign(ctx.vars, r.vars)
        note(n, 'ok', r.detail)
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
    } else if (n.type === 'wait_zoom') {
      // Wait until Zoom data is in: the webinar has ended and its attendance / Q&A / chat / polls were fetched
      // (tried every 5 minutes from 5 minutes after the end); after 2 hours without any, it carries on
      const ev = await runEvent(admin, run, wf as Record<string, unknown>, state)
      if (!ev) {
        const msg = 'No webinar date for this lead: register them first (Register for webinar) or start from a Before / After webinar trigger.'
        note(n, 'failed', msg)
        return save({ status: 'failed', node_id: at, error: msg })
      }
      const endAt = Date.parse(`${ev.event_date}T${String(ev.end_time ?? ev.start_time ?? '23:00').slice(0, 5)}:00+05:30`)
      if (Number(ev.zoom_pull_count ?? 0) >= 1) note(n, 'ok', `Zoom data of “${ev.title}” (${ev.event_date}) is in`)
      else if (!ev.zoom_webinar_id || Date.now() > endAt + 130 * 60_000) note(n, 'ok', `No Zoom data for “${ev.title}” ${ev.zoom_webinar_id ? '2 hours after the end' : '(no Zoom webinar)'}: carried on without it`)
      else {
        const next = Math.max(Date.now() + 60_000, endAt + 5 * 60_000)
        const last = log[log.length - 1]
        if (!last || last.node_id !== n.id || last.status !== 'waiting') note(n, 'waiting', `Waiting for Zoom's data of “${ev.title}” (checked every minute after the end)`)
        // node_id stays on the step before, so the next run checks again
        return save({ status: 'waiting', node_id: at, next_at: new Date(next).toISOString() })
      }
    } else if (n.type === 'webinar_analytics') {
      try {
        const r = await webinarAnalytics(admin, run, wf as Record<string, unknown>, state)
        state.vars = { ...(state.vars ?? {}), ...r.vars }
        Object.assign(ctx.vars, r.vars)
        note(n, 'ok', r.detail)
      } catch (e) {
        note(n, 'failed', (e as Error).message)
        return save({ status: 'failed', node_id: at, error: (e as Error).message })
      }
    } else if (n.type === 'wait') {
      const ms = Math.max(1, Number(d.amount) || 1) * (UNIT_MS[String(d.unit)] ?? UNIT_MS.days)
      const until = new Date(Date.now() + ms)
      note(n, 'waiting', `Waiting until ${until.toISOString()}`)
      return save({ status: 'waiting', node_id: n.id, next_at: until.toISOString() })
    } else if (n.type === 'wait_event') {
      // Wait for event: until some time before (or after) a date-time — a field such as the Zoom meeting's start,
      // or (older steps) the workflow's webinar / event; a moment already passed carries straight on
      let base: number
      try {
        base = await bulkBase(admin, run, wf as Record<string, unknown>, { anchor: d.anchor === 'var' ? 'var' : 'event', anchor_var: d.anchor_var }, ctx)
      } catch (e) {
        const msg = (e as Error).message.replace('to count the times from', 'to wait for')
        note(n, 'failed', msg)
        return save({ status: 'failed', node_id: at, error: msg })
      }
      const ms = Math.max(0, Number(d.amount) || 0) * (UNIT_MS[String(d.unit)] ?? UNIT_MS.hours)
      const until = base + (d.when === 'after' ? ms : -ms)
      const what = `${Number(d.amount) || 0} ${String(d.unit ?? 'hours')} ${d.when === 'after' ? 'after' : 'before'} ${new Date(base).toISOString()}`
      if (until > Date.now() + 5_000) {
        note(n, 'waiting', `Waiting until ${new Date(until).toISOString()} (${what})`)
        return save({ status: 'waiting', node_id: n.id, next_at: new Date(until).toISOString() })
      }
      note(n, 'ok', `${what} has already passed: carried on`)
    } else if (n.type === 'condition' || n.type === 'switch') {
      // Switch: the first path whose condition the lead matches (checked top to bottom); Yes / No: yes or no.
      // A path with no line, or no path matching, ends the workflow here.
      const cases = n.type === 'switch' ? ((d.cases ?? []) as (Cond & { id: string; label?: string })[]) : [{ ...(d as unknown as Cond), id: 'yes', label: 'Yes' }]
      let hit: { id: string; label: string } | null = null
      for (const [ci, c] of cases.entries()) {
        // a run value (webhook field / earlier step) is checked as it is; anything else on the lead
        const ok = c.field?.startsWith('v:') ? matchVar(c, ctx.vars) : !!run.lead_id && (await matches(admin, run.lead_id, c))
        if (ok) {
          hit = { id: c.id, label: String(c.label ?? '').trim() || `Path ${ci + 1}` }
          break
        }
      }
      if (!hit && n.type === 'condition') hit = { id: 'no', label: 'No' }
      const edge = hit ? edges.find((e) => e.source === n.id && e.sourceHandle === hit!.id) : null
      if (!hit || !edge) {
        note(n, 'ok', !run.lead_id && !cases.some((c) => c.field?.startsWith('v:')) ? 'No lead to check: the workflow ends here.' : hit ? `Went down “${hit.label}”; it has no next step, so the workflow ends here.` : 'The lead matched no path: the workflow ends here.')
        return save({ status: 'done', node_id: n.id, error: null })
      }
      note(n, 'ok', `Went down “${hit.label}”`)
      jump = byId.get(edge.target) ?? null
    } else {
      note(n, 'skipped', `${n.type} steps are not running yet.`)
    }
    at = n.id
  }
  return save({ status: 'stopped', node_id: at, error: 'Too many steps in one go.' })
}

type Cond = { field: string; op: string; value: string }

/**
 * A condition on a value of the run ("v:<key>": a webhook field or an earlier step's, e.g. submitted_at): text without
 * case, includes any of / starts / ends, and > >= < <= as numbers or date-times.
 */
function matchVar(c: Cond, vars: Record<string, string>) {
  const key = c.field.slice(2)
  const v = String(vars[key] ?? vars[varKey(key)] ?? '').trim()
  const op = c.op === 'is' ? 'eq' : c.op === 'is_not' ? 'neq' : c.op
  const want = String(c.value ?? '').trim()
  if (op === 'empty') return v === ''
  if (op === 'not_empty') return v !== ''
  const low = v.toLowerCase()
  if (op === 'in' || op === 'starts' || op === 'ends') {
    const vals = (op === 'in' ? want.split('\n') : [want]).map((x) => x.trim().toLowerCase()).filter(Boolean)
    return vals.some((x) => (op === 'in' ? low.includes(x) : op === 'starts' ? low.startsWith(x) : low.endsWith(x)))
  }
  // numbers, else date-times ("2026-10-30 10:59", ISO, a date)
  const num = (x: string) => (x !== '' && !Number.isNaN(Number(x.replace(/[,\s₹]/g, ''))) ? Number(x.replace(/[,\s₹]/g, '')) : null)
  const when = (x: string) => parseWhen(x) ?? (/^\d{4}-\d{2}-\d{2}$/.test(x) ? Date.parse(`${x}T00:00:00+05:30`) : null)
  let a = num(v)
  let b = num(want)
  if (a == null || b == null) {
    a = when(v)
    b = when(want)
  }
  if (['gt', 'gte', 'lt', 'lte'].includes(op)) {
    if (a == null || b == null) return false
    return op === 'gt' ? a > b : op === 'gte' ? a >= b : op === 'lt' ? a < b : a <= b
  }
  const same = a != null && b != null ? a === b : low === want.toLowerCase()
  return op === 'neq' ? !same : same
}

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

  if (c.field === 'customer') {
    // a customer: a purchase with a paid part, or a confirmed / completed booking
    const { count: p } = await admin.from('purchases').select('id', { count: 'exact', head: true }).eq('lead_id', leadId).eq('status', 'active').gt('paid_amount', 0)
    let has = (p ?? 0) > 0
    if (!has) {
      const { count: b } = await admin.from('bookings').select('id', { count: 'exact', head: true }).eq('lead_id', leadId).in('status', ['confirmed', 'completed'])
      has = (b ?? 0) > 0
    }
    return op === 'not_exists' ? !has : has
  }
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
      if (!has) {
        const { count } = await admin.from('purchases').select('id', { count: 'exact', head: true }).eq('lead_id', leadId).eq('status', 'active').gt('paid_amount', 0)
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
  // includes any of (one per line) / starts with / ends with — text without case; picked choices (stage, source…) by id
  if (op === 'in' || op === 'starts' || op === 'ends') {
    const picked = ['stage', 'source', 'owner', 'temperature', 'landing_page'].includes(c.field)
    const vals = (op === 'in' ? want.split('\n') : [want]).map((x) => x.trim()).filter(Boolean)
    if (!vals.length) return false
    if (picked) {
      const mine = c.field === 'landing_page' ? [String(lead.webhook_id ?? ''), String(lead.landing_page_id ?? '')] : [v]
      return vals.some((x) => mine.includes(x))
    }
    const low = v.toLowerCase()
    if (c.field === 'phone') {
      const digits = v.replace(/\D/g, '')
      return vals.some((x) => {
        const d = x.replace(/\D/g, '')
        return op === 'in' ? digits.slice(-10) === d.slice(-10) || digits.includes(d) : op === 'starts' ? digits.startsWith(d) || v.startsWith(x) : digits.endsWith(d)
      })
    }
    return vals.some((x) => (op === 'in' ? low.includes(x.toLowerCase()) : op === 'starts' ? low.startsWith(x.toLowerCase()) : low.endsWith(x.toLowerCase())))
  }
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
  if (run.is_test || (run.payload && !run.lead_id)) {
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
        ...leadDates(run.created_at),
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
  const info = run.lead_id ? await leadInfo(admin, run.lead_id) : { vars: {} as Record<string, string>, leadPhone: null }
  // fields passed by a "Go to workflow" step / the webhook's post (on top of the lead's own)
  const passed = extraVars(run.payload)
  return { tenantId: run.tenant_id, leadPhone: info.leadPhone, vars: { ...info.vars, ...passed } }
}

/** a lead's fields as message variables: its extra fields (form / sheet columns), then the standard ones */
async function leadInfo(admin: SupabaseClient, leadId: string): Promise<{ vars: Record<string, string>; leadPhone: string | null }> {
  const { data: lead } = await admin.from('leads').select('first_name, last_name, phone, whatsapp, email, city, business_id, funnel_id, landing_page_id, purpose, extra, created_at').eq('id', leadId).maybeSingle()
  const [{ data: biz }, { data: funnel }, { data: page }] = await Promise.all([
    lead?.business_id ? admin.from('businesses').select('name').eq('id', lead.business_id).maybeSingle() : Promise.resolve({ data: null }),
    lead?.funnel_id ? admin.from('funnels').select('name').eq('id', lead.funnel_id).maybeSingle() : Promise.resolve({ data: null }),
    lead?.landing_page_id ? admin.from('landing_pages').select('name').eq('id', lead.landing_page_id).maybeSingle() : Promise.resolve({ data: null }),
  ])
  const first = (lead?.first_name ?? '').trim()
  return {
    leadPhone: lead ? lead.whatsapp || lead.phone : null,
    vars: {
      ...extraVars(lead?.extra as Record<string, unknown> | null),
      purpose: lead?.purpose ?? String((lead?.extra as Record<string, unknown> | null)?.purpose ?? ''),
      first_name: first,
      name: [first, lead?.last_name ?? ''].join(' ').trim(),
      phone: lead?.phone ?? '',
      email: lead?.email ?? '',
      city: lead?.city ?? '',
      ...leadDates(lead?.created_at),
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

/**
 * Get lead details: the newest lead of the workflow's sub-business whose phone (last 10 digits) / email matches the picked
 * field — or, "phone or email", the newest lead matching either (e.g. a Booking Calendar booking's phone and email)
 */
async function findLead(admin: SupabaseClient, run: Run, funnelId: string | null, d: Record<string, unknown>, ctx: Ctx) {
  const by = d.match === 'email' ? 'email' : d.match === 'any' ? 'any' : 'phone'
  const phoneKey = String((by === 'any' ? d.phone_var || 'phone' : by === 'phone' ? d.value_var : '') ?? '').trim()
  const emailKey = String((by === 'any' ? d.email_var || 'email' : by === 'email' ? d.value_var : '') ?? '').trim()
  if (by !== 'any' && !String(d.value_var ?? '').trim()) throw new Error('Pick the field to match the lead with.')
  const rawPhone = phoneKey ? varValue(ctx.vars, phoneKey).trim() : ''
  const rawEmail = emailKey ? varValue(ctx.vars, emailKey).trim() : ''
  const digits = rawPhone.replace(/\D/g, '').slice(-10)
  const email = rawEmail.toLowerCase()
  const okPhone = digits.length === 10
  const okEmail = /^[^\s@,()"]+@[^\s@,()"]+$/.test(email)
  if (by === 'phone' && !rawPhone) throw new Error(`Lead not found: {{${phoneKey}}} is empty.`)
  if (by === 'email' && !rawEmail) throw new Error(`Lead not found: {{${emailKey}}} is empty.`)
  if (by === 'phone' && !okPhone) throw new Error(`Lead not found: "${rawPhone}" is not a 10-digit phone number.`)
  if (by === 'email' && !okEmail) throw new Error(`Lead not found: "${rawEmail}" is not an email.`)
  if (by === 'any' && !okPhone && !okEmail) throw new Error('Lead not found: no valid phone number or email to match.')

  const { data: f } = funnelId ? await admin.from('funnels').select('sub_business_id, business_id').eq('id', funnelId).maybeSingle() : { data: null }
  if (!f) throw new Error('Link this workflow to a funnel (Used in funnel) to find its leads.')
  const { data: fs } = f.sub_business_id
    ? await admin.from('funnels').select('id').eq('tenant_id', run.tenant_id).eq('sub_business_id', f.sub_business_id)
    : await admin.from('funnels').select('id').eq('tenant_id', run.tenant_id).eq('business_id', f.business_id)
  const ids = (fs ?? []).map((x) => x.id as string)
  // in the sub-business: the lead's own sub-business, or one of its funnels
  const scopes = [...(f.sub_business_id ? [`sub_business_id.eq.${f.sub_business_id}`] : []), ...(ids.length ? [`funnel_id.in.(${ids.join(',')})`] : [])]
  if (!scopes.length) throw new Error('Lead not found: this sub-business has no funnels.')
  const match: string[] = [
    ...(by !== 'email' && okPhone ? [`phone.ilike.%${digits}`, `whatsapp.ilike.%${digits}`] : []),
    ...(by !== 'phone' && okEmail ? [`email.ilike.${email}`] : []),
  ]
  // (in the sub-business) and (matches), as one filter
  const either = scopes.flatMap((sc) => match.map((m) => `and(${sc},${m})`)).join(',')
  const { data: rows, error } = await admin.from('leads').select('id, phone, whatsapp, email').eq('tenant_id', run.tenant_id).or(either).order('created_at', { ascending: false }).limit(20)
  if (error) throw new Error(error.message)
  // exactly (ilike reads _ and % as wildcards)
  const samePhone = (x: unknown) => okPhone && String(x ?? '').replace(/\D/g, '').slice(-10) === digits
  const sameEmail = (x: unknown) => okEmail && String(x ?? '').trim().toLowerCase() === email
  const hit = (rows ?? []).find((r) => (by !== 'email' && (samePhone(r.phone) || samePhone(r.whatsapp))) || (by !== 'phone' && sameEmail(r.email)))
  const tried = [by !== 'email' && okPhone ? `phone ${digits}` : '', by !== 'phone' && okEmail ? `email ${email}` : ''].filter(Boolean).join(' or ')
  if (!hit) throw new Error(`Lead not found with ${tried}.`)
  const viaPhone = by !== 'email' && (samePhone(hit.phone) || samePhone(hit.whatsapp))
  return { id: hit.id as string, by: viaPhone ? 'phone' : 'email', value: viaPhone ? digits : email }
}

/** Get lead details found no one: add the lead (name, phone, email from the step's fields) to the workflow's funnel */
async function addLead(admin: SupabaseClient, funnelId: string | null, d: Record<string, unknown>, ctx: Ctx, workflowName: string) {
  if (!funnelId) throw new Error('Lead not found, and the workflow has no funnel (Used in funnel) to add it to.')
  const phoneKey = String((d.match === 'any' ? d.phone_var || 'phone' : d.match === 'email' ? 'phone' : d.value_var) ?? 'phone')
  const emailKey = String((d.match === 'any' ? d.email_var || 'email' : d.match === 'email' ? d.value_var : 'email') ?? 'email')
  const data = {
    name: varValue(ctx.vars, 'name').trim() || [varValue(ctx.vars, 'first_name'), varValue(ctx.vars, 'last_name')].join(' ').trim(),
    phone: varValue(ctx.vars, phoneKey).trim(),
    email: varValue(ctx.vars, emailKey).trim(),
  }
  if (!data.name) throw new Error('Lead not found, and there is no name to add it with.')
  if (data.phone.replace(/\D/g, '').length < 10) throw new Error('Lead not found, and there is no valid phone number to add it with.')
  const widget = varValue(ctx.vars, 'widget').trim()
  const { data: id, error } = await admin.rpc('workflow_create_lead', {
    p_funnel: funnelId,
    p_data: data,
    p_note: widget ? `Booked a call on the booking calendar “${widget}”` : `Added by the workflow “${workflowName}”`,
  })
  if (error) throw new Error(`Could not add the lead: ${error.message}`)
  return { id: String(id), by: 'new', value: '' }
}

/** {{lead_date}} "29 Oct 2026" and {{lead_datetime}} "29 Oct 2026, 4:00 pm": when the lead came in, India time */
function leadDates(at: string | null | undefined) {
  const t = at ? Date.parse(at) : NaN
  if (Number.isNaN(t)) return { lead_date: '', lead_datetime: '' }
  const p = istParts(t)
  return { lead_date: niceDate(p.date), lead_datetime: `${niceDate(p.date)}, ${niceTime(p.time)}` }
}

/** a link for this lead: <app>/<code> → the step's URL with the lead's fields ({field} or {{field}}) filled in */
async function makeShortLink(admin: SupabaseClient, run: Run, d: Record<string, unknown>, ctx: Ctx) {
  const raw = String(d.url ?? '').trim()
  // a field at the very start is a whole URL (kept as it is); fields inside are URL-encoded
  const url = raw.replace(/\{\{?\s*([a-zA-Z0-9_]+)\s*\}\}?/g, (_m, k, at: number) => {
    const vars: Record<string, string> = { full_name: ctx.vars.name ?? '', fname: ctx.vars.first_name ?? '', ...ctx.vars }
    const v = vars[varKey(k)] ?? (varValue(vars, k) || varValue(vars, varKey(k)))
    return at === 0 ? v.trim() : encodeURIComponent(v)
  })
  if (!/^https?:\/\/[^\s]+$/i.test(url)) throw new Error(`Not a valid URL after filling in the lead's fields: "${url.slice(0, 120)}"`)
  const key = varKey(String(d.var ?? '')) || 'generated_link'
  // the workspace's own address (primary domain + folder); what the builder saved only if it has none
  const base = (await appUrl(admin, run.tenant_id)) || String(d.base_url ?? '').replace(/\/+$/, '')
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
      // also the filled-in URL itself: whole, and only its parameters (after "?")
      const q = url.indexOf('?')
      return { short, url, vars: { [key]: short, [`${key}_code`]: code, [`${key}_full_url`]: url, [`${key}_parameters`]: q < 0 ? '' : url.slice(q + 1) } }
    }
    if (!String(error.message).includes('duplicate')) throw new Error(error.message)
  }
  throw new Error('Could not make a unique link; try again.')
}

/** https://<primary domain>/<folder> of the workspace (e.g. https://pride.viralsakhiya.com/pride), or '' */
async function appUrl(admin: SupabaseClient, tenantId: string) {
  const { data } = await admin.from('tenant_domains').select('domain, base_path').eq('tenant_id', tenantId).order('is_primary', { ascending: false }).order('created_at').limit(1).maybeSingle()
  if (!data?.domain) return ''
  const path = String(data.base_path ?? '').replace(/^\/+|\/+$/g, '')
  return `https://${data.domain}${path ? `/${path}` : ''}`
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
/** "29 Oct 2026 5pm-8pm" (India time; "5:30pm" when not on the hour) */
function whenText(date: string, start: string, end: string) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
  const [y, mo, dd] = date.split('-').map(Number)
  const t = (hm: string) => {
    const [h, m] = hm.split(':').map(Number)
    const h12 = h % 12 === 0 ? 12 : h % 12
    return `${h12}${m ? `:${String(m).padStart(2, '0')}` : ''}${h < 12 ? 'am' : 'pm'}`
  }
  return `${dd} ${months[mo - 1]} ${y} ${t(start)}-${t(end)}`
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
    zoom_date_time: whenText(date, time, endTime),
    zoom_start: `${date} ${time}`,
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
  } else if (d.meet_mode === 'webhook') {
    // the team member the webhook sent (a Booking Calendar booking sends their email; older ones their id), if still active here
    const who = String(varValue(ctx.vars, String(d.meet_var || 'member_email')) ?? '').trim()
    let mid: string | null = null
    if (/^[0-9a-f-]{36}$/i.test(who)) {
      const { data: m } = await admin.from('tenant_members').select('id').eq('id', who).eq('tenant_id', run.tenant_id).eq('status', 'active').maybeSingle()
      mid = m?.id ?? null
    } else if (who.includes('@')) {
      const { data: ps } = await admin.from('profiles').select('id').ilike('email', who.replace(/[%_]/g, '\\$&'))
      const ids = (ps ?? []).map((p) => p.id as string)
      const { data: m } = ids.length
        ? await admin.from('tenant_members').select('id').in('user_id', ids).eq('tenant_id', run.tenant_id).eq('status', 'active').limit(1).maybeSingle()
        : { data: null }
      mid = m?.id ?? null
    }
    host = mid ?? lead.owner_id ?? null
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
  const { data: who } = host ? await admin.from('tenant_members').select('profiles(full_name, email, phone)').eq('id', host).maybeSingle() : { data: null }
  const hostProfile = (who as { profiles?: { full_name?: string; email?: string; phone?: string } } | null)?.profiles ?? null
  const hostName = (hostProfile?.full_name ?? null) as string | null
  await admin.from('lead_activities').insert({
    tenant_id: run.tenant_id,
    lead_id: lead.id,
    kind: 'note',
    note: `Meeting booked by workflow for ${date} ${time}${hostName ? ` · with ${hostName}` : ''} · Zoom ${z.join_url}`,
  })
  // the team member it went to, for later messages ({{member_name}}, {{member_email}}, {{member_phone}})
  const member = d.meet_mode === 'webhook' ? { member_name: hostName ?? '', member_email: hostProfile?.email ?? '', member_phone: hostProfile?.phone ?? '' } : {}
  return { id: String(z.id), when: `${date} ${time}`, host: hostName, vars: { ...vars(z), ...member } }
}

// ---------------- webinars ----------------
type Row = Record<string, unknown>
const hm = (t: unknown) => String(t ?? '').slice(0, 5)

/** the zoom function (as the database calls it) */
async function zoomFn(admin: SupabaseClient, body: Record<string, unknown>) {
  const { data: secret } = await admin.rpc('workflow_cron_secret')
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/zoom`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-cron-secret': String(secret ?? '') },
    body: JSON.stringify(body),
  })
  const z = await res.json().catch(() => ({}))
  if (!res.ok || z.error) throw new Error(z.error ?? `Zoom error ${res.status}`)
  return z as Record<string, string>
}

/** a webinar date's values for messages (and the lead's own link on it) */
async function webinarVars(admin: SupabaseClient, ev: Row, leadId: string | null): Promise<Record<string, string>> {
  const { data: reg } = leadId
    ? await admin.from('webinar_registrations').select('join_url, short_link').eq('event_id', String(ev.id)).eq('lead_id', leadId).maybeSingle()
    : { data: null }
  return webinarVarsOf(ev, reg)
}
function webinarVarsOf(ev: Row, reg: { join_url?: string | null; short_link?: string | null } | null): Record<string, string> {
  const date = String(ev.event_date)
  const start = hm(ev.start_time) || '00:00'
  const end = hm(ev.end_time) || start
  const short = String(reg?.short_link ?? '')
  return {
    webinar_title: String(ev.title ?? ''),
    webinar_date: date,
    webinar_time: start,
    webinar_start: `${date} ${start}`,
    webinar_end: `${date} ${end}`,
    webinar_date_time: whenText(date, start, end),
    webinar_join_link: String(reg?.join_url ?? ''),
    webinar_short_link: short,
    webinar_short_link_code: short ? short.split('/').pop() ?? '' : '',
    event_title: String(ev.title ?? ''),
    event_date: niceDate(date),
    event_time: niceTime(start),
    event_link: short || String(reg?.join_url ?? '') || String(ev.meeting_link ?? ''),
  }
}

/** the webinar date of this run: its own (Before / After webinar), the one registered earlier in it, else the lead's latest */
async function runEvent(admin: SupabaseClient, run: Run, wf: Row, state: NonNullable<Run['state']>): Promise<Row | null> {
  let id = run.event_id ?? state.event_id ?? null
  if (!id && run.lead_id) {
    let q = admin.from('webinar_registrations').select('event_id').eq('lead_id', run.lead_id)
    if (wf.webinar_id) q = q.eq('webinar_id', String(wf.webinar_id))
    const { data } = await q.order('created_at', { ascending: false }).limit(1).maybeSingle()
    id = (data?.event_id as string | undefined) ?? null
  }
  if (!id) return null
  const { data: ev } = await admin.from('events').select('*').eq('id', id).maybeSingle()
  return (ev as Row | null) ?? null
}

/**
 * Register for webinar: the lead on the webinar's coming date (the next one; if one is on now, the one after), on Zoom
 * with their own join link (and a short link of it). Registering again for the same date gives the same link.
 */
async function registerWebinar(admin: SupabaseClient, run: Run, wf: Row, d: Record<string, unknown>, ctx: Ctx): Promise<{ wait: string } | { eventId: string; vars: Record<string, string>; detail: string }> {
  if (!run.lead_id) throw new Error(run.is_test ? 'A test run has no lead to register: try it with a real form post.' : 'No lead to register: add a Get lead details step before this one.')
  let webinarId = String(d.webinar_id ?? '') || String(wf.webinar_id ?? '')
  if (!webinarId && wf.funnel_id) {
    const { data } = await admin.from('webinars').select('id').eq('funnel_id', String(wf.funnel_id)).is('archived_at', null).order('created_at', { ascending: false }).limit(1).maybeSingle()
    webinarId = (data?.id as string | undefined) ?? ''
  }
  if (!webinarId) throw new Error('Pick the webinar to register for.')
  const { data: w } = await admin.from('webinars').select('id, title, tenant_id, archived_at').eq('id', webinarId).maybeSingle()
  if (!w || w.tenant_id !== run.tenant_id || w.archived_at) throw new Error('The webinar was deleted.')
  const { data: eventId, error } = await admin.rpc('webinar_upcoming', { p_webinar: webinarId })
  if (error) throw new Error(error.message)
  if (!eventId) throw new Error(`“${w.title}” has no coming date to register for.`)
  const { data: ev } = await admin.from('events').select('*').eq('id', String(eventId)).maybeSingle()
  if (!ev) throw new Error('The webinar date was deleted.')
  if (!ev.zoom_webinar_id) {
    if (ev.zoom_error) throw new Error(`The Zoom webinar of ${niceDate(ev.event_date)} couldn't be made: ${ev.zoom_error}`)
    if (!ev.zoom_account_id) throw new Error('The webinar has no Zoom account.')
    return { wait: `The Zoom webinar of ${niceDate(ev.event_date)} isn't ready yet.` }
  }

  let { data: reg } = await admin.from('webinar_registrations').select('*').eq('event_id', ev.id).eq('lead_id', run.lead_id).maybeSingle()
  let fresh = false
  if (!reg) {
    const { data: lead } = await admin.from('leads').select('first_name, last_name, email, phone').eq('id', run.lead_id).maybeSingle()
    // no email: the Zoom function registers them with <phone>@noemail.bizdock.in
    const email = String(lead?.email ?? '').trim()
    const z = await zoomFn(admin, { action: 'register', event_id: ev.id, email, first_name: lead?.first_name ?? '', last_name: lead?.last_name ?? '', phone: lead?.phone ?? '' })
    const { data: ins, error: insErr } = await admin
      .from('webinar_registrations')
      .upsert({ tenant_id: run.tenant_id, webinar_id: webinarId, event_id: ev.id, lead_id: run.lead_id, registrant_id: z.registrant_id || null, join_url: z.join_url }, { onConflict: 'event_id,lead_id' })
      .select('*')
      .single()
    if (insErr) throw new Error(insErr.message)
    reg = ins
    fresh = true
    await admin.from('lead_activities').insert({
      tenant_id: run.tenant_id,
      lead_id: run.lead_id,
      kind: 'note',
      note: `Registered for the webinar “${ev.title}” on ${niceDate(ev.event_date)} at ${niceTime(hm(ev.start_time))}`,
    })
  }
  if (d.short_link !== false && reg && reg.join_url && !reg.short_link) {
    const s = await makeShortLink(admin, run, { url: reg.join_url, var: 'webinar_short_link', base_url: d.base_url }, ctx)
    await admin.from('webinar_registrations').update({ short_link: s.short }).eq('id', reg.id)
    reg.short_link = s.short
  }
  const vars = webinarVarsOf(ev, reg)
  return {
    eventId: String(ev.id),
    vars,
    detail: `${fresh ? 'Registered' : 'Already registered'} for “${ev.title}” on ${niceDate(ev.event_date)} ${niceTime(hm(ev.start_time))}: ${vars.webinar_short_link || vars.webinar_join_link}`,
  }
}

const CATEGORY: Record<string, string> = { super_hot: 'Super Hot', hot: 'Hot', warm: 'Warm', cold: 'Cold' }
/**
 * How active the lead was in the webinar. Temporary rules (to be replaced by the client's):
 * didn't join → Cold; stayed 75%+ and asked / chatted / answered a poll → Super Hot; stayed 50%+ → Hot; else Warm.
 */
function categorize(a: { attended: boolean; percent: number; questions: number; chats: number; polls: number }) {
  if (!a.attended) return 'cold'
  if (a.percent >= 75 && a.questions + a.chats + a.polls > 0) return 'super_hot'
  if (a.percent >= 50) return 'hot'
  return 'warm'
}

/** Get webinar analytics: the lead's attendance, Q&A, chat and polls on the webinar date → their category (kept on the registration) */
async function webinarAnalytics(admin: SupabaseClient, run: Run, wf: Row, state: NonNullable<Run['state']>) {
  if (!run.lead_id) throw new Error('No lead: the analytics are the lead’s.')
  const ev = await runEvent(admin, run, wf, state)
  if (!ev) throw new Error('No webinar date for this lead: register them first or start from a Before / After webinar trigger.')
  const { data: lead } = await admin.from('leads').select('email').eq('id', run.lead_id).maybeSingle()
  const email = String(lead?.email ?? '').trim().toLowerCase()
  const who = email ? `lead_id.eq.${run.lead_id},email.eq.${email}` : `lead_id.eq.${run.lead_id}`
  const [{ data: att }, { data: com }] = await Promise.all([
    admin.from('zoom_attendance').select('minutes, join_time, leave_time').eq('event_id', String(ev.id)).or(who),
    admin.from('zoom_comments').select('kind').eq('event_id', String(ev.id)).or(who),
  ])
  const rows = (att ?? []) as { minutes: number | null; join_time: string | null; leave_time: string | null }[]
  const minutes = rows.reduce((n, r) => n + (Number(r.minutes) || 0), 0)
  const toMin = (t: unknown) => {
    const [h, m] = hm(t).split(':').map(Number)
    return h * 60 + m
  }
  const duration = Math.max(1, toMin(ev.end_time ?? ev.start_time) - toMin(ev.start_time))
  const percent = Math.min(100, Math.round((minutes / duration) * 100))
  const kinds = ((com ?? []) as { kind: string }[]).map((c) => c.kind)
  const questions = kinds.filter((k) => k === 'qa').length
  const chats = kinds.filter((k) => k === 'chat').length
  const polls = kinds.filter((k) => k === 'poll').length
  const attended = rows.length > 0
  const cat = categorize({ attended, percent, questions, chats, polls })
  const joined = rows.map((r) => r.join_time).filter(Boolean).sort()[0] ?? null
  if (ev.webinar_id)
    await admin
      .from('webinar_registrations')
      .upsert(
        { tenant_id: run.tenant_id, webinar_id: ev.webinar_id, event_id: ev.id, lead_id: run.lead_id, category: cat, attended_minutes: minutes, categorized_at: new Date().toISOString() },
        { onConflict: 'event_id,lead_id' },
      )
  await admin.from('lead_activities').insert({
    tenant_id: run.tenant_id,
    lead_id: run.lead_id,
    kind: 'note',
    note: `Webinar “${ev.title}” (${niceDate(String(ev.event_date))}): ${CATEGORY[cat]} · ${attended ? `attended ${minutes} min (${percent}%)` : 'didn’t join'}${questions ? ` · ${questions} question${questions > 1 ? 's' : ''}` : ''}${chats ? ` · ${chats} chat` : ''}${polls ? ` · ${polls} poll answer${polls > 1 ? 's' : ''}` : ''}`,
  })
  const vars: Record<string, string> = {
    webinar_category: CATEGORY[cat],
    webinar_attended: attended ? 'Yes' : 'No',
    webinar_minutes: String(minutes),
    webinar_attended_percent: String(percent),
    webinar_questions: String(questions),
    webinar_chats: String(chats),
    webinar_polls: String(polls),
    webinar_joined_at: joined ? (() => {
      const p = istParts(Date.parse(joined))
      return `${p.date} ${p.time}`
    })() : '',
  }
  return { vars, detail: `${CATEGORY[cat]}: ${attended ? `attended ${minutes} of ${duration} min (${percent}%)` : 'didn’t join'} · ${questions} Q&A · ${chats} chat · ${polls} poll` }
}

/** Bulk WhatsApp: the moment its times count from */
async function bulkBase(admin: SupabaseClient, run: Run, wf: Record<string, unknown>, d: Record<string, unknown>, ctx: Ctx): Promise<number> {
  const ist = (date: string, time: string | null) => Date.parse(`${date}T${(time ?? '00:00').slice(0, 5)}:00+05:30`)
  if (d.anchor === 'event') {
    let eventId = (wf.event_id as string | null) ?? null
    if (!eventId && wf.funnel_id) {
      const { data: f } = await admin.from('funnels').select('event_id').eq('id', wf.funnel_id).maybeSingle()
      eventId = f?.event_id ?? null
    }
    const { data: ev } = eventId ? await admin.from('events').select('event_date, start_time').eq('id', eventId).maybeSingle() : { data: null }
    if (!ev?.event_date) throw new Error('This workflow has no webinar / event to count the times from.')
    return ist(ev.event_date, ev.start_time)
  }
  if (d.anchor === 'meeting') {
    const { data: m } = run.lead_id
      ? await admin.from('meetings').select('meeting_date, start_time').eq('lead_id', run.lead_id).neq('status', 'cancelled').order('created_at', { ascending: false }).limit(1).maybeSingle()
      : { data: null }
    if (!m?.meeting_date) throw new Error(run.lead_id ? 'The lead has no meeting to count the times from.' : 'No lead, so no meeting to count the times from (pick a field instead).')
    return ist(m.meeting_date, m.start_time)
  }
  if (d.anchor === 'var') {
    const key = String(d.anchor_var ?? '')
    let raw: unknown = ctx.vars[key]
    if (raw == null || raw === '') {
      // a webhook field kept on the submission
      let sent: Record<string, unknown> = (run.is_test ? run.test_data : run.payload) ?? {}
      if (!run.is_test && !run.payload && run.submission_id) {
        const { data: sub } = await admin.from('lead_submissions').select('data').eq('id', run.submission_id).maybeSingle()
        sent = (sub?.data ?? {}) as Record<string, unknown>
      }
      raw = sent[key] ?? Object.entries(sent).find(([k]) => varKey(k) === key)?.[1]
    }
    const t = parseWhen(raw)
    if (t == null) throw new Error(`"${key}" has no readable date-time to count the times from${raw ? ` (got "${String(raw).slice(0, 40)}")` : ''}.`)
    return t
  }
  return new Date(run.created_at).getTime()
}

const fill = (s: string, vars: Record<string, string>) => s.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (_, k) => varValue(vars, k))

/**
 * {{x}} as is; {{x_date}} / {{x_time}} / {{x_datetime}} of a field x holding a date / date-time / time, in India time:
 * "29 Oct 2026" / "4:00 pm" / "29 Oct 2026, 4:00 pm" (a date only: no time; a time only: no date)
 */
function varValue(vars: Record<string, string>, k: string): string {
  if (vars[k] != null) return String(vars[k])
  const m = k.match(/^(.+)_(date|time|datetime)$/)
  if (!m || vars[m[1]] == null) return ''
  const w = readWhen(vars[m[1]])
  if (!w) return ''
  const date = w.date ? niceDate(w.date) : ''
  const time = w.time ? niceTime(w.time) : ''
  if (m[2] === 'date') return date
  if (m[2] === 'time') return time
  return [date, time].filter(Boolean).join(', ')
}

/** a date (YYYY-MM-DD) and / or a time (HH:MM), India time, from what a form / webhook / step sent */
function readWhen(raw: unknown): { date: string | null; time: string | null } | null {
  const v = String(raw ?? '').trim()
  if (!v) return null
  // a time alone: 16:00 / 4:00 pm / 4 pm
  let m = v.match(/^(\d{1,2})(?::(\d{2}))?(?::\d{2})?\s*([ap])?\.?\s*m?\.?$/i)
  if (m && (m[2] != null || m[3])) {
    let h = Number(m[1])
    if (m[3]) h = (h % 12) + (m[3].toLowerCase() === 'p' ? 12 : 0)
    return h < 24 ? { date: null, time: `${String(h).padStart(2, '0')}:${m[2] ?? '00'}` } : null
  }
  // 29/10/2026 or 29-10-2026 (day first), with an optional time
  m = v.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})(?:[ ,T]+(.+))?$/)
  if (m) {
    const date = `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`
    const t = m[4] ? readWhen(m[4])?.time ?? null : null
    return { date, time: t }
  }
  // a date alone
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return { date: v, time: null }
  // a date with a time, with or without a zone (no zone: India time)
  m = v.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{1,2}:\d{2}(?::\d{2})?\s*[ap]\.?m\.?)$/i)
  if (m) return { date: m[1], time: readWhen(m[2])?.time ?? null }
  const t = parseWhen(v)
  return t == null ? null : istParts(t)
}
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
/** 2026-10-29 → 29 Oct 2026 */
const niceDate = (d: string) => {
  const [y, mo, dd] = d.split('-').map(Number)
  return `${dd} ${MONTHS[mo - 1]} ${y}`
}
/** 16:00 → 4:00 pm */
const niceTime = (hm: string) => {
  const [h, mi] = hm.split(':').map(Number)
  return `${h % 12 === 0 ? 12 : h % 12}:${String(mi).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`
}

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

  // kept in WhatsApp logs (System Connections → WhatsApp → Logs), sent or failed
  const logRow = {
    tenant_id: run.tenant_id,
    direction: 'out',
    phone: to,
    lead_id: !d.to || d.to === 'lead' ? run.lead_id : null,
    template,
    source: 'workflow',
    workflow_id: run.workflow_id,
    run_id: run.id,
  }
  try {
    return await sendTemplate(admin, run, d, ctx, to, template, workflowName, logRow)
  } catch (e) {
    if (!run.is_test) await admin.from('whatsapp_logs').insert({ ...logRow, status: 'failed', error: (e as Error).message.slice(0, 300) })
    throw e
  }
}

async function sendTemplate(
  admin: SupabaseClient,
  run: Run,
  d: Record<string, unknown>,
  ctx: Ctx,
  to: string,
  template: string,
  workflowName: string,
  logRow: Record<string, unknown>,
) {
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

  const body = fill(String(d.template_body ?? d.message ?? ''), { ...ctx.vars, ...Object.fromEntries(parameters.map((p) => [p.name, p.value])) })
  if (!run.is_test)
    await admin.from('whatsapp_logs').insert({
      ...logRow,
      body,
      params: Object.fromEntries(parameters.map((p) => [p.name, p.value])),
      status: 'sent',
      wati_id: out.local_message_id ? String(out.local_message_id) : null,
    })
  // keep a copy on the lead (WhatsApp tab)
  if (run.lead_id && (!d.to || d.to === 'lead')) {
    await admin.from('lead_messages').insert({ tenant_id: run.tenant_id, lead_id: run.lead_id, channel: 'whatsapp', title: template, body, via: 'workflow' })
  }
  return `Sent "${template}" to +${to}`
}
