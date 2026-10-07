import { useState } from "react";
import { useParams } from "react-router-dom";
import { getThemePalette } from "../../themes";
import { Avatar } from "../Avatar";
import { errorMessage, invalidateShelf, localDay, shelfSend, useShelf } from "./api";
import type { Club, Run } from "./api";
import { Cover, EmptyNote, Spinner, TopBar } from "./ui";
import { CopyPagesSheet } from "./CopyPagesSheet";
import { byline, formatDay, percentText, usePalette } from "./format";

// The book club: what everyone in the group said about this book, in the
// order a reader meets it, and only as far as you have read. It is fetched
// when opened and never shown elsewhere — the home card only counts it.
//
// "As far as you have read" is a fraction of each person's own edition, worked
// out on the server (backend/src/shelf-logic.ts). Someone who has finished the
// book once sees everything, re-read or not.

function Compose({ run, onPosted }: { run: Run; onPosted: () => void }) {
  const palette = usePalette();
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function post() {
    if (!note.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await shelfSend("post", `/runs/${run.id}/log`, { position: run.position, note: note.trim(), loggedOn: localDay() });
      setNote("");
      invalidateShelf();
      onPosted();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="rounded-2xl border border-slate-200/70 bg-white p-3 shadow-sm">
      <textarea
        value={note}
        onChange={(event) => setNote(event.target.value)}
        rows={2}
        maxLength={2000}
        placeholder={`A thought at ${run.totalUnits ? percentText(run.fraction) : `p. ${run.position}`}…`}
        className="w-full resize-none bg-transparent text-[15px] outline-none"
      />
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs text-slate-500">Others see it once they reach p. {run.position}.</span>
        <button
          type="button"
          onClick={post}
          disabled={busy || !note.trim()}
          className="rounded-full px-4 py-1.5 text-sm font-semibold text-white disabled:opacity-40"
          style={{ background: palette.accent }}
        >
          Post
        </button>
      </div>
      {error ? <p className="pt-1 text-sm text-rose-600">{error}</p> : null}
    </div>
  );
}

export function ClubScreen() {
  const { itemId } = useParams();
  const { data: club, error, reload } = useShelf<Club>(`/items/${itemId}/club`);
  const [checkingCopy, setCheckingCopy] = useState(false);

  if (!club) {
    return (
      <>
        <TopBar title="Book club" />
        {error ? <p className="p-8 text-center text-sm text-slate-500">This book club isn't here.</p> : <Spinner />}
      </>
    );
  }

  const others = club.members.filter((member) => !member.isMe);

  return (
    <>
      <TopBar title="Book club" />
      <main className="mx-auto max-w-xl px-4 pb-8">
        <div className="flex items-center gap-3 py-4">
          <Cover item={club.item} size="sm" />
          <div className="min-w-0">
            <div className="truncate font-semibold">{club.item.title}</div>
            <div className="truncate text-sm text-slate-500">{byline(club.item)}</div>
          </div>
        </div>

        {club.members.length ? (
          <div className="-mx-4 flex gap-4 overflow-x-auto px-4 pb-3 [scrollbar-width:none]">
            {club.members.map((member) => (
              <div key={member.id} className="flex w-14 shrink-0 flex-col items-center text-center">
                <Avatar size="big" name={member.name ?? "?"} themeKey={member.themeKey} imageUrl={member.profilePictureUrl} />
                <span className="mt-1 w-full truncate text-xs text-slate-700">{member.isMe ? "You" : member.name}</span>
                <span className="text-[11px] tabular-nums text-slate-500">{member.finished ? "✓ read" : percentText(member.fraction)}</span>
              </div>
            ))}
          </div>
        ) : null}

        {club.myRun ? <Compose run={club.myRun} onPosted={() => void reload()} /> : null}

        <div className="mt-4 flex flex-col gap-2">
          {club.notes.length === 0 ? (
            <EmptyNote>
              {others.length
                ? "No notes up to here yet."
                : "Nobody else is reading this one yet. Notes you leave will wait for whoever does."}
            </EmptyNote>
          ) : (
            club.notes.map((note) => {
              const palette = getThemePalette(note.author.themeKey);
              return (
                <article key={note.id} className="rounded-2xl bg-white p-3.5 shadow-sm" style={{ borderLeft: `4px solid ${palette.border}` }}>
                  <div className="flex items-center justify-between gap-2 text-xs text-slate-500">
                    <span className="flex min-w-0 items-center gap-1.5">
                      <Avatar size="small" name={note.author.name ?? "?"} themeKey={note.author.themeKey} imageUrl={note.author.profilePictureUrl} />
                      <span className="truncate font-medium" style={{ color: palette.text }}>
                        {note.isMine ? "You" : note.author.name}
                      </span>
                    </span>
                    <span className="shrink-0 tabular-nums">
                      {note.fraction !== null ? `${percentText(note.fraction)} · ` : ""}p. {note.position} · {formatDay(note.loggedOn)}
                    </span>
                  </div>
                  <p className="mt-1.5 whitespace-pre-wrap text-[15px] text-slate-800">{note.note}</p>
                </article>
              );
            })
          )}
        </div>

        {club.aheadCount > 0 ? (
          <p className="mt-4 rounded-2xl bg-white/70 px-4 py-3 text-center text-sm text-slate-600">
            🔒 {club.aheadCount} more note{club.aheadCount === 1 ? "" : "s"} further on. They unlock as you read.
          </p>
        ) : null}

        {club.myRun && !club.reachConfirmed ? (
          <p className="mt-3 px-2 text-center text-xs text-slate-500">
            Notes close to your place are held back a little, because your copy's page count isn't confirmed.{" "}
            <button type="button" onClick={() => setCheckingCopy(true)} className="font-medium underline">
              Set it
            </button>
          </p>
        ) : null}
        {checkingCopy && club.myRun ? (
          <CopyPagesSheet
            title={club.item.title}
            initial={club.myRun.totalUnits}
            confirmLabel="That's my copy"
            onClose={() => setCheckingCopy(false)}
            onConfirm={async (pages) => {
              await shelfSend("put", `/runs/${club.myRun!.id}`, { totalUnits: pages });
              invalidateShelf();
              setCheckingCopy(false);
              void reload();
            }}
          />
        ) : null}

        {!club.myRun && club.reach < 1 ? (
          <p className="mt-4 text-center text-sm text-slate-500">Start reading it to join in.</p>
        ) : null}
      </main>
    </>
  );
}
