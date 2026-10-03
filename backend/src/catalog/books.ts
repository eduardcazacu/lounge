import type { CatalogCandidate, CatalogEdition } from "@blogging-app/common";

// Books come from Open Library, with Google Books filling the holes.
//
// Open Library has the covers and asks for no key, but its genres are a raw
// "subjects" list — library shelf marks, award names, "Accessible book" — and
// some works have no page count. Google Books' keyless tier has clean
// categories and page counts but small covers and a daily quota. Both are asked
// at once; Open Library's results are kept and Google's matching volume fills
// in what is missing. If Open Library finds nothing, Google's own results are
// returned instead.
//
// Plain fetch only: this module is imported by src/index.ts, which must stay
// Node-safe.
//
// Google's keyless quota is shared per IP, and a Worker's egress IP is shared
// with strangers, so it answers 429 often. GOOGLE_BOOKS_API_KEY, if set, gives
// it a quota of its own; without it the search is Open Library alone.

// Open Library gives "identified" requests, a User-Agent naming the app and a
// contact email, a higher rate limit than anonymous ones, and a way to reach us
// about a problem other than blocking the IP. Google receives it too and
// ignores it.
export const USER_AGENT = "EddiesLounge/1.0 (hello@eduardcazacu.com)";
const RESULT_LIMIT = 10;
const TIMEOUT_MS = 5000;

export type OpenLibraryDoc = {
  key?: string;
  title?: string;
  author_name?: string[];
  // Every spelling of every author, flattened. Asked for by import only:
  // Murakami's `author_name` is 村上春樹, and a Goodreads export says Haruki.
  author_alternative_name?: string[];
  first_publish_year?: number;
  cover_i?: number;
  number_of_pages_median?: number;
  subject?: string[];
  // The one edition Open Library thinks best fits the query, in the language
  // asked for with `lang`. See `searchBooks`.
  editions?: { docs?: OpenLibraryEditionDoc[] };
};

export type OpenLibraryEditionDoc = {
  key?: string;
  title?: string;
  cover_i?: number;
  language?: string[];
  publisher?: string[];
  publish_year?: number[];
  number_of_pages_median?: number;
};

/** An entry of /works/:id/editions.json, which is shaped unlike search's. */
export type OpenLibraryEdition = {
  key?: string;
  title?: string;
  subtitle?: string;
  covers?: number[];
  languages?: { key?: string }[];
  publishers?: string[];
  publish_date?: string;
  physical_format?: string;
  number_of_pages?: number;
};

export type GoogleVolume = {
  id?: string;
  volumeInfo?: {
    title?: string;
    subtitle?: string;
    authors?: string[];
    publishedDate?: string;
    pageCount?: number;
    categories?: string[];
    imageLinks?: { thumbnail?: string; smallThumbnail?: string };
  };
};

/**
 * A provider that refused or failed, as opposed to one that answered "no such
 * book". The difference matters more than anything else in this module: the
 * second can be acted on (add it by hand), the first must be waited out, and
 * mistaking one for the other is how an import used to turn a rate limit into
 * permanent hand-made copies of books Open Library knows perfectly well.
 */
export class CatalogUnavailable extends Error {
  constructor(
    readonly provider: string,
    readonly retryAfterSeconds: number
  ) {
    super(`${provider} is unavailable; retry in ${retryAfterSeconds}s`);
  }
}

const DEFAULT_RETRY_AFTER_SECONDS = { limited: 60, failed: 30 };

/**
 * `Retry-After` is either a number of seconds or an HTTP date. Missing or
 * unreadable, the caller's default stands. Clamped to an hour: a server asking
 * for longer is, for an import screen, the same as "later".
 */
export function parseRetryAfter(header: string | null, fallbackSeconds: number, now = Date.now()): number {
  if (!header) return fallbackSeconds;
  const trimmed = header.trim();
  let seconds = /^\d+$/.test(trimmed) ? Number(trimmed) : Math.ceil((Date.parse(trimmed) - now) / 1000);
  if (!Number.isFinite(seconds)) seconds = fallbackSeconds;
  return Math.max(1, Math.min(3600, seconds));
}

