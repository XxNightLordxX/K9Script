-- =====================================================================
-- john-k9 :: ROLLBACK 0019 :: k9_dog_characters
--
-- Would reverse:
--   sql/migrations/0019_create_k9_dog_characters.sql
--
-- ///////////////////////////////////////////////////////////////////////
-- THIS SCRIPT DELIBERATELY DOES NOTHING -- same design as 0007_down.sql/
-- 0008_down.sql/0011_down.sql/0013_down.sql/0015_down.sql/0016_down.sql/
-- 0018_down.sql/0020_down.sql, same reason. It is not unfinished.
--
-- THIS FILE WAS MISSING UNTIL NOW, AND THAT WAS THE WHOLE BUG. Every
-- other applied migration in this directory has a matching `000N_down.sql`
-- and README.md's uninstall section tells you plainly: "Want to undo one
-- specific migration? Run the matching sql/rollback/000N_down.sql." For
-- migration 19 that file simply did not exist, so anyone who followed that
-- instruction got a bare "no such file" from their shell with nothing
-- explaining why this one number was different from all the others. (The
-- one legitimately-absent number is 0012, which lives in
-- sql/migrations/optional/ and is explained in sql/DATABASE_GUIDE.md --
-- 0019 had no such explanation anywhere.)
--
-- Migration 0019 does exactly one thing: CREATE TABLE. Undoing a CREATE
-- TABLE means DROPping it, which deletes every row. This table holds the
-- PIN that says "this character IS a dog until an admin says otherwise" --
-- the explicit, admin-set fact, deliberately separate from the ordinary
-- certification-driven appearance that server/appearance.lua already
-- unwinds by itself when a credential is lost.
--
-- WHAT DROPPING IT WOULD ACTUALLY COST: every pinned dog character would
-- stop being pinned. They would not break, and they would not be stuck as
-- dogs -- they would simply revert to being ordinary characters whose
-- appearance follows their certification like everybody else's, at their
-- next appearance evaluation. Nobody's in-game abilities change either way:
-- this table has never been what decides whether a citizenid may act as a
-- K9, only whether their dog form is pinned in place. But the admin
-- decisions themselves would be gone, and each one would have to be re-made
-- by hand with /k9setdog, character by character.
--
-- No rollback script in this directory will ever drop a table. The one
-- destructive path is sql/rollback/uninstall_all.sql, which is inert until
-- you personally arm it. You cannot lose your data by running the wrong
-- rollback file.
--
-- WHAT TO DO INSTEAD: to un-pin one character, run /k9removedog on them --
-- that is what it is for, it takes seconds, and it leaves the audit trail
-- intact. There is no legitimate reason to want this table gone while the
-- feature is still installed. Genuinely uninstalling this resource
-- entirely? Run sql/rollback/backup_k9_tables.sh FIRST (README.md's
-- "Uninstalling / rolling back" section), then arm and run
-- sql/rollback/uninstall_all.sql.
--
-- Running this file is always harmless. It only READS, and changes
-- nothing. Re-run it as often as you like.
-- ///////////////////////////////////////////////////////////////////////
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql
-- (this migration's own table does not individually need that floor, but
-- every other table in this schema already does, so a database that could
-- apply 0019 in the first place already meets it).
-- =====================================================================

DROP PROCEDURE IF EXISTS `john_k9_rollback_0019_report`;
DELIMITER $$
CREATE PROCEDURE `john_k9_rollback_0019_report`()
BEGIN
    DECLARE dogchars_exists INT DEFAULT 0;
    DECLARE dogchars_rows BIGINT DEFAULT 0;
    DECLARE dogchars_active_rows BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO dogchars_exists FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'k9_dog_characters';

    IF dogchars_exists = 0 THEN
        SELECT 'NOTHING TO DO' AS status,
               'k9_dog_characters does not exist in this database. Migration 0019 was either never applied here, or has already been removed.' AS detail;
    ELSE
        SELECT COUNT(*) INTO dogchars_rows FROM `k9_dog_characters`;
        SELECT COUNT(*) INTO dogchars_active_rows FROM `k9_dog_characters` WHERE `active` = 1;

        SELECT 'NOTHING DONE - ON PURPOSE' AS status,
               dogchars_exists AS k9_dog_characters_present,
               dogchars_rows AS total_rows_ever_written,
               dogchars_active_rows AS currently_pinned_dog_characters_this_would_unpin,
               'This script never drops a table. See this file''s own header for exactly what dropping this table would cost. To un-pin one character, use /k9removedog instead. To remove the table anyway: run backup_k9_tables.sh first, then arm and run uninstall_all.sql.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `john_k9_rollback_0019_report`();
DROP PROCEDURE IF EXISTS `john_k9_rollback_0019_report`;

-- HOUSEKEEPING: migration 0019 defines no stored procedure of its own
-- (its only statement is a bare CREATE TABLE IF NOT EXISTS) -- nothing of
-- 0019's own to sweep here. This file's own reporting procedure is already
-- dropped immediately above.
