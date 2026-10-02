import { useState } from "react";
import { errorMessage } from "./api";
import { Sheet } from "./ui";
import { usePalette } from "./format";

// "Pages in your copy": asked at Start, and wherever a reader changes it.
//
// Editions of one book differ by a quarter in length and more, and the
// catalog's figure is usually a median across them. The book club compares
// readers by how far through *their own copy* they are, so a wrong length
// shows notes too early — spoilers — or too late. It is prefilled, so
// confirming is one tap; a length nobody confirmed is allowed for with a
// margin (backend/src/shelf-logic.ts), never trusted.

export function CopyPagesSheet({
  title,
  initial,
  confirmLabel,
  note,
  onConfirm,
  onClose,
}: {
  title: string;
  initial: number | null;
  confirmLabel: string;
  note?: string;
  onConfirm: (pages: number) => Promise<void>;
  onClose: () => void;
}) {
  const palette = usePalette();
  const [pages, setPages] = useState(initial ? String(initial) : "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const value = Number.parseInt(pages, 10);

  async function confirm() {
    if (!(value > 0)) return;
    setBusy(true);
    setError(null);
    try {
      await onConfirm(value);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  }

  return (
    <Sheet
      title={title}
      onClose={onClose}
      footer={
        <button
          type="button"
          onClick={confirm}
          disabled={busy || !(value > 0)}
          className="w-full rounded-full py-3.5 font-semibold text-white disabled:opacity-50"
          style={{ background: palette.accent }}
        >
          {busy ? "Saving…" : confirmLabel}
        </button>
      }
    >
      <label className="block text-center text-sm text-slate-500">
        Pages in your copy
        <input
          autoFocus
          inputMode="numeric"
          value={pages}
          onChange={(event) => setPages(event.target.value.replace(/[^0-9]/g, "").slice(0, 5))}
          onKeyDown={(event) => {
            if (event.key === "Enter") void confirm();
          }}
          className="block w-full bg-transparent py-1 text-center font-semibold tabular-nums text-slate-900 outline-none"
          // index.css holds phone inputs at 16px !important; see wiki/gotchas.md.
          ref={(element) => element?.style.setProperty("font-size", "48px", "important")}
        />
      </label>
      <p className="pb-2 text-center text-xs text-slate-500">
        {note ?? "Editions differ. The book club shows others' notes by how far through your own copy you are, so this keeps it spoiler-free."}
      </p>
      {error ? <p className="pb-2 text-center text-sm text-rose-600">{error}</p> : null}
    </Sheet>
  );
}
