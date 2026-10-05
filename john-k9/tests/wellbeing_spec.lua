--[[
    tests/wellbeing_spec.lua

    First test coverage for server/wellbeing.lua (previously zero). Loads
    the REAL, unmodified server/cooldowns.lua -> server/entities.lua ->
    server/wellbeing.lua chain into one sandbox (the fxmanifest.lua
    server_scripts order), and drives it through:

      - the real captured lib.callback.register handler
        (getWellbeingSnapshot),
      - the real captured AddEventHandler handler (playerDropped),
      - the shared TickWellbeing maintenance thread (stepped via
        fixtures/sandbox.lua's coroutine thread runner, same technique
        tenure_spec.lua already established).

    server/certifications/ is DELIBERATELY NOT loaded here -- only
    IsConfiguredK9Model is stubbed directly, same "stub, don't load, a
    function already covered by its own file's spec" convention
    kennel_spec.lua's own header already establishes for HasK9Access/
    NotifyPlayer. IsConfiguredK9Model itself is covered by
    certifications_spec.lua; NotifyPlayer by notify_spec.lua.

    Fatigue's rest-source world scan (GetAllObjects/GetAllVehicles/
    GetHashKey) is DELIBERATELY NOT exercised: every fixture below sets
    Config.Wellbeing.Fatigue.restSources = {} (the shipped default is
    {'water_bowl'}), which keeps TickWellbeing's own `#restSources > 0`
    guard false and the scan skipped entirely -- out of this task's
    four-point scope (shared cooldown, tick thread, hesitation cap, relay
    ingest). GetAllObjects/GetAllVehicles/GetHashKey are still stubbed
    (returning empty/identity) purely as a safety net so a future edit
    that accidentally exercises that path fails on a real assertion
    instead of an unregistered-global error -- not a claim that path is
    covered. Recorded here as a disclosed gap, not silently skipped.

    WHAT THIS FILE PROVES:
      1. The tick thread: one TickWellbeing pass per step() after priming
         (interval honored), and playerDropped resets ONLY `lastCoords`,
         never `fatigue`, which persists across a disconnect within the
         same session and is re-observable under a brand-new source id for
         the same citizenid.
      2. Database persistence: the dirty-flag/periodic-flush/write-on-
         disconnect design, the boot-order schema gate, and eviction only
         once a change is confirmed written.
      3. The handler condition badge: resolved server-side from the K9's
         own partnership, sent on change only, and explicitly cleared on
         every path that can make it go stale.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to defense_spec.lua's/
-- tenure_spec.lua's own copies (the only other files needing
-- GetEntityCoords' `-`/`#` operators).
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
-- Real, shipped config.lua values for Config.Wellbeing/Config.Tracking --
-- used as this fixture's baseline so boundary/tick-math tests exercise the
-- actual numbers this resource ships, not arbitrary round test numbers.
-- restSources is deliberately emptied -- see this file's own header.
-- ----------------------------------------------------------------------

local function baselineWellbeingConfig()
    return {
        tickIntervalMs = 5000,
        Fatigue = {
            max                    = 100,
            sprintDecayPerTick     = 2.0,
            idleRegenPerTick       = 1.0,
            restRegenPerTick       = 4.0,
            restRadius             = 5.0,
            restSources            = {}, -- shipped default is {'water_bowl'} -- emptied here, see file header
            speedPenaltyThreshold  = 30,
            speedPenaltyMultiplier = 0.90,
            sprintSpeedThreshold   = 4.0,
        },
    }
end

local function baselineFeatures(overrides)
    -- Only FatigueSystem survives here; the other wellbeing stats were
    -- removed on 2026-09-02. Default stays false so "every flag off" tests keep
    -- meaning what they say.
    local features = {
        FatigueSystem = false,
    }
    for key, value in pairs(overrides or {}) do
        features[key] = value
    end
    return features
end

--- Builds one complete, independent sandbox for server/wellbeing.lua, with
--- the real server/cooldowns.lua and server/entities.lua loaded alongside
--- it first (the exact fxmanifest.lua server_scripts order), and every
--- other cross-file/native dependency as a test-controlled stub.
--- @param opts table? -- { featuresOverride, wellbeingCfg }
--- @return table fixture
local function newWellbeingFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()
    local createThreadCallCount = 0
    local function CreateThread(fn)
        createThreadCallCount = createThreadCallCount + 1
        threadRunner.CreateThread(fn)
    end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local registeredNetEvents = {} -- eventName -> true
    local function RegisterNetEvent(eventName, handler)
        registeredNetEvents[eventName] = true
        if handler then
            AddEventHandler(eventName, handler)
        end
    end

    local callbacks = {} -- name -> handler
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        local line = table.concat(parts, '\t')
        -- COMPAT-LAYER MIGRATION (this pass): shared/compat/core.lua's own
        -- onResourceStart handler (loaded below, since server/wellbeing.lua
        -- now routes GetItemCount/RemoveItem through K9Compat) fires on
        -- every fireResourceStart('john-k9') call and prints its OWN
        -- diagnostic-command line every time regardless of config (see
        -- equipmentshop_spec.lua's identical comment for the full "every
        -- branch of that handler prints something" writeup) -- filtered
        -- here since every assertion in this suite is about
        -- server/wellbeing.lua's own warning surface, several of which
        -- assert EXACTLY ZERO lines for a disabled feature.
        if line:find('[John-K9] K9Compat:', 1, true) then return end
        printedLines[#printedLines + 1] = line
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    -- exports.qbx_core:GetPlayer(src) -- keyed by source, holds citizenid
    local citizenidBySource = {}
    local function qbxGetPlayer(_self, src)
        local citizenid = citizenidBySource[src]
        if not citizenid then return nil end
        return { PlayerData = { citizenid = citizenid } }
    end

    -- HANDLER CONDITION BADGE (this pass) -- exports.qbx_core:GetPlayerByCitizenId(citizenid),
    -- the reverse-direction lookup server/wellbeing.lua's own
    -- ResolveOnlineSourceForCitizenid needs. Derived from the SAME
    -- `citizenidBySource` table setPlayer/clearPlayer already maintain
    -- (mirrors this suite's own
    -- identical fixture pattern for this exact export) -- never a second,
    -- independently-maintained table that could drift out of sync with it.
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        for src, cid in pairs(citizenidBySource) do
            if cid == citizenid then return { PlayerData = { citizenid = cid, source = src } } end
        end
        return nil
    end

    -- HANDLER CONDITION BADGE (this pass) -- server/partnership.lua's real
    -- GetActivePartnerCitizenId accessor, stubbed. ABSENT from `env` by
    -- default (mirrors this suite's own
    -- "server/partnership.lua module absent" soft-dependency convention) --
    -- every PRE-EXISTING test in this file never wires this fixture up at
    -- all, so `type(GetActivePartnerCitizenId) == 'function'` stays false
    -- for every one of them, exactly reproducing today's real "no
    -- partnership module loaded" behavior with zero risk of an accidental
    -- behavior change. Only tests that explicitly call setPartner(...) (or
    -- setActivePartnerResolver(...) directly) below ever populate this.
    local partnerByCitizenid = {} -- citizenid -> { partner = citizenid, isK9 = bool }
    local function getActivePartnerCitizenIdStub(citizenid)
        local entry = partnerByCitizenid[citizenid]
        if not entry then return nil, nil end
        return entry.partner, entry.isK9
    end

    local onlinePlayerIds = {}
    local function GetPlayers()
        local out = {}
        for i, id in ipairs(onlinePlayerIds) do out[i] = tostring(id) end
        return out
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end

    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    -- SECURITY FIX FOLLOW-UP (coder-architect, adversarial-pass finding,
    -- this pass): ResolveK9Ped now ALSO requires HasK9Access(source), not
    -- just a matching model -- see that function's own doc comment in
    -- server/wellbeing.lua for the full writeup. Defaults every source to
    -- `true` so every PRE-EXISTING test in this file (none of which were
    -- ever testing an access-denial scenario -- that is squarely this
    -- fixture's own owner's territory to add, not invented here) keeps
    -- behaving exactly as it did before this stub existed. `setHasK9Access`
    -- exposed below for a future test that wants to exercise the new gate
    -- directly.
    local hasK9AccessBySource = {}
    local defaultHasK9Access = true
    local function HasK9Access(source)
        local v = hasK9AccessBySource[source]
        if v == nil then return defaultHasK9Access end
        return v
    end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    -- DEATH/RESPAWN (this task) -- defaults every ped to 200 (alive, native
    -- max health), matching combat_spec.lua's/medkit_spec.lua's own default
    -- so a fixture that never calls setHealth behaves exactly as before
    -- this addition.
    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    -- Safety-net stubs only -- see this file's header on why the Fatigue
    -- rest-source scan is not exercised. Never expected to be hit given
    -- every fixture config's restSources = {}.
    local function GetAllObjects() return {} end
    local function GetAllVehicles() return {} end
    local function GetHashKey(name) return name end

    -- GetSelectedPedWeapon: server/wellbeing.lua's relayWeaponFire handler
    -- requires the reporter to actually be holding a weapon before it will
    -- log nearby gunfire -- a red-team finding, since that event carries no
    -- payload and was otherwise reportable by anyone who could send it.
    -- GetHashKey above is identity, so a weapon "hash" here is just its
    -- name string. Defaults to armed, because every pre-existing test in
    -- this file was written when any reporter was accepted and is about
    -- something else entirely; the unarmed case gets its own explicit
    -- tests. Set weaponBySource[src] = 'WEAPON_UNARMED' (or 0) to make a
    -- specific reporter unarmed.
    local weaponBySource = {}
    local function GetSelectedPedWeapon(ped)
        for src, p in pairs(pedBySource) do
            if p == ped then return weaponBySource[src] or 'WEAPON_PISTOL' end
        end
        return 'WEAPON_PISTOL'
    end

    -- netId -> entity resolution goes through the REAL, unmodified
    -- server/entities.lua's ResolveNetworkEntity (loaded below), which
    -- itself calls these three raw natives. Keyed by
    -- a plain opaque netId/entity number this fixture controls entirely via
    -- setNetworkEntity below -- no relationship to pedBySource/coordsByPed's
    -- own numbering, exactly like every other entity-handle table in this
    -- fixture.
    local entityByNetId = {}
    local existingEntities = {}
    local entityTypeByEntity = {}
    local function NetworkGetEntityFromNetworkId(netId) return entityByNetId[netId] or 0 end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityType(entity) return entityTypeByEntity[entity] or 0 end

    -- STARTUP VALIDATION (this task) -- GetCurrentResourceName/onResourceStart
    -- support for exercising the new WarnIfItemMissing/onResourceStart block.
    local RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- exports.ox_inventory:GetItemCount/RemoveItem -- keyed by source, then item name.
    local itemCounts = {}
    local function oxGetItemCount(_self, source, itemName)
        return (itemCounts[source] and itemCounts[source][itemName]) or 0
    end
    local function oxRemoveItem(_self, source, itemName, count)
        local have = (itemCounts[source] and itemCounts[source][itemName]) or 0
        if have < count then return false end
        itemCounts[source][itemName] = have - count
        return true
    end

    -- exports.ox_inventory:Items(itemName) -- the server's own live item
    -- registry (this task, STARTUP VALIDATION section). Keyed by item name
    -- -> true (registered); a name never registered here correctly returns
    -- nil, matching real ox_inventory's own getItem() behavior for an
    -- unknown name.
    local registeredItems = {}
    local throwOnItemsExport = false
    local function oxItems(_self, itemName)
        if throwOnItemsExport then
            error('simulated native failure: ox_inventory Items()')
        end
        if registeredItems[itemName] then return { name = itemName } end
        return nil
    end

    local config = {
        Features = baselineFeatures(opts.featuresOverride),
        Wellbeing = opts.wellbeingCfg or baselineWellbeingConfig(),
        Tracking = {
            Blood     = { relayCooldownMs = 500 },
            Gunpowder = { relayCooldownMs = 300 },
        },
        -- COMPAT-LAYER MIGRATION (coder-backend, this pass): pins the
        -- 'inventory' system straight to 'ox_inventory' via `override`
        -- (shared/compat/core.lua's TIER 1, skipping the candidate-scanning
        -- walk). The other four systems get empty-but-present tables so
        -- DetectSystem's own "missing or malformed" warning never fires.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer         = GetGameTimer,
        CreateThread         = CreateThread,
        Wait                 = threadRunner.Wait,
        AddEventHandler      = AddEventHandler,
        RegisterNetEvent     = RegisterNetEvent,
        TriggerClientEvent   = TriggerClientEvent,
        print                = printStub,
        NotifyPlayer         = NotifyPlayer,
        lib                  = lib,
        -- COMPAT-LAYER MIGRATION (this pass): server/wellbeing.lua's
        -- GetItemCount/RemoveItem calls are now routed through `K9Compat.Get('inventory')`
        -- -- shared/compat/inventory.lua's BuildOxInventoryServer requires
        -- ALL SEVEN server-realm methods present as callable exports before
        -- it returns ANYTHING. `Items` stays a direct, un-routed
        -- `exports.ox_inventory:Items` call (see server/wellbeing.lua's own
        -- COMPAT-LAYER FINDING comment -- no server-realm ItemExists exists
        -- in the contract). GetInventoryItems/GetContainerFromSlot/
        -- RegisterStash/RegisterShop/registerHook (never called by
        -- server/wellbeing.lua at all) are harmless no-ops purely so
        -- capability verification passes.
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer, GetPlayerByCitizenId = qbxGetPlayerByCitizenId },
            ox_inventory = {
                GetItemCount = oxGetItemCount,
                RemoveItem = oxRemoveItem,
                Items = oxItems,
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        GetPlayers           = GetPlayers,
        GetPlayerPed         = GetPlayerPed,
        GetEntityModel       = GetEntityModel,
        IsConfiguredK9Model  = IsConfiguredK9Model,
        HasK9Access          = HasK9Access,
        GetEntityCoords      = GetEntityCoords,
        GetEntityHealth      = GetEntityHealth,
        GetAllObjects        = GetAllObjects,
        GetAllVehicles       = GetAllVehicles,
        GetHashKey           = GetHashKey,
        GetSelectedPedWeapon = GetSelectedPedWeapon,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist      = DoesEntityExist,
        GetEntityType        = GetEntityType,
        GetCurrentResourceName = GetCurrentResourceName,
        Config               = config,
        -- DATABASE PERSISTENCE (this pass, coder-backend) -- ABSENT from
        -- `env` by default (mirrors GetActivePartnerCitizenId's own
        -- "soft-dependency, not loaded" convention just above), so every
        -- PRE-EXISTING test in this file -- none of which passes
        -- opts.k9Store -- keeps observing
        -- `type(K9Store) == 'table'` as false, exactly reproducing
        -- today's real "server/datastore.lua has not yet grown
        -- Wellbeing_Get/Wellbeing_Upsert" state with zero behavior
        -- change. Only tests that explicitly pass opts.k9Store below ever
        -- populate this.
        K9Store              = opts.k9Store,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
        -- always reports 'started' (this file never tests an
        -- undetected-inventory scenario -- covered by shared/compat/
        -- inventory.lua's own dedicated spec and this task's own per-file
        -- stub-degrade writeup in server/wellbeing.lua's header).
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- COMPAT-LAYER MIGRATION (this pass): load the REAL, unmodified
    -- shared/compat/core.lua + shared/compat/inventory.lua before the file
    -- under test (never a hand-written fake translation layer).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/wellbeing.lua', env)

    -- HANDLER CONDITION BADGE (this pass) -- env.GetActivePartnerCitizenId
    -- is only ever assigned when a test opts in via setPartner/
    -- setActivePartnerResolver below (never at fixture-construction time),
    -- so every PRE-EXISTING test in this file -- none of which ever calls
    -- either -- keeps observing `type(GetActivePartnerCitizenId) ==
    -- 'function'` as false, exactly reproducing "server/partnership.lua
    -- not loaded" with zero behavior change. Safe to assign AFTER
    -- Sandbox.loadInto above: server/wellbeing.lua's own functions resolve
    -- this name fresh, by upvalue into `env`, at CALL time (inside
    -- TickWellbeing, always reached later via threadRunner.step()), never
    -- at this file's own load time.
    local function setPartner(k9Citizenid, handlerCitizenid)
        partnerByCitizenid[k9Citizenid] = { partner = handlerCitizenid, isK9 = true }
        partnerByCitizenid[handlerCitizenid] = { partner = k9Citizenid, isK9 = false }
        env.GetActivePartnerCitizenId = getActivePartnerCitizenIdStub
    end
    local function clearPartner(citizenid)
        local entry = partnerByCitizenid[citizenid]
        if entry then
            partnerByCitizenid[entry.partner] = nil
        end
        partnerByCitizenid[citizenid] = nil
    end

    local primed = false
    local function primeIfNeeded()
        if not primed then
            threadRunner.step()
            primed = true
        end
    end

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        printedLines = printedLines,
        notifyCalls = notifyCalls,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setPlayer = function(src, citizenid) citizenidBySource[src] = citizenid end,
        clearPlayer = function(src) citizenidBySource[src] = nil end,
        setOnline = function(ids) onlinePlayerIds = ids end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        -- Makes a reporting source unarmed (or arms them with a specific
        -- weapon). server/wellbeing.lua's relayWeaponFire ignores an
        -- unarmed reporter -- see the GetSelectedPedWeapon stub above.
        setWeapon = function(src, weapon) weaponBySource[src] = weapon end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setHasK9Access = function(source, v) hasK9AccessBySource[source] = v end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        -- Registers a fake world object entity behind a netId, for
        -- ResolveNetworkEntity(netId, 3).
        -- `entityType` defaults to 3 (object), matching a real world prop;
        -- pass 1/2 to exercise ResolveNetworkEntity's own ped/vehicle
        -- type-mismatch reject. Model/coords for `entity` are set the
        -- ordinary way (setModel/setCoords above), since GetEntityModel/
        -- GetEntityCoords read the exact same generic tables regardless of
        -- whether the handle is a ped or a plain object.
        setNetworkEntity = function(netId, entity, entityType)
            entityByNetId[netId] = entity
            existingEntities[entity] = true
            entityTypeByEntity[entity] = entityType or 3
        end,
        removeNetworkEntity = function(netId)
            local entity = entityByNetId[netId]
            entityByNetId[netId] = nil
            if entity then existingEntities[entity] = nil end
        end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        getItemCount = function(src, itemName) return (itemCounts[src] and itemCounts[src][itemName]) or 0 end,
        registerInventoryItem = function(itemName) registeredItems[itemName] = true end,
        setThrowOnItemsExport = function(v) throwOnItemsExport = v end,
        invokeCallback = function(name, source, ...)
            assert(callbacks[name], 'no callback registered for ' .. name)
            return callbacks[name](source, ...)
        end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            for _, handler in ipairs(eventHandlers[eventName] or {}) do
                handler(...)
            end
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler()
            end
        end,
        --- Fires the real onResourceStop handler. `resourceName` defaults to
        --- this fixture's own resource name, so a test that means "we are
        --- stopping" does not have to restate it; pass something else to
        --- prove the name check works.
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName == nil and 'john-k9' or resourceName)
            end
        end,
        --- Fires 'onResourceStart' with the given resourceName -- mirrors
        --- firePlayerDropped's shape. `resourceName` defaults to this
        --- fixture's own stubbed GetCurrentResourceName() value ('john-k9')
        --- so the common case ("this resource itself just started") needs no
        --- argument; callers testing the `GetCurrentResourceName() ~=
        --- resourceName` guard pass a different name explicitly.
        --- @param resourceName string?
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'john-k9')
            end
        end,
        registeredNetEvents = registeredNetEvents,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        createThreadCallCount = function() return createThreadCallCount end,
        primeIfNeeded = primeIfNeeded,
        runOneTick = function()
            primeIfNeeded()
            threadRunner.step()
        end,
        -- HANDLER CONDITION BADGE (this pass) helpers --------------------
        setPartner = setPartner,
        clearPartner = clearPartner,
        -- Simulates server/partnership.lua never having loaded at all,
        -- even after a prior setPartner() call in the SAME test -- see
        -- PushHandlerConditionUpdate's own soft-dependency guard.
        setNoPartnershipModule = function() env.GetActivePartnerCitizenId = nil end,
    }
end


-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/wellbeing.lua registers at least one playerDropped handler', function()
    local f = newWellbeingFixture()
    t.isTrue(f.eventHandlerCount('playerDropped') >= 1, "this file's own lastCoords-reset handler, plus every cooldown tracker's own RegisterPlayerDropped()")
end)

t.test('No TickWellbeing activity when the wellbeing feature flag is false -- stepping produces zero wellbeingUpdate events', function()
    local f = newWellbeingFixture() -- all features false by default
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)
    f.runOneTick()
    f.runOneTick()
    t.equals(#f.clientEvents, 0)
end)

t.test("RESOLVED: the shared TickWellbeing thread now starts unconditionally at file load, even when the wellbeing feature flag is false -- exactly three threads always exist now, and idling over an all-off Config.Features costs nothing observable", function()
    -- INVERTED ON PURPOSE (this pass, coder-backend). This test used to be
    -- titled "DISCREPANCY: ..." and asserted exactly ONE CreateThread call
    -- with every flag off, pinning server/wellbeing.lua's OWN then-true
    -- header claim ("this file starts NO thread at all if all five flags
    -- are false") as a real, deliberately-tested invariant -- but that
    -- invariant was also a real, confirmed live-toggle-ON bug: a server
    -- booting with all five wellbeing flags off and later flipping ONE on
    -- live from the tablet (every one of them is `tier = 'live'` in
    -- server/runtimecontrol.lua's own FEATURE_TIERS) had nothing polling to
    -- ever start ticking that stat or pushing a single wellbeingUpdate,
    -- until this resource restarted -- an already-connected client's stat
    -- snapshot going stale with NO upper bound, not merely one tick
    -- interval. That gap is fixed now (see server/wellbeing.lua's
    -- CreateThread call and its own resolution comment for the full
    -- writeup, and the LIVE-FLIP FIX test immediately below for the real
    -- regression coverage) -- the tick thread starts unconditionally and
    -- re-checks all five flags fresh every tick. A test that kept asserting
    -- "exactly one CreateThread call with everything off" would now be
    -- asserting the BUG's own premise, not this file's real behavior --
    -- inverted here on purpose, mirroring tests/combat_spec.lua's own
    -- corrected "with every combat feature flag off..." test and
    -- tests/runtimefeaturetiers_spec.lua's "RESOLVED PARTIAL LIVENESS" test
    -- for the identical shape. Re-reverting this back to asserting ONE
    -- thread would need server/wellbeing.lua's own fix undone first, and
    -- would reopen the exact unbounded-staleness gap the LIVE-FLIP FIX test
    -- below exists to prove closed.
    local f = newWellbeingFixture() -- all features false
    -- THE THREE THREADS, NAMED EXHAUSTIVELY so nobody has to re-derive
    -- this later: (1) the unconditional TickWellbeing loop, (2)
    -- WellbeingLastSeenOnline's own always-on :StartSweep -- bounds that
    -- tracker's own table the same proven way every other sweep in this
    -- resource does; see EvictStaleWellbeingEntries' own doc comment in
    -- server/wellbeing.lua for why this is a SEPARATE tracker from
    -- WellbeingStats itself -- and (3) the periodic persistence-flush
    -- thread, mirroring server/webhook.lua's own FlushQueue thread shape.
    -- All three run unconditionally at file load; see PersistenceCfg's own
    -- doc comment for why an all-off Config.Wellbeing.Persistence (the
    -- sub-block does not even need to exist) still costs nothing
    -- observable while idle.
    t.equals(f.createThreadCallCount(), 3, "three CreateThread calls happen at file-load time even with every feature off -- the shared tick loop, WellbeingLastSeenOnline's own sweep, and the persistence-flush thread. This was eight until 2026-09-02, when the removed subsystems took their own per-citizenid cooldown sweeps with them. The PROPERTY this pins is unchanged -- every one of these starts unconditionally at file load, so a live toggle-on reaches an already-connected client with no restart")
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, "the now-unconditional tick thread must idle cleanly with every flag off, no error")
    t.equals(#f.clientEvents, 0, "no wellbeingUpdate is ever pushed while every flag is off, even though the thread is now genuinely running")
end)

-- ========================================================================
-- CONFIRMED LIVE-FLIP BUG, FIXED (this pass, coder-backend): the shared
-- TickWellbeing thread -- the ONLY place any wellbeing stat is ever
-- ticked/decayed/regenerated or pushed to a client -- used to only ever
-- start if a wellbeing feature flag was ALREADY true at this file's own
-- load time. server/runtimecontrol.lua's FEATURE_TIERS registers it as
-- `tier = 'live'` (ApplyFeatureOverride mutates Config.Features.*
-- immediately, no restart), so an operator could boot with it off, flip it
-- on live from the tablet, and get live mutation handlers (each re-checks
-- its own flag fresh) writing real WellbeingStats mutations, with
-- the one thread that would ever tick/push any of it never having started
-- -- an already-connected client's stat snapshot stuck stale forever, not
-- merely one tick interval. This is the exact property this section proves
-- now holds: a flag flipped on live is picked up by the already-running
-- thread within one tick, regardless of what the flags were when this file
-- loaded.
-- ========================================================================

-- ------------------------------------------------------------------------
-- STARTUP VALIDATION for every placeholder ox_inventory item name
-- this resource depends on (Config.K9Medkit.itemName included -- see
-- server/wellbeing.lua's own header for why that check lives here despite
-- belonging, in spirit, to server/medkit.lua).
-- ------------------------------------------------------------------------

t.test('STARTUP VALIDATION: K9Medkit disabled -- the item is never even checked, missing or not (read-at-point-of-activation discipline)', function()
    local f = newWellbeingFixture()
    f.config.Features.K9Medkit = false
    f.config.K9Medkit = { itemName = 'k9_medkit' }

    f.fireResourceStart()
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('k9_medkit', 1, true) ~= nil, 'a disabled feature must never be checked at all')
    end
end)

-- ========================================================================
-- STAMINA DURATION TUNABLE (owner directive, this pass: "make sure high
-- command can edit the ability to make stamina last longer or even
-- permanently"). Config.Wellbeing.Fatigue.sprintDecayPerTick is now exposed
-- via server/runtimecontrol.lua's TUNABLE_REGISTRY (min = 0, max = 20.0--
-- see that entry's own comment for the full "why 0, why no client push"
-- writeup). This section proves the GAMEPLAY claim that registration alone
-- cannot: that a live edit genuinely changes how long a sprinting K9's
-- fatigue lasts, that 0 specifically means EXACTLY permanent (not merely a
-- very slow drain), and that a live edit back to a finite value takes
-- effect on the very next tick with no restart -- all driven through the
-- exact same `Config.Wellbeing.Fatigue.sprintDecayPerTick` field
-- server/runtimecontrol.lua's ApplyTunableOverride mutates in production
-- (SetConfigByPath writes into this SAME table object; mutating
-- f.config.Wellbeing.Fatigue.sprintDecayPerTick directly below is
-- byte-for-byte what that call does).
-- ========================================================================

--- Moves the given ped `distanceMeters` further along +X than its current
--- fixture coords and returns the new coords, so a caller can drive several
--- consecutive "sprinting" ticks without hand-computing absolute positions
--- each time. `distanceMeters` must exceed sprintSpeedThreshold(4.0) *
--- dtSeconds(TICK_INTERVAL_MS/1000 = 5) = 20.0 meters for TickWellbeing to
--- classify the tick as sprinting -- 30 meters (6 m/s) is used throughout
--- this section, comfortably over that line.
--- @param f table fixture returned by newWellbeingFixture
--- @param ped number
--- @param fromX number
--- @param distanceMeters number
--- @return number newX
local function sprintTick(f, ped, fromX, distanceMeters)
    local newX = fromX + distanceMeters
    f.setCoords(ped, newX, 0, 0)
    f.runOneTick()
    return newX
end

t.test('SnapshotOf pushes nativeStaminaRestorePercent to the client, read fresh, alongside the other six wellbeingTunables fields -- this is the field client/wellbeing.lua actually calls RestorePlayerStamina with', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true } })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.config.Wellbeing.Fatigue.nativeStaminaRestorePercent = 0.75
    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.wellbeingTunables.fatigueNativeStaminaRestorePercent, 0.75)

    -- Read fresh, not captured once -- a live tablet edit reaches the very
    -- next snapshot with no restart, same as every sibling field in this
    -- table.
    f.config.Wellbeing.Fatigue.nativeStaminaRestorePercent = 0
    snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.wellbeingTunables.fatigueNativeStaminaRestorePercent, 0)
