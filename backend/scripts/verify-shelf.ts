// Checks the shelf's arithmetic: re-reads, backfilled reads, DNFs, streaks and
// the book club's spoiler gate.
//
//   cd backend && npx tsx scripts/verify-shelf.ts
//
// These are the rules that fail without an error — a stat that is merely
// wrong, or a note shown one chapter too early — so they are pinned here rather
// than trusted to be noticed. The router feeds them rows; nothing here needs a
// database.

import {
  addDays,
  buildStats,
  currentStreak,
  longestStreak,
  partitionClubNotes,
  readerReach,
  type StatsRun,
} from "../src/shelf-logic";
import { cleanGenres, parseRetryAfter } from "../src/catalog/books";
import { sameBook } from "../src/catalog/match-book";

let checks = 0;
let failures = 0;
function check(label: string, ok: boolean, detail?: unknown) {
  checks += 1;
  if (ok) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

function run(partial: Partial<StatsRun> & Pick<StatsRun, "id" | "entryId" | "itemId" | "status">): StatsRun {
  return {
    finishedOn: null,
    totalUnits: 300,
    title: `Book ${partial.itemId}`,
    coverUrl: null,
    genres: [],
    rating: null,
    recommend: null,
    ...partial,
  };
}

console.log("Re-reads");
{
  // Dune read in 2025, re-read twice in 2026. Hyperion read once in 2026.
  const runs = [
    run({ id: 1, entryId: 10, itemId: 100, status: "finished", finishedOn: "2025-06-01", rating: 8 }),
    run({ id: 2, entryId: 10, itemId: 100, status: "finished", finishedOn: "2026-02-01", rating: 10, genres: ["Science fiction"] }),
    run({ id: 3, entryId: 10, itemId: 100, status: "finished", finishedOn: "2026-08-01", rating: 6, genres: ["Science fiction"] }),
    run({ id: 4, entryId: 11, itemId: 101, status: "finished", finishedOn: "2026-03-10", rating: 9, totalUnits: 500, genres: ["Science fiction"] }),
  ];
  const logs = [
    { runId: 2, loggedOn: "2026-01-20", fromPosition: 0, toPosition: 300 },
    { runId: 3, loggedOn: "2026-07-30", fromPosition: 0, toPosition: 300 },
    { runId: 4, loggedOn: "2026-03-10", fromPosition: 0, toPosition: 500 },
    { runId: 1, loggedOn: "2025-05-30", fromPosition: 0, toPosition: 300 },
  ];
  const stats = buildStats(2026, logs, runs);
  check("each finished run is a book finished", stats.booksFinished === 3, stats.booksFinished);
  check("two different works", stats.distinctBooks === 2, stats.distinctBooks);
  check("a re-read of a book first read last year still counts as a re-read", stats.rereads === 2, stats.rereads);
  check("a re-read's pages count as pages read", stats.pages === 1100, stats.pages);
  check("a work's latest rating stands for it in the average", stats.averageRating === 7.5, stats.averageRating);
  check("genres are counted per finished run", stats.genres[0]?.books === 3, stats.genres);
  check("a genre's pages come from its books' logs", stats.genres[0]?.pages === 1100, stats.genres[0]);
  check("a genre's average uses each work's latest rating", stats.genres[0]?.averageRating === 7.5, stats.genres[0]);
  check("months are bucketed by finish day", stats.buckets[1].books === 1 && stats.buckets[7].books === 1, stats.buckets);
  check("longest book", stats.longest?.totalUnits === 500, stats.longest);
}

console.log("Backfilled reads and DNFs");
{
  // A book added as "read in March 2024" has one closing log on its finish day.
  const runs = [
    run({ id: 1, entryId: 1, itemId: 1, status: "finished", finishedOn: "2024-03-15" }),
    run({ id: 2, entryId: 2, itemId: 2, status: "dnf", finishedOn: "2024-05-01" }),
  ];
  const logs = [
    { runId: 1, loggedOn: "2024-03-15", fromPosition: 0, toPosition: 300 },
    { runId: 2, loggedOn: "2024-04-20", fromPosition: 0, toPosition: 80 },
  ];
  const stats = buildStats(2024, logs, runs);
  check("a backfilled read counts as a book in its year", stats.booksFinished === 1, stats.booksFinished);
  check("and its pages land on its finish day", stats.buckets[2].pages === 300, stats.buckets[2]);
  check("a DNF counts its pages", stats.pages === 380, stats.pages);
  check("but not as a book finished", stats.booksFinished === 1 && stats.dnf === 1, stats);
  check("nothing leaks into another year", buildStats(2023, logs, runs).pages === 0);
}

console.log("Closing logs");
{
  // Three days of logged reading, then a book backfilled as finished on 31 Dec.
  const stats = buildStats(
    2025,
    [
      { runId: 1, loggedOn: "2025-03-01", fromPosition: 0, toPosition: 30 },
      { runId: 1, loggedOn: "2025-03-02", fromPosition: 30, toPosition: 60 },
      { runId: 1, loggedOn: "2025-03-03", fromPosition: 60, toPosition: 90 },
      { runId: 1, loggedOn: "2025-12-31", fromPosition: 0, toPosition: 900, closing: true },
    ],
    [run({ id: 1, entryId: 1, itemId: 1, status: "finished", finishedOn: "2025-12-31", totalUnits: 900 })]
  );
  check("a closing log's pages count", stats.pages === 990, stats.pages);
  check("but its day is not a reading day", stats.readingDays === 3, stats.readingDays);
  check("nor the best day", stats.bestDay?.pages === 30, stats.bestDay);
  check("nor part of the pace", stats.pagesPerReadingDay === 30, stats.pagesPerReadingDay);
  check("and it still lands in its month", stats.buckets[11].pages === 900, stats.buckets[11]);
}

console.log("All time");
{
  const runs = [
    run({ id: 1, entryId: 1, itemId: 1, status: "finished", finishedOn: "2023-06-01", genres: ["Fantasy"], rating: 6 }),
    run({ id: 2, entryId: 1, itemId: 1, status: "finished", finishedOn: "2026-02-01", genres: ["Fantasy"], rating: 9 }),
    run({ id: 3, entryId: 2, itemId: 2, status: "dnf", finishedOn: "2025-01-10", genres: ["Horror"] }),
  ];
  const logs = [
    { runId: 1, loggedOn: "2023-06-01", fromPosition: 0, toPosition: 300, closing: true },
    { runId: 2, loggedOn: "2026-01-15", fromPosition: 0, toPosition: 300 },
    { runId: 3, loggedOn: "2025-01-05", fromPosition: 0, toPosition: 40 },
  ];
  const stats = buildStats("all", logs, runs);
  check("all time counts every finished run", stats.booksFinished === 2 && stats.distinctBooks === 1 && stats.rereads === 1, stats);
  check("all time counts every page", stats.pages === 640, stats.pages);
  check("all time buckets are years, gaps included", stats.buckets.map((bucket) => bucket.key).join() === "2023,2024,2025,2026", stats.buckets);
  check("an empty year in the middle is an empty bar", stats.buckets[1].pages === 0 && stats.buckets[1].books === 0, stats.buckets[1]);
  check("a DNF's genre gets its pages but no book", stats.genres.find((row) => row.genre === "Horror")?.pages === 40 && stats.genres.find((row) => row.genre === "Horror")?.books === 0, stats.genres);
  check("all time average uses the latest rating", stats.averageRating === 9, stats.averageRating);
  check("nothing at all is no buckets", buildStats("all", [], []).buckets.length === 0);
}

console.log("Corrections");
{
  const stats = buildStats(
    2026,
    [
      { runId: 1, loggedOn: "2026-01-01", fromPosition: 0, toPosition: 50 },
      { runId: 1, loggedOn: "2026-01-02", fromPosition: 50, toPosition: 40 },
    ],
    []
  );
  check("a bookmark moved back nets out of the page total", stats.pages === 40, stats.pages);
  check("and the day it happened is not a reading day", stats.readingDays === 1, stats.readingDays);
}

console.log("Streaks");
{
  const today = "2026-10-01";
  const days = [today, addDays(today, -1), addDays(today, -2), addDays(today, -4)];
  check("counts back from today", currentStreak(days, today) === 3);
  check("survives a morning with nothing logged yet", currentStreak(days.slice(1), today) === 2);
  check("is broken by a missed day", currentStreak([addDays(today, -2)], today) === 0);
  check("crosses a month boundary", currentStreak(["2026-03-01", "2026-02-28"], "2026-03-01") === 2);
  check("longest run in a set", longestStreak(["2026-01-01", "2026-01-02", "2026-01-05", "2026-01-06", "2026-01-07"]) === 3);
}

console.log("Book club");
{
  // Every length here is confirmed, so this is the edition arithmetic alone.
  // The item's catalog edition is 400 pages. I read a 200-page edition and am
  // on page 80: 40%. Ana reads the 400-page one and wrote at page 240: 60%. In
  // pages, 240 is past my 80 either way; but Ben wrote at page 100 of a
  // 500-page edition — 20% — which a page comparison would hide.
  const itemTotal = 400;
  const me = 1;
  const reach = readerReach([{ status: "active", position: 80, totalUnits: 200, unitsConfirmed: true }], itemTotal);
  check("reach is a fraction of the reader's own edition", Math.abs(reach.fraction - 0.4) < 1e-9 && reach.confirmed, reach);

  const notes = [
    { id: 1, userId: 2, toPosition: 240, runTotalUnits: 400, runUnitsConfirmed: true },
    { id: 2, userId: 3, toPosition: 100, runTotalUnits: 500, runUnitsConfirmed: true },
    { id: 3, userId: 4, toPosition: 160, runTotalUnits: 400, runUnitsConfirmed: true },
    { id: 4, userId: me, toPosition: 199, runTotalUnits: 200, runUnitsConfirmed: true },
    { id: 5, userId: 5, toPosition: 10, runTotalUnits: null, runUnitsConfirmed: true },
  ];
  const { visible, aheadCount } = partitionClubNotes(notes, me, reach, itemTotal);
  const ids = visible.map((note) => note.id).sort();
  check("a note at 60% is hidden at 40%", !ids.includes(1), ids);
  check("a note at 20% of a longer edition is shown", ids.includes(2), ids);
  check("a note at exactly my place is shown", ids.includes(3), ids);
  check("my own notes are always shown", ids.includes(4), ids);
  check("an edition of unknown length falls back to the catalog's", ids.includes(5), ids);
  check("the hidden ones are counted", aheadCount === 1, aheadCount);

  const unknown = partitionClubNotes([{ id: 9, userId: 2, toPosition: 10, runTotalUnits: null, runUnitsConfirmed: true }], me, { fraction: 0.5, confirmed: true }, null);
  check("a note with no length anywhere is treated as the ending", unknown.aheadCount === 1, unknown);

  const finisher = readerReach(
    [
      { status: "finished", position: 200, totalUnits: 200 },
      { status: "active", position: 10, totalUnits: 200 },
    ],
    itemTotal
  );
  check("a re-reader who finished it before sees everything", finisher.fraction === 1 && finisher.confirmed, finisher);
  const quitter = readerReach([{ status: "dnf", position: 300, totalUnits: 400, unitsConfirmed: true }], itemTotal);
  check("a DNF reaches as far as it got", quitter.fraction === 0.75, quitter);
}

console.log("Unconfirmed page counts");
{
  // The catalog says 400 pages; my copy really has 600, but I never said so.
  // On page 300 I am halfway, and Books thinks I am at 75%.
  const me = 1;
  const reach = readerReach([{ status: "active", position: 300, totalUnits: 400, unitsConfirmed: false }], 400);
  check("an unconfirmed reach says so", reach.fraction === 0.75 && !reach.confirmed, reach);
  const at = (fraction: number, confirmed = true) => ({ id: Math.round(fraction * 1000), userId: 2, toPosition: fraction * 400, runTotalUnits: 400, runUnitsConfirmed: confirmed });
  const shown = (fraction: number, confirmed = true, viewer = reach) =>
    partitionClubNotes([at(fraction, confirmed)], me, viewer, 400).visible.length === 1;
  check("a note just under an unconfirmed reach waits", !shown(0.7));
  check("one comfortably under it shows", shown(0.64));
  check("the same note shows once my length is confirmed", shown(0.7, true, { ...reach, confirmed: true }));
  check("a note from an unconfirmed copy waits a little longer", !shown(0.6, false, { fraction: 0.65, confirmed: true }));
  check("both unconfirmed: the margins add up", !shown(0.56, false, reach) && shown(0.54, false, reach));
  check("a finished reader sees every note, confirmed or not", partitionClubNotes([at(0.99, false)], me, { fraction: 1, confirmed: true }, 400).visible.length === 1);
}

console.log("Genres");
{
  const hobbit = cleanGenres(["Arkenstone", "Battle of Five Armies", "Fantasy fiction", "Dragons", "Juvenile fiction", "Accessible book"]);
  check("places and things are dropped, genres kept", hobbit.join() === "Fantasy,Children's", hobbit);
  const sf = cleanGenres(["Science-fiction", "Sci-fi", "Hard science-fiction", "Fiction, science fiction, general"]);
  check("spellings of one genre are one genre", sf.join() === "Science fiction", sf);
  const hist = cleanGenres(["Fiction, historical, general", "History"]);
  check("historical fiction is not history", hist.join() === "Historical fiction,History", hist);
  check("plain fiction survives alone", cleanGenres(["Fiction", "Protected DAISY"]).join() === "Fiction");
  check("plain fiction gives way to a real genre", cleanGenres(["Fiction", "Mystery"]).join() === "Mystery");
  check("nothing recognisable is no genre", cleanGenres(["Arkenstone", "In library"]).length === 0);
}

console.log("Import matching");
{
  const row = { title: "Dune (Dune Chronicles, #1)", creators: ["Frank Herbert"] };
  check("a series suffix does not stop a match", sameBook(row, { title: "Dune", author_name: ["Frank Herbert"] }));
  check("a subtitle does not stop a match", sameBook({ title: "Sapiens", creators: ["Yuval Noah Harari"] }, { title: "Sapiens: A Brief History of Humankind", author_name: ["Yuval Noah Harari"] }));
  check("a different author is not a match", !sameBook({ title: "Circe", creators: ["Madeline Miller"] }, { title: "Circe", author_name: ["Someone Else"] }));
  check("a different title is not a match", !sameBook(row, { title: "Dune Messiah", author_name: ["Frank Herbert"] }));
  check("a study guide is not the book", !sameBook({ title: "Project Hail Mary", creators: ["Andy Weir"] }, { title: "Summary of Project Hail Mary", author_name: ["Andy Weir"] }));
}

console.log("Retry-After");
{
  const now = Date.parse("2026-10-02T12:00:00Z");
  check("seconds are seconds", parseRetryAfter("120", 60, now) === 120);
  check("an HTTP date is the time until it", parseRetryAfter("Fri, 02 Oct 2026 12:00:45 GMT", 60, now) === 45);
  check("missing falls back", parseRetryAfter(null, 60, now) === 60);
  check("nonsense falls back", parseRetryAfter("soon", 30, now) === 30);
  check("a date in the past still waits a moment", parseRetryAfter("Fri, 02 Oct 2026 11:00:00 GMT", 60, now) === 1);
  check("a day is clamped to an hour", parseRetryAfter("86400", 60, now) === 3600);
}

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures > 0) process.exit(1);
