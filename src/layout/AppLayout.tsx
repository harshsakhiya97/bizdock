import { useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router'
import { LogOut, Menu, PanelLeft } from 'lucide-react'
import { displayName, useAuth } from '@/auth/useAuth'
import { Avatar } from '@/components/Avatar'
import { LogoLockup } from '@/components/Logo'
import { LogoutDialog } from '@/components/LogoutDialog'
import { APP_VERSION } from '@/config'
import { cn } from '@/lib/cn'
import { NotificationBell } from './NotificationBell'
import { metaFor, navSections, tabNames } from './nav'

const STORAGE_KEY = 'bizdock.sidebarCollapsed'

function readCollapsed() {
  try {
    return localStorage.getItem(STORAGE_KEY) === '1'
  } catch {
    return false
  }
}

/** Theme-kit app shell: sidebar, top bar with crumbs, page area and the phone tab bar. */
export function AppLayout() {
  const { pathname } = useLocation()
  const { profile, user } = useAuth()
  const [collapsed, setCollapsed] = useState(readCollapsed)
  const [mobileOpen, setMobileOpen] = useState(false)
  const [logoutOpen, setLogoutOpen] = useState(false)
  const meta = metaFor(pathname)
  const Icon = meta.icon
  const name = displayName(profile?.full_name, user?.email)
  const email = profile?.email ?? user?.email ?? ''

  const sections = navSections
  const tabs = sections.flatMap((s) => s.items).filter((i) => tabNames[i.to])

  function toggle() {
    setCollapsed((c) => {
      try {
        localStorage.setItem(STORAGE_KEY, c ? '0' : '1')
      } catch {
        /* storage unavailable */
      }
      return !c
    })
  }

  return (
    <div className="shell">
      <aside className={cn('sidebar', collapsed && 'is-collapsed', mobileOpen && 'is-open')}>
        <div className="sidebar-brand">
          <LogoLockup />
          <button type="button" className="btn btn-ghost btn-icon" onClick={toggle} aria-label="Toggle sidebar">
            <PanelLeft size={18} />
          </button>
        </div>

        <nav className="sidebar-nav">
          {sections.map((section) => (
            <div key={section.title}>
              <div className="nav-section-label">{section.title}</div>
              {section.items.map(({ to, label, icon: I }) => (
                <NavLink key={to} to={to} className="nav-item" title={label} onClick={() => setMobileOpen(false)}>
                  <I size={17} strokeWidth={1.9} />
                  <span className="nav-text">{label}</span>
                </NavLink>
              ))}
            </div>
          ))}
        </nav>

        <div className="sidebar-user">
          <Avatar name={name} size={32} />
          <div className="user-meta">
            <b>{name}</b>
            <small>{email}</small>
          </div>
          <button
            type="button"
            className="btn btn-ghost btn-icon"
            onClick={() => setLogoutOpen(true)}
            aria-label="Log out"
          >
            <LogOut size={16} />
          </button>
        </div>
        <NavLink to="/whats-new" className="sidebar-version" onClick={() => setMobileOpen(false)}>
          Version {APP_VERSION} · What’s new
        </NavLink>
      </aside>

      {mobileOpen && <div className="sidebar-overlay" onClick={() => setMobileOpen(false)} />}

      <div className="main">
        <header className="topbar">
          <div className="crumbs">
            <button
              type="button"
              className="btn btn-ghost btn-icon menu-btn"
              onClick={() => setMobileOpen((o) => !o)}
              aria-label="Menu"
            >
              <Menu size={18} />
            </button>
            <Icon size={19} />
            <h1>{meta.title}</h1>
            <span className="sep">/</span>
            <small>{meta.crumb}</small>
          </div>
          <div className="topbar-right">
            <NotificationBell />
          </div>
        </header>

        <main className="page">
          <Outlet />
        </main>
      </div>

      {/* phone: app-style tab bar */}
      <nav className="tabbar" aria-label="Main" style={{ gridTemplateColumns: `repeat(${tabs.length}, 1fr)` }}>
        {tabs.map(({ to, icon: I }) => (
          <NavLink key={to} to={to} className="tabbar-item">
            <I size={21} />
            <span>{tabNames[to]}</span>
          </NavLink>
        ))}
      </nav>

      <LogoutDialog open={logoutOpen} onClose={() => setLogoutOpen(false)} />
    </div>
  )
}
