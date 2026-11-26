// lead-insight: the AI summary of a lead (Lead page → AI Insights), by Gemini — the workspace's key (System
// Connections → Gemini AI), counted in ai_usage (feature lead_insight), stopped by its monthly ₹ limit.
// Gemini gets the lead's details, follow-ups (comments / outcomes), notes, Callyzer call transcripts, AI calls
// (HelloRix: result, summary, answers, transcript), meetings,
// bookings / invoices / payments and WhatsApp messages — with the lead's name, phone numbers and emails hidden.
//
//   POST { action: 'cron' } + header x-cron-secret (public.workflow_cron_secret()), every minute while needed, ~45 s:
//     1. leads that changed (quiet for a minute) → rewritten, up to 30 a run (lead_insight_claim 'auto')
//     2. each workspace with Summarize leads on (lead_insight_syncs.active): leads with no summary yet
//        (newest first); the sync ends itself when none is left.
//     A failure is tried again on later runs (3 tries); a rate limit just ends that part of the run.
//   POST { action: 'refresh', lead_id } (from the app, logged in) → that lead now → { content, generated_at }
//   POST { action: 'lead', lead_id } + x-cron-secret (a workflow's AI call step) → that lead now
//
// It also names a lead's Source when its utm_source is a code not known yet (leads.utm_source_pending -> the AI ->
// lead_source_resolve: saved in source_aliases, every lead with that code gets it).
//
// Which AI writes it: System Connections → AI order → Lead AI Insights (Level 1, 2, 3; on / off; the prompt, empty =
// the default below). The monthly ₹ limit counts every AI.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'
import { AiBusy, aiAsk, aiRoute, logUsage, type Route } from '../_shared/ai.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const RUN_MS = 45_000
const BATCH = 5

class RateLimited extends Error {}

const PROMPT = `You are a sales assistant for an Indian business. Below is everything the CRM knows about one lead (a possible customer): the lead's details, follow-up calls and their comments, notes, phone call transcripts (Hindi / English / Hinglish), AI calls (an AI voice agent's calls with their transcripts), meetings, bookings and payments, and WhatsApp messages. The lead's name, phone numbers and emails are hidden ("the lead", [phone], [email]).

Write a short, practical summary for the business's team, in simple English, as JSON:
- summary: 2–3 lines: who the lead is, what they want, where things stand now.
- interest: level "hot" (ready to buy / book soon), "warm" (interested, not decided) or "cold" (not interested, not reachable, or no reply); why: one line.
- needs, budget, timeline: one short line each; "Not mentioned" when nothing says it.
- objections: what holds them back (price, time, trust, …), short items; empty if none.
- next_action: the one best thing the team should do next (what, and when if it's clear).
- risks: what could make this lead go cold or be lost, short items; empty if none.
- asked_for: what the lead asked the business for, in their own words where possible (more details on a product or package, a price list, a call back at a time, a demo, a document on WhatsApp, …), short items, newest first; empty if none.
Use only what the records say; don't invent facts. Dates are in India time.`

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    summary: { type: 'STRING' },
    interest: { type: 'OBJECT', properties: { level: { type: 'STRING', enum: ['hot', 'warm', 'cold'] }, why: { type: 'STRING' } }, required: ['level', 'why'] },
    needs: { type: 'STRING' },
    budget: { type: 'STRING' },
    timeline: { type: 'STRING' },
    objections: { type: 'ARRAY', items: { type: 'STRING' } },
    next_action: { type: 'STRING' },
    risks: { type: 'ARRAY', items: { type: 'STRING' } },
    asked_for: { type: 'ARRAY', items: { type: 'STRING' } },
  },
  required: ['summary', 'interest', 'needs', 'budget', 'timeline', 'objections', 'next_action', 'risks', 'asked_for'],
}

const ist = (s: string | null | undefined) =>
  s ? new Date(s).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit' }) : '—'
