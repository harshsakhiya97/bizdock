export type TenantRow = {
  id: string
  name: string
  tenant_key: string
  app_name: string
  logo_url: string | null
  favicon_url: string | null
  primary_color: string
  status: 'active' | 'suspended'
  plan: string | null
  enabled_modules: string[]
  supabase_url: string | null
  supabase_key: string | null
  created_at: string
  updated_at: string
}

export type DomainRow = {
  id: string
  tenant_id: string
  domain: string
  is_primary: boolean
  created_at: string
}

/** Tenant list row: tenant + its domains + business count */
export type TenantListRow = TenantRow & {
  tenant_domains: Pick<DomainRow, 'domain' | 'is_primary'>[]
  businesses: { count: number }[]
}

/** Modules a tenant can be given. Keys match the permission keys used by tenant roles. */
export const MODULES: { key: string; label: string; description: string }[] = [
  { key: 'dashboard', label: 'Dashboard', description: 'Overview across all businesses and per business' },
  { key: 'leads', label: 'Leads & Contacts', description: 'Capture and tag leads from every source' },
  { key: 'pipelines', label: 'Pipelines', description: 'Custom sales stages per business / product' },
  { key: 'follow_ups', label: 'Follow-ups', description: 'WhatsApp and call follow-up rules' },
  { key: 'calling', label: 'Calling Team', description: 'Shared calling queue and call outcomes' },
  { key: 'funnels', label: 'Funnels', description: 'Webinar and VSL tracking' },
  { key: 'payments', label: 'Payments & Sales', description: 'Online and offline payments, part-payments' },
  { key: 'finance', label: 'Finance', description: 'Income, expenses and profit per business' },
  { key: 'team', label: 'Team & Salary', description: 'Employee logins, roles and salary' },
  { key: 'settings', label: 'Settings', description: 'Businesses and app settings' },
]

/** hostname check: lowercase labels separated by dots, ending in a TLD */
export function isValidDomain(value: string) {
  return /^(?=.{1,253}$)(?:(?!-)[a-z0-9-]{1,63}(?<!-)\.)+[a-z]{2,63}$/.test(value)
}

export function isValidHexColor(value: string) {
  return /^#[0-9a-fA-F]{6}$/.test(value)
}
