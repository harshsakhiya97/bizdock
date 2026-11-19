// google-ads: a workspace's Google Ads spend (Google Ads API, read only), with the keys saved in System Connections →
// Google Ads: developer token, OAuth client ID + secret, refresh token, and optionally a manager (MCC) ID and customer IDs.
//
//   POST { action: 'test', id }          from the app (on save): log in, list the ad accounts, start the first pull
//   POST { action: 'sync', tenant_id }   from the app (Sync now / Refresh from Google): pull now, in the background
//   POST { action: 'cron', tenant_id? }  + header x-cron-secret, every 3 hours
//
// Per ad account, one run at a time (lock_until):
//   1. campaigns, ad groups and ads (names, status, type, headlines…) at most every 3 hours
//   2. history: per day at campaign / ad group / ad level, 30 days per call, from backfill_from (90 days back) to today
//   3. then: the last 7 days again once a day (Google keeps adjusting numbers), else yesterday and today
// Spend is saved without GST, in the account's currency (cost_micros ÷ 1,000,000).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const V = 'v26'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const BUDGET_MS = 100_000
const ymd = (d: Date) => d.toISOString().slice(0, 10)
const addDays = (s: string, n: number) => ymd(new Date(Date.parse(`${s}T00:00:00Z`) + n * 86400_000))
const todayIn = (tz: string) => {
  try {
    return new Date().toLocaleDateString('en-CA', { timeZone: tz || 'Asia/Kolkata' })
  } catch {
    return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
  }
}
const digits = (s: unknown) => String(s ?? '').replace(/\D/g, '')
const adminClient = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

type Cfg = Record<string, string>
type Account = {
  id: string
  tenant_id: string
  integration_id: string
  customer_id: string
  timezone: string | null
  backfill_from: string | null
  synced_until: string | null
  last_full_at: string | null
  lock_until: string | null
  structure_at: string | null
}

class GoogleError extends Error {
  constructor(message: string, public auth = false) {
    super(message)
  }
}

/** an access token from the saved refresh token */
async function accessToken(cfg: Cfg) {
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: String(cfg.client_id ?? '').trim(), client_secret: String(cfg.client_secret ?? '').trim(), refresh_token: String(cfg.refresh_token ?? '').trim(), grant_type: 'refresh_token' }),
  })
  const d = await r.json().catch(() => ({}))
  if (!r.ok || !d.access_token) throw new GoogleError(`Google refused the login (check the Client ID, Client Secret and Refresh token): ${d.error_description ?? d.error ?? r.status}`, true)
  return String(d.access_token)
}

/** Google's error words, the readable part */
function errText(d: unknown, status: number) {
  const e = (Array.isArray(d) ? (d[0] as Record<string, unknown>)?.error : (d as Record<string, unknown>)?.error) as
    | { message?: string; status?: string; details?: { errors?: { message?: string; errorCode?: Record<string, string> }[] }[] }
    | undefined
  const inner = e?.details?.flatMap((x) => x.errors ?? [])?.[0]
  const code = inner?.errorCode ? Object.values(inner.errorCode)[0] : ''
  const msg = inner?.message ?? e?.message ?? `Google Ads error ${status}`
  const auth = status === 401 || status === 403 || e?.status === 'UNAUTHENTICATED' || e?.status === 'PERMISSION_DENIED'
  const nice =
    code === 'CLOUD_PROJECT_NOT_APPROVED_FOR_PRODUCTION'
      ? 'The Google Cloud project only has Test Account access: request Explorer (or Basic) access in Google Cloud → Google Ads API.'
      : code === 'DEVELOPER_TOKEN_NOT_APPROVED'
      ? 'The developer token only has test access: apply for Basic access in the manager account’s API Center.'
      : code === 'DEVELOPER_TOKEN_INVALID' || code === 'DEVELOPER_TOKEN_PROHIBITED'
        ? 'Google refused the developer token.'
        : code === 'USER_PERMISSION_DENIED'
          ? 'This Google login can’t see that account (if it sits under a manager account, fill in the Manager ID).'
          : msg
  return new GoogleError(nice, auth)
}

