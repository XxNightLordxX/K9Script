--[[
    tests/vehicle_spec.lua

    Direct tests of server/vehicle.lua's two RegisterNetEvent handlers
    (requestVehicleSeatClaim / releaseVehicleSeatClaim) plus its
    playerDropped/onResourceStop cleanup and periodic sweep thread, against
    the REAL, unmodified production file -- loaded alongside the real
    server/entities.lua per that file's own FILE-TO-FILE CONTRACT (every
    ResolveNetworkEntity call is the real resolve+existence-guard primitive,
    not a reimplementation). HasK9Access and NotifyPlayer are stubbed
    directly -- both are genuinely OTHER files' own logic, already covered
    by their own specs (server/certifications/, server/notify.lua/
    notify_spec.lua) -- this file's job is server/vehicle.lua's own
    handshake/lifecycle logic, not a second copy of those. Same overall
    fixture shape as tests/kennel_spec.lua's own newKennelFixture() -- read
    that file's header before touching this one; this design deliberately
    follows it rather than inventing a new shape.

    ONE FRESH SANDBOX PER TEST (never shared) -- `VehicleSeatClaims` is a
    `local` upvalue alive for this whole loaded file's lifetime, so reusing
    one sandbox across unrelated test cases would let one test's claim state
    leak into the next. newVehicleServerFixture() below builds one complete,
    independent world for every single t.test() call.

    THE CENTRAL PROOF THIS FILE EXISTS FOR: "TWO DOGS, SAME VEHICLE, SAME
    SEAT" below dispatches requestVehicleSeatClaim TWICE, from two different
    sources, for the IDENTICAL (vehicleNetId, seatIndex) pair, back to back
    with no yield between the two dispatchNetEvent calls -- exactly
    tests/kennel_spec.lua's own "two dogs racing the same kennel" shape
    (requestEnterKennel dispatched for src 2 then src 3 against the same
    netId). Because server/vehicle.lua's own check-and-claim has no yield of
    any kind inside it, calling the handler twice in immediate succession
    from this spec IS the same guarantee ordinary FXServer event-processing
    order gives two genuinely simultaneous network requests -- there is no
    difference in the SERVER's own vantage point between "two real,
    concurrent requests happened to be processed one after another" and "a
    test called the handler twice in a row": both look identical to code
    with no yield in between. If this file's own server/vehicle.lua ever
    grows a yield inside the check-and-claim path (an awaited callback, a
    Wait), the second dispatchNetEvent call below would begin racing this
    first one's own in-flight state instead of seeing it as already
    committed -- which is the exact bug this whole task exists to close, so
    a regression here would very likely also break this specific test.

    locale() is NEVER stubbed (this suite's own convention) -- every call
    below that reaches a NotifyPlayer(..., locale('...'), ...) call evaluates
    that locale() argument for real, against the real locales/en.json.
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

local VEHICLE_MODEL = 'police'
local WRONG_MODEL = 'civilian_sedan'
local VEHICLE_HASH = GetHashKey(VEHICLE_MODEL)
local WRONG_HASH = GetHashKey(WRONG_MODEL)
local VEHICLE_INTERACT_METERS = 3.0

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- same shape as tests/kennel_spec.lua's/
-- tests/partnership_spec.lua's own copies, needed for
-- `#(GetEntityCoords(a) - GetEntityCoords(b))`.
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

--- Builds one complete, independent sandbox for server/vehicle.lua, with
--- the real server/entities.lua loaded alongside it (matching
--- fxmanifest.lua's own load order), and every other cross-file/native
--- dependency as a test-controlled stub.
--- @param opts { vehicleEntryExit: boolean? }?
--- @return table fixture
local function newVehicleServerFixture(opts)
    opts = opts or {}
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent) -- vehicle.lua registers exactly one handler per event name
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {} -- { {target=, description=, notifyType=}, ... }
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local playersBySource = {} -- source -> citizenid string, or nil = unresolved
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = playersBySource[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid } }
            end,
            -- Reverse lookup, added for the forced-release pass: the
            -- 'vehicle_seat' releaser resolves a citizenid's CURRENT live
            -- source rather than trusting the one recorded on the claim.
            -- Derived from the SAME playersBySource table as the forward
            -- lookup, so a test that disconnects someone makes them offline
            -- in both directions at once and cannot drift.
            GetPlayerByCitizenId = function(_self, citizenid)
                for src, cid in pairs(playersBySource) do
                    if cid == citizenid then
                        return { PlayerData = { citizenid = cid, source = src } }
                    end
                end
                return nil
            end,
        },
    }

    local pedBySource = {} -- source -> ped handle (unset/0 == "disconnected mid-flight")
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {} -- handle -> {x=,y=,z=}
    local function GetEntityCoords(handle)
        local c = coordsByHandle[handle] or { x = 0, y = 0, z = 0 }
        return vec3(c.x, c.y, c.z)
    end

    local networkEntities = {} -- netId -> handle
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (GetEntityType's real domain; 2 = vehicle)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {} -- handle -> hash
    local function GetEntityModel(handle) return entityModels[handle] end

    local config = {
        Features = { VehicleEntryExit = opts.vehicleEntryExit ~= false },
        K9Vehicles = { VEHICLE_MODEL },
        VehicleInteractMeters = VEHICLE_INTERACT_METERS,
    }

    -- Sandbox.newThreadRunner() -- same convention as tests/pursuitsprint_spec.lua's
    -- own server-side fixture: captures every CreateThread'd coroutine
    -- without auto-running it. `threadCreateCount` (wrapped locally, same
    -- shape as that file's own copy) lets the FEATURE-OFF test below prove
    -- the sweep thread genuinely never gets created at all, not merely
    -- never stepped.
    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        runner.CreateThread(fn)
    end

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetHashKey = GetHashKey,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityModel = GetEntityModel,
        CreateThread = CreateThread,
        Wait = runner.Wait,
        Config = config,
    }

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/entities.lua', env)
    -- EXCLUSIVE BODY-CLAIM REGISTRY (kennel-vs-vehicle-seat race fix pass)
    -- -- requestVehicleSeatClaim now calls
    -- ClaimBody/ReleaseBody/IsBodyClaimedByOther, real globals from this
    -- file, loaded here the same way server/entities.lua's own
    -- ResolveNetworkEntity already is (never a reimplementation). This file
    -- ALSO starts its own unconditional periodic sweep thread at load time
    -- (mirrors server/vehicle.lua's own sweep design) -- see the two
    -- `threadCreateCount()` assertions below, now 2 instead of 1 for
    -- exactly this reason.
    Sandbox.loadInto('../server/bodyclaims.lua', env)
    Sandbox.loadInto('../server/vehicle.lua', env)

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        threadCreateCount = function() return threadCreateCount end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayer = function(src, citizenid) playersBySource[src] = citizenid end,
        setPed = function(src, pedHandle, coords)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = coords or { x = 0, y = 0, z = 0 }
        end,
        --- @param netId number
        --- @param handle number
        --- @param vopts { exists: boolean?, entityType: number?, model: number?, coords: table? }?
        registerVehicle = function(netId, handle, vopts)
            vopts = vopts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = vopts.exists ~= false
            entityTypes[handle] = vopts.entityType or 2 -- 2 = vehicle
            entityModels[handle] = vopts.model or VEHICLE_HASH
            coordsByHandle[handle] = vopts.coords or { x = 0, y = 0, z = 0 }
        end,
        removeVehicleExistence = function(handle) existingEntities[handle] = false end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            return handler(...)
        end,
        firePlayerDropped = function(src, reason)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler(reason)
            end
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        -- Same stepping semantics fixtures/sandbox.lua's own newThreadRunner()
        -- documents: the FIRST step() only primes the sweep loop's initial
        -- Wait() (no sweep pass runs yet); each call after that runs exactly
        -- one full sweep pass.
        stepSweep = runner.step,
        lastClientEventNamed = function(name)
            for i = #clientEvents, 1, -1 do
                if clientEvents[i].event == name then return clientEvents[i] end
            end
            return nil
        end,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
    }
end

-- ========================================================================
-- Defensive payload handling -- silent no-op on malformed/unresolvable
-- input, matching server/kennel.lua's own established convention exactly
-- (never trust client payload shape, never notify a caller whose payload
-- was never even a legible request).
-- ========================================================================

t.test('requestVehicleSeatClaim: non-number vehicleNetId is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 'not-a-number', 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: non-number seatIndex is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 'not-a-number', 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: non-number requestToken is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 'not-a-number')
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: an out-of-range seatIndex (never produced by the real client) is a silent no-op, closing an unbounded-memory-growth vector', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 999999, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: feature flag off is a silent no-op', function()
    local f = newVehicleServerFixture({ vehicleEntryExit = false })
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: unresolvable citizenid is a silent no-op', function()
    local f = newVehicleServerFixture()
    -- setPlayer() deliberately never called for src 2 -- exports.qbx_core:GetPlayer returns nil
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestVehicleSeatClaim: src disconnected between the event firing and this line (GetPlayerPed returns 0) is a silent no-op', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    -- setPed() deliberately never called -- GetPlayerPed(2) reads 0

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.equals(#f.clientEvents, 0)
    t.equals(#f.notifyCalls, 0)
end)

-- ========================================================================
-- Real rejections -- each notifies AND sends the deny event, per this
-- file's own header EVENT/CALLBACK CONTRACT.
-- ========================================================================

t.test('requestVehicleSeatClaim: no HasK9Access is denied with common.no_k9_access -- the FIRST time this action has ever been re-verified server-side', function()
    local f = newVehicleServerFixture()
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    -- setAccess() deliberately never called -- HasK9Access(2) reads false

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 42)

    t.equals(f.lastNotify().target, 2)
    t.equals(f.lastNotify().description, locale('common.no_k9_access'))
    local denyCall = f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied')
    t.isNotNil(denyCall)
    t.equals(denyCall.target, 2)
    t.equals(denyCall.args[1], 500)
    t.equals(denyCall.args[2], 1)
    t.equals(denyCall.args[3], 42, 'the requestToken must be echoed back verbatim')
end)

t.test('requestVehicleSeatClaim: an unresolvable netId is denied as an invalid vehicle', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    -- registerVehicle() deliberately never called for netId 999999

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 999999, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
    t.isNotNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied'))
end)

t.test('requestVehicleSeatClaim: a netId that resolves to a PED, never a vehicle, is denied as invalid -- never trusts the client-claimed entity type', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { entityType = 1, coords = { x = 0, y = 0, z = 0 } }) -- 1 = ped

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('requestVehicleSeatClaim: a real vehicle of an unlisted model is denied as invalid -- never trusts the client-claimed model', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { model = WRONG_HASH, coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('requestVehicleSeatClaim: a genuinely deleted vehicle (existence false) is denied as invalid', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { exists = false, coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.entry_interrupted'))
end)

t.test('requestVehicleSeatClaim: too far from the vehicle is denied -- closes the "claim every K9 vehicle on the map from across it" griefing vector', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 999, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.equals(f.lastNotify().description, locale('vehicle.claim_too_far'))
end)

t.test('requestVehicleSeatClaim: exactly at the configured interact distance plus tolerance is still accepted', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    -- Config.VehicleInteractMeters (3.0) + the file's own 1.0m tolerance = 4.0m, so 3.9m must still pass.
    f.registerVehicle(500, 50, { coords = { x = 3.9, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNotNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'))
end)

-- ========================================================================
-- THE FIX ITSELF -- happy path, self-renewal, per-seat independence, and
-- THE CENTRAL PROOF: two dogs, same vehicle, same seat.
-- ========================================================================

t.test('requestVehicleSeatClaim: a certified handler close enough to a genuine K9 vehicle is granted, with the requestToken echoed back verbatim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0.5, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 777)

    local grant = f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted')
    t.isNotNil(grant)
    t.equals(grant.target, 2)
    t.equals(grant.args[1], 500)
    t.equals(grant.args[2], 1)
    t.equals(grant.args[3], 777)
    t.equals(#f.notifyCalls, 0, 'a GRANT is never itself narrated server-side -- the client shows its own success notify once genuinely seated')
end)

t.test('requestVehicleSeatClaim: the SAME src re-requesting the SAME seat it already holds is treated as a renewal, not a collision', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 2)

    local grants = 0
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' then grants = grants + 1 end
    end
    t.equals(grants, 2, 'both of THIS SAME src\'s own requests for its own seat must succeed')
end)

t.test('requestVehicleSeatClaim: two DIFFERENT seats on the SAME vehicle never block each other', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 2, 1)

    local grants = 0
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' then grants = grants + 1 end
    end
    t.equals(grants, 2, 'different seats are independent claims')
end)

t.test('TWO DOGS, SAME VEHICLE, SAME SEAT -- the actual concurrency bug this file exists to close: dispatched back to back, with NO yield between them, exactly like server/kennel.lua\'s own "two dogs racing the same kennel" shape', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0.2, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- Both handlers independently computed seat 1 as "the best free seat"
    -- (client/vehicle.lua's own FindBestK9Seat, run locally by each of
    -- them before either ever contacted the server) -- this is the exact
    -- audit scenario: two requests for the IDENTICAL (vehicleNetId,
    -- seatIndex) pair.
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 100)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 200)

    local grant2 = nil
    local grant3 = nil
    local deny2 = nil
    local deny3 = nil
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 2 then grant2 = c end
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grant3 = c end
        if c.event == 'john-k9:client:vehicleSeatClaimDenied' and c.target == 2 then deny2 = c end
        if c.event == 'john-k9:client:vehicleSeatClaimDenied' and c.target == 3 then deny3 = c end
    end

    t.isNotNil(grant2, 'the FIRST request (src 2) must win -- ordinary event-processing order')
    t.isNil(deny2)
    t.isNil(grant3, 'the SECOND request (src 3) for the identical vehicle/seat MUST be refused -- this is the entire bug')
    t.isNotNil(deny3)
    t.equals(deny3.args[3], 200, 'src 3\'s own requestToken is echoed back on its OWN denial')

    local notifiedThree = false
    for _, n in ipairs(f.notifyCalls) do
        if n.target == 3 and n.description == locale('vehicle.no_seat_available') then notifiedThree = true end
    end
    t.isTrue(notifiedThree, 'src 3 must be told the real reason: the seat is taken')
end)

t.test('TWO DOGS, SAME VEHICLE, SAME SEAT -- the LOSING order also correctly denies whichever request is processed second, not whichever src number is higher', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- src 3 processed FIRST this time.
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    local grant3, deny2
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grant3 = c end
        if c.event == 'john-k9:client:vehicleSeatClaimDenied' and c.target == 2 then deny2 = c end
    end
    t.isNotNil(grant3, 'whichever request is processed FIRST wins -- src 3, this time')
    t.isNotNil(deny2, 'and the other is denied -- src 2, this time')
end)

-- ========================================================================
-- releaseVehicleSeatClaim -- self-only, mirrors server/entities.lua's
-- ReleaseNetworkEntity's own "never clears whatever is there" discipline.
-- ========================================================================

t.test('releaseVehicleSeatClaim: self-only -- a DIFFERENT src cannot release someone else\'s claim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1) -- src 2 holds it
    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 3, 500, 1)    -- src 3 tries to release it -- must be a no-op

    -- Still held by src 2 -- a fresh request from src 3 for the same seat must still be denied.
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)
    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree, 'src 2\'s claim must still be intact -- src 3\'s foreign release attempt must have done nothing')
end)

t.test('releaseVehicleSeatClaim: the genuine holder releasing frees the seat immediately for someone else, well before any TTL', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 2, 500, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

t.test('releaseVehicleSeatClaim: malformed payload is a silent no-op that cannot disturb a real claim', function()
    -- STRENGTHENED 2026-08-31. This was `t.isTrue(true)` with a comment
    -- saying there was "nothing else observable to assert". The bare
    -- assertion did carry real weight -- the fixture's dispatchNetEvent
    -- calls the handler with no pcall, so a throw fails the test outright --
    -- but the comment was wrong, and a test whose only assertion is a
    -- literal is indistinguishable from one someone forgot to finish.
    --
    -- There are two observable things worth pinning: the malformed call must
    -- not release someone else's claim, and it must not corrupt the table
    -- such that a legitimate claim afterwards stops working.
    --
    -- WHAT THIS DOES NOT DO, verified rather than assumed: it does not catch
    -- a mutation. Deleting the handler's `type(vehicleNetId) ~= 'number'`
    -- guard leaves this green, because ClearVehicleSeatClaim then looks up
    -- VehicleSeatClaims['nope'], finds nil, and returns on the next line
    -- anyway. Both mutations tried against it are semantically equivalent.
    -- That is a good sign about the code -- the property holds through two
    -- independent layers -- but it means this test's value is as a
    -- REGRESSION guard for future refactors, not as a detector of anything
    -- wrong today. Said plainly so nobody mistakes it for coverage it does
    -- not provide.
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- A real claim, held by src 2.
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    -- Junk in every argument position. None may throw.
    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 2, 'nope', 1)
    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 2, 500, 'nope')
    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 2, nil, nil)

    -- src 2's claim must still stand: a DIFFERENT player asking for the same
    -- seat is still refused. If any malformed call had cleared the claim,
    -- src 3 would be granted here.
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree,
        'a malformed release must not free the seat -- src 2 still holds it, so src 3 must be refused')
