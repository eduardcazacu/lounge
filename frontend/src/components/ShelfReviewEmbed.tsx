import { Link } from "react-router-dom";
import type { ShelfReviewCard } from "../hooks";

// A review cross-posted from /books, as the Lounge shows it: the cover, the
// stars, the verdict and the opening of what was said, all read live from the
// review rather than from the post's own text, so an edit on /books shows here
// too. Tapping it opens the review and its discussion in Books. See
// wiki/books.md.
//
// Stars are text here rather than Books' own star component: the blog would
// otherwise pull Books' code into its chunk for five glyphs.

function starText(rating: number) {
  return "★".repeat(Math.floor(rating / 2)) + (rating % 2 ? "½" : "");
}

export function ShelfReviewEmbed({ review, full = false }: { review: ShelfReviewCard; full?: boolean }) {
  const verb = review.status === "dnf" ? "Did not finish" : "Read";
  return (
    <Link
      to={`/books/review/${review.id}`}
      onClick={(event) => event.stopPropagation()}
      className="mt-2 flex gap-3 rounded-xl border border-slate-200 bg-slate-50 p-3 no-underline"
    >
      {review.item.coverUrl ? (
        <img src={review.item.coverUrl} alt="" loading="lazy" className="h-24 w-16 shrink-0 rounded-md object-cover shadow-sm ring-1 ring-black/10" />
      ) : (
        <div className="flex h-24 w-16 shrink-0 items-center justify-center rounded-md bg-amber-100 p-1 text-center text-[10px] font-semibold text-amber-900">
          {review.item.title}
        </div>
      )}
      <div className="min-w-0 flex-1">
        <div className="text-xs font-medium uppercase tracking-wide text-slate-500">📚 {verb}</div>
        <div className="font-semibold leading-snug text-slate-900">{review.item.title}</div>
        {review.item.creators.length ? <div className="truncate text-sm text-slate-500">{review.item.creators.join(", ")}</div> : null}
        <div className="mt-1 flex flex-wrap items-center gap-2 text-sm">
          {review.rating !== null ? <span className="text-amber-500">{starText(review.rating)}</span> : null}
          {review.recommend !== null ? (
            <span className={review.recommend ? "text-emerald-700" : "text-rose-700"}>
              {review.recommend ? "👍 Recommends" : "👎 Doesn't recommend"}
            </span>
          ) : null}
        </div>
        {review.body ? (
          <p className={`mt-1.5 whitespace-pre-wrap text-sm text-slate-700 ${full ? "" : "line-clamp-3"}`}>{review.body}</p>
        ) : null}
        <div className="mt-1.5 text-xs font-medium text-slate-500">Open in Books ›</div>
      </div>
    </Link>
  );
}
