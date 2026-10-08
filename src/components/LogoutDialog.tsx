import { useState } from 'react'
import { LogOut } from 'lucide-react'
import { useNavigate } from 'react-router'
import { useAuth } from '@/auth/useAuth'
import { Modal } from './Modal'

export function LogoutDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { signOut } = useAuth()
  const navigate = useNavigate()
  const [busy, setBusy] = useState(false)

  async function confirm() {
    setBusy(true)
    await signOut()
    setBusy(false)
    onClose()
    navigate('/login', { replace: true })
  }

  return (
    <Modal open={open} onClose={onClose}>
      <div className="text-center">
        <div className="mx-auto mb-4 grid size-12 place-items-center rounded-full bg-brand-soft text-brand">
          <LogOut className="size-5" />
        </div>
        <h2 className="text-lg font-bold">Ready to leave?</h2>
        <p className="mt-1 text-sm text-gray-500">Are you sure you want to log out?</p>
        <div className="mt-6 grid grid-cols-2 gap-3">
          <button
            onClick={onClose}
            className="h-10 rounded-lg border border-gray-300 text-sm font-semibold hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            onClick={confirm}
            disabled={busy}
            className="h-10 rounded-lg bg-brand text-sm font-semibold text-white hover:bg-brand-hover disabled:opacity-60"
          >
            {busy ? 'Logging out…' : 'Yes, Logout'}
          </button>
        </div>
      </div>
    </Modal>
  )
}
