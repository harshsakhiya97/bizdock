import { useContext } from 'react'
import { AuthContext } from './auth-context'

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>')
  return ctx
}

export function displayName(name: string | null | undefined, email: string | null | undefined) {
  return name?.trim() || email?.split('@')[0] || 'User'
}
