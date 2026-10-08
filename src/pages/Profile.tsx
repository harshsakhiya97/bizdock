import { useState, type FormEvent, type ReactNode } from 'react'
import { useSearchParams } from 'react-router'
import { LogOut } from 'lucide-react'
import { displayName, useAuth } from '@/auth/useAuth'
import { Avatar } from '@/components/Avatar'
import { Label, PasswordInput, TextInput } from '@/components/Field'
import { LogoutDialog } from '@/components/LogoutDialog'
import { Modal } from '@/components/Modal'
import { cn } from '@/lib/cn'
import { supabase } from '@/lib/supabase'

type Tab = 'profile' | 'password'

export function ProfilePage() {
  const [params, setParams] = useSearchParams()
  const tab: Tab = params.get('tab') === 'password' ? 'password' : 'profile'

  const tabs: { id: Tab; label: string }[] = [
    { id: 'profile', label: 'My Profile' },
    { id: 'password', label: 'Reset Password' },
  ]

  return (
    <div className="flex min-h-[416px] overflow-hidden rounded-xl border border-gray-200 bg-white">
      <aside className="w-[200px] shrink-0 border-r border-gray-200 p-2.5">
        <div className="px-2 pt-2 pb-3 text-[11px] font-bold tracking-wider text-brand uppercase">Settings</div>
        {tabs.map((t) => (
          <button
            key={t.id}
            onClick={() => setParams(t.id === 'profile' ? {} : { tab: t.id })}
            className={cn(
              'mb-1 block w-full rounded-md px-2.5 py-2 text-left text-sm',
              tab === t.id ? 'bg-brand-soft font-semibold text-gray-900' : 'text-gray-700 hover:bg-gray-50',
            )}
          >
            {t.label}
          </button>
        ))}
      </aside>
      <section className="flex-1 p-6">{tab === 'profile' ? <ProfileDetails /> : <ResetPassword />}</section>
    </div>
  )
}

function ProfileDetails() {
  const { profile, user } = useAuth()
  const [editOpen, setEditOpen] = useState(false)
  const [logoutOpen, setLogoutOpen] = useState(false)
  const name = displayName(profile?.full_name, user?.email)

  const rows: [string, ReactNode][] = [
    ['User Name', name],
    ['Email ID', profile?.email ?? user?.email ?? '—'],
    ['Phone', profile?.phone || '—'],
    [
      'My Role',
      <span key="role" className="rounded-full bg-brand-soft px-2.5 py-0.5 text-xs font-semibold text-brand">
        Owner
      </span>,
    ],
  ]

  return (
    <div>
      <h2 className="text-lg font-semibold">My Profile</h2>
      <Avatar name={name} size={72} className="mt-4" />

      <dl className="mt-6 grid grid-cols-[140px_1fr] items-center gap-y-3 text-sm">
        {rows.map(([label, value]) => (
          <div key={label} className="contents">
            <dt className="text-gray-500">{label}</dt>
            <dd className="text-gray-900">{value}</dd>
          </div>
        ))}
      </dl>

      <div className="mt-7 flex flex-col items-start gap-3">
        <button
          onClick={() => setEditOpen(true)}
          disabled={!profile}
          className="h-9 rounded-lg bg-navy px-4 text-sm font-semibold text-white hover:bg-navy-hover disabled:opacity-50"
        >
          Edit Profile
        </button>
        <button
          onClick={() => setLogoutOpen(true)}
          className="inline-flex h-9 items-center gap-2 rounded-lg border border-gray-300 px-4 text-sm font-semibold text-brand hover:bg-gray-50"
        >
          <LogOut className="size-4" /> Logout
        </button>
      </div>

      {profile && <EditProfileModal open={editOpen} onClose={() => setEditOpen(false)} />}
      <LogoutDialog open={logoutOpen} onClose={() => setLogoutOpen(false)} />
    </div>
  )
}

function EditProfileModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { profile, refreshProfile } = useAuth()
  const [fullName, setFullName] = useState(profile?.full_name ?? '')
  const [phone, setPhone] = useState(profile?.phone ?? '')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!profile) return
    setBusy(true)
    setError(null)
    const { error } = await supabase
      .from('profiles')
      .update({ full_name: fullName.trim() || null, phone: phone.trim() || null })
      .eq('id', profile.id)
    setBusy(false)
    if (error) return setError(error.message)
    await refreshProfile()
    onClose()
  }

  return (
    <Modal open={open} onClose={onClose}>
      <h2 className="text-lg font-bold">Edit Profile</h2>
      <form onSubmit={onSubmit} className="mt-4 space-y-4">
        <div>
          <Label htmlFor="full_name" required>
            User Name
          </Label>
          <TextInput id="full_name" value={fullName} onChange={(e) => setFullName(e.target.value)} required />
        </div>
        <div>
          <Label htmlFor="phone">Phone</Label>
          <TextInput id="phone" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
        </div>
        {error && <p className="text-sm text-red-600">{error}</p>}
        <div className="grid grid-cols-2 gap-3 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="h-10 rounded-lg border border-gray-300 text-sm font-semibold hover:bg-gray-50"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={busy}
            className="h-10 rounded-lg bg-brand text-sm font-semibold text-white hover:bg-brand-hover disabled:opacity-60"
          >
            {busy ? 'Saving…' : 'Save'}
          </button>
        </div>
      </form>
    </Modal>
  )
}

function ResetPassword() {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setSuccess(false)
    if (password.length < 6) return setError('Password must be at least 6 characters.')
    if (password !== confirm) return setError('Passwords do not match.')
    setBusy(true)
    const { error } = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (error) return setError(error.message)
    setPassword('')
    setConfirm('')
    setSuccess(true)
  }

  return (
    <div>
      <h2 className="text-lg font-semibold">Reset Password</h2>
      <form onSubmit={onSubmit} className="mt-4 max-w-[318px] space-y-5">
        <div>
          <Label htmlFor="new_password" required>
            New Password
          </Label>
          <PasswordInput
            id="new_password"
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <div>
          <Label htmlFor="confirm_password" required>
            Confirm Password
          </Label>
          <PasswordInput
            id="confirm_password"
            autoComplete="new-password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
          />
        </div>
        {error && <p className="text-sm text-red-600">{error}</p>}
        {success && <p className="text-sm text-emerald-700">Password updated.</p>}
        <button
          type="submit"
          disabled={busy}
          className="h-9 rounded-lg bg-navy px-4 text-sm font-semibold text-white hover:bg-navy-hover disabled:opacity-50"
        >
          {busy ? 'Updating…' : 'Update Password'}
        </button>
      </form>
    </div>
  )
}
