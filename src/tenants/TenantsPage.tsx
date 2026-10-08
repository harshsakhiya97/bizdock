import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/Button'
import { listTenants } from './api'
import { CreateTenantDrawer } from './CreateTenantDrawer'
import { StatusBadge, TenantIcon } from './TenantBadges'
import type { TenantListRow } from './types'

export function TenantsPage() {
  const [rows, setRows] = useState<TenantListRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [creating, setCreating] = useState(false)

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

  return (
    <div>
      <h2 className="text-lg font-semibold">Clients</h2>
      <p className="mt-0.5 text-sm text-gray-600">Your clients, their domains and branding.</p>

      <div className="mt-4 rounded-xl border border-gray-200 bg-white">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 px-4 py-3">
          <div className="flex items-center gap-2">
            <span className="rounded-lg border border-brand px-3 py-1 text-sm font-medium text-brand">All Clients</span>
            <span className="rounded-md bg-brand-soft px-2 py-0.5 text-xs font-semibold text-brand">
              {rows?.length ?? 0} Clients
            </span>
          </div>
          <div className="flex items-center gap-3">
            <div className="relative">
              <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-gray-400" />
              <input
                type="search"
                placeholder="Search clients or domains"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                className="h-9 w-64 rounded-lg border border-gray-300 pr-3 pl-9 text-sm outline-none focus:border-brand focus:ring-2 focus:ring-brand/15"
              />
            </div>
            <Button onClick={() => setCreating(true)}>
              <Plus /> Add Client
            </Button>
          </div>
        </div>

        {error ? (
          <p className="px-4 py-10 text-center text-sm text-red-600">{error}</p>
        ) : !filtered ? (
          <p className="px-4 py-10 text-center text-sm text-gray-500">Loading clients…</p>
        ) : filtered.length === 0 ? (
          <p className="px-4 py-10 text-center text-sm text-gray-500">
            {rows?.length ? 'No clients match your search.' : 'No clients yet. Add your first one.'}
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-200 text-left text-xs font-semibold tracking-wide text-gray-500 uppercase">
                  <th className="px-4 py-2.5">Client</th>
                  <th className="px-4 py-2.5">Primary domain</th>
                  <th className="px-4 py-2.5">Businesses</th>
                  <th className="px-4 py-2.5">Plan</th>
                  <th className="px-4 py-2.5">Status</th>
                  <th className="px-4 py-2.5">Created</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((t) => {
                  const primary = t.tenant_domains.find((d) => d.is_primary) ?? t.tenant_domains[0]
                  return (
                    <tr key={t.id} className="border-b border-gray-100 last:border-0 hover:bg-gray-50">
                      <td className="px-4 py-3">
                        <Link to={`/clients/${t.id}`} className="flex items-center gap-3">
                          <TenantIcon tenant={t} />
                          <div>
                            <div className="font-semibold text-gray-900 hover:text-brand">{t.app_name}</div>
                            <div className="text-xs text-gray-500">{t.name}</div>
                          </div>
                        </Link>
                      </td>
                      <td className="px-4 py-3 text-gray-700">
                        {primary?.domain ?? <span className="text-gray-400">No domain</span>}
                        {t.tenant_domains.length > 1 && (
                          <span className="ml-1.5 text-xs text-gray-400">+{t.tenant_domains.length - 1}</span>
                        )}
                      </td>
                      <td className="px-4 py-3 text-gray-700">{t.businesses[0]?.count ?? 0}</td>
                      <td className="px-4 py-3 text-gray-700">{t.plan || '—'}</td>
                      <td className="px-4 py-3">
                        <StatusBadge status={t.status} />
                      </td>
                      <td className="px-4 py-3 text-gray-500">
                        {new Date(t.created_at).toLocaleDateString('en-IN', {
                          day: 'numeric',
                          month: 'short',
                          year: 'numeric',
                        })}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <CreateTenantDrawer open={creating} onClose={() => setCreating(false)} />
    </div>
  )
}