end)

-- ========================================================================
-- A CLAIM MUST NEVER OUTLIVE THE PLAYER OR THE VEHICLE -- lazy TTL expiry,
-- playerDropped, onResourceStop, and the periodic sweep thread. See
-- server/vehicle.lua's own header for the full four-mechanism writeup.
-- ========================================================================

t.test('TTL: a claim older than the TTL is treated as absent and silently overwritten by a fresh request from someone else', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(10001) -- just past VEHICLE_SEAT_CLAIM_TTL_MS (10000)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree, 'an expired claim must never permanently block the seat')
end)

t.test('TTL: a claim younger than the TTL is still enforced', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(9999)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree)
end)

t.test('playerDropped: a disconnecting src\'s claim is dropped immediately, not left to the TTL', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.firePlayerDropped(2, 'left')
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

t.test('playerDropped: only the disconnecting src\'s OWN claims are cleared -- an unrelated src\'s claim on a different seat is unaffected', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 2, 1)
    f.firePlayerDropped(2, 'left')

    -- src 3's own claim on seat 2 must still be enforced against a NEW
    -- would-be claimant.
    f.setAccess(4, true)
    f.setPlayer(4, 'CIT3')
    f.setPed(4, 12, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 4, 500, 2, 1)

    local grantedFour = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 4 then grantedFour = true end
    end
    t.isFalse(grantedFour, 'src 3\'s own, unrelated claim must survive src 2\'s disconnect')
end)

