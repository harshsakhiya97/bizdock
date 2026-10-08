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
      navigate('/tenants', { replace: true })
    } catch (err) {
      setError((err as Error).message)
      setBusy(false)
    }
  }

  return (
    <div className="max-w-[560px]">
      <SectionHeader title="Delete tenant" description="Permanently remove this tenant and everything in it." />
      <div className="rounded-xl border border-red-200 bg-red-50 p-5">
        <p className="text-sm text-red-800">
          This deletes <strong>{tenant.app_name}</strong>: its businesses, roles, team memberships, domains, logo and
          all of its data. Its users&apos; logins stay (they may belong to other tenants). This can&apos;t be undone.
        </p>
        <label htmlFor="confirm-name" className="mt-4 mb-1.5 block text-sm font-semibold text-gray-900">
          Type <span className="font-mono">{tenant.name}</span> to confirm
        </label>
        <TextInput
          id="confirm-name"
          autoComplete="off"
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
          className="bg-white"
        />
        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        <Button variant="danger" className="mt-4" disabled={!matches || busy} onClick={onDelete}>
          <Trash2 /> {busy ? 'Deleting…' : 'Delete tenant'}
        </Button>
      </div>
    </div>
  )
}
