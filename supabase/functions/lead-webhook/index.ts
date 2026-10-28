// lead-webhook: public endpoint a landing page posts its form to.
//
//   POST https://<project>.supabase.co/functions/v1/lead-webhook?key=<landing page webhook key>
//
// Accepts JSON, application/x-www-form-urlencoded or multipart form data. UTM values may come in
// the body or the query string. Required: name, email, phone (+ the page's own required fields).
// Same phone in the same funnel updates that lead; otherwise a new lead is added to the first stage.
// A webhook can instead update a lead, book a meeting for it or log a payment (see webhook_submit);
// nested JSON (and JSON sent as text) becomes dotted paths (a.b.0.c) to pick from when mapping; a list of
// values stays one field ("a, b"), which can be mapped to Tags.
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

const MAX_FIELDS = 400
const MAX_LEN = 2000

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ ok: false, error: 'Use POST' }, 405)

  const url = new URL(req.url)
  const data: Record<string, string> = {}
  const seg = (k: string) => k.trim().replace(/\[\]$/, '').toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60)
  // one field per value; a field inside an object is its path: appointment.bookings.0.customer.phone
  const put = (k: string, v: unknown, depth = 0, prefix = '') => {
    const s1 = seg(k)
    if (!s1) return
    const key = prefix ? `${prefix}.${s1}` : s1
    // JSON sent as text ({"firstName":"Rahul"…}) is opened like any other object
    if (typeof v === 'string' && /^\s*[[{]/.test(v) && depth < 6) {
      try {
        const parsed = JSON.parse(v)
        if (parsed && typeof parsed === 'object') v = parsed
      } catch {
        /* plain text */
      }
    }
    // a list of plain values (checkboxes: ["LinkedIn", "Podcast"]) stays one field: "LinkedIn, Podcast"
    if (Array.isArray(v) && v.every((x) => x == null || typeof x !== 'object')) {
      v = v.filter((x) => x != null && String(x).trim() !== '').map((x) => String(x).trim()).join(', ')
    }
    // objects and lists of objects: each inner field on its own path
    if (v && typeof v === 'object') {
      if (depth >= 6) return
      for (const [k2, v2] of Object.entries(v as Record<string, unknown>)) put(k2, v2, depth + 1, key)
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
      // checkboxes send the same name several times: keep them all
      for (const k of new Set(form.keys())) {
        const all = form.getAll(k).filter((v): v is string => typeof v === 'string')
        put(k, all.length > 1 ? all : all[0] ?? '')
      }
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
