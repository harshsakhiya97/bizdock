import type { ReactNode } from 'react'
import type { TenantRow } from '../types'

export type SectionProps = { tenant: TenantRow; onSaved: (t: TenantRow) => void }

export function SectionHeader({ title, description }: { title: string; description: string }) {
  return (
    <div className="page-head">
      <h2>{title}</h2>
      <p>{description}</p>
    </div>
  )
}

export function SaveStatus({ error, saved }: { error: string | null; saved: boolean }): ReactNode {
  if (error) return <div className="alert alert-error">{error}</div>
  if (saved) return <div className="alert alert-info">Saved.</div>
  return null
}
