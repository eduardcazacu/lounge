import { lazy, Suspense, useEffect, useState } from 'react'
import { createBrowserRouter, Navigate, Route, RouterProvider, Routes, ScrollRestoration, useLocation, type Location } from 'react-router-dom'
import { Signup } from './pages/Signup'
import { Signin } from './pages/Signin'
import { getAuthHeader, refreshAccessToken, refreshAccessTokenIfStale } from './lib/auth'
import { enablePushIfPermissionGranted } from './lib/push'
import { NotificationPrompt } from './components/NotificationPrompt'

// Every page but the two a signed-out visitor lands on is fetched the first
// time it is opened. Bundled together the app was one file of over 600 kB,
// and somebody signing in was downloading the admin panel, the editor and
// Instant's camera and crypto before seeing a form. A page's code arrives
// with its first visit instead; `vite:preloadError` in `main.tsx` covers a tab
// left open across a deploy, whose old chunk names no longer exist.
const Blog = lazy(() => import('./pages/Blog').then((m) => ({ default: m.Blog })))
const Blogs = lazy(() => import('./pages/Blogs').then((m) => ({ default: m.Blogs })))
const Publish = lazy(() => import('./pages/Publish').then((m) => ({ default: m.Publish })))
const Account = lazy(() => import('./pages/Account').then((m) => ({ default: m.Account })))
const Instant = lazy(() => import('./pages/Instant').then((m) => ({ default: m.Instant })))
const Books = lazy(() => import('./pages/Books').then((m) => ({ default: m.Books })))
const Admin = lazy(() => import('./pages/Admin').then((m) => ({ default: m.Admin })))
const VerifyEmail = lazy(() => import('./pages/VerifyEmail').then((m) => ({ default: m.VerifyEmail })))
const ForgotPassword = lazy(() => import('./pages/ForgotPassword').then((m) => ({ default: m.ForgotPassword })))
const ResetPassword = lazy(() => import('./pages/ResetPassword').then((m) => ({ default: m.ResetPassword })))
const Privacy = lazy(() => import('./pages/Legal').then((m) => ({ default: m.Privacy })))
const Terms = lazy(() => import('./pages/Legal').then((m) => ({ default: m.Terms })))
const Support = lazy(() => import('./pages/Legal').then((m) => ({ default: m.Support })))

function RootRedirect() {
  const [targetPath, setTargetPath] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    const bootstrap = async () => {
      if (getAuthHeader()) {
        if (active) {
          setTargetPath("/blogs");
        }
        return;
      }

      const refreshedToken = await refreshAccessToken();
      if (!active) {
        return;
      }
      setTargetPath(refreshedToken ? "/blogs" : "/signin");
    };

    void bootstrap();
    return () => {
      active = false;
    };
  }, []);

  if (!targetPath) {
    return <div className="min-h-screen bg-slate-100" />;
  }

  return <Navigate to={targetPath} replace />;
}

// The Lounge's push banner, kept off /books, which is a standalone app with
// its own way back (wiki/books.md): the banner would sit over its bottom tabs.
function LoungeChrome() {
  const location = useLocation();
  if (location.pathname === "/books" || location.pathname.startsWith("/books/")) {
    return null;
  }
  return <NotificationPrompt />;
}

function App() {
  useEffect(() => {
    let cancelled = false;

    const bootstrap = async () => {
      await refreshAccessTokenIfStale();
      if (cancelled) return;
      const authHeader = getAuthHeader();
      if (!authHeader) return;
      try {
        await enablePushIfPermissionGranted(authHeader);
      } catch {
        // Silent re-sync only; user can re-enable from the banner or Account page.
      }
    };

    void bootstrap();

    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        void refreshAccessTokenIfStale();
      }
    };

    window.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      cancelled = true;
      window.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, []);

  return <RouterProvider router={router} future={{ v7_startTransition: true }} />
}

// Books' bottom tabs switch with `replace`, so each would otherwise open at
// its top. Keyed by URL instead, a tab comes back where it was left, as a tab
// bar's would. Everything else is keyed by history entry: a new screen starts
// at the top and Back returns to the place it was left.
const TAB_ROOTS = new Set(['/books', '/books/feed', '/books/library'])
const scrollKey = (location: Location) =>
  TAB_ROOTS.has(location.pathname) ? location.pathname + location.search : location.key

function Root() {
  return (
    <>
      {/* Restores before paint, so a page drawn from the query cache comes
          back at full height; one that draws a skeleton first is clamped to
          the skeleton's height (wiki/gotchas.md). */}
      <ScrollRestoration getKey={scrollKey} />
      {/* Nothing while a page's code arrives: a placeholder in either
          theme would flash against Instant's black or the blog's light. */}
      <Suspense fallback={null}>
        <Routes>
          <Route path="/" element={<RootRedirect />} />
          <Route path="/signup" element={<Signup />} />
          <Route path="/signin" element={<Signin />} />
          <Route path="/forgot-password" element={<ForgotPassword />} />
          <Route path="/reset-password" element={<ResetPassword />} />
          <Route path="/blog/:id" element={<Blog />} />
          <Route path="/blogs" element={<Blogs />} />
          <Route path="/publish" element={<Publish />} />
          <Route path="/account" element={<Account />} />
          <Route path="/instant" element={<Instant />} />
          <Route path="/books/*" element={<Books />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="/verify-email" element={<VerifyEmail />} />
          <Route path="/privacy" element={<Privacy />} />
          <Route path="/terms" element={<Terms />} />
          <Route path="/support" element={<Support />} />
        </Routes>
      </Suspense>
      <LoungeChrome />
    </>
  )
}

// A data router only for ScrollRestoration, which needs one. Every route is
// still a descendant <Routes> under one catch-all, as it was under
// BrowserRouter; nothing here uses loaders.
const router = createBrowserRouter([{ path: '*', element: <Root /> }], {
  future: { v7_relativeSplatPath: true },
})

export default App
