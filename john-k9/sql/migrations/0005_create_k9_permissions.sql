-- =====================================================================
-- john-k9 :: migration 0005 :: create k9_permissions
--
-- WHO NEEDS THIS FILE: an existing installation whose `john-k9/sql/install.sql`
-- was applied BEFORE `k9_permissions` existed in it (i.e. before
-- `Config.Features.PermissionGrants` / `Config.Permissions` /
-- `server/permissions.lua` landed). A fresh install never needs this file
-- -- install.sql already creates this table in final shape in one pass.
--
-- IDEMPOTENT / SAFE TO RE-RUN: `CREATE TABLE IF NOT EXISTS` is a no-op if
-- the table already exists in ANY shape -- this statement never ALTERs,
-- never DROPs, never touches existing rows. Running this against a
-- database that already has `k9_permissions` (e.g. one built from the
-- current install.sql) is a guaranteed no-op; running it against a
-- database that has never had this table creates it. Either way, running
-- this file twice, or after install.sql, or before install.sql, produces
-- the identical end state -- same reasoning as migration 0001
-- (`k9_partnerships`), which this file mirrors exactly in shape and
-- rationale (a bare `CREATE TABLE IF NOT EXISTS` for a brand-new table
-- needs no INFORMATION_SCHEMA-guarded stored-procedure dance the way
-- migrations 0003/0004's `ALTER TABLE ... ADD COLUMN`/`ADD KEY` steps do
-- -- `CREATE TABLE IF NOT EXISTS` is itself portable across every
-- MySQL/MariaDB version this resource supports; the portability problem
-- those other migrations work around is specific to `ADD COLUMN IF NOT
-- EXISTS`/`ADD INDEX IF NOT EXISTS`, which MySQL 5.7 and MySQL
-- 8.0.0-8.0.28 do not support -- not to `CREATE TABLE IF NOT EXISTS`,
-- which every version back to MySQL 3.x understands).
--
-- SHAPE: byte-for-byte the same table definition documented in
-- `john-k9/sql/install.sql`'s own `k9_permissions` header comment (read
-- that comment for the full design rationale -- not repeated here to avoid
-- two copies drifting out of sync) -- including the `active_permission_key`
-- generated column and its backing unique key, so a database that goes
-- straight from "no k9_permissions table at all" to running this migration
-- file lands directly in final shape and never has a window where grants
-- are possible without the race-safety backstop.
--
-- VERSION REQUIREMENT: same floor as the rest of this resource -- MySQL
-- >= 5.7.8 or MariaDB >= 10.2, because `active_permission_key` is an
-- INDEXED VIRTUAL GENERATED COLUMN (see sql/install.sql's own top-of-file
-- header for the full verified-by-execution version matrix). Do not run
-- this file against a database not already meeting install.sql's own
-- floor.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- ORDERING: independent of migrations 0001-0004 -- `k9_permissions` shares
-- no column or foreign relationship with `k9_certifications`,
-- `k9_partnerships`, `k9_search_log`, or `k9_progression`. Applying this
-- file's numeric filename order (0001, 0002, 0003, 0004, 0005, ...) after
-- install.sql, as documented in install.sql's own header, always satisfies
-- any real ordering requirement this resource's migrations have as a
-- whole, even though this specific file does not depend on any of the
-- other four tables existing first.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_permissions` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,
  `permission`       VARCHAR(50)  NOT NULL,
  `granted_by`       VARCHAR(50)  NOT NULL,
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,

  `active_permission_key` VARCHAR(105)
                       GENERATED ALWAYS AS (
                         CASE WHEN `active` = 1
                              THEN CONCAT(`citizenid`, '::', `permission`)
                              ELSE NULL
                         END
                       ) VIRTUAL,

  PRIMARY KEY (`id`),
  KEY `idx_citizen_permission_active` (`citizenid`, `permission`, `active`),
  KEY `idx_permission_active` (`permission`, `active`),
  UNIQUE KEY `uq_one_active_permission_per_citizen` (`active_permission_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
