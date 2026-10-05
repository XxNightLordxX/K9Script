-- =====================================================================
-- john-k9 :: migration 0019 :: create k9_dog_characters
--
-- server/dogcharacter.lua (coder-backend, mana_policedogs feature-parity
-- pass -- competitor's own admin commands, per its Tebex description, are
-- `/setPoliceDog [id] [variation]` / `/removePoliceDog [id]`, which mark a
-- CHARACTER as permanently a dog, independent of any job/certification).
--
-- WHAT THIS TABLE IS, PRECISELY, AND WHY IT IS NOT A DUPLICATE OF THE
-- EXISTING `k9_ped_assignments` (migration 0008): that table already
-- records "what does citizenid X currently look like, and what did they
-- look like before" -- server/dogcharacter.lua reuses it UNCHANGED for
-- exactly that (via appearance.lua's own SendSwapRequest/
-- WriteAppearanceApplied/original-model-capture machinery, requested as a
-- small additive hook -- see server/dogcharacter.lua's own header for the
-- exact hand-off). What did NOT exist anywhere is a record of WHETHER a
-- given citizenid's current appearance is an EXPLICIT, ADMIN-PINNED FACT
-- (mana's model: "this character IS a dog until an admin says otherwise")
-- as opposed to an ORDINARY certification/permission-driven appearance
-- (this resource's own existing model, which server/appearance.lua's own
-- MaybeRevertK9Appearance already correctly unwinds the instant the
-- underlying credential is lost). This table holds exactly that one fact
-- -- a PIN, not a second copy of the model/original-hash bookkeeping --
-- and nothing else.
--
-- WHO NEEDS THIS FILE: every installation running this feature -- it is
-- brand new, so every existing database lacks it. Running this file is
-- also a safe no-op on a database that already has a same-named table from
-- some unrelated source (see IDEMPOTENT note below). server/dogcharacter.lua
-- does NOT run its own boot-time schema-collision probe the way
-- server/datastore.lua's shared VerifyTableShapesAgainstKnownSchema does
-- for every OTHER table in this schema -- deliberately: that file's own
-- header explicitly rejects a "mid-session monitor watching ordinary
-- query failures" design, so this file does not invent one either. Instead
-- every accessor below independently `pcall`s its own real query and
-- degrades to a logged failure for JUST that one call, matching the
-- per-call (not session-wide) failure posture every other K9Store.*
-- accessor already uses -- see server/dogcharacter.lua's own header.
--
-- IDEMPOTENT / SAFE TO RE-RUN: a bare `CREATE TABLE IF NOT EXISTS` -- no
-- ALTER, no DROP, never touches an existing row. Safe to run any number of
-- times, in any order relative to install.sql or any other migration file
-- in this folder (this table has no foreign key or other cross-table
-- dependency on anything created by migrations 0001-0018, including
-- `k9_ped_assignments` itself -- the two tables are correlated only in
-- application logic, at server/dogcharacter.lua/server/appearance.lua's
-- own runtime, never via a DB-level constraint).
--
-- WORKS WITH `Config.Database.enabled = false`: this table's own accessors
-- (server/dogcharacter.lua, NOT server/datastore.lua -- see that file's own
-- header for why it is a deliberate, flagged, temporary exception to this
-- schema's "only datastore.lua calls MySQL.*" convention, pending the
-- routed consolidation that file's header also spells out verbatim) follow
-- the exact same "one `if DatabaseEnabled(...) then ... else ... end`
-- branch, real SQL on one side, a plain Lua table on the other" shape every
-- other K9Store.* accessor in this resource already uses, so a memory-mode
-- server keeps every dog-character admin command working for the life of
-- the process, with nothing remembered past a restart -- exactly the same
-- honest trade-off server/datastore.lua's own header documents for every
-- other table in this schema.
--
-- SHAPE:
--   citizenid  VARCHAR(50), PRIMARY KEY -- qbx_core/QBCore convention, matching every other table in this schema
--   model      VARCHAR(64) NOT NULL     -- the PINNED K9 ped model NAME (a Config.Peds[].model string) -- record-keeping/audit/reconnect-precedence only; the ACTUAL live-ped swap and its own original-model-hash capture continue to live entirely in k9_ped_assignments, reused unchanged (see header above)
--   active     TINYINT(1) NOT NULL DEFAULT 1 -- 1 = currently pinned as a dog-character, 0 = un-pinned (row kept, never deleted, matching k9_ped_assignments' own "keep for history, never delete" convention -- see that table's migration 0008 header for the identical reasoning)
--   set_by     VARCHAR(50) NOT NULL     -- citizenid of the high-command officer who ran /k9setdog -- no FK/format constraint, same as k9_ped_assignments.applied_by/k9_certifications.revoked_by's own 'system:...' sentinel precedent
--   set_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
--   unset_at   DATETIME, NULL           -- set when active flips to 0
--
-- WHY PRIMARY KEY ON `citizenid` ALONE, NOT AN AUTO_INCREMENT `id`: same
-- reasoning as k9_ped_assignments' own migration 0008 header -- this is
-- CURRENT STATE ONLY ("is citizenid X currently pinned as a dog-character,
-- and to which model"), not an append-only history. The audit trail for
-- WHO ran /k9setdog / /k9removedog and WHEN already exists as `print()`
-- lines via this resource's established print-based-audit convention (see
-- server/appearance.lua's own LogAppearanceAudit / server/admin.lua's
-- LogAuditInvocation), matching k9_ped_assignments' own identical decision.
--
-- INDEX: `idx_active` on (`active`) -- same "cheap, matches this schema's
-- established convention for the one column a future admin/reporting query
-- against a table like this will most want to filter by" reasoning as
-- k9_ped_assignments' own idx_active.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql's
-- own stated floor and every other migration in this folder -- this
-- specific table needs nothing beyond that floor itself.
--
-- ROUTING NOTE (not part of the SQL below -- for whoever integrates this):
-- this table's name/columns should ideally also be added to
-- server/datastore.lua's own EXPECTED_TABLE_COLUMNS / friendly-name maps
-- (near k9_ped_assignments' own entries) so its shared boot-time schema-
-- collision probe covers this table too, the same way it already covers
-- every other table in this schema. Not required for correctness today --
-- server/dogcharacter.lua's own accessors degrade to memory-only mode on
-- any real query failure against this table regardless (see that file's
-- own header) -- but folding it into the shared probe would give this
-- table the same fine-grained "one bad table doesn't force EVERY table
-- into memory mode" treatment k9_ped_assignments already gets.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_dog_characters` (
  `citizenid` VARCHAR(50)  NOT NULL,
  `model`     VARCHAR(64)  NOT NULL,
  `active`    TINYINT(1)   NOT NULL DEFAULT 1,
  `set_by`    VARCHAR(50)  NOT NULL,
  `set_at`    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `unset_at`  DATETIME     DEFAULT NULL,

  PRIMARY KEY (`citizenid`),
  KEY `idx_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
