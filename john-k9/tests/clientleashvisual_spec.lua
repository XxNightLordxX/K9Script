--[[
    tests/clientleashvisual_spec.lua

    Direct, black-box tests of client/leashvisual.lua against the REAL,
    unmodified production file -- see that file's own header for the full
    design writeup (bystander visibility via an entity-scoped statebag,
    native verification, and the per-termination-path cleanup mapping).
    Mirrors tests/clientpropattachment_spec.lua's fixture conventions
    closely (same sandbox shape, same dispatchNetEvent-runs-in-a-coroutine
    convention, since EnsureRopeTexturesLoaded's own bounded poll can
    genuinely yield, exactly like that file's AttachPropToOwnPed).

    FIXTURE MODELS A SMALL "WORLD" OF PLAYERS: `registerPlayer(serverId,
    playerIndex)` creates a fake connected player with its own ped entity,
    resolvable via GetPlayerFromServerId/GetPlayerPed/
    NetworkGetPlayerIndexFromPed exactly like the real natives. Player index
    1 (server id 1) is always THIS client's own ("myPed" / PlayerPedId()) --
    every other registered player is a distinct entity this client can only
    ever observe, exactly the bystander/participant distinction this file's
    own design is built around.

    STATEBAG MOCK: `Entity(entity).state:set(key, value, replicate)`
    synchronously fires every handler registered via
    AddStateBagChangeHandler whose keyFilter matches -- a faithful enough
    simulation of real state-bag replication for testing THIS file's own
    consumer logic (which is what every test below actually exercises),
    regardless of which client's Entity(...) call originated it -- exactly
    mirroring how a bystander's OWN AddStateBagChangeHandler really does
    fire for a change some OTHER client made.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

local RESOURCE_NAME = 'john-k9'
local LEASH_VISUAL_STATE_KEY = 'john-k9:leashVisual'

--- @param opts table?
--- @return table fixture
local function newLeashVisualFixture(opts)
    opts = opts or {}

    -- ---- notify / print ----
    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }

    local capturedPrints = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
    end

    -- ---- event plumbing ----
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

    -- ---- fake "world" of players/peds ----
    local existingEntities = {}
    local deadEntities = {}
    local entityCoords = {}
    local pedByPlayer = {}
    local playerByServerId = {}
    local serverIdByPlayer = {}
    local playerIndexByPed = {}
    local nextPed = 1

    --- @param serverId number
    --- @param playerIndex number
    --- @return number ped
    local function registerPlayer(serverId, playerIndex)
        local ped = nextPed
        nextPed = nextPed + 1
        existingEntities[ped] = true
        entityCoords[ped] = { x = 0.0, y = 0.0, z = 0.0 }
        pedByPlayer[playerIndex] = ped
        playerByServerId[serverId] = playerIndex
        serverIdByPlayer[playerIndex] = serverId
        playerIndexByPed[ped] = playerIndex
        return ped
    end

    --- @param playerIndex number
    local function unregisterPlayer(playerIndex)
        local ped = pedByPlayer[playerIndex]
        if ped then
            existingEntities[ped] = nil
            playerIndexByPed[ped] = nil
        end
        local serverId = serverIdByPlayer[playerIndex]
        if serverId then playerByServerId[serverId] = nil end
        pedByPlayer[playerIndex] = nil
        serverIdByPlayer[playerIndex] = nil
    end

    local myPed = registerPlayer(1, 1) -- THIS client's own player -- server id 1, player index 1
    local function PlayerPedId() return myPed end

    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return deadEntities[entity] == true end
    local function GetEntityCoords(entity) return entityCoords[entity] or { x = 0.0, y = 0.0, z = 0.0 } end

    local function GetPlayerFromServerId(serverId)
        local p = playerByServerId[serverId]
        if p == nil then return -1 end
        return p
    end
    local function GetPlayerServerId(playerIndex) return serverIdByPlayer[playerIndex] end
    local function GetPlayerPed(playerIndex) return pedByPlayer[playerIndex] or 0 end
    local function NetworkGetPlayerIndexFromPed(ped)
        local p = playerIndexByPed[ped]
        if p == nil then return -1 end
        return p
    end

    -- ---- rope natives ----
    local ropeTexturesLoaded = opts.ropeTexturesLoadedInitially ~= false -- default: already loaded, no poll needed
    local ropeLoadTexturesCalls = 0
    local function RopeAreTexturesLoaded() return ropeTexturesLoaded end
    local function RopeLoadTextures()
        ropeLoadTexturesCalls = ropeLoadTexturesCalls + 1
        if opts.textureLoadSucceedsAfterRequest then ropeTexturesLoaded = true end
    end

    local ropeIdSeq = 0
    local existingRopes = {}
    local addRopeCalls = {}
    local deleteRopeCalls = {}
    local attachEntitiesToRopeCalls = {}
    local function AddRope(...)
        local args = { ... }
        addRopeCalls[#addRopeCalls + 1] = args
        if opts.addRopeFails then return 0 end
        ropeIdSeq = ropeIdSeq + 1
        existingRopes[ropeIdSeq] = true
        return ropeIdSeq
    end
    local function DoesRopeExist(ropeId) return existingRopes[ropeId] == true end
    local function DeleteRope(ropeId)
        deleteRopeCalls[#deleteRopeCalls + 1] = ropeId
        existingRopes[ropeId] = nil
    end
    local function AttachEntitiesToRope(...)
        attachEntitiesToRopeCalls[#attachEntitiesToRopeCalls + 1] = { ... }
    end

    local boneQueryCalls = {}
    local function GetWorldPositionOfEntityBone(entity, boneIndex)
        boneQueryCalls[#boneQueryCalls + 1] = { entity = entity, boneIndex = boneIndex }
        return { x = 10.0, y = 20.0, z = 30.0 }
    end
    local function GetOffsetFromEntityGivenWorldCoords(entity, x, y, z)
        return { x = x, y = y, z = z } -- identity stub -- sufficient to prove the value flows end to end
    end

    -- ---- statebag mock ----
    local stateBagHandlers = {}
    local function AddStateBagChangeHandler(keyFilter, _bagFilter, handler)
        stateBagHandlers[#stateBagHandlers + 1] = { keyFilter = keyFilter, handler = handler }
        return #stateBagHandlers
    end
    local function GetEntityFromStateBagName(bagName)
        local entity = tonumber((bagName or ''):match('^entity:(%d+)$'))
        return entity or 0
    end
    local stateSetCalls = {}
    local function Entity(entity)
        return {
            state = {
                set = function(_self, key, value, replicate)
                    stateSetCalls[#stateSetCalls + 1] = { entity = entity, key = key, value = value, replicate = replicate }
                    local bagName = 'entity:' .. tostring(entity)
                    for _, h in ipairs(stateBagHandlers) do
                        if h.keyFilter == nil or h.keyFilter == key then
                            h.handler(bagName, key, value, 0, replicate == true)
                        end
                    end
                end,
            },
        }
    end

    -- ---- prop attach mock (client/propattachment.lua's shared helper) ----
    local attachPropCalls = {}
    local detachPropCalls = {}
    local propObjSeq = 1000
    local function AttachPropToOwnPed(modelName, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, isNetworked, timeoutMs)
        attachPropCalls[#attachPropCalls + 1] = { modelName = modelName, boneIndex = boneIndex, isNetworked = isNetworked }
        if opts.propModelBehavior and opts.propModelBehavior[modelName] == 'fail' then
            return nil
        end
        propObjSeq = propObjSeq + 1
        existingEntities[propObjSeq] = true
        return propObjSeq
    end
    local function DetachAndDeleteProp(entity)
        detachPropCalls[#detachPropCalls + 1] = entity
        if entity then existingEntities[entity] = nil end
    end

    local config = {
        Features = {},
        LeashMaxDistance = opts.leashMaxDistance,
        LeashVisual = opts.leashVisual, -- nil unless a test supplies one -- exercises the "Config.LeashVisual missing" defensive path by default
    }

    local env = Sandbox.newEnv({
        Config = config,
        lib = lib,
        print = printStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CountingCreateThread,
        Wait = threadRunner.Wait,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        GetEntityCoords = GetEntityCoords,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerServerId = GetPlayerServerId,
        GetPlayerPed = GetPlayerPed,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        RopeAreTexturesLoaded = RopeAreTexturesLoaded,
        RopeLoadTextures = RopeLoadTextures,
        AddRope = AddRope,
        DoesRopeExist = DoesRopeExist,
        DeleteRope = DeleteRope,
        AttachEntitiesToRope = AttachEntitiesToRope,
        GetWorldPositionOfEntityBone = GetWorldPositionOfEntityBone,
        GetOffsetFromEntityGivenWorldCoords = GetOffsetFromEntityGivenWorldCoords,
        AddStateBagChangeHandler = AddStateBagChangeHandler,
        GetEntityFromStateBagName = GetEntityFromStateBagName,
        Entity = Entity,
        AttachPropToOwnPed = AttachPropToOwnPed,
        DetachAndDeleteProp = DetachAndDeleteProp,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
    })

    Sandbox.loadInto('../client/leashvisual.lua', env)

    return {
        env = env,
        myPed = myPed,
        registerPlayer = registerPlayer,
        unregisterPlayer = unregisterPlayer,
        setDead = function(entity, v) deadEntities[entity] = v end,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        capturedPrints = capturedPrints,
        netEventNames = netEvents,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEvents) do n = n + 1 end
            return n
        end,
        threadCount = function() return threadCreateCount end,
        stateBagHandlerCount = function() return #stateBagHandlers end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do handler(resourceName) end
        end,
        step = threadRunner.step,
        ropeLoadTexturesCallCount = function() return ropeLoadTexturesCalls end,
        addRopeCalls = addRopeCalls,
        deleteRopeCalls = deleteRopeCalls,
        attachEntitiesToRopeCalls = attachEntitiesToRopeCalls,
        boneQueryCalls = boneQueryCalls,
        stateSetCalls = stateSetCalls,
        lastStateSet = function() return stateSetCalls[#stateSetCalls] end,
        attachPropCalls = attachPropCalls,
        detachPropCalls = detachPropCalls,
        --- Directly simulates an EXTERNAL client (some other K9's own
        --- leashvisual.lua instance) writing the statebag on `k9Ped` --
        --- fires every locally-registered handler, exactly like real
        --- statebag replication would for this client. Runs inside its own
        --- fresh coroutine, same reasoning as dispatchNetEvent below:
        --- CreateLocalRope can transitively reach
        --- EnsureRopeTexturesLoaded's own bounded Wait() poll, which
        --- cannot yield outside a coroutine.
        externalStateBagSet = function(k9Ped, value)
            local co = coroutine.create(function()
                Entity(k9Ped).state:set(LEASH_VISUAL_STATE_KEY, value, true)
            end)
            local ok, err = coroutine.resume(co)
            if not ok then error('externalStateBagSet: ' .. tostring(err)) end
            while coroutine.status(co) ~= 'dead' do
                ok, err = coroutine.resume(co)
                if not ok then error('externalStateBagSet mid-flight: ' .. tostring(err)) end
            end
        end,
        --- Runs a captured RegisterNetEvent handler to completion inside
        --- its own fresh coroutine -- same convention as
        --- tests/clientpropattachment_spec.lua's identical helper, needed
        --- because EnsureRopeTexturesLoaded's bounded poll can genuinely
        --- yield via Wait().
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
-- CONFIG SAFETY -- clamp-and-warn, never a bare assert; the zero-is-truthy
-- trap explicitly.
-- ========================================================================

t.test('Config.LeashVisual missing entirely: built-in defaults are used, one warning printed, nothing errors', function()
    local f = newLeashVisualFixture({})
    t.isTrue(#f.capturedPrints >= 1)
    t.contains(f.capturedPrints[1], 'Config.LeashVisual is missing')
    -- Still fully functional with defaults -- prove it registers normally.
    t.equals(f.netEventCount(), 2)
    t.equals(f.stateBagHandlerCount(), 1)
end)

t.test('ZERO-IS-TRUTHY TRAP: k9BoneIndex = 0 explicitly configured is honored as-is, NOT silently replaced by the fallback', function()
    local f = newLeashVisualFixture({ leashVisual = { k9BoneIndex = 0, officerBoneIndex = 5 } })
    -- No "k9BoneIndex is missing or not a non-negative integer" warning for a genuinely valid 0.
    for _, line in ipairs(f.capturedPrints) do
        t.notContains(line, 'k9BoneIndex')
    end

    local k9 = f.registerPlayer(2, 2)
    local officer = f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    -- The K9-side bone query must have used index 0 (not some nonzero fallback).
    local sawK9Query = false
    for _, call in ipairs(f.boneQueryCalls) do
        if call.entity == k9 and call.boneIndex == 0 then sawK9Query = true end
    end
    t.isTrue(sawK9Query, 'k9BoneIndex=0 must reach GetWorldPositionOfEntityBone as 0, not be replaced')

    local sawOfficerQuery = false
    for _, call in ipairs(f.boneQueryCalls) do
        if call.entity == officer and call.boneIndex == 5 then sawOfficerQuery = true end
    end
    t.isTrue(sawOfficerQuery)
end)

t.test('ZERO-IS-TRUTHY TRAP: ropeMinLengthMeters = 0.0 explicitly configured is honored, not replaced', function()
    local f = newLeashVisualFixture({ leashVisual = { ropeMinLengthMeters = 0.0, ropeMaxLengthMeters = 9.0 } })
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    t.equals(#f.addRopeCalls, 1)
    -- AddRope(x,y,z, rotX,rotY,rotZ, maxLength, ropeType, initLength, minLength, ...)
    t.equals(f.addRopeCalls[1][10], 0.0, 'minLength (10th positional arg) must be the configured 0.0, not a nonzero fallback')
end)

t.test('an invalid ropeType (out of AddRope\'s documented 0-7 range) is clamped to the fallback, warned loudly', function()
    local f = newLeashVisualFixture({ leashVisual = { ropeType = 99 } })
    local found = false
    for _, line in ipairs(f.capturedPrints) do
        if line:find('ropeType', 1, true) and line:find('0%-7') then found = true end
    end
    t.isTrue(found, 'must warn specifically about the ropeType range')

    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(f.addRopeCalls[1][8], 0, 'ropeType (8th positional arg) must fall back to the safe default 0, never the invalid 99')
end)

t.test('a non-positive ropeMaxLengthMeters falls back to a value derived from Config.LeashMaxDistance', function()
    local f = newLeashVisualFixture({ leashMaxDistance = 10.0, leashVisual = { ropeMaxLengthMeters = -1 } })
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(f.addRopeCalls[1][7], 15.0, 'maxLength (7th positional arg) must fall back to LeashMaxDistance * 1.5 = 15.0')
end)

-- ========================================================================
-- VISUAL_ENABLED = false: genuinely inert, same two-tier posture as
-- client/propattachment.lua's own REGISTRATION-TIME FEATURE GATE.
-- ========================================================================

t.test('Config.LeashVisual.enabled = false: no net events, no statebag handler, no thread, no onResourceStop handler', function()
    local f = newLeashVisualFixture({ leashVisual = { enabled = false } })
    t.equals(f.netEventCount(), 0)
    t.equals(f.stateBagHandlerCount(), 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

-- ========================================================================
-- ROPE TEXTURE LOADING -- bounded wait, give up loudly.
-- ========================================================================

t.test('rope textures already loaded: EnsureRopeTexturesLoaded succeeds without ever calling RopeLoadTextures', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)
    t.equals(f.ropeLoadTexturesCallCount(), 0)
end)

t.test('rope textures never load within the bounded timeout: gives up loudly (console print + one player notify), never creates a rope, the leash mechanic itself is unaffected', function()
    local f = newLeashVisualFixture({ ropeTexturesLoadedInitially = false, leashVisual = { ropeTextureTimeoutMs = 200 } })
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    t.equals(#f.addRopeCalls, 0, 'must never call AddRope when textures never load')
    t.equals(f.ropeLoadTexturesCallCount(), 1)

    local sawLoudPrint = false
    for _, line in ipairs(f.capturedPrints) do
        if line:find('RopeAreTexturesLoaded', 1, true) then sawLoudPrint = true end
    end
    t.isTrue(sawLoudPrint, 'must print loudly on total texture-load failure')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.lastNotify().description, locale('leashvisual.rope_textures_unavailable'))
end)

t.test('after giving up once, a second attach attempt never re-polls or re-notifies (latched failure)', function()
    local f = newLeashVisualFixture({ ropeTexturesLoadedInitially = false, leashVisual = { ropeTextureTimeoutMs = 200 } })
    local k9a = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9a, { officerServerId = 3 })
    t.equals(f.ropeLoadTexturesCallCount(), 1)
    t.equals(#f.notifyCalls, 1)

    local k9b = f.registerPlayer(4, 4)
    f.registerPlayer(5, 5)
    f.externalStateBagSet(k9b, { officerServerId = 5 })
    t.equals(f.ropeLoadTexturesCallCount(), 1, 'must not re-poll a doomed texture load a second time')
    t.equals(#f.notifyCalls, 1, 'must not notify a second time')
end)

t.test('textures load successfully mid-poll (within the timeout): the rope is created', function()
    local f = newLeashVisualFixture({ ropeTexturesLoadedInitially = false, textureLoadSucceedsAfterRequest = true, leashVisual = { ropeTextureTimeoutMs = 5000 } })
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)
    t.equals(#f.notifyCalls, 0)
end)

-- ========================================================================
-- ROPE RENDERING (bystander path) -- driven purely by the statebag, no
-- participant-side event needed at all, proving bystander visibility.
-- ========================================================================

t.test('bystander path: an external statebag set for a pairing THIS client has no part in still renders a local rope, attached at both real bone-derived offsets', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    local officer = f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    t.equals(#f.addRopeCalls, 1)
    t.equals(#f.attachEntitiesToRopeCalls, 1)
    local attach = f.attachEntitiesToRopeCalls[1]
    t.equals(attach[2], k9, 'ent1 must be the K9 ped')
    t.equals(attach[3], officer, 'ent2 must be the officer ped')
    t.equals(attach[13], nil, 'boneName1 must be nil -- no confirmed bone NAME string exists for either skeleton')
    t.equals(attach[14], nil, 'boneName2 must be nil')

    t.equals(#f.boneQueryCalls, 2, 'must derive an offset from a real bone index for BOTH ends')
end)

t.test('a second statebag fire for the SAME pairing (no value change assumed by the test, called twice) is idempotent -- never a duplicate rope', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)
end)

t.test('statebag cleared (false) deletes the locally-rendered rope', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)

    f.externalStateBagSet(k9, false)
    t.equals(#f.deleteRopeCalls, 1)
end)

t.test('a malformed statebag value (missing officerServerId, wrong type) is treated as inactive -- never errors, never creates a rope', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    local ok = pcall(f.externalStateBagSet, k9, { officerServerId = 'not-a-number' })
    t.isTrue(ok)
    t.equals(#f.addRopeCalls, 0)
end)

t.test('AddRope returning an invalid handle (DoesRopeExist false) is a safe no-op, logged, never crashes', function()
    local f = newLeashVisualFixture({ addRopeFails = true })
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.attachEntitiesToRopeCalls, 0)
    local found = false
    for _, line in ipairs(f.capturedPrints) do
        if line:find('AddRope did not return a valid rope handle', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('officer ped not resolvable yet: no rope is created, and the pairing is still remembered for reconciliation', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    -- Officer (server id 3) deliberately NOT registered yet.
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 0)

    -- Now the officer streams in -- the reconciliation pass in the monitor
    -- thread (not a second statebag fire) must pick this up.
    f.registerPlayer(3, 3)
    f.step() -- prime
    f.step() -- one monitor pass
    t.equals(#f.addRopeCalls, 1, 'reconciliation must retry and now succeed once the officer ped resolves')
end)

-- ========================================================================
-- PARTICIPANT-SIDE WRITER (K9 role) -- reacts to
-- 'john-k9:client:leashAttached'/'...leashDetached', the SAME events
-- client/movement.lua already handles independently.
-- ========================================================================

t.test('leashAttached, isConstrained=true (I am the K9): writes my OWN statebag with the partner\'s server id, which also renders MY OWN rope', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(7, 7) -- the officer partner
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 7, true)

    t.equals(#f.stateSetCalls, 1)
    t.equals(f.stateSetCalls[1].entity, f.myPed)
    t.equals(f.stateSetCalls[1].key, LEASH_VISUAL_STATE_KEY)
    t.equals(f.stateSetCalls[1].value.officerServerId, 7)
    t.equals(f.stateSetCalls[1].replicate, true)

    -- The writer's own client also renders its own rope via the exact same
    -- statebag path -- no separate code path needed.
    t.equals(#f.addRopeCalls, 1)
end)

t.test('leashAttached: source guard rejects a forged local trigger', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(7, 7)
    f.dispatchNetEvent('john-k9:client:leashAttached', 1, 7, true)
    t.equals(#f.stateSetCalls, 0)
end)

t.test('leashDetached clears a previously-written statebag (sets it to false, replicated)', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(7, 7)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 7, true)
    t.equals(#f.addRopeCalls, 1)

    f.dispatchNetEvent('john-k9:client:leashDetached', 65535, 'detached')
    t.equals(f.lastStateSet().value, false)
    t.equals(f.lastStateSet().replicate, true)
    t.equals(#f.deleteRopeCalls, 1, 'clearing my own statebag must also tear down my own just-rendered rope, via the same statebag path')
end)

t.test('leashDetached: source guard rejects a forged local trigger', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(7, 7)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 7, true)
    f.dispatchNetEvent('john-k9:client:leashDetached', 1, 'detached')
    t.equals(#f.deleteRopeCalls, 0, 'a forged detach must never clear a real, active statebag')
end)

t.test('leashDetached with nothing ever attached is a harmless no-op', function()
    local f = newLeashVisualFixture({})
    local ok = pcall(f.dispatchNetEvent, 'john-k9:client:leashDetached', 65535, 'detached')
    t.isTrue(ok)
    t.equals(#f.stateSetCalls, 0)
end)

-- ========================================================================
-- PARTICIPANT-SIDE HANDLE PROP (officer role) -- task item 3.
-- ========================================================================

t.test('leashAttached, isConstrained=false (I am the officer): attaches a handle prop to my own hand, networked so bystanders see it, never touches the statebag', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(9, 9) -- the K9 partner
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)

    t.equals(#f.stateSetCalls, 0, 'the officer side must never write the leash-visual statebag -- only the K9 side does')
    t.equals(#f.attachPropCalls, 1)
    t.equals(f.attachPropCalls[1].isNetworked, true)
end)

t.test('handle prop: primary model fails, fallback succeeds, breadcrumb printed', function()
    local f = newLeashVisualFixture({ propModelBehavior = { p_ing_dogleash01x = 'fail' } })
    f.registerPlayer(9, 9)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)
    t.equals(#f.attachPropCalls, 2)
    t.equals(f.attachPropCalls[2].modelName, 'prop_tennis_ball')
    local found = false
    for _, line in ipairs(f.capturedPrints) do
        if line:find('used handleFallbackModel', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('handle prop: both models fail -- no prop, no crash, loud console breadcrumb, the rope/mechanic are unaffected', function()
    local f = newLeashVisualFixture({ propModelBehavior = { p_ing_dogleash01x = 'fail', prop_tennis_ball = 'fail' } })
    f.registerPlayer(9, 9)
    local ok = pcall(f.dispatchNetEvent, 'john-k9:client:leashAttached', 65535, 9, false)
    t.isTrue(ok)
    local found = false
    for _, line in ipairs(f.capturedPrints) do
        if line:find('both handleModel and handleFallbackModel failed', 1, true) then found = true end
    end
    t.isTrue(found)
end)

t.test('leashDetached (officer side) detaches and clears the handle prop', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(9, 9)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)
    t.equals(#f.attachPropCalls, 1)

    f.dispatchNetEvent('john-k9:client:leashDetached', 65535, 'detached')
    t.equals(#f.detachPropCalls, 1)
end)

t.test('DOUBLE-FIRE SAFETY: a second leashAttached(isConstrained=false) before detach never orphans the first handle prop', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(9, 9)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)
    t.equals(#f.attachPropCalls, 2)
    t.equals(#f.detachPropCalls, 1, 'the first handle prop must be detached before the second is created')
end)

-- ========================================================================
-- TERMINATION AND CLEANUP -- the highest-priority area per this task's own
-- brief. Covers: own-death (both roles), rendered-rope liveness (the
-- bystander backstop), and onResourceStop.
-- ========================================================================

t.test('OWN-DEATH (K9 side): a dead own-ped clears my written statebag automatically, even with no server round trip', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(7, 7)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 7, true)
    t.equals(#f.stateSetCalls, 1)

    f.setDead(f.myPed, true)
    f.step() -- prime
    f.step() -- one monitor pass
    t.equals(f.lastStateSet().value, false, 'own-death must clear the statebag exactly like a real detach would')
end)

t.test('OWN-DEATH (officer side): a dead own-ped detaches my own handle prop automatically', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(9, 9)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)
    t.equals(#f.attachPropCalls, 1)

    f.setDead(f.myPed, true)
    f.step()
    f.step()
    t.equals(#f.detachPropCalls, 1)
end)

t.test('OWN-DEATH poll: idle (nothing attached) never touches anything, even if my own ped is dead', function()
    local f = newLeashVisualFixture({})
    f.setDead(f.myPed, true)
    f.step()
    f.step()
    t.equals(#f.stateSetCalls, 0)
    t.equals(#f.detachPropCalls, 0)
end)

t.test('RENDERED-ROPE LIVENESS (bystander backstop): the K9 side dying tears down a bystander\'s own rendered rope, with NO statebag change ever needed', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)

    f.setDead(k9, true) -- the K9 dies -- this bystander never receives any statebag update at all
    f.step()
    f.step()
    t.equals(#f.deleteRopeCalls, 1, 'the liveness backstop must independently notice and tear down the rope')
end)

t.test('RENDERED-ROPE LIVENESS: the officer side disconnecting (ped stops existing) tears down a bystander\'s rope', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)

    f.unregisterPlayer(3)
    f.step()
    f.step()
    t.equals(#f.deleteRopeCalls, 1)
end)

t.test('RENDERED-ROPE LIVENESS: an entity-out-of-scope K9 (DoesEntityExist false) is treated exactly like a death', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    f.unregisterPlayer(2)
    f.step()
    f.step()
    t.equals(#f.deleteRopeCalls, 1)
end)

t.test('a healthy, fully-resolvable pairing survives repeated monitor passes untouched', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    f.step()
    f.step()
    f.step()
    f.step()
    t.equals(#f.deleteRopeCalls, 0)
    t.equals(#f.addRopeCalls, 1, 'must not re-create an already-active rope')
end)

t.test('onResourceStop: clears my own K9-side statebag write even with no server round trip', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(7, 7)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 7, true)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(f.lastStateSet().value, false)
end)

t.test('onResourceStop: detaches my own officer-side handle prop', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(9, 9)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.detachPropCalls, 1)
end)

t.test('onResourceStop: deletes every rope THIS client is currently rendering, including a pure bystander rope with no participant-side state of its own', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })
    t.equals(#f.addRopeCalls, 1)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteRopeCalls, 1)
end)

t.test('onResourceStop: a mismatched resourceName never fires, even with a live rope and handle prop', function()
    local f = newLeashVisualFixture({})
    f.registerPlayer(9, 9)
    f.dispatchNetEvent('john-k9:client:leashAttached', 65535, 9, false)
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    f.fireResourceStop('some_other_resource')
    t.equals(#f.detachPropCalls, 0)
    t.equals(#f.deleteRopeCalls, 0)
end)

t.test('onResourceStop is idempotent: a second firing never double-deletes', function()
    local f = newLeashVisualFixture({})
    local k9 = f.registerPlayer(2, 2)
    f.registerPlayer(3, 3)
    f.externalStateBagSet(k9, { officerServerId = 3 })

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteRopeCalls, 1)
    f.fireResourceStop(RESOURCE_NAME)
    t.equals(#f.deleteRopeCalls, 1, 'a second stop firing must not attempt a second delete')
end)

os.exit(t.summary())
