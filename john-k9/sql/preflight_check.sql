-- =====================================================================
-- john-k9 :: PRE-INSTALL SAFETY CHECK -- run this BEFORE install.sql
--
-- WHAT IT DOES: looks at your database and tells you whether installing
-- this resource is safe. It is READ-ONLY -- it makes no changes at all,
-- creates nothing, and can be run on a live production server at any
-- time, as many times as you like.
--
-- HOW TO RUN IT:
--     mysql -u YOUR_USER -p YOUR_DATABASE < preflight_check.sql
-- ...or paste it into phpMyAdmin / HeidiSQL with your database selected.
--
-- WHAT YOU WANT TO SEE: every row saying "OK". Anything starting with
-- "!!" means stop and read that row before you install -- these are the
-- only rows this file considers a real reason not to proceed (a name
-- conflict, a too-old server). Anything starting with "WARN" is worth
-- reading but is NOT a reason to stop by itself (e.g. CHECK 5's "does
-- this look like the right database" sanity check, which can be
-- legitimately true on a brand-new server) -- `sql/k9_setup.sh` treats
-- these two markers differently for exactly this reason: it refuses to
-- proceed on any "!!" line, but only prints "WARN" lines for you to read.
--
-- It deliberately uses NO stored procedures, so it also works on managed
-- hosts that do not grant CREATE ROUTINE -- which is itself one of the
-- things it checks for you (see CHECK 2).
-- =====================================================================


-- ---------------------------------------------------------------------
-- CHECK 1: does anything already own one of our table names?
--
-- `install.sql` uses CREATE TABLE IF NOT EXISTS, so it will never
-- overwrite or damage a table that is already there -- but that also
-- means it will silently SKIP a table whose name is taken by something
-- else, leaving this resource pointed at a table it cannot use. That
-- shows up later as confusing "Unknown column" errors at runtime rather
-- than as an install failure, so it is worth five seconds to check now.
--
-- A table counted as "ours" is matched on its identifying columns only,
-- NOT on the columns that later migrations add -- so a database from an
-- older version of this resource correctly reports as ours, needing
-- migrations, rather than as a conflict.
-- ---------------------------------------------------------------------
SELECT
    x.table_name AS `table`,
    CASE
        WHEN x.tbl_exists = 0
            THEN 'OK - absent, install.sql will create it'
        WHEN x.obj_type <> 'BASE TABLE'
            THEN CONCAT('!! CONFLICT - a ', LOWER(x.obj_type),
                        ' already uses this name, not a table. install.sql will skip it and this resource will fail at runtime with errors like "The target table is not insertable". Rename or remove it before installing.')
        WHEN x.cols_found = x.cols_expected
            THEN 'OK - already present and is ours'
        ELSE CONCAT('!! CONFLICT - a DIFFERENT table already uses this name (matched only ',
                    x.cols_found, ' of ', x.cols_expected,
                    ' expected columns). Do NOT install until this is resolved.')
    END AS verdict
