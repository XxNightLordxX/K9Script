-- =====================================================================
-- john-k9 :: migration 0007 :: server/runtimecontrol.lua persistence
--
-- Config.Features.RuntimeFeatureControl / Config.Features.TabletTheming.
-- Four brand-new tables, no ALTER of anything pre-existing:
--
--   k9_runtime_feature_overrides -- CURRENT effective override state, one
--     row per override key ('feature:<Name>' or 'tuning:<Config.path>').
--     Read once at server/runtimecontrol.lua's own file-load time to
--     re-apply every override on top of config.lua's shipped defaults
--     (a restart must not silently revert an override -- this table is
--     how that survives one). A row's ABSENCE means "no override, use the
--     config.lua default" -- resetting an override DELETES its row here
--     rather than writing a sentinel, so "back to default" has an
--     unambiguous, obvious representation (see server/runtimecontrol.lua's
--     own header for the full contract).
--
--   k9_runtime_override_audit -- APPEND-ONLY history of every override
--     change (set OR reset), who made it, and the before/after value.
--     Never updated or deleted by this resource -- this is the "who
--     changed what, from what, to what" trail the owner explicitly asked
--     for. A row here survives even after the corresponding
--     k9_runtime_feature_overrides row is deleted by a reset.
--
--   k9_tablet_theme -- CURRENT tablet theme, always exactly one row
--     (id = 1). Cosmetic only -- see server/runtimecontrol.lua's own
--     header for why this table can never influence authorization.
--
--   k9_tablet_theme_audit -- APPEND-ONLY history of every theme change,
--     full snapshot per row (not a diff -- the whole surface is six small
--     columns, so a full snapshot per change is simpler to read back than
--     a sparse diff and costs nothing meaningful in row size).
--
-- WHO NEEDS THIS FILE: any installation that does not yet have these four
-- tables -- which, at the time of writing, is EVERY installation (all four
-- are brand new). Run this after install.sql and migrations 0001-0006, per
-- this resource's own documented numeric-filename ordering.
--
-- IDEMPOTENT / SAFE TO RE-RUN: every statement below is a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance. Mirrors migration 0005's own reasoning
-- (`k9_permissions`) for why a brand-new table needs none of that: the
-- portability problem those procedures work around is specific to
-- `ADD COLUMN IF NOT EXISTS` / `ADD INDEX IF NOT EXISTS` (MariaDB-only /
-- MySQL 8.0.29+ only), not to `CREATE TABLE IF NOT EXISTS`, which every
-- MySQL/MariaDB version back to MySQL 3.x already understands natively.
-- Running this file twice, or before/after install.sql, or against a
-- database that already has some but not all four tables, always produces
-- the same end state.
--
-- NO GENERATED COLUMNS, UNLIKE 0001/0004/0005/0006: none of these four
-- tables need a DB-level "at most one active row" backstop the way
-- k9_certifications/k9_partnerships/k9_permissions do -- both "current
-- state" tables here use a real, non-generated PRIMARY KEY as their own
-- single-row-per-key guarantee instead (override_key / a fixed id = 1),
-- so this migration does NOT require the MySQL >= 5.7.8 / MariaDB >= 10.2
-- floor for its OWN sake. Kept identical to that floor anyway, matching
-- every other migration in this directory, since a server running any of
-- 0001/0004/0005/0006 already meets it.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- VERIFIED BY EXECUTION, this pass: applied clean (fresh database, no
-- prior john-k9 tables) and re-applied a second consecutive time
-- (idempotency) against both MySQL 5.7.44 and MySQL 8.0.46 real
-- containers -- see this resource's own verification notes for the exact
-- commands/output. No MariaDB instance was reachable in this execution
-- environment to add a third data point; every SQL construct used here
-- (plain `CREATE TABLE IF NOT EXISTS`, no generated columns, no
-- version-gated syntax) is also used unconditionally by migrations
-- 0001/0002/0005 above, which this repo's own sql/install.sql header
-- already records as verified clean on MariaDB 10.11 -- there is nothing
-- in this file that construct did not already exercise.
--
-- ORDERING: independent of every other table this resource has --
-- `k9_runtime_feature_overrides`/`k9_runtime_override_audit` reference no
-- other table's key at all (override_key is a resource-defined string,
-- e.g. 'feature:HighCommand', not a foreign key), and the two theme
-- tables are a self-contained pair. Applying this file's numeric filename
-- order (..., 0006, 0007) after install.sql, as documented in
-- install.sql's own header, always satisfies any real ordering
-- requirement this resource's migrations have as a whole, even though
-- this specific file has no dependency on any of the other six tables.
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_runtime_feature_overrides -- current effective override state.
--
-- override_key encodes BOTH what kind of override this is and which
-- Config value it targets, in one string, so a single table (and a
-- single re-apply loop at server start) covers both Part 1 surfaces this
-- migration backs:
--   'feature:<Config.Features key>'         e.g. 'feature:HighCommand'
--   'tuning:<dotted Config path>'           e.g. 'tuning:Tracking.Scent.searchCooldownMs'
-- `value` is always stored as its plain string form ('true'/'false' for a
-- feature, a plain number-as-string for a tuning value) -- server/
-- runtimecontrol.lua owns parsing it back to the right Lua type; this
-- table does not need to distinguish the two at the SQL layer, only at
-- read time, which is exactly where server/runtimecontrol.lua's own
-- allowlist (which already knows each key's kind) already has to look
-- the key up anyway.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_runtime_feature_overrides` (
  `override_key` VARCHAR(100) NOT NULL,
  `kind`         VARCHAR(10)  NOT NULL,          -- 'feature' | 'tuning' -- see header
  `value`        VARCHAR(64)  NOT NULL,          -- plain string form of the override; see header
  `updated_by`   VARCHAR(50)  NOT NULL,          -- citizenid of the high-command officer who set this override
  `updated_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`override_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_runtime_override_audit -- append-only "who changed what, from what,
-- to what" trail. A row here is NEVER updated or deleted by this
-- resource, including when the corresponding k9_runtime_feature_overrides
-- row is later deleted by a reset-to-default -- the history of that
-- override having existed at all must survive its own removal.
-- `old_value`/`new_value` are nullable specifically to represent the two
-- edges a plain override table cannot: `old_value IS NULL` means "there
-- was no prior override, this was the config.lua default before this
-- change", and `new_value IS NULL` means "reset back to the config.lua
-- default" (the row this audits was DELETED from
-- k9_runtime_feature_overrides by this same action).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_runtime_override_audit` (
  `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `override_key`  VARCHAR(100) NOT NULL,
  `kind`          VARCHAR(10)  NOT NULL,
  `old_value`     VARCHAR(64)  DEFAULT NULL,
  `new_value`     VARCHAR(64)  DEFAULT NULL,
  `changed_by`    VARCHAR(50)  NOT NULL,
  `changed_at`    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one override key, most recent
  -- first" -- the natural admin/audit query over this table.
  KEY `idx_override_key_changed_at` (`override_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_tablet_theme -- current tablet theme. Always exactly one row
-- (id = 1, enforced at the application layer by server/runtimecontrol.lua
-- always upserting id = 1 and never inserting any other id -- a second
-- row would just never be read by anything, not a corruption risk, but
-- there is no reason for one to ever exist).
--
-- COSMETIC ONLY: every column here is presentation state (colour/density/
-- header text). Nothing in this table is ever consulted by any
-- authorization check anywhere in this resource -- see
-- server/runtimecontrol.lua's own header for the full "theming can never
-- change what anyone is authorized to do or see" contract this table
-- exists under.
--
-- Colour columns are VARCHAR(7) to hold exactly '#RRGGBB' -- the
-- resource-side validator (server/runtimecontrol.lua) only ever accepts
-- that exact shape before a value reaches this column, so the column
-- width is a belt-and-suspenders bound, not the primary validation layer.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_tablet_theme` (
  `id`               TINYINT UNSIGNED NOT NULL,
  `primary_color`    VARCHAR(7)  NOT NULL DEFAULT '#2563eb',
  `accent_color`     VARCHAR(7)  NOT NULL DEFAULT '#f59e0b',
  `background_color` VARCHAR(7)  NOT NULL DEFAULT '#111827',
  `text_color`       VARCHAR(7)  NOT NULL DEFAULT '#f9fafb',
  `density`          VARCHAR(20) NOT NULL DEFAULT 'comfortable',
  `header_title`     VARCHAR(40) NOT NULL DEFAULT 'K9 Command Tablet',
  `updated_by`       VARCHAR(50) DEFAULT NULL,
  `updated_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_tablet_theme_audit -- append-only, full-snapshot-per-change history.
-- A full snapshot (not a diff) per row: the whole theme surface is six
-- small columns, so snapshotting all six on every change is simpler to
-- read back chronologically ("what did the tablet look like on date X")
-- than reconstructing state from a sparse diff log, at negligible extra
-- row size.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_tablet_theme_audit` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `primary_color`    VARCHAR(7)  NOT NULL,
  `accent_color`     VARCHAR(7)  NOT NULL,
  `background_color` VARCHAR(7)  NOT NULL,
  `text_color`       VARCHAR(7)  NOT NULL,
  `density`          VARCHAR(20) NOT NULL,
  `header_title`     VARCHAR(40) NOT NULL,
  `changed_by`       VARCHAR(50) NOT NULL,
  `changed_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
