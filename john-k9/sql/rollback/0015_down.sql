-- =====================================================================
-- john-k9 :: ROLLBACK 0015 :: k9_xp_tiers / k9_xp_tier_audit
--
-- Would reverse:
--   sql/migrations/0015_create_k9_xp_tiers.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0007_down.sql/
-- 0008_down.sql/0011_down.sql/0013_down.sql before it, same reason. It is
-- not unfinished.
--
-- Migration 0015 does exactly two things: CREATE TABLE x2. Undoing a
-- CREATE TABLE means DROPping it, which deletes every row. For these two
-- tables specifically:
--
--   * k9_xp_tiers holds every high-command-edited field override for an
--     EXISTING XP rank (xp threshold, label, speed/scent multipliers, the
--     optional medkit-cooldown multiplier and badge), RIGHT NOW, on top of
--     whatever Config.XPTiers ships in config.lua. Dropping it does not
--     just lose history: server/xptiers.lua's own onResourceStart handler
--     re-reads this table on every resource start and mutates
--     Config.XPTiers back to config.lua's shipped defaults for any rank
--     with no row left here -- so dropping this table SILENTLY REVERTS
--     every edited rank's threshold/label/multipliers to config.lua's own
--     defaults on the NEXT restart, for every server this resource is
--     installed on, with no warning. A real behavior change to a live
--     server (every K9's real movement-speed/scent-range bonus for a
--     re-tuned rank snaps back to the shipped default the moment this
--     resource next restarts), not merely an audit-trail loss. Ranks that
--     were never edited from their config.lua default are completely
--     unaffected either way.
--   * k9_xp_tier_audit is the full "who changed which rank, and how"
--     trail. Not recomputable from k9_xp_tiers, which only ever holds
--     CURRENT field overrides, never the history of what a rank's values
--     used to be before an earlier edit.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want a specific rank's threshold/label/multipliers put back to
--     config.lua's own shipped default? Re-open the K9 Command Tablet's
--     XP-rank screen and edit that rank back to the values config.lua's
--     own Config.XPTiers comment documents -- no table needs to be
--     touched or dropped for this.
--   * Genuinely want one or both of these two tables gone? Run
--     sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
--     rolling back" section), then arm and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own tables do not individually need that floor -- see
-- migration 0015's own header -- but every other table in this schema
-- already does, so a database that could apply 0015 in the first place
-- already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0015_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0015_report`()
BEGIN
    DECLARE tiers_exists INT DEFAULT 0;
    DECLARE tiers_audit_exists INT DEFAULT 0;

    DECLARE tier_rows BIGINT DEFAULT 0;
    DECLARE tier_audit_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO tiers_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_xp_tiers';
    SELECT COUNT(*) INTO tiers_audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_xp_tier_audit';

    IF tiers_exists = 0 AND tiers_audit_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'Neither migration-0015 table exists in this database. Migration 0015 was either never applied here, or both have already been removed.' AS detail;
    ELSE
        IF tiers_exists = 1 THEN SELECT COUNT(*) INTO tier_rows FROM `k9_xp_tiers`; END IF;
        IF tiers_audit_exists = 1 THEN SELECT COUNT(*) INTO tier_audit_rows FROM `k9_xp_tier_audit`; END IF;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               tiers_exists AS k9_xp_tiers_present,
               tier_rows AS edited_rank_overrides_this_would_silently_revert,
               tiers_audit_exists AS k9_xp_tier_audit_present,
               tier_audit_rows AS audit_rows_this_would_destroy,
               'This script never drops a table. See this file''s own header for exactly what each table costs to lose and what to do instead (usually: leave the table alone, edit the rank back from the tablet instead). To remove these tables anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0015_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0015_report`;

-- HOUSEKEEPING: migration 0015 defines no stored procedure of its own
-- (every statement in it is a bare CREATE TABLE IF NOT EXISTS) -- nothing
-- of 0015's own to sweep here. This file's own reporting procedure is
-- already dropped immediately above.
