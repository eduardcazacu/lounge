import type { CatalogCandidate } from "@blogging-app/common";

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

const USER_AGENT = "EddiesLounge/1.0 (https://lounge.eduardcazacu.com)";
const RESULT_LIMIT = 10;
const TIMEOUT_MS = 5000;

export type OpenLibraryDoc = {
  key?: string;
  title?: string;
  author_name?: string[];
  first_publish_year?: number;
  cover_i?: number;
  number_of_pages_median?: number;
  subject?: string[];
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

export function fromOpenLibrary(doc: OpenLibraryDoc): CatalogCandidate | null {
  if (!doc.key || !doc.title) return null;
  return {
    kind: "book",
    source: "openlibrary",
    externalId: doc.key,
    title: doc.title.slice(0, 300),
    creators: (doc.author_name ?? []).slice(0, 5),
    year: doc.first_publish_year ?? null,
    coverUrl: doc.cover_i ? `https://covers.openlibrary.org/b/id/${doc.cover_i}-M.jpg` : null,
    totalUnits: doc.number_of_pages_median && doc.number_of_pages_median > 0 ? doc.number_of_pages_median : null,
    genres: cleanGenres(doc.subject),
  };
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
    `&fields=key,title,author_name,first_publish_year,cover_i,number_of_pages_median,subject` +
    `&limit=${RESULT_LIMIT}`;
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
      coverUrl: candidate.coverUrl ?? match.coverUrl,
      year: candidate.year ?? match.year,
    };
  });

  // Relevance order, except that an entry with no cover and no page count —
  // usually a study guide or an omnibus nobody means — sinks below the rest.
  const looksReal = (candidate: CatalogCandidate) => candidate.coverUrl !== null || candidate.totalUnits !== null;
  return { results: [...merged.filter(looksReal), ...merged.filter((candidate) => !looksReal(candidate))], complete: true };
}
