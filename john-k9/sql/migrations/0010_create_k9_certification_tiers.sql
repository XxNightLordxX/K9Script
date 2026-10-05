-- =====================================================================
-- john-k9 :: migration 0010 :: server/certtiers.lua persistence
--
-- Config.Features nothing new required -- this surface is high-command-
-- gated in code (server/certtiers.lua's own CanManageCertTiers), not
-- behind a separate feature flag, matching the owner's literal ask:
-- "Allow high command to edit the tiers trainee certified senior etc add
-- more roles edit permissions for those roles etc."
--
-- THIS IS AN OWNER-DIRECTED REVERSAL of a design decision already shipped
-- in this codebase. server/certifications.lua's own header ("TIER (§5)")
-- argued explicitly for a fixed, hardcoded 3-step tier vocabulary
-- (trainee/certified/senior) instead of a Config table: "a small, fixed
-- vocabulary; making it configurable would let an operator invent tier
-- names no future Phase 2/3 gate could rank against, for no real benefit
-- -- an operator can hold the model in their head". That reasoning is
-- NOT wrong for the world it was written for; it simply no longer
-- applies once the owner asks for the opposite (an operator-EXTENSIBLE,
-- runtime-editable tier list with per-tier granted capabilities). See
-- server/certtiers.lua's own header for the full writeup of why the old
-- argument is preserved in comments rather than deleted, and what
-- replaces it. This migration is the schema half of that reversal.
--
-- Three brand-new tables, no ALTER of anything pre-existing (in
-- particular: NOT touching `k9_certifications.tier`, which migration
-- 0006 already shipped as `VARCHAR(20) NOT NULL DEFAULT 'certified'` --
-- that column's TYPE and DEFAULT are exactly what makes the three legacy
-- keys below load-bearing; see server/certtiers.lua's header "EXISTING
-- ROWS" section):
--
--   k9_certification_tiers -- CURRENT effective tier catalog OVERRIDE/
--     ADDITION state, one row per tier key that has EVER been touched by
--     a high-command edit (created, renamed, re-capability'd, or
--     deleted/tombstoned). A key's ABSENCE from this table means "use
--     Config.CertificationTiers' own default for this key" if it is one
--     of the three shipped defaults (trainee/certified/senior), or
--     "this key does not exist" otherwise -- mirrors
--     k9_runtime_feature_overrides' own "absence = config default"
--     contract (migration 0007) exactly. `deleted` is a TOMBSTONE flag,
--     not a real row DELETE (see "WHY A TOMBSTONE, NOT A DELETE" below)
--     -- server/certtiers.lua's own merge logic excludes any row with
--     `deleted = 1` from the live catalog entirely, for both a
--     DB-added tier and a suppressed CONFIG-default tier alike.
--
--   k9_certification_tier_capabilities -- CURRENT effective
--     tier -> capability grants, one row per (tier_key, capability_key)
--     pair that is CURRENTLY GRANTED. Absence of a row means "this tier
--     does not have this capability". `capability_key` is validated
--     server-side against server/certtiers.lua's own fixed, CODE-OWNED
--     CAPABILITY_CATALOG before any INSERT ever reaches this table --
--     this table itself has no CHECK/ENUM constraint enforcing that
--     vocabulary (this schema's established convention: fixed
--     vocabularies are validated at the application layer, not the DB
--     layer -- see migration 0006's own `revoke_reason` precedent) -- but
--     the vocabulary itself is closed at the CODE level (not editable by
--     an in-game action, not editable by an operator's own Config edit
--     either) specifically so that high command editing "what a tier
--     grants" can only ever toggle membership in an already-reviewed,
--     already-shipped set of capability keys, never invent a new one.
--     See server/certtiers.lua's own header "PRIVILEGE ESCALATION /
--     THREAT MODEL" section for the full reasoning this table's own
--     design depends on.
--
--   k9_certification_tier_audit -- APPEND-ONLY history of every tier
--     catalog change (create, rename/re-capability, reorder, delete) --
--     who made it, and a human-readable before/after `detail` string.
--     Never updated or deleted by this resource. Deliberately ONE table
--     for every action kind (not split per action), mirroring migration
--     0007's own k9_runtime_override_audit design (a single audit table
--     with an `action` discriminator column covering both its 'feature'
--     and 'tuning' override kinds) -- same reasoning applies here: one
--     "who changed the tier catalog, and how" trail is easier to read
--     chronologically than N per-action-kind tables.
--
-- WHY A TOMBSTONE (`deleted` flag), NOT A ROW DELETE, IN
-- k9_certification_tiers: two of the three legacy tier keys
-- (trainee/senior) have NO row in this table at all on a server where
-- high command has never touched them -- they exist purely as
-- Config.CertificationTiers defaults. There is nothing to DELETE FROM in
-- that case; "delete the trainee tier" has to mean "record that this key
-- is now suppressed", which only a tombstone ROW (not a row's absence)
-- can represent for a config-sourced key. A DB-added tier (one that
-- never existed in Config.CertificationTiers at all) is tombstoned via
-- the exact same flag for the same reason: ONE merge/exclusion code path
-- in server/certtiers.lua handles both cases identically, rather than
-- two ("is this key config-sourced or DB-sourced") that could drift out
-- of sync with each other. A tombstoned key can be resurrected later by
-- re-adding the same key (server/certtiers.lua's UpsertTier flips
-- `deleted` back to 0 and re-appends it at the end of the ordinal list --
-- see that file's own header for why a restore does not attempt to
-- reclaim the key's old ordinal position).
--
-- WHO NEEDS THIS FILE: any installation that does not yet have these
-- three tables -- which, at the time of writing, is EVERY installation
-- (all three are brand new). Run this after install.sql and migrations
-- 0001-0009, per this resource's own documented numeric-filename
-- ordering.
--
-- IDEMPOTENT / SAFE TO RE-RUN: every statement below is a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance. Same reasoning as migrations 0005/0007/0008's
-- own headers: the ALTER-table portability problem those procedures
-- exist for (`ADD COLUMN IF NOT EXISTS` being MariaDB-only / MySQL
-- 8.0.29+ only) does not apply to `CREATE TABLE IF NOT EXISTS`, which
-- every MySQL/MariaDB version this resource supports already understands
-- natively. Running this file twice, or before/after install.sql, or
-- against a database that already has some but not all three tables,
-- always produces the same end state.
--
-- NO GENERATED COLUMNS: unlike k9_certifications/k9_partnerships/
-- k9_permissions/k9_certification_specializations, none of these three
-- tables need a DB-level "at most one active row" backstop -- both
-- current-state tables here use a real, non-generated PRIMARY KEY
-- (tier_key alone / the (tier_key, capability_key) composite) as their
-- own single-row-per-key guarantee instead. This migration does NOT
-- require the MySQL >= 5.7.8 / MariaDB >= 10.2 floor for its OWN sake --
-- kept identical to that floor anyway, matching every other migration in
-- this directory, since a server running any prior migration in this
-- directory already meets it.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- NO FK ANYWHERE IN THIS FILE, matching this schema's own established
-- "no FK, relational integrity enforced at the application layer"
-- convention (see k9_certifications' own header on qbx_core players, and
-- k9_certification_specializations' own header on k9_certifications
-- itself, for the identical reasoning): `k9_certification_tier_capabilities
-- .tier_key` is NOT a foreign key into `k9_certification_tiers.tier_key`
-- specifically because a legacy default tier key (trainee/senior) can
-- hold capability rows while having NO row of its own in
-- k9_certification_tiers at all (see "WHY A TOMBSTONE" above) -- an FK
-- here would reject exactly the common case this design depends on.
-- server/certtiers.lua's own application-level validation (every
-- capability write is preceded by a known-tier-key check against the
-- live merged catalog) is what actually enforces this relationship.
--
-- ORDERING: independent of every other table this resource has -- none
-- of these three reference any other migration's table by key.
-- k9_certification_tier_capabilities has no FK relationship to
-- k9_certification_tiers either (see above), so these three tables have
-- no ordering requirement even relative to EACH OTHER beyond this file's
-- own statement order (capabilities table created after the tiers table,
-- for readability only -- not a real dependency).
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_certification_tiers -- current effective tier-catalog override/
-- addition/tombstone state. See header for the full "absence = use
-- Config.CertificationTiers default" / "deleted = tombstone, not a real
-- DELETE" contract.
--
-- `tier_key` VARCHAR(32): matches (with headroom) `k9_certifications
-- .tier`'s own VARCHAR(20) from migration 0006 -- kept slightly WIDER
-- here, deliberately, so a future legitimate long-ish operator-chosen key
-- (e.g. 'master_handler') is never silently truncated by this table
-- while still comfortably exceeding anything `k9_certifications.tier`
-- can actually store. server/certtiers.lua's own key-format validator
-- additionally caps accepted keys well under both limits (see that
-- file's IsValidTierKey) -- this column width is a belt-and-suspenders
-- bound, not the primary validation layer, same posture migration 0007's
-- own header states for k9_tablet_theme's colour columns.
--
-- `label` VARCHAR(60): display-only, rendered by the tablet -- validated
-- server-side (character filter mirroring server/runtimecontrol.lua's own
-- IsSafeHeaderTitle) before ever reaching this column, for the identical
-- "defense in depth on top of textContent-only rendering discipline"
-- reason that file's header gives for its own header_title column.
--
-- `ordinal` INT: rank for comparison via GetCertificationTierOrdinal/
-- MeetsTierRequirement/TierHasCapability. No UNIQUE constraint on this
-- column, deliberately -- see server/certtiers.lua's own header
-- "CONCURRENT-ADD ORDINAL TIE" note for the one documented, disclosed,
-- non-security-relevant edge case this allows (two brand-new tiers
-- created in the same instant may tie; a tie is a safe, non-escalating
-- outcome, never a crash, never a lost row).
--
-- `deleted` TINYINT(1): tombstone flag. server/certtiers.lua's merge
-- excludes ANY row with `deleted = 1` from the live catalog, full stop --
-- capability rows for a tombstoned tier_key are left in place in
-- k9_certification_tier_capabilities (not cleaned up), since they simply
-- become unreachable dead weight once the tier itself is excluded, and
-- are transparently reactivated if the same key is ever re-added (see
-- header "WHY A TOMBSTONE" above).
--
-- `updated_by` / `updated_at`: who last touched this row and when --
-- ON UPDATE CURRENT_TIMESTAMP so a rename/re-ordinal/re-delete/restore
-- all bump this automatically; `created_at` is separate and immutable so
-- "when was this tier key first introduced" survives any later edit.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_certification_tiers` (
  `tier_key`     VARCHAR(32)  NOT NULL,
  `label`        VARCHAR(60)  NOT NULL,
  `ordinal`      INT          NOT NULL,
  `deleted`      TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`   VARCHAR(50)  NOT NULL,
  `updated_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`tier_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_certification_tier_capabilities -- current effective tier ->
-- capability grants. A SIBLING TABLE, not a column/CSV/JSON blob on
-- k9_certification_tiers, for the identical reason
-- k9_certification_specializations (migration 0006) is a sibling table
-- rather than a column on k9_certifications: a tier may grant MULTIPLE
-- capabilities simultaneously, which a single column could not represent
-- without inventing exactly the CSV/JSON convention this schema
-- deliberately avoids elsewhere. `capability_key` values are restricted,
-- at the APPLICATION layer only (see header), to
-- server/certtiers.lua's fixed CAPABILITY_CATALOG.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_certification_tier_capabilities` (
  `tier_key`        VARCHAR(32) NOT NULL,
  `capability_key`  VARCHAR(64) NOT NULL,
  `granted_by`      VARCHAR(50) NOT NULL,
  `granted_at`      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`tier_key`, `capability_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_certification_tier_audit -- append-only "who changed the tier
-- catalog, and how" trail. Never updated or deleted by this resource,
-- including after the corresponding k9_certification_tiers row is later
-- tombstoned -- the history of a tier having existed, and every edit made
-- to it, must survive its own deletion.
--
-- `action` VARCHAR(20): 'tier_create' | 'tier_update' | 'tier_restore' |
-- 'tier_reorder' | 'tier_delete' -- a fixed, small, application-validated
-- vocabulary, same "no DB-level ENUM/CHECK" convention as
-- k9_certifications.revoke_reason.
--
-- `tier_key` VARCHAR(32): for a 'tier_reorder' row (which touches every
-- tier at once, not one specific key), this is the literal string
-- 'ALL' -- a sentinel, not a real key, matching k9_certifications
-- .revoked_by's own 'system:job_change' sentinel-in-a-plain-VARCHAR
-- precedent (no separate nullable/typed column invented just for this
-- one action kind).
--
-- `detail` TEXT: a human-readable before/after summary (e.g. "label:
-- 'Trainee' -> 'Rookie'", or a full old-ordinal/new-ordinal listing for a
-- reorder). Plain text, not JSON -- this codebase's Lua runtime has no
-- confirmed, luacheck-allowlisted `json` global available to any file
-- (grepped: zero real call sites anywhere in server/*.lua as of this
-- migration), so a hand-built descriptive string is what every writer of
-- this column can actually produce without introducing a new,
-- unverified cross-file dependency for one audit column.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_certification_tier_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `tier_key`     VARCHAR(32)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one tier key, most recent
  -- first" -- the natural admin/audit query over this table, mirroring
  -- migration 0007's own idx_override_key_changed_at.
  KEY `idx_tier_key_changed_at` (`tier_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
