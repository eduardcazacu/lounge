# Books

`/books` is a reading log, a review feed and a spoiler-safe book club for the
same small group, signed in with the same account. It is a web app only. The
router is `backend/src/route/shelf.ts`, the arithmetic is
`backend/src/shelf-logic.ts`, and the client is `frontend/src/components/books/`.

## It is called "shelf" because it is not about books

Nothing in the schema says "book" except a value. `CatalogItem.kind` is
`"book"` today; a film or an album would be another kind. A watch or a listen
would still be a `ShelfRun`, a rating would still be a `ShelfReview`, and the
feed, the discussion and the stats would need no new tables. A new kind costs a
catalog provider in `backend/src/catalog/`, a value in `shelfKinds` in
`common/src/index.ts`, and whatever "units" means for it (pages here; minutes or
tracks there).

Book-specific tables (`books`, `reading_logs`) lost to this. They would have
been easier to name, but every one of them would have needed a twin for the
first other kind anybody asked for.

## The model in one paragraph

A `CatalogItem` is the work, shared across everyone and every group because it
holds only public metadata. A `CatalogEdition` is one printing of a work,
shared the same way. A `ShelfEntry` is one person's relationship to the work,
including the want-to-read flag and which edition they have. A `ShelfRun` is one read-through, and
**a re-read is a new run, never a reset of the old one**. That is what lets
stats count a book read twice as two books finished but one distinct work, and
lets each read carry its own review. A `ProgressLog` is one session of reading,
`fromPosition → toPosition` on the reader's own day. The note on a log is what
the book club shows.

## Rules the schema cannot state

**A finished run always ends with a closing log.** Finishing writes a log for
whatever pages were never logged, dated on the finish day. A book backfilled as
"read in 2023" gets one such log covering the whole book; a DNF backfilled from
the library gets one up to the page it was put down at, if the reader gives
one. Without it, a book
would count toward books finished but not toward pages, and the two numbers
would disagree. The log is marked `closing`. That way its pages count, but its
day is never a reading day, a best day or part of a streak: a remembered book
was not read on 31 December. `PUT /runs/:id` moves the closing log when a
finished run's length or date is corrected.

**Book-club gating is by fraction, never by page.** Each run keeps the length
of its own edition (`ShelfRun.totalUnits`). Page 200 is the ending of a
250-page paperback and the middle of a 500-page hardback. A note is visible
when its fraction is at or below the reader's **reach**. Reach is 1 for anyone
who has ever finished the work, so a re-reader sees everything; otherwise it is
the furthest any of their runs got. A note whose length is unknown everywhere
counts as being at the end. `readerReach` and `partitionClubNotes` own this, and
both are pinned by `scripts/verify-shelf.ts`.

**A length nobody confirmed is allowed for, not trusted.** The catalog's page
count is usually Open Library's median across editions, and a reader's copy can
be a quarter longer or shorter. Taken on trust, it shows notes early, which is
a spoiler. `ShelfRun.unitsConfirmed` says whether the length is the reader's
own. It is set when they give it at Start, when they set it later, or when an
import brings their edition's count. For each side of a comparison that rests
on an unconfirmed length (the reader's reach, the note's position), a note
needs `UNCONFIRMED_MARGIN` (10%) more before it shows. Late is better than
early. The client asks for the length at every Start, prefilled so confirming
is one tap. It shows "Your copy: N pages" when logging. A page logged past the
end prompts "is your copy longer?" instead of being capped, because that is
usually what it means.

**Days are the reader's own.** The client sends `loggedOn` and `today` as local
`YYYY-MM-DD` strings, and the server never derives a reading day from its own
clock. The one place no client is there to say, a KOReader sync, uses the zone
the reader's browser gave when they set sync up. This deliberately differs from Instant's streaks, which are UTC: "pages
read that day" means the reader's day.

**A log in the middle of a run cannot move.** Each log starts where the
previous one ended. Only the latest log of a run in progress can change its page
or be deleted (an undo). Notes on any log can be edited.

**A percentage is logged as a page.** The log sheet's Percent mode is for
e-readers, which show no page worth typing. It is turned into a page of the
reader's copy in `frontend/src/components/books/LogSheet.tsx`, rounded as a
KOReader sync is (`pageAt` in `backend/src/reader-sync.ts`). That way every log
is still a page range, and stats, streaks and the book club need nothing new.
It needs the copy's length, and the sheet asks for it when it is missing.

