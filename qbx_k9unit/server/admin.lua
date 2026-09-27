--[[
    qbx_k9unit/server/admin.lua

    In-game admin/audit surface over the tables this resource already
    writes but, until now, only ever exposed as a raw SQL query an admin ran
    by hand (README.md's own documented "admin listing" queries;
    DEVELOPER_REFERENCE.md Part B top-3 item 2 / §9 -- formerly COMPLEMENTARY_FEATURES.md,
    merged 2026-08-25): `k9_certifications`
    (server/certifications/), `k9_partnerships` (server/partnership.lua),
    `k9_search_log` (server/search.lua), `k9_progression`
    (server/progression.lua). THIS FILE COMPUTES NOTHING NEW — it is a
    read-only, server-authoritative wrapper over query shapes sql/install.sql
    already documents and already indexes for. It never INSERTs/UPDATEs/
    DELETEs anything.

    COVERAGE RE-CHECK (this pass): three things landed under this file
    since its own last review — K9Inventory.allowedItems enforcement
    (server/inventory.lua), new wellbeing state (server/wellbeing.lua), and
    six outbound `qbx_k9unit:events:*` dispatch events — plus
    `k9_partnerships` grew the `tenure_bonus_tier_granted` column
    (server/tenure.lua). Checked each against this file's own "read-only
    wrapper over a real table" scope:
      - `k9_progression` (server/progression.lua's XP/tier persistence) was
        a genuine, undocumented GAP: a real table this resource has
        written to since Phase 4, with no query surface here at all — the
        same class of gap this file's own brief warns is "worse than one
        that admits its scope." CLOSED this pass: `/k9audit xp` below.
      - `tenure_bonus_tier_granted` needs no new command: it is a column on
        `k9_partnerships`, already fully returned by `/k9audit partner`
        (QueryPartnershipHistory selects every column via its own `columns`
        local, which already includes it) — an admin auditing a
        partnership's history sees its current tenure-tier progress for
        free, no code change required.
      - The six `qbx_k9unit:events:*` events are fire-and-forget
        `TriggerEvent` dispatches, not a persisted store — there is no
        table row to query that isn't already one of `k9_certifications`
        (certificationGranted/Revoked), `k9_partnerships`
        (partnershipEstablished/Ended), `k9_search_log`
        (searchCompleted), or, as of this pass, `k9_progression`
        (xpTierReached). Nothing further to add here; the underlying data
        each event reports on is fully covered once `/k9audit xp` lands.
      - K9Inventory.allowedItems enforcement (server/inventory.lua) rejects
        a mutation against ox_inventory's own stash contents — it writes
        no row to any `k9_*` table this file (or this resource) owns.
        ox_inventory's own stash/logging is that system's audit surface,
        not this resource's; out of this file's scope by the same
        "wraps this resource's own tables only" boundary that already
        excludes qbx_core/ox_inventory's own schemas entirely. Documented
        here, not silently skipped.
      - Wellbeing (server/wellbeing.lua) state is in-memory only (that
        file's own header — no `k9_wellbeing`/similar table exists in
        sql/install.sql) — there is no durable row for a read-only audit
        surface to wrap. Nothing to add unless/until that state is ever
        persisted.

    COVERAGE RE-CHECK (this pass, take 2): a schema review flagged
    `idx_job_active` (`job`, `active`) on `k9_certifications` — sql/
    install.sql's own comment on that index names the exact query it
    exists to serve, "list all certified handlers in department X" — as
    specified and indexed for but never queried by any code in this
    resource. Confirmed independently before building on that premise: a
    repo-wide search for `WHERE job` / `idx_job_active` found the CREATE
    TABLE's own KEY declaration and doc comment, and nothing else — every
    query this file already had (QueryCertificationHistory) filters on
    `citizenid`, using `idx_citizen_job_active` as a prefix scan, never
    `idx_job_active`. The index has been paying its write-amplification
    cost on every INSERT/UPDATE to `k9_certifications` since it was added,
    for a read path nothing exercised. CLOSED this pass: `/k9audit dept`
    below, whose query is sql/install.sql's own documented `idx_job_active`
    shape verbatim (`SELECT citizenid, granted_by, granted_at FROM
    k9_certifications WHERE job = ? AND active = 1`), plus the same
    ORDER BY/LIMIT discipline every other query in this file already
    follows.

    ======================================================================
    ACCESS MODEL — REVISED (project-owner-directed design change, this
    pass): this surface was originally the first ACE-gated action in this
    resource (DEVELOPER_REFERENCE.md Part B §9's own "precedent-setting choice,
    not a blocker" flag), on the reasoning that "can this connected
    principal read the search/cert/partnership audit trail" is
    SERVER-OPERATOR tooling, unrelated to department membership or K9
    certification. That reasoning was sound for what it covered, but the
    project owner's own correction is sound too: ACE is granted from the
    server console or a permissions file — a SERVER-ADMIN trust boundary —
    but this is a POLICE resource, and the people who should be trusted to
    review K9 certification/partnership/search history are SENIOR OFFICERS
    IN-GAME, not whoever happens to have console access. Every OTHER gated
    action in this resource (HasK9Access, IsEligibleCertifier,
    CheckPartnershipEligibility) already uses a job/grade threshold for
    exactly this kind of authority question; this file now does too.

    GATED ON POLICE JOB RANK, mirroring server/certifications/'s
    IsEligibleCertifier EXACTLY — read that function before touching
    IsAuthorizedAdmin below — including both of its hardening properties,
    carried over here from day one rather than waiting to rediscover them:
      - `job.isboss` ALWAYS qualifies, regardless of the configured numeric
        threshold. A department boss must be able to audit their own
        department at least as freely as they can already certify/revoke
        in it.
      - `job.grade.level` is explicitly type-checked (`type(...) ==
        'number'`) before ever reaching the `>=` comparison — never merely
        checked for truthiness/non-nil. A job object shaped differently
        than qbx_core's documented `{ name, level: number }` schema (a
        non-number `level`) must FAIL CLOSED (deny) here, never throw an
        uncaught "attempt to compare number with <type>" error on this
        authorization path — the exact class of bug coder-security already
        found and fixed twice in server/certifications/
        (IsEligibleCertifier's own certifierGrade comparison, and
        HasK9Access's autoAccessGrade branch).
    Threshold: `Config.Departments[job.name].auditGrade` — a NEW per-
    department field (config.lua's to add; not this file's). Deliberately
    a SEPARATE field from `certifierGrade`, not a reuse of it: auditing is
    a read-only oversight action over a genuinely privacy-sensitive dataset
    (who searched whom), and a server owner may reasonably want that bar
    set independently of who is trusted to grant/revoke certifications —
    e.g. restricting audit to command staff while certifierGrade stays at
    "K9 training sergeant," or the reverse. Both currently ship with the
    same default per department (see this file's own "CONFIG THIS FILE
    ASSUMES EXISTS" section below) purely so day-one behavior doesn't
    surprise an operator who hasn't reconsidered the split yet — nothing
    about the code ties the two together.

    NOT SCOPED TO THE CALLER'S OWN DEPARTMENT: passing IsAuthorizedAdmin at
    all (senior enough in ANY configured Config.Departments job) authorizes
    every command in this file, including `/k9audit dept` against a
    DIFFERENT department's roster than the caller's own. This mirrors an
    existing precedent already established in this resource —
    GrantCertification explicitly allows cross-department certification
    (§4.2 item 3: "this only requires the target be in *some* configured
    department, not the SAME one as the granter") — rather than inventing a
    new, narrower same-department-only rule found nowhere else in this
    codebase. Flagged for coder-security/project-owner to confirm or
    override if audit access should in fact be department-scoped.

    CONSOLE (source == 0) IS STILL NOT TRUSTED BY DEFAULT — opt-in via the
    SAME Config.AdminAudit.TrustConsole flag this file already had, kept
    UNCHANGED by this rewrite, and for a STRONGER reason than before: a
    job-rank check has NOTHING to compare for source == 0 at all (the
    console has no Player/PlayerData/job — Config.Departments[nil] is
    simply nil, not a crash, but it can never be a truthy match either).
    Without this explicit, separately-reasoned bypass, console access would
    not merely default off, it would be STRUCTURALLY IMPOSSIBLE under a
    job-rank gate — silently removing a documented operator capability as a
    side effect of swapping the authorization mechanism, not a decision
    anyone actually made. The original three-producer rationale for
    defaulting this OFF is UNCHANGED by this rewrite — see
    IsAuthorizedAdmin's own comment below for the full writeup, preserved
    verbatim from before this pass. A server owner who wants a genuine
    console operator to run these commands still sets TrustConsole = true
    and still accepts that all three producers (console, RCON, any
    co-located resource via ExecuteCommand) gain access, exactly as before.

    ACE IS NO LONGER USED BY THIS FILE AT ALL, as of this pass.
    `Config.AdminAudit.AcePermission` is now DEAD CONFIG — see this pass's
    hand-off note to the config owner: recommended for removal, not merely
    left unread by this file. `IsPlayerAceAllowed` itself remains a
    confirmed apiset:server native (`curl`-verified against
    ext/native-decls/IsPlayerAceAllowed.md this pass) and is still used
    elsewhere in this resource (server/combat.lua's FlagNonCompliance
    staff-notification path, and, until later the
    same day, server/bonetool.lua. NOTE: bonetool.lua has SINCE been
    converted off ACE too, so any claim here that it was "deliberately left
    ACE-gated" is stale. It now gates on `job.isboss` only -- a deliberately
    stricter principal than this file's `auditGrade`, because read-only audit
    access must not also confer a prop-spawning dev tool -- plus a replicated
    convar an operator must set on purpose. server/combat.lua's
    FlagNonCompliance staff-notification path is now the only live
    IsPlayerAceAllowed call site left in this resource) — nothing about this rewrite
    calls that native's own correctness into question, this file simply no
    longer has a reason to call it.
    ======================================================================

    SQL SAFETY — read before touching any query function below:
      - This file constructs 9 distinct hardcoded SQL string templates in
        total (COVERAGE RE-CHECK, this pass: was 8 —
        QueryCertificationHistory:1, QueryPartnershipHistory:2,
        QuerySearchLogBy{Officer,Plate,Person}/QuerySearchLogRecent:4,
        QueryProgressionSnapshot:1, QueryDepartmentRoster:1 (new,
        `/k9audit dept`) — verified by
        re-reading every `:format(`/literal-string call site below, not
        re-counted from memory). The security property that matters (every
        one of them is 100% hardcoded text, never built from a
        caller-controlled fragment) holds regardless of the exact count,
        but the count itself should be accurate.
      - Every WHERE-clause value (citizenid, plate) is bound via a `?`
        oxmysql placeholder — NEVER string-concatenated. No caller-supplied
        string ever reaches raw SQL text.
      - The one thing embedded via string.format rather than bound as a
        placeholder is each query's row LIMIT — and that value, by the time
        it reaches string.format, is a plain Lua integer already produced
        by ClampLimit below (clamped into [1, HARD_MAX_RESULTS]), never a
        value copied verbatim from a command's `args`. DISCLOSED REASONING:
        oxmysql's prepared-statement binding of a `LIMIT ?` placeholder
        specifically (as opposed to WHERE/VALUES placeholders, which is all
        every other query in this codebase ever binds — search.lua,
        certifications.lua, partnership.lua) could not be independently
        confirmed against a live oxmysql/mysql2 install in this sandbox,
        and no existing file in this resource establishes a precedent to
        confirm against either. Embedding an already-clamped-server-side
        integer is not a SQL-injection vector (there is no
        attacker-reachable string in that position — only a number this
        file's own clamping code produced) and sidesteps that unconfirmed
        compatibility question entirely.
      - `/k9audit search`'s `mode` argument is checked against a fixed
        whitelist table (VALID_SEARCH_LOG_MODES) and used ONLY to select
        which of four separately hardcoded query functions runs — never
        concatenated into a query, never used to select a column/table name
        dynamically.
      - Every query orders by a plain integer column (`id` — AUTO_INCREMENT,
        strictly increasing with insertion order) or by a column MySQL
        itself sorts server-side (`granted_at`/`searched_at`, via a
        hardcoded ORDER BY clause) — this file never parses or compares a
        DATETIME value in Lua. The one place two separately-fetched row
        sets must be merged (QueryPartnershipHistory below, one query per
        unique index) sorts by `id` for exactly this reason: whether
        oxmysql/mysql2 marshals a MySQL DATETIME into Lua as a plain string,
        a table, or something else was never independently confirmed in
        this sandbox, so comparing `id` (always a plain Lua number,
        unambiguous either way) avoids the question rather than assuming an
        answer.
      - Every result set is bounded. HARD_MAX_RESULTS below is enforced at
        resource start regardless of what Config.AdminAudit.MaxResults.* is
        configured to — an unbounded (or absurdly large) LIMIT against
        k9_search_log on a busy server is both a footgun and a DoS vector
        against this resource's own database, exactly the failure mode this
        task's brief names directly.

    ======================================================================
    COMMAND SURFACE (all five commands gated on
    Config.Features.AdminAuditCommands AT REGISTRATION TIME — if that flag
    is not `true`, none of these commands exist at all, not merely a
    runtime no-op; see the onResourceStart block at the bottom of this
    file):

    1. '/k9audit cert <citizenid>'
       Full certification grant/revoke history for one citizenid, across
       every department, most recently GRANTED first. Uses
       idx_citizen_job_active's leading `citizenid` column as a prefix scan
       — sql/install.sql's own comment on that index names this exact
       "full cert history for citizenid X across all jobs" query shape.

    2. '/k9audit partner <citizenid>'
       Full partnership history (active and historical) for one citizenid,
       in EITHER role. Two separate equality queries — one per unique index
       (idx_k9_citizenid_active / idx_handler_citizenid_active) — merged
       and re-sorted here rather than one OR'd query, so each half of the
       work hits its own purpose-built index instead of forcing an
       index-merge access plan on a single OR'd WHERE clause.

    3. '/k9audit search <mode> [value] [limit]'
       mode ∈ {'officer', 'plate', 'person', 'recent'} — STRICT WHITELIST,
       see VALID_SEARCH_LOG_MODES:
         officer <citizenid> [limit] — searches PERFORMED BY citizenid,
           most recent first (idx_searcher_searched_at — the exact query
           shape sql/install.sql's own comment on that index names).
         plate <plate> [limit]       — searches OF vehicle plate, most
           recent first (idx_target_plate_searched_at, same exact-shape
           reuse).
         person <citizenid> [limit]  — searches OF person citizenid, most
           recent first (idx_target_citizenid_searched_at, same exact-shape
           reuse).
         recent [limit]              — the N most recently logged searches
           of ANY kind, ordered by `id DESC` (NOT `searched_at`) with no
           WHERE clause at all — reading the last N rows off the end of
           InnoDB's own clustered primary-key index is cheap and needs no
           dedicated index of its own, honoring this task's explicit
           instruction to use the three existing purpose-built indexes
           rather than add a new one for a "recent window" query
           sql/install.sql's own header never anticipated.

    4. '/k9audit xp <citizenid>'
       Current persisted XP total for one citizenid, from `k9_progression`
       (server/progression.lua) — added this pass, see this file's own
       header "COVERAGE RE-CHECK" section for why. `citizenid` is that
       table's own PRIMARY KEY (sql/install.sql), so this is a single-row
       point lookup: no `[limit]` argument, no ORDER BY, and no
       Config.AdminAudit.MaxResults.* entry needed for it (there is never
       more than one row to bound). Deliberately reports the raw `xp`
       integer only, NOT a derived tier — this file's own "COMPUTES
       NOTHING NEW" rule (see this header's opening paragraph) means it
       does not re-implement server/progression.lua's `ResolveTier`
       threshold walk (a `local` function, not exposed as a
       resource-global) here as a second, driftable copy; an admin can
       compare the reported total against Config.XPTiers directly.

    5. '/k9audit dept <job> [limit]'
       Current ACTIVE certified-handler roster for one department (a
       Config.Departments key), most recently GRANTED first. Added this
       pass — see this file's header "COVERAGE RE-CHECK (this pass, take
       2)" section above for why. Uses `idx_job_active` — the exact query
       shape sql/install.sql's own comment on that index names ("list all
       certified handlers in department X").

       ARGUMENT SHAPE: a department name, validated against
       `Config.Departments` the same way server/certifications/'s
       `/k9decertifyoffline` validates its own `job` argument
       (`if not Config.Departments[job] then ... end`, that file's own
       `RevokeCertificationOffline`) — reusing an existing, already-vetted
       validation shape rather than inventing a new one for the same kind
       of argument. A department name that is not a configured
       `Config.Departments` key is rejected outright as `invalid_args`,
       the same posture `IsValidCitizenId`/`NormalizePlateArg` already
       take for this file's other string arguments — a typo'd/unconfigured
       job could never have a matching row, so failing fast beats a
       silent, confusing "no results found."

       ACTIVE-ONLY, NOT FULL HISTORY: this command reports only
       `active = 1` rows, never revoked ones. Three independent reasons,
       not just "the index says so": (1) `idx_job_active`'s own
       sql/install.sql doc comment names this exact query as "list all
       certified handlers in department X" — a present-tense ROSTER
       question, not a historical one; (2) `/k9audit cert` above already
       covers full grant/revoke history (including every department) for
       one citizenid — a second, department-scoped full-history view
       would duplicate that command's job rather than serve the roster
       use case this index exists for; (3) a revoked-history view keyed
       by department, unlike `/k9audit cert`'s per-citizenid view, would
       accumulate EVERY citizenid ever certified-then-revoked in that
       department with no natural per-target scope to bound it — the
       roster framing keeps this a small, bounded, genuinely useful
       result set instead.

       RESULT CAP: reuses `Config.AdminAudit.MaxResults.Certifications`
       (still clamped into `[1, HARD_MAX_RESULTS]` by ClampLimit either
       way) rather than a new dedicated config key — this queries the
       exact same `k9_certifications` table `/k9audit cert` already caps
       under that same key, and a roster is naturally smaller than a
       full per-citizenid history in the common case (one row per
       currently-certified handler, not one row per grant/revoke event
       ever recorded), so the existing per-table cap is the right unit,
       not a new one.

       DISPLAY BOUNDARY: reuses the exact same three columns
       `idx_job_active`'s own doc comment names — `citizenid, granted_by,
       granted_at` — nothing wider. Deliberately does NOT also return
       `revoked_by`/`revoked_at` (always NULL for an active-only row
       anyway) or any column `/k9audit cert` does not already expose for
       the very same table; this command widens WHO the query is scoped
       by (department instead of citizenid), never WHAT is disclosed.
    ======================================================================

    CALLBACK SURFACE (this pass) — every command above only ever formats
    its query results into a chat toast or a console print; there was, until
    now, no way for the tablet (or any other in-game consumer) to reach the
    RAW rows themselves. Five `lib.callback.register` endpoints now mirror
    the five commands one-to-one, each a thin wrapper around the EXACT SAME
    Query* function (therefore the exact same K9Store.* accessor) its
    command counterpart already calls, gated by the EXACT SAME
    IsAuthorizedAdmin(source) call, the EXACT SAME shared AuditCooldown
    budget, and the EXACT SAME ClampLimit bound — registered inside the same
    onResourceStart block, behind the same Config.Features.AdminAuditCommands
    gate, so a callback can never be reached more easily than the command it
    mirrors. See the full "CALLBACK SURFACE" comment block immediately above
    the five `lib.callback.register(...)` calls near the end of this file
    (inside onResourceStart, right after the five RegisterCommand blocks)
    for the complete argument/return-shape contract:
      qbx_k9unit:server:tabletAuditCert    (source, citizenid, limit)
      qbx_k9unit:server:tabletAuditPartner (source, citizenid, limit)
      qbx_k9unit:server:tabletAuditSearch  (source, mode, value, limit)
      qbx_k9unit:server:tabletAuditXp      (source, citizenid)
      qbx_k9unit:server:tabletAuditDept    (source, job, limit)
    Every one returns `{ ok = true, rows = <table>, label = <string>,
    cap = <number> }` on success — the four that take a `limit` argument
    (every one except tabletAuditXp, which takes none — see its own doc
    comment) also carry `limit = <number>` (the exact, already-clamped value
    this call actually used) and `truncated = <boolean>` (true only when the
    caller's own request exceeded `cap` and was cut down to it — this task's
    own "you asked for 500, here are the first 100" case) — or
    `{ ok = false, error = 'not_authorized'|'rate_limited'|'invalid_args', message = string? }`
    otherwise — never a formatted string, and NEVER `cap`/`limit`/`truncated`
    on a refusal: all three failure branches in every callback below return
    before HARD_MAX_RESULTS is ever attached to a response, so an
    unauthorized/rate-limited/malformed caller learns nothing new from this
    pass that IsAuthorizedAdmin didn't already refuse to tell them. `cap` is
    `HARD_MAX_RESULTS` below, verbatim — added THIS pass (closing the exact
    gap this task was opened to fix: html/tablet.js previously hardcoded its
    own guess of this same number) so a consumer is TOLD the real ceiling
    rather than duplicating it, mirroring runtimeSetTunable's own `min`/`max`
    echo (server/runtimecontrol.lua) exactly. See the full "CALLBACK
    SURFACE" comment block immediately above the five
    `lib.callback.register(...)` calls near the end of this file for the
    exact per-callback field list.

    CORRECTION (this pass): the sentence that used to close this section —
    "No NUI callback and no client/tablet.lua change are part of this pass"
    — was true when this section was first written and has been FALSE since
    a later pass built exactly that: client/tablet.lua's own tablet:audit*
    bridges (that file's own "K9 AUDIT TRAIL VIEWER" section) call all five
    of these callbacks directly, and html/tablet.js's Audit Trail tab is the
    real, live consumer this section originally only anticipated. Left here,
    corrected rather than deleted, per this project's own standing rule that
    a confidently-worded but stale comment costs the next reader real time.

    RATE LIMITING: one shared NewCooldown() instance (server/cooldowns.lua
    — per this task's explicit "use the shared constructors" convention)
    across all five commands, keyed by the CALLER's own source, mirroring
    server/certifications/'s CertifyActionCooldown shape (one cooldown
    covering several related actions, not one per command). This is a
    DB-load/spam guard, not an authorization boundary — nothing here
    mutates state or costs an ox_inventory round trip the way certify/
    search does, but k9_search_log grows without bound on a busy server and
    a scripted polling loop against it is real, avoidable DB load.

    AUDIT-OF-THE-AUDIT: every invocation of every command below — allowed,
    denied, rate-limited, or malformed — is logged to the server console
    via LogAuditInvocation. An audit surface over a genuine
    privacy-sensitive dataset (who searched whom, when) that nobody can
    itself audit is exactly the gap this task calls out by name. This is
    deliberately a `print()`, not a new DB table: a persisted "audit of
    audits" table would be a real schema change, and config.lua/
    fxmanifest.lua/sql/install.sql are explicitly out of this file's scope
    for this pass — flagged as a reasonable follow-up for db-schema/
    coder-architect to weigh in on, not silently skipped.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `NewCooldown`, resource-global from
      server/cooldowns.lua — must load after that file in fxmanifest.lua's
      server_scripts, same requirement every other consumer of it already
      states.
    - THIS FILE does NOT call HasK9Access / IsConfiguredK9Model /
      GetActivePartnerCitizenId / IsActivePartnerOf or any other
      resource-global from server/certifications/ or
      server/partnership.lua — deliberately: this surface's authorization
      is pure ACE, unrelated to K9 certification or department membership
      (see ACCESS MODEL above). No load-order dependency on either file.
    - THIS FILE exposes no resource-global functions of its own — nothing
      else in this resource needs to call into an admin/audit query.
    - THIS FILE performs SELECT-only queries against k9_certifications,
      k9_partnerships, k9_search_log, and k9_progression — read
      sql/install.sql's header comments on all four tables (index
      rationale, exact column shapes) before changing any query below.
    - THIS FILE calls `lib.callback.register` (ox_lib, CALLBACK SURFACE
      section above) — same soft dependency every other `lib.callback.
      register`/`locale()` call site in this resource already has on
      ox_lib being started first; no NEW load-order requirement this file
      did not already have via its own pre-existing `locale(...)` calls.
    ======================================================================

    CONFIG THIS FILE ASSUMES EXISTS — NOT owned by this file for this task
    (coder-backend does not own config.lua/fxmanifest.lua/.luacheckrc here;
    see this pass's hand-off note for the exact blocks needed). A missing
    Config.Features.AdminAuditCommands is treated as `false` (feature
    disabled, no crash) by the guard below — but if that flag IS `true`,
    Config.AdminAudit must exist with the exact shape asserted in the
    onResourceStart block below, or this resource will refuse to finish
    starting (fail loudly on a genuine misconfiguration, once the operator
    has actually opted in — never silently on an unrelated server that
    hasn't touched this feature at all):
      Config.Features.AdminAuditCommands  : boolean (new; default false)
      Config.AdminAudit.TrustConsole      : boolean (existing; default false — see ACCESS MODEL above for why this is unchanged, not removed, by the ACE->job-rank rewrite)
      Config.AdminAudit.CommandCooldownMs : number  (existing; shared per-source cooldown, ms)
      Config.AdminAudit.MaxResults.Certifications : integer, 1..100
      Config.AdminAudit.MaxResults.Partnerships   : integer, 1..100
      Config.AdminAudit.MaxResults.SearchLog      : integer, 1..100
      Config.Departments[job].auditGrade  : number (NEW this pass, per department —
                                            see ACCESS MODEL above; job.grade.level
                                            required to run any command in this file,
                                            job.isboss always qualifies too, same
                                            shape as Config.Departments[job].certifierGrade
                                            in server/certifications/). Recommended
                                            defaults matching this pass's report to the
                                            config owner: police=4, sheriff=3, bcso=3
                                            (identical to each department's own
                                            certifierGrade, day one — see rationale above).

      Config.AdminAudit.AcePermission is now DEAD CONFIG — no longer read by
      this file as of this pass (see ACCESS MODEL above). Recommended for
      removal from config.lua, not merely left in place unread.
]]

-- ADMIN CHAT COMMANDS ARE OFF BY DEFAULT (owner: "k9certify should only
-- be done through the tablet", and all other admin work with it). They are
-- only registered when Config.CommandTablet.adminChatCommands is true --
-- the tablet does every one of these. The handlers below are kept (and
-- tested) so an owner who wants console access can switch them back on.
local function RegisterAdminCommand(name, handler, restricted)
    if type(Config.CommandTablet) == 'table' and Config.CommandTablet.adminChatCommands == true then
        RegisterCommand(name, handler, restricted)
    end
end


-- Hard ceiling enforced regardless of what Config.AdminAudit.MaxResults.*
-- is configured to — same "config is a tunable, not a bypass" posture as
-- server/search.lua's own Config.SearchZones.alertBroadcastRadius <= 200.0
-- assert. An admin audit query is still a real query against a
-- potentially large, ever-growing table (k9_search_log) — an unbounded or
-- absurdly large LIMIT is both a footgun and a DoS vector against this
-- resource's own database, the exact failure mode this task's brief names
-- directly.
local HARD_MAX_RESULTS = 100

-- Floor enforced on Config.AdminAudit.CommandCooldownMs for the same
-- reason server/cooldowns.lua's own IsOnCooldown FAILS CLOSED on a
-- non-positive threshold (treats it as "on cooldown forever," never as "no
-- cooldown") — a misconfigured 0/negative value here would not open a gap,
-- it would silently brick this entire command surface for every caller
-- including legitimate admins. CLAMPED UP TO at resource start (see the
-- onResourceStart handler below) rather than asserted on — a bare assert
-- here used to abort THIS ENTIRE HANDLER the instant it fired, silently
-- skipping every command/callback registration still to come below it, for
-- one operator typo. Discovering a too-low value in the field is a far
-- smaller failure than that.
local MIN_COMMAND_COOLDOWN_MS = 250

-- Fallback used ONLY when Config.AdminAudit.CommandCooldownMs is missing or
-- not a number at all (NaN included) — matches config.lua's own shipped
-- default for this field. A value that IS a number but merely below
-- MIN_COMMAND_COOLDOWN_MS is clamped UP to the floor instead of replaced by
-- this fallback (the operator's intent to have SOME distinct cooldown is
-- preserved; only the unsafe part is corrected).
local DEFAULT_COMMAND_COOLDOWN_MS = 3000

-- How many formatted rows are batched into a single ox_lib toast — kept
-- small so one command's results don't render as one unreadable wall of
-- text, and so multiple short toasts don't spam the screen either.
local ROWS_PER_NOTIFY_CHUNK = 5

-- Fixed whitelist of valid `/k9audit search` modes — see this file's header
-- "SQL SAFETY" section for why this is a strict table lookup, never a
-- value that reaches SQL text directly.
local VALID_SEARCH_LOG_MODES = { officer = true, plate = true, person = true, recent = true }

-- DEVELOPER_REFERENCE.md item 1 convention (server/cooldowns.lua): shared
-- constructor, not a hand-rolled table. One instance covers all three
-- commands in this file, keyed by the CALLING admin's own source — see
-- this file's header "RATE LIMITING" section. No default threshold baked
-- in (mirrors server/search.lua's TargetSearchCooldown shape); the
-- threshold is supplied explicitly at every .Consume() call from
-- Config.AdminAudit.CommandCooldownMs.
local AuditCooldown = NewCooldown()
AuditCooldown.RegisterPlayerDropped()

--- Sends an ox_lib notification to a specific player, using this file's own
--- 'K9 Unit — Admin Audit' title. Deliberately kept as a thin LOCAL wrapper
--- (same name, shadowing the resource-global on purpose) rather than
--- flattened onto server/notify.lua's shared implementation directly at
--- every call site below — see that file's header "TWO CALL SITES
--- DELIBERATELY KEPT AS LOCAL WRAPPERS" section for the full reasoning
--- (this title is a deliberate, player-visible per-subsystem difference,
--- not an accident, and keeping it here in one place avoids duplicating the
--- title string at all 11 of this file's own call sites instead). The
--- explicit `_G.` prefix below is required, not decorative: a bare
--- `NotifyPlayer(...)` call inside this same-named local function's own
--- body would resolve to this local (already in scope inside its own body)
--- and recurse forever instead of reaching the shared global. NEVER called
--- with `target == 0` (server console) by any call site in this file —
--- console has no client to notify; see each command handler's own console
--- branch for how it surfaces results instead (a plain print()).
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    _G.NotifyPlayer(target, description, notifyType, 'K9 Unit — Admin Audit')
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- 4-step "first match wins" resolution, steps 2-4 (step 1 -- this
-- feature's own Config.Features.AdminAuditCommands flag -- is already
-- checked by this file's own COMMAND REGISTRATION gate further down, at
-- resource-start time, before any command handler IsAuthorizedAdmin below
-- guards can ever be registered at all). Mirrors
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId shape
-- exactly -- see that function's own doc comment for the full reasoning;
-- kept as this file's own tiny local copy rather than a shared export,
-- matching this resource's established "each file keeps its own tiny copy
-- of a genuinely small, self-contained check" convention
-- (server/permissions.lua's IsDuplicateKeyError doc comment names the same
-- precedent explicitly).
--
-- Called ONLY from inside IsAuthorizedAdmin below, and ONLY once every
-- OTHER (legacy auditGrade rank / job.isboss / high-command / k9.audit
-- capability-grant) qualification has ALREADY independently passed -- see
-- that function's own restructure below for exactly where. An explicit
-- per-person BLOCK or a missing per-person GRANT can therefore only ever
-- NARROW who this file's commands allow, never widen it: holding
-- 'feature.AdminAuditCommands' does not, by itself, ever authorize someone
-- who fails every other check IsAuthorizedAdmin already performs -- purely
-- additive in the opposite direction from every OTHER bypass in that
-- function (isboss/k9.audit-grant/high-command all WIDEN access; this
-- narrows it), exactly matching config.lua's own documented Config.FeatureControl
-- precedence ("global off... a block... can never switch on something...").
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsAdminFeaturePermittedForCitizenId(citizenid)
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.AdminAuditCommands') == true then
        return false -- step 2: an explicit block always wins, even over an otherwise-qualifying rank/high-command/capability-grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.AdminAuditCommands == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.AdminAuditCommands') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Server-authoritative authorization check for every command in this
--- file. See this file's header "ACCESS MODEL" section for the full
--- reasoning on both the ACE->job-rank rewrite and the console
--- (source == 0) carve-out.
---
--- PER-PERSON FEATURE CONTROL (this pass, coder-security -- see
--- IsAdminFeaturePermittedForCitizenId immediately above for the full
--- contract): every path below that used to `return true` directly now
--- routes through that check first, keyed to the caller's OWN
--- server-resolved citizenid -- never a client claim, never the console's
--- (source == 0 has no citizenid and is a distinct trust boundary --
--- Config.AdminAudit.TrustConsole -- untouched by this addition, see that
--- branch below). A block/missing-grant can therefore revoke a
--- specific officer's audit access WITHOUT touching their job grade, and
--- takes effect on their VERY NEXT command invocation (this function is
--- re-checked from scratch on every one of this file's five command
--- handlers, never cached) -- never gated behind a restart, matching this
--- resource's "gate at registration, not just inside the handler" rule
--- for the FEATURE flag itself while keeping the PER-PERSON layer fully
--- live.
---
--- JOB-RANK CHECK (this pass, project-owner-directed): mirrors
--- server/certifications/'s IsEligibleCertifier exactly — same
--- Config.Departments[job.name] membership requirement, same job.isboss
--- short-circuit, same explicit `type(job.grade.level) == 'number'` guard
--- before ever comparing it, applied against a NEW, separate threshold
--- (Config.Departments[job.name].auditGrade, not certifierGrade — see
--- header for why these are deliberately independent fields). FAILS CLOSED
--- on every path where a job cannot be fully resolved: no Player, no
--- PlayerData, no job, job.name not a configured department, no
--- dept.auditGrade (or a non-number one), no job.grade, or a non-number
--- job.grade.level all return false — none of them ever reach the `>=`
--- comparison, so none of them can throw. `job.isboss` is the only path
--- that returns true without inspecting job.grade at all, matching
--- IsEligibleCertifier's own documented behavior.
---
--- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
--- project-owner-directed this pass): a caller for whom IsHighCommand(source)
--- is true also qualifies, regardless of auditGrade — see that file's own
--- header for the full "run any command" contract. Guarded by a
--- `type(...) == 'function'` runtime existence check, so this function is
--- byte-identical in behavior to before if server/highcommand.lua is ever
--- removed or Config.Features.HighCommand is false.
--- @param source number
--- @return boolean
local function IsAuthorizedAdmin(source)
    -- SECURITY REVIEW OUTCOME (coder-security, prior pass, preserved verbatim
    -- -- the reasoning below is about `source == 0` itself and is unaffected
    -- by swapping the second branch from an ACE check to a job-rank check):
    -- this function previously did `if source == 0 then return true end`, on
    -- the reasoning that the server console already owns the process, the DB
    -- and the ACE system, so gating a read-only query behind ACE was not a
    -- real boundary. That reasoning is sound for the console -- and WRONG for
    -- FiveM, because `source == 0` has three distinct producers that this
    -- layer cannot tell apart:
    --   1. the real server console (the case the reasoning describes),
    --   2. an RCON client, authenticated only by `rcon_password` -- a
    --      network-facing credential, entirely separate from filesystem/DB/ACE
    --      control, so a leaked RCON password does NOT imply "already owns
    --      everything",
    --   3. ANY other resource on this server, via the `ExecuteCommand` native.
    --      These commands are registered with `restricted = false`, so nothing
    --      at the native layer stops a compromised, malicious or merely buggy
    --      co-located resource from running `k9audit search recent 100` and
    --      reading the entire privacy-sensitive audit trail with no ACE grant
    --      of its own.
    -- So the blanket bypass trusted a far broader and weaker set of actors than
    -- its justification described. It is opt-in and defaults off. THIS PASS
    -- ADDS A SECOND, INDEPENDENT REASON THIS BRANCH MUST STAY EXPLICIT: a
    -- job-rank check has no job object to consult for source == 0 at all, so
    -- without this early, separately-reasoned return, console access would be
    -- structurally impossible rather than a deliberate default -- see header
    -- ACCESS MODEL for the full writeup.
    if source == 0 then
        return Config.AdminAudit.TrustConsole == true
    end

    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- Resolved once, reused by every qualification path below AND by the
    -- PER-PERSON FEATURE CONTROL check each of them now routes through --
    -- same citizenid the pre-existing 'k9.audit' permission-grant bypass
    -- immediately below already reads from this exact field.
    local citizenid = Player.PlayerData.citizenid

    -- EXPLICIT PER-PERSON CAPABILITY BLOCK (security-audit pass, this pass
    -- -- see server/permissions.lua's own ADMIN_CAPABILITY_BLOCKABLE_KEYS
    -- doc comment for the full "why", and server/certifications/'s
    -- HasK9Access/IsEligibleCertifier for the identical addition applied
    -- there). Checked BEFORE job.isboss, deliberately -- this is the ONE
    -- bypass in this function 'block.k9.audit' must beat too, matching the
    -- owner's own "an explicit block beats everything, including High
    -- Command" model, mirrored here for the boss short-circuit exactly as
    -- IsEligibleCertifier now does for its own.
    --
    -- DISTINCT FROM, AND CHECKED SEPARATELY FROM, `block.AdminAuditCommands`
    -- below (IsAdminFeaturePermittedForCitizenId) -- the two answer
    -- different questions and are not a duplicate: this narrows whether
    -- `citizenid` holds the 'k9.audit' CAPABILITY at all (the same fact
    -- server/tablet.lua's own effectivePermissions listing and every other
    -- 'k9.audit' consumer cares about), while `block.AdminAuditCommands`
    -- narrows only whether THIS FILE's own five slash commands specifically
    -- remain usable for someone who separately still holds the capability.
    -- A citizenid can be blocked from one without the other, and both are
    -- meaningful independently -- exactly why this is a NEW, additive
    -- check rather than a replacement for the existing one.
    if type(HasPermission) == 'function' and HasPermission(citizenid, 'block.k9.audit') then
        return false
    end

    -- job.isboss always qualifies regardless of the configured numeric
    -- threshold -- same rule, same reasoning, as
    -- server/certifications/'s IsEligibleCertifier. PER-PERSON FEATURE
    -- CONTROL (this pass) is layered on AFTER this qualifies, never
    -- instead of it -- see IsAdminFeaturePermittedForCitizenId's own doc
    -- comment above for why a block/missing-grant can narrow even a boss's
    -- own audit access without touching their job rank.
    if job.isboss then return IsAdminFeaturePermittedForCitizenId(citizenid) end

    -- PERMISSION GRANT BYPASS (server/permissions.lua, Config.Features.PermissionGrants,
    -- resolution-order STEP 1) -- an active granted 'k9.audit' permission
    -- ALLOWS outright, checked before the high-command bypass and the
    -- auditGrade comparison below, matching config.lua's own documented
    -- "first match wins" order. Guarded by a `type(...) == 'function'`
    -- runtime existence check -- this function still works exactly as
    -- before if server/permissions.lua is ever removed or
    -- Config.Features.PermissionGrants is false. PER-PERSON FEATURE
    -- CONTROL (this pass) still applies on top of this bypass -- holding
    -- the 'k9.audit' CAPABILITY grant is a different fact from holding the
    -- 'feature.AdminAuditCommands' FEATURE grant Config.FeatureControl.RequireGrant
    -- asks for; a block on the latter still wins even for someone who
    -- holds the former.
    if type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.audit') then
        return IsAdminFeaturePermittedForCitizenId(citizenid)
    end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- project-owner-directed this pass) -- auditGrade is explicitly one of
    -- the gates a High Command officer must bypass (see that file's own
    -- header PART 1 for the full contract). Guarded by a
    -- `type(...) == 'function'` runtime existence check, this resource's
    -- established soft-dependency convention -- this function still works
    -- exactly as before if server/highcommand.lua is ever removed or
    -- Config.Features.HighCommand is false (IsHighCommand re-checks that
    -- flag itself and returns false). PER-PERSON FEATURE CONTROL (this
    -- pass) still applies on top of this bypass -- see
    -- server/tablet.lua's own disclosed "NO high-command bypass at step 3"
    -- reading of config.lua's Config.FeatureControl order, which this
    -- mirrors: high command triggering ITS OWN audit access is still
    -- subject to a block/RequireGrant the same as anyone else.
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return IsAdminFeaturePermittedForCitizenId(citizenid)
    end

    -- SAME hardening IsEligibleCertifier/HasK9Access already carry: an
    -- explicit type check on BOTH operands before the `>=` comparison, not a
    -- pcall. A pcall here would convert a real job-shape bug into exactly the
    -- silent "this rank can never audit anything" no-op this codebase's own
    -- prior security fixes exist to stop happening quietly. Non-number
    -- dept.auditGrade (unset/misconfigured department) or non-number
    -- job.grade.level (a job object shaped differently than qbx_core's
    -- documented `{ name, level: number }` schema) both FAIL CLOSED here --
    -- this function returns false, never throws, and never reaches the
    -- comparison with a bad operand on either side.
    local dept = Config.Departments[job.name]
    if type(dept.auditGrade) ~= 'number' then return false end

    if not (job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.auditGrade) then
        return false
    end

    -- PER-PERSON FEATURE CONTROL, final path (this pass) -- same check as
    -- every bypass above, applied to the ordinary rank-qualified case too.
    return IsAdminFeaturePermittedForCitizenId(citizenid)
end

--- Parses and clamps an optional caller-supplied result-count argument.
--- Never trusts the raw value directly into a query — always returns a
--- plain Lua integer already clamped into [1, hardMax]. `defaultValue` is
--- substituted when `rawArg` is absent/unparseable, but is then put through
--- the EXACT SAME floor+range-clamp pass as a parsed `rawArg` would be —
--- deliberately not returned raw. The onResourceStart config-shape assert
--- below now also rejects a non-integer/out-of-range
--- `Config.AdminAudit.MaxResults.*` at startup (belt-and-suspenders), but
--- this function does not rely on that assert alone: floor+clamp always
--- runs here too, so `defaultValue` can never reach `string.format('...
--- LIMIT %d', limit)` un-floored regardless of how it got here. Lua's `%d`
--- format specifier raises an UNCAUGHT error on a float with a fractional
--- part -- that `%d` embed now happens inside server/datastore.lua's own
--- K9Store.* functions (this file no longer builds its own SQL text at
--- all), OUTSIDE of and before that layer's own fail-closed pcall wrap,
--- which would otherwise turn a config-shape gap into a runtime crash on
--- the very first invocation of any of these three commands. See this file's
--- header "SQL SAFETY" section for why the RETURNED integer (never
--- `rawArg` itself, and now never a raw `defaultValue` either) is the only
--- thing that ever reaches a query string.
---
--- NaN HARDENING (this pass, added for the CALLBACK SURFACE below): every
--- pre-existing caller of this function is a RegisterCommand handler, whose
--- `rawArg` is always either nil or a plain string straight from chat
--- input -- `tonumber('nan')` is nil on this codebase's own Lua 5.4 build
--- (see tests/admin_spec.lua's own locked-in regression case for that
--- exact fact), so a real NaN value could never previously reach `parsed`
--- at all. The CALLBACK SURFACE below accepts `limit` as a plain Lua
--- number straight off the wire (a `lib.callback` argument, never a
--- string), and `tonumber(x)` on an ALREADY-NaN number returns that SAME
--- NaN unchanged, not nil -- so a malicious/buggy client could send a raw
--- NaN double as `limit` and reach this function with a `parsed` value no
--- comparison against it can ever resolve (`nan < 1` and `nan > hardMax`
--- are BOTH false; `math.floor(nan)` itself does not error, so unlike the
--- string.format('%d', ...) UNCAUGHT-error case this file's docs already
--- name, NaN would instead silently walk straight past both clamp checks
--- and OUT of this function, only to throw later, inside
--- server/datastore.lua's own `%d` embed, the very failure mode this
--- function exists to prevent). Guarded explicitly here, once, for every
--- caller (command or callback alike) via the standard `x ~= x` NaN
--- self-inequality test -- treated identically to an unparseable/absent
--- `rawArg` (falls back to `defaultValue`, then still runs through the
--- SAME floor+range clamp below, same as every other path through this
--- function).
---
--- SOUNDNESS RE-CHECK (this pass, per this task's explicit instruction to
--- read this function rather than trust it): re-verified directly against a
--- real Lua 5.4 interpreter, not just re-read, against every shape this
--- task named by name -- non-numeric ('abc', '', a table, a boolean),
--- NaN (both `0/0` and the string 'nan'), infinite (`math.huge`/`-math.huge`
--- and the overflow-to-infinity strings '1e400'/'-1e400'), negative, zero,
--- fractional (both positive and negative), and absurdly large finite
--- (`1e300`). Every case returns a plain, finite Lua number already inside
--- `[1, hardMax]`, with NO error thrown in any case -- `math.floor` on a
--- non-finite float does not raise in this Lua build (it returns the float
--- unchanged when it has no integer representation, which the `> hardMax` /
--- `< 1` comparisons below still resolve correctly since `-huge < 1` and
--- `huge > hardMax` are both true, and `nan`'s self-inequality is caught
--- one line above math.floor ever runs on it). CONCLUSION: the clamping
--- logic itself needed no change -- it was already sound. The only change
--- this pass makes is the SECOND return value below, `truncated`, which
--- carries NEW information the callback surface needs but the clamp itself
--- never previously reported.
--- @param rawArg string|number|nil -- a RegisterCommand string arg, a lib.callback numeric arg, or nil/absent
--- @param defaultValue number
--- @param hardMax number
--- @return number limit -- always in [1, hardMax], the exact value embedded in a query
--- @return boolean truncated -- true ONLY when a genuine, parseable request exceeded `hardMax` and was cut down to it (this task's own "you asked for 500, here are the first 100" case). NEVER true when `rawArg` was absent/unparseable/NaN and `defaultValue` was substituted instead -- every `Config.AdminAudit.MaxResults.*` value is itself asserted at resource start (see the onResourceStart block below) to already be <= hardMax, so the default path can structurally never trigger this. Also never true for a below-floor request (negative/zero/-infinity) -- that clamp exists to reject a nonsensical LOW request, not to report "asked for more than available", which is what this flag is specifically for.
local function ClampLimit(rawArg, defaultValue, hardMax)
    local parsed = tonumber(rawArg)
    if parsed == nil or parsed ~= parsed then
        parsed = defaultValue
    end
    parsed = math.floor(parsed)
    if parsed < 1 then return 1, false end
    if parsed > hardMax then return hardMax, true end
    return parsed, false
end

--- @param value string?
--- @return boolean
local function IsValidCitizenId(value)
    -- VARCHAR(50) per every k9_* citizenid column (sql/install.sql) —
    -- bounding the length to the actual column width rather than accepting
    -- an arbitrarily long string into a query parameter. Not an injection
    -- backstop (this value only ever reaches a bound `?` placeholder,
    -- never raw SQL text) — a plain sanity/DoS-lite bound, matching this
    -- task's "validate type/range/length of every argument" requirement.
    return type(value) == 'string' and value ~= '' and #value <= 50
end

--- @param value string?
--- @return boolean
local function IsValidDepartment(value)
    -- Same validation shape server/certifications/'s
    -- RevokeCertificationOffline already applies to its own `job` argument
    -- (`if not Config.Departments[job] then ... end`) — reused here rather
    -- than invented fresh, per this file's header "COMMAND SURFACE" item 5
    -- "ARGUMENT SHAPE" reasoning. A typo'd/unconfigured department name
    -- could never have a matching k9_certifications row, so this rejects
    -- it outright as `invalid_args` instead of silently returning zero
    -- results — same posture IsValidCitizenId/NormalizePlateArg already
    -- take for this file's other string arguments.
    return type(value) == 'string' and value ~= '' and Config.Departments[value] ~= nil
end

--- @param value string?
--- @return string? trimmedPlate -- nil if invalid
local function NormalizePlateArg(value)
    if type(value) ~= 'string' then return nil end
    -- Same trim server/search.lua applies to GTA's own space-padded
    -- GetVehicleNumberPlateText result — mirrored here for the same
    -- reason (a human admin typing a plate by hand is just as likely to
    -- add stray whitespace), not re-derived independently.
    local trimmed = value:match('^%s*(.-)%s*$')
    if not trimmed or trimmed == '' or #trimmed > 15 then return nil end -- VARCHAR(15) per k9_search_log.target_plate
    return trimmed
end

--- Console log line for EVERY invocation of every command in this file —
--- allowed, denied, rate-limited, or malformed. "An audit tool nobody can
--- audit is a gap" (this task's own framing). Deliberately a print(), not
--- a new DB table — see this file's header "AUDIT-OF-THE-AUDIT" section
--- for why a persisted meta-audit table is a schema decision out of this
--- file's scope. `detail` is deliberately 'n/a' for a denied/unauthorized
--- attempt (logged BEFORE any argument is parsed — see each command
--- handler's own auth-check-first ordering) so an unauthorized caller's
--- attempted query target is never even parsed, let alone logged.
--- @param source number
--- @param commandName string
--- @param detail string
--- @param outcome string -- 'ok' | 'denied' | 'rate_limited' | 'invalid_args'
local function LogAuditInvocation(source, commandName, detail, outcome)
    local whoLabel = 'console'
    if source ~= 0 then
        local Player = exports.qbx_core:GetPlayer(source)
        local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
        whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    end
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, commandName, detail, outcome))
end

--- Merges two already-LIMITed row sets (one per unique index — see
--- QueryPartnershipHistory below) into one list, sorts by `id` DESC (see
--- this file's header "SQL SAFETY" section for why `id`, never a DATETIME
--- column, is compared in Lua), then truncates to `limit`. Cheap: each
--- input list is already bounded by the SAME `limit`, so this never
--- operates on more than 2 * limit rows (<= 2 * HARD_MAX_RESULTS worst
--- case).
--- @param rowsA table
--- @param rowsB table
--- @param limit number
--- @return table merged
local function MergeSortedByIdDesc(rowsA, rowsB, limit)
    local merged = {}
    for _, row in ipairs(rowsA) do merged[#merged + 1] = row end
    for _, row in ipairs(rowsB) do merged[#merged + 1] = row end

    table.sort(merged, function(a, b) return a.id > b.id end)

    local truncated = {}
    for i = 1, math.min(limit, #merged) do
        truncated[i] = merged[i]
    end
    return truncated
end

-- ======================================================================
-- DISPLAY NAME RESOLUTION (this pass) -- owner's own request, verbatim:
-- "Ensure a name actually pops up and not the player id in the tablet
-- etc." Applied here to every audit surface THIS FILE owns: the five
-- /k9audit* commands' chat/console output (FormatCertRow/FormatPartnershipRow/
-- FormatSearchLogRow/FormatDeptCertRow below, via PresentRows/
-- PrintRowsToConsole) and the tabletAudit* callbacks' JSON `rows`/`label`
-- the tablet's Audit Trail tab renders (see the CALLBACK SURFACE section
-- further below).
--
-- A DELIBERATE, SELF-CONTAINED LOCAL DUPLICATE of server/tablet.lua's own
-- ResolveDisplayName -- same resolution order (online charinfo ->
-- GetPlayerName native -> offline GetOfflinePlayer charinfo -> citizenid
-- fallback, never blank), NOT a cross-file call to that file's `local`
-- function. Two independent reasons, either alone sufficient:
--   1. Exporting server/tablet.lua's ResolveDisplayName as a resource-global
--      would need a NEW .luacheckrc `globals` entry this file cannot add
--      for itself -- this resource's established convention for a
--      genuinely small, self-contained helper is a per-file duplicate
--      instead (see server/permissions.lua's own MeetsDepartmentGradeOrHighCommand/
--      IsDuplicateKeyError doc comments for the same reasoning already
--      applied elsewhere in this codebase).
--   2. server/tablet.lua returns ENTIRELY at its own top (`if not
--      Config.Features.CommandTablet then return end`) -- this file's five
--      audit COMMANDS are a load-bearing, independent surface from the
--      tablet (Config.Features.AdminAuditCommands is its own, separate
--      flag; an operator can ship CommandTablet = false with
--      AdminAuditCommands = true, a real, plausible config, not a
--      contrived one), so depending on a global that file only SOMETIMES
--      defines would make this file's own name resolution silently break
--      whenever CommandTablet happens to be off. A local duplicate has no
--      such load-order or feature-flag coupling.
-- ======================================================================

--- @param charinfo any
--- @return string?
local function FullNameFromCharinfo(charinfo)
    if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
        local full = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
        if type(full) == 'string' and full ~= '' then return full end
    end
    return nil
end

--- @param citizenid string
--- @return string -- ALWAYS a non-empty string; falls back to `citizenid` itself when no name resolves, never blank
local function ResolveAuditDisplayName(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData then
        local full = FullNameFromCharinfo(onlinePlayer.PlayerData.charinfo)
        if full then return full end

        local onlineSrc = onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            local ok, viaNative = pcall(GetPlayerName, onlineSrc)
            if ok and type(viaNative) == 'string' and viaNative ~= '' then return viaNative end
        end
    end

    -- OFFLINE -- ask qbx_core's own offline accessor before giving up. See
    -- server/tablet.lua's own header "NAME RESOLUTION" for how this export
    -- was confirmed real against qbx_core's live server/player.lua.
    local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
    if ok and type(offlinePlayer) == 'table' and offlinePlayer.PlayerData then
        local full = FullNameFromCharinfo(offlinePlayer.PlayerData.charinfo)
        if full then return full end
    end

    -- Still nothing usable -- fall back to the citizenid itself. Never
    -- blank, never a guess at an unverified schema.
    return citizenid
end

--- Pure text-formatting helper (no I/O of its own) -- turns an
--- already-resolved-or-nil display name and its citizenid into ONE
--- human-readable fragment for a chat/console line, per this task's "keep
--- the identifier, add the name; never a blank or a fake name" rule:
---   * citizenid nil/empty -> 'N/A' (this file's own pre-existing
---     convention for a nullable citizenid column, e.g. revoked_by/ended_by
---     on an active/never-ended row).
---   * name resolved to something OTHER than the citizenid itself ->
---     "Name (citizenid)".
---   * name nil, OR identical to the citizenid (ResolveAuditDisplayName's
---     own documented "nothing resolved" fallback) -> the bare citizenid --
---     never a fabricated name, and this bare citizenid IS the "clear
---     marker" this task's own instruction asks for when a name genuinely
---     cannot be resolved (identical, deliberately, to how
---     server/tablet.lua's own `name` field already signals the same case:
---     a `name` equal to its sibling `citizenid` reads as unresolved, not
---     as a coincidentally citizenid-shaped human name).
--- @param name string? -- ResolveAuditDisplayName's own result, or nil if never resolved (e.g. a nil/empty source column)
--- @param citizenid string?
--- @return string
local function NameWithCitizenId(name, citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 'N/A' end
    if type(name) == 'string' and name ~= '' and name ~= citizenid then
        return ('%s (%s)'):format(name, citizenid)
    end
    return citizenid
end

--- Convenience wrapper combining the two helpers above, for the `label`
--- header strings below that take a single citizenid argument and have no
--- separate `_name` sibling field to carry (contrast the ROW enrichers
--- further below, which deliberately keep the resolved name SEPARATE from
--- the formatted fragment so it can travel to the tablet's JSON `_name`
--- fields unformatted).
--- @param citizenid string? -- already validated by IsValidCitizenId at every call site
--- @return string
local function AuditDisplayLabel(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 'N/A' end
    return NameWithCitizenId(ResolveAuditDisplayName(citizenid), citizenid)
end

--- @param row table -- one k9_certifications row, ALREADY passed through
--- EnrichCertHistoryRows below (granted_by_name/revoked_by_name present)
--- @return string
local function FormatCertRow(row)
    return locale('admin.cert_row_format',
        tostring(row.job), tostring(row.active == 1), NameWithCitizenId(row.granted_by_name, row.granted_by), tostring(row.granted_at),
        NameWithCitizenId(row.revoked_by_name, row.revoked_by),
        row.revoked_at and tostring(row.revoked_at) or 'N/A'
    )
end

--- @param row table -- one k9_partnerships row, ALREADY passed through
--- EnrichPartnershipHistoryRows below
--- @return string
local function FormatPartnershipRow(row)
    return locale('admin.partnership_row_format',
        NameWithCitizenId(row.k9_citizenid_name, row.k9_citizenid), NameWithCitizenId(row.handler_citizenid_name, row.handler_citizenid), tostring(row.active == 1),
        NameWithCitizenId(row.established_by_name, row.established_by), tostring(row.established_at),
        NameWithCitizenId(row.ended_by_name, row.ended_by),
        row.ended_at and tostring(row.ended_at) or 'N/A'
    )
end

--- @param row table -- one k9_search_log row, ALREADY passed through
--- EnrichSearchLogRows below
--- @return string
local function FormatSearchLogRow(row)
    -- Dynamic-value substitution via locale()'s own %s placeholder, not `..`
    -- concatenation — same "no string-built player-facing fragments"
    -- discipline as DEVELOPER_REFERENCE.md's own documented concatenation fixes
    -- (movement.officer_fallback_name, bonetool.bone_index_label, etc.).
    local targetLabel = row.target_type == 'vehicle'
        and locale('admin.search_log_target_plate_label', tostring(row.target_plate))
        or locale('admin.search_log_target_citizenid_label', NameWithCitizenId(row.target_citizenid_name, row.target_citizenid))
    return locale('admin.search_log_row_format',
        tostring(row.searched_at), NameWithCitizenId(row.searcher_citizenid_name, row.searcher_citizenid), tostring(row.searcher_job),
        tostring(row.target_type), targetLabel, tostring(row.result),
        row.total_weight and tostring(row.total_weight) or 'N/A',
        row.alert_tier and tostring(row.alert_tier) or 'N/A'
    )
end

--- @param row table -- one k9_progression row
--- @return string
local function FormatProgressionRow(row)
    -- Deliberately reports the raw `xp` total only — see this file's
    -- header "COMMAND SURFACE" item 4 for why a tier is not derived here.
    -- No citizenid column on this row at all (see QueryProgressionSnapshot's
    -- own doc comment) -- the name resolution for THIS query lives entirely
    -- in its own `label` (AuditDisplayLabel), not here.
    return locale('admin.progression_row_format', tostring(row.xp), tostring(row.updated_at))
end

--- @param row table -- one k9_certifications row (active-only roster shape),
--- ALREADY passed through EnrichDeptRosterRows below
--- @return string
local function FormatDeptCertRow(row)
    -- Deliberately omits `job` (already the query's own fixed argument —
    -- same "never repeat the field the query is scoped by" convention
    -- FormatCertRow above follows by omitting `citizenid`) and
    -- `active`/`revoked_by`/`revoked_at` (always true/NULL/NULL for an
    -- active-only roster row — see this file's header "COMMAND SURFACE"
    -- item 5 "DISPLAY BOUNDARY" reasoning for why nothing wider than
    -- idx_job_active's own documented column list is exposed here).
    return locale('admin.dept_cert_row_format', NameWithCitizenId(row.citizenid_name, row.citizenid), NameWithCitizenId(row.granted_by_name, row.granted_by), tostring(row.granted_at))
end

--- Presents `rows` (already fetched, already bounded) to a connected
--- caller as a small number of batched ox_lib toasts — a deliberately
--- minimal in-game presentation. This file's scope is the command/query/
--- authorization layer, not a new NUI screen; a proper list view is
--- natural follow-up work for coder-ui once this command surface proves
--- useful, not built here. NEVER called for console (source == 0).
--- @param target number
--- @param label string
--- @param rows table
--- @param formatRow fun(row: table): string
local function PresentRows(target, label, rows, formatRow)
    if #rows == 0 then
        NotifyPlayer(target, locale('admin.no_results_found', label), 'info')
        return
    end

    NotifyPlayer(target, locale('admin.result_count', label, #rows), 'info')

    local lines = {}
    for i, row in ipairs(rows) do
        lines[#lines + 1] = formatRow(row)
        if #lines >= ROWS_PER_NOTIFY_CHUNK or i == #rows then
            NotifyPlayer(target, table.concat(lines, '\n'), 'info')
            lines = {}
        end
    end
end

--- Console-side presentation counterpart to PresentRows above — a plain
--- print() per row, no client to notify.
--- @param label string
--- @param rows table
--- @param formatRow fun(row: table): string
local function PrintRowsToConsole(label, rows, formatRow)
    print(('[qbx_k9unit] %s: %d result(s)'):format(label, #rows))
    for _, row in ipairs(rows) do
        print('[qbx_k9unit]   ' .. formatRow(row))
    end
end

-- ======================================================================
-- ROW ENRICHERS (this pass) -- add a `<field>_name` sibling to each RAW
-- citizenid column these five queries already return, additive only:
-- every existing raw column is UNCHANGED (this task's own "add a
-- display-name field alongside the id -- do not replace the id, and do not
-- make any code path key off a name" rule). ONE enrichment per query
-- function below, mutating and returning the same `rows` table -- both of
-- each query's own callers (the matching /k9audit* RegisterCommand handler
-- via FormatCertRow/FormatPartnershipRow/FormatSearchLogRow/FormatDeptCertRow,
-- and the matching tabletAudit* lib.callback's own JSON `rows` response)
-- see the SAME already-enriched rows -- name resolution runs exactly ONCE
-- per query, not once per consumer.
-- ======================================================================

--- @param rows table -- raw k9_certifications history rows (job, granted_by, granted_at, revoked_by, revoked_at, active)
--- @return table -- the same rows, each with granted_by_name/revoked_by_name added (nil where the source column is nil)
local function EnrichCertHistoryRows(rows)
    for _, row in ipairs(rows) do
        row.granted_by_name = (type(row.granted_by) == 'string' and row.granted_by ~= '') and ResolveAuditDisplayName(row.granted_by) or nil
        row.revoked_by_name = (type(row.revoked_by) == 'string' and row.revoked_by ~= '') and ResolveAuditDisplayName(row.revoked_by) or nil
    end
    return rows
end

--- @param rows table -- raw k9_partnerships history rows
--- @return table -- the same rows, each with k9_citizenid_name/handler_citizenid_name/established_by_name/ended_by_name added (a K9 is a citizenid too -- see server/permissions.lua's own "a handler OR a K9, since both are just citizenids" convention)
local function EnrichPartnershipHistoryRows(rows)
    for _, row in ipairs(rows) do
        row.k9_citizenid_name = (type(row.k9_citizenid) == 'string' and row.k9_citizenid ~= '') and ResolveAuditDisplayName(row.k9_citizenid) or nil
        row.handler_citizenid_name = (type(row.handler_citizenid) == 'string' and row.handler_citizenid ~= '') and ResolveAuditDisplayName(row.handler_citizenid) or nil
        row.established_by_name = (type(row.established_by) == 'string' and row.established_by ~= '') and ResolveAuditDisplayName(row.established_by) or nil
        row.ended_by_name = (type(row.ended_by) == 'string' and row.ended_by ~= '') and ResolveAuditDisplayName(row.ended_by) or nil
    end
    return rows
end

--- @param rows table -- raw k9_search_log rows
--- @return table -- the same rows, each with searcher_citizenid_name/target_citizenid_name added. `target_citizenid_name` stays nil for a vehicle-type row (target_citizenid itself is nil there -- target_plate is the identifier instead, and a plate is not a citizenid, so it is never routed through ResolveAuditDisplayName)
local function EnrichSearchLogRows(rows)
    for _, row in ipairs(rows) do
        row.searcher_citizenid_name = (type(row.searcher_citizenid) == 'string' and row.searcher_citizenid ~= '') and ResolveAuditDisplayName(row.searcher_citizenid) or nil
        row.target_citizenid_name = (type(row.target_citizenid) == 'string' and row.target_citizenid ~= '') and ResolveAuditDisplayName(row.target_citizenid) or nil
    end
    return rows
end

--- @param rows table -- raw k9_certifications active-roster rows (citizenid, granted_by, granted_at)
--- @return table -- the same rows, each with citizenid_name/granted_by_name added
local function EnrichDeptRosterRows(rows)
    for _, row in ipairs(rows) do
        row.citizenid_name = (type(row.citizenid) == 'string' and row.citizenid ~= '') and ResolveAuditDisplayName(row.citizenid) or nil
        row.granted_by_name = (type(row.granted_by) == 'string' and row.granted_by ~= '') and ResolveAuditDisplayName(row.granted_by) or nil
    end
    return rows
end

--- '/k9audit cert' query. Uses idx_citizen_job_active's leading `citizenid`
--- column as a prefix scan (sql/install.sql's own comment on that index
--- names this exact "full cert history for citizenid X" shape). Ordered by
--- `granted_at DESC` — MySQL sorts this server-side; this file never
--- parses/compares that value in Lua (see header "SQL SAFETY").
--- @param citizenid string
--- @param limit number -- already clamped by ClampLimit
--- @return table rows
local function QueryCertificationHistory(citizenid, limit)
    return EnrichCertHistoryRows(K9Store.Cert_GetHistory(citizenid, limit))
end

--- '/k9audit partner' query. Two separate equality queries — one per unique
--- index (idx_k9_citizenid_active / idx_handler_citizenid_active) — merged
--- in Lua by MergeSortedByIdDesc above, rather than one OR'd WHERE clause
--- forcing an index-merge plan across two independent indexes. Each
--- sub-query is itself ordered `id DESC LIMIT limit` (not `established_at
--- DESC`) precisely so the Lua-side merge and the SQL-side LIMIT selection
--- agree on the exact same sort key — see header "SQL SAFETY".
--- @param citizenid string
--- @param limit number -- already clamped by ClampLimit
--- @return table rows
local function QueryPartnershipHistory(citizenid, limit)
    local asK9 = K9Store.Partner_GetHistoryByK9(citizenid, limit)
    local asHandler = K9Store.Partner_GetHistoryByHandler(citizenid, limit)

    -- Enriched AFTER the merge/truncate, deliberately: name resolution only
    -- ever runs over the final, already-bounded `limit`-sized result, never
    -- over the larger pre-merge candidate set.
    return EnrichPartnershipHistoryRows(MergeSortedByIdDesc(asK9, asHandler, limit))
end

--- '/k9audit search officer' query — searches PERFORMED BY citizenid, most
--- recent first. Uses idx_searcher_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param citizenid string
--- @param limit number
--- @return table rows
local function QuerySearchLogByOfficer(citizenid, limit)
    return EnrichSearchLogRows(K9Store.SearchLog_GetByOfficer(citizenid, limit))
end

--- '/k9audit search plate' query — searches OF a vehicle plate, most recent
--- first. Uses idx_target_plate_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param plate string -- already normalized by NormalizePlateArg
--- @param limit number
--- @return table rows
local function QuerySearchLogByPlate(plate, limit)
    return EnrichSearchLogRows(K9Store.SearchLog_GetByPlate(plate, limit))
end

--- '/k9audit search person' query — searches OF a person citizenid, most
--- recent first. Uses idx_target_citizenid_searched_at, exactly matching
--- sql/install.sql's own documented query for that index.
--- @param citizenid string
--- @param limit number
--- @return table rows
local function QuerySearchLogByPerson(citizenid, limit)
    return EnrichSearchLogRows(K9Store.SearchLog_GetByPerson(citizenid, limit))
end

--- '/k9audit search recent' query — the N most recently logged searches of
--- ANY kind, no WHERE clause. Ordered by `id DESC` (InnoDB's own clustered
--- primary-key order), NOT `searched_at` — reading the tail of the
--- clustered index is cheap and needs no dedicated index of its own; see
--- this file's header "COMMAND SURFACE" section for the full reasoning.
--- @param limit number
--- @return table rows
local function QuerySearchLogRecent(limit)
    return EnrichSearchLogRows(K9Store.SearchLog_GetRecent(limit))
end

--- '/k9audit xp' query — see this file's header "COMMAND SURFACE" item 4
--- and "COVERAGE RE-CHECK" for the full reasoning. `citizenid` is
--- k9_progression's own PRIMARY KEY (sql/install.sql) — a plain,
--- unclamped `LIMIT 1` literal is correct here, NOT a caller-influenced
--- ClampLimit value, because there is structurally never more than one
--- matching row regardless of what any argument says.
--- @param citizenid string
--- @return table rows -- 0 or 1 rows
local function QueryProgressionSnapshot(citizenid)
    return K9Store.XP_GetSnapshotRows(citizenid)
end

--- '/k9audit dept' query — see this file's header "COMMAND SURFACE" item 5
--- and "COVERAGE RE-CHECK (this pass, take 2)" for the full reasoning.
--- Uses `idx_job_active` (`job`, `active`) — this is sql/install.sql's own
--- documented query for that index, verbatim, with only ORDER BY/LIMIT
--- added on top (same discipline every other query function in this file
--- already follows). `active = 1` restricts this to the CURRENT roster,
--- never revoked history — see this file's header "ACTIVE-ONLY, NOT FULL
--- HISTORY" reasoning. Ordered by `granted_at DESC` — MySQL sorts this
--- server-side; this file never parses/compares that value in Lua (see
--- header "SQL SAFETY").
--- @param job string -- already validated against Config.Departments by IsValidDepartment
--- @param limit number -- already clamped by ClampLimit
--- @return table rows
local function QueryDepartmentRoster(job, limit)
    return EnrichDeptRosterRows(K9Store.Cert_GetActiveRosterByJob(job, limit))
end

-- ======================================================================
-- COMMAND REGISTRATION — gated on Config.Features.AdminAuditCommands AT
-- REGISTRATION TIME (this task's explicit convention): if the flag is not
-- `true`, none of the five commands below are ever registered at all, not
-- merely a runtime no-op. A missing/nil flag is treated identically to
-- `false` (feature disabled, no crash) — this resource must not fail to
-- start for an unrelated server that hasn't touched config.lua's new
-- fields yet. Only once the flag is explicitly `true` does this block
-- require Config.AdminAudit's full shape, and fails loudly (assert) if
-- that shape is wrong — the operator has opted in and deserves an
-- immediate, obvious failure rather than a silently broken command
-- surface. Mirrors server/search.lua's own onResourceStart config-safety-
-- guard convention.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if not (Config.Features and Config.Features.AdminAuditCommands == true) then
        return -- feature disabled (or not yet configured) — nothing below this line ever runs
    end

    assert(
        type(Config.AdminAudit) == 'table',
        '[qbx_k9unit] Config.Features.AdminAuditCommands is true but Config.AdminAudit is missing.'
    )

    -- CLAMP AND WARN, DELIBERATELY NEVER THROW (was a bare `assert` before
    -- this pass). A bare assert inside this SAME onResourceStart handler
    -- aborts the handler the instant it fires, silently skipping every
    -- registration still to run below it -- all five commands AND all six
    -- callbacks this handler registers, none of which have anything to do
    -- with this cooldown -- for the rest of this resource's uptime. A
    -- too-low/malformed value here fails safe on its own regardless
    -- (server/cooldowns.lua's IsOnCooldown treats a non-positive/NaN
    -- per-call threshold as "permanently on cooldown", printing its own
    -- separate one-time warning the first time any audit command actually
    -- runs) -- so the old assert bought nothing but a few seconds' head
    -- start on that same discovery, at the cost of being able to take the
    -- whole command surface down with it.
    do
        local rawCooldownMs = Config.AdminAudit.CommandCooldownMs
        local isValidNumber = type(rawCooldownMs) == 'number' and rawCooldownMs == rawCooldownMs -- NaN ~= NaN
        if not isValidNumber then
            print(
                ('[qbx_k9unit] WARNING: Config.AdminAudit.CommandCooldownMs (%s) is missing or not a number -- ' ..
                 'using the built-in fallback of %dms instead of aborting every command/callback this file ' ..
                 'registers. Fix Config.AdminAudit.CommandCooldownMs in config.lua to silence this ' ..
                 'warning.'):format(tostring(rawCooldownMs), DEFAULT_COMMAND_COOLDOWN_MS)
            )
            Config.AdminAudit.CommandCooldownMs = DEFAULT_COMMAND_COOLDOWN_MS
        elseif rawCooldownMs < MIN_COMMAND_COOLDOWN_MS then
            print(
                ('[qbx_k9unit] WARNING: Config.AdminAudit.CommandCooldownMs (%s) must be >= %dms -- clamping UP ' ..
                 'to %dms instead of aborting every command/callback this file registers. Fix ' ..
                 'Config.AdminAudit.CommandCooldownMs in config.lua to silence this warning.'
                ):format(tostring(rawCooldownMs), MIN_COMMAND_COOLDOWN_MS, MIN_COMMAND_COOLDOWN_MS)
            )
            Config.AdminAudit.CommandCooldownMs = MIN_COMMAND_COOLDOWN_MS
        end
    end
    -- Config.AdminAudit.AcePermission is intentionally NOT asserted here any
    -- more -- this file no longer calls IsPlayerAceAllowed at all as of this
    -- pass (see header "ACCESS MODEL"). If a shipped config still declares
    -- it, that's harmless dead data, not a startup failure.

    -- (ACE->job-rank rewrite, an earlier pass): IsAuthorizedAdmin compares
    -- job.grade.level against Config.Departments[job.name].auditGrade for
    -- every non-boss caller. Only run once Config.Features.AdminAuditCommands
    -- is true, matching this whole block's own "operator has opted in"
    -- convention -- an unrelated server that never touches this feature at
    -- all is never forced to add auditGrade to every department it didn't
    -- otherwise need to configure for this file.
    assert(type(Config.Departments) == 'table', '[qbx_k9unit] Config.Features.AdminAuditCommands is true but Config.Departments is missing -- IsAuthorizedAdmin requires it to resolve the caller\'s own department threshold.')

    -- CLAMP AND WARN, DELIBERATELY NEVER THROW (was a per-department bare
    -- `assert` before this pass -- unlike server/highcommand.lua's identical
    -- highCommandGrade guard, this one had NO nil-allowed branch at all, so
    -- an operator who simply never set auditGrade on a department also hit
    -- this abort, not only a genuine typo). IsAuthorizedAdmin's own
    -- type-check (see that function's doc comment) already fails closed at
    -- RUNTIME on a missing/malformed auditGrade -- denies every non-boss
    -- officer in that department -- identically for nil and for any other
    -- non-number value, so forcing a malformed value to nil here changes
    -- nothing about that runtime behavior; it only makes the failure LOUD,
    -- once, at start, instead of being silently discovered per-officer, and
    -- stops it from being able to abort every OTHER command/callback in
    -- this same handler.
    for jobName, dept in pairs(Config.Departments) do
        if type(dept) ~= 'table' then
            print(
                ('[qbx_k9unit] WARNING: Config.Departments[%s] is not a table (found: %s) -- IsAuthorizedAdmin ' ..
                 'cannot resolve an auditGrade for this department and will fail closed (deny) for every ' ..
                 'officer in it. Fix Config.Departments[%s] in config.lua to restore it.'
                ):format(tostring(jobName), tostring(dept), tostring(jobName))
            )
        elseif type(dept.auditGrade) ~= 'number' then
            print(
                ('[qbx_k9unit] WARNING: Config.Departments[%s].auditGrade must be a number (found: %s) -- ' ..
                 'IsAuthorizedAdmin compares job.grade.level >= dept.auditGrade for every non-boss officer in ' ..
                 'that department. FORCING it to nil for this session (fails closed, denying every non-boss ' ..
                 'officer in this department -- the exact same outcome IsAuthorizedAdmin\'s own runtime type ' ..
                 'check already produces for a malformed value) instead of aborting every command/callback ' ..
                 'this file registers. Every other field on this department (certifierGrade, ' ..
                 'highCommandGrade, label, ...) is unaffected. Find Config.Departments[%s].auditGrade in ' ..
                 'config.lua and set it to a number to restore audit access for this department.'
                ):format(tostring(jobName), tostring(dept.auditGrade), tostring(jobName))
            )
            dept.auditGrade = nil
        end
    end

    local maxResults = Config.AdminAudit.MaxResults
    assert(type(maxResults) == 'table', '[qbx_k9unit] Config.AdminAudit.MaxResults must be a table.')

    -- CLAMP AND WARN for every Config.AdminAudit.MaxResults key, mirroring
    -- server/cooldowns.lua's own ResolveConfiguredThresholdMs pattern (read,
    -- validate, print one clear warning naming the key and the fallback
    -- used, never abort). Certifications/Partnerships/SearchLog used to be a
    -- bare per-key `assert` loop here -- the exact "config-abort" bug class
    -- this resource has been bitten by before: one malformed key on an
    -- unrelated operator's config would silently kill EVERY registration in
    -- this entire onResourceStart handler, all five commands AND all six
    -- callbacks, not merely the one query that actually needs the bad
    -- value. 'CatalogAudit' (added in a later pass) was deliberately given
    -- this SAME safe treatment from the start specifically to dodge that
    -- fate -- this pass extends it to the three older keys that were still
    -- carrying the original assert, rather than inventing a second shape.
    --
    -- `x or default` does NOT fall back when x is 0 -- checked here via an
    -- explicit `type(...) == 'number'` + range test, never via `or`, the
    -- exact footgun server/cooldowns.lua's own header names by name. A
    -- non-positive value is also never read as "unlimited" -- it is caught
    -- by the SAME `>= 1` floor as every other malformed case, not given
    -- special "0 means no cap" meaning.
    -- @param key string -- the exact Config.AdminAudit.MaxResults.<key> name, used only in the printed warning
    -- @param fallback number -- a positive, hardcoded literal used only when the configured value is invalid
    local function ResolveMaxResultsKey(key, fallback)
        local value = maxResults[key]
        local valid = type(value) == 'number'
            and value == math.floor(value)
            and value >= 1
            and value <= HARD_MAX_RESULTS
        if not valid then
            print(
                ('[qbx_k9unit] admin.lua: Config.AdminAudit.MaxResults.%s is missing or not an integer in ' ..
                 '[1, %d] (found: %s). Using a built-in fallback of %d instead of aborting this file\'s entire ' ..
                 'command/callback registration over one field. Add Config.AdminAudit.MaxResults.%s = %d (or ' ..
                 'your own preferred value, 1-%d) to config.lua to silence this warning.'
                ):format(key, HARD_MAX_RESULTS, tostring(value), fallback, key, fallback, HARD_MAX_RESULTS)
            )
            maxResults[key] = fallback
        end
    end

    -- Certifications/Partnerships/SearchLog have been required keys here
    -- since before this pass touched this file -- 25 matches config.lua's
    -- own shipped default for all three.
    ResolveMaxResultsKey('Certifications', 25)
    ResolveMaxResultsKey('Partnerships', 25)
    ResolveMaxResultsKey('SearchLog', 25)

    -- 'CatalogAudit' (GAP 2 closure, an earlier pass) backs
    -- `qbx_k9unit:server:tabletAuditCatalog`'s own default result limit --
    -- 25 matches config.lua's own shipped default for this key too.
    ResolveMaxResultsKey('CatalogAudit', 25)

    --- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md #1) -- the five
    --- bodies below are named LOCAL functions, reached through the single
    --- '/k9audit <cert|partner|search|xp|dept> ...' dispatcher further
    --- below, which parses the subcommand keyword FIRST and then forwards
    --- into the exact same function.
    ---
    --- Each function re-checks `IsAuthorizedAdmin(source)` from inside its
    --- OWN body rather than relying on a single shared gate at the
    --- dispatcher's top -- so the gate cannot be widened by a future edit
    --- to the dispatcher. All five share an IDENTICAL gate/cooldown (see
    --- docs/history/COMMAND_CONSOLIDATION_SPEC.md §1's own audit table).
    ---
    --- The five original single-purpose command names
    --- were registered as hidden aliases through 2026-09-02 and are now
    --- DELETED at the owner's request -- the server had not launched, so
    --- there were no macros or cheat-sheets to protect.

    --- '/k9audit cert [citizenid] [limit]' core -- see this file's header
    --- "COMMAND SURFACE" item 1.
    --- @param source number
    --- @param args string[]
    local function HandleAuditCert(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9audit cert', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9audit cert', 'n/a', 'rate_limited')
            return -- silent no-op: rate-limited, not an error worth notifying about (matches this resource's bark/leash-request/certify-action convention)
        end

        local citizenid = args[1]
        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'k9audit cert', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditcert')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryCertificationHistory(citizenid, limit)
        local label = locale('admin.cert_history_label', AuditDisplayLabel(citizenid))

        LogAuditInvocation(source, 'k9audit cert', citizenid, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatCertRow)
        else
            PresentRows(source, label, rows, FormatCertRow)
        end
    end


    --- '/k9audit partner [citizenid] [limit]' core -- see this file's header
    --- "COMMAND SURFACE" item 2.
    --- @param source number
    --- @param args string[]
    local function HandleAuditPartner(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9audit partner', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9audit partner', 'n/a', 'rate_limited')
            return
        end

        local citizenid = args[1]
        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'k9audit partner', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditpartner')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.Partnerships, HARD_MAX_RESULTS)
        local rows = QueryPartnershipHistory(citizenid, limit)
        local label = locale('admin.partnership_history_label', AuditDisplayLabel(citizenid))

        LogAuditInvocation(source, 'k9audit partner', citizenid, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatPartnershipRow)
        else
            PresentRows(source, label, rows, FormatPartnershipRow)
        end
    end


    --- '/k9audit search <officer|plate|person|recent> [value] [limit]' core
    --- -- see this file's header "COMMAND SURFACE" item 3. Authorization is
    --- checked BEFORE the `mode` argument is even inspected — an
    --- unauthorized caller learns nothing about argument validity, not
    --- even whether their chosen mode string was recognized. This is a
    --- deliberate divergence from server/certifications/'s own
    --- GrantCertification ordering (which validates argument shape BEFORE
    --- eligibility) — justified here because this surface is explicitly a
    --- privacy-sensitive audit tool (this task's own framing), not a
    --- capability grant with an obvious legitimate target already implied
    --- by the caller reaching the handler at all. Flagged for
    --- coder-security to confirm or override, same as the console
    --- carve-out in this file's header.
    --- @param source number
    --- @param args string[]
    local function HandleAuditSearch(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9audit search', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9audit search', 'n/a', 'rate_limited')
            return
        end

        local mode = args[1]
        if not VALID_SEARCH_LOG_MODES[mode] then
            LogAuditInvocation(source, 'k9audit search', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditsearch')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local rows, label

        if mode == 'officer' or mode == 'person' then
            local citizenid = args[2]
            if not IsValidCitizenId(citizenid) then
                LogAuditInvocation(source, 'k9audit search', 'n/a', 'invalid_args')
                local usage = locale('admin.usage_auditsearch_mode', mode)
                if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
                return
            end
            local limit = ClampLimit(args[3], Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = (mode == 'officer') and QuerySearchLogByOfficer(citizenid, limit) or QuerySearchLogByPerson(citizenid, limit)
            label = locale('admin.search_log_label_by_value', mode, AuditDisplayLabel(citizenid))
        elseif mode == 'plate' then
            local plate = NormalizePlateArg(args[2])
            if not plate then
                LogAuditInvocation(source, 'k9audit search', 'n/a', 'invalid_args')
                local usage = locale('admin.usage_auditsearch_plate')
                if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
                return
            end
            local limit = ClampLimit(args[3], Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogByPlate(plate, limit)
            label = locale('admin.search_log_label_plate', plate)
        else -- 'recent'
            local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogRecent(limit)
            label = locale('admin.search_log_label_recent')
        end

        LogAuditInvocation(source, 'k9audit search', label, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatSearchLogRow)
        else
            PresentRows(source, label, rows, FormatSearchLogRow)
        end
    end


    --- '/k9audit xp [citizenid]' core -- see this file's header "COMMAND
    --- SURFACE" item 4 and "COVERAGE RE-CHECK" for the full reasoning. No
    --- `[limit]` argument — `citizenid` is k9_progression's own PRIMARY
    --- KEY, so there is never more than one row to bound.
    --- @param source number
    --- @param args string[]
    local function HandleAuditXp(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9audit xp', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9audit xp', 'n/a', 'rate_limited')
            return
        end

        local citizenid = args[1]
        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'k9audit xp', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditxp')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local rows = QueryProgressionSnapshot(citizenid)
        local label = locale('admin.xp_snapshot_label', AuditDisplayLabel(citizenid))

        LogAuditInvocation(source, 'k9audit xp', citizenid, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatProgressionRow)
        else
            PresentRows(source, label, rows, FormatProgressionRow)
        end
    end


    --- '/k9audit dept <job> [limit]' core -- see this file's header "COMMAND
    --- SURFACE" item 5 and "COVERAGE RE-CHECK (this pass, take 2)" for the
    --- full reasoning (idx_job_active, specified/indexed for but never
    --- queried until now). Reuses Config.AdminAudit.MaxResults.Certifications
    --- as its result cap — see item 5's own "RESULT CAP" note for why no
    --- new config key was added.
    --- @param source number
    --- @param args string[]
    local function HandleAuditDept(source, args)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'k9audit dept', 'n/a', 'denied')
            if source ~= 0 then NotifyPlayer(source, locale('admin.not_authorized'), 'error') end
            return
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'k9audit dept', 'n/a', 'rate_limited')
            return
        end

        local job = args[1]
        if not IsValidDepartment(job) then
            LogAuditInvocation(source, 'k9audit dept', 'n/a', 'invalid_args')
            local usage = locale('admin.usage_auditdept')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        local limit = ClampLimit(args[2], Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryDepartmentRoster(job, limit)
        local label = locale('admin.dept_roster_label', job)

        LogAuditInvocation(source, 'k9audit dept', job, 'ok')

        if source == 0 then
            PrintRowsToConsole(label, rows, FormatDeptCertRow)
        else
            PresentRows(source, label, rows, FormatDeptCertRow)
        end
    end


    -- ==================================================================
    -- '/k9audit <cert|partner|search|xp|dept> ...' -- docs/history/COMMAND_CONSOLIDATION_SPEC.md
    -- #1, the merged entry point. NOT contextual dispatch (project-owner's
    -- own "fluid, do the obviously-right-thing" redirect was evaluated
    -- against this family's REAL code and does not fit it, unlike
    -- fetch/kennel/training -- see this pass's own report for the full
    -- reasoning): all five subcommands share the IDENTICAL
    -- IsAuthorizedAdmin gate (nobody is ever entitled to exactly one of the
    -- five but not the others), and every one of the five needs a
    -- DIFFERENT mandatory target argument (a citizenid string for
    -- cert/partner/xp, a whitelisted mode keyword for search, a
    -- Config.Departments job name for dept) with no ambient "current
    -- context" this dispatcher could infer any of them from -- there is no
    -- state to guess FROM. An explicit subcommand keyword stays required;
    -- the no-argument path below still just prints the subcommand list
    -- (docs/history/COMMAND_CONSOLIDATION_SPEC.md §4's own established convention,
    -- reused verbatim from '/k9audit search' with no bad-subcommand args at
    -- all).
    --
    -- PARSE THE SUBCOMMAND FIRST, then forward into that ONE subcommand's
    -- own Handle* function above UNCHANGED -- IsAuthorizedAdmin(source) is
    -- re-run from inside whichever Handle* function is reached, exactly as
    -- it would be via the old standalone command name. This dispatcher
    -- itself performs NO authorization check of its own before forwarding
    -- -- there is nothing to widen by skipping one, since every branch's
    -- own gate still runs, unconditionally, before that branch does
    -- anything else.
    -- ==================================================================
    local AUDIT_SUBCOMMAND_HANDLERS = {
        cert = HandleAuditCert,
        partner = HandleAuditPartner,
        search = HandleAuditSearch,
        xp = HandleAuditXp,
        dept = HandleAuditDept,
    }

    --- Shifts args[2..] down to a new table's [1..], so a subcommand's own
    --- Handle* function sees an identical `args` shape to what it sees when
    --- reached via its own standalone command name (where args[1] is
    --- already the citizenid/mode/job, not the subcommand keyword).
    --- @param args string[]
    --- @return string[] shifted
    local function ShiftArgsPastSubcommand(args)
        local shifted = {}
        for i = 2, #args do
            shifted[#shifted + 1] = args[i]
        end
        return shifted
    end

    RegisterAdminCommand('k9audit', function(source, args)
        local subcommand = args[1]
        local handler = subcommand and AUDIT_SUBCOMMAND_HANDLERS[subcommand]

        if not handler then
            -- NO-ARGUMENT / UNRECOGNIZED-SUBCOMMAND DISCOVERABILITY
            -- (docs/history/COMMAND_CONSOLIDATION_SPEC.md §4) -- the exact convention
            -- '/k9audit search' already established, reused verbatim. Never
            -- an error for a bare invocation -- this IS the "what are my
            -- options" answer for a non-technical owner.
            local usage = locale('admin.usage_audit')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        handler(source, ShiftArgsPastSubcommand(args))
    end, false)

    -- ======================================================================
    -- CALLBACK SURFACE (this pass) -- the missing half this task exists to
    -- close: the five commands above only ever format their query results
    -- into a chat toast (PresentRows) or a console print
    -- (PrintRowsToConsole); there was, until now, no way for the tablet (or
    -- any other in-game consumer) to reach the underlying ROWS themselves.
    -- Every callback below is a thin `lib.callback.register` wrapper around
    -- the EXACT SAME Query* local function (therefore the EXACT SAME
    -- K9Store.* accessor, the EXACT SAME hardcoded SQL text) its command
    -- counterpart already calls above -- see this file's header "SQL
    -- SAFETY" section, entirely unchanged by this addition. THIS FILE
    -- STILL COMPUTES NOTHING NEW: a callback returns the raw row table a
    -- Query* function already produced, nothing more.
    --
    -- AUTHORIZATION IS IDENTICAL TO THE COMMAND IT MIRRORS -- not a
    -- separate, easier-to-reach check. Every callback below calls the SAME
    -- `IsAuthorizedAdmin(source)` every RegisterCommand handler above
    -- already calls, re-deriving the caller's job/grade/permission state
    -- from their OWN server-held `source` on every single invocation --
    -- never a client-sent flag, never a value cached from an earlier call.
    -- These callbacks are registered inside this SAME onResourceStart
    -- block, behind the SAME `Config.Features.AdminAuditCommands` gate the
    -- five commands above already require: if that flag is not `true`,
    -- NONE of these callbacks are ever registered either, not merely a
    -- runtime no-op that still replies once invoked -- a callback reachable
    -- while the feature is off would be a strictly EASIER path into this
    -- data than the commands it is supposed to mirror, exactly the
    -- privilege-escalation shape this task's own brief warns against by
    -- name.
    --
    -- RATE LIMITING IS THE SAME SHARED BUDGET, NOT A SEPARATE ONE -- every
    -- callback below calls the SAME `AuditCooldown` instance, keyed by the
    -- SAME caller `source`, as every command above. A caller cannot double
    -- their effective query rate against k9_search_log by alternating
    -- between the chat command and the tablet callback; both draw down the
    -- one cooldown bucket per source.
    --
    -- EVERY RESULT SET IS BOUNDED THE SAME WAY -- every `limit` argument
    -- below is passed through the SAME `ClampLimit(rawArg, defaultValue,
    -- HARD_MAX_RESULTS)` the command path already uses before it can ever
    -- reach a Query* function, never a client-supplied value passed through
    -- unclamped. See ClampLimit's own doc comment above, "NaN HARDENING
    -- (this pass)", for the ONE new hostile-input case this callback
    -- surface specifically opens (a raw NaN Lua number, only reachable
    -- because `limit` here arrives as a number over the wire rather than a
    -- string from chat) and why it is closed inside ClampLimit itself, once,
    -- rather than re-derived per call site here.
    --
    -- RETURN SHAPE mirrors server/tablet.lua's own established
    -- `{ ok, error, message, ... }` convention (see e.g. that file's
    -- tabletRequestPersonSummary) rather than inventing a new one:
    --   success: { ok = true, rows = <table>, label = <string>, cap = <number>, limit = <number>?, truncated = <boolean>? }
    --     `rows` is the RAW array K9Store.* already returns for that query
    --     (see each Query* function's own doc comment a few hundred lines
    --     above for the exact column list) -- the entire point of this
    --     task, never a formatted string. `label` is the SAME human-
    --     readable description (via the SAME `locale(...)` call) the
    --     command path already builds for its own toast/console header --
    --     included purely as a display convenience, never itself a source
    --     of additional data. `cap` (THIS PASS) is `HARD_MAX_RESULTS`
    --     verbatim, the real ceiling this file enforces regardless of what
    --     any caller asks for -- present on EVERY success response,
    --     including tabletAuditXp's (which has no `limit` concept at all --
    --     see that callback's own comment -- but still carries `cap` for a
    --     uniform response shape across all five). `limit` and `truncated`
    --     (THIS PASS) are present on the four callbacks that take a `limit`
    --     argument (tabletAuditCert/Partner/Search/Dept): `limit` is the
    --     EXACT, already-`ClampLimit`-clamped value this call actually used
    --     (always <= `cap`), and `truncated` is `true` only when the
    --     caller's own request exceeded `cap` and was cut down to it --
    --     see `ClampLimit`'s own doc comment above for the exact contract
    --     both values come from, unmodified.
    --   failure: { ok = false, error = 'not_authorized' | 'rate_limited' | 'invalid_args', message = string? }
    --     `message` is only ever populated on `not_authorized` (the SAME
    --     `locale('admin.not_authorized')` text NotifyPlayer already sends
    --     for a denied command), matching server/tablet.lua's own
    --     documented "message stays optional, absence is a clean fallback"
    --     contract for its other two error codes. NEVER `cap`/`limit`/
    --     `truncated` here -- every failure branch in every callback below
    --     returns before HARD_MAX_RESULTS is ever attached to anything, so
    --     an unauthorized/rate-limited/malformed caller cannot use this
    --     pass's new fields to learn the configured cap without first
    --     passing IsAuthorizedAdmin.
    -- A callback NEVER exposes a wider column set than its command
    -- counterpart already prints -- e.g. tabletAuditDept's rows are the
    -- SAME `citizenid, granted_by, granted_at` triple `/k9audit dept`'s own
    -- "DISPLAY BOUNDARY" header section documents, nothing wider.
    --
    -- AUDIT-OF-THE-AUDIT still applies unchanged -- every callback
    -- invocation (allowed, denied, rate-limited, or malformed) is logged
    -- via the SAME `LogAuditInvocation` the commands use, under a DISTINCT
    -- `tabletAuditX` label (rather than `k9auditx`) so an operator reading
    -- the console log can tell which path -- console/chat command vs.
    -- tablet callback -- a given invocation came through.
    --
    -- NUI/CLIENT WIRING -- STATUS CORRECTED (this pass): this paragraph used
    -- to say "no `client/tablet.lua` change and no NUI callback are part of
    -- this pass" and that these five `lib.callback.register` names were only
    -- a CONTRACT a follow-up tablet screen would build against, not built
    -- here. That follow-up has SINCE landed: client/tablet.lua's own
    -- tablet:audit* bridges (its own "K9 AUDIT TRAIL VIEWER" section) call
    -- all five of these directly, and html/tablet.js's Audit Trail tab is
    -- the real, live consumer of the `{ ok, rows, label, cap, limit,
    -- truncated, error, message }` shape below (`cap`/`limit`/`truncated`
    -- added THIS pass -- see this file's header CALLBACK SURFACE section
    -- for why). Left here, corrected rather than deleted, so the ORIGINAL
    -- "not built here" framing doesn't keep misleading whoever reads this
    -- block next.
    -- ======================================================================

    --- 'qbx_k9unit:server:tabletAuditCert' -- mirrors '/k9audit cert'. See
    --- QueryCertificationHistory above for the exact row shape returned.
    --- @param source number
    --- @param citizenid string?
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, cap: number?, limit: number?, truncated: boolean?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditCert', function(source, citizenid, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditCert', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditCert', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'tabletAuditCert', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryCertificationHistory(citizenid, clampedLimit)
        local label = locale('admin.cert_history_label', AuditDisplayLabel(citizenid))

        LogAuditInvocation(source, 'tabletAuditCert', citizenid, 'ok')
        -- cap/limit/truncated (this pass): see this file's header CALLBACK
        -- SURFACE section and the CALLBACK SURFACE comment block above for
        -- the full contract. Computed and attached ONLY after
        -- IsAuthorizedAdmin has already returned true above -- none of the
        -- three refusal branches above ever reach this line.
        return { ok = true, rows = rows, label = label, cap = HARD_MAX_RESULTS, limit = clampedLimit, truncated = wasTruncated }
    end)

    --- 'qbx_k9unit:server:tabletAuditPartner' -- mirrors '/k9audit partner'.
    --- See QueryPartnershipHistory above for the exact row shape returned
    --- (already merged across both roles and sorted/truncated by
    --- MergeSortedByIdDesc).
    --- @param source number
    --- @param citizenid string?
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, cap: number?, limit: number?, truncated: boolean?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditPartner', function(source, citizenid, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditPartner', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditPartner', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'tabletAuditPartner', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.Partnerships, HARD_MAX_RESULTS)
        local rows = QueryPartnershipHistory(citizenid, clampedLimit)
        local label = locale('admin.partnership_history_label', AuditDisplayLabel(citizenid))

        LogAuditInvocation(source, 'tabletAuditPartner', citizenid, 'ok')
        -- cap/limit/truncated: see tabletAuditCert above for the full contract.
        return { ok = true, rows = rows, label = label, cap = HARD_MAX_RESULTS, limit = clampedLimit, truncated = wasTruncated }
    end)

    --- 'qbx_k9unit:server:tabletAuditSearch' -- mirrors '/k9audit search'.
    --- `mode` is checked against the SAME VALID_SEARCH_LOG_MODES whitelist
    --- BEFORE `value` is even inspected -- same "an unauthorized/malformed
    --- caller learns nothing about argument validity, not even whether
    --- their chosen mode string was recognized" posture this file's own
    --- '/k9audit search' command comment already documents. See
    --- QuerySearchLogByOfficer/ByPlate/ByPerson/Recent above for the exact
    --- row shape returned (identical across all four modes).
    --- @param source number
    --- @param mode string? -- 'officer' | 'plate' | 'person' | 'recent'
    --- @param value string? -- citizenid (officer/person) or plate (plate); ignored for 'recent'
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, cap: number?, limit: number?, truncated: boolean?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditSearch', function(source, mode, value, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not VALID_SEARCH_LOG_MODES[mode] then
            LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        -- `effectiveLimit`/`wasTruncated` are declared alongside `rows`/
        -- `label` (rather than as a `local` inside each branch, the shape
        -- this file had before this pass) specifically so the cap/limit/
        -- truncated response fields below can read whichever branch's
        -- ClampLimit call actually ran, exactly the same "declare above,
        -- assign inside each branch" shape `rows`/`label` already used.
        local rows, label, effectiveLimit, wasTruncated

        if mode == 'officer' or mode == 'person' then
            if not IsValidCitizenId(value) then
                LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'invalid_args')
                return { ok = false, error = 'invalid_args' }
            end
            effectiveLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = (mode == 'officer') and QuerySearchLogByOfficer(value, effectiveLimit) or QuerySearchLogByPerson(value, effectiveLimit)
            label = locale('admin.search_log_label_by_value', mode, AuditDisplayLabel(value))
        elseif mode == 'plate' then
            local plate = NormalizePlateArg(value)
            if not plate then
                LogAuditInvocation(source, 'tabletAuditSearch', 'n/a', 'invalid_args')
                return { ok = false, error = 'invalid_args' }
            end
            effectiveLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogByPlate(plate, effectiveLimit)
            label = locale('admin.search_log_label_plate', plate)
        else -- 'recent'
            effectiveLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.SearchLog, HARD_MAX_RESULTS)
            rows = QuerySearchLogRecent(effectiveLimit)
            label = locale('admin.search_log_label_recent')
        end

        LogAuditInvocation(source, 'tabletAuditSearch', label, 'ok')
        -- cap/limit/truncated: see tabletAuditCert above for the full contract.
        return { ok = true, rows = rows, label = label, cap = HARD_MAX_RESULTS, limit = effectiveLimit, truncated = wasTruncated }
    end)

    --- 'qbx_k9unit:server:tabletAuditXp' -- mirrors '/k9audit xp'. No
    --- `limit` argument -- `citizenid` is k9_progression's own PRIMARY KEY
    --- (see QueryProgressionSnapshot's own doc comment above), so `rows` is
    --- always an array of 0 or 1 elements regardless of what any caller
    --- supplies.
    --- @param source number
    --- @param citizenid string?
    --- @return table { ok: boolean, rows: table?, label: string?, cap: number?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditXp', function(source, citizenid)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditXp', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditXp', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidCitizenId(citizenid) then
            LogAuditInvocation(source, 'tabletAuditXp', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local rows = QueryProgressionSnapshot(citizenid)
        local label = locale('admin.xp_snapshot_label', AuditDisplayLabel(citizenid))

        LogAuditInvocation(source, 'tabletAuditXp', citizenid, 'ok')
        -- `cap` only, for a UNIFORM AuditResult shape across all five
        -- callbacks -- see tabletAuditCert above for the full cap/limit/
        -- truncated contract. This endpoint takes NO `limit` argument at all
        -- (citizenid is k9_progression's own PRIMARY KEY -- see
        -- QueryProgressionSnapshot's own doc comment above), so `limit`/
        -- `truncated` are deliberately never included here: there is
        -- nothing to clamp and nothing that could ever be truncated.
        return { ok = true, rows = rows, label = label, cap = HARD_MAX_RESULTS }
    end)

    --- 'qbx_k9unit:server:tabletAuditDept' -- mirrors '/k9audit dept'. See
    --- QueryDepartmentRoster above for the exact row shape returned
    --- (active roster only, same three columns idx_job_active's own doc
    --- comment names -- nothing wider).
    --- @param source number
    --- @param job string? -- must be a configured Config.Departments key
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, cap: number?, limit: number?, truncated: boolean?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditDept', function(source, job, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditDept', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditDept', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        if not IsValidDepartment(job) then
            LogAuditInvocation(source, 'tabletAuditDept', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.Certifications, HARD_MAX_RESULTS)
        local rows = QueryDepartmentRoster(job, clampedLimit)
        local label = locale('admin.dept_roster_label', job)

        LogAuditInvocation(source, 'tabletAuditDept', job, 'ok')
        -- cap/limit/truncated: see tabletAuditCert above for the full contract.
        return { ok = true, rows = rows, label = label, cap = HARD_MAX_RESULTS, limit = clampedLimit, truncated = wasTruncated }
    end)

    -- ==================================================================
    -- GAP 2 CLOSURE -- "eight audit tables are write-only" (owner-directed
    -- "full control ... accountability" pass). server/datastore.lua has
    -- eight `*Audit_Append`/`*Audit_Insert` writers backing every catalog
    -- edit a high-command officer makes from the tablet (certification
    -- tiers, permission keys, XP tiers, equipment shop items, equipment
    -- shop locations, per-K9 individual overrides, runtime feature/tunable
    -- overrides, tablet theme) -- and, until this pass, NOT ONE had a read
    -- accessor anywhere in this resource. Every one of those edits was
    -- logged perfectly and was invisible forever. This is the read side.
    --
    -- ONE GENERIC CALLBACK, PARAMETERIZED BY CATALOG NAME -- NOT eight
    -- near-identical ones (this task's own explicit instruction: eight
    -- copies is exactly the kind of drift this resource keeps finding and
    -- fixing reactively elsewhere, e.g. server/permissions.lua's own
    -- IsDuplicateKeyError doc comment on "each file keeps its own tiny copy"
    -- being the RIGHT call only for a genuinely small, self-contained
    -- check -- eight full authorization+cooldown+query+shape blocks is not
    -- that).
    --
    -- CATALOG_AUDIT_SOURCES below is the ENTIRE trust boundary for this
    -- surface, stated once: `catalogName` (a client-supplied string, over
    -- the wire, therefore adversarial) is looked up in this HARDCODED Lua
    -- table literal and is NEVER, itself, used to build a table name, a
    -- column name, or any other piece of SQL text -- not concatenated, not
    -- formatted into a query string, not passed to K9Store as a table-name
    -- argument. Every value in this table is a closed-over Lua FUNCTION
    -- REFERENCE this file itself names at load time (one of the eight real
    -- K9Store.*_GetRecent accessors below, each of which has its own
    -- hardcoded `FROM k9_whatever_audit` SQL text with zero caller-supplied
    -- interpolation) plus a locale key for the display label -- a caller
    -- can therefore never reach any table this map does not explicitly
    -- name here, no matter what string they send, in any encoding, under
    -- any validation bypass on their own client.
    -- ==================================================================
    -- `hasCitizenidColumn` (this pass, DISPLAY NAME RESOLUTION) -- every one
    -- of these eight row shapes carries a `changed_by` citizenid column
    -- (who made this catalog edit); exactly ONE, k9Profiles
    -- (IndividualOverrideAudit_GetRecent), ALSO carries a `citizenid` column
    -- naming the K9/handler the override targets. Flagged here rather than
    -- hardcoded inside EnrichChangedByRows below, so that helper stays a
    -- single generic function for all eight instead of a k9Profiles-specific
    -- branch living inside it.
    local CATALOG_AUDIT_SOURCES = {
        certTiers        = { accessor = K9Store.TierAudit_GetRecent,               labelKey = 'admin.catalog_audit_label_cert_tiers' },
        permissionKeys   = { accessor = K9Store.PermKeyAudit_GetRecent,            labelKey = 'admin.catalog_audit_label_permission_keys' },
        xpTiers          = { accessor = K9Store.XPTierAudit_GetRecent,             labelKey = 'admin.catalog_audit_label_xp_tiers' },
        shopItems        = { accessor = K9Store.ShopItemAudit_GetRecent,           labelKey = 'admin.catalog_audit_label_shop_items' },
        shopLocations    = { accessor = K9Store.ShopLocationAudit_GetRecent,       labelKey = 'admin.catalog_audit_label_shop_locations' },
        k9Profiles       = { accessor = K9Store.IndividualOverrideAudit_GetRecent, labelKey = 'admin.catalog_audit_label_k9_profiles', hasCitizenidColumn = true },
        runtimeOverrides = { accessor = K9Store.OverrideAudit_GetRecent,           labelKey = 'admin.catalog_audit_label_runtime_overrides' },
        tabletThemes     = { accessor = K9Store.ThemeAudit_GetRecent,              labelKey = 'admin.catalog_audit_label_tablet_themes' },
    }

    --- DISPLAY NAME RESOLUTION (this pass) -- generic enrichment for all
    --- eight CATALOG_AUDIT_SOURCES row shapes above, ONE helper rather than
    --- eight near-identical copies (mirrors CATALOG_AUDIT_SOURCES's own
    --- "one generic, parameterized callback, not eight" reasoning). Additive
    --- only: `changed_by`/`citizenid` themselves are unchanged.
    --- @param rows table
    --- @param alsoEnrichCitizenid boolean? -- true only for the k9Profiles source (IndividualOverrideAudit_GetRecent's own extra `citizenid` column)
    --- @return table -- the same rows
    local function EnrichChangedByRows(rows, alsoEnrichCitizenid)
        for _, row in ipairs(rows) do
            row.changed_by_name = (type(row.changed_by) == 'string' and row.changed_by ~= '') and ResolveAuditDisplayName(row.changed_by) or nil
            if alsoEnrichCitizenid then
                row.citizenid_name = (type(row.citizenid) == 'string' and row.citizenid ~= '') and ResolveAuditDisplayName(row.citizenid) or nil
            end
        end
        return rows
    end

    --- 'qbx_k9unit:server:tabletAuditCatalog' -- the GAP 2 read side. Same
    --- authorization, cooldown, and result-cap scaffolding as the five
    --- callbacks above (this task's own explicit "reuse, don't invent new
    --- gating" instruction) -- IsAuthorizedAdmin re-verified fresh on THIS
    --- call, the SAME shared AuditCooldown budget, the SAME HARD_MAX_RESULTS
    --- ceiling via ClampLimit. See this section's own header immediately
    --- above for the full CATALOG_AUDIT_SOURCES trust-boundary writeup.
    --- CONSUMED (a later pass than this callback itself): client/tablet.lua's
    --- own `tablet:auditCatalog` NUI callback bridges this one-to-one
    --- (VERBATIM forward, same as its five siblings), and html/tablet.js's
    --- Audit Trail tab grew a sixth "Catalog Changes" mode that calls it --
    --- this callback shipped ahead of both by one pass, tested but with no
    --- caller anywhere in the shipped client; it is not any more.
    --- @param source number
    --- @param catalogName string? -- MUST be an exact key of CATALOG_AUDIT_SOURCES above
    --- @param limit number?
    --- @return table { ok: boolean, rows: table?, label: string?, cap: number?, limit: number?, truncated: boolean?, error: string?, message: string? }
    lib.callback.register('qbx_k9unit:server:tabletAuditCatalog', function(source, catalogName, limit)
        if not IsAuthorizedAdmin(source) then
            LogAuditInvocation(source, 'tabletAuditCatalog', 'n/a', 'denied')
            return { ok = false, error = 'not_authorized', message = locale('admin.not_authorized') }
        end

        if not AuditCooldown.Consume(source, Config.AdminAudit.CommandCooldownMs) then
            LogAuditInvocation(source, 'tabletAuditCatalog', 'n/a', 'rate_limited')
            return { ok = false, error = 'rate_limited' }
        end

        local sourceDef = type(catalogName) == 'string' and CATALOG_AUDIT_SOURCES[catalogName]
        if not sourceDef then
            LogAuditInvocation(source, 'tabletAuditCatalog', 'n/a', 'invalid_args')
            return { ok = false, error = 'invalid_args' }
        end

        local clampedLimit, wasTruncated = ClampLimit(limit, Config.AdminAudit.MaxResults.CatalogAudit, HARD_MAX_RESULTS)
        local rows = EnrichChangedByRows(sourceDef.accessor(clampedLimit), sourceDef.hasCitizenidColumn)
        local label = locale(sourceDef.labelKey)

        LogAuditInvocation(source, 'tabletAuditCatalog', catalogName, 'ok')
        -- cap/limit/truncated: see tabletAuditCert above for the full contract.
        return { ok = true, rows = rows, label = label, cap = HARD_MAX_RESULTS, limit = clampedLimit, truncated = wasTruncated }
    end)

    print('[qbx_k9unit] admin.lua: audit command registered (/k9audit, with subcommands cert/partner/search/xp/dept); audit callbacks registered (tabletAuditCert, tabletAuditPartner, tabletAuditSearch, tabletAuditXp, tabletAuditDept, tabletAuditCatalog).')
end)
