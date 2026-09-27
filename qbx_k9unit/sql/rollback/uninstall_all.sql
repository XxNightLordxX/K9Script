-- =====================================================================
-- qbx_k9unit :: FULL UNINSTALL -- DROPS EVERY TABLE THIS RESOURCE OWNS
--
-- This header used to say "ALL SIX TABLES". It has said six for a long
-- time; the real number passed six, then eleven, migration 0010 took it to
-- fourteen, migration 0011 took it to sixteen, migration 0013 took it to
-- eighteen, migration 0014 took it to twenty, migration 0015 took it to
-- twenty-two, migration 0016 took it to twenty-four, migration 0018 took
-- it to twenty-five, migration 0019 took it to twenty-six, migration
-- 0020 (ROSTER_SPEC.md §3/§4) took it to twenty-seven, and migration 0022
-- (K9 fatigue/mood/fear-stress/injury/hunger/thirst persistence) took it to
-- twenty-eight. A hardcoded count in a destructive script is a promise that
-- silently rots every time a migration lands, so it is deliberately not
-- restated as a number here.
--
-- SCHEMA-SAFETY AUDIT FIX (db-schema pass, 2026-08-27): migration 0019's
-- own table (`k9_dog_characters`, the mana_policedogs feature-parity
-- admin-pinned dog-character record behind /k9setdog and /k9removedog)
-- had been completely absent from this file's FK-blocker gate, shape gate
-- and DROP list since the day it shipped -- the exact same class of gap
-- migration 0010's three tables, and every hand-maintained list like it in
-- this repo, had before being fixed. Named everywhere in this procedure
-- now, in the same change that added it to sql/install.sql,
-- sql/preflight_check.sql, sql/migration_status.sql and
-- sql/rollback/backup_k9_tables.sh.
-- The DROP list below is the authority. If you add a table in a
-- migration, add it here in the SAME change -- and to preflight_check.sql
-- and migration_status.sql, which have the same exposure.
--
-- #####################################################################
-- #  THIS FILE PERMANENTLY DELETES DATA. THERE IS NO UNDO.            #
-- #                                                                   #
-- #  IT IS INERT AS SHIPPED. Running it right now, as-is, does        #
-- #  NOTHING except print a refusal. You have to arm it by hand       #
-- #  (STEP 1 below) before it will delete anything. That is           #
-- #  deliberate: it means you cannot destroy your server's K9 data by #
-- #  pasting the wrong file into HeidiSQL or phpMyAdmin.              #
-- #                                                                   #
-- #  It also refuses -- armed or not -- if any of the 28 table names  #
-- #  it wants to drop is currently a table (or view) whose columns    #
-- #  do not look like qbx_k9unit's own, or blocked by another table's #
-- #  foreign key. It only ever drops a table it can verify is ours.   #
-- #####################################################################
--
-- WHAT YOU LOSE, permanently, when you arm and run this:
--
--   k9_certifications  Every K9-handler certification ever granted or
--                      revoked, and by whom. Your access-control record.
--
--   k9_search_log      Every contraband search ever performed: who
--                      searched, what they searched, when, and what was
--                      found. THIS IS THE ONE THAT MATTERS MOST. It is a
--                      privacy and accountability record -- the evidence
--                      trail for "did an officer actually search that
--                      player, and when". It is APPEND-ONLY and it is
--                      reconstructible from NOTHING. Once dropped, the
--                      answer to any future question about a past search
--                      is gone for good.
--
--   k9_partnerships    The full history of every K9/handler partnership:
--                      who, with whom, when formed, who ended it, when.
--
--   k9_partnership_pair_progress
--                      The highest partnership-tenure milestone tier each
--                      EXACT (K9, handler) pair has ever confirmed-earned,
--                      the fully durable half of the partnership-tenure
--                      anti-farm guard. Dropping it does not break
--                      anything (a missing row just reads as "never
--                      earned anything"), but it silently reopens the
--                      exploit this table exists to close: a pair that
--                      already earned a milestone could re-earn it again
--                      by breaking and reforming after this table is
--                      gone.
--
--   k9_progression     Every player's accumulated K9 XP, earned over
--                      weeks of play. Not recomputable.
--
--   k9_permissions     Every named K9 permission ever granted or revoked
--                      (k9.access / k9.certify / k9.audit / k9.givexp),
--                      and by whom. Your grantable-capability record --
--                      dropping this also silently strips every
--                      currently-active grant, not just the history.
--
--   k9_certification_specializations
--                      Every K9 specialization ever granted or revoked
--                      (narcotics / tracking / etc.), and by whom. Same
--                      shape of loss as k9_permissions: dropping it
--                      erases the audit trail AND silently removes every
--                      currently-active specialization.
--
--   k9_runtime_feature_overrides / k9_runtime_override_audit
--                      Every currently-active runtime override high
--                      command has made to a feature flag or tuning value
--                      away from config.lua's own shipped default, plus
--                      the full "who changed what, from what, to what"
--                      trail for every override ever set or reset.
--                      Dropping the first silently reverts every live
--                      override to its config.lua default on the next
--                      restart -- a real behavior change, not just an
--                      audit-trail loss; the second is not recomputable
--                      from anything else, since it holds history the
--                      first table never does.
--
--   k9_tablet_theme / k9_tablet_theme_audit
--                      The current K9 command tablet theme (colors,
--                      density, header title) every connected player's
--                      tablet renders, and the full history of every
--                      theme change ever made as a complete snapshot per
--                      change. Dropping the first silently reverts every
--                      tablet to its hardcoded default theme on the next
--                      read.
--
--   k9_ped_assignments Every citizenid's currently-applied K9 ped model
--                      override, and the original model hash needed to
--                      restore their real model. Not recomputable.
--
--   k9_certification_tiers / k9_certification_tier_capabilities /
--   k9_certification_tier_audit
--                      The full high-command-editable certification tier
--                      catalog (trainee/certified/senior plus any custom
--                      tier added or renamed since), exactly which
--                      capabilities each tier currently grants, and the
--                      full history of every tier-catalog create/rename/
--                      reorder/delete ever made. Dropping the first two
--                      silently reverts EVERY tier to config.lua's own
--                      three defaults with NO capabilities granted at all
--                      on the next restart -- including un-deleting a
--                      tier high command deliberately tombstoned. A real
--                      behavior change to a live server, not merely an
--                      audit-trail loss. The audit table is not
--                      recomputable from the other two, which only ever
--                      hold current state.
--
--   k9_equipment_shop_locations / k9_equipment_shop_locations_audit
--                      Every K9 equipment shop location a high command
--                      officer has added/moved from the tablet at runtime
--                      (on top of whatever config.lua ships), and the full
--                      history of every add/move/remove ever made.
--                      Dropping the first silently removes every
--                      tablet-added shop location from every connected
--                      client on the next broadcast -- a real behavior
--                      change, not just an audit-trail loss (locations
--                      that live in config.lua itself are unaffected
--                      either way). The audit table is not recomputable
--                      from the first, which only ever holds current
--                      state.
--
--   k9_permission_keys / k9_permission_key_audit
--                      The full high-command-editable PERMISSION-KEY
--                      catalog (the four shipped defaults -- k9.access /
--                      k9.certify / k9.audit / k9.givexp -- plus any
--                      custom key added, relabeled, or tombstoned since),
--                      and the full history of every create/relabel/
--                      restore/delete ever made. Dropping the first
--                      silently reverts EVERY permission key to
--                      config.lua's own Config.Permissions defaults on the
--                      next restart -- including un-deleting a key high
--                      command deliberately tombstoned, and forgetting the
--                      label/description of any custom key an operator
--                      never re-adds. A real behavior change to a live
--                      server (server/permissions.lua's HasPermission
--                      re-validates every grant against this same catalog
--                      on every call), not merely an audit-trail loss. The
--                      audit table is not recomputable from the first,
--                      which only ever holds current state. Dropping
--                      either table does NOT delete any existing grant row
--                      in k9_permissions itself -- see that table's own
--                      entry above for what THAT loses.
--
--   k9_equipment_shop_items / k9_equipment_shop_item_audit
--                      The full high-command-editable K9 EQUIPMENT SHOP
--                      ITEM CATALOG override/addition/tombstone state (on
--                      top of whatever config.lua's Config.K9EquipmentShop
--                      .items ships), and the full history of every
--                      create/edit/reorder/delete ever made. Dropping the
--                      first silently reverts every price/label/order/
--                      purchase-requirement edit to config.lua's own
--                      shipped defaults on the NEXT restart -- including
--                      un-deleting an item high command deliberately
--                      pulled from sale, and silently DROPPING the
--                      certification-tier/specialization purchase
--                      requirement protecting every gated item still in
--                      the shop. A real behavior (and security-posture)
--                      change to a live server, not merely an audit-trail
--                      loss. The audit table is not recomputable from the
--                      first, which only ever holds current state.
--
--   k9_xp_tiers / k9_xp_tier_audit
--                      Every high-command-edited field override for an
--                      existing XP rank (threshold, label, speed/scent
--                      multipliers, the optional medkit-cooldown multiplier
--                      and badge), on top of whatever config.lua's
--                      Config.XPTiers ships, and the full history of every
--                      edit ever made. Dropping the first silently reverts
--                      every edited rank back to config.lua's own shipped
--                      defaults on the NEXT restart (server/xptiers.lua's
--                      own onResourceStart handler re-reads this table and
--                      finds nothing left to override) -- a real behavior
--                      change to a live server (every K9's real movement-
--                      speed/scent-range bonus for a re-tuned rank snaps
--                      back), not merely an audit-trail loss. The audit
--                      table is not recomputable from the first, which
--                      only ever holds current field values, never history.
--
--   k9_individual_overrides / k9_individual_override_audit
--                      Every high-command-edited per-citizenid speed/scent/
--                      medkit-cooldown override (the per-INDIVIDUAL-K9 "god
--                      mode" layer, on top of whatever XP-tier profile a
--                      citizenid otherwise resolves to), and the full
--                      history of every create/edit/reset ever made.
--                      Dropping the first silently reverts every hand-tuned
--                      K9 back to its plain XP-tier values on the NEXT
--                      restart (server/k9profiles.lua's own onResourceStart
--                      handler re-reads this table and finds nothing left
--                      to override) -- a real behavior change to a live
--                      server, not merely an audit-trail loss. The audit
--                      table is not recomputable from the first, which
--                      only ever holds the current override, never history.
--
--   k9_dog_characters  Every character an admin has ever pinned as
--                      permanently a dog with /k9setdog (and un-pinned
--                      with /k9removedog) -- mana_policedogs feature
--                      parity. Dropping this silently un-pins every
--                      currently-pinned dog character: they do not break
--                      and are not stuck as dogs, they simply revert to an
--                      ordinary certification-driven appearance at their
--                      next appearance evaluation. Nobody's actual K9
--                      role/certification is affected either way -- this
--                      table has never decided whether a citizenid may act
--                      as a K9, only whether their dog form is pinned in
--                      place. The admin decisions themselves are gone and
--                      would have to be re-made by hand, character by
--                      character.
--
--   k9_personnel       Every K9/Handler roster assignment ever made
--                      (which of the two rosters a certified citizenid
--                      belongs to per department) and their current
--                      callsign, plus the full history of every
--                      assignment/role-change/clear ever made
--                      (ROSTER_SPEC.md §3/§4). Dropping this silently
--                      sends every currently-assigned K9/handler back to
--                      the "Unassigned" bucket on the next roster read,
--                      and forgets every currently-held callsign -- a
--                      real behavior change to the roster screens, but
--                      NOT to anyone's actual in-game abilities (this
--                      table has never been the thing that decides
--                      whether a citizenid can act as a K9/handler, only
--                      which roster list they show up on).
--
--   k9_wellbeing       Every online K9's current fatigue, mood, fear/
--                      stress, injury, hunger and thirst condition
--                      (server/wellbeing.lua). Dropping this silently
--                      resets every K9's condition to fresh-and-uninjured
--                      the next time this resource loads that citizenid --
--                      exactly the "nightly restart resets the dog"
--                      behavior this table exists to prevent. Not
--                      recomputable.
--
-- ==> THE ONLY WAY BACK IS A BACKUP YOU TOOK BEFORE RUNNING THIS.
--     Run sql/rollback/backup_k9_tables.sh first. It takes seconds.
--     See README.md's "Uninstalling / rolling back" section (or
--     sql/DATABASE_GUIDE.md's "Part 2"). If you have not run it, stop
--     now and go run it.
--
-- YOU PROBABLY DO NOT NEED THIS FILE. Almost every real "I need to undo
-- the install" situation is solved by the per-migration rollback scripts
-- in this directory (0004_down.sql / 0003_down.sql), which reverse a
-- schema change WITHOUT deleting anything. This file is only for
-- genuinely removing the resource from a server for good. If you are
-- unsure which you want: you want 0004_down.sql, not this.
--
-- Also note: you do NOT need to uninstall to stop using the resource.
-- Removing `ensure qbx_k9unit` from server.cfg stops it completely, and
-- leaves every one of our tables intact and harmless on disk in case you
-- ever want them back. Just want permission grants specifically off?
-- `Config.Features.PermissionGrants = false` does that without touching
-- any table at all -- see sql/rollback/0005_down.sql.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1 -- ARM IT (this is the safety catch)
--
-- The line immediately below resets the confirmation to "not armed" every
-- single time this file runs, so a leftover setting from an earlier
-- session can never arm it behind your back.
-- ---------------------------------------------------------------------
SET @K9_UNINSTALL_CONFIRM = NULL;

