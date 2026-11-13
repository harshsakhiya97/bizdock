// meta-oauth: "Continue with Facebook" — BizDock's Meta app (Facebook Login for Business, configuration with a
// system-user token that doesn't expire, ads_read). The person logs in to Facebook, picks their business and ad accounts,
// presses Allow; the connection is saved as a facebook_ads row in integrations (its token in meta_tokens) with its ad
// accounts in meta_ad_accounts, and the first pull starts (meta-ads).
//
//   POST { action: 'start', tenant_id, integration_id?, back }  (the app, logged in) → { url, state }
//   GET  ?code=…&state=…  (Facebook sends the browser back here) → saved, then the popup goes to the app's /meta-connect page
//   POST { action: 'token', tenant_id, token, integration_id? }  → Add with a token: a system user's token made in the
//        client's Business Settings (for the BizDock app, ads_read); checked with Facebook, then saved the same way
//
// Secrets: META_APP_ID, META_APP_SECRET, META_CONFIG_ID. Tokens never reach the browser.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const V = 'v25.0'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const redirectUri = () => `${Deno.env.get('SUPABASE_URL')}/functions/v1/meta-oauth`
const newState = () => Array.from(crypto.getRandomValues(new Uint8Array(24)), (x) => x.toString(16).padStart(2, '0')).join('')

/** Meta asks for this proof with every call made with the app secret */
async function proof(token: string, secret: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(token))
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, '0')).join('')
}

type Result = { ok?: boolean; message?: string; integration_id?: string | null; back?: string | null }

