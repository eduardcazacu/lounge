// Which of the three apps was open last, so a launch from the home screen
// returns to it. iOS throws an idle PWA out of memory and relaunches it at the
// manifest's start_url, `/`, which would otherwise always mean the feed. Only
// the app is kept, never the screen inside it: a book page or an open instant
// is a deep link that may be gone by the next launch, and an app's front page
// never is.
const KEY = "lastApp";
const APPS = ["/blogs", "/books", "/instant"] as const;

export function rememberApp(pathname: string) {
  const app =
    pathname === "/books" || pathname.startsWith("/books/") ? "/books"
    : pathname === "/instant" ? "/instant"
    : pathname === "/blogs" || pathname.startsWith("/blog/") ? "/blogs"
    : null;
  if (!app) return;
  try {
    localStorage.setItem(KEY, app);
  } catch {
    // Storage blocked: every launch opens the feed, as it always did.
  }
}

export function lastApp(): string {
  try {
    const app = localStorage.getItem(KEY);
    if (app && (APPS as readonly string[]).includes(app)) return app;
  } catch {
    // Fall through to the feed.
  }
  return "/blogs";
}
