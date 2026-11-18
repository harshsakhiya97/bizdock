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

// https://vite.dev/config/
export default defineConfig({
  define: { __GIT_BRANCH__: JSON.stringify(branch) },
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': path.resolve(import.meta.dirname, './src') },
  },
})
