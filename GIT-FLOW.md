# BizDock — branches, work and deploy flow

Two developers work on BizDock at the same time. Same flow in **both repos**:
`bizdock-tenant` (the app) and `bizdock` (admin app, Supabase migrations and edge functions).

## Branches

| Branch | Who | What it is |
|---|---|---|
| `dev_harsh` | Harsh | Harsh's daily work |
| `dev_shyam` | Shyam | Shyam's daily work |
| `deploy/pride` | common | Both dev branches merge here; Pride is deployed from it; version tags (`v0.20`…) are on it |
| `main` | common | A copy of what's live (updated after each deploy). A new client's branch is made from `main` |

Never commit straight to `deploy/pride` or `main`.

## Golden rule: always pull before you merge

Before merging into `deploy/pride` (and before starting work each day), **always take a fresh pull first** — the other
developer may have merged since your last pull:

```bash
git fetch origin
git checkout deploy/pride && git pull          # the latest common branch
git checkout dev_<you> && git pull && git merge origin/deploy/pride   # their work into yours; fix clashes here
```

Only then merge your branch into `deploy/pride`. Merging into a stale `deploy/pride` makes the push fail, or worse,
deploys without the other developer's latest work.

## Daily

1. **Start of the day** — bring in what the other merged:
   ```bash
   git checkout dev_<you>
   git pull
   git merge origin/deploy/pride
   ```
2. **Work** — commit and push to your own branch only (`git push origin dev_<you>`).

## Save / deploy

1. Bring your branch up to date: `git merge origin/deploy/pride` (fix any clashes on your branch).
2. Merge into the common branch:
   ```bash
   git checkout deploy/pride && git pull
   git merge --no-edit dev_<you>
   npx tsc -b && npx vite build      # must pass
   git push
   ```
3. Release notes: add the version's entries to `src/data/releases.ts` (both repos). One person writes a version's notes,
   or fix the clash by hand at merge time.
4. Tag and deploy (from `deploy/pride`):
   ```bash
   git tag -f vX.YY
   # bizdock-tenant
   git push -f origin vX.YY && npm run deploy
   # bizdock (admin)
   git push -f origin vX.YY
   ```
5. Make `main` the copy of what's live: `git push origin deploy/pride:main`

## The database and edge functions don't follow branches

- **Migrations go live the moment they're applied** (one Supabase project), whichever branch you're on.
  - Only *add* things (new tables, columns, RPCs, new versions of functions).
  - Tell the other developer before changing or removing anything that's already used.
  - Migration file names are timestamps (`YYYYMMDDHHMMSS_name.sql`); use the real time so they stay in order.
- **Edge functions**: deploy only from `deploy/pride` (after the merge), never from a dev branch, so nobody overwrites
  the other's version:
  ```bash
  npx supabase functions deploy <name> --project-ref tnnjudehqalkgglzkfik --no-verify-jwt
  ```

## Seeing who works where

What's new → **Git graph** (owner / support logins and the admin app): each branch, its last commit and who made it,
how far it is ahead / behind `deploy/pride` and `main`, the commits of the last 30 days, merges and version tags.

## A new client

Make the client's branch from `main` (e.g. `deploy/<client>`), then that client's deploys come from it, the same way
as `deploy/pride`.
