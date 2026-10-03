-- AlterTable
ALTER TABLE "posts" ADD COLUMN     "shelf_ask_id" INTEGER;

-- CreateTable
CREATE TABLE "shelf_asks" (
    "id" SERIAL NOT NULL,
    "author_id" INTEGER NOT NULL,
    "body" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "edited_at" TIMESTAMP(3),

    CONSTRAINT "shelf_asks_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "shelf_ask_comments" (
    "id" SERIAL NOT NULL,
    "ask_id" INTEGER NOT NULL,
    "author_id" INTEGER NOT NULL,
    "content" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "edited_at" TIMESTAMP(3),

    CONSTRAINT "shelf_ask_comments_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "shelf_asks_created_at_idx" ON "shelf_asks"("created_at");

-- CreateIndex
CREATE INDEX "shelf_ask_comments_ask_id_idx" ON "shelf_ask_comments"("ask_id");

-- CreateIndex
CREATE UNIQUE INDEX "posts_shelf_ask_id_key" ON "posts"("shelf_ask_id");

-- AddForeignKey
ALTER TABLE "posts" ADD CONSTRAINT "posts_shelf_ask_id_fkey" FOREIGN KEY ("shelf_ask_id") REFERENCES "shelf_asks"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_asks" ADD CONSTRAINT "shelf_asks_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_ask_comments" ADD CONSTRAINT "shelf_ask_comments_ask_id_fkey" FOREIGN KEY ("ask_id") REFERENCES "shelf_asks"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_ask_comments" ADD CONSTRAINT "shelf_ask_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

