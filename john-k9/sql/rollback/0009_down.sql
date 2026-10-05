-- =====================================================================
-- john-k9 :: ROLLBACK 0009 :: remove k9_progression.idx_xp
--
-- Reverses EXACTLY ONE migration:
--   sql/migrations/0009_add_k9_progression_idx_xp.sql
--
-- WHAT THIS REMOVES (schema only -- see "NO DATA IS LOST" below):
--   * KEY `idx_xp` (xp) on `k9_progression`
--
-- NO DATA IS LOST. `idx_xp` is a plain, non-unique lookup index -- pure
-- derived structure over rows that stay exactly where they are. Every
-- citizenid's real, persisted `xp` total in `k9_progression` survives this
-- file untouched. Row count before == row count after, always. This
-- mirrors sql/rollback/0004_down.sql's own "indexes are safe to drop, only
-- whole-table CREATEs are not" precedent exactly -- unlike
-- sql/rollback/0005_down.sql (a no-op report, because migration 0005
-- CREATEs a whole table whose rows would be lost by a real DROP), this
-- migration only ever ADDs an index, so this rollback can safely perform
-- the real, matching DROP.
--
-- ///////////////////////////////////////////////////////////////////////
-- READ THIS BEFORE RUNNING -- WHAT YOU GIVE UP
--
-- `idx_xp` is what makes `/k9stats` (server/leaderboard.lua,
-- Config.Features.K9Leaderboard) a cheap, bounded, `Extra: Using index`
-- query. Without it, `/k9stats` reverts to a full table scan PLUS a
-- filesort of the ENTIRE `k9_progression` table on every single
-- invocation (verified by real EXPLAIN this pass -- see migration 0009's
-- own header for the exact `type=ALL`/`Using filesort` numbers on a
-- 20,000- and 150,000-row table, on MariaDB 10.11, MySQL 5.7.44, and
-- MySQL 8.0.46 alike) -- a real, avoidable DB-load footgun on a busy,
-- long-running server, not merely a slower response. Running this
-- rollback does NOT disable `/k9stats` itself (it will keep working,
-- correctly, just expensively) -- if you want the command gone entirely,
-- set `Config.Features.K9Leaderboard = false` instead, which is free and
-- reversible with no schema change at all.
--
-- So: run this file to get UNSTUCK from a bad index (see
-- README.md's "Uninstalling / rolling back" section for the general
-- workflow), fix the underlying
-- problem, then run sql/migrations/0009_... again to put it back. Do not
-- leave a production server with `/k9stats` enabled and this rollback
-- applied for any length of time.
-- ///////////////////////////////////////////////////////////////////////
--
-- SAFE TO RE-RUN. Wrapped in the same INFORMATION_SCHEMA-guarded stored
-- procedure pattern sql/rollback/0004_down.sql already uses, for the
-- identical portability reason: a plain `ALTER TABLE ... DROP INDEX IF
-- EXISTS` is MariaDB-only and MySQL 8.0.29+ only -- MySQL 5.7 and MySQL
-- 8.0.0-8.0.28 throw a syntax error on that form. Running this file a
-- second time, or against a database that never had `idx_xp` at all
-- (e.g. one whose install.sql predates it and never applied migration
-- 0009 either), is a guaranteed clean no-op.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql.
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0009_drop_idx_xp`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0009_drop_idx_xp`()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_progression'
          AND INDEX_NAME = 'idx_xp'
    ) THEN
        ALTER TABLE `k9_progression` DROP INDEX `idx_xp`;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0009_drop_idx_xp`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0009_drop_idx_xp`;
