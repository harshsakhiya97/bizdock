import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import { ArrowLeft, ExternalLink, GitBranch, GitCommitHorizontal, RefreshCw, Tag } from 'lucide-react'
import { PageHead } from '@/components/ui'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/cn'

/**
 * What's new → Git graph: the two repos' branches, commits of the last 30 days, merges and version tags, read live from
 * GitHub (edge function github). For owners / support, to see which branch each developer is on.
 */
type Repo = 'tenant' | 'admin'
type Commit = { sha: string; parents: string[]; message: string; date: string; author: string; login: string | null; avatar: string | null; url: string }
type Branch = { name: string; sha: string; date: string | null; login: string | null; avatar: string | null; name_author: string | null }
type Graph = {
  repo: string
  since: string
  branches: Branch[]
  commits: Commit[]
  tags: { name: string; sha: string }[]
  compare: Record<string, Record<string, { ahead: number; behind: number }>>
}
type Files = { files: { name: string; status: string; add: number; del: number }[]; stats: { additions: number; deletions: number } | null }

const call = async <T,>(body: Record<string, unknown>): Promise<T> => {
  const { data, error } = await supabase.functions.invoke('github', { body })
  if (error) {
    const ctx = (error as { context?: Response }).context
    const msg = ctx ? await ctx.json().then((j) => j?.error).catch(() => null) : null
    throw new Error(msg || error.message)
  }
  if (data?.error) throw new Error(data.error)
  return data as T
}

const COLORS = ['#2563eb', '#16a34a', '#d97706', '#7c3aed', '#db2777', '#0891b2', '#dc2626', '#65a30d', '#9333ea', '#0d9488']
const ROW = 52
const LANE = 18
const PAD = 14
const when = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }) : '—'
function ago(iso: string | null) {
  if (!iso) return ''
  const m = Math.round((Date.now() - Date.parse(iso)) / 60_000)
  if (m < 60) return `${Math.max(1, m)} min ago`
  const h = Math.round(m / 60)
  if (h < 24) return `${h} h ago`
  const d = Math.round(h / 24)
  return `${d} day${d > 1 ? 's' : ''} ago`
}
const firstLine = (m: string) => m.split('\n')[0]

/** each commit's lane: the first-parent line of each branch (main, deploy/pride, then the newest), then merged-away branches */
function layout(g: Graph) {
  const bySha = new Map(g.commits.map((c) => [c.sha, c]))
  const lane = new Map<string, string>()
  const order = [...g.branches].sort((a, b) => {
    const rank = (n: string) => (n === 'main' ? 0 : n === 'deploy/pride' ? 1 : 2)
    return rank(a.name) - rank(b.name) || String(b.date ?? '').localeCompare(String(a.date ?? ''))
  })
  const lanes: { id: string; label: string }[] = []
  const walk = (start: string, id: string) => {
    let s: string | undefined = start
    let n = 0
    while (s && bySha.has(s) && !lane.has(s)) {
      lane.set(s, id)
      n++
      s = bySha.get(s)!.parents[0]
    }
    return n
  }
  for (const b of order) if (walk(b.sha, b.name)) lanes.push({ id: b.name, label: b.name })
  for (const c of g.commits) {
    if (lane.has(c.sha)) continue
    const merge = g.commits.find((m) => m.parents[1] === c.sha)
    const label = merge?.message.match(/Merge branch '([^']+)'/)?.[1] ?? merge?.message.match(/from [^/\s]+\/(\S+)/)?.[1] ?? 'merged branch'
    const id = `x:${c.sha}`
    walk(c.sha, id)
    lanes.push({ id, label })
  }
  const col = new Map(lanes.map((l, i) => [l.id, i]))
  const row = new Map(g.commits.map((c, i) => [c.sha, i]))
  return { lane, lanes, col, row, bySha }
}

