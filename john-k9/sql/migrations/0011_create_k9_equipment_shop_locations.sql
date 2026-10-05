-- =====================================================================
-- john-k9 :: migration 0011 :: server/equipmentshop.lua runtime shop
--                                  locations
--
-- Config.Features.K9EquipmentShop. The owner's own words: "make the shop a
-- dog ped and i can change the locations in the config or add more
-- locations remove locations etc along with in the high command tablet."
-- config.lua's own Config.K9EquipmentShop.locations already covers "change
-- in the config" (a plain Lua array, add/remove/reorder freely, no code
-- change needed). This migration is the OTHER half: a database-backed pool
-- of shop locations the tablet can add to, move, and remove from AT
-- RUNTIME, persisted across restarts, with a full audit trail -- following
-- the exact two-table pattern (current-state table + append-only audit
-- companion) sql/migrations/0007_create_k9_runtime_control.sql already
-- established for the identical "operator edits something at runtime,
-- config.lua stays the shipped default" shape.
--
-- SCOPE, STATED PLAINLY: this migration's tables hold ONLY tablet-added
-- locations (a synthetic `db:<id>` key, never referencing a config.lua
-- array index). A location that lives in Config.K9EquipmentShop.locations
-- (a `cfg:<n>` key, computed client/server-side, never stored here) stays
-- editable ONLY by hand-editing config.lua and restarting, exactly as
-- before this migration -- these two tables never override or suppress a
-- config.lua entry. This is a deliberate scope decision (see
-- server/equipmentshop.lua's own header for the full reasoning: a stored
-- override keyed to a config.lua ARRAY INDEX would silently apply to the
-- wrong location the moment an operator reorders that array, which
-- Config.K9EquipmentShop's own comment explicitly permits doing "freely,
-- no code change needed" -- adding a stale-index hazard on top of that
-- freedom was judged worse than just not offering it), not an oversight.
-- The EFFECTIVE shop location list a player actually sees is therefore
-- always: every Config.K9EquipmentShop.locations entry, PLUS every row in
-- k9_equipment_shop_locations below -- a pure union, never a conflict to
-- resolve.
--
-- WHO NEEDS THIS FILE: any installation that does not yet have these two
-- tables -- which, at the time of writing, is EVERY installation (both are
-- brand new).
--
-- IDEMPOTENT / SAFE TO RE-RUN: both statements below are a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance, matching migration 0007's/0008's own identical
-- reasoning for why a brand-new table needs none of that (the portability
-- problem those procedures work around is specific to `ADD COLUMN IF NOT
-- EXISTS`/`ADD INDEX IF NOT EXISTS`, not to `CREATE TABLE IF NOT EXISTS`,
-- which every MySQL/MariaDB version back to MySQL 3.x already understands
-- natively). Running this file twice, or before/after install.sql, or
-- against a database that already has one but not the other of these two
-- tables, always produces the same end state.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- ORDERING: independent of every other table this resource has --
-- `k9_equipment_shop_locations`/`k9_equipment_shop_locations_audit`
-- reference no other table's key at all (`location_id` in the audit table
-- is a resource-defined reference, not a SQL foreign key -- see that
-- table's own comment below for why). Applying this file's numeric
-- filename order (..., 0009, 0010, 0011) after install.sql, as this
-- resource's own migrations directory already documents, always satisfies
-- any real ordering requirement this resource's migrations have as a
-- whole, even though this specific file has no dependency of its own on
-- any of the others. (Deliberately not a number here -- a hardcoded
-- table or migration count in a comment silently rots every time one is
-- added, which has already happened repeatedly across this schema's own
-- headers.)
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql --
-- this migration's own tables do not individually need that floor (no
-- generated column, no functional index), but ship under the same
-- requirement as the rest of this schema for one consistent minimum across
-- the whole resource.
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_equipment_shop_locations -- current, tablet-added shop locations.
-- One row per location a high command officer has added at runtime. This
-- table is NEVER pre-populated from config.lua and never mirrors a
-- config.lua entry -- see this file's own header "SCOPE" section.
--
-- `model`/`scenario`/`label` are all nullable: NULL means "use this shop's
-- own Config.K9EquipmentShop.pedModel/pedScenario/label default", exactly
-- mirroring how a config.lua location entry may omit any of these same
-- three fields to the identical effect (server/equipmentshop.lua's
-- BuildEffectiveLocations applies the SAME fallback rule to both sources,
-- so a tablet-added location and a config.lua one behave identically).
-- `scenario` additionally distinguishes NULL ("use the default") from an
-- empty string '' ("this ped explicitly plays no scenario, overriding a
-- non-empty shop default") -- the same NULL-vs-false distinction
-- config.lua's own per-location `scenario = false` makes in Lua, where SQL
-- has no native boolean-false-vs-string type to reuse instead.
--
-- `heading` is NOT NULL (unlike model/scenario/label): every location
-- needs SOME heading to spawn a ped with, and 0.0 is exactly
-- config.lua's own Config.K9EquipmentShop.pedHeading default value, so a
-- row that never set one behaves identically to one that explicitly set
-- 0.0 -- no separate NULL-means-default case needed for this one field.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_equipment_shop_locations` (
  `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `x`          DOUBLE       NOT NULL,
  `y`          DOUBLE       NOT NULL,
  `z`          DOUBLE       NOT NULL,
  `heading`    DOUBLE       NOT NULL DEFAULT 0,
  `model`      VARCHAR(64)  DEFAULT NULL,   -- NULL = use Config.K9EquipmentShop.pedModel
  `scenario`   VARCHAR(64)  DEFAULT NULL,   -- NULL = use Config.K9EquipmentShop.pedScenario; '' = explicitly no scenario for this ped
  `label`      VARCHAR(100) DEFAULT NULL,   -- NULL = use Config.K9EquipmentShop.label
  `created_by` VARCHAR(50)  NOT NULL,       -- citizenid of the high-command officer who added this location
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by` VARCHAR(50)  DEFAULT NULL,   -- citizenid of whoever last moved/edited it, NULL if never edited since creation
  `updated_at` DATETIME     DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_equipment_shop_locations_audit -- append-only "who changed what, from
-- what, to what" trail, same full-snapshot-per-change shape as migration
-- 0007's k9_tablet_theme_audit. A row here is NEVER updated or deleted by
-- this resource, including when the corresponding
-- k9_equipment_shop_locations row is later deleted by a "remove" action --
-- the history of that location having existed at all must survive its own
-- removal, exactly like k9_runtime_override_audit's own stated contract.
--
-- `location_id` is DELIBERATELY NOT a SQL foreign key to
-- `k9_equipment_shop_locations.id`, for the identical reason
-- k9_runtime_override_audit's `override_key` is a plain string rather than
-- a foreign key: a real FK would either cascade-delete this audit row the
-- moment the location it audits is removed (destroying exactly the history
-- this table exists to keep), or block the removal outright (turning a
-- routine tablet action into a database error) -- neither is acceptable,
-- so the relationship is informational only, resolved by the application,
-- never enforced or cascaded by the database.
--
-- `action` is a plain, resource-defined string ('add' | 'move' | 'remove')
-- -- not an ENUM, matching k9_runtime_feature_overrides.kind's own
-- VARCHAR-not-ENUM choice, so a future fourth action needs no ALTER TABLE
-- to record.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_equipment_shop_locations_audit` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `location_id` INT UNSIGNED DEFAULT NULL,  -- see header: informational reference only, not a real FK
  `action`      VARCHAR(20)  NOT NULL,      -- 'add' | 'move' | 'remove'
  `x`           DOUBLE       DEFAULT NULL,
  `y`           DOUBLE       DEFAULT NULL,
  `z`           DOUBLE       DEFAULT NULL,
  `heading`     DOUBLE       DEFAULT NULL,
  `model`       VARCHAR(64)  DEFAULT NULL,
  `scenario`    VARCHAR(64)  DEFAULT NULL,
  `label`       VARCHAR(100) DEFAULT NULL,
  `changed_by`  VARCHAR(50)  NOT NULL,
  `changed_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one location, most recent first"
  -- -- the natural admin/audit query over this table, matching
  -- k9_runtime_override_audit's own idx_override_key_changed_at precedent.
  KEY `idx_location_id_changed_at` (`location_id`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
