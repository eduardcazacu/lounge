import { createHash } from "node:crypto";
import type { Prisma, PrismaClient } from "@prisma/client";
import { sameBook } from "./catalog/match-book";
import { dateFromDay, dayOf } from "./shelf-logic";

// Reading progress from KOReader, applied to Books. The wire side — KOReader's
// own sync protocol — is src/route/kosync.ts; this is what a sync means here.
//
// KOReader names a file by a hash and gives a percentage. So a file is first
// identified (by the reader, or by the title KOReader sends when "Send
// document metadata" is on), and a percentage becomes a page of the reader's
// own copy, the same way the book club turns pages into fractions the other
// way.
//
// A sync only ever moves a read forward, and only one that is already under
// way: flicking back to check a map is not un-reading, and opening a book on
// the Kindle is not deciding to read it.

export const READER_SOURCE = "koreader";

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

// No 0/o, 1/l/i: it is typed on a Kindle's keyboard from a phone screen.
const PASSWORD_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

/** Twelve characters in three groups: about 59 bits, and short enough to type. */
export function generatePassword() {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  const chars = [...bytes].map((byte) => PASSWORD_ALPHABET[byte % PASSWORD_ALPHABET.length]);
  return [chars.slice(0, 4), chars.slice(4, 8), chars.slice(8)].map((group) => group.join("")).join("-");
}

/**
 * The key KOReader will send for a password: it hashes the password itself,
 * so this is all the server ever sees. node:crypto because Node's WebCrypto
 * has no MD5; the Worker has node:crypto through nodejs_compat.
 */
export function readerKeyFor(password: string) {
  return createHash("md5").update(password).digest("hex");
}

/** What is stored for a key KOReader sends. */
export function hashReaderKey(key: string) {
  return createHash("sha256").update(key.toLowerCase()).digest("hex");
}

