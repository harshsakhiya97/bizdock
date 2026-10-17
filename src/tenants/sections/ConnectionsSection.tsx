import { useState } from 'react'
import { Button } from '@/components/Button'
import { Hint } from '@/components/Field'
import { cn } from '@/lib/cn'
import { updateTenant } from '../api'
import { WHATSAPP_PROVIDERS, type WhatsAppProvider } from '../types'
import { SaveStatus, SectionHeader, type SectionProps } from './shared'

/** What this client may connect in its System Connections page. */
export function ConnectionsSection({ tenant, onSaved }: SectionProps) {
  const wa = tenant.connections?.whatsapp
  const [allowed, setAllowed] = useState(!!wa?.allowed)
  const [provider, setProvider] = useState<WhatsAppProvider | null>(wa?.provider ?? null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)
  const changed = allowed !== !!wa?.allowed || (allowed && provider !== (wa?.provider ?? null))

  async function save() {
    if (allowed && !provider) return setError('Pick the WhatsApp provider.')
    setBusy(true)
    setError(null)
    try {
      onSaved(await updateTenant(tenant.id, { connections: { ...tenant.connections, whatsapp: { allowed, provider: allowed ? provider : null } } }))
      setSaved(true)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <SectionHeader title="Connections" description="Third-party services this client may connect. They enter their own keys in System Connections." />

      <div className="stack" style={{ maxWidth: 640, gap: 12 }}>
        <div className="link-rows">
          <label>
            <span className="check">
              <input
                type="checkbox"
                checked={allowed}
                onChange={(e) => {
                  setSaved(false)
                  setAllowed(e.target.checked)
                }}
              />
              <span>
                <b>WhatsApp</b>
                <small>Send WhatsApp messages from leads, clients, bookings and workflows.</small>
              </span>
            </span>
          </label>
        </div>

        {allowed && (
          <>
            <span className="field-label">WhatsApp provider</span>
            <div className="choice-grid">
              {WHATSAPP_PROVIDERS.map((p) => (
                <button
                  key={p.key}
                  type="button"
                  className={cn('choice', provider === p.key && 'is-active')}
                  onClick={() => {
                    setSaved(false)
                    setProvider(p.key)
                  }}
                >
                  <b>{p.label}</b>
                  <small>{p.description}</small>
                </button>
              ))}
            </div>
            <Hint>Changing the provider later means the client has to enter the new provider’s keys again.</Hint>
          </>
        )}

        <div className="row">
          <Button variant="dark" onClick={save} disabled={busy || !changed}>
            {busy ? 'Saving…' : 'Save connections'}
          </Button>
          <SaveStatus error={error} saved={saved} />
        </div>
      </div>
    </>
  )
}
