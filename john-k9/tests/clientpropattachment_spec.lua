--[[
    tests/clientpropattachment_spec.lua

    Direct, black-box tests of client/propattachment.lua against the REAL,
    unmodified production file -- the client half of
    Config.Features.PropAttachments AND the shared, generic
    AttachPropToOwnPed()/DetachAndDeleteProp() mechanic this file exposes
    for client/fetch.lua and client/bonetool.lua to reuse (see that pair's
    own FILE-TO-FILE CONTRACT header block). One of six client files this
    pass writes a spec for (see tests/vehiclecombatguard_spec.lua's own
    header, whose disclosed gap this batch exists to close).

    TWO-TIER GATING, DELIBERATE, NOT A BUG (unlike this pass's disclosed
    findings in tests/clientkennel_spec.lua/tests/clientfetch_spec.lua):
    `AttachPropToOwnPed`/`DetachAndDeleteProp`/`IsPropAttachmentEngaged`/
    `RequestToggleK9PropAttachment` are declared UNCONDITIONALLY (outside
    any `Config.Features.PropAttachments` check) because
    client/bonetool.lua calls the first two regardless of THIS flag, gated
    instead on its own `BoneSweepDevTool` flag -- see this file's own
    header "Neither function is gated on Config.Features.PropAttachments".
    The REGISTRATION-TIME gate (`if Config.Features.PropAttachments then
    ... end`, wrapping the command, all three RegisterNetEvent handlers,
    the own-death poll thread and the onResourceStop hook) is what makes
    THOSE five things genuinely absent with the flag off. Both halves are
    tested explicitly below -- this is the ONE file of the six in this
    batch that gets this split right on both axes.

    NET-EVENT DISPATCH RUNS INSIDE A FRESH COROUTINE where a handler can
    yield (`attachK9Prop`, via `AttachPropToOwnPed`'s own `Wait(50)` poll
    loop) -- same `dispatchNetEvent` convention as
    tests/clientkennel_spec.lua/tests/clientfetch_spec.lua.

    THE ONE PERSISTENT CreateThread (own-death poll) uses
    `Sandbox.newThreadRunner()` -- a plain `while true do Wait(1000) ...
    end` loop with `Wait` as its own first statement, exactly the shape
    that helper's own doc comment describes.

    NO STALE-STATE ORPHAN BUG HERE, PROVEN, NOT ASSUMED: unlike
    client/kennel.lua's `deployKennelAt` and client/fetch.lua's
    `carryFetchBall` (both disclosed findings in this pass's sibling
    specs), `attachK9Prop`'s own STALE-VEST GUARD correctly detaches and
    deletes any PRE-EXISTING `myVestEntity` before creating a new one. The
    dedicated test below proves a double dispatch here is safe where the
    other two files' equivalent double dispatch is not.
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
local PRIMARY_MODEL = 'prop_bodyarmour_02'
local FALLBACK_MODEL = 'prop_tennis_ball'

--- @param opts { propAttachments: boolean? }?
--- @return table fixture
local function newPropAttachmentFixture(opts)
    opts = opts or {}

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
    local pedCoords = { x = 0.0, y = 0.0, z = 0.0 }
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return entity == pedHandle and pedDead or false end
    local function GetEntityModel(entity) return entityModels[entity] end
    local function GetEntityCoords(_entity) return pedCoords end

    local objectSeq = 0
    local objectBehavior = {}
    local createObjectCalls, deleteEntityCalls, attachEntityCalls, detachEntityCalls = {}, {}, {}, {}
    local function CreateObject(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag)
        objectSeq = objectSeq + 1
        local entity = objectSeq
        createObjectCalls[#createObjectCalls + 1] = { entity = entity, modelHash = modelHash, isNetwork = isNetwork }
        if objectBehavior.createFails then return 0 end
        existingEntities[entity] = true
        entityModels[entity] = modelHash
        return entity
    end
    local function DeleteEntity(entity)
        deleteEntityCalls[#deleteEntityCalls + 1] = entity
        existingEntities[entity] = nil
    end
    local function AttachEntityToEntity(entity, attachTo, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, p9, p10, p11, p12, p13, p14)
        attachEntityCalls[#attachEntityCalls + 1] = {
            entity = entity, attachTo = attachTo, boneIndex = boneIndex,
            offsetX = offsetX, offsetY = offsetY, offsetZ = offsetZ,
        }
    end
    local function DetachEntity(entity, ...) detachEntityCalls[#detachEntityCalls + 1] = entity end

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
    -- ResolveNetworkEntity -- same convention as this batch's sibling specs.
    local function ResolveNetworkEntity(netId)
        for entity, id in pairs(netIdByEntity) do
            if id == netId and existingEntities[entity] then return entity end
        end
        return nil
    end

    local config = {
        Features = { PropAttachments = opts.propAttachments ~= false },
        PropAttachments = {
            propModel = PRIMARY_MODEL,
            fallbackPropModel = FALLBACK_MODEL,
            boneIndex = 0,
            offsetX = 0.1, offsetY = 0.2, offsetZ = 0.3,
            rotX = 0.0, rotY = 0.0, rotZ = 0.0,
        },
    }

    local env = Sandbox.newEnv({
        Config = config,
        GetHashKey = GetHashKey,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CountingCreateThread,
        Wait = threadRunner.Wait,
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
        AttachEntityToEntity = AttachEntityToEntity,
        DetachEntity = DetachEntity,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        ResolveNetworkEntity = ResolveNetworkEntity,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    })

    Sandbox.loadInto('../client/propattachment.lua', env)

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
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        step = threadRunner.step,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyCallCount = function() return denyCalls end,
        setModelBehavior = function(modelName, behavior) modelBehavior[GetHashKey(modelName)] = behavior end,
        setObjectBehavior = function(t2) objectBehavior = t2 or {} end,
        requestModelCalls = requestModelCalls,
        releaseModelCalls = releaseModelCalls,
        createObjectCalls = createObjectCalls,
        deleteEntityCalls = deleteEntityCalls,
        attachEntityCalls = attachEntityCalls,
        detachEntityCalls = detachEntityCalls,
        setPedDead = function(v) pedDead = v end,
        registerForeignEntity = function(netId, entity, modelHash)
            existingEntities[entity] = true
            entityModels[entity] = modelHash
            netIdByEntity[entity] = netId
        end,
        --- Runs ANY function (not just a captured net-event handler) to
        --- completion inside its own fresh coroutine, returning whatever it
        --- returns -- needed for direct AttachPropToOwnPed() calls whose own
        --- internal Wait(50) poll loop can genuinely yield (a stuck model
        --- load), unlike this suite's other `runXInCoroutine`-style helpers,
        --- which only ever wrap a captured event handler.
        callInCoroutine = function(fn, ...)
            local co = coroutine.create(fn)
            local results = { coroutine.resume(co, ...) }
            local ok = table.remove(results, 1)
            if not ok then error('callInCoroutine: ' .. tostring(results[1])) end
            while coroutine.status(co) ~= 'dead' do
                results = { coroutine.resume(co) }
                ok = table.remove(results, 1)
                if not ok then error('callInCoroutine mid-flight: ' .. tostring(results[1])) end
            end
            return table.unpack(results)
        end,
        --- Runs a captured RegisterNetEvent handler to completion inside its
        --- own fresh coroutine -- same convention as this batch's sibling
        --- specs.
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
-- TWO-TIER GATING -- see this file's own header. The generic mechanic
-- (AttachPropToOwnPed/DetachAndDeleteProp/IsPropAttachmentEngaged/
-- RequestToggleK9PropAttachment) stays defined regardless of the flag;
-- the REGISTRATION-TIME block is what goes genuinely inert.
-- ========================================================================

t.test('feature off: the four generic-mechanic globals stay defined (client/bonetool.lua depends on the first two regardless of THIS flag)', function()
    local f = newPropAttachmentFixture({ propAttachments = false })
    t.isNotNil(f.env.AttachPropToOwnPed)
    t.isNotNil(f.env.DetachAndDeleteProp)
    t.isNotNil(f.env.IsPropAttachmentEngaged)
    t.isNotNil(f.env.RequestToggleK9PropAttachment)
end)

t.test('feature off: the REGISTRATION-TIME block is genuinely inert -- no command, no net events, no thread, no onResourceStop handler', function()
    local f = newPropAttachmentFixture({ propAttachments = false })
    t.equals(#f.commands, 0)
    t.equals(f.netEventCount(), 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

t.test('feature off: RequestToggleK9PropAttachment() itself (still defined) correctly no-ops', function()
    local f = newPropAttachmentFixture({ propAttachments = false })
    f.env.RequestToggleK9PropAttachment()
    t.equals(#f.serverEvents, 0)
end)

t.test('feature off: IsPropAttachmentEngaged() reads false -- a vest can never be tracked with no way to create one', function()
    local f = newPropAttachmentFixture({ propAttachments = false })
    t.isFalse(f.env.IsPropAttachmentEngaged())
end)

-- ========================================================================
-- AttachPropToOwnPed / DetachAndDeleteProp -- this file's OWN generic
-- mechanic (not a cross-file dependency to stub -- this is the real logic
-- under test).
-- ========================================================================

t.test('AttachPropToOwnPed: an empty or non-string modelName is rejected before ever touching a native', function()
    local f = newPropAttachmentFixture()
    t.isNil(f.env.AttachPropToOwnPed('', 0, 0, 0, 0, 0, 0, 0, true))
    t.isNil(f.env.AttachPropToOwnPed(nil, 0, 0, 0, 0, 0, 0, 0, true))
    t.equals(#f.requestModelCalls, 0)
end)

t.test('AttachPropToOwnPed: an invalid model hash never calls RequestModel at all', function()
    local f = newPropAttachmentFixture()
    f.setModelBehavior('bogus_model', 'invalid')
    t.isNil(f.env.AttachPropToOwnPed('bogus_model', 0, 0, 0, 0, 0, 0, 0, true))
    t.equals(#f.requestModelCalls, 0)
end)

t.test('AttachPropToOwnPed: a model that never loads releases its streaming reference (LEAK FIX) and returns nil', function()
    local f = newPropAttachmentFixture()
    f.setModelBehavior('stuck_model', 'timeout')
    local entity = f.callInCoroutine(f.env.AttachPropToOwnPed, 'stuck_model', 0, 0, 0, 0, 0, 0, 0, true, 200)
    t.isNil(entity)
    t.equals(#f.requestModelCalls, 1)
    t.isTrue(#f.releaseModelCalls >= 1, 'a timed-out request must release its streaming reference, not leak it')
    t.equals(#f.createObjectCalls, 0)
end)

t.test('AttachPropToOwnPed: CreateObject failing (DoesEntityExist false) returns nil', function()
    local f = newPropAttachmentFixture()
    f.setObjectBehavior({ createFails = true })
    t.isNil(f.env.AttachPropToOwnPed('anything', 0, 0, 0, 0, 0, 0, 0, true))
end)

t.test('AttachPropToOwnPed: happy path -- creates the object at the caller\'s own current ped position, attaches it at the given bone/offset, honors isNetworked, returns the entity', function()
    local f = newPropAttachmentFixture()
    local entity = f.env.AttachPropToOwnPed('some_prop', 5, 0.1, 0.2, 0.3, 0.0, 0.0, 0.0, true)
    t.isNotNil(entity)
    t.equals(#f.createObjectCalls, 1)
    t.equals(f.createObjectCalls[1].isNetwork, true)
    t.equals(#f.attachEntityCalls, 1)
    t.equals(f.attachEntityCalls[1].entity, entity)
    t.equals(f.attachEntityCalls[1].attachTo, 1, 'must attach to the caller\'s OWN PlayerPedId()')
    t.equals(f.attachEntityCalls[1].boneIndex, 5)
    t.equals(f.attachEntityCalls[1].offsetY, 0.2)
end)

t.test('AttachPropToOwnPed: isNetworked=false (a purely local visual aid, e.g. client/bonetool.lua\'s marker) passes isNetwork=false to CreateObject', function()
    local f = newPropAttachmentFixture()
    f.env.AttachPropToOwnPed('marker_prop', 0, 0, 0, 0, 0, 0, 0, false)
    t.equals(f.createObjectCalls[1].isNetwork, false)
end)

t.test('DetachAndDeleteProp: nil or a non-existent entity is a harmless no-op', function()
    local f = newPropAttachmentFixture()
    f.env.DetachAndDeleteProp(nil)
    f.env.DetachAndDeleteProp(999999)
    t.equals(#f.detachEntityCalls, 0)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('DetachAndDeleteProp: an existing entity is detached THEN deleted', function()
    local f = newPropAttachmentFixture()
    local entity = f.env.AttachPropToOwnPed('some_prop', 0, 0, 0, 0, 0, 0, 0, true)
    f.env.DetachAndDeleteProp(entity)
    t.equals(#f.detachEntityCalls, 1)
    t.equals(#f.deleteEntityCalls, 1)
end)

-- ========================================================================
-- Sanity + happy path (feature-gated command/handlers)
-- ========================================================================

t.test('feature on: registers exactly 1 command, 3 net events, 1 thread, 1 onResourceStop handler', function()
    local f = newPropAttachmentFixture()
    t.equals(#f.commands, 1)
    t.equals(f.commands[1].name, 'k9propattach')
    t.equals(f.netEventCount(), 3)
    t.isNotNil(f.netEventNames['john-k9:client:attachK9Prop'])
    t.isNotNil(f.netEventNames['john-k9:client:rejectK9PropAttach'])
    t.isNotNil(f.netEventNames['john-k9:client:removeK9PropAttachment'])
    t.equals(f.threadCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('RequestToggleK9PropAttachment: CanShowK9UI false denies locally, no server contact', function()
    local f = newPropAttachmentFixture()
    f.setCanShowK9UI(false)
    f.env.RequestToggleK9PropAttachment()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestToggleK9PropAttachment: happy path sends the real requestToggleK9PropAttachment event', function()
    local f = newPropAttachmentFixture()
    f.env.RequestToggleK9PropAttachment()
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:requestToggleK9PropAttachment')
end)

t.test('the k9propattach command genuinely calls RequestToggleK9PropAttachment(), not a dead registration', function()
    local f = newPropAttachmentFixture()
    f.commands[1].handler()
    t.equals(#f.serverEvents, 1)
end)

t.test('attachK9Prop: happy path -- primary model loads, object created, attached, netId reported, IsPropAttachmentEngaged() becomes true', function()
    local f = newPropAttachmentFixture()
    t.isFalse(f.env.IsPropAttachmentEngaged())
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    t.equals(#f.createObjectCalls, 1)
    t.equals(f.createObjectCalls[1].modelHash, GetHashKey(PRIMARY_MODEL))
    t.equals(#f.attachEntityCalls, 1)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'john-k9:server:confirmPropAttached')
    t.isTrue(f.env.IsPropAttachmentEngaged())
end)

t.test('attachK9Prop: source guard rejects a forged local trigger', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 1)
    t.equals(#f.createObjectCalls, 0)
end)

t.test('attachK9Prop: primary model fails -- falls back to fallbackPropModel', function()
    local f = newPropAttachmentFixture()
    f.setModelBehavior(PRIMARY_MODEL, 'invalid')
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    t.equals(#f.createObjectCalls, 1)
    t.equals(f.createObjectCalls[1].modelHash, GetHashKey(FALLBACK_MODEL))
    t.isTrue(f.env.IsPropAttachmentEngaged())
end)

t.test('attachK9Prop: BOTH primary and fallback fail -- notifies, cancels the request, never engages', function()
    local f = newPropAttachmentFixture()
    f.setModelBehavior(PRIMARY_MODEL, 'invalid')
    f.setModelBehavior(FALLBACK_MODEL, 'invalid')
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    t.isFalse(f.env.IsPropAttachmentEngaged())
    t.equals(f.lastNotify().description, locale('propattachment.vest_prop_load_failed'))
    t.equals(f.lastServerEvent().event, 'john-k9:server:cancelPropAttachRequest')
end)

t.test('DOUBLE-FIRE SAFETY (contrast with tests/clientkennel_spec.lua/tests/clientfetch_spec.lua\'s disclosed findings): a second attachK9Prop dispatch BEFORE the first vest is ever removed correctly detaches+deletes the FIRST vest before creating the second -- no orphan', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    local firstEntity = f.createObjectCalls[1].entity
    t.equals(#f.deleteEntityCalls, 0)

    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535) -- e.g. a retried request after the first attempt visibly did nothing
    t.equals(#f.createObjectCalls, 2, 'a second vest object is created')
    t.equals(#f.detachEntityCalls, 1, 'THE FIX (unlike kennel.lua/fetch.lua): the FIRST vest is detached before the second is created')
    t.isTrue((function()
        for _, e in ipairs(f.deleteEntityCalls) do if e == firstEntity then return true end end
        return false
    end)(), 'the first vest entity must actually be the one deleted, not left dangling')
    t.equals(#f.deleteEntityCalls, 1, 'exactly one delete -- the stale first vest, never the live second one')
end)

t.test('rejectK9PropAttach: source guard, feature gate, and the happy path (detaches+deletes the just-created vest, clears tracking)', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    t.isTrue(f.env.IsPropAttachmentEngaged())

    f.dispatchNetEvent('john-k9:client:rejectK9PropAttach', 1) -- forged
    t.isTrue(f.env.IsPropAttachmentEngaged(), 'a forged local trigger must never undo a real attachment')

    f.dispatchNetEvent('john-k9:client:rejectK9PropAttach', 65535)
    t.isFalse(f.env.IsPropAttachmentEngaged())
    t.equals(#f.deleteEntityCalls, 1)
end)

t.test('rejectK9PropAttach: a clean no-op when nothing was ever attached (DetachAndDeleteProp(nil) tolerates it)', function()
    local f = newPropAttachmentFixture()
    local ok = pcall(f.dispatchNetEvent, 'john-k9:client:rejectK9PropAttach', 65535)
    t.isTrue(ok)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeK9PropAttachment (cleanup backstop): source guard, non-number netId, and an unresolvable netId are all safe no-ops', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    local netId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('john-k9:client:removeK9PropAttachment', 1, netId)
    t.equals(#f.deleteEntityCalls, 0)

    f.dispatchNetEvent('john-k9:client:removeK9PropAttachment', 65535, 'not-a-number')
    t.equals(#f.deleteEntityCalls, 0)

    f.dispatchNetEvent('john-k9:client:removeK9PropAttachment', 65535, 999999)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeK9PropAttachment: DEFENSE-IN-DEPTH MODEL CHECK -- a resolvable netId whose model is not a configured prop is rejected', function()
    local f = newPropAttachmentFixture()
    f.registerForeignEntity(777, 40, GetHashKey('prop_random_other_thing'))
    f.dispatchNetEvent('john-k9:client:removeK9PropAttachment', 65535, 777)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('removeK9PropAttachment: happy path -- deletes the real vest and clears tracking', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    local netId = f.lastServerEvent().args[1]

    f.dispatchNetEvent('john-k9:client:removeK9PropAttachment', 65535, netId)
    t.equals(#f.deleteEntityCalls, 1)
    t.isFalse(f.env.IsPropAttachmentEngaged())

    -- Proves tracking was really cleared: onResourceStop afterward finds
    -- nothing left to clean up a second time.
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1)
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- the highest-priority area per this task's own
-- brief.
-- ========================================================================

t.test('OWN-DEATH poll: idle (no vest attached) never fires reportOwnK9PropAttachDeath even if the ped is dead', function()
    local f = newPropAttachmentFixture()
    f.setPedDead(true)
    f.step() -- prime
    f.step() -- one idle pass
    t.equals(#f.serverEvents, 0)
end)

t.test('OWN-DEATH poll: a dead ped while wearing a vest detaches+deletes it, clears tracking, and reports the death', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    f.setPedDead(true)

    f.step() -- prime -- reaches Wait(1000)
    f.step() -- performs the death check
    t.equals(#f.detachEntityCalls, 1)
    t.equals(#f.deleteEntityCalls, 1)
    t.isFalse(f.env.IsPropAttachmentEngaged())
    -- 2, not 1: attachK9Prop's own dispatch above already sent
    -- confirmPropAttached -- the death thread adds a second, distinct event.
    t.equals(#f.serverEvents, 2)
    t.equals(f.lastServerEvent().event, 'john-k9:server:reportOwnK9PropAttachDeath')
end)

t.test('onResourceStop: no-op when nothing was ever attached', function()
    local f = newPropAttachmentFixture()
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 0)
end)

t.test('onResourceStop: deletes a still-attached vest on a resource restart, and is idempotent on a second firing', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1)
    t.isFalse(f.env.IsPropAttachmentEngaged())

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteEntityCalls, 1, 'a second firing must not attempt a second delete')
end)

t.test('onResourceStop: a mismatched resourceName never fires, even with a live vest attached', function()
    local f = newPropAttachmentFixture()
    f.dispatchNetEvent('john-k9:client:attachK9Prop', 65535)
    f.fireResourceStop('some_other_resource')
    t.equals(#f.deleteEntityCalls, 0)
    t.isTrue(f.env.IsPropAttachmentEngaged())
end)

-- ========================================================================
-- ANY PED -- this file's header USED TO CLAIM it calls IsOwnModelK9()
-- ("THIS FILE calls client/main.lua's CanShowK9UI()/DenyK9UIAccess() and
-- IsOwnModelK9()"), but reading the actual code showed neither
-- RequestToggleK9PropAttachment nor the attachK9Prop handler ever called it
-- -- a small, disclosed documentation staleness (the same bug CLASS
-- server/partnership.lua's own header flags twice for itself: "this
-- project has twice shipped a header describing a control that did not
-- actually exist"), not a functional defect. FIXED 2026-08-26: the header
-- comment now says CanShowK9UI() alone, matching the real code -- no
-- behavior change. Proven below by OMITTING IsOwnModelK9 from the sandbox
-- entirely: if a regression ever added an IsOwnModelK9() call, this test
-- would fail loudly with "attempt to call a nil value" instead of silently
-- passing.
-- ========================================================================

t.test('ANY PED: RequestToggleK9PropAttachment works via CanShowK9UI() alone, with IsOwnModelK9 entirely undefined (the file\'s header now correctly documents this -- see this file\'s "documentation staleness" note above for the FIXED claim)', function()
    local f = newPropAttachmentFixture()
    t.isNil(f.env.IsOwnModelK9, 'sanity: this fixture genuinely never defines IsOwnModelK9')
    local ok, err = pcall(f.env.RequestToggleK9PropAttachment)
    t.isTrue(ok, 'must not reach for a global the real code path does not call: ' .. tostring(err))
    t.equals(#f.serverEvents, 1)
end)

-- ========================================================================
-- DOUBLE-FIRE / RE-ENTRANCY
-- ========================================================================

t.test('RequestToggleK9PropAttachment: two rapid calls both reach the server -- no client-side "already toggling" guard, by design (the server decides add-vs-remove from its own PropAttachmentState, per this file\'s own comment)', function()
    local f = newPropAttachmentFixture()
    f.env.RequestToggleK9PropAttachment()
    f.env.RequestToggleK9PropAttachment()
    t.equals(#f.serverEvents, 2)
end)

os.exit(t.summary())
