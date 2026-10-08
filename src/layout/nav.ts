import { Building2, LayoutGrid, Sparkles, User, type LucideIcon } from 'lucide-react'

export type NavItem = { to: string; label: string; icon: LucideIcon }

export const navSections: { title: string; items: NavItem[] }[] = [
  { title: 'General', items: [{ to: '/dashboard', label: 'Dashboard', icon: LayoutGrid }] },
  { title: 'Platform', items: [{ to: '/clients', label: 'Clients', icon: Building2 }] },
  { title: 'Account', items: [{ to: '/profile', label: 'My Profile', icon: User }] },
]

type Meta = { title: string; crumb: string; icon: LucideIcon }

/** Top bar title + breadcrumb for each page. */
export const pageMeta: Record<string, Meta> = {
  '/dashboard': { title: 'Dashboard', crumb: 'Overview', icon: LayoutGrid },
  '/clients': { title: 'Clients', crumb: 'Overview', icon: Building2 },
  '/profile': { title: 'My Profile', crumb: 'Overview', icon: User },
  '/whats-new': { title: "What's New", crumb: 'Version history', icon: Sparkles },
}

export function metaFor(pathname: string): Meta {
  if (pageMeta[pathname]) return pageMeta[pathname]
  if (pathname.startsWith('/clients/')) return { title: 'Clients', crumb: 'Client details', icon: Building2 }
  return pageMeta['/dashboard']
}
