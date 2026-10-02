import type { CatalogCandidate, ImportRowInput } from "@blogging-app/common";
import {
  CatalogUnavailable,
  fetchProvider,
  fromGoogle,
  fromOpenLibrary,
  googleVolumesUrl,
  normaliseForMatch,
  OPEN_LIBRARY_URL,
  type GoogleVolume,
  type OpenLibraryDoc,
} from "./books";

// Finding the catalog work for a book described by someone else's export, or
// by a reader who typed it in by hand.
//
// By ISBN first, then by title and author, and a title search is believed only
// if the title and the author's surname both agree — a confident wrong match
// files someone's review under another book, and nobody would notice until
// the book club showed the wrong people.
//
// Two outcomes are kept strictly apart. Open Library answering "nothing" is a
// result, and the caller may fall back to the book's own details. Open Library
// refusing or failing is not: `CatalogUnavailable` is thrown and the caller
// waits. Treating a rate limit as "not found" once turned whole imports into
// hand-made copies of books the catalog knows, each unique to its importer —
// so two people reading the same book never met in its book club.
//
// Requests are paced to about one a second (`paced`). Open Library limits by
// IP; an import is the one thing here that asks it many questions in a row.
//
// Google Books is the second source, asked when Open Library refuses or has
// no such book. It is asked second, not alongside, because a book should come
// from one source where it can, and Open Library's covers and work ids are the
// better ones. Two readers getting the same book from different sources is
// not a split book club: src/catalog/store.ts finds an existing work by title
// and author whatever its source, so whichever source supplied a book first
// is the one everybody lands on.

const FIELDS = "key,title,author_name,first_publish_year,cover_i,number_of_pages_median,subject";
const SPACING_MS = 1000;

export type BookMatch = { candidate: CatalogCandidate; match: "isbn" | "title" };

export type MatchOptions = { openLibraryUrl?: string; googleBooksUrl?: string; googleBooksApiKey?: string };

/**
 * Which sources have refused, shared across the rows of one import batch, so
 * that a source that said "not now" is not asked again for every row after.
 */
export type SourceState = { openLibraryDown: CatalogUnavailable | null; googleDown: CatalogUnavailable | null };

export const freshSourceState = (): SourceState => ({ openLibraryDown: null, googleDown: null });

// Per isolate, so it paces one Worker instance rather than the world. That is
// enough: imports are client-driven one batch at a time, so one import runs
// on one instance at a time.
let nextSlot = 0;

async function paced() {
  const now = Date.now();
  const wait = nextSlot - now;
  nextSlot = Math.max(now, nextSlot) + SPACING_MS;
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
}

/** Series and subtitles differ between exports and catalogs: "Dune (Dune Chronicles, #1)" is "Dune". */
export function titleKey(title: string) {
  return normaliseForMatch(title.replace(/\(.*?\)/g, "").split(":")[0]);
}

export function bareTitle(title: string) {
  return title.replace(/\(.*?\)/g, "").split(":")[0].trim();
}

function surname(name: string | undefined) {
  return normaliseForMatch(name).split(" ").pop() ?? "";
}

/** Whether a catalog result is plausibly the book described. */
export function sameBook(row: Pick<ImportRowInput, "title" | "creators">, doc: Pick<OpenLibraryDoc, "title" | "author_name">) {
  const wanted = titleKey(row.title);
  const found = titleKey(doc.title ?? "");
  // Equal once series and subtitles are gone, and no looser: a prefix match
  // would take "Dune Messiah" for "Dune".
  if (!wanted || wanted !== found) return false;
  const author = surname(row.creators[0]);
  if (!author) return true;
  return (doc.author_name ?? []).some((name) => surname(name) === author);
}

async function search(params: string, options: MatchOptions): Promise<OpenLibraryDoc[]> {
  await paced();
  const answer = await fetchProvider<{ docs?: OpenLibraryDoc[] }>(
    `${options.openLibraryUrl ?? OPEN_LIBRARY_URL}/search.json?${params}&fields=${FIELDS}&limit=5`
  );
  if (!answer.ok) throw new CatalogUnavailable("Open Library", answer.retryAfterSeconds);
  return answer.data?.docs ?? [];
}

function withDetails(candidate: CatalogCandidate, book: Pick<ImportRowInput, "totalUnits" | "year">): CatalogCandidate {
  return { ...candidate, totalUnits: candidate.totalUnits ?? book.totalUnits, year: candidate.year ?? book.year };
}

export type BookToFind = Pick<ImportRowInput, "title" | "creators" | "isbn13" | "isbn10" | "totalUnits" | "year">;

