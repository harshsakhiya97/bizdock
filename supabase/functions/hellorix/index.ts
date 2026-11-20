// hellorix: AI Calling through the HelloRix voice API (System Connections → AI Calling).
//
// From the app (logged in):
//   { action: 'options', api_key? | id? }       caller numbers, voices and personas of a key (the Keys form)
//   { action: 'test', id }                      check the saved key, keep its options, mark it connected
//   { action: 'templates' }                     the workspace's templates (HelloRix objectives)
//   { action: 'template', objective_id }        one template, for the editor (the auto-added opening hidden)
//   { action: 'template_save', objective_id?, form }   create / edit a template
//   { action: 'template_delete', objective_id }
//   { action: 'draft', language, goal, business }      Write with AI (the workspace's Gemini key)
//   { action: 'call', to, name?, lead_id?, objective_id?, via? }   place a call now
//   { action: 'detail', id }                    a call fresh from HelloRix, with its transcript
//   { action: 'sync' }                          ask HelloRix about this workspace's unfinished calls
// From HelloRix: the call.completed webhook   (?i=<integration id>, signed with the connection's webhook secret)
// From pg_cron / the workflow runner (x-cron-secret):
//   { action: 'cron' }                          unfinished calls of every workspace
//   { action: 'run_call', tenant_id, run_id, lead_id?, to, name?, objective_id, variables? }   a workflow's AI call step
//
// The key never reaches the browser. Each call is kept in ai_calls with HelloRix's cost (₹).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const BASE = 'https://app.hellorix.ai/api/external/v1'
const FINAL = ['completed', 'no_answer', 'busy', 'failed', 'cancelled', 'expired']
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)
const admin = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

type Cfg = Record<string, string>
type Conn = { id: string; tenant_id: string; config: Cfg; status: string }

// ---------- HelloRix ----------
async function hx(key: string, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  let r: Response
  try {
    r = await fetch(BASE + path, {
      method,
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Accept: 'application/json', ...headers },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(30000),
    })
  } catch {
    throw new Error('Could not reach HelloRix. Try again in a minute.')
  }
  const text = await r.text()
  let d: Record<string, unknown>
  try {
    d = JSON.parse(text)
  } catch {
    d = { error: 'non_json', message: text.slice(0, 200) }
  }
  return { status: r.status, d }
}
const FRIENDLY: Record<string, string> = {
  invalid_phone: 'This number is not valid.',
  quiet_hours: 'Calls are not allowed at this time (quiet hours).',
  recipient_not_allowlisted: 'This number is not allowed for calling on the HelloRix account.',
  no_voice_line: 'No calling number is connected on HelloRix.',
  objective_not_found: 'The template was not found on HelloRix.',
  objective_not_published: 'The template is not published on HelloRix.',
  missing_parameters: 'The template needs a value that was not given.',
  service_unavailable: 'HelloRix is busy. Try again in a minute.',
  insufficient_balance: 'The HelloRix balance is empty: recharge it on hellorix.ai to keep calling.',
  objective_in_use: 'This template is used by a running HelloRix campaign and can’t be changed now.',
  prompt_with_script_fields: 'A full prompt can’t be mixed with the guided fields.',
}
function friendly(d: Record<string, unknown>, status: number) {
  const code = String(d?.error ?? '')
  if (code === 'call_refused') return `Call refused: ${String(d.message ?? 'not allowed right now')}.`
  if (status === 401) return 'HelloRix refused the API key: check it in System Connections → AI Calling.'
  if (status === 403) return 'The HelloRix key needs the campaigns.run and campaigns.view permissions.'
  return FRIENDLY[code] ?? String(d?.message ?? `HelloRix error ${status}`)
}
const listOf = (d: Record<string, unknown>, k: string) => ((d[k] ?? d.data ?? []) as Record<string, unknown>[])

// ---------- the connection ----------
async function connOf(db: SupabaseClient, tenantId: string): Promise<Conn | null> {
  const { data } = await db.from('integrations').select('id, tenant_id, config, status').eq('tenant_id', tenantId).eq('provider', 'hellorix').eq('is_enabled', true).order('updated_at', { ascending: false }).limit(1).maybeSingle()
  return (data as Conn | null) ?? null
}
const keyOf = (c: Conn | null) => {
  const k = String(c?.config?.api_key ?? '').trim()
  if (!k) throw new Error('AI Calling is not connected: add the HelloRix API key in System Connections → AI Calling.')
  return k
}

