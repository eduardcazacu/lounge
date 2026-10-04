import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { errorMessage, invalidateShelf, localDay, shelfSend, useShelf } from "./api";
import type { FeedReview, WorkDetail } from "./api";
import { CopyPagesSheet } from "./CopyPagesSheet";
import { EndedSheet } from "./AddScreen";
import { BookHeader, Card, PersonLine, RecommendBadge, ReviewBody, SectionTitle, Spinner, Stars, TopBar } from "./ui";
import { SHELF_LABEL, usePalette } from "./format";

// A work as the group sees it: where it stands on your shelf, who else is
// reading it or wants to, what everyone thought, and the way into the book
// club. Everything that is about the book rather than one person's copy of it
// is here; your own reads, logs and edition are on your copy's page
// (ItemScreen), which links back.
//
// The cover and title are an English edition's where the catalog holds one,
// else the work's own; never the viewer's edition, since the page belongs to
// nobody's shelf in particular (englishEditions in backend/src/route/shelf.ts).

/**
 * Where the book stands on your shelf, linking to your copy, or Want, Start
 * and Read it, which add this same work — never a search for it, which could
 * land on another — as the add screen does.
 */
function QuickAdd({ work }: { work: WorkDetail }) {
  const palette = usePalette();
  const navigate = useNavigate();
  const [starting, setStarting] = useState(false);
  const [ending, setEnding] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { item, mine } = work;

  if (mine) {
    return (
      <Link
        to={`/books/item/${mine.entryId}`}
        className="mt-4 inline-block rounded-full px-3 py-1 text-sm font-medium"
        style={{ background: palette.postBg, color: palette.accent }}
      >
        ✓ In your library · {SHELF_LABEL[mine.status]} ›
      </Link>
    );
  }

  async function want() {
    setBusy(true);
    setError(null);
    try {
      await shelfSend("post", "/entries", { itemId: item.id, intent: "want", today: localDay() });
      // The refetch brings `mine`, which turns the buttons into the tag above.
      invalidateShelf();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const button = "flex-1 rounded-full py-2.5 text-sm disabled:opacity-60";
  return (
    <div className="mt-4">
      <div className="flex gap-2">
        <button type="button" onClick={want} disabled={busy} className={`${button} font-medium`} style={{ background: palette.postBg, color: palette.text }}>
          Want
        </button>
        <button type="button" onClick={() => setStarting(true)} disabled={busy} className={`${button} font-semibold text-white`} style={{ background: palette.accent }}>
          Start
        </button>
        <button type="button" onClick={() => setEnding(true)} disabled={busy} className={`${button} font-medium`} style={{ background: palette.postBg, color: palette.text }}>
          Read it
        </button>
      </div>
      {error ? <p className="mt-1.5 text-sm text-rose-600">{error}</p> : null}
      {starting ? (
        <CopyPagesSheet
          title={item.title}
          // The length of the edition shown, which adding makes the reader's own.
          initial={item.edition?.totalUnits ?? item.totalUnits}
          confirmLabel="Start reading"
          onClose={() => setStarting(false)}
          onConfirm={async (pages) => {
            await shelfSend("post", "/entries", { itemId: item.id, intent: "start", totalUnits: pages, today: localDay() });
            invalidateShelf();
            setStarting(false);
            navigate("/books");
          }}
        />
      ) : null}
      {ending ? (
        <EndedSheet
          book={{ ...item, totalUnits: item.edition?.totalUnits ?? item.totalUnits }}
          target={{ itemId: item.id }}
          intent="finished"
          onClose={() => setEnding(false)}
          onDone={(runId) => navigate(`/books/finish/${runId}?backfill=1`)}
        />
      ) : null}
    </div>
  );
}

/** Who else in the group is reading the book now, and who wants to. Each opens their library. */
function Shelvers({ shelvers }: { shelvers: WorkDetail["shelvers"] }) {
  const rows = [
    { label: "Reading now", people: shelvers.reading },
    { label: "Want to read", people: shelvers.want },
  ].filter((row) => row.people.length > 0);
  if (rows.length === 0) return null;
  return (
    <>
      <SectionTitle>Friends with it</SectionTitle>
      <Card className="!p-3.5">
        {rows.map((row, index) => (
          <div key={row.label} className={index > 0 ? "mt-2.5 border-t border-slate-100 pt-2.5" : ""}>
            <div className="text-xs font-medium text-slate-500">{row.label}</div>
            <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-2">
              {row.people.map((person) => (
                <Link key={person.id} to={`/books/people/${person.id}`} className="min-w-0 max-w-full">
                  <PersonLine person={person} />
                </Link>
              ))}
            </div>
          </div>
        ))}
      </Card>
    </>
  );
}

export function WorkScreen() {
  const { itemId } = useParams();
  const { data: work, error } = useShelf<WorkDetail>(`/items/${itemId}`);
  const reviews = useShelf<{ reviews: FeedReview[] }>(`/reviews?scope=everyone&itemId=${itemId}&limit=20`);

  if (!work) {
    return (
      <>
        <TopBar title="" />
        {error ? <p className="p-8 text-center text-sm text-slate-500">This book isn't here any more.</p> : <Spinner />}
      </>
    );
  }

  const { item } = work;
  const reviewList = reviews.data?.reviews ?? [];

  return (
    <>
      <TopBar title={item.title} />
      <main className="mx-auto max-w-xl px-4 pb-8">
        <BookHeader item={item} />

        <QuickAdd work={work} />

        <Link to={`/books/club/${item.id}`} className="mt-4 flex items-center justify-between rounded-2xl border border-slate-200/70 bg-white px-4 py-3 shadow-sm">
          <span>
            <span className="font-medium">💬 Book club</span>
            <span className="block text-xs text-slate-500">Notes from everyone reading it, up to where you are.</span>
          </span>
          <span className="text-slate-400">›</span>
        </Link>

        <Shelvers shelvers={work.shelvers} />

        {reviewList.length ? (
          <>
            <SectionTitle>What people thought</SectionTitle>
            <div className="flex flex-col gap-2">
              {reviewList.map((review) => (
                <Link key={review.id} to={`/books/review/${review.id}`}>
                  <Card className="!p-3.5">
                    <div className="flex items-center justify-between gap-2">
                      <PersonLine person={review.reviewer} />
                      <Stars rating={review.rating} />
                    </div>
                    <ReviewBody review={review} className="mt-1.5 line-clamp-2 text-sm text-slate-700" />
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
    </>
  );
}
