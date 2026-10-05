-- =====================================================================
-- john-k9 :: migration 0004 :: add k9_certifications active-cert
-- backstop (active_cert_key + uq_one_active_cert_per_job), plus the two
-- plain lookup indexes idx_citizen_job_active / idx_job_active, to an
-- EXISTING k9_certifications table that predates them.
--
-- WHY THIS FILE EXISTS (db-schema re-reconciliation pass, 2026-08-25):
-- DEVELOPER_REFERENCE.md section 9 item 1 records this table's DB-level uniqueness
-- backstop as something db-schema's Phase 1 review "resolved" and
-- "added" to an already-drafted certification table design ("dedicated
-- table confirmed, with an added DB-level uniqueness backstop" -- DEVELOPER_REFERENCE.md
-- section 9 item 1; see also section 4.3's own "Reviewed and refined by
-- db-schema" framing). That wording means the generated column, its
-- unique index, and very likely the two plain lookup indexes below were
-- not necessarily present in the very first shape `k9_certifications`
-- ever took in this project's history -- the exact same "column/index
-- added to an existing table's CREATE TABLE, but no migration shipped
-- alongside it" situation that made migration 0003 above necessary for
-- `k9_partnerships.tenure_bonus_tier_granted`. Unlike that case, no
-- earlier migration file was ever written to backfill this one, and
-- `CREATE TABLE IF NOT EXISTS` in install.sql/migration-less installs
-- does NOT retroactively add a column/index to a table that already
-- exists in some earlier shape -- so any database whose k9_certifications
-- table was created before this backstop landed is silently missing it
-- today, with no error or warning anywhere.
--
-- WHY THIS IS A SERIOUS GAP, NOT A COSMETIC ONE: server/certifications.lua's
-- GrantCertification does an application-level SELECT-then-INSERT
-- (SELECT ... WHERE citizenid = ? AND job = ? AND active = 1, then INSERT)
-- with NO transaction/locking of its own between the two statements. Its
-- own comments are explicit that this is safe ONLY because
-- `uq_one_active_cert_per_job` is expected to throw a real MySQL/MariaDB
-- 1062 duplicate-key error on the second of two concurrent grant requests
-- for the same (citizenid, job), which `IsDuplicateKeyError`/the calling
-- code then treats as "lost the race, not a real failure." On a database
-- missing this constraint, that 1062 never happens: two near-simultaneous
-- grant requests for the same target/department can BOTH pass the
-- pre-check and BOTH insert, leaving two simultaneously active
-- k9_certifications rows for the same (citizenid, job) -- a real,
-- silent TOCTOU window with no error, no log line, and no code path that
-- would ever notice on that database, exactly the class of gap this pass
-- was asked to close.
--
-- WHO NEEDS THIS FILE: any existing installation that already has
-- `k9_certifications` (created by an earlier `install.sql`) but does NOT
-- yet have `active_cert_key` / `uq_one_active_cert_per_job` (and/or the
-- two plain lookup indexes below). A fresh install never needs this file
-- -- current install.sql already creates this table with all of the
-- below in one CREATE TABLE. Running this against a database that was
-- built from the current install.sql is a documented, guaranteed no-op
-- (see below) -- it is always safe to run this file "just in case," on
-- every upgrade, exactly like migration 0003.
--
-- IDEMPOTENT / SAFE TO RE-RUN, EACH PIECE INDEPENDENTLY: four separate
-- INFORMATION_SCHEMA-guarded stored-procedure blocks below (one for the
-- generated column, one for each of the two plain indexes, one for the
-- unique key) -- each checks its own target's existence before acting, so
-- this file is safe to run against a database in ANY partial state (e.g.
-- one that already has the plain indexes but not the generated column, or
-- vice versa), not just the two extremes of "has everything" / "has
-- nothing." Column is added before the unique key that references it
-- (MySQL/MariaDB requires the column to exist before an index can be
-- built on it) -- this file's four blocks are ordered for exactly that
-- dependency, so running the whole file top-to-bottom in one pass always
-- works regardless of which pieces (if any) a given database already has.
--
-- ORDERING, REVISED (db-schema re-review, 2026-08-25): the two plain
-- lookup indexes (`idx_citizen_job_active`, `idx_job_active`) are now
-- applied BEFORE the unique key (`uq_one_active_cert_per_job`), not after.
-- Reason: the unique key is the one step in this file that can legitimately
-- fail with a real duplicate-entry error -- see "OPERATOR NOTE" below --
-- on a database that already accumulated more than one simultaneously-
-- active row for some (citizenid, job) pair before this constraint existed.
-- Most SQL-import tools (the plain `mysql` CLI without `--force`, and most
-- GUI import dialogs) abort the REST of a script on the first statement
-- error in it. If the unique-key step ran before the two plain indexes and
-- failed on a dirty database, the two plain indexes -- which have nothing
-- to do with the duplicate-row conflict and would apply cleanly regardless
-- -- would never get created on that run, silently leaving
-- `idx_citizen_job_active` (the hot-path index `HasK9Access`'s cache-refresh
-- query depends on) missing on exactly the installs that most need an
-- operator to notice and fix something. With the unique key moved last, a
-- database with pre-existing duplicate active rows still ends this file
-- with the column and BOTH plain indexes successfully applied -- only the
-- one step that genuinely cannot succeed until an operator resolves the
-- duplicates (per the OPERATOR NOTE below) fails, and it fails last, after
-- everything independent of it has already landed.
--
-- WHY NOT A PLAIN `ADD COLUMN IF NOT EXISTS` / `ADD INDEX IF NOT EXISTS`:
-- same portability reasoning as migration 0003's own header (not repeated
-- in full here) -- that syntax is MariaDB-only / MySQL 8.0.29+ only, and
-- this resource's migrations must not assume a specific MySQL/MariaDB
-- version. The INFORMATION_SCHEMA-guarded procedure pattern below is
-- identical in shape to migration 0003's, extended to also guard
-- KEY/INDEX existence via INFORMATION_SCHEMA.STATISTICS (the correct
-- catalog view for index presence, as opposed to .COLUMNS for column
-- presence).
--
-- See the "RE-RUN-AFTER-PARTIAL-FAILURE SAFETY" note above Step 1 below for
-- why each of these four procedures is now also dropped immediately BEFORE
-- it is created, not only after.
--
-- WHY BACKFILLING active_cert_key IS SAFE FOR EXISTING ROWS: it is a
-- VIRTUAL generated column (`GENERATED ALWAYS AS (...) VIRTUAL`), computed
-- from `active`/`citizenid`/`job` on every read -- MySQL/MariaDB derives
-- its value for every pre-existing row automatically the moment the
-- column is added; there is no data to backfill by hand and no way for
-- this ALTER to compute a wrong value for a row that predates it. If two
-- rows already active for the same (citizenid, job) exist on a given
-- database BECAUSE of the exact race this migration closes going forward,
-- the subsequent `ADD UNIQUE KEY` step will fail loudly (a real duplicate
-- entry error, on the ALTER itself) rather than silently accepting a bad
-- state -- see the operator note below for how to handle that specific
-- case; this migration deliberately does not try to auto-resolve it.
--
-- OPERATOR NOTE if the `ADD UNIQUE KEY` step below fails with a duplicate
-- entry error: it means this database already accumulated more than one
-- simultaneously-active k9_certifications row for the same (citizenid,
-- job) pair before this constraint was ever enforced -- exactly the data
-- corruption this migration exists to prevent from happening again. This
-- migration deliberately does NOT decide which of the duplicate active
-- rows to keep/deactivate for you (a real access-control/audit judgment
-- call, not a schema-layer one) -- per this pass's own "never write a
-- destructive statement" constraint, no ALTER/UPDATE/DELETE resolving
-- that conflict is included here. Identify the conflicting rows first
-- (`SELECT citizenid, job, COUNT(*) FROM k9_certifications WHERE active = 1
-- GROUP BY citizenid, job HAVING COUNT(*) > 1;`), decide by hand which row
-- should remain the sole active one for each conflicting pair, `UPDATE`
-- the others to `active = 0` (never delete the audit row), THEN re-run
-- this migration file -- the unique-key step will then succeed.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever ADDs a column and ADDs
-- indexes; it never DROPs, TRUNCATEs, or rewrites any existing column,
-- table, or row.
--
-- ORDERING REQUIREMENT: this file assumes `k9_certifications` itself
-- already exists (created by `install.sql`) -- run install.sql first on
-- any database that lacks it entirely. Applying this file's numeric
-- filename order (0001, 0002, 0003, 0004, ...) after install.sql, as
-- documented in install.sql's own header, always satisfies this.
-- =====================================================================

