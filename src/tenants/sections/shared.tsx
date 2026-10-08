import type { ReactNode } from 'react'
import type { TenantRow } from '../types'

export type SectionProps = { tenant: TenantRow; onSaved: (t: TenantRow) => void }

export function SectionHeader({ title, description }: { title: string; description: string }) {
  return (
    <div className="mb-5">
      <h3 className="text-lg font-semibold">{title}</h3>
      <p className="mt-0.5 text-sm text-gray-600">{description}</p>
    </div>
  )
}

export function SaveStatus({ error, saved }: { error: string | null; saved: boolean }): ReactNode {
  if (error) return <p className="text-sm text-red-600">{error}</p>
  if (saved) return <p className="text-sm text-emerald-700">Saved.</p>
  return null
}
