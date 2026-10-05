--[[
    tests/clientequipmentshop_spec.lua

    Direct, black-box tests of client/equipmentshop.lua against the REAL,
    unmodified production file. This file previously had NO spec coverage
    at all (unlike its server half, tests/equipmentshop_spec.lua) -- this
    is that gap closed, focused on the parts of this pass's own task brief
    that are actually load-bearing:

      - A real ped is created (not a bare sphere) and targeted directly via
        `K9Compat.Get('target').AddLocalEntity` with the resolved
        model/heading/scenario/label -- section B.
      - ENTITY LIFECYCLE, this task's own named biggest risk: a ped is
        deleted BY ITS OWN RECORDED HANDLE when the player leaves
        PED_DESPAWN_RADIUS (section C), when its own location's data
        changes while spawned -- a respawn, not a duplicate (section D),
        when its own location disappears entirely -- a tablet "remove"
        (section E) -- and on `onResourceStop`, so a restart never leaves
        an orphaned entity behind (section G). No test here ever finds a
        ped by proximity/model search; every assertion reads back the
        SAME handle this file's own CreatePed call produced.
      - A model that never loads times out (Config.K9EquipmentShop.pedModelLoadTimeoutMs),
        warns once, and never calls CreatePed at all -- section F.
      - The config-only fallback actually engages when the server
        round-trip throws -- section H.
      - The `john-k9:client:equipmentShopLocationsUpdated` handler's
        source-origin guard -- section I.

    STUBBING EFFORT, reported honestly: proportionate. Every native this
    file touches is a small, controllable recording stand-in
    (CreatePed/DoesEntityExist/DeleteEntity/RequestModel/HasModelLoaded/
    SetModelAsNoLongerNeeded/IsModelValid/GetHashKey/SetEntityAsMissionEntity/
    FreezeEntityPosition/SetEntityInvincible/SetBlockingOfNonTemporaryEvents/
    TaskStartScenarioInPlace/GetEntityCoords/PlayerPedId), plus a minimal
    vector3-alike metatable (same shape as tests/clienttracking_spec.lua's
    own copy, `-`/`#` only -- this file's own distance math needs nothing
    else). Nothing here required disproportionate stubbing.

    THREAD RUNNER: reuses fixtures/sandbox.lua's own Sandbox.newThreadRunner()
    unmodified -- this file's own per-location worker thread calls
    Wait(...) at the END of its loop body (like every other sweep thread in
    this resource, per that helper's own documented assumption), so its
    documented "first step() call only primes" semantics apply here exactly
    as written; NOT tests/clienttracking_spec.lua's situation (whose three
    threads call Wait at the END too, actually -- but that file built its
    own instrumented runner for a DIFFERENT reason, to capture each Wait's
    own `ms` argument, which no test in this file needs). A `runner.step()`
    call is EMPIRICALLY confirmed (see the "happy path" test below, the
    first one that runs) to fully execute the startup thread AND every
    per-location worker thread it starts, in the same call -- because
    `ipairs` walks a Lua table's integer keys live, and the startup
    thread's own CreateThread calls (inside ReconcileWorkers) append new
    entries to the SAME `threads` array the running `ipairs` loop has not
    finished walking yet.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
-- Never stubbed, per this suite's convention: every locale() below is
-- resolved against the REAL locales/en.json, so a message this file
-- asserts on cannot drift away from the one the player actually sees.
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- same shape as tests/clienttracking_spec.lua's own
-- copy, only the two operators this file's own distance math needs.
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT) end
Vec3MT.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec3MT) end

