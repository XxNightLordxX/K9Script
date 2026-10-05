--[[
    john-k9/server/datastore.lua

    THE ONLY PLACE IN THIS RESOURCE THAT MAY NAME A `k9_*` TABLE OR CALL
    `MySQL.*` DIRECTLY. Every other server file reads/writes this
    resource's persistent state through the `K9Store` table this file
    exposes -- never through its own `MySQL.scalar/single/query/insert/
    update` call, and never through its own `if Config.Database.enabled
    then ... else ... end` branch. That is the whole point of this file.

    Owner's own words for the request this answers: "setup in the config
    if i dont want to do a sql injection i just say false in the section
    and it will disable all those features that rely on it but still try
    to make sure we can use as many of those features even if its off."

    THE READING THAT MAKES THAT TRACTABLE (verified against every real
    query this resource makes before writing a line of this file, not
    assumed): almost nothing here needs a database to FUNCTION. What the
    database provides is PERSISTENCE. Certifications, XP, partnerships,
    permissions, runtime feature overrides, tablet theming and K9 ped
    assignments can all live in memory for the life of the server process
    -- every access/authorization CHECK this resource makes is answerable
    from whatever this process currently holds, online or not, exactly as
    it is today. The honest story for `Config.Database.enabled = false` is
    therefore not "these features turn off" -- it is "everything keeps
    working, nothing is remembered past a restart," plus the audit tables
    (k9_search_log, k9_runtime_override_audit, k9_tablet_theme_audit)
    simply never getting a row written. See config.lua's own
    `Config.Database` block for the plain-language version of this
    promise aimed at a non-programmer operator.

    ======================================================================
    ARCHITECTURE -- ONE CODE PATH, TWO BACKENDS

    Every public `K9Store.*` function below has EXACTLY ONE `if
    DatabaseEnabled() then ... else ... end` branch, at the very top of its
    own body, and nowhere else. The `true` branch runs the real,
    byte-identical SQL this resource has always run (copied verbatim from
    the production call sites this file replaces -- see the per-table
    section headers below for exactly which file/line each one came from).
    The `false` branch answers the identical question from a plain Lua
    table this file owns, enforcing the identical invariants (at most one
    active row per key, fail-closed on a miss, bounded growth for the one
    table designed to grow without limit). No caller of `K9Store` ever
    branches on `Config.Database.enabled` itself -- that flag is read in
    exactly the places listed in this file, full stop. That is what makes
    "which backend is live" a single fact instead of something that can
    drift file by file, the exact bug class this resource has already
    shipped once for fresh-install-vs-upgraded-install schema drift.

    CONTRACT DISCIPLINE, so every call site elsewhere in this resource can
    swap `MySQL.xxx.await(sql, params)` for `K9Store.SomeFunction(args)`
    with NO other change to its own surrounding logic (no change to how it
    pcalls, no change to how it reads the result): each function below
    mirrors the exact return/throw contract of the ONE oxmysql method it
    replaces, table for table --
      * mirrors `MySQL.scalar.await`  -> returns a scalar value, or nil.
      * mirrors `MySQL.single.await`  -> returns one row (a table), or nil.
      * mirrors `MySQL.query.await`   -> returns an array of rows (never nil).
      * mirrors `MySQL.insert.await`  -> returns the new row's id, or
        THROWS (via Lua `error()`) on failure -- callers already `pcall()`
        this exactly like they pcall a real insert today.
      * mirrors `MySQL.update.await`  -> returns the affected-row count.
      * a few mirror this resource's own existing `SafeQuery`/`SafeWrite`
        bespoke wrappers instead (admin.lua, permissions.lua,
        runtimecontrol.lua, tablet.lua all independently hand-rolled the
        same "pcall around a query, log and degrade on failure" pattern --
        those call sites already expect a boolean/empty-table return, never
        a thrown error, so the functions replacing THEM keep that contract
        instead of oxmysql's raw one).
    A DUPLICATE-ACTIVE-ROW CONDITION in memory mode raises the SAME SHAPE
    of error object oxmysql's mysql2 driver raises for a real MySQL error
    1062 (`{ errno = 1062, message = 'ER_DUP_ENTRY: ...' }`) -- every
    `IsDuplicateKeyError(err)` helper already hand-rolled independently in
    certifications.lua/permissions.lua/partnership.lua checks `err.errno ==
    1062` FIRST, before ever inspecting a message string, so this needs
    ZERO changes to that existing duplicate-detection logic at any call
    site. Documented here once rather than re-derived at each table below.

    WHY THIS NEVER ACTUALLY RACES IN MEMORY MODE, worth being explicit
    about rather than leaving implicit: every one of this resource's real
    check-then-insert sequences (GrantCertification's `GrantInFlight` lock,
    permissions.lua's identically-shaped lock, partnership.lua's
    `PartnershipEstablishMutex`) exists to close a race that can only occur
    because a REAL `.await` call yields this coroutine and lets FXServer
    resume a second, concurrent request in the gap. A memory-mode
    `K9Store` call never yields at all -- it is a synchronous Lua table
    scan -- so on FXServer's single-threaded/cooperatively-scheduled Lua
    VM, two calls for the same key can never interleave in memory mode in
    the first place. Those application-level locks stay exactly as they
    are (this file does not touch them, and should not) -- they simply
    have nothing left to close when the backend beneath them cannot yield;
    the duplicate-row throw below is pure defense-in-depth, mirroring what
    the DB-level UNIQUE KEY backstops on the real backend.

    FAIL-CLOSED, BY CONSTRUCTION, NOT BY DISCIPLINE: a fresh server process
    in memory mode starts with EVERY table in this file completely empty.
    Nobody is pre-certified, pre-permitted, or pre-partnered -- a citizenid
    only appears in any of these tables after a real, server-authorized
    grant happens during THIS session. That is what makes "a session-only
    grant can only be easier to LOSE than a saved one, never easier to
    get" true structurally, not just as a design intention: there is no
    code path in this file that invents a row nobody granted.

    BOUNDED GROWTH: `k9_search_log` is the one table in this schema
    designed to grow without limit -- sql/install.sql's own header calls
    it "append-mostly" for the other audit tables but genuinely unbounded
    for this one. Its memory-mode mirror below is a fixed-capacity ring
    buffer (`SEARCH_LOG_MEMORY_CAP`), never a table that grows for the
    life of the process -- see that section for the exact number and
    reasoning. `k9_runtime_override_audit` / `k9_tablet_theme_audit` are
    also unbounded on the real backend (nothing ever prunes them there
    either) but are driven by rare, high-command-gated administrative
    actions rather than ordinary gameplay, so their memory-mode mirrors
    use a smaller, separate cap for the same reason -- see their own
    section.

    WHAT THIS FILE DELIBERATELY DOES NOT DO: it does not change what any
    caller is AUTHORIZED to do. Every eligibility check, cooldown, mutex,
    proximity check, and rank/permission gate in every file this
    accessor layer serves stays exactly where it is, in that file, running
    exactly as before -- this file only changes where the READ or WRITE at
    the bottom of an already-authorized action goes.

    LOAD ORDER: this file calls no natives and reads no other resource
    file's globals at its own load time (only inside function bodies,
    called later, at runtime) -- so its only real requirement is loading
    BEFORE every file that calls `K9Store.*`, i.e. before every other
    resource-owned file in `server_scripts`. See fxmanifest.lua's own
    placement comment for this file.
]]

K9Store = {}

-- ======================================================================
-- BACKEND SELECTION -- the ONE flag read in this whole resource.
-- ======================================================================

-- Set to `true`, at most once per boot, exclusively by
-- VerifyTableShapesAgainstKnownSchema() (db-schema pass, 2026-08-26) near
-- the bottom of this file -- the ONE check in this file that can force
-- every K9Store.* function back to the already-proven memory-only path,
-- run exactly ONCE, at `onResourceStart`, before this resource's first real
-- query. That single boot-time probe covers TWO different findings, not
-- two independent checks: (a) this database has a `k9_*` table whose NAME
-- this resource owns but whose COLUMNS do not match (some OTHER resource's
-- table happens to share one of our names), or (b) one or more of this
-- resource's own tables do not exist in this database at all (sql/install.sql
-- was never run, or was run but a later migration was not, or a table was
-- later dropped). See that function's own header for the full "why", "what
-- this costs", and "how to fix it" writeup for each case -- not repeated
-- here. Declared here, ahead of DatabaseEnabled() below, purely so that one
-- flag can force every K9Store.* function in this file back to the
-- memory-only path without any of them needing their own awareness of it.
--
-- CORRECTED, THIS PASS (lifecycle QA pass -- header-accuracy finding): this
-- comment used to also describe a "LIVE QUERY-FAILURE CIRCUIT BREAKER"
-- that would supposedly fire "if a REAL query against one of this
-- resource's own tables fails because that table does not exist at
-- all... either because sql/install.sql was never run, or because it was
-- run and the table was later dropped WHILE THIS RESOURCE KEPT RUNNING."
-- That second clause was never true, and no such capability exists
-- anywhere in this file: every write to SCHEMA_COLLISION_DETECTED (and to
-- TABLE_MISSING_THIS_SESSION below) happens exclusively inside
-- VerifyTableShapesAgainstKnownSchema, which this file's own
-- `onResourceStart` handler runs exactly once, at boot -- there is no
-- mid-session monitor watching ordinary K9Store.* query failures for a
-- table that vanished after this resource already started. A table
-- genuinely dropped out from under a live, already-running install will
-- simply make every subsequent query against it throw a normal "table
-- doesn't exist" error at that call's own pcall boundary, handled however
-- that specific call site's own existing failure-handling already treats
-- an unexpected query error (most already degrade to "could not confirm,"
-- never to a schema-collision determination) -- it will never flip this
-- flag and never force memory-only mode for the rest of this resource's
-- process. Correcting the claim here rather than building the capability
-- it described: a boot-time probe answering "does the schema match right
-- now" is a fundamentally different (and cheaper, and already reliable)
-- guarantee than a live monitor watching for a table to vanish mid-session
-- would be, and nothing else in this resource's own design ever actually
-- depended on the latter existing.
local SCHEMA_COLLISION_DETECTED = false

-- PER-TABLE FALLBACK (db-schema-fallback-granularity pass, this pass):
-- table name (e.g. `k9_progression`) -> `true` for exactly the tables
-- VerifyTableShapesAgainstKnownSchema's PART-INSTALLED branch confirmed
-- missing THIS boot, while at least one other of this resource's tables
-- was confirmed present and matching (if EVERY table is missing, or a real
-- collision is found, SCHEMA_COLLISION_DETECTED above is set instead and
-- this table is irrelevant -- it is populated in that case too, for
-- diagnostic completeness, but nothing ever needs to read it there since
-- the whole-resource flag already answers every table `false`). Declared
-- here, ahead of DatabaseEnabled() below, for the same reason
-- SCHEMA_COLLISION_DETECTED is: so DatabaseEnabled(tableName) can answer a
-- per-table question without every caller needing its own awareness of
-- where this comes from. See this file's own "SCHEMA COLLISION SAFETY NET"
-- section near the bottom, sub-header "PER-TABLE FALLBACK, NOT
-- WHOLE-RESOURCE, FOR A MISSING TABLE", for the full "why" writeup this
-- pass replaced -- including the one deliberate exception this table also
-- encodes (a missing `k9_certifications` forces
-- `k9_certification_specializations` in here too, even when that table's
-- own columns matched).
local TABLE_MISSING_THIS_SESSION = {}

