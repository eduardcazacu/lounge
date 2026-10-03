import { useEffect, useState } from "react";
import { Link, NavLink, Route, Routes, useLocation } from "react-router-dom";
import { Avatar } from "../BlogCard";
import { getCachedProfile } from "../../lib/auth";
import { Sheet } from "./ui";
import { usePushState } from "./notifications";
import { usePalette } from "./format";
import { HomeScreen } from "./HomeScreen";
import { AddScreen } from "./AddScreen";
import { ItemScreen } from "./ItemScreen";
import { ClubScreen } from "./ClubScreen";
import { FinishScreen } from "./FinishScreen";
import { FeedScreen } from "./FeedScreen";
import { AskScreen } from "./AskScreen";
import { ReviewScreen } from "./ReviewScreen";
import { LibraryScreen } from "./LibraryScreen";
import { StatsScreen } from "./StatsScreen";
import { ImportScreen } from "./ImportScreen";
import { KoreaderScreen } from "./KoreaderScreen";

/**
 * Paints the browser's own furniture in the reader's palette while /books is
 * open, and puts it back after. Installed to an iPhone's home screen, the
 * strip under the clock takes the *document's* background, not the app's — the
 * same thing `useDarkChrome` does for Instant, in the other direction.
 */
function useLightChrome(background: string) {
  useEffect(() => {
    const root = document.documentElement;
    const { body } = document;
    const previous = {
      root: root.style.backgroundColor,
      body: body.style.backgroundColor,
      title: document.title,
    };
    root.style.backgroundColor = background;
    body.style.backgroundColor = background;
    document.title = "Lounge Books";

    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
    const ownsMeta = meta === null;
    const previousContent = meta?.content ?? null;
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "theme-color";
      document.head.appendChild(meta);
    }
    meta.content = background;

    return () => {
      root.style.backgroundColor = previous.root;
      body.style.backgroundColor = previous.body;
      document.title = previous.title;
      if (ownsMeta) meta?.remove();
      else if (meta && previousContent !== null) meta.content = previousContent;
    };
  }, [background]);
}

const TABS = [
  {
    to: "/books",
    label: "Reading",
    end: true,
    icon: <path d="M2 5.5C4.5 4 8 4 12 6c4-2 7.5-2 10-.5V19c-2.5-1.5-6-1.5-10 .5-4-2-7.5-2-10-.5zM12 6v13.5" />,
  },
  {
    to: "/books/feed",
    label: "Feed",
    end: false,
    icon: <path d="M21 11.5a8.4 8.4 0 0 1-9 8.5 8.6 8.6 0 0 1-3.8-.9L3 21l1.9-5.2A8.4 8.4 0 0 1 4 11.5 8.5 8.5 0 0 1 12.5 3h.5a8.5 8.5 0 0 1 8 8z" />,
  },
  {
    to: "/books/library",
    label: "Library",
    end: false,
    icon: <path d="M4 4h4v16H4zM10 4h4v16h-4zM16.5 4.5l3.8-1 3.2 15.5-3.8 1z" />,
  },
];

/** Screens that take the whole height for their own controls hide the tabs. */
function showsTabs(pathname: string) {
  return !/^\/books\/(add|finish\/|import)/.test(pathname);
}

function BottomTabs({ accent }: { accent: string }) {
  return (
    <nav
      className="fixed inset-x-0 bottom-0 z-40 border-t border-slate-200/70 bg-white/90 backdrop-blur"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
    >
      <div className="mx-auto grid h-14 max-w-xl grid-cols-3">
        {TABS.map((tab) => (
          <NavLink
            key={tab.to}
            to={tab.to}
            end={tab.end}
            replace
            className="flex flex-col items-center justify-center gap-0.5 text-[11px] font-medium"
            style={({ isActive }) => ({ color: isActive ? accent : "#64748b" })}
          >
            <svg viewBox="0 0 24 24" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round">
              {tab.icon}
            </svg>
            {tab.label}
          </NavLink>
        ))}
      </div>
    </nav>
  );
}

