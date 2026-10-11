import { useEffect, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { X } from 'lucide-react'
import { cn } from '@/lib/cn'

/**
 * Theme-kit pop-up.
 * - With `title`: .modal-lg with sticky .modal-head (title + close), scrolling .modal-body, sticky .modal-foot.
 * - Without `title`: the small centred .modal box.
 */
export function Modal({
  open,
  onClose,
  children,
  width,
  title,
  footer,
  className,
}: {
  open: boolean
  onClose: () => void
  children: ReactNode
  /** max width in px (default: 360 small, 760 with a title) */
  width?: number
  title?: string
  footer?: ReactNode
  className?: string
}) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      // an open search dropdown handles Esc itself
      if (e.key === 'Escape' && !document.querySelector('[data-popover]')) onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null
  // Rendered into <body> so no parent (sticky sidebar, cards) can sit on top of it.
  return createPortal(
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div
        role="dialog"
        data-modal
        aria-modal="true"
        aria-label={title}
        className={cn('modal', title && 'modal-lg', className)}
        style={width ? { maxWidth: width } : undefined}
        onMouseDown={(e) => e.stopPropagation()}
      >
        {title ? (
          <>
            <div className="modal-head">
              <h3>{title}</h3>
              <button type="button" className="btn btn-ghost btn-icon" onClick={onClose} aria-label="Close">
                <X size={18} />
              </button>
            </div>
            <div className="modal-body">{children}</div>
            {footer && <div className="modal-foot">{footer}</div>}
          </>
        ) : (
          children
        )}
      </div>
    </div>,
    document.body,
  )
}
