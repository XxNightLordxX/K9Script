-- =====================================================================
-- john-k9 :: migration 0003 :: add k9_partnerships.tenure_bonus_tier_granted
--
-- WHO NEEDS THIS FILE: an existing installation that already has
-- `k9_partnerships` (created either by an earlier `install.sql` or by
-- migration 0001 above) but does NOT yet have the
-- `tenure_bonus_tier_granted` column `server/tenure.lua` requires (see that
-- file's own header, "WHY ONE NEW COLUMN IS UNAVOIDABLE", and
-- `john-k9/sql/install.sql`'s own `k9_partnerships` header comment for
-- the full rationale -- not repeated here). A fresh install never needs
-- this file -- current install.sql and migration 0001 both already include
-- this column in their CREATE TABLE. Running this against a database that
-- was built from the current install.sql/migration 0001 is a documented,
-- guaranteed no-op (see below) -- it is always safe to run this file
-- "just in case."
--
-- WHY NOT A PLAIN `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`: that syntax
-- is NOT portable across every MySQL/MariaDB version this kind of FiveM
-- server database realistically runs. MariaDB has supported
-- `ADD COLUMN IF NOT EXISTS` since 10.0.2; MySQL did not add it until
-- 8.0.29 (2022) -- a MySQL 5.7 or early-8.0 install (still common on
-- shared hosting / older txAdmin setups) would throw a syntax error on
-- that statement, which is exactly the kind of "assumed MySQL/MariaDB
-- version compatibility" this migration must not gamble on. The pattern
-- below (query INFORMATION_SCHEMA.COLUMNS, branch inside a stored
-- procedure, ALTER only if missing, then drop the procedure) is supported
-- identically by every MySQL/MariaDB version this resource can actually
-- run on, and produces the exact same idempotent end state:
--
-- CORRECTION (verified by execution, not inspection, against real
-- MySQL 5.6.51 / 5.7.44 / 8.0.46 and MariaDB 10.11.14 servers): an
-- earlier revision of this comment claimed the guard pattern below is
-- "supported identically by MySQL 5.6+". The guard pattern itself is --
-- but MySQL 5.6 CANNOT RUN THIS RESOURCE'S SCHEMA AT ALL, so that floor
-- was never reachable and is corrected here. sql/install.sql's own base
-- `CREATE TABLE`s require INDEXED VIRTUAL GENERATED COLUMNS
-- (`k9_certifications.active_cert_key`,
-- `k9_partnerships.active_partner_k9_key`/`active_partner_handler_key`,
-- each backing a UNIQUE KEY), a feature MySQL did not gain until 5.7.8
-- and MariaDB not until 10.2. On a real MySQL 5.6.51 server, install.sql
-- and this resource's migrations fail outright:
--     ERROR 1064 (42000) at line 48: You have an error in your SQL syntax
--     ... near 'GENERATED ALWAYS AS ( CASE WHEN `active` = 1'
-- and leave the database HALF-BUILT -- only `k9_progression` (the one
-- table with no generated column) gets created; `k9_certifications`,
-- `k9_search_log` and `k9_partnerships` do not exist at all.
--
-- TRUE MINIMUM VERSIONS: MySQL >= 5.7.8, or MariaDB >= 10.2.
-- Verified passing end-to-end on MySQL 5.7.44, MySQL 8.0.46 and
-- MariaDB 10.11.14; verified FAILING on MySQL 5.6.51.
--
-- The stored-procedure guard below is still genuinely REQUIRED, and is
-- not made redundant by that higher floor: `ADD COLUMN IF NOT EXISTS`
-- still does not exist in MySQL 5.7 or in MySQL 8.0.0-8.0.28, both of
-- which sit above the 5.7.8 floor and are still in the field. The
-- reasoning above stands; only the "5.6" number was wrong.
--   * Column already present (fresh install, or this migration already
--     ran once before)      -> IF is false -> no ALTER runs -> no-op.
--   * Column missing         -> IF is true  -> ALTER runs once, adds the
--                                column with the documented DEFAULT 0 for
--                                every existing row (see below) -> next run
--                                of this same file is then a no-op.
-- Either branch leaves the temporary procedure dropped when this script
-- finishes, so re-running the whole file is always safe -- it never tries
-- to CREATE PROCEDURE over an existing one left behind by a prior partial
-- run.
--
-- WHY THE DEFAULT (0) BACKFILLS SAFELY FOR EXISTING ROWS: `ALTER TABLE ...
-- ADD COLUMN ... NOT NULL DEFAULT 0` populates every pre-existing row with
-- 0 for the new column -- which is the CORRECT value for every row that
-- predates this feature: 0 means "no tenure milestone has been paid out
-- yet for this partnership row," which is factually true for every row
-- that existed before `server/tenure.lua` could ever have written to it.
-- No existing partnership loses or double-counts a milestone by this
-- backfill -- `server/tenure.lua`'s own periodic check will simply
-- evaluate each active row's real elapsed tenure the next time it runs and
-- grant whatever is newly due, exactly as if the column had existed from
-- that row's `established_at` all along.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever ADDs a column with a safe
-- default; it never DROPs, TRUNCATEs, or rewrites any existing column,
-- table, or row.
--
-- ORDERING REQUIREMENT: this file assumes `k9_partnerships` itself already
-- exists (created by `install.sql` or by migration 0001 above) -- run
-- 0001 (or install.sql) first on any database that has neither. Applying
-- this file's numeric filename order (0001, 0002, 0003, ...) after
-- install.sql, as documented in install.sql's own header, always satisfies
-- this.
--
-- RE-RUN-AFTER-PARTIAL-FAILURE SAFETY (db-schema execution-verification
-- pass): a `DROP PROCEDURE IF EXISTS` is issued immediately BEFORE the
-- `CREATE PROCEDURE` below, in addition to the one already present after
-- the `CALL`. This column's own ALTER cannot legitimately fail (a plain
-- `ADD COLUMN ... DEFAULT 0` has no duplicate-entry/constraint failure
-- mode the way migration 0004's unique-key step does), so this is
-- defense-in-depth rather than a fix for an observed failure on THIS file
-- -- but the same CREATE-then-CALL-then-DROP shape is used again in
-- migration 0004, where the CALL genuinely can throw (a pre-existing
-- duplicate-active-row conflict). A tool that runs this script and aborts
-- on the first statement error (the plain `mysql` CLI without `--force`,
-- per this resource's own documented install method) would, without this
-- extra DROP, leave the temporary procedure behind if a run were ever
-- interrupted for any other reason (killed connection, disk full
-- mid-script, etc.), and the next re-run would then fail at `CREATE
-- PROCEDURE` (MySQL/MariaDB error 1304, "PROCEDURE ... already exists")
-- instead of cleanly re-attempting the guarded ALTER. Dropping the
-- procedure on the way IN, not just on the way out, makes re-running this
-- file after ANY prior partial run safe, not just after a clean one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 0: ORDER-PROTECTION GUARD (db-schema foolproofing pass).
--
-- Every step below is an ALTER TABLE `k9_partnerships`. If that table has
-- never been created on this database (install.sql, or migration 0001,
-- has not been run here yet), MySQL/MariaDB's own error for that is a raw,
-- easy-to-misread:
--     ERROR 1146 (42S02): Table 'yourdb.k9_partnerships' doesn't exist
-- This guard turns that into one specific, actionable, plain-English
-- refusal instead -- a full-detail SELECT for GUI tools (phpMyAdmin/
-- HeidiSQL always show a result set), plus a short SIGNAL so the plain
-- `mysql` CLI also stops with a message it can actually show (SIGNAL's
-- own MESSAGE_TEXT is capped at 128 characters by MySQL/MariaDB, hence two
-- messages instead of one long one).
--
-- SAFE TO RE-RUN: this guard procedure follows the exact same
-- drop-before-and-after pattern as every other procedure in this file, so
-- re-running this file after a refusal (once the real problem -- running
-- things out of order -- is fixed) is always safe.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0003_require_base_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0003_require_base_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_partnerships'
    ) THEN
        SELECT 'STOPPED - WRONG ORDER' AS status,
               'Table k9_partnerships does not exist in this database. This migration only ever ALTERs that table, so it must exist first. Run sql/install.sql (creates every john-k9 table, including this migration''s change, in one pass) -- or, if you are applying migrations one file at a time, run sql/migrations/0001_create_k9_partnerships.sql before this file. Nothing has been changed by this migration.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 0003 stopped: k9_partnerships missing. See detail above. Run install.sql first.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0003_require_base_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0003_require_base_table`;


DROP PROCEDURE IF EXISTS `john_k9_migration_0003_add_tenure_column`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0003_add_tenure_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_partnerships'
          AND COLUMN_NAME = 'tenure_bonus_tier_granted'
    ) THEN
        ALTER TABLE `k9_partnerships`
            ADD COLUMN `tenure_bonus_tier_granted` TINYINT UNSIGNED NOT NULL DEFAULT 0
                COMMENT 'Highest 1-based index into Config.Partnership.TenureBonus.milestones already paid out for this row; 0 = none yet. See server/tenure.lua and sql/install.sql k9_partnerships header.'
                AFTER `active`;
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0003_add_tenure_column`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0003_add_tenure_column`;
