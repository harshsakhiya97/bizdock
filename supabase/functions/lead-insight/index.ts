// lead-insight: the AI summary of a lead (Lead page → AI Insights), by Gemini — the workspace's key (System
// Connections → Gemini AI), counted in ai_usage (feature lead_insight), stopped by its monthly ₹ limit.
// Gemini gets the lead's details, follow-ups (comments / outcomes), notes, Callyzer call transcripts, meetings,
// bookings / invoices / payments and WhatsApp messages — with the lead's name, phone numbers and emails hidden.
//
//   POST { action: 'cron' } + header x-cron-secret (public.workflow_cron_secret()), every minute while needed, ~45 s:
//     1. leads that changed (quiet for a minute) → rewritten, up to 30 a run (lead_insight_claim 'auto')
//     2. each workspace with Summarize leads on (lead_insight_syncs.active): leads with no summary yet
//        (newest first); the sync ends itself when none is left.
//     A failure is tried again on later runs (3 tries); a rate limit just ends that part of the run.
//   POST { action: 'refresh', lead_id } (from the app, logged in) → that lead now → { content, generated_at }
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const RUN_MS = 45_000
const BATCH = 5

type Gem = { id: string; key: string; model: string; priceIn: number; priceOut: number; limit: number } | { error: string }
class RateLimited extends Error {}

/** the workspace's Gemini connection (cached for the run) */
async function geminiFor(admin: SupabaseClient, cache: Map<string, Gem>, tenantId: string): Promise<Gem> {
  const hit = cache.get(tenantId)
  if (hit) return hit
  const { data: conn } = await admin.from('integrations').select('id, config').eq('tenant_id', tenantId).eq('provider', 'gemini').eq('is_enabled', true).order('updated_at', { ascending: false }).limit(1).maybeSingle()
  const cfg = (conn?.config ?? {}) as Record<string, string>
  const key = String(cfg.api_key ?? '').trim()
  const g: Gem = !conn || !key
    ? { error: 'Gemini AI is not connected.' }
    : { id: String(conn.id), key, model: String(cfg.model || 'gemini-flash-latest'), priceIn: Number(cfg.price_in || 0), priceOut: Number(cfg.price_out || 0), limit: Number(cfg.monthly_limit || 0) }
  if (!('error' in g) && g.limit > 0) {
    const ist = new Date(Date.now() + 330 * 60_000)
    const start = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), 1) - 330 * 60_000).toISOString()
    const { data } = await admin.from('ai_usage').select('input_tokens, output_tokens').eq('tenant_id', tenantId).not('model', 'ilike', 'claude%').gte('created_at', start).limit(200000)
    const spent = ((data ?? []) as { input_tokens: number; output_tokens: number }[]).reduce((t, r) => t + Number(r.input_tokens) * g.priceIn + Number(r.output_tokens) * g.priceOut, 0) / 1e6
    if (spent >= g.limit) {
      const out = { error: `This month’s AI limit (₹${g.limit}) is used up.` }
      cache.set(tenantId, out)
      return out
    }
  }
  cache.set(tenantId, g)
  return g
}