// ---------- the template (objective) ----------
const OPENING_MARK = 'CALL OPENING (always follow, in this order):'
const OPENING_BLOCK = `${OPENING_MARK}
1. Never say "Hello" or "Hi". Start with "Namaste {customer_name} ji", then say your name and the company name.
2. Say that they had sent an enquiry (request) to the company, and that is why you are calling.
3. Ask: "Kya aapke paas 2 minute hain baat karne ke liye?" (in English: "Do you have 2 minutes to talk?").
4. If they are busy or say no: ask what time is good to call back, record it in callback_time, thank them and end the call politely.
5. If they say yes: continue with the rest of the call below.`
const LANG_MARK = 'LANGUAGE CHECK:'
const LANG_BLOCK = `${LANG_MARK} right after the opening (once they agree to talk), ask: "Would you be more comfortable talking in Hindi or in English?" Continue the rest of the call only in the language they choose. If the answer is not clear, continue in the language they replied in. Record every collected answer in English, using Latin letters, even when the conversation is in Hindi.`
const RAW_ASK = 'Follow the call instructions given above and achieve the goal described there.'
const on = (v: unknown, dflt = true) => (v === undefined || v === null || v === '' ? dflt : v === true || v === 'true' || v === '1')

function stripAuto(text: string) {
  let t = text
  const o = t.indexOf(OPENING_MARK)
  if (o >= 0) {
    const endMark = 'continue with the rest of the call below.'
    const e = t.indexOf(endMark, o)
    t = t.slice(0, o) + (e >= 0 ? t.slice(e + endMark.length) : '')
  }
  const l = t.indexOf(LANG_MARK)
  if (l >= 0) t = t.slice(0, l)
  return t.trim()
}

type Field = { field: string; type?: string; required?: boolean; how_to_ask?: string; options?: string | string[] }
function cleanTemplate(input: Record<string, unknown>) {
  const o: Record<string, unknown> = {}
  for (const k of ['name', 'kind', 'purpose', 'ask', 'scenario', 'if_they_push_back', 'closing', 'give_up', 'voice_id', 'persona_id']) {
    const v = typeof input[k] === 'string' ? (input[k] as string).trim() : input[k]
    if (v !== undefined && v !== null && v !== '') o[k] = v
  }
  let collect = ((input.collect ?? []) as Field[])
    .filter((c) => String(c.field ?? '').trim())
    .slice(0, 20)
    .map((c) => ({
      field: String(c.field).trim().toLowerCase().replace(/[^a-z0-9_]/g, '_'),
      type: ['text', 'number', 'date', 'choice', 'yes_no', 'phone', 'email'].includes(String(c.type)) ? String(c.type) : 'text',
      required: !!c.required,
      ...(c.how_to_ask ? { how_to_ask: String(c.how_to_ask) } : {}),
      ...(c.type === 'choice' ? { options: (Array.isArray(c.options) ? c.options : String(c.options ?? '').split(',')).map((s) => String(s).trim()).filter(Boolean) } : {}),
    }))
  if (o.scenario) {
    delete o.purpose
    if (!o.ask) o.ask = RAW_ASK
  }
  const k = o.scenario ? 'scenario' : 'purpose'
  // the fixed opening and the language question: chosen on each template
  if (on(input.fixed_opening)) {
    if (o[k] && !String(o[k]).includes(OPENING_MARK)) o[k] = `${OPENING_BLOCK}\n\n${o[k]}`
    if (!collect.some((x) => x.field === 'callback_time')) collect.push({ field: 'callback_time', type: 'text', required: false, how_to_ask: 'If they are busy, ask when to call back' })
  }
  if (on(input.lang_step)) {
    if (o[k] && !String(o[k]).includes(LANG_MARK)) o[k] = `${o[k]}\n\n${LANG_BLOCK}`
    if (!collect.some((x) => x.field === 'preferred_language'))
      collect = [{ field: 'preferred_language', type: 'choice', required: true, options: ['Hindi', 'English'], how_to_ask: 'Ask whether they are more comfortable in Hindi or English' }, ...collect]
  }
  if (collect.length) o.collect = collect.slice(0, 20)
  if (!o.name) throw new Error('Give the template a name.')
  if (!o.purpose && !o.scenario) throw new Error('Write the opening & purpose, or the full call prompt.')
  if (!o.ask) throw new Error('Write what to ask.')
  return o
}
function forEditor(o: Record<string, unknown>) {
  const a = { ...o }
  // which auto blocks the template has (shown as its two ticks), then hidden from the text
  const text = ['purpose', 'scenario', 'prompt'].map((k) => (typeof a[k] === 'string' ? (a[k] as string) : '')).join('\n')
  const fixed = text.includes(OPENING_MARK)
  const lang = text.includes(LANG_MARK)
  for (const k of ['purpose', 'scenario', 'prompt']) if (typeof a[k] === 'string') a[k] = stripAuto(a[k] as string)
  if (Array.isArray(a.collect)) a.collect = (a.collect as Field[]).filter((x) => !((x.field === 'callback_time' && fixed) || (x.field === 'preferred_language' && lang)))
  return { ...a, raw: a.ask === RAW_ASK || a.prompt_mode === 'raw', fixed_opening: fixed, lang_step: lang }
}

