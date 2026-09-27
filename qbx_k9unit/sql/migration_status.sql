-- =====================================================================
-- qbx_k9unit :: MIGRATION PLAN / DRY RUN -- read-only, changes nothing
--
-- WHAT IT DOES: tells you exactly what running `install.sql` and every
-- file in `sql/migrations/` (in order) WOULD do to this database right
-- now, without doing any of it. Every row below is either "no-op — already
-- applied" or a plain-English description of the real CREATE/ALTER
-- statement that file would run.
--
-- WHY THIS IS THE ONLY HONEST WAY TO "DRY RUN" A SCHEMA CHANGE: MySQL and
-- MariaDB both auto-commit CREATE TABLE / ALTER TABLE the instant they run
-- -- there is no way to wrap them in a transaction and roll it back
-- afterward to "preview" them. Actually running the real files is the only
-- way to know for certain they will work; this report is the next best
-- thing -- it reads the exact same INFORMATION_SCHEMA state the guarded
-- migrations themselves check, and prints what they would decide.
--
-- HOW TO RUN IT:
--     mysql -u YOUR_USER -p YOUR_DATABASE < migration_status.sql
-- ...or paste it into phpMyAdmin / HeidiSQL with your database selected.
-- `sql/k9_setup.sh --dry-run` runs this for you automatically.
--
-- SAFE EVEN WHEN OUR TABLES DO NOT EXIST YET (fresh database): every
-- check below either queries INFORMATION_SCHEMA only (which always
-- exists), or -- for the one check that genuinely needs to look at real
-- row data (0004's pre-existing-duplicate-certification check) -- uses
-- PREPARE/EXECUTE to build that query ONLY when the target table is
-- confirmed present. A flat `SELECT ... FROM k9_certifications ...` would
-- itself throw a raw "table doesn't exist" error on a fresh database
-- before ever reaching a WHERE guard (MySQL resolves table names at parse
-- time, not row-evaluation time) -- exactly the kind of raw error this
-- report exists to prevent, so it is avoided here on purpose.
-- PREPARE/EXECUTE needs no elevated privilege (unlike a stored procedure,
-- it does not require CREATE ROUTINE), so this file works on the same
-- restricted/managed hosts preflight_check.sql's own CHECK 4 already
-- flags as sometimes lacking that grant.
--
-- This never touches sql/rollback/uninstall_all.sql -- that file's own
-- unarmed run is already its own free dry run (see that file's header).
-- =====================================================================


-- ---------------------------------------------------------------------
-- PART 1: install.sql -- what would a plain run create right now?
--
-- install.sql only ever CREATEs (CREATE TABLE IF NOT EXISTS); it never
-- ALTERs a table that already exists in some other shape. So for any
-- table already present, install.sql is a guaranteed no-op EVEN IF that
-- table is missing a column/index a later migration would add -- that is
-- exactly what the migrations in PART 2 below are for.
-- ---------------------------------------------------------------------
SELECT
    t.table_name AS `install.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN 'CREATE this table (currently absent)'
         ELSE 'no-op -- table already exists (install.sql never ALTERs an existing table; see PART 2 for column/index-level changes)'
    END AS plan
FROM (
    SELECT 'k9_certifications' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists
    UNION ALL SELECT 'k9_certification_specializations',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations')
    UNION ALL SELECT 'k9_search_log',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_search_log')
    UNION ALL SELECT 'k9_partnerships',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships')
    UNION ALL SELECT 'k9_progression',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression')
    UNION ALL SELECT 'k9_permissions',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions')
    UNION ALL SELECT 'k9_runtime_feature_overrides',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides')
    UNION ALL SELECT 'k9_runtime_override_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit')
    UNION ALL SELECT 'k9_tablet_theme',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme')
    UNION ALL SELECT 'k9_tablet_theme_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit')
    UNION ALL SELECT 'k9_ped_assignments',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments')
    UNION ALL SELECT 'k9_certification_tiers',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tiers')
    UNION ALL SELECT 'k9_certification_tier_capabilities',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_capabilities')
    UNION ALL SELECT 'k9_certification_tier_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_audit')
    UNION ALL SELECT 'k9_equipment_shop_locations',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations')
    UNION ALL SELECT 'k9_equipment_shop_locations_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations_audit')
    UNION ALL SELECT 'k9_permission_keys',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_keys')
    UNION ALL SELECT 'k9_permission_key_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_key_audit')
    UNION ALL SELECT 'k9_equipment_shop_items',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_items')
    UNION ALL SELECT 'k9_equipment_shop_item_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_item_audit')
    UNION ALL SELECT 'k9_xp_tiers',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tiers')
    UNION ALL SELECT 'k9_xp_tier_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tier_audit')
    UNION ALL SELECT 'k9_individual_overrides',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_overrides')
    UNION ALL SELECT 'k9_individual_override_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_override_audit')
    UNION ALL SELECT 'k9_partnership_pair_progress',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress')
    UNION ALL SELECT 'k9_personnel',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel')
    UNION ALL SELECT 'k9_dog_characters',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters')
    UNION ALL SELECT 'k9_wellbeing',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing')
    UNION ALL SELECT 'k9_roles',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles')
) t
ORDER BY t.table_name;
-- NOTE: install.sql now converges with sql/migrations/0001-0023 (29 tables
-- total, including k9_progression's idx_xp, migration 0010's three
-- certification-tier tables, migration 0011's two equipment-shop-location
-- tables, migration 0013's two permission-key-catalog tables, migration
-- 0014's two equipment-shop-item tables, migration 0015's two
-- XP-rank-override tables, migration 0016's two per-individual-K9
-- override tables, migration 0018's one partnership-tenure
-- anti-farm-guard table, migration 0019's one admin-pinned dog-character
-- table (mana_policedogs feature parity, /k9setdog /k9removedog -- this
-- table was itself the SCHEMA-SAFETY AUDIT FIX, db-schema pass 2026-08-27:
-- it had been completely absent from install.sql/this file/preflight_check
-- .sql/uninstall_all.sql/backup_k9_tables.sh/datastore.lua's
-- EXPECTED_TABLE_COLUMNS since the day migration 0019 shipped, so a fresh
-- install via install.sql alone never created it at all), migration
-- 0020's one K9/Handler roster assignment table (ROSTER_SPEC.md §3/§4), and
-- migration 0022's one K9 fatigue/mood/fear-stress/injury/hunger/thirst
-- persistence table (server/wellbeing.lua's K9Store.Wellbeing_Get/
-- K9Store.Wellbeing_Upsert)).
-- If this comment and install.sql's real table count ever disagree again,
-- install.sql is out of date; report it rather than trust this file. (This
-- comment previously said "0001-0011 / 16 tables", then "0001-0013/0015 /
-- 20 tables" while claiming migration 0014's own two tables were a
-- still-pending, separately-landing pass -- that was itself the exact
-- class of silent omission this note exists to flag: migration 0014 had
-- already shipped as a real migration file for some time by then,
-- install.sql was simply never updated to match it. Fixed here, along with
-- install.sql itself, in the same change.)


-- ---------------------------------------------------------------------
-- PART 2: sql/migrations/0001-0011 -- what would each one do, in order?
--
-- Mirrors each file's own INFORMATION_SCHEMA guard exactly, so the
-- verdict below is what that file will actually decide, not a guess.
-- ---------------------------------------------------------------------

-- 0001 / 0002 / 0005 / 0007: bare CREATE TABLE IF NOT EXISTS, no ALTER,
-- no dependency on any other table -- same no-op-or-create logic as PART 1.
SELECT
    m.migration_file AS `migration`,
    CASE WHEN m.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', m.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', m.table_name, '` already exists')
    END AS plan
FROM (
    SELECT '0001_create_k9_partnerships.sql' AS migration_file, 'k9_partnerships' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships') AS tbl_exists
    UNION ALL SELECT '0002_create_k9_progression.sql', 'k9_progression',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression')
    UNION ALL SELECT '0005_create_k9_permissions.sql', 'k9_permissions',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permissions')
    UNION ALL SELECT '0007_create_k9_runtime_control.sql', 'k9_runtime_feature_overrides',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_feature_overrides')
    UNION ALL SELECT '0008_create_k9_ped_assignments.sql', 'k9_ped_assignments',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_ped_assignments')
) m;

-- 0007 creates FOUR tables in one file -- the other three, reported
-- separately so a partially-applied 0007 (e.g. interrupted mid-file) shows
-- accurately instead of only reporting on the first table.
SELECT
    '0007_create_k9_runtime_control.sql (cont.)' AS `migration`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_runtime_override_audit' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_runtime_override_audit') AS tbl_exists
    UNION ALL SELECT 'k9_tablet_theme',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme')
    UNION ALL SELECT 'k9_tablet_theme_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_tablet_theme_audit')
) t;

