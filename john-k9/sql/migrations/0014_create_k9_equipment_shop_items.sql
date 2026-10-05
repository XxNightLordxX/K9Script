-- =====================================================================
-- john-k9 :: migration 0014 :: server/equipmentshop.lua K9 equipment
--                                  shop ITEM CATALOG persistence
--
-- OWNER'S OWN WORDS, THIS PASS: "give high command real control over the
-- equipment shop" -- full command over everything. Migrations 0010
-- (server/certtiers.lua) and 0011 (server/equipmentshop.lua's own runtime
-- shop LOCATIONS) already established the two building blocks this
-- migration recombines for the shop's INVENTORY specifically: "config
-- stays the shipped default, a database table layers operator EDITS on
-- top, high-command-gated, tombstoned rather than hard-deleted." This
-- migration is the schema half of extending that exact same pattern (per
-- this pass's own explicit instruction: "follow the pattern already
-- proven in server/certtiers.lua ... do not invent a different
-- mechanism") to WHICH items are sold, at what price, in what order, and
-- under what certification-tier/specialization purchase requirement --
-- the one part of the shop migration 0011 deliberately left untouched
-- (that migration's own header: "these callbacks manage ONLY the...
-- location pool" -- items were always out of scope for it).
--
-- Two tables, mirroring migration 0010's exact "current-state table +
-- append-only audit companion" shape (NOT three -- see "WHY NO SEPARATE
-- CAPABILITIES-STYLE SIBLING TABLE" below for why this schema needs one
-- fewer table than migration 0010's tier catalog did):
--
--   k9_equipment_shop_items -- CURRENT effective item-catalog OVERRIDE/
--     ADDITION/tombstone state, one row per item_key (an ox_inventory
--     item NAME, e.g. 'k9_medkit') that has EVER been touched by a
--     high-command edit. A key's ABSENCE from this table means "use
--     Config.K9EquipmentShop.items' own entry for this key, if one
--     exists" -- identical "absence = config default" contract as
--     k9_certification_tiers (migration 0010) and
--     k9_runtime_feature_overrides (migration 0007). `deleted` is a
--     TOMBSTONE flag, not a real row DELETE, for the identical reason
--     migration 0010 gives for its own `deleted` column: a config-sourced
--     item_key (e.g. 'k9_medkit', shipped in Config.K9EquipmentShop.items)
--     has NO row here at all until high command first touches it, so
--     "remove this item from the shop" has to mean "record that this key
--     is now suppressed", which only a tombstone ROW (not a row's
--     absence) can represent. A DB-added item_key (one that never existed
--     in Config.K9EquipmentShop.items at all -- high command can add a
--     brand-new item to the shop purely from the tablet, referencing any
--     real ox_inventory item name) is tombstoned via the exact same flag,
--     for the exact same "one merge/exclusion code path handles both
--     cases" reasoning migration 0010 already gives.
--
--   k9_equipment_shop_item_audit -- APPEND-ONLY history of every item
--     catalog change (create, edit, reorder, delete/restore) -- who made
--     it, and a human-readable before/after `detail` string. Never
--     updated or deleted by this resource, mirroring
--     k9_certification_tier_audit's own identical contract.
--
-- WHY NO SEPARATE CAPABILITIES-STYLE SIBLING TABLE: migration 0010 needed
-- a THIRD table (k9_certification_tier_capabilities) because a single
-- tier can hold an open SET of capabilities simultaneously -- a
-- many-to-many relationship a single column cannot represent without a
-- CSV/JSON convention this schema avoids elsewhere. A shop item's
-- purchase requirement is different in shape, not merely simpler: AT MOST
-- ONE certification-tier floor and AT MOST ONE specialization gate per
-- item (this pass's own explicit, disclosed design decision -- see
-- server/equipmentshop.lua's own header "PURCHASE REQUIREMENTS" section
-- for the full writeup of why AND-of-at-most-one-each, not an open set,
-- is what "whether an item requires a certification tier or
-- specialization to buy" was scoped to mean) -- a true 1-to-0-or-1
-- relationship per axis, which two plain nullable columns represent
-- completely, with no sibling table needed at all.
--
-- `required_tier_key`/`required_specialization` are DELIBERATELY NOT
-- FOREIGN KEYS into k9_certification_tiers.tier_key /
-- Config.K9Specializations (which is not even a database table at all --
-- it is a plain config.lua Lua table, so an FK into it is not physically
-- possible) -- matching this schema's own established "no FK, relational
-- integrity enforced at the application layer" convention (see
-- k9_certifications' own header on qbx_core players, and migration
-- 0010's own header on k9_certification_tier_capabilities.tier_key, for
-- the identical reasoning applied here). server/equipmentshop.lua's own
-- application-level validation (every write is preceded by a
-- known-tier-key / known-specialization-key check against the LIVE
-- catalogs) is what actually enforces both relationships -- see that
-- file's own ShopItemsUpsert callback.
--
-- WHO NEEDS THIS FILE: any installation that does not yet have these two
-- tables -- which, at the time of writing, is EVERY installation (both
-- are brand new).
--
-- IDEMPOTENT / SAFE TO RE-RUN: both statements below are a bare
-- `CREATE TABLE IF NOT EXISTS` -- no ALTER, no INFORMATION_SCHEMA-guarded
-- stored-procedure dance, matching migrations 0007/0010/0011's own
-- identical reasoning for why a brand-new table needs none of that (the
-- portability problem those procedures exist for is specific to `ADD
-- COLUMN IF NOT EXISTS`/`ADD INDEX IF NOT EXISTS`, not to `CREATE TABLE IF
-- NOT EXISTS`, which every MySQL/MariaDB version this resource supports
-- already understands natively). Running this file twice, or before/after
-- install.sql, or against a database that already has one but not the
-- other of these two tables, always produces the same end state.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- NO GENERATED COLUMNS, NO FK ANYWHERE IN THIS FILE (see above) -- this
-- migration does not individually require the MySQL >= 5.7.8 / MariaDB >=
-- 10.2 floor for its own sake, but ships under the same requirement as
-- every other migration in this directory for one consistent minimum
-- across the whole schema (a server already able to run migrations
-- 0001-0013 already meets it).
--
-- ORDERING: independent of every other table this resource has -- neither
-- table here references any other migration's table by key. Applying this
-- resource's own documented numeric-filename order (..., 0012, 0013,
-- 0014) after install.sql always satisfies any real ordering requirement
-- this resource's migrations have as a whole, even though this specific
-- file has no dependency of its own on any of the others.
-- =====================================================================