// ---------- calls ----------
const digits10 = (p: string) => {
  const d = String(p ?? '').replace(/\D/g, '').replace(/^91(?=\d{10}$)/, '').replace(/^0(?=\d{10}$)/, '')
  return /^[6-9]\d{9}$/.test(d) ? d : ''
}
/** calling hours (India time): "10:00"–"19:00" on the ticked days (0 = Sunday) */
function inHours(cfg: Cfg) {
  const now = new Date(Date.now() + 330 * 60_000)
  const hm = `${String(now.getUTCHours()).padStart(2, '0')}:${String(now.getUTCMinutes()).padStart(2, '0')}`
  const start = cfg.hours_start || '10:00'
  const end = cfg.hours_end || '19:00'
  const days = String(cfg.hours_days ?? '0,1,2,3,4,5,6').split(',').filter(Boolean).map(Number)
  if (!days.includes(now.getUTCDay())) return `Calls are only placed on the calling days set in System Connections → AI Calling.`
  if (hm < start || hm >= end) return `Calls are only placed between ${start} and ${end} (India time): System Connections → AI Calling → Calling hours.`
  return null
}

async function placeCall(
  db: SupabaseClient,
  conn: Conn,
  p: { to: string; name?: string | null; lead_id?: string | null; objective_id?: string | null; member_id?: string | null; via: 'manual' | 'lead' | 'workflow'; run_id?: string | null; variables?: Record<string, string> },
) {
  const cfg = conn.config ?? {}
  const key = keyOf(conn)
  const d = digits10(p.to)
  if (!d) throw new Error('Only Indian mobile numbers (10 digits) can be called.')
  const off = inHours(cfg)
  if (off) throw new Error(off)
  const objective = String(p.objective_id || '').trim()
  if (!objective) throw new Error('Pick the template.')
  let lead: Record<string, string | null> | null = null
  if (p.lead_id) {
    const { data } = await db.from('leads').select('id, first_name, last_name, city, purpose, business_id').eq('id', p.lead_id).maybeSingle()
    lead = data as Record<string, string | null> | null
  }
  const name = String(p.name ?? [lead?.first_name, lead?.last_name].filter(Boolean).join(' ') ?? '').trim()
  const first = name.split(/\s+/)[0] || 'ji'
  const requestId = `bz-${conn.tenant_id.slice(0, 8)}-${d}-${Math.floor(Date.now() / 60000)}`
  const body = {
    to: '+91' + d,
    objective_id: objective,
    ...(name ? { name } : {}),
    variables: { customer_name: first, city: lead?.city ?? '', ...(p.variables ?? {}) },
    post_call_insights: cfg.insights === 'outcome' ? 'outcome' : 'full',
    ...(cfg.from_number ? { from_number: cfg.from_number } : {}),
    webhook_url: `${Deno.env.get('SUPABASE_URL')}/functions/v1/hellorix?i=${conn.id}`,
    ...(cfg.webhook_secret ? { webhook_secret: cfg.webhook_secret } : {}),
    request_id: requestId,
  }
  // the template's name, for the lists
  let objectiveName: string | null = null
  try {
    const o = await hx(key, 'GET', `/voice/objectives/${encodeURIComponent(objective)}`)
    if (o.status < 300) objectiveName = String(o.d.name ?? '') || null
  } catch {
    /* name only */
  }
  const base = {
    tenant_id: conn.tenant_id,
    integration_id: conn.id,
    lead_id: p.lead_id ?? null,
    business_id: lead?.business_id ?? null,
    member_id: p.member_id ?? null,
    workflow_run_id: p.run_id ?? null,
    via: p.via,
    to_phone: '+91' + d,
    to_name: name || null,
    objective_id: objective,
    objective_name: objectiveName,
  }
  const r = await hx(key, 'POST', '/voice/calls', body, { 'Idempotency-Key': requestId })
  if (r.status >= 300 || r.d.error) {
    const msg = friendly(r.d, r.status)
    await db.from('ai_calls').insert({ ...base, status: 'failed', final: true, outcome: 'failed', error: msg, raw: r.d })
    throw new Error(msg)
  }
  const { data: row, error } = await db
    .from('ai_calls')
    .insert({ ...base, hx_call_id: (r.d.id as string) || null, hx_queue_id: (r.d.queue_id as string) || null, status: String(r.d.status ?? 'queued'), placed_at: (r.d.placed_at as string) || new Date().toISOString(), raw: r.d })
    .select('*')
    .single()
  if (error) throw new Error(error.message)
  return row as Record<string, unknown>
}