-- 0003: ALTER k9_partnerships, ADD COLUMN tenure_bonus_tier_granted.
-- Depends on k9_partnerships existing first (see the order-protection
-- guard added to 0003 itself) -- reported here too, so a dry run catches
-- the same "wrong order" problem the migration itself would refuse on.
-- Row count comes from INFORMATION_SCHEMA's own InnoDB estimate
-- (TABLE_ROWS), not a live COUNT(*) -- approximate, but safe to read even
-- when the table does not exist (simply NULL), and this report is
-- explicitly a planning estimate everywhere else too.
SELECT
    '0003_add_k9_partnerships_tenure_bonus_tier_granted.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_partnerships does not exist yet. Run install.sql or migration 0001 first.'
        WHEN base.col_exists > 0
            THEN 'no-op -- tenure_bonus_tier_granted already present'
        ELSE CONCAT('ADD COLUMN tenure_bonus_tier_granted to k9_partnerships (defaults to 0 for all ~',
                    IFNULL(base.approx_rows, 0), ' existing row(s))')
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships' AND COLUMN_NAME='tenure_bonus_tier_granted') AS col_exists,
      (SELECT TABLE_ROWS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnerships') AS approx_rows
) base;

-- 0004: ALTER k9_certifications -- add active_cert_key, two plain indexes,
-- and the uq_one_active_cert_per_job unique key. Depends on
-- k9_certifications existing first.
--
-- The duplicate-active-row pre-check below (the ONE way this migration can
-- legitimately fail even when the table exists) needs to look at REAL ROWS
-- in k9_certifications, not just INFORMATION_SCHEMA metadata -- so it is
-- built as dynamic SQL (PREPARE/EXECUTE) gated on the table actually
-- existing, per this file's own header note on why a flat SELECT here
-- would be unsafe on a fresh database.
SET @k9ms_has_certs = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications');
SET @k9ms_dupe_pairs = 0;
SET @k9ms_dupe_sql = IF(@k9ms_has_certs > 0,
    'SELECT COUNT(*) INTO @k9ms_dupe_pairs FROM (SELECT citizenid, job FROM k9_certifications WHERE active = 1 GROUP BY citizenid, job HAVING COUNT(*) > 1) k9ms_dupes',
    'SELECT 1');
