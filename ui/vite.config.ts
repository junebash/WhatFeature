import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// The server serves the built app at /ui (see "Web UI" in docs/DESIGN.md). In development, `npm run dev` serves it
// with hot reload and forwards API calls to a local server (`just serve`), or to WHATFEATURE_URL as the CLI does, so
// the page and API share an origin just as they do in production.
// 127.0.0.1, not localhost: the server listens on 127.0.0.1, and Node may resolve localhost to ::1.
const server = process.env.WHATFEATURE_URL ?? 'http://127.0.0.1:8080'

export default defineConfig({
  base: '/ui/',
  plugins: [vue()],
  server: {
    proxy: {
      '/admin': server,
      '/health': server,
    },
  },
})
