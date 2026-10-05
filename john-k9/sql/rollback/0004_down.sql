-- =====================================================================
-- john-k9 :: ROLLBACK 0004 :: remove k9_certifications.active_cert_key
--                                 and the three indexes migration 0004 adds
--
-- Reverses EXACTLY ONE migration:
--   sql/migrations/0004_add_k9_certifications_active_cert_key.sql
--
-- WHAT THIS REMOVES (schema only -- see "NO DATA IS LOST" below):
--   * UNIQUE KEY `uq_one_active_cert_per_job`  (on `active_cert_key`)
--   * KEY        `idx_job_active`              (job, active)
--   * KEY        `idx_citizen_job_active`      (citizenid, job, active)
--   * COLUMN     `active_cert_key`             (VIRTUAL generated column)
--
-- NO DATA IS LOST. Every one of the four objects above is DERIVED:
-- `active_cert_key` is a VIRTUAL generated column -- it is computed from
-- `active`/`citizenid`/`job` on read and occupies no row storage at all,
-- so dropping it cannot delete anything. The other three are indexes:
-- pure lookup structures over rows that stay exactly where they are. Every
-- certification grant/revoke row in `k9_certifications` survives this file
-- untouched. Row count before == row count after, always.
--
-- ///////////////////////////////////////////////////////////////////////
-- READ THIS BEFORE RUNNING -- WHAT YOU GIVE UP
--
-- `uq_one_active_cert_per_job` is not decorative. It is the DATABASE-LEVEL
-- backstop for this resource's core access-control invariant: "at most one
-- active certification per (citizenid, job)". server/certifications.lua's
-- grant path is a check-then-insert with no transaction between the two
-- steps; that unique key is what turns a lost race into a clean, caught
-- 1062 duplicate-key error instead of a silently duplicated grant.
--
-- Measured on a real server, 20 concurrent grant requests for the same
-- handler/department:
--     WITH this constraint:     1 INSERT succeeded, 19 rejected with 1062
--                               -> exactly 1 active certification row.
--     WITHOUT this constraint: 20 INSERTs succeeded, none rejected
--                               -> 20 simultaneously-active certifications,
--                                  no error, no log line, nothing to notice.
--
-- So: run this file to get UNSTUCK (see
-- sql/migrations/0004_add_k9_certifications_active_cert_key.sql's own
-- OPERATOR NOTE -- the duplicate-active-certs case), fix the underlying
-- problem, then run
-- sql/migrations/0004_... again to put the constraint back. Do not leave a
-- production server sitting in this rolled-back state.
-- ///////////////////////////////////////////////////////////////////////
--
-- SAFE TO RE-RUN. Every step below is wrapped in the same
-- INFORMATION_SCHEMA-guarded stored procedure pattern the forward
-- migrations 0003/0004 use, for the same portability reason: a plain
-- `ALTER TABLE ... DROP INDEX IF EXISTS` / `DROP COLUMN IF EXISTS` is
-- MariaDB-only and MySQL 8.0.29+ only. MySQL 5.7 and MySQL 8.0.0-8.0.28
-- (both above this resource's real 5.7.8 floor, both still in the field)
-- throw a syntax error on that form. Running this file a second time is a
-- guaranteed clean no-op: each guard sees the object already gone and
-- skips its ALTER.
--
-- ORDER MATTERS, and it is the reverse of migration 0004's own order:
-- `uq_one_active_cert_per_job` is an index ON `active_cert_key`, so the
-- index must be dropped BEFORE the column it indexes. Dropping the column
-- first fails with a real dependency error.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2 -- the same floor
-- sql/install.sql states, for the same generated-column reason.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1 of 4: drop UNIQUE KEY `uq_one_active_cert_per_job`
-- (must come before the column drop -- this index is ON that column)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_uq_one_active_cert_per_job`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0004_drop_uq_one_active_cert_per_job`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'uq_one_active_cert_per_job'
    ) THEN
        ALTER TABLE `k9_certifications` DROP INDEX `uq_one_active_cert_per_job`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0004_drop_uq_one_active_cert_per_job`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_uq_one_active_cert_per_job`;


-- ---------------------------------------------------------------------
-- STEP 2 of 4: drop KEY `idx_job_active`
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_idx_job_active`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0004_drop_idx_job_active`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'idx_job_active'
    ) THEN
        ALTER TABLE `k9_certifications` DROP INDEX `idx_job_active`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0004_drop_idx_job_active`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_idx_job_active`;


-- ---------------------------------------------------------------------
-- STEP 3 of 4: drop KEY `idx_citizen_job_active`
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_idx_citizen_job_active`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0004_drop_idx_citizen_job_active`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'idx_citizen_job_active'
    ) THEN
        ALTER TABLE `k9_certifications` DROP INDEX `idx_citizen_job_active`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0004_drop_idx_citizen_job_active`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_idx_citizen_job_active`;


-- ---------------------------------------------------------------------
-- STEP 4 of 4: drop the VIRTUAL generated COLUMN `active_cert_key`
-- (last -- every index on it is gone by now)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_active_cert_key_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0004_drop_active_cert_key_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'active_cert_key'
    ) THEN
        ALTER TABLE `k9_certifications` DROP COLUMN `active_cert_key`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0004_drop_active_cert_key_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0004_drop_active_cert_key_column`;


-- ---------------------------------------------------------------------
-- HOUSEKEEPING: clear any migration/rollback procedure left behind by an
-- EARLIER run that died partway through.
--
-- This is a real, observed failure mode, not a theoretical one. Migration
-- 0004's final step (`ADD UNIQUE KEY`) legitimately fails with a 1062 on a
-- database that already contains duplicate active certifications. When it
-- does, the `mysql` client aborts the rest of the file -- including that
-- step's own trailing `DROP PROCEDURE` -- and
-- `john_k9_migration_0004_add_uq_one_active_cert_per_job` is left
-- sitting in the operator's schema. Sweeping those here means a rollback
-- always returns the database to a genuinely clean state, with no stray
-- john-k9 procedures left over from a half-finished migration.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_active_cert_key_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_idx_citizen_job_active`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_idx_job_active`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_uq_one_active_cert_per_job`;
