import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { getThemePalette } from "../../themes";
import { formatPostedTime } from "../../lib/datetime";
import { errorMessage, invalidateShelf, shelfSend } from "./api";
import type { Ask } from "./api";
import { PersonLine, Sheet } from "./ui";
import { usePalette } from "./format";

// An ask in the feed: a review card with the book taken out. Same tint, same
// byline, same way into a discussion, because answering it is the point.

export function AskTag() {
  return <span className="rounded-full bg-sky-50 px-2 py-0.5 text-xs font-medium text-sky-800">🙋 Looking for a recommendation</span>;
}

export function AskCard({ ask }: { ask: Ask }) {
  const navigate = useNavigate();
  const palette = getThemePalette(ask.author.themeKey);
  const open = () => navigate(`/books/ask/${ask.id}`);

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
        <PersonLine person={ask.author} />
        <span className="shrink-0 text-xs text-slate-500">{formatPostedTime(ask.createdAt)}</span>
      </div>
      <div className="mt-3">
        <AskTag />
      </div>
      <p className="mt-2 line-clamp-4 whitespace-pre-wrap text-[15px] leading-relaxed text-slate-700">{ask.body}</p>
      <div className="mt-3 text-xs font-medium" style={{ color: palette.accent }}>
        💬 {ask.commentCount > 0 ? `${ask.commentCount} in the discussion` : "Suggest something"}
      </div>
    </article>
  );
}

export function AskSheet({ onClose }: { onClose: () => void }) {
  const palette = usePalette();
  const [body, setBody] = useState("");
  const [toLounge, setToLounge] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function send() {
    if (!body.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await shelfSend("post", "/asks", { body: body.trim(), lounge: toLounge });
      invalidateShelf();
      onClose();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <Sheet
      title="Ask for a recommendation"
      onClose={onClose}
      footer={
        <button
          type="button"
          onClick={send}
          disabled={busy || !body.trim()}
          className="w-full rounded-full py-3.5 font-semibold text-white disabled:opacity-50"
          style={{ background: palette.accent }}
        >
          {busy ? "Asking…" : "Ask"}
        </button>
      }
    >
      <textarea
        value={body}
        onChange={(event) => setBody(event.target.value)}
        rows={5}
        maxLength={2000}
        autoFocus
        placeholder="What are you in the mood for? Something like a book you loved, something for a long flight…"
        className="w-full resize-none rounded-2xl border border-slate-200 bg-white p-4 text-[16px] outline-none focus:border-slate-400"
      />
      <label className="mt-3 flex w-full items-center justify-between gap-3 rounded-2xl bg-slate-50 px-4 py-3">
        <span className="text-[15px]">
          Also post on the Lounge
          <span className="block text-xs text-slate-500">A card in the feed that links back here, where the answers are.</span>
        </span>
        <input
          type="checkbox"
          checked={toLounge}
          onChange={(event) => setToLounge(event.target.checked)}
          className="h-6 w-6"
          style={{ accentColor: palette.accent }}
        />
      </label>
      {error ? <p className="mt-3 text-sm text-rose-600">{error}</p> : null}
    </Sheet>
  );
}