end)

t.test('PERMANENT STAMINA: sprintDecayPerTick = 0 (the tablet\'s "permanent" setting) means fatigue never drops below its starting value, even across many ticks of continuous sustained sprinting', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.sprintDecayPerTick = 0
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick() -- first sample: no prior lastCoords yet
    local x = 0
    for _ = 1, 50 do
        x = sprintTick(f, 9001, x, 30) -- 30m/tick = 6 m/s, comfortably over the 4.0 m/s sprint threshold
    end

    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 100, 'fatigue must still be at max after 50 straight ticks of sustained sprinting -- not merely high, EXACTLY unchanged, proving this is a real zero-decay no-op rather than a very slow drain that would eventually cross the threshold')
end)

t.test('PROPORTIONALITY: halving sprintDecayPerTick exactly halves the fatigue lost over the same number of sustained-sprint ticks -- "last longer" is a real, graduated dial, not just an on/off switch', function()
    local defaultCfg = baselineWellbeingConfig() -- sprintDecayPerTick = 2.0, the shipped default
    local fDefault = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = defaultCfg })
    fDefault.setOnline({ 1 }); fDefault.setPlayer(1, 'K9-CID'); fDefault.setPed(1, 9001)
    fDefault.setModel(9001, 555); fDefault.setIsK9Model(555, true); fDefault.setCoords(9001, 0, 0, 0)
    fDefault.runOneTick()
    local xd = 0
    for _ = 1, 10 do xd = sprintTick(fDefault, 9001, xd, 30) end
    local snapDefault = fDefault.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snapDefault.fatigue, 80, 'sanity: shipped default (2.0/tick) loses 20 fatigue over 10 sprinting ticks')

    local halvedCfg = baselineWellbeingConfig()
    halvedCfg.Fatigue.sprintDecayPerTick = 1.0 -- a live "lasts longer" tablet edit -- half the shipped rate
    local fHalved = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = halvedCfg })
    fHalved.setOnline({ 1 }); fHalved.setPlayer(1, 'K9-CID'); fHalved.setPed(1, 9001)
    fHalved.setModel(9001, 555); fHalved.setIsK9Model(555, true); fHalved.setCoords(9001, 0, 0, 0)
    fHalved.runOneTick()
    local xh = 0
    for _ = 1, 10 do xh = sprintTick(fHalved, 9001, xh, 30) end
    local snapHalved = fHalved.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snapHalved.fatigue, 90, 'halving the decay rate must exactly halve the fatigue lost over the identical 10-tick sprint (10 lost, not 20) -- a genuinely proportional "lasts longer", not a step change')