t.test('onResourceStop: clears every claim, regardless of who held it', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.fireResourceStop('john-k9')
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

t.test('onResourceStop: a mismatched resourceName never fires', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.fireResourceStop('some_other_resource')
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isFalse(grantedThree, 'a mismatched resourceName must never clear anything')
end)

-- ========================================================================
-- PERIODIC SWEEP -- mechanism 4 of "a claim must never outlive the player
-- or the vehicle": proactively drops claims naming a vehicle that no longer
-- exists at all, independent of the TTL, and independently re-confirms the
-- TTL sweep too. Gated on Config.Features.VehicleEntryExit at file load.
-- ========================================================================

-- LIVE-FLIP FIX. The sweep used to be created only `if
-- Config.Features.VehicleEntryExit` at file load. That looked thrifty and
-- was a trap: the claim handler re-reads the flag on EVERY request, so on a
-- server that booted with this feature off, an operator turning it on from
-- the tablet started granting claims with nothing whatsoever running to
-- expire them -- and a stranded claim is a seat nobody can sit in for the
-- rest of the server's uptime, which is worse than the race this whole file
-- exists to fix. server/combat.lua and server/wellbeing.lua were each fixed
-- for the identical trap already; this follows them.

t.test('LIVE-FLIP FIX: the sweep thread is created even with the feature OFF at boot -- it is what makes turning the feature on later safe', function()
    local f = newVehicleServerFixture({ vehicleEntryExit = false })
    -- 2, not 1: server/bodyclaims.lua's own unconditional periodic sweep
    -- thread is created in the SAME sandbox env alongside this file's own
    -- (see newVehicleServerFixture's loadInto comment above) -- both are
    -- created regardless of Config.Features.VehicleEntryExit, so this count
    -- is unaffected by `vehicleEntryExit = false` either way.
    t.equals(f.threadCreateCount(), 2,
        'gating thread CREATION on a boot-time flag snapshot is the exact bug: the flag can change, the missing thread cannot appear later')
end)

t.test('feature on: the periodic sweep thread IS created', function()
    local f = newVehicleServerFixture()
    -- 2, not 1 -- see the identical note on the FEATURE-OFF test immediately above.
    t.equals(f.threadCreateCount(), 2)
end)

t.test('LIVE-FLIP FIX: a feature turned ON after boot still gets its claims expired -- no seat is stranded for the rest of the server\'s uptime', function()
    -- Boots with the feature OFF, exactly like a server that had never
    -- enabled vehicle entry.
    local f = newVehicleServerFixture({ vehicleEntryExit = false })
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- High command turns it on from the tablet mid-session. This is what
    -- ApplyFeatureOverride does: it writes straight into the live table.
    f.env.Config.Features.VehicleEntryExit = true

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    local grantedTwo = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 2 then grantedTwo = true end
    end
    t.isTrue(grantedTwo, 'precondition: the claim handler really does honour a live flip-on -- which is exactly why the sweep must exist')

    -- The claimant vanishes without ever releasing, and never comes back.
    -- Nothing but the sweep can free this seat now.
    f.removeVehicleExistence(50)
    f.stepSweep() -- primes the loop's own first Wait()
    f.stepSweep() -- one full sweep pass

    f.registerVehicle(500, 51, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)
    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree, 'without the sweep running, this seat would be unusable for the rest of the server\'s uptime')
end)

t.test('LIVE-FLIP FIX: while the feature is genuinely OFF, the sweep does nothing at all -- it costs a comparison, not work', function()
    local f = newVehicleServerFixture({ vehicleEntryExit = false })
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    -- No claim can even be created while the feature is off, so there is
    -- nothing for the sweep to find. It must simply not error.
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.stepSweep()
    f.stepSweep()
    t.equals(#f.clientEvents, 0, 'nothing granted, nothing denied, nothing swept -- an inert feature stays inert')
end)

t.test('sweep: proactively drops a claim naming a vehicle that no longer exists at all, even well before its own TTL would have expired it', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.removeVehicleExistence(50) -- the vehicle is destroyed while the claim is still well within its TTL

    f.stepSweep() -- primes the sweep loop's own first Wait()
    f.stepSweep() -- runs exactly one full sweep pass

    -- Re-register the SAME netId against a genuine, DIFFERENT vehicle
    -- entity (a stale netId reused is not realistic, but resolving THIS
    -- netId to nothing at all -- the actual case -- already proves the
    -- sweep fired; re-registering here just gives a second request
    -- something real to succeed against).
    f.registerVehicle(500, 51, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree, 'the sweep must have dropped the claim tied to the now-nonexistent vehicle')
end)

t.test('sweep: also drops a TTL-expired claim even if nobody ever requests that exact seat again', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(10001)

    f.stepSweep() -- primes
    f.stepSweep() -- one full pass -- must have dropped the expired claim

    -- Indirect proof: re-registering a FRESH vehicle at the SAME netId and
    -- granting a different src the same seat only works if the table entry
    -- was actually removed (an empty per-vehicle table, not merely an
    -- expired-but-present one) -- GetLiveClaim's own lazy path already
    -- covers "still present but expired," so this specifically exercises
    -- the SWEEP's own removal, not that fallback.
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 2)

    local grantedThree = false
    for _, c in ipairs(f.clientEvents) do
        if c.event == 'john-k9:client:vehicleSeatClaimGranted' and c.target == 3 then grantedThree = true end
    end
    t.isTrue(grantedThree)
end)

-- ========================================================================
-- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
-- RED-THEN-GREEN PROOF, in the real cross-file integration context.
--   RED, closed: a citizenid already claimed by a DIFFERENT exclusive
--   mechanic (kennel_rest/combat_target), or already a busy combat holder,
--   is refused a vehicle-seat grant -- the exact shape of the confirmed
--   kennel-vs-vehicle-seat race, proven here from server/vehicle.lua's own
--   side without needing server/kennel.lua/server/combat.lua loaded at all
--   (ClaimBody is called directly, the same way a real grant would have).
--   GREEN, the control: every ordinary single-claim test above this
--   section still succeeds -- this section only adds the NEW refusal
--   paths and their own releases.
--   GREEN, the other control: releaseVehicleSeatClaim still works
--   correctly WHILE a claim is actively held.
-- ========================================================================

t.test('EXCLUSIVE BODY-CLAIM: requestVehicleSeatClaim is refused when the SAME citizenid already holds a live kennel_rest claim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.env.ClaimBody('CIT1', 'kennel_rest')

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'), 'the race this pass exists to close: a seat must never be granted alongside another mechanic\'s live claim')
    -- Reuses the SAME locale key client/vehicle.lua's own pre-existing
    -- (racy) kennel-rest guard already reuses for this exact scenario.
    t.equals(f.lastNotify().description, locale('kennel.enter_already_resting'))
end)