-- Set to `true` exactly once the schema-collision determination above is
-- FINAL for this boot -- either because there was nothing to check
-- (`Config.Database.enabled == false`, so the probe below never runs at
-- all) or because the probe ran and returned, by whatever outcome (a real
-- collision, a clean match, a part-installed database -- which settles
-- TABLE_MISSING_THIS_SESSION above, not this whole-resource flag -- or the
-- probe's own pcall degrading a failed check to "no collision found" --
-- see VerifyTableShapesAgainstKnownSchema's own header). NEVER read
-- directly by a K9Store.* accessor -- only by
-- K9Store.WaitForSchemaCheckToSettle() below, which every OTHER file's own
-- boot-time cache read of a table in EXPECTED_TABLE_COLUMNS must call
-- before trusting its own first query -- see that function's own doc
-- comment for the current, authoritative caller list (kept in exactly ONE
-- place now, not repeated here) and this file's own "SCHEMA COLLISION
-- SAFETY NET" section near the bottom for the full writeup of the race
-- this closes.
local SCHEMA_CHECK_SETTLED = false

--- @param tableName string? -- OPTIONAL. When given, also checks
--- TABLE_MISSING_THIS_SESSION (declared just above, next to
--- SCHEMA_COLLISION_DETECTED) for THIS one table -- see this file's own
--- "SCHEMA COLLISION SAFETY NET" section near the bottom, sub-header "PER-
--- TABLE FALLBACK, NOT WHOLE-RESOURCE, FOR A MISSING TABLE", for the full
--- "why" writeup.
--- Every one of this file's ~99 real `K9Store.*` accessors passes its own
--- table's exact name here (verified against the literal SQL two-or-so
--- lines below its own call, not guessed) -- the two call sites that
--- genuinely have no single table in mind (the plain boot-status PRINT,
--- and the onResourceStart gate deciding whether to even run the probe at
--- all) call this with NO argument, exactly as before this pass.
--- Omitting `tableName` (or passing nil) answers the GLOBAL question only
--- -- "is the database on at all, resource-wide" -- never per-table, which
--- is what every pre-existing caller of `K9Store.IsDatabaseEnabled()` (this
--- file's own tests included) already expects unchanged.
--- @return boolean
--- Anything other than a literal `false` on `Config.Database.enabled`
--- means "on" -- including `Config.Database` not existing at all yet (an
--- older config.lua that predates this feature). That is a deliberate
--- fail-safe default: a config that has never heard of this flag gets
--- today's behavior (a real database), never a silent, unrequested
--- switch to memory-only mode.
local function DatabaseEnabled(tableName)
    if SCHEMA_COLLISION_DETECTED then return false end
    if type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database.enabled == false then return false end
    -- PER-TABLE FALLBACK (db-schema-fallback-granularity pass): a table
    -- named here was individually confirmed missing by
    -- VerifyTableShapesAgainstKnownSchema's PART-INSTALLED branch, while at
    -- least one other of this resource's tables was confirmed to exist and
    -- match -- SCHEMA_COLLISION_DETECTED above is deliberately NOT set for
    -- that case (see that branch's own header for the full "why", including
    -- the one deliberate exception: a caller asking about
    -- `k9_certification_specializations` gets `false` here whenever
    -- `k9_certifications` itself is the one missing, even though
    -- `k9_certification_specializations`'s own columns matched -- that
    -- table is force-added to TABLE_MISSING_THIS_SESSION alongside its
    -- owner for exactly that reason, so this lookup alone is sufficient;
    -- no caller needs its own awareness of the coupling).
    if tableName ~= nil and TABLE_MISSING_THIS_SESSION[tableName] then return false end
    return true
end

--- @param tableName string? -- see DatabaseEnabled's own doc comment --
--- forwarded as-is; omit for the resource-wide answer.
K9Store.IsDatabaseEnabled = DatabaseEnabled

--- "Is the database DELIBERATELY off, by the operator's own config choice?"
--- -- as opposed to "is it unexpectedly unreachable right now?".
---
--- WHY THIS IS A SEPARATE QUESTION FROM IsDatabaseEnabled, AND WHY IT HAD
--- TO EXIST (live production bug, owner report: a rank-8 police officer
--- told "You are not authorized to certify K9 handlers", on a stock
--- install). DatabaseEnabled above answers ONE question -- "can I read this
--- table?" -- and returns false for three causes that are NOT the same
--- kind of thing:
---   (a) Config.Database.enabled == false -- the operator chose memory-only
---       mode. This is the SHIPPED DEFAULT (see config.lua's own
---       Config.Database block: "so the resource is drag-and-drop").
---   (b) this one table was confirmed missing from an otherwise-installed
---       database (PART-INSTALLED fallback above).
---   (c) a whole-resource schema collision was detected.
--- Callers that must fail closed on "I cannot verify a per-person BLOCK"
--- (server/permissions.lua's HasPermission, server/tablet.lua's
--- BlockNamespaceUnreliable) were treating all three identically. For (b)
--- and (c) that is exactly right: the operator expects persistence, real
--- block rows may exist in a table we genuinely cannot read, and handing
--- someone back an ability an admin took away is the worse error. For (a)
--- it is flatly wrong, and it broke every stock install: in deliberate
--- memory mode there is no unreadable prior state to be wrong about --
--- every grant and every block that exists at all this session is in the
--- in-memory store and reads back perfectly, and nothing persisted from a
--- previous session because the operator asked for exactly that. Treating
--- that as "cannot verify" made HasPermission report `block.k9.access` and
--- `block.k9.certify` TRUE for every player on the server, which turned
--- HasK9Access and IsEligibleCertifier false for everyone: nobody could
--- use a single K9 feature, and nobody could certify anyone -- including
--- themselves -- so the resource could never be bootstrapped at all.
---
--- ANSWERS ONLY (a). Deliberately does NOT consult SCHEMA_COLLISION_DETECTED
--- or TABLE_MISSING_THIS_SESSION: a caller wanting "can I read it" already
--- has IsDatabaseEnabled, and folding the two together here would recreate
--- the exact conflation this exists to undo. Same fail-safe default as
--- DatabaseEnabled for a config that predates the flag (a missing
--- Config.Database is "a real database", never "deliberately off"), so an
--- older config.lua is treated as expecting persistence and keeps the
--- strict fail-closed behavior.
--- @return boolean
local function DatabaseConfiguredOff()
    return type(Config) == 'table'
        and type(Config.Database) == 'table'
        and Config.Database.enabled == false
end

K9Store.IsDatabaseConfiguredOff = DatabaseConfiguredOff

-- ======================================================================
-- BOOT-ORDER SETTLEMENT -- closes the race between the schema-collision
-- probe below (VerifyTableShapesAgainstKnownSchema, a real, YIELDING
-- MySQL.query.await call) and every OTHER file's own `onResourceStart`
-- boot-time read of a table this probe checks -- see
-- K9Store.WaitForSchemaCheckToSettle's own doc comment (below) for the
-- current, complete list of which files that is; not repeated here since
-- keeping several hand-typed copies of that same list in sync is exactly
-- what let it go stale before this pass. See this file's own "SCHEMA
-- COLLISION SAFETY NET" section near the bottom for the full "why this
-- exists" writeup; this is just the mechanism.
--
-- THE RACE, PRECISELY: fxmanifest.lua loads this file before any of those
-- others, so THIS file's own `AddEventHandler('onResourceStart', ...)`
-- call (bottom of this file) registers first. But registering first only
-- guarantees running first up to that handler's own FIRST yield --
-- `MySQL.query.await` always yields (it awaits a real oxmysql promise), and
-- when a handler yields, FXServer's event dispatch does not wait for it to
-- resume before invoking the NEXT handler already registered for the same
-- event -- it moves on immediately. So for the entire window between this
-- probe's own query going out and coming back, `SCHEMA_COLLISION_DETECTED`
-- above still reads whatever it read before the probe started (`false`,
-- since it starts false and is set at most once), and any OTHER file's own
-- onResourceStart handler that fires in that window sees a stale answer.
--
-- WHY THIS MATTERS MORE THAN "STALE FOR A MOMENT": each of those other
-- files' own boot-time reads is a NARROWER `SELECT` than the columns this
-- file's own EXPECTED_TABLE_COLUMNS checks (e.g. PermKey_GetAllRows
-- selects 4 of the 7 columns k9_permission_keys is checked against). A
-- foreign table the full probe would correctly reject as a collision can
-- still satisfy one of these narrower SELECTs during that window,
-- returning a stranger's real rows into a catalog cache -- exactly the
-- outcome the safety net exists to prevent, just via a side door instead
-- of the front one.
--
-- THE FIX: every one of those files' own onResourceStart handlers must
-- call K9Store.WaitForSchemaCheckToSettle() FIRST, before its own first
-- K9Store.* read, and treat a `false` result (see below) the exact same
-- way it already treats `Config.Database.enabled == false` -- boot to
-- config-only defaults for this session, no DB read attempted. This keeps
-- the fix entirely coordination-based (a shared "has this been decided
-- yet" flag), not a structural merge of every catalog's own query into
-- this file's -- see this file's own "SCHEMA COLLISION SAFETY NET" section
-- for why that alternative was rejected.
-- ======================================================================

-- Bounded wait budget for K9Store.WaitForSchemaCheckToSettle() below --
-- see the "DOES NOT BLOCK INDEFINITELY" paragraph on that function's own
-- header for why this MUST be finite. 3 seconds comfortably covers a real
-- (even mildly congested) local-network schema lookup -- a single,
-- indexed INFORMATION_SCHEMA.COLUMNS query -- while still keeping a
-- genuinely unreachable/hung database from stalling every other file's own
-- resource start by more than a few seconds.
local SCHEMA_CHECK_WAIT_TIMEOUT_MS = 3000
local SCHEMA_CHECK_WAIT_POLL_MS = 50

--- @return boolean -- true only when `Config.Database.enabled` is the
--- literal value `false` -- i.e. the database is off BY CONFIGURATION,
--- independent of whatever SCHEMA_COLLISION_DETECTED currently holds.
--- Deliberately NOT the same question as DatabaseEnabled() above (which
--- also folds in the collision flag) -- this one exists purely so
--- WaitForSchemaCheckToSettle() below can recognize "there was never going
--- to be a probe to wait for" and return immediately, with zero delay,
--- regardless of whether the probe's own onResourceStart handler has run
--- yet at all.
local function DatabaseTurnedOffByConfig()
    return type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database.enabled == false
end

--- Blocks the CALLING coroutine (never the whole server -- see below) until
--- the schema-collision determination above is final, or until a bounded
--- timeout elapses, whichever comes first. This is the ONE call every
--- OTHER file's own onResourceStart handler that reads a `k9_*` table this
--- file's EXPECTED_TABLE_COLUMNS list also checks must make BEFORE its own
--- first K9Store.* read -- see the "BOOT-ORDER SETTLEMENT" header just
--- above for the exact race this closes.
---
--- THE AUTHORITATIVE CALLER LIST (boot-order-race audit, this pass -- this
--- comment is now the ONLY place this list is written out; every other
--- mention of it in this file points back HERE instead of keeping its own
--- copy, precisely because four separate hand-typed copies had already
--- drifted out of sync with each other and with reality before this pass
--- -- one omitted server/certtiers.lua entirely, one wrongly implied
--- server/equipmentshop.lua already called this when it did not yet).
--- Currently, in fxmanifest.lua server_scripts load order:
---   server/runtimecontrol.lua     -- 1 call site: the onResourceStart
---     handler that re-applies persisted overrides/theme on top of
---     config.lua's shipped defaults reads K9Store.Override_GetAll()
---     (k9_runtime_feature_overrides) and K9Store.Theme_GetRows()
---     (k9_tablet_theme) -- ADDED to this list (issue-closer sweep,
---     2026-08-26): this call site existed since this file's own boot
---     section was written, but was missing from this list the whole time
---     (the exact class of drift this paragraph's own header warns about) --
---     confirmed by direct read that it now calls this function first, same
---     fail-closed skip-with-a-log shape as every other entry here.
---   server/permissions.lua        -- 2 call sites: the FeatureControl
---     startup warning does NOT call this (no k9_* table read there), but
---     the onResourceStart backfill loop (RefreshPermissionCache per
---     already-connected officer) does.
---   server/permissionkeycatalog.lua
---   server/main.lua                -- the certification-cache backfill
---     loop (RefreshCertificationCache, server/certifications/'s own
---     export) -- lives here, not in certifications.lua itself, because
---     that is where fxmanifest.lua's own load order put the backfill.
---   server/certtiers.lua
---   server/partnership.lua         -- the partnership-cache backfill loop
---     (RefreshPartnershipCache per already-connected officer).
---   server/wellbeing.lua           -- ADDED (boot-order-race audit,
---     lifecycle QA pass -- wellbeing persistence landed after this list
---     was last written and was never revisited against it): 1 call site,
---     but NOT an onResourceStart backfill loop like every other entry on
---     this list -- this file has none. EnsureStats' own persistence-load
---     branch (K9Store.Wellbeing_Get) is the one real read; the wait lives
---     INSIDE that one shared function (same "wait lives inside the one
---     shared function, not at each call site" shape as
---     server/equipmentshop.lua's own ActivateEquipmentShopIfEnabled entry
---     below), which covers every one of EnsureStats' own callers with one
---     change: the shared TickWellbeing tick thread's own per-player pass,
---     and every petK9/feedK9/calmDownK9/applyK9Distraction/
---     relayDamageEvent/getWellbeingSnapshot handler. The earliest and most
---     exposed of those is 'john-k9:server:getWellbeingSnapshot' --
---     client/wellbeing.lua's own on-demand-snapshot thread checks
---     IsOwnModelK9() on its very FIRST iteration, no leading Wait, and
---     fires that callback immediately whenever a player's ped is ALREADY
---     K9-modeled the instant this resource (re)starts (a ped model is
---     world state a script restart does not reset) -- reaching this
---     file's own K9Store.Wellbeing_Get well before TickWellbeing's shared
---     thread has even taken its own first Wait(TICK_INTERVAL_MS).
---   server/progression.lua         -- the XP/handler-XP cache backfill
---     loop (LoadXPForCitizenid/LoadHandlerXPForCitizenid).
---   server/xptiers.lua
---   server/k9profiles.lua
---   server/equipmentshop.lua       -- 2 call sites: the UNCONDITIONAL
---     runtime-shop-locations boot load (runs on every boot, not gated on
---     Config.Features.K9EquipmentShop -- the single most-exposed instance
---     of this race in this whole resource), and
---     ActivateEquipmentShopIfEnabled (reached from two onResourceStart
---     handlers AND a live runtime toggle-on -- the wait lives inside that
---     one shared function rather than at each of its three call sites).
--- NOT on this list, deliberately: server/tenure.lua, whose only boot-time-
--- adjacent read is a CreateThread loop that always waits at least one
--- full tick interval (5 minutes by default, never less than
--- SCHEMA_CHECK_WAIT_TIMEOUT_MS under any sane config) before its first
--- real query -- structurally different from an onResourceStart handler
--- racing this probe's own first yield, so it does not need this call (see
--- that file's own tick-loop comment if this changes).
--- HOW TO TELL IF A NEW FILE NEEDS ADDING: it registers its own
--- `onResourceStart` handler (or a CreateThread loop with no meaningful
--- delay before its first query) that reads a table in
--- EXPECTED_TABLE_COLUMNS above, directly or through a K9Store.* accessor
--- -- OR (added, wellbeing.lua entry above, this pass, so this exact gap
--- cannot recur a THIRD time): it exposes an `lib.callback.register`/
--- `RegisterNetEvent` handler a CLIENT can reach on its own very first
--- frame after this resource restarts (no server-side delay of its own
--- gates it), which reads such a table directly or through a K9Store.*
--- accessor -- server/wellbeing.lua's own getWellbeingSnapshot is the
--- worked example: nothing about it looks like a boot-time read at the
--- call site itself, but a client that is ALREADY in the state the
--- handler responds to (here, an already-K9-modeled ped, world state a
--- script restart does not reset) can and does reach it within the very
--- first network round trip after this resource loads. If so, add it to
--- fxmanifest.lua's own load-order comment for that file AND to this
--- list, in the SAME change -- this list drifting is exactly the bug this
--- paragraph exists to stop from recurring a third time.
--- DOES NOT BLOCK INDEFINITELY, BY CONSTRUCTION: this polls
--- SCHEMA_CHECK_SETTLED at most `SCHEMA_CHECK_WAIT_TIMEOUT_MS /
--- SCHEMA_CHECK_WAIT_POLL_MS` times (a fixed, small number), via `Wait(...)`
--- -- the same cooperative-yield primitive every maintenance thread in
--- this resource already uses (see e.g. server/appearance.lua's own sweep
--- thread) -- never a busy spin. A database that never answers at all
--- (unreachable, or the probe's own query hangs rather than erroring) costs
--- callers at most SCHEMA_CHECK_WAIT_TIMEOUT_MS once, at boot, never again
--- -- it does not retry, and it does not grow the wait for a second caller
--- (every caller polls the SAME shared flag, so a slow first caller does
--- not make a second caller wait twice).
---
--- @return boolean settled -- `true` means the determination is final for
--- this boot and DatabaseEnabled()/every K9Store.* accessor now gives the
--- correct, settled answer -- proceed exactly as before. `false` means the
--- probe genuinely had not finished within the wait budget -- per this
--- resource's own fail-closed convention (see this file's header
--- "FAIL-CLOSED, BY CONSTRUCTION"), the caller must NOT proceed to read a
--- `k9_*` table on the strength of its own narrower query in this case --
--- the collision state is unknown, and unknown must be treated the same as
--- "assume collision" for that one boot-time read: fall back to
--- config-only defaults for this session, exactly like
--- `Config.Database.enabled == false`, and let a later natural refresh
--- (this resource's own established self-healing convention -- every one
--- of these three catalogs already re-reads its own table after its next
--- successful admin edit) pick up the real state once the probe -- which
--- keeps running in the background regardless of this timeout -- actually
--- finishes.
function K9Store.WaitForSchemaCheckToSettle()
    if SCHEMA_CHECK_SETTLED then return true end
    if DatabaseTurnedOffByConfig() then
        -- Nothing to wait for: the probe's own onResourceStart handler
        -- below never even attempts to run when the database is off by
        -- config, so SCHEMA_CHECK_SETTLED would otherwise never be set at
        -- all this session -- recognized here, directly, so this returns
        -- instantly instead of waiting out the full timeout every single
        -- boot on a `Config.Database.enabled = false` server.
        return true
    end
    if type(Wait) ~= 'function' then
        -- No real FXServer scheduler available (a plain sandbox/unit-test
        -- load with no natives stubbed) -- there is nothing to
        -- cooperatively wait ON, so report whatever is already known
        -- rather than erroring or spinning. Every current caller already
        -- treats `false` here as "could not confirm settlement yet, fall
        -- back to config defaults" -- the safe direction in a sandbox that
        -- has not modeled the probe's own timing at all.
        return SCHEMA_CHECK_SETTLED
    end
    local waited = 0
    while not SCHEMA_CHECK_SETTLED and waited < SCHEMA_CHECK_WAIT_TIMEOUT_MS do
        Wait(SCHEMA_CHECK_WAIT_POLL_MS)
        waited = waited + SCHEMA_CHECK_WAIT_POLL_MS
    end
    return SCHEMA_CHECK_SETTLED
end

-- ======================================================================
-- SHARED MEMORY-BACKEND HELPERS
-- ======================================================================

--- @return number
local function NowUnix()
    return os.time()
end

--- Formats a Lua epoch as the same "YYYY-MM-DD HH:MM:SS" shape oxmysql
--- hands back for a DATETIME column, so a caller that does `tostring(row.
--- granted_at)` (this resource's admin/tablet formatting convention)
--- prints something sane in memory mode too.
--- @param unixTime number?
--- @return string?
local function FormatDateTime(unixTime)
    if not unixTime then return nil end
    return os.date('%Y-%m-%d %H:%M:%S', unixTime)
end

--- Raises the SAME SHAPE of error oxmysql's mysql2 driver raises for a
--- real MySQL/MariaDB error 1062 (duplicate entry against a UNIQUE KEY) --
--- see this file's header for why every existing `IsDuplicateKeyError`
--- helper elsewhere in this resource already recognizes this without any
--- change on its part.
--- @param context string -- for the console line only, never parsed by a caller
local function ThrowDuplicateActiveRow(context)
    error({ errno = 1062, message = ('ER_DUP_ENTRY: duplicate active row for %s (john-k9 in-memory backend)'):format(context) }, 0)
end

--- Coerces a `limit` argument -- crossing into this file from a caller,
--- eventually either embedded into hardcoded SQL text via `string.format`'s
--- `%d` (the DB branch) or compared against a table length with `>=` (the
--- memory branch) -- into a small, strictly-positive Lua integer. NEVER
--- trusts a caller to have already done this: every current caller already
--- clamps its own `limit` before reaching here (server/admin.lua's own
--- ClampLimit, server/leaderboard.lua's independent copy of the same
--- helper), but this is a SEPARATE, defense-in-depth backstop at the one
--- layer that actually embeds the value in SQL text or a raw comparison --
--- see this task's own brief: "confirm the server clamps it rather than
--- trusting it," applied one layer deeper than the call site.
---
--- WITHOUT THIS: `string.format('LIMIT %d', limit)` raises an UNCAUGHT Lua
--- error (`bad argument ... (number has no integer representation)`) for a
--- non-number, NaN, +-infinity, or a float with a fractional part -- and
--- for every DB-branch accessor below that builds its SQL text with
--- `:format(limit)' BEFORE its own `pcall(MySQL.query.await, ...)`, that
--- throw happens OUTSIDE the pcall, so it is NOT caught by this file's own
--- "always a table, empty on failure, never throws" SafeQuery contract --
--- it propagates straight out into whatever RegisterCommand/lib.callback
--- handler called it. The memory-branch `if #out >= limit then break end`
--- comparisons have the identical exposure the other way: `>= ` against a
--- non-number throws "attempt to compare number with X". Both failure
--- modes are closed here, once, for every accessor that takes a `limit`,
--- rather than re-derived per call site.
--- @param limit any
--- @return number -- a strictly-positive integer in [1, 100000]
local function SanitizeLimit(limit)
    local n = tonumber(limit)
    if n == nil or n ~= n then return 1 end -- non-numeric or NaN -> smallest safe fallback
    n = math.floor(n)
    if n < 1 then return 1 end
    if n > 100000 then return 100000 end -- backstop ceiling, not a business-rule cap -- see doc comment above
    return n
end

-- ======================================================================
-- k9_certifications
--
-- Real queries mirrored below, copied from server/certifications/
-- (RefreshCertificationCache, IsCertRowConfirmedActive, GrantCertification/
-- doGrantInsert, RevokeCertification/RevokeCertificationOffline/
-- QBCore:Server:OnJobUpdate, SetCertificationTier, RenewCertification,
-- QueryCertificationRecord), server/appearance.lua (IsCertifiedK9ForJob/
-- IsCertifiedK9ForAnyJob), server/tablet.lua (QueryHasAnyActiveCertification)
-- and server/admin.lua (QueryCertificationHistory, QueryDepartmentRoster).
-- ======================================================================
local CertRows = {}
local CertNextId = 0

--- @param citizenid string
--- @param job string? -- nil matches ANY job (IsCertifiedK9ForAnyJob's shape)
--- @return table? row
local function CertFindActive(citizenid, job)
    for _, row in ipairs(CertRows) do
        if row.active == 1 and row.citizenid == citizenid and (job == nil or row.job == job) then
            return row
        end
    end
    return nil
end

--- Mirrors MySQL.scalar.await. Replaces server/certifications/'s
--- RefreshCertificationCache/IsCertRowConfirmedActive/GrantCertification
--- existence-check queries.
function K9Store.Cert_GetActiveId(citizenid, job)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', { citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    return row and row.id or nil
end

--- Mirrors MySQL.scalar.await. Replaces server/appearance.lua's
--- IsCertifiedK9ForAnyJob and server/tablet.lua's
--- QueryHasAnyActiveCertification (identical "any department" query).
function K9Store.Cert_GetActiveIdAnyJob(citizenid)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.scalar.await('SELECT id FROM k9_certifications WHERE citizenid = ? AND active = 1 LIMIT 1', { citizenid })
    end
    local row = CertFindActive(citizenid, nil)
    return row and row.id or nil
end

--- Mirrors MySQL.single.await. Replaces RefreshCertificationCache's own
--- tier/expiry metadata read.
--- @return table? { tier: string, expires_at_unix: number? }
function K9Store.Cert_GetActiveMeta(citizenid, job)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.single.await(
            'SELECT tier, UNIX_TIMESTAMP(expires_at) AS expires_at_unix FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1',
            { citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return nil end
    return { tier = row.tier, expires_at_unix = row.expires_at_unix }
end

--- Mirrors MySQL.insert.await -- returns the new row's id, or THROWS
--- (a duplicate-active-row error in memory mode, a real thrown oxmysql
--- error in DB mode) exactly like the real INSERT this replaces.
--- @param expiryDays number? -- nil = no expiry (DEFAULT NULL, matches the real schema)
--- @return number id
function K9Store.Cert_Insert(citizenid, job, grantedBy, expiryDays)
    if DatabaseEnabled('k9_certifications') then
        if expiryDays then
            return MySQL.insert.await(
                'INSERT INTO k9_certifications (citizenid, job, granted_by, expires_at) VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL ? DAY))',
                { citizenid, job, grantedBy, expiryDays })
        end
        return MySQL.insert.await('INSERT INTO k9_certifications (citizenid, job, granted_by) VALUES (?, ?, ?)', { citizenid, job, grantedBy })
    end
    if CertFindActive(citizenid, job) then ThrowDuplicateActiveRow('k9_certifications ' .. citizenid .. '::' .. job) end
    CertNextId = CertNextId + 1
    CertRows[#CertRows + 1] = {
        id = CertNextId, citizenid = citizenid, job = job, granted_by = grantedBy,
        granted_at = FormatDateTime(NowUnix()), revoked_by = nil, revoked_at = nil, revoke_reason = nil,
        expires_at_unix = expiryDays and (NowUnix() + expiryDays * 86400) or nil,
        active = 1, tier = 'certified',
    }
    return CertNextId
end

--- Mirrors MySQL.update.await. Replaces the (byte-identical) UPDATE used
--- by RevokeCertification, RevokeCertificationOffline, and the
--- QBCore:Server:OnJobUpdate auto-revoke branch.
--- @return number affectedRows
function K9Store.Cert_RevokeActive(citizenid, job, revokedBy, reason)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.update.await(
            'UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP, revoke_reason = ? WHERE citizenid = ? AND job = ? AND active = 1',
            { revokedBy, reason, citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return 0 end
    row.active, row.revoked_by, row.revoked_at, row.revoke_reason = 0, revokedBy, FormatDateTime(NowUnix()), reason
    return 1
end

--- Mirrors MySQL.update.await. Replaces SetCertificationTier's UPDATE.
function K9Store.Cert_SetTier(citizenid, job, tier)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.update.await('UPDATE k9_certifications SET tier = ? WHERE citizenid = ? AND job = ? AND active = 1', { tier, citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return 0 end
    row.tier = tier
    return 1
end

--- Mirrors MySQL.update.await. Replaces RenewCertification's UPDATE.
function K9Store.Cert_RenewExpiry(citizenid, job, expiryDays)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.update.await('UPDATE k9_certifications SET expires_at = DATE_ADD(NOW(), INTERVAL ? DAY) WHERE citizenid = ? AND job = ? AND active = 1', { expiryDays, citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return 0 end
    row.expires_at_unix = NowUnix() + expiryDays * 86400
    return 1
end

--- Mirrors MySQL.single.await. Replaces QueryCertificationRecord's own
--- row read (that function still layers QueryActiveSpecializations on
--- top itself -- unchanged, that is a separate table/call below).
function K9Store.Cert_GetActiveRecord(citizenid, job)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.single.await(
            'SELECT tier, granted_by, granted_at, revoked_by, revoked_at, revoke_reason, UNIX_TIMESTAMP(expires_at) AS expires_at_unix ' ..
            'FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1', { citizenid, job })
    end
    local row = CertFindActive(citizenid, job)
    if not row then return nil end
    return {
        tier = row.tier, granted_by = row.granted_by, granted_at = row.granted_at,
        revoked_by = row.revoked_by, revoked_at = row.revoked_at, revoke_reason = row.revoke_reason,
        expires_at_unix = row.expires_at_unix,
    }
end

--- Mirrors the SafeQuery contract server/admin.lua's own
--- QueryCertificationHistory ('/k9audit cert') used (fixed here to actually
--- match it -- this function used to call MySQL.query.await un-pcalled,
--- which would have thrown a raw Lua error out of a migrated call site
--- where the original always degraded to zero rows; see this file's own
--- header "CONTRACT DISCIPLINE" for why a caller must never have to change
--- its error handling to adopt this accessor). MEMORY-MODE SCOPE NOTE:
--- only rows created THIS SESSION exist to return -- a restart already
--- erased anything older, per this file's header. Not a bug to fix here;
--- it is the documented cost of Config.Database.enabled = false.
--- @return table rows -- newest first, always a table, empty on failure
function K9Store.Cert_GetHistory(citizenid, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_certifications') then
        local sql = ('SELECT job, granted_by, granted_at, revoked_by, revoked_at, active FROM k9_certifications WHERE citizenid = ? ORDER BY granted_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[John-K9] datastore: Cert_GetHistory query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #CertRows, 1, -1 do
        local row = CertRows[i]
        if row.citizenid == citizenid then
            out[#out + 1] = { job = row.job, granted_by = row.granted_by, granted_at = row.granted_at, revoked_by = row.revoked_by, revoked_at = row.revoked_at, active = row.active }
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors the SafeQuery contract server/admin.lua's own
--- QueryDepartmentRoster ('/k9audit dept') used -- CURRENT roster only. See
--- Cert_GetHistory's own doc comment immediately above for why this needs
--- the pcall wrap (same fix, same reasoning).
--- @return table rows -- always a table, empty on failure
function K9Store.Cert_GetActiveRosterByJob(job, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_certifications') then
        local sql = ('SELECT citizenid, granted_by, granted_at FROM k9_certifications WHERE job = ? AND active = 1 ORDER BY granted_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { job })
        if not ok then
            print(('[John-K9] datastore: Cert_GetActiveRosterByJob query failed for job=%s: %s'):format(tostring(job), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #CertRows, 1, -1 do
        local row = CertRows[i]
        if row.job == job and row.active == 1 then
            out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = row.granted_at }
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors the SafeQuery contract server/tablet.lua's own
--- BuildCertificationsArray uses -- every ACTIVE cert row for ONE
--- citizenid across ALL configured departments, columns job+granted_by,
--- UNORDERED (the caller re-keys this by job itself against a small,
--- fixed-size Config.Departments map, so no ordering is ever needed on
--- this side). Added THIS pass specifically because no existing accessor
--- returns this shape -- Cert_GetActiveIdAnyJob (above) is a scalar
--- existence check only, and every OTHER Cert_* accessor is scoped to one
--- (citizenid, job) pair, not "every job for one citizenid" -- see
--- server/tablet.lua's own "K9STORE MIGRATION NOTE" (on that file's former
--- SafeQuery) for the full context this accessor closes out.
--- @return table rows -- always a table, empty on failure
function K9Store.Cert_GetActiveJobsForCitizen(citizenid)
    if DatabaseEnabled('k9_certifications') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT job, granted_by FROM k9_certifications WHERE citizenid = ? AND active = 1', { citizenid })
        if not ok then
            print(('[John-K9] datastore: Cert_GetActiveJobsForCitizen query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for _, row in ipairs(CertRows) do
        if row.active == 1 and row.citizenid == citizenid then
            out[#out + 1] = { job = row.job, granted_by = row.granted_by }
        end
    end
    return out
end

--- Mirrors the SafeQuery contract server/tablet.lua's own
--- tabletRequestRoster per-department fetch uses -- active certs for ONE
--- job, columns citizenid+granted_by, LIMIT applied, DELIBERATELY NO
--- ORDER BY. NOT a duplicate of Cert_GetActiveRosterByJob above -- that
--- one adds `ORDER BY granted_at DESC` (server/admin.lua's own shape),
--- which a real EXPLAIN pass server/tablet.lua's own header documents
--- turns this exact query into a filesort; this accessor exists
--- specifically so server/tablet.lua's roster fetch can stay on the
--- filesort-free plan that same header measured. Added THIS pass; do not
--- collapse it back onto Cert_GetActiveRosterByJob.
--- @return table rows -- always a table, empty on failure, NOT sorted
function K9Store.Cert_GetActiveRosterByJobUnordered(job, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_certifications') then
        local sql = ('SELECT citizenid, granted_by FROM k9_certifications WHERE job = ? AND active = 1 LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { job })
        if not ok then
            print(('[John-K9] datastore: Cert_GetActiveRosterByJobUnordered query failed for job=%s: %s'):format(tostring(job), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for _, row in ipairs(CertRows) do
        if row.job == job and row.active == 1 then
            out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by }
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors MySQL.scalar.await DIRECTLY (NOT the SafeQuery/SafeWrite
--- bespoke contract) -- matches server/certtiers.lua's own DeleteTier call
--- site, which pcalls this exactly like a raw `MySQL.scalar.await` today
--- (that function never routed this one through its own local SafeQuery/
--- SafeWrite helpers), so this keeps the SAME "throws on a real DB error,
--- pcall'd by the CALLER" contract every other scalar-mirroring Cert_*
--- function above already has -- see this file's header "CONTRACT
--- DISCIPLINE". DELIBERATELY counts EVERY row (active OR inactive/
--- historical) -- no `active = 1` filter, matching server/certtiers.lua's
--- own header "HAZARD 2" reasoning: "an inactive row still holds a real,
--- audit-trail-relevant tier value that must not start pointing at
--- nothing".
--- @return number count
function K9Store.Cert_CountByTier(tier)
    if DatabaseEnabled('k9_certifications') then
        return MySQL.scalar.await('SELECT COUNT(*) FROM k9_certifications WHERE tier = ?', { tier })
    end
    local count = 0
    for _, row in ipairs(CertRows) do
        if row.tier == tier then count = count + 1 end
    end
    return count
end

-- ======================================================================
-- k9_certification_specializations
--
-- Mirrored from server/certifications/ (RefreshSpecializationCache,
-- RevokeAllSpecializationsForCitizenJob, GrantSpecialization/
-- doGrantInsert, RevokeSpecialization/RevokeSpecializationOffline,
-- QueryActiveSpecializations).
-- ======================================================================
local SpecRows = {}
local SpecNextId = 0

local function SpecFindActive(citizenid, job, specialization)
    for _, row in ipairs(SpecRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job and row.specialization == specialization then
            return row
        end
    end
    return nil
end

--- Mirrors MySQL.query.await. Row shape (`{ specialization = ... }`)
--- matches the real column list exactly, since both call sites this
--- replaces (RefreshSpecializationCache, RevokeAllSpecializationsForCitizenJob)
--- iterate `row.specialization` directly.
function K9Store.Spec_GetActiveKeys(citizenid, job)
    if DatabaseEnabled('k9_certification_specializations') then
        return MySQL.query.await('SELECT specialization FROM k9_certification_specializations WHERE citizenid = ? AND job = ? AND active = 1', { citizenid, job })
    end
    local out = {}
    for _, row in ipairs(SpecRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job then
            out[#out + 1] = { specialization = row.specialization }
        end
    end
    return out
end

--- Mirrors MySQL.scalar.await. Replaces GrantSpecialization's existence check.
function K9Store.Spec_GetActiveId(citizenid, job, specialization)
    if DatabaseEnabled('k9_certification_specializations') then
        return MySQL.scalar.await(
            'SELECT id FROM k9_certification_specializations WHERE citizenid = ? AND job = ? AND specialization = ? AND active = 1 LIMIT 1',
            { citizenid, job, specialization })
    end
    local row = SpecFindActive(citizenid, job, specialization)
    return row and row.id or nil
end

--- Mirrors MySQL.insert.await.
function K9Store.Spec_Insert(citizenid, job, specialization, grantedBy)
    if DatabaseEnabled('k9_certification_specializations') then
        return MySQL.insert.await(
            'INSERT INTO k9_certification_specializations (citizenid, job, specialization, granted_by) VALUES (?, ?, ?, ?)',
            { citizenid, job, specialization, grantedBy })
    end
    if SpecFindActive(citizenid, job, specialization) then
        ThrowDuplicateActiveRow('k9_certification_specializations ' .. citizenid .. '::' .. job .. '::' .. specialization)
    end
    SpecNextId = SpecNextId + 1
    SpecRows[#SpecRows + 1] = {
        id = SpecNextId, citizenid = citizenid, job = job, specialization = specialization, granted_by = grantedBy,
        granted_at = FormatDateTime(NowUnix()), revoked_by = nil, revoked_at = nil, active = 1,
    }
    return SpecNextId
end

--- Mirrors MySQL.update.await. Replaces RevokeSpecialization/
--- RevokeSpecializationOffline's (byte-identical) UPDATE.
function K9Store.Spec_RevokeOne(citizenid, job, specialization, revokedBy)
    if DatabaseEnabled('k9_certification_specializations') then
        return MySQL.update.await(
            'UPDATE k9_certification_specializations SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND specialization = ? AND active = 1',
            { revokedBy, citizenid, job, specialization })
    end
    local row = SpecFindActive(citizenid, job, specialization)
    if not row then return 0 end
    row.active, row.revoked_by, row.revoked_at = 0, revokedBy, FormatDateTime(NowUnix())
    return 1
end

--- Mirrors MySQL.update.await. Replaces
--- RevokeAllSpecializationsForCitizenJob's bulk UPDATE (cascades every
--- active specialization for one (citizenid, job) pair at once).
function K9Store.Spec_RevokeAllForJob(citizenid, job, revokedBy)
    if DatabaseEnabled('k9_certification_specializations') then
        return MySQL.update.await(
            'UPDATE k9_certification_specializations SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
            { revokedBy, citizenid, job })
    end
    local count = 0
    for _, row in ipairs(SpecRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job then
            row.active, row.revoked_by, row.revoked_at = 0, revokedBy, FormatDateTime(NowUnix())
            count = count + 1
        end
    end
    return count
end

-- ======================================================================
-- k9_partnerships
--
-- Mirrored from server/partnership.lua (RefreshPartnershipCache, the
-- establish critical section's two pre-checks + INSERT, DoBreakPartnership's
-- SELECT/UPDATE/reconciliation), server/tenure.lua (CheckTenureMilestonesForK9)
-- and server/admin.lua (QueryPartnershipHistory, both roles).
--
-- TWO INDEPENDENT UNIQUENESS DIMENSIONS, exactly like the real schema's
-- two separate UNIQUE KEYs: a citizenid may not appear as an ACTIVE party
-- in more than one row, whether as the K9 or as the handler. Enforced
-- below the same way the real INSERT's two DB-level UNIQUE KEYs do --
-- reject on EITHER party already being active in any row.
-- ======================================================================
local PartnerRows = {}
local PartnerNextId = 0

--- @return table? row -- the FULL internal row (includes established_at_unix)
local function PartnerFindActiveRowByParty(citizenid)
    for _, row in ipairs(PartnerRows) do
        if row.active == 1 and (row.k9_citizenid == citizenid or row.handler_citizenid == citizenid) then
            return row
        end
    end
    return nil
end

local function PartnerFindById(id)
    for _, row in ipairs(PartnerRows) do
        if row.id == id then return row end
    end
    return nil
end

--- Mirrors MySQL.single.await. Replaces RefreshPartnershipCache's own
--- read and DoBreakPartnership's initial SELECT (both select `id,
--- k9_citizenid, handler_citizenid` for either-role lookup).
function K9Store.Partner_GetActiveRowByParty(citizenid)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.single.await(
            'SELECT id, k9_citizenid, handler_citizenid FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
            { citizenid, citizenid })
    end
    local row = PartnerFindActiveRowByParty(citizenid)
    if not row then return nil end
    return { id = row.id, k9_citizenid = row.k9_citizenid, handler_citizenid = row.handler_citizenid }
end

--- Mirrors MySQL.scalar.await. Replaces the establish critical section's
--- two identical pre-INSERT existence checks (one per party).
function K9Store.Partner_GetActiveIdByParty(citizenid)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.scalar.await(
            'SELECT id FROM k9_partnerships WHERE active = 1 AND (k9_citizenid = ? OR handler_citizenid = ?) LIMIT 1',
            { citizenid, citizenid })
    end
    local row = PartnerFindActiveRowByParty(citizenid)
    return row and row.id or nil
end

--- Mirrors MySQL.insert.await. THROWS a duplicate-active-row error (memory
--- mode) if EITHER party already has an active row -- mirrors the real
--- schema's two independent UNIQUE KEYs backstopping the same INSERT.
function K9Store.Partner_Insert(k9Citizenid, handlerCitizenid, establishedBy)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.insert.await('INSERT INTO k9_partnerships (k9_citizenid, handler_citizenid, established_by) VALUES (?, ?, ?)', { k9Citizenid, handlerCitizenid, establishedBy })
    end
    if PartnerFindActiveRowByParty(k9Citizenid) then ThrowDuplicateActiveRow('k9_partnerships k9=' .. k9Citizenid) end
    if PartnerFindActiveRowByParty(handlerCitizenid) then ThrowDuplicateActiveRow('k9_partnerships handler=' .. handlerCitizenid) end
    PartnerNextId = PartnerNextId + 1
    PartnerRows[#PartnerRows + 1] = {
        id = PartnerNextId, k9_citizenid = k9Citizenid, handler_citizenid = handlerCitizenid, established_by = establishedBy,
        established_at_unix = NowUnix(), established_at = FormatDateTime(NowUnix()),
        ended_by = nil, ended_at = nil, active = 1, tenure_bonus_tier_granted = 0,
    }
    return PartnerNextId
end

--- Mirrors MySQL.update.await. Replaces DoBreakPartnership's UPDATE
--- (`WHERE id = ? AND active = 1`).
function K9Store.Partner_EndById(id, endedBy)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.update.await('UPDATE k9_partnerships SET active = 0, ended_by = ?, ended_at = CURRENT_TIMESTAMP WHERE id = ? AND active = 1', { endedBy, id })
    end
    local row = PartnerFindById(id)
    if not row or row.active ~= 1 then return 0 end
    local endedAtNow = NowUnix()
    -- `ended_at_unix` ADDED this pass (Partners tab, coder-ui) alongside the
    -- pre-existing `established_at_unix` Partner_Insert already stamps --
    -- mirrors PartnerHistoryColumns' own new field below, so a memory-mode
    -- history row can report a real elapsed duration without a date parser.
    row.active, row.ended_by, row.ended_at, row.ended_at_unix = 0, endedBy, FormatDateTime(endedAtNow), endedAtNow
    return 1
end

--- Mirrors MySQL.scalar.await. Replaces DoBreakPartnership's
--- reconciliation read (`SELECT active FROM k9_partnerships WHERE id = ?
--- LIMIT 1`) -- deliberately looks up by id ALONE, regardless of current
--- `active` value, matching the real query's own unfiltered WHERE clause.
function K9Store.Partner_GetActiveFlagById(id)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.scalar.await('SELECT active FROM k9_partnerships WHERE id = ? LIMIT 1', { id })
    end
    local row = PartnerFindById(id)
    return row and row.active or nil
end

--- `established_at_unix`/`ended_at_unix`/`tenure_bonus_tier_granted` ADDED
--- this pass (Partners tab, coder-ui) -- additive fields only, every
--- existing consumer (server/admin.lua's QueryPartnershipHistory) already
--- tolerates extra table keys it doesn't read. Mirrors the DB-mode SELECT's
--- own new `UNIX_TIMESTAMP(...)`/`tenure_bonus_tier_granted` columns below
--- so memory mode and DB mode return the identical shape, matching this
--- file's own established mirroring discipline.
local function PartnerHistoryColumns(row)
    return {
        id = row.id, k9_citizenid = row.k9_citizenid, handler_citizenid = row.handler_citizenid,
        established_by = row.established_by, established_at = row.established_at,
        established_at_unix = row.established_at_unix,
        ended_by = row.ended_by, ended_at = row.ended_at, ended_at_unix = row.ended_at_unix,
        active = row.active, tenure_bonus_tier_granted = row.tenure_bonus_tier_granted,
    }
end

--- Mirrors the SafeQuery contract server/admin.lua's own
--- QueryPartnershipHistory K9-side sub-query used -- fixed here to actually
--- match it (see Cert_GetHistory's own doc comment above for why an
--- un-pcalled MySQL.query.await would have broken a migrated call site
--- that feeds this straight into MergeSortedByIdDesc, which never expects
--- a thrown error). MergeSortedByIdDesc's own two-way merge additionally
--- REQUIRES both sub-queries to independently return a table, never nil,
--- on a failure of just one of the two -- this fail-closed contract is
--- what guarantees that.
--- @return table rows -- always a table, empty on failure
function K9Store.Partner_GetHistoryByK9(citizenid, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_partnerships') then
        -- `tenure_bonus_tier_granted`/`UNIX_TIMESTAMP(...)` ADDED this pass
        -- (Partners tab, coder-ui) -- additive columns only, appended after
        -- every pre-existing one so a positional consumer (none today) is
        -- never affected; NULL for a never-established/still-active
        -- `ended_at` exactly mirrors memory mode's own nil `ended_at_unix`.
        local columns = 'id, k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active, tenure_bonus_tier_granted, UNIX_TIMESTAMP(established_at) AS established_at_unix, UNIX_TIMESTAMP(ended_at) AS ended_at_unix'
        local sql = ('SELECT %s FROM k9_partnerships WHERE k9_citizenid = ? ORDER BY id DESC LIMIT %d'):format(columns, limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[John-K9] datastore: Partner_GetHistoryByK9 query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #PartnerRows, 1, -1 do
        if PartnerRows[i].k9_citizenid == citizenid then
            out[#out + 1] = PartnerHistoryColumns(PartnerRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors the SafeQuery contract server/admin.lua's own
--- QueryPartnershipHistory handler-side sub-query used. See
--- Partner_GetHistoryByK9's own doc comment immediately above for why this
--- needs the pcall wrap (same fix, same reasoning).
--- @return table rows -- always a table, empty on failure
function K9Store.Partner_GetHistoryByHandler(citizenid, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_partnerships') then
        -- `tenure_bonus_tier_granted`/`UNIX_TIMESTAMP(...)` ADDED this pass
        -- (Partners tab, coder-ui) -- additive columns only, appended after
        -- every pre-existing one so a positional consumer (none today) is
        -- never affected; NULL for a never-established/still-active
        -- `ended_at` exactly mirrors memory mode's own nil `ended_at_unix`.
        local columns = 'id, k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active, tenure_bonus_tier_granted, UNIX_TIMESTAMP(established_at) AS established_at_unix, UNIX_TIMESTAMP(ended_at) AS ended_at_unix'
        local sql = ('SELECT %s FROM k9_partnerships WHERE handler_citizenid = ? ORDER BY id DESC LIMIT %d'):format(columns, limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[John-K9] datastore: Partner_GetHistoryByHandler query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #PartnerRows, 1, -1 do
        if PartnerRows[i].handler_citizenid == citizenid then
            out[#out + 1] = PartnerHistoryColumns(PartnerRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Mirrors MySQL.single.await. Replaces server/tenure.lua's
--- CheckTenureMilestonesForK9 read. `tenure_seconds` is computed the same
--- way SQL's TIMESTAMPDIFF(SECOND, established_at, NOW()) would (both
--- measured against real wall-clock time; in memory mode a restart resets
--- tenure to zero along with everything else in this table).
function K9Store.Partner_GetTenureRow(k9Citizenid)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.single.await(
            'SELECT id, k9_citizenid, handler_citizenid, tenure_bonus_tier_granted, TIMESTAMPDIFF(SECOND, established_at, NOW()) AS tenure_seconds FROM k9_partnerships WHERE active = 1 AND k9_citizenid = ? LIMIT 1',
            { k9Citizenid })
    end
    for _, row in ipairs(PartnerRows) do
        if row.active == 1 and row.k9_citizenid == k9Citizenid then
            return {
                id = row.id, k9_citizenid = row.k9_citizenid, handler_citizenid = row.handler_citizenid,
                tenure_bonus_tier_granted = row.tenure_bonus_tier_granted,
                tenure_seconds = NowUnix() - row.established_at_unix,
            }
        end
    end
    return nil
end

--- Mirrors MySQL.update.await. Replaces CheckTenureMilestonesForK9's
--- optimistic CAS UPDATE -- only applies `newTier` if the row is still
--- active AND its `tenure_bonus_tier_granted` still equals
--- `expectedOldTier` (a lost race returns 0, exactly like the real
--- UPDATE's affected-row count would).
function K9Store.Partner_SetTenureTierCAS(id, newTier, expectedOldTier)
    if DatabaseEnabled('k9_partnerships') then
        return MySQL.update.await(
            'UPDATE k9_partnerships SET tenure_bonus_tier_granted = ? WHERE id = ? AND active = 1 AND tenure_bonus_tier_granted = ?',
            { newTier, id, expectedOldTier })
    end
    local row = PartnerFindById(id)
    if not row or row.active ~= 1 or row.tenure_bonus_tier_granted ~= expectedOldTier then return 0 end
    row.tenure_bonus_tier_granted = newTier
    return 1
end

-- ======================================================================
-- k9_partnership_pair_progress
--
-- Mirrored from server/partnership.lua (CaptureTenureSeedForPair, the
-- establish critical section's own seed read) -- migration 0018 / this
-- table's own header in sql/install.sql for the full "why a table, not a
-- column on k9_partnerships" writeup (also restated in server/tenure.lua's
-- "TENURE PROGRESSION EXTENSIONS" item 3, the design this table
-- implements verbatim). THE FULLY DURABLE REPLACEMENT for what used to be
-- server/partnership.lua's own in-memory-only `PairTenureSeed` table: keyed
-- by the PAIR (k9_citizenid, handler_citizenid), never by partnership id,
-- so a value written here outlives any one k9_partnerships row being
-- superseded by a brand-new one on reform, AND survives a genuine resource
-- restart when Config.Database.enabled = true (the exact gap the old
-- in-memory-only table could not close -- see that table's own former
-- header comment, preserved in git history, for the full "why in-memory,
-- why not TTL'd" reasoning this table now makes moot for the DB-on case).
-- ======================================================================
local PairProgressRows = {} -- pairKey (see PairProgressKey) -> { highest_tenure_tier_granted = number }

--- @param k9Citizenid string
--- @param handlerCitizenid string
--- @return string
local function PairProgressKey(k9Citizenid, handlerCitizenid)
    return k9Citizenid .. ':' .. handlerCitizenid
end

--- Mirrors MySQL.scalar.await. Replaces server/partnership.lua's own
--- former in-memory `PairTenureSeed[pairKey]` read at establish time.
--- @return number? highestTierGranted -- nil if this EXACT (k9, handler) pair has never had a milestone tier captured for it
function K9Store.PairProgress_GetHighestTenureTier(k9Citizenid, handlerCitizenid)
    if DatabaseEnabled('k9_partnership_pair_progress') then
        return MySQL.scalar.await(
            'SELECT highest_tenure_tier_granted FROM k9_partnership_pair_progress WHERE k9_citizenid = ? AND handler_citizenid = ? LIMIT 1',
            { k9Citizenid, handlerCitizenid })
    end
    local row = PairProgressRows[PairProgressKey(k9Citizenid, handlerCitizenid)]
    return row and row.highest_tenure_tier_granted or nil
end

--- Mirrors MySQL.insert.await -- an UPSERT that never LOWERS the stored
--- tier (`GREATEST(...)`, matching this resource's own "an already-earned
--- milestone is never re-grantable" invariant): writing a tier smaller
--- than what is already on file for this exact pair is a genuine no-op,
--- never a regression. Throws only on a real DB-mode error; there is no
--- uniqueness conflict to reject in an atomic upsert.
--- @param k9Citizenid string
--- @param handlerCitizenid string
--- @param tier number -- the tier just confirmed granted (k9_partnerships.tenure_bonus_tier_granted at capture time)
--- @return number insertId -- unused by every real caller today; returned only for parity with MySQL.insert.await's own contract
function K9Store.PairProgress_UpsertHighestTenureTier(k9Citizenid, handlerCitizenid, tier)
    if DatabaseEnabled('k9_partnership_pair_progress') then
        return MySQL.insert.await(
            'INSERT INTO k9_partnership_pair_progress (k9_citizenid, handler_citizenid, highest_tenure_tier_granted) VALUES (?, ?, ?) ' ..
            'ON DUPLICATE KEY UPDATE highest_tenure_tier_granted = GREATEST(highest_tenure_tier_granted, VALUES(highest_tenure_tier_granted))',
            { k9Citizenid, handlerCitizenid, tier })
    end
    local key = PairProgressKey(k9Citizenid, handlerCitizenid)
    local row = PairProgressRows[key]
    if not row then
        row = { highest_tenure_tier_granted = 0 }
        PairProgressRows[key] = row
    end
    if tier > row.highest_tenure_tier_granted then
        row.highest_tenure_tier_granted = tier
    end
    return 1
end

-- ======================================================================
-- k9_permissions
--
-- Mirrored from server/permissions.lua (RefreshPermissionCache,
-- IsPermissionRowConfirmedActive, GrantPermission/doGrantInsert,
-- RevokePermission) and server/tablet.lua (QueryActivePermissionSet).
-- ======================================================================
local PermRows = {}
local PermNextId = 0

local function PermFindActive(citizenid, permission)
    for _, row in ipairs(PermRows) do
        if row.active == 1 and row.citizenid == citizenid and row.permission == permission then
            return row
        end
    end
    return nil
end

--- Mirrors MySQL.scalar.await. Replaces IsPermissionRowConfirmedActive's
--- read and GrantPermission's own pre-check.
function K9Store.Perm_GetActiveId(citizenid, permission)
    if DatabaseEnabled('k9_permissions') then
        return MySQL.scalar.await('SELECT id FROM k9_permissions WHERE citizenid = ? AND permission = ? AND active = 1 LIMIT 1', { citizenid, permission })
    end
    local row = PermFindActive(citizenid, permission)
    return row and row.id or nil
end

--- Mirrors MySQL.query.await. Row shape (`{ permission = ... }`) matches
--- the real single-column SELECT -- both RefreshPermissionCache and
--- server/tablet.lua's QueryActivePermissionSet iterate `row.permission`
--- directly.
function K9Store.Perm_GetActiveForCitizen(citizenid)
    if DatabaseEnabled('k9_permissions') then
        return MySQL.query.await('SELECT permission FROM k9_permissions WHERE citizenid = ? AND active = 1', { citizenid })
    end
    local out = {}
    for _, row in ipairs(PermRows) do
        if row.active == 1 and row.citizenid == citizenid then
            out[#out + 1] = { permission = row.permission }
        end
    end
    return out
end

--- Mirrors MySQL.insert.await.
function K9Store.Perm_Insert(citizenid, permission, grantedBy)
    if DatabaseEnabled('k9_permissions') then
        return MySQL.insert.await('INSERT INTO k9_permissions (citizenid, permission, granted_by) VALUES (?, ?, ?)', { citizenid, permission, grantedBy })
    end
    if PermFindActive(citizenid, permission) then ThrowDuplicateActiveRow('k9_permissions ' .. citizenid .. '::' .. permission) end
    PermNextId = PermNextId + 1
    PermRows[#PermRows + 1] = {
        id = PermNextId, citizenid = citizenid, permission = permission, granted_by = grantedBy,
        granted_at = FormatDateTime(NowUnix()), revoked_by = nil, revoked_at = nil, active = 1,
    }
    return PermNextId
end

--- Mirrors MySQL.update.await. Replaces RevokePermission's UPDATE.
function K9Store.Perm_RevokeActive(citizenid, permission, revokedBy)
    if DatabaseEnabled('k9_permissions') then
        return MySQL.update.await('UPDATE k9_permissions SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND permission = ? AND active = 1', { revokedBy, citizenid, permission })
    end
    local row = PermFindActive(citizenid, permission)
    if not row then return 0 end
    row.active, row.revoked_by, row.revoked_at = 0, revokedBy, FormatDateTime(NowUnix())
    return 1
end

--- Mirrors the SafeQuery contract server/admin.lua's own Cert_GetHistory/
--- Cert_GetActiveRosterByJob use (see those functions' own doc comments for
--- the full "why this needs the pcall wrap" reasoning) -- replaces
--- server/permissions.lua's own ListActivePermissionsForCitizenId, which
--- previously ran this exact SQL through that file's local generic
--- SafeQuery(sql, params) helper. No LIMIT clause -- the real query never
--- had one (a citizenid's own full grant history, not a roster-style
--- capped list).
--- @return table rows -- newest first, always a table, empty on failure
function K9Store.Perm_GetHistoryByCitizenId(citizenid)
    if DatabaseEnabled('k9_permissions') then
        local ok, rowsOrErr = pcall(MySQL.query.await,
            'SELECT permission, granted_by, granted_at FROM k9_permissions WHERE citizenid = ? AND active = 1 ORDER BY granted_at DESC',
            { citizenid })
        if not ok then
            print(('[John-K9] datastore: Perm_GetHistoryByCitizenId query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #PermRows, 1, -1 do
        local row = PermRows[i]
        if row.citizenid == citizenid and row.active == 1 then
            out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = row.granted_at }
        end
    end
    return out
end

--- Mirrors the SafeQuery contract, same as Perm_GetHistoryByCitizenId
--- immediately above -- replaces server/permissions.lua's own
--- ListPermissionRoster (the tablet's "who currently holds this
--- permission" view). No LIMIT clause, matching the real query exactly.
--- @return table rows -- newest-granted first, always a table, empty on failure
function K9Store.Perm_GetActiveRosterByPermission(permissionKey)
    if DatabaseEnabled('k9_permissions') then
        local ok, rowsOrErr = pcall(MySQL.query.await,
            'SELECT citizenid, granted_by, granted_at FROM k9_permissions WHERE permission = ? AND active = 1 ORDER BY granted_at DESC',
            { permissionKey })
        if not ok then
            print(('[John-K9] datastore: Perm_GetActiveRosterByPermission query failed for permission=%s: %s'):format(tostring(permissionKey), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #PermRows, 1, -1 do
        local row = PermRows[i]
        if row.permission == permissionKey and row.active == 1 then
            out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = row.granted_at }
        end
    end
    return out
end

--- Mirrors MySQL.scalar.await. Replaces server/permissionkeycatalog.lua's
--- own DeleteKey informational read -- how many CURRENTLY ACTIVE grant rows
--- reference `permissionKey` right now, at the moment a high-command officer
--- tombstones the catalog key that names it. Purely informational (see that
--- file's own header "TOMBSTONE, NOT REFERENCE-COUNTED" section for why a
--- non-zero count never refuses the delete the way Cert_CountByTier's
--- equivalent does for a certification tier) -- deliberately counts ONLY
--- `active = 1` rows, unlike Cert_CountByTier's own deliberate omission of
--- that filter, because this number exists purely to tell the deleting
--- officer "this many handlers lose this capability the instant you confirm",
--- which a long-revoked historical row has no bearing on.
--- @return number count
function K9Store.Perm_CountActiveByPermission(permissionKey)
    if DatabaseEnabled('k9_permissions') then
        return MySQL.scalar.await('SELECT COUNT(*) FROM k9_permissions WHERE permission = ? AND active = 1', { permissionKey })
    end
    local count = 0
    for _, row in ipairs(PermRows) do
        if row.permission == permissionKey and row.active == 1 then count = count + 1 end
    end
    return count
end

-- ======================================================================
-- k9_progression
--
-- Mirrored from server/progression.lua (LoadXPForCitizenid, AwardXP's/
-- AwardXPDirect's UPSERT) and server/admin.lua/server/leaderboard.lua's
-- own read queries. UNLIKE the four "active-row" tables above, this one
-- is a live profile row (one per citizenid, upserted in place) -- see
-- sql/install.sql's own k9_progression header for why.
-- ======================================================================
local ProgressionRows = {} -- citizenid -> { xp = number, created_at_unix, updated_at_unix }

--- Mirrors MySQL.scalar.await. Replaces LoadXPForCitizenid's read.
--- @return number? xp -- nil if this citizenid has no row yet (matches the
--- real query's own nil-on-no-row shape; every existing caller already
--- treats nil as "0 XP", see LoadXPForCitizenid's own `xpOrErr or 0`).
function K9Store.XP_Get(citizenid)
    if DatabaseEnabled('k9_progression') then
        return MySQL.scalar.await('SELECT xp FROM k9_progression WHERE citizenid = ? LIMIT 1', { citizenid })
    end
    local row = ProgressionRows[citizenid]
    return row and row.xp or nil
end

--- Mirrors MySQL.insert.await -- an UPSERT that always "succeeds" (throws
--- only on a genuine DB-mode error; there is no uniqueness conflict to
--- reject in an atomic add-or-create). Callers keep their own
--- CreateThread/pcall wrapping around this call UNCHANGED (see this
--- file's header "CONTRACT DISCIPLINE") -- this function does not spawn
--- a thread itself, so the non-blocking behavior server/progression.lua's
--- AwardXP/AwardXPDirect already implement is preserved exactly as-is,
--- memory mode included (a plain table write here is already instant,
--- never a reason to defer it).
--- @param delta number -- the per-award DELTA, never the new running total
--- @return number insertId -- unused by every real caller today; returned only for parity with MySQL.insert.await's own contract
function K9Store.XP_UpsertAdd(citizenid, delta)
    if DatabaseEnabled('k9_progression') then
        return MySQL.insert.await(
            'INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?) ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP',
            { citizenid, delta })
    end
    local row = ProgressionRows[citizenid]
    if not row then
        row = { xp = 0, created_at_unix = NowUnix() }
        ProgressionRows[citizenid] = row
    end
    row.xp = row.xp + delta
    row.updated_at_unix = NowUnix()
    return 1
end

--- Mirrors MySQL.query.await. Replaces server/leaderboard.lua's
--- QueryTopXp. MEMORY-MODE SCOPE NOTE: ranks only citizenids this PROCESS
--- has actually touched via XP_Get/XP_UpsertAdd this session (typically:
--- everyone who has connected, or been queried, since the last restart)
--- -- there is no durable roster to rank an offline citizenid nobody has
--- interacted with yet against, which is the expected shape of a
--- session-only leaderboard, not a bug.
function K9Store.XP_GetTop(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_progression') then
        local sql = ('SELECT citizenid, xp FROM k9_progression ORDER BY xp DESC LIMIT %d'):format(limit)
        return MySQL.query.await(sql, {})
    end
    local list = {}
    for citizenid, row in pairs(ProgressionRows) do
        list[#list + 1] = { citizenid = citizenid, xp = row.xp }
    end
    table.sort(list, function(a, b) return a.xp > b.xp end)
    local out = {}
    for i = 1, math.min(limit, #list) do out[i] = list[i] end
    return out
end

--- Mirrors the SafeQuery contract server/admin.lua's own
--- QueryProgressionSnapshot ('/k9audit xp') uses -- an array of 0 or 1 rows.
function K9Store.XP_GetSnapshotRows(citizenid)
    if DatabaseEnabled('k9_progression') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT xp, updated_at FROM k9_progression WHERE citizenid = ? LIMIT 1', { citizenid })
        if not ok then
            print(('[John-K9] datastore: XP_GetSnapshotRows query failed for %s: %s'):format(citizenid, tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local row = ProgressionRows[citizenid]
    if not row then return {} end
    return { { xp = row.xp, updated_at = FormatDateTime(row.updated_at_unix or row.created_at_unix) } }
end

-- ----------------------------------------------------------------------
-- handler_xp -- a SECOND, INDEPENDENT accumulated total on this SAME
-- `k9_progression` row (added by sql/migrations/0017_add_k9_progression_
-- handler_xp.sql; sql/install.sql already carries it for a fresh install).
-- Mirrored from server/progression.lua's AwardHandlerXP/GetHandlerXPTier --
-- see config.lua's own Config.HandlerXPTiers header for the full "why a
-- second column, not a second reading of `xp`" reasoning.
--
-- DELIBERATELY NOT in EXPECTED_TABLE_COLUMNS['k9_progression'] above (see
-- sql/install.sql's own `k9_progression` header, the paragraph right after
-- its CREATE TABLE, for the full reasoning already recorded there): that
-- list is a STABLE, FOUNDING column signature used to detect a genuine
-- name collision, and `handler_xp` has not been true of every
-- k9_progression row since the table was created the way
-- citizenid/xp/created_at/updated_at have -- including it there would
-- misreport every real installation that has not yet applied migration
-- 0017 as a foreign-table collision and disable MySQL for the entire
-- resource. A pre-0017 database is therefore a normal, expected case here,
-- not a bug -- both accessors below degrade it safely rather than assume
-- the column exists.
--
-- READ CONTRACT: HandlerXP_Get mirrors XP_Get's own raw-mirror-of-
-- MySQL.scalar.await contract exactly (throws on a genuine DB-mode error,
-- including "Unknown column 'handler_xp'" against a pre-migration-0017
-- database) -- the caller (server/progression.lua's own
-- LoadHandlerXPForCitizenid, mirroring LoadXPForCitizenid) is what
-- pcall-wraps this and degrades a missing column to a safe 0-handler-XP
-- baseline, exactly like LoadXPForCitizenid already does for XP_Get.
--
-- WRITE CONTRACT, DELIBERATELY DIFFERENT FROM XP_UpsertAdd: XP_UpsertAdd
-- above raw-mirrors MySQL.insert.await (throws to its own caller, which
-- wraps it in a CreateThread + pcall of its own). HandlerXP_UpsertAdd
-- instead mirrors this file's SafeWrite contract (boolean, never throws --
-- same shape as Override_Upsert/Override_Delete above), so a write against
-- a not-yet-migrated database (or any other genuine DB error) degrades to
-- a plain `false` AwardHandlerXP can check directly, rather than an error
-- string its own pcall has to unwrap. Chosen for this second, newer
-- accessor specifically so that contract is exercised by a real caller
-- from day one, rather than only ever existing as an unused convention
-- elsewhere in this file.
--- @return number? handlerXp -- nil if this citizenid has no row yet (matches XP_Get's own nil-on-no-row shape)
function K9Store.HandlerXP_Get(citizenid)
    if DatabaseEnabled('k9_progression') then
        return MySQL.scalar.await('SELECT handler_xp FROM k9_progression WHERE citizenid = ? LIMIT 1', { citizenid })
    end
    local row = ProgressionRows[citizenid]
    return row and row.handler_xp or nil
end

--- Mirrors the SafeWrite contract (boolean, never throws) -- see this
--- section's own header immediately above for why this accessor's contract
--- deliberately differs from its `xp`-column sibling, XP_UpsertAdd.
--- @param delta number -- the per-award DELTA, never the new running total
--- @return boolean ok
function K9Store.HandlerXP_UpsertAdd(citizenid, delta)
    if DatabaseEnabled('k9_progression') then
        local ok, err = pcall(MySQL.insert.await,
            'INSERT INTO k9_progression (citizenid, handler_xp) VALUES (?, ?) ON DUPLICATE KEY UPDATE handler_xp = handler_xp + VALUES(handler_xp), updated_at = CURRENT_TIMESTAMP',
            { citizenid, delta })
        if not ok then
            print(('[John-K9] datastore: HandlerXP_UpsertAdd write failed for %s (has sql/migrations/0017_add_k9_progression_handler_xp.sql been applied?): %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local row = ProgressionRows[citizenid]
    if not row then
        row = { xp = 0, handler_xp = 0, created_at_unix = NowUnix() }
        ProgressionRows[citizenid] = row
    end
    row.handler_xp = (row.handler_xp or 0) + delta
    row.updated_at_unix = NowUnix()
    return true
end

-- ======================================================================
-- k9_wellbeing
--
-- Mirrored from server/wellbeing.lua's own K9Store.Wellbeing_Get/
-- K9Store.Wellbeing_Upsert call sites (EnsureStats' own load path;
-- FlushDirtyWellbeingStats/FlushWellbeingEntryNow's own write path -- see
-- that file's header "DATABASE PERSISTENCE" section for the full design
-- these two accessors exist to back). ONE ROW PER CITIZENID, upserted in
-- place -- same "live profile row, not an append-mostly audit log" shape
-- as k9_progression immediately above, not k9_certifications' shape.
-- sql/migrations/0022_create_k9_wellbeing.sql is this table's owner
-- migration; sql/install.sql carries the identical CREATE TABLE for a
-- fresh install.
-- ======================================================================
local WellbeingRows = {} -- citizenid -> { fatigue, updated_at_unix }

--- Mirrors MySQL.single.await exactly -- nil for no row, same raw-mirror
--- contract as Cert_GetActiveMeta above (throws on a genuine DB-mode
--- error; NOT pcall-wrapped here on purpose -- server/wellbeing.lua's own
--- EnsureStats already pcalls this call site and degrades a throw to
--- EXACTLY the same fresh-default construction it already uses for a nil
--- return, per that file's header "FAIL DIRECTION, STATED EXPLICITLY" --
--- wrapping it a second time here would only hide a real error from that
--- caller's own diagnostic print). The SELECT names its columns
--- explicitly so the returned row's keys match server/wellbeing.lua's own
--- reads with no remapping needed at the call site.
--- @param citizenid string
--- @return table? row -- { fatigue }, or nil if this citizenid has no row yet
function K9Store.Wellbeing_Get(citizenid)
    if DatabaseEnabled('k9_wellbeing') then
        -- Reads FATIGUE ONLY. The mood, fear_stress, injury, hunger and
        -- thirst columns still exist on k9_wellbeing but their systems were
        -- removed on 2026-09-02, so nothing writes or reads them any more.
        -- They are left in place deliberately: dropping a column from a
        -- table that may already hold a server's data is destructive and
        -- irreversible, so that is the owner's call to make with a
        -- migration, not something this resource does on their behalf.
        return MySQL.single.await(
            'SELECT fatigue FROM k9_wellbeing WHERE citizenid = ? LIMIT 1',
            { citizenid })
    end
    local row = WellbeingRows[citizenid]
    if not row then return nil end
    return { fatigue = row.fatigue }
end

--- Mirrors the SafeWrite contract (boolean, never throws) -- same shape as
--- Override_Upsert above, chosen over XP_UpsertAdd's raw-mirror-and-throw
--- contract because `row` always carries ABSOLUTE, already-clamped values
--- (never a delta to accumulate server-side) -- k9_runtime_feature_overrides'
--- own "the caller already knows the final value, just persist it" shape,
--- not k9_progression's "atomic increment-or-create" one.
--- server/wellbeing.lua's own FlushDirtyWellbeingStats/
--- FlushWellbeingEntryNow already treat "threw" and "returned false"
--- identically (both leave `stats.dirty` untouched so the next flush
--- retries the same row), so never throwing here costs that caller
--- nothing while sparing every call site its own pcall wrapper.
--- @param citizenid string
--- @param row table -- the persisted numeric fields, already clamped to each stat's own range by the caller: fatigue
--- @return boolean ok
function K9Store.Wellbeing_Upsert(citizenid, row)
    if DatabaseEnabled('k9_wellbeing') then
        -- Writes FATIGUE ONLY -- see Wellbeing_Get above for why the other
        -- five columns are left alone rather than dropped.
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_wellbeing (citizenid, fatigue) VALUES (?, ?) ' ..
            'ON DUPLICATE KEY UPDATE fatigue = VALUES(fatigue), updated_at = CURRENT_TIMESTAMP',
            { citizenid, row.fatigue })
        if not ok then
            print(('[John-K9] datastore: Wellbeing_Upsert write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    WellbeingRows[citizenid] = {
        fatigue = row.fatigue,
        updated_at_unix = NowUnix(),
    }
    return true
end

-- ======================================================================
-- k9_search_log
--
-- Mirrored from server/search.lua (LogSearchAttempt's INSERT) and
-- server/admin.lua's four read shapes (QuerySearchLogByOfficer/ByPlate/
-- ByPerson/Recent). THE ONE TABLE THIS SCHEMA DESIGNS TO GROW WITHOUT
-- LIMIT (sql/install.sql's own header) -- its memory mirror is therefore
-- a FIXED-CAPACITY RING BUFFER, never an ever-growing Lua table, so
-- Config.Database.enabled = false cannot become a slow memory leak on a
-- long-uptime server. `id` still increases monotonically even as old
-- rows are evicted, so 'ORDER BY id DESC' (QuerySearchLogRecent's own
-- sort key) stays meaningful throughout.
-- ======================================================================
local SEARCH_LOG_MEMORY_CAP = 500
local SearchLogRows = {}
local SearchLogNextId = 0

--- Mirrors MySQL.insert.await.
function K9Store.SearchLog_Insert(searcherCitizenid, searcherJob, targetType, targetPlate, targetCitizenid, result, totalWeight, alertTier)
    if DatabaseEnabled('k9_search_log') then
        return MySQL.insert.await([[
            INSERT INTO k9_search_log
                (searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ]], { searcherCitizenid, searcherJob, targetType, targetPlate, targetCitizenid, result, totalWeight, alertTier })
    end
    SearchLogNextId = SearchLogNextId + 1
    SearchLogRows[#SearchLogRows + 1] = {
        id = SearchLogNextId, searcher_citizenid = searcherCitizenid, searcher_job = searcherJob,
        target_type = targetType, target_plate = targetPlate, target_citizenid = targetCitizenid,
        result = result, total_weight = totalWeight, alert_tier = alertTier, searched_at = FormatDateTime(NowUnix()),
    }
    -- RING BUFFER: drop the oldest row once over capacity -- see header.
    while #SearchLogRows > SEARCH_LOG_MEMORY_CAP do
        table.remove(SearchLogRows, 1)
    end
    return SearchLogNextId
end

local function SearchLogColumns(row)
    return {
        searcher_citizenid = row.searcher_citizenid, searcher_job = row.searcher_job, target_type = row.target_type,
        target_plate = row.target_plate, target_citizenid = row.target_citizenid, result = row.result,
        total_weight = row.total_weight, alert_tier = row.alert_tier, searched_at = row.searched_at, id = row.id,
    }
end

--- Mirrors the SafeQuery contract server/admin.lua's SafeQuery uses.
--- Replaces QuerySearchLogByOfficer ('/k9audit search officer').
function K9Store.SearchLog_GetByOfficer(citizenid, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_search_log') then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log WHERE searcher_citizenid = ? ORDER BY searched_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[John-K9] datastore: SearchLog_GetByOfficer query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        if SearchLogRows[i].searcher_citizenid == citizenid then
            out[#out + 1] = SearchLogColumns(SearchLogRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Replaces QuerySearchLogByPlate ('/k9audit search plate').
function K9Store.SearchLog_GetByPlate(plate, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_search_log') then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log WHERE target_plate = ? ORDER BY searched_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { plate })
        if not ok then
            print(('[John-K9] datastore: SearchLog_GetByPlate query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        if SearchLogRows[i].target_plate == plate then
            out[#out + 1] = SearchLogColumns(SearchLogRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Replaces QuerySearchLogByPerson ('/k9audit search person').
function K9Store.SearchLog_GetByPerson(citizenid, limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_search_log') then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log WHERE target_citizenid = ? ORDER BY searched_at DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, { citizenid })
        if not ok then
            print(('[John-K9] datastore: SearchLog_GetByPerson query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        if SearchLogRows[i].target_citizenid == citizenid then
            out[#out + 1] = SearchLogColumns(SearchLogRows[i])
            if #out >= limit then break end
        end
    end
    return out
end

--- Replaces QuerySearchLogRecent ('/k9audit search recent') -- ordered by
--- `id DESC`, not `searched_at`, matching the real query exactly (see
--- that function's own doc comment for why).
function K9Store.SearchLog_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_search_log') then
        local sql = ('SELECT searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at, id FROM k9_search_log ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: SearchLog_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #SearchLogRows, 1, -1 do
        out[#out + 1] = SearchLogColumns(SearchLogRows[i])
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_runtime_feature_overrides / k9_runtime_override_audit
--
-- Mirrored from server/runtimecontrol.lua. The override table is a plain
-- key-value store (PRIMARY KEY on override_key, one row per key, upserted
-- in place) -- NOT an "active-row" table, so no generated-key uniqueness
-- engine is needed here. The audit table is a pure append-only log, same
-- "bounded in memory mode" treatment as k9_search_log above, but with a
-- smaller cap: these rows come from rare, high-command-gated admin
-- actions, not ordinary gameplay, so real-world volume is tiny -- the cap
-- exists as a hygiene backstop, not because this table is expected to
-- ever approach it.
-- ======================================================================
local OverrideRows = {} -- override_key -> { override_key, kind, value, updated_by, updated_at }
local OVERRIDE_AUDIT_MEMORY_CAP = 200
local OverrideAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces runtimecontrol.lua's
--- onResourceStart boot read (re-applying persisted overrides on top of
--- config.lua's defaults) -- IN MEMORY MODE THIS IS ALWAYS EMPTY ON A
--- FRESH PROCESS, by construction (there is nothing to have persisted
--- across the restart that just happened), so runtimecontrol.lua's own
--- boot loop naturally applies zero overrides and leaves config.lua's
--- shipped defaults in effect -- exactly the documented behavior.
function K9Store.Override_GetAll()
    if DatabaseEnabled('k9_runtime_feature_overrides') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT override_key, kind, value, updated_by, updated_at FROM k9_runtime_feature_overrides', {})
        if not ok then
            print(('[John-K9] datastore: Override_GetAll query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for _, row in pairs(OverrideRows) do
        out[#out + 1] = { override_key = row.override_key, kind = row.kind, value = row.value, updated_by = row.updated_by, updated_at = row.updated_at }
    end
    return out
end

--- Mirrors the SafeWrite contract (boolean, never throws). Replaces every
--- `INSERT ... ON DUPLICATE KEY UPDATE` write against
--- k9_runtime_feature_overrides.
function K9Store.Override_Upsert(overrideKey, kind, value, updatedBy)
    if DatabaseEnabled('k9_runtime_feature_overrides') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_runtime_feature_overrides (override_key, kind, value, updated_by) VALUES (?, ?, ?, ?) ' ..
            'ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { overrideKey, kind, value, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Override_Upsert write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    OverrideRows[overrideKey] = { override_key = overrideKey, kind = kind, value = value, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()) }
    return true
end

--- Mirrors the SafeWrite contract. Replaces the `DELETE FROM
--- k9_runtime_feature_overrides WHERE override_key = ?` reset path.
function K9Store.Override_Delete(overrideKey)
    if DatabaseEnabled('k9_runtime_feature_overrides') then
        local ok, err = pcall(MySQL.query.await, 'DELETE FROM k9_runtime_feature_overrides WHERE override_key = ?', { overrideKey })
        if not ok then
            print(('[John-K9] datastore: Override_Delete write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    OverrideRows[overrideKey] = nil
    return true
end

--- Mirrors the SafeWrite contract. `newValue` may be nil (the "reset back
--- to default" shape the real INSERT already allows via a NULL column).
function K9Store.OverrideAudit_Append(overrideKey, kind, oldValue, newValue, changedBy)
    if DatabaseEnabled('k9_runtime_override_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_runtime_override_audit (override_key, kind, old_value, new_value, changed_by) VALUES (?, ?, ?, ?, ?)',
            { overrideKey, kind, oldValue, newValue, changedBy })
        if not ok then
            print(('[John-K9] datastore: OverrideAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    OverrideAuditRows[#OverrideAuditRows + 1] = { override_key = overrideKey, kind = kind, old_value = oldValue, new_value = newValue, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #OverrideAuditRows > OVERRIDE_AUDIT_MEMORY_CAP do
        table.remove(OverrideAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE (owner-directed "full control ... accountability" pass --
--- every catalog-edit audit table was write-only until this pass; see
--- server/admin.lua's own new `john-k9:server:tabletAuditCatalog`
--- callback for the tablet-facing consumer this backs). Mirrors the
--- SafeQuery contract exactly (K9Store.SearchLog_GetRecent's own shape,
--- immediately above this section) -- most recent first, bounded by
--- SanitizeLimit, NEVER throws, ALWAYS a table. `Config.Database.enabled =
--- false`: returns whatever THIS session's own OverrideAudit_Append calls
--- have accumulated in `OverrideAuditRows` so far (empty on a fresh session
--- with no edits yet this pass, per this file's own established
--- "everything still works, forgotten on next restart" story -- see this
--- file's own header) -- never a hardcoded empty regardless of real
--- in-memory state, which would silently contradict every other
--- `K9Store.*_GetAll*`/`*_GetRecent` accessor's own documented behavior in
--- this exact same file.
--- @param limit any
--- @return table rows -- { { override_key, kind, old_value, new_value, changed_by, changed_at }, ... }, most recent first
function K9Store.OverrideAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_runtime_override_audit') then
        local sql = ('SELECT override_key, kind, old_value, new_value, changed_by, changed_at FROM k9_runtime_override_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: OverrideAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #OverrideAuditRows, 1, -1 do
        local row = OverrideAuditRows[i]
        out[#out + 1] = { override_key = row.override_key, kind = row.kind, old_value = row.old_value, new_value = row.new_value, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_tablet_theme / k9_tablet_theme_audit
--
-- Mirrored from server/runtimecontrol.lua. k9_tablet_theme is a SINGLETON
-- (always exactly one row, id = 1, per that table's own sql/install.sql
-- header) -- the memory mirror is simply one Lua table or nil, never a
-- keyed store. k9_tablet_theme_audit is append-only, same bounded
-- treatment as the runtime-override audit log above and for the same
-- reason (rare, high-command-gated admin action, not gameplay volume).
-- ======================================================================
local ThemeRow = nil
local THEME_AUDIT_MEMORY_CAP = 200
local ThemeAuditRows = {}

--- Mirrors the SafeQuery contract -- an array of 0 or 1 rows, matching
--- runtimecontrol.lua's own onResourceStart read exactly.
function K9Store.Theme_GetRows()
    if DatabaseEnabled('k9_tablet_theme') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT primary_color, accent_color, background_color, text_color, density, header_title FROM k9_tablet_theme WHERE id = 1', {})
        if not ok then
            print(('[John-K9] datastore: Theme_GetRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    if not ThemeRow then return {} end
    return { { primary_color = ThemeRow.primary_color, accent_color = ThemeRow.accent_color, background_color = ThemeRow.background_color, text_color = ThemeRow.text_color, density = ThemeRow.density, header_title = ThemeRow.header_title } }
end

--- Mirrors the SafeWrite contract. Replaces both tabletSetTheme's and
--- tabletResetTheme's identical `INSERT ... ON DUPLICATE KEY UPDATE`
--- against the id=1 singleton row.
function K9Store.Theme_Upsert(primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, updatedBy)
    if DatabaseEnabled('k9_tablet_theme') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_tablet_theme (id, primary_color, accent_color, background_color, text_color, density, header_title, updated_by) ' ..
            'VALUES (1, ?, ?, ?, ?, ?, ?, ?) ' ..
            'ON DUPLICATE KEY UPDATE primary_color = VALUES(primary_color), accent_color = VALUES(accent_color), ' ..
            'background_color = VALUES(background_color), text_color = VALUES(text_color), density = VALUES(density), ' ..
            'header_title = VALUES(header_title), updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Theme_Upsert write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ThemeRow = {
        primary_color = primaryColor, accent_color = accentColor, background_color = backgroundColor,
        text_color = textColor, density = density, header_title = headerTitle,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
    }
    return true
end

--- Mirrors the SafeWrite contract.
function K9Store.ThemeAudit_Append(primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, changedBy)
    if DatabaseEnabled('k9_tablet_theme_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_tablet_theme_audit (primary_color, accent_color, background_color, text_color, density, header_title, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { primaryColor, accentColor, backgroundColor, textColor, density, headerTitle, changedBy })
        if not ok then
            print(('[John-K9] datastore: ThemeAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ThemeAuditRows[#ThemeAuditRows + 1] = {
        primary_color = primaryColor, accent_color = accentColor, background_color = backgroundColor,
        text_color = textColor, density = density, header_title = headerTitle,
        changed_by = changedBy, changed_at = FormatDateTime(NowUnix()),
    }
    while #ThemeAuditRows > THEME_AUDIT_MEMORY_CAP do
        table.remove(ThemeAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- immediately above the k9_runtime_override_audit section for the full
--- contract this mirrors exactly (SafeQuery, most recent first, bounded,
--- never throws, real in-memory data when Config.Database.enabled = false).
--- @param limit any
--- @return table rows -- { { primary_color, accent_color, background_color, text_color, density, header_title, changed_by, changed_at }, ... }, most recent first
function K9Store.ThemeAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_tablet_theme_audit') then
        local sql = ('SELECT primary_color, accent_color, background_color, text_color, density, header_title, changed_by, changed_at FROM k9_tablet_theme_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: ThemeAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #ThemeAuditRows, 1, -1 do
        local row = ThemeAuditRows[i]
        out[#out + 1] = {
            primary_color = row.primary_color, accent_color = row.accent_color, background_color = row.background_color,
            text_color = row.text_color, density = row.density, header_title = row.header_title,
            changed_by = row.changed_by, changed_at = row.changed_at,
        }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_ped_assignments
--
-- Mirrored from server/appearance.lua (GetAppearanceRow,
-- WriteAppearanceApplied, WriteAppearanceReverted, and the
-- original_model_hash backfill UPDATE). PRIMARY KEY is `citizenid` alone
-- on the real schema (current-state bookkeeping, not an audit log, per
-- sql/migrations/0008's own header) -- the memory mirror is a plain
-- citizenid-keyed map for the same reason.
-- ======================================================================
local AssignmentRows = {} -- citizenid -> { model, original_model_hash, active }

--- Mirrors GetAppearanceRow's own contract (single row or nil, already
--- pcall-wrapped internally on the DB side).
function K9Store.Appearance_GetRow(citizenid)
    if DatabaseEnabled('k9_ped_assignments') then
        local ok, rows = pcall(MySQL.query.await, 'SELECT model, original_model_hash, active FROM k9_ped_assignments WHERE citizenid = ? LIMIT 1', { citizenid })
        if not ok then
            print(('[John-K9] datastore: Appearance_GetRow query failed for %s: %s'):format(citizenid, tostring(rows)))
            return nil
        end
        return rows and rows[1] or nil
    end
    local row = AssignmentRows[citizenid]
    if not row then return nil end
    return { model = row.model, original_model_hash = row.original_model_hash, active = row.active }
end

--- Mirrors WriteAppearanceApplied's own boolean contract, INCLUDING its
--- exact "preserve the existing original_model_hash if the current row is
--- still active" COALESCE semantics -- the real SQL's
--- `COALESCE(VALUES(original_model_hash), original_model_hash)` is
--- reproduced here verbatim so this still behaves correctly even if a
--- caller migrated to this function without also carrying over
--- appearance.lua's own pre-read `keepOriginal` computation.
function K9Store.Appearance_UpsertApplied(citizenid, model, originalHash, appliedByLabel)
    if DatabaseEnabled('k9_ped_assignments') then
        local ok, err = pcall(MySQL.query.await, [[
            INSERT INTO k9_ped_assignments (citizenid, model, original_model_hash, active, applied_by, applied_at, revoked_at)
            VALUES (?, ?, ?, 1, ?, CURRENT_TIMESTAMP, NULL)
            ON DUPLICATE KEY UPDATE
                model = VALUES(model),
                original_model_hash = COALESCE(VALUES(original_model_hash), original_model_hash),
                active = 1,
                applied_by = VALUES(applied_by),
                applied_at = CURRENT_TIMESTAMP,
                revoked_at = NULL
        ]], { citizenid, model, originalHash, appliedByLabel })
        if not ok then
            print(('[John-K9] datastore: Appearance_UpsertApplied write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local existing = AssignmentRows[citizenid]
    local coalescedHash = originalHash
    if coalescedHash == nil and existing then coalescedHash = existing.original_model_hash end
    AssignmentRows[citizenid] = {
        model = model, original_model_hash = coalescedHash, active = 1,
        applied_by = appliedByLabel, applied_at_unix = NowUnix(), revoked_at = nil,
    }
    return true
end

--- Mirrors WriteAppearanceReverted's own boolean contract.
function K9Store.Appearance_MarkReverted(citizenid)
    if DatabaseEnabled('k9_ped_assignments') then
        local ok, err = pcall(MySQL.query.await, 'UPDATE k9_ped_assignments SET active = 0, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND active = 1', { citizenid })
        if not ok then
            print(('[John-K9] datastore: Appearance_MarkReverted write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local row = AssignmentRows[citizenid]
    if row and row.active == 1 then
        row.active = 0
        row.revoked_at = FormatDateTime(NowUnix())
    end
    return true
end

--- Mirrors the conditional backfill UPDATE
--- (`WHERE citizenid = ? AND active = 1 AND original_model_hash IS NULL`)
--- used when a persisted, offline-created assignment never had its first
--- swap attempt's original hash captured.
function K9Store.Appearance_SetOriginalHashIfMissing(citizenid, hash)
    if DatabaseEnabled('k9_ped_assignments') then
        local ok, err = pcall(MySQL.query.await, 'UPDATE k9_ped_assignments SET original_model_hash = ? WHERE citizenid = ? AND active = 1 AND original_model_hash IS NULL', { hash, citizenid })
        if not ok then
            print(('[John-K9] datastore: Appearance_SetOriginalHashIfMissing write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local row = AssignmentRows[citizenid]
    if row and row.active == 1 and row.original_model_hash == nil then
        row.original_model_hash = hash
    end
    return true
end

-- ======================================================================
-- k9_equipment_shop_locations / k9_equipment_shop_locations_audit
--
-- Mirrored from server/equipmentshop.lua's own SafeQuery/SafeWrite/
-- SafeInsert helpers (that file's RUNTIME SHOP LOCATIONS section --
-- migration 0011, the newest table in this schema). Those three helpers
-- are this resource's own bespoke wrapper contracts (a pcall'd
-- boolean/empty-table-on-failure shape), NOT oxmysql's raw ones -- see
-- this file's header "CONTRACT DISCIPLINE" for why the functions below
-- keep that SAME bespoke contract rather than the raw scalar/insert/
-- update one, exactly like the Cert_GetHistory/Perm_GetHistoryByCitizenId/
-- etc. functions above already do for the identical reason.
--
-- k9_equipment_shop_locations is a current-state table (one row per
-- tablet-added location, PRIMARY KEY id) -- the memory mirror is a plain
-- id-keyed map, same shape as AssignmentRows above. Its audit companion
-- is append-only, same bounded-in-memory-mode treatment as
-- k9_runtime_override_audit/k9_tablet_theme_audit above and for the same
-- reason (rare, high-command-gated admin action, not gameplay volume).
-- ======================================================================
local ShopLocationRows = {} -- id -> { x, y, z, heading, model, scenario, label, created_by, updated_by }
local ShopLocationNextId = 0
local SHOP_LOCATION_AUDIT_MEMORY_CAP = 200
local ShopLocationAuditRows = {}

--- Mirrors server/equipmentshop.lua's own SafeQuery contract (always a
--- table, empty on failure, never throws). Replaces the boot-time
--- `SELECT id, x, y, z, heading, model, scenario, label FROM
--- k9_equipment_shop_locations` read.
--- @return table rows
function K9Store.ShopLocation_GetAll()
    if DatabaseEnabled('k9_equipment_shop_locations') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT id, x, y, z, heading, model, scenario, label FROM k9_equipment_shop_locations', {})
        if not ok then
            print(('[John-K9] datastore: ShopLocation_GetAll query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for id, row in pairs(ShopLocationRows) do
        out[#out + 1] = { id = id, x = row.x, y = row.y, z = row.z, heading = row.heading, model = row.model, scenario = row.scenario, label = row.label }
    end
    return out
end

--- Mirrors server/equipmentshop.lua's own SafeInsert contract (`ok,
--- insertId` -- never throws, `ok = false` on failure). Replaces
--- equipmentShopAddLocation's `INSERT INTO k9_equipment_shop_locations
--- (...) VALUES (...)`.
--- @return boolean ok, number? insertId
function K9Store.ShopLocation_Insert(x, y, z, heading, model, scenario, label, createdBy)
    if DatabaseEnabled('k9_equipment_shop_locations') then
        local ok, resultOrErr = pcall(MySQL.insert.await,
            'INSERT INTO k9_equipment_shop_locations (x, y, z, heading, model, scenario, label, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            { x, y, z, heading, model, scenario, label, createdBy })
        if not ok or type(resultOrErr) ~= 'number' then
            print(('[John-K9] datastore: ShopLocation_Insert failed: %s'):format(tostring(resultOrErr)))
            return false, nil
        end
        return true, resultOrErr
    end
    ShopLocationNextId = ShopLocationNextId + 1
    ShopLocationRows[ShopLocationNextId] = { x = x, y = y, z = z, heading = heading, model = model, scenario = scenario, label = label, created_by = createdBy, updated_by = nil }
    return true, ShopLocationNextId
end

--- Mirrors server/equipmentshop.lua's own SafeWrite contract (boolean,
--- never throws). Replaces equipmentShopMoveLocation's `UPDATE
--- k9_equipment_shop_locations SET ... WHERE id = ?`.
--- @return boolean ok
function K9Store.ShopLocation_Update(x, y, z, heading, model, scenario, label, updatedBy, id)
    if DatabaseEnabled('k9_equipment_shop_locations') then
        local ok, err = pcall(MySQL.query.await,
            'UPDATE k9_equipment_shop_locations SET x = ?, y = ?, z = ?, heading = ?, model = ?, scenario = ?, label = ?, updated_by = ? WHERE id = ?',
            { x, y, z, heading, model, scenario, label, updatedBy, id })
        if not ok then
            print(('[John-K9] datastore: ShopLocation_Update failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    local row = ShopLocationRows[id]
    if row then
        row.x, row.y, row.z, row.heading, row.model, row.scenario, row.label, row.updated_by = x, y, z, heading, model, scenario, label, updatedBy
    end
    return true
end

--- Mirrors server/equipmentshop.lua's own SafeWrite contract. Replaces
--- equipmentShopRemoveLocation's `DELETE FROM k9_equipment_shop_locations
--- WHERE id = ?`.
--- @return boolean ok
function K9Store.ShopLocation_Delete(id)
    if DatabaseEnabled('k9_equipment_shop_locations') then
        local ok, err = pcall(MySQL.query.await, 'DELETE FROM k9_equipment_shop_locations WHERE id = ?', { id })
        if not ok then
            print(('[John-K9] datastore: ShopLocation_Delete failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ShopLocationRows[id] = nil
    return true
end

--- Mirrors server/equipmentshop.lua's own SafeWrite contract. Replaces
--- every one of that file's identical `INSERT INTO
--- k9_equipment_shop_locations_audit (...) VALUES (...)` calls (add/move/
--- remove all share this one shape).
--- @return boolean ok
function K9Store.ShopLocationAudit_Insert(locationId, action, x, y, z, heading, model, scenario, label, changedBy)
    if DatabaseEnabled('k9_equipment_shop_locations_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_equipment_shop_locations_audit (location_id, action, x, y, z, heading, model, scenario, label, changed_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            { locationId, action, x, y, z, heading, model, scenario, label, changedBy })
        if not ok then
            print(('[John-K9] datastore: ShopLocationAudit_Insert failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ShopLocationAuditRows[#ShopLocationAuditRows + 1] = {
        location_id = locationId, action = action, x = x, y = y, z = z, heading = heading,
        model = model, scenario = scenario, label = label, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()),
    }
    while #ShopLocationAuditRows > SHOP_LOCATION_AUDIT_MEMORY_CAP do
        table.remove(ShopLocationAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- (k9_runtime_override_audit section, above) for the full contract this
--- mirrors exactly.
--- @param limit any
--- @return table rows -- { { location_id, action, x, y, z, heading, model, scenario, label, changed_by, changed_at }, ... }, most recent first
function K9Store.ShopLocationAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_equipment_shop_locations_audit') then
        local sql = ('SELECT location_id, action, x, y, z, heading, model, scenario, label, changed_by, changed_at FROM k9_equipment_shop_locations_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: ShopLocationAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #ShopLocationAuditRows, 1, -1 do
        local row = ShopLocationAuditRows[i]
        out[#out + 1] = {
            location_id = row.location_id, action = row.action, x = row.x, y = row.y, z = row.z, heading = row.heading,
            model = row.model, scenario = row.scenario, label = row.label, changed_by = row.changed_by, changed_at = row.changed_at,
        }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_certification_tiers / k9_certification_tier_capabilities /
-- k9_certification_tier_audit
--
-- Mirrored from server/certtiers.lua (the owner-directed "high command can
-- edit K9 cert tiers at runtime" pass) -- RefreshCertificationTierCatalog's
-- two catalog reads, certTiersUpsert/certTiersReorder/certTiersDelete's
-- own writes, and WriteTierAudit. That file's local SafeQuery/SafeWrite
-- helpers are gone; every read/write below goes through these K9Store.
-- Tier_*/TierCap_*/TierAudit_Append accessors instead, mirroring the exact
-- SafeQuery/SafeWrite bespoke contract (never throws) those two local
-- helpers already had -- see this file's header "CONTRACT DISCIPLINE".
--
-- k9_certification_tiers / k9_certification_tier_capabilities are BOTH
-- current-state tables (one row per tier_key / per (tier_key,
-- capability_key) pair, a real PRIMARY KEY per migration 0010's own
-- header, no generated-key uniqueness engine needed) -- their memory
-- mirrors are plain keyed maps, same shape as OverrideRows/ShopLocationRows
-- above. k9_certification_tier_audit is append-only, same bounded-in-
-- memory-mode ring-buffer treatment as every other rare/admin-gated audit
-- table in this file (k9_runtime_override_audit, k9_tablet_theme_audit,
-- k9_equipment_shop_locations_audit) -- this surface is high-command-gated,
-- not ordinary gameplay volume, per migration 0010's own header.
-- ======================================================================
local TierRows = {}    -- tier_key -> { tier_key, label, ordinal, deleted, updated_by, updated_at, created_at_unix }
local TierCapRows = {} -- tier_key -> { [capability_key] = { granted_by, granted_at } }
local TIER_AUDIT_MEMORY_CAP = 200
local TierAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces RefreshCertificationTierCatalog's
--- own `SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers`
--- -- every tier row EVER touched by a high-command edit, including
--- tombstoned ones (the `deleted` column is what RefreshCertificationTierCatalog
--- itself filters on, not this accessor).
--- @return table rows
function K9Store.Tier_GetAllRows()
    if DatabaseEnabled('k9_certification_tiers') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers', {})
        if not ok then
            print(('[John-K9] datastore: Tier_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for tierKey, row in pairs(TierRows) do
        out[#out + 1] = { tier_key = tierKey, label = row.label, ordinal = row.ordinal, deleted = row.deleted }
    end
    return out
end

--- Mirrors the SafeQuery contract. Replaces certTiersUpsert's own
--- `SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?`
--- pre-write read (used only to distinguish a 'tier_create' from a
--- 'tier_restore' for the audit trail -- see that callback's own comment).
--- @return table rows -- 0 or 1 rows, `{ { deleted = 0|1 } }` or `{}`
function K9Store.Tier_GetDeletedFlagByKey(tierKey)
    if DatabaseEnabled('k9_certification_tiers') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?', { tierKey })
        if not ok then
            print(('[John-K9] datastore: Tier_GetDeletedFlagByKey query failed for %s: %s'):format(tostring(tierKey), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local row = TierRows[tierKey]
    if not row then return {} end
    return { { deleted = row.deleted } }
end

--- Mirrors the SafeWrite contract. Replaces certTiersUpsert's own
--- `INSERT ... VALUES (?, ?, ?, 0, ?) ON DUPLICATE KEY UPDATE label =
--- VALUES(label), ordinal = VALUES(ordinal), deleted = 0, updated_by =
--- VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` -- always
--- un-tombstones the row (`deleted = 0`) and sets BOTH label and ordinal,
--- whether this is a brand-new key, a restore, or a rename/re-ordinal of
--- an already-live one. NOT the same function as Tier_UpdateOrdinal below
--- -- see that one's own doc comment for exactly why certTiersReorder
--- must never call this one instead.
--- @return boolean ok
function K9Store.Tier_Upsert(tierKey, label, ordinal, updatedBy)
    if DatabaseEnabled('k9_certification_tiers') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_certification_tiers (tier_key, label, ordinal, deleted, updated_by) VALUES (?, ?, ?, 0, ?) ' ..
            'ON DUPLICATE KEY UPDATE label = VALUES(label), ordinal = VALUES(ordinal), deleted = 0, ' ..
            'updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { tierKey, label, ordinal, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Tier_Upsert write failed for %s: %s'):format(tostring(tierKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = TierRows[tierKey]
    TierRows[tierKey] = {
        tier_key = tierKey, label = label, ordinal = ordinal, deleted = 0,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
        created_at_unix = existing and existing.created_at_unix or NowUnix(),
    }
    return true
end

--- Mirrors the SafeWrite contract. Replaces certTiersReorder's own per-key
--- `INSERT ... VALUES (?, ?, ?, 0, ?) ON DUPLICATE KEY UPDATE ordinal =
--- VALUES(ordinal), deleted = 0, updated_by = VALUES(updated_by),
--- updated_at = CURRENT_TIMESTAMP` -- DELIBERATELY DOES NOT TOUCH `label`
--- ON CONFLICT, matching the real SQL's own ON DUPLICATE KEY UPDATE clause
--- exactly (which never mentions that column) -- `label` here is used
--- ONLY for the brand-new-row INSERT branch (a config-only default key,
--- e.g. trainee/senior, that has never had a row in this table before a
--- reorder touches it for the first time).
---
--- NOT INTERCHANGEABLE WITH Tier_Upsert ABOVE, ON PURPOSE (found while
--- migrating, not merely preserved by copy-paste): reusing Tier_Upsert
--- here would let a reorder silently OVERWRITE a label with a STALE
--- in-memory snapshot if it raced a concurrent rename for the SAME key,
--- landing in the narrow window between that rename's own TierEditMutex
--- release and its own RefreshCertificationTierCatalog call (which is
--- what actually refreshes the in-memory label this reorder loop reads).
--- The real SQL closes that hazard structurally, by never writing to
--- `label` at all on this path -- this accessor preserves that exact
--- property; Tier_Upsert's memory-mode branch would not.
--- @return boolean ok
function K9Store.Tier_UpdateOrdinal(tierKey, label, ordinal, updatedBy)
    if DatabaseEnabled('k9_certification_tiers') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_certification_tiers (tier_key, label, ordinal, deleted, updated_by) VALUES (?, ?, ?, 0, ?) ' ..
            'ON DUPLICATE KEY UPDATE ordinal = VALUES(ordinal), deleted = 0, updated_by = VALUES(updated_by), ' ..
            'updated_at = CURRENT_TIMESTAMP',
            { tierKey, label, ordinal, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Tier_UpdateOrdinal write failed for %s: %s'):format(tostring(tierKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = TierRows[tierKey]
    if existing then
        existing.ordinal, existing.deleted, existing.updated_by, existing.updated_at = ordinal, 0, updatedBy, FormatDateTime(NowUnix())
    else
        TierRows[tierKey] = {
            tier_key = tierKey, label = label, ordinal = ordinal, deleted = 0,
            updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()), created_at_unix = NowUnix(),
        }
    end
    return true
end

--- Mirrors the SafeWrite contract. Replaces certTiersDelete's own
--- `INSERT ... VALUES (?, ?, ?, 1, ?) ON DUPLICATE KEY UPDATE deleted = 1,
--- updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` --
--- TOMBSTONES a row (see that file's header "HAZARD 2"), leaving an
--- ALREADY-EXISTING row's label/ordinal untouched, exactly like
--- Tier_UpdateOrdinal above and for the identical reason (the real SQL's
--- own ON DUPLICATE KEY UPDATE clause never mentions those two columns) --
--- `label`/`ordinal` here are used ONLY for the brand-new-row INSERT case
--- (a tier_key that has never had a row in this table before, e.g. a
--- legacy config-only key being tombstoned for the very first time).
--- @return boolean ok
function K9Store.Tier_Tombstone(tierKey, label, ordinal, updatedBy)
    if DatabaseEnabled('k9_certification_tiers') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_certification_tiers (tier_key, label, ordinal, deleted, updated_by) VALUES (?, ?, ?, 1, ?) ' ..
            'ON DUPLICATE KEY UPDATE deleted = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { tierKey, label, ordinal, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Tier_Tombstone write failed for %s: %s'):format(tostring(tierKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = TierRows[tierKey]
    if existing then
        existing.deleted, existing.updated_by, existing.updated_at = 1, updatedBy, FormatDateTime(NowUnix())
    else
        TierRows[tierKey] = {
            tier_key = tierKey, label = label, ordinal = ordinal, deleted = 1,
            updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()), created_at_unix = NowUnix(),
        }
    end
    return true
end

--- Mirrors the SafeQuery contract. Replaces RefreshCertificationTierCatalog's
--- own `SELECT tier_key, capability_key FROM k9_certification_tier_capabilities`
--- -- every currently-granted tier/capability pair, across every tier.
--- @return table rows
function K9Store.TierCap_GetAllRows()
    if DatabaseEnabled('k9_certification_tier_capabilities') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT tier_key, capability_key FROM k9_certification_tier_capabilities', {})
        if not ok then
            print(('[John-K9] datastore: TierCap_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for tierKey, caps in pairs(TierCapRows) do
        for capKey in pairs(caps) do
            out[#out + 1] = { tier_key = tierKey, capability_key = capKey }
        end
    end
    return out
end

--- Mirrors the SafeQuery contract. Replaces certTiersUpsert's own
--- `SELECT capability_key FROM k9_certification_tier_capabilities WHERE
--- tier_key = ?` reconciliation read (the capability set ONE tier
--- currently holds, before diffing against the requested set).
--- @return table rows
function K9Store.TierCap_GetForTier(tierKey)
    if DatabaseEnabled('k9_certification_tier_capabilities') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT capability_key FROM k9_certification_tier_capabilities WHERE tier_key = ?', { tierKey })
        if not ok then
            print(('[John-K9] datastore: TierCap_GetForTier query failed for %s: %s'):format(tostring(tierKey), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    local caps = TierCapRows[tierKey]
    if caps then
        for capKey in pairs(caps) do out[#out + 1] = { capability_key = capKey } end
    end
    return out
end

--- Mirrors the SafeWrite contract. Replaces certTiersUpsert's own
--- `INSERT INTO k9_certification_tier_capabilities (tier_key,
--- capability_key, granted_by) VALUES (?, ?, ?)` (one row per newly-added
--- capability, called once per capability inside that callback's own
--- reconciliation loop).
--- @return boolean ok
function K9Store.TierCap_Insert(tierKey, capabilityKey, grantedBy)
    if DatabaseEnabled('k9_certification_tier_capabilities') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_certification_tier_capabilities (tier_key, capability_key, granted_by) VALUES (?, ?, ?)',
            { tierKey, capabilityKey, grantedBy })
        if not ok then
            print(('[John-K9] datastore: TierCap_Insert write failed for %s/%s: %s'):format(tostring(tierKey), tostring(capabilityKey), tostring(err)))
            return false
        end
        return true
    end
    TierCapRows[tierKey] = TierCapRows[tierKey] or {}
    TierCapRows[tierKey][capabilityKey] = { granted_by = grantedBy, granted_at = FormatDateTime(NowUnix()) }
    return true
end

--- Mirrors the SafeWrite contract. Replaces certTiersUpsert's own
--- `DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND
--- capability_key = ?` (one row per newly-removed capability, called once
--- per capability inside that same reconciliation loop).
--- @return boolean ok
function K9Store.TierCap_Delete(tierKey, capabilityKey)
    if DatabaseEnabled('k9_certification_tier_capabilities') then
        local ok, err = pcall(MySQL.query.await, 'DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND capability_key = ?', { tierKey, capabilityKey })
        if not ok then
            print(('[John-K9] datastore: TierCap_Delete write failed for %s/%s: %s'):format(tostring(tierKey), tostring(capabilityKey), tostring(err)))
            return false
        end
        return true
    end
    if TierCapRows[tierKey] then TierCapRows[tierKey][capabilityKey] = nil end
    return true
end

--- Mirrors the SafeWrite contract. Replaces WriteTierAudit's own `INSERT
--- INTO k9_certification_tier_audit (action, tier_key, detail, changed_by)
--- VALUES (?, ?, ?, ?)` -- append-only, bounded in memory mode like every
--- other rare/admin-gated audit table in this file (see header above).
--- @return boolean ok
function K9Store.TierAudit_Append(action, tierKey, detail, changedBy)
    if DatabaseEnabled('k9_certification_tier_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_certification_tier_audit (action, tier_key, detail, changed_by) VALUES (?, ?, ?, ?)',
            { action, tierKey, detail, changedBy })
        if not ok then
            print(('[John-K9] datastore: TierAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    TierAuditRows[#TierAuditRows + 1] = { action = action, tier_key = tierKey, detail = detail, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #TierAuditRows > TIER_AUDIT_MEMORY_CAP do
        table.remove(TierAuditRows, 1)
    end
    return true
end

-- ======================================================================
-- k9_roles -- the K9 role catalog (server/roles.lua): each role's label,
-- the XP it switches on at and what it unlocks, overlaid on the roles
-- config.lua ships (Config.K9Specializations). Current-state table, one
-- row per role_key, tombstoned (deleted = 1) rather than DELETEd so a
-- config-shipped role can be removed too -- the same shape as
-- k9_certification_tiers above. Same never-throws SafeQuery/SafeWrite
-- contract as every accessor in this file.
-- ======================================================================
local RoleRows = {} -- role_key -> { role_key, label, xp_required, unlocks, deleted, updated_by, updated_at }

--- Every role row ever written, tombstones included (server/roles.lua
--- filters on `deleted`).
--- @return table rows
function K9Store.Role_GetAllRows()
    if DatabaseEnabled('k9_roles') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT role_key, label, xp_required, unlocks, deleted FROM k9_roles', {})
        if not ok then
            print(('[John-K9] datastore: Role_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for roleKey, row in pairs(RoleRows) do
        out[#out + 1] = { role_key = roleKey, label = row.label, xp_required = row.xp_required, unlocks = row.unlocks, deleted = row.deleted }
    end
    return out
end

--- Creates or updates a role (always un-tombstones it).
--- @return boolean ok
function K9Store.Role_Upsert(roleKey, label, xpRequired, unlocks, updatedBy)
    if DatabaseEnabled('k9_roles') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_roles (role_key, label, xp_required, unlocks, deleted, updated_by) VALUES (?, ?, ?, ?, 0, ?) ' ..
            'ON DUPLICATE KEY UPDATE label = VALUES(label), xp_required = VALUES(xp_required), unlocks = VALUES(unlocks), ' ..
            'deleted = 0, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { roleKey, label, xpRequired, unlocks, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Role_Upsert write failed for %s: %s'):format(tostring(roleKey), tostring(err)))
            return false
        end
        return true
    end
    RoleRows[roleKey] = { role_key = roleKey, label = label, xp_required = xpRequired, unlocks = unlocks, deleted = 0,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()) }
    return true
end

--- Removes a role (a tombstone row, so a config-shipped role stays gone).
--- @return boolean ok
function K9Store.Role_Tombstone(roleKey, label, updatedBy)
    if DatabaseEnabled('k9_roles') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_roles (role_key, label, xp_required, unlocks, deleted, updated_by) VALUES (?, ?, 0, \'\', 1, ?) ' ..
            'ON DUPLICATE KEY UPDATE deleted = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { roleKey, label, updatedBy })
        if not ok then
            print(('[John-K9] datastore: Role_Tombstone write failed for %s: %s'):format(tostring(roleKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = RoleRows[roleKey] or {}
    RoleRows[roleKey] = { role_key = roleKey, label = existing.label or label, xp_required = existing.xp_required or 0,
        unlocks = existing.unlocks or '', deleted = 1, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()) }
    return true
end

-- k9_role_audit -- append-only history of role edits (server/roles.lua),
-- read by the tablet's Audit Trail (Catalog Changes). Same shape and
-- never-throws contract as k9_xp_tier_audit below; a bounded in-memory
-- ring when the table is unavailable.
local ROLE_AUDIT_MEMORY_CAP = 200
local RoleAuditRows = {}

--- @param action string -- 'role_create' | 'role_update' | 'role_delete'
--- @param roleKey string
--- @param detail string
--- @param changedBy string
--- @return boolean ok
function K9Store.RoleAudit_Append(action, roleKey, detail, changedBy)
    if DatabaseEnabled('k9_role_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_role_audit (action, role_key, detail, changed_by) VALUES (?, ?, ?, ?)',
            { action, roleKey, detail, changedBy })
        if not ok then
            print(('[John-K9] datastore: RoleAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    RoleAuditRows[#RoleAuditRows + 1] = { action = action, role_key = roleKey, detail = detail, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #RoleAuditRows > ROLE_AUDIT_MEMORY_CAP do
        table.remove(RoleAuditRows, 1)
    end
    return true
end

--- @param limit any
--- @return table rows -- { { action, role_key, detail, changed_by, changed_at }, ... }, most recent first
function K9Store.RoleAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_role_audit') then
        local sql = ('SELECT action, role_key, detail, changed_by, changed_at FROM k9_role_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: RoleAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #RoleAuditRows, 1, -1 do
        local row = RoleAuditRows[i]
        out[#out + 1] = { action = row.action, role_key = row.role_key, detail = row.detail, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- (k9_runtime_override_audit section, near the top of this file) for the
--- full contract this mirrors exactly.
--- @param limit any
--- @return table rows -- { { action, tier_key, detail, changed_by, changed_at }, ... }, most recent first
function K9Store.TierAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_certification_tier_audit') then
        local sql = ('SELECT action, tier_key, detail, changed_by, changed_at FROM k9_certification_tier_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: TierAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #TierAuditRows, 1, -1 do
        local row = TierAuditRows[i]
        out[#out + 1] = { action = row.action, tier_key = row.tier_key, detail = row.detail, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_permission_keys / k9_permission_key_audit
--
-- Mirrored from server/permissionkeycatalog.lua (the owner-directed
-- "high command can add/remove/relabel K9 permission keys at runtime" pass
-- -- see that file's own header for the full design writeup, which this
-- section deliberately does not repeat). Same "current-state table +
-- append-only audit table" shape as the k9_certification_tier_* section
-- immediately above, minus that section's own capabilities sibling table
-- and ordinal column -- a permission key is just a label/description pair,
-- with no per-key ordering and nothing else to reconcile per write.
--
-- k9_permission_keys is a current-state table (one row per permission_key
-- that has EVER been touched by a high-command edit, migration 0013's own
-- header) -- its memory mirror is a plain keyed map, same shape as
-- TierRows above. k9_permission_key_audit is append-only, same bounded-
-- in-memory-mode ring-buffer treatment as every other rare/admin-gated
-- audit table in this file.
-- ======================================================================
local PermKeyRows = {} -- permission_key -> { label, description, deleted, updated_by, updated_at, created_at_unix }
local PERMKEY_AUDIT_MEMORY_CAP = 200
local PermKeyAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces
--- RefreshPermissionKeyCatalog's own `SELECT permission_key, label,
--- description, deleted FROM k9_permission_keys` -- every permission-key
--- row EVER touched by a high-command edit, including tombstoned ones (the
--- `deleted` column is what RefreshPermissionKeyCatalog itself filters on,
--- not this accessor).
--- @return table rows
function K9Store.PermKey_GetAllRows()
    if DatabaseEnabled('k9_permission_keys') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT permission_key, label, description, deleted FROM k9_permission_keys', {})
        if not ok then
            print(('[John-K9] datastore: PermKey_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for key, row in pairs(PermKeyRows) do
        out[#out + 1] = { permission_key = key, label = row.label, description = row.description, deleted = row.deleted }
    end
    return out
end

--- Mirrors the SafeQuery contract. Replaces permKeysUpsert's own `SELECT
--- deleted FROM k9_permission_keys WHERE permission_key = ?` pre-write read
--- (used only to distinguish a 'permkey_create' from a 'permkey_restore'
--- for the audit trail -- see that callback's own comment).
--- @return table rows -- 0 or 1 rows, `{ { deleted = 0|1 } }` or `{}`
function K9Store.PermKey_GetDeletedFlagByKey(permissionKey)
    if DatabaseEnabled('k9_permission_keys') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT deleted FROM k9_permission_keys WHERE permission_key = ?', { permissionKey })
        if not ok then
            print(('[John-K9] datastore: PermKey_GetDeletedFlagByKey query failed for %s: %s'):format(tostring(permissionKey), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local row = PermKeyRows[permissionKey]
    if not row then return {} end
    return { { deleted = row.deleted } }
end

--- Mirrors the SafeWrite contract. Replaces permKeysUpsert's own `INSERT
--- ... VALUES (?, ?, ?, 0, ?) ON DUPLICATE KEY UPDATE label = VALUES(label),
--- description = VALUES(description), deleted = 0, updated_by =
--- VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` -- always
--- un-tombstones the row (`deleted = 0`) and sets both label and
--- description, whether this is a brand-new key, a restore, or a
--- rename/re-describe of an already-live one.
--- @param description string? -- nil is stored as SQL NULL, matching
--- Config.Permissions[key].description's own optional shape.
--- @return boolean ok
function K9Store.PermKey_Upsert(permissionKey, label, description, updatedBy)
    if DatabaseEnabled('k9_permission_keys') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_permission_keys (permission_key, label, description, deleted, updated_by) VALUES (?, ?, ?, 0, ?) ' ..
            'ON DUPLICATE KEY UPDATE label = VALUES(label), description = VALUES(description), deleted = 0, ' ..
            'updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { permissionKey, label, description, updatedBy })
        if not ok then
            print(('[John-K9] datastore: PermKey_Upsert write failed for %s: %s'):format(tostring(permissionKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = PermKeyRows[permissionKey]
    PermKeyRows[permissionKey] = {
        label = label, description = description, deleted = 0,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
        created_at_unix = existing and existing.created_at_unix or NowUnix(),
    }
    return true
end

--- Mirrors the SafeWrite contract. Replaces permKeysDelete's own `INSERT
--- ... VALUES (?, ?, ?, 1, ?) ON DUPLICATE KEY UPDATE deleted = 1,
--- updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` --
--- TOMBSTONES a row, leaving an ALREADY-EXISTING row's label/description
--- untouched (the real SQL's own ON DUPLICATE KEY UPDATE clause never
--- mentions those two columns) -- `label`/`description` here are used ONLY
--- for the brand-new-row INSERT case (a config-only default key that has
--- never had a row in this table before being tombstoned for the first
--- time).
--- @return boolean ok
function K9Store.PermKey_Tombstone(permissionKey, label, description, updatedBy)
    if DatabaseEnabled('k9_permission_keys') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_permission_keys (permission_key, label, description, deleted, updated_by) VALUES (?, ?, ?, 1, ?) ' ..
            'ON DUPLICATE KEY UPDATE deleted = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { permissionKey, label, description, updatedBy })
        if not ok then
            print(('[John-K9] datastore: PermKey_Tombstone write failed for %s: %s'):format(tostring(permissionKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = PermKeyRows[permissionKey]
    if existing then
        existing.deleted, existing.updated_by, existing.updated_at = 1, updatedBy, FormatDateTime(NowUnix())
    else
        PermKeyRows[permissionKey] = {
            label = label, description = description, deleted = 1,
            updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()), created_at_unix = NowUnix(),
        }
    end
    return true
end

--- Mirrors the SafeWrite contract. Replaces WritePermKeyAudit's own `INSERT
--- INTO k9_permission_key_audit (action, permission_key, detail,
--- changed_by) VALUES (?, ?, ?, ?)` -- append-only, bounded in memory mode
--- like every other rare/admin-gated audit table in this file.
--- @return boolean ok
function K9Store.PermKeyAudit_Append(action, permissionKey, detail, changedBy)
    if DatabaseEnabled('k9_permission_key_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_permission_key_audit (action, permission_key, detail, changed_by) VALUES (?, ?, ?, ?)',
            { action, permissionKey, detail, changedBy })
        if not ok then
            print(('[John-K9] datastore: PermKeyAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    PermKeyAuditRows[#PermKeyAuditRows + 1] = { action = action, permission_key = permissionKey, detail = detail, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #PermKeyAuditRows > PERMKEY_AUDIT_MEMORY_CAP do
        table.remove(PermKeyAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- (k9_runtime_override_audit section, near the top of this file) for the
--- full contract this mirrors exactly.
--- @param limit any
--- @return table rows -- { { action, permission_key, detail, changed_by, changed_at }, ... }, most recent first
function K9Store.PermKeyAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_permission_key_audit') then
        local sql = ('SELECT action, permission_key, detail, changed_by, changed_at FROM k9_permission_key_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: PermKeyAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #PermKeyAuditRows, 1, -1 do
        local row = PermKeyAuditRows[i]
        out[#out + 1] = { action = row.action, permission_key = row.permission_key, detail = row.detail, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_xp_tiers / k9_xp_tier_audit
--
-- Mirrored from server/xptiers.lua (the owner-directed "set experience
-- level for each rank up" pass -- see that file's own header for the full
-- design, including why the overlay is applied by mutating the live
-- `Config.XPTiers[ordinal]` table IN PLACE rather than a second merged
-- catalog structure the way k9_certification_tiers/k9_permission_keys
-- above are). `k9_xp_tiers` is keyed by `ordinal` (the rank's fixed
-- 1-based POSITION in Config.XPTiers, not a string key -- this pass does
-- not add or remove ranks, only edits existing ones in place, so a stable
-- position IS a stable identity here), a current-state table exactly like
-- OverrideRows/TierRows/PermKeyRows above -- one row per rank that has
-- EVER been touched by a high-command edit; a rank's absence from this
-- table means "use Config.XPTiers[ordinal]'s own shipped default". No
-- tombstone/`deleted` flag -- unlike the tier-catalog/permission-key
-- overlays, this one has no delete surface at all (server/xptiers.lua's
-- own header, "SCOPE DECISION"), so there is nothing to tombstone.
-- `k9_xp_tier_audit` is append-only, same bounded-in-memory-mode
-- ring-buffer treatment as every other rare/admin-gated audit table in
-- this file.
-- ======================================================================
local XPTierRows = {} -- ordinal -> { xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge, updated_by, updated_at, created_at_unix }
local XPTIER_AUDIT_MEMORY_CAP = 200
local XPTierAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces
--- ApplyPersistedXPTierOverrides's own `SELECT ordinal, xp_threshold,
--- label, speed_multiplier, scent_range_multiplier,
--- medkit_cooldown_multiplier, badge FROM k9_xp_tiers` -- every rank ever
--- touched by a high-command edit.
--- @return table rows
function K9Store.XPTier_GetAllRows()
    if DatabaseEnabled('k9_xp_tiers') then
        local ok, rowsOrErr = pcall(MySQL.query.await,
            'SELECT ordinal, xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge FROM k9_xp_tiers', {})
        if not ok then
            print(('[John-K9] datastore: XPTier_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for ordinal, row in pairs(XPTierRows) do
        out[#out + 1] = {
            ordinal = ordinal, xp_threshold = row.xp_threshold, label = row.label,
            speed_multiplier = row.speed_multiplier, scent_range_multiplier = row.scent_range_multiplier,
            medkit_cooldown_multiplier = row.medkit_cooldown_multiplier, badge = row.badge,
        }
    end
    return out
end

--- Mirrors the SafeWrite contract. Replaces xpTiersUpsert's own
--- `INSERT INTO k9_xp_tiers (...) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON
--- DUPLICATE KEY UPDATE xp_threshold = VALUES(xp_threshold), label =
--- VALUES(label), speed_multiplier = VALUES(speed_multiplier),
--- scent_range_multiplier = VALUES(scent_range_multiplier),
--- medkit_cooldown_multiplier = VALUES(medkit_cooldown_multiplier), badge
--- = VALUES(badge), updated_by = VALUES(updated_by), updated_at =
--- CURRENT_TIMESTAMP`. `medkitCooldownMultiplier`/`badge` may legitimately
--- be `nil` (an unset optional field) -- passed straight through to
--- oxmysql as SQL NULL, the same nullable-middle-parameter shape this
--- file's own ShopLocation_Insert/ShopLocation_Update already rely on for
--- `model`/`scenario`/`label`.
--- @return boolean ok
function K9Store.XPTier_Upsert(ordinal, xpThreshold, label, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier, badge, updatedBy)
    if DatabaseEnabled('k9_xp_tiers') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_xp_tiers (ordinal, xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge, updated_by) ' ..
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE xp_threshold = VALUES(xp_threshold), label = VALUES(label), ' ..
            'speed_multiplier = VALUES(speed_multiplier), scent_range_multiplier = VALUES(scent_range_multiplier), ' ..
            'medkit_cooldown_multiplier = VALUES(medkit_cooldown_multiplier), badge = VALUES(badge), ' ..
            'updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { ordinal, xpThreshold, label, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier, badge, updatedBy })
        if not ok then
            print(('[John-K9] datastore: XPTier_Upsert write failed for ordinal %s: %s'):format(tostring(ordinal), tostring(err)))
            return false
        end
        return true
    end
    local existing = XPTierRows[ordinal]
    XPTierRows[ordinal] = {
        xp_threshold = xpThreshold, label = label, speed_multiplier = speedMultiplier,
        scent_range_multiplier = scentRangeMultiplier, medkit_cooldown_multiplier = medkitCooldownMultiplier, badge = badge,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
        created_at_unix = existing and existing.created_at_unix or NowUnix(),
    }
    return true
end

--- Mirrors the SafeWrite contract. Replaces server/xptiers.lua's own
--- `INSERT INTO k9_xp_tier_audit (action, ordinal, detail, changed_by)
--- VALUES ('xp_tier_update', ?, ?, ?)` -- append-only, bounded in memory
--- mode like every other rare/admin-gated audit table in this file. The
--- `action` column always holds the literal `'xp_tier_update'` today (this
--- pass has no other action kind -- see server/xptiers.lua's own header,
--- "SCOPE DECISION": no create/delete/reorder surface exists) -- kept as a
--- real column rather than omitted, matching k9_certification_tier_audit/
--- k9_permission_key_audit's own shape, so a future action kind (should
--- one ever be added) needs no schema change, only a new literal value.
--- @return boolean ok
function K9Store.XPTierAudit_Append(ordinal, detail, changedBy)
    if DatabaseEnabled('k9_xp_tier_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_xp_tier_audit (action, ordinal, detail, changed_by) VALUES (?, ?, ?, ?)',
            { 'xp_tier_update', ordinal, detail, changedBy })
        if not ok then
            print(('[John-K9] datastore: XPTierAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    XPTierAuditRows[#XPTierAuditRows + 1] = { action = 'xp_tier_update', ordinal = ordinal, detail = detail, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #XPTierAuditRows > XPTIER_AUDIT_MEMORY_CAP do
        table.remove(XPTierAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- (k9_runtime_override_audit section, near the top of this file) for the
--- full contract this mirrors exactly.
--- @param limit any
--- @return table rows -- { { action, ordinal, detail, changed_by, changed_at }, ... }, most recent first
function K9Store.XPTierAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_xp_tier_audit') then
        local sql = ('SELECT action, ordinal, detail, changed_by, changed_at FROM k9_xp_tier_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: XPTierAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #XPTierAuditRows, 1, -1 do
        local row = XPTierAuditRows[i]
        out[#out + 1] = { action = row.action, ordinal = row.ordinal, detail = row.detail, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_individual_overrides / k9_individual_override_audit
--
-- Mirrored from server/k9profiles.lua (the owner-directed "god over that
-- tablet, full customization over everything related to that K9" pass --
-- the per-INDIVIDUAL-K9 override half; k9_xp_tiers immediately above
-- already covers the per-RANK half). Same "SafeQuery/SafeWrite bespoke
-- contract, never throws" discipline as every other K9Store accessor in
-- this file, and the same current-state-table + append-only-audit-table
-- shape as k9_certification_tiers/k9_permission_keys above -- WITH a
-- `deleted` tombstone column (unlike k9_xp_tiers, which has none -- see
-- that section's own header for why a rank can only ever be re-valued,
-- never removed): an individual override is a real, operator-initiated
-- "reset this K9 back to normal" action, distinct from "edit one field",
-- so it needs a real tombstone the same way k9_certification_tiers/
-- k9_permission_keys do, even though (unlike a certification tier key)
-- nothing else in this schema references a citizenid's override row by
-- foreign key, so there is no HAZARD-2-shaped corruption risk a tombstone
-- is defending against here -- it exists purely for audit-trail
-- consistency with the rest of this schema.
--
-- k9_individual_overrides is a current-state table (one row per citizenid
-- that has EVER had an override written for it, a real PRIMARY KEY per
-- migration 0016's own header, no generated-key uniqueness engine needed)
-- -- its memory mirror is a plain keyed map, same shape as TierRows/
-- PermKeyRows above. k9_individual_override_audit is append-only, same
-- bounded-in-memory-mode ring-buffer treatment as every other rare/
-- admin-gated audit table in this file -- this surface is high-command-
-- gated, not ordinary gameplay volume, per migration 0016's own header.
--
-- NAMING (bug caught in QA before this ever shipped, recorded here so it is
-- never repeated): `K9Store.Override_*` / `OverrideRows` /
-- `OverrideAuditRows` / `OVERRIDE_AUDIT_MEMORY_CAP` ALREADY NAME the
-- pre-existing `k9_runtime_feature_overrides` subsystem above (see
-- `K9Store.Override_Upsert(overrideKey, kind, value, updatedBy)` a few
-- hundred lines up, consumed by server/runtimecontrol.lua's
-- runtimeSetFeature/runtimeSetTunable). A first draft of this section
-- reused that exact name -- Lua silently lets a later top-level
-- `function K9Store.Override_Upsert(...)` OVERWRITE the earlier one in the
-- same shared table, and a later `local OverrideRows = {}` shadows (never
-- errors on) the earlier `local` of the same name -- so every existing
-- runtime-feature-override write would have silently landed on THIS
-- section's own 5-argument signature instead, writing garbage into the
-- wrong columns while still returning `true` and reporting success. Caught
-- before merge; every symbol in THIS section is therefore prefixed
-- `IndividualOverride*`/`INDIVIDUAL_OVERRIDE*`, never bare `Override*`,
-- specifically so it can never collide with that earlier, unrelated
-- subsystem again. See tests/datastore_spec.lua's own "NAME COLLISION
-- REGRESSION" section for the automated test this incident produced.
-- ======================================================================
local IndividualOverrideRows = {} -- citizenid -> { speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, note, deleted, updated_by, updated_at, created_at_unix }
local INDIVIDUAL_OVERRIDE_AUDIT_MEMORY_CAP = 200
local IndividualOverrideAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces server/k9profiles.lua's own
--- boot-time cache warm `SELECT citizenid, speed_multiplier,
--- scent_range_multiplier, medkit_cooldown_multiplier, note, deleted FROM
--- k9_individual_overrides` -- every citizenid EVER touched by a
--- high-command edit, including tombstoned ones (the `deleted` column is
--- what server/k9profiles.lua's own cache-build filters on, not this
--- accessor).
--- @return table rows
function K9Store.IndividualOverride_GetAllRows()
    if DatabaseEnabled('k9_individual_overrides') then
        local ok, rowsOrErr = pcall(MySQL.query.await,
            'SELECT citizenid, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, sprint_decay_per_tick, note, deleted FROM k9_individual_overrides', {})
        if not ok then
            print(('[John-K9] datastore: IndividualOverride_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for citizenid, row in pairs(IndividualOverrideRows) do
        out[#out + 1] = {
            citizenid = citizenid, speed_multiplier = row.speed_multiplier,
            scent_range_multiplier = row.scent_range_multiplier,
            medkit_cooldown_multiplier = row.medkit_cooldown_multiplier,
            sprint_decay_per_tick = row.sprint_decay_per_tick,
            note = row.note, deleted = row.deleted,
        }
    end
    return out
end

--- Mirrors the SafeWrite contract. Replaces k9ProfileUpsert's own
--- `INSERT INTO k9_individual_overrides (citizenid, speed_multiplier,
--- scent_range_multiplier, medkit_cooldown_multiplier, note, deleted,
--- updated_by) VALUES (?, ?, ?, ?, ?, 0, ?) ON DUPLICATE KEY UPDATE
--- speed_multiplier = VALUES(speed_multiplier), scent_range_multiplier =
--- VALUES(scent_range_multiplier), medkit_cooldown_multiplier =
--- VALUES(medkit_cooldown_multiplier), note = VALUES(note), deleted = 0,
--- updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` --
--- always UN-tombstones the row (`deleted = 0`) and sets every field,
--- whether this is a brand-new citizenid, a restore, or a plain re-edit of
--- an already-live override. Every one of `speedMultiplier`/
--- `scentRangeMultiplier`/`medkitCooldownMultiplier`/`sprintDecayPerTick`/`note` may
--- legitimately be `nil` (an intentionally-unset, per-field-optional
--- override -- see migration 0016's own header) -- passed straight through
--- to oxmysql as SQL NULL, the same nullable-middle-parameter shape this
--- file's own XPTier_Upsert/ShopLocation_Insert already rely on.
--- @return boolean ok
function K9Store.IndividualOverride_Upsert(citizenid, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier, sprintDecayPerTick, note, updatedBy)
    if DatabaseEnabled('k9_individual_overrides') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_individual_overrides (citizenid, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, sprint_decay_per_tick, note, deleted, updated_by) ' ..
            'VALUES (?, ?, ?, ?, ?, ?, 0, ?) ON DUPLICATE KEY UPDATE speed_multiplier = VALUES(speed_multiplier), ' ..
            'scent_range_multiplier = VALUES(scent_range_multiplier), medkit_cooldown_multiplier = VALUES(medkit_cooldown_multiplier), ' ..
            'sprint_decay_per_tick = VALUES(sprint_decay_per_tick), ' ..
            'note = VALUES(note), deleted = 0, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { citizenid, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier, sprintDecayPerTick, note, updatedBy })
        if not ok then
            print(('[John-K9] datastore: IndividualOverride_Upsert write failed for %s: %s'):format(tostring(citizenid), tostring(err)))
            return false
        end
        return true
    end
    local existing = IndividualOverrideRows[citizenid]
    IndividualOverrideRows[citizenid] = {
        speed_multiplier = speedMultiplier, scent_range_multiplier = scentRangeMultiplier,
        medkit_cooldown_multiplier = medkitCooldownMultiplier,
        sprint_decay_per_tick = sprintDecayPerTick, note = note, deleted = 0,
        updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
        created_at_unix = existing and existing.created_at_unix or NowUnix(),
    }
    return true
end

--- Mirrors the SafeWrite contract. Replaces k9ProfileReset's own
--- `INSERT INTO k9_individual_overrides (citizenid, deleted, updated_by)
--- VALUES (?, 1, ?) ON DUPLICATE KEY UPDATE deleted = 1, updated_by =
--- VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` -- TOMBSTONES a row
--- (see migration 0016's own header), leaving an ALREADY-EXISTING row's
--- own field values untouched (matching K9Store.Tier_Tombstone's identical
--- "the real SQL's own ON DUPLICATE KEY UPDATE clause never mentions those
--- columns" reasoning) -- there is no reference-count hazard to check
--- first here (nothing else in this schema points at a citizenid's
--- override row), so unlike K9Store.Cert_CountByTier/DeleteTier's own
--- gate, this accessor is called unconditionally once authorization and
--- payload validation have already passed.
--- @return boolean ok
function K9Store.IndividualOverride_Tombstone(citizenid, updatedBy)
    if DatabaseEnabled('k9_individual_overrides') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_individual_overrides (citizenid, deleted, updated_by) VALUES (?, 1, ?) ' ..
            'ON DUPLICATE KEY UPDATE deleted = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { citizenid, updatedBy })
        if not ok then
            print(('[John-K9] datastore: IndividualOverride_Tombstone write failed for %s: %s'):format(tostring(citizenid), tostring(err)))
            return false
        end
        return true
    end
    local existing = IndividualOverrideRows[citizenid]
    if existing then
        existing.deleted, existing.updated_by, existing.updated_at = 1, updatedBy, FormatDateTime(NowUnix())
    else
        IndividualOverrideRows[citizenid] = {
            speed_multiplier = nil, scent_range_multiplier = nil, medkit_cooldown_multiplier = nil, note = nil,
            deleted = 1, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()), created_at_unix = NowUnix(),
        }
    end
    return true
end

--- Mirrors the SafeWrite contract. Replaces server/k9profiles.lua's own
--- `INSERT INTO k9_individual_override_audit (action, citizenid, detail,
--- changed_by) VALUES (?, ?, ?, ?)` -- append-only, bounded in memory mode
--- like every other rare/admin-gated audit table in this file.
--- @return boolean ok
function K9Store.IndividualOverrideAudit_Append(action, citizenid, detail, changedBy)
    if DatabaseEnabled('k9_individual_override_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_individual_override_audit (action, citizenid, detail, changed_by) VALUES (?, ?, ?, ?)',
            { action, citizenid, detail, changedBy })
        if not ok then
            print(('[John-K9] datastore: IndividualOverrideAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    IndividualOverrideAuditRows[#IndividualOverrideAuditRows + 1] = { action = action, citizenid = citizenid, detail = detail, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #IndividualOverrideAuditRows > INDIVIDUAL_OVERRIDE_AUDIT_MEMORY_CAP do
        table.remove(IndividualOverrideAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- (k9_runtime_override_audit section, near the top of this file) for the
--- full contract this mirrors exactly.
--- @param limit any
--- @return table rows -- { { action, citizenid, detail, changed_by, changed_at }, ... }, most recent first
function K9Store.IndividualOverrideAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_individual_override_audit') then
        local sql = ('SELECT action, citizenid, detail, changed_by, changed_at FROM k9_individual_override_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: IndividualOverrideAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #IndividualOverrideAuditRows, 1, -1 do
        local row = IndividualOverrideAuditRows[i]
        out[#out + 1] = { action = row.action, citizenid = row.citizenid, detail = row.detail, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_equipment_shop_items / k9_equipment_shop_item_audit
--
-- Mirrored from server/equipmentshop.lua (owner-directed "give high
-- command real control over the equipment shop" pass -- the INVENTORY
-- half: which items are sold, at what price, in what order, and under
-- what purchase requirement, extending that file's own pre-existing
-- RUNTIME SHOP LOCATIONS work, migration 0011, to the shop's item
-- catalog). Same "SafeQuery/SafeWrite bespoke contract, never throws"
-- discipline as every other K9Store accessor in this file, and the exact
-- same shape as K9Store.Tier_*/TierAudit_Append immediately above (one
-- current-state table + one append-only audit table -- see migration
-- 0014's own header, "WHY NO SEPARATE CAPABILITIES-STYLE SIBLING TABLE",
-- for why this feature needs one fewer table than the tier catalog did).
--
-- k9_equipment_shop_items is a current-state table (one row per item_key
-- that has EVER been touched by a high-command edit, a real PRIMARY KEY
-- per migration 0014's own header) -- its memory mirror is a plain
-- keyed map, same shape as TierRows above. k9_equipment_shop_item_audit
-- is append-only, same bounded-in-memory-mode ring-buffer treatment as
-- every other rare/admin-gated audit table in this file (this surface is
-- high-command-gated, not ordinary gameplay volume, per migration 0014's
-- own header).
-- ======================================================================
local ShopItemRows = {} -- item_key -> { item_key, label, price, currency, sort_order, required_tier_key, required_specialization, deleted, updated_by, updated_at, created_at_unix }
local SHOP_ITEM_AUDIT_MEMORY_CAP = 200
local ShopItemAuditRows = {}

--- Mirrors the SafeQuery contract. Replaces
--- RefreshEquipmentShopItemCatalog's own `SELECT item_key, label, price,
--- currency, sort_order, required_tier_key, required_specialization,
--- deleted FROM k9_equipment_shop_items` -- every item row EVER touched
--- by a high-command edit, including tombstoned ones (the `deleted`
--- column is what RefreshEquipmentShopItemCatalog itself filters on, not
--- this accessor).
--- @return table rows
function K9Store.ShopItem_GetAllRows()
    if DatabaseEnabled('k9_equipment_shop_items') then
        local ok, rowsOrErr = pcall(MySQL.query.await,
            'SELECT item_key, label, price, currency, sort_order, required_tier_key, required_specialization, deleted FROM k9_equipment_shop_items', {})
        if not ok then
            print(('[John-K9] datastore: ShopItem_GetAllRows query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for itemKey, row in pairs(ShopItemRows) do
        out[#out + 1] = {
            item_key = itemKey, label = row.label, price = row.price, currency = row.currency,
            sort_order = row.sort_order, required_tier_key = row.required_tier_key,
            required_specialization = row.required_specialization, deleted = row.deleted,
        }
    end
    return out
end

--- Mirrors the SafeQuery contract. Replaces ShopItemsUpsert's own `SELECT
--- deleted FROM k9_equipment_shop_items WHERE item_key = ?` pre-write read
--- (used only to distinguish an 'item_create' from an 'item_restore' for
--- the audit trail -- see that callback's own comment).
--- @return table rows -- 0 or 1 rows, `{ { deleted = 0|1 } }` or `{}`
function K9Store.ShopItem_GetDeletedFlagByKey(itemKey)
    if DatabaseEnabled('k9_equipment_shop_items') then
        local ok, rowsOrErr = pcall(MySQL.query.await, 'SELECT deleted FROM k9_equipment_shop_items WHERE item_key = ?', { itemKey })
        if not ok then
            print(('[John-K9] datastore: ShopItem_GetDeletedFlagByKey query failed for %s: %s'):format(tostring(itemKey), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local row = ShopItemRows[itemKey]
    if not row then return {} end
    return { { deleted = row.deleted } }
end

--- Mirrors the SafeWrite contract. Full-replacement upsert -- always
--- un-tombstones the row (`deleted = 0`) and sets label/price/currency/
--- required_tier_key/required_specialization, whether this is a
--- brand-new key, a restore, or an edit of an already-live one. Does NOT
--- touch `sort_order` on an existing row -- mirrors
--- K9Store.Tier_Upsert/Tier_UpdateOrdinal's own split responsibility
--- exactly (Tier_Upsert sets ordinal only for a brand-new/restoring row;
--- an existing row's rank is changed ONLY by ShopItem_UpdateSortOrder
--- below, never by this function) -- see that pair's own doc comments for
--- the identical reasoning applied here.
--- @return boolean ok
function K9Store.ShopItem_Upsert(itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy)
    if DatabaseEnabled('k9_equipment_shop_items') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_equipment_shop_items (item_key, label, price, currency, sort_order, required_tier_key, required_specialization, deleted, updated_by) ' ..
            'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?) ' ..
            'ON DUPLICATE KEY UPDATE label = VALUES(label), price = VALUES(price), currency = VALUES(currency), ' ..
            'required_tier_key = VALUES(required_tier_key), required_specialization = VALUES(required_specialization), ' ..
            'deleted = 0, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy })
        if not ok then
            print(('[John-K9] datastore: ShopItem_Upsert write failed for %s: %s'):format(tostring(itemKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = ShopItemRows[itemKey]
    ShopItemRows[itemKey] = {
        item_key = itemKey, label = label, price = price, currency = currency,
        sort_order = existing and existing.sort_order or sortOrder,
        required_tier_key = requiredTierKey, required_specialization = requiredSpecialization,
        deleted = 0, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()),
        created_at_unix = existing and existing.created_at_unix or NowUnix(),
    }
    return true
end

--- Mirrors the SafeWrite contract. Replaces ShopItemsReorder's own per-key
--- `INSERT ... VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?) ON DUPLICATE KEY UPDATE
--- sort_order = VALUES(sort_order), deleted = 0, updated_by =
--- VALUES(updated_by), updated_at = CURRENT_TIMESTAMP` -- DELIBERATELY
--- DOES NOT TOUCH label/price/currency/required_tier_key/
--- required_specialization ON CONFLICT, matching K9Store.Tier_UpdateOrdinal's
--- own "never overwrite the other editable fields with a stale in-memory
--- snapshot on a reorder" reasoning EXACTLY (see that function's own doc
--- comment for the full race this closes) -- the non-sort_order arguments
--- here are used ONLY for the brand-new-row INSERT branch (a config-only
--- item that has never had a row in this table before a reorder touches
--- it for the first time).
--- @return boolean ok
function K9Store.ShopItem_UpdateSortOrder(itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy)
    if DatabaseEnabled('k9_equipment_shop_items') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_equipment_shop_items (item_key, label, price, currency, sort_order, required_tier_key, required_specialization, deleted, updated_by) ' ..
            'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?) ' ..
            'ON DUPLICATE KEY UPDATE sort_order = VALUES(sort_order), deleted = 0, updated_by = VALUES(updated_by), ' ..
            'updated_at = CURRENT_TIMESTAMP',
            { itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy })
        if not ok then
            print(('[John-K9] datastore: ShopItem_UpdateSortOrder write failed for %s: %s'):format(tostring(itemKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = ShopItemRows[itemKey]
    if existing then
        existing.sort_order, existing.deleted, existing.updated_by, existing.updated_at = sortOrder, 0, updatedBy, FormatDateTime(NowUnix())
    else
        ShopItemRows[itemKey] = {
            item_key = itemKey, label = label, price = price, currency = currency, sort_order = sortOrder,
            required_tier_key = requiredTierKey, required_specialization = requiredSpecialization,
            deleted = 0, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()), created_at_unix = NowUnix(),
        }
    end
    return true
end

--- Mirrors the SafeWrite contract. Replaces ShopItemsDelete's own `INSERT
--- ... VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?) ON DUPLICATE KEY UPDATE deleted
--- = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP`
--- -- TOMBSTONES a row, leaving an ALREADY-EXISTING row's other columns
--- untouched, exactly like K9Store.Tier_Tombstone above and for the
--- identical reason -- the non-deleted-flag arguments here are used ONLY
--- for the brand-new-row INSERT case (an item_key that has never had a
--- row in this table before, e.g. a legacy config-only item being
--- tombstoned for the very first time).
--- @return boolean ok
function K9Store.ShopItem_Tombstone(itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy)
    if DatabaseEnabled('k9_equipment_shop_items') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_equipment_shop_items (item_key, label, price, currency, sort_order, required_tier_key, required_specialization, deleted, updated_by) ' ..
            'VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?) ' ..
            'ON DUPLICATE KEY UPDATE deleted = 1, updated_by = VALUES(updated_by), updated_at = CURRENT_TIMESTAMP',
            { itemKey, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization, updatedBy })
        if not ok then
            print(('[John-K9] datastore: ShopItem_Tombstone write failed for %s: %s'):format(tostring(itemKey), tostring(err)))
            return false
        end
        return true
    end
    local existing = ShopItemRows[itemKey]
    if existing then
        existing.deleted, existing.updated_by, existing.updated_at = 1, updatedBy, FormatDateTime(NowUnix())
    else
        ShopItemRows[itemKey] = {
            item_key = itemKey, label = label, price = price, currency = currency, sort_order = sortOrder,
            required_tier_key = requiredTierKey, required_specialization = requiredSpecialization,
            deleted = 1, updated_by = updatedBy, updated_at = FormatDateTime(NowUnix()), created_at_unix = NowUnix(),
        }
    end
    return true
end

--- Mirrors the SafeWrite contract. Replaces WriteShopItemAudit's own
--- `INSERT INTO k9_equipment_shop_item_audit (action, item_key, detail,
--- changed_by) VALUES (?, ?, ?, ?)` -- append-only, bounded in memory mode
--- like every other rare/admin-gated audit table in this file.
--- @return boolean ok
function K9Store.ShopItemAudit_Append(action, itemKey, detail, changedBy)
    if DatabaseEnabled('k9_equipment_shop_item_audit') then
        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO k9_equipment_shop_item_audit (action, item_key, detail, changed_by) VALUES (?, ?, ?, ?)',
            { action, itemKey, detail, changedBy })
        if not ok then
            print(('[John-K9] datastore: ShopItemAudit_Append write failed: %s'):format(tostring(err)))
            return false
        end
        return true
    end
    ShopItemAuditRows[#ShopItemAuditRows + 1] = { action = action, item_key = itemKey, detail = detail, changed_by = changedBy, changed_at = FormatDateTime(NowUnix()) }
    while #ShopItemAuditRows > SHOP_ITEM_AUDIT_MEMORY_CAP do
        table.remove(ShopItemAuditRows, 1)
    end
    return true
end

--- GAP 2 CLOSURE -- see K9Store.OverrideAudit_GetRecent's own doc comment
--- (k9_runtime_override_audit section, near the top of this file) for the
--- full contract this mirrors exactly.
--- @param limit any
--- @return table rows -- { { action, item_key, detail, changed_by, changed_at }, ... }, most recent first
function K9Store.ShopItemAudit_GetRecent(limit)
    limit = SanitizeLimit(limit)
    if DatabaseEnabled('k9_equipment_shop_item_audit') then
        local sql = ('SELECT action, item_key, detail, changed_by, changed_at FROM k9_equipment_shop_item_audit ORDER BY id DESC LIMIT %d'):format(limit)
        local ok, rowsOrErr = pcall(MySQL.query.await, sql, {})
        if not ok then
            print(('[John-K9] datastore: ShopItemAudit_GetRecent query failed: %s'):format(tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for i = #ShopItemAuditRows, 1, -1 do
        local row = ShopItemAuditRows[i]
        out[#out + 1] = { action = row.action, item_key = row.item_key, detail = row.detail, changed_by = row.changed_by, changed_at = row.changed_at }
        if #out >= limit then break end
    end
    return out
end

-- ======================================================================
-- k9_personnel (migration 0020, docs/history/ROSTER_SPEC.md §3/§4) -- db-schema pass,
-- 2026-08-26.
--
-- Owner's own words for the request this answers: "make it in the tablet
-- where there is a roster where we can assign callsigns see list of hired
-- k9s and full menu to fire promote etc", "Also a separate roster for
-- handlers same thing". This section is the K9Store half of that answer
-- -- server/roster.lua (the owner file) never names this table or calls
-- MySQL.* itself, per this file's own header.
--
-- Modeled directly on the k9_certifications section above: append-mostly
-- audit rows (assigning INSERTs a new row, clearing UPDATEs the existing
-- active row to `active = 0`, never deletes), one active row per
-- (citizenid, job), a generated-column unique key backstopping that
-- invariant at the DB level (`Personnel_Insert` mirrors `Cert_Insert`'s
-- own ThrowDuplicateActiveRow contract exactly), and the identical
-- memory-mode mirror shape every other table in this file already uses.
--
-- SECOND invariant unique to this table (k9_certifications has no
-- equivalent): COMBINED-NAMESPACE callsign uniqueness, case-insensitive,
-- per department (docs/history/ROSTER_SPEC.md §4) -- a K9's callsign and a handler's
-- callsign in the SAME job share one namespace. `Personnel_SetCallsign`
-- below throws the identical `{ errno = 1062 }`-shaped duplicate error
-- (via `ThrowDuplicateCallsign`, a sibling of `ThrowDuplicateActiveRow`
-- above) when a collision is found, so a caller's existing
-- `IsDuplicateKeyError` check recognizes it without any change on its
-- part, exactly like every other duplicate-row condition in this file.
-- ======================================================================
local PersonnelRows = {}
local PersonnelNextId = 0

--- @param citizenid string
--- @param job string
--- @return table? row
local function PersonnelFindActiveRow(citizenid, job)
    for _, row in ipairs(PersonnelRows) do
        if row.active == 1 and row.citizenid == citizenid and row.job == job then
            return row
        end
    end
    return nil
end

--- Case-insensitive callsign lookup, scoped to one department, across
--- BOTH roles combined (docs/history/ROSTER_SPEC.md §4's "one namespace" decision) --
--- excludes `excludeCitizenid`'s own row so re-saving a citizenid's own
--- unchanged callsign is never reported as a collision against itself.
--- @param job string
--- @param callsignLower string -- already lower-cased by the caller
--- @param excludeCitizenid string
--- @return table? row -- the colliding row, or nil
local function PersonnelFindActiveByCallsignInJob(job, callsignLower, excludeCitizenid)
    for _, row in ipairs(PersonnelRows) do
        if row.active == 1 and row.job == job and row.citizenid ~= excludeCitizenid
            and type(row.callsign) == 'string' and row.callsign:lower() == callsignLower then
            return row
        end
    end
    return nil
end

--- Sibling of `ThrowDuplicateActiveRow` above, same shape, distinct
--- wording -- both are recognized identically by every existing
--- `IsDuplicateKeyError(err)` helper (`err.errno == 1062` first, before
--- ever inspecting a message string), so this needs zero changes to any
--- existing duplicate-detection logic at any call site. Kept as a
--- separate function (rather than reusing `ThrowDuplicateActiveRow`
--- directly) purely so the console text names the real condition
--- (a callsign collision, not a duplicate active row) for anyone reading
--- server logs.
--- @param context string -- for the console line only, never parsed by a caller
local function ThrowDuplicateCallsign(context)
    error({ errno = 1062, message = ('ER_DUP_ENTRY: duplicate active callsign for %s (john-k9 in-memory backend)'):format(context) }, 0)
end

--- Mirrors MySQL.single.await. The current roster assignment (if any) for
--- one (citizenid, job) pair -- nil means "Unassigned" (docs/history/ROSTER_SPEC.md
--- §3/§5), not an error.
--- @param citizenid string
--- @param job string
--- @return table? { id, role, callsign, granted_by, granted_at }
function K9Store.Personnel_GetActiveRow(citizenid, job)
    if DatabaseEnabled('k9_personnel') then
        return MySQL.single.await(
            'SELECT id, role, callsign, granted_by, granted_at FROM k9_personnel WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1',
            { citizenid, job })
    end
    local row = PersonnelFindActiveRow(citizenid, job)
    if not row then return nil end
    return { id = row.id, role = row.role, callsign = row.callsign, granted_by = row.granted_by, granted_at = row.granted_at }
end

--- Mirrors the SafeQuery contract this file's own Cert_GetActiveRosterByJobUnordered
--- uses -- every ACTIVE personnel row for ONE department, both roles
--- combined (server/roster.lua splits them by `role` itself, and also
--- uses this same read for the combined-namespace callsign-collision
--- check). Always a table, empty on failure, never throws.
--- @param job string
--- @return table rows -- { { citizenid, role, callsign, granted_by, granted_at }, ... }
function K9Store.Personnel_GetActiveRowsByJob(job)
    if DatabaseEnabled('k9_personnel') then
        local ok, rowsOrErr = pcall(MySQL.query.await,
            'SELECT citizenid, role, callsign, granted_by, granted_at FROM k9_personnel WHERE job = ? AND active = 1', { job })
        if not ok then
            print(('[John-K9] datastore: Personnel_GetActiveRowsByJob query failed for job=%s: %s'):format(tostring(job), tostring(rowsOrErr)))
            return {}
        end
        return rowsOrErr or {}
    end
    local out = {}
    for _, row in ipairs(PersonnelRows) do
        if row.job == job and row.active == 1 then
            out[#out + 1] = { citizenid = row.citizenid, role = row.role, callsign = row.callsign, granted_by = row.granted_by, granted_at = row.granted_at }
        end
    end
    return out
end

--- Mirrors MySQL.insert.await -- returns the new row's id, or THROWS (a
--- duplicate-active-row error in memory mode, a real thrown oxmysql error
--- in DB mode, both `{ errno = 1062 }`-shaped) exactly like
--- `Cert_Insert` above. Always starts with a NULL callsign (docs/history/ROSTER_SPEC.md
--- §4: a fresh assignment/re-hire never resurrects an old callsign).
--- @param citizenid string
--- @param job string
--- @param role string -- 'k9' | 'handler', validated by the caller (server/roster.lua)
--- @param grantedBy string
--- @return number id
function K9Store.Personnel_Insert(citizenid, job, role, grantedBy)
    if DatabaseEnabled('k9_personnel') then
        return MySQL.insert.await('INSERT INTO k9_personnel (citizenid, job, role, granted_by) VALUES (?, ?, ?, ?)', { citizenid, job, role, grantedBy })
    end
    if PersonnelFindActiveRow(citizenid, job) then ThrowDuplicateActiveRow('k9_personnel ' .. citizenid .. '::' .. job) end
    PersonnelNextId = PersonnelNextId + 1
    PersonnelRows[#PersonnelRows + 1] = {
        id = PersonnelNextId, citizenid = citizenid, job = job, role = role, callsign = nil,
        granted_by = grantedBy, granted_at = FormatDateTime(NowUnix()),
        cleared_by = nil, cleared_at = nil, active = 1,
    }
    return PersonnelNextId
end

--- Mirrors MySQL.update.await. Changes the active row's role AND clears
--- its callsign in the SAME statement (docs/history/ROSTER_SPEC.md §4/§6: a role
--- change is not a new hire cycle -- it stays the same history row -- but
--- a K9 callsign and a handler callsign mean different things, so the old
--- one is never silently relabelled as the new kind).
--- @return number affectedRows
function K9Store.Personnel_UpdateRole(citizenid, job, role)
    if DatabaseEnabled('k9_personnel') then
        return MySQL.update.await('UPDATE k9_personnel SET role = ?, callsign = NULL WHERE citizenid = ? AND job = ? AND active = 1', { role, citizenid, job })
    end
    local row = PersonnelFindActiveRow(citizenid, job)
    if not row then return 0 end
    row.role, row.callsign = role, nil
    return 1
end

--- Mirrors MySQL.update.await, but MAY ALSO THROW a duplicate-callsign
--- error (`{ errno = 1062 }`, via `ThrowDuplicateCallsign` above) if
--- `callsign` collides case-insensitively with another active row in the
--- same department -- the DB-mode branch relies on
--- `uq_one_active_callsign_per_job` for the identical real-server
--- behavior. Callers (server/roster.lua) are expected to pre-check for a
--- collision AND catch this throw, the same defense-in-depth pattern this
--- schema already uses for `k9_certifications`' own
--- `uq_one_active_cert_per_job`. `callsign = nil` clears it -- always
--- allowed, never a collision.
--- @param citizenid string
--- @param job string
--- @param callsign string? -- nil clears the callsign
--- @return number affectedRows
function K9Store.Personnel_SetCallsign(citizenid, job, callsign)
    if DatabaseEnabled('k9_personnel') then
        return MySQL.update.await('UPDATE k9_personnel SET callsign = ? WHERE citizenid = ? AND job = ? AND active = 1', { callsign, citizenid, job })
    end
    if type(callsign) == 'string' then
        local collision = PersonnelFindActiveByCallsignInJob(job, callsign:lower(), citizenid)
        if collision then ThrowDuplicateCallsign('k9_personnel ' .. job .. '::' .. callsign) end
    end
    local row = PersonnelFindActiveRow(citizenid, job)
    if not row then return 0 end
    row.callsign = callsign
    return 1
end

--- Mirrors MySQL.update.await. Best-effort personnel-row cleanup for a
--- Fire action (docs/history/ROSTER_SPEC.md §6/§7) -- called AFTER the certification
--- revoke it accompanies has already succeeded, never before (see
--- server/roster.lua's own `ClearPersonnelRowForCitizenJob` doc comment).
--- `clearedBy` may hold a non-citizenid 'system:...' sentinel, mirroring
--- `Cert_RevokeActive`'s own `revoked_by` precedent.
--- @return number affectedRows
function K9Store.Personnel_ClearActive(citizenid, job, clearedBy)
    if DatabaseEnabled('k9_personnel') then
        return MySQL.update.await(
            'UPDATE k9_personnel SET active = 0, cleared_by = ?, cleared_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1',
            { clearedBy, citizenid, job })
    end
    local row = PersonnelFindActiveRow(citizenid, job)
    if not row then return 0 end
    row.active, row.cleared_by, row.cleared_at = 0, clearedBy, FormatDateTime(NowUnix())
    return 1
end

-- ======================================================================
-- BOOT LINE -- one console line stating which backend is live, so an
-- operator (or QA) can confirm Config.Database.enabled took effect
-- without reading code.
-- ======================================================================
if DatabaseEnabled() then
    print('[John-K9] datastore: Config.Database.enabled -- persisting to MySQL/MariaDB. This is the recommended way to run this resource.')
else
    print('[John-K9] datastore: Config.Database.enabled = false -- running IN MEMORY ONLY. Every certification, XP total, partnership, permission grant, runtime override and tablet theme change will be forgotten on the next restart, and no audit trail is being written. See config.lua\'s Config.Database comment for the full, plain-language explanation.')
end

-- ======================================================================
-- SCHEMA COLLISION SAFETY NET (db-schema pass, 2026-08-26)
--
-- Owner's own words for the requirement this answers: "ensure everything
-- regarding the sql is fixed done and no issues, I want it foolproof --
-- whether I've got a full database, or the database has similar names or
-- same names before injection, without causing any issues."
--
-- THE DANGEROUS CASE THIS CATCHES: `sql/preflight_check.sql` CHECK 1
-- already warns an operator, BEFORE they install, if one of this
-- resource's table names is already taken by something that is NOT ours
-- (read that file's own header for the full "why this matters"
-- explanation -- not repeated here). That is the right place for a HUMAN
-- to catch this, but it only fires if the operator remembers to run it --
-- nothing forces that. If they skip straight to pasting install.sql,
-- `CREATE TABLE IF NOT EXISTS` silently does nothing for a colliding
-- name, and every `K9Store.*` query below this point that names that
-- table starts running against a foreign table it does not own --
-- writing whatever this resource writes into someone else's data, or
-- failing in confusing ways. This block is the SAME check, run
-- automatically, in Lua, once, at this resource's own boot -- a second
-- line of defense for the operator who never opens
-- sql/preflight_check.sql at all. It does not replace that file (it
-- checks fewer things -- no server-version check, no CREATE ROUTINE
-- check -- and it can only warn AFTER the resource has already started,
-- where the SQL file warns BEFORE anything is installed); it is the
-- safety net underneath it.
--
-- WHAT IT DOES ON A COLLISION: this resource has exactly ONE choke point
-- for every real SQL statement it ever runs -- every `MySQL.*.await` call
-- in this whole resource lives in THIS file (see this file's own header,
-- "THE ONLY PLACE IN THIS RESOURCE THAT MAY NAME A `k9_*` TABLE OR CALL
-- `MySQL.*` DIRECTLY"). That single choke point is what makes a real
-- fail-safe possible without touching any other file: on ANY collision,
-- `DatabaseEnabled()` above is forced to report `false` for the rest of
-- this process (via `SCHEMA_COLLISION_DETECTED`, declared next to that
-- function) -- the exact same, already-proven memory-only fallback
-- `Config.Database.enabled = false` already uses. Every certification/
-- XP/partnership/permission/runtime-override/tablet-theme/K9-appearance
-- check keeps working for the life of the process (see this file's own
-- header, "THE READING THAT MAKES THAT TRACTABLE") -- nothing crashes,
-- nothing is denied to a real player -- it just stops persisting, and
-- says exactly why, loudly, once, in the console, instead of quietly
-- writing into a table it does not own.
--
-- THE BOOT-ORDER RACE THIS USED TO HAVE, AND HOW IT IS CLOSED (interaction
-- review + fix, this pass -- WIDENED, later pass, to cover every file
-- listed in K9Store.WaitForSchemaCheckToSettle's own doc comment, not only
-- the original four this paragraph used to name -- see that doc comment
-- for the current, complete, authoritative list rather than a second copy
-- here): the paragraph above is true ONLY from the moment this probe's own
-- query returns -- and that query, like every real `MySQL.*.await` call,
-- YIELDS. Several other files each register their OWN `onResourceStart`
-- handler to populate their own boot-time cache from a `k9_*` table this
-- same EXPECTED_TABLE_COLUMNS list also checks. fxmanifest.lua loads this
-- file first, so this probe's handler registers first too -- but
-- registering first only guarantees running first up to its own first
-- yield; when it yields, FXServer's event dispatch moves straight on to
-- the NEXT already-registered handler rather than waiting for this one to
-- resume. Every one of those other files' own boot-time reads is a
-- NARROWER `SELECT` than the column list this probe checks (e.g.
-- `K9Store.PermKey_GetAllRows` selects 4 of the 7 columns
-- `k9_permission_keys` is checked against below) -- so for the length of
-- that one window, a foreign table this probe WOULD correctly reject as a
-- collision could still satisfy one of those narrower SELECTs and hand a
-- stranger's real rows into a catalog cache, exactly the outcome this
-- whole safety net exists to prevent, just through a side door instead of
-- the front one. THE FIX: `K9Store.WaitForSchemaCheckToSettle()` (declared
-- next to `SCHEMA_CHECK_SETTLED`, near the top of this file) gives every
-- one of those files' own onResourceStart handlers a shared,
-- resource-global "has this been decided yet" signal to wait on, with a
-- bounded timeout (`SCHEMA_CHECK_WAIT_TIMEOUT_MS`), BEFORE their own first
-- read -- see that function's own header for the full contract, including
-- what a caller must do on a timeout (treat it the same as
-- `Config.Database.enabled == false` for that one boot-time read, never
-- proceed on an unconfirmed answer). THE RESIDUAL WINDOW, DISCLOSED RATHER
-- THAN LEFT IMPLICIT: this closes the race for every boot-time read that
-- calls `WaitForSchemaCheckToSettle()` first -- it does nothing for a
-- `K9Store.*` call made OUTSIDE of a boot sequence (a live admin edit, a
-- runtime callback) that races the probe, but no such call exists in this
-- resource -- every other `K9Store.*` accessor is reached only through a
-- player-triggered command/callback, all of which fire long after resource
-- start settles. A future file that adds its OWN `onResourceStart` read of
-- a table in EXPECTED_TABLE_COLUMNS without calling
-- `WaitForSchemaCheckToSettle()` first would silently reopen this exact
-- window -- there is no automatic enforcement of that call today beyond
-- this comment and each call site's own.
--
-- THE TRADE-OFF, STATED PLAINLY: this is a WHOLE-RESOURCE fallback, not a
-- per-table one. If only ONE of this resource's tables collides, ALL of
-- them fall back to memory mode until the operator fixes the one real
-- problem and restarts -- not just the one table that collided. Gating
-- every individual K9Store.* function, table by table, would need its own
-- tracking per table and would be a much larger, riskier change for a
-- case that should be rare and is always operator-fixable in minutes
-- (rename or drop the one foreign table) -- coarse-but-safe was judged
-- better than fine-grained-but-fragile for a safety net whose only job is
-- "never write into a table we do not own."
--
-- WHAT THIS DOES NOT DO: it does not fix the collision, drop anything, or
-- rename anything -- it only detects, refuses to write, and reports. Per
-- this resource's own established convention for an operator-facing
-- refusal (see server/certtiers.lua's own console messages, e.g. its
-- `Config.CertificationTiers is missing, malformed, ...` line, for the
-- exact voice this matches): plain English, names the exact table, says
-- what to do next.
--
-- THE COLUMN LIST BELOW MUST STAY IN SYNC WITH
-- `sql/preflight_check.sql`'s CHECK 1 -- same hand-maintained-list
-- convention (and same reason) as `sql/rollback/uninstall_all.sql`'s own
-- "OWNED TABLE LIST" comment: a table this resource adds in a future
-- migration needs its identifying columns added HERE too, in the SAME
-- change, or this safety net silently does not know to check it. This is
-- deliberately a small, cheap, additive check (one query, run once, at
-- boot) -- it is not a replacement for actually running
-- sql/preflight_check.sql before an install, which remains the primary,
-- pre-write line of defense; this is the safety net for the operator who
-- skips that step.
--
-- WHY THIS IS SAFE TO SANDBOX-TEST AGAINST: the `AddEventHandler` call at
-- the bottom of this block is guarded by `type(AddEventHandler) ==
-- 'function'`, this resource's own established soft-dependency
-- convention (see fxmanifest.lua's own client_scripts comments for the
-- same pattern applied elsewhere) -- in `tests/datastore_spec.lua`'s
-- sandbox (a plain Lua environment with no FXServer natives unless a spec
-- explicitly stubs one), `AddEventHandler` is absent, so this whole block
-- registers nothing and VerifyTableShapesAgainstKnownSchema() is never
-- invoked -- zero risk to any existing spec that loads this file, exactly
-- like every other real-native call in this resource that is reached only
-- through a guarded, runtime-fired handler rather than at file-load time.
-- ======================================================================

local EXPECTED_TABLE_COLUMNS = {
    k9_certifications                  = { 'citizenid', 'job', 'granted_by', 'granted_at', 'revoked_by', 'revoked_at', 'active' },
    k9_search_log                      = { 'searcher_citizenid', 'searcher_job', 'target_type', 'target_plate', 'target_citizenid', 'result', 'total_weight', 'alert_tier', 'searched_at' },
    k9_partnerships                    = { 'k9_citizenid', 'handler_citizenid', 'established_by', 'established_at', 'ended_by', 'ended_at', 'active' },
    k9_partnership_pair_progress       = { 'k9_citizenid', 'handler_citizenid', 'highest_tenure_tier_granted' },
    k9_progression                     = { 'citizenid', 'xp', 'created_at', 'updated_at' },
    k9_permissions                     = { 'citizenid', 'permission', 'granted_by', 'granted_at', 'revoked_by', 'revoked_at', 'active' },
    k9_certification_specializations   = { 'citizenid', 'job', 'specialization', 'granted_by', 'granted_at', 'revoked_by', 'revoked_at', 'active' },
    k9_runtime_feature_overrides       = { 'override_key', 'kind', 'value', 'updated_by', 'updated_at' },
    k9_runtime_override_audit          = { 'override_key', 'kind', 'old_value', 'new_value', 'changed_by', 'changed_at' },
    k9_tablet_theme                    = { 'primary_color', 'accent_color', 'background_color', 'text_color', 'density', 'header_title', 'updated_by', 'updated_at' },
    k9_tablet_theme_audit              = { 'primary_color', 'accent_color', 'background_color', 'text_color', 'density', 'header_title', 'changed_by', 'changed_at' },
    k9_ped_assignments                 = { 'citizenid', 'model', 'original_model_hash', 'active', 'applied_by', 'applied_at', 'revoked_at' },
    k9_certification_tiers             = { 'tier_key', 'label', 'ordinal', 'deleted', 'created_at', 'updated_by', 'updated_at' },
    k9_certification_tier_capabilities = { 'tier_key', 'capability_key', 'granted_by', 'granted_at' },
    k9_certification_tier_audit        = { 'id', 'action', 'tier_key', 'detail', 'changed_by', 'changed_at' },
    k9_equipment_shop_locations        = { 'x', 'y', 'z', 'created_by' },
    k9_equipment_shop_locations_audit  = { 'location_id', 'action', 'changed_by', 'changed_at' },
    k9_xp_tiers                        = { 'ordinal', 'xp_threshold', 'label', 'speed_multiplier', 'scent_range_multiplier', 'updated_by', 'updated_at' },
    k9_xp_tier_audit                   = { 'id', 'action', 'ordinal', 'detail', 'changed_by', 'changed_at' },
    k9_individual_overrides            = { 'citizenid', 'speed_multiplier', 'scent_range_multiplier', 'medkit_cooldown_multiplier', 'note', 'deleted', 'updated_by' },
    k9_individual_override_audit       = { 'id', 'action', 'citizenid', 'detail', 'changed_by', 'changed_at' },
    k9_equipment_shop_items            = { 'item_key', 'price', 'sort_order', 'required_tier_key', 'required_specialization', 'deleted', 'updated_by' },
    k9_equipment_shop_item_audit       = { 'id', 'action', 'item_key', 'detail', 'changed_by', 'changed_at' },
    -- quality pass, 2026-08-26: this file's own PermKey_* functions above
    -- (K9Store.PermKey_GetAllRows / PermKey_GetDeletedFlagByKey /
    -- PermKey_Upsert / PermKey_Tombstone) have named `k9_permission_keys`
    -- and `k9_permission_key_audit` since migration 0013 landed, but these
    -- two table names were never actually added here -- meaning the schema
    -- collision safety net silently never checked either of them, the
    -- exact gap this section's own header warns is easy to introduce.
    -- Column list mirrors sql/preflight_check.sql's own CHECK 1 entries for
    -- these two tables exactly (both fixed in the same change) -- keep both
    -- in sync if either changes.
    k9_permission_keys                 = { 'permission_key', 'label', 'description', 'deleted', 'created_at', 'updated_by', 'updated_at' },
    k9_roles                           = { 'role_key', 'label', 'xp_required', 'unlocks', 'deleted', 'created_at', 'updated_by', 'updated_at' },
    k9_role_audit                      = { 'id', 'action', 'role_key', 'detail', 'changed_by', 'changed_at' },
    k9_permission_key_audit            = { 'id', 'action', 'permission_key', 'detail', 'changed_by', 'changed_at' },
    -- SCHEMA-SAFETY AUDIT FIX (db-schema pass, 2026-08-27): migration 0019
    -- (mana_policedogs feature-parity pass, the admin-pinned "this
    -- citizenid IS a dog" record behind /k9setdog and /k9removedog,
    -- server/dogcharacter.lua) created `k9_dog_characters` but this table
    -- name was NEVER added here, or to sql/install.sql, sql/preflight_check
    -- .sql, sql/migration_status.sql, sql/rollback/uninstall_all.sql or
    -- sql/rollback/backup_k9_tables.sh -- the exact same class of gap
    -- k9_permission_keys/k9_permission_key_audit had before being fixed
    -- (see the comment on those two rows above), except this one meant the
    -- ONE table in this whole schema that could actually collide with a
    -- foreign table silently and never be told so, since
    -- VerifyTableShapesAgainstKnownSchema below only ever protects a table
    -- named here. server/dogcharacter.lua's own accessors already call
    -- through `K9Store.IsDatabaseEnabled('k9_dog_characters')` (a
    -- deliberate, flagged exception to this file's own "only
    -- server/datastore.lua calls MySQL.*" rule -- see that file's own
    -- header), so adding this row needed no other code change there: a real
    -- name collision or a genuinely missing table now correctly falls back
    -- this ONE table to honest memory-only mode instead of issuing a real
    -- query against a table that either does not exist or is not ours.
    -- Column list mirrors sql/preflight_check.sql's own CHECK 1 entry for
    -- this table exactly -- keep both in sync if either changes.
    k9_dog_characters                  = { 'citizenid', 'model', 'active', 'set_by', 'set_at', 'unset_at' },
    -- docs/history/ROSTER_SPEC.md §3/§4 (migration 0020, db-schema pass, 2026-08-26).
    -- Column list mirrors sql/preflight_check.sql's own CHECK 1 entry for
    -- this table exactly -- keep both in sync if either changes.
    k9_personnel                       = { 'citizenid', 'job', 'role', 'callsign', 'granted_by', 'granted_at', 'cleared_by', 'cleared_at', 'active' },
    -- db-schema pass, 2026-08-27 (wellbeing persistence wiring): matches
    -- sql/migrations/0022_create_k9_wellbeing.sql's real CREATE TABLE
    -- exactly -- `citizenid`, `fatigue`, `mood`, `fear_stress`, `injury`,
    -- `hunger`, `thirst`, `updated_at`. Column list mirrors
    -- sql/preflight_check.sql's own CHECK 1 entry for this table exactly --
    -- keep both in sync if either changes. GETTING THIS WRONG DOES NOT
    -- WARN QUIETLY: a real column list that does not cover every name
    -- listed here forces VerifyTableShapesAgainstKnownSchema below to treat
    -- `k9_wellbeing` as a SCHEMA COLLISION, which refuses MySQL for the
    -- WHOLE RESOURCE this session, not just this one table -- see that
    -- function's own header and DatabaseEnabled's own "SCHEMA COLLISION
    -- SAFETY NET" comment above for why a single wrong entry here is a
    -- resource-wide fail-closed event, not a small one.
    k9_wellbeing                       = { 'citizenid', 'fatigue', 'updated_at' },
}

--- Short, operator-facing phrase for each table in EXPECTED_TABLE_COLUMNS
--- above -- used ONLY by the PART-INSTALLED branch below to name exactly
--- which FEATURES will not be remembered this session, rather than making
--- an operator cross-reference a bare table name against sql/install.sql
--- to work out what it backs. Hand-maintained, same convention (and same
--- reason) as EXPECTED_TABLE_COLUMNS itself -- a table added there without
--- a matching entry here still works (the fallback below tolerates a
--- missing description, see its own code), it just prints a less useful
--- message for that one table until this is filled in too.
local MISSING_TABLE_FEATURE_DESCRIPTIONS = {
    k9_certifications                  = 'certifications (who is certified, and at what tier)',
    k9_search_log                      = 'the search audit log',
    k9_partnerships                    = 'K9/handler partnerships',
    k9_partnership_pair_progress       = 'partnership tenure-bonus anti-farm history -- NOTE: while this table is missing, a pair that breaks up and reforms AFTER a restart can re-earn tenure-bonus XP milestones they already collected (see MISSING_TABLE_CASCADES\'s own doc comment for the full "why" and why this is disclosed here rather than fixed by a cascade)',
    k9_progression                     = 'XP and handler XP',
    k9_permissions                     = 'individual permission grants and feature blocks -- NOTE: while this table is missing, every per-person `block.<Name>` restriction is treated as ACTIVE FOR EVERYONE rather than silently lifted for whoever it targeted (see server/permissions.lua\'s own HasPermission doc comment "MEMORY-MODE BLOCK ASYMMETRY" for the full "why") -- positive grants and certifications are unaffected',
    k9_certification_specializations   = 'certification specializations',
    k9_runtime_feature_overrides       = 'live feature on/off overrides',
    k9_runtime_override_audit          = 'the feature-override audit log',
    k9_tablet_theme                    = "the tablet's saved theme",
    k9_tablet_theme_audit              = 'the tablet-theme audit log',
    k9_ped_assignments                 = 'K9 ped/model assignments',
    k9_certification_tiers             = 'the certification tier catalog',
    k9_certification_tier_capabilities = 'which capabilities each certification tier unlocks',
    k9_certification_tier_audit        = 'the certification-tier audit log',
    k9_equipment_shop_locations        = 'runtime K9 Supply shop locations',
    k9_equipment_shop_locations_audit  = 'the shop-location audit log',
    k9_xp_tiers                        = 'the XP tier/rank catalog',
    k9_xp_tier_audit                   = 'the XP-tier audit log',
    k9_individual_overrides            = 'per-officer speed/scent/cooldown overrides',
    k9_individual_override_audit       = 'the per-officer override audit log',
    k9_equipment_shop_items            = 'the K9 Supply shop item catalog',
    k9_equipment_shop_item_audit       = 'the shop-item audit log',
    k9_permission_keys                 = 'the permission-key catalog',
    k9_roles                           = 'the K9 role catalog (tablet edits to role names, XP requirements and unlocks are kept in memory for this session only while it is missing)',
    k9_permission_key_audit            = 'the permission-key audit log',
    k9_role_audit                      = 'the role edit history (kept in memory for this session only while it is missing)',
    k9_dog_characters                  = 'admin-pinned "this citizenid is permanently a dog" records (/k9setdog, /k9removedog -- mana_policedogs feature parity) -- NOTE: while this table is missing, every currently-pinned dog character falls back to memory only for the rest of this session (nobody\'s actual K9 role/certification is affected either way -- this table has never decided whether a citizenid may act as a K9, only whether their dog form is pinned in place; see server/dogcharacter.lua\'s own header)',
    k9_personnel                       = 'the K9/Handler roster assignments and callsigns -- NOTE: while this table is missing, every currently-assigned K9/handler falls back to the "Unassigned" bucket on the roster screens the moment this resource restarts (nobody\'s actual certification/permission/feature access is affected either way -- see docs/history/ROSTER_SPEC.md §8)',
    k9_wellbeing                       = 'K9 fatigue -- NOTE: while this table is missing, every online K9\'s fatigue resets to fully-rested on the next restart (nobody\'s actual certification/permission/feature access is affected either way -- see server/wellbeing.lua\'s own header "DATABASE PERSISTENCE")',
}

--- A table this resource treats as MISSING when the table it is listed
--- under here is missing, EVEN IF this table's own columns matched --
--- forced into TABLE_MISSING_THIS_SESSION alongside its owner rather than
--- left to fall back independently. This is the ONE exception to "each
--- table falls back on its own", and it exists for exactly one reason
--- today:
---
--- `k9_certifications` -> `k9_certification_specializations`: HasSpecialization
--- (server/certifications/) only ever consults a citizenid's
--- specializations AFTER first confirming their CURRENT certification
--- cache entry is active -- so if `k9_certifications` is missing (memory
--- mode, reset on every restart, nobody pre-certified) while
--- `k9_certification_specializations` is a real, intact table, a citizenid
--- who was properly certified-and-specialized before some past restart,
--- lost that (memory-mode) certification at restart, and is later
--- RE-certified fresh by a high-command officer for an unrelated reason
--- would silently regain their OLD specializations the instant
--- RefreshSpecializationCache re-reads the still-persisted row -- specializations
--- that officer never chose to grant and has no way to know exist. That is
--- specifically what config.lua's own invariant on this feature forbids: a
--- memory-mode fallback may only ever be easier to LOSE than a working
--- database, never easier to get BACK without a fresh, deliberate grant.
--- Forcing `k9_certification_specializations` to memory mode alongside its
--- owning table closes this -- both reset together, so a fresh
--- certification this session starts with zero specializations, exactly
--- like a fresh certification always has, regardless of what an untouched
--- real table remembers.
---
--- Every OTHER table pair in this schema was checked for the same shape of
--- coupling (an in-session USE-time check that trusts a persisted row from
--- a DIFFERENT table without re-validating the relationship live) and
--- found NOT to have it -- see this pass's own investigation notes,
--- summarized: catalog tables (k9_certification_tiers/
--- k9_certification_tier_capabilities, k9_xp_tiers, k9_permission_keys)
--- already fall back to config.lua's own defaults independently of this
--- mechanism (an established, pre-existing pattern -- see
--- K9Store.WaitForSchemaCheckToSettle's own callers), and every grant
--- table's own USE-time check (HasK9Access, HasPermission,
--- GetActivePartnerCitizenId) reads that SAME table's own current backend,
--- never a different one -- so a missing k9_progression or k9_partnerships
--- table produces ordinary, honest DATA LOSS ("a returning veteran looks
--- like a rookie for the session"), never an authorization state a working
--- database would not also produce.
---
--- CORRECTED, THIS PASS (coder-security -- the claim above used to also
--- name k9_permissions as "ordinary, honest data loss", which is true for
--- the four named capabilities and every `feature.<Name>` row it holds,
--- but WRONG for the `block.<Name>` rows that same table also holds.
--- HasPermission's own "reads that SAME table's own current backend, never
--- a different one" is exactly the problem for a NEGATIVE grant: a missing
--- k9_permissions table means a positive grant/certification READS as
--- absent -- ordinary data loss, fails safe -- but a `block.<Name>` row
--- ALSO reads as absent, and for a block, absent means UNBLOCKED --
--- handing back access a human admin specifically took away, exactly the
--- "authorization state a working database would not also produce" this
--- paragraph claims cannot happen. Grant tables and block tables are not
--- the same shape even when they share one physical table: a missing GRANT
--- fails toward less access, a missing BLOCK fails toward more, and only
--- the first of those is safe to let happen silently. See server/
--- permissions.lua's own HasPermission doc comment, "MEMORY-MODE BLOCK
--- ASYMMETRY", for the fix -- `block.<Name>` is reported ACTIVE for every
--- citizenid, unconditionally, for as long as k9_permissions itself is not
--- database-backed this session, rather than trust an absence this table
--- structurally cannot distinguish from "never blocked." Not fixed here,
--- in this file, because the fix is a HasPermission-level policy decision
--- (what an unverifiable answer should mean), not a K9Store-level data
--- question (what the memory-mode mirror currently holds) -- this file's
--- own job stops at "here is what is actually in the table right now,"
--- truthfully; server/permissions.lua is what decides an absent block
--- cannot be trusted).
---
--- `k9_partnership_pair_progress` was the other candidate raised during
--- this review (it exists specifically to survive a k9_partnerships row
--- being superseded on reform). UPDATE, corrected rather than left stale:
--- it is NOT dead weight -- server/partnership.lua's CaptureTenureSeedForPair
--- and respondPartnerUp's own establish critical section already call
--- PairProgress_UpsertHighestTenureTier/PairProgress_GetHighestTenureTier
--- directly (that file's own former in-memory-only PairTenureSeed table is
--- gone, replaced outright rather than kept as a cache in front of this
--- one -- see that file's own header for why). Checked here anyway, for
--- the SAME reason this comment already checks every other grant table's
--- USE-time path: this table's own two callers each read/write through
--- THIS table's own current backend (never a different one) -- BUT this is
--- NOT the same shape of "ordinary, honest data loss" the paragraph above
--- accepts for k9_progression/k9_partnerships/k9_permissions, and saying so
--- would understate it: this table's WHOLE JOB is anti-farm, and
--- server/tenure.lua's CheckTenureMilestonesForK9 pays out REAL, permanent
--- XP (AwardXP/AwardHandlerXP) the FIRST time a milestone tier is crossed.
--- If this table is missing (memory mode, resets on every restart) and a
--- pair breaks up and reforms AFTER a restart, the seed read at reform time
--- comes back empty, so the reformed partnership's own
--- `tenure_bonus_tier_granted` floor starts at 0 again -- letting
--- CheckTenureMilestonesForK9 pay out the SAME milestones' XP a SECOND
--- time. That genuinely is "easier to get than a working database allows,"
--- the exact thing config.lua's own invariant forbids -- restated here so
--- a future reader does not repeat the milder "just data loss" framing.
--- NOT fixed by a MISSING_TABLE_CASCADES entry, because there is no OTHER
--- table whose own memory-mode fallback would close this -- the exploit is
--- intrinsic to THIS table's own absence (forcing k9_partnerships to
--- memory mode too would not help; a pair can farm this within a single
--- continuous session regardless of k9_partnerships' backend, the ONLY
--- real precondition is a RESTART happening while k9_partnership_pair_progress
--- itself is the missing one). Disclosed instead, loudly and specifically,
--- via this table's own MISSING_TABLE_FEATURE_DESCRIPTIONS entry above --
--- an operator reading the per-table fallback message for this ONE table
--- sees the real consequence, not a softened one. Rare in practice (needs
--- BOTH this specific table missing AND a genuine mid-session resource
--- restart landing between one break and the next reform of the SAME
--- pair), operator-fixable in minutes (run the missing migration), and
--- consistent with this whole pass's own "proportionate, not maximal"
--- philosophy: shutting down partnerships/milestones entirely while only
--- this one audit-shaped table is missing would reintroduce the exact
--- disproportionate-blast-radius problem this pass exists to fix, to
--- prevent a narrow, disclosed, restart-gated edge case.
local MISSING_TABLE_CASCADES = {
    k9_certifications = { 'k9_certification_specializations' },
}

--- Runs the collision probe described above. READ-ONLY (a single
--- INFORMATION_SCHEMA.COLUMNS query -- never writes, never drops, never
--- alters anything), wrapped in its own pcall so a failure here (e.g. a
--- restricted database user without SELECT on INFORMATION_SCHEMA, per
--- sql/preflight_check.sql's own CHECK 4 disclosure for a different
--- privilege) can never itself break this resource's startup -- it just
--- means this particular safety net could not run, silently degrading to
--- "no collision found" rather than blocking boot. A health check that can
--- crash the thing it is checking is worse than no health check.
local function VerifyTableShapesAgainstKnownSchema()
    local tableNames = {}
    for tableName in pairs(EXPECTED_TABLE_COLUMNS) do
        tableNames[#tableNames + 1] = tableName
    end

    local placeholders = {}
    for i = 1, #tableNames do placeholders[i] = '?' end

    -- SECURITY/ROBUSTNESS FIX (coder-security pass): this USED TO be
    -- `pcall(MySQL.query.await, sql, tableNames)` -- but `pcall(f, ...)`
    -- evaluates `f` (here, the expression `MySQL.query.await`) as part of
    -- building pcall's OWN argument list, in the CALLING stack frame, before
    -- pcall itself ever runs. If `MySQL.query` is ever nil/missing (a
    -- malformed/partial oxmysql stub, a co-located resource shadowing the
    -- global with an incompatible shape, or simply this function running
    -- before oxmysql has finished initializing its own wrapper table), that
    -- indexing throws OUTSIDE the pcall's own protection -- silently
    -- defeating this function's own doc comment promise two paragraphs up
    -- ("wrapped in its own pcall so a failure here... can never itself break
    -- this resource's startup") and crashing the `onResourceStart` handler
    -- below instead. FIXED by moving the ENTIRE call, including the
    -- `MySQL.query.await` field lookup itself, inside the protected closure
    -- -- now every failure mode this function's own header already promises
    -- to degrade from (a restricted DB user, a missing/malformed MySQL
    -- global) is caught by the SAME pcall, not just the query's own
    -- execution.
    local ok, rows = pcall(function()
        return MySQL.query.await(
            ('SELECT TABLE_NAME AS tbl, COLUMN_NAME AS col FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (%s)'):format(table.concat(placeholders, ', ')),
            tableNames
        )
    end)
    if not ok or type(rows) ~= 'table' then
        print(('[John-K9] datastore: schema collision check could not run (%s) -- proceeding as if no collision was found. If you suspect a table-name conflict, run sql/preflight_check.sql by hand instead.'):format(tostring(rows)))
        return
    end

    local actualColumnsByTable = {}
    for _, row in ipairs(rows) do
        actualColumnsByTable[row.tbl] = actualColumnsByTable[row.tbl] or {}
        actualColumnsByTable[row.tbl][row.col] = true
    end

    -- MISSING-TABLE CHECK -- "the SQL was never imported", which is a
    -- COMPLETELY different situation from a name collision and needs a
    -- completely different message. A collision means someone else owns a
    -- table we wanted; a missing table means nobody does, because
    -- sql/install.sql has not been run (or was run and the table was later
    -- dropped -- taking the SQL back out is something an owner is entitled
    -- to do, see config.lua's Config.Database block).
    --
    -- PER-TABLE FALLBACK, NOT WHOLE-RESOURCE, FOR A MISSING TABLE (revised
    -- this pass -- REPLACES the original "half-installed is the worst of
    -- both worlds, so blank every table" reasoning that used to sit here;
    -- kept out of git history, not restated, since it is no longer this
    -- function's actual behavior). Challenged in a lifecycle QA pass on a
    -- real, disproportionate blast radius: an operator forgetting ONE new
    -- migration after an update -- a common, trivial, entirely recoverable
    -- mistake -- silently made every OTHER already-intact table invisible
    -- to every officer for the rest of the session, with no way to tell
    -- from the tablet alone which specific feature was actually affected.
    --
    -- Re-examined against this file's own concrete example ("certifications
    -- would save and XP would not, so a handler comes back certified but at
    -- rank one"): that is not actually an inconsistent state -- it is the
    -- SAME state every brand-new certification already starts in
    -- (zero XP, tier one), produced honestly by an intact k9_certifications
    -- table and a missing k9_progression table each independently telling
    -- the truth about what they do and do not remember. A returning
    -- veteran looking like a rookie for one session is a real, disclosed
    -- COST (see the per-table message below, which names it) -- it is not
    -- corruption, and it is not a reason to also blank the k9_certifications
    -- table, which has nothing wrong with it.
    --
    -- The one place a genuine cross-table inconsistency WAS found -- a
    -- missing k9_certifications alongside an intact
    -- k9_certification_specializations letting a later, unrelated
    -- re-certification silently hand back specializations nobody re-granted
    -- -- is handled explicitly, not by abandoning per-table fallback
    -- wholesale: see MISSING_TABLE_CASCADES above, consulted below, which
    -- forces that one dependent table to fall back alongside its owner.
    -- Every other table in this schema was checked for the same shape of
    -- coupling and found not to have it (see MISSING_TABLE_CASCADES's own
    -- doc comment for the full per-table accounting).
    --
    -- THE INVARIANT THIS MUST NEVER VIOLATE (config.lua's own, restated
    -- here because this is the mechanism that must keep proving it): a
    -- memory-only fallback may only ever be easier to LOSE than a working
    -- database gives, never easier to GET. Per-table fallback only ever
    -- REMOVES persistence from a table that already cannot persist today
    -- (it was already going to memory mode under the old whole-resource
    -- design too) -- it never grants a table LESS scrutiny than before, and
    -- the one identified coupling above is closed explicitly rather than
    -- left to chance.
    --
    -- Deliberately NOT a hard failure, same reasoning as always: refusing
    -- to start would take the whole resource down over something the owner
    -- can fix in a minute, and would punish exactly the person who is
    -- trying it for the first time. Loud once, in plain English, names
    -- exactly which FEATURES are affected (not just which tables), then
    -- runs.
    -- ORDERING FIX, this pass: `missing` and `collided` are now BOTH
    -- computed up front, independently of each other, from the SAME
    -- `actualColumnsByTable` -- and the collision check (below) is
    -- evaluated and acted on FIRST, before either missing-table branch
    -- gets a chance to `return`. This used to matter far less: under the
    -- old whole-resource design, whichever branch ran first set the exact
    -- same flag with the exact same effect, so a table that was BOTH
    -- missing (some OTHER table) and a genuine collision (a THIRD table)
    -- at once was already, silently, only ever reported as "missing" --
    -- the collision check below was structurally unreachable whenever
    -- `#missing > 0`, because the old missing-table branches `return`ed
    -- first. That silent gap is now a real, distinct behavioral risk under
    -- per-table fallback: a genuinely colliding table could keep receiving
    -- real writes for the rest of the session, undetected, for no reason
    -- other than a SEPARATE, unrelated table happening to be missing at
    -- the same time. Fixed by checking collision FIRST -- a collision
    -- always wins and forces the whole-resource fallback regardless of
    -- what else is missing (any missing tables found are still named in
    -- the same message, for a complete diagnostic picture, but do not
    -- change the outcome once a real collision exists).
    local collided = {}
    for tableName, expectedColumns in pairs(EXPECTED_TABLE_COLUMNS) do
        local actualColumns = actualColumnsByTable[tableName]
        if actualColumns then -- the table exists at all
            local matched = 0
            for _, column in ipairs(expectedColumns) do
                if actualColumns[column] then matched = matched + 1 end
            end
            if matched < #expectedColumns then
                collided[#collided + 1] = { name = tableName, matched = matched, expected = #expectedColumns }
            end
        end
    end

    local missing = {}
    local totalExpected = 0
    for tableName in pairs(EXPECTED_TABLE_COLUMNS) do
        totalExpected = totalExpected + 1
        if not actualColumnsByTable[tableName] then
            missing[#missing + 1] = tableName
        end
    end
    table.sort(missing) -- pairs() order is undefined; an operator reading this needs a stable, scannable list

    if #collided > 0 then
        SCHEMA_COLLISION_DETECTED = true
        print('[John-K9] datastore: !! SCHEMA COLLISION DETECTED -- refusing to use MySQL for the rest of this session.')
        for _, c in ipairs(collided) do
            print(('[John-K9] datastore: !!   `%s` already exists in this database, but only %d of its %d expected columns match. This is almost certainly a DIFFERENT resource\'s table that happens to share this name, not an older john-k9 install. john-k9 will NOT write to it.'):format(c.name, c.matched, c.expected))
        end
        if #missing > 0 then
            print(('[John-K9] datastore: !!   Separately, %d of this resource\'s %d tables do not exist in this database at all: %s -- irrelevant to the collision above (a missing table cannot collide), named here only so this one message is a complete diagnostic picture.'):format(#missing, totalExpected, table.concat(missing, ', ')))
        end
        print('[John-K9] datastore: !! Every john-k9 feature is now running IN MEMORY ONLY for this session (identical to Config.Database.enabled = false -- see that setting\'s own comment in config.lua) so nothing gets written into a table this resource does not own. Nothing is lost that was not already lost: none of the table(s) named above ever belonged to john-k9 in this database. TO FIX: rename or remove the conflicting table(s) named above (or ask whoever owns them to), then restart this resource. See sql/preflight_check.sql CHECK 1 for the full explanation and README.md for the plain-language install story.')
        return
    end

    if #missing == totalExpected then
        -- Every single expected table is absent -- sql/install.sql was
        -- never run at all, not merely a table or two behind. Nothing to
        -- gain from per-table granularity here (every table would fall
        -- back anyway), and the "SQL was never imported" story is a
        -- single, simple fact worth one whole-resource message rather than
        -- a 25-line wall of per-table cascade bookkeeping -- so this
        -- branch keeps using the whole-resource flag, same as a real
        -- collision. TABLE_MISSING_THIS_SESSION is populated too, purely
        -- for consistency (nothing currently reads it while
        -- SCHEMA_COLLISION_DETECTED is set, since that flag alone already
        -- makes DatabaseEnabled(anything) false).
        for _, tableName in ipairs(missing) do
            TABLE_MISSING_THIS_SESSION[tableName] = true
        end
        SCHEMA_COLLISION_DETECTED = true
        print('[John-K9] datastore: this resource\'s own tables were not found in this database -- it looks like the SQL was never imported.')
        print('[John-K9] datastore: Running IN MEMORY ONLY for this session. Every feature works right now, for everyone on the server -- certifications, XP, partnerships, permissions, the tablet, all of it. What is missing is memory across a restart: when this server next restarts, all of it resets and everyone starts over. The audit trail is not kept at all.')
        print('[John-K9] datastore: TO FIX: run sql/k9_setup.sh against the database this server uses -- it runs install.sql, then every file in sql/migrations/, in the right order, safely, whether this is a first install or an upgrade. If you are pasting SQL by hand instead (no shell/mysql CLI available), run sql/install.sql first, then every file under sql/migrations/ in numeric order (0001, 0002, 0003, ... through the highest number present) -- install.sql alone does NOT create every table this resource uses; skipping the migrations folder will trigger this same warning again on the next restart. Then restart this resource. If you MEANT to run without a database, set Config.Database.enabled = false in config.lua and this message stops. See sql/DATABASE_GUIDE.md for a step-by-step version of all of this.')
        return
    end

    if #missing > 0 then
        -- PART-INSTALLED: at least one real, matching table exists, so this
        -- is not "never imported" -- apply the coupling exceptions from
        -- MISSING_TABLE_CASCADES, then fall back ONLY the affected tables.
        -- Every table NOT named below keeps using the real database exactly
        -- as before -- this is the whole point of this pass's change.
        local affected = {} -- tableName -> true, includes cascaded tables, for TABLE_MISSING_THIS_SESSION + the message below
        local cascaded = {} -- tableName -> the owner that pulled it in, for the message below (only ones NOT already genuinely missing)
        for _, tableName in ipairs(missing) do
            affected[tableName] = true
        end
        for _, tableName in ipairs(missing) do
            local dependents = MISSING_TABLE_CASCADES[tableName]
            if dependents then
                for _, dependentTable in ipairs(dependents) do
                    if not affected[dependentTable] then
                        affected[dependentTable] = true
                        cascaded[dependentTable] = tableName
                    end
                end
            end
        end
        for tableName in pairs(affected) do
            TABLE_MISSING_THIS_SESSION[tableName] = true
        end

        local affectedSorted = {}
        for tableName in pairs(affected) do affectedSorted[#affectedSorted + 1] = tableName end
        table.sort(affectedSorted)

        print(('[John-K9] datastore: !! PART-INSTALLED DATABASE -- %d of this resource\'s %d tables do not exist in this database: %s'):format(#missing, totalExpected, table.concat(missing, ', ')))
        print('[John-K9] datastore: !! This usually means sql/install.sql was run at some point but a later migration in sql/migrations/ was not, or a table was dropped afterwards.')
        print('[John-K9] datastore: !! THE FOLLOWING FEATURES WILL NOT BE REMEMBERED PAST A RESTART THIS SESSION (everything else keeps saving to the database normally):')
        for _, tableName in ipairs(affectedSorted) do
            local description = MISSING_TABLE_FEATURE_DESCRIPTIONS[tableName] or tableName
            local owner = cascaded[tableName]
            if owner then
                print(('[John-K9] datastore: !!   - %s (`%s`) -- this table itself is fine, but it is running in memory too because `%s` (%s) is missing and this feature depends on it -- see MISSING_TABLE_CASCADES in server/datastore.lua for why.'):format(description, tableName, owner, MISSING_TABLE_FEATURE_DESCRIPTIONS[owner] or owner))
            else
                print(('[John-K9] datastore: !!   - %s (`%s`)'):format(description, tableName))
            end
        end
        print('[John-K9] datastore: !! TO FIX: run the migrations in sql/migrations/ in number order (or re-run sql/install.sql, which is safe to run again -- it creates only what is missing), then restart this resource. Every feature listed above will resume normal persistence the moment its table exists again -- nothing about the tables that were already fine needs any action.')
        return
    end

    -- Nothing missing, nothing collided -- a real, fully migrated install.
    -- Every table keeps using the database exactly as configured; nothing
    -- left to do here.
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('onResourceStart', function(resourceName)
        if type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() ~= resourceName then return end
        if DatabaseEnabled() then
            VerifyTableShapesAgainstKnownSchema()
        end
        -- SETTLEMENT, ALWAYS, REGARDLESS OF OUTCOME (db-schema pass,
        -- 2026-08-26 boot-order fix) -- see K9Store.WaitForSchemaCheckToSettle's
        -- own header for the race this closes. Reached whether
        -- DatabaseEnabled() was already false by config (the branch above
        -- never ran at all), a real collision was just found, the database
        -- is clean, or VerifyTableShapesAgainstKnownSchema()'s own internal
        -- pcall degraded a failed check to "no collision found" -- that
        -- function never throws past its own pcall, so this line always
        -- runs once this handler reaches it, and every OTHER file's own
        -- onResourceStart handler that is currently parked inside
        -- K9Store.WaitForSchemaCheckToSettle() wakes up on its very next
        -- poll with the correct, final answer.
        SCHEMA_CHECK_SETTLED = true
    end)
end
