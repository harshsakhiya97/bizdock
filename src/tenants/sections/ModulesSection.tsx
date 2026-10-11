import { useState } from 'react'
import { Button } from '@/components/Button'
import { Hint } from '@/components/Field'
import { updateTenant } from '../api'
import { MODULES } from '../types'
import { SaveStatus, SectionHeader, type SectionProps } from './shared'

export function ModulesSection({ tenant, onSaved }: SectionProps) {
  const [enabled, setEnabled] = useState<Set<string>>(new Set(tenant.enabled_modules))
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)

  const allOn = MODULES.every((m) => enabled.has(m.key))
  const changed = enabled.size !== tenant.enabled_modules.length || tenant.enabled_modules.some((k) => !enabled.has(k))

  function toggle(key: string) {
    setSaved(false)
    setEnabled((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  async function save() {
    setBusy(true)
    setError(null)
    try {
      // keep the order of MODULES
      const list = MODULES.map((m) => m.key).filter((k) => enabled.has(k))
      onSaved(await updateTenant(tenant.id, { enabled_modules: list }))
      setSaved(true)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <SectionHeader title="Modules" description="Choose which parts of the app this client gets." />

      <div className="stack" style={{ maxWidth: 640, gap: 12 }}>
        <div className="row-between">
          <span className="muted">
            {enabled.size} of {MODULES.length} enabled
          </span>
          <button
            type="button"
            className="link-btn"
            onClick={() => {
              setSaved(false)
              setEnabled(allOn ? new Set() : new Set(MODULES.map((m) => m.key)))
            }}
          >
            {allOn ? 'Turn all off' : 'Turn all on'}
          </button>
        </div>

        <div className="link-rows">
          {MODULES.map((m) => (
            <label key={m.key}>
              <span className="check">
                <input type="checkbox" checked={enabled.has(m.key)} onChange={() => toggle(m.key)} />
                <span>
                  <b>{m.label}</b>
                  <small>{m.description}</small>
                </span>
              </span>
            </label>
          ))}
        </div>

        <Hint>This saves the choice. The client&apos;s panel will hide modules that are off as each module is built.</Hint>
        <div className="row">
          <Button variant="dark" onClick={save} disabled={busy || !changed}>
            {busy ? 'Saving…' : 'Save modules'}
          </Button>
          <SaveStatus error={error} saved={saved} />
        </div>
      </div>
    </>
  )
}