function api(cfg: Cfg, token: string) {
  const headers = (login?: string) => {
    // access now follows the Google Cloud project (Explorer / Basic…); a developer token is optional and ignored by Google
    const h: Record<string, string> = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }
    const dev = String(cfg.developer_token ?? '').trim()
    if (dev) h['developer-token'] = dev
    const l = digits(login ?? cfg.login_customer_id)
    if (l) h['login-customer-id'] = l
    return h
  }
  return {
    /** every row of a GAQL query */
    async query(customer: string, q: string): Promise<Record<string, any>[]> {
      const r = await fetch(`https://googleads.googleapis.com/${V}/customers/${customer}/googleAds:searchStream`, { method: 'POST', headers: headers(), body: JSON.stringify({ query: q }) })
      const d = await r.json().catch(() => null)
      if (!r.ok) throw errText(d, r.status)
      return ((d ?? []) as { results?: Record<string, any>[] }[]).flatMap((b) => b.results ?? [])
    },
    async accessible(): Promise<string[]> {
      const r = await fetch(`https://googleads.googleapis.com/${V}/customers:listAccessibleCustomers`, { headers: headers('') })
      const d = await r.json().catch(() => null)
      if (!r.ok) throw errText(d, r.status)
      return ((d?.resourceNames ?? []) as string[]).map((x) => digits(x))
    },
  }
}

/** log in, find the ad accounts (the listed customer IDs, else the manager's accounts, else every account the login sees) */
async function discover(admin: SupabaseClient, row: { id: string; tenant_id: string; config: Cfg }) {
  const cfg = row.config
  const token = await accessToken(cfg)
  const g = api(cfg, token)
  let ids = String(cfg.customer_ids ?? '').split(/[\s,;]+/).map(digits).filter(Boolean)
  if (!ids.length && digits(cfg.login_customer_id)) {
    const list = await g.query(digits(cfg.login_customer_id), 'SELECT customer_client.id, customer_client.manager, customer_client.status FROM customer_client WHERE customer_client.level <= 1')
    ids = list.filter((x) => !x.customerClient?.manager && (x.customerClient?.status ?? 'ENABLED') === 'ENABLED').map((x) => digits(x.customerClient?.id))
  }
  if (!ids.length) ids = await g.accessible()
  if (!ids.length) throw new GoogleError('No Google Ads accounts were found for this login.')
  const today = todayIn('Asia/Kolkata')
  let saved = 0
  const problems: string[] = []
  for (const id of [...new Set(ids)]) {
    try {
      const [c] = await g.query(id, 'SELECT customer.id, customer.descriptive_name, customer.currency_code, customer.time_zone, customer.manager FROM customer LIMIT 1')
      const { data: had } = await admin.from('google_ad_accounts').select('id').eq('tenant_id', row.tenant_id).eq('customer_id', id).maybeSingle()
      const base = { integration_id: row.id, name: c?.customer?.descriptiveName ?? null, currency: c?.customer?.currencyCode ?? null, timezone: c?.customer?.timeZone ?? null, is_manager: !!c?.customer?.manager }
      const { error } = had
        ? await admin.from('google_ad_accounts').update({ ...base, last_error: null }).eq('id', had.id)
        : await admin.from('google_ad_accounts').insert({ ...base, tenant_id: row.tenant_id, customer_id: id, backfill_from: addDays(today, -90) })
      if (error) throw new Error(error.message)
      saved++
    } catch (e) {
      problems.push(`${id}: ${(e as Error).message}`)
      if (e instanceof GoogleError && e.auth && ids.length === 1) throw e
    }
  }
  if (!saved) throw new GoogleError(problems[0] ?? 'No Google Ads accounts could be read.')
  return { saved, problems }
}

const micros = (v: unknown) => Math.round(Number(v ?? 0) / 10_000) / 100

