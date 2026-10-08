import { useEffect, useRef, useState } from 'react'
import { Bell } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

export function TopBar({ title, crumb, icon: Icon }: { title: string; crumb: string; icon: LucideIcon }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [open])

  return (
    <header className="sticky top-0 z-30 flex h-[58px] shrink-0 items-center justify-between border-b border-gray-200 bg-white px-6">
      <div className="flex items-center gap-2.5">
        <Icon className="size-[19px] text-gray-800" strokeWidth={1.9} />
        <h1 className="text-[19px] font-bold tracking-tight">{title}</h1>
        <span className="text-gray-300">/</span>
        <span className="text-[13px] text-gray-500">{crumb}</span>
      </div>

      <div ref={ref} className="relative">
        <button
          onClick={() => setOpen((o) => !o)}
          aria-label="Notifications"
          className="grid size-9 place-items-center rounded-lg text-gray-700 hover:bg-gray-100"
        >
          <Bell className="size-[19px]" strokeWidth={1.8} />
        </button>
        {open && (
          <div className="absolute top-11 right-0 w-[360px] rounded-xl border border-gray-200 bg-white shadow-lg">
            <div className="border-b border-gray-200 px-4 py-3 text-[15px] font-bold">Notifications</div>
            <div className="px-4 py-10 text-center text-sm text-gray-500">No notifications yet.</div>
          </div>
        )}
      </div>
    </header>
  )
}