export function sameHash(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** A KOReader username from a display name: lowercase letters and digits. */
export function usernameFrom(name: string | null | undefined) {
  const slug = (name ?? "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "")
    .slice(0, 20);
  return slug || "reader";
}

export function validTimeZone(timeZone: string) {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** The calendar day it is in `timeZone`: what a manual log would be dated. */
export function dayInZone(date: Date, timeZone: string) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(date);
    const get = (type: string) => parts.find((part) => part.type === type)?.value;
    return `${get("year")}-${get("month")}-${get("day")}`;
  } catch {
    return dayOf(date);
  }
}

// ---------------------------------------------------------------------------
// Pure: what a sync does to a run
// ---------------------------------------------------------------------------

/** A percentage of the reader's copy, as a page of it. */
export function pageAt(percentage: number, totalUnits: number | null) {
  if (!totalUnits || !Number.isFinite(percentage)) return null;
  const clamped = Math.min(1, Math.max(0, percentage));
  return Math.min(totalUnits, Math.round(clamped * totalUnits));
}

export type LastLog = { id: number; loggedOn: string; source: string | null; note: string | null; closing: boolean };

export type SyncStep =
  | { kind: "none"; reason: "no-length" | "not-forward" }
  | { kind: "extend"; logId: number; from: number; to: number }
  | { kind: "create"; from: number; to: number };

/**
 * One sync, as a change to a run's log. A sync turning pages every few
 * minutes extends the day's KOReader log rather than adding one each time,
 * or a day's reading would be forty rows in the book's history. A note, or a
 * log the reader wrote by hand, ends that: the next sync starts a new log, so
 * nothing the reader wrote is ever moved.
 */
export function planSync(input: {
  position: number;
  totalUnits: number | null;
  percentage: number;
  day: string;
  lastLog: LastLog | null;
}): SyncStep {
  const to = pageAt(input.percentage, input.totalUnits);
  if (to === null) return { kind: "none", reason: "no-length" };
  if (to <= input.position) return { kind: "none", reason: "not-forward" };
  const last = input.lastLog;
  if (last && last.source === READER_SOURCE && last.loggedOn === input.day && !last.note && !last.closing) {
    return { kind: "extend", logId: last.id, from: input.position, to };
  }
  return { kind: "create", from: input.position, to };
}

// ---------------------------------------------------------------------------
// Identifying a file
// ---------------------------------------------------------------------------

/**
 * KOReader's authors are one string, several names on separate lines, and a
 * calibre library may store them surname first.
 */
export function authorsFrom(authors: string | null | undefined) {
  return (authors ?? "")
    .split(/\n|;| & /)
    .map((name) => name.trim())
    .filter(Boolean)
    .map((name) => {
      const parts = name.split(",").map((part) => part.trim());
      return parts.length === 2 && parts[1] ? `${parts[1]} ${parts[0]}` : name;
    });
}

type Candidate = { entryId: number; title: string; creators: string[] };

/** The one candidate KOReader's title and authors describe, or null if none or several. */
export function matchByMetadata(title: string | null | undefined, authors: string | null | undefined, candidates: Candidate[]) {
  if (!title?.trim()) return null;
  const book = { title, creators: authorsFrom(authors) };
  const found = candidates.filter((candidate) => sameBook(book, { title: candidate.title, author_name: candidate.creators }));
  return found.length === 1 ? found[0].entryId : null;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/**
 * Moves a run to `to` with a log, in one transaction with the caller's other
 * writes. Logging by hand and syncing both come through here, so a run's
 * position and its logs cannot disagree.
 */
export async function recordProgress(
  tx: Prisma.TransactionClient,
  input: {
    runId: number;
    userId: number;
    day: string;
    from: number;
    to: number;
    note?: string | null;
    source?: string | null;
    extendLogId?: number;
  }
) {
  const select = { id: true, loggedOn: true, fromPosition: true, toPosition: true, note: true, createdAt: true } as const;
  const log = input.extendLogId
    ? await tx.progressLog.update({ where: { id: input.extendLogId }, data: { toPosition: input.to }, select })
    : await tx.progressLog.create({
        data: {
          runId: input.runId,
          userId: input.userId,
          loggedOn: dateFromDay(input.day),
          fromPosition: input.from,
          toPosition: input.to,
          note: input.note ?? null,
          source: input.source ?? null,
        },
        select,
      });
  await tx.shelfRun.update({ where: { id: input.runId }, data: { position: input.to } });
  return log;
}

/**
 * Applies a document's stored percentage to the read it is linked to, if
 * there is one under way. Returns the run's new position, or null when
 * nothing moved.
 */
export async function applyDocument(prisma: PrismaClient, documentId: number, day: string) {
  return prisma.$transaction(async (tx) => {
    const doc = await tx.readerDocument.findUnique({
      where: { id: documentId },
      select: { userId: true, entryId: true, ignored: true, percentage: true },
    });
    if (!doc || doc.ignored || doc.entryId === null) return null;
    const run = await tx.shelfRun.findFirst({
      where: { entryId: doc.entryId, status: "active", entry: { userId: doc.userId } },
      select: {
        id: true,
        position: true,
        totalUnits: true,
        entry: { select: { item: { select: { totalUnits: true } } } },
        logs: {
          orderBy: { id: "desc" },
          take: 1,
          select: { id: true, loggedOn: true, source: true, note: true, closing: true },
        },
      },
    });
    if (!run) return null;
    const last = run.logs[0];
    const step = planSync({
      position: run.position,
      totalUnits: run.totalUnits ?? run.entry.item.totalUnits,
      percentage: doc.percentage,
      day,
      lastLog: last ? { ...last, loggedOn: dayOf(last.loggedOn) } : null,
    });
    if (step.kind === "none") return null;
    await recordProgress(tx, {
      runId: run.id,
      userId: doc.userId,
      day,
      from: step.from,
      to: step.to,
      source: READER_SOURCE,
      extendLogId: step.kind === "extend" ? step.logId : undefined,
    });
    return step.to;
  });
}

export type ReaderPush = {
  document: string;
  progress: string;
  percentage: number;
  device: string;
  deviceId: string;
  title?: string | null;
  authors?: string | null;
};

/**
 * One PUT from KOReader: remember it (so KOReader's other devices can pull
 * it), identify the file if its title says which book it is, and move the
 * read. Returns when it was stored, which is the timestamp KOReader keeps.
 */
export async function receivePush(prisma: PrismaClient, userId: number, timeZone: string, push: ReaderPush) {
  const metadata = push.title ? { title: push.title.slice(0, 500), authors: push.authors?.slice(0, 500) ?? null } : {};
  const doc = await prisma.readerDocument.upsert({
    where: { userId_document: { userId, document: push.document } },
    create: {
      userId,
      document: push.document,
      progress: push.progress,
      percentage: push.percentage,
      device: push.device,
      deviceId: push.deviceId,
      ...metadata,
    },
    update: {
      progress: push.progress,
      percentage: push.percentage,
      device: push.device,
      deviceId: push.deviceId,
      ...metadata,
    },
    select: { id: true, entryId: true, ignored: true, title: true, authors: true, updatedAt: true },
  });

  if (doc.entryId === null && !doc.ignored && doc.title) {
    // Only reads already under way: opening a book on the Kindle is not
    // deciding to read it, so a want-list match is a suggestion (see
    // `pendingDocuments`), not a start.
    const reading = await prisma.shelfEntry.findMany({
      where: { userId, runs: { some: { status: "active" } } },
      select: { id: true, item: { select: { title: true, creators: true } } },
    });
    const entryId = matchByMetadata(
      doc.title,
      doc.authors,
      reading.map((entry) => ({ entryId: entry.id, title: entry.item.title, creators: entry.item.creators }))
    );
    if (entryId !== null) await prisma.readerDocument.update({ where: { id: doc.id }, data: { entryId } });
  }

  await applyDocument(prisma, doc.id, dayInZone(new Date(), timeZone));
  return doc.updatedAt;
}

/**
 * Files synced lately that nobody has said are a book, each with the entry it
 * most likely is: the one its title names, or else the only read under way
 * that no file is linked to yet — the usual case, one book on the go.
 */
export async function pendingDocuments(prisma: PrismaClient, userId: number) {
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  const docs = await prisma.readerDocument.findMany({
    where: { userId, entryId: null, ignored: false, updatedAt: { gte: since } },
    orderBy: { updatedAt: "desc" },
    take: 5,
    select: { id: true, title: true, authors: true, percentage: true, device: true, updatedAt: true },
  });
  if (docs.length === 0) return [];
  const entries = await prisma.shelfEntry.findMany({
    where: { userId, OR: [{ runs: { some: { status: "active" } } }, { wantedAt: { not: null } }] },
    select: {
      id: true,
      item: { select: { title: true, creators: true } },
      runs: { where: { status: "active" }, select: { id: true } },
      _count: { select: { readerDocuments: true } },
    },
  });
  const candidates = entries.map((entry) => ({ entryId: entry.id, title: entry.item.title, creators: entry.item.creators }));
  const unlinkedReading = entries.filter((entry) => entry.runs.length > 0 && entry._count.readerDocuments === 0);
  return docs.map((doc) => ({
    id: doc.id,
    title: doc.title,
    authors: doc.authors,
    percentage: doc.percentage,
    device: doc.device,
    syncedAt: doc.updatedAt.toISOString(),
    suggestedEntryId:
      matchByMetadata(doc.title, doc.authors, candidates) ??
      (!doc.title && unlinkedReading.length === 1 ? unlinkedReading[0].id : null),
  }));
}
