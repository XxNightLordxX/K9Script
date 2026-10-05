--[[
    tests/vehiclecombatguard_spec.lua

    Regression coverage for a QA-reported real defect (originally found when
    both files still shared the SAME ped via attach): with all of
    Config.Features' combat flags on (the shipped default as of this spec's
    authoring — config.lua's Config.Features.VehicleEntryExit/BiteAndHold/
    NonLethalTakedown/PropDragging are all `true`), a K9 could grab the SAME
    ped (its own PlayerPedId()) via two independent, mutually-unaware
    mechanics: client/vehicle.lua's EnterNearestK9Vehicle() (at the time,
    freeze/hide/disable-collision/attach the ped TO a vehicle as its CHILD;
    a LATER pass replaced this with real SET_PED_INTO_VEHICLE seating — see
    that file's own header — but the underlying guard this spec covers is
    unaffected: entering a vehicle, attach-based or real-seat-based, still
    puts the SAME ped's control state at odds with combat.lua's per-tick
    holder-anchor attach, just via a different concrete mechanism) and
    client/combat.lua's PropDragging holder-side maintenance loop (attach a
    dragged target TO that SAME ped as its PARENT, every tick) or BiteAndHold
    holder-side stance. Neither direction had a guard. This spec pins down
    both new guards this pass adds:
      1. client/vehicle.lua's EnterNearestK9Vehicle() now refuses while
         client/combat.lua reports an active drag (IsDragEngaged()) or bite
         hold (IsBiteHoldEngaged()) as HOLDER.
      2. client/combat.lua's RequestBiteHold()/RequestTakedown()/
         RequestDrag() now refuse while client/vehicle.lua reports the K9 as
         currently tucked into a vehicle (IsInK9Vehicle()).
    Both guards are a `type(fn) == 'function' and fn()` SOFT DEPENDENCY (this
    resource's established convention — see every client file's identical
    guard on IsBiteHoldEngaged, and client/agility.lua's/client/movement.lua's
    own `IsInK9Vehicle and IsInK9Vehicle()` guards on that exact global) —
    each direction is therefore tested BOTH with the other file's global
    present-and-controllable AND entirely absent (simulating a server that
    runs one feature without the other), proving the guard degrades cleanly
    rather than erroring when the sibling feature is off.

    TWO SEPARATE, INDEPENDENT SANDBOXES (not one combined load of both real
    files together): the soft-dependency shape above means each production
    file only ever needs the OTHER file's query function as a plain
    controllable stub, never the other file's full native surface (which
    would mean stubbing client/combat.lua's `NetworkRequestControlOfEntity`/
    `SetPedToRagdollWithFall`/`promise`/`SetTimeout`/etc. just to load
    client/vehicle.lua, or vice versa) — this mirrors exactly how the real
    production code itself treats the dependency (a query call behind a
    runtime existence check, never a hard `require`).

    THIS SPEC'S OWN FIXED BASELINE (same real concurrency incident
    tests/clientradial_spec.lua's and tests/clientvision_spec.lua's own
    headers document): config.lua is edited by other agents while this
    suite runs, so both fixtures below pin every feature flag this spec
    depends on to a known value BEFORE applying `opts.features`, rather than
    trusting whatever config.lua's live defaults happen to be at the moment
    a given test runs.

    LOCALE KEYS THIS SPEC DEPENDS ON, NOT YET LANDED AS OF THIS PASS
    (client/vehicle.lua and client/combat.lua are this task's owned files;
    locales/en.json is not — reported to whoever owns it rather than edited
    here): `vehicle.blocked_by_drag`, `vehicle.blocked_by_bite_hold`,
    `combat.blocked_by_vehicle`. Every test below that exercises a BLOCKED
    path calls the real `locale()` against the real `locales/en.json`
    (DEVELOPER_REFERENCE.md's own documented behavior) and will fail loudly with
    "locale key missing from locales/en.json: ..." until those three keys
    are added — this is the correctly-working, documented "Cause B" signal
    DEVELOPER_REFERENCE.md describes, not a bug in this spec or in the two
    production files, and every such failure is expected to clear the
    moment those keys land with no code change needed here.

    FIXTURE NOTE (this pass — real seating made EnterNearestK9Vehicle()'s own
    entry sequence asynchronous, door-open delay then seat then door-shut,
    each a CreateThread'd coroutine rather than one synchronous call): the
    vehicle fixture's CreateThread stub CAPTURES coroutines rather than
    running them, and exposes runLatestThreadToCompletion() to explicitly
    drive just the freshest one to completion. This is deliberate, not
    incidental — client/vehicle.lua's own file-load-time watchdog thread is
    ALSO created via CreateThread (a `while true do ... end` loop with no
    exit), so a naive "run every captured function synchronously" stub would
    hang this whole spec the moment Sandbox.loadInto() loads that file. Every
    test that expects a successful, unblocked entry calls
    runLatestThreadToCompletion() right after f.env.EnterNearestK9Vehicle();
    every test that expects a GUARD to block entry does not (no new thread is
    ever created on that path, so there is nothing to run, and calling it
    would incorrectly touch the watchdog coroutine instead).

    WHAT THIS SPEC DOES NOT COVER: the two production files' PRE-EXISTING
    behavior (EnterNearestK9Vehicle's IsPedInAnyVehicle check, seat-picking/
    door-mapping, ExitK9Vehicle, the vehicle-lifecycle/own-death watchdog
    thread, RequestBiteHold/
    RequestTakedown/RequestDrag's own no-target-in-range path, the shared
    maintenance thread's per-tick reassertion) is untested here — this file
    is scoped tightly to the ONE new cross-file interaction this pass adds,
    per this task's own "keep your new cases in a file you own, don't
    collide with a concurrently-written client movement/combat spec"
    instruction. Full behavioral coverage of client/vehicle.lua and
    client/combat.lua beyond this specific guard is a separate, larger gap
    this spec does not attempt to close.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Shared fixtures -- Vec3 stand-in (identical shape to combat_spec.lua's/
-- defense_spec.lua's own copies) and the deterministic GetHashKey stand-in
-- (identical formula to main_spec.lua's/kennel_spec.lua's own copies).
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

local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

-- ----------------------------------------------------------------------
-- client/vehicle.lua fixture
-- ----------------------------------------------------------------------

--- @param opts { features: table?, isDragEngaged: boolean?, isBiteHoldEngaged: boolean?, omitCombatGlobals: boolean?, vehicleNearby: boolean?, isPedInAnyVehicle: boolean? }?
local function newVehicleFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- HasK9Access() -- PERMISSION AUDIT FOLLOW-UP (this pass): see
    -- tests/clientvehicle_spec.lua's own newVehicleFixture for the identical
    -- addition and its full writeup. Default `true`, same "happy path is
    -- the default" convention canShowK9UI above already established.
    local hasK9Access = true
    local function HasK9Access() return hasK9Access end

    local isPedInAnyVehicle = opts.isPedInAnyVehicle or false
    local function IsPedInAnyVehicle(_ped, _bool) return isPedInAnyVehicle end

    local function PlayerPedId() return 1 end
    local myCoords = vec3(0.0, 0.0, 0.0)
    local vehicleModelName = 'police'
    local vehicleEntity = 99
    local vehiclePresent = opts.vehicleNearby
    if vehiclePresent == nil then vehiclePresent = true end

    local function GetEntityCoords(entity)
        if entity == 1 then return myCoords end
        if entity == vehicleEntity then return vec3(1.0, 0.0, 0.0) end
        return vec3(0.0, 0.0, 0.0)
    end
    local function GetEntityModel(entity)
        if entity == vehicleEntity then return GetHashKey(vehicleModelName) end
        return GetHashKey('some_other_model')
    end
    local function GetGamePool(poolName)
        if poolName == 'CVehicle' and vehiclePresent then
            return { vehicleEntity }
        end
        return {}
    end
    local existingEntities = { [vehicleEntity] = true, [1] = true }
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(_entity) return false end

    -- REAL-SEAT FIXTURE (this pass — client/vehicle.lua no longer attaches/
    -- hides/freezes; it finds a real free seat, opens/shuts that seat's
    -- door, and SET_PED_INTO_VEHICLE's the ped). A standard 4-seat cruiser:
    -- GetVehicleMaxNumberOfPassengers = 3 -> valid seats -1..2. Every
    -- non-driver seat free by default -- this spec's own scope is the
    -- drag/bite-hold mutual guard, not seat-picking itself (that's
    -- tests/clientvehicle_spec.lua's job), so seat availability is not made
    -- independently controllable here.
    local function GetVehicleMaxNumberOfPassengers(_vehicle) return 3 end
    local function IsVehicleSeatFree(_vehicle, seatIndex) return seatIndex ~= -1 end
    local seatCalls, doorOpenCalls, doorShutCalls, networkControlCalls = {}, {}, {}, {}
    local function SetPedIntoVehicle(ped, vehicle, seatIndex)
        seatCalls[#seatCalls + 1] = { ped = ped, vehicle = vehicle, seatIndex = seatIndex }
    end
    local function SetVehicleDoorOpen(vehicle, doorIndex, loose, openInstantly)
        doorOpenCalls[#doorOpenCalls + 1] = { vehicle = vehicle, doorIndex = doorIndex, loose = loose, openInstantly = openInstantly }
    end
    local function SetVehicleDoorShut(vehicle, doorIndex, closeInstantly)
        doorShutCalls[#doorShutCalls + 1] = { vehicle = vehicle, doorIndex = doorIndex, closeInstantly = closeInstantly }
    end
    local function NetworkRequestControlOfEntity(entity)
        networkControlCalls[#networkControlCalls + 1] = entity
        return true
    end

    local function SetEntityCoords(...) end
    local function SetEntityHeading(...) end
    local function GetEntityHeading(...) return 0.0 end
    local function GetOffsetFromEntityInWorldCoords(entity, x, y, z) return vec3(x, y, z) end

    local netIdSeq = 0
    local netIdByEntity = {}
    local function NetworkGetNetworkIdFromEntity(entity)
        if not netIdByEntity[entity] then
            netIdSeq = netIdSeq + 1
            netIdByEntity[entity] = netIdSeq
        end
        return netIdByEntity[entity]
    end
    local function ResolveNetworkEntity(netId)
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- SEAT-RACE FIX (coder-frontend pass, out-of-scope mechanical patch --
    -- flagged to this file's owner rather than silently absorbed):
    -- client/vehicle.lua's EnterNearestK9Vehicle() now sends
    -- 'john-k9:server:requestVehicleSeatClaim' and waits for a real
    -- server grant (server/vehicle.lua, NEW FILE) before touching any door/
    -- seat native at all -- see that file's own EVENT/CALLBACK CONTRACT
    -- header. Without RegisterNetEvent/TriggerServerEvent stubs, loading the
    -- real client/vehicle.lua here throws at load time
    -- ("attempt to call a nil value (global 'RegisterNetEvent')"), taking
    -- every test in this whole file down with it -- this addition is the
    -- minimal, mechanical fix for that, mirroring
    -- tests/clientvehicle_spec.lua's own fixture shape exactly (same
    -- capture-and-echo-back-verbatim grantSeatClaim() helper). No existing
    -- assertion's INTENT changes: every test that expected a successful,
    -- unblocked entry now also calls grantSeatClaim() once, between
    -- EnterNearestK9Vehicle() and runLatestThreadToCompletion() -- see
    -- those two call sites below for the two lines this added.
    local netEvents = {}
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end
    local serverEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        serverEventCalls[#serverEventCalls + 1] = { event = eventName, args = { ... } }
    end

    -- CAPTURE, DON'T AUTO-RUN: client/vehicle.lua's own file-load-time
    -- watchdog thread (a `while true do ... end` loop) is created via
    -- CreateThread the moment Sandbox.loadInto() below executes this file --
    -- naively running every captured function synchronously would hang this
    -- spec forever inside that loop (Wait() below is a no-op, so nothing
    -- would ever actually suspend it). Threads are captured as coroutines
    -- instead, and ONLY explicitly driven ones are ever resumed --
    -- runLatestThreadToCompletion() below drives just the most-recently
    -- created one (EnterNearestK9Vehicle()'s own one-shot, terminating
    -- door-open/seat/door-shut sequence, created fresh by each call this
    -- spec makes), never the watchdog captured at load time. This spec's own
    -- header already scopes the watchdog thread itself as untested here.
    local capturedThreads = {}
    local function CreateThread(fn)
        capturedThreads[#capturedThreads + 1] = coroutine.create(fn)
    end
    local function Wait(_ms) coroutine.yield() end
    local RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- client/vehicle.lua now routes its "Load Into Vehicle"/"Release From
    -- Vehicle" options through K9Compat.Get('target')
    -- (shared/compat/target.lua) rather than calling `exports.ox_target`
    -- directly -- see that file's own header. This spec loads the REAL
    -- shared/compat/core.lua + shared/compat/target.lua (never a
    -- hand-written fake translation layer, which would just assert against
    -- itself) so K9Compat.Get('target') resolves to the REAL ox_target
    -- adapter, which is a byte-for-byte pass-through of the options table
    -- this file already captures below via the exact same colon-call
    -- `exports.ox_target:addGlobalVehicle` stub as before -- ox_target is
    -- the ONLY candidate this fixture makes `GetResourceState` report as
    -- 'started', so detection deterministically resolves to it. Every
    -- REQUIRED_EXPORTS name (shared/compat/target.lua's OxTargetFactory)
    -- must exist as a callable function or the whole adapter is rejected as
    -- unverified and silently falls back to the no-op stub -- every
    -- `remove*` name and `addLocalEntity`/`removeLocalEntity` below is never
    -- actually called by anything this spec exercises, but must still exist.
    local addGlobalVehicleCalls = {}
    local exportsTable = {
        ox_target = {
            addGlobalVehicle = function(_self, options) addGlobalVehicleCalls[#addGlobalVehicleCalls + 1] = options end,
            addGlobalPlayer = function() end,
            addGlobalObject = function() end,
            addModel = function() end,
            addSphereZone = function() end,
            removeGlobalPlayer = function() end,
            removeGlobalVehicle = function() end,
            removeGlobalObject = function() end,
            removeModel = function() end,
            removeZone = function() end,
            addLocalEntity = function() end,
            removeLocalEntity = function() end,
        },
    }
    local function IsDuplicityVersion() return false end -- client realm, for shared/compat/core.lua
    local function GetResourceState(resourceName)
        return resourceName == 'ox_target' and 'started' or 'missing'
    end

    -- The two soft-dependency globals this spec exists to exercise -- see
    -- this file's own header. `omitCombatGlobals` simulates
    -- client/combat.lua never having loaded at all (every combat feature
    -- flag off), in which case neither global exists as anything, not even
    -- a stub that returns false.
    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        PlayerPedId = PlayerPedId,
        GetHashKey = GetHashKey,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        GetGamePool = GetGamePool,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        GetVehicleMaxNumberOfPassengers = GetVehicleMaxNumberOfPassengers,
        IsVehicleSeatFree = IsVehicleSeatFree,
        SetPedIntoVehicle = SetPedIntoVehicle,
        SetVehicleDoorOpen = SetVehicleDoorOpen,
        SetVehicleDoorShut = SetVehicleDoorShut,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        SetEntityCoords = SetEntityCoords,
        SetEntityHeading = SetEntityHeading,
        GetEntityHeading = GetEntityHeading,
        GetOffsetFromEntityInWorldCoords = GetOffsetFromEntityInWorldCoords,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        lib = { notify = lib_notify },
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        TriggerServerEvent = TriggerServerEvent,
        CreateThread = CreateThread,
        Wait = Wait,
        GetCurrentResourceName = GetCurrentResourceName,
        exports = exportsTable,
        IsDuplicityVersion = IsDuplicityVersion,
        GetResourceState = GetResourceState,
        -- Menu-parity pass (this session): client/vehicle.lua now also
        -- registers a 'k9vehicle' chat command (RegisterCommand) alongside
        -- its existing ox_target option / resource-globals -- a plain no-op
        -- stub, same shape as every other fixture in this suite that loads a
        -- production file registering a command it does not itself need to
        -- exercise (e.g. tests/tabletlocalization_spec.lua's own
        -- newFixture()).
        RegisterCommand = function(_name, _handler, _restricted) end,
    }

    if not opts.omitCombatGlobals then
        if opts.isDragEngaged ~= nil then
            overrides.IsDragEngaged = function() return opts.isDragEngaged end
        end
        if opts.isBiteHoldEngaged ~= nil then
            overrides.IsBiteHoldEngaged = function() return opts.isBiteHoldEngaged end
        end
    end

    local env = Sandbox.newEnv(overrides)

    Sandbox.loadInto('../config.lua', env)

    env.Config.Features.VehicleEntryExit = true
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end
    env.Config.K9Vehicles = { vehicleModelName }
    env.Config.VehicleInteractMeters = 3.0

    -- Real K9Compat, real ox_target adapter -- see the `exportsTable`
    -- comment above for why. Must load before client/vehicle.lua, which
    -- reads the `K9Compat` global at RegisterVehicleOxTargetOptions() call
    -- time (fired below via fireOwnResourceStart / f.env.EnterNearestK9Vehicle
    -- tests don't need it, but the "Load Into Vehicle" option tests do).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/target.lua', env)

    Sandbox.loadInto('../client/vehicle.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        seatCalls = seatCalls,
        doorOpenCalls = doorOpenCalls,
        doorShutCalls = doorShutCalls,
        networkControlCalls = networkControlCalls,
        denyCalls = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        --- Fires the captured onResourceStart handler(s) (this resource's
        --- own name) so RegisterVehicleOxTargetOptions() actually runs and
        --- exports.ox_target:addGlobalVehicle's options get captured.
        fireOwnResourceStart = function()
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(RESOURCE_NAME)
            end
        end,
        addGlobalVehicleCalls = addGlobalVehicleCalls,
        --- Drives the MOST RECENTLY CreateThread'd coroutine to completion --
        --- see this fixture's own CreateThread stub comment for why only the
        --- latest one is ever touched (never the file-load-time watchdog).
        --- Call this immediately after f.env.EnterNearestK9Vehicle() actually
        --- created a new entry sequence (i.e. every guard above it passed) --
        --- bounded to 50 resumes so a genuine bug (an accidental infinite
        --- loop in the production sequence) fails loudly instead of hanging
        --- the whole test process.
        runLatestThreadToCompletion = function()
            local co = capturedThreads[#capturedThreads]
            if not co then return end
            local iterations = 0
            while coroutine.status(co) ~= 'dead' and iterations < 50 do
                local ok, err = coroutine.resume(co)
                if not ok then
                    error(('vehicle fixture: captured thread errored: %s'):format(tostring(err)))
                end
                iterations = iterations + 1
            end
        end,
        -- SEAT-RACE FIX -- see this fixture's own RegisterNetEvent/
        -- TriggerServerEvent comment above. Echoes the MOST RECENT
        -- requestVehicleSeatClaim call's own (vehicleNetId, seatIndex,
        -- token) back exactly as the real server always does.
        grantSeatClaim = function()
            local call
            for i = #serverEventCalls, 1, -1 do
                if serverEventCalls[i].event == 'john-k9:server:requestVehicleSeatClaim' then
                    call = serverEventCalls[i]
                    break
                end
            end
            assert(call, 'vehicle fixture: grantSeatClaim() called with no outstanding requestVehicleSeatClaim')
            env.source = 65535
            netEvents['john-k9:client:vehicleSeatClaimGranted'](call.args[1], call.args[2], call.args[3])
        end,
    }
end

-- ----------------------------------------------------------------------
-- client/combat.lua fixture -- ONLY what RequestBiteHold()/RequestTakedown()/
-- RequestDrag() and this file's own load-time top section touch. Does not
-- stub NetworkRequestControlOfEntity/SetPedToRagdollWithFall/promise/
-- SetTimeout/etc: CreateThread below never actually RUNS the captured shared
-- maintenance thread body (nor does any test here fire dragStarted/
-- applyBiteHold/applyDragSpeedLimit), so none of that surface is ever
-- reached -- see this file's own header "TWO SEPARATE, INDEPENDENT
-- SANDBOXES" note for why that is a deliberate, real property of the
-- soft-dependency shape being tested, not a shortcut.
-- ----------------------------------------------------------------------

--- @param opts { features: table?, isInK9Vehicle: boolean?, omitVehicleGlobal: boolean? }?
local function newCombatTriggerFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- HasK9Access() -- PERMISSION AUDIT FOLLOW-UP (this pass): RequestBiteHold/
    -- RequestTakedown/RequestDrag's own access gate was widened from
    -- CanShowK9UI() to HasK9Access() alone -- see client/combat.lua's own doc
    -- comment on each for the full writeup. Default `true`, same "happy path
    -- is the default" convention canShowK9UI above already established.
    local hasK9Access = true
    local function HasK9Access() return hasK9Access end

    local function PlayerPedId() return 1 end
    local myCoords = vec3(0.0, 0.0, 0.0)
    local otherPed = 42
    local function GetEntityCoords(entity)
        if entity == otherPed then return vec3(1.0, 0.0, 0.0) end
        return myCoords
    end
    local function GetGamePool(poolName)
        if poolName == 'CPed' then return { otherPed } end
        return {}
    end
    local function DoesEntityExist(entity) return entity == 1 or entity == otherPed end
    local function IsEntityDead(_entity) return false end

    local netIdSeq = 0
    local function NetworkGetNetworkIdFromEntity(_entity)
        netIdSeq = netIdSeq + 1
        return netIdSeq
    end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { eventName, ... }
    end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    -- Capturing-only, never invoked: this spec never fires
    -- dragStarted/applyBiteHold/applyDragSpeedLimit/etc, only the
    -- self-initiated RequestBiteHold/RequestTakedown/RequestDrag triggers,
    -- so the handler itself is never read back -- just needs to exist so
    -- this file's own `if Config.Features.X then RegisterNetEvent(...) end`
    -- blocks don't error at load time.
    local function RegisterNetEvent(_eventName, _handler) end
    local function CreateThread(_fn) end -- never run: this spec never exercises the shared maintenance thread
    local function AddEventHandler(_eventName, _handler) end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        PlayerPedId = PlayerPedId,
        GetHashKey = GetHashKey,
        GetEntityCoords = GetEntityCoords,
        GetGamePool = GetGamePool,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        TriggerServerEvent = TriggerServerEvent,
        lib = { notify = lib_notify },
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = CreateThread,
        AddEventHandler = AddEventHandler,
    }

    if not opts.omitVehicleGlobal and opts.isInK9Vehicle ~= nil then
        overrides.IsInK9Vehicle = function() return opts.isInK9Vehicle end
    end

    local env = Sandbox.newEnv(overrides)

    Sandbox.loadInto('../config.lua', env)

    env.Config.Features.BiteAndHold = true
    env.Config.Features.NonLethalTakedown = true
    env.Config.Features.PropDragging = true
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end

    Sandbox.loadInto('../client/combat.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
    }
end

-- ----------------------------------------------------------------------
-- Direction 1: client/vehicle.lua's EnterNearestK9Vehicle() refuses while
-- client/combat.lua reports an active drag/bite hold.
-- ----------------------------------------------------------------------

t.test('vehicle: EnterNearestK9Vehicle succeeds when neither drag nor bite hold is engaged', function()
    local f = newVehicleFixture({ isDragEngaged = false, isBiteHoldEngaged = false })
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim() -- SEAT-RACE FIX: the server round trip must be granted before the door/seat sequence even starts
    f.runLatestThreadToCompletion() -- drives the door-open/seat/door-shut sequence to completion
    t.equals(#f.doorOpenCalls, 1, 'should have opened the chosen seat door')
    t.equals(#f.seatCalls, 1, 'should have seated the ped for real (SET_PED_INTO_VEHICLE), not attached it')
    t.equals(#f.doorShutCalls, 1, 'should have shut the door again once seated')
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('vehicle.loaded'))
end)

t.test('vehicle: EnterNearestK9Vehicle refuses with a distinct notification while a drag is engaged', function()
    local f = newVehicleFixture({ isDragEngaged = true, isBiteHoldEngaged = false })
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.doorOpenCalls, 0, 'must not open a door while a drag is active')
    t.equals(#f.seatCalls, 0, 'must not seat the ped while a drag is active')
    t.equals(#f.doorShutCalls, 0)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('vehicle.blocked_by_drag'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('vehicle: EnterNearestK9Vehicle refuses with a distinct notification while a bite hold is engaged', function()
    local f = newVehicleFixture({ isDragEngaged = false, isBiteHoldEngaged = true })
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.doorOpenCalls, 0, 'must not open a door while a bite hold is active')
    t.equals(#f.seatCalls, 0, 'must not seat the ped while a bite hold is active')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('vehicle.blocked_by_bite_hold'))
end)

t.test('vehicle: drag is checked before bite hold when both are somehow engaged', function()
    local f = newVehicleFixture({ isDragEngaged = true, isBiteHoldEngaged = true })
    f.env.EnterNearestK9Vehicle()
    t.equals(f.notifyCalls[1].description, locale('vehicle.blocked_by_drag'))
end)

t.test('vehicle: the guard degrades cleanly (no error, enters normally) when client/combat.lua never loaded at all', function()
    local f = newVehicleFixture({ omitCombatGlobals = true })
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim() -- SEAT-RACE FIX
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'IsDragEngaged/IsBiteHoldEngaged being entirely absent globals must not block entry')
    t.isTrue(f.env.IsInK9Vehicle())
end)

t.test('vehicle: the ox_target "Load Into Vehicle" option hides itself while a drag is engaged (display optimization mirror)', function()
    local f = newVehicleFixture({ isDragEngaged = true, isBiteHoldEngaged = false })
    f.fireOwnResourceStart()
    t.equals(#f.addGlobalVehicleCalls, 1)
    local enterOption = f.addGlobalVehicleCalls[1][1]
    t.equals(enterOption.name, 'john-k9:enterVehicle')
    t.isFalse(enterOption.canInteract(99, 1.0, {}, 'police'))
end)

t.test('vehicle: the ox_target "Load Into Vehicle" option hides itself while a bite hold is engaged (display optimization mirror)', function()
    local f = newVehicleFixture({ isDragEngaged = false, isBiteHoldEngaged = true })
    f.fireOwnResourceStart()
    local enterOption = f.addGlobalVehicleCalls[1][1]
    t.isFalse(enterOption.canInteract(99, 1.0, {}, 'police'))
end)

t.test('vehicle: the ox_target "Load Into Vehicle" option is offered normally when neither is engaged', function()
    local f = newVehicleFixture({ isDragEngaged = false, isBiteHoldEngaged = false })
    f.fireOwnResourceStart()
    local enterOption = f.addGlobalVehicleCalls[1][1]
    t.isTrue(enterOption.canInteract(99, 1.0, {}, 'police'))
end)

-- ----------------------------------------------------------------------
-- Direction 2: client/combat.lua's self-initiated triggers refuse while
-- client/vehicle.lua reports the K9 as currently tucked into a vehicle.
-- This is the QA-reported real defect's OWN reverse-order case (enter
-- vehicle first, then request a drag/bite hold/takedown).
-- ----------------------------------------------------------------------

local function assertBlockedByVehicle(requestFnName)
    t.test(('combat: %s refuses with a notification while tucked into a vehicle'):format(requestFnName), function()
        local f = newCombatTriggerFixture({ isInK9Vehicle = true })
        f.env[requestFnName]()
        t.equals(#f.triggerServerEventCalls, 0, 'must never contact the server while tucked into a vehicle')
        t.equals(#f.notifyCalls, 1)
        t.equals(f.notifyCalls[1].description, locale('combat.blocked_by_vehicle'))
        t.equals(f.notifyCalls[1].type, 'error')
    end)

    t.test(('combat: %s proceeds normally when not in a vehicle'):format(requestFnName), function()
        local f = newCombatTriggerFixture({ isInK9Vehicle = false })
        f.env[requestFnName]()
        t.equals(#f.triggerServerEventCalls, 1, 'should have contacted the server with a real candidate target')
    end)

    t.test(('combat: %s degrades cleanly (no error, proceeds normally) when client/vehicle.lua never loaded at all'):format(requestFnName), function()
        local f = newCombatTriggerFixture({ omitVehicleGlobal = true })
        f.env[requestFnName]()
        t.equals(#f.triggerServerEventCalls, 1, 'IsInK9Vehicle being an entirely absent global must not block the request')
    end)
end

assertBlockedByVehicle('RequestBiteHold')
assertBlockedByVehicle('RequestTakedown')
assertBlockedByVehicle('RequestDrag')

os.exit(t.summary())
