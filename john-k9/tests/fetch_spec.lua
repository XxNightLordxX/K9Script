--[[
    tests/fetch_spec.lua

    Direct tests of server/fetch.lua's eleven RegisterNetEvent handlers
    (requestThrowFetchBall / confirmFetchBallThrown / cancelFetchThrow /
    requestPickupFetchBall / confirmFetchBallCarried / cancelFetchCarryAttach /
    releaseFetchBall / confirmFetchBallDropped / requestDeliverFetchBall /
    requestRecallFetchBall / reportFetchCarrierDown), its maintenance thread,
    and its playerDropped/onResourceStop cleanup, against the REAL,
    unmodified production file -- loaded alongside the real
    server/cooldowns.lua and server/entities.lua per that file's own
    FILE-TO-FILE CONTRACT (ThrowCooldown/PickupCooldown are real NewCooldown()
    trackers, every ResolveNetworkEntity call is the real resolve+existence-
    guard primitive). HasK9Access, IsConfiguredK9Model, and NotifyPlayer are
    stubbed directly -- all three are genuinely OTHER files' own logic
    (server/certifications/, server/notify.lua), already covered by their
    own specs -- this file's job is server/fetch.lua's own handshake/
    lifecycle/entity-theft-boundary logic, not a second copy of those.

    locale() is NEVER stubbed (this suite's own convention) -- every call
    below that reaches a NotifyPlayer(..., locale('fetch.xxx'), ...) call
    evaluates that locale() argument for real, against the real
    locales/en.json, before this file's own NotifyPlayer stub ever sees the
    result.

    ONE FRESH SANDBOX PER TEST (never shared) -- FetchBalls, CarrierIndex,
    PendingFetchThrows, PendingFetchCarries, and PendingFetchDrops are all
    `local` upvalues alive for this whole loaded file's lifetime, exactly
    like server/kennel.lua's Kennels/PendingKennelPlacements
    (kennel_spec.lua's own header explains why this matters). newFetchFixture()
    below builds one complete, independent world for every single t.test()
    call.

    ======================================================================
    WHAT THIS SPEC IS SPECIFICALLY CHECKING (per this pass's own task brief):

    1. Every confirm-failure branch that used to strand a real, already-
       created networked object now tells the client to reclaim it.
       confirmFetchBallThrown: TTL expiry, the HasK9Access re-check, the
       already-existing-ball ("shouldn't be reachable") branch, entity/model
       mismatch, and the netId-uniqueness collision. confirmFetchBallDropped:
       the same shape (TTL expiry, ball-missing/state-changed, entity/model
       mismatch, netId-uniqueness collision). See each section below for the
       specific 'john-k9:client:removeFetchBall' assertions.

    2. Cleanup is SAFE, not merely present: `safeToCleanup` in both handlers
       is re-derived FIRST and is `false` (no cleanup instruction sent) for
       every branch where the reported netId does NOT resolve to a real,
       correctly-modeled, uniquely-owned object -- proven below by asserting
       NO 'john-k9:client:removeFetchBall' event fires for the
       entity-doesn't-exist, wrong-model, and netId-collision branches, and
       critically that a foreign citizenid's own ball is untouched by another
       citizenid's rejected confirm.

    3. releaseFetchBall is unconditional -- no cooldown of any kind can block
       it, proven directly against the exact footgun server/cooldowns.lua's
       own header documents (a `releaseCooldownMs = 0` config value, which
       WOULD permanently fail-closed block release forever if any cooldown
       tracker were consulted for it).

    4. Lifecycle cleanup on playerDropped covers BOTH roles this file tracks
       independently -- the thrower (keyed by citizenid) and the carrier
       (keyed by source, via CarrierIndex) -- plus onResourceStop.

    5. confirmFetchBallCarried's two failure branches call EndFetchCycle
       while `ball.netId` STILL names the OLD, pre-pickup entity (this is
       DELIBERATE per that handler's own doc comment, not a bug) -- pinned
       below as current, correct behavior, not "fixed" into asserting the
       new netId instead.
    ======================================================================

    A GENUINE, DISCLOSED COVERAGE GAP (matching kennel_spec.lua's own
    precedent for the identical class of branch): confirmFetchBallThrown's
    `if FetchBalls[citizenid] then ... end` ("shouldn't be reachable, but
    never trust an invariant alone") branch is NOT reachable through the
    public net events alone -- requestThrowFetchBall's own
    `if FetchBalls[citizenid] then reject already_active_ball end` check
    (which runs BEFORE a pending throw is ever created) means a citizenid
    can never have both an active FetchBalls entry AND a live
    PendingFetchThrows entry at the same time via any real caller. Reaching
    it would require writing directly into this file's private `FetchBalls`/
    `PendingFetchThrows` locals to fabricate a state no real caller can
    produce -- disclosed here, not silently worked around, exactly like
    kennel_spec.lua's own note on the equivalent `Kennels[citizenid]` branch.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- see kennel_spec.lua's own identical comment for why
-- the real native's exact algorithm does not matter here.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local BALL_MODEL = 'prop_tennis_ball'
local WRONG_MODEL = 'prop_totally_unrelated_junk'
local BALL_HASH = GetHashKey(BALL_MODEL)
local WRONG_HASH = GetHashKey(WRONG_MODEL)
local K9_PED_HASH = GetHashKey('a_c_shepherd')
local NON_K9_PED_HASH = GetHashKey('a_c_pug')

local THROW_COOLDOWN_MS = 5000
local PICKUP_COOLDOWN_MS = 500
local PENDING_THROW_TTL_MS = 15000
local MAX_BALL_LIFETIME_MS = 300000
local PICKUP_INTERACT_DIST = 2.0
local DELIVER_PROXIMITY = 3.0
local MAINTENANCE_INTERVAL_MS = 2000

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- server/fetch.lua's proximity checks do
-- `#(GetEntityCoords(a) - GetEntityCoords(b))`, so both the `-` and `#`
-- metamethods must be modeled (same shape certifications_spec.lua/
-- tenure_spec.lua already use for their own proximity checks).
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

--- @param a number
--- @param b number
--- @param message string?
local function approxEquals(a, b, message)
    t.isTrue(math.abs(a - b) < 1e-6, (message and (message .. ': ') or '') ..
        ('expected ~%s, got %s'):format(tostring(b), tostring(a)))
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/fetch.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it
--- (same load order fxmanifest.lua's server_scripts list requires).
--- @param opts table? -- { mouthCarryMode: string (default 'fake'), releaseCooldownMs: number? (deliberately unused optional field -- see releaseFetchBall tests below) }
--- @return table fixture
local function newFetchFixture(opts)
    opts = opts or {}
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {} -- eventName -> { handler, handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent) -- fetch.lua registers exactly one handler per event name
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

    local function IsConfiguredK9Model(hash) return hash == K9_PED_HASH end

    -- K9 role/model decoupling (server/appearance.lua) -- requestPickupFetchBall
    -- ORs this in alongside IsConfiguredK9Model(GetEntityModel(ped)) so a
    -- role-holder on a non-K9 model can still carry. Stubbed here (not the
    -- real server/appearance.lua), same "this file's own logic only"
    -- reasoning as HasK9Access/IsConfiguredK9Model above. Defaults false.
    local hasRoleBySource = {}
    local function HasK9Role(src) return hasRoleBySource[src] == true end

    local playersBySource = {} -- source -> citizenid string, or nil = unresolved
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = playersBySource[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid } }
            end,
        },
    }

    -- PER-PERSON FEATURE CONTROL (this pass) -- mirrors
    -- tests/pursuitsprint_spec.lua's own `permissionGrants`/
    -- `defaultHasPermission`/`grantPermission` fixture shape, for
    -- IsFetchMechanicPermittedForCitizenId.
    local permissionGrants = {} -- [citizenid][key] = true/false
    local function defaultHasPermission(citizenid, key)
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local pedBySource = {} -- source -> ped handle (unset/0 == "disconnected mid-flight")
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {} -- handle -> vec3
    local function GetEntityCoords(handle) return coordsByHandle[handle] or vec3(0, 0, 0) end

    local headingByHandle = {}
    local function GetEntityHeading(handle) return headingByHandle[handle] or 0.0 end

    local networkEntities = {} -- netId -> handle
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (GetEntityType's real domain; 1 = ped, 3 = object)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {} -- handle -> hash (used for both peds and ball objects)
    local function GetEntityModel(handle) return entityModels[handle] end

    -- NETWORK-OWNERSHIP GUARD mock (coder-architect, urgent red-team finding
    -- this pass -- mirrors tests/propattachment_spec.lua's own identical
    -- mock, added there first for server/propattachment.lua's own original
    -- guard). handle -> src of whichever connection currently, per this
    -- mock's own OneSync stand-in, "owns" that networked object. Defaults to
    -- nil (no known owner) for any handle registerEntity's caller doesn't
    -- explicitly assign one to -- deliberately FAIL CLOSED, matching the
    -- real NetworkGetEntityOwner check's own `~= src` comparison, so a test
    -- that wants a confirm to reach PAST this guard must say so explicitly
    -- via registerEntity's own `owner` field.
    local entityOwners = {} -- handle -> src
    local function NetworkGetEntityOwner(handle) return entityOwners[handle] end

    local deletedEntities = {} -- handle -> true
    local function DeleteEntity(handle) deletedEntities[handle] = true end

    local config = {
        Features = { FetchMechanic = true },
        FetchMechanic = {
            ballPropModel = BALL_MODEL,
            throwForwardOffsetMeters = 1.0,
            throwUpOffsetMeters = 1.2,
            throwForceForward = 12.0,
            throwForceUp = 6.0,
            throwCooldownMs = opts.throwCooldownMs or THROW_COOLDOWN_MS,
            pendingThrowTtlMs = PENDING_THROW_TTL_MS,
            maxBallLifetimeMs = MAX_BALL_LIFETIME_MS,
            pickupInteractDistanceMeters = PICKUP_INTERACT_DIST,
            deliverProximityMeters = DELIVER_PROXIMITY,
            maintenanceIntervalMs = MAINTENANCE_INTERVAL_MS,
            mouthCarryMode = opts.mouthCarryMode or 'fake',
            mouthBoneIndex = 0,
            mouthOffsetX = 0.0, mouthOffsetY = 0.0, mouthOffsetZ = 0.0,
            pickupCooldownMs = opts.pickupCooldownMs or PICKUP_COOLDOWN_MS,
            releaseCooldownMs = opts.releaseCooldownMs, -- deliberately never read by the production file -- see releaseFetchBall tests
        },
        FeatureControl = { RequireGrant = {} },
    }

    local runner = Sandbox.newThreadRunner()

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        HasK9Role = HasK9Role,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        HasPermission = defaultHasPermission,
        IsConfiguredK9Model = IsConfiguredK9Model,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHeading = GetEntityHeading,
        GetHashKey = GetHashKey,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityModel = GetEntityModel,
        NetworkGetEntityOwner = NetworkGetEntityOwner,
        DeleteEntity = DeleteEntity,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        print = printStub,
        Config = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/fetch.lua', env)

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        deletedEntities = deletedEntities,
        printedLines = printedLines,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setK9Role = function(src, hasRole) hasRoleBySource[src] = hasRole end,
        setPlayer = function(src, citizenid) playersBySource[src] = citizenid end,
        -- PER-PERSON FEATURE CONTROL (this pass) -- see this fixture's own
        -- header comment above.
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        setPed = function(src, pedHandle, coords, heading, modelHash)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = vec3(coords.x, coords.y, coords.z)
            headingByHandle[pedHandle] = heading or 0.0
            entityModels[pedHandle] = modelHash or K9_PED_HASH
        end,
        registerEntity = function(netId, handle, ropts)
            ropts = ropts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = ropts.exists ~= false
            entityTypes[handle] = ropts.entityType or 3
            entityModels[handle] = ropts.model or BALL_HASH
            entityOwners[handle] = ropts.owner -- nil (no owner) unless the caller says otherwise -- see entityOwners' own declaration comment above
            local c = ropts.coords or { x = 0, y = 0, z = 0 }
            coordsByHandle[handle] = vec3(c.x, c.y, c.z)
        end,
        setEntityOwner = function(handle, src) entityOwners[handle] = src end,
        removeExistence = function(handle) existingEntities[handle] = false end,
        entityExists = function(handle) return existingEntities[handle] == true end,
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
        -- Maintenance thread stepping -- see fixtures/sandbox.lua's own
        -- newThreadRunner() doc comment: the FIRST step() only primes the
        -- coroutine (reaches the initial Wait), so a genuine "run one sweep
        -- pass" from a fresh fixture needs step() called TWICE.
        primeMaintenance = function() runner.step() end,
        stepMaintenance = function() runner.step() end,
    }
end

local nextNetId = 1000
local function freshNetId()
    nextNetId = nextNetId + 1
    return nextNetId
end

--- @param f table
--- @param eventName string
--- @return table? -- the most recently captured {event=,target=,args=} entry for eventName, or nil
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then
            return f.clientEvents[i]
        end
    end
    return nil
end

--- @param f table
--- @param eventName string
--- @return integer
local function countClientEvents(f, eventName)
    local n = 0
    for _, e in ipairs(f.clientEvents) do
        if e.event == eventName then n = n + 1 end
    end
    return n
end

--- Drives a full, successful requestThrowFetchBall -> confirmFetchBallThrown
--- handshake, returning the resulting netId/entity handle.
--- @param f table
--- @param src number
--- @param citizenid string
--- @param pedHandle number
--- @param pedCoords table
--- @return number netId, number entityHandle
local function throwSuccessfully(f, src, citizenid, pedHandle, pedCoords)
    f.setAccess(src, true)
    f.setPlayer(src, citizenid)
    f.setPed(src, pedHandle, pedCoords, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', src)
    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    assert(instruction, 'requestThrowFetchBall did not send a throwFetchBallAt instruction')
    local x, y, z = instruction.args[1], instruction.args[2], instruction.args[3]
    local netId = freshNetId()
    local objectHandle = netId + 500000
    -- owner = src: an honest client's confirm always names the object IT
    -- ITSELF just created -- see the NETWORK-OWNERSHIP GUARD mock's own
    -- declaration comment above for why this must be explicit.
    f.registerEntity(netId, objectHandle, { coords = { x = x, y = y, z = z }, owner = src })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', src, netId)
    return netId, objectHandle
end

--- Drives a full pickup (requestPickupFetchBall, and for 'attach' mode also
--- confirmFetchBallCarried) for `carrierSrc` against an already-thrown ball.
--- Positions the carrier ped exactly at the ball's own coords so the
--- server-side proximity re-check trivially passes.
--- @param f table
--- @param carrierSrc number
--- @param carrierCitizenId string
--- @param carrierPedHandle number
--- @param ballNetId number
--- @param ballCoords table
--- @return string mode
local function pickupSuccessfully(f, carrierSrc, carrierCitizenId, carrierPedHandle, ballNetId, ballCoords)
    f.setAccess(carrierSrc, true)
    f.setPlayer(carrierSrc, carrierCitizenId)
    f.setPed(carrierSrc, carrierPedHandle, ballCoords, 0.0, K9_PED_HASH)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', carrierSrc, ballNetId)
    local carryEvent = lastClientEvent(f, 'john-k9:client:carryFetchBall')
    assert(carryEvent, 'requestPickupFetchBall did not send a carryFetchBall instruction')
    local mode = carryEvent.args[2]
    if mode == 'attach' then
        local newNetId = freshNetId()
        local newHandle = newNetId + 700000
        -- owner = carrierSrc: the carrier's own client created this
        -- freshly-attached replacement -- see the NETWORK-OWNERSHIP GUARD
        -- mock's own declaration comment above.
        f.registerEntity(newNetId, newHandle, { coords = ballCoords, owner = carrierSrc })
        f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', carrierSrc, newNetId)
    end
    return mode
end

-- ----------------------------------------------------------------------
-- Sanity: the whole file loaded and registered what its own header
-- documents, before trusting any test below that depends on it.
-- ----------------------------------------------------------------------

t.test('server/fetch.lua registers exactly its 11 documented server net events', function()
    local f = newFetchFixture()
    local names, count = {}, 0
    for name in pairs(f.netEventNames) do
        names[name] = true
        count = count + 1
    end
    t.equals(count, 11)
    for _, name in ipairs({
        'john-k9:server:requestThrowFetchBall',
        'john-k9:server:confirmFetchBallThrown',
        'john-k9:server:cancelFetchThrow',
        'john-k9:server:requestPickupFetchBall',
        'john-k9:server:confirmFetchBallCarried',
        'john-k9:server:cancelFetchCarryAttach',
        'john-k9:server:releaseFetchBall',
        'john-k9:server:confirmFetchBallDropped',
        'john-k9:server:requestDeliverFetchBall',
        'john-k9:server:requestRecallFetchBall',
        'john-k9:server:reportFetchCarrierDown',
    }) do
        t.isTrue(names[name] ~= nil, name .. ' should be registered')
    end
end)

t.test('server/fetch.lua registers a playerDropped and an onResourceStop handler', function()
    local f = newFetchFixture()
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1)
    t.isTrue(f.eventHandlerCount('onResourceStop') >= 1)
end)

-- ========================================================================
-- REGRESSION (same class of bug QA reproduced against server/combat.lua):
-- ThrowCooldown/PickupCooldown = NewCooldown(Config.FetchMechanic.
-- throwCooldownMs / pickupCooldownMs) used to hand a raw, operator-editable
-- Config value straight to NewCooldown -- an uncaught non-positive/NaN
-- value there would abort THIS FILE's own load from that line onward,
-- taking every one of its 11 net events (including releaseFetchBall, this
-- file's own "always let go" termination path a stuck carrier depends on)
-- and its playerDropped/onResourceStop handlers down with it. Fixed via
-- ResolveConfiguredThresholdMs (server/cooldowns.lua) at both of this
-- file's raw Config-cooldown call sites. Proves the fix at the exact level
-- the bug was found: does the file still load, and does the termination
-- path stay reachable, no matter what an operator puts in the config.
-- ========================================================================

t.test('REGRESSION: Config.FetchMechanic.throwCooldownMs = 0 no longer aborts this file\'s load -- clamps to the shipped 5000ms fallback, warns loudly (naming the exact key/value/substitute), and every event/termination path stays registered', function()
    local f = newFetchFixture({ throwCooldownMs = 0 })

    local names, count = {}, 0
    for name in pairs(f.netEventNames) do names[name] = true; count = count + 1 end
    t.equals(count, 11, 'every net event this file documents must still register, not just the ones textually above the bad value')
    t.isNotNil(names['john-k9:server:releaseFetchBall'],
        'the termination path a stuck carrier depends on must remain reachable no matter what an operator puts in the config')
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1)
    t.isTrue(f.eventHandlerCount('onResourceStop') >= 1)

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.FetchMechanic.throwCooldownMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find('5000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted -- the operator must still find out')
end)

t.test('REGRESSION: Config.FetchMechanic.pickupCooldownMs = -1 no longer aborts this file\'s load -- clamps to the shipped 500ms fallback and warns loudly', function()
    local f = newFetchFixture({ pickupCooldownMs = -1 })

    local names, count = {}, 0
    for name in pairs(f.netEventNames) do names[name] = true; count = count + 1 end
    t.equals(count, 11)
    t.isNotNil(names['john-k9:server:releaseFetchBall'])

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.FetchMechanic.pickupCooldownMs', 1, true)
            and line:find('found: -1', 1, true)
            and line:find('500', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)
end)

t.test('REGRESSION: both throwCooldownMs and pickupCooldownMs invalid at once (worst case) still loads cleanly with every event/termination path intact', function()
    local f = newFetchFixture({ throwCooldownMs = 0 / 0, pickupCooldownMs = 0 })
    local count = 0
    for _ in pairs(f.netEventNames) do count = count + 1 end
    t.equals(count, 11)
end)

-- ----------------------------------------------------------------------
-- requestThrowFetchBall
-- ----------------------------------------------------------------------

t.test('requestThrowFetchBall: an uncertified handler is rejected with a real notification', function()
    local f = newFetchFixture()
    f.setAccess(1, false)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[1].description, locale('fetch.not_authorized_equipment'))
    t.equals(f.notifyCalls[1].notifyType, 'error')
end)

t.test('requestThrowFetchBall: cooldown silently blocks a second immediate request from the same source', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 1)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1) -- same instant, no advance
    t.equals(#f.notifyCalls, 0, 'rate-limited rejection is silent')
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 1)
end)

t.test('requestThrowFetchBall: an unresolvable citizenid is rejected with a real notification', function()
    local f = newFetchFixture()
    f.setAccess(1, true) -- no setPlayer -- GetPlayer(1) resolves to nil
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(#f.clientEvents, 0)
    t.equals(f.notifyCalls[1].description, locale('common.unable_to_resolve_citizenid'))
end)

t.test('requestThrowFetchBall: a second request while a ball is already active (confirmed) is rejected', function()
    local f = newFetchFixture()
    throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.advance(THROW_COOLDOWN_MS + 1)
    local before = countClientEvents(f, 'john-k9:client:throwFetchBallAt')
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.already_active_ball'))
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), before)
end)

t.test('requestThrowFetchBall: a second request while a throw is pending (unconfirmed) is rejected', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1) -- pending created, never confirmed
    f.advance(THROW_COOLDOWN_MS + 1)
    local before = countClientEvents(f, 'john-k9:client:throwFetchBallAt')
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.throw_in_progress'))
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), before)
end)

