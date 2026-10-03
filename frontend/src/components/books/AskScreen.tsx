import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { getThemePalette } from "../../themes";
import { formatPostedTime } from "../../lib/datetime";
import { errorMessage, invalidateShelf, shelfSend, useShelf } from "./api";
import type { AskDetail } from "./api";
import { AskTag } from "./AskCard";
import { Discussion } from "./Discussion";
import { PersonLine, Spinner, TopBar } from "./ui";
import { usePalette } from "./format";

// One ask and the suggestions under it. Where an ask's Lounge card lands, and
// where a notification about a suggestion opens.

export function AskScreen() {
  const { askId } = useParams();
  const navigate = useNavigate();
  const palette = usePalette();
  const { data, error, reload } = useShelf<{ ask: AskDetail }>(`/asks/${askId}`);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  if (!data) {
    return (
      <>
        <TopBar title="Ask" />
        {error ? <p className="p-8 text-center text-sm text-slate-500">This ask isn't here any more.</p> : <Spinner />}
      </>
    );
  }

  const { ask } = data;
  const authorPalette = getThemePalette(ask.author.themeKey);

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setActionError(null);
    try {
      await action();
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const save = () =>
    run(async () => {
      if (!draft.trim()) return;
      await shelfSend("put", `/asks/${ask.id}`, { body: draft.trim() });
      setEditing(false);
      invalidateShelf();
    });

  const remove = () => {
    if (!window.confirm(ask.loungePostId ? "Delete this ask, its discussion and its Lounge post?" : "Delete this ask and its discussion?")) return;
    void run(async () => {
      await shelfSend("delete", `/asks/${ask.id}`);
      invalidateShelf();
      navigate("/books/feed", { replace: true });
    });
  };

  const postToLounge = () =>
    run(async () => {
      await shelfSend("post", `/asks/${ask.id}/lounge`);
      invalidateShelf();
    });

  return (
    <>
      <TopBar
        title="Ask"
        right={
          ask.isMine && !editing ? (
            <button
              type="button"
              onClick={() => {
                setDraft(ask.body);
                setEditing(true);
              }}
              className="rounded-full px-3 py-1.5 text-sm font-semibold"
              style={{ color: palette.accent }}
            >
              Edit
            </button>
          ) : null
        }
      />
      <main className="mx-auto max-w-xl px-4 pb-8">
        <article className="mt-4 rounded-2xl bg-white p-4 shadow-sm" style={{ borderTop: `3px solid ${authorPalette.border}` }}>
          <div className="flex items-center justify-between gap-2">
            <Link to={`/books/people/${ask.author.id}`} className="min-w-0">
              <PersonLine person={ask.author} />
            </Link>
            <span className="shrink-0 text-xs text-slate-500">
              {formatPostedTime(ask.createdAt)}
              {ask.editedAt ? " · edited" : ""}
            </span>
          </div>
          <div className="mt-3">
            <AskTag />
          </div>
          {editing ? (
            <div className="mt-2">
              <textarea
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                rows={5}
                maxLength={2000}
                className="w-full resize-none rounded-xl border border-slate-200 p-3 text-[16px] outline-none focus:border-slate-400"
              />
              <div className="mt-1 flex items-center justify-between text-sm">
                <button type="button" onClick={remove} disabled={busy} className="text-rose-600">
                  Delete
                </button>
                <div className="flex gap-4">
                  <button type="button" onClick={() => setEditing(false)} className="text-slate-500">
                    Cancel
                  </button>
                  <button type="button" onClick={() => void save()} disabled={busy || !draft.trim()} className="font-semibold" style={{ color: palette.accent }}>
                    Save
                  </button>
                </div>
              </div>
            </div>
          ) : (
            <p className="mt-2 whitespace-pre-wrap text-[16px] leading-relaxed text-slate-800">{ask.body}</p>
          )}
          {ask.loungePostId ? (
            <Link to={`/blog/${ask.loungePostId}`} className="mt-3 inline-block text-xs font-medium text-slate-500">
              Also on the Lounge ›
            </Link>
          ) : ask.isMine ? (
            <button type="button" onClick={() => void postToLounge()} disabled={busy} className="mt-3 text-sm font-medium" style={{ color: palette.accent }}>
              Post this on the Lounge
            </button>
          ) : null}
          {actionError ? <p className="mt-2 text-sm text-rose-600">{actionError}</p> : null}
        </article>

        <Discussion
          path={`/asks/${ask.id}`}
          comments={ask.comments}
          canDelete={ask.isMine}
          onChanged={reload}
          empty={ask.isMine ? "No suggestions yet." : "No suggestions yet. Know something they'd like?"}
          placeholder={ask.isMine ? "Add a detail" : "Suggest something"}
        />
      </main>
    </>
  );
}
