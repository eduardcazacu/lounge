import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { errorMessage, invalidateShelf, localDay, shelfGet, shelfSend } from "./api";
import type { CatalogCandidate } from "./api";
import { Cover, Sheet, TopBar } from "./ui";
import { CopyPagesSheet } from "./CopyPagesSheet";
import { EditionSheet } from "./EditionSheet";
import { byline, languageName, usePalette } from "./format";

// Adding a book is one search and one tap. Type a title or an author, and each
// result carries the three things you might mean: Want, Start, Read it. Cover,
// page count and genre come from the catalog, so nothing else is asked —
// except the day a past read ended, which only the reader knows.
//
// Opened from a library tab (`?intent=`), the screen already knows which of
// those you mean: each result carries that one button, and the book lands in
// the tab you came from.
//
// A result is shown as its edition: search offers an English one where the
// work has it, and "Other editions" swaps it for the copy on the reader's
// shelf. The edition is the reader's own; the work it belongs to is shared.

export type Intent = "want" | "start" | "finished" | "dnf";

const INTENTS: Intent[] = ["want", "start", "finished", "dnf"];

const BUTTON_LABEL: Record<Intent, string> = { want: "Want", start: "Start", finished: "Read it", dnf: "Didn't finish" };

const TITLE: Record<Intent, string> = {
  want: "Add to want to read",
  start: "Start reading",
  finished: "Add a book you've read",
  dnf: "Add a book you put down",
};

/** The library tab a book added with this intent lands in. */
const TAB_OF: Record<Intent, string> = { want: "want", start: "reading", finished: "read", dnf: "dnf" };

const DEBOUNCE_MS = 350;

/** A result as the reader will see it on their shelf: its edition's title, cover and length. */
/** Results already on the reader's shelf, by `source:externalId`, from the search response. */
type OnShelf = Record<string, { entryId: number; status: "reading" | "read" | "dnf" | "want" }>;

const SHELF_LABEL: Record<OnShelf[string]["status"], string> = {
  reading: "Reading",
  read: "Read",
  dnf: "Didn't finish",
  want: "Want to read",
};

function asShown(candidate: CatalogCandidate) {
  const { edition } = candidate;
  return {
    title: edition?.title ?? candidate.title,
    coverUrl: edition?.coverUrl ?? candidate.coverUrl,
    totalUnits: edition?.totalUnits ?? candidate.totalUnits,
  };
}

/** When a past read ended — and, for one put down, how far it got. */
function EndedSheet({
  candidate,
  intent,
  onClose,
  onDone,
}: {
  candidate: CatalogCandidate;
  intent: "finished" | "dnf";
  onClose: () => void;
  onDone: (runId: number) => void;
}) {
  const palette = usePalette();
  const [finishedOn, setFinishedOn] = useState(localDay());
  const [stoppedAt, setStoppedAt] = useState("");
  const stoppedAtPage = Number.parseInt(stoppedAt, 10);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const result = await shelfSend<{ runId: number }>("post", "/entries", {
        candidate,
        intent,
        finishedOn,
        ...(intent === "dnf" && stoppedAtPage > 0 ? { stoppedAt: stoppedAtPage } : {}),
        today: localDay(),
      });
      invalidateShelf();
      onDone(result.runId);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  }

  const quick = (label: string, day: string) => (
    <button
      type="button"
      onClick={() => setFinishedOn(day)}
      className={`rounded-full border px-3 py-1.5 text-sm ${finishedOn === day ? "font-semibold" : "text-slate-600"}`}
      style={finishedOn === day ? { borderColor: palette.accent, color: palette.accent } : { borderColor: "#e2e8f0" }}
    >
      {label}
    </button>
  );
  const thisYear = new Date().getFullYear();

  return (
    <Sheet
      title={intent === "dnf" ? "When did you put it down?" : "When did you finish it?"}
      onClose={onClose}
      footer={
        <button
          type="button"
          onClick={save}
          disabled={busy || !finishedOn}
          className="w-full rounded-full py-3.5 font-semibold text-white disabled:opacity-50"
          style={{ background: palette.accent }}
        >
          {busy ? "Adding…" : intent === "dnf" ? "Add to did not finish" : "Add to finished"}
        </button>
      }
    >
      <div className="flex items-center gap-3 pb-4">
        <Cover item={asShown(candidate)} size="sm" />
        <div className="min-w-0">
          <div className="truncate font-semibold">{asShown(candidate).title}</div>
          <div className="truncate text-sm text-slate-500">{byline(candidate)}</div>
        </div>
      </div>
      <div className="flex flex-wrap gap-2 pb-3">
        {/* A year alone is filed on its last day: it then counts toward the
            right year, and a closing log is never anybody's best day. */}
        {quick("Today", localDay())}
        {quick(String(thisYear - 1), `${thisYear - 1}-12-31`)}
        {quick(String(thisYear - 2), `${thisYear - 2}-12-31`)}
        {quick(String(thisYear - 3), `${thisYear - 3}-12-31`)}
      </div>
      <label className="block pb-2 text-sm text-slate-600">
        Or the exact day
        <input
          type="date"
          value={finishedOn}
          max={localDay()}
          onChange={(event) => setFinishedOn(event.target.value)}
          className="mt-1 block w-full rounded-xl border border-slate-200 px-3 py-2.5 text-[16px]"
        />
      </label>
      {intent === "dnf" ? (
        <label className="block pb-2 text-sm text-slate-600">
          Stopped at page <span className="text-slate-400">(optional)</span>
          <input
            inputMode="numeric"
            value={stoppedAt}
            onChange={(event) => setStoppedAt(event.target.value.replace(/[^0-9]/g, ""))}
            placeholder={asShown(candidate).totalUnits ? `of ${asShown(candidate).totalUnits}` : ""}
            className="mt-1 block w-full rounded-xl border border-slate-200 px-3 py-2.5 text-[16px]"
          />
        </label>
      ) : null}
      <p className="pb-2 text-xs text-slate-500">
        {intent === "dnf"
          ? "The pages you got through count toward that year; the book doesn't."
          : "It counts toward that year's books and pages. A year is enough if you don't remember the day."}
      </p>
      {error ? <p className="text-sm text-rose-600">{error}</p> : null}
    </Sheet>
  );
}

