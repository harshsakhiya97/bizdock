import { Bug, MinusCircle, Sparkles, TrendingUp } from 'lucide-react'
import { PageHead } from '@/components/ui'
import { releases, type Release } from '@/data/releases'

const GROUPS = [
  { key: 'new', label: 'New', icon: Sparkles, tone: 'info' },
  { key: 'improved', label: 'Improved', icon: TrendingUp, tone: 'success' },
  { key: 'fixed', label: 'Fixed', icon: Bug, tone: 'warning' },
  { key: 'removed', label: 'Removed', icon: MinusCircle, tone: 'muted' },
] as const satisfies readonly { key: keyof Release; label: string; icon: unknown; tone: string }[]

const fmt = (d: string) =>
  new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'long', year: 'numeric' })

export function WhatsNewPage() {
  return (
    <>
      <PageHead title="What's New" subtitle="Every version of the BizDock app and what it added." />
      <div className="wn-timeline">
        {releases.map((r, i) => (
          <article key={r.version} className="wn-item">
            <span className="wn-dot" aria-hidden />
            <div className="wn-card">
              <div className="wn-head">
                <span className="wn-version">Version {r.version}</span>
                {i === 0 && <span className="badge badge-success">Current</span>}
                <span className="muted small">{fmt(r.date)}</span>
              </div>
              <h3 className="wn-title">{r.title}</h3>
              {r.summary && <p className="wn-summary">{r.summary}</p>}
              {GROUPS.filter((g) => r[g.key]?.length).map(({ key, label, icon: Icon, tone }) => (
                <section key={key} className="wn-group">
                  <span className={`wn-tag wn-tag-${tone}`}>
                    <Icon size={14} /> {label}
                  </span>
                  <ul>
                    {r[key]?.map((line) => (
                      <li key={line}>{line}</li>
                    ))}
                  </ul>
                </section>
              ))}
            </div>
          </article>
        ))}
      </div>
    </>
  )
}
