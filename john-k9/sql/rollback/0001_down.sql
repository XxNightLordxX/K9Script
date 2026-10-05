-- =====================================================================
-- john-k9 :: ROLLBACK 0001 :: k9_partnerships
--
-- Would reverse:
--   sql/migrations/0001_create_k9_partnerships.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0002_down.sql,
-- same reason. It is not unfinished.
--
-- Migration 0001 does exactly one thing: CREATE TABLE `k9_partnerships`.
-- Undoing a CREATE TABLE means DROPping it, which deletes every row --
-- the full history of who was partnered with whom, when it started, who
-- ended it and when. That is audit history. It is not recomputable from
-- anything else in the database.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert until
-- you personally arm it. You cannot lose your data by running the wrong
-- rollback file.
--
-- IF YOU CAME HERE TO UNDO THE COLUMN ADDED BY MIGRATION 0003 (the
-- tenure-bonus column on this same table), that is a different file and it
-- DOES do real work: sql/rollback/0003_down.sql.
--
-- WHAT TO DO INSTEAD:
--   * Just want the resource to stop using the table? Stop the resource
--     and leave the table alone.
--   * Genuinely want it gone? Run sql/rollback/backup_k9_tables.sh FIRST
--     (README.md's "Uninstalling / rolling back" section), then arm and run
--     sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0001_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0001_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_partnerships';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_partnerships does not exist in this database. Migration 0001 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_partnerships`;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS partnership_rows_this_would_destroy,
               'This script never drops a table. Those rows are the audit history of every K9/handler partnership ever formed. To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql. To undo only migration 0003''s tenure column on this table, use 0003_down.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0001_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0001_report`;