end)

t.test('LIVE CHANGE TAKES EFFECT: a tablet edit from permanent (0) back to a finite decay rate resumes real decay on the very next tick, mid-session, with no restart -- the "gate the start, never strand the stop" rule applies in reverse here too: raising the drain back up must actually reach an already-running K9', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.sprintDecayPerTick = 0 -- starts "permanent"
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick()
    local x = 0
    for _ = 1, 5 do x = sprintTick(f, 9001, x, 30) end
    local snapBefore = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snapBefore.fatigue, 100, 'sanity: still permanent after 5 sprinting ticks')

    -- Mutates the SAME Config.Wellbeing.Fatigue table server/runtimecontrol.lua's
    -- ApplyTunableOverride/SetConfigByPath writes into in production -- this
    -- IS what a live 'john-k9:server:runtimeSetTunable' call does to this
    -- exact field.
    f.config.Wellbeing.Fatigue.sprintDecayPerTick = 2.0

    sprintTick(f, 9001, x, 30)
    local snapAfter = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snapAfter.fatigue, 98, 'decay must resume IMMEDIATELY on the very next tick after the live edit -- TickWellbeing reads Config.Wellbeing.Fatigue.sprintDecayPerTick fresh every pass, never a value captured once at file-load time')
end)

t.test('NO NEGATIVE/WRAPPED FATIGUE: even at the tunable\'s own maximum (20.0/tick), repeated sustained sprinting clamps at 0 and never goes negative', function()
    local cfg = baselineWellbeingConfig()
    cfg.Fatigue.sprintDecayPerTick = 20.0 -- the registry's own declared max
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick()
    local x = 0
    for i = 1, 8 do
        x = sprintTick(f, 9001, x, 30)
        local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
        t.isTrue(snap.fatigue >= 0, ('fatigue must never go negative (tick %d): got %s'):format(i, tostring(snap.fatigue)))
    end
    local final = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(final.fatigue, 0, 'after enough ticks at the maximum decay rate, fatigue settles at exactly 0, clamped -- never negative')
end)

