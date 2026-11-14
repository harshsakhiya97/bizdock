// meta-ads: pulls the connected Facebook ad accounts' numbers (Marketing API, read only).
//
// From the database every 3 hours (header x-cron-secret):  { action: 'cron', tenant_id? }
// From the app (System Connections or funnel editors):      { action: 'sync', tenant_id }  → pull now (in the background)
//
// Per ad account, one run at a time (lock_until):
//   1. campaigns, ad sets and ads (names, status, objective) at most every 3 hours
//   2. history: day by day per ad, 30 days per call, from backfill_from to today (continues in a new run if long)
//   3. then: the last 7 days again once a day (Meta keeps adjusting numbers), else yesterday and today
// Numbers go in per ad per day (meta_insights_put); spend is without GST, in the account's currency.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const V = 'v25.0'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const BUDGET_MS = 100_000
const FIELDS = 'date_start,campaign_id,campaign_name,adset_id,adset_name,ad_id,ad_name,spend,impressions,reach,frequency,clicks,inline_link_clicks,ctr,cpc,cpm,actions'
const ymd = (d: Date) => d.toISOString().slice(0, 10)
const addDays = (s: string, n: number) => ymd(new Date(Date.parse(`${s}T00:00:00Z`) + n * 86400_000))
/** today in the ad account's time zone */
const todayIn = (tz: string) => {
  try {
    return new Date().toLocaleDateString('en-CA', { timeZone: tz || 'Asia/Kolkata' })
  } catch {
    return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
  }
}

type Account = {
  id: string
  tenant_id: string
  integration_id: string
  act_id: string
  timezone: string | null
  backfill_from: string | null
  synced_until: string | null
  last_full_at: string | null
  lock_until: string | null
  structure_at: string | null
}

class MetaError extends Error {
  constructor(message: string, public code: number) {
    super(message)
  }
}
// token gone (190), permissions (200 / 10), too many calls (4, 17, 32, 613, 80000…)
const isAuth = (c: number) => c === 190 || c === 102 || c === 10 || c === 200
const isLimit = (c: number) => [4, 17, 32, 613].includes(c) || (c >= 80000 && c <= 80014)

async function proof(token: string, secret: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(token))
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, '0')).join('')
}

const adminClient = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

/** every page of a Graph list */
async function listAll(url: string): Promise<Record<string, unknown>[]> {
  const out: Record<string, unknown>[] = []
  let next: string | undefined = url
  for (let i = 0; next && i < 200; i++) {
    const r = await fetch(next)
    const d = await r.json().catch(() => ({}))
    if (!r.ok || d.error) throw new MetaError(d.error?.message ?? `Facebook error ${r.status}`, Number(d.error?.code ?? r.status))
    out.push(...((d.data ?? []) as Record<string, unknown>[]))
    next = d.paging?.next
  }
  return out
}

