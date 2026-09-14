import type { PrismaClient } from "@prisma/client";

// Every signup lands here. Other groups are populated with
// scripts/create-account.ts.
export const MAIN_GROUP_KEY = "main";

// Looked up per request rather than carried in the JWT, so moving someone
// between groups takes effect immediately instead of when their token expires.
// Returns null for a user id that no longer exists.
export async function getUserGroupId(prisma: PrismaClient, userId: number): Promise<number | null> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { groupId: true },
  });
  return user?.groupId ?? null;
}
