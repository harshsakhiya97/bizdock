import { useState, type FormEvent } from 'react'
import { Navigate, useLocation } from 'react-router'
import { Lock, Mail } from 'lucide-react'
import { useAuth } from '@/auth/useAuth'
import { Label, PasswordInput, TextInput } from '@/components/Field'
import { LogoMark } from '@/components/Logo'
import { Splash } from '@/components/Splash'
import { APP_VERSION } from '@/config'
import { supabase } from '@/lib/supabase'

type Mode = 'login' | 'forgot'

export function LoginPage() {
  const { session, loading, accessError } = useAuth()
  const location = useLocation()
  const from = (location.state as { from?: string } | null)?.from ?? '/dashboard'

  const [mode, setMode] = useState<Mode>('login')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  if (loading) return <Splash />
  if (session) return <Navigate to={from} replace />

  const canSubmit = mode === 'login' ? email.trim() !== '' && password !== '' : email.trim() !== ''

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!canSubmit) return
    setBusy(true)
    setError(null)
    setNotice(null)

    if (mode === 'login') {
      // on success the auth provider checks owner access, then <Navigate> above redirects
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
      if (error) setError(error.message)
    } else {
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/profile?tab=password`,
      })
      if (error) setError(error.message)
      else setNotice('If this email has an account, a reset link is on its way. Open it to set a new password.')
    }
    setBusy(false)
  }

  function switchMode(next: Mode) {
    setMode(next)
    setError(null)
    setNotice(null)
  }

  const titles: Record<Mode, [string, string]> = {
    login: ['Log in to your account', 'Welcome back! Please enter your details.'],
    forgot: ['Reset your password', "Enter your email and we'll send a reset link."],
  }
  const shownError = error ?? accessError

  return (
    <div className="auth">
      <div className="auth-form-side">
        <form className="auth-form" onSubmit={onSubmit}>
          <div className="auth-logo">
            <LogoMark size={84} />
            <div className="brand-name">
              BizDock
              <span>Business Suite</span>
            </div>
          </div>
          <div className="auth-title">
            <h1>{titles[mode][0]}</h1>
            <p>{titles[mode][1]}</p>
          </div>

          <div>
            <Label htmlFor="email" required>
              Email ID
            </Label>
            <TextInput
              id="email"
              type="email"
              autoComplete="email"
              placeholder="Enter Email ID"
              icon={<Mail />}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoFocus
            />
          </div>
          {mode === 'login' && (
            <div>
              <Label htmlFor="password" required>
                Password
              </Label>
              <PasswordInput
                id="password"
                autoComplete="current-password"
                placeholder="Enter Password"
                icon={<Lock />}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </div>
          )}
          {mode === 'login' && (
            <button type="button" className="auth-forgot" onClick={() => switchMode('forgot')}>
              Forgot Password?
            </button>
          )}

          {shownError && <div className="alert alert-error">{shownError}</div>}
          {notice && <div className="alert alert-info">{notice}</div>}

          <button type="submit" className="btn btn-primary btn-block" disabled={!canSubmit || busy}>
            {busy ? 'Please wait…' : mode === 'login' ? 'Login' : 'Send Reset Link'}
          </button>

          {mode === 'forgot' && (
            <div className="auth-switch">
              <button type="button" onClick={() => switchMode('login')}>
                Back to login
              </button>
            </div>
          )}
          <div className="auth-version">Version {APP_VERSION}</div>
        </form>
      </div>

      <div className="auth-art" aria-hidden="true">
        <LogoMark size={44} className="auth-art-logo" />
        <div className="preview">
          <div className="preview-side">
            <div className="row" style={{ gap: 6, marginBottom: 8 }}>
              <LogoMark size={22} />
              <b style={{ fontSize: 10, letterSpacing: '.04em' }}>BIZDOCK</b>
            </div>
            <div className="ph" style={{ width: '70%' }} />
            <div className="ph active" />
            <div className="ph" style={{ width: '80%' }} />
            <div className="ph" style={{ width: '60%' }} />
            <div className="ph" style={{ width: '75%' }} />
            <div className="ph" style={{ width: '50%' }} />
          </div>
          <div className="preview-main">
            <h4>Highlights</h4>
            <div className="preview-stats">
              <div>
                <small>Leads</small>
                <b>—</b>
              </div>
              <div>
                <small>Payments</small>
                <b>—</b>
              </div>
              <div>
                <small>Profit</small>
                <b>—</b>
              </div>
            </div>
            <div className="preview-bars">
              <h5>Overview</h5>
              {[92, 70, 64, 45, 30].map((w) => (
                <div key={w} className="preview-bar">
                  <span />
                  <i style={{ width: `${w}%` }} />
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
