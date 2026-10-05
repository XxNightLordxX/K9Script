-- =====================================================================
-- john-k9 :: ROLLBACK 0017 :: remove k9_progression.handler_xp
--
-- Reverses EXACTLY ONE migration:
--   sql/migrations/0017_add_k9_progression_handler_xp.sql
--
-- WHAT THIS REMOVES:
--   * COLUMN `handler_xp` on `k9_progression`
--
-- ///////////////////////////////////////////////////////////////////////
-- !! THIS IS A ROLLBACK THAT LOSES INFORMATION -- READ IT, SAME AS 0003/0006 !!
--
-- No ROWS are deleted, and no other column on `k9_progression` (including
-- `xp`, every citizenid's real K9 XP total) is touched. But UNLIKE
-- migration 0009's `idx_xp` (a plain derived index, safe to drop with zero
-- data loss), `handler_xp` is real, independently-accumulated,
-- non-derived data -- exactly like migration 0006's `tier`/
-- `revoke_reason`/`expires_at` (see that rollback's own header for the
-- identical warning shape, mirrored here on purpose):
--
--   * DROPping `handler_xp` loses every citizenid's real, earned handler
--     XP total -- every certification granted, every K9 treated, every
--     kennel deployed, every partnership-tenure milestone paid to a
--     handler. Re-applying migration 0017 afterward brings the column
--     back at `DEFAULT 0` for EVERY row, including ones that used to hold
--     a real, nonzero total -- that total is gone, not merely hidden.
--
-- ==> RUN THE BACKUP FIRST if you want any chance of recovering these
--     values. sql/rollback/backup_k9_tables.sh captures `k9_progression`
--     in full, including `handler_xp`; nothing else does, and it is not
--     reconstructible from any other table or column afterward.
-- ///////////////////////////////////////////////////////////////////////
--
-- WHY NOT JUST DISABLE THE FEATURE INSTEAD OF ROLLING BACK: prefer this.
-- Set `Config.Features.HandlerXPProgression = false` (config.lua) instead
-- of running this file. That stops any NEW handler_xp from ever accruing
-- and makes every handler-XP-tier effect a no-op immediately (every
-- accessor in server/progression.lua that reads Config.HandlerXPTiers is
-- consulted only after this flag has already gated the caller, exactly
-- like Config.Features.XPProgression already gates AwardXP), while
-- leaving every already-earned handler_xp value intact in the database
-- for if the feature is turned back on later. Only run this file if you
-- specifically need the COLUMN gone (e.g. a third-party tool chokes on
-- its presence, or you are fully uninstalling the handler-XP feature and
-- want the schema to reflect that).
--
-- SAFE TO RE-RUN. Same INFORMATION_SCHEMA-guarded stored procedure
-- pattern as every other rollback in this directory, for the identical
-- portability reason (`DROP COLUMN IF EXISTS` is MariaDB-only / MySQL
-- 8.0.29+ only). A second run is a guaranteed clean no-op: the guard sees
-- the column already gone and skips the ALTER.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 of 1: drop COLUMN `handler_xp`
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0017_drop_handler_xp_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0017_drop_handler_xp_column`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_progression'
          AND COLUMN_NAME = 'handler_xp'
    ) THEN
        ALTER TABLE `k9_progression` DROP COLUMN `handler_xp`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0017_drop_handler_xp_column`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0017_drop_handler_xp_column`;


-- ---------------------------------------------------------------------
-- HOUSEKEEPING: clear any migration procedure left behind by an earlier
-- run that died partway through (same rationale as 0006_down.sql's own
-- housekeeping block).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0017_require_base_table`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0017_add_handler_xp_column`;
