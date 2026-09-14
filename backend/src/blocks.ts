import type { PrismaClient } from "@prisma/client";

// A block cuts both directions. Whoever blocked whom, neither person can list,
// key or send to the other, and neither sees the other's conversation — so
// every check below asks "is there a block either way", never "did I block".

/** Everyone on the other side of a block with `userId`, in either direction. */
export async function blockedUserIds(prisma: PrismaClient, userId: number): Promise<Set<number>> {
  const rows = await prisma.userBlock.findMany({
    where: { OR: [{ blockerId: userId }, { blockedId: userId }] },
    select: { blockerId: true, blockedId: true },
  });
  return new Set(rows.map((row) => (row.blockerId === userId ? row.blockedId : row.blockerId)));
}

export async function isBlockedEitherWay(
  prisma: PrismaClient,
  a: number,
  b: number
): Promise<boolean> {
  const row = await prisma.userBlock.findFirst({
    where: {
      OR: [
        { blockerId: a, blockedId: b },
        { blockerId: b, blockedId: a },
      ],
    },
    select: { id: true },
  });
  return row !== null;
}
