-- =====================================================================
-- john-k9 :: migration 0017 :: add k9_progression.handler_xp
--
-- WHY THIS FILE EXISTS: owner-directed "partners and levels" tablet tab
-- for BOTH K9s and handlers. The K9 half (Config.XPTiers/`xp`) already
-- existed; this is the handler half -- server/progression.lua's new
-- AwardHandlerXP/GetHandlerXPTier, gated behind
-- `Config.Features.HandlerXPProgression` (config.lua). See that config
-- flag's own comment, Config.HandlerXPTiers' own header, and
-- server/progression.lua's own "HANDLER XP" section for the full design
-- (why a SECOND column on this SAME table, not a second table, and not a
-- second reading of the existing `xp` column).
--
-- WHO NEEDS THIS FILE: any existing installation whose `k9_progression`
-- table predates `handler_xp` (i.e. every installation before this pass --
-- sql/install.sql's own `k9_progression` CREATE TABLE is updated in this
-- same pass to include `handler_xp` directly, per this repo's own
-- "install.sql has final shape, a migration backfills an existing DB"
-- convention already established by migrations 0003/0006/0009 for their
-- own columns/indexes -- see this migration's own rollback file,
-- sql/rollback/0017_down.sql, for the reverse).
--
-- COMPATIBILITY FOR EXISTING ROWS: `handler_xp` is added
-- `NOT NULL DEFAULT 0`. A plain constant DEFAULT on an ADD COLUMN
-- backfills EVERY existing row (every citizenid who has ever earned K9 XP)
-- the instant the ALTER completes -- there is no separate backfill UPDATE
-- to run and no window where an existing row has a NULL/unknown
-- handler_xp. Every existing citizenid's own `xp` total, and every other
-- column on this table, is completely untouched by this migration --
-- this file only ever ADDS a column, never rewrites or reads an existing
-- one.
--
-- NET EFFECT: run this migration on a live production database with real
-- accumulated K9 XP, and every one of those totals keeps working exactly
-- as before, with zero operator action. `handler_xp` starts at 0 for
-- every existing citizenid (nobody had a handler total before this
-- column existed, which is the only honest starting value) and only ever
-- grows from here via AwardHandlerXP, once
-- `Config.Features.HandlerXPProgression` is turned on (it ships `false`
-- by default -- see that flag's own comment in config.lua for why).
--
-- IDEMPOTENT / SAFE TO RE-RUN: one INFORMATION_SCHEMA.COLUMNS-guarded
-- stored-procedure block, mirroring migration 0006's own
-- `add_tier_column`/migration 0009's own `add_idx_xp` pattern exactly --
-- same portability reasoning (a plain `ADD COLUMN IF NOT EXISTS` is
-- MariaDB-only / MySQL 8.0.29+ only; this resource's stated floor is
-- MySQL 5.7.8 / MariaDB 10.2, and MySQL 8.0.0-8.0.28, still in the field,
-- throws a syntax error on that form). Running this file a second time,
-- or against a database that already has `handler_xp` (e.g. one built
-- from the updated install.sql directly), is a guaranteed clean no-op.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever ADDs one column; it never
-- DROPs, TRUNCATEs, or rewrites any existing column, table, or row.
--
-- ORDERING: depends on `k9_progression` already existing (migration 0002
-- / install.sql) -- guarded by the same "STOPPED - WRONG ORDER" refusal
-- migration 0009 already established for this exact table, rather than a
-- cryptic raw `ERROR 1146 (42S02): Table ... doesn't exist`. Independent
-- of every other table in this schema otherwise -- `k9_progression`
-- shares no column or foreign relationship with any of them.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql --
-- this migration's own column is not generated/virtual and does not
-- strictly need that floor for its own sake, kept identical anyway
-- because this resource's other migrations already require it (same
-- reasoning migration 0006's own header gives for the identical choice).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Step 0: ORDER-PROTECTION GUARD (mirrors migration 0009's own guard for
-- this exact table verbatim). Step 1 below is an ALTER TABLE
-- `k9_progression`. If that table has never been created on this
-- database, MySQL/MariaDB's raw error is a cryptic
-- `ERROR 1146 (42S02): Table 'yourdb.k9_progression' doesn't exist`. This
-- guard replaces that with one plain-English refusal instead -- a
-- full-detail SELECT for GUI tools, plus a short SIGNAL (capped at 128
-- characters by MySQL/MariaDB) so the plain `mysql` CLI also stops with a
-- readable message. Same drop-before-and-after pattern as this file's own
-- main procedure below, so re-running this file after a refusal is safe.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0017_require_base_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0017_require_base_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_progression'
    ) THEN
        SELECT 'STOPPED - WRONG ORDER' AS status,
               'Table k9_progression does not exist in this database. This migration only ever ALTERs that table, so it must exist first. Run sql/install.sql (creates every john-k9 table in one pass) -- or, if you are applying migrations one file at a time, run sql/migrations/0002_create_k9_progression.sql before this file. Nothing has been changed by this migration.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 0017 stopped: k9_progression missing. See detail above. Run install.sql first.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0017_require_base_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0017_require_base_table`;


-- ---------------------------------------------------------------------
-- Step 1: add `handler_xp` if missing.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0017_add_handler_xp_column`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0017_add_handler_xp_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_progression'
          AND COLUMN_NAME = 'handler_xp'
    ) THEN
        ALTER TABLE `k9_progression`
            ADD COLUMN `handler_xp` INT UNSIGNED NOT NULL DEFAULT 0 AFTER `xp`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0017_add_handler_xp_column`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0017_add_handler_xp_column`;
