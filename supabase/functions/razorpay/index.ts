// razorpay: a workspace's Razorpay payments (System Connections → Razorpay: Key ID + Key Secret), pulled from Razorpay's
// API into razorpay_payments (Side menu → Payments → History logs).
//
//   POST { action: 'cron' } + header x-cron-secret   every 5 minutes: each connected account, from its last sync
//                                                    (7 days back again, so refunds / captures update) — first time 90 days
//   POST { action: 'test', id }      from the app (System Connections): check the keys
//   POST { action: 'sync', tenant_id } from the app (Payments page): sync now
//
// Keys never reach the browser. Amounts are saved in ₹ (Razorpay sends paise).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

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
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

const DAY = 86_400
const FIRST_DAYS = 90
const AGAIN_DAYS = 7
const RUN_MS = 50_000

type Row = { id: string; tenant_id: string; config: Record<string, string>; is_enabled: boolean }
type Pay = Record<string, unknown> & { id: string; amount: number; created_at: number; notes?: Record<string, unknown> | unknown[] }

async function rz(row: Row, path: string) {
  const id = String(row.config.key_id ?? '').trim()
  const secret = String(row.config.key_secret ?? '').trim()
  if (!id || !secret) throw new Error('The Razorpay Key ID or Key Secret is missing.')
  const res = await fetch(`https://api.razorpay.com/v1${path}`, { headers: { Authorization: `Basic ${btoa(`${id}:${secret}`)}` } })
  const body = await res.json().catch(() => ({}))
  if (res.status === 401) throw new Error('Razorpay refused the keys (check the Key ID and Key Secret, and Test / Live mode).')
  if (!res.ok) throw new Error(`Razorpay: ${body?.error?.description ?? res.status}`)
  return body as { count?: number; items?: Pay[] }
}

const s = (v: unknown) => (v == null || v === '' ? null : String(v))
const rupees = (p: unknown) => Math.round(Number(p ?? 0)) / 100

function toRow(row: Row, p: Pay) {
  return {
    tenant_id: row.tenant_id,
    integration_id: row.id,
    payment_id: p.id,
    order_id: s(p.order_id),
    invoice_id: s(p.invoice_id),
    amount: rupees(p.amount),
    currency: s(p.currency),
    status: s(p.status),
    method: s(p.method),
    captured: p.captured == null ? null : !!p.captured,
    email: s(p.email),
    phone: s(p.contact),
    description: s(p.description),
    notes: p.notes && !Array.isArray(p.notes) ? p.notes : {},
    amount_refunded: rupees(p.amount_refunded),
    refund_status: s(p.refund_status),
    fee: p.fee == null ? null : rupees(p.fee),
    tax: p.tax == null ? null : rupees(p.tax),
    error_description: s(p.error_description),
    vpa: s(p.vpa),
    bank: s(p.bank),
    wallet: s(p.wallet),
    paid_at: new Date(Number(p.created_at) * 1000).toISOString(),
    raw: p,
    synced_at: new Date().toISOString(),
  }
}

/** one account: the payments from its last sync (7 days back again), else the last 90 days */
async function syncOne(admin: SupabaseClient, row: Row, started: number) {
  const now = Math.floor(Date.now() / 1000)
  const last = Number(row.config.synced_until ?? 0)
  const from = last ? last - AGAIN_DAYS * DAY : now - FIRST_DAYS * DAY
  let skip = 0
  let saved = 0
  try {
    for (;;) {
      if (Date.now() - started > RUN_MS) break
      const page = await rz(row, `/payments?from=${from}&to=${now}&count=100&skip=${skip}`)
      const items = page.items ?? []
      if (items.length) {
        const { error } = await admin.from('razorpay_payments').upsert(items.map((p) => toRow(row, p)), { onConflict: 'tenant_id,payment_id' })
        if (error) throw new Error(error.message)
        saved += items.length
      }
      if (items.length < 100) {
        // all of it: next time from now (7 days back again)
        await admin
          .from('integrations')
          .update({ status: 'connected', last_error: null, config: { ...row.config, synced_until: String(now), last_sync_at: new Date().toISOString() } })
          .eq('id', row.id)
        return { saved, done: true }
      }
      skip += 100
    }
    // out of time: the next run carries on (same window, already-saved ones are just updated)
    await admin.from('integrations').update({ config: { ...row.config, last_sync_at: new Date().toISOString() } }).eq('id', row.id)
    return { saved, done: false }
  } catch (e) {
    await admin.from('integrations').update({ status: 'error', last_error: (e as Error).message }).eq('id', row.id)
    return { saved, error: (e as Error).message }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const b = (await req.json().catch(() => ({}))) as Record<string, unknown>
  const started = Date.now()

  // ---- every 5 minutes ----
  const cron = req.headers.get('x-cron-secret')
  if (cron) {
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || cron !== secret) return fail('Not allowed', 401)
    const { data } = await admin.from('integrations').select('id, tenant_id, config, is_enabled').eq('provider', 'razorpay').eq('is_enabled', true)
    const out = []
    for (const r of (data ?? []) as Row[]) {
      if (Date.now() - started > RUN_MS) break
      out.push({ id: r.id, ...(await syncOne(admin, r, started)) })
    }
    return json({ ok: true, accounts: out })
  }

  // ---- from the app ----
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)

  if (b.action === 'test') {
    // only people who can read the keys (System Connections)
    const { data: r } = await ownRow(asCaller, admin, String(b.id ?? ''), 'razorpay', 'id, tenant_id, config, is_enabled')
    if (!r) return fail('Account not found.', 404)
    try {
      await rz(r as Row, '/payments?count=1')
      await admin.from('integrations').update({ status: 'connected', last_error: null }).eq('id', r.id)
      return json({ ok: true })
    } catch (e) {
      await admin.from('integrations').update({ status: 'error', last_error: (e as Error).message }).eq('id', r.id)
      return fail((e as Error).message)
    }
  }

  if (b.action === 'sync') {
    const tenant = String(b.tenant_id ?? '')
    const { data: ok } = await asCaller.rpc('can_see_payments', { p_tenant: tenant })
    if (!ok) return fail('You can’t see payments.', 403)
    const { data } = await admin.from('integrations').select('id, tenant_id, config, is_enabled').eq('provider', 'razorpay').eq('tenant_id', tenant).eq('is_enabled', true)
    if (!data?.length) return fail('Razorpay isn’t connected (System Connections).')
    let saved = 0
    for (const r of data as Row[]) {
      const res = await syncOne(admin, r, started)
      if ('error' in res && res.error) return fail(res.error)
      saved += res.saved
    }
    return json({ ok: true, saved })
  }
  return fail('Unknown action')
})