/** HelloRix's call object → our row; the first time it is final: the lead's category and a note (lead / workflow calls) */
async function applyCall(db: SupabaseClient, row: Record<string, unknown>, c: Record<string, unknown>) {
  const status = String(c.status ?? row.status)
  const final = c.final === true || FINAL.includes(status)
  const cost = c.cost as { amount?: number; final?: boolean } | undefined
  const collectedRaw = c.collected
  const collected = Array.isArray(collectedRaw)
    ? Object.fromEntries((collectedRaw as { field?: string; value?: unknown }[]).map((x, i) => [x?.field ?? String(i), x?.value ?? x]))
    : (collectedRaw as Record<string, unknown>) ?? {}
  const patch = {
    hx_call_id: (c.id as string) || row.hx_call_id,
    status,
    final,
    outcome: (c.outcome as string) ?? row.outcome ?? null,
    summary: (c.summary as string) ?? row.summary ?? null,
    collected,
    recording_url: (c.recording_url as string) ?? row.recording_url ?? null,
    duration_seconds: (c.duration_seconds as number) ?? null,
    talk_seconds: (c.talk_seconds as number) ?? null,
    cost: cost?.amount ?? row.cost ?? null,
    cost_final: cost?.final !== false && cost?.amount !== undefined,
    hangup_party: (c.hangup_party as string) ?? null,
    answered_at: (c.answered_at as string) ?? null,
    ended_at: (c.ended_at as string) ?? null,
    raw: c,
    updated_at: new Date().toISOString(),
  }
  const { data: saved } = await db.from('ai_calls').update(patch).eq('id', row.id).select('*').single()
  const r = (saved ?? { ...row, ...patch }) as Record<string, unknown>
  if (final && r.lead_id && !r.lead_updated && (r.via === 'lead' || r.via === 'workflow')) {
    const out = String(r.outcome ?? '').toLowerCase()
    const temp = out === 'interested' ? 'hot' : out === 'callback' || out === 'deferred' ? 'warm' : out === 'declined' ? 'cold' : null
    if (temp) await db.from('leads').update({ temperature: temp }).eq('id', r.lead_id)
    const answers = Object.entries((r.collected ?? {}) as Record<string, unknown>)
      .filter(([, v]) => v !== null && v !== '')
      .map(([k, v]) => `${k.replace(/_/g, ' ')}: ${typeof v === 'object' ? JSON.stringify(v) : v}`)
    const note = [`AI call${r.objective_name ? ` (${r.objective_name})` : ''}: ${OUT_LABEL[out] ?? status}`, r.summary ? String(r.summary) : '', answers.join(' · ')].filter(Boolean).join('\n')
    await db.from('lead_activities').insert({ tenant_id: r.tenant_id, lead_id: r.lead_id, kind: 'note', note, member_id: r.member_id ?? null })
    await db.from('ai_calls').update({ lead_updated: true }).eq('id', r.id)
  }
  return r
}
const OUT_LABEL: Record<string, string> = { interested: 'Interested', callback: 'Call back', deferred: 'Later', declined: 'Not interested', no_answer: 'Not answered', busy: 'Busy', failed: 'Failed' }

