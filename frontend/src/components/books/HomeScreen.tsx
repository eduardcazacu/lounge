import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Avatar } from "../BlogCard";
import { invalidateShelf, localDay, shelfSend, useShelf } from "./api";
import type { Home, HomeReading, Person, ReaderPending } from "./api";
import { AccountButton } from "./BooksApp";
import { LogSheet } from "./LogSheet";
import { CopyPagesSheet } from "./CopyPagesSheet";
import { ReaderLinkSheet } from "./ReaderLinkSheet";
import { dismissNotificationsCard, isNotificationsCardDismissed, usePushState } from "./notifications";
import { Card, Cover, EmptyNote, ProgressBar, SectionTitle, Spinner } from "./ui";
import { agoText, byline, percentText, usePalette } from "./format";

// Home: what is being read, how far, and a button to log more — then three
// numbers, then the want list. Everything else is a tap away. The book club
// is a chip on the card that opens it; nothing anyone wrote is shown here.

function ReadingCard({ reading, onLog }: { reading: HomeReading; onLog: () => void }) {
  const palette = usePalette();
  const navigate = useNavigate();
  const [checkingCopy, setCheckingCopy] = useState(false);
  const { item, run, club } = reading;
  const total = run.totalUnits;

  // A sync never finishes a book — there may be an epilogue, or notes at the
  // back KOReader counts as the book — so near the end it asks, once a tap.
  async function finish() {
    await shelfSend("post", `/runs/${run.id}/finish`, { status: "finished", finishedOn: localDay() });
    invalidateShelf();
    navigate(`/books/finish/${run.id}`);
  }

  return (
    <Card className="!p-3">
      <div className="flex gap-3">
        <button type="button" onClick={() => navigate(`/books/item/${reading.entryId}`)} className="shrink-0" aria-label={`Open ${item.title}`}>
          <Cover item={item} size="md" />
        </button>
        <div className="flex min-w-0 flex-1 flex-col">
          <button type="button" onClick={() => navigate(`/books/item/${reading.entryId}`)} className="min-w-0 text-left">
            <div className="truncate text-[16px] font-semibold leading-tight text-slate-900">{item.title}</div>
            <div className="truncate text-sm text-slate-500">{byline(item)}</div>
          </button>
          <div className="mt-auto pt-2">
            <ProgressBar fraction={run.fraction} color={palette.accent} />
            <div className="mt-1 flex items-center justify-between text-xs text-slate-500">
              <span className="tabular-nums">
                {total ? `p. ${run.position} of ${total} · ${percentText(run.fraction)}` : `p. ${run.position}`}
              </span>
              {reading.today > 0 ? (
                <span className="font-medium tabular-nums" style={{ color: palette.accent }}>
                  +{reading.today} today
                </span>
              ) : null}
            </div>
            {reading.reader ? (
              <div className="mt-0.5 text-xs text-slate-500">
                KOReader · {agoText(reading.reader.syncedAt)}
                {run.fraction !== null && run.fraction >= 0.99 ? (
                  <>
                    {" · "}
                    <button type="button" onClick={finish} className="font-medium" style={{ color: palette.accent }}>
                      Finished it?
                    </button>
                  </>
                ) : null}
              </div>
            ) : null}
            {!run.unitsConfirmed ? (
              <button type="button" onClick={() => setCheckingCopy(true)} className="mt-0.5 text-left text-xs font-medium text-amber-700">
                {total ? `Is your copy ${total} pages?` : "How many pages is your copy?"}
              </button>
            ) : null}
          </div>
        </div>
      </div>
      <div className="mt-3 flex items-center gap-2">
        <Link
          to={`/books/club/${item.id}`}
          className="flex min-w-0 flex-1 items-center gap-2 rounded-full border border-slate-200 px-3 py-2 text-sm text-slate-600"
        >
          <span aria-hidden>💬</span>
          <span className="truncate">
            Book club
            {club.visibleNotes > 0 ? ` · ${club.visibleNotes} note${club.visibleNotes === 1 ? "" : "s"}` : ""}
            {club.aheadNotes > 0 ? ` · ${club.aheadNotes} ahead` : ""}
          </span>
          {club.readers.length > 0 ? (
            <span className="ml-auto flex -space-x-1.5">
              {club.readers.slice(0, 3).map((reader) => (
                <span key={reader.id} className="rounded-full ring-2 ring-white">
                  <Avatar size="small" name={reader.name ?? "?"} themeKey={reader.themeKey} imageUrl={reader.profilePictureUrl} />
                </span>
              ))}
            </span>
          ) : null}
        </Link>
        <button
          type="button"
          onClick={onLog}
          className="shrink-0 rounded-full px-5 py-2 text-[15px] font-semibold text-white shadow-sm active:scale-[0.98]"
          style={{ background: palette.accent }}
        >
          + Pages
        </button>
      </div>
      {checkingCopy ? (
        <CopyPagesSheet
          title={item.title}
          initial={total}
          confirmLabel="That's my copy"
          onClose={() => setCheckingCopy(false)}
          onConfirm={async (pages) => {
            await shelfSend("put", `/runs/${run.id}`, { totalUnits: pages });
            invalidateShelf();
            setCheckingCopy(false);
          }}
        />
      ) : null}
    </Card>
  );
}

