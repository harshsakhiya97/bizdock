import { CalendarClock, TrendingUp, Users, Wallet, type LucideIcon } from 'lucide-react'
import { displayName, useAuth } from '@/auth/useAuth'
import { PageHead, StatCard, type Tone } from '@/components/ui'

// Placeholder cards — values show "—" until real data is connected.
const stats: { label: string; icon: LucideIcon; tone: Tone }[] = [
  { label: 'Leads', icon: Users, tone: 'info' },
  { label: 'Follow-ups', icon: CalendarClock, tone: 'warning' },
  { label: 'Payments', icon: Wallet, tone: 'success' },
  { label: 'Profit', icon: TrendingUp, tone: 'purple' },
]

export function DashboardPage() {
  const { profile, user } = useAuth()
  const name = displayName(profile?.full_name, user?.email)

  return (
    <>
      <PageHead
        title={`Welcome, ${name}`}
        subtitle="Here's an overview of your businesses."
      />
      <div className="stat-grid">
        {stats.map((s) => (
          <StatCard key={s.label} icon={s.icon} tone={s.tone} value="—" label={s.label} />
        ))}
      </div>
    </>
  )
}
