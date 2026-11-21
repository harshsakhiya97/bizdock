// call-transcribe: the transcript of every Callyzer call recording (our copy in bucket call-recordings), by Gemini —
// the workspace's key (System Connections → Gemini AI), counted in ai_usage (feature call_transcript), stopped by its
// monthly ₹ limit. Newest calls first, then the backlog.
//
//   POST { action: 'cron' } + header x-cron-secret (public.workflow_cron_secret())
//     → for ~45 s: claims 5 calls at a time (call_transcript_claim) and transcribes them side by side.
//       A failure is tried again on later runs (3 tries); Gemini's rate limit just ends the run (no try counted).
//   POST { action: 'redo', id } (from the app, logged in) → that call again, now → { transcript }
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const RUN_MS = 45_000
const BATCH = 5

const PROMPT = `This is a recorded phone call in India between a business's team member and a customer or lead (it may be in Hindi, English or Hinglish).
Return JSON with "transcript": the whole conversation, one line per turn, "Team: …" or "Customer: …" (use a person's name instead when it is said clearly). Write Hindi in Roman script (Hinglish), as spoken. If nobody speaks (ringing, voicemail, silence), write a short note in brackets, e.g. "(no conversation: voicemail)".`

type Gem = { id: string; key: string; model: string; priceIn: number; priceOut: number; limit: number } | { error: string }
class RateLimited extends Error {}

/** the workspace's Gemini connection (cached for the run) */
async function geminiFor(admin: SupabaseClient, cache: Map<string, Gem>, tenantId: string): Promise<Gem> {
  const hit = cache.get(tenantId)
  if (hit) return hit
  const { data: conn } = await admin.from('integrations').select('id, config').eq('tenant_id', tenantId).eq('provider', 'gemini').eq('is_enabled', true).order('updated_at', { ascending: false }).limit(1).maybeSingle()
  const cfg = (conn?.config ?? {}) as Record<string, string>
  const key = String(cfg.api_key ?? '').trim()
  const g: Gem = !conn || !key
    ? { error: 'Gemini AI is not connected.' }
    : { id: String(conn.id), key, model: String(cfg.model || 'gemini-flash-latest'), priceIn: Number(cfg.price_in || 0), priceOut: Number(cfg.price_out || 0), limit: Number(cfg.monthly_limit || 0) }
  if (!('error' in g) && g.limit > 0) {
    const ist = new Date(Date.now() + 330 * 60_000)
    const start = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), 1) - 330 * 60_000).toISOString()
    const { data } = await admin.from('ai_usage').select('input_tokens, output_tokens').eq('tenant_id', tenantId).gte('created_at', start).limit(200000)
    const spent = ((data ?? []) as { input_tokens: number; output_tokens: number }[]).reduce((t, r) => t + Number(r.input_tokens) * g.priceIn + Number(r.output_tokens) * g.priceOut, 0) / 1e6
    if (spent >= g.limit) {
      const out = { error: `This month’s AI limit (₹${g.limit}) is used up.` }
      cache.set(tenantId, out)
      return out
    }
  }
  cache.set(tenantId, g)
  return g
}

const mimeOf = (p: string) => ({ mp3: 'audio/mpeg', m4a: 'audio/mp4', wav: 'audio/wav', ogg: 'audio/ogg', aac: 'audio/aac', amr: 'audio/amr', '3gp': 'audio/3gpp' })[p.split('.').pop()?.toLowerCase() ?? ''] ?? 'audio/mpeg'

