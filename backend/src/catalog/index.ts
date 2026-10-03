import type { CatalogCandidate, ShelfKind } from "@blogging-app/common";
import { searchBooks, type BookSearchOptions, type BookSearchResult } from "./books";

export type CatalogSearchOptions = BookSearchOptions;
export { CatalogUnavailable, bookEditions } from "./books";

// How long a search answer is reused, here and by the hourly sweep that
// deletes older ones (src/scheduled.ts).
export const SEARCH_CACHE_TTL_MS = 24 * 60 * 60 * 1000;

// One search per kind. A kind whose provider needs a key (TMDB for films, say)
// keeps it here on the server, which is why the browser never calls a
// provider itself. See wiki/books.md.
const providers: Record<ShelfKind, (query: string, options: CatalogSearchOptions) => Promise<BookSearchResult>> = {
  book: searchBooks,
};

export async function searchCatalog(
  kind: ShelfKind,
  query: string,
  options: CatalogSearchOptions = {}
): Promise<BookSearchResult> {
  return providers[kind](query, options);
}