async function pullAccount(admin: SupabaseClient, a: Account, cfg: Cfg, token: string, deadline: number): Promise<{ done: boolean; rows: number; error?: string }> {
  if (a.lock_until && Date.parse(a.lock_until) > Date.now()) return { done: true, rows: 0 }
  await admin.from('google_ad_accounts').update({ lock_until: new Date(Date.now() + 3 * 60_000).toISOString() }).eq('id', a.id)
  const g = api(cfg, token)
  const cid = a.customer_id
  const today = todayIn(a.timezone ?? '')
  const now = new Date().toISOString()
  let rows = 0
  const patch: Record<string, unknown> = {}
  const put = async (table: string, list: Record<string, unknown>[], conflict: string) => {
    for (let i = 0; i < list.length; i += 500) {
      const { error } = await admin.from(table).upsert(list.slice(i, i + 500), { onConflict: conflict })
      if (error) throw new Error(error.message)
    }
  }
  const metrics = 'metrics.cost_micros, metrics.impressions, metrics.clicks, metrics.conversions'
  const insights = async (since: string, until: string) => {
    const where = `WHERE segments.date BETWEEN '${since}' AND '${until}'`
    const levels: [string, string][] = [
      ['campaign', `SELECT segments.date, campaign.id, ${metrics} FROM campaign ${where}`],
      ['ad_group', `SELECT segments.date, campaign.id, ad_group.id, ${metrics} FROM ad_group ${where}`],
      ['ad', `SELECT segments.date, campaign.id, ad_group.id, ad_group_ad.ad.id, ${metrics} FROM ad_group_ad ${where}`],
    ]
    for (const [level, q] of levels) {
      const list = await g.query(cid, q)
      const { error } = await admin.from('google_insights').delete().eq('account_id', a.id).eq('level', level).gte('day', since).lte('day', until)
      if (error) throw new Error(error.message)
      await put(
        'google_insights',
        list.map((r) => ({
          tenant_id: a.tenant_id,
          account_id: a.id,
          level,
          day: r.segments?.date,
          campaign_id: String(r.campaign?.id ?? ''),
          ad_group_id: level === 'campaign' ? '' : String(r.adGroup?.id ?? ''),
          ad_id: level === 'ad' ? String(r.adGroupAd?.ad?.id ?? '') : '',
          spend: micros(r.metrics?.costMicros),
          impressions: Number(r.metrics?.impressions ?? 0),
          clicks: Number(r.metrics?.clicks ?? 0),
          conversions: Number(r.metrics?.conversions ?? 0),
          updated_at: new Date().toISOString(),
        })),
        'tenant_id,level,campaign_id,ad_group_id,ad_id,day',
      )
      rows += list.length
    }
  }
  try {
    // 1. campaigns, ad groups, ads
    if (!a.structure_at || Date.now() - Date.parse(a.structure_at) > 3 * 3600_000) {
      const camps = await g.query(cid, "SELECT campaign.id, campaign.name, campaign.status, campaign.advertising_channel_type FROM campaign WHERE campaign.status != 'REMOVED'")
      await put('google_campaigns', camps.map((r) => ({ tenant_id: a.tenant_id, campaign_id: String(r.campaign.id), account_id: a.id, name: r.campaign.name ?? null, status: r.campaign.status ?? null, channel: r.campaign.advertisingChannelType ?? null, updated_at: now })), 'tenant_id,campaign_id')
      const groups = await g.query(cid, "SELECT ad_group.id, ad_group.name, ad_group.status, campaign.id FROM ad_group WHERE ad_group.status != 'REMOVED'")
      await put('google_ad_groups', groups.map((r) => ({ tenant_id: a.tenant_id, ad_group_id: String(r.adGroup.id), campaign_id: String(r.campaign?.id ?? ''), account_id: a.id, name: r.adGroup.name ?? null, status: r.adGroup.status ?? null, updated_at: now })), 'tenant_id,ad_group_id')
      const ads = await g.query(
        cid,
        "SELECT ad_group_ad.ad.id, ad_group_ad.ad.name, ad_group_ad.ad.type, ad_group_ad.status, ad_group_ad.ad.final_urls, ad_group_ad.ad.responsive_search_ad.headlines, ad_group_ad.ad.responsive_search_ad.descriptions, ad_group_ad.ad.responsive_display_ad.headlines, ad_group_ad.ad.responsive_display_ad.descriptions, ad_group.id, campaign.id FROM ad_group_ad WHERE ad_group_ad.status != 'REMOVED'",
      )
      const texts = (x: unknown) => ((x ?? []) as { text?: string }[]).map((t) => t.text).filter(Boolean)
      await put(
        'google_ads',
        ads.map((r) => {
          const ad = r.adGroupAd?.ad ?? {}
          const heads = [...texts(ad.responsiveSearchAd?.headlines), ...texts(ad.responsiveDisplayAd?.headlines)]
          const descs = [...texts(ad.responsiveSearchAd?.descriptions), ...texts(ad.responsiveDisplayAd?.descriptions)]
          return {
            tenant_id: a.tenant_id,
            ad_id: String(ad.id),
            ad_group_id: String(r.adGroup?.id ?? ''),
            campaign_id: String(r.campaign?.id ?? ''),
            account_id: a.id,
            name: ad.name || heads[0] || null,
            type: ad.type ?? null,
            status: r.adGroupAd?.status ?? null,
            final_urls: ad.finalUrls ?? [],
            headlines: heads,
            descriptions: descs,
            updated_at: now,
          }
        }),
        'tenant_id,ad_id,ad_group_id',
      )
      patch.structure_at = now
    }
    // 2. history, 30 days per call
    let upto = a.synced_until
    const start = a.backfill_from ?? addDays(today, -90)
    while (!upto || upto < today) {
      if (Date.now() > deadline) {
        await admin.from('google_ad_accounts').update({ ...patch, synced_until: upto, lock_until: null }).eq('id', a.id)
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
      } else if (patch.synced_until === undefined) {
        await insights(addDays(today, -1), today)
      }
    }
    await admin.from('google_ad_accounts').update({ ...patch, last_sync_at: new Date().toISOString(), last_error: null, lock_until: null }).eq('id', a.id)
    return { done: true, rows }
  } catch (e) {
    const msg = (e as Error).message
    await admin.from('google_ad_accounts').update({ ...patch, last_error: msg, lock_until: null }).eq('id', a.id)
    if (e instanceof GoogleError && e.auth) await admin.from('integrations').update({ status: 'error', last_error: msg }).eq('id', a.integration_id)
    return { done: true, rows, error: msg }
  }
}

