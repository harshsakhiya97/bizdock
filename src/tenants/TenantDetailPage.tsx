import { useCallback, useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router'
import { ArrowLeft } from 'lucide-react'
import { Empty } from '@/components/ui'
import { cn } from '@/lib/cn'
import { getTenant } from './api'
import { BrandingSection } from './sections/BrandingSection'
import { DangerSection } from './sections/DangerSection'
import { DatabaseSection } from './sections/DatabaseSection'
import { DomainsSection } from './sections/DomainsSection'
import { GeneralSection } from './sections/GeneralSection'
import { ModulesSection } from './sections/ModulesSection'
import { ConnectionsSection } from './sections/ConnectionsSection'
import { StatusBadge, TenantIcon } from './TenantBadges'
import type { TenantRow } from './types'

const sections = [
  { id: 'general', label: 'General' },
  { id: 'branding', label: 'Branding' },
  { id: 'domains', label: 'Domains' },
  { id: 'modules', label: 'Modules' },
  { id: 'connections', label: 'Connections' },
  { id: 'database', label: 'Database' },
  { id: 'delete', label: 'Delete client' },
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

  if (error) return <div className="alert alert-error">{error}</div>
  if (tenant === undefined) return <div className="empty">Loading client…</div>
  if (tenant === null)
    return (
      <div className="card">
        <Empty>
          <div>This client doesn&apos;t exist (it may have been deleted).</div>
          <Link to="/clients" className="link" style={{ marginTop: 8 }}>
            Back to clients
          </Link>
        </Empty>
      </div>
    )

  const props = { tenant, onSaved: setTenant }

  return (
    <>
      <Link to="/clients" className="back-link">
        <ArrowLeft size={15} /> All clients
      </Link>
      <div className="detail-head">
        <TenantIcon tenant={tenant} size={44} />
        <div>
          <div className="row" style={{ gap: 8 }}>
            <h2>{tenant.app_name}</h2>
            <StatusBadge status={tenant.status} />
          </div>
          <p>{tenant.name}</p>
        </div>
      </div>

      <div className="settings">
        <nav className="settings-nav">
          <div className="label">CLIENT</div>
          {sections.map((s) => (
            <button
              key={s.id}
              type="button"
              onClick={() => setParams(s.id === 'general' ? {} : { section: s.id })}
              className={cn(section === s.id && 'is-active', s.id === 'delete' && 'danger-text')}
            >
              {s.label}
            </button>
          ))}
        </nav>
        <div className="settings-body">
          {section === 'general' && <GeneralSection {...props} />}
          {section === 'branding' && <BrandingSection {...props} />}
          {section === 'domains' && <DomainsSection tenant={tenant} />}
          {section === 'modules' && <ModulesSection {...props} />}
          {section === 'connections' && <ConnectionsSection {...props} />}
          {section === 'database' && <DatabaseSection {...props} />}
          {section === 'delete' && <DangerSection tenant={tenant} />}
        </div>
      </div>
    </>
  )
}
