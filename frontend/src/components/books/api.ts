import axios from "axios";
import { useCallback, useEffect, useRef, useState } from "react";
import type { CatalogCandidate } from "@blogging-app/common";
import { BACKEND_URL } from "../../config";
import { getAuthHeader, getCurrentUserId } from "../../lib/auth";

// The shelf API, and the one cache /books reads through.
//
// Every screen asks `useShelf(path)` and gets the last answer for that path at
// once, if there is one, while a fresh one is fetched. A write calls
// `invalidateShelf()`, which refetches whatever is on screen. That is the whole
// data layer: the shelf is one person's few hundred rows, and showing the last
// answer first is what makes the home screen open instantly from the home
// screen icon.

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
};

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
  createdAt: string;
  editedAt: string | null;
};

export type HomeReading = {
  entryId: number;
  item: Item;
  run: Run;
  today: number;
  club: { visibleNotes: number; aheadNotes: number; readers: Person[] };
};

export type Home = {
  today: string;
  reading: HomeReading[];
  want: { entryId: number; item: Item }[];
  highlights: { year: number; booksThisYear: number; pagesThisWeek: number; streak: number };
};

export type ProgressLogRow = {
  id: number;
  loggedOn: string;
  fromPosition: number;
  toPosition: number;
  note: string | null;
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

export type { CatalogCandidate };

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

// Keyed by account as well as path: one localStorage token is shared by every
// tab, so another account can sign in under an open /books (wiki/gotchas.md).
const cache = new Map<string, unknown>();
const cacheKey = (path: string) => `${getCurrentUserId() ?? "-"}:${path}`;
const INVALIDATE_EVENT = "shelf-invalidate";

/** Refetch everything on screen after a write. Cheap: it is a handful of GETs. */
export function invalidateShelf() {
  window.dispatchEvent(new Event(INVALIDATE_EVENT));
}

/** Edit a cached answer in place, for an optimistic update. */
export function patchCached<T>(path: string, update: (value: T) => T) {
  const current = cache.get(cacheKey(path)) as T | undefined;
  if (current !== undefined) {
    cache.set(cacheKey(path), update(current));
    window.dispatchEvent(new CustomEvent(`${INVALIDATE_EVENT}:local`, { detail: path }));
  }
}

export function useShelf<T>(path: string | null) {
  const [data, setData] = useState<T | undefined>(() => (path ? (cache.get(cacheKey(path)) as T | undefined) : undefined));
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(false);
  const latestPath = useRef(path);
  latestPath.current = path;

  const load = useCallback(async () => {
    if (!path) return;
    setLoading(true);
    try {
      const value = await shelfGet<T>(path);
      cache.set(cacheKey(path), value);
      if (latestPath.current === path) {
        setData(value);
        setError(null);
      }
    } catch (e) {
      if (latestPath.current === path) setError(e);
    } finally {
      if (latestPath.current === path) setLoading(false);
    }
  }, [path]);

  useEffect(() => {
    setData(path ? (cache.get(cacheKey(path)) as T | undefined) : undefined);
    setError(null);
    void load();
  }, [path, load]);

  useEffect(() => {
    const reload = () => void load();
    const onVisible = () => {
      if (document.visibilityState === "visible") reload();
    };
    const onLocal = (event: Event) => {
      if (path && (event as CustomEvent<string>).detail === path) setData(cache.get(cacheKey(path)) as T);
    };
    window.addEventListener(INVALIDATE_EVENT, reload);
    window.addEventListener(`${INVALIDATE_EVENT}:local`, onLocal);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener(INVALIDATE_EVENT, reload);
      window.removeEventListener(`${INVALIDATE_EVENT}:local`, onLocal);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [load, path]);

  return { data, error, loading, reload: load };
}
