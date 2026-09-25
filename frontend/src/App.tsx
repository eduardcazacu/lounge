import { lazy, Suspense, useEffect, useState } from 'react'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { Signup } from './pages/Signup'
import { Signin } from './pages/Signin'
import { getAuthHeader, refreshAccessToken } from './lib/auth'
import { enablePushIfPermissionGranted } from './lib/push'
import { NotificationPrompt } from './components/NotificationPrompt'
import { ChatDrawer } from './components/ChatDrawer'

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

function App() {
  useEffect(() => {
    let cancelled = false;

    const bootstrap = async () => {
      await refreshAccessToken();
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
        void refreshAccessToken();
      }
    };

    window.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      cancelled = true;
      window.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, []);

  return (
    <>
      <BrowserRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
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
          <Route path="/admin" element={<Admin />} />
          <Route path="/verify-email" element={<VerifyEmail />} />
          <Route path="/privacy" element={<Privacy />} />
          <Route path="/terms" element={<Terms />} />
          <Route path="/support" element={<Support />} />
        </Routes>
        </Suspense>
        <NotificationPrompt />
        <ChatDrawer />
      </BrowserRouter>
    </>
  )
}

export default App
