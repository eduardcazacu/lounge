-- Postgres indexes the referenced side of a foreign key, never the referencing
-- one. These are the columns read by a foreign key on a hot path — the feed's
-- comments, an author's posts — or scanned by a cascade when a user, a device or
-- a catalog item is deleted.

-- CreateIndex
CREATE INDEX "posts_author_id_idx" ON "posts"("author_id");

-- CreateIndex
CREATE INDEX "comments_post_id_idx" ON "comments"("post_id");

-- CreateIndex
CREATE INDEX "sessions_user_id_idx" ON "sessions"("user_id");

-- CreateIndex
CREATE INDEX "instants_sender_id_idx" ON "instants"("sender_id");

-- CreateIndex
CREATE INDEX "instant_key_envelopes_device_key_id_idx" ON "instant_key_envelopes"("device_key_id");

-- CreateIndex
CREATE INDEX "shelf_entries_item_id_idx" ON "shelf_entries"("item_id");