t.test('requestThrowFetchBall: a disconnected ped (GetPlayerPed == 0) is a silent no-op', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123') -- ped left unset -> GetPlayerPed(1) == 0
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('requestThrowFetchBall: spawn/force vectors at heading 0 use +Y forward, matching kennel.lua\'s heading trig', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 100.0, y = 200.0, z = 30.0 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    t.equals(instruction.target, 1)
    approxEquals(instruction.args[1], 100.0, 'spawnX')
    approxEquals(instruction.args[2], 201.0, 'spawnY (pedY + 1.0m offset)')
    approxEquals(instruction.args[3], 31.2, 'spawnZ (pedZ + 1.2m up offset)')
    approxEquals(instruction.args[4], 0.0, 'forceX')
    approxEquals(instruction.args[5], 12.0, 'forceY (throwForceForward)')
    approxEquals(instruction.args[6], 6.0, 'forceZ (throwForceUp)')
end)

t.test('requestThrowFetchBall: success opens a pending throw and notifies nothing yet (confirm-driven success message)', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 1)
end)

-- ----------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsFetchMechanicPermittedForCitizenId, checked at
-- requestThrowFetchBall (this section). Mirrors
-- tests/pursuitsprint_spec.lua's own section of the same name.
-- ----------------------------------------------------------------------

