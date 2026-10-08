import { CalendarClock, TrendingUp, Users, Wallet, type LucideIcon } from 'lucide-react'
import { displayName, useAuth } from '@/auth/useAuth'

type Stat = { label: string; icon: LucideIcon; tint: string }

// Placeholder cards — values show "—" until real data is connected.
const stats: Stat[] = [
  { label: 'Leads', icon: Users, tint: 'bg-blue-50 text-blue-600' },
  { label: 'Follow-ups', icon: CalendarClock, tint: 'bg-amber-50 text-amber-600' },
  { label: 'Payments', icon: Wallet, tint: 'bg-emerald-50 text-emerald-600' },
  { label: 'Profit', icon: TrendingUp, tint: 'bg-violet-50 text-violet-600' },
]

export function DashboardPage() {
  const { profile, user } = useAuth()
  const name = displayName(profile?.full_name, user?.email)

  return (
    <div>
      <h2 className="text-lg font-semibold">Welcome, {name}</h2>
      <p className="mt-0.5 text-sm text-gray-600">Here's an overview of your businesses.</p>

      <div className="mt-4 grid grid-cols-[repeat(auto-fill,minmax(158px,1fr))] gap-4">
        {stats.map(({ label, icon: Icon, tint }) => (
          <div key={label} className="rounded-xl border border-gray-200 bg-white p-4">
            <div className={`grid size-8 place-items-center rounded-lg ${tint}`}>
              <Icon className="size-4" strokeWidth={2} />
            </div>
            <div className="mt-3 text-2xl font-bold tracking-tight">—</div>
            <div className="text-sm text-gray-600">{label}</div>
          </div>
        ))}
      </div>
    </div>
  )
}
