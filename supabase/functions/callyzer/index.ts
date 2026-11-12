// callyzer: a workspace's Callyzer account → BizDock's calls (Callyzer API v2.2, the account's API access key).
//
// From the app (logged in, "Settings & integrations" access):
//   { action: 'test', tenant_id, api_key }        → { ok, total }: the key works (last 7 days' calls counted)
//   { action: 'connect', tenant_id, api_key }     → saves the key and starts pulling the last 180 days
//   { action: 'sync', tenant_id }                 → pull now
// From the database every 5 minutes (header x-cron-secret):
//   { action: 'cron' }                            → pull every connected workspace
//
// Calls are asked for by the time Callyzer received them from the phone (synced_from / synced_to), so a phone that syncs
// late is still caught. Phone calls and WhatsApp calls (voice + video). Only numbers that are a lead's number are kept
// (callyzer_ingest). Callyzer allows one request per 2 seconds; a long pull continues in a new run (a cursor in config).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const API = 'https://api1.callyzer.co/api/v2.2'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const nowSec = () => Math.floor(Date.now() / 1000)
const DAY = 86400
const BUDGET_MS = 100_000
const COMBOS: [string, string][] = [
  ['PhoneCall', 'Voice'],
  ['WhatsAppCall', 'Voice'],
  ['WhatsAppCall', 'Video'],
]

type Config = Record<string, string>
type Row = { id: string; tenant_id: string; config: Config; is_enabled: boolean; status: string }
type Cursor = { from: number; to: number; combo: number; page: number }

// ---- Callyzer API (one request per 2 s) ----
let lastCall = 0
async function cz(apiKey: string, path: string, body: Record<string, unknown>): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const wait = lastCall + 2100 - Date.now()
    if (wait > 0) await sleep(wait)
    lastCall = Date.now()
    const res = await fetch(`${API}${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const data = (await res.json().catch(() => ({}))) as Record<string, unknown>
    if (res.status === 429) {
      await sleep((Number(res.headers.get('retry-after')) || 3) * 1000)
      continue
    }
    return { ok: res.ok, status: res.status, data }
  }
  return { ok: false, status: 429, data: { message: 'Callyzer is busy (too many requests). Try again in a minute.' } }
}
const czError = (r: { status: number; data: Record<string, unknown> }) =>
  r.status === 401
    ? 'Callyzer refused the API key. Generate a new one in Callyzer → Connectors → API & Webhook → API Config.'
    : r.status === 403
      ? `Callyzer refused: ${String(r.data.message ?? 'the API add-on or subscription is not active')}.`
      : `Callyzer said: ${String(r.data.message ?? r.status)}`

async function testKey(apiKey: string) {
  const to = nowSec() - 60
  const r = await cz(apiKey, '/call-log/history', { call_from: to - 7 * DAY, call_to: to, call_method: 'PhoneCall', call_mode: 'Voice', page_no: 1, page_size: 1 })
  if (!r.ok) return { ok: false as const, error: czError(r) }
  return { ok: true as const, total: Number(r.data.total_records ?? 0) }
}

// ---- pulling ----
async function pull(admin: SupabaseClient, row: Row, deadline: number): Promise<{ saved: number; done: boolean; error?: string }> {
  const cfg = { ...row.config }
  const key = cfg.api_key
  if (!key) return { saved: 0, done: true, error: 'No API key.' }
  // one run at a time per workspace
  if (cfg.lock_until && Date.parse(cfg.lock_until) > Date.now()) return { saved: 0, done: true }
  const save = async (patch: Config, extra: Record<string, unknown> = {}) => {
    Object.assign(cfg, patch)
    await admin.from('integrations').update({ config: cfg, ...extra }).eq('id', row.id)
  }
  await save({ lock_until: new Date(Date.now() + 3 * 60_000).toISOString() })

  let cur: Cursor | null = null
  try {
    cur = cfg.cursor ? (JSON.parse(cfg.cursor) as Cursor) : null
  } catch {
    cur = null
  }
  if (!cur) {
    const to = nowSec() - 60
    const start = Number(cfg.synced_until) || to - 180 * DAY + 120
    const from = Math.max(start, to - 179 * DAY)
    if (to - from < 60) {
      await save({ lock_until: '', last_sync_at: new Date().toISOString() })
      return { saved: 0, done: true }
    }
    cur = { from, to, combo: 0, page: 1 }
  }

  let saved = 0
  try {
    while (cur.combo < COMBOS.length) {
      if (Date.now() > deadline) {
        await save({ cursor: JSON.stringify(cur), lock_until: '', last_saved: String(Number(cfg.last_saved || 0) + saved) })
        return { saved, done: false }
      }
      const [method, mode] = COMBOS[cur.combo]
      const r = await cz(key, '/call-log/history', {
        synced_from: cur.from,
        synced_to: cur.to,
        call_method: method,
        call_mode: mode,
        page_no: cur.page,
        page_size: 100,
      })
      if (!r.ok) {
        const msg = czError(r)
        // a refused key stops the pulls until it is fixed; other errors are tried again next time
        await save({ cursor: JSON.stringify(cur), lock_until: '' }, r.status === 401 || r.status === 403 ? { status: 'error', last_error: msg } : { last_error: msg })
        return { saved, done: false, error: msg }
      }
      const list = (Array.isArray(r.data.result) ? r.data.result : []) as Record<string, unknown>[]
      if (list.length) {
        const { data: n, error } = await admin.rpc('callyzer_ingest', { p_tenant: row.tenant_id, p_rows: list })
        if (error) throw new Error(error.message)
        saved += Number(n ?? 0)
      }
      const total = Number(r.data.total_records ?? 0)
      if (list.length === 100 && cur.page * 100 < total) cur.page++
      else cur = { ...cur, combo: cur.combo + 1, page: 1 }
    }
    // the window is done
    await save(
      { cursor: '', synced_until: String(cur.to), lock_until: '', last_sync_at: new Date().toISOString(), last_saved: '0' },
      { status: 'connected', last_error: null },
    )
    return { saved, done: true }
  } catch (e) {
    await save({ cursor: cur ? JSON.stringify(cur) : '', lock_until: '' }, { last_error: (e as Error).message })
    return { saved, done: false, error: (e as Error).message }
  }
}

/** a long pull goes on in a new run (fire and forget) */
async function continueLater(tenantId: string | null) {
  const secret = await adminClient().rpc('workflow_cron_secret')
  fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/callyzer`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-cron-secret': String(secret.data ?? '') },
    body: JSON.stringify({ action: 'cron', tenant_id: tenantId }),
  }).catch(() => {})
  await sleep(500)
}