/** A file KOReader synced that is not a book yet: one tap to say which. */
function ReaderPendingCard({ doc }: { doc: ReaderPending }) {
  const palette = usePalette();
  const [open, setOpen] = useState(false);
  return (
    <Card className="mb-3">
      <p className="text-[15px] font-medium text-slate-900">
        {doc.title ? `${doc.title} on your ${doc.device}` : `Your ${doc.device} is reading something`}
      </p>
      <p className="mt-0.5 text-sm text-slate-600">
        At {percentText(doc.percentage)}, synced {agoText(doc.syncedAt)}. Which book is it? You'll only be asked once.
      </p>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="mt-3 rounded-full px-4 py-2 text-sm font-semibold text-white"
        style={{ background: palette.accent }}
      >
        Choose the book
      </button>
      {open ? <ReaderLinkSheet doc={doc} onClose={() => setOpen(false)} /> : null}
    </Card>
  );
}

/**
 * Asks once, after the first reading is logged — when there is a book club to
 * hear from — rather than on the first visit, when the question means
 * nothing yet. "Not now" is final for this card; the avatar menu still has
 * the switch.
 */
function NotificationsCard({ home }: { home: Home }) {
  const palette = usePalette();
  const { state, busy, error, turnOn } = usePushState();
  const [dismissed, setDismissed] = useState(isNotificationsCardDismissed);
  const hasRead = home.highlights.pagesThisWeek > 0 || home.highlights.streak > 0 || home.reading.some((reading) => reading.run.position > 0);
  if (dismissed || state !== "off" || !hasRead) return null;

  const close = () => {
    dismissNotificationsCard();
    setDismissed(true);
  };
  return (
    <Card className="mt-3">
      <p className="text-[15px] font-medium text-slate-900">Hear from your book clubs?</p>
      <p className="mt-1 text-sm text-slate-600">
        A note when someone's thoughts are ready for you to read, and when a friend starts a book you want to read. Never
        anything past where you are.
      </p>
      {error ? <p className="mt-1 text-xs text-rose-600">{error}</p> : null}
      <div className="mt-3 flex gap-2">
        <button
          type="button"
          disabled={busy}
          onClick={async () => {
            if (await turnOn()) close();
          }}
          className="rounded-full px-4 py-2 text-sm font-semibold text-white disabled:opacity-60"
          style={{ background: palette.accent }}
        >
          {busy ? "Turning on…" : "Turn on"}
        </button>
        <button type="button" onClick={close} className="rounded-full px-4 py-2 text-sm font-medium text-slate-600">
          Not now
        </button>
      </div>
    </Card>
  );
}

function Highlights({ home }: { home: Home }) {
  const navigate = useNavigate();
  const palette = usePalette();
  const tiles = [
    { value: home.highlights.booksThisYear, label: `book${home.highlights.booksThisYear === 1 ? "" : "s"} in ${home.highlights.year}` },
    { value: home.highlights.pagesThisWeek, label: "pages this week" },
    { value: home.highlights.streak, label: `day streak${home.highlights.streak > 0 ? " 🔥" : ""}` },
  ];
  return (
    <Card onClick={() => navigate("/books/stats")} className="!p-0">
      <div className="grid grid-cols-3 divide-x divide-slate-100">
        {tiles.map((tile) => (
          <div key={tile.label} className="px-2 py-3 text-center">
            <div className="text-2xl font-semibold tabular-nums" style={{ color: palette.text }}>
              {tile.value.toLocaleString()}
            </div>
            <div className="text-[11px] leading-tight text-slate-500">{tile.label}</div>
          </div>
        ))}
      </div>
      <div className="border-t border-slate-100 py-1.5 text-center text-xs font-medium" style={{ color: palette.accent }}>
        More stats ›
      </div>
    </Card>
  );
}

