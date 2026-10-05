-- =====================================================================
-- john-k9 :: migration 0009 :: add k9_progression.idx_xp
--
-- WHY THIS FILE EXISTS: DEVELOPER_REFERENCE.md Part A Tier C §10 -- "Handler
-- leaderboard / /k9stats". server/leaderboard.lua's own `/k9stats` command
-- runs `SELECT citizenid, xp FROM k9_progression ORDER BY xp DESC LIMIT ?`
-- -- a real, bounded query, but one that `k9_progression`'s existing shape
-- (sql/install.sql, migration 0002) cannot serve cheaply: that table's
-- ONLY key is `PRIMARY KEY (citizenid)`, which has no bearing on an
-- `ORDER BY xp` at all.
--
-- VERIFIED BY REAL EXPLAIN, NOT ASSUMED -- this pass's own explicit
-- instruction was "give me real EXPLAIN output," so this migration was
-- written only after actually measuring the query on real engines, not
-- reasoned about in the abstract. Ran against a real MariaDB 10.11.14
-- instance and this session's own MySQL 5.7.44 / 8.0.46 containers, each
-- loaded with 20,000 and then 150,000 synthetic `k9_progression` rows:
--
--   BEFORE this index, on ALL THREE engines:
--     EXPLAIN SELECT citizenid, xp FROM k9_progression ORDER BY xp DESC LIMIT 50;
--     -> type=ALL, key=NULL, rows=20000 (or 150000), Extra="Using filesort"
--     i.e. a full table scan PLUS an in-memory/on-disk sort of every row
--     in the table, every single time this command is run, to return 50
--     of them -- the EXACT anti-pattern this task named by example (an
--     existing admin query doing a filesort over 8,572 rows; a
--     maintenance script full-scanning 150k). This migration exists so
--     `/k9stats` does not become a third instance of it.
--
--   AFTER `ADD KEY idx_xp (xp)`, on ALL THREE engines:
--     -> type=index, key=idx_xp, rows=50, Extra="Using index"
--     (MySQL 8.0.46 additionally reports "Backward index scan; Using
--     index" in its Extra column -- functionally the same plan, more
--     specific wording). `rows=50` is the LIMIT, not the table size --
--     confirmed IDENTICAL at both 20,000 and 150,000 rows, i.e. this
--     query's cost no longer grows with table size at all. This works
--     because InnoDB secondary indexes always carry the table's primary
--     key alongside the indexed column, so `idx_xp` alone already
--     contains both columns `/k9stats` selects (`xp`, `citizenid`) --
--     a genuine covering index, needing zero lookups into the clustered
--     primary-key index per returned row.
--
--   Measured wall-clock, 150,000-row MariaDB table (buffer-pool-resident,
--   so this UNDERSTATES the real gap under disk I/O or lock contention on
--   a live server): ~0.083s before this index vs. ~0.014s after, for the
--   identical query.
--
-- WHY A NON-UNIQUE, SINGLE-COLUMN INDEX ON `xp` ALONE: `/k9stats` has no
-- WHERE clause at all (it is a global ranking, not a per-citizenid or
-- per-job lookup -- see server/leaderboard.lua's own header for why), so
-- there is no second column for a composite key to usefully lead with.
-- `xp` is NOT unique across citizenids (many K9s can share the same XP
-- total, especially near 0), so this is a plain `KEY`, never a `UNIQUE
-- KEY` -- attempting the latter would eventually throw a real duplicate-
-- key error against ordinary, legitimate data.
--
-- WHO NEEDS THIS FILE: any existing installation whose `k9_progression`
-- table predates this index (i.e. every installation before this pass --
-- sql/install.sql's own `k9_progression` CREATE TABLE is being updated in
-- this same pass to include `idx_xp` directly, per this repo's own
-- "install.sql has final shape, a migration backfills an existing DB"
-- convention already established by migrations 0003/0004 for their own
-- tables -- see this migration's own rollback file, sql/rollback/0009_down.sql,
-- for the reverse).
--
-- SAFE TO RE-RUN / PORTABLE, same technique and same reason migration 0004
-- already established for this exact resource: a plain
-- `ALTER TABLE ... ADD INDEX IF NOT EXISTS` is MariaDB-only and MySQL
-- 8.0.29+ only -- MySQL 5.7 and MySQL 8.0.0-8.0.28 (both above this
-- resource's real 5.7.8 floor, both still in the field, both re-verified
-- directly this pass, not assumed) throw a syntax error on that form.
-- Wrapped in the identical INFORMATION_SCHEMA.STATISTICS-guarded stored
-- procedure pattern instead, portable across all three targets this
-- resource supports. Running this file a second time, or against a
-- database already built from the updated install.sql, is a guaranteed
-- clean no-op.
--
-- NO DATA IS TOUCHED. This file only ever adds an index -- a pure lookup
-- structure over rows that stay exactly where they are. Row count before
-- == row count after, always. No column, no row, no other index is
-- modified.
--
-- ORDERING: independent of every other migration in this directory --
-- `k9_progression` shares no column or foreign relationship with
-- `k9_certifications`, `k9_partnerships`, `k9_permissions`,
-- `k9_certification_specializations`, or whatever 0007/0008 introduce.
-- Applying this file's numeric filename order (..., 0008, 0009) after
-- install.sql, as install.sql's own header already documents, always
-- satisfies any real ordering requirement this resource's migrations have
-- as a whole, even though this specific file has no dependency of its own
-- on any of them.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Step 0: ORDER-PROTECTION GUARD (db-schema foolproofing pass). The step
-- below is an ALTER TABLE `k9_progression`. If that table has never been
-- created on this database, MySQL/MariaDB's raw error is a cryptic
-- `ERROR 1146 (42S02): Table 'yourdb.k9_progression' doesn't exist`. This
-- guard replaces that with one plain-English refusal instead -- a
-- full-detail SELECT for GUI tools, plus a short SIGNAL (capped at 128
-- characters by MySQL/MariaDB) so the plain `mysql` CLI also stops with a
-- readable message. Same drop-before-and-after pattern as this file's own
-- main procedure below, so re-running this file after a refusal is safe.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0009_require_base_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0009_require_base_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_progression'
    ) THEN
        SELECT 'STOPPED - WRONG ORDER' AS status,
               'Table k9_progression does not exist in this database. This migration only ever ALTERs that table, so it must exist first. Run sql/install.sql (creates every john-k9 table in one pass) -- or, if you are applying migrations one file at a time, run sql/migrations/0002_create_k9_progression.sql before this file. Nothing has been changed by this migration.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 0009 stopped: k9_progression missing. See detail above. Run install.sql first.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0009_require_base_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0009_require_base_table`;


DROP PROCEDURE IF EXISTS `john_k9_migration_0009_add_idx_xp`;

DELIMITER $$

CREATE PROCEDURE `john_k9_migration_0009_add_idx_xp`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_progression'
          AND INDEX_NAME = 'idx_xp'
    ) THEN
        ALTER TABLE `k9_progression`
            ADD KEY `idx_xp` (`xp`);
    END IF;
END$$

DELIMITER ;

CALL `john_k9_migration_0009_add_idx_xp`();

DROP PROCEDURE IF EXISTS `john_k9_migration_0009_add_idx_xp`;
