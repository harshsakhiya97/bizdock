// team-member: actions that need Supabase admin rights for the client panel's Team page.
//
//   create         add a person (new login with the default password, or an existing login)
//   reset_password set a member's password back to the workspace default
//   update_profile change a member's name / phone
//
// Every action is checked with the CALLER's own permissions first: the membership row is
// written (or touched) with the caller's token, so row security and the role-level rule
// decide. Only the login itself is created / changed with the service key.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

type BusinessPick = { business_id: string; branch_id: string | null }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)

  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const auth = req.headers.get('Authorization') ?? ''

  const asCaller = createClient(url, anon, { global: { headers: { Authorization: auth } } })
  const admin = createClient(url, service, { auth: { persistSession: false } })

  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return fail('Bad request')
  }
  const tenantId = String(body.tenant_id ?? '')
  if (!tenantId) return fail('Missing workspace')

  try {
    switch (body.action) {
      case 'create':
        return await create(asCaller, admin, tenantId, body)
      case 'reset_password':
        return await resetPassword(asCaller, admin, tenantId, String(body.member_id ?? ''))
      case 'update_profile':
        return await updateProfile(asCaller, admin, tenantId, body)
      default:
        return fail('Unknown action')
    }
  } catch (e) {
    return fail((e as Error).message ?? 'Something went wrong', 500)
  }
})

async function defaultPassword(asCaller: SupabaseClient, tenantId: string) {
  const { data } = await asCaller.from('tenant_settings').select('default_password').eq('tenant_id', tenantId).maybeSingle()
  return (data?.default_password as string | null) ?? null
}

/** Touch the member row with the caller's token: fails unless the caller may edit this person. */
async function assertCanManage(asCaller: SupabaseClient, tenantId: string, memberId: string) {
  const { data, error } = await asCaller
    .from('tenant_members')
    .update({ updated_at: new Date().toISOString() })
    .eq('id', memberId)
    .eq('tenant_id', tenantId)
    .select('user_id')
    .maybeSingle()
  if (error) throw new Error(error.message)
  if (!data) throw new Error('You can’t change this person.')
  return data.user_id as string
}

async function create(asCaller: SupabaseClient, admin: SupabaseClient, tenantId: string, b: Record<string, unknown>) {
  const email = String(b.email ?? '').trim().toLowerCase()
  const fullName = String(b.full_name ?? '').trim()
  const phone = String(b.phone ?? '').trim() || null
  const roleId = String(b.role_id ?? '')
  if (!fullName) return fail('Name is required.')
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return fail('Enter a valid email.')
  if (!roleId) return fail('Pick a role.')

  // the role must be visible to the caller in this workspace
  const { data: role } = await asCaller.from('roles').select('id').eq('id', roleId).eq('tenant_id', tenantId).maybeSingle()
  if (!role) return fail('That role is not in this workspace.')

  const { data: existing } = await admin.from('profiles').select('id').eq('email', email).maybeSingle()
  let userId = existing?.id as string | undefined
  let created = false

  if (userId) {
    const { data: already } = await admin
      .from('tenant_members')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('user_id', userId)
      .maybeSingle()
    if (already) return fail('This person is already in the team.')
  } else {
    const password = String(b.password ?? '') || (await defaultPassword(asCaller, tenantId))
    if (!password) return fail('Set the default password for new logins first.')
    if (password.length < 6) return fail('The password must be at least 6 characters.')
    const { data: made, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName, must_change_password: true },
    })
    if (error || !made.user) return fail(error?.message ?? 'Could not create the login.')
    userId = made.user.id
    created = true
    await admin.from('profiles').update({ full_name: fullName, phone }).eq('id', userId)
  }

  // membership is written with the CALLER's token: row security + the level rule decide
  const { data: member, error: memberError } = await asCaller
    .from('tenant_members')
    .insert({
      tenant_id: tenantId,
      user_id: userId,
      role_id: roleId,
      all_businesses: Boolean(b.all_businesses),
      reports_to: (b.reports_to as string) || null,
      department: String(b.department ?? '').trim() || null,
      designation: String(b.designation ?? '').trim() || null,
      joined_on: (b.joined_on as string) || null,
    })
    .select('id')
    .single()

  if (memberError || !member) {
    if (created) await admin.auth.admin.deleteUser(userId)
    return fail(memberError?.message ?? 'Could not add this person.')
  }

  const picks = (Array.isArray(b.businesses) ? b.businesses : []) as BusinessPick[]
  if (!b.all_businesses && picks.length) {
    const { error } = await asCaller.from('member_businesses').insert(
      picks.map((p) => ({ member_id: member.id, tenant_id: tenantId, business_id: p.business_id, branch_id: p.branch_id })),
    )
    if (error) return fail(`Added, but businesses were not saved: ${error.message}`)
  }

  return json({ member_id: member.id, new_login: created })
}

async function resetPassword(asCaller: SupabaseClient, admin: SupabaseClient, tenantId: string, memberId: string) {
  if (!memberId) return fail('Missing person')
  const password = await defaultPassword(asCaller, tenantId)
  if (!password) return fail('Set the default password for new logins first.')
  const userId = await assertCanManage(asCaller, tenantId, memberId)
  const { data: u } = await admin.auth.admin.getUserById(userId)
  const { error } = await admin.auth.admin.updateUserById(userId, {
    password,
    user_metadata: { ...(u.user?.user_metadata ?? {}), must_change_password: true },
  })
  if (error) return fail(error.message)
  return json({ ok: true })
}

async function updateProfile(asCaller: SupabaseClient, admin: SupabaseClient, tenantId: string, b: Record<string, unknown>) {
  const fullName = String(b.full_name ?? '').trim()
  if (!fullName) return fail('Name is required.')
  const userId = await assertCanManage(asCaller, tenantId, String(b.member_id ?? ''))
  const { error } = await admin
    .from('profiles')
    .update({ full_name: fullName, phone: String(b.phone ?? '').trim() || null })
    .eq('id', userId)
  if (error) return fail(error.message)
  return json({ ok: true })
}
