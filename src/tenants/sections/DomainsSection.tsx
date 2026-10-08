import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Globe, Plus, Star, Trash2 } from 'lucide-react'
import { Button } from '@/components/Button'
import { TextInput } from '@/components/Field'
import { Modal } from '@/components/Modal'
import { addDomain, listDomains, removeDomain, setPrimaryDomain } from '../api'
import { isValidDomain, type DomainRow, type TenantRow } from '../types'
import { SectionHeader } from './shared'

export function DomainsSection({ tenant }: { tenant: TenantRow }) {
  const [domains, setDomains] = useState<DomainRow[] | null>(null)
  const [value, setValue] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState<DomainRow | null>(null)

  const load = useCallback(() => {
    listDomains(tenant.id)
      .then(setDomains)
      .catch((e: Error) => setError(e.message))
  }, [tenant.id])
  useEffect(load, [load])

  async function act(fn: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await fn()
      load()
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function onAdd(e: FormEvent) {
    e.preventDefault()
    const d = value
      .trim()
      .toLowerCase()
      .replace(/^https?:\/\//, '')
      .replace(/\/.*$/, '')
    if (!isValidDomain(d)) return setError('Enter a domain like admin.clientname.com.')
    const first = (domains?.length ?? 0) === 0
    void act(async () => {
      await addDomain(tenant.id, d, first)
      setValue('')
    })
  }

  return (
    <div className="max-w-[640px]">
      <SectionHeader
        title="Domains"
        description="Addresses that open this tenant's panel: a bizdock.in subdomain or the client's own domain."
      />

      <form onSubmit={onAdd} className="mb-5 flex gap-2">
        <div className="flex-1">
          <TextInput
            aria-label="New domain"
            placeholder="e.g. admin.viralsakhiya.com or viral.bizdock.in"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            icon={<Globe />}
          />
        </div>
        <Button type="submit" disabled={busy || !value.trim()} className="h-11">
          <Plus /> Add domain
        </Button>
      </form>
      {error && <p className="mb-4 text-sm text-red-600">{error}</p>}

      {!domains ? (
        <p className="text-sm text-gray-500">Loading…</p>
      ) : domains.length === 0 ? (
        <p className="rounded-lg border border-dashed border-gray-300 px-4 py-8 text-center text-sm text-gray-500">
          No domains yet. Without one, this tenant can only be opened locally with its tenant key.
        </p>
      ) : (
        <ul className="divide-y divide-gray-100 rounded-xl border border-gray-200">
          {domains.map((d) => (
            <li key={d.id} className="flex items-center justify-between gap-3 px-4 py-3">
              <div className="flex min-w-0 items-center gap-2.5">
                <Globe className="size-4 shrink-0 text-gray-400" />
                <span className="truncate text-sm font-medium">{d.domain}</span>
                {d.is_primary && (
                  <span className="rounded-md bg-brand-soft px-2 py-0.5 text-xs font-semibold text-brand">Primary</span>
                )}
              </div>
              <div className="flex shrink-0 gap-1">
                {!d.is_primary && (
                  <Button variant="ghost" disabled={busy} onClick={() => act(() => setPrimaryDomain(tenant.id, d.id))}>
                    <Star /> Make primary
                  </Button>
                )}
                <Button
                  variant="ghost"
                  disabled={busy}
                  className="text-red-600"
                  onClick={() => setConfirmRemove(d)}
                  aria-label={`Remove ${d.domain}`}
                >
                  <Trash2 />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}

      <div className="mt-6 rounded-xl bg-gray-50 p-4 text-sm text-gray-700">
        <div className="mb-1 font-semibold">DNS setup (once hosting is chosen)</div>
        Point each domain at the tenant panel&apos;s hosting with a <strong>CNAME</strong> record, and add it to the
        hosting&apos;s custom domains so SSL is issued. Until then, domains here only decide which tenant a domain
        opens.
      </div>

      <Modal open={!!confirmRemove} onClose={() => setConfirmRemove(null)}>
        <h2 className="text-lg font-bold">Remove domain?</h2>
        <p className="mt-1 text-sm text-gray-600">
          <strong>{confirmRemove?.domain}</strong> will stop opening this tenant&apos;s panel.
          {confirmRemove?.is_primary && ' It is the primary domain; pick another one as primary afterwards.'}
        </p>
        <div className="mt-6 grid grid-cols-2 gap-3">
          <Button variant="outline" onClick={() => setConfirmRemove(null)}>
            Cancel
          </Button>
          <Button
            variant="danger"
            onClick={() => {
              const d = confirmRemove
              setConfirmRemove(null)
              if (d) void act(() => removeDomain(d.id))
            }}
          >
            Remove
          </Button>
        </div>
      </Modal>
    </div>
  )
}