async function continueLater(tenantId: string | null) {
  const { data: secret } = await adminClient().rpc('workflow_cron_secret')
  fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/google-ads`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-cron-secret': String(secret ?? '') },
    body: JSON.stringify({ action: 'cron', tenant_id: tenantId }),
  }).catch(() => {})
  await new Promise((r) => setTimeout(r, 500))
}

async function runAll(admin: SupabaseClient, tenantId: string | null) {
  const deadline = Date.now() + BUDGET_MS
  let q = admin
    .from('google_ad_accounts')
    .select('id, tenant_id, integration_id, customer_id, timezone, backfill_from, synced_until, last_full_at, lock_until, structure_at, integrations!inner(is_enabled, status, config)')
    .eq('is_enabled', true)
    .eq('is_manager', false)
    .eq('integrations.is_enabled', true)
    .eq('integrations.status', 'connected')
  if (tenantId) q = q.eq('tenant_id', tenantId)
  const { data, error } = await q
  if (error) return { error: error.message }
  const tokens = new Map<string, string | null>()
  const out: Record<string, unknown> = {}
  let unfinished = false
  for (const row of (data ?? []) as unknown as (Account & { integrations: { config: Cfg } })[]) {
    if (Date.now() > deadline) {
      unfinished = true
      break
    }
    const cfg = row.integrations.config ?? {}
    if (!tokens.has(row.integration_id)) {
      try {
        tokens.set(row.integration_id, await accessToken(cfg))
      } catch (e) {
        tokens.set(row.integration_id, null)
        await admin.from('integrations').update({ status: 'error', last_error: (e as Error).message }).eq('id', row.integration_id)
      }
    }
    const token = tokens.get(row.integration_id)
    if (!token) continue
    const r = await pullAccount(admin, row, cfg, token, deadline)
    out[row.customer_id] = r
    if (!r.done) unfinished = true
  }
  if (unfinished) await continueLater(tenantId)
  return out
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  const admin = adminClient()
  const b = (await req.json().catch(() => ({}))) as Record<string, unknown>

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

  if (b.action === 'test') {
    // only people who can read the keys (System Connections)
    const { data: r } = await asCaller.from('integrations').select('id, tenant_id, config').eq('id', String(b.id ?? '')).eq('provider', 'google_ads').maybeSingle()
    if (!r) return json({ error: 'Connection not found.' }, 404)
    try {
      const res = await discover(admin, r as { id: string; tenant_id: string; config: Cfg })
      await admin.from('integrations').update({ status: 'connected', last_error: null }).eq('id', r.id)
      await continueLater(r.tenant_id)
      return json({ ok: true, ...res })
    } catch (e) {
      await admin.from('integrations').update({ status: 'error', last_error: (e as Error).message }).eq('id', r.id)
      return json({ error: (e as Error).message }, 400)
    }
  }

  if (b.action === 'sync') {
    const tenantId = String(b.tenant_id ?? '')
    const { data: may } = await asCaller.rpc('can_sync_google', { p_tenant: tenantId })
    if (!may) return json({ error: 'You need System Connections or funnel edit access.' }, 403)
    await admin.from('google_ad_accounts').update({ structure_at: null }).eq('tenant_id', tenantId)
    await continueLater(tenantId)
    return json({ ok: true })
  }
  return json({ error: 'Unknown action' }, 400)
})
