-- =====================================================================
-- john-k9 :: ROLLBACK 0018 :: k9_partnership_pair_progress
--
-- Would reverse:
--   sql/migrations/0018_create_k9_partnership_pair_progress.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0007_down.sql/
-- 0008_down.sql/0011_down.sql/0013_down.sql/0015_down.sql/0016_down.sql
-- before it, same reason. It is not unfinished.
--
-- Migration 0018 does exactly one thing: CREATE TABLE. Undoing a CREATE
-- TABLE means DROPping it, which deletes every row. This table holds the
-- highest partnership-tenure milestone tier each EXACT (K9, handler) pair
-- has ever confirmed-earned -- the fully durable half of the
-- partnership-tenure anti-farm guard (server/partnership.lua's
-- CaptureTenureSeedForPair / the establish critical section's own seed
-- read; see this migration's own header for the full design). Dropping it
-- does not just lose history: it reopens exactly the gap this migration
-- exists to close. A pair that already earned a milestone, then breaks and
-- reforms after this table is dropped, would be able to re-earn that same
-- milestone again -- the resource still runs fine either way (every read
-- of a missing row degrades to "never earned anything," never an error),
-- it just silently stops protecting against that one exploit for every
-- pair whose row is gone.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD: there is no legitimate reason to want this table
-- gone while keeping the rest of this resource installed -- it has no
-- tablet UI, no admin edit path, and costs nothing to keep (one small row
-- per pair that has ever earned a milestone, written automatically).
-- Genuinely uninstalling this resource entirely? Run
-- sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
-- rolling back" section), then arm and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own table does not individually need that floor, but
-- every other table in this schema already does, so a database that could
-- apply 0018 in the first place already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0018_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0018_report`()
BEGIN
    DECLARE progress_exists INT DEFAULT 0;
    DECLARE progress_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO progress_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_partnership_pair_progress';

    IF progress_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'k9_partnership_pair_progress does not exist in this database. Migration 0018 was either never applied here, or has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO progress_rows FROM `k9_partnership_pair_progress`;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               progress_exists AS k9_partnership_pair_progress_present,
               progress_rows AS pairs_that_would_lose_their_earned_anti_farm_protection,
               'This script never drops a table. See this file''s own header for exactly what dropping this table would reopen. To remove it anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0018_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0018_report`;

-- HOUSEKEEPING: migration 0018 defines no stored procedure of its own
-- (its only statement is a bare CREATE TABLE IF NOT EXISTS) -- nothing of
-- 0018's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
