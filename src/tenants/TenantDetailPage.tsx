import { useCallback, useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router'
import { ArrowLeft } from 'lucide-react'
import { cn } from '@/lib/cn'
import { getTenant } from './api'
import { BrandingSection } from './sections/BrandingSection'
import { DangerSection } from './sections/DangerSection'
import { DatabaseSection } from './sections/DatabaseSection'
import { DomainsSection } from './sections/DomainsSection'
import { GeneralSection } from './sections/GeneralSection'
import { ModulesSection } from './sections/ModulesSection'
import { StatusBadge, TenantIcon } from './TenantBadges'
import type { TenantRow } from './types'

const sections = [
  { id: 'general', label: 'General' },
  { id: 'branding', label: 'Branding' },
  { id: 'domains', label: 'Domains' },
  { id: 'modules', label: 'Modules' },
  { id: 'database', label: 'Database' },
  { id: 'delete', label: 'Delete tenant' },
] as const
type SectionId = (typeof sections)[number]['id']

export function TenantDetailPage() {
  const { id = '' } = useParams()
  const [params, setParams] = useSearchParams()
  const section = (sections.find((s) => s.id === params.get('section'))?.id ?? 'general') as SectionId
  const [tenant, setTenant] = useState<TenantRow | null | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(() => {
    getTenant(id)
      .then(setTenant)
      .catch((e: Error) => setError(e.message))
  }, [id])
  useEffect(load, [load])

  if (error) return <p className="text-sm text-red-600">{error}</p>
  if (tenant === undefined) return <p className="text-sm text-gray-500">Loading tenant…</p>
  if (tenant === null)
    return (
      <div>
        <p className="text-sm text-gray-600">This tenant doesn&apos;t exist (it may have been deleted).</p>
        <Link to="/tenants" className="mt-2 inline-block text-sm font-semibold text-brand">
          Back to tenants
        </Link>
      </div>
    )

  const props = { tenant, onSaved: setTenant }

  return (
    <div>
      <Link to="/tenants" className="inline-flex items-center gap-1.5 text-sm text-gray-600 hover:text-brand">
        <ArrowLeft className="size-4" /> All tenants
      </Link>
      <div className="mt-3 mb-5 flex items-center gap-3">
        <TenantIcon tenant={tenant} size={44} />
        <div>
          <div className="flex items-center gap-2.5">
            <h2 className="text-lg font-semibold">{tenant.app_name}</h2>
            <StatusBadge status={tenant.status} />
          </div>
          <p className="text-sm text-gray-500">{tenant.name}</p>
        </div>
      </div>

      <div className="flex min-h-[460px] overflow-hidden rounded-xl border border-gray-200 bg-white">
        <aside className="w-[200px] shrink-0 border-r border-gray-200 p-2.5">
          <div className="px-2 pt-2 pb-3 text-[11px] font-bold tracking-wider text-brand uppercase">Tenant</div>
          {sections.map((s) => (
            <button
              key={s.id}
              onClick={() => setParams(s.id === 'general' ? {} : { section: s.id })}
              className={cn(
                'mb-1 block w-full rounded-md px-2.5 py-2 text-left text-sm',
                section === s.id ? 'bg-brand-soft font-semibold text-gray-900' : 'text-gray-700 hover:bg-gray-50',
                s.id === 'delete' && section !== s.id && 'text-red-600',
              )}
            >
              {s.label}
            </button>
          ))}
        </aside>
        <section className="min-w-0 flex-1 p-6">
          {section === 'general' && <GeneralSection {...props} />}
          {section === 'branding' && <BrandingSection {...props} />}
          {section === 'domains' && <DomainsSection tenant={tenant} />}
          {section === 'modules' && <ModulesSection {...props} />}
          {section === 'database' && <DatabaseSection {...props} />}
          {section === 'delete' && <DangerSection tenant={tenant} />}
        </section>
      </div>
    </div>
  )
}
