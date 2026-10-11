import { useState } from 'react'
import { LogOut } from 'lucide-react'
import { useNavigate } from 'react-router'
import { useAuth } from '@/auth/useAuth'
import { ConfirmModal } from './ui'

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
    <ConfirmModal
      open={open}
      icon={LogOut}
      title="Ready to leave?"
      message="Are you sure you want to log out?"
      confirmLabel={busy ? 'Logging out…' : 'Yes, Logout'}
      busy={busy}
      onCancel={onClose}
      onConfirm={confirm}
    />
  )
}