async function pullAccount(admin: SupabaseClient, a: Account, token: string, appSecret: string, deadline: number): Promise<{ done: boolean; rows: number; error?: string }> {
  if (a.lock_until && Date.parse(a.lock_until) > Date.now()) return { done: true, rows: 0 }
  await admin.from('meta_ad_accounts').update({ lock_until: new Date(Date.now() + 3 * 60_000).toISOString() }).eq('id', a.id)
  const p = await proof(token, appSecret)
  const base = (path: string, params: Record<string, string>) =>
    `https://graph.facebook.com/${V}/${a.act_id}/${path}?${new URLSearchParams({ ...params, access_token: token, appsecret_proof: p })}`
  const today = todayIn(a.timezone ?? '')
  let rows = 0
  const patch: Record<string, unknown> = {}
  const insights = async (since: string, until: string) => {
    const list = await listAll(base('insights', { level: 'ad', time_increment: '1', time_range: JSON.stringify({ since, until }), fields: FIELDS, limit: '500' }))
    for (let i = 0; i < Math.max(list.length, 1); i += 500) {
      const { data, error } = await admin.rpc('meta_insights_put', { p_account: a.id, p_since: since, p_until: until, p_rows: list.slice(i, i + 500), p_clear: i === 0 })
      if (error) throw new Error(error.message)
      rows += Number(data ?? 0)
    }
  }
  try {
    // 1. campaigns, ad sets, ads
    if (!a.structure_at || Date.now() - Date.parse(a.structure_at) > 3 * 3600_000) {
      const levels: [string, string, string][] = [
        ['campaign', 'campaigns', 'id,name,status,effective_status,objective,created_time'],
        ['adset', 'adsets', 'id,name,campaign_id,status,effective_status'],
        ['ad', 'ads', 'id,name,adset_id,campaign_id,status,effective_status'],
      ]
      for (const [level, path, fields] of levels) {
        const list = await listAll(base(path, { fields, limit: '500' }))
        for (let i = 0; i < list.length; i += 500) {
          const { error } = await admin.rpc('meta_structure_put', { p_account: a.id, p_level: level, p_rows: list.slice(i, i + 500) })
          if (error) throw new Error(error.message)
        }
      }
      patch.structure_at = new Date().toISOString()
    }
    // money: prepaid funds left, amount due, spent and the spending limit (one call; the funds line may need more access)
    try {
      const acct = async (fields: string) => {
        const r = await fetch(`https://graph.facebook.com/${V}/${a.act_id}?${new URLSearchParams({ fields, access_token: token, appsecret_proof: p })}`)
        const d = await r.json().catch(() => ({}))
        if (!r.ok || d.error) throw new MetaError(d.error?.message ?? `Facebook error ${r.status}`, Number(d.error?.code ?? r.status))
        return d as Record<string, unknown>
      }
      const basic = 'account_status,currency,balance,amount_spent,spend_cap,is_prepay_account'
      let d: Record<string, unknown>
      let fundsNote: string | null = null
      try {
        d = await acct(`${basic},funding_source_details,prepay_balance`)
      } catch (e) {
        if (e instanceof MetaError && isLimit(e.code)) throw e
        try {
          d = await acct(`${basic},funding_source_details`)
        } catch {
          d = await acct(basic)
          fundsNote = (e as Error).message
        }
      }
      const fsd = (d.funding_source_details ?? null) as { display_string?: string; type?: number } | null
      // a funds line like "Available balance (₹1,234.56 INR)" → 1234.56; never a card ("Mastercard *5819")
      const txt = fsd?.display_string ?? ''
      const m = /(balance|funds|₹|INR)/i.test(txt) && !/\*\d{3,}/.test(txt) ? txt.replace(/,/g, '').match(/(\d+(?:\.\d+)?)/) : null
      const pb = d.prepay_balance as { amount?: string | number; amount_in_hundredths?: string | number; currency?: string } | undefined
      const pbAmount = pb?.amount_in_hundredths != null ? Number(pb.amount_in_hundredths) / 100 : pb?.amount != null ? Number(pb.amount) : null
      patch.funds = {
        prepaid: !!d.is_prepay_account,
        available: pbAmount != null && !Number.isNaN(pbAmount) ? pbAmount : m ? Number(m[1]) : null,
        funds_text: fsd?.display_string ?? null,
        source_type: fsd?.type ?? null,
        raw: { funding: fsd, prepay_balance: pb ?? null },
        due: d.balance != null ? Number(d.balance) / 100 : null,
        spent: d.amount_spent != null ? Number(d.amount_spent) / 100 : null,
        cap: d.spend_cap != null && Number(d.spend_cap) > 0 ? Number(d.spend_cap) / 100 : null,
        currency: d.currency ?? null,
        note: fundsNote,
      }
      patch.funds_at = new Date().toISOString()
      if (d.account_status != null) patch.account_status = Number(d.account_status)
    } catch (e) {
      if (e instanceof MetaError && (isAuth(e.code) || isLimit(e.code))) throw e
    }
    // 2. history, 30 days per call
    let upto = a.synced_until
    const start = a.backfill_from ?? addDays(today, -90)
    while (!upto || upto < today) {
      if (Date.now() > deadline) {
        await admin.from('meta_ad_accounts').update({ ...patch, synced_until: upto, lock_until: null }).eq('id', a.id)
        return { done: false, rows }
      }
      const since = upto ? addDays(upto, 1) : start
      let until = addDays(since, 29)
      if (until > today) until = today
      await insights(since, until)
      upto = until
      patch.synced_until = upto
    }
    // 3. the last 7 days again once a day, else yesterday and today
    if (Date.now() < deadline) {
      if (a.last_full_at !== today) {
        await insights(addDays(today, -7), today)
        patch.last_full_at = today
      } else if (a.synced_until === today || patch.synced_until === undefined) {
        await insights(addDays(today, -1), today)
      }
    }
    await admin.from('meta_ad_accounts').update({ ...patch, last_sync_at: new Date().toISOString(), last_error: null, lock_until: null }).eq('id', a.id)
    return { done: true, rows }
  } catch (e) {
    const code = e instanceof MetaError ? e.code : 0
    const msg = isAuth(code) ? 'Facebook login expired or access was removed: press Reconnect.' : isLimit(code) ? 'Facebook asked to slow down; trying again later.' : (e as Error).message
    await admin.from('meta_ad_accounts').update({ ...patch, last_error: msg, lock_until: null }).eq('id', a.id)
    if (isAuth(code)) await admin.from('integrations').update({ status: 'error', last_error: msg }).eq('id', a.integration_id)
    return { done: true, rows, error: msg }
  }
}