-- ---------------------------------------------------------------------
-- RE-RUN-AFTER-PARTIAL-FAILURE SAFETY (db-schema execution-verification
-- pass, 2026-08-25): every one of this file's four blocks now issues a
-- `DROP PROCEDURE IF EXISTS` immediately BEFORE its own `CREATE PROCEDURE`,
-- in addition to the one already present after each `CALL`. This closes a
-- real gap the previous version of this file had: Step 4 below (the
-- `ADD UNIQUE KEY`) is explicitly documented as the one step that can
-- legitimately fail with a real duplicate-entry error, on exactly the
-- dirty-data database this migration exists to catch (see the "OPERATOR
-- NOTE" below). When run through the plain `mysql` CLI without `--force`
-- -- this resource's own documented install method (see README.md) -- a
-- statement error aborts the REST of the script, which means the `CALL`
-- that throws would never reach its own trailing `DROP PROCEDURE IF
-- EXISTS` line: the temporary procedure is left behind in the schema.
-- The OPERATOR NOTE's own recovery instructions ("deactivate the
-- duplicates, THEN re-run this migration file") would previously walk
-- straight into a SECOND, unrelated failure on that re-run --
-- `CREATE PROCEDURE john_k9_migration_0004_add_uq_one_active_cert_per_job`
-- failing with MySQL/MariaDB error 1304 ("PROCEDURE ... already exists"),
-- because the first, aborted run's procedure was still sitting in the
-- schema -- even though the actual data problem had already been fixed.
-- Dropping each procedure on the way IN, not just on the way out, makes
-- re-running this file after ANY prior partial run (for this reason or any
-- other) safe, matching what this file's header already claims.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Step 0: ORDER-PROTECTION GUARD (db-schema foolproofing pass). All four
-- steps below are ALTER TABLE `k9_certifications`. If that table has never
-- been created on this database, MySQL/MariaDB's raw error for that is a
-- cryptic `ERROR 1146 (42S02): Table 'yourdb.k9_certifications' doesn't
-- exist`. This guard replaces that with one plain-English refusal instead
-- of four repeats of the same raw error (one per step below) -- a
-- full-detail SELECT for GUI tools, plus a short SIGNAL (capped at 128
-- characters by MySQL/MariaDB) so the plain `mysql` CLI also stops with a
-- readable message. Same drop-before-and-after pattern as every other
-- procedure in this file, so re-running this file after a refusal is safe.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_require_base_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0004_require_base_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_certifications'
    ) THEN
        SELECT 'STOPPED - WRONG ORDER' AS status,
               'Table k9_certifications does not exist in this database. This migration only ever ALTERs that table, so it must exist first. Run sql/install.sql before this file -- it creates every john-k9 table, including the one this migration changes, in one pass. Nothing has been changed by this migration.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 0004 stopped: k9_certifications missing. See detail above. Run install.sql first.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0004_require_base_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_require_base_table`;


