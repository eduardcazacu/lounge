import { useEffect, useState } from "react";
import type { ChangeEvent } from "react";
import { Link } from "react-router-dom";
import { IMPORT_BATCH_SIZE } from "@blogging-app/common";
import type { ImportRowInput, ImportRowResult } from "@blogging-app/common";
import { isAxiosError } from "axios";
import { errorMessage, invalidateShelf, localDay, shelfSend } from "./api";
import { looksLikeDnfShelf, NotAGoodreadsExport, readGoodreadsExport, statusOf, toImportRows } from "./goodreads";
import type { GoodreadsExport } from "./goodreads";
import { Card, SectionTitle, TopBar } from "./ui";
import { usePalette } from "./format";

// Bringing a Goodreads library across.
//
// The file is read here, in the browser, and only the shelf's own columns go
// to the server, twenty books at a time — which keeps each request inside a
// Worker's outbound limit (the server looks each book up on Open Library) and
// gives an honest progress bar. Importing is safe to repeat: a second run of
// the same or a newer export adds only what is new. Imported reviews stay on
// the library and the book's page and never reach the review feed.

type Phase =
  | { kind: "pick" }
  | { kind: "preview"; exported: GoodreadsExport }
  | { kind: "importing"; done: number; total: number; waitingSeconds: number | null }
  | { kind: "finished"; results: ImportRowResult[]; remaining: ImportRowInput[] };

