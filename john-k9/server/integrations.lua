--[[
    john-k9/server/integrations.lua

    EXTERNAL-SYSTEM INTEGRATION SURFACE -- the seam this resource offers to
    dispatch, MDT, evidence, jail, phone, billing, or any other operator-run
    system, KNOWN OR UNKNOWN, per DEVELOPER_REFERENCE.md Part A §7 ("K9-down
    dispatch integration hook") and Part B §2/§3 ("Dispatch integration" /
    "MDT / evidence integration"). Read those three sections before touching
    this file.

    ======================================================================
    THE HARD CONSTRAINT THIS FILE IS BUILT UNDER: every server running this
    resource may run a DIFFERENT, possibly custom-built, possibly
    not-yet-written dispatch/MDT/ambulance/jail/phone/billing/evidence
    system. This file therefore never names, requires, `exports.<name>:...`
    calls, or `GetResourceState('<name>')`-branches on any specific
    third-party resource -- not even as a "sensible default." See DESIGN
    PRINCIPLES near the bottom of this header for how that constraint shapes
    every choice below.

    ======================================================================
    OUTBOUND vs. INBOUND -- the two, and only two, integration shapes this
    resource uses, and why a third shape (a per-hook `{ event = '...',
    export = '...', enabled = bool }` config table) was considered and
    rejected:

    OUTBOUND (a fact THIS resource announces -- "a K9 went down", "a search
    found contraband", "a cert was granted") -- a plain `TriggerEvent` on the
    stable `john-k9:events:*` namespace server/exports.lua's header
    documents, with ZERO config surface. Any resource -- dispatch, MDT, a
    Discord bridge, a homebrew logger, something that does not exist yet --
    reacts by writing exactly one `AddEventHandler('john-k9:events:...',
    function(...) ... end)`, from documentation alone, with no coupling to
    this resource's internals and no possibility of ever seeing an error
    thrown by a handler this resource doesn't know exists. This is already
    how six events work today (server/exports.lua's EVENT CONTRACT) and this
    file adds a seventh (k9Down) the identical way. A `{ event = '...',
    export = '...', enabled = bool }`-shaped config table for THIS direction
    would be strictly WORSE, not merely unnecessary: it would let an
    operator "rename" the event we fire (a new place to typo, and a reason a
    listener written straight from this file's docs would silently stop
    matching), and an `export` variant would mean calling into exactly ONE
    named resource -- the single-integration assumption this whole file
    exists to forbid. `TriggerEvent` already IS the any-number-of-listeners,
    zero-coupling primitive; wrapping it in config changes nothing for the
    better and adds a real footgun.

    INBOUND (a fact THIS resource needs FROM an operator's own system --
    "is this player wanted", "is this player downed") -- a bare
    `function(...) -> value` Config field, nil by default, called through
    pcall, FAILS CLOSED on error or absence. Already shipped twice, not
    invented here: `Config.Combat.WantedStatusCheckOverride` and
    `Config.Combat.PropDragging.IsPlayerDownedOverride`. Neither hook this
    file adds needs to ask an operator's own system anything, so this file
    introduces NO new inbound config -- it is pure OUTBOUND, which is a
    deliberate reflection of what Part A §7 / Part B §2 / §3 actually need,
    not an oversight. If a genuine future hook ever needs an answer FROM an
    external system, follow this exact shape (bare function, nil default,
    pcall, fail closed) rather than inventing a third one.

    ======================================================================
    WHAT'S ALREADY DONE, NOT DUPLICATED HERE (verified by direct read of
    server/exports.lua's EVENT CONTRACT and config.lua before writing a
    single line of this file):
    - Part B §2's OUTBOUND half ("a completed contraband search... fires a
      dispatch call") -- already covered by
      'john-k9:events:searchCompleted' (server/exports.lua EVENT
      CONTRACT #5, wired in server/search.lua's LogSearchAttempt).
    - Part B §2's INBOUND half (asking a real dispatch/wanted system instead
      of guessing off metadata.wanted) -- already covered by
      `Config.Combat.WantedStatusCheckOverride` (config.lua, consumed by
      server/combat.lua's IsPlayerWantedEligible).
    - Part B §3's certification half ("MDT relevance" for grant/revoke) --
      already covered by 'john-k9:events:certificationGranted' /
      'john-k9:events:certificationRevoked' (EVENT CONTRACT #1/#2, wired
      in server/certifications/).
    - Part B §5's ambulance/laststand half -- already covered by
      `Config.Combat.PropDragging.IsPlayerDownedOverride`, per that config
      field's own comment ("Reuses ... rather than adding its own").
    None of the above needed a single line changed here -- listed here so a
    reader of THIS file (the one place someone will look for "the
    integration surface") does not go hunting for something that already
    shipped under a different file's byline.

    ======================================================================
    RECOMMENDED, NOT APPLIED HERE (server/search.lua is not edited by this
    file): 'john-k9:events:searchCompleted''s payload (searcherCitizenid,
    searcherJob, targetType, result, totalWeight?, alertTier?) carries no
    identifier for WHAT was searched -- an MDT wanting to attach a `found`
    result to a real case/evidence record (Part B §3's actual stated goal,
    "turns 'the K9 found drugs' into an actual case artifact") cannot do
    that from this payload alone. Both missing values (`plateOrNil`,
    `targetCitizenidOrNil`) are ALREADY local variables in scope at
    server/search.lua's own
    `FireOutboundEvent('john-k9:events:searchCompleted', ...)` call site
    inside LogSearchAttempt -- this would be a strictly additive two-argument
    change (MINOR per server/exports.lua's own versioning posture; never
    reordering or removing an existing argument), not a redesign. Left
    unapplied here since it requires editing server/search.lua; noted here
    so the gap stays visible rather than being silently reopened as "new"
    by a future audit.

    ======================================================================
    K9-DOWN DISPATCH HOOK (DEVELOPER_REFERENCE.md Part A §7, THIS FILE's actual
    new logic) -- 'john-k9:events:k9Down'.

    WHY A SELF-CONTAINED POLL, NOT A HOOK INSIDE server/wellbeing.lua'S
    EXISTING TickWellbeing LOOP: that loop already iterates every online K9
    once per Config.Wellbeing.tickIntervalMs -- a textbook
    "add one call at an existing success path." server/wellbeing.lua is not
    edited by this file. Part A §7's own text explicitly names the
    alternative used here ("doable even earlier off raw GetEntityHealth
    polling if wanted sooner") -- this is that alternative, not a shortcut
    taken without grounds. Flagged as a genuine, disclosed future
    consolidation opportunity: a future edit to server/wellbeing.lua could
    fold this file's detection into that shared tick loop and delete this
    file's own thread, with no change to the event contract itself.

    DETECTION SHAPE, mirroring server/wellbeing.lua's own
    PED_DEAD_HEALTH_THRESHOLD / MIN_DEATH_EPISODE_DURATION_MS pattern (same
    file) rather than inventing an unrelated one: a raw native-health read,
    edge-triggered (fires at most once per continuous at/below-threshold
    episode, never once per poll tick), with a minimum qualifying duration
    so an ordinary combat graze healed a moment later never fires a dispatch
    alert. See Config.K9DownDispatch below for the exact tuning values.

    WHO COUNTS: a currently-connected player whose live ped model is a
    configured K9 model (IsConfiguredK9Model, server/certifications/) OR
    who holds the decoupled K9 ROLE (HasK9Role, server/appearance.lua --
    K9 role/model decoupling) on a model neither of those recognizes
    (a human, a custom streamed ped), AND who currently has K9 access
    (HasK9Access, server/certifications/) -- i.e. a real, on-duty,
    certified handler's K9, not merely anyone who happens to be wearing a
    dog skin, and not merely anyone who bypasses HasK9Access without
    actually being the K9 (a high-command tester, or an officer above
    Config.Departments' autoAccessGrade threshold, neither of which
    HasK9Role recognizes). IsConfiguredK9Model/HasK9Access are
    resource-global functions from server/certifications/, called
    directly with no runtime existence guard: unlike a genuinely optional
    soft dependency (a different feature file that might be removed or
    whose flag might be off), certifications.lua is this resource's own
    permission-system root and is always present, loaded well before this
    file (fxmanifest.lua's own server_scripts order), matching every other
    same-resource, same-load-time caller of these two. HasK9Role IS guarded
    with `type(...) == 'function'`, matching every other site widened the
    same way (server/main.lua's CheckLeashEligibility has the fullest
    writeup on why).

    PAYLOAD: 'john-k9:events:k9Down' (source: number, citizenid: string,
    jobName: string, coords: vector3, health: number). `source` is the
    live, currently-connected server id at the moment of firing -- a
    listener that wants to act on it (e.g. TriggerClientEvent a nearby
    unit) should treat it exactly as any other TriggerEvent payload: a
    hint, not a guarantee the source is still connected by the time the
    listener's own handler runs. `coords` is included deliberately, unlike
    this resource's other outbound events -- a dispatch alert is the one
    integration in this whole contract for which a map location is the
    entire point (an "Officer K9 Down" board entry with no location is not
    useful), so this one payload carries it while the others correctly do
    not manufacture a location need they don't have.

    NOT IN SCOPE: a corresponding "recovered"/"cleared" event. Nothing in
    Part A §7 asks for one, and this resource's own minimalism convention
    ("detection only, never enforcement") argues against announcing
    something nobody asked for. A dispatch resource that wants a
    "cleared" concept can already infer one from its own timeout, the same
    way a real dispatch board ages out a stale call.
    ======================================================================

    DESIGN PRINCIPLES (mirrors server/exports.lua's, restated for the
    boundary this file specifically guards):
    1. RE-DERIVE, NEVER TRUST. Every value in the k9Down payload is read
       fresh, server-side, at the moment of firing -- never a client claim.
    2. FAIL CLOSED, NEVER THROW ACROSS THE RESOURCE BOUNDARY.
       FireOutboundEvent (server/events.lua, shared across every file that
       fires a `john-k9:events:*` event) pcall-wraps the TriggerEvent
       call -- a misbehaving listener's own AddEventHandler throwing can
       never unwind back into this file's own poll thread. This used to be
       this file's own fifth independent copy of that six-line helper --
       that has since been consolidated; see server/events.lua's header for
       the full extraction writeup.
    3. ABSENCE IS A CLEAN NO-OP. With Config.Features.K9DownDispatch false
       (or absent), this file starts no thread, allocates no table, and
       calls TriggerEvent zero times -- a server with no dispatch resource
       listening sees zero errors and zero log spam, identically whether the
       flag is on or off, since TriggerEvent-ing to zero registered handlers
       is itself already a documented no-op in FXServer.
    ======================================================================
]]

if not Config.Features.K9DownDispatch then return end

-- CONFIG-SAFETY GUARD -- run at this file's own LOAD time, NOT deferred into
-- an onResourceStart handler (server/certifications/'s own header gives
-- the identical reasoning for the identical structural reason): the
-- K9DownFireCooldown construction a few lines below this guard calls
-- NewCooldown(...) immediately, at this file's own load time -- by the time
-- any onResourceStart handler could run, that call has already executed.
-- config.lua is a shared_script, loaded in full before any server_scripts
-- file (this one included) starts executing, so Config already holds its
-- real, final values by the time this line runs -- not a load-order gamble.
if type(Config.K9DownDispatch) ~= 'table' then
    -- CLAMP AND WARN, NOT ASSERT (see server/cooldowns.lua's header
    -- ADDENDUM and this block's own comment below for the full reasoning).
    -- USED TO be a hard `assert` here on the theory that there was "nothing
    -- sensible to clamp/substitute for the whole table missing" -- that
    -- theory doesn't hold up: substituting an empty table lets every one of
    -- the per-field resolvers immediately below fall back to its own
    -- already-established default, exactly as if an operator had left each
    -- field individually blank, instead of aborting this file's load
    -- (K9DownFireCooldown's construction, PollK9Health, the maintenance
    -- thread, and this file's own playerDropped cleanup) over a missing
    -- table.
    --
    -- Assigned back onto the GLOBAL Config.K9DownDispatch (not just a local
    -- variable) so this stays a genuine TABLE REFERENCE, matching
    -- server/runtimecontrol.lua's own documented expectation for this exact
    -- field ("`local tuning = Config.K9DownDispatch` is a TABLE REFERENCE,
    -- not a copy") -- a high-command operator using the tablet's live
    -- runtime tuning for K9DownDispatch.* must still reach the same table
    -- this file reads from, even after this substitution.
    print(
        '[John-K9] WARNING: Config.Features.K9DownDispatch is true but Config.K9DownDispatch is missing or ' ..
        'not a table -- using this file\'s own built-in defaults (healthThreshold=100, minDurationMs=3000, ' ..
        'pollIntervalMs=2000, reFireCooldownMs=30000) for every field it would have set. Add the settings ' ..
        'table back to config.lua.'
    )
    Config.K9DownDispatch = {}
end
local tuning = Config.K9DownDispatch

-- CLAMP AND WARN, NOT ASSERT (see server/cooldowns.lua's header ADDENDUM:
-- "does an operator's config.lua edit alone... reach this value? If yes it
-- must be clamped and warned about, never asserted and aborted").
-- healthThreshold/minDurationMs/pollIntervalMs below USED TO be three
-- separate hard `assert`s here -- each one correctly diagnosing a real risk
-- (a bad number would make every online K9 read as permanently
-- down/never down, or poll needlessly tight/throw in Wait()) but with the
-- wrong remedy: an uncaught error thrown from THIS FILE's own top-level
-- chunk aborts server/integrations.lua's load from that line onward --
-- taking K9DownFireCooldown's own construction, PollK9Health, the
-- maintenance CreateThread, and this file's own playerDropped cleanup down
-- with it, over one operator typo. reFireCooldownMs two lines below this
-- comment (K9DownFireCooldown's own construction) was already migrated to
-- ResolveConfiguredThresholdMs -- these three siblings were missed only
-- because they never reach NewCooldown at all (healthThreshold/
-- minDurationMs are pure comparison values, pollIntervalMs feeds Wait()
-- directly), not because the risk was any different.
--
-- healthThreshold and pollIntervalMs are each resolved individually --
-- neither has a relationship to any other field in this block.
-- pollIntervalMs is a genuine duration (feeds Wait() directly, no
-- legitimate non-positive meaning), so it reuses
-- ResolveConfiguredThresholdMs unchanged. healthThreshold is NOT a
-- duration -- it is a raw GetEntityHealth(ped) comparison value -- so it
-- gets its own bespoke clamp-and-warn below rather than borrowing
-- ResolveConfiguredThresholdMs's cooldown-specific warning text ("does NOT
-- mean 'no cooldown'... permanently block the guarded action"), which would
-- mislead an operator reading a healthThreshold warning.
--
-- minDurationMs is deliberately NOT run through ResolveConfiguredThresholdMs
-- either, for a different reason: IsValidThreshold (which backs
-- ResolveConfiguredThresholdMs) rejects 0, but 0 is an explicitly
-- LEGITIMATE value here (config.lua's own comment: "0 disables it", i.e.
-- "fire on the very first qualifying poll tick, no debounce") -- routing it
-- through ResolveConfiguredThresholdMs would silently replace every
-- operator's valid `minDurationMs = 0` with the 3000ms fallback and warn
-- about it, training operators to ignore a warning that fires on a
-- perfectly good value. Its own bespoke resolver below accepts >= 0.
--- @param value any
--- @return boolean
local function IsValidHealthThreshold(value)
    return type(value) == 'number' and value == value and value > 0
end

--- @param value any
--- @return boolean
local function IsValidMinDurationMs(value)
    return type(value) == 'number' and value == value and value >= 0
end

--- Same clamp-and-warn shape as server/cooldowns.lua's
--- ResolveConfiguredThresholdMs, generalized here for a Config number that
--- is not itself a cooldown/duration threshold (so IsValidThreshold's
--- strictly-positive rule either doesn't apply to its meaning, as with
--- healthThreshold, or doesn't apply to its VALID RANGE, as with
--- minDurationMs's legitimate 0). Never errors; prints one warning naming
--- the exact key, the bad value found, and the fallback substituted, then
--- returns a value guaranteed to satisfy `isValidFn`.
--- @param value any
--- @param fallback number -- must itself satisfy isValidFn -- an invalid fallback is this call site's own bug, matching ResolveConfiguredThresholdMs's identical fallback-validation posture
--- @param keyName string
--- @param isValidFn fun(v: any): boolean
--- @param requirementText string -- human-readable requirement, used only in the printed warning
--- @return number
local function ResolveConfiguredNumber(value, fallback, keyName, isValidFn, requirementText)
    if not isValidFn(fallback) then
        error(('[John-K9] ResolveConfiguredNumber called with an invalid fallback (%s) for %s -- the ' ..
            'fallback is a hardcoded call-site literal, not an operator-editable value, so this is a ' ..
            'programmer bug at the call site, not a Config problem.'):format(tostring(fallback), keyName), 2)
    end
    if isValidFn(value) then
        return value
    end
    print(('[John-K9] %s is %s (found: %s). Using the built-in fallback of %s instead so this feature keeps ' ..
        'working while the config is fixed -- find %s in config.lua and correct it.')
            :format(keyName, requirementText, tostring(value), tostring(fallback), keyName))
    return fallback
end

tuning.healthThreshold = ResolveConfiguredNumber(
    tuning.healthThreshold, 100, 'Config.K9DownDispatch.healthThreshold', IsValidHealthThreshold,
    'missing or not a positive number -- compared directly against GetEntityHealth(ped) in this file\'s own ' ..
    'poll loop; a non-positive or NaN value would make every online K9 read as permanently down (or never ' ..
    'down at all)')

tuning.minDurationMs = ResolveConfiguredNumber(
    tuning.minDurationMs, 3000, 'Config.K9DownDispatch.minDurationMs', IsValidMinDurationMs,
    'missing or not a non-negative number -- 0 is a legitimate choice ("fire on the very first qualifying ' ..
    'poll tick, no debounce"), but nil/a string/NaN/negative is not')

tuning.pollIntervalMs = ResolveConfiguredThresholdMs(
    tuning.pollIntervalMs, 2000, 'Config.K9DownDispatch.pollIntervalMs')

-- reFireCooldownMs is intentionally NOT re-validated here beyond what
-- ResolveConfiguredThresholdMs(tuning.reFireCooldownMs, ...) below already
-- enforces on its own (see K9DownFireCooldown's own declaration a few lines
-- down) -- duplicating that check here would only race it.

--- MOVED to server/events.lua: this file's header's own DESIGN PRINCIPLE 2
--- deferred this exact consolidation to a future cross-file cleanup; that
--- cleanup has now happened. This file's own copy, byte-for-byte identical
--- to the five others that existed alongside it, is now the single shared
--- resource-global implementation in that file. See server/events.lua's
--- header for the full extraction writeup. The one call site below is
--- unchanged: same event name, arguments, and firing condition.

-- Per-source candidate-episode state -- see this file's header "DETECTION
-- SHAPE" for the episode/edge-trigger design this backs.
-- K9DownState[source] = { candidateDownSince = <GetGameTimer() ms, 0 = not
--   currently in a candidate episode>, firedThisEpisode = boolean }
-- Deliberately NOT a server/cooldowns.lua NewCooldown/NewMutex instance --
-- same "different shape entirely, do not force it onto the cooldown
-- constructors" reasoning server/search.lua's own ContrabandXpState gives
-- for its own bespoke table: this tracks an episode START TIME and a fired
-- FLAG, not a single "has enough time elapsed" instant, so it does not fit
-- either constructor. Cleared per-source on disconnect below -- a
-- disconnected K9 has nothing further to report.
local K9DownState = {}

AddEventHandler('playerDropped', function()
    K9DownState[source] = nil
end)

-- Flat per-source cooldown on the FIRE itself (not the detection) -- a
-- backstop against a K9 flapping across the threshold boundary faster than
-- minDurationMs alone would filter (e.g. a heal landing exactly mid-episode
-- and a re-injury moments later), independent of the episode/edge-trigger
-- logic above. Mirrors this resource's own established "flat per-source
-- cooldown, a real server/cooldowns.lua tracker, never a hand-rolled table"
-- convention. NewCooldown's own constructor guard
-- (AssertValidDefaultThreshold) already errors loudly at this exact line if
-- tuning.reFireCooldownMs is not a valid positive number -- see the CONFIG-
-- SAFETY GUARD comment above for why that is deliberately relied on here
-- rather than re-checked.
-- reFireCooldownMs is resolved through ResolveConfiguredThresholdMs, NOT read
-- raw. The assert block above names this field in its message but never
-- actually validated it, so a plain `reFireCooldownMs = 0` -- the most
-- natural thing an operator types for "no cooldown" -- reached NewCooldown(0),
-- which errors at file-load time and takes PollK9Health and its CreateThread
-- loop down with it. K9-down dispatch would then be silently dead for the
-- rest of that server's uptime behind one console line. Clamp and warn, the
-- same as the other eleven configured-threshold sites.
local K9DownFireCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    tuning.reFireCooldownMs, 30000, 'Config.K9DownDispatch.reFireCooldownMs'))
K9DownFireCooldown.RegisterPlayerDropped()

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- header documents the 4-step resolution; step 1, Config.Features.K9DownDispatch,
-- is already this file's own top-of-file gate above. Mirrors
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId shape
-- verbatim (that file's own header says to read it before writing a
-- variant). A block here suppresses the ANNOUNCEMENT of a specific K9's own
-- down episode (e.g. a training/test account nobody wants paging real
-- dispatch) -- it never affects detection/state tracking for anyone else.
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsK9DownDispatchPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.K9DownDispatch') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.K9DownDispatch == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.K9DownDispatch') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- One poll pass over every currently-connected player -- see this file's
--- header "WHO COUNTS" / "DETECTION SHAPE" for the full design this
--- implements.
local function PollK9Health()
    local now = GetGameTimer()

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local ped = GetPlayerPed(src)
            if ped == 0 then
                -- Not actually a live, spawned player ped right now (still
                -- loading in, or GetPlayers() briefly stale) -- clear any
                -- stale episode state rather than let a later reconnect
                -- inherit an unrelated old episode.
                K9DownState[src] = nil
            -- PERFORMANCE (this is a per-tick, every-connected-player poll,
            -- not a one-off authorization check): HasK9Access(src) is
            -- checked FIRST and short-circuits the `and` below for the
            -- (overwhelming majority, on any real server) of connected
            -- players who have no K9 access at all -- IsConfiguredK9Model
            -- is a cheap hash compare either way, but HasK9Role can fall
            -- through to a real MySQL read (server/appearance.lua's
            -- IsCertifiedK9ForJob) when its own in-memory permission-cache
            -- check misses, and that must never run once per connected
            -- player per poll tick. Ordering this OTHER way (role/model
            -- check first) would run that DB-capable fallback against
            -- every non-K9 player on the server, every tick -- exactly the
            -- N+1-shaped cost this resource's own HasK9Access ordering
            -- (permission-cache bypass checked before any DB-touching
            -- branch) already avoids elsewhere.
            elseif not (HasK9Access(src) and (IsConfiguredK9Model(GetEntityModel(ped)) or (type(HasK9Role) == 'function' and HasK9Role(src)))) then
                -- Not currently a real, on-duty, certified K9 (WHO COUNTS
                -- above) -- clear any stale episode so a K9 who lost
                -- certification or changed model mid-episode cannot later
                -- fire off a health reading taken before that change.
                K9DownState[src] = nil
            else
                local health = GetEntityHealth(ped)
                local state = K9DownState[src]
                if not state then
                    state = { candidateDownSince = 0, firedThisEpisode = false }
                    K9DownState[src] = state
                end

                if health <= tuning.healthThreshold then
                    if state.candidateDownSince == 0 then
                        state.candidateDownSince = now
                    end

                    if not state.firedThisEpisode and (now - state.candidateDownSince) >= tuning.minDurationMs then
                        if K9DownFireCooldown.Consume(src) then
                            local Player = exports.qbx_core:GetPlayer(src)
                            local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
                            local jobName = Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.name
                            if citizenid and jobName then
                                -- PER-PERSON FEATURE CONTROL -- see
                                -- IsK9DownDispatchPermittedForCitizenId above.
                                -- Checked here rather than before
                                -- K9DownFireCooldown.Consume above: this is a
                                -- passive, server-driven detection poll, not a
                                -- player-issued request, so there is no
                                -- attacker who benefits from forcing a cooldown
                                -- burn by controlling when this fires --
                                -- re-ordering would only mean re-resolving
                                -- Player/citizenid/jobName on every poll tick a
                                -- blocked K9 stays down, for no behavioral
                                -- benefit. Regardless of the outcome below,
                                -- this K9's own episode is marked fired so a
                                -- block suppresses the announcement without
                                -- being retried every poll tick for the rest
                                -- of this same down episode.
                                state.firedThisEpisode = true

                                if IsK9DownDispatchPermittedForCitizenId(citizenid) then
                                    local coords = GetEntityCoords(ped)
                                    FireOutboundEvent('john-k9:events:k9Down', src, citizenid, jobName, coords, health)

                                    -- CONVENIENCE LAYER, PURELY ADDITIVE -- see
                                    -- shared/compat/dispatch.lua's own header
                                    -- for the full contract; this is the exact
                                    -- call that file documents for wiring this
                                    -- in, placed immediately AFTER (never
                                    -- instead of) the FireOutboundEvent call
                                    -- above so BOTH fire from the SAME
                                    -- detection episode. This resource's own
                                    -- custom/off-the-shelf dispatch that
                                    -- listens ONLY for the plain
                                    -- 'john-k9:events:k9Down' event above
                                    -- keeps working with ZERO setup either way
                                    -- -- K9Compat.Get('dispatch').Alert(...) is
                                    -- a safe no-op (returns false, sends
                                    -- nothing) whenever no supported
                                    -- off-the-shelf dispatch is detected (see
                                    -- core.lua's BuildNoOpStub/BuildSafeAdapter
                                    -- for why this can never throw into this
                                    -- poll thread), so removing this one call
                                    -- would change nothing about the line
                                    -- above it. `title` is a plain string, not
                                    -- a locale() call, per dispatch.lua's own
                                    -- header LOCALE NOTE. Guarded the same way
                                    -- every other K9Compat.Get('framework')
                                    -- call in this resource is -- a
                                    -- missing K9Compat (e.g. shared/compat/
                                    -- core.lua not yet loaded/registered for any
                                    -- reason) degrades to "this convenience
                                    -- layer did nothing this poll tick," never a
                                    -- thrown error that could take down this
                                    -- poll thread's own pcall wrapper's caller.
                                    if type(K9Compat) == 'table' and type(K9Compat.Get) == 'function' then
                                        K9Compat.Get('dispatch').Alert({
                                            code     = 'k9_down',
                                            title    = 'K9 Unit Down',
                                            message  = ('A K9 unit (%s) has gone down and needs assistance.'):format(jobName),
                                            coords   = coords,
                                            jobs     = { jobName },
                                            priority = 0,
                                        })
                                    end
                                end
                            end
                            -- else: a transient exports.qbx_core:GetPlayer
                            -- resolution miss -- firedThisEpisode stays
                            -- false, so the very next poll tick (while
                            -- health is still <= threshold) tries again;
                            -- the fire cooldown above was already consumed
                            -- though, so a genuinely persistent resolution
                            -- failure is still bounded by
                            -- reFireCooldownMs, not retried every single
                            -- poll tick forever.
                        end
                        -- else: still within reFireCooldownMs of a PRIOR
                        -- fire (a different earlier episode, or this same
                        -- one's own earlier attempt) -- firedThisEpisode
                        -- stays false, so this retries on the very next
                        -- poll tick once the cooldown clears, rather than
                        -- permanently giving up on reporting a K9 that is
                        -- STILL down right now.
                    end
                else
                    state.candidateDownSince = 0
                    state.firedThisEpisode = false
                end
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(tuning.pollIntervalMs)
        local ok, err = pcall(PollK9Health)
        if not ok then
            print(('[John-K9] K9-down dispatch poll error: %s'):format(tostring(err)))
        end
    end
end)
