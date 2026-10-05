-- =====================================================================
-- john-k9 :: migration 0008 :: create k9_ped_assignments
--
-- server/appearance.lua (coder-architect, K9 role/ped-model decoupling
-- pass, Config.K9Appearance). This table is the ONLY new persisted state
-- that pass needed: the K9 ROLE ITSELF was already derivable from existing
-- tables (an active k9_certifications row, or an active k9_permissions
-- 'k9.access' grant -- see server/appearance.lua's HasK9Role and its own
-- header for the full writeup); what did NOT exist anywhere is a record of
-- WHAT PED MODEL a citizenid is currently wearing as a result, or what
-- they looked like before the very first swap, so a revoke can put it
-- back. This table holds exactly that, and nothing else.
--
-- WHO NEEDS THIS FILE: every installation running this feature -- it is
-- brand new, so every existing database lacks it. A fresh install running
-- sql/install.sql after this migration lands will get it there instead
-- (see that file's own k9_ped_assignments header, added alongside this
-- migration) -- running this file afterward is still a documented, safe
-- no-op (CREATE TABLE IF NOT EXISTS).
--
-- IDEMPOTENT / SAFE TO RE-RUN: a bare `CREATE TABLE IF NOT EXISTS` -- no
-- ALTER, no DROP, never touches an existing row. Safe to run any number of
-- times, in any order relative to install.sql or the other migration files
-- in this folder (this table has no foreign key or other cross-table
-- dependency on anything created by migrations 0001-0007).
--
-- WHY `original_model_hash` IS A HASH (a BIGINT), NOT A MODEL NAME STRING,
-- UNLIKE `model` BELOW: `model` always comes from an operator's own
-- Config.Peds entry, so the STRING NAME is always already known and is
-- what makes an admin reading this table by hand able to tell what is
-- applied at a glance. `original_model_hash` is captured from a LIVE
-- player's ped via the GetEntityModel native, which returns a HASH -- GTA
-- model hashes are one-way (there is no native or table anywhere that
-- reverses a hash back into the string that produced it), so the hash is
-- the ONLY form this value could ever be captured in, and it is also all
-- SetPlayerModel/RequestModel ever need to restore it -- there is no lossy
-- round trip here, storing the name was never an option to begin with.
-- BIGINT (not INT) because GetHashKey/GetEntityModel's signed 32-bit
-- return is stored EXACTLY as returned, with no reinterpretation of sign,
-- and BIGINT has headroom either way.
--
-- WHY PRIMARY KEY ON `citizenid` ALONE, NOT AN AUTO_INCREMENT `id`: unlike
-- k9_certifications/k9_permissions (which are append-only histories where
-- a citizenid can hold many rows over time, one per grant/revoke cycle),
-- this table tracks CURRENT STATE ONLY -- "what does citizenid X currently
-- look like, and what did they look like before" -- there is exactly one
-- answer to that question per citizenid at any moment, which
-- server/appearance.lua's own UPSERT (`INSERT ... ON DUPLICATE KEY UPDATE`)
-- depends on directly. History of PAST swaps is not kept (this is
-- appearance bookkeeping, not an audit table -- the audit trail for WHO
-- applied/reverted WHAT and WHEN already exists as `print()` lines via
-- LogAppearanceAudit, matching this resource's established
-- print-based-audit convention for admin/permission actions, per
-- server/admin.lua's own LogAuditInvocation and this pass's own item E).
--
-- SHAPE:
--   citizenid            VARCHAR(50), PRIMARY KEY -- qbx_core/QBCore convention, matching every other table in this schema
--   model                VARCHAR(64) NOT NULL -- currently-applied K9 ped model NAME (a Config.Peds[].model string)
--   original_model_hash  BIGINT, NULL -- see "WHY A HASH" above; NULL only until captured (an offline target's very first assignment, captured on their next PlayerLoaded before the real swap runs -- see server/appearance.lua)
--   active               TINYINT(1) NOT NULL DEFAULT 1 -- 1 = currently applied, 0 = reverted (row kept, never deleted, so a re-apply's UPSERT can tell "reuse this original" (still active) from "capture a fresh one" (was reverted) -- see WriteAppearanceApplied's own doc comment in server/appearance.lua)
--   applied_by           VARCHAR(50) NOT NULL -- citizenid of whoever applied it, or the literal string 'system' for the automatic PlayerLoaded/OnJobUpdate-driven paths (mirrors k9_certifications.revoked_by's own 'system:job_change' sentinel precedent -- no FK/format constraint on this column, same reasoning)
--   applied_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
--   revoked_at           DATETIME, NULL -- set when active flips to 0
--
-- INDEX: `idx_active` on (`active`) -- no known hot query needs it today
-- (every lookup in server/appearance.lua is by citizenid, the primary
-- key), but is cheap and matches this schema's established convention of
-- indexing the one column nearly every future admin/reporting query
-- against a table like this will want to filter by ("show me every
-- currently-applied K9 ped assignment").
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql's
-- own stated floor -- this specific table needs nothing from that floor
-- itself (no generated column, no functional index), but ships under the
-- same requirement as the rest of this schema for one consistent minimum
-- across the whole resource.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_ped_assignments` (
  `citizenid`           VARCHAR(50)  NOT NULL,
  `model`               VARCHAR(64)  NOT NULL,
  `original_model_hash` BIGINT       DEFAULT NULL,
  `active`              TINYINT(1)   NOT NULL DEFAULT 1,
  `applied_by`          VARCHAR(50)  NOT NULL,
  `applied_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_at`          DATETIME     DEFAULT NULL,

  PRIMARY KEY (`citizenid`),
  KEY `idx_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
