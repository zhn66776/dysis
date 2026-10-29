import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import { readFileSync, existsSync } from 'node:fs'
import { resolve, basename } from 'node:path'

// The app serves provider marks from Resources/ProviderIcons at icons/.
// Mirror that in the dev server so the browser preview shows real icons.
function providerIcons(): Plugin {
  const dir = resolve(import.meta.dirname, '../Resources/ProviderIcons')
  return {
    name: 'agentdesk-provider-icons',
    configureServer(server) {
      server.middlewares.use('/icons', (req, res, next) => {
        const file = resolve(dir, basename(req.url ?? ''))
        if (!file.endsWith('.svg') || !existsSync(file)) return next()
        res.setHeader('Content-Type', 'image/svg+xml')
        res.end(readFileSync(file))
      })
    },
  }
}

export default defineConfig({
  base: './',
  plugins: [react(), providerIcons()],
  build: { outDir: 'dist', emptyOutDir: true, sourcemap: false, chunkSizeWarningLimit: 1000 },
  server: { host: '127.0.0.1', port: 5174 },
})
