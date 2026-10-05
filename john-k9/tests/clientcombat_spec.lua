--[[
    tests/clientcombat_spec.lua

    Direct, black-box tests of client/combat.lua against the REAL,
    unmodified production file -- the client half of BiteAndHold/
    NonLethalTakedown/PropDragging (server/combat.lua's own client-facing
    contract, already covered server-side by combat_spec.lua). Per this
    pass's own task brief, priority is concentrated on the parts that have
    produced real bugs this session:

      1. The suppression maintenance thread's rewrite from a plain
         `while true do Wait(ms) ... end` loop into a self-continuing
         function driven by `promise.new()` + `SetTimeout` (see "CANCELLABLE
         MAINTENANCE WAIT" in client/combat.lua's own header). Proven below:
         the promise resolves once and only once, an unwoken wait still
         resolves on its own timeout, and a grant wakes a parked wait early.
      2. The NPC-takedown health-floor top-up added this session
         (applyNpcTakedown's `SetEntityHealth` call).
      3. Own-death handling for the drag HOLDER and NPC-relay effects (the
         session's "HOLDER-DEATH LIFECYCLE FIX") -- plus, more lightly, the
         pre-existing target-side own-death guards (ActiveBiteHold/
         ActiveForcedRagdoll/ActiveDragSpeedLimit) these mirror.
      4. The `source ~= 65535` origin guard, pinned across a representative
         sample of this file's dozen `john-k9:client:*` handlers -- see
         the dedicated "D3" note below for exactly what this does and does
         not prove.

    A COROUTINE-PER-CALLBACK SCHEDULER, NOT A REAL EVENT LOOP -- this file's
    shared maintenance thread is no longer a `while true do Wait(x) ...
    end` loop (the shape tests/fixtures/sandbox.lua's own
    Sandbox.newThreadRunner() was built for), so this spec does NOT use
    that helper. Instead, `CreateThread` is captured but never
    auto-invoked, and `SetTimeout`/`promise.new()` are modeled directly
    (see newCombatFixture()'s own comment on `runInCoroutine`): every
    entry into `MaintenanceTick` from OUTSIDE an already-running coroutine
    (the thread's own first run, a fired `SetTimeout` callback, a resolved
    promise's `:next()` continuation) is wrapped in a FRESH
    `coroutine.create`/`coroutine.resume` pair, mirroring FXServer's own
    documented "every callback dispatch runs in its own coroutine"
    scheduling model -- which is exactly what makes a `Wait(0)` call
    (`coroutine.yield()` in this fixture) legal inside a `SetTimeout`
    continuation at all, the same property combat_spec.lua's own
    `dispatchStepped` already relies on for a server-side yielding handler.
    A test that needs to step through several consecutive Wait(0)-class
    ticks resumes the returned coroutine directly, one `coroutine.resume`
    per tick, exactly like combat_spec.lua's own `startCoroutine`.

    lib.callback.await IS NOT USED BY THIS FILE -- client/combat.lua never
    calls it (confirmed by grep before writing this), so the recent
    resource-wide "every `lib.callback.await` call is now pcall-wrapped and
    fails CLOSED by throwing, not by returning nil" change has no bearing
    on this spec's fixture.

    FIXTURE CONFIG, NOT REAL config.lua -- per this task's explicit
    instruction: every test below builds its OWN local `Config` table
    (Features.BiteAndHold/NonLethalTakedown/PropDragging, plus the handful
    of Config.Combat.* sub-fields this file actually reads), never the real
    config.lua. This spec keeps passing regardless of which way config.lua's
    Config.Features flags are set on any given day (whatever their current
    count is), and regardless of the exact numeric values shipped there.

    THE VEHICLE-TUCK MUTUAL GUARD (IsBlockedByVehicleTuck / IsInK9Vehicle) --
    landed in client/combat.lua WHILE this spec was being written (a
    concurrent, independent pass closing a QA-reported real defect: a K9
    tucked into a vehicle via client/vehicle.lua's EnterNearestK9Vehicle()
    is genuinely seated in a real vehicle seat with no body free to fight,
    so none of RequestBiteHold/RequestTakedown/
    RequestDrag should be able to start anything against it). Tested below
    against the file as it now stands. ONE REAL, TRANSIENT FINDING while
    writing these tests, disclosed for the record even though it has since
    been fixed by someone else: at the moment this guard's own three call
    sites landed, they called `locale('combat.blocked_by_vehicle')`, and
    that exact key did not yet exist anywhere in locales/en.json (confirmed
    at the time: a plain grep found nothing, and locales/en.json had no
    uncommitted changes, so this was not the ordinary "en.json mid-edit"
    false alarm DEVELOPER_REFERENCE.md warns about -- it was a real gap, reported
    to the coordinator with a suggested string rather than silently worked
    around here). The key was added shortly after being reported (see
    locales/en.json's real "combat.blocked_by_vehicle" entry) -- the
    vehicle-tuck test section below now passes against the real, current
    text, fetched via locale() rather than typed in by hand.

    ======================================================================
    D3 -- WHAT THE SOURCE-ORIGIN GUARD TESTS BELOW DO AND DO NOT PROVE
    (repeated at every relevant test's own call site too, not left to be
    found only here, matching tests/main_spec.lua's own convention for the
    identical pattern in client/main.lua's playBark handler):

    Every `john-k9:client:*` handler in this file opens with
    `if source ~= 65535 then return end` (coder-security pass, per
    DEVELOPER_REFERENCE.md#trust-boundary). This spec's sandbox models
    `source` as an ordinary Lua global the handler reads via `_ENV` --
    exactly like every other stubbed native here -- and each test below
    sets it explicitly before invoking the captured handler. That is
    sufficient to pin what THE CODE WRITTEN does: a 65535-sourced call is
    processed, anything else is rejected before doing any work.

    IT IS NOT SUFFICIENT, AND IS NOT CLAIMED TO BE SUFFICIENT, to settle
    DEVELOPER_REFERENCE.md's still-OPEN decision D3: whether FiveM's real client
    runtime always/reliably repopulates `source` this way on every genuine
    dispatch, or whether it can fail open via a stale carry-over from a
    prior genuine server-sent event landing on a since-forged local
    trigger. As of this spec's writing, DEVELOPER_REFERENCE.md's own D3 section
    describes at least four independent attempts to settle this by reading
    the game engine's own source code, all of which hit the same wall (the
    part that actually decides this is not in any file readable from
    outside the engine's own private build process) -- and this task's own
    brief describes a fifth such attempt having also failed. Only a live
    test against a real, running server (D3's own "connect a test account,
    receive one genuine server message, then try to fake one" sequence) can
    settle it -- a Lua-level sandbox test, however green, categorically
    cannot raise or lower that grade. A GREEN RUN OF THIS SPEC FILE MUST
    NEVER BE READ AS HAVING CLOSED D3. This file's own tests are worth
    having regardless: they prove the guard AS WRITTEN does reject a
    non-65535 `source`, a necessary (not sufficient) condition for the
    mitigation to work at all.
    ======================================================================

    WHAT THIS FILE DOES NOT COVER, AND WHY: see the dedicated section at
    the bottom of this file, after every test.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to combat_spec.lua's own
-- copy (the only natives this file calls that need real `-`/`#` vector
-- operators are GetEntityCoords' call sites in FindNearestCombatTarget/
-- FindNearestDraggableCandidate).
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
-- GetHashKey stand-in -- same deterministic, non-native formula every
-- other client spec in this suite already uses. Only needed here because
-- K9_BITE_HOLD_SCENARIO_BY_MODEL_HASH is built from it at FILE-LOAD time.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'john-k9'

local function baselineBiteAndHoldConfig()
    return { range = 2.5, maxDurationMs = 15000 }
end

local function baselineTakedownConfig()
    return { range = 3.0, ragdollDurationMs = 4000, healthFloor = 100 }
end

local function baselinePropDraggingConfig()
    return { range = 2.5, maxDragDurationMs = 20000, dragSpeedMultiplier = 0.4 }
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for client/combat.lua, with a
--- controllable/capturing stand-in for every native or cross-file global
--- this spec's exercised call paths touch.
--- @param opts table?
--- @return table fixture
local function newCombatFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local gameTimerCallCount = 0
    local function GetGameTimer()
        gameTimerCallCount = gameTimerCallCount + 1
        return fakeNow
    end

    -- ---- CreateThread / Wait / promise / SetTimeout scheduling ----
    -- See this file's own header "A COROUTINE-PER-CALLBACK SCHEDULER" for
    -- the full reasoning.
    local capturedThreadFns = {}
    local function CreateThread(fn) capturedThreadFns[#capturedThreadFns + 1] = fn end
    local function Wait(_ms) coroutine.yield() end

    -- Mirrors deferred.lua's real, documented contract (see
    -- client/combat.lua's own header "CANCELLABLE MAINTENANCE WAIT" --
    -- verified there against the primary source): `:next(fn)` registers a
    -- continuation; `:resolve()` runs every registered continuation exactly
    -- once -- a promise already past PENDING is a verified no-op on a
    -- second `:resolve()` call, never a second run.
    local promiseLib = {}
    function promiseLib.new()
        local p = { _state = 0, _callbacks = {} }
        function p:next(fn)
            if self._state == 1 then fn() else self._callbacks[#self._callbacks + 1] = fn end
        end
        function p:resolve()
            if self._state ~= 0 then return end -- resolve-once guarantee
            self._state = 1
            local callbacks = self._callbacks
            self._callbacks = {}
            for _, cb in ipairs(callbacks) do cb() end
        end
        return p
    end

    local pendingTimeouts = {} -- ordered list of callback functions
    local function SetTimeout(_ms, fn)
        pendingTimeouts[#pendingTimeouts + 1] = fn
        return #pendingTimeouts
    end

    --- Runs `fn` inside a FRESH coroutine and returns it, whatever state it
    --- ends up in ('suspended' if it hit a Wait(0)-class reassertion branch,
    --- 'dead' if it ran to completion, i.e. reached the idle
    --- WaitCancellable branch and returned normally).
    local function runInCoroutine(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then error('runInCoroutine: ' .. tostring(err)) end
        return co
    end

    -- ---- event/thread registration capture ----
    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- ---- self-initiated-trigger natives ----
    local pedHandle = 1
    local existingEntities = { [1] = true }
    local deadPeds = {}
    local coordsByPed = { [1] = vec3(0, 0, 0) }
    local pedPool = {}
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(ped) return existingEntities[ped] == true end
    local function IsEntityDead(ped) return deadPeds[ped] == true end
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end
    local function GetGamePool(poolName) return poolName == 'CPed' and pedPool or {} end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] or (ped + 500000) end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local isOwnModelK9 = opts.isOwnModelK9 or false
    local function CanShowK9UI() return canShowK9UI end
    local denyCallCount = 0
    local function DenyK9UIAccess() denyCallCount = denyCallCount + 1 end
    local function IsOwnModelK9() return isOwnModelK9 end

    -- HasK9Access() -- ANY-PED SWEEP FIX (this pass): the PropDragging
    -- move-rate-composer routing decision (AssertDragSpeedLimitOnTarget/
    -- endDragSpeedLimit/the shared maintenance thread's ActiveDragSpeedLimit
    -- branches/onResourceStop) now reads `(IsOwnModelK9() or HasK9Access())
    -- and K9MoveRateModifiers`, matching client/movement.lua's own
    -- RecomputeK9MoveRate() eligibility gate exactly (see this file's
    -- header "MOVE-RATE COMPOSER SCOPE" note for the full writeup). Default
    -- false, matching the PRE-FIX implicit assumption every existing test
    -- below that leaves this unset already relies on (isOwnModelK9 = false
    -- with no access concept at all used to mean "take the direct
    -- SetPedMoveRateOverride branch") -- so `(false or false) = false`
    -- preserves every pre-existing test's expected behavior unchanged;
    -- only a test that explicitly opts in via `hasK9Access = true` (or
    -- `f.setHasK9Access(true)`) exercises the new OR-widened branch.
    local hasK9Access = opts.hasK9Access or false
    local function HasK9Access() return hasK9Access end

    -- IsInK9Vehicle -- absent by default (models client/vehicle.lua not
    -- loaded at all, e.g. a unit-test harness -- this file's own comment on
    -- IsBlockedByVehicleTuck names this exact scenario), settable via
    -- opts.isInK9Vehicle (nil = absent global, true/false = present).
    local isInK9Vehicle = opts.isInK9Vehicle

    -- ---- NPC/target relay natives ----
    local networkEntities = {}
    local function ResolveNetworkEntity(netId) return networkEntities[netId] end

    local requestControlCalls = {}
    local function NetworkRequestControlOfEntity(entity) requestControlCalls[#requestControlCalls + 1] = entity end

    local disableControlCalls = {}
    local function DisableControlAction(inputGroup, control, disable)
        disableControlCalls[#disableControlCalls + 1] = { inputGroup = inputGroup, control = control, disable = disable }
    end

    local callOrder = {} -- shared ordering log, see "ORDERING" tests below
    local canBeDamagedCalls = {}
    local function SetEntityCanBeDamaged(ped, canBeDamaged)
        canBeDamagedCalls[#canBeDamagedCalls + 1] = { ped = ped, canBeDamaged = canBeDamaged }
        callOrder[#callOrder + 1] = 'SetEntityCanBeDamaged'
    end

    local blockingCalls = {}
    local function SetBlockingOfNonTemporaryEvents(ped, blocking)
        blockingCalls[#blockingCalls + 1] = { ped = ped, blocking = blocking }
    end

    local fleeAttributeCalls = {}
    local function SetPedFleeAttributes(ped, flags, clear)
        fleeAttributeCalls[#fleeAttributeCalls + 1] = { ped = ped, flags = flags, clear = clear }
    end

    local ragdollCalls = {}
    local function SetPedToRagdollWithFall(ped, minTime, maxTime, fallType, dirX, dirY, dirZ, ...)
        ragdollCalls[#ragdollCalls + 1] = { ped = ped, minTime = minTime, maxTime = maxTime, fallType = fallType, dirX = dirX, dirY = dirY, dirZ = dirZ }
        callOrder[#callOrder + 1] = 'SetPedToRagdollWithFall'
    end

    local forwardVectorByPed = {}
    local function GetEntityForwardVector(ped) return forwardVectorByPed[ped] or vec3(0, 0, 0) end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end
    local setHealthCalls = {}
    local function SetEntityHealth(ped, health)
        setHealthCalls[#setHealthCalls + 1] = { ped = ped, health = health }
        callOrder[#callOrder + 1] = 'SetEntityHealth'
    end

    local attachCalls = {}
    local function AttachEntityToEntity(targetPed, holderPed, ...)
        attachCalls[#attachCalls + 1] = { targetPed = targetPed, holderPed = holderPed }
    end
    local detachCalls = {}
    local function DetachEntity(ped, ...) detachCalls[#detachCalls + 1] = ped end

    local moveRateCalls = {}
    local function SetPedMoveRateOverride(ped, rate) moveRateCalls[#moveRateCalls + 1] = { ped = ped, rate = rate } end

    local clearTasksCalls, scenarioCalls = {}, {}
    local function ClearPedTasksImmediately(ped) clearTasksCalls[#clearTasksCalls + 1] = ped end
    local function TaskStartScenarioInPlace(ped, name) scenarioCalls[#scenarioCalls + 1] = { ped = ped, name = name } end
    local function GetEntityModel(_ped) return 0 end -- cosmetic-only lookup, not asserted on below

    -- ---- move-rate composer (client/movement.lua) -- cross-file, optional ----
    local recomputeCalls = 0
    local K9MoveRateModifiers, RecomputeK9MoveRate
    if opts.withMoveRateComposer then
        K9MoveRateModifiers = { fatigue = 1.0, injury = 1.0, mood = 1.0, xpTier = 1.0, dragging = 1.0 }
        RecomputeK9MoveRate = function() recomputeCalls = recomputeCalls + 1 end
    end

    local config = {
        Features = {
            BiteAndHold = opts.biteAndHold ~= false,
            NonLethalTakedown = opts.nonLethalTakedown ~= false,
            PropDragging = opts.propDragging ~= false,
        },
        Combat = {
            BiteAndHold = opts.biteAndHoldCfg or baselineBiteAndHoldConfig(),
            NonLethalTakedown = opts.takedownCfg or baselineTakedownConfig(),
            PropDragging = opts.propDraggingCfg or baselinePropDraggingConfig(),
        },
    }

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = Wait,
        promise = promiseLib,
        SetTimeout = SetTimeout,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        GetHashKey = GetHashKey,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        GetEntityCoords = GetEntityCoords,
        GetGamePool = GetGamePool,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        TriggerServerEvent = TriggerServerEvent,
        lib = lib,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        IsOwnModelK9 = IsOwnModelK9,
        HasK9Access = HasK9Access,
        ResolveNetworkEntity = ResolveNetworkEntity,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        DisableControlAction = DisableControlAction,
        SetEntityCanBeDamaged = SetEntityCanBeDamaged,
        SetBlockingOfNonTemporaryEvents = SetBlockingOfNonTemporaryEvents,
        SetPedFleeAttributes = SetPedFleeAttributes,
        SetPedToRagdollWithFall = SetPedToRagdollWithFall,
        GetEntityForwardVector = GetEntityForwardVector,
        GetEntityHealth = GetEntityHealth,
        SetEntityHealth = SetEntityHealth,
        AttachEntityToEntity = AttachEntityToEntity,
        DetachEntity = DetachEntity,
        SetPedMoveRateOverride = SetPedMoveRateOverride,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
        GetEntityModel = GetEntityModel,
        Config = config,
    }
    if isInK9Vehicle ~= nil then
        envOverrides.IsInK9Vehicle = function() return isInK9Vehicle end
    end
    if opts.withMoveRateComposer then
        envOverrides.K9MoveRateModifiers = K9MoveRateModifiers
        envOverrides.RecomputeK9MoveRate = RecomputeK9MoveRate
    end

    local env = Sandbox.newEnv(envOverrides)
    Sandbox.loadInto('../client/combat.lua', env)

    return {
        env = env,
        config = config,
        serverEvents = serverEvents,
        lastServerEvent = function()
            return serverEvents[#serverEvents]
        end,
        notifyCalls = notifyCalls,
        denyCallCount = function() return denyCallCount end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setIsInK9Vehicle = function(v) isInK9Vehicle = v end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        gameTimerCallCount = function() return gameTimerCallCount end,
        setPed = function(handle, exists)
            pedHandle = handle
            if exists ~= false then existingEntities[handle] = true end
        end,
        setDead = function(ped, isDead) deadPeds[ped] = isDead end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        addPoolPed = function(ped, opts2)
            opts2 = opts2 or {}
            pedPool[#pedPool + 1] = ped
            existingEntities[ped] = opts2.exists ~= false
            deadPeds[ped] = opts2.dead == true
            coordsByPed[ped] = vec3(opts2.x or 0, opts2.y or 0, opts2.z or 0)
        end,
        setNetId = function(ped, netId) netIdByPed[ped] = netId end,
        registerNetworkEntity = function(netId, ped) networkEntities[netId] = ped end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setForward = function(ped, x, y, z) forwardVectorByPed[ped] = vec3(x, y, z) end,
        requestControlCalls = requestControlCalls,
        disableControlCalls = disableControlCalls,
        canBeDamagedCalls = canBeDamagedCalls,
        blockingCalls = blockingCalls,
        fleeAttributeCalls = fleeAttributeCalls,
        ragdollCalls = ragdollCalls,
        setHealthCalls = setHealthCalls,
        attachCalls = attachCalls,
        detachCalls = detachCalls,
        moveRateCalls = moveRateCalls,
        recomputeCallCount = function() return recomputeCalls end,
        K9MoveRateModifiers = K9MoveRateModifiers,
        callOrder = callOrder,
        netEventNames = netEvents,
        threadCreateCount = function() return #capturedThreadFns end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        -- Invokes a captured `john-k9:client:*` handler directly (never
        -- yields -- none of client/combat.lua's RegisterNetEvent handler
        -- BODIES call Wait, unlike server/combat.lua's own yielding
        -- HandleTakedownRequest) with `source` set immediately beforehand.
        dispatchNetEvent = function(eventName, sourceValue, ...)
            local handler = assert(netEvents[eventName], 'no handler registered for ' .. eventName)
            env.source = sourceValue
            handler(...)
        end,
        startMaintenanceThread = function()
            assert(#capturedThreadFns == 1, 'expected exactly one CreateThread call, got ' .. #capturedThreadFns)
            return runInCoroutine(capturedThreadFns[1])
        end,
        pendingTimeoutCount = function() return #pendingTimeouts end,
        fireTimeout = function(index)
            local fn = table.remove(pendingTimeouts, index or 1)
            assert(fn, 'fireTimeout: no pending timeout at index ' .. tostring(index or 1))
            return runInCoroutine(fn)
        end,
        resumeCoroutine = function(co)
            local ok, err = coroutine.resume(co)
            if not ok then error('resumeCoroutine: ' .. tostring(err)) end
        end,
    }
end

-- ========================================================================
-- Sanity: the file loaded and registered exactly what its own header
-- documents, before trusting any test below.
-- ========================================================================

t.test('with every combat feature flag off, the file is genuinely inert: no globals, no net events, no thread, no onResourceStop handler', function()
    local f = newCombatFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = false })
    t.isNil(f.env.RequestBiteHold)
    t.isNil(f.env.RequestTakedown)
    t.isNil(f.env.RequestDrag)
    t.isNil(f.env.IsBiteHoldEngaged)
    t.isNil(f.env.IsDragEngaged)
    -- CANCEL-PATH FIX (this pass): ReleaseTakedown/IsTakedownEngaged live in
    -- the exact same file-level "at least one flag on" gate as every other
    -- global above -- genuinely inert (undefined, not merely a no-op) with
    -- every flag off, same as their siblings.
    t.isNil(f.env.ReleaseTakedown)
    t.isNil(f.env.IsTakedownEngaged)
    local netEventCount = 0
    for _ in pairs(f.netEventNames) do netEventCount = netEventCount + 1 end
    t.equals(netEventCount, 0)
    t.equals(f.threadCreateCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

t.test('with at least one flag on, the shared maintenance thread and onResourceStop handler are both created exactly once, regardless of WHICH single flag it is', function()
    local f = newCombatFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = true })
    t.equals(f.threadCreateCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('PER-MECHANIC GATING: with only PropDragging on, BiteAndHold/NonLethalTakedown receiver events are never registered', function()
    local f = newCombatFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = true })
    t.isNil(f.netEventNames['john-k9:client:applyBiteHold'])
    t.isNil(f.netEventNames['john-k9:client:forceRagdoll'])
    t.isNotNil(f.netEventNames['john-k9:client:dragStarted'])
end)

-- This case previously PINNED the opposite behaviour as a disclosed,
-- unfixed finding: the per-mechanic gate had only ever closed the RECEIVING
-- side, so RequestBiteHold/RequestTakedown/RequestDrag remained defined and
-- still fired at the server whenever ANY of the three top-level flags was
-- on. That was never a security hole -- the server gates each mechanic
-- independently and rejected it -- but it contradicted this file's own
-- stated "per-mechanic, not just per-file, inertness" goal, and it sent a
-- doomed request the player got no useful feedback from.
-- The sending side is now gated too. Do NOT revert this to the old
-- expectation: a request that cannot possibly succeed should be refused
-- here, with a reason the player can read, rather than travelling to the
-- server to be silently dropped.
t.test('PER-MECHANIC GATING, SENDING SIDE: with its own flag off, RequestBiteHold refuses locally and never reaches the server', function()
    local f = newCombatFixture({ biteAndHold = false, nonLethalTakedown = false, propDragging = true })
    f.setHasK9Access(true) -- PERMISSION AUDIT FOLLOW-UP: the relevant access gate is now HasK9Access() alone (was CanShowK9UI()) -- set here purely to prove the FEATURE-flag check runs first, ahead of the access check, regardless of access
    f.addPoolPed(50, { x = 0.5 })
    -- Still DEFINED -- the file-level gate is "any of the three", and
    -- PropDragging is on here, so the file loads and declares all three.
    -- The refusal is inside the function, not at declaration time.
    t.isNotNil(f.env.RequestBiteHold, 'RequestBiteHold is still defined: the file-level gate is satisfied by PropDragging')
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 0, 'no requestBiteHold event may reach the server when Config.Features.BiteAndHold is false')
    t.equals(#f.notifyCalls, 1, 'the player must be told why, not left with a silent no-op')
    t.equals(f.notifyCalls[1].description, locale('combat.bite_hold_feature_disabled'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('PER-MECHANIC GATING, SENDING SIDE: the same holds for RequestTakedown and RequestDrag', function()
    -- Only BiteAndHold on, so the other two must each refuse locally.
    local f = newCombatFixture({ biteAndHold = true, nonLethalTakedown = false, propDragging = false })
    f.setHasK9Access(true) -- PERMISSION AUDIT FOLLOW-UP -- see the sibling test immediately above for why this is HasK9Access(), not CanShowK9UI(), now
    f.addPoolPed(50, { x = 0.5 })
    f.env.RequestTakedown()
    t.equals(#f.serverEvents, 0, 'RequestTakedown must not reach the server with NonLethalTakedown off')
    f.env.RequestDrag()
    t.equals(#f.serverEvents, 0, 'RequestDrag must not reach the server with PropDragging off')
end)

t.test('PER-MECHANIC GATING: the gate does NOT block the mechanic that IS enabled', function()
    -- The regression that matters most: an over-broad gate would silently
    -- disable a feature the operator turned on.
    local f = newCombatFixture({ biteAndHold = true, nonLethalTakedown = false, propDragging = false })
    f.setHasK9Access(true) -- PERMISSION AUDIT FOLLOW-UP: RequestBiteHold's own access gate is HasK9Access() now (was CanShowK9UI()) -- without this, the fixture's own hasK9Access=false default denies before ever reaching the per-mechanic feature check this test targets
    f.addPoolPed(50, { x = 0.5 })
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 1, 'BiteAndHold is enabled here and must still reach the server')
    t.equals(f.serverEvents[1].event, 'john-k9:server:requestBiteHold')
end)

-- ========================================================================
-- Self-initiated triggers: HasK9Access gate (PERMISSION AUDIT FOLLOW-UP,
-- this pass -- was CanShowK9UI(), widened to match server/combat.lua's
-- shared ValidateCombatRequest, which gates access on HasK9Access(src)
-- alone -- see client/combat.lua's own doc comment on RequestBiteHold()/
-- RequestTakedown()/RequestDrag() for the full writeup), the vehicle-tuck
-- mutual guard, no-target-in-range, and the happy path.
--
-- newCombatFixture()'s own `hasK9Access` default is `false` (chosen to
-- preserve the UNRELATED move-rate-composer tests further down this file
-- that rely on it staying false unless explicitly opted into) -- every test
-- below that means to represent an ORDINARILY PERMITTED K9 now opts in
-- explicitly via `hasK9Access = true` / `f.setHasK9Access(true)`, since
-- CanShowK9UI() no longer gates any of these three functions at all.
-- ========================================================================

t.test('RequestBiteHold: HasK9Access false denies locally, no server contact', function()
    local f = newCombatFixture({ hasK9Access = false })
    f.env.RequestBiteHold()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestBiteHold: no candidate in range notifies and sends nothing', function()
    local f = newCombatFixture({ hasK9Access = true })
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 0)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('combat.no_target_in_range'))
    t.equals(f.notifyCalls[#f.notifyCalls].type, 'error')
end)

t.test('RequestBiteHold: excludes a DEAD candidate ped (unlike RequestDrag\'s own candidate search)', function()
    local f = newCombatFixture({ hasK9Access = true })
    f.addPoolPed(50, { x = 1, dead = true })
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 0, 'a dead ped must never be selected by FindNearestCombatTarget')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('combat.no_target_in_range'), 'must reach the real candidate search (past the access gate) and find nobody live, not merely be denied access')
end)

t.test('RequestBiteHold: happy path sends the real netId of the nearest live candidate', function()
    local f = newCombatFixture({ hasK9Access = true })
    f.addPoolPed(50, { x = 5 })
    f.addPoolPed(51, { x = 1 }) -- nearer
    f.setNetId(51, 900051)
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestBiteHold')
    t.equals(f.lastServerEvent().args[1], 900051)
end)

-- PERMISSION AUDIT FOLLOW-UP -- the High Command/autoAccessGrade bypass
-- shape this pass exists to unblock: HasK9Access() true (server/config
-- grants access without certification) but IsOwnModelK9()/IsK9Role() false
-- (the CanShowK9UI() combinator would have refused this caller before this
-- pass's widening). RequestBiteHold() must reach the server regardless --
-- it no longer calls CanShowK9UI()/IsOwnModelK9() at all.
t.test('RequestBiteHold: HasK9Access() true with isOwnModelK9 false (High Command bypass shape) still reaches the server', function()
    local f = newCombatFixture({ hasK9Access = true, isOwnModelK9 = false, canShowK9UI = false })
    f.addPoolPed(50, { x = 1 })
    f.setNetId(50, 900050)
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 1, 'a HasK9Access()-true bypass holder must reach the server even though CanShowK9UI() would have refused them')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestBiteHold')
    t.equals(f.denyCallCount(), 0, 'must not have been locally denied')
end)

t.test('ReleaseBiteHold: always sends, unconditionally, no HasK9Access gate', function()
    local f = newCombatFixture({ hasK9Access = false })
    f.env.ReleaseBiteHold()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:releaseBiteHold')
end)

-- RELEASE-PATH GUARANTEE, PERMISSION AUDIT FOLLOW-UP (this pass's own
-- explicit requirement): the release half of a toggle must be reachable
-- with NO access at all, even after the START half's own gate was widened
-- -- pinned directly against BOTH access predicates at once (not just
-- HasK9Access, which the line above already covers alone) so a future edit
-- that accidentally adds an `and CanShowK9UI()`-style check to the release
-- path is caught here too.
t.test('ReleaseBiteHold: fires with HasK9Access AND CanShowK9UI both false -- no access of any kind', function()
    local f = newCombatFixture({ hasK9Access = false, canShowK9UI = false, isOwnModelK9 = false })
    f.env.ReleaseBiteHold()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:releaseBiteHold')
end)

-- TERMINATION-PATH GUARANTEE (this pass's own explicit test requirement):
-- "verify the termination path still runs with the gating function
-- entirely undefined, not merely false." `hasK9Access = false` above only
-- proves the FALSE case; a real production install could have a stripped
-- or out-of-order client/main.lua where HasK9Access simply does not exist
-- as a global at all -- a stricter, meaningfully different condition
-- (Lua raises "attempt to call a nil value" on a bare call, not a false
-- return) that a naive `if not HasK9Access() then ... end` guard would
-- crash on, permanently bricking the release path. ReleaseBiteHold's own
-- body never references HasK9UI/HasK9Access (or any other gate) at all --
-- this pins that property directly rather than trusting it by inspection
-- alone. CanShowK9UI is ALSO undefined here (not merely HasK9Access), same
-- "no access predicate of any kind" posture as the pair of tests above.
t.test('ReleaseBiteHold: fires even when HasK9Access/CanShowK9UI are entirely UNDEFINED (not merely false) -- a release path must never depend on any gating function existing at all', function()
    local f = newCombatFixture()
    f.env.HasK9Access = nil
    f.env.CanShowK9UI = nil
    local ok, err = pcall(f.env.ReleaseBiteHold)
    t.isTrue(ok, 'ReleaseBiteHold must not error when HasK9Access/CanShowK9UI are undefined: ' .. tostring(err))
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:releaseBiteHold')
end)

-- ReleaseDrag() had ZERO test coverage before this pass -- the drag
-- equivalent of the two ReleaseBiteHold guarantees above, both pinned here
-- for the first time. A K9 holder stuck unable to drop a dragged suspect
-- is this resource's own named worst-case outcome (client/combat.lua's
-- own ReleaseDrag doc comment: "no consent/access gate on the way out").
t.test('ReleaseDrag: always sends, unconditionally, no HasK9Access/CanShowK9UI gate -- including when both are entirely UNDEFINED, not merely false', function()
    local f = newCombatFixture({ hasK9Access = false, canShowK9UI = false })
    f.env.ReleaseDrag()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:releaseDrag')

    local f2 = newCombatFixture()
    f2.env.HasK9Access = nil
    f2.env.CanShowK9UI = nil
    local ok, err = pcall(f2.env.ReleaseDrag)
    t.isTrue(ok, 'ReleaseDrag must not error when HasK9Access/CanShowK9UI are undefined: ' .. tostring(err))
    t.equals(#f2.serverEvents, 1)
    t.equals(f2.lastServerEvent().event, 'john-k9:server:releaseDrag')
end)

t.test('RequestTakedown: HasK9Access false denies locally (PERMISSION AUDIT FOLLOW-UP -- was CanShowK9UI(), see RequestBiteHold\'s own header comment for the full writeup)', function()
    local f = newCombatFixture({ hasK9Access = false })
    f.env.RequestTakedown()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

-- PERMISSION AUDIT FOLLOW-UP -- the High Command/autoAccessGrade bypass
-- shape, RequestTakedown's own equivalent of RequestBiteHold's identical
-- test above.
t.test('RequestTakedown: HasK9Access() true with isOwnModelK9 false (High Command bypass shape) still reaches the server', function()
    local f = newCombatFixture({ hasK9Access = true, isOwnModelK9 = false, canShowK9UI = false })
    f.addPoolPed(50, { x = 1 })
    f.setNetId(50, 900050)
    f.env.RequestTakedown()
    t.equals(#f.serverEvents, 1, 'a HasK9Access()-true bypass holder must reach the server even though CanShowK9UI() would have refused them')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestTakedown')
    t.equals(f.denyCallCount(), 0, 'must not have been locally denied')
end)

-- CANCEL-PATH FIX (this pass, coder-frontend -- audit-flagged gap):
-- ReleaseTakedown() had ZERO test coverage before this pass -- it did not
-- exist at all. Same two guarantees ReleaseBiteHold/ReleaseDrag already pin
-- above, pinned here for the first time for takedown: a K9 stuck unable to
-- call off a wrongly-targeted takedown is exactly the "no way back" gap
-- this pass exists to close.
t.test('ReleaseTakedown: always sends, unconditionally, no HasK9Access/CanShowK9UI gate -- including when both are entirely UNDEFINED, not merely false', function()
    local f = newCombatFixture({ hasK9Access = false, canShowK9UI = false })
    f.env.ReleaseTakedown()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:releaseTakedown')

    local f2 = newCombatFixture()
    f2.env.HasK9Access = nil
    f2.env.CanShowK9UI = nil
    local ok, err = pcall(f2.env.ReleaseTakedown)
    t.isTrue(ok, 'ReleaseTakedown must not error when HasK9Access/CanShowK9UI are undefined: ' .. tostring(err))
    t.equals(#f2.serverEvents, 1)
    t.equals(f2.lastServerEvent().event, 'john-k9:server:releaseTakedown')
end)

t.test('RequestDrag: candidate search does NOT exclude a dead ped (PropDragging\'s whole premise is a downed target)', function()
    local f = newCombatFixture({ hasK9Access = true }) -- PERMISSION AUDIT FOLLOW-UP: must clear RequestDrag's own access gate to reach the candidate search this test targets
    f.addPoolPed(60, { x = 1, dead = true })
    f.setNetId(60, 900060)
    f.env.RequestDrag()
    t.equals(#f.serverEvents, 1, 'a dead NPC ped must still be a valid drag candidate')
    t.equals(f.lastServerEvent().args[1], 900060)
end)

-- PERMISSION AUDIT FOLLOW-UP -- the High Command/autoAccessGrade bypass
-- shape, RequestDrag's own equivalent of RequestBiteHold/RequestTakedown's
-- identical tests above.
t.test('RequestDrag: HasK9Access() true with isOwnModelK9 false (High Command bypass shape) still reaches the server', function()
    local f = newCombatFixture({ hasK9Access = true, isOwnModelK9 = false, canShowK9UI = false })
    f.addPoolPed(60, { x = 1 })
    f.setNetId(60, 900060)
    f.env.RequestDrag()
    t.equals(#f.serverEvents, 1, 'a HasK9Access()-true bypass holder must reach the server even though CanShowK9UI() would have refused them')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDrag')
    t.equals(f.denyCallCount(), 0, 'must not have been locally denied')
end)

t.test('IsBiteHoldEngaged / IsDragEngaged / IsTakedownEngaged: all false before any grant', function()
    local f = newCombatFixture()
    t.isFalse(f.env.IsBiteHoldEngaged())
    t.isFalse(f.env.IsDragEngaged())
    t.isFalse(f.env.IsTakedownEngaged())
end)

-- ========================================================================
-- LEGIBILITY PASS (this session) -- HOLDER-side duration/ending notices.
-- See client/combat.lua's own header "LEGIBILITY PASS" for the full
-- writeup of the gap these close: before this pass, biteHoldStarted never
-- told the holder how long the hold would run, and biteHoldEnded never
-- told the holder anything at all, for any reason. Neither handler had a
-- single test in this file before this pass either -- both are entirely
-- new coverage, not a rewrite of an existing assertion.
-- ========================================================================

t.test('biteHoldStarted: sets MyEngagedTargetNetId (IsBiteHoldEngaged) and notifies the holder with the configured duration, ceil-rounded to whole seconds', function()
    local f = newCombatFixture({ biteAndHoldCfg = { range = 2.5, maxDurationMs = 12500 } })
    f.dispatchNetEvent('john-k9:client:biteHoldStarted', 65535, 12345, 999)

    t.isTrue(f.env.IsBiteHoldEngaged())
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('combat.bite_hold_holder_status', 13), 'ceil(12500 / 1000) == 13, never truncated to 12')
    t.equals(f.notifyCalls[1].type, 'inform')
    t.equals(f.notifyCalls[1].duration, 12500, 'the toast\'s own lifetime should match the real effect duration')
end)

t.test('biteHoldStarted: source guard rejects a forged local trigger -- no state change, no notify', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:biteHoldStarted', 1, 12345, 999)
    t.isFalse(f.env.IsBiteHoldEngaged())
    t.equals(#f.notifyCalls, 0)
end)

t.test('biteHoldEnded: reason == "released" (the holder\'s own ReleaseBiteHold press) clears state but does NOT notify -- self-evident from the keypress itself, mirrors drag_ended/takedown_ended_early\'s own manual-release exclusion', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:biteHoldStarted', 65535, 555, 999)
    t.equals(#f.notifyCalls, 1, 'sanity: the start notice already fired')

    f.dispatchNetEvent('john-k9:client:biteHoldEnded', 65535, 555, 'released')
    t.isFalse(f.env.IsBiteHoldEngaged())
    t.equals(#f.notifyCalls, 1, 'a manual release must not add a second notify')
end)

t.test('biteHoldEnded: a NON-manual reason (timeout/target_died/disconnect/...) DOES notify the holder -- the consistency fix, matching drag/takedown\'s own "announce every non-manual ending" pattern', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:biteHoldStarted', 65535, 555, 999)

    f.dispatchNetEvent('john-k9:client:biteHoldEnded', 65535, 555, 'timeout')
    t.isFalse(f.env.IsBiteHoldEngaged())
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('combat.bite_hold_ended'))
    t.equals(f.notifyCalls[2].type, 'inform')
end)

t.test('biteHoldEnded: a stale/foreign targetNetId (does not match MyEngagedTargetNetId) is ignored entirely -- never clears a DIFFERENT hold\'s state, never notifies', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:biteHoldStarted', 65535, 555, 999)
    f.dispatchNetEvent('john-k9:client:biteHoldEnded', 65535, 777, 'timeout') -- a DIFFERENT targetNetId
    t.isTrue(f.env.IsBiteHoldEngaged(), 'must still be engaged with 555 -- the stale event named 777')
    t.equals(#f.notifyCalls, 1, 'no end-notify for an event this handler correctly ignored')
end)

t.test('biteHoldEnded: source guard rejects a forged local trigger -- no notify', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:biteHoldStarted', 65535, 555, 999)
    f.dispatchNetEvent('john-k9:client:biteHoldEnded', 1, 555, 'timeout')
    t.isTrue(f.env.IsBiteHoldEngaged(), 'a forged end must not have cleared the hold')
    t.equals(#f.notifyCalls, 1, 'only the start notice, no forged end-notify')
end)

-- ========================================================================
-- CANCEL-PATH FIX (this pass, coder-frontend -- audit-flagged gap):
-- takedownStarted/takedownEnded. Neither event existed before this pass --
-- a takedown's holder previously had NO client-side state for its own
-- takedown at all (client/combat.lua's own header used to say so
-- explicitly), so IsTakedownEngaged() had nothing to report and
-- ReleaseTakedown() had no state to clear. Mirrors biteHoldStarted/
-- biteHoldEnded's own test shape immediately above -- same source-origin
-- guard, same stale/foreign-targetNetId handling -- deliberately WITHOUT a
-- lib.notify assertion: unlike biteHoldStarted/dragStarted, this handler
-- adds no new holder-facing toast (the existing 'combat.takedown_attempted'
-- notify at request time is unchanged, and server/combat.lua's own EndHold
-- already owns the "ended early" notify for every non-manual reason) -- see
-- client/combat.lua's own doc comment on the takedownStarted/takedownEnded
-- handlers for why.
-- ========================================================================

t.test('takedownStarted: sets MyEngagedTakedownTargetNetId (IsTakedownEngaged), no notify', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:takedownStarted', 65535, 12345, 999)
    t.isTrue(f.env.IsTakedownEngaged())
    t.equals(#f.notifyCalls, 0, 'takedownStarted adds no new holder-facing toast -- unlike biteHoldStarted/dragStarted, see this test\'s own header note')
end)

t.test('takedownStarted: source guard rejects a forged local trigger -- no state change', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:takedownStarted', 1, 12345, 999)
    t.isFalse(f.env.IsTakedownEngaged())
end)

t.test('takedownEnded: reason == "released_by_holder" clears state, source-guarded, ignores a stale/foreign targetNetId', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:takedownStarted', 65535, 555, 999)
    t.isTrue(f.env.IsTakedownEngaged())

    -- forged end must not clear real state
    f.dispatchNetEvent('john-k9:client:takedownEnded', 1, 555, 'released_by_holder')
    t.isTrue(f.env.IsTakedownEngaged(), 'a forged end must not have cleared the takedown')

    -- stale/foreign targetNetId must not clear a DIFFERENT takedown's state
    f.dispatchNetEvent('john-k9:client:takedownEnded', 65535, 777, 'timeout')
    t.isTrue(f.env.IsTakedownEngaged(), 'must still be engaged with 555 -- the stale event named 777')

    -- the genuine end
    f.dispatchNetEvent('john-k9:client:takedownEnded', 65535, 555, 'released_by_holder')
    t.isFalse(f.env.IsTakedownEngaged())
    t.equals(#f.notifyCalls, 0, 'no client-side notify for any takedownEnded reason -- see this section\'s own header note')
end)

t.test('dragStarted: notifies the holder with the configured drag duration, mirroring biteHoldStarted', function()
    local f = newCombatFixture({ propDraggingCfg = { range = 2.5, maxDragDurationMs = 8000, dragSpeedMultiplier = 0.4 } })
    f.registerNetworkEntity(900050, 50)
    f.setPed(1, true)
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 900050, false, 999)

    t.isTrue(f.env.IsDragEngaged())
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('combat.drag_holder_status', 8))
    t.equals(f.notifyCalls[1].type, 'inform')
    t.equals(f.notifyCalls[1].duration, 8000)
end)

-- ------------------------------------------------------------------
-- THE VEHICLE-TUCK MUTUAL GUARD (IsBlockedByVehicleTuck) -- landed in
-- client/combat.lua concurrently with this spec's own authoring (see this
-- file's header). type(IsInK9Vehicle) == 'function' runtime existence
-- guard, same convention main_spec.lua's PlayK9Sound tests already cover
-- for an unrelated symbol.
-- ------------------------------------------------------------------

t.test('vehicle-tuck guard: IsInK9Vehicle entirely absent (client/vehicle.lua not loaded) degrades cleanly -- never blocks', function()
    local f = newCombatFixture({ hasK9Access = true }) -- PERMISSION AUDIT FOLLOW-UP: must clear RequestBiteHold's own access gate to reach the vehicle-tuck guard this test targets -- opts.isInK9Vehicle left nil -- global genuinely absent
    t.isNil(f.env.IsInK9Vehicle, 'sanity: this sandbox genuinely does not define IsInK9Vehicle')
    f.addPoolPed(50, { x = 1 })
    local ok, err = pcall(f.env.RequestBiteHold)
    t.isTrue(ok, 'must not error when IsInK9Vehicle does not exist: ' .. tostring(err))
    t.equals(#f.serverEvents, 1)
end)

t.test('vehicle-tuck guard: IsInK9Vehicle present but false -- proceeds normally for all three triggers', function()
    local f = newCombatFixture({ isInK9Vehicle = false, hasK9Access = true })
    f.addPoolPed(50, { x = 1 })
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 1)
end)

t.test('vehicle-tuck guard: IsInK9Vehicle true blocks RequestBiteHold/RequestTakedown/RequestDrag with a notify and zero server contact (locale key "combat.blocked_by_vehicle" was missing from locales/en.json when this test was first written mid-session -- confirmed added since, real string re-checked via locale() below rather than typed in by hand, per this suite\'s own convention)', function()
    local f = newCombatFixture({ isInK9Vehicle = true, hasK9Access = true }) -- PERMISSION AUDIT FOLLOW-UP: must clear the access gate first to actually reach this test's own target, the vehicle-tuck guard immediately after it
    f.addPoolPed(50, { x = 1 }) -- deliberately resolvable -- a bypassed guard WOULD produce a visible server event
    f.env.RequestBiteHold()
    t.equals(#f.serverEvents, 0, 'a tucked K9 must never be able to start a bite hold')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('combat.blocked_by_vehicle'))

    f.env.RequestTakedown()
    t.equals(#f.serverEvents, 0)

    f.env.RequestDrag()
    t.equals(#f.serverEvents, 0)
end)

-- ========================================================================
-- Target-side relay handlers (Category B) -- happy paths and the
-- "bridge call" onset-latency fix (see client/combat.lua's own header
-- "SHARED PER-TICK ASSERTION HELPERS"): a grant immediately runs the
-- SAME reassertion the maintenance thread's next tick would, rather than
-- waiting for that tick.
-- ========================================================================

t.test('applyBiteHold: sets ActiveBiteHold, immediately bridges DisableControlAction (onset-latency fix), and wakes the maintenance thread', function()
    local f = newCombatFixture()
    f.startMaintenanceThread() -- idle -- registers its first coarse-wait SetTimeout
    t.equals(f.pendingTimeoutCount(), 1)

    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999)
    t.equals(#f.disableControlCalls, 2, 'the immediate bridge call must fire both DisableControlAction calls (sprint + attack) on grant, not wait for the next tick')
    t.equals(f.pendingTimeoutCount(), 2, 'WakeMaintenanceThread must schedule a SEPARATE, fresh SetTimeout(0, ...) alongside the still-pending original coarse wait')
    -- LEGIBILITY FIX (this pass) -- the TARGET previously received zero
    -- text for this; see client/combat.lua's own header "LEGIBILITY PASS".
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('combat.bite_hold_target_notice'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('applyBiteHold: source guard rejects a forged local trigger -- pins the CODE only, see this file\'s own D3 note', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 1, 12345, 999)
    t.equals(#f.disableControlCalls, 0)
    t.equals(#f.notifyCalls, 0, 'a forged applyBiteHold must not notify either')
end)

t.test('endBiteHold: source guard rejects a forged local trigger', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999)
    f.dispatchNetEvent('john-k9:client:endBiteHold', 1, 'timeout')
    -- Still active -- proven by the maintenance thread still reasserting on its next tick.
    f.startMaintenanceThread()
    t.isTrue(#f.disableControlCalls > 2, 'a forged endBiteHold must not have cleared ActiveBiteHold')
    t.equals(#f.notifyCalls, 1, 'only the start notice -- a forged end must not add a second notify')
end)

t.test('endBiteHold: source == 65535 genuinely clears ActiveBiteHold -- no further reassertion on the next tick, and notifies the TARGET that the restraint ended', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999)
    local callsAfterGrant = #f.disableControlCalls
    f.dispatchNetEvent('john-k9:client:endBiteHold', 65535, 'timeout')
    f.startMaintenanceThread()
    t.equals(#f.disableControlCalls, callsAfterGrant, 'no new DisableControlAction calls once ActiveBiteHold is cleared')
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('combat.target_restraint_ended'))
    t.equals(f.notifyCalls[2].type, 'inform')
end)

t.test('endBiteHold: a stale/duplicate end (nothing was ever active) is a true no-op -- clears an already-nil state but never notifies', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:endBiteHold', 65535, 'timeout')
    t.equals(#f.notifyCalls, 0, 'nothing was active -- no spurious "you\'re free" toast')
end)

t.test('forceRagdoll: applies the damage bracket and ragdoll task using the TARGET\'s own forward vector, source-guarded', function()
    local f = newCombatFixture()
    f.setPed(1, true)
    f.setForward(1, 0.6, 0.8, 0.0)
    f.dispatchNetEvent('john-k9:client:forceRagdoll', 1, 999) -- forged
    t.equals(#f.canBeDamagedCalls, 0)

    f.dispatchNetEvent('john-k9:client:forceRagdoll', 65535, 999)
    t.equals(#f.canBeDamagedCalls, 1)
    t.equals(f.canBeDamagedCalls[1].ped, 1)
    t.equals(f.canBeDamagedCalls[1].canBeDamaged, false)
    t.equals(#f.ragdollCalls, 1)
    t.equals(f.ragdollCalls[1].dirX, 0.6)
    t.equals(f.ragdollCalls[1].dirY, 0.8)
    -- LEGIBILITY FIX (this pass) -- the forged call above must not have
    -- notified either (source guard already rejected it before this).
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('combat.takedown_target_notice'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('endForceRagdoll: restores damageability, and is a no-op when nothing is active', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:endForceRagdoll', 65535, 'timeout')
    t.equals(#f.canBeDamagedCalls, 0, 'no-op when ActiveForcedRagdoll was never set')
    t.equals(#f.notifyCalls, 0, 'a true no-op must not notify either')

    f.dispatchNetEvent('john-k9:client:forceRagdoll', 65535, 999)
    f.dispatchNetEvent('john-k9:client:endForceRagdoll', 65535, 'timeout')
    t.equals(#f.canBeDamagedCalls, 2)
    t.equals(f.canBeDamagedCalls[2].canBeDamaged, true)
    t.equals(#f.notifyCalls, 2, 'start notice + end notice')
    t.equals(f.notifyCalls[2].description, locale('combat.target_restraint_ended'))
    t.equals(f.notifyCalls[2].type, 'inform')
end)

t.test('applyDragSpeedLimit / endDragSpeedLimit: human target (no move-rate composer) calls SetPedMoveRateOverride directly', function()
    local f = newCombatFixture({ propDragging = true })
    f.setIsOwnModelK9(false)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)
    t.equals(#f.moveRateCalls, 1)
    t.equals(f.moveRateCalls[1].rate, f.config.Combat.PropDragging.dragSpeedMultiplier)
    -- LEGIBILITY FIX (this pass) -- the TARGET previously received zero
    -- text for this either, same gap/fix shape as bite-hold/takedown above.
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('combat.drag_target_notice'))
    t.equals(f.notifyCalls[1].type, 'error')

    f.dispatchNetEvent('john-k9:client:endDragSpeedLimit', 65535, 'released_by_holder')
    t.equals(#f.moveRateCalls, 2)
    t.equals(f.moveRateCalls[2].rate, 1.0)
    t.equals(#f.detachCalls, 1, 'endDragSpeedLimit also defensively detaches its own ped')
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('combat.target_restraint_ended'))
    t.equals(f.notifyCalls[2].type, 'inform')
end)

t.test('endDragSpeedLimit: a stale/duplicate end (nothing was ever active) is a true no-op -- never notifies', function()
    local f = newCombatFixture({ propDragging = true })
    f.dispatchNetEvent('john-k9:client:endDragSpeedLimit', 65535, 'released_by_holder')
    t.equals(#f.moveRateCalls, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('applyDragSpeedLimit: a K9-model target (rare, per this file\'s own "MOVE-RATE COMPOSER SCOPE" note) routes through the composer instead of calling SetPedMoveRateOverride directly', function()
    local f = newCombatFixture({ propDragging = true, withMoveRateComposer = true })
    f.setIsOwnModelK9(true)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)
    t.equals(#f.moveRateCalls, 0, 'must not call SetPedMoveRateOverride directly when routing through the composer')
    t.equals(f.recomputeCallCount(), 1)
    t.equals(f.K9MoveRateModifiers.dragging, f.config.Combat.PropDragging.dragSpeedMultiplier)
end)

-- REGRESSION (ANY-PED SWEEP FIX, this pass) -- pins the exact bug
-- client/movement.lua's own "MOVE-RATE COMPOSER SCOPE" note flagged as a
-- related, out-of-scope observation when RecomputeK9MoveRate() itself was
-- widened to `not (IsOwnModelK9() or HasK9Access())`: a K9-role handler on
-- a non-K9 body (IsOwnModelK9() false) whose access comes from
-- HasK9Access() (job/certification, or the High Command/autoAccessGrade
-- bypass server/pursuitsprint.lua's own grant relies on -- deliberately
-- NOT IsK9Role(), which excludes those bypasses) is dragged. BEFORE this
-- fix, this exact caller took the direct SetPedMoveRateOverride branch
-- (IsOwnModelK9() alone was false), silently clobbering any of THEIR OWN
-- already-composed fatigue/injury/mood move-rate modifiers for the
-- duration of the drag, and resetting them to a flat 1.0 -- not back to
-- their own composed baseline -- the instant the drag ended. Fixed: this
-- caller must now route through the SAME composer the K9-model case above
-- does, identically, even off-model.
t.test('applyDragSpeedLimit: a HasK9Access()-true target on a non-K9 body (role/access, not model) ALSO routes through the composer, not a raw override', function()
    local f = newCombatFixture({ propDragging = true, withMoveRateComposer = true })
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)
    t.equals(#f.moveRateCalls, 0, 'must not call SetPedMoveRateOverride directly -- HasK9Access() alone must be enough to route through the composer')
    t.equals(f.recomputeCallCount(), 1)
    t.equals(f.K9MoveRateModifiers.dragging, f.config.Combat.PropDragging.dragSpeedMultiplier)

    f.dispatchNetEvent('john-k9:client:endDragSpeedLimit', 65535, 'released_by_holder')
    t.equals(#f.moveRateCalls, 0, 'the restore-to-neutral side must ALSO route through the composer for this same caller, not reset to a flat 1.0 directly')
    t.equals(f.recomputeCallCount(), 2)
    t.equals(f.K9MoveRateModifiers.dragging, 1.0)
end)

-- ========================================================================
-- NPC-relay handlers, and PRIORITY #2: the NPC-takedown health-floor
-- top-up (applyNpcTakedown's SetEntityHealth call).
-- ========================================================================

t.test('applyNpcBiteHold: resolves the netId, requests network control, applies flee-suppression, source-guarded', function()
    local f = newCombatFixture()
    f.registerNetworkEntity(500, 5000)
    f.dispatchNetEvent('john-k9:client:applyNpcBiteHold', 1, 500, 999) -- forged
    t.equals(#f.requestControlCalls, 0)

    f.dispatchNetEvent('john-k9:client:applyNpcBiteHold', 65535, 500, 999)
    t.equals(#f.requestControlCalls, 1)
    t.equals(f.requestControlCalls[1], 5000)
    t.equals(#f.blockingCalls, 1)
    t.equals(f.blockingCalls[1].blocking, true)
    t.equals(#f.fleeAttributeCalls, 1)
end)

t.test('applyNpcBiteHold: an unresolvable netId (despawned between grant and receipt) is a clean no-op', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:applyNpcBiteHold', 65535, 999999, 999)
    t.equals(#f.requestControlCalls, 0)
    t.equals(#f.blockingCalls, 0)
end)

t.test('endNpcBiteHold: restores flee-suppression', function()
    local f = newCombatFixture()
    f.registerNetworkEntity(500, 5000)
    f.dispatchNetEvent('john-k9:client:applyNpcBiteHold', 65535, 500, 999)
    f.dispatchNetEvent('john-k9:client:endNpcBiteHold', 65535, 500, 'released')
    t.equals(#f.blockingCalls, 2)
    t.equals(f.blockingCalls[2].blocking, false)
end)

t.test('applyNpcTakedown: NPC health below the configured floor is topped up, BEFORE the ragdoll task, alongside (not instead of) the damage bracket', function()
    local f = newCombatFixture({ takedownCfg = { range = 3.0, ragdollDurationMs = 4000, healthFloor = 100 } })
    f.registerNetworkEntity(600, 6000)
    f.setHealth(6000, 50) -- below the 100 floor
    f.dispatchNetEvent('john-k9:client:applyNpcTakedown', 65535, 600, 999)

    t.equals(#f.setHealthCalls, 1)
    t.equals(f.setHealthCalls[1].ped, 6000)
    t.equals(f.setHealthCalls[1].health, 100)
    t.equals(#f.canBeDamagedCalls, 1, 'the damage bracket must still apply regardless of the health top-up')
    t.equals(#f.ragdollCalls, 1)

    -- Ordering: SetEntityCanBeDamaged and SetEntityHealth must both precede
    -- SetPedToRagdollWithFall, per this handler's own documented
    -- "damage-bracket + health floor BEFORE the ragdoll task, never after".
    local healthIndex, damagedIndex, ragdollIndex
    for i, tag in ipairs(f.callOrder) do
        if tag == 'SetEntityHealth' then healthIndex = i end
        if tag == 'SetEntityCanBeDamaged' then damagedIndex = i end
        if tag == 'SetPedToRagdollWithFall' then ragdollIndex = i end
    end
    t.isTrue(healthIndex < ragdollIndex, 'SetEntityHealth must run before SetPedToRagdollWithFall')
    t.isTrue(damagedIndex < ragdollIndex, 'SetEntityCanBeDamaged must run before SetPedToRagdollWithFall')
end)

t.test('applyNpcTakedown: NPC health EXACTLY at the floor is left untouched (strict less-than, not <=)', function()
    local f = newCombatFixture({ takedownCfg = { range = 3.0, ragdollDurationMs = 4000, healthFloor = 100 } })
    f.registerNetworkEntity(601, 6001)
    f.setHealth(6001, 100)
    f.dispatchNetEvent('john-k9:client:applyNpcTakedown', 65535, 601, 999)
    t.equals(#f.setHealthCalls, 0)
end)

t.test('applyNpcTakedown: NPC health ABOVE the floor is left untouched -- this is a one-time top-up, never a heal above the floor', function()
    local f = newCombatFixture({ takedownCfg = { range = 3.0, ragdollDurationMs = 4000, healthFloor = 100 } })
    f.registerNetworkEntity(602, 6002)
    f.setHealth(6002, 180)
    f.dispatchNetEvent('john-k9:client:applyNpcTakedown', 65535, 602, 999)
    t.equals(#f.setHealthCalls, 0)
end)

t.test('applyNpcTakedown: uses the REQUESTING K9\'s own forward vector (PlayerPedId()), not the NPC\'s -- higher fidelity than forceRagdoll\'s player-target fallback (see this file\'s own "RAGDOLL FALL-DIRECTION" note)', function()
    local f = newCombatFixture()
    f.setPed(1, true)
    f.setForward(1, 0.3, 0.9, 0.0) -- the K9's own forward vector
    f.registerNetworkEntity(603, 6003)
    f.setForward(6003, 1.0, 0.0, 0.0) -- the NPC's own forward vector -- must NOT be the one used
    f.dispatchNetEvent('john-k9:client:applyNpcTakedown', 65535, 603, 999)
    t.equals(f.ragdollCalls[1].dirX, 0.3)
    t.equals(f.ragdollCalls[1].dirY, 0.9)
end)

t.test('endNpcTakedown: restores damageability, a clean no-op for an unresolvable netId', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:endNpcTakedown', 65535, 999999, 'timeout')
    t.equals(#f.canBeDamagedCalls, 0)

    f.registerNetworkEntity(604, 6004)
    f.dispatchNetEvent('john-k9:client:applyNpcTakedown', 65535, 604, 999)
    f.dispatchNetEvent('john-k9:client:endNpcTakedown', 65535, 604, 'timeout')
    t.equals(#f.canBeDamagedCalls, 2)
    t.equals(f.canBeDamagedCalls[2].canBeDamaged, true)
end)

-- ========================================================================
-- PropDragging holder-side (dragStarted/dragEnded) -- the AttachEntityToEntity
-- bridge call and NPC-target move-rate direct call.
-- ========================================================================

t.test('dragStarted: NPC target -- bridges an immediate AttachEntityToEntity + move-rate override on grant, wakes the thread', function()
    local f = newCombatFixture({ propDragging = true })
    f.registerNetworkEntity(700, 7000)
    f.startMaintenanceThread()
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 700, false, 999)
    t.equals(#f.attachCalls, 1)
    t.equals(f.attachCalls[1].targetPed, 7000)
    t.equals(#f.moveRateCalls, 1, 'NPC target: the move rate is driven directly by the HOLDER\'s own client')
    t.isTrue(f.env.IsDragEngaged())
end)

t.test('dragStarted: PLAYER target -- attaches, but does NOT drive the target\'s move rate directly (that is the target\'s OWN client\'s job via applyDragSpeedLimit)', function()
    local f = newCombatFixture({ propDragging = true })
    f.registerNetworkEntity(701, 7001)
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 701, true, 999)
    t.equals(#f.attachCalls, 1)
    t.equals(#f.moveRateCalls, 0)
end)

t.test('dragEnded: detaches, restores an NPC target\'s move rate, ignores a stale/foreign event for a DIFFERENT targetNetId', function()
    local f = newCombatFixture({ propDragging = true })
    f.registerNetworkEntity(702, 7002)
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 702, false, 999)

    f.dispatchNetEvent('john-k9:client:dragEnded', 65535, 999999, 'released_by_holder') -- foreign targetNetId
    t.isTrue(f.env.IsDragEngaged(), 'a stale/foreign dragEnded must never clear a DIFFERENT drag\'s state')

    f.dispatchNetEvent('john-k9:client:dragEnded', 65535, 702, 'released_by_holder')
    t.isFalse(f.env.IsDragEngaged())
    t.equals(#f.detachCalls, 1)
    t.equals(#f.moveRateCalls, 2, 'the NPC\'s move rate must be restored to neutral on end')
    t.equals(f.moveRateCalls[2].rate, 1.0)
end)

-- ========================================================================
-- PRIORITY #1 -- THE SUPPRESSION MAINTENANCE THREAD'S promise+SetTimeout
-- CANCELLABLE WAIT. Three properties, proven together in one coherent
-- scenario per the plan this task named: resolves once and only once, an
-- unwoken wait still resolves on its own timeout, and a grant wakes a
-- parked wait early.
-- ========================================================================

t.test('CANCELLABLE WAIT: an idle thread registers exactly one coarse-wait SetTimeout, and does not yield (it reaches the idle branch on its very first tick)', function()
    local f = newCombatFixture()
    local co = f.startMaintenanceThread()
    t.equals(f.pendingTimeoutCount(), 1)
    t.equals(coroutine.status(co), 'dead', 'an idle first tick must run to completion, never yield')
end)

t.test('CANCELLABLE WAIT: an UNWOKEN coarse wait still resolves on its own timeout, and the tick genuinely continues (re-registers a fresh coarse wait)', function()
    local f = newCombatFixture()
    f.startMaintenanceThread()
    local before = f.gameTimerCallCount()

    f.fireTimeout(1)
    t.equals(f.gameTimerCallCount(), before + 1, 'exactly one more MaintenanceTick body ran')
    t.equals(f.pendingTimeoutCount(), 1, 'still idle -- a fresh coarse-wait SetTimeout was re-registered')
end)

t.test('CANCELLABLE WAIT: a grant (applyBiteHold) wakes a parked idle wait EARLY, via a SEPARATE SetTimeout(0, ...), not by touching the original one', function()
    local f = newCombatFixture()
    f.startMaintenanceThread() -- registers pendingTimeouts[1], the coarse wait
    t.equals(f.pendingTimeoutCount(), 1)

    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999) -- calls WakeMaintenanceThread()
    t.equals(f.pendingTimeoutCount(), 2, 'the wake schedules its OWN fresh SetTimeout(0, ...), alongside the still-pending original')

    local disableCallsAfterBridge = #f.disableControlCalls -- the bridge call in applyBiteHold itself already fired 2

    local co = f.fireTimeout(2) -- fire the WAKE timeout specifically (index 2)
    t.equals(#f.disableControlCalls, disableCallsAfterBridge + 2, 'the resumed tick must have reasserted the bite-hold controls -- proves the wake genuinely resumed MaintenanceTick, not just cleared a flag')
    t.equals(coroutine.status(co), 'suspended', 'ActiveBiteHold is still active, so this resumed tick must be parked on its own Wait(0), not have run to completion')
end)

t.test('CANCELLABLE WAIT: THE PROMISE RESOLVES ONCE AND ONLY ONCE -- the original, now-superseded coarse-wait timeout is inert once it also eventually fires', function()
    local f = newCombatFixture()
    f.startMaintenanceThread()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999)
    t.equals(f.pendingTimeoutCount(), 2)

    f.fireTimeout(2) -- consume the wake timeout first, exactly as the previous test does
    local gameTimerAfterWake = f.gameTimerCallCount()
    local disableCallsAfterWake = #f.disableControlCalls

    -- The ORIGINAL coarse-wait timeout (now index 1, the only one left) is
    -- STALE: PendingMaintenanceWaitPromise was already claimed and nulled by
    -- the wake path above. Firing it must be a genuine no-op -- no new tick,
    -- no new native calls -- proving the underlying promise really did
    -- resolve exactly once, not twice.
    t.equals(f.pendingTimeoutCount(), 1)
    f.fireTimeout(1)
    t.equals(f.gameTimerCallCount(), gameTimerAfterWake, 'a stale, superseded timeout must never cause a second tick')
    t.equals(#f.disableControlCalls, disableCallsAfterWake, 'a stale, superseded timeout must never cause a second reassertion')
end)

t.test('WakeMaintenanceThread: a second grant landing BEFORE the first wake has actually fired schedules its OWN second SetTimeout -- but only the FIRST one to fire ever resumes the tick, the second is inert', function()
    local f = newCombatFixture({ propDragging = true })
    f.startMaintenanceThread()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999) -- first wake scheduled
    t.equals(f.pendingTimeoutCount(), 2)

    f.registerNetworkEntity(710, 7100)
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 710, false, 999) -- second grant, same instant
    t.equals(f.pendingTimeoutCount(), 3, 'WakeMaintenanceThread\'s own early-return guard only protects against waking when truly nothing is parked -- it does NOT deduplicate two back-to-back wakes racing for the same still-parked slot, so a second, genuinely separate SetTimeout(0, ...) is scheduled here too')

    local before = f.gameTimerCallCount()
    f.fireTimeout(2) -- whichever wake fires FIRST
    t.equals(f.gameTimerCallCount(), before + 1, 'exactly one tick ran')

    f.fireTimeout(2) -- the SECOND, now-stale wake (re-indexed to slot 2 after the first was consumed)
    t.equals(f.gameTimerCallCount(), before + 1, 'the second, now-stale wake must be inert -- by the time it fires, PendingMaintenanceWaitPromise is already nil, proving the resolve-once guarantee holds even across two independently-scheduled wakes for the same parked slot, not just a wake racing the original coarse timeout')
end)

t.test('BACKSTOP STARVATION FIX: an idle-class effect\'s (ActiveForcedRagdoll) expired backstop fires in the SAME tick as an active Wait(0)-class effect (ActiveBiteHold) -- neither effect gates the other\'s own processing', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999) -- Wait(0)-class -- the bridge call already fires 2 DisableControlAction calls here
    f.dispatchNetEvent('john-k9:client:forceRagdoll', 65535, 999) -- idle-class, own backstop only
    t.equals(#f.canBeDamagedCalls, 1)
    local disableCallsBeforeTick = #f.disableControlCalls

    f.advance(baselineTakedownConfig().ragdollDurationMs + 1) -- past ActiveForcedRagdoll's own deadline
    f.startMaintenanceThread()

    t.equals(#f.disableControlCalls, disableCallsBeforeTick + 2, 'ActiveBiteHold\'s own reassertion must still have run this tick')
    t.equals(#f.canBeDamagedCalls, 2, 'ActiveForcedRagdoll\'s own expired backstop must ALSO have fired in the SAME tick -- the historical bug this fix closed had it starved for as long as a Wait(0)-class effect stayed active')
    t.equals(f.canBeDamagedCalls[2].canBeDamaged, true)
end)

-- ========================================================================
-- PRIORITY #3 -- OWN-DEATH HANDLING. The session's "HOLDER-DEATH LIFECYCLE
-- FIX" (ActiveDragAsHolder, ActiveNpcEffects), plus the pre-existing
-- target-side guards (ActiveBiteHold, ActiveForcedRagdoll,
-- ActiveDragSpeedLimit) these mirror.
-- ========================================================================

t.test('OWN-DEATH (holder, drag): the K9\'s own death mid-drag reports it, detaches, restores an NPC target\'s move rate, and clears ActiveDragAsHolder in the SAME tick -- no further AttachEntityToEntity reassertion', function()
    local f = newCombatFixture({ propDragging = true })
    f.registerNetworkEntity(800, 8000)
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 800, false, 999)
    t.equals(#f.attachCalls, 1, 'sanity: the bridge call already attached once')

    f.setDead(1, true) -- the K9's OWN ped (PlayerPedId() == 1 by default)
    f.startMaintenanceThread()

    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:reportHolderDied')
    t.equals(#f.detachCalls, 1)
    t.equals(f.moveRateCalls[#f.moveRateCalls].rate, 1.0)
    t.isFalse(f.env.IsDragEngaged())
    t.equals(#f.attachCalls, 1, 'no further AttachEntityToEntity re-assertion once the holder\'s own death is detected -- the death branch replaces the reassertion branch, it does not run alongside it')
end)

t.test('OWN-DEATH (holder, NPC-relay effects): the K9\'s own death reports ONCE even with TWO simultaneous NPC effects active, and restores each correctly by kind', function()
    local f = newCombatFixture()
    f.registerNetworkEntity(801, 8001)
    f.registerNetworkEntity(802, 8002)
    f.dispatchNetEvent('john-k9:client:applyNpcBiteHold', 65535, 801, 999)
    f.dispatchNetEvent('john-k9:client:applyNpcTakedown', 65535, 802, 999)

    f.setDead(1, true)
    f.startMaintenanceThread()

    local reportCount = 0
    for _, e in ipairs(f.serverEvents) do
        if e.event == 'john-k9:server:reportHolderDied' then reportCount = reportCount + 1 end
    end
    t.equals(reportCount, 1, 'exactly one report, even with two simultaneous NPC-relay effects held by the same client')
    t.equals(f.blockingCalls[#f.blockingCalls].blocking, false, 'the bite-kind NPC effect must be restored (flee-suppression lifted)')
    t.equals(f.canBeDamagedCalls[#f.canBeDamagedCalls].canBeDamaged, true, 'the takedown-kind NPC effect must be restored (damageable again)')
end)

t.test('OWN-DEATH (target, ActiveBiteHold): the bitten target\'s own death reports it and stops reasserting sprint/attack suppression', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:applyBiteHold', 65535, 12345, 999)
    local callsBeforeDeath = #f.disableControlCalls

    f.setDead(1, true)
    f.startMaintenanceThread()

    t.equals(f.lastServerEvent().event, 'john-k9:server:reportBiteHoldTargetDied')
    t.equals(#f.disableControlCalls, callsBeforeDeath, 'no further reassertion once death is detected')
end)

t.test('OWN-DEATH (target, ActiveForcedRagdoll): death immediately restores damageability, same as the timeout backstop', function()
    local f = newCombatFixture()
    f.dispatchNetEvent('john-k9:client:forceRagdoll', 65535, 999)
    f.setDead(1, true)
    f.startMaintenanceThread()
    t.equals(f.canBeDamagedCalls[#f.canBeDamagedCalls].canBeDamaged, true)
end)

t.test('OWN-DEATH (target, ActiveDragSpeedLimit): death restores move rate to neutral and defensively detaches', function()
    local f = newCombatFixture({ propDragging = true })
    f.setIsOwnModelK9(false)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)
    f.setDead(1, true)
    f.startMaintenanceThread()
    t.equals(f.moveRateCalls[#f.moveRateCalls].rate, 1.0)
    t.isTrue(#f.detachCalls >= 1)
end)

-- REGRESSION (ANY-PED SWEEP FIX, this pass) -- same shape as the
-- applyDragSpeedLimit/endDragSpeedLimit regression above, for the shared
-- maintenance thread's OWN-DEATH and timeout-backstop branches
-- specifically (both were ALSO gated on bare IsOwnModelK9() before this
-- fix, and both restore-to-neutral, same real bug class: a HasK9Access()
-- role-holder's own composed fatigue/injury/mood would have been
-- clobbered by a raw SetPedMoveRateOverride(ped, 1.0) instead of being
-- correctly re-composed).
t.test('OWN-DEATH (target, ActiveDragSpeedLimit): a HasK9Access()-true off-model target ALSO restores through the composer, not a raw override', function()
    local f = newCombatFixture({ propDragging = true, withMoveRateComposer = true })
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)
    f.setDead(1, true)
    f.startMaintenanceThread()
    t.equals(#f.moveRateCalls, 0, 'must not call SetPedMoveRateOverride directly on own-death restore')
    t.equals(f.K9MoveRateModifiers.dragging, 1.0)
    t.isTrue(#f.detachCalls >= 1)
end)

t.test('TIMEOUT BACKSTOP (target, ActiveDragSpeedLimit): a HasK9Access()-true off-model target restores through the composer on expiry too, not just on the explicit end event', function()
    local f = newCombatFixture({ propDragging = true, withMoveRateComposer = true })
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)
    t.equals(f.recomputeCallCount(), 1, 'the onset bridge call must already have gone through the composer')

    f.advance(baselinePropDraggingConfig().maxDragDurationMs + 1)
    f.startMaintenanceThread()

    t.equals(#f.moveRateCalls, 0, 'the expiry backstop must also route through the composer, not a raw override')
    -- 3, not 2: this single tick both reasserts (AssertDragSpeedLimitOnTarget,
    -- +1 recompute) AND then observes the expired deadline and restores
    -- (+1 recompute) -- on top of the onset bridge call (+1) already
    -- counted above. Reassertion-before-backstop-check is this thread's
    -- own existing, unchanged per-tick order (see "SHARED MAINTENANCE
    -- THREAD" header) -- this test counts the real total, not a guessed one.
    t.equals(f.recomputeCallCount(), 3)
    t.equals(f.K9MoveRateModifiers.dragging, 1.0)
end)

-- ========================================================================
-- onResourceStop restore -- persistent-flag natives must never survive a
-- resource restart mid-effect.
-- ========================================================================

t.test('onResourceStop: restores damageability, drag attachment, NPC flee/damage flags, and move rate -- all in one pass, resourceName-gated', function()
    local f = newCombatFixture({ propDragging = true })
    f.dispatchNetEvent('john-k9:client:forceRagdoll', 65535, 999)
    f.registerNetworkEntity(900, 9000)
    f.dispatchNetEvent('john-k9:client:applyNpcBiteHold', 65535, 900, 999)
    f.registerNetworkEntity(901, 9001)
    f.dispatchNetEvent('john-k9:client:dragStarted', 65535, 901, false, 999)
    f.setIsOwnModelK9(false)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)

    f.fireResourceStop('some_other_resource')
    local canBeDamagedBefore = #f.canBeDamagedCalls

    f.fireResourceStop(RESOURCE_NAME)
    t.isTrue(#f.canBeDamagedCalls > canBeDamagedBefore, 'ActiveForcedRagdoll must be restored on a genuine stop')
    t.equals(f.canBeDamagedCalls[#f.canBeDamagedCalls].canBeDamaged, true)
    t.isTrue(#f.detachCalls >= 2, 'both the drag holder\'s target AND this client\'s own drag-speed-limited ped must be detached')
    t.equals(f.moveRateCalls[#f.moveRateCalls].rate, 1.0)
end)

-- REGRESSION (ANY-PED SWEEP FIX, this pass) -- same "restore through the
-- composer, not a raw override" fix, for the onResourceStop cleanup path.
-- Cleanup/termination paths are never GATED on an access check (this one
-- isn't -- it still unconditionally restores for every caller); the fix
-- here is only about WHICH restore mechanism a HasK9Access()-true,
-- off-model caller gets, exactly like every other call site above.
t.test('onResourceStop: a HasK9Access()-true off-model ActiveDragSpeedLimit target restores through the composer too', function()
    local f = newCombatFixture({ propDragging = true, withMoveRateComposer = true })
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.dispatchNetEvent('john-k9:client:applyDragSpeedLimit', 65535, 999)

    f.fireResourceStop(RESOURCE_NAME)

    t.equals(#f.moveRateCalls, 0, 'must not call SetPedMoveRateOverride directly on resource-stop restore')
    t.equals(f.K9MoveRateModifiers.dragging, 1.0)
    t.isTrue(#f.detachCalls >= 1)
end)

-- ========================================================================
-- WHAT THIS FILE DOES NOT COVER, AND WHY (per this task's own instruction
-- to disclose uncovered paths rather than silently skip them):
--
--   - PlayBiteHoldStance()'s exact per-breed scenario mapping -- purely
--     cosmetic, and this fixture's GetEntityModel stub always returns 0
--     (falling back to the default scenario every time). No assertion is
--     made on TaskStartScenarioInPlace's scenario-name argument anywhere.
--   - NetworkRequestControlOfEntity's own best-effort, unconfirmed-success
--     semantics -- this spec only proves the call HAPPENS (matching the
--     file's own honestly-disclosed "fire and forget, never gated on
--     NetworkHasControlOfEntity" design), never that "control" was
--     genuinely granted, which the production file itself explicitly
--     states cannot be verified from inside this codebase.
--   - The EXACT fidelity gap between forceRagdoll's player-target forward
--     vector (the TARGET's own client) and applyNpcTakedown's NPC-target
--     forward vector (the K9's own client) -- both are proven to thread
--     GetEntityForwardVector(PlayerPedId())'s value through correctly in
--     isolation, but distinguishing WHICH client's PlayerPedId() a given
--     handler reads would need a genuine two-client simulation this single-
--     sandbox fixture does not attempt (see this file's own "RAGDOLL
--     FALL-DIRECTION" header comment for the disclosed difference itself).
--   - DragExceedsMaxDistance / the drag max-distance safety valve, and the
--     ActiveNpcEffects/ActiveDragAsHolder/ActiveForcedRagdoll TIMEOUT
--     backstops (as opposed to their OWN-DEATH branches, which are this
--     task's named priority and are covered above) -- these mirror
--     already-covered shapes (a deadline check + restore) and were not
--     independently exercised for every single state to keep this file's
--     size proportionate to the task's five named priorities.
--   - client/vehicle.lua's OWN symmetric mutual-guard half (the reverse
--     ordering: drag/hold first, then "Enter Vehicle") -- that guard lives
--     in a file this spec does not own or load.
--   - Exact multi-candidate tie-breaking in FindNearestCombatTarget /
--     FindNearestDraggableCandidate beyond "the nearer of two candidates
--     wins" (exercised once, in RequestBiteHold's happy-path test above).
-- ========================================================================

os.exit(t.summary())