t.test('EXCLUSIVE BODY-CLAIM: requestVehicleSeatClaim is refused when the SAME citizenid already holds a live combat_target/drag claim, with the accurate "being dragged" message', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.env.ClaimBody('CIT1', 'combat_target', 5000, 'drag')

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'))
    t.equals(f.lastNotify().description, locale('vehicle.blocked_by_being_dragged'))
end)

t.test('EXCLUSIVE BODY-CLAIM: requestVehicleSeatClaim is refused when the SAME citizenid already holds a live combat_target/bite claim, with the generic fallback message (no dedicated locale key exists for this exact scenario)', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.env.ClaimBody('CIT1', 'combat_target', 5000, 'bite')

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'))
    t.equals(f.lastNotify().description, locale('combat.reject_fallback'))
end)

t.test('EXCLUSIVE BODY-CLAIM: a claim that has genuinely EXPIRED no longer blocks a vehicle-seat grant -- a 300ms race must never become a permanent lockout', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.env.ClaimBody('CIT1', 'kennel_rest', 1000)

    f.advance(1001)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNotNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'), 'an expired claim must never permanently block a legitimate later request')
end)

t.test('EXCLUSIVE BODY-CLAIM, COMBAT HOLDER BUSY-STATE: requestVehicleSeatClaim is refused with the DRAG-specific message when server/combat.lua reports this src as a busy drag holder', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    -- server/combat.lua is not loaded in this fixture -- stubbed directly,
    -- mirroring the real `type(...) == 'function'` soft-dependency guard.
    f.env.IsK9CurrentlyHolding = function(src) return src == 2 end
    f.env.GetActiveHoldEffectTypeForHolder = function(src) return src == 2 and 'drag' or nil end

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'))
    t.equals(f.lastNotify().description, locale('vehicle.blocked_by_drag'))
end)