// How many times in a row the catalog may turn every row away before the
// import stops and hands the decision back to the reader. Six waits is
// several minutes of Open Library saying no.
const MAX_IDLE_PAUSES = 6;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const STEPS = [
  <>
    On the Goodreads <strong>website</strong> (the app can't do it), open <strong>My Books</strong>.
  </>,
  <>
    In the left column choose <strong>Import and export</strong>, then <strong>Export Library</strong>.
  </>,
  <>
    When the link to <strong>goodreads_library_export.csv</strong> appears (seconds to a few minutes), download it and pick it below.
  </>,
];

export function ImportScreen() {
  const palette = usePalette();
  const [phase, setPhase] = useState<Phase>({ kind: "pick" });
  const [error, setError] = useState<string | null>(null);
  const [dnfShelf, setDnfShelf] = useState<string | null>(null);
  const [includeReviews, setIncludeReviews] = useState(true);

  // Leaving mid-import loses nothing that was sent, but the rest would not
  // arrive, so the browser is asked to confirm.
  useEffect(() => {
    if (phase.kind !== "importing") return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [phase.kind]);

  async function pickFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    setError(null);
    try {
      const exported = readGoodreadsExport(await file.text());
      if (exported.books.length === 0) {
        setError("That export has no books in it.");
        return;
      }
      setDnfShelf(exported.shelves.find(looksLikeDnfShelf) ?? null);
      setPhase({ kind: "preview", exported });
    } catch (e) {
      setError(e instanceof NotAGoodreadsExport ? e.message : "That file couldn't be read. Is it the CSV Goodreads made?");
    }
  }

  const choices = { dnfShelf, includeReviews };
  // A few hundred rows: cheap enough to count on every render.
  let counts: { finished: number; reading: number; want: number; dnf: number; ignored: number; reviews: number } | null = null;
  if (phase.kind === "preview") {
    counts = { finished: 0, reading: 0, want: 0, dnf: 0, ignored: 0, reviews: 0 };
    for (const book of phase.exported.books) {
      const status = statusOf(book, choices);
      if (!status) counts.ignored += 1;
      else counts[status] += 1;
      if ((status === "finished" || status === "dnf") && (book.rating !== null || book.review)) counts.reviews += 1;
    }
  }

  /**
   * Sends the rows a batch at a time. A row the server hands back as "retry"
   * — Open Library refused — goes back to the front of the queue, and the
   * screen waits as long as Open Library asked before carrying on. Nothing is
   * written for such a row in the meantime, so no book is ever filed from the
   * export's own details just because the catalog was busy.
   */
  async function run(rows: ImportRowInput[], earlier: ImportRowResult[]) {
    const total = earlier.length + rows.length;
    const results = [...earlier];
    const queue = [...rows];
    let idlePauses = 0;
    setPhase({ kind: "importing", done: results.length, total, waitingSeconds: null });

    while (queue.length > 0) {
      const batch = queue.slice(0, IMPORT_BATCH_SIZE);
      let answer: { results: ImportRowResult[]; retryAfterSeconds: number | null } | null = null;
      for (let attempt = 0; attempt < 3 && !answer; attempt += 1) {
        try {
          answer = await shelfSend("post", "/import", { source: "goodreads", rows: batch, today: localDay() });
        } catch (e) {
          if (attempt === 2) {
            setError(errorMessage(e, "The import stopped. Nothing already added is lost."));
            invalidateShelf();
            setPhase({ kind: "finished", results, remaining: queue });
            return;
          }
          await sleep(1500 * (attempt + 1));
        }
      }

      const retry: ImportRowInput[] = [];
      answer!.results.forEach((result, index) => {
        if (result.outcome === "retry") retry.push(batch[index]);
        else results.push(result);
      });
      queue.splice(0, batch.length, ...retry);
      setPhase({ kind: "importing", done: results.length, total, waitingSeconds: null });

      if (retry.length > 0) {
        idlePauses = retry.length === batch.length ? idlePauses + 1 : 0;
        if (idlePauses >= MAX_IDLE_PAUSES) {
          setError("The book catalogs are still turning requests away. Nothing already added is lost; carry on later.");
          invalidateShelf();
          setPhase({ kind: "finished", results, remaining: queue });
          return;
        }
        for (let left = answer!.retryAfterSeconds ?? 30; left > 0; left -= 1) {
          setPhase({ kind: "importing", done: results.length, total, waitingSeconds: left });
          await sleep(1000);
        }
      } else {
        idlePauses = 0;
      }
    }
    invalidateShelf();
    setPhase({ kind: "finished", results, remaining: [] });
  }

  return (
    <>
      <TopBar title="Import from Goodreads" />
      <main className="mx-auto max-w-xl px-4 pb-10">
        {phase.kind === "pick" ? (
          <>
            <SectionTitle>Get your export</SectionTitle>
            <Card>
              <ol className="flex list-decimal flex-col gap-2 pl-5 text-[15px] text-slate-700">
                {STEPS.map((step, index) => (
                  <li key={index}>{step}</li>
                ))}
              </ol>
              <a
                href="https://www.goodreads.com/review/import"
                target="_blank"
                rel="noreferrer noopener"
                className="mt-3 inline-block text-sm font-medium"
                style={{ color: palette.accent }}
              >
                Open Goodreads' export page ↗
              </a>
            </Card>

            <label
              className="mt-4 flex cursor-pointer flex-col items-center gap-1 rounded-2xl border-2 border-dashed bg-white px-4 py-8 text-center"
              style={{ borderColor: palette.border }}
            >
              <span className="text-[16px] font-semibold" style={{ color: palette.accent }}>
                Choose goodreads_library_export.csv
              </span>
              <span className="text-xs text-slate-500">Read on this device; your private notes never leave it.</span>
              <input type="file" accept=".csv,text/csv" onChange={pickFile} className="sr-only" />
            </label>
            {error ? <p className="mt-3 text-sm text-rose-600">{error}</p> : null}
          </>
        ) : null}

        {phase.kind === "preview" && counts ? (
          <>
            <SectionTitle>What will be added</SectionTitle>
            <Card>
              <ul className="flex flex-col gap-1.5 text-[15px]">
                <li>
                  <strong>{counts.finished}</strong> read
                </li>
                <li>
                  <strong>{counts.reading}</strong> currently reading
                </li>
                <li>
                  <strong>{counts.want}</strong> want to read
                </li>
                {dnfShelf ? (
                  <li>
                    <strong>{counts.dnf}</strong> did not finish
                  </li>
                ) : null}
                {counts.ignored ? (
                  <li className="text-slate-500">
                    {counts.ignored} on other shelves, left out
                  </li>
                ) : null}
              </ul>
              <p className="mt-3 text-xs text-slate-500">
                A book read more than once comes across as read once, on the last date Goodreads has. Books you already
                have here aren't added twice.
              </p>
            </Card>

            <SectionTitle>Choices</SectionTitle>
            <Card>
              <label className="block text-sm text-slate-600">
                Which shelf means “did not finish”?
                <select
                  value={dnfShelf ?? ""}
                  onChange={(event) => setDnfShelf(event.target.value || null)}
                  className="mt-1 block w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-[16px] text-slate-900"
                >
                  <option value="">None — I don't have one</option>
                  {phase.exported.shelves.map((shelf) => (
                    <option key={shelf} value={shelf}>
                      {shelf}
                    </option>
                  ))}
                </select>
              </label>
              <label className="mt-4 flex items-center justify-between gap-3">
                <span className="text-[15px]">
                  Bring ratings and reviews
                  <span className="block text-xs text-slate-500">
                    {counts.reviews} books have one. They stay on your library and the book's page, not in the feed.
                  </span>
                </span>
                <input
                  type="checkbox"
                  checked={includeReviews}
                  onChange={(event) => setIncludeReviews(event.target.checked)}
                  className="h-6 w-6 shrink-0"
                  style={{ accentColor: palette.accent }}
                />
              </label>
            </Card>

            <div className="mt-6 grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => setPhase({ kind: "pick" })}
                className="rounded-full border border-slate-300 bg-white py-3.5 font-medium text-slate-700"
              >
                Another file
              </button>
              <button
                type="button"
                onClick={() => void run(toImportRows(phase.exported.books, choices), [])}
                className="rounded-full py-3.5 font-semibold text-white"
                style={{ background: palette.accent }}
              >
                Import {counts.finished + counts.reading + counts.want + counts.dnf}
              </button>
            </div>
          </>
        ) : null}

        {phase.kind === "importing" ? (
          <Card className="mt-6">
            <div className="text-[15px] font-medium">
              Importing… {phase.done} of {phase.total}
            </div>
            {phase.waitingSeconds !== null ? (
              <p className="mt-1 text-sm text-amber-700">
                The book catalogs asked us to slow down. Carrying on in {phase.waitingSeconds}s.
              </p>
            ) : null}
            <div className="mt-3 h-2 overflow-hidden rounded-full bg-slate-200">
              <div
                className="h-full rounded-full transition-[width] duration-500"
                style={{ width: `${(phase.done / Math.max(1, phase.total)) * 100}%`, background: palette.accent }}
              />
            </div>
            <p className="mt-3 text-xs text-slate-500">
              Each book is looked up for its cover and details. Keep this page open; a big library takes a few minutes.
            </p>
          </Card>
        ) : null}

        {phase.kind === "finished" ? (
          <Summary phase={phase} error={error} onResume={() => void run(phase.remaining, phase.results)} />
        ) : null}
      </main>
    </>
  );
}

function Summary({
  phase,
  error,
  onResume,
}: {
  phase: Extract<Phase, { kind: "finished" }>;
  error: string | null;
  onResume: () => void;
}) {
  const palette = usePalette();
  const added = phase.results.filter((result) => result.outcome === "added");
  const skipped = phase.results.filter((result) => result.outcome === "skipped");
  const failed = phase.results.filter((result) => result.outcome === "failed");
  // Not in the catalog when imported, so made from the export's own details.
  // Worth asking again: the catalog may have them now, and finding them is
  // what puts their readers in the same book club.
  const byHand = added.filter((result) => result.match === "manual" && result.entryId !== null);
  const stopped = phase.remaining.length > 0;

  return (
    <>
      <SectionTitle>{stopped ? "Paused" : "Done"}</SectionTitle>
      <Card>
        <ul className="flex flex-col gap-1 text-[15px]">
          <li>
            <strong>{added.length}</strong> added
          </li>
          {skipped.length ? <li className="text-slate-600">{skipped.length} already here</li> : null}
          {failed.length ? <li className="text-rose-600">{failed.length} couldn't be imported</li> : null}
          {stopped ? <li className="text-amber-700">{phase.remaining.length} still to go</li> : null}
        </ul>
        {stopped ? (
          <>
            {error ? <p className="mt-2 text-sm text-rose-600">{error}</p> : null}
            <button
              type="button"
              onClick={onResume}
              className="mt-3 w-full rounded-full py-3 font-semibold text-white"
              style={{ background: palette.accent }}
            >
              Carry on with the other {phase.remaining.length}
            </button>
          </>
        ) : null}
      </Card>

      {byHand.length ? <FindInCatalog books={byHand} /> : null}

      {failed.length ? (
        <>
          <SectionTitle>Not imported</SectionTitle>
          <p className="mb-2 px-1 text-xs text-slate-500">Importing the same file again tries these again; nothing is added twice.</p>
          <ul className="flex flex-col gap-1.5">
            {failed.map((result) => (
              <li key={result.ref} className="truncate rounded-xl bg-white px-3 py-2 text-sm text-slate-600 shadow-sm">
                {result.title}
              </li>
            ))}
          </ul>
        </>
      ) : null}

      <Link
        to="/books/library?tab=read"
        className="mt-6 block rounded-full py-3.5 text-center font-semibold text-white"
        style={{ background: palette.accent }}
      >
        Go to your library
      </Link>
    </>
  );
}

type FindState = "waiting" | "found" | "missing" | "busy";

/**
 * The books an import made from its own details, with a button to look them
 * all up again. One at a time, and it stops at the first sign of a rate limit
 * rather than spending the rest of the list on refusals.
 */
function FindInCatalog({ books }: { books: ImportRowResult[] }) {
  const palette = usePalette();
  const [states, setStates] = useState<Record<string, FindState>>({});
  const [running, setRunning] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [entryIds, setEntryIds] = useState<Record<string, number>>({});

  async function findAll() {
    setRunning(true);
    setMessage(null);
    for (const book of books) {
      if (states[book.ref] === "found" || states[book.ref] === "missing") continue;
      setStates((previous) => ({ ...previous, [book.ref]: "busy" }));
      try {
        const { entryId } = await shelfSend<{ entryId: number }>("post", `/entries/${entryIds[book.ref] ?? book.entryId}/rematch`);
        setEntryIds((previous) => ({ ...previous, [book.ref]: entryId }));
        setStates((previous) => ({ ...previous, [book.ref]: "found" }));
      } catch (e) {
        const status = isAxiosError(e) ? e.response?.status : undefined;
        if (status === 404) {
          setStates((previous) => ({ ...previous, [book.ref]: "missing" }));
          continue;
        }
        setStates((previous) => ({ ...previous, [book.ref]: "waiting" }));
        setMessage(errorMessage(e, "Couldn't reach the book catalog. Try again in a minute."));
        break;
      }
    }
    invalidateShelf();
    setRunning(false);
  }

  const label: Record<FindState, string> = { waiting: "", busy: "Looking…", found: "Found ✓", missing: "Not in the catalog" };

  return (
    <>
      <SectionTitle>Added from Goodreads' details</SectionTitle>
      <p className="mb-2 px-1 text-xs text-slate-500">
        The book catalog didn't have these, so they use what your export said — without a cover or genres, and with a book
        club of their own. Look them up again to fix that.
      </p>
      <ul className="flex flex-col gap-1.5">
        {books.map((book) => (
          <li key={book.ref}>
            <Link
              to={`/books/item/${entryIds[book.ref] ?? book.entryId}`}
              className="flex items-center justify-between gap-2 rounded-xl bg-white px-3 py-2 text-sm shadow-sm"
            >
              <span className="truncate">{book.title}</span>
              <span className="shrink-0 text-xs text-slate-500">{label[states[book.ref] ?? "waiting"]}</span>
            </Link>
          </li>
        ))}
      </ul>
      {message ? <p className="mt-2 text-sm text-amber-700">{message}</p> : null}
      <button
        type="button"
        onClick={() => void findAll()}
        disabled={running}
        className="mt-3 w-full rounded-full border py-3 font-semibold disabled:opacity-60"
        style={{ borderColor: palette.accent, color: palette.accent }}
      >
        {running ? "Looking them up…" : "Find these in the catalog"}
      </button>
    </>
  );
}
