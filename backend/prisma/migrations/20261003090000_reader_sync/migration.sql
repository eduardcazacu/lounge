-- AlterTable
ALTER TABLE "progress_logs" ADD COLUMN     "source" TEXT;

-- CreateTable
CREATE TABLE "reader_syncs" (
    "user_id" INTEGER NOT NULL,
    "username" TEXT NOT NULL,
    "key_hash" TEXT NOT NULL,
    "time_zone" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMP(3),

    CONSTRAINT "reader_syncs_pkey" PRIMARY KEY ("user_id")
);

-- CreateTable
CREATE TABLE "reader_documents" (
    "id" SERIAL NOT NULL,
    "user_id" INTEGER NOT NULL,
    "document" TEXT NOT NULL,
    "entry_id" INTEGER,
    "ignored" BOOLEAN NOT NULL DEFAULT false,
    "progress" TEXT NOT NULL,
    "percentage" DOUBLE PRECISION NOT NULL,
    "device" TEXT NOT NULL,
    "device_id" TEXT NOT NULL,
    "title" TEXT,
    "authors" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "reader_documents_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "reader_syncs_username_key" ON "reader_syncs"("username");

-- CreateIndex
CREATE INDEX "reader_documents_entry_id_idx" ON "reader_documents"("entry_id");

-- CreateIndex
CREATE UNIQUE INDEX "reader_documents_user_id_document_key" ON "reader_documents"("user_id", "document");

-- AddForeignKey
ALTER TABLE "reader_syncs" ADD CONSTRAINT "reader_syncs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "reader_documents" ADD CONSTRAINT "reader_documents_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "reader_documents" ADD CONSTRAINT "reader_documents_entry_id_fkey" FOREIGN KEY ("entry_id") REFERENCES "shelf_entries"("id") ON DELETE SET NULL ON UPDATE CASCADE;
