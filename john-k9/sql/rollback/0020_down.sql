-- =====================================================================
-- john-k9 :: ROLLBACK 0020 :: k9_personnel
--
-- Would reverse:
--   sql/migrations/0020_create_k9_personnel.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0007_down.sql/
-- 0008_down.sql/0011_down.sql/0013_down.sql/0015_down.sql/0016_down.sql/
-- 0018_down.sql before it, same reason. It is not unfinished.
--
-- Migration 0020 does exactly one thing: CREATE TABLE. Undoing a CREATE
-- TABLE means DROPping it, which deletes every row. This table holds
-- which roster (K9 or Handler) every currently-assigned citizenid belongs
-- to per department, and their current callsign -- see that migration's
-- own header for the full design. Dropping it does not just lose history:
-- every currently-assigned K9/handler would fall back into the
-- "Unassigned" bucket the moment this resource next reads the roster
-- (there is no row left to say which list they belong on), and every
-- currently-held callsign would be forgotten. Nobody's actual in-game
-- abilities change either way -- this table has never been the thing that
-- decides whether a citizenid can act as a K9/handler, only which ROSTER
-- LIST they show up on and what callsign they answer to -- but the
-- roster-organization work itself would be lost and would have to be
-- redone by hand, department by department.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD: there is no legitimate reason to want this table
-- gone while keeping the roster feature installed -- reassigning a
-- citizenid back to the correct roster/callsign from the tablet costs a
-- few clicks and does not need this file. Genuinely uninstalling this
-- resource entirely? Run sql/rollback/backup_k9_tables.sh FIRST
-- (README.md's "Uninstalling / rolling back" section), then arm and run
-- sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own table does not individually need that floor, but
-- every other table in this schema already does, so a database that could
-- apply 0020 in the first place already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0020_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0020_report`()
BEGIN
    DECLARE personnel_exists INT DEFAULT 0;
    DECLARE personnel_rows BIGINT DEFAULT 0;
    DECLARE personnel_active_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO personnel_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_personnel';

    IF personnel_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'k9_personnel does not exist in this database. Migration 0020 was either never applied here, or has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO personnel_rows FROM `k9_personnel`;
        SELECT COUNT(*) INTO personnel_active_rows FROM `k9_personnel` WHERE `active` = 1;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               personnel_exists AS k9_personnel_present,
               personnel_rows AS total_rows_ever_written,
               personnel_active_rows AS currently_assigned_roster_rows_this_would_send_back_to_unassigned,
               'This script never drops a table. See this file''s own header for exactly what dropping this table would cost. To remove it anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0020_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0020_report`;

-- HOUSEKEEPING: migration 0020 defines no stored procedure of its own
-- (its only statement is a bare CREATE TABLE IF NOT EXISTS) -- nothing of
-- 0020's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
