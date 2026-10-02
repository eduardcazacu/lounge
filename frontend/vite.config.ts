import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
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
