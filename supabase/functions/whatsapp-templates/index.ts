// whatsapp-templates: the workspace's WhatsApp message templates, through its own WhatsApp provider.
//
//   POST { tenant_id, action: 'list' }                          → { templates: [...] }
//   POST { tenant_id, action: 'create', template: {...WATI body} } → { ok, result }
//   POST { tenant_id, action: 'delete', waba_id, name, language }  → { ok }
//
// The provider keys are read with the CALLER's token, so row security decides: only people with
// "Settings & integrations" can read the integrations row. The keys never reach the browser.
// Providers: WATI for now (Dovesoft / AiSensy / Meta answer "not supported yet").
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)

  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return fail('Bad request')
  }
  const tenantId = String(body.tenant_id ?? '')
  if (!tenantId) return fail('Missing workspace')

  const { data: row } = await asCaller
    .from('integrations')
    .select('config, is_enabled')
    .eq('tenant_id', tenantId)
    .eq('provider', 'whatsapp')
    .maybeSingle()
  if (!row) return fail('Connect WhatsApp first (System Connections).', 404)
  if (!row.is_enabled) return fail('WhatsApp is paused. Turn it on in System Connections.')
  const cfg = (row.config ?? {}) as Record<string, string>
  if (cfg.vendor !== 'wati') return fail('Templates from this WhatsApp provider aren’t supported yet.')

  // "https://live-mt-server.wati.io/123456" (+ optional trailing slash / path) → base for v1/v2 calls
  const base = (cfg.api_endpoint ?? '').trim().replace(/\/+$/, '').replace(/\/api\/v\d.*$/, '')
  const token = (cfg.access_token ?? '').trim().replace(/^Bearer\s+/i, '')
  if (!/^https:\/\/[^/]+\/\w+/.test(base) || !token) return fail('The WATI API endpoint or access token is missing. Check System Connections.')

  const wati = async (method: string, path: string, payload?: unknown) => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, accept: 'application/json', ...(payload ? { 'content-type': 'application/json' } : {}) },
      body: payload ? JSON.stringify(payload) : undefined,
    })
    const text = await res.text()
    let data: unknown = null
    try {
      data = text ? JSON.parse(text) : null
    } catch {
      data = { raw: text.slice(0, 500) }
    }
    if (res.status === 401 || res.status === 403)
      throw new Error('WATI refused the access token (check the token and that it has template permissions).')
    if (!res.ok) {
      const d = data as Record<string, unknown> | null
      throw new Error(String(d?.result ?? d?.message ?? d?.error ?? `WATI error ${res.status}`))
    }
    return data as Record<string, unknown>
  }

  try {
    switch (body.action) {
      case 'list': {
        // all pages (100 per page, at most 10 pages)
        const all: unknown[] = []
        for (let page = 1; page <= 10; page++) {
          const d = await wati('GET', `/api/v2/getMessageTemplates?pageSize=100&pageNumber=${page}`)
          const items = (d.messageTemplates as unknown[]) ?? []
          all.push(...items)
          const link = d.link as { total?: number } | undefined
          if (!items.length || !link?.total || all.length >= link.total) break
        }
        return json({ templates: all })
      }
      case 'create': {
        const t = body.template as Record<string, unknown> | undefined
        if (!t?.elementName || !t.body) return fail('Template name and body are required.')
        const d = await wati('POST', '/api/v1/whatsApp/templates', t)
        if (d.ok === false) return fail(String(d.result ?? 'WATI did not accept the template.'))
        return json({ ok: true, result: d.result ?? null })
      }
      case 'delete': {
        const waba = String(body.waba_id ?? ''), name = String(body.name ?? ''), lang = String(body.language ?? '')
        if (!waba || !name || !lang) return fail('This template can’t be deleted from here (no WhatsApp account ID). Delete it in WATI.')
        const d = await wati('DELETE', `/api/v1/whatsApp/templates/${encodeURIComponent(waba)}/${encodeURIComponent(name)}/${encodeURIComponent(lang)}`)
        if (d?.ok === false) return fail(String(d.result ?? 'Delete failed.'))
        return json({ ok: true })
      }
      default:
        return fail('Unknown action')
    }
  } catch (e) {
    return fail((e as Error).message ?? 'Something went wrong', 502)
  }
})