/** What the avatar opens: the way back to the Lounge, and the account. */
export function AccountButton() {
  const [open, setOpen] = useState(false);
  const [profile, setProfile] = useState(getCachedProfile);
  useEffect(() => {
    const sync = () => setProfile(getCachedProfile());
    window.addEventListener("profile-picture-changed", sync);
    window.addEventListener("storage", sync);
    return () => {
      window.removeEventListener("profile-picture-changed", sync);
      window.removeEventListener("storage", sync);
    };
  }, []);

  return (
    <>
      <button type="button" onClick={() => setOpen(true)} aria-label="Account and the Lounge" className="shrink-0 rounded-full">
        <Avatar size="big" name={profile.name || "?"} themeKey={profile.themeKey} imageUrl={profile.profilePictureUrl} />
      </button>
      {open ? (
        <Sheet title={profile.name || "You"} onClose={() => setOpen(false)}>
          <nav className="flex flex-col pb-2">
            <SheetLink to="/blogs" label="Back to the Lounge" />
            <SheetLink to="/books/add?intent=finished" label="Add a book you've already read" onClick={() => setOpen(false)} />
            <SheetLink to="/books/stats" label="Your reading stats" onClick={() => setOpen(false)} />
            <SheetLink to="/books/import" label="Import from Goodreads" onClick={() => setOpen(false)} />
            <SheetLink to="/books/koreader" label="KOReader sync" onClick={() => setOpen(false)} />
            <NotificationsRow onNavigate={() => setOpen(false)} />
            <SheetLink to="/account" label="Account settings" />
          </nav>
        </Sheet>
      ) : null}
    </>
  );
}

/** Turning notifications on for this app, or the way to choose which arrive. */
function NotificationsRow({ onNavigate }: { onNavigate: () => void }) {
  const { state, busy, error, turnOn } = usePushState();
  if (state === "unsupported") return null;
  if (state === "on") return <SheetLink to="/account#notifications" label="Notification settings" onClick={onNavigate} />;
  return (
    <div className="border-b border-slate-100 py-3.5">
      {state === "off" ? (
        <button type="button" onClick={() => void turnOn()} disabled={busy} className="flex w-full items-center justify-between text-left text-[15px] text-slate-800">
          {busy ? "Turning on…" : "Turn on notifications"}
          <span className="text-slate-400">›</span>
        </button>
      ) : (
        <p className="text-[15px] text-slate-800">Notifications</p>
      )}
      <p className="mt-0.5 text-xs text-slate-500">
        {state === "off"
          ? "Replies to your reviews, new notes in your book clubs, and friends starting books you want to read."
          : state === "blocked"
            ? "They're blocked for this app. Allow them in your browser's or phone's settings."
            : "On iPhone, add Books to your Home Screen (Share → Add to Home Screen) and open it from there."}
      </p>
      {error ? <p className="mt-1 text-xs text-rose-600">{error}</p> : null}
    </div>
  );
}

function SheetLink({ to, label, onClick }: { to: string; label: string; onClick?: () => void }) {
  return (
    <Link to={to} onClick={onClick} className="flex items-center justify-between border-b border-slate-100 py-3.5 text-[15px] text-slate-800">
      {label}
      <span className="text-slate-400">›</span>
    </Link>
  );
}

export function BooksApp() {
  const palette = usePalette();
  const location = useLocation();
  useLightChrome(palette.softBg);
  const tabs = showsTabs(location.pathname);

  // A new screen starts at its top, as an app's would, not wherever the last
  // one was scrolled to.
  useEffect(() => {
    window.scrollTo(0, 0);
  }, [location.pathname]);

  return (
    <div className="min-h-dvh text-slate-900" style={{ background: palette.softBg }}>
      <div style={{ paddingBottom: tabs ? "calc(4.5rem + env(safe-area-inset-bottom))" : undefined }}>
        <Routes>
          <Route index element={<HomeScreen />} />
          <Route path="add" element={<AddScreen />} />
          <Route path="item/:entryId" element={<ItemScreen />} />
          <Route path="club/:itemId" element={<ClubScreen />} />
          <Route path="finish/:runId" element={<FinishScreen />} />
          <Route path="feed" element={<FeedScreen />} />
          <Route path="review/:reviewId" element={<ReviewScreen />} />
          <Route path="ask/:askId" element={<AskScreen />} />
          <Route path="library" element={<LibraryScreen />} />
          <Route path="people/:userId" element={<LibraryScreen />} />
          <Route path="stats" element={<StatsScreen />} />
          <Route path="import" element={<ImportScreen />} />
          <Route path="koreader" element={<KoreaderScreen />} />
          <Route path="*" element={<HomeScreen />} />
        </Routes>
      </div>
      {tabs ? <BottomTabs accent={palette.accent} /> : null}
    </div>
  );
}