t.test('requestThrowFetchBall BLOCK: an explicit block.FetchMechanic grant denies, and burns NO throw cooldown', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.grantPermission('ABC123', 'block.FetchMechanic', true)

    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 0)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.not_authorized_equipment'))

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had consumed ThrowCooldown, this would now be silently rate-limited
    -- instead of succeeding.
    f.grantPermission('ABC123', 'block.FetchMechanic', false)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 1, 'a block must never burn the cooldown a legitimate follow-up throw still needs')
end)

t.test('requestThrowFetchBall not blocked: an ordinary handler with no grant/block row at all still throws (default allow, step 4)', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 1)
end)

t.test('requestThrowFetchBall RequireGrant listed + no grant held -- denied even though every other check passes', function()
    local f = newFetchFixture()
    f.config.FeatureControl.RequireGrant.FetchMechanic = true
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    -- deliberately NOT granted
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 0)
end)

t.test('requestThrowFetchBall RequireGrant listed + an active feature.FetchMechanic grant -- allowed', function()
    local f = newFetchFixture()
    f.config.FeatureControl.RequireGrant.FetchMechanic = true
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.grantPermission('ABC123', 'feature.FetchMechanic', true)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 1)
end)

-- ----------------------------------------------------------------------
-- cancelFetchThrow
-- ----------------------------------------------------------------------

t.test('cancelFetchThrow: frees the caller\'s own pending slot immediately, rather than waiting out the TTL', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    f.dispatchNetEvent('john-k9:server:cancelFetchThrow', 1)

    f.advance(THROW_COOLDOWN_MS + 1)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    t.equals(countClientEvents(f, 'john-k9:client:throwFetchBallAt'), 2, 'a genuinely fresh throw, not blocked by "already in progress"')
    for _, call in ipairs(f.notifyCalls) do
        t.isTrue(call.description ~= locale('fetch.throw_in_progress'))
    end
end)

t.test('cancelFetchThrow: a cancel from a mismatched source does not clear another connection\'s pending throw', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1) -- pending.src == 1

    f.setPlayer(2, 'ABC123') -- resolves to the same citizenid, different source
    f.dispatchNetEvent('john-k9:server:cancelFetchThrow', 2)

    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.thrown_success'))
end)

-- ----------------------------------------------------------------------
-- confirmFetchBallThrown -- input/pending validation
-- ----------------------------------------------------------------------

t.test('confirmFetchBallThrown: a non-number netId is a silent no-op', function()
    local f = newFetchFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, 'not-a-number')
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmFetchBallThrown: an unresolvable citizenid is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, 12345)
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmFetchBallThrown: no matching pending throw at all is a silent no-op', function()
    local f = newFetchFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, 12345)
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmFetchBallThrown: a confirm from a source that does not match the pending\'s own src is a silent no-op, and the real pending survives it', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)

    f.setPlayer(2, 'ABC123')
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 2, 99999)
    t.equals(#f.notifyCalls, 0)

    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.thrown_success'))
end)

-- ----------------------------------------------------------------------
-- confirmFetchBallThrown -- the fixed rejection branches: every one now
-- notifies AND (when, and only when, `safeToCleanup` genuinely holds) sends
-- 'john-k9:client:removeFetchBall' to `src` -- NEVER a server-side
-- DeleteEntity (that is this handler's own documented design: the client
-- that just created the object does its own resolve+model-check+delete
-- locally, see this handler's own doc comment) and NEVER a broadcast.
-- ----------------------------------------------------------------------

t.test('confirmFetchBallThrown: an expired (TTL) pending throw notifies timed-out AND instructs the client to reclaim the real object', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })

    f.advance(PENDING_THROW_TTL_MS + 1)
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.throw_timed_out'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'error')
    local cleanup = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.isNotNil(cleanup, 'the real, already-created object must not be left with no reclaim instruction')
    t.equals(cleanup.target, 1, 'sent ONLY to the reporting src, never a broadcast')
    t.equals(cleanup.args[1], netId)
    t.isNil(f.deletedEntities[handle], 'this handler never calls DeleteEntity itself -- reclaim is client-instructed, by design')
end)

t.test('confirmFetchBallThrown: HasK9Access revoked mid-flight notifies AND instructs the client to reclaim the real object', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] }, owner = 1 })

    f.setAccess(1, false) -- decertified between request and confirm
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.not_authorized_equipment'))
    local cleanup = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.isNotNil(cleanup)
    t.equals(cleanup.target, 1)
    t.equals(cleanup.args[1], netId)
end)

t.test('confirmFetchBallThrown: an entity that never resolves (never created, or already gone) notifies "unconfirmed" and sends NO cleanup instruction (nothing real to reclaim)', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    -- Never call f.registerEntity -- the claimed netId resolves to nothing.
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, freshNetId())

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.placement_failed_unconfirmed'))
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'), 'safeToCleanup must be false when the entity never resolved')
end)

t.test('confirmFetchBallThrown: a real object of an unexpected model is rejected, and NO cleanup instruction is sent (might not be the real ball at all)', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local netId = freshNetId()
    local handle = netId + 500000
    f.registerEntity(netId, handle, {
        coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] },
        model = WRONG_HASH,
    })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, netId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.placement_failed_wrong_model'))
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'), 'safeToCleanup requires the correct model -- never instruct a delete of an unverified-model entity')
    t.isNil(f.deletedEntities[handle])
end)

t.test('confirmFetchBallThrown: a netId already claimed by a DIFFERENT citizenid\'s active ball is rejected, sends NO cleanup instruction, and the original owner\'s ball is untouched', function()
    local f = newFetchFixture()
    local netId1, handle1 = throwSuccessfully(f, 1, 'AAA111', 5001, { x = 0, y = 0, z = 0 })
    f.advance(THROW_COOLDOWN_MS + 1)

    -- A second handler reports player 1's ALREADY-CLAIMED netId as their own
    -- throw -- the exact hijack path this file's header GLOBAL
    -- NETID-UNIQUENESS INVARIANT exists to close.
    f.setAccess(2, true)
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 2)
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 2, netId1)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.placement_failed_already_tracked'))
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'), 'never instruct a delete of an entity this citizenid does not own')
    t.isNil(f.deletedEntities[handle1], 'citizenid AAA111\'s real ball must never be touched by BBB222\'s rejected confirm')

    -- Player 1's own ball is provably still intact and recallable.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

t.test('confirmFetchBallThrown: success registers the ball and notifies success', function()
    local f = newFetchFixture()
    throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.thrown_success'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'success')
end)

-- ----------------------------------------------------------------------
-- requestPickupFetchBall
-- ----------------------------------------------------------------------

t.test('requestPickupFetchBall: a non-number netId is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 1, 'nope')
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestPickupFetchBall: an uncertified handler is rejected', function()
    local f = newFetchFixture()
    f.setAccess(1, false)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 1, 123)
    t.equals(f.notifyCalls[1].description, locale('fetch.not_authorized_equipment'))
end)

t.test('requestPickupFetchBall: cooldown silently blocks a second immediate pickup request from the same source', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 1)
    local before = #f.notifyCalls
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(#f.notifyCalls, before, 'rate-limited rejection is silent')
end)

t.test('requestPickupFetchBall: a disconnected ped (GetPlayerPed == 0) is a silent no-op', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    local before = #f.notifyCalls
    f.setAccess(2, true) -- ped left unset -> GetPlayerPed(2) == 0
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(#f.notifyCalls, before)
end)

t.test('requestPickupFetchBall: a non-K9 ped model is rejected', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    -- PER-PERSON FEATURE CONTROL (this pass): requestPickupFetchBall now
    -- resolves the caller's own citizenid immediately after HasK9Access
    -- (before IsFetchMechanicPermittedForCitizenId), not only right before
    -- the eventual mutation the way it used to -- a real connected caller
    -- that already passed HasK9Access always has a resolvable citizenid in
    -- production, so every test past this point needs setPlayer too.
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, NON_K9_PED_HASH)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.carry_requires_k9_model'))
end)

-- K9 ROLE/MODEL DECOUPLING WIDENING -- "I also want everything to work with
-- any ped". A caller who holds the decoupled K9 ROLE (HasK9Role) but is
-- standing on a non-K9 model must still be able to carry -- previously this
-- was unconditionally rejected as carry_requires_k9_model.
t.test('requestPickupFetchBall: K9 ROLE/MODEL DECOUPLING -- a non-K9 ped model IS accepted when the caller holds the decoupled K9 role', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, NON_K9_PED_HASH)
    f.setK9Role(2, true)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 1, 'a human/custom-modeled role-holder must be allowed to carry, not rejected as carry_requires_k9_model')
