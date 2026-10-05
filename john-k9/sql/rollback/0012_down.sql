-- =====================================================================
-- john-k9 :: ROLLBACK 0012 :: convert every john-k9 table's stored
--                                 collation back away from
--                                 utf8mb4_unicode_ci
--
-- Reverses:
--   sql/migrations/optional/0012_convert_charset_collation.sql
--
-- READ THIS FIRST -- WHAT "ROLLBACK" DOES AND DOES NOT MEAN HERE. Every
-- other rollback in this folder either restores a table to a shape it
-- provably had before (0004_down, 0006_down: drop a derived
-- column/index that stored no independent data) or is explicit up front
-- about exactly which values it cannot bring back (0003_down: the
-- `tenure_bonus_tier_granted` column's actual values). This one needs the
-- same honesty, in a slightly different shape:
--
--   * DATA-LOSSLESS, GENUINELY: this file changes ONLY the COLLATION
--     (the comparison/sort rule) of each table's text columns, never the
--     CHARACTER SET (the actual byte encoding your text is stored in) --
--     that was utf8mb4 before migration 0012 ran, stayed utf8mb4 the whole
--     time migration 0012 was applied, and stays utf8mb4 here too, on
--     every table, always. Two collations over the SAME character set
--     read and write the exact same bytes for the exact same characters;
--     only how those bytes SORT and COMPARE differs. No character, no
--     row, no column value is altered, truncated, or reinterpreted by
--     running this file. If you are worried this rollback could mangle
--     emoji, accented names, or any other real player-typed text: it
--     cannot -- that risk exists for a genuine charset change (e.g.
--     utf8mb4 -> latin1), which this file does not perform in either
--     direction.
--
--   * NOT HISTORY-LOSSLESS, AND THIS FILE DOES NOT PRETEND OTHERWISE:
--     migration 0012 never recorded what EACH table's individual
--     collation was before it ran -- it could have been
--     `utf8mb4_general_ci`, `utf8mb4_0900_ai_ci`, or something else
--     again, and could genuinely have differed table-to-table if your
--     tables were created at different times against different server
--     defaults (see migration 0012's own header for exactly how that
--     happens). This file cannot restore a value it was never given.
--     What it does instead is convert every table back to a single,
--     explicitly named, disclosed stand-in collation --
--     `utf8mb4_general_ci`, chosen because it is a genuinely common
--     pre-fix ambient default in this project's own supported server
--     range, not because it is provably what YOUR database had. Read
--     that as "get back to an ambiguous, ambient-default-shaped state,
--     on purpose, using one concrete name instead of a hand-wave," not
--     as "restore my exact original setup." If you need your database's
--     LITERAL original per-table collation back, restore from the backup
--     taken before you ever ran migration 0012 (sql/k9_setup.sh's own
--     mandatory full-database backup step if you used that script, or
--     sql/rollback/backup_full_database.sh if you ran this migration by
--     hand) -- that backup is the only place your original, specific values
--     genuinely still exist.
--
-- WHY YOU WOULD EVER WANT THIS AT ALL: migration 0012 is optional in the
-- first place (see its own header -- most installs never need it). If you
-- ran it and then decided you didn't want the schema-level change after
-- all -- for example, you'd rather use the one-line per-query `COLLATE`
-- workaround its own header also documents, or you hit an unexpected
-- interaction and want to get back to your prior state while you
-- investigate -- this file gets you unstuck the same way `0004_down.sql`
-- gets an operator unstuck from a bad `uq_one_active_cert_per_job`
-- rollout: reverse the schema change, decide what you actually want, then
-- either leave it reversed or re-run
-- `sql/migrations/optional/0012_convert_charset_collation.sql` to put it
-- back.
--
-- ⚠️ RUNNING THIS PUTS YOU BACK WHERE THE ORIGINAL PROBLEM LIVED. If the
-- reason you ran migration 0012 in the first place was a real
-- `ERROR 1267: Illegal mix of collations` in one of your own reports
-- joining a john-k9 table to qbx_core's `players` table, running this
-- file brings that exact error back for that same report. That is
-- expected, not a bug in this file -- it is what "rollback" means here.
--
-- COST: identical in kind to migration 0012's own -- this is the same
-- `ALTER TABLE ... CONVERT TO CHARACTER SET`, just to a different named
-- collation, so it is the same COPY-algorithm full table rewrite, at the
-- same cost, with the same `k9_search_log`-is-the-expensive-one shape.
-- Read migration 0012's own header "COST" section in full before running
-- this on a live server with real search history; it is not repeated a
-- second time here.
--
-- IDEMPOTENT / SAFE TO RE-RUN: exactly the same convergence design as the
-- forward migration -- each table is only touched if it exists and does
-- not already report `utf8mb4_general_ci`. Running this file twice in a
-- row does one real rewrite pass, then a clean no-op.
--
-- SAFE AGAINST AN UNINSTALLED DATABASE WITHOUT A SEPARATE GUARD: unlike
-- the forward migration, this file needs no explicit "Step 0" refusal --
-- every table this file touches is gated by its own `IF ... TABLE_NAME =
-- ... AND TABLE_COLLATION <> ...` check inside
-- `INFORMATION_SCHEMA.TABLES`, which simply returns no rows (a silent,
-- harmless no-op) for a table that does not exist, the same pattern
-- `0004_down.sql`'s own `IF EXISTS` guards already rely on. Running this
-- against a database with no john-k9 tables at all does nothing and
-- reports nothing changed.
--
-- NO DESTRUCTIVE STATEMENT: only ever `ALTER TABLE ... CONVERT TO
-- CHARACTER SET`; never DROPs, TRUNCATEs, or DELETEs a table or a row.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching every other file in
-- this resource (this file's own statements do not individually need that
-- floor).
--
-- NOT EXECUTION-VERIFIED IN THIS PASS -- see migration 0012's own header
-- for the same disclosure applied to this file's identical
-- generated-column/unique-key interaction risk; it is not repeated a
-- second time here.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1 of 2: convert every table this resource owns EXCEPT
-- `k9_search_log` back to `utf8mb4_general_ci`, via the same cursor +
-- dynamic-SQL pattern the forward migration uses, for the identical
-- "hand-maintained list, not a `k9\_%` sweep" reasoning given in that
-- file's own header (this database can legitimately contain a different
-- K9 resource's own same-prefixed tables, e.g. `k9_units`, which this
-- file must never touch).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0012_revert_small_tables`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0012_revert_small_tables`()
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
          AND ist.TABLE_COLLATION <> 'utf8mb4_general_ci';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    rev_loop: LOOP
        FETCH cur INTO tname;
        IF done = 1 THEN LEAVE rev_loop; END IF;
        SET @k9ms_0012d_sql = CONCAT('ALTER TABLE `', tname, '` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci');
        PREPARE k9ms_0012d_stmt FROM @k9ms_0012d_sql;
        EXECUTE k9ms_0012d_stmt;
        DEALLOCATE PREPARE k9ms_0012d_stmt;
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL `john_k9_rollback_0012_revert_small_tables`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0012_revert_small_tables`;


-- ---------------------------------------------------------------------
-- STEP 2 of 2: `k9_search_log`, alone, last -- same reason the forward
-- migration keeps it separate: its cost is disclosed on its own, never
-- hidden inside a loop that also silently processed every cheap table.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `john_k9_rollback_0012_revert_search_log`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0012_revert_search_log`()
BEGIN
    IF EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'k9_search_log'
          AND TABLE_COLLATION <> 'utf8mb4_general_ci'
    ) THEN
        ALTER TABLE `k9_search_log` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0012_revert_search_log`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0012_revert_search_log`;


-- ---------------------------------------------------------------------
-- FINAL REPORT: same shape as the forward migration's own -- read-only,
-- prints the resulting collation of every john-k9 table that exists.
-- ---------------------------------------------------------------------
SELECT TABLE_NAME AS `table`, TABLE_COLLATION AS collation_after_this_rollback
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

SELECT 'DONE -- every john-k9 table above now reports utf8mb4_general_ci (or already did). This is a named stand-in, not a restoration of your literal original per-table collation -- see this file''s own header. Re-run sql/migrations/optional/0012_convert_charset_collation.sql at any time to put utf8mb4_unicode_ci back.' AS final_note;
