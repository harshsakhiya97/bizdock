import { useState } from 'react'
import { Button } from '@/components/Button'
import { Hint } from '@/components/Field'
import { cn } from '@/lib/cn'
import { updateTenant } from '../api'
import { OTHER_CONNECTIONS, WHATSAPP_PROVIDERS, type OtherConnection, type TenantRow, type WhatsAppProvider } from '../types'
import { SaveStatus, SectionHeader, type SectionProps } from './shared'

type State = { whatsapp: boolean; provider: WhatsAppProvider | null } & Record<OtherConnection, boolean>
const read = (t: TenantRow): State => ({
  whatsapp: !!t.connections?.whatsapp?.allowed,
  provider: t.connections?.whatsapp?.provider ?? null,
  ...(Object.fromEntries(OTHER_CONNECTIONS.map((c) => [c.key, !!t.connections?.[c.key]?.allowed])) as Record<OtherConnection, boolean>),
})

/** What this client may connect in its System Connections page. */
export function ConnectionsSection({ tenant, onSaved }: SectionProps) {
  const [st, setSt] = useState<State>(() => read(tenant))
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)
  const set = (patch: Partial<State>) => {
    setSaved(false)
    setSt((s) => ({ ...s, ...patch }))
  }
  const changed = JSON.stringify({ ...st, provider: st.whatsapp ? st.provider : null }) !== JSON.stringify({ ...read(tenant), provider: read(tenant).whatsapp ? read(tenant).provider : null })
  const on = [st.whatsapp, ...OTHER_CONNECTIONS.map((c) => st[c.key])].filter(Boolean).length

  async function save() {
    if (st.whatsapp && !st.provider) return setError('Pick the WhatsApp provider.')
    setBusy(true)
    setError(null)
    try {
      const connections = {
        ...tenant.connections,
        whatsapp: { allowed: st.whatsapp, provider: st.whatsapp ? st.provider : null },
        ...Object.fromEntries(OTHER_CONNECTIONS.map((c) => [c.key, { allowed: st[c.key] }])),
      }
      onSaved(await updateTenant(tenant.id, { connections }))
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
        <span className="muted">
          {on} of {OTHER_CONNECTIONS.length + 1} allowed
        </span>
        <div className="link-rows">
          <label>
            <span className="check">
              <input type="checkbox" checked={st.whatsapp} onChange={(e) => set({ whatsapp: e.target.checked })} />
              <span>
                <b>WhatsApp</b>
                <small>Send WhatsApp messages from leads, clients, bookings and workflows.</small>
              </span>
            </span>
          </label>
        </div>

        {st.whatsapp && (
          <>
            <span className="field-label">WhatsApp provider</span>
            <div className="choice-grid">
              {WHATSAPP_PROVIDERS.map((p) => (
                <button key={p.key} type="button" className={cn('choice', st.provider === p.key && 'is-active')} onClick={() => set({ provider: p.key })}>
                  <b>{p.label}</b>
                  <small>{p.description}</small>
                </button>
              ))}
            </div>
            <Hint>Changing the provider later means the client has to enter the new provider’s keys again.</Hint>
          </>
        )}

        <div className="link-rows">
          {OTHER_CONNECTIONS.map((c) => (
            <label key={c.key}>
              <span className="check">
                <input type="checkbox" checked={st[c.key]} onChange={(e) => set({ [c.key]: e.target.checked } as Partial<State>)} />
                <span>
                  <b>{c.label}</b>
                  <small>{c.description}</small>
                </span>
              </span>
            </label>
          ))}
        </div>
        <Hint>Turning one off hides Connect for the client; a connection they already saved stays until they disconnect it.</Hint>

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
