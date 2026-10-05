-- =====================================================================
-- john-k9 :: ROLLBACK 0007 :: k9_runtime_feature_overrides /
--                                 k9_runtime_override_audit /
--                                 k9_tablet_theme / k9_tablet_theme_audit
--
-- Would reverse:
--   sql/migrations/0007_create_k9_runtime_control.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0001_down.sql/
-- 0002_down.sql/0005_down.sql, same reason. It is not unfinished.
--
-- Migration 0007 does exactly four things: CREATE TABLE x4. Undoing a
-- CREATE TABLE means DROPping it, which deletes every row. For these four
-- tables specifically:
--
--   * k9_runtime_feature_overrides holds every CURRENTLY ACTIVE runtime
--     override -- every feature high command has switched on/off, and
--     every tuning value high command has changed, that differs from
--     config.lua's own shipped default RIGHT NOW. Dropping it does not
--     just lose history: server/runtimecontrol.lua re-applies every row
--     in this table on top of config.lua's defaults at its own file-load
--     time (this is precisely what makes an override survive a restart,
--     per the owner's own explicit requirement), so dropping this table
--     and restarting the resource SILENTLY REVERTS every live override to
--     its config.lua default with no warning -- a genuine behavior change
--     to a live server, not merely an audit-trail loss.
--   * k9_runtime_override_audit is the full "who changed what, from what,
--     to what" trail the owner explicitly asked for, for every override
--     ever set or reset. Not recomputable from any other table --
--     k9_runtime_feature_overrides only ever holds the CURRENT value, not
--     the history of how it got there.
--   * k9_tablet_theme holds the CURRENT tablet theme every connected
--     player's tablet renders. Dropping it does not just lose history:
--     the next read falls back to server/runtimecontrol.lua's own
--     hardcoded default theme, silently discarding whatever high command
--     last configured, on every server this resource is installed on.
--   * k9_tablet_theme_audit is the full history of every theme change
--     ever made, as a full snapshot per change. Not recomputable from
--     k9_tablet_theme, which only ever holds the current one.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert
-- until you personally arm it. You cannot lose your data by running the
-- wrong rollback file.
--
-- WHAT TO DO INSTEAD:
--   * Just want runtime overrides to stop being possible from the tablet?
--     Set `Config.Features.RuntimeFeatureControl = false` and leave both
--     tables alone -- server/runtimecontrol.lua's own callbacks re-check
--     that flag on every call and refuse (see that file's own header),
--     and every override already stored in k9_runtime_feature_overrides
--     stays exactly as it is, ready to keep applying (RuntimeFeatureControl
--     being off does NOT stop config.lua's live values from being what
--     they currently are -- it only stops FURTHER changes) or to resume
--     being tunable the moment the flag is turned back on.
--   * Just want tablet theming to stop being editable? Set
--     `Config.Features.TabletTheming = false` the same way -- the current
--     theme keeps rendering for everyone (this table is still read even
--     with the feature off, per that file's own "cosmetic state persists
--     independent of whether it can currently be CHANGED" contract), it
--     just can no longer be changed until the flag is back on.
--   * Genuinely want one or more of these four tables gone? Run
--     sql/rollback/backup_k9_tables.sh FIRST (README.md's "Uninstalling /
--     rolling back" section -- report to the sql/** owner that these four table names need
--     adding to that script's own table list and to
--     sql/rollback/uninstall_all.sql, neither of which this file edits),
--     then arm and run sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own tables do not individually need that floor -- see
-- migration 0007's own header -- but every other table in this schema
-- already does, so a database that could apply 0007 in the first place
-- already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0007_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0007_report`()
BEGIN
    DECLARE overrides_exists INT DEFAULT 0;
    DECLARE override_audit_exists INT DEFAULT 0;
    DECLARE theme_exists INT DEFAULT 0;
    DECLARE theme_audit_exists INT DEFAULT 0;

    DECLARE override_rows BIGINT DEFAULT 0;
    DECLARE override_audit_rows BIGINT DEFAULT 0;
    DECLARE theme_rows BIGINT DEFAULT 0;
    DECLARE theme_audit_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO overrides_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_runtime_feature_overrides';
    SELECT COUNT(*) INTO override_audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_runtime_override_audit';
    SELECT COUNT(*) INTO theme_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_tablet_theme';
    SELECT COUNT(*) INTO theme_audit_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_tablet_theme_audit';

    IF overrides_exists = 0 AND override_audit_exists = 0 AND theme_exists = 0 AND theme_audit_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'None of the four migration-0007 tables exist in this database. Migration 0007 was either never applied here, or all four have already been removed.' AS detail;
    ELSE
        IF overrides_exists = 1 THEN SELECT COUNT(*) INTO override_rows FROM `k9_runtime_feature_overrides`; END IF;
        IF override_audit_exists = 1 THEN SELECT COUNT(*) INTO override_audit_rows FROM `k9_runtime_override_audit`; END IF;
        IF theme_exists = 1 THEN SELECT COUNT(*) INTO theme_rows FROM `k9_tablet_theme`; END IF;
        IF theme_audit_exists = 1 THEN SELECT COUNT(*) INTO theme_audit_rows FROM `k9_tablet_theme_audit`; END IF;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               overrides_exists AS k9_runtime_feature_overrides_present,
               override_rows AS active_overrides_this_would_silently_revert_on_next_restart,
               override_audit_exists AS k9_runtime_override_audit_present,
               override_audit_rows AS audit_rows_this_would_destroy,
               theme_exists AS k9_tablet_theme_present,
               theme_rows AS theme_rows_this_would_destroy,
               theme_audit_exists AS k9_tablet_theme_audit_present,
               theme_audit_rows AS theme_audit_rows_this_would_destroy,
               'This script never drops a table. See this file''s own header for exactly what each table costs to lose and what to do instead (usually: flip the relevant Config.Features flag off, not drop the table). To remove these tables anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0007_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0007_report`;

-- HOUSEKEEPING: migration 0007 defines no stored procedure of its own
-- (every statement in it is a bare CREATE TABLE IF NOT EXISTS) -- nothing
-- of 0007's own to sweep here, unlike 0004/0006's housekeeping blocks.
-- This file's own reporting procedure is already dropped immediately above.
