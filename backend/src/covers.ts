import type { PrismaClient } from "@prisma/client";

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
// `CatalogItem.coverUrl` stays "the URL to show": the provider's until the copy
// exists, ours after. `coverKey` marks a copy as ours. The hourly sweep copies
// what a request did not get to, and rewrites URLs if the bucket's public
// address ever changes.

const TIMEOUT_MS = 8000;
const MAX_BYTES = 2 * 1024 * 1024;
// Smaller than any real cover: a 1×1 placeholder some providers send instead
// of a 404.
const MIN_BYTES = 1024;
const USER_AGENT = "EddiesLounge/1.0 (https://lounge.eduardcazacu.com)";
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

export async function copyCover(
  prisma: PrismaClient,
  bucket: R2Bucket | undefined,
  r2PublicBaseUrl: string | undefined,
  itemId: number
): Promise<CoverOutcome> {
  // Without a bucket (`npm run dev`) covers stay where they are.
  if (!bucket || !r2PublicBaseUrl) return "skipped";
  const item = await prisma.catalogItem.findUnique({ where: { id: itemId }, select: { coverUrl: true, coverKey: true } });
  if (!item?.coverUrl || item.coverKey) return "skipped";

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(item.coverUrl, { headers: { "User-Agent": USER_AGENT }, signal: controller.signal });
    if (response.status === 404) {
      // No such cover — usually an ISBN Open Library has no picture for. Drop
      // the URL so nobody asks again; the client draws a title board.
      await prisma.catalogItem.update({ where: { id: itemId }, data: { coverUrl: null } });
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
      await prisma.catalogItem.update({ where: { id: itemId }, data: { coverUrl: null } });
      return "none";
    }

    const key = `covers/${itemId}.${extension}`;
    await bucket.put(key, bytes, {
      httpMetadata: { contentType, cacheControl: "public, max-age=31536000, immutable" },
    });
    await prisma.catalogItem.update({
      where: { id: itemId },
      data: { coverKey: key, coverUrl: publicCoverUrl(r2PublicBaseUrl, key) },
    });
    return "copied";
  } catch (error) {
    console.warn("[covers] copy failed", itemId, error instanceof Error ? error.message : error);
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
  itemIds: number[]
) {
  const outcomes: CoverOutcome[] = [];
  for (const itemId of itemIds) outcomes.push(await copyCover(prisma, bucket, r2PublicBaseUrl, itemId));
  return outcomes;
}

/** The hourly part: covers no request got to, and URLs a domain change left behind. */
export async function sweepCovers(prisma: PrismaClient, bucket: R2Bucket | undefined, r2PublicBaseUrl: string | undefined) {
  if (!bucket || !r2PublicBaseUrl) return { copied: 0, rewritten: 0 };
  const pending = await prisma.catalogItem.findMany({
    where: { coverKey: null, coverUrl: { not: null } },
    orderBy: { id: "asc" },
    take: SWEEP_BATCH,
    select: { id: true },
  });
  const outcomes = await copyCovers(prisma, bucket, r2PublicBaseUrl, pending.map((item) => item.id));

  const base = r2PublicBaseUrl.replace(/\/+$/, "");
  const stale = await prisma.catalogItem.findMany({
    where: { coverKey: { not: null }, NOT: { coverUrl: { startsWith: `${base}/` } } },
    take: 500,
    select: { id: true, coverKey: true },
  });
  for (const item of stale) {
    await prisma.catalogItem.update({ where: { id: item.id }, data: { coverUrl: publicCoverUrl(base, item.coverKey!) } });
  }
  return { copied: outcomes.filter((outcome) => outcome === "copied").length, rewritten: stale.length };
}

/** Removes a copied cover, for a catalog item about to be deleted. */
export async function deleteCover(bucket: R2Bucket | undefined, coverKey: string | null) {
  if (bucket && coverKey) {
    await Promise.resolve(bucket.delete(coverKey)).catch((error) => console.warn("[covers] delete failed", coverKey, error));
  }
}
