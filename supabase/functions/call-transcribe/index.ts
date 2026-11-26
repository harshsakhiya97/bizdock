// call-transcribe: the transcript of every Callyzer call recording (our copy in bucket call-recordings), by Gemini, then
// Claude (System Connections → Claude API, if connected) checks who said what — Gemini flash-lite flips the speakers —
// the workspace's key (System Connections → Gemini AI), counted in ai_usage (feature call_transcript), stopped by its
// monthly ₹ limit. Newest calls first, then the backlog.
//
//   POST { action: 'cron' } + header x-cron-secret (public.workflow_cron_secret()), every minute while needed, ~45 s:
//     1. new calls (last 3 days) with no transcript → Gemini, up to 15 a run (call_transcript_claim 'auto')
//     2. each workspace with Sync transcripts on (transcript_syncs.active, Callyzer → History logs):
//        - transcripts whose Team / Customer labels Claude hasn't checked yet → Claude fixes them ('relabel')
//        - every call with no transcript → Gemini ('write')
//        and the sync ends itself when nothing is left (or only what its engines can't do).
//     A failure is tried again on later runs (3 tries); a rate limit just ends that part of the run (no try counted).
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
Return JSON with "transcript": the whole conversation, one turn per line (separate lines with a line break), each line starting with exactly "Team:" or "Customer:" (when a person's name is said clearly, add it in brackets: "Team (Alka):", "Customer (Rahul):"). Write Hindi in Roman script (Hinglish), as spoken. If nobody speaks (ringing, voicemail, silence), write a short note in brackets, e.g. "(no conversation: voicemail)".`

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
    const { data } = await admin.from('ai_usage').select('input_tokens, output_tokens').eq('tenant_id', tenantId).not('model', 'ilike', 'claude%').gte('created_at', start).limit(200000)
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
async function transcribe(admin: SupabaseClient, cache: Map<string, Gem>, id: string, cla: Map<string, Cla> = new Map()): Promise<string> {
  const { data: c } = await admin.from('calls').select('id, tenant_id, recording_path, transcript_tries, direction, emp_name, client_name, lead_id, phone').eq('id', id).maybeSingle()
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
        contents: [{ role: 'user', parts: [{ inline_data: { mime_type: mimeOf(c.recording_path), data: b64(bytes) } }, { text: PROMPT + (await who(admin, c)) }] }],
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
    // Claude checks who said what (if connected); if it can't, Gemini's labels stay and Sync transcripts checks it later
    let checked = false
    if (/^(Team|Customer)\b/m.test(transcript)) {
      const cl = await claudeFor(admin, cla, c.tenant_id)
      if (!('error' in cl)) {
        try {
          transcript = await fixLabels(admin, cl, c, transcript)
          checked = true
        } catch {
          /* Gemini's labels stay */
        }
      }
    }
    await admin
      .from('calls')
      .update({ transcript: transcript || '(no conversation)', labels_checked: checked, transcript_status: 'done', transcript_error: null, transcript_at: new Date().toISOString(), transcript_lease: null, transcript_redo: false })
      .eq('id', id)
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


/** who is who on the call (so the team member isn't written as the customer) */
async function who(admin: SupabaseClient, c: { tenant_id: string; direction: string | null; emp_name: string | null; client_name: string | null; lead_id: string | null; phone: string | null }) {
  let lead = ''
  if (c.lead_id) {
    const { data } = await admin.from('leads').select('first_name, last_name').eq('id', c.lead_id).maybeSingle()
    lead = [data?.first_name, data?.last_name].filter(Boolean).join(' ')
  } else if (c.phone) {
    const { data } = await admin.from('leads').select('first_name, last_name, phone').eq('tenant_id', c.tenant_id).ilike('phone', `%${c.phone.slice(-10)}`).limit(1).maybeSingle()
    lead = [data?.first_name, data?.last_name].filter(Boolean).join(' ')
  }
  const team = (c.emp_name ?? '').trim()
  const customer = (lead || c.client_name || '').trim()
  const dir = c.direction === 'outgoing' ? 'The team member called the customer (outgoing call): the first "Hello" is usually the customer picking up, and the person who introduces themself and the business ("main … bol rahi hu", "… se baat kar rahe hain") is the team member.' : c.direction === 'incoming' ? 'The customer called the business (incoming call): the team member usually answers first.' : ''
  return `

WHO IS WHO (use this to label the speakers correctly):
- Team = ${team ? `the business's team member${team ? `, ${team}` : ''}` : 'the business’s team member'}: the one who speaks for the business, introduces themself or the business, explains the offer, books meetings, follows up.
- Customer = ${customer ? `the lead, ${customer}` : 'the lead'}: the one being called about their enquiry or interest.
${dir}
If someone says "main ${team || 'X'} bol rahi/raha hu" they are Team.`
}

// ---------------- Claude: fix the speaker labels of an old transcript ----------------
type Cla = { id: string; key: string; model: string } | { error: string }
async function claudeFor(admin: SupabaseClient, cache: Map<string, Cla>, tenantId: string): Promise<Cla> {
  const hit = cache.get(tenantId)
  if (hit) return hit
  const { data: conn } = await admin.from('integrations').select('id, config').eq('tenant_id', tenantId).eq('provider', 'claude').eq('is_enabled', true).order('updated_at', { ascending: false }).limit(1).maybeSingle()
  const cfg = (conn?.config ?? {}) as Record<string, string>
  const key = String(cfg.api_key ?? '').trim()
  const c: Cla = !conn || !key ? { error: 'Claude API is not connected.' } : { id: String(conn.id), key, model: String(cfg.model || 'claude-sonnet-4-5') }
  cache.set(tenantId, c)
  return c
}

const RELABEL = `Below is the transcript of a recorded phone call in India between a business's team member and a customer or lead (Hindi, English or Hinglish). It was written by a speech-to-text model that sometimes put the speakers the wrong way round, or ran several turns together on one line.
Fix only the speaker labels and the line breaks:
- One turn per line. Each line starts with exactly "Team:" or "Customer:"; when the person's name is known, add it in brackets: "Team (Alka):", "Customer (Rahul):".
- Decide who is who from the conversation and the facts below (who introduces themself and the business, who explains the offer or books the meeting = Team).
- Every line gets a speaker, also short sounds like "hm", "haa", "ok", "ji": they belong to whoever is listening (usually the other person than the line before).
- Keep every word exactly as it is: don't translate, correct, shorten or add anything. Notes in brackets like [noise] stay where they are.
- Reply with the fixed transcript only, nothing before or after it.`

type CallWho = { id: string; tenant_id: string; direction: string | null; emp_name: string | null; client_name: string | null; lead_id: string | null; phone: string | null }

/** a transcript → Claude → the same words with the right Team / Customer labels (usage counted) */
async function fixLabels(admin: SupabaseClient, g: { id: string; key: string; model: string }, c: CallWho, text: string): Promise<string> {
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': g.key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({
      model: g.model,
      max_tokens: 8000,
      temperature: 0,
      system: RELABEL,
      messages: [{ role: 'user', content: `${(await who(admin, c)).trim()}\n\nTRANSCRIPT:\n${text.slice(0, 60000)}` }],
    }),
  })
  const d = await r.json().catch(() => ({}))
  if (r.status === 429 || r.status === 529) throw new RateLimited(d?.error?.message ?? 'Claude is busy')
  if (!r.ok) throw new Error(d?.error?.message ? `Claude: ${d.error.message}` : `Claude error ${r.status}`)
  const out = ((d?.content ?? []) as { type: string; text?: string }[]).filter((x) => x.type === 'text').map((x) => x.text ?? '').join('').trim()
  await admin.from('ai_usage').insert({
    tenant_id: c.tenant_id,
    integration_id: g.id,
    model: g.model,
    feature: 'call_relabel',
    input_tokens: Number(d?.usage?.input_tokens ?? 0),
    output_tokens: Number(d?.usage?.output_tokens ?? 0),
    member_id: null,
  })
  // the same conversation back: labelled lines, and not much shorter (no words dropped)
  if (!out || !/^(Team|Customer)\b/m.test(out) || out.length < text.length * 0.8) throw new Error('Claude gave no usable transcript.')
  return out
}

/** one saved transcript → Claude checks its labels (Sync transcripts) */
async function relabel(admin: SupabaseClient, cache: Map<string, Cla>, id: string) {
  const { data: c } = await admin.from('calls').select('id, tenant_id, transcript, transcript_tries, direction, emp_name, client_name, lead_id, phone').eq('id', id).maybeSingle()
  if (!c?.transcript) throw new Error('No transcript to fix.')
  const g = await claudeFor(admin, cache, c.tenant_id)
  if ('error' in g) {
    await admin.from('calls').update({ transcript_lease: null }).eq('id', id)
    throw new Error(g.error)
  }
  try {
    const text = await fixLabels(admin, g, c, String(c.transcript))
    await admin.from('calls').update({ transcript: text, labels_checked: true, transcript_redo: false, transcript_error: null, transcript_lease: null }).eq('id', id)
  } catch (e) {
    if (e instanceof RateLimited) {
      await admin.from('calls').update({ transcript_lease: null }).eq('id', id)
      throw e
    }
    // the transcript stays as it is; after 3 tries it's left alone
    await admin.from('calls').update({ transcript_tries: Number(c.transcript_tries) + 1, transcript_error: (e as Error).message.slice(0, 300), transcript_lease: null }).eq('id', id)
    throw e
  }
}

/** claim and work through calls of one kind until the time, the count or a stop */
async function work(admin: SupabaseClient, mode: 'auto' | 'write' | 'relabel', tenant: string | null, max: number, until: number, fn: (id: string) => Promise<unknown>) {
  let done = 0
  let failed = 0
  let stop = ''
  while (Date.now() < until && !stop && done + failed < max) {
    const { data: ids } = await admin.rpc('call_transcript_claim', { p_limit: Math.min(BATCH, max - done - failed), p_mode: mode, p_tenant: tenant })
    const list = ((ids ?? []) as unknown[]).map((x) => String(typeof x === 'object' && x ? Object.values(x)[0] : x))
    if (!list.length) break
    const res = await Promise.allSettled(list.map((id) => fn(id)))
    for (const r of res) {
      if (r.status === 'fulfilled') done++
      else {
        failed++
        if (r.reason instanceof RateLimited) stop = 'rate limit'
        else if (/AI limit|not connected/.test(String(r.reason?.message))) stop = String(r.reason.message)
      }
    }
  }
  return { done, failed, stop: stop || null }
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
    const until = Date.now() + RUN_MS
    const cla = new Map<string, Cla>()
    // 1. new calls: their transcript as they come in
    const auto = await work(admin, 'auto', null, 15, until, (id) => transcribe(admin, cache, id, cla))
    // 2. Sync transcripts
    const syncs: Record<string, unknown> = {}
    const { data: on } = await admin.from('transcript_syncs').select('tenant_id').eq('active', true)
    for (const s of (on ?? []) as { tenant_id: string }[]) {
      const t = s.tenant_id
      const cl = await claudeFor(admin, cla, t)
      const claudeOn = !('error' in cl)
      const fix = claudeOn ? await work(admin, 'relabel', t, 40, until, (id) => relabel(admin, cla, id)) : { done: 0, failed: 0, stop: 'Claude API not connected' }
      const write = await work(admin, 'write', t, 15, until, (id) => transcribe(admin, cache, id, cla))
      syncs[t] = { fix, write }
      // finished: nothing left that its engines can do
      const { count: relabelLeft } = await admin
        .from('calls')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', t)
        .eq('source', 'callyzer')
        .eq('transcript_status', 'done')
        .eq('labels_checked', false)
        .or('transcript.like.Team%,transcript.like.Customer%')
        .lt('transcript_tries', 3)
        .not('recording_path', 'is', null)
        .gte('duration_sec', 5)
      const { count: writeLeft } = await admin
        .from('calls')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', t)
        .eq('source', 'callyzer')
        .or('transcript_status.is.null,transcript_status.eq.waiting')
        .lt('transcript_tries', 3)
        .not('recording_path', 'is', null)
        .gte('duration_sec', 5)
      if ((!claudeOn || !relabelLeft) && !writeLeft) {
        await admin.from('transcript_syncs').update({ active: false, finished_at: new Date().toISOString(), note: claudeOn || !relabelLeft ? 'Done' : 'Done (Claude API not connected: speaker labels not checked)' }).eq('tenant_id', t)
      }
    }
    return json({ ok: true, auto, syncs })
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
