-- =====================================================================
-- john-k9 :: ROLLBACK 0010 :: k9_certification_tiers /
--                                 k9_certification_tier_capabilities /
--                                 k9_certification_tier_audit
--
-- Would reverse:
--   sql/migrations/0010_create_k9_certification_tiers.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as
-- 0001_down.sql/0002_down.sql/0005_down.sql/0007_down.sql, same reason.
-- It is not unfinished.
--
-- Migration 0010 does exactly three things: CREATE TABLE x3. Undoing a
-- CREATE TABLE means DROPping it, which deletes every row. For these
-- three tables specifically:
--
--   * k9_certification_tiers holds every tier-catalog OVERRIDE, ADDITION,
--     and DELETION (tombstone) high command has made relative to
--     config.lua's own Config.CertificationTiers defaults, RIGHT NOW.
--     Dropping it does not just lose history: server/certtiers.lua
--     re-merges this table on top of Config.CertificationTiers at its own
--     onResourceStart time (this is precisely what makes a tier edit
--     survive a restart, per this task's own explicit requirement), so
--     dropping this table and restarting the resource SILENTLY REVERTS
--     every custom tier, every rename, and every tombstoned
--     (high-command-deleted) legacy tier back to whatever
--     Config.CertificationTiers alone says -- including UN-DELETING a
--     tier high command deliberately removed. A genuine behavior change
--     to a live server, not merely an audit-trail loss.
--   * k9_certification_tier_capabilities holds every CURRENT tier ->
--     capability grant. Dropping it silently reverts every tier to
--     holding NO capabilities at all (this table has no config.lua
--     default to fall back to -- see migration 0010's own header:
--     Config.CertificationTiers ships every tier's default capability
--     set EMPTY, on purpose, so this table is the ONLY place any
--     non-empty capability grant has ever lived).
--   * k9_certification_tier_audit is the full "who changed the tier
--     catalog, and how" trail for every create/update/reorder/delete
--     ever made. Not recomputable from the two tables above, which only
--     ever hold CURRENT state, never history.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want tier editing to stop being possible from the tablet?
--     server/certtiers.lua's mutating callbacks re-verify IsHighCommand()
--     server-side on every call -- if NO officer on your server currently
--     qualifies as high command (Config.Features.HighCommand = false, or
--     Config.Departments[...].highCommandGrade left unset for every
--     department), the tier catalog is already effectively read-only in
--     practice, and every row in all three tables stays exactly as it is,
--     ready to keep applying (or to resume being editable the moment a
--     high-command officer exists again).
--   * A SPECIFIC tier edit needs undoing (e.g. someone tombstoned a tier
--     by mistake)? Re-add the same tier key through the tablet (or
--     `/k9tiersetcertification`-equivalent, whatever command surface the
--     tablet owner wires up) -- server/certtiers.lua's UpsertTier flips a
--     tombstoned key's `deleted` flag back to 0 and restores it (at the
--     end of the ordinal list, not its old position -- see that file's
--     own header for why). This is much narrower and safer than dropping
--     a whole table.
--   * Genuinely want one or more of these three tables gone? Run
--     sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
--     rolling back" section -- report to the sql/** owner that these three table names need
--     adding to that script's own table list and to
--     sql/rollback/uninstall_all.sql, neither of which this file edits),
--     then arm and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own tables do not individually need that floor -- see
-- migration 0010's own header -- but every other table in this schema
-- already does, so a database that could apply 0010 in the first place
-- already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0010_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0010_report`()
BEGIN
    DECLARE tiers_exists INT DEFAULT 0;
    DECLARE caps_exists INT DEFAULT 0;
    DECLARE audit_exists INT DEFAULT 0;

    DECLARE tiers_rows BIGINT DEFAULT 0;
    DECLARE caps_rows BIGINT DEFAULT 0;
    DECLARE audit_rows BIGINT DEFAULT 0;
    DECLARE tombstoned_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tiers_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_certification_tiers';
    SELECT COUNT(*) INTO caps_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_certification_tier_capabilities';
    SELECT COUNT(*) INTO audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_certification_tier_audit';

    IF tiers_exists = 0 AND caps_exists = 0 AND audit_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'None of the three migration-0010 tables exist in this database. Migration 0010 was either never applied here, or all three have already been removed.' AS detail;
    ELSE
        IF tiers_exists = 1 THEN
            SELECT COUNT(*) INTO tiers_rows FROM `k9_certification_tiers`;
            SELECT COUNT(*) INTO tombstoned_rows FROM `k9_certification_tiers` WHERE `deleted` = 1;
        END IF;
        IF caps_exists = 1 THEN SELECT COUNT(*) INTO caps_rows FROM `k9_certification_tier_capabilities`; END IF;
        IF audit_exists = 1 THEN SELECT COUNT(*) INTO audit_rows FROM `k9_certification_tier_audit`; END IF;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               tiers_exists AS k9_certification_tiers_present,
               tiers_rows AS tier_override_rows_this_would_silently_revert_on_next_restart,
               tombstoned_rows AS of_which_tombstoned_deleted_tiers_that_would_silently_UNDELETE,
               caps_exists AS k9_certification_tier_capabilities_present,
               caps_rows AS capability_grant_rows_this_would_silently_revert_to_empty,
               audit_exists AS k9_certification_tier_audit_present,
               audit_rows AS audit_rows_this_would_destroy,
               'This script never drops a table. See this file''s own header for exactly what each table costs to lose and what to do instead (usually: re-edit the specific tier through the tablet, not drop the table). To remove these tables anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0010_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0010_report`;

-- HOUSEKEEPING: migration 0010 defines no stored procedure of its own
-- (every statement in it is a bare CREATE TABLE IF NOT EXISTS) -- nothing
-- of 0010's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
