import { useNavigate } from "react-router-dom";
import { getThemePalette } from "../../themes";
import { formatPostedTime } from "../../lib/datetime";
import type { FeedReview } from "./api";
import { Cover, PersonLine, RecommendBadge, ReviewBody, SpoilerTag, Stars } from "./ui";
import { byline } from "./format";

// A review in the feed. Tinted by the reviewer's palette, like a post on the
// Lounge, so whose it is shows before the name is read.

export function ReviewCard({ review }: { review: FeedReview }) {
  const navigate = useNavigate();
  const palette = getThemePalette(review.reviewer.themeKey);
  const open = () => navigate(`/books/review/${review.id}`);

  return (
    <article
      onClick={open}
      onKeyDown={(event) => {
        if (event.key === "Enter") open();
      }}
      role="link"
      tabIndex={0}
      className="cursor-pointer rounded-2xl bg-white p-4 shadow-sm transition-shadow hover:shadow-md"
      style={{ borderTop: `3px solid ${palette.border}` }}
    >
      <div className="flex items-center justify-between gap-2">
        <PersonLine person={review.reviewer} />
        <span className="shrink-0 text-xs text-slate-500">{formatPostedTime(review.createdAt)}</span>
      </div>
      <div className="mt-3 flex gap-3">
        <Cover item={review.item} size="sm" />
        <div className="min-w-0 flex-1">
          <div className="line-clamp-2 font-semibold leading-snug">{review.item.title}</div>
          <div className="truncate text-sm text-slate-500">{byline(review.item)}</div>
          <div className="mt-1.5 flex flex-wrap items-center gap-2">
            <Stars rating={review.rating} />
            <RecommendBadge recommend={review.recommend} />
            {review.run.status === "dnf" ? <span className="rounded bg-slate-100 px-1.5 py-0.5 text-xs font-medium text-slate-600">DNF</span> : null}
            {review.readNumber > 1 ? <span className="text-xs text-slate-500">Re-read #{review.readNumber}</span> : null}
            {review.spoiler && !review.covered ? <SpoilerTag /> : null}
          </div>
        </div>
      </div>
      <ReviewBody review={review} className="mt-3 line-clamp-4 whitespace-pre-wrap text-[15px] leading-relaxed text-slate-700" />
      <div className="mt-3 text-xs font-medium" style={{ color: palette.accent }}>
        💬 {review.commentCount > 0 ? `${review.commentCount} in the discussion` : "Discuss"}
      </div>
    </article>
  );
}
