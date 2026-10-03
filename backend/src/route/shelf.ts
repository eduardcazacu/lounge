import { Hono } from "hono";
import type { Context } from "hono";
import { verify } from "hono/jwt";
import type { Prisma, PrismaClient } from "@prisma/client";
import {
  addShelfEntryInput,
  finishRunInput,
  importBatchInput,
  startRunInput,
  linkReaderDocumentInput,
  logProgressInput,
  readerSetupInput,
  reviewCommentInput,
  shelfKind,
  updateProgressLogInput,
  updateRunInput,
  upsertReviewInput,
} from "@blogging-app/common";
import { getConfig } from "../env";
import { getPrismaClient } from "../prisma";
import { getUserGroupId } from "../groups";
import { scheduleBackgroundWork } from "../background";
import { notifyFollowersOfNewPost, sendPushToUsers } from "../push";
import { CatalogUnavailable, SEARCH_CACHE_TTL_MS, searchCatalog } from "../catalog";
import { findBook, freshSourceState, manualCandidate, type SourceState } from "../catalog/match-book";
import { findKnownBook, rememberIsbns, resolveCandidate } from "../catalog/store";
import { copyCovers, deleteCover } from "../covers";
import { notifyBookClubNote, notifyFinishedReading, notifyStartedReading, type NotifyConfig } from "../shelf-notify";
import { blockedUserIds } from "../blocks";
import {
  applyDocument,
  dayInZone,
  generatePassword,
  hashReaderKey,
  pendingDocuments,
  readerKeyFor,
  recordProgress,
  usernameFrom,
  validTimeZone,
} from "../reader-sync";
import type { CatalogCandidate, ImportRowInput, ImportRowResult } from "@blogging-app/common";
import {
  addDays,
  buildStats,
  currentStreak,
  dateFromDay,
  dayOf,
  fractionOf,
  partitionClubNotes,
  readerReach,
  type StatsPeriod,
} from "../shelf-logic";

// /books. The tables are generic — a CatalogItem has a `kind` and nothing else
// here is about books — so another kind is a new catalog provider and a new
// value in `shelfKinds`, not a new router. See wiki/books.md.
//
// Everything social (reviews, discussion, the book club, other people's
// shelves) is confined to the caller's group and answers 404 outside it, as
// the blog and Instant do. The catalog is shared across groups because it
// holds only public metadata.

type ShelfEnv = {
  Bindings: {
    DATABASE_URL?: string;
    JWT_SECRET?: string;
    R2_PUBLIC_BASE_URL?: string;
    VAPID_PUBLIC_KEY?: string;
    VAPID_PRIVATE_KEY?: string;
    VAPID_SUBJECT?: string;
    GOOGLE_BOOKS_API_KEY?: string;
    GOOGLE_BOOKS_URL?: string;
    OPEN_LIBRARY_URL?: string;
    BLOG_IMAGES?: R2Bucket;
  };
  Variables: {
    userId: number;
  };
};

export const shelfRouter = new Hono<ShelfEnv>();

shelfRouter.use("/*", async (c, next) => {
  try {
    const authHeader = c.req.header("Authorization") || "";
    const token = authHeader.startsWith("Bearer ")
      ? authHeader.slice("Bearer ".length).trim()
      : authHeader.trim();
    if (!token) {
      c.status(403);
      return c.json({ msg: "Missing authorization token" });
    }
    const { jwtSecret } = getConfig(c);
    const payload = await verify(token, jwtSecret, "HS256");
    // Any audience at all marks a special-purpose token (Instant's socket
    // ticket), never an API credential.
    if (payload?.aud !== undefined) {
      c.status(403);
      return c.json({ msg: "This token cannot be used for API requests" });
    }
    const userId = Number(payload?.id);
    if (!Number.isFinite(userId)) {
      c.status(403);
      return c.json({ msg: "Token payload is missing a valid user id" });
    }
    c.set("userId", userId);
    await next();
  } catch (e) {
    c.status(403);
    return c.json({
      msg: "You are not logged in",
      error: e instanceof Error ? e.message : "Invalid token",
    });
  }
});

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

const personSelect = { id: true, name: true, themeKey: true, profilePictureKey: true } as const;

type PersonRow = { id: number; name: string | null; themeKey: string; profilePictureKey: string | null };

function publicUrl(baseUrl: string | undefined, key: string | null) {
  if (!baseUrl || !key) return null;
  return `${baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl}/${key}`;
}

function personView(row: PersonRow, r2: string | undefined) {
  return {
    id: row.id,
    name: row.name,
    themeKey: row.themeKey,
    profilePictureUrl: publicUrl(r2, row.profilePictureKey),
  };
}

const itemSelect = {
  id: true,
  kind: true,
  // "manual" marks a book the catalog did not supply, which the reader can
  // ask to have found (POST /entries/:id/rematch).
  source: true,
  title: true,
  creators: true,
  year: true,
  coverUrl: true,
  totalUnits: true,
  genres: true,
} as const;

type ItemRow = Prisma.CatalogItemGetPayload<{ select: typeof itemSelect }>;

const itemView = (item: ItemRow) => item;

type RunRow = {
  id: number;
  status: string;
  startedOn: Date | null;
  finishedOn: Date | null;
  totalUnits: number | null;
  position: number;
  unitsConfirmed?: boolean;
};

function runView(run: RunRow, itemTotalUnits: number | null) {
  const totalUnits = run.totalUnits ?? itemTotalUnits;
  return {
    id: run.id,
    status: run.status,
    startedOn: run.startedOn ? dayOf(run.startedOn) : null,
    finishedOn: run.finishedOn ? dayOf(run.finishedOn) : null,
    totalUnits,
    position: run.position,
    fraction: fractionOf(run.position, totalUnits),
    // Whether `totalUnits` is the reader's own copy, as opposed to the
    // catalog's median across editions. The client asks when it is not.
    unitsConfirmed: Boolean(run.unitsConfirmed),
  };
}

type ReviewRow = {
  id: number;
  rating: number | null;
  recommend: boolean | null;
  body: string | null;
  createdAt: Date;
  editedAt: Date | null;
};

function reviewView(review: ReviewRow) {
  return {
    id: review.id,
    rating: review.rating,
    recommend: review.recommend,
    body: review.body,
    createdAt: review.createdAt.toISOString(),
    editedAt: review.editedAt ? review.editedAt.toISOString() : null,
  };
}

// A review row exists as soon as someone opens the prompt and saves anything,
// including nothing. It is only a review — in the feed, on the Lounge — once it
// says something.
const reviewHasContent: Prisma.ShelfReviewWhereInput = {
  OR: [{ rating: { not: null } }, { recommend: { not: null } }, { body: { not: null } }],
};