end)

t.test('requestPickupFetchBall: already carrying (or mid attach-transition) is rejected', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId) -- creates PendingFetchCarries[2], never confirmed
    f.advance(PICKUP_COOLDOWN_MS + 1) -- clear PickupCooldown's own gate so THIS check, not the cooldown, is what's exercised
    local before = #f.notifyCalls
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId + 999)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.already_carrying'))
    t.isTrue(#f.notifyCalls > before)
end)

t.test('requestPickupFetchBall: no ball at that netId, or a ball not in a pickup-able state, notifies "not available"', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    -- PER-PERSON FEATURE CONTROL (this pass): see the "a non-K9 ped model is
    -- rejected" test above for why this now needs setPlayer too.
    f.setPlayer(1, 'AAA111')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 1, 123456)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.not_available_to_pickup'))
end)

t.test('requestPickupFetchBall: a carried ball cannot be picked up by a second K9', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    pickupSuccessfully(f, 2, 'BBB222', 5002, netId, { x = 0, y = 0, z = 0 })

    f.setAccess(3, true)
    f.setPed(3, 5003, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(3, 'CCC333')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 3, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.not_available_to_pickup'))
end)

-- ----------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsFetchMechanicPermittedForCitizenId, checked at
-- requestPickupFetchBall (this section) -- the SAME predicate
-- requestThrowFetchBall's own section above already exercises, consulted
-- again here since pickup is this feature's OTHER "opening" action (a K9
-- starting to carry a ball someone else threw).
-- ----------------------------------------------------------------------

t.test('requestPickupFetchBall BLOCK: an explicit block.FetchMechanic grant denies, and burns NO pickup cooldown', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.grantPermission('BBB222', 'block.FetchMechanic', true)

    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 0)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.not_authorized_equipment'))

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had consumed PickupCooldown, this would now be silently rate-limited
    -- instead of succeeding.
    f.grantPermission('BBB222', 'block.FetchMechanic', false)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 1, 'a block must never burn the cooldown a legitimate follow-up pickup still needs')
end)

t.test('requestPickupFetchBall not blocked: an ordinary K9 with no grant/block row at all still picks up (default allow, step 4)', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 1)
end)

t.test('requestPickupFetchBall RequireGrant listed + no grant held -- denied even though every other check passes', function()
    local f = newFetchFixture()
    -- Thrown BEFORE RequireGrant is turned on -- this test is only about
    -- the PICKUP side's own RequireGrant resolution, isolated from the
    -- throw's own identical (and separately tested) resolution above.
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.config.FeatureControl.RequireGrant.FetchMechanic = true
    f.setAccess(2, true)
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    -- deliberately NOT granted
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 0)
end)

t.test('requestPickupFetchBall RequireGrant listed + an active feature.FetchMechanic grant -- allowed', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.config.FeatureControl.RequireGrant.FetchMechanic = true
    f.setAccess(2, true)
    f.setPlayer(2, 'BBB222')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.grantPermission('BBB222', 'feature.FetchMechanic', true)
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 1)
end)

t.test('TERMINATION PATH UNAFFECTED: releaseFetchBall still works instantly for a carrier who is now block.FetchMechanic-blocked -- "drop a ball" must never be gated', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    pickupSuccessfully(f, 2, 'BBB222', 5002, netId, { x = 0, y = 0, z = 0 })

    f.grantPermission('BBB222', 'block.FetchMechanic', true)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)
    t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), 1, 'a blocked carrier must still be able to voluntarily drop the ball')
end)

t.test('requestPickupFetchBall: an entity that fails re-resolution or model-check notifies "pickup unconfirmed"', function()
    local f = newFetchFixture()
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.removeExistence(handle) -- the ball despawned between throw-confirm and this pickup attempt

    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.pickup_unconfirmed'))
end)

t.test('requestPickupFetchBall: too far from the ball\'s live server-side position is rejected -- the REAL authority boundary, not just the client\'s ox_target UI radius', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })

    f.setAccess(2, true)
    -- Comfortably past pickupInteractDistanceMeters (2.0m) -- 50m away.
    f.setPed(2, 5002, { x = 50.0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.too_far_to_pickup'))
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 0)
end)

t.test('requestPickupFetchBall: an unresolvable citizenid for the carrier is a silent no-op after all other checks pass', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH) -- no setPlayer -- GetPlayer(2) resolves to nil
    local before = #f.notifyCalls
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(#f.notifyCalls, before)
    t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), 0)
end)

t.test('requestPickupFetchBall: success in "fake" mode carries the ball, notifies success, and opens no PendingFetchCarries slot', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    local carry = lastClientEvent(f, 'john-k9:client:carryFetchBall')
    t.equals(carry.target, 2)
    t.equals(carry.args[1], netId)
    t.equals(carry.args[2], 'fake')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.picked_up_success'))
    t.equals(f.notifyCalls[#f.notifyCalls].notifyType, 'success')

    -- No attach-mode transition needed in 'fake' mode -- confirming carried
    -- with no pending must be a silent no-op (proves no stray pending was
    -- opened for 'fake' mode).
    local beforeNotify = #f.notifyCalls
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, netId)
    t.equals(#f.notifyCalls, beforeNotify)
end)

t.test('requestPickupFetchBall: success in "attach" mode opens a PendingFetchCarries slot instead of confirming immediately', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    local carry = lastClientEvent(f, 'john-k9:client:carryFetchBall')
    t.equals(carry.args[2], 'attach')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.picked_up_success'))

    -- Still transitioning -- a second pickup attempt by anyone else must be
    -- rejected as "already carrying" from the CARRIER's own perspective
    -- (checked via requestDeliverFetchBall / releaseFetchBall below, but the
    -- carrier itself trying a fresh pickup must also see "already carrying").
    f.advance(PICKUP_COOLDOWN_MS + 1) -- clear PickupCooldown's own gate so THIS check, not the cooldown, is what's exercised
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.already_carrying'))
end)

-- ----------------------------------------------------------------------
-- confirmFetchBallCarried -- 'attach'-mode pickup confirm
-- ----------------------------------------------------------------------

t.test('confirmFetchBallCarried: a non-number netId is a silent no-op', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 1, 'nope')
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmFetchBallCarried: no matching pending is a silent no-op', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 1, 999)
    t.equals(#f.notifyCalls, 0)
end)

t.test('confirmFetchBallCarried: an expired pending is a SILENT no-op by design (the maintenance sweep may already have force-ended this cycle) -- not one of this pass\'s fixed branches', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId) -- PendingFetchCarries[2] opened
    local before = #f.notifyCalls -- thrown_success + picked_up_success already counted here

    f.advance(PENDING_THROW_TTL_MS + 1) -- pendingThrowTtlMs is reused for this TTL -- see requestPickupFetchBall's own source
    local newNetId = freshNetId()
    f.registerEntity(newNetId, newNetId + 700000, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, newNetId)
    t.equals(#f.notifyCalls, before, 'this branch adds nothing, silently, per its own source comment')
end)

t.test('confirmFetchBallCarried: entity/model mismatch ends the WHOLE cycle via EndFetchCycle, broadcasting the OLD stale netId (deliberate, documented, not a bug)', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId, oldHandle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, oldNetId) -- PendingFetchCarries[2] opened, ball.netId still == oldNetId

    -- The 'attach' replacement object never resolves (model load failed
    -- client-side but it still fired this confirm with a bogus netId).
    local bogusNetId = freshNetId()
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, bogusNetId)

    -- STALE-NETID PIN (this file's own doc comment, investigated and left
    -- as-is): EndFetchCycle acted on the OLD, pre-pickup netId/entity, NOT
    -- the new bogusNetId the client just reported.
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.isNotNil(broadcast)
    t.equals(broadcast.target, -1, 'EndFetchCycle always broadcasts, unlike confirmFetchBallThrown\'s src-only reclaim instruction')
    t.equals(broadcast.args[1], oldNetId, 'must be the OLD netId -- see this handler\'s own doc comment for why this is deliberate, not a bug')
    t.isTrue(f.deletedEntities[oldHandle], 'the OLD (already client-deleted in reality, but still server-tracked) entity is what gets resolved+deleted')

    -- The carrier is told the carry ended.
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.isNotNil(endCarry)
    t.equals(endCarry.target, 2)
    t.equals(endCarry.args[2], true, 'terminal = true')

    -- Registry fully cleared.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'))
end)

t.test('confirmFetchBallCarried: a netId already claimed by a DIFFERENT citizenid\'s ball ends the cycle rather than create a collision, and does not touch the other citizenid\'s ball', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local otherNetId, otherHandle = throwSuccessfully(f, 9, 'ZZZ999', 5009, { x = 500, y = 500, z = 0 })

    local myNetId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, myNetId)

    -- Carrier's client reports the OTHER citizen's live netId as its own
    -- freshly-attached replacement.
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, otherNetId)

    t.isNil(f.deletedEntities[otherHandle], 'ZZZ999\'s real ball must never be deleted by ABC123\'s carry confirm')
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.equals(endCarry.target, 2)
end)

t.test('confirmFetchBallCarried: a non-matching carrierSrc/state is a silent no-op (e.g. the cycle already ended)', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1) -- ends the cycle out from under the carrier

    local before = #f.notifyCalls
    local newNetId = freshNetId()
    f.registerEntity(newNetId, newNetId + 700000, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, newNetId)
    t.equals(#f.notifyCalls, before, 'ball is gone -- silent no-op')
end)

t.test('confirmFetchBallCarried: success overwrites ball.netId with the NEW, real, currently-attached replacement', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    local mode = pickupSuccessfully(f, 2, 'BBB222', 5002, oldNetId, { x = 0, y = 0, z = 0 })
    t.equals(mode, 'attach')

    -- A subsequent releaseFetchBall/EndFetchCycle-driven delete must act on
    -- the NEW netId, not the stale old one, proving ball.netId really was
    -- overwritten by the successful confirm.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.isTrue(broadcast.args[1] ~= oldNetId, 'must be the NEW netId from the successful confirm, not the stale pre-pickup one')
end)

-- ----------------------------------------------------------------------
-- cancelFetchCarryAttach
-- ----------------------------------------------------------------------

