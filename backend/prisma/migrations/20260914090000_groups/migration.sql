-- CreateTable
CREATE TABLE "groups" (
    "id" SERIAL NOT NULL,
    "key" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "groups_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "groups_key_key" ON "groups"("key");

-- Seed the two groups. Accounts for "testing" are created with
-- scripts/create-account.ts so their passwords never live in the repo.
INSERT INTO "groups" ("key", "name") VALUES ('main', 'Main'), ('testing', 'Testing');

-- AlterTable
-- Added nullable, backfilled into "main", then tightened, so every existing
-- account stays where it was.
ALTER TABLE "users" ADD COLUMN "group_id" INTEGER;
UPDATE "users" SET "group_id" = (SELECT "id" FROM "groups" WHERE "key" = 'main');
ALTER TABLE "users" ALTER COLUMN "group_id" SET NOT NULL;

-- CreateIndex
CREATE INDEX "users_group_id_idx" ON "users"("group_id");

-- AddForeignKey
ALTER TABLE "users" ADD CONSTRAINT "users_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "groups"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