PREPARE k9ms_stmt FROM @k9ms_dupe_sql;
EXECUTE k9ms_stmt;
DEALLOCATE PREPARE k9ms_stmt;

SELECT
    '0004_add_k9_certifications_active_cert_key.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_certifications does not exist yet. Run install.sql first.'
        WHEN base.col_exists > 0 AND base.uq_exists > 0 AND base.idx1_exists > 0 AND base.idx2_exists > 0
            THEN 'no-op -- active_cert_key column and all three indexes already present'
        ELSE CONCAT(
            'will apply what is missing: ',
            IF(base.col_exists = 0, 'ADD COLUMN active_cert_key; ', ''),
            IF(base.idx1_exists = 0, 'ADD INDEX idx_citizen_job_active; ', ''),
            IF(base.idx2_exists = 0, 'ADD INDEX idx_job_active; ', ''),
            IF(base.uq_exists = 0,
               IF(@k9ms_dupe_pairs > 0,
                  CONCAT('ADD UNIQUE KEY uq_one_active_cert_per_job -- WILL FAIL: ', @k9ms_dupe_pairs,
                         ' (citizenid, job) pair(s) already have more than one active row. See sql/migrations/0004_add_k9_certifications_active_cert_key.sql''s own OPERATOR NOTE BEFORE running this migration.'),
                  'ADD UNIQUE KEY uq_one_active_cert_per_job'),
               '')
        )
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='active_cert_key') AS col_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='uq_one_active_cert_per_job') AS uq_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='idx_citizen_job_active') AS idx1_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='idx_job_active') AS idx2_exists
) base;

