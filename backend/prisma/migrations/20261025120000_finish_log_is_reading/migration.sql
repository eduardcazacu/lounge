-- Finish used to write its log of the unlogged pages as a closing log, which is
-- never a reading day, so a reader who finished a book lost that day's streak.
-- It now writes a reading-day log tagged "finish". Earlier finishes are told
-- apart from backfills by the run having other logs: a backfilled read only
-- ever gets its one closing log. A book finished without a single log before
-- it cannot be told apart, and stays as it is.
UPDATE "progress_logs" AS closing
SET "closing" = false, "source" = 'finish'
WHERE closing."closing" = true
  AND EXISTS (
    SELECT 1 FROM "progress_logs" AS other
    WHERE other."run_id" = closing."run_id" AND other."closing" = false
  );