/** a call that isn't final yet: read it from HelloRix (a "pre-…" id: found by number + template + time) */
async function syncOne(db: SupabaseClient, key: string, row: Record<string, unknown>) {
  const id = String(row.hx_call_id ?? '')
  if (id && !id.startsWith('pre-')) {
    const r = await hx(key, 'GET', `/voice/calls/${encodeURIComponent(id)}`)
    if (r.status < 300) return applyCall(db, row, r.d)
  }
  const since = new Date(Date.parse(String(row.placed_at)) - 120_000).toISOString()
  const q = new URLSearchParams({ to: String(row.to_phone), since, limit: '20' })
  if (row.objective_id) q.set('objective_id', String(row.objective_id))
  const r = await hx(key, 'GET', `/voice/calls?${q}`)
  if (r.status >= 300) return row
  const { data: taken } = await db.from('ai_calls').select('hx_call_id').eq('tenant_id', row.tenant_id).neq('id', row.id).not('hx_call_id', 'is', null)
  const used = new Set((taken ?? []).map((x: { hx_call_id: string }) => x.hx_call_id))
  const mine = listOf(r.d, 'calls')
    .filter((c) => c.id === id || !used.has(String(c.id)))
    .sort((a, b) => Date.parse(String(a.placed_at)) - Date.parse(String(b.placed_at)))[0]
  if (mine) return applyCall(db, row, mine)
  if (Date.now() - Date.parse(String(row.placed_at)) > 6 * 3600_000) {
    await db.from('ai_calls').update({ final: true, status: 'expired', updated_at: new Date().toISOString() }).eq('id', row.id)
  }
  return row
}
async function syncTenant(db: SupabaseClient, tenantId: string) {
  const conn = await connOf(db, tenantId)
  if (!conn?.config?.api_key) return 0
  const { data: rows } = await db.from('ai_calls').select('*').eq('tenant_id', tenantId).eq('final', false).gte('placed_at', new Date(Date.now() - 2 * 86400_000).toISOString()).order('placed_at').limit(40)
  let n = 0
  for (const row of rows ?? []) {
    try {
      await syncOne(db, String(conn.config.api_key), row)
      n++
    } catch {
      /* next time */
    }
  }
  return n
}

// ---------- the webhook ----------
async function hmacHex(secret: string, msg: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg))
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
async function webhook(req: Request, integrationId: string) {
  const db = admin()
  const raw = await req.text()
  const { data: conn } = await db.from('integrations').select('id, tenant_id, config, status').eq('id', integrationId).eq('provider', 'hellorix').maybeSingle()
  if (!conn) return fail('Unknown connection', 404)
  const secret = String((conn.config as Cfg)?.webhook_secret ?? '')
  if (secret) {
    const sig = req.headers.get('x-hellorix-signature') ?? ''
    const t = /t=(\d+)/.exec(sig)?.[1]
    const v1 = /v1=([0-9a-f]+)/.exec(sig)?.[1]
    if (!t || !v1 || Math.abs(Date.now() / 1000 - Number(t)) > 300 || (await hmacHex(secret, `${t}.${raw}`)) !== v1) return fail('Bad signature', 401)
  }
  let body: Record<string, unknown>
  try {
    body = JSON.parse(raw)
  } catch {
    return fail('Bad body')
  }
  const c = (body.data ?? body) as Record<string, unknown>
  const id = String(c.id ?? '')
  let { data: row } = await db.from('ai_calls').select('*').eq('tenant_id', conn.tenant_id).eq('hx_call_id', id).maybeSingle()
  if (!row && c.to) {
    // placed with a "pre-…" id: the open call to that number with that template, placed last
    const { data: cands } = await db
      .from('ai_calls')
      .select('*')
      .eq('tenant_id', conn.tenant_id)
      .eq('to_phone', String(c.to))
      .eq('final', false)
      .order('placed_at', { ascending: false })
      .limit(5)
    row = (cands ?? []).find((x: Record<string, unknown>) => !c.objective_id || x.objective_id === c.objective_id) ?? null
  }
  if (row) await applyCall(db, row, c)
  return json({ ok: true })
}

