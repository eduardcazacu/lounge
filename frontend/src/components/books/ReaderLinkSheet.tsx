import { useState } from "react";
import { errorMessage, invalidateShelf, localDay, shelfSend, useShelf } from "./api";
import type { Home, Item } from "./api";
import { CopyPagesSheet } from "./CopyPagesSheet";
import { Cover, Sheet } from "./ui";
import { byline, percentText, usePalette } from "./format";

// "Which book is this?" for a file KOReader synced. KOReader names a file
// only by a hash, so this is asked once per file; after it, the file's syncs
// move that book (backend/src/reader-sync.ts).
//
// The choices are the reads under way and the want list. Picking a want-list
// book starts it, which is why its copy's length is asked first, as Start
// asks: KOReader's percentage becomes a page of that copy.

type Choice = { entryId: number; item: Item; reading: boolean; totalUnits: number | null; unitsConfirmed: boolean };

export function ReaderLinkSheet({
  doc,
  onClose,
}: {
  doc: { id: number; title: string | null; authors: string | null; percentage: number; suggestedEntryId?: number | null };
  onClose: () => void;
}) {
  const palette = usePalette();
  const { data: home } = useShelf<Home>(`/home?today=${localDay()}`);
  const [askingPages, setAskingPages] = useState<Choice | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const choices: Choice[] = [
    ...(home?.reading ?? []).map((reading) => ({
      entryId: reading.entryId,
      item: reading.item,
      reading: true,
      totalUnits: reading.run.totalUnits,
      unitsConfirmed: reading.run.unitsConfirmed,
    })),
    ...(home?.want ?? []).map((want) => ({
      entryId: want.entryId,
      item: want.item,
      reading: false,
      totalUnits: want.item.totalUnits,
      unitsConfirmed: false,
    })),
  ];
  // The likeliest first, so the usual case is the top row.
  choices.sort((a, b) => Number(b.entryId === doc.suggestedEntryId) - Number(a.entryId === doc.suggestedEntryId));

  async function send(body: Record<string, unknown>) {
    setBusy(true);
    setError(null);
    try {
      await shelfSend("post", `/reader/documents/${doc.id}/link`, body);
      invalidateShelf();
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  function pick(choice: Choice) {
    // Starting a book, or a book with no length to turn a percentage into
    // pages, asks for the copy's length first.
    if (!choice.reading || !choice.totalUnits) setAskingPages(choice);
    else void send({ entryId: choice.entryId, today: localDay() });
  }

  if (askingPages) {
    return (
      <CopyPagesSheet
        title={askingPages.item.title}
        initial={askingPages.totalUnits}
        confirmLabel={askingPages.reading ? "Link it" : "Start reading"}
        note="KOReader says how far through you are, not which page. This turns it into pages of your copy."
        onClose={() => setAskingPages(null)}
        onConfirm={async (pages) => {
          await shelfSend("post", `/reader/documents/${doc.id}/link`, {
            entryId: askingPages.entryId,
            totalUnits: pages,
            today: localDay(),
          });
          invalidateShelf();
          onClose();
        }}
      />
    );
  }

  const described = doc.title ? `${doc.title}${doc.authors ? ` · ${doc.authors.split("\n")[0]}` : ""}` : null;
  return (
    <Sheet title="Which book is this?" onClose={onClose}>
      <p className="text-sm text-slate-600">
        {described ? <span className="font-medium text-slate-800">{described}</span> : "A book on your Kindle"}, at{" "}
        {percentText(doc.percentage)}.
      </p>
      {error ? <p className="mt-2 text-sm text-rose-600">{error}</p> : null}
      <ul className="mt-3 flex flex-col">
        {choices.map((choice) => (
          <li key={choice.entryId}>
            <button
              type="button"
              disabled={busy}
              onClick={() => pick(choice)}
              className="flex w-full items-center gap-3 border-b border-slate-100 py-2.5 text-left disabled:opacity-60"
            >
              <Cover item={choice.item} size="xs" />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-[15px] font-medium text-slate-900">{choice.item.title}</span>
                <span className="block truncate text-xs text-slate-500">
                  {choice.reading ? "Reading now" : "Want to read · starts it"}
                  {byline(choice.item) ? ` · ${byline(choice.item)}` : ""}
                </span>
              </span>
              {choice.entryId === doc.suggestedEntryId ? (
                <span className="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold text-white" style={{ background: palette.accent }}>
                  Likely
                </span>
              ) : null}
            </button>
          </li>
        ))}
      </ul>
      {home && choices.length === 0 ? (
        <p className="mt-2 text-sm text-slate-500">Nothing on the go or on your want list. Add the book first, then link it here.</p>
      ) : null}
      <button
        type="button"
        disabled={busy}
        onClick={() => void send({ ignore: true })}
        className="mt-3 w-full rounded-full py-2.5 text-sm font-medium text-slate-500"
      >
        Not a book I track
      </button>
    </Sheet>
  );
}
