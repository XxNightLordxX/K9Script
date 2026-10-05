-- =====================================================================
-- john-k9 :: migration 0002 :: create k9_progression
--
-- WHO NEEDS THIS FILE: an existing installation whose `john-k9/sql/install.sql`
-- was applied BEFORE `k9_progression` existed in it -- the exact historical
-- gap this resource's own README.md document: `server/progression.lua`
-- shipped reading/writing this table before install.sql created it, and
-- because both call sites are pcall-wrapped, every XP award silently
-- no-op'd at the DB layer instead of erroring (see install.sql's own
-- `k9_progression` header for the full account). A fresh install never
-- needs this file -- current install.sql already creates this table.
--
-- IDEMPOTENT / SAFE TO RE-RUN: `CREATE TABLE IF NOT EXISTS` is a no-op if
-- the table already exists -- never ALTERs, never DROPs, never touches
-- existing rows. Safe to run any number of times, in any order relative to
-- install.sql or the other migration files in this folder.
--
-- NO DATA LOSS RISK: because every prior write attempt against a missing
-- `k9_progression` table failed silently (pcall) rather than throwing,
-- there was never a real row to lose on an affected database -- applying
-- this migration only ever adds the ability to persist going forward, it
-- cannot conflict with or overwrite anything.
--
-- SHAPE: byte-for-byte the same table definition documented in
-- `john-k9/sql/install.sql`'s own `k9_progression` header comment (read
-- that comment for the full design rationale -- not repeated here to avoid
-- two copies drifting out of sync).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_progression` (
  `citizenid`  VARCHAR(50)  NOT NULL,
  `xp`         INT UNSIGNED NOT NULL DEFAULT 0,
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
