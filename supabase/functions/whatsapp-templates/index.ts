// whatsapp-templates: the workspace's WhatsApp message templates, through its own WhatsApp provider.
//
//   POST { tenant_id, action: 'list' }                          → { templates: [...] }
//   POST { tenant_id, action: 'create', template: {...WATI body} } → { ok, result }
//   POST { tenant_id, action: 'delete', waba_id, name, language }  → { ok }
//   POST { tenant_id, action: 'send', phone, template, params, body?, lead_id? }  → { ok }  (WhatsApp logs → Chats; kept in the logs)
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

  /** WATI's own words for a refusal: its message / result / errors, else its whole reply (shortened) */
  const reason = (data: unknown): string | null => {
    if (data == null) return null
    if (typeof data === 'string') return data.slice(0, 500) || null
    const d = data as Record<string, unknown>
    // Meta's own explanation, passed on by WATI: { error: { error_user_title, error_user_msg } }
    const meta = (d.error ?? {}) as Record<string, unknown>
    if (typeof meta === 'object' && (meta.error_user_title || meta.error_user_msg))
      return [meta.error_user_title, meta.error_user_msg].filter(Boolean).join(': ').slice(0, 500)
    const pick = (v: unknown): string | null =>
      typeof v === 'string' && v.trim()
        ? v.trim()
        : Array.isArray(v) && v.length
          ? v.map((x) => (typeof x === 'string' ? x : (x as Record<string, unknown>)?.message ?? (x as Record<string, unknown>)?.description ?? JSON.stringify(x))).join('; ')
          : v && typeof v === 'object' && !Array.isArray(v)
            ? pick((v as Record<string, unknown>).message) ?? pick((v as Record<string, unknown>).feedback) ?? pick((v as Record<string, unknown>).error)
            : null
    const found = pick(d.message) ?? pick(d.result) ?? pick(d.info) ?? pick(d.error) ?? pick(d.errors) ?? pick(d.title) ?? pick(d.raw)
    if (found && !/^(false|true)$/i.test(found)) return found.slice(0, 500)
    const all = JSON.stringify(d)
    return all && all !== '{}' ? `WATI replied: ${all.slice(0, 400)}` : null
  }

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
    if (!res.ok) throw new Error(reason(data) ?? `WATI error ${res.status}`)
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
        // kept in the function logs, to see what WATI said
        console.log('wati create', t.elementName, JSON.stringify(d).slice(0, 2000))
        if (d.ok === false) return fail(`WATI did not accept the template: ${reason(d) ?? 'no reason given'}`)
        return json({ ok: true, result: d.result ?? null })
      }
      case 'delete': {
        const waba = String(body.waba_id ?? ''), name = String(body.name ?? ''), lang = String(body.language ?? '')
        if (!waba || !name || !lang) return fail('This template can’t be deleted from here (no WhatsApp account ID). Delete it in WATI.')
        const d = await wati('DELETE', `/api/v1/whatsApp/templates/${encodeURIComponent(waba)}/${encodeURIComponent(name)}/${encodeURIComponent(lang)}`)
        if (d?.ok === false) return fail(`Delete failed: ${reason(d) ?? 'no reason given'}`)
        return json({ ok: true })
      }
      case 'send': {
        // a template to one number (WhatsApp logs → Chats), kept in the logs
        let to = String(body.phone ?? '').replace(/\D/g, '')
        if (to.startsWith('00')) to = to.slice(2)
        if (to.length === 11 && to.startsWith('0')) to = to.slice(1)
        if (to.length === 10) to = `91${to}`
        if (to.length < 11) return fail('Not a valid WhatsApp number.')
        const template = String(body.template ?? '').trim()
        if (!template) return fail('Pick a template.')
        const params = Object.entries((body.params ?? {}) as Record<string, unknown>).map(([name, value]) => ({ name, value: String(value ?? '').trim() || '-' }))
        const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
        const { data: member } = await admin.from('tenant_members').select('id').eq('tenant_id', tenantId).eq('user_id', me.user.id).maybeSingle()
        const leadId = typeof body.lead_id === 'string' && body.lead_id ? body.lead_id : null
        const text = String(body.body ?? '').replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (m, k) => params.find((x) => x.name === k)?.value ?? m)
        const log = { tenant_id: tenantId, direction: 'out', phone: to, lead_id: leadId, template, body: text || null, params: Object.fromEntries(params.map((x) => [x.name, x.value])), source: 'app', sent_by: member?.id ?? null }
        try {
          const d = await wati('POST', `/api/v1/sendTemplateMessage?whatsappNumber=${to}`, { template_name: template, broadcast_name: 'bizdock_chat', parameters: params })
          if (d.result === false) throw new Error(reason(d) ?? `WATI didn't send it: check the template is approved and +${to} is on WhatsApp.`)
          await admin.from('whatsapp_logs').insert({ ...log, status: 'sent', wati_id: d.local_message_id ? String(d.local_message_id) : null })
          if (leadId) await admin.from('lead_messages').insert({ tenant_id: tenantId, lead_id: leadId, channel: 'whatsapp', title: template, body: text, via: 'app' })
          return json({ ok: true })
        } catch (e) {
          await admin.from('whatsapp_logs').insert({ ...log, status: 'failed', error: (e as Error).message.slice(0, 300) })
          throw e
        }
      }
      default:
        return fail('Unknown action')
    }
  } catch (e) {
    return fail((e as Error).message ?? 'Something went wrong', 502)
  }
})
