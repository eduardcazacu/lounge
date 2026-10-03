import type { Prisma, PrismaClient } from "@prisma/client";
import type { CatalogCandidate, CatalogEdition } from "@blogging-app/common";
import { bareTitle, sameBook, type BookToFind } from "./match-book";

// The catalog we already have, asked before Open Library is.
//
// A group reads the same books. The second person to import or rematch a book
// finds it here — by an ISBN an earlier import attached to it, or by title and
// author — and Open Library is never asked. Only catalog works count; a manual
// item is what we are trying to get away from.

type Db = PrismaClient | Prisma.TransactionClient;

export type KnownBook = { itemId: number; totalUnits: number | null; match: "isbn" | "title" };

function isbnsOf(book: Pick<BookToFind, "isbn13" | "isbn10">) {
  return [book.isbn13, book.isbn10].filter((isbn): isbn is string => Boolean(isbn));
}

export async function findKnownBook(db: Db, book: BookToFind): Promise<KnownBook | null> {
  const isbns = isbnsOf(book);
  if (isbns.length > 0) {
    const byIsbn = await db.catalogItem.findFirst({
      where: { kind: "book", source: { not: "manual" }, isbns: { hasSome: isbns } },
      select: { id: true, totalUnits: true },
    });
    if (byIsbn) return { itemId: byIsbn.id, totalUnits: byIsbn.totalUnits, match: "isbn" };
  }

  const title = bareTitle(book.title);
  if (!title) return null;
  const byTitle = await db.catalogItem.findMany({
    where: { kind: "book", source: { not: "manual" }, title: { startsWith: title, mode: "insensitive" } },
    select: { id: true, title: true, creators: true, totalUnits: true },
    take: 10,
  });
  const found = byTitle.find((item) => sameBook(book, { title: item.title, author_name: item.creators }));
  return found ? { itemId: found.id, totalUnits: found.totalUnits, match: "title" } : null;
}

/**
 * Adds ISBNs to a work, so the next import of those editions finds it here.
 * Read-modify-write rather than `push`, which would store duplicates.
 */
export async function rememberIsbns(db: Db, itemId: number, book: Pick<BookToFind, "isbn13" | "isbn10">) {
  const isbns = isbnsOf(book);
  if (isbns.length === 0) return;
  const item = await db.catalogItem.findUnique({ where: { id: itemId }, select: { isbns: true } });
  if (!item) return;
  const missing = isbns.filter((isbn) => !item.isbns.includes(isbn));
  if (missing.length > 0) {
    await db.catalogItem.update({ where: { id: itemId }, data: { isbns: [...item.isbns, ...missing] } });
  }
}

/**
 * The catalog row for a candidate, created on first sighting. The first
 * sighting fixes the metadata: later searches may say something slightly
 * different, and a cover changing under existing reviews is worse than an old
 * page count.
 */
export async function saveCandidate(db: Db, candidate: CatalogCandidate, book?: Pick<BookToFind, "isbn13" | "isbn10">) {
  const item = await db.catalogItem.upsert({
    where: { kind_source_externalId: { kind: candidate.kind, source: candidate.source, externalId: candidate.externalId } },
    create: {
      kind: candidate.kind,
      source: candidate.source,
      externalId: candidate.externalId,
      title: candidate.title,
      creators: candidate.creators,
      year: candidate.year,
      coverUrl: candidate.coverUrl,
      totalUnits: candidate.totalUnits,
      genres: candidate.genres,
      isbns: book ? isbnsOf(book) : [],
    },
    update: {},
    select: { id: true, totalUnits: true, coverUrl: true, coverKey: true },
  });
  if (book) await rememberIsbns(db, item.id, book);
  return item;
}

/**
 * The work a candidate should land on: itself if we have it, else a work we
 * already have with the same title and author from any source, else a new
 * one. Without the middle step, a book first added from Google Books and
 * later picked from Open Library's search results would become two works,
 * and its readers two book clubs.
 */
export async function resolveCandidate(db: Db, candidate: CatalogCandidate, book?: Pick<BookToFind, "isbn13" | "isbn10">) {
  if (candidate.source !== "manual") {
    const exact = await db.catalogItem.findUnique({
      where: { kind_source_externalId: { kind: candidate.kind, source: candidate.source, externalId: candidate.externalId } },
      select: { id: true },
    });
    if (!exact) {
      const known = await findKnownBook(db, {
        title: candidate.title,
        creators: candidate.creators,
        isbn13: book?.isbn13 ?? null,
        isbn10: book?.isbn10 ?? null,
        totalUnits: candidate.totalUnits,
        year: candidate.year,
      });
      if (known) {
        if (book) await rememberIsbns(db, known.itemId, book);
        return db.catalogItem.findUniqueOrThrow({
          where: { id: known.itemId },
          select: { id: true, totalUnits: true, coverUrl: true, coverKey: true },
        });
      }
    }
  }
  return saveCandidate(db, candidate, book);
}

/**
 * The row for an edition of a work, created the first time anybody picks it.
 * Like a work, its first sighting fixes it.
 */
export async function saveEdition(db: Db, itemId: number, edition: CatalogEdition) {
  return db.catalogEdition.upsert({
    where: { itemId_source_externalId: { itemId, source: edition.source, externalId: edition.externalId } },
    create: {
      itemId,
      source: edition.source,
      externalId: edition.externalId,
      title: edition.title,
      language: edition.language,
      publisher: edition.publisher,
      year: edition.year,
      format: edition.format,
      coverUrl: edition.coverUrl,
      totalUnits: edition.totalUnits,
    },
    update: {},
    select: { id: true, coverUrl: true, coverKey: true },
  });
}
