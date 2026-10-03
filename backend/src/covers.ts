import type { PrismaClient } from "@prisma/client";
import { USER_AGENT } from "./catalog/books";

// Book covers, copied into our own R2 bucket.
//
// Covers arrive as Open Library (or Google) URLs, and were first shown
// straight from there. That made every page view a request from the viewer's
// browser to Open Library, which limits cover requests by IP — a library page
// full of covers fetched by ISBN could get a reader's own IP refused — and
// left covers blank whenever Open Library was down. A copy made once, on the
// server, is neither, and is resized by Cloudflare like every other image the
// Lounge serves (`getTransformedImageUrl` in frontend/src/lib/content.ts).
//
// `coverUrl` stays "the URL to show", on a CatalogItem and a CatalogEdition
// alike: the provider's until the copy exists, ours after. `coverKey` marks a
// copy as ours. The hourly sweep copies what a request did not get to, and
// rewrites URLs if the bucket's public address ever changes.

const TIMEOUT_MS = 8000;
const MAX_BYTES = 2 * 1024 * 1024;
// Smaller than any real cover: a 1×1 placeholder some providers send instead
// of a 404.
const MIN_BYTES = 1024;
const SWEEP_BATCH = 20;

const EXTENSIONS: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/gif": "gif",
};

export type CoverOutcome = "copied" | "none" | "skipped" | "failed";

export function publicCoverUrl(r2PublicBaseUrl: string, key: string) {
  return `${r2PublicBaseUrl.replace(/\/+$/, "")}/${key}`;
}

// Works and editions both carry a cover, the same two columns on each. An
// edition's copy lives under covers/editions/ so the two id sequences never
// share a key.
type CoverRow = { coverUrl: string | null; coverKey: string | null };
type CoverTable = {
  prefix: string;
  find(prisma: PrismaClient, id: number): Promise<CoverRow | null>;
  update(prisma: PrismaClient, id: number, data: { coverUrl: string | null; coverKey?: string }): Promise<unknown>;
  pending(prisma: PrismaClient): Promise<{ id: number }[]>;
  stale(prisma: PrismaClient, base: string): Promise<{ id: number; coverKey: string | null }[]>;
};

const coverColumns = { coverUrl: true, coverKey: true } as const;

const TABLES = {
  item: {
    prefix: "covers/",
    find: (prisma, id) => prisma.catalogItem.findUnique({ where: { id }, select: coverColumns }),
    update: (prisma, id, data) => prisma.catalogItem.update({ where: { id }, data }),
    pending: (prisma) =>
      prisma.catalogItem.findMany({
        where: { coverKey: null, coverUrl: { not: null } },
        orderBy: { id: "asc" },
        take: SWEEP_BATCH,
        select: { id: true },
      }),
    stale: (prisma, base) =>
      prisma.catalogItem.findMany({
        where: { coverKey: { not: null }, NOT: { coverUrl: { startsWith: `${base}/` } } },
        take: 500,
        select: { id: true, coverKey: true },
      }),
  },
  edition: {
    prefix: "covers/editions/",
    find: (prisma, id) => prisma.catalogEdition.findUnique({ where: { id }, select: coverColumns }),
    update: (prisma, id, data) => prisma.catalogEdition.update({ where: { id }, data }),
    pending: (prisma) =>
      prisma.catalogEdition.findMany({
        where: { coverKey: null, coverUrl: { not: null } },
        orderBy: { id: "asc" },
        take: SWEEP_BATCH,
        select: { id: true },
      }),
    stale: (prisma, base) =>
      prisma.catalogEdition.findMany({
        where: { coverKey: { not: null }, NOT: { coverUrl: { startsWith: `${base}/` } } },
        take: 500,
        select: { id: true, coverKey: true },
      }),
  },
} satisfies Record<string, CoverTable>;

export type CoverOwner = keyof typeof TABLES;

export async function copyCover(
  prisma: PrismaClient,
  bucket: R2Bucket | undefined,
  r2PublicBaseUrl: string | undefined,
  id: number,
  owner: CoverOwner = "item"
): Promise<CoverOutcome> {
  // Without a bucket (`npm run dev`) covers stay where they are.
  if (!bucket || !r2PublicBaseUrl) return "skipped";
  const table: CoverTable = TABLES[owner];
  const row = await table.find(prisma, id);
  if (!row?.coverUrl || row.coverKey) return "skipped";

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(row.coverUrl, { headers: { "User-Agent": USER_AGENT }, signal: controller.signal });
    if (response.status === 404) {
      // No such cover — usually an ISBN Open Library has no picture for. Drop
      // the URL so nobody asks again; the client draws a title board.
      await table.update(prisma, id, { coverUrl: null });
      return "none";
    }
    // Anything else that is not a picture is a refusal or an outage, and the
    // sweep tries again in an hour.
    if (!response.ok) return "failed";
    const contentType = (response.headers.get("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
    const extension = EXTENSIONS[contentType];
    if (!extension) return "failed";
    const bytes = await response.arrayBuffer();
    if (bytes.byteLength > MAX_BYTES) return "failed";
    if (bytes.byteLength < MIN_BYTES) {
      await table.update(prisma, id, { coverUrl: null });
      return "none";
    }

    const key = `${table.prefix}${id}.${extension}`;
    await bucket.put(key, bytes, {
      httpMetadata: { contentType, cacheControl: "public, max-age=31536000, immutable" },
    });
    await table.update(prisma, id, { coverKey: key, coverUrl: publicCoverUrl(r2PublicBaseUrl, key) });
    return "copied";
  } catch (error) {
    console.warn("[covers] copy failed", owner, id, error instanceof Error ? error.message : error);
    return "failed";
  } finally {
    clearTimeout(timer);
  }
}

/** Copies several, one after another: the sources are rate-limited by IP. */
export async function copyCovers(
  prisma: PrismaClient,
  bucket: R2Bucket | undefined,
  r2PublicBaseUrl: string | undefined,
  itemIds: number[],
  editionIds: number[] = []
) {
  const outcomes: CoverOutcome[] = [];
  for (const itemId of itemIds) outcomes.push(await copyCover(prisma, bucket, r2PublicBaseUrl, itemId));
  for (const editionId of editionIds) outcomes.push(await copyCover(prisma, bucket, r2PublicBaseUrl, editionId, "edition"));
  return outcomes;
}

/** The hourly part: covers no request got to, and URLs a domain change left behind. */
export async function sweepCovers(prisma: PrismaClient, bucket: R2Bucket | undefined, r2PublicBaseUrl: string | undefined) {
  if (!bucket || !r2PublicBaseUrl) return { copied: 0, rewritten: 0 };
  const base = r2PublicBaseUrl.replace(/\/+$/, "");
  let copied = 0;
  let rewritten = 0;
  for (const [owner, table] of Object.entries(TABLES) as [CoverOwner, CoverTable][]) {
    for (const row of await table.pending(prisma)) {
      if ((await copyCover(prisma, bucket, r2PublicBaseUrl, row.id, owner)) === "copied") copied += 1;
    }
    const stale = await table.stale(prisma, base);
    for (const row of stale) await table.update(prisma, row.id, { coverUrl: publicCoverUrl(base, row.coverKey!) });
    rewritten += stale.length;
  }
  return { copied, rewritten };
}

/** Removes a copied cover, for a catalog item about to be deleted. */
export async function deleteCover(bucket: R2Bucket | undefined, coverKey: string | null) {
  if (bucket && coverKey) {
    await Promise.resolve(bucket.delete(coverKey)).catch((error) => console.warn("[covers] delete failed", coverKey, error));
  }
}