t.test('cancelFetchCarryAttach: no pending is a silent no-op', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    f.dispatchNetEvent('john-k9:server:cancelFetchCarryAttach', 1)
    t.equals(#f.notifyCalls, 0)
end)

t.test('cancelFetchCarryAttach: ends the whole cycle (nothing tangible survives an attach failure)', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:cancelFetchCarryAttach', 2)

    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'))
end)

-- ----------------------------------------------------------------------
-- releaseFetchBall -- UNCONDITIONAL. No cooldown of any kind may gate it.
-- ----------------------------------------------------------------------

t.test('releaseFetchBall: still transitioning (PendingFetchCarries) is a silent no-op -- nothing to release yet', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)
    t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), 0)
end)

t.test('releaseFetchBall: not currently a carrier is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 1)
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('releaseFetchBall: NO CONFIG-DRIVEN COOLDOWN CAN BLOCK IT -- proven directly against the exact footgun (releaseCooldownMs = 0, which would fail-closed forever if consulted)', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake', releaseCooldownMs = 0 })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })

    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    -- Release IMMEDIATELY -- zero elapsed time since pickup. If any cooldown
    -- (a 0-threshold one fails CLOSED per server/cooldowns.lua's own
    -- documented behavior) were consulted here, this would silently do
    -- nothing.
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)
    t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), 1, 'release must succeed on the very first attempt, at t=0 since pickup')

    -- Pick the (now recreated, 'fake'-mode) ball back up and release again,
    -- immediately, with zero elapsed time since THIS release -- repeat
    -- several times. A permanently-blocking release cooldown would allow
    -- exactly one release ever; this proves there is no such ceiling.
    for i = 1, 3 do
        local dropNetId = freshNetId()
        f.registerEntity(dropNetId, dropNetId + 900000 + i, { coords = { x = 0, y = 0, z = 0 }, owner = 2 })
        f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, dropNetId)

        f.advance(PICKUP_COOLDOWN_MS + 1) -- only PickupCooldown needs to elapse -- a real, present, separate gate
        f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, dropNetId)
        t.equals(countClientEvents(f, 'john-k9:client:carryFetchBall'), i + 1)

        f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2) -- t=0 since this pickup -- must still succeed
        t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), i + 1, ('release #%d must succeed immediately, no advance since pickup'):format(i + 1))
    end
end)

t.test('releaseFetchBall: "fake" mode opens a PendingFetchDrops slot and sends endFetchCarry(mode, terminal=false)', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.equals(endCarry.target, 2)
    t.equals(endCarry.args[1], 'fake')
    t.equals(endCarry.args[2], false, 'terminal = false -- the cycle continues, just no longer carried')

    -- A confirm now completes the drop (PendingFetchDrops was opened).
    local dropNetId = freshNetId()
    f.registerEntity(dropNetId, dropNetId + 800000, { coords = { x = 0, y = 0, z = 0 } })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, dropNetId)

    -- The ball is pickup-able again (state == 'dropped').
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, dropNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.picked_up_success'))
end)

t.test('releaseFetchBall: "attach" mode does NOT open a PendingFetchDrops slot -- the physical entity already exists, nothing to recreate', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    pickupSuccessfully(f, 2, 'BBB222', 5002, oldNetId, { x = 0, y = 0, z = 0 })

    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.equals(endCarry.args[1], 'attach')
    t.equals(endCarry.args[2], false)

    -- confirmFetchBallDropped with no pending is a silent no-op -- proves no
    -- PendingFetchDrops slot was opened for 'attach' mode.
    local before = #f.notifyCalls
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, freshNetId())
    t.equals(#f.notifyCalls, before)
end)

t.test('releaseFetchBall: a stale CarrierIndex entry (ball missing/reassigned) is defensively cleared without erroring', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1) -- ends the cycle (itself sends ONE endFetchCarry, terminal=true, since the ball was still 'carried') -- CarrierIndex[2] cleanup is EndFetchCycle's own job, verified below
    local before = countClientEvents(f, 'john-k9:client:endFetchCarry')

    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2) -- must not error
    t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), before, 'CarrierIndex[2] was already cleared by EndFetchCycle -- nothing left to release, so no NEW endFetchCarry is sent')
end)

-- ----------------------------------------------------------------------
-- confirmFetchBallDropped -- 'fake'-mode drop confirm. Deliberately NEVER
-- calls NotifyPlayer on ANY branch (matches confirmFetchBallCarried's own
-- silent convention, per this handler's own doc comment) -- every assertion
-- below checks the 'john-k9:client:removeFetchBall' cleanup instruction,
-- never notify text.
-- ----------------------------------------------------------------------

t.test('confirmFetchBallDropped: a non-number netId is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 1, 'nope')
    t.equals(#f.clientEvents, 0)
end)

t.test('confirmFetchBallDropped: no matching pending is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 1, 123)
    t.equals(#f.clientEvents, 0)
end)

t.test('confirmFetchBallDropped: an expired pending sends a cleanup instruction ONLY when the reported netId is genuinely safe to reclaim', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2) -- PendingFetchDrops[2] opened

    local dropNetId = freshNetId()
    local dropHandle = dropNetId + 800000
    f.registerEntity(dropNetId, dropHandle, { coords = { x = 0, y = 0, z = 0 }, owner = 2 })

    f.advance(PENDING_THROW_TTL_MS + 1)
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, dropNetId)

    local cleanup = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.isNotNil(cleanup, 'a genuinely real, correctly-modeled, unclaimed object must be reclaimable even on a TTL rejection')
    t.equals(cleanup.target, 2)
    t.equals(cleanup.args[1], dropNetId)
    t.isNil(f.deletedEntities[dropHandle], 'this handler never calls DeleteEntity server-side -- client-instructed reclaim only')
end)

t.test('confirmFetchBallDropped: the ball no longer being in "dropped" state (recalled/changed in the meantime) sends no cleanup for a nonexistent target, but real cleanup for a real one', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2) -- ball.state == 'dropped', PendingFetchDrops[2] open, ball.carrierSrc == nil already

    -- A DIFFERENT K9 picks up the still-'dropped' ball (using its LAST
    -- KNOWN, still-stale netId, which is legitimately resolvable since
    -- nothing deleted it) before player 2's own drop-confirm arrives.
    f.setAccess(3, true)
    f.setPed(3, 5003, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(3, 'CCC333')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 3, netId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.picked_up_success'), 'the race must genuinely re-carry the ball for player 3')

    -- Player 2's stale drop-confirm now arrives, reporting a freshly
    -- recreated (but now-irrelevant) object.
    local staleDropNetId = freshNetId()
    local staleDropHandle = staleDropNetId + 800000
    f.registerEntity(staleDropNetId, staleDropHandle, { coords = { x = 0, y = 0, z = 0 }, owner = 2 })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, staleDropNetId)

    local cleanup = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.isNotNil(cleanup, 'this freshly-created, real, correctly-modeled, unclaimed object must still be reclaimed even though the ball state changed underneath it')
    t.equals(cleanup.target, 2)
    t.equals(cleanup.args[1], staleDropNetId)

    -- Player 3's real carry must be completely undisturbed by player 2's
    -- stale confirm -- releasing it now must produce exactly one NEW
    -- endFetchCarry event (player 3's own), not zero and not more than one.
    local beforeRelease = countClientEvents(f, 'john-k9:client:endFetchCarry')
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 3)
    t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), beforeRelease + 1, 'only player 3\'s own release, never affected by player 2\'s stale confirm')
end)

t.test('confirmFetchBallDropped: an entity that never resolves sends no cleanup instruction', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)

    -- Never register the recreated ball object.
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, freshNetId())
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'))
end)

t.test('confirmFetchBallDropped: a wrong-model entity sends no cleanup instruction (never trust an unverified model)', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)

    local dropNetId = freshNetId()
    local dropHandle = dropNetId + 800000
    f.registerEntity(dropNetId, dropHandle, { coords = { x = 0, y = 0, z = 0 }, model = WRONG_HASH })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, dropNetId)

    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'))
    t.isNil(f.deletedEntities[dropHandle])
end)

t.test('confirmFetchBallDropped: a netId already claimed by a DIFFERENT citizenid\'s ball sends NO cleanup instruction, and that other ball is untouched', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local otherNetId, otherHandle = throwSuccessfully(f, 9, 'ZZZ999', 5009, { x = 500, y = 500, z = 0 })

    local myNetId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, myNetId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)

    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, otherNetId)

    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'), 'never instruct a delete of an entity this citizenid does not own')
    t.isNil(f.deletedEntities[otherHandle], 'ZZZ999\'s real ball must never be touched by ABC123\'s rejected drop-confirm')
end)

t.test('confirmFetchBallDropped: success updates ball.netId silently (no notify), matching confirmFetchBallCarried\'s own convention', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2)

    local before = #f.notifyCalls
    local dropNetId = freshNetId()
    f.registerEntity(dropNetId, dropNetId + 800000, { coords = { x = 0, y = 0, z = 0 }, owner = 2 })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallDropped', 2, dropNetId)
    t.equals(#f.notifyCalls, before, 'no notify on the success path, by design')

    -- ball.netId really was overwritten -- a recall now broadcasts the NEW netId.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.args[1], dropNetId)
end)

-- ----------------------------------------------------------------------
-- requestDeliverFetchBall
-- ----------------------------------------------------------------------

t.test('requestDeliverFetchBall: a non-number targetServerId is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 1, 'nope')
    t.equals(#f.notifyCalls, 0)
end)

t.test('requestDeliverFetchBall: still transitioning (PendingFetchCarries) is a silent no-op', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    local before = #f.notifyCalls -- thrown_success + picked_up_success already counted here

    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 2, 1)
    t.equals(#f.notifyCalls, before, 'silent no-op -- nothing added')
end)

t.test('requestDeliverFetchBall: not currently carrying notifies "not carrying"', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 1, 2)
    t.equals(f.notifyCalls[1].description, locale('fetch.not_carrying'))
end)

t.test('requestDeliverFetchBall: delivering to anyone other than the real thrower is rejected', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.setPed(3, 5003, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 2, 3) -- 3 is not the thrower (1 is)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.wrong_deliver_target'))
end)

t.test('requestDeliverFetchBall: a disconnected carrier or handler ped is a silent no-op', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    -- The thrower (src 1) disconnects (ped no longer resolvable) without
    -- firing playerDropped in this test -- an edge race, not the normal path.
    local before = #f.notifyCalls
    -- Overwrite ped 1 to 0 directly via setPed with handle 0 is not
    -- representable through the public helper; simulate by having
    -- GetPlayerPed return 0 for src 1 -- easiest is to never have called
    -- setPed with a nonzero handle in the first place for a FRESH src.
    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 2, 999) -- unresolvable target id
    t.equals(#f.notifyCalls, before + 1, 'wrong_deliver_target fires first -- target id 999 was never the recorded thrower')
end)