const cut = (s: unknown, n: number) => {
  const t = String(s ?? '').trim()
  return t.length > n ? `${t.slice(0, n)}…` : t
}
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** hides the lead's name, phone numbers and emails (and the names in "Team (…)" / "Customer (…)") */
function masker(lead: Record<string, unknown>) {
  const names = [lead.first_name, lead.last_name]
    .map((x) => String(x ?? '').trim())
    .flatMap((x) => [x, ...x.split(/\s+/)])
    .filter((x) => x.length >= 3)
    .sort((a, b) => b.length - a.length)
  const nameRe = names.length ? new RegExp(`\\b(${[...new Set(names)].map(esc).join('|')})\\b`, 'gi') : null
  return (s: unknown) => {
    let t = String(s ?? '')
    t = t.replace(/\b(Team|Customer)\s*\([^)]*\)/g, '$1')
    t = t.replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, '[email]')
    t = t.replace(/\+?\d[\d\s-]{8,}\d/g, '[phone]')
    if (nameRe) t = t.replace(nameRe, 'the lead')
    return t
  }
}

/** everything about the lead, as text for Gemini */
async function gather(admin: SupabaseClient, leadId: string) {
  const { data: lead } = await admin.from('leads').select('*').eq('id', leadId).maybeSingle()
  if (!lead) throw new Error('Lead not found.')
  const m = masker(lead)
  const t = lead.tenant_id as string
  const [stage, funnel, source, biz, lost, fus, outs, acts, calls, meets, books, invs, wa, aic] = await Promise.all([
    lead.stage_id ? admin.from('funnel_stages').select('name, kind').eq('id', lead.stage_id).maybeSingle() : Promise.resolve({ data: null }),
    lead.funnel_id ? admin.from('funnels').select('name').eq('id', lead.funnel_id).maybeSingle() : Promise.resolve({ data: null }),
    lead.source_id ? admin.from('lead_sources').select('name').eq('id', lead.source_id).maybeSingle() : Promise.resolve({ data: null }),
    lead.business_id ? admin.from('businesses').select('name').eq('id', lead.business_id).maybeSingle() : Promise.resolve({ data: null }),
    lead.lost_reason_id ? admin.from('lost_reasons').select('name').eq('id', lead.lost_reason_id).maybeSingle() : Promise.resolve({ data: null }),
    admin.from('follow_ups').select('due_at, completed_at, mode, purpose, status, outcome_id, result_note').eq('lead_id', leadId).order('due_at', { ascending: false }).limit(30),
    admin.from('follow_up_outcomes').select('id, name').eq('tenant_id', t),
    admin.from('lead_activities').select('kind, note, created_at').eq('lead_id', leadId).in('kind', ['note', 'stage', 'temperature', 'created', 'submission']).order('created_at', { ascending: false }).limit(30),
    admin.from('calls').select('started_at, direction, duration_sec, outcome, transcript').eq('lead_id', leadId).order('started_at', { ascending: false }).limit(15),
    admin.from('meetings').select('meeting_date, start_time, mode, status, title, outcome_note, agenda').eq('lead_id', leadId).order('meeting_date', { ascending: false }).limit(10),
    admin.from('bookings').select('booking_date, purpose, status, total_amount, paid_amount, order_status').eq('lead_id', leadId).order('booking_date', { ascending: false }).limit(15),
    admin.from('invoices').select('id, invoice_date, total_amount, paid_amount').eq('lead_id', leadId).order('invoice_date', { ascending: false }).limit(15),
    admin.from('whatsapp_logs').select('sent_at, direction, template, body, status').eq('lead_id', leadId).order('sent_at', { ascending: false }).limit(15),
    admin.from('ai_calls').select('placed_at, objective_name, status, outcome, summary, collected, talk_seconds, transcript').eq('lead_id', leadId).eq('final', true).order('placed_at', { ascending: false }).limit(10),
  ])
  const outName = new Map(((outs.data ?? []) as { id: string; name: string }[]).map((o) => [o.id, o.name]))
  const L: string[] = []
  const now = new Date()
  L.push(`Today: ${ist(now.toISOString())}`)
  L.push('', 'LEAD')
  const extra = Object.entries((lead.extra ?? {}) as Record<string, unknown>)
    .filter(([k, v]) => String(v ?? '').trim() && !/name|phone|mobile|email|whatsapp/i.test(k))
    .slice(0, 25)
  const row = (k: string, v: unknown) => {
    if (v !== null && v !== undefined && String(v).trim() !== '') L.push(`- ${k}: ${m(cut(v, 400))}`)
  }
  row('Added', ist(lead.created_at))
  row('Business', biz.data?.name)
  row('Funnel', funnel.data?.name)
  row('Stage', stage.data ? `${stage.data.name}${stage.data.kind && stage.data.kind !== 'open' ? ` (${stage.data.kind})` : ''}` : null)
  row('Category', lead.temperature)
  row('Source', source.data?.name)
  row('Purpose', lead.purpose)
  row('City', lead.city)
  row('Required on', lead.required_on)
  row('Estimated amount', lead.estimated_amount ? `₹${lead.estimated_amount}` : null)
  row('Tags', (lead.tags ?? []).join(', '))
  row('Lost reason', lost.data?.name)
  row('UTM', [lead.utm_source, lead.utm_medium, lead.utm_campaign].filter(Boolean).join(' / '))
  row('Description', lead.notes)
  for (const [k, v] of extra) row(k.replace(/_/g, ' '), typeof v === 'object' ? JSON.stringify(v) : v)

  const f = (fus.data ?? []) as Record<string, string | null>[]
  if (f.length) {
    L.push('', 'FOLLOW-UPS (newest first)')
    for (const x of f)
      L.push(`- ${x.status === 'done' ? `done ${ist(x.completed_at)}` : `${x.status} · due ${ist(x.due_at)}`} · ${x.mode ?? ''}${x.purpose ? ` · ${m(cut(x.purpose, 120))}` : ''}${x.outcome_id ? ` · outcome: ${outName.get(x.outcome_id) ?? ''}` : ''}${x.result_note ? ` · comment: ${m(cut(x.result_note, 400))}` : ''}`)
  }
  const a = (acts.data ?? []) as Record<string, string | null>[]
  if (a.length) {
    L.push('', 'NOTES & CHANGES (newest first)')
    for (const x of a) L.push(`- ${ist(x.created_at)} · ${x.kind}${x.note ? `: ${m(cut(x.note, 400))}` : ''}`)
  }
  const c = (calls.data ?? []) as Record<string, string | number | null>[]
  if (c.length) {
    L.push('', 'PHONE CALLS (newest first)')
    let budget = 24_000
    for (const x of c) {
      L.push(`- ${ist(x.started_at as string)} · ${x.direction ?? ''} · ${x.outcome ?? ''} · ${Math.round(Number(x.duration_sec ?? 0))} s`)
      if (x.transcript && budget > 0) {
        const tr = m(cut(x.transcript, Math.min(6000, budget)))
        budget -= tr.length
        L.push(`  Transcript:\n  ${tr.replace(/\n/g, '\n  ')}`)
      }
    }
  }
  const ac = (aic.data ?? []) as Record<string, unknown>[]
  if (ac.length) {
    L.push('', 'AI CALLS (an AI voice agent called the lead; newest first)')
    let budget = 16_000
    for (const x of ac) {
      L.push(`- ${ist(x.placed_at as string)} · ${x.objective_name ?? 'call'} · ${x.outcome ?? x.status ?? ''}${x.talk_seconds ? ` · ${Math.round(Number(x.talk_seconds))} s` : ''}`)
      if (x.summary) L.push(`  Summary: ${m(cut(x.summary, 600))}`)
      const ans = Object.entries((x.collected ?? {}) as Record<string, unknown>).filter(([, v]) => v !== null && v !== '' && typeof v !== 'object')
      if (ans.length) L.push(`  Answers: ${m(cut(ans.map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v}`).join(' · '), 600))}`)
      const turns = Array.isArray(x.transcript) ? (x.transcript as { speaker?: string; text?: string }[]) : []
      if (turns.length && budget > 0) {
        const tr = m(cut(turns.map((t) => `${t.speaker === 'agent' ? 'AI' : 'Lead'}: ${t.text ?? ''}`).join('\n'), Math.min(5000, budget)))
        budget -= tr.length
        L.push(`  Transcript:\n  ${tr.replace(/\n/g, '\n  ')}`)
      }
    }
  }
  const mt = (meets.data ?? []) as Record<string, string | null>[]
  if (mt.length) {
    L.push('', 'MEETINGS')
    for (const x of mt) L.push(`- ${x.meeting_date} ${x.start_time ?? ''} · ${x.mode ?? ''} · ${x.status ?? ''}${x.title ? ` · ${m(cut(x.title, 120))}` : ''}${x.outcome_note ? ` · note: ${m(cut(x.outcome_note, 300))}` : ''}`)
  }
  const b = (books.data ?? []) as Record<string, string | number | null>[]
  if (b.length) {
    L.push('', 'BOOKINGS / ORDERS')
    for (const x of b) L.push(`- ${x.booking_date} · ${m(cut(x.purpose, 120))} · ${x.status ?? ''}${x.order_status ? `/${x.order_status}` : ''} · total ₹${x.total_amount ?? 0} · paid ₹${x.paid_amount ?? 0}`)
  }
  const iv = (invs.data ?? []) as Record<string, string | number | null>[]
  if (iv.length) {
    const { data: pays } = await admin.from('invoice_payments').select('invoice_id, amount, status, due_on, paid_on').in('invoice_id', iv.map((x) => x.id as string))
    L.push('', 'INVOICES & PAYMENTS')
    for (const x of iv) {
      L.push(`- invoice ${x.invoice_date} · total ₹${x.total_amount ?? 0} · paid ₹${x.paid_amount ?? 0}`)
      for (const p of ((pays ?? []) as Record<string, string | number | null>[]).filter((p) => p.invoice_id === x.id))
        L.push(`  · ₹${p.amount} ${p.status}${p.paid_on ? ` on ${p.paid_on}` : p.due_on ? ` due ${p.due_on}` : ''}`)
    }
  }
  const w = (wa.data ?? []) as Record<string, string | null>[]
  if (w.length) {
    L.push('', 'WHATSAPP (newest first)')
    for (const x of w) L.push(`- ${ist(x.sent_at)} · ${x.direction === 'in' ? 'from the lead' : 'to the lead'} · ${x.status ?? ''}${x.template ? ` · template ${x.template}` : ''}${x.body ? `: ${m(cut(x.body, 300))}` : ''}`)
  }
  return { tenantId: t, text: L.join('\n') }
}

const SRC_PROMPT = `A CRM lead came from an ad or link whose utm_source is a short code. Tell which platform the lead saw it on, as the name the business uses in its list of sources when one fits (e.g. ig → Instagram, fb → Facebook, th → Threads, yt → YouTube, an → Facebook Audience Network). Reply with a short platform name (1–3 words). If the code doesn't name a platform (e.g. "manual", "test"), reply "Other".`

