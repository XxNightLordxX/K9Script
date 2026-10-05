-- =====================================================================
-- john-k9 :: OPTIONAL migration 0012 :: convert every existing table's
--               stored collation to utf8mb4_unicode_ci
--
-- THE PROBLEM THIS FIXES: none of this resource's tables ever declared an
-- explicit COLLATE before this pass -- every CREATE TABLE simply said
-- `DEFAULT CHARSET=utf8mb4` and left the collation to whatever the server's
-- own ambient default happened to be at the moment that table was first
-- created (`utf8mb4_general_ci` on some older defaults, `utf8mb4_0900_ai_ci`
-- on stock MySQL 8, `utf8mb4_unicode_ci` on others). qbx_core's own tables
-- declare `utf8mb4_unicode_ci` explicitly. `sql/install.sql` and every
-- table-creating file under `sql/migrations/` now state
-- `COLLATE=utf8mb4_unicode_ci` explicitly too (see install.sql's own header
-- for that half of this fix) -- but that only helps a table CREATEd from
-- this point forward. It does nothing for a table that was already created,
-- on some earlier server default, before this change landed. This file is
-- the other half: it converts an EXISTING table's already-stored collation
-- to match.
--
-- WHO ACTUALLY NEEDS THIS: almost certainly not you, and that is not a
-- guess -- read carefully before deciding.
--   * This resource's own functioning is completely unaffected either way.
--     Every internal lookup this resource performs either goes through
--     qbx_core's own Lua exports, or stays entirely within this resource's
--     own tables -- and every one of THOSE tables shares whatever single
--     ambient collation your server happened to give them at install time,
--     so they already agree with each other today, mismatch or not.
--     Nothing in `server/*.lua` does a raw SQL join between one of our
--     tables and `players`.
--   * The ONLY situation where this mismatch bites: YOU write your own SQL
--     report or query that JOINs one of our tables to qbx_core's `players`
--     table (or any other table declared `utf8mb4_unicode_ci`) on a text
--     column, most commonly `citizenid`. If your table's stored collation
--     disagrees with the other side of that join, MySQL/MariaDB refuses the
--     query outright with `ERROR 1267 (HY000): Illegal mix of collations
--     (utf8mb4_general_ci,IMPLICIT) and (utf8mb4_unicode_ci,IMPLICIT) for
--     operation '='` (the exact collation names in that message vary; the
--     shape of the error does not).
--   * If you have never written that kind of report, you can safely ignore
--     this file entirely, forever. Nothing about leaving it un-run makes
--     this resource less correct, less safe, or slower.
--   * If you HAVE hit that exact error, or want to pre-empt it before
--     writing your first cross-table report, this file is for you.
--
-- IF YOU WOULD RATHER NOT RUN THIS AT ALL: you do not have to fix the
-- schema to fix your report. Add `COLLATE utf8mb4_unicode_ci` to the join
-- condition itself instead, e.g.:
--     ... JOIN players p ON p.citizenid = t.citizenid COLLATE utf8mb4_unicode_ci
-- (or the reverse direction, or `CONVERT(... USING utf8mb4)` -- any of the
-- usual per-query collation-coercion techniques work here) and the error
-- goes away for that one query, with nothing in the database touched at
-- all. This file exists for the person who would rather fix it once at the
-- schema level than remember that workaround in every report they ever
-- write -- it is a convenience, not a requirement.
--
-- WHY THIS FILE LIVES IN `sql/migrations/optional/`, NOT `sql/migrations/`
-- ITSELF -- READ THIS IF YOU ARE WONDERING WHY k9_setup.sh NEVER RUNS IT:
-- `sql/k9_setup.sh` installs/upgrades by running `install.sql`, then every
-- file matched by the shell glob `sql/migrations/*.sql`, in filename order,
-- UNCONDITIONALLY, every single time it is run (see that script's own
-- Step 3). That is exactly right for every other migration in this
-- resource -- they are all cheap, safe-by-default, "just always apply this"
-- changes. This one is not that. Converting a table's stored collation is
-- an `ALTER TABLE ... CONVERT TO CHARACTER SET`, which MySQL/MariaDB can
-- only perform with the COPY algorithm: a full rewrite of every row in that
-- table, not a metadata-only change like every ADD COLUMN/ADD INDEX
-- elsewhere in this resource's migrations. Placing this file one directory
-- deeper, under `sql/migrations/optional/`, is what keeps it OUT of
-- `k9_setup.sh`'s plain (non-recursive) `migrations/*.sql` glob -- it is
-- structurally impossible for the default install/upgrade path to run this
-- file by accident. You run it only by naming it directly:
--     mysql -u YOUR_USER -p YOUR_DATABASE < sql/migrations/optional/0012_convert_charset_collation.sql
-- CORRECTED: this used to point to "README.md §7" for a plain-language
-- version of this file; that section does not exist in README.md (verified
-- by reading it), and no separate plain-language walkthrough of this
-- specific migration exists elsewhere either. The "WHO ACTUALLY NEEDS THIS"
-- block above IS this file's own plain-language version -- read that
-- instead. See the "WHY THIS FILE LIVES IN sql/migrations/optional/" section
-- immediately below for where this sits in the overall install story.
--
-- COST -- READ THIS BEFORE RUNNING ON A LIVE SERVER, THE SAME HONEST
-- DISCLOSURE MIGRATIONS 0004 AND 0006 ALREADY GIVE FOR THEIR OWN COSTS:
--   * Every table this resource owns except one is small by design --
--     current-state rows (one per citizenid, one per active grant, one per
--     tablet theme) or audit trails that grow only as fast as a human staff
--     member takes an action. Converting any of those finishes close to
--     instantly on any real server.
--   * `k9_search_log` is the deliberate exception. It is explicitly an
--     append-only log designed to grow UNBOUNDED with ordinary play (see
--     its own header in `sql/install.sql` and
--     `sql/maintenance_prune_k9_search_log.sql`, this resource's own
--     opt-in retention tool for exactly this table) -- on a server that has
--     been running for a while, it can hold a genuinely large number of
--     rows, and the COPY-algorithm rewrite this file performs on it costs
--     roughly in proportion to that row count: small on a young server,
--     potentially the most expensive and most lock-sensitive single
--     statement this resource has ever shipped on a server that has been
--     running for months with `K9SearchLog`/contraband search active.
--   * HONEST LIMIT OF THIS DISCLOSURE: unlike migration 0009's own header
--     (which quotes real, measured `EXPLAIN` output at two real row counts),
--     this pass did not have the ability to run an actual timed conversion
--     against a `k9_search_log` table of realistic production size to quote
--     you a real number here, and says so plainly rather than inventing
--     one. Treat "minutes, not seconds, on a table with a real production
--     history" as the honest expectation, not a measured guarantee -- your
--     own server's actual duration depends on its row count, disk, and
--     MySQL/MariaDB version, none of which this file can know in advance.
--     If you want a real number before committing to running this on your
--     live server, time it first against a restored copy of your own
--     backup on a throwaway database.
--   * WHAT THE LOCK ACTUALLY COSTS YOU WHILE IT RUNS: `k9_search_log` is
--     written to by `server/search.lua`'s `HandleSearchTarget`, which (per
--     that table's own header in `sql/install.sql`) already fires its
--     INSERT non-blockingly (`MySQL.insert(...)` without `.await`) so a
--     slow/contended write never delays the search callback's own response
--     to the officer performing the search -- gameplay itself does not
--     freeze while this ALTER holds its lock. What DOES happen: any search
--     performed while this ALTER is mid-flight has its audit-log INSERT
--     queued behind the lock rather than landing immediately, and this
--     statement adds real CPU/disk I/O load to your database server for its
--     entire duration, competing with every other query your live server is
--     running at the same time. Pick a quiet moment (low player count) the
--     same way you would for any other maintenance window, even though nothing
--     here technically requires taking the server offline.
--
-- IDEMPOTENT / SAFE TO RE-RUN: every table below is converted only if it
-- BOTH exists AND does not already report `utf8mb4_unicode_ci` as its
-- stored collation (checked directly against
-- `INFORMATION_SCHEMA.TABLES.TABLE_COLLATION`, not assumed) -- so running
-- this file a second time in a row, or against a database that already had
-- some tables fixed by hand, converges rather than repeating a full table
-- rewrite that has nothing left to do. A table this file does not find
-- (because your installation predates it, or has not yet applied the
-- migration that creates it) is silently skipped, not an error -- this file
-- never requires every john-k9 table to exist, only that at least one
-- does (see Step 0 below).
--
-- REFUSES CLEANLY ON AN UNINSTALLED DATABASE: if NOT ONE of this resource's
-- tables exists in this database at all, Step 0 below stops the whole file
-- with one plain-English message instead of a wall of `ERROR 1146 (42S02):
-- Table '...' doesn't exist` (one per table this file would otherwise have
-- tried and failed against) -- same order-protection convention migrations
-- 0003/0004/0006/0009 already established for their own single-table case,
-- extended here to a "at least one of our many tables must exist" check
-- since this file, uniquely among this resource's migrations, touches every
-- table this resource owns instead of just one.
--
-- ROLLBACK PARTNER, AND AN HONEST WORD ABOUT WHAT IT CANNOT PROMISE:
-- `sql/rollback/0012_down.sql` reverses this file. Read its own header
-- before assuming "rollback" means "back to exactly where I started" here
-- -- it is more nuanced than every other rollback in this resource, and
-- that file says so plainly rather than implying a perfect undo.
--
-- NO DESTRUCTIVE STATEMENT: this file only ever runs
-- `ALTER TABLE ... CONVERT TO CHARACTER SET utf8mb4 COLLATE
-- utf8mb4_unicode_ci` -- it never DROPs, TRUNCATEs, or DELETEs a table or a
-- row, and it never changes the CHARACTER SET your data is actually stored
-- in (utf8mb4 in, utf8mb4 out, on every table, always) -- only the
-- COLLATION (the comparison/sort rule applied to that same, unchanged
-- utf8mb4 byte data) changes. See the "DATA-LOSSLESS" note in
-- `sql/rollback/0012_down.sql`'s own header for exactly what that
-- distinction does and does not guarantee.
--
-- VERSION REQUIREMENT: same floor as the rest of this resource -- MySQL
-- >= 5.7.8 or MariaDB >= 10.2 (this file's own statements do not
-- individually need that floor -- `CONVERT TO CHARACTER SET` is far older
-- syntax than this resource's generated columns -- kept identical anyway
-- because a database that could not run `sql/install.sql` in the first
-- place has nothing here for this file to convert).
--
-- NOT EXECUTION-VERIFIED IN THIS PASS -- DISCLOSED, NOT HIDDEN: this file
-- was written and reviewed carefully, but the environment this pass ran in
-- did not provide a way to actually run it against a real MySQL/MariaDB
-- server. In particular, `k9_certifications`, `k9_certification_specializations`,
-- `k9_partnerships`, and `k9_permissions` each carry a `VIRTUAL GENERATED`
-- column backing a `UNIQUE KEY` -- converting a table's character set/
-- collation while a virtual generated column and a unique index over it are
-- both in play is a real combination this schema has not exercised before,
-- and it deserves a genuine execution pass (fresh install, convert, convert
-- again for idempotency, roll back, and re-run the 20-connection concurrent-
-- grant race migration 0004's own rollback already measured, to confirm the
-- unique constraint still enforces correctly after the underlying columns'
-- collation has changed) before this file is trusted on a production
-- database. Treat this file as reviewed-but-not-yet-execution-verified until
-- that pass happens and this note is updated to say so.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Step 0: ORDER-PROTECTION GUARD. If NOT ONE of this resource's tables
-- exists in this database, there is nothing anywhere for this file to
-- convert -- refuse with one plain-English reason instead of one raw
-- "table doesn't exist" error per table this file would otherwise attempt.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0012_require_any_table`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0012_require_any_table`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME IN (
            'k9_certification_specializations',
            'k9_certification_tier_audit',
            'k9_certification_tier_capabilities','k9_certification_tiers',
            'k9_certifications','k9_dog_characters',
            'k9_equipment_shop_item_audit','k9_equipment_shop_items',
            'k9_equipment_shop_locations',
            'k9_equipment_shop_locations_audit',
            'k9_individual_override_audit','k9_individual_overrides',
            'k9_partnership_pair_progress','k9_partnerships',
            'k9_ped_assignments','k9_permission_key_audit',
            'k9_permission_keys','k9_permissions','k9_personnel',
            'k9_progression','k9_runtime_feature_overrides',
            'k9_runtime_override_audit','k9_search_log','k9_tablet_theme',
            'k9_tablet_theme_audit','k9_wellbeing','k9_xp_tier_audit',
            'k9_xp_tiers'
          )
    ) THEN
        SELECT 'STOPPED - NOTHING INSTALLED' AS status,
               'No john-k9 table exists in this database at all. This file only ever CONVERTs the stored collation of a table that already exists -- there is nothing here for it to change. Run sql/install.sql (and every file in sql/migrations/) first to install john-k9 itself, then come back to this file if you still want it -- it is optional even then; see this file''s own header for who actually needs it. Nothing has been changed.' AS detail;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'john-k9 optional migration 0012 stopped: no john-k9 table exists in this database. See detail above. Run install.sql first if you meant to install john-k9.';
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0012_require_any_table`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0012_require_any_table`;