// ---------- Write with AI (Gemini) ----------
async function draft(db: SupabaseClient, tenantId: string, b: Record<string, unknown>) {
  const { data: g } = await db.from('integrations').select('config').eq('tenant_id', tenantId).eq('provider', 'gemini').eq('is_enabled', true).limit(1).maybeSingle()
  const gk = String((g?.config as Cfg | undefined)?.api_key ?? '')
  const model = String((g?.config as Cfg | undefined)?.model ?? 'gemini-flash-latest')
  if (!gk) throw new Error('Connect Gemini AI in System Connections to write templates with AI.')
  const lang = b.language === 'Hinglish' ? 'Hinglish (Hindi words in English/Latin letters, never Devanagari)' : 'simple English'
  const goal = String(b.goal ?? '').trim().slice(0, 1000)
  const biz = String(b.business ?? '').trim().slice(0, 200) || 'our business'
  const prompt = `Write a phone-call script for an AI voice agent calling a person who enquired with "${biz}" (an Indian business).
Write every text field in ${lang}. Never use Devanagari. Never use emojis. Never invent prices, discounts or promises.
Reply only with JSON: {"name","purpose","ask","collect":[{"field","type","required","options","how_to_ask"}],"if_they_push_back","closing","give_up"}.
- name: short English name, e.g. "${biz} lead qualifier".
- purpose: who the agent is, which company, and why they are calling. 3-5 sentences. Do NOT write the greeting or "do you have 2 minutes": a fixed opening is added automatically. Never use the word "Hello".
- ask: what to find out.
- collect: 4-7 fields in snake_case English; type one of text, number, choice, yes_no, date; options (comma separated) only for choice. Do not add language or callback_time fields.
- if_they_push_back: how to handle price / "send details" / "busy". Never quote a price; say the team will share exact details.
- closing and give_up: short.
${goal ? `The goal of the call: ${goal}` : ''}`
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': gk },
    body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: { temperature: 0.5, responseMimeType: 'application/json' } }),
  })
  const d = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(d?.error?.message ?? `Gemini error ${r.status}`)
  const text = d?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text ?? '').join('') ?? ''
  const u = d?.usageMetadata ?? {}
  await db.from('ai_usage').insert({ tenant_id: tenantId, model, feature: 'ai_call_template', input_tokens: u.promptTokenCount ?? 0, output_tokens: u.candidatesTokenCount ?? 0 })
  try {
    return JSON.parse(text.replace(/^```(json)?|```$/g, '').trim())
  } catch {
    throw new Error('Gemini’s reply could not be read. Try again.')
  }
}