/** a lead waiting on a new utm_source code (leads.utm_source_pending): the AI names its Source once for the workspace */
async function resolveSource(admin: SupabaseClient, route: Route, tenantId: string, leadId: string) {
  const { data: l } = await admin.from('leads').select('utm_source_pending').eq('id', leadId).maybeSingle()
  const code = String(l?.utm_source_pending ?? '').trim()
  if (!code) return
  const { data: srcs } = await admin.from('lead_sources').select('name').eq('tenant_id', tenantId).eq('is_active', true).order('sort_order')
  const names = ((srcs ?? []) as { name: string }[]).map((x) => x.name)
  const res = await aiAsk(
    route,
    {
      system: SRC_PROMPT,
      messages: [{ role: 'user', text: `utm_source: "${code}"\nThe business's sources: ${names.join(', ') || '(none yet)'}` }],
      schema: { type: 'OBJECT', properties: { source: { type: 'STRING' } }, required: ['source'] },
      jsonShape: '{"source": string}',
      maxTokens: 200,
    },
    (o) => {
      if (!String(o.json?.source ?? '').trim()) throw new Error('no source')
    },
  )
  await logUsage(admin, tenantId, res, 'lead_insight')
  const name = String(res.json!.source).trim().slice(0, 60)
  // the business's own spelling when it has that source
  const own = names.find((n) => n.toLowerCase() === name.toLowerCase()) ?? name
  await admin.rpc('lead_source_resolve', { p_tenant: tenantId, p_code: code, p_name: own })
}