FROM (
    SELECT 'k9_certifications' AS table_name, 7 AS cols_expected,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists,
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS obj_type,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications'
         AND COLUMN_NAME IN ('citizenid','job','granted_by','granted_at','revoked_by','revoked_at','active')) AS cols_found
    UNION ALL SELECT 'k9_search_log', 9,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log'
         AND COLUMN_NAME IN ('searcher_citizenid','searcher_job','target_type','target_plate','target_citizenid','result','total_weight','alert_tier','searched_at'))
    UNION ALL SELECT 'k9_partnerships', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships'
         AND COLUMN_NAME IN ('k9_citizenid','handler_citizenid','established_by','established_at','ended_by','ended_at','active'))
    -- k9_partnership_pair_progress (migration 0018) -- the fully durable
    -- anti-farm guard table; see that migration's own header and
    -- server/datastore.lua's PairProgress_* accessors for the full design.
    -- Brand new (no prior version of this resource ever shipped it), so
    -- every one of its 3 columns is safe to check here, unlike
    -- k9_progression's own deliberate 4-of-5 exclusion just below.
    UNION ALL SELECT 'k9_partnership_pair_progress', 3,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'
         AND COLUMN_NAME IN ('k9_citizenid','handler_citizenid','highest_tenure_tier_granted'))
    -- Column list deliberately stays at the ORIGINAL 4 founding columns
    -- (migration 0002), NOT the 5 real columns this table has carried
    -- since migration 0017 added `handler_xp` -- see sql/install.sql's own
    -- `k9_progression` header ("`handler_xp` DELIBERATELY NOT ADDED...")
    -- for the full reasoning: including it here would misreport every
    -- real, legitimately-ours database that has not yet applied migration
    -- 0017 as a "!! CONFLICT" against a foreign table, which is exactly
    -- the false positive this check exists to avoid.
    UNION ALL SELECT 'k9_progression', 4,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression'
         AND COLUMN_NAME IN ('citizenid','xp','created_at','updated_at'))
    UNION ALL SELECT 'k9_permissions', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions'
         AND COLUMN_NAME IN ('citizenid','permission','granted_by','granted_at','revoked_by','revoked_at','active'))
    UNION ALL SELECT 'k9_certification_specializations', 8,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations'
         AND COLUMN_NAME IN ('citizenid','job','specialization','granted_by','granted_at','revoked_by','revoked_at','active'))
    UNION ALL SELECT 'k9_runtime_feature_overrides', 5,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides'
         AND COLUMN_NAME IN ('override_key','kind','value','updated_by','updated_at'))
    UNION ALL SELECT 'k9_runtime_override_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit'
         AND COLUMN_NAME IN ('override_key','kind','old_value','new_value','changed_by','changed_at'))
    UNION ALL SELECT 'k9_tablet_theme', 8,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme'
         AND COLUMN_NAME IN ('primary_color','accent_color','background_color','text_color','density','header_title','updated_by','updated_at'))
    UNION ALL SELECT 'k9_tablet_theme_audit', 8,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit'
         AND COLUMN_NAME IN ('primary_color','accent_color','background_color','text_color','density','header_title','changed_by','changed_at'))
    UNION ALL SELECT 'k9_ped_assignments', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments'
         AND COLUMN_NAME IN ('citizenid','model','original_model_hash','active','applied_by','applied_at','revoked_at'))
    -- migration 0010 (db-schema foolproofing pass, 2026-08-25): these three
    -- were previously absent from this check entirely -- not "OK", not
    -- "CONFLICT", just silently missing from the report, which meant a VIEW
    -- squatting one of these three table names (or a different, incompatible
    -- table already using one of these names) was invisible here and would
    -- only surface later as a confusing runtime error. See uninstall_all.sql
    -- and migration_status.sql, which had the identical exposure for the
    -- same three tables, fixed in the same change.
    UNION ALL SELECT 'k9_certification_tiers', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tiers'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tiers'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tiers'
         AND COLUMN_NAME IN ('tier_key','label','ordinal','deleted','created_at','updated_by','updated_at'))
    UNION ALL SELECT 'k9_certification_tier_capabilities', 4,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_capabilities'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_capabilities'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_capabilities'
         AND COLUMN_NAME IN ('tier_key','capability_key','granted_by','granted_at'))
    UNION ALL SELECT 'k9_certification_tier_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_audit'
         AND COLUMN_NAME IN ('id','action','tier_key','detail','changed_by','changed_at'))
    -- migration 0011 (db-schema pass, 2026-08-26): these two were previously
    -- absent from this check entirely -- the exact same class of silent gap
    -- migration 0010's three tables had here before being fixed (see the
    -- comment on those three rows above).
    UNION ALL SELECT 'k9_equipment_shop_locations', 4,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations'
         AND COLUMN_NAME IN ('x','y','z','created_by'))
    UNION ALL SELECT 'k9_equipment_shop_locations_audit', 4,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations_audit'
         AND COLUMN_NAME IN ('location_id','action','changed_by','changed_at'))
    -- migration 0013 (owner-directed "add or remove permissions" pass):
    -- these two were previously absent from this check entirely -- the
    -- exact same class of silent gap migrations 0010/0011's tables had
    -- here before being fixed (see the comments on those rows above).
    UNION ALL SELECT 'k9_permission_keys', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_keys'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_keys'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_keys'
         AND COLUMN_NAME IN ('permission_key','label','description','deleted','created_at','updated_by','updated_at'))
    UNION ALL SELECT 'k9_permission_key_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_key_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_key_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_key_audit'
         AND COLUMN_NAME IN ('id','action','permission_key','detail','changed_by','changed_at'))
    -- migration 0014 (owner-directed "give high command real control over
    -- the equipment shop" pass -- the shop's ITEM CATALOG, not just its
    -- locations): these two were previously absent from this check
    -- entirely -- the exact same class of silent gap migrations
    -- 0010/0011/0013's tables had here before being fixed (see the
    -- comments on those rows above).
    -- BOOT-CHECK SYNC (db-schema convergence pass, 2026-08-26): the column
    -- subset named below (`item_key`, `price`, `sort_order`,
    -- `required_tier_key`, `required_specialization`, `deleted`,
    -- `updated_by`) is deliberately the SAME 7 names server/datastore.lua's
    -- own EXPECTED_TABLE_COLUMNS uses for this table, not the `label`/
    -- `currency` pair this row used to check instead -- see the sync note
    -- on the `k9_individual_overrides` row further down for why the two
    -- files disagreeing on which columns identify "ours" is a real hazard
    -- (a different verdict on a genuine name collision), not a cosmetic
    -- detail. The real table has all 9 columns either way (both subsets
    -- pass for a genuine install); only the collision case differs.
    UNION ALL SELECT 'k9_equipment_shop_items', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_items'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_items'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_items'
         AND COLUMN_NAME IN ('item_key','price','sort_order','required_tier_key','required_specialization','deleted','updated_by'))
    UNION ALL SELECT 'k9_equipment_shop_item_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_item_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_item_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_item_audit'
         AND COLUMN_NAME IN ('id','action','item_key','detail','changed_by','changed_at'))
    -- migration 0015 (owner-directed "set experience level for each rank
    -- up" pass): these two were previously absent from this check entirely
    -- -- the exact same class of silent gap migrations 0010/0011/0013's
    -- tables had here before being fixed (see the comments on those rows
    -- above).
    -- BOOT-CHECK SYNC (db-schema convergence pass, 2026-08-26): the column
    -- subset below (7 names, no `medkit_cooldown_multiplier`/`badge`) is
    -- deliberately the SAME list server/datastore.lua's own
    -- EXPECTED_TABLE_COLUMNS uses for this table -- see the sync note on
    -- the `k9_individual_overrides` row further down for why keeping these
    -- two hand-maintained lists identical matters (a real-collision case
    -- can otherwise get a different verdict from preflight than from the
    -- boot check). The real table has all 9 columns either way.
    UNION ALL SELECT 'k9_xp_tiers', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tiers'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tiers'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tiers'
         AND COLUMN_NAME IN ('ordinal','xp_threshold','label','speed_multiplier','scent_range_multiplier','updated_by','updated_at'))
    UNION ALL SELECT 'k9_xp_tier_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tier_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tier_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tier_audit'
         AND COLUMN_NAME IN ('id','action','ordinal','detail','changed_by','changed_at'))
    -- migration 0016 (owner-directed "god over that tablet, full
    -- customization over everything related to that K9" pass, the
    -- per-INDIVIDUAL-K9 override half): these two were previously absent
    -- from this check entirely -- the exact same class of silent gap
    -- migrations 0010/0011/0013/0014/0015's tables had here before being
    -- fixed (see the comments on those rows above).
    -- BOOT-CHECK SYNC FIX (db-schema convergence pass, 2026-08-26):
    -- server/datastore.lua's own runtime schema-collision probe
    -- (EXPECTED_TABLE_COLUMNS, checked at boot) and this file are supposed
    -- to be the SAME hand-maintained-list convention checking the SAME
    -- thing -- datastore.lua's own comment says so in as many words ("THE
    -- COLUMN LIST BELOW MUST STAY IN SYNC WITH sql/preflight_check.sql's
    -- CHECK 1"). They had drifted: this row previously expected 9 columns
    -- including `created_at`/`updated_at`, while datastore.lua's own list
    -- for this same table names only 7 and does not include either. Both
    -- lists happened to still say "OK" for a genuine, fully-formed install
    -- of this resource's OWN table (which has all 9 real columns and
    -- therefore satisfies either subset) -- but the two lists disagreeing
    -- on WHICH columns identify "ours" is exactly the scenario that can
    -- make preflight and the boot check give different verdicts on a real
    -- NAME COLLISION with some other resource's table (one whose columns
    -- happen to overlap one list's picks but not the other's) -- the "owner
    -- gets a clean preflight, then a boot-time refusal, or the reverse"
    -- failure this pair of checks exists to prevent. Reconciled by making
    -- this row match server/datastore.lua's own 7-column list exactly
    -- (`citizenid`, `speed_multiplier`, `scent_range_multiplier`,
    -- `medkit_cooldown_multiplier`, `note`, `deleted`, `updated_by`) rather
    -- than the other way around, since this SQL-side file could be edited
    -- directly in this pass and the Lua-side one could not -- if
    -- datastore.lua's own list is ever widened to the table's full 9
    -- columns, widen this row to match in the same change.
    UNION ALL SELECT 'k9_individual_overrides', 7,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_overrides'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_overrides'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_overrides'
         AND COLUMN_NAME IN ('citizenid','speed_multiplier','scent_range_multiplier','medkit_cooldown_multiplier','note','deleted','updated_by'))
    UNION ALL SELECT 'k9_individual_override_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_override_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_override_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_override_audit'
         AND COLUMN_NAME IN ('id','action','citizenid','detail','changed_by','changed_at'))
    -- migration 0020 (ROSTER_SPEC.md §3/§4, db-schema pass, 2026-08-26):
    -- the K9/Handler roster assignment + callsign table. Column list
    -- deliberately the SAME 9 names server/datastore.lua's own
    -- EXPECTED_TABLE_COLUMNS uses for this table -- see the sync note on
    -- the `k9_individual_overrides` row above for why keeping these two
    -- hand-maintained lists identical matters.
    UNION ALL SELECT 'k9_personnel', 9,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'
         AND COLUMN_NAME IN ('citizenid','job','role','callsign','granted_by','granted_at','cleared_by','cleared_at','active'))
    -- migration 0019 (mana_policedogs feature-parity pass, /k9setdog /
    -- k9removedog's admin-pinned "this citizenid IS a dog" fact) --
    -- SCHEMA-SAFETY AUDIT FIX, db-schema pass 2026-08-27: this table was
    -- missing from this check entirely from the day it shipped -- the exact
    -- same class of silent gap migrations 0010/0011/0013/0014/0015/0016
    -- each had here before being fixed (see the comments on those rows
    -- above). Column list mirrors sql/install.sql's own CREATE TABLE and
    -- server/datastore.lua's own EXPECTED_TABLE_COLUMNS entry for this
    -- table exactly -- keep all three in sync if any changes.
    UNION ALL SELECT 'k9_dog_characters', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'
         AND COLUMN_NAME IN ('citizenid','model','active','set_by','set_at','unset_at'))
    -- migration 0022 (K9 fatigue/mood/fear-stress/injury/hunger/thirst
    -- persistence -- server/wellbeing.lua's K9Store.Wellbeing_Get/
    -- K9Store.Wellbeing_Upsert). Column list mirrors sql/install.sql's own
    -- CREATE TABLE and server/datastore.lua's own EXPECTED_TABLE_COLUMNS
    -- entry for this table exactly -- keep all three in sync if any changes.
    UNION ALL SELECT 'k9_wellbeing', 3,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'
         AND COLUMN_NAME IN ('citizenid','fatigue','updated_at'))
    -- migration 0023 (the K9 role catalog -- server/roles.lua's
    -- K9Store.Role_* accessors). Column list mirrors sql/install.sql and
    -- server/datastore.lua's EXPECTED_TABLE_COLUMNS exactly.
    UNION ALL SELECT 'k9_roles', 8,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'
         AND COLUMN_NAME IN ('role_key','label','xp_required','unlocks','deleted','created_at','updated_by','updated_at'))
    -- migration 0024 (role edit history -- K9Store.RoleAudit_*).
    UNION ALL SELECT 'k9_role_audit', 6,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_role_audit'),
      (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_role_audit'),
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_role_audit'
         AND COLUMN_NAME IN ('id','action','role_key','detail','changed_by','changed_at'))
) x
ORDER BY x.table_name;


