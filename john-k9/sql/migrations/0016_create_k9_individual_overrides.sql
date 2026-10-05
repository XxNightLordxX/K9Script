-- =====================================================================
-- john-k9 :: migration 0016 :: server/k9profiles.lua per-INDIVIDUAL K9
--                                  override ("god mode" layer)
--
-- Owner's own words for THIS pass: high command should be "a god over that
-- tablet with full customization over everything related to that K9", and
-- separately, "make this a tier system." Two DIFFERENT ladders already
-- existed before this pass for the "tier system" half:
--   * `k9_certification_tiers` (migration 0010, server/certtiers.lua) --
--     trainee/certified/senior (+ operator-added), carrying toggleable
--     CAPABILITIES.
--   * `k9_xp_tiers` (migration 0015, server/xptiers.lua) -- Recruit/
--     Trained/Veteran/Elite, ALREADY carrying per-rank speedMultiplier/
--     scentRangeMultiplier/medkitCooldownMultiplier -- i.e. "each tier of
--     dog gets a longer sprint" already exists, per RANK, not per dog.
-- This migration does NOT add a third parallel ladder. It answers the
-- OTHER half of the owner's ask -- "everything related to THAT K9",
-- singular, by citizenid -- a layer that sits ON TOP of whichever XP rank a
-- citizenid's K9 currently resolves to, for the rare case an operator wants
-- to hand-tune ONE specific dog rather than an entire rank.
--
-- RESOLUTION ORDER, STATED HERE (mirrored in server/k9profiles.lua's own
-- header, the single source of truth a future reader should trust if this
-- comment and that one ever disagree): GLOBAL DEFAULT (Config.XPTiers[1],
-- the base rank) -> XP TIER PROFILE (GetXPTier(citizenid), which already
-- folds the global default in as its own floor) -> INDIVIDUAL OVERRIDE
-- (this table, PER FIELD, highest precedence). A citizenid with no override
-- row at all, or one with every field NULL, resolves EXACTLY as if this
-- table did not exist.
--
-- SCOPE, STATED PLAINLY: only the three fields that already have a real,
-- live composition point in this codebase (server/progression.lua's
-- Config.XPTiers speedMultiplier/scentRangeMultiplier/
-- medkitCooldownMultiplier) are overridable here. "Everything related to
-- that K9" was investigated further and deliberately NOT extended to: (a)
-- wellbeing stat maxima (server/wellbeing.lua's own Clamp(...) call sites
-- read Config.Wellbeing.<Stat>.max as one global constant with no
-- per-citizenid composer to hook -- server/progression.lua's own "XP TIER
-- UNLOCKS" section already investigated and rejected this exact extension
-- for the sibling XP-tier system, on cost/ownership grounds, not
-- farmability -- the same finding applies here unchanged), (b) combat
-- action cooldowns (server/combat.lua's own anti-farm floors are FILE-LOCAL
-- CONSTANTS by explicit design -- "the only way to weaken it is to edit
-- this file's own source under code review" -- a database-editable
-- per-citizenid override of a PvP cooldown is exactly the class of footgun
-- that comment exists to forbid), and (c) permissions/capabilities (already
-- owned by k9_permissions/k9_certification_tier_capabilities -- a THIRD
-- place to grant the same class of thing would reopen the exact
-- "which one wins" ambiguity this migration's own header goes out of its
-- way to avoid). See server/k9profiles.lua's own header for the full
-- writeup this paragraph summarizes.
--
-- TOMBSTONE, NOT HARD DELETE (mirrors migration 0010's `deleted` column,
-- for the SAME "say what you did, permanently" audit-trail convention this
-- schema applies everywhere else) -- NOT because a hard delete would be
-- unsafe here (nothing else in this schema references a citizenid's
-- override row by foreign key the way k9_certifications.tier references a
-- tier_key, so there is no HAZARD-2-shaped corruption risk to avoid), but
-- for consistency with every other admin-edited current-state table in
-- this resource and so a reset is itself an audited, reversible-by-re-edit
-- action rather than a silent row disappearance.
--
-- IDEMPOTENT / SAFE TO RE-RUN: both statements below are a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance, matching migrations 0007/0008/0010/0011/0013/0015's
-- own identical reasoning for why a brand-new table needs none of that.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- NO FK ANYWHERE IN THIS FILE, matching this schema's own established "no
-- FK, relational integrity enforced at the application layer" convention.
-- `k9_individual_override_audit.citizenid` is NOT a foreign key into
-- `k9_individual_overrides.citizenid` for the identical reason
-- `k9_certification_tier_audit.tier_key` is not one into
-- `k9_certification_tiers.tier_key` (migration 0010's own header): the
-- FIRST edit ever made for a citizenid has, by definition, no prior row in
-- `k9_individual_overrides` at the instant the audit row is written.
--
-- ORDERING: independent of every other table this resource has --
-- `k9_individual_overrides`/`k9_individual_override_audit` reference no
-- other table's key at all (citizenid is a plain, unvalidated-by-FK string
-- everywhere else in this schema already, e.g. k9_certifications.citizenid,
-- k9_progression.citizenid). Applying this file's numeric filename order
-- after install.sql, as this resource's own migrations directory already
-- documents, always satisfies any real ordering requirement.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql --
-- this migration's own tables do not individually need that floor, but
-- ship under the same requirement as the rest of this schema for one
-- consistent minimum across the whole resource.
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_individual_overrides -- current, high-command-edited per-citizenid
-- field overrides layered ON TOP of whatever XP-tier profile a citizenid
-- currently resolves to. One row per citizenid that has EVER had an
-- override written for it -- a citizenid's absence from this table, OR a
-- present-but-`deleted = 1` row, both mean "no individual override; use
-- this K9's own XP-tier values unchanged" (see server/k9profiles.lua's
-- GetK9EffectiveMultipliers for the exact resolution).
--
-- `citizenid` VARCHAR(50): matches every other citizenid column in this
-- schema (k9_certifications.citizenid, k9_progression.citizenid,
-- k9_permissions.citizenid) byte for byte. PRIMARY KEY -- at most one
-- override row per citizenid, ever; re-editing the same citizenid always
-- UPDATEs this one row (see K9Store.Override_Upsert's own ON DUPLICATE KEY
-- UPDATE clause), never inserts a second one.
--
-- `speed_multiplier` / `scent_range_multiplier` /
-- `medkit_cooldown_multiplier` DOUBLE, ALL NULLABLE, ALL INDEPENDENTLY
-- OPTIONAL: unlike k9_xp_tiers (where every rank has always had a REQUIRED
-- speed/scent multiplier), an individual override is deliberately
-- PER-FIELD -- an operator overriding only `speed_multiplier` for one dog
-- must not be forced to also pin `scent_range_multiplier`/
-- `medkit_cooldown_multiplier` to some value; NULL here means "defer to
-- this citizenid's own XP-tier value for this one field", read live, so an
-- operator who only ever wanted to touch ONE field never accidentally
-- freezes the OTHER two against a future XP-tier re-tune. Bounds are
-- enforced ENTIRELY at the application layer (server/k9profiles.lua's own
-- IsValidMultiplier, and server/xptiers.lua's MAX_SPEED_SCENT_MULTIPLIER /
-- MAX_MEDKIT_COOLDOWN_MULTIPLIER), never in SQL.
--
-- THIS COMMENT USED TO STATE THE BOUNDS AS LITERAL NUMBERS, `(0, 3.0]` for
-- the first two, and that went stale. The speed/scent ceiling is not a
-- constant: it is read from `Config.MaxSpeedScentMultiplier`, which the
-- owner edits and which ships at 10.0 -- the game engine's own documented
-- maximum for the movement override this eventually feeds. So a value this
-- file once described as impossible is now perfectly ordinary.
--
-- Deliberately NOT restated as a new number here. A bound written into a
-- migration comment is a copy of a fact that lives somewhere else, and
-- copies rot silently while the original keeps changing -- which is exactly
-- what happened. Read the two Lua constants named above for the live
-- answer; they are the ones actually enforcing it.
--
-- THE COLUMN ITSELF IS DELIBERATELY UNCONSTRAINED, and that is why raising
-- the ceiling in config needed no migration at all: this is a plain DOUBLE,
-- with no CHECK, matching this schema's own established "validate in Lua,
-- not in SQL" convention. Had the bound been baked in here as a constraint,
-- an owner raising their own configured ceiling would have hit a database
-- rejection with no obvious cause.
--
-- `note` VARCHAR(120) NULLABLE: an optional, operator-authored, freeform
-- reason ("K9 injured in training, temp cap"), rendered by the tablet
-- next to this citizenid's override -- validated server-side with the same
-- character filter server/certtiers.lua's own IsValidTierLabel already
-- applies, defense in depth on top of textContent-only rendering, not a
-- substitute for it.
--
-- `deleted` TINYINT(1) NOT NULL DEFAULT 0: the tombstone -- see this file's
-- own header "TOMBSTONE, NOT HARD DELETE".
--
-- `updated_by` / `updated_at` / `created_at`: same shape and same meaning
-- as every other admin-edited current-state table in this schema
-- (k9_certification_tiers, k9_permission_keys, k9_xp_tiers).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_individual_overrides` (
  `citizenid`                  VARCHAR(50)  NOT NULL,
  `speed_multiplier`           DOUBLE       DEFAULT NULL,
  `scent_range_multiplier`     DOUBLE       DEFAULT NULL,
  `medkit_cooldown_multiplier` DOUBLE       DEFAULT NULL,
  `note`                       VARCHAR(120) DEFAULT NULL,
  `deleted`                    TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`                 VARCHAR(50)  NOT NULL,
  `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_individual_override_audit -- append-only "who changed which K9's
-- individual override, and how" trail. Never updated or deleted by this
-- resource. Deliberately ONE table (not split per action), mirroring
-- migration 0007/0010/0013/0015's own single-audit-table-with-a-
-- discriminator-column design.
--
-- `action` VARCHAR(20): one of 'override_create', 'override_update',
-- 'override_reset' -- see server/k9profiles.lua's own WriteOverrideAudit
-- for exactly when each is used.
--
-- `citizenid` VARCHAR(50): which K9's override this audit row is about.
-- NOT a foreign key -- see this file's own header "NO FK".
--
-- `detail` TEXT: a human-readable before/after field-by-field summary.
-- Plain text, not JSON -- matching migration 0010/0015's own reasoning
-- (this resource's Lua runtime has no confirmed, luacheck-allowlisted
-- `json` global available to any file).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_individual_override_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `citizenid`    VARCHAR(50)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one K9's override, most recent
  -- first" -- the natural admin/audit query over this table, mirroring
  -- migration 0010/0015's own idx_*_changed_at precedent.
  KEY `idx_citizenid_changed_at` (`citizenid`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