const JSON_SHAPE = `{"summary": string, "interest": {"level": "hot" | "warm" | "cold", "why": string}, "needs": string, "budget": string, "timeline": string, "objections": string[], "next_action": string, "risks": string[], "asked_for": string[]}`

/** one lead → the AI order (System Connections → AI order → Lead AI Insights) → summary saved */
async function summarize(admin: SupabaseClient, cache: Map<string, Route>, leadId: string) {
  const t0 = new Date().toISOString()
  const { data: row } = await admin.from('lead_insights').select('tries').eq('lead_id', leadId).maybeSingle()
  let tenantId = ''
  try {
    const { tenantId: t, text } = await gather(admin, leadId)
    tenantId = t
    let route = cache.get(t)
    if (!route) {
      route = await aiRoute(admin, t, 'lead_insight')
      cache.set(t, route)
    }
    if (!route.enabled) throw new Error('Lead AI Insights are turned off (System Connections → AI order).')
    if (route.limitHit) throw new Error(route.limitHit)
    // a new utm_source code: its Source first (a failure here doesn't stop the summary)
    try {
      await resolveSource(admin, route, t, leadId)
    } catch (e) {
      if (e instanceof AiBusy) throw e
      console.error('source', leadId, (e as Error).message)
    }
    const res = await aiAsk(route, { system: route.prompt ?? PROMPT, messages: [{ role: 'user', text }], schema: SCHEMA, jsonShape: JSON_SHAPE, maxTokens: 4000 }, (o) => {
      if (!o.json?.summary) throw new Error('no summary')
    })
    await logUsage(admin, t, res, 'lead_insight')
    const content = res.json!
    const at = new Date().toISOString()
    await admin.from('lead_insights').upsert({ lead_id: leadId, tenant_id: t, content, model: res.model, generated_at: at, lease: null, tries: 0, error: null })
    // done — unless the lead changed again while this was being written
    await admin.from('lead_insights').update({ stale: false }).eq('lead_id', leadId).lte('stale_at', t0)
    return { content, generated_at: at }
  } catch (e) {
    if (e instanceof AiBusy) {
      await admin.from('lead_insights').update({ lease: null }).eq('lead_id', leadId)
      throw new RateLimited(e.message)
    }
    const msg = (e as Error).message
    // no AI / limit used up / turned off: not the lead's fault, no try counted
    const tries = Number(row?.tries ?? 0) + (/AI limit|not connected|turned off|No AI is set/.test(msg) ? 0 : 1)
    if (tenantId) await admin.from('lead_insights').update({ tries, error: msg.slice(0, 300), lease: null }).eq('lead_id', leadId)
    throw e
  }
}

