--[[
    qbx_k9unit/server/tablet.lua

    Config.Features.CommandTablet. THE SERVER AGGREGATION LAYER for the K9
    Command Tablet -- html/tablet.js and client/tablet.lua
    are both complete and shipped; this file is what
    unblocks them by implementing the server side of their already-agreed
    NUI contract (see html/tablet.js's own header for the byte-exact
    payload shapes this file must match).

    ======================================================================
    ARCHITECTURE DECISION, STATED UP FRONT: this file registers SEVEN of the
    nine callbacks the tablet needs -- the genuinely CROSS-FILE aggregations
    that don't belong to any single owning subsystem:
      qbx_k9unit:server:tabletRequestMyRecord
      qbx_k9unit:server:tabletRequestRoster
      qbx_k9unit:server:tabletRequestOnlinePlayers -- the "pick a player id
        from a list" entry point into the Console/Person screens
        (owner-directed, 2026-08-26: "make the add permission section...
        where its a list when i choose a player id" -- a citizenid is not
        something an operator can see in game, but a server id is). SAME
        audience as tabletRequestRoster (CallerHasConsoleAccess) -- see
        that gate's own doc comment and this callback's own header for why
        this is a BROWSE capability, not the wider person-lookup one.
      qbx_k9unit:server:tabletResolveOnlinePlayer -- resolves ONE row from
        that list (a server id) to the citizenid it belonged to, freshly,
        at the moment of the click -- see its own header for the
        RECYCLED-SOURCE-ID guard this exists to close.
      qbx_k9unit:server:tabletRequestPersonSummary
      qbx_k9unit:server:tabletRequestPersonFeatures
      qbx_k9unit:server:tabletRequestMyPartnerships -- the Partners tab
        (owner-directed "both the k9 and handler
        should be able to pull up a list of their partners and levels").
        Joins K9Store.Partner_GetHistoryByK9/ByHandler (server/partnership.lua's
        own DB-authoritative history accessors, already used by
        server/admin.lua's high-command-only audit tool) with this file's
        own ResolveDisplayName -- exactly the "no single owning file can
        produce this alone" test the paragraph below already applies to
        the others.
    The other two are registered INSIDE the file that already owns the
    logic they wrap, mirroring server/permissions.lua's own established
    precedent (that file's "TABLET CALLBACKS" section registers
    tabletGrantPermission/tabletRevokePermission directly alongside
    GrantPermission/RevokePermission, rather than here):
      qbx_k9unit:server:tabletCertify  -- server/certifications/,
        GrantCertificationForTablet (see that function's own doc comment
        for the full "offline-grant asymmetry" writeup -- summarized
        below).
      qbx_k9unit:server:tabletGiveXp   -- server/highcommand.lua,
        GrantHighCommandXp / IsAuthorizedForXpGrant (factored out of
        '/k9givexp's own command handler so neither file duplicates the
        other's authorization/clamp/self-grant/cooldown/audit logic).
    Reasoning: a mutation that maps cleanly onto ONE file's existing
    write-path (grant/revoke/certify/givexp) belongs next to that write
    path, where its authorization checks already live and where a future
    change to that authorization is made exactly once. A READ that must
    join k9_permissions + k9_certifications + k9_progression together --
    something no single owning file can produce from its own table alone --
    belongs here. server/permissions.lua's own header names this precise
    split explicitly and defers the read side to "whichever file ends up
    owning that aggregation" -- this file is that answer.
    ======================================================================

    ======================================================================
    THE OFFLINE-GRANT ASYMMETRY -- see
    server/certifications/'s GrantCertificationForTablet for the full
    writeup; summarized here since it shaped this file's own design too.
    RevokeCertificationOffline already lets an officer revoke a
    disconnected citizenid's certification (DEVELOPER_REFERENCE.md §4.3 requires it).
    GrantCertification cannot get the same treatment: DEVELOPER_REFERENCE.md §4.2 item 5's
    model check reads a LIVE ped's model, and this resource's schema has NO
    persisted "this citizenid plays a K9 model" fact to substitute for a
    disconnected target. DECISION: no offline grant path was added.
    tabletCertify resolves the target to a currently-connected server id
    and, only if that succeeds, delegates to the EXACT SAME GrantCertification
    a live '/k9certify [server id]' would run -- one code path, the real
    model/proximity/eligibility checks intact. A disconnected target fails
    closed with 'target_must_be_online', an honest, distinguishable
    failure, never a weaker grant. tabletGiveXp is the opposite case:
    AwardXPDirect has no live-session precondition at all, so it IS fully
    offline-capable, and is built that way (citizenid-keyed, works for a
    disconnected target) -- these two "six callbacks" siblings deliberately
    resolve the identical-looking "online/offline" question in opposite
    directions, for a real, disclosed, security-driven reason each time.
    ======================================================================

    ======================================================================
    SECURITY RULE (client/tablet.lua's own words, repeated here because
    this is the file a modified client actually talks to): THE TABLET IS A
    VIEW. IT DECIDES NOTHING. Every one of the callbacks below
    re-resolves the CALLER's own identity from `source` (ox_lib's callback
    dispatch value, server-verified, never a client-supplied one) and
    re-derives every permission/certification/XP fact from this resource's
    own server-held state (k9_permissions, k9_certifications, the
    progression cache) -- never from a client-supplied citizenid, job, or
    boolean. A `targetCitizenId` argument selects WHOSE record to read; it
    is NEVER treated as an assertion about the CALLER's own identity or
    authority. tabletRequestOnlinePlayers/tabletResolveOnlinePlayer take a
    server id (`source`, an online player's connection slot) instead of a
    citizenid -- but the exact same rule applies: `source` selects WHOSE
    connection to read, resolved to a citizenid FRESH on the server, on
    every call, never trusted from an earlier response. tabletRequestRoster/
    tabletRequestOnlinePlayers/tabletRequestPersonSummary require the
    caller to hold real "console" access (an effective admin capability, or
    high command); tabletRequestPersonFeatures requires high command
    specifically -- both re-verified here on every call, never trusted from
    a client's own cached copy of `viewer.isHighCommand`.
    ======================================================================

    ======================================================================
    STATE RESOLUTION (myFeatures[].state / features[].state) -- config.lua's
    Config.FeatureControl documents this as a 4-step "first match wins"
    order for whether a feature is USABLE for a given person; html/tablet.js's
    own header extends it with one more step (an underlying-certification
    gate) for what the TABLET specifically should render:
      1. Config.Features.<key> is not `true`                    -> 'global_off'
      2. an explicit per-person BLOCK row ('block.<key>')       -> 'blocked'
      3. the caller/target lacks K9 access (HasK9Access)        -> 'not_certified'
      4. <key> is in RequireGrant and no 'feature.<key>' grant  -> 'requires_grant_missing'
      5. otherwise                                              -> 'available'
    Computed fresh on every call from k9_permissions rows this file reads
    itself (never cached, never trusted from a prior response) -- see
    ResolveFeatureState below. NOTE, DISCLOSED: config.lua's own base
    4-step order for Config.FeatureControl has no high-command bypass at
    step 3 ("<Name> is listed in RequireGrant -> ALLOW ONLY IF THEY HOLD A
    GRANT", no stated exception) -- unlike the SEPARATE Config.Permissions
    4-step order, which explicitly bypasses at step 2. This file follows
    that literal distinction: a high-command officer who wants to TRIGGER a
    RequireGrant-listed feature THEMSELVES still needs their own
    'feature.<key>' grant, same as anyone else. If that reading is wrong,
    it is a one-line change to ResolveFeatureState below, not a redesign.

    RESOLVED, PREVIOUSLY A REAL GAP:
    server/permissions.lua's IsValidPermissionKey originally only accepted
    an EXACT key already present in Config.Permissions (the four admin
    capabilities), with no case for the 'feature.<Name>'/'block.<Name>'
    namespace -- meaning tablet:grantFeature/revokeFeature/blockFeature/
    unblockFeature failed with 'invalid_permission' on every attempt. Now
    fixed there: IsValidPermissionKey accepts 'feature.<Name>'/'block.<Name>'
    when <Name> is validated against the real Config.Features table (never a
    free-form string). This file's OWN reads (QueryActivePermissionSet
    below) were never affected by that bug either way -- they read
    k9_permissions directly, bypassing the write-path validator, the same
    way server/permissions.lua's own ListActivePermissionsForCitizenId/
    ListPermissionRoster already do -- so 'blocked'/'requires_grant_missing'
    now reflect REAL, storable grant/block rows end to end, not merely "never
    blocked, never granted by construction" as before this fix landed. See
    the ROUND TRIP test in tests/tabletserver_spec.lua
    for proof of the full path: a grant made
    through tabletGrantPermission is visible in this file's own
    ResolveFeatureState output afterward.
    ======================================================================

    ======================================================================
    ROSTER QUERY -- PERFORMANCE. A real EXPLAIN pass (against
    live MySQL 5.7 and 8.0 containers, seeded with 12,000 k9_certifications
    rows across 3 departments) confirmed:
      SELECT citizenid, granted_by FROM k9_certifications
      WHERE job = ? AND active = 1 LIMIT <n>
    uses `idx_job_active` as a `ref` index seek (`type: ref`, `Extra: NULL`
    -- no filesort, no temporary table) on BOTH versions. The SAME query
    with `ORDER BY granted_at DESC` added -- server/admin.lua's own existing
    dept-roster query shape -- adds `Using filesort` on the exact same seed,
    which is almost certainly the concrete instance of the "existing admin
    query filesorting 8,572 rows to return 50" finding;
    NOT fixed here (server/admin.lua is out of scope for
    this file and this file does not touch it), but independently reconfirmed
    and deliberately NOT repeated below: this file's own per-department
    fetch has NO ORDER BY at all -- any deterministic ordering the roster
    wants is applied AFTER fetch, in Lua, over the already-bounded result.
    Bounded per Config.CommandTablet.maxRosterRows (clamped -- see
    ClampedMaxRosterRows: non-positive/nil/NaN/infinite falls back to the
    default, never "unlimited", this resource's standing footgun-avoidance
    convention), fetched per CONFIGURED DEPARTMENT (a small, fixed set --
    2-4 in every shipped config) rather than as one unindexed table scan,
    with a hard multiplier-plus-absolute ceiling (ROSTER_FETCH_MULTIPLIER /
    ROSTER_FETCH_ABSOLUTE_CAP below) so a misconfigured maxRosterRows can
    never blow the query up regardless. The free-text `query` substring
    match (name/citizenid/department, case-insensitive) is applied ENTIRELY
    IN LUA over this already-bounded candidate set, not pushed into a SQL
    LIKE -- a leading-wildcard LIKE cannot use a B-tree index anyway, and a
    citizenid's NAME is not a queryable SQL column in this schema at all
    (see NAME RESOLUTION below), so there is no meaningful SQL-side filter
    to push down beyond the already-applied `job = ? AND active = 1` seek.
    ======================================================================

    ======================================================================
    NAME RESOLUTION -- DISCLOSED GAP, NOW ANSWERED: an ONLINE citizenid's
    display name resolves via qbx_core's own PlayerData.charinfo
    (firstname/lastname), falling back to the GetPlayerName native (a
    real, VERIFIED server-callable native -- ext/native-decls/GetPlayerName.md
    returns HTTP 200, apiset: server) if charinfo is absent/malformed.

    For an OFFLINE citizenid, this question is now closed: confirmed
    directly against qbx_core's live server/player.lua that
    `exports.qbx_core:GetOfflinePlayer(citizenid)` IS a real export --
    returns a Player-shaped object (`.PlayerData`, `.Offline = true`) for a
    known citizenid, or nil if not found. `GetOfflinePlayerByCitizenId`
    does NOT exist as a separate export -- that half of the name floated in
    this file's original draft was never real; `GetOfflinePlayer` alone is
    the one and only offline accessor, already keyed by citizenid (no
    separate ByCitizenId variant needed).

    WIRED: ResolveDisplayName below now
    calls `exports.qbx_core:GetOfflinePlayer(citizenid)` for an offline
    target, behind a `pcall` (the export call itself, not just its result)
    so a qbx_core build without it -- or a citizenid it does not
    recognize -- degrades exactly as before: straight to the citizenid
    fallback, never an error. Only `PlayerData.charinfo` is consulted for
    the offline path (there is no offline `source`/native-name to fall
    back to, unlike the online branch above it), so the offline result is
    either a real name or the citizenid -- never a half-resolved guess.
    ======================================================================

    ======================================================================
    myFeatures / features KEY LIST -- DYNAMIC, NOT HARDCODED (owner's own
    instruction, verbatim: "Do not hardcode a feature list in the
    tablet UI... render the roster from whatever Config.FeatureControl.RequireGrant
    and Config.Features actually contain at runtime, so a feature added
    after you finish appears without a UI change"). Feature files
    (findalert/pursuitsprint) plus an equipment shop or a leaderboard can
    each add their own Config.Features entry and, where relevant,
    its own Config.FeatureControl.RequireGrant entry at any time -- a list this file
    captured once at load/write time would already be stale the moment a
    new one lands. ListMyFeaturesKeys below therefore iterates
    `pairs(Config.Features)` FRESH on every call (Config is a shared table
    this file never copies), sorted for a stable, deterministic output
    order -- no per-file registry, no coordination needed when a new
    feature is added. `requiresGrant` is read the same way, from
    `Config.FeatureControl.RequireGrant[key]` at resolution time. This
    necessarily includes every OTHER Config.Features flag too (HighCommand,
    CommandTablet, RuntimeFeatureControl, ...), not just K9-ability ones --
    a deliberate breadth-over-curation tradeoff per the owner's own explicit
    instruction; each row's `state` is still computed correctly and
    honestly for whatever the key actually is (an administrative flag with
    no RequireGrant entry simply always resolves 'global_off'/'available',
    which is accurate, just not necessarily a row the UI chooses to
    surface with a trigger button -- that display-level filtering, if
    wanted, is a UI-scope decision, not a correctness concern for this
    file's own resolution logic).
    ======================================================================

    ======================================================================
    K9 ROLE ASSIGN / DE-ASSIGN / REVERT-TO-HUMAN -- the owner's expanded,
    mid-pass ask ("assign and de-assign the K9 role... remove the K9 ped
    and revert that player to a human... I want high command to have
    pretty much absolute control"). THREE distinct actions, each mapped to
    the narrowest EXISTING (or newly-added, clearly-scoped) primitive
    rather than a new parallel mechanism:
      ASSIGN -- qbx_k9unit:server:tabletAssignK9Role (targetCitizenId,
        modelName) -> {ok, error?, message?}, registered below. Thin
        wrapper over server/appearance.lua's ApplyK9PedRole(granterSrc,
        targetCitizenid, modelName) -- ALREADY high-command-gated
        internally (it delegates to GrantPermission's own IsHighCommand
        check), ALREADY works for any Config.Peds entry (requirement:
        "everything work with any ped" -- ApplyK9PedRole validates against
        the operator's OWN Config.Peds list, which can include a custom/
        non-dog streamed model, never a hardcoded name). This file adds NO
        second authorization check and NO second appearance-mutation path
        -- see this function's own doc comment.
      DE-ASSIGN -- NO NEW CALLBACK. Mapped onto the tablet's EXISTING
        tablet:revokePermission {targetCitizenId, permission:'k9.access'}
        action (server/permissions.lua's already-registered
        tabletRevokePermission), since 'k9.access' is precisely the
        credential ApplyK9PedRole/HasK9Role treat as "holds the role."
        Revoking it already triggers server/permissions.lua's own
        RevokePermission -> MaybeRevertK9Appearance reconciliation
        automatically once the citizenid no longer qualifies through ANY
        other path (see appearance.lua's own FILE-TO-FILE CONTRACT). No
        server/tablet.lua code needed for this one at all -- reported here
        so it isn't mistaken for a gap.
      REVERT-TO-HUMAN (unconditional) -- qbx_k9unit:server:tabletRevertK9Ped
        (targetCitizenId) -> {ok, error?, message?}, registered below.
        THE NO-UNBOUNDED-TRAP REQUIREMENT, STATED EXPLICITLY BY THE OWNER:
        this action must NEVER be gated on the target still holding K9
        access, still being certified, or still passing any feature check
        -- MaybeRevertK9Appearance is therefore NOT reused here (it
        deliberately refuses to revert a citizenid who still qualifies
        through k9.access or an active certification -- correct for ITS
        OWN auto-revert-on-credential-loss call sites, wrong for a direct,
        forceful "make them human right now" tablet button). Calls a NEW
        primitive, ForceRevertK9Appearance(granterSrc, targetCitizenid),
        added to server/appearance.lua rather
        than hand-rolled here -- "coordinate with it, do not build a second
        revert path" was the owner's own explicit instruction. CONFIRMED
        (direct read of
        server/appearance.lua): ForceRevertK9Appearance HAS NOW LANDED --
        it re-verifies IsHighCommand(granterSrc) itself (never trusting
        this wrapper), consumes its own AppearanceActionCooldown (shared
        with tabletAssignK9Role/ApplyK9PedRole, keyed by granterSrc), is
        credential-blind on the TARGET by design (the whole point of a
        termination path -- see that function's own doc comment), and
        checks every one of its own DB writes' return values before ever
        reporting success. Still guarded here with
        `type(ForceRevertK9Appearance) == 'function'`, this resource's
        standard soft-dependency convention -- kept even though the
        function is now confirmed present, exactly like every other
        cross-file call in this file, so a future removal of
        server/appearance.lua degrades to a clear 'not_available' rather
        than an uncaught error.
    ======================================================================

    ======================================================================
    "ANY PED" / GATE ON ROLE, NEVER MODEL -- every check in this file
    (HasK9Access for feature-state resolution, IsHighCommand/HasPermission
    for authorization) is already model-independent by construction --
    grepped this file end to end to confirm NOTHING here reads
    GetEntityModel/IsConfiguredK9Model/an entity's ped model at all. The
    live bug (client/movement.lua:822's certify
    predicate demanding a K9 model client-side while the server-side
    GrantCertification does not) lives entirely in a different
    file and is NOT reproduced here: tabletCertify (server/certifications/)
    and tabletAssignK9Role/tabletRevertK9Ped below all gate purely on
    CALLER authorization (IsHighCommand / IsEligibleCertifier) and
    TARGET identity (citizenid, online-resolution where needed) -- never on
    what the target currently looks like.
    ======================================================================

    ======================================================================
    FILE-TO-FILE CONTRACT -- reads only except the two K9-role actions below:
      HasPermission, IsHighCommand, HasK9Access, GetXP, GetXPTier -- every
      one guarded by `type(fn) == 'function'` (this resource's established
      soft-dependency convention: this file degrades to "nobody qualifies
      for anything" / "no XP data" rather than erroring if any of those
      four owning files is ever removed, exactly like every other consumer
      of these four).
      Runs its own direct, parameterized SELECTs against k9_permissions and
      k9_certifications for the read shapes no existing accessor already
      covers (a citizenid's full active-permission SET, a citizenid's
      per-department certification row, and the bounded per-department
      roster scan) -- the same "read-only aggregation reaches into another
      subsystem's own table directly" pattern server/admin.lua's own audit
      commands and server/permissions.lua's own ListActivePermissionsForCitizenId/
      ListPermissionRoster already establish for an identical need.
    ======================================================================

    LOCALE KEYS THIS FILE NEEDS -- real keys, NOT invented inline.
    Both have LANDED in locales/en.json: `tablet.roster_truncated_notice`
    (worded as "Showing the first %d entries -- narrow your search to see
    the rest.", wired into tabletRequestRoster's `truncatedMessage` below)
    and `tablet.console_not_authorized` ("You don't have access to the
    Command Console.", wired into every CallerHasConsoleAccess refusal
    below). Both are resolved via this file's own SafeLocale() helper, not
    a bare locale() call -- each is an OPTIONAL field alongside an `error`
    code the tablet can already render generically, so a future rename or
    removal of either key degrades to that same generic behaviour instead
    of throwing out of the callback.

    FXMANIFEST.LUA PLACEMENT REQUESTED (server_scripts, not edited here):
    insert `'server/tablet.lua',` immediately after `'server/progression.lua',`
    and before `'server/combat.lua',` -- satisfies every soft load-order
    preference this file has (after cooldowns/notify/highcommand/permissions/
    certifications/progression, all five of which it may call at runtime),
    though nothing here is strictly load-order-dependent: every cross-file
    call is behind its own `type(fn) == 'function'` guard, matching this
    resource's "runtime existence guard, not a load-order assumption"
    convention.
]]

if not (Config.Features and Config.Features.CommandTablet == true) then return end

-- ======================================================================
-- CONSTANTS
-- ======================================================================

local DEFAULT_MAX_ROSTER_ROWS = 100 -- mirrors config.lua's own Config.CommandTablet.maxRosterRows default
local ROSTER_FETCH_MULTIPLIER = 5   -- headroom so the in-Lua text filter still has real candidates to search among
local ROSTER_FETCH_ABSOLUTE_CAP = 1000 -- hard ceiling per department, regardless of a misconfigured maxRosterRows
local MAX_ROSTER_QUERY_LENGTH = 100  -- defensive bound on the free-text search box, matching this resource's
                                      -- established "plain sanity/DoS-lite bound" convention (server/permissions.lua's
                                      -- own IsValidCitizenId is the same idea applied to a citizenid)
local MAX_CITIZENID_LENGTH = 50      -- VARCHAR(50), matching every citizenid column in this resource's schema

-- ======================================================================
-- RATE LIMITING -- the read/aggregation callbacks below (tabletRequestMyRecord/
-- Roster/OnlinePlayers/PersonSummary/PersonFeatures, plus
-- tabletResolveOnlinePlayer) had NO cooldown at all, unlike every
-- other client-triggered, DB-touching read this resource exposes
-- (server/admin.lua's own AuditCooldown covers its five read-only audit
-- callbacks/commands the exact same way; server/tracking.lua/server/search.lua
-- cooldown their own query paths too). BuildCertificationsArray alone issues
-- one extra query pair PER ACTIVELY-HELD DEPARTMENT, and tabletRequestRoster
-- issues one query PER CONFIGURED DEPARTMENT, every single call -- a caller
-- who can already reach one of these (any certified handler for
-- tabletRequestMyRecord; console-access/high-command for the others)
-- could otherwise fire an unbounded number of these per second with nothing
-- server-side to slow them down. ONE SHARED instance across all of them,
-- mirroring server/admin.lua's AuditCooldown / server/runtimecontrol.lua's
-- RuntimeControlActionCooldown "one cooldown per related-action group" shape
-- -- these are the tablet's own related "read a record" group. This is
-- an anti-hammering floor, not an abuse gate: every caller reaching the
-- Consume call below already PASSED this callback's own authorization check
-- (see each callback's own placement of this call, always AFTER
-- authorization, never before -- a denied caller never spends this shared
-- budget). html/tablet.js's own SEARCH_DEBOUNCE_MS already spaces
-- keystroke-triggered roster requests out client-side well past this floor;
-- this is the server-side backstop for a client that does not (deliberately
-- or otherwise), matching this resource's "never trust a client-side-only
-- limit" convention.
-- ======================================================================
local TABLET_READ_COOLDOWN_MS = 500
local TabletReadCooldown = NewCooldown(TABLET_READ_COOLDOWN_MS)
TabletReadCooldown.RegisterPlayerDropped()

-- FORCE END PARTNERSHIP's own action cooldown, keyed by the acting officer.
-- Every other high-command mutation in this resource owns one of these --
-- AppearanceActionCooldown, CertifyActionCooldown, PermissionActionCooldown,
-- all at 1500ms -- and this was the one destructive admin action without
-- it, while its two READ siblings in this same file were throttled.
--
-- It lives HERE, in the tablet handler, and NOT inside
-- ForceBreakPartnershipForCitizenId: that primitive is also called by
-- automatic teardowns (a revoked certification, a department change), and
-- those must never be refused for arriving close together.
local PARTNERSHIP_FORCE_END_COOLDOWN_MS = 1500
local PartnershipForceEndCooldown = NewCooldown(PARTNERSHIP_FORCE_END_COOLDOWN_MS)
PartnershipForceEndCooldown.RegisterPlayerDropped()

--- DYNAMIC feature key list -- see this file's header "myFeatures /
--- features KEY LIST -- DYNAMIC, NOT HARDCODED" for the full reasoning.
--- Reads `Config.Features` FRESH on every call (never cached at file-load
--- time, and never a Lua-literal list of names) so a feature landed by any
--- other agent after this file was written appears automatically, with no
--- edit here. Sorted for a stable, deterministic output order only --
--- `pairs` iteration order over a plain Lua table is not guaranteed.
--- @return table -- sorted array of Config.Features key strings
local function ListFeatureKeys()
    local keys = {}
    if type(Config.Features) == 'table' then
        for key in pairs(Config.Features) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
    end
    return keys
end

-- ======================================================================
-- SMALL, GENERAL HELPERS
-- ======================================================================

--- Fail-closed K9Store-accessor wrapper -- pcall around a K9Store.* function
--- (a failed read returns zero rows/false, never a raw Lua error out of a
--- lib.callback handler). server/datastore.lua's own K9Store.* functions
--- that mirror a RAW oxmysql method (MySQL.scalar/single/query.await) do so
--- un-pcalled in their DB-mode branch, by design (see that file's header
--- "CONTRACT DISCIPLINE") -- this file still needs "never throws" for its
--- own callback handlers regardless of which backend K9Store is running
--- against, so the pcall stays here, at every one of this file's own
--- K9Store call sites, even the ones (like Cert_GetActiveJobsForCitizen/
--- Cert_GetActiveRosterByJobUnordered below) that already never throw on
--- their own -- consistent double-wrapping over a call-site-by-call-site
--- judgment call about which K9Store functions "need" it.
--- @param fn function -- a K9Store.* accessor
--- @return any result -- rowsOrErr on success, or the caller's own documented
--- fallback (nil/false/{}) on failure -- see each call site.
--- @return boolean ok -- SECOND return, added this pass (see
--- QueryActivePermissionSet's own "DISPLAY-GAP, FAIL-OPEN" doc comment
--- below for why this exists): `true` only when `fn` actually ran to
--- completion without throwing. Every PRE-EXISTING call site in this file
--- still works unchanged -- Lua truncates extra return values in every
--- context those call sites use (`SafeStoreCall(...) or {}`, a bare
--- assignment to one local, a direct `~= nil` comparison) -- so this is
--- additive, not a signature break. Only QueryActivePermissionSet reads
--- this second value; every other call site is free to keep ignoring it.
local function SafeStoreCall(fn, ...)
    local ok, resultOrErr = pcall(fn, ...)
    if not ok then
        print(('[qbx_k9unit] tablet.lua K9Store call failed: %s'):format(tostring(resultOrErr)))
        return nil, false
    end
    return resultOrErr, true
end

--- Single-key pcall-wrapped locale() resolution, mirroring client/tablet.lua's
--- own SafeLocale() helper -- both `console_not_authorized` and
--- `roster_truncated_notice` below are OPTIONAL fields on their own response
--- (an `error` code the tablet can already render generically, or a plain
--- roster array with no truncation note), never the sole carrier of a
--- required value -- so a missing/renamed locale key must degrade to that
--- same generic behaviour instead of throwing out of a callback and
--- refusing an otherwise-successful request.
--- @param fullKey string @param ... any -- forwarded to locale() for %s/%d substitution
--- @return string?
local function SafeLocale(fullKey, ...)
    local ok, value = pcall(locale, fullKey, ...)
    if ok and type(value) == 'string' and value ~= '' then return value end
    return nil
end

--- DB-authoritative: does `citizenid` hold an active row in ANY configured
--- department? Used ONLY as the offline fallback inside
--- ResolveTargetHasK9Access below (an online target's access is read from
--- the real, live HasK9Access(source) instead -- this is strictly a
--- substitute for when no live source exists). Migrated onto
--- K9Store.Cert_GetActiveIdAnyJob (identical SQL/index, now behind
--- the DatabaseEnabled() switch -- Config.Database.enabled = false answers
--- this from K9Store's own in-memory certification rows instead of a live
--- MySQL connection).
--- @param citizenid string
--- @return boolean
local function QueryHasAnyActiveCertification(citizenid)
    return SafeStoreCall(K9Store.Cert_GetActiveIdAnyJob, citizenid) ~= nil
end

--- Every ACTIVE k9_permissions row for `citizenid`, as a set (presence of a
--- key means "currently holds this permission string"). Covers all three
--- shapes this file needs to check (the four admin capabilities,
--- 'feature.<Name>', 'block.<Name>') in ONE query -- reads the table
--- directly rather than going through server/permissions.lua's HasPermission,
--- which is scoped to ONLINE citizenids only (see that file's own "CACHING"
--- header section) -- this file needs the SAME read to work for an offline
--- target too (tabletRequestPersonSummary/tabletRequestPersonFeatures), so a
--- direct, DB-authoritative read is correct here regardless of
--- IsValidPermissionKey's own now-fixed namespace acceptance (see this
--- file's header "RESOLVED, PREVIOUSLY A REAL GAP"). Migrated onto
--- K9Store.Perm_GetActiveForCitizen (identical SQL, same row
--- shape `{ permission = ... }`) -- now works correctly under
--- Config.Database.enabled = false too.
--- @param citizenid string
--- @return table<string, boolean> set
--- @return boolean readOk -- SECOND return (DISPLAY-GAP, FAIL-OPEN fix,
--- this pass) -- see BlockNamespaceUnreliable's own doc comment
--- immediately below for the full "why" and how this is consumed. `true`
--- only when SafeStoreCall's own underlying K9Store call actually
--- succeeded (no pcall failure) -- NEVER inferred from `set` being empty,
--- which is exactly the conflation this fix closes: an empty `set` is
--- ambiguous on its own (genuinely holds nothing, OR the read failed and
--- `or {}` below papered over it), so this second value is the one
--- deliberate, explicit signal that disambiguates the two, and every
--- caller that cares about the block namespace must consult it rather
--- than re-deriving "did this actually work" from `set` a second way.
local function QueryActivePermissionSet(citizenid)
    local rows, readOk = SafeStoreCall(K9Store.Perm_GetActiveForCitizen, citizenid)
    local set = {}
    for _, row in ipairs(rows or {}) do
        set[row.permission] = true
    end
    return set, readOk
end

--- THE BUG THIS CLOSES: ResolveFeatureState below used to derive `blocked`
--- purely from `activePermSet['block.' .. key] == true` -- true precision
--- when the read behind `activePermSet` genuinely succeeded, but WRONG the
--- moment it did not, because QueryActivePermissionSet's own `or {}`
--- (before this pass) made "the query threw" and "this citizenid
--- genuinely holds zero rows" produce the IDENTICAL empty table. An empty
--- table can never look blocked, so a DB degradation (memory-mode,
--- a per-table fallback, a schema collision, or a plain transient query
--- error) made a real, active `block.<Name>` row silently stop applying
--- ON THE TABLET ONLY -- the exact "MEMORY-MODE BLOCK ASYMMETRY" this
--- resource's own server/permissions.lua HasPermission was hardened
--- against (see that function's own doc comment, immediately above its
--- `permissionKey:match('^block%.')` branch) -- never mirrored here until
--- now. Real enforcement was never affected (every consuming file calls
--- the hardened HasPermission directly, never this file's display-only
--- aggregation) -- this was a display bug, but the forbidden DIRECTION of
--- one: the tablet must never show `available` for something a real
--- HasPermission call would refuse.
---
--- THE FIX, deliberately reusing HasPermission's own two cases rather than
--- inventing a second notion of "did this read actually succeed":
---   1. MEMORY-MODE / SCHEMA COLLISION / PART-INSTALLED FALLBACK, for the
---      WHOLE session -- the exact same
---      `K9Store.IsDatabaseEnabled('k9_permissions')` call HasPermission's
---      own case 1 uses, unconditionally, regardless of whether THIS
---      particular read happened to return successfully (PermRows, the
---      memory-mode mirror, never throws -- it can report a clean, ok=true
---      empty read while still being the wrong store to trust a block's
---      absence from -- exactly HasPermission's own case-1 reasoning).
---   2. THIS SPECIFIC READ FAILED -- `readOk == false` from
---      QueryActivePermissionSet above. This file has no equivalent of
---      HasPermission's own warmed, per-citizenid PermissionCache/
---      PermissionCheckUnresolved (this is a live, uncached, DB-authoritative
---      read on every call, by design -- see QueryActivePermissionSet's own
---      header for why it must work for an offline target too) -- so there
---      is no separate "was this citizenid ever left unresolved" table to
---      consult here; the direct, honest analogue for an uncached read is
---      simply whether THIS call actually succeeded, which is precisely
---      the signal SafeStoreCall/QueryActivePermissionSet now surface.
--- Either case denies the ENTIRE (finite, named) list of block-gated
--- features to this citizenid for this one response, never just the keys
--- that happen to already have a block row cached somewhere -- matching
--- HasPermission's own "deny everything in the namespace rather than risk
--- handing back even one" posture.
--- @param readOk boolean -- QueryActivePermissionSet's own second return
--- @return boolean
local function BlockNamespaceUnreliable(readOk)
    -- CASE 0, MIRRORING HasPermission's OWN (server/permissions.lua --
    -- read that function's CASE 0 comment for the full writeup of the
    -- live production bug this closes). Deliberate memory-only mode
    -- (Config.Database.enabled = false, the SHIPPED DEFAULT) is not
    -- "cannot verify": the in-memory store is the authoritative store for
    -- the session and reads back every block that exists. Treating it as
    -- unverifiable made this tablet show every block-gated feature as
    -- blocked for every person on a stock install, on top of the real
    -- enforcement lockout HasPermission was independently causing. Must
    -- stay exactly in step with HasPermission's own rule -- this function's
    -- whole contract (see its doc comment above) is that it never shows
    -- `available` for something a real HasPermission call would refuse,
    -- and being STRICTER than HasPermission is the other way to break that
    -- promise: the tablet would report a feature blocked that the player
    -- can actually use.
    if type(K9Store) == 'table' and type(K9Store.IsDatabaseConfiguredOff) == 'function'
        and K9Store.IsDatabaseConfiguredOff() == true then
        return readOk == false -- deliberate memory mode: only THIS read failing is still a real "cannot verify"
    end

    if type(K9Store) == 'table' and type(K9Store.IsDatabaseEnabled) == 'function'
        and not K9Store.IsDatabaseEnabled('k9_permissions') then
        return true -- case 1: unreadable while persistence WAS expected (schema collision, or this table missing from an otherwise-installed database)
    end
    return readOk == false -- case 2: this citizenid's own read did not succeed
end

--- Real, current Unix time in whole seconds, or nil if unavailable --
--- mirrors server/certifications/'s own NowUnix "fails toward
--- availability" posture (see that file's IsExpiredUnix doc comment): an
--- unreadable `os.time` must make `expired` resolve to false, never crash
--- this read entirely, since a broken clock says nothing about whether a
--- real certification has actually lapsed. Not itself a cross-file call --
--- os.time is plain Lua 5.4 stdlib, not a resource-global -- so this is a
--- small local duplicate of that file's own guard, not a new dependency.
--- @return number?
local function NowUnixOrNil()
    if type(os) == 'table' and type(os.time) == 'function' then
        return os.time()
    end
    return nil
end

--- ONE ROW PER CONFIGURED DEPARTMENT for `citizenid` -- including
--- departments they have never held (active = false, grantedBy = nil), so
--- the tablet can offer "Certify" for a brand-new department per
--- PersonSummaryResult's own documented contract. Uses idx_citizen_job_active
--- as a citizenid-prefix scan (no LIMIT needed: bounded by the number of
--- configured departments, a small fixed set -- at most one active row per
--- department per this schema's own uq_one_active_cert_per_job invariant).
--- Migrated onto K9Store.Cert_GetActiveJobsForCitizen (identical
--- SQL/index, now behind the DatabaseEnabled() switch) -- see that
--- accessor's own doc comment in server/datastore.lua for why it needed to
--- be added rather than reused from an existing one.
---
--- CERTIFICATION DEPTH READ-SIDE -- tier/expiry/specializations
--- were entirely absent from this array until now: a handler's tier and
--- specializations did not display anywhere on the tablet, not even
--- read-only, for the handler themselves or for high command looking them
--- up. For each department this citizenid ACTUALLY holds (active == true
--- only -- a department they've never held has no tier/expiry/specializations
--- to report, matching this row's own existing active=false/grantedBy=nil
--- shape for that case), this now calls server/certifications/'s
--- DB-authoritative, already-exposed QueryCertificationRecord(citizenid,
--- jobKey) -- the SAME accessor that file's own header names as built "for
--- tablet/roster/admin reads" and already used by an OFFLINE-safe caller
--- (works for a disconnected citizenid too, exactly what
--- tabletRequestPersonSummary needs for someone who is not online right
--- now). One extra pair of queries (QueryCertificationRecord's own
--- Cert_GetActiveRecord + Spec_GetActiveKeys reads) PER DEPARTMENT THIS
--- CITIZENID ACTUALLY HOLDS -- bounded by the same small, fixed
--- Config.Departments count this function's own existing loop is already
--- bounded by (2-4 in every shipped config), not by roster size: this
--- function runs once per tabletRequestMyRecord/tabletRequestPersonSummary
--- call, never once per roster row. `expired` is computed HERE, in Lua,
--- rather than by calling into server/certifications/'s own (local,
--- unexported) IsExpiredUnix -- see NowUnixOrNil above for why that is a
--- small, deliberate, same-logic local duplicate rather than a new
--- cross-file call. Guarded with `type(QueryCertificationRecord) ==
--- 'function'`, this resource's established soft-dependency convention --
--- degrades to no tier/expiry/specializations data (never a crash) if
--- server/certifications/ is ever unavailable, exactly like every other
--- guarded cross-file read in this file.
--- @param citizenid string
--- @return table -- array of { departmentKey, departmentLabel, active, grantedBy, tier, expiresAtUnix, expired, specializations }
local function BuildCertificationsArray(citizenid)
    local rows = SafeStoreCall(K9Store.Cert_GetActiveJobsForCitizen, citizenid) or {}
    local grantedByJob = {}
    for _, row in ipairs(rows) do
        grantedByJob[row.job] = row.granted_by
    end

    local now = NowUnixOrNil()

    local out = {}
    if type(Config.Departments) == 'table' then
        -- Deterministic order -- `pairs` over Config.Departments has no
        -- guaranteed order, and a stable per-request shape is worth a
        -- cheap sort over a small, fixed-size table.
        local jobKeys = {}
        for jobKey in pairs(Config.Departments) do
            jobKeys[#jobKeys + 1] = jobKey
        end
        table.sort(jobKeys)

        for _, jobKey in ipairs(jobKeys) do
            local dept = Config.Departments[jobKey]
            local isActive = grantedByJob[jobKey] ~= nil

            -- Only an ACTIVE department has a tier/expiry/specializations to
            -- report at all -- see this function's own doc comment above.
            local tier, expiresAtUnix, specializations = nil, nil, {}
            if isActive and type(QueryCertificationRecord) == 'function' then
                local record = QueryCertificationRecord(citizenid, jobKey)
                if record then
                    tier = record.tier
                    expiresAtUnix = record.expiresAtUnix
                    specializations = record.specializations or {}
                end
            end

            local expired = false
            if type(expiresAtUnix) == 'number' and type(now) == 'number' and now >= expiresAtUnix then
                expired = true
            end

            out[#out + 1] = {
                departmentKey = jobKey,
                departmentLabel = (type(dept) == 'table' and type(dept.label) == 'string') and dept.label or jobKey,
                active = isActive,
                grantedBy = grantedByJob[jobKey],
                tier = tier,
                expiresAtUnix = expiresAtUnix,
                expired = expired,
                specializations = specializations,
            }
        end
    end
    return out
end

--- @param charinfo any
--- @return string?
local function FullNameFromCharinfo(charinfo)
    if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
        local full = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
        if type(full) == 'string' and full ~= '' then return full end
    end
    return nil
end

--- Best-effort display name -- see this file's header "NAME RESOLUTION"
--- for the full, disclosed gap this documents rather than guesses around.
--- The OFFLINE branch below now consults qbx_core's own
--- `GetOfflinePlayer` export per that header's "NOT YET WIRED" note --
--- soft-guarded with `pcall`, exactly like every other cross-resource call
--- in this file, so a qbx_core version without that export (or a citizenid
--- it does not recognize) still falls through to the same
--- always-safe citizenid fallback this function has always had.
--- @param citizenid string
--- @return string
local function ResolveDisplayName(citizenid)
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

    -- OFFLINE -- ask qbx_core's own offline accessor before giving up.
    local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
    if ok and type(offlinePlayer) == 'table' and offlinePlayer.PlayerData then
        local full = FullNameFromCharinfo(offlinePlayer.PlayerData.charinfo)
        if full then return full end
    end

    -- Still nothing usable -- fall back to the citizenid itself. Never
    -- blank, never a guess at an unverified schema.
    return citizenid
end

--- THE REAL EXISTENCE CHECK (see html/tablet.js's "GHOST-CITIZENID GUARD"
--- doc comment on
--- personSummaryLooksLikeNoRecord for the exact gap this closes): does a
--- REAL qbx_core player row exist for `citizenid` at all, online or
--- offline? tabletRequestPersonSummary previously returned `ok = true` for
--- ANY syntactically valid citizenid string -- a typo, or a deleted
--- character's old id -- with no way to distinguish that from a genuine
--- handler who simply holds zero certs/XP/partnership. html/tablet.js's own
--- stopgap inferred "no record" from every OTHER field being empty
--- simultaneously, documented there as a frontend-only placeholder for
--- exactly this field.
---
--- DELIBERATELY THE SAME RESOLUTION PATH ResolveDisplayName ALREADY USES
--- (online GetPlayerByCitizenId first, offline GetOfflinePlayer via pcall
--- as the fallback) -- NOT a new or stricter source of truth. This matters
--- for honesty, not just code reuse: if this function used a different/
--- stricter check than ResolveDisplayName, the two could disagree (e.g.
--- `exists = false` alongside a `name` that isn't the bare citizenid
--- fallback, or vice versa), which would be a more confusing contract than
--- the one being fixed. A citizenid ResolveDisplayName can put a real name
--- to is, by construction, a citizenid this function reports as existing.
--- @param citizenid string
--- @return boolean
local function ResolvePlayerExists(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData then return true end

    local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
    if ok and type(offlinePlayer) == 'table' and offlinePlayer.PlayerData then return true end

    return false
end

--- OWNER'S ASK ("ensure a name actually pops up and not the player id...
--- etc"), THE ONE GAP FOUND IN THIS FILE: BuildCertificationsArray's own
--- `grantedBy` field is a raw citizenid, and html/tablet.js already renders
--- it directly as plain text (that file's own resolveCertRow-style renderer,
--- class `k9tablet-cert-granter`) -- the exact "identifier where a human
--- name belongs" bug this closes. Adds ONE additive sibling
--- field, `grantedByName`, to each row BuildCertificationsArray already
--- returned, via the SAME ResolveDisplayName this file already uses for
--- `viewer.name`/`target.name`/roster rows -- `grantedBy` itself is left
--- completely unchanged (still the citizenid, still the only thing any
--- lookup/grant/revoke keys off -- keep the identifier,
--- a name is never an identity).
---
--- WHY A SEPARATE POST-PROCESSING PASS, NOT FOLDED INTO
--- BuildCertificationsArray's OWN BODY: that function is defined EARLIER in
--- this file (above), textually before ResolveDisplayName's own `local
--- function` declaration -- Lua's lexical scoping means a `local` declared
--- later is invisible to a function defined earlier in the same chunk, so a
--- direct call to ResolveDisplayName from inside BuildCertificationsArray
--- would resolve to a nil GLOBAL at runtime (there is no forward-declared
--- local of that name), throwing the moment any active-department row was
--- built. Kept here instead, called from BOTH call sites
--- (tabletRequestMyRecord/tabletRequestPersonSummary below), rather than
--- reordering ~55 lines of BuildCertificationsArray's own body/doc comment
--- purely to move it below ResolveDisplayName.
--- @param certifications table -- BuildCertificationsArray's own return value, mutated in place
--- @return table -- the same table, so this reads as one expression at each call site
local function EnrichCertificationsWithGrantedByName(certifications)
    for _, row in ipairs(certifications) do
        row.grantedByName = row.grantedBy and ResolveDisplayName(row.grantedBy) or nil
    end
    return certifications
end

--- @param configured any
--- @return number
local function ClampedMaxRosterRows()
    local configuredValue = type(Config.CommandTablet) == 'table' and Config.CommandTablet.maxRosterRows
    if type(configuredValue) ~= 'number' or configuredValue ~= configuredValue
        or configuredValue <= 0 or configuredValue == math.huge then
        return DEFAULT_MAX_ROSTER_ROWS
    end
    return math.floor(configuredValue)
end

-- ======================================================================
-- AUTHORIZATION-SHAPED HELPERS -- each mirrors an existing rank-gate SHAPE
-- already established elsewhere in this resource (server/certifications/'s
-- IsEligibleCertifier, server/admin.lua's IsAuthorizedAdmin,
-- server/permissions.lua's own MeetsDepartmentGradeOrHighCommand), rather
-- than exporting any of those `local` functions as new resource-globals
-- purely for this one read -- see server/permissions.lua's own doc comment
-- on MeetsDepartmentGradeOrHighCommand for the established reasoning this
-- follows: "a small internal duplicate of the ... comparison shape ...
-- deliberately NOT achieved by exporting ... as new resource-globals ...
-- which would have required a .luacheckrc globals entry this file cannot
-- add for itself." This file is in the identical position.
-- ======================================================================

--- Rank-only comparison (no grant, no high-command re-check -- both are
--- already checked by every call site BEFORE falling through to this).
--- Fails closed on every unresolvable shape, identical to every other rank
--- gate in this resource.
--- @param source number
--- @param gradeField string -- 'certifierGrade' | 'auditGrade'
--- @return boolean
local function MeetsDepartmentRank(source, gradeField)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or type(Config.Departments) ~= 'table' or not Config.Departments[job.name] then return false end

    if job.isboss then return true end

    local dept = Config.Departments[job.name]
    if type(dept[gradeField]) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept[gradeField]
end

-- ======================================================================
-- PERMISSION-KEY CATALOG AWARENESS (cross-layer contract audit
-- finding: "a custom permission key can be created and granted, and never
-- shows as held"). server/permissionkeycatalog.lua lets high command create
-- a permission key entirely at runtime; server/permissions.lua's own
-- IsValidPermissionKey/HasPermission are already catalog-aware, so granting
-- one genuinely works. Previously, BOTH aggregation sites below this
-- section (ResolveEffectivePermissions, and tabletRequestPersonSummary's
-- own inline `permissions` builder further down this file) instead iterated
-- `pairs(Config.Permissions)` -- the static, four-key, config-only table --
-- so a purely-runtime key was never even a CANDIDATE in either response,
-- regardless of whether the person asking (or being asked about) actually
-- held it: html/tablet.js's own resolveCapabilityRows() already merges the
-- live catalog in and renders a row for a custom key, but that row's
-- `held` flag is read directly from whichever of these two fields this bug
-- broke, so it read "not held" forever, and the operator could never
-- confirm or revoke a custom permission from the tablet.
-- ======================================================================

--- The four capability keys with a HARDCODED legacy-rank/high-command
--- resolution branch in ResolveEffectivePermissions below (mirrors
--- server/permissions.lua's own LegacyOrHighCommandStillQualifies -- a
--- literal string comparison, never a catalog lookup). ALWAYS treated as
--- candidates, regardless of what the permission-key catalog currently
--- reports for that literal string, deliberately: certifications.lua's
--- IsEligibleCertifier / admin.lua's IsAuthorizedAdmin / HasK9Access's other
--- three routes (certification, autoAccessGrade, high command) are each
--- COMPLETELY INDEPENDENT of the permission-key catalog -- tombstoning
--- 'k9.certify' from the tablet's Permission Keys screen only turns off the
--- ABILITY TO GRANT/HOLD that one capability BY THAT ROUTE (see
--- server/permissionkeycatalog.lua's own header "NO PROTECTED KEY" for the
--- exact, disclosed reasoning this mirrors); it does not, and must not,
--- revoke a rank-qualified officer's real, independent certify/audit
--- authority. If this file instead derived its candidate set PURELY from
--- the live catalog, tombstoning one of these four would silently drop it
--- from a rank-qualified caller's own effectivePermissions -- which
--- html/tablet.js reads directly to decide whether to show that caller
--- their OWN "Certify"/"Give XP" buttons at all (CAPABILITY_ORDER /
--- canCertify/canGiveXp) -- hiding a real ability the tablet's own
--- documented contract says it has, the exact opposite-direction "tablet
--- reports something that is not true" bug this closes.
--- Only a CUSTOM key (anything outside this table) has no such independent
--- route, so only a custom key's candidacy is allowed to depend on the
--- catalog/held-state below.
local LEGACY_PERMISSION_KEYS = { ['k9.access'] = true, ['k9.certify'] = true, ['k9.audit'] = true, ['k9.givexp'] = true }

--- Every permission-key catalog key server/tablet.lua's own two
--- admin-capability aggregations (ResolveEffectivePermissions,
--- tabletRequestPersonSummary's inline `permissions` builder) must consider
--- as a candidate, given one specific citizenid's own `activePermSet`
--- (QueryActivePermissionSet's own live, DB-authoritative row set -- ALWAYS
--- the real ground truth for "is this actually held" in both callers,
--- independent of this function). THREE sources, unioned:
---   1. LEGACY_PERMISSION_KEYS above -- always, unconditionally (see that
---      table's own doc comment for why these four cannot be allowed to
---      depend on catalog/tombstone state at all).
---   2. server/permissionkeycatalog.lua's own live ListPermissionCatalogKeys
---      (soft dependency, `type(...) == 'function'`-guarded, matching
---      server/permissions.lua's own IsValidPermissionKey/PermissionLabelFor
---      established shape exactly -- read that file's doc comments before
---      changing this one). Falls back to Config.Permissions directly ONLY
---      when the catalog function is absent OR its own call throws --
---      NEVER to an empty set: a catalog failure must degrade to "the four
---      shipped keys", the original pre-catalog behavior, not to "no
---      capabilities at all", which would read as a false, alarming "this
---      person has no permissions" on an authorized screen.
---   3. Every key `activePermSet` itself names, EXCLUDING the
---      'feature.<Name>'/'block.<Name>' per-person-feature namespace
---      (server/permissionkeycatalog.lua's own catalog never represents
---      that namespace at all -- see that file's header "NAMESPACE
---      PROTECTION" -- so neither must this admin-capability aggregation,
---      or a feature grant/block would render disguised as an admin
---      capability). THIS is what surfaces a TOMBSTONED custom key someone
---      still actively holds: ListPermissionCatalogKeys() excludes a
---      tombstoned key entirely by design (that file's own header
---      "TOMBSTONE, NOT REFERENCE-COUNTED"), so without this union a
---      still-granted, retired custom key would vanish from every response
---      the instant it is tombstoned -- a permission nobody could ever
---      revoke again from the tablet. html/tablet.js's own
---      resolveCapabilityRows() already has a third bucket specifically
---      built to render exactly this case (retired, revoke-only, no Grant
---      button) -- but only if the key actually reaches its `heldKeys`
---      argument in the first place, which is this union's own job to
---      guarantee.
--- NEVER widens what a CALLER can see on its own: this only decides which
--- KEY STRINGS are considered, never which citizenid's activePermSet is
--- read -- both call sites below still re-verify their own authorization
--- gate (IsHighCommand / CallerHasConsoleAccess) BEFORE ever calling this,
--- exactly as before.
--- @param activePermSet table<string, boolean>
--- @return table<string, boolean>
local function AdminCapabilityCandidateKeys(activePermSet)
    local candidates = {}
    for key in pairs(LEGACY_PERMISSION_KEYS) do
        candidates[key] = true
    end

    local haveCatalog = false
    if type(ListPermissionCatalogKeys) == 'function' then
        local ok, rowsOrErr = pcall(ListPermissionCatalogKeys)
        if ok and type(rowsOrErr) == 'table' then
            haveCatalog = true
            for _, entry in ipairs(rowsOrErr) do
                if type(entry) == 'table' and type(entry.key) == 'string' then
                    candidates[entry.key] = true
                end
            end
        else
            print(('[qbx_k9unit] tablet.lua AdminCapabilityCandidateKeys: ListPermissionCatalogKeys() failed (%s) -- falling back to Config.Permissions for the non-legacy portion of this candidate set.'):format(tostring(rowsOrErr)))
        end
    end

    -- FALLBACK, catalog absent or thrown ONLY -- never applied on top of a
    -- successful catalog read (that would resurrect a deliberately
    -- tombstoned DEFAULT key as a still-grantable candidate purely because
    -- it is a Config.Permissions literal, defeating the whole point of
    -- tombstoning it -- see server/permissionkeycatalog.lua's header
    -- "TOMBSTONE, NOT REFERENCE-COUNTED"). A tombstoned key someone still
    -- holds is already covered by source 3 below regardless.
    if not haveCatalog and type(Config.Permissions) == 'table' then
        for key in pairs(Config.Permissions) do
            candidates[key] = true
        end
    end

    if type(activePermSet) == 'table' then
        for key, active in pairs(activePermSet) do
            if active == true and type(key) == 'string'
                and not key:match('^feature%.') and not key:match('^block%.') then
                candidates[key] = true
            end
        end
    end

    return candidates
end

--- Full 4-step resolution (config.lua's own documented order) for every
--- CATALOG-AWARE candidate key (AdminCapabilityCandidateKeys above -- the
--- four shipped keys ALWAYS, plus any live/held custom key), from `source`'s
--- own perspective. Used for viewer.effectivePermissions (MyRecordResult)
--- and the "console access" gate (roster / person summary). `activePermSet`
--- is the CALLER's own active k9_permissions rows
--- (QueryActivePermissionSet(callerCitizenid)).
--- @param source number
--- @param activePermSet table<string, boolean>
--- @param isHighCommandCaller boolean
--- @return table -- sorted array of qualifying permission-catalog keys
--- Which of this tablet's ADMIN SCREENS this server can actually serve
--- right now, as a plain screen-key -> boolean map, sent once per
--- tabletRequestMyRecord inside `viewer.surfaces`.
---
--- THE BUG THIS CLOSES (owner directive, verbatim: "ensure anything
--- disabled in the config or requires a restart wont show up in the
--- tablet"). Every admin tab in html/tablet.js was gated on the viewer's
--- CAPABILITY alone -- do they hold 'k9.tablettheme', 'k9.runtimecontrol',
--- and so on. A capability says "you are allowed to use this screen"; it
--- says nothing about whether the screen's feature is switched on. So an
--- operator who set Config.Features.TabletTheming = false still got a Theme
--- tab, could open it, could edit every field, and every save came back
--- refused -- the server's own tabletSetTheme/tabletResetTheme check that
--- flag, this tab never did. Same shape for Shop Locations/Shop Items
--- (K9EquipmentShop), Runtime Control (RuntimeFeatureControl -- worse
--- there, since runtimeListFeatures itself has no flag check, so the whole
--- inventory rendered and every single toggle was refused), Permission
--- Keys (PermissionGrants), XP Tiers (both XP ladders off), and Audit,
--- whose callbacks are not even REGISTERED when AdminAuditCommands is off
--- -- that tab did not fail with a message, it hung until the callback
--- timed out.
---
--- RESOLVED SERVER-SIDE, FROM THE SAME FLAGS THE CALLBACKS ENFORCE, and
--- never inferred client-side from `myFeatures`: that array is a
--- PER-PERSON view (a row can read 'blocked' or 'not_certified' for
--- reasons that have nothing to do with whether the server has the feature
--- on), and it is also the wrong shape for the two screens whose
--- availability depends on more than one flag. One map, computed where the
--- flags actually live, keeps the tab and the callback behind it agreeing
--- by construction.
---
--- ONLY ADMIN SCREENS APPEAR HERE. The five universal tabs (Home, My
--- Record, Progression, Partnerships, Commands, Help) are deliberately
--- absent and are never gated: each is a read of your own record or of
--- static reference text, and each already has an honest "your server does
--- not track this" body for the switched-off case -- a MISSING tab reads
--- as a broken tablet, an empty one reads as a server setting, and for
--- those six the second is the truth worth showing. Cert Tiers, K9
--- Profiles, the two Roster tabs, Guided Flows and Command Console are
--- absent for a different reason: none of them has an owning
--- Config.Features flag at all (verified by reading server/certtiers.lua,
--- server/k9profiles.lua and server/roster.lua directly -- roster.lua's
--- only flag gate is Config.Features.CommandTablet, which is already true
--- for anyone holding an open tablet). Adding a key here for a screen with
--- no flag would be inventing a switch that does not exist.
---
--- A SCREEN MISSING FROM THIS MAP IS "AVAILABLE", NOT "HIDDEN" -- see
--- html/tablet.js's own surfaceEnabled(), which treats an absent key, and
--- an absent `surfaces` object entirely, as true. That direction is
--- deliberate: an older client talking to a newer server, or a payload
--- that failed to carry this field, must keep every tab it has always had
--- rather than silently losing admin screens. Hiding is only ever the
--- result of an explicit `false` here.
--- @return table<string, boolean>
local function BuildAvailableSurfaces()
    local features = type(Config.Features) == 'table' and Config.Features or {}
    local shopOn = features.K9EquipmentShop == true
    return {
        theme           = features.TabletTheming == true,
        shop_locations  = shopOn,
        shop_items      = shopOn,
        runtime_control = features.RuntimeFeatureControl == true,
        audit           = features.AdminAuditCommands == true,
        permission_keys = features.PermissionGrants == true,
        -- EITHER ladder is enough: the XP Tier editor edits both
        -- Config.XPTiers and Config.HandlerXPTiers, and a server running
        -- exactly one of the two ladders still has real work to do here.
        -- Only with BOTH off does the screen have nothing to edit.
        xp_tiers        = features.XPProgression == true or features.HandlerXPProgression == true,
    }
end

local function ResolveEffectivePermissions(source, activePermSet, isHighCommandCaller)
    local out = {}

    for key in pairs(AdminCapabilityCandidateKeys(activePermSet)) do
        local qualifies = false
        if isHighCommandCaller or activePermSet[key] == true then
            qualifies = true
        elseif key == 'k9.access' then
            -- HasK9Access already resolves grant + high-command + cert-cache
            -- + autoAccessGrade internally -- reused whole, not re-derived.
            qualifies = type(HasK9Access) == 'function' and HasK9Access(source) == true
        elseif key == 'k9.certify' then
            qualifies = MeetsDepartmentRank(source, 'certifierGrade')
        elseif key == 'k9.audit' then
            qualifies = MeetsDepartmentRank(source, 'auditGrade')
        end
        -- 'k9.givexp' has no legacy tier below high command/grant (both
        -- already checked above), and neither does any CUSTOM key (no
        -- branch above matches it) -- no further branch needed for either:
        -- both fall through to the plain `isHighCommandCaller or
        -- activePermSet[key]` check already performed above, matching
        -- server/permissions.lua's own LegacyOrHighCommandStillQualifies
        -- fallback reasoning for the identical namespace.
        if qualifies then out[#out + 1] = key end
    end

    table.sort(out)
    return out
end

--- "Console audience" gate for tabletRequestRoster specifically (the FULL
--- browse/search-by-name/department listing) -- per html/tablet.js's own
--- contract: "a caller with at least one of effectivePermissions non-empty,
--- or isHighCommand." Re-verified here on every call, from `source`'s own
--- live job -- never trusts a client's cached copy of
--- viewer.isHighCommand/effectivePermissions.
---
--- As of this pass, tabletRequestPersonSummary no longer calls this
--- function directly -- see CallerHasPersonAccess() immediately below,
--- which wraps this one and additionally admits a caller holding
--- 'k9.certify' or 'k9.givexp' alone. This function's own narrowed
--- contract (high command / 'k9.audit' only) is UNCHANGED and still the
--- only thing that gates the roster; do not widen it to "fix" a
--- person-lookup gap -- see CallerHasPersonAccess()'s own doc comment for
--- why a separate, narrower function was the right shape instead.
--- @param source number
--- @param callerCitizenid string
--- @param isHighCommandCaller boolean
--- @return boolean
local function CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller)
    if isHighCommandCaller then return true end

    -- OWNER'S DECISION: NARROWED to high command, or an explicit
    -- 'k9.audit' grant. This used to admit any caller with ANY non-empty
    -- effective permission, and 'k9.access' resolves true for every ordinary
    -- certified handler -- so a base-rank officer could look up any citizen
    -- id and read that person's certification history, their XP, and, worst,
    -- WHICH PEOPLE HOLD 'k9.certify'/'k9.audit'/'k9.givexp'. Read-only, so
    -- never an escalation, but it let rank-and-file enumerate who the
    -- powerful people in the department were.
    --
    -- 'k9.audit' is kept alongside high command deliberately, and this is
    -- not a loophole in "restrict it to high command": that capability is
    -- granted BY high command, to one named person, for exactly this
    -- purpose. Dropping it would leave the permission defined, grantable,
    -- documented -- and inert, which is its own bug class. What is closed is
    -- the 'k9.access' path, which was never a decision anyone made; it was a
    -- side effect of asking "do they have ANY permission at all".
    --
    -- Not affected: tabletRequestMyRecord. Every handler can still see their
    -- OWN record, which is a different question from looking up someone else.
    local activePermSet = QueryActivePermissionSet(callerCitizenid)
    for _, key in ipairs(ResolveEffectivePermissions(source, activePermSet, false)) do
        if key == 'k9.audit' then return true end
    end
    return false
end

--- "Single-person audience" gate for tabletRequestPersonSummary specifically
--- -- NOT tabletRequestRoster, which keeps CallerHasConsoleAccess() exactly
--- as it was (workflow audit finding #1, 2026-08-26). The whole point of
--- delegating 'k9.certify' or 'k9.givexp' to someone who is not high
--- command and does not hold 'k9.audit' is letting them do THAT ONE thing
--- without handing them the audit console -- html/tablet.js's own
--- buildPersonScreen() already gates every actual control on this screen
--- (Certify/Decertify, Give XP, the capability/feature/role sections) on
--- the viewer's OWN effectivePermissions/isHighCommand, independently of
--- how the screen was reached. Before this pass, a bare 'k9.certify' or
--- 'k9.givexp' grant qualified for NONE of those controls because the
--- screen itself was unreachable: both real entry points (the roster's
--- "Manage" button and the "Open by exact citizen ID" box) live inside
--- buildConsoleScreen(), which called tabletRequestRoster or
--- tabletRequestPersonSummary, and both were gated on
--- CallerHasConsoleAccess() -- so a capability that was real, granted, and
--- exercised correctly the moment someone reached it was completely inert
--- in practice. This function is what makes it reachable: it defers to
--- CallerHasConsoleAccess() first (so nothing already permitted stops
--- being permitted), then separately admits 'k9.certify'/'k9.givexp'
--- holders for THIS callback alone. The roster itself is untouched -- a
--- 'k9.certify'/'k9.givexp'-only caller still cannot browse or search by
--- name/department, only open a SPECIFIC citizenid they already know (see
--- html/tablet.js's buildConsoleScreen() narrowed rendering for that
--- viewer state, and canOpenPersonRecord() for the client-side mirror of
--- this exact gate -- convenience only, per THE SECURITY RULE, this is the
--- real enforcement).
--- @param source number
--- @param callerCitizenid string
--- @param isHighCommandCaller boolean
--- @return boolean
local function CallerHasPersonAccess(source, callerCitizenid, isHighCommandCaller)
    if CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller) then return true end

    local activePermSet = QueryActivePermissionSet(callerCitizenid)
    for _, key in ipairs(ResolveEffectivePermissions(source, activePermSet, isHighCommandCaller)) do
        if key == 'k9.certify' or key == 'k9.givexp' then return true end
    end
    return false
end

--- Does `citizenid` currently have K9 access, for a target that may be
--- ONLINE (reuses the real HasK9Access(source), fully accurate) or OFFLINE
--- (no live source exists -- falls back to the two PERSISTENT sources of
--- access: an explicit 'k9.access' grant, or an active certification row
--- in ANY department). The offline fallback deliberately does NOT attempt
--- to reconstruct autoAccessGrade/high-command bypass eligibility -- both
--- are inherently properties of a LIVE job, which a disconnected citizenid
--- does not have one of right now; this mirrors how every other part of
--- this resource treats an offline citizenid's rank-dependent state as
--- simply unknowable, never guessed.
--- @param citizenid string
--- @param activePermSet table<string, boolean>
--- @return boolean
local function ResolveTargetHasK9Access(citizenid, activePermSet)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    if onlineSrc then
        return type(HasK9Access) == 'function' and HasK9Access(onlineSrc) == true
    end
    if activePermSet['k9.access'] == true then return true end
    return QueryHasAnyActiveCertification(citizenid)
end

-- ======================================================================
-- BLOCK ENFORCEMENT CLASSIFICATION -- html/tablet.js's PersonFeaturesResult
-- doc comment (its own `blockEnforcement?` field, immediately above
-- featureBlockEnforcement()) is the canonical four-state contract this
-- section implements: THE TABLET MUST NEVER TELL AN OPERATOR A BLOCK DOES
-- MORE, OR LESS, THAN IT ACTUALLY DOES. Every key below was placed by
-- directly reading the feature-owning file's own per-person gate (or
-- confirming, by grep, that none exists) -- never guessed from the
-- feature's name. See each table's own comment for the exact evidence.
-- ======================================================================

--- The twelve features client/featureblocks.lua's own header names as
--- purely client-rendered/client-local, with NO server-side registration
--- point a `block.<Name>` check could ever be wired into (that file's own
--- header: confirmed by a grep across every server/*.lua file before it
--- was written, not assumed from the name). Kept BYTE-FOR-BYTE identical
--- to that file's own CLIENT_ENFORCED_FEATURES set -- if either table is
--- ever edited, update the other in the same pass.
---
--- These twelve DO now have a real, working per-person block --
--- client/featureblocks.lua's IsK9FeatureBlocked(), fed by a server push
--- -- but it is enforced BY THE PLAYER'S OWN CLIENT, which is a strictly
--- WEAKER guarantee than every other entry in this file's `features`
--- array: a modified client can always choose to skip its own check,
--- exactly as it could already fake this resource's model/access checks
--- (IsOwnModelK9/CanShowK9UI). Calling this 'enforced' would falsely claim
--- server-side parity; calling it 'not_enforceable' would falsely claim
--- the block does nothing. 'client_enforced' is the honest third answer --
--- see locales/en.json's tablet.block_client_enforced_badge/_hint for the
--- operator-facing "best-effort, not a guarantee" wording.
local CLIENT_ENFORCED_FEATURES = {
    RadialMenu = true,
    VehicleEntryExit = true,
    AgilityBasicJump = true,
    AgilityAdvanced = true,
    ThermalVision = true,
    NightVision = true,
    HealthStaminaHUD = true,
    ContrabandScreenFX = true,
    AdvancedBarkRadial = true,
    ProximityAudioFX = true,
    WaterTrackingDecay = true,
    CameraFeedPiP = true,
}

--- Every OTHER Config.Features key confirmed, by direct code read this
--- pass (a grep for `block.<Name>` -- literal and the dynamic
--- `'block.' .. featureName` shape several files share -- across every
--- server/*.lua file), to have NO server-side point that would EVER
--- consult `block.<Name>`, for a reason that is NOT "nobody has wired it
--- in yet" (that case is the safe 'not_yet_enforced' fallback this
--- function deliberately does not return for these):
---
---   K9EQUIPMENTSHOP -- REMOVED FROM THIS TABLE. A PRIOR
---   version of this comment (and of server/equipmentshop.lua's own
---   header) concluded K9EquipmentShop was structurally exempt, reasoning
---   that the buy/sell transaction never reaches this resource's own
---   code. That reasoning was WRONG, not merely superseded: re-reading
---   ox_inventory's own real source found it fires a genuine, per-attempt,
---   server-side `registerHook('openShop', ...)` / `registerHook('buyItem',
---   ...)` pair this resource's own K9Compat inventory adapter can already
---   register against (a fully generic `RegisterHook` pass-through,
---   shared/compat/inventory.lua). server/equipmentshop.lua now registers
---   both -- IsEquipmentShopPermittedForCitizenId there implements the
---   SAME four-step Config.FeatureControl resolution every other
---   blockable feature uses, and a genuine `HasPermission(citizenid,
---   'block.K9EquipmentShop')` call site now exists (see that file's own
---   "PER-PERSON FEATURE CONTROL" sections for the full writeup). This key
---   therefore now falls through to the ordinary 'enforced' classification
---   below, exactly like any other server-gated ability.
---
---   RESOURCEAUTODETECT / HIGHCOMMAND / PERMISSIONGRANTS / COMMANDTABLET /
---   CERTIFICATIONEXPIRY / RUNTIMEFEATURECONTROL / TABLETTHEMING -- these
---   are administrative/infrastructure switches, not a K9 ability any
---   single citizenid "does" -- grepped end to end for
---   `block.<Name>` (literal and dynamic) across every server/*.lua file:
---   zero matches for any of these seven keys, in sharp contrast to
---   ordinary abilities like BasicBarkSounds/LeashMechanics/etc. (which
---   ARE something a person does, and DO have their own `block.<Name>`
---   check -- see their omission from this table). config.lua's own
---   Config.FeatureControl per-person-block contract ("high command can
---   turn an individual feature on or off for ONE specific K9 or
---   handler") only makes sense for a feature that is something a
---   specific person does; these seven structurally are not that.
---
--- DISCLOSED: server/permissions.lua's IsValidPermissionKey still lets a
--- high-command operator WRITE a `block.<Name>` row for any of these eight
--- keys (it validates only `Config.Features[Name] ~= nil`, never whether
--- anything actually reads that row) -- this table exists specifically so
--- the tablet tells that operator, honestly, that doing so would have no
--- effect at all, rather than implying either that it works ('enforced')
--- or that it merely hasn't been wired up yet ('not_yet_enforced').
local NOT_ENFORCEABLE_FEATURES = {
    ResourceAutoDetect = true,
    HighCommand = true,
    PermissionGrants = true,
    CommandTablet = true,
    CertificationExpiry = true,
    RuntimeFeatureControl = true,
    TabletTheming = true,
}

--- @param key string -- a Config.Features key
--- @return string -- 'client_enforced' | 'not_enforceable' | 'enforced'
--- NEVER returns 'not_yet_enforced' -- that value exists purely as
--- html/tablet.js's own client-side fallback for a `blockEnforcement`
--- field this function did not send at all (an older server build, or a
--- key this function has genuinely never heard of -- structurally
--- impossible today, since ListFeatureKeys() and this function iterate
--- the exact same, real-time Config.Features table). Every key this
--- function DOES resolve for lands in EXACTLY one of the two explicit
--- tables above, by a direct, disclosed code read; 'enforced' is the
--- DEFAULT for every remaining key precisely because every ordinary
--- K9-ability feature file in this resource follows the same "PER-PERSON
--- FEATURE CONTROL" convention (HasPermission(citizenid, 'block.' .. key)
--- checked, static or via a shared `featureName`/`featureKey` parameter,
--- before the ability's own effect runs) -- confirmed, not assumed, for
--- every key currently in Config.Features (full per-key evidence list:
--- server/main.lua, server/search.lua,
--- server/tracking.lua, server/wellbeing.lua, server/combat.lua and
--- eighteen further single-feature files each their own `block.<Name>`
--- check). A FUTURE feature added to Config.Features without being placed
--- in either table above will default to 'enforced' here -- whoever adds
--- it is expected to add it to one of the two tables above AT THE SAME
--- TIME it lands its own `block.<Name>` check (or its own reason not to),
--- mirroring this file's existing Config.CommandTablet.ActionableFeatures
--- convention for exactly this "a small, explicit, code-owner-maintained
--- registry, never silently stale" reason.
local function ResolveBlockEnforcement(key)
    if NOT_ENFORCEABLE_FEATURES[key] == true then return 'not_enforceable' end
    if CLIENT_ENFORCED_FEATURES[key] == true then return 'client_enforced' end
    return 'enforced'
end

-- ======================================================================
-- FEATURE STATE RESOLUTION -- see this file's header "STATE RESOLUTION".
-- ======================================================================

--- @param key string -- a Config.Features key
--- @param hasK9Access boolean -- already resolved for the relevant person (caller or target)
--- @param activePermSet table<string, boolean> -- that SAME person's active k9_permissions rows
--- @param isHighCommandBypass boolean? -- OPTIONAL, pre-resolved by the caller (mirrors ResolveEffectivePermissions's own `isHighCommandCaller` parameter shape) -- see this function's own header comment below for the full "displayed state, not the underlying record" reasoning
--- @param blockNamespaceUnreliable boolean? -- OPTIONAL, pre-resolved ONCE per call site from BlockNamespaceUnreliable(readOk) (see that function's own doc comment for the full "DISPLAY-GAP, FAIL-OPEN" writeup this closes) -- when true, `activePermSet['block.' .. key]` cannot be trusted to reflect a real, currently-absent block, so this resolves 'blocked' unconditionally for every key, exactly mirroring server/permissions.lua's HasPermission failing closed for the identical reason.
--- @return string -- 'global_off' | 'blocked' | 'not_certified' | 'requires_grant_missing' | 'available'
--- DISPLAY-GAP FIX (this pass): high command already implicitly holds
--- every permission/feature/K9 upgrade -- LegacyOrHighCommandStillQualifies
--- and this file's own ResolveEffectivePermissions have resolved that for
--- the four admin-capability keys for a long time. This function did NOT:
--- it read `activePermSet` (the raw k9_permissions GRANT SNAPSHOT) and
--- `hasK9Access` (the raw certification/grant-derived access flag) alone,
--- so a genuinely high-command officer with no PERSONAL certification or
--- 'feature.<Name>' grant saw their own real abilities reported
--- 'not_certified'/'requires_grant_missing' -- UNDER-reporting their real
--- authority, the wrong direction of wrong, but still wrong (it reads as
--- a broken feature, not a working one, and invites turning on a grant
--- that was never needed).
---
--- `isHighCommandBypass` is a DISPLAY-ONLY overlay, computed by each call
--- site from server/permissions.lua's own IsHighCommandBypassCitizenId
--- (soft dependency, see BuildMyFeaturesArray/BuildPersonFeaturesArray
--- below for exactly how each resolves it) -- NEVER derived here, and
--- NEVER written back into k9_permissions: `activePermSet` above stays
--- the untouched, real k9_permissions snapshot every other consumer of
--- QueryActivePermissionSet (ListActivePermissionsForCitizenId, etc.)
--- still reads -- this function changes only the STRING this ONE response
--- reports for `state`, never the ground truth GetXP/GetXPTier/
--- GetHandlerXPTier or the permission rows themselves reflect (those stay
--- deliberately pure -- real earned XP, real held grants, nothing
--- fabricated).
---
--- ORDER MATTERS: 'global_off' and 'blocked' are checked BEFORE the
--- bypass, and 'blocked' explicitly SHORT-CIRCUITS it -- the owner's own
--- explicit carve-out ("an explicit block.<Name> still beats high
--- command, always") is the ONE lever he has to restrain one specific
--- person without demoting them, and this fix must never quietly take
--- that away. A globally-disabled feature likewise stays 'global_off' for
--- everyone, high command included -- rank does not turn a server-wide
--- switch back on.
--- @return string state
--- @return boolean viaHighCommand -- true ONLY when `state` came back
--- 'available' AND the ordinary (non-bypass) path would NOT have reached
--- 'available' on its own -- i.e. this specific person's real, personal
--- access/grant is NOT what makes this row usable right now, their rank
--- is. `false` for every other state, AND for an 'available' row this
--- person would have earned honestly regardless (real K9 access, and
--- either no grant required or a real grant held) -- a high-command
--- officer who ALSO happens to hold the real grant is not shown as
--- "via rank" for something they were never missing in the first place.
--- BuildPersonFeaturesArray surfaces this as its own `viaHighCommand`
--- field for html/tablet.js's subtle per-row marker; BuildMyFeaturesArray
--- does not forward it at all (myFeatures[] carries no granted/
--- requiresGrant detail to contextualize it against, and this is far
--- less likely to confuse the high-command viewer about their OWN screen
--- than about someone else's).
---
--- FAIL-CLOSED ON AN UNRELIABLE READ (this pass -- see
--- BlockNamespaceUnreliable's own doc comment for the full "why"): checked
--- immediately after 'global_off' and BEFORE the ordinary
--- `activePermSet['block.' .. key]` read, for the same reason 'blocked'
--- itself is checked before the high-command bypass below -- an unreliable
--- read must win over EVERYTHING further down this function, bypass
--- included, because the whole point is "an active block might be sitting
--- in a place this read could not reach", and a rank-based bypass is not a
--- reason to ignore that risk.
local function ResolveFeatureState(key, hasK9Access, activePermSet, isHighCommandBypass, blockNamespaceUnreliable)
    if not (Config.Features and Config.Features[key] == true) then return 'global_off', false end
    if blockNamespaceUnreliable or activePermSet['block.' .. key] == true then return 'blocked', false end

    local requireGrant = type(Config.FeatureControl) == 'table' and type(Config.FeatureControl.RequireGrant) == 'table'
        and Config.FeatureControl.RequireGrant[key] == true
    local hasGrant = activePermSet['feature.' .. key] == true
    local ordinarilyAvailable = hasK9Access and (not requireGrant or hasGrant)

    if ordinarilyAvailable then return 'available', false end
    if isHighCommandBypass == true then return 'available', true end
    if not hasK9Access then return 'not_certified', false end
    return 'requires_grant_missing', false
end

-- ======================================================================
-- FEATURE DOMAIN TAGGING -- owner-directed ("more color based on all
-- scent stuff vehicle related is more text based") pass. A small, explicit,
-- hand-maintained table, deliberately mirroring NOT_ENFORCEABLE_FEATURES/
-- CLIENT_ENFORCED_FEATURES above (same shape: a plain key->value map, read
-- by one small resolver function, never guessed from a feature's name
-- string at render time) -- this is that same established pattern, not a
-- second mechanism. `myFeatures[].category`/`features[].category` (both
-- documented in html/tablet.js's own header, both sent as a bare `nil`
-- until this pass) are populated from this table below.
--
-- owner-directed, 2026-08-26, verbatim: "same with features and sub
-- features" -- Config.Features' 60 flat flags are grouped the same way
-- commands were, so the tablet's feature list reads as a handful of
-- labelled sections instead of one long undifferentiated wall. EVERY
-- Config.Features key must resolve to EXACTLY ONE of the eleven domains
-- below -- see tests/tabletfeaturedomains_spec.lua's own "no key left
-- behind" test, which loads the REAL config.lua (never a hand-typed
-- duplicate of its key list, which could silently drift the moment a new
-- Config.Features key is added without a matching entry here) and fails
-- loudly if even one key resolves to `nil`. This table itself is still
-- hand-authored, deliberately: which domain a feature belongs in is a
-- judgment call no script can make, but the SET OF KEYS being judged is
-- always the live, real Config.Features, not a copy that can go stale.
--
-- PREVIOUSLY (before this pass): only the 'scent' and 'vehicle' families
-- (7 of the then-59 keys) had a domain at all; every other key rendered
-- with no grouping whatsoever. html/tablet.js's own buildPersonFeaturesSection()/
-- buildMyFeaturesSection() now render whatever domain set this file sends,
-- in a fixed declared order, with an UNRECOGNIZED domain string (or nil)
-- falling back to its own generic "Other" bucket rather than vanishing --
-- see that file's own FEATURE_DOMAIN_ORDER for the client-side half of
-- this contract.
local FEATURE_DOMAINS = {
    -- 'scent' -- detection & scent. Config.Tracking.ScentVision.palette
    -- (config.lua) is the ONE person-to-colour scheme this domain's
    -- tablet content must agree with; see html/tablet.js's own
    -- scent-section comment for why that palette is deliberately NOT
    -- reused here for feature-row colouring (it is reserved for
    -- representing a SPECIFIC TRACKED PERSON, which no row in this
    -- generic feature list is).
    ScentTracking      = 'scent',
    ScentVision        = 'scent',
    BloodTracking      = 'scent',
    GunpowderSniffing  = 'scent',
    WaterTrackingDecay = 'scent',

    -- 'search' -- search & contraband/rescue operations (the OUTCOME/
    -- alerting layer over a search, not the scent detection that feeds
    -- it -- see 'scent' above for that half).
    SearchZones        = 'search',
    ContrabandAlerts   = 'search',
    ContrabandScreenFX = 'search',
    FindAlerts         = 'search',

    -- 'vision' -- vision & sensory augmentation (sight AND the one
    -- proximity-audio cue that plays the same role for hearing).
    NightVision        = 'vision',
    ThermalVision      = 'vision',
    CameraFeedPiP      = 'vision',
    ProximityAudioFX   = 'vision',

    -- 'combat' -- combat & restraint, plus the tactical-awareness/alert
    -- abilities that exist specifically for a dangerous encounter.
    BiteAndHold        = 'combat',
    NonLethalTakedown  = 'combat',
    PursuitSprint      = 'combat',
    PropDragging       = 'combat',

    -- 'movement' -- core K9 control and mobility: the basic actions of
    -- having and directing a dog (leash, barking, agility, getting in/out
    -- of vehicles and through doors).
    LeashMechanics     = 'movement',
    BasicBarkSounds    = 'movement',
    AdvancedBarkRadial = 'movement',
    AgilityBasicJump   = 'movement',
    AgilityAdvanced    = 'movement',
    VehicleEntryExit   = 'movement',
    DoorInteraction    = 'movement',

    -- 'wellbeing' -- the K9's own physical/mental state and the systems
    -- that surface or respond to it.
    FatigueSystem      = 'wellbeing',
    HealthStaminaHUD   = 'wellbeing',
    K9DownDispatch     = 'wellbeing',

    -- 'progression' -- XP, certification, and the handler/K9 partnership
    -- record that progression is tracked against.
    XPProgression         = 'progression',
    HandlerXPProgression  = 'progression',
    CertificationExpiry   = 'progression',
    K9Leaderboard         = 'progression',
    HandlerPartnership    = 'progression',
    PartnershipTenureBonus = 'progression',

    -- 'gear' -- physical/inventory items and equipment.
    K9Inventory        = 'gear',
    K9Medkit           = 'gear',
    K9EquipmentShop    = 'gear',
    DeployableKennel   = 'gear',
    PropAttachments    = 'gear',

    -- 'training' -- the playful/practice mechanics -- distinct from
    -- 'scent'/'search' above, which are the real operational abilities
    -- these mechanics practice for.
    FetchMechanic      = 'training',

    -- 'admin' -- administrative/infrastructure switches with no
    -- per-citizenid ability behind them at all (the tablet itself, high
    -- command, permission grants, runtime control, theming, audit
    -- commands, and the one dev-only sweep tool).
    CommandTablet          = 'admin',
    HighCommand            = 'admin',
    PermissionGrants       = 'admin',
    RuntimeFeatureControl  = 'admin',
    TabletTheming          = 'admin',
    AdminAuditCommands     = 'admin',
    BoneSweepDevTool       = 'admin',

    -- 'integration' -- plumbing that talks to something outside this
    -- resource's own gameplay (Discord, resource detection, the radial
    -- menu's own UI mechanism).
    DiscordWebhook     = 'integration',
    ResourceAutoDetect = 'integration',
    RadialMenu         = 'integration',
}

--- @param key string -- a Config.Features key
--- @return string? -- one of FEATURE_DOMAIN_ORDER's keys (html/tablet.js), or nil if genuinely uncategorised (should never happen for a real Config.Features key -- see this table's own header)
local function ResolveFeatureDomain(key)
    return FEATURE_DOMAINS[key]
end

--- Is `key` known to have a client/tablet.lua single-button trigger?
--- DATA-DRIVEN, not hardcoded here -- see this file's header "myFeatures /
--- features KEY LIST -- DYNAMIC, NOT HARDCODED": reads the OPTIONAL,
--- REQUESTED `Config.CommandTablet.ActionableFeatures` allowlist (same
--- shape/spirit as the already-established Config.FeatureControl.RequireGrant
--- -- a small, explicit, config-owned table extended alongside its own
--- client/tablet.lua wiring whenever a new triggerable feature is added,
--- never a list this file would need editing to keep in sync). Defaults to
--- `false` when that table does not exist yet (requested, not yet landed)
--- -- the safe default is "no trigger shown" (a missing
--- button), never a phantom one that would click and do nothing.
--- @param key string
--- @return boolean
local function IsKnownActionableFeature(key)
    return type(Config.CommandTablet) == 'table'
        and type(Config.CommandTablet.ActionableFeatures) == 'table'
        and Config.CommandTablet.ActionableFeatures[key] == true
end

--- MyRecordResult's own `myFeatures` shape.
--- @param hasK9Access boolean
--- @param activePermSet table<string, boolean>
--- @param isHighCommandBypass boolean? -- see ResolveFeatureState's own doc comment. Callers of THIS function already have a live, correctly-scoped `IsHighCommand(source)` answer for the CALLER's own current job (tabletRequestMyRecord's own `isHighCommandCaller`) -- passed straight through, never re-derived via IsHighCommandBypassCitizenId here, since a fresh IsHighCommand(source) call is strictly more accurate than re-resolving the SAME online caller by citizenid a second time.
--- @param blockNamespaceUnreliable boolean? -- see BlockNamespaceUnreliable's own doc comment -- pre-resolved ONCE by the caller from QueryActivePermissionSet's own second return, then forwarded to every ResolveFeatureState call this loop makes.
--- @return table
local function BuildMyFeaturesArray(hasK9Access, activePermSet, isHighCommandBypass, blockNamespaceUnreliable)
    local out = {}
    for i, key in ipairs(ListFeatureKeys()) do
        out[i] = {
            key = key,
            label = nil,     -- html/tablet.js's own DEFAULT_STRINGS humanizes an absent label client-side
            category = ResolveFeatureDomain(key),
            actionable = IsKnownActionableFeature(key),
            state = ResolveFeatureState(key, hasK9Access, activePermSet, isHighCommandBypass, blockNamespaceUnreliable),
        }
    end
    return out
end

--- PersonFeaturesResult's own `features` shape -- HIGH COMMAND ONLY, richer
--- per-row detail than myFeatures (globallyEnabled/requiresGrant/granted/
--- blocked, alongside the same resolved `state`).
---
--- `granted`/`blocked`/`globallyEnabled`/`requiresGrant` below are ALL
--- left reading `activePermSet`/`Config.Features` directly, UNCHANGED by
--- `isHighCommandBypass` -- see ResolveFeatureState's own doc comment:
--- this is a DISPLAYED-STATE overlay only, never a fabricated grant row.
--- An operator reviewing a high-command TARGET with no personal
--- 'feature.<Name>' grant still sees `granted: false` (the honest,
--- factual record) alongside `state: 'available'` (the honest, factual
--- REASON it works anyway) -- both true at once, neither one lying.
--- @param hasK9Access boolean
--- @param activePermSet table<string, boolean>
--- @param isHighCommandBypass boolean? -- see ResolveFeatureState's own doc comment. Resolved by tabletRequestPersonFeatures for the TARGET specifically (server/permissions.lua's IsHighCommandBypassCitizenId, soft dependency) -- this is the TARGET's own rank, not the viewing high-command caller's; two high-command officers looking at a THIRD, non-high-command handler must see that handler's real, ungranted state, not their own.
--- @param blockNamespaceUnreliable boolean? -- see BlockNamespaceUnreliable's own doc comment -- pre-resolved ONCE by the caller from QueryActivePermissionSet's own second return, then forwarded to every ResolveFeatureState call this loop makes. Deliberately NOT applied to the `blocked` field below (see this function's own header "granted/blocked/globallyEnabled/requiresGrant... UNCHANGED" -- ground truth stays ground truth; only `state` fails closed).
--- @return table
local function BuildPersonFeaturesArray(hasK9Access, activePermSet, isHighCommandBypass, blockNamespaceUnreliable)
    local requireGrantTable = (type(Config.FeatureControl) == 'table' and type(Config.FeatureControl.RequireGrant) == 'table')
        and Config.FeatureControl.RequireGrant or {}

    local out = {}
    for i, key in ipairs(ListFeatureKeys()) do
        local state, viaHighCommand = ResolveFeatureState(key, hasK9Access, activePermSet, isHighCommandBypass, blockNamespaceUnreliable)
        out[i] = {
            key = key,
            label = nil,
            category = ResolveFeatureDomain(key),
            globallyEnabled = Config.Features and Config.Features[key] == true or false,
            requiresGrant = requireGrantTable[key] == true,
            granted = activePermSet['feature.' .. key] == true,
            blocked = activePermSet['block.' .. key] == true,
            state = state,
            -- SUBTLE MARKER (owner-directed, "why can this person do
            -- that" should be answerable at a glance, not by reading two
            -- fields) -- see ResolveFeatureState's own doc comment for the
            -- exact "would this row have been available anyway" contract.
            -- Always `false` for a granted/globally-off/blocked/genuinely-
            -- certified row -- never a second way to say "available".
            viaHighCommand = viaHighCommand,
            blockEnforcement = ResolveBlockEnforcement(key), -- see this file's own "BLOCK ENFORCEMENT CLASSIFICATION" section above
        }
    end
    return out
end

--- Shared XP/tier read -- nil/nil when XPProgression is off, matching
--- MyRecordResult/PersonSummaryResult's own documented `xp: number|null`
--- contract. GetXP/GetXPTier are guarded by `type(fn) == 'function'`
--- (this resource's soft-dependency convention) even though
--- server/progression.lua always defines both once loaded -- see that
--- file's own header for why the guard is kept regardless of load order.
--- @param citizenid string
--- @return number? xp
--- @return string? tierLabel
local function ResolveXpAndTierLabel(citizenid)
    if not (Config.Features and Config.Features.XPProgression == true) then
        return nil, nil
    end

    local xp = type(GetXP) == 'function' and GetXP(citizenid) or nil
    local tierLabel = nil
    if type(GetXPTier) == 'function' then
        local tier = GetXPTier(citizenid)
        tierLabel = type(tier) == 'table' and type(tier.label) == 'string' and tier.label or nil
    end
    return xp, tierLabel
end

--- HANDLER-LADDER counterpart to ResolveXpAndTierLabel above (owner-directed
--- progression pass). Same shape, same soft-dependency guards, same
--- nil-when-off contract -- and DELIBERATELY A SEPARATE FUNCTION reading a
--- SEPARATE FLAG rather than an extra return value bolted onto that one.
---
--- Config.Features.XPProgression and Config.Features.HandlerXPProgression
--- are independent switches: a server can legitimately run either ladder
--- without the other. Folding both into one resolver would have meant one
--- flag check deciding both answers, so turning the K9 ladder off would
--- have silently taken the handler ladder's numbers down with it -- the
--- same one-gate-too-few shape that left this whole feature invisible in
--- the first place.
---
--- nil means "this ladder is off, or the total is not knowable", NOT zero.
--- A handler genuinely sitting at 0 XP returns 0, and the two must stay
--- distinguishable all the way to the screen: "not tracked here" and "you
--- have not earned any yet" are different things to tell someone.
--- @param citizenid string
--- @return number? handlerXp
--- @return string? handlerTierLabel
local function ResolveHandlerXpAndTierLabel(citizenid)
    if not (Config.Features and Config.Features.HandlerXPProgression == true) then
        return nil, nil
    end

    local handlerXp = type(GetHandlerXP) == 'function' and GetHandlerXP(citizenid) or nil
    local handlerTierLabel = nil
    if type(GetHandlerXPTier) == 'function' then
        local tier = GetHandlerXPTier(citizenid)
        handlerTierLabel = type(tier) == 'table' and type(tier.label) == 'string' and tier.label or nil
    end
    return handlerXp, handlerTierLabel
end

--- Read-only rank/grade display for PersonSummaryResult -- owner-directed
--- "the roster panel should show everything about a person" pass. Reads
--- the EXACT SAME PlayerData.job shape every rank gate in this resource
--- already trusts (server/permissions.lua's MeetsDepartmentGradeOrHighCommand,
--- server/certifications/'s IsEligibleCertifier, etc.) -- never a new
--- source of truth, and never a write path: this resource has no
--- SetJobGrade-equivalent anywhere today, so the tablet only ever DISPLAYS
--- this, matching THE SECURITY RULE'S "never render a control the server
--- would refuse" -- there is no promotion control here at all, honest
--- about there being nothing behind one yet, rather than a disabled button
--- implying a feature that does not exist.
--- Online-preferred (exports.qbx_core:GetPlayerByCitizenId, same call
--- ResolveDisplayName above already makes), offline-fallback
--- (exports.qbx_core:GetOfflinePlayer, same call ResolveDisplayName's own
--- offline branch already makes) -- so this resolves for an offline
--- target exactly as well as an online one, matching every other read in
--- tabletRequestPersonSummary.
--- @param citizenid string
--- @return table? -- { departmentLabel: string, gradeLabel: string?, gradeLevel: number?, isBoss: boolean } | nil if no resolvable job at all
local function ResolveJobGradeInfo(citizenid)
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if not (player and player.PlayerData) then
        local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
        if ok and type(offlinePlayer) == 'table' then player = offlinePlayer end
    end

    local job = player and player.PlayerData and player.PlayerData.job
    if type(job) ~= 'table' then return nil end

    local dept = type(Config.Departments) == 'table' and Config.Departments[job.name]
    local departmentLabel = (type(dept) == 'table' and type(dept.label) == 'string' and dept.label)
        or (type(job.label) == 'string' and job.label)
        or job.name

    local gradeLabel = (type(job.grade) == 'table' and type(job.grade.name) == 'string') and job.grade.name or nil
    local gradeLevel = (type(job.grade) == 'table' and type(job.grade.level) == 'number') and job.grade.level or nil

    return {
        departmentLabel = departmentLabel,
        gradeLabel = gradeLabel,
        gradeLevel = gradeLevel,
        isBoss = job.isboss == true,
    }
end

--- Read-only partnership display for PersonSummaryResult. DB-AUTHORITATIVE
--- (K9Store.Partner_GetActiveRowByParty, via this file's own SafeStoreCall)
--- -- deliberately NOT server/partnership.lua's GetActivePartnerCitizenId,
--- which reads an ONLINE-ONLY in-memory cache (see that function's own doc
--- comment) and would silently report "not partnered" for an offline
--- target that actually is -- this callback must stay correct for an
--- offline target exactly like every other read in tabletRequestPersonSummary.
--- @param citizenid string
--- @return table? -- { partnerCitizenid: string, partnerName: string, role: 'k9'|'handler' } | nil (no active partnership, feature off, or unreadable)
local function ResolvePartnershipInfo(citizenid)
    if not (Config.Features and Config.Features.HandlerPartnership == true) then return nil end

    local row = SafeStoreCall(K9Store.Partner_GetActiveRowByParty, citizenid)
    if type(row) ~= 'table' then return nil end

    local isK9 = row.k9_citizenid == citizenid
    local partnerCitizenid = isK9 and row.handler_citizenid or row.k9_citizenid
    if type(partnerCitizenid) ~= 'string' or partnerCitizenid == '' then return nil end

    return {
        partnerCitizenid = partnerCitizenid,
        partnerName = ResolveDisplayName(partnerCitizenid),
        role = isK9 and 'k9' or 'handler',
    }
end

-- ======================================================================
-- CALLBACK 1 -- tabletRequestMyRecord. Every certified handler/K9 gets
-- this, not just high command (Config.FeatureControl.everyoneCanViewOwnRecord).
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestMyRecord', function(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true

    -- config.lua's own words: "Turning this off leaves the tablet as a
    -- high-command-only tool" -- a non-high-command caller is denied
    -- outright when the flag is off; high command is unaffected (they
    -- already have the console view regardless).
    if not isHighCommandCaller then
        local everyoneCanView = type(Config.FeatureControl) == 'table' and Config.FeatureControl.everyoneCanViewOwnRecord == true
        if not everyoneCanView then
            return { ok = false, error = 'not_authorized' }
        end
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    local activePermSet, permReadOk = QueryActivePermissionSet(citizenid)
    local blockNamespaceUnreliable = BlockNamespaceUnreliable(permReadOk)
    local effectivePermissions = ResolveEffectivePermissions(source, activePermSet, isHighCommandCaller)
    local xp, tierLabel = ResolveXpAndTierLabel(citizenid)
    local handlerXp, handlerTierLabel = ResolveHandlerXpAndTierLabel(citizenid)
    local hasK9Access = type(HasK9Access) == 'function' and HasK9Access(source) == true

    -- SERVER-TRUSTWORTHY ROLE SIGNAL (owner-directed
    -- "a handler and the k9 are both separate and if not fix it" /
    -- "if the server does not currently tell the page which role the
    -- viewer is in a trustworthy way, that is the first thing to fix").
    -- Previously the ONLY "is this viewer the K9" signal html/tablet.js
    -- had was state.isK9Model, computed entirely client-side
    -- (client/tablet.lua's ResolveLocalRoleFlags -> IsOwnModelK9(), "is my
    -- own ped CURRENTLY this model") -- explicitly documented there as
    -- cosmetic/framing-only, never authoritative. HasK9Role(source)
    -- (server/appearance.lua) is the correct, already-existing,
    -- MODEL-INDEPENDENT answer instead: "does this citizenid actually hold
    -- the K9 identity" (an active k9_certifications row for their current
    -- job, or an active k9.access grant), the SAME primitive
    -- server/main.lua's own IsGenuinelyK9Party prefers over a model check
    -- for exactly this "role, not appearance" reasoning. isPartnered is
    -- likewise now resolved from GetActivePartnerCitizenId (server/partnership.lua's
    -- own in-memory, online-authoritative cache -- correct here because
    -- the caller of THIS callback is, by construction, online right now),
    -- not the client-local IsPartnered() leash/appearance guess. Both
    -- guarded with this file's established `type(...) == 'function'`
    -- soft-dependency convention -- degrade to false, never a crash or a
    -- stale guess, if either owning file is ever unavailable. Used ONLY
    -- for html/tablet.js's role-driven LAYOUT (which landing body/tab
    -- order/vocabulary to show) -- never a new authorization decision
    -- here or on the client; every mutation this file/client/tablet.lua
    -- exposes still re-derives its own authorization from scratch,
    -- unrelated to these two fields (THE SECURITY RULE, html/tablet.js's
    -- own header).
    local isK9RoleCaller = type(HasK9Role) == 'function' and HasK9Role(source) == true
    local isPartneredCaller = type(GetActivePartnerCitizenId) == 'function' and GetActivePartnerCitizenId(citizenid) ~= nil

    return {
        ok = true,
        viewer = {
            citizenid = citizenid,
            name = ResolveDisplayName(citizenid),
            isHighCommand = isHighCommandCaller,
            effectivePermissions = effectivePermissions,
            allowSelfGrant = type(Config.HighCommand) == 'table' and Config.HighCommand.allowSelfGrant == true,
            isK9 = isK9RoleCaller,
            isPartnered = isPartneredCaller,
            -- ADMIN SURFACES THIS SERVER ACTUALLY HAS (owner directive:
            -- "ensure anything disabled in the config ... wont show up in
            -- the tablet"). See BuildAvailableSurfaces' own doc comment for
            -- the full writeup, including why this is resolved SERVER-SIDE
            -- from the same Config.Features flags each screen's own
            -- callbacks enforce, rather than inferred client-side.
            surfaces = BuildAvailableSurfaces(),
        },
        certifications = EnrichCertificationsWithGrantedByName(BuildCertificationsArray(citizenid)),
        xp = xp,
        tierLabel = tierLabel,
        -- ROLES (server/roles.lua): the live role list (roles high command
        -- created included) and the XP a role requirement is measured
        -- against, so the tablet can say "active" or "unlocks at N XP".
        roleCatalog = type(ListRolesForDisplay) == 'function' and ListRolesForDisplay() or nil,
        roleXp = type(GetRoleXpForCitizen) == 'function' and GetRoleXpForCitizen(citizenid) or nil,
        -- HANDLER LADDER (owner-directed progression pass). Carried
        -- ALONGSIDE the K9 pair above, never merged into it: the two are
        -- separate ladders on separate feature switches, and either can be
        -- nil while the other has a real value. null here means "this
        -- ladder is switched off", NOT zero -- a handler genuinely on 0 XP
        -- sends 0, and the UI must be able to tell those apart.
        handlerXp = handlerXp,
        handlerTierLabel = handlerTierLabel,
        -- THE TWO LADDERS, for the Progression screen. Sent ONLY on the
        -- caller's own record, never on roster rows: the ladders are
        -- server-wide and identical for everyone, so repeating them per row
        -- would multiply an unchanging payload by the roster size for no
        -- gain. Label and threshold only -- see
        -- server/progression.lua's GetXPLadderForDisplay for why the
        -- multipliers are deliberately withheld.
        --
        -- Each is an EMPTY ARRAY, never null, when its own ladder is
        -- switched off, so the UI's iteration never needs a null check and
        -- "off" renders the same as "no ranks configured" -- which is the
        -- honest thing to show for both.
        xpLadder = type(GetXPLadderForDisplay) == 'function' and GetXPLadderForDisplay() or {},
        handlerXpLadder = type(GetHandlerXPLadderForDisplay) == 'function' and GetHandlerXPLadderForDisplay() or {},
        -- isHighCommandCaller is already a FRESH, correctly-job-scoped
        -- IsHighCommand(source) answer for this exact caller (computed
        -- above) -- reused verbatim as the DISPLAY-STATE bypass rather
        -- than re-resolving the same online citizenid a second time via
        -- IsHighCommandBypassCitizenId. See ResolveFeatureState's own doc
        -- comment for the full "why", and BuildPersonFeaturesArray's own
        -- call site below for the OFFLINE-capable sibling case.
        myFeatures = BuildMyFeaturesArray(hasK9Access, activePermSet, isHighCommandCaller, blockNamespaceUnreliable),
        -- `partnership` -- CLOSES A REAL GAP: tabletRequestPersonSummary (the
        -- high-command-only lookup path, CALLBACK 3) has called
        -- ResolvePartnershipInfo(targetCitizenId) since that callback
        -- shipped, but this record -- the one every ordinary handler/K9
        -- actually opens for THEMSELVES -- never called the same function
        -- for the CALLER's own citizenid, so an ordinary K9 or handler had
        -- no way to see their own partnership on their own record. SAME
        -- function, SAME shape ({ partnerCitizenid, partnerName, role } |
        -- nil), called here with `citizenid` -- the value this callback
        -- already resolved from `source` above, never anything the client
        -- sent -- so this is exactly as self-scoped as every other field
        -- in this response. DB-authoritative (not the online-only
        -- Partnerships cache `isPartnered` above already reads), matching
        -- ResolvePartnershipInfo's own doc comment; harmless duplication
        -- of one extra read for a caller who is, by construction, online
        -- right now. NOT a replacement for `isPartnered` above (that field
        -- stays exactly as before, for html/tablet.js's own role-driven
        -- LAYOUT decision) -- this is the actual partner identity/name/role
        -- payload the Partnership tab needs to render, which `isPartnered`
        -- alone never carried.
        partnership = ResolvePartnershipInfo(citizenid),
    }
end)

-- ======================================================================
-- CALLBACK 2 -- tabletRequestRoster. Console audience only. See this
-- file's header "ROSTER QUERY -- PERFORMANCE" for the full bound/index
-- writeup.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestRoster', function(source, query)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller) then
        -- 'tablet.console_not_authorized' has landed in locales/en.json, so
        -- `message` is populated as this file's header always intended.
        -- SafeLocale() rather than a bare locale() call: this field is
        -- OPTIONAL per the JS contract (errorText() already falls back to
        -- a generic message for a bare 'not_authorized' error code), so a
        -- future rename/removal of this key must degrade to that same
        -- fallback instead of throwing out of this callback.
        return { ok = false, error = 'not_authorized', message = SafeLocale('tablet.console_not_authorized') }
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    if type(query) ~= 'string' then query = '' end
    if #query > MAX_ROSTER_QUERY_LENGTH then query = query:sub(1, MAX_ROSTER_QUERY_LENGTH) end
    local needle = query:lower()

    local maxRows = ClampedMaxRosterRows()
    local fetchCapPerDept = math.min(maxRows * ROSTER_FETCH_MULTIPLIER, ROSTER_FETCH_ABSOLUTE_CAP)

    -- BOUNDED, INDEXED fetch -- one query PER CONFIGURED DEPARTMENT (a
    -- small, fixed set), each an idx_job_active index seek with a hard,
    -- server-produced integer LIMIT (never a client-influenced one). NO
    -- ORDER BY -- see this file's header for the filesort this
    -- deliberately avoids repeating. Migrated onto
    -- K9Store.Cert_GetActiveRosterByJobUnordered -- a NEW
    -- accessor added specifically for this call site: the existing
    -- K9Store.Cert_GetActiveRosterByJob (server/datastore.lua) mirrors
    -- server/admin.lua's ORDERED shape (`ORDER BY granted_at DESC`), and
    -- swapping onto it would silently reintroduce the exact filesort this
    -- loop exists to avoid -- see that new accessor's own doc comment for
    -- the full reasoning. The LIMIT integer itself is still an
    -- already-clamped, server-computed Lua integer embedded via
    -- string.format inside that accessor's own DB-mode branch, never a
    -- client-influenced value.
    local candidates = {}
    local hitFetchCap = false
    if type(Config.Departments) == 'table' then
        for jobKey, dept in pairs(Config.Departments) do
            local rows = SafeStoreCall(K9Store.Cert_GetActiveRosterByJobUnordered, jobKey, fetchCapPerDept) or {}
            if #rows >= fetchCapPerDept then hitFetchCap = true end
            local departmentLabel = (type(dept) == 'table' and type(dept.label) == 'string') and dept.label or jobKey
            for _, row in ipairs(rows) do
                candidates[#candidates + 1] = {
                    citizenid = row.citizenid,
                    departmentLabel = departmentLabel,
                    grantedBy = row.granted_by,
                }
            end
        end
    end

    -- Resolve name/xp/tier and apply the free-text filter over the
    -- already-bounded candidate set -- all in-memory reads from here
    -- (ResolveDisplayName/GetXP/GetXPTier), no further DB round trips.
    local filtered = {}
    for _, candidate in ipairs(candidates) do
        local name = ResolveDisplayName(candidate.citizenid)
        local matches = needle == ''
            or candidate.citizenid:lower():find(needle, 1, true) ~= nil
            or name:lower():find(needle, 1, true) ~= nil
            or candidate.departmentLabel:lower():find(needle, 1, true) ~= nil
        if matches then
            local xp, tierLabel = ResolveXpAndTierLabel(candidate.citizenid)
            local handlerXp, handlerTierLabel = ResolveHandlerXpAndTierLabel(candidate.citizenid)
            filtered[#filtered + 1] = {
                citizenid = candidate.citizenid,
                name = name,
                departmentLabel = candidate.departmentLabel,
                certified = true,
                xp = xp,
                tierLabel = tierLabel,
                handlerXp = handlerXp,
                handlerTierLabel = handlerTierLabel,
            }
        end
    end

    table.sort(filtered, function(a, b) return a.citizenid < b.citizenid end)

    local truncated = hitFetchCap
    local rows = filtered
    if #filtered > maxRows then
        truncated = true
        rows = {}
        for i = 1, maxRows do rows[i] = filtered[i] end
    end

    -- 'tablet.roster_truncated_notice' has landed in locales/en.json, so
    -- this sets `truncatedMessage` as this file's own header always intended.
    -- html/tablet.js's contract documents it as optional and PREFERRED over a
    -- client-built count text when present; SafeLocale() (rather than a bare
    -- locale() call) means its absence with `truncated = true` remains a
    -- safe fallback if the key is ever renamed or removed, not a thrown error.
    local result = { ok = true, rows = rows, truncated = truncated }
    if truncated then
        result.truncatedMessage = SafeLocale('tablet.roster_truncated_notice', #rows)
    end
    return result
end)

-- ======================================================================
-- CALLBACK 2b/2c -- tabletRequestOnlinePlayers / tabletResolveOnlinePlayer.
-- Owner-directed, 2026-08-26, verbatim: "make the add permission section
-- on the ui tablet for the command tablet where its a list when i choose
-- a player id and just click those permissions etc make it easier". The
-- Person screen's permission checkboxes already exist and already work
-- (html/tablet.js's buildCapabilityList(), tablet:grantPermission/
-- revokePermission) -- what did not exist was a way to REACH that screen
-- for someone an operator can actually identify in game: the roster above
-- lists ONLY citizenids holding an ACTIVE certification, and the "open by
-- exact citizen ID" box needs a citizenid, which is not something a
-- player ever sees -- the pause menu shows a SERVER id. This pair closes
-- that gap by listing who is online RIGHT NOW, keyed by server id for
-- display, resolved to a citizenid fresh on the server the moment a row
-- is actually clicked. It is a NEW ENTRY POINT ONLY -- it reuses
-- openPerson()/loadPersonSummary() and every existing grant control on
-- the Person screen verbatim; no second grant mechanism was built.
--
-- AUTHORIZATION -- WHICH GATE, AND WHY: this is a BROWSE capability (list
-- of EVERYONE currently connected, regardless of certification), the
-- exact same shape of thing CallerHasConsoleAccess() was narrowed to
-- prevent (see that function's own doc comment, OWNER'S DECISION
-- 2026-08-25): letting a base-rank officer enumerate who else is on duty
-- right now, by name and job, purely because they hold ONE delegated
-- capability unrelated to browsing (e.g. 'k9.certify'/'k9.givexp' alone).
-- So this pair is gated with CallerHasConsoleAccess -- the SAME, narrower
-- gate as tabletRequestRoster -- and DELIBERATELY NOT the wider
-- CallerHasPersonAccess a 'k9.certify'/'k9.givexp'-only holder also
-- qualifies for. That viewer still reaches the Person screen exactly as
-- before this pass (the "open by exact citizen ID" box, if they already
-- know one) -- they simply do not get a free roster of everyone online.
-- This is "match the one whose screen this belongs to" read as: the
-- LISTING/BROWSING question this belongs with is tabletRequestRoster's,
-- not tabletRequestPersonSummary's -- both eventually land on the same
-- Person screen, but the roster and this list are the two BROWSE
-- entry points into it, and browsing is the thing that was narrowed.
--
-- RECYCLED SOURCE IDS -- THE PART THAT MATTERS MOST: a server id is not a
-- stable identity. It is freed the instant its holder disconnects and can
-- be handed to a brand-new connection seconds later. Resolving a click
-- purely from `exports.qbx_core:GetPlayer(clickedSourceId)` at click time
-- would silently hand back WHOEVER now holds that slot, not the specific
-- person the operator saw and clicked when the list was drawn -- landing
-- a permission grant on the wrong person, the single worst failure mode
-- this feature could have. The fix: tabletRequestOnlinePlayers mints a
-- short-lived, single-use, OPAQUE nonce per row, recording (source,
-- citizenid) as of THIS EXACT LIST BUILD; tabletResolveOnlinePlayer looks
-- that nonce up and only succeeds if the CURRENT live occupant of that
-- same source is STILL that same citizenid. A nonce is never a citizenid
-- and never reused across list builds (so one operator's stale list can
-- never be "revalidated" by some completely unrelated caller's more
-- recent refresh landing the same source back on the SAME citizenid by
-- coincidence -- see MintOnlinePlayerNonce's own doc comment). Everything
-- downstream of a successful resolve -- the Person screen, every
-- certify/grant/xp control on it -- keys on the resolved CITIZENID
-- exactly as it already did for the roster/"open by ID" entry points; a
-- server id is NEVER stored as, or substituted for, that key anywhere.
-- ======================================================================

local ONLINE_PLAYERS_ROW_CAP = 100 -- fixed, not config-driven (mirrors
-- PARTNERSHIP_HISTORY_LIMIT's own "small, fixed, no config knob" shape).
-- This list is built from an in-memory GetPlayers() scan, never a DB
-- query -- unlike ClampedMaxRosterRows/DEFAULT_MAX_ROSTER_ROWS, raising
-- this costs CPU/JSON-payload size only, never a slower query plan -- but
-- it stays bounded rather than unbounded: a 900-slot server's whole
-- population is not something an operator can usefully scroll anyway.
-- Past this cap, `truncated`/`truncatedMessage` below tell the operator
-- so, and how to narrow it -- the SAME search box the roster already
-- offers (matches by name, server id, or job, applied to the FULL
-- GetPlayers() scan before this cap is applied, so a search can still
-- find someone past the display cap even though a bare, unfiltered list
-- cannot show them all at once).
local ONLINE_PLAYERS_QUERY_MAX_LENGTH = 100 -- same defensive bound as MAX_ROSTER_QUERY_LENGTH

-- EPHEMERAL, SERVER-MEMORY ONLY -- never written to the database, never
-- sent to any client as anything but an opaque, single-use string. See
-- this section's own header "RECYCLED SOURCE IDS" for what this exists to
-- prevent. Deliberately keyed by the MINTED NONCE, not by `source` alone
-- -- a per-source (rather than per-mint) table would let one caller's
-- fresh tabletRequestOnlinePlayers call overwrite the bookkeeping a
-- DIFFERENT caller's still-open, stale list depends on, silently
-- "revalidating" that stale list's own click the instant the two
-- happened to agree on who currently holds that source -- exactly the
-- wrong-person failure this whole mechanism exists to close. One entry
-- per row, per list build, consumed (deleted) the moment
-- tabletResolveOnlinePlayer looks it up, whether that lookup succeeds or
-- fails.
local OnlinePlayerNonces = {} -- nonce(string) -> { source: number, citizenid: string, mintedAt: number(ms, GetGameTimer()) }
local ONLINE_PLAYER_NONCE_TTL_MS = 60000 -- generous relative to click latency, short relative to "an operator walked away and left the tablet open"
local onlinePlayerNonceSequence = 0

--- Deletes every nonce whose TTL has already elapsed. Called at the START
--- of every tabletRequestOnlinePlayers call so this table never grows
--- unbounded across a long session's worth of refreshes -- NOT on a
--- timer/interval of its own, matching this file's "no background work
--- beyond what a real request already triggers" convention elsewhere.
local function PruneExpiredOnlinePlayerNonces()
    local now = GetGameTimer()
    for nonce, record in pairs(OnlinePlayerNonces) do
        if (now - record.mintedAt) > ONLINE_PLAYER_NONCE_TTL_MS then
            OnlinePlayerNonces[nonce] = nil
        end
    end
end

--- @param sourceId number
--- @param citizenid string
--- @return string
local function MintOnlinePlayerNonce(sourceId, citizenid)
    onlinePlayerNonceSequence = onlinePlayerNonceSequence + 1
    local nonce = ('%d:%d:%d'):format(sourceId, onlinePlayerNonceSequence, GetGameTimer())
    OnlinePlayerNonces[nonce] = { source = sourceId, citizenid = citizenid, mintedAt = GetGameTimer() }
    return nonce
end

--- Cheap, in-memory job label for an ONLINE PlayerData.job -- deliberately
--- NOT ResolveJobGradeInfo (below): that function's own online-preferred/
--- offline-fallback pair exists to resolve a citizenid that might not be
--- online at all, which costs an extra GetPlayerByCitizenId lookup this
--- call site already has the answer to (this function is only ever called
--- from inside a GetPlayers() loop that already holds the live
--- PlayerData). Mirrors that function's own label precedence exactly
--- (Config.Departments[job.name].label, then job.label, then the bare
--- job.name) so the SAME job resolves to the SAME label whether shown
--- here or on the Person screen.
--- @param job table
--- @return string
local function JobLabelFromLiveJob(job)
    local dept = type(Config.Departments) == 'table' and Config.Departments[job.name]
    if type(dept) == 'table' and type(dept.label) == 'string' then return dept.label end
    if type(job.label) == 'string' then return job.label end
    return job.name
end

lib.callback.register('qbx_k9unit:server:tabletRequestOnlinePlayers', function(source, query)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller) then
        return { ok = false, error = 'not_authorized', message = SafeLocale('tablet.console_not_authorized') }
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    if type(query) ~= 'string' then query = '' end
    if #query > ONLINE_PLAYERS_QUERY_MAX_LENGTH then query = query:sub(1, ONLINE_PLAYERS_QUERY_MAX_LENGTH) end
    local needle = query:lower()

    PruneExpiredOnlinePlayerNonces()

    -- IN-MEMORY SCAN, NO DB ROUND TRIP AT ALL -- GetPlayers() is qbx_core's
    -- own live connected-session list, and every field below (name, job,
    -- HasK9Access) is resolved from data this process already holds in
    -- memory for a connected player, exactly like server/main.lua's own
    -- RefreshCertificationCache backfill loop over the same
    -- GetPlayers()/tonumber pattern. No maxRosterRows-style multiplier/cap
    -- pair is needed the way tabletRequestRoster has one: that exists
    -- there because ROSTER_FETCH_ABSOLUTE_CAP bounds a DB LIMIT clause
    -- BEFORE rows are fetched; here every currently-connected player is
    -- already fully in memory regardless, so filtering happens over the
    -- real, complete set and only the RESPONSE (not the work done to
    -- build it) is capped below.
    local candidates = {}
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local onlinePlayer = exports.qbx_core:GetPlayer(src)
            local job = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.job
            local citizenid = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.citizenid
            if type(job) == 'table' and type(citizenid) == 'string' then
                local name = ResolveDisplayName(citizenid)
                local jobLabel = JobLabelFromLiveJob(job)
                local hasK9Access = type(HasK9Access) == 'function' and HasK9Access(src) == true
                local matches = needle == ''
                    or name:lower():find(needle, 1, true) ~= nil
                    or tostring(src):find(needle, 1, true) ~= nil
                    or jobLabel:lower():find(needle, 1, true) ~= nil
                if matches then
                    candidates[#candidates + 1] = {
                        source = src,
                        citizenid = citizenid, -- SERVER-SIDE BOOKKEEPING ONLY -- stripped from every row below; see the nonce-minting loop's own comment.
                        name = name,
                        jobLabel = jobLabel,
                        hasK9Access = hasK9Access,
                    }
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.name == b.name then return a.source < b.source end
        return a.name < b.name
    end)

    local truncated = #candidates > ONLINE_PLAYERS_ROW_CAP
    local rows = {}
    local limit = math.min(#candidates, ONLINE_PLAYERS_ROW_CAP)
    for i = 1, limit do
        local candidate = candidates[i]
        rows[#rows + 1] = {
            source = candidate.source,
            name = candidate.name,
            jobLabel = candidate.jobLabel,
            hasK9Access = candidate.hasK9Access,
            -- OPAQUE, SINGLE-USE -- never a citizenid, never anything the
            -- client could use to identify this person outside this one
            -- round trip. See tabletResolveOnlinePlayer's own doc comment.
            nonce = MintOnlinePlayerNonce(candidate.source, candidate.citizenid),
        }
    end

    local result = { ok = true, rows = rows, truncated = truncated }
    if truncated then
        result.truncatedMessage = SafeLocale('tablet.online_players_truncated_notice', #rows)
    end
    return result
end)

--- Resolves ONE row from the online-players list (a server id) to the
--- citizenid it belonged to, freshly, AT THE MOMENT OF THIS CALL -- never
--- the citizenid a client might claim, and never trusted from a prior
--- response. See this section's own header "RECYCLED SOURCE IDS" for the
--- full reasoning `nonce` exists to close. Same audience as
--- tabletRequestOnlinePlayers (CallerHasConsoleAccess) -- a caller who
--- could not see the list in the first place must not be able to resolve
--- an arbitrary source id through this callback either.
lib.callback.register('qbx_k9unit:server:tabletResolveOnlinePlayer', function(source, targetSource, nonce)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    -- invalid_args BEFORE authorization/cooldown, matching
    -- tabletRequestPersonSummary's own established ordering immediately
    -- below (invalid_args -> authorization -> rate limit) -- a malformed
    -- payload from a modified client must never spend either budget.
    if type(targetSource) ~= 'number' or type(nonce) ~= 'string' or nonce == '' then
        return { ok = false, error = 'invalid_args' }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not CallerHasConsoleAccess(source, callerCitizenid, isHighCommandCaller) then
        return { ok = false, error = 'not_authorized', message = SafeLocale('tablet.console_not_authorized') }
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    PruneExpiredOnlinePlayerNonces()

    -- SINGLE-USE: deleted the instant it is looked up, success or not, so
    -- a click can never be replayed against the same list entry twice.
    local record = OnlinePlayerNonces[nonce]
    OnlinePlayerNonces[nonce] = nil

    if not record or record.source ~= targetSource then
        return { ok = false, error = 'stale_online_list', message = SafeLocale('tablet.online_player_stale') }
    end

    -- THE RECYCLED-SOURCE-ID GUARD ITSELF: `targetSource` is a currently-
    -- (or was-recently-) connected server id, reused by a brand-new
    -- connection the instant its previous holder drops. Re-resolving
    -- PURELY from `targetSource` here would silently hand back WHOEVER
    -- now holds that slot, not the specific person the operator saw and
    -- clicked when the list was drawn. `record.citizenid` is who occupied
    -- `targetSource` at the moment tabletRequestOnlinePlayers minted this
    -- nonce; this only succeeds if the CURRENT live occupant of that same
    -- source is STILL that same citizenid.
    local targetPlayer = exports.qbx_core:GetPlayer(targetSource)
    local liveCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not liveCitizenid or liveCitizenid ~= record.citizenid then
        return { ok = false, error = 'target_disconnected', message = SafeLocale('tablet.online_player_disconnected') }
    end

    return { ok = true, citizenid = liveCitizenid, name = ResolveDisplayName(liveCitizenid) }
end)

-- ======================================================================
-- CALLBACK 3 -- tabletRequestPersonSummary. Console audience, PLUS a
-- 'k9.certify'/'k9.givexp' holder acting on one already-known citizenid --
-- see CallerHasPersonAccess()'s own doc comment for why this callback
-- specifically (not tabletRequestRoster) is the one widened. Works for ANY
-- citizenid, online or offline (every read below is DB-authoritative,
-- never the online-only in-memory caches other files keep).
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestPersonSummary', function(source, targetCitizenId)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not CallerHasPersonAccess(source, callerCitizenid, isHighCommandCaller) then
        -- 'tablet.console_not_authorized' has landed in locales/en.json, so
        -- `message` is populated as this file's header always intended.
        -- SafeLocale() rather than a bare locale() call: this field is
        -- OPTIONAL per the JS contract (errorText() already falls back to
        -- a generic message for a bare 'not_authorized' error code), so a
        -- future rename/removal of this key must degrade to that same
        -- fallback instead of throwing out of this callback.
        return { ok = false, error = 'not_authorized', message = SafeLocale('tablet.console_not_authorized') }
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    local activePermSet = QueryActivePermissionSet(targetCitizenId)
    local xp, tierLabel = ResolveXpAndTierLabel(targetCitizenId)
    local handlerXp, handlerTierLabel = ResolveHandlerXpAndTierLabel(targetCitizenId)

    -- CATALOG-AWARE (see "PERMISSION-KEY CATALOG AWARENESS"
    -- section above ResolveEffectivePermissions for the full writeup this
    -- mirrors): candidate keys now come from AdminCapabilityCandidateKeys
    -- (the four shipped keys, always, UNION the live catalog's current
    -- keys, UNION anything `activePermSet` itself names outside the
    -- feature./block. namespace -- the last of which is what keeps a
    -- TOMBSTONED-but-still-held custom key from vanishing here the instant
    -- high command retires it, so it remains revocable). This builder
    -- itself is unchanged in one respect that matters: it still only ever
    -- reports a key TARGET holds an ACTUAL, active k9_permissions row for
    -- (`activePermSet[key] == true`) -- never a rank-qualification guess --
    -- exactly like before, for every key, shipped or custom.
    local permissions = {}
    for key in pairs(AdminCapabilityCandidateKeys(activePermSet)) do
        if activePermSet[key] == true then permissions[#permissions + 1] = key end
    end
    table.sort(permissions)

    return {
        ok = true,
        -- `exists` (see
        -- ResolvePlayerExists's own doc comment above for the full
        -- writeup): a REAL existence check, true only when qbx_core
        -- actually found a player row (online or offline) for this
        -- citizenid -- never guessed from every OTHER field happening to
        -- be empty. This is the field html/tablet.js's own
        -- personSummaryLooksLikeNoRecord() stopgap heuristic was written
        -- to be replaced by; that function's own doc comment names this
        -- exact shape (`target.exists`).
        target = { citizenid = targetCitizenId, name = ResolveDisplayName(targetCitizenId), exists = ResolvePlayerExists(targetCitizenId) },
        certifications = EnrichCertificationsWithGrantedByName(BuildCertificationsArray(targetCitizenId)),
        xp = xp,
        tierLabel = tierLabel,
        roleCatalog = type(ListRolesForDisplay) == 'function' and ListRolesForDisplay() or nil,
        roleXp = type(GetRoleXpForCitizen) == 'function' and GetRoleXpForCitizen(targetCitizenId) or nil,
        -- HANDLER LADDER (owner-directed progression pass). Carried
        -- ALONGSIDE the K9 pair above, never merged into it: the two are
        -- separate ladders on separate feature switches, and either can be
        -- nil while the other has a real value. null here means "this
        -- ladder is switched off", NOT zero -- a handler genuinely on 0 XP
        -- sends 0, and the UI must be able to tell those apart.
        handlerXp = handlerXp,
        handlerTierLabel = handlerTierLabel,
        -- Dog-character PIN (server/dogcharacter.lua): the breed this
        -- character is kept as permanently, or nil. Set/cleared from the
        -- tablet only (the /k9setdog family was removed).
        pinnedDogModel = type(GetPinnedDogCharacterModel) == 'function' and GetPinnedDogCharacterModel(targetCitizenId) or nil,
        permissions = permissions,
        -- Owner-directed "one screen shows everything about a person" feature
        -- (roster panel: cert+tier, rank, XP+tier, partnership, permissions).
        -- Both READ-ONLY, both nil-safe (never a guessed value) -- see
        -- ResolveJobGradeInfo/ResolvePartnershipInfo's own doc comments
        -- just above CALLBACK 1 for exactly what each does and does not do.
        job = ResolveJobGradeInfo(targetCitizenId),
        partnership = ResolvePartnershipInfo(targetCitizenId),
        -- `assignedK9Model` (for the Onboarding flow's
        -- new K9 Role step -- see html/tablet.js's own
        -- buildFlowOnboardK9RoleSummaryLine() doc comment): the ONE
        -- server-derived, model-independent-BY-NAME-ONLY signal of
        -- whether THIS TARGET (not the caller -- HasK9Role/isK9RoleForTarget
        -- both need a live `source` and so cannot answer for an offline
        -- target the way this whole callback already must, see
        -- ResolveJobGradeInfo/ResolvePartnershipInfo just above) currently
        -- holds an active k9_ped_assignments row. server/appearance.lua's
        -- GetAssignedK9Model was already written and exposed globally for
        -- exactly this "future consumer" (its own doc comment says so
        -- verbatim) and reads the SAME DB row online or offline, matching
        -- every other field in this response. A guided-flow summary must
        -- never re-derive "did the K9 role actually get applied" from a
        -- mutation's own claimed `ok:true` (THE HONESTY REQUIREMENT this
        -- whole PersonSummaryResult contract exists to satisfy) -- this
        -- field is what that re-derivation reads. string|nil; nil both
        -- when nothing is assigned AND when server/appearance.lua is
        -- absent (this file's standard `type(fn) == 'function'`
        -- soft-dependency convention -- degrades to "not shown", never an
        -- error).
        assignedK9Model = (type(GetAssignedK9Model) == 'function') and GetAssignedK9Model(targetCitizenId) or nil,
    }
end)

-- ======================================================================
-- CALLBACK 4 -- tabletRequestPersonFeatures. HIGH COMMAND ONLY -- re-
-- verified here regardless of what a client believes viewer.isHighCommand
-- to be.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestPersonFeatures', function(source, targetCitizenId)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    local activePermSet, permReadOk = QueryActivePermissionSet(targetCitizenId)
    local blockNamespaceUnreliable = BlockNamespaceUnreliable(permReadOk)
    local hasK9Access = ResolveTargetHasK9Access(targetCitizenId, activePermSet)
    -- DISPLAY-GAP FIX (this pass) -- the TARGET's OWN rank, not the
    -- viewing high-command caller's: soft dependency on
    -- server/permissions.lua's IsHighCommandBypassCitizenId, which itself
    -- resolves `false` for an OFFLINE target, unconditionally and by
    -- design (see that function's own doc comment) -- never "improved"
    -- here. No `expectedJobName` is passed: Config.Features abilities are
    -- not scoped to one department the way a specific certification tier
    -- is (HasK9Access/ResolveTargetHasK9Access just above are equally
    -- job-agnostic for the identical reason), so the target's own
    -- CURRENT job, whatever it is, is the only one that could ever be
    -- relevant here.
    local targetIsHighCommandBypass = type(IsHighCommandBypassCitizenId) == 'function'
        and IsHighCommandBypassCitizenId(targetCitizenId) == true

    return {
        ok = true,
        target = { citizenid = targetCitizenId, name = ResolveDisplayName(targetCitizenId) },
        features = BuildPersonFeaturesArray(hasK9Access, activePermSet, targetIsHighCommandBypass, blockNamespaceUnreliable),
    }
end)

-- ======================================================================
-- CALLBACK 5 (owner's mid-pass expansion) -- tabletAssignK9Role. Thin
-- wrapper over server/appearance.lua's ApplyK9PedRole -- see this file's
-- header "K9 ROLE ASSIGN / DE-ASSIGN / REVERT-TO-HUMAN" for the full
-- mapping. ApplyK9PedRole already re-verifies IsHighCommand internally
-- (via GrantPermission) and already accepts ANY Config.Peds entry -- this
-- wrapper adds no authorization logic and no appearance-mutation logic of
-- its own, only the return-shape translation client/tablet.lua's
-- AwaitServerCallback expects. Guarded with `type(fn) == 'function'` --
-- server/appearance.lua may not be present on every install (its own
-- feature surface is separate from CommandTablet's), so this degrades to
-- a clear 'not_available' rather than an uncaught error if it is ever
-- removed.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletAssignK9Role', function(source, targetCitizenId, modelName)
    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH
        or type(modelName) ~= 'string' or modelName == '' then
        return { ok = false, error = 'invalid_args' }
    end

    if type(ApplyK9PedRole) ~= 'function' then
        return { ok = false, error = 'not_available' }
    end

    local ok, outcome = ApplyK9PedRole(source, targetCitizenId, modelName)
    if ok then
        if outcome == 'persisted_offline' then
            return { ok = true, message = locale('appearance.apply_pending_offline') }
        end
        return { ok = true }
    end
    return { ok = false, error = outcome }
end)

-- ======================================================================
-- CALLBACK 6 (an owner-directed expansion) -- tabletRevertK9Ped. See this
-- file's header "K9 ROLE ASSIGN / DE-ASSIGN / REVERT-TO-HUMAN" for the
-- full "no unbounded trap" writeup: this is a TERMINATION path and must
-- NEVER be gated on the target still holding K9 access/certification --
-- the only gate here is the CALLER's own authorization (high command),
-- re-verified from `source` on every call, never a client-supplied flag.
-- ForceRevertK9Appearance is a soft dependency on server/appearance.lua
-- (not yet landed as of this file being written) -- guarded with
-- `type(fn) == 'function'` so this callback is registered (a real,
-- honest 'not_available' response) rather than absent entirely, and
-- activates automatically the moment that function ships, with zero
-- further edits needed here.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRevertK9Ped', function(source, targetCitizenId)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end

    if type(ForceRevertK9Appearance) ~= 'function' then
        return { ok = false, error = 'not_available' }
    end

    local ok, outcome = ForceRevertK9Appearance(source, targetCitizenId)
    if ok then return { ok = true } end
    return { ok = false, error = outcome }
end)

-- ======================================================================
-- DOG-CHARACTER PIN -- tabletPinDogCharacter / tabletUnpinDogCharacter.
-- "Keep this character as a dog permanently", independent of any
-- certification (server/dogcharacter.lua's header explains the pin vs
-- the certification-driven look). These replace /k9setdog, /k9removedog
-- and /k9dog -- all admin work is on the tablet now (owner's choice).
-- SetDogCharacter/RemoveDogCharacter re-check high command and rate-limit
-- themselves; this only validates the arguments and shapes the reply.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletPinDogCharacter', function(source, targetCitizenId, modelName)
    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH
        or type(modelName) ~= 'string' or modelName == '' then
        return { ok = false, error = 'invalid_args' }
    end
    if type(SetDogCharacter) ~= 'function' then return { ok = false, error = 'not_available' } end
    local ok, outcome = SetDogCharacter(source, targetCitizenId, modelName)
    if ok then return { ok = true } end
    if outcome == 'denied' then return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') } end
    return { ok = false, error = outcome }
end)

lib.callback.register('qbx_k9unit:server:tabletUnpinDogCharacter', function(source, targetCitizenId)
    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end
    if type(RemoveDogCharacter) ~= 'function' then return { ok = false, error = 'not_available' } end
    local ok, outcome = RemoveDogCharacter(source, targetCitizenId)
    if ok then return { ok = true } end
    if outcome == 'denied' then return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') } end
    return { ok = false, error = outcome }
end)

-- ======================================================================
-- CALLBACKS 7-9 -- THE PARTNERSHIPS TAB. Owner's own words, in two rounds:
-- "both the k9 and handler should be able to pull
-- up a list of there partners and levels etc in a tab... Past
-- partnerships matter too, not just the active one" -- then, refined --
-- "a partnership tab should be shown on all tablets as a tab as it
-- entails how many handlers a k9 has or how many k9s a handler has and
-- high command is a handler or a k9 and should have control over it also
-- but the partnership tab should show whos there partners." Three
-- callbacks, one shared row-builder:
--   tabletRequestMyPartnerships       -- CALLER's own history (CALLBACK 7)
--   tabletRequestPartnershipsForTarget -- high-command lookup of ANY
--     citizenid's history (CALLBACK 8) -- "high command... should have
--     control over it also," read side.
--   tabletForceEndPartnership          -- high-command-only teardown of a
--     TARGET's active partnership (CALLBACK 9) -- the "control" write
--     side, a thin wrapper over the EXISTING, already-tested
--     ForceBreakPartnershipForCitizenId (server/partnership.lua -- the
--     SAME function certification-revoke/department-change teardowns
--     already call; this is not a new teardown mechanism).
-- All three share TabletReadCooldown/TABLET_READ_COOLDOWN_MS where they
-- read (this file's own header "RATE LIMITING" -- 7/8 are the fifth and
-- sixth callers of that one shared bucket; 9 is a mutation, not a read,
-- so it spends nothing from that budget and owns its own 1500ms
-- PartnershipForceEndCooldown instead -- the same per-officer action
-- cooldown CALLBACK 5/6 get from server/appearance.lua's
-- AppearanceActionCooldown, which their delegates consume internally).
--
-- "ONE ACTIVE PARTNERSHIP PER CITIZENID, EITHER ROLE, AT A TIME" -- VERIFIED
-- (qa-tester/ad71ee3115acd466d's audit, this same pass), not assumed: the
-- two independent UNIQUE keys plus PartnershipEstablishMutex's own
-- pre-INSERT re-check (server/partnership.lua) hold this invariant with
-- no found race. So "how many handlers has this K9 had" is NEVER a live
-- concurrent count (always 0 or 1 active) -- it is the HISTORICAL row
-- count this callback already returns (k9_partnerships is append-only,
-- old rows never deleted), exactly matching the owner's own clarified
-- reading ("Past partnerships... is where the count comes from
-- historically"). html/tablet.js derives that count from `#partnerships`
-- (or the truncated notice below when it would undercount) -- this file
-- adds no separate COUNT query for it.
--
-- MERGE, NOT A NEW QUERY SHAPE: K9Store.Partner_GetHistoryByK9/ByHandler
-- (server/datastore.lua) are the SAME two accessors server/admin.lua's own
-- QueryPartnershipHistory already uses for the high-command audit console
-- -- one citizenid can never appear as BOTH k9_citizenid and
-- handler_citizenid on the SAME row (role is frozen at establishment, see
-- server/partnership.lua's own header), so a plain concat-then-sort-by-id
-- here needs no de-dup, unlike a de-normalized join would. Deliberately a
-- small, local, one-off sort (NOT server/admin.lua's own local
-- MergeSortedByIdDesc) -- that helper is `local` to admin.lua, not a
-- resource global, and promoting it purely to avoid a few lines of
-- duplication here was judged not worth touching that file.
--
-- "LEVEL" IS `tenure_bonus_tier_granted` AS-IS, A PLAIN NUMBER, not a
-- resolved title: server/tenure.lua's own milestone titles ("Bonded
-- Pair", ...) live behind that file's `local` ResolveMilestoneTitle,
-- reading Config.Partnership.TenureBonus.milestones -- reproducing that
-- resolution here would be a second copy of the same config-reading logic
-- to keep in sync. Instead, client/tablet.lua's own NUI callback handler
-- for 'tablet:requestMyPartnerships' (self only -- getPartnershipTenureProgress
-- has no target argument, so CALLBACK 8's admin lookup never gets this
-- enrichment) composes THIS result with the ALREADY-SHIPPED,
-- ALREADY-CLIENT-TRIGGERABLE 'qbx_k9unit:server:getPartnershipTenureProgress'
-- callback (server/tenure.lua) for the one active row's rich tier
-- title/next-milestone countdown -- see that file's own doc comment. A
-- past (ended) row's frozen `tenure_bonus_tier_granted` is still reported
-- here, verbatim, so a caller who lost a long-tenured partnership still
-- sees what tier it reached; html/tablet.js renders it as a plain "Tier
-- N" rather than inventing a title for a row this file cannot ask
-- tenure.lua about. NOT PRESENTED AS TAMPER-PROOF:
-- server/partnership.lua's own PairTenureSeed anti-farm guard
-- is disclosed as in-memory-only, reset by a resource restart -- this
-- file adds no wording implying `tenureTierGranted` is audit-grade, and
-- html/tablet.js is asked to do the same.
--
-- DURATION: `established_at_unix`/`ended_at_unix` (added to
-- K9Store.Partner_GetHistoryByK9/ByHandler, DB-mode via
-- UNIX_TIMESTAMP(), memory-mode via the pre-existing established_at_unix/
-- new ended_at_unix stamps) let html/tablet.js compute "how long this ran"
-- with plain arithmetic against Date.now()/1000 for a still-active row, or
-- the two stamps directly for an ended one -- never a date-string parse.
--
-- NAMES, OFFLINE-SAFE: `partnerName`/`endedByName` both go through this
-- file's own ResolveDisplayName -- confirmed offline-safe via
-- exports.qbx_core:GetOfflinePlayer, which matters MORE here than
-- anywhere else in this file: most of a citizenid's PAST partners are, by
-- definition, usually not the person currently holding the tablet, and
-- very often not online at all.
-- ======================================================================
local PARTNERSHIP_HISTORY_LIMIT = 25 -- fixed, not caller-influenced by CALLBACK 7 (which takes no query argument at all) or CALLBACK 8 (which takes only a citizenid, not a limit) -- generous for "everyone this citizenid has ever been partnered with," matching this file's other small fixed caps (e.g. MAX_ROSTER_QUERY_LENGTH above)

--- 'system:<reason>' sentinel decoding -- server/partnership.lua's own
--- documented `ended_by` shape (either the ending party's own citizenid,
--- or this sentinel for an automatic teardown). Passing the raw sentinel
--- through ResolveDisplayName would harmlessly fall back to echoing it
--- verbatim (it is not a real citizenid, so nothing resolves) -- this
--- gives html/tablet.js a clean boolean-ish signal instead so it never has
--- to string-match a Lua-side convention itself.
--- @param endedBy string?
--- @return string? systemReason -- the text after 'system:', or nil if `endedBy` is not that sentinel shape
local function EndedBySystemReason(endedBy)
    if type(endedBy) ~= 'string' then return nil end
    return endedBy:match('^system:(.+)$')
end

--- Shared by CALLBACK 7 (self) and CALLBACK 8 (high-command lookup of any
--- citizenid) -- identical shape either way, this file never gives an
--- admin a richer/different row shape than a caller sees for themselves.
--- @param citizenid string
--- @return table result -- { partnerships: table[], truncated: boolean }
local function BuildPartnershipRowsForCitizenId(citizenid)
    local asK9 = SafeStoreCall(K9Store.Partner_GetHistoryByK9, citizenid, PARTNERSHIP_HISTORY_LIMIT) or {}
    local asHandler = SafeStoreCall(K9Store.Partner_GetHistoryByHandler, citizenid, PARTNERSHIP_HISTORY_LIMIT) or {}

    local merged = {}
    for _, row in ipairs(asK9) do merged[#merged + 1] = row end
    for _, row in ipairs(asHandler) do merged[#merged + 1] = row end
    table.sort(merged, function(a, b) return (tonumber(a.id) or 0) > (tonumber(b.id) or 0) end)

    -- "You asked for everything, here is the most recent N" -- same
    -- disclosed-truncation discipline as tabletRequestRoster's own
    -- `truncated` field (this file's header), never a silently-cut count.
    local truncated = #merged > PARTNERSHIP_HISTORY_LIMIT
    if truncated then
        for i = #merged, PARTNERSHIP_HISTORY_LIMIT + 1, -1 do merged[i] = nil end
    end

    local rows = {}
    for _, row in ipairs(merged) do
        local isK9Role = row.k9_citizenid == citizenid
        local partnerCitizenid = isK9Role and row.handler_citizenid or row.k9_citizenid
        local systemReason = EndedBySystemReason(row.ended_by)
        rows[#rows + 1] = {
            id = row.id,
            partnerCitizenid = partnerCitizenid,
            partnerName = ResolveDisplayName(partnerCitizenid),
            role = isK9Role and 'k9' or 'handler',
            active = row.active == 1 or row.active == true,
            establishedAtUnix = tonumber(row.established_at_unix),
            endedAtUnix = tonumber(row.ended_at_unix),
            endedBySystemReason = systemReason,
            endedByName = (systemReason == nil and type(row.ended_by) == 'string' and row.ended_by ~= '') and ResolveDisplayName(row.ended_by) or nil,
            tenureTierGranted = tonumber(row.tenure_bonus_tier_granted) or 0,
        }
    end

    return { partnerships = rows, truncated = truncated }
end

lib.callback.register('qbx_k9unit:server:tabletRequestMyPartnerships', function(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    local isHighCommandCaller = type(IsHighCommand) == 'function' and IsHighCommand(source) == true
    if not isHighCommandCaller then
        local everyoneCanView = type(Config.FeatureControl) == 'table' and Config.FeatureControl.everyoneCanViewOwnRecord == true
        if not everyoneCanView then
            return { ok = false, error = 'not_authorized' }
        end
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    local featureEnabled = type(Config.Features) == 'table' and Config.Features.HandlerPartnership == true
    if not featureEnabled then
        return { ok = true, featureEnabled = false, partnerships = {}, truncated = false }
    end

    local result = BuildPartnershipRowsForCitizenId(citizenid)
    return {
        ok = true,
        featureEnabled = true,
        partnerships = result.partnerships,
        truncated = result.truncated,
    }
end)

-- ======================================================================
-- CALLBACK 8 -- tabletRequestPartnershipsForTarget. HIGH COMMAND ONLY --
-- "high command... should have control over it also," read half. Console
-- audience convention would be CallerHasConsoleAccess (isHighCommand OR
-- k9.audit), but this is deliberately narrower, isHighCommand ONLY,
-- matching CALLBACK 4/tabletRequestPersonFeatures's own reasoning (an
-- ordinary k9.audit-holding officer already sees this same history via
-- the Person screen's partnership section if they can open the console at
-- all; the owner's own "control over it" phrasing is about
-- HIGH COMMAND specifically, not every console-capable officer).
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletRequestPartnershipsForTarget', function(source, targetCitizenId)
    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end

    if not TabletReadCooldown.Consume(source, TABLET_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    local featureEnabled = type(Config.Features) == 'table' and Config.Features.HandlerPartnership == true
    if not featureEnabled then
        return { ok = true, featureEnabled = false, target = { citizenid = targetCitizenId, name = ResolveDisplayName(targetCitizenId) }, partnerships = {}, truncated = false }
    end

    local result = BuildPartnershipRowsForCitizenId(targetCitizenId)
    return {
        ok = true,
        featureEnabled = true,
        target = { citizenid = targetCitizenId, name = ResolveDisplayName(targetCitizenId) },
        partnerships = result.partnerships,
        truncated = result.truncated,
    }
end)

-- ======================================================================
-- CALLBACK 9 -- tabletForceEndPartnership. HIGH COMMAND ONLY -- the
-- "control over it" write half. Thin wrapper, exactly like CALLBACK 5/6
-- above: adds no authorization or teardown logic of its own beyond
-- re-verifying IsHighCommand fresh from `source` (never a client-supplied
-- flag, THE SECURITY RULE) and delegates the actual teardown to the
-- EXISTING, already-tested ForceBreakPartnershipForCitizenId
-- (server/partnership.lua -- the same function certification-revoke and
-- department-change already call for an automatic teardown; this is that
-- SAME code path, not a second one). `reason` is a plain, non-secret
-- string this file owns ('admin_forced_from_tablet') -- client/partnership.lua's
-- own partnershipEnded handler now has a DEDICATED sentence for exactly
-- this tag (WORKFLOW CLARITY FIX, that file's own doc comment: the old
-- generic-%s-template fallback used to show this raw tag verbatim --
-- "Partnership ended (admin_forced_from_tablet)." -- to whichever party
-- was online, which is not a readable notification). Add a matching
-- branch there (and a locales/en.json key) if this file ever mints a
-- second reason string of its own.
-- ======================================================================
lib.callback.register('qbx_k9unit:server:tabletForceEndPartnership', function(source, targetCitizenId)
    if type(targetCitizenId) ~= 'string' or targetCitizenId == '' or #targetCitizenId > MAX_CITIZENID_LENGTH then
        return { ok = false, error = 'invalid_args' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end

    -- The officer making the call. Resolved BEFORE anything is changed: an
    -- action that ends two other players' partnership has to be
    -- attributable, so if we cannot say who is doing it we do not do it.
    local Player = exports.qbx_core:GetPlayer(source)
    local actorCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(actorCitizenid) ~= 'string' or actorCitizenid == '' then
        return { ok = false, error = 'not_authorized', message = locale('common.unable_to_resolve_citizenid') }
    end

    -- After the authorization check, so someone who is refused anyway
    -- cannot burn a legitimate officer's cooldown -- the key is the
    -- caller's own source regardless, but refusing first keeps the
    -- ordering the same as this file's other gated handlers.
    if not PartnershipForceEndCooldown.Consume(source, PARTNERSHIP_FORCE_END_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    if type(ForceBreakPartnershipForCitizenId) ~= 'function' then
        return { ok = false, error = 'not_available' }
    end

    -- NO PRE-CHECK VIA GetActivePartnerCitizenId HERE, DELIBERATELY: that
    -- accessor reads server/partnership.lua's ONLINE-ONLY in-memory cache
    -- (see that file's own doc comment) and would wrongly report
    -- "not_partnered" for an offline target who actually has an active row
    -- -- exactly the trap this file's own ResolvePartnershipInfo above
    -- already avoids by using the DB-authoritative K9Store.Partner_GetActiveRowByParty
    -- instead. ForceBreakPartnershipForCitizenId already performs that
    -- exact DB-authoritative lookup internally (DoBreakPartnership's own
    -- SELECT) and returns `false` cleanly when there is truly no active
    -- row -- this callback trusts that single, already-correct answer
    -- rather than re-deriving a second, offline-unsafe one.
    local ended = ForceBreakPartnershipForCitizenId(targetCitizenId, 'admin_forced_from_tablet', actorCitizenid)
    if not ended then
        return { ok = false, error = 'not_partnered' }
    end
    return { ok = true }
end)
