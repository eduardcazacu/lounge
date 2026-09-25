import React from 'react'
import ReactDOM from 'react-dom/client'
import { Analytics } from "@vercel/analytics/react"
import { SpeedInsights } from "@vercel/speed-insights/react"
import App from './App.tsx'
import './index.css'
import { APP_NAME } from './config'
import { initializeAxiosAuth } from './lib/auth'

document.title = APP_NAME;
initializeAxiosAuth();

// A tab opened before a deploy still names the previous build's page chunks,
// and Vercel serves only the current build's files, so opening a page that tab
// has not loaded yet would fail. Reloading fetches the current build. This is
// the handler Vite documents for exactly this case.
window.addEventListener("vite:preloadError", (event) => {
  event.preventDefault();
  window.location.reload();
});

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js");
  });
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
    <Analytics />
    <SpeedInsights />
  </React.StrictMode>,
)