-- ========================================================================
-- PER-CITIZENID STAMINA OVERRIDE WIRING (this pass, coder-backend, Part B
-- of the owner's "keep the speed and stamina editing where i can edit it
-- to as high as i want" request). server/k9profiles.lua's
-- GetK9EffectiveMultipliers is an accessor nothing calls unless it is
-- actually wired somewhere real -- these tests prove TickWellbeing's own
-- Fatigue sprint-decay branch genuinely consults it (soft-guarded,
-- pcall-wrapped, exactly the idiom server/tracking.lua's own
-- ResolveMaxRangeForCitizenId already established for the sibling
-- scent-range field), not merely that the accessor exists in isolation.
-- ========================================================================

t.test('STAMINA OVERRIDE WIRING: when GetK9EffectiveMultipliers is available and returns a per-citizenid sprintDecayPerTick, TickWellbeing uses THAT value, not the raw Config.Wellbeing.Fatigue.sprintDecayPerTick global', function()
    local cfg = baselineWellbeingConfig() -- Fatigue.sprintDecayPerTick = 2.0 (the global default)
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    -- Simulates a high-command individual override of 0.5/tick for this
    -- exact citizenid -- a real server/k9profiles.lua would resolve this
    -- from its own OverrideByCitizenId/StaminaOverrideByCitizenId tables;
    -- this fixture never loads that file, so it stubs the ONE seam
    -- TickWellbeing actually calls, exactly like tests/tracking_spec.lua's
    -- own fixture stubs GetK9EffectiveMultipliers for the sibling
    -- scent-range wiring.
    local calls = {}
    f.env.GetK9EffectiveMultipliers = function(citizenid)
        calls[#calls + 1] = citizenid
        return { sprintDecayPerTick = 0.5 }
    end

    f.runOneTick()
    local x = 0
    for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end

    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 95, '10 sprinting ticks at an OVERRIDDEN 0.5/tick must lose exactly 5 fatigue, not 20 (the raw global 2.0/tick would have produced)')
    t.isTrue(#calls > 0, 'GetK9EffectiveMultipliers must actually have been called, not merely be available and unused')
    t.equals(calls[1], 'K9-CID', 'must be called with THIS citizenid, never a different one or a raw source id')
end)

t.test('STAMINA OVERRIDE WIRING: sprintDecayPerTick = 0 from the override is a genuine "permanent stamina" no-op, exactly like the global-default 0 case above', function()
    local cfg = baselineWellbeingConfig() -- Fatigue.sprintDecayPerTick = 2.0 (the global default, deliberately NON-zero here)
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.env.GetK9EffectiveMultipliers = function() return { sprintDecayPerTick = 0 } end

    f.runOneTick()
    local x = 0
    for _ = 1, 50 do x = sprintTick(f, 9001, x, 30) end

    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 100, 'an OVERRIDDEN 0/tick must behave exactly like the global-default 0 case: fatigue never drops, even after 50 sustained-sprint ticks, even though the raw Config default here is a non-zero 2.0')
end)

t.test('STAMINA OVERRIDE WIRING: GetK9EffectiveMultipliers ABSENT (an install predating server/k9profiles.lua) falls back to the raw Config.Wellbeing.Fatigue.sprintDecayPerTick global -- exactly today\'s behavior, unaffected', function()
    local cfg = baselineWellbeingConfig()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    -- Deliberately never setting f.env.GetK9EffectiveMultipliers -- this
    -- fixture's own Sandbox.newEnv seeds every global from the REAL _G,
    -- which has no such function either, so `type(GetK9EffectiveMultipliers)
    -- == 'function'` is false here, exactly modelling an install that
    -- predates that file.
    t.isNil(f.env.GetK9EffectiveMultipliers)
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.runOneTick()
    local x = 0
    for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end
    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 80, 'must fall back to the raw global (2.0/tick * 10 ticks = 20 lost), exactly matching this section\'s own earlier "shipped default" sanity check')
end)