-- 0006: ALTER k9_certifications (tier / revoke_reason / expires_at /
-- idx_expires_at) + CREATE TABLE k9_certification_specializations. The
-- order-protection guard added to 0006 SIGNALs when k9_certifications is
-- missing, and the plain mysql CLI (this resource's documented invocation
-- method) aborts the rest of the script on that error -- so the WHOLE FILE
-- is blocked as one unit, Step 5's CREATE TABLE included, not just the
-- four ALTER steps (verified by execution; an earlier draft of both this
-- report and 0006's own guard comment said otherwise -- corrected here to
-- match what actually happens).
SELECT
    '0006_add_k9_certification_lifecycle.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED (the whole file, including the new k9_certification_specializations TABLE) -- k9_certifications does not exist yet. Run install.sql first.'
        WHEN base.tier_exists > 0 AND base.reason_exists > 0 AND base.expires_exists > 0 AND base.idx_exists > 0
            THEN 'no-op -- tier, revoke_reason, expires_at and idx_expires_at already present on k9_certifications'
        ELSE CONCAT(
            'will apply what is missing on k9_certifications: ',
            IF(base.tier_exists = 0, 'ADD COLUMN tier (defaults every existing row to ''certified'', preserving current access); ', ''),
            IF(base.reason_exists = 0, 'ADD COLUMN revoke_reason (NULL, no backfill); ', ''),
            IF(base.expires_exists = 0, 'ADD COLUMN expires_at (NULL, no backfill -- never expires); ', ''),
            IF(base.idx_exists = 0, 'ADD INDEX idx_expires_at; ', '')
        )
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='tier') AS tier_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='revoke_reason') AS reason_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND COLUMN_NAME='expires_at') AS expires_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certifications' AND INDEX_NAME='idx_expires_at') AS idx_exists
) base;

SELECT
    '0006_add_k9_certification_lifecycle.sql (cont.)' AS `migration`,
    CASE WHEN spec.tbl_exists = 0
         THEN 'CREATE TABLE k9_certification_specializations (currently absent -- independent of the k9_certifications columns above)'
         ELSE 'no-op -- k9_certification_specializations already exists'
    END AS plan
FROM (
    SELECT (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_specializations') AS tbl_exists
) spec;

-- 0009: ALTER k9_progression, ADD KEY idx_xp (xp) -- for /k9stats
-- (Config.Features.K9Leaderboard). Depends on k9_progression existing
-- first (see the order-protection guard added to 0009 itself). Plain
-- index, no data written, so no duplicate-row failure mode like 0004's.
SELECT
    '0009_add_k9_progression_idx_xp.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_progression does not exist yet. Run install.sql or migration 0002 first.'
        WHEN base.idx_exists > 0
            THEN 'no-op -- idx_xp already present'
        ELSE 'ADD INDEX idx_xp (xp) to k9_progression'
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression' AND INDEX_NAME='idx_xp') AS idx_exists
) base;

