-- AlterTable
ALTER TABLE "users" ADD COLUMN     "notify_book_activity" BOOLEAN NOT NULL DEFAULT true,
ADD COLUMN     "notify_book_club" BOOLEAN NOT NULL DEFAULT true,
ADD COLUMN     "notify_book_discussion" BOOLEAN NOT NULL DEFAULT true;

-- CreateTable
CREATE TABLE "notifications_sent" (
    "user_id" INTEGER NOT NULL,
    "key" TEXT NOT NULL,
    "sent_on" DATE NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "notifications_sent_pkey" PRIMARY KEY ("user_id","key","sent_on")
);

-- CreateIndex
CREATE INDEX "notifications_sent_sent_on_idx" ON "notifications_sent"("sent_on");

-- AddForeignKey
ALTER TABLE "notifications_sent" ADD CONSTRAINT "notifications_sent_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