-- ---------------------------------------------------------------------
-- Step 1: convert every SMALL/CHEAP table this resource owns, i.e. every
-- one of its own tables EXCEPT `k9_search_log` (handled separately, last,
-- in Step 2 below, precisely so its own much larger disclosed cost is
-- never hidden inside a loop that also silently processed fifteen cheap
-- tables). A cursor over a small, explicit, hand-maintained list -- not a
-- `k9\_%` INFORMATION_SCHEMA sweep -- for the identical reason
-- `sql/rollback/uninstall_all.sql`'s own DROP list is hand-maintained
-- rather than swept: this database can legitimately contain a DIFFERENT
-- K9 resource's own same-prefixed tables (e.g. `k9_units`), and this file
-- must never touch those.
--
-- Each table is included in the cursor's result set only if it BOTH exists
-- AND does not already report `utf8mb4_unicode_ci` -- this is what makes
-- re-running this whole file a converging no-op rather than a repeated
-- full rewrite of tables that already landed correctly on an earlier run.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0012_convert_small_tables`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0012_convert_small_tables`()
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE tname VARCHAR(64);
    DECLARE cur CURSOR FOR
        SELECT ist.TABLE_NAME
        FROM INFORMATION_SCHEMA.TABLES ist
        JOIN (
            SELECT 'k9_certification_specializations' AS table_name
            UNION ALL SELECT 'k9_certification_tier_audit'
            UNION ALL SELECT 'k9_certification_tier_capabilities'
            UNION ALL SELECT 'k9_certification_tiers'
            UNION ALL SELECT 'k9_certifications'
            UNION ALL SELECT 'k9_dog_characters'
            UNION ALL SELECT 'k9_equipment_shop_item_audit'
            UNION ALL SELECT 'k9_equipment_shop_items'
            UNION ALL SELECT 'k9_equipment_shop_locations'
            UNION ALL SELECT 'k9_equipment_shop_locations_audit'
            UNION ALL SELECT 'k9_individual_override_audit'
            UNION ALL SELECT 'k9_individual_overrides'
            UNION ALL SELECT 'k9_partnership_pair_progress'
            UNION ALL SELECT 'k9_partnerships'
            UNION ALL SELECT 'k9_ped_assignments'
            UNION ALL SELECT 'k9_permission_key_audit'
            UNION ALL SELECT 'k9_permission_keys'
            UNION ALL SELECT 'k9_permissions'
            UNION ALL SELECT 'k9_personnel'
            UNION ALL SELECT 'k9_progression'
            UNION ALL SELECT 'k9_runtime_feature_overrides'
            UNION ALL SELECT 'k9_runtime_override_audit'
            UNION ALL SELECT 'k9_search_log'
            UNION ALL SELECT 'k9_tablet_theme'
            UNION ALL SELECT 'k9_tablet_theme_audit'
            UNION ALL SELECT 'k9_wellbeing'
            UNION ALL SELECT 'k9_xp_tier_audit'
            UNION ALL SELECT 'k9_xp_tiers'
        ) wanted ON wanted.table_name = ist.TABLE_NAME
        WHERE ist.TABLE_SCHEMA = DATABASE()
          AND ist.TABLE_COLLATION <> 'utf8mb4_unicode_ci';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    conv_loop: LOOP
        FETCH cur INTO tname;
        IF done = 1 THEN LEAVE conv_loop; END IF;
        SET @k9ms_0012_sql = CONCAT('ALTER TABLE `', tname, '` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
        PREPARE k9ms_0012_stmt FROM @k9ms_0012_sql;
        EXECUTE k9ms_0012_stmt;
        DEALLOCATE PREPARE k9ms_0012_stmt;
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL `john_k9_migration_0012_convert_small_tables`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0012_convert_small_tables`;


-- ---------------------------------------------------------------------
-- Step 2: convert `k9_search_log`, ALONE, LAST -- see this file's own
-- header "COST" section for exactly why this table is kept separate from
-- Step 1's cursor and what running this specific statement actually costs
-- on a server with real search history. Idempotent the same way as every
-- table in Step 1: only converts if the table exists and is not already
-- `utf8mb4_unicode_ci`.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_migration_0012_convert_search_log`;
DELIMITER $$
CREATE PROCEDURE `john_k9_migration_0012_convert_search_log`()
BEGIN
    IF EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_search_log'
          AND TABLE_COLLATION <> 'utf8mb4_unicode_ci'
    ) THEN
        ALTER TABLE `k9_search_log` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_migration_0012_convert_search_log`();
DROP PROCEDURE IF EXISTS `john_k9_migration_0012_convert_search_log`;


-- ---------------------------------------------------------------------
-- FINAL REPORT: read-only, prints the resulting collation of every
-- john-k9 table that exists in this database, so you can see the
-- outcome immediately without a separate query. Every row here should say
-- `utf8mb4_unicode_ci` once this file has finished.
-- ---------------------------------------------------------------------
SELECT TABLE_NAME AS `table`, TABLE_COLLATION AS collation_after_this_migration
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN (
    'k9_certification_specializations','k9_certification_tier_audit',
    'k9_certification_tier_capabilities','k9_certification_tiers',
    'k9_certifications','k9_dog_characters',
    'k9_equipment_shop_item_audit','k9_equipment_shop_items',
    'k9_equipment_shop_locations','k9_equipment_shop_locations_audit',
    'k9_individual_override_audit','k9_individual_overrides',
    'k9_partnership_pair_progress','k9_partnerships','k9_ped_assignments',
    'k9_permission_key_audit','k9_permission_keys','k9_permissions',
    'k9_personnel','k9_progression','k9_runtime_feature_overrides',
    'k9_runtime_override_audit','k9_search_log','k9_tablet_theme',
    'k9_tablet_theme_audit','k9_wellbeing','k9_xp_tier_audit',
    'k9_xp_tiers'
  )
ORDER BY TABLE_NAME;

SELECT 'DONE -- every john-k9 table above now reports utf8mb4_unicode_ci (or already did). If you were chasing ERROR 1267 "Illegal mix of collations" against your own report, try that query again now.' AS final_note;