t.test('requestDeliverFetchBall: too far from the handler\'s own live position is rejected', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    -- Handler (src 1) is far from the carrier (src 2) -- comfortably past
    -- deliverProximityMeters (3.0m).
    f.setPed(1, 5001, { x = 100.0, y = 0, z = 0 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 2, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.too_far_to_deliver'))
end)

t.test('requestDeliverFetchBall: success ends the cycle and notifies BOTH the carrier and the handler', function()
    local f = newFetchFixture()
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:requestDeliverFetchBall', 2, 1) -- handler ped 1 is at the same coords -- within tolerance

    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)

    local carrierNotify, handlerNotify
    for _, call in ipairs(f.notifyCalls) do
        if call.description == locale('fetch.delivered_success') then carrierNotify = call end
        if call.description == locale('fetch.delivered_notice_handler') then handlerNotify = call end
    end
    t.isNotNil(carrierNotify)
    t.equals(carrierNotify.target, 2)
    t.isNotNil(handlerNotify)
    t.equals(handlerNotify.target, 1)
end)

-- ----------------------------------------------------------------------
-- requestRecallFetchBall
-- ----------------------------------------------------------------------

t.test('requestRecallFetchBall: no active ball notifies "no active ball to recall"', function()
    local f = newFetchFixture()
    f.setPlayer(1, 'ABC123')
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[1].description, locale('fetch.no_active_ball_to_recall'))
end)

t.test('requestRecallFetchBall: only the real thrower may recall -- a citizenid mismatch (not this ball\'s own thrower source) is rejected', function()
    local f = newFetchFixture()
    throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setPlayer(2, 'ABC123') -- a second connection resolving to the SAME citizenid
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 2)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'), 'ball.throwerSrc is 1, not 2 -- reject')
end)

t.test('requestRecallFetchBall: success ends the cycle, deletes the entity, broadcasts removal, and notifies success', function()
    local f = newFetchFixture()
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.target, -1)
    t.equals(broadcast.args[1], netId)
end)

t.test('requestRecallFetchBall: recalling a CARRIED ball also tells the carrier its carry ended', function()
    local f = newFetchFixture()
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.equals(endCarry.target, 2)
    t.equals(endCarry.args[2], true, 'terminal = true')
end)

-- ----------------------------------------------------------------------
-- reportFetchCarrierDown
-- ----------------------------------------------------------------------

t.test('reportFetchCarrierDown: still transitioning is a silent no-op', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:reportFetchCarrierDown', 2)
    t.equals(countClientEvents(f, 'john-k9:client:endFetchCarry'), 0)
end)

t.test('reportFetchCarrierDown: not currently carrying is a silent no-op', function()
    local f = newFetchFixture()
    f.dispatchNetEvent('john-k9:server:reportFetchCarrierDown', 1)
    t.equals(#f.notifyCalls, 0)
end)

t.test('reportFetchCarrierDown: "fake" mode fully ends the cycle (nothing tangible can be left behind)', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.dispatchNetEvent('john-k9:server:reportFetchCarrierDown', 2)
    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.args[1], netId)
end)

t.test('reportFetchCarrierDown: "attach" mode degrades to a natural "dropped" state -- the ball entity still physically exists', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId, oldHandle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, oldNetId)
    -- Confirm the attach with a NEW, real replacement object -- this is the
    -- one the ball's registry actually tracks afterward (ball.netId is
    -- overwritten by a successful confirmFetchBallCarried), NOT the netId
    -- carried in the earlier 'john-k9:client:carryFetchBall' instruction
    -- (which still names the OLD, pre-pickup entity -- see this file's own
    -- STALE-BROADCAST-NETID doc comment on confirmFetchBallCarried).
    local newNetId = freshNetId()
    local newHandle = newNetId + 700000
    f.registerEntity(newNetId, newHandle, { coords = { x = 0, y = 0, z = 0 }, owner = 2 })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, newNetId)

    f.dispatchNetEvent('john-k9:server:reportFetchCarrierDown', 2)
    t.isNil(f.deletedEntities[oldHandle], 'attach mode degrades to dropped, not a full end -- nothing is deleted')
    t.isNil(f.deletedEntities[newHandle], 'the currently-attached real object must not be deleted either')
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.equals(endCarry.args[2], false, 'terminal = false')

    -- Ball is pickup-able again as 'dropped', at the NEW netId.
    f.setAccess(3, true)
    f.setPed(3, 5003, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(3, 'CCC333')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 3, newNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.picked_up_success'))
end)

-- ----------------------------------------------------------------------
-- Maintenance thread
-- ----------------------------------------------------------------------

t.test('maintenance thread: an absolute lifetime-expired ball is ended even with no other activity', function()
    local f = newFetchFixture()
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.primeMaintenance()
    f.advance(MAX_BALL_LIFETIME_MS + 1)
    f.stepMaintenance()

    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.args[1], netId)
end)

t.test('maintenance thread: a "thrown" ball whose entity has despawned (external deletion) is ended, not left to rot for the rest of maxBallLifetimeMs', function()
    local f = newFetchFixture()
    local _, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.removeExistence(handle) -- external despawn, not a recall/pickup/drop

    f.primeMaintenance()
    f.stepMaintenance()

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'), 'registry entry must already be gone')
end)

t.test('maintenance thread: a "carried" ball with a stale netId is left untouched by the despawn check (the transitional-window guard)', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId, oldHandle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    -- Mid-transition: PendingFetchCarries[2] is open, ball.state == 'carried',
    -- ball.netId is STILL the stale, pre-pickup oldNetId (never nil'd during
    -- this window -- see this file's own header STATE MACHINE note).
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, oldNetId)

    f.removeExistence(oldHandle) -- simulate the client having already deleted the OLD entity locally, as it really does mid-transition

    -- No time advance -- this proves item (b), the despawn re-check, not
    -- item (c), the PendingFetchCarries TTL sweep (covered by its own test
    -- below with a real time advance).
    f.primeMaintenance()
    f.stepMaintenance()

    -- Ball must survive this sweep -- state == 'carried' skips the despawn
    -- re-check entirely, by design. Proven directly (not through a gated
    -- action like reportFetchCarrierDown/releaseFetchBall, which are both
    -- ALSO gated on PendingFetchCarries and so cannot distinguish "the cycle
    -- survived" from "the cycle survived but is still mid-transition"): the
    -- attach transition itself can still be completed successfully.
    local newNetId = freshNetId()
    local newHandle = newNetId + 700000
    f.registerEntity(newNetId, newHandle, { coords = { x = 0, y = 0, z = 0 }, owner = 2 })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallCarried', 2, newNetId)

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'), 'the registry entry, and the successfully-confirmed carry, both survived the maintenance sweep')
    t.isTrue(f.deletedEntities[newHandle], 'the recall deletes the NEW (post-confirm) entity, proving the confirm above genuinely took effect')
end)

t.test("maintenance thread: an expired PendingFetchCarries entry force-ends the still-'carried' ball", function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId, oldHandle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, oldNetId) -- PendingFetchCarries[2] opened, never confirmed

    f.primeMaintenance()
    f.advance(PENDING_THROW_TTL_MS + 1)
    f.stepMaintenance()

    t.isTrue(f.deletedEntities[oldHandle], 'the maintenance sweep must force-end an unconfirmed attach transition rather than leave it in limbo forever')
    local endCarry = lastClientEvent(f, 'john-k9:client:endFetchCarry')
    t.equals(endCarry.target, 2)
    t.equals(endCarry.args[2], true)
end)

t.test('maintenance thread: an expired PendingFetchDrops entry simply clears the pending slot -- the ball itself stays "dropped"', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)
    f.dispatchNetEvent('john-k9:server:releaseFetchBall', 2) -- PendingFetchDrops[2] opened, ball.state == 'dropped', ball.netId stale == old netId

    f.primeMaintenance()
    f.advance(PENDING_THROW_TTL_MS + 1)
    f.stepMaintenance()

    -- No deletion/broadcast from THIS branch -- but the despawn check (b)
    -- runs in the same pass, and the stale netId (still the pre-pickup
    -- ball) is a real, still-existing entity, so it must survive.
    local recalledNotify
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    for i = #f.notifyCalls, 1, -1 do
        if f.notifyCalls[i].target == 1 then recalledNotify = f.notifyCalls[i]; break end
    end
    t.equals(recalledNotify.description, locale('fetch.recalled_success'), 'ball survived -- only the transitional PendingFetchDrops bookkeeping slot was cleared')
end)

t.test('maintenance thread: an expired PendingFetchThrows entry simply clears the pending slot', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)

    f.primeMaintenance()
    f.advance(PENDING_THROW_TTL_MS + 1)
    f.stepMaintenance()

    -- A confirm against the (now-expired-and-cleared) pending is a silent no-op.
    local instruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local netId = freshNetId()
    f.registerEntity(netId, netId + 500000, { coords = { x = instruction.args[1], y = instruction.args[2], z = instruction.args[3] } })
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, netId)
    t.equals(#f.notifyCalls, 0, 'PendingFetchThrows was cleared by the sweep -- this confirm now finds nothing')
end)

-- ----------------------------------------------------------------------
-- Lifecycle: playerDropped -- BOTH tracked roles (thrower AND carrier)
-- ----------------------------------------------------------------------

t.test('playerDropped: clears an in-flight pending throw for the disconnecting source', function()
    local f = newFetchFixture()
    f.setAccess(1, true)
    f.setPlayer(1, 'ABC123')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    f.firePlayerDropped(1)

    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, 12345)
    t.equals(#f.notifyCalls, 0, 'pending was cleared -- silent no-op')
end)

t.test('playerDropped (THROWER role): ends the entire cycle for the disconnecting handler, regardless of ball state', function()
    local f = newFetchFixture()
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.firePlayerDropped(1)

    t.isTrue(f.deletedEntities[handle])
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.args[1], netId)

    f.setPlayer(1, 'ABC123') -- reconnect, same citizenid
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'))
end)

