-- AlterTable
ALTER TABLE "posts" ADD COLUMN     "shelf_review_id" INTEGER;

-- CreateTable
CREATE TABLE "catalog_items" (
    "id" SERIAL NOT NULL,
    "kind" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "external_id" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "creators" TEXT[],
    "year" INTEGER,
    "cover_url" TEXT,
    "total_units" INTEGER,
    "genres" TEXT[],
    "metadata" JSONB,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "catalog_items_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "shelf_entries" (
    "id" SERIAL NOT NULL,
    "user_id" INTEGER NOT NULL,
    "item_id" INTEGER NOT NULL,
    "wanted_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "shelf_entries_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "shelf_runs" (
    "id" SERIAL NOT NULL,
    "entry_id" INTEGER NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'active',
    "started_on" DATE,
    "finished_on" DATE,
    "total_units" INTEGER,
    "position" INTEGER NOT NULL DEFAULT 0,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "shelf_runs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "progress_logs" (
    "id" SERIAL NOT NULL,
    "run_id" INTEGER NOT NULL,
    "user_id" INTEGER NOT NULL,
    "logged_on" DATE NOT NULL,
    "from_position" INTEGER NOT NULL,
    "to_position" INTEGER NOT NULL,
    "note" TEXT,
    "closing" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "progress_logs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "shelf_reviews" (
    "id" SERIAL NOT NULL,
    "run_id" INTEGER NOT NULL,
    "rating" INTEGER,
    "recommend" BOOLEAN,
    "body" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "edited_at" TIMESTAMP(3),

    CONSTRAINT "shelf_reviews_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "shelf_review_comments" (
    "id" SERIAL NOT NULL,
    "review_id" INTEGER NOT NULL,
    "author_id" INTEGER NOT NULL,
    "content" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "edited_at" TIMESTAMP(3),

    CONSTRAINT "shelf_review_comments_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "catalog_items_kind_source_external_id_key" ON "catalog_items"("kind", "source", "external_id");

-- CreateIndex
CREATE UNIQUE INDEX "shelf_entries_user_id_item_id_key" ON "shelf_entries"("user_id", "item_id");

-- CreateIndex
CREATE INDEX "shelf_runs_entry_id_idx" ON "shelf_runs"("entry_id");

-- CreateIndex
CREATE INDEX "shelf_runs_status_idx" ON "shelf_runs"("status");

-- CreateIndex
CREATE INDEX "progress_logs_run_id_idx" ON "progress_logs"("run_id");

-- CreateIndex
CREATE INDEX "progress_logs_user_id_logged_on_idx" ON "progress_logs"("user_id", "logged_on");

-- CreateIndex
CREATE UNIQUE INDEX "shelf_reviews_run_id_key" ON "shelf_reviews"("run_id");

-- CreateIndex
CREATE INDEX "shelf_reviews_created_at_idx" ON "shelf_reviews"("created_at");

-- CreateIndex
CREATE INDEX "shelf_review_comments_review_id_idx" ON "shelf_review_comments"("review_id");

-- CreateIndex
CREATE UNIQUE INDEX "posts_shelf_review_id_key" ON "posts"("shelf_review_id");

-- AddForeignKey
ALTER TABLE "posts" ADD CONSTRAINT "posts_shelf_review_id_fkey" FOREIGN KEY ("shelf_review_id") REFERENCES "shelf_reviews"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_entries" ADD CONSTRAINT "shelf_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_entries" ADD CONSTRAINT "shelf_entries_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "catalog_items"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_runs" ADD CONSTRAINT "shelf_runs_entry_id_fkey" FOREIGN KEY ("entry_id") REFERENCES "shelf_entries"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "progress_logs" ADD CONSTRAINT "progress_logs_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "shelf_runs"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "progress_logs" ADD CONSTRAINT "progress_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_reviews" ADD CONSTRAINT "shelf_reviews_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "shelf_runs"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_review_comments" ADD CONSTRAINT "shelf_review_comments_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "shelf_reviews"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_review_comments" ADD CONSTRAINT "shelf_review_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

