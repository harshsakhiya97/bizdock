// recording-copy: our own copy of Callyzer call recordings (bucket call-recordings, private).
//
//   POST { action: 'cron' } + header x-cron-secret (public.workflow_cron_secret())
//     → copies waiting recordings, newest first, 5 at a time, for ~45 s: downloads Callyzer's mp3, uploads it to
//       <tenant>/<yyyy>/<mm>/<call id>.mp3, saves recording_path on callyzer_team_calls and the matching calls row.
//       A failed copy is tried again on later runs (5 tries); its error is kept in copy_error.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const RUN_MS = 45_000
const BATCH = 5

type Rec = { tenant_id: string; external_id: string; started_at: string; recording_url: string; copy_tries: number }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: secret } = await admin.rpc('workflow_cron_secret')
  if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'Not allowed' }, 401)

  const started = Date.now()
  let copied = 0
  let failed = 0
  const seen = new Set<string>()
  while (Date.now() - started < RUN_MS) {
    const { data, error } = await admin
      .from('callyzer_team_calls')
      .select('tenant_id, external_id, started_at, recording_url, copy_tries')
      .not('recording_url', 'is', null)
      .is('recording_path', null)
      .lt('copy_tries', 5)
      .order('started_at', { ascending: false })
      .limit(BATCH * 4)
    if (error) return json({ error: error.message }, 500)
    const list = ((data ?? []) as Rec[]).filter((r) => !seen.has(`${r.tenant_id}|${r.external_id}`)).slice(0, BATCH)
    if (!list.length) break
    const results = await Promise.all(list.map((r) => copyOne(admin, r)))
    for (const [i, ok] of results.entries()) {
      seen.add(`${list[i].tenant_id}|${list[i].external_id}`)
      if (ok) copied++
      else failed++
    }
  }
  return json({ ok: true, copied, failed })
})

async function copyOne(admin: SupabaseClient, r: Rec): Promise<boolean> {
  const d = new Date(r.started_at)
  const ext = (r.recording_url.split('?')[0].match(/\.(mp3|m4a|amr|wav|ogg|aac|3gp)$/i)?.[1] ?? 'mp3').toLowerCase()
  const safeId = r.external_id.replace(/[^a-zA-Z0-9_-]/g, '_')
  const path = `${r.tenant_id}/${d.getUTCFullYear()}/${String(d.getUTCMonth() + 1).padStart(2, '0')}/${safeId}.${ext}`
  try {
    const res = await fetch(r.recording_url)
    if (!res.ok) throw new Error(`Callyzer answered ${res.status}`)
    const body = new Uint8Array(await res.arrayBuffer())
    if (body.byteLength < 100) throw new Error('Empty recording')
    const type = ext === 'mp3' ? 'audio/mpeg' : ext === 'm4a' ? 'audio/mp4' : ext === 'wav' ? 'audio/wav' : ext === 'ogg' ? 'audio/ogg' : ext === 'aac' ? 'audio/aac' : 'application/octet-stream'
    const { error } = await admin.storage.from('call-recordings').upload(path, body, { contentType: type, upsert: true })
    if (error) throw new Error(error.message)
    await admin.from('callyzer_team_calls').update({ recording_path: path, copy_error: null }).eq('tenant_id', r.tenant_id).eq('external_id', r.external_id)
    await admin.from('calls').update({ recording_path: path }).eq('tenant_id', r.tenant_id).eq('source', 'callyzer').eq('external_id', r.external_id)
    return true
  } catch (e) {
    await admin
      .from('callyzer_team_calls')
      .update({ copy_tries: r.copy_tries + 1, copy_error: (e as Error).message.slice(0, 300) })
      .eq('tenant_id', r.tenant_id)
      .eq('external_id', r.external_id)
    return false
  }
}
