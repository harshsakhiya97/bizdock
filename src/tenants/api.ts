import { supabase } from '@/lib/supabase'
import type { DomainRow, TenantListRow, TenantRow } from './types'

const BUCKET = 'tenant-branding'

function fail(error: { message: string } | null): asserts error is null {
  if (error) throw new Error(friendly(error.message))
}

/** Turn common database errors into plain messages. */
function friendly(message: string) {
  if (message.includes('tenant_domains_domain_key')) return 'That domain is already used by a client.'
  if (message.includes('tenant_domains_one_primary')) return 'This client already has a primary domain.'
  if (message.includes('tenant_domains_domain_check')) return 'Domains must be lowercase.'
  if (message.includes('tenants_registry_pair')) return 'Set both the Supabase URL and key, or leave both empty.'
  return message
}

export async function listTenants() {
  const { data, error } = await supabase
    .from('tenants')
    .select('*, tenant_domains(domain, is_primary), businesses(count)')
    .order('created_at', { ascending: false })
  fail(error)
  return (data ?? []) as TenantListRow[]
}

export async function getTenant(id: string) {
  const { data, error } = await supabase.from('tenants').select('*').eq('id', id).maybeSingle()
  fail(error)
  return data as TenantRow | null
}

export async function createTenant(input: {
  name: string
  app_name: string
  primary_color: string
  domain: string | null
}) {
  const { domain, ...fields } = input
  const { data, error } = await supabase.from('tenants').insert(fields).select('*').single()
  fail(error)
  const tenant = data as TenantRow
  if (domain) {
    try {
      await addDomain(tenant.id, domain, true)
    } catch (e) {
      // keep things consistent: no half-created tenant
      await supabase.from('tenants').delete().eq('id', tenant.id)
      throw e
    }
  }
  return tenant
}

export async function updateTenant(id: string, patch: Partial<TenantRow>) {
  const { data, error } = await supabase.from('tenants').update(patch).eq('id', id).select('*').single()
  fail(error)
  return data as TenantRow
}

export async function deleteTenant(tenant: TenantRow) {
  // remove branding files first (storage isn't cleared by the database cascade)
  const { data: files } = await supabase.storage.from(BUCKET).list(tenant.id)
  if (files?.length) {
    await supabase.storage.from(BUCKET).remove(files.map((f) => `${tenant.id}/${f.name}`))
  }
  const { error } = await supabase.from('tenants').delete().eq('id', tenant.id)
  fail(error)
}

// ---------- domains ----------
export async function listDomains(tenantId: string) {
  const { data, error } = await supabase
    .from('tenant_domains')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('is_primary', { ascending: false })
    .order('created_at')
  fail(error)
  return (data ?? []) as DomainRow[]
}

export async function addDomain(tenantId: string, domain: string, isPrimary: boolean) {
  const { error } = await supabase
    .from('tenant_domains')
    .insert({ tenant_id: tenantId, domain: domain.trim().toLowerCase(), is_primary: isPrimary })
  fail(error)
}

export async function removeDomain(id: string) {
  const { error } = await supabase.from('tenant_domains').delete().eq('id', id)
  fail(error)
}

export async function setPrimaryDomain(tenantId: string, domainId: string) {
  let { error } = await supabase
    .from('tenant_domains')
    .update({ is_primary: false })
    .eq('tenant_id', tenantId)
    .eq('is_primary', true)
  fail(error)
  ;({ error } = await supabase.from('tenant_domains').update({ is_primary: true }).eq('id', domainId))
  fail(error)
}

// ---------- branding files ----------
function pathInBucket(url: string | null) {
  const marker = `/storage/v1/object/public/${BUCKET}/`
  return url && url.includes(marker) ? url.split(marker)[1] : null
}

/** Uploads a logo or favicon and saves its URL on the tenant. Removes the previous file. */
export async function uploadBranding(tenant: TenantRow, kind: 'logo' | 'favicon', file: File) {
  const ext = (file.name.split('.').pop() || 'png').toLowerCase()
  const path = `${tenant.id}/${kind}-${Date.now()}.${ext}`
  const { error } = await supabase.storage.from(BUCKET).upload(path, file, { contentType: file.type })
  fail(error)
  const url = supabase.storage.from(BUCKET).getPublicUrl(path).data.publicUrl
  const column = kind === 'logo' ? 'logo_url' : 'favicon_url'
  const updated = await updateTenant(tenant.id, { [column]: url })
  const old = pathInBucket(tenant[column])
  if (old) await supabase.storage.from(BUCKET).remove([old])
  return updated
}

export async function removeBranding(tenant: TenantRow, kind: 'logo' | 'favicon') {
  const column = kind === 'logo' ? 'logo_url' : 'favicon_url'
  const updated = await updateTenant(tenant.id, { [column]: null })
  const old = pathInBucket(tenant[column])
  if (old) await supabase.storage.from(BUCKET).remove([old])
  return updated
}
