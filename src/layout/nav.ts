import { LayoutGrid, Sparkles, User, type LucideIcon } from 'lucide-react'

export type NavItem = { to: string; label: string; icon: LucideIcon }

export const navSections: { title: string; items: NavItem[] }[] = [
  { title: 'General', items: [{ to: '/dashboard', label: 'Dashboard', icon: LayoutGrid }] },
  { title: 'Account', items: [{ to: '/profile', label: 'My Profile', icon: User }] },
]

/** Top bar title + breadcrumb for each page. */
export const pageMeta: Record<string, { title: string; crumb: string; icon: LucideIcon }> = {
  '/dashboard': { title: 'Dashboard', crumb: 'Overview', icon: LayoutGrid },
  '/profile': { title: 'My Profile', crumb: 'Overview', icon: User },
  '/whats-new': { title: "What's New", crumb: 'Version history', icon: Sparkles },
}