const adminClient = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

async function runAll(admin: SupabaseClient, tenantId: string | null) {
  const deadline = Date.now() + BUDGET_MS
  let q = admin.from('integrations').select('id, tenant_id, config, is_enabled, status').eq('provider', 'callyzer').eq('is_enabled', true).eq('status', 'connected')
  if (tenantId) q = q.eq('tenant_id', tenantId)
  const { data } = await q
  let unfinished = false
  const out: Record<string, unknown> = {}
  for (const row of (data ?? []) as Row[]) {
    if (Date.now() > deadline) {
      unfinished = true
      break
    }
    const r = await pull(admin, row, deadline)
    out[row.tenant_id] = r
    if (!r.done && !r.error) unfinished = true
  }
  if (unfinished) await continueLater(tenantId)
  return out
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const admin = adminClient()
  const b = await req.json().catch(() => ({}))

  // ---- from the database ----
  const cronHeader = req.headers.get('x-cron-secret')
  if (cronHeader) {
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || cronHeader !== secret) return json({ error: 'Not allowed' }, 401)
    return json(await runAll(admin, b.tenant_id ? String(b.tenant_id) : null))
  }

  // ---- from the app ----
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return json({ error: 'Please log in again.' }, 401)
  const tenantId = String(b.tenant_id ?? '')
  const { data: may } = await asCaller.rpc('can_manage_integrations', { p_tenant: tenantId })
  if (!may) return json({ error: 'You need “Settings & integrations” access for Callyzer.' }, 403)
  const { data: t } = await admin.from('tenants').select('connections').eq('id', tenantId).maybeSingle()
  if (!(t?.connections as Record<string, { allowed?: boolean }> | null)?.callyzer?.allowed) return json({ error: 'Callyzer isn’t enabled for your workspace. Ask BizDock to turn it on.' }, 400)

  if (b.action === 'test' || b.action === 'connect') {
    const apiKey = String(b.api_key ?? '').trim()
    if (!apiKey) return json({ error: 'Paste the API access key.' }, 400)
    const test = await testKey(apiKey)
    if (!test.ok) return json({ error: test.error }, 400)
    if (b.action === 'test') return json({ ok: true, total: test.total })

    const { data: m } = await admin.from('tenant_members').select('id').eq('tenant_id', tenantId).eq('user_id', me.user.id).maybeSingle()
    const { data: old } = await admin.from('integrations').select('id, config').eq('tenant_id', tenantId).eq('provider', 'callyzer').maybeSingle()
    // a new key keeps how far it has pulled (same Callyzer account); a first connect pulls the last 180 days
    const config: Config = { ...((old?.config as Config) ?? {}), api_key: apiKey, lock_until: '', cursor: '' }
    const row = { config, status: 'connected', last_error: null, is_enabled: true }
    const { error } = old
      ? await admin.from('integrations').update(row).eq('id', old.id)
      : await admin.from('integrations').insert({ ...row, tenant_id: tenantId, provider: 'callyzer', connected_by: m?.id ?? null })
    if (error) return json({ error: error.message }, 500)
    await continueLater(tenantId)
    return json({ ok: true, total: test.total })
  }

  if (b.action === 'sync') {
    await continueLater(tenantId)
    return json({ ok: true })
  }
  return json({ error: 'Unknown action' }, 400)
})
