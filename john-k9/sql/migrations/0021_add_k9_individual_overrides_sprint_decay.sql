-- =====================================================================
-- john-k9 :: migration 0021 :: add k9_individual_overrides.sprint_decay_per_tick
--
-- WHY THIS FILE EXISTS: the owner asked to be able to set a K9's stamina
-- "as high as i want or permanant", per individual dog, from the tablet.
-- That landed (server/k9profiles.lua's `sprintDecayPerTick` field, set
-- through the same high-command-only path as speed and scent range) but
-- it had NOWHERE TO BE SAVED -- migration 0016 created this table with
-- exactly three DOUBLE columns and a note, none of which is a stamina
-- field. So the override has been held in memory only and SILENTLY
-- REVERTS ON EVERY RESOURCE RESTART. The tablet discloses that today
-- rather than hiding it, which is honest but is not a fix. This is the
-- fix.
--
-- WHO NEEDS THIS FILE: any installation whose `k9_individual_overrides`
-- table predates this column -- i.e. every installation before this pass.
-- sql/install.sql's own CREATE TABLE for this table is updated in the
-- same pass to include the column directly, per this repo's established
-- "install.sql has the final shape, a migration backfills an existing
-- database" convention (migrations 0003/0006/0009/0017 for their own
-- columns). See sql/rollback/0021_down.sql for the reverse.
--
-- WHY NULLABLE WITH NO DEFAULT, unlike migration 0017's `handler_xp`:
-- every column on this table is deliberately NULLABLE and independently
-- optional, because NULL here means "this dog has no override for this
-- field, defer to the server-wide setting" -- see migration 0016's own
-- header on that design. A `NOT NULL DEFAULT 0` would be actively WRONG
-- here: 0 is not a neutral value for this column, it is the sentinel
-- meaning PERMANENT STAMINA. Backfilling every existing override row
-- with 0 would silently hand every dog that already has a speed or scent
-- override a stamina that never runs out. NULL is the only honest
-- starting value, and it is what an existing row gets.
--
-- WHAT THE VALUE MEANS: how much stamina drains per tick. A BIGGER number
-- means stamina runs out FASTER; a SMALLER number makes it last longer;
-- exactly 0 means it never runs out at all. Range is enforced in
-- server/k9profiles.lua (>= 0, ceiling 20.0), not by a CHECK constraint
-- here -- MySQL 5.7 parses CHECK and silently ignores it, so a constraint
-- in this file would read as a guarantee it does not actually provide.
--
-- COMPATIBILITY FOR EXISTING ROWS: every existing override row keeps its
-- speed, scent-range, medkit-cooldown and note values completely
-- untouched, and gains a NULL stamina, which resolves to exactly the
-- behaviour that row already had. There is no window in which an existing
-- dog behaves differently, and there is no backfill UPDATE to run.
--
-- IDEMPOTENT / SAFE TO RE-RUN: one INFORMATION_SCHEMA.COLUMNS-guarded
-- stored-procedure block, the same pattern migrations 0006/0009/0017
-- already use, for the same portability reason: a plain
-- `ADD COLUMN IF NOT EXISTS` is MariaDB-only / MySQL 8.0.29+ only, and
-- this resource's stated floor is MySQL 5.7.8 / MariaDB 10.2 (MySQL
-- 8.0.0-8.0.28 is still in the field and throws a syntax error on that
-- form). Running this file twice, or against a database already built
-- from the updated install.sql, is a guaranteed clean no-op.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever ADDs one column. It never
-- DROPs, TRUNCATEs, or rewrites any existing column, table or row.
--
-- ORDERING: depends on `k9_individual_overrides` already existing
-- (migration 0016 / install.sql), guarded below by the same
-- "STOPPED - WRONG ORDER" refusal migrations 0009/0017 already establish,
-- rather than a cryptic raw `ERROR 1146 (42S02)`.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Step 0: ORDER-PROTECTION GUARD. Step 1 is an ALTER TABLE. If that table
-- has never been created here, the raw engine error is a cryptic
-- `ERROR 1146 (42S02): Table 'yourdb.k9_individual_overrides' doesn't
-- exist`. This replaces it with a plain-English refusal: a full-detail
-- SELECT for GUI tools, plus a short SIGNAL (MySQL/MariaDB cap it at 128
-- characters) so the plain `mysql` CLI also stops readably.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0021_require_base_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0021_require_base_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_individual_overrides'
    ) THEN
        SELECT 'STOPPED - WRONG ORDER' AS status,
               'Table k9_individual_overrides does not exist in this database. This migration only ever ALTERs that table, so it must exist first. Run sql/install.sql (creates every john-k9 table in one pass) -- or, if you are applying migrations one file at a time, run sql/migrations/0016_create_k9_individual_overrides.sql before this file. Nothing has been changed by this migration.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 0021 stopped: k9_individual_overrides missing. See detail above. Run install.sql first.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0021_require_base_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0021_require_base_table`;


-- ---------------------------------------------------------------------
-- Step 1: add `sprint_decay_per_tick` if missing. Placed AFTER
-- `medkit_cooldown_multiplier` so the three tunable numbers sit together
-- and `note` stays last, matching migration 0016's own column order.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0021_add_sprint_decay_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0021_add_sprint_decay_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_individual_overrides'
          AND COLUMN_NAME = 'sprint_decay_per_tick'
    ) THEN
        ALTER TABLE `k9_individual_overrides`
            ADD COLUMN `sprint_decay_per_tick` DOUBLE DEFAULT NULL AFTER `medkit_cooldown_multiplier`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0021_add_sprint_decay_column`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0021_add_sprint_decay_column`;
