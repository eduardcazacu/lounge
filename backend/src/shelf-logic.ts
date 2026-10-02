// The rules of the shelf that are arithmetic rather than queries: how far a
// reader has got, which book-club notes they may see, what counts as a book
// read this year and how a streak is counted. Kept apart from the router so
// scripts/verify-shelf.ts can drive them without a database.
//
// Days are the reader's own calendar days, as "YYYY-MM-DD" strings. They are
// compared as strings and stepped in UTC, which is exact for whole days and
// never meets a daylight-saving hour.

export type RunStatus = "active" | "finished" | "dnf";

export type RunForReach = {
  status: string;
  position: number;
  totalUnits: number | null;
  /** Whether the reader confirmed this run's length is their copy's. */
  unitsConfirmed?: boolean;
};

/** How far through the work a position is, 0..1, or null if its length is unknown. */
export function fractionOf(position: number, totalUnits: number | null | undefined): number | null {
  if (!totalUnits || totalUnits <= 0) return null;
  return Math.max(0, Math.min(1, position / totalUnits));
}

export type Reach = {
  /** 0..1 */
  fraction: number;
  /**
   * Whether that fraction rests on a length the reader confirmed (or on a
   * finished read, which needs no length). An unconfirmed length is usually
   * the catalog's median across editions, and can be off by a quarter.
   */
  confirmed: boolean;
};

/**
 * How far into a work a reader has got, for spoiler purposes.
 *
 * Anyone who has ever finished it has read everything. Otherwise it is the
 * furthest any of their runs — the active one or one they gave up on — has
 * reached. Measured as a fraction rather than pages because two people's
 * editions rarely have the same page count: page 200 of a 250-page paperback is
 * the ending, of a 500-page hardback it is the middle.
 */
export function readerReach(runs: RunForReach[], itemTotalUnits: number | null): Reach {
  if (runs.some((run) => run.status === "finished")) return { fraction: 1, confirmed: true };
  let reach: Reach = { fraction: 0, confirmed: true };
  for (const run of runs) {
    const fraction = fractionOf(run.position, run.totalUnits ?? itemTotalUnits);
    if (fraction !== null && fraction > reach.fraction) reach = { fraction, confirmed: Boolean(run.unitsConfirmed) };
  }
  return reach;
}

export type ClubNote = {
  id: number;
  userId: number;
  toPosition: number;
  runTotalUnits: number | null;
  /** Whether the writer had confirmed their copy's length. */
  runUnitsConfirmed?: boolean;
};

// Rounding in the reader's favour by a hair, so a note written on the same
// page in the same edition is never hidden by floating point.
const REACH_EPSILON = 1e-6;

/**
 * The margin for a length nobody confirmed. Editions of one book commonly
 * differ by a quarter in pages, and an unconfirmed length is usually the
 * catalog's median, so a fraction resting on one can be well off. Each side
 * — the reader's reach and the note's position — that rests on an unconfirmed
 * length costs this much: a note shows slightly late rather than slightly
 * early, because early is a spoiler.
 */
export const UNCONFIRMED_MARGIN = 0.1;

/**
 * Splits notes into what this reader may see and how many are still ahead of
 * them. Their own notes are always visible. A note whose position cannot be
 * expressed as a fraction — the writer's edition has no known length — is
 * treated as being at the end, because guessing earlier is how spoilers leak.
 */
export function partitionClubNotes<T extends ClubNote>(
  notes: T[],
  viewerId: number,
  reach: Reach,
  itemTotalUnits: number | null
): { visible: (T & { fraction: number | null })[]; aheadCount: number } {
  const visible: (T & { fraction: number | null })[] = [];
  let aheadCount = 0;
  const readerMargin = reach.confirmed ? 0 : UNCONFIRMED_MARGIN;
  for (const note of notes) {
    const fraction = fractionOf(note.toPosition, note.runTotalUnits ?? itemTotalUnits);
    const writerMargin = note.runUnitsConfirmed ? 0 : UNCONFIRMED_MARGIN;
    // Someone who has finished the book has read every page of it, whatever
    // anybody's page counts say.
    const at = reach.fraction >= 1 ? fraction ?? 1 : Math.min(1, (fraction ?? 1) + writerMargin + readerMargin);
    if (note.userId === viewerId || at <= reach.fraction + REACH_EPSILON) {
      visible.push({ ...note, fraction });
    } else {
      aheadCount += 1;
    }
  }
  return { visible, aheadCount };
}

export function addDays(day: string, delta: number): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
}