async function continueLater(tenantId: string | null) {
  const { data: secret } = await adminClient().rpc('workflow_cron_secret')
  fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/meta-ads`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-cron-secret': String(secret ?? '') },
    body: JSON.stringify({ action: 'cron', tenant_id: tenantId }),
  }).catch(() => {})
  await new Promise((r) => setTimeout(r, 500))
}

async function runAll(admin: SupabaseClient, tenantId: string | null) {
  const appSecret = (Deno.env.get('META_APP_SECRET') ?? '').trim()
  if (!appSecret) return { error: 'META_APP_SECRET missing' }
  const deadline = Date.now() + BUDGET_MS
  let q = admin
    .from('meta_ad_accounts')
    .select('id, tenant_id, integration_id, act_id, timezone, backfill_from, synced_until, last_full_at, lock_until, structure_at, integrations!inner(is_enabled, status)')
    .eq('is_enabled', true)
    .eq('integrations.is_enabled', true)
    .eq('integrations.status', 'connected')
  if (tenantId) q = q.eq('tenant_id', tenantId)
  const { data, error } = await q
  if (error) return { error: error.message }
  const tokens = new Map<string, string>()
  const out: Record<string, unknown> = {}
  let unfinished = false
  for (const a of (data ?? []) as unknown as Account[]) {
    if (Date.now() > deadline) {
      unfinished = true
      break
    }
    if (!tokens.has(a.integration_id)) {
      const { data: t } = await admin.from('meta_tokens').select('access_token').eq('integration_id', a.integration_id).maybeSingle()
      tokens.set(a.integration_id, String(t?.access_token ?? ''))
    }
    const token = tokens.get(a.integration_id)!
    if (!token) continue
    const r = await pullAccount(admin, a, token, appSecret, deadline)
    out[a.act_id] = r
    if (!r.done) unfinished = true
  }
  if (unfinished) await continueLater(tenantId)
  return out
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const admin = adminClient()
  const b = await req.json().catch(() => ({}))

  const cronHeader = req.headers.get('x-cron-secret')
  if (cronHeader) {
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || cronHeader !== secret) return json({ error: 'Not allowed' }, 401)
    return json(await runAll(admin, b.tenant_id ? String(b.tenant_id) : null))
  }

  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return json({ error: 'Please log in again.' }, 401)
  const tenantId = String(b.tenant_id ?? '')
  if (b.action === 'sync') {
    const { data: may } = await asCaller.rpc('can_sync_meta', { p_tenant: tenantId })
    if (!may) return json({ error: 'You need System Connections or funnel edit access.' }, 403)
    // the structure is listed again now
    await admin.from('meta_ad_accounts').update({ structure_at: null }).eq('tenant_id', tenantId)
    await continueLater(tenantId)
    return json({ ok: true })
  }
  return json({ error: 'Unknown action' }, 400)
})
