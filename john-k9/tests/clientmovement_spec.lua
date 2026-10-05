--[[
    tests/clientmovement_spec.lua

    Direct, black-box tests of client/movement.lua against the REAL,
    unmodified production file. Originally scoped to three priorities named
    as "what matters most" for this file; a fourth and fifth were added in
    the "close the any-ped speed-system gap" pass to pin down a real,
    previously disclosed test gap and a real, newly-found cleanup gap:

      1. RequestLeashAttach()'s gate -- the officer-initiated-vs-K9-initiated
         asymmetry fix (see that function's own "BUG FIX" doc comment in
         client/movement.lua). Both initiation directions are proven to
         genuinely reach TriggerServerEvent below.
      2. The THREE, distinct, non-overlapping onResourceStop handlers (camera
         view-mode reset, leash auto-detach, move-rate override reset).
      3. RecomputeK9MoveRate() -- the multiplicative composer, its clamp
         range, its ANY-PED `IsOwnModelK9() or HasK9Access()` gate, and its
         own onResourceStop-driven reset.
      4. The AgilityBasicJump=false jump/crouch suppression thread -- proves
         it stays keyed on IsEntityModelK9(PlayerPedId()) (the BODY), not
         IsOwnModelK9() (which would incorrectly also suppress a role-holder
         on a human body), pinning the owner's own explicit, dated decision.
      5. The always-on move-rate WATCHDOG (added this pass) -- closes a real
         "unbounded trap" the ANY-PED fix in #3 opened: an off-model
         role-holder can now carry a genuine non-1.0 rate, but every OTHER
         caller of RecomputeK9MoveRate() is gated behind a server push that
         simply stops once role/access is lost, with no dedicated
         "you lost K9 access" broadcast anywhere in this resource. Proves
         the watchdog converges such a player back to neutral on its own,
         AND that it costs nothing (no HasK9Access() network round trip) for
         the overwhelming common case of a player with nothing to watch.
      6. The AgilityBasicJump PER-PERSON BLOCK (client/featureblocks.lua
         hand-off item 2, added THIS pass) -- proves the suppression thread
         is genuinely CREATED (not merely a no-op check inside an
         always-running thread) the instant a block first arrives via the
         'john-k9:client:featureBlocksApplied' local event, even with
         Config.Features.AgilityBasicJump = true (the shipped default,
         where NO thread existed at all before this addition); that it
         self-releases within one more pass once the block clears; that the
         SAME owner-pinned human-body exemption from priority #4 above holds
         regardless of WHICH of the two reasons (global flag vs. per-person
         block) is driving suppression; and, the interval decision's own
         central claim, that the STEADY STATE (blocked == false, the
         overwhelming common case) creates NO thread at all -- not a cheap
         poll, genuinely zero -- unlike the hand-off note's originally
         proposed 1Hz poll.
      7. The elastic leash pull-back thread's IsRestingInKennel() exclusion
         (leash-in-kennel fix, this pass) -- CLOSES, partially, this file's
         own former "single largest disclosed gap" (that thread's body was
         captured but never stepped at all). Proves the thread genuinely
         pulls an out-of-range leashed pair back together by default, that
         resting in a kennel now excludes that pull-back exactly like being
         in a vehicle or tucked into a K9 cruiser already did, that the
         exclusion is a soft dependency (client/kennel.lua absent degrades
         safely), and that the hard-cap safety-valve auto-detach is NOT
         excludable by any of the three exclusions -- see PRIORITY #7's own
         section further down for the full test list and "WHAT THIS FILE
         STILL DOES NOT COVER" for what remains genuinely untested about
         this thread even after this addition.

    Everything else in this 1900+ line file is covered LIGHTLY or not at
    all -- see "WHAT THIS FILE DOES NOT COVER" at the bottom for the full,
    honest list. This is a deliberate scope decision (matching this task's
    own instruction to do the named priorities well rather than everything
    thinly), not an oversight.

    FIXTURE CONFIG, NOT REAL config.lua -- per this task's explicit
    instruction: this file's own fixture builds a small, LOCAL `Config`
    table with only the one field client/movement.lua actually reads at
    LOAD time (`Config.Features.AgilityBasicJump`). Defaults to `true`
    (this file's long-standing default, so every PRIORITY #1-3 test below
    that passes no opts at all keeps meaning exactly what it always meant --
    the AgilityBasicJump-suppression CreateThread branch never registers,
    so those tests never need to stub DisableControlAction at all) --
    overridable to `false` per-test via `newMovementFixture({ agilityBasicJump
    = false, ... })`, used only by PRIORITY #4 below. This spec never loads
    the real config.lua and asserts nothing about its shipped values, so it
    keeps passing regardless of which way config.lua's Config.Features
    flags are set on any given day, whatever their current count is. Every
    OTHER Config field this file reads
    (Config.LeashMaxDistance, Config.CertifyProximityMeters,
    Config.DoorInteraction.*) is read ONLY inside the three ox_target
    registration functions, which this spec never invokes (see "WHAT THIS
    FILE DOES NOT COVER") -- so this fixture's Config table genuinely never
    needs those fields either, not because they were forgotten.

    CreateThread IS CAPTURED, AND OPTIONALLY STEPPABLE -- by default
    (opts.stepThreads unset/false) this spec only counts how many threads
    client/movement.lua registers, never steps or asserts on any thread's
    BODY. PRIORITY #4 below opts INTO real stepping
    (`newMovementFixture({ stepThreads = true, ... })`, backed by
    Sandbox.newThreadRunner()) specifically to exercise the jump/crouch
    suppression thread's body. PRIORITY #7 (leash-in-kennel fix, added THIS
    pass) does the same for the elastic leash pull-back thread (softLimit/
    hardCap pull-back, the three exclusions, the hard-cap auto-detach safety
    valve) -- this file's own fixture now carries a real Vec3 stub plus
    GetEntityCoords/SetEntityCoords/IsPedInAnyVehicle/GetPlayerPed, the exact
    machinery combat_spec.lua/clientradial_spec.lua already use for their own
    unrelated Vec3 needs, specifically so PRIORITY #7 could stop being a
    disclosed gap. See "WHAT THIS FILE STILL DOES NOT COVER" near the bottom
    for what remains genuinely untested about that thread even after this
    addition (its exact pull-strength math, the detachRequestedForSafety
    single-fire guard).

    NOTIFICATION TYPE: 'info', NOT 'inform' -- ox_lib's real
    NotificationType union is 'info' | 'warning' | 'success' | 'error';
    'inform' was never a member. client/movement.lua's own two former
    'inform' call sites (ToggleK9Camera's toggle notice, leashDetached's
    notice) were switched to 'info' this session -- every assertion below
    that checks a notify `type` uses the real, current value.

    ONE FRESH SANDBOX PER TEST -- same discipline as every other spec in
    this suite (main_spec.lua, clientradial_spec.lua, clientvision_spec.lua):
    this file's own file-load-time locals (isFirstPersonK9View, leashState,
    detachRequestedForSafety, lastAppliedMoveRate, K9MoveRateModifiers) are
    exactly the kind of module-lifetime state that must never leak between
    two unrelated test cases.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- same deterministic, non-native formula
-- main_spec.lua/kennel_spec.lua already use. Only needed here because
-- K9_SIT_SCENARIO_BY_MODEL_HASH / K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH
-- are built from it at FILE-LOAD time -- this spec never asserts on either
-- table's contents, it just needs load to succeed without erroring.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

-- ----------------------------------------------------------------------
-- Vec3-alike stub -- THIS PASS (leash-in-kennel exclusion fix). Closes the
-- header's own previously-disclosed "single largest gap" (the elastic
-- leash pull-back thread's BODY was captured but never stepped) just
-- enough to prove the new IsRestingInKennel() exclusion actually works --
-- same shape as tests/clientkennel_spec.lua's/tests/clientcombat_spec.lua's
-- own identical Vec3MT stubs, EXTENDED with __div/__mul/__add (this
-- thread's own pull-back math needs `(partnerCoords - myCoords) / dist`
-- and `myCoords + dir * pullAmount`, which neither of those two files'
-- narrower stubs needed).
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__add = function(a, b)
    return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, Vec3MT)
end
Vec3MT.__mul = function(a, b)
    return setmetatable({ x = a.x * b, y = a.y * b, z = a.z * b }, Vec3MT)
