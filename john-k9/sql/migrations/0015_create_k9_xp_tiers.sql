-- =====================================================================
-- john-k9 :: migration 0015 :: server/xptiers.lua runtime XP-rank
--                                  overlay
--
-- Config.Features nothing new required -- this surface is high-command-
-- gated in code (server/xptiers.lua's own CanManageXPTiers), not behind a
-- separate feature flag, matching migration 0010's own identical framing.
--
-- Owner's own words for THIS half of the requirement: "...or even add or
-- remove permissions, set experience level for each rank up etc." ("add or
-- remove permissions" is migration 0013, k9_permission_keys -- a separate,
-- concurrently-landing pass). This migration is the "set experience level
-- for each rank" half: a database-backed overlay over `Config.XPTiers`
-- (config.lua's four shipped ranks -- Recruit/Trained/Veteran/Elite as of
-- this writing), editable from the K9 Command Tablet at runtime, persisted
-- across restarts, with a full audit trail -- following the SAME
-- "config = shipped defaults; DB rows override" shape migration 0010
-- established for `Config.CertificationTiers`, with one deliberate
-- difference explained in server/xptiers.lua's own header ("WHY IN-PLACE
-- MUTATION, NOT A SEPARATE MERGED CATALOG"): the override is APPLIED by
-- mutating the live `Config.XPTiers[ordinal]` table in place, not by
-- building a second parallel catalog structure -- this migration's own
-- schema is unaffected by that choice either way; it is purely how
-- server/xptiers.lua's own Lua code consumes what this migration stores.
--
-- SCOPE, STATED PLAINLY (see server/xptiers.lua's own header, "SCOPE
-- DECISION", for the full reasoning): this migration's table holds ONLY
-- per-RANK field overrides for a rank that ALREADY EXISTS in
-- Config.XPTiers, keyed by that rank's fixed 1-based ARRAY POSITION
-- (`ordinal`), never a free-form/addable key. There is no create, delete,
-- or reorder surface for XP ranks in this pass -- unlike migration 0010's
-- `k9_certification_tiers` (an open-ended, addable/removable/reorderable
-- catalog with its own `deleted` tombstone column), this table has NO
-- tombstone column at all, because there is nothing to tombstone: a rank
-- can only ever be RE-VALUED, never removed, through this surface.
--
-- WHO NEEDS THIS FILE: any installation that does not yet have these two
-- tables -- which, at the time of writing, is EVERY installation (both are
-- brand new).
--
-- IDEMPOTENT / SAFE TO RE-RUN: both statements below are a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance, matching migrations 0007/0008/0010/0011/0013's
-- own identical reasoning for why a brand-new table needs none of that.
-- Running this file twice, or before/after install.sql, or against a
-- database that already has one but not the other of these two tables,
-- always produces the same end state.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- NO FK ANYWHERE IN THIS FILE, matching this schema's own established "no
-- FK, relational integrity enforced at the application layer" convention.
-- `k9_xp_tier_audit.ordinal` is NOT a foreign key into
-- `k9_xp_tiers.ordinal` for the identical reason
-- `k9_certification_tier_audit.tier_key` is not one into
-- `k9_certification_tiers.tier_key` (migration 0010's own header): a rank
-- that has NEVER been edited (still purely a config.lua default) has NO
-- row in `k9_xp_tiers` at all, yet server/xptiers.lua's own audit trail
-- must still be able to record the FIRST edit ever made to it -- an FK
-- here would reject exactly that common, expected case.
--
-- ORDERING: independent of every other table this resource has --
-- `k9_xp_tiers`/`k9_xp_tier_audit` reference no other table's key at all.
-- Applying this file's numeric filename order after install.sql, as this
-- resource's own migrations directory already documents, always satisfies
-- any real ordering requirement this resource's migrations have as a
-- whole, even though this specific file has no dependency of its own on
-- any of the others.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql --
-- this migration's own tables do not individually need that floor (no
-- generated column, no functional index), but ship under the same
-- requirement as the rest of this schema for one consistent minimum across
-- the whole resource.
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_xp_tiers -- current, high-command-edited field overrides for an
-- EXISTING XP rank. One row per rank (`ordinal`) that has EVER been
-- touched by a tablet edit. A rank's absence from this table means "use
-- Config.XPTiers[ordinal]'s own shipped default for every field" --
-- mirrors k9_runtime_feature_overrides' own "absence = config default"
-- contract (migration 0007) exactly.
--
-- `ordinal` INT: the rank's fixed 1-based POSITION in Config.XPTiers, NOT
-- an auto-increment/synthetic id and NOT a free-form string key -- ranks
-- are neither addable nor removable through this surface (see this file's
-- own header "SCOPE"), so a rank's array position IS a stable identity
-- for as long as this pass's own design holds. Rank 1 is REQUIRED by
-- server/progression.lua's own onResourceStart shape guard to always
-- resolve to exactly 0 XP -- server/xptiers.lua's own application-layer
-- validation (never this table's own schema, which has no CHECK
-- constraint for it) is what enforces that a row for ordinal 1 can never
-- carry a non-zero `xp_threshold` in practice.
--
-- `xp_threshold` INT: the rank's minimum accumulated XP. NOT NULL --
-- unlike `medkit_cooldown_multiplier`/`badge` below, every rank has always
-- had a real threshold in Config.XPTiers, so there is no "unset" state to
-- represent for this column.
--
-- `label` VARCHAR(60): display-only, rendered by the tablet and pushed to
-- clients via the existing `john-k9:client:xpTierChanged` event --
-- validated server-side (character filter mirroring
-- server/certtiers.lua's own IsValidTierLabel) before ever reaching this
-- column, for the identical "defense in depth on top of textContent-only
-- rendering discipline" reason migration 0007's header gives for
-- k9_tablet_theme's own header_title column.
--
-- `speed_multiplier` / `scent_range_multiplier` DOUBLE: the rank's
-- movement-speed and scent-range bonus multipliers -- mirrors
-- Config.XPTiers' own `speedMultiplier`/`scentRangeMultiplier` fields
-- exactly. DOUBLE (not DECIMAL) matches this resource's own established
-- precedent for a real-valued gameplay number (see
-- k9_equipment_shop_locations' `x`/`y`/`z`/`heading` columns, migration
-- 0011) and loses no precision against a Lua number, which is a double
-- internally regardless.
--
-- `medkit_cooldown_multiplier` DOUBLE NULL: OPTIONAL -- mirrors
-- Config.XPTiers' own OPTIONAL `medkitCooldownMultiplier` field (present
-- on the shipped Veteran row only). NULL means "this rank has no medkit
-- cooldown reduction configured", the identical meaning an absent field on
-- a Config.XPTiers[n] Lua table already carries -- see
-- server/progression.lua's own GetXPTierMedkitCooldownMs, which already
-- treats a missing/nil multiplier as "not configured", never an error.
--
-- `badge` VARCHAR(30) NULL: OPTIONAL -- mirrors Config.XPTiers' own
-- OPTIONAL `badge` field (present on the shipped Elite row only, currently
-- display-only -- see server/progression.lua's own "XP TIER UNLOCKS"
-- section, Elite entry). NULL means "no badge configured for this rank".
--
-- `updated_by` / `updated_at`: who last edited this rank's fields and
-- when -- ON UPDATE CURRENT_TIMESTAMP so any edit bumps this
-- automatically; `created_at` is separate and immutable so "when was this
-- rank first ever edited from its config.lua default" survives any later
-- edit.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_xp_tiers` (
  `ordinal`                    INT          NOT NULL,
  `xp_threshold`               INT          NOT NULL,
  `label`                      VARCHAR(60)  NOT NULL,
  `speed_multiplier`           DOUBLE       NOT NULL,
  `scent_range_multiplier`     DOUBLE       NOT NULL,
  `medkit_cooldown_multiplier` DOUBLE       DEFAULT NULL,
  `badge`                      VARCHAR(30)  DEFAULT NULL,
  `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`                 VARCHAR(50)  NOT NULL,
  `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`ordinal`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_xp_tier_audit -- append-only "who changed which rank, and how"
-- trail. Never updated or deleted by this resource. Deliberately ONE
-- table (not split per action), mirroring migration 0007/0010/0013's own
-- single-audit-table-with-a-discriminator-column design.
--
-- `action` VARCHAR(20): always the literal `'xp_tier_update'` as of this
-- migration (this pass has no create/delete/reorder action kind at all --
-- see this file's own header "SCOPE") -- kept as a real column rather than
-- omitted so a future action kind, should one ever be added, needs no
-- schema change.
--
-- `ordinal` INT: which rank this audit row is about. NOT a foreign key --
-- see this file's own header "NO FK" for why.
--
-- `detail` TEXT: a human-readable before/after field-by-field summary
-- (e.g. "xp: 9000 -> 15000, speedMultiplier: 1.15 -> 1.15 ... -- 3
-- currently-connected K9(s) re-ranked LOWER by this edit"). Plain text,
-- not JSON -- matching migration 0010's own header reasoning (this
-- resource's Lua runtime has no confirmed, luacheck-allowlisted `json`
-- global available to any file).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_xp_tier_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `ordinal`      INT          NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one rank, most recent first" --
  -- the natural admin/audit query over this table, mirroring migration
  -- 0010's own idx_tier_key_changed_at precedent.
  KEY `idx_ordinal_changed_at` (`ordinal`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
