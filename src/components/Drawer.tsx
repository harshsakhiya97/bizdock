import { useEffect, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { X } from 'lucide-react'

/** Theme-kit right-side slide-over panel (Add / Edit forms). */
export function Drawer({
  open,
  onClose,
  title,
  children,
  footer,
  width = 620,
}: {
  open: boolean
  onClose: () => void
  title: string
  children: ReactNode
  footer?: ReactNode
  width?: number
}) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      // a pop-up open on top of the drawer handles Esc itself
      if (e.key === 'Escape' && !document.querySelector('[data-modal], [data-popover]')) onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null
  return createPortal(
    <div className="drawer-backdrop" onMouseDown={onClose}>
      <aside
        className="drawer"
        style={{ width: `min(${width}px, 100vw)` }}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="drawer-head">
          <h3>{title}</h3>
          <button type="button" className="btn btn-ghost btn-icon" onClick={onClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>
        <div className="drawer-body">{children}</div>
        {footer && <div className="drawer-foot">{footer}</div>}
      </aside>
    </div>,
    document.body,
  )
}
