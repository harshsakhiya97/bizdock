// The AI order (System Connections → AI order, table ai_routes): per AI feature, Level 1 is tried first and the next
// level when it fails (busy / server error or timeout / unreadable answer / not connected — the failures ticked for
// that feature). Gemini busy (429 / 503) is tried once more after 2.5 s first. One monthly ₹ limit for every AI
// (System Connections → Gemini AI → Monthly AI limit): Gemini at its prices, Claude at its own (or Anthropic's list price).
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

export type Feature = 'lead_insight' | 'insights' | 'ai_call_template'
export type Provider = 'gemini' | 'claude'
export type FailKind = 'busy' | 'error' | 'bad_answer' | 'not_connected'
export type Level = { provider: Provider; id: string; key: string; model: string; name: string }
export type Route = { enabled: boolean; levels: Level[]; failOn: Set<string>; prompt: string | null; limitHit: string | null }
export type Out = { text: string; json?: Record<string, unknown>; provider: Provider; model: string; integrationId: string; inTok: number; outTok: number }

export class AiFail extends Error {
  constructor(public kind: FailKind, msg: string) {
    super(msg)
  }
}
/** every level was busy: try again later (no try counted) */
export class AiBusy extends Error {}

const ALL_FAIL: FailKind[] = ['busy', 'error', 'bad_answer', 'not_connected']
const DEFAULT_LEVELS = [{ provider: 'gemini', model: '' }, { provider: 'claude', model: '' }]
const NAME: Record<Provider, string> = { gemini: 'Gemini', claude: 'Claude' }
const USD = 88
function claudePrice(cfg: Record<string, string>, model: string) {
  const fam = /opus/i.test(model) ? [15, 75] : /sonnet/i.test(model) ? [3, 15] : [1, 5]
  return { pin: Number(cfg.price_in || fam[0] * USD), pout: Number(cfg.price_out || fam[1] * USD) }
}

/** the feature's AI order, its connections and this month's limit */
export async function aiRoute(admin: SupabaseClient, tenantId: string, feature: Feature): Promise<Route> {
  const [{ data: route }, { data: conns }] = await Promise.all([
    admin.from('ai_routes').select('enabled, levels, fail_on, prompt').eq('tenant_id', tenantId).eq('feature', feature).maybeSingle(),
    admin.from('integrations').select('id, provider, config, updated_at').eq('tenant_id', tenantId).in('provider', ['gemini', 'claude']).eq('is_enabled', true).order('updated_at', { ascending: false }),
  ])
  const conn = (p: string) => ((conns ?? []) as { id: string; provider: string; config: Record<string, string> }[]).find((c) => c.provider === p)
  const g = conn('gemini')
  const c = conn('claude')
  const want = ((route?.levels as { provider: string; model?: string }[] | undefined) ?? DEFAULT_LEVELS).filter((l) => l.provider === 'gemini' || l.provider === 'claude')
  const levels: Level[] = want.map((l) => {
    const row = l.provider === 'gemini' ? g : c
    const cfg = (row?.config ?? {}) as Record<string, string>
    return {
      provider: l.provider as Provider,
      id: row ? String(row.id) : '',
      key: String(cfg.api_key ?? '').trim(),
      model: String(l.model || cfg.model || (l.provider === 'gemini' ? 'gemini-flash-latest' : 'claude-haiku-4-5')),
      name: NAME[l.provider as Provider],
    }
  })
  let limitHit: string | null = null
  const gc = (g?.config ?? {}) as Record<string, string>
  const limit = Number(gc.monthly_limit || 0)
  if (limit > 0) {
    const ist = new Date(Date.now() + 330 * 60_000)
    const start = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), 1) - 330 * 60_000).toISOString()
    const { data } = await admin.from('ai_usage').select('model, input_tokens, output_tokens').eq('tenant_id', tenantId).gte('created_at', start).limit(200000)
    const cc = (c?.config ?? {}) as Record<string, string>
    const spent =
      ((data ?? []) as { model: string; input_tokens: number; output_tokens: number }[]).reduce((t, r) => {
        if (/^claude/i.test(r.model ?? '')) {
          const p = claudePrice(cc, r.model)
          return t + Number(r.input_tokens) * p.pin + Number(r.output_tokens) * p.pout
        }
        return t + Number(r.input_tokens) * Number(gc.price_in || 0) + Number(r.output_tokens) * Number(gc.price_out || 0)
      }, 0) / 1e6
    if (spent >= limit) limitHit = `This month’s AI limit (₹${limit.toLocaleString('en-IN')}) is used up (≈ ₹${spent.toFixed(2)}). Raise it in System Connections → Gemini AI, or wait till next month.`
  }
  return {
    enabled: route ? !!route.enabled : true,
    levels,
    failOn: new Set((route?.fail_on as string[] | undefined) ?? ALL_FAIL),
    prompt: String(route?.prompt ?? '').trim() || null,
    limitHit,
  }
}

