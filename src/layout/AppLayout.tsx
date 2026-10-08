import { useState } from 'react'
import { Outlet, useLocation } from 'react-router'
import { LayoutGrid } from 'lucide-react'
import { pageMeta } from './nav'
import { Sidebar } from './Sidebar'
import { TopBar } from './TopBar'

const STORAGE_KEY = 'bizdock.sidebarCollapsed'

function readCollapsed() {
  try {
    return localStorage.getItem(STORAGE_KEY) === '1'
  } catch {
    return false
  }
}

export function AppLayout() {
  const { pathname } = useLocation()
  const [collapsed, setCollapsed] = useState(readCollapsed)
  const meta = pageMeta[pathname] ?? { title: 'BizDock', crumb: 'Overview', icon: LayoutGrid }

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
    <div className="flex min-h-svh">
      <Sidebar collapsed={collapsed} onToggle={toggle} />
      <div className="flex min-w-0 flex-1 flex-col">
        <TopBar {...meta} />
        <main className="flex-1 px-6 py-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
