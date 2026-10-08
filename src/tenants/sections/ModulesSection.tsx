import { useState } from 'react'
import { Button } from '@/components/Button'
import { cn } from '@/lib/cn'
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
    <div className="max-w-[640px]">
      <SectionHeader title="Modules" description="Choose which parts of the app this tenant gets." />

      <div className="mb-3 flex items-center justify-between">
        <span className="text-sm text-gray-600">
          {enabled.size} of {MODULES.length} enabled
        </span>
        <button
          type="button"
          onClick={() => {
            setSaved(false)
            setEnabled(allOn ? new Set() : new Set(MODULES.map((m) => m.key)))
          }}
          className="text-sm font-semibold text-brand hover:underline"
        >
          {allOn ? 'Turn all off' : 'Turn all on'}
        </button>
      </div>

      <ul className="divide-y divide-gray-100 rounded-xl border border-gray-200">
        {MODULES.map((m) => {
          const on = enabled.has(m.key)
          return (
            <li key={m.key}>
              <label className="flex cursor-pointer items-center justify-between gap-4 px-4 py-3 hover:bg-gray-50">
                <div>
                  <div className="text-sm font-medium">{m.label}</div>
                  <div className="text-xs text-gray-500">{m.description}</div>
                </div>
                <input type="checkbox" className="peer sr-only" checked={on} onChange={() => toggle(m.key)} />
                <span
                  aria-hidden
                  className={cn(
                    'relative h-6 w-11 shrink-0 rounded-full transition-colors peer-focus-visible:ring-2 peer-focus-visible:ring-brand/40',
                    on ? 'bg-brand' : 'bg-gray-300',
                  )}
                >
                  <span
                    className={cn(
                      'absolute top-0.5 left-0.5 size-5 rounded-full bg-white shadow transition-transform',
                      on && 'translate-x-5',
                    )}
                  />
                </span>
              </label>
            </li>
          )
        })}
      </ul>

      <p className="mt-3 text-xs text-gray-500">
        This saves the choice. The tenant&apos;s panel will hide modules that are off as each module is built.
      </p>
      <div className="mt-4 flex items-center gap-4">
        <Button variant="dark" onClick={save} disabled={busy || !changed}>
          {busy ? 'Saving…' : 'Save modules'}
        </Button>
        <SaveStatus error={error} saved={saved} />
      </div>
    </div>
  )
}