## Search goes through the backend

`GET /api/v1/shelf/catalog/search` asks Open Library and Google Books at once.
It keeps Open Library's results, which have the covers and need no key, and
fills a missing page count or genre from Google's matching volume. Google's
keyless quota is shared by every caller on the Worker's egress IP and answers
429 often; `GOOGLE_BOOKS_API_KEY` gives it a quota of its own.

**Genres are mapped onto a fixed list** (`cleanGenres` in
`backend/src/catalog/books.ts`), not kept as the providers give them. Open
Library's subjects mix genres with characters and places ("Arkenstone") and
spell one genre several ways ("Science-fiction", "Sci-fi"). Kept raw, they
split one taste across three rows of the genre stats and ranked a dragon's
treasure as somebody's favourite genre. A subject that maps onto nothing is
dropped. A work's genres are fixed on its first sighting, so a change to the
list only reaches works added afterwards.

## Editions are the reader's; the work is everyone's

Open Library's work title and cover belong to whichever edition a librarian
catalogued first, often a translation's. The Last Wish is the work "Ostatnie
Życzenie", with a Polish cover. Search therefore asks for English editions
(`lang=en`), and `fromOpenLibrary` in `backend/src/catalog/books.ts` shows an
English edition's title and cover in place of the work's. It only does this for
English: an edition search picked in another language is no better than the
work's own. A work added for the first time is filed under that English title
and cover.

A reader's edition hangs off their `ShelfEntry` (`editionId`), never off the
work. `itemView` in `backend/src/route/shelf.ts` puts its title and cover in
place of the work's wherever that entry is shown: library, home, their reviews
in the feed and on the Lounge, the book club as they see it, and their stats.
Nobody else's copy changes. An edition with no cover shows the work's.

