-- =====================================================================
-- john-k9 :: ROLLBACK 0013 :: k9_permission_keys / k9_permission_key_audit
--
-- Would reverse:
--   sql/migrations/0013_create_k9_permission_keys.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as
-- 0001_down.sql/0002_down.sql/0005_down.sql/0007_down.sql/0010_down.sql/
-- 0011_down.sql, same reason. It is not unfinished.
--
-- Migration 0013 does exactly two things: CREATE TABLE x2. Undoing a
-- CREATE TABLE means DROPping it, which deletes every row. For these two
-- tables specifically:
--
--   * k9_permission_keys holds every permission-key catalog OVERRIDE,
--     ADDITION, and DELETION (tombstone) high command has made relative to
--     config.lua's own Config.Permissions defaults, RIGHT NOW.
--     Dropping it does not just lose history:
--     server/permissionkeycatalog.lua re-merges this table on top of
--     Config.Permissions at its own onResourceStart time (this is
--     precisely what makes a permission-key edit survive a restart, per
--     this feature's own explicit requirement), so dropping this table
--     and restarting the resource SILENTLY REVERTS every custom key, every
--     relabel, and every tombstoned (high-command-deleted) legacy key back
--     to whatever Config.Permissions alone says -- including UN-DELETING a
--     key high command deliberately removed. A genuine behavior change to
--     a live server, not merely an audit-trail loss.
--   * k9_permission_key_audit is the full "who changed the permission-key
--     catalog, and how" trail for every create/update/restore/delete ever
--     made. Not recomputable from the table above, which only ever holds
--     CURRENT state, never history.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want permission-key catalog editing to stop being possible
--     from the tablet? server/permissionkeycatalog.lua's mutating
--     callbacks re-verify IsHighCommand() server-side on every call -- if
--     NO officer on your server currently qualifies as high command
--     (Config.Features.HighCommand = false, or
--     Config.Departments[...].highCommandGrade left unset for every
--     department), the catalog is already effectively read-only in
--     practice, and every row in both tables stays exactly as it is,
--     ready to keep applying (or to resume being editable the moment a
--     high-command officer exists again).
--   * A SPECIFIC key edit needs undoing (e.g. someone tombstoned a
--     permission key by mistake)? Re-add the same key through the tablet
--     -- server/permissionkeycatalog.lua's UpsertKey flips a tombstoned
--     key's `deleted` flag back to 0 and restores it. This is much
--     narrower and safer than dropping a whole table.
--   * Genuinely want one or both of these two tables gone? Run
--     sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
--     rolling back" section -- report to the sql/** owner that these two table names need
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
-- migration 0013's own header -- but every other table in this schema
-- already does, so a database that could apply 0013 in the first place
-- already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0013_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0013_report`()
BEGIN
    DECLARE keys_exists INT DEFAULT 0;
    DECLARE audit_exists INT DEFAULT 0;

    DECLARE keys_rows BIGINT DEFAULT 0;
    DECLARE audit_rows BIGINT DEFAULT 0;
    DECLARE tombstoned_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO keys_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_permission_keys';
    SELECT COUNT(*) INTO audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_permission_key_audit';

    IF keys_exists = 0 AND audit_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Neither migration-0013 table exists in this database. Migration 0013 was either never applied here, or both have already been removed.' AS detail;
    ELSE
        IF keys_exists = 1 THEN
            SELECT COUNT(*) INTO keys_rows FROM `k9_permission_keys`;
            SELECT COUNT(*) INTO tombstoned_rows FROM `k9_permission_keys` WHERE `deleted` = 1;
        END IF;
        IF audit_exists = 1 THEN SELECT COUNT(*) INTO audit_rows FROM `k9_permission_key_audit`; END IF;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               keys_exists AS k9_permission_keys_present,
               keys_rows AS permission_key_override_rows_this_would_silently_revert_on_next_restart,
               tombstoned_rows AS of_which_tombstoned_deleted_keys_that_would_silently_UNDELETE,
               audit_exists AS k9_permission_key_audit_present,
               audit_rows AS audit_rows_this_would_destroy,
               'This script never drops a table. See this file''s own header for exactly what each table costs to lose and what to do instead (usually: re-edit the specific key through the tablet, not drop the table). To remove these tables anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0013_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0013_report`;

-- HOUSEKEEPING: migration 0013 defines no stored procedure of its own
-- (every statement in it is a bare CREATE TABLE IF NOT EXISTS) -- nothing
-- of 0013's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
