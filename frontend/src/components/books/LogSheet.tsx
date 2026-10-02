import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { errorMessage, invalidateShelf, localDay, shelfSend } from "./api";
import type { Item, Run } from "./api";
import { Sheet } from "./ui";
import { percentText, usePalette } from "./format";

// Logging today's reading: the action /books is built around.
//
// It opens on a number field with the keyboard up, so the usual entry is
// "type 20, press Log". The chips add to the number rather than saving, so a
// mis-tap costs nothing. "I'm on page" is there for the reader who knows where
// the bookmark is but not how far they got today. A note is optional and goes
// to the book club, where others see it only once they have read this far.
//
// "Your copy: N pages" sits under the number, because that length decides
// where a note lands in the book club and the catalog's figure is often
// another edition's. A number past the last page is not quietly capped: it
// usually means the copy is longer, so the sheet asks.

type Mode = "amount" | "position";

export function LogSheet({ run, item, onClose }: { run: Run; item: Item; onClose: () => void }) {
  const palette = usePalette();
  const navigate = useNavigate();
  const [mode, setMode] = useState<Mode>("amount");
  const [value, setValue] = useState("");
  const [note, setNote] = useState("");
  const [showNote, setShowNote] = useState(false);
  const [yesterday, setYesterday] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reachedEnd, setReachedEnd] = useState(false);
  // Notes in the book club this log made readable, shown before closing.
  const [unlocked, setUnlocked] = useState(0);
  // The copy's length as changed here, ahead of the next refetch.
  const [copy, setCopy] = useState<{ pages: number | null; confirmed: boolean }>({
    pages: run.totalUnits,
    confirmed: run.unitsConfirmed,
  });
  const [editingCopy, setEditingCopy] = useState(false);
  const [copyDraft, setCopyDraft] = useState(run.totalUnits ? String(run.totalUnits) : "");

  const total = copy.pages;
  const number = Number.parseInt(value, 10);
  const valid = Number.isFinite(number) && number >= 0;
  const target = !valid ? run.position : mode === "amount" ? run.position + number : number;
  const clampedTarget = total ? Math.min(target, total) : target;
  const moved = clampedTarget - run.position;
  // Past the end of the copy on file: ask rather than cap.
  const overshoot = Boolean(total && target > total);
  const canSave = !busy && !overshoot && (moved !== 0 || note.trim().length > 0);

  async function setCopyPages(pages: number) {
    await shelfSend("put", `/runs/${run.id}`, { totalUnits: pages });
    setCopy({ pages, confirmed: true });
    setCopyDraft(String(pages));
    invalidateShelf();
  }

  const add = (amount: number) => {
    setMode("amount");
    setValue(String((valid && mode === "amount" ? number : 0) + amount));
  };

  async function save() {
    if (!canSave) return;
    setBusy(true);
    setError(null);
    const day = new Date();
    if (yesterday) day.setDate(day.getDate() - 1);
    try {
      const result = await shelfSend<{ reachedEnd: boolean; unlockedNotes: number }>("post", `/runs/${run.id}/log`, {
        // Pages read are sent as pages read, so a log from another device in
        // the meantime is added to rather than overwritten. A note with no
        // pages is a log that stays where the bookmark is.
        ...(mode === "amount" && number > 0 ? { amount: number } : { position: target }),
        note: note.trim() || undefined,
        loggedOn: localDay(day),
      });
      invalidateShelf();
      if (result.reachedEnd) setReachedEnd(true);
      else if (result.unlockedNotes > 0) setUnlocked(result.unlockedNotes);
      else onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function finish() {
    setBusy(true);
    try {
      await shelfSend("post", `/runs/${run.id}/finish`, { status: "finished", finishedOn: localDay() });
      invalidateShelf();
      onClose();
      navigate(`/books/finish/${run.id}`);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  }

  if (unlocked > 0) {
    return (
      <Sheet title="Logged" onClose={onClose}>
        <p className="pb-2 text-[15px] text-slate-600">
          You've reached {unlocked === 1 ? "a note" : `${unlocked} notes`} in the {item.title} book club.
        </p>
        <div className="flex gap-2 py-3">
          <button type="button" onClick={onClose} className="flex-1 rounded-full border border-slate-300 py-3 font-medium text-slate-700">
            Later
          </button>
          <button
            type="button"
            onClick={() => {
              onClose();
              navigate(`/books/club/${item.id}`);
            }}
            className="flex-1 rounded-full py-3 font-semibold text-white"
            style={{ background: palette.accent }}
          >
            Read {unlocked === 1 ? "it" : "them"}
          </button>
        </div>
      </Sheet>
    );
  }

  if (reachedEnd) {
    return (
      <Sheet title="That's the last page" onClose={onClose}>
        <p className="pb-2 text-[15px] text-slate-600">
          Finished <span className="font-semibold text-slate-900">{item.title}</span>? You can rate it and say a few words
          next — or skip that.
        </p>
        {error ? <p className="py-2 text-sm text-rose-600">{error}</p> : null}
        <div className="flex gap-2 py-3">
          <button type="button" onClick={onClose} className="flex-1 rounded-full border border-slate-300 py-3 font-medium text-slate-700">
            Not yet
          </button>
          <button
            type="button"
            onClick={finish}
            disabled={busy}
            className="flex-1 rounded-full py-3 font-semibold text-white disabled:opacity-60"
            style={{ background: palette.accent }}
          >
            Finished it
          </button>
        </div>
      </Sheet>
    );
  }

  const label =
    moved > 0 ? `Log ${moved} page${moved === 1 ? "" : "s"}` : moved < 0 ? `Move back to p. ${clampedTarget}` : note.trim() ? "Post note" : "Log";

  return (
    <Sheet
      title={item.title}
      onClose={onClose}
      footer={
        <button
          type="button"
          onClick={() => void save()}
          disabled={!canSave}
          className="w-full rounded-full py-3.5 text-[16px] font-semibold text-white transition-opacity disabled:opacity-40"
          style={{ background: palette.accent }}
        >
          {busy ? "Saving…" : label}
        </button>
      }
    >
      <div className="mb-3 flex rounded-full bg-slate-100 p-1 text-sm font-medium">
        {(["amount", "position"] as Mode[]).map((option) => (
          <button
            key={option}
            type="button"
            onClick={() => {
              setMode(option);
              setValue("");
            }}
            className={`flex-1 rounded-full py-1.5 ${mode === option ? "bg-white text-slate-900 shadow-sm" : "text-slate-500"}`}
          >
            {option === "amount" ? "Pages read" : "I'm on page"}
          </button>
        ))}
      </div>

      <form
        onSubmit={(event) => {
          event.preventDefault();
          void save();
        }}
      >
        <input
          autoFocus
          inputMode="numeric"
          pattern="[0-9]*"
          value={value}
          onChange={(event) => setValue(event.target.value.replace(/[^0-9]/g, "").slice(0, 6))}
          placeholder={mode === "amount" ? "0" : String(run.position)}
          aria-label={mode === "amount" ? "Pages read" : "Current page"}
          className="w-full bg-transparent text-center text-6xl font-semibold tabular-nums text-slate-900 outline-none placeholder:text-slate-300"
          // index.css holds every phone input at 16px !important so iOS does
          // not zoom on focus; only an inline !important outranks it, and at
          // 60px there is no zoom to prevent.
          ref={(element) => element?.style.setProperty("font-size", "60px", "important")}
        />
      </form>
      <p className="text-center text-sm text-slate-500">
        {total ? (
          <>
            p. {clampedTarget} of {total} · {percentText(clampedTarget / total)}
          </>
        ) : (
          <>p. {clampedTarget}</>
        )}
      </p>
      {editingCopy ? (
        <div className="mx-auto flex max-w-xs items-center justify-center gap-2 pb-3 pt-1 text-sm">
          <span className="text-slate-500">Your copy:</span>
          <input
            inputMode="numeric"
            value={copyDraft}
            onChange={(event) => setCopyDraft(event.target.value.replace(/[^0-9]/g, "").slice(0, 5))}
            className="w-20 rounded-lg border border-slate-300 px-2 py-1 text-center tabular-nums"
            aria-label="Pages in your copy"
          />
          <span className="text-slate-500">pages</span>
          <button
            type="button"
            disabled={busy || !(Number.parseInt(copyDraft, 10) > 0)}
            onClick={async () => {
              setBusy(true);
              try {
                await setCopyPages(Number.parseInt(copyDraft, 10));
                setEditingCopy(false);
              } catch (e) {
                setError(errorMessage(e));
              } finally {
                setBusy(false);
              }
            }}
            className="font-semibold disabled:opacity-40"
            style={{ color: palette.accent }}
          >
            Save
          </button>
        </div>
      ) : (
        <p className="pb-3 pt-0.5 text-center text-xs">
          <button
            type="button"
            onClick={() => setEditingCopy(true)}
            className={copy.confirmed ? "text-slate-400" : "font-medium text-amber-700"}
          >
            {total
              ? copy.confirmed
                ? `Your copy: ${total} pages · Change`
                : `Is your copy ${total} pages? Check it, so book club notes line up`
              : "How many pages is your copy?"}
          </button>
        </p>
      )}

      {overshoot ? (
        <div className="mb-3 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <p>
            Page {target} is past the {total} pages on file. Is your copy longer?
          </p>
          <div className="mt-2 flex flex-col gap-2">
            <button
              type="button"
              disabled={busy}
              onClick={async () => {
                setBusy(true);
                try {
                  await setCopyPages(target);
                } catch (e) {
                  setError(errorMessage(e));
                  setBusy(false);
                  return;
                }
                setBusy(false);
                setEditingCopy(true);
              }}
              className="rounded-full bg-white py-2 font-semibold shadow-sm disabled:opacity-60"
            >
              Yes, it's longer — set its pages
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                setMode("position");
                setValue(String(total));
              }}
              className="py-1 font-medium text-amber-800 disabled:opacity-60"
            >
              No — page {total} is the last page
            </button>
          </div>
        </div>
      ) : null}

      {mode === "amount" ? (
        <div className="flex justify-center gap-2 pb-3">
          {[5, 10, 20, 50].map((amount) => (
            <button
              key={amount}
              type="button"
              onClick={() => add(amount)}
              className="rounded-full border px-4 py-1.5 text-sm font-medium"
              style={{ borderColor: palette.border, color: palette.text, background: palette.softBg }}
            >
              +{amount}
            </button>
          ))}
        </div>
      ) : null}

      <div className="flex items-center justify-between gap-2 border-t border-slate-100 py-3 text-sm">
        <div className="flex rounded-full bg-slate-100 p-0.5 font-medium">
          {[false, true].map((option) => (
            <button
              key={String(option)}
              type="button"
              onClick={() => setYesterday(option)}
              className={`rounded-full px-3 py-1 ${yesterday === option ? "bg-white text-slate-900 shadow-sm" : "text-slate-500"}`}
            >
              {option ? "Yesterday" : "Today"}
            </button>
          ))}
        </div>
        {!showNote ? (
          <button type="button" onClick={() => setShowNote(true)} className="font-medium" style={{ color: palette.accent }}>
            + Note for the book club
          </button>
        ) : null}
      </div>

      {showNote ? (
        <div className="pb-2">
          <textarea
            value={note}
            onChange={(event) => setNote(event.target.value)}
            rows={3}
            maxLength={2000}
            autoFocus
            placeholder="What do you think so far?"
            className="w-full resize-none rounded-xl border border-slate-200 p-3 text-[15px] outline-none focus:border-slate-400"
          />
          <p className="pt-1 text-xs text-slate-500">
            Others see this once they've read to {total ? `${percentText(clampedTarget / total)} (p. ${clampedTarget})` : `p. ${clampedTarget}`} —
            no spoilers.
          </p>
        </div>
      ) : null}

      {error ? <p className="pb-2 text-sm text-rose-600">{error}</p> : null}
    </Sheet>
  );
}