/** claim and work through leads until the time, the count or a stop */
async function work(admin: SupabaseClient, cache: Map<string, Route>, mode: 'auto' | 'sync', tenant: string | null, max: number, until: number) {
  let done = 0
  let failed = 0
  let stop = ''
  while (Date.now() < until && !stop && done + failed < max) {
    const { data: ids } = await admin.rpc('lead_insight_claim', { p_limit: Math.min(BATCH, max - done - failed), p_mode: mode, p_tenant: tenant })
    const list = ((ids ?? []) as unknown[]).map((x) => String(typeof x === 'object' && x ? Object.values(x)[0] : x))
    if (!list.length) break
    const res = await Promise.allSettled(list.map((id) => summarize(admin, cache, id)))
    for (const r of res) {
      if (r.status === 'fulfilled') done++
      else {
        failed++
        if (r.reason instanceof RateLimited) stop = 'rate limit'
        else if (mode === 'sync' && /AI limit|not connected|turned off|No AI is set/.test(String(r.reason?.message))) stop = String(r.reason.message)
      }
    }
  }
  return { done, failed, stop: stop || null }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const b = await req.json().catch(() => ({}))
  const cache = new Map<string, Route>()

  if (b.action === 'cron') {
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'Not allowed' }, 401)
    const until = Date.now() + RUN_MS
    // 1. leads that changed
    const auto = await work(admin, cache, 'auto', null, 30, until)
    // 2. Summarize leads
    const syncs: Record<string, unknown> = {}
    const { data: on } = await admin.from('lead_insight_syncs').select('tenant_id').eq('active', true)
    for (const s of (on ?? []) as { tenant_id: string }[]) {
      const t = s.tenant_id
      const ai = await aiRoute(admin, t, 'lead_insight')
      cache.set(t, ai)
      const why = !ai.enabled ? 'Lead AI Insights are turned off.' : ai.limitHit ?? (!ai.levels.some((l) => l.key) ? 'No AI in its order is connected.' : null)
      if (why) {
        await admin.from('lead_insight_syncs').update({ active: false, finished_at: new Date().toISOString(), note: `Stopped: ${why}` }).eq('tenant_id', t)
        syncs[t] = { stop: why }
        continue
      }
      const r = await work(admin, cache, 'sync', t, 60, until)
      syncs[t] = r
      if (!r.stop && !r.done && !r.failed && Date.now() < until) {
        await admin.from('lead_insight_syncs').update({ active: false, finished_at: new Date().toISOString(), note: 'Done' }).eq('tenant_id', t)
      }
    }
    return json({ ok: true, auto, syncs })
  }

  if (b.action === 'lead') {
    // a workflow's AI call step (Received & lead updated): this lead now
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'Not allowed' }, 401)
    const { data: lead } = await admin.from('leads').select('id, tenant_id').eq('id', String(b.lead_id)).maybeSingle()
    if (!lead) return json({ error: 'Lead not found.' }, 404)
    await admin.from('lead_insights').upsert({ lead_id: lead.id, tenant_id: lead.tenant_id, stale: true, stale_at: new Date().toISOString(), tries: 0, error: null })
    try {
      const r = await summarize(admin, cache, String(lead.id))
      return json({ ok: true, generated_at: r.generated_at })
    } catch (e) {
      return json({ error: e instanceof RateLimited ? 'the AI is busy (rate limit)' : (e as Error).message })
    }
  }

  if (b.action === 'refresh') {
    const auth = req.headers.get('Authorization') ?? ''
    const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
    const { data: me } = await asCaller.auth.getUser()
    if (!me.user) return json({ error: 'Please log in again.' }, 401)
    // the caller must be able to see the lead
    const { data: seen } = await asCaller.from('leads').select('id, tenant_id').eq('id', String(b.lead_id)).maybeSingle()
    if (!seen) return json({ error: 'Lead not found.' }, 404)
    await admin.from('lead_insights').upsert({ lead_id: seen.id, tenant_id: seen.tenant_id, stale: true, stale_at: new Date().toISOString(), tries: 0, error: null })
    try {
      return json({ ok: true, ...(await summarize(admin, cache, String(seen.id))) })
    } catch (e) {
      return json({ error: e instanceof RateLimited ? 'Gemini is busy (rate limit). Try again in a minute.' : (e as Error).message })
    }
  }
  return json({ error: 'Unknown action' }, 400)
})
