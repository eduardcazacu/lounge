-- The Lounge chat room is gone (wiki/decisions.md, "No chat room"). Its
-- messages expired after a day by design, so nothing kept is lost.

-- DropForeignKey
ALTER TABLE "chat_messages" DROP CONSTRAINT "chat_messages_author_id_fkey";

-- DropTable
DROP TABLE "chat_messages";

-- DropTable
DROP TABLE "chat_settings";

