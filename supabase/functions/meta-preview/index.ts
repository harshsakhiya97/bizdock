// meta-preview: an ad's preview as Facebook draws it (Marketing API /{ad_id}/previews, read only).
//   POST { tenant_id, ad_id, format? }  (the app, logged in, System Connections or funnel edit access)
//   → { src } : the address of Facebook's preview frame (it works for a short while), or { error }
// The token never reaches the browser.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const V = 'v25.0'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const FORMATS = new Set(['MOBILE_FEED_STANDARD', 'DESKTOP_FEED_STANDARD', 'INSTAGRAM_STANDARD', 'INSTAGRAM_STORY', 'INSTAGRAM_REELS', 'FACEBOOK_STORY_MOBILE', 'FACEBOOK_REELS_MOBILE', 'RIGHT_COLUMN_STANDARD'])

async function proof(token: string, secret: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(token))
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const b = await req.json().catch(() => ({}))
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return json({ error: 'Please log in again.' }, 401)
  const tenantId = String(b.tenant_id ?? '')
  const adId = String(b.ad_id ?? '')
  const format = FORMATS.has(String(b.format)) ? String(b.format) : 'MOBILE_FEED_STANDARD'
  if (!/^\d+$/.test(adId)) return json({ error: 'Unknown ad.' }, 400)
  const { data: may } = await asCaller.rpc('can_sync_meta', { p_tenant: tenantId })
  if (!may) return json({ error: 'You need System Connections or funnel edit access.' }, 403)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: ad } = await admin.from('meta_ads').select('account_id').eq('tenant_id', tenantId).eq('ad_id', adId).maybeSingle()
  if (!ad) return json({ error: 'Unknown ad.' }, 404)
  const { data: acc } = await admin.from('meta_ad_accounts').select('integration_id').eq('id', ad.account_id).maybeSingle()
  const { data: t } = acc?.integration_id ? await admin.from('meta_tokens').select('access_token').eq('integration_id', acc.integration_id).maybeSingle() : { data: null }
  const token = String(t?.access_token ?? '')
  if (!token) return json({ error: 'This ad’s Facebook connection was removed.' }, 400)
  const appSecret = (Deno.env.get('META_APP_SECRET') ?? '').trim()

  const r = await fetch(`https://graph.facebook.com/${V}/${adId}/previews?${new URLSearchParams({ ad_format: format, access_token: token, appsecret_proof: await proof(token, appSecret) })}`)
  const d = await r.json().catch(() => ({}))
  if (!r.ok || d.error) return json({ error: `Facebook: ${d.error?.message ?? r.status}` }, 400)
  const body = String(d.data?.[0]?.body ?? '')
  const src = body.match(/src="([^"]+)"/)?.[1]?.replace(/&amp;/g, '&')
  if (!src || !/^https:\/\/([a-z0-9-]+\.)*facebook\.com\//.test(src)) return json({ error: 'Facebook has no preview of this ad in this format.' }, 404)
  return json({ src })
})
