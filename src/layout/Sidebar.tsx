import { useState } from 'react'
import { Link, NavLink, useLocation } from 'react-router'
import { LogOut, PanelLeft } from 'lucide-react'
import { displayName, useAuth } from '@/auth/useAuth'
import { Avatar } from '@/components/Avatar'
import { LogoLockup } from '@/components/Logo'
import { LogoutDialog } from '@/components/LogoutDialog'
import { APP_VERSION } from '@/config'
import { cn } from '@/lib/cn'
import { navSections } from './nav'

export function Sidebar({ collapsed, onToggle }: { collapsed: boolean; onToggle: () => void }) {
  const { profile, user } = useAuth()
  const { pathname } = useLocation()
  const [logoutOpen, setLogoutOpen] = useState(false)
  const name = displayName(profile?.full_name, user?.email)
  const email = profile?.email ?? user?.email ?? ''

  return (
    <aside
      className={cn(
        'sticky top-0 flex h-svh shrink-0 flex-col border-r border-gray-200 bg-white transition-[width] duration-200',
        collapsed ? 'w-[68px]' : 'w-[238px]',
      )}
    >
      {/* header */}
      <div className={cn('flex h-[58px] items-center', collapsed ? 'justify-center' : 'justify-between px-3.5')}>
        {!collapsed && <LogoLockup />}
        <button
          onClick={onToggle}
          aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          className="grid size-9 place-items-center rounded-lg text-gray-600 hover:bg-gray-100"
        >
          <PanelLeft className="size-[18px]" />
        </button>
      </div>

      {/* nav */}
      <nav className={cn('flex-1 overflow-y-auto', collapsed ? 'pt-2' : 'pt-4')}>
        {navSections.map((section) => (
          <div key={section.title} className={cn(!collapsed && 'mb-3')}>
            {!collapsed && (
              <div className="px-4 pb-2 text-[11px] font-bold tracking-wider text-gray-900 uppercase">
                {section.title}
              </div>
            )}
            {section.items.map(({ to, label, icon: Icon }) => (
              <NavLink
                key={to}
                to={to}
                title={collapsed ? label : undefined}
                className={({ isActive }) =>
                  cn(
                    'flex h-[38px] items-center gap-3 text-[14px] font-medium transition-colors',
                    collapsed ? 'justify-center' : 'px-4',
                    isActive ? 'bg-brand text-white' : 'text-gray-800 hover:bg-gray-50',
                  )
                }
              >
                <Icon className="size-[17px]" strokeWidth={1.9} />
                {!collapsed && label}
              </NavLink>
            ))}
          </div>
        ))}
      </nav>

      {/* footer */}
      <div className={cn('border-t border-gray-200', collapsed ? 'grid justify-items-center gap-2 py-3' : 'px-3.5 py-3')}>
        {collapsed ? (
          <>
            <Avatar name={name} />
            <button
              onClick={() => setLogoutOpen(true)}
              aria-label="Log out"
              className="grid size-8 place-items-center rounded-md text-gray-600 hover:bg-gray-100"
            >
              <LogOut className="size-4" />
            </button>
          </>
        ) : (
          <>
            <div className="flex items-center gap-2.5">
              <Avatar name={name} />
              <div className="min-w-0 flex-1 leading-tight">
                <div className="truncate text-sm font-semibold">{name}</div>
                <div className="truncate text-xs text-gray-500">{email}</div>
              </div>
              <button
                onClick={() => setLogoutOpen(true)}
                aria-label="Log out"
                className="grid size-8 place-items-center rounded-md text-gray-600 hover:bg-gray-100"
              >
                <LogOut className="size-4" />
              </button>
            </div>
            <Link
              to="/whats-new"
              className={cn(
                'mt-2 block pl-[42px] text-[11px] hover:text-brand',
                pathname === '/whats-new' ? 'text-brand' : 'text-gray-500',
              )}
            >
              Version {APP_VERSION} · What&apos;s new
            </Link>
          </>
        )}
      </div>

      <LogoutDialog open={logoutOpen} onClose={() => setLogoutOpen(false)} />
    </aside>
  )
}