-- To actually delete the tables, REMOVE THE TWO DASHES AND THE SPACE from
-- the start of the next line (turning it from a comment into a real
-- statement), then run this file:
--
-- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';
--
-- Leave it commented and this file stays a harmless no-op.
-- ---------------------------------------------------------------------


DROP PROCEDURE IF EXISTS `qbx_k9unit_uninstall_all`;
DELIMITER $$
CREATE PROCEDURE `qbx_k9unit_uninstall_all`()
BEGIN
    -- =================================================================
    -- SAFETY GATE -- runs BEFORE anything is dropped, armed or not.
    --
    -- WHY THIS EXISTS (a real, reproduced failure, not a theoretical one):
    -- if any OTHER table in this database has a FOREIGN KEY pointing at
    -- one of our tables, `DROP TABLE` on that table is refused by InnoDB
    -- with error 1451. Without this gate the uninstall would already have
    -- dropped the earlier tables in the list before hitting that error,
    -- and the `mysql` client aborts the rest of the file -- leaving the
    -- operator with SOME of our tables gone and the rest still there.
    -- Measured before this gate was added: `k9_search_log` (the audit log,
    -- and the one table that is reconstructible from nothing) was already
    -- destroyed, then the run stopped, leaving five tables behind.
    --
    -- A half-completed uninstall is worse than one that refuses to start,
    -- so this refuses to start. Nothing is dropped unless everything can
    -- be dropped.
    -- =================================================================
    DECLARE fk_blockers INT DEFAULT 0;
    DECLARE shape_blockers INT DEFAULT 0;

    -- OWNED TABLE LIST -- named out in full, byte-identical, in FOUR places
    -- in this procedure: this COUNT, every branch of the dependency report
    -- below, the DRIFT CHECK branch of that same report, and the DROP list
    -- at the bottom. It is deliberately NOT swept from INFORMATION_SCHEMA by
    -- a bare `k9\_%` LIKE/REGEXP pattern instead of typed out repeatedly.
    -- Two real constraints make a blind pattern sweep unsafe for THIS
    -- specific list, unlike the stored-procedure sweep further down this
    -- same file (which safely IS a pattern sweep -- see its own header for
    -- why that one is safe and this one is not):
    --   1. DROP ORDER: if a future table here ever gains a real FK to
    --      another table in this same list, the DROP statements at the
    --      bottom would need to run in dependency order -- a sweep has no
    --      way to know that order, a hand-maintained list can be written in
    --      it. (No such FK exists between any two of our own tables today --
    --      every CREATE TABLE in install.sql/this resource's migrations
    --      declares zero FKs by design, see e.g. k9_certifications' own
    --      header -- but the DROP list is written defensively as if one
    --      could exist tomorrow, since retrofitting order into an existing
    --      DROP list under time pressure is worse than starting with it.)
    --   2. OTHER RESOURCES SHARE THE `k9_` PREFIX: this database can
    --      legitimately contain another K9 resource's own tables (the
    --      "STILL PRESENT" report below and backup_k9_tables.sh's own NOTE
    --      both call out `k9_units`-style tables as a real, expected case)
    --      -- a bare `k9\_%` sweep in the FK-blocker COUNT below would treat
    --      an FK into THAT resource's table as a reason to refuse OUR
    --      uninstall, which is wrong: we are not dropping that table, so a
    --      constraint pointing at it is none of our business.
    -- Because this list must stay hand-maintained, migration 0010's own
    -- three brand-new tables being absent from it for a time (fixed in this
    -- same change, verified by execution -- see this file's own git history/
    -- PR description) is exactly the failure mode this comment exists to
    -- keep from recurring a THIRD time. The DRIFT CHECK branch of the
    -- dependency report below is the backstop for the next time a migration
    -- is missed here anyway: it runs unconditionally, on every single
    -- invocation (armed or not), and names any `k9_%` table in this
    -- database that is not one of the twenty-nine named below (this
    -- prose previously said "twenty-five," which was already one short of
    -- the real count even before this pass's own k9_dog_characters fix,
    -- then "twenty-seven" before this pass's own k9_wellbeing addition --
    -- corrected here to match the real, counted list), loudly, in the
    -- one report every operator already reads before doing anything else in
    -- this file.
    SELECT COUNT(*) INTO fk_blockers
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
    WHERE CONSTRAINT_SCHEMA = DATABASE()
      AND REFERENCED_TABLE_NAME IN ('k9_certifications','k9_search_log','k9_partnerships',
                                    'k9_partnership_pair_progress',
                                    'k9_progression','k9_permissions','k9_certification_specializations',
                                    'k9_runtime_feature_overrides','k9_runtime_override_audit',
                                    'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments',
                                    'k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit',
                                    'k9_equipment_shop_locations','k9_equipment_shop_locations_audit',
                                    'k9_permission_keys','k9_permission_key_audit',
                                    'k9_equipment_shop_items','k9_equipment_shop_item_audit',
                                    'k9_xp_tiers','k9_xp_tier_audit',
                                    'k9_individual_overrides','k9_individual_override_audit',
                                    'k9_personnel','k9_dog_characters','k9_wellbeing','k9_roles')
      AND TABLE_NAME NOT IN ('k9_certifications','k9_search_log','k9_partnerships',
                             'k9_partnership_pair_progress',
                             'k9_progression','k9_permissions','k9_certification_specializations',
                             'k9_runtime_feature_overrides','k9_runtime_override_audit',
                             'k9_tablet_theme','k9_tablet_theme_audit','k9_ped_assignments',
                             'k9_certification_tiers','k9_certification_tier_capabilities','k9_certification_tier_audit',
                             'k9_equipment_shop_locations','k9_equipment_shop_locations_audit',
                             'k9_permission_keys','k9_permission_key_audit',
                             'k9_equipment_shop_items','k9_equipment_shop_item_audit',
                             'k9_xp_tiers','k9_xp_tier_audit',
                             'k9_individual_overrides','k9_individual_override_audit',
                             'k9_personnel','k9_dog_characters','k9_wellbeing','k9_roles');


    -- =================================================================
    -- SHAPE GATE, SECOND SAFETY GATE -- also runs BEFORE anything is
    -- dropped, armed or not, same as the FK-blocker gate above.
    --
    -- WHY THIS EXISTS: the FK-blocker gate above only refuses if some
    -- OTHER table references one of our 28 names via a real foreign key.
    -- It says nothing about whether the table CURRENTLY sitting under one
    -- of those 28 names is actually ours. `DROP TABLE IF EXISTS` drops
    -- whatever object has that name, full stop -- it does not check that
    -- the object's columns look like something qbx_k9unit created. On a
    -- shared database (the exact case this resource's own comments
    -- elsewhere already treat as real and expected -- a sibling K9
    -- resource, e.g. `k9_units`, sharing this same database), a foreign
    -- resource happening to use one of these 28 exact table names would
    -- otherwise be silently, permanently destroyed by an armed run of
    -- this file, with no warning -- the single worst outcome this
    -- resource's own design principle rules out everywhere else
    -- (`sql/preflight_check.sql` CHECK 1 and `server/datastore.lua`'s own
    -- boot-time schema-collision probe both exist specifically so this
    -- resource never treats a same-named foreign table as its own; the
    -- boot check goes as far as refusing to use the database at all
    -- rather than risk a single write into one). This uninstall path had
    -- no equivalent check before this pass -- fixed here the same way.
    --
    -- Reuses the identical per-table "does this table have OUR expected
    -- columns" signature `sql/preflight_check.sql`'s own CHECK 1 uses
    -- (itself kept in sync with `server/datastore.lua`'s
    -- `EXPECTED_TABLE_COLUMNS`, per that file's own comment) rather than
    -- inventing a third, independently-drifting list. HONEST LIMIT OF
    -- THIS APPROACH: SQL has no way to `require()` a Lua table or another
    -- .sql file at runtime, so this is necessarily a THIRD hand-typed copy
    -- of the same 28 signatures, not a shared reference to one -- exactly
    -- the same hand-maintained-list tradeoff this procedure's own OWNED
    -- TABLE LIST comment above already accepts for the DROP list itself.
    -- If you change a table's identifying columns in ANY of the three
    -- places (this block, `sql/preflight_check.sql` CHECK 1,
    -- `server/datastore.lua`'s `EXPECTED_TABLE_COLUMNS`), change all three
    -- in the same commit -- that is the honest process for keeping three
    -- independently-maintained-but-must-agree lists from drifting apart
    -- again, not a promise that they cannot.
    --
    -- A table that does not exist at all is NOT a shape blocker (nothing
    -- for `DROP TABLE IF EXISTS` to hurt); a table that exists but is a
    -- VIEW rather than a real table, or is missing our expected columns,
    -- IS one -- either would make `DROP TABLE` itself throw a real error
    -- majority of the way through the DROP list below (views cannot be
    -- dropped by `DROP TABLE` at all) or silently destroy a foreign
    -- table's real data, so both are caught here, before anything runs.
    -- =================================================================
    SELECT COUNT(*) INTO shape_blockers
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
            UNION ALL SELECT 'k9_partnership_pair_progress', 3,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'
                 AND COLUMN_NAME IN ('k9_citizenid','handler_citizenid','highest_tenure_tier_granted'))
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
            -- migration 0020 (ROSTER_SPEC.md §3/§4): same class of gap as
            -- migrations 0010/0011/0013/0014/0015/0016/0018's tables above,
            -- avoided from the start this time -- named here plus in the
            -- FK-blocker gate and dependency report, and in the DROP list
            -- below.
            UNION ALL SELECT 'k9_personnel', 9,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'
                 AND COLUMN_NAME IN ('citizenid','job','role','callsign','granted_by','granted_at','cleared_by','cleared_at','active'))
            -- migration 0019 (mana_policedogs feature-parity pass) --
            -- SCHEMA-SAFETY AUDIT FIX, db-schema pass 2026-08-27: same class
            -- of gap as migration 0020's row above documents for itself,
            -- except this one predates it and went unnoticed until a
            -- dedicated schema-safety audit found it. Column list mirrors
            -- sql/install.sql's own CREATE TABLE and server/datastore.lua's
            -- own EXPECTED_TABLE_COLUMNS entry for this table exactly.
            UNION ALL SELECT 'k9_dog_characters', 6,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'
                 AND COLUMN_NAME IN ('citizenid','model','active','set_by','set_at','unset_at'))
            -- migration 0022 (K9 fatigue/mood/fear-stress/injury/hunger/
            -- thirst persistence, server/wellbeing.lua's K9Store.Wellbeing_Get/
            -- K9Store.Wellbeing_Upsert) -- named here plus in the FK-blocker
            -- gate and dependency report above, from the start. Column list
            -- mirrors sql/install.sql's own CREATE TABLE and
            -- server/datastore.lua's own EXPECTED_TABLE_COLUMNS entry for
            -- this table exactly.
            UNION ALL SELECT 'k9_wellbeing', 3,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'
                 AND COLUMN_NAME IN ('citizenid','fatigue','updated_at'))
            UNION ALL SELECT 'k9_roles', 8,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'
                 AND COLUMN_NAME IN ('role_key','label','xp_required','unlocks','deleted','created_at','updated_by','updated_at'))
    ) shp
    WHERE shp.tbl_exists = 1
      AND (shp.obj_type <> 'BASE TABLE' OR shp.cols_found <> shp.cols_expected);


    -- -----------------------------------------------------------------
    -- WHAT THIS DELETES, IN PLAIN ENGLISH -- runs UNCONDITIONALLY, before
    -- the dependency report and before the arm check, so it is the FIRST
    -- real content an operator running this file (armed or not) actually
    -- sees on screen. It exists because everything above this point in
    -- this file's own HEADER already explains, table by table, exactly
    -- what is lost and what is/is not recomputable -- but that header is
    -- a block of SQL COMMENTS, and neither the plain `mysql` CLI nor
    -- `sql/rollback/uninstall.sh` echoes comments back to the operator.
    -- Someone running this the documented way (piped into `mysql`, or via
    -- uninstall.sh) previously never saw that breakdown at all unless they
    -- separately opened this .sql file in a text editor -- exactly
    -- backwards for the single most consequential file in this resource.
    -- Only lists a table if it actually EXISTS in this database right now
    -- (a table that was never installed has nothing to lose), and includes
    -- its current row count so "not recomputable" is not just an abstract
    -- warning -- it is attached to a real number for THIS database.
    -- -----------------------------------------------------------------
    SELECT w.table_name, t.TABLE_ROWS AS approx_rows_right_now, w.what_you_would_lose
    FROM (
        SELECT 'k9_certifications' AS table_name, 'Every K9-handler certification ever granted or revoked, and by whom -- your access-control record.' AS what_you_would_lose
        UNION ALL SELECT 'k9_search_log' AS table_name, 'THE ONE THAT MATTERS MOST: every contraband search ever performed (who, what, when, what was found). A privacy/accountability record, reconstructible from NOTHING once gone.' AS what_you_would_lose
        UNION ALL SELECT 'k9_partnerships' AS table_name, 'The full history of every K9/handler partnership: who, with whom, when formed, who ended it and when.' AS what_you_would_lose
        UNION ALL SELECT 'k9_partnership_pair_progress' AS table_name, 'The fully durable half of the partnership-tenure anti-farm guard -- the highest milestone tier each exact (K9, handler) pair has ever earned. Dropping this does not break anything, but silently lets a pair re-earn an already-earned milestone by breaking and reforming.' AS what_you_would_lose
        UNION ALL SELECT 'k9_progression' AS table_name, 'Every player''s accumulated K9 XP and handler XP, earned over weeks of play. Not recomputable.' AS what_you_would_lose
        UNION ALL SELECT 'k9_permissions' AS table_name, 'Every named permission ever granted or revoked, and by whom. Also silently strips every CURRENTLY-ACTIVE grant, not just the history.' AS what_you_would_lose
        UNION ALL SELECT 'k9_certification_specializations' AS table_name, 'Every K9 specialization ever granted or revoked, and by whom. Also silently strips every CURRENTLY-ACTIVE specialization.' AS what_you_would_lose
        UNION ALL SELECT 'k9_runtime_feature_overrides' AS table_name, 'Every currently-active runtime override to a feature flag/tuning value. Dropping this silently reverts every live override to its config.lua default on the next restart -- a real behavior change.' AS what_you_would_lose
        UNION ALL SELECT 'k9_runtime_override_audit' AS table_name, 'The full ''who changed what, from what, to what'' history of every runtime override ever set or reset. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_tablet_theme' AS table_name, 'The current K9 tablet theme every connected player''s tablet renders. Dropping this silently reverts every tablet to its hardcoded default on the next read.' AS what_you_would_lose
        UNION ALL SELECT 'k9_tablet_theme_audit' AS table_name, 'The full history of every tablet theme change ever made. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_ped_assignments' AS table_name, 'Every citizenid''s currently-applied K9 ped model override, and the original model needed to restore it. Not recomputable.' AS what_you_would_lose
        UNION ALL SELECT 'k9_certification_tiers' AS table_name, 'The high-command-editable certification tier catalog. Dropping this (with the two below) silently reverts EVERY tier to config.lua''s three defaults with NO capabilities granted -- a real behavior change, including un-deleting a tombstoned tier.' AS what_you_would_lose
        UNION ALL SELECT 'k9_certification_tier_capabilities' AS table_name, 'Exactly which capabilities each certification tier currently grants. See k9_certification_tiers above for the full effect of dropping it.' AS what_you_would_lose
        UNION ALL SELECT 'k9_certification_tier_audit' AS table_name, 'The full history of every tier create/rename/reorder/delete ever made. Not recomputable from the two tables above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_equipment_shop_locations' AS table_name, 'Every K9 equipment shop location added/moved from the tablet at runtime. Dropping this silently removes every tablet-added location from every connected client on the next broadcast.' AS what_you_would_lose
        UNION ALL SELECT 'k9_equipment_shop_locations_audit' AS table_name, 'The full history of every shop-location add/move/remove ever made. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_permission_keys' AS table_name, 'The high-command-editable permission-key catalog (defaults plus any custom key). Dropping this silently reverts every permission key to config.lua''s defaults on the next restart, including un-deleting a tombstoned key.' AS what_you_would_lose
        UNION ALL SELECT 'k9_permission_key_audit' AS table_name, 'The full history of every permission-key create/relabel/restore/delete ever made. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_equipment_shop_items' AS table_name, 'The high-command-editable equipment shop item catalog (price/label/order/purchase requirements). Dropping this silently reverts every item to config.lua''s defaults, including silently DROPPING the certification-tier/specialization gate protecting a restricted item.' AS what_you_would_lose
        UNION ALL SELECT 'k9_equipment_shop_item_audit' AS table_name, 'The full history of every shop-item create/edit/reorder/delete ever made. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_xp_tiers' AS table_name, 'Every high-command-edited field override for an XP rank (threshold/label/speed/scent/badge). Dropping this silently reverts every edited rank to config.lua''s defaults on the next restart -- every K9''s real movement/scent bonus for a re-tuned rank snaps back.' AS what_you_would_lose
        UNION ALL SELECT 'k9_xp_tier_audit' AS table_name, 'The full history of every XP-rank edit ever made. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_individual_overrides' AS table_name, 'Every per-citizenid speed/scent/medkit-cooldown override (the per-K9 ''god mode'' layer). Dropping this silently reverts every hand-tuned K9 to its plain XP-tier values on the next restart.' AS what_you_would_lose
        UNION ALL SELECT 'k9_individual_override_audit' AS table_name, 'The full history of every per-citizenid override create/edit/reset ever made. Not recomputable from the table above.' AS what_you_would_lose
        UNION ALL SELECT 'k9_dog_characters' AS table_name, 'Every character ever admin-pinned as permanently a dog with /k9setdog (mana_policedogs feature parity). Dropping this silently un-pins every currently-pinned dog character on their next appearance evaluation -- they revert to an ordinary certification-driven appearance, not a broken state. Nobody''s actual K9 role/certification is affected either way.' AS what_you_would_lose
        UNION ALL SELECT 'k9_personnel' AS table_name, 'Every K9/Handler roster assignment and callsign, past and present (ROSTER_SPEC.md §3/§4). Dropping this silently sends every currently-assigned K9/handler back to the "Unassigned" bucket on the next roster read and forgets every current callsign -- a real change to the roster screens, but not to anyone''s actual in-game abilities.' AS what_you_would_lose
        UNION ALL SELECT 'k9_wellbeing' AS table_name, 'Every online K9''s current fatigue/mood/fear-stress/injury/hunger/thirst condition. Dropping this silently resets every K9''s wellbeing to fresh-and-uninjured the next time this resource loads that citizenid -- exactly the "nightly restart resets the dog" behavior this table was added to close. Not recomputable.' AS what_you_would_lose
        UNION ALL SELECT 'k9_roles' AS table_name, 'Every K9 role high command created, renamed, re-priced or removed on the tablet (name, XP needed, what it unlocks). Dropping this silently reverts the role list to config.lua''s three defaults on the next restart; who holds which role is kept (that is k9_certification_specializations).' AS what_you_would_lose
    ) w
    JOIN INFORMATION_SCHEMA.TABLES t
      ON t.TABLE_SCHEMA = DATABASE() AND t.TABLE_NAME = w.table_name
    ORDER BY w.table_name;

    -- -----------------------------------------------------------------
    -- DEPENDENCY REPORT -- always printed, whether or not this file is
    -- armed. Running it UNARMED is therefore a free dry run: it tells you
    -- exactly what removing this resource would affect, and changes
    -- nothing. An empty report means nothing else in your database
    -- references our tables.
    -- -----------------------------------------------------------------
    SELECT problem, object_name, detail FROM (
        SELECT 1 AS ord,
               'BLOCKS UNINSTALL - foreign key into our table' AS problem,
               CONSTRAINT_NAME AS object_name,
               CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' references ', REFERENCED_TABLE_NAME,
                      ' -- drop this constraint first: ALTER TABLE `', TABLE_NAME,
                      '` DROP FOREIGN KEY `', CONSTRAINT_NAME, '`;') AS detail
        FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
        WHERE CONSTRAINT_SCHEMA = DATABASE()
          AND REFERENCED_TABLE_NAME REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit|equipment_shop_locations|equipment_shop_locations_audit|permission_keys|permission_key_audit|equipment_shop_items|equipment_shop_item_audit|xp_tiers|xp_tier_audit|individual_overrides|individual_override_audit|personnel|dog_characters|wellbeing)$'
          AND TABLE_NAME NOT REGEXP '^k9_(certifications|search_log|partnerships|partnership_pair_progress|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit|equipment_shop_locations|equipment_shop_locations_audit|permission_keys|permission_key_audit|equipment_shop_items|equipment_shop_item_audit|xp_tiers|xp_tier_audit|individual_overrides|individual_override_audit|personnel|dog_characters|wellbeing)$'
        UNION ALL
        SELECT 1,
               'BLOCKS UNINSTALL - table name is not ours (columns do not match)',
               shp2.table_name,
               CONCAT('A table named `', shp2.table_name, '` exists in this database, but its columns ',
                      'do not match what qbx_k9unit created (reported type: ', IFNULL(shp2.obj_type, 'MISSING'),
                      ', matched ', shp2.cols_found, ' of ', shp2.cols_expected, ' expected identifying columns). ',
                      'This uninstall will NOT drop it -- dropping a table just because the NAME matches would ',
                      'risk permanently destroying a DIFFERENT resource''s data (e.g. a sibling K9 resource ',
                      'sharing this same database). If this is genuinely an old/renamed shape of our own table, ',
                      'migrate it to match sql/install.sql by hand first; if it belongs to another resource, ',
                      'that resource -- not this file -- needs a different table name.')
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
            UNION ALL SELECT 'k9_partnership_pair_progress', 3,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_partnership_pair_progress'
                 AND COLUMN_NAME IN ('k9_citizenid','handler_citizenid','highest_tenure_tier_granted'))
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
            UNION ALL SELECT 'k9_personnel', 9,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_personnel'
                 AND COLUMN_NAME IN ('citizenid','job','role','callsign','granted_by','granted_at','cleared_by','cleared_at','active'))
            UNION ALL SELECT 'k9_dog_characters', 6,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_dog_characters'
                 AND COLUMN_NAME IN ('citizenid','model','active','set_by','set_at','unset_at'))
            UNION ALL SELECT 'k9_wellbeing', 3,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_wellbeing'
                 AND COLUMN_NAME IN ('citizenid','fatigue','updated_at'))
            UNION ALL SELECT 'k9_roles', 8,
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'),
              (SELECT TABLE_TYPE  FROM INFORMATION_SCHEMA.TABLES  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'),
              (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='k9_roles'
                 AND COLUMN_NAME IN ('role_key','label','xp_required','unlocks','deleted','created_at','updated_by','updated_at'))
        ) shp2
        WHERE shp2.tbl_exists = 1
          AND (shp2.obj_type <> 'BASE TABLE' OR shp2.cols_found <> shp2.cols_expected)
        UNION ALL
        SELECT 2,
               'WILL BREAK - view reads one of our tables',
               TABLE_NAME,
               'This view keeps existing after the uninstall but errors with "references invalid table(s)" whenever anything uses it. Drop or rewrite it.'
        FROM INFORMATION_SCHEMA.VIEWS
        WHERE TABLE_SCHEMA = DATABASE()
          AND VIEW_DEFINITION REGEXP 'k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit|equipment_shop_locations|equipment_shop_locations_audit|permission_keys|permission_key_audit|equipment_shop_items|equipment_shop_item_audit|xp_tiers|xp_tier_audit|individual_overrides|individual_override_audit|personnel|dog_characters|wellbeing)'
        UNION ALL
        SELECT 3,
               'WILL BE DELETED - trigger lives on one of our tables',
               TRIGGER_NAME,
               CONCAT('This trigger is attached to ', EVENT_OBJECT_TABLE,
                      ' and MySQL deletes it together with that table. Save its definition now if you want it back (SHOW CREATE TRIGGER `', TRIGGER_NAME, '`).')
        FROM INFORMATION_SCHEMA.TRIGGERS
        WHERE TRIGGER_SCHEMA = DATABASE()
          AND EVENT_OBJECT_TABLE REGEXP '^k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit|equipment_shop_locations|equipment_shop_locations_audit|permission_keys|permission_key_audit|equipment_shop_items|equipment_shop_item_audit|xp_tiers|xp_tier_audit|individual_overrides|individual_override_audit|personnel|dog_characters|wellbeing)$'
        UNION ALL
        SELECT 4,
               'WILL BREAK - stored routine reads one of our tables',
               ROUTINE_NAME,
               'This routine keeps existing after the uninstall but fails with "Table doesn''t exist" when called. Drop or rewrite it.'
        FROM INFORMATION_SCHEMA.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
          AND ROUTINE_NAME NOT LIKE 'qbx\_k9unit\_%'
          AND ROUTINE_DEFINITION REGEXP 'k9_(certifications|search_log|partnerships|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit|equipment_shop_locations|equipment_shop_locations_audit|permission_keys|permission_key_audit|equipment_shop_items|equipment_shop_item_audit|xp_tiers|xp_tier_audit|individual_overrides|individual_override_audit|personnel|dog_characters|wellbeing)'
        UNION ALL
        -- DRIFT CHECK (db-schema foolproofing pass, 2026-08-25): reproduced by
        -- execution -- a real FK into `k9_certification_tiers` (a table this
        -- file's own FK-blocker COUNT above did not yet know about) was
        -- previously invisible to every check in this file, and an armed run
        -- printed `UNINSTALLED` without ever mentioning it. That specific gap
        -- is now closed (the three migration-0010 tables are named
        -- everywhere above), but the SAME class of gap -- a future migration
        -- adding a table here without also adding it to this file -- cannot
        -- be closed the same way in advance, because this list is
        -- deliberately hand-maintained, not a `k9\_%` pattern sweep (see the
        -- OWNED TABLE LIST comment above this procedure's DECLARE for why a
        -- pattern sweep is unsafe here specifically: DROP ordering and
        -- other-resources'-tables sharing the same prefix). This branch is
        -- the backstop instead: it runs UNCONDITIONALLY, every single time
        -- this file is run, armed or not, as part of the one report every
        -- operator already reads before anything else happens -- so the next
        -- missed table announces itself here instead of hiding the way
        -- migration 0010's three tables did. NOT a refusal/gate by itself
        -- (unlike the FK-blocker check above): a `k9_%` table this file does
        -- not recognize is EITHER a genuine drift bug in this file (report
        -- it) OR another K9 resource's own, unrelated table legitimately
        -- sharing this prefix (the "STILL PRESENT" report below and
        -- backup_k9_tables.sh's own NOTE both document that second case as
        -- real and expected) -- this file cannot tell those two apart from
        -- INFORMATION_SCHEMA alone, so it surfaces the fact loudly and lets
        -- a human decide, exactly like backup_k9_tables.sh's own drift guard
        -- and this file's own "STILL PRESENT" residue report already do,
        -- rather than guessing and either refusing a legitimate uninstall or
        -- silently accepting a real drift.
        SELECT 0,
               'UNRECOGNIZED - k9_* table not in this file''s own table list',
               TABLE_NAME,
               'This table is NOT one of the tables this file knows how to check or drop. If it belongs to qbx_k9unit, this file is out of date -- a migration added a table without this file being updated in the same change (see the OWNED TABLE LIST comment above) -- report it before arming this file. If it belongs to a DIFFERENT K9 resource sharing this database, this is expected and safe to ignore; this file will never touch it.'
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME LIKE 'k9\_%'
          AND TABLE_NAME NOT REGEXP '^k9_(certifications|search_log|partnerships|partnership_pair_progress|progression|permissions|certification_specializations|runtime_feature_overrides|runtime_override_audit|tablet_theme|tablet_theme_audit|ped_assignments|certification_tiers|certification_tier_capabilities|certification_tier_audit|equipment_shop_locations|equipment_shop_locations_audit|permission_keys|permission_key_audit|equipment_shop_items|equipment_shop_item_audit|xp_tiers|xp_tier_audit|individual_overrides|individual_override_audit|personnel|dog_characters|wellbeing)$'
    ) deps
    ORDER BY ord, object_name;

    -- `<=>` is NULL-safe equality: when the arming line above is left
    -- commented out, @K9_UNINSTALL_CONFIRM is NULL, and a plain `=` would
    -- yield NULL (neither true nor false) rather than a clean false. `<=>`
    -- makes the unarmed case a definite, reliable "no".
    IF NOT (@K9_UNINSTALL_CONFIRM <=> 'YES-DELETE-ALL-MY-K9-DATA') THEN
        SELECT 'NOT ARMED - NOTHING WAS DELETED' AS status,
               'This file is not armed, so it did nothing at all. Your tables are untouched. Any rows listed above are what removing this resource WOULD affect -- this was a free dry run. To really delete: take a backup first (sql/rollback/backup_k9_tables.sh), then uncomment the SET @K9_UNINSTALL_CONFIRM line near the top of this file and run it again.' AS detail;

    ELSEIF fk_blockers > 0 THEN
        SELECT 'REFUSED - NOTHING WAS DELETED' AS status,
               CONCAT('Another table in this database has ', fk_blockers,
                      ' foreign key column(s) pointing at our tables (listed above). MySQL will not let those tables be dropped while those constraints exist, and dropping only SOME of our tables would leave you half-uninstalled -- so nothing was touched at all. Remove the listed constraint(s) with the ALTER TABLE command shown above, then run this file again.') AS detail;

    ELSEIF shape_blockers > 0 THEN
        SELECT 'REFUSED - NOTHING WAS DELETED' AS status,
               CONCAT(shape_blockers,
                      ' of our 28 table name(s) are used in this database by something whose columns do not ',
                      'match qbx_k9unit (listed above as "BLOCKS UNINSTALL - table name is not ours"). ',
                      'Dropping a table just because its NAME matches ours would risk destroying a DIFFERENT ',
                      'resource''s data -- so nothing was touched at all, exactly like the foreign-key case ',
                      'above. Rename or fix the foreign table (or, if it is genuinely an old shape of our own ',
                      'table, bring it up to sql/install.sql''s current shape by hand), then run this file ',
                      'again.') AS detail;

    ELSE
        DROP TABLE IF EXISTS `k9_search_log`;
        DROP TABLE IF EXISTS `k9_certifications`;
        DROP TABLE IF EXISTS `k9_partnerships`;
        DROP TABLE IF EXISTS `k9_progression`;
        DROP TABLE IF EXISTS `k9_permissions`;
        DROP TABLE IF EXISTS `k9_certification_specializations`;
        DROP TABLE IF EXISTS `k9_runtime_feature_overrides`;
        DROP TABLE IF EXISTS `k9_runtime_override_audit`;
        DROP TABLE IF EXISTS `k9_tablet_theme`;
        DROP TABLE IF EXISTS `k9_tablet_theme_audit`;
        DROP TABLE IF EXISTS `k9_ped_assignments`;
        -- migration 0010 (db-schema foolproofing pass, 2026-08-25): these
        -- three were previously absent from this list entirely, which is
        -- why the FK-blocker gate above and the dependency report also had
        -- to be fixed in the SAME change -- see the OWNED TABLE LIST comment
        -- near this procedure's DECLARE for the full incident writeup. No FK
        -- exists between any two of our own tables (see that comment), so
        -- their position in this list carries no ordering requirement today.
        DROP TABLE IF EXISTS `k9_certification_tiers`;
        DROP TABLE IF EXISTS `k9_certification_tier_capabilities`;
        DROP TABLE IF EXISTS `k9_certification_tier_audit`;
        -- migration 0011 (db-schema pass, 2026-08-26): same class of gap as
        -- migration 0010's three tables immediately above, now fixed in the
        -- same way -- named here plus in the FK-blocker gate and dependency
        -- report above. No FK exists between any two of our own tables, so
        -- their position in this list carries no ordering requirement.
        DROP TABLE IF EXISTS `k9_equipment_shop_locations`;
        DROP TABLE IF EXISTS `k9_equipment_shop_locations_audit`;
        -- migration 0013 (owner-directed "add or remove permissions" pass):
        -- same class of gap as migrations 0010/0011's tables immediately
        -- above, now fixed in the same way -- named here plus in the
        -- FK-blocker gate and dependency report above. No FK exists between
        -- any two of our own tables, so their position in this list carries
        -- no ordering requirement.
        DROP TABLE IF EXISTS `k9_permission_keys`;
        DROP TABLE IF EXISTS `k9_permission_key_audit`;
        -- migration 0014 (owner-directed "give high command real control
        -- over the equipment shop" pass -- the ITEM CATALOG half; migration
        -- 0011's two tables above already cover the LOCATIONS half): same
        -- class of gap as migrations 0010/0011/0013's tables immediately
        -- above, now fixed in the same way -- named here plus in the
        -- FK-blocker gate and dependency report above. No FK exists between
        -- any two of our own tables, so their position in this list carries
        -- no ordering requirement.
        DROP TABLE IF EXISTS `k9_equipment_shop_items`;
        DROP TABLE IF EXISTS `k9_equipment_shop_item_audit`;
        -- migration 0015 (owner-directed "set experience level for each
        -- rank up" pass): same class of gap as migrations 0010/0011/0013's
        -- tables immediately above, now fixed in the same way -- named here
        -- plus in the FK-blocker gate and dependency report above. No FK
        -- exists between any two of our own tables, so their position in
        -- this list carries no ordering requirement.
        DROP TABLE IF EXISTS `k9_xp_tiers`;
        DROP TABLE IF EXISTS `k9_xp_tier_audit`;
        -- migration 0016 (owner-directed "god over that tablet, full
        -- customization over everything related to that K9" pass -- the
        -- per-INDIVIDUAL-K9 override half; migration 0015's two tables
        -- above already cover the per-RANK half): same class of gap as
        -- migrations 0010/0011/0013/0014/0015's tables immediately above,
        -- now fixed in the same way -- named here plus in the FK-blocker
        -- gate and dependency report above. No FK exists between any two
        -- of our own tables, so their position in this list carries no
        -- ordering requirement.
        DROP TABLE IF EXISTS `k9_individual_overrides`;
        DROP TABLE IF EXISTS `k9_individual_override_audit`;
        -- migration 0018 (the fully durable partnership-tenure anti-farm
        -- guard, closing KNOWN_ISSUES.md's own "in-memory only" disclosure):
        -- same class of gap as migrations 0010/0011/0013/0014/0015/0016's
        -- tables above, now fixed in the same way -- named here plus in the
        -- FK-blocker gate and dependency report above. No FK exists between
        -- any two of our own tables, so its position in this list carries
        -- no ordering requirement.
        DROP TABLE IF EXISTS `k9_partnership_pair_progress`;
        -- migration 0019 (mana_policedogs feature-parity pass, the
        -- admin-pinned "this citizenid IS a dog" record behind /k9setdog
        -- and /k9removedog) -- SCHEMA-SAFETY AUDIT FIX, db-schema pass
        -- 2026-08-27: this table was completely absent from this DROP
        -- list (and from the FK-blocker gate and shape gate above) since
        -- the day it shipped, the exact same class of gap migration 0010's
        -- three tables had before being fixed. No FK exists between any
        -- two of our own tables, so its position in this list carries no
        -- ordering requirement.
        DROP TABLE IF EXISTS `k9_dog_characters`;
        -- migration 0020 (ROSTER_SPEC.md §3/§4, the K9/Handler roster
        -- assignment + callsign table) -- named here plus in the
        -- FK-blocker gate and dependency report above, from the start.
        -- No FK exists between any two of our own tables, so its position
        -- in this list carries no ordering requirement.
        DROP TABLE IF EXISTS `k9_personnel`;
        -- migration 0022 (K9 fatigue/mood/fear-stress/injury/hunger/thirst
        -- persistence, server/wellbeing.lua's K9Store.Wellbeing_Get/
        -- K9Store.Wellbeing_Upsert) -- named here plus in the FK-blocker
        -- gate and dependency report above, from the start. No FK exists
        -- between any two of our own tables, so its position in this list
        -- carries no ordering requirement.
        DROP TABLE IF EXISTS `k9_wellbeing`;

        -- migration 0023 -- the K9 role catalog (server/roles.lua).
        DROP TABLE IF EXISTS `k9_roles`;

        -- RESIDUE REPORT: name any k9_* table this file did NOT drop. New
        -- migrations add tables, and if one is ever missed out of the list
        -- above it would otherwise be left behind in silence. This turns
        -- that into a visible line. Tables belonging to OTHER K9 resources
        -- (e.g. k9_units) legitimately appear here -- they are not ours to
        -- drop -- so this is a prompt to check, not an error.
        SELECT 'STILL PRESENT - not dropped by this file' AS note, TABLE_NAME AS table_name,
               'If this belongs to qbx_k9unit then this uninstall script is out of date and missed it -- report that. If it belongs to a different K9 resource, this is correct and expected.' AS detail
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'k9\_%';

        SELECT 'UNINSTALLED' AS status,
               'Every qbx_k9unit table has been dropped. This is permanent. If you took a backup with backup_k9_tables.sh, the restore command it printed is now your only way back. Anything listed above as "WILL BREAK" is now broken and needs your attention.' AS detail;
    END IF;
END$$
DELIMITER ;
CALL `qbx_k9unit_uninstall_all`();
DROP PROCEDURE IF EXISTS `qbx_k9unit_uninstall_all`;


-- ---------------------------------------------------------------------
-- HOUSEKEEPING: remove every helper procedure this resource's migrations
-- or rollbacks could have left behind in this schema, so a full uninstall
-- really does leave nothing of qbx_k9unit anywhere in the database.
--
-- This used to be a hand-maintained list of DROP PROCEDURE statements,
-- one per migration. That list fell out of date every single time a new
-- migration landed -- which is exactly the kind of silent drift that
-- leaves debris in an operator's database. It now sweeps by NAME PATTERN
-- instead, so a migration added tomorrow is cleaned up without anyone
-- having to remember to edit this file.
--
-- The pattern `qbx_k9unit\_%` is this resource's own reserved prefix and
-- nothing else in a sane database uses it; the escape makes `_` a literal
-- underscore rather than a single-character wildcard. Only PROCEDUREs in
-- the CURRENT database are considered -- never another schema, never a
-- FUNCTION, never a table.
--
-- Runs whether or not the uninstall was armed: it only ever removes this
-- resource's own leftover scaffolding, never a table and never a row, so
-- there is nothing to guard.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `qbx_k9unit_sweep_helper_procedures`;
DELIMITER $$
CREATE PROCEDURE `qbx_k9unit_sweep_helper_procedures`()
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE rname VARCHAR(128);
    DECLARE cur CURSOR FOR
        SELECT ROUTINE_NAME FROM INFORMATION_SCHEMA.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
          AND ROUTINE_TYPE = 'PROCEDURE'
          AND ROUTINE_NAME LIKE 'qbx\_k9unit\_%'
          AND ROUTINE_NAME <> 'qbx_k9unit_sweep_helper_procedures';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    sweep: LOOP
        FETCH cur INTO rname;
        IF done = 1 THEN LEAVE sweep; END IF;
        SET @drop_sql = CONCAT('DROP PROCEDURE IF EXISTS `', rname, '`');
        PREPARE stmt FROM @drop_sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL `qbx_k9unit_sweep_helper_procedures`();
DROP PROCEDURE IF EXISTS `qbx_k9unit_sweep_helper_procedures`;