/**
 * Everyone else in the group who reads here, as the Lounge's blog shows its
 * authors: a row of avatars that scrolls sideways. Each opens that person's
 * library.
 */
function ReadersStrip({ readers }: { readers: Person[] }) {
  return (
    <Card className="!p-3">
      <div className="flex gap-3 overflow-x-auto py-1.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {readers.map((reader) => {
          const name = reader.name?.trim() || "Someone";
          return (
            <Link key={reader.id} to={`/books/people/${reader.id}`} title={name} className="flex w-16 shrink-0 flex-col items-center gap-1.5">
              <span className="flex h-12 w-12 items-center justify-center rounded-full bg-slate-100 p-0.5">
                <Avatar size="big" name={name} themeKey={reader.themeKey} imageUrl={reader.profilePictureUrl} />
              </span>
              <span className="max-w-[64px] truncate text-[11px] leading-tight text-slate-600">
                {name}
              </span>
            </Link>
          );
        })}
      </div>
    </Card>
  );
}

export function HomeScreen() {
  const palette = usePalette();
  const { data: home, error } = useShelf<Home>(`/home?today=${localDay()}`);
  const [logging, setLogging] = useState<HomeReading | null>(null);

  return (
    <>
      <header className="sticky top-0 z-30 backdrop-blur" style={{ paddingTop: "env(safe-area-inset-top)", background: `${palette.softBg}e6` }}>
        <div className="mx-auto flex h-16 max-w-xl items-center gap-3 px-4">
          <AccountButton />
          <h1 className="flex-1 text-xl font-bold tracking-tight" style={{ color: palette.text }}>
            Books
          </h1>
          <Link
            to="/books/add"
            aria-label="Add a book"
            className="flex h-10 w-10 items-center justify-center rounded-full text-white shadow-sm"
            style={{ background: palette.accent }}
          >
            <svg viewBox="0 0 24 24" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
              <path d="M12 5v14M5 12h14" />
            </svg>
          </Link>
        </div>
      </header>

      <main className="mx-auto max-w-xl px-4 pb-6">
        {!home ? (
          error ? (
            <EmptyNote>Couldn't load your shelf. It will try again when you come back to it.</EmptyNote>
          ) : (
            <Spinner />
          )
        ) : (
          <>
            <SectionTitle>Reading now</SectionTitle>
            {(home.readerPending ?? []).map((doc) => (
              <ReaderPendingCard key={doc.id} doc={doc} />
            ))}
            {home.reading.length === 0 ? (
              <Link to="/books/add" className="block">
                <EmptyNote>
                  Nothing on the go. <span style={{ color: palette.accent }}>Find a book to start →</span>
                </EmptyNote>
              </Link>
            ) : (
              <div className="flex flex-col gap-3">
                {home.reading.map((reading) => (
                  <ReadingCard key={reading.run.id} reading={reading} onLog={() => setLogging(reading)} />
                ))}
              </div>
            )}

            <NotificationsCard home={home} />

            <SectionTitle>This year</SectionTitle>
            <Highlights home={home} />

            <SectionTitle
              action={
                <Link to="/books/library?tab=want" className="text-sm font-medium" style={{ color: palette.accent }}>
                  {home.want.length > 0 ? "All" : ""}
                </Link>
              }
            >
              Want to read
            </SectionTitle>
            {home.want.length === 0 ? (
              <EmptyNote>Books you mean to get to go here. Add one with “Want” from the + button.</EmptyNote>
            ) : (
              <div className="-mx-4 flex gap-3 overflow-x-auto px-4 pb-2 [scrollbar-width:none]">
                {home.want.map((want) => (
                  <Link key={want.entryId} to={`/books/item/${want.entryId}`} className="shrink-0">
                    <Cover item={want.item} size="lg" />
                  </Link>
                ))}
              </div>
            )}

            <Link
              to="/books/library"
              className="mt-6 block text-center text-sm font-medium"
              style={{ color: palette.accent }}
            >
              Your library ›
            </Link>

            {home.readers?.length ? (
              <>
                <SectionTitle>Who's reading</SectionTitle>
                <ReadersStrip readers={home.readers} />
              </>
            ) : null}
          </>
        )}
      </main>

      {logging ? <LogSheet run={logging.run} item={logging.item} onClose={() => setLogging(null)} /> : null}
    </>
  );
}
