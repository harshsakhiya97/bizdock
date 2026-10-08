import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { AuthContext, type Profile } from './auth-context'

const NO_ACCESS = 'This account does not have access to the BizDock admin panel.'

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [isOwner, setIsOwner] = useState(false)
  const [loading, setLoading] = useState(true)
  const [accessError, setAccessError] = useState<string | null>(null)

  /** Loads profile + owner flag. Signs out anyone who isn't a platform owner. */
  const loadUser = useCallback(async (next: Session | null) => {
    if (!next) {
      setProfile(null)
      setIsOwner(false)
      setSession(null)
      return
    }
    const userId = next.user.id
    const [{ data: prof }, { data: owner }] = await Promise.all([
      supabase.from('profiles').select('id, email, full_name, phone').eq('id', userId).maybeSingle(),
      supabase.from('platform_owners').select('user_id').eq('user_id', userId).maybeSingle(),
    ])
    if (!owner) {
      setAccessError(NO_ACCESS)
      await supabase.auth.signOut()
      setProfile(null)
      setIsOwner(false)
      setSession(null)
      return
    }
    setAccessError(null)
    setProfile((prof as Profile | null) ?? null)
    setIsOwner(true)
    setSession(next)
  }, [])

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      await loadUser(data.session)
      setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((event, next) => {
      if (event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED') {
        if (next) setSession(next)
        return
      }
      // run outside the auth callback (Supabase recommendation)
      setTimeout(() => void loadUser(next), 0)
    })
    return () => sub.subscription.unsubscribe()
  }, [loadUser])

  const value = useMemo(
    () => ({
      session,
      user: session?.user ?? null,
      profile,
      isOwner,
      loading,
      accessError,
      refreshProfile: () => loadUser(session),
      signOut: async () => {
        await supabase.auth.signOut()
      },
    }),
    [session, profile, isOwner, loading, accessError, loadUser],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
