// zoom-oauth: "Connect with Zoom" — BizDock's own Zoom app (OAuth), so a workspace connects a Zoom account in a popup
// (Zoom's login → Allow) instead of making its own Server-to-Server app and pasting keys.
//
//   POST { action: 'start', tenant_id, integration_id?, origin }  (the app, logged in)
//        → { url, state }: open url in the popup; the app polls zoom_oauth_result(state)
//   GET  ?code=…&state=…  (Zoom sends the browser back here) → the account is saved as a Zoom row in integrations
//        (config.auth 'oauth'; its tokens in zoom_oauth_tokens), and the popup says so and closes.
//
// Secrets: ZOOM_OAUTH_CLIENT_ID, ZOOM_OAUTH_CLIENT_SECRET (the BizDock app's credentials). Tokens never reach the browser.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const redirectUri = () => `${Deno.env.get('SUPABASE_URL')}/functions/v1/zoom-oauth`
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

/** the page the popup ends on: what happened, then it closes (the app also polls the result) */
function page(ok: boolean, message: string, origin: string | null) {
  const msg = JSON.stringify({ source: 'bizdock-zoom', ok, message })
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Zoom · BizDock</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#f6f7f9;color:#111}
.box{background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:28px 32px;max-width:380px;text-align:center}
.ic{font-size:34px;margin-bottom:8px}.m{color:#555;font-size:14px;margin-top:6px}</style></head>
<body><div class="box"><div class="ic">${ok ? '✅' : '⚠️'}</div><b>${ok ? 'Zoom connected' : 'Zoom not connected'}</b><div class="m">${esc(message)}</div><div class="m">You can close this window.</div></div>
<script>try{if(window.opener)window.opener.postMessage(${msg},${JSON.stringify(origin || '*')})}catch(e){}${ok ? 'setTimeout(function(){window.close()},1500)' : ''}</script></body></html>`
  return new Response(html, { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const clientId = (Deno.env.get('ZOOM_OAUTH_CLIENT_ID') ?? '').trim()
  const clientSecret = (Deno.env.get('ZOOM_OAUTH_CLIENT_SECRET') ?? '').trim()

  // ---- the app opens the popup ----
  if (req.method === 'POST') {
    const b = await req.json().catch(() => ({}))
    if (b.action !== 'start') return json({ error: 'Unknown action' }, 400)
    if (!clientId || !clientSecret) return json({ error: 'Connect with Zoom isn’t set up yet (BizDock’s Zoom app keys are missing).' }, 400)
    const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    })
    const { data: me } = await asCaller.auth.getUser()
    if (!me.user) return json({ error: 'Please log in again.' }, 401)
    const tenantId = String(b.tenant_id ?? '')
    const { data: may } = await asCaller.rpc('can_manage_integrations', { p_tenant: tenantId })
    if (!may) return json({ error: 'You need “Settings & integrations” access to connect Zoom.' }, 403)
    const { data: t } = await admin.from('tenants').select('connections').eq('id', tenantId).maybeSingle()
    if (!(t?.connections as Record<string, { allowed?: boolean }> | null)?.zoom?.allowed) return json({ error: 'Zoom isn’t enabled for your workspace. Ask BizDock to turn it on.' }, 400)
    let integrationId: string | null = null
    if (b.integration_id) {
      const { data: row } = await asCaller.from('integrations').select('id').eq('id', String(b.integration_id)).eq('tenant_id', tenantId).eq('provider', 'zoom').maybeSingle()
      if (!row) return json({ error: 'Account not found.' }, 404)
      integrationId = row.id
    }
    const { data: m } = await admin.from('tenant_members').select('id').eq('tenant_id', tenantId).eq('user_id', me.user.id).maybeSingle()
    const state = Array.from(crypto.getRandomValues(new Uint8Array(24)), (x) => x.toString(16).padStart(2, '0')).join('')
    // the app's own address, so the popup can tell it (postMessage) — only a plain https / localhost origin
    const origin = /^https?:\/\/[a-z0-9.-]+(:\d+)?$/i.test(String(b.origin ?? '')) ? String(b.origin) : null
    const { error } = await admin
      .from('zoom_oauth_states')
      .insert({ id: state, tenant_id: tenantId, member_id: m?.id ?? null, user_id: me.user.id, integration_id: integrationId, result: origin ? { origin } : null })
    if (error) return json({ error: error.message }, 500)
    const url = `https://zoom.us/oauth/authorize?${new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: redirectUri(), state })}`
    return json({ url, state })
  }

  // ---- Zoom sends the browser back ----
  const q = new URL(req.url).searchParams
  const stateId = q.get('state') ?? ''
  const { data: st } = stateId ? await admin.from('zoom_oauth_states').select('*').eq('id', stateId).maybeSingle() : { data: null }
  const origin = (st?.result as { origin?: string } | null)?.origin ?? null
  const finish = async (ok: boolean, message: string, integrationId: string | null = null) => {
    if (st) await admin.from('zoom_oauth_states').update({ used_at: new Date().toISOString(), result: { ok, message, integration_id: integrationId, origin } }).eq('id', st.id)
    return page(ok, message, origin)
  }
  if (!st) return page(false, 'This link has expired. Start again from BizDock → System Connections → Zoom.', null)
  if (st.used_at) return page(false, 'This link was already used. Start again from BizDock.', origin)
  if (Date.now() - Date.parse(st.created_at) > 15 * 60_000) return finish(false, 'This took too long. Start again from BizDock.')
  if (q.get('error')) return finish(false, q.get('error') === 'access_denied' ? 'You didn’t allow BizDock on Zoom.' : `Zoom said: ${q.get('error_description') ?? q.get('error')}`)
  const code = q.get('code')
  if (!code) return finish(false, 'Zoom didn’t send a code. Try again.')

  try {
    // the code → the account's tokens
    const res = await fetch(`https://zoom.us/oauth/token?${new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri() })}`, {
      method: 'POST',
      headers: { Authorization: `Basic ${btoa(`${clientId}:${clientSecret}`)}` },
    })
    const tok = await res.json().catch(() => ({}))
    if (!res.ok || !tok.access_token) return finish(false, `Zoom refused the login: ${tok.reason ?? tok.error ?? res.status}`)
    // who connected
    const ur = await fetch('https://api.zoom.us/v2/users/me', { headers: { Authorization: `Bearer ${tok.access_token}` } })
    const u = await ur.json().catch(() => ({}))
    if (!ur.ok || !u.id) return finish(false, `Couldn’t read the Zoom user: ${u.message ?? ur.status}`)
    const name = [u.first_name, u.last_name].filter(Boolean).join(' ').trim() || String(u.email ?? 'Zoom')
    const email = String(u.email ?? '')

    // the same Zoom user already connected here (or the account being reconnected): renew it; else a new account
    const { data: rows } = await admin.from('integrations').select('id, label, config').eq('tenant_id', st.tenant_id).eq('provider', 'zoom')
    const all = (rows ?? []) as { id: string; label: string | null; config: Record<string, string> }[]
    const same = st.integration_id
      ? all.find((r) => r.id === st.integration_id)
      : all.find((r) => r.config?.auth === 'oauth' && r.config?.zoom_user_id === String(u.id))
    let integrationId: string
    const base = { auth: 'oauth', zoom_user_id: String(u.id), zoom_account_id: String(u.account_id ?? ''), zoom_email: email, host_email: '' }
    if (same) {
      const config: Record<string, string> = { ...(same.config ?? {}), ...base }
      // an older keys-account switched to Connect with Zoom: its keys go
      delete config.account_id
      delete config.client_id
      delete config.client_secret
      const { error } = await admin.from('integrations').update({ config, status: 'connected', last_error: null, is_enabled: true }).eq('id', same.id)
      if (error) return finish(false, error.message)
      integrationId = same.id
    } else {
      // a name not used yet in this workspace
      const taken = new Set(all.map((r) => (r.label ?? '').toLowerCase()))
      let label = name
      if (taken.has(label.toLowerCase())) label = `${name} (${email})`
      for (let i = 2; taken.has(label.toLowerCase()); i++) label = `${name} ${i}`
      const config = { ...base, cloud_record: 'Yes', is_default: all.length ? 'No' : 'Yes' }
      const { data: ins, error } = await admin
        .from('integrations')
        .insert({ tenant_id: st.tenant_id, provider: 'zoom', label, config, status: 'connected', is_enabled: true, connected_by: st.member_id })
        .select('id')
        .single()
      if (error) return finish(false, error.message)
      integrationId = ins.id
    }
    const { error: tErr } = await admin.from('zoom_oauth_tokens').upsert({
      integration_id: integrationId,
      access_token: tok.access_token,
      refresh_token: tok.refresh_token,
      expires_at: new Date(Date.now() + (Number(tok.expires_in) || 3600) * 1000).toISOString(),
      scope: tok.scope ?? null,
      updated_at: new Date().toISOString(),
    })
    if (tErr) return finish(false, tErr.message)
    return finish(true, `${name}${email ? ` (${email})` : ''} is connected.`, integrationId)
  } catch (e) {
    return finish(false, (e as Error).message)
  }
})
