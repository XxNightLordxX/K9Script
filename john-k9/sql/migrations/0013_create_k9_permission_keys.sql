-- =====================================================================
-- john-k9 :: migration 0013 :: server/permissionkeycatalog.lua persistence
--
-- Config.Features nothing new required -- this surface is high-command-
-- gated in code (server/permissionkeycatalog.lua's own
-- CanManagePermissionKeys), not behind a separate feature flag, matching
-- the same precedent migration 0010 already established for the
-- certification-tier catalog and the owner's own literal ask for THIS
-- pass: "have high command add more certification roles and change the
-- permissions for them or remove certification roles or even add or
-- remove permissions." The first half of that sentence is migration
-- 0010's job; this migration is the schema half of the second ("add or
-- remove permissions" -- the PERMISSION KEYS themselves, e.g. 'k9.access',
-- not the four grade-based certification tiers).
--
-- THE GAP THIS CLOSES: Config.Permissions (config.lua) ships exactly four
-- keys. High command can already GRANT/REVOKE those four to a specific
-- citizenid (server/permissions.lua, migration 0005) -- but cannot create a
-- fifth, rename one, or retire one without an operator hand-editing
-- config.lua and restarting the server. This migration is the schema half
-- of making that catalog itself operator-extensible at runtime, the exact
-- same "config ships the defaults, a database table overlays runtime
-- edits" pattern migration 0010 already established for certification
-- tiers -- see server/permissionkeycatalog.lua's own header for the full
-- design writeup (including why it deliberately does NOT copy every part
-- of that pattern -- no ordinal, no capabilities sibling table, no
-- reference-count delete refusal, and why each omission is safe here).
--
-- Two brand-new tables, no ALTER of anything pre-existing (in particular:
-- NOT touching `k9_permissions.permission`, which migration 0005 already
-- shipped as `VARCHAR(50) NOT NULL` with no DEFAULT and no ENUM/CHECK
-- constraint -- a permission grant row already stores whatever string
-- IsValidPermissionKey accepted at grant time, so this migration adds
-- nothing there and needs nothing there):
--
--   k9_permission_keys -- CURRENT effective permission-key catalog
--     OVERRIDE/ADDITION state, one row per permission_key that has EVER
--     been touched by a high-command edit (created, relabeled/re-described,
--     or deleted/tombstoned). A key's ABSENCE from this table means "use
--     Config.Permissions' own default for this key" if it is one of the
--     four shipped defaults ('k9.access'/'k9.certify'/'k9.audit'/
--     'k9.givexp'), or "this key does not exist" otherwise -- mirrors
--     k9_certification_tiers' own "absence = config default" contract
--     (migration 0010) exactly. `deleted` is a TOMBSTONE flag, not a real
--     row DELETE -- see "WHY A TOMBSTONE" below.
--
--   k9_permission_key_audit -- APPEND-ONLY history of every permission-key
--     catalog change (create, relabel, restore, delete) -- who made it, and
--     a human-readable before/after `detail` string. Never updated or
--     deleted by this resource. Same single-table-with-an-`action`-
--     discriminator-column shape as k9_certification_tier_audit (migration
--     0010) and k9_runtime_override_audit (migration 0007).
--
-- WHY A TOMBSTONE (`deleted` flag), NOT A ROW DELETE, IN
-- k9_permission_keys: three of the four default keys ('k9.certify',
-- 'k9.audit', 'k9.givexp' -- and 'k9.access' too, until first touched) have
-- NO row in this table at all on a server where high command has never
-- opened this screen -- they exist purely as Config.Permissions defaults.
-- There is nothing to DELETE FROM in that case; "remove the k9.audit
-- permission" has to mean "record that this key is now suppressed", which
-- only a tombstone ROW (not a row's absence) can represent for a
-- config-sourced key. A DB-added key (one that never existed in
-- Config.Permissions at all) is tombstoned via the exact same flag for the
-- same reason: ONE merge/exclusion code path in
-- server/permissionkeycatalog.lua handles both cases identically.
--
-- UNLIKE k9_certification_tiers (migration 0010), THIS TABLE HAS NO
-- ORDINAL COLUMN AND NO SIBLING CAPABILITIES TABLE: a permission key is
-- consulted by HasPermission(citizenid, key) as a flat, unordered
-- membership test (does this citizenid hold an active k9_permissions row
-- naming this exact string) -- there is no rank/comparison concept for a
-- permission key the way GetCertificationTierOrdinal/MeetsTierRequirement
-- need one for a tier, and nothing about "what a permission key grants" is
-- itself sub-divided into toggleable capabilities the way a tier's
-- CAPABILITY_CATALOG membership is -- a permission key IS the capability.
-- See server/permissionkeycatalog.lua's own header for why this also means
-- DeleteKey below never needs a reference-count refusal the way
-- DeleteTier does.
--
-- WHO NEEDS THIS FILE: any installation that does not yet have these two
-- tables -- which, at the time of writing, is EVERY installation (both are
-- brand new). Run this after install.sql and migrations 0001-0012, per
-- this resource's own documented numeric-filename ordering.
--
-- IDEMPOTENT / SAFE TO RE-RUN: every statement below is a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance. Running this file twice, or before/after
-- install.sql, or against a database that already has one but not both of
-- these tables, always produces the same end state.
--
-- NO GENERATED COLUMNS: like k9_certification_tiers/
-- k9_certification_tier_audit (migration 0010), neither table here needs a
-- DB-level "at most one active row" backstop -- k9_permission_keys uses a
-- real, non-generated PRIMARY KEY (permission_key) as its own single-row-
-- per-key guarantee. This migration does NOT require the MySQL >= 5.7.8 /
-- MariaDB >= 10.2 floor for its OWN sake -- kept identical to that floor
-- anyway, matching every other migration in this directory, since a server
-- running any prior migration in this directory already meets it.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- NO FK ANYWHERE IN THIS FILE, matching this schema's own established "no
-- FK, relational integrity enforced at the application layer" convention
-- (see k9_certifications' own header on qbx_core players, and
-- k9_certification_tier_capabilities' own header on k9_certification_tiers,
-- for the identical reasoning): `k9_permissions.permission` is NOT a
-- foreign key into `k9_permission_keys.permission_key` specifically because
-- (a) a legacy default key can hold ACTIVE k9_permissions rows while having
-- NO row of its own in k9_permission_keys at all (see "WHY A TOMBSTONE"
-- above), and (b) `k9_permissions.permission` ALSO stores the entirely
-- separate `feature.<Name>`/`block.<Name>` per-person-feature-control
-- namespace (server/permissions.lua's IsValidPermissionKey), which is
-- DELIBERATELY NEVER represented in k9_permission_keys at all -- see
-- server/permissionkeycatalog.lua's own header "NAMESPACE PROTECTION" for
-- the full reasoning an FK here would have made impossible to enforce
-- correctly. server/permissionkeycatalog.lua's own application-level
-- validation (every catalog write is preceded by a reserved-namespace
-- check and a known-key check against the live merged catalog) is what
-- actually enforces the relationship that matters.
--
-- ORDERING: independent of every other table this resource has -- neither
-- table here references any other migration's table by key.
-- k9_permission_key_audit has no FK relationship to k9_permission_keys
-- either, so these two tables have no ordering requirement even relative
-- to each other beyond this file's own statement order (audit table
-- created after the current-state table, for readability only -- not a
-- real dependency).
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_permission_keys -- current effective permission-key catalog
-- override/addition/tombstone state. See header for the full "absence =
-- use Config.Permissions default" / "deleted = tombstone, not a real
-- DELETE" contract.
--
-- `permission_key` VARCHAR(50): matches `k9_permissions.permission`'s own
-- VARCHAR(50) (migration 0005) exactly, so a valid catalog key can always
-- actually be written to a grant row referencing it.
-- server/permissionkeycatalog.lua's own key-format validator additionally
-- caps accepted keys well under this limit (see that file's
-- IsValidPermissionCatalogKey) -- this column width is a belt-and-
-- suspenders bound, not the primary validation layer.
--
-- `label` VARCHAR(60): display-only, rendered by the tablet -- validated
-- server-side (character filter mirroring server/certtiers.lua's own
-- IsValidTierLabel) before ever reaching this column.
--
-- `description` VARCHAR(300) NULL: optional, matches
-- Config.Permissions[key].description's own optional-string shape exactly
-- -- NULL means "no description supplied", never an empty-string
-- placeholder.
--
-- `deleted` TINYINT(1): tombstone flag. server/permissionkeycatalog.lua's
-- merge excludes ANY row with `deleted = 1` from the live catalog, full
-- stop.
--
-- `updated_by` / `updated_at`: who last touched this row and when --
-- ON UPDATE CURRENT_TIMESTAMP so a relabel/re-describe/re-delete/restore
-- all bump this automatically; `created_at` is separate and immutable so
-- "when was this key first introduced" survives any later edit.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_permission_keys` (
  `permission_key` VARCHAR(50)  NOT NULL,
  `label`          VARCHAR(60)  NOT NULL,
  `description`    VARCHAR(300) DEFAULT NULL,
  `deleted`        TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`     VARCHAR(50)  NOT NULL,
  `updated_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`permission_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_permission_key_audit -- append-only "who changed the permission-key
-- catalog, and how" trail. Never updated or deleted by this resource,
-- including after the corresponding k9_permission_keys row is later
-- tombstoned.
--
-- `action` VARCHAR(20): 'permkey_create' | 'permkey_update' |
-- 'permkey_restore' | 'permkey_delete' -- a fixed, small, application-
-- validated vocabulary, same "no DB-level ENUM/CHECK" convention as
-- k9_certification_tier_audit.action.
--
-- `detail` TEXT: a human-readable before/after summary (e.g. `label:
-- 'Grant XP' -> 'Award XP'`). Plain text, not JSON -- same reasoning
-- k9_certification_tier_audit.detail's own header already gives (no
-- confirmed, luacheck-allowlisted `json` global exists anywhere in this
-- resource's Lua runtime).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_permission_key_audit` (
  `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`         VARCHAR(20)  NOT NULL,
  `permission_key` VARCHAR(50)  NOT NULL,
  `detail`         TEXT         NOT NULL,
  `changed_by`     VARCHAR(50)  NOT NULL,
  `changed_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one permission key, most recent
  -- first" -- the natural admin/audit query over this table, mirroring
  -- k9_certification_tier_audit's own idx_tier_key_changed_at.
  KEY `idx_permission_key_changed_at` (`permission_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
