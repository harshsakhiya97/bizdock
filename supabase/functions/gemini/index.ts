// gemini: a workspace's Gemini AI connection (System Connections → Gemini AI: API key + model).
//
//   POST { action: 'models', api_key? | id? }  from the app (the Keys form): the models a key can use, for the dropdown
//                                 (the typed key, else the saved one of that connection)
//   POST { action: 'test', id }   from the app (on save): check the key with Google, list the models it can use (saved on
//                                 the connection for the Model dropdown) and pick a default model if none is set
//
// The key never reaches the browser. AI features (AI Insights, later) will call Gemini here and log tokens in ai_usage.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

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
      const { data: r } = await asCaller.from('integrations').select('config').eq('id', String(b.id)).eq('provider', 'gemini').maybeSingle()
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
    const { data: r } = await asCaller.from('integrations').select('id, config').eq('id', String(b.id ?? '')).eq('provider', 'gemini').maybeSingle()
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
  return fail('Unknown action')
})
