-- =====================================================================
-- john-k9 :: ROLLBACK 0011 :: k9_equipment_shop_locations /
--                                 k9_equipment_shop_locations_audit
--
-- Would reverse:
--   sql/migrations/0011_create_k9_equipment_shop_locations.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0007_down.sql/
-- 0008_down.sql before it, same reason. It is not unfinished.
--
-- Migration 0011 does exactly two things: CREATE TABLE x2. Undoing a
-- CREATE TABLE means DROPping it, which deletes every row. For these two
-- tables specifically:
--
--   * k9_equipment_shop_locations holds every shop location a high
--     command officer has added from the tablet, RIGHT NOW, on top of
--     whatever Config.K9EquipmentShop.locations ships in config.lua.
--     Dropping it does not just lose history: server/equipmentshop.lua's
--     own BuildEffectiveLocations reads this table fresh on every request
--     (and re-broadcasts it to every connected client on every mutation),
--     so dropping this table SILENTLY REMOVES every tablet-added shop
--     location, on every server this resource is installed on, with no
--     warning -- a real behavior change to a live server (players walk up
--     to where a shop used to be and find nothing there), not merely an
--     audit-trail loss. Locations that live in config.lua itself are
--     completely unaffected either way -- see migration 0011's own header
--     "SCOPE" section for why this table never touches those.
--   * k9_equipment_shop_locations_audit is the full "who added/moved/
--     removed which location, and what it looked like" trail. Not
--     recomputable from k9_equipment_shop_locations, which only ever holds
--     CURRENT locations, never the history of ones that were later moved
--     or removed.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want tablet-driven location edits to stop being possible?
--     Set `Config.Features.K9EquipmentShop = false` (turns the whole shop
--     off, tablet editing included), or -- once the tablet screen for this
--     ships -- whatever more targeted flag that screen's own owner wires
--     up. Either way, leave this table alone: nothing here needs to be
--     dropped to stop further edits, and every location already added
--     stays intact, ready to resume working the moment editing is
--     re-enabled.
--   * Genuinely want one or both of these two tables gone? Run
--     sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
--     rolling back" section -- as of the db-schema pass on 2026-08-26, both of these table
--     names are included in that script's own table list and in
--     sql/rollback/uninstall_all.sql's DROP list, FK-blocker gate, and
--     dependency report; neither is edited by this file itself), then arm
--     and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own tables do not individually need that floor -- see
-- migration 0011's own header -- but every other table in this schema
-- already does, so a database that could apply 0011 in the first place
-- already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0011_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0011_report`()
BEGIN
    DECLARE locations_exists INT DEFAULT 0;
    DECLARE locations_audit_exists INT DEFAULT 0;

    DECLARE location_rows BIGINT DEFAULT 0;
    DECLARE location_audit_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO locations_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_equipment_shop_locations';
    SELECT COUNT(*) INTO locations_audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_equipment_shop_locations_audit';

    IF locations_exists = 0 AND locations_audit_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Neither migration-0011 table exists in this database. Migration 0011 was either never applied here, or both have already been removed.' AS detail;
    ELSE
        IF locations_exists = 1 THEN SELECT COUNT(*) INTO location_rows FROM `k9_equipment_shop_locations`; END IF;
        IF locations_audit_exists = 1 THEN SELECT COUNT(*) INTO location_audit_rows FROM `k9_equipment_shop_locations_audit`; END IF;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               locations_exists AS k9_equipment_shop_locations_present,
               location_rows AS tablet_added_shop_locations_this_would_silently_remove,
               locations_audit_exists AS k9_equipment_shop_locations_audit_present,
               location_audit_rows AS audit_rows_this_would_destroy,
               'This script never drops a table. See this file''s own header for exactly what each table costs to lose and what to do instead (usually: leave the table alone, gate further edits with a Config.Features flag instead). To remove these tables anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0011_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0011_report`;

-- HOUSEKEEPING: migration 0011 defines no stored procedure of its own
-- (every statement in it is a bare CREATE TABLE IF NOT EXISTS) -- nothing
-- of 0011's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
