import axios from "axios";
import { useQuery } from "@tanstack/react-query";
import { useCallback } from "react";
import type { CatalogCandidate, CatalogEdition } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader, getCurrentUserId } from "../../lib/auth";
import { accountKey, queryClient } from "../../lib/query";

// The shelf API, and how /books reads through the app's query cache.
//
// Every screen asks `useShelf(path)` and gets the last answer for that path at
// once, if there is one — from memory, or from disk on a cold launch — while a
// fresh one is fetched. A write calls `invalidateShelf()`, which refetches
// whatever is on screen. The shelf is one person's few hundred rows, and
// showing the last answer first is what makes the home screen open instantly
// from the home screen icon.

export type Person = {
  id: number;
  name: string | null;
  themeKey: string | null;
  profilePictureUrl: string | null;
};

export type Item = {
  id: number;
  kind: string;
  /** "manual": not from the catalog — typed in, or imported while it had no match. */
  source: string;
  title: string;
  creators: string[];
  year: number | null;
  coverUrl: string | null;
  totalUnits: number | null;
  genres: string[];
  /**
   * The printing this reader has, when they chose one (or search offered an
   * English one). `title` and `coverUrl` above are already its; this says
   * which it is.
   */
  edition: ItemEdition | null;
};

export type ItemEdition = Omit<CatalogEdition, "source" | "coverUrl">;

export type RunStatus = "active" | "finished" | "dnf";

export type Run = {
  id: number;
  status: RunStatus;
  startedOn: string | null;
  finishedOn: string | null;
  totalUnits: number | null;
  position: number;
  fraction: number | null;
  /** Whether `totalUnits` is the reader's own copy, rather than the catalog's guess. */
  unitsConfirmed: boolean;
};

export type Review = {
  id: number;
  rating: number | null;
  recommend: boolean | null;
  body: string | null;
  /** The reviewer marked it as giving the book away. */
  spoiler: boolean;
  /** A spoiler, and this viewer hasn't finished the book: cover it until they ask. */
  covered: boolean;
  createdAt: string;
  editedAt: string | null;
};

export type HomeReading = {
  entryId: number;
  item: Item;
  run: Run;
  today: number;
  /** The latest KOReader sync of this book, when a file is linked to it. */
  reader: { device: string; syncedAt: string } | null;
  club: { visibleNotes: number; aheadNotes: number; readers: Person[] };
};

/** A file KOReader synced that nobody has said is a book yet. */
export type ReaderPending = {
  id: number;
  /** What KOReader says the file is: only with "Send document metadata" on. */
  title: string | null;
  authors: string | null;
  percentage: number;
  device: string;
  syncedAt: string;
  /** The entry it most likely is: the one its title names, or the one read on the go. */
  suggestedEntryId: number | null;
};

export type ReaderSettings = {
  serverUrl: string;
  login: { username: string; timeZone: string; lastSeenAt: string | null } | null;
  documents: {
    id: number;
    title: string | null;
    authors: string | null;
    percentage: number;
    device: string;
    ignored: boolean;
    syncedAt: string;
    entry: { id: number; item: Item } | null;
  }[];
};

export type Home = {
  today: string;
  reading: HomeReading[];
  want: { entryId: number; item: Item }[];
  readerPending: ReaderPending[];
  /** Everyone else in the group with a read on their shelf, most recently active first. */
  readers: Person[];
  highlights: { year: number; booksThisYear: number; pagesThisWeek: number; streak: number };
};

export type ProgressLogRow = {
  id: number;
  loggedOn: string;
  fromPosition: number;
  toPosition: number;
  note: string | null;
  /** "koreader" when a KOReader sync wrote it. */
  source: string | null;
  createdAt: string;
};

export type EntryDetail = {
  id: number;
  isMine: boolean;
  wantedAt: string | null;
  owner: Person;
  item: Item;
  runs: (Run & {
    number: number;
    review: (Review & { loungePostId: number | null; commentCount: number }) | null;
  })[];
  recentLogs: ProgressLogRow[];
};

export type LibraryEntry = {
  id: number;
  wantedAt: string | null;
  /** Where it stands on the want list once arranged, lowest first. Null sorts above every rank. */
  wantRank: number | null;
  item: Item;
  runs: (Run & { review: Review | null })[];
};

export type Library = { owner: Person; entries: LibraryEntry[] };

export type FeedReview = Review & {
  commentCount: number;
  loungePostId: number | null;
  entryId: number;
  reviewer: Person;
  item: Item;
  run: Run;
  readNumber: number;
};