-- ---------------------------------------------------------------------
-- CHECK 1b: is there a k9_* table in this database that CHECK 1 above does
-- not even know to look for?
--
-- CHECK 1 above can only report "OK"/"CONFLICT" for the table names it is
-- explicitly told to check -- exactly the gap that let a VIEW squatting one
-- of migration 0010's three table names go completely unreported for a
-- time (see that check's own comment). This is the backstop for the NEXT
-- table a future migration adds before this file is updated to match: it
-- sweeps INFORMATION_SCHEMA by NAME PATTERN (`k9\_%`) instead of a
-- hand-maintained list, so it needs no updating when a new migration lands
-- -- unlike CHECK 1 itself, which cannot be pattern-swept without losing
-- its own per-table expected-column signatures (see uninstall_all.sql's own
-- "OWNED TABLE LIST" comment for the identical DROP-order / other-resources
-- reasoning that applies here too).
--
-- WARN, never "!!": this file cannot tell "this file is out of date" apart
-- from "a different K9 resource (e.g. k9_units) already shares this
-- database", and the second case is common and legitimate -- so this never
-- blocks an install by itself, the same posture CHECK 5 below already takes
-- for its own genuinely ambiguous case.
-- ---------------------------------------------------------------------
SELECT
    CASE WHEN COUNT(*) = 0
        THEN 'OK - no k9_* table in this database is unknown to CHECK 1 above'
        ELSE CONCAT('WARN - ', COUNT(*), ' k9_* table(s) exist that are not part of this resource''s current schema: ',
                    GROUP_CONCAT(TABLE_NAME ORDER BY TABLE_NAME SEPARATOR ', '),
                    '. If any of these belong to john-k9, CHECK 1 above is out of date -- report it before installing. If they belong to a different K9 resource sharing this database, this is expected and safe to ignore.')
    END AS unrecognized_k9_tables_check
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME LIKE 'k9\_%'
  AND TABLE_NAME NOT IN ('k9_certifications','k9_search_log','k9_partnerships','k9_progression',
                          'k9_permissions','k9_certification_specializations',
                          'k9_runtime_feature_overrides','k9_runtime_override_audit',
                          'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments',
                          'k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit',
                          'k9_equipment_shop_locations','k9_equipment_shop_locations_audit',
                          'k9_permission_keys','k9_permission_key_audit',
                          'k9_equipment_shop_items','k9_equipment_shop_item_audit',
                          'k9_xp_tiers','k9_xp_tier_audit',
                          'k9_individual_overrides','k9_individual_override_audit',
                          'k9_partnership_pair_progress','k9_personnel','k9_dog_characters','k9_wellbeing','k9_roles','k9_role_audit');


-- ---------------------------------------------------------------------
-- CHECK 2: is your database server new enough, and can it run the
-- migrations?
--
-- Two separate requirements:
--   * VERSION -- MySQL 5.7.8+ or MariaDB 10.2+. Older servers cannot
--     parse this resource's generated columns at all and will leave a
--     half-built database. MySQL 5.6 in particular WILL fail.
--   * CREATE ROUTINE -- migrations 0003 and 0004 create a temporary
--     stored procedure, run it once, and immediately drop it again.
--     Some managed/shared hosts do not grant this. install.sql itself
--     does NOT need it; only those two migration files do.
-- ---------------------------------------------------------------------
SELECT
    VERSION() AS server_version,
    CASE
        WHEN VERSION() LIKE '%MariaDB%' THEN
            CASE WHEN CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) > 10
                   OR (CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) = 10
                       AND CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(),'.',2),'.',-1) AS UNSIGNED) >= 2)
                 THEN 'OK - MariaDB 10.2 or newer'
                 ELSE '!! TOO OLD - needs MariaDB 10.2 or newer. Do NOT install.' END
        WHEN CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) >= 8 THEN 'OK - MySQL 8'
        WHEN CAST(SUBSTRING_INDEX(VERSION(),'.',1) AS UNSIGNED) = 5
             AND CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(),'.',2),'.',-1) AS UNSIGNED) >= 7
             THEN 'OK - MySQL 5.7 (must be 5.7.8 or newer)'
        ELSE '!! TOO OLD - needs MySQL 5.7.8+ or MariaDB 10.2+. Do NOT install.'
    END AS version_verdict;


