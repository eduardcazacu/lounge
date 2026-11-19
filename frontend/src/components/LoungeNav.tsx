import type { ReactNode } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { getThemePalette } from "../themes";
import { INSTANT_COLORS } from "./instant/style";

// The one way around the Lounge: the feed, Books, Instant and a new post, the
// same four places from every one of them. Each surface mounts it itself rather
// than `App.tsx` mounting it once, because only the surface knows when one of
// its screens needs the whole height — Instant's composer, Books' add and
// finish flows. See wiki/web-client.md.

/** What a page leaves clear at its bottom edge for the bar. */
export const LOUNGE_NAV_SPACE = "calc(3.5rem + env(safe-area-inset-bottom))";

type Section = { to: string; label: string; matches: (path: string) => boolean; icon: ReactNode };

const SECTIONS: Section[] = [
  {
    to: "/blogs",
    label: "Lounge",
    matches: (path) => path === "/blogs" || path.startsWith("/blog/"),
    icon: <path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z" />,
  },
  {
    to: "/books",
    label: "Books",
    matches: (path) => path === "/books" || path.startsWith("/books/"),
    icon: <path d="M2 5.5C4.5 4 8 4 12 6c4-2 7.5-2 10-.5V19c-2.5-1.5-6-1.5-10 .5-4-2-7.5-2-10-.5zM12 6v13.5" />,
  },
  {
    to: "/instant",
    label: "Instant",
    matches: (path) => path === "/instant",
    icon: (
      <>
        <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z" />
        <circle cx="12" cy="13" r="4" />
      </>
    ),
  },
];

export function LoungeNav({ variant = "light" }: { variant?: "light" | "dark" }) {
  const { pathname } = useLocation();
  const navigate = useNavigate();
  const palette = getThemePalette(localStorage.getItem("themeKey"));
  const accent = palette.accent;
  const dark = variant === "dark";
  // The palette's text, not its accent: the grey palette's accent is the
  // same slate an idle item is drawn in, and the current place vanished.
  // The same pair as Books' sections, so the two read as one system.
  const idle = dark ? INSTANT_COLORS.secondaryText : "#94a3b8";
  const active = dark ? INSTANT_COLORS.primaryText : palette.text;

  return (
    <nav
      className={`fixed inset-x-0 bottom-0 z-40 border-t ${dark ? "border-white/10" : "border-slate-200/70 bg-white/90 backdrop-blur"}`}
      style={{ paddingBottom: "env(safe-area-inset-bottom)", background: dark ? INSTANT_COLORS.background : undefined }}
    >
      <div className="mx-auto grid h-14 max-w-xl grid-cols-4">
        {SECTIONS.map((section) => {
          const isActive = section.matches(pathname);
          return (
            <Link
              key={section.to}
              to={section.to}
              onClick={(event) => {
                // The feed's own tab, tapped again, is how to refresh it: the
                // logo in the app bar does the same.
                if (section.to === "/blogs" && pathname === "/blogs") {
                  event.preventDefault();
                  navigate("/blogs", { replace: true, state: { refreshFeedAt: Date.now() } });
                }
              }}
              aria-current={isActive ? "page" : undefined}
              className="flex flex-col items-center justify-center gap-0.5 text-[11px] font-medium"
              style={{ color: isActive ? active : idle }}
            >
              <svg viewBox="0 0 24 24" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round">
                {section.icon}
              </svg>
              {section.label}
            </Link>
          );
        })}
        <Link
          to="/publish"
          aria-label="New post"
          className="flex flex-col items-center justify-center gap-0.5 text-[11px] font-medium"
          style={{ color: idle }}
        >
          <span className="flex h-7 w-10 items-center justify-center rounded-full text-white" style={{ background: accent }}>
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
              <path d="M12 5v14M5 12h14" />
            </svg>
          </span>
          Post
        </Link>
      </div>
    </nav>
  );
}