end
Vec3MT.__div = function(a, b)
    return setmetatable({ x = a.x / b, y = a.y / b, z = a.z / b }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end

local RESOURCE_NAME = 'john-k9'

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real client/movement.lua
--- loaded against a LOCAL fixture Config (see this file's header) plus a
--- controllable/capturing stand-in for every native or cross-file global
--- this spec's exercised call paths touch.
--- @param opts { agilityBasicJump: boolean?, stepThreads: boolean?, featureBlocksAvailable: boolean?, blockedFeatures: table? }? --
---   agilityBasicJump defaults to `true` (this file's long-standing default,
---   preserved for every pre-existing call site below that passes no opts
---   at all -- see this file's header on why AgilityBasicJump=true is the
---   default). Set to `false` to register the jump/crouch suppression
---   thread instead (PRIORITY #4 below). stepThreads defaults to `false`
---   (CreateThread only counted, never invoked, as before) -- set `true` to
---   back CreateThread/Wait with Sandbox.newThreadRunner() so a registered
---   thread's body can actually be stepped, needed only by PRIORITY #4's
---   suppression-thread tests below. featureBlocksAvailable (default true,
---   same "soft dependency" convention clientagility_spec.lua/
---   clientradial_spec.lua already use) controls whether IsK9FeatureBlocked
---   is injected into the sandbox at all -- set `false` to prove the
---   fail-open path (PRIORITY #6 below) genuinely never calls a nil global.
---   blockedFeatures (default {}) seeds the initial block state read by
---   that same stand-in.
--- @return table fixture
local function newMovementFixture(opts)
    opts = opts or {}
    local threadRunner = opts.stepThreads and Sandbox.newThreadRunner() or nil

    local isOwnModelK9 = true
    local canShowK9UI = true
    local function IsOwnModelK9() return isOwnModelK9 end
    local canShowK9UICallCount = 0
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    local denyCallCount = 0
    local function DenyK9UIAccess() denyCallCount = denyCallCount + 1 end

    -- ANY-PED MOVE-RATE FIX (this pass): RecomputeK9MoveRate()'s own gate is
    -- now `IsOwnModelK9() or HasK9Access()`, not IsOwnModelK9() alone -- see
    -- that function's own "SCOPE, CORRECTED" header comment in the real
    -- production file for the full writeup (two independent agents found the
    -- same real bug: a role-holder on a non-K9 body got a server grant and a
    -- success toast but zero actual speed change). HasK9Access() is a REAL
    -- cross-file global from client/main.lua -- called there UNGUARDED,
    -- exactly like IsOwnModelK9()/CanShowK9UI() above from that same
    -- always-loaded foundational file (Phase 1 scaffold, never a soft/
    -- optional dependency the way client/appearance.lua's IsK9Role is) -- so
    -- this fixture needs its own controllable stand-in for it, same as it
    -- already has for those two. Defaults to false so every PRE-EXISTING
    -- "not IsOwnModelK9" test below keeps meaning exactly what it always
    -- meant (neither model nor access -- a full reset), and the widening
    -- itself gets its own dedicated tests further down.
    local hasK9Access = false
    local hasK9AccessCallCount = 0
    local function HasK9Access() hasK9AccessCallCount = hasK9AccessCallCount + 1; return hasK9Access end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    -- LOCAL (same-client) events, as distinct from serverEvents above.
    -- client/movement.lua re-broadcasts 'john-k9:client:leashStateChanged'
    -- locally whenever leashState flips, so client/radial.lua rebuilds its
    -- menu and re-evaluates IsLeashed() right then -- otherwise the Detach
    -- item's availability would only refresh at resource start or an ox_lib
    -- restart, which is the bug that fix exists for. This stub has to be
    -- present or every leash test dies at the TriggerEvent call itself.
    local localEvents = {}
    local function TriggerEvent(eventName, ...)
        localEvents[#localEvents + 1] = { event = eventName, args = { ... } }
    end

    local notifyCalls = {}
    local alertDialogResponse = 'confirm'
    local alertDialogCalls = {}
    local lib = {
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
        alertDialog = function(payload)
            alertDialogCalls[#alertDialogCalls + 1] = payload
            return alertDialogResponse
        end,
    }

    -- pedHandle 1 exists by default -- RecomputeK9MoveRate's "no valid ped"
    -- branch is exercised explicitly per-test via setPedMissing()/setPed().
    local pedHandle = 1
    local existingEntities = { [1] = true }
    local entityModels = {}
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityModel(entity) return entityModels[entity] end

    -- LEASH PULL-BACK THREAD MACHINERY -- THIS PASS (leash-in-kennel
    -- exclusion fix, PRIORITY #7 below). Coords are a shared table keyed by
    -- ANY ped handle, same convention tests/clientkennel_spec.lua already
    -- established for its own coordsByHandle. Defaults: myPed (handle 1)
    -- and any as-yet-unregistered handle both read as the origin, so a
    -- test that forgets to set a partner's coords fails loudly via `dist`
    -- staying 0 (never pulled back) rather than erroring.
    local coordsByHandle = { [1] = vec3(0, 0, 0) }
    local setCoordsCalls = {}
    local function GetEntityCoords(handle) return coordsByHandle[handle] or vec3(0, 0, 0) end
    local function SetEntityCoords(handle, x, y, z, ...)
        coordsByHandle[handle] = vec3(x, y, z)
        setCoordsCalls[#setCoordsCalls + 1] = { handle = handle, x = x, y = y, z = z }
    end
    local pedInVehicle = false
    local function IsPedInAnyVehicle(_ped, _lastVehicle) return pedInVehicle end
    local playerPedByIndex = {}
    local function GetPlayerPed(playerIndex) return playerPedByIndex[playerIndex] or 0 end

    -- IsRestingInKennel -- THIS PASS. Soft dependency, same
    -- `opts.provideXxx ~= false` convention as IsK9FeatureBlocked above:
    -- present by default (client/kennel.lua loaded, answering `false`
    -- unless a test says otherwise), omittable via
    -- opts.provideIsRestingInKennel = false to prove the real
    -- `IsRestingInKennel and IsRestingInKennel()` guard in
    -- client/movement.lua degrades safely with client/kennel.lua entirely
    -- absent.
    local isRestingInKennelValue = false
    local function IsRestingInKennel() return isRestingInKennelValue end

    -- PRIORITY #4 (AgilityBasicJump suppression thread) -- a SEPARATE
    -- knob from IsOwnModelK9()/entityModels above on purpose: the real
    -- production gate for this thread is `IsEntityModelK9(PlayerPedId())`,
    -- deliberately NOT IsOwnModelK9() (owner's decision, see that thread's
    -- own "OWNER'S DECISION, 2026-08-25: MODEL, not role" comment) -- a
    -- role-holder on a human body must have IsOwnModelK9() able to read
    -- `true` (role-widened) while this reads `false` (real body is human),
    -- which a single shared table could not represent.
    local entityModelK9 = {}
    local function IsEntityModelK9(entity) return entityModelK9[entity] == true end

    local disableControlActionCalls = {}
    local function DisableControlAction(inputGroup, control, disable)
        disableControlActionCalls[#disableControlActionCalls + 1] = { inputGroup = inputGroup, control = control, disable = disable }
    end

    -- PRIORITY #6 (AgilityBasicJump PER-PERSON BLOCK, added this pass) --
    -- same "controllable stand-in, soft dependency" convention
    -- clientagility_spec.lua/clientradial_spec.lua already use for the
    -- identical global. `featureBlocksAvailable` defaults to true (this
    -- global is injected); set opts.featureBlocksAvailable = false to prove
    -- the fail-open path never calls a nil function.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end

    local setMoveRateCalls = {}
    local function SetPedMoveRateOverride(ped, rate)
        setMoveRateCalls[#setMoveRateCalls + 1] = { ped = ped, rate = rate }
    end

    local camViewModeCalls = {}
    local function SetFollowPedCamViewMode(mode) camViewModeCalls[#camViewModeCalls + 1] = mode end

    local function GetCurrentResourceName() return RESOURCE_NAME end

    local playerIndexByServerId = {}
    local function GetPlayerFromServerId(serverId) return playerIndexByServerId[serverId] or -1 end
    local function GetPlayerName(playerIndex) return 'Player#' .. tostring(playerIndex) end

    local commands = {}
    local function RegisterCommand(name, handler) commands[name] = handler end
    local keyMappingCount = 0
    local function RegisterKeyMapping(...) keyMappingCount = keyMappingCount + 1 end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    -- Captured, and invoked ONLY when opts.stepThreads is true (PRIORITY #4
    -- and PRIORITY #5 below) -- see this file's header on why the elastic
    -- pull-back thread's BODY specifically stays a disclosed gap
    -- regardless. threadRunner.CreateThread captures every thread this file
    -- registers, in registration order: (1) the elastic leash pull-back
    -- thread (registered near the top of the file), (2) the always-on
    -- move-rate watchdog (PRIORITY #5, unconditional -- registers
    -- regardless of AgilityBasicJump), (3) the jump/crouch suppression
    -- thread under test in PRIORITY #4 (registered further down still, and
    -- ONLY when AgilityBasicJump=false). Every fixture accessor that steps
    -- threads (PRIORITY #4/#5's `step()`) resumes ALL of them every call --
    -- see that accessor's own doc comment below for why resuming the OTHER
    -- threads alongside whichever one a given test is actually targeting is
    -- safe and asserted-inert.
    local threadCount = 0
    local function CreateThread(fn)
        threadCount = threadCount + 1
        if threadRunner then threadRunner.CreateThread(fn) end
    end
    -- Only ever reached when threadRunner exists (CreateThread above is the
    -- only way a thread body starts running at all in this fixture) -- a
    -- harmless no-op otherwise, never called.
    local function Wait(ms) if threadRunner then threadRunner.Wait(ms) end end

    -- See this file's header "FIXTURE CONFIG, NOT REAL config.lua" -- the
    -- ONLY field client/movement.lua reads at load time. Defaults to `true`
    -- (this file's long-standing default -- see newMovementFixture()'s own
    -- doc comment above), overridable per-test via opts.agilityBasicJump.
    -- LeashMaxDistance -- THIS PASS (PRIORITY #7, leash-in-kennel exclusion
    -- fix): the elastic pull-back thread's own softLimit/hardCap/
    -- pullZoneStart math reads this at RUN time (every tick), not load
    -- time, so unlike AgilityBasicJump above it needs no opts plumbing of
    -- its own -- a single fixed fixture-owned value (10.0, an arbitrary
    -- round number with no correctness dependency on config.lua's real
    -- shipped value) is enough for every PRIORITY #7 test below to compute
    -- its own pullZoneStart/hardCap distances against.
    local Config = { Features = { AgilityBasicJump = opts.agilityBasicJump ~= false }, LeashMaxDistance = 10.0 }

    local overrides = {
        GetHashKey = GetHashKey,
        Config = Config,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = CreateThread,
        Wait = Wait,
        IsOwnModelK9 = IsOwnModelK9,
        IsEntityModelK9 = IsEntityModelK9,
        DisableControlAction = DisableControlAction,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        TriggerServerEvent = TriggerServerEvent,
        TriggerEvent = TriggerEvent,
        lib = lib,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        GetEntityModel = GetEntityModel,
        SetPedMoveRateOverride = SetPedMoveRateOverride,
        SetFollowPedCamViewMode = SetFollowPedCamViewMode,
        GetCurrentResourceName = GetCurrentResourceName,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerName = GetPlayerName,
        GetEntityCoords = GetEntityCoords,
        SetEntityCoords = SetEntityCoords,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        GetPlayerPed = GetPlayerPed,
    }
    -- Soft dependency, same convention as IsK9FeatureBlocked below --
    -- omitted entirely (not merely stubbed false) when
    -- opts.provideIsRestingInKennel == false.
    if opts.provideIsRestingInKennel ~= false then
        overrides.IsRestingInKennel = IsRestingInKennel
    end
    -- PRIORITY #6 -- soft dependency, omitted entirely (not merely stubbed
    -- false) when opts.featureBlocksAvailable == false, so the fail-open
    -- test below exercises the REAL `type(IsK9FeatureBlocked) == 'function'`
    -- guard against a genuinely absent global, not a stand-in that happens
    -- to answer false.
    if featureBlocksAvailable then
        overrides.IsK9FeatureBlocked = IsK9FeatureBlocked
    end

    local env = Sandbox.newEnv(overrides)

    Sandbox.loadInto('../client/movement.lua', env)

    return {
        env = env,
        commands = commands,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        denyCallCount = function() return denyCallCount end,
        setHasK9Access = function(v) hasK9Access = v end,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        localEvents = localEvents,
        countLocalEvents = function(name)
            local n = 0
            for _, e in ipairs(localEvents) do
                if e.event == name then n = n + 1 end
            end
            return n
        end,
        notifyCalls = notifyCalls,
        alertDialogCalls = alertDialogCalls,
        setAlertDialogResponse = function(v) alertDialogResponse = v end,
        setMoveRateCalls = setMoveRateCalls,
        camViewModeCalls = camViewModeCalls,
        setPed = function(handle, exists)
            pedHandle = handle
            if exists ~= false then existingEntities[handle] = true end
        end,
        setPedMissing = function() pedHandle = 0 end,
        setModel = function(entity, hash) entityModels[entity] = hash end,
        setEntityModelK9 = function(entity, v) entityModelK9[entity] = v end,
        disableControlActionCalls = disableControlActionCalls,
        -- PRIORITY #6 -- same shape as clientradial_spec.lua's own
        -- setBlocked/fireFeatureBlocksApplied/featureBlocksAppliedHandlerCount
        -- trio for the identical mechanism.
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        fireFeatureBlocksApplied = function()
            for _, handler in ipairs(eventHandlers['john-k9:client:featureBlocksApplied'] or {}) do
                handler()
            end
        end,
        featureBlocksAppliedHandlerCount = function() return #(eventHandlers['john-k9:client:featureBlocksApplied'] or {}) end,
        --- Resumes EVERY captured thread once (Sandbox.newThreadRunner()'s
        --- own step() semantics). Only meaningful when this fixture was
        --- built with opts.stepThreads = true -- see newMovementFixture()'s
        --- own doc comment above. Registers, in this order: (1) the elastic
        --- leash pull-back thread, (2) the always-on move-rate watchdog
        --- (PRIORITY #5), and, ONLY when AgilityBasicJump=false, (3) the
        --- jump/crouch suppression thread under test in PRIORITY #4.
        --- Resuming ALL of them every call, even when a given test only
        --- cares about one, is safe and asserted-inert for the other two:
        --- `leashState` is never set to non-nil by any test in either
        --- PRIORITY #4 or #5, so thread (1)'s own body short-circuits
        --- straight to its idle Wait() without ever touching
        --- GetEntityCoords/IsPedInAnyVehicle/any other native this fixture
        --- does not stub; thread (2) (the watchdog) only ever does real
        --- work while `lastAppliedMoveRate` is non-1.0, so a PRIORITY #4
        --- test (which never touches the move-rate composer at all) always
        --- finds it idle.
        step = function()
            assert(threadRunner, 'newMovementFixture(opts): step requires opts.stepThreads = true')
            threadRunner.step()
        end,
        registerPlayer = function(serverId, playerIndex) playerIndexByServerId[serverId] = playerIndex end,
        -- LEASH PULL-BACK THREAD helpers -- THIS PASS (PRIORITY #7).
        setPedCoords = function(handle, x, y, z) coordsByHandle[handle] = vec3(x, y, z) end,
        setCoordsCalls = setCoordsCalls,
        setPedInVehicle = function(v) pedInVehicle = v end,
        --- Registers a partner ped so GetPlayerFromServerId ->
        --- GetPlayerPed -> DoesEntityExist all resolve to a real, existing
        --- handle -- mirrors registerPlayer() above but also marks the
        --- resulting ped handle as existing (registerPlayer alone only
        --- wires the serverId -> playerIndex half already used by the
        --- leash attach/detach net-event tests).
        registerPartnerPed = function(serverId, playerIndex, handle)
            playerIndexByServerId[serverId] = playerIndex
            playerPedByIndex[playerIndex] = handle
            existingEntities[handle] = true
        end,
        setIsRestingInKennel = function(v) isRestingInKennelValue = v end,
        threadCount = function() return threadCount end,
        keyMappingCount = function() return keyMappingCount end,
        commandCount = function()
            local n = 0
            for _ in pairs(commands) do n = n + 1 end
            return n
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        netEventNames = netEvents,
        triggerLeashAttached = function(sourceValue, partnerServerId, isConstrained)
            local handler = assert(netEvents['john-k9:client:leashAttached'],
                'client/movement.lua did not register a john-k9:client:leashAttached handler')
            env.source = sourceValue
            handler(partnerServerId, isConstrained)
        end,
        triggerLeashDetached = function(sourceValue, reason)
            local handler = assert(netEvents['john-k9:client:leashDetached'],
                'client/movement.lua did not register a john-k9:client:leashDetached handler')
            env.source = sourceValue
            handler(reason)
        end,
        triggerLeashAttachRequest = function(sourceValue, fromServerId)
            local handler = assert(netEvents['john-k9:client:leashAttachRequest'],
                'client/movement.lua did not register a john-k9:client:leashAttachRequest handler')
            env.source = sourceValue
            handler(fromServerId)
        end,
        --- GAP 1, PART 2 -- fires the new
        --- 'john-k9:client:k9SpeedOverrideStatus' handler, mirroring the
        --- three triggerLeashXxx helpers above exactly.
        --- @param sourceValue number
        --- @param status any
        triggerSpeedOverrideStatus = function(sourceValue, status)
            local handler = assert(netEvents['john-k9:client:k9SpeedOverrideStatus'],
                'client/movement.lua did not register a john-k9:client:k9SpeedOverrideStatus handler')
            env.source = sourceValue
            handler(status)
        end,
    }
end

-- ========================================================================
-- Sanity: the file loaded and exposed/registered exactly what its own
-- FILE-TO-FILE CONTRACT documents, before trusting any test below.
-- ========================================================================

t.test('client/movement.lua exposes its five documented resource-globals', function()
    local f = newMovementFixture()
    t.isNotNil(f.env.ToggleK9Camera)
    t.isNotNil(f.env.K9Sit)
    t.isNotNil(f.env.RequestLeashAttach)
    t.isNotNil(f.env.DetachLeash)
    t.isNotNil(f.env.IsLeashed)
    t.isNotNil(f.env.K9MoveRateModifiers, 'the move-rate composer table')
    t.isNotNil(f.env.RecomputeK9MoveRate, 'the move-rate composer function')
end)

t.test('registers exactly 3 onResourceStop handlers (camera reset, leash auto-detach, move-rate reset)', function()
    local f = newMovementFixture()
    t.equals(f.onResourceStopHandlerCount(), 3)
end)

t.test('registers exactly 1 onResourceStart handler (ox_target lifecycle re-registration -- not exercised by this spec, see "WHAT THIS FILE DOES NOT COVER")', function()
    local f = newMovementFixture()
    t.equals(f.onResourceStartHandlerCount(), 1)
end)

t.test('creates exactly 2 threads (the elastic leash pull-back thread, and the always-on move-rate watchdog) given AgilityBasicJump=true in this fixture\'s Config -- proves the AgilityBasicJump-suppression thread branch really is skipped', function()
    local f = newMovementFixture()
    t.equals(f.threadCount(), 2, 'leash pull-back + move-rate watchdog (see PRIORITY #5, the watchdog is unconditional -- it registers regardless of AgilityBasicJump)')
end)

t.test('registers exactly 5 RegisterNetEvent handlers (leashAttachRequest, leashAttached, leashDetached, playDoorScratch, k9SpeedOverrideStatus)', function()
    local f = newMovementFixture()
    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 5, 'GAP 1 PART 2 added john-k9:client:k9SpeedOverrideStatus -- this count must move in lockstep with every new RegisterNetEvent this file adds, per this test\'s own name')
    t.isNotNil(f.netEventNames['john-k9:client:k9SpeedOverrideStatus'], 'the new handler must be registered under this exact event name')
end)

-- ========================================================================
-- PRIORITY #1 -- RequestLeashAttach()'s gate. This session's regression: an
-- unconditional CanShowK9UI() pre-check silently denied every
-- officer-initiated "Attach Leash" request before it ever reached the
-- server, because CanShowK9UI() == IsOwnModelK9() and HasK9Access(), which
-- is false by construction for an officer (never modeled as a K9). The fix
-- only applies the K9-shaped pre-check when the LOCAL player would actually
-- be the K9-role party. Both directions are proven below to genuinely reach
-- TriggerServerEvent -- the server (CheckLeashEligibility) is the one place
-- that actually decides role/eligibility.
-- ========================================================================

-- ========================================================================
-- /k9leash -- ONE command: detach when leashed, otherwise attach to the
-- nearest candidate. Detach is never gated ("gate the start, never the
-- stop"); attach is.
-- ========================================================================

--- @return table f, table calls -- calls.detach / calls.attach (target ids)
local function leashCommandFixture(leashed, candidate)
    local f = newMovementFixture()
    local calls = { detach = 0, attach = {} }
    f.env.IsLeashed = function() return leashed end
    f.env.DetachLeash = function() calls.detach = calls.detach + 1 end
    f.env.RequestLeashAttach = function(id) calls.attach[#calls.attach + 1] = id end
    f.env.FindNearestLeashCandidate = function() return candidate end
    return f, calls
end

t.test('/k9leash while leashed detaches -- even for a player who has lost K9 access', function()
    local f, calls = leashCommandFixture(true, 7)
    f.setCanShowK9UI(false)
    f.commands['k9leash']()
    t.equals(calls.detach, 1)
    t.equals(#calls.attach, 0)
    t.equals(f.denyCallCount(), 0, 'letting go is never refused')
end)

t.test('/k9leash while not leashed attaches to the nearest candidate', function()
    local f, calls = leashCommandFixture(false, 7)
    f.setCanShowK9UI(true)
    f.commands['k9leash']()
    t.equals(calls.detach, 0)
    t.equals(#calls.attach, 1)
    t.equals(calls.attach[1], 7)
end)

t.test('/k9leash with nobody nearby says so, and sends nothing', function()
    local f, calls = leashCommandFixture(false, nil)
    f.setCanShowK9UI(true)
    f.commands['k9leash']()
    t.equals(#calls.attach, 0)
    local n = f.notifyCalls[#f.notifyCalls]
    t.isNotNil(n)
    t.equals(n.description, locale('radial.no_leash_candidate'))
    t.equals(n.type, 'error')
end)

t.test('/k9leash from a player without K9 access is refused before looking for anyone', function()
    local f, calls = leashCommandFixture(false, 7)
    f.setCanShowK9UI(false)
    f.commands['k9leash']()
    t.equals(f.denyCallCount(), 1)
    t.equals(#calls.attach, 0)
end)

t.test('RequestLeashAttach: K9-role initiator (IsOwnModelK9 true) BLOCKED locally when CanShowK9UI is false -- denied before ever reaching the server', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(false)
    f.env.RequestLeashAttach(999)
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestLeashAttach: K9-role initiator (IsOwnModelK9 true) with CanShowK9UI true reaches the server', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(true)
    f.env.RequestLeashAttach(42)
    t.equals(f.denyCallCount(), 0)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestLeashAttach')
    t.equals(f.lastServerEvent().args[1], 42)
end)

t.test('RequestLeashAttach: THE REGRESSION FIX -- an officer-role initiator (IsOwnModelK9 false) reaches the server even though CanShowK9UI is also false, and CanShowK9UI is never even consulted (short-circuit)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(false) -- would have wrongly blocked under the pre-fix unconditional gate
    f.env.RequestLeashAttach(7)
    t.equals(#f.serverEvents, 1, 'an officer-initiated Attach Leash request must reach the server -- this is the exact regression this session fixed')
    t.equals(f.lastServerEvent().args[1], 7)
    t.equals(f.denyCallCount(), 0)
    t.equals(f.canShowK9UICallCount(), 0, 'Lua\'s `and` short-circuits: IsOwnModelK9() being false means CanShowK9UI() must never even run for this branch')
end)

t.test('RequestLeashAttach: an officer-role initiator with CanShowK9UI true (sanity) also reaches the server', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(true)
    f.env.RequestLeashAttach(8)
    t.equals(#f.serverEvents, 1)
end)

t.test('RequestLeashAttach: already leashed blocks a FRESH request from the K9-role side, with no server contact', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 55, true) -- establish leashState first
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(true)
    f.env.RequestLeashAttach(999)
    t.equals(#f.serverEvents, 0, 'no NEW requestLeashAttach event -- IsLeashed() must block before ever calling TriggerServerEvent')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('movement.already_leashed'))
    t.equals(f.notifyCalls[#f.notifyCalls].type, 'error')
end)

t.test('RequestLeashAttach: already leashed ALSO blocks the officer-role side -- the IsLeashed() check runs unconditionally, regardless of which gate branch preceded it', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 55, false) -- officer/anchor side's own leashState, isConstrained=false
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(false)
    f.env.RequestLeashAttach(999)
    t.equals(#f.serverEvents, 0)
end)

-- ========================================================================
-- Supporting infrastructure for IsLeashed()/the leash handshake -- lightly
-- covered ONLY to the extent the priority tests above and the
-- onResourceStop tests below depend on real state transitions, not a full
-- D3-style source-origin-guard treatment (that treatment lives in
-- clientcombat_spec.lua, which this file's own guards share the identical
-- open-question caveat with -- see this file's own "WHAT THIS FILE DOES
-- NOT COVER" note on that).
-- ========================================================================

t.test('leashAttached: source == 65535 sets leashState (IsLeashed() true) and notifies with type "success"', function()
    local f = newMovementFixture()
    t.isFalse(f.env.IsLeashed())
    f.triggerLeashAttached(65535, 10, true)
    t.isTrue(f.env.IsLeashed())
    local n = f.notifyCalls[#f.notifyCalls]
    t.equals(n.description, locale('movement.leash_now_leashed'))
    t.equals(n.type, 'success')
end)

t.test('leashAttached: isConstrained false notifies with the anchor-side message instead', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, false)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('movement.leash_now_anchoring'))
end)

t.test('leashAttached: a forged non-65535 source is rejected -- leashState stays nil, no notify', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(1, 10, true)
    t.isFalse(f.env.IsLeashed())
    t.equals(#f.notifyCalls, 0)
end)

t.test('leashDetached: source == 65535 clears leashState and notifies with type "info", default reason', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.triggerLeashDetached(65535, 'detached')
    t.isFalse(f.env.IsLeashed())
    local n = f.notifyCalls[#f.notifyCalls]
    t.equals(n.description, locale('movement.leash_detached'))
    t.equals(n.type, 'info')
end)

t.test('leashDetached: reason == "partner_disconnected" uses the distinct partner-disconnected message', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.triggerLeashDetached(65535, 'partner_disconnected')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('movement.leash_detached_partner_disconnected'))
end)

t.test('leashDetached: a forged non-65535 source is rejected -- leashState survives untouched', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.triggerLeashDetached(7, 'detached')
    t.isTrue(f.env.IsLeashed(), 'a forged local trigger must never be able to silence the elastic-restriction thread by clearing leashState')
end)

t.test('DetachLeash: a no-op (no TriggerServerEvent) when not currently leashed', function()
    local f = newMovementFixture()
    f.env.DetachLeash()
    t.equals(#f.serverEvents, 0)
end)

t.test('DetachLeash: sends the real detachLeash event when leashed, with zero consent/access gate', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.setCanShowK9UI(false) -- must not matter -- detach has no access gate
    f.env.DetachLeash()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:detachLeash')
end)

t.test('leashAttachRequest (consent prompt, target side): source == 65535 shows the prompt and relays the response to the server', function()
    local f = newMovementFixture()
    f.registerPlayer(10, 3)
    f.setAlertDialogResponse('confirm')
    f.triggerLeashAttachRequest(65535, 10)
    t.equals(#f.alertDialogCalls, 1)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:respondLeashAttach')
    t.equals(f.lastServerEvent().args[1], 10)
    t.equals(f.lastServerEvent().args[2], true)
end)

t.test('leashAttachRequest: a decline response relays accepted=false', function()
    local f = newMovementFixture()
    f.registerPlayer(10, 3)
    f.setAlertDialogResponse('cancel')
    f.triggerLeashAttachRequest(65535, 10)
    t.equals(f.lastServerEvent().args[2], false)
end)

t.test('leashAttachRequest: a forged non-65535 source never even shows the prompt', function()
    local f = newMovementFixture()
    f.triggerLeashAttachRequest(1, 10)
    t.equals(#f.alertDialogCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

-- ========================================================================
-- PRIORITY #2 -- the THREE onResourceStop handlers. Distinct, no overlap:
-- each is proven to fire independently, to be a no-op when its own
-- condition doesn't hold, and all three are proven to coexist correctly
-- (no interference) when fired together in the same resourceName check.
-- ========================================================================

t.test('onResourceStop CAMERA handler: a no-op when the camera was never toggled to first-person', function()
    local f = newMovementFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.camViewModeCalls, 0)
end)

t.test('onResourceStop CAMERA handler: resets the view mode to 1 (third-person) and truly clears its own flag -- a later ToggleK9Camera() flips to first-person again, proving the internal boolean was really reset, not just visually', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.ToggleK9Camera() -- flips to first-person (mode 4)
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 4)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 1, 'the stop handler must reset the view mode to third-person')

    f.env.ToggleK9Camera()
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 4, 'toggling again must go back to first-person -- proves isFirstPersonK9View was genuinely reset to false, not left stale')
end)

t.test('onResourceStop CAMERA handler: a mismatched resourceName never fires, even mid-first-person', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.ToggleK9Camera()
    local callsBefore = #f.camViewModeCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.camViewModeCalls, callsBefore)
end)

t.test('onResourceStop LEASH handler: a no-op (no detachLeash event) when not currently leashed', function()
    local f = newMovementFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.serverEvents, 0)
end)

t.test('onResourceStop LEASH handler: sends detachLeash when leashed, but leashState only clears once the (simulated) server confirmation arrives -- proves this handler fires DetachLeash(), not a direct local clear', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:detachLeash')
    t.isTrue(f.env.IsLeashed(), 'DetachLeash() only SENDS the request -- leashState clears only when leashDetached actually arrives, exactly like a normal manual detach')
end)

t.test('onResourceStop LEASH handler: a mismatched resourceName never fires, even while leashed', function()
    local f = newMovementFixture()
    f.triggerLeashAttached(65535, 10, true)
    f.fireResourceStop('some_other_resource')
    t.equals(#f.serverEvents, 0)
end)

t.test('onResourceStop MOVE-RATE handler: a no-op (no SetPedMoveRateOverride call) when the composer never applied a non-neutral value', function()
    local f = newMovementFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('onResourceStop MOVE-RATE handler: resets a non-neutral applied rate to 1.0, and is idempotent on a second firing', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.5)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 2)
    t.equals(f.setMoveRateCalls[2].rate, 1.0)

    f.fireResourceStop(RESOURCE_NAME) -- fired twice -- must not double-reset
    t.equals(#f.setMoveRateCalls, 2, 'a second firing must be a no-op once the tracked rate is already neutral')
end)

t.test('onResourceStop MOVE-RATE handler: a mismatched resourceName never fires, even with a non-neutral rate applied', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.injury = 0.6
    f.env.RecomputeK9MoveRate()
    local callsBefore = #f.setMoveRateCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.setMoveRateCalls, callsBefore)
end)

t.test('onResourceStop MOVE-RATE handler: skips the native call (no valid ped) but STILL resets its own internal tracking -- a disclosed, low-severity finding, not a fix: a later resourceStop with a valid ped never re-attempts the reset either', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 1)

    f.setPedMissing() -- PlayerPedId() now returns 0 -- native call must be skipped
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 1, 'the native call is correctly skipped for an invalid ped')

    f.setPed(1, true) -- ped becomes valid again
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.setMoveRateCalls, 1, 'FINDING (harmless in practice, see comment above): the internal lastAppliedMoveRate was already reset to 1.0 during the invalid-ped firing, so this second, now-valid-ped firing never actually re-corrects the native state that was skipped the first time -- low real-world impact since onResourceStop only ever runs once at genuine resource teardown')
end)

t.test('onResourceStop: all THREE handlers fire independently in the same pass with zero interference (camera + leash + move-rate all active at once)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.ToggleK9Camera() -- first-person
    f.triggerLeashAttached(65535, 10, true) -- leashed
    f.env.K9MoveRateModifiers.mood = 0.8
    f.env.RecomputeK9MoveRate() -- non-neutral rate applied

    local camBefore, moveBefore, serverBefore = #f.camViewModeCalls, #f.setMoveRateCalls, #f.serverEvents
    f.fireResourceStop(RESOURCE_NAME)

    t.equals(#f.camViewModeCalls, camBefore + 1)
    t.equals(f.camViewModeCalls[#f.camViewModeCalls], 1)
    t.equals(#f.setMoveRateCalls, moveBefore + 1)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
    t.equals(#f.serverEvents, serverBefore + 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:detachLeash')
end)

-- ========================================================================
-- PRIORITY #3 -- RecomputeK9MoveRate(): degenerate-ped guards, the
-- not-a-K9 reset branch, multiplicative composition, the [0.1, 2.0] clamp,
-- and the defensive non-number guard.
-- ========================================================================

t.test('RecomputeK9MoveRate: no valid ped (PlayerPedId returns 0) is a clean no-op', function()
    local f = newMovementFixture()
    f.setPedMissing()
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('RecomputeK9MoveRate: a ped handle that DoesEntityExist reports false for is also a clean no-op', function()
    local f = newMovementFixture()
    f.setPed(2, false)
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('RecomputeK9MoveRate: not IsOwnModelK9, never applied before -- no-op (already neutral)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('RecomputeK9MoveRate: not IsOwnModelK9, but a non-neutral rate WAS previously applied -- resets to 1.0 (prevents a stale override surviving a K9-to-human model swap on the same ped index)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.injury = 0.7
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.7)

    f.setIsOwnModelK9(false)
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
    t.equals(#f.setMoveRateCalls, 2)
end)

t.test('RecomputeK9MoveRate: IsOwnModelK9 true, every modifier at its default 1.0 -- applies exactly 1.0', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 1)
    t.equals(f.setMoveRateCalls[1].rate, 1.0)
end)

t.test('RecomputeK9MoveRate: IsOwnModelK9 true ALWAYS re-applies, even with no change -- unlike the not-a-K9 branch, this is never deduped', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.RecomputeK9MoveRate()
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 2, 'the K9 branch is a deliberate no-early-return composer, not a change-detection cache')
end)

t.test('RecomputeK9MoveRate: composes two non-default modifiers multiplicatively (0.5 * 0.4 = 0.2)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.5
    f.env.K9MoveRateModifiers.mood = 0.4
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.2)
end)

t.test('RecomputeK9MoveRate: clamps a product below 0.1 up to the floor', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.01
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.1)
end)

t.test('RecomputeK9MoveRate: AUTOMATIC (no individual override signaled) clamps a product above 2.0 down to the tight defensive ceiling -- UNCHANGED by GAP 1 PART 2, this is the control every override-specific test below is measured against', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.xpTier = 5.0
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0)
end)

-- ========================================================================
-- GAP 1, PART 2 -- "EXPLICIT INDIVIDUAL OVERRIDE VS. AUTOMATIC MULTIPLIER".
-- RED-THEN-GREEN, WITH A CONTROL: the test immediately above IS the
-- control (same 5.0 xpTier value, same fixture, override NOT signaled --
-- still clamps to 2.0, proving this fix did not just raise the ceiling for
-- everyone). The tests below flip ONLY the new signal
-- (K9IndividualSpeedOverrideActive, via the new
-- 'john-k9:client:k9SpeedOverrideStatus' handler) and prove the SAME
-- 5.0 value now genuinely reaches SetPedMoveRateOverride, up to the real
-- engine ceiling (10.0) -- never beyond it, and never bypassing the floor.
-- ========================================================================

t.test('RecomputeK9MoveRate: an ACTIVE individual speed override lets the SAME composed value that the control above clamped to 2.0 genuinely reach SetPedMoveRateOverride uncapped by the tight ceiling', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.triggerSpeedOverrideStatus(65535, { active = true })
    f.env.K9MoveRateModifiers.xpTier = 5.0
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 5.0, 'THE FIX: this used to be 2.0 -- an audited individual override must not be silently rendered down to the automatic-multiplier defensive ceiling')
end)

t.test('RecomputeK9MoveRate: an ACTIVE override still respects the REAL engine ceiling (10.0) -- an extreme/bogus value is clamped there, never passed through raw', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.triggerSpeedOverrideStatus(65535, { active = true })
    f.env.K9MoveRateModifiers.xpTier = 50.0
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 10.0, 'even an override-active composition must never exceed SET_PED_MOVE_RATE_OVERRIDE\'s own documented real maximum')
end)

t.test('RecomputeK9MoveRate: an ACTIVE override does NOT bypass the floor -- Rule "the floor stays meaningful" holds regardless of override status', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.triggerSpeedOverrideStatus(65535, { active = true })
    f.env.K9MoveRateModifiers.xpTier = 0.01
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.1, 'a frozen player is a trapped player -- the floor is never bent, override or not')
end)

t.test('john-k9:client:k9SpeedOverrideStatus: source == 65535 sets the flag AND immediately re-applies via RecomputeK9MoveRate(), with no other trigger involved', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.xpTier = 5.0
    -- Established at 2.0 first (override not yet active) -- proves the
    -- event handler itself is what re-applies, not merely a value already
    -- sitting there from some earlier call.
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0)

    f.triggerSpeedOverrideStatus(65535, { active = true })
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 5.0, 'receiving the event alone, with no separate RecomputeK9MoveRate() call from the test, must re-apply the wider ceiling immediately')
end)

t.test('john-k9:client:k9SpeedOverrideStatus: {active = false} (a reset) snaps the ceiling back down to 2.0 immediately, even with no change to the underlying number', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.xpTier = 5.0
    f.triggerSpeedOverrideStatus(65535, { active = true })
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 5.0)

    f.triggerSpeedOverrideStatus(65535, { active = false })
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0, 'once server/k9profiles.lua reports the override is gone, this client must go back to treating the SAME number as automatic')
end)

t.test('john-k9:client:k9SpeedOverrideStatus: SOURCE-ORIGIN GUARD -- a forged local event (source ~= 65535) is ignored outright, the flag never changes', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.xpTier = 5.0
    f.env.RecomputeK9MoveRate() -- establishes the 2.0-clamped baseline
    local callsBefore = #f.setMoveRateCalls

    f.triggerSpeedOverrideStatus(1234, { active = true })

    t.equals(#f.setMoveRateCalls, callsBefore, 'a forged event must not even trigger a re-apply, let alone widen the ceiling')
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0, 'a REAL subsequent recompute proves the flag itself was never set by the forged event')
end)

t.test('john-k9:client:k9SpeedOverrideStatus: a malformed payload (missing/non-boolean active, or not a table at all) degrades to false -- the tighter, safer default -- never errors', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.xpTier = 5.0
    f.triggerSpeedOverrideStatus(65535, { active = true })
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 5.0, 'sanity: override genuinely active before the malformed payload below arrives')

    local ok = pcall(f.triggerSpeedOverrideStatus, 65535, {})
    t.isTrue(ok, 'a table with no `active` key at all must never error')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0, 'missing `active` must be treated as false, not as "leave the previous value alone"')

    f.triggerSpeedOverrideStatus(65535, { active = true }) -- re-arm
    local ok2 = pcall(f.triggerSpeedOverrideStatus, 65535, 'not a table')
    t.isTrue(ok2, 'a non-table payload must never error')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0, 'a non-table payload must also degrade to false')
end)

t.test('RecomputeK9MoveRate: a non-number entry in K9MoveRateModifiers is ignored defensively, never errors, never contributes to the product', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.somethingBogus = 'oops'
    local ok, err = pcall(f.env.RecomputeK9MoveRate)
    t.isTrue(ok, 'a non-number modifier entry must never error: ' .. tostring(err))
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
end)

t.test('RecomputeK9MoveRate: applies to the CURRENT PlayerPedId(), not a hardcoded handle', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.setPed(777, true)
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].ped, 777)
end)

-- ========================================================================
-- ANY-PED MOVE-RATE FIX (this pass) -- RecomputeK9MoveRate()'s gate is now
-- `IsOwnModelK9() or HasK9Access()`, not IsOwnModelK9() alone. Two
-- independent agents separately found the same real bug: a role-holder
-- (certified handler, or a HasK9Access() High-Command/autoAccessGrade
-- bypass) on a non-K9 body got a genuine server grant -- client/pursuitsprint.lua's
-- "activated" toast, a real K9MoveRateModifiers write -- and ZERO actual
-- speed change, because the bare IsOwnModelK9() gate reset the composer back
-- to neutral before it ever composed anything. See the real production
-- file's own "SCOPE, CORRECTED" header comment on K9MoveRateModifiers for
-- the full writeup (the two concrete configurations this reproduces in:
-- Config.K9Appearance.requireK9ModelForRole = true, and the default-config
-- HasK9Access() autoAccessGrade/High-Command-bypass case) -- not re-derived
-- here, only proven behaviorally against the real function.
-- ========================================================================

t.test('ANY-PED FIX: NOT IsOwnModelK9, but HasK9Access() true -- the composer now applies for real, proving a role-holder on a non-K9 body genuinely receives the speed change', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.env.K9MoveRateModifiers.fatigue = 0.85
    f.env.RecomputeK9MoveRate()
    t.equals(#f.setMoveRateCalls, 1, 'THE BUG: this used to be 0 -- IsOwnModelK9() alone reset to neutral and returned before composing anything')
    t.equals(f.setMoveRateCalls[1].rate, 0.85, 'the real fatigue modifier must reach SetPedMoveRateOverride on a human/custom body exactly as it would on a K9 model')
end)

t.test('ANY-PED FIX: neither IsOwnModelK9 NOR HasK9Access -- still a full reset, exactly like before this fix (a player with no model AND no access has no legitimate reason for any modifier to apply)', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.injury = 0.6
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.6)

    f.setIsOwnModelK9(false)
    f.setHasK9Access(false)
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'neither half of the OR is true -- must still reset to neutral, not stay stuck at 0.6')
end)

t.test('ANY-PED FIX: HasK9Access() is NEVER consulted when IsOwnModelK9() is already true -- `or` short-circuits, so the already-K9-modeled common case pays no extra network round trip', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(true)
    f.env.RecomputeK9MoveRate()
    t.equals(f.hasK9AccessCallCount(), 0, 'Lua\'s `or` short-circuits: IsOwnModelK9() being true means HasK9Access() must never even run')
    t.equals(#f.setMoveRateCalls, 1, 'the K9-modeled case must still apply normally')
end)

t.test('ANY-PED FIX: HasK9Access() true alone (never a K9 model at all, e.g. an unlisted human ped) applies breed at its neutral 1.0 default -- breed itself was never meaningful off-model, only the OTHER modifiers (fatigue/injury/mood/xpTier/pursuitSprint) are what this fix actually restores', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.setModel(1, 12345) -- pedHandle 1 (this fixture's default) -- some hash never present in any breed table
    f.env.RecomputeK9MoveRate()
    t.equals(f.env.K9MoveRateModifiers.breed, 1.0, 'breed must stay neutral for a model with no configured breed multiplier, exactly as it already did before this fix')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'with every modifier at its neutral default, the composed rate is exactly 1.0 -- still a REAL native call, not a skipped one, unlike the old bare-IsOwnModelK9() gate which would have skipped this entirely')
end)

t.test('ANY-PED FIX: switching FROM a legitimate access-only (non-K9-model) state back to neither resets to neutral, same stale-override protection the original K9-to-human comment already documented', function()
    local f = newMovementFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.env.K9MoveRateModifiers.mood = 0.9
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.9)

    f.setHasK9Access(false) -- access revoked mid-session, still not K9-modeled
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'losing the ONLY qualifying condition (access, since model was already false) must still reset to neutral')
end)

-- ========================================================================
-- PRIORITY #4 -- the AgilityBasicJump=false suppression thread, ADDED THIS
-- PASS to close a real, previously-disclosed gap (see the former version of
-- "WHAT THIS FILE DOES NOT COVER" below, and the "close the any-ped
-- speed-system gap" task this session): the ANY-PED FIX above widens
-- RecomputeK9MoveRate()'s gate to `IsOwnModelK9() or HasK9Access()` because a
-- move-rate EFFECT is something a ROLE grants -- but this thread answers a
-- DIFFERENT question ("does this ped's own SKELETON have a jump/crouch
-- animation to suppress"), stays keyed on `IsEntityModelK9(PlayerPedId())`
-- alone (a pure body/model check, never IsOwnModelK9()), and is the owner's
-- own explicit, dated decision (see client/movement.lua's own "OWNER'S
-- DECISION, 2026-08-25: MODEL, not role" comment on this exact thread) that
-- a role-holder on a human body keeps jump and crouch. Nothing anywhere in
-- this suite previously exercised this thread's body at all -- these are the
-- first tests that do.
-- ========================================================================

t.test('AgilityBasicJump=false, real K9-modeled ped: the suppression thread disables INPUT_JUMP (22) and INPUT_DUCK (36) every step, at Wait(0)', function()
    local f = newMovementFixture({ agilityBasicJump = false, stepThreads = true })
    f.setEntityModelK9(1, true) -- pedHandle 1, this fixture's default PlayerPedId()

    f.step() -- one full loop-body pass (Wait sits at the END of this thread's convention, see the fixture's own "step" doc comment)

    t.equals(#f.disableControlActionCalls, 2, 'both controls must be disabled every pass while suppression is active')
    t.equals(f.disableControlActionCalls[1].inputGroup, 0)
    t.equals(f.disableControlActionCalls[1].control, 22, 'INPUT_JUMP')
    t.equals(f.disableControlActionCalls[1].disable, true)
    t.equals(f.disableControlActionCalls[2].control, 36, 'INPUT_DUCK')
    t.equals(f.disableControlActionCalls[2].disable, true)

    f.step() -- a second pass must re-disable both controls again -- DisableControlAction's own contract requires re-assertion every frame, it does not persist on its own
    t.equals(#f.disableControlActionCalls, 4, 'must re-assert every single pass (Wait(0) => every frame), never assume one call is sufficient')
end)

t.test('OWNER\'S DECISION PINNED: AgilityBasicJump=false, role-holder on a HUMAN body (IsOwnModelK9 true via role, IsEntityModelK9(PlayerPedId()) false) -- jump/crouch are NEVER suppressed, proving this thread reads the body, not the role', function()
    local f = newMovementFixture({ agilityBasicJump = false, stepThreads = true })
    f.setIsOwnModelK9(true) -- the role-widened, "any-ped" answer -- deliberately NOT what this thread's own gate reads
    -- f.setEntityModelK9(1, ...) deliberately left unset -- pedHandle 1's
    -- real body stays human (entityModelK9[1] defaults falsy), exactly the
    -- "certified handler, human body" case the owner's decision protects.

    f.step()
    f.step() -- two passes, same as the positive test above, to prove this isn't a one-shot fluke

    t.equals(#f.disableControlActionCalls, 0, 'a role-holder on a human body must keep jump and crouch -- IsOwnModelK9() being true must NOT be enough to trigger suppression')
end)

t.test('AgilityBasicJump=false, plain human ped (neither role nor K9 model): also never suppressed -- the ordinary, non-K9 case must be inert exactly as it always was', function()
    local f = newMovementFixture({ agilityBasicJump = false, stepThreads = true })
    -- Every knob at its fixture default: isOwnModelK9 defaults true in this
    -- file's own fixture (see newMovementFixture()'s very first local) --
    -- flip it to false here so this test genuinely represents "not a K9 by
    -- any measure", not an accidental duplicate of the role-holder case
    -- above.
    f.setIsOwnModelK9(false)

    f.step()

    t.equals(#f.disableControlActionCalls, 0)
end)

t.test('AgilityBasicJump=false, real K9-modeled ped losing its model mid-session (e.g. a K9-to-human PedModel swap): suppression stops on the VERY NEXT pass, no separate cleanup path needed', function()
    local f = newMovementFixture({ agilityBasicJump = false, stepThreads = true })
    f.setEntityModelK9(1, true)
    f.step()
    t.equals(#f.disableControlActionCalls, 2, 'suppressed while still K9-modeled')

    f.setEntityModelK9(1, false) -- model swap -- no longer a K9 body
    f.step()
    t.equals(#f.disableControlActionCalls, 2, 'no NEW DisableControlAction calls once the body is no longer K9-modeled -- this thread re-reads IsEntityModelK9(PlayerPedId()) fresh every single pass, so there is nothing left to "clean up": the very next pass already stops calling DisableControlAction at all, which is itself the full removal path for this thread (unlike SetPedMoveRateOverride, DisableControlAction applies for exactly the one frame it is called on and does nothing further once simply not re-asserted)')
end)

t.test('AgilityBasicJump=true (this fixture\'s existing default): the suppression thread never registers at all, so DisableControlAction can never fire regardless of model -- confirms PRIORITY #4\'s tests above are exercising a thread that genuinely does not exist in the shipped default', function()
    local f = newMovementFixture({ stepThreads = true }) -- agilityBasicJump omitted -> defaults true
    f.setEntityModelK9(1, true)

    f.step() -- steps whatever DID get created (the leash pull-back thread and the move-rate watchdog -- see PRIORITY #5 -- neither touches DisableControlAction)

    t.equals(f.threadCount(), 2, 'leash pull-back + move-rate watchdog -- see the earlier, pre-existing "creates exactly 2 threads" sanity test; no suppression thread')
    t.equals(#f.disableControlActionCalls, 0)
end)

-- ========================================================================
-- PRIORITY #6 -- the AgilityBasicJump PER-PERSON BLOCK
-- (client/featureblocks.lua hand-off item 2), added THIS pass. See this
-- file's own header item 6 for the full list of what these tests prove.
-- The onResourceStop side of "guaranteed release" is deliberately NOT a
-- new test here -- it is the EXISTING "registers exactly 3 onResourceStop
-- handlers" sanity test near the top of this file, unchanged and still
-- passing: this feature adds no 4th handler at all, because
-- DisableControlAction needs no explicit reset (see client/movement.lua's
-- own comment on this, immediately above EnsureAgilityJumpSuppressionThread).
-- ========================================================================

t.test('the john-k9:client:featureBlocksApplied listener is registered exactly once', function()
    local f = newMovementFixture()
    t.equals(f.featureBlocksAppliedHandlerCount(), 1)
end)

t.test('STEADY STATE (the interval decision\'s own central claim): AgilityBasicJump=true, never blocked -- creates NO suppression thread at all, not even an idle poll -- threadCount stays at 2 across multiple ticks/events with nothing to react to', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setEntityModelK9(1, true)
    f.step()
    f.step()
    f.fireFeatureBlocksApplied() -- a real sync arrived, but changed nothing (blockedFeatures stays empty)
    f.step()

    t.equals(f.threadCount(), 2, 'leash pull-back + move-rate watchdog only -- zero cost paid for a feature nobody has ever blocked, not even a cheap poll')
    t.equals(#f.disableControlActionCalls, 0)
end)

t.test('A BLOCK ARRIVING MID-SESSION TAKES EFFECT: AgilityBasicJump=true (no thread exists yet) -- firing featureBlocksApplied with AgilityBasicJump blocked CREATES the suppression thread on the spot, and it suppresses on the very next step, same tick the sync would have arrived on', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setEntityModelK9(1, true)
    t.equals(f.threadCount(), 2, 'sanity: no suppression thread yet')

    f.setBlocked('AgilityBasicJump', true)
    f.fireFeatureBlocksApplied()

    t.equals(f.threadCount(), 3, 'the block event itself must be what creates the thread -- not a poll that happens to notice it later')

    f.step()
    t.equals(#f.disableControlActionCalls, 2, 'INPUT_JUMP + INPUT_DUCK, exactly like the global-off case')
end)

t.test('A BLOCK CLEARING MID-SESSION RELEASES: once cleared, the suppression thread stops calling DisableControlAction on its very next pass -- no separate teardown path needed, mirroring the model-loss test above', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setEntityModelK9(1, true)
    f.setBlocked('AgilityBasicJump', true)
    f.fireFeatureBlocksApplied()
    f.step()
    t.equals(#f.disableControlActionCalls, 2, 'suppressed while blocked')

    f.setBlocked('AgilityBasicJump', false)
    f.fireFeatureBlocksApplied()
    f.step()
    t.equals(#f.disableControlActionCalls, 2, 'no NEW DisableControlAction calls once unblocked -- the loop\'s own while-condition re-reads the (now false) block on this very next pass and exits')

    -- The now-dead thread must not have left the feature permanently
    -- suppressed OR permanently un-suppressible -- a FRESH block later must
    -- still work (proves EnsureAgilityJumpSuppressionThread() can start a
    -- brand new thread once the old one has genuinely ended, not just once
    -- ever).
    f.setBlocked('AgilityBasicJump', true)
    f.fireFeatureBlocksApplied()
    t.equals(f.threadCount(), 4, 'a fresh thread, since the previous one already exited its while loop and cleared agilityJumpSuppressionThreadRunning')
    f.step()
    t.equals(#f.disableControlActionCalls, 4)
end)

t.test('OWNER\'S DECISION STILL HOLDS VIA THE BLOCK PATH: a role-holder on a HUMAN body (IsOwnModelK9 true via role, IsEntityModelK9(PlayerPedId()) false) is NEVER suppressed even while AgilityBasicJump is blocked for them -- same exemption as PRIORITY #4, proven again for the NEW trigger mechanism', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setIsOwnModelK9(true) -- role-widened answer; deliberately NOT what this thread's own gate reads
    -- entityModelK9(1) left unset -- real body stays human
    f.setBlocked('AgilityBasicJump', true)
    f.fireFeatureBlocksApplied()

    t.equals(f.threadCount(), 3, 'the thread still gets created -- the exemption is inside the loop body (per-frame), not a reason to skip creating the loop at all')

    f.step()
    f.step()
    t.equals(#f.disableControlActionCalls, 0, 'a role-holder on a human body must keep jump and crouch regardless of which of the two reasons is driving suppression')
end)

t.test('DUPLICATE-THREAD GUARD: AgilityBasicJump=false (a thread already exists from load) -- a block ALSO arriving for the same feature must not start a second copy', function()
    local f = newMovementFixture({ agilityBasicJump = false, stepThreads = true })
    t.equals(f.threadCount(), 3, 'sanity: the global-off suppression thread already exists (leash + watchdog + suppression)')

    f.setBlocked('AgilityBasicJump', true)
    f.fireFeatureBlocksApplied()

    t.equals(f.threadCount(), 3, 'EnsureAgilityJumpSuppressionThread() must be a no-op while agilityJumpSuppressionThreadRunning is already true')
end)

t.test('FAILS OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- firing featureBlocksApplied is a harmless no-op, never an error, and never starts suppression', function()
    local f = newMovementFixture({ featureBlocksAvailable = false, stepThreads = true })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.setEntityModelK9(1, true)

    f.fireFeatureBlocksApplied() -- must not error despite IsK9FeatureBlocked being absent

    t.equals(f.threadCount(), 2, 'no suppression thread -- fails OPEN (unblockable), exactly as this feature behaved before this pass')
    f.step()
    t.equals(#f.disableControlActionCalls, 0)
end)

-- ========================================================================
-- PRIORITY #5 -- the always-on move-rate watchdog, ADDED THIS PASS to close
-- a real, verified "unbounded trap": the ANY-PED FIX above (PRIORITY #3)
-- lets an OFF-MODEL role-holder carry a genuine non-1.0 move-rate override
-- (fatigue/injury/mood/xpTier/pursuitSprint) for the first time -- but every
-- caller that would ever recompute it again is itself gated behind a
-- SERVER-PUSHED event (wellbeingUpdate/xpTierChanged/pursuitSprint's own
-- start-tick-end calls), and server/wellbeing.lua's TickWellbeing skips its
-- entire per-player body -- broadcast included -- the instant a player's
-- role/access is lost (confirmed by reading server/wellbeing.lua's
-- ResolveK9Ped and its one call site in TickWellbeing). Certification
-- revocation (server/certifications/) sends only a plain notify, nothing
-- this file or any of its callers listens for. Before the ANY-PED fix this
-- was harmless (an off-model player's OLD gate, `not IsOwnModelK9()` alone,
-- was always true for them); after it, losing role/access while staying
-- online and off-model would otherwise leave whatever rate was last applied
-- in place FOREVER (until a full relog or a resource restart) -- exactly
-- the case this task's own rules forbid, and worse than pre-fix behavior
-- for exactly the population the fix was meant to help. See the watchdog's
-- own header comment in client/movement.lua for the full writeup this
-- section proves against the REAL function.
-- ========================================================================

t.test('WATCHDOG IDLE: while lastAppliedMoveRate has never left neutral, stepping the watchdog does NOT call HasK9Access() at all -- proves the common case (a player who has never triggered any move-rate effect) never pays the underlying network round trip, even though this thread runs unconditionally for every player', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setIsOwnModelK9(false) -- if the watchdog read this gate unconditionally every poll, this would force a HasK9Access() call

    f.step()
    f.step()

    t.equals(f.hasK9AccessCallCount(), 0, 'the watchdog must check its own cheap local lastAppliedMoveRate FIRST, before ever reaching IsOwnModelK9()/HasK9Access()')
    t.equals(#f.setMoveRateCalls, 0, 'no native call at all while there is genuinely nothing to watch')
end)

t.test('WATCHDOG ACTIVE: once a real non-1.0 rate is applied, stepping the watchdog re-invokes RecomputeK9MoveRate() for real -- a second, independent SetPedMoveRateOverride call with no other trigger involved', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setIsOwnModelK9(true)
    f.env.K9MoveRateModifiers.fatigue = 0.85
    f.env.RecomputeK9MoveRate() -- the ordinary caller path (mirrors client/wellbeing.lua) -- establishes the non-neutral baseline the watchdog must then notice
    t.equals(#f.setMoveRateCalls, 1)

    f.step() -- the watchdog thread alone, no direct RecomputeK9MoveRate() call this time

    t.equals(#f.setMoveRateCalls, 2, 'the watchdog must have made its OWN, independent SetPedMoveRateOverride call')
    t.equals(f.setMoveRateCalls[2].rate, 0.85, 'still the same real, current fatigue modifier -- the watchdog recomputes from live state, not a cached snapshot')
end)

t.test('WATCHDOG CLOSES THE GAP: OWNER-VERIFIED SCENARIO -- an off-model role-holder (IsOwnModelK9 false, HasK9Access true) carrying a real fatigue penalty has their role/access revoked WHILE NOTHING ELSE EVER CALLS RecomputeK9MoveRate() AGAIN -- the watchdog alone converges them back to neutral within one poll', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true) -- e.g. a certified handler on a human body, per the ANY-PED fix
    f.env.K9MoveRateModifiers.fatigue = 0.85
    f.env.RecomputeK9MoveRate()
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 0.85, 'sanity: the real effect is genuinely applied off-model, exactly as PRIORITY #3\'s ANY-PED FIX tests already prove')

    -- THE REVOCATION: role/access lost. Simulates server/certifications/'s
    -- RevokeCertification -- no event fires client-side that this file (or
    -- client/wellbeing.lua/client/progression.lua) listens for; the ONLY
    -- thing that changes is what HasK9Access() will now answer the next
    -- time anything asks it.
    f.setHasK9Access(false)

    -- No direct f.env.RecomputeK9MoveRate() call here on purpose -- proving
    -- the watchdog itself is what notices, not a test artifact calling the
    -- real fix function again by hand.
    f.step()

    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'THE FIX: without the watchdog this would still read 0.85 forever -- the watchdog\'s own periodic re-check is what forces the reset once neither IsOwnModelK9() nor HasK9Access() holds any longer')
end)

t.test('WATCHDOG SELF-QUIETS: once its own reset has run, a SECOND step makes no further native calls -- the idle branch takes back over instead of re-asserting 1.0 forever', function()
    local f = newMovementFixture({ stepThreads = true })
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.env.K9MoveRateModifiers.mood = 0.9
    f.env.RecomputeK9MoveRate()

    f.setHasK9Access(false)
    f.step()
    t.equals(#f.setMoveRateCalls, 2, 'first watchdog pass: the reset call')

    f.step()
    t.equals(#f.setMoveRateCalls, 2, 'second watchdog pass: already neutral (lastAppliedMoveRate == 1.0) -- the idle branch takes over, exactly like the "WATCHDOG IDLE" test above, no further calls')
end)

-- ========================================================================
-- PRIORITY #7 -- THE ELASTIC LEASH PULL-BACK THREAD's IsRestingInKennel()
-- EXCLUSION (leash-in-kennel fix, this pass). This file's own header used
-- to disclose the pull-back thread's BODY as "the single largest disclosed
-- gap in this spec" (captured but never stepped) -- CLOSED, partially, this
-- pass: real Vec3 + GetEntityCoords/SetEntityCoords/IsPedInAnyVehicle/
-- GetPlayerPed machinery was added to this file's own fixture (see the
-- top-of-file Vec3MT stub and newMovementFixture()'s own "LEASH PULL-BACK
-- THREAD MACHINERY" section) specifically to prove the new
-- IsRestingInKennel() exclusion actually works, using the SAME
-- `stepThreads = true` + `f.step()` convention PRIORITY #4/#5 above
-- already established (one `f.step()` call = one full loop-body pass,
-- since -- like the suppression/watchdog threads above -- this thread's
-- own `Wait(sleepMs)` sits at the END of its while-loop body, not the
-- start). See "WHAT THIS FILE STILL DOES NOT COVER" below for what remains
-- genuinely untested about this thread even after this addition.
-- ========================================================================

t.test('LEASH PULL-BACK: baseline -- out of the pull zone, not in a vehicle, not resting -- SetEntityCoords genuinely pulls this ped toward its partner (proves the thread body actually runs, not merely registers)', function()
    local f = newMovementFixture({ stepThreads = true })
    f.registerPartnerPed(65, 20, 2)
    f.triggerLeashAttached(65535, 65, true)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 10, 0, 0) -- dist 10 -- between pullZoneStart (7.5) and hardCap (15) for this fixture's Config.LeashMaxDistance = 10.0

    f.step()

    t.equals(#f.setCoordsCalls, 1)
    t.equals(f.setCoordsCalls[1].handle, 1, 'THIS client\'s own ped is the one pulled, never the partner\'s')
end)

t.test('LEASH PULL-BACK: IsRestingInKennel() true excludes the pull-back, exactly like IsPedInAnyVehicle/IsInK9Vehicle already did -- THE FIX', function()
    local f = newMovementFixture({ stepThreads = true })
    f.registerPartnerPed(65, 20, 2)
    f.triggerLeashAttached(65535, 65, true)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 10, 0, 0)
    f.setIsRestingInKennel(true)

    f.step()

    t.equals(#f.setCoordsCalls, 0, 'resting in a kennel must exclude the elastic pull-back -- otherwise a physics fight against the kennel\'s own AttachEntityToEntity every tick')
end)

t.test('LEASH PULL-BACK: IsRestingInKennel absent entirely (client/kennel.lua not loaded) is a soft dependency -- pull-back still runs exactly as before this pass, no error', function()
    local f = newMovementFixture({ stepThreads = true, provideIsRestingInKennel = false })
    t.isNil(f.env.IsRestingInKennel, 'IsRestingInKennel must be genuinely absent from this sandbox for this test to prove anything')
    f.registerPartnerPed(65, 20, 2)
    f.triggerLeashAttached(65535, 65, true)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 10, 0, 0)

    f.step() -- must not throw "attempt to call a nil value"

    t.equals(#f.setCoordsCalls, 1, 'with client/kennel.lua absent, the pull-back must behave exactly as it did before this pass')
end)

t.test('LEASH PULL-BACK: past the hard cap, the safety-valve auto-detach still fires regardless of IsRestingInKennel() -- the kennel exclusion only ever touches the SOFT pull-back branch, never the hard-cap fallback', function()
    local f = newMovementFixture({ stepThreads = true })
    f.registerPartnerPed(65, 20, 2)
    f.triggerLeashAttached(65535, 65, true)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 20, 0, 0) -- dist 20 > hardCap (15)
    f.setIsRestingInKennel(true)

    f.step()

    t.equals(#f.setCoordsCalls, 0, 'the hard-cap branch never calls SetEntityCoords -- it detaches instead')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'john-k9:server:detachLeash', 'DetachLeash() must still fire unconditionally even while resting in a kennel -- the hard-cap safety valve is this file\'s own last resort and must never be excludable')
end)

-- ========================================================================
-- WHAT THIS FILE STILL DOES NOT COVER, AND WHY (per this task's own
-- instruction to disclose uncovered paths rather than silently skip them):
--
--   - The elastic leash pull-back thread's own detachRequestedForSafety
--     single-fire guard, and its softLimit/pullZoneStart proportional
--     pull-strength math (the exact pullAmount for a given distance) --
--     PRIORITY #7 above proves the thread runs and proves its THREE
--     exclusions (vehicle/K9-vehicle/kennel) and its hard-cap fallback all
--     fire or don't fire correctly, but does not pin the exact magnitude
--     of a given pull-back call or that a second hard-cap breach within
--     the same attach does not re-notify/re-detach.
--   - ToggleK9Camera()'s OWN gate behavior (IsOwnModelK9 false -> deny) is
--     exercised only as a SIDE EFFECT of setting up onResourceStop tests
--     above -- not independently tested for its own sake (e.g. the
--     denial-path notify text).
--   - K9Sit() -- not exercised at all (no ClearPedTasksImmediately/
--     TaskStartScenarioInPlace stubs are even provided).
--   - RegisterLeashOxTargetOption() /
--     RegisterDoorInteractionOxTargetOptions() and their canInteract/
--     onSelect closures -- these `local` functions are only reachable via
--     the combined onResourceStart handler this spec confirms is
--     registered (see the "registers exactly 1 onResourceStart handler"
--     sanity test above) but never FIRES. Reaching them would need
--     exports.ox_target stubs and a live Config.LeashMaxDistance/
--     Config.CertifyProximityMeters/Config.DoorInteraction.* fixture --
--     all display-only plausibility gates per this file's own repeated
--     documentation (the server independently re-validates everything
--     authoritatively regardless), so this is a real but low-severity gap.
--   - ScratchAtDoor() / NudgeDoor() / IsLikelyDoorEntity() and the
--     playDoorScratch broadcast receiver -- same reasoning as the
--     ox_target registration functions above (only reachable through
--     onResourceStart-registered ox_target options this spec never fires,
--     or directly as `local`s this spec cannot reach at all).
--   - The AgilityBasicJump-suppression CreateThread branch -- NOW COVERED,
--     see PRIORITY #4 above (added this pass, as part of closing the
--     any-ped speed-system gap): newMovementFixture({ agilityBasicJump =
--     false, stepThreads = true }) registers and actually steps this
--     thread's body, proving it gates on IsEntityModelK9(PlayerPedId())
--     (the body), never IsOwnModelK9() (which would incorrectly also
--     suppress a role-holder on a human body -- the owner's own explicit,
--     dated decision this section's own tests pin). Still not covered:
--     the idle-poll interval itself (Wait(1000) in the non-suppressing
--     branch) is asserted only indirectly, via DisableControlAction not
--     firing -- this fixture's Wait stub discards its `ms` argument
--     entirely (Sandbox.newThreadRunner()'s own contract), so the exact
--     1000 vs. 0 distinction between the two branches is not independently
--     verified here, only each branch's DisableControlAction behavior is.
--   - The same thread's PER-PERSON BLOCK (client/featureblocks.lua hand-off
--     item 2) -- NOW COVERED, see PRIORITY #6 above (added this pass):
--     proves the thread is genuinely absent (zero cost, not a cheap poll)
--     until a block first arrives via the local featureBlocksApplied
--     event, created and suppressing within that same tick when it does,
--     self-releasing once cleared, immune to a duplicate second thread if
--     the global-off case and a live block co-occur, upholding the SAME
--     human-body exemption as the global-off case, and failing open when
--     client/featureblocks.lua is not loaded at all. Same disclosed gap as
--     immediately above applies here too (the exact Wait(1000) vs Wait(0)
--     ms argument is not independently asserted, only each branch's
--     DisableControlAction behavior is).
--   - The SOURCE-ORIGIN GUARD's open engine-level question (can `source`
--     ever fail open to something other than 65535 on a genuine dispatch)
--     is NOT settled by the light source-guard tests in this file, exactly
--     as it is not settled by clientcombat_spec.lua's own, much more
--     thorough treatment of the identical pattern -- see that file's own
--     header for the full D3 citation/caveat, which applies here verbatim
--     (this file's guards share the same `if source ~= 65535 then return
--     end` shape, sourced from the same coder-security pass).
-- ========================================================================

os.exit(t.summary())
