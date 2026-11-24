// gemini: a workspace's Gemini AI connection (System Connections → Gemini AI: API key + model).
//
//   POST { action: 'models', api_key? | id? }  from the app (the Keys form): the models a key can use, for the dropdown
//                                 (the typed key, else the saved one of that connection)
//   POST { action: 'test', id }   from the app (on save): check the key with Google, list the models it can use (saved on
//                                 the connection for the Model dropdown) and pick a default model if none is set
//
//   POST { action: 'insights_status', tenant_id }  AI Insights: may this person use it, and is Gemini connected
//   POST { action: 'insights', tenant_id, page, context, messages }  AI Insights (by the AI order: System Connections →
//                                 AI order → AI Insights): answer about the screen (the browser
//                                 sends the page's text and its lists' rows, names already swapped for "Person N" and
//                                 phone numbers / emails removed); stops at the connection's monthly ₹ limit
//
// The key never reaches the browser. Tokens are logged in ai_usage (feature 'insights').
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'
import { AiBusy, aiAsk, aiRoute, logUsage } from '../_shared/ai.ts'

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
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

type Model = { id: string; name: string; input: number | null; output: number | null }

/** the models this key can use to write text (generateContent), newest names first */
async function listModels(key: string): Promise<Model[]> {
  const out: Model[] = []
  let page = ''
  for (let i = 0; i < 10; i++) {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000${page ? `&pageToken=${encodeURIComponent(page)}` : ''}`, { headers: { 'x-goog-api-key': key } })
    const d = await r.json().catch(() => ({}))
    if (!r.ok) {
      const msg = d?.error?.message ?? `Gemini error ${r.status}`
      throw new Error(r.status === 400 || r.status === 403 ? `Google refused the API key: ${msg}` : msg)
    }
    for (const m of (d.models ?? []) as Record<string, unknown>[]) {
      const methods = (m.supportedGenerationMethods ?? []) as string[]
      if (!methods.includes('generateContent')) continue
      const id = String(m.name ?? '').replace(/^models\//, '')
      // skip embeddings / image / audio-only / tuning variants
      if (!id || /embedding|aqa|imagen|veo|tts|audio|live|image-generation|learnlm/i.test(id)) continue
      out.push({ id, name: String(m.displayName ?? id), input: m.inputTokenLimit ? Number(m.inputTokenLimit) : null, output: m.outputTokenLimit ? Number(m.outputTokenLimit) : null })
    }
    page = d.nextPageToken ?? ''
    if (!page) break
  }
  return out.sort((a, b) => b.id.localeCompare(a.id, undefined, { numeric: true }))
}

/** a sensible default: the newest stable Flash, else the newest stable model */
function pickDefault(models: Model[]) {
  const stable = models.filter((m) => !/preview|exp|experimental|latest/i.test(m.id))
  return (stable.find((m) => /flash/i.test(m.id) && !/lite/i.test(m.id)) ?? stable[0] ?? models[0])?.id ?? ''
}


/** this month's estimated ₹ (India time) at the connection's prices */
// deno-lint-ignore no-explicit-any

const INSIGHTS_RULES = `You are "AI Insights" inside BizDock, a CRM used by Indian businesses. The user is looking at one screen of the app; you get the text of that screen and the full rows of every list on it (not only the rows visible on screen).
Rules:
- Use only the data given. If something is not in it, say so plainly; never invent numbers, names or reasons.
- People are shown as "Person 1", "Person 2"…: always write them exactly like that (the app turns them back into names). Phone numbers and emails are hidden on purpose; never ask for them.
- Write in simple English. Be short and useful: bullet points, **bold** the key numbers, ₹ with Indian grouping (₹1,25,000), dates like 20 Nov.
- When you summarise: what this screen shows, the key numbers, what stands out, what needs attention, and 2–3 concrete next steps.
- If the lists were cut to a sample, say your numbers come from the sample unless a total is shown on the screen.`

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)
  const b = (await req.json().catch(() => ({}))) as Record<string, unknown>

  if (b.action === 'models') {
    let key = String(b.api_key ?? '').trim()
    if (!key && b.id) {
      const { data: r } = await ownRow(asCaller, admin, String(b.id), 'gemini', 'config')
      key = String((r?.config as Record<string, string> | undefined)?.api_key ?? '').trim()
    }
    if (!key) return fail('Enter the API key.')
    try {
      const models = await listModels(key)
      return json({ ok: true, models, default: pickDefault(models) })
    } catch (e) {
      return fail((e as Error).message)
    }
  }

  if (b.action === 'test') {
    // only people who can read the keys (System Connections)
    const { data: r } = await ownRow(asCaller, admin, String(b.id ?? ''), 'gemini', 'id, config')
    if (!r) return fail('Connection not found.', 404)
    const cfg = (r.config ?? {}) as Record<string, string>
    try {
      const models = await listModels(String(cfg.api_key ?? '').trim())
      if (!models.length) throw new Error('This key can’t use any Gemini text model.')
      const model = models.some((m) => m.id === cfg.model) ? cfg.model : pickDefault(models)
      await admin
        .from('integrations')
        .update({ status: 'connected', last_error: null, config: { ...cfg, model, models: JSON.stringify(models), checked_at: new Date().toISOString() } })
        .eq('id', r.id)
      return json({ ok: true, model, models: models.length })
    } catch (e) {
      await admin.from('integrations').update({ status: 'error', last_error: (e as Error).message }).eq('id', r.id)
      return fail((e as Error).message)
    }
  }
  if (b.action === 'insights_status' || b.action === 'insights') {
    const tenantId = String(b.tenant_id ?? '')
    const { data: memberId } = await asCaller.rpc('ai_insights_me', { p_tenant: tenantId })
    if (!memberId) return b.action === 'insights_status' ? json({ allowed: false }) : fail('You can’t use AI Insights.', 403)
    // the AI order (System Connections → AI order → AI Insights): Level 1, then the next when it fails
    const route = await aiRoute(admin, tenantId, 'insights')
    const connected = route.enabled && route.levels.some((l) => l.key)
    if (b.action === 'insights_status') return json({ allowed: true, connected })
    if (!route.enabled) return fail('AI Insights is turned off (System Connections → AI order).')
    if (!connected) return fail('Connect Gemini AI (or the AI set in System Connections → AI order) to use AI Insights.')
    if (route.limitHit) return fail(route.limitHit)
    const context = String(b.context ?? '').slice(0, 400_000)
    const page = String(b.page ?? '').slice(0, 200)
    const msgs = (Array.isArray(b.messages) ? b.messages : []).slice(-20) as { role: string; text: string }[]
    if (!msgs.length) return fail('Ask something.')
    const messages = msgs.map((m, i) => ({
      role: (m.role === 'model' ? 'model' : 'user') as 'model' | 'user',
      text: i === 0 ? `SCREEN: ${page}\n\n${context}\n\n---\n${String(m.text).slice(0, 4000)}` : String(m.text).slice(0, 4000),
    }))
    try {
      const o = await aiAsk(route, { system: INSIGHTS_RULES, messages, maxTokens: 8192 })
      await logUsage(admin, tenantId, o, 'insights', memberId === '00000000-0000-0000-0000-000000000000' ? null : memberId)
      return json({ ok: true, text: o.text, tokens: { input: o.inTok, output: o.outTok } })
    } catch (e) {
      return fail(e instanceof AiBusy ? 'The AI is busy right now. Try again in a minute.' : (e as Error).message)
    }
  }

  return fail('Unknown action')
})