-- 0010: CREATE TABLE x3 (k9_certification_tiers /
-- k9_certification_tier_capabilities / k9_certification_tier_audit) --
-- db-schema foolproofing pass: this migration was previously completely
-- absent from this report, so `k9_setup.sh --dry-run` never told an
-- operator it existed or what it would do, even though `install.sql`
-- already creates all three tables directly (see PART 1 above) and
-- `sql/migrations/0010_create_k9_certification_tiers.sql` creates them for
-- an upgrade path. Independent of every other table (see that migration's
-- own header "ORDERING" section -- no FK, no dependency on any other
-- table), so unlike 0003/0004/0006/0009 above there is no "BLOCKED"
-- case to report here.
SELECT
    t.table_name AS `0010_create_k9_certification_tiers.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_certification_tiers' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tiers') AS tbl_exists
    UNION ALL SELECT 'k9_certification_tier_capabilities',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_capabilities')
    UNION ALL SELECT 'k9_certification_tier_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_certification_tier_audit')
) t;

-- 0011: CREATE TABLE x2 (k9_equipment_shop_locations /
-- k9_equipment_shop_locations_audit) -- db-schema convergence pass, 2026-08-26:
-- this migration was previously completely absent from this report, the
-- same class of omission migration 0010 already had fixed here once
-- before (see the PART 1 note above). Independent of every other table
-- (see that migration's own header "ORDERING" section -- no FK, no
-- dependency on any other table), so there is no "BLOCKED" case to report
-- here, same as 0010 above.
SELECT
    t.table_name AS `0011_create_k9_equipment_shop_locations.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_equipment_shop_locations' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations') AS tbl_exists
    UNION ALL SELECT 'k9_equipment_shop_locations_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_locations_audit')
) t;

-- 0013: CREATE TABLE x2 (k9_permission_keys / k9_permission_key_audit) --
-- owner-directed "add or remove permissions" pass: this migration was
-- previously completely absent from this report, the same class of
-- omission migrations 0010/0011 already had fixed here once before (see
-- the PART 1 note above). Independent of every other table (see that
-- migration's own header "ORDERING" section -- no FK, no dependency on any
-- other table), so there is no "BLOCKED" case to report here, same as
-- 0010/0011 above.
SELECT
    t.table_name AS `0013_create_k9_permission_keys.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_permission_keys' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_keys') AS tbl_exists
    UNION ALL SELECT 'k9_permission_key_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_permission_key_audit')
) t;

-- 0014: CREATE TABLE x2 (k9_equipment_shop_items / k9_equipment_shop_item_audit)
-- -- owner-directed "give high command real control over the equipment
-- shop" pass, the shop's ITEM CATALOG half (server/equipmentshop.lua's own
-- pre-existing migration 0011 already covers the shop's LOCATIONS half):
-- this migration was previously completely absent from this report, the
-- same class of omission migrations 0010/0011/0013 already had fixed here
-- once before (see the PART 1 note above). Independent of every other
-- table (see that migration's own header "ORDERING" section -- no FK, no
-- dependency on any other table), so there is no "BLOCKED" case to report
-- here, same as 0010/0011/0013 above.
SELECT
    t.table_name AS `0014_create_k9_equipment_shop_items.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_equipment_shop_items' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_items') AS tbl_exists
    UNION ALL SELECT 'k9_equipment_shop_item_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_equipment_shop_item_audit')
) t;

-- 0015: CREATE TABLE x2 (k9_xp_tiers / k9_xp_tier_audit) -- owner-directed
-- "set experience level for each rank up" pass (0014 is a separate,
-- concurrently-landing equipment-shop-item pass, not this one -- see that
-- migration's own header): this migration was previously completely
-- absent from this report, the same class of omission migrations
-- 0010/0011/0013 already had fixed here once before (see the PART 1 note
-- above). Independent of every other table (see that migration's own
-- header "ORDERING" section -- no FK, no dependency on any other table),
-- so there is no "BLOCKED" case to report here, same as 0010/0011/0013
-- above.
SELECT
    t.table_name AS `0015_create_k9_xp_tiers.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_xp_tiers' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tiers') AS tbl_exists
    UNION ALL SELECT 'k9_xp_tier_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_xp_tier_audit')
) t;

-- 0016: CREATE TABLE x2 (k9_individual_overrides / k9_individual_override_audit)
-- -- owner-directed "god over that tablet, full customization over
-- everything related to that K9" pass, the per-INDIVIDUAL-K9 override half
-- (migration 0015's k9_xp_tiers already covers the per-RANK half -- see
-- server/k9profiles.lua's own header for the full "what already existed"
-- writeup): this migration was previously completely absent from this
-- report, the same class of omission migrations 0010/0011/0013/0014
-- already had fixed here once before (see the PART 1 note above).
-- Independent of every other table (see that migration's own header
-- "ORDERING" section -- no FK, no dependency on any other table), so there
-- is no "BLOCKED" case to report here, same as 0010/0011/0013/0014/0015
-- above.
SELECT
    t.table_name AS `0016_create_k9_individual_overrides.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_individual_overrides' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_overrides') AS tbl_exists
    UNION ALL SELECT 'k9_individual_override_audit',
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_individual_override_audit')
) t;

