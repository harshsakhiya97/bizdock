import { useState, type FormEvent } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router'
import { ArrowLeft, Lock, Mail } from 'lucide-react'
import { useAuth } from '@/auth/useAuth'
import { Label, PasswordInput, TextInput } from '@/components/Field'
import { LogoMark } from '@/components/Logo'
import { Splash } from '@/components/Splash'
import { APP_VERSION } from '@/config'
import { supabase } from '@/lib/supabase'

type Mode = 'login' | 'forgot'

export function LoginPage() {
  const { session, loading } = useAuth()
  const navigate = useNavigate()
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
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
      if (error) setError(error.message)
      else navigate(from, { replace: true })
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

  return (
    <div className="grid min-h-svh lg:grid-cols-[45fr_55fr]">
      {/* left: form */}
      <div className="flex items-center justify-center px-6 py-12">
        <div className="w-full max-w-[378px]">
          <div className="mb-8 flex flex-col items-center">
            <LogoMark size={84} className="shadow-sm" />
            <div className="mt-3 text-[22px] leading-none font-extrabold tracking-tight">BIZDOCK</div>
            <div className="mt-1.5 text-[10px] font-bold tracking-[0.25em] text-brand">BUSINESS SUITE</div>
          </div>

          <div className="mb-6 text-center">
            <h1 className="text-[22px] font-bold tracking-tight">
              {mode === 'login' ? 'Log in to your account' : 'Forgot your password?'}
            </h1>
            <p className="mt-1 text-sm text-gray-600">
              {mode === 'login'
                ? 'Welcome back! Please enter your details.'
                : "Enter your email and we'll send you a reset link."}
            </p>
          </div>

          <form onSubmit={onSubmit} className="space-y-5">
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
                <div className="mt-3 text-right">
                  <button
                    type="button"
                    onClick={() => switchMode('forgot')}
                    className="text-sm font-semibold text-gray-900 hover:text-brand"
                  >
                    Forgot Password?
                  </button>
                </div>
              </div>
            )}

            {error && <p className="text-sm text-red-600">{error}</p>}
            {notice && <p className="text-sm text-gray-600">{notice}</p>}

            <button
              type="submit"
              disabled={!canSubmit || busy}
              className="h-11 w-full rounded-lg bg-brand text-sm font-semibold text-white transition-colors hover:bg-brand-hover disabled:cursor-not-allowed disabled:bg-brand-muted"
            >
              {busy ? 'Please wait…' : mode === 'login' ? 'Login' : 'Send reset link'}
            </button>

            {mode === 'forgot' && (
              <button
                type="button"
                onClick={() => switchMode('login')}
                className="mx-auto flex items-center gap-1.5 text-sm font-semibold text-gray-700 hover:text-brand"
              >
                <ArrowLeft className="size-4" /> Back to login
              </button>
            )}
          </form>

          <p className="mt-5 text-center text-xs text-gray-500">Version {APP_VERSION}</p>
        </div>
      </div>

      {/* right: grid panel with preview card */}
      <div
        className="relative hidden items-center overflow-hidden bg-canvas lg:flex"
        style={{
          backgroundImage:
            'linear-gradient(var(--color-grid) 1px, transparent 1px), linear-gradient(90deg, var(--color-grid) 1px, transparent 1px)',
          backgroundSize: '28px 28px',
        }}
      >
        <LogoMark size={44} className="absolute top-5 right-5 shadow-sm" />
        <PreviewCard />
      </div>
    </div>
  )
}

function PreviewCard() {
  return (
    <div className="ml-12 flex w-full translate-x-0 overflow-hidden rounded-l-xl border border-r-0 border-gray-200 bg-white shadow-xl">
      <div className="w-[170px] shrink-0 border-r border-gray-200 p-3">
        <div className="mb-4 flex items-center gap-2">
          <LogoMark size={20} />
          <span className="text-[11px] font-extrabold">BIZDOCK</span>
        </div>
        <div className="mb-4 h-1.5 w-24 rounded-full bg-gray-200" />
        <div className="mb-4 h-5 rounded bg-brand" />
        <div className="space-y-2.5">
          <div className="h-1.5 w-28 rounded-full bg-gray-200" />
          <div className="h-1.5 w-20 rounded-full bg-gray-200" />
          <div className="h-1.5 w-24 rounded-full bg-gray-200" />
          <div className="h-1.5 w-16 rounded-full bg-gray-200" />
        </div>
      </div>
      <div className="flex-1 p-4">
        <div className="mb-3 text-[13px] font-bold">Highlights</div>
        <div className="mb-3 grid grid-cols-3 gap-2.5">
          {['Leads', 'Payments', 'Profit'].map((label) => (
            <div key={label} className="rounded-lg border border-gray-200 px-2.5 py-2.5">
              <div className="text-[10px] text-gray-500">{label}</div>
              <div className="mt-1 text-sm font-bold text-gray-700">—</div>
            </div>
          ))}
        </div>
        <div className="rounded-lg border border-gray-200 p-3">
          <div className="mb-2 text-[11px] font-bold">Overview</div>
          <div className="ml-[22%] space-y-1.5">
            {[90, 68, 62, 44, 30].map((w) => (
              <div key={w} className="h-1 rounded-full bg-brand" style={{ width: `${w}%` }} />
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}