"Other editions" lists Open Library's editions of the work
(`GET /catalog/editions?work=` from search, `GET /items/:id/editions` from the
book's page), ranked by `rankEditions`: English first, then editions with no
language recorded (mostly English), then the rest; within each, those with a
cover first, then the newest. A list is cached for a day in
`catalog_search_cache` under `editions:<work key>`. Only Open Library works
have editions. Google's volumes are not grouped into works, so a book filed
from Google, or by hand, keeps the cover it has.

**Choosing an edition never changes a run's length.** The book's page offers
the edition's page count through "Pages in your copy" instead, because the
book club trusts only a length the reader confirmed. Edition covers are copied
into R2 like works' (`covers/editions/<id>`, `backend/src/covers.ts`).

## Open Library limits by IP

Open Library rate-limits by IP and is sometimes simply down. Everything that
talks to it is shaped around that, and the rule underneath all of it is in
`backend/src/catalog/books.ts`: **a refusal is never an answer.** A 429, a
403, a 5xx, a timeout or a refused connection becomes `CatalogUnavailable`,
carrying the `Retry-After` it gave. It is never taken for an empty result.

- **Search** answers 503 with `retryAfterSeconds`, and the add screen says
  search is down and offers adding by hand. It never says "Nothing found". If
  Google answered, its results are shown meanwhile.
- **Search answers are cached for a day** in `catalog_search_cache`. A group
  reads the same books, so most searches have been made before. Only answers
  Open Library gave are cached; Google-only ones would outlive the outage
  they came from.
- **Import asks our own catalog first** (`backend/src/catalog/store.ts`): by an
  ISBN an earlier import attached to a work (`CatalogItem.isbns`), then by
  title and author. The second person to import a book costs Open Library
  nothing.
- **Import is paced** to about one Open Library request a second (`paced` in
  `backend/src/catalog/match-book.ts`), one row at a time.
- **Google Books is the second source** for import and the repair (`findBook`).
  It is asked when Open Library refuses or lacks the book, second rather than
  alongside, so a book comes from one source where it can. Only when Open
  Library refused *and* Google did not find the book does the row come back
  as `retry`, with nothing written; the import screen waits as long as Open
  Library asked. A book is made from the export's own details only when Open
  Library answered that it has no such book and Google had none either, or
  could not be asked. A refusing source is not asked again for the rest of
  the batch (`SourceState`).
- **Two sources are still one book.** `resolveCandidate` in
  `backend/src/catalog/store.ts` lands a candidate on a work we already have
  with the same title and author, whatever its source, before creating one.
  Everything that creates a catalog item goes through it: adding from search,
  import, and the repair. Otherwise a Dune first added from Google and later
  picked from Open Library's results would be two works and two book clubs.
- **Covers are copied into R2** when a work is first added
  (`backend/src/covers.ts`), then served from our bucket through Cloudflare's
  resizing. Hotlinked, each viewer's browser asked Open Library for every
  cover. Covers by ISBN are rate-limited per viewer IP, and all of them
  vanished when Open Library went down. `coverUrl` is always the URL to show;
  `coverKey` marks it as our copy. The hourly cron (`runShelfSweep` in
  `backend/src/scheduled.ts`) copies what a request did not get to, rewrites
  URLs if the bucket's address changes, and expires cached searches.
- **Hand-made books can be found again.** `POST /entries/:id/rematch` looks a
  manual item up again, and if the catalog has it, moves **everyone's** entry
  for that item onto the catalog work. A person who already had the work gets
  the two entries merged, reads and all. It is the same book, and two people
  holding two copies of it never meet in its book club. The import summary
  and the book's page both offer it.

Calling the providers from the browser lost because a future kind's provider
(TMDB, say) needs a key that cannot be shipped to a client. Adding takes the
candidate back whole (`addShelfEntryInput`) rather than an id, so it costs no
second round trip to the provider. The first sighting of a work fixes its
metadata.

## Stats are per period

`GET /stats?year=` takes a year or `all`, and `buildStats` in
`backend/src/shelf-logic.ts` computes the same figures either way. Only the
chart's buckets differ: months for a year, and for all time every year from
the first to the last, gaps included, so a year off reading shows as an empty
bar. A book counts toward each of its genres, so the genre rows add up to more
than the totals. A genre's average rating uses each work's latest rating in
the period.

## Adding lands where you asked

The add screen takes `?intent=` (`start`, `want`, `finished`, `dnf`). Each
library tab opens it with its own intent, so the screen shows that one button
and returns to the tab with the book in it. Without an intent it offers Want,
Start and Read it. There, Want stays on the screen for adding several in a row,
and Read it goes on to the review prompt.

## Importing from Goodreads

`/books/import` reads a Goodreads library export
(`goodreads_library_export.csv`) **in the browser**, in
`frontend/src/components/books/goodreads.ts`. Only the shelf's own columns go
to `POST /api/v1/shelf/import`, so private notes never leave the device. The
rows are sent eight at a time (`IMPORT_BATCH_SIZE` in `common/src/index.ts`,
which says what each row can cost); a Worker on the free plan may make only 50
outbound requests per invocation.
How a row finds its book, cheapest first, is in the comment on `importRow` in
`backend/src/route/shelf.ts`; what happens when Open Library refuses is in
"Open Library limits by IP" above. No row is dropped.

Three rules, all chosen deliberately:

- **A book is recognised by its Goodreads id, never re-matched.** Its entry
  and run carry `importId` (`goodreads:<Book Id>`). Open Library does not
  answer the same way twice; it was seen matching a book by title on one run
  and failing on the next. A second import that matched again would add the
  book twice. With the id, re-importing a newer export adds only what changed,
  and a book that was "currently reading" last time is finished rather than
  read again.
- **One read per book, on the one date the export has.** Goodreads exports a
  `Read Count`, but only the last read's date. Inventing dates for the earlier
  reads would distort every year's stats.
- **Imported reviews never reach the feed.** `ShelfReview.imported` keeps them
  out of `/reviews` unless the request is for one book's page. An import is
  years of reviews arriving at once and would bury what people are reading
  now.

Goodreads has no "did not finish"; people make a shelf for it. The import
screen offers the export's custom shelves and preselects one that looks like
DNF (`looksLikeDnfShelf`).

```bash
cd backend && npx tsx ../frontend/scripts/verify-goodreads.ts   # the export's quirks: formula ISBNs, HTML reviews, quoted line breaks
```

## KOReader sync

The backend is a KOReader **progress sync server**: KOReader's built-in
Progress sync plugin is pointed at `https://<api>/kosync` with a login made in
`/books/koreader`, and page turns on a Kindle move the book here. The wire is
`backend/src/route/kosync.ts`; what a sync means is
`backend/src/reader-sync.ts`.

- **A file has to be identified once.** KOReader names a file only by a hash
  (`ReaderDocument.document`) and sends a percentage. A file nobody has
  identified is stored and shown on Home as "which book is it?", with the
  likeliest choice marked. When KOReader's "Send document metadata" is on, its
  title and authors come with each sync, and a title naming exactly one read
  under way links the file by itself (`matchByMetadata`, the import's
  `sameBook`).
- **A sync never starts or finishes a read.** It moves only a run already
  under way. A want-list book is linked, and so started, only by the reader. Near
  the end the card asks "Finished it?", for the epilogue reason a manual log
  gives.
- **Percentage becomes a page of the reader's copy**, so a run with no known
  length logs nothing until it has one. Linking asks.
- **Forward only.** A sync behind the run's position is stored, for KOReader's
  other devices, but logs nothing. Paging back to check a map is not
  un-reading.
- **One KOReader log per run per day.** A sync extends that day's `koreader`
  log (`ProgressLog.source`) rather than adding a row per page turn. A note or
  a hand-written log ends it, so nothing the reader wrote is ever moved.
- **The login is generated.** It is a 12-character password, shown once, and
  stored as sha256 of the md5 KOReader derives from it (`ReaderSync.keyHash`).
  KOReader's Register button is refused.

KOReader's progress is handed back verbatim on `GET /syncs/progress/:document`,
so syncing between several KOReader devices keeps working with the Lounge as
their only server.

## On the Lounge

A review can be cross-posted as a `Post` with `shelfReviewId` set. The blog
feed (`/blog/bulk`, `/blog/:id`) selects the review through that relation, and
`frontend/src/components/ShelfReviewEmbed.tsx` draws the card from it. Editing
the review therefore edits the card, and the post's own title and content are
only a plain-text fallback. The card opens `/books/review/:id`, where the
discussion is. Deleting a run deletes its Lounge post first.

## Notifications

Three kinds, each with its own switch under the account's master switch
(`notifyBookDiscussion`, `notifyBookClub`, `notifyBookActivity` on `User`; the
Books section of Account settings):

- **Replies**: a comment on your review, or in a discussion you are in.
- **Book club notes**: `notifyBookClubNote` in `backend/src/shelf-notify.ts`
  runs the same gate as the club screen (`partitionClubNotes`) for every
  current reader. A notification therefore never shows anyone more than the
  club would, and the note's text can be in it. At most one per book per
  reader per day: the `notifications_sent` row is both the record and the
  check. Readers who finished the book are not told; their club has moved on.
  A reader whose own logging unlocks notes is told in the app instead
  (`unlockedNotes` on the log response). They are already looking at it, and
  a push to yourself is noise.
- **Friends' reading**: someone starting a book you want to read, or finishing
  one you are reading. Never from an import or a backfilled read, which would
  replay years of someone's history at everyone at once. A finish carries no
  rating, because a rating is the beginning of a spoiler.

All of them go through `sendPushToUsers` **without `apnsConfig`**, so Web Push
only: the iOS app is Instant and cannot open Books. Blocks are honoured both
ways.

Books asks for permission itself, from a row in the avatar menu and a card
that appears once a reading has been logged. The Lounge's banner is kept off
`/books`, and on an iPhone each home-screen web app has its own permission;
see [gotchas.md](gotchas.md).

## The standalone app

`/books` is served from `frontend/books.html`, a second Vite entry that loads
the same bundle but names `books.webmanifest` and the books icons. Browsers
read the manifest link from the page as it first loads, so swapping the link
from script lost: "Add to Home Screen" does not reliably see a change made
after load. The rewrites in `vercel.json` send `/books/*` there.

The manifest's `scope` is `/`, not `/books`, so "Back to the Lounge" stays
inside the installed app instead of opening the browser's out-of-scope bar. Its
distinct `id` and `start_url` are what make it a second installable app.
Signing in honours `?next=`, which keeps a sign-in from the installed app inside
it. `safeNextPath` in `frontend/src/components/Auth.tsx` accepts only same-site
paths.

The icons are drawn by `frontend/scripts/make-books-icons.swift`; regenerate
them rather than editing the PNGs.

```bash
cd backend && npx tsx scripts/verify-shelf.ts   # re-reads, backfills, DNFs, streaks, spoiler gating
```