t.test('playerDropped (CARRIER role, "fake" mode): fully ends the cycle for a DIFFERENT citizenid than the thrower', function()
    local f = newFetchFixture({ mouthCarryMode = 'fake' })
    local netId, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, netId)

    f.firePlayerDropped(2) -- the CARRIER disconnects, not the thrower

    t.isTrue(f.deletedEntities[handle], '"fake" mode carrier loss must fully end the cycle -- nothing tangible could be recreated by the now-gone client')
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.args[1], netId)

    -- Thrower (still connected, citizenid ABC123) has no active ball anymore.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'))
end)

t.test('playerDropped (CARRIER role, "attach" mode, ALREADY CONFIRMED): degrades to "dropped" -- the entity is left in the world, not deleted', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    pickupSuccessfully(f, 2, 'BBB222', 5002, oldNetId, { x = 0, y = 0, z = 0 })

    -- Find the NEW, confirmed entity's handle so we can prove it survives.
    local carryEvent = lastClientEvent(f, 'john-k9:client:carryFetchBall')
    local newNetId = carryEvent.args[1]

    f.firePlayerDropped(2)

    t.isNil(f.deletedEntities[newNetId + 700000], 'a CONFIRMED attach-mode carry degrades to dropped on carrier disconnect -- the real object is left behind, per this handler\'s own documented reasoning')

    -- Thrower's ball is still active (now 'dropped'), recallable.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

t.test('playerDropped (CARRIER role, "attach" mode, STILL TRANSITIONING/UNCONFIRMED): the TWO-PHASE FIX -- must fully end the cycle, not degrade to "dropped" (a prior `not ball.netId` check here was dead code)', function()
    local f = newFetchFixture({ mouthCarryMode = 'attach' })
    local oldNetId, oldHandle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setAccess(2, true)
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0, K9_PED_HASH)
    f.setPlayer(2, 'BBB222')
    f.dispatchNetEvent('john-k9:server:requestPickupFetchBall', 2, oldNetId) -- PendingFetchCarries[2] opened, NEVER confirmed

    f.firePlayerDropped(2)

    -- The discriminator MUST be PendingFetchCarries[2] (captured before it's
    -- cleared), never `not ball.netId` -- ball.netId is STILL the old,
    -- pre-pickup value at this point (never nil'd during the transition, per
    -- this file's own header STATE MACHINE note), so a `not ball.netId`
    -- check would have wrongly taken the "degrade to dropped" branch here.
    t.isTrue(f.deletedEntities[oldHandle], 'an unconfirmed attach-mode transition must fully end the cycle on disconnect, not degrade to dropped')
    local broadcast = lastClientEvent(f, 'john-k9:client:removeFetchBall')
    t.equals(broadcast.args[1], oldNetId)

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'), 'the whole cycle, including the registry entry, is really gone')
end)

t.test('playerDropped: a mismatched citizenid\'s connection dropping does not disturb another citizenid\'s own active ball', function()
    local f = newFetchFixture()
    local _, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.setPlayer(99, 'ZZZ999') -- unrelated connection
    f.firePlayerDropped(99)

    t.isNil(f.deletedEntities[handle])
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

-- ----------------------------------------------------------------------
-- Lifecycle: onResourceStop
-- ----------------------------------------------------------------------

t.test('onResourceStop: ignores a stop event for a different resource', function()
    local f = newFetchFixture()
    local _, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.fireResourceStop('some_other_resource')
    t.isNil(f.deletedEntities[handle])
end)

t.test('onResourceStop: deletes every remaining ball entity, but does NOT broadcast a removal', function()
    local f = newFetchFixture()
    local _, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    for i = #f.clientEvents, 1, -1 do f.clientEvents[i] = nil end

    f.fireResourceStop('john-k9')
    t.isTrue(f.deletedEntities[handle])
    t.equals(#f.clientEvents, 0, 'no broadcast on this path, per the source\'s own comment on why one would be unreliable busywork here')
end)

t.test('onResourceStop: a stale ball entry (entity already gone) is skipped without erroring', function()
    local f = newFetchFixture()
    local _, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    f.removeExistence(handle)
    f.fireResourceStop('john-k9') -- must not throw
    t.isNil(f.deletedEntities[handle], 'never resolved, so DeleteEntity is never called on it')
end)

-- ----------------------------------------------------------------------
-- CROSS-FEATURE NETID GAP, THE MIRROR CASE (coder-architect, this pass) --
-- see kennel_spec.lua's own identical-purpose section for the fuller
-- writeup (this is the same fix, exercised from the OPPOSITE direction: an
-- attacker's FETCH confirm naming a victim's real, live KENNEL). Config.lua
-- configures Config.DeployableKennel.fallbackPropModel and
-- Config.FetchMechanic.ballPropModel to the IDENTICAL 'prop_tennis_ball', so
-- this section is STRICTLY MORE DANGEROUS than the kennel-side one:
-- confirmFetchBallThrown has NO positional/distance check at all (this
-- file's own doc comment on that handler explains why -- a thrown, physics-
-- simulated ball's resting position legitimately moves), so the THEFT shape
-- (not just deletion) is reachable with nothing but the netId, no proximity
-- to the victim required whatsoever.
--
-- newCombinedFixture() below loads the REAL, unmodified server/fetch.lua AND
-- server/kennel.lua into ONE shared env (same load order fxmanifest.lua
-- requires) so both genuinely share ONE server/entities.lua
-- ClaimedNetworkEntities instance.
-- ----------------------------------------------------------------------

--- @return table fixture -- same shape as newFetchFixture()'s own return,
--- so lastClientEvent/countClientEvents/throwSuccessfully/freshNetId are all
--- reusable unchanged.
local function newCombinedFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local function IsConfiguredK9Model(hash) return hash == K9_PED_HASH end

    local playersBySource = {}
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = playersBySource[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid } }
            end,
        },
    }

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByHandle = {}
    local function GetEntityCoords(handle) return coordsByHandle[handle] or vec3(0, 0, 0) end

    local headingByHandle = {}
    local function GetEntityHeading(handle) return headingByHandle[handle] or 0.0 end

    local networkEntities = {}
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {}
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {}
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local entityModels = {}
    local function GetEntityModel(handle) return entityModels[handle] end

    local entityOwners = {}
    local function NetworkGetEntityOwner(handle) return entityOwners[handle] end

    local deletedEntities = {}
    local function DeleteEntity(handle) deletedEntities[handle] = true end

    -- kennel.lua's own model constants -- distinct from BALL_HASH so the
    -- "wrong model" class of check stays meaningful, but its FALLBACK model
    -- is the SAME 'prop_tennis_ball' string as BALL_MODEL, mirroring
    -- config.lua's own real configuration exactly -- the entire precondition
    -- for the cross-feature gap this section proves closed.
    local KENNEL_PROP_MODEL = 'prop_dog_cage_01'

    local config = {
        Features = { FetchMechanic = true, DeployableKennel = true },
        FetchMechanic = {
            ballPropModel = BALL_MODEL,
            throwForwardOffsetMeters = 1.0,
            throwUpOffsetMeters = 1.2,
            throwForceForward = 12.0,
            throwForceUp = 6.0,
            throwCooldownMs = THROW_COOLDOWN_MS,
            pendingThrowTtlMs = PENDING_THROW_TTL_MS,
            maxBallLifetimeMs = MAX_BALL_LIFETIME_MS,
            pickupInteractDistanceMeters = PICKUP_INTERACT_DIST,
            deliverProximityMeters = DELIVER_PROXIMITY,
            maintenanceIntervalMs = MAINTENANCE_INTERVAL_MS,
            mouthCarryMode = 'fake',
            mouthBoneIndex = 0,
            mouthOffsetX = 0.0, mouthOffsetY = 0.0, mouthOffsetZ = 0.0,
            pickupCooldownMs = PICKUP_COOLDOWN_MS,
        },
        DeployableKennel = {
            propModel = KENNEL_PROP_MODEL,
            fallbackPropModel = BALL_MODEL, -- 'prop_tennis_ball' -- SAME string as fetch's own ball model, on purpose
            placementForwardOffsetMeters = 2.0,
            deployCooldownMs = 5000,
            pendingPlacementTtlMs = 15000,
        },
    }

    -- fetch.lua's maintenance thread is never stepped in this section -- a
    -- genuine no-op CreateThread (never calling its argument) is simpler
    -- than wiring the coroutine-based thread runner for a thread this
    -- section has no use for.
    local function CreateThread(_fn) end

    -- CLOSEABLE KENNEL (server/kennel.lua, coder-backend's own
    -- command-consolidation pass) -- that file now registers ONE
    -- lib.callback ('john-k9:server:getOwnKennelDoorState') at file-load
    -- time, unconditionally -- same stub shape tests/kennel_spec.lua's own
    -- fixtures already carry for the identical need. Not exercised by any
    -- test in THIS section (no test here drives that callback), but must
    -- exist so server/kennel.lua loads without erroring at all.
    local LibStub = {
        callback = {
            register = function() end,
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        IsConfiguredK9Model = IsConfiguredK9Model,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHeading = GetEntityHeading,
        GetHashKey = GetHashKey,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityModel = GetEntityModel,
        NetworkGetEntityOwner = NetworkGetEntityOwner,
        DeleteEntity = DeleteEntity,
        CreateThread = CreateThread,
        Config = config,
        lib = LibStub,
    })

    -- Same load order fxmanifest.lua's server_scripts list requires:
    -- cooldowns.lua, entities.lua, THEN kennel.lua and fetch.lua -- both
    -- feature files sharing the ONE server/entities.lua instance loaded here
    -- is the entire point of this fixture.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/kennel.lua', env)
    Sandbox.loadInto('../server/fetch.lua', env)

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        deletedEntities = deletedEntities,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        netEventNames = netEvents,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setPlayer = function(src, citizenid) playersBySource[src] = citizenid end,
        setPed = function(src, pedHandle, coords, heading, modelHash)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = vec3(coords.x, coords.y, coords.z)
            headingByHandle[pedHandle] = heading or 0.0
            entityModels[pedHandle] = modelHash or K9_PED_HASH
        end,
        registerEntity = function(netId, handle, ropts)
            ropts = ropts or {}
            networkEntities[netId] = handle
            existingEntities[handle] = ropts.exists ~= false
            entityTypes[handle] = ropts.entityType or 3
            -- Defaults to BALL_HASH ('prop_tennis_ball') -- this fixture's
            -- whole point is the model kennel's fallback and fetch's ball
            -- SHARE, so an entity registered with no explicit `model` must
            -- credibly be either feature's own real object by default.
            entityModels[handle] = ropts.model or BALL_HASH
            entityOwners[handle] = ropts.owner
            local c = ropts.coords or { x = 0, y = 0, z = 0 }
            coordsByHandle[handle] = vec3(c.x, c.y, c.z)
        end,
        setEntityOwner = function(handle, src) entityOwners[handle] = src end,
        removeExistence = function(handle) existingEntities[handle] = false end,
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
    }
