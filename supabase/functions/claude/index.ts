// claude: a workspace's Claude API connection (System Connections → Claude API: API key + model). Used by Sync
// transcripts (Callyzer → History logs) to fix the speaker labels of old call transcripts (call-transcribe).
//
//   POST { action: 'models', api_key? | id? }  from the app (the Keys form): the models the key can use, for the dropdown
//   POST { action: 'test', id }                from the app (on save): check the key, keep the model list, pick a model
//
// The key never reaches the browser.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

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

type Model = { id: string; name: string }

/** the models the key can use (newest first, as Anthropic lists them) */
async function listModels(key: string): Promise<Model[]> {
  const r = await fetch('https://api.anthropic.com/v1/models?limit=100', { headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01' } })
  const d = await r.json().catch(() => ({}))
  if (!r.ok) {
    const msg = d?.error?.message ?? `Claude API error ${r.status}`
    throw new Error(r.status === 401 || r.status === 403 ? `Anthropic refused the API key: ${msg}` : msg)
  }
  return ((d.data ?? []) as { id: string; display_name?: string }[]).map((m) => ({ id: m.id, name: m.display_name || m.id }))
}
/** a sensible default: the newest Sonnet, else the first */
const pickDefault = (models: Model[]) => (models.find((m) => /sonnet/i.test(m.id)) ?? models[0])?.id ?? ''

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
      // only people who can read the keys (System Connections)
      const { data: r } = await ownRow(asCaller, admin, String(b.id), 'claude', 'config')
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
    const { data: r } = await ownRow(asCaller, admin, String(b.id ?? ''), 'claude', 'id, config')
    if (!r) return fail('Connection not found.', 404)
    const cfg = (r.config ?? {}) as Record<string, string>
    try {
      const models = await listModels(String(cfg.api_key ?? '').trim())
      if (!models.length) throw new Error('This key can’t use any Claude model.')
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