t.test('STAMINA OVERRIDE WIRING: a THROWING GetK9EffectiveMultipliers is caught (pcall) and falls back to the raw Config global -- never crashes TickWellbeing for every other online K9', function()
    local cfg = baselineWellbeingConfig()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
    f.setOnline({ 1 })
    f.setPlayer(1, 'K9-CID')
    f.setPed(1, 9001)
    f.setModel(9001, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9001, 0, 0, 0)

    f.env.GetK9EffectiveMultipliers = function() error('simulated failure in server/k9profiles.lua') end

    f.runOneTick()
    local x = 0
    local ok = pcall(function()
        for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end
    end)
    t.isTrue(ok, 'a throwing GetK9EffectiveMultipliers must never crash TickWellbeing itself')
    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
    t.equals(snap.fatigue, 80, 'must fall back to the raw global exactly as if the function were absent')
end)

t.test('STAMINA OVERRIDE WIRING: a malformed return value (not a table, or a non-number sprintDecayPerTick) is ignored -- falls back to the raw Config global, never a crash or a nonsense subtraction', function()
    local cfg = baselineWellbeingConfig()
    for _, badReturn in ipairs({ nil, false, 'not a table', {}, { sprintDecayPerTick = 'not a number' }, { sprintDecayPerTick = false } }) do
        local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, wellbeingCfg = cfg })
        f.setOnline({ 1 })
        f.setPlayer(1, 'K9-CID')
        f.setPed(1, 9001)
        f.setModel(9001, 555)
        f.setIsK9Model(555, true)
        f.setCoords(9001, 0, 0, 0)

        f.env.GetK9EffectiveMultipliers = function() return badReturn end

        f.runOneTick()
        local x = 0
        local ok = pcall(function()
            for _ = 1, 10 do x = sprintTick(f, 9001, x, 30) end
        end)
        t.isTrue(ok, ('must never crash for a malformed return value: %s'):format(tostring(badReturn)))
        local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)
        t.equals(snap.fatigue, 80, ('must fall back to the raw global for a malformed return value: %s'):format(tostring(badReturn)))
    end
end)