-- 0017: ALTER k9_progression, ADD COLUMN handler_xp -- owner-directed
-- "partners and levels" tablet tab, handler half (config.lua's
-- Config.Features.HandlerXPProgression / Config.HandlerXPTiers).
-- Depends on k9_progression existing first (see the order-protection
-- guard added to 0017 itself, mirroring 0009's). Plain column with a
-- constant DEFAULT, no data written beyond the backfill DEFAULT itself,
-- so no duplicate-row failure mode like 0004's.
SELECT
    '0017_add_k9_progression_handler_xp.sql' AS `migration`,
    CASE
        WHEN base.tbl_exists = 0
            THEN 'BLOCKED -- k9_progression does not exist yet. Run install.sql or migration 0002 first.'
        WHEN base.col_exists > 0
            THEN 'no-op -- handler_xp already present'
        ELSE 'ADD COLUMN handler_xp INT UNSIGNED NOT NULL DEFAULT 0 to k9_progression (backfills every existing row to 0, no operator action needed)'
    END AS plan
FROM (
    SELECT
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression') AS tbl_exists,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_progression' AND COLUMN_NAME='handler_xp') AS col_exists
) base;

-- 0018: CREATE TABLE (k9_partnership_pair_progress) -- the fully durable
-- half of the partnership-tenure anti-farm guard, closing the
-- "in-memory only, a restart re-opens the exploit once per pair" gap
-- KNOWN_ISSUES.md used to disclose (see that migration's own header for
-- the full design). Independent of every other table (no FK, no
-- dependency on any other table -- see that migration's own header
-- "ORDERING" section), so there is no "BLOCKED" case to report here, same
-- as 0010/0011/0013/0014/0015/0016 above.
SELECT
    t.table_name AS `0018_create_k9_partnership_pair_progress.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_partnership_pair_progress' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress') AS tbl_exists
) t;

-- 0019: CREATE TABLE (k9_dog_characters) -- mana_policedogs feature-parity
-- pass, the admin-pinned "this citizenid IS a dog" fact behind /k9setdog
-- and /k9removedog (server/dogcharacter.lua). SCHEMA-SAFETY AUDIT FIX
-- (db-schema pass, 2026-08-27): this migration was previously completely
-- absent from this report -- the exact same class of omission migrations
-- 0010/0011/0013/0014/0015/0016 already had fixed here once before (see
-- the PART 1 note above), except this one was never caught until a
-- dedicated schema-safety audit found it: install.sql, this file,
-- preflight_check.sql, uninstall_all.sql, backup_k9_tables.sh and
-- datastore.lua's EXPECTED_TABLE_COLUMNS had ALL missed this table since
-- the day migration 0019 shipped. Independent of every other table (see
-- that migration's own header -- no FK, no dependency on any other table),
-- so there is no "BLOCKED" case to report here, same as
-- 0010/0011/0013/0014/0015/0016/0018 above.
SELECT
    t.table_name AS `0019_create_k9_dog_characters.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_dog_characters' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters') AS tbl_exists
) t;

