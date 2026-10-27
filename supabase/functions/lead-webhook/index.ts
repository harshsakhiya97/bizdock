// lead-webhook: public endpoint a landing page posts its form to.
//
//   POST https://<project>.supabase.co/functions/v1/lead-webhook?key=<landing page webhook key>
//
// Accepts JSON, application/x-www-form-urlencoded or multipart form data. UTM values may come in
// the body or the query string. Required: name, email, phone (+ the page's own required fields).
// Same phone in the same funnel updates that lead; otherwise a new lead is added to the first stage.
// A webhook can instead update a lead, book a meeting for it or log a payment (see webhook_submit);
// nested JSON is flattened (a.b.c → a_b_c) so its fields can be mapped.
// For a plain HTML form, add a hidden "_redirect" field to send the visitor to a thank-you page.
// No login: the key is the secret. Everything else is checked by public.webhook_submit.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

const MAX_FIELDS = 80
const MAX_LEN = 2000

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ ok: false, error: 'Use POST' }, 405)

  const url = new URL(req.url)
  const data: Record<string, string> = {}
  const put = (k: string, v: unknown, depth = 0) => {
    const key = k.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60)
    if (!key) return
    // nested JSON (booking tools, payment gateways): { appointment: { bookingStart } } → appointment_bookingstart
    if (v && typeof v === 'object') {
      if (depth >= 5) return
      for (const [k2, v2] of Object.entries(v as Record<string, unknown>)) put(`${key}_${k2}`, v2, depth + 1)
      return
    }
    if (Object.keys(data).length >= MAX_FIELDS && !(key in data)) return
    data[key] = String(v ?? '').slice(0, MAX_LEN)
  }

  // query string first (utm_* on the page URL), body wins
  url.searchParams.forEach((v, k) => put(k, v))
  const type = req.headers.get('content-type') ?? ''
  let isForm = false
  try {
    if (type.includes('application/json')) {
      const body = await req.json()
      if (body && typeof body === 'object') for (const [k, v] of Object.entries(body)) put(k, v)
    } else {
      const form = await req.formData()
      isForm = true
      form.forEach((v, k) => typeof v === 'string' && put(k, v))
    }
  } catch {
    return json({ ok: false, error: 'Could not read the form data.' }, 400)
  }

  const key = data.key ?? ''
  const redirect = data._redirect || data.redirect || ''
  if (!/^[a-f0-9]{32}$/.test(key)) return json({ ok: false, error: 'Missing or invalid webhook key.' }, 401)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  })
  const { data: res, error } = await admin.rpc('webhook_submit', { p_key: key, p_data: data })
  if (error) {
    const status = error.message.includes('webhook key') ? 401 : 422
    return json({ ok: false, error: error.message }, status)
  }

  if (isForm && /^https?:\/\//.test(redirect)) {
    return new Response(null, { status: 303, headers: { ...cors, Location: redirect } })
  }
  return json({ ok: true, ...(res as Record<string, unknown>) })
})
