// sheets-sync: Google Sheet links of funnels (WhatsApp tab) → leads.
//
//   POST { action: 'cron' }  + header x-cron-secret   → syncs every active sheet (run every minute by pg_cron;
//                                                        the secret lives in the vault: public.sheets_cron_secret())
//   POST { action: 'sync', sheet_id }  (logged-in user) → syncs one sheet now (also reads its columns)
//   POST { action: 'info' }            (logged-in user) → { email } of the Google service account to share sheets with
//
// Sheets are read with a Google service account (secret GOOGLE_SERVICE_ACCOUNT = its JSON key file).
// The sheet must be shared with that account's email (Viewer). Row 1 = column names.
// New rows (after the ones already handled) are passed to public.sheet_ingest() with the service role.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

const MAX_ROWS = 500 // per sheet per run

type Sheet = {
  id: string
  spreadsheet_id: string
  gid: string | null
  import_existing: boolean
  synced_rows: number | null
  is_active: boolean
}

// ---------- Google auth (service account → access token) ----------
type Account = { client_email: string; private_key: string }
function account(): Account | null {
  try {
    const a = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT') ?? '')
    return a.client_email && a.private_key ? a : null
  } catch {
    return null
  }
}
const b64url = (b: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof b === 'string' ? new TextEncoder().encode(b) : new Uint8Array(b)
  let s = ''
  for (const x of bytes) s += String.fromCharCode(x)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
let cached: { token: string; until: number } | null = null
async function googleToken(acc: Account) {
  if (cached && cached.until > Date.now() + 60_000) return cached.token
  const now = Math.floor(Date.now() / 1000)
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const claim = b64url(
    JSON.stringify({ iss: acc.client_email, scope: 'https://www.googleapis.com/auth/spreadsheets.readonly', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 }),
  )
  const pem = acc.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0))
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${claim}`))
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claim}.${b64url(sig)}` }),
  })
  const out = await res.json()
  if (!res.ok || !out.access_token) throw new Error('Google sign-in failed. Check the service account key.')
  cached = { token: out.access_token, until: Date.now() + (out.expires_in ?? 3600) * 1000 }
  return cached.token
}

// ---------- read a sheet ----------
async function readRows(token: string, s: Sheet): Promise<string[][]> {
  const g = (url: string) => fetch(url, { headers: { Authorization: `Bearer ${token}` } })
  const meta = await g(`https://sheets.googleapis.com/v4/spreadsheets/${s.spreadsheet_id}?fields=sheets.properties(sheetId,title)`)
  if (meta.status === 403 || meta.status === 404)
    throw new Error('Can’t open the sheet. Share it (Viewer) with the service account email shown on the WhatsApp tab.')
  if (!meta.ok) throw new Error(`Google Sheets error (${meta.status}).`)
  const tabs = ((await meta.json()).sheets ?? []).map((x: { properties: { sheetId: number; title: string } }) => x.properties)
  const tab = tabs.find((t: { sheetId: number }) => s.gid != null && String(t.sheetId) === s.gid) ?? tabs[0]
  if (!tab) throw new Error('The sheet has no tabs.')
  const range = encodeURIComponent(`'${tab.title.replace(/'/g, "''")}'`)
  const res = await g(`https://sheets.googleapis.com/v4/spreadsheets/${s.spreadsheet_id}/values/${range}?majorDimension=ROWS&valueRenderOption=FORMATTED_VALUE`)
  if (!res.ok) throw new Error(`Google Sheets error (${res.status}).`)
  return ((await res.json()).values ?? []) as string[][]
}

// ---------- sync one sheet ----------
async function syncSheet(admin: ReturnType<typeof createClient>, token: string, s: Sheet) {
  try {
    const rows = await readRows(token, s)
    const headers = (rows[0] ?? []).map((h, i) => String(h ?? '').trim() || `Column ${i + 1}`)
    const data = rows.slice(1).map((r) => Object.fromEntries(headers.map((h, i) => [h, String(r[i] ?? '').trim()])))
    const sample = data.find((r) => Object.values(r).some(Boolean)) ?? null
    await admin.from('funnel_sheets').update({ headers, sample }).eq('id', s.id)

    let done = s.synced_rows
    if (done == null) {
      // first sync: start after the existing rows unless asked to import them
      done = s.import_existing ? 0 : data.length
      await admin.from('funnel_sheets').update({ synced_rows: done, last_synced_at: new Date().toISOString(), last_error: null }).eq('id', s.id)
    }
    if (data.length < done) {
      // rows were deleted from the sheet: carry on from the new end
      await admin.from('funnel_sheets').update({ synced_rows: data.length, last_synced_at: new Date().toISOString() }).eq('id', s.id)
      return { added: 0, updated: 0, skipped: 0 }
    }
    const fresh = data.slice(done, done + MAX_ROWS)
    if (!fresh.length) {
      await admin.from('funnel_sheets').update({ last_synced_at: new Date().toISOString(), last_error: null }).eq('id', s.id)
      return { added: 0, updated: 0, skipped: 0 }
    }
    const { data: out, error } = await admin.rpc('sheet_ingest', { p_sheet: s.id, p_rows: fresh, p_first: done + 2 })
    if (error) throw new Error(error.message)
    return out
  } catch (e) {
    const message = (e as Error).message
    await admin.from('funnel_sheets').update({ last_error: message, last_synced_at: new Date().toISOString() }).eq('id', s.id)
    return { error: message }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    body = {}
  }
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const acc = account()
  const COLS = 'id, spreadsheet_id, gid, import_existing, synced_rows, is_active'

  // every minute from pg_cron
  if (body.action === 'cron') {
    const { data: secret } = await admin.rpc('sheets_cron_secret')
    if (!secret || req.headers.get('x-cron-secret') !== secret) return fail('Not allowed', 401)
    if (!acc) return json({ skipped: 'GOOGLE_SERVICE_ACCOUNT not set' })
    const { data: sheets } = await admin.from('funnel_sheets').select(COLS).eq('is_active', true)
    if (!sheets?.length) return json({ synced: 0 })
    const token = await googleToken(acc)
    const results = []
    for (const s of sheets as Sheet[]) results.push(await syncSheet(admin, token, s))
    return json({ synced: sheets.length, results })
  }

  // a logged-in person (row security decides which sheets they can see)
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)

  if (body.action === 'info') return json({ email: acc?.client_email ?? null })

  if (body.action === 'sync') {
    const { data: s } = await asCaller.from('funnel_sheets').select(COLS).eq('id', String(body.sheet_id ?? '')).maybeSingle()
    if (!s) return fail('Sheet not found.', 404)
    if (!acc) return fail('The Google service account isn’t set up yet.')
    const token = await googleToken(acc)
    const out = await syncSheet(admin, token, s as Sheet)
    if (out && 'error' in out) return fail(String(out.error))
    return json(out)
  }
  return fail('Unknown action')
})
