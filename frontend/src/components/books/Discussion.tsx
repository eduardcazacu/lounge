import { useState } from "react";
import { getThemePalette } from "../../themes";
import { formatPostedTime } from "../../lib/datetime";
import { getCurrentUserId } from "../../lib/auth";
import { errorMessage, shelfSend } from "./api";
import type { ReviewComment } from "./api";
import { PersonLine, SectionTitle } from "./ui";
import { usePalette } from "./format";

// The discussion under a review or an ask. `path` is the thing discussed
// ("/reviews/12", "/asks/3"); both answer the same comment routes beneath it.

function CommentRow({
  path,
  comment,
  canDelete,
  onChanged,
}: {
  path: string;
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
      await shelfSend("put", `${path}/comments/${comment.id}`, { content: draft.trim() });
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
      await shelfSend("delete", `${path}/comments/${comment.id}`);
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

export function Discussion({
  path,
  comments,
  canDelete,
  onChanged,
  empty,
  placeholder,
}: {
  path: string;
  comments: ReviewComment[];
  /** The owner of the review or ask can delete anyone's comment on it. */
  canDelete: boolean;
  onChanged: () => Promise<void> | void;
  empty: string;
  placeholder: string;
}) {
  const palette = usePalette();
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);

  async function send() {
    if (!draft.trim()) return;
    setBusy(true);
    setSendError(null);
    try {
      await shelfSend("post", `${path}/comments`, { content: draft.trim() });
      setDraft("");
      await onChanged();
    } catch (e) {
      setSendError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <SectionTitle>Discussion</SectionTitle>
      <ul className="flex flex-col gap-2">
        {comments.length === 0 ? (
          <li className="px-1 text-sm text-slate-500">{empty}</li>
        ) : (
          comments.map((comment) => (
            <CommentRow key={comment.id} path={path} comment={comment} canDelete={canDelete} onChanged={() => void onChanged()} />
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
          placeholder={placeholder}
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
    </>
  );
}