function b64(bytes: Uint8Array) {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

/** one call: its recording → Gemini → transcript saved */
async function transcribe(admin: SupabaseClient, cache: Map<string, Gem>, id: string): Promise<string> {
  const { data: c } = await admin.from('calls').select('id, tenant_id, recording_path, transcript_tries').eq('id', id).maybeSingle()
  if (!c?.recording_path) throw new Error('No recording copied yet.')
  const g = await geminiFor(admin, cache, c.tenant_id)
  if ('error' in g) {
    await admin.from('calls').update({ transcript_status: 'waiting', transcript_error: g.error, transcript_lease: null }).eq('id', id)
    throw new Error(g.error)
  }
  try {
    const { data: file, error } = await admin.storage.from('call-recordings').download(c.recording_path)
    if (error || !file) throw new Error(`reading the recording: ${error?.message ?? 'empty'}`)
    const bytes = new Uint8Array(await file.arrayBuffer())
    if (bytes.byteLength > 19_000_000) throw new Error('The recording is too long for one go.')
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(g.model)}:generateContent`, {
      method: 'POST',
      headers: { 'x-goog-api-key': g.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ inline_data: { mime_type: mimeOf(c.recording_path), data: b64(bytes) } }, { text: PROMPT }] }],
        generationConfig: { temperature: 0.2, maxOutputTokens: 16000, responseMimeType: 'application/json', responseSchema: { type: 'OBJECT', properties: { transcript: { type: 'STRING' } }, required: ['transcript'] } },
      }),
    })
    const d = await r.json().catch(() => ({}))
    if (r.status === 429) throw new RateLimited(d?.error?.message ?? 'Gemini rate limit')
    if (!r.ok) throw new Error(d?.error?.message ? `Gemini: ${d.error.message}` : `Gemini error ${r.status}`)
    const text = ((d?.candidates?.[0]?.content?.parts ?? []) as { text?: string; thought?: boolean }[]).filter((p) => !p.thought).map((p) => p.text ?? '').join('')
    let transcript = ''
    try {
      transcript = String(JSON.parse(text).transcript ?? '').trim()
    } catch {
      throw new Error(`Gemini gave no usable answer (${d?.candidates?.[0]?.finishReason ?? 'empty'})`)
    }
    const u = d?.usageMetadata ?? {}
    await admin.from('ai_usage').insert({
      tenant_id: c.tenant_id,
      integration_id: g.id,
      model: g.model,
      feature: 'call_transcript',
      input_tokens: Number(u.promptTokenCount ?? 0),
      output_tokens: Number(u.candidatesTokenCount ?? 0) + Number(u.thoughtsTokenCount ?? 0),
      member_id: null,
    })
    await admin.from('calls').update({ transcript: transcript || '(no conversation)', transcript_status: 'done', transcript_error: null, transcript_at: new Date().toISOString(), transcript_lease: null }).eq('id', id)
    return transcript
  } catch (e) {
    if (e instanceof RateLimited) {
      await admin.from('calls').update({ transcript_lease: null }).eq('id', id)
      throw e
    }
    const tries = Number(c.transcript_tries) + 1
    await admin.from('calls').update({ transcript_tries: tries, transcript_error: (e as Error).message.slice(0, 300), transcript_status: tries >= 3 ? 'error' : 'waiting', transcript_lease: null }).eq('id', id)
    throw e
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const b = await req.json().catch(() => ({}))
  const cache = new Map<string, Gem>()

  if (b.action === 'cron') {
    const { data: secret } = await admin.rpc('workflow_cron_secret')
    if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'Not allowed' }, 401)
    const started = Date.now()
    let done = 0
    let failed = 0
    let stop = ''
    while (Date.now() - started < RUN_MS && !stop) {
      const { data: ids } = await admin.rpc('call_transcript_claim', { p_limit: BATCH })
      const list = ((ids ?? []) as unknown[]).map((x) => String(typeof x === 'object' && x ? Object.values(x)[0] : x))
      if (!list.length) break
      const res = await Promise.allSettled(list.map((id) => transcribe(admin, cache, id)))
      for (const r of res) {
        if (r.status === 'fulfilled') done++
        else {
          failed++
          if (r.reason instanceof RateLimited) stop = 'Gemini rate limit'
          else if (/AI limit|not connected/.test(String(r.reason?.message))) stop = String(r.reason.message)
        }
      }
    }
    return json({ ok: true, done, failed, stop: stop || null })
  }

  if (b.action === 'redo') {
    const auth = req.headers.get('Authorization') ?? ''
    const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
    const { data: me } = await asCaller.auth.getUser()
    if (!me.user) return json({ error: 'Please log in again.' }, 401)
    // the caller must be able to see the call
    const { data: seen } = await asCaller.from('calls').select('id').eq('id', String(b.id)).maybeSingle()
    if (!seen) return json({ error: 'Call not found.' }, 404)
    await admin.from('calls').update({ transcript_tries: 0 }).eq('id', String(b.id))
    try {
      const transcript = await transcribe(admin, cache, String(b.id))
      return json({ ok: true, transcript })
    } catch (e) {
      return json({ error: e instanceof RateLimited ? 'Gemini is busy (rate limit). Try again in a minute.' : (e as Error).message })
    }
  }
  return json({ error: 'Unknown action' }, 400)
})
