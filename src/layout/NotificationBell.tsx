import { useCallback, useRef, useState } from 'react'
import { Bell } from 'lucide-react'
import { useClickOutside } from '@/lib/useClickOutside'

/** Header bell from the theme kit. No notifications are sent yet, so the list is empty. */
export function NotificationBell() {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const close = useCallback(() => setOpen(false), [])
  useClickOutside(ref, open, close)

  return (
    <div className="nb" ref={ref}>
      <button type="button" className="bell" onClick={() => setOpen((o) => !o)} aria-label="Notifications">
        <Bell size={19} />
      </button>
      {open && (
        <div className="nb-menu">
          <div className="nb-head">
            <b>Notifications</b>
          </div>
          <div className="muted small nb-empty">You’re all caught up.</div>
        </div>
      )}
    </div>
  )
}