export type Ask = {
  system: string
  messages: { role: 'user' | 'model'; text: string }[]
  /** Gemini's response schema: the answer must be JSON */
  schema?: Record<string, unknown>
  /** for Claude (no schema): the JSON it must reply with */
  jsonShape?: string
  maxTokens?: number
  temperature?: number
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const parseJson = (s: string) => {
  const a = s.indexOf('{')
  const b = s.lastIndexOf('}')
  const v = JSON.parse(a >= 0 && b > a ? s.slice(a, b + 1) : s)
  if (!v || typeof v !== 'object') throw new Error('not an object')
  return v as Record<string, unknown>
}

async function gemini(l: Level, q: Ask): Promise<Out> {
  for (let attempt = 0; ; attempt++) {
    let r: Response
    try {
      r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(l.model)}:generateContent`, {
        method: 'POST',
        headers: { 'x-goog-api-key': l.key, 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(50_000),
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: q.system }] },
          contents: q.messages.map((m) => ({ role: m.role, parts: [{ text: m.text }] })),
          generationConfig: {
            temperature: q.temperature ?? 0.3,
            maxOutputTokens: q.maxTokens ?? 8192,
            ...(q.schema || q.jsonShape ? { responseMimeType: 'application/json' } : {}),
            ...(q.schema ? { responseSchema: q.schema } : {}),
          },
        }),
      })
    } catch (e) {
      throw new AiFail('error', `Gemini didn’t answer (${(e as Error).name === 'TimeoutError' ? 'timeout' : (e as Error).message})`)
    }
    const d = await r.json().catch(() => ({}))
    const msg = String(d?.error?.message ?? '')
    const busy = r.status === 429 || r.status === 503 || /overloaded|high demand|try again later/i.test(msg)
    if (busy && attempt === 0) {
      await sleep(2500)
      continue
    }
    if (busy) throw new AiFail('busy', msg ? `Gemini: ${msg}` : 'Gemini is busy.')
    if (!r.ok) throw new AiFail('error', msg ? `Gemini: ${msg}` : `Gemini error ${r.status}`)
    const text = ((d?.candidates?.[0]?.content?.parts ?? []) as { text?: string; thought?: boolean }[]).filter((p) => !p.thought).map((p) => p.text ?? '').join('').trim()
    const why = d?.candidates?.[0]?.finishReason ?? 'empty'
    if (!text) throw new AiFail('bad_answer', `Gemini gave no answer (${why}).`)
    let json: Record<string, unknown> | undefined
    if (q.schema || q.jsonShape) {
      try {
        json = parseJson(text)
      } catch {
        throw new AiFail('bad_answer', `Gemini gave no usable answer (${why}).`)
      }
    }
    const u = d?.usageMetadata ?? {}
    return { text, json, provider: 'gemini', model: l.model, integrationId: l.id, inTok: Number(u.promptTokenCount ?? 0), outTok: Number(u.candidatesTokenCount ?? 0) + Number(u.thoughtsTokenCount ?? 0) }
  }
}

async function claude(l: Level, q: Ask): Promise<Out> {
  const json = !!(q.schema || q.jsonShape)
  const system = json ? `${q.system}\n\nReply with one JSON object only (no text before or after it, no code fences)${q.jsonShape ? `, exactly these keys:\n${q.jsonShape}` : '.'}` : q.system
  let r: Response
  try {
    r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': l.key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      signal: AbortSignal.timeout(60_000),
      body: JSON.stringify({
        model: l.model,
        max_tokens: Math.min(q.maxTokens ?? 4096, 8192),
        // no temperature: newer Claude models refuse it
        system,
        messages: q.messages.map((m) => ({ role: m.role === 'model' ? 'assistant' : 'user', content: m.text })),
      }),
    })
  } catch (e) {
    throw new AiFail('error', `Claude didn’t answer (${(e as Error).name === 'TimeoutError' ? 'timeout' : (e as Error).message})`)
  }
  const d = await r.json().catch(() => ({}))
  const msg = String(d?.error?.message ?? '')
  if (r.status === 429 || r.status === 529) throw new AiFail('busy', msg ? `Claude: ${msg}` : 'Claude is busy.')
  if (!r.ok) throw new AiFail('error', msg ? `Claude: ${msg}` : `Claude error ${r.status}`)
  const text = ((d?.content ?? []) as { type: string; text?: string }[]).filter((x) => x.type === 'text').map((x) => x.text ?? '').join('').trim()
  if (!text) throw new AiFail('bad_answer', 'Claude gave no answer.')
  let out: Record<string, unknown> | undefined
  if (json) {
    try {
      out = parseJson(text)
    } catch {
      throw new AiFail('bad_answer', 'Claude gave no usable answer.')
    }
  }
  return { text, json: out, provider: 'claude', model: l.model, integrationId: l.id, inTok: Number(d?.usage?.input_tokens ?? 0), outTok: Number(d?.usage?.output_tokens ?? 0) }
}

/** Level 1, then the next level when it fails in a way the feature moves on for */
export async function aiAsk(route: Route, q: Ask, check?: (o: Out) => void): Promise<Out> {
  if (!route.levels.length) throw new AiFail('not_connected', 'No AI is set for this in System Connections → AI order.')
  let last: AiFail | null = null
  for (let i = 0; i < route.levels.length; i++) {
    const l = route.levels[i]
    try {
      if (!l.key) throw new AiFail('not_connected', `${l.name} is not connected.`)
      const o = l.provider === 'gemini' ? await gemini(l, q) : await claude(l, q)
      if (check) {
        try {
          check(o)
        } catch (e) {
          throw new AiFail('bad_answer', `${l.name} gave no usable answer (${(e as Error).message}).`)
        }
      }
      return o
    } catch (e) {
      if (!(e instanceof AiFail)) throw e
      last = e
      const more = i < route.levels.length - 1
      if (!more || !route.failOn.has(e.kind)) break
    }
  }
  if (last?.kind === 'busy') throw new AiBusy(last.message)
  throw last ?? new Error('No AI answered.')
}

/** counted in ai_usage (System Connections cards, the monthly limit) */
export async function logUsage(admin: SupabaseClient, tenantId: string, o: Out, feature: string, memberId: string | null = null) {
  await admin.from('ai_usage').insert({
    tenant_id: tenantId,
    integration_id: o.integrationId || null,
    model: o.model,
    feature,
    input_tokens: o.inTok,
    output_tokens: o.outTok,
    member_id: memberId,
  })
}
