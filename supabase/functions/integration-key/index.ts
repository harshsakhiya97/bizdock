// integration-key: System Connections → Copy next to a saved key. The browser only ever gets keys masked (AB••••••••YZ);
// Copy asks for the person's own BizDock password and this sends back that one key, which goes straight to the clipboard.
//
//   POST { integration_id, key, password }   key: one of SECRET_KEYS (facebook_ads 'access_token' = the Meta token)
//
// Who: anyone who can open System Connections (row security on integrations). Wrong password → nothing is sent.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

/** the config values that are keys / secrets / tokens (same list as private.integration_secret_keys) */
const SECRET_KEYS = ['api_key', 'access_token', 'key_secret', 'client_secret', 'developer_token', 'refresh_token', 'api_token', 'webhook_secret']

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const asCaller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)
  const b = (await req.json().catch(() => ({}))) as Record<string, unknown>
  const id = String(b.integration_id ?? '')
  const key = String(b.key ?? '')
  const password = String(b.password ?? '')
  if (!id || !SECRET_KEYS.includes(key)) return fail('Nothing to copy.')
  if (!password) return fail('Enter your password.')

  // only connections this person can manage (System Connections)
  const { data: ok } = await asCaller.from('integrations').select('id').eq('id', id).maybeSingle()
  if (!ok) return fail('Connection not found.', 404)

  // their own password, checked with a throw-away login (that one session is closed again straight away)
  if (!me.user.email) return fail('Your login has no email, so the password can’t be checked.')
  const check = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } })
  const { error: bad } = await check.auth.signInWithPassword({ email: me.user.email, password })
  if (bad) return fail(/rate|many/i.test(bad.message) ? 'Too many tries. Wait a minute and try again.' : 'Wrong password.', 403)
  await check.auth.signOut({ scope: 'local' }).catch(() => undefined)

  const { data: row } = await admin.from('integrations').select('provider, config').eq('id', id).maybeSingle()
  if (!row) return fail('Connection not found.', 404)
  let value = String(((row.config ?? {}) as Record<string, unknown>)[key] ?? '')
  if (!value && row.provider === 'facebook_ads' && key === 'access_token') {
    const { data: t } = await admin.from('meta_tokens').select('access_token').eq('integration_id', id).maybeSingle()
    value = String(t?.access_token ?? '')
  }
  if (!value) return fail('No saved key to copy.', 404)
  return json({ value })
})
