--[[
    tests/clientsearch_spec.lua

    Client-side spec for client/search.lua (Search Vehicle / Search Person
    and the bystander contraband-alert broadcast receiver). Follows
    main_spec.lua's worked example: a real, unmodified client/search.lua
    loaded into a fresh sandbox per test, driven only through its real
    ox_target option definitions (captured via a stubbed
    exports.ox_target:addGlobalVehicle/addGlobalPlayer) and its one
    RegisterNetEvent handler -- never a reimplementation of PerformSearch's
    logic, which is a `local` this spec has no other way to reach (exactly
    the ox_target-onSelect-closure pattern DEVELOPER_REFERENCE.md's own sandbox
    doc describes as the correct way in).

    LIFECYCLE NOTE: client/search.lua's own "LIFECYCLE FIX" comment means
    its two ox_target options are NOT registered merely by loading the
    file -- they are only registered inside the captured
    AddEventHandler('onResourceStart', ...) handler. newSearchFixture()
    below fires that handler once with GetCurrentResourceName()'s own
    stubbed value immediately after loading, mirroring a real resource
    start, so every test below can go straight to `f.vehicleOption()` /
    `f.personOption()` without repeating that plumbing itself.

    THIS PASS'S PRIORITY, per this file's own task brief:
    1. The in-flight guard (`searchInProgress`) -- section B, driven via
       REENTRANCY (this sandbox's lib.progressBar is otherwise synchronous,
       so a reentrant onSelect call fired from INSIDE the pending
       progressBar callback models "a second click lands while the first
       search is still running").
    2. Every rejection `reason` the server can return has a client-side
       label, and none of them silently show nothing -- section C
       enumerates the FULL real reason set found by reading
       server/search.lua directly (not just this file's own header
       comment, which used to be stale by one value, 'access_revoked' --
       since fixed, this file's header now documents it too), including
       the two "no reason at all" degenerate cases (a nil round-trip
       result, and a lib.callback.await that throws outright, modeling
       ox_lib's real timeout/rejection behavior). UX PASS (this spec
       revision): five of those reasons now each get their OWN,
       distinct locale key (NAMED_DENIED_REASONS below) instead of
       collapsing into one generic message -- only a truly unrecognized
       reason still falls through to the generic catch-all.
    3. netId capture BEFORE the sniff animation, so a target whose entity
       handle gets reassigned mid-animation cannot be misattributed --
       section D, proven by mutating the entity->netId mapping FROM INSIDE
       the (reentrant) progressBar stub, i.e. strictly between the capture
       point and the eventual server call.

    `source ~= 65535` origin guard: section F, on the ONE real
    RegisterNetEvent handler this file registers
    ('john-k9:client:playContrabandAlert'). Per this task's own
    instruction, wherever this guard is pinned below carries its own
    comment that a green test here proves what THE CODE does and does NOT
    settle whether the engine itself can be made to fail open -- see that
    section for the full, repeated caveat.

    STUBBING EFFORT, reported honestly: proportionate. The one native-ish
    surface unique to this file versus main_spec.lua/clientradial_spec.lua
    is `exports.ox_target:addGlobalVehicle/addGlobalPlayer` (colon-call
    syntax -- `self` is the stubbed ox_target table itself, discarded).
    Everything else is the same small recording/controllable stand-in
    shape already established (lib.progressBar/lib.callback.await/
    lib.notify, DoesEntityExist, NetworkGetNetworkIdFromEntity,
    NetworkGetPlayerIndexFromPed, PlayerId, AddEventHandler,
    RegisterNetEvent, GetCurrentResourceName, PlaySoundOnNetworkEntity as
    a call-recording stand-in for the already-covered client/main.lua
    function of that name). TriggerServerEvent is DELIBERATELY never
    stubbed at all (see section E) -- this file's own header states it
    triggers no server events beyond the one callback, and an unstubbed
    global call would fail loudly rather than silently, which is the
    stronger check.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- same deterministic, non-native formula
-- clientmovement_spec.lua already uses for the identical reason: this
-- pass's own K9_SEARCH_SCENARIO_BY_MODEL_HASH table (client/search.lua) is
-- built from real GetHashKey calls at FILE-LOAD time, so this spec needs
-- SOME stand-in for the file to load at all, even though most tests below
-- never assert on that table's contents directly.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Sentinel returned by `queueCallbackThrow()`/`queueProgressBarThrow()` --
--- see their own comments below for why a thrown lib.callback.await matters
--- here (ox_lib's real behavior on a timeout/rejection is to throw, not
--- return nil -- confirmed elsewhere in this codebase's own concurrent
--- FAIL-CLOSED GUARD comments in client/wellbeing.lua, added the same
--- session this spec was written).
local THROW = setmetatable({}, { __tostring = function() return 'THROW' end })

--- @param opts { canShowK9UI: boolean?, hasK9Access: boolean?, searchZones: boolean? }?
local function newSearchFixture(opts)
    opts = opts or {}

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local canShowK9UICallCount = 0
    local denyCalls = 0
    local denyReasons = {}
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    -- GATE WIDENED TO HasK9Access() ALONE (permission audit finding) --
    -- client/search.lua's PerformSearch()/canInteract predicates now check
    -- HasK9Access() instead of CanShowK9UI(). Independently settable from
    -- canShowK9UI (defaults to the SAME value when opts.hasK9Access is
    -- omitted, so every existing call site in this spec keeps working
    -- unchanged) so the interesting divergent case -- HasK9Access()-true,
    -- CanShowK9UI()-false, i.e. a High Command/autoAccessGrade-bypass
    -- holder with no certification -- can be modeled directly.
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = canShowK9UI end
    local hasK9AccessCallCount = 0
    local function HasK9Access() hasK9AccessCallCount = hasK9AccessCallCount + 1; return hasK9Access end
    local function DenyK9UIAccess(reason)
        denyCalls = denyCalls + 1
        denyReasons[#denyReasons + 1] = reason
    end

    local existingEntities = {} -- entity -> boolean
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    local netIdByEntity = {} -- entity -> netId, mutable mid-test (section D)
    local function NetworkGetNetworkIdFromEntity(entity) return netIdByEntity[entity] end

    -- lib.progressBar -- a plain FIFO queue of canned `completed` booleans,
    -- PLUS an optional reentrant hook fired from INSIDE the stub (before it
    -- returns) so a test can simulate "something else happens while the
    -- sniff animation is still playing" (sections B and D both need this).
    local progressBarCalls = {}
    local progressBarQueue = {}
    local progressBarReentrant = nil
    local function progressBar(def)
        progressBarCalls[#progressBarCalls + 1] = def
        if progressBarReentrant then
            local fn = progressBarReentrant
            progressBarReentrant = nil
            fn()
        end
        local next = table.remove(progressBarQueue, 1)
        if next == nil then return true end -- default: completed normally
        return next
    end

    -- lib.callback.await -- a plain FIFO queue of canned responses. A
    -- queued THROW sentinel makes this stub error() instead of returning,
    -- modeling ox_lib's real timeout/rejection behavior (see section C's
    -- "an outright throw" test).
    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local next = table.remove(callbackResponses, 1)
        if next == THROW then
            error('simulated lib.callback.await failure (timeout/rejection)')
        end
        return next
    end

    local notifyCalls = {}
    local lib = {
        progressBar = progressBar,
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    -- client/search.lua now routes its "Search Vehicle"/"Search Person"
    -- options through K9Compat.Get('target') (shared/compat/target.lua)
    -- rather than calling `exports.ox_target` directly -- see that file's
    -- own header. This fixture loads the REAL shared/compat/core.lua +
    -- shared/compat/target.lua (never a hand-written fake translation
    -- layer, which would just assert against itself) so K9Compat.Get
    -- ('target') resolves to the REAL ox_target adapter, which is a
    -- byte-for-byte pass-through of the options table -- captured below via
    -- the exact same colon-call `exports.ox_target:addGlobalVehicle/
    -- addGlobalPlayer` stub as before. ox_target is the ONLY candidate this
    -- fixture makes `GetResourceState` report as 'started', so detection
    -- deterministically resolves to it. Every REQUIRED_EXPORTS name
    -- (shared/compat/target.lua's OxTargetFactory) must exist as a
    -- callable function or the whole adapter is rejected as unverified and
    -- silently falls back to the no-op stub -- the exports this file never
    -- actually exercises are still stubbed as harmless no-ops so
    -- verification passes.
    local addGlobalVehicleCalls, addGlobalPlayerCalls = {}, {}
    local oxTargetStub = {}
    function oxTargetStub.addGlobalVehicle(_, defs) addGlobalVehicleCalls[#addGlobalVehicleCalls + 1] = defs end
    function oxTargetStub.addGlobalPlayer(_, defs) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = defs end
    function oxTargetStub.addGlobalObject() end
    function oxTargetStub.addModel() end
    function oxTargetStub.addSphereZone() end
    function oxTargetStub.removeGlobalPlayer() end
    function oxTargetStub.removeGlobalVehicle() end
    function oxTargetStub.removeGlobalObject() end
    function oxTargetStub.removeModel() end
    function oxTargetStub.removeZone() end
    function oxTargetStub.addLocalEntity() end
    function oxTargetStub.removeLocalEntity() end

    local function IsDuplicityVersion() return false end -- client realm, for shared/compat/core.lua
    local function GetResourceState(resourceName)
        return resourceName == 'ox_target' and 'started' or 'missing'
    end

    -- AddEventHandler -- captures EVERY event name (not just
    -- 'onResourceStart'): shared/compat/core.lua also registers
    -- 'onClientResourceStart'/'onClientResourceStop' handlers at load time
    -- (client realm) that this fixture never fires, but must not reject.
    -- `resourceStartHandlers` (used by fireResourceStart below, matching
    -- this file's own header LIFECYCLE NOTE) stays scoped to
    -- 'onResourceStart' specifically, exactly as before.
    local resourceStartHandlers = {}
    local otherEventHandlers = {}
    local function AddEventHandler(eventName, handler)
        if eventName == 'onResourceStart' then
            resourceStartHandlers[#resourceStartHandlers + 1] = handler
        else
            otherEventHandlers[eventName] = otherEventHandlers[eventName] or {}
            otherEventHandlers[eventName][#otherEventHandlers[eventName] + 1] = handler
        end
    end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local function GetCurrentResourceName() return 'john-k9' end

    local playerIndexByPed = {}
    local function NetworkGetPlayerIndexFromPed(entity) return playerIndexByPed[entity] or -1 end
    local myPlayerId = 0
    local function PlayerId() return myPlayerId end

    local playSoundOnNetworkEntityCalls = {}
    local function PlaySoundOnNetworkEntity(netId, soundName)
        playSoundOnNetworkEntityCalls[#playSoundOnNetworkEntityCalls + 1] = { netId = netId, soundName = soundName }
    end

    -- SEARCH SCENARIO stand-ins (this pass) -- see client/search.lua's own
    -- "SEARCH SCENARIO" section. `myPedHandle` defaults to a fixed handle
    -- with NO entry in `entityModels`, so ResolveSearchScenario() falls
    -- through to K9_SEARCH_DEFAULT_SCENARIO by default -- exactly what
    -- most tests below want without having to configure a model per test.
    local myPedHandle = 1
    local entityModels = {}
    local function PlayerPedId() return myPedHandle end
    local function GetEntityModel(entity) return entityModels[entity] end

    local clearPedTasksImmediatelyCalls = {}
    local function ClearPedTasksImmediately(ped)
        clearPedTasksImmediatelyCalls[#clearPedTasksImmediatelyCalls + 1] = ped
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        HasK9Access = HasK9Access,
        DenyK9UIAccess = DenyK9UIAccess,
        DoesEntityExist = DoesEntityExist,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        lib = lib,
        exports = { ox_target = oxTargetStub },
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        PlayerId = PlayerId,
        PlaySoundOnNetworkEntity = PlaySoundOnNetworkEntity,
        IsDuplicityVersion = IsDuplicityVersion,
        GetResourceState = GetResourceState,
        GetHashKey = GetHashKey,
        PlayerPedId = PlayerPedId,
        GetEntityModel = GetEntityModel,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        -- TriggerServerEvent deliberately NOT stubbed -- see this file's
        -- own header on why an unstubbed call failing loudly is the
        -- stronger check for "this file sends no server events beyond the
        -- one callback."
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)
    -- Explicit, per this task's own instruction: never depend on
    -- config.lua's shipped default (currently true for every flag).
    env.Config.Features.SearchZones = opts.searchZones
    if opts.searchZones == nil then env.Config.Features.SearchZones = true end

    -- Real K9Compat, real ox_target adapter -- see the oxTargetStub comment
    -- above for why. Must load before client/search.lua, which reads the
    -- `K9Compat` global inside RegisterSearchOxTargetOptions() (fired below
    -- via the captured onResourceStart handler).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/target.lua', env)

    Sandbox.loadInto('../client/search.lua', env)

    -- Mirrors a real resource start -- see this file's own header
    -- LIFECYCLE NOTE.
    for _, fn in ipairs(resourceStartHandlers) do
        fn('john-k9')
    end

    local fixture
    fixture = {
        env = env,
        notifyCalls = notifyCalls,
        progressBarCalls = progressBarCalls,
        playSoundOnNetworkEntityCalls = playSoundOnNetworkEntityCalls,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        denyCallCount = function() return denyCalls end,
        lastDenyReason = function() return denyReasons[#denyReasons] end,

        setEntityExists = function(entity, v) existingEntities[entity] = v end,
        setNetIdForEntity = function(entity, netId) netIdByEntity[entity] = netId end,

        queueProgressBarResult = function(v) progressBarQueue[#progressBarQueue + 1] = v end,
        setProgressBarReentrant = function(fn) progressBarReentrant = fn end,

        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        queueCallbackThrow = function() callbackResponses[#callbackResponses + 1] = THROW end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,

        setPlayerIndexForPed = function(entity, idx) playerIndexByPed[entity] = idx end,
        setMyPlayerId = function(v) myPlayerId = v end,

        -- SEARCH SCENARIO / resource-stop cleanup stand-ins (this pass).
        setMyPedHandle = function(v) myPedHandle = v end,
        setEntityModel = function(entity, model) entityModels[entity] = model end,
        clearPedTasksImmediatelyCalls = clearPedTasksImmediatelyCalls,
        --- Fires every captured 'onResourceStop' handler (there is exactly
        --- one, registered by this pass's own RESOURCE-STOP CLEANUP block) --
        --- mirrors fireResourceStart below, using the SAME otherEventHandlers
        --- capture this fixture's own AddEventHandler already routes any
        --- non-'onResourceStart' event name into.
        fireResourceStop = function(resourceName)
            for _, fn in ipairs(otherEventHandlers['onResourceStop'] or {}) do fn(resourceName) end
        end,

        --- The single "Search Vehicle" ox_target option definition, as
        --- registered by the most recent onResourceStart trigger.
        vehicleOption = function()
            local defs = addGlobalVehicleCalls[#addGlobalVehicleCalls]
            return defs and defs[1]
        end,
        --- The single "Search Person" ox_target option definition.
        personOption = function()
            local defs = addGlobalPlayerCalls[#addGlobalPlayerCalls]
            return defs and defs[1]
        end,
        addGlobalVehicleCallCount = function() return #addGlobalVehicleCalls end,
        addGlobalPlayerCallCount = function() return #addGlobalPlayerCalls end,

        --- Re-fires onResourceStart -- used by the lifecycle re-registration test.
        fireResourceStart = function(resourceName)
            for _, fn in ipairs(resourceStartHandlers) do fn(resourceName) end
        end,

        triggerContrabandAlert = function(sourceValue, netId, alertTier)
            local handler = assert(netEventHandlers['john-k9:client:playContrabandAlert'],
                'client/search.lua did not register a john-k9:client:playContrabandAlert handler')
            env.source = sourceValue
            handler(netId, alertTier)
        end,
    }
    return fixture
end

-- ----------------------------------------------------------------------
-- Sanity: both ox_target options really got registered on resource start,
-- and the net event handler is really reachable.
-- ----------------------------------------------------------------------

t.test('resource start registers exactly one Search Vehicle and one Search Person ox_target option', function()
    local f = newSearchFixture()
    t.equals(f.addGlobalVehicleCallCount(), 1)
    t.equals(f.addGlobalPlayerCallCount(), 1)
    local vehicleOpt = f.vehicleOption()
    local personOpt = f.personOption()
    t.isNotNil(vehicleOpt)
    t.isNotNil(personOpt)
    t.equals(vehicleOpt.name, 'john-k9:searchVehicle')
    t.equals(personOpt.name, 'john-k9:searchPerson')
    t.equals(vehicleOpt.label, locale('search.vehicle_target_label'))
    t.equals(personOpt.label, locale('search.person_target_label'))
end)

t.test('LIFECYCLE FIX: onResourceStart firing again (e.g. a bare ox_target restart) re-registers both options', function()
    local f = newSearchFixture()
    f.fireResourceStart('ox_target')
    t.equals(f.addGlobalVehicleCallCount(), 2, 'must re-register on an ox_target restart, not just this resource\'s own start')
    t.equals(f.addGlobalPlayerCallCount(), 2)

    -- An unrelated resource starting must NOT trigger a re-registration.
    f.fireResourceStart('some_other_resource')
    t.equals(f.addGlobalVehicleCallCount(), 2)
end)

t.test('canInteract: both options respect Config.Features.SearchZones, and Search Person excludes the local player\'s own ped', function()
    local fOff = newSearchFixture({ searchZones = false })
    t.isFalse(fOff.vehicleOption().canInteract(500, 1.0, {}, 'x'))
    t.isFalse(fOff.personOption().canInteract(500, 1.0, {}, 'x'))

    local fOn = newSearchFixture({ searchZones = true })
    t.isTrue(fOn.vehicleOption().canInteract(500, 1.0, {}, 'x'))

    fOn.setPlayerIndexForPed(500, 3)
    fOn.setMyPlayerId(3)
    t.isFalse(fOn.personOption().canInteract(500, 1.0, {}, 'x'), 'a player must never be offered "Search Person" against their own ped')

    fOn.setPlayerIndexForPed(501, 7) -- a different player
    t.isTrue(fOn.personOption().canInteract(501, 1.0, {}, 'x'))
end)

t.test('ROLE ICON: both options use the settled K9-role icon (fa-dog), never the old bare magnifying-glass', function()
    local f = newSearchFixture()
    t.equals(f.vehicleOption().icon, 'fas fa-dog')
    t.equals(f.personOption().icon, 'fas fa-dog')
end)

t.test('canInteract: NEVER SHOW AN OPTION THAT WILL JUST REFUSE -- both options hide themselves while a search is already in flight, and un-hide the moment it completes', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    local sawVehicleDuringFlight, sawPersonDuringFlight
    f.setProgressBarReentrant(function()
        sawVehicleDuringFlight = f.vehicleOption().canInteract(500, 1.0, {}, 'x')
        sawPersonDuringFlight = f.personOption().canInteract(500, 1.0, {}, 'x')
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.isFalse(sawVehicleDuringFlight, 'Search Vehicle must be hidden while a search is in flight, not merely inert once selected')
    t.isFalse(sawPersonDuringFlight, 'the OTHER option (Search Person) must also be hidden while Search Vehicle is in flight')

    -- Once the in-flight search has completed, both options must be
    -- interactable again -- this is a display gate only, never a stuck flag.
    t.isTrue(f.vehicleOption().canInteract(500, 1.0, {}, 'x'))
    t.isTrue(f.personOption().canInteract(500, 1.0, {}, 'x'))
end)

-- ----------------------------------------------------------------------
-- SECTION A -- the defensive re-check + "nothing to search" guard, before
-- the in-flight/netId-capture sections that build on top of a successful
-- entry into PerformSearch.
-- ----------------------------------------------------------------------

t.test('onSelect: CanShowK9UI() false denies access and never starts the sniff animation at all', function()
    local f = newSearchFixture({ canShowK9UI = false })
    f.setEntityExists(500, true)
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.progressBarCalls, 0)
    t.equals(f.callbackCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- GATE WIDENED TO HasK9Access() ALONE (permission audit finding, Job 2).
-- server/search.lua's searchTarget callback gates on HasK9Access(source)
-- alone (confirmed by reading it directly) -- these tests prove client/
-- search.lua's own gate now matches that, offering the ability to a High
-- Command/autoAccessGrade-bypass holder (HasK9Access() true, CanShowK9UI()
-- false -- HasK9Role() deliberately excludes that exact bypass, per
-- server/appearance.lua's own header) instead of silently withholding it,
-- and that DenyK9UIAccess() is now called with the specific, house-standard
-- 'combat.no_access' reason rather than the old generic default.
-- ----------------------------------------------------------------------

t.test('onSelect: a High Command/autoAccessGrade-bypass holder (HasK9Access true, CanShowK9UI false) IS now offered the search -- proves the widened gate, not just its absence', function()
    local f = newSearchFixture({ canShowK9UI = false, hasK9Access = true })
    f.setEntityExists(500, true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(f.denyCallCount(), 0, 'a bypass holder must not be denied at this gate at all')
    t.equals(#f.progressBarCalls, 1, 'the sniff animation must actually start for a bypass holder')
    t.equals(f.callbackCallCount(), 1, 'the real server callback must actually be reached')
end)

t.test('canInteract: a High Command/autoAccessGrade-bypass holder sees the option at all (canInteract widened identically to onSelect)', function()
    local f = newSearchFixture({ canShowK9UI = false, hasK9Access = true })
    t.isTrue(f.vehicleOption().canInteract(500, 1.0, {}, 'x'))
    t.isTrue(f.personOption().canInteract(500, 1.0, {}, 'x'))
end)

t.test('onSelect: HasK9Access() false (whether or not CanShowK9UI() also is) denies access with the specific combat.no_access reason, not the old generic default', function()
    local f = newSearchFixture({ canShowK9UI = false, hasK9Access = false })
    f.setEntityExists(500, true)
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.denyCallCount(), 1)
    t.equals(f.lastDenyReason(), 'combat.no_access')
    t.isFalse(locale('combat.no_access') == locale('common.no_k9_access_unknown'), 'sanity: the two locale strings must actually differ, or this proof is meaningless')
end)

t.test('a certified K9 (CanShowK9UI true, HasK9Access true) is unaffected by the widened gate -- proves this is a pure widening, nothing that worked before stops working', function()
    local f = newSearchFixture({ canShowK9UI = true, hasK9Access = true })
    f.setEntityExists(500, true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.denyCallCount(), 0)
    t.equals(#f.progressBarCalls, 1)
end)

t.test('onSelect: a target entity that no longer exists notifies search.nothing_to_search and never starts the animation', function()
    local f = newSearchFixture()
    -- Never registered via setEntityExists -- DoesEntityExist defaults false.
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.progressBarCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.nothing_to_search'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('onSelect: player cancelling/moving away mid-sniff (progressBar returns false) makes no server call at all, and resets the in-flight flag', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueProgressBarResult(false)
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.callbackCallCount(), 0)

    -- The in-flight flag must have been released -- a fresh attempt right
    -- after must be able to proceed normally, not be silently swallowed.
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.callbackCallCount(), 1)
end)

-- ----------------------------------------------------------------------
-- SEARCH SCENARIO (this pass, coder-frontend) -- the header used to claim
-- "plays a sniff animation" while PerformSearch called nothing but
-- lib.progressBar. Pins that the progress bar call now really does carry
-- an `anim.scenario`, and that it's resolved fresh from the CURRENT ped
-- model each call rather than cached once. See client/search.lua's own
-- "SEARCH SCENARIO" section for the full verification writeup (what was
-- tried, and why WORLD_DOG_SITTING_* was reused rather than a fabricated
-- name).
-- ----------------------------------------------------------------------

t.test('SEARCH SCENARIO: the progress bar now carries a real anim.scenario, not the bare shell it used to (this is the bug this pass fixes -- the header claimed an animation played when nothing did)', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(#f.progressBarCalls, 1)
    local def = f.progressBarCalls[1]
    t.isTrue(type(def.anim) == 'table', 'lib.progressBar must be called with a real anim table, not nothing at all')
    t.isTrue(type(def.anim.scenario) == 'string' and #def.anim.scenario > 0, 'anim.scenario must be a real, non-empty scenario name')
end)

t.test('SEARCH SCENARIO: an unmapped/default ped model falls back to K9_SEARCH_DEFAULT_SCENARIO (WORLD_DOG_SITTING_SHEPHERD), never nil and never an empty string', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    -- setMyPedHandle/setEntityModel deliberately NOT called -- this fixture's
    -- own default (myPedHandle = 1, no entry in entityModels) is exactly the
    -- "unmapped model" case.

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(f.progressBarCalls[1].anim.scenario, 'WORLD_DOG_SITTING_SHEPHERD')
end)

t.test('SEARCH SCENARIO: resolved fresh from the CURRENT ped model on every call, not cached from the first search', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)

    f.setMyPedHandle(77)
    f.setEntityModel(77, GetHashKey('a_c_rottweiler'))
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.progressBarCalls[1].anim.scenario, 'WORLD_DOG_SITTING_ROTTWEILER')

    -- A breed swap between searches (appearance change) -- the SECOND
    -- search must reflect the NEW model, not the first search's cached
    -- scenario name.
    f.setMyPedHandle(88)
    f.setEntityModel(88, GetHashKey('a_c_husky'))
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.progressBarCalls[2].anim.scenario, 'WORLD_DOG_SITTING_RETRIEVER')
end)

-- ----------------------------------------------------------------------
-- RESOURCE-STOP CLEANUP (this pass) -- the one exit path lib.progressBar's
-- own anim.scenario cleanup cannot cover on its own (see client/search.lua's
-- own RESOURCE-STOP CLEANUP comment for the full "why" -- ox_lib runs
-- INSIDE this resource via shared_scripts, so a stop of this resource kills
-- that coroutine before it reaches its own post-loop cleanup native call).
-- ----------------------------------------------------------------------

t.test('RESOURCE-STOP CLEANUP: stopping THIS resource mid-search clears the ped\'s scenario task immediately', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.setMyPedHandle(42)
    -- Reentrant hook fires from INSIDE the (still-pending) progressBar call
    -- -- exactly "the resource stops while the sniff animation is still
    -- playing", the scenario this cleanup exists for.
    f.setProgressBarReentrant(function()
        f.fireResourceStop('john-k9')
    end)
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(#f.clearPedTasksImmediatelyCalls, 1, 'a resource stop while searchInProgress must clear the CURRENT ped\'s scenario task exactly once')
    t.equals(f.clearPedTasksImmediatelyCalls[1], 42, 'must clear the CURRENT PlayerPedId(), not a stale/hardcoded handle')
end)

t.test('RESOURCE-STOP CLEANUP: stopping THIS resource while NO search is running is a clean no-op', function()
    local f = newSearchFixture()
    f.fireResourceStop('john-k9')
    t.equals(#f.clearPedTasksImmediatelyCalls, 0, 'must never touch ped tasks outside an active search')
end)

t.test('RESOURCE-STOP CLEANUP: an UNRELATED resource stopping mid-search must not trigger this cleanup at all', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.setProgressBarReentrant(function()
        f.fireResourceStop('some_other_resource')
    end)
    f.queueProgressBarResult(true)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(#f.clearPedTasksImmediatelyCalls, 0, 'only THIS resource\'s own stop may trigger this cleanup')
end)

-- ----------------------------------------------------------------------
-- SECTION B -- THE IN-FLIGHT GUARD (searchInProgress), THIS TASK'S TOP
-- PRIORITY. Driven via reentrancy: the reentrant onSelect call happens
-- from INSIDE the pending lib.progressBar call, i.e. strictly AFTER
-- `searchInProgress = true` has already been set by the outer call and
-- strictly BEFORE it is ever reset -- exactly the "double-click before the
-- sniff animation visually disables the option" window this flag exists
-- to close.
-- ----------------------------------------------------------------------

t.test('a second onSelect call made WHILE a search is already in flight (same option) is a silent no-op -- no second animation, no second server call', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.setProgressBarReentrant(function()
        f.vehicleOption().onSelect({ entity = 500 }) -- the "double-click"
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(#f.progressBarCalls, 1, 'the reentrant call must never have started a second sniff animation/progress bar')
    t.equals(f.callbackCallCount(), 1, 'and therefore never a second server round trip either')
    t.equals(#f.notifyCalls, 1, 'exactly the ONE real outcome notify -- the reentrant call is silent, per this file\'s own "routine double-click protection, not an error state" comment')
    t.equals(f.notifyCalls[1].description, locale('search.nothing_found'))
end)

t.test('the in-flight guard also blocks a concurrent attempt through the OTHER option (Search Person while Search Vehicle is mid-flight)', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setEntityExists(600, true)
    f.setNetIdForEntity(500, 111)
    f.setNetIdForEntity(600, 222)
    f.setProgressBarReentrant(function()
        f.personOption().onSelect({ entity = 600 })
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().args[1], 'vehicle', 'only the ORIGINAL (vehicle) search must have actually reached the server')
end)

t.test('searchInProgress is always released after a completed search, even one whose callback throws -- a fresh search right after must be able to proceed', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackThrow()
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.failed'))

    f.queueCallbackResponse({ ok = true, contrabandFound = true })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.callbackCallCount(), 2, 'the flag must have been released even after a throw -- this second, independent search must reach the server')
end)

-- ----------------------------------------------------------------------
-- SECTION C -- EVERY REJECTION REASON HAS A CLIENT-SIDE LABEL, AND NONE
-- OF THEM SILENTLY SHOW NOTHING. Full reason set below was found by
-- reading server/search.lua's searchTarget callback directly (grep
-- `reason = ` across that file), not copied from client/search.lua's own
-- header comment. UX PASS: five of these reasons ('invalid_target',
-- 'feature_disabled', 'no_access', 'too_far', 'access_revoked') each get
-- their own distinct locale key now (NAMED_DENIED_REASONS below), never
-- collapsed into one generic message -- see the dedicated catch-all test
-- further down for the one case that still legitimately falls through to
-- search.generic_denied (a truly unrecognized/future reason).
-- ----------------------------------------------------------------------

--- Every reason string server/search.lua's searchTarget callback can
--- return, confirmed by reading that file directly this pass.
--- WAS `SILENT_REASONS`, DELIBERATELY REVERSED (cooldown-UX pass). These
--- two used to be pinned as silent no-ops, following this resource's
--- low-key cooldown convention. That convention is right for an INSTANT
--- refusal -- press a key, nothing happens, the absence of a response is
--- itself the answer -- and it is still applied that way to the CLIENT-side
--- `searchInProgress` double-click guard, which fires before any animation
--- (its own silence test further down is unchanged, on purpose).
---
--- It was wrong HERE. These two reasons come back from the SERVER, which
--- means the player has already stood through the full sniff progress bar
--- with movement disabled before hearing anything. Staying silent then
--- means the dog visibly searched and produced no result at all -- not
--- readable as "wait a moment", just readable as broken. Both now name
--- themselves in 'inform' styling: low-key, because a cooldown is a normal
--- rhythm of the feature, but no longer invisible.
local POST_ANIMATION_LOW_KEY_REASONS = {
    on_cooldown = 'search.on_cooldown_after_search',
    search_in_progress = 'search.already_searching_after_search',
}

--- UX PASS (this pass): every one of these now gets its OWN, distinct
--- plain-English locale key naming that specific reason -- collapsing all
--- five into one generic "Unable to search right now" message (the
--- previous behavior) is exactly the "never a bare 'not permitted'"
--- complaint this pass fixes. Only a genuinely unrecognized/missing reason
--- (see the dedicated catch-all test below) still falls through to
--- search.generic_denied.
local NAMED_DENIED_REASONS = {
    invalid_target = 'search.invalid_target_denied',
    feature_disabled = 'search.feature_disabled_denied',
    no_access = 'search.no_access_denied',
    too_far = 'search.too_far_denied',
    access_revoked = 'search.access_revoked_denied', -- see the DISCLOSED FINDING sub-test below
}

for reason, localeKey in pairs(POST_ANIMATION_LOW_KEY_REASONS) do
    t.test(('reason %q: answers the player rather than leaving a four-second animation with no outcome at all'):format(reason), function()
        local f = newSearchFixture()
        f.setEntityExists(500, true)
        f.setNetIdForEntity(500, 111)
        f.queueCallbackResponse({ ok = false, reason = reason })
        f.vehicleOption().onSelect({ entity = 500 })

        t.equals(#f.notifyCalls, 1, ('reason %q must say something -- by this point the player has already paid the full sniff animation'):format(reason))
        t.equals(f.notifyCalls[1].description, locale(localeKey), 'and must name which of the two it actually is')
        t.equals(f.notifyCalls[1].type, 'inform',
            'LOW-KEY, not error-styled: a cooldown is a normal rhythm of using the feature, not a mistake the player made')

        -- Handled, not stuck: a fresh attempt right after must proceed.
        f.queueCallbackResponse({ ok = true, contrabandFound = false })
        f.vehicleOption().onSelect({ entity = 500 })
        t.equals(f.callbackCallCount(), 2)
    end)
end

t.test('the two post-animation reasons are told APART, not merged into one shared message', function()
    -- "Wait a moment" and "another search is already running" are different
    -- facts, and waiting out a cooldown does not explain the second one.
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false, reason = 'on_cooldown' })
    f.vehicleOption().onSelect({ entity = 500 })
    f.queueCallbackResponse({ ok = false, reason = 'search_in_progress' })
    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(#f.notifyCalls, 2)
    t.isFalse(f.notifyCalls[1].description == f.notifyCalls[2].description)
end)

t.test('neither post-animation reason collapses into the generic catch-all', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false, reason = 'on_cooldown' })
    f.vehicleOption().onSelect({ entity = 500 })
    t.isFalse(f.notifyCalls[1].description == locale('search.generic_denied'))
end)

for reason, localeKey in pairs(NAMED_DENIED_REASONS) do
    t.test(('reason %q: names the real reason (%s) -- never silent, never the generic catch-all, never confused with a clean result'):format(reason, localeKey), function()
        local f = newSearchFixture()
        f.setEntityExists(500, true)
        f.setNetIdForEntity(500, 111)
        f.queueCallbackResponse({ ok = false, reason = reason })
        f.vehicleOption().onSelect({ entity = 500 })
        t.equals(#f.notifyCalls, 1, ('reason %q must produce exactly one notification, never silence'):format(reason))
        t.equals(f.notifyCalls[1].description, locale(localeKey))
        t.isFalse(f.notifyCalls[1].description == locale('search.generic_denied'), ('reason %q must NOT collapse into the generic catch-all'):format(reason))
        t.equals(f.notifyCalls[1].type, 'error')
    end)
end

t.test('a genuinely unrecognized/future reason string still falls through to the generic catch-all (search.generic_denied) -- proves the catch-all still works, not just the five named reasons above', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false, reason = 'a_totally_unrecognized_future_reason' })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('reason "search_failed": a DISTINCT message from generic_denied AND from a clean "nothing found" result -- never collapsed into either', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false, reason = 'search_failed' })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.failed'))
    t.notContains(f.notifyCalls[1].description, locale('search.generic_denied'))
    t.notContains(f.notifyCalls[1].description, locale('search.nothing_found'))
end)

t.test('a completely EMPTY round trip (result == nil, e.g. a dropped/absent response) is treated as a rejection with no reason -- falls to generic_denied, never silent, never a false "nothing found"', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    -- Nothing queued at all -- callbackAwait's table.remove on an empty queue returns nil.
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1, 'a nil result must not be silently swallowed')
    t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
end)

t.test('a result with ok == false and NO reason field at all also falls to generic_denied, never silent', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.generic_denied'))
end)

t.test('lib.callback.await THROWING outright (ox_lib\'s real timeout/rejection behavior) is caught and produces the SAME search.failed message as an explicit search_failed reason -- never an uncaught error, never silence', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackThrow()
    -- pcall this call site itself too: if client/search.lua's own internal
    -- pcall wrapper (see this file's own "everything ... is wrapped in
    -- pcall" comment) were ever removed, this would surface as an escaped
    -- error here rather than a clean assertion failure below.
    local ok = pcall(function() f.vehicleOption().onSelect({ entity = 500 }) end)
    t.isTrue(ok, 'a thrown lib.callback.await must never escape PerformSearch uncaught')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.failed'))
end)

-- 'access_revoked' (a decertified-mid-search re-check) is now covered by
-- the NAMED_DENIED_REASONS loop test above, which asserts it gets its own
-- search.access_revoked_denied message -- SUPERSEDES an earlier "DISCLOSED
-- FINDING" test here that accepted the old collapsed-into-generic_denied
-- behavior as merely a documentation drift rather than fixing it. Removed
-- rather than left alongside a contradictory assertion.

-- ----------------------------------------------------------------------
-- SECTION D -- netId CAPTURE BEFORE THE SNIFF ANIMATION. Proven by
-- mutating the entity->netId mapping FROM INSIDE the (reentrant)
-- progressBar stub -- i.e. strictly between capture and the eventual
-- server call, modeling a despawn/respawn that reassigns the same entity
-- handle to a different netId mid-animation.
-- ----------------------------------------------------------------------

t.test('netId is captured BEFORE the sniff animation runs -- a mid-animation handle reassignment must not retarget the eventual server call', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.setProgressBarReentrant(function()
        -- Simulates entity handle 500 being despawned and its slot reused
        -- by an unrelated entity with a different netId, strictly DURING
        -- the sniff animation.
        f.setNetIdForEntity(500, 222)
    end)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })

    f.vehicleOption().onSelect({ entity = 500 })

    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().args[2], 111,
        'targetNetId must be the value captured BEFORE the animation (111), never the value the mapping was mutated to mid-animation (222)')
end)

-- ----------------------------------------------------------------------
-- SECTION E -- contraband found / nothing found rendering, and the
-- confirmation that THIS FILE never itself broadcasts anything -- the
-- bystander alert is server-initiated only (see this fixture's own
-- deliberate omission of a TriggerServerEvent stub, in its header).
-- ----------------------------------------------------------------------

t.test('a clean contrabandFound == true result notifies search.contraband_found as a success, and NEVER triggers any event itself', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = true, contrabandFound = true, totalWeight = 50, alertTier = 'whine' })
    f.vehicleOption().onSelect({ entity = 500 }) -- would throw if it ever called the unstubbed TriggerServerEvent
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.contraband_found'))
    t.equals(f.notifyCalls[1].type, 'success')
end)

t.test('a clean contrabandFound == false result is a NON-SILENT "nothing found" notify, distinct from every rejection message', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setNetIdForEntity(500, 111)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.personOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('search.nothing_found'))
    t.equals(f.notifyCalls[1].type, 'info')
end)

t.test('the sniff animation label differs between Search Vehicle and Search Person, and the real Config.SearchZones.sniffAnimDurationMs is used for both', function()
    local f = newSearchFixture()
    f.setEntityExists(500, true)
    f.setEntityExists(600, true)
    f.setNetIdForEntity(500, 1)
    f.setNetIdForEntity(600, 2)
    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.vehicleOption().onSelect({ entity = 500 })
    t.equals(f.progressBarCalls[1].label, locale('search.progress_vehicle_label'))
    t.equals(f.progressBarCalls[1].duration, f.env.Config.SearchZones.sniffAnimDurationMs)

    f.queueCallbackResponse({ ok = true, contrabandFound = false })
    f.personOption().onSelect({ entity = 600 })
    t.equals(f.progressBarCalls[2].label, locale('search.progress_person_label'))
end)

-- ----------------------------------------------------------------------
-- SECTION F -- `source ~= 65535` origin guard on
-- 'john-k9:client:playContrabandAlert'.
--
-- SCOPE NOTE, repeated here rather than left only in this file's header
-- (per this task's own instruction): every test below pins what THIS
-- FILE'S CODE does when `source` holds a given value at call time. NONE
-- of them settle, and none should be read as settling, the underlying
-- engine question this project tracks as open decision D3
-- (DEVELOPER_REFERENCE.md) -- whether FiveM's real client runtime can ever be
-- made to deliver a forged local trigger with a stale/incorrect `source`
-- left over from an earlier genuine server-sent event landing on the
-- same connection. Independent attempts to settle D3 by reading the game
-- engine's own source code have repeatedly hit the same wall (four,
-- per DEVELOPER_REFERENCE.md's own count as of this session; this task's own
-- brief counts five -- whichever the exact number, neither this test file
-- nor any other Lua-level sandbox test can add or subtract from it).
-- DEVELOPER_REFERENCE.md's own words: "Do not settle this by reading more
-- code -- only the live test settles it." A green result below proves the
-- guard AS WRITTEN rejects a non-65535 source; it must never be mistaken
-- for having closed D3.
-- ----------------------------------------------------------------------

t.test('playContrabandAlert: source == 65535 (the documented genuine-server sentinel) is processed', function()
    local f = newSearchFixture()
    f.triggerContrabandAlert(65535, 200, 'whine')
    t.equals(#f.playSoundOnNetworkEntityCalls, 1, 'a genuinely server-sourced call must be processed -- see this section\'s own D3 scope note above')
    t.equals(f.playSoundOnNetworkEntityCalls[1].netId, 200)
    t.equals(f.playSoundOnNetworkEntityCalls[1].soundName, 'whine')
end)

t.test('playContrabandAlert: a forged local trigger with an arbitrary non-65535 numeric source is rejected -- pins the CODE\'s behavior only, D3 remains open regardless (see this section\'s header)', function()
    local f = newSearchFixture()
    f.triggerContrabandAlert(1, 200, 'aggressive_bark')
    t.equals(#f.playSoundOnNetworkEntityCalls, 0)
end)

t.test('playContrabandAlert: source left nil (a bare local TriggerEvent() carrying no origin at all) is also rejected -- same D3 scope caveat as above', function()
    local f = newSearchFixture()
    f.triggerContrabandAlert(nil, 200, 'whine')
    t.equals(#f.playSoundOnNetworkEntityCalls, 0)
end)

os.exit(t.summary())