t.test('EVERY tracker in server/wellbeing.lua has a cleanup strategy -- source-keyed ones register a playerDropped hook, citizenid-keyed ones sweep, and none has neither', function()
    -- Same "read the file's own text, not a runtime accessor" technique
    -- tests/mainserver_spec.lua/tests/combat_spec.lua/
    -- tests/partnership_spec.lua already established for the identical
    -- invariant in their own files. A tracker with NEITHER strategy leaks
    -- for the whole uptime of the server.
    local handle = assert(io.open('../server/wellbeing.lua', 'r'))
    local text = handle:read('*a')
    handle:close()

    local declared = {}
    for name in text:gmatch('local%s+([%w_]+)%s*=%s*New[CN]') do
        declared[#declared + 1] = name
    end
    -- FLOOR LOWERED 5 -> 1 on 2026-09-02, and the reason matters because the
    -- message below says not to lower it lightly. The four trackers this
    -- floor was written around were deleted along with the subsystems that
    -- owned them, at the owner's request. The floor exists to catch the PATTERN going stale (a rename
    -- of NewCooldown/NewNestedCooldown would silently match nothing and this
    -- test would pass while checking zero trackers), so it still has to be
    -- above zero -- but it can only ever be as high as the number of
    -- trackers the file genuinely still declares.
    t.isTrue(#declared >= 1,
        ('sanity: only found %d tracker declaration(s) in server/wellbeing.lua -- the pattern has probably drifted; fix it rather than lowering this floor'):format(#declared))

    for _, name in ipairs(declared) do
        local hasPlayerDropped = text:find(name .. '.RegisterPlayerDropped(', 1, true) ~= nil
        local hasSweep = text:find(name .. '.StartSweep(', 1, true) ~= nil
        t.isTrue(hasPlayerDropped or hasSweep,
            name .. ' has neither .RegisterPlayerDropped() nor .StartSweep() -- whatever it is keyed by, its table grows for the whole uptime of the server with nothing to bound it')
    end
end)


-- ========================================================================
-- HANDLER CONDITION BADGE (this pass) -- see server/wellbeing.lua's own
-- "HANDLER CONDITION BADGE" header section for the full design these
-- tests pin. Every test below uses the REAL, unmodified
-- PushHandlerConditionUpdate/ComputeHandlerConditionTags/
-- ClearHandlerConditionBadge/ClearAllHandlerConditionBadges — none of
-- them are `local` to this SPEC, only to server/wellbeing.lua itself —
-- reached exclusively through the real TickWellbeing tick, the real
-- playerDropped handler, and the real CreateThread loop's own `else`
-- branch, exactly as production reaches them.
-- ========================================================================

local HANDLER_CONDITION_EVENT = 'john-k9:client:partnerConditionUpdate'

--- @param f table
--- @return table[] -- every captured partnerConditionUpdate client event, in order
local function partnerConditionEvents(f)
    local out = {}
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == HANDLER_CONDITION_EVENT then
            out[#out + 1] = ev
        end
    end
    return out
end

--- Wires ONE online, K9-modeled player plus ONE registered (not
--- necessarily "online" in the GetPlayers() sense -- see this section's
--- own note below on why that distinction does not matter here) handler
--- citizenid, partners them, and puts the K9 online. Does NOT run a tick
--- -- callers do that themselves so they can inspect state at whichever
--- point in the sequence they care about.
--- @param f table
--- @param opts table? -- { k9Src, k9Citizenid, handlerSrc, handlerCitizenid }
--- @return number k9Src, number ped, number handlerSrc
local function wirePartneredK9(f, opts)
    opts = opts or {}
    local k9Src = opts.k9Src or 1
    local k9Citizenid = opts.k9Citizenid or 'K9-CID'
    local handlerSrc = opts.handlerSrc or 10
    local handlerCitizenid = opts.handlerCitizenid or 'HANDLER-CID'
    local ped = k9Src * 100

    f.setPlayer(k9Src, k9Citizenid)
    f.setPed(k9Src, ped)
    f.setModel(ped, 555)
    f.setIsK9Model(555, true)
    f.setCoords(ped, 0, 0, 0)
    f.setPlayer(handlerSrc, handlerCitizenid)
    f.setPartner(k9Citizenid, handlerCitizenid)
    f.setOnline({ k9Src })

    return k9Src, ped, handlerSrc
end

t.test('HANDLER CONDITION BADGE: a genuinely partnered, online handler receives exactly one condition push per changed tick', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrc = wirePartneredK9(f)

    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 1)
    t.equals(events[1].target, handlerSrc)
    t.isTrue(events[1].args[1].visible)
end)

t.test('HANDLER CONDITION BADGE: an UNPARTNERED K9 sends no condition update to anyone, ever, even across many ticks -- with the partnership MODULE genuinely loaded (a real resolver wired in for an unrelated pair), just no ROW for this citizenid', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    f.setPlayer(1, 'K9-LONELY')
    f.setPed(1, 100)
    f.setModel(100, 555)
    f.setIsK9Model(555, true)
    f.setCoords(100, 0, 0, 0)
    f.setOnline({ 1 })
    -- setPartner for a COMPLETELY UNRELATED pair -- this wires the real
    -- GetActivePartnerCitizenId resolver function into env (module
    -- genuinely "loaded"), while 'K9-LONELY' itself is left with no row
    -- at all -- distinct from the dedicated module-ABSENT test below,
    -- which exercises the OTHER absence shape (GetActivePartnerCitizenId
    -- not a function at all).
    f.setPlayer(2, 'SOME-OTHER-K9')
    f.setPlayer(20, 'SOME-OTHER-HANDLER')
    f.setPartner('SOME-OTHER-K9', 'SOME-OTHER-HANDLER')

    f.runOneTick()
    f.runOneTick()
    f.runOneTick()

    t.equals(#partnerConditionEvents(f), 0)
end)

t.test('HANDLER CONDITION BADGE: server/partnership.lua module absent (GetActivePartnerCitizenId not a function at all) is a silent no-op, never a crash', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    f.setPlayer(1, 'K9-NOMOD')
    f.setPed(1, 100)
    f.setModel(100, 555)
    f.setIsK9Model(555, true)
    f.setCoords(100, 0, 0, 0)
    f.setOnline({ 1 })
    f.setNoPartnershipModule()

    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'TickWellbeing must never crash just because server/partnership.lua never loaded')
    t.equals(#partnerConditionEvents(f), 0)
end)

t.test('HANDLER CONDITION BADGE: Config.Features.HandlerPartnership = false is treated exactly like "no partnership" -- gated even when GetActivePartnerCitizenId WOULD have resolved a real partner', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = false } })
    wirePartneredK9(f)

    f.runOneTick()

    t.equals(#partnerConditionEvents(f), 0, 'the feature flag must be checked even though this K9 genuinely has an active partnership')
end)

t.test('HANDLER CONDITION BADGE: a handler receives condition updates ONLY for their OWN bonded K9 partner, never for an unrelated K9 -- two independent pairs, cross-checked both ways', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrcA = wirePartneredK9(f, { k9Src = 1, k9Citizenid = 'K9-A', handlerSrc = 10, handlerCitizenid = 'HANDLER-A' })

    -- A second, completely independent pair -- different K9, different
    -- handler, no relationship to the first pair at all.
    f.setPlayer(2, 'K9-B')
    f.setPed(2, 200)
    f.setModel(200, 555)
    f.setIsK9Model(555, true)
    f.setCoords(200, 5000, 5000, 0) -- far away -- irrelevant, this feature never uses position at all
    f.setPlayer(20, 'HANDLER-B')
    f.setPartner('K9-B', 'HANDLER-B')
    f.setOnline({ 1, 2 })

    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'exactly one push per genuinely partnered, online K9 this tick')

    local sawA, sawB = false, false
    for _, ev in ipairs(events) do
        t.isTrue(ev.target == handlerSrcA or ev.target == 20, 'no target outside the two genuine handlers in this test ever receives this event')
        if ev.target == handlerSrcA then sawA = true end
        if ev.target == 20 then sawB = true end
    end
    t.isTrue(sawA, "K9-A's real partner (HANDLER-A) received their own push")
    t.isTrue(sawB, "K9-B's real partner (HANDLER-B) received their own push, for THEIR OWN K9, never K9-A's")
end)