const PROMPT = `You are a sales assistant for an Indian business. Below is everything the CRM knows about one lead (a possible customer): the lead's details, follow-up calls and their comments, notes, phone call transcripts (Hindi / English / Hinglish), meetings, bookings and payments, and WhatsApp messages. The lead's name, phone numbers and emails are hidden ("the lead", [phone], [email]).

Write a short, practical summary for the business's team, in simple English, as JSON:
- summary: 2–3 lines: who the lead is, what they want, where things stand now.
- interest: level "hot" (ready to buy / book soon), "warm" (interested, not decided) or "cold" (not interested, not reachable, or no reply); why: one line.
- needs, budget, timeline: one short line each; "Not mentioned" when nothing says it.
- objections: what holds them back (price, time, trust, …), short items; empty if none.
- next_action: the one best thing the team should do next (what, and when if it's clear).
- risks: what could make this lead go cold or be lost, short items; empty if none.
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
  },
  required: ['summary', 'interest', 'needs', 'budget', 'timeline', 'objections', 'next_action', 'risks'],
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
  const [stage, funnel, source, biz, lost, fus, outs, acts, calls, meets, books, invs, wa] = await Promise.all([
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

/** one lead → Gemini → summary saved */
async function summarize(admin: SupabaseClient, cache: Map<string, Gem>, leadId: string) {
  const t0 = new Date().toISOString()
  const { data: row } = await admin.from('lead_insights').select('tries').eq('lead_id', leadId).maybeSingle()
  let tenantId = ''
  try {
    const { tenantId: t, text } = await gather(admin, leadId)
    tenantId = t
    const g = await geminiFor(admin, cache, t)
    if ('error' in g) throw new Error(g.error)
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(g.model)}:generateContent`, {
      method: 'POST',
      headers: { 'x-goog-api-key': g.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: PROMPT }] },
        contents: [{ role: 'user', parts: [{ text }] }],
        generationConfig: { temperature: 0.3, maxOutputTokens: 4000, responseMimeType: 'application/json', responseSchema: SCHEMA },
      }),
    })
    const d = await r.json().catch(() => ({}))
    if (r.status === 429) throw new RateLimited(d?.error?.message ?? 'Gemini rate limit')
    if (!r.ok) throw new Error(d?.error?.message ? `Gemini: ${d.error.message}` : `Gemini error ${r.status}`)
    const out = ((d?.candidates?.[0]?.content?.parts ?? []) as { text?: string; thought?: boolean }[]).filter((p) => !p.thought).map((p) => p.text ?? '').join('')
    let content: Record<string, unknown>
    try {
      content = JSON.parse(out)
    } catch {
      throw new Error(`Gemini gave no usable answer (${d?.candidates?.[0]?.finishReason ?? 'empty'})`)
    }
    const u = d?.usageMetadata ?? {}
    await admin.from('ai_usage').insert({
      tenant_id: t,
      integration_id: g.id,
      model: g.model,
      feature: 'lead_insight',
      input_tokens: Number(u.promptTokenCount ?? 0),
      output_tokens: Number(u.candidatesTokenCount ?? 0) + Number(u.thoughtsTokenCount ?? 0),
      member_id: null,
    })
    const at = new Date().toISOString()
    await admin.from('lead_insights').upsert({ lead_id: leadId, tenant_id: t, content, model: g.model, generated_at: at, lease: null, tries: 0, error: null })
    // done — unless the lead changed again while this was being written
    await admin.from('lead_insights').update({ stale: false }).eq('lead_id', leadId).lte('stale_at', t0)
    return { content, generated_at: at }
  } catch (e) {
    if (e instanceof RateLimited) {
      await admin.from('lead_insights').update({ lease: null }).eq('lead_id', leadId)
      throw e
    }
    const msg = (e as Error).message
    // no Gemini / limit used up: not the lead's fault, no try counted
    const tries = Number(row?.tries ?? 0) + (/AI limit|not connected/.test(msg) ? 0 : 1)
    if (tenantId) await admin.from('lead_insights').update({ tries, error: msg.slice(0, 300), lease: null }).eq('lead_id', leadId)
    throw e
  }
}

/** claim and work through leads until the time, the count or a stop */
async function work(admin: SupabaseClient, cache: Map<string, Gem>, mode: 'auto' | 'sync', tenant: string | null, max: number, until: number) {
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
        else if (mode === 'sync' && /AI limit|not connected/.test(String(r.reason?.message))) stop = String(r.reason.message)
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
  const cache = new Map<string, Gem>()

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
      const g = await geminiFor(admin, cache, t)
      if ('error' in g) {
        await admin.from('lead_insight_syncs').update({ active: false, finished_at: new Date().toISOString(), note: `Stopped: ${g.error}` }).eq('tenant_id', t)
        syncs[t] = { stop: g.error }
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
