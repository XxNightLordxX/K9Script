--[[
    tests/clientradial_spec.lua

    Second client-side spec in this suite (tests/main_spec.lua is the
    first and the worked example this file follows -- same fresh-sandbox-
    per-test discipline, same "drive the real registered thing, never a
    reimplementation" rule).

    SCOPE, per this pass's own task brief: client/radial.lua is almost
    pure table construction -- it builds a set of ox_lib radial menu items
    behind Config.Features flags, then hands them to
    lib.registerRadial/lib.addRadialItem. What matters most, and what this
    file is built to catch, is exactly the class of bug that "looks fine"
    at a glance: an item that appears when its flag is false, one that's
    missing when its flag is true, a duplicate id silently shadowing
    another item in ox_lib's own registry, or an onSelect closure that
    calls a nil global and throws the instant a player clicks it.

    LOAD-TIME TABLE CONSTRUCTION, NOT RUNTIME -- IMPORTANT FOR THIS FIXTURE:
    every `if Config.Features.X then k9SubmenuItems[#k9SubmenuItems+1] =
    {...} end` branch in client/radial.lua runs ONCE, when the file is
    loaded, not on every call. There is no live re-evaluation the way
    ox_target's canInteract predicate works (see that file's own "OPEN
    STRUCTURAL QUESTION" comment). That means testing "does flag X being
    true/false change which items appear" REQUIRES loading a fresh copy of
    client/radial.lua per flag combination -- toggling a field on an
    already-loaded env's Config table after load does nothing, since the
    branches already ran. newRadialFixture() below therefore takes a
    `features` table of overrides, applies them to the REAL config.lua's
    Config.Features BEFORE loading client/radial.lua, and is called fresh
    (a brand new env, a brand new Config table -- config.lua's own `Config
    = {}` literal is freshly constructed every time it's loaded into a new
    env, so mutating one fixture's Config.Features can never leak into
    another fixture) for every single test in this file, exactly like
    main_spec.lua's own newMainFixture() discipline.

    FIXED BASELINE, NOT "config.lua's live shipped defaults" -- confirmed
    the hard way while writing this file: config.lua is edited
    concurrently by other agents in this repo, and several flags this spec
    treats as a stable reference point (ScentTracking, BiteAndHold, and
    others) were briefly flipped to `true` mid-session by someone else's
    unrelated pass, which made a batch of "absent under the default" tests
    below flap to FAIL for a reason with nothing to do with
    client/radial.lua. newRadialFixture() therefore applies ITS OWN fixed
    baseline table to Config.Features (RadialMenu/LeashMechanics/
    VehicleEntryExit/BasicBarkSounds on, every later-phase flag off --
    matching the Phase 1 vertical slice's own intended shape) immediately
    after loading the real config.lua, BEFORE applying whatever
    `opts.features` a given test asks for. See that baseline's own comment,
    right where it's built, for the full reasoning. This file makes NO
    assertion anywhere about what config.lua's real values happen to be at
    any given moment -- every presence/absence test below sets the ONE flag
    it cares about explicitly, and everything else comes from this spec's
    own stable baseline, not from the live file.

    STUBBING EFFORT, reported honestly per this task's own instruction:
    every native this file's LOAD-TIME table construction touches is
    trivial (locale(), Config, lib.registerRadial, lib.addRadialItem -- four
    stand-ins, none of them a real game native). The natives only start
    mattering once a test actually INVOKES an onSelect closure (candidate-
    search helpers use PlayerPedId/GetEntityCoords/GetActivePlayers/
    PlayerId/GetPlayerPed/DoesEntityExist/GetPlayerServerId; individual
    items call ~30 more cross-file globals, none of them real client
    natives at all -- they are this resource's OWN globals, defined in
    other files this spec never loads). None of that required
    "disproportionate" stubbing in the sense DEVELOPER_REFERENCE.md's stale
    pre-main_spec.lua audit worried about: every one of those ~30 globals
    is a simple call-recording stand-in (record a call, optionally return a
    canned value), the same shape already used throughout this suite's
    server-side specs for RegisterCommand/TriggerClientEvent/etc. See this
    file's own closing comment (bottom) for the one genuine, disclosed
    finding this pass turned up while building this fixture.

    VECTOR STUB: identical shape to combat_spec.lua/certifications_spec.lua/
    tenure_spec.lua's own copies (a real FiveM vector3 supports `-`
    (component-wise) and `#` (magnitude) via operator metamethods;
    FindNearestLeashCandidate/FindNearestPartnerCandidate below do
    `#(myCoords - GetEntityCoords(targetPed))`, so both must be real
    operators here, not plain tables).

    OX_LIB RESTART LIFECYCLE COVERAGE (added this pass, dependency-
    verification finding): client/radial.lua's own registration calls used
    to run as bare top-level statements at file-load time; they now live
    inside one idempotent RegisterK9RadialMenu() function, invoked by an
    `AddEventHandler('onResourceStart', ...)` dispatcher that fires on
    EITHER this resource's own start OR ox_lib's (see that function's own
    doc comment in client/radial.lua for the full writeup). This fixture
    therefore now ALSO stubs `AddEventHandler`/`GetCurrentResourceName` --
    same idiom as tests/inventory_spec.lua's own `fireResourceStart` /
    `wipeHookRegistrations` pair, which covers the identical "does the
    dependency's own restart re-trigger our registration" bug class against
    ox_inventory instead of ox_lib -- and auto-fires this resource's OWN
    start once, right after loading client/radial.lua, so every ALREADY
    EXISTING test below (all written against the OLD "registration runs
    immediately at load" behavior) keeps working completely unchanged: real
    FXServer reliably fires `onResourceStart` for a resource's own boot
    (see client/movement.lua's/client/fetch.lua's own established
    `AddEventHandler('onResourceStart', ...)` idiom, already relied on
    elsewhere in this codebase), so auto-firing it here is a faithful
    representation of real startup, not a shortcut that hides behavior.
    Only the NEW tests near the bottom of this file (search "OX_LIB RESTART
    LIFECYCLE") explicitly drive `f.wipeOxLibRadialState()` +
    `f.fireResourceStart(...)` to prove the fix.

    LIVE-STATE MODELING, NOT JUST A RAW CALL LOG (needed for the new tests
    to have real teeth): `lib.registerRadial`/`lib.addRadialItem` below now
    maintain a small keyed model -- `liveMenus` (id -> items, exactly
    mirroring ox_lib's real `menus[radial.id] = radial` key-based
    overwrite) and `liveRootItems` (an id-deduped array, exactly mirroring
    ox_lib's real `lib.addRadialItem` scan-and-replace-or-append algorithm,
    verified against ox_lib's own source this pass) -- IN ADDITION to the
    original flat `registerRadialCalls`/`addRadialItemCalls` audit-trail
    arrays (kept, unchanged, for the one existing test that still reads
    `addRadialItemCalls` directly). `findMenu`/`findRootItem`/`findInMenu`/
    `allIds` below now read from the live model instead of the raw log --
    for every EXISTING test (which only ever registers once per fixture)
    this is byte-identical behavior to before, since "first match in the
    log" and "current value in the live model" are the same thing when
    there is only one registration; it only starts to matter, correctly,
    once a test re-registers and needs "what does ox_lib actually think is
    registered RIGHT NOW" rather than "every call ever made."
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- see header comment above.
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua (with
--- `opts.features` merged onto its Config.Features table BEFORE
--- client/radial.lua loads -- see this file's header on why load order
--- matters here) + the real client/radial.lua, plus a capturing/
--- controllable stand-in for every global either file's load-time or
--- exercised-onSelect call paths touch.
---
--- `opts.omit` is a list of cross-file global NAMES to leave entirely
--- undefined in the sandbox (so `env.<Name>` reads back nil) -- used only
--- by the "does this onSelect's target carry a type()=='function' guard"
--- tests below, to prove the guarded ones degrade cleanly and the
--- unguarded ones do not.
--- @param opts { features: table?, omit: string[]?, canShowK9UI: boolean?, hasK9Access: boolean? }?
--- @return table fixture
local function newRadialFixture(opts)
    opts = opts or {}
    local omitSet = {}
    for _, name in ipairs(opts.omit or {}) do omitSet[name] = true end

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end

    local canShowK9UICalls, denyCalls, hasK9AccessCalls = 0, 0, 0
    local denyReasons = {}
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    -- REASON PARAMETER (ease-of-use audit finding) -- captures whatever
    -- reason (if any) each onSelect closure passes, so this spec can prove
    -- the specific-reason routing (combat.no_access for HasK9Access()-alone
    -- gates, common.no_k9_role_or_access for the broader CanShowK9UI() ones)
    -- lands correctly, same "already-valid locale key" contract
    -- tests/main_spec.lua's own DenyK9UIAccess tests pin directly.
    local function DenyK9UIAccess(reason)
        denyCalls = denyCalls + 1
        denyReasons[#denyReasons + 1] = reason
    end
    local function HasK9Access() hasK9AccessCalls = hasK9AccessCalls + 1; return hasK9Access end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as CanShowK9UI/DenyK9UIAccess
    -- above. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false. Only
    -- RadialMenu/AdvancedBarkRadial are meaningful here -- see
    -- client/radial.lua's own "K9 UNIT RADIAL -- PER-PERSON BLOCK" header
    -- for why this file checks those two at REGISTRATION time, unlike
    -- every other feature this pass touches.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end
    local denyK9FeatureBlockedCallCount = 0
    local function DenyK9FeatureBlocked() denyK9FeatureBlockedCallCount = denyK9FeatureBlockedCallCount + 1 end

    -- Generic call log: calls[name] is a list of arg-tuples, one per
    -- invocation, for every plain "do a thing" cross-file global below.
    local calls = {}
    local function record(name)
        return function(...)
            calls[name] = calls[name] or {}
            calls[name][#calls[name] + 1] = { ... }
        end
    end

    -- Controllable "current state" query stubs (IsLeashed/IsInK9Vehicle/
    -- GetActiveTrackType/IsBiteHoldEngaged/IsDragEngaged/
    -- IsFetchCarryEngaged) -- each ALSO logs its own call into `calls` so a
    -- test can assert a release branch never re-derives state it doesn't
    -- need (e.g. Detach Leash never calling CanShowK9UI at all).
    local queryState = {
        isLeashed = false, isInK9Vehicle = false, activeTrackType = nil, isTracking = false,
        isBiteHoldEngaged = false, isDragEngaged = false, isFetchCarryEngaged = false,
        -- Top-level icon access gate (this pass) -- see this file's header
        -- addition for the same section.
        isPartnered = false, isDragTargetEngaged = false,
        isRestingInKennel = false, isCarryingKennel = false,
    }
    local function queryFn(name, field)
        return function(...)
            calls[name] = calls[name] or {}
            calls[name][#calls[name] + 1] = { ... }
            return queryState[field]
        end
    end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    -- LIVE ox_lib STATE MODEL -- see this file's header ("LIVE-STATE
    -- MODELING") for why this exists alongside the raw call-log arrays
    -- below. `liveMenus[id]` mirrors ox_lib's real `menus[radial.id] =
    -- radial` (a plain keyed overwrite -- a second registerRadial call for
    -- the same id REPLACES, never duplicates). `liveRootItems` mirrors
    -- ox_lib's real `lib.addRadialItem` id-scan-then-replace-or-append
    -- algorithm for the (nil parentMenuId) root wheel -- the only shape our
    -- own code ever calls it with.
    local liveMenus = {}
    local liveRootItems = {}

    local registerRadialCalls = {}
    local function lib_registerRadial(def)
        registerRadialCalls[#registerRadialCalls + 1] = def
        liveMenus[def.id] = def.items
    end

    local addRadialItemCalls = {}
    local function lib_addRadialItem(items, parentMenuId)
        addRadialItemCalls[#addRadialItemCalls + 1] = items
        -- Our own code never calls this with a parentMenuId (every
        -- k9SubmenuItems-style submenu is built as a plain local table and
        -- registered wholesale via lib.registerRadial instead -- see
        -- client/radial.lua's own header on why `menu` is navigation, not
        -- grouping) -- only the root-wheel (nil parentMenuId) case needs a
        -- faithful id-dedup model here.
        local target = parentMenuId and (liveMenus[parentMenuId] or {}) or liveRootItems
        for _, item in ipairs(items) do
            local replacedExisting = false
            for i, existing in ipairs(target) do
                if existing.id == item.id then
                    target[i] = item
                    replacedExisting = true
                    break
                end
            end
            if not replacedExisting then
                target[#target + 1] = item
            end
        end
    end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    -- PERIODIC ICON REFRESH thread stub (this pass -- top-level icon access
    -- gate). Sandbox.newThreadRunner()'s coroutine-backed CreateThread/Wait
    -- pair (see fixtures/sandbox.lua's own doc comment) lets tests below
    -- step through exactly one 15s refresh pass at a time via
    -- `f.stepIconRefreshThread()`, rather than either looping forever
    -- synchronously (the real Wait(15000) would never yield in a plain
    -- for-loop model) or needing this fixture to fake real elapsed time.
    local threadRunner = Sandbox.newThreadRunner()

    -- GetGameTimer stub -- CONTROLLABLE, not just present. Needed now that
    -- client/radial.lua's own ShouldShowK9RadialIcon() reads it directly
    -- (the startup fail-open grace window) -- tests below advance it via
    -- `f.advanceGameTimer(ms)` to move in and out of that window
    -- deterministically, rather than a real Wait ever elapsing in a test.
    local gameTimerNow = 0
    local function GetGameTimer() return gameTimerNow end

    -- OX_LIB RESTART LIFECYCLE stubs -- same `AddEventHandler`/
    -- `GetCurrentResourceName` idiom as tests/inventory_spec.lua,
    -- tests/kennel_spec.lua, tests/fetch_spec.lua, etc. `eventHandlers` is
    -- exposed (indirectly, via `fireResourceStart` below) so this file can
    -- drive client/radial.lua's RegisterK9RadialMenu() dispatcher exactly
    -- the way real FXServer would -- once for this resource's own start,
    -- and again for a later, independent ox_lib restart.
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function GetCurrentResourceName() return 'john-k9' end
    local function fireResourceStart(resourceName)
        for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
            handler(resourceName)
        end
    end
    --- Fires client/featureblocks.lua's own local
    --- `john-k9:client:featureBlocksApplied` re-broadcast (REQUESTED --
    --- this spec drives it directly rather than loading that file for
    --- real, same "stub the cross-file dependency" convention as
    --- everything else in this fixture) -- proves RegisterK9RadialMenu()
    --- genuinely re-runs (and re-evaluates the two block checks) on this
    --- event, not just on a resource/ox_lib restart.
    local function fireFeatureBlocksApplied()
        for _, handler in ipairs(eventHandlers['john-k9:client:featureBlocksApplied'] or {}) do
            handler()
        end
    end

    --- Fires client/movement.lua's own local
    --- `john-k9:client:leashStateChanged` re-broadcast, the same way
    --- fireFeatureBlocksApplied above drives client/featureblocks.lua's.
    --- That file fires this every time leashState flips, purely so this
    --- file rebuilds the menu and the Attach/Detach Leash item
    --- re-evaluates IsLeashed() right then.
    local function fireLeashStateChanged()
        for _, handler in ipairs(eventHandlers['john-k9:client:leashStateChanged'] or {}) do
            handler()
        end
    end

    -- FindNearestLeashCandidate/FindNearestPartnerCandidate's natives.
    local myPed = 1
    local pedCoords = { [1] = vec3(0, 0, 0) }
    local activePlayers = {}
    local playerPeds = {}
    local playerServerIds = {}
    local function PlayerPedId() return myPed end
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end
    local function GetActivePlayers() return activePlayers end
    local function PlayerId() return 0 end -- local player's own playerId; test setup never puts 0 into activePlayers
    local function GetPlayerPed(playerId) return playerPeds[playerId] or 0 end
    local function DoesEntityExist(entity) return entity ~= 0 and entity ~= nil end
    local function GetPlayerServerId(playerId) return playerServerIds[playerId] end

    local allStubs = {
        K9Sit = record('K9Sit'),
        IsLeashed = queryFn('IsLeashed', 'isLeashed'),
        DetachLeash = record('DetachLeash'),
        RequestLeashAttach = record('RequestLeashAttach'),
        IsInK9Vehicle = queryFn('IsInK9Vehicle', 'isInK9Vehicle'),
        EnterNearestK9Vehicle = record('EnterNearestK9Vehicle'),
        ExitK9Vehicle = record('ExitK9Vehicle'),
        GetActiveTrackType = queryFn('GetActiveTrackType', 'activeTrackType'),
        IsTracking = queryFn('IsTracking', 'isTracking'),
        StopTracking = record('StopTracking'),
        StartScentTrack = record('StartScentTrack'),
        StartBloodTrack = record('StartBloodTrack'),
        StartGunpowderTrack = record('StartGunpowderTrack'),
        StartCertifiedTrack = record('StartCertifiedTrack'),
        IsBiteHoldEngaged = queryFn('IsBiteHoldEngaged', 'isBiteHoldEngaged'),
        ReleaseBiteHold = record('ReleaseBiteHold'),
        RequestBiteHold = record('RequestBiteHold'),
        RequestTakedown = record('RequestTakedown'),
        -- Takedown became a TOGGLE this pass -- see the k9_takedown tests
        -- at the end of this file. Stubbed in the same shape as bite hold's
        -- own trio directly above, so the item can be driven through both
        -- of its states.
        IsTakedownEngaged = queryFn('IsTakedownEngaged', 'isTakedownEngaged'),
        ReleaseTakedown = record('ReleaseTakedown'),
        IsDragEngaged = queryFn('IsDragEngaged', 'isDragEngaged'),
        ReleaseDrag = record('ReleaseDrag'),
        RequestDrag = record('RequestDrag'),
        BreakPartnership = record('BreakPartnership'),
        RequestPartnerUp = record('RequestPartnerUp'),
        TogglePartnership = record('TogglePartnership'),
        FetchContextual = record('FetchContextual'),
        IsFetchCarryEngaged = queryFn('IsFetchCarryEngaged', 'isFetchCarryEngaged'),
        ReleaseFetchBall = record('ReleaseFetchBall'),
        RequestThrowFetchBall = record('RequestThrowFetchBall'),
        RequestRecallFetchBall = record('RequestRecallFetchBall'),
        RequestToggleK9PropAttachment = record('RequestToggleK9PropAttachment'),
        RequestDeployKennel = record('RequestDeployKennel'),
        ExitKennelRest = record('ExitKennelRest'),
        -- The merged 'k9_kennel' item calls this one global for all five
        -- kennel actions; client/kennel.lua resolves which is meant and
        -- reaches ExitKennelRest() itself for the exit case.
        RequestKennelContextual = record('RequestKennelContextual'),
        RequestOpenOwnK9Inventory = record('RequestOpenOwnK9Inventory'),
        RequestTreatNearestK9 = record('RequestTreatNearestK9'),
        -- Top-level icon access gate (this pass) -- consulted by
        -- IsK9RadialIconNeededForOngoingEngagement(), not by any onSelect
        -- closure.
        IsPartnered = queryFn('IsPartnered', 'isPartnered'),
        IsDragTargetEngaged = queryFn('IsDragTargetEngaged', 'isDragTargetEngaged'),
        IsRestingInKennel = queryFn('IsRestingInKennel', 'isRestingInKennel'),
        IsCarryingKennel = queryFn('IsCarryingKennel', 'isCarryingKennel'),
        -- Command Tablet (Job 3 regrouping/bug-fix pass) -- see the
        -- 'k9_open_tablet' tests near the bottom of this file for the full
        -- writeup of the nesting bug this pass fixes.
        OpenTablet = record('OpenTablet'),
        -- OWNER REVERSAL (coder-architect, this pass) -- k9_thermal_vision/
        -- k9_night_vision's own, separate call targets,
        -- client/vision.lua's ToggleThermalVision()/ToggleNightVision().
        -- No CanShowK9UI()/HasK9Access() gate of their own -- see each
        -- item's own comment in client/radial.lua.
        ToggleThermalVision = record('ToggleThermalVision'),
        ToggleNightVision = record('ToggleNightVision'),
        -- k9_vision_cycle's own call target, client/vision.lua's
        -- CycleVision() -- kept as an extra, optional convenience alongside
        -- the two items immediately above. No CanShowK9UI()/HasK9Access()
        -- gate of its own either -- see that item's own comment in
        -- client/radial.lua.
        CycleVision = record('CycleVision'),
        -- DISCOVERABILITY PASS: k9_scent_vision / k9_camera_feed, both
        -- previously command-and-keybind-only. Same no-gate-of-their-own
        -- posture as every other perception item here -- each callee
        -- performs its own real check and notifies specifically on failure.
        ToggleScentVision = record('ToggleScentVision'),
        ToggleCameraFeed = record('ToggleCameraFeed'),
        -- ONE MENU PER PLAYER: the menu is built for who you are playing.
        -- Every test above this pass was written from the dog's side, so
        -- the fixture plays the dog unless a test passes opts.playingDog =
        -- false (the handler's menu -- see the tests near the bottom).
        IsOwnModelK9 = function() return opts.playingDog ~= false end,
        -- Which OTHER players' peds are dogs (FindNearestPairCandidate).
        IsEntityModelK9 = function(ped) return (opts.dogPeds or {})[ped] == true end,
    }

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        TriggerServerEvent = TriggerServerEvent,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        GetActivePlayers = GetActivePlayers,
        PlayerId = PlayerId,
        GetPlayerPed = GetPlayerPed,
        DoesEntityExist = DoesEntityExist,
        GetPlayerServerId = GetPlayerServerId,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        lib = { registerRadial = lib_registerRadial, addRadialItem = lib_addRadialItem, notify = lib_notify,
            -- ox_lib's real removeRadialItem (resource/interface/client/radial.lua):
            -- remove by id from the root wheel, a no-op when absent. Opt-in so
            -- the older-ox_lib fallback (inert stub) stays covered too.
            removeRadialItem = opts.withRemoveRadialItem and function(id)
                for i, existing in ipairs(liveRootItems) do
                    if existing.id == id then table.remove(liveRootItems, i); break end
                end
            end or nil },
        -- Top-level icon access gate (this pass) -- department membership
        -- check reads QBX.PlayerData.job.name directly. Defaults to no job
        -- at all (nil) -- a test wanting a department member sets
        -- `f.env.QBX.PlayerData.job.name = 'police'` (or any real
        -- Config.Departments key) directly against the exposed `env`
        -- fixture field, same "mutate env directly" convention this
        -- fixture already uses nowhere else needed a dedicated setter for.
        QBX = { PlayerData = { job = { name = nil } } },
    }
    for name, fn in pairs(allStubs) do
        if not omitSet[name] then overrides[name] = fn end
    end
    if featureBlocksAvailable then
        overrides.IsK9FeatureBlocked = IsK9FeatureBlocked
        overrides.DenyK9FeatureBlocked = DenyK9FeatureBlocked
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- THIS SPEC'S OWN FIXED BASELINE -- deliberately NOT "whatever
    -- config.lua currently ships." config.lua is a live file other agents
    -- edit concurrently in this repo (confirmed mid-session: ScentTracking/
    -- BiteAndHold/etc. were briefly flipped to `true` by someone else's
    -- pass while this spec was being written, which made several
    -- "absent under the shipped default" assertions below flap to FAIL for
    -- a reason that had nothing to do with client/radial.lua). Every test
    -- in this file that cares about a SPECIFIC flag combination sets that
    -- combination explicitly via `opts.features`; this baseline just gives
    -- every other, unrelated flag a known, stable value first so a test
    -- that only means to exercise ONE flag doesn't silently inherit
    -- whatever value a dozen OTHER flags happen to carry in the real file
    -- at the moment this spec happens to run. This baseline mirrors the
    -- Phase 1 vertical slice's own intended shape (RadialMenu/
    -- LeashMechanics/VehicleEntryExit/BasicBarkSounds on, everything later
    -- off) but is NOT itself an assertion about config.lua's real, current
    -- defaults -- this file makes no claim about those at all.
    local baseline = {
        RadialMenu = true, LeashMechanics = true, VehicleEntryExit = true, BasicBarkSounds = true,
        AdvancedBarkRadial = false, ScentTracking = false, BloodTracking = false, GunpowderSniffing = false,
        BiteAndHold = false, NonLethalTakedown = false, PropDragging = false, HandlerPartnership = false,
        FetchMechanic = false, PropAttachments = false,
        DeployableKennel = false, K9Inventory = false, K9Medkit = false,
        -- NightVision/ThermalVision -- both ship `true` in the real, live
        -- config.lua, and the
        -- k9_vision_cycle item is gated on an OR of the two -- left
        -- unpinned here, every "absent under baseline" test in this file
        -- would flap depending on the real file's live values, exactly the
        -- failure mode this baseline table exists to prevent.
        NightVision = false, ThermalVision = false,
    }
    for key, value in pairs(baseline) do
        env.Config.Features[key] = value
    end
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end
    Sandbox.loadInto('../client/radial.lua', env)

    -- Auto-fire THIS resource's own start, exactly once, immediately after
    -- loading -- see this file's header ("OX_LIB RESTART LIFECYCLE
    -- COVERAGE") for why: client/radial.lua's registration calls now only
    -- run when RegisterK9RadialMenu() is invoked by its own
    -- `AddEventHandler('onResourceStart', ...)` dispatcher, and real
    -- FXServer reliably fires that event for a resource's own boot. Doing
    -- it here, transparently, means every test below that predates this
    -- lifecycle fix keeps working completely unchanged.
    fireResourceStart('john-k9')

    return {
        env = env,
        Config = env.Config,
        registerRadialCalls = registerRadialCalls,
        addRadialItemCalls = addRadialItemCalls,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        calls = calls,

        --- @param id string -- a lib.registerRadial menu id (e.g. 'k9unit')
        --- @return table? items
        findMenu = function(id)
            return liveMenus[id]
        end,

        --- @param id string -- a root-wheel item id (added via lib.addRadialItem)
        findRootItem = function(id)
            for _, item in ipairs(liveRootItems) do
                if item.id == id then return item end
            end
            return nil
        end,

        --- @param menuId string
        --- @param itemId string
        findInMenu = function(menuId, itemId)
            local items = liveMenus[menuId]
            if not items then return nil end
            for _, item in ipairs(items) do
                if item.id == itemId then return item end
            end
            return nil
        end,

        --- Finds an item anywhere under the K9 menu -- the top level or any
        --- sub-menu it opens (Partner & Leash / Combat / Senses / Utility / Bark).
        --- @param itemId string
        --- @return table? item, string? menuId -- the menu it lives in
        findK9Item = function(itemId)
            local seen = {}
            local function search(menuId)
                if seen[menuId] then return nil end
                seen[menuId] = true
                for _, item in ipairs(liveMenus[menuId] or {}) do
                    if item.id == itemId then return item, menuId end
                end
                for _, item in ipairs(liveMenus[menuId] or {}) do
                    if item.menu then
                        local hit, where = search(item.menu)
                        if hit then return hit, where end
                    end
                end
                return nil
            end
            return search('k9unit')
        end,

        --- Every id CURRENTLY registered (every live menu's items, plus
        --- every live root item) -- for the no-duplicate-ids check. Reads
        --- the live keyed model, not the raw call log, so this reflects
        --- what ox_lib would actually show right now, even after a
        --- re-registration -- see this file's header ("LIVE-STATE
        --- MODELING") for why that distinction matters.
        allIds = function()
            local ids = {}
            for _, items in pairs(liveMenus) do
                for _, item in ipairs(items) do ids[#ids + 1] = item.id end
            end
            for _, item in ipairs(liveRootItems) do ids[#ids + 1] = item.id end
            return ids
        end,

        -- OX_LIB RESTART LIFECYCLE test helpers -- see this file's header.
        fireResourceStart = fireResourceStart,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        --- Simulates ox_lib's OWN restart reconstructing its two file-local
        --- registries (`menus`/`menuItems` in the real ox_lib source) empty
        --- -- the real mechanism client/radial.lua's onResourceStart
        --- dispatcher exists to recover from. Wipes both the live keyed
        --- model AND the raw call-log arrays (the latter purely so the
        --- NEXT registration pass's own call order can be inspected in
        --- isolation, uncontaminated by calls made before the simulated
        --- restart).
        wipeOxLibRadialState = function()
            for k in pairs(liveMenus) do liveMenus[k] = nil end
            for i = #liveRootItems, 1, -1 do liveRootItems[i] = nil end
            for i = #registerRadialCalls, 1, -1 do registerRadialCalls[i] = nil end
            for i = #addRadialItemCalls, 1, -1 do addRadialItemCalls[i] = nil end
        end,
        --- Order ids were passed to lib.registerRadial, since the last wipe
        --- (or since fixture construction, if never wiped) -- for the
        --- "submenus registered before the items that reference them"
        --- ordering assertions.
        registerRadialOrder = function()
            local order = {}
            for _, def in ipairs(registerRadialCalls) do order[#order + 1] = def.id end
            return order
        end,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        canShowK9UICallCount = function() return canShowK9UICalls end,
        denyCallCount = function() return denyCalls end,
        lastDenyReason = function() return denyReasons[#denyReasons] end,
        hasK9AccessCallCount = function() return hasK9AccessCalls end,
        setState = function(field, value) queryState[field] = value end,
        setMyPed = function(handle) myPed = handle end,
        setPedCoords = function(entity, coords) pedCoords[entity] = coords end,
        setActivePlayers = function(list) activePlayers = list end,
        setPlayerPed = function(playerId, ped) playerPeds[playerId] = ped end,
        setPlayerServerId = function(playerId, serverId) playerServerIds[playerId] = serverId end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        denyK9FeatureBlockedCallCount = function() return denyK9FeatureBlockedCallCount end,
        fireFeatureBlocksApplied = fireFeatureBlocksApplied,
        fireLeashStateChanged = fireLeashStateChanged,
        leashStateChangedHandlerCount = function() return #(eventHandlers['john-k9:client:leashStateChanged'] or {}) end,
        featureBlocksAppliedHandlerCount = function() return #(eventHandlers['john-k9:client:featureBlocksApplied'] or {}) end,

        -- Top-level icon access gate (this pass).
        advanceGameTimer = function(deltaMs) gameTimerNow = gameTimerNow + deltaMs end,
        --- Runs exactly one PERIODIC ICON REFRESH pass (see
        --- fixtures/sandbox.lua's own Sandbox.newThreadRunner() doc comment
        --- on "NOTE on stepping semantics" for why this calls step() TWICE:
        --- the thread's own body is `while true do Wait(...) ... end`, so
        --- the first step() only reaches that initial Wait and primes the
        --- coroutine; the second actually runs one refresh pass.
        stepIconRefreshThread = function()
            threadRunner.step()
            threadRunner.step()
        end,
        --- Runs every captured thread one step -- enough for a one-shot
        --- CreateThread body (no Wait) to finish.
        stepThreads = function() threadRunner.step() end,
    }
end

--- @param item table
local function assertGuardDoesNotThrow(item)
    local ok, err = pcall(item.onSelect)
    t.isTrue(ok, ('%s onSelect must not throw when its cross-file target global is entirely absent -- %s'):format(item.id, tostring(err)))
end

-- ----------------------------------------------------------------------
-- Sanity: default (unmodified) real config.lua flags -- the exact shape a
-- freshly-installed server sees.
-- ----------------------------------------------------------------------

t.test('this spec\'s baseline flags: the k9unit submenu is registered and linked from a single root opener item', function()
    local f = newRadialFixture()
    local items = f.findMenu('k9unit')
    t.isNotNil(items, 'lib.registerRadial must be called with id="k9unit"')
    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'lib.addRadialItem must add the single k9unit_open opener to the root wheel')
    t.equals(opener.menu, 'k9unit', 'the opener must navigate into the k9unit submenu just registered')
    t.isNil(opener.onSelect, 'the opener is a pure navigation link, per this file\'s own header on menu-vs-navigation semantics -- it must carry no onSelect of its own')
end)

t.test('this spec\'s baseline flags: Bark, the Partner & Leash group (Leash + Vehicle) and Utility (with Kennel) are what a K9 sees; every later-phase item stays absent', function()
    local f = newRadialFixture()
    local items = f.findMenu('k9unit')
    local presentIds = {}
    for _, item in ipairs(items) do presentIds[item.id] = true end

    t.isTrue(presentIds.k9_utility, 'the Utility sub-menu opener must be present -- k9_sit alone (no dedicated flag) guarantees the sub-menu is never empty')
    t.isTrue(presentIds.k9_bark)
    t.isTrue(presentIds.k9_group_handler, 'Leash and Vehicle are both on here, so they share the Partner & Leash group')

    local _, leashMenu = f.findK9Item('k9_leash')
    local _, vehicleMenu = f.findK9Item('k9_vehicle')
    local _, kennelMenu = f.findK9Item('k9_kennel')
    local _, sitMenu = f.findK9Item('k9_sit')
    t.equals(leashMenu, 'k9unit_handler')
    t.equals(vehicleMenu, 'k9unit_handler')
    t.equals(kennelMenu, 'k9unit_utility', 'k9_kennel has no dedicated flag of its own (it carries the kennel EXIT path) and now lives in Utility')
    t.equals(sitMenu, 'k9unit_utility')

    for _, id in ipairs({
        'k9_track_certified', 'k9_bite_hold', 'k9_takedown', 'k9_drag', 'k9_partner', 'k9_fetch',
        'k9_thermal_vision', 'k9_night_vision', 'k9_vision_cycle',
    }) do
        t.isNil(f.findK9Item(id), ('%s must be absent anywhere in the K9 menu under this baseline'):format(id))
    end
end)

-- ----------------------------------------------------------------------
-- MENU SHAPE (the rework pass) -- ox_lib shows 6 slots a page and turns
-- the 6th into "More..."; the K9 menu and every group must fit on one page.
-- ----------------------------------------------------------------------

t.test('NO "MORE..." PAGES: with every optional feature on, the K9 menu has at most six entries -- Tablet, Bark, Partner & Leash, Combat, Senses, Utility -- and every action is at most two presses away', function()
    local f = newRadialFixture({
        features = {
            CommandTablet = true,
            ScentTracking = true,
            ThermalVision = true,
            NightVision = true,
            BiteAndHold = true,
            NonLethalTakedown = true,
            PropDragging = true,
            HandlerPartnership = true,
            FetchMechanic = true,
        },
    })
    local top = f.findMenu('k9unit')
    local topIds = {}
    for i, item in ipairs(top) do topIds[i] = item.id end
    t.isTrue(#top <= 6, ('ox_lib shows 6 slots a page; the K9 menu must fit on one page, got %d entries'):format(#top))
    t.equals(table.concat(topIds, ','), 'k9_open_tablet,k9_bark,k9_group_handler,k9_group_combat,k9_group_senses,k9_utility')

    local function ids(menuId)
        local out = {}
        for _, item in ipairs(f.findMenu(menuId) or {}) do out[#out + 1] = item.id end
        return table.concat(out, ',')
    end
    t.equals(ids('k9unit_handler'), 'k9_leash,k9_vehicle,k9_partner')
    t.equals(ids('k9unit_combat'), 'k9_bite_hold,k9_takedown,k9_drag')
    t.equals(ids('k9unit_senses'), 'k9_track_certified,k9_scent_vision,k9_thermal_vision,k9_night_vision,k9_vision_cycle')
    t.isTrue(#f.findMenu('k9unit_utility') <= 6, 'Utility fits on one page too')
    local _, fetchMenu = f.findK9Item('k9_fetch')
    local _, kennelMenu = f.findK9Item('k9_kennel')
    t.equals(fetchMenu, 'k9unit_utility')
    t.equals(kennelMenu, 'k9unit_utility')

    for _, menuId in ipairs({ 'k9unit_handler', 'k9unit_combat', 'k9unit_senses' }) do
        t.isTrue(#f.findMenu(menuId) <= 6, menuId .. ' fits on one page')
    end
end)

t.test('ONE MENU PER PLAYER: a human handler gets the handler\'s buttons -- no Sit, Bark, Bite or dog senses that could only refuse', function()
    local f = newRadialFixture({
        playingDog = false,
        features = {
            CommandTablet = true, ScentTracking = true, ThermalVision = true, NightVision = true,
            BiteAndHold = true, NonLethalTakedown = true, PropDragging = true,
            HandlerPartnership = true, FetchMechanic = true, K9Medkit = true,
        },
    })
    local topIds = {}
    for i, item in ipairs(f.findMenu('k9unit')) do topIds[i] = item.id end
    t.equals(table.concat(topIds, ','), 'k9_open_tablet,k9_group_handler,k9_utility')

    for _, dogOnly in ipairs({ 'k9_sit', 'k9_bark', 'k9_bite_hold', 'k9_takedown', 'k9_drag', 'k9_scent_vision', 'k9_thermal_vision', 'k9_night_vision', 'k9_vision_cycle', 'k9_track_certified' }) do
        t.isNil(f.findK9Item(dogOnly), dogOnly .. ' is not in a human\'s menu')
    end
    local handlerIds = {}
    for _, item in ipairs(f.findMenu('k9unit_handler')) do handlerIds[#handlerIds + 1] = item.id end
    t.equals(table.concat(handlerIds, ','), 'k9_leash,k9_partner', 'Vehicle is the dog getting itself in and out, so it is on the dog\'s menu')
    t.isNotNil(f.findInMenu('k9unit_utility', 'k9_treat_nearest'))
    t.isNotNil(f.findInMenu('k9unit_utility', 'k9_fetch'))

    t.isNil(f.findK9Item('k9_mark_suspect'), 'suspect marking was removed -- a K9 can act on anyone')
end)

t.test('ONE MENU PER PLAYER: the Kennel button says what each player can do with it -- the dog enters, a person puts it down or works the door', function()
    local dog = newRadialFixture({ playingDog = true, features = { DeployableKennel = true } })
    local person = newRadialFixture({ playingDog = false, features = { DeployableKennel = true } })
    t.equals(dog.findK9Item('k9_kennel').label, Sandbox.locale('radial.kennel_label'))
    t.equals(person.findK9Item('k9_kennel').label, Sandbox.locale('radial.kennel_label_handler'))
end)

t.test('ONE MENU PER PLAYER: the dog never gets Treat K9 (a person\'s action)', function()
    local dog = newRadialFixture({ features = { K9Medkit = true, BiteAndHold = true } })
    t.isNil(dog.findK9Item('k9_treat_nearest'))
end)

t.test('ONE MENU PER PLAYER: a bite still being held keeps its button even after the character changes -- it can always be let go', function()
    local f = newRadialFixture({ playingDog = false, features = { BiteAndHold = true } })
    t.isNil(f.findK9Item('k9_bite_hold'))
    f.setState('isBiteHoldEngaged', true)
    f.fireLeashStateChanged()
    t.isNotNil(f.findK9Item('k9_bite_hold'), 'the release button is back while the hold runs')
end)

t.test('SHOW ONLY WHAT YOU CAN USE: a button whose ability high command blocked for you is left out; a dog without K9 access gets no dog moves; a running move keeps its button', function()
    local blocked = newRadialFixture({ features = { BiteAndHold = true, NonLethalTakedown = true } })
    blocked.env.IsK9FeatureBlocked = function(name) return name == 'BiteAndHold' end
    blocked.fireLeashStateChanged()
    t.isNil(blocked.findK9Item('k9_bite_hold'), 'blocked ability: no button')
    t.isNotNil(blocked.findK9Item('k9_takedown'), 'other abilities untouched')

    local noAccess = newRadialFixture({ features = { BiteAndHold = true, BasicBarkSounds = true, LeashMechanics = true } })
    noAccess.env.HasK9AccessCached = function() return false end
    noAccess.fireLeashStateChanged()
    t.isNil(noAccess.findK9Item('k9_bite_hold'))
    t.isNil(noAccess.findK9Item('k9_bark'))
    t.isNotNil(noAccess.findK9Item('k9_leash'), 'the leash is never hidden this way')

    noAccess.setState('isBiteHoldEngaged', true)
    noAccess.fireLeashStateChanged()
    t.isNotNil(noAccess.findK9Item('k9_bite_hold'), 'a hold still running keeps its release button')
end)

t.test('rebuilding the menu (it re-registers on every state change) never duplicates an item moved into a group or into Utility', function()
    local f = newRadialFixture({ features = { FetchMechanic = true, BiteAndHold = true, NonLethalTakedown = true } })
    f.fireLeashStateChanged()
    f.fireLeashStateChanged()
    local function count(menuId, id)
        local n = 0
        for _, item in ipairs(f.findMenu(menuId) or {}) do if item.id == id then n = n + 1 end end
        return n
    end
    t.equals(count('k9unit_utility', 'k9_fetch'), 1)
    t.equals(count('k9unit_utility', 'k9_kennel'), 1)
    t.equals(count('k9unit_combat', 'k9_bite_hold'), 1)
    t.equals(count('k9unit', 'k9_group_combat'), 1)
end)

t.test('a group with only ONE item available on this server is not wrapped -- that item stays in the top menu, no sub-menu for a single button', function()
    local f = newRadialFixture({ features = { VehicleEntryExit = false } })
    local item, menuId = f.findK9Item('k9_leash')
    t.isNotNil(item)
    t.equals(menuId, 'k9unit', 'Leash is the only Partner & Leash item here, so it sits in the top menu')
    t.isNil(f.findMenu('k9unit_handler'))
end)

-- ----------------------------------------------------------------------
-- 'k9unit_utility' sub-menu (Job 3 regrouping, ease-of-use audit) -- Sit/
-- Toggle K9 Vest/Open My Gear/Treat K9, none of which carry a release/
-- termination half worth protecting from an extra menu level (see
-- client/radial.lua's own "REGROUPING PASS" header for the full safety
-- reasoning this follows). Command Tablet and every termination-capable
-- toggle (Leash/Vehicle/Bite & Hold/Takedown/Drag/Break Partnership/
-- Kennel) stay flat at the TOP level on purpose -- NOT folded
-- in here, despite the task's own illustrative "Utility (kennel/inventory/
-- vehicle/medkit/vest)" suggestion naming kennel and vehicle too; deviation
-- documented at each of those items' own call sites in client/radial.lua.
-- ----------------------------------------------------------------------

t.test('k9unit_utility: registered and linked from the k9unit menu via a single k9_utility opener', function()
    local f = newRadialFixture()
    local link = f.findK9Item('k9_utility')
    t.isNotNil(link, 'k9unit must carry a k9_utility opener linking into the sub-menu')
    t.equals(link.menu, 'k9unit_utility')
    t.isNil(link.onSelect, 'the opener is a pure navigation link, carrying no onSelect of its own')

    local utilityItems = f.findMenu('k9unit_utility')
    t.isNotNil(utilityItems, 'lib.registerRadial must be called with id="k9unit_utility"')
end)

t.test('k9unit_utility: Sit is present regardless of every other feature flag, since it has no dedicated flag of its own', function()
    local f = newRadialFixture()
    t.isNotNil(f.findInMenu('k9unit_utility', 'k9_sit'))
end)

-- ----------------------------------------------------------------------
-- Per-flag presence: flags that ship FALSE and gate exactly one item each
-- in the k9unit submenu.
-- ----------------------------------------------------------------------

local FALSE_BY_DEFAULT_SINGLE_ITEM_CASES = {
    { flag = 'BiteAndHold', itemId = 'k9_bite_hold' },
    { flag = 'NonLethalTakedown', itemId = 'k9_takedown' },
    { flag = 'PropDragging', itemId = 'k9_drag' },
    -- MOVED into 'k9unit_utility' (Job 3 regrouping) -- `menu` overrides the
    -- default 'k9unit' target below for these three only.
    { flag = 'PropAttachments', itemId = 'k9_prop_attachment', menu = 'k9unit_utility' },
    -- The two items this task explicitly called out as "wired only
    -- recently, both behind flags that ship false" -- proven here by the
    -- SAME generic mechanism as every other flag/item pair, not a special
    -- case, precisely because nothing about them IS special-cased in the
    -- source.
    { flag = 'K9Inventory', itemId = 'k9_open_inventory', menu = 'k9unit_utility' },
    -- Treat K9 is a person's action (a handler or medic treats the dog), so
    -- it is looked for in the menu a human player gets.
    { flag = 'K9Medkit', itemId = 'k9_treat_nearest', menu = 'k9unit_utility', playingDog = false },
    -- RESOLVED this pass: closed the exact disclosed gap
    -- a removed file's own header used to name ("not wired into
    -- client/radial.lua by this pass") -- same generic mechanism, nothing
    -- special-cased.
    -- RADIAL JOIN ENTRY POINT (this pass) -- same flag gates BOTH the
    -- toggle above and this new item, since joining is using the same
    -- feature starting one is.
}

for _, case in ipairs(FALSE_BY_DEFAULT_SINGLE_ITEM_CASES) do
    local menu = case.menu or 'k9unit'

    t.test(('%s: absent when Config.Features.%s is explicitly false'):format(case.itemId, case.flag), function()
        local f = newRadialFixture({ playingDog = case.playingDog })
        t.isNil(f.findInMenu(menu, case.itemId))
    end)

    t.test(('%s: appears ONLY when Config.Features.%s is explicitly true'):format(case.itemId, case.flag), function()
        local f = newRadialFixture({ features = { [case.flag] = true }, playingDog = case.playingDog })
        t.isNotNil(f.findInMenu(menu, case.itemId), ('%s must appear once %s is true'):format(case.itemId, case.flag))
    end)
end

-- ----------------------------------------------------------------------
-- k9_track_certified (owner-directed decluttering pass, 2026-08-26) -- the
-- ONE merged item REPLACING the three former separate k9_track_scent/
-- k9_track_blood/k9_track_gunpowder items. Unlike every case in
-- FALSE_BY_DEFAULT_SINGLE_ITEM_CASES above (exactly one flag gates exactly
-- one item), this ONE item is gated on an OR of three flags -- tested
-- individually below rather than folded into that generic table, since the
-- generic helper assumes a strict one-flag-to-one-item mapping this item no
-- longer has.
-- ----------------------------------------------------------------------
t.test('k9_track_certified: absent when ScentTracking, BloodTracking, and GunpowderSniffing are all false', function()
    local f = newRadialFixture()
    t.isNil(f.findK9Item('k9_track_certified'))
end)

for _, flag in ipairs({ 'ScentTracking', 'BloodTracking', 'GunpowderSniffing' }) do
    t.test(('k9_track_certified: appears when ONLY %s is true (the item is gated on an OR of the three, not an AND)'):format(flag), function()
        local f = newRadialFixture({ features = { [flag] = true } })
        t.isNotNil(f.findK9Item('k9_track_certified'), ('k9_track_certified must appear once %s alone is true'):format(flag))
    end)
end

-- ----------------------------------------------------------------------
-- k9_thermal_vision / k9_night_vision (OWNER REVERSAL, coder-architect,
-- this pass: "I want the thermal and night vision separate"). Each is its
-- own item, gated on its OWN single flag (a strict one-flag-to-one-item
-- mapping, unlike k9_vision_cycle below), calling straight through to its
-- own Toggle*Vision() -- no shared dispatch, no cross-item coupling.
-- ----------------------------------------------------------------------
t.test('k9_thermal_vision: absent when ThermalVision is false (this baseline)', function()
    local f = newRadialFixture()
    t.isNil(f.findK9Item('k9_thermal_vision'))
end)

t.test('k9_thermal_vision: present when ThermalVision is true, even with NightVision false, with the real locale-backed label', function()
    local f = newRadialFixture({ features = { ThermalVision = true, NightVision = false } })
    local item = f.findK9Item('k9_thermal_vision')
    t.isNotNil(item)
    t.equals(item.label, locale('radial.thermal_vision_label'))
end)

t.test('k9_thermal_vision: onSelect calls ToggleThermalVision() exactly once, and consults NEITHER CanShowK9UI NOR HasK9Access', function()
    local f = newRadialFixture({ features = { ThermalVision = true }, canShowK9UI = false, hasK9Access = false })
    f.findK9Item('k9_thermal_vision').onSelect()
    t.equals(#f.calls.ToggleThermalVision, 1)
    t.equals(f.canShowK9UICallCount(), 0, 'k9_thermal_vision must never call CanShowK9UI -- gating is ToggleThermalVision()\'s own job (IsOwnModelK9() only)')
    t.equals(f.hasK9AccessCallCount(), 0, 'k9_thermal_vision must never call HasK9Access either, for the same reason')
    t.equals(f.denyCallCount(), 0, 'no DenyK9UIAccess call either, since the gate it would guard is never consulted')
end)

t.test('FIXED-SHAPE GUARD: k9_thermal_vision does not throw when ToggleThermalVision is entirely absent', function()
    local f = newRadialFixture({ features = { ThermalVision = true }, omit = { 'ToggleThermalVision' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_thermal_vision'))
end)

t.test('k9_night_vision: absent when NightVision is false (this baseline)', function()
    local f = newRadialFixture()
    t.isNil(f.findK9Item('k9_night_vision'))
end)

t.test('k9_night_vision: present when NightVision is true, even with ThermalVision false, with the real locale-backed label', function()
    local f = newRadialFixture({ features = { NightVision = true, ThermalVision = false } })
    local item = f.findK9Item('k9_night_vision')
    t.isNotNil(item)
    t.equals(item.label, locale('radial.night_vision_label'))
end)

t.test('k9_night_vision: onSelect calls ToggleNightVision() exactly once, and consults NEITHER CanShowK9UI NOR HasK9Access', function()
    local f = newRadialFixture({ features = { NightVision = true }, canShowK9UI = false, hasK9Access = false })
    f.findK9Item('k9_night_vision').onSelect()
    t.equals(#f.calls.ToggleNightVision, 1)
    t.equals(f.canShowK9UICallCount(), 0, 'k9_night_vision must never call CanShowK9UI -- gating is ToggleNightVision()\'s own job (IsOwnModelK9() only)')
    t.equals(f.hasK9AccessCallCount(), 0, 'k9_night_vision must never call HasK9Access either, for the same reason')
end)

t.test('FIXED-SHAPE GUARD: k9_night_vision does not throw when ToggleNightVision is entirely absent', function()
    local f = newRadialFixture({ features = { NightVision = true }, omit = { 'ToggleNightVision' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_night_vision'))
end)

t.test('k9_thermal_vision and k9_night_vision are INDEPENDENT items: both present at once when both flags are true, and each survives the OTHER flag being off', function()
    local f = newRadialFixture({ features = { ThermalVision = true, NightVision = true } })
    t.isNotNil(f.findK9Item('k9_thermal_vision'))
    t.isNotNil(f.findK9Item('k9_night_vision'))
end)

-- ----------------------------------------------------------------------
-- k9_vision_cycle -- KEPT as an extra, optional convenience alongside the
-- two explicit items directly above (owner's own steer: "keep it as an
-- extra... it costs nothing, someone may prefer it"), never their
-- replacement. Same OR-of-flags shape as k9_track_certified above
-- (display-only gate: "is at least one mode even switched on"), tested the
-- identical way -- not folded into FALSE_BY_DEFAULT_SINGLE_ITEM_CASES since
-- that helper assumes a strict one-flag-to-one-item mapping this item does
-- not have.
-- ----------------------------------------------------------------------
t.test('k9_vision_cycle: absent when NightVision and ThermalVision are both false (this baseline)', function()
    local f = newRadialFixture()
    t.isNil(f.findK9Item('k9_vision_cycle'))
end)

for _, flag in ipairs({ 'NightVision', 'ThermalVision' }) do
    t.test(('k9_vision_cycle: appears when ONLY %s is true (gated on an OR of the two, not an AND)'):format(flag), function()
        local f = newRadialFixture({ features = { [flag] = true } })
        t.isNotNil(f.findK9Item('k9_vision_cycle'), ('k9_vision_cycle must appear once %s alone is true'):format(flag))
    end)
end

t.test('k9_vision_cycle: onSelect calls CycleVision() exactly once, and consults NEITHER CanShowK9UI NOR HasK9Access -- deliberately ungated, matching client/vision.lua\'s own IsOwnModelK9()-only philosophy', function()
    local f = newRadialFixture({ features = { NightVision = true }, canShowK9UI = false, hasK9Access = false })
    f.findK9Item('k9_vision_cycle').onSelect()
    t.equals(#f.calls.CycleVision, 1)
    t.equals(f.canShowK9UICallCount(), 0, 'k9_vision_cycle must never call CanShowK9UI -- gating is CycleVision()/Toggle*Vision()\'s own job (IsOwnModelK9() only)')
    t.equals(f.hasK9AccessCallCount(), 0, 'k9_vision_cycle must never call HasK9Access either, for the same reason')
    t.equals(f.denyCallCount(), 0, 'no DenyK9UIAccess call either, since the gate it would guard is never consulted')
end)

t.test('FIXED-SHAPE GUARD: k9_vision_cycle does not throw when CycleVision is entirely absent', function()
    local f = newRadialFixture({ features = { ThermalVision = true }, omit = { 'CycleVision' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_vision_cycle'))
end)

-- ----------------------------------------------------------------------
-- Per-flag presence: flags that ship TRUE (Phase 1) -- prove the item
-- disappears when explicitly turned off, the mirror image of the cases
-- above.
-- ----------------------------------------------------------------------

local TRUE_BY_DEFAULT_SINGLE_ITEM_CASES = {
    { flag = 'LeashMechanics', itemId = 'k9_leash' },
    { flag = 'VehicleEntryExit', itemId = 'k9_vehicle' },
}

for _, case in ipairs(TRUE_BY_DEFAULT_SINGLE_ITEM_CASES) do
    t.test(('%s: present under this spec\'s baseline (Config.Features.%s = true)'):format(case.itemId, case.flag), function()
        local f = newRadialFixture()
        t.isNotNil(f.findK9Item(case.itemId))
    end)

    t.test(('%s: absent when Config.Features.%s is explicitly turned off'):format(case.itemId, case.flag), function()
        local f = newRadialFixture({ features = { [case.flag] = false } })
        t.isNil(f.findK9Item(case.itemId))
    end)
end

-- k9_sit has NO dedicated Config.Features flag at all (bundled under the
-- general RadialMenu flag + per-onSelect access check only, per its own
-- comment) -- prove it stays present even with every OTHER flag off.
t.test('k9_sit: present regardless of every other feature flag, since it has no dedicated flag of its own', function()
    local f = newRadialFixture({ features = {
        LeashMechanics = false, VehicleEntryExit = false, BasicBarkSounds = false,
    } })
    t.isNotNil(f.findInMenu('k9unit_utility', 'k9_sit'))
end)

-- ----------------------------------------------------------------------
-- HandlerPartnership -- ONE flag gates TWO items (Break Partnership AND
-- Partner Up), both flat in the k9unit submenu.
-- ----------------------------------------------------------------------

t.test('HandlerPartnership explicitly false: no partnership item appears', function()
    local f = newRadialFixture()
    t.isNil(f.findK9Item('k9_partner'))
end)

t.test('HandlerPartnership true: ONE "Partner Up / Break Partnership" item, not two', function()
    local f = newRadialFixture({ features = { HandlerPartnership = true } })
    local item = f.findK9Item('k9_partner')
    t.isNotNil(item)
    t.equals(item.label, locale('radial.partner_toggle_label'))
    t.isNil(f.findK9Item('k9_break_partnership'))
    t.isNil(f.findK9Item('k9_partner_up'))
end)

-- ----------------------------------------------------------------------
-- FetchMechanic -- ONE Fetch item (the rework pass), no sub-menu. It hands
-- to client/fetch.lua's FetchContextual(), which picks drop/recall/throw.
-- ----------------------------------------------------------------------

t.test('FetchMechanic explicitly false: no Fetch item and no fetch sub-menu', function()
    local f = newRadialFixture()
    t.isNil(f.findMenu('k9unit_fetch'))
    t.isNil(f.findK9Item('k9_fetch'))
end)

t.test('FetchMechanic true: ONE Fetch item that acts in a single click -- no sub-menu to open first', function()
    local f = newRadialFixture({ features = { FetchMechanic = true } })
    local item = f.findK9Item('k9_fetch')
    t.isNotNil(item)
    t.isNil(item.menu, 'not a sub-menu link')
    t.isNil(f.findMenu('k9unit_fetch'), 'the old Throw/Recall sub-menu is gone')

    item.onSelect()
    t.equals(#f.calls.FetchContextual, 1, 'one click runs the shared drop / recall / throw choice')
end)

t.test('FetchMechanic true: a missing FetchContextual does not throw', function()
    local f = newRadialFixture({ features = { FetchMechanic = true }, omit = { 'FetchContextual' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_fetch'))
end)

-- ----------------------------------------------------------------------
-- BasicBarkSounds / AdvancedBarkRadial -- the one item whose SHAPE (not
-- just presence) changes with a second, layered flag.
-- ----------------------------------------------------------------------

t.test('BasicBarkSounds false: k9_bark is entirely absent, even though AdvancedBarkRadial defaults to false too (nothing to layer onto)', function()
    local f = newRadialFixture({ features = { BasicBarkSounds = false } })
    t.isNil(f.findK9Item('k9_bark'))
    t.isNil(f.findMenu('k9unit_bark'))
end)

t.test('BasicBarkSounds false: staying off even with AdvancedBarkRadial forced true still yields no k9_bark item at all (Bark requires BasicBarkSounds underneath it)', function()
    local f = newRadialFixture({ features = { BasicBarkSounds = false, AdvancedBarkRadial = true } })
    t.isNil(f.findK9Item('k9_bark'))
    t.isNil(f.findMenu('k9unit_bark'), 'the nested variant submenu must not be built at all when the prerequisite flag is off')
end)

t.test('BasicBarkSounds true, AdvancedBarkRadial false: a single k9_bark item with its own onSelect, sending the literal barkType "bark"', function()
    local f = newRadialFixture()
    local item = f.findK9Item('k9_bark')
    t.isNotNil(item)
    t.isNil(item.menu, 'without AdvancedBarkRadial this must be a terminal action, not a submenu link')
    t.isNotNil(item.onSelect)
    t.equals(item.label, locale('radial.bark_label'))

    item.onSelect()
    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].event, 'john-k9:server:relayBark')
    t.equals(f.triggerServerEventCalls[1].args[1], 'bark')
end)

-- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission audit
-- finding, this pass) -- server/main.lua's relayBark handler gates on
-- HasK9Access(src) alone -- no existing test in this file exercised the
-- basic (non-Advanced) Bark item's access gate at all before this pass.
t.test('BasicBarkSounds true, AdvancedBarkRadial false: k9_bark is gated on HasK9Access() alone (widened) -- denied with combat.no_access; a bypass holder (HasK9Access true, CanShowK9UI false) is offered', function()
    local fDenied = newRadialFixture({ hasK9Access = false, canShowK9UI = false })
    fDenied.findK9Item('k9_bark').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.equals(fDenied.lastDenyReason(), 'combat.no_access')
    t.equals(#fDenied.triggerServerEventCalls, 0)

    local fBypass = newRadialFixture({ hasK9Access = true, canShowK9UI = false })
    fBypass.findK9Item('k9_bark').onSelect()
    t.equals(fBypass.denyCallCount(), 0)
    t.equals(#fBypass.triggerServerEventCalls, 1)
    t.equals(fBypass.triggerServerEventCalls[1].args[1], 'bark')
end)

t.test('BasicBarkSounds true + AdvancedBarkRadial true: k9_bark becomes a pure navigation link into k9unit_bark, carrying no onSelect of its own', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })
    local item = f.findK9Item('k9_bark')
    t.isNotNil(item)
    t.equals(item.menu, 'k9unit_bark')
    t.isNil(item.onSelect)
end)

t.test('AdvancedBarkRadial true: k9unit_bark contains exactly one item per REAL config.lua Config.AdvancedBarkRadial entry, with matching id/label/icon, each sending its own barkType', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })
    local variants = f.Config.AdvancedBarkRadial
    local items = f.findMenu('k9unit_bark')
    t.isNotNil(items)
    t.equals(#items, #variants, 'one submenu item per REAL config.lua variant -- not a hardcoded count')

    for _, variant in ipairs(variants) do
        local item = f.findInMenu('k9unit_bark', 'k9_bark_' .. variant.barkType)
        t.isNotNil(item, ('missing submenu item for real config.lua variant %s'):format(variant.barkType))
        t.equals(item.label, variant.label)
        t.equals(item.icon, variant.icon)
        t.isNil(item.menu, 'each variant is a terminal action, not a further navigation link')

        item.onSelect()
    end

    t.equals(#f.triggerServerEventCalls, #variants)
    for i, variant in ipairs(variants) do
        t.equals(f.triggerServerEventCalls[i].event, 'john-k9:server:relayBark')
        t.equals(f.triggerServerEventCalls[i].args[1], variant.barkType, 'each variant must send ITS OWN barkType, not a shared/last-iteration one (the exact Lua closure-capture bug this file\'s own header warns a naive loop could introduce)')
    end
end)

t.test('AdvancedBarkRadial true: each variant item is ALSO gated on HasK9Access() alone (widened), same as the basic Bark item', function()
    local fDenied = newRadialFixture({ features = { AdvancedBarkRadial = true }, hasK9Access = false, canShowK9UI = false })
    local variant = fDenied.Config.AdvancedBarkRadial[1]
    fDenied.findInMenu('k9unit_bark', 'k9_bark_' .. variant.barkType).onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.equals(fDenied.lastDenyReason(), 'combat.no_access')
    t.equals(#fDenied.triggerServerEventCalls, 0)

    local fBypass = newRadialFixture({ features = { AdvancedBarkRadial = true }, hasK9Access = true, canShowK9UI = false })
    fBypass.findInMenu('k9unit_bark', 'k9_bark_' .. variant.barkType).onSelect()
    t.equals(fBypass.denyCallCount(), 0)
    t.equals(#fBypass.triggerServerEventCalls, 1)
end)

-- ----------------------------------------------------------------------
-- k9_open_tablet (Command Tablet) -- NESTING BUG FIX, this pass. Found
-- while doing the Job 3 regrouping pass: this item used to be registered
-- from a code position textually INSIDE the
-- `if Config.Features.AdvancedBarkRadial and not
-- IsRadialFeatureBlockedForMe('AdvancedBarkRadial') then` branch, so it only
-- ever appeared when BOTH CommandTablet AND AdvancedBarkRadial were true --
-- even though its own, only intended gate is Config.Features.CommandTablet
-- alone. The tests below pin that this is now genuinely fixed: present
-- whenever CommandTablet is true, REGARDLESS of AdvancedBarkRadial's value.
-- ----------------------------------------------------------------------

t.test('k9_open_tablet: absent when Config.Features.CommandTablet is false, regardless of AdvancedBarkRadial', function()
    local fBasic = newRadialFixture({ features = { CommandTablet = false, AdvancedBarkRadial = false } })
    t.isNil(fBasic.findK9Item('k9_open_tablet'))

    local fAdvanced = newRadialFixture({ features = { CommandTablet = false, AdvancedBarkRadial = true } })
    t.isNil(fAdvanced.findK9Item('k9_open_tablet'))
end)

t.test('THE BUG THIS PASS FIXES: k9_open_tablet is present when CommandTablet is true AND AdvancedBarkRadial is false -- it used to be silently absent in exactly this combination', function()
    local f = newRadialFixture({ features = { CommandTablet = true, AdvancedBarkRadial = false } })
    local item = f.findK9Item('k9_open_tablet')
    t.isNotNil(item, 'k9_open_tablet must appear whenever CommandTablet is true, independent of AdvancedBarkRadial -- this is the exact nesting bug this pass fixes')
    t.equals(item.label, locale('radial.tablet_label'))

    item.onSelect()
    t.equals(#f.calls.OpenTablet, 1)
end)

t.test('k9_open_tablet: also present when BOTH CommandTablet and AdvancedBarkRadial are true (the one combination that already worked before this fix)', function()
    local f = newRadialFixture({ features = { CommandTablet = true, AdvancedBarkRadial = true } })
    t.isNotNil(f.findK9Item('k9_open_tablet'))
end)

t.test('k9_open_tablet: guarded -- absent OpenTablet does not throw', function()
    local f = newRadialFixture({ features = { CommandTablet = true }, omit = { 'OpenTablet' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_open_tablet'))
end)

-- ----------------------------------------------------------------------
-- RadialMenu=false suppresses the entire feature, REGARDLESS of every
-- other flag -- the task's own explicitly-named priority case.
-- ----------------------------------------------------------------------

t.test('RadialMenu=false: the k9unit submenu and its root opener never get registered, even with every OTHER feature flag turned on', function()
    local f = newRadialFixture({ features = {
        RadialMenu = false,
        LeashMechanics = true, VehicleEntryExit = true, BasicBarkSounds = true,
        AdvancedBarkRadial = true, ScentTracking = true, BloodTracking = true,
        GunpowderSniffing = true, BiteAndHold = true, NonLethalTakedown = true,
        PropDragging = true, HandlerPartnership = true, FetchMechanic = true, PropAttachments = true,
        DeployableKennel = true, K9Inventory = true, K9Medkit = true,
    } })

    t.isNil(f.findMenu('k9unit'), 'the k9unit submenu itself must never be registered when RadialMenu is false')
    t.isNil(f.findRootItem('k9unit_open'), 'no opener can reach a menu that was never registered')
    t.equals(#f.addRadialItemCalls, 0, 'lib.addRadialItem must never be called at all when RadialMenu is false')

    -- DISCLOSED NUANCE, not a bug this spec is asked to fix: the source's
    -- own `if Config.Features.RadialMenu then ... end` wrapper is the LAST
    -- block in the file and only guards the k9unit registerRadial + its
    -- root opener addRadialItem call. The k9unit_bark/k9unit_defense/
    -- k9unit_fetch nested submenus are each registered independently,
    -- earlier in the file, gated ONLY on their OWN sub-feature flag -- NOT
    -- on RadialMenu at all. With RadialMenu=false they still get
    -- registered in ox_lib's own menu registry, just as ORPHANS nothing
    -- links to (the only item that would link to them, k9_bark/k9_defense/
    -- k9_fetch, lives inside k9SubmenuItems, which is never itself
    -- registered as 'k9unit' in this scenario). Practically inert --
    -- nothing in the actual radial WHEEL is reachable -- but not literally
    -- "lib.registerRadial is never called again after RadialMenu is
    -- false," which is why this test asserts on 'k9unit' specifically and
    -- the opener, not on registerRadialCalls being empty outright.
    t.isNotNil(f.findMenu('k9unit_bark'), 'orphaned, but genuinely still registered -- see comment above')
end)

-- ----------------------------------------------------------------------
-- No two items share an id, across a fixture with EVERY flag enabled.
-- ----------------------------------------------------------------------

t.test('no two registered items (across every submenu and the root wheel) share the same id, with every feature flag turned on', function()
    local f = newRadialFixture({ features = {
        RadialMenu = true, LeashMechanics = true, VehicleEntryExit = true,
        BasicBarkSounds = true, AdvancedBarkRadial = true, ScentTracking = true,
        BloodTracking = true, GunpowderSniffing = true, BiteAndHold = true,
        NonLethalTakedown = true, PropDragging = true, HandlerPartnership = true,
        FetchMechanic = true,
        PropAttachments = true, DeployableKennel = true, K9Inventory = true,
        K9Medkit = true, } })

    local ids = f.allIds()
    t.isTrue(#ids > 20, 'sanity: this fixture should have produced a large number of items, or this test is not exercising what it claims to')

    local seen = {}
    for _, id in ipairs(ids) do
        t.isNil(seen[id], ('duplicate radial item id found: %s'):format(tostring(id)))
        seen[id] = true
    end
end)

-- ----------------------------------------------------------------------
-- onSelect targets: the `type(fn) == 'function'` guard -- present for
-- every item wired to client/partnership.lua, client/fetch.lua,
-- client/propattachment.lua, client/kennel.lua, client/inventory.lua and
-- client/medkit.lua (per this
-- file's own header: "Every cross-file global added after this file's own
-- initial Phase 1 pass is called behind a type(fn) == 'function' runtime
-- existence guard"). Each case below proves the guard actually holds --
-- onSelect must not throw even when the target global is entirely absent
-- from the sandbox -- and that a PRESENT target really does get called
-- with the right arguments once access is granted.
-- ----------------------------------------------------------------------

t.test('k9_partner: hands straight to TogglePartnership (which decides break vs partner up) -- never gated here, and a missing TogglePartnership does not throw', function()
    local fAbsent = newRadialFixture({ features = { HandlerPartnership = true }, omit = { 'TogglePartnership' }, canShowK9UI = false })
    assertGuardDoesNotThrow(fAbsent.findK9Item('k9_partner'))

    local f = newRadialFixture({ features = { HandlerPartnership = true }, canShowK9UI = false })
    f.findK9Item('k9_partner').onSelect()
    f.stepThreads()
    t.equals(#f.calls.TogglePartnership, 1, 'the one shared toggle ran')
    t.equals(f.denyCallCount(), 0, 'the menu item adds no gate of its own -- breaking must always be reachable')
end)

-- UPDATED: this test used to pin the exact bug it was meant to prevent.
-- It asserted that the vest item REFUSES when CanShowK9UI() is false and
-- never reaches RequestToggleK9PropAttachment. But that function is the one
-- that decides whether the press is an ADD or a REMOVE, and it deliberately
-- lets a REMOVE through unconditionally -- because taking off a vest you are
-- already wearing is not a capability. Gating before it meant a handler who
-- lost their certification while wearing one could not take it off from the
-- radial menu, and decertification does not strip prop attachments
-- server-side the way it strips leashes and holds. So the item is now
-- ungated and the strictness lives in the callee, which knows the direction.
--
-- What this test pins now: the item ALWAYS reaches the callee, and the
-- callee is trusted to apply the ADD gate (and to emit the same denial
-- reason) itself. tests/clientpropattachment_spec.lua owns proving that.
t.test('k9_prop_attachment: always reaches the toggle, which resolves add-vs-remove before gating -- so a lapsed handler can still take a vest OFF', function()
    local fAbsent = newRadialFixture({ features = { PropAttachments = true, DeployableKennel = true }, omit = { 'RequestToggleK9PropAttachment', 'RequestDeployKennel' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_utility', 'k9_prop_attachment'))

    local fDenied = newRadialFixture({ features = { PropAttachments = true, DeployableKennel = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit_utility', 'k9_prop_attachment').onSelect()
    t.equals(fDenied.denyCallCount(), 0, 'the radial item itself must NOT deny -- it cannot tell an add from a remove, so it defers')
    t.isNotNil(fDenied.calls.RequestToggleK9PropAttachment, 'the toggle is reached even with access refused, so the remove path stays open')
    t.isNil(fDenied.calls.RequestDeployKennel)

    local fGranted = newRadialFixture({ features = { PropAttachments = true, DeployableKennel = true } })
    fGranted.findInMenu('k9unit_utility', 'k9_prop_attachment').onSelect()
    t.equals(#fGranted.calls.RequestToggleK9PropAttachment, 1)
end)

-- THE TWO ITEMS THIS TASK EXPLICITLY PRIORITISED: "Open My Gear" and
-- "Treat K9" -- both recently wired, both behind flags that ship false.
-- Full treatment (presence already proven above): guard + access gate +
-- happy-path call. Both MOVED into 'k9unit_utility' (Job 3 regrouping).
t.test('k9_open_inventory ("Open My Gear"): guarded -- absent RequestOpenOwnK9Inventory does not throw; denied access never calls it; granted access calls it', function()
    local fAbsent = newRadialFixture({ features = { K9Inventory = true }, omit = { 'RequestOpenOwnK9Inventory' } })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_utility', 'k9_open_inventory'))

    local fDenied = newRadialFixture({ features = { K9Inventory = true }, canShowK9UI = false })
    fDenied.findInMenu('k9unit_utility', 'k9_open_inventory').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.equals(fDenied.lastDenyReason(), 'common.no_k9_role_or_access', 'NOT WIDENED (server/inventory.lua requires model/role AND access for the K9 whose gear is opened) -- see this item\'s own comment in client/radial.lua')
    t.isNil(fDenied.calls.RequestOpenOwnK9Inventory)

    local fGranted = newRadialFixture({ features = { K9Inventory = true } })
    fGranted.findInMenu('k9unit_utility', 'k9_open_inventory').onSelect()
    t.equals(#fGranted.calls.RequestOpenOwnK9Inventory, 1)
    t.equals(fGranted.findInMenu('k9unit_utility', 'k9_open_inventory').label, locale('radial.open_inventory_label'))
end)

-- CanShowK9UI() PRE-CHECK REMOVED (ease-of-use/permission audit finding,
-- this pass) -- "Treat K9" is a HUMAN HANDLER action (job-only eligibility
-- server-side, per server/medkit.lua's own header), not a K9 ability; this
-- item's own onSelect no longer gates on CanShowK9UI() at all, matching
-- client/medkit.lua's own RequestTreatNearestK9() (which had its own
-- matching, redundant pre-check removed in the same pass) and this file's
-- own "Treat K9" ox_target `canInteract` predicate (which never checked the
-- treater's own role either). This is a REPLACEMENT for the old "guarded +
-- access gate + happy path" test below, not an addition to it -- the old
-- test's own "denied access never calls it" assertion described exactly
-- the behavior this pass fixes.
t.test('k9_treat_nearest ("Treat K9"): guarded -- absent RequestTreatNearestK9 does not throw; CanShowK9UI() is NEVER checked; it always calls through regardless of role/access (the server is the real gate)', function()
    local fAbsent = newRadialFixture({ features = { K9Medkit = true }, omit = { 'RequestTreatNearestK9' }, playingDog = false })
    assertGuardDoesNotThrow(fAbsent.findInMenu('k9unit_utility', 'k9_treat_nearest'))

    -- The exact case this pass fixes: CanShowK9UI() false (not a K9 role
    -- holder at all -- e.g. a plain PD/EMS officer with no K9 certification)
    -- must still reach RequestTreatNearestK9(), never DenyK9UIAccess() at
    -- this layer.
    local fNotAK9 = newRadialFixture({ features = { K9Medkit = true }, canShowK9UI = false, playingDog = false })
    fNotAK9.findInMenu('k9unit_utility', 'k9_treat_nearest').onSelect()
    t.equals(fNotAK9.denyCallCount(), 0, 'this item must never call DenyK9UIAccess() itself -- CanShowK9UI() is not this action\'s gate')
    t.equals(fNotAK9.canShowK9UICallCount(), 0, 'CanShowK9UI() must not even be READ by this onSelect -- it was fully removed, not merely ignored')
    t.equals(#fNotAK9.calls.RequestTreatNearestK9, 1)

    local fGranted = newRadialFixture({ features = { K9Medkit = true }, playingDog = false })
    fGranted.findInMenu('k9unit_utility', 'k9_treat_nearest').onSelect()
    t.equals(#fGranted.calls.RequestTreatNearestK9, 1)
    -- Reuses medkit.treat_target_label rather than minting a duplicate key,
    -- per this item's own comment -- confirmed against the real label.
    t.equals(fGranted.findInMenu('k9unit_utility', 'k9_treat_nearest').label, locale('medkit.treat_target_label'))
end)

-- ----------------------------------------------------------------------
-- HEADER/CODE DRIFT FIX (dependency-verification pass): Sit, Leash,
-- Vehicle, the three Track items, and Bite&Hold/Takedown/Drag used to call
-- their cross-file target DIRECTLY, with no type()=='function' guard --
-- contradicting this file's own header, which claims a BLANKET "every
-- cross-file global added after this file's own initial Phase 1 pass is
-- called behind a type(fn)=='function' guard" policy. That was never
-- reachable with a genuinely nil target in a real session
-- (fxmanifest.lua loads client/movement.lua/client/vehicle.lua/
-- client/tracking.lua/client/combat.lua as part of the SAME resource
-- start, always complete before any player action can fire an onSelect
-- closure), so this was a documentation/implementation drift, not a live
-- safety bug -- but per this pass's own instruction to make the header and
-- the code agree, client/radial.lua now wraps every one of these nine call
-- sites in the exact same guard every other post-Phase-1 item already
-- uses. The header's blanket claim is therefore no longer false for any
-- item in this file. Every case below now proves the FIXED (guarded,
-- non-throwing) behavior, same `assertGuardDoesNotThrow` shape already
-- used for every other guarded item above -- not that a throw was merely
-- possible in theory.
--
-- CROSS-FLAG GAP CHECK (the substantive question a guard-vs-header choice
-- actually turns on, not just "does the header technically say guard
-- everything"): every item this fix touches calls a global from the SAME
-- feature area gated by the SAME Config.Features flag the item itself is
-- registered under (k9_leash + LeashMechanics both live in
-- client/movement.lua's own gate; k9_vehicle + VehicleEntryExit both in
-- client/vehicle.lua's; k9_track_* + its own Scent/Blood/GunpowderSniffing
-- flag in client/tracking.lua's; k9_bite_hold/k9_takedown/k9_drag each
-- paired with client/combat.lua's matching BiteAndHold/NonLethalTakedown/
-- PropDragging flag) -- so there is no real combination of flags where one
-- of these items is registered but its OWN target file never defines the
-- matching global at all; k9_sit is the sole exception (no dedicated flag
-- of its own), but K9Sit() is defined unconditionally in
-- client/movement.lua regardless of any feature flag. This is a narrower,
-- same-flag correspondence than client/vehicle.lua's own newly-added
-- IsDragEngaged()/IsBiteHoldEngaged() guard (a genuine CROSS-flag case:
-- VehicleEntryExit can be enabled on a server running NONE of
-- BiteAndHold/NonLethalTakedown/PropDragging, in which case
-- client/combat.lua's globals are never declared at all) -- so unlike that
-- one, every guard added here is defensive/redundant given the real
-- feature-flag graph, not load-bearing against an actual reachable gap.
-- Added anyway, for the same reason this file already gives for every
-- other redundant guard it carries (BreakPartnership's own comment: "kept
-- anyway... it costs nothing to honor that against, say, a future
-- load-order change") -- and because it is what makes the header's own
-- blanket claim true rather than false.
-- ----------------------------------------------------------------------

t.test('FIXED: k9_sit is now guarded -- absent K9Sit does not throw', function()
    local f = newRadialFixture({ omit = { 'K9Sit' } })
    assertGuardDoesNotThrow(f.findInMenu('k9unit_utility', 'k9_sit'))
end)

t.test('FIXED: k9_vehicle is now guarded -- absent IsInK9Vehicle/EnterNearestK9Vehicle/ExitK9Vehicle does not throw in either direction', function()
    local fEnter = newRadialFixture({ features = { VehicleEntryExit = true }, omit = { 'IsInK9Vehicle', 'EnterNearestK9Vehicle' } })
    assertGuardDoesNotThrow(fEnter.findK9Item('k9_vehicle'))

    local fExit = newRadialFixture({ features = { VehicleEntryExit = true }, omit = { 'IsInK9Vehicle', 'ExitK9Vehicle' } })
    fExit.setState('isInK9Vehicle', true)
    assertGuardDoesNotThrow(fExit.findK9Item('k9_vehicle'))
end)

t.test('FIXED: k9_track_certified is guarded -- absent IsTracking/StartCertifiedTrack does not throw in either branch', function()
    local fStart = newRadialFixture({ features = { ScentTracking = true }, omit = { 'IsTracking', 'StartCertifiedTrack' } })
    assertGuardDoesNotThrow(fStart.findK9Item('k9_track_certified'))

    local fStop = newRadialFixture({ features = { ScentTracking = true }, omit = { 'StopTracking' } })
    fStop.setState('isTracking', true)
    assertGuardDoesNotThrow(fStop.findK9Item('k9_track_certified'))
end)

t.test('FIXED: k9_bite_hold/k9_takedown/k9_drag are now guarded -- absent targets do not throw in either branch', function()
    local fStart = newRadialFixture({ features = { BiteAndHold = true, NonLethalTakedown = true, PropDragging = true }, omit = { 'IsBiteHoldEngaged', 'RequestBiteHold', 'RequestTakedown', 'IsDragEngaged', 'RequestDrag' } })
    assertGuardDoesNotThrow(fStart.findK9Item('k9_bite_hold'))
    assertGuardDoesNotThrow(fStart.findK9Item('k9_takedown'))
    assertGuardDoesNotThrow(fStart.findK9Item('k9_drag'))

    local fRelease = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, omit = { 'ReleaseBiteHold', 'ReleaseDrag' } })
    fRelease.setState('isBiteHoldEngaged', true)
    fRelease.setState('isDragEngaged', true)
    assertGuardDoesNotThrow(fRelease.findK9Item('k9_bite_hold'))
    assertGuardDoesNotThrow(fRelease.findK9Item('k9_drag'))
end)

t.test('k9_takedown: present RequestTakedown is called once access is granted (the one call-through this file had not yet pinned)', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true } })
    f.findK9Item('k9_takedown').onSelect()
    t.equals(#f.calls.RequestTakedown, 1)
end)

-- ----------------------------------------------------------------------
-- Access gating correctness for the UNGUARDED items above -- this matters
-- MORE than the guard nuance: proving the right branch is chosen and
-- CanShowK9UI/DenyK9UIAccess fire (or deliberately don't) exactly where
-- this file's own comments say they should.
-- ----------------------------------------------------------------------

t.test('k9_sit: denied access never calls K9Sit; granted access calls it', function()
    local fDenied = newRadialFixture({ canShowK9UI = false })
    fDenied.findInMenu('k9unit_utility', 'k9_sit').onSelect()
    t.equals(fDenied.denyCallCount(), 1)
    t.isNil(fDenied.calls.K9Sit)

    local fGranted = newRadialFixture({ canShowK9UI = true })
    fGranted.findInMenu('k9unit_utility', 'k9_sit').onSelect()
    t.equals(#fGranted.calls.K9Sit, 1)
end)

t.test('k9_leash: while leashed, Detach fires UNGATED (CanShowK9UI never even asked); while not leashed, Attach is GATED', function()
    local fDetach = newRadialFixture({ features = { LeashMechanics = true }, canShowK9UI = false })
    fDetach.setState('isLeashed', true)
    fDetach.findK9Item('k9_leash').onSelect()
    t.equals(#fDetach.calls.DetachLeash, 1)
    t.equals(fDetach.canShowK9UICallCount(), 0, 'Detach must never consult CanShowK9UI at all, per the "no unbounded trap" comment')
    t.equals(fDetach.denyCallCount(), 0)

    local fAttachDenied = newRadialFixture({ features = { LeashMechanics = true }, canShowK9UI = false })
    fAttachDenied.setState('isLeashed', false)
    fAttachDenied.findK9Item('k9_leash').onSelect()
    t.equals(fAttachDenied.denyCallCount(), 1)
    t.isNil(fAttachDenied.calls.RequestLeashAttach)
end)

t.test('k9_leash: Attach finds the nearest in-range candidate and calls RequestLeashAttach with their server id; out of Config.LeashMaxDistance range is treated as no candidate', function()
    local f = newRadialFixture({ features = { LeashMechanics = true } })
    f.setState('isLeashed', false)
    f.setActivePlayers({ 4, 5 })
    f.setPlayerPed(4, 100)
    f.setPedCoords(100, vec3(f.Config.LeashMaxDistance + 1, 0, 0)) -- just OUT of range
    f.setPlayerServerId(4, 111)
    f.setPlayerPed(5, 101)
    f.setPedCoords(101, vec3(2, 0, 0)) -- in range
    f.setPlayerServerId(5, 222)

    f.findK9Item('k9_leash').onSelect()
    t.equals(#f.calls.RequestLeashAttach, 1)
    t.equals(f.calls.RequestLeashAttach[1][1], 222, 'must pick the in-range candidate, never the out-of-range one, and pass their real server id')
end)

t.test('k9_leash: a human handler (not a K9, no K9 access of their own) can clip the leash on -- the menu no longer refuses the person who holds the leash', function()
    local f = newRadialFixture({ features = { LeashMechanics = true }, playingDog = false, canShowK9UI = false, dogPeds = { [101] = true } })
    f.setState('isLeashed', false)
    f.setActivePlayers({ 5 })
    f.setPlayerPed(5, 101)
    f.setPedCoords(101, vec3(1, 0, 0))
    f.setPlayerServerId(5, 222)
    f.findK9Item('k9_leash').onSelect()
    t.equals(f.denyCallCount(), 0)
    t.equals(#f.calls.RequestLeashAttach, 1)
    t.equals(f.calls.RequestLeashAttach[1][1], 222)
end)

t.test('k9_leash: the handler gets their DOG even when a bystander is standing closer', function()
    local f = newRadialFixture({ features = { LeashMechanics = true }, playingDog = false, dogPeds = { [101] = true } })
    f.setState('isLeashed', false)
    f.setActivePlayers({ 4, 5 })
    f.setPlayerPed(4, 100)
    f.setPedCoords(100, vec3(0.5, 0, 0)) -- a bystander, right next to the handler
    f.setPlayerServerId(4, 111)
    f.setPlayerPed(5, 101)
    f.setPedCoords(101, vec3(2, 0, 0)) -- the dog, a little further
    f.setPlayerServerId(5, 222)
    f.findK9Item('k9_leash').onSelect()
    t.equals(f.calls.RequestLeashAttach[1][1], 222)
end)

t.test('k9_leash: Attach with nobody in range notifies radial.no_leash_candidate and never calls RequestLeashAttach', function()
    local f = newRadialFixture({ features = { LeashMechanics = true } })
    f.setState('isLeashed', false)
    f.setActivePlayers({})
    f.findK9Item('k9_leash').onSelect()
    t.isNil(f.calls.RequestLeashAttach)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('radial.no_leash_candidate'))
end)

t.test('k9_kennel: UNCONDITIONAL REGISTRATION (trap-hunt fix) -- present with EVERY Config.Features flag off, including DeployableKennel, unlike Deploy Kennel immediately above it. See this item\'s own source comment for why a widened-but-not-actually-live gate (the shape k9_leash uses) was deliberately rejected here', function()
    local f = newRadialFixture({ features = {
        DeployableKennel = false, LeashMechanics = false, VehicleEntryExit = false, BasicBarkSounds = false,
    } })
    t.isNotNil(f.findK9Item('k9_kennel'), 'must be present regardless of every feature flag -- a confining-mechanic escape hatch must never be hideable')
end)

t.test('k9_kennel: onSelect fires UNGATED -- CanShowK9UI/DenyK9UIAccess are never even consulted, unlike Deploy Kennel immediately above it', function()
    local f = newRadialFixture({ features = { DeployableKennel = false }, canShowK9UI = false })
    f.findK9Item('k9_kennel').onSelect()
    t.equals(#f.calls.RequestKennelContextual, 1, 'must call RequestKennelContextual() regardless of CanShowK9UI() -- it carries the exit path')
    t.equals(f.canShowK9UICallCount(), 0, 'an exit path must never even ask CanShowK9UI() -- gate the START of a thing, never the STOP')
    t.equals(f.denyCallCount(), 0)
end)

t.test('k9_kennel: onSelect tolerates RequestKennelContextual being entirely absent (soft dependency) -- must not throw', function()
    local f = newRadialFixture({ omit = { 'RequestKennelContextual' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_kennel'))
end)

-- INVERTED, THIS PASS (coordinator review) -- an earlier version of THIS
-- test asserted the OPPOSITE: that k9_kennel is ABSENT when
-- DeployableKennel=false and this client is not currently resting. That
-- assertion was wrong, not the production code: a gate evaluated at
-- RegisterK9RadialMenu() time is a one-shot, boot-time snapshot (see the
-- item's own client/radial.lua comment) -- if DeployableKennel happened to
-- be false the LAST time that function ran, a widened, "present only while
-- resting" gate would leave the item permanently absent for the rest of
-- this resource's uptime regardless of what IsRestingInKennel() answers
-- LATER, which is the exact "hidden right when someone actually needs it"
-- failure this whole pass exists to close -- worse here than for the leash
-- item this pattern was copied from, since this occupant is physically
-- attached to a prop, not merely leashed. UNCONDITIONAL registration (this
-- test) is therefore the correct fix, matching Sit/Detach Leash's own
-- established "an exit-adjacent action must not be gated" precedent.
--
-- THE REAL QUESTION THIS RAISES, ANSWERED DIRECTLY BELOW: does registering
-- the item unconditionally grant ANY kennel capability on a server with
-- DeployableKennel off? NO. ExitKennelRest() is a thin wrapper over
-- ReleaseKennelRest(), which can only ever RELEASE an EXISTING restState --
-- it never deploys, never creates a kennel object, never attaches anyone TO
-- one, and (see server/kennel.lua's own requestExitKennel handler) the one
-- server event it fires only ever CLEARS a KennelOccupants entry that
-- already names this exact src, never grants one. A player on a
-- DeployableKennel=false server who was never resting gets nothing from
-- this item but a harmless no-op (proven below) -- there is no capability
-- to gate here, only a release path, so "gate the START of a thing, never
-- the STOP" applies cleanly. Before reverting this test back to asserting
-- absence, first prove ExitKennelRest() (or something it calls) has grown
-- a code path that creates/authorizes state rather than only clearing it --
-- if that ever becomes true, the gate question is real again and this test
-- (and client/radial.lua's own comment above the item) both need another
-- look.
t.test('k9_kennel: UNCONDITIONAL REGISTRATION GRANTS NOTHING OF ITS OWN -- this ITEM adds no notify/server-event/native call beyond the single RequestKennelContextual() call itself. Every real decision (which of deploy/enter/exit/close/open is meant, and every gate on those except the exit) lives in client/kennel.lua and is proven against the REAL implementation in tests/clientkennel_spec.lua; this file stubs the global as a bare recorder, so it can only prove THIS file adds no second, independent side effect on top', function()
    local f = newRadialFixture({ features = { DeployableKennel = false } })
    f.findK9Item('k9_kennel').onSelect()

    t.equals(#f.calls.RequestKennelContextual, 1, 'exactly one call, straight through -- no branching/gating logic of this item\'s own')
    t.equals(#f.notifyCalls, 0, 'this ITEM never notifies directly -- any notification is client/kennel.lua\'s own responsibility, proven elsewhere')
    t.equals(#f.triggerServerEventCalls, 0, 'this ITEM never talks to the network directly -- any server event is client/kennel.lua\'s own responsibility, proven elsewhere')
end)

-- ORDERING FIX + GATE WIDENED (permission audit finding, this pass) --
-- Exit used to sit BEHIND this item's own access gate (the exact "gate the
-- STOP" bug this codebase's own rule forbids); Exit is now checked FIRST,
-- unconditionally, exactly like Detach Leash/Release Bite & Hold/Release
-- Drag. The Enter (start) branch is separately WIDENED to HasK9Access()
-- alone, not CanShowK9UI() (server/vehicle.lua's requestVehicleSeatClaim
-- gates on HasK9Access(src) alone).
t.test('k9_vehicle: Exit is now UNGATED (ordering fix -- checked before the access gate, never denied); Enter is gated on HasK9Access() alone (widened)', function()
    local fEnterDenied = newRadialFixture({ features = { VehicleEntryExit = true }, hasK9Access = false, canShowK9UI = false })
    fEnterDenied.setState('isInK9Vehicle', false)
    fEnterDenied.findK9Item('k9_vehicle').onSelect()
    t.equals(fEnterDenied.denyCallCount(), 1)
    t.equals(fEnterDenied.lastDenyReason(), 'combat.no_access')
    t.isNil(fEnterDenied.calls.EnterNearestK9Vehicle)

    -- THE FIX: a K9 already inside a vehicle who has lost access (or never
    -- had it) must still be able to exit via this item -- never denied.
    local fExitNoAccess = newRadialFixture({ features = { VehicleEntryExit = true }, hasK9Access = false, canShowK9UI = false })
    fExitNoAccess.setState('isInK9Vehicle', true)
    fExitNoAccess.findK9Item('k9_vehicle').onSelect()
    t.equals(fExitNoAccess.denyCallCount(), 0, 'exiting a vehicle must never be denied -- this was the exact bug this pass fixes')
    t.equals(#fExitNoAccess.calls.ExitK9Vehicle, 1)

    -- THE WIDENING: a High Command/autoAccessGrade-bypass holder (HasK9Access
    -- true, CanShowK9UI false) must now be offered Enter too. RESIDUAL,
    -- DISCLOSED GAP: client/vehicle.lua's own EnterNearestK9Vehicle() (not
    -- loaded/exercised by this isolated spec) still internally re-gates on
    -- CanShowK9UI() as of this same pass -- see client/radial.lua's own
    -- comment on this item for the full writeup.
    local fEnterBypass = newRadialFixture({ features = { VehicleEntryExit = true }, hasK9Access = true, canShowK9UI = false })
    fEnterBypass.setState('isInK9Vehicle', false)
    fEnterBypass.findK9Item('k9_vehicle').onSelect()
    t.equals(fEnterBypass.denyCallCount(), 0)
    t.equals(#fEnterBypass.calls.EnterNearestK9Vehicle, 1)
end)

t.test('k9_vehicle: granted access chooses Enter or Exit based on IsInK9Vehicle()', function()
    local fEnter = newRadialFixture({ features = { VehicleEntryExit = true } })
    fEnter.setState('isInK9Vehicle', false)
    fEnter.findK9Item('k9_vehicle').onSelect()
    t.equals(#fEnter.calls.EnterNearestK9Vehicle, 1)
    t.isNil(fEnter.calls.ExitK9Vehicle)

    local fExit = newRadialFixture({ features = { VehicleEntryExit = true } })
    fExit.setState('isInK9Vehicle', true)
    fExit.findK9Item('k9_vehicle').onSelect()
    t.equals(#fExit.calls.ExitK9Vehicle, 1)
    t.isNil(fExit.calls.EnterNearestK9Vehicle)
end)

-- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission audit
-- finding, this pass) -- server/combat.lua's shared ValidateCombatRequest
-- (backing requestBiteHold/requestTakedown/requestDrag) gates on
-- HasK9Access(src) alone. `hasK9Access = false` is therefore the real
-- denial case now for the Start branch.
t.test('k9_bite_hold / k9_drag: the Release branch is UNGATED; the Start branch is GATED on HasK9Access() alone (widened)', function()
    local fRelease = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, hasK9Access = false, canShowK9UI = false })
    fRelease.setState('isBiteHoldEngaged', true)
    fRelease.setState('isDragEngaged', true)
    fRelease.findK9Item('k9_bite_hold').onSelect()
    fRelease.findK9Item('k9_drag').onSelect()
    t.equals(#fRelease.calls.ReleaseBiteHold, 1)
    t.equals(#fRelease.calls.ReleaseDrag, 1)
    t.equals(fRelease.denyCallCount(), 0, 'neither release branch may ever call DenyK9UIAccess')

    local fStartDenied = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, hasK9Access = false, canShowK9UI = false })
    fStartDenied.setState('isBiteHoldEngaged', false)
    fStartDenied.setState('isDragEngaged', false)
    fStartDenied.findK9Item('k9_bite_hold').onSelect()
    fStartDenied.findK9Item('k9_drag').onSelect()
    t.equals(fStartDenied.denyCallCount(), 2)
    t.equals(fStartDenied.lastDenyReason(), 'combat.no_access')
    t.isNil(fStartDenied.calls.RequestBiteHold)
    t.isNil(fStartDenied.calls.RequestDrag)

    -- THE WIDENING: a High Command/autoAccessGrade-bypass holder (HasK9Access
    -- true, CanShowK9UI false) must now be offered both Start branches.
    -- RESIDUAL, DISCLOSED GAP: client/combat.lua's own RequestBiteHold()/
    -- RequestDrag() (not loaded/exercised by this isolated spec) still
    -- internally re-gate on CanShowK9UI() as of this same pass -- see
    -- client/radial.lua's own comment on these items for the full writeup.
    local fBypass = newRadialFixture({ features = { BiteAndHold = true, PropDragging = true }, hasK9Access = true, canShowK9UI = false })
    fBypass.setState('isBiteHoldEngaged', false)
    fBypass.setState('isDragEngaged', false)
    fBypass.findK9Item('k9_bite_hold').onSelect()
    fBypass.findK9Item('k9_drag').onSelect()
    t.equals(fBypass.denyCallCount(), 0)
    t.equals(#fBypass.calls.RequestBiteHold, 1)
    t.equals(#fBypass.calls.RequestDrag, 1)
end)

-- ----------------------------------------------------------------------
-- k9_track_certified (owner-directed decluttering pass, 2026-08-26) -- ONE
-- context-sensitive item now, so the OLD "clicking a DIFFERENT track type
-- while another is active must not cancel it" disambiguation this section
-- used to pin (GetActiveTrackType()-based) no longer applies -- there is
-- only one item, so ANY active tracking session (of whatever type the
-- SERVER resolved) makes it a Stop; otherwise it starts the ONE merged
-- action. This ALSO means this file never needs to know or care which
-- specific type is active -- IsTracking() alone is enough, exactly per
-- this pass's own "the server resolves which types apply, the client must
-- not decide this" requirement.
-- ----------------------------------------------------------------------

t.test('k9_track_certified: any active tracking session (regardless of type) makes this item a Stop, UNGATED', function()
    local f = newRadialFixture({ features = { ScentTracking = true }, canShowK9UI = false })
    f.setState('isTracking', true)
    f.findK9Item('k9_track_certified').onSelect()
    t.equals(#f.calls.StopTracking, 1)
    t.equals(f.denyCallCount(), 0, 'stopping an active trail must never be gated')
    t.isNil(f.calls.StartCertifiedTrack, 'must never also start a new search on the same click')
end)

-- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission audit
-- finding, this pass) -- server/tracking.lua's findTrackableSource/
-- findNearestTrackableSource both gate on HasK9Access(source) alone;
-- client/tracking.lua's own StartTrack() already made this exact fix on
-- itself (see that file's "ANY-PED SWEEP FIX" comment).
t.test('k9_track_certified: nothing active -- starting the merged search is GATED on HasK9Access() alone (widened)', function()
    local f = newRadialFixture({ features = { ScentTracking = true }, hasK9Access = false, canShowK9UI = false })
    f.setState('isTracking', false)
    f.findK9Item('k9_track_certified').onSelect()
    t.equals(f.denyCallCount(), 1)
    t.equals(f.lastDenyReason(), 'combat.no_access')
    t.isNil(f.calls.StartCertifiedTrack)

    -- THE WIDENING: a High Command/autoAccessGrade-bypass holder (HasK9Access
    -- true, CanShowK9UI false) must now be offered the search. Unlike Bite &
    -- Hold/Takedown/Drag/SAR Call/Vehicle above, there is NO residual gap
    -- here -- client/tracking.lua's own StartTrack() (called via
    -- StartCertifiedTrack()) already gates on HasK9Access() alone too (see
    -- that file's own header, confirmed by reading it directly), so this
    -- item genuinely unlocks the ability end-to-end for a bypass holder.
    local fBypass = newRadialFixture({ features = { ScentTracking = true }, hasK9Access = true, canShowK9UI = false })
    fBypass.setState('isTracking', false)
    fBypass.findK9Item('k9_track_certified').onSelect()
    t.equals(fBypass.denyCallCount(), 0)
    t.equals(#fBypass.calls.StartCertifiedTrack, 1)
end)

t.test('k9_track_certified: nothing active, access granted -- calls StartCertifiedTrack (the ONE merged action, never a specific Start*Track)', function()
    local f = newRadialFixture({ features = { ScentTracking = true } })
    f.setState('isTracking', false)
    f.findK9Item('k9_track_certified').onSelect()
    t.equals(#f.calls.StartCertifiedTrack, 1)
    t.isNil(f.calls.StartScentTrack, 'the collapsed item must never call the old per-type globals directly')
    t.isNil(f.calls.StartBloodTrack)
    t.isNil(f.calls.StartGunpowderTrack)
end)

-- ----------------------------------------------------------------------
-- OX_LIB RESTART LIFECYCLE -- dependency-verification finding: ox_lib
-- keeps `menus`/`menuItems` as plain file-local Lua tables in its own
-- client chunk (verified directly against overextended/ox_lib
-- resource/interface/client/radial.lua's own source this pass), so an
-- independent `restart ox_lib` reconstructs both empty with nothing
-- prompting a re-add -- silently wiping this resource's ENTIRE radial
-- menu with no error. client/radial.lua's RegisterK9RadialMenu() +
-- `AddEventHandler('onResourceStart', ...)` dispatcher (see that
-- function's own doc comment) fixes this; the cases below prove it,
-- mirroring tests/inventory_spec.lua's own `fireResourceStart`/
-- `wipeHookRegistrations` pair for the identical bug class against
-- ox_inventory instead. See this file's header ("OX_LIB RESTART
-- LIFECYCLE COVERAGE" / "LIVE-STATE MODELING") for the fixture mechanics
-- these tests rely on.
-- ----------------------------------------------------------------------

t.test('client/radial.lua registers exactly one onResourceStart handler', function()
    local f = newRadialFixture()
    t.equals(f.eventHandlerCount('onResourceStart'), 1)
end)

t.test('An unrelated resource starting neither registers nor re-registers anything', function()
    local f = newRadialFixture()
    t.isNotNil(f.findMenu('k9unit'))

    f.wipeOxLibRadialState()
    local ok = pcall(f.fireResourceStart, 'some_other_resource')
    t.isTrue(ok, "an unrelated resource's own start must never touch this file's registration at all")
    t.isNil(f.findMenu('k9unit'), 'confirms the wipe really took effect and the unrelated start did not silently re-populate it')
end)

t.test('Re-registering (via a simulated ox_lib restart) rebuilds fresh onSelect closures that still function correctly -- not stale/broken references into a torn-down state', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true } })

    f.wipeOxLibRadialState()
    f.fireResourceStart('ox_lib')

    f.findK9Item('k9_takedown').onSelect()
    t.equals(#f.calls.RequestTakedown, 1, 'a freshly re-registered item\'s onSelect must still genuinely call through once access is granted')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- RadialMenu and
-- AdvancedBarkRadial. See client/radial.lua's own "K9 UNIT RADIAL --
-- PER-PERSON BLOCK" header for the full design: both are checked at
-- REGISTRATION time (unlike every other feature this pass touches, which
-- check at the point an ability acts) because both features ARE this
-- file's own registration structure. This relies on the SAME
-- REPLACE-in-place ox_lib semantics the "no wipe in between" test above
-- already verifies -- re-registering after a block change is safe, not a
-- new risk.
-- ----------------------------------------------------------------------

t.test('RadialMenu blocked for this specific client: the opener STAYS present (REPLACED, not removed -- see production code\'s own "DUPLICATE-VS-REPLACE" note) but no longer navigates anywhere, and denies via DenyK9FeatureBlocked (a distinct, honest reason from DenyK9UIAccess) instead', function()
    local f = newRadialFixture({ features = { RadialMenu = true } })
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'sanity: unblocked, the opener navigates into k9unit')

    f.setBlocked('RadialMenu', true)
    f.fireFeatureBlocksApplied()

    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'the opener stays visible rather than silently vanishing (no verified ox_lib removal call exists for this codebase to rely on)')
    t.isNil(opener.menu, 'it must no longer navigate into k9unit -- there is nothing useful behind it while blocked')
    t.isNotNil(opener.onSelect)

    opener.onSelect()
    t.equals(f.denyK9FeatureBlockedCallCount(), 1, 'must deny via the distinct, honest DenyK9FeatureBlocked reason')
    t.equals(f.denyCallCount(), 0, 'never the generic "not certified" DenyK9UIAccess -- this is a block, not an access denial')
end)

t.test('RadialMenu block is LIVE: registered at load, blocked afterward via the featureBlocksApplied event, unblocked again -- the opener re-links to k9unit without a resource restart', function()
    local f = newRadialFixture({ features = { RadialMenu = true } })

    f.setBlocked('RadialMenu', true)
    f.fireFeatureBlocksApplied()
    t.isNil(f.findRootItem('k9unit_open').menu)

    f.setBlocked('RadialMenu', false)
    f.fireFeatureBlocksApplied()
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'unblocking must restore real navigation on the very next rebuild, no restart required')
    t.isNotNil(f.findMenu('k9unit'), 'and the submenu itself must be registered again too')
end)

t.test('RadialMenu block never touches OTHER abilities\' own resource-global functions -- K9Sit() itself keeps working when called directly (a block only removes ONE entry point\'s usefulness, never an ability)', function()
    local f = newRadialFixture({ features = { RadialMenu = true } })

    f.setBlocked('RadialMenu', true)
    f.fireFeatureBlocksApplied()
    t.isNil(f.findRootItem('k9unit_open').menu, 'sanity: the radial entry point no longer navigates anywhere')

    -- The resource-global K9Sit() itself (the SAME function every other
    -- surface -- keybind, command, tablet trigger, export -- would call)
    -- is completely untouched by this file's own registration logic --
    -- proving a RadialMenu block only ever removes the ONE entry point
    -- this file owns, never the ability.
    f.env.K9Sit()
    t.equals(#f.calls.K9Sit, 1, 'the underlying ability keeps working via any OTHER surface regardless of a RadialMenu block')
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- RadialMenu registers exactly as before this pass', function()
    local f = newRadialFixture({ features = { RadialMenu = true }, featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'an unknown block state must never disable the whole radial surface -- it must fail OPEN')
end)

t.test('AdvancedBarkRadial blocked for this specific client: Bark degrades to the SAME single, flat, generic item this file ships when the GLOBAL flag is false -- basic barking is unaffected', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })
    t.isNotNil(f.findMenu('k9unit_bark'), 'sanity: unblocked, the variant submenu IS registered')
    t.equals(f.findK9Item('k9_bark').menu, 'k9unit_bark')

    f.setBlocked('AdvancedBarkRadial', true)
    f.fireFeatureBlocksApplied()

    local bark = f.findK9Item('k9_bark')
    t.isNotNil(bark, 'Bark itself must still be offered -- only the ADVANCED variant submenu is withheld')
    t.isNil(bark.menu, 'must be a terminal action again, not a navigation link into the (now unreachable) variant submenu')
    t.isNotNil(bark.onSelect)

    bark.onSelect()
    t.equals(f.triggerServerEventCalls[#f.triggerServerEventCalls].args[1], 'bark', 'a blocked AdvancedBarkRadial must still send the plain generic bark type -- BasicBarkSounds has its own, separate, server-enforced block key this pass does not touch')
end)

t.test('AdvancedBarkRadial block is LIVE and reversible via the featureBlocksApplied event, same as RadialMenu', function()
    local f = newRadialFixture({ features = { AdvancedBarkRadial = true } })

    f.setBlocked('AdvancedBarkRadial', true)
    f.fireFeatureBlocksApplied()
    -- NOTE: k9unit_bark itself may still exist as an ORPHAN in ox_lib's own
    -- registry while blocked -- same disclosed, accepted nuance as the
    -- GLOBAL RadialMenu=false path above ("orphaned, but genuinely still
    -- registered"); this file only ever ADDS/REPLACES a menu id, it never
    -- calls an unverified removal API (see production code's own comment).
    -- What actually matters -- and what this test checks -- is that
    -- NOTHING REACHABLE from 'k9unit' still links to it.
    t.isNil(f.findK9Item('k9_bark').menu, 'k9_bark must not navigate into the (possibly orphaned) k9unit_bark while blocked')

    f.setBlocked('AdvancedBarkRadial', false)
    f.fireFeatureBlocksApplied()
    t.isNotNil(f.findMenu('k9unit_bark'), 'unblocking must restore the variant submenu on the next rebuild')
    t.equals(f.findK9Item('k9_bark').menu, 'k9unit_bark')
end)

t.test('a block on a DIFFERENT feature name never affects RadialMenu or AdvancedBarkRadial', function()
    local f = newRadialFixture({ features = { RadialMenu = true, AdvancedBarkRadial = true } })
    f.setBlocked('NightVision', true)
    f.fireFeatureBlocksApplied()
    t.isNotNil(f.findRootItem('k9unit_open'))
    t.isNotNil(f.findMenu('k9unit_bark'))
end)

t.test('the john-k9:client:featureBlocksApplied listener is registered exactly once per fixture, alongside the existing onResourceStart dispatcher', function()
    local f = newRadialFixture()
    t.equals(f.featureBlocksAppliedHandlerCount(), 1)
end)

-- THE MISSING LISTENER. client/movement.lua has fired
-- 'john-k9:client:leashStateChanged' on every leash state flip for some
-- time, and BOTH that file's comment and this file's Attach/Detach Leash
-- item claimed the pairing existed -- but no AddEventHandler for it was ever
-- written here. The menu was in fact only rebuilt by 'onResourceStart' and
-- 'john-k9:client:featureBlocksApplied', so a player who got leashed saw
-- no Detach item until something unrelated happened to rebuild the menu, and
-- had to find the walk-away safety valve by accident instead.
--
-- Two comments describing a mechanism that did not exist is exactly why both
-- assertions below are written against observable behaviour -- a registered
-- handler, and a menu that actually gets rebuilt -- rather than against
-- either comment.
t.test('LEASH LISTENER: this file registers a handler for client/movement.lua\'s leashStateChanged re-broadcast -- the pairing both files\' comments claimed, now real', function()
    local f = newRadialFixture()
    t.isTrue(f.leashStateChangedHandlerCount() >= 1, 'client/movement.lua fires this event on every leash flip purely so this file rebuilds the menu; with no handler here that event goes nowhere and the Detach item never refreshes')
end)

t.test('LEASH LISTENER: firing leashStateChanged genuinely re-runs RegisterK9RadialMenu -- a leash acquired after load makes Detach reachable with no resource restart', function()
    local f = newRadialFixture()

    -- Wipe ox_lib's own registries, exactly as its restart would, so the
    -- only way anything can be registered again is a real rebuild.
    f.wipeOxLibRadialState()
    t.equals(#f.registerRadialOrder(), 0, 'precondition: nothing registered after the wipe')

    f.fireLeashStateChanged()

    t.isTrue(#f.registerRadialOrder() > 0, 'the event must actually re-run RegisterK9RadialMenu(), not merely be listened for -- a handler that registers nothing is the same bug with extra steps')
end)

-- ============================================================================
-- TOP-LEVEL ICON ACCESS GATE (this pass -- coder-security/coder-backend
-- finding response: every player, including civilians, used to see the
-- 'k9unit_open' opener unconditionally). See client/radial.lua's own
-- "TOP-LEVEL ICON ACCESS GATE" header (right above RegisterK9RadialMenu())
-- for the full three-part design this section proves: (1) never gates a
-- way out, (2) fails OPEN on an unknown answer, (3) stays live across a
-- mid-session change via the periodic refresh thread.
--
-- Every test below EXPLICITLY advances past the 8s startup grace window
-- first (`f.advanceGameTimer(8001)`) unless it is specifically testing
-- that window itself -- otherwise the fail-open grace period would mask
-- every one of these from ever exercising the real department/access/
-- engagement logic at all, exactly the "flap for the wrong reason"
-- failure class this suite's own header warns about elsewhere.
-- ============================================================================

t.test('STARTUP GRACE WINDOW: a brand-new client (no department, no access, GetGameTimer still inside the 8s window) sees the icon fully reachable -- FAIL OPEN, not closed, on an unknown answer', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
    -- fireResourceStart already ran once inside newRadialFixture() at
    -- gameTimerNow == 0 -- still inside the window.
    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'the root opener must always be registered, blocked or not, reachable or not')
    t.equals(opener.menu, 'k9unit', 'inside the grace window the opener must navigate normally, not degrade to an inert stub')
    t.isNotNil(f.findMenu('k9unit'), 'the submenu itself must also be registered while the icon is reachable')
end)

t.test('AFTER THE GRACE WINDOW, an ox_lib too old to remove items: no department, no K9 access, no ongoing engagement -- the opener becomes an INERT stub (stays visible, denies via DenyK9UIAccess, does not navigate)', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()

    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'the icon itself must STAY VISIBLE (same disclosed compromise as the featureblocks-blocked case) -- only its behavior changes')
    t.isNil(opener.menu, 'must no longer navigate into the submenu -- the submenu itself may still exist in ox_lib\'s own registry (see client/radial.lua\'s own comment on why that registration is NOT re-gated on this same answer), but with the opener\'s own `menu` field cleared, nothing anywhere still points to it')

    opener.onSelect()
    t.isTrue(f.denyCallCount() >= 1, 'selecting the inert icon must deny via DenyK9UIAccess -- the SAME message every other gated action in this file already shows, not a new parallel string')
end)

t.test('AFTER THE GRACE WINDOW, current ox_lib: a civilian with no K9 department, access or engagement has NO K9 Unit button at all -- and gets it back on joining a K9 department', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false, withRemoveRadialItem = true })
    f.env.QBX.PlayerData.job.name = 'unemployed'
    t.isNotNil(f.findRootItem('k9unit_open'), 'inside the startup window the button is there (fail open)')
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()
    t.isNil(f.findRootItem('k9unit_open'), 'no dead button cluttering a civilian\'s radial')
    f.env.QBX.PlayerData.job.name = 'police'
    f.advanceGameTimer(20000)
    f.stepIconRefreshThread()
    local opener = f.findRootItem('k9unit_open')
    t.isNotNil(opener, 'joining a K9 department brings it back without a reconnect')
    t.equals(opener.menu, 'k9unit')
end)

t.test('AFTER THE GRACE WINDOW: department membership (QBX.PlayerData.job.name in Config.Departments) alone keeps the icon fully reachable, even with zero K9 access', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
    -- 'police' is a real Config.Departments key in the shipped config.lua.
    f.env.QBX.PlayerData.job.name = 'police'
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()

    local opener = f.findRootItem('k9unit_open')
    t.equals(opener.menu, 'k9unit', 'a department member sees the real, working icon even before ever being certified -- certification-specific refusals happen INSIDE the submenu, not by hiding the door to it')
    t.isNotNil(f.findMenu('k9unit'))
end)

t.test('AFTER THE GRACE WINDOW: a job NOT in Config.Departments earns nothing by itself -- the icon degrades to inert without also holding K9 access', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
    f.env.QBX.PlayerData.job.name = 'unemployed' -- not a real Config.Departments key
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()

    t.isNil(f.findRootItem('k9unit_open').menu)
end)

t.test('AFTER THE GRACE WINDOW: HasK9Access() alone (a permission-grant holder outside any listed department) keeps the icon fully reachable', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = true })
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()

    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit')
end)

-- NEVER GATE A WAY OUT -- the load-bearing half of this whole gate. Each of
-- these proves an in-progress engagement keeps the icon (and therefore the
-- ONLY reachable Detach Leash / Break Partnership / etc. surface) fully
-- available even with zero department and zero K9 access -- exactly the
-- "decertified mid-leash" stranding scenario this file's own header names.
for _, case in ipairs({
    { field = 'isLeashed', label = 'IsLeashed() (Detach Leash -- the ONE surface with no other exit at all)' },
    { field = 'isPartnered', label = 'IsPartnered() (Break Partnership -- the OTHER surface with no other exit besides the tablet)' },
    { field = 'isBiteHoldEngaged', label = 'IsBiteHoldEngaged() (also has its own keybind exit -- defense in depth, not load-bearing)' },
    { field = 'isDragEngaged', label = 'IsDragEngaged()' },
    { field = 'isDragTargetEngaged', label = 'IsDragTargetEngaged() (the DRAGGED party, not the dragger)' },
    { field = 'isRestingInKennel', label = 'IsRestingInKennel() (also has its own keybind exit)' },
    { field = 'isCarryingKennel', label = 'IsCarryingKennel()' },
    { field = 'isFetchCarryEngaged', label = 'IsFetchCarryEngaged() (also has its own command exit)' },
}) do
    t.test(('NEVER GATE A WAY OUT: %s alone keeps the icon fully reachable with zero department and zero K9 access'):format(case.label), function()
        local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
        f.advanceGameTimer(8001)
        f.setState(case.field, true)
        f.stepIconRefreshThread()

        t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', ('%s must keep the icon reachable'):format(case.field))
        t.isNotNil(f.findMenu('k9unit'), 'the submenu itself must be registered too, not just the opener')
    end)
end

t.test('FEATUREBLOCKS BLOCK TAKES PRIORITY over the access gate: a RadialMenu block still denies via DenyK9FeatureBlocked, never DenyK9UIAccess, regardless of department/access/engagement state', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false, blockedFeatures = { RadialMenu = true } })
    f.env.QBX.PlayerData.job.name = 'police' -- would otherwise make the icon fully reachable
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()

    local opener = f.findRootItem('k9unit_open')
    t.isNil(opener.menu)
    opener.onSelect()
    t.isTrue(f.denyK9FeatureBlockedCallCount() >= 1, 'a featureblocks block keeps its OWN distinct message even when this client would otherwise pass the access gate')
    t.equals(f.denyCallCount(), 0, 'must not ALSO fire DenyK9UIAccess -- exactly one denial message per click, the correct one')
end)

t.test('PERIODIC ICON REFRESH: does not exist at all when Config.Features.RadialMenu is globally off -- no icon exists for anyone to reveal', function()
    local f = newRadialFixture({ features = { RadialMenu = false } })
    -- No thread was ever created for CreateThread to capture -- stepping
    -- must be a safe no-op, not an error, and nothing must appear.
    local ok = pcall(f.stepIconRefreshThread)
    t.isTrue(ok, 'stepping with no thread registered must not throw')
    t.isNil(f.findRootItem('k9unit_open'))
end)

t.test('PERIODIC ICON REFRESH: a player who becomes a department member MID-SESSION (no reconnect, no resource restart) sees the icon become reachable within one refresh pass', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()
    t.isNil(f.findRootItem('k9unit_open').menu, 'precondition: inert before the job change')

    -- The job change itself: QBX.PlayerData is qbx_core's own live-updated
    -- cache -- this file has no event of its own for it, which is exactly
    -- why the periodic thread (not an event listener) is what closes this
    -- gap.
    f.env.QBX.PlayerData.job.name = 'police'
    f.stepIconRefreshThread()

    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'the icon must become reachable within one refresh pass, with no resource restart and no reconnect')
end)

t.test('PERIODIC ICON REFRESH: a handler who is DECERTIFIED mid-session (HasK9Access flips false, no department either) loses the icon within one refresh pass -- proves the gate is genuinely LIVE in both directions', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = true })
    f.advanceGameTimer(8001)
    f.stepIconRefreshThread()
    t.equals(f.findRootItem('k9unit_open').menu, 'k9unit', 'precondition: reachable while access is held')

    f.setHasK9Access(false)
    f.stepIconRefreshThread()

    t.isNil(f.findRootItem('k9unit_open').menu, 'access revoked mid-session, with no ongoing engagement to protect, must degrade the icon to inert within one refresh pass')
end)


-- ========================================================================
-- NON-LETHAL TAKEDOWN IS NOW A TOGGLE (completeness QA finding, this pass;
-- the keybind half landed first in client/keybinds.lua).
--
-- This item's own header used to argue, correctly at the time, that
-- takedown was a one-shot because client/combat.lua "exposes only
-- RequestTakedown(), with no matching release/cancel counterpart and no
-- IsTakedownEngaged()-style query". Both functions landed later and this
-- item was never updated -- so ReleaseTakedown() was reachable from
-- nothing at all.
--
-- It matters because RequestTakedown() picks the NEAREST eligible ped,
-- which client/combat.lua's own comment admits is "not necessarily the
-- intended one". Take down the wrong person and they stayed ragdolled and
-- damage-immune for the full configured duration, with no route out at
-- all for a solo K9.
-- ========================================================================
t.test('k9_takedown: NOT engaged -> requests a takedown, exactly as before', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true } })
    f.findK9Item('k9_takedown').onSelect()
    t.equals(#(f.calls.RequestTakedown or {}), 1)
    t.equals(#(f.calls.ReleaseTakedown or {}), 0)
end)

t.test('k9_takedown: ENGAGED -> releases instead, and never falls through to fire a second request', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true } })
    f.setState('isTakedownEngaged', true)
    f.findK9Item('k9_takedown').onSelect()
    t.equals(#(f.calls.ReleaseTakedown or {}), 1, 'the wrongly-taken-down target must be releasable from the radial too, not only the keybind')
    t.equals(#(f.calls.RequestTakedown or {}), 0)
end)

t.test('k9_takedown: the Release branch is UNGATED -- it fires with no K9 access at all, because that is the STOP half', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true }, hasK9Access = false, canShowK9UI = false })
    f.setState('isTakedownEngaged', true)
    f.findK9Item('k9_takedown').onSelect()
    t.equals(#(f.calls.ReleaseTakedown or {}), 1, 'a K9 decertified mid-takedown must still be able to let go -- gate the start, never the stop')
    t.equals(f.denyCallCount(), 0, 'and must never be told it cannot use K9 features while doing so')
end)

t.test('CONTROL: the Start branch still carries its access gate -- wiring the release must not have widened the start', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true }, hasK9Access = false, canShowK9UI = false })
    f.setState('isTakedownEngaged', false)
    f.findK9Item('k9_takedown').onSelect()
    t.equals(#(f.calls.RequestTakedown or {}), 0)
    t.isTrue(f.denyCallCount() > 0)
end)

t.test('CONTROL: tolerates IsTakedownEngaged/ReleaseTakedown being entirely absent (soft dependency), exactly as the bite-hold and drag releases already are', function()
    local f = newRadialFixture({ features = { NonLethalTakedown = true }, omit = { 'IsTakedownEngaged', 'ReleaseTakedown' } })
    local ok = pcall(function() f.findK9Item('k9_takedown').onSelect() end)
    t.isTrue(ok)
end)

-- ----------------------------------------------------------------------
-- k9_scent_vision / k9_camera_feed -- DISCOVERABILITY PASS.
--
-- Both abilities shipped with a command and a keybind and no radial entry
-- at all, so the only players who ever found them were the ones who read
-- the keybind list. Both now sit in the perception family.
--
-- Unlike ThermalVision/NightVision, both of these default to TRUE in
-- config.lua, so they are present in this file's baseline rather than
-- absent from it -- which is why the presence tests below use the baseline
-- fixture and the absence tests pin the flag off explicitly.
-- ----------------------------------------------------------------------

t.test('k9_scent_vision: present at the shipped default (Config.Features.ScentVision defaults true), with the real locale-backed label', function()
    local f = newRadialFixture()
    local item = f.findK9Item('k9_scent_vision')
    t.isNotNil(item, 'an ability with a command and a keybind but no wheel entry is one only keybind-list readers ever find')
    t.equals(item.label, locale('radial.scent_vision_label'))
end)

t.test('k9_scent_vision: absent when Config.Features.ScentVision is off', function()
    local f = newRadialFixture({ features = { ScentVision = false } })
    t.isNil(f.findK9Item('k9_scent_vision'))
end)

t.test('k9_scent_vision: onSelect calls ToggleScentVision() exactly once, and gates on nothing itself', function()
    local f = newRadialFixture({ canShowK9UI = false, hasK9Access = false })
    f.findK9Item('k9_scent_vision').onSelect()
    t.equals(#f.calls.ToggleScentVision, 1)
    t.equals(f.canShowK9UICallCount(), 0, 'the item must not pre-gate -- ToggleScentVision() does the real CanShowK9UI() check on its turning-ON branch, and turning OFF is never gated')
end)

t.test('FIXED-SHAPE GUARD: k9_scent_vision does not throw when ToggleScentVision is entirely absent', function()
    local f = newRadialFixture({ omit = { 'ToggleScentVision' } })
    assertGuardDoesNotThrow(f.findK9Item('k9_scent_vision'))
end)

t.test('NO PARTNER CAMERA BUTTON: the partner camera is opened from the tablet only (owner\'s choice) -- not in the dog\'s menu or the handler\'s', function()
    t.isNil(newRadialFixture().findK9Item('k9_camera_feed'))
    t.isNil(newRadialFixture({ playingDog = false }).findK9Item('k9_camera_feed'))
end)

os.exit(t.summary())