export function dayOf(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** Prisma maps a `@db.Date` to midnight UTC; this is that, from a local day. */
export function dateFromDay(day: string): Date {
  return new Date(`${day}T00:00:00Z`);
}

/**
 * Consecutive reading days ending today — or yesterday, so that a streak is
 * not shown as broken in the morning before the day's reading is logged.
 */
export function currentStreak(readingDays: Iterable<string>, today: string): number {
  const days = new Set(readingDays);
  let cursor = days.has(today) ? today : addDays(today, -1);
  let count = 0;
  while (days.has(cursor)) {
    count += 1;
    cursor = addDays(cursor, -1);
  }
  return count;
}

export function longestStreak(readingDays: Iterable<string>): number {
  const sorted = [...new Set(readingDays)].sort();
  let best = 0;
  let run = 0;
  let previous: string | null = null;
  for (const day of sorted) {
    run = previous !== null && addDays(previous, 1) === day ? run + 1 : 1;
    if (run > best) best = run;
    previous = day;
  }
  return best;
}

export type StatsLog = {
  /** Which run the pages belong to, so they can be credited to its genres. */
  runId: number;
  loggedOn: string;
  fromPosition: number;
  toPosition: number;
  /** A finished run's closing log: pages, but not a reading day. */
  closing?: boolean;
};

export type StatsRun = {
  id: number;
  entryId: number;
  itemId: number;
  status: string;
  finishedOn: string | null;
  totalUnits: number | null;
  title: string;
  coverUrl: string | null;
  genres: string[];
  rating: number | null;
  recommend: boolean | null;
};

/** A calendar year, or every year at once. */
export type StatsPeriod = number | "all";

export type GenreStats = {
  genre: string;
  books: number;
  pages: number;
  averageRating: number | null;
};

export type PeriodStats = {
  period: StatsPeriod;
  booksFinished: number;
  distinctBooks: number;
  rereads: number;
  dnf: number;
  pages: number;
  readingDays: number;
  pagesPerReadingDay: number;
  longestStreak: number;
  bestDay: { day: string; pages: number } | null;
  /** Months of the year, or every year from the first to the last for "all". */
  buckets: { key: number; books: number; pages: number }[];
  genres: GenreStats[];
  averageRating: number | null;
  ratings: number[];
  recommended: number;
  notRecommended: number;
  longest: { title: string; coverUrl: string | null; totalUnits: number } | null;
  shortest: { title: string; coverUrl: string | null; totalUnits: number } | null;
};

function average(values: number[]) {
  return values.length > 0 ? Math.round((values.reduce((sum, value) => sum + value, 0) / values.length) * 10) / 10 : null;
}

/**
 * A period of reading — one year, or all of it — from every log and every run
 * a person has.
 *
 * Re-reads are counted the way a reader would count them: each finished run
 * is a book finished, so reading something twice is two; and `distinctBooks`
 * beside it says how many different works that was. A run is a re-read if the
 * same entry has an earlier finished run, in any year. Pages are the sum of
 * what each log moved, so the second time through counts as reading done. A
 * DNF counts its pages and nothing else.
 *
 * A book with three genres counts toward all three, books and pages alike, so
 * the genre rows do not add up to the totals and are not meant to.
 *
 * `runs` must hold all of the person's runs, not only this period's, or a
 * re-read of a book first read earlier would look like a first read.
 */
export function buildStats(period: StatsPeriod, logs: StatsLog[], runs: StatsRun[]): PeriodStats {
  const inPeriod = (day: string) => period === "all" || day.startsWith(`${period}-`);

  const finishedInOrder = runs
    .filter((run) => run.status === "finished" && run.finishedOn)
    .sort((a, b) => (a.finishedOn! < b.finishedOn! ? -1 : a.finishedOn! > b.finishedOn! ? 1 : a.id - b.id));
  const seenEntries = new Set<number>();
  const rereadRunIds = new Set<number>();
  for (const run of finishedInOrder) {
    if (seenEntries.has(run.entryId)) rereadRunIds.add(run.id);
    seenEntries.add(run.entryId);
  }
  const finished = finishedInOrder.filter((run) => inPeriod(run.finishedOn!));
  const dnf = runs.filter((run) => run.status === "dnf" && run.finishedOn && inPeriod(run.finishedOn)).length;
  const periodLogs = logs.filter((log) => inPeriod(log.loggedOn));

  // Months for a year; for all time, every year from the first to the last,
  // gaps included, so a year off reading shows as one.
  let buckets: PeriodStats["buckets"];
  const bucketOf = (day: string) => Number(period === "all" ? day.slice(0, 4) : day.slice(5, 7));
  if (period === "all") {
    const years = [...periodLogs.map((log) => log.loggedOn), ...finished.map((run) => run.finishedOn!)].map((day) =>
      Number(day.slice(0, 4))
    );
    const first = years.length ? Math.min(...years) : 0;
    const last = years.length ? Math.max(...years) : -1;
    buckets = Array.from({ length: last - first + 1 }, (_, index) => ({ key: first + index, books: 0, pages: 0 }));
  } else {
    buckets = Array.from({ length: 12 }, (_, index) => ({ key: index + 1, books: 0, pages: 0 }));
  }
  const bucketByKey = new Map(buckets.map((bucket) => [bucket.key, bucket]));

  // Closing logs count as pages — those pages were read — but not toward
  // which days were reading days, the best day or a streak: a book backfilled
  // as "finished 31 December" was not read on the 31st.
  const runById = new Map(runs.map((run) => [run.id, run]));
  const genreRows = new Map<string, { books: number; pages: number; ratings: Map<number, number> }>();
  const genreRow = (genre: string) => {
    let row = genreRows.get(genre);
    if (!row) {
      row = { books: 0, pages: 0, ratings: new Map() };
      genreRows.set(genre, row);
    }
    return row;
  };

  const pagesByDay = new Map<string, number>();
  let pages = 0;
  for (const log of periodLogs) {
    const moved = log.toPosition - log.fromPosition;
    pages += moved;
    const bucket = bucketByKey.get(bucketOf(log.loggedOn));
    if (bucket) bucket.pages += moved;
    if (!log.closing) pagesByDay.set(log.loggedOn, (pagesByDay.get(log.loggedOn) ?? 0) + moved);
    for (const genre of runById.get(log.runId)?.genres ?? []) genreRow(genre).pages += moved;
  }

  // A day only counts as a reading day if it moved forward; a correction that
  // took the bookmark back is not reading.
  const readingDays = [...pagesByDay.entries()].filter(([, moved]) => moved > 0).map(([day]) => day);
  let bestDay: PeriodStats["bestDay"] = null;
  for (const [day, moved] of pagesByDay) {
    if (moved > 0 && (!bestDay || moved > bestDay.pages)) bestDay = { day, pages: moved };
  }

  // A rating belongs to a run, and a re-read can be rated again. For an
  // average each work counts once, at its latest rating in the period.
  const latestRatingByItem = new Map<number, number>();
  let recommended = 0;
  let notRecommended = 0;
  for (const run of finished) {
    const bucket = bucketByKey.get(bucketOf(run.finishedOn!));
    if (bucket) bucket.books += 1;
    for (const genre of run.genres) {
      const row = genreRow(genre);
      row.books += 1;
      if (run.rating !== null) row.ratings.set(run.itemId, run.rating);
    }
    if (run.rating !== null) latestRatingByItem.set(run.itemId, run.rating);
    if (run.recommend === true) recommended += 1;
    if (run.recommend === false) notRecommended += 1;
  }
  const ratings = [...latestRatingByItem.values()];

  const withLength = finished.filter((run) => run.totalUnits && run.totalUnits > 0);
  const pick = (compare: (a: number, b: number) => boolean) =>
    withLength.reduce<StatsRun | null>(
      (best, run) => (!best || compare(run.totalUnits!, best.totalUnits!) ? run : best),
      null
    );
  const longest = pick((a, b) => a > b);
  const shortest = pick((a, b) => a < b);
  const lengthView = (run: StatsRun | null) =>
    run ? { title: run.title, coverUrl: run.coverUrl, totalUnits: run.totalUnits! } : null;

  return {
    period,
    booksFinished: finished.length,
    distinctBooks: new Set(finished.map((run) => run.itemId)).size,
    rereads: finished.filter((run) => rereadRunIds.has(run.id)).length,
    dnf,
    pages,
    readingDays: readingDays.length,
    pagesPerReadingDay:
      readingDays.length > 0 ? Math.round([...pagesByDay.values()].reduce((sum, moved) => sum + moved, 0) / readingDays.length) : 0,
    longestStreak: longestStreak(readingDays),
    bestDay,
    buckets,
    genres: [...genreRows.entries()]
      .map(([genre, row]) => ({
        genre,
        books: row.books,
        pages: row.pages,
        averageRating: average([...row.ratings.values()]),
      }))
      .filter((row) => row.books > 0 || row.pages > 0)
      .sort((a, b) => b.books - a.books || b.pages - a.pages || a.genre.localeCompare(b.genre))
      .slice(0, 12),
    averageRating: average(ratings),
    ratings,
    recommended,
    notRecommended,
    longest: lengthView(longest),
    shortest: lengthView(shortest),
  };
}
