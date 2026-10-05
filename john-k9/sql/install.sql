-- =====================================================================
-- john-k9 :: DATABASE REQUIREMENTS -- READ FIRST
--
-- MINIMUM SERVER VERSION: MySQL >= 5.7.8, or MariaDB >= 10.2.
--
-- This is a hard requirement, not a recommendation. Five of the
-- thirty (30) tables below (k9_certifications,
-- k9_certification_specializations, k9_partnerships, k9_permissions,
-- k9_personnel)
-- declare an INDEXED VIRTUAL GENERATED COLUMN backing a UNIQUE KEY
-- (`k9_certifications.active_cert_key`,
-- `k9_certification_specializations.active_spec_key`,
-- `k9_partnerships.active_partner_k9_key` and `active_partner_handler_key`,
-- `k9_permissions.active_permission_key`,
-- `k9_personnel.active_personnel_key` and `active_callsign_key`
-- (migration 0020, ROSTER_SPEC.md §3/§4)) -- the other twenty-five
-- (k9_search_log, k9_progression, k9_runtime_feature_overrides,
-- k9_runtime_override_audit, k9_tablet_theme, k9_tablet_theme_audit,
-- k9_ped_assignments, k9_certification_tiers,
-- k9_certification_tier_capabilities, k9_certification_tier_audit,
-- k9_equipment_shop_locations, k9_equipment_shop_locations_audit,
-- k9_permission_keys, k9_permission_key_audit, k9_equipment_shop_items,
-- k9_equipment_shop_item_audit, k9_xp_tiers, k9_xp_tier_audit,
-- k9_individual_overrides, k9_individual_override_audit,
-- k9_partnership_pair_progress, k9_dog_characters, k9_wellbeing, k9_roles,
-- k9_role_audit) need
-- nothing from this floor and would run on an older server on their own,
-- but this resource has one stated minimum for the schema as a whole, not
-- a per-table one.
-- -- the DB-level backstop for this resource's "at most one active
-- certification per (citizenid, job)", "at most one active partnership
-- per party" and "at most one active permission grant per (citizenid,
-- permission)" invariants. Secondary indexes on virtual generated columns
-- arrived in MySQL 5.7.8 and MariaDB 10.2; nothing older can parse these
-- statements.
--
-- Verified BY EXECUTION against real servers, not by inspection:
--   MySQL 5.6.51   -- FAILS. install.sql aborts at the first generated
--                     column with `ERROR 1064 (42000) ... near 'GENERATED
--                     ALWAYS AS ('`, and leaves the database HALF-BUILT:
--                     only `k9_progression` is created. Do not attempt.
--   MySQL 5.7.44   -- OK (install.sql + migrations 0001-0004 all clean).
--   MySQL 8.0.46   -- OK.
--   MariaDB 10.11  -- OK.
--
-- `k9_permissions` (migration 0005) reuses this exact generated-column /
-- unique-key technique verbatim -- same VARCHAR(105) CONCAT(citizenid,
-- '::', X) VIRTUAL shape already proven above for `k9_certifications` and
-- `k9_partnerships` -- rather than inventing a new one. Its own execution
-- verification (clean install, migration-on-existing-db, re-run
-- idempotency, rollback, and the 20-connection concurrent-grant race) is
-- tracked as a separate pass against the same MySQL 5.7/8.0/MariaDB 10.11
-- targets above; see sql/migrations/0005_create_k9_permissions.sql's own
-- header for status.
--
-- If your host runs MySQL 5.6, upgrade the database server before
-- installing this resource; there is no supported downgrade path for the
-- schema, because the uniqueness guarantees the resource's concurrency
-- safety depends on cannot be expressed without these columns.
--
-- TEXT COLLATION (db-schema pass, 2026-08-25): every `CREATE TABLE` below
-- now states `COLLATE=utf8mb4_unicode_ci` explicitly, matching qbx_core's
-- own declared convention, instead of leaving it unstated and letting each
-- table silently inherit whatever the server's schema/session default
-- happens to be at CREATE time (`utf8mb4_general_ci` on some older
-- defaults, `utf8mb4_0900_ai_ci` on stock MySQL 8, `utf8mb4_unicode_ci` on
-- others) -- the same VARCHAR/TEXT column can therefore land with a
-- different collation depending purely on which server it was installed
-- on, which is the root problem, not any one wrong value. None of this
-- resource's own lookups are affected either way -- every internal query
-- stays within this schema's own now-consistent tables or goes through
-- qbx_core's Lua exports, never a raw SQL join to `players` -- but an
-- operator writing their own report that joins one of these tables to
-- `players` on `citizenid` gets a hard `ERROR 1267: Illegal mix of
-- collations` the moment the two sides disagree. A fresh install via this
-- file now always lands on the same collation regardless of server
-- default, at no cost to anyone. An EXISTING table created before this
-- change keeps whatever collation it already has -- `CREATE TABLE IF NOT
-- EXISTS` does not retroactively convert one, the same convergence rule
-- this file's own header already documents for columns/indexes. Converting
-- an existing table's stored collation is a full table rewrite (`CONVERT
-- TO CHARACTER SET`), not a free metadata change, so it is deliberately an
-- OPT-IN migration rather than part of the default upgrade path -- see
-- `sql/migrations/optional/0012_convert_charset_collation.sql` (CORRECTED
-- path -- this used to say `sql/migrations/0012_...` with no `optional/`
-- segment; that file does not exist at the old path) and that file's own
-- header for the full cost/benefit disclosure and the plain-language
-- version of "do I need to run this" (its own "WHO ACTUALLY NEEDS THIS"
-- section -- CORRECTED: this used to point to a nonexistent "README.md §7").
-- =====================================================================

-- =====================================================================
-- john-k9 :: k9_certifications
--
-- Source of truth for K9 handler certification grants/revocations.
-- See DEVELOPER_REFERENCE.md section 4.3 for full rationale. This table is an
-- append-mostly audit log: granting INSERTs a new row, revoking UPDATEs
-- the existing active row to active = 0 (never deletes), so the full
-- grant/revoke history per citizenid+job is always reconstructable —
-- including revocations issued while the target is offline.
--
-- db-schema review notes (per DEVELOPER_REFERENCE.md 4.3 / 9.1):
--   * citizenid/job/granted_by/revoked_by use the standard qbx_core /
--     QBCore VARCHAR(50) citizenid convention, matched consistently
--     across every citizenid-shaped column in this table.
--   * No FK to a `players` table is declared here on purpose: qbx_core's
--     player table does not live in this repo/resource, and this
--     resource's own migration should not have a hard install-order
--     dependency on qbx_core's schema existing first, nor should a
--     player-data reset/delete workflow on another resource's table be
--     able to fail this table's constraints. Relational integrity to
--     qbx_core players is enforced at the application layer (same
--     convention used by other standalone oxmysql resources).
--   * Two purpose-built indexes below, plus a generated-column unique
--     constraint that gives the "at most one active row per
--     (citizenid, job)" invariant a real DB-level backstop instead of
--     relying on application logic alone — see the column/index
--     comments for exact query patterns each one supports.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once.
--
-- UPGRADING AN EXISTING DATABASE (db-schema pass, 2026-08-24): this file
-- remains the correct thing to run for a brand-new install (it creates
-- every table below in one pass, in final shape, via CREATE TABLE IF NOT
-- EXISTS). It is NOT re-run to pick up a column/index added to an ALREADY
-- EXISTING table on a live database — `CREATE TABLE IF NOT EXISTS` is a
-- complete no-op once the table exists, even if that table's stored
-- definition is missing a column this file's CREATE TABLE now includes
-- (e.g. `k9_partnerships.tenure_bonus_tier_granted`, added below). For
-- that case, apply the ordered, individually-idempotent files under
-- `john-k9/sql/migrations/` (0001, 0002, 0003, ... in filename order)
-- instead — each one is safe to run any number of times and safe to run
-- against a database that already has the change it applies. A fresh
-- install never needs the migrations folder; an existing install upgrading
-- across resource versions runs install.sql once (harmless no-op for
-- anything already present) then every migration file in order.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,                          -- qbx_core / QBCore citizenid convention
  `job`              VARCHAR(50)  NOT NULL,                          -- department job name at grant time (Config.Departments key)
  `granted_by`       VARCHAR(50)  NOT NULL,                          -- citizenid of the certifying officer
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,                      -- citizenid of the revoking officer; NULL until revoked.
                                                                      -- Per DEVELOPER_REFERENCE.md 4.4, may also hold the non-citizenid
                                                                      -- sentinel 'system:job_change' when auto-revoked by
                                                                      -- a department firing rather than a manual revoke.
                                                                      -- No FK/format constraint on this column, so no
                                                                      -- migration change is needed to support the sentinel;
                                                                      -- coder-backend's audit-reading logic should just
                                                                      -- expect it as a valid non-citizenid value.
  `revoked_at`       DATETIME     DEFAULT NULL,

  -- CERTIFICATION DEPTH (DEVELOPER_REFERENCE.md Part A §2 -- coder-backend pass,
  -- landed via sql/migrations/0006_add_k9_certification_lifecycle.sql for
  -- an existing database; included here directly so a FRESH install lands
  -- in the same final shape in one pass, matching this file's own
  -- documented convergence promise). Nullable, free text NOT used --
  -- validated against a small fixed vocabulary (retired / reassigned /
  -- disciplinary / performance / other) at the application layer
  -- (server/certifications.lua's VALID_REVOKE_REASONS), same "no
  -- FK/format constraint in the schema, enforced by the app" convention
  -- `revoked_by`'s own 'system:job_change' sentinel above already
  -- establishes. NULL until revoked, and stays NULL forever for a row
  -- revoked before this column existed (no reason is recoverable for
  -- history that predates it) or for a revoke that simply didn't supply
  -- one (this argument is optional everywhere it is threaded through).
  `revoke_reason`    VARCHAR(20)  DEFAULT NULL,

  -- CERTIFICATION DEPTH (DEVELOPER_REFERENCE.md Part A §9). NULL means "does not
  -- expire" -- the default for EVERY row unless a certifier grants (or
  -- later renews) this citizenid's certification on a server that has
  -- explicitly opted in via `Config.Features.CertificationExpiry = true`.
  -- Every pre-existing row a migration touches stays NULL forever (see
  -- that migration's own COMPATIBILITY section) -- an operator turning
  -- this feature on does not retroactively start a countdown on anyone
  -- already certified. DISCLOSED, ACCEPTED TIMEZONE CAVEAT (same one this
  -- file's own `k9_permissions` comment below already flags for a
  -- hypothetical future expiry column, now realized here): like every
  -- other DATETIME in this schema, this column carries no timezone of its
  -- own -- `server/certifications.lua` reads it back via
  -- `UNIX_TIMESTAMP(expires_at)` and writes it via
  -- `DATE_ADD(NOW(), INTERVAL ? DAY)`, both evaluated against the DB
  -- session's current time zone. This is internally consistent as long as
  -- the DB server's configured time zone does not change after rows are
  -- written; a post-go-live time zone change would skew every stored
  -- expiry by the same delta every other DATETIME-derived calculation in
  -- this schema (e.g. `server/tenure.lua`'s `TIMESTAMPDIFF`) already
  -- silently inherits -- a pre-existing, disclosed limitation of this
  -- schema's DATETIME convention as a whole, not something this column
  -- introduces net-new.
  `expires_at`       DATETIME     DEFAULT NULL,

  `active`           TINYINT(1)   NOT NULL DEFAULT 1,                -- 1 = currently grants access, 0 = historical/revoked row

  -- CERTIFICATION DEPTH (DEVELOPER_REFERENCE.md Part A §5). Fixed, ordinal
  -- 3-step vocabulary (trainee / certified / senior), enforced at the
  -- application layer (server/certifications.lua's TIER_RANK) rather than
  -- a DB-level ENUM/CHECK, same reasoning as `revoke_reason` above.
  -- DEFAULT 'certified' is a DELIBERATE compatibility choice, not an
  -- arbitrary pick: it is the tier that preserves EVERY existing/new
  -- plain-boolean-shaped grant's actual capability unchanged -- an
  -- existing certified handler, or a brand-new grant made by code that
  -- has never heard of tiers, gets exactly the access level this
  -- resource's single-boolean model already granted before this column
  -- existed. Only an explicit, separate SetCertificationTier action ever
  -- moves a row to 'trainee' or 'senior'.
  `tier`             VARCHAR(20)  NOT NULL DEFAULT 'certified',

  -- Generated helper column (derived only, never written directly by
  -- app code): NULL for every inactive/revoked row, and
  -- `citizenid::job` for an active row. MySQL/MariaDB unique indexes
  -- treat every NULL as a distinct value (never collides with another
  -- NULL), so a UNIQUE index on this column lets the database itself
  -- reject a second concurrent INSERT that would create two active
  -- rows for the same (citizenid, job) pair, without changing the
  -- semantics of `active` (still a plain NOT NULL 0/1 flag) and without
  -- ever deleting/blocking historical audit rows.
  `active_cert_key`  VARCHAR(105)
                       GENERATED ALWAYS AS (
                         CASE WHEN `active` = 1
                              THEN CONCAT(`citizenid`, '::', `job`)
                              ELSE NULL
                         END
                       ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- Hot-path index: "does citizenid X hold an active cert for job Y".
  -- Checked on player load, job change, grant, and revoke (per
  -- DEVELOPER_REFERENCE.md 4.3 the result is cached in memory after that, so this
  -- index is NOT hit on every menu-open/spawn request — only on the
  -- less-frequent events that (re)populate the cache).
  --   SELECT id FROM k9_certifications
  --   WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1;
  -- citizenid leads the index so it also serves "full cert history for
  -- citizenid X across all jobs" (WHERE citizenid = ?) as a prefix scan.
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),

  -- Admin-path index: "list all certified handlers in department X"
  -- (DEVELOPER_REFERENCE.md 4.3 rationale). idx_citizen_job_active above cannot serve
  -- this efficiently because job is not its leading column; this index
  -- makes it an index seek instead of a full table scan:
  --   SELECT citizenid, granted_by, granted_at FROM k9_certifications
  --   WHERE job = ? AND active = 1;
  KEY `idx_job_active` (`job`, `active`),

  -- CERTIFICATION DEPTH (DEVELOPER_REFERENCE.md Part A §9). Not on this
  -- resource's own hot path (the expiry sweep walks currently-connected
  -- players via the in-memory cache -- see server/certifications.lua's
  -- header -- never a live SQL scan over this column); added for the
  -- natural admin/report query this column invites ("list every
  -- certification expiring in the next N days across the whole roster"),
  -- matching idx_job_active's own "add the index the query needs"
  -- convention immediately above.
  KEY `idx_expires_at` (`expires_at`),

  -- DB-level backstop for the app-enforced "one active row per
  -- (citizenid, job)" invariant. Closes the check-then-insert race
  -- window (e.g. two near-simultaneous grant requests for the same
  -- target/job) that pure application-level enforcement cannot fully
  -- close on its own. coder-backend: on the grant INSERT, treat a
  -- duplicate-key error on this constraint (MySQL/MariaDB error 1062)
  -- identically to the normal pre-check "already certified" no-op —
  -- it means another request won the race, not a real failure.
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_certification_specializations
--
-- DEVELOPER_REFERENCE.md Part B §11 -- named K9 training specializations
-- (narcotics / explosives / patrol / ..., catalog in
-- `Config.K9Specializations`) layered on top of an existing ACTIVE
-- `k9_certifications` row. Landed via
-- `sql/migrations/0006_add_k9_certification_lifecycle.sql` for an
-- existing database; included here directly so a fresh install lands in
-- the same final shape in one pass -- see that migration file's own
-- header for the full design rationale (why a sibling table and not a
-- column, why no FK to `k9_certifications`, why the same generated-column
-- unique-key technique as `k9_certifications.active_cert_key` /
-- `k9_permissions.active_permission_key` above/below), not repeated a
-- third time here.
--
-- Same append-mostly-audit-log shape as `k9_certifications`/
-- `k9_permissions`: granting a specialization INSERTs a new row; revoking
-- (manually, or automatically when the base certification itself is
-- revoked or lapses -- server/certifications.lua's
-- RevokeAllSpecializationsForCitizenJob) UPDATEs the existing active row
-- to `active = 0`, never deletes.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, see
-- `john-k9/sql/migrations/0006_add_k9_certification_lifecycle.sql`.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_certification_specializations` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,
  `job`              VARCHAR(50)  NOT NULL,
  `specialization`   VARCHAR(30)  NOT NULL,          -- a key from Config.K9Specializations, validated at the application layer
  `granted_by`       VARCHAR(50)  NOT NULL,
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,

  -- Generated helper column, same VIRTUAL/NULL-when-inactive technique as
  -- `k9_certifications.active_cert_key` above (see that column's own
  -- comment for the full "why a unique index on a generated column, why
  -- NULLs never collide" reasoning).
  `active_spec_key`  VARCHAR(135)
                       GENERATED ALWAYS AS (
                         CASE WHEN `active` = 1
                              THEN CONCAT(`citizenid`, '::', `job`, '::', `specialization`)
                              ELSE NULL
                         END
                       ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- "Every active specialization citizenid X holds for job Y" -- used by
  -- QueryActiveSpecializations (tablet/roster reads) and by the
  -- cascade-revoke-on-base-cert-loss bulk UPDATE
  -- (RevokeAllSpecializationsForCitizenJob). citizenid leads the index so
  -- it also serves "every specialization citizenid X has ever held,
  -- across every job" as a prefix scan:
  --   SELECT specialization FROM k9_certification_specializations
  --   WHERE citizenid = ? AND job = ? AND active = 1;
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),

  -- Admin-path index: "every citizenid currently holding specialization X
  -- in department Y" (mirrors `k9_certifications.idx_job_active`'s own
  -- rationale, extended one column):
  --   SELECT citizenid FROM k9_certification_specializations
  --   WHERE job = ? AND specialization = ? AND active = 1;
  KEY `idx_job_spec_active` (`job`, `specialization`, `active`),

  -- DB-level backstop for "at most one ACTIVE (citizenid, job,
  -- specialization) row" -- same 20-connection-race protection
  -- `uq_one_active_cert_per_job` gives `k9_certifications` above, scoped
  -- to a 3-part key instead of a 2-part one.
  UNIQUE KEY `uq_one_active_spec_per_citizen_job` (`active_spec_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_search_log
--
-- Persistent audit log for the Phase 2 contraband-search action
-- (`john-k9:server:searchTarget`, john-k9/DEVELOPER_REFERENCE.md#contraband-search,
-- DEVELOPER_REFERENCE.md §11.4 item 2's "STILL-OPEN" list). Added per
-- db-schema's Phase 2 review of the open question both of those raised:
-- does a search action warrant the same kind of durable accountability
-- trail `k9_certifications` already provides for grants/revokes?
--
-- db-schema recommendation (recorded here, not just in review notes):
-- YES -- log it, for a materially different reason than why
-- k9_certifications is persisted. k9_certifications persists a
-- *permission grant* -- current authorization state that must survive a
-- restart and be checked/revoked while the target is offline; its
-- `active` row IS the access-control mechanism, not just a record of
-- one. A search event is not that: nothing ever re-checks a past search
-- to decide whether a *future* search is allowed (rate limiting is
-- handled entirely by the in-memory cooldown tables in
-- server/search.lua, which is correct -- cooldowns are ephemeral by
-- nature and do not need to survive a restart). What tips this table
-- into "persist it" territory instead is the same real-world category
-- server/certifications.lua's header already names for its own audit
-- trail: in-fiction accountability for a disputed claim. "Did this K9
-- unit actually search my vehicle, or fabricate probable cause after
-- the fact" is a dispute a server admin has no way to resolve without a
-- durable record -- unlike a certification dispute, there is no
-- "current state" left behind anywhere (not in ox_inventory, not on the
-- vehicle, not on the player) for an admin to inspect after the fact and
-- reconstruct what happened. The DB-write cost is not a real concern:
-- writes here are gated behind the same human-paced action (an officer
-- manually initiating a search, already throttled by
-- `Config.SearchZones.searchCooldownMs` plus the per-source
-- cooldown/mutex in server/search.lua) that already rate-limits the far
-- more expensive ox_inventory round trip each row corresponds to --
-- this INSERT rides along a path that is already throttled, it does not
-- open a new hot path of its own.
--
-- Scope: only searches that reach a real inventory-read attempt are
-- logged (`result` = 'found' | 'clean' | 'search_failed', corresponding
-- to searchTarget's own step 11+ outcomes) -- NOT early rejections
-- ('feature_disabled', 'no_access', 'search_in_progress', 'on_cooldown',
-- 'too_far', 'invalid_target'). Those never touched the target's real
-- inventory and carry no forensic value for the "did a search actually
-- happen" question this table exists to answer; logging them would only
-- add noise and write volume for no accountability benefit. If a future
-- need emerges to also audit e.g. repeated 'too_far' probing as a
-- harassment signal, that is a deliberately separate decision, not
-- assumed by this table's current scope.
--
-- Shape deliberately differs from k9_certifications: this is a plain
-- append-only log (INSERT-only, never UPDATE, no `active` flag, no
-- revocation semantics) -- there is no "at most one X" invariant here
-- for a generated column + unique index to backstop, the way
-- `active_cert_key` backstops k9_certifications' "one active cert per
-- (citizenid, job)" rule. A resolved target being searched many times
-- over its lifetime is the entire point of a log, not a race to
-- prevent -- adding that kind of backstop here would be decoration, not
-- protection, so none is added.
--
-- No FK to a `players`/vehicle-ownership table, for the exact same
-- reason k9_certifications declares none (see that table's own comment
-- above): this resource's migration must not depend on qbx_core's
-- schema existing first, and a player-data reset workflow on another
-- resource's table must never be able to fail this table's constraints.
-- Relational integrity to qbx_core players / vehicle ownership is
-- enforced at the application layer, same convention as above.
--
-- Integration note for coder-backend (server/search.lua): write exactly
-- one row per completed search attempt, at the point in
-- HandleSearchTarget's validation-order body where the result is already
-- known (after the tier lookup for 'found'/'clean', or immediately upon
-- the pcall failure for 'search_failed') -- do NOT await this INSERT
-- inline before returning to the caller; fire it non-blockingly
-- (`MySQL.insert(...)` without `.await`) so a slow/contended DB write
-- never delays or risks the search callback's own response to the
-- requesting officer. Resolve `searcher_citizenid`/`searcher_job` via
-- `exports.qbx_core:GetPlayer(source).PlayerData` (same pattern
-- server/certifications.lua already uses for granter/target citizenid
-- lookups) -- prefer whatever job value `HasK9Access` already resolved
-- for this source over re-deriving it, per this resource's existing
-- "single source of truth" convention. Resolve `target_citizenid` for a
-- person search the same way, from the target's live server id
-- (`exports.qbx_core:GetPlayer(targetServerId).PlayerData.citizenid`),
-- not the raw ped netId.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_search_log` (
  `id`                 INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `searcher_citizenid` VARCHAR(50)  NOT NULL,                      -- qbx_core / QBCore citizenid convention; the certified officer who performed the search
  `searcher_job`       VARCHAR(50)  NOT NULL,                      -- department job at time of search (Config.Departments key) -- same rationale as k9_certifications.job
  `target_type`        ENUM('vehicle', 'person') NOT NULL,         -- mirrors searchTarget's own targetType argument; closed set, so ENUM (not VARCHAR) is the correct type
  `target_plate`       VARCHAR(15)  DEFAULT NULL,                  -- populated only when target_type = 'vehicle' (GetVehicleNumberPlateText, resolved server-side -- never client-supplied)
  `target_citizenid`   VARCHAR(50)  DEFAULT NULL,                  -- populated only when target_type = 'person' (resolved server-side from the target's live server id -- never client-supplied)
  `result`             ENUM('found', 'clean', 'search_failed') NOT NULL,
                                                                    -- 'found'/'clean' = a real inventory read completed (contrabandFound true/false);
                                                                    -- 'search_failed' = the inventory read itself errored/returned nil (searchTarget's
                                                                    -- reason = 'search_failed' path) -- kept as its own distinct value, never
                                                                    -- collapsed into 'clean', carrying john-k9/DEVELOPER_REFERENCE.md#contraband-search's
                                                                    -- explicit "never collapse search_failed into contrabandFound=false" requirement
                                                                    -- all the way down into the audit record itself.
  `total_weight`       INT UNSIGNED DEFAULT NULL,                  -- the real computed totalWeight for 'found'/'clean' (0 for 'clean'); NULL for
                                                                    -- 'search_failed', where no real number was ever computed -- NULL here means
                                                                    -- "unknown", not "zero", so a query summing this column can't silently
                                                                    -- misrepresent a failed check as a clean one.
  `alert_tier`         VARCHAR(32)  DEFAULT NULL,                  -- Config.ContrabandAlertTiers key looked up for 'found'/'clean' results
                                                                    -- (e.g. 'whine', 'aggressive_bark', 'clean'); NULL for 'search_failed'
  `searched_at`        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),

  -- Officer-accountability query: "every search citizenid X has performed,
  -- most recent first" -- the other half of the dispute question this
  -- table exists for ("was this specific K9 unit even in a position to
  -- have searched anyone that shift").
  --   SELECT * FROM k9_search_log
  --   WHERE searcher_citizenid = ? ORDER BY searched_at DESC;
  KEY `idx_searcher_searched_at` (`searcher_citizenid`, `searched_at`),

  -- Target-accountability query, vehicle side -- the primary dispute
  -- query this table is built to answer: "was vehicle with plate X ever
  -- actually searched, by whom, when, and with what result".
  --   SELECT * FROM k9_search_log
  --   WHERE target_plate = ? ORDER BY searched_at DESC;
  KEY `idx_target_plate_searched_at` (`target_plate`, `searched_at`),

  -- Same query shape, person side.
  --   SELECT * FROM k9_search_log
  --   WHERE target_citizenid = ? ORDER BY searched_at DESC;
  KEY `idx_target_citizenid_searched_at` (`target_citizenid`, `searched_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_partnerships
--
-- OWNER FILE NOW EXISTS -- `server/partnership.lua` (coder-backend, this
-- pass) reads and writes this table for real; this comment block is
-- updated in place per its own prior instruction to do so once that
-- happened, rather than left describing a since-resolved "ahead of
-- implementation" state (same "don't leave stale framing around a
-- resolved item" standard DEVELOPER_REFERENCE.md's own revision history already
-- applies to itself). The schema below is UNCHANGED from the version
-- landed ahead of implementation -- `server/partnership.lua` was written
-- to match these real columns/constraints exactly, not the other way
-- around; see that file's own header for the schema-to-code mapping.
--
-- Governing spec: DEVELOPER_REFERENCE.md section 12.0, item 7 ("Handler-
-- partnership link: reuse active leash pairing, or a new persistent
-- registry?"), resolved in Revision 5 (coder-architect) as Option B: a
-- new, DB-backed, mutually-consented K9/handler partnership registry,
-- independent of momentary leash state. See that section for the full
-- rationale on why `server/main.lua`'s in-memory `LeashPairs` was
-- rejected for this purpose (it is transient, session-scoped state for
-- a movement-restriction mechanic, and would leave `HandlerDownDefense`
-- non-functional for its own primary use case -- an off-leash foot
-- chase, where the pair is deliberately unleashed).
--
-- Owner file: `server/partnership.lua`. Per DEVELOPER_REFERENCE.md section 12.0
-- item 7 and section 12.3, that file:
--   * handles the "Partner Up" consent handshake (mirroring
--     `server/main.lua`'s `PendingLeashRequests` pattern -- a TTL'd
--     pending-request slot, one live request per target, consumed on
--     any response -- NOT `k9_certifications`' grant-hierarchy model,
--     since partnership is a peer relationship between two already-
--     eligible parties, not a permission grant),
--   * maintains an in-memory `Partnerships[citizenid]` cache
--     (`{ partner = partnerCitizenid, isK9 = boolean, active = true }`)
--     refreshed via a `RefreshPartnershipCache` modeled on
--     `certifications.lua`'s `RefreshCertificationCache` (same
--     pcall/fail-closed discipline), populated on `PlayerLoaded` and via
--     an `onResourceStart` backfill loop mirroring
--     `certifications.lua`'s own restart-recovery pattern,
--   * exposes a `ForceBreakPartnershipForCitizenId` teardown (citizenid-
--     keyed, not source-keyed like leash's own equivalent -- see that
--     function's own doc comment in server/partnership.lua for why an
--     offline-capable teardown is a REQUIRED divergence from leash's
--     shape here, not an optional one), called alongside every existing
--     `ForceDetachLeashForSource` / `ForceDetachOfficerLeashForSource`
--     call site in `server/certifications.lua` (K9-role cert revocation, either
--     party's department change) -- automatic, no-consent-needed
--     termination, mirroring the leash's own "no unbounded trap" rule.
--
-- Modeled directly on `k9_certifications` above (same file, read in
-- full before this table was written), per DEVELOPER_REFERENCE.md's explicit
-- instruction to reuse that table's conventions rather than invent new
-- ones: append-mostly audit rows (establishing INSERTs a new row,
-- ending UPDATEs the existing active row to active = 0, never deletes),
-- an `active` flag, `established_by`/`ended_by` citizenid-shaped
-- attribution columns (mirroring `granted_by`/`revoked_by`), a
-- CREATE TABLE IF NOT EXISTS for idempotent re-runs, and
-- VARCHAR(50)/DATETIME typing matching the qbx_core/QBCore citizenid
-- convention used throughout this file.
--
-- Where this table's shape necessarily DIFFERS from k9_certifications,
-- because a partnership is a relationship between TWO citizenids rather
-- than one citizenid's grant against one job:
--   * two citizenid columns (`k9_citizenid`, `handler_citizenid`)
--     instead of one citizenid + one job, and
--   * TWO generated-column unique constraints instead of one --
--     `k9_certifications`' single `active_cert_key` only had to prevent
--     two simultaneous active rows for the same (citizenid, job) pair.
--     Here, per DEVELOPER_REFERENCE.md section 12.0 item 7's explicit call-out,
--     BOTH "at most one active partnership per K9 citizenid" AND "at
--     most one active partnership per handler citizenid" must hold
--     independently -- a single combined key (e.g. on the concatenated
--     pair) would not stop a K9 who is already partnered with handler A
--     from also picking up an active row with handler B, nor the
--     symmetric case on the handler side. Each side therefore gets its
--     own VIRTUAL generated column (NULL whenever the row is inactive,
--     the real citizenid whenever it is active) and its own UNIQUE KEY,
--     exactly doubling `k9_certifications`' single-constraint pattern
--     rather than trying to force one constraint to cover both
--     invariants at once.
--   * `ended_by` may, like `k9_certifications.revoked_by`, hold a
--     non-citizenid sentinel (e.g. `'system:leash_force_detach'`,
--     `'system:cert_revoked'`, `'system:job_change'`) when
--     `server/partnership.lua`'s automatic-teardown path ends a
--     partnership rather than either party doing so directly -- no
--     FK/format constraint is placed on this column for the same reason
--     `k9_certifications` places none on `revoked_by`.
--
-- `tenure_bonus_tier_granted` (db-schema pass, 2026-08-24): ONE new column,
-- added per `server/tenure.lua`'s own header ("WHY ONE NEW COLUMN IS
-- UNAVOIDABLE") -- that file's real SELECT/UPDATE text was read directly
-- (not inferred from its header prose) and this column matches it exactly:
-- name, type, NOT NULL, and DEFAULT 0. It is the highest 1-based index into
-- `Config.Partnership.TenureBonus.milestones` already paid out as a
-- one-time XP bonus for THIS partnership row (0 = none yet). Without a
-- durable marker here, `server/tenure.lua`'s periodic milestone check would
-- re-grant every already-earned milestone for every still-active,
-- past-threshold partnership on every resource/server restart -- an
-- ordinary, frequent event, not a rare edge case (same class of bug this
-- file's own `k9_progression` table below was added to close for XP
-- persistence generally). Written ONLY by `server/tenure.lua`, via an
-- optimistic `UPDATE ... WHERE tenure_bonus_tier_granted = <old value>`
-- race guard -- never decremented, never reset in place; a NEW partnership
-- row (a break + re-form always INSERTs a fresh row, per this table's own
-- append-mostly design above) always starts at this column's DEFAULT 0,
-- which is how tenure resets across a break/re-form with zero extra code.
-- TINYINT UNSIGNED is sized for the real domain (a handful of milestones,
-- proposed as 3 in `server/tenure.lua`'s closing comment block) while still
-- leaving headroom (0-255) for future milestones without a second widening
-- migration. `server/tenure.lua`'s own queries are pcall-wrapped and
-- degrade to a silent no-op if this column is missing, so adding it here is
-- backward-compatible with a database that has not applied it yet -- but
-- see `john-k9/sql/migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql`
-- for the companion ALTER TABLE this exact addition requires on any
-- database where `k9_partnerships` already exists (CREATE TABLE IF NOT
-- EXISTS below does not retroactively add a column to an existing table).
--
-- No FK to a `players` table is declared here, for the exact same
-- reason `k9_certifications` and `k9_search_log` above declare none:
-- this resource's migration must not depend on qbx_core's own schema
-- existing first, and a player-data reset/delete workflow on another
-- resource's table must never be able to fail this table's constraints.
-- Relational integrity to qbx_core players is enforced at the
-- application layer, same convention used throughout this file.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_partnerships` (
  `id`                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `k9_citizenid`        VARCHAR(50)  NOT NULL,                     -- citizenid of the party currently playing the K9-role ped at establishment time
  `handler_citizenid`   VARCHAR(50)  NOT NULL,                     -- citizenid of the party currently playing the certified-handler role
  `established_by`      VARCHAR(50)  NOT NULL,                     -- citizenid of whichever party's client INITIATED the "Partner Up" request
                                                                     -- (mutual consent is still required from the other party before this row
                                                                     -- is written -- see server/partnership.lua's pending-request handshake --
                                                                     -- this column records who asked first, not who "granted" anything).
  `established_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `ended_by`            VARCHAR(50)  DEFAULT NULL,                 -- citizenid of whichever party ended the partnership, OR a non-citizenid
                                                                     -- 'system:...' sentinel when server/partnership.lua's automatic-teardown
                                                                     -- path ends it (leash-force-detach call sites, cert revocation, department
                                                                     -- change) -- NULL until ended. See k9_certifications.revoked_by above for
                                                                     -- the identical sentinel convention this column mirrors.
  `ended_at`            DATETIME     DEFAULT NULL,
  `active`              TINYINT(1)   NOT NULL DEFAULT 1,           -- 1 = currently a live partnership, 0 = historical/ended row

  `tenure_bonus_tier_granted` TINYINT UNSIGNED NOT NULL DEFAULT 0, -- highest 1-based index into
                                                                     -- Config.Partnership.TenureBonus.milestones already paid
                                                                     -- out for THIS row; 0 = none yet. See this table's own
                                                                     -- header comment above for the full rationale
                                                                     -- (server/tenure.lua) and the companion migration file
                                                                     -- for databases where this table already existed.

  -- Generated helper columns (derived only, never written directly by
  -- app code): NULL for every inactive/ended row, and the respective
  -- citizenid for an active row. Two separate columns/constraints are
  -- required here, unlike k9_certifications' single active_cert_key --
  -- see the header comment above for why one combined key cannot cover
  -- both "one active partnership per K9" and "one active partnership
  -- per handler" invariants at once.
  `active_partner_k9_key`      VARCHAR(50)
                                  GENERATED ALWAYS AS (
                                    CASE WHEN `active` = 1
                                         THEN `k9_citizenid`
                                         ELSE NULL
                                    END
                                  ) VIRTUAL,
  `active_partner_handler_key` VARCHAR(50)
                                  GENERATED ALWAYS AS (
                                    CASE WHEN `active` = 1
                                         THEN `handler_citizenid`
                                         ELSE NULL
                                    END
                                  ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- Hot-path index, K9 side: "does citizenid X (as a K9) currently have
  -- an active partner". Also serves "full partnership history for K9
  -- citizenid X" as a prefix scan (WHERE k9_citizenid = ?).
  --   SELECT * FROM k9_partnerships
  --   WHERE k9_citizenid = ? AND active = 1 LIMIT 1;
  KEY `idx_k9_citizenid_active` (`k9_citizenid`, `active`),

  -- Hot-path index, handler side: the symmetric lookup for the other
  -- role in the pair.
  --   SELECT * FROM k9_partnerships
  --   WHERE handler_citizenid = ? AND active = 1 LIMIT 1;
  KEY `idx_handler_citizenid_active` (`handler_citizenid`, `active`),

  -- DB-level backstop, K9 side: closes the check-then-insert race window
  -- (two near-simultaneous "Partner Up" acceptances naming the same K9
  -- citizenid) the same way k9_certifications' uq_one_active_cert_per_job
  -- closes it for grants. coder-backend/server/partnership.lua: on the
  -- establishing INSERT, treat a duplicate-key error on either of these
  -- two constraints (MySQL/MariaDB error 1062) as "target already has an
  -- active partnership, reject the request" -- NOT as an unexpected
  -- failure to surface as a generic error.
  UNIQUE KEY `uq_one_active_partnership_per_k9` (`active_partner_k9_key`),

  -- DB-level backstop, handler side -- the second, independent
  -- invariant this table has that k9_certifications does not need
  -- (see header comment: a certification's invariant is scoped to a
  -- single citizenid; a partnership's is scoped to TWO).
  UNIQUE KEY `uq_one_active_partnership_per_handler` (`active_partner_handler_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_progression
--
-- SCHEMA LANDING BEHIND ITS OWN IMPLEMENTATION -- deliberately noted, not
-- swept under the rug. `server/progression.lua` (Phase 4,
-- `Config.Features.XPProgression`) shipped already reading and writing
-- this exact table -- `SELECT xp FROM k9_progression WHERE citizenid = ?
-- LIMIT 1` and `INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?)
-- ON DUPLICATE KEY UPDATE ...` -- before this table existed anywhere in
-- this migration file. Both call sites are pcall-wrapped (per that file's
-- own "a DB failure must never surface as a caller-visible failure"
-- posture for a non-security-relevant read/write), so the missing table
-- did NOT throw or appear in any obvious error path: every award silently
-- no-op'd at the DB layer (the in-memory K9XP cache still worked, so
-- gameplay looked correct for the remainder of a session) while
-- `LoadXPForCitizenid` silently fell back to a logged-but-easy-to-miss
-- "query failed" line and a 0-XP baseline on every reconnect/restart. If
-- `Config.Features.XPProgression` was ever flipped to `true` against a
-- database missing this table, no K9's XP would have persisted a single
-- point across a restart, with nothing forcing that fact into view. This
-- table closes that gap. THE SPEC/DESIGN ARTIFACT GOVERNING ITS SHAPE
-- PREDATES THIS EDIT: this `CREATE TABLE` is intentionally the same shape
-- already reviewed and sketched (not applied) in
-- john-k9/DEVELOPER_REFERENCE.md#xp-schema, derived here directly
-- from server/progression.lua's real, currently-shipping queries rather
-- than re-derived from scratch -- the two agree because the sketch is
-- what that file was written against.
--
-- Governing spec: DEVELOPER_REFERENCE.md section 13.4.1 (`Config.Features.
-- XPProgression`), and john-k9/DEVELOPER_REFERENCE.md#xp-schema's own
-- persistence-decision note (sections 2-4) for the full "why a table, not
-- qbx_core metadata" rationale -- restated briefly here: (1) atomic
-- accumulation via a single `INSERT ... ON DUPLICATE KEY UPDATE
-- xp = xp + VALUES(xp)` needs a real UPSERT target, not a Lua-side
-- metadata read-modify-write race across concurrent XP-award sources
-- (search/tracking/combat success paths); (2) offline correction/
-- inspection must work without loading another player's full metadata
-- blob out of band; (3) admin/ops queryability ("list every K9 at Elite
-- tier," "average XP in department X") without scanning every player's
-- JSON. Same three reasons DEVELOPER_REFERENCE.md section 4.3 already accepted once for
-- `k9_certifications` over metadata.
--
-- Owner file: `server/progression.lua`. That file's own header documents
-- the full event/callback contract; the two queries relevant to this
-- table's shape are:
--   SELECT xp FROM k9_progression WHERE citizenid = ? LIMIT 1;
--   INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?)
--     ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP;
-- The second parameter of the INSERT is the per-award DELTA (e.g. a
-- configured `Config.XP.awards[actionKey]` value, always a positive
-- integer per config.lua's current award table), NOT the new running
-- total -- `VALUES(xp)` on the `ON DUPLICATE KEY UPDATE` branch refers to
-- that just-bound delta, giving a single-statement atomic
-- increment-or-create with no separate SELECT-then-UPDATE round trip and
-- no read-modify-write race across concurrent award sources. This is WHY
-- `citizenid` below must be a real UNIQUE/PRIMARY key: an
-- `ON DUPLICATE KEY UPDATE` against a column with no unique constraint
-- backing it does not upsert at all -- MySQL/MariaDB would simply INSERT
-- a brand-new row every time, silently accumulating one row per award
-- per citizenid instead of one row per citizenid, and `SELECT ... LIMIT 1`
-- would then return whichever row happens to sort first rather than the
-- citizenid's real total. `citizenid` is declared PRIMARY KEY for exactly
-- this reason.
--
-- Scope: ONE ROW PER CITIZENID, not per (citizenid, job) -- per
-- server/progression.lua's own header ("XP survives a department change,
-- unlike k9_certifications") and config.lua's `Config.XP.
-- scopePerCitizenidOrJob` comment (currently only 'citizenid' is
-- implemented; 'job' is flagged there as a still-open product call, per
-- DEVELOPER_REFERENCE.md section 13.6 item 2 -- NOT guessed at here). If that call
-- is ever made, the fix is a migration on this table (composite
-- `PRIMARY KEY (citizenid, job)` instead of `citizenid` alone, mirroring
-- `k9_certifications`' job-scoping), not a rewrite.
--
-- Deliberately NOT an append-only log like `k9_search_log`: this is a
-- live profile row UPDATEd in place on every award (an atomic increment),
-- not an audit trail of individual award events. Whether a separate
-- append-only `k9_xp_log`-style table is also worth adding for
-- anti-cheat/dispute auditing is a distinct, still-open question
-- (john-k9/DEVELOPER_REFERENCE.md#xp-schema) -- not
-- decided or added here.
--
-- `xp`'s tier is intentionally NOT computed in SQL (no generated column
-- the way `k9_certifications.active_cert_key` is generated):
-- `Config.XPTiers` is code-side and config-driven; server/progression.lua's
-- `ResolveTier` walks it in Lua exactly the way `server/search.lua` walks
-- `Config.ContrabandAlertTiers`. Baking tier thresholds into a SQL CASE
-- expression here would create a second, driftable copy of the same
-- boundaries config.lua already owns.
--
-- No FK to a `players` table, for the identical reason `k9_certifications`
-- and `k9_search_log` above declare none (see either table's header
-- comment): this resource's migration must not depend on qbx_core's own
-- schema existing first, and a player-data reset/delete workflow on
-- another resource's table must never be able to fail this table's
-- constraints. Relational integrity to qbx_core players is enforced at
-- the application layer, same convention used throughout this file.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once -- including against a
-- database that has already been running with
-- `Config.Features.XPProgression` enabled and this table silently
-- missing: this migration only ever CREATEs, never DROPs/rewrites, so
-- applying it introduces no destructive step against any pre-existing
-- production data (there was never any real row to lose here in the
-- first place, since every prior write attempt failed silently at the
-- DB layer).
--
-- `handler_xp` ADDED (owner-directed "partners and levels" tablet tab,
-- handler half; server/progression.lua's AwardHandlerXP/GetHandlerXPTier,
-- Config.Features.HandlerXPProgression). A SECOND, INDEPENDENT accumulated
-- total on this SAME row -- not a second table, and not a shared reading
-- of `xp` above -- because a citizenid's standing as a HANDLER (certifying,
-- treating, deploying kennels, partnership tenure) is earned by different
-- actions than its standing as a K9 (search/track/bite/takedown), and
-- blending them into one number would let either role's grinding silently
-- unlock the other role's effects with no matching effort in that role.
-- See Config.HandlerXPTiers' own header (config.lua) for the full "why a
-- second total, not a second reading of the same one" reasoning, and
-- sql/migrations/0017_add_k9_progression_handler_xp.sql for the migration
-- that adds this column to an EXISTING database (this CREATE TABLE only
-- ever helps a brand-new install -- same "install.sql has final shape, a
-- migration backfills an existing DB" convention this table's own header
-- already states for `idx_xp`, migration 0009). Same UNSIGNED/DEFAULT 0
-- shape as `xp`, for the identical reasons.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_progression` (
  `citizenid`  VARCHAR(50)  NOT NULL,                    -- qbx_core / QBCore citizenid convention, matches every other k9_* table
  `xp`         INT UNSIGNED NOT NULL DEFAULT 0,          -- accumulated K9 total; source of truth for Config.XPTiers lookups
                                                          -- (server/progression.lua's ResolveTier). UNSIGNED guards against a
                                                          -- negative value at the type level, but is not a substitute for
                                                          -- app-layer clamping if a future "reduce/reset XP" admin path is
                                                          -- ever added (see john-k9/DEVELOPER_REFERENCE.md#xp-schema) -- no
                                                          -- such path exists in this codebase today.
  `handler_xp` INT UNSIGNED NOT NULL DEFAULT 0,          -- accumulated HANDLER total, independent of `xp` above; source of truth
                                                          -- for Config.HandlerXPTiers lookups (server/progression.lua's
                                                          -- ResolveHandlerTier). See this table's own header note on why this
                                                          -- is a second column, not a second reading of `xp`.
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                                                          -- bumped by the ON UPDATE clause AND explicitly re-set by
                                                          -- progression.lua's own UPSERT (`updated_at = CURRENT_TIMESTAMP`
                                                          -- in the ON DUPLICATE KEY UPDATE branch) -- belt-and-suspenders,
                                                          -- but harmless since both always agree; a cheap "is this K9's
                                                          -- progression stale/abandoned" signal without needing a
                                                          -- separate log table.

  PRIMARY KEY (`citizenid`),
  -- `citizenid` is the PRIMARY KEY, not a surrogate `id` + separate UNIQUE
  -- KEY the way `k9_certifications`/`k9_search_log`/`k9_partnerships` use
  -- an AUTO_INCREMENT id -- this table is a one-row-per-citizenid live
  -- profile, not an append-mostly audit log, so there is no historical
  -- row to preserve alongside the "current" one and no reason for a
  -- separate identity column. This IS the unique key
  -- `INSERT ... ON DUPLICATE KEY UPDATE` above depends on to upsert
  -- correctly instead of silently accumulating duplicate rows per
  -- citizenid -- see the integration note above.

  -- ADDED via sql/migrations/0009_add_k9_progression_idx_xp.sql
  -- (DEVELOPER_REFERENCE.md Part A Tier C §10, server/leaderboard.lua's
  -- `/k9stats`). PREVIOUSLY documented here as "optional, not added" --
  -- that was correct until this query actually got built. VERIFIED BY
  -- REAL EXPLAIN, not assumed (see migration 0009's own header for the
  -- exact numbers): without this index, `SELECT citizenid, xp FROM
  -- k9_progression ORDER BY xp DESC LIMIT ?` is `type=ALL,
  -- Extra=Using filesort` -- a full table scan PLUS a sort of every row,
  -- on every single invocation, that gets WORSE as the player base grows
  -- (confirmed identical query cost at both 20,000 and 150,000 rows
  -- WITHOUT this index -- i.e. before it, the cost scales with table
  -- size; after it, it does not). With it: `type=index, key=idx_xp,
  -- Extra=Using index` -- InnoDB secondary indexes always carry the
  -- table's primary key alongside the indexed column, so this index alone
  -- already contains both columns `/k9stats` selects (`xp`, `citizenid`),
  -- a genuine covering index needing zero lookups into the primary-key
  -- index per returned row. Plain, non-unique, single-column: `xp` is not
  -- unique across citizenids (many K9s can share a total, especially near
  -- 0) and `/k9stats` has no WHERE clause to lead a composite key with (a
  -- global ranking, not a per-citizenid/per-job lookup).
  KEY `idx_xp` (`xp`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- `handler_xp` DELIBERATELY NOT ADDED to sql/preflight_check.sql's CHECK 1
-- `cols_expected`/column list, or to server/datastore.lua's
-- EXPECTED_TABLE_COLUMNS['k9_progression'] entry, for this table -- a
-- decision, not an oversight, stated here so a future pass does not "fix"
-- it. Both of those lists exist to answer "is this really OUR
-- k9_progression table, or did a different resource's table squat this
-- name" using a STABLE, FOUNDING column signature -- `citizenid`/`xp`/
-- `created_at`/`updated_at` have been true of every k9_progression row
-- since migration 0002, before migration 0017 ever added `handler_xp`.
-- Including `handler_xp` in either check would make it FAIL against every
-- real, legitimately-ours installation that has not yet applied migration
-- 0017 -- preflight_check.sql's CHECK 1 would misreport a real upgrade-
-- pending database as "!! CONFLICT - a DIFFERENT table already uses this
-- name," and server/datastore.lua's own live collision probe
-- (VerifyTableShapesAgainstKnownSchema) would actually DISABLE MySQL for
-- the ENTIRE resource, for the whole session, the exact false-positive
-- both mechanisms exist to avoid (see server/datastore.lua's own
-- EXPECTED_TABLE_COLUMNS['k9_xp_tiers'] entry -- 7 of that table's 9 real
-- columns -- for the identical established precedent of a subset,
-- founding-columns-only signature that does not grow every time a later
-- migration adds one more column).
--
-- =====================================================================
-- john-k9 :: k9_permissions
--
-- Backs `Config.Features.PermissionGrants` / `Config.Permissions` /
-- `server/permissions.lua`: lets a high-command officer grant one NAMED
-- capability (a `Config.Permissions` key -- currently `k9.access`,
-- `k9.certify`, `k9.audit`, `k9.givexp`) to one specific citizenid --
-- handler or K9, since both are just citizenids to this resource -- and
-- revoke it later. See config.lua's own `Config.Permissions` block for the
-- full capability list/labels and the 4-step resolution order this table
-- feeds step 1 of ("an active, explicitly granted permission for that
-- citizenid -> ALLOW", checked before the high-command/rank fallbacks).
--
-- MODELED DIRECTLY ON `k9_certifications` ABOVE (read in full before this
-- table was written, per this resource's own established convention of
-- reusing that table's shape rather than inventing a new one -- see
-- `k9_partnerships`' header for the same instruction applied once already).
-- Same append-mostly audit-log design: granting INSERTs a new row, revoking
-- UPDATEs the existing active row to `active = 0` (never deletes), so the
-- full grant/revoke history per (citizenid, permission) is always
-- reconstructable -- this is an AUTHORIZATION AUDIT TRAIL ("who gave whom
-- what power, and when it was taken away"), not just current-state storage,
-- for the exact same reason `k9_certifications` keeps its revoked rows
-- rather than deleting them.
--
-- SHAPE DIFFERENCE FROM `k9_certifications`: one citizenid + one
-- department-scoped `job` there, versus one citizenid + one
-- resource-global `permission` key here -- a grant is not scoped to a
-- department, it is scoped to the specific capability named in
-- `Config.Permissions`. `permission` is therefore this table's structural
-- analogue of `k9_certifications.job`, and every index/generated-column
-- choice below mirrors that table's (citizenid, job) pattern with
-- (citizenid, permission) substituted throughout.
--
-- WHY `permission` IS `VARCHAR(50)`, NOT `ENUM(...)`: config.lua's own
-- `Config.Permissions` header is explicit that this is a config-driven,
-- extensible catalog ("Add a new key and migrate [the Lua config, and
-- existing grant rows stay valid under the new key set] instead" of
-- renaming one in place) -- a server owner can add a fifth capability by
-- editing `Config.Permissions` alone, with no DB schema change. `ENUM`
-- would silently defeat that: every new capability would additionally
-- require an `ALTER TABLE ... MODIFY permission ENUM(...)` on every
-- installed database just to become grantable, which is exactly the kind
-- of hidden coupling this table must not introduce. Sized at
-- `VARCHAR(50)`, matching `citizenid`/`job`/`granted_by`/`revoked_by`'s
-- existing width in this file, even though every current key
-- (`k9.givexp` at 9 characters) is far shorter -- headroom for future
-- capability names costs nothing and avoids a second migration later
-- purely to widen a column.
--
-- WHY THIS TABLE, NOT A COLUMN ON AN EXISTING TABLE: a grant is keyed by
-- (citizenid, permission), an N:M relationship -- one citizenid can hold
-- several permissions at once, and one permission can be held by many
-- citizenids. Neither `k9_certifications` nor `k9_progression` (one row
-- per citizenid) can represent that without denormalizing one flag column
-- per capability, which breaks the moment a fifth capability is added.
--
-- NO FK to a `players` table is declared here, for the identical reason
-- `k9_certifications` above declares none (see that table's own comment in
-- full -- not repeated here): this resource's migration must not depend on
-- qbx_core's own schema existing first, and a player-data reset/delete
-- workflow on another resource's table must never be able to fail this
-- table's constraints. Relational integrity to qbx_core players is
-- enforced at the application layer, same convention used throughout this
-- file. This also covers the K9-as-citizenid case identically -- a K9's
-- "player row" is the same qbx_core players table under its own citizenid,
-- so no separate carve-out is needed for granting to a K9 versus a
-- handler.
--
-- `granted_by`/`revoked_by` carry the SAME no-FK, no-format-constraint
-- convention as `k9_certifications.granted_by`/`revoked_by`: ordinarily a
-- citizenid (the high-command officer who acted), but nothing in this
-- table enforces that shape, so a future automatic-teardown path (e.g. a
-- department change stripping a grant, mirroring
-- `k9_certifications`' own `'system:job_change'` sentinel) could write a
-- non-citizenid `'system:...'` sentinel into `revoked_by` without a schema
-- change -- NOT currently exercised by any code in this resource (grants
-- are revoked only by an explicit high-command action today, per
-- config.lua's `Config.Permissions` header), reserved for parity with the
-- established pattern rather than implemented ahead of need.
--
-- NO TIMESTAMPDIFF / ELAPSED-TIME MATH ANYWHERE IN THIS TABLE'S DESIGN OR
-- ITS THREE QUERIES BELOW (see sql/install.sql's own DATETIME-timezone
-- hazard note and DEVELOPER_REFERENCE.md-adjacent tuning tables elsewhere in this
-- resource for why that matters): every consumer query filters on
-- `active`/`citizenid`/`permission` and orders by `granted_at`, never
-- diffs two DATETIME columns. If a future feature adds a grant EXPIRY
-- (e.g. "this permission lapses after N days"), that computation would
-- inherit the exact hazard this file's other DATETIME columns already
-- carry (a DB server timezone change after go-live skews TIMESTAMPDIFF
-- math) and must be designed with that in mind -- not present today, so
-- not designed around here.
--
-- Generated helper column (derived only, never written directly by app
-- code), and its backing unique key: NULL for every inactive/revoked row,
-- and `citizenid::permission` for an active row -- identical mechanism to
-- `k9_certifications.active_cert_key` above (see that column's own comment
-- for the full "why a VIRTUAL generated column, why NULLs never collide"
-- rationale, not repeated here). THIS IS A CORRECTNESS REQUIREMENT, NOT A
-- NICETY: `server/permissions.lua`'s grant path is expected to be the same
-- application-level check-then-insert shape `server/certifications.lua`
-- already uses, with no transaction spanning both statements -- exactly
-- the shape a 20-connection concurrent-grant race test already proved
-- (see sql/rollback/0004_down.sql's own measured numbers for
-- `k9_certifications`) produces 20 simultaneously-active rows with zero
-- errors when the equivalent constraint is absent. coder-backend: on the
-- grant INSERT, treat a duplicate-key error on this constraint
-- (MySQL/MariaDB error 1062) identically to the normal pre-check
-- "already granted" no-op -- it means another request won the race, not a
-- real failure.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, see
-- `john-k9/sql/migrations/0005_create_k9_permissions.sql`.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_permissions` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,                          -- qbx_core / QBCore citizenid convention; the handler OR K9 the grant applies to (both are citizenids)
  `permission`       VARCHAR(50)  NOT NULL,                          -- Config.Permissions key, e.g. 'k9.access' / 'k9.certify' / 'k9.audit' / 'k9.givexp' -- VARCHAR not ENUM, see header comment above
  `granted_by`       VARCHAR(50)  NOT NULL,                          -- citizenid of the granting high-command officer
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,                      -- citizenid of the revoking officer; NULL until revoked. See header comment for the reserved (unused today) 'system:...' sentinel convention.
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,                -- 1 = currently grants the capability, 0 = historical/revoked row

  -- Generated helper column, identical mechanism to
  -- `k9_certifications.active_cert_key` (see that column's comment above):
  -- NULL for every inactive/revoked row, `citizenid::permission` for an
  -- active row. Backs the DB-level "one active grant per (citizenid,
  -- permission)" backstop below.
  `active_permission_key` VARCHAR(105)
                       GENERATED ALWAYS AS (
                         CASE WHEN `active` = 1
                              THEN CONCAT(`citizenid`, '::', `permission`)
                              ELSE NULL
                         END
                       ) VIRTUAL,

  PRIMARY KEY (`id`),

  -- Hot-path index: "does citizenid X currently hold permission P" --
  -- checked on every capability check (server/permissions.lua's per-action
  -- gate, ahead of the high-command/rank fallbacks per config.lua's 4-step
  -- resolution order). citizenid leads the index so it ALSO serves the
  -- tablet's per-person view, "list every active permission citizenid X
  -- currently holds", as a citizenid-prefix scan with `active = 1`
  -- evaluated via index condition pushdown -- same dual-purpose role
  -- `k9_certifications.idx_citizen_job_active` plays for that table.
  --   -- hot-path capability check:
  --   SELECT id FROM k9_permissions
  --   WHERE citizenid = ? AND permission = ? AND active = 1 LIMIT 1;
  --   -- tablet per-person view:
  --   SELECT permission, granted_by, granted_at FROM k9_permissions
  --   WHERE citizenid = ? AND active = 1 ORDER BY granted_at DESC;
  KEY `idx_citizen_permission_active` (`citizenid`, `permission`, `active`),

  -- Roster-path index: "list everyone holding permission P" (the tablet's
  -- roster view for a given capability). idx_citizen_permission_active
  -- above cannot serve this efficiently because `permission` is not its
  -- leading column; this index makes it an index seek instead of a full
  -- table scan, mirroring k9_certifications.idx_job_active's role.
  --   SELECT citizenid, granted_by, granted_at FROM k9_permissions
  --   WHERE permission = ? AND active = 1;
  KEY `idx_permission_active` (`permission`, `active`),

  -- DB-level backstop for the app-enforced "one active grant per
  -- (citizenid, permission)" invariant -- see the header comment above for
  -- why this is a correctness requirement, not a nicety. Closes the
  -- check-then-insert race window the same way
  -- `k9_certifications.uq_one_active_cert_per_job` closes it for
  -- certification grants.
  UNIQUE KEY `uq_one_active_permission_per_citizen` (`active_permission_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_runtime_feature_overrides / k9_runtime_override_audit /
--               k9_tablet_theme / k9_tablet_theme_audit
--
-- CONVERGENCE FIX (db-schema foolproofing pass): these four tables were
-- created via `sql/migrations/0007_create_k9_runtime_control.sql` but were
-- never added here, so a FRESH install silently lacked
-- Config.Features.RuntimeFeatureControl / Config.Features.TabletTheming's
-- persistence with no error and no warning -- exactly the same
-- "fresh install != upgraded install" gap this file's own header already
-- documents install.sql being responsible for NOT reintroducing. Added
-- here now, byte-for-byte the same shape as migration 0007 -- see that
-- file's own header for the full design rationale (why override_key
-- encodes both kind and target, why old_value/new_value are nullable in
-- opposite directions, why theme rows are full snapshots, why id=1 is the
-- only tablet_theme row) -- not repeated a second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these four tables, run
-- `sql/migrations/0007_create_k9_runtime_control.sql` instead (a
-- guaranteed no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_runtime_feature_overrides` (
  `override_key` VARCHAR(100) NOT NULL,
  `kind`         VARCHAR(10)  NOT NULL,          -- 'feature' | 'tuning'
  `value`        VARCHAR(64)  NOT NULL,          -- plain string form of the override
  `updated_by`   VARCHAR(50)  NOT NULL,          -- citizenid of the high-command officer who set this override
  `updated_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`override_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_runtime_override_audit` (
  `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `override_key`  VARCHAR(100) NOT NULL,
  `kind`          VARCHAR(10)  NOT NULL,
  `old_value`     VARCHAR(64)  DEFAULT NULL,     -- NULL = there was no prior override (config.lua default before this change)
  `new_value`     VARCHAR(64)  DEFAULT NULL,     -- NULL = reset back to the config.lua default
  `changed_by`    VARCHAR(50)  NOT NULL,
  `changed_at`    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_override_key_changed_at` (`override_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_tablet_theme` (
  `id`               TINYINT UNSIGNED NOT NULL,             -- always exactly one row, id = 1 -- see migration 0007's own header
  `primary_color`    VARCHAR(7)  NOT NULL DEFAULT '#2563eb',
  `accent_color`     VARCHAR(7)  NOT NULL DEFAULT '#f59e0b',
  `background_color` VARCHAR(7)  NOT NULL DEFAULT '#111827',
  `text_color`       VARCHAR(7)  NOT NULL DEFAULT '#f9fafb',
  `density`          VARCHAR(20) NOT NULL DEFAULT 'comfortable',
  `header_title`     VARCHAR(40) NOT NULL DEFAULT 'K9 Command Tablet',
  `updated_by`       VARCHAR(50) DEFAULT NULL,
  `updated_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_tablet_theme_audit` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `primary_color`    VARCHAR(7)  NOT NULL,
  `accent_color`     VARCHAR(7)  NOT NULL,
  `background_color` VARCHAR(7)  NOT NULL,
  `text_color`       VARCHAR(7)  NOT NULL,
  `density`          VARCHAR(20) NOT NULL,
  `header_title`     VARCHAR(40) NOT NULL,
  `changed_by`       VARCHAR(50) NOT NULL,
  `changed_at`       DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_ped_assignments
--
-- CONVERGENCE FIX (db-schema foolproofing pass): created via
-- `sql/migrations/0008_create_k9_ped_assignments.sql` but never added
-- here -- same class of gap as the four tables immediately above. Added
-- now, byte-for-byte the same shape as migration 0008 -- see that file's
-- own header for the full design rationale (why `original_model_hash` is
-- a hash not a name, why `citizenid` alone is the primary key, why this
-- is current-state bookkeeping and not an audit log) -- not repeated a
-- second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, run
-- `sql/migrations/0008_create_k9_ped_assignments.sql` instead (a
-- guaranteed no-op if this file already created it).
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

-- =====================================================================
-- john-k9 :: k9_certification_tiers / k9_certification_tier_capabilities
--               / k9_certification_tier_audit
--
-- Added alongside `sql/migrations/0010_create_k9_certification_tiers.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (why this reverses server/certifications.lua's earlier
-- "tier is hardcoded, not a Config table" decision, why `deleted` is a
-- tombstone rather than a real row DELETE, why capabilities are a sibling
-- table rather than a column/CSV/JSON blob, why neither table declares an
-- FK) -- not repeated a second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these tables, run
-- `sql/migrations/0010_create_k9_certification_tiers.sql` instead (a
-- guaranteed no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_certification_tiers` (
  `tier_key`     VARCHAR(32)  NOT NULL,
  `label`        VARCHAR(60)  NOT NULL,
  `ordinal`      INT          NOT NULL,
  `deleted`      TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`   VARCHAR(50)  NOT NULL,
  `updated_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`tier_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_certification_tier_capabilities` (
  `tier_key`        VARCHAR(32) NOT NULL,
  `capability_key`  VARCHAR(64) NOT NULL,
  `granted_by`      VARCHAR(50) NOT NULL,
  `granted_at`      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`tier_key`, `capability_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_certification_tier_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `tier_key`     VARCHAR(32)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_tier_key_changed_at` (`tier_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_equipment_shop_locations / k9_equipment_shop_locations_audit
--
-- CONVERGENCE FIX (db-schema pass, 2026-08-26): created via
-- `sql/migrations/0011_create_k9_equipment_shop_locations.sql` but never
-- added here -- the same class of gap this file's own header already
-- documents having happened (and been fixed) for the runtime-control/
-- theme tables, k9_ped_assignments, and the certification-tier tables
-- above. Added now, byte-for-byte the same shape as migration 0011 -- see
-- that file's own header for the full design rationale (why this is
-- scoped to ONLY tablet-added locations, never a config.lua entry; why
-- `model`/`scenario`/`label` are nullable; why `location_id` in the audit
-- table is not a real FK) -- not repeated a second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these two tables, run
-- `sql/migrations/0011_create_k9_equipment_shop_locations.sql` instead (a
-- guaranteed no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_equipment_shop_locations` (
  `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `x`          DOUBLE       NOT NULL,
  `y`          DOUBLE       NOT NULL,
  `z`          DOUBLE       NOT NULL,
  `heading`    DOUBLE       NOT NULL DEFAULT 0,
  `model`      VARCHAR(64)  DEFAULT NULL,   -- NULL = use Config.K9EquipmentShop.pedModel
  `scenario`   VARCHAR(64)  DEFAULT NULL,   -- NULL = use Config.K9EquipmentShop.pedScenario; '' = explicitly no scenario for this ped
  `label`      VARCHAR(100) DEFAULT NULL,   -- NULL = use Config.K9EquipmentShop.label
  `created_by` VARCHAR(50)  NOT NULL,       -- citizenid of the high-command officer who added this location
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by` VARCHAR(50)  DEFAULT NULL,   -- citizenid of whoever last moved/edited it, NULL if never edited since creation
  `updated_at` DATETIME     DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_equipment_shop_locations_audit` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `location_id` INT UNSIGNED DEFAULT NULL,  -- informational reference only, not a real FK -- see migration 0011's own header
  `action`      VARCHAR(20)  NOT NULL,      -- 'add' | 'move' | 'remove'
  `x`           DOUBLE       DEFAULT NULL,
  `y`           DOUBLE       DEFAULT NULL,
  `z`           DOUBLE       DEFAULT NULL,
  `heading`     DOUBLE       DEFAULT NULL,
  `model`       VARCHAR(64)  DEFAULT NULL,
  `scenario`    VARCHAR(64)  DEFAULT NULL,
  `label`       VARCHAR(100) DEFAULT NULL,
  `changed_by`  VARCHAR(50)  NOT NULL,
  `changed_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_location_id_changed_at` (`location_id`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_permission_keys / k9_permission_key_audit
--
-- Added alongside `sql/migrations/0013_create_k9_permission_keys.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (why this overlays server/permissions.lua's
-- Config.Permissions catalog the same way k9_certification_tiers overlays
-- Config.CertificationTiers, why `deleted` is a tombstone rather than a
-- real row DELETE, why there is no ordinal or capabilities sibling table
-- the way the certification-tier tables have, and why neither table
-- declares an FK) -- not repeated a second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these tables, run
-- `sql/migrations/0013_create_k9_permission_keys.sql` instead (a
-- guaranteed no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_permission_keys` (
  `permission_key` VARCHAR(50)  NOT NULL,
  `label`          VARCHAR(60)  NOT NULL,
  `description`    VARCHAR(300) DEFAULT NULL,
  `deleted`        TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`     VARCHAR(50)  NOT NULL,
  `updated_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`permission_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_permission_key_audit` (
  `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`         VARCHAR(20)  NOT NULL,
  `permission_key` VARCHAR(50)  NOT NULL,
  `detail`         TEXT         NOT NULL,
  `changed_by`     VARCHAR(50)  NOT NULL,
  `changed_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_permission_key_changed_at` (`permission_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_equipment_shop_items / k9_equipment_shop_item_audit
--
-- Added alongside `sql/migrations/0014_create_k9_equipment_shop_items.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (why this overlays server/equipmentshop.lua's
-- Config.K9EquipmentShop.items catalog the same way k9_certification_tiers
-- overlays Config.CertificationTiers, why `deleted` is a tombstone rather
-- than a real row DELETE, why `required_tier_key`/`required_specialization`
-- are two plain nullable columns rather than a capabilities-style sibling
-- table, and why neither table declares an FK) -- not repeated a second
-- time here.
--
-- db-schema convergence pass, 2026-08-26: this section was previously
-- completely absent from this file even though migration 0014 itself has
-- shipped since this same pass -- the exact class of silent gap migrations
-- 0010/0011/0013/0015 already had fixed here once before for THIS file (see
-- this file's own top-of-header table count, which this addition brings
-- back in sync with the real CREATE TABLE count below). Without this
-- section, a FRESH install via this file alone never created these two
-- tables at all, so every real-database write server/equipmentshop.lua's
-- own item-catalog editor makes would have silently failed (K9Store's own
-- pcall-guarded SafeWrite contract logs and degrades rather than crashing,
-- so nothing would have thrown -- it would just never have persisted,
-- which is worse: the tablet would report success on every edit while
-- nothing survived a restart).
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these tables, run
-- `sql/migrations/0014_create_k9_equipment_shop_items.sql` instead (a
-- guaranteed no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_equipment_shop_items` (
  `item_key`                VARCHAR(50)  NOT NULL,
  `label`                   VARCHAR(60)  DEFAULT NULL,
  `price`                   INT UNSIGNED NOT NULL,
  `currency`                VARCHAR(50)  DEFAULT NULL,
  `sort_order`              INT          NOT NULL,
  `required_tier_key`       VARCHAR(32)  DEFAULT NULL,
  `required_specialization` VARCHAR(50)  DEFAULT NULL,
  `deleted`                 TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`              VARCHAR(50)  NOT NULL,
  `updated_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`item_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_equipment_shop_item_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `item_key`     VARCHAR(50)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_item_key_changed_at` (`item_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_xp_tiers / k9_xp_tier_audit
--
-- Added alongside `sql/migrations/0015_create_k9_xp_tiers.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (why this overlays Config.XPTiers by mutating it in
-- place rather than a second merged-catalog structure, why there is no
-- `deleted` tombstone column at all, why `ordinal` -- not a free-form
-- string key -- is this table's own stable identity, and why neither
-- table declares an FK) -- not repeated a second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these tables, run
-- `sql/migrations/0015_create_k9_xp_tiers.sql` instead (a guaranteed
-- no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_xp_tiers` (
  `ordinal`                    INT          NOT NULL,
  `xp_threshold`               INT          NOT NULL,
  `label`                      VARCHAR(60)  NOT NULL,
  `speed_multiplier`           DOUBLE       NOT NULL,
  `scent_range_multiplier`     DOUBLE       NOT NULL,
  `medkit_cooldown_multiplier` DOUBLE       DEFAULT NULL,
  `badge`                      VARCHAR(30)  DEFAULT NULL,
  `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`                 VARCHAR(50)  NOT NULL,
  `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`ordinal`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_xp_tier_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `ordinal`      INT          NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_ordinal_changed_at` (`ordinal`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_individual_overrides / k9_individual_override_audit
--
-- Added alongside `sql/migrations/0016_create_k9_individual_overrides.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (the per-INDIVIDUAL-K9 "god mode" override layer,
-- resolution order GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE, why
-- every field is independently NULLABLE/optional, why this table declares
-- a `deleted` tombstone despite having no reference-count hazard the way
-- k9_certification_tiers does, and why neither table declares an FK) --
-- not repeated a second time here.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates these tables, run
-- `sql/migrations/0016_create_k9_individual_overrides.sql` instead (a
-- guaranteed no-op if this file already created them).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_individual_overrides` (
  `citizenid`                  VARCHAR(50)  NOT NULL,
  `speed_multiplier`           DOUBLE       DEFAULT NULL,
  `scent_range_multiplier`     DOUBLE       DEFAULT NULL,
  `medkit_cooldown_multiplier` DOUBLE       DEFAULT NULL,
  -- How fast this one dog's stamina drains. BIGGER = runs out sooner,
  -- SMALLER = lasts longer, exactly 0 = never runs out at all. NULL means
  -- no override: this dog uses the server-wide setting. Range is enforced
  -- in server/k9profiles.lua, not by a CHECK here -- MySQL 5.7 parses
  -- CHECK and silently ignores it, so one written here would read as a
  -- guarantee it does not actually give.
  `sprint_decay_per_tick`      DOUBLE       DEFAULT NULL,
  `note`                       VARCHAR(120) DEFAULT NULL,
  `deleted`                    TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`                 VARCHAR(50)  NOT NULL,
  `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `k9_individual_override_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `citizenid`    VARCHAR(50)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_citizenid_changed_at` (`citizenid`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_partnership_pair_progress
--
-- Added alongside `sql/migrations/0018_create_k9_partnership_pair_progress.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale. The FULLY DURABLE half of the partnership-tenure
-- anti-farm guard KNOWN_ISSUES.md used to disclose as "in-memory only, a
-- restart re-opens the loop once per pair": server/partnership.lua's
-- CaptureTenureSeedForPair (called from the shared break-teardown core,
-- DoBreakPartnership) writes the highest partnership-tenure milestone tier
-- an exact (k9, handler) pair has ever confirmed-earned into THIS table,
-- keyed by the pair itself rather than by `k9_partnerships.id` -- so the
-- value survives that row being superseded by a brand-new one on
-- break+reform, AND survives a genuine resource restart (unlike the
-- in-memory table this replaces, which could not). Read back by
-- `respondPartnerUp`'s own establish critical section the moment that
-- exact pair reforms, and re-applied via the SAME optimistic-CAS primitive
-- (`K9Store.Partner_SetTenureTierCAS`) server/tenure.lua's own tick already
-- uses to write `k9_partnerships.tenure_bonus_tier_granted` -- so a pair
-- can never re-earn an already-earned milestone by cycling break/reform,
-- restart or no restart.
--
-- `k9_citizenid` / `handler_citizenid` VARCHAR(50): same convention as
-- every other citizenid column in this schema. Together they form the
-- PRIMARY KEY -- at most one progress row per EXACT pair, ever; a
-- role-swapped "pair" (the same two humans, K9 and handler roles
-- reversed) is deliberately treated as a different relationship, never
-- sharing a row with the original (see server/partnership.lua's
-- TenurePairKey-equivalent key construction, `PairProgressKey`,
-- server/datastore.lua, for the same role-order-sensitive reasoning).
--
-- `highest_tenure_tier_granted` TINYINT UNSIGNED NOT NULL DEFAULT 0: only
-- ever written via `GREATEST(highest_tenure_tier_granted, VALUES(...))`
-- (`K9Store.PairProgress_UpsertHighestTenureTier`) -- a write can never
-- LOWER this column, matching this resource's own "an already-earned
-- milestone is never re-grantable" invariant.
--
-- NO FK, matching this schema's own established "no FK, relational
-- integrity enforced at the application layer" convention -- neither
-- citizenid column references `k9_partnerships` (a pair's progress row is
-- deliberately independent of any single partnership row's lifecycle) nor
-- any player table.
--
-- No audit table: unlike `k9_individual_overrides`/`k9_certification_tiers`,
-- this table is never hand-edited by an operator -- it is written
-- automatically, exactly once per confirmed milestone grant, by the same
-- anti-farm logic already covered by tests/partnership_spec.lua and
-- tests/datastore_spec.lua. Matches `k9_progression`'s own precedent (a
-- live, automatically-upserted total, no companion audit table) rather
-- than the admin-edited tables' precedent.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, run
-- `sql/migrations/0018_create_k9_partnership_pair_progress.sql` instead (a
-- guaranteed no-op if this file already created it).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_partnership_pair_progress` (
  `k9_citizenid`                 VARCHAR(50)       NOT NULL,
  `handler_citizenid`            VARCHAR(50)       NOT NULL,
  `highest_tenure_tier_granted`  TINYINT UNSIGNED  NOT NULL DEFAULT 0,

  PRIMARY KEY (`k9_citizenid`, `handler_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_dog_characters
--
-- SCHEMA-SAFETY AUDIT FIX (db-schema pass, 2026-08-27): this table was
-- created by `sql/migrations/0019_create_k9_dog_characters.sql` (see that
-- file's own header for the full mana_policedogs feature-parity design
-- rationale) but was NEVER added here -- so a fresh install via this file
-- alone never created it, `/k9setdog`/`/k9removedog` (server/dogcharacter.lua)
-- issued real queries against a table that plain did not exist on any
-- server that only ever ran `install.sql`, and the failure reported back
-- was a generic `db_error` with nothing pointing at the actual cause. This
-- table's own migration file was the ONLY place that created it before this
-- fix -- every other integration point this schema's tables normally go
-- through (this file, `sql/preflight_check.sql`, `sql/migration_status.sql`,
-- `sql/rollback/uninstall_all.sql`, `sql/rollback/backup_k9_tables.sh`,
-- `server/datastore.lua`'s `EXPECTED_TABLE_COLUMNS`) had the identical gap,
-- all fixed in this same change.
--
-- Byte-for-byte the same column definitions, types, charset and collation
-- as `sql/migrations/0019_create_k9_dog_characters.sql`'s own `CREATE
-- TABLE` -- see that file's own header for the full "why" of this table's
-- shape (a single admin-pinned "this citizenid IS a dog" fact, deliberately
-- separate from and never overwriting the certification-driven appearance
-- state `k9_ped_assignments`, migration 0008, already tracks). Answers a
-- different question than `k9_personnel` below: this table is a purely
-- COSMETIC pin, completely decoupled from role/certification (see that
-- table's own header, and `k9_personnel`'s header just below, for the full
-- "why not this table instead" argument).
--
-- No FK anywhere, matching this schema's own established "no FK,
-- relational integrity enforced at the application layer" convention.
-- `server/dogcharacter.lua`'s own accessors are a DELIBERATE, FLAGGED
-- exception to this file's "only server/datastore.lua calls MySQL.*"
-- convention (see that file's own header) -- they call through
-- `K9Store.IsDatabaseEnabled('k9_dog_characters')`, which this fix also
-- wires into `server/datastore.lua`'s `EXPECTED_TABLE_COLUMNS` so a real
-- name collision on this exact table name now forces this ONE table (not
-- the whole resource) into honest memory-only mode instead of a silent
-- write into a table this resource does not own.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, run
-- `sql/migrations/0019_create_k9_dog_characters.sql` instead (a guaranteed
-- no-op if this file already created it).
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

-- =====================================================================
-- john-k9 :: k9_personnel
--
-- Added alongside `sql/migrations/0020_create_k9_personnel.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (ROSTER_SPEC.md §3/§4). Answers the one fact neither
-- `k9_certifications` nor `k9_dog_characters` (migration 0019, a
-- deliberately separate, purely cosmetic pin) can: WHICH roster (K9 or
-- Handler) a certified citizenid currently belongs to per department, and
-- what callsign (if any) they currently hold there.
--
-- Modeled directly on `k9_certifications` above (append-mostly audit
-- rows: assigning INSERTs a new row, clearing UPDATEs the existing active
-- row to `active = 0`, never deletes) -- NOT on `k9_dog_characters`'s
-- current-state-only shape, because a personnel record needs to preserve
-- history across a fire-and-rehire cycle, exactly like a certification
-- does. `role` (called `personnelRole` in code/API, to avoid colliding
-- with this resource's existing ped-and-access "role" concept -- see
-- migration 0020's own header) and `callsign` both live on the same
-- active row, scoped to (citizenid, job) exactly like a certification --
-- one active row per (citizenid, job), enforced by
-- `uq_one_active_personnel_per_job` the same way
-- `k9_certifications.uq_one_active_cert_per_job` enforces its own
-- invariant. `active_callsign_key` additionally backs the COMBINED-
-- NAMESPACE callsign uniqueness decision (ROSTER_SPEC.md §4): one
-- department, one callsign namespace, shared by both rosters, compared
-- case-insensitively.
--
-- No FK anywhere (including none to `k9_certifications` itself), matching
-- this schema's own established "no FK, relational integrity enforced at
-- the application layer" convention -- see migration 0020's own header for
-- the full reasoning.
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, run
-- `sql/migrations/0020_create_k9_personnel.sql` instead (a guaranteed
-- no-op if this file already created it).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_personnel` (
  `id`                    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`             VARCHAR(50)  NOT NULL,
  `job`                   VARCHAR(50)  NOT NULL,
  `role`                  VARCHAR(10)  NOT NULL,
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
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),
  KEY `idx_job_active` (`job`, `active`),
  UNIQUE KEY `uq_one_active_personnel_per_job` (`active_personnel_key`),
  UNIQUE KEY `uq_one_active_callsign_per_job` (`active_callsign_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_wellbeing
--
-- Added alongside `sql/migrations/0022_create_k9_wellbeing.sql`,
-- byte-for-byte the same shape -- see that file's own header for the full
-- design rationale (why six DECIMAL(6,2) stats and not the four short-lived
-- GetGameTimer()-relative timer-window fields, why one row per citizenid
-- rather than an append-mostly audit log, and why no FK to a `players`
-- table). Not repeated a second time here.
--
-- db-schema convergence pass, 2026-08-27: this section was previously
-- completely absent from this file even though migration 0022 itself had
-- already shipped -- the exact class of silent gap migrations
-- 0010/0011/0013/0014/0015/0019 each already had fixed here once before for
-- THIS file (see this file's own top-of-header table count, which this
-- addition brings back in sync with the real CREATE TABLE count below).
-- Without this section, a FRESH install via this file alone never created
-- this table at all, so server/wellbeing.lua's own K9Store.Wellbeing_Get/
-- K9Store.Wellbeing_Upsert accessors would have had nothing to read or
-- write against on a brand-new server until an operator separately ran
-- the migrations folder.
--
-- Owner file: `server/wellbeing.lua`, exclusively through
-- `server/datastore.lua`'s `K9Store.Wellbeing_Get`/`K9Store.Wellbeing_Upsert`
-- (this resource's own established "only datastore.lua names a k9_* table
-- or calls MySQL.* directly" rule -- see that file's own header).
--
-- Safe to run against a fresh database; CREATE TABLE IF NOT EXISTS makes
-- this idempotent if executed more than once. For an EXISTING database
-- that predates this table, run
-- `sql/migrations/0022_create_k9_wellbeing.sql` instead (a guaranteed
-- no-op if this file already created it).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_wellbeing` (
  `citizenid`   VARCHAR(50)  NOT NULL,
  -- FATIGUE IS THE ONLY WELLBEING COLUMN. This table used to carry five
  -- more -- mood, fear_stress, injury, hunger, thirst -- for subsystems
  -- removed at the owner's request on 2026-09-02. A fresh install no
  -- longer creates them.
  --
  -- AN EXISTING DATABASE KEEPS ITS OWN COPIES, on purpose: an unused
  -- column costs nothing, and a migration that DROPs columns is
  -- irreversible against live data. Nothing reads or writes them, and the
  -- startup shape check no longer expects them, so they are inert. Drop
  -- them by hand if you want the table tidy:
  --   ALTER TABLE `k9_wellbeing`
  --     DROP COLUMN `mood`, DROP COLUMN `fear_stress`, DROP COLUMN `injury`,
  --     DROP COLUMN `hunger`, DROP COLUMN `thirst`;
  `fatigue`     DECIMAL(6,2) NOT NULL DEFAULT 100.00,
  `updated_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_roles
--
-- The K9 ROLE catalog (server/roles.lua). A role is what high command
-- gives a person on the tablet -- e.g. "Narcotics detection" -- with an XP
-- requirement it switches on at and a list of what it unlocks (tracking
-- types, contraband detection categories, bite & takedown). It replaces the
-- old separate "certification tier" and "specialization" ladders on the
-- tablet. Who holds which role is still stored in
-- `k9_certification_specializations` (one row per grant, keyed by
-- role_key) -- this table is only the catalog.
--
-- The three shipped roles live in config.lua (Config.K9Specializations);
-- a row here overrides that role's label / XP / unlocks, adds a role
-- created on the tablet, or (`deleted = 1`, a tombstone) removes one --
-- the same overlay shape as `k9_certification_tiers`. `unlocks` is a
-- comma-separated list from server/roles.lua's closed unlock vocabulary.
--
-- Read and written only through server/datastore.lua's K9Store.Role_*
-- accessors. For an EXISTING database that predates this table, run
-- `sql/migrations/0023_create_k9_roles.sql` instead (a guaranteed no-op if
-- this file already created it).
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_roles` (
  `role_key`     VARCHAR(32)  NOT NULL,
  `label`        VARCHAR(60)  NOT NULL,
  `xp_required`  INT          NOT NULL DEFAULT 0,
  `unlocks`      VARCHAR(255) NOT NULL DEFAULT '',
  `deleted`      TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by`   VARCHAR(50)  NOT NULL,
  `updated_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`role_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- john-k9 :: k9_role_audit
--
-- The full history of every role edit high command makes on the tablet
-- (server/roles.lua): who created, changed or deleted which role, and
-- what it looked like afterwards. Append-only; shown on the tablet's
-- Audit Trail under Catalog Changes. For an EXISTING database that
-- predates this table, run `sql/migrations/0024_create_k9_role_audit.sql`.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `k9_role_audit` (
  `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `action`       VARCHAR(20)  NOT NULL,
  `role_key`     VARCHAR(32)  NOT NULL,
  `detail`       TEXT         NOT NULL,
  `changed_by`   VARCHAR(50)  NOT NULL,
  `changed_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  KEY `idx_role_changed_at` (`role_key`, `changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
