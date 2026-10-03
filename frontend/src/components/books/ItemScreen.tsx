import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { errorMessage, invalidateShelf, localDay, shelfSend, useShelf } from "./api";
import type { CatalogEdition, EntryDetail, FeedReview, ProgressLogRow } from "./api";
import { LogSheet } from "./LogSheet";
import { CopyPagesSheet } from "./CopyPagesSheet";
import { EditionSheet } from "./EditionSheet";
import { Card, Cover, PersonLine, ProgressBar, RecommendBadge, SectionTitle, Sheet, Spinner, Stars, TopBar } from "./ui";
import { byline, editionLine, formatDay, percentText, usePalette } from "./format";

// One work on one person's shelf. For your own: the read in progress and what
// can be done to it, every earlier read with its review, and the way into the
// book club. For somebody else's: their reads and reviews, read-only.
//
// The cover and title are the reader's edition's, which they can change here.
// Changing it offers the new edition's length for the read in progress rather
// than setting it: the book club trusts a length only the reader confirmed.

type RunWithReview = EntryDetail["runs"][number];

function EndSheet({ run, onClose }: { run: RunWithReview; onClose: () => void }) {
  const palette = usePalette();
  const navigate = useNavigate();
  const [day, setDay] = useState(localDay());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function end(status: "finished" | "dnf") {
    setBusy(true);
    setError(null);
    try {
      await shelfSend("post", `/runs/${run.id}/finish`, { status, finishedOn: day });
      invalidateShelf();
      onClose();
      navigate(`/books/finish/${run.id}`);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <Sheet title="Done with it?" onClose={onClose}>
      <label className="block pb-4 text-sm text-slate-600">
        On
        <input
          type="date"
          value={day}
          max={localDay()}
          onChange={(event) => setDay(event.target.value)}
          className="mt-1 block w-full rounded-xl border border-slate-200 px-3 py-2.5 text-[16px]"
        />
      </label>
      {error ? <p className="pb-2 text-sm text-rose-600">{error}</p> : null}
      <div className="flex flex-col gap-2 pb-2">
        <button
          type="button"
          disabled={busy}
          onClick={() => end("finished")}
          className="rounded-full py-3.5 font-semibold text-white disabled:opacity-60"
          style={{ background: palette.accent }}
        >
          Finished it
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={() => end("dnf")}
          className="rounded-full border border-slate-300 py-3.5 font-medium text-slate-700 disabled:opacity-60"
        >
          Did not finish
        </button>
      </div>
      <p className="pb-2 text-xs text-slate-500">
        Finishing counts any pages you didn't log as read on that day. A DNF keeps the pages you got through.
      </p>
    </Sheet>
  );
}

function LogRow({ log, isLatest }: { log: ProgressLogRow; isLatest: boolean }) {
  const [editing, setEditing] = useState(false);
  const [note, setNote] = useState(log.note ?? "");
  const [busy, setBusy] = useState(false);
  const moved = log.toPosition - log.fromPosition;

  async function undo() {
    if (!window.confirm("Remove this entry?")) return;
    setBusy(true);
    try {
      await shelfSend("delete", `/logs/${log.id}`);
      invalidateShelf();
    } finally {
      setBusy(false);
    }
  }

  async function saveNote() {
    setBusy(true);
    try {
      await shelfSend("put", `/logs/${log.id}`, { note: note.trim() || null });
      invalidateShelf();
      setEditing(false);
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="border-b border-slate-100 py-2.5 last:border-0">
      <div className="flex items-center justify-between gap-2 text-sm">
        <span className="text-slate-500">{formatDay(log.loggedOn)}</span>
        <span className="flex-1 tabular-nums text-slate-800">
          {moved >= 0 ? `+${moved}` : moved} → p. {log.toPosition}
          {log.source === "koreader" ? (
            <span className="ml-2 rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-500">KOReader</span>
          ) : null}
        </span>
        <button type="button" onClick={() => setEditing((value) => !value)} className="text-xs font-medium text-slate-500">
          {log.note ? "Edit note" : "Add note"}
        </button>
        {isLatest ? (
          <button type="button" onClick={undo} disabled={busy} className="text-xs font-medium text-rose-600">
            Undo
          </button>
        ) : null}
      </div>
      {log.note && !editing ? <p className="mt-1 whitespace-pre-wrap text-sm text-slate-600">“{log.note}”</p> : null}
      {editing ? (
        <div className="mt-2 flex gap-2">
          <textarea
            value={note}
            onChange={(event) => setNote(event.target.value)}
            rows={2}
            className="flex-1 resize-none rounded-xl border border-slate-200 p-2 text-sm"
          />
          <button type="button" onClick={saveNote} disabled={busy} className="self-end rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white">
            Save
          </button>
        </div>
      ) : null}
    </li>
  );
}

function PastRun({ run, isMine }: { run: RunWithReview; isMine: boolean }) {
  const palette = usePalette();
  const navigate = useNavigate();
  const review = run.review;
  const hasReview = review && (review.rating !== null || review.recommend !== null || review.body);

  async function remove() {
    if (!window.confirm(`Delete read #${run.number}, its pages and its review? This can't be undone.`)) return;
    await shelfSend("delete", `/runs/${run.id}`);
    invalidateShelf();
    navigate("/books", { replace: true });
  }

  return (
    <Card className="!p-3.5">
      <div className="flex items-center justify-between gap-2 text-sm">
        <span className="font-semibold text-slate-800">
          {run.number > 1 ? `Read #${run.number}` : "Read"}
          {run.status === "dnf" ? <span className="ml-1.5 rounded bg-slate-100 px-1.5 py-0.5 text-xs font-medium text-slate-600">DNF</span> : null}
        </span>
        <span className="text-slate-500">
          {run.startedOn ? `${formatDay(run.startedOn)} – ` : ""}
          {formatDay(run.finishedOn)}
        </span>
      </div>
      {hasReview ? (
        <Link to={`/books/review/${review.id}`} className="mt-2 block">
          <div className="flex flex-wrap items-center gap-2">
            <Stars rating={review.rating} />
            <RecommendBadge recommend={review.recommend} />
          </div>
          {review.body ? <p className="mt-1.5 line-clamp-3 whitespace-pre-wrap text-[15px] text-slate-700">{review.body}</p> : null}
          <p className="mt-1.5 text-xs text-slate-500">
            {review.commentCount > 0 ? `${review.commentCount} in the discussion · ` : ""}
            {review.loungePostId ? "On the Lounge · " : ""}
            Open ›
          </p>
        </Link>
      ) : null}
      {isMine ? (
        <div className="mt-2 flex gap-4 text-sm">
          <Link to={`/books/finish/${run.id}?edit=1`} className="font-medium" style={{ color: palette.accent }}>
            {hasReview ? "Edit review" : "Write a review"}
          </Link>
          <button type="button" onClick={remove} className="ml-auto text-slate-400">
            Delete
          </button>
        </div>
      ) : null}
    </Card>
  );
}

/**
 * A book the catalog did not supply — typed in by hand, or imported while
 * the catalog had no match — and the way to look it up again. Found, the book
 * moves onto the catalog's work for everyone holding this copy, which is what
 * puts its readers in one book club.
 */
function FindInCatalogCard({ entryId }: { entryId: number }) {
  const palette = usePalette();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function find() {
    setBusy(true);
    setMessage(null);
    try {
      const { entryId: moved } = await shelfSend<{ entryId: number }>("post", `/entries/${entryId}/rematch`);
      invalidateShelf();
      navigate(`/books/item/${moved}`, { replace: true });
    } catch (e) {
      setMessage(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mt-4 rounded-2xl border border-dashed bg-white/70 px-4 py-3" style={{ borderColor: palette.border }}>
      <p className="text-sm text-slate-600">
        Added from your own details, so it has no genres and a book club of its own. If the book catalog has it, finding
        it fixes both.
      </p>
      {message ? <p className="mt-1.5 text-sm text-amber-700">{message}</p> : null}
      <button type="button" onClick={find} disabled={busy} className="mt-2 text-sm font-semibold disabled:opacity-60" style={{ color: palette.accent }}>
        {busy ? "Looking…" : "Find it in the catalog"}
      </button>
    </div>
  );
}

export function ItemScreen() {
  const { entryId } = useParams();
  const palette = usePalette();
  const navigate = useNavigate();
  const { data: entry, error } = useShelf<EntryDetail>(`/entries/${entryId}`);
  const others = useShelf<{ reviews: FeedReview[] }>(entry ? `/reviews?scope=everyone&itemId=${entry.item.id}&limit=10` : null);
  const [logging, setLogging] = useState(false);
  const [ending, setEnding] = useState(false);
  const [copyLength, setCopyLength] = useState<{ initial: number | null; note?: string } | null>(null);
  const [choosingEdition, setChoosingEdition] = useState(false);
  const [starting, setStarting] = useState(false);
  const [busy, setBusy] = useState(false);

  if (!entry) {
    return (
      <>
        <TopBar title="" />
        {error ? <p className="p-8 text-center text-sm text-slate-500">This book isn't here any more.</p> : <Spinner />}
      </>
    );
  }

  const { item } = entry;
  const active = entry.runs.find((run) => run.status === "active");
  const past = entry.runs.filter((run) => run.status !== "active");
  const otherReviews = (others.data?.reviews ?? []).filter((review) => review.reviewer.id !== entry.owner.id);

  // The last read's length if it was the reader's own; otherwise the
  // catalog's, to be confirmed or corrected.
  const startPages =
    entry.runs.find((run) => run.unitsConfirmed && run.totalUnits)?.totalUnits ?? entry.runs[0]?.totalUnits ?? item.totalUnits;

  async function start(pages: number) {
    await shelfSend("post", `/entries/${entry!.id}/reread`, { today: localDay(), totalUnits: pages });
    invalidateShelf();
    setStarting(false);
  }

  async function setEditionTo(edition: CatalogEdition | null) {
    await shelfSend("put", `/entries/${entry!.id}/edition`, { edition });
    invalidateShelf();
    setChoosingEdition(false);
    if (active && edition?.totalUnits && edition.totalUnits !== active.totalUnits) {
      setCopyLength({
        initial: edition.totalUnits,
        note: `This edition has ${edition.totalUnits} pages. Saving it as your copy's length keeps the book club in step with where you are.`,
      });
    }
  }

  async function unwant() {
    setBusy(true);
    try {
      await shelfSend("delete", `/entries/${entry!.id}/want`);
      invalidateShelf();
      if (entry!.runs.length === 0) navigate("/books", { replace: true });
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <TopBar title={entry.isMine ? item.title : <PersonLine person={entry.owner} />} />
      <main className="mx-auto max-w-xl px-4 pb-8">
        <div className="flex gap-4 pt-5">
          <Cover item={item} size="lg" />
          <div className="min-w-0 flex-1">
            <h2 className="text-xl font-semibold leading-snug">{item.title}</h2>
            <p className="text-[15px] text-slate-600">{byline(item)}</p>
            <p className="mt-1 text-sm text-slate-500">
              {[item.year, (item.edition?.totalUnits ?? item.totalUnits) ? `${item.edition?.totalUnits ?? item.totalUnits} pages` : null]
                .filter(Boolean)
                .join(" · ")}
            </p>
            {item.edition || (entry.isMine && item.source === "openlibrary") ? (
              <p className="mt-0.5 text-xs text-slate-500">
                {item.edition ? editionLine({ ...item.edition, totalUnits: null }) : null}
                {entry.isMine && item.source === "openlibrary" ? (
                  <>
                    {item.edition ? " · " : null}
                    <button type="button" onClick={() => setChoosingEdition(true)} className="font-medium" style={{ color: palette.accent }}>
                      {item.edition ? "Change edition" : "Choose your edition"}
                    </button>
                  </>
                ) : null}
              </p>
            ) : null}
            {item.genres.length ? (
              <div className="mt-2 flex flex-wrap gap-1">
                {item.genres.map((genre) => (
                  <span key={genre} className="rounded-full px-2 py-0.5 text-xs" style={{ background: palette.postBg, color: palette.text }}>
                    {genre}
                  </span>
                ))}
              </div>
            ) : null}
          </div>
        </div>

        {entry.isMine && active ? (
          <>
            <SectionTitle>{entry.runs.length > 1 ? `Reading again · #${entry.runs.length}` : "Reading"}</SectionTitle>
            <Card>
              <ProgressBar fraction={active.fraction} color={palette.accent} />
              <div className="mt-1.5 flex items-center justify-between text-sm text-slate-600">
                <span className="tabular-nums">
                  p. {active.position}
                  {active.totalUnits ? ` of ${active.totalUnits} · ${percentText(active.fraction)}` : ""}
                </span>
                <button
                  type="button"
                  onClick={() => setCopyLength({ initial: active.totalUnits })}
                  className={`text-xs font-medium ${active.unitsConfirmed ? "text-slate-500" : "text-amber-700"}`}
                >
                  {active.unitsConfirmed ? "Your copy · change" : "Is that your copy's length?"}
                </button>
              </div>
              <div className="mt-3 grid grid-cols-2 gap-2">
                <button type="button" onClick={() => setEnding(true)} className="rounded-full border border-slate-300 py-2.5 font-medium text-slate-700">
                  Finish…
                </button>
                <button type="button" onClick={() => setLogging(true)} className="rounded-full py-2.5 font-semibold text-white" style={{ background: palette.accent }}>
                  + Pages
                </button>
              </div>
              {entry.recentLogs.length ? (
                <ul className="mt-3 border-t border-slate-100">
                  {entry.recentLogs.map((log, index) => (
                    <LogRow key={log.id} log={log} isLatest={index === 0} />
                  ))}
                </ul>
              ) : null}
            </Card>
          </>
        ) : null}

        {entry.isMine && !active ? (
          <div className="mt-5 flex gap-2">
            <button
              type="button"
              onClick={() => setStarting(true)}
              disabled={busy}
              className="flex-1 rounded-full py-3 font-semibold text-white disabled:opacity-60"
              style={{ background: palette.accent }}
            >
              {past.length ? "Read it again" : "Start reading"}
            </button>
            {entry.wantedAt ? (
              <button type="button" onClick={unwant} disabled={busy} className="rounded-full border border-slate-300 px-4 py-3 text-sm font-medium text-slate-600">
                Remove from want
              </button>
            ) : null}
          </div>
        ) : null}

        {entry.isMine && item.source === "manual" ? <FindInCatalogCard entryId={entry.id} /> : null}

        <Link to={`/books/club/${item.id}`} className="mt-4 flex items-center justify-between rounded-2xl border border-slate-200/70 bg-white px-4 py-3 shadow-sm">
          <span>
            <span className="font-medium">💬 Book club</span>
            <span className="block text-xs text-slate-500">Notes from everyone reading it, up to where you are.</span>
          </span>
          <span className="text-slate-400">›</span>
        </Link>

        {past.length ? (
          <>
            <SectionTitle>{entry.isMine ? "Your reads" : "Their reads"}</SectionTitle>
            <div className="flex flex-col gap-2">
              {past.map((run) => (
                <PastRun key={run.id} run={run} isMine={entry.isMine} />
              ))}
            </div>
          </>
        ) : null}

        {otherReviews.length ? (
          <>
            <SectionTitle>What others thought</SectionTitle>
            <div className="flex flex-col gap-2">
              {otherReviews.map((review) => (
                <Link key={review.id} to={`/books/review/${review.id}`}>
                  <Card className="!p-3.5">
                    <div className="flex items-center justify-between gap-2">
                      <PersonLine person={review.reviewer} />
                      <Stars rating={review.rating} />
                    </div>
                    {review.body ? <p className="mt-1.5 line-clamp-2 text-sm text-slate-700">{review.body}</p> : null}
                    <div className="mt-1.5">
                      <RecommendBadge recommend={review.recommend} />
                    </div>
                  </Card>
                </Link>
              ))}
            </div>
          </>
        ) : null}
      </main>

      {logging && active ? <LogSheet run={active} item={item} onClose={() => setLogging(false)} /> : null}
      {ending && active ? <EndSheet run={active} onClose={() => setEnding(false)} /> : null}
      {copyLength && active ? (
        <CopyPagesSheet
          title={item.title}
          initial={copyLength.initial}
          note={copyLength.note}
          confirmLabel="Save"
          onClose={() => setCopyLength(null)}
          onConfirm={async (pages) => {
            await shelfSend("put", `/runs/${active.id}`, { totalUnits: pages });
            invalidateShelf();
            setCopyLength(null);
          }}
        />
      ) : null}
      {choosingEdition ? (
        <EditionSheet
          title={item.title}
          path={`/items/${item.id}/editions`}
          currentId={item.edition?.externalId ?? null}
          onClose={() => setChoosingEdition(false)}
          onPick={setEditionTo}
          onReset={item.edition ? () => setEditionTo(null) : undefined}
        />
      ) : null}
      {starting ? (
        <CopyPagesSheet
          title={item.title}
          initial={startPages}
          confirmLabel={past.length ? "Read it again" : "Start reading"}
          onClose={() => setStarting(false)}
          onConfirm={start}
        />
      ) : null}
    </>
  );
}