-- ---------------------------------------------------------------------
-- k9_equipment_shop_items -- current effective item-catalog override/
-- addition/tombstone state. See header for the full "absence = use
-- Config.K9EquipmentShop.items default" / "deleted = tombstone, not a
-- real DELETE" contract.
--
-- `item_key` VARCHAR(50): an ox_inventory item NAME -- this resource's
-- own placeholder items (`k9_medkit`, `k9_treat`, `k9_meat_bait`,
-- `k9_ultrasonic_whistle`) are all comfortably under 20 characters; 50 is
-- deliberate headroom for a real, arbitrary ox_inventory item name from
-- any operator's own data/items.lua, matching migration 0010's own
-- "kept slightly WIDER than what this resource itself would ever
-- generate" reasoning for tier_key's own VARCHAR(32).
-- server/equipmentshop.lua's own key-format validator (IsValidShopItemKey)
-- additionally caps accepted keys well under this limit -- this column
-- width is a belt-and-suspenders bound, not the primary validation layer,
-- same posture migration 0010's header states for tier_key.
--
-- `label` VARCHAR(60) NULL: display-only OVERRIDE of ox_inventory's own
-- item label -- NULL means "use whatever ox_inventory's own Items(name)
-- reports", never a forced/duplicated copy of it. Validated server-side
-- (the same character filter as k9_certification_tiers.label) before
-- ever reaching this column when non-NULL.
--
-- `price` INT UNSIGNED NOT NULL: whole-currency-unit price. INTEGER, NOT
-- DECIMAL -- server/equipmentshop.lua's own validator rejects a
-- fractional price outright (see that file's header "PRICE VALIDATION"
-- for the full reasoning) so this column's type itself backs that
-- decision rather than merely trusting the application layer never to
-- send one. UNSIGNED because a negative price is rejected before it ever
-- reaches this column -- ZERO is explicitly ALLOWED (a legitimate free
-- item; see that same header section for why), which is exactly what
-- UNSIGNED still permits.
--
-- `currency` VARCHAR(50) NULL: an ox_inventory item name to charge
-- instead of the shop-wide Config.K9EquipmentShop.currencyItem default --
-- NULL means "use the shop-wide default", mirroring
-- k9_equipment_shop_locations.model/scenario/label's own NULL-means-
-- shop-wide-default convention (migration 0011) exactly.
--
-- `sort_order` INT NOT NULL: rank for display/registration order across
-- the WHOLE merged catalog (config-sourced AND database-only items
-- alike) -- no UNIQUE constraint, deliberately, for the identical
-- "CONCURRENT-ADD ORDINAL TIE" reason migration 0010's header discloses
-- for k9_certification_tiers.ordinal (a safe, non-escalating, purely
-- cosmetic tie between two items created in the same instant).
--
-- `required_tier_key` VARCHAR(32) NULL: a k9_certification_tiers.tier_key
-- value (see header for why this is not a real FK) -- NULL means "no
-- tier floor required to buy this item". Sized identically to
-- k9_certification_tiers.tier_key itself (migration 0010) so any key that
-- table can ever legally hold fits here without truncation.
--
-- `required_specialization` VARCHAR(50) NULL: a Config.K9Specializations
-- key (e.g. 'narcotics') -- NULL means "no specialization required".
-- Sized generously above every key this resource's own default catalog
-- currently uses (narcotics/explosives/patrol, all <= 10 chars) for the
-- same operator-extensibility headroom reasoning as item_key above.
--
-- `deleted` TINYINT(1): tombstone flag -- see header.
--
-- `updated_by` / `updated_at`: who last touched this row and when --
-- ON UPDATE CURRENT_TIMESTAMP so any edit bumps this automatically;
-- `created_at` is separate and immutable so "when was this item_key first
-- introduced to the override table" survives any later edit.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_equipment_shop_items` (
  `item_key`                VARCHAR(50)  NOT NULL,
  `label`                   VARCHAR(60)  DEFAULT NULL,
  `price`                   INT UNSIGNED NOT NULL,
  `currency`                VARCHAR(50)  DEFAULT NULL,
  `sort_order`              INT          NOT NULL,
  `required_tier_key`       VARCHAR(32)  DEFAULT NULL,
  `required_specialization` VARCHAR(50)  DEFAULT NULL,
  `deleted`                 TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`              VARCHAR(50)  NOT NULL,
  `updated_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`item_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- k9_equipment_shop_item_audit -- append-only "who changed the item
-- catalog, and how" trail. Never updated or deleted by this resource,
-- including after the corresponding k9_equipment_shop_items row is later
-- tombstoned -- the history of an item having existed, and every edit
-- made to it, must survive its own deletion, mirroring
-- k9_certification_tier_audit's own identical contract.
--
-- `action` VARCHAR(20): 'item_create' | 'item_update' | 'item_restore' |
-- 'item_reorder' | 'item_delete' -- a fixed, small, application-validated
-- vocabulary, same "no DB-level ENUM/CHECK" convention as every other
-- audit table in this schema.
--
-- `item_key` VARCHAR(50): for an 'item_reorder' row (which touches every
-- listed item at once, not one specific key), this is the literal string
-- 'ALL' -- the same sentinel-in-a-plain-VARCHAR convention
-- k9_certification_tier_audit.tier_key already uses for its own
-- 'tier_reorder' rows.
--
-- `detail` TEXT: a human-readable before/after summary, plain text (not
-- JSON) -- same "no confirmed json global available anywhere in this
-- codebase's Lua runtime" reasoning migration 0010's header gives for its
-- own identical column.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `k9_equipment_shop_item_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `item_key`     VARCHAR(50)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  -- Backs "full change history for this one item key, most recent
  -- first" -- the natural admin/audit query over this table, mirroring
  -- k9_certification_tier_audit's own idx_tier_key_changed_at precedent.
  KEY `idx_item_key_changed_at` (`item_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
