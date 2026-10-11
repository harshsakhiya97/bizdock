// Shared building blocks from the theme kit.
import { useState, type ReactNode } from 'react'
import { ChevronLeft, ChevronRight, Inbox, Search, type LucideIcon } from 'lucide-react'
import { cn } from '@/lib/cn'
import { Modal } from './Modal'

export function PageHead({ title, subtitle, actions }: { title: ReactNode; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="row-between page-top">
      <div className="page-head">
        <h2>{title}</h2>
        {subtitle && <p>{subtitle}</p>}
      </div>
      {actions && <div className="row page-actions">{actions}</div>}
    </div>
  )
}

export type Tone = 'ink' | 'brand' | 'info' | 'warning' | 'success' | 'danger' | 'teal' | 'purple' | 'orange'
const TONES: Record<Tone, [string, string]> = {
  ink: ['var(--ink)', '#fff'],
  brand: ['var(--brand-soft)', 'var(--brand)'],
  info: ['var(--info-soft)', 'var(--info)'],
  warning: ['var(--warning-soft)', 'var(--warning)'],
  success: ['var(--success-soft)', 'var(--success)'],
  danger: ['var(--danger-soft)', 'var(--danger)'],
  teal: ['var(--teal-soft)', 'var(--teal)'],
  purple: ['var(--purple-soft)', 'var(--purple)'],
  orange: ['var(--orange-soft)', 'var(--orange)'],
}

export function StatCard({
  icon: Icon,
  value,
  label,
  hint,
  tone = 'ink',
}: {
  icon: LucideIcon
  value: ReactNode
  label: string
  hint?: string
  tone?: Tone
}) {
  const [bg, fg] = TONES[tone]
  return (
    <div className="stat">
      <div className="stat-icon" style={{ background: bg, color: fg }}>
        <Icon size={16} strokeWidth={2} />
      </div>
      <div>
        <div className="stat-value">{value}</div>
        <div className="stat-label">{label}</div>
        {hint && <div className="stat-hint">{hint}</div>}
      </div>
    </div>
  )
}

export function Tabs({
  tabs,
  value,
  onChange,
  count,
}: {
  tabs: string[]
  value: string
  onChange?: (t: string) => void
  count?: ReactNode
}) {
  return (
    <div className="tabs">
      {tabs.map((t) => (
        <button key={t} type="button" className={cn('tab', value === t && 'is-active')} onClick={() => onChange?.(t)}>
          {t}
        </button>
      ))}
      {count != null && <span className="badge badge-brand">{count}</span>}
    </div>
  )
}

export function SearchInput({
  placeholder = 'Search',
  value,
  onChange,
  width = 240,
}: {
  placeholder?: string
  value: string
  onChange: (v: string) => void
  width?: number
}) {
  return (
    <div className="input-wrap" style={{ width }}>
      <Search size={15} />
      <input
        className="input input-sm"
        type="search"
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  )
}

export function Empty({ icon: Icon = Inbox, children }: { icon?: LucideIcon; children: ReactNode }) {
  return (
    <div className="empty">
      <Icon size={28} />
      <div>{children}</div>
    </div>
  )
}

export type Column<T> = { key: string; label: string; render: (row: T) => ReactNode; align?: 'right' }

/** Table with the kit's "Showing x–y of n" footer and pager. `bare`: no card around it (inside a .panel). */
export function DataTable<T extends { id: string }>({
  columns,
  rows,
  empty = 'Nothing here yet.',
  pageSize = 10,
  onRowClick,
  bare,
}: {
  columns: Column<T>[]
  rows: T[]
  empty?: ReactNode
  pageSize?: number
  onRowClick?: (row: T) => void
  bare?: boolean
}) {
  const [page, setPage] = useState(1)
  const pages = Math.max(1, Math.ceil(rows.length / pageSize))
  const current = Math.min(page, pages)
  const slice = rows.slice((current - 1) * pageSize, current * pageSize)
  return (
    <div className={bare ? undefined : 'card'}>
      {rows.length === 0 ? (
        <Empty>{empty}</Empty>
      ) : (
        <>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  {columns.map((c) => (
                    <th key={c.key} style={c.align ? { textAlign: c.align } : undefined}>
                      {c.label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {slice.map((r) => (
                  <tr
                    key={r.id}
                    onClick={onRowClick ? () => onRowClick(r) : undefined}
                    className={onRowClick ? 'is-clickable' : undefined}
                  >
                    {columns.map((c) => (
                      <td key={c.key} style={c.align ? { textAlign: c.align } : undefined}>
                        {c.render(r)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="table-foot">
            <span>
              Showing {(current - 1) * pageSize + 1}–{Math.min(current * pageSize, rows.length)} of {rows.length}
            </span>
            <div className="pager">
              <button type="button" onClick={() => setPage(Math.max(1, current - 1))} aria-label="Previous">
                <ChevronLeft size={14} />
              </button>
              {Array.from({ length: pages }, (_, i) => i + 1).map((n) => (
                <button key={n} type="button" className={n === current ? 'is-active' : ''} onClick={() => setPage(n)}>
                  {n}
                </button>
              ))}
              <button type="button" onClick={() => setPage(Math.min(pages, current + 1))} aria-label="Next">
                <ChevronRight size={14} />
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  )
}

/** Small centred confirm box ("Ready to leave?"). */
export function ConfirmModal({
  open,
  icon: Icon,
  title,
  message,
  confirmLabel = 'Confirm',
  danger,
  busy,
  onConfirm,
  onCancel,
}: {
  open: boolean
  icon?: LucideIcon
  title: ReactNode
  message: ReactNode
  confirmLabel?: string
  danger?: boolean
  busy?: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  return (
    <Modal open={open} onClose={onCancel}>
      {Icon && (
        <div
          className="modal-icon"
          style={danger ? { background: 'var(--danger-soft)', color: 'var(--danger)' } : undefined}
        >
          <Icon size={22} />
        </div>
      )}
      <h3>{title}</h3>
      <p>{message}</p>
      <div className="modal-actions">
        <button type="button" className="btn btn-outline" onClick={onCancel}>
          Cancel
        </button>
        <button
          type="button"
          className={cn('btn', danger ? 'btn-danger' : 'btn-primary')}
          disabled={busy}
          onClick={onConfirm}
        >
          {confirmLabel}
        </button>
      </div>
    </Modal>
  )
}
