-- AlterTable
-- Generalize push subscriptions so APNs device tokens can live alongside Web Push.
-- APNs has no p256dh/auth, so those become nullable.
ALTER TABLE "user_push_subscriptions" ADD COLUMN "provider" TEXT NOT NULL DEFAULT 'webpush';
ALTER TABLE "user_push_subscriptions" ALTER COLUMN "p256dh" DROP NOT NULL;
ALTER TABLE "user_push_subscriptions" ALTER COLUMN "auth" DROP NOT NULL;

-- CreateTable
CREATE TABLE "instant_device_keys" (
    "id" SERIAL NOT NULL,
    "user_id" INTEGER NOT NULL,
    "device_id" TEXT NOT NULL,
    "public_key" TEXT NOT NULL,
    "user_agent" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMP(3),

    CONSTRAINT "instant_device_keys_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "instants" (
    "id" TEXT NOT NULL,
    "sender_id" INTEGER NOT NULL,
    "recipient_id" INTEGER NOT NULL,
    "media_key" TEXT,
    "media_iv" TEXT,
    "ephemeral_pub_key" TEXT,
    "media_type" TEXT NOT NULL DEFAULT 'image/webp',
    "byte_size" INTEGER NOT NULL,
    "duration_mode" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "opened_at" TIMESTAMP(3),
    "viewed_at" TIMESTAMP(3),
    "expires_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "instants_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "instant_key_envelopes" (
    "id" SERIAL NOT NULL,
    "instant_id" TEXT NOT NULL,
    "device_key_id" INTEGER NOT NULL,
    "wrapped_key" TEXT NOT NULL,
    "wrap_iv" TEXT NOT NULL,

    CONSTRAINT "instant_key_envelopes_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "instant_streaks" (
    "id" SERIAL NOT NULL,
    "user_low_id" INTEGER NOT NULL,
    "user_high_id" INTEGER NOT NULL,
    "count" INTEGER NOT NULL DEFAULT 0,
    "last_low_sent_at" TIMESTAMP(3),
    "last_high_sent_at" TIMESTAMP(3),
    "last_increment_on" DATE,
    "warned_for_on" DATE,

    CONSTRAINT "instant_streaks_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "instant_device_keys_user_id_idx" ON "instant_device_keys"("user_id");

-- CreateIndex
CREATE UNIQUE INDEX "instant_device_keys_user_id_device_id_key" ON "instant_device_keys"("user_id", "device_id");

-- CreateIndex
CREATE INDEX "instants_recipient_id_opened_at_idx" ON "instants"("recipient_id", "opened_at");

-- CreateIndex
CREATE INDEX "instants_expires_at_idx" ON "instants"("expires_at");

-- CreateIndex
CREATE INDEX "instants_created_at_idx" ON "instants"("created_at");

-- CreateIndex
CREATE INDEX "instant_key_envelopes_instant_id_idx" ON "instant_key_envelopes"("instant_id");

-- CreateIndex
CREATE UNIQUE INDEX "instant_key_envelopes_instant_id_device_key_id_key" ON "instant_key_envelopes"("instant_id", "device_key_id");

-- CreateIndex
CREATE INDEX "instant_streaks_count_idx" ON "instant_streaks"("count");

-- CreateIndex
CREATE UNIQUE INDEX "instant_streaks_user_low_id_user_high_id_key" ON "instant_streaks"("user_low_id", "user_high_id");

-- AddForeignKey
ALTER TABLE "instant_device_keys" ADD CONSTRAINT "instant_device_keys_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "instants" ADD CONSTRAINT "instants_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "instants" ADD CONSTRAINT "instants_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "instant_key_envelopes" ADD CONSTRAINT "instant_key_envelopes_instant_id_fkey" FOREIGN KEY ("instant_id") REFERENCES "instants"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "instant_key_envelopes" ADD CONSTRAINT "instant_key_envelopes_device_key_id_fkey" FOREIGN KEY ("device_key_id") REFERENCES "instant_device_keys"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "instant_streaks" ADD CONSTRAINT "instant_streaks_user_low_id_fkey" FOREIGN KEY ("user_low_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "instant_streaks" ADD CONSTRAINT "instant_streaks_user_high_id_fkey" FOREIGN KEY ("user_high_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
