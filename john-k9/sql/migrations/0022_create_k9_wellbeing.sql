-- =====================================================================
-- john-k9 :: migration 0022 :: create k9_wellbeing
--
-- WHO NEEDS THIS FILE: an existing installation whose `john-k9/sql/install.sql`
-- was applied BEFORE `k9_wellbeing` existed in it. A brand-new install does
-- NOT need to run this file by hand -- `sql/install.sql` now also creates
-- this table directly (added in the same follow-up change that closed the
-- CROSS-FILE DEPENDENCY note below), matching this resource's own
-- established "install.sql creates every table any migration creates"
-- convention. Running this file anyway (e.g. via `sql/k9_setup.sh`, which
-- runs every file in this folder after install.sql) is always safe --
-- `CREATE TABLE IF NOT EXISTS` is a guaranteed no-op once install.sql has
-- already created it.
--
-- WHAT THIS TABLE IS FOR: server/wellbeing.lua's six per-K9 stats
-- (fatigue, mood, fearStress, injury, hunger, thirst) used to live ONLY in
-- that file's own in-memory table, with no database write of any kind
-- ever existing for it -- a routine resource restart (or a crash) silently
-- reset every online K9's condition to fresh-and-uninjured, no matter what
-- had happened to it in-game, with no config flag, no log line and no
-- player-visible warning that this was happening. This table is what
-- server/wellbeing.lua's new `K9Store.Wellbeing_Get`/
-- `K9Store.Wellbeing_Upsert` accessors read/write, one row per citizenid,
-- exactly mirroring `k9_progression`'s own shape (a single UPSERT-able
-- row per citizenid, no history table -- there is nothing here worth
-- keeping a change log of, unlike a certification grant/revoke).
--
-- WHAT IS DELIBERATELY NOT IN THIS TABLE: the four short-lived
-- "GetGameTimer() timer window" fields server/wellbeing.lua's own
-- in-memory struct also tracks (distractedUntil, hesitatingUntil,
-- hesitationEpisodeStartedAt, injuryDeathEpisodeStartedAt) are
-- process-uptime-relative timestamps, not wall-clock ones -- meaningless,
-- and actively misleading, the instant the server process restarts. Only
-- the six real, wall-clock-meaningful magnitude stats are persisted. See
-- server/wellbeing.lua's own header, "DATABASE PERSISTENCE" section, for
-- the full design writeup this table exists to support.
--
-- CROSS-FILE DEPENDENCY, DISCLOSED WHEN THIS MIGRATION WAS AUTHORED AND
-- NOW CLOSED IN A FOLLOW-UP CHANGE: this migration was originally authored
-- under a file-ownership boundary that did not include server/datastore.lua
-- (the ONLY file in this resource permitted to name a `k9_*` table or call
-- `MySQL.*` directly), sql/install.sql, sql/preflight_check.sql,
-- sql/migration_status.sql, sql/rollback/uninstall_all.sql,
-- sql/rollback/backup_k9_tables.sh, or tests/schemaconvergence_spec.lua's
-- own hand-maintained MIGRATION_FILES_THAT_CREATE_TABLES list -- so this
-- table shipped for one pass with nothing reading or writing it yet.
-- CONFIRMED, this follow-up: every one of those files now carries a
-- matching `k9_wellbeing` entry -- server/datastore.lua's
-- `K9Store.Wellbeing_Get(citizenid)` (mirrors `MySQL.single.await`: nil =
-- no row) and `K9Store.Wellbeing_Upsert(citizenid, row)` (SafeWrite-style:
-- returns a boolean, never throws) both exist and are exactly what
-- server/wellbeing.lua's own soft-guarded call sites
-- (`type(K9Store.Wellbeing_Get) == 'function'`) now find and use. That
-- guard itself was never removed and still matters: it is what lets this
-- table, and this whole feature, keep degrading safely to memory-only
-- behaviour on any server where the database is unreachable or
-- `Config.Database.enabled`/`Config.Wellbeing.Persistence.enabled` is
-- `false`, exactly as before.
--
-- IDEMPOTENT / SAFE TO RE-RUN: `CREATE TABLE IF NOT EXISTS` is a no-op if
-- the table already exists -- never ALTERs, never DROPs, never touches
-- existing rows. Safe to run any number of times, in any order relative
-- to install.sql or the other migration files in this folder. Never
-- writes into any table this resource does not own -- this file creates
-- exactly one new table and touches nothing else.
--
-- NO DATA LOSS RISK ON A LIVE, POPULATED DATABASE: this is a brand-new
-- table name, never previously used by this resource -- there is no
-- existing `k9_wellbeing` data anywhere for this migration to collide
-- with, and no other table's rows are read, modified, or referenced by
-- this statement.
--
-- SHAPE: one row per citizenid, matching `k9_progression`'s own
-- (migration 0002 / install.sql) established style for a single-row-per-
-- citizenid UPSERT-able table -- VARCHAR(50) citizenid primary key (same
-- width as every other citizenid column in this schema), DECIMAL(6,2) for
-- each 0-100-range stat (two decimal places is ample precision for a
-- gauge this resource already displays as a whole/near-whole number; the
-- full-precision running value stays in server/wellbeing.lua's own memory
-- for the whole session and is only ever rounded at the moment it is
-- flushed to disk), and the same DATETIME `updated_at ON UPDATE
-- CURRENT_TIMESTAMP` convention `k9_progression` already uses.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_wellbeing` (
  `citizenid`   VARCHAR(50)  NOT NULL,
  `fatigue`     DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `mood`        DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `fear_stress` DECIMAL(6,2) NOT NULL DEFAULT 0.00,
  `injury`      DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `hunger`      DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `thirst`      DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `updated_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