function cleanBody(body: string | null | undefined) {
  if (body === undefined) return undefined;
  const trimmed = body?.trim() ?? "";
  return trimmed.length > 0 ? trimmed : null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function db(c: Context<ShelfEnv>) {
  const config = getConfig(c);
  return { prisma: getPrismaClient(config.databaseUrl) as PrismaClient, config };
}

function idParam(c: Context<ShelfEnv>, name: string) {
  const value = Number(c.req.param(name));
  return Number.isInteger(value) && value > 0 ? value : null;
}

function todayFrom(c: Context<ShelfEnv>) {
  const raw = c.req.query("today");
  return raw && /^\d{4}-\d{2}-\d{2}$/.test(raw) ? raw : dayOf(new Date());
}

async function readJson(c: Context<ShelfEnv>) {
  try {
    return await c.req.json();
  } catch {
    return null;
  }
}

function notFound(c: Context<ShelfEnv>, msg = "Not found") {
  c.status(404);
  return c.json({ msg });
}

function badRequest(c: Context<ShelfEnv>, msg: string) {
  c.status(400);
  return c.json({ msg });
}

function conflict(c: Context<ShelfEnv>, msg: string) {
  c.status(409);
  return c.json({ msg });
}

async function requireGroup(c: Context<ShelfEnv>, prisma: PrismaClient) {
  return getUserGroupId(prisma, c.get("userId"));
}

/** The caller's own run, with what the log and finish paths need. */
async function ownRun(prisma: PrismaClient, runId: number, userId: number) {
  const run = await prisma.shelfRun.findUnique({
    where: { id: runId },
    include: { entry: { select: { userId: true, itemId: true, item: { select: itemSelect } } } },
  });
  return run && run.entry.userId === userId ? run : null;
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

/** Says the catalog is unavailable, and when to try again, rather than that nothing exists. */
function catalogUnavailable(c: Context<ShelfEnv>, error: CatalogUnavailable) {
  c.header("Retry-After", String(error.retryAfterSeconds));
  c.status(503);
  return c.json({
    msg: "Book search is unavailable right now. Try again in a minute, or add the book by hand.",
    retryAfterSeconds: error.retryAfterSeconds,
  });
}

/**
 * Search, through a day-long cache. A group reads the same books, so most
 * searches have been made before, and each one answered from the cache is one
 * Open Library — which limits by IP — never sees. Only complete answers are
 * cached; see `BookSearchResult.complete`.
 */
shelfRouter.get("/catalog/search", async (c) => {
  const kind = shelfKind.safeParse(c.req.query("kind") ?? "book");
  if (!kind.success) return badRequest(c, "Unknown kind.");
  const query = (c.req.query("q") ?? "").trim().replace(/\s+/g, " ").slice(0, 200);
  if (query.length < 2) return c.json({ results: [] });
  const { prisma, config } = db(c);
  const key = query.toLowerCase();

  const cached = await prisma.catalogSearchCache.findUnique({ where: { kind_query: { kind: kind.data, query: key } } });
  if (cached && Date.now() - cached.createdAt.getTime() < SEARCH_CACHE_TTL_MS) {
    return c.json({ results: cached.results });
  }

  try {
    const { results, complete } = await searchCatalog(kind.data, query, {
      ...catalogOptions(config),
    });
    if (complete) {
      const json = results as unknown as Prisma.InputJsonValue;
      await prisma.catalogSearchCache.upsert({
        where: { kind_query: { kind: kind.data, query: key } },
        create: { kind: kind.data, query: key, results: json },
        update: { results: json, createdAt: new Date() },
      });
    }
    return c.json({ results });
  } catch (error) {
    if (error instanceof CatalogUnavailable) return catalogUnavailable(c, error);
    throw error;
  }
});

/** Where the catalog's providers are, and the key Google wants. */
function catalogOptions(config: ReturnType<typeof getConfig>) {
  return {
    openLibraryUrl: config.openLibraryUrl,
    googleBooksUrl: config.googleBooksUrl,
    googleBooksApiKey: config.googleBooksApiKey,
  };
}

/** What the Books notifications need to send: see src/shelf-notify.ts. */
function notifyConfig(c: Context<ShelfEnv>): NotifyConfig {
  const config = getConfig(c);
  return {
    databaseUrl: config.databaseUrl,
    vapidPublicKey: config.vapidPublicKey,
    vapidPrivateKey: config.vapidPrivateKey,
    vapidSubject: config.vapidSubject,
  };
}

/** Copies new covers into R2 after the response, one after another. */
function scheduleCoverCopies(c: Context<ShelfEnv>, prisma: PrismaClient, itemIds: number[]) {
  if (itemIds.length === 0) return;
  const { r2PublicBaseUrl } = getConfig(c);
  scheduleBackgroundWork(c, copyCovers(prisma, c.env?.BLOG_IMAGES, r2PublicBaseUrl, [...new Set(itemIds)]));
}

// ---------------------------------------------------------------------------
// Entries: adding, the library, one work
// ---------------------------------------------------------------------------

shelfRouter.post("/entries", async (c) => {
  const parsed = addShelfEntryInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const { candidate, intent, startedOn, finishedOn, stoppedAt, today, totalUnits: copyUnits } = parsed.data;
  if ((intent === "finished" || intent === "dnf") && !finishedOn) return badRequest(c, "When did you finish it?");

  const userId = c.get("userId");
  const { prisma } = db(c);

  // A hand-typed work gets an id of its own. Matching it to someone else's
  // hand-typed "same" work by title would be a guess, and a wrong guess merges
  // two people's book clubs.
  const externalId = candidate.source === "manual" ? `manual:${crypto.randomUUID()}` : candidate.externalId;

  let needsCover: number | null = null;
  // Set when this request began a read, so friends who want the book hear.
  let startedItemId: number | null = null;
  const result = await prisma.$transaction(async (tx) => {
    const item = await resolveCandidate(tx, { ...candidate, externalId });
    if (item.coverUrl && !item.coverKey) needsCover = item.id;

    const entry = await tx.shelfEntry.upsert({
      where: { userId_itemId: { userId, itemId: item.id } },
      create: { userId, itemId: item.id, wantedAt: intent === "want" ? new Date() : null },
      update: intent === "want" ? {} : { wantedAt: null },
      select: { id: true, wantedAt: true },
    });

    if (intent === "want") {
      if (!entry.wantedAt) {
        await tx.shelfEntry.update({ where: { id: entry.id }, data: { wantedAt: new Date() } });
      }
      return { entryId: entry.id, runId: null as number | null };
    }

    const active = await tx.shelfRun.findFirst({
      where: { entryId: entry.id, status: "active" },
      select: { id: true },
    });

    if (intent === "start") {
      if (active) return { entryId: entry.id, runId: active.id };
      const run = await tx.shelfRun.create({
        data: {
          entryId: entry.id,
          status: "active",
          startedOn: dateFromDay(startedOn ?? today),
          // The reader's own copy when they gave it at Start; otherwise the
          // catalog's figure, unconfirmed, which the book club allows for.
          totalUnits: copyUnits ?? candidate.totalUnits ?? item.totalUnits,
          unitsConfirmed: copyUnits !== undefined,
        },
        select: { id: true },
      });
      startedItemId = item.id;
      return { entryId: entry.id, runId: run.id };
    }

    // A past read, backfilled: finished, or given up on. It gets the one
    // closing log a finished run always has, dated the day it ended, so the
    // year it was read in counts its pages as well as the book. A DNF's
    // closing log covers only as far as the reader says they got, if they
    // say.
    const totalUnits = copyUnits ?? candidate.totalUnits ?? item.totalUnits;
    const reached =
      intent === "finished"
        ? totalUnits ?? 0
        : Math.max(0, totalUnits ? Math.min(stoppedAt ?? 0, totalUnits) : stoppedAt ?? 0);
    const run = await tx.shelfRun.create({
      data: {
        entryId: entry.id,
        status: intent,
        startedOn: startedOn ? dateFromDay(startedOn) : null,
        finishedOn: dateFromDay(finishedOn!),
        totalUnits,
        unitsConfirmed: copyUnits !== undefined,
        position: reached,
      },
      select: { id: true },
    });
    if (reached > 0) {
      await tx.progressLog.create({
        data: {
          runId: run.id,
          userId,
          loggedOn: dateFromDay(finishedOn!),
          fromPosition: 0,
          toPosition: reached,
          closing: true,
        },
      });
    }
    return { entryId: entry.id, runId: run.id };
  });

  if (needsCover !== null) scheduleCoverCopies(c, prisma, [needsCover]);
  if (startedItemId !== null) {
    scheduleBackgroundWork(c, notifyStartedReading(prisma, notifyConfig(c), { actorId: userId, itemId: startedItemId }));
  }
  return c.json(result);
});

/**
 * Removes the work from the want list. An entry that is only a wish is deleted
 * outright; one with runs keeps them.
 */
shelfRouter.delete("/entries/:id/want", async (c) => {
  const entryId = idParam(c, "id");
  if (!entryId) return notFound(c);
  const userId = c.get("userId");
  const { prisma } = db(c);
  const entry = await prisma.shelfEntry.findUnique({
    where: { id: entryId },
    select: { userId: true, _count: { select: { runs: true } } },
  });
  if (!entry || entry.userId !== userId) return notFound(c);
  if (entry._count.runs === 0) {
    await prisma.shelfEntry.delete({ where: { id: entryId } });
  } else {
    await prisma.shelfEntry.update({ where: { id: entryId }, data: { wantedAt: null } });
  }
  return c.json({ ok: true });
});

shelfRouter.post("/entries/:id/reread", async (c) => {
  const entryId = idParam(c, "id");
  if (!entryId) return notFound(c);
  const parsedBody = startRunInput.safeParse((await readJson(c)) ?? {});
  if (!parsedBody.success) return badRequest(c, "Inputs are incorrect.");
  const today = parsedBody.data.today ?? dayOf(new Date());
  const copyUnits = parsedBody.data.totalUnits;
  const userId = c.get("userId");
  const { prisma } = db(c);
  const entry = await prisma.shelfEntry.findUnique({
    where: { id: entryId },
    select: {
      userId: true,
      itemId: true,
      item: { select: { totalUnits: true } },
      runs: { orderBy: { id: "desc" }, select: { id: true, status: true, totalUnits: true } },
    },
  });
  if (!entry || entry.userId !== userId) return notFound(c);
  const active = entry.runs.find((run) => run.status === "active");
  if (active) return c.json({ runId: active.id });
  const run = await prisma.$transaction(async (tx) => {
    const created = await tx.shelfRun.create({
      data: {
        entryId,
        status: "active",
        startedOn: dateFromDay(today),
        // The reader's copy if they said; otherwise the edition read last
        // time, which is a guess, and so unconfirmed.
        totalUnits: copyUnits ?? entry.runs[0]?.totalUnits ?? entry.item.totalUnits,
        unitsConfirmed: copyUnits !== undefined,
      },
      select: { id: true },
    });
    await tx.shelfEntry.update({ where: { id: entryId }, data: { wantedAt: null } });
    return created;
  });
  scheduleBackgroundWork(c, notifyStartedReading(prisma, notifyConfig(c), { actorId: userId, itemId: entry.itemId }));
  return c.json({ runId: run.id });
});

/**
 * One person's shelf, all of it. A shelf is a few hundred entries at most, so
 * it is fetched whole and the client splits it into reading, want, finished
 * and DNF without a round trip per tab.
 */
shelfRouter.get("/entries", async (c) => {
  const callerId = c.get("userId");
  const { prisma, config } = db(c);
  const rawUserId = c.req.query("userId");
  let userId = callerId;
  if (rawUserId) {
    const requested = Number(rawUserId);
    if (!Number.isInteger(requested) || requested <= 0) return notFound(c);
    if (requested !== callerId) {
      const [callerGroup, theirGroup] = await Promise.all([
        requireGroup(c, prisma),
        getUserGroupId(prisma, requested),
      ]);
      if (callerGroup === null || callerGroup !== theirGroup) return notFound(c);
    }
    userId = requested;
  }

  const [owner, entries] = await Promise.all([
    prisma.user.findUnique({ where: { id: userId }, select: personSelect }),
    prisma.shelfEntry.findMany({
      where: { userId },
      orderBy: { id: "desc" },
      select: {
        id: true,
        wantedAt: true,
        item: { select: itemSelect },
        runs: {
          orderBy: { id: "asc" },
          select: {
            id: true,
            status: true,
            startedOn: true,
            finishedOn: true,
            totalUnits: true,
            position: true,
            unitsConfirmed: true,
            review: { select: { id: true, rating: true, recommend: true, body: true, createdAt: true, editedAt: true } },
          },
        },
      },
    }),
  ]);
  if (!owner) return notFound(c);

  return c.json({
    owner: personView(owner, config.r2PublicBaseUrl),
    entries: entries.map((entry) => ({
      id: entry.id,
      wantedAt: entry.wantedAt ? entry.wantedAt.toISOString() : null,
      item: itemView(entry.item),
      runs: entry.runs.map((run) => ({
        ...runView(run, entry.item.totalUnits),
        review: run.review ? reviewView(run.review) : null,
      })),
    })),
  });
});

/** One work on one person's shelf: every run, its review, and today's logs. */
shelfRouter.get("/entries/:id", async (c) => {
  const entryId = idParam(c, "id");
  if (!entryId) return notFound(c);
  const callerId = c.get("userId");
  const { prisma, config } = db(c);
  const entry = await prisma.shelfEntry.findUnique({
    where: { id: entryId },
    select: {
      id: true,
      userId: true,
      wantedAt: true,
      user: { select: { ...personSelect, groupId: true } },
      item: { select: itemSelect },
      runs: {
        orderBy: { id: "desc" },
        select: {
          id: true,
          status: true,
          startedOn: true,
          finishedOn: true,
          totalUnits: true,
          position: true,
          unitsConfirmed: true,
          review: {
            select: {
              id: true,
              rating: true,
              recommend: true,
              body: true,
              createdAt: true,
              editedAt: true,
              loungePost: { select: { id: true } },
              _count: { select: { comments: true } },
            },
          },
        },
      },
    },
  });
  if (!entry) return notFound(c);
  const isMine = entry.userId === callerId;
  if (!isMine) {
    const groupId = await requireGroup(c, prisma);
    if (groupId === null || groupId !== entry.user.groupId) return notFound(c);
  }

  const activeRun = entry.runs.find((run) => run.status === "active");
  // The most recent logs of the run in progress, so the last one can be
  // undone and a note edited. Only the owner sees them here; everyone else
  // sees notes through the book club, which gates them.
  const recentLogs =
    isMine && activeRun
      ? await prisma.progressLog.findMany({
          where: { runId: activeRun.id },
          orderBy: { id: "desc" },
          take: 10,
          select: { id: true, loggedOn: true, fromPosition: true, toPosition: true, note: true, source: true, createdAt: true },
        })
      : [];

  return c.json({
    id: entry.id,
    isMine,
    wantedAt: entry.wantedAt ? entry.wantedAt.toISOString() : null,
    owner: personView(entry.user, config.r2PublicBaseUrl),
    item: itemView(entry.item),
    runs: entry.runs.map((run, index) => ({
      ...runView(run, entry.item.totalUnits),
      // Runs are listed newest first; the first read is number 1.
      number: entry.runs.length - index,
      review: run.review
        ? {
            ...reviewView(run.review),
            loungePostId: run.review.loungePost?.id ?? null,
            commentCount: run.review._count.comments,
          }
        : null,
    })),
    recentLogs: recentLogs.map((log) => ({
      id: log.id,
      loggedOn: dayOf(log.loggedOn),
      fromPosition: log.fromPosition,
      toPosition: log.toPosition,
      note: log.note,
      source: log.source,
      createdAt: log.createdAt.toISOString(),
    })),
  });
});

// ---------------------------------------------------------------------------
// Home: the one request the main screen makes
// ---------------------------------------------------------------------------

shelfRouter.get("/home", async (c) => {
  const userId = c.get("userId");
  const today = todayFrom(c);
  const { prisma, config } = db(c);
  const groupId = await requireGroup(c, prisma);
  if (groupId === null) return notFound(c);

  const year = Number(today.slice(0, 4));
  const weekStart = addDays(today, -6);

  const [activeRuns, wanted, recentDays, weekLogs, finishedThisYear] = await Promise.all([
    prisma.shelfRun.findMany({
      where: { status: "active", entry: { userId } },
      orderBy: { id: "desc" },
      select: {
        id: true,
        status: true,
        startedOn: true,
        finishedOn: true,
        totalUnits: true,
        position: true,
        unitsConfirmed: true,
        entry: { select: { id: true, item: { select: itemSelect } } },
      },
    }),
    prisma.shelfEntry.findMany({
      where: { userId, wantedAt: { not: null } },
      orderBy: { wantedAt: "desc" },
      take: 20,
      select: { id: true, item: { select: itemSelect } },
    }),
    // A streak needs days, not logs; a year is more than any streak anyone
    // will have to walk back through on a Tuesday.
    prisma.progressLog.findMany({
      where: { userId, closing: false, loggedOn: { gte: dateFromDay(addDays(today, -400)) } },
      distinct: ["loggedOn"],
      select: { loggedOn: true },
    }),
    prisma.progressLog.findMany({
      where: { userId, loggedOn: { gte: dateFromDay(weekStart), lte: dateFromDay(today) } },
      select: { runId: true, loggedOn: true, fromPosition: true, toPosition: true },
    }),
    prisma.shelfRun.count({
      where: {
        status: "finished",
        entry: { userId },
        finishedOn: { gte: dateFromDay(`${year}-01-01`), lte: dateFromDay(`${year}-12-31`) },
      },
    }),
  ]);

  const entryIds = activeRuns.map((run) => run.entry.id);
  const [readerLinks, readerPending] = await Promise.all([
    entryIds.length
      ? prisma.readerDocument.findMany({
          where: { userId, entryId: { in: entryIds }, ignored: false },
          orderBy: { updatedAt: "desc" },
          select: { entryId: true, device: true, updatedAt: true },
        })
      : [],
    pendingDocuments(prisma, userId),
  ]);

  const itemIds = activeRuns.map((run) => run.entry.item.id);
  // What the book-club chip on each card needs: the notes the reader may see,
  // the ones still ahead, and who else is reading it now. Fetched for the
  // works in progress only, which is a handful.
  const [clubNotes, otherReaders, myRunsOfThese] = itemIds.length
    ? await Promise.all([
        prisma.progressLog.findMany({
          where: {
            note: { not: null },
            userId: { not: userId },
            user: { groupId },
            run: { entry: { itemId: { in: itemIds } } },
          },
          select: {
            id: true,
            userId: true,
            toPosition: true,
            run: { select: { totalUnits: true, unitsConfirmed: true, entry: { select: { itemId: true } } } },
          },
        }),
        prisma.shelfRun.findMany({
          where: {
            status: "active",
            entry: { itemId: { in: itemIds }, userId: { not: userId }, user: { groupId } },
          },
          select: { entry: { select: { itemId: true, user: { select: personSelect } } } },
        }),
        // A re-reader has already read the ending, so their reach is every
        // run of the work, not just the one in progress.
        prisma.shelfRun.findMany({
          where: { entry: { userId, itemId: { in: itemIds } } },
          select: { status: true, position: true, totalUnits: true, unitsConfirmed: true, entry: { select: { itemId: true } } },
        }),
      ])
    : [[], [], []];

  const todayByRun = new Map<number, number>();
  let pagesThisWeek = 0;
  for (const log of weekLogs) {
    const moved = log.toPosition - log.fromPosition;
    pagesThisWeek += moved;
    if (dayOf(log.loggedOn) === today) todayByRun.set(log.runId, (todayByRun.get(log.runId) ?? 0) + moved);
  }

  return c.json({
    today,
    reading: activeRuns.map((run) => {
      const item = run.entry.item;
      const reach = readerReach(
        myRunsOfThese.filter((mine) => mine.entry.itemId === item.id),
        item.totalUnits
      );
      const notes = clubNotes
        .filter((note) => note.run.entry.itemId === item.id)
        .map((note) => ({
          id: note.id,
          userId: note.userId,
          toPosition: note.toPosition,
          runTotalUnits: note.run.totalUnits,
          runUnitsConfirmed: note.run.unitsConfirmed,
        }));
      const { visible, aheadCount } = partitionClubNotes(notes, userId, reach, item.totalUnits);
      return {
        entryId: run.entry.id,
        item: itemView(item),
        run: runView(run, item.totalUnits),
        today: todayByRun.get(run.id) ?? 0,
        // The latest KOReader sync of this book, if a file is linked to it.
        reader: (() => {
          const link = readerLinks.find((doc) => doc.entryId === run.entry.id);
          return link ? { device: link.device, syncedAt: link.updatedAt.toISOString() } : null;
        })(),
        club: {
          visibleNotes: visible.length,
          aheadNotes: aheadCount,
          readers: otherReaders
            .filter((reader) => reader.entry.itemId === item.id)
            .map((reader) => personView(reader.entry.user, config.r2PublicBaseUrl)),
        },
      };
    }),
    want: wanted.map((entry) => ({ entryId: entry.id, item: itemView(entry.item) })),
    readerPending,
    highlights: {
      year,
      booksThisYear: finishedThisYear,
      pagesThisWeek,
      streak: currentStreak(recentDays.map((row) => dayOf(row.loggedOn)), today),
    },
  });
});

// ---------------------------------------------------------------------------
// KOReader sync: the login KOReader uses (route/kosync.ts), and which book
// each synced file is. See src/reader-sync.ts.
// ---------------------------------------------------------------------------

/** Where KOReader is pointed: this API's own origin, as the reader's browser reached it. */
function kosyncUrl(c: Context<ShelfEnv>) {
  return `${new URL(c.req.url).origin}/kosync`;
}

shelfRouter.get("/reader", async (c) => {
  const userId = c.get("userId");
  const { prisma } = db(c);
  const [sync, documents] = await Promise.all([
    prisma.readerSync.findUnique({ where: { userId }, select: { username: true, timeZone: true, lastSeenAt: true } }),
    prisma.readerDocument.findMany({
      where: { userId },
      orderBy: { updatedAt: "desc" },
      take: 50,
      select: {
        id: true,
        title: true,
        authors: true,
        percentage: true,
        device: true,
        ignored: true,
        updatedAt: true,
        entry: { select: { id: true, item: { select: itemSelect } } },
      },
    }),
  ]);
  return c.json({
    serverUrl: kosyncUrl(c),
    login: sync
      ? { username: sync.username, timeZone: sync.timeZone, lastSeenAt: sync.lastSeenAt?.toISOString() ?? null }
      : null,
    documents: documents.map((doc) => ({
      id: doc.id,
      title: doc.title,
      authors: doc.authors,
      percentage: doc.percentage,
      device: doc.device,
      ignored: doc.ignored,
      syncedAt: doc.updatedAt.toISOString(),
      entry: doc.entry ? { id: doc.entry.id, item: itemView(doc.entry.item) } : null,
    })),
  });
});

/**
 * Makes the KOReader login, or a new password for it. The password is in this
 * answer and nowhere else: only a hash of the key KOReader derives from it is
 * kept.
 */
shelfRouter.post("/reader/password", async (c) => {
  const parsed = readerSetupInput.safeParse(await readJson(c));
  if (!parsed.success || !validTimeZone(parsed.data.timeZone)) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const password = generatePassword();
  const keyHash = hashReaderKey(readerKeyFor(password));
  const existing = await prisma.readerSync.findUnique({ where: { userId }, select: { username: true } });
  let username = existing?.username;
  if (username) {
    await prisma.readerSync.update({ where: { userId }, data: { keyHash, timeZone: parsed.data.timeZone } });
  } else {
    const user = await prisma.user.findUnique({ where: { id: userId }, select: { name: true } });
    const base = usernameFrom(user?.name);
    const taken = await prisma.readerSync.findUnique({ where: { username: base }, select: { userId: true } });
    username = taken ? `${base}${userId}` : base;
    await prisma.readerSync.create({ data: { userId, username, keyHash, timeZone: parsed.data.timeZone } });
  }
  return c.json({ serverUrl: kosyncUrl(c), username, password });
});

/** Turns sync off. Files stay linked, so setting it up again carries on. */
shelfRouter.delete("/reader", async (c) => {
  const { prisma } = db(c);
  await prisma.readerSync.deleteMany({ where: { userId: c.get("userId") } });
  return c.json({ ok: true });
});

shelfRouter.post("/reader/documents/:id/link", async (c) => {
  const documentId = idParam(c, "id");
  if (!documentId) return notFound(c);
  const parsed = linkReaderDocumentInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const doc = await prisma.readerDocument.findUnique({ where: { id: documentId }, select: { userId: true } });
  if (!doc || doc.userId !== userId) return notFound(c);

  if ("ignore" in parsed.data) {
    await prisma.readerDocument.update({ where: { id: documentId }, data: { ignored: true, entryId: null } });
    return c.json({ ok: true, runId: null });
  }

  const { entryId, totalUnits: copyUnits } = parsed.data;
  const sync = await prisma.readerSync.findUnique({ where: { userId }, select: { timeZone: true } });
  const today = parsed.data.today ?? dayOf(new Date());
  const entry = await prisma.shelfEntry.findUnique({
    where: { id: entryId },
    select: {
      userId: true,
      itemId: true,
      wantedAt: true,
      item: { select: { totalUnits: true } },
      runs: { orderBy: { id: "desc" }, select: { id: true, status: true, totalUnits: true } },
    },
  });
  if (!entry || entry.userId !== userId) return notFound(c);
  let run = entry.runs.find((candidate) => candidate.status === "active");
  // A want-list book: KOReader is reading it, so the reader has started it.
  // Only when the reader says so, here — never from a sync on its own.
  let started = false;
  if (!run) {
    if (!entry.wantedAt) return conflict(c, "That read is over. Start a re-read of it first.");
    run = await prisma.$transaction(async (tx) => {
      const created = await tx.shelfRun.create({
        data: {
          entryId,
          status: "active",
          startedOn: dateFromDay(today),
          totalUnits: copyUnits ?? entry.item.totalUnits,
          unitsConfirmed: copyUnits !== undefined,
        },
        select: { id: true, status: true, totalUnits: true },
      });
      await tx.shelfEntry.update({ where: { id: entryId }, data: { wantedAt: null } });
      return created;
    });
    started = true;
  } else if (copyUnits !== undefined) {
    await prisma.shelfRun.update({ where: { id: run.id }, data: { totalUnits: copyUnits, unitsConfirmed: true } });
  }

  await prisma.readerDocument.update({ where: { id: documentId }, data: { entryId, ignored: false } });
  // Where KOReader already is counts from now: the first link moves the bar.
  await applyDocument(prisma, documentId, parsed.data.today ?? (sync ? dayInZone(new Date(), sync.timeZone) : today));
  if (started) {
    scheduleBackgroundWork(c, notifyStartedReading(prisma, notifyConfig(c), { actorId: userId, itemId: entry.itemId }));
  }
  return c.json({ ok: true, runId: run.id });
});

// ---------------------------------------------------------------------------
// Runs and logs
// ---------------------------------------------------------------------------

/** One of the caller's runs with its work and review: what the review prompt opens on. */
shelfRouter.get("/runs/:id", async (c) => {
  const runId = idParam(c, "id");
  if (!runId) return notFound(c);
  const userId = c.get("userId");
  const { prisma } = db(c);
  const run = await prisma.shelfRun.findUnique({
    where: { id: runId },
    select: {
      id: true,
      status: true,
      startedOn: true,
      finishedOn: true,
      totalUnits: true,
      position: true,
      unitsConfirmed: true,
      entry: { select: { id: true, userId: true, item: { select: itemSelect }, _count: { select: { runs: true } } } },
      review: {
        select: {
          id: true,
          rating: true,
          recommend: true,
          body: true,
          createdAt: true,
          editedAt: true,
          loungePost: { select: { id: true } },
        },
      },
    },
  });
  if (!run || run.entry.userId !== userId) return notFound(c);
  return c.json({
    entryId: run.entry.id,
    item: itemView(run.entry.item),
    run: runView(run, run.entry.item.totalUnits),
    isReread: run.entry._count.runs > 1,
    review: run.review ? { ...reviewView(run.review), loungePostId: run.review.loungePost?.id ?? null } : null,
  });
});

/**
 * How many of other people's book club notes became readable when this
 * reader's run moved forward from `from` to where it is now. The same gate as
 * the club screen, asked twice: once as the reader was, once as they are.
 */
async function notesUnlocked(prisma: PrismaClient, userId: number, itemId: number, runId: number, from: number) {
  const groupId = await getUserGroupId(prisma, userId);
  if (groupId === null) return 0;
  const [item, myRuns, notes] = await Promise.all([
    prisma.catalogItem.findUnique({ where: { id: itemId }, select: { totalUnits: true } }),
    prisma.shelfRun.findMany({
      where: { entry: { itemId, userId } },
      select: { id: true, status: true, position: true, totalUnits: true, unitsConfirmed: true },
    }),
    prisma.progressLog.findMany({
      where: { note: { not: null }, userId: { not: userId }, user: { groupId }, run: { entry: { itemId } } },
      select: { id: true, userId: true, toPosition: true, run: { select: { totalUnits: true, unitsConfirmed: true } } },
    }),
  ]);
  if (!item || notes.length === 0) return 0;
  const gated = notes.map((note) => ({
    id: note.id,
    userId: note.userId,
    toPosition: note.toPosition,
    runTotalUnits: note.run.totalUnits,
    runUnitsConfirmed: note.run.unitsConfirmed,
  }));
  const before = readerReach(myRuns.map((run) => (run.id === runId ? { ...run, position: from } : run)), item.totalUnits);
  const after = readerReach(myRuns, item.totalUnits);
  return (
    partitionClubNotes(gated, userId, after, item.totalUnits).visible.length -
    partitionClubNotes(gated, userId, before, item.totalUnits).visible.length
  );
}

shelfRouter.post("/runs/:id/log", async (c) => {
  const runId = idParam(c, "id");
  if (!runId) return notFound(c);
  const parsed = logProgressInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const run = await ownRun(prisma, runId, userId);
  if (!run) return notFound(c);
  if (run.status !== "active") return conflict(c, "This read is already over. Start a re-read to log more.");

  const totalUnits = run.totalUnits ?? run.entry.item.totalUnits;
  const from = run.position;
  let to = parsed.data.position ?? from + (parsed.data.amount ?? 0);
  if (totalUnits) to = Math.min(to, totalUnits);
  const note = cleanBody(parsed.data.note) ?? null;
  if (to === from && !note) return badRequest(c, "Nothing to log.");

  const log = await prisma.$transaction((tx) =>
    recordProgress(tx, { runId, userId, day: parsed.data.loggedOn, from, to, note })
  );

  if (note) scheduleBackgroundWork(c, notifyBookClubNote(prisma, notifyConfig(c), log.id));
  const unlockedNotes = to > from ? await notesUnlocked(prisma, userId, run.entry.itemId, runId, from) : 0;

  return c.json({
    // Notes in the book club this move made readable. Shown right away by
    // the logging sheet; the reader is in the app, so it is not a push.
    unlockedNotes,
    log: {
      id: log.id,
      loggedOn: dayOf(log.loggedOn),
      fromPosition: log.fromPosition,
      toPosition: log.toPosition,
      note: log.note,
      createdAt: log.createdAt.toISOString(),
    },
    run: runView({ ...run, position: to }, run.entry.item.totalUnits),
    // The client offers to finish the book rather than finishing it: someone
    // who logs the last page may still have an epilogue to go.
    reachedEnd: Boolean(totalUnits && to >= totalUnits),
  });
});

async function ownLog(prisma: PrismaClient, logId: number, userId: number) {
  const log = await prisma.progressLog.findUnique({
    where: { id: logId },
    select: {
      id: true,
      userId: true,
      runId: true,
      fromPosition: true,
      toPosition: true,
      run: { select: { status: true, totalUnits: true, entry: { select: { item: { select: { totalUnits: true } } } } } },
    },
  });
  if (!log || log.userId !== userId) return null;
  const latest = await prisma.progressLog.findFirst({
    where: { runId: log.runId },
    orderBy: { id: "desc" },
    select: { id: true },
  });
  return { ...log, isLatest: latest?.id === log.id };
}

/**
 * A note can be edited on any log. A position only on the latest log of a
 * run in progress: each log starts where the one before it ended, and moving
 * one in the middle would leave the chain disagreeing with itself.
 */
shelfRouter.put("/logs/:id", async (c) => {
  const logId = idParam(c, "id");
  if (!logId) return notFound(c);
  const parsed = updateProgressLogInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const log = await ownLog(prisma, logId, userId);
  if (!log) return notFound(c);

  const data: Prisma.ProgressLogUpdateInput = {};
  if (parsed.data.note !== undefined) data.note = cleanBody(parsed.data.note) ?? null;
  let newPosition: number | null = null;
  if (parsed.data.toPosition !== undefined && parsed.data.toPosition !== log.toPosition) {
    if (!log.isLatest || log.run.status !== "active") {
      return conflict(c, "Only the latest entry of a book in progress can change its page.");
    }
    const total = log.run.totalUnits ?? log.run.entry.item.totalUnits;
    newPosition = total ? Math.min(parsed.data.toPosition, total) : parsed.data.toPosition;
    data.toPosition = newPosition;
  }

  await prisma.$transaction(async (tx) => {
    await tx.progressLog.update({ where: { id: logId }, data });
    if (newPosition !== null) await tx.shelfRun.update({ where: { id: log.runId }, data: { position: newPosition } });
  });
  return c.json({ ok: true });
});

/** Undo. Only the latest log of a run in progress, for the same reason as above. */
shelfRouter.delete("/logs/:id", async (c) => {
  const logId = idParam(c, "id");
  if (!logId) return notFound(c);
  const userId = c.get("userId");
  const { prisma } = db(c);
  const log = await ownLog(prisma, logId, userId);
  if (!log) return notFound(c);
  if (!log.isLatest || log.run.status !== "active") {
    return conflict(c, "Only the latest entry of a book in progress can be removed.");
  }
  await prisma.$transaction(async (tx) => {
    await tx.progressLog.delete({ where: { id: logId } });
    await tx.shelfRun.update({ where: { id: log.runId }, data: { position: log.fromPosition } });
  });
  return c.json({ ok: true, position: log.fromPosition });
});

shelfRouter.post("/runs/:id/finish", async (c) => {
  const runId = idParam(c, "id");
  if (!runId) return notFound(c);
  const parsed = finishRunInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const run = await ownRun(prisma, runId, userId);
  if (!run) return notFound(c);
  if (run.status !== "active") return conflict(c, "This read is already over.");

  const totalUnits = run.totalUnits ?? run.entry.item.totalUnits;
  const finishing = parsed.data.status === "finished";
  // Finishing writes the closing log: whatever was not logged page by page is
  // read on the day it was finished. Without it a book read in one sitting and
  // never logged would count as a book but not as pages. A DNF stops where it
  // stopped.
  const closingFrom = run.position;
  const closes = finishing && totalUnits !== null && closingFrom < totalUnits;

  const updated = await prisma.$transaction(async (tx) => {
    if (closes) {
      await tx.progressLog.create({
        data: {
          runId,
          userId,
          loggedOn: dateFromDay(parsed.data.finishedOn),
          fromPosition: closingFrom,
          toPosition: totalUnits!,
          closing: true,
        },
      });
    }
    return tx.shelfRun.update({
      where: { id: runId },
      data: {
        status: parsed.data.status,
        finishedOn: dateFromDay(parsed.data.finishedOn),
        totalUnits,
        ...(closes ? { position: totalUnits! } : {}),
      },
    });
  });
  // Only a finish, not a DNF: "Ben gave up on Circe" is not news anyone needs
  // halfway through it.
  if (finishing) {
    scheduleBackgroundWork(c, notifyFinishedReading(prisma, notifyConfig(c), { actorId: userId, itemId: run.entry.itemId }));
  }
  return c.json({ run: runView(updated, run.entry.item.totalUnits) });
});

/**
 * Corrections to a run: the edition's page count, or its dates. On a finished
 * run the closing log moves with them, so the year and the page total stay
 * consistent with what the run says.
 */
shelfRouter.put("/runs/:id", async (c) => {
  const runId = idParam(c, "id");
  if (!runId) return notFound(c);
  const parsed = updateRunInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const run = await ownRun(prisma, runId, userId);
  if (!run) return notFound(c);

  const data: Prisma.ShelfRunUpdateInput = {};
  if (parsed.data.startedOn !== undefined) {
    data.startedOn = parsed.data.startedOn ? dateFromDay(parsed.data.startedOn) : null;
  }
  if (parsed.data.finishedOn !== undefined) {
    if (run.status === "active") return conflict(c, "This read is not finished.");
    data.finishedOn = dateFromDay(parsed.data.finishedOn);
  }
  if (parsed.data.totalUnits !== undefined) {
    data.totalUnits = parsed.data.totalUnits;
    // Setting a length, even to the one already there, is the reader saying
    // it is their copy's.
    data.unitsConfirmed = true;
    if (run.status === "finished") data.position = parsed.data.totalUnits;
    else if (run.position > parsed.data.totalUnits) data.position = parsed.data.totalUnits;
  }

  const updated = await prisma.$transaction(async (tx) => {
    if (run.status === "finished") {
      const closing = await tx.progressLog.findFirst({
        where: { runId },
        orderBy: { id: "desc" },
        select: { id: true, loggedOn: true },
      });
      const closingData: Prisma.ProgressLogUpdateInput = {};
      if (closing && parsed.data.totalUnits !== undefined) closingData.toPosition = parsed.data.totalUnits;
      if (closing && parsed.data.finishedOn !== undefined && run.finishedOn && dayOf(closing.loggedOn) === dayOf(run.finishedOn)) {
        closingData.loggedOn = dateFromDay(parsed.data.finishedOn);
      }
      if (closing && Object.keys(closingData).length > 0) {
        await tx.progressLog.update({ where: { id: closing.id }, data: closingData });
      } else if (!closing && parsed.data.totalUnits !== undefined) {
        // A backfilled read whose length was unknown when it was added gets
        // its closing log now that the length is known.
        await tx.progressLog.create({
          data: {
            runId,
            userId,
            loggedOn: (data.finishedOn as Date | undefined) ?? run.finishedOn ?? new Date(),
            fromPosition: 0,
            toPosition: parsed.data.totalUnits,
            closing: true,
          },
        });
      }
    }
    return tx.shelfRun.update({ where: { id: runId }, data });
  });
  return c.json({ run: runView(updated, run.entry.item.totalUnits) });
});

/**
 * Deletes a run added by mistake, with its logs and review. A Lounge post made
 * from that review goes too: it would otherwise survive as a card pointing at
 * nothing. An entry left with no runs and no wish is removed.
 */
shelfRouter.delete("/runs/:id", async (c) => {
  const runId = idParam(c, "id");
  if (!runId) return notFound(c);
  const userId = c.get("userId");
  const { prisma } = db(c);
  const run = await ownRun(prisma, runId, userId);
  if (!run) return notFound(c);
  await prisma.$transaction(async (tx) => {
    await tx.post.deleteMany({ where: { shelfReview: { runId } } });
    await tx.shelfRun.delete({ where: { id: runId } });
    const entry = await tx.shelfEntry.findUnique({
      where: { id: run.entryId },
      select: { wantedAt: true, _count: { select: { runs: true } } },
    });
    if (entry && entry._count.runs === 0 && !entry.wantedAt) {
      await tx.shelfEntry.delete({ where: { id: run.entryId } });
    }
  });
  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// Reviews
// ---------------------------------------------------------------------------

shelfRouter.put("/runs/:id/review", async (c) => {
  const runId = idParam(c, "id");
  if (!runId) return notFound(c);
  const parsed = upsertReviewInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Inputs are incorrect.");
  const userId = c.get("userId");
  const { prisma } = db(c);
  const run = await ownRun(prisma, runId, userId);
  if (!run) return notFound(c);

  const fields: Prisma.ShelfReviewUpdateInput = {};
  if (parsed.data.rating !== undefined) fields.rating = parsed.data.rating;
  if (parsed.data.recommend !== undefined) fields.recommend = parsed.data.recommend;
  if (parsed.data.body !== undefined) fields.body = cleanBody(parsed.data.body);

  const existing = await prisma.shelfReview.findUnique({ where: { runId }, select: { id: true } });
  const review = existing
    ? await prisma.shelfReview.update({ where: { runId }, data: { ...fields, editedAt: new Date() } })
    : await prisma.shelfReview.create({
        data: {
          runId,
          rating: parsed.data.rating ?? null,
          recommend: parsed.data.recommend ?? null,
          body: cleanBody(parsed.data.body) ?? null,
        },
      });
  return c.json({ review: reviewView(review) });
});

function ratingText(rating: number | null) {
  if (rating === null) return null;
  const stars = "★".repeat(Math.floor(rating / 2)) + (rating % 2 ? "½" : "");
  return stars;
}

/**
 * Cross-posts a review to the Lounge. The post's title and content are only a
 * fallback: the feed card is drawn from the review itself through
 * `shelfReviewId`, so later edits to the review show on the Lounge too.
 */
shelfRouter.post("/reviews/:id/lounge", async (c) => {
  const reviewId = idParam(c, "id");
  if (!reviewId) return notFound(c);
  const userId = c.get("userId");
  const { prisma, config } = db(c);
  const review = await prisma.shelfReview.findUnique({
    where: { id: reviewId },
    select: {
      id: true,
      rating: true,
      recommend: true,
      body: true,
      loungePost: { select: { id: true } },
      run: {
        select: {
          status: true,
          entry: {
            select: {
              userId: true,
              user: { select: { name: true } },
              item: { select: { title: true, creators: true } },
            },
          },
        },
      },
    },
  });
  if (!review || review.run.entry.userId !== userId) return notFound(c);
  if (review.loungePost) return c.json({ postId: review.loungePost.id });
  if (review.rating === null && review.recommend === null && !review.body) {
    return badRequest(c, "Add a rating, a recommendation or a few words first.");
  }

  const { item } = review.run.entry;
  const verb = review.run.status === "dnf" ? "Did not finish" : "Read";
  const byline = item.creators.length ? ` by ${item.creators.join(", ")}` : "";
  const title = `${verb}: ${item.title}${byline}`.slice(0, 300);
  const summary = [
    ratingText(review.rating),
    review.recommend === true ? "Recommends it" : review.recommend === false ? "Does not recommend it" : null,
  ]
    .filter(Boolean)
    .join(" · ");
  const content = [summary, review.body].filter(Boolean).join("\n\n") || title;

  const post = await prisma.post.create({
    data: { title, content, authorId: userId, published: true, shelfReviewId: review.id },
    select: { id: true },
  });

  scheduleBackgroundWork(
    c,
    notifyFollowersOfNewPost({
      databaseUrl: config.databaseUrl,
      authorId: userId,
      authorName: review.run.entry.user.name?.trim() || "Someone",
      postId: post.id,
      postTitle: title,
      vapidConfig: {
        vapidPublicKey: config.vapidPublicKey,
        vapidPrivateKey: config.vapidPrivateKey,
        vapidSubject: config.vapidSubject,
      },
    })
  );

  return c.json({ postId: post.id });
});

const feedReviewSelect = {
  id: true,
  rating: true,
  recommend: true,
  body: true,
  createdAt: true,
  editedAt: true,
  loungePost: { select: { id: true } },
  _count: { select: { comments: true } },
  run: {
    select: {
      id: true,
      status: true,
      startedOn: true,
      finishedOn: true,
      totalUnits: true,
      position: true,
      unitsConfirmed: true,
      entry: {
        select: {
          id: true,
          user: { select: personSelect },
          item: { select: itemSelect },
          runs: { where: { status: { in: ["finished", "dnf"] } }, select: { id: true } },
        },
      },
    },
  },
} satisfies Prisma.ShelfReviewSelect;

type FeedReviewRow = Prisma.ShelfReviewGetPayload<{ select: typeof feedReviewSelect }>;

function feedReviewView(review: FeedReviewRow, r2: string | undefined) {
  const { run } = review;
  const finishedRunIds = run.entry.runs.map((other) => other.id).sort((a, b) => a - b);
  return {
    ...reviewView(review),
    commentCount: review._count.comments,
    loungePostId: review.loungePost?.id ?? null,
    entryId: run.entry.id,
    reviewer: personView(run.entry.user, r2),
    item: itemView(run.entry.item),
    run: runView(run, run.entry.item.totalUnits),
    // 1 for a first read, 2 for the first re-read, and so on.
    readNumber: Math.max(1, finishedRunIds.indexOf(run.id) + 1),
  };
}

shelfRouter.get("/reviews", async (c) => {
  const callerId = c.get("userId");
  const { prisma, config } = db(c);
  const groupId = await requireGroup(c, prisma);
  if (groupId === null) return notFound(c);

  const scope = c.req.query("scope") ?? "everyone";
  const rawLimit = Number(c.req.query("limit") ?? 15);
  const limit = Number.isFinite(rawLimit) ? Math.max(1, Math.min(30, rawLimit)) : 15;
  const rawCursor = Number(c.req.query("cursor"));
  const cursor = Number.isInteger(rawCursor) && rawCursor > 0 ? rawCursor : undefined;
  const rawItemId = Number(c.req.query("itemId"));
  const itemId = Number.isInteger(rawItemId) && rawItemId > 0 ? rawItemId : undefined;

  let ownerId: number | undefined;
  if (scope === "mine") ownerId = callerId;
  else if (scope === "user") {
    const requested = Number(c.req.query("userId"));
    if (!Number.isInteger(requested) || requested <= 0) return notFound(c);
    ownerId = requested;
  }

  const rows = await prisma.shelfReview.findMany({
    where: {
      ...reviewHasContent,
      // Imported reviews are years of them arriving at once; the feed is for
      // what people are reading now. A book's own page still lists them.
      ...(itemId === undefined ? { imported: false } : {}),
      ...(cursor ? { id: { lt: cursor } } : {}),
      run: {
        entry: {
          user: { groupId },
          ...(ownerId !== undefined ? { userId: ownerId } : {}),
          ...(itemId !== undefined ? { itemId } : {}),
        },
      },
    },
    orderBy: { id: "desc" },
    take: limit + 1,
    select: feedReviewSelect,
  });

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  return c.json({
    reviews: page.map((review) => feedReviewView(review, config.r2PublicBaseUrl)),
    nextCursor: hasMore ? page[page.length - 1]?.id ?? null : null,
  });
});

shelfRouter.get("/reviews/:id", async (c) => {
  const reviewId = idParam(c, "id");
  if (!reviewId) return notFound(c);
  const callerId = c.get("userId");
  const { prisma, config } = db(c);
  const groupId = await requireGroup(c, prisma);
  if (groupId === null) return notFound(c);

  const review = await prisma.shelfReview.findFirst({
    where: { id: reviewId, run: { entry: { user: { groupId } } } },
    select: {
      ...feedReviewSelect,
      comments: {
        orderBy: { id: "asc" },
        select: { id: true, content: true, createdAt: true, editedAt: true, author: { select: personSelect } },
      },
    },
  });
  if (!review) return notFound(c);

  return c.json({
    review: {
      ...feedReviewView(review, config.r2PublicBaseUrl),
      isMine: review.run.entry.user.id === callerId,
      comments: review.comments.map((comment) => ({
        id: comment.id,
        content: comment.content,
        createdAt: comment.createdAt.toISOString(),
        editedAt: comment.editedAt ? comment.editedAt.toISOString() : null,
        author: personView(comment.author, config.r2PublicBaseUrl),
      })),
    },
  });
});

shelfRouter.post("/reviews/:id/comments", async (c) => {
  const reviewId = idParam(c, "id");
  if (!reviewId) return notFound(c);
  const parsed = reviewCommentInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Write something first.");
  const userId = c.get("userId");
  const { prisma, config } = db(c);
  const groupId = await requireGroup(c, prisma);
  if (groupId === null) return notFound(c);

  const review = await prisma.shelfReview.findFirst({
    where: { id: reviewId, run: { entry: { user: { groupId } } } },
    select: {
      run: { select: { entry: { select: { userId: true, item: { select: { title: true } } } } } },
      comments: { select: { authorId: true } },
    },
  });
  if (!review) return notFound(c);

  const comment = await prisma.shelfReviewComment.create({
    data: { reviewId, authorId: userId, content: parsed.data.content },
    select: { id: true, content: true, createdAt: true, editedAt: true, author: { select: personSelect } },
  });

  // The reviewer and everyone already in the discussion, minus the person
  // writing, who want to hear about it (notifyBookDiscussion) and are not on
  // either side of a block with the writer. Web Push only — no apnsConfig —
  // because the iOS app has no books and an iPhone banner would open an app
  // that cannot show this.
  const candidates = [
    ...new Set([review.run.entry.userId, ...review.comments.map((other) => other.authorId)]),
  ].filter((id) => id !== userId);
  const [willing, blocked] = candidates.length
    ? await Promise.all([
        prisma.user.findMany({ where: { id: { in: candidates }, notifyBookDiscussion: true }, select: { id: true } }),
        blockedUserIds(prisma, userId),
      ])
    : [[], new Set<number>()];
  const recipients = willing.map((user) => user.id).filter((id) => !blocked.has(id));
  if (recipients.length > 0) {
    const name = comment.author.name?.trim() || "Someone";
    scheduleBackgroundWork(
      c,
      sendPushToUsers({
        databaseUrl: config.databaseUrl,
        userIds: recipients,
        payload: {
          title: `${name} replied about ${review.run.entry.item.title}`,
          body: parsed.data.content.slice(0, 140),
          data: { openUrl: `/books/review/${reviewId}` },
        },
        topic: `shelf-review-${reviewId}`,
        vapidConfig: {
          vapidPublicKey: config.vapidPublicKey,
          vapidPrivateKey: config.vapidPrivateKey,
          vapidSubject: config.vapidSubject,
        },
      })
    );
  }

  return c.json({
    comment: {
      id: comment.id,
      content: comment.content,
      createdAt: comment.createdAt.toISOString(),
      editedAt: null,
      author: personView(comment.author, config.r2PublicBaseUrl),
    },
  });
});

shelfRouter.put("/reviews/:id/comments/:commentId", async (c) => {
  const commentId = idParam(c, "commentId");
  if (!commentId) return notFound(c);
  const parsed = reviewCommentInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "Write something first.");
  const { prisma } = db(c);
  const comment = await prisma.shelfReviewComment.findUnique({
    where: { id: commentId },
    select: { authorId: true, reviewId: true },
  });
  if (!comment || comment.reviewId !== idParam(c, "id") || comment.authorId !== c.get("userId")) return notFound(c);
  await prisma.shelfReviewComment.update({
    where: { id: commentId },
    data: { content: parsed.data.content, editedAt: new Date() },
  });
  return c.json({ ok: true });
});

/** The writer can delete a comment, and so can the reviewer whose page it is on. */
shelfRouter.delete("/reviews/:id/comments/:commentId", async (c) => {
  const commentId = idParam(c, "commentId");
  if (!commentId) return notFound(c);
  const userId = c.get("userId");
  const { prisma } = db(c);
  const comment = await prisma.shelfReviewComment.findUnique({
    where: { id: commentId },
    select: {
      authorId: true,
      reviewId: true,
      review: { select: { run: { select: { entry: { select: { userId: true } } } } } },
    },
  });
  if (!comment || comment.reviewId !== idParam(c, "id")) return notFound(c);
  if (comment.authorId !== userId && comment.review.run.entry.userId !== userId) return notFound(c);
  await prisma.shelfReviewComment.delete({ where: { id: commentId } });
  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// Finding a hand-made book in the catalog
// ---------------------------------------------------------------------------

type Tx = Prisma.TransactionClient;

/**
 * Moves one shelf entry from a hand-made item onto the catalog's work. If the
 * person already has that work on their shelf, the two entries become one:
 * the reads move across, and the empty entry goes.
 */
async function moveEntry(
  tx: Tx,
  entry: { id: number; userId: number; wantedAt: Date | null; importId: string | null },
  targetItemId: number
) {
  const existing = await tx.shelfEntry.findUnique({
    where: { userId_itemId: { userId: entry.userId, itemId: targetItemId } },
    select: { id: true, wantedAt: true, importId: true },
  });
  if (!existing) {
    await tx.shelfEntry.update({ where: { id: entry.id }, data: { itemId: targetItemId } });
    return entry.id;
  }

  const runs = await tx.shelfRun.findMany({ where: { entryId: entry.id }, select: { id: true, importId: true } });
  for (const run of runs) {
    // Two runs from the same import row cannot share an entry; the one
    // moving across gives up its import id, which only ever served to find it.
    const clash = run.importId
      ? await tx.shelfRun.findUnique({ where: { entryId_importId: { entryId: existing.id, importId: run.importId } } })
      : null;
    await tx.shelfRun.update({ where: { id: run.id }, data: { entryId: existing.id, ...(clash ? { importId: null } : {}) } });
  }
  const hasRuns = (await tx.shelfRun.count({ where: { entryId: existing.id } })) > 0;
  // Delete first: the import id is unique per person, and it is moving.
  await tx.shelfEntry.delete({ where: { id: entry.id } });
  await tx.shelfEntry.update({
    where: { id: existing.id },
    data: {
      wantedAt: hasRuns ? existing.wantedAt : existing.wantedAt ?? entry.wantedAt,
      importId: existing.importId ?? entry.importId,
    },
  });
  return existing.id;
}

/**
 * Looks a hand-made book up in the catalog again: our own first, then Open
 * Library. Found, the book moves onto the catalog's work — for everyone who has
 * this hand-made item, because it is the same book, and two people holding two
 * copies of it never meet in its book club. That is the repair for books an
 * import added from its own details, and for books typed in by hand that the
 * catalog has after all.
 */
shelfRouter.post("/entries/:id/rematch", async (c) => {
  const entryId = idParam(c, "id");
  if (!entryId) return notFound(c);
  const userId = c.get("userId");
  const { prisma, config } = db(c);
  const entry = await prisma.shelfEntry.findUnique({
    where: { id: entryId },
    select: {
      userId: true,
      item: { select: { id: true, source: true, title: true, creators: true, isbns: true, totalUnits: true, year: true, coverKey: true } },
    },
  });
  if (!entry || entry.userId !== userId) return notFound(c);
  const manual = entry.item;
  if (manual.source !== "manual") return conflict(c, "This book is already in the catalog.");

  const book = {
    title: manual.title,
    creators: manual.creators,
    isbn13: manual.isbns.find((isbn) => isbn.length === 13) ?? null,
    isbn10: manual.isbns.find((isbn) => isbn.length === 10) ?? null,
    totalUnits: manual.totalUnits,
    year: manual.year,
  };

  let targetItemId: number | null = (await findKnownBook(prisma, book))?.itemId ?? null;
  let candidate: CatalogCandidate | null = null;
  if (targetItemId === null) {
    try {
      candidate = (await findBook(book, catalogOptions(config)))?.candidate ?? null;
    } catch (error) {
      if (error instanceof CatalogUnavailable) return catalogUnavailable(c, error);
      throw error;
    }
    if (!candidate) {
      c.status(404);
      return c.json({ msg: "Still not in the catalog. It stays as you entered it." });
    }
  }

  let needsCover: number | null = null;
  let deletedCoverKey: string | null = null;
  const movedTo = await prisma.$transaction(async (tx) => {
    if (targetItemId === null) {
      const item = await resolveCandidate(tx, candidate!, book);
      if (item.coverUrl && !item.coverKey) needsCover = item.id;
      targetItemId = item.id;
    } else {
      await rememberIsbns(tx, targetItemId, book);
    }
    const holders = await tx.shelfEntry.findMany({
      where: { itemId: manual.id },
      select: { id: true, userId: true, wantedAt: true, importId: true },
    });
    let mine = entryId;
    for (const holder of holders) {
      const moved = await moveEntry(tx, holder, targetItemId);
      if (holder.id === entryId) mine = moved;
    }
    await tx.catalogItem.delete({ where: { id: manual.id } });
    deletedCoverKey = manual.coverKey;
    return mine;
  });

  await deleteCover(c.env?.BLOG_IMAGES, deletedCoverKey);
  if (needsCover !== null) scheduleCoverCopies(c, prisma, [needsCover]);
  return c.json({ entryId: movedTo });
});

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

type RowContext = {
  prisma: PrismaClient;
  userId: number;
  source: string;
  today: string;
  options: ReturnType<typeof catalogOptions>;
  /** Which sources have refused during this batch; see `SourceState`. */
  sources: SourceState;
  /** Set when a row had to be handed back; its wait goes to the client. */
  retryAfterSeconds: number | null;
  /** New catalog items whose covers still need copying into R2. */
  covers: number[];
};

/**
 * Writes one imported row through the same rules as adding by hand: a read
 * gets its closing log on its finish day, a want sets the wish, and nothing is
 * written twice. The book is found, cheapest first:
 *
 * 1. by the row's id, if an earlier import brought it in — never matched again,
 *    because Open Library does not answer the same way twice;
 * 2. in our own catalog, by an ISBN an earlier import attached, or by title and
 *    author;
 * 3. on Open Library, paced to about one request a second;
 * 4. from the row's own details — but only when Open Library answered and has
 *    no such book. If it refused, the row is handed back as "retry" and
 *    nothing is written.
 */
async function importRow(context: RowContext, row: ImportRowInput): Promise<ImportRowResult> {
  const { prisma, userId, source, today } = context;
  const base = { ref: row.ref, title: row.title };
  const importId = `${source}:${row.ref}`;

  const known = await prisma.shelfEntry.findUnique({
    where: { userId_importId: { userId, importId } },
    select: { id: true },
  });

  let match: ImportRowResult["match"] = null;
  let candidate: CatalogCandidate | null = null;
  let knownItemId: number | null = null;
  if (!known) {
    const inCatalog = await findKnownBook(prisma, row);
    if (inCatalog) {
      knownItemId = inCatalog.itemId;
      match = inCatalog.match;
    } else {
      try {
        const found = await findBook(row, context.options, context.sources);
        candidate = found?.candidate ?? manualCandidate(row, source);
        match = found?.match ?? "manual";
      } catch (error) {
        if (error instanceof CatalogUnavailable) {
          context.retryAfterSeconds = Math.max(context.retryAfterSeconds ?? 0, error.retryAfterSeconds);
          return { ...base, outcome: "retry", match: null, entryId: null };
        }
        console.warn("[import] match failed", row.ref, error instanceof Error ? error.message : error);
        return { ...base, outcome: "failed", match: null, entryId: null };
      }
    }
  }

  try {
    return await prisma.$transaction(async (tx) => {
      let entry: { id: number; wantedAt: Date | null };
      let itemTotalUnits: number | null;
      if (known) {
        const current = await tx.shelfEntry.findUniqueOrThrow({
          where: { id: known.id },
          select: { id: true, wantedAt: true, item: { select: { totalUnits: true } } },
        });
        entry = current;
        itemTotalUnits = current.item.totalUnits;
      } else {
        let itemId: number;
        if (knownItemId !== null) {
          await rememberIsbns(tx, knownItemId, row);
          const item = await tx.catalogItem.findUniqueOrThrow({ where: { id: knownItemId }, select: { totalUnits: true } });
          itemId = knownItemId;
          itemTotalUnits = item.totalUnits;
        } else {
          // A manual item keeps the row's ISBNs too, so a rematch later can
          // look it up by them.
          const item = await resolveCandidate(tx, candidate!, row);
          if (item.coverUrl && !item.coverKey) context.covers.push(item.id);
          itemId = item.id;
          itemTotalUnits = item.totalUnits;
        }
        const upserted = await tx.shelfEntry.upsert({
          where: { userId_itemId: { userId, itemId } },
          create: { userId, itemId, importId },
          update: {},
          select: { id: true, wantedAt: true, importId: true },
        });
        // A book already on the shelf, added by hand, takes the import's id
        // so the next import recognises it. One that already carries another
        // row's id (two editions of one work in the export) keeps it.
        if (!upserted.importId) await tx.shelfEntry.update({ where: { id: upserted.id }, data: { importId } });
        entry = upserted;
      }
      const done = (outcome: ImportRowResult["outcome"]): ImportRowResult => ({ ...base, outcome, match, entryId: entry.id });
      const totalUnits = row.totalUnits ?? itemTotalUnits;

      if (row.status === "want") {
        if (entry.wantedAt) return done("skipped");
        const runs = await tx.shelfRun.count({ where: { entryId: entry.id } });
        if (runs > 0) return done("skipped");
        await tx.shelfEntry.update({
          where: { id: entry.id },
          data: { wantedAt: row.addedOn ? dateFromDay(row.addedOn) : new Date() },
        });
        return done("added");
      }

      // Anything but a wish takes it off the want list, as starting does.
      if (entry.wantedAt) await tx.shelfEntry.update({ where: { id: entry.id }, data: { wantedAt: null } });

      const previous = await tx.shelfRun.findUnique({
        where: { entryId_importId: { entryId: entry.id, importId } },
        select: { id: true, status: true, position: true },
      });

      if (row.status === "reading") {
        if (previous) return done("skipped");
        const active = await tx.shelfRun.findFirst({ where: { entryId: entry.id, status: "active" }, select: { id: true } });
        if (active) return done("skipped");
        await tx.shelfRun.create({
          data: {
            entryId: entry.id,
            status: "active",
            startedOn: row.addedOn ? dateFromDay(row.addedOn) : null,
            totalUnits,
            // An export's page count is the reader's own edition's.
            unitsConfirmed: row.totalUnits !== null,
            importId,
          },
        });
        return done("added");
      }

      if (previous && previous.status !== "active") return done("skipped");

      // Read once, on the one date the export has. A finish date missing from
      // the export falls back to when the book was added, then to today.
      const finishedOn = dateFromDay(row.finishedOn ?? row.addedOn ?? today);
      const finishing = row.status === "finished";
      const from = previous?.position ?? 0;
      const reached = finishing ? totalUnits ?? from : from;

      const run = previous
        ? await tx.shelfRun.update({
            where: { id: previous.id },
            data: { status: row.status, finishedOn, totalUnits, unitsConfirmed: row.totalUnits !== null, position: reached },
            select: { id: true },
          })
        : await tx.shelfRun.create({
            data: {
              entryId: entry.id,
              status: row.status,
              finishedOn,
              totalUnits,
              unitsConfirmed: row.totalUnits !== null,
              position: reached,
              importId,
            },
            select: { id: true },
          });

      if (reached > from) {
        await tx.progressLog.create({
          data: { runId: run.id, userId, loggedOn: finishedOn, fromPosition: from, toPosition: reached, closing: true },
        });
      }

      const body = cleanBody(row.review) ?? null;
      if (row.rating !== null || body) {
        await tx.shelfReview.upsert({
          where: { runId: run.id },
          create: { runId: run.id, rating: row.rating, body, imported: true },
          update: {},
        });
      }
      return done("added");
    });
  } catch (error) {
    console.warn("[import] write failed", row.ref, error instanceof Error ? error.message : error);
    return { ...base, outcome: "failed", match, entryId: null };
  }
}

/**
 * One batch of an import. The client reads the export file itself and sends
 * it here a batch at a time, one batch after another; rows are worked through
 * in order, not in parallel, so Open Library sees about one request a second.
 *
 * When Open Library refuses, the rest of the batch is not sent to it: those
 * rows come back as "retry", with `retryAfterSeconds`, and the client waits
 * and sends them again. Rows that need no lookup — already imported, or
 * already in the catalog — are still written meanwhile.
 */
shelfRouter.post("/import", async (c) => {
  const parsed = importBatchInput.safeParse(await readJson(c));
  if (!parsed.success) return badRequest(c, "That file has rows this import can't read.");
  const { prisma, config } = db(c);
  const context: RowContext = {
    prisma,
    userId: c.get("userId"),
    source: parsed.data.source,
    today: parsed.data.today,
    options: catalogOptions(config),
    sources: freshSourceState(),
    retryAfterSeconds: null,
    covers: [],
  };

  const results: ImportRowResult[] = [];
  for (const row of parsed.data.rows) results.push(await importRow(context, row));

  scheduleCoverCopies(c, prisma, context.covers);
  return c.json({
    results,
    retryAfterSeconds: context.retryAfterSeconds,
  });
});

// ---------------------------------------------------------------------------
// The book club
// ---------------------------------------------------------------------------

/**
 * Every note left on this work by anyone in the group, as far as the caller
 * has read and no further. Fetched only when the club is opened. The notes are
 * ordered by where in the book they were written, which is the order a reader
 * meets them in.
 */
shelfRouter.get("/items/:id/club", async (c) => {
  const itemId = idParam(c, "id");
  if (!itemId) return notFound(c);
  const userId = c.get("userId");
  const { prisma, config } = db(c);
  const groupId = await requireGroup(c, prisma);
  if (groupId === null) return notFound(c);

  const [item, myRuns, notes, readers] = await Promise.all([
    prisma.catalogItem.findUnique({ where: { id: itemId }, select: itemSelect }),
    prisma.shelfRun.findMany({
      where: { entry: { itemId, userId } },
      select: { id: true, status: true, position: true, totalUnits: true, unitsConfirmed: true },
    }),
    prisma.progressLog.findMany({
      where: { note: { not: null }, user: { groupId }, run: { entry: { itemId } } },
      select: {
        id: true,
        userId: true,
        toPosition: true,
        note: true,
        loggedOn: true,
        createdAt: true,
        user: { select: personSelect },
        run: { select: { totalUnits: true, unitsConfirmed: true } },
      },
    }),
    prisma.shelfRun.findMany({
      where: { entry: { itemId, user: { groupId } }, status: { in: ["active", "finished"] } },
      select: {
        status: true,
        position: true,
        unitsConfirmed: true,
        totalUnits: true,
        entry: { select: { user: { select: personSelect } } },
      },
    }),
  ]);
  if (!item) return notFound(c);

  const reach = readerReach(myRuns, item.totalUnits);
  const { visible, aheadCount } = partitionClubNotes(
    notes.map((note) => ({ ...note, runTotalUnits: note.run.totalUnits, runUnitsConfirmed: note.run.unitsConfirmed })),
    userId,
    reach,
    item.totalUnits
  );
  visible.sort((a, b) => (a.fraction ?? 1) - (b.fraction ?? 1) || a.createdAt.getTime() - b.createdAt.getTime());

  // Who else is in the club: each person once, at their furthest point. How
  // far someone has got is not a spoiler; what they said about it is.
  const people = new Map<number, { person: PersonRow; fraction: number; finished: boolean }>();
  for (const run of readers) {
    const person = run.entry.user;
    const finished = run.status === "finished";
    const fraction = finished ? 1 : fractionOf(run.position, run.totalUnits ?? item.totalUnits) ?? 0;
    const known = people.get(person.id);
    if (!known || fraction > known.fraction) people.set(person.id, { person, fraction, finished: finished || Boolean(known?.finished) });
  }

  // The run a note written here would be attached to: the caller's read in
  // progress, if there is one. A note is a log that does not move the
  // bookmark, so the club can be written to without logging pages.
  const activeRun = myRuns.find((run) => run.status === "active");

  return c.json({
    item: itemView(item),
    reach: reach.fraction,
    // False when the reader's place rests on a page count they never
    // confirmed; the club then holds notes back by a margin, and says why.
    reachConfirmed: reach.confirmed,
    aheadCount,
    myRun: activeRun ? runView({ ...activeRun, startedOn: null, finishedOn: null }, item.totalUnits) : null,
    members: [...people.values()]
      .sort((a, b) => b.fraction - a.fraction)
      .map((member) => ({
        ...personView(member.person, config.r2PublicBaseUrl),
        fraction: member.fraction,
        finished: member.finished,
        isMe: member.person.id === userId,
      })),
    notes: visible.map((note) => ({
      id: note.id,
      note: note.note,
      fraction: note.fraction,
      position: note.toPosition,
      loggedOn: dayOf(note.loggedOn),
      createdAt: note.createdAt.toISOString(),
      isMine: note.userId === userId,
      author: personView(note.user, config.r2PublicBaseUrl),
    })),
  });
});

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

shelfRouter.get("/stats", async (c) => {
  const userId = c.get("userId");
  const today = todayFrom(c);
  // "all" is every year at once; anything else that is not a plausible year
  // falls back to this one.
  const rawYear = c.req.query("year") ?? today.slice(0, 4);
  const yearNumber = Number(rawYear);
  const period: StatsPeriod =
    rawYear === "all"
      ? "all"
      : Number.isInteger(yearNumber) && yearNumber > 1900 && yearNumber < 3000
        ? yearNumber
        : Number(today.slice(0, 4));
  const { prisma } = db(c);

  // A person's whole history, aggregated here rather than in SQL: at the size
  // of one reader's shelf it is a few thousand rows at most, and the re-read
  // rule needs every finished run in order anyway.
  const [logs, runs] = await Promise.all([
    prisma.progressLog.findMany({
      where: { userId },
      select: { runId: true, loggedOn: true, fromPosition: true, toPosition: true, closing: true },
    }),
    prisma.shelfRun.findMany({
      where: { entry: { userId } },
      select: {
        id: true,
        entryId: true,
        status: true,
        finishedOn: true,
        totalUnits: true,
        review: { select: { rating: true, recommend: true } },
        entry: { select: { item: { select: { id: true, title: true, coverUrl: true, genres: true, totalUnits: true } } } },
      },
    }),
  ]);

  const statsLogs = logs.map((log) => ({
    runId: log.runId,
    loggedOn: dayOf(log.loggedOn),
    fromPosition: log.fromPosition,
    toPosition: log.toPosition,
    closing: log.closing,
  }));
  const statsRuns = runs.map((run) => ({
    id: run.id,
    entryId: run.entryId,
    itemId: run.entry.item.id,
    status: run.status,
    finishedOn: run.finishedOn ? dayOf(run.finishedOn) : null,
    totalUnits: run.totalUnits ?? run.entry.item.totalUnits,
    title: run.entry.item.title,
    coverUrl: run.entry.item.coverUrl,
    genres: run.entry.item.genres,
    rating: run.review?.rating ?? null,
    recommend: run.review?.recommend ?? null,
  }));

  const years = new Set<number>([Number(today.slice(0, 4))]);
  for (const log of statsLogs) years.add(Number(log.loggedOn.slice(0, 4)));
  for (const run of statsRuns) if (run.finishedOn) years.add(Number(run.finishedOn.slice(0, 4)));

  return c.json({
    stats: buildStats(period, statsLogs, statsRuns),
    currentStreak: currentStreak(statsLogs.filter((log) => !log.closing).map((log) => log.loggedOn), today),
    years: [...years].sort((a, b) => b - a),
  });
});