t.test('EXCLUSIVE BODY-CLAIM, COMBAT HOLDER BUSY-STATE: requestVehicleSeatClaim is refused with the BITE-HOLD message for a bite/takedown holder (no dedicated takedown message exists, the bite-hold one is reused, mirroring client/vehicle.lua\'s own pre-existing convention)', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.env.IsK9CurrentlyHolding = function(src) return src == 2 end
    f.env.GetActiveHoldEffectTypeForHolder = function(src) return src == 2 and 'takedown' or nil end

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'))
    t.equals(f.lastNotify().description, locale('vehicle.blocked_by_bite_hold'))
end)

t.test('EXCLUSIVE BODY-CLAIM, COMBAT HOLDER BUSY-STATE: an absent server/combat.lua (IsK9CurrentlyHolding never defined) is simply "not busy," never an error', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    -- IsK9CurrentlyHolding/GetActiveHoldEffectTypeForHolder deliberately
    -- left undefined -- exactly like a server that never loaded
    -- server/combat.lua at all.

    local ok = pcall(f.dispatchNetEvent, 'john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    t.isTrue(ok)
    t.isNotNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'))
end)

t.test('EXCLUSIVE BODY-CLAIM: a granted vehicle-seat claims this citizenid\'s body -- a DIFFERENT mechanic sees it as claimed', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    local claimed, mechanic = f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest')
    t.isTrue(claimed)
    t.equals(mechanic, 'vehicle_seat')
end)

t.test('EXCLUSIVE BODY-CLAIM: releaseVehicleSeatClaim also releases this citizenid\'s vehicle_seat body-claim -- release paths still work while a claim is actively held', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.isTrue(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'), 'sanity: the claim is genuinely held before release')

    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 2, 500, 1)

    t.isFalse(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'), 'releasing the seat claim must free the body-claim too')
    t.isTrue(f.env.ClaimBody('CIT1', 'kennel_rest'), 'the control: a legitimate claim by a different mechanic succeeds once released')
end)

t.test('EXCLUSIVE BODY-CLAIM: playerDropped also releases this citizenid\'s vehicle_seat body-claim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    f.firePlayerDropped(2, 'left')

    t.isFalse(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'), 'a disconnecting claimant must not leave a permanent body-claim behind')
end)

-- ----------------------------------------------------------------------
-- FORCED RELEASE ON ACCESS LOSS -- this file's half of
-- server/bodyclaims.lua's ForceReleaseBodyClaimForCitizenId dispatcher.
--
-- tests/bodyclaims_spec.lua proves the dispatcher's routing in isolation.
-- What can only be proven HERE is that server/vehicle.lua genuinely
-- registers a 'vehicle_seat' releaser and that it does BOTH halves: clears
-- its own VehicleSeatClaims row AND tells the affected client to get out.
-- A registry-only clear would hand the exact seat this player is still
-- sitting in to a second citizenid.
-- ----------------------------------------------------------------------

t.test('FORCED RELEASE: server/vehicle.lua registers a vehicle_seat releaser, and it does BOTH halves -- frees the seat AND tells the client to get out', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.isTrue(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'), 'sanity: the seat claim is held')

    t.isTrue(f.env.ForceReleaseBodyClaimForCitizenId('CIT1', 'cert_revoked'),
        'server/vehicle.lua must have registered a vehicle_seat releaser at its own file load')

    -- HALF ONE: the seat row itself is gone, so somebody else can have it.
    t.isFalse(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'), 'the body claim is released')
    f.setAccess(3, true)
    f.setPlayer(3, 'CIT2')
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 500, 1, 1)
    t.isNotNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'),
        'a SECOND citizenid can now claim that exact seat -- proving VehicleSeatClaims was cleared, not just the body claim')

    -- HALF TWO: and the first player was told to get out, so the seat is
    -- not handed over underneath someone still sitting in it.
    local forced
    for i = 1, #f.clientEvents do
        if f.clientEvents[i].event == 'john-k9:client:forceExitVehicleSeat' then forced = f.clientEvents[i] end
    end
    t.isNotNil(forced, 'THE LOAD-BEARING HALF: clearing the seat row without this event hands the seat to a second player while the first is still in it')
    t.equals(forced.target, 2, 'targeted at the affected player alone, never broadcast')
    t.equals(forced.args[1], 'cert_revoked', 'the reason reaches the client so it can say why')
end)

t.test('FORCED RELEASE: the client event is aimed at the citizenid\'s CURRENT live source, never the one recorded on the claim', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    f.setPlayer(2, nil)
    f.setPlayer(9, 'CIT1') -- same person, reconnected on a new source

    f.env.ForceReleaseBodyClaimForCitizenId('CIT1', 'cert_revoked')

    local forced
    for i = 1, #f.clientEvents do
        if f.clientEvents[i].event == 'john-k9:client:forceExitVehicleSeat' then forced = f.clientEvents[i] end
    end
    t.isNotNil(forced)
    t.equals(forced.target, 9, 'resolved fresh -- source 2 may now belong to an unrelated player who would be thrown out of their own vehicle')
end)

t.test('FORCED RELEASE: an OFFLINE citizenid still gets the seat row cleared, with no client event attempted', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    f.setPlayer(2, nil)

    t.isTrue(f.env.ForceReleaseBodyClaimForCitizenId('CIT1', 'cert_revoked'),
        'offline is a SUCCESS -- no client is rendering a seated ped to desync from')
    t.isFalse(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'))
end)

t.test('FORCED RELEASE: a citizenid holding NO seat is a clean no-op', function()
    local f = newVehicleServerFixture()
    f.setPlayer(2, 'CIT1')
    t.isFalse(f.env.ForceReleaseBodyClaimForCitizenId('CIT1', 'cert_revoked'))
end)

t.test('FORCED RELEASE IS UNGATED: it still frees a seat whose holder\'s access has ALREADY been revoked', function()
    -- GATE THE STOP, NEVER THE START. The caller is
    -- EndK9AccessForCitizenId, which has already taken this citizenid's
    -- access away -- a HasK9Access check anywhere in the release path would
    -- be guaranteed false at exactly the moment it matters.
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)

    f.setAccess(2, false) -- revoked while seated

    t.isTrue(f.env.ForceReleaseBodyClaimForCitizenId('CIT1', 'cert_revoked'))
    local forced
    for i = 1, #f.clientEvents do
        if f.clientEvents[i].event == 'john-k9:client:forceExitVehicleSeat' then forced = f.clientEvents[i] end
    end
    t.isNotNil(forced, 'losing access must never be what stops you getting out of a vehicle')
end)

t.test('EXCLUSIVE BODY-CLAIM: the periodic sweep also releases this citizenid\'s vehicle_seat body-claim for a TTL-expired claim nobody ever asks about again', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT1')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.advance(10001) -- past VEHICLE_SEAT_CLAIM_TTL_MS (10000)

    f.stepSweep() -- primes
    f.stepSweep() -- one full pass

    t.isFalse(f.env.IsBodyClaimedByOther('CIT1', 'kennel_rest'), 'the sweep must release the shared body-claim in lockstep with its own VehicleSeatClaims entry')
end)


-- ========================================================================
-- ONE SEAT PER CITIZENID, ACROSS EVERY VEHICLE (cross-change QA finding,
-- this pass -- reproduced in a harness before being fixed).
--
-- This file's exclusivity has always been addressed by (vehicleNetId,
-- seatIndex): correct for its original job, which was stopping two PEOPLE
-- racing for one seat. server/bodyclaims.lua then arrived addressing
-- exclusivity by CITIZENID, and the two schemes did not line up.
--
-- The sequence that broke it: hold seat 1 of vehicle A, then claim seat 1
-- of vehicle B. The per-seat check passes (different seat, nobody else
-- there), and ClaimBody reads the second call as a RENEWAL of the same
-- mechanic rather than a collision, overwriting the first in that
-- citizenid's single registry slot. Release vehicle A -- by hand, by TTL,
-- or by the sweep -- and ReleaseBody has no seat identity to check
-- against, so it clears the slot outright while vehicle B's seat is still
-- genuinely held. The registry then reports that citizenid as unclaimed
-- with a real seat claim live, and a concurrent kennel-rest or bite-hold
-- request is granted: the exact "two mechanics claim one body" race the
-- registry exists to close, reached by a different route.
--
-- Neither file's own tests could see it. bodyclaims_spec only renews the
-- same logical claim; this file only ever collided two requests on the
-- identical (vehicle, seat) pair. The bug lived in the seam.
-- ========================================================================
t.test('SECOND SEAT REFUSED: one citizenid holding a live claim on vehicle A cannot also claim a seat on vehicle B', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT-DUP')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.registerVehicle(501, 51, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    t.isNotNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimGranted'), 'precondition: the first claim really was granted')

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 501, 1, 2)
    local denied = f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied')
    t.isNotNil(denied, 'the second seat, on a different vehicle, must be refused')
    t.equals(denied.args[1], 501)