-- ------------------------------------------------------------------
-- THRESHOLD-TO-WORD PINS -- "coarse, not numeric," derived from the
-- EXISTING per-stat threshold, never a new number. Each test sets its
-- OWN stat's threshold to EXACTLY the stat's known starting value (see
-- EnsureStats above -- Fatigue starts at its own `.max`) so the tag's own
-- boundary comparison (`<=`/`>=`) is pinned on ONE deterministic real
-- tick. Fatigue's own first-tick arithmetic already lands back on its
-- exact starting value with no override needed: lastCoords is nil on tick
-- 1, so no sprint/rest branch runs at all.
-- ------------------------------------------------------------------

--- @param f table
--- @return string[]? tags -- nil if no partnerConditionUpdate was ever sent
local function lastHandlerTags(f)
    local events = partnerConditionEvents(f)
    local last = events[#events]
    return last and last.args[1].tags
end

--- @param tags string[]?
--- @param tag string
--- @return boolean
local function tagsContain(tags, tag)
    if not tags then return false end
    for _, v in ipairs(tags) do
        if v == tag then return true end
    end
    return false
end

t.test('THRESHOLD PIN: Fatigue <= speedPenaltyThreshold reports "tired" -- absent one unit above it, present exactly at it', function()
    local cfgAbsent = baselineWellbeingConfig()
    cfgAbsent.Fatigue.speedPenaltyThreshold = 99 -- starting fatigue (max=100) is one unit ABOVE this
    local fAbsent = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgAbsent })
    wirePartneredK9(fAbsent)
    fAbsent.runOneTick()
    t.isFalse(tagsContain(lastHandlerTags(fAbsent), 'tired'))

    local cfgPresent = baselineWellbeingConfig()
    cfgPresent.Fatigue.speedPenaltyThreshold = 100 -- starting fatigue is EXACTLY this
    local fPresent = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true }, wellbeingCfg = cfgPresent })
    wirePartneredK9(fPresent)
    fPresent.runOneTick()
    t.isTrue(tagsContain(lastHandlerTags(fPresent), 'tired'))
end)

-- ------------------------------------------------------------------
-- NEVER A TRACKER -- assert on the REAL payload shape, not on intent.
-- ------------------------------------------------------------------

-- ------------------------------------------------------------------
-- "GATE THE START, NEVER THE STOP" -- the display must stop cleanly.
-- ------------------------------------------------------------------

t.test('STOPS CLEANLY: partnership ending sends an explicit visible=false clear on the very next tick -- self-healing, not stranded', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrc = wirePartneredK9(f)
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1, 'sanity: the handler really did get an initial visible push')

    f.clearPartner('K9-CID') -- partnership ends -- GetActivePartnerCitizenId now resolves nil for both parties
    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2)
    local clearEvent = events[2]
    t.equals(clearEvent.target, handlerSrc)
    t.isFalse(clearEvent.args[1].visible)
    t.equals(#clearEvent.args[1].tags, 0)

    -- And it stays cleared -- no further stray pushes once there is
    -- nothing left to report.
    f.runOneTick()
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 2)
end)

t.test('STOPS CLEANLY: the K9 (not the handler) disconnecting clears the badge IMMEDIATELY, via playerDropped -- never waits for a future tick that will never come for this citizenid again', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local k9Src, _, handlerSrc = wirePartneredK9(f)
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1)

    f.firePlayerDropped(k9Src)

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'the clear must be sent synchronously from playerDropped, with no further tick needed')
    t.equals(events[2].target, handlerSrc)
    t.isFalse(events[2].args[1].visible)

    -- GetPlayers() no longer includes the disconnected K9 -- proves this
    -- citizenid would otherwise never be revisited by TickWellbeing again,
    -- which is exactly why the immediate clear above matters.
    f.setOnline({})
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 2, 'no further pushes for a citizenid TickWellbeing will never iterate again')
end)

t.test('STOPS CLEANLY: the HANDLER (not the K9) disconnecting needs no explicit push (nobody to receive one), and a later RECONNECT under a new source id forces a fresh push rather than being suppressed as "unchanged"', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    wirePartneredK9(f, { handlerSrc = 10, handlerCitizenid = 'HANDLER-RECONNECT' })
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1)

    f.clearPlayer(10) -- handler goes offline -- GetPlayerByCitizenId('HANDLER-RECONNECT') now resolves nil
    local ok = pcall(f.runOneTick)
    t.isTrue(ok, 'an offline handler must never crash the tick')
    t.equals(#partnerConditionEvents(f), 1, 'nothing to push to -- no event, but no error either')

    -- Handler reconnects under a DIFFERENT server id (a real, common case --
    -- FiveM does not guarantee the same id back).
    f.setPlayer(11, 'HANDLER-RECONNECT')
    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'the reconnect must force a fresh push, not be suppressed by an unchanged tagsKey against the OLD source id')
    t.equals(events[2].target, 11)
    t.isTrue(events[2].args[1].visible)
end)

