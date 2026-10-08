import { createContext } from 'react'
import type { Session, User } from '@supabase/supabase-js'

export type Profile = {
  id: string
  email: string | null
  full_name: string | null
  phone: string | null
}

export type AuthState = {
  session: Session | null
  user: User | null
  profile: Profile | null
  /** true when this login is a BizDock platform owner */
  isOwner: boolean
  loading: boolean
  /** set when someone without owner access tried to log in */
  accessError: string | null
  refreshProfile: () => Promise<void>
  signOut: () => Promise<void>
}

export const AuthContext = createContext<AuthState | undefined>(undefined)