export type ProviderAnswer<T> = { ok: true; data: T | null } | { ok: false; retryAfterSeconds: number };

/**
 * One provider request. A 404 is an answer (nothing there); a 429, a 403
 * (Open Library's block), a 5xx, a timeout or a refused connection is not.
 */
export async function fetchProvider<T>(url: string): Promise<ProviderAnswer<T>> {
  const host = new URL(url).host;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
      signal: controller.signal,
    });
    if (response.status === 404) return { ok: true, data: null };
    if (!response.ok) {
      const limited = response.status === 429 || response.status === 403;
      const retryAfterSeconds = parseRetryAfter(
        response.headers.get("Retry-After"),
        limited ? DEFAULT_RETRY_AFTER_SECONDS.limited : DEFAULT_RETRY_AFTER_SECONDS.failed
      );
      // Google says why in the body ("Requests from referer <empty> are
      // blocked" is a key restricted to websites; "API key not valid" is a
      // typo). Logged, because both look like a rate limit from outside. The
      // body never contains the key.
      const reason = (await response.text().catch(() => "")).match(/"message":\s*"([^"]{0,200})/)?.[1] ?? "";
      console.warn("[catalog] provider answered", response.status, host, `retry in ${retryAfterSeconds}s`, reason);
      return { ok: false, retryAfterSeconds };
    }
    return { ok: true, data: (await response.json()) as T };
  } catch (error) {
    console.warn("[catalog] provider failed", host, error instanceof Error ? error.message : error);
    return { ok: false, retryAfterSeconds: DEFAULT_RETRY_AFTER_SECONDS.failed };
  } finally {
    clearTimeout(timer);
  }
}

export const OPEN_LIBRARY_URL = "https://openlibrary.org";
export const GOOGLE_BOOKS_URL = "https://www.googleapis.com";

const GOOGLE_FIELDS = "items(id,volumeInfo(title,subtitle,authors,publishedDate,pageCount,categories,imageLinks))";

export function googleVolumesUrl(base: string | undefined, query: string, limit: number, key: string | undefined) {
  return (
    `${base ?? GOOGLE_BOOKS_URL}/books/v1/volumes?q=${encodeURIComponent(query)}` +
    `&maxResults=${limit}&printType=books&fields=${GOOGLE_FIELDS}` +
    (key ? `&key=${encodeURIComponent(key)}` : "")
  );
}

// Genres are mapped onto a short fixed list rather than kept as the providers
// give them. Open Library's subjects mix genres with characters, places and
// library shelf marks ("Arkenstone", "Accessible book"), and spell one genre
// several ways ("Science-fiction", "Sci-fi", "Fiction, science fiction,
// general"). Raw, they made genre stats split one taste across three rows and
// rank a dragon's treasure as somebody's favourite genre. A subject that maps
// onto nothing is dropped: no genre is better than a wrong one.
//
// Order matters — the first pattern a subject matches wins, so the specific
// come before the general ("historical fiction" before "history", anything
// before plain "fiction").
const GENRES: [RegExp, string][] = [
  [/science.?fiction|sci.?fi\b/, "Science fiction"],
  [/fantasy|fairy tales|dragons|magic\b/, "Fantasy"],
  [/histor\w*.*fiction|fiction.*histor/, "Historical fiction"],
  [/myster|detective/, "Mystery"],
  [/thriller|suspense/, "Thriller"],
  [/\bcrime\b/, "Crime"],
  [/horror|ghost stories/, "Horror"],
  [/romance|love stories/, "Romance"],
  [/dystop/, "Dystopian"],
  [/mytholog|legends/, "Mythology"],
  [/graphic novel|comic/, "Comics"],
  [/juvenile|children/, "Children's"],
  [/young adult/, "Young adult"],
  [/short stories/, "Short stories"],
  [/poetry|poems/, "Poetry"],
  [/drama|plays\b/, "Drama"],
  [/humou?r|satire/, "Humour"],
  [/adventure/, "Adventure"],
  [/classic/, "Classics"],
  [/biograph|memoir|autobiograph/, "Biography & memoir"],
  [/essays/, "Essays"],
  [/true crime/, "True crime"],
  [/philosoph/, "Philosophy"],
  [/psycholog/, "Psychology"],
  [/self.?help|personal development|self.?improvement/, "Self-help"],
  [/business|econom|finance|management/, "Business & economics"],
  [/politic|government/, "Politics"],
  [/religio|spiritual|theolog/, "Religion"],
  [/travel/, "Travel"],
  [/cook|recipes|food/, "Food & cooking"],
  [/\bart\b|music|photograph/, "Arts"],
  [/histor/, "History"],
  [/physics|biology|chemistry|astronom|mathemat|\bscience/, "Science"],
  [/technolog|computer|programming/, "Technology"],
  [/nature|ecology|environment/, "Nature"],
  [/fiction|novel/, "Fiction"],
];

