// Creates a ready-to-use account in a group: approved, email already verified,
// so it can sign in immediately without an inbox or an admin.
//
//   cd backend && npx tsx scripts/create-account.ts \
//     --email review@example.com --name "App Review" --group testing
//
// This is how the App Store review accounts in "testing" are made. The password
// is taken from ACCOUNT_PASSWORD if set, otherwise generated and printed once.
// Either way it only ever reaches the database as a bcrypt hash — never put it
// in the repo.
//
// Targets whatever DATABASE_URL resolves to (backend/.env by default).

import "dotenv/config";
import { parseArgs } from "node:util";
import { Prisma } from "@prisma/client";
import { getPrismaClient } from "../src/prisma";
import { hashPassword } from "../src/password";
import { normalizeEmail } from "../src/verification";

const MIN_PASSWORD_LENGTH = 6;

function generatePassword() {
  // Unambiguous characters, so it survives being read aloud or retyped from
  // App Store Connect's review notes.
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(20));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

async function main() {
  const { values } = parseArgs({
    options: {
      email: { type: "string" },
      name: { type: "string" },
      group: { type: "string" },
    },
  });

  if (!values.email || !values.group) {
    console.error(
      "Usage: npx tsx scripts/create-account.ts --email <email> --group <key> [--name <name>]"
    );
    process.exit(2);
  }

  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    console.error("DATABASE_URL is not set.");
    process.exit(2);
  }

  const suppliedPassword = process.env.ACCOUNT_PASSWORD;
  if (suppliedPassword !== undefined && suppliedPassword.length < MIN_PASSWORD_LENGTH) {
    console.error(`ACCOUNT_PASSWORD must be at least ${MIN_PASSWORD_LENGTH} characters.`);
    process.exit(2);
  }
  const password = suppliedPassword ?? generatePassword();

  const prisma = getPrismaClient(databaseUrl);
  try {
    const group = await prisma.group.findUnique({
      where: { key: values.group },
      select: { id: true, key: true },
    });
    if (!group) {
      const known = await prisma.group.findMany({ select: { key: true }, orderBy: { id: "asc" } });
      console.error(
        `No group "${values.group}". Known groups: ${known.map((g) => g.key).join(", ") || "none"}.`
      );
      process.exit(1);
    }

    const email = normalizeEmail(values.email);
    if (await prisma.user.findUnique({ where: { email }, select: { id: true } })) {
      console.error(`An account with email ${email} already exists.`);
      process.exit(1);
    }

    const user = await prisma.user.create({
      data: {
        email,
        name: values.name?.trim() || null,
        password: await hashPassword(password),
        status: "approved",
        emailVerifiedAt: new Date(),
        groupId: group.id,
      },
      select: { id: true, email: true },
    });

    console.log(`Created user ${user.id} <${user.email}> in group "${group.key}".`);
    if (suppliedPassword === undefined) {
      console.log(`Password (shown once, not stored anywhere else): ${password}`);
    }
  } catch (error) {
    if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === "P2002") {
      console.error(`An account with email ${values.email} already exists.`);
      process.exit(1);
    }
    throw error;
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
