import { Link } from "react-router-dom";
import type { ShelfAskCard } from "../hooks";

// An ask cross-posted from /books, as the Lounge shows it: the review card's
// frame with no book in it, read live from the ask. Tapping it opens the ask
// in Books, where the suggestions are. See wiki/books.md.

export function ShelfAskEmbed({ ask, full = false }: { ask: ShelfAskCard; full?: boolean }) {
  return (
    <Link
      to={`/books/ask/${ask.id}`}
      onClick={(event) => event.stopPropagation()}
      className="mt-2 block rounded-xl border border-slate-200 bg-slate-50 p-3 no-underline"
    >
      <div className="text-xs font-medium uppercase tracking-wide text-slate-500">🙋 Looking for a recommendation</div>
      <p className={`mt-1.5 whitespace-pre-wrap text-[15px] text-slate-800 ${full ? "" : "line-clamp-4"}`}>{ask.body}</p>
      <div className="mt-1.5 text-xs font-medium text-slate-500">
        {ask.commentCount > 0 ? `${ask.commentCount} ${ask.commentCount === 1 ? "suggestion" : "suggestions"} in Books ›` : "Suggest something in Books ›"}
      </div>
    </Link>
  );
}