t.test('STOPS CLEANLY: every wellbeing stat system switched off at once clears every currently-visible badge from the CreateThread loop\'s own else-branch -- the one iteration TickWellbeing itself never runs', function()
    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true, HandlerPartnership = true } })
    local _, _, handlerSrc = wirePartneredK9(f)
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 1)

    f.config.Features.FatigueSystem = false -- the ONLY flag that was on -- now every one of the six is off

    f.runOneTick()

    local events = partnerConditionEvents(f)
    t.equals(#events, 2, 'the else-branch must clear the stranded badge on this very next tick, even though TickWellbeing itself never runs')
    t.equals(events[2].target, handlerSrc)
    t.isFalse(events[2].args[1].visible)

    -- Idempotent -- repeatedly idling with everything off must never
    -- resend the clear over and over.
    f.runOneTick()
    f.runOneTick()
    t.equals(#partnerConditionEvents(f), 2)
end)

-- ============================================================================
-- DATABASE PERSISTENCE (this pass, coder-backend). See server/wellbeing.lua's
-- own header "DATABASE PERSISTENCE" section for the full design writeup this
-- section proves. K9Store is ABSENT from every fixture above (none of them
-- pass opts.k9Store) -- every one of those 112 tests is therefore already a
-- standing regression proof that this whole feature is a pure ADDITION: with
-- no K9Store at all, EnsureStats/FlushDirtyWellbeingStats/
-- EvictStaleWellbeingEntries must all behave EXACTLY as they did before this
-- pass (WellbeingPersistenceAvailable() is false throughout). The tests below
-- are the NEW behaviour, exercised with a real, controllable fake K9Store.
-- ============================================================================

--- Minimal, deterministic in-memory K9Store stub mirroring the EXACT
--- contract server/wellbeing.lua's own WellbeingPersistenceAvailable/
--- EnsureStats/FlushDirtyWellbeingStats/FlushWellbeingEntryNow call sites
--- depend on: Wellbeing_Get mirrors MySQL.single.await (nil = no row);
--- Wellbeing_Upsert mirrors this resource's own SafeWrite-style bespoke
--- contract (returns true/false, never throws in the ordinary case --
--- `setThrowOnUpsert`/`setThrowOnGet` below simulate the DISCONNECTED-
--- DATABASE case specifically, for the fail-direction tests). `rows`
--- (the durable "database" content) is mutated ONLY on a genuinely
--- successful upsert -- `upsertCalls` records every ATTEMPT, succeeded or
--- not, so a test can tell "did this write really persist" (`ctl.rows`)
--- apart from "was a write even attempted" (`ctl.upsertCallCount()`).
--- @return table k9Store, table ctl
local function newFakeK9Store()
    local rows = {}
    local getCalls, upsertCalls, waitCalls = {}, {}, {}
    local throwOnGet, throwOnUpsert, failUpsert = false, false, false
    -- BOOT-ORDER SETTLEMENT (this pass) -- defaults to `true` (settled,
    -- exactly what every real production boot looks like within a few
    -- milliseconds of the schema probe's own real query returning) so
    -- every ONE of the 112+ pre-existing tests above this section, none of
    -- which calls `ctl.setSchemaSettled`, keeps observing precisely the
    -- same load behaviour it already asserted on before this pass existed.
    -- Only `setSchemaSettled(false)` (the dedicated tests below) exercises
    -- the new branch.
    local schemaSettled = true

    local function shallowCopy(tbl)
        local out = {}
        for k, v in pairs(tbl) do out[k] = v end
        return out
    end

    local store = {
        Wellbeing_Get = function(citizenid)
            getCalls[#getCalls + 1] = citizenid
            if throwOnGet then error('simulated K9Store.Wellbeing_Get failure (database unreachable)') end
            local row = rows[citizenid]
            return row and shallowCopy(row) or nil
        end,
        Wellbeing_Upsert = function(citizenid, row)
            upsertCalls[#upsertCalls + 1] = { citizenid = citizenid, row = row }
            if throwOnUpsert then error('simulated K9Store.Wellbeing_Upsert failure (database unreachable)') end
            if failUpsert then return false end
            rows[citizenid] = shallowCopy(row)
            return true
        end,
        -- BOOT-ORDER SETTLEMENT (this pass) -- mirrors the REAL
        -- K9Store.WaitForSchemaCheckToSettle's own return contract exactly
        -- (server/datastore.lua): `true` once the schema-collision
        -- determination is final, `false` only while it genuinely has not
        -- settled yet. This fake never actually waits/yields (there is
        -- nothing timing-dependent to model here -- see this file's own
        -- FAIL DIRECTION tests just below for why a plain boolean is
        -- sufficient to pin EnsureStats' own two branches).
        WaitForSchemaCheckToSettle = function()
            waitCalls[#waitCalls + 1] = true
            return schemaSettled
        end,
    }

    return store, {
        rows = rows,
        seedRow = function(citizenid, row) rows[citizenid] = row end,
        setThrowOnGet = function(v) throwOnGet = v end,
        setThrowOnUpsert = function(v) throwOnUpsert = v end,
        setFailUpsert = function(v) failUpsert = v end,
        setSchemaSettled = function(v) schemaSettled = v end,
        getCallCount = function() return #getCalls end,
        upsertCallCount = function() return #upsertCalls end,
        waitCallCount = function() return #waitCalls end,
    }
end


-- ============================================================================
-- BOOT-ORDER SETTLEMENT (boot-order-race audit, this pass -- lifecycle QA
-- finding: EnsureStats read K9Store.Wellbeing_Get with no call to
-- K9Store.WaitForSchemaCheckToSettle at all, the one real gap left in
-- server/datastore.lua's own authoritative caller list; see that file's own
-- updated list entry for server/wellbeing.lua for the full trigger writeup).
-- Mirrors the shape tests/datastore_spec.lua's own SETTLEMENT section uses to
-- pin K9Store.WaitForSchemaCheckToSettle itself: a plain, controllable
-- boolean answer is enough here (this file's own persistence layer never
-- talks to K9Store.WaitForSchemaCheckToSettle's real bounded-poll timing --
-- that mechanism is fully proven once, in tests/datastore_spec.lua, and is
-- not re-derived per caller anywhere else in this resource's own test suite
-- either -- see e.g. tests/permissionkeycatalog_spec.lua's/
-- tests/xptiereditor_spec.lua's own equivalent pinning tests, which stub the
-- SAME plain boolean rather than re-running a real coroutine race).
-- ============================================================================

t.test('BOOT-ORDER SETTLEMENT: a not-yet-settled schema check skips the database read entirely and degrades to the exact same fresh default as no database at all -- logged, never a fourth outcome', function()
    local k9Store, ctl = newFakeK9Store()
    ctl.setSchemaSettled(false)
    -- Seeds a REAL, legitimate row first -- the strongest possible control:
    -- if this test passed merely because there was nothing to load anyway,
    -- it would prove nothing about the gate actually skipping the read.
    ctl.seedRow('K9-CID', { fatigue = 50 })

    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, k9Store = k9Store })
    f.setPlayer(1, 'K9-CID')

    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)

    t.equals(ctl.waitCallCount(), 1, 'CONTROL: the gate was genuinely consulted, not skipped')
    t.equals(ctl.getCallCount(), 0, 'CONTROL: Wellbeing_Get must NEVER be called while the schema-collision determination is still unsettled -- even though a real, seeded row exists and would otherwise load successfully')
    t.equals(snap.fatigue, 100, 'degrades to the exact same fresh default as no database at all -- never the seeded row')
    t.contains(table.concat(f.printedLines, '\n'), 'schema-collision check had not finished', 'the fallback must be logged clearly, never silent')
end)

t.test('BOOT-ORDER SETTLEMENT control (the positive case, proving the gate does not just always skip): once the schema check has settled, EnsureStats performs its real read exactly as before and picks up the legitimate persisted row', function()
    local k9Store, ctl = newFakeK9Store()
    ctl.setSchemaSettled(true) -- explicit, even though this is the default -- this test is ABOUT this value
    ctl.seedRow('K9-CID', { fatigue = 50 })

    local f = newWellbeingFixture({ featuresOverride = { FatigueSystem = true }, k9Store = k9Store })
    f.setPlayer(1, 'K9-CID')

    local snap = f.invokeCallback('john-k9:server:getWellbeingSnapshot', 1)

    t.equals(ctl.waitCallCount(), 1, 'CONTROL: the gate was genuinely consulted')
    t.equals(ctl.getCallCount(), 1, 'CONTROL: settled -- the real read genuinely happened')
    t.equals(snap.fatigue, 50, 'the legitimate persisted row is loaded verbatim once settled -- the gate must never suppress a real, confirmed-safe read')
end)

-- ============================================================================
-- PROOF SCAFFOLDING CHECK (rule 6 of this task): this file must never ship a
-- leftover "flip this to force red" switch. Grepped by hand, this pass:
-- `grep -n "FORCE_RED\|DEBUG_BREAK\|TEMP_DISABLE" tests/wellbeing_spec.lua`
-- returns nothing -- every red-then-green proof this task required
-- (PERSISTENCE ANTI-FARM above, and the LOAD FREEZE test) was verified by
-- hand-editing server/wellbeing.lua's EnsureStats to ignore `loadedRow` and
-- reverting immediately after confirming the specific test went red and then
-- green again -- never by leaving a switch in this file. The three BOOT-ORDER
-- SETTLEMENT tests immediately above were verified the same way, this pass:
-- temporarily replacing EnsureStats' own `local schemaSettled =
-- type(K9Store.WaitForSchemaCheckToSettle) ~= 'function' or
-- K9Store.WaitForSchemaCheckToSettle()` with a version that still CALLS
-- K9Store.WaitForSchemaCheckToSettle() (so the "gate was consulted" CONTROL in
-- every one of the three tests kept passing, isolating the break to the ONE
-- thing actually broken -- ignoring the real return value) but then
-- hard-codes `schemaSettled = true` regardless of the answer. That turned
-- ONLY the first (negative) test red -- `getCallCount()` read 1 instead of
-- the expected 0, and the snapshot came back holding the seeded row's real
-- values instead of fresh defaults, since the query ran despite
-- settled=false -- while the second (positive) and third (paid-once) tests
-- stayed green throughout, since both already exercise settled=true and
-- never depended on the false branch being honored. Confirming the first
-- test was the one actually exercising the new gate, not a fixture that
-- never reached it, and that the fix does not accidentally make every case
-- fall through to the same branch. Reverting restored all three to green.
-- ============================================================================


-- ========================================================================
-- FLUSH ON RESOURCE STOP (lifecycle QA finding, this pass). This file had
-- NO onResourceStop handler at all -- the one stateful subsystem in this
-- resource that was missed, while kennel, combat, vehicle, propattachment,
-- fetch, bonetool, equipmentshop, hud and tablet all had one.
--
-- What it cost: `restart john-k9` discarded WellbeingStats wholesale
-- and the next boot reloaded each citizenid's LAST-FLUSHED row, silently
-- reverting up to flushIntervalMs (60s by default) of drift for every
-- online K9 and handler, to a value that looks entirely plausible.
-- ========================================================================
os.exit(t.summary())