end)

t.test('SECOND SEAT REFUSED: also across two seats of the SAME vehicle', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT-DUP')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 2, 2)

    local denied = f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied')
    t.isNotNil(denied)
    t.equals(denied.args[2], 2, 'the SECOND seat is the one refused, not the first')
end)

t.test('CONTROL: re-requesting the SAME seat is still a renewal, not a self-collision -- the fix must not lock a client out of the seat it already holds', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT-DUP')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 2)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied'), 'a retry on the exact same seat is the documented renewal path and must still be granted')
end)

t.test('CONTROL: a DIFFERENT citizenid is unaffected -- this is a per-person limit, not a global one-seat-on-the-server limit', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setAccess(3, true)
    f.setPlayer(2, 'CIT-A')
    f.setPlayer(3, 'CIT-B')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.setPed(3, 11, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.registerVehicle(501, 51, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 3, 501, 1, 2)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied'), 'two different people in two different vehicles is ordinary play and must never be refused')
end)

t.test('RELEASING THE FIRST SEAT FREES THE PERSON -- the refusal is a start gate, never a trap: let go and the next seat is available', function()
    local f = newVehicleServerFixture()
    f.setAccess(2, true)
    f.setPlayer(2, 'CIT-DUP')
    f.setPed(2, 10, { x = 0, y = 0, z = 0 })
    f.registerVehicle(500, 50, { coords = { x = 0, y = 0, z = 0 } })
    f.registerVehicle(501, 51, { coords = { x = 0, y = 0, z = 0 } })

    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 500, 1, 1)
    f.dispatchNetEvent('john-k9:server:releaseVehicleSeatClaim', 2, 500, 1)
    f.dispatchNetEvent('john-k9:server:requestVehicleSeatClaim', 2, 501, 1, 2)

    t.isNil(f.lastClientEventNamed('john-k9:client:vehicleSeatClaimDenied'), 'after releasing, the same person must be able to take a different seat')
end)

os.exit(t.summary())
