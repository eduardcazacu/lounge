import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { getThemePalette } from "../../themes";
import { formatPostedTime } from "../../lib/datetime";
import { getCurrentUserId } from "../../lib/auth";
import { errorMessage, invalidateShelf, shelfSend, useShelf } from "./api";
import type { ReviewComment, ReviewDetail } from "./api";
import { Cover, PersonLine, RecommendBadge, SectionTitle, Spinner, Stars, TopBar } from "./ui";
import { byline, formatDay, usePalette } from "./format";

// One review and its discussion. This is where a Lounge card for a review
// lands, and where a notification about a reply opens.

function CommentRow({
  reviewId,
  comment,
  canDelete,
  onChanged,
}: {
  reviewId: number;
  comment: ReviewComment;
  canDelete: boolean;
  onChanged: () => void;
}) {
  const mine = comment.author.id === getCurrentUserId();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(comment.content);
  const [busy, setBusy] = useState(false);
  const palette = getThemePalette(comment.author.themeKey);

  async function save() {
    if (!draft.trim()) return;
    setBusy(true);
    try {
      await shelfSend("put", `/reviews/${reviewId}/comments/${comment.id}`, { content: draft.trim() });
      setEditing(false);
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!window.confirm("Delete this comment?")) return;
    setBusy(true);
    try {
      await shelfSend("delete", `/reviews/${reviewId}/comments/${comment.id}`);
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="rounded-2xl bg-white p-3.5 shadow-sm" style={{ borderLeft: `3px solid ${palette.border}` }}>
      <div className="flex items-center justify-between gap-2">
        <PersonLine person={comment.author} />
        <span className="shrink-0 text-xs text-slate-500">
          {formatPostedTime(comment.createdAt)}
          {comment.editedAt ? " · edited" : ""}
        </span>
      </div>
      {editing ? (
        <div className="mt-2">
          <textarea value={draft} onChange={(event) => setDraft(event.target.value)} rows={3} className="w-full resize-none rounded-xl border border-slate-200 p-2 text-[15px]" />
          <div className="flex justify-end gap-3 text-sm">
            <button type="button" onClick={() => setEditing(false)} className="text-slate-500">
              Cancel
            </button>
            <button type="button" onClick={save} disabled={busy} className="font-semibold">
              Save
            </button>
          </div>
        </div>
      ) : (
        <p className="mt-1.5 whitespace-pre-wrap text-[15px] text-slate-800">{comment.content}</p>
      )}
      {(mine || canDelete) && !editing ? (
        <div className="mt-1.5 flex gap-4 text-xs text-slate-500">
          {mine ? (
            <button type="button" onClick={() => setEditing(true)}>
              Edit
            </button>
          ) : null}
          <button type="button" onClick={remove} disabled={busy}>
            Delete
          </button>
        </div>
      ) : null}
    </li>
  );
}

export function ReviewScreen() {
  const { reviewId } = useParams();
  const palette = usePalette();
  const { data, error, reload } = useShelf<{ review: ReviewDetail }>(`/reviews/${reviewId}`);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);

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

  async function send() {
    if (!draft.trim()) return;
    setBusy(true);
    setSendError(null);
    try {
      await shelfSend("post", `/reviews/${review.id}/comments`, { content: draft.trim() });
      setDraft("");
      await reload();
    } catch (e) {
      setSendError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function postToLounge() {
    setBusy(true);
    try {
      await shelfSend("post", `/reviews/${review.id}/lounge`);
      invalidateShelf();
    } catch (e) {
      setSendError(errorMessage(e));
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
          </div>
          {review.body ? <p className="mt-3 whitespace-pre-wrap text-[16px] leading-relaxed text-slate-800">{review.body}</p> : null}
          {review.loungePostId ? (
            <Link to={`/blog/${review.loungePostId}`} className="mt-3 inline-block text-xs font-medium text-slate-500">
              Also on the Lounge ›
            </Link>
          ) : review.isMine ? (
            <button type="button" onClick={postToLounge} disabled={busy} className="mt-3 text-sm font-medium" style={{ color: palette.accent }}>
              Post this on the Lounge
            </button>
          ) : null}
        </article>

        <SectionTitle>Discussion</SectionTitle>
        <ul className="flex flex-col gap-2">
          {review.comments.length === 0 ? (
            <li className="px-1 text-sm text-slate-500">Nothing yet. Say what you thought of it too.</li>
          ) : (
            review.comments.map((comment) => (
              <CommentRow key={comment.id} reviewId={review.id} comment={comment} canDelete={review.isMine} onChanged={() => void reload()} />
            ))
          )}
        </ul>

        <form
          className="mt-3 flex items-end gap-2 rounded-2xl bg-white p-2 shadow-sm"
          onSubmit={(event) => {
            event.preventDefault();
            void send();
          }}
        >
          <textarea
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            rows={2}
            maxLength={2000}
            placeholder="Add to the discussion"
            className="min-w-0 flex-1 resize-none bg-transparent p-2 text-[15px] outline-none"
          />
          <button
            type="submit"
            disabled={busy || !draft.trim()}
            className="rounded-full px-4 py-2 text-sm font-semibold text-white disabled:opacity-40"
            style={{ background: palette.accent }}
          >
            Send
          </button>
        </form>
        {sendError ? <p className="mt-2 text-sm text-rose-600">{sendError}</p> : null}
      </main>
    </>
  );
}
