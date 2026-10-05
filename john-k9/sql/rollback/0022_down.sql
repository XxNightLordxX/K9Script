-- =====================================================================
-- john-k9 :: ROLLBACK 0022 :: k9_wellbeing
--
-- Would reverse:
--   sql/migrations/0022_create_k9_wellbeing.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0001_down.sql/
-- 0002_down.sql/0007_down.sql/0008_down.sql/0011_down.sql/0013_down.sql/
-- 0015_down.sql/0016_down.sql/0018_down.sql/0019_down.sql/0020_down.sql,
-- same reason. It is not unfinished.
--
-- Migration 0022 does exactly one thing: CREATE TABLE `k9_wellbeing`. The
-- only way to "undo" a CREATE TABLE is to DROP that table, and dropping it
-- deletes every row in it -- every online K9's current fatigue, mood,
-- fear/stress, injury, hunger and thirst, all at once, with no way to
-- rebuild any of it from anything else in the database. Unlike a pure
-- audit/history table, losing this one has an IMMEDIATE gameplay
-- consequence, not just a lost record: the next time each affected
-- citizenid's row is referenced, server/wellbeing.lua's own
-- K9Store.Wellbeing_Get finds no row and falls back to fresh defaults --
-- exactly as if every K9 with a row in this table had just had its
-- condition silently reset. That is precisely the bug this table exists
-- to fix, so undoing it by dropping the table would be reintroducing that
-- exact bug on demand.
--
-- So this file refuses to do it, and no rollback script in this directory
-- will ever drop a table. Destroying data is a separate, deliberate,
-- clearly-labelled decision, and it lives in exactly one file:
-- sql/rollback/uninstall_all.sql, which is inert until you personally arm
-- it. That separation is the entire safety design: you cannot lose your
-- data by running the wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want K9 wellbeing to stop being saved to the database? Set
--     `Config.Wellbeing.Persistence.enabled = false` in config.lua (or
--     `Config.Database.enabled = false` to turn off ALL database
--     persistence resource-wide) and leave this table alone -- every
--     already-saved row stays exactly as it is, ready to resume being
--     read/written the moment the flag is back on, and every OTHER
--     wellbeing feature keeps working normally in the meantime (this
--     resource degrades to session-memory-only for this one table, never
--     an error).
--   * Genuinely want this table gone? `k9_wellbeing` is now a real entry in
--     sql/preflight_check.sql, sql/migration_status.sql,
--     sql/rollback/uninstall_all.sql, sql/rollback/backup_k9_tables.sh,
--     server/datastore.lua's EXPECTED_TABLE_COLUMNS, and sql/install.sql
--     itself (see migration 0022's own header, "CROSS-FILE DEPENDENCY,"
--     for the full landing history -- this migration shipped one pass
--     before that wiring did, disclosed as such at the time). Run
--     sql/rollback/backup_k9_tables.sh FIRST, then arm and run
--     sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS -- it reports what
-- the table currently holds so you can make an informed decision, and it
-- changes nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0022_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0022_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_wellbeing';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_wellbeing does not exist in this database. Migration 0022 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_wellbeing`;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS wellbeing_rows_this_would_destroy,
               'This script never drops a table. Those rows are every tracked K9''s current fatigue/mood/fear-stress/injury/hunger/thirst and cannot be rebuilt from anything else -- dropping this table resets that condition to fresh for every one of them. To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0022_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0022_report`;

-- HOUSEKEEPING: migration 0022 defines no stored procedure of its own
-- (it is a bare CREATE TABLE IF NOT EXISTS) -- nothing of 0022's own to
-- sweep here. This file's own reporting procedure is already dropped
-- immediately above.
