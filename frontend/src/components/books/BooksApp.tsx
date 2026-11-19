import { useEffect, useState } from "react";
import { Link, Route, Routes, useLocation } from "react-router-dom";
import { Avatar } from "../Avatar";
import { LoungeNav, LOUNGE_NAV_SPACE } from "../LoungeNav";
import { getCachedProfile } from "../../lib/auth";
import { Sheet } from "./ui";
import { usePushState } from "./notifications";
import { usePalette } from "./format";
import { HomeScreen } from "./HomeScreen";
import { AddScreen } from "./AddScreen";
import { ItemScreen } from "./ItemScreen";
import { WorkScreen } from "./WorkScreen";
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

/** Screens that take the whole height for their own controls hide the Lounge's bar. */
function showsNav(pathname: string) {
  return !/^\/books\/(add|finish\/|import)/.test(pathname);
}

/** Reading, Feed and Library: the screens a book is logged from. */
function showsLogBook(pathname: string) {
  return /^\/books(\/(feed|library))?\/?$/.test(pathname);
}

/** What the floating button leaves clear under the last card, over the bar's own space. */
const LOG_BOOK_SPACE = `calc(${LOUNGE_NAV_SPACE} + 4.5rem)`;

/**
 * Logging a book is the one thing every section is for, so it floats over all
 * three rather than living in one of their headers. Right-aligned to the
 * column, so it sits over the bar's Post: the two "add" actions stack in one
 * corner and read as Books' and the Lounge's, not as two of the same.
 */
function LogBookButton() {
  const palette = usePalette();
  return (
    <div className="pointer-events-none fixed inset-x-0 z-30" style={{ bottom: `calc(${LOUNGE_NAV_SPACE} + 1rem)` }}>
      <div className="mx-auto flex max-w-xl justify-end px-4">
        <Link
          to="/books/add"
          className="pointer-events-auto flex h-12 items-center gap-2 rounded-full pl-4 pr-5 text-[15px] font-semibold text-white shadow-lg"
          style={{ background: palette.accent }}
        >
          <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
            <path d="M12 5v14M5 12h14" />
          </svg>
          Log book
        </Link>
      </div>
    </div>
  );
}

/** What the avatar opens: the account, and the corners of Books with no section of their own. */
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
      <button type="button" onClick={() => setOpen(true)} aria-label="Account and more" className="shrink-0 rounded-full">
        <Avatar size="big" name={profile.name || "?"} themeKey={profile.themeKey} imageUrl={profile.profilePictureUrl} />
      </button>
      {open ? (
        <Sheet title={profile.name || "You"} onClose={() => setOpen(false)}>
          <nav className="flex flex-col pb-2">
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
  const nav = showsNav(location.pathname);
  const logBook = showsLogBook(location.pathname);

  return (
    <div className="min-h-dvh text-slate-900" style={{ background: palette.softBg }}>
      <div style={{ paddingBottom: logBook ? LOG_BOOK_SPACE : nav ? LOUNGE_NAV_SPACE : undefined }}>
        <Routes>
          <Route index element={<HomeScreen />} />
          <Route path="add" element={<AddScreen />} />
          <Route path="item/:entryId" element={<ItemScreen />} />
          <Route path="work/:itemId" element={<WorkScreen />} />
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
      {logBook ? <LogBookButton /> : null}
      {nav ? <LoungeNav /> : null}
    </div>
  );
}
