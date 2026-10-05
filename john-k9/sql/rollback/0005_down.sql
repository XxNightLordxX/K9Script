-- =====================================================================
-- john-k9 :: ROLLBACK 0005 :: k9_permissions
--
-- Would reverse:
--   sql/migrations/0005_create_k9_permissions.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0001_down.sql and
-- 0002_down.sql, same reason. It is not unfinished.
--
-- Migration 0005 does exactly one thing: CREATE TABLE `k9_permissions`.
-- Undoing a CREATE TABLE means DROPping it, which deletes every row -- the
-- full history of who granted which named capability (k9.access,
-- k9.certify, k9.audit, k9.givexp, or any later addition to
-- Config.Permissions) to which handler or K9, and who took it away and
-- when. That is an AUTHORIZATION AUDIT TRAIL. It is not recomputable from
-- anything else in the database -- unlike k9_certifications' job-rank
-- grants, there is no separate "current permission state" recorded
-- anywhere else (not in qbx_core metadata, not in another john-k9
-- table) that this table's rows could be reconstructed from if lost.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert until
-- you personally arm it. You cannot lose your data by running the wrong
-- rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want the resource to stop granting/checking named permissions?
--     Set `Config.Features.PermissionGrants = false` and leave the table
--     alone -- per config.lua's own header, grants are purely ADDITIVE
--     (they only ever widen access on top of rank, never narrow it), so
--     turning the feature off costs nothing and every existing grant row
--     stays intact for whenever it's turned back on.
--   * Genuinely want the table gone? Run sql/rollback/backup_k9_tables.sh
--     FIRST (README.md's "Uninstalling / rolling back" section), then arm
--     and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0005_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0005_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;
    DECLARE active_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_permissions';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_permissions does not exist in this database. Migration 0005 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_permissions`;
        SELECT COUNT(*) INTO active_rows FROM `k9_permissions` WHERE `active` = 1;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS permission_grant_rows_this_would_destroy,
               active_rows AS of_which_currently_active_grants,
               'This script never drops a table. Those rows are the full grant/revoke history of every named K9 permission ever issued, and the active ones are live access-control state -- dropping this table would both erase the audit trail and silently strip every currently-granted permission (server/permissions.lua would then fall back to high-command/rank gating alone for everyone). To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0005_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0005_report`;

-- HOUSEKEEPING: clear a migration procedure left behind by a half-finished
-- earlier run (same rationale as 0004_down.sql's housekeeping block).
-- Migration 0005 is a bare CREATE TABLE and defines no procedure of its
-- own, so there is nothing of 0005's to sweep here -- this file's own
-- reporting procedure is already dropped immediately above.
