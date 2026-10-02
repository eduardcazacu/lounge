-- AlterTable
ALTER TABLE "catalog_items" ADD COLUMN     "cover_key" TEXT,
ADD COLUMN     "isbns" TEXT[] DEFAULT ARRAY[]::TEXT[];

-- AlterTable
ALTER TABLE "shelf_entries" ADD COLUMN     "import_id" TEXT;

-- AlterTable
ALTER TABLE "shelf_runs" ADD COLUMN     "import_id" TEXT,
ADD COLUMN     "units_confirmed" BOOLEAN NOT NULL DEFAULT false;

-- AlterTable
ALTER TABLE "shelf_reviews" ADD COLUMN     "imported" BOOLEAN NOT NULL DEFAULT false;

-- CreateTable
CREATE TABLE "catalog_search_cache" (
    "kind" TEXT NOT NULL,
    "query" TEXT NOT NULL,
    "results" JSONB NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "catalog_search_cache_pkey" PRIMARY KEY ("kind","query")
);

-- CreateIndex
CREATE INDEX "catalog_search_cache_created_at_idx" ON "catalog_search_cache"("created_at");

-- CreateIndex
CREATE INDEX "catalog_items_isbns_idx" ON "catalog_items" USING GIN ("isbns");

-- CreateIndex
CREATE UNIQUE INDEX "shelf_entries_user_id_import_id_key" ON "shelf_entries"("user_id", "import_id");

-- CreateIndex
CREATE UNIQUE INDEX "shelf_runs_entry_id_import_id_key" ON "shelf_runs"("entry_id", "import_id");