async function findOnOpenLibrary(book: BookToFind, options: MatchOptions): Promise<BookMatch | null> {
  const author = book.creators[0];
  for (const isbn of [book.isbn13, book.isbn10]) {
    if (!isbn) continue;
    const docs = await search(`q=isbn:${isbn}`, options);
    // An ISBN is an edition, so the title can legitimately differ (a
    // translation, a reissue); only the author has to agree.
    const doc = docs.find((found) => !author || (found.author_name ?? []).some((name) => surname(name) === surname(author)));
    const candidate = doc ? fromOpenLibrary(doc) : null;
    if (candidate) return { candidate: withDetails(candidate, book), match: "isbn" };
    // One ISBN that finds nothing is enough to know the other won't.
    break;
  }

  const docs = await search(
    `title=${encodeURIComponent(bareTitle(book.title))}${author ? `&author=${encodeURIComponent(author)}` : ""}`,
    options
  );
  const doc = docs.find((found) => sameBook(book, found));
  const candidate = doc ? fromOpenLibrary(doc) : null;
  return candidate ? { candidate: withDetails(candidate, book), match: "title" } : null;
}

async function googleSearch(query: string, options: MatchOptions): Promise<GoogleVolume[]> {
  const answer = await fetchProvider<{ items?: GoogleVolume[] }>(
    googleVolumesUrl(options.googleBooksUrl, query, 5, options.googleBooksApiKey)
  );
  if (!answer.ok) throw new CatalogUnavailable("Google Books", answer.retryAfterSeconds);
  return answer.data?.items ?? [];
}

async function findOnGoogle(book: BookToFind, options: MatchOptions): Promise<BookMatch | null> {
  const author = book.creators[0];
  const isbn = book.isbn13 ?? book.isbn10;
  if (isbn) {
    const volumes = await googleSearch(`isbn:${isbn}`, options);
    const volume = volumes.find(
      (found) => !author || (found.volumeInfo?.authors ?? []).some((name) => surname(name) === surname(author))
    );
    const candidate = volume ? fromGoogle(volume) : null;
    if (candidate) return { candidate: withDetails(candidate, book), match: "isbn" };
  }
  const title = bareTitle(book.title);
  const volumes = await googleSearch(`intitle:"${title}"${author ? ` inauthor:"${author}"` : ""}`, options);
  // Google's own title, without the subtitle it keeps separately, is what is
  // compared — the candidate's title has the subtitle joined on.
  const volume = volumes.find((found) => sameBook(book, { title: found.volumeInfo?.title, author_name: found.volumeInfo?.authors }));
  const candidate = volume ? fromGoogle(volume) : null;
  return candidate ? { candidate: withDetails(candidate, book), match: "title" } : null;
}

/**
 * The catalog work for a book, from Open Library or else Google Books.
 *
 * Null means both answered and neither has it — or Open Library answered "no"
 * and Google could not be asked; that book is made from its own details, and
 * can be found again later. Throws `CatalogUnavailable` when Open Library did
 * not answer and Google did not find the book either: Open Library may well
 * have it, so the caller waits rather than file it by hand.
 *
 * `state` remembers refusals across the rows of a batch; a source that has
 * refused is not asked again until the next batch.
 */
export async function findBook(
  book: BookToFind,
  options: MatchOptions = {},
  state: SourceState = freshSourceState()
): Promise<BookMatch | null> {
  if (!state.openLibraryDown) {
    try {
      const found = await findOnOpenLibrary(book, options);
      if (found) return found;
    } catch (error) {
      if (!(error instanceof CatalogUnavailable)) throw error;
      state.openLibraryDown = error;
    }
  }

  if (!state.googleDown) {
    try {
      const found = await findOnGoogle(book, options);
      if (found) return found;
    } catch (error) {
      if (!(error instanceof CatalogUnavailable)) throw error;
      state.googleDown = error;
    }
  }

  if (state.openLibraryDown) throw state.openLibraryDown;
  return null;
}

/**
 * The export's own details, as a manual item. Its id comes from the export's
 * row, not the importer, so two people importing the same Goodreads book while
 * the catalog has no such book still share one item — and one book club.
 */
export function manualCandidate(row: ImportRowInput, source: string): CatalogCandidate {
  const isbn = row.isbn13 ?? row.isbn10;
  return {
    kind: "book",
    source: "manual",
    externalId: `${source}:${row.ref}`,
    title: row.title,
    creators: row.creators,
    year: row.year,
    // Copied into R2 by backend/src/covers.ts, or dropped if Open Library has
    // none: `default=false` makes it answer 404 rather than a blank image.
    coverUrl: isbn ? `${OPEN_LIBRARY_COVERS_URL}/b/isbn/${isbn}-M.jpg?default=false` : null,
    totalUnits: row.totalUnits,
    genres: [],
  };
}

export const OPEN_LIBRARY_COVERS_URL = "https://covers.openlibrary.org";