export function GitGraphPage() {
  // the admin app: platform owners only
  const dev = true
  const [repo, setRepo] = useState<Repo>('tenant')
  const [g, setG] = useState<Graph | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [open, setOpen] = useState<string | null>(null)
  const [files, setFiles] = useState<Record<string, Files | 'loading' | string>>({})

  const load = useCallback(
    (fresh = false) => {
      setLoading(true)
      setError(null)
      call<Graph>({ action: 'graph', repo, fresh })
        .then(setG, (e) => {
          setG(null)
          setError((e as Error).message)
        })
        .finally(() => setLoading(false))
    },
    [repo],
  )
  useEffect(() => {
    setOpen(null)
    if (dev) load()
  }, [load, dev])

  const L = useMemo(() => (g ? layout(g) : null), [g])
  const tagsOf = useMemo(() => {
    const m = new Map<string, string[]>()
    for (const t of g?.tags ?? []) m.set(t.sha, [...(m.get(t.sha) ?? []), t.name])
    return m
  }, [g])
  const tipsOf = useMemo(() => {
    const m = new Map<string, string[]>()
    for (const b of g?.branches ?? []) m.set(b.sha, [...(m.get(b.sha) ?? []), b.name])
    return m
  }, [g])
  const color = (id: string) => COLORS[(L?.col.get(id) ?? 0) % COLORS.length]
  const branchColor = (name: string) => (L?.col.has(name) ? color(name) : '#94a3b8')

  function toggle(c: Commit) {
    const next = open === c.sha ? null : c.sha
    setOpen(next)
    if (next && !files[c.sha]) {
      setFiles((f) => ({ ...f, [c.sha]: 'loading' }))
      call<Files>({ action: 'commit', repo, sha: c.sha }).then(
        (r) => setFiles((f) => ({ ...f, [c.sha]: r })),
        (e) => setFiles((f) => ({ ...f, [c.sha]: (e as Error).message })),
      )
    }
  }

  // every line of the graph: a commit to each of its parents (rows from → to); an older parent: a short dashed line
  const edges = useMemo(() => {
    if (!g || !L) return []
    const xOf = (sha: string) => PAD + (L.col.get(L.lane.get(sha) ?? '') ?? 0) * LANE
    const out: { key: string; from: number; to: number; ax: number; px: number; merge: boolean; color: string; dashed?: boolean }[] = []
    g.commits.forEach((c, ai) => {
      c.parents.forEach((p, pi) => {
        const pr = L.row.get(p)
        const cl = COLORS[(L.col.get(L.lane.get(c.sha) ?? '') ?? 0) % COLORS.length]
        if (pr == null) {
          if (pi === 0) out.push({ key: `${c.sha}-${p}`, from: ai, to: ai, ax: xOf(c.sha), px: xOf(c.sha), merge: false, color: cl, dashed: true })
          return
        }
        const merge = pi > 0
        const pc = COLORS[(L.col.get(L.lane.get(p) ?? '') ?? 0) % COLORS.length]
        out.push({ key: `${c.sha}-${p}`, from: ai, to: pr, ax: xOf(c.sha), px: xOf(p), merge, color: merge ? pc : cl })
      })
    })
    return out
  }, [g, L])
  const branches = useMemo(() => [...(g?.branches ?? [])].sort((a, b) => String(b.date ?? '').localeCompare(String(a.date ?? ''))), [g])
  const width = PAD * 2 + Math.max(1, L?.lanes.length ?? 1) * LANE

  return (
    <>
      <PageHead
        title="Git graph"
        subtitle="Branches, commits of the last 30 days, merges and the deployed versions — live from GitHub."
        actions={
          <div className="row" style={{ gap: 8 }}>
            <Link to="/whats-new" className="btn btn-outline btn-sm">
              <ArrowLeft size={15} /> What's new
            </Link>
            <button type="button" className="btn btn-outline btn-sm" onClick={() => load(true)} disabled={loading}>
              <RefreshCw size={15} className={loading ? 'spin' : undefined} /> Refresh
            </button>
          </div>
        }
      />
      <div className="seg" role="tablist" style={{ marginBottom: 16 }}>
        {(['tenant', 'admin'] as Repo[]).map((r) => (
          <button key={r} type="button" role="tab" aria-selected={repo === r} className={repo === r ? 'is-active' : ''} onClick={() => setRepo(r)}>
            {r === 'tenant' ? 'Tenant app (bizdock-tenant)' : 'Admin repo (bizdock)'}
          </button>
        ))}
      </div>

      {error && <div className="card" style={{ padding: 16, color: "var(--danger)" }}>{error}</div>}
      {!g && !error && <div className="card muted" style={{ padding: 24 }}>{loading ? 'Loading from GitHub…' : ''}</div>}

      {g && L && (
        <>
          <h3 className="gg-h">Currently working on</h3>
          <div className="gg-cards">
            {branches.map((b) => {
              const cmp = g.compare[b.name] ?? {}
              const recent = b.date && Date.now() - Date.parse(b.date) < 30 * 86_400_000
              return (
                <div key={b.name} className={cn('card gg-card', !recent && 'is-old')} style={{ borderTopColor: branchColor(b.name) }}>
                  <div className="gg-branch">
                    <GitBranch size={15} style={{ color: branchColor(b.name) }} /> <b>{b.name}</b>
                  </div>
                  <div className="gg-who">
                    {b.avatar && <img src={b.avatar} alt="" />}
                    <span>{b.login ?? b.name_author ?? '—'}</span>
                  </div>
                  <div className="muted small">
                    Last commit {ago(b.date)} · {when(b.date)}
                  </div>
                  <div className="gg-cmp">
                    {Object.entries(cmp).map(([base, v]) => (
                      <span key={base} className="badge badge-muted" title={`${v.ahead} commits not in ${base}; ${v.behind} commits of ${base} not here`}>
                        vs {base}: ↑{v.ahead} ↓{v.behind}
                      </span>
                    ))}
                  </div>
                </div>
              )
            })}
          </div>

          <h3 className="gg-h">
            Commits <span className="muted small">({g.commits.length} since {new Date(g.since).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })})</span>
          </h3>
          <div className="gg-legend">
            {L.lanes.map((l) => (
              <span key={l.id} className="gg-lane-pill" style={{ ['--c' as string]: color(l.id) }}>
                {l.label}
              </span>
            ))}
          </div>
          <div className="card gg-list">
            {g.commits.length === 0 && <div className="muted" style={{ padding: 16 }}>No commits in the last 30 days.</div>}
            {g.commits.map((c, i) => {
              const id = L.lane.get(c.sha) ?? ''
              const x = PAD + (L.col.get(id) ?? 0) * LANE
              const y = ROW / 2
              const isOpen = open === c.sha
              const f = files[c.sha]
              return (
                <div key={c.sha} className={cn('gg-row-wrap', isOpen && 'is-open')}>
                  <div className="gg-row" onClick={() => toggle(c)} role="button" tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && toggle(c)}>
                    <svg className="gg-svg" width={width} height={ROW} aria-hidden>
                      {/* lines through this row: from each commit above to its parents below */}
                      {edges.map((e) => {
                        if (i < e.from || i > e.to) return null
                        const top = i === e.from ? y : 0
                        const bottom = e.dashed ? ROW : i === e.to ? y : ROW
                        const k = `${e.key}-${i}`
                        if (e.ax === e.px) return <line key={k} x1={e.ax} y1={top} x2={e.ax} y2={bottom} stroke={e.color} strokeWidth={2} strokeDasharray={e.dashed ? '3 3' : undefined} />
                        // a merge bends into the merged lane right below the merge; a branch start bends into its parent's lane
                        if (e.merge) {
                          if (i === e.from) return <path key={k} d={`M${e.ax},${y} C${e.ax},${ROW} ${e.px},${y} ${e.px},${ROW}`} fill="none" stroke={e.color} strokeWidth={2} />
                          return <line key={k} x1={e.px} y1={0} x2={e.px} y2={bottom} stroke={e.color} strokeWidth={2} />
                        }
                        if (i === e.to) return <path key={k} d={`M${e.ax},0 C${e.ax},${y} ${e.px},0 ${e.px},${y}`} fill="none" stroke={e.color} strokeWidth={2} />
                        return <line key={k} x1={e.ax} y1={top} x2={e.ax} y2={ROW} stroke={e.color} strokeWidth={2} />
                      })}
                      <circle cx={x} cy={y} r={c.parents.length > 1 ? 5 : 6} fill={c.parents.length > 1 ? '#fff' : color(id)} stroke={color(id)} strokeWidth={c.parents.length > 1 ? 3 : 2} />
                    </svg>
                    <div className="gg-main">
                      <div className="gg-msg">
                        {(tipsOf.get(c.sha) ?? []).map((b) => (
                          <span key={b} className="gg-ref" style={{ ['--c' as string]: branchColor(b) }}>
                            <GitBranch size={11} /> {b}
                          </span>
                        ))}
                        {(tagsOf.get(c.sha) ?? []).map((t) => (
                          <span key={t} className="gg-ref gg-tag">
                            <Tag size={11} /> {t}
                          </span>
                        ))}
                        <span className={cn(c.parents.length > 1 && 'muted')}>{firstLine(c.message)}</span>
                      </div>
                      <div className="gg-meta muted small">
                        {c.avatar && <img src={c.avatar} alt="" />}
                        {c.login ?? c.author} · {when(c.date)} · <code>{c.sha.slice(0, 7)}</code>
                      </div>
                    </div>
                  </div>
                  {isOpen && (
                    <div className="gg-detail">
                      <pre className="gg-full">{c.message.trim()}</pre>
                      {f === 'loading' && <div className="muted small">Loading files…</div>}
                      {typeof f === 'string' && f !== 'loading' && <div className="muted small">{f}</div>}
                      {f && typeof f === 'object' && (
                        <>
                          <div className="muted small" style={{ marginBottom: 6 }}>
                            <GitCommitHorizontal size={13} /> {f.files.length} file{f.files.length === 1 ? '' : 's'}
                            {f.stats ? ` · +${f.stats.additions} −${f.stats.deletions}` : ''}
                          </div>
                          <ul className="gg-files">
                            {f.files.map((x) => (
                              <li key={x.name}>
                                <span className={`gg-st gg-st-${x.status}`}>{x.status}</span> <code>{x.name}</code>{' '}
                                <span className="gg-add">+{x.add}</span> <span className="gg-del">−{x.del}</span>
                              </li>
                            ))}
                          </ul>
                        </>
                      )}
                      <a className="btn btn-outline btn-sm" href={c.url} target="_blank" rel="noreferrer" style={{ marginTop: 8 }}>
                        <ExternalLink size={14} /> Open on GitHub
                      </a>
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        </>
      )}
    </>
  )
}
