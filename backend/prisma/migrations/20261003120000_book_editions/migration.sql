-- AlterTable
ALTER TABLE "shelf_entries" ADD COLUMN     "edition_id" INTEGER;

-- CreateTable
CREATE TABLE "catalog_editions" (
    "id" SERIAL NOT NULL,
    "item_id" INTEGER NOT NULL,
    "source" TEXT NOT NULL,
    "external_id" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "language" TEXT,
    "publisher" TEXT,
    "year" INTEGER,
    "format" TEXT,
    "cover_url" TEXT,
    "cover_key" TEXT,
    "total_units" INTEGER,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "catalog_editions_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "catalog_editions_item_id_source_external_id_key" ON "catalog_editions"("item_id", "source", "external_id");

-- AddForeignKey
ALTER TABLE "catalog_editions" ADD CONSTRAINT "catalog_editions_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "catalog_items"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "shelf_entries" ADD CONSTRAINT "shelf_entries_edition_id_fkey" FOREIGN KEY ("edition_id") REFERENCES "catalog_editions"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- Cached searches predate the English edition each result now carries, and
-- would show the translation's cover for another day.
DELETE FROM "catalog_search_cache";
