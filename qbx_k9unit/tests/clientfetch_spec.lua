--[[
    tests/clientfetch_spec.lua

    Direct, black-box tests of client/fetch.lua against the REAL,
    unmodified production file -- the client half of
    Config.Features.FetchMechanic (server/fetch.lua's own header is the
    authoritative contract). One of six client files this pass writes a
    spec for (see tests/vehiclecombatguard_spec.lua's own header, whose
    disclosed gap this batch exists to close).

    STYLE: fresh sandbox per test, a local fixture Config (never the real
    config.lua, per this suite's established convention -- see
    tests/clientcombat_spec.lua's header), a direct K9Compat stub (not the
    real shared/compat/core.lua + shared/compat/target.lua adapter pair --
    see tests/clientkennel_spec.lua's own header for why: this file's own
    logic, not the compat translation layer, is what this spec exists to
    exercise).

    HARD (NOT SOFT) CROSS-FILE DEPENDENCY: this file calls
    client/propattachment.lua's `AttachPropToOwnPed`/`DetachAndDeleteProp`
    UNGUARDED (no `type(fn) == 'function'` check) -- per its own header,
    "must load after both of those files". This spec stubs both directly
    and controllably, matching this suite's established treatment of a hard
    cross-file dependency (see tests/clientcombat_spec.lua's own
    IsOwnModelK9()/HasK9Access() treatment) -- it does not load the real
    client/propattachment.lua, which is covered by its own dedicated spec.

    NET-EVENT DISPATCH RUNS INSIDE A FRESH COROUTINE (mirrors
    tests/clientkennel_spec.lua's identical `dispatchNetEvent`): several
    handlers here (`throwFetchBallAt`, `endFetchCarry`'s 'fake'-mode drop
    recreate) call `LoadModelWithTimeout`, which polls `Wait(50)` in a real
    loop -- legal because FiveM's own RegisterNetEvent handlers already run
    inside their own coroutine context in production.

    THE TWO PERSISTENT CreateThread THREADS (OWN-DEATH poll,
    CONFIRM-FAILURE BACKSTOP) use `Sandbox.newThreadRunner()` -- both are
    plain `while true do ... Wait(x) ... end` loops, exactly the shape that
    helper was built for (unlike tests/clientcombat_spec.lua's own
    SetTimeout/promise-driven maintenance thread, which needed a different
    approach). `f.step()` resumes BOTH captured threads once per call, per
    that helper's own documented "first step primes, each call after runs
    one pass" semantics.

    ONE REAL DEFECT FOUND WHILE WRITING THIS SPEC, NOW FIXED (client/
    fetch.lua's own "STALE-CARRY GUARD" comment on `carryFetchBall` is the
    fix itself) -- the dedicated test below pins the FIXED behavior, not the
    original bug. Left here as a record of what was wrong and what changed:

    NO STALE-CARRY GUARD ON `carryFetchBall`'S 'attach' BRANCH (FIXED) -- an
    asymmetry with client/propattachment.lua's own `attachK9Prop`, which
    DOES guard against exactly this shape (see that file's "STALE-VEST
    GUARD" comment), and the SAME bug class as this pass's other fixed
    finding in client/kennel.lua's `deployKennelAt` (see
    tests/clientkennel_spec.lua's header). If
    'qbx_k9unit:client:carryFetchBall' was ever dispatched to the same
    client TWICE in 'attach' mode before the FIRST resulting
    `ActiveFetchCarry.netId` was ever cleared, the second dispatch called
    `AttachPropToOwnPed` again and overwrote `ActiveFetchCarry` with the NEW
    netId -- the FIRST attached entity was never detached or deleted, and
    nothing in this file could ever reach it again. Fixed with a
    STALE-CARRY GUARD at the top of the carryFetchBall handler, mirroring
    client/propattachment.lua's STALE-VEST GUARD / client/kennel.lua's
    STALE-KENNEL GUARD: a still-set `ActiveFetchCarry` in 'attach' mode is
    resolved and torn down via DetachAndDeleteProp BEFORE this dispatch's
    own `mode` is even branched on (a second dispatch's own mode says
    nothing about what the PREVIOUS carry was). See the dedicated test below
    for the exact repro, now pinning the fixed, leak-free behavior.
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

local RESOURCE_NAME = 'qbx_k9unit'
local BALL_MODEL = 'prop_tennis_ball'

--- @param opts { fetchMechanic: boolean?, maxBallLifetimeMs: number? }?
--- @return table fixture
local function newFetchFixture(opts)
    opts = opts or {}

    local hasK9Access = true
    local function HasK9Access() return hasK9Access end
    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

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

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    -- ---- Sandbox.newThreadRunner() for the two persistent threads ----
    local threadRunner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CountingCreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        threadRunner.CreateThread(fn)
    end

    -- ---- model loading ----
    local modelBehavior = {} -- [hash] = 'timeout' | 'invalid' | nil (loads immediately)
    local requestModelCalls, releaseModelCalls = {}, {}
    local function IsModelValid(hash) return modelBehavior[hash] ~= 'invalid' end
    local function RequestModel(hash) requestModelCalls[#requestModelCalls + 1] = hash end
    local function HasModelLoaded(hash) return modelBehavior[hash] ~= 'timeout' end
    local function SetModelAsNoLongerNeeded(hash) releaseModelCalls[#releaseModelCalls + 1] = hash end

    -- ---- ped / entity state ----
    local pedHandle = 1
    local existingEntities = { [1] = true }
    local entityModels = {}
    local pedDead = false
    local pedCoords = { x = 10.0, y = 20.0, z = 5.0 }
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return entity == pedHandle and pedDead or false end
    local function GetEntityModel(entity) return entityModels[entity] end
    local function GetEntityCoords(_entity) return pedCoords end

    local objectSeq = 0
    local objectBehavior = {}
    local createObjectCalls, deleteEntityCalls = {}, {}
    local function CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag)
        objectSeq = objectSeq + 1
        local entity = objectSeq
        createObjectCalls[#createObjectCalls + 1] = { entity = entity, modelHash = modelHash, x = x, y = y, z = z }
        if objectBehavior.createFails then return 0 end
        existingEntities[entity] = true
        entityModels[entity] = modelHash
        return entity
    end
    local function DeleteEntity(entity)
        deleteEntityCalls[#deleteEntityCalls + 1] = entity
        existingEntities[entity] = nil
    end

    local applyForceCalls = {}
    local function ApplyForceToEntity(entity, forceType, x, y, z, ox, oy, oz, bone, isDirRel, isForceRel, isSoftForce, apply, p13)
        applyForceCalls[#applyForceCalls + 1] = { entity = entity, forceType = forceType, x = x, y = y, z = z }
    end

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
    -- ResolveNetworkEntity -- same convention as tests/clientkennel_spec.lua.
    local function ResolveNetworkEntity(netId)
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    local requestControlCalls = {}
    local function NetworkRequestControlOfEntity(entity) requestControlCalls[#requestControlCalls + 1] = entity end

    local clearTasksCalls, scenarioCalls = {}, {}
    local function ClearPedTasksImmediately(ped) clearTasksCalls[#clearTasksCalls + 1] = ped end
    local function TaskStartScenarioInPlace(ped, name, p2, playEnter) scenarioCalls[#scenarioCalls + 1] = { ped = ped, name = name } end

    local detachEntityCalls = {}
    local function DetachEntity(entity, ...) detachEntityCalls[#detachEntityCalls + 1] = entity end

    -- ---- HARD cross-file dependency: client/propattachment.lua -- see this
    -- file's own header. Direct, controllable stubs, never the real file.
    local attachPropCalls, detachAndDeleteCalls = {}, {}
    local attachPropBehavior = { succeeds = true }
    local function AttachPropToOwnPed(modelName, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, isNetworked, timeoutMs)
        attachPropCalls[#attachPropCalls + 1] = {
            modelName = modelName, boneIndex = boneIndex,
            offsetX = offsetX, offsetY = offsetY, offsetZ = offsetZ,
            isNetworked = isNetworked,
        }
        if not attachPropBehavior.succeeds then return nil end
        objectSeq = objectSeq + 1
        local entity = objectSeq
        existingEntities[entity] = true
        entityModels[entity] = GetHashKey(BALL_MODEL)
        return entity
    end
    local function DetachAndDeleteProp(entity)
        detachAndDeleteCalls[#detachAndDeleteCalls + 1] = entity
        if entity then existingEntities[entity] = nil end
    end

    -- ---- K9Compat -- direct stub, see this file's header ----
    local addModelCalls, addGlobalPlayerCalls = {}, {}
    local K9Compat = {
        Get = function(_system)
            return {
                AddModel = function(models, options) addModelCalls[#addModelCalls + 1] = { models = models, options = options } end,
                AddGlobalPlayer = function(options) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = options end,
            }
        end,
        Redetect = function() end,
        Which = function(_system) return 'ox_target' end,
    }

    -- ---- "Deliver to Handler" onSelect/canInteract support ----
    local myPlayerId = 1
    local otherPlayerIndex = 7
    local function PlayerId() return myPlayerId end
    -- entity 1 (pedHandle, "my own ped") maps back to MY OWN player index --
    -- the real native's actual behavior for your own ped -- so the
    -- "carrier's own ped must never be a valid delivery target" check below
    -- exercises the real `NetworkGetPlayerIndexFromPed(entity) ~= PlayerId()`
    -- comparison meaningfully, not vacuously.
    local function NetworkGetPlayerIndexFromPed(entity)
        if entity == 999 then return otherPlayerIndex end
        if entity == pedHandle then return myPlayerId end
        return -1
    end
    local function GetPlayerServerId(playerIndex) return playerIndex == otherPlayerIndex and 55 or -1 end
    local function ResolvePlayerServerIdFromPed(entity)
        local idx = NetworkGetPlayerIndexFromPed(entity)
        if idx == -1 then return nil end
        local serverId = GetPlayerServerId(idx)
        if serverId == -1 then return nil end
        return serverId
    end

    local config = {
        Features = { FetchMechanic = opts.fetchMechanic ~= false },
        FetchMechanic = {
            ballPropModel = BALL_MODEL,
            mouthBoneIndex = 0,
            mouthOffsetX = 0.0, mouthOffsetY = 0.4, mouthOffsetZ = 0.15,
            maxBallLifetimeMs = opts.maxBallLifetimeMs or 300000,
            pickupInteractDistanceMeters = 2.0,
            deliverProximityMeters = 3.0,
        },
    }

    local env = Sandbox.newEnv({
        Config = config,
        GetHashKey = GetHashKey,
        HasK9Access = HasK9Access,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CountingCreateThread,
        Wait = threadRunner.Wait,
        GetGameTimer = GetGameTimer,
        IsModelValid = IsModelValid,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        GetEntityModel = GetEntityModel,
        GetEntityCoords = GetEntityCoords,
        CreateObject = CreateObject,
        DeleteEntity = DeleteEntity,
        ApplyForceToEntity = ApplyForceToEntity,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        NetworkRequestControlOfEntity = NetworkRequestControlOfEntity,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
        DetachEntity = DetachEntity,
        AttachPropToOwnPed = AttachPropToOwnPed,
        DetachAndDeleteProp = DetachAndDeleteProp,
        K9Compat = K9Compat,
        PlayerId = PlayerId,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        GetPlayerServerId = GetPlayerServerId,
        ResolvePlayerServerIdFromPed = ResolvePlayerServerIdFromPed,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    })

    Sandbox.loadInto('../client/fetch.lua', env)

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
        threadCount = function() return threadCreateCount end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        step = threadRunner.step,
        addModelCalls = addModelCalls,
        addGlobalPlayerCalls = addGlobalPlayerCalls,
        setHasK9Access = function(v) hasK9Access = v end,
        denyCallCount = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setModelBehavior = function(modelName, behavior) modelBehavior[GetHashKey(modelName)] = behavior end,
        setObjectBehavior = function(t2) objectBehavior = t2 or {} end,
        setAttachPropBehavior = function(t2) attachPropBehavior = t2 end,
        requestModelCalls = requestModelCalls,
        releaseModelCalls = releaseModelCalls,
        createObjectCalls = createObjectCalls,
        deleteEntityCalls = deleteEntityCalls,
        applyForceCalls = applyForceCalls,
        requestControlCalls = requestControlCalls,
        clearTasksCalls = clearTasksCalls,
        scenarioCalls = scenarioCalls,
        detachEntityCalls = detachEntityCalls,
        attachPropCalls = attachPropCalls,
        detachAndDeleteCalls = detachAndDeleteCalls,
        setPedDead = function(v) pedDead = v end,
        setPedMissing = function() existingEntities[pedHandle] = nil end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        registerForeignEntity = function(netId, entity, modelHash)
            existingEntities[entity] = true
            entityModels[entity] = modelHash
            netIdByEntity[entity] = netId
        end,
        --- Runs a captured RegisterNetEvent handler to completion inside its
        --- own fresh coroutine -- same convention as
        --- tests/clientkennel_spec.lua's identical helper.
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
    }
end

-- ========================================================================
-- FEATURE OFF -- this file DOES have a real top-of-file
-- `if not Config.Features.FetchMechanic then return end` gate, so, unlike
-- client/kennel.lua/client/vehicle.lua, "genuinely inert" is provably true
-- here, not just claimed.
-- ========================================================================

t.test('feature off: no globals, no commands, no net events, no threads, no onResourceStart/onResourceStop handlers', function()
    local f = newFetchFixture({ fetchMechanic = false })
    t.isNil(f.env.RequestThrowFetchBall)
    t.isNil(f.env.ReleaseFetchBall)
    t.isNil(f.env.RequestRecallFetchBall)
    t.isNil(f.env.IsFetchCarryEngaged)
    t.equals(#f.commands, 0)
    t.equals(f.netEventCount(), 0)
    t.equals(f.onResourceStartHandlerCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
    t.equals(f.threadCount(), 0)
end)

-- ========================================================================
-- Sanity + happy path
-- ========================================================================

t.test('feature on: exposes all four globals, registers 4 commands (3 hidden aliases + merged k9fetch), 4 net events, both onResourceStart/onResourceStop handlers, and 2 threads', function()
    local f = newFetchFixture()
    t.isNotNil(f.env.RequestThrowFetchBall)
    t.isNotNil(f.env.ReleaseFetchBall)
    t.isNotNil(f.env.RequestRecallFetchBall)
    t.isNotNil(f.env.IsFetchCarryEngaged)
    t.equals(#f.commands, 4, 'k9throwfetchball, k9dropfetchball, k9recallfetchball (hidden aliases) + k9fetch (docs/history/COMMAND_CONSOLIDATION_SPEC.md #3)')
    t.equals(f.netEventCount(), 4)
    t.isNotNil(f.netEventNames['qbx_k9unit:client:throwFetchBallAt'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:carryFetchBall'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:endFetchCarry'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:removeFetchBall'])
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
    t.equals(f.threadCount(), 2, 'OWN-DEATH poll + CONFIRM-FAILURE BACKSTOP')
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('RequestThrowFetchBall: HasK9Access false denies locally, no server contact', function()
    local f = newFetchFixture()
    f.setHasK9Access(false)
    f.env.RequestThrowFetchBall()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestThrowFetchBall: happy path sends the real requestThrowFetchBall event', function()
    local f = newFetchFixture()
    f.env.RequestThrowFetchBall()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestThrowFetchBall')
end)

t.test('commands: k9throwfetchball/k9dropfetchball/k9recallfetchball are wired to their real functions', function()
    local f = newFetchFixture()
    local byName = {}
    for _, c in ipairs(f.commands) do byName[c.name] = c.handler end

    byName['k9throwfetchball']()
    t.equals(f.serverEvents[1].event, 'qbx_k9unit:server:requestThrowFetchBall')

    byName['k9recallfetchball']()
    t.equals(f.serverEvents[2].event, 'qbx_k9unit:server:requestRecallFetchBall')

    -- ReleaseFetchBall is a no-op while not carrying -- proves the command
    -- really calls the real function (which itself correctly no-ops here),
    -- not that the command is unwired.
    byName['k9dropfetchball']()
    t.equals(#f.serverEvents, 2, 'ReleaseFetchBall must not send anything while ActiveFetchCarry is nil')
end)

-- ========================================================================
-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md #3) -- the merged
-- '/k9fetch' entry point. Reference implementation for contextual dispatch
-- across the five families (project-owner-directed mid-pass redirect) --
-- see this file's own new comment block above RegisterCommand('k9fetch', ...)
-- in client/fetch.lua for the full design writeup.
-- ========================================================================

--- @param f table -- newFetchFixture() result
--- @return fun(...) k9fetch handler
local function findK9Fetch(f)
    for _, c in ipairs(f.commands) do
        if c.name == 'k9fetch' then return c.handler end
    end
    error('k9fetch command not registered')
end

t.test('FetchContextual is the shared one-click action (radial Fetch item, tablet button, bare /k9fetch); IsMyFetchBallOut tracks this client\'s own ball', function()
    local f = newFetchFixture()
    t.equals(type(f.env.FetchContextual), 'function')
    t.isFalse(f.env.IsMyFetchBallOut())

    f.env.FetchContextual()
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestThrowFetchBall')

    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    t.isTrue(f.env.IsMyFetchBallOut(), 'the thrower\'s own ball is out')

    f.env.FetchContextual()
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestRecallFetchBall', 'the same click now calls it back')
end)

t.test('CONTEXTUAL DISPATCH: bare /k9fetch THROWS when nothing is active (no carry, no thrown ball)', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)

    k9fetch(nil, {})

    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestThrowFetchBall')
end)

t.test('CONTEXTUAL DISPATCH: bare /k9fetch RECALLS when this client has an active thrown ball out in the world', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)

    -- Puts this client into the "I threw one, still active" state via the
    -- REAL production path (throwFetchBallAt), not a hand-set internal --
    -- same "drive it through the real net event" discipline the rest of
    -- this spec already uses.
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)

    k9fetch(nil, {})

    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestRecallFetchBall', 'a client with an active thrown ball must recall, never throw a second one')
end)

t.test('CONTEXTUAL DISPATCH: bare /k9fetch DROPS when this client is currently carrying the ball', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)

    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    local ballNetId = f.lastServerEvent().args[1]
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, ballNetId, 'fake') -- puts this client into ActiveFetchCarry ~= nil via the real net event
    t.isTrue(f.env.IsFetchCarryEngaged())

    k9fetch(nil, {})

    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:releaseFetchBall', 'a carrying client must drop, never throw or recall')
end)

t.test('EXPLICIT OVERRIDE: /k9fetch throw|drop|recall force that exact action regardless of dispatcher-inferred state', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)

    k9fetch(nil, { 'throw' })
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestThrowFetchBall')

    k9fetch(nil, { 'recall' })
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestRecallFetchBall')

    -- 'drop' while NOT carrying -- forces ReleaseFetchBall() the same as
    -- the old k9dropfetchball alias does, which itself correctly no-ops.
    local eventsBefore = #f.serverEvents
    k9fetch(nil, { 'drop' })
    t.equals(#f.serverEvents, eventsBefore, 'ReleaseFetchBall must still no-op with no active carry, even via the explicit override')
end)

t.test('GATE NEVER WIDENED BY THE MERGE: bare /k9fetch (throw branch) still refuses without HasK9Access, identically to /k9throwfetchball', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)
    f.setHasK9Access(false)

    k9fetch(nil, {})

    t.equals(#f.serverEvents, 0, 'no throw request must reach the server for an unauthorized caller')
    t.equals(f.denyCallCount(), 1)
end)

t.test('GATE NEVER WIDENED BY THE MERGE: explicit /k9fetch throw ALSO refuses without HasK9Access, identically to /k9throwfetchball', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)
    f.setHasK9Access(false)

    k9fetch(nil, { 'throw' })

    t.equals(#f.serverEvents, 0)
    t.equals(f.denyCallCount(), 1)
end)

t.test('NO-ARGUMENT DISCOVERABILITY / unrecognized word: an argument that is not throw/drop/recall notifies the usage string instead of guessing', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)

    k9fetch(nil, { 'bogus' })

    t.equals(#f.serverEvents, 0, 'an unrecognized word must never fall through to a guessed action')
    t.equals(f.lastNotify().description, locale('fetch.usage_k9fetch'))
end)

t.test('CONFIRMATION NAMES THE DECISION: the bare contextual dispatch notifies which action it picked before firing it', function()
    local f = newFetchFixture()
    local k9fetch = findK9Fetch(f)

    k9fetch(nil, {})
    t.equals(f.notifyCalls[1].description, locale('fetch.contextual_throwing'))
end)

t.test('throwFetchBallAt: happy path -- creates the ball, applies a forceType-3 impulse, reports the netId back', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 1)
    t.equals(#f.applyForceCalls, 1)
    t.equals(f.applyForceCalls[1].forceType, 3, 'must be APPLY_TYPE_IMPULSE, not a continuous force')
    t.equals(f.applyForceCalls[1].x, 1.0)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:confirmFetchBallThrown')
end)

t.test('throwFetchBallAt: source guard rejects a forged local trigger', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 1, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
end)

t.test('throwFetchBallAt: any non-number argument among the six is rejected', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 'oops')
    t.equals(#f.createObjectCalls, 0)
end)

t.test('throwFetchBallAt: model never loads -- notifies, cancels the throw, never calls CreateObject', function()
    local f = newFetchFixture()
    f.setModelBehavior(BALL_MODEL, 'invalid')
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    t.equals(#f.createObjectCalls, 0)
    t.equals(f.lastNotify().description, locale('fetch.prop_load_failed'))
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:cancelFetchThrow')
end)

t.test('throwFetchBallAt: CreateObject fails -- notifies, cancels the throw', function()
    local f = newFetchFixture()
    f.setObjectBehavior({ createFails = true })
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    t.equals(f.lastNotify().description, locale('fetch.throw_failed'))
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:cancelFetchThrow')
end)

t.test('FIXED: STALE-THROW GUARD -- a second throwFetchBallAt dispatch before the first is ever cleared now deletes the first ball instead of orphaning it (mirrors client/kennel.lua\'s own deployKennelAt STALE-KENNEL GUARD)', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    local firstEntity = f.createObjectCalls[1].entity
    t.equals(#f.deleteEntityCalls, 0, 'the first thrown ball is still alive and untouched after only one dispatch')

    -- A second throwFetchBallAt lands for the SAME client before the first
    -- ball's netId is ever cleared (removeFetchBall / onResourceStop / the
    -- CONFIRM-FAILURE BACKSTOP thread) -- see this file's own STALE-THROW
    -- GUARD comment for the concrete scenarios this models.
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 40.0, 50.0, 6.0, 0.0, 0.0, 0.0)
    local secondEntity = f.createObjectCalls[2].entity

    t.equals(#f.createObjectCalls, 2, 'a second, independent ball object is created')
    t.equals(#f.deleteEntityCalls, 1, 'FIXED: the STALE-THROW GUARD deletes the first ball before the second is even created')
    t.equals(f.deleteEntityCalls[1], firstEntity, 'the entity actually deleted by the guard is the FIRST ball, not the second')

    -- The SECOND (now-current) ball is still tracked correctly: onResourceStop
    -- cleans it up exactly once, and never re-touches the already-deleted first.
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 2, 'onResourceStop cleans up the second (now-current) ball too')
    t.equals(f.deleteEntityCalls[2], secondEntity, 'the second delete call targets the SECOND ball, confirming myThrownBallNetId correctly tracks the current one, not the orphaned first')
end)

t.test('carryFetchBall (mode="fake"): deletes the old ball, plays the carry stance, engages the fake carry', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    local ballNetId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, ballNetId, 'fake')
    t.equals(#f.requestControlCalls, 1)
    t.equals(#f.deleteEntityCalls, 1)
    t.equals(#f.clearTasksCalls, 1)
    t.equals(#f.scenarioCalls, 1)
    t.isTrue(f.env.IsFetchCarryEngaged())
end)

t.test('carryFetchBall (mode="attach"): deletes the old ball, calls AttachPropToOwnPed with the configured mouth bone/offset, reports the NEW netId', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    local ballNetId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, ballNetId, 'attach')
    t.equals(#f.attachPropCalls, 1)
    t.equals(f.attachPropCalls[1].modelName, BALL_MODEL)
    t.equals(f.attachPropCalls[1].boneIndex, 0)
    t.equals(f.attachPropCalls[1].offsetY, 0.4)
    t.equals(f.attachPropCalls[1].isNetworked, true, 'other clients must see the carried ball')
    t.isTrue(f.env.IsFetchCarryEngaged())
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:confirmFetchBallCarried')
    t.isTrue(f.lastServerEvent().args[1] ~= ballNetId, 'the reported netId must be the NEW attached entity\'s, not the old ball\'s')
end)

t.test('carryFetchBall (mode="attach"): AttachPropToOwnPed failure notifies, cancels the attach, leaves carry disengaged', function()
    local f = newFetchFixture()
    f.setAttachPropBehavior({ succeeds = false })
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')
    t.isFalse(f.env.IsFetchCarryEngaged())
    t.equals(f.lastNotify().description, locale('fetch.carry_failed'))
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:cancelFetchCarryAttach')
end)

t.test('carryFetchBall: source guard, invalid netId type, and invalid mode are all rejected as clean no-ops', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 1, 999, 'attach')
    t.isFalse(f.env.IsFetchCarryEngaged())

    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 'not-a-number', 'attach')
    t.isFalse(f.env.IsFetchCarryEngaged())

    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999, 'bogus-mode')
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('carryFetchBall: DEFENSE-IN-DEPTH MODEL CHECK -- a resolvable old-ball netId whose model is not the configured ball prop is rejected before anything else happens', function()
    local f = newFetchFixture()
    f.registerForeignEntity(555, 40, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 555, 'attach')
    t.equals(#f.requestControlCalls, 0)
    t.equals(#f.attachPropCalls, 0)
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('endFetchCarry (mode="attach", terminal=false): a plain drop only DETACHES, never deletes -- the ball stays pickup-able', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')

    f.dispatchNetEvent('qbx_k9unit:client:endFetchCarry', 65535, 'attach', false)
    t.equals(#f.detachEntityCalls, 1)
    t.equals(#f.detachAndDeleteCalls, 0, 'a non-terminal drop must never delete the entity')
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('endFetchCarry (mode="attach", terminal=true): DEFENSE-IN-DEPTH -- deletes THIS client\'s own last-known attached entity directly', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')

    f.dispatchNetEvent('qbx_k9unit:client:endFetchCarry', 65535, 'attach', true)
    t.equals(#f.detachAndDeleteCalls, 1)
    t.equals(#f.detachEntityCalls, 0, 'a terminal end must delete, not just detach')
end)

t.test('endFetchCarry (mode="fake", terminal=false): clears tasks and recreates a real, visible ball at the K9\'s current position', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'fake')

    f.dispatchNetEvent('qbx_k9unit:client:endFetchCarry', 65535, 'fake', false)
    t.isTrue(#f.clearTasksCalls >= 1)
    t.equals(#f.createObjectCalls, 1)
    t.equals(f.createObjectCalls[1].x, 10.0, 'must recreate at the ped\'s own current coords')
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:confirmFetchBallDropped')
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('endFetchCarry (mode="fake", terminal=true): clears tasks, but recreates nothing -- the cycle is over', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'fake')

    f.dispatchNetEvent('qbx_k9unit:client:endFetchCarry', 65535, 'fake', true)
    t.equals(#f.createObjectCalls, 0)
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('endFetchCarry: source guard and an invalid mode are both clean no-ops', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')
    f.dispatchNetEvent('qbx_k9unit:client:endFetchCarry', 1, 'attach', true)
    t.isTrue(f.env.IsFetchCarryEngaged(), 'a forged local trigger must never end a real carry')

    f.dispatchNetEvent('qbx_k9unit:client:endFetchCarry', 65535, 'bogus', true)
    t.isTrue(f.env.IsFetchCarryEngaged())
end)

t.test('removeFetchBall (cleanup backstop): source guard, non-number netId, unresolvable netId and the DEFENSE-IN-DEPTH model check are all safe no-ops', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:removeFetchBall', 1, 999999)
    t.equals(#f.deleteEntityCalls, 0)

    f.dispatchNetEvent('qbx_k9unit:client:removeFetchBall', 65535, 'not-a-number')
    t.equals(#f.deleteEntityCalls, 0)

    f.dispatchNetEvent('qbx_k9unit:client:removeFetchBall', 65535, 999999)
    t.equals(#f.deleteEntityCalls, 0)

    f.registerForeignEntity(556, 41, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('qbx_k9unit:client:removeFetchBall', 65535, 556)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeFetchBall: happy path -- deletes a real, resolvable ball, and clears BOTH myThrownBallNetId and a matching ActiveFetchCarry.netId', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    local ballNetId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('qbx_k9unit:client:removeFetchBall', 65535, ballNetId)
    t.equals(#f.deleteEntityCalls, 1)

    -- Proves myThrownBallNetId was really cleared: onResourceStop afterward
    -- finds nothing left of the thrown ball to clean up.
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'onResourceStop must not attempt a second delete of the already-removed ball')
end)

t.test('ReleaseFetchBall: no-op when not carrying; sends releaseFetchBall unconditionally (no access gate) when carrying', function()
    local f = newFetchFixture()
    f.env.ReleaseFetchBall()
    t.equals(#f.serverEvents, 0)

    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'fake')
    f.setHasK9Access(false) -- must not matter -- release has no access gate
    f.env.ReleaseFetchBall()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:releaseFetchBall')
end)

t.test('ANY PED: RequestThrowFetchBall works via HasK9Access() alone -- CanShowK9UI/IsOwnModelK9 are never consulted, and this fixture never even defines IsOwnModelK9', function()
    local f = newFetchFixture()
    t.isNil(f.env.IsOwnModelK9, 'sanity: this fixture genuinely never defines IsOwnModelK9')
    f.setCanShowK9UI(false) -- must not matter at all for the throw gate
    local ok, err = pcall(f.env.RequestThrowFetchBall)
    t.isTrue(ok, 'must not reach for a global this file does not use for this gate: ' .. tostring(err))
    t.equals(#f.serverEvents, 1, 'HasK9Access() alone is the whole gate -- CanShowK9UI() false must not block a human handler throw')
end)

t.test('ANY PED: RequestRecallFetchBall is unconditional -- works even with HasK9Access false, mid-carry or not', function()
    local f = newFetchFixture()
    f.setHasK9Access(false)
    f.env.RequestRecallFetchBall()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestRecallFetchBall')
end)

t.test('ANY PED: "Deliver to Handler" canInteract has no access gate at all beyond ActiveFetchCarry + not-self', function()
    local f = newFetchFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local deliverOption
    for _, option in ipairs(f.addGlobalPlayerCalls[1]) do
        if option.name == 'qbx_k9unit:deliverFetchBall' then deliverOption = option end
    end
    t.isNotNil(deliverOption)

    -- Not carrying -- hidden regardless of anything else.
    t.isFalse(deliverOption.canInteract(999, 1.0, {}, 'x'))

    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'fake')
    t.isTrue(deliverOption.canInteract(999, 1.0, {}, 'x'), 'a real, non-self target while carrying must be offered with no further gate')
    t.isFalse(deliverOption.canInteract(1, 1.0, {}, 'x'), 'the carrier\'s own ped must never be a valid delivery target')
end)

t.test('ANY PED: "Pick Up Ball" canInteract gates on CanShowK9UI() alone', function()
    local f = newFetchFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local pickupOption = f.addModelCalls[1].options[1]
    t.equals(pickupOption.name, 'qbx_k9unit:pickupFetchBall')
    t.isTrue(pickupOption.canInteract(1, 1.0, {}, 'x'))

    f.setCanShowK9UI(false)
    t.isFalse(pickupOption.canInteract(1, 1.0, {}, 'x'))
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- the highest-priority area per this task's own
-- brief.
-- ========================================================================

t.test('OWN-DEATH poll: idle (ActiveFetchCarry nil) never even checks IsEntityDead -- a dead ped with no active carry must never fire reportFetchCarrierDown', function()
    local f = newFetchFixture()
    f.setPedDead(true)
    f.step() -- prime
    f.step() -- one idle pass
    t.equals(#f.serverEvents, 0)
end)

t.test('OWN-DEATH poll: mode="attach" -- detaches the carried entity (not delete -- the server round trip owns final cleanup), clears the carry, reports the death', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')
    f.setPedDead(true)

    f.step() -- prime -- reaches Wait(1000) inside the truthy branch
    f.step() -- performs the death check, detaches, clears, reports
    t.equals(#f.detachEntityCalls, 1)
    t.isFalse(f.env.IsFetchCarryEngaged())
    -- 2, not 1: carryFetchBall's own dispatch above already sent
    -- confirmFetchBallCarried -- the death thread adds a SECOND, distinct
    -- event on top of that, it does not replace it.
    t.equals(#f.serverEvents, 2)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:reportFetchCarrierDown')
end)

t.test('OWN-DEATH poll: mode="fake" -- no entity to detach, but the carry is still cleared and the death still reported', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'fake')
    f.setPedDead(true)

    f.step()
    f.step()
    t.equals(#f.detachEntityCalls, 0)
    t.isFalse(f.env.IsFetchCarryEngaged())
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:reportFetchCarrierDown')
end)

t.test('CONFIRM-FAILURE BACKSTOP: does nothing before the deadline, then deletes and clears exactly once the deadline is reached', function()
    local f = newFetchFixture({ maxBallLifetimeMs = 1000 })
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    t.equals(#f.deleteEntityCalls, 0)

    f.step() -- prime both threads
    f.advance(1000 + 15000 - 1) -- one ms before the deadline (maxBallLifetimeMs + the 15s jitter margin)
    f.step()
    t.equals(#f.deleteEntityCalls, 0, 'must not act before its own deadline')

    f.advance(2)
    f.step()
    t.equals(#f.deleteEntityCalls, 1, 'must act once the deadline is reached')

    f.step() -- a later pass must not double-delete -- myThrownBallNetId is already cleared
    t.equals(#f.deleteEntityCalls, 1)
end)

t.test('CONFIRM-FAILURE BACKSTOP: a ball that is legitimately picked up well BEFORE the deadline is never touched by the backstop', function()
    local f = newFetchFixture({ maxBallLifetimeMs = 1000 })
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    local ballNetId = f.lastServerEvent().args[1]
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, ballNetId, 'fake')

    f.step()
    f.advance(1000 + 15000 + 1000) -- well past what the deadline WOULD have been
    f.step()
    t.equals(#f.deleteEntityCalls, 1, 'only the ORIGINAL throw-path delete from carryFetchBall\'s own old-entity cleanup -- the backstop must never fire a second, spurious delete for an already-resolved throw')
end)

t.test('onResourceStop: mismatched resourceName never fires, even mid-carry', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')
    f.fireResourceStop('some_other_resource')
    t.isTrue(f.env.IsFetchCarryEngaged())
end)

t.test('onResourceStop: mode="attach" -- deletes (not just detaches) the carried entity via DetachAndDeleteProp, then clears the carry', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachAndDeleteCalls, 1)
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('onResourceStop: a still-outstanding thrown ball (never picked up) is deleted too, and both cleanups can fire together with zero interference', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:throwFetchBallAt', 65535, 10.0, 20.0, 5.0, 1.0, 2.0, 3.0)
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach') -- a SEPARATE, second carry (models this client both having an outstanding throw AND a live carry from a different ball at once)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachAndDeleteCalls, 1, 'the carried entity is torn down via DetachAndDeleteProp')
    t.equals(#f.deleteEntityCalls, 1, 'the separately-tracked thrown ball is torn down via a direct DeleteEntity')
    t.isFalse(f.env.IsFetchCarryEngaged())
end)

t.test('onResourceStop: no-op when nothing is tracked at all', function()
    local f = newFetchFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachAndDeleteCalls, 0)
    t.equals(#f.deleteEntityCalls, 0)
end)

-- ========================================================================
-- FIXED: STALE-CARRY GUARD on carryFetchBall's 'attach' branch. See this
-- file's own header for the full writeup.
-- ========================================================================

t.test('FIXED: a second carryFetchBall("attach") dispatch before the first carry is ever cleared now tears down the FIRST attached entity instead of orphaning it', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999999, 'attach')
    t.equals(#f.detachAndDeleteCalls, 0)
    t.equals(#f.detachEntityCalls, 0, 'the first attached entity is still alive and untouched after only one dispatch')

    -- A second dispatch lands before endFetchCarry/removeFetchBall ever
    -- clears the first carry -- e.g. a duplicated/retried server event.
    f.dispatchNetEvent('qbx_k9unit:client:carryFetchBall', 65535, 999998, 'attach')

    t.equals(#f.attachPropCalls, 2, 'a second, independent attach happens')
    t.equals(#f.detachAndDeleteCalls, 1, 'FIXED: the STALE-CARRY GUARD tears down the first attached entity before the second attach is even created')
    t.equals(#f.detachEntityCalls, 0, 'teardown goes through DetachAndDeleteProp, never a bare DetachEntity, for the stale entity')

    -- The SECOND (now-current) carry is still tracked correctly:
    -- onResourceStop cleans it up too, and never double-tears-down the
    -- already-cleaned-up first one.
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachAndDeleteCalls, 2, 'onResourceStop cleans up the second, now-current attach on top of the guard\'s own first-attach cleanup -- no orphan left behind either way')
end)

os.exit(t.summary())
