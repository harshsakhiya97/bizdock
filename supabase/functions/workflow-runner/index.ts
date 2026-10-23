// workflow-runner: runs workflows step by step (first version).
//
//   POST { action: 'cron' } + header x-cron-secret   → takes the due runs and moves each one forward
//     (called by pg_cron every minute and straight after a form submission starts a run;
//      the secret lives in the vault: public.workflow_cron_secret())
//
// Steps done now: WhatsApp (approved template through WATI) and Wait. Email, Call, Wait for event and
// Go to workflow are skipped (logged), Yes/No and Switch stop the run — they come later.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

type Node = { id: string; type: string; data: Record<string, unknown> }
type Edge = { source: string; target: string; sourceHandle?: string | null }
type Run = { id: string; tenant_id: string; workflow_id: string; lead_id: string | null; submission_id: string | null; node_id: string; log: LogLine[] }
type LogLine = { at: string; node_id: string; kind: string; status: 'ok' | 'skipped' | 'failed' | 'waiting' | 'stopped'; detail: string }

const MAX_STEPS = 25
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
  const save = (patch: Record<string, unknown>) =>
    admin.from('workflow_runs').update({ ...patch, log, updated_at: new Date().toISOString() }).eq('id', run.id)

  const { data: wf } = await admin.from('workflows').select('id, name, is_active, archived_at, nodes, edges').eq('id', run.workflow_id).maybeSingle()
  if (!wf) return save({ status: 'stopped', error: 'The workflow was deleted.' })
  if (!wf.is_active || wf.archived_at) return save({ status: 'stopped', error: 'The workflow was switched off.' })
  const nodes = (wf.nodes ?? []) as Node[]
  const edges = (wf.edges ?? []) as Edge[]
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const nextOf = (id: string) => {
    const e = edges.find((x) => x.source === id && !x.sourceHandle) ?? edges.find((x) => x.source === id)
    return e ? byId.get(e.target) ?? null : null
  }

  const ctx = await context(admin, run)
  let at = run.node_id
  for (let i = 0; i < MAX_STEPS; i++) {
    const n = nextOf(at)
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

type Ctx = { vars: Record<string, string>; leadPhone: string | null; tenantId: string }

async function context(admin: SupabaseClient, run: Run): Promise<Ctx> {
  const { data: lead } = run.lead_id
    ? await admin.from('leads').select('first_name, last_name, phone, whatsapp, email, city, business_id, funnel_id, landing_page_id').eq('id', run.lead_id).maybeSingle()
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
  if (run.lead_id && d.to !== 'team') {
    const body = fill(String(d.template_body ?? d.message ?? ''), { ...ctx.vars, ...Object.fromEntries(parameters.map((p) => [p.name, p.value])) })
    await admin.from('lead_messages').insert({ tenant_id: run.tenant_id, lead_id: run.lead_id, channel: 'whatsapp', title: template, body, via: 'workflow' })
  }
  return `Sent "${template}" to +${to}`
}