function ManualSheet({
  initialTitle,
  intents,
  onClose,
  onPick,
}: {
  initialTitle: string;
  intents: Intent[];
  onClose: () => void;
  onPick: (candidate: CatalogCandidate, intent: Intent) => void;
}) {
  const palette = usePalette();
  const [title, setTitle] = useState(initialTitle);
  const [author, setAuthor] = useState("");
  const [pages, setPages] = useState("");
  const candidate: CatalogCandidate = {
    kind: "book",
    source: "manual",
    externalId: "manual",
    title: title.trim(),
    creators: author.trim() ? [author.trim()] : [],
    year: null,
    coverUrl: null,
    totalUnits: Number.parseInt(pages, 10) > 0 ? Number.parseInt(pages, 10) : null,
    genres: [],
  };
  const ready = candidate.title.length > 0;
  const field = "mt-1 block w-full rounded-xl border border-slate-200 px-3 py-2.5 text-[16px] outline-none focus:border-slate-400";

  return (
    <Sheet title="Add it by hand" onClose={onClose}>
      <label className="block pb-3 text-sm text-slate-600">
        Title
        <input autoFocus value={title} onChange={(event) => setTitle(event.target.value)} className={field} />
      </label>
      <label className="block pb-3 text-sm text-slate-600">
        Author
        <input value={author} onChange={(event) => setAuthor(event.target.value)} className={field} />
      </label>
      <label className="block pb-4 text-sm text-slate-600">
        Pages
        <input inputMode="numeric" value={pages} onChange={(event) => setPages(event.target.value.replace(/[^0-9]/g, ""))} className={field} />
      </label>
      <div className="flex gap-2 pb-2">
        {intents.map((intent) => (
          <button
            key={intent}
            type="button"
            disabled={!ready}
            onClick={() => onPick(candidate, intent)}
            className="flex-1 rounded-full py-2.5 text-sm font-semibold disabled:opacity-40"
            style={
              intent === "start" || intents.length === 1
                ? { background: palette.accent, color: "white" }
                : { background: palette.softBg, color: palette.text }
            }
          >
            {BUTTON_LABEL[intent]}
          </button>
        ))}
      </div>
    </Sheet>
  );
}

