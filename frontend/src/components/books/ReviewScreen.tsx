import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { getThemePalette } from "../../themes";
import { formatPostedTime } from "../../lib/datetime";
import { errorMessage, invalidateShelf, shelfSend, useShelf } from "./api";
import type { ReviewDetail } from "./api";
import { Discussion } from "./Discussion";
import { Cover, PersonLine, RecommendBadge, Spinner, SpoilerCover, SpoilerTag, Stars, TopBar } from "./ui";
import { byline, formatDay, usePalette } from "./format";

// One review and its discussion. This is where a Lounge card for a review
// lands, and where a notification about a reply opens. A spoiler covers the
// discussion along with the review: the replies give the ending away as
// readily as the review does.

export function ReviewScreen() {
  const { reviewId } = useParams();
  const palette = usePalette();
  const { data, error, reload } = useShelf<{ review: ReviewDetail }>(`/reviews/${reviewId}`);
  const [busy, setBusy] = useState(false);
  const [loungeError, setLoungeError] = useState<string | null>(null);
  const [shown, setShown] = useState(false);

  if (!data) {
    return (
      <>
        <TopBar title="Review" />
        {error ? <p className="p-8 text-center text-sm text-slate-500">This review isn't here any more.</p> : <Spinner />}
      </>
    );
  }

  const { review } = data;
  const reviewerPalette = getThemePalette(review.reviewer.themeKey);
  const covered = review.covered && !shown;

  async function postToLounge() {
    setBusy(true);
    try {
      await shelfSend("post", `/reviews/${review.id}/lounge`);
      invalidateShelf();
    } catch (e) {
      setLoungeError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <TopBar
        title="Review"
        right={
          review.isMine ? (
            <Link to={`/books/finish/${review.run.id}?edit=1`} className="rounded-full px-3 py-1.5 text-sm font-semibold" style={{ color: palette.accent }}>
              Edit
            </Link>
          ) : null
        }
      />
      <main className="mx-auto max-w-xl px-4 pb-8">
        <article className="mt-4 rounded-2xl bg-white p-4 shadow-sm" style={{ borderTop: `3px solid ${reviewerPalette.border}` }}>
          <div className="flex items-center justify-between gap-2">
            <Link to={`/books/people/${review.reviewer.id}`} className="min-w-0">
              <PersonLine person={review.reviewer} />
            </Link>
            <span className="shrink-0 text-xs text-slate-500">{formatPostedTime(review.createdAt)}</span>
          </div>
          <Link to={`/books/item/${review.entryId}`} className="mt-3 flex gap-3">
            <Cover item={review.item} size="md" />
            <div className="min-w-0">
              <div className="font-semibold leading-snug">{review.item.title}</div>
              <div className="text-sm text-slate-500">{byline(review.item)}</div>
              <div className="mt-1 text-xs text-slate-500">
                {review.run.status === "dnf" ? "Did not finish" : "Finished"}
                {review.run.finishedOn ? ` ${formatDay(review.run.finishedOn)}` : ""}
                {review.readNumber > 1 ? ` · re-read #${review.readNumber}` : ""}
              </div>
            </div>
          </Link>
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <Stars rating={review.rating} size={18} />
            <RecommendBadge recommend={review.recommend} />
            {review.spoiler && !covered ? <SpoilerTag /> : null}
          </div>
          {covered ? (
            <SpoilerCover onShow={() => setShown(true)} what={review.body ? "This review and its discussion" : "The discussion"} />
          ) : review.body ? (
            <p className="mt-3 whitespace-pre-wrap text-[16px] leading-relaxed text-slate-800">{review.body}</p>
          ) : null}
          {review.loungePostId ? (
            <Link to={`/blog/${review.loungePostId}`} className="mt-3 inline-block text-xs font-medium text-slate-500">
              Also on the Lounge ›
            </Link>
          ) : review.isMine ? (
            <button type="button" onClick={postToLounge} disabled={busy} className="mt-3 text-sm font-medium" style={{ color: palette.accent }}>
              Post this on the Lounge
            </button>
          ) : null}
          {loungeError ? <p className="mt-2 text-sm text-rose-600">{loungeError}</p> : null}
        </article>

        {covered ? null : (
          <Discussion
            path={`/reviews/${review.id}`}
            comments={review.comments}
            canDelete={review.isMine}
            onChanged={reload}
            empty="Nothing yet. Say what you thought of it too."
            placeholder="Add to the discussion"
          />
        )}
      </main>
    </>
  );
}
