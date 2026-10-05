-- =====================================================================
-- john-k9 :: migration 0020 :: create k9_personnel
--
-- ROSTER_SPEC.md §3 (db-schema pass, 2026-08-26) -- owner's own words for
-- the request this answers: "make it in the tablet where there is a roster
-- where we can assign callsigns see list of hired k9s and full menu to
-- fire promote etc", "Also a separate roster for handlers same thing".
-- This table is the one new fact neither `k9_certifications` nor
-- `k9_dog_characters` can answer: WHICH of the two rosters (K9 or Handler)
-- a certified citizenid currently belongs to, and what callsign (if any)
-- they currently hold on that roster.
--
-- WHY NOT `k9_dog_characters` (migration 0019)? See ROSTER_SPEC.md §1 for
-- the full argument, restated briefly: that table is a purely COSMETIC
-- admin pin ("this citizenid IS a dog until an admin says otherwise"),
-- explicitly decoupled from role by its own header. Building the roster
-- split on it would MISS every real K9 who holds an active certification
-- but never had `/k9setdog` run on them (very likely most K9s on a normal
-- server), and would WRONGLY put a handler cosmetically pinned as a dog
-- (a costume, an event) onto the K9 roster. `IsPinnedDogCharacter` remains
-- useful only as an EXTRA, informational, non-authoritative fact shown on
-- a K9's roster row -- never as the thing that decides which roster a
-- citizenid appears on.
--
-- SHAPE, MODELED DIRECTLY ON `k9_certifications` (this schema's own
-- established append-mostly-audit-log convention), NOT on
-- `k9_dog_characters`'s current-state-only shape -- because, like a
-- certification, a personnel record needs to preserve history across a
-- fire-and-rehire cycle, not just overwrite in place (ROSTER_SPEC.md §3/§4:
-- firing clears the active row, a re-hire starts a brand-new one, the old
-- row stays present but inactive for audit purposes, and its callsign is
-- never resurrected):
--   `id`          INT UNSIGNED, PK, AUTO_INCREMENT -- one row per hire
--                 cycle, exactly like `k9_certifications.id`.
--   `citizenid`   VARCHAR(50)  -- qbx_core/QBCore convention, matches
--                 every other citizenid column in this schema.
--   `job`         VARCHAR(50)  -- department job name at grant time
--                 (Config.Departments key), scoped exactly like a
--                 certification, so a citizenid certified in two
--                 departments can hold two independent roster roles.
--   `role`        VARCHAR(10)  -- 'k9' | 'handler', validated at the
--                 application layer (server/roster.lua's
--                 IsValidPersonnelRole), NOT a DB-level ENUM/CHECK, same
--                 "validate in Lua, not in SQL" convention this schema
--                 already applies to `k9_certifications.tier`/
--                 `revoke_reason`. CALLED `personnelRole` in code/API,
--                 DELIBERATELY NOT `role`, to avoid colliding with the
--                 existing `role_heading`/`buildRoleControl`/`HasK9Role`
--                 "role" (the ped-and-access role this table has nothing
--                 to do with) -- see ROSTER_SPEC.md §1's own "naming
--                 collision, called out explicitly" section. The COLUMN is
--                 still named `role` here because it is unambiguous inside
--                 this one table with no sibling "role" concept to collide
--                 with -- the collision only exists in the shared Lua/API
--                 surface, which is where the rename actually matters.
--   `callsign`    VARCHAR(12), NULLABLE -- see ROSTER_SPEC.md §4: plain
--                 text, clamped 1-12 characters, restricted to letters,
--                 digits, spaces and hyphens SERVER-SIDE
--                 (server/roster.lua's IsValidCallsignFormat) -- this
--                 column has no CHECK constraint, matching this schema's
--                 own established convention for every other
--                 application-validated free-text column (e.g.
--                 `k9_individual_overrides.note`). Cleared (set to NULL),
--                 never carried, when a personnel role changes -- a K9
--                 callsign and a handler callsign mean different things.
--                 Not carried across a fire/re-hire cycle either -- a
--                 fresh personnel row always starts with NULL here.
--   `granted_by`  VARCHAR(50)  -- citizenid of the high-command officer who
--                 made this assignment, same shape/semantics as
--                 `k9_certifications.granted_by`.
--   `granted_at`  DATETIME, DEFAULT CURRENT_TIMESTAMP.
--   `cleared_by`  VARCHAR(50), NULLABLE -- citizenid of whoever cleared
--                 this row (a Fire action's best-effort personnel-row
--                 cleanup, ROSTER_SPEC.md §6/§7), OR a non-citizenid
--                 'system:...' sentinel, mirroring
--                 `k9_certifications.revoked_by`'s own identical
--                 precedent -- no FK/format constraint, same reasoning.
--                 NULL until cleared.
--   `cleared_at`  DATETIME, NULLABLE.
--   `active`      TINYINT(1), NOT NULL, DEFAULT 1 -- 1 = currently on a
--                 roster, 0 = historical/cleared row, matching
--                 `k9_certifications.active`'s exact semantics.
--
-- TWO GENERATED HELPER COLUMNS (derived only, never written directly by
-- app code), same VIRTUAL/NULL-when-inactive technique
-- `k9_certifications.active_cert_key` already established in this schema:
--
--   `active_personnel_key` VARCHAR(105) -- NULL for every inactive row,
--   `citizenid::job` for an active one. Backs
--   `uq_one_active_personnel_per_job`, the DB-level backstop for
--   ROSTER_SPEC.md §3's "exactly ONE active row per (citizenid, job)"
--   invariant -- the identical technique, and the identical width
--   (VARCHAR(50) + '::' + VARCHAR(50) = 102, rounded to 105), as
--   `k9_certifications.active_cert_key`.
--
--   `active_callsign_key` VARCHAR(70) -- NULL for every inactive row AND
--   for every active row with a NULL callsign (so any number of
--   currently-callsign-less personnel rows in the same department can
--   coexist without colliding), otherwise `job::LOWER(callsign)`. Backs
--   `uq_one_active_callsign_per_job`, the DB-level backstop for
--   ROSTER_SPEC.md §4's COMBINED-NAMESPACE callsign uniqueness decision:
--   one department, one callsign namespace, shared by BOTH rosters --
--   a K9's callsign and a handler's callsign in the same department
--   cannot collide, case-insensitively (the `LOWER(...)` inside the
--   generated expression is what makes the comparison case-insensitive at
--   the DB level, matching server/roster.lua's own application-layer
--   `:lower()` pre-check). Width: VARCHAR(50) job + '::' + LOWER of a
--   12-character callsign = 64, rounded to 70 for headroom, matching this
--   schema's own "round up, don't cut it exactly to the byte" convention.
--
-- WHY NOT ONE COMBINED (citizenid, job, role) INVARIANT INSTEAD OF A BARE
-- (citizenid, job) ONE: `k9_partnerships` needed TWO independent unique
-- constraints because a partnership genuinely has two independent parties
-- that can each only be in one active partnership. A personnel row has
-- only ONE identity axis that needs to be unique -- (citizenid, job) --
-- because `role` is a property OF that one active row, not a second
-- identity. Scoping the unique key to (citizenid, job) rather than
-- (citizenid, job, role) is what makes "at most one active row per
-- (citizenid, job)" also mean "a citizenid cannot be both k9 AND handler
-- in the same department at once" for free (ROSTER_SPEC.md §3's "Both is
-- prevented by construction" claim, acceptance criterion #4) -- a
-- role-scoped key would have allowed exactly that.
--
-- NO FK ANYWHERE IN THIS FILE, matching this schema's own established "no
-- FK, relational integrity enforced at the application layer" convention
-- (see `k9_certifications`' own header in sql/install.sql for the full
-- "why" -- this resource's migration must not depend on qbx_core's schema
-- existing first, and a player-data reset workflow on another resource's
-- table must never be able to fail this table's constraints). In
-- particular: NO FK to `k9_certifications` either, even though every real
-- personnel row is expected to correspond to an active certification --
-- that relationship is enforced and re-verified live, in Lua
-- (server/roster.lua re-checks `K9Store.Cert_GetActiveId` on every
-- mutation, and both roster reads filter on "active certification AND
-- active personnel row" per ROSTER_SPEC.md §7), never at the DB level,
-- for the identical reason `k9_certification_specializations` declares no
-- FK into `k9_certifications` (sql/install.sql's own header on that
-- table).
--
-- LIVES BEHIND `K9Store` LIKE EVERY OTHER TABLE IN THIS SCHEMA (unlike
-- `k9_dog_characters`, which is a deliberate, flagged, temporary
-- exception owned directly by server/dogcharacter.lua) -- this is a
-- brand-new table with no pre-existing accessor anywhere, so there is no
-- reason to duplicate that file's temporary workaround. See
-- server/datastore.lua's own `K9Store.Personnel_*` accessors (added in
-- the same change as this migration) for the real queries this table's
-- shape was derived from.
--
-- WHO NEEDS THIS FILE: every installation running the roster feature --
-- it is brand new, so every existing database lacks it. Running this file
-- is also a safe no-op on a database that already has a same-named table
-- from some unrelated source: server/datastore.lua's own boot-time
-- schema-collision probe (`VerifyTableShapesAgainstKnownSchema`,
-- `EXPECTED_TABLE_COLUMNS['k9_personnel']`, added in the same change as
-- this migration) covers this table exactly like every other one in this
-- schema, forcing the WHOLE resource into memory-only mode on a real name
-- collision rather than silently writing into a table this resource does
-- not own -- see that file's own header for the full "why" and "what this
-- costs" writeup, not repeated here.
--
-- IDEMPOTENT / SAFE TO RE-RUN: a bare `CREATE TABLE IF NOT EXISTS` -- no
-- ALTER, no DROP, never touches an existing row. Safe to run any number of
-- times, in any order relative to install.sql or any other migration file
-- in this folder (this table has no foreign key or other cross-table
-- dependency on anything created by migrations 0001-0019).
--
-- NO DESTRUCTIVE STATEMENT: this file only ever CREATEs; it never DROPs,
-- TRUNCATEs, ALTERs, or rewrites any existing column, table, or row.
--
-- COMPATIBILITY: a brand-new, independent table -- nothing here reads,
-- rewrites, or depends on the shape of any existing row in any other
-- table. Every currently-active certification on an existing server
-- simply has no `k9_personnel` row yet, which resolves to the explicit
-- "Unassigned" bucket (ROSTER_SPEC.md §3/§8) -- no data is migrated,
-- converted, or guessed, because there is no reliable signal in the
-- existing schema to guess K9-vs-Handler from. Nothing about any existing
-- citizenid's actual in-game abilities changes the moment this table is
-- created -- every existing certification/permission/feature check is
-- completely untouched by whether a `k9_personnel` row exists for them.
--
-- WORKS WITH `Config.Database.enabled = false` (memory-only mode): this
-- table's own accessors (server/datastore.lua's `K9Store.Personnel_*`)
-- follow the exact same `if DatabaseEnabled('k9_personnel') then <real
-- SQL> else <plain Lua table>` shape every other table in this schema
-- already uses -- roster assignment, role changes, and callsign
-- assignment all keep working for the life of the process, with nothing
-- remembered past a restart. Same honest trade-off this schema already
-- documents for every other table, not a new one for this feature.
--
-- ORDERING: independent of every other table this resource has --
-- `k9_personnel` references no other table's key at all (citizenid/job
-- are plain, unvalidated-by-FK strings everywhere else in this schema
-- already). Applying this file's numeric filename order after
-- install.sql, as this resource's own migrations directory already
-- documents, always satisfies any real ordering requirement.
--
-- Requires MySQL >= 5.7.8 or MariaDB >= 10.2, matching sql/install.sql's
-- own stated floor and every other migration in this folder that declares
-- an indexed virtual generated column (`k9_certifications`,
-- `k9_certification_specializations`, `k9_partnerships`, `k9_permissions`)
-- -- this table joins that list.
--
-- ROLLBACK: see sql/rollback/0020_down.sql -- like every other CREATE-only
-- migration in this schema, it deliberately does nothing (a DROP would
-- destroy real roster history) and instead reports what dropping this
-- table would cost.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_personnel` (
  `id`                    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`             VARCHAR(50)  NOT NULL,
  `job`                   VARCHAR(50)  NOT NULL,
  `role`                  VARCHAR(10)  NOT NULL,                    -- 'k9' | 'handler' -- called personnelRole in code/API, see header
  `callsign`              VARCHAR(12)  DEFAULT NULL,
  `granted_by`            VARCHAR(50)  NOT NULL,
  `granted_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `cleared_by`            VARCHAR(50)  DEFAULT NULL,
  `cleared_at`            DATETIME     DEFAULT NULL,
  `active`                TINYINT(1)   NOT NULL DEFAULT 1,

  `active_personnel_key`  VARCHAR(105)
                            GENERATED ALWAYS AS (
                              CASE WHEN `active` = 1
                                   THEN CONCAT(`citizenid`, '::', `job`)
                                   ELSE NULL
                              END
                            ) VIRTUAL,

  `active_callsign_key`   VARCHAR(70)
                            GENERATED ALWAYS AS (
                              CASE WHEN `active` = 1 AND `callsign` IS NOT NULL
                                   THEN CONCAT(`job`, '::', LOWER(`callsign`))
                                   ELSE NULL
                              END
                            ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- Hot-path index: "what roster row (if any) does citizenid X currently
  -- hold for job Y" -- citizenid leads the index so it also serves "every
  -- roster row citizenid X has ever held, across every job" as a
  -- citizenid-prefix scan, mirroring k9_certifications' own
  -- idx_citizen_job_active exactly.
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),

  -- Admin-path index: "list every active roster row in department X" --
  -- both roster reads (K9 list, Handler list) and the Unassigned-bucket
  -- computation use this, mirroring k9_certifications' own idx_job_active.
  KEY `idx_job_active` (`job`, `active`),

  -- DB-level backstop for "at most one active row per (citizenid, job)"
  -- (ROSTER_SPEC.md §3, acceptance criterion #4) -- closes the
  -- check-then-insert race window the same way
  -- k9_certifications.uq_one_active_cert_per_job does for grants.
  -- server/datastore.lua's K9Store.Personnel_Insert: on a duplicate-key
  -- error against THIS constraint, treat it as "already assigned",
  -- exactly like every other *_Insert accessor's own documented
  -- ThrowDuplicateActiveRow contract.
  UNIQUE KEY `uq_one_active_personnel_per_job` (`active_personnel_key`),

  -- DB-level backstop for the COMBINED-NAMESPACE callsign uniqueness
  -- decision (ROSTER_SPEC.md §4) -- one department, one callsign
  -- namespace, shared by K9s and Handlers alike, compared
  -- case-insensitively (the generated column already applies LOWER()).
  -- server/datastore.lua's K9Store.Personnel_SetCallsign: on a
  -- duplicate-key error against THIS constraint, treat it as
  -- 'callsign_taken' -- the exact outcome ROSTER_SPEC.md §4 requires,
  -- never a silent overwrite of the existing holder.
  UNIQUE KEY `uq_one_active_callsign_per_job` (`active_callsign_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