export function AddScreen() {
  const palette = usePalette();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  // Set when opened from a library tab or the account menu: the one thing
  // this visit is for.
  const fixed = INTENTS.find((intent) => intent === params.get("intent")) ?? null;
  const intents: Intent[] = fixed ? [fixed] : ["want", "start", "finished"];
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<CatalogCandidate[] | null>(null);
  const [onShelf, setOnShelf] = useState<OnShelf>({});
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ending, setEnding] = useState<{ candidate: CatalogCandidate; intent: "finished" | "dnf" } | null>(null);
  const [starting, setStarting] = useState<CatalogCandidate | null>(null);
  const [manual, setManual] = useState(false);
  // The result whose editions are being browsed.
  const [browsing, setBrowsing] = useState<CatalogCandidate | null>(null);
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const [added, setAdded] = useState<Set<string>>(new Set());
  const requestId = useRef(0);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) {
      setResults(null);
      setSearching(false);
      return;
    }
    setSearching(true);
    const id = ++requestId.current;
    const timer = setTimeout(async () => {
      try {
        const response = await shelfGet<{ results: CatalogCandidate[]; onShelf?: OnShelf }>(
          `/catalog/search?kind=book&q=${encodeURIComponent(q)}`
        );
        if (id === requestId.current) {
          setResults(response.results);
          setOnShelf(response.onShelf ?? {});
          setError(null);
        }
      } catch (e) {
        if (id === requestId.current) {
          // Unavailable is not "nothing found": the old results go, and the
          // way forward is offered instead of a list that would mislead.
          setResults(null);
          setError(errorMessage(e, "Search isn't answering. Try again in a minute, or add the book by hand."));
        }
      } finally {
        if (id === requestId.current) setSearching(false);
      }
    }, DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [query]);

  const keyOf = (candidate: CatalogCandidate) => `${candidate.source}:${candidate.externalId}`;

  /** Where to go once a book is on the shelf. */
  function landed(intent: Intent, runId: number | null) {
    if (fixed) {
      // Back to the library tab this was opened from, with the book in it.
      navigate(`/books/library?tab=${TAB_OF[intent]}`, { replace: true });
    } else if (intent === "start") {
      navigate("/books", { replace: true });
    } else if (intent === "finished" && runId) {
      // From the general add screen a finished book is a moment to say what
      // you thought; from the library it is bookkeeping, and goes straight in.
      navigate(`/books/finish/${runId}?backfill=1`, { replace: true });
    }
  }

  async function pick(candidate: CatalogCandidate, intent: Intent) {
    if (intent === "finished" || intent === "dnf") {
      setManual(false);
      setEnding({ candidate, intent });
      return;
    }
    if (intent === "start") {
      // Starting asks one thing: how long the reader's own copy is.
      setManual(false);
      setStarting(candidate);
      return;
    }
    const key = keyOf(candidate);
    setBusyKey(key);
    setError(null);
    try {
      await shelfSend("post", "/entries", { candidate, intent, today: localDay() });
      invalidateShelf();
      if (intent === "want" && !fixed) {
        // Wanting is often several books at a sitting, so the general add
        // screen stays put. From the want tab it goes back to the tab, like
        // every other tab does.
        setAdded((previous) => new Set(previous).add(key));
        setManual(false);
      } else {
        landed(intent, null);
      }
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusyKey(null);
    }
  }

  return (
    <>
      <TopBar title={fixed ? TITLE[fixed] : "Add a book"} />
      <main className="mx-auto max-w-xl px-4 pb-10">
        <div className="sticky z-20 -mx-4 px-4 pb-3 pt-3" style={{ top: "calc(3.5rem + env(safe-area-inset-top))", background: palette.softBg }}>
          <input
            autoFocus
            type="search"
            enterKeyHint="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Title or author"
            className="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-[17px] shadow-sm outline-none focus:border-slate-400"
          />
        </div>

        {error ? (
          <div className="py-3 text-center">
            <p className="text-sm text-amber-700">{error}</p>
            <button type="button" onClick={() => setManual(true)} className="mt-2 text-sm font-medium" style={{ color: palette.accent }}>
              Add it by hand
            </button>
          </div>
        ) : null}
        {searching && !results ? <p className="py-6 text-center text-sm text-slate-400">Searching…</p> : null}
        {!results && !searching && !error ? (
          <p className="px-2 py-8 text-center text-sm text-slate-500">
            {fixed === "finished"
              ? "Find the book, then say when you finished it."
              : fixed === "dnf"
                ? "Find the book, then say when you put it down."
                : "Covers, page counts and genres are filled in for you."}
          </p>
        ) : null}

        {results ? (
          <ul className={`flex flex-col gap-2 transition-opacity ${searching ? "opacity-60" : ""}`}>
            {results.length === 0 ? <li className="py-6 text-center text-sm text-slate-500">Nothing found.</li> : null}
            {results.map((candidate) => {
              const key = keyOf(candidate);
              const isAdded = added.has(key);
              const mine = onShelf[key];
              const shown = asShown(candidate);
              const edition = candidate.edition;
              return (
                <li key={key} className="flex gap-3 rounded-2xl border border-slate-200/70 bg-white p-3 shadow-sm">
                  <Cover item={shown} size="sm" />
                  <div className="flex min-w-0 flex-1 flex-col">
                    <div className="line-clamp-2 font-semibold leading-snug">{shown.title}</div>
                    <div className="truncate text-sm text-slate-500">
                      {[byline(candidate), candidate.year, shown.totalUnits ? `${shown.totalUnits} pages` : null]
                        .filter(Boolean)
                        .join(" · ")}
                    </div>
                    {mine ? (
                      <Link
                        to={`/books/item/${mine.entryId}`}
                        className="mt-1 self-start rounded-full px-2 py-0.5 text-xs font-medium"
                        style={{ background: palette.softBg, color: palette.accent }}
                      >
                        ✓ In your library · {SHELF_LABEL[mine.status]} ›
                      </Link>
                    ) : null}
                    {candidate.source === "openlibrary" ? (
                      <div className="truncate text-xs text-slate-400">
                        {edition
                          ? `${[languageName(edition.language), edition.publisher, edition.year].filter(Boolean).join(" · ")} · `
                          : null}
                        <button type="button" onClick={() => setBrowsing(candidate)} className="font-medium" style={{ color: palette.accent }}>
                          Other editions
                        </button>
                      </div>
                    ) : null}
                    <div className="mt-auto flex gap-1.5 pt-2">
                      {intents.map((intent) => {
                        const primary = intent === "start" || intents.length === 1;
                        const done = intent === "want" && isAdded;
                        return (
                          <button
                            key={intent}
                            type="button"
                            disabled={busyKey === key || done}
                            onClick={() => pick(candidate, intent)}
                            className={`rounded-full px-3 py-1.5 text-sm disabled:opacity-60 ${primary ? "font-semibold" : "font-medium"}`}
                            style={primary && !done ? { background: palette.accent, color: "white" } : { background: palette.softBg, color: palette.text }}
                          >
                            {done ? "✓ Wanted" : BUTTON_LABEL[intent]}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                </li>
              );
            })}
            <li>
              <button type="button" onClick={() => setManual(true)} className="w-full py-4 text-sm font-medium" style={{ color: palette.accent }}>
                Can't find it? Add it by hand
              </button>
            </li>
          </ul>
        ) : null}
      </main>

      {ending ? (
        <EndedSheet
          candidate={ending.candidate}
          intent={ending.intent}
          onClose={() => setEnding(null)}
          onDone={(runId) => landed(ending.intent, runId)}
        />
      ) : null}
      {starting ? (
        <CopyPagesSheet
          title={asShown(starting).title}
          initial={asShown(starting).totalUnits}
          confirmLabel="Start reading"
          onClose={() => setStarting(null)}
          onConfirm={async (pages) => {
            await shelfSend("post", "/entries", { candidate: starting, intent: "start", totalUnits: pages, today: localDay() });
            invalidateShelf();
            setStarting(null);
            landed("start", null);
          }}
        />
      ) : null}
      {browsing ? (
        <EditionSheet
          title={asShown(browsing).title}
          path={`/catalog/editions?work=${encodeURIComponent(browsing.externalId)}`}
          currentId={browsing.edition?.externalId ?? null}
          onClose={() => setBrowsing(null)}
          onPick={(edition) => {
            // Only the result's edition changes. Its title and cover stay the
            // work's, which the first person to add it fixes for everyone.
            const key = keyOf(browsing);
            setResults((previous) =>
              previous ? previous.map((candidate) => (keyOf(candidate) === key ? { ...candidate, edition } : candidate)) : previous
            );
            setBrowsing(null);
          }}
        />
      ) : null}
      {manual ? <ManualSheet initialTitle={query} intents={intents} onClose={() => setManual(false)} onPick={pick} /> : null}
    </>
  );
}
