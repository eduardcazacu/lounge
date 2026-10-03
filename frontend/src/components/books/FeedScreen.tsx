import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { errorMessage, shelfGet, useShelf } from "./api";
import type { FeedPost } from "./api";
import { ReviewCard } from "./ReviewCard";
import { AskCard, AskSheet } from "./AskCard";
import { EmptyNote, Spinner, TopBar } from "./ui";
import { usePalette } from "./format";

// Reviews and asks for a recommendation, newest first: everyone's, or only
// yours. No ranking — the Lounge has nothing to rank away (wiki/product.md).

type Page = { posts: FeedPost[]; nextCursor: string | null };

export function FeedScreen() {
  const palette = usePalette();
  const [params, setParams] = useSearchParams();
  const scope = params.get("scope") === "mine" ? "mine" : "everyone";
  const { data: first, error } = useShelf<Page>(`/feed?scope=${scope}`);
  const [more, setMore] = useState<FeedPost[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [asking, setAsking] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [moreError, setMoreError] = useState<string | null>(null);

  // A fresh first page — a new tab, or a refetch after a write — starts the
  // list over from it.
  useEffect(() => {
    setMore([]);
    setCursor(first?.nextCursor ?? null);
  }, [first]);

  async function loadMore() {
    if (!cursor) return;
    setLoadingMore(true);
    setMoreError(null);
    try {
      const page = await shelfGet<Page>(`/feed?scope=${scope}&cursor=${encodeURIComponent(cursor)}`);
      setMore((previous) => [...previous, ...page.posts]);
      setCursor(page.nextCursor);
    } catch (e) {
      setMoreError(errorMessage(e));
    } finally {
      setLoadingMore(false);
    }
  }

  const posts = [...(first?.posts ?? []), ...more];

  return (
    <>
      <TopBar
        title="Reviews"
        back={false}
        right={
          <button
            type="button"
            onClick={() => setAsking(true)}
            className="rounded-full px-3 py-1.5 text-sm font-semibold"
            style={{ color: palette.accent }}
          >
            🙋 Ask
          </button>
        }
      />
      {asking ? <AskSheet onClose={() => setAsking(false)} /> : null}
      <main className="mx-auto max-w-xl px-4 pb-8">
        <div className="my-3 flex rounded-full bg-white p-1 text-sm font-medium shadow-sm">
          {(["everyone", "mine"] as const).map((option) => (
            <button
              key={option}
              type="button"
              onClick={() => setParams(option === "mine" ? { scope: "mine" } : {}, { replace: true })}
              className="flex-1 rounded-full py-2"
              style={scope === option ? { background: palette.accent, color: "white" } : { color: "#64748b" }}
            >
              {option === "everyone" ? "Everyone" : "Mine"}
            </button>
          ))}
        </div>

        {!first ? (
          error ? <EmptyNote>Couldn't load reviews.</EmptyNote> : <Spinner />
        ) : posts.length === 0 ? (
          <EmptyNote>
            {scope === "mine"
              ? "Finish a book and say what you thought, or ask for a recommendation — it shows up here."
              : "No reviews yet. Be the first: finish a book and rate it, or ask what to read next."}
          </EmptyNote>
        ) : (
          <div className="flex flex-col gap-3">
            {posts.map((post) =>
              post.kind === "ask" ? <AskCard key={`ask-${post.id}`} ask={post} /> : <ReviewCard key={`review-${post.id}`} review={post} />
            )}
            {cursor ? (
              <button
                type="button"
                onClick={loadMore}
                disabled={loadingMore}
                className="py-3 text-sm font-medium disabled:opacity-60"
                style={{ color: palette.accent }}
              >
                {loadingMore ? "Loading…" : "Older posts"}
              </button>
            ) : null}
            {moreError ? <p className="text-center text-sm text-rose-600">{moreError}</p> : null}
          </div>
        )}
      </main>
    </>
  );
}