export type ReviewComment = {
  id: number;
  content: string;
  createdAt: string;
  editedAt: string | null;
  author: Person;
};

export type ReviewDetail = FeedReview & { isMine: boolean; comments: ReviewComment[] };

/** Someone asking the group for a recommendation: a review with no book. */
export type Ask = {
  id: number;
  body: string;
  createdAt: string;
  editedAt: string | null;
  author: Person;
  commentCount: number;
  loungePostId: number | null;
};

export type AskDetail = Ask & { isMine: boolean; comments: ReviewComment[] };

export type FeedPost = ({ kind: "review" } & FeedReview) | ({ kind: "ask" } & Ask);

export type Club = {
  item: Item;
  reach: number;
  /** False when the reader's place rests on a page count they never confirmed. */
  reachConfirmed: boolean;
  aheadCount: number;
  myRun: Run | null;
  members: (Person & { fraction: number; finished: boolean; isMe: boolean })[];
  notes: {
    id: number;
    note: string;
    fraction: number | null;
    position: number;
    loggedOn: string;
    createdAt: string;
    isMine: boolean;
    author: Person;
  }[];
};

export type GenreStats = { genre: string; books: number; pages: number; averageRating: number | null };

export type PeriodStats = {
  period: number | "all";
  booksFinished: number;
  distinctBooks: number;
  rereads: number;
  dnf: number;
  pages: number;
  readingDays: number;
  pagesPerReadingDay: number;
  longestStreak: number;
  bestDay: { day: string; pages: number } | null;
  /** Months 1..12 for a year; the years themselves for all time. */
  buckets: { key: number; books: number; pages: number }[];
  genres: GenreStats[];
  averageRating: number | null;
  ratings: number[];
  recommended: number;
  notRecommended: number;
  longest: { title: string; coverUrl: string | null; totalUnits: number } | null;
  shortest: { title: string; coverUrl: string | null; totalUnits: number } | null;
};

export type Stats = {
  stats: PeriodStats;
  currentStreak: number;
  years: number[];
};

export type { CatalogCandidate, CatalogEdition };

/** Today in the reader's own timezone. Reading is logged by the reader's day. */
export function localDay(date = new Date()) {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

const API = `${BACKEND_URL}/api/v1/shelf`;

function headers() {
  return { Authorization: getAuthHeader() };
}

export async function shelfGet<T>(path: string): Promise<T> {
  const response = await axios.get(`${API}${path}`, { headers: headers() });
  return response.data as T;
}

export async function shelfSend<T = unknown>(
  method: "post" | "put" | "delete",
  path: string,
  body?: unknown
): Promise<T> {
  const response = await axios.request({ method, url: `${API}${path}`, data: body, headers: headers() });
  return response.data as T;
}

/** The server's own words for a failed request, which are written for people. */
export function errorMessage(error: unknown, fallback = "Something went wrong. Try again.") {
  if (axios.isAxiosError(error)) {
    const msg = error.response?.data?.msg;
    if (typeof msg === "string" && msg) return msg;
    if (!error.response) return "You seem to be offline.";
  }
  return fallback;
}

// --- cache -----------------------------------------------------------------

// The app's one query cache (src/lib/query.ts), under a "shelf" key per path.
// Keyed by account as well as path: one localStorage token is shared by every
// tab, so another account can sign in under an open /books (wiki/gotchas.md).
const shelfKey = (path: string) => accountKey(getCurrentUserId(), "shelf", path);

/** Refetch everything on screen after a write. Cheap: it is a handful of GETs. */
export function invalidateShelf() {
  void queryClient.invalidateQueries({ queryKey: accountKey(getCurrentUserId(), "shelf") });
}

/** Edit a cached answer in place, for an optimistic update. */
export function patchCached<T>(path: string, update: (value: T) => T) {
  queryClient.setQueryData<T>(shelfKey(path), (current) => (current === undefined ? current : update(current)));
}

export function useShelf<T>(path: string | null) {
  const query = useQuery({
    queryKey: shelfKey(path ?? ""),
    queryFn: () => shelfGet<T>(path!),
    enabled: path !== null,
    // Every visit refetches, as this did before it was TanStack: a club's notes
    // and a friend's progress are someone else's writes, which no
    // invalidateShelf() here will ever announce.
    staleTime: 0,
  });
  const { refetch } = query;
  const reload = useCallback(async () => {
    await refetch();
  }, [refetch]);
  return { data: query.data, error: query.error, loading: query.isFetching, reload };
}
