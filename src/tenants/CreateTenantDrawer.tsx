import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import { Button } from '@/components/Button'
import { Drawer } from '@/components/Drawer'
import { Label, TextInput } from '@/components/Field'
import { createTenant } from './api'
import { ColorField } from './ColorField'
import { isValidDomain, isValidHexColor } from './types'

export function CreateTenantDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [appName, setAppName] = useState('')
  const [domain, setDomain] = useState('')
  const [color, setColor] = useState('#2b5fe8')
  const [plan, setPlan] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  function reset() {
    setName('')
    setAppName('')
    setDomain('')
    setColor('#2b5fe8')
    setPlan('')
    setError(null)
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    const d = domain.trim().toLowerCase()
    if (!name.trim() || !appName.trim()) return setError('Client name and app name are required.')
    if (d && !isValidDomain(d)) return setError('Enter a domain like admin.clientname.com (no https://).')
    if (!isValidHexColor(color)) return setError('Pick a colour like #2b5fe8.')
    setBusy(true)
    setError(null)
    try {
      const tenant = await createTenant({
        name: name.trim(),
        app_name: appName.trim(),
        primary_color: color,
        plan: plan.trim() || null,
        domain: d || null,
      })
      reset()
      onClose()
      navigate(`/clients/${tenant.id}`)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title="Add Client"
      footer={
        <>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" form="create-tenant" disabled={busy}>
            {busy ? 'Creating…' : 'Create Client'}
          </Button>
        </>
      }
    >
      <p className="mb-5 text-sm text-gray-600">
        Creates the client with starter roles and adds you as Tech Support Team. You can upload the logo, set modules
        and more domains on the next screen.
      </p>
      <form id="create-tenant" onSubmit={onSubmit} className="space-y-5">
        <div>
          <Label htmlFor="t-name" required>
            Client name
          </Label>
          <TextInput id="t-name" placeholder="e.g. Viral" value={name} onChange={(e) => setName(e.target.value)} />
          <p className="mt-1 text-xs text-gray-500">Your name for this client. Only you see it.</p>
        </div>
        <div>
          <Label htmlFor="t-app" required>
            App name
          </Label>
          <TextInput
            id="t-app"
            placeholder="e.g. Viral Sakhiya"
            value={appName}
            onChange={(e) => setAppName(e.target.value)}
          />
          <p className="mt-1 text-xs text-gray-500">
            Shown to the client&apos;s users on their login page and sidebar.
          </p>
        </div>
        <div>
          <Label htmlFor="t-domain">Primary domain</Label>
          <TextInput
            id="t-domain"
            placeholder="e.g. admin.viralsakhiya.com"
            value={domain}
            onChange={(e) => setDomain(e.target.value)}
          />
          <p className="mt-1 text-xs text-gray-500">A subdomain of bizdock.in or the client&apos;s own domain.</p>
        </div>
        <ColorField id="t-color" label="Theme colour" value={color} onChange={setColor} />
        <div>
          <Label htmlFor="t-plan">Plan</Label>
          <TextInput id="t-plan" placeholder="e.g. Starter" value={plan} onChange={(e) => setPlan(e.target.value)} />
        </div>
        {error && <p className="text-sm text-red-600">{error}</p>}
      </form>
    </Drawer>
  )
}
