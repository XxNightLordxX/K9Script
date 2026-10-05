--[[
    tests/clientkennel_spec.lua

    Direct, black-box tests of client/kennel.lua against the REAL,
    unmodified production file -- the client half of
    Config.Features.DeployableKennel (server/kennel.lua's own header is the
    authoritative contract). One of six client files this pass writes a
    spec for (see tests/vehiclecombatguard_spec.lua's own header, whose
    disclosed gap this batch exists to close).

    STYLE: follows tests/clientcombat_spec.lua/tests/clientmovement_spec.lua
    -- fresh sandbox per test, a local fixture Config (never the real
    config.lua, so this spec keeps passing regardless of how config.lua's
    other Config.Features flags are set on any given day, whatever their
    current count is), K9Compat + a real
    ox_target adapter loaded exactly the way
    tests/vehiclecombatguard_spec.lua already established for a client file
    that routes its ox_target registration through
    K9Compat.Get('target') -- never a hand-written fake translation layer,
    which would just assert against itself.

    NET-EVENT DISPATCH RUNS INSIDE A FRESH COROUTINE, mirroring
    tests/clientagility_spec.lua's `runVault()`: `deployKennelAt`'s own
    LoadModelWithTimeout can call `Wait(50)` in a real poll loop (mirrors
    the real RequestModel/HasModelLoaded pattern), and FiveM's own
    RegisterNetEvent handlers already run inside their own coroutine
    context in production -- exactly what makes that Wait() call legal at
    all. `dispatchNetEvent()` below wraps every captured handler invocation
    in `coroutine.create`/`coroutine.resume`, draining it to completion
    regardless of how many times (zero or more) it yields, so the SAME
    helper works uniformly whether or not a given test's model-load
    behavior ever actually yields.

    WATCHDOG THREAD -- CAPTURE, DON'T AUTO-RUN, mirroring
    tests/clientvehicle_spec.lua's own identical convention (see that
    file's header "THREE DIFFERENT CreateThread LIFETIMES"): this file has
    exactly ONE CreateThread call (the shared rest/carry watchdog, near the
    bottom of client/kennel.lua), so `capturedThreads[1]` always names it.
    `stepWatchdogOnce()` below resumes it exactly once per call (one full
    loop body, up to and including its own `Wait(sleepMs)`), so a test can
    assert on exactly what one tick of that thread does without needing to
    predict how many resumes an unrelated change might require.

    TWO REAL DEFECTS FOUND WHILE WRITING THIS SPEC (an earlier pass), BOTH
    FIXED (client/kennel.lua's own "REGISTRATION-TIME FEATURE GATE" and
    "STALE-KENNEL GUARD" comments are the fixes themselves) -- kept as a
    record of what was wrong and what changed, per this project's own "do
    not leave a stale finding claiming a fixed bug is still current" rule:

    1. NOT GENUINELY INERT WITH THE FEATURE OFF (FIXED) -- see the
       REGISTRATION-TIME FEATURE GATE tests below.
    2. NO STALE-KENNEL GUARD ON deployKennelAt (FIXED) -- see the dedicated
       test below.

    K9-CAN-RIDE-ALONG PASS (this pass) -- adds tests for
    pickupKennelConfirmed/putDownKennelAt/enterKennelConfirmed/
    kennelCarrierLost, the carry-aware RequestDeployKennel() branch, the
    Enter/Exit Kennel ox_target options, IsRestingInKennel()/
    IsCarryingKennel(), and the shared watchdog thread's own-death/
    wander-off/entity-lost/carry-reassertion branches. See
    server/kennel.lua's own header CRITICAL SAFETY section for the full
    architecture this pins from the client side.

    TRAP-HUNT FIX (this pass, coder-frontend): a real, high-probability
    stranding trap was found in "Rest in Kennel" -- the ONLY pre-existing
    exit was re-selecting the same small (likely camera-occluding) kennel
    prop through ox_target, with no radial entry, no keybind. This pass
    adds ExitKennelRest() (a globally-exposed, gate-free wrapper over
    ReleaseKennelRest()), a k9exitkennel keybind (client/keybinds.lua), and
    an "Exit Kennel" radial item (client/radial.lua). It ALSO corrects a
    real false claim this file's own former "WANDER-OFF EXIT" test
    inherited from client/kennel.lua's own (now-fixed) comment: "simply
    walking away is ALREADY an unconditional... way out" -- VERIFIED FALSE,
    since AttachEntityToEntity re-clamps the occupant's position to the
    kennel's bone every tick regardless of movement input (see
    client/combat.lua's own PROP DRAGGING header for the same finding
    applied to its own dragged target). See the "EXITKENNELREST" and
    "REQUIRED (trap-hunt brief)" test sections below for the new coverage,
    and the corrected WATCHDOG test's own new name for the corrected
    framing.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'john-k9'
local PRIMARY_MODEL = 'prop_dog_cage_01'
local FALLBACK_MODEL = 'prop_tennis_ball'
local MY_PED = 9001

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- the shared watchdog thread's own wander-off check
-- does `#(GetEntityCoords(ped) - GetEntityCoords(kennelEntity))`. Same
-- shape as tests/kennel_spec.lua's own identical Vec3MT stub (added for
-- the equivalent server-side native this pass).
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