-- 0020: CREATE TABLE (k9_personnel) -- ROSTER_SPEC.md §3/§4, the K9/Handler
-- roster assignment + callsign table. Independent of every other table (no
-- FK, no dependency on any other table -- see that migration's own header
-- "ORDERING" section), so there is no "BLOCKED" case to report here, same
-- as 0010/0011/0013/0014/0015/0016/0018 above.
SELECT
    t.table_name AS `0020_create_k9_personnel.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_personnel' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel') AS tbl_exists
) t;

-- 0022: CREATE TABLE (k9_wellbeing) -- K9 fatigue/mood/fear-stress/injury/
-- hunger/thirst persistence (server/wellbeing.lua's K9Store.Wellbeing_Get/
-- K9Store.Wellbeing_Upsert -- closes the "a routine restart silently resets
-- every K9's condition" gap; see that migration's own header). Independent
-- of every other table (no FK, no dependency on any other table), so there
-- is no "BLOCKED" case to report here, same as
-- 0010/0011/0013/0014/0015/0016/0018/0019/0020 above.
SELECT
    t.table_name AS `0022_create_k9_wellbeing.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_wellbeing' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing') AS tbl_exists
) t;

-- 0023: CREATE TABLE (k9_roles) -- the K9 role catalog high command edits
-- on the tablet (server/roles.lua). Independent of every other table.
SELECT
    t.table_name AS `0023_create_k9_roles.sql would...`,
    CASE WHEN t.tbl_exists = 0
         THEN CONCAT('CREATE TABLE `', t.table_name, '` (currently absent)')
         ELSE CONCAT('no-op -- `', t.table_name, '` already exists')
    END AS plan
FROM (
    SELECT 'k9_roles' AS table_name,
      (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles') AS tbl_exists
) t;


-- ---------------------------------------------------------------------
-- PART 3: blast-radius summary -- row counts for every table that
-- ALREADY exists (these are what a full-database backup, taken before you
-- proceed, would be protecting).
-- ---------------------------------------------------------------------
SELECT TABLE_NAME AS `existing_table`, TABLE_ROWS AS `approx_rows`
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships','k9_progression',
                      'k9_permissions','k9_certification_specializations',
                      'k9_runtime_feature_overrides','k9_runtime_override_audit',
                      'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments',
                      'k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit',
                      'k9_equipment_shop_locations','k9_equipment_shop_locations_audit',
                      'k9_permission_keys','k9_permission_key_audit',
                      'k9_equipment_shop_items','k9_equipment_shop_item_audit',
                      'k9_xp_tiers','k9_xp_tier_audit',
                      'k9_individual_overrides','k9_individual_override_audit',
                      'k9_partnership_pair_progress','k9_personnel','k9_dog_characters','k9_wellbeing','k9_roles')
ORDER BY TABLE_NAME;

-- DRIFT CHECK -- same posture and same reasoning as preflight_check.sql's
-- own CHECK 1b and uninstall_all.sql's own DRIFT CHECK dependency-report
-- branch (both added in the same change as this one): a `k9_%` table this
-- report does not know to plan for is either this file being out of date
-- (report it) or a different K9 resource's own table sharing the prefix
-- (expected, ignore it) -- this file cannot tell those apart, so it warns
-- rather than guessing either way.
SELECT
    CASE WHEN COUNT(*) = 0
        THEN 'OK - no k9_* table in this database is unknown to this report'
        ELSE CONCAT('WARN - ', COUNT(*), ' k9_* table(s) exist that this report does not plan for: ',
                    GROUP_CONCAT(TABLE_NAME ORDER BY TABLE_NAME SEPARATOR ', '),
                    '. If any of these belong to qbx_k9unit, this file is missing a migration -- report it. If they belong to a different K9 resource sharing this database, this is expected and safe to ignore.')
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
                          'k9_partnership_pair_progress','k9_personnel','k9_dog_characters','k9_wellbeing','k9_roles');

SELECT 'DRY RUN COMPLETE -- nothing was changed by this report. Run sql/k9_setup.sh (without --dry-run) to actually apply the plan above; it backs up your whole database first, automatically, and refuses to write anything if that backup fails.' AS final_note;