// ---------- requests ----------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  const url = new URL(req.url)
  const hook = url.searchParams.get('i')
  if (hook && req.headers.get('x-hellorix-event')) return webhook(req, hook)
  if (hook) return json({ ok: true }) // a test ping

  const db = admin()
  const cron = req.headers.get('x-cron-secret')
  if (cron) {
    const { data: secret } = await db.rpc('workflow_cron_secret')
    if (!secret || cron !== secret) return fail('Not allowed', 401)
    const b = (await req.json().catch(() => ({}))) as Record<string, unknown>
    if (b.action === 'run_call') {
      try {
        const conn = await connOf(db, String(b.tenant_id))
        if (!conn) throw new Error('AI Calling is not connected (System Connections → AI Calling).')
        const row = await placeCall(db, conn, {
          to: String(b.to ?? ''),
          name: (b.name as string) ?? null,
          lead_id: (b.lead_id as string) ?? null,
          objective_id: (b.objective_id as string) ?? null,
          via: 'workflow',
          run_id: (b.run_id as string) ?? null,
          variables: (b.variables as Record<string, string>) ?? {},
        })
        return json({ ok: true, id: row.id, status: row.status })
      } catch (e) {
        return fail((e as Error).message)
      }
    }
    // every workspace with an unfinished call
    const { data: open } = await db.from('ai_calls').select('tenant_id').eq('final', false).gte('placed_at', new Date(Date.now() - 2 * 86400_000).toISOString())
    let n = 0
    for (const t of [...new Set((open ?? []).map((x: { tenant_id: string }) => x.tenant_id))]) n += await syncTenant(db, t)
    return json({ ok: true, synced: n })
  }

  // from the app
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)
  const b = (await req.json().catch(() => ({}))) as Record<string, unknown>
  const tenantId = String(b.tenant_id ?? '')
  const can = async (module: string, action: string) => {
    const { data } = await asCaller.rpc('ai_calling_can', { p_tenant: tenantId, p_action: module === 'ai_calling' ? action : 'member' })
    return data === true
  }
  const member = async () => {
    const { data } = await db.from('tenant_members').select('id').eq('tenant_id', tenantId).eq('user_id', me.user!.id).eq('status', 'active').maybeSingle()
    return (data?.id as string | undefined) ?? null
  }

  try {
    // ----- the connection (System Connections people: they can read its keys) -----
    if (b.action === 'options' || b.action === 'test') {
      let key = String(b.api_key ?? '').trim()
      let row: { id: string; config: Cfg } | null = null
      if (b.id) {
        const { data } = await asCaller.from('integrations').select('id, config').eq('id', String(b.id)).eq('provider', 'hellorix').maybeSingle()
        row = data as { id: string; config: Cfg } | null
        if (!row) return fail('Connection not found.', 404)
        if (!key) key = String(row.config?.api_key ?? '').trim()
      }
      if (!key) return fail('Enter the API key.')
      const who = await hx(key, 'GET', '/voice')
      if (who.status >= 300) throw new Error(friendly(who.d, who.status))
      const [nums, voices, personas, objs] = await Promise.all([hx(key, 'GET', '/voice/numbers'), hx(key, 'GET', '/voice/voices'), hx(key, 'GET', '/voice/personas'), hx(key, 'GET', '/voice/objectives')])
      const options = {
        account: who.d,
        numbers: listOf(nums.d, 'numbers').map((n) => ({ id: String(n.number ?? n.phone ?? n.id ?? ''), label: String(n.label ?? n.name ?? n.number ?? n.phone ?? n.id ?? '') })),
        voices: listOf(voices.d, 'voices').map((v) => ({ id: String(v.id), label: `${v.name ?? v.id}${v.language ? ` (${v.language})` : ''}` })),
        personas: listOf(personas.d, 'personas').map((p) => ({ id: String(p.id), label: `${p.name ?? p.id}${p.tone ? ` · ${p.tone}` : ''}` })),
        templates: listOf(objs.d, 'objectives').map((o) => ({ id: String(o.id), label: String(o.name ?? o.id) })),
      }
      if (b.action === 'test' && row) {
        const cfg = { ...row.config, options: JSON.stringify(options), checked_at: new Date().toISOString(), webhook_secret: row.config.webhook_secret || crypto.randomUUID().replace(/-/g, '') }
        await db.from('integrations').update({ status: 'connected', last_error: null, config: cfg }).eq('id', row.id)
      }
      return json({ ok: true, ...options })
    }

    // ----- everything else: the workspace's connection -----
    const conn = await connOf(db, tenantId)
    if (!(await asCaller.rpc('ai_calling_can', { p_tenant: tenantId, p_action: 'member' })).data) return fail('Not allowed', 403)
    const key = () => keyOf(conn)

    if (b.action === 'templates') {
      const r = await hx(key(), 'GET', '/voice/objectives')
      if (r.status >= 300) throw new Error(friendly(r.d, r.status))
      const list = listOf(r.d, 'objectives')
        .filter((o) => o.status !== 'archived')
        .map((o) => ({ id: o.id, name: o.name, kind: o.kind, version: o.version, status: o.status, purpose: typeof o.purpose === 'string' ? stripAuto(o.purpose) : o.purpose, prompt_mode: o.prompt_mode, collect: o.collect }))
      let opts: Record<string, unknown> = {}
      try {
        opts = JSON.parse(String(conn?.config?.options ?? '{}'))
      } catch {
        opts = {}
      }
      return json({ ok: true, templates: list, voices: opts.voices ?? [], personas: opts.personas ?? [] })
    }
    if (b.action === 'template') {
      const r = await hx(key(), 'GET', `/voice/objectives/${encodeURIComponent(String(b.objective_id))}`)
      if (r.status >= 300) throw new Error(friendly(r.d, r.status))
      return json({ ok: true, template: forEditor(r.d) })
    }
    if (b.action === 'template_save' || b.action === 'template_delete') {
      if (!(await can('ai_calling', 'templates'))) return fail('You can’t manage AI calling templates.', 403)
      if (b.action === 'template_delete') {
        const r = await hx(key(), 'DELETE', `/voice/objectives/${encodeURIComponent(String(b.objective_id))}`)
        if (r.status >= 300 && r.status !== 404) throw new Error(friendly(r.d, r.status))
        return json({ ok: true })
      }
      const body = cleanTemplate((b.form ?? {}) as Record<string, unknown>)
      const r = b.objective_id
        ? await hx(key(), 'PUT', `/voice/objectives/${encodeURIComponent(String(b.objective_id))}`, body)
        : await hx(key(), 'POST', '/voice/objectives', body)
      if (r.status >= 300) throw new Error(friendly(r.d, r.status))
      return json({ ok: true, template: r.d })
    }
    if (b.action === 'draft') {
      if (!(await can('ai_calling', 'templates'))) return fail('You can’t manage AI calling templates.', 403)
      return json({ ok: true, draft: await draft(db, tenantId, b) })
    }
    if (b.action === 'call') {
      if (!(await can('ai_calling', 'view'))) return fail('You can’t place AI calls.', 403)
      if (!conn) throw new Error('AI Calling is not connected (System Connections → AI Calling).')
      if (b.lead_id) {
        const { data: l } = await asCaller.from('leads').select('id').eq('id', String(b.lead_id)).maybeSingle()
        if (!l) return fail('You can’t open this lead.', 403)
      }
      const row = await placeCall(db, conn, {
        to: String(b.to ?? ''),
        name: (b.name as string) ?? null,
        lead_id: (b.lead_id as string) ?? null,
        objective_id: (b.objective_id as string) ?? null,
        member_id: await member(),
        via: b.lead_id ? 'lead' : 'manual',
      })
      return json({ ok: true, call: row })
    }
    if (b.action === 'detail') {
      // only a call this person can see
      const { data: row } = await asCaller.from('ai_calls').select('*').eq('id', String(b.id)).maybeSingle()
      if (!row) return fail('Call not found.', 404)
      let fresh = row as Record<string, unknown>
      let turns: unknown[] = []
      const id = String(row.hx_call_id ?? '')
      if (conn?.config?.api_key) {
        try {
          if (!row.final || !row.cost_final) fresh = await syncOne(db, key(), row)
          const hid = String(fresh.hx_call_id ?? id)
          if (hid && !hid.startsWith('pre-')) {
            const t = await hx(key(), 'GET', `/voice/calls/${encodeURIComponent(hid)}/transcript`)
            if (t.status < 300) turns = (t.d.turns as unknown[]) ?? []
          }
        } catch {
          /* show what we have */
        }
      }
      return json({ ok: true, call: { ...fresh, raw: undefined }, transcript: turns })
    }
    if (b.action === 'sync') return json({ ok: true, synced: await syncTenant(db, tenantId) })
    return fail('Unknown action')
  } catch (e) {
    return fail((e as Error).message)
  }
})
