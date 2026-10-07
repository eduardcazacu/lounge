import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    react(),
    // Only the precache list is generated; the worker is ours, in src/sw.ts,
    // and it must keep being served as /sw.js so existing installs update in
    // place with their push subscriptions. Both webmanifests stay hand-written
    // in public/, and main.tsx registers the worker. See wiki/web-client.md.
    VitePWA({
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.ts',
      manifest: false,
      injectRegister: false,
      // `npm run dev` serves the worker too, as /dev-sw.js, so push still
      // works locally. It precaches nothing there; see src/sw.ts.
      devOptions: { enabled: true, type: 'module' },
      injectManifest: {
        globPatterns: ['**/*.{js,css,html,webmanifest,ico}', '*icon*.png', 'topbar-logo.png'],
      },
    }),
  ],
  build: {
    rollupOptions: {
      // Two pages, one app. books.html differs only in its <head> — the
      // manifest and icon a phone installs for /books. vercel.json routes
      // /books there. See wiki/books.md.
      input: {
        main: 'index.html',
        books: 'books.html',
      },
    },
  },
})
