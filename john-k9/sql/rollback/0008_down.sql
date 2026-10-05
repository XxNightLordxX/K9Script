-- =====================================================================
-- john-k9 :: ROLLBACK 0008 :: k9_ped_assignments
--
-- Would reverse:
--   sql/migrations/0008_create_k9_ped_assignments.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING, same as sql/rollback/0002_down.sql
-- and sql/rollback/0007_down.sql before it. Read the next paragraph before
-- looking for the "real" version of this script -- there isn't one, on
-- purpose.
--
-- Migration 0008 does exactly one thing: CREATE TABLE `k9_ped_assignments`.
-- The only way to "undo" a CREATE TABLE is to DROP it, and dropping THIS
-- table specifically means every currently-applied K9's ORIGINAL
-- appearance record is gone. That is not a cosmetic loss: it is the one
-- piece of state that lets a future revoke put a K9 back to what they
-- actually looked like before they were ever swapped, instead of falling
-- back to Config.K9Appearance.fallbackHumanModel for someone that fallback
-- was never meant for. A currently-active K9 whose row is dropped this way
-- is not stuck as an animal (server/appearance.lua's own MaybeRevertK9Appearance
-- still runs and still reverts them, just to the fallback model instead of
-- their real original) -- but the "instead of their real original" part is
-- exactly the kind of quiet, permanent, unrecoverable loss this resource's
-- rollback scripts refuse to cause silently.
--
-- So this file refuses to drop it, and no rollback script in this
-- directory will ever drop a table. Destroying data is a separate,
-- deliberate, clearly-labelled decision, and it lives in exactly one file:
-- sql/rollback/uninstall_all.sql, which is inert until you personally arm
-- it. That separation is the entire safety design: you cannot lose your
-- data by running the wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want the FEATURE off? Set Config.K9Appearance.applyPedModelOnCertify
--     to false. Every currently-applied K9 keeps whatever model they are
--     currently wearing (this resource never reverts anyone on its own
--     initiative) -- this table simply stops being written to or read from
--     going forward. No SQL needed at all.
--   * Genuinely want the table gone? Run sql/rollback/backup_k9_tables.sh
--     FIRST (README.md's "Uninstalling / rolling back" section), then arm
--     and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS -- it reports what
-- the table currently holds so you can make an informed decision, and it
-- changes nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0008_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0008_report`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;
    DECLARE active_rows BIGINT DEFAULT 0;
    DECLARE rows_missing_original BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_ped_assignments';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_ped_assignments does not exist in this database. Migration 0008 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_ped_assignments`;
        SELECT COUNT(*) INTO active_rows FROM `k9_ped_assignments` WHERE `active` = 1;
        SELECT COUNT(*) INTO rows_missing_original FROM `k9_ped_assignments` WHERE `original_model_hash` IS NULL;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS total_rows_this_would_destroy,
               active_rows AS currently_applied_k9s_that_would_lose_their_real_original_appearance,
               rows_missing_original AS rows_with_no_original_captured_yet,
               'This script never drops a table. Dropping k9_ped_assignments does not strand anyone as an animal (a future revoke still falls back to Config.K9Appearance.fallbackHumanModel), but it does permanently lose the REAL original appearance for every row above -- they would be reverted to the fallback instead of what they actually looked like. To disable the feature without losing this data, set Config.K9Appearance.applyPedModelOnCertify to false instead. To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0008_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0008_report`;

-- HOUSEKEEPING: migration 0008 defines no stored procedure of its own (a
-- bare CREATE TABLE IF NOT EXISTS) -- nothing of 0008's own to sweep here;
-- this file's own reporting procedure is already dropped immediately
-- above.