end

--- Drives a full, successful requestDeployKennel -> confirmKennelPlaced
--- handshake against the REAL server/kennel.lua loaded into the SAME
--- combined fixture, producing a genuine, live victim kennel this section's
--- fetch-confirm attacks can then target by netId.
--- @param f table
--- @param src number
--- @param citizenid string
--- @param pedHandle number
--- @param pedCoords table
--- @return number netId, number entityHandle
local function deployKennelSuccessfully(f, src, citizenid, pedHandle, pedCoords)
    f.setAccess(src, true)
    f.setPlayer(src, citizenid)
    f.setPed(src, pedHandle, pedCoords, 0.0)
    f.dispatchNetEvent('john-k9:server:requestDeployKennel', src)
    local instruction = lastClientEvent(f, 'john-k9:client:deployKennelAt')
    assert(instruction, 'requestDeployKennel did not send a deployKennelAt instruction')
    local x, y, z = instruction.args[1], instruction.args[2], instruction.args[3]
    local netId = freshNetId()
    local objectHandle = netId + 900000 -- distinct offset from throwSuccessfully's own +500000, so a kennel and a fetch ball in the same test never collide on entity handle
    f.registerEntity(netId, objectHandle, { coords = { x = x, y = y, z = z }, owner = src })
    f.dispatchNetEvent('john-k9:server:confirmKennelPlaced', src, netId)
    return netId, objectHandle
end

t.test('CROSS-FEATURE: confirmFetchBallThrown\'s TTL-expiry rejection naming a DIFFERENT citizenid\'s real, live KENNEL does NOT delete it', function()
    local f = newCombinedFixture()
    local victimKennelNetId, victimKennelHandle = deployKennelSuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })

    -- Attacker opens their own pending throw, creates nothing real, lets it
    -- TTL-expire, then reports the VICTIM's real, live kennel's netId.
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 5000, y = 5000, z = 500 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 2)
    f.advance(PENDING_THROW_TTL_MS + 1)
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 2, victimKennelNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.throw_timed_out'), 'the attacker still gets a genuine rejection, just never a destructive one')
    t.isNil(f.deletedEntities[victimKennelHandle], 'the victim\'s real, live kennel must survive an attacker naming it from a FETCH confirm')
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'), 'no cleanup instruction may ever be sent for an entity server/fetch.lua does not own')

    -- The victim's kennel is provably still intact and pickup-able through
    -- server/kennel.lua's own, completely independent code path.
    f.dispatchNetEvent('john-k9:server:requestPickupKennel', 1, victimKennelNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('CROSS-FEATURE, THE MORE SEVERE SHAPE (no positional check at all): confirmFetchBallThrown\'s plain SUCCESS PATH must not silently register a victim\'s real, live KENNEL as the attacker\'s own thrown ball', function()
    local f = newCombinedFixture()
    local victimKennelNetId, victimKennelHandle = deployKennelSuccessfully(f, 1, 'VICTIM01', 5001, { x = 0, y = 0, z = 0 })

    -- Attacker throws from anywhere -- confirmFetchBallThrown has NO
    -- positional check at all, so proximity to the victim is irrelevant.
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 9999, y = 9999, z = 999 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 2)
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 2, victimKennelNetId)

    -- Must be REJECTED, not silently written into FetchBalls as the
    -- attacker's own thrown ball.
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.placement_failed_already_tracked'), 'must be rejected, not silently registered as a genuine new thrown ball')
    t.isNil(f.deletedEntities[victimKennelHandle])
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'))

    -- PROOF the write never happened: the attacker's own requestRecallFetchBall
    -- must say "no active ball", never actually succeed and delete the
    -- victim's real kennel.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 2)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'))
    t.isNil(f.deletedEntities[victimKennelHandle], 'the attacker must never be able to delete the victim\'s kennel via a bogus "recall" of their own non-existent ball')

    -- The victim's kennel remains genuinely theirs: they can still pick it
    -- up. This used to assert the entity was DELETED on pickup, which was
    -- true until the kennel became something a K9 can sit inside and a
    -- handler can carry away with the dog still in it. Deleting it now
    -- would destroy an object with a player attached to it, so pickup
    -- keeps the same object alive and carries it. The security property
    -- this test exists to prove is untouched -- what changed is only what
    -- a successful pickup does to the entity afterwards.
    f.dispatchNetEvent('john-k9:server:requestPickupKennel', 1, victimKennelNetId)
    t.isNil(f.deletedEntities[victimKennelHandle], 'a pickup carries the kennel, it does not delete it -- an occupant could be inside')
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('kennel.picked_up_success'))
end)

t.test('CROSS-FEATURE: a legitimate fetch throw is entirely unaffected by an UNRELATED citizen\'s own live kennel existing elsewhere', function()
    local f = newCombinedFixture()
    deployKennelSuccessfully(f, 9, 'BYSTANDER9', 5009, { x = 9000, y = 9000, z = 0 })

    -- An honest handler's own, genuine throw must succeed exactly as it does
    -- with no kennel in play at all.
    local _, handle = throwSuccessfully(f, 1, 'ABC123', 5001, { x = 0, y = 0, z = 0 })
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.thrown_success'))

    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.isTrue(f.deletedEntities[handle])
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

-- ----------------------------------------------------------------------
-- PRE-CONFIRMATION-WINDOW RACE (coder-architect, urgent red-team finding
-- this pass) -- see kennel_spec.lua's own identical-purpose section for the
-- fuller writeup. Every test ABOVE this point (and every same-feature test
-- earlier in this file) that names a "victim's real ball" builds it via
-- throwSuccessfully, i.e. the victim's OWN confirm has ALREADY landed. This
-- section instead drives the victim only as far as "client created a real
-- object, no confirm sent yet" before the attacker acts -- the narrower,
-- more dangerous window neither FindOtherBallByNetId nor
-- IsNetworkEntityClaimedByOther can close, because neither registry is
-- written until a confirm SUCCEEDS.
-- ----------------------------------------------------------------------

t.test('PRE-CONFIRMATION-WINDOW: an attacker confirming a victim\'s real, NOT-YET-CONFIRMED thrown ball BEFORE the victim\'s own confirm arrives cannot delete it (deletion shape)', function()
    local f = newFetchFixture()

    -- Victim: requestThrowFetchBall already ran, their client already
    -- created the real object -- but confirmFetchBallThrown has NOT been
    -- called yet.
    f.setAccess(1, true)
    f.setPlayer(1, 'VICTIM01')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    local victimInstruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local victimNetId = freshNetId()
    local victimHandle = victimNetId + 500000
    f.registerEntity(victimNetId, victimHandle, {
        coords = { x = victimInstruction.args[1], y = victimInstruction.args[2], z = victimInstruction.args[3] },
        owner = 1,
    })

    -- Attacker: their OWN pending slot, creates nothing real -- races a
    -- confirm naming the victim's netId before the victim's own confirm ever
    -- fires, then gets decertified before their own confirm lands (a plain,
    -- no-time-advance-needed rejection branch -- a real TTL-expiry advance
    -- here would ALSO expire the victim's own still-pending throw, since
    -- both use the identical pendingThrowTtlMs and this fixture's
    -- GetGameTimer is shared/global, which would corrupt this test's own
    -- "victim's later confirm still succeeds" assertion below for a reason
    -- unrelated to what this test is actually proving).
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 5002, { x = 0, y = 0, z = 0 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 2)
    f.setAccess(2, false) -- decertified between the attacker's own throw and their bogus confirm
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 2, victimNetId)

    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.not_authorized_equipment'))
    t.isNil(f.deletedEntities[victimHandle], 'the victim\'s real object, not yet even confirmed by its own owner, must survive an attacker racing in first')
    t.isNil(lastClientEvent(f, 'john-k9:client:removeFetchBall'))

    -- The victim's OWN, genuine confirm -- arriving SECOND -- must still
    -- succeed normally.
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, victimNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.thrown_success'))
end)

t.test('PRE-CONFIRMATION-WINDOW: an attacker confirming a victim\'s real, NOT-YET-CONFIRMED thrown ball IMMEDIATELY cannot steal it (theft shape -- the plain success path, no proximity needed at all)', function()
    local f = newFetchFixture()

    f.setAccess(1, true)
    f.setPlayer(1, 'VICTIM01')
    f.setPed(1, 5001, { x = 0, y = 0, z = 0 })
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 1)
    local victimInstruction = lastClientEvent(f, 'john-k9:client:throwFetchBallAt')
    local victimNetId = freshNetId()
    local victimHandle = victimNetId + 500000
    f.registerEntity(victimNetId, victimHandle, {
        coords = { x = victimInstruction.args[1], y = victimInstruction.args[2], z = victimInstruction.args[3] },
        owner = 1,
    })

    -- Attacker races their own confirm in FIRST, from anywhere -- this
    -- handler has no distance check to accidentally narrow the window.
    f.setAccess(2, true)
    f.setPlayer(2, 'ATTACKER1')
    f.setPed(2, 9999, { x = 9999, y = 9999, z = 999 }, 0.0)
    f.dispatchNetEvent('john-k9:server:requestThrowFetchBall', 2)
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 2, victimNetId)

    -- Must be rejected -- NOT silently registered as FetchBalls[ATTACKER1].
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.placement_failed_already_tracked'), 'the NETWORK-OWNERSHIP GUARD rejects this on the plain success path, no proximity or timing needed at all')
    t.isNil(f.deletedEntities[victimHandle])

    -- PROOF the write never happened.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 2)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.no_active_ball_to_recall'))
    t.isNil(f.deletedEntities[victimHandle])

    -- The victim's OWN, genuine confirm -- arriving SECOND -- still succeeds
    -- normally: the attacker's bogus confirm never claimed anything for it
    -- to collide with.
    f.dispatchNetEvent('john-k9:server:confirmFetchBallThrown', 1, victimNetId)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.thrown_success'))

    -- HARD CONSTRAINT check -- not stranded either: the victim can still end
    -- their own, now-properly-registered cycle through the ordinary recall
    -- path.
    f.dispatchNetEvent('john-k9:server:requestRecallFetchBall', 1)
    t.isTrue(f.deletedEntities[victimHandle])
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('fetch.recalled_success'))
end)

os.exit(t.summary())
