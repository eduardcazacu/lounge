import { useEffect, useState } from "react";
import { errorMessage, shelfGet } from "./api";
import type { CatalogEdition } from "./api";
import { Cover, Sheet } from "./ui";
import { editionLine, usePalette } from "./format";

// "Other editions": every printing Open Library has of a work, to pick the one
// on your shelf. A work's own cover is whichever edition was catalogued first,
// often a translation's, and search's English pick sometimes has no cover at
// all. The server ranks them English first (`rankEditions` in
// backend/src/catalog/books.ts); the sheet opens on English and the editions
// with no language recorded, which are mostly English too, and the rest are a
// tap away.

const looksEnglish = (edition: CatalogEdition) => edition.language === "eng" || edition.language === null;

export function EditionSheet({
  title,
  path,
  currentId,
  onPick,
  onReset,
  onClose,
}: {
  title: string;
  /** `/items/:id/editions` for a book on the shelf, `/catalog/editions?work=` for a search result. */
  path: string;
  /** The edition chosen now, marked in the list. */
  currentId: string | null;
  onPick: (edition: CatalogEdition) => Promise<void> | void;
  /** Offered when set: going back to the work's own cover and title. */
  onReset?: () => Promise<void>;
  onClose: () => void;
}) {
  const palette = usePalette();
  const [editions, setEditions] = useState<CatalogEdition[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [allLanguages, setAllLanguages] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    shelfGet<{ editions: CatalogEdition[] }>(path)
      .then((response) => {
        if (cancelled) return;
        setEditions(response.editions);
        // Straight to everything when there is no English edition to show.
        if (!response.editions.some(looksEnglish)) setAllLanguages(true);
      })
      .catch((e) => {
        if (!cancelled) setLoadError(errorMessage(e, "Open Library isn't answering. Try again in a minute."));
      });
    return () => {
      cancelled = true;
    };
  }, [path]);

  async function choose(key: string, action: () => Promise<void> | void) {
    setBusy(key);
    setError(null);
    try {
      await action();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(null);
    }
  }

  const shown = editions ? (allLanguages ? editions : editions.filter(looksEnglish)) : [];
  const hidden = editions ? editions.length - editions.filter(looksEnglish).length : 0;

  return (
    <Sheet title="Choose your edition" onClose={onClose}>
      <p className="pb-3 text-sm text-slate-500">
        The cover and title you'll see for <span className="font-medium text-slate-700">{title}</span>. Only yours changes.
      </p>
      {loadError ? <p className="py-6 text-center text-sm text-amber-700">{loadError}</p> : null}
      {!editions && !loadError ? <p className="py-10 text-center text-sm text-slate-400">Finding editions…</p> : null}
      {editions && editions.length === 0 ? (
        <p className="py-6 text-center text-sm text-slate-500">Open Library lists no editions of this book.</p>
      ) : null}
      {error ? <p className="pb-2 text-sm text-rose-600">{error}</p> : null}

      {shown.length ? (
        <ul className="flex flex-col">
          {shown.map((edition) => {
            const current = edition.externalId === currentId;
            return (
              <li key={edition.externalId} className="border-b border-slate-100 last:border-0">
                <button
                  type="button"
                  disabled={busy !== null}
                  onClick={() => void choose(edition.externalId, () => onPick(edition))}
                  className="flex w-full items-center gap-3 py-2.5 text-left disabled:opacity-60"
                >
                  <Cover item={edition} size="sm" />
                  <span className="min-w-0 flex-1">
                    <span className="line-clamp-2 font-medium leading-snug text-slate-900">{edition.title}</span>
                    <span className="mt-0.5 block text-sm text-slate-500">{editionLine(edition)}</span>
                  </span>
                  {busy === edition.externalId ? (
                    <span className="text-xs text-slate-400">Saving…</span>
                  ) : current ? (
                    <span className="text-sm font-semibold" style={{ color: palette.accent }}>
                      ✓
                    </span>
                  ) : null}
                </button>
              </li>
            );
          })}
        </ul>
      ) : null}

      {editions && !allLanguages && hidden > 0 ? (
        <button
          type="button"
          onClick={() => setAllLanguages(true)}
          className="w-full py-3 text-sm font-medium"
          style={{ color: palette.accent }}
        >
          Show {hidden} in other languages
        </button>
      ) : null}
      {onReset ? (
        <button
          type="button"
          disabled={busy !== null}
          onClick={() => void choose("reset", onReset)}
          className="w-full py-3 text-sm font-medium text-slate-500 disabled:opacity-60"
        >
          {busy === "reset" ? "Saving…" : "Use the catalog's cover and title"}
        </button>
      ) : null}
    </Sheet>
  );
}