-- ---------------------------------------------------------------------
-- Step 1: add `active_cert_key` (generated column) if missing.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_active_cert_key_column`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0004_add_active_cert_key_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'active_cert_key'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD COLUMN `active_cert_key` VARCHAR(105)
                GENERATED ALWAYS AS (
                    CASE WHEN `active` = 1
                         THEN CONCAT(`citizenid`, '::', `job`)
                         ELSE NULL
                    END
                ) VIRTUAL
                AFTER `active`;
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0004_add_active_cert_key_column`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_active_cert_key_column`;

-- ---------------------------------------------------------------------
-- Step 2: add `idx_citizen_job_active` if missing (server/admin.lua's
-- '/k9auditcert' relies on this exact index -- see sql/install.sql's own
-- comment on it and server/admin.lua's QueryCertificationHistory). This
-- step is independent of the generated column above and of the unique key
-- below -- it is applied here, BEFORE the unique key, precisely so it
-- still lands even if the unique-key step further down fails on a database
-- with pre-existing duplicate active rows (see the "ORDERING, REVISED"
-- note in this file's header).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_idx_citizen_job_active`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0004_add_idx_citizen_job_active`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'idx_citizen_job_active'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`);
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0004_add_idx_citizen_job_active`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_idx_citizen_job_active`;

-- ---------------------------------------------------------------------
-- Step 3: add `idx_job_active` if missing (DEVELOPER_REFERENCE.md 4.3's admin-path
-- "list all certified handlers in department X" query relies on this
-- exact index -- see sql/install.sql's own comment on it). Same
-- independence-from-the-unique-key reasoning as Step 2 above applies here.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_idx_job_active`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0004_add_idx_job_active`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'idx_job_active'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD KEY `idx_job_active` (`job`, `active`);
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0004_add_idx_job_active`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_idx_job_active`;

-- ---------------------------------------------------------------------
-- Step 4: add `uq_one_active_cert_per_job` (unique key on the column added
-- in Step 1) if missing. Depends on Step 1 having already run in this same
-- pass, or on a database where the column was already present from an
-- earlier partial application. Deliberately placed LAST: this is the one
-- step in this file that can legitimately fail with a real duplicate-entry
-- error on a database that already accumulated more than one
-- simultaneously-active row for some (citizenid, job) pair -- see the
-- "OPERATOR NOTE" below and the "ORDERING, REVISED" note in this file's
-- header for why Steps 2 and 3 above (independent of this one) are applied
-- first, so they still land even if this step fails.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_uq_one_active_cert_per_job`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0004_add_uq_one_active_cert_per_job`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'uq_one_active_cert_per_job'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`);
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0004_add_uq_one_active_cert_per_job`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0004_add_uq_one_active_cert_per_job`;
