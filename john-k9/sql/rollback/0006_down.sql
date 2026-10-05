-- =====================================================================
-- john-k9 :: ROLLBACK 0006 :: k9_certifications tier/revoke_reason/
--                                 expires_at columns + idx_expires_at
--                                 (does NOT drop k9_certification_specializations)
--
-- Reverses PART of exactly one migration:
--   sql/migrations/0006_add_k9_certification_lifecycle.sql
--
-- WHAT THIS REMOVES:
--   * KEY     `idx_expires_at`   (on k9_certifications)
--   * COLUMN  `expires_at`       (on k9_certifications)
--   * COLUMN  `revoke_reason`    (on k9_certifications)
--   * COLUMN  `tier`             (on k9_certifications)
--
-- WHAT THIS DELIBERATELY DOES NOT TOUCH:
--   * `k9_certification_specializations` (the whole new table) --
--     see "TABLE NOT DROPPED" below.
--
-- ///////////////////////////////////////////////////////////////////////
-- !! THIS IS A ROLLBACK THAT LOSES INFORMATION -- READ IT, SAME AS 0003 !!
--
-- No ROWS are deleted, and no other column on `k9_certifications` is
-- touched. But UNLIKE migration 0004's `active_cert_key` (a VIRTUAL
-- generated column, computed on read, safe to drop), `tier`,
-- `revoke_reason`, and `expires_at` are ALL real, independently-written,
-- non-derived data -- exactly like migration 0003's
-- `tenure_bonus_tier_granted` (see that rollback's own header for the
-- identical warning shape, mirrored here on purpose):
--
--   * DROPping `tier` loses every promotion/demotion decision an operator
--     ever made (who is 'trainee', who is 'senior') -- re-applying
--     migration 0006 afterwards resets EVERY row back to the DEFAULT
--     'certified', silently un-promoting every senior handler and
--     un-demoting every trainee back to full access.
--   * DROPping `revoke_reason` loses every categorized revoke reason
--     (retired / reassigned / disciplinary / performance / other) ever
--     recorded -- gone permanently; re-applying migration 0006 cannot
--     recover it (the column comes back NULL for every row, including
--     ones that used to have a real reason).
--   * DROPping `expires_at` loses every certification's real expiry
--     deadline, including ones already renewed/extended by an operator --
--     re-applying migration 0006 brings the column back NULL for every
--     row (i.e. "never expires" for everyone) until each one is granted
--     or renewed again.
--
-- ==> RUN THE BACKUP FIRST. sql/rollback/backup_k9_tables.sh captures
--     these columns' values; nothing else does, and they are not
--     reconstructible from any other table or column. See README.md's
--     "Uninstalling / rolling back" section.
-- ///////////////////////////////////////////////////////////////////////
--
-- TABLE NOT DROPPED: `k9_certification_specializations` is an independent
-- audit-trail table, same class as `k9_permissions` (migration 0005) --
-- it is the full grant/revoke history of every K9 specialization ever
-- issued, not recomputable from `k9_certifications` or any other table.
-- This file follows 0005_down.sql's own precedent exactly: report what
-- dropping it would cost, and do not do it. See the REPORT-ONLY block at
-- the bottom of this file.
--
-- WHY NOT JUST DISABLE THE FEATURE INSTEAD OF ROLLING BACK: for `tier`
-- and `revoke_reason`, there is no feature flag to flip -- both are
-- always-on, additive dimensions of the SAME certification row a plain
-- boolean cert already needed (a `tier` of 'certified' with no
-- specializations behaves identically to today's pre-0006 shape; nothing
-- to disable). For `expires_at`, the equivalent of "just disable it" IS
-- available and does NOT require running this file at all: set
-- `Config.Features.CertificationExpiry = false`. That stops any NEW
-- expires_at from ever being set and makes server/certifications.lua's
-- own expiry checks/warnings/sweep a total no-op immediately, while
-- leaving every already-recorded expires_at value intact in the
-- database for if the feature is turned back on later. Prefer that over
-- this file unless you specifically need the COLUMN gone (e.g. a
-- third-party tool chokes on its presence).
--
-- SAFE TO RE-RUN. Same INFORMATION_SCHEMA-guarded stored procedure
-- pattern as every other rollback in this directory, for the identical
-- portability reason (`DROP COLUMN IF EXISTS` / `DROP INDEX IF EXISTS`
-- are MariaDB-only / MySQL 8.0.29+ only). A second run is a guaranteed
-- clean no-op: each guard sees the object already gone and skips its
-- ALTER.
--
-- ORDER MATTERS: `idx_expires_at` is dropped BEFORE the `expires_at`
-- column it indexes, same "index before the column it depends on"
-- ordering rule migration 0004's own rollback follows. `tier` and
-- `revoke_reason` have no index depending on them, so their order
-- relative to each other and to the idx_expires_at/expires_at pair does
-- not matter.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1 of 4: drop KEY `idx_expires_at`
-- (must come before dropping the `expires_at` column it indexes)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_idx_expires_at`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0006_drop_idx_expires_at`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'idx_expires_at'
    ) THEN
        ALTER TABLE `k9_certifications` DROP INDEX `idx_expires_at`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0006_drop_idx_expires_at`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_idx_expires_at`;


-- ---------------------------------------------------------------------
-- STEP 2 of 4: drop COLUMN `expires_at`
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_expires_at_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0006_drop_expires_at_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'expires_at'
    ) THEN
        ALTER TABLE `k9_certifications` DROP COLUMN `expires_at`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0006_drop_expires_at_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_expires_at_column`;


-- ---------------------------------------------------------------------
-- STEP 3 of 4: drop COLUMN `revoke_reason`
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_revoke_reason_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0006_drop_revoke_reason_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'revoke_reason'
    ) THEN
        ALTER TABLE `k9_certifications` DROP COLUMN `revoke_reason`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0006_drop_revoke_reason_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_revoke_reason_column`;


-- ---------------------------------------------------------------------
-- STEP 4 of 4: drop COLUMN `tier`
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_tier_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0006_drop_tier_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'tier'
    ) THEN
        ALTER TABLE `k9_certifications` DROP COLUMN `tier`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0006_drop_tier_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_drop_tier_column`;


-- ---------------------------------------------------------------------
-- REPORT-ONLY: k9_certification_specializations is never dropped by this
-- file -- see "TABLE NOT DROPPED" above. Mirrors 0005_down.sql's own
-- report-only block exactly.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_report_specializations`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0006_report_specializations`()
BEGIN
    DECLARE tbl_exists INT DEFAULT 0;
    DECLARE rows_held BIGINT DEFAULT 0;
    DECLARE active_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tbl_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'k9_certification_specializations';

    IF tbl_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Table k9_certification_specializations does not exist in this database. Migration 0006 was either never applied here, or the table has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO rows_held FROM `k9_certification_specializations`;
        SELECT COUNT(*) INTO active_rows FROM `k9_certification_specializations` WHERE `active` = 1;
        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               rows_held AS specialization_grant_rows_this_would_destroy,
               active_rows AS of_which_currently_active_grants,
               'This script never drops a table. Those rows are the full grant/revoke history of every K9 specialization ever issued, and the active ones are live capability state that server/search.lua-style gates may already be reading -- dropping this table would erase that history and silently strip every currently-held specialization. To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0006_report_specializations`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0006_report_specializations`;


-- ---------------------------------------------------------------------
-- HOUSEKEEPING: clear any migration/rollback procedure left behind by an
-- earlier run that died partway through (same rationale as 0004_down.sql's
-- housekeeping block).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_tier_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_revoke_reason_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_expires_at_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_idx_expires_at`;