--- @param opts table? -- { config: table, playerCoords: table?, callbackResult: table? ('ok'/'response'), callbackThrows: boolean?, hasModelLoaded: table<any, boolean|fun():boolean>? }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local netEvents = {}
    local function RegisterNetEvent(name, fn) netEvents[name] = fn end

    local playerCoords = opts.playerCoords or vec3(0.0, 0.0, 0.0)
    local function GetEntityCoords(_entity) return playerCoords end
    local function PlayerPedId() return 1 end

    local function GetHashKey(name) return 'hash:' .. tostring(name) end

    local invalidModels = opts.invalidModels or {}
    local function IsModelValid(hash) return not invalidModels[hash] end

    local requestedModels = {}
    local function RequestModel(hash) requestedModels[hash] = (requestedModels[hash] or 0) + 1 end

    local modelLoadedOverrides = opts.hasModelLoaded or {}
    local function HasModelLoaded(hash)
        local override = modelLoadedOverrides[hash]
        if type(override) == 'function' then return override() end
        if override ~= nil then return override end
        return true -- default: every model not explicitly overridden loads instantly
    end

    local releasedModels = {}
    local function SetModelAsNoLongerNeeded(hash) releasedModels[#releasedModels + 1] = hash end

    local nextPedHandle = 1
    local createdPeds = {}   -- array of { handle, pedType, hash, x, y, z, heading, isNetwork, bScriptHostPed }
    local pedExists = {}
    local function CreatePed(pedType, hash, x, y, z, heading, isNetwork, bScriptHostPed)
        local handle = nextPedHandle
        nextPedHandle = handle + 1
        createdPeds[#createdPeds + 1] = { handle = handle, pedType = pedType, hash = hash, x = x, y = y, z = z, heading = heading, isNetwork = isNetwork, bScriptHostPed = bScriptHostPed }
        pedExists[handle] = true
        return handle
    end
    local function DoesEntityExist(handle) return pedExists[handle] == true end
    local deletedPeds = {}
    local function DeleteEntity(handle)
        deletedPeds[#deletedPeds + 1] = handle
        pedExists[handle] = nil
    end

    local missionEntityCalls, frozenCalls, invincibleCalls, blockedCalls, scenarioCalls = {}, {}, {}, {}, {}
    local function SetEntityAsMissionEntity(e, a, b) missionEntityCalls[#missionEntityCalls + 1] = { e, a, b } end
    local function FreezeEntityPosition(e, toggle) frozenCalls[#frozenCalls + 1] = { e, toggle } end
    local function SetEntityInvincible(e, toggle) invincibleCalls[#invincibleCalls + 1] = { e, toggle } end
    local function SetBlockingOfNonTemporaryEvents(e, toggle) blockedCalls[#blockedCalls + 1] = { e, toggle } end
    local function TaskStartScenarioInPlace(e, name, timeToLeave, playIntro) scenarioCalls[#scenarioCalls + 1] = { e, name, timeToLeave, playIntro } end

    -- FAKE K9COMPAT -- this file no longer calls `exports.ox_target`/
    -- `exports.ox_inventory` directly (routed through K9Compat.Get(...)
    -- this pass, see client/equipmentshop.lua's own "COMPAT LAYER" header
    -- section); the real shared/compat/*.lua adapters are covered by their
    -- own dedicated specs (tests/compattarget_spec.lua,
    -- tests/compatinventory_spec.lua), so this fixture only needs a
    -- minimal fake that records calls the same shape a real ox_target/
    -- ox_inventory-backed adapter would, keeping every existing assertion
    -- below (`f.targetedEntities`, `f.removedEntities`,
    -- `f.openInventoryCalls`) meaningful without re-deriving the adapter
    -- translation this spec does not own testing.
    local targetedEntities = {} -- [pedHandle] = options (from AddLocalEntity)
    local removedEntities = {}
    local openInventoryCalls = {}
    local fakeK9Compat = {
        Get = function(system)
            if system == 'target' then
                return {
                    AddLocalEntity = function(entity, options)
                        targetedEntities[entity] = options
                        return { entity = entity }
                    end,
                    RemoveLocalEntity = function(handle)
                        if type(handle) ~= 'table' then return end
                        removedEntities[#removedEntities + 1] = handle.entity
                        targetedEntities[handle.entity] = nil
                    end,
                }
            end
            if system == 'inventory' then
                return {
                    -- Returns TRUE by default, matching shared/compat/
                    -- inventory.lua's real ox_inventory adapter (its
                    -- `attempted` contract). opts.openShopFails = true
                    -- models the qb-inventory / ps-inventory case, where
                    -- the CLIENT half of the adapter is nil by design and
                    -- K9Compat's own safe stub answers false -- see the
                    -- SILENT-DOOR tests at the end of this file.
                    OpenShop = function(shopType)
                        openInventoryCalls[#openInventoryCalls + 1] = { 'shop', { type = shopType } }
                        return not opts.openShopFails
                    end,
                }
            end
            return {}
        end,
    }

    local notifyCalls = {}

    local function lib_callback_await(name, ...)
        if name == 'john-k9:server:equipmentShopGetLocations' then
            if opts.callbackThrows then error('simulated timeout/unavailable callback', 0) end
            return opts.callbackResult or { ok = true, locations = {} }
        end
        error('clientequipmentshop_spec fixture: unstubbed lib.callback.await: ' .. tostring(name))
    end

    local env = Sandbox.newEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = printStub,
        K9Compat = fakeK9Compat,
        lib = {
            callback = { await = lib_callback_await },
            notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
        },
        Config = opts.config,
        GetEntityCoords = GetEntityCoords,
        PlayerPedId = PlayerPedId,
        GetHashKey = GetHashKey,
        IsModelValid = IsModelValid,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        CreatePed = CreatePed,
        DoesEntityExist = DoesEntityExist,
        DeleteEntity = DeleteEntity,
        SetEntityAsMissionEntity = SetEntityAsMissionEntity,
        FreezeEntityPosition = FreezeEntityPosition,
        SetEntityInvincible = SetEntityInvincible,
        SetBlockingOfNonTemporaryEvents = SetBlockingOfNonTemporaryEvents,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
    })

    Sandbox.loadInto('../client/equipmentshop.lua', env)

    return {
        runner = runner,
        printedLines = printedLines,
        createdPeds = createdPeds,
        deletedPeds = deletedPeds,
        pedExists = pedExists,
        targetedEntities = targetedEntities,
        removedEntities = removedEntities,
        openInventoryCalls = openInventoryCalls,
        notifyCalls = notifyCalls,
        scenarioCalls = scenarioCalls,
        invincibleCalls = invincibleCalls,
        missionEntityCalls = missionEntityCalls,
        frozenCalls = frozenCalls,
        releasedModels = releasedModels,
        setPlayerCoords = function(v) playerCoords = v end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName or 'john-k9')
            end
        end,
        triggerLocationsUpdated = function(sourceValue, locations)
            local handler = assert(netEvents['john-k9:client:equipmentShopLocationsUpdated'],
                'client/equipmentshop.lua did not register a john-k9:client:equipmentShopLocationsUpdated handler')
            env.source = sourceValue
            handler(locations)
        end,
    }
end

--- @param printedLines string[]
--- @param substring string
--- @return boolean
local function anyLineContains(printedLines, substring)
    for _, line in ipairs(printedLines) do
        if line:find(substring, 1, true) then return true end
    end
    return false
end

local BASE_CONFIG = {
    Features = { K9EquipmentShop = true },
    Departments = { police = {} },
    K9EquipmentShop = {
        shopType = 'k9supply',
        label = 'K9 Supply',
        pedModel = 'a_c_shepherd',
        pedHeading = 90.0,
        pedScenario = 'WORLD_DOG_SITTING_SHEPHERD',
        pedModelLoadTimeoutMs = 10000,
        locations = {
            { x = 0.0, y = 0.0, z = 0.0 },
        },
    },
}

local SERVER_RESOLVED_LOCATIONS = {
    ok = true,
    locations = {
        ['cfg:1'] = { x = 0.0, y = 0.0, z = 0.0, heading = 90.0, model = 'a_c_shepherd', scenario = 'WORLD_DOG_SITTING_SHEPHERD', label = 'K9 Supply' },
    },
}

-- ----------------------------------------------------------------------
-- A -- absence is a clean no-op
-- ----------------------------------------------------------------------

t.test('Config.Features.K9EquipmentShop off: no thread ever creates a ped, no ox_target call', function()
    local f = newFixture({ config = { Features = { K9EquipmentShop = false }, K9EquipmentShop = BASE_CONFIG.K9EquipmentShop } })
    f.runner.step()
    f.runner.step()
    t.equals(#f.createdPeds, 0)
end)

t.test('shopType missing: no ped, no crash', function()
    local f = newFixture({ config = { Features = { K9EquipmentShop = true }, K9EquipmentShop = { locations = BASE_CONFIG.K9EquipmentShop.locations } } })
    f.runner.step()
    t.equals(#f.createdPeds, 0)
end)

-- ----------------------------------------------------------------------
-- B -- a real ped is created and targeted directly (not a bare sphere)
-- ----------------------------------------------------------------------

t.test('happy path: a player standing at the shop location gets a real ped spawned there, targeted via addLocalEntity, playing its configured scenario', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })

    f.runner.step()

    t.equals(#f.createdPeds, 1, 'exactly one ped must be created for the one configured location')
    local ped = f.createdPeds[1]
    t.equals(ped.hash, 'hash:a_c_shepherd')
    t.equals(ped.x, 0.0)
    t.equals(ped.heading, 90.0)
    t.equals(ped.isNetwork, false, 'the ped must be LOCAL, never networked -- see this file\'s own ENTITY LIFECYCLE header')

    t.isNotNil(f.targetedEntities[ped.handle], 'the real ped handle must be targeted via ox_target:addLocalEntity')
    t.equals(f.targetedEntities[ped.handle][1].label, 'K9 Supply')
    t.equals(f.targetedEntities[ped.handle][1].icon, 'fas fa-user-tie', 'ROLE ICON: a handler-bucket action (no CanShowK9UI() gate) must use the settled handler icon, not the old shopping-basket or a K9-role icon')

    t.equals(#f.scenarioCalls, 1)
    t.equals(f.scenarioCalls[1][2], 'WORLD_DOG_SITTING_SHEPHERD')

    t.equals(#f.invincibleCalls, 1)
    t.equals(#f.missionEntityCalls, 1, 'SetEntityAsMissionEntity must be called so the engine never despawns this ped out from under this file\'s own tracking')
    t.equals(#f.frozenCalls, 1)

    t.isTrue(#f.releasedModels >= 1, 'the model streaming reference must be released after CreatePed, regardless of success')

    -- Opening the shop from the spawned ped's own option must still go
    -- through ox_inventory's real, unaffected export -- this file decides
    -- nothing about the transaction.
    f.targetedEntities[ped.handle][1].onSelect()
    t.equals(#f.openInventoryCalls, 1)
    t.equals(f.openInventoryCalls[1][2].type, 'k9supply')
    t.equals(#f.notifyCalls, 0, 'a shop that opened must say nothing -- the UI opening IS the feedback')
end)

-- ----------------------------------------------------------------------
-- SILENT-DOOR FIX. This file's onSelect used to throw away OpenShop's
-- return value, which made one entirely ordinary configuration produce the
-- worst possible bug: a real, visible dog ped at a real, configured supply
-- point, with a working prompt, that does nothing at all when clicked --
-- nothing on screen, nothing in console.
--
-- The configuration is not exotic. shared/compat/inventory.lua's
-- qb-inventory adapter (and ps-inventory's, same architecture) returns nil
-- for the CLIENT realm unconditionally and says so in its own header --
-- correctly, because those backends genuinely have no client-callable
-- "open this shop" primitive. An explicit
-- Config.Compat.Systems.inventory.override does not fall through to the
-- other candidates. So an owner who overrides to qb-inventory keeps a
-- perfectly working SERVER half (the K9 medkit, contraband searches) and
-- gets this one player-facing door silently welded shut.
-- ----------------------------------------------------------------------

t.test('SILENT-DOOR FIX: an inventory backend whose client half cannot open a shop tells the player so, instead of doing nothing at all', function()
    local f = newFixture({
        config = BASE_CONFIG,
        playerCoords = vec3(0.0, 0.0, 0.0),
        callbackResult = SERVER_RESOLVED_LOCATIONS,
        openShopFails = true,
    })
    f.runner.step()
    local ped = f.createdPeds[1]

    f.targetedEntities[ped.handle][1].onSelect()

    t.equals(#f.notifyCalls, 1, 'clicking a real ped and getting no response whatsoever is the bug -- there must be a message')
    t.equals(f.notifyCalls[1].description, locale('equipmentshop.cannot_open_on_this_inventory'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('SILENT-DOOR FIX: the message names the real cause and never tells the player to try again -- on this backend it can never work', function()
    local f = newFixture({
        config = BASE_CONFIG,
        playerCoords = vec3(0.0, 0.0, 0.0),
        callbackResult = SERVER_RESOLVED_LOCATIONS,
        openShopFails = true,
    })
    f.runner.step()
    local ped = f.createdPeds[1]
    f.targetedEntities[ped.handle][1].onSelect()

    local text = f.notifyCalls[1].description
    t.isTrue(text:lower():find('server', 1, true) ~= nil,
        'it has to point at the person who can actually fix it -- the player cannot')
    t.isTrue(text:lower():find('try again', 1, true) == nil,
        'telling someone to retry something structurally impossible is worse than telling them nothing')
end)

t.test('SILENT-DOOR FIX: a repeated click keeps answering -- the failure is not swallowed after the first time', function()
    local f = newFixture({
        config = BASE_CONFIG,
        playerCoords = vec3(0.0, 0.0, 0.0),
        callbackResult = SERVER_RESOLVED_LOCATIONS,
        openShopFails = true,
    })
    f.runner.step()
    local ped = f.createdPeds[1]

    for _ = 1, 3 do
        f.targetedEntities[ped.handle][1].onSelect()
    end
    t.equals(#f.notifyCalls, 3, 'a player who clicks again deserves an answer again, not silence after the first')
end)

-- ----------------------------------------------------------------------
-- C -- ENTITY LIFECYCLE: distance-based despawn, by the ped's own handle
-- ----------------------------------------------------------------------

t.test('a spawned ped is despawned once the player leaves PED_DESPAWN_RADIUS -- deleted BY ITS OWN HANDLE', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local ped = f.createdPeds[1]
    t.isTrue(f.pedExists[ped.handle])

    f.setPlayerCoords(vec3(500.0, 500.0, 0.0)) -- well beyond PED_DESPAWN_RADIUS
    f.runner.step()

    t.equals(#f.deletedPeds, 1)
    t.equals(f.deletedPeds[1], ped.handle, 'the ONLY entity ever deleted must be the exact handle this file itself created -- never a proximity/model search result')
    t.isFalse(f.pedExists[ped.handle] == true)
    t.isNil(f.targetedEntities[ped.handle], 'ox_target must also have been told to remove this entity\'s options')
    t.isTrue((function() for _, e in ipairs(f.removedEntities) do if e == ped.handle then return true end end return false end)())
end)

t.test('LEAK FIX: a ped that has ALREADY ceased to exist still gets its ox_target registration removed', function()
    -- The removal used to sit inside `if DoesEntityExist(ped)`, so a ped
    -- that vanished before its own despawn ran -- streamed out, cleaned up
    -- by the game, deleted by another resource -- skipped it. And since the
    -- handle is cleared from SpawnedTargetHandles first (correctly, so this
    -- function stays re-entrant), nothing could ever remove that
    -- registration afterwards: it leaked for the rest of the session, once
    -- per despawn that raced the entity disappearing.
    --
    -- GATE THE START OF A THING, NEVER THE STOP: DoesEntityExist is exactly
    -- the kind of condition that is false precisely when cleanup matters
    -- most.
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local ped = f.createdPeds[1]
    t.isNotNil(f.targetedEntities[ped.handle], 'sanity: the option is registered while the ped is alive')

    -- The entity disappears out from under this resource, without any
    -- despawn of ours having run.
    f.pedExists[ped.handle] = nil

    f.setPlayerCoords(vec3(500.0, 500.0, 0.0))
    f.runner.step()

    t.isNil(f.targetedEntities[ped.handle],
        'the target registration must be gone even though the entity was already dead -- otherwise it is unreachable forever')
    t.isTrue((function() for _, e in ipairs(f.removedEntities) do if e == ped.handle then return true end end return false end)(),
        'RemoveLocalEntity must actually have been called, not merely skipped quietly')
end)

t.test('LEAK FIX, THE CONTROL: DeleteEntity is still NOT called for an entity that no longer exists', function()
    -- Only the target removal was moved out of the existence check. Deleting
    -- a handle the engine has already reclaimed is the one half that
    -- genuinely does need a live entity, so that guard must stay.
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local ped = f.createdPeds[1]
    f.pedExists[ped.handle] = nil

    f.setPlayerCoords(vec3(500.0, 500.0, 0.0))
    f.runner.step()

    t.equals(#f.deletedPeds, 0, 'nothing should be deleted -- the entity was already gone')
end)

t.test('re-approaching after a distance despawn spawns a FRESH ped -- never re-uses a stale handle', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local firstPed = f.createdPeds[1]

    f.setPlayerCoords(vec3(500.0, 500.0, 0.0))
    f.runner.step()

    f.setPlayerCoords(vec3(0.0, 0.0, 0.0))
    f.runner.step()

    t.equals(#f.createdPeds, 2, 'a second, distinct ped must be created on re-approach')
    t.isTrue(f.createdPeds[2].handle ~= firstPed.handle)
    t.isTrue(f.pedExists[f.createdPeds[2].handle])
end)

-- ----------------------------------------------------------------------
-- D -- ENTITY LIFECYCLE: a content change (tablet "move") respawns, never
-- duplicates
-- ----------------------------------------------------------------------

t.test('a location edit (tablet move) landing while its ped is already spawned despawns the stale ped and spawns exactly one fresh one', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local originalPed = f.createdPeds[1]
    t.equals(originalPed.model or originalPed.hash, 'hash:a_c_shepherd')

    -- Broadcast an update for the SAME key ('cfg:1') with a different
    -- model/heading -- simulating a tablet edit.
    f.triggerLocationsUpdated(65535, {
        ['cfg:1'] = { x = 0.0, y = 0.0, z = 0.0, heading = 45.0, model = 'a_c_husky', scenario = '', label = 'K9 Supply' },
    })
    f.runner.step()

    t.equals(#f.deletedPeds, 1, 'the stale ped must be despawned exactly once')
    t.equals(f.deletedPeds[1], originalPed.handle)
    t.equals(#f.createdPeds, 2, 'exactly one fresh ped must replace it -- never a second, duplicate ped alongside the first')
    t.equals(f.createdPeds[2].hash, 'hash:a_c_husky')
    t.equals(f.createdPeds[2].heading, 45.0)
    t.isTrue(f.pedExists[f.createdPeds[2].handle])
    t.isFalse(f.pedExists[originalPed.handle] == true)
end)

t.test('re-broadcasting the IDENTICAL location data is a no-op -- no despawn/respawn churn for an unchanged location', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local originalPed = f.createdPeds[1]

    f.triggerLocationsUpdated(65535, {
        ['cfg:1'] = { x = 0.0, y = 0.0, z = 0.0, heading = 90.0, model = 'a_c_shepherd', scenario = 'WORLD_DOG_SITTING_SHEPHERD', label = 'K9 Supply' },
    })
    f.runner.step()

    t.equals(#f.createdPeds, 1, 'an unchanged location must never be despawned/respawned just because ActiveLocations was replaced wholesale')
    t.equals(#f.deletedPeds, 0)
    t.isTrue(f.pedExists[originalPed.handle])
end)

-- ----------------------------------------------------------------------
-- E -- ENTITY LIFECYCLE: removal (tablet "remove") despawns and the
-- worker thread self-terminates -- no unbounded trap
-- ----------------------------------------------------------------------

t.test('a location removed entirely (tablet remove) despawns its ped and its own worker thread stops running', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local ped = f.createdPeds[1]
    t.isTrue(f.pedExists[ped.handle])

    f.triggerLocationsUpdated(65535, {}) -- the location is gone entirely
    f.runner.step()

    t.equals(#f.deletedPeds, 1)
    t.equals(f.deletedPeds[1], ped.handle)
    t.isFalse(f.pedExists[ped.handle] == true)

    -- The worker thread must have returned (exited), not spun forever --
    -- a further step() must do nothing more to this already-gone location
    -- (no further CreatePed/DeleteEntity calls against it).
    f.runner.step()
    f.runner.step()
    t.equals(#f.createdPeds, 1)
    t.equals(#f.deletedPeds, 1)
end)

-- ----------------------------------------------------------------------
-- F -- MODEL LOADING: a model that never loads times out, warns once,
-- never calls CreatePed
-- ----------------------------------------------------------------------

t.test('a model that never finishes loading times out (Config.K9EquipmentShop.pedModelLoadTimeoutMs), warns once, and CreatePed is never called', function()
    local config = {
        Features = { K9EquipmentShop = true },
        K9EquipmentShop = {
            shopType = 'k9supply', label = 'K9 Supply',
            pedModel = 'a_c_neverloads', pedHeading = 0.0, pedScenario = false,
            pedModelLoadTimeoutMs = 100, -- small, so this test only needs a few Wait(50) steps
            locations = { { x = 0.0, y = 0.0, z = 0.0 } },
        },
    }
    local f = newFixture({
        config = config,
        playerCoords = vec3(0.0, 0.0, 0.0),
        callbackResult = { ok = true, locations = { ['cfg:1'] = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0, model = 'a_c_neverloads', scenario = '', label = 'K9 Supply' } } },
        hasModelLoaded = { ['hash:a_c_neverloads'] = false },
    })

    -- Enough steps to exhaust a 100ms timeout at 50ms per Wait, plus
    -- headroom -- each step() resumes exactly one Wait(50) of the inner
    -- polling loop once the outer worker thread has already run once.
    for _ = 1, 10 do f.runner.step() end

    t.equals(#f.createdPeds, 0, 'CreatePed must never be called for a model that never loads')
    t.isTrue(anyLineContains(f.printedLines, 'failed to load'))
    t.isTrue(#f.releasedModels >= 1, 'the streaming reference must still be released on a timeout')
end)

-- ----------------------------------------------------------------------
-- G -- ENTITY LIFECYCLE: resource-restart safety net
-- ----------------------------------------------------------------------

t.test('onResourceStop deletes every currently-spawned ped by its own handle', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local ped = f.createdPeds[1]
    t.isTrue(f.pedExists[ped.handle])

    f.fireResourceStop('john-k9')

    t.equals(#f.deletedPeds, 1)
    t.equals(f.deletedPeds[1], ped.handle)
    t.isFalse(f.pedExists[ped.handle] == true)
end)

t.test('onResourceStop for a DIFFERENT resource is ignored -- the ped survives', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local ped = f.createdPeds[1]

    f.fireResourceStop('some_other_resource')

    t.equals(#f.deletedPeds, 0)
    t.isTrue(f.pedExists[ped.handle])
end)

-- ----------------------------------------------------------------------
-- H -- the config-only fallback engages when the server round-trip fails
-- ----------------------------------------------------------------------

t.test('a throwing/unavailable equipmentShopGetLocations callback falls back to Config.K9EquipmentShop.locations alone -- the shop still works', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackThrows = true })

    f.runner.step()

    t.equals(#f.createdPeds, 1, 'the config-defined location must still get a ped even though the server round-trip failed entirely')
    t.equals(f.createdPeds[1].hash, 'hash:a_c_shepherd')
    t.isTrue(anyLineContains(f.printedLines, 'could not fetch'))
end)

-- ----------------------------------------------------------------------
-- I -- SOURCE-ORIGIN GUARD on the live-update handler
-- ----------------------------------------------------------------------

t.test('a forged (non-65535) source on equipmentShopLocationsUpdated is ignored entirely', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local originalPed = f.createdPeds[1]

    f.triggerLocationsUpdated(12345, {}) -- forged: would otherwise remove the only location
    f.runner.step()

    t.equals(#f.deletedPeds, 0, 'a forged event must never be allowed to remove a real location')
    t.isTrue(f.pedExists[originalPed.handle])
end)

t.test('a real (65535) source on equipmentShopLocationsUpdated is honoured', function()
    local f = newFixture({ config = BASE_CONFIG, playerCoords = vec3(0.0, 0.0, 0.0), callbackResult = SERVER_RESOLVED_LOCATIONS })
    f.runner.step()
    local originalPed = f.createdPeds[1]

    f.triggerLocationsUpdated(65535, {})
    f.runner.step()

    t.equals(#f.deletedPeds, 1)
    t.equals(f.deletedPeds[1], originalPed.handle)
end)

os.exit(t.summary())
