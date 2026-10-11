import { useState } from 'react'
import { useNavigate } from 'react-router'
import { Trash2 } from 'lucide-react'
import { Button } from '@/components/Button'
import { TextInput } from '@/components/Field'
import { deleteTenant } from '../api'
import type { TenantRow } from '../types'
import { SectionHeader } from './shared'

export function DangerSection({ tenant }: { tenant: TenantRow }) {
  const navigate = useNavigate()
  const [typed, setTyped] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const matches = typed.trim() === tenant.name

  async function onDelete() {
    if (!matches) return
    setBusy(true)
    setError(null)
    try {
      await deleteTenant(tenant)
      navigate('/clients', { replace: true })
    } catch (err) {
      setError((err as Error).message)
      setBusy(false)
    }
  }

  return (
    <>
      <SectionHeader title="Delete client" description="Permanently remove this client and everything in it." />
      <div className="alert-danger-box" style={{ maxWidth: 560 }}>
        <p>
          This deletes <strong>{tenant.app_name}</strong>: its businesses, roles, team memberships, domains, logo and
          all of its data. Its users&apos; logins stay (they may belong to other clients). This can&apos;t be undone.
        </p>
        <div>
          <label htmlFor="confirm-name" className="field-label">
            Type <span className="input-mono">{tenant.name}</span> to confirm
          </label>
          <TextInput id="confirm-name" autoComplete="off" value={typed} onChange={(e) => setTyped(e.target.value)} />
        </div>
        {error && <div className="alert alert-error">{error}</div>}
        <div>
          <Button variant="danger" disabled={!matches || busy} onClick={onDelete}>
            <Trash2 /> {busy ? 'Deleting…' : 'Delete client'}
          </Button>
        </div>
      </div>
    </>
  )
}
