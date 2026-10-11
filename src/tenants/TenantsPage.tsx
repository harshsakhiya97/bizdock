import { useCallback, useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router'
import { Plus } from 'lucide-react'
import { DataTable, PageHead, SearchInput, Tabs, type Column } from '@/components/ui'
import { listTenants } from './api'
import { CreateTenantDrawer } from './CreateTenantDrawer'
import { StatusBadge, TenantIcon } from './TenantBadges'
import type { TenantListRow } from './types'

export function TenantsPage() {
  const [rows, setRows] = useState<TenantListRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [creating, setCreating] = useState(false)
  const navigate = useNavigate()

  const load = useCallback(() => {
    listTenants()
      .then(setRows)
      .catch((e: Error) => setError(e.message))
  }, [])
  useEffect(load, [load])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!rows || !q) return rows
    return rows.filter(
      (t) =>
        t.name.toLowerCase().includes(q) ||
        t.app_name.toLowerCase().includes(q) ||
        t.tenant_domains.some((d) => d.domain.includes(q)),
    )
  }, [rows, query])

  const columns: Column<TenantListRow>[] = [
    {
      key: 'client',
      label: 'Client',
      render: (t) => (
        <div className="cell-main">
          <TenantIcon tenant={t} />
          <div>
            <span className="strong">{t.app_name}</span>
            <small>{t.name}</small>
          </div>
        </div>
      ),
    },
    {
      key: 'domain',
      label: 'Primary domain',
      render: (t) => {
        const primary = t.tenant_domains.find((d) => d.is_primary) ?? t.tenant_domains[0]
        return (
          <>
            {primary?.domain ?? <span className="muted">No domain</span>}
            {t.tenant_domains.length > 1 && (
              <span className="muted small" style={{ marginLeft: 6 }}>
                +{t.tenant_domains.length - 1}
              </span>
            )}
          </>
        )
      },
    },
    { key: 'businesses', label: 'Businesses', render: (t) => <span className="num">{t.businesses[0]?.count ?? 0}</span> },
    { key: 'status', label: 'Status', render: (t) => <StatusBadge status={t.status} /> },
    {
      key: 'created',
      label: 'Created',
      render: (t) => (
        <span className="muted nowrap">
          {new Date(t.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
        </span>
      ),
    },
  ]

  return (
    <>
      <PageHead title="Clients" subtitle="Your clients, their domains and branding." />

      <div className="panel">
        <div className="panel-bar">
          <Tabs tabs={['All Clients']} value="All Clients" count={`${rows?.length ?? 0} Clients`} />
          <div className="row">
            <SearchInput placeholder="Search clients or domains" value={query} onChange={setQuery} width={260} />
            <button type="button" className="btn btn-primary" onClick={() => setCreating(true)}>
              <Plus size={16} /> Add Client
            </button>
          </div>
        </div>

        {error ? (
          <div className="empty danger-text">{error}</div>
        ) : !filtered ? (
          <div className="empty">Loading clients…</div>
        ) : (
          <DataTable
            bare
            columns={columns}
            rows={filtered}
            onRowClick={(t) => navigate(`/clients/${t.id}`)}
            empty={rows?.length ? 'No clients match your search.' : 'No clients yet. Add your first one.'}
          />
        )}
      </div>

      <CreateTenantDrawer open={creating} onClose={() => setCreating(false)} />
    </>
  )
}
