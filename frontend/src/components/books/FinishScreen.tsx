import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { errorMessage, invalidateShelf, shelfSend, useShelf } from "./api";
import type { Item, Review, Run } from "./api";
import { Cover, Spinner, StarInput, TopBar } from "./ui";
import { byline, usePalette } from "./format";

// The prompt after finishing (or giving up on) a book, and the editor for a
// review later. Every part is optional — stars, a thumbs up or down, a few
// words — and Skip is as big as Save, because a reader who just closed a book
// owes nobody a review. "Also post on the Lounge" puts a card in the Lounge's
// feed that links back here; the card reads the review live, so editing it
// later edits the card.

type RunDetail = {
  entryId: number;
  item: Item;
  run: Run;
  isReread: boolean;
  review: (Review & { loungePostId: number | null }) | null;
};

export function FinishScreen() {
  const { runId } = useParams();
  const [params] = useSearchParams();
  const editing = params.get("edit") === "1";
  const backfill = params.get("backfill") === "1";
  const navigate = useNavigate();
  const palette = usePalette();
  const { data, error: loadError } = useShelf<RunDetail>(`/runs/${runId}`);

  const [rating, setRating] = useState<number | null>(null);
  const [recommend, setRecommend] = useState<boolean | null>(null);
  const [body, setBody] = useState("");
  const [toLounge, setToLounge] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [seeded, setSeeded] = useState(false);

  // Fill the form once, from the review as it stands, and never again: a
  // refetch while someone is typing must not put the old text back.
  useEffect(() => {
    if (!data || seeded) return;
    setRating(data.review?.rating ?? null);
    setRecommend(data.review?.recommend ?? null);
    setBody(data.review?.body ?? "");
    setSeeded(true);
  }, [data, seeded]);

  if (!data) {
    return (
      <>
        <TopBar title="Review" />
        {loadError ? <p className="p-8 text-center text-sm text-slate-500">This read isn't on your shelf.</p> : <Spinner />}
      </>
    );
  }

  const dnf = data.run.status === "dnf";
  const onLounge = data.review?.loungePostId !== null && data.review?.loungePostId !== undefined;
  const hasContent = rating !== null || recommend !== null || body.trim().length > 0;
  const title = editing ? "Your review" : dnf ? "Put it down" : backfill ? "Added to finished" : "Finished!";

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const { review } = await shelfSend<{ review: Review }>("put", `/runs/${runId}/review`, {
        rating,
        recommend,
        body: body.trim() || null,
      });
      if (toLounge && hasContent && !onLounge) {
        await shelfSend("post", `/reviews/${review.id}/lounge`);
      }
      invalidateShelf();
      navigate(hasContent ? `/books/review/${review.id}` : "/books", { replace: true });
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <>
      <TopBar title={title} />
      <main className="mx-auto flex max-w-xl flex-col items-center px-5 pb-10 pt-6">
        <Cover item={data.item} size="lg" />
        <h2 className="mt-3 text-center text-xl font-semibold leading-snug">{data.item.title}</h2>
        <p className="text-sm text-slate-500">
          {byline(data.item)}
          {data.isReread ? " · re-read" : ""}
        </p>

        {!editing ? (
          <p className="mt-4 text-center text-[15px] text-slate-600">
            {dnf ? "No shame in it. Want to say why?" : "How was it? All of this is optional, and you can change it later."}
          </p>
        ) : null}

        <div className="mt-5">
          <StarInput value={rating} onChange={setRating} />
          <p className="mt-1 h-4 text-center text-xs text-slate-500">{rating !== null ? `${rating / 2} of 5` : "Tap a star, or half of one"}</p>
        </div>

        <div className="mt-4 grid w-full grid-cols-2 gap-2">
          {[true, false].map((option) => {
            const active = recommend === option;
            return (
              <button
                key={String(option)}
                type="button"
                onClick={() => setRecommend(active ? null : option)}
                className="rounded-2xl border-2 py-3 text-[15px] font-medium transition-colors"
                style={
                  active
                    ? { borderColor: option ? "#059669" : "#e11d48", background: option ? "#ecfdf5" : "#fff1f2", color: option ? "#047857" : "#be123c" }
                    : { borderColor: "#e2e8f0", background: "white", color: "#475569" }
                }
                aria-pressed={active}
              >
                {option ? "👍 Recommend" : "👎 Not for me"}
              </button>
            );
          })}
        </div>

        <textarea
          value={body}
          onChange={(event) => setBody(event.target.value)}
          rows={5}
          maxLength={10000}
          placeholder={dnf ? "Where did it lose you?" : "What did you think?"}
          className="mt-4 w-full resize-y rounded-2xl border border-slate-200 bg-white p-4 text-[16px] outline-none focus:border-slate-400"
        />

        <label className={`mt-3 flex w-full items-center justify-between gap-3 rounded-2xl bg-white px-4 py-3 ${hasContent && !onLounge ? "" : "opacity-60"}`}>
          <span className="text-[15px]">
            {onLounge ? "Posted on the Lounge ✓" : "Also post on the Lounge"}
            <span className="block text-xs text-slate-500">
              {onLounge ? "Edits here show there too." : "A card in the feed that links back here."}
            </span>
          </span>
          {!onLounge ? (
            <input
              type="checkbox"
              checked={toLounge && hasContent}
              disabled={!hasContent}
              onChange={(event) => setToLounge(event.target.checked)}
              className="h-6 w-6"
              style={{ accentColor: palette.accent }}
            />
          ) : null}
        </label>

        {error ? <p className="mt-3 text-sm text-rose-600">{error}</p> : null}

        <div className="mt-6 grid w-full grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => (editing ? navigate(-1) : navigate("/books", { replace: true }))}
            className="rounded-full border border-slate-300 bg-white py-3.5 font-medium text-slate-700"
          >
            {editing ? "Cancel" : "Skip"}
          </button>
          <button
            type="button"
            onClick={save}
            disabled={busy}
            className="rounded-full py-3.5 font-semibold text-white disabled:opacity-60"
            style={{ background: palette.accent }}
          >
            {busy ? "Saving…" : "Save"}
          </button>
        </div>
      </main>
    </>
  );
}
