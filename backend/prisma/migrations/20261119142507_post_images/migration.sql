-- A post's photos move from one column on the post to rows of their own, for
-- carousels of up to ten. Each existing image becomes its post's cover
-- (position 0); its size was never recorded, so it stays null and the carousel
-- measures it when it loads. Copied before the column is dropped.

-- CreateTable
CREATE TABLE "post_images" (
    "id" SERIAL NOT NULL,
    "post_id" INTEGER NOT NULL,
    "key" TEXT NOT NULL,
    "position" INTEGER NOT NULL,
    "width" INTEGER,
    "height" INTEGER,

    CONSTRAINT "post_images_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "post_images_key_key" ON "post_images"("key");

-- CreateIndex
CREATE INDEX "post_images_post_id_position_idx" ON "post_images"("post_id", "position");

-- AddForeignKey
ALTER TABLE "post_images" ADD CONSTRAINT "post_images_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "posts"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- CopyData
INSERT INTO "post_images" ("post_id", "key", "position")
SELECT "id", "image_key", 0 FROM "posts" WHERE "image_key" IS NOT NULL;

-- AlterTable
ALTER TABLE "posts" DROP COLUMN "image_key";
