import { useState, type FormEvent } from 'react'
import { useSearchParams } from 'react-router'
import { LogOut } from 'lucide-react'
import { displayName, useAuth } from '@/auth/useAuth'
import { Avatar } from '@/components/Avatar'
import { Label, PasswordInput, TextInput } from '@/components/Field'
import { LogoutDialog } from '@/components/LogoutDialog'
import { cn } from '@/lib/cn'
import { supabase } from '@/lib/supabase'

type Tab = 'profile' | 'password'
type Msg = { error?: string; ok?: string }

const tabs: { id: Tab; label: string }[] = [
  { id: 'profile', label: 'My Profile' },
  { id: 'password', label: 'Reset Password' },
]

export function ProfilePage() {
  const [params, setParams] = useSearchParams()
  const tab: Tab = params.get('tab') === 'password' ? 'password' : 'profile'

  return (
    <div className="settings">
      <nav className="settings-nav">
        <div className="label">SETTINGS</div>
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            className={cn(tab === t.id && 'is-active')}
            onClick={() => setParams(t.id === 'profile' ? {} : { tab: t.id })}
          >
            {t.label}
          </button>
        ))}
      </nav>
      <div className="settings-body">{tab === 'profile' ? <ProfileView /> : <ResetPasswordView />}</div>
    </div>
  )
}

function ProfileView() {
  const { profile, user, refreshProfile } = useAuth()
  const [editing, setEditing] = useState(false)
  const [logoutOpen, setLogoutOpen] = useState(false)
  const [fullName, setFullName] = useState('')
  const [phone, setPhone] = useState('')
  const [msg, setMsg] = useState<Msg>({})
  const [busy, setBusy] = useState(false)
  const name = displayName(profile?.full_name, user?.email)

  function startEdit() {
    setFullName(profile?.full_name ?? '')
    setPhone(profile?.phone ?? '')
    setMsg({})
    setEditing(true)
  }

  async function save(e: FormEvent) {
    e.preventDefault()
    if (!profile) return
    if (!fullName.trim()) return setMsg({ error: 'User name is required.' })
    setBusy(true)
    const { error } = await supabase
      .from('profiles')
      .update({ full_name: fullName.trim(), phone: phone.trim() || null })
      .eq('id', profile.id)
    setBusy(false)
    if (error) return setMsg({ error: error.message })
    await refreshProfile()
    setEditing(false)
    setMsg({ ok: 'Profile updated.' })
  }

  return (
    <>
      <h2 style={{ fontSize: 16 }}>My Profile</h2>
      <Avatar name={name} size={72} />
      {editing ? (
        <form className="stack" style={{ maxWidth: 360 }} onSubmit={save}>
          <div>
            <Label htmlFor="full_name" required>
              User Name
            </Label>
            <TextInput id="full_name" value={fullName} onChange={(e) => setFullName(e.target.value)} autoFocus />
          </div>
          <div>
            <Label htmlFor="phone">Phone</Label>
            <TextInput id="phone" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </div>
          <div className="row">
            <button type="submit" className="btn btn-dark" disabled={busy}>
              {busy ? 'Saving…' : 'Save'}
            </button>
            <button type="button" className="btn btn-outline" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </form>
      ) : (
        <>
          <dl className="kv">
            <dt>User Name</dt>
            <dd>{name}</dd>
            <dt>Email ID</dt>
            <dd>{profile?.email ?? user?.email ?? '—'}</dd>
            <dt>Phone</dt>
            <dd>{profile?.phone || '—'}</dd>
            <dt>My Role</dt>
            <dd>
              <span className="badge badge-brand">Owner</span>
            </dd>
          </dl>
          <div className="profile-actions">
            <button type="button" className="btn btn-dark" onClick={startEdit} disabled={!profile}>
              Edit Profile
            </button>
            <button type="button" className="btn btn-outline danger-text" onClick={() => setLogoutOpen(true)}>
              <LogOut size={15} /> Logout
            </button>
          </div>
        </>
      )}
      {msg.error && <div className="alert alert-error">{msg.error}</div>}
      {msg.ok && <div className="alert alert-info">{msg.ok}</div>}
      <LogoutDialog open={logoutOpen} onClose={() => setLogoutOpen(false)} />
    </>
  )
}

function ResetPasswordView() {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [msg, setMsg] = useState<Msg>({})
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (password.length < 6) return setMsg({ error: 'Password must be at least 6 characters.' })
    if (password !== confirm) return setMsg({ error: "Passwords don't match." })
    setBusy(true)
    const { error } = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (error) return setMsg({ error: error.message })
    setPassword('')
    setConfirm('')
    setMsg({ ok: 'Password updated.' })
  }

  return (
    <>
      <h2 style={{ fontSize: 16 }}>Reset Password</h2>
      <form className="stack" style={{ maxWidth: 320 }} onSubmit={submit}>
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
        {msg.error && <div className="alert alert-error">{msg.error}</div>}
        {msg.ok && <div className="alert alert-info">{msg.ok}</div>}
        <div>
          <button type="submit" className="btn btn-dark" disabled={busy}>
            {busy ? 'Updating…' : 'Update Password'}
          </button>
        </div>
      </form>
    </>
  )
}
