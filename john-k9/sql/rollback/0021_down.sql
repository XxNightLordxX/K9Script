-- =====================================================================
-- john-k9 :: ROLLBACK 0021 :: remove k9_individual_overrides.sprint_decay_per_tick
--
-- Reverses EXACTLY ONE migration:
--   sql/migrations/0021_add_k9_individual_overrides_sprint_decay.sql
--
-- WHAT THIS REMOVES:
--   * COLUMN `sprint_decay_per_tick` on `k9_individual_overrides`
--
-- ///////////////////////////////////////////////////////////////////////
-- !! THIS IS A ROLLBACK THAT LOSES INFORMATION -- READ IT, SAME AS 0003/0006/0017 !!
--
-- No ROWS are deleted, and no other column on `k9_individual_overrides`
-- is touched -- every dog's `speed_multiplier`, `scent_range_multiplier`,
-- `medkit_cooldown_multiplier` and `note` survive this file untouched.
--
-- But `sprint_decay_per_tick` is real, hand-authored operator data, not
-- something derived that can be recomputed -- exactly like migration
-- 0006's `tier` and 0017's `handler_xp` (see those rollbacks' own headers
-- for the identical warning, mirrored here deliberately):
--
--   * DROPping it loses every per-dog stamina decision high command has
--     made. Re-applying migration 0021 afterward brings the column back
--     as NULL for EVERY row -- each of those dogs silently falls back to
--     the server-wide stamina setting, and nothing anywhere records that
--     it used to have its own.
--   * THE CASE THAT HURTS MOST: a dog set to exactly 0, meaning stamina
--     that NEVER RUNS OUT. That is the single most deliberate setting on
--     this table and the one an operator is most likely to have chosen
--     for a reason. After this rollback that dog gets tired like any
--     other, with no error and nothing in the log -- it will look like
--     the feature broke rather than like a rollback did it.
--
-- ==> RUN THE BACKUP FIRST if you want any chance of recovering these
--     values. sql/rollback/backup_k9_tables.sh captures
--     `k9_individual_overrides` in full, including this column; nothing
--     else does, and it is not run for you.
--
-- WHAT STILL WORKS AFTER THIS ROLLBACK: everything. The per-dog stamina
-- override does not disappear as a FEATURE -- server/k9profiles.lua keeps
-- accepting it and holding it in memory for the rest of the server's
-- uptime, exactly as it behaved before migration 0021 existed. It simply
-- stops surviving a restart again. Nothing errors, nothing refuses; you
-- are back to the previous, disclosed limitation.
-- ///////////////////////////////////////////////////////////////////////
--
-- IDEMPOTENT / SAFE TO RE-RUN: INFORMATION_SCHEMA-guarded, same shape as
-- the migration it reverses. Running it twice, or against a database that
-- never had the column, is a clean no-op rather than an error.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0021_drop_sprint_decay_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0021_drop_sprint_decay_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_individual_overrides'
          AND COLUMN_NAME = 'sprint_decay_per_tick'
    ) THEN
        ALTER TABLE `k9_individual_overrides`
            DROP COLUMN `sprint_decay_per_tick`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0021_drop_sprint_decay_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0021_drop_sprint_decay_column`;
