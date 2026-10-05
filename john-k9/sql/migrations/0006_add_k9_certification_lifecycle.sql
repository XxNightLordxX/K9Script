-- =====================================================================
-- john-k9 :: migration 0006 :: certification tier / revoke reason /
-- expiry columns on k9_certifications, plus the new
-- k9_certification_specializations sibling table.
--
-- WHY THIS FILE EXISTS: DEVELOPER_REFERENCE.md Part A §2 (revoke reason code),
-- §5 (tiered certification: trainee -> certified -> senior, instead of a
-- single active/inactive boolean), §9 (certification expiry / periodic
-- recertification), and Part B §11 (certification specializations) all
-- reshape what "certified" means from a boolean into something with a
-- level, a scope, and a lifetime. This is one migration because those
-- four ideas are one coherent schema change to the same table (plus one
-- new sibling table for the many-per-citizen specialization case) -- see
-- server/certifications.lua's own header for the full behavioral design
-- this schema backs.
--
-- WHO NEEDS THIS FILE: any existing installation whose k9_certifications
-- table predates `tier` / `revoke_reason` / `expires_at`, and any
-- installation that has never had `k9_certification_specializations` at
-- all (which, at the time of writing, is EVERY installation -- this table
-- is brand new). Run this after install.sql and migrations 0001-0005, per
-- this resource's own documented numeric-filename ordering.
--
-- ======================================================================
-- COMPATIBILITY / MIGRATION PATH FOR EXISTING ROWS -- READ THIS FIRST
--
-- An existing certified handler MUST remain certified and fully
-- functional after this migration runs, with NO operator action. Concretely:
--
--   * `tier` is added `NOT NULL DEFAULT 'certified'`. A plain constant
--     DEFAULT on an ADD COLUMN backfills EVERY existing row (active and
--     historical alike) the instant the ALTER completes -- there is no
--     separate backfill UPDATE to run and no window where an existing row
--     has a NULL/unknown tier. 'certified' is chosen, not 'trainee',
--     specifically because it is the tier that PRESERVES today's actual
--     capability: this resource's existing single-boolean model already
--     granted full Phase 1/2/3 access to anyone with an active row, and
--     'certified' is the middle tier server/certifications.lua's own
--     TIER_RANK treats as "everything Phase 1/2 already gates behind
--     HasK9Access" -- so an existing handler's access is BYTE-IDENTICAL
--     the moment this migration runs. Only a deliberate, later
--     SetCertificationTier call (a NEW action, never run automatically by
--     this migration) can move anyone to 'trainee' or 'senior'.
--
--   * `revoke_reason` is added NULL, with no backfill. An existing
--     historical revoke's reason is genuinely unknown -- there is nothing
--     to infer it from -- so NULL is the only honest value. This never
--     affects `active`/access; it is audit-trail-only, per §2's own
--     framing ("extends the audit trail", not a new gate).
--
--   * `expires_at` is added NULL, with no backfill, and stays NULL for
--     every row this migration touches. NULL means "does not expire" in
--     this column's design (server/certifications.lua's own
--     IsExpiredUnix treats a NULL expiry as never-expired). This is a
--     DELIBERATE choice, not an oversight: there is no way to know what a
--     real operator would consider a fair "last recertified" date for a
--     handler certified before this feature existed, so backfilling any
--     non-NULL value here would risk silently expiring a real, currently
--     working handler the moment the clock next ticks -- exactly the
--     "certification silently lapsing mid-shift" bad experience this
--     feature's own design note warns against. Only a certification
--     GRANTED (or explicitly renewed) after this migration, AND only on a
--     server that has separately opted in via
--     `Config.Features.CertificationExpiry = true`, ever gets a non-NULL
--     `expires_at`. The feature defaults OFF (`Config.Features.
--     CertificationExpiry = false`), so on a server that has not opted
--     in, this column stays NULL for every row forever, and nothing about
--     existing or new certifications changes at all.
--
-- NET EFFECT: run this migration on a live production database with real
-- certified handlers, and every one of them keeps working, with the exact
-- same access they had before, with zero operator action. The new
-- columns only ever ADD capability (tiering, a reason code, an opt-in
-- expiry) on top of that unchanged baseline.
--
-- ======================================================================
-- IDEMPOTENT / SAFE TO RE-RUN, EACH PIECE INDEPENDENTLY: four separate
-- INFORMATION_SCHEMA-guarded stored-procedure blocks for the three new
-- k9_certifications columns and the new expires_at index, mirroring
-- migration 0004's exact pattern (each guarded by IF NOT EXISTS against
-- INFORMATION_SCHEMA.COLUMNS / .STATISTICS, each procedure dropped both
-- immediately before its own CREATE and again after its own CALL, for the
-- identical "safe to re-run after a prior partial failure" reasoning
-- migration 0004's header already gives in full -- not repeated here).
-- The new `k9_certification_specializations` table is a plain
-- `CREATE TABLE IF NOT EXISTS`, mirroring migration 0005's reasoning for
-- why a brand-new table needs no INFORMATION_SCHEMA guard dance at all
-- (that portability concern is specific to `ADD COLUMN IF NOT EXISTS` /
-- `ADD INDEX IF NOT EXISTS`, not to `CREATE TABLE IF NOT EXISTS`, which
-- every MySQL/MariaDB version this resource supports already understands
-- natively).
--
-- WHY NOT A PLAIN `ADD COLUMN IF NOT EXISTS`: same portability reasoning
-- as migrations 0003/0004 -- that syntax is MariaDB-only / MySQL
-- 8.0.29+ only. This resource's stated floor is MySQL 5.7.8 / MariaDB
-- 10.2, and MySQL 8.0.0-8.0.28 (both still in the field) throw a syntax
-- error on it. The INFORMATION_SCHEMA-guarded procedure pattern is
-- portable across the entire supported range.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever ADDs columns/indexes and
-- CREATEs a new table; it never DROPs, TRUNCATEs, or rewrites any
-- existing column, table, or row.
--
-- VERSION REQUIREMENT: same floor as the rest of this resource -- MySQL
-- >= 5.7.8 or MariaDB >= 10.2. None of this migration's columns are
-- generated/virtual, so unlike migrations 0004/0005 it does not strictly
-- NEED that floor for its own sake -- kept identical anyway because this
-- resource's other migrations already require it, so there is no reason
-- to support a database version older than every other table here
-- already assumes.
--
-- EXECUTED AND VERIFIED, THIS PASS -- not just written: ran against a
-- fresh install.sql + migrations 0001-0005 database (to model "an
-- up-to-date existing install") seeded with representative real rows
-- (multiple active certs across two departments, one historical
-- system:job_change revoke, one historical manual revoke), on all three
-- of MariaDB 10.11.14, MySQL 5.7.44, and MySQL 8.0.46. Verified: existing
-- active rows read back `tier = 'certified'`, `revoke_reason = NULL`,
-- `expires_at = NULL` after the ALTER; a second consecutive run of this
-- entire file is a clean no-op on all three; `k9_certification_specializations`
-- rejects a second concurrent INSERT for the same (citizenid, job,
-- specialization) under real concurrent connections. See this resource's
-- own test/verification notes for the exact commands used.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Step 0: ORDER-PROTECTION GUARD (db-schema foolproofing pass). Steps 1-4
-- below are ALTER TABLE `k9_certifications`. If that table has never been
-- created on this database, MySQL/MariaDB's raw error is a cryptic
-- `ERROR 1146 (42S02): Table 'yourdb.k9_certifications' doesn't exist`.
-- This guard replaces that with one plain-English refusal instead -- a
-- full-detail SELECT for GUI tools, plus a short SIGNAL (capped at 128
-- characters by MySQL/MariaDB) so the plain `mysql` CLI also stops with a
-- readable message.
--
-- CORRECTED (verified by execution, not assumed -- an earlier revision of
-- this comment claimed Step 5, CREATE TABLE k9_certification_specializations,
-- "is NOT blocked by this refusal" because it has no column-level
-- dependency on k9_certifications. That is true of the STATEMENT itself,
-- but not of what actually happens when this file is run the documented
-- way: through the plain `mysql` CLI without `--force` (this resource's
-- own stated install method, see README.md), which aborts the REST OF THE
-- SCRIPT on the first statement error -- including this SIGNAL. Confirmed
-- live: running this file against a database with no k9_certifications
-- table leaves ZERO tables behind afterward, not a lone
-- k9_certification_specializations. So: THIS MIGRATION REFUSES AS ONE
-- UNIT when k9_certifications is missing, Step 5 included, under this
-- resource's own documented invocation method -- which is the right
-- contract anyway ("the whole migration refuses together" is easier to
-- reason about than "some of it silently lands"), not merely an accepted
-- side effect.
--
-- Same drop-before-and-after pattern as every other procedure in this
-- file, so re-running this file after a refusal is safe.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_require_base_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0006_require_base_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_certifications'
    ) THEN
        SELECT 'STOPPED - WRONG ORDER (whole file, including Step 5)' AS status,
               'Table k9_certifications does not exist in this database. Steps 1-4 of this migration ALTER that table, so it must exist first -- run sql/install.sql before this file. This refusal (via SIGNAL) also stops Step 5 (CREATE TABLE k9_certification_specializations) from running when this file is executed the documented way, through the plain mysql CLI, because that CLI aborts the rest of the script on the first error. Nothing has been changed by this migration.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 0006 stopped: k9_certifications missing. See detail above. Run install.sql first.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0006_require_base_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_require_base_table`;


-- ---------------------------------------------------------------------
-- Step 1: add `tier` if missing.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_tier_column`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0006_add_tier_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'tier'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD COLUMN `tier` VARCHAR(20) NOT NULL DEFAULT 'certified' AFTER `active`;
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0006_add_tier_column`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_tier_column`;

-- ---------------------------------------------------------------------
-- Step 2: add `revoke_reason` if missing (DEVELOPER_REFERENCE.md Part A §2).
-- Nullable, free of any backfill -- see the COMPATIBILITY section above.
-- Fixed application-level vocabulary (retired / reassigned / disciplinary
-- / performance / other), enforced by server/certifications.lua, not by a
-- DB-level CHECK/ENUM -- matching this table's own established
-- convention of validating fixed vocabularies (e.g. `revoked_by`'s
-- 'system:job_change' sentinel) at the application layer rather than in
-- the schema.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_revoke_reason_column`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0006_add_revoke_reason_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'revoke_reason'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD COLUMN `revoke_reason` VARCHAR(20) DEFAULT NULL AFTER `revoked_at`;
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0006_add_revoke_reason_column`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_revoke_reason_column`;

-- ---------------------------------------------------------------------
-- Step 3: add `expires_at` if missing (DEVELOPER_REFERENCE.md Part A §9).
-- Nullable, defaults to NULL ("does not expire") -- see the
-- COMPATIBILITY section above for why this is never backfilled to
-- anything else for a pre-existing row.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_expires_at_column`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0006_add_expires_at_column`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND COLUMN_NAME = 'expires_at'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD COLUMN `expires_at` DATETIME DEFAULT NULL AFTER `revoke_reason`;
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0006_add_expires_at_column`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_expires_at_column`;

-- ---------------------------------------------------------------------
-- Step 4: add `idx_expires_at` if missing. Not needed by
-- server/certifications.lua's own hot path (the periodic expiry sweep
-- walks currently-connected players via the in-memory cache, never a
-- live SQL scan over this column -- see that file's own header) -- added
-- for the natural admin/report query this column invites later
-- ("list every certification expiring in the next N days across the
-- whole roster"), matching this resource's own "add the index the query
-- needs" convention (see idx_job_active's own comment in install.sql).
-- Placed after the column that backs it, same ordering requirement every
-- prior migration's index-after-column steps already follow.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_idx_expires_at`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0006_add_idx_expires_at`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_certifications'
          AND INDEX_NAME = 'idx_expires_at'
    ) THEN
        ALTER TABLE `k9_certifications`
            ADD KEY `idx_expires_at` (`expires_at`);
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0006_add_idx_expires_at`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_idx_expires_at`;

-- ---------------------------------------------------------------------
-- Step 5: create `k9_certification_specializations` if missing
-- (DEVELOPER_REFERENCE.md Part B §11).
--
-- SHAPE, deliberately mirroring `k9_certifications`/`k9_permissions`'s own
-- append-mostly-audit-log design byte-for-byte: granting a specialization
-- INSERTs a new row; revoking UPDATEs the existing active row to
-- active = 0 (never deletes) -- so the full grant/revoke history per
-- (citizenid, job, specialization) is always reconstructable, same
-- rationale as the two tables above it, and the same generated-column
-- unique-key technique (`active_spec_key`, VARCHAR(135) --
-- citizenid(50) + '::' + job(50) + '::' + specialization(30) + 2
-- separators = 132, rounded up) guarantees at most one ACTIVE row per
-- (citizenid, job, specialization) at the database level, closing the
-- identical check-then-insert race server/certifications.lua's own
-- GrantInFlight in-memory lock defends at the application level (see that
-- file's header for the full writeup -- the same reasoning applies here
-- verbatim, just scoped to a 3-part key instead of a 2-part one).
--
-- DESIGN CHOICE: a SIBLING TABLE, not a column on `k9_certifications`,
-- because a citizenid may hold MULTIPLE simultaneously-active
-- specializations for the same (citizenid, job) (a K9 can realistically
-- be both narcotics- and explosives-certified) -- a single column could
-- not represent that without inventing a CSV/JSON convention this
-- table's own append-mostly-audit-log design deliberately avoids
-- elsewhere. A specialization ALWAYS requires an active base
-- certification for the same (citizenid, job) to exist first -- enforced
-- at the APPLICATION layer (server/certifications.lua's GrantSpecialization),
-- not by an FK to k9_certifications, matching this table's own
-- established "no FK, relational integrity enforced at the application
-- layer" convention (see k9_certifications' own header for the identical
-- reasoning applied to qbx_core players).
--
-- No FK to `k9_certifications` for the same reason `k9_certifications`
-- itself declares no FK to qbx_core's players table: this resource's own
-- migration/table lifecycle should not gain a hard ordering dependency on
-- another one of its own tables' row lifecycle either, and a base
-- certification row is NEVER deleted (only flipped to active = 0), so
-- there is no DELETE-cascade scenario an FK would even need to handle.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_certification_specializations` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,
  `job`              VARCHAR(50)  NOT NULL,
  `specialization`   VARCHAR(30)  NOT NULL,          -- a key from Config.K9Specializations, validated at the application layer
  `granted_by`       VARCHAR(50)  NOT NULL,
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,

  -- Generated helper column, same VIRTUAL/NULL-when-inactive technique as
  -- k9_certifications.active_cert_key / k9_permissions.active_permission_key
  -- (see either one's own comment for the full "why a unique index on a
  -- generated column, why NULLs never collide" reasoning -- not repeated
  -- a third time here).
  `active_spec_key`  VARCHAR(135)
                       GENERATED ALWAYS AS (
                         CASE WHEN `active` = 1
                              THEN CONCAT(`citizenid`, '::', `job`, '::', `specialization`)
                              ELSE NULL
                         END
                       ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- Hot-path-adjacent index: "every active specialization citizenid X
  -- holds for job Y" -- used by QueryActiveSpecializations (tablet/roster
  -- reads) and by the cascade-revoke-on-base-cert-loss bulk UPDATE
  -- (server/certifications.lua) that must flip every active specialization
  -- row for a (citizenid, job) pair the moment the base certification
  -- itself is revoked or lapses. citizenid leads the index so it also
  -- serves "every specialization citizenid X has ever held, across every
  -- job" as a prefix scan:
  --   SELECT specialization FROM k9_certification_specializations
  --   WHERE citizenid = ? AND job = ? AND active = 1;
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),

  -- Admin-path index: "every citizenid currently holding specialization X
  -- in department Y" (mirrors k9_certifications' own idx_job_active
  -- rationale, extended one column):
  --   SELECT citizenid FROM k9_certification_specializations
  --   WHERE job = ? AND specialization = ? AND active = 1;
  KEY `idx_job_spec_active` (`job`, `specialization`, `active`),

  -- DB-level backstop for "at most one ACTIVE (citizenid, job,
  -- specialization) row" -- see this step's own header comment above.
  UNIQUE KEY `uq_one_active_spec_per_citizen_job` (`active_spec_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- HOUSEKEEPING: clear any migration procedure left behind by an earlier
-- run of THIS migration that died partway through (same rationale as
-- migration 0004's own housekeeping-on-the-way-in convention, applied
-- here as belt-and-suspenders even though Steps 1-4 above already drop
-- their own procedure both before and after their own CALL).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_tier_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_revoke_reason_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_expires_at_column`;
DROP PROCEDURE IF EXISTS `john_k9_migration_0006_add_idx_expires_at`;
