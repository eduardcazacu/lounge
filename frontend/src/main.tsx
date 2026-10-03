import React from 'react'
import ReactDOM from 'react-dom/client'
import { Analytics } from "@vercel/analytics/react"
import { SpeedInsights } from "@vercel/speed-insights/react"
import { PersistQueryClientProvider } from '@tanstack/react-query-persist-client'
import App from './App.tsx'
import './index.css'
import { APP_NAME } from './config'
import { initializeAxiosAuth } from './lib/auth'
import { persistOptions, queryClient } from './lib/query'

document.title = APP_NAME;
initializeAxiosAuth();

// A tab opened before a deploy still names the previous build's page chunks,
// and neither Vercel nor the service worker's precache, which a new worker
// prunes as it takes over, still has them, so opening a page that tab has not
// loaded yet would fail. Reloading fetches the current build. This is
// the handler Vite documents for exactly this case.
window.addEventListener("vite:preloadError", (event) => {
  event.preventDefault();
  window.location.reload();
});

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    // vite-plugin-pwa serves the dev build of src/sw.ts under its own name,
    // as a module; production's is /sw.js, as it always was.
    void (import.meta.env.DEV
      ? navigator.serviceWorker.register("/dev-sw.js?dev-sw", { type: "module" })
      : navigator.serviceWorker.register("/sw.js"));
  });
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <PersistQueryClientProvider client={queryClient} persistOptions={persistOptions}>
      <App />
    </PersistQueryClientProvider>
    <Analytics />
    <SpeedInsights />
  </React.StrictMode>,
)
