// github: the Git graph page (What's new → Git graph) — branches, commits of the last 30 days, merges and version tags
// of BizDock's two repos, read through GitHub's API with a read-only token (secret GITHUB_TOKEN).
//
//   POST { action: 'graph', repo: 'tenant' | 'admin' }       → { branches, commits, tags, compare }
//   POST { action: 'commit', repo, sha }                      → one commit's files
//
// Only platform owners and a workspace's owner / support logins (public.can_see_dev()). Answers are kept a minute.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (message: string, status = 400) => json({ error: message }, status)

const REPOS: Record<string, string> = { tenant: 'harshsakhiya97/bizdock-tenant', admin: 'harshsakhiya97/bizdock' }
const DAYS = 30
/** branches compared with each other: ahead / behind these */
const BASES = ['deploy/pride', 'main']

const cache = new Map<string, { at: number; body: unknown }>()

async function gh(path: string) {
  const token = (Deno.env.get('GITHUB_TOKEN') ?? '').trim()
  if (!token) throw new Error('The GitHub token isn’t set yet (Supabase secret GITHUB_TOKEN).')
  const res = await fetch(`https://api.github.com${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'bizdock' },
  })
  const body = await res.json().catch(() => ({}))
  if (res.status === 401) throw new Error('GitHub refused the token (expired or wrong).')
  if (res.status === 404) throw new Error('GitHub: not found — does the token have read access to this repo?')
  if (!res.ok) throw new Error(`GitHub: ${body?.message ?? res.status}`)
  return body
}

type GhCommit = {
  sha: string
  parents: { sha: string }[]
  html_url: string
  commit: { message: string; author: { name: string; date: string }; committer: { date: string } }
  author: { login: string; avatar_url: string } | null
}

async function graph(repo: string) {
  const r = REPOS[repo]
  const since = new Date(Date.now() - DAYS * 86_400_000).toISOString()
  const branches = (await gh(`/repos/${r}/branches?per_page=100`)) as { name: string; commit: { sha: string } }[]
  const tags = ((await gh(`/repos/${r}/tags?per_page=50`)) as { name: string; commit: { sha: string } }[]).map((t) => ({ name: t.name, sha: t.commit.sha }))
  const commits = new Map<string, Record<string, unknown>>()
  const tips: { name: string; sha: string; date: string | null; login: string | null; avatar: string | null; name_author: string | null }[] = []
  for (const b of branches) {
    let tip: GhCommit | null = null
    for (let page = 1; page <= 5; page++) {
      const list = (await gh(`/repos/${r}/commits?sha=${encodeURIComponent(b.name)}&since=${since}&per_page=100&page=${page}`)) as GhCommit[]
      for (const c of list) {
        if (!tip) tip = c
        if (!commits.has(c.sha))
          commits.set(c.sha, {
            sha: c.sha,
            parents: c.parents.map((p) => p.sha),
            message: c.commit.message,
            date: c.commit.committer?.date ?? c.commit.author?.date,
            author: c.commit.author?.name ?? '',
            login: c.author?.login ?? null,
            avatar: c.author?.avatar_url ?? null,
            url: c.html_url,
          })
      }
      if (list.length < 100) break
    }
    if (!tip) {
      // no commit in 30 days: its tip, for the card
      const c = (await gh(`/repos/${r}/commits/${b.commit.sha}`)) as GhCommit
      tip = c
    }
    tips.push({
      name: b.name,
      sha: b.commit.sha,
      date: tip?.commit.committer?.date ?? null,
      login: tip?.author?.login ?? null,
      avatar: tip?.author?.avatar_url ?? null,
      name_author: tip?.commit.author?.name ?? null,
    })
  }
  // each branch against deploy/pride and main
  const names = new Set(branches.map((b) => b.name))
  const compare: Record<string, Record<string, { ahead: number; behind: number }>> = {}
  for (const b of branches) {
    for (const base of BASES) {
      if (!names.has(base) || base === b.name) continue
      try {
        const c = await gh(`/repos/${r}/compare/${encodeURIComponent(base)}...${encodeURIComponent(b.name)}`)
        ;(compare[b.name] ??= {})[base] = { ahead: Number(c.ahead_by) || 0, behind: Number(c.behind_by) || 0 }
      } catch {
        // skip
      }
    }
  }
  const list = [...commits.values()].sort((a, b) => String(b.date).localeCompare(String(a.date)))
  return { repo: r, since, branches: tips, commits: list, tags, compare }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail('Use POST', 405)
  const asCaller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: me } = await asCaller.auth.getUser()
  if (!me.user) return fail('Please log in again.', 401)
  const { data: ok } = await asCaller.rpc('can_see_dev')
  if (!ok) return fail('Only owners and support can see this.', 403)

  const b = (await req.json().catch(() => ({}))) as Record<string, unknown>
  const repo = String(b.repo ?? 'tenant')
  if (!REPOS[repo]) return fail('Unknown repo')
  try {
    if (b.action === 'commit') {
      const sha = String(b.sha ?? '')
      if (!/^[0-9a-f]{7,40}$/i.test(sha)) return fail('Bad commit')
      const key = `c:${repo}:${sha}`
      const hit = cache.get(key)
      if (hit) return json(hit.body)
      const c = await gh(`/repos/${REPOS[repo]}/commits/${sha}`)
      const body = {
        sha: c.sha,
        message: c.commit?.message ?? '',
        stats: c.stats ?? null,
        files: ((c.files ?? []) as Record<string, unknown>[]).map((f) => ({ name: f.filename, status: f.status, add: f.additions, del: f.deletions })),
      }
      cache.set(key, { at: Date.now(), body })
      return json(body)
    }
    const key = `g:${repo}`
    const hit = cache.get(key)
    if (hit && Date.now() - hit.at < 60_000 && !b.fresh) return json(hit.body)
    const body = await graph(repo)
    cache.set(key, { at: Date.now(), body })
    return json(body)
  } catch (e) {
    return fail((e as Error).message, 502)
  }
})
