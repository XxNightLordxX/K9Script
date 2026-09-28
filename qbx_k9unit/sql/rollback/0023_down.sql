-- =====================================================================
-- qbx_k9unit :: ROLLBACK 0023 :: k9_roles
--
-- Would reverse:
--   sql/migrations/0023_create_k9_roles.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0022_down.sql
-- and the other create-table rollbacks, same reason. It is not unfinished.
--
-- Migration 0023 does exactly one thing: CREATE TABLE `k9_roles`. The only
-- way to undo that is to DROP the table, which deletes every role high command created or edited on the tablet (the three shipped roles come back from config.lua; every other change is lost). No rollback
-- script in this directory ever drops a table; that lives only in
-- sql/rollback/uninstall_all.sql, which is inert until you arm it.
--
-- WHAT TO DO INSTEAD: leave the table alone. Nothing reads it unless roles are edited on the tablet.
--
-- Running this file is always harmless. It only READS.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0023_report`;
DELIMITER $$
CREATE PROCEDURE `qbx_k9unit_rollback_0023_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_roles';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_roles does not exist in this database. Migration 0023 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_roles`;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS rows_this_would_destroy,
               'This script never drops a table. To remove it anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `qbx_k9unit_rollback_0023_report`();
DROP PROCEDURE IF EXISTS `qbx_k9unit_rollback_0023_report`;
