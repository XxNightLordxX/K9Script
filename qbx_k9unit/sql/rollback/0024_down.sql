-- =====================================================================
-- qbx_k9unit :: ROLLBACK 0024 :: k9_role_audit
--
-- Would reverse:
--   sql/migrations/0024_create_k9_role_audit.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0022_down.sql
-- and the other create-table rollbacks, same reason. It is not unfinished.
--
-- Migration 0024 does exactly one thing: CREATE TABLE `k9_role_audit`. The only
-- way to undo that is to DROP the table, which deletes the whole history of role edits, which cannot be rebuilt from anything else. No rollback
-- script in this directory ever drops a table; that lives only in
-- sql/rollback/uninstall_all.sql, which is inert until you arm it.
--
-- WHAT TO DO INSTEAD: leave the table alone; it only grows when a role is edited.
--
-- Running this file is always harmless. It only READS.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0024_report`;
DELIMITER $$
CREATE PROCEDURE `qbx_k9unit_rollback_0024_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_role_audit';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_role_audit does not exist in this database. Migration 0024 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_role_audit`;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS rows_this_would_destroy,
               'This script never drops a table. To remove it anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `qbx_k9unit_rollback_0024_report`();
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0024_report`;
