-- =====================================================================
-- john-k9 :: ROLLBACK 0002 :: k9_progression
--
-- Would reverse:
--   sql/migrations/0002_create_k9_progression.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING. That is not a bug, and it is not
-- an unfinished file. Read the next paragraph before looking for the
-- "real" version of this script -- there isn't one, on purpose.
--
-- Migration 0002 does exactly one thing: CREATE TABLE `k9_progression`.
-- The only way to "undo" a CREATE TABLE is to DROP that table, and
-- dropping it deletes every row in it -- every player's accumulated K9 XP,
-- permanently, with no way to rebuild it from anything else in the
-- database. XP is earned over weeks of play; it is not recomputable.
--
-- So this file refuses to do it, and no rollback script in this directory
-- will ever drop a table. Destroying data is a separate, deliberate,
-- clearly-labelled decision, and it lives in exactly one file:
-- sql/rollback/uninstall_all.sql, which is inert until you personally arm
-- it. That separation is the entire safety design: you cannot lose your
-- data by running the wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want the resource to stop using the table? Stop the resource.
--     Leave the table alone. It costs nothing to keep and it is your only
--     copy of everyone's XP.
--   * Genuinely want it gone? Run sql/rollback/backup_k9_tables.sh FIRST
--     (README.md's "Uninstalling / rolling back" section), then arm and run
--     sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS -- it reports what
-- the table currently holds so you can make an informed decision, and it
-- changes nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0002_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0002_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_progression';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_progression does not exist in this database. Migration 0002 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_progression`;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS xp_rows_this_would_destroy,
               'This script never drops a table. Those rows are every player''s accumulated K9 XP and cannot be rebuilt from anything else. To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0002_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0002_report`;

-- HOUSEKEEPING: clear a migration procedure left behind by a half-finished
-- earlier run (same rationale as 0004_down.sql's housekeeping block).
-- Migration 0002 is a bare CREATE TABLE and defines no procedure of its
-- own, so there is nothing of 0002's to sweep here -- this file's own
-- reporting procedure is already dropped immediately above.