-- ---------------------------------------------------------------------
-- CHECK 3: what is already in our tables, if anything?
--
-- Purely informational: if these are non-zero you are upgrading, not
-- installing fresh, so take a backup first
-- (sql/rollback/backup_k9_tables.sh). Zeroes here are perfectly normal
-- for a first install -- CHECK 1 above is the one that matters.
-- ---------------------------------------------------------------------
SELECT TABLE_NAME AS `our_table`, TABLE_ROWS AS `approx_rows`
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships','k9_progression','k9_permissions','k9_certification_specializations','k9_runtime_feature_overrides','k9_runtime_override_audit','k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments','k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit','k9_equipment_shop_locations','k9_equipment_shop_locations_audit','k9_permission_keys','k9_permission_key_audit','k9_equipment_shop_items','k9_equipment_shop_item_audit','k9_xp_tiers','k9_xp_tier_audit','k9_individual_overrides','k9_individual_override_audit','k9_partnership_pair_progress','k9_personnel','k9_dog_characters','k9_wellbeing','k9_roles','k9_role_audit')
ORDER BY TABLE_NAME;


-- ---------------------------------------------------------------------
-- CHECK 4: do you have CREATE ROUTINE on this database?
--
-- Migrations 0003 and 0004, and every script in sql/rollback/, create a
-- temporary stored procedure, call it once, and drop it again. That
-- needs the CREATE ROUTINE privilege. Some managed/shared hosts do not
-- grant it.
--
-- THIS IS ONLY A PROBLEM FOR UPGRADES AND ROLLBACKS, NOT FOR A FRESH
-- INSTALL. `install.sql` on its own needs no routine privilege at all,
-- and already produces the final table shape, indexes and constraints in
-- a single pass -- so a brand-new install on a restricted host is fine.
--
-- The privilege may be granted on this database specifically OR globally,
-- so both are checked. Without it, migration 0003/0004 and every rollback
-- script stop with exactly this (real error text, reproduced on a
-- restricted user):
--
--   ERROR 1370 (42000) at line 172: alter routine command denied to user
--   'fivem_limited'@'localhost' for routine
--   'k9priv.john_k9_migration_0004_add_active_cert_key_column'
--
-- Nothing is damaged when that happens -- the file simply stops.
-- ---------------------------------------------------------------------
SELECT
    CASE WHEN (
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMA_PRIVILEGES
          WHERE PRIVILEGE_TYPE = 'CREATE ROUTINE'
            AND TABLE_SCHEMA = DATABASE()
            AND REPLACE(GRANTEE, '''', '') = CURRENT_USER())
      + (SELECT COUNT(*) FROM INFORMATION_SCHEMA.USER_PRIVILEGES
          WHERE PRIVILEGE_TYPE = 'CREATE ROUTINE'
            AND REPLACE(GRANTEE, '''', '') = CURRENT_USER())
    ) > 0
      THEN 'OK - CREATE ROUTINE available, migrations and rollback scripts will run'
      ELSE 'NOTE - this user has no CREATE ROUTINE. A FRESH install.sql still works fine and is unaffected. But migrations 0003/0004 and every sql/rollback/ script will stop with ERROR 1370 (nothing is damaged). Ask your host to GRANT CREATE ROUTINE, or have them run those files for you.'
    END AS create_routine_verdict;


-- ---------------------------------------------------------------------
-- CHECK 5: does this look like the right database at all?
--
-- Every citizenid this resource ever stores is only meaningful next to a
-- real qbx_core/QBCore `players` table -- this resource declares no
-- foreign key to it (see install.sql's own k9_certifications header for
-- why), so installing into the WRONG database, or a database qbx_core has
-- never touched yet, does not error. It just quietly produces a K9 system
-- full of citizenids that never match anyone real -- the single most
-- common real-world cause of "why don't my certifications show up
-- in-game" support requests, and usually a typo'd database name, not a
-- real problem with this resource.
--
-- WARNING ONLY -- never a stop. A brand-new, multi-resource database
-- provisioned before qbx_core has run for the very first time is a real,
-- legitimate situation, not necessarily a mistake, so this never refuses
-- to let you continue -- it only asks you to double-check.
-- ---------------------------------------------------------------------
SELECT
    CASE
        WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE()) = 0
            THEN CONCAT('WARN - database `', DATABASE(), '` has NO tables at all. ',
                        'If you meant to install into your live FiveM database, check for a typo''d ',
                        'database name before continuing -- this is the most common real-world cause ',
                        'of a K9 system whose citizenids never match a real player. If this is a ',
                        'genuinely brand-new server and qbx_core has never started yet, start it first ',
                        'so its `players` table exists, then come back and install this resource. ',
                        '(This is a warning, not a stop -- a fresh multi-resource database provisioned ',
                        'before qbx_core''s first run is a real, legitimate situation.)')
        WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'players') = 0
            THEN CONCAT('WARN - database `', DATABASE(), '` has tables, but none named `players`. ',
                        'john-k9''s citizenid columns are only meaningful next to a real qbx_core/QBCore ',
                        '`players` table. This resource will still install correctly (it has no foreign key ',
                        'to `players`, on purpose), but double-check this is really the same database your ',
                        'FiveM server''s `qbx_core` resource points at before you rely on any of this. ',
                        '(This is a warning, not a stop.)')
        ELSE CONCAT('OK - database `', DATABASE(), '` has a `players` table, consistent with a real qbx_core/QBCore install')
    END AS qbx_core_sanity_check;
