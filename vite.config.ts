import { execSync } from 'node:child_process'
import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// the git branch this app was built / started from (What's new → Git graph marks it as Current)
let branch = ''
try {
  branch = execSync('git branch --show-current', { cwd: import.meta.dirname }).toString().trim()
} catch {
  branch = ''
}

// dev: the branch right now (after a git checkout, without restarting the dev server)
const liveBranch = {
  name: 'bizdock-git-branch',
  configureServer(server: { middlewares: { use: (fn: (req: { url?: string }, res: { setHeader: (k: string, v: string) => void; end: (s: string) => void }, next: () => void) => void) => void } }) {
    server.middlewares.use((req, res, next) => {
      if (!req.url?.split('?')[0].endsWith('/__git_branch')) return next()
      let b = ''
      try {
        b = execSync('git branch --show-current', { cwd: import.meta.dirname }).toString().trim()
      } catch {
        b = ''
      }
      res.setHeader('Content-Type', 'text/plain')
      res.end(b)
    })
  },
}

// https://vite.dev/config/
export default defineConfig({
  define: { __GIT_BRANCH__: JSON.stringify(branch) },
  plugins: [react(), tailwindcss(), liveBranch],
  resolve: {
    alias: { '@': path.resolve(import.meta.dirname, './src') },
  },
})
