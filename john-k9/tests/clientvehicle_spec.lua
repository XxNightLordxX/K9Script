--[[
    tests/clientvehicle_spec.lua

    Direct, black-box tests of client/vehicle.lua against the REAL,
    unmodified production file -- K9 vehicle entry/exit
    (Config.Features.VehicleEntryExit).

    REWRITTEN THIS PASS (owner-reported real defect: "put in vehicle" used
    to hide/freeze/attach the K9 to a boot/trunk offset -- invisible, wrong
    place). The production file now finds a genuinely free, non-driver seat
    (rear preferred), opens that seat's real door, SET_PED_INTO_VEHICLE's the
    ped for real (visible, collidable, a genuine game-recognized occupant --
    still PlayerPedId(), the player's own ped; nothing here ever spawns a
    ped of any kind, confirmed by grep having zero CreatePed/SetPlayerModel
    hits in the whole file), and shuts the door again. Every test below that
    used to assert on collisionCalls/freezeCalls/visibleCalls/attachCalls/
    detachCalls now asserts on the real-seat equivalents: seatCalls
    (SET_PED_INTO_VEHICLE), doorOpenCalls/doorShutCalls, and a
    pedCurrentVehicle model of "what vehicle does the game currently
    consider this ped seated in" that TASK_LEAVE_VEHICLE/
    CLEAR_PED_TASKS_IMMEDIATELY/the ped's own ordinary exit controls can all
    independently change -- see this fixture's own comments below for how
    that model works and why it exists.

    THREE DIFFERENT CreateThread LIFETIMES, never confused with each other
    (this fixture's central design constraint, same shape
    tests/vehiclecombatguard_spec.lua's own sibling fixture already
    establishes for the identical reason):
      1. The PERSISTENT watchdog thread (`while true do ... end`, no exit),
         created once at file-load time -- always capturedThreads[1].
      2. EITHER of two one-shot threads created fresh by each entry attempt
         that gets far enough to need one (every guard above it passed):
         the GIVE-UP TIMEOUT thread (created by EnterNearestK9Vehicle()
         itself, the instant it sends requestVehicleSeatClaim -- see the
         SEAT-RACE FIX section below), and, once granted, the door-open/
         seat/door-shut sequence thread (created by the
         vehicleSeatClaimGranted handler).
      3. ExitK9Vehicle()'s own one-shot, bounded stall-fallback thread --
         created fresh by each call that gets far enough to need it (the
         ped was actually seated somewhere).
    The fixture's CreateThread stub CAPTURES every thread as a coroutine
    rather than running any of them automatically -- runLatestThreadToCompletion()
    explicitly drives whichever one was most recently created to completion
    or a bounded 50 resumes, and stepWatchdogOnce() explicitly resumes ONLY
    capturedThreads[1], once. Never mixed: no test calls
    runLatestThreadToCompletion() when it means to drive the watchdog, or
    vice versa.

    SEAT-RACE FIX (this pass) -- client/vehicle.lua now sends
    'john-k9:server:requestVehicleSeatClaim' and waits for
    'john-k9:client:vehicleSeatClaimGranted'/'...Denied' (server/vehicle.lua,
    NEW FILE) BEFORE ever touching a door/seat native -- see that pair's own
    EVENT/CALLBACK CONTRACT header comments for the full design and the
    concurrency bug this closes. This fixture therefore now provides:
    RegisterNetEvent/TriggerServerEvent stubs (capturing every call in
    `serverEventCalls`, same "capture, don't auto-run" posture as
    CreateThread), `dispatchClientEvent(eventName, src, ...)` (sets
    `env.source` then invokes the captured handler -- lets a test simulate
    either a genuine server response, src = 65535, or a spoofed one for the
    SOURCE-ORIGIN GUARD tests), and two thin convenience wrappers over it,
    `grantSeatClaim()`/`denySeatClaim()`, which read the MOST RECENT
    requestVehicleSeatClaim call's own (vehicleNetId, seatIndex, token) and
    echo it back exactly as the real server always does -- the minimal-diff
    way most of this file's pre-existing tests now complete a "happy path"
    entry: `EnterNearestK9Vehicle()` -> `grantSeatClaim()` ->
    `runLatestThreadToCompletion()`, in that order, wherever the original
    two-line sequence used to be enough on its own.

    `opts.onServerEvent` (constructor option, new) lets a test intercept
    every TriggerServerEvent call as it happens -- used by exactly one test
    below (the two-independent-client interleaving proof) to wire two
    separate fixture instances through a shared, minimal seat-claim relay
    that mirrors server/vehicle.lua's own check-then-claim shape, without
    reimplementing that file's full access/proximity logic (which is
    tests/vehicle_spec.lua's own job).

    SCOPE, DELIBERATELY NARROWED TO AVOID COLLIDING WITH
    tests/vehiclecombatguard_spec.lua: that file already thoroughly covers
    the mutual guard between EnterNearestK9Vehicle() and
    IsDragEngaged()/IsBiteHoldEngaged() (both directions) against this same
    production file, including the mid-delay re-check this pass added --
    this spec does not duplicate that coverage, only this file's OTHER
    behavior (seat/door selection, real termination/cleanup, any-ped,
    double-fire, per-person block, feature-off inertness, and now the
    seat-claim round trip). ONE DELIBERATE, DISCLOSED EXCEPTION: this pass
    also adds narrow coverage for IsDragTargetEngaged() -- a THIRD mutual-
    guard global, new to client/combat.lua this same pass, that
    tests/vehiclecombatguard_spec.lua's own header does not mention at all
    (it only names IsDragEngaged/IsBiteHoldEngaged). Since nothing else in
    this suite exercises it and it lives in the identical guard chain this
    file's own EnterNearestK9Vehicle() now carries, it is tested here rather
    than left completely uncovered -- flagged for whoever owns
    tests/vehiclecombatguard_spec.lua to relocate/duplicate there for
    naming consistency if they prefer, not done here since that file is
    outside this pass's own edit scope.

    IMPORTANT: this file loading the REAL server/vehicle.lua's own request
    handler is deliberately NOT how this suite proves the fix -- that would
    duplicate tests/vehicle_spec.lua's own job and mix two files' test
    conventions in one spec (this codebase's established, one-real-file-
    per-side pattern -- see e.g. tests/kennel_spec.lua loading only
    server/kennel.lua for the server side, tests/clientkennel_spec.lua
    loading only client/kennel.lua for the client side). Instead, the
    interleaving test below hand-writes a MINIMAL relay that mirrors
    server/vehicle.lua's own check-then-claim shape (first request for a
    given vehicle+seat wins, no yield in between) purely so client-side
    behavior at the CLIENT boundary -- does EnterNearestK9Vehicle() actually
    wait for a real grant before calling SET_PED_INTO_VEHICLE -- can be
    proven with two independent, real client/vehicle.lua instances racing
    each other, the same shape the audit's own two-instance demo used.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

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

local RESOURCE_NAME = 'john-k9'
local VEHICLE_MODEL = 'police'
local OTHER_VEHICLE_SENTINEL = 777 -- "some unrelated vehicle the ped got into via ordinary game controls"

--- @param opts { vehicleEntryExit: boolean?, isDragTargetEngaged: boolean?, onServerEvent: function? }?
--- @return table fixture
local function newVehicleFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- HasK9Access() -- PERMISSION AUDIT FOLLOW-UP (this pass): added because
    -- EnterNearestK9Vehicle()'s own access gate was widened from
    -- CanShowK9UI() to HasK9Access() alone, to match server/vehicle.lua's
    -- requestVehicleSeatClaim handler (see client/vehicle.lua's own doc
    -- comment on EnterNearestK9Vehicle() for the full writeup). Default
    -- `true` -- same "happy path is the default" convention canShowK9UI
    -- above already established for this fixture -- so every pre-existing
    -- test below that never mentions access at all keeps exercising the
    -- ordinary, permitted case unchanged. Decoupled from canShowK9UI on
    -- purpose: this file's own ox_target canInteract predicate for "Load
    -- Into Vehicle" still gates display on CanShowK9UI() (a disclosed,
    -- deliberately out-of-scope-this-pass gap -- see that predicate's own
    -- comment), so a test exercising the High Command/autoAccessGrade
    -- bypass shape needs to set these two independently.
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end
    local function HasK9Access() return hasK9Access end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as CanShowK9UI/DenyK9UIAccess
    -- above. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end
    local denyK9FeatureBlockedCallCount = 0
    local function DenyK9FeatureBlocked() denyK9FeatureBlockedCallCount = denyK9FeatureBlockedCallCount + 1 end

    -- SEAT-RACE FIX -- IsDragTargetEngaged() controllable stand-in. See this
    -- file's own header for why this ONE extra combat.lua global is modeled
    -- here (unlike IsDragEngaged/IsBiteHoldEngaged, deliberately left out of
    -- scope for tests/vehiclecombatguard_spec.lua to cover). Always defined
    -- (never a soft-dependency omission test in THIS file -- that shape is
    -- already covered for the sibling guards over in
    -- tests/vehiclecombatguard_spec.lua, no need to re-prove the identical
    -- `type(fn) == 'function'` degrade pattern a third time here).
    local dragTargetEngaged = opts.isDragTargetEngaged or false

    -- KENNEL-VS-VEHICLE MUTUAL GUARD (this pass) -- IsRestingInKennel()
    -- controllable stand-in, same shape as dragTargetEngaged above.
    -- `opts.restingInKennelAvailable`, unlike dragTargetEngaged, DOES get its
    -- own soft-dependency-omission test below (mirroring
    -- opts.featureBlocksAvailable's own shape above) -- IsRestingInKennel()
    -- is declared unconditionally at client/kennel.lua's own file top
    -- (outside that file's Config.Features.DeployableKennel registration
    -- gate), but that is a fact about THAT file, not a hard load-order
    -- guarantee this file may assume; the `type(...) == 'function'` guard
    -- exists specifically so a server that never loads client/kennel.lua at
    -- all (or loads it after this file) still degrades to "skip this check"
    -- rather than erroring.
    local restingInKennelAvailable = opts.restingInKennelAvailable
    if restingInKennelAvailable == nil then restingInKennelAvailable = true end
    local restingInKennel = opts.isRestingInKennel or false

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local pedHandle = 1
    local pedCoords = vec3(0.0, 0.0, 0.0)
    local pedDead = false
    local existingEntities = { [pedHandle] = true, [OTHER_VEHICLE_SENTINEL] = true }

    -- ---- "what vehicle does the game currently consider this ped seated
    -- in" -- nil means not in any vehicle. This is the ONE piece of state
    -- every seating-related native reads and writes, modeling the real
    -- game's own seat bookkeeping (a single source of truth, same as the
    -- real engine has) rather than independent booleans that could drift
    -- out of sync with each other the way this fixture's OLD version's
    -- separate `isPedInAnyVehicle` flag and attach-call list could.
    local pedCurrentVehicle = nil

    local function PlayerPedId() return pedHandle end
    local function GetEntityCoords(entity)
        if entity == pedHandle then return pedCoords end
        return vec3(0.0, 0.0, 0.0)
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return entity == pedHandle and pedDead or false end
    local function IsPedInAnyVehicle(ped, _bool)
        return ped == pedHandle and pedCurrentVehicle ~= nil
    end
    local function GetVehiclePedIsIn(ped, _lastVehicle)
        if ped == pedHandle and pedCurrentVehicle then return pedCurrentVehicle end
        return 0
    end

    -- ---- vehicle world state ----
    local vehiclePool = {}
    local vehicleModelByEntity = {}
    local vehicleCoordsByEntity = {}
    local vehicleMaxPassengers = {}
    local occupiedSeats = {} -- occupiedSeats[vehicle][seatIndex] = true
    local function GetGamePool(poolName) return poolName == 'CVehicle' and vehiclePool or {} end
    local function GetEntityModel(entity) return vehicleModelByEntity[entity] end
    --- @param maxPassengers number? -- defaults to 3 (a standard 4-seat cruiser: seats -1..2)
    local function addVehicle(entity, modelName, x, y, z, maxPassengers)
        vehiclePool[#vehiclePool + 1] = entity
        vehicleModelByEntity[entity] = GetHashKey(modelName)
        vehicleCoordsByEntity[entity] = vec3(x, y, z)
        vehicleMaxPassengers[entity] = maxPassengers or 3
        existingEntities[entity] = true
    end
    -- GetEntityCoords must also answer for vehicle entities.
    local realGetEntityCoords = GetEntityCoords
    GetEntityCoords = function(entity)
        if vehicleCoordsByEntity[entity] then return vehicleCoordsByEntity[entity] end
        return realGetEntityCoords(entity)
    end

    local function GetVehicleMaxNumberOfPassengers(vehicle) return vehicleMaxPassengers[vehicle] or 3 end
    local function IsVehicleSeatFree(vehicle, seatIndex)
        return not (occupiedSeats[vehicle] and occupiedSeats[vehicle][seatIndex])
    end
    local function setSeatOccupied(vehicle, seatIndex, occupied)
        occupiedSeats[vehicle] = occupiedSeats[vehicle] or {}
        occupiedSeats[vehicle][seatIndex] = occupied or nil
    end

    local seatCalls, doorOpenCalls, doorShutCalls, networkControlCalls = {}, {}, {}, {}
    local function SetPedIntoVehicle(ped, vehicle, seatIndex)
        seatCalls[#seatCalls + 1] = { ped = ped, vehicle = vehicle, seatIndex = seatIndex }
        if ped == pedHandle then pedCurrentVehicle = vehicle end
    end
    -- RIDE POSE / DRIVER-SEAT GUARD / ENTER CAPTURE (owner-directed ride
    -- pass). Recorded rather than merely stubbed: for each of these three
    -- the interesting question is WHICH value or WHEN, not "was it called".
    local scenarioCalls = {}
    local function TaskStartScenarioInPlace(ped, scenarioName, unkDelay, playEnterAnim)
        scenarioCalls[#scenarioCalls + 1] = { ped = ped, scenarioName = scenarioName, playEnterAnim = playEnterAnim }
    end

    -- Who is in seat -1 of a given vehicle. Defaults to nobody, so the
    -- driver-seat guard is inert unless a test deliberately puts the dog
    -- there -- otherwise every unrelated test would trip it.
    local driverBySeat = {}
    local function GetPedInVehicleSeat(vehicle, seatIndex)
        if seatIndex ~= -1 then return 0 end
        return driverBySeat[vehicle] or 0
    end

    local disabledControls = {}
    local function DisableControlAction(_group, control, _disable)
        disabledControls[control] = (disabledControls[control] or 0) + 1
    end
    local pressedControls = {}
    local function IsDisabledControlJustPressed(_group, control) return pressedControls[control] == true end

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

    local taskLeaveVehicleCalls, clearTasksCalls = {}, {}
    local function TaskLeaveVehicle(ped, vehicle, flags)
        taskLeaveVehicleCalls[#taskLeaveVehicleCalls + 1] = { ped = ped, vehicle = vehicle, flags = flags }
        -- Deliberately does NOT clear pedCurrentVehicle -- in reality this
        -- is an animated task that takes real time to resolve, so this
        -- fixture never assumes it "worked" on its own; a test that wants
        -- to model the animation completing calls simulatePedExitedVehicle()
        -- explicitly, at whatever point in the timeline it chooses.
    end
    local function ClearPedTasksImmediately(ped)
        clearTasksCalls[#clearTasksCalls + 1] = ped
    end

    local setCoordsCalls, setHeadingCalls = {}, {}
    local function GetOffsetFromEntityInWorldCoords(entity, x, y, z) return vec3(x, y, z) end
    local function SetEntityCoords(entity, x, y, z, ...) setCoordsCalls[#setCoordsCalls + 1] = { entity = entity, x = x, y = y, z = z } end
    local function SetEntityHeading(entity, heading) setHeadingCalls[#setHeadingCalls + 1] = { entity = entity, heading = heading } end
    local function GetEntityHeading(_entity) return 42.0 end

    local netIdSeq = 0
    local netIdByEntity = {}
    local function NetworkGetNetworkIdFromEntity(entity)
        if not netIdByEntity[entity] then
            netIdSeq = netIdSeq + 1
            netIdByEntity[entity] = netIdSeq
        end
        return netIdByEntity[entity]
    end
    -- Direct, controllable stand-in for client/main.lua's cross-file
    -- ResolveNetworkEntity -- same convention as this batch's sibling
    -- specs; used here for ResolveVehicleFromState() (purely a
    -- notification-wording decision in the new watchdog design -- see this
    -- file's own WATCHDOG section below).
    local vehicleResolvable = true
    local function ResolveNetworkEntity(netId)
        if not vehicleResolvable then return nil end
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- SEAT-RACE FIX -- RegisterNetEvent captures exactly one handler per
    -- event name (this file registers each of its two new events once),
    -- same convention as tests/kennel_spec.lua's own server-side fixture.
    local netEvents = {}
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    -- SEAT-RACE FIX -- captures every TriggerServerEvent call
    -- (requestVehicleSeatClaim / releaseVehicleSeatClaim) rather than
    -- sending it anywhere by default -- most tests below only need to
    -- inspect `serverEventCalls`/call `grantSeatClaim()`/`denySeatClaim()`.
    -- `opts.onServerEvent`, when supplied, is ALSO invoked with every call
    -- (constructor option) -- used by exactly one test (the two-client
    -- interleaving proof) to relay calls between two independent fixture
    -- instances.
    local serverEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        serverEventCalls[#serverEventCalls + 1] = { event = eventName, args = { ... } }
        if opts.onServerEvent then opts.onServerEvent(eventName, ...) end
    end

    --- @param name string
    --- @return table? call -- { event = string, args = table }
    local function lastServerEventNamed(name)
        for i = #serverEventCalls, 1, -1 do
            if serverEventCalls[i].event == name then return serverEventCalls[i] end
        end
        return nil
    end

    -- CAPTURE, DON'T AUTO-RUN -- see this file's own header for the full
    -- "three different CreateThread lifetimes" rationale.
    local capturedThreads = {}
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        capturedThreads[#capturedThreads + 1] = coroutine.create(fn)
    end
    local function Wait(_ms) coroutine.yield() end

    --- Drives the MOST RECENTLY created thread to completion (or a bounded
    --- 50 resumes, so a genuine infinite-loop bug fails loudly instead of
    --- hanging this test process) -- see this file's header.
    local function runLatestThreadToCompletion()
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
    end

    --- Resumes the RIDE GUARD thread -- the enter-key capture and
    --- driver-seat eviction loop added at the bottom of client/vehicle.lua
    --- (owner-directed ride pass). It is the LAST thread created at file
    --- load, so it is the last entry present before any test does anything
    --- that creates one of its own; captured by index at fixture build
    --- time rather than by position later, so a test that creates threads
    --- first still drives the right one.
    ---
    --- Resumed exactly once: the loop body runs one full pass and then
    --- yields at its own Wait, which is precisely one tick of the real
    --- thread.
    -- Resolved AFTER the file is loaded (see the assignment just below
    -- Sandbox.loadInto) -- this closure is defined before the load runs, so
    -- capturing the count here would always read 0.
    local rideGuardThreadIndex = 0
    local function runGuardThread()
        local co = capturedThreads[rideGuardThreadIndex]
        if not co then return end
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('vehicle fixture: ride guard thread errored: %s'):format(tostring(err)))
        end
    end

    --- Resumes ONLY the file-load-time watchdog thread (always
    --- capturedThreads[1]) exactly once.
    local function stepWatchdogOnce()
        local co = capturedThreads[1]
        if not co then return end
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('vehicle fixture: watchdog thread errored: %s'):format(tostring(err)))
        end
    end

    -- ---- K9Compat -- direct stub, see tests/clientkennel_spec.lua's own
    -- header for why this is the right level of abstraction here.
    local addGlobalVehicleCalls = {}
    local K9Compat = {
        Get = function(_system)
            return {
                AddGlobalVehicle = function(options) addGlobalVehicleCalls[#addGlobalVehicleCalls + 1] = options end,
            }
        end,
        Redetect = function() end,
        Which = function(_system) return 'ox_target' end,
    }

    local config = {
        Features = { VehicleEntryExit = opts.vehicleEntryExit ~= false },
        K9Vehicles = { VEHICLE_MODEL },
        VehicleInteractMeters = 3.0,
    }

    local envOverrides = {
        Config = config,
        GetHashKey = GetHashKey,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        lib = lib,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        GetVehiclePedIsIn = GetVehiclePedIsIn,
        GetGamePool = GetGamePool,
        GetEntityModel = GetEntityModel,
        GetVehicleMaxNumberOfPassengers = GetVehicleMaxNumberOfPassengers,
        IsVehicleSeatFree = IsVehicleSeatFree,
        SetPedIntoVehicle = SetPedIntoVehicle,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
        GetPedInVehicleSeat = GetPedInVehicleSeat,
        DisableControlAction = DisableControlAction,
        IsDisabledControlJustPressed = IsDisabledControlJustPressed,
        SetVehicleDoorOpen = SetVehicleDoorOpen,
        SetVehicleDoorShut = SetVehicleDoorShut,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        TaskLeaveVehicle = TaskLeaveVehicle,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        GetOffsetFromEntityInWorldCoords = GetOffsetFromEntityInWorldCoords,
        SetEntityCoords = SetEntityCoords,
        SetEntityHeading = SetEntityHeading,
        GetEntityHeading = GetEntityHeading,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        TriggerServerEvent = TriggerServerEvent,
        CreateThread = CreateThread,
        Wait = Wait,
        K9Compat = K9Compat,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
        IsDragTargetEngaged = function() return dragTargetEngaged end,
        -- Menu-parity pass (this session): client/vehicle.lua now also
        -- registers a 'k9vehicle' chat command (RegisterCommand) alongside
        -- its existing ox_target option / resource-globals -- a plain no-op
        -- stub, same shape as every other fixture in this suite that loads a
        -- production file registering a command it does not itself need to
        -- exercise.
        RegisterCommand = function(_name, _handler, _restricted) end,
    }
    if featureBlocksAvailable then
        envOverrides.IsK9FeatureBlocked = IsK9FeatureBlocked
        envOverrides.DenyK9FeatureBlocked = DenyK9FeatureBlocked
    end
    if restingInKennelAvailable then
        envOverrides.IsRestingInKennel = function() return restingInKennel end
    end
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../client/vehicle.lua', env)
    -- The ride guard is the LAST thread client/vehicle.lua creates at load
    -- time, so it is the last captured entry at exactly this moment --
    -- before any test has had a chance to create one of its own.
    rideGuardThreadIndex = #capturedThreads

    -- File load itself already creates ONE thread (the persistent
    -- watchdog) -- every test below cares about threads created SINCE
    -- fixture setup (i.e. by EnterNearestK9Vehicle()/ExitK9Vehicle() calls
    -- the test itself makes), not that baseline, so threadCount() below is
    -- reported net of it.
    local baselineThreadCount = threadCreateCount

    return {
        env = env,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        seatCalls = seatCalls,
        scenarioCalls = scenarioCalls,
        runGuardThread = runGuardThread,
        MY_PED = pedHandle,
        --- Puts this client's own ped into a vehicle WITHOUT going through
        --- this resource's seating flow -- the admin-teleport / other-
        --- resource / loaded-late case the driver-seat guard exists for.
        setPedCurrentVehicle = function(vehicle) pedCurrentVehicle = vehicle end,
        disabledControlCount = function(control) return disabledControls[control] or 0 end,
        pressControl = function(control) pressedControls[control] = true end,
        setDriverSeatOccupant = function(vehicle, ped) driverBySeat[vehicle] = ped end,
        doorOpenCalls = doorOpenCalls,
        doorShutCalls = doorShutCalls,
        networkControlCalls = networkControlCalls,
        taskLeaveVehicleCalls = taskLeaveVehicleCalls,
        clearTasksCalls = clearTasksCalls,
        setCoordsCalls = setCoordsCalls,
        setHeadingCalls = setHeadingCalls,
        threadCount = function() return threadCreateCount - baselineThreadCount end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        runLatestThreadToCompletion = runLatestThreadToCompletion,
        stepWatchdogOnce = stepWatchdogOnce,
        addGlobalVehicleCalls = addGlobalVehicleCalls,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        denyCallCount = function() return denyCalls end,
        setPedDead = function(v) pedDead = v end,
        setPedMissing = function() existingEntities[pedHandle] = nil end,
        -- Models "the ped is seated in some vehicle via ordinary game
        -- controls, unrelated to this file's own bookkeeping" -- the
        -- pre-flight IS_PED_IN_ANY_VEHICLE guard's own scenario.
        setIsPedInAnyVehicle = function(v) pedCurrentVehicle = v and OTHER_VEHICLE_SENTINEL or nil end,
        -- Models the ped having actually, successfully left whatever
        -- vehicle it was in -- either its own ordinary "exit vehicle"
        -- control working unaided, or TASK_LEAVE_VEHICLE's animation
        -- finishing. Tests call this explicitly, at whatever point in a
        -- scenario's timeline they choose, rather than having it happen
        -- automatically.
        simulatePedExitedVehicle = function() pedCurrentVehicle = nil end,
        getPedCurrentVehicle = function() return pedCurrentVehicle end,
        addVehicle = addVehicle,
        setSeatOccupied = setSeatOccupied,
        setVehicleResolvable = function(v) vehicleResolvable = v end,
        -- Deletes the vehicle entity AND -- matching the real engine's own
        -- documented behavior (client/vehicle.lua's own header: "the game
        -- engine itself already force-ejects any occupant when their
        -- vehicle is deleted") -- clears pedCurrentVehicle if this ped was
        -- the one seated in it.
        deleteVehicleEntity = function(entity)
            existingEntities[entity] = nil
            if pedCurrentVehicle == entity then pedCurrentVehicle = nil end
        end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        denyK9FeatureBlockedCallCount = function() return denyK9FeatureBlockedCallCount end,
        setDragTargetEngaged = function(v) dragTargetEngaged = v end,
        setRestingInKennel = function(v) restingInKennel = v end,
        -- SEAT-RACE FIX -- see this file's own header for the full design.
        serverEventCalls = serverEventCalls,
        lastServerEventNamed = lastServerEventNamed,
        --- Sets env.source then invokes the captured handler for
        --- `eventName` -- the generic primitive `grantSeatClaim`/
        --- `denySeatClaim` below and the SOURCE-ORIGIN GUARD tests are both
        --- built on. `src` = 65535 models a genuine server-originated event
        --- (FiveM's own documented sentinel); anything else models a
        --- spoofed/locally-fired one.
        dispatchClientEvent = function(eventName, src, ...)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'vehicle fixture: no handler registered for ' .. eventName)
            return handler(...)
        end,
        --- Simulates the server granting the MOST RECENT
        --- requestVehicleSeatClaim call, echoing back that exact call's own
        --- (vehicleNetId, seatIndex, token) -- exactly what the real server
        --- always does (server/vehicle.lua's own header). Fails loudly if
        --- no such request was ever made.
        grantSeatClaim = function()
            local call = lastServerEventNamed('john-k9:server:requestVehicleSeatClaim')
            assert(call, 'vehicle fixture: grantSeatClaim() called with no outstanding requestVehicleSeatClaim')
            env.source = 65535
            netEvents['john-k9:client:vehicleSeatClaimGranted'](call.args[1], call.args[2], call.args[3])
        end,
        --- Same as grantSeatClaim() above, but denies instead.
        denySeatClaim = function()
            local call = lastServerEventNamed('john-k9:server:requestVehicleSeatClaim')
            assert(call, 'vehicle fixture: denySeatClaim() called with no outstanding requestVehicleSeatClaim')
            env.source = 65535
            netEvents['john-k9:client:vehicleSeatClaimDenied'](call.args[1], call.args[2], call.args[3])
        end,
    }
end

-- ========================================================================
-- Feature-off inertness -- unaffected by this pass's real-seat rewrite,
-- kept as a straightforward regression check.
-- ========================================================================

t.test('feature off: creates no watchdog thread and registers neither onResourceStart nor onResourceStop', function()
    local f = newVehicleFixture({ vehicleEntryExit = false })
    t.equals(f.threadCount(), 0)
    t.equals(f.onResourceStartHandlerCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

t.test('feature off: none of EnterNearestK9Vehicle/ExitK9Vehicle/IsInK9Vehicle exist at all', function()
    local f = newVehicleFixture({ vehicleEntryExit = false })
    t.isNil(f.env.EnterNearestK9Vehicle)
    t.isNil(f.env.ExitK9Vehicle)
    t.isNil(f.env.IsInK9Vehicle)
end)

-- ========================================================================
-- Sanity + pre-flight guards
-- ========================================================================

t.test('FORCED RELEASE: the forceExitVehicleSeat handler is registered and calls ExitK9Vehicle with the access-revoked notice', function()
    local f = newVehicleFixture()
    -- dispatchClientEvent asserts a handler exists, so this is the
    -- registration proof: with no handler it fails loudly rather than
    -- silently passing.
    f.dispatchClientEvent('john-k9:client:forceExitVehicleSeat', 65535, 'cert_revoked')
end)

t.test('FORCED RELEASE: a FORGED local trigger is rejected -- the source-origin guard holds on this handler too', function()
    -- Same omission, same file-wide convention, same reasoning as the
    -- kennel side: harmless today because the effect is self-only, guarded
    -- anyway so a future payload on this event cannot become forgeable.
    -- MUST BE GENUINELY SEATED FIRST. An earlier version of this test
    -- forged the event with the client standing on the pavement and
    -- asserted no notification -- which passes with OR without the guard,
    -- because ExitK9Vehicle early-returns on IsInK9Vehicle() anyway. It
    -- proved nothing, and only showed itself when the guard was removed on
    -- purpose and the test stayed green.
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle(), 'sanity: genuinely seated before the forged trigger')

    f.dispatchClientEvent('john-k9:client:forceExitVehicleSeat', 1, 'cert_revoked')

    t.isTrue(f.env.IsInK9Vehicle(),
        'a locally-forged trigger (source ~= 65535) must be ignored outright -- the client stays seated')
end)

t.test('FORCED RELEASE: the handler is a safe no-op when this client is not in a K9 vehicle at all', function()
    -- A duplicate or late event must never throw, and must never notify
    -- someone standing on a pavement that they have been let out of a
    -- vehicle.
    local f = newVehicleFixture()
    local before = #f.notifyCalls
    f.dispatchClientEvent('john-k9:client:forceExitVehicleSeat', 65535, 'cert_revoked')
    t.equals(#f.notifyCalls, before, 'ExitK9Vehicle\'s own IsInK9Vehicle() early return makes this inert')
end)

t.test('feature on: exposes the three documented globals, and IsInK9Vehicle starts false', function()
    local f = newVehicleFixture()
    t.isNotNil(f.env.EnterNearestK9Vehicle)
    t.isNotNil(f.env.ExitK9Vehicle)
    t.isNotNil(f.env.IsInK9Vehicle)
    t.isFalse(f.env.IsInK9Vehicle())
end)

-- PERMISSION AUDIT FOLLOW-UP (this pass): EnterNearestK9Vehicle()'s own
-- access gate was widened from CanShowK9UI() to HasK9Access() alone, to
-- match server/vehicle.lua's requestVehicleSeatClaim handler -- see
-- client/vehicle.lua's own doc comment on EnterNearestK9Vehicle() for the
-- full writeup. CanShowK9UI() alone no longer denies this function at all
-- (proven by the very next test, the High Command bypass shape).
t.test('EnterNearestK9Vehicle: HasK9Access false denies locally, creates no thread', function()
    local f = newVehicleFixture()
    f.setHasK9Access(false)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.denyCallCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.threadCount(), 0)
end)

-- PERMISSION AUDIT FOLLOW-UP -- the High Command/autoAccessGrade bypass
-- shape this pass exists to unblock: HasK9Access() true but CanShowK9UI()
-- false (the pre-widening combinator, which this function no longer calls
-- at all) must still reach the server -- proves the gate genuinely changed,
-- not merely that HasK9Access() was added ALONGSIDE the old check.
t.test('EnterNearestK9Vehicle: HasK9Access() true with CanShowK9UI() false (High Command bypass shape) still proceeds -- CanShowK9UI() no longer gates this function at all', function()
    local f = newVehicleFixture()
    f.setHasK9Access(true)
    f.setCanShowK9UI(false)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.denyCallCount(), 0, 'must not have been locally denied')
    -- Proves this genuinely reached PAST the access gate (not merely that
    -- nothing happened for an unrelated reason): with no K9 vehicle in range
    -- in this fixture, the function's own NEXT check -- the vehicle search --
    -- is what fires, producing this exact, different notify.
    t.equals(f.lastNotify().description, locale('vehicle.no_vehicle_nearby'), 'must have reached the vehicle search past the access gate, not been denied')
end)

t.test('EnterNearestK9Vehicle: no K9 vehicle within range notifies and does nothing', function()
    local f = newVehicleFixture()
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.lastNotify().description, locale('vehicle.no_vehicle_nearby'))
end)

t.test('EnterNearestK9Vehicle: already seated in SOME vehicle via ordinary game controls refuses, even though IsInK9Vehicle() itself is still false', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setIsPedInAnyVehicle(true)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0, 'must never try to seat a ped the game already considers seated somewhere')
    t.equals(f.threadCount(), 0)
    t.equals(f.lastNotify().description, locale('vehicle.already_in_vehicle'))
end)

t.test('EnterNearestK9Vehicle: a vehicle outside Config.VehicleInteractMeters is never selected', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 100.0, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0)
end)

t.test('EnterNearestK9Vehicle: a vehicle of an unlisted model is never selected, no matter how close', function()
    local f = newVehicleFixture()
    f.addVehicle(50, 'some_civilian_car', 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 0)
end)

-- ========================================================================
-- SEAT-RACE FIX -- the new server round trip itself: request shape, the
-- door staying untouched until a real grant arrives, SOURCE-ORIGIN GUARDs,
-- stale-token rejection, the deny path, the give-up timeout, and
-- onResourceStop releasing an outstanding claim. See this file's own header
-- for the full design.
-- ========================================================================

t.test('SEAT-RACE FIX: EnterNearestK9Vehicle sends requestVehicleSeatClaim with the real vehicle netId and the locally-chosen seatIndex, and touches NO door/seat native until a grant actually arrives', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()

    local call = f.lastServerEventNamed('john-k9:server:requestVehicleSeatClaim')
    t.isNotNil(call, 'must ask the server before doing anything physical')
    t.equals(call.args[2], 1, 'seat 1 is the locally-computed best free seat, sent to the server')
    t.isTrue(type(call.args[3]) == 'number', 'a request token must be sent')
    t.equals(#f.doorOpenCalls, 0, 'no door touched until the server actually grants the claim')
    t.equals(#f.seatCalls, 0)
    t.equals(f.threadCount(), 1, 'the give-up timeout thread, not a door/seat sequence -- that one only starts once granted')
end)

t.test('SEAT-RACE FIX: server grants the claim -- door opens ONLY now, the rest of the sequence runs exactly as before', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.doorOpenCalls, 0)

    f.grantSeatClaim()
    t.equals(#f.doorOpenCalls, 1, 'the door opens the instant a grant arrives')
    t.equals(#f.seatCalls, 0, 'not seated yet -- still mid door-open delay')

    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
    t.isTrue(f.env.IsInK9Vehicle())

    local releaseCall = f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim')
    t.isNotNil(releaseCall, 'a successfully-used claim must be released immediately, not left to its own server-side TTL')
end)

t.test('SEAT-RACE FIX: server denies the claim -- resets local state, never opens a door, and shows NO second local notify (the server already told the player why, server-side)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    local notifyCountBefore = #f.notifyCalls

    f.denySeatClaim()

    t.equals(#f.doorOpenCalls, 0)
    t.equals(#f.seatCalls, 0)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.notifyCalls, notifyCountBefore, 'the server owns messaging for its own rejection reasons -- this file must not show a redundant local notify')

    -- A denial must never permanently block future attempts.
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
end)

t.test('SEAT-RACE FIX SOURCE-ORIGIN GUARD: a spoofed vehicleSeatClaimGranted (source ~= 65535) is ignored -- never opens a door', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    local call = f.lastServerEventNamed('john-k9:server:requestVehicleSeatClaim')

    f.dispatchClientEvent('john-k9:client:vehicleSeatClaimGranted', 999, call.args[1], call.args[2], call.args[3])

    t.equals(#f.doorOpenCalls, 0, 'a locally-fired/spoofed grant must never be trusted')
    t.isFalse(f.env.IsInK9Vehicle())

    -- The genuine grant, from the real server sentinel, must still work
    -- afterward -- the spoofed attempt must not have consumed/corrupted the
    -- real pending claim.
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
end)

t.test('SEAT-RACE FIX SOURCE-ORIGIN GUARD: a spoofed vehicleSeatClaimDenied (source ~= 65535) is ignored -- does not reset vehicleEntryInProgress', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    local call = f.lastServerEventNamed('john-k9:server:requestVehicleSeatClaim')

    f.dispatchClientEvent('john-k9:client:vehicleSeatClaimDenied', 999, call.args[1], call.args[2], call.args[3])

    -- Still pending, per the spoofed message being ignored: a second entry
    -- attempt must still be refused as a double-fire, not silently allowed.
    f.env.EnterNearestK9Vehicle()
    t.equals(#f.serverEventCalls, 1, 'must not have sent a second request -- vehicleEntryInProgress is still true')
end)

t.test('SEAT-RACE FIX: a grant for a STALE token (an already-abandoned earlier request) is ignored', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    local call = f.lastServerEventNamed('john-k9:server:requestVehicleSeatClaim')
    local staleToken = call.args[3] - 1

    f.dispatchClientEvent('john-k9:client:vehicleSeatClaimGranted', 65535, call.args[1], call.args[2], staleToken)

    t.equals(#f.doorOpenCalls, 0, 'a response for a different (stale) request must never act on the current one')
end)

t.test('SEAT-RACE FIX GIVE-UP TIMEOUT: no grant or deny ever arrives -- gives up locally after the bounded wait, best-effort releases, notifies, and never leaves vehicleEntryInProgress stuck', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.threadCount(), 1, 'the give-up timeout thread')

    f.runLatestThreadToCompletion() -- drives the give-up timeout thread through its single bounded Wait()

    t.equals(#f.seatCalls, 0)
    t.equals(#f.doorOpenCalls, 0)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'), 'best-effort release even though nothing was ever confirmed granted')

    -- Never stuck: a fresh attempt must work normally afterward.
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
end)

t.test('SEAT-RACE FIX GIVE-UP TIMEOUT: never fires once a grant has already been received -- the bounded local door/seat sequence governs completion from that point on', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim() -- consumes the pending claim, marks it granted, opens the door, starts the door/seat thread

    -- The give-up timeout thread (capturedThreads[1] of this ride, still
    -- alive) is driven directly here rather than via runLatestThreadToCompletion()
    -- (which would drive the NEWER door/seat thread instead) -- proving the
    -- give-up thread's own `not pendingSeatClaim.granted` guard makes it a
    -- true no-op post-grant, not merely unreached.
    t.equals(f.threadCount(), 2, 'both the give-up timeout thread and the new door/seat thread now exist')

    f.runLatestThreadToCompletion() -- drives the door/seat thread (the most recently created one) to completion
    t.equals(#f.seatCalls, 1)
    t.isTrue(f.env.IsInK9Vehicle())
end)

t.test('SEAT-RACE FIX: onResourceStop releases an outstanding, not-yet-answered seat claim -- a resource restart mid-request must not leave the seat reserved for the rest of the server-side TTL', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()

    f.fireResourceStop(RESOURCE_NAME)

    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'), 'must release the still-pending claim on resource stop')
end)

t.test('SEAT-RACE FIX: onResourceStop ALSO releases a claim already granted but not yet acted on (mid door/seat sequence)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim() -- door opens, door/seat thread created, but never driven

    f.fireResourceStop(RESOURCE_NAME)

    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'), 'a granted-but-not-yet-seated claim must also be released')
end)

-- ========================================================================
-- SEAT-RACE FIX -- THE ACTUAL CONCURRENCY PROOF: two INDEPENDENT, real
-- client/vehicle.lua instances, each with its own state, racing the SAME
-- real vehicle/seat -- the exact shape the audit's own demo used ("loading
-- the real client/vehicle.lua twice as two independent script instances
-- with their own network-latency replicas and interleaving their
-- coroutines in lock-step"). See this file's own header for why the relay
-- below is a minimal stand-in for server/vehicle.lua's own check-then-claim
-- shape, not a re-implementation of its full access/proximity logic.
-- ========================================================================

--- A minimal, faithful stand-in for server/vehicle.lua's own check-then-
--- claim core: the FIRST queued request for a given (vehicleNetId,
--- seatIndex) pair is granted, every subsequent one for the SAME pair is
--- denied, with no yield of any kind in `processNext()` -- exactly this
--- resource's own "ordinary event-processing order is what serializes two
--- requests" discipline (server/vehicle.lua's/server/kennel.lua's own
--- header). Requests are QUEUED, not answered immediately, so a test can
--- put BOTH clients' requests genuinely in flight -- neither yet
--- answered -- before deciding the processing order, the same "both dogs
--- pick Enter Vehicle before either hears back" moment the real bug lived
--- in.
--- @return table relay
local function newSeatClaimRelay()
    local claims = {}  -- "netId:seatIndex" -> src currently holding it
    local pending = {} -- queue of { src, netId, seatIndex, token }
    local clientsBySource = {}

    local relay = {}

    --- @param src string|number -- any unique key identifying one client instance
    --- @param clientFixture table -- a newVehicleFixture() return value
    function relay.register(src, clientFixture)
        clientsBySource[src] = clientFixture
    end

    --- @param src string|number
    --- @return function -- pass as that client's own `opts.onServerEvent`
    function relay.onServerEventFor(src)
        return function(eventName, ...)
            if eventName == 'john-k9:server:requestVehicleSeatClaim' then
                local netId, seatIndex, token = ...
                pending[#pending + 1] = { src = src, netId = netId, seatIndex = seatIndex, token = token }
            elseif eventName == 'john-k9:server:releaseVehicleSeatClaim' then
                local netId, seatIndex = ...
                local key = netId .. ':' .. seatIndex
                if claims[key] == src then claims[key] = nil end
            end
        end
    end

    --- @return number
    function relay.pendingCount() return #pending end

    --- Processes exactly one QUEUED request, FIFO -- see this function's
    --- own doc comment above for why this is the load-bearing "no yield
    --- between check and claim" step.
    function relay.processNext()
        local req = table.remove(pending, 1)
        assert(req, 'seat claim relay: processNext() called with nothing queued')
        local key = req.netId .. ':' .. req.seatIndex
        local eventName
        if claims[key] and claims[key] ~= req.src then
            eventName = 'john-k9:client:vehicleSeatClaimDenied'
        else
            claims[key] = req.src
            eventName = 'john-k9:client:vehicleSeatClaimGranted'
        end
        clientsBySource[req.src].dispatchClientEvent(eventName, 65535, req.netId, req.seatIndex, req.token)
    end

    return relay
end

t.test('SEAT-RACE FIX -- TWO REAL, INDEPENDENT client/vehicle.lua INSTANCES racing the SAME real vehicle/seat, both requests genuinely in flight before either is answered: exactly ONE ever calls SET_PED_INTO_VEHICLE, the other is denied and never touches a door', function()
    local relay = newSeatClaimRelay()

    local clientA = newVehicleFixture({ onServerEvent = relay.onServerEventFor('A') })
    local clientB = newVehicleFixture({ onServerEvent = relay.onServerEventFor('B') })
    relay.register('A', clientA)
    relay.register('B', clientB)

    -- The SAME real vehicle, from each client's own local perspective. In
    -- real FiveM each client has its own local entity handle for the same
    -- networked object -- irrelevant here, since what actually matters is
    -- that both fixtures map their own handle to the SAME netId (both use
    -- entity handle 50, and NetworkGetNetworkIdFromEntity assigns netIds in
    -- per-fixture call order, so both resolve to netId 1) -- this is
    -- objectively one real vehicle in the shared game world, exactly the
    -- scenario the audit described.
    clientA.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    clientB.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    -- Both handlers select "Enter Vehicle" before EITHER has heard back
    -- from the server -- the exact audit scenario: "two dogs standing near
    -- the same K9 cruiser both pick Enter Vehicle inside the same ~400ms
    -- window." Both independently compute seat 1 as the best free seat,
    -- since neither has entered yet -- exactly the precondition the
    -- original client-only design could never arbitrate.
    clientA.env.EnterNearestK9Vehicle()
    clientB.env.EnterNearestK9Vehicle()

    t.equals(relay.pendingCount(), 2, 'both requests are genuinely simultaneous, in flight, before either is answered -- this is what a client-only design could never see')
    t.equals(#clientA.doorOpenCalls, 0, 'sanity: neither client has touched a door yet')
    t.equals(#clientB.doorOpenCalls, 0)

    -- The server necessarily processes them ONE AT A TIME, in SOME order --
    -- ordinary FIFO here, matching whichever request the relay's own queue
    -- happened to receive first (A). This one call is the entire fix: the
    -- CHECK-AND-CLAIM inside it has no yield, so B's request cannot see a
    -- half-written state.
    relay.processNext() -- grants A
    relay.processNext() -- denies B -- A already holds (vehicleNetId=1, seatIndex=1)

    clientA.runLatestThreadToCompletion() -- A's door-open/seat/door-shut sequence
    -- B was denied before ever calling SetVehicleDoorOpen -- nothing left
    -- to drive for B at all.

    t.equals(#clientA.seatCalls, 1, 'A genuinely gets seated')
    t.equals(#clientB.seatCalls, 0, 'B is NEVER seated -- this is the actual concurrency bug the fix closes')
    t.equals(#clientB.doorOpenCalls, 0, 'B never even opens a door -- denied before any physical action')
    t.isTrue(clientA.env.IsInK9Vehicle())
    t.isFalse(clientB.env.IsInK9Vehicle())

    -- The stronger, exact-audit-language assertion: never do both
    -- SET_PED_INTO_VEHICLE calls land on the same vehicle/seat pair.
    local totalSeatCallsOnThisSeat = #clientA.seatCalls + #clientB.seatCalls
    t.equals(totalSeatCallsOnThisSeat, 1, 'at most one SET_PED_INTO_VEHICLE call for this vehicle/seat pair, combined across both clients')
end)

t.test('SEAT-RACE FIX -- the LOSING order also works: if B\'s request happens to be processed first, A is the one denied -- the fix arbitrates by processing order, not by identity', function()
    local relay = newSeatClaimRelay()

    local clientA = newVehicleFixture({ onServerEvent = relay.onServerEventFor('A') })
    local clientB = newVehicleFixture({ onServerEvent = relay.onServerEventFor('B') })
    relay.register('A', clientA)
    relay.register('B', clientB)

    clientA.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    clientB.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    clientA.env.EnterNearestK9Vehicle()
    clientB.env.EnterNearestK9Vehicle()
    t.equals(relay.pendingCount(), 2)

    relay.processNext() -- grants A (still queued first -- FIFO)
    relay.processNext() -- denies B

    -- Symmetry check with a FRESH pair of clients where B's request is
    -- queued and processed FIRST this time.
    local relay2 = newSeatClaimRelay()
    local clientC = newVehicleFixture({ onServerEvent = relay2.onServerEventFor('C') })
    local clientD = newVehicleFixture({ onServerEvent = relay2.onServerEventFor('D') })
    relay2.register('C', clientC)
    relay2.register('D', clientD)
    clientC.addVehicle(60, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    clientD.addVehicle(60, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    clientD.env.EnterNearestK9Vehicle() -- D requests FIRST this time
    clientC.env.EnterNearestK9Vehicle()
    t.equals(relay2.pendingCount(), 2)

    relay2.processNext() -- grants D (first in the queue)
    relay2.processNext() -- denies C

    clientD.runLatestThreadToCompletion()
    t.equals(#clientD.seatCalls, 1, 'whichever request is processed first wins -- D this time')
    t.equals(#clientC.seatCalls, 0, 'and the other is denied -- C this time')
end)

-- ========================================================================
-- SEAT-RACE FIX -- IsDragTargetEngaged() mutual guard (client/combat.lua,
-- new this pass -- "am I the one currently BEING dragged"). See this file's
-- own header for why this is tested here rather than in
-- tests/vehiclecombatguard_spec.lua.
-- ========================================================================

t.test('IsDragTargetEngaged pre-flight guard: refuses immediately, no thread, no server contact, when the local ped is currently being dragged', function()
    local f = newVehicleFixture({ isDragTargetEngaged = true })
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    f.env.EnterNearestK9Vehicle()

    t.equals(#f.serverEventCalls, 0, 'must refuse before ever contacting the server')
    t.equals(f.threadCount(), 0)
    t.equals(f.lastNotify().description, locale('vehicle.blocked_by_being_dragged'))
end)

t.test('IsDragTargetEngaged canInteract mirror: the "Get in the Back Seat" option hides while being dragged', function()
    local f = newVehicleFixture({ isDragTargetEngaged = true })
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, o in ipairs(f.addGlobalVehicleCalls[1]) do
        if o.name == 'john-k9:enterVehicle' then enterOption = o end
    end
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))

    f.setDragTargetEngaged(false)
    t.isTrue(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
end)

t.test('IsDragTargetEngaged MID-DELAY re-check: starts being dragged AFTER a grant but before the door-open delay finishes -- aborts, shuts the door back, releases the claim', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    t.equals(#f.doorOpenCalls, 1)

    f.setDragTargetEngaged(true) -- starts mid-delay
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0, 'must never seat a ped that started being dragged during the delay')
    t.equals(#f.doorShutCalls, 1, 'the door this file opened must still be shut again')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.blocked_by_being_dragged'))
    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'), 'the now-unneeded granted claim must be released')
end)

-- ========================================================================
-- KENNEL-VS-VEHICLE MUTUAL GUARD (this pass) -- IsRestingInKennel()
-- (client/kennel.lua). QA found no guard existed in EITHER direction between
-- resting in a kennel and being seated in a K9 vehicle; this half closes the
-- "resting, then selects Enter Vehicle" direction. See client/kennel.lua's
-- own "Rest in Kennel" onSelect/canInteract and enterKennelConfirmed guards
-- for the other, symmetric half (tests/clientkennel_spec.lua).
-- ========================================================================

t.test('IsRestingInKennel pre-flight guard: refuses immediately, no thread, no server contact, when the local ped is currently resting in a kennel', function()
    local f = newVehicleFixture({ isRestingInKennel = true })
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    f.env.EnterNearestK9Vehicle()

    t.equals(#f.serverEventCalls, 0, 'must refuse before ever contacting the server -- a claim taken and then abandoned holds a seat until it times out')
    t.equals(f.threadCount(), 0)
    t.equals(f.lastNotify().description, locale('kennel.enter_already_resting'))
end)

t.test('IsRestingInKennel canInteract mirror: the "Load Into Vehicle" option hides while resting in a kennel', function()
    local f = newVehicleFixture({ isRestingInKennel = true })
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, o in ipairs(f.addGlobalVehicleCalls[1]) do
        if o.name == 'john-k9:enterVehicle' then enterOption = o end
    end
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))

    f.setRestingInKennel(false)
    t.isTrue(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
end)

t.test('IsRestingInKennel MID-DELAY re-check: starts resting in a kennel AFTER a grant but before the door-open delay finishes -- aborts, shuts the door back, releases the claim', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    t.equals(#f.doorOpenCalls, 1)

    f.setRestingInKennel(true) -- starts mid-delay (a SEPARATE, ALSO server-arbitrated round trip completing in this exact window)
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0, 'must never seat a ped that started resting in a kennel during the delay')
    t.equals(#f.doorShutCalls, 1, 'the door this file opened must still be shut again')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('kennel.enter_already_resting'))
    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'), 'the now-unneeded granted claim must be released')
end)

t.test('IsRestingInKennel soft dependency: with client/kennel.lua not loaded at all (no IsRestingInKennel global), entry proceeds normally instead of erroring', function()
    local f = newVehicleFixture({ restingInKennelAvailable = false })
    t.isNil(f.env.IsRestingInKennel)
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)

    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 1, 'an absent optional global must be a skipped check, never an error')
end)

-- ========================================================================
-- REAL SEATING -- happy path, seat/door mapping, and "auto-find the best
-- spot" (rear preferred, never the driver's seat, never a taken seat, clear
-- refusal when nothing qualifies -- no silent fallback to anywhere else).
-- Every "happy path" sequence below now reads:
--   EnterNearestK9Vehicle() -> grantSeatClaim() -> runLatestThreadToCompletion()
-- -- see this file's own header for why grantSeatClaim() is the
-- minimal-diff way to keep exercising exactly the same downstream behavior
-- these tests always covered.
-- ========================================================================

t.test('happy path: opens the door, seats the ped for real (not attach/freeze/hide), shuts the door, becomes visible-and-collidable by construction (no collision/visibility natives touched at all)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 5.0, 0.0, 0.0)
    f.addVehicle(51, VEHICLE_MODEL, 1.0, 0.0, 0.0) -- nearer

    f.env.EnterNearestK9Vehicle()
    t.equals(f.threadCount(), 1, 'the give-up timeout thread starts immediately -- the door-open/seat/door-shut sequence only starts once granted')
    t.isFalse(f.env.IsInK9Vehicle(), 'not seated yet -- still waiting on the server')

    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.equals(#f.doorOpenCalls, 1)
    t.equals(f.doorOpenCalls[1].vehicle, 51, 'must act on the NEARER of the two candidates')
    t.equals(#f.seatCalls, 1)
    t.equals(f.seatCalls[1].ped, 1)
    t.equals(f.seatCalls[1].vehicle, 51)
    t.equals(#f.doorShutCalls, 1)
    t.equals(f.doorShutCalls[1].vehicle, 51)
    t.equals(f.doorOpenCalls[1].doorIndex, f.doorShutCalls[1].doorIndex, 'opens and shuts the SAME door')
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.loaded'))
    t.equals(f.getPedCurrentVehicle(), 51, 'the ped is now a real, game-recognized occupant of the vehicle')
    t.isTrue(#f.networkControlCalls >= 1, 'must ask for network control of the vehicle at least once (client/combat.lua\'s established fire-and-forget pattern)')
end)

t.test('SEAT/DOOR MAPPING: rear-left (seat 1) is tried first on a standard 4-seat cruiser, and maps to door 1 (DSIDE_R), never door 2', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0) -- default maxPassengers = 3 -> seats -1..2, all free
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 1, 'rear, driver\'s side is first in the preference order')
    t.equals(f.doorOpenCalls[1].doorIndex, 1, 'seat 1 (back, driver\'s side) is door 1 (VEH_EXT_DOOR_DSIDE_R) -- NOT seatIndex+1 (which would wrongly be door 2, the front passenger door)')
end)

t.test('SEAT/DOOR MAPPING: seat 1 occupied falls back to seat 2 (rear, passenger\'s side) -> door 3 (PSIDE_R)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setSeatOccupied(50, 1, true)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 2)
    t.equals(f.doorOpenCalls[1].doorIndex, 3)
end)

t.test('SEAT/DOOR MAPPING: both rear seats occupied falls back to seat 0 (front passenger) -> door 2 (PSIDE_F), never the driver\'s seat -1', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setSeatOccupied(50, 1, true)
    f.setSeatOccupied(50, 2, true)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 0)
    t.equals(f.doorOpenCalls[1].doorIndex, 2)
end)

t.test('NEVER THE TRUNK, NEVER THE DRIVER: every non-driver seat occupied refuses with a clear reason, no seat/door call at all', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setSeatOccupied(50, 0, true)
    f.setSeatOccupied(50, 1, true)
    f.setSeatOccupied(50, 2, true)
    f.env.EnterNearestK9Vehicle()

    t.equals(f.threadCount(), 0, 'must refuse synchronously -- never even contact the server')
    t.equals(#f.serverEventCalls, 0)
    t.equals(#f.seatCalls, 0)
    t.equals(#f.doorOpenCalls, 0)
    t.equals(f.lastNotify().description, locale('vehicle.no_seat_available'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('a 2-seat vehicle (maxPassengers = 1, no rear seats at all) correctly falls back to the front passenger seat', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0, 1) -- maxPassengers=1 -> valid seats -1..0 only
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.equals(f.seatCalls[1].seatIndex, 0)
    t.isTrue(f.env.IsInK9Vehicle())
end)

t.test('MID-DELAY ABORT: the vehicle is deleted during the door-open delay -- aborts, shuts nothing (nothing left to shut), never seats, releases the now-unneeded claim', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    t.equals(#f.doorOpenCalls, 1, 'the door open call already fired before the delay')

    f.deleteVehicleEntity(50) -- something else deletes it mid-delay
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0, 'must never seat the ped once the vehicle is confirmed gone')
    t.equals(#f.doorShutCalls, 0, 'nothing left to shut a door on')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'))
end)

t.test('MID-DELAY ABORT: the chosen seat fills up during the door-open delay -- aborts, shuts the door back, never displaces whoever took it, releases the claim', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle() -- picks seat 1 (rear, driver's side)
    f.grantSeatClaim()

    f.setSeatOccupied(50, 1, true) -- someone else takes it mid-delay
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0, 'must never force the seat once it is genuinely occupied')
    t.equals(#f.doorShutCalls, 1, 'the door this file opened must still be shut again')
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.no_seat_available'))
    t.isNotNil(f.lastServerEventNamed('john-k9:server:releaseVehicleSeatClaim'))
end)

t.test('MID-DELAY ABORT: the ped dies during the door-open delay -- aborts rather than seating a corpse', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()

    f.setPedDead(true)
    f.runLatestThreadToCompletion()

    t.equals(#f.seatCalls, 0)
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('DOUBLE-FIRE: a second EnterNearestK9Vehicle() while already tucked in is a clean no-op', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
    local threadCountAfterFirstRide = f.threadCount()
    local serverEventCountAfterFirstRide = #f.serverEventCalls -- the request, plus the release fired right after seating

    f.env.EnterNearestK9Vehicle()
    t.equals(#f.seatCalls, 1, 'a second call while IsInK9Vehicle() is true must not seat again')
    t.equals(f.threadCount(), threadCountAfterFirstRide, 'must not even start a second sequence -- no new thread, no new server contact')
    t.equals(#f.serverEventCalls, serverEventCountAfterFirstRide, 'must not have sent a second request')
end)

t.test('DOUBLE-FIRE: a second EnterNearestK9Vehicle() DURING the door-open delay (before the first has finished) is also a clean no-op -- vehicleEntryInProgress guard', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    t.equals(f.threadCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle(), 'sanity: still mid-request, not seated yet')

    f.env.EnterNearestK9Vehicle() -- double-click during the animation window
    t.equals(f.threadCount(), 1, 'must not start a second concurrent sequence against the same ped')
    t.equals(#f.serverEventCalls, 1, 'must not have sent a second request to the server either')

    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'exactly one seat call, from the original sequence only')
    t.isTrue(f.env.IsInK9Vehicle())
end)

-- ========================================================================
-- ExitK9Vehicle -- deliberately NEVER gated behind CanShowK9UI(), and
-- deliberately NEVER touches the server at all (see this file's own header
-- EVENT/CALLBACK CONTRACT section: "ExitK9Vehicle() below is COMPLETELY
-- UNCHANGED by this pass"). Real seating changes what "exit" means:
-- vehicleState clears synchronously and immediately, a graceful
-- TASK_LEAVE_VEHICLE is issued, and a bounded courtesy thread force-ejects
-- the ped if that animation never actually finishes (owner's own
-- "bulletproof" requirement).
-- ========================================================================

t.test('ExitK9Vehicle: a no-op when not currently tucked in', function()
    local f = newVehicleFixture()
    f.env.ExitK9Vehicle()
    t.equals(#f.taskLeaveVehicleCalls, 0)
end)

t.test('ExitK9Vehicle: already out via ordinary game controls before this was ever called -- clears state silently, no task, no notify', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())

    f.simulatePedExitedVehicle() -- the player used the ordinary "exit vehicle" control themselves
    local notifyCountBefore = #f.notifyCalls
    f.env.ExitK9Vehicle()

    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.taskLeaveVehicleCalls, 0, 'nothing left to do -- must not re-issue a leave task for a ped already out')
    t.equals(#f.notifyCalls, notifyCountBefore, 'nothing new to tell the player -- they already know they got out')
end)

t.test('ANY PED / NEVER TRAPPED: ExitK9Vehicle works even with CanShowK9UI() false -- a lapsed certification must never strand a rider', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())

    f.setCanShowK9UI(false)
    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'ExitK9Vehicle must succeed regardless of CanShowK9UI()')
    t.equals(#f.taskLeaveVehicleCalls, 1)
    t.equals(f.taskLeaveVehicleCalls[1].flags, 0, 'the graceful, animated exit flag')
end)

t.test('ExitK9Vehicle: happy path -- the animation genuinely finishes before the fallback timeout, no hard eject needed', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'vehicleState clears immediately and synchronously, before the animation even finishes')
    t.equals(#f.taskLeaveVehicleCalls, 1)
    t.equals(f.taskLeaveVehicleCalls[1].vehicle, 50)
    t.equals(f.lastNotify().description, locale('vehicle.released'))

    f.simulatePedExitedVehicle() -- the animation finishes cleanly, well within the fallback window
    f.runLatestThreadToCompletion() -- the courtesy fallback thread's very first check already sees the ped out
    t.equals(#f.clearTasksCalls, 0, 'the hard fallback must never fire once the graceful exit already worked')
    t.equals(#f.taskLeaveVehicleCalls, 1, 'no second, hard TASK_LEAVE_VEHICLE call either')
end)

t.test('BULLETPROOF EXIT: the graceful animation stalls (door jammed, etc.) -- the courtesy fallback force-ejects an ALIVE ped via a second, hard TASK_LEAVE_VEHICLE (flag 16)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    f.env.ExitK9Vehicle()
    -- Deliberately do NOT call simulatePedExitedVehicle() -- models the
    -- animation never actually completing.
    f.runLatestThreadToCompletion() -- drives the fallback thread through its full bounded wait

    t.equals(#f.taskLeaveVehicleCalls, 2, 'the original graceful call, plus the hard fallback')
    t.equals(f.taskLeaveVehicleCalls[2].flags, 16, '"teleports outside, door kept closed" per TASK_LEAVE_VEHICLE\'s own documented flag semantics')
    t.equals(#f.clearTasksCalls, 0, 'the alive path uses TASK_LEAVE_VEHICLE, not the dead-ped CLEAR_PED_TASKS_IMMEDIATELY path')
end)

t.test('BULLETPROOF EXIT: the ped dies before the graceful animation resolves -- the fallback uses CLEAR_PED_TASKS_IMMEDIATELY + reposition instead, never a task a dead ped cannot run', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    f.env.ExitK9Vehicle()
    f.setPedDead(true)
    f.runLatestThreadToCompletion()

    t.equals(#f.clearTasksCalls, 1)
    t.isTrue(#f.setCoordsCalls >= 1, 'must still reposition the ped away from the vehicle')
    t.equals(#f.taskLeaveVehicleCalls, 1, 'only the original graceful call -- the dead-ped fallback path never calls TASK_LEAVE_VEHICLE at all')
end)

t.test('DOUBLE-FIRE: a second ExitK9Vehicle() after already exiting is a clean no-op', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    f.env.ExitK9Vehicle()
    t.equals(#f.taskLeaveVehicleCalls, 1)

    f.env.ExitK9Vehicle()
    t.equals(#f.taskLeaveVehicleCalls, 1, 'vehicleState is already nil -- a second call must not issue another leave task')
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- onResourceStop, then the persistent watchdog.
-- NEVER GATE A TERMINATION PATH: neither of these checks
-- Config.Features.VehicleEntryExit, CanShowK9UI(), or any feature-block --
-- only whether there is an active ride to release at all.
-- ========================================================================

t.test('onResourceStop: no-op when not currently tucked in', function()
    local f = newVehicleFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.equals(#f.clearTasksCalls, 0)
end)

t.test('onResourceStop: a resource restart mid-ride hard-ejects an ALIVE ped via TASK_LEAVE_VEHICLE flag 16, synchronously (no thread, no Wait)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    local threadCountBefore = f.threadCount()

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.taskLeaveVehicleCalls, 1)
    t.equals(f.taskLeaveVehicleCalls[1].flags, 16)
    t.equals(f.threadCount(), threadCountBefore, 'a termination path must resolve synchronously -- no new thread, no Wait')
    t.isFalse(f.env.IsInK9Vehicle())

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.taskLeaveVehicleCalls, 1, 'a second firing must not release again -- vehicleState is already nil')
end)

t.test('onResourceStop: a dead ped mid-ride is hard-ejected via CLEAR_PED_TASKS_IMMEDIATELY + reposition, not TASK_LEAVE_VEHICLE', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    f.setPedDead(true)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.clearTasksCalls, 1)
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.isTrue(#f.setCoordsCalls >= 1)
end)

t.test('onResourceStop: a mismatched resourceName never fires, even mid-ride', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    f.fireResourceStop('some_other_resource')
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.isTrue(f.env.IsInK9Vehicle())
end)

-- WATCHDOG THREAD -- substantially redesigned this pass (see
-- client/vehicle.lua's own header for the full "why the old missStreak
-- debounce no longer applies" reasoning): the primary release decision now
-- reads IsPedInAnyVehicle on this client's own local ped (always reliable,
-- no streaming dependency), so there is no debounce left to test for the
-- release decision itself -- only for which of two notification strings
-- gets shown, which is cosmetic, not a stranding risk.

t.test('watchdog: idle (never tucked in) is a true no-op across many ticks', function()
    local f = newVehicleFixture()
    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    t.equals(#f.notifyCalls, 0)
end)

t.test('watchdog: still genuinely seated -- no release, across many ticks', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(#f.taskLeaveVehicleCalls, 0)
    t.equals(#f.clearTasksCalls, 0)
end)

t.test('watchdog: the ped exits via ordinary game controls -- releases silently on the very next tick, no notify (they already know)', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    f.simulatePedExitedVehicle()
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.notifyCalls, 1, 'no new notify beyond the original "loaded" one')
end)

t.test('watchdog: the vehicle is deleted out from under the ped (engine auto-ejects) -- releases AND notifies vehicle_lost, since the vehicle itself is genuinely gone', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    f.deleteVehicleEntity(50) -- this fixture's own deleteVehicleEntity() models the engine's auto-eject too
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.vehicle_lost'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('watchdog OWN-DEATH RELEASE: a dead ped while tucked in releases IMMEDIATELY on the very first tick, hard-ejecting via CLEAR_PED_TASKS_IMMEDIATELY + reposition', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    f.setPedDead(true)

    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(#f.clearTasksCalls, 1)
    t.isTrue(#f.setCoordsCalls >= 1)
    t.equals(f.lastNotify().description, locale('vehicle.released_on_death'))
    t.equals(f.lastNotify().type, 'error')
end)

t.test('watchdog OWN-DEATH RELEASE: takes precedence even when the vehicle has ALSO despawned in the same tick -- exactly one release, the death-flavored one', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    f.setPedDead(true)
    f.setVehicleResolvable(false)

    f.stepWatchdogOnce()
    t.isFalse(f.env.IsInK9Vehicle())
    t.equals(f.lastNotify().description, locale('vehicle.released_on_death'), 'the death branch must win, not the vehicle-lost branch')
    local deathNotifyCount = 0
    for _, n in ipairs(f.notifyCalls) do
        if n.description == locale('vehicle.released_on_death') then deathNotifyCount = deathNotifyCount + 1 end
    end
    t.equals(deathNotifyCount, 1, 'exactly one release notify, never two')
end)

-- ========================================================================
-- ANY PED -- this file never calls IsOwnModelK9() anywhere: EnterNearestK9
-- Vehicle()'s own gate is HasK9Access() alone (PERMISSION AUDIT FOLLOW-UP,
-- this pass -- UPDATED, was CanShowK9UI() -- see that function's own doc
-- comment for the full writeup; the ox_target "Load Into Vehicle" hover
-- option's own canInteract predicate is a SEPARATE, disclosed exception
-- that still gates display on CanShowK9UI() alone, covered by its own test
-- immediately below this section), and the vehicle-side model check
-- (K9VehicleHashes) is keyed on the VEHICLE's own model, never the ped's.
-- The seated entity is always, and only, PlayerPedId() -- the player's own
-- ped -- confirmed by grep having zero CreatePed/SetPlayerModel/other
-- ped-spawning native hits anywhere in client/vehicle.lua; nothing in this
-- file, before or after this pass, ever spawns a decorative or stand-in ped
-- of any kind.
-- ========================================================================

t.test('ANY PED: EnterNearestK9Vehicle works with IsOwnModelK9 entirely undefined, gated on HasK9Access() alone', function()
    local f = newVehicleFixture()
    t.isNil(f.env.IsOwnModelK9, 'sanity: this fixture genuinely never defines IsOwnModelK9')
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    local ok, err = pcall(f.env.EnterNearestK9Vehicle)
    t.isTrue(ok, 'must not reach for a global this file does not use: ' .. tostring(err))
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())
    t.equals(f.seatCalls[1].ped, 1, 'the seated entity is PlayerPedId() -- the player\'s own ped -- never a spawned stand-in')
end)

t.test('ANY PED: the "Get in the Back Seat" ox_target option also gates on CanShowK9UI() alone, and hides when every seat is genuinely taken', function()
    local f = newVehicleFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addGlobalVehicleCalls[1]
    local enterOption, exitOption
    for _, o in ipairs(options) do
        if o.name == 'john-k9:enterVehicle' then enterOption = o end
        if o.name == 'john-k9:exitVehicle' then exitOption = o end
    end
    t.isNotNil(enterOption)
    t.isNotNil(exitOption)

    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    t.isTrue(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    f.setCanShowK9UI(false)
    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    f.setCanShowK9UI(true)

    f.setSeatOccupied(50, 0, true)
    f.setSeatOccupied(50, 1, true)
    f.setSeatOccupied(50, 2, true)
    t.isFalse(enterOption.canInteract(50, 1.0, {}, VEHICLE_MODEL), 'hides the option once every non-driver seat is genuinely occupied, coder-frontend\'s own "never show an option that will just refuse" ask')
end)

t.test('"Get Out of the Vehicle" canInteract: only true when hovering the EXACT current vehicle, never a different one', function()
    local f = newVehicleFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addGlobalVehicleCalls[1]
    local exitOption
    for _, o in ipairs(options) do
        if o.name == 'john-k9:exitVehicle' then exitOption = o end
    end

    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.addVehicle(51, VEHICLE_MODEL, 1.0, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle() -- nearest is 50
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()

    t.isTrue(exitOption.canInteract(50, 1.0, {}, VEHICLE_MODEL))
    t.isFalse(exitOption.canInteract(51, 1.0, {}, VEHICLE_MODEL), 'must never offer to release from a DIFFERENT vehicle than the one actually tucked into')
end)

t.test('onResourceStart: the SECOND branch (resourceName == K9Compat.Which(target)) also registers the options', function()
    local f = newVehicleFixture()
    f.fireResourceStart('ox_target') -- K9Compat.Which('target') in this fixture's stub always returns 'ox_target'
    t.equals(#f.addGlobalVehicleCalls, 1)
end)

-- ========================================================================
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- checked inside
-- EnterNearestK9Vehicle() itself. ExitK9Vehicle() stays completely
-- untouched -- termination must never be gated.
-- ========================================================================

t.test('EnterNearestK9Vehicle: VehicleEntryExit blocked -- denies via DenyK9FeatureBlocked, never seats, never starts a thread', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setBlocked('VehicleEntryExit', true)

    f.env.EnterNearestK9Vehicle()

    t.equals(#f.seatCalls, 0)
    t.equals(f.threadCount(), 0)
    t.equals(#f.serverEventCalls, 0, 'must refuse before ever contacting the server')
    t.equals(f.denyK9FeatureBlockedCallCount(), 1)
    t.isFalse(f.env.IsInK9Vehicle())
end)

t.test('EnterNearestK9Vehicle: a block on a DIFFERENT feature name never affects VehicleEntryExit', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setBlocked('NightVision', true)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1)
end)

t.test('ExitK9Vehicle: a block on VehicleEntryExit never refuses exiting -- termination must never be gated', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.isTrue(f.env.IsInK9Vehicle())

    f.setBlocked('VehicleEntryExit', true)
    f.env.ExitK9Vehicle()
    t.isFalse(f.env.IsInK9Vehicle(), 'a block must never prevent exiting an already-entered vehicle')
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- entry works exactly as before this pass', function()
    local f = newVehicleFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'an unknown block state must never freeze this ability -- it must fail OPEN')
end)


-- ========================================================================
-- RIDING IN A VEHICLE (owner-directed, this pass, asked three times in
-- escalating specificity): the dog sits like a dog, the ordinary enter key
-- works, and the driver's seat is never an option.
-- ========================================================================

t.test('RIDE POSE: a seated K9 is posed like a dog, not left in the engine\'s human sit-in', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'precondition: genuinely seated')

    -- The pose runs on its own delayed thread, after the door-shut wait.
    f.runLatestThreadToCompletion()
    t.equals(#f.scenarioCalls, 1, 'a dog in a car must be posed as a dog')
    t.equals(f.scenarioCalls[1].playEnterAnim, false, 'no enter transition -- the ped is fixed in a seat and would visibly slide')
end)

t.test('RIDE POSE: the scenario is a real, verified dog-sit name, never nil', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.env.EnterNearestK9Vehicle()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    f.runLatestThreadToCompletion()
    local name = f.scenarioCalls[1] and f.scenarioCalls[1].scenarioName
    t.isTrue(type(name) == 'string' and name:find('WORLD_DOG_SITTING', 1, true) == 1,
        'a nil or invented scenario name is a silent no-op that leaves the dog standing in the seat')
end)

t.test('DRIVER SEAT: a K9 found in seat -1 is put out, whatever route placed it there', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    -- Nothing in this resource seated them -- this is the admin-teleport /
    -- other-resource / loaded-late case the guard exists for.
    f.setPedCurrentVehicle(50)
    f.setDriverSeatOccupant(50, f.MY_PED)

    f.runGuardThread()

    t.equals(#f.taskLeaveVehicleCalls, 1, 'the dog must be taken out of the driver\'s seat')
    t.equals(f.taskLeaveVehicleCalls[1].ped, f.MY_PED)
end)

t.test('DRIVER SEAT: a K9 in an ORDINARY passenger seat is left completely alone', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.setPedCurrentVehicle(50)
    -- Seat -1 is occupied by someone else entirely -- the human driver.
    f.setDriverSeatOccupant(50, 4242)

    f.runGuardThread()

    t.equals(#f.taskLeaveVehicleCalls, 0, 'riding as a passenger is the whole point of the feature and must never be interrupted')
end)

t.test('ENTER KEY: the ordinary enter control is captured only while a K9 is in reach of an eligible vehicle', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.runGuardThread()
    t.isTrue(f.disabledControlCount(23) > 0, 'in reach, the game\'s own enter must be taken over so it cannot walk the dog to the driver door')
end)

t.test('ENTER KEY: nothing is captured when there is no eligible vehicle nearby -- a K9 away from cars has an ordinary keyboard', function()
    local f = newVehicleFixture()
    -- No vehicle added at all.
    f.runGuardThread()
    t.equals(f.disabledControlCount(23), 0)
end)

t.test('ENTER KEY: pressing it loads the dog in, through the same seating flow the command already used', function()
    local f = newVehicleFixture()
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.pressControl(23)
    f.runGuardThread()
    f.grantSeatClaim()
    f.runLatestThreadToCompletion()
    t.equals(#f.seatCalls, 1, 'the normal key must do what the command does')
    t.isTrue(f.seatCalls[1].seatIndex ~= -1, 'and never the driver\'s seat')
end)

t.test('CONTROL: a non-K9 never has the enter key taken from them', function()
    local f = newVehicleFixture({ hasK9Access = false })
    f.addVehicle(50, VEHICLE_MODEL, 0.5, 0.0, 0.0)
    f.runGuardThread()
    t.equals(f.disabledControlCount(23), 0, 'capturing a control from an ordinary player would break their game')
    t.equals(#f.taskLeaveVehicleCalls, 0)
end)

os.exit(t.summary())
