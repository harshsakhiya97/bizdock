import { useState, type FormEvent } from 'react'
import { Check, Copy } from 'lucide-react'
import { Button } from '@/components/Button'
import { Label, TextInput } from '@/components/Field'
import { cn } from '@/lib/cn'
import { updateTenant } from '../api'
import { SaveStatus, SectionHeader, type SectionProps } from './shared'

export function GeneralSection({ tenant, onSaved }: SectionProps) {
  const [name, setName] = useState(tenant.name)
  const [appName, setAppName] = useState(tenant.app_name)
  const [plan, setPlan] = useState(tenant.plan ?? '')
  const [status, setStatus] = useState(tenant.status)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)
  const [copied, setCopied] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setSaved(false)
    if (!name.trim() || !appName.trim()) return setError('Tenant name and app name are required.')
    setBusy(true)
    setError(null)
    try {
      onSaved(
        await updateTenant(tenant.id, {
          name: name.trim(),
          app_name: appName.trim(),
          plan: plan.trim() || null,
          status,
        }),
      )
      setSaved(true)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function copyKey() {
    try {
      await navigator.clipboard.writeText(tenant.tenant_key)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      /* clipboard blocked */
    }
  }

  return (
    <div className="max-w-[520px]">
      <SectionHeader title="General" description="Basic details, plan and whether the tenant's app is open." />
      <form onSubmit={onSubmit} className="space-y-5">
        <div>
          <Label htmlFor="g-name" required>
            Tenant name
          </Label>
          <TextInput id="g-name" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div>
          <Label htmlFor="g-app" required>
            App name
          </Label>
          <TextInput id="g-app" value={appName} onChange={(e) => setAppName(e.target.value)} />
        </div>
        <div>
          <Label htmlFor="g-plan">Plan</Label>
          <TextInput id="g-plan" placeholder="e.g. Starter" value={plan} onChange={(e) => setPlan(e.target.value)} />
        </div>
        <div>
          <span className="mb-1.5 block text-sm font-semibold">Status</span>
          <div className="inline-flex rounded-lg border border-gray-300 p-1">
            {(['active', 'suspended'] as const).map((s) => (
              <button
                key={s}
                type="button"
                onClick={() => setStatus(s)}
                className={cn(
                  'rounded-md px-4 py-1.5 text-sm font-medium',
                  status === s
                    ? s === 'active'
                      ? 'bg-emerald-50 text-emerald-700'
                      : 'bg-amber-50 text-amber-700'
                    : 'text-gray-600 hover:bg-gray-50',
                )}
              >
                {s === 'active' ? 'Active' : 'Suspended'}
              </button>
            ))}
          </div>
          {status === 'suspended' && (
            <p className="mt-1.5 text-xs text-amber-700">
              Suspended tenants see &ldquo;Workspace not found&rdquo; and can&apos;t log in.
            </p>
          )}
        </div>

        <div>
          <span className="mb-1.5 block text-sm font-semibold">Tenant key</span>
          <div className="flex items-center gap-2">
            <code className="rounded-lg border border-gray-200 bg-gray-50 px-3 py-2 font-mono text-sm">
              {tenant.tenant_key}
            </code>
            <Button type="button" variant="outline" onClick={copyKey}>
              {copied ? <Check /> : <Copy />} {copied ? 'Copied' : 'Copy'}
            </Button>
          </div>
          <p className="mt-1.5 text-xs text-gray-500">
            For local testing of the tenant&apos;s panel: set <code>VITE_TENANT_KEY</code> to this in its .env.local.
          </p>
        </div>

        <SaveStatus error={error} saved={saved} />
        <Button type="submit" variant="dark" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </Button>
      </form>
    </div>
  )
}