export function cleanGenres(raw: string[] | undefined): string[] {
  const genres: string[] = [];
  for (const subject of raw ?? []) {
    const text = subject.toLowerCase();
    const match = GENRES.find(([pattern]) => pattern.test(text));
    if (match && !genres.includes(match[1])) genres.push(match[1]);
  }
  // "Fiction" says nothing next to a real genre; alone it is still something.
  const specific = genres.filter((genre) => genre !== "Fiction");
  return (specific.length > 0 ? specific : genres).slice(0, 3);
}

export function normaliseForMatch(value: string | undefined) {
  return (value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function matchKey(title: string | undefined, creator: string | undefined) {
  const surname = normaliseForMatch(creator).split(" ").pop() ?? "";
  return `${normaliseForMatch(title).split(" ").slice(0, 4).join(" ")}|${surname}`;
}

const openLibraryCover = (id: number | undefined) =>
  id && id > 0 ? `https://covers.openlibrary.org/b/id/${id}-M.jpg` : null;

const positive = (value: number | undefined) => (value && value > 0 ? value : null);

// A work's own title and cover on Open Library are whichever edition a
// librarian happened to catalogue first, and for a translated book that is
// often not the English one: The Last Wish is the work "Ostatnie Życzenie",
// with a Polish cover. Search therefore asks for an English edition
// (`lang=en`), and an English edition's title and cover are shown in place of
// the work's. Only an English one: the edition search picks in another
// language is no better than the work's own.
// Search and import ask for the same fields, so a work found either way is
// filed the same way. With `lang=en`, the edition each work comes with is an
// English one where there is one.
export const OPEN_LIBRARY_FIELDS =
  "key,title,author_name,first_publish_year,cover_i,number_of_pages_median,subject" +
  ",editions,editions.key,editions.title,editions.cover_i,editions.language,editions.publisher" +
  ",editions.publish_year,editions.number_of_pages_median";

export function fromOpenLibrary(doc: OpenLibraryDoc): CatalogCandidate | null {
  if (!doc.key || !doc.title) return null;
  const editionDoc = doc.editions?.docs?.[0];
  const edition = editionDoc?.key && editionDoc.title ? fromOpenLibraryEditionDoc(editionDoc) : null;
  const english = edition?.language === "eng" ? edition : null;
  return {
    kind: "book",
    source: "openlibrary",
    externalId: doc.key,
    title: (english?.title ?? doc.title).slice(0, 300),
    creators: (doc.author_name ?? []).slice(0, 5),
    year: doc.first_publish_year ?? null,
    coverUrl: english?.coverUrl ?? openLibraryCover(doc.cover_i),
    totalUnits: positive(doc.number_of_pages_median),
    genres: cleanGenres(doc.subject),
    edition: english,
  };
}

export function fromOpenLibraryEditionDoc(doc: OpenLibraryEditionDoc): CatalogEdition {
  return {
    source: "openlibrary",
    externalId: doc.key!,
    title: doc.title!.slice(0, 300),
    language: doc.language?.length === 1 ? doc.language[0] : null,
    publisher: doc.publisher?.[0]?.slice(0, 200) ?? null,
    year: doc.publish_year?.length ? Math.min(...doc.publish_year) : null,
    format: null,
    coverUrl: openLibraryCover(doc.cover_i),
    totalUnits: positive(doc.number_of_pages_median),
  };
}

export function fromOpenLibraryEdition(entry: OpenLibraryEdition): CatalogEdition | null {
  if (!entry.key || !entry.title) return null;
  const year = Number.parseInt(entry.publish_date?.match(/\b(1[5-9]|20)\d\d\b/)?.[0] ?? "", 10);
  // One language is the edition's; several is a bilingual edition, which is
  // not "the English one" either.
  const languages = (entry.languages ?? []).flatMap((language) => language.key?.replace("/languages/", "") ?? []);
  return {
    source: "openlibrary",
    externalId: entry.key,
    title: (entry.subtitle ? `${entry.title}: ${entry.subtitle}` : entry.title).slice(0, 300),
    language: languages.length === 1 ? languages[0].slice(0, 8) : null,
    publisher: entry.publishers?.[0]?.trim().slice(0, 200) || null,
    year: Number.isFinite(year) ? year : null,
    format: entry.physical_format?.trim().slice(0, 80) || null,
    coverUrl: openLibraryCover(entry.covers?.find((id) => id > 0)),
    // A page count of 1 is an audiobook's "1 audio disc", not a length.
    totalUnits: entry.number_of_pages && entry.number_of_pages > 1 ? entry.number_of_pages : null,
  };
}

/**
 * The order editions are offered in: English first, then those with no
 * language recorded (most of them are English too — Orbit's The Last Wish is
 * one), then the rest; within each, those with a cover, then the newest.
 * Someone browsing editions is nearly always looking for the cover of the copy
 * on their shelf.
 */
export function rankEditions(editions: CatalogEdition[]) {
  const languageRank = (edition: CatalogEdition) => (edition.language === "eng" ? 0 : edition.language === null ? 1 : 2);
  return [...editions].sort(
    (a, b) =>
      languageRank(a) - languageRank(b) ||
      Number(b.coverUrl !== null) - Number(a.coverUrl !== null) ||
      (b.year ?? 0) - (a.year ?? 0)
  );
}

// Dune has about 150 editions and Open Library answers 300 in a second or so.
// A work with thousands (Shakespeare) is cut off, English first being the
// order the reader would have scrolled in anyway.
const EDITIONS_LIMIT = 300;

/**
 * Every edition Open Library has of a work, ranked. `workKey` is the work's
 * externalId ("/works/OL…W"). Throws CatalogUnavailable on a refusal, as
 * search does; an unknown work is an empty list.
 */
export async function bookEditions(workKey: string, options: BookSearchOptions = {}): Promise<CatalogEdition[]> {
  if (!/^\/works\/OL\d+W$/.test(workKey)) return [];
  const answer = await fetchProvider<{ entries?: OpenLibraryEdition[] }>(
    `${options.openLibraryUrl ?? OPEN_LIBRARY_URL}${workKey}/editions.json?limit=${EDITIONS_LIMIT}`
  );
  if (!answer.ok) throw new CatalogUnavailable("Open Library", answer.retryAfterSeconds);
  return rankEditions((answer.data?.entries ?? []).flatMap((entry) => fromOpenLibraryEdition(entry) ?? []));
}

function googleCover(volume: GoogleVolume) {
  const link = volume.volumeInfo?.imageLinks?.thumbnail ?? volume.volumeInfo?.imageLinks?.smallThumbnail;
  return link ? link.replace(/^http:/, "https:").replace("&edge=curl", "") : null;
}

export function fromGoogle(volume: GoogleVolume): CatalogCandidate | null {
  const info = volume.volumeInfo;
  if (!volume.id || !info?.title) return null;
  const year = Number.parseInt(info.publishedDate?.slice(0, 4) ?? "", 10);
  return {
    kind: "book",
    source: "google",
    externalId: volume.id,
    title: (info.subtitle ? `${info.title}: ${info.subtitle}` : info.title).slice(0, 300),
    creators: (info.authors ?? []).slice(0, 5),
    year: Number.isFinite(year) ? year : null,
    coverUrl: googleCover(volume),
    totalUnits: info.pageCount && info.pageCount > 0 ? info.pageCount : null,
    genres: cleanGenres(info.categories),
  };
}

export type BookSearchOptions = {
  googleBooksApiKey?: string;
  /** Only ever changed to point local tests at a stand-in. */
  openLibraryUrl?: string;
  /** Likewise. */
  googleBooksUrl?: string;
};

export type BookSearchResult = {
  results: CatalogCandidate[];
  /**
   * Whether Open Library answered. Only such an answer is worth caching: one
   * made of Google's results alone is a stopgap for the length of an outage.
   */
  complete: boolean;
};

export async function searchBooks(query: string, options: BookSearchOptions = {}): Promise<BookSearchResult> {
  const q = query.trim();
  if (!q) return { results: [], complete: true };

  const openLibraryUrl =
    `${options.openLibraryUrl ?? OPEN_LIBRARY_URL}/search.json?q=${encodeURIComponent(q)}` +
    `&fields=${OPEN_LIBRARY_FIELDS}&lang=en&limit=${RESULT_LIMIT}`;
  const googleUrl = googleVolumesUrl(options.googleBooksUrl, q, RESULT_LIMIT, options.googleBooksApiKey);

  const [openLibrary, google] = await Promise.all([
    fetchProvider<{ docs?: OpenLibraryDoc[] }>(openLibraryUrl),
    fetchProvider<{ items?: GoogleVolume[] }>(googleUrl),
  ]);

  const googleCandidates = google.ok ? (google.data?.items ?? []).flatMap((volume) => fromGoogle(volume) ?? []) : [];

  if (!openLibrary.ok) {
    // Google alone is better than nothing while Open Library is away. With
    // neither, the reader is told search is down — not that the book does not
    // exist, which is what an empty list would say.
    if (googleCandidates.length > 0) return { results: googleCandidates, complete: false };
    throw new CatalogUnavailable("Open Library", openLibrary.retryAfterSeconds);
  }

  const openLibraryCandidates = (openLibrary.data?.docs ?? []).flatMap((doc) => fromOpenLibrary(doc) ?? []);
  if (openLibraryCandidates.length === 0) {
    return { results: googleCandidates, complete: true };
  }

  const googleByKey = new Map<string, CatalogCandidate>();
  for (const candidate of googleCandidates) {
    const key = matchKey(candidate.title, candidate.creators[0]);
    if (!googleByKey.has(key)) googleByKey.set(key, candidate);
  }

  const merged = openLibraryCandidates.map((candidate) => {
    const match = googleByKey.get(matchKey(candidate.title, candidate.creators[0]));
    if (!match) return candidate;
    return {
      ...candidate,
      totalUnits: candidate.totalUnits ?? match.totalUnits,
      // Google's categories are the better genres when it has any.
      genres: match.genres.length > 0 ? match.genres : candidate.genres,
      // An English edition with no cover of its own would otherwise fall back
      // to the work's, which is the translation's cover this is avoiding.
      // Google's volume, matched by the English title, is the English cover.
      coverUrl:
        candidate.edition && !candidate.edition.coverUrl ? match.coverUrl ?? candidate.coverUrl : candidate.coverUrl ?? match.coverUrl,
      year: candidate.year ?? match.year,
    };
  });

  // Relevance order, except that an entry with no cover and no page count —
  // usually a study guide or an omnibus nobody means — sinks below the rest.
  const looksReal = (candidate: CatalogCandidate) => candidate.coverUrl !== null || candidate.totalUnits !== null;
  return { results: [...merged.filter(looksReal), ...merged.filter((candidate) => !looksReal(candidate))], complete: true };
}
