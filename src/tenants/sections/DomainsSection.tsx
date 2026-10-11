import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Globe, Plus, Star, Trash2 } from 'lucide-react'
import { Button } from '@/components/Button'
import { TextInput } from '@/components/Field'
import { ConfirmModal } from '@/components/ui'
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
    <>
      <SectionHeader
        title="Domains"
        description="Addresses that open this client's panel: a bizdock.in subdomain or their own domain."
      />

      <div className="stack" style={{ maxWidth: 640 }}>
        <form onSubmit={onAdd} className="row" style={{ flexWrap: 'nowrap' }}>
          <TextInput
            aria-label="New domain"
            placeholder="e.g. admin.viralsakhiya.com or viral.bizdock.in"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            icon={<Globe />}
          />
          <Button type="submit" disabled={busy || !value.trim()} style={{ height: 40 }}>
            <Plus /> Add domain
          </Button>
        </form>
        {error && <div className="alert alert-error">{error}</div>}

        {!domains ? (
          <div className="muted small">Loading…</div>
        ) : domains.length === 0 ? (
          <div className="empty-box">
            No domains yet. Without one, this client can only be opened locally with its client key.
          </div>
        ) : (
          <div className="link-rows">
            {domains.map((d) => (
              <div key={d.id}>
                <div className="lr-title">
                  <Globe size={15} className="muted" />
                  <span className="cell-clip">{d.domain}</span>
                  {d.is_primary && <span className="badge badge-brand">Primary</span>}
                </div>
                <div className="row-actions">
                  {!d.is_primary && (
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={busy}
                      onClick={() => act(() => setPrimaryDomain(tenant.id, d.id))}
                    >
                      <Star /> Make primary
                    </Button>
                  )}
                  <button
                    type="button"
                    className="btn btn-ghost btn-icon danger-text"
                    disabled={busy}
                    title="Remove"
                    aria-label={`Remove ${d.domain}`}
                    onClick={() => setConfirmRemove(d)}
                  >
                    <Trash2 size={15} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="note">
          <b>DNS setup (once hosting is chosen)</b>
          Point each domain at the client panel&apos;s hosting with a <strong>CNAME</strong> record, and add it to the
          hosting&apos;s custom domains so SSL is issued. Until then, domains here only decide which client a domain
          opens.
        </div>
      </div>

      <ConfirmModal
        open={!!confirmRemove}
        icon={Trash2}
        danger
        title="Remove domain?"
        message={
          <>
            <strong>{confirmRemove?.domain}</strong> will stop opening this client&apos;s panel.
            {confirmRemove?.is_primary && ' It is the primary domain; pick another one as primary afterwards.'}
          </>
        }
        confirmLabel="Remove"
        onCancel={() => setConfirmRemove(null)}
        onConfirm={() => {
          const d = confirmRemove
          setConfirmRemove(null)
          if (d) void act(() => removeDomain(d.id))
        }}
      />
    </>
  )
}
