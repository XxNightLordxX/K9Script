-- =====================================================================
-- john-k9 :: ROLLBACK 0003 :: remove
--                k9_partnerships.tenure_bonus_tier_granted
--
-- Reverses EXACTLY ONE migration:
--   sql/migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql
--
-- WHAT THIS REMOVES:
--   * COLUMN `tenure_bonus_tier_granted` on `k9_partnerships`
--
-- ///////////////////////////////////////////////////////////////////////
-- !! THIS IS THE ONE ROLLBACK SCRIPT THAT LOSES INFORMATION -- READ IT !!
--
-- No ROWS are deleted. Every partnership row in `k9_partnerships`
-- survives, and every other column on it is untouched.
--
-- BUT, unlike 0004's `active_cert_key`, this column is NOT derived and NOT
-- an index -- it holds real stored state that exists nowhere else in the
-- database: the highest tenure-bonus milestone already PAID OUT for each
-- partnership (0 = none yet, 1 = the 1-day bonus, 2 = the 7-day, and so
-- on -- a 1-based index into Config.Partnership.TenureBonus.milestones).
--
-- Drop it and that payout history is gone. Re-applying migration 0003
-- afterwards recreates the column at its DEFAULT 0 for every row, which
-- server/tenure.lua reads as "this partnership has never been paid any
-- tenure bonus." Every already-paid milestone then becomes eligible again,
-- and every long-running partnership gets re-paid its 1-day, 7-day and
-- 30-day XP the next time the tenure check ticks. That is a real,
-- server-wide XP grant you did not intend.
--
-- ==> RUN THE BACKUP FIRST. sql/rollback/backup_k9_tables.sh captures this
--     column's values; nothing else does, and they are not reconstructible
--     from any other table. See README.md's "Uninstalling / rolling back"
--     section.
-- ///////////////////////////////////////////////////////////////////////
--
-- SAFE TO RE-RUN. The INFORMATION_SCHEMA-guarded stored procedure below
-- follows the same pattern, for the same portability reason, as the
-- forward migrations 0003/0004: `ALTER TABLE ... DROP COLUMN IF EXISTS` is
-- MariaDB-only and MySQL 8.0.29+ only, and MySQL 5.7 / 8.0.0-8.0.28 throw
-- a syntax error on it. A second run is a guaranteed clean no-op: the
-- guard sees the column already gone and skips the ALTER.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1 of 1: drop COLUMN `tenure_bonus_tier_granted`
--
-- No index depends on this column (it is not part of
-- idx_k9_citizenid_active, idx_handler_citizenid_active, or either
-- active-partner unique key), so unlike 0004_down.sql there is no
-- drop-the-index-first ordering requirement here.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0003_drop_tenure_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0003_drop_tenure_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_partnerships'
          AND COLUMN_NAME = 'tenure_bonus_tier_granted'
    ) THEN
        ALTER TABLE `k9_partnerships` DROP COLUMN `tenure_bonus_tier_granted`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0003_drop_tenure_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0003_drop_tenure_column`;


-- ---------------------------------------------------------------------
-- HOUSEKEEPING: clear any migration procedure left behind by an earlier
-- run of migration 0003 that died partway through (same rationale as
-- 0004_down.sql's own housekeeping block -- a `mysql` client aborts the
-- rest of a file on error, including that step's trailing DROP PROCEDURE).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0003_add_tenure_column`;
