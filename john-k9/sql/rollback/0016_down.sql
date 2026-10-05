-- =====================================================================
-- john-k9 :: ROLLBACK 0016 :: k9_individual_overrides /
--                                 k9_individual_override_audit
--
-- Would reverse:
--   sql/migrations/0016_create_k9_individual_overrides.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0007_down.sql/
-- 0008_down.sql/0011_down.sql/0013_down.sql/0015_down.sql before it, same
-- reason. It is not unfinished.
--
-- Migration 0016 does exactly two things: CREATE TABLE x2. Undoing a
-- CREATE TABLE means DROPping it, which deletes every row. For these two
-- tables specifically:
--
--   * k9_individual_overrides holds every high-command-edited per-
--     citizenid speed/scent/medkit-cooldown override, RIGHT NOW, layered on
--     top of whatever XP-tier profile each citizenid otherwise resolves to.
--     Dropping it does not just lose history: server/k9profiles.lua's own
--     onResourceStart handler re-reads this table on every resource start
--     to warm its in-memory cache, so a fresh boot after this table is
--     dropped means EVERY previously hand-tuned K9 silently reverts to its
--     plain XP-tier values with no warning. A real behavior change to a
--     live server (a K9 someone deliberately sped up or slowed down for a
--     documented reason snaps back the moment this resource next
--     restarts), not merely an audit-trail loss. A citizenid that never had
--     an override is completely unaffected either way.
--   * k9_individual_override_audit is the full "who changed which K9's
--     override, and how" trail. Not recomputable from
--     k9_individual_overrides, which only ever holds the CURRENT override
--     (or its tombstoned absence), never the history of what it used to be
--     before an earlier edit or reset.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want one specific K9 back to its plain XP-tier values? Re-open
--     the K9 Command Tablet's individual-override screen and reset that
--     citizenid's override -- no table needs to be touched or dropped for
--     this (this action tombstones the row, it does not need this file).
--   * Genuinely want one or both of these two tables gone? Run
--     sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
--     rolling back" section), then arm and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own tables do not individually need that floor, but
-- every other table in this schema already does, so a database that could
-- apply 0016 in the first place already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0016_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0016_report`()
BEGIN
    DECLARE overrides_exists INT DEFAULT 0;
    DECLARE overrides_audit_exists INT DEFAULT 0;

    DECLARE override_rows BIGINT DEFAULT 0;
    DECLARE override_audit_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO overrides_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_individual_overrides';
    SELECT COUNT(*) INTO overrides_audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_individual_override_audit';

    IF overrides_exists = 0 AND overrides_audit_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Neither migration-0016 table exists in this database. Migration 0016 was either never applied here, or both have already been removed.' AS detail;
    ELSE
        IF overrides_exists = 1 THEN SELECT COUNT(*) INTO override_rows FROM `k9_individual_overrides`; END IF;
        IF overrides_audit_exists = 1 THEN SELECT COUNT(*) INTO override_audit_rows FROM `k9_individual_override_audit`; END IF;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               overrides_exists AS k9_individual_overrides_present,
               override_rows AS individual_k9_overrides_this_would_silently_revert,
               overrides_audit_exists AS k9_individual_override_audit_present,
               override_audit_rows AS audit_rows_this_would_destroy,
               'This script never drops a table. See this file''s own header for exactly what each table costs to lose and what to do instead (usually: leave the table alone, reset the override from the tablet instead). To remove these tables anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0016_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0016_report`;

-- HOUSEKEEPING: migration 0016 defines no stored procedure of its own
-- (every statement in it is a bare CREATE TABLE IF NOT EXISTS) -- nothing
-- of 0016's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