type SaveIn = { tenantId: string; memberId: string | null; integrationId: string | null; token: string; tokenType: string; expiresIn: number; auth: 'oauth' | 'token' }
/** a Facebook login (popup) or a pasted token → the connection, its token and its ad accounts; the first pull starts */
async function saveConnection(admin: SupabaseClient, appSecret: string, o: SaveIn): Promise<{ error: string } | { label: string; accounts: number; integrationId: string }> {
  const token = o.token
  const p = await proof(token, appSecret)
  const graph = async (path: string, params: Record<string, string> = {}) => {
    const r = await fetch(`https://graph.facebook.com/${V}/${path}?${new URLSearchParams({ ...params, access_token: token, appsecret_proof: p })}`)
    const d = await r.json().catch(() => ({}))
    if (!r.ok || d.error) throw new Error(d.error?.message ?? `Facebook error ${r.status}`)
    return d
  }
  const who = await graph('me', { fields: 'id,name' })
  // the ad accounts the person allowed
  const accounts: Record<string, unknown>[] = []
  let page = await graph('me/adaccounts', { fields: 'id,account_id,name,currency,timezone_name,account_status,business{id,name}', limit: '200' })
  for (let i = 0; i < 20; i++) {
    accounts.push(...((page.data ?? []) as Record<string, unknown>[]))
    const next = page.paging?.next as string | undefined
    if (!next) break
    const r = await fetch(next)
    page = await r.json()
  }
  if (!accounts.length) return { error: o.auth === 'token' ? 'This token can’t see any ad account: assign the ad accounts to the system user (View performance) and try again.' : 'No ad accounts were shared. Try again and tick the ad accounts on Facebook’s screen.' }
  const business = (accounts.find((a) => (a.business as { name?: string } | undefined)?.name)?.business as { id?: string; name?: string } | undefined) ?? {}
  const label = business.name || String(who.name ?? 'Facebook')

  // the same Facebook login already connected here (or the one being reconnected): renewed; else a new connection
  const { data: rows } = await admin.from('integrations').select('id, config').eq('tenant_id', o.tenantId).eq('provider', 'facebook_ads')
  const all = (rows ?? []) as { id: string; config: Record<string, string> }[]
  const same = o.integrationId ? all.find((r) => r.id === o.integrationId) : all.find((r) => r.config?.fb_user_id === String(who.id))
  const config = { auth: o.auth, fb_user_id: String(who.id), fb_name: String(who.name ?? ''), business_id: String(business.id ?? ''), business_name: String(business.name ?? '') }
  let integrationId: string
  if (same) {
    const { error } = await admin.from('integrations').update({ label, config: { ...(same.config ?? {}), ...config }, status: 'connected', last_error: null, is_enabled: true }).eq('id', same.id)
    if (error) return { error: error.message }
    integrationId = same.id
  } else {
    const { data: ins, error } = await admin
      .from('integrations')
      .insert({ tenant_id: o.tenantId, provider: 'facebook_ads', label, config, status: 'connected', is_enabled: true, connected_by: o.memberId })
      .select('id')
      .single()
    if (error) return { error: error.message }
    integrationId = ins.id
  }
  const { error: tErr } = await admin.from('meta_tokens').upsert({
    integration_id: integrationId,
    access_token: token,
    token_type: o.tokenType,
    expires_at: o.expiresIn ? new Date(Date.now() + o.expiresIn * 1000).toISOString() : null,
    updated_at: new Date().toISOString(),
  })
  if (tErr) return { error: tErr.message }

  // history from the old ad-spend days (else the last 90 days)
  const { data: first } = await admin.from('ad_spend').select('spend_date').eq('tenant_id', o.tenantId).order('spend_date').limit(1).maybeSingle()
  const d90 = new Date(Date.now() - 90 * 86400_000).toISOString().slice(0, 10)
  const from = first?.spend_date && first.spend_date < d90 ? first.spend_date : d90
  for (const a of accounts) {
    const actId = String(a.id)
    const { data: had } = await admin.from('meta_ad_accounts').select('id').eq('tenant_id', o.tenantId).eq('act_id', actId).maybeSingle()
    const base = {
      integration_id: integrationId,
      name: String(a.name ?? actId),
      currency: String(a.currency ?? ''),
      timezone: String(a.timezone_name ?? ''),
      account_status: Number(a.account_status ?? 0) || null,
      business_name: (a.business as { name?: string } | undefined)?.name ?? null,
      last_error: null,
    }
    if (had) await admin.from('meta_ad_accounts').update(base).eq('id', had.id)
    else await admin.from('meta_ad_accounts').insert({ ...base, tenant_id: o.tenantId, act_id: actId, backfill_from: from })
  }

  // the first pull, in the background
  const { data: secret } = await admin.rpc('workflow_cron_secret')
  fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/meta-ads`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-cron-secret': String(secret ?? '') },
    body: JSON.stringify({ action: 'cron', tenant_id: o.tenantId }),
  }).catch(() => {})
  await new Promise((r) => setTimeout(r, 400))
  return { label, accounts: accounts.length, integrationId }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const appId = (Deno.env.get('META_APP_ID') ?? '').trim()
  const appSecret = (Deno.env.get('META_APP_SECRET') ?? '').trim()
  const configId = (Deno.env.get('META_CONFIG_ID') ?? '').trim()

  // ---- from the app ----
  if (req.method === 'POST') {
    const b = await req.json().catch(() => ({}))
    if (!appId || !appSecret || !configId) return json({ error: 'Continue with Facebook isn’t set up yet (BizDock’s Meta app keys are missing).' }, 400)
    const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    })
    const { data: me } = await asCaller.auth.getUser()
    if (!me.user) return json({ error: 'Please log in again.' }, 401)
    if (b.action !== 'start' && b.action !== 'token') return json({ error: 'Unknown action' }, 400)
    const tenantId = String(b.tenant_id ?? '')
    const { data: may } = await asCaller.rpc('can_manage_integrations', { p_tenant: tenantId })
    if (!may) return json({ error: 'You need System Connections access to connect Facebook.' }, 403)
    const { data: t } = await admin.from('tenants').select('connections').eq('id', tenantId).maybeSingle()
    if (!(t?.connections as Record<string, { allowed?: boolean }> | null)?.facebook_ads?.allowed) return json({ error: 'Facebook Ads isn’t enabled for your workspace. Ask BizDock to turn it on.' }, 400)
    if (b.action === 'token') {
      const token = String(b.token ?? '').trim()
      if (!token) return json({ error: 'Paste the access token.' }, 400)
      let integrationId: string | null = null
      if (b.integration_id) {
        const { data: row } = await asCaller.from('integrations').select('id').eq('id', String(b.integration_id)).eq('tenant_id', tenantId).eq('provider', 'facebook_ads').maybeSingle()
        if (!row) return json({ error: 'Connection not found.' }, 404)
        integrationId = row.id
      }
      const { data: m } = await admin.from('tenant_members').select('id').eq('tenant_id', tenantId).eq('user_id', me.user.id).maybeSingle()
      try {
        const r = await saveConnection(admin, appSecret, { tenantId, memberId: m?.id ?? null, integrationId, token, tokenType: 'system_user', expiresIn: 0, auth: 'token' })
        if ('error' in r) return json({ error: r.error }, 400)
        return json({ ok: true, message: `${r.label} is connected with ${r.accounts} ad account${r.accounts === 1 ? '' : 's'}.` })
      } catch (e) {
        const msg = (e as Error).message
        return json({ error: /appsecret_proof|app secret/i.test(msg) ? 'This token wasn’t made for the BizDock app: generate it for the BizDock app (system user → Generate token → app BizDock).' : `Facebook refused the token: ${msg}` }, 400)
      }
    }
    let integrationId: string | null = null
    if (b.integration_id) {
      const { data: row } = await asCaller.from('integrations').select('id').eq('id', String(b.integration_id)).eq('tenant_id', tenantId).eq('provider', 'facebook_ads').maybeSingle()
      if (!row) return json({ error: 'Connection not found.' }, 404)
      integrationId = row.id
    }
    const { data: m } = await admin.from('tenant_members').select('id').eq('tenant_id', tenantId).eq('user_id', me.user.id).maybeSingle()
    const back = /^(https:\/\/[a-z0-9.-]+|http:\/\/localhost)(:\d+)?(\/[\w./-]*)?$/i.test(String(b.back ?? '')) ? String(b.back) : null
    const state = newState()
    const { error } = await admin
      .from('meta_oauth_states')
      .insert({ id: state, tenant_id: tenantId, member_id: m?.id ?? null, user_id: me.user.id, integration_id: integrationId, result: { back } })
    if (error) return json({ error: error.message }, 500)
    const url = `https://www.facebook.com/${V}/dialog/oauth?${new URLSearchParams({
      client_id: appId,
      redirect_uri: redirectUri(),
      state,
      config_id: configId,
      response_type: 'code',
      override_default_response_type: 'true',
    })}`
    return json({ url, state })
  }

  // ---- Facebook sends the browser back ----
  const q = new URL(req.url).searchParams
  const stateId = q.get('state') ?? ''
  const { data: st } = stateId ? await admin.from('meta_oauth_states').select('*').eq('id', stateId).maybeSingle() : { data: null }
  const back = ((st?.result ?? {}) as Result).back ?? null
  const go = (r: Result) => {
    if (back) return Response.redirect(`${back}?state=${encodeURIComponent(stateId)}`, 302)
    return new Response(`${r.ok ? 'Facebook connected' : 'Facebook not connected'}: ${r.message ?? ''}\nYou can close this window.`, {
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    })
  }
  const finish = async (ok: boolean, message: string, integrationId: string | null = null) => {
    const r: Result = { ok, message, integration_id: integrationId, back }
    if (st) await admin.from('meta_oauth_states').update({ used_at: new Date().toISOString(), result: r }).eq('id', st.id)
    return go(r)
  }
  if (!st) return go({ ok: false, message: 'This link has expired. Start again from BizDock → System Connections → Facebook Ads.' })
  if (st.used_at) return go((st.result ?? {}) as Result)
  if (Date.now() - Date.parse(st.created_at) > 15 * 60_000) return finish(false, 'This took too long. Start again from BizDock.')
  if (q.get('error')) return finish(false, q.get('error_reason') === 'user_denied' ? 'You didn’t allow BizDock on Facebook.' : `Facebook said: ${q.get('error_description') ?? q.get('error')}`)
  const code = q.get('code')
  if (!code) return finish(false, 'Facebook didn’t send a code. Try again.')

  try {
    // the code → the connection's token
    const tr = await fetch(`https://graph.facebook.com/${V}/oauth/access_token?${new URLSearchParams({ client_id: appId, client_secret: appSecret, redirect_uri: redirectUri(), code })}`)
    const tok = await tr.json().catch(() => ({}))
    if (!tr.ok || !tok.access_token) return finish(false, `Facebook refused the login: ${tok.error?.message ?? tr.status}`)
    const token = String(tok.access_token)
    const saved = await saveConnection(admin, appSecret, { tenantId: st.tenant_id, memberId: st.member_id, integrationId: st.integration_id, token, tokenType: String(tok.token_type ?? ''), expiresIn: Number(tok.expires_in ?? 0), auth: 'oauth' })
    if ('error' in saved) return finish(false, saved.error)
    const { label, accounts, integrationId } = saved
    return finish(true, `${label} is connected with ${accounts} ad account${accounts === 1 ? '' : 's'}.`, integrationId)
  } catch (e) {
    return finish(false, (e as Error).message)
  }
})