--- @param opts { deployableKennel: boolean? }?
--- @return table fixture
local function newKennelFixture(opts)
    opts = opts or {}

    local canShowK9UI = true
    local canShowK9UICalls = 0
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- K9-CAN-RIDE-ALONG PASS -- client/main.lua's own real HasK9Access() is
    -- an awaited server callback; this fixture stubs it as a plain
    -- controllable boolean, same level of abstraction CanShowK9UI() above
    -- already uses. Defaults to true so pickup-related tests that don't
    -- care about this gate specifically don't need to opt in every time.
    local hasK9AccessValue = true
    local hasK9AccessCalls = 0
    local function HasK9Access() hasK9AccessCalls = hasK9AccessCalls + 1; return hasK9AccessValue end

    -- ANY PED -- this file never calls IsOwnModelK9() as a hard dependency;
    -- it is consulted ONLY via a `type(IsOwnModelK9) == 'function'` soft
    -- guard on the "Rest in Kennel" option's own canInteract. Defaults to
    -- true (a K9-modeled ped) so tests that don't care about this specific
    -- display optimization aren't forced to opt in.
    local isOwnModelK9Value = true
    local function IsOwnModelK9() return isOwnModelK9Value end

    -- KENNEL-VS-VEHICLE MUTUAL GUARD (this pass) -- IsInK9Vehicle()
    -- (client/vehicle.lua) controllable stand-in, same soft-dependency shape
    -- as IsOwnModelK9()/HasK9Access() above. `opts.inK9VehicleAvailable`
    -- defaults to true; set false to model a server that never loads
    -- client/vehicle.lua at all (Config.Features.VehicleEntryExit off),
    -- proving this file's own `type(fn) == 'function'` guard degrades to
    -- "skip this check" rather than erroring.
    local inK9VehicleAvailable = opts.inK9VehicleAvailable
    if inK9VehicleAvailable == nil then inK9VehicleAvailable = true end
    local isInK9Vehicle = opts.isInK9Vehicle or false

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    -- CLOSEABLE KENNEL (this pass) -- `getOwnKennelDoorState` callback
    -- stand-in, same "queue of canned responses, defaulting to a sane
    -- value" shape as every other callbackAwait fixture in this suite.
    -- Defaults to `{ ok = true, closed = false, occupied = false }` (an
    -- open, empty kennel) so every PRE-EXISTING "ENTERS" test written
    -- before this callback existed keeps exercising the enter path without
    -- needing to opt in.
    local callbackResponseQueue = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local queued = table.remove(callbackResponseQueue, 1)
        if queued ~= nil then return queued end
        return { ok = true, closed = false, occupied = false }
    end
    lib.callback = { await = callbackAwait }

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local commands = {}
    local function RegisterCommand(name, handler, restricted)
        commands[#commands + 1] = { name = name, handler = handler, restricted = restricted }
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- CAPTURE, DON'T AUTO-RUN -- see this file's own header for the full
    -- rationale (mirrors tests/clientvehicle_spec.lua's identical
    -- convention). This file has exactly ONE CreateThread call (the shared
    -- rest/carry watchdog), so capturedThreads[1] always names it.
    local capturedThreads = {}
    local function CreateThread(fn)
        capturedThreads[#capturedThreads + 1] = coroutine.create(fn)
    end
    local waitCalls = {}
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms; coroutine.yield() end

    -- ---- model loading ----
    -- modelBehavior[hash] = 'loads' (default) | 'timeout' | 'invalid'
    local modelBehavior = {}
    local requestModelCalls, releaseModelCalls = {}, {}
    local printLines = {}
    local function IsModelValid(hash) return modelBehavior[hash] ~= 'invalid' end
    local function RequestModel(hash) requestModelCalls[#requestModelCalls + 1] = hash end
    local function HasModelLoaded(hash) return modelBehavior[hash] ~= 'timeout' end
    local function SetModelAsNoLongerNeeded(hash) releaseModelCalls[#releaseModelCalls + 1] = hash end

    -- ---- object/ped lifecycle -- ONE shared handle space, exactly like a
    -- real client (peds and objects are both just entity handles) ----
    local objectSeq = 0
    local objectBehavior = {} -- default: real object, real ground placement
    local existingEntities = { [MY_PED] = true }
    local entityModels = {}
    local createObjectCalls, deleteEntityCalls, freezeCalls, placeCalls = {}, {}, {}, {}
    local function CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag)
        objectSeq = objectSeq + 1
        local entity = objectSeq
        createObjectCalls[#createObjectCalls + 1] = { entity = entity, modelHash = modelHash, x = x, y = y, z = z }
        if objectBehavior.createFails then
            return 0
        end
        existingEntities[entity] = true
        entityModels[entity] = modelHash
        return entity
    end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityModel(entity) return entityModels[entity] end
    local function PlaceObjectOnGroundProperly(entity)
        placeCalls[#placeCalls + 1] = entity
        return not objectBehavior.groundFails
    end
    local function FreezeEntityPosition(entity, toggle) freezeCalls[#freezeCalls + 1] = { entity = entity, toggle = toggle } end
    local function DeleteEntity(entity)
        deleteEntityCalls[#deleteEntityCalls + 1] = entity
        existingEntities[entity] = nil
    end

    -- K9-CAN-RIDE-ALONG PASS -- coords/heading are a SHARED table keyed by
    -- ANY handle (ped or object alike, exactly like the real natives).
    local coordsByHandle = { [MY_PED] = { x = 0, y = 0, z = 0 } }
    local headingByHandle = { [MY_PED] = 0.0 }
    local function GetEntityCoords(handle)
        local c = coordsByHandle[handle] or { x = 0, y = 0, z = 0 }
        return vec3(c.x, c.y, c.z)
    end
    local function GetEntityHeading(handle) return headingByHandle[handle] or 0.0 end
    local setCoordsCalls, setHeadingCalls = {}, {}
    -- REST POSE (owner-reported "make sure the dog actually shows up in the
    -- kennel" fix). Both of these are recorded rather than merely stubbed
    -- because the ORDER of ClearPedTasksImmediately relative to
    -- SetEntityCoords/AttachEntityToEntity is the whole point of the fix --
    -- a stub that only proved "it was called" would pass just as happily
    -- with the clear running AFTER the attach, which is the broken shape.
    -- callSeq is a single shared monotonic counter every one of the four
    -- relevant natives stamps itself with, so a test can assert real
    -- sequencing instead of just presence.
    local callSeq = 0
    local function NextSeq() callSeq = callSeq + 1 return callSeq end

    local function SetEntityCoords(handle, x, y, z, ...)
        coordsByHandle[handle] = { x = x, y = y, z = z }
        setCoordsCalls[#setCoordsCalls + 1] = { handle = handle, x = x, y = y, z = z, seq = NextSeq() }
    end
    local function SetEntityHeading(handle, heading)
        headingByHandle[handle] = heading
        setHeadingCalls[#setHeadingCalls + 1] = { handle = handle, heading = heading }
    end

    local collisionCalls = {}
    local function SetEntityCollision(handle, toggle, keepPhysics)
        collisionCalls[#collisionCalls + 1] = { handle = handle, toggle = toggle, keepPhysics = keepPhysics }
    end

    local detachCalls = {}
    local function DetachEntity(handle, dynamic, collision)
        detachCalls[#detachCalls + 1] = { handle = handle, dynamic = dynamic, collision = collision, seq = NextSeq() }
    end

    local attachCalls = {}
    local function AttachEntityToEntity(entity1, entity2, boneIndex, xPos, yPos, zPos, xRot, yRot, zRot, p9, useSoftPinning, collision, isPed, rotationOrder, syncRot)
        attachCalls[#attachCalls + 1] = {
            entity1 = entity1, entity2 = entity2, boneIndex = boneIndex,
            xPos = xPos, yPos = yPos, zPos = zPos, xRot = xRot, yRot = yRot, zRot = zRot,
            isPed = isPed, seq = NextSeq(),
        }
    end

    local controlRequestCalls = {}
    local function NetworkRequestControlOfEntity(entity) controlRequestCalls[#controlRequestCalls + 1] = entity end

    local clearTasksCalls = {}
    local function ClearPedTasksImmediately(ped)
        clearTasksCalls[#clearTasksCalls + 1] = { ped = ped, seq = NextSeq() }
    end

    local scenarioCalls = {}
    local function TaskStartScenarioInPlace(ped, scenarioName, unkDelay, playEnterAnim)
        scenarioCalls[#scenarioCalls + 1] = {
            ped = ped, scenarioName = scenarioName,
            unkDelay = unkDelay, playEnterAnim = playEnterAnim, seq = NextSeq(),
        }
    end

    local deadPeds = {}
    local function IsEntityDead(ped) return deadPeds[ped] == true end

    local function PlayerPedId() return MY_PED end

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
    -- ResolveNetworkEntity -- this spec tests client/kennel.lua, not
    -- client/main.lua's own resolve sequence (already covered elsewhere).
    -- The optional second (expectedEntityType) argument client/kennel.lua
    -- now passes at some call sites is deliberately NOT modeled/enforced
    -- here -- same level of abstraction the pre-existing stub already
    -- used for the single-argument call sites.
    local function ResolveNetworkEntity(netId)
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    -- ---- K9Compat -- DIRECT stub, not the real shared/compat/core.lua +
    -- shared/compat/target.lua adapter pair. See this file's own header.
    local addModelCalls = {}
    local redetectCallCount = 0
    local K9Compat = {
        Get = function(_system)
            return {
                AddModel = function(models, options) addModelCalls[#addModelCalls + 1] = { models = models, options = options } end,
            }
        end,
        Redetect = function() redetectCallCount = redetectCallCount + 1 end,
        Which = function(_system) return 'ox_target' end,
    }

    local config = {
        Features = { DeployableKennel = opts.deployableKennel ~= false },
        DeployableKennel = {
            propModel = PRIMARY_MODEL,
            fallbackPropModel = FALLBACK_MODEL,
            interactDistanceMeters = 2.5,
            carryBoneIndex = 0,
            carryOffsetX = 0.0,
            carryOffsetY = 0.3,
            carryOffsetZ = 0.35,
            carryRotX = 0.0,
            carryRotY = 0.0,
            carryRotZ = 0.0,
            restOffsetX = 0.0,
            restOffsetY = 0.0,
            restOffsetZ = 0.0,
        },
    }

    local env = Sandbox.newEnv({
        Config = config,
        GetHashKey = GetHashKey,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        IsOwnModelK9 = IsOwnModelK9,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CreateThread,
        IsModelValid = IsModelValid,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        Wait = Wait,
        CreateObject = CreateObject,
        DoesEntityExist = DoesEntityExist,
        GetEntityModel = GetEntityModel,
        PlaceObjectOnGroundProperly = PlaceObjectOnGroundProperly,
        FreezeEntityPosition = FreezeEntityPosition,
        DeleteEntity = DeleteEntity,
        GetEntityCoords = GetEntityCoords,
        GetEntityHeading = GetEntityHeading,
        SetEntityCoords = SetEntityCoords,
        SetEntityHeading = SetEntityHeading,
        SetEntityCollision = SetEntityCollision,
        DetachEntity = DetachEntity,
        AttachEntityToEntity = AttachEntityToEntity,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
        IsEntityDead = IsEntityDead,
        PlayerPedId = PlayerPedId,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
        print = function(line) printLines[#printLines + 1] = line end,
        K9Compat = K9Compat,
    })
    if inK9VehicleAvailable then
        env.IsInK9Vehicle = function() return isInK9Vehicle end
    end

    Sandbox.loadInto('../client/kennel.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        commands = commands,
        netEventNames = netEvents,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEvents) do n = n + 1 end
            return n
        end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        addModelCalls = addModelCalls,
        redetectCallCount = function() return redetectCallCount end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICalls end,
        denyCallCount = function() return denyCalls end,
        setHasK9Access = function(v) hasK9AccessValue = v end,
        hasK9AccessCallCount = function() return hasK9AccessCalls end,
        setIsOwnModelK9 = function(v) isOwnModelK9Value = v end,
        setModelBehavior = function(modelName, behavior) modelBehavior[GetHashKey(modelName)] = behavior end,
        setObjectBehavior = function(t2) objectBehavior = t2 or {} end,
        requestModelCalls = requestModelCalls,
        releaseModelCalls = releaseModelCalls,
        createObjectCalls = createObjectCalls,
        deleteEntityCalls = deleteEntityCalls,
        freezeCalls = freezeCalls,
        placeCalls = placeCalls,
        waitCalls = waitCalls,
        printLines = printLines,
        setEntityMissing = function(entity) existingEntities[entity] = nil end,
        setCoords = function(handle, x, y, z) coordsByHandle[handle] = { x = x, y = y, z = z } end,
        setHeading = function(handle, heading) headingByHandle[handle] = heading end,
        setCoordsCalls = setCoordsCalls,
        setHeadingCalls = setHeadingCalls,
        callbackCallLog = callbackCallLog,
        queueDoorStateResponse = function(v) callbackResponseQueue[#callbackResponseQueue + 1] = v end,
        collisionCalls = collisionCalls,
        detachCalls = detachCalls,
        attachCalls = attachCalls,
        clearTasksCalls = clearTasksCalls,
        scenarioCalls = scenarioCalls,
        lastAttachCall = function() return attachCalls[#attachCalls] end,
        controlRequestCalls = controlRequestCalls,
        setPedDead = function(ped, dead) deadPeds[ped] = dead end,
        setInK9Vehicle = function(v) isInK9Vehicle = v end,
        MY_PED = MY_PED,
        --- Registers a networked entity THIS handler did not itself create
        --- via deployKennelAt (e.g. some other feature's prop, or another
        --- player's real vehicle/ped) -- used only by the DEFENSE-IN-DEPTH
        --- MODEL CHECK test below, which needs a resolvable netId whose
        --- entity is deliberately NOT a configured kennel prop model.
        registerForeignEntity = function(netId, entity, modelHash, coords)
            existingEntities[entity] = true
            entityModels[entity] = modelHash
            netIdByEntity[entity] = netId
            if coords then coordsByHandle[entity] = coords end
        end,
        --- Runs a captured RegisterNetEvent handler to completion inside its
        --- own fresh coroutine -- see this file's header for why.
        dispatchNetEvent = function(eventName, sourceValue, ...)
            local handler = assert(netEvents[eventName], 'no handler registered for ' .. eventName)
            env.source = sourceValue
            local co = coroutine.create(handler)
            local ok, err = coroutine.resume(co, ...)
            if not ok then error('dispatchNetEvent(' .. eventName .. '): ' .. tostring(err)) end
            while coroutine.status(co) ~= 'dead' do
                ok, err = coroutine.resume(co)
                if not ok then error('dispatchNetEvent(' .. eventName .. ') mid-flight: ' .. tostring(err)) end
            end
        end,
        --- Resumes the shared watchdog thread exactly once -- one full loop
        --- body, up to and including its own trailing Wait(sleepMs). See
        --- this file's own header.
        stepWatchdogOnce = function()
            local co = capturedThreads[1]
            if not co then return end
            local ok, err = coroutine.resume(co)
            if not ok then error('kennel fixture: watchdog thread errored: ' .. tostring(err)) end
        end,
        watchdogThreadCount = function() return #capturedThreads end,
    }
end

-- ========================================================================
-- FEATURE OFF -- pins the FIXED behavior: genuinely inert at the
-- REGISTRATION level (see this file's header, fixed defect #1), not merely
-- internally no-op.
-- ========================================================================

t.test('FIXED: feature off registers no GATED net events, onResourceStart/onResourceStop handlers, or threads -- ONLY k9kennel and the forced-exit event survive, unconditionally, both exit-path-critical (docs/history/COMMAND_CONSOLIDATION_SPEC.md #5)', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.equals(#f.commands, 1, 'k9deploykennel is not registered with the feature off, but k9kennel IS -- its own exit branch must survive a toggled-off feature, same reasoning as k9exitkennel')
    t.equals(f.commands[1].name, 'k9kennel')
    -- ONE net event survives the feature being off, deliberately:
    -- 'forceExitKennelRest'. It is the client half of server/kennel.lua's
    -- forced release when a player loses K9 access while resting inside a
    -- kennel, and it is a pure EXIT path -- exactly the k9kennel command's
    -- own reasoning one line above. GATE THE START OF A THING, NEVER THE
    -- STOP: an operator toggling DeployableKennel off mid-session must not
    -- be able to strand a resting player by removing the only thing that
    -- could let them out. The other six, all of which START or MUTATE
    -- something, stay gated.
    t.equals(f.netEventCount(), 1, 'only the forced-exit release event is registered with the feature off -- none of this file\'s six GATED net events is')
    t.isNotNil(f.netEventNames['john-k9:client:forceExitKennelRest'], 'the forced-exit release path must survive a toggled-off feature')
    t.equals(f.onResourceStartHandlerCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
    t.equals(f.watchdogThreadCount(), 0, 'the shared watchdog thread must not even start with the feature off')
end)

t.test('feature off: RequestDeployKennel() itself stays defined and reachable-but-inert (the per-handler check inside the function), for client/radial.lua/client/tablet.lua\'s own call sites', function()
    local f = newKennelFixture({ deployableKennel = false })
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 0)
    t.equals(f.canShowK9UICallCount(), 0, 'the feature-flag check short-circuits before ever consulting CanShowK9UI()')
end)

t.test('feature off: IsRestingInKennel()/IsCarryingKennel() stay defined and simply report false -- never nil, never erroring', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.isFalse(f.env.IsRestingInKennel())
    t.isFalse(f.env.IsCarryingKennel())
end)

t.test('FIXED: feature off -- none of this file\'s six net events exists to dispatch at all (previously registered but internally no-op; now not registered)', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.isNil(f.netEventNames['john-k9:client:deployKennelAt'])
    t.isNil(f.netEventNames['john-k9:client:removeKennel'])
    t.isNil(f.netEventNames['john-k9:client:pickupKennelConfirmed'])
    t.isNil(f.netEventNames['john-k9:client:putDownKennelAt'])
    t.isNil(f.netEventNames['john-k9:client:enterKennelConfirmed'])
    t.isNil(f.netEventNames['john-k9:client:kennelCarrierLost'])
    -- Deliberately NOT asserted nil here: forceExitKennelRest is the
    -- seventh event and is registered unconditionally on purpose -- see the
    -- first feature-off test above.
end)

-- ========================================================================
-- Sanity + happy path
-- ========================================================================

t.test('feature on: registers exactly 2 commands (k9deploykennel + the additive k9kennel), 7 net events (6 gated + the always-on forced-exit release), 1 onResourceStart, 1 onResourceStop, and starts the shared watchdog thread', function()
    local f = newKennelFixture()
    t.equals(#f.commands, 2)
    local names = {}
    for _, c in ipairs(f.commands) do names[c.name] = true end
    t.isTrue(names['k9deploykennel'])
    t.isTrue(names['k9kennel'])
    t.equals(f.netEventCount(), 7)
    t.isNotNil(f.netEventNames['john-k9:client:forceExitKennelRest'], 'registered unconditionally -- see the feature-off test above')
    t.isNotNil(f.netEventNames['john-k9:client:deployKennelAt'])
    t.isNotNil(f.netEventNames['john-k9:client:removeKennel'])
    t.isNotNil(f.netEventNames['john-k9:client:pickupKennelConfirmed'])
    t.isNotNil(f.netEventNames['john-k9:client:putDownKennelAt'])
    t.isNotNil(f.netEventNames['john-k9:client:enterKennelConfirmed'])
    t.isNotNil(f.netEventNames['john-k9:client:kennelCarrierLost'])
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
    t.equals(f.watchdogThreadCount(), 1)
end)

-- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission audit
-- finding, this pass) -- see RequestDeployKennel()'s own "GATE WIDENED" doc
-- comment. Deploying a kennel is a HUMAN HANDLER action, gated the same way
-- "Pick Up Kennel" already is (see that option's own HasK9Access()-only
-- tests further below).

t.test('CONTROL: RequestDeployKennel: HasK9Access() false denies locally with reason combat.no_access, no server contact', function()
    local f = newKennelFixture()
    f.setHasK9Access(false)
    f.env.RequestDeployKennel()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('GATE WIDENED: RequestDeployKennel: HasK9Access() true with CanShowK9UI() false (High Command/autoAccessGrade-bypass shape) still reaches the server', function()
    local f = newKennelFixture()
    f.setHasK9Access(true)
    f.setCanShowK9UI(false)
    f.env.RequestDeployKennel()
    t.equals(f.denyCallCount(), 0, 'a HasK9Access()-true bypass holder must never be denied even though CanShowK9UI() would have refused them')
    t.equals(#f.serverEvents, 1, 'a HasK9Access()-true bypass holder must reach the server even though CanShowK9UI() would have refused them')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDeployKennel')
end)

t.test('RequestDeployKennel: happy path sends the real requestDeployKennel event', function()
    local f = newKennelFixture()
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDeployKennel')
    t.equals(#f.lastServerEvent().args, 0)
end)

t.test('deployKennelAt: happy path -- primary model loads immediately, object created, grounded, frozen, netId reported back', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 100.0, 200.0, 30.0)
    t.equals(#f.createObjectCalls, 1)
    t.equals(f.createObjectCalls[1].x, 100.0)
    t.equals(#f.placeCalls, 1)
    t.equals(#f.freezeCalls, 1)
    t.equals(f.freezeCalls[1].toggle, true)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:confirmKennelPlaced')
    t.equals(#f.waitCalls, 0, 'a model that loads immediately never yields at all')
end)

t.test('deployKennelAt: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 1, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
end)

t.test('deployKennelAt: non-number coordinate arguments are rejected, no object created', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 'x', 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
end)

t.test('deployKennelAt: primary model times out -- falls back to fallbackPropModel, releases the primary\'s streaming reference (LEAK FIX), and logs a breadcrumb', function()
    local f = newKennelFixture()
    f.setModelBehavior(PRIMARY_MODEL, 'timeout')
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 1, 'must still succeed using the fallback')
    t.equals(f.createObjectCalls[1].modelHash, GetHashKey(FALLBACK_MODEL))
    t.equals(#f.waitCalls, 100, 'exactly REQUEST_MODEL_TIMEOUT_MS/50 = 100 polls for the stuck primary')
    t.isTrue(#f.releaseModelCalls >= 1, 'the timed-out primary\'s streaming reference must be released, not leaked')
    t.equals(#f.printLines, 1, 'a fallback breadcrumb must be printed for a server operator to notice')
end)

t.test('deployKennelAt: BOTH primary and fallback fail to load -- notifies, cancels placement, never touches CreateObject', function()
    local f = newKennelFixture()
    f.setModelBehavior(PRIMARY_MODEL, 'invalid')
    f.setModelBehavior(FALLBACK_MODEL, 'invalid')
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
    t.equals(f.lastNotify().description, locale('kennel.prop_load_failed'))
    t.equals(f.lastServerEvent().event, 'john-k9:server:cancelKennelPlacement')
end)

t.test('deployKennelAt: CreateObject fails -- notifies, cancels placement', function()
    local f = newKennelFixture()
    f.setObjectBehavior({ createFails = true })
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(f.lastNotify().description, locale('kennel.placement_failed'))
    t.equals(f.lastServerEvent().event, 'john-k9:server:cancelKennelPlacement')
end)

t.test('deployKennelAt: PlaceObjectOnGroundProperly fails -- deletes the just-created object, notifies, cancels placement', function()
    local f = newKennelFixture()
    f.setObjectBehavior({ groundFails = true })
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 1)
    t.equals(#f.deleteEntityCalls, 1, 'a kennel the game could not ground properly must never be confirmed')
    t.equals(f.lastNotify().description, locale('kennel.no_suitable_ground'))
    t.equals(f.lastServerEvent().event, 'john-k9:server:cancelKennelPlacement')
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- the highest-priority area per this task's own
-- brief.
-- ========================================================================

t.test('onResourceStop: no-op when no kennel was ever deployed', function()
    local f = newKennelFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('onResourceStop: deletes a still-resolvable, self-deployed kennel, and is idempotent on a second firing', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.serverEvents, 1)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'the kennel this client itself created must be deleted on a resource restart, per this file\'s own "ship-blocking QA finding" comment')

    f.fireResourceStop(RESOURCE_NAME) -- fired twice, e.g. two AddEventHandler-registered listeners in practice
    t.equals(#f.deleteEntityCalls, 1, 'myKennelNetId is nil by the second firing -- must not attempt a second delete')
end)

t.test('onResourceStop: a kennel that is no longer resolvable (streamed out / already gone) is a clean no-op, but myKennelNetId is still cleared', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    -- Simulate the object no longer existing on this client (streamed out) --
    -- the ONLY entity created so far is handle 1.
    f.setEntityMissing(1)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 0, 'ResolveNetworkEntity returning nil must never be treated as an error')

    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 2, 'a second requestDeployKennel must reach the server -- the stale netId must not permanently block future deploys')
end)

t.test('onResourceStop: a mismatched resourceName never fires, even with a live kennel deployed', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    f.fireResourceStop('some_other_resource')
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('SAFETY: onResourceStop while resting unconditionally detaches this client\'s own ped and restores collision, with no server round trip required', function()
    local f = newKennelFixture()
    local netId = 500
    f.registerForeignEntity(netId, 42, GetHashKey(PRIMARY_MODEL), { x = 5, y = 5, z = 0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.fireResourceStop(RESOURCE_NAME)
    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
end)

t.test('SAFETY: onResourceStop while carrying detaches the carried object (never deletes it -- server/kennel.lua\'s own sweep owns that)', function()
    local f = newKennelFixture()
    local netId = 501
    f.registerForeignEntity(netId, 43, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsCarryingKennel())

    f.fireResourceStop(RESOURCE_NAME)
    t.isFalse(f.env.IsCarryingKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == 43)
    t.isNil(f.deleteEntityCalls[1], 'the carried object must not be deleted client-side -- an occupant could be attached to it')
end)

t.test('removeKennel (cleanup backstop): source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local netId = f.lastServerEvent().args[1]
    f.dispatchNetEvent('john-k9:client:removeKennel', 1, netId)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel: non-number netId is rejected', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:removeKennel', 65535, 'not-a-number')
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel: an unresolvable netId (not streamed in) is a clean no-op', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:removeKennel', 65535, 999999)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeKennel: DEFENSE-IN-DEPTH MODEL CHECK -- a resolvable netId whose CURRENT model is NOT a configured kennel prop is never deleted, even though the source guard and feature gate both pass', function()
    local f = newKennelFixture()
    f.registerForeignEntity(777, 50, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('john-k9:client:removeKennel', 65535, 777)
    t.equals(#f.deleteEntityCalls, 0, 'an entity whose live model is not an allowlisted kennel prop must never be deleted by this handler, regardless of what netId the server named')
end)

t.test('removeKennel: the ACCEPT side of the same allowlist -- a resolvable netId whose model matches the FALLBACK prop (not just the primary) is deleted too', function()
    local f = newKennelFixture()
    f.registerForeignEntity(778, 51, GetHashKey(FALLBACK_MODEL))
    f.dispatchNetEvent('john-k9:client:removeKennel', 65535, 778)
    t.equals(#f.deleteEntityCalls, 1, 'the fallback prop model must be allowlisted exactly like the primary')
end)

t.test('removeKennel: happy path -- resolves the real kennel entity (matching the configured propModel), clears myKennelNetId, deletes it', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local netId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('john-k9:client:removeKennel', 65535, netId)
    t.equals(#f.deleteEntityCalls, 1)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'onResourceStop must not attempt a SECOND delete of the already-removed kennel')
end)

t.test('SAFETY: removeKennel for the netId THIS client is resting in forces an unconditional local release, even though pickup no longer triggers this path in the ordinary case', function()
    local f = newKennelFixture()
    local netId = 502
    f.registerForeignEntity(netId, 44, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.dispatchNetEvent('john-k9:client:removeKennel', 65535, netId)
    t.isFalse(f.env.IsRestingInKennel(), 'defense-in-depth: this client must never depend on an ordinary pickup being the only way a kennel it is resting in can disappear')
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestExitKennel', 'the best-effort server bookkeeping fire must still happen')
end)

t.test('FIXED: removeKennel -- feature off from file-load means the handler is not even registered, so there is nothing left to dispatch to', function()
    local g = newKennelFixture({ deployableKennel = false })
    t.isNil(g.netEventNames['john-k9:client:removeKennel'], 'removeKennel is not registered at all with the feature off (REGISTRATION-TIME FEATURE GATE)')
end)

t.test('FIXED: STALE-KENNEL GUARD -- a second dispatch before the first is ever removed now deletes the first kennel instead of orphaning it (was asymmetric with client/propattachment.lua\'s own attachK9Prop STALE-VEST GUARD; now mirrors it)', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    local firstEntity = f.createObjectCalls[1].entity
    t.equals(#f.deleteEntityCalls, 0, 'the first kennel is still alive and untouched after only one dispatch')

    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 10.0, 20.0, 3.0)
    local secondEntity = f.createObjectCalls[2].entity

    t.equals(#f.createObjectCalls, 2, 'a second, independent kennel object is created')
    t.equals(#f.deleteEntityCalls, 1, 'FIXED: the STALE-KENNEL GUARD deletes the first kennel before the second is even created')
    t.equals(f.deleteEntityCalls[1], firstEntity, 'the entity actually deleted by the guard is the FIRST kennel, not the second')

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 2, 'onResourceStop cleans up the second (now-current) kennel too')
    t.equals(f.deleteEntityCalls[2], secondEntity, 'the second delete call targets the SECOND kennel, confirming myKennelNetId correctly tracks the current one, not the orphaned first')
end)

-- ========================================================================
-- pickupKennelConfirmed -- NEW THIS PASS (K9-can-ride-along). NEVER
-- CreateObjects a new prop -- attaches the SAME, already-existing entity.
-- ========================================================================

t.test('pickupKennelConfirmed: happy path -- requests network control, unfreezes, attaches the SAME object to the picker\'s own hands (entity1 = the object, isPed = false)', function()
    local f = newKennelFixture()
    local netId = 600
    f.registerForeignEntity(netId, 70, GetHashKey(PRIMARY_MODEL))

    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    t.isTrue(f.env.IsCarryingKennel())
    t.isTrue(#f.controlRequestCalls >= 1 and f.controlRequestCalls[#f.controlRequestCalls] == 70, 'NETWORK OWNERSHIP -- must request control of the object before attaching it (client/combat.lua PropDragging precedent)')
    t.isTrue(#f.freezeCalls >= 1 and f.freezeCalls[#f.freezeCalls].entity == 70 and f.freezeCalls[#f.freezeCalls].toggle == false, 'must unfreeze before attaching, or the two would fight each other')
    local attach = f.lastAttachCall()
    t.equals(attach.entity1, 70, 'entity1 is the kennel OBJECT')
    t.equals(attach.entity2, MY_PED, 'entity2 is the picker\'s own ped')
    t.equals(attach.isPed, false, 'entity1 is an object, not a ped')
    t.equals(#f.createObjectCalls, 0, 'must NEVER CreateObject a second, separate prop -- the SAME real object is reused')
end)

t.test('pickupKennelConfirmed: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 601
    f.registerForeignEntity(netId, 71, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 1, netId)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.attachCalls, 0)
end)

t.test('pickupKennelConfirmed: an unresolvable netId fails closed -- never claims to be carrying anything', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, 999999)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.attachCalls, 0)
end)

t.test('pickupKennelConfirmed: a resolvable netId whose model is NOT a configured kennel prop fails closed', function()
    local f = newKennelFixture()
    local netId = 602
    f.registerForeignEntity(netId, 72, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.attachCalls, 0)
end)

-- ========================================================================
-- putDownKennelAt -- NEW THIS PASS. Mirror image of deployKennelAt applied
-- to an already-existing object -- never creates, never deletes.
-- ========================================================================

t.test('putDownKennelAt: happy path -- detaches, repositions at the server-computed spot, re-freezes, clears carry state', function()
    local f = newKennelFixture()
    local netId = 700
    f.registerForeignEntity(netId, 80, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsCarryingKennel())

    f.dispatchNetEvent('john-k9:client:putDownKennelAt', 65535, netId, 11.0, 22.0, 3.0)
    t.isFalse(f.env.IsCarryingKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == 80)
    t.isTrue(#f.setCoordsCalls >= 1)
    local lastSet = f.setCoordsCalls[#f.setCoordsCalls]
    t.equals(lastSet.handle, 80)
    t.equals(lastSet.x, 11.0)
    t.equals(lastSet.y, 22.0)
    t.equals(#f.placeCalls, 1)
    t.isTrue(f.freezeCalls[#f.freezeCalls].entity == 80 and f.freezeCalls[#f.freezeCalls].toggle == true)
    t.equals(#f.deleteEntityCalls, 0, 'never deletes the object -- an occupant could be attached to it')
    t.equals(#f.createObjectCalls, 0, 'never creates a new one either')
end)

t.test('putDownKennelAt: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 701
    f.registerForeignEntity(netId, 81, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    f.dispatchNetEvent('john-k9:client:putDownKennelAt', 1, netId, 0, 0, 0)
    t.isTrue(f.env.IsCarryingKennel(), 'a forged event must not affect real carry state')
end)

t.test('putDownKennelAt: an already-gone entity is a clean no-op -- still clears local carry state', function()
    local f = newKennelFixture()
    local netId = 702
    f.registerForeignEntity(netId, 82, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    f.setEntityMissing(82)

    f.dispatchNetEvent('john-k9:client:putDownKennelAt', 65535, netId, 1, 2, 3)
    t.isFalse(f.env.IsCarryingKennel())
    t.equals(#f.setCoordsCalls, 0)
end)

-- ========================================================================
-- enterKennelConfirmed -- NEW THIS PASS. The occupant is ALWAYS
-- PlayerPedId() -- THIS client's own real ped. Confirmed: this file has no
-- CreatePed call anywhere (grepped for it while writing this spec).
-- ========================================================================

t.test('enterKennelConfirmed: happy path -- positions this client\'s OWN ped at the kennel, disables collision, attaches it (entity1 = the ped, isPed = false to match the one existing precedent), sets restState', function()
    local f = newKennelFixture()
    local netId = 800
    f.registerForeignEntity(netId, 90, GetHashKey(PRIMARY_MODEL), { x = 50.0, y = 60.0, z = 10.0 })
    f.setHeading(90, 45.0)

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    t.isTrue(f.env.IsRestingInKennel())
    t.equals(f.setCoordsCalls[#f.setCoordsCalls].handle, MY_PED)
    t.equals(f.setCoordsCalls[#f.setCoordsCalls].x, 50.0)
    t.equals(f.setCoordsCalls[#f.setCoordsCalls].y, 60.0)
    t.equals(f.setHeadingCalls[#f.setHeadingCalls].handle, MY_PED)
    t.equals(f.setHeadingCalls[#f.setHeadingCalls].heading, 45.0)
    t.isTrue(f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == false)
    local attach = f.lastAttachCall()
    t.equals(attach.entity1, MY_PED, 'entity1 is the OCCUPANT\'S OWN ped -- never a spawned ped, never driven from another client')
    t.equals(attach.entity2, 90, 'entity2 is the kennel object')
    t.equals(#f.createObjectCalls, 0, 'no ped or prop is ever created -- the occupant is a real, already-connected player\'s own ped')
    t.equals(f.lastNotify().description, locale('kennel.enter_success'))
end)

-- ======================================================================
-- REST POSE -- owner-reported, THIS PASS: "make sure the dog actually
-- shows up in the kennel."
--
-- Two separate defects lived in enterKennelConfirmed, and the tests below
-- pin BOTH plus the exit side:
--   1. Tasks were never cleared before the attach. You always WALK to a
--      kennel, so the ped essentially always carries a live locomotion
--      task when the confirmation lands, and AttachEntityToEntity does not
--      cancel tasks -- it only re-parents the transform. The dog kept
--      playing its walk/run cycle while pinned: visibly running on the
--      spot inside the cage.
--   2. It was never posed. Even with tasks cleared, the result is a dog
--      standing bolt upright in a cage, which is not "resting in a kennel".
--
-- ORDER IS THE WHOLE POINT, so these assert real sequencing (the shared
-- callSeq counter in the fixture), not mere presence. A test that only
-- checked "ClearPedTasksImmediately was called" would pass just as happily
-- against the broken shape where the clear runs AFTER the attach and wipes
-- the pose, or after SetEntityCoords and teleports the ped mid-stride.
-- ======================================================================
t.test('REST POSE: enterKennelConfirmed clears tasks BEFORE repositioning and attaching, then poses AFTER the attach -- the exact order, not just the presence, of all four calls', function()
    local f = newKennelFixture()
    local netId = 860
    f.registerForeignEntity(netId, 140, GetHashKey(PRIMARY_MODEL), { x = 50.0, y = 60.0, z = 10.0 })

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    t.equals(#f.clearTasksCalls, 1, 'tasks cleared exactly once on the way in')
    t.equals(f.clearTasksCalls[1].ped, MY_PED, 'only ever this client\'s OWN ped -- never another player\'s')
    t.equals(#f.scenarioCalls, 1, 'posed exactly once on the way in')
    t.equals(f.scenarioCalls[1].ped, MY_PED, 'only ever this client\'s OWN ped')

    local clearSeq = f.clearTasksCalls[1].seq
    local coordsSeq = f.setCoordsCalls[#f.setCoordsCalls].seq
    local attachSeq = f.lastAttachCall().seq
    local poseSeq = f.scenarioCalls[1].seq

    t.isTrue(clearSeq < coordsSeq, 'CLEAR BEFORE REPOSITION -- a ped teleported mid-stride keeps sliding; clearing first makes it genuinely idle for the whole sequence')
    t.isTrue(clearSeq < attachSeq, 'CLEAR BEFORE ATTACH -- this is the actual bug: a live locomotion task surviving into the attach is what made the dog run on the spot inside the cage')
    t.isTrue(attachSeq < poseSeq, 'POSE AFTER ATTACH -- the attach sets the parent transform and an in-place scenario animates without moving the root, so this order lets the attachment govern WHERE and the scenario govern WHAT IT LOOKS LIKE. Reversed, the scenario\'s own entry transition fights an attach applied a frame later')
end)

t.test('REST POSE: playEnterAnim is FALSE -- deliberately unlike every other TaskStartScenarioInPlace call in this resource, because this ped is already pinned inside a cage and an enter transition would render as sliding against an attachment that will not let it move', function()
    local f = newKennelFixture()
    local netId = 861
    f.registerForeignEntity(netId, 141, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    t.equals(f.scenarioCalls[1].unkDelay, 0)
    t.equals(f.scenarioCalls[1].playEnterAnim, false)
end)

t.test('REST POSE: the scenario name is resolved PER BREED from the occupant\'s own live ped model, and an unmapped/future model falls back to the shepherd sit rather than passing nil to the native', function()
    -- Chop shares the Rottweiler sit (no Chop-specific scenario exists) --
    -- the table is a verbatim copy of client/movement.lua's own
    -- native-api-assistant-verified K9_SIT_SCENARIO_BY_MODEL_HASH, so this
    -- pins the copy against silent divergence from its source.
    local f = newKennelFixture()
    f.registerForeignEntity(9999, MY_PED, GetHashKey('a_c_chop'))
    local netId = 862
    f.registerForeignEntity(netId, 142, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.equals(f.scenarioCalls[1].scenarioName, 'WORLD_DOG_SITTING_ROTTWEILER')

    local g = newKennelFixture()
    g.registerForeignEntity(9998, MY_PED, GetHashKey('a_c_husky'))
    g.registerForeignEntity(863, 143, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    g.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 863)
    t.equals(g.scenarioCalls[1].scenarioName, 'WORLD_DOG_SITTING_RETRIEVER')

    -- Never registered a model at all -- GetEntityModel returns nil, the
    -- shape a future Config.Peds entry nobody mapped would also produce.
    local h = newKennelFixture()
    h.registerForeignEntity(864, 144, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    h.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 864)
    t.equals(h.scenarioCalls[1].scenarioName, 'WORLD_DOG_SITTING_SHEPHERD', 'the default, never nil -- a nil scenario name is a silent no-op that would leave the dog standing')
end)

t.test('REST POSE: NOT GATED -- the pose still plays for an occupant the server already authorized even when CanShowK9UI() would now deny (the one-layer-up trap: a cosmetic pose must never carry an authorization check K9Sit() would have imposed)', function()
    local f = newKennelFixture()
    local netId = 865
    f.registerForeignEntity(netId, 145, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    f.setCanShowK9UI(false) -- decertified in the round-trip window, after the server already granted

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    t.isTrue(f.env.IsRestingInKennel(), 'the server already granted this occupancy claim before the event was sent -- the client must not second-guess it')
    t.equals(#f.scenarioCalls, 1, 'posed anyway; a false refusal here would leave a silently un-posed dog plus a spurious access-denied toast right after the success notice')
    t.equals(#f.clearTasksCalls, 1)
end)

t.test('CONTROL: a REFUSED entry never clears tasks and never poses -- proves the two new calls sit inside the granted path, not before its guards (a fixture that always posed would pass every positive assertion above while proving nothing)', function()
    -- Forged local trigger: rejected by the SOURCE-ORIGIN GUARD, the very
    -- first line of the handler.
    local f = newKennelFixture()
    f.registerForeignEntity(866, 146, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 1, 866)
    t.equals(#f.clearTasksCalls, 0, 'a forged trigger must not touch this client\'s own ped at all')
    t.equals(#f.scenarioCalls, 0)

    -- Mid-round-trip vehicle guard: refuses AFTER the server already
    -- granted, releases the claim, and must leave the ped completely alone.
    local g = newKennelFixture()
    g.registerForeignEntity(867, 147, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    g.setInK9Vehicle(true) -- true by the time the confirmation lands, exactly the MID-ROUND-TRIP shape
    g.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 867)
    t.equals(#g.attachCalls, 0)
    t.equals(#g.clearTasksCalls, 0, 'a ped the vehicle already owns via a real seat must not have its tasks wiped by the kennel')
    t.equals(#g.scenarioCalls, 0)

    -- Unresolvable netId: fails closed before anything is touched.
    local h = newKennelFixture()
    h.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 999999)
    t.equals(#h.clearTasksCalls, 0)
    t.equals(#h.scenarioCalls, 0)
end)

t.test('REST POSE: EVERY exit path ends the pose -- the manual exit, and the automatic backstops where there is no player input coming to end a scenario on its own', function()
    -- Manual exit.
    local f = newKennelFixture()
    f.registerForeignEntity(868, 148, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 868)
    t.equals(#f.clearTasksCalls, 1)
    f.env.ExitKennelRest()
    t.equals(#f.clearTasksCalls, 2, 'the exit clears again -- without this the sit scenario keeps running and "Exit Kennel" looks like it did nothing')
    t.isTrue(f.clearTasksCalls[2].seq > f.detachCalls[#f.detachCalls].seq, 'cleared after the detach, so nothing re-poses a ped that is already free')
    t.isFalse(f.env.IsRestingInKennel())

    -- RESOURCE STOP. Regression test for a real miss: this handler used to
    -- carry its OWN hand-duplicated copy of the detach/collision natives,
    -- and the rest-pose fix landed in ReleaseKennelRest only -- so a K9
    -- resting when an operator restarted the resource was left frozen in
    -- the sitting scenario until they pressed a movement key, in exactly
    -- the case that fix's own commit message claimed to have covered. Both
    -- paths now go through the single ReleaseOccupantNatives().
    local r = newKennelFixture()
    r.registerForeignEntity(870, 150, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    r.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 870)
    t.equals(#r.clearTasksCalls, 1)
    r.fireResourceStop(RESOURCE_NAME)
    t.isFalse(r.env.IsRestingInKennel())
    t.equals(#r.clearTasksCalls, 2, 'resource stop ends the pose too -- the whole point of routing it through the one shared release')
    t.isTrue(r.clearTasksCalls[2].seq > r.detachCalls[#r.detachCalls].seq, 'cleared after the detach, same order as every other exit path')

    -- Automatic backstop: the kennel is removed out from under the
    -- occupant. THIS is the case that most needed it -- no player input is
    -- coming to end the scenario by itself.
    local g = newKennelFixture()
    g.registerForeignEntity(869, 149, GetHashKey(PRIMARY_MODEL), { x = 1.0, y = 2.0, z = 3.0 })
    g.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 869)
    t.equals(#g.clearTasksCalls, 1)
    g.dispatchNetEvent('john-k9:client:removeKennel', 65535, 869)
    t.isFalse(g.env.IsRestingInKennel())
    t.equals(#g.clearTasksCalls, 2, 'the removal backstop ends the pose too')
end)

t.test('FORCED RELEASE: forceExitKennelRest detaches this client\'s ped, restores collision, and says WHY -- the client half of a server-side access revoke', function()
    local f = newKennelFixture()
    local netId = 800
    f.registerForeignEntity(netId, 90, GetHashKey(PRIMARY_MODEL), { x = 50.0, y = 60.0, z = 10.0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel(), 'sanity: resting before the revoke')

    f.dispatchNetEvent('john-k9:client:forceExitKennelRest', 65535, 'cert_revoked')

    t.isFalse(f.env.IsRestingInKennel(), 'the player must actually be let out, not merely forgotten by the server')
    t.isTrue(f.detachCalls[#f.detachCalls] ~= nil, 'the ped is physically detached from the kennel prop')
    local lastCollision = f.collisionCalls[#f.collisionCalls]
    t.isTrue(lastCollision.handle == MY_PED and lastCollision.toggle == true,
        'collision restored -- leaving it off would be its own trap')
    t.equals(f.lastNotify().description, locale('kennel.exit_access_revoked'),
        'and the player is told why they were moved, rather than being silently teleported out')
end)

t.test('FORCED RELEASE: a FORGED local trigger is rejected -- the source-origin guard holds on this handler too', function()
    -- This handler shipped without the guard every other server->client
    -- handler in this file carries. The effect of a forged trigger is
    -- self-only and harmless (you can already leave voluntarily), which is
    -- exactly why it was easy to miss -- and exactly why the convention is
    -- "every event, no per-event judgement calls": the next payload added
    -- to this event would otherwise arrive forgeable.
    local f = newKennelFixture()
    local netId = 800
    f.registerForeignEntity(netId, 90, GetHashKey(PRIMARY_MODEL), { x = 50.0, y = 60.0, z = 10.0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel(), 'sanity: resting via a legitimate server event')

    f.dispatchNetEvent('john-k9:client:forceExitKennelRest', 1, 'cert_revoked')

    t.isTrue(f.env.IsRestingInKennel(), 'a locally-forged trigger (source ~= 65535) must be ignored outright')
end)

t.test('FORCED RELEASE: forceExitKennelRest is a safe no-op when this client is not resting at all', function()
    local f = newKennelFixture()
    local before = #f.notifyCalls

    f.dispatchNetEvent('john-k9:client:forceExitKennelRest', 65535, 'cert_revoked')

    t.equals(#f.notifyCalls, before, 'a duplicate or late event must not tell someone standing in the street they have been let out of a kennel')
end)

t.test('FORCED RELEASE: forceExitKennelRest still works with the feature toggled off mid-session -- the release must outlive the feature', function()
    -- GATE THE START OF A THING, NEVER THE STOP. The handler is registered
    -- outside this file's feature gate on purpose; an operator switching
    -- DeployableKennel off must not be able to strand someone inside one.
    local f = newKennelFixture()
    local netId = 800
    f.registerForeignEntity(netId, 90, GetHashKey(PRIMARY_MODEL), { x = 50.0, y = 60.0, z = 10.0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.env.Config.Features.DeployableKennel = false

    f.dispatchNetEvent('john-k9:client:forceExitKennelRest', 65535, 'cert_revoked')

    t.isFalse(f.env.IsRestingInKennel())
    t.equals(f.lastNotify().description, locale('kennel.exit_access_revoked'))
end)

t.test('enterKennelConfirmed: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 801
    f.registerForeignEntity(netId, 91, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 1, netId)
    t.isFalse(f.env.IsRestingInKennel())
end)

t.test('enterKennelConfirmed: an unresolvable/wrong-model netId fails closed', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, 999999)
    t.isFalse(f.env.IsRestingInKennel())

    local netId = 802
    f.registerForeignEntity(netId, 92, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isFalse(f.env.IsRestingInKennel())
end)

-- ========================================================================
-- "Exit Kennel" -- the occupant's own, ALWAYS-AVAILABLE local release. See
-- server/kennel.lua's header CRITICAL SAFETY section -- this must work
-- with ZERO server involvement.
-- ========================================================================

t.test('SAFETY: the "Exit Kennel" ox_target option releases unconditionally -- detaches, restores collision, and fires the best-effort server bookkeeping event', function()
    local f = newKennelFixture()
    local netId = 900
    f.registerForeignEntity(netId, 100, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:exitKennel' then exitOption = option end
    end
    t.isNotNil(exitOption, 'an "Exit Kennel" option must be registered')
    t.isTrue(exitOption.canInteract(100, 1.0, {}, 'anything'))

    exitOption.onSelect()
    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestExitKennel')
end)

t.test('SAFETY: the "Exit Kennel" ox_target option calls the SAME ExitKennelRest() global the new k9exitkennel keybind (client/keybinds.lua) and "Exit Kennel" radial item (client/radial.lua) now also call -- never a second, forked release', function()
    local f = newKennelFixture()
    local netId = 951
    f.registerForeignEntity(netId, 151, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:exitKennel' then exitOption = option end
    end

    local exitKennelRestCalls = 0
    local realExitKennelRest = f.env.ExitKennelRest
    f.env.ExitKennelRest = function(...)
        exitKennelRestCalls = exitKennelRestCalls + 1
        return realExitKennelRest(...)
    end

    exitOption.onSelect()
    t.equals(exitKennelRestCalls, 1, 'onSelect must call through the shared ExitKennelRest() global, not a private copy of ReleaseKennelRest')
    t.isFalse(f.env.IsRestingInKennel())
end)

-- ========================================================================
-- ExitKennelRest() -- trap-hunt fix, THIS PASS. The occupant's own
-- ALWAYS-AVAILABLE exit entry point, exposed globally so client/keybinds.lua's
-- new k9exitkennel command/keybind and client/radial.lua's new "Exit
-- Kennel" item can reach it directly, instead of only through ox_target on
-- the kennel prop itself. See client/kennel.lua's own doc comment on this
-- global, and its corrected WANDER-OFF EXIT comment above for the finding
-- this whole addition responds to.
-- ========================================================================

t.test('ExitKennelRest(): defined with the feature ON, and releases exactly like the ox_target option -- detaches, restores collision, fires the best-effort server bookkeeping event', function()
    local f = newKennelFixture()
    local netId = 952
    f.registerForeignEntity(netId, 152, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.env.ExitKennelRest()

    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestExitKennel')
end)

t.test('FIXED: ExitKennelRest() stays defined and reachable-but-inert with the feature OFF at file-load -- mirrors IsRestingInKennel()/IsCarryingKennel()/RequestDeployKennel() above, for client/keybinds.lua/client/radial.lua\'s own call sites', function()
    local f = newKennelFixture({ deployableKennel = false })
    t.isNotNil(f.env.ExitKennelRest)
    f.env.ExitKennelRest() -- must not error even though restState can never be non-nil with the feature off from load
    t.equals(#f.serverEvents, 0, 'a genuine no-op -- ReleaseKennelRest\'s own `if not restState then return end` guard short-circuits before ever touching the network')
end)

t.test('ExitKennelRest(): calling it while not resting is a genuine, harmless no-op -- no detach, no collision change, no server event', function()
    local f = newKennelFixture()
    f.env.ExitKennelRest()
    t.equals(#f.detachCalls, 0)
    t.equals(#f.collisionCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('REQUIRED (trap-hunt brief): ExitKennelRest() releases the occupant even when Config.Features.DeployableKennel has been toggled OFF mid-session, AFTER the occupant already entered while it was on', function()
    local f = newKennelFixture()
    local netId = 953
    f.registerForeignEntity(netId, 153, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    -- Simulates a live config push flipping the flag off while this client
    -- is already resting -- this file's own REGISTRATION-TIME FEATURE GATE
    -- was evaluated once at load time and does not re-run, so every
    -- net-event handler/ox_target option/watchdog thread registered while
    -- the flag was still true stays registered regardless -- but this
    -- proves ExitKennelRest() ITSELF never re-reads the flag on the way
    -- out either.
    f.env.Config.Features.DeployableKennel = false

    f.env.ExitKennelRest()
    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
end)

t.test('REQUIRED (trap-hunt brief): ExitKennelRest() releases the occupant even when CanShowK9UI()/HasK9Access() would now both deny access ("no longer certified") -- neither is even consulted', function()
    local f = newKennelFixture()
    local netId = 954
    f.registerForeignEntity(netId, 154, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.setCanShowK9UI(false)
    f.setHasK9Access(false)
    local canShowK9UICallsBefore = f.canShowK9UICallCount()
    local hasK9AccessCallsBefore = f.hasK9AccessCallCount()

    f.env.ExitKennelRest()

    t.isFalse(f.env.IsRestingInKennel(), 'an exit path must never be deniable by a certification/access check')
    t.equals(f.canShowK9UICallCount(), canShowK9UICallsBefore, 'CanShowK9UI() must never even be consulted on the way out')
    t.equals(f.hasK9AccessCallCount(), hasK9AccessCallsBefore, 'HasK9Access() must never even be consulted on the way out')
    t.equals(f.denyCallCount(), 0, 'DenyK9UIAccess() must never fire for an exit path')
end)

t.test('ANY PED: the "Rest in Kennel" option\'s canInteract relies on CanShowK9UI() alone -- setting IsOwnModelK9 has NO effect either way, proving production code never consults it', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:enterKennel' then enterOption = option end
    end
    f.setIsOwnModelK9(false) -- would matter if production code consulted it -- it must not
    t.isTrue(enterOption.canInteract(1, 1.0, {}, 'anything'), 'CanShowK9UI() alone decides this -- a role-holder on a non-dog body (IsOwnModelK9() == false) must still see the option')
end)

t.test('"Rest in Kennel"/"Exit Kennel" options: name, icon, and gating -- fa-dog + CanShowK9UI() convention (coder-frontend input this pass)', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local options = f.addModelCalls[#f.addModelCalls].options
    local enterOption, exitOption
    for _, option in ipairs(options) do
        if option.name == 'john-k9:enterKennel' then enterOption = option end
        if option.name == 'john-k9:exitKennel' then exitOption = option end
    end
    t.equals(enterOption.icon, 'fas fa-dog')
    t.equals(exitOption.icon, 'fas fa-dog')
    t.isTrue(enterOption.canInteract(1, 1.0, {}, 'anything'))

    f.setCanShowK9UI(false)
    t.isFalse(enterOption.canInteract(1, 1.0, {}, 'anything'), 'Rest in Kennel is gated on CanShowK9UI(), same convention as every self-administered K9 action')
end)

t.test('"Rest in Kennel": canInteract also hides while already resting or carrying (display-only convenience, matches server-side rejection)', function()
    local f = newKennelFixture()
    local netId = 901
    f.registerForeignEntity(netId, 101, GetHashKey(PRIMARY_MODEL))
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:enterKennel' then enterOption = option end
    end
    t.isTrue(enterOption.canInteract(101, 1.0, {}, 'anything'))

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isFalse(enterOption.canInteract(101, 1.0, {}, 'anything'), 'already resting -- must not offer to enter again')
end)

-- ========================================================================
-- KENNEL-VS-VEHICLE MUTUAL GUARD (this pass) -- IsInK9Vehicle()
-- (client/vehicle.lua). QA found no guard existed in EITHER direction
-- between resting in a kennel and being seated in a K9 vehicle. This half
-- closes "seated in a vehicle, then selects Rest in Kennel" -- both a
-- pre-flight refusal (onSelect, before requestEnterKennel is ever sent --
-- server/kennel.lua's own requestEnterKennel handler writes
-- KennelOccupants[citizenid] BEFORE this client ever attaches anything, and
-- that occupancy has NO timeout at all short of a disconnect, so it must
-- never be requested while already in a vehicle in the first place) and a
-- defensive re-check inside enterKennelConfirmed itself (the round trip's
-- own window: the player could select "Enter Vehicle" -- a SEPARATE,
-- ALSO server-arbitrated action -- in the gap between onSelect and this
-- confirmation arriving). See client/vehicle.lua's own symmetric
-- IsRestingInKennel() guard (tests/clientvehicle_spec.lua) for the other,
-- reverse direction.
-- ========================================================================

t.test('"Rest in Kennel": canInteract hides while seated in a K9 vehicle', function()
    local f = newKennelFixture()
    local netId = 960
    f.registerForeignEntity(netId, 160, GetHashKey(PRIMARY_MODEL))
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:enterKennel' then enterOption = option end
    end
    t.isTrue(enterOption.canInteract(160, 1.0, {}, 'anything'))

    f.setInK9Vehicle(true)
    t.isFalse(enterOption.canInteract(160, 1.0, {}, 'anything'), 'seated in a vehicle -- must not offer to also start resting in a kennel')
end)

t.test('"Rest in Kennel": onSelect refuses BEFORE requestEnterKennel is ever sent while seated in a K9 vehicle -- a claim taken and then abandoned has NO timeout at all', function()
    local f = newKennelFixture()
    local netId = 961
    f.registerForeignEntity(netId, 161, GetHashKey(PRIMARY_MODEL))
    f.setInK9Vehicle(true)
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:enterKennel' then enterOption = option end
    end

    enterOption.onSelect({ entity = 161 })

    t.equals(#f.serverEvents, 0, 'must refuse locally before ever contacting the server')
    t.isFalse(f.env.IsRestingInKennel())
    t.equals(f.lastNotify().description, locale('combat.blocked_by_vehicle'))
end)

t.test('enterKennelConfirmed: MID-ROUND-TRIP re-check -- the client entered a K9 vehicle AFTER onSelect but before this confirmation arrived -- refuses locally, does NOT attach, and releases the server-side occupancy claim it was just granted', function()
    local f = newKennelFixture()
    local netId = 962
    f.registerForeignEntity(netId, 162, GetHashKey(PRIMARY_MODEL))
    f.setInK9Vehicle(true) -- started mid-round-trip, i.e. true by the time the confirmation lands

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    t.isFalse(f.env.IsRestingInKennel(), 'must never attach a ped that is now seated in a vehicle')
    t.equals(#f.attachCalls, 0, 'must never AttachEntityToEntity a ped the vehicle already owns via a real seat')
    t.equals(f.lastNotify().description, locale('combat.blocked_by_vehicle'))
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestExitKennel', 'ReleaseKennelRest() would no-op here (restState was never set) -- the release must be sent directly, or server/kennel.lua\'s KennelOccupants entry (written BEFORE this event was even sent) leaks forever')
end)

t.test('KENNEL-VS-VEHICLE soft dependency: with client/vehicle.lua not loaded at all (no IsInK9Vehicle global), Rest in Kennel works exactly as before this pass', function()
    local f = newKennelFixture({ inK9VehicleAvailable = false })
    t.isNil(f.env.IsInK9Vehicle)
    local netId = 963
    f.registerForeignEntity(netId, 163, GetHashKey(PRIMARY_MODEL))
    f.fireResourceStart(RESOURCE_NAME)
    local enterOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:enterKennel' then enterOption = option end
    end
    t.isTrue(enterOption.canInteract(163, 1.0, {}, 'anything'), 'an absent optional global must be a skipped check, never an error')

    enterOption.onSelect({ entity = 163 })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestEnterKennel')

    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())
end)

t.test('"Exit Kennel": canInteract only true for the SPECIFIC entity this client is actually resting in', function()
    local f = newKennelFixture()
    local netId = 902
    f.registerForeignEntity(netId, 102, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:exitKennel' then exitOption = option end
    end
    t.isTrue(exitOption.canInteract(102, 1.0, {}, 'anything'))
    t.isFalse(exitOption.canInteract(999, 1.0, {}, 'anything'), 'a DIFFERENT entity must never offer "Exit Kennel" for a kennel this client is not actually inside')
end)

-- ========================================================================
-- "Pick Up Kennel" -- REWORKED THIS PASS (coder-frontend input): fa-user-tie
-- + HasK9Access() alone, deliberately NOT CanShowK9UI()/IsOwnModelK9() --
-- a human handler carrying a box does not require currently being a dog.
-- ========================================================================

t.test('"Pick Up Kennel": icon is fa-user-tie, and canInteract relies on HasK9Access() alone -- NOT CanShowK9UI()/IsOwnModelK9()', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    t.equals(#f.addModelCalls, 1, 'all five options register via ONE AddModel call')
    local options = f.addModelCalls[1].options
    t.equals(#options, 5, 'Pick Up, Rest In, Exit, Close, and Open Kennel -- see the CLOSEABLE KENNEL ox_target tests below for the two added this pass')
    local pickupOption
    for _, option in ipairs(options) do
        if option.name == 'john-k9:pickupKennel' then pickupOption = option end
    end
    t.equals(pickupOption.icon, 'fas fa-user-tie')

    -- Not a K9, not able to "show K9 UI" at all -- must still see the option.
    f.setCanShowK9UI(false)
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    t.isTrue(pickupOption.canInteract(1, 1.0, {}, 'anything'), 'a human handler must be able to pick up a kennel without being a dog')

    f.setHasK9Access(false)
    t.isFalse(pickupOption.canInteract(1, 1.0, {}, 'anything'))
end)

t.test('"Pick Up Kennel": canInteract hides while THIS client is already carrying something', function()
    local f = newKennelFixture()
    local netId = 903
    f.registerForeignEntity(netId, 103, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    f.fireResourceStart(RESOURCE_NAME)
    local pickupOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:pickupKennel' then pickupOption = option end
    end
    t.isFalse(pickupOption.canInteract(103, 1.0, {}, 'anything'))
end)

t.test('"Pick Up Kennel": onSelect sends the real requestPickupKennel event with the hovered entity\'s netId', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local pickupOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:pickupKennel' then pickupOption = option end
    end
    local netId = 904
    f.registerForeignEntity(netId, 104, GetHashKey(PRIMARY_MODEL))
    pickupOption.onSelect({ entity = 104 })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestPickupKennel')
    t.equals(f.lastServerEvent().args[1], netId)
end)

-- ========================================================================
-- RequestDeployKennel: carry-aware branch -- THIS PASS. One entry point
-- serves BOTH "deploy a new kennel" and "put down the one I'm carrying,"
-- decided by which state this client is actually in. Checked BEFORE even
-- the feature-flag/CanShowK9UI() gates, mirroring
-- client/vehicle.lua's own ExitK9Vehicle() "never gate an exit-adjacent
-- action" precedent.
-- ========================================================================

t.test('RequestDeployKennel: while carrying, sends requestPutDownKennel instead of requestDeployKennel', function()
    local f = newKennelFixture()
    local netId = 905
    f.registerForeignEntity(netId, 105, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    f.env.RequestDeployKennel()
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestPutDownKennel')
end)

t.test('RequestDeployKennel: the put-down branch is NEVER gated behind CanShowK9UI()/the feature flag -- mirrors ExitK9Vehicle()', function()
    local f = newKennelFixture()
    local netId = 906
    f.registerForeignEntity(netId, 106, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    f.setCanShowK9UI(false)
    f.env.RequestDeployKennel()
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestPutDownKennel', 'a handler whose certification lapses mid-carry must still be able to set the kennel back down')
    t.equals(f.denyCallCount(), 0)
end)

-- ========================================================================
-- kennelCarrierLost -- NEW THIS PASS (carrier-disconnect safety net,
-- server/kennel.lua's playerDropped handler, event 12).
-- ========================================================================

t.test('kennelCarrierLost: settles the object (detach + freeze) and clears local carry state if it was mine', function()
    local f = newKennelFixture()
    local netId = 1000
    f.registerForeignEntity(netId, 200, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    f.dispatchNetEvent('john-k9:client:kennelCarrierLost', 65535, netId)
    t.isFalse(f.env.IsCarryingKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == 200)
    t.isTrue(f.freezeCalls[#f.freezeCalls].entity == 200 and f.freezeCalls[#f.freezeCalls].toggle == true)
end)

t.test('kennelCarrierLost: source guard rejects a forged local trigger', function()
    local f = newKennelFixture()
    local netId = 1001
    f.registerForeignEntity(netId, 201, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    f.dispatchNetEvent('john-k9:client:kennelCarrierLost', 1, netId)
    t.isTrue(f.env.IsCarryingKennel())
end)

t.test('kennelCarrierLost: never touches an occupant\'s own restState -- a K9 riding inside is unaffected by who was carrying it', function()
    local f = newKennelFixture()
    local netId = 1002
    f.registerForeignEntity(netId, 202, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId) -- THIS same client is (for test purposes) the occupant

    f.dispatchNetEvent('john-k9:client:kennelCarrierLost', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel(), 'restState must be completely untouched by a carrier-lost broadcast for the SAME netId')
end)

-- ========================================================================
-- SHARED WATCHDOG THREAD -- own-death / wander-off / entity-lost / carry
-- re-assertion. See this file's header for the capture-and-step
-- convention.
-- ========================================================================

t.test('WATCHDOG: own-death while resting releases the occupant (detach + restore collision)', function()
    local f = newKennelFixture()
    local netId = 1100
    f.registerForeignEntity(netId, 300, GetHashKey(PRIMARY_MODEL), { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.setPedDead(MY_PED, true)
    f.stepWatchdogOnce()

    t.isFalse(f.env.IsRestingInKennel())
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
end)

t.test('WATCHDOG: distance-check backstop -- CORRECTED framing (trap-hunt finding, this pass): this does NOT prove "walking away is an escape hatch." An earlier version of this test\'s own name/assertion message claimed exactly that, and it was FALSE -- see client/kennel.lua\'s own corrected WANDER-OFF EXIT comment for the full writeup (AttachEntityToEntity re-clamps the occupant\'s position to the kennel\'s bone every tick; only DetachEntity ends that, never ordinary movement input). This test instead pins the NARROW, REAL case this branch actually catches: this fixture\'s own GetEntityCoords/SetEntityCoords stub directly overwrites coordinates (unlike a real attached ped, which the engine would keep re-clamping) -- standing in for the rare native-level desync where the attachment silently ends while restState has not been told yet. If that ever happens, the occupant really is free-standing, and this branch still correctly converts it into a clean, tracked exit rather than a stale KennelOccupants entry.', function()
    local f = newKennelFixture()
    local netId = 1101
    f.registerForeignEntity(netId, 301, GetHashKey(PRIMARY_MODEL), { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.setCoords(MY_PED, 100.0, 100.0, 0.0) -- simulates a desynced/already-detached ped, far beyond interactDistanceMeters (2.5) -- NOT a claim that ordinary movement can reach this state while genuinely attached
    f.stepWatchdogOnce()

    t.isFalse(f.env.IsRestingInKennel(), 'a free-standing occupant (however that came about) must still be converted into a clean exit')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestExitKennel')
end)

t.test('REQUIRED (trap-hunt brief): WATCHDOG -- the kennel entity becoming unresolvable releases the occupant after the debounced miss-streak, not on the first miss (this IS the genuine, always-running automatic safety valve for "the kennel prop is destroyed while occupied" -- it never depends on a thread that only starts under some condition: this thread starts whenever the feature was on at file-load, the same condition that is the only way restState could ever become non-nil in the first place)', function()
    local f = newKennelFixture()
    local netId = 1102
    f.registerForeignEntity(netId, 302, GetHashKey(PRIMARY_MODEL), { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)

    f.setEntityMissing(302)
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsRestingInKennel(), 'a single miss must not be trusted -- could be a momentary streaming hiccup')
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsRestingInKennel())
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsRestingInKennel(), 'three consecutive misses must release the occupant')
end)

t.test('WATCHDOG: idles (no rest, no carry) without touching any native at all', function()
    local f = newKennelFixture()
    f.stepWatchdogOnce()
    t.equals(#f.detachCalls, 0)
    t.equals(#f.attachCalls, 0)
    t.equals(#f.controlRequestCalls, 0)
end)

t.test('WATCHDOG: while carrying, periodically re-requests network control and re-asserts the attach (defensive re-assertion for the one relationship that crosses an ownership boundary)', function()
    local f = newKennelFixture()
    local netId = 1103
    f.registerForeignEntity(netId, 303, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)
    local controlCallsBefore = #f.controlRequestCalls
    local attachCallsBefore = #f.attachCalls

    f.stepWatchdogOnce()

    t.isTrue(#f.controlRequestCalls > controlCallsBefore)
    t.isTrue(#f.attachCalls > attachCallsBefore)
    t.isTrue(f.env.IsCarryingKennel())
end)

t.test('WATCHDOG: own-death while carrying notifies and requests a put-down through the ordinary server flow (never deletes/detaches unilaterally)', function()
    local f = newKennelFixture()
    local netId = 1104
    f.registerForeignEntity(netId, 304, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    f.setPedDead(MY_PED, true)
    f.stepWatchdogOnce()

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestPutDownKennel')
    t.equals(f.lastNotify().description, locale('kennel.exit_own_downed'))
end)

t.test('WATCHDOG: the carried object becoming unresolvable clears local carry state after the debounced miss-streak', function()
    local f = newKennelFixture()
    local netId = 1105
    f.registerForeignEntity(netId, 305, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, netId)

    f.setEntityMissing(305)
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsCarryingKennel())
    f.stepWatchdogOnce()
    t.isTrue(f.env.IsCarryingKennel())
    f.stepWatchdogOnce()
    t.isFalse(f.env.IsCarryingKennel())
end)

-- ========================================================================
-- DOUBLE-FIRE / RE-ENTRANCY
-- ========================================================================

t.test('RequestDeployKennel: two rapid calls BEFORE the first server confirmation ever arrives both reach the server (no client-side in-flight guard) -- safe only because server/kennel.lua independently re-enforces the one-kennel-per-citizenid limit, per this file\'s own comment', function()
    local f = newKennelFixture()
    f.env.RequestDeployKennel()
    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 2, 'myKennelNetId is only set once deployKennelAt actually succeeds, so a pre-confirmation double-press is not blocked client-side')
end)

t.test('RequestDeployKennel: a call AFTER a real kennel is already confirmed is correctly blocked locally, no server contact', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 2.0, 3.0)
    t.equals(#f.serverEvents, 1)

    f.env.RequestDeployKennel()
    t.equals(#f.serverEvents, 1, 'once myKennelNetId is set, a second RequestDeployKennel must not reach the server')
    t.equals(f.lastNotify().description, locale('kennel.already_deployed'))
end)

-- ========================================================================
-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md #5, ADDITIVE) -- the
-- new 'k9kennel' entry point + RequestKennelContextual(). k9deploykennel
-- above is UNCHANGED (proven by every test above it) -- these tests are
-- about the NEW additive layer specifically.
-- ========================================================================

--- @param f table -- newKennelFixture() result
--- @return fun(...) k9kennel handler
local function findK9Kennel(f)
    for _, c in ipairs(f.commands) do
        if c.name == 'k9kennel' then return c.handler end
    end
    error('k9kennel command not registered')
end

t.test('CONTEXTUAL DISPATCH: bare /k9kennel DEPLOYS when nothing is active (no rest, no carry, nothing deployed)', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDeployKennel')
    t.equals(f.notifyCalls[1].description, locale('kennel.contextual_deploying'))
end)

t.test('CONTEXTUAL DISPATCH: bare /k9kennel ENTERS this client\'s own deployed kennel when close enough', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    -- The fixture's own CreateObject stub does not track per-entity coords
    -- (see its own header) -- the deployed kennel object therefore reads
    -- back at the same default (0,0,0) GetEntityCoords falls back to for
    -- any untracked handle, exactly where MY_PED itself starts. This is
    -- "close enough" by construction; the deploy args below are the real
    -- production call shape, not load-bearing for the distance itself.
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestEnterKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
    -- RequestEnterOwnKennel() itself notifies nothing extra on the success
    -- path (the server's own confirmation is what tells the player they're
    -- resting) -- the ONE notify this whole bare dispatch produces is the
    -- "here's what I decided" confirmation.
    t.equals(f.lastNotify().description, locale('kennel.contextual_entering'))
end)

t.test('CONTEXTUAL DISPATCH: bare /k9kennel refuses to enter (never guesses a second deploy) when this client\'s own kennel is too far away', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 0.0, 0.0)
    -- Move THIS CLIENT far away instead (the deployed object's own tracked
    -- coords always read back as the untracked-handle default -- see the
    -- "ENTERS" test's own comment) -- this is what actually varies the
    -- computed distance in this fixture.
    f.setCoords(MY_PED, 100.0, 0.0, 0.0)
    local eventsBefore = #f.serverEvents

    k9kennel(nil, {})

    t.equals(#f.serverEvents, eventsBefore, 'too far to enter must never fall through to deploying a second kennel')
    t.equals(f.lastNotify().description, locale('kennel.enter_too_far'))
end)

t.test('CONTEXTUAL DISPATCH: bare /k9kennel PUTS DOWN when this client is currently carrying a kennel', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 1.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, kennelNetId)
    t.isTrue(f.env.IsCarryingKennel())

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestPutDownKennel')
    t.equals(f.lastNotify().description, locale('kennel.contextual_putting_down'))
end)

t.test('LEAVING: bare /k9kennel while resting only says where the exit is; the K9 menu\'s Kennel button (same RequestKennelContextual) gets you out', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    local netId = 900
    f.registerForeignEntity(netId, 55, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    k9kennel(nil, {})

    t.isTrue(f.env.IsRestingInKennel(), 'the command never gets you out -- only the third eye and the K9 menu do')
    t.equals(f.lastNotify().description, locale('kennel.exit_use_third_eye'))

    f.env.RequestKennelContextual()
    t.isFalse(f.env.IsRestingInKennel(), 'the K9 menu\'s Kennel button (RequestKennelContextual) does get you out')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestExitKennel')
end)

t.test('EXPLICIT OVERRIDE: /k9kennel deploy|enter force that exact action; there is no exit word any more', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    k9kennel(nil, { 'deploy' })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDeployKennel')

    -- fake a deploy confirm so myKennelNetId is set for the 'enter' override
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]

    k9kennel(nil, { 'enter' })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestEnterKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)

    local netId = 901
    f.registerForeignEntity(netId, 56, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    k9kennel(nil, { 'exit' })
    t.isTrue(f.env.IsRestingInKennel(), '/k9kennel exit no longer exists -- leaving is the third eye or the K9 menu')
end)

-- ========================================================================
-- CLOSEABLE KENNEL (owner-directed, docs/history/COMMAND_CONSOLIDATION_SPEC.md #5
-- extension, this pass). See server/kennel.lua's own "CLOSEABLE KENNEL"
-- header section for the full design writeup.
-- ========================================================================

t.test('CONTEXTUAL DISPATCH: bare /k9kennel CLOSES the door when the server reports the kennel is open and occupied', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    f.queueDoorStateResponse({ ok = true, closed = false, occupied = true })

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestCloseKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
    t.equals(f.lastNotify().description, locale('kennel.contextual_closing'))
end)

t.test('CONTEXTUAL DISPATCH: bare /k9kennel OPENS the door when the server reports the kennel is closed (regardless of occupancy)', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    f.queueDoorStateResponse({ ok = true, closed = true, occupied = false })

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestOpenKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
    t.equals(f.lastNotify().description, locale('kennel.contextual_opening'))
end)

t.test('CONTEXTUAL DISPATCH: bare /k9kennel ENTERS when the server reports open and unoccupied (the ordinary case, unchanged)', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    f.queueDoorStateResponse({ ok = true, closed = false, occupied = false })

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestEnterKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
end)

t.test('CONTEXTUAL DISPATCH: bare /k9kennel falls back to a plain ENTER attempt if the door-state callback is unavailable/throws -- never leaves the player with no response at all', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    f.queueDoorStateResponse(nil) -- simulate a rejected/timed-out lib.callback.await

    k9kennel(nil, {})

    t.equals(f.lastServerEvent().event, 'john-k9:server:requestEnterKennel', 'a missing/failed door-state answer must never leave the dispatcher doing nothing at all')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
end)

t.test('EXPLICIT OVERRIDE: /k9kennel close|open force that exact action, reachable by the OWNER standing outside', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]

    k9kennel(nil, { 'close' })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestCloseKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)

    k9kennel(nil, { 'open' })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestOpenKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
end)

t.test('EXPLICIT OVERRIDE: /k9kennel close|open are ALSO reachable by the OCCUPANT resting inside (not just the owner outside)', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    local netId = 950
    f.registerForeignEntity(netId, 60, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    k9kennel(nil, { 'close' })
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestCloseKennel')
    t.equals(f.lastServerEvent().args[1], netId, 'the occupant has no myKennelNetId of their own -- must resolve via restState instead')
end)

t.test('/k9kennel close|open with nothing deployed and nothing entered is a silent no-op -- nothing to act on', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    k9kennel(nil, { 'close' })
    t.equals(#f.serverEvents, 0)

    k9kennel(nil, { 'open' })
    t.equals(#f.serverEvents, 0)
end)

-- ========================================================================
-- CLOSEABLE KENNEL -- ox_target surface (owner-directed audit finding, this
-- pass: "Allow the kennel to close" was reachable by chat and the
-- contextual radial item, but had NO ox_target option at all, unlike every
-- OTHER kennel action). Reuses RequestCloseKennelDoor()/
-- RequestOpenKennelDoor() (already exercised via chat above) UNMODIFIED --
-- these tests pin the ox_target-SPECIFIC part: which entity the option
-- shows on, and that it never fires on the wrong kennel.
-- ========================================================================

t.test('"Close Kennel"/"Open Kennel" ox_target options exist, with the expected icons, alongside Pick Up/Rest/Exit', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local closeOption, openOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:closeKennel' then closeOption = option end
        if option.name == 'john-k9:openKennel' then openOption = option end
    end
    t.isNotNil(closeOption, 'a "Close Kennel" option must be registered')
    t.isNotNil(openOption, 'an "Open Kennel" option must be registered')
    t.equals(closeOption.icon, 'fas fa-lock')
    t.equals(openOption.icon, 'fas fa-lock-open')
    t.equals(closeOption.label, locale('kennel.close_target_label'))
    t.equals(openOption.label, locale('kennel.open_target_label'))
end)

t.test('"Close Kennel"/"Open Kennel": canInteract is TRUE on the OWNER\'s own deployed kennel entity, and onSelect sends the matching real event with the correct netId', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    local kennelEntity = f.createObjectCalls[1].entity

    f.fireResourceStart(RESOURCE_NAME)
    local closeOption, openOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:closeKennel' then closeOption = option end
        if option.name == 'john-k9:openKennel' then openOption = option end
    end

    t.isTrue(closeOption.canInteract(kennelEntity, 1.0, {}, 'anything'))
    t.isTrue(openOption.canInteract(kennelEntity, 1.0, {}, 'anything'))

    closeOption.onSelect()
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestCloseKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)

    openOption.onSelect()
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestOpenKennel')
    t.equals(f.lastServerEvent().args[1], kennelNetId)
end)

t.test('"Close Kennel"/"Open Kennel": canInteract is TRUE on the kennel the OCCUPANT is actually resting in, and onSelect resolves via restState (no myKennelNetId of their own)', function()
    local f = newKennelFixture()
    local netId = 960
    f.registerForeignEntity(netId, 61, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.fireResourceStart(RESOURCE_NAME)
    local closeOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:closeKennel' then closeOption = option end
    end

    t.isTrue(closeOption.canInteract(61, 1.0, {}, 'anything'))
    closeOption.onSelect()
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestCloseKennel')
    t.equals(f.lastServerEvent().args[1], netId)
end)

t.test('CORRECTNESS: "Close Kennel"/"Open Kennel" canInteract is FALSE on a DIFFERENT kennel prop -- must never let a click on a stranger\'s kennel silently toggle THIS client\'s own, unrelated one', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    -- A second, unrelated kennel-model entity (e.g. some other handler's
    -- deployed kennel) this client has no relationship to at all.
    local strangerNetId = 961
    f.registerForeignEntity(strangerNetId, 62, GetHashKey(PRIMARY_MODEL))

    f.fireResourceStart(RESOURCE_NAME)
    local closeOption, openOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:closeKennel' then closeOption = option end
        if option.name == 'john-k9:openKennel' then openOption = option end
    end

    t.isFalse(closeOption.canInteract(62, 1.0, {}, 'anything'), 'must not offer to close a kennel this client neither owns nor rests in, even while THIS client has its own kennel deployed elsewhere')
    t.isFalse(openOption.canInteract(62, 1.0, {}, 'anything'))
end)

t.test('"Close Kennel"/"Open Kennel": canInteract is FALSE with nothing deployed and nothing entered', function()
    local f = newKennelFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local closeOption, openOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:closeKennel' then closeOption = option end
        if option.name == 'john-k9:openKennel' then openOption = option end
    end
    t.isFalse(closeOption.canInteract(999, 1.0, {}, 'anything'))
    t.isFalse(openOption.canInteract(999, 1.0, {}, 'anything'))
end)

t.test('"Close Kennel"/"Open Kennel": canInteract hides while THIS client is carrying a kennel (matches "Pick Up Kennel"\'s own exclusion)', function()
    local f = newKennelFixture()
    f.dispatchNetEvent('john-k9:client:deployKennelAt', 65535, 0.0, 0.0, 0.0)
    local kennelNetId = f.lastServerEvent().args[1]
    local kennelEntity = f.createObjectCalls[1].entity
    f.dispatchNetEvent('john-k9:client:pickupKennelConfirmed', 65535, kennelNetId)
    t.isTrue(f.env.IsCarryingKennel())

    f.fireResourceStart(RESOURCE_NAME)
    local closeOption, openOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:closeKennel' then closeOption = option end
        if option.name == 'john-k9:openKennel' then openOption = option end
    end

    t.isFalse(closeOption.canInteract(kennelEntity, 1.0, {}, 'anything'))
    t.isFalse(openOption.canInteract(kennelEntity, 1.0, {}, 'anything'))
end)

-- ========================================================================
-- RED-THEN-GREEN CONTROL (the load-bearing proof, per this pass's own
-- brief): adding the Close/Open ox_target options above must NEVER make
-- the closed-kennel-traps-its-occupant bug possible again. The occupant's
-- "Exit Kennel" option, ExitKennelRest(), and the shared watchdog's own
-- backstops read NONE of this file's new code -- pinned here, alongside
-- the two new options, specifically so a future change to one cannot
-- silently break the other without a red test catching it in THIS same
-- file.
-- ========================================================================

t.test('CONTROL: the occupant can still ALWAYS exit through "Exit Kennel" while "Close Kennel"/"Open Kennel" are ALSO visible on the exact same entity', function()
    local f = newKennelFixture()
    local netId = 962
    f.registerForeignEntity(netId, 63, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    t.isTrue(f.env.IsRestingInKennel())

    f.fireResourceStart(RESOURCE_NAME)
    local exitOption, closeOption, openOption
    for _, option in ipairs(f.addModelCalls[#f.addModelCalls].options) do
        if option.name == 'john-k9:exitKennel' then exitOption = option end
        if option.name == 'john-k9:closeKennel' then closeOption = option end
        if option.name == 'john-k9:openKennel' then openOption = option end
    end

    -- All three genuinely coexist on the SAME entity -- exit is not hidden
    -- by the new options existing, and the new options are not hidden by
    -- exit existing.
    t.isTrue(exitOption.canInteract(63, 1.0, {}, 'anything'))
    t.isTrue(closeOption.canInteract(63, 1.0, {}, 'anything'))
    t.isTrue(openOption.canInteract(63, 1.0, {}, 'anything'))

    -- This is the occupant's own release path -- it reads NO field of
    -- server-side kennel state (see server/kennel.lua's own "CLOSEABLE
    -- KENNEL" header: "requestExitKennel... is UNCHANGED, still reads no
    -- field of `Kennels` at all"), so a closed kennel (a fact this client
    -- never even tracks locally) can never change what this call below
    -- does.
    exitOption.onSelect()
    t.isFalse(f.env.IsRestingInKennel(), 'the occupant must still be able to get out, regardless of the kennel\'s open/closed state, which this option never reads')
    t.isTrue(#f.detachCalls >= 1 and f.detachCalls[#f.detachCalls].handle == MY_PED)
    t.isTrue(#f.collisionCalls >= 1 and f.collisionCalls[#f.collisionCalls].handle == MY_PED and f.collisionCalls[#f.collisionCalls].toggle == true)
end)

-- GATE WIDENED TO HasK9Access() ALONE (permission audit finding, this
-- pass) -- these three used to set CanShowK9UI() false to prove a refusal;
-- that is no longer this gate (see RequestDeployKennel()'s own "GATE
-- WIDENED" doc comment), so the CONTROL below opts out via HasK9Access()
-- instead, and a new companion test proves the bypass shape reaches the
-- server through THIS dispatch path too, not just the direct call already
-- covered above.

t.test('GATE MATCHES RequestDeployKennel(): bare /k9kennel (deploy branch) still refuses without HasK9Access, identically to /k9deploykennel', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.setHasK9Access(false)

    k9kennel(nil, {})

    t.equals(#f.serverEvents, 0, 'no deploy request must reach the server for an unauthorized caller')
    t.equals(f.denyCallCount(), 1)
end)

t.test('GATE MATCHES RequestDeployKennel(): explicit /k9kennel deploy ALSO refuses without HasK9Access, identically to /k9deploykennel', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.setHasK9Access(false)

    k9kennel(nil, { 'deploy' })

    t.equals(#f.serverEvents, 0)
    t.equals(f.denyCallCount(), 1)
end)

t.test('GATE WIDENED, REACHABLE THROUGH THE MERGE TOO: bare /k9kennel (deploy branch) succeeds for a HasK9Access()-true bypass holder even with CanShowK9UI() false', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)
    f.setHasK9Access(true)
    f.setCanShowK9UI(false)

    k9kennel(nil, {})

    t.equals(f.denyCallCount(), 0, 'a HasK9Access()-true bypass holder must never be denied even though CanShowK9UI() would have refused them')
    t.equals(#f.serverEvents, 1, 'a HasK9Access()-true bypass holder must reach the server even though CanShowK9UI() would have refused them')
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDeployKennel')
end)

t.test('GATE NEVER WIDENED: exiting via the K9 menu\'s Kennel button while resting stays UNGATED even with CanShowK9UI false (never gate the stop)', function()
    local f = newKennelFixture()
    local netId = 902
    f.registerForeignEntity(netId, 57, GetHashKey(PRIMARY_MODEL))
    f.dispatchNetEvent('john-k9:client:enterKennelConfirmed', 65535, netId)
    f.setCanShowK9UI(false)

    f.env.RequestKennelContextual()

    t.isFalse(f.env.IsRestingInKennel())
    t.equals(f.denyCallCount(), 0, 'exiting must never be denied, even with CanShowK9UI false')
end)

t.test('NO-ARGUMENT DISCOVERABILITY / unrecognized word: an argument that is not deploy/enter/exit shows the usage notice, never guesses', function()
    local f = newKennelFixture()
    local k9kennel = findK9Kennel(f)

    k9kennel(nil, { 'bogus' })

    t.equals(#f.serverEvents, 0, 'an unrecognized word must never fall through to a guessed action')
    t.equals(f.lastNotify().description, locale('kennel.usage_k9kennel'))
end)

t.test('ADDITIVE, NOT A REPLACEMENT: k9deploykennel keeps working exactly as before, unaffected by k9kennel existing alongside it', function()
    local f = newKennelFixture()
    local byName = {}
    for _, c in ipairs(f.commands) do byName[c.name] = c.handler end

    byName['k9deploykennel']()
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestDeployKennel')
end)

os.exit(t.summary())
