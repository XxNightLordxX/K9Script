--[[
    tests/clientinventory_spec.lua

    Client-side spec for client/inventory.lua -- CLOSING A GAP, not covering
    a regression: this file was migrated to route its stash-open call
    through K9Compat.Get('inventory') by a prior pass in this same coder-
    backend "wire the inventory compat layer" task, but shipped with NO spec
    of its own at all (unlike its server half, tests/inventory_spec.lua).
    Flagged by the coordinator mid-task; closed here rather than left open,
    per this task's own "test fixtures are part of the work" instruction.

    Follows tests/clientwellbeing_spec.lua's / tests/clientsearch_spec.lua's
    own established pattern for a file routed through the compat layer: the
    REAL, unmodified shared/compat/core.lua + the relevant real adapter file
    (shared/compat/target.lua AND shared/compat/inventory.lua both, since
    this file consumes BOTH systems) are loaded into this sandbox alongside
    the real client/inventory.lua -- never a hand-written fake translation
    layer that would just assert against itself. `GetResourceState` /
    `exports` are the only two knobs a test needs to steer which backend (if
    any) K9Compat actually resolves to.

    THIS PASS'S PRIORITY, matching the actual value of this task per the
    coordinator's own framing (STUB-DEGRADE, not the mechanical swap):
    1. The HAPPY PATH on the CONFIRMED reference backend (ox_inventory) --
       proving `OpenK9InventoryForNetId` still calls the real
       `exports.ox_inventory:openInventory('stash', stashId)` shape end to
       end through the compat layer, unchanged from what this file called
       directly before its migration.
    2. STUB-DEGRADE: no inventory backend detected/started at all. Proves
       the no-op stub's falsy OpenStash collapses into the SAME
       `inventory.unable_to_open_generic` player-facing notify this file
       already used for an ox_inventory-missing session before this pass --
       a clean "feature switched off" degrade, never a hang or an uncaught
       error, and never a silent no-feedback failure either.
    3. The existing reason-handling table (K9_INVENTORY_REASON_MESSAGES) and
       the on_cooldown/request_in_progress silent-no-op carve-out, both
       pre-existing and untouched by the compat-layer migration, get at
       least one assertion each so a future edit to either can't regress
       silently for lack of any coverage at all.
    4. The ox_target option dispatch (RegisterK9InventoryOxTargetOption)
       registers on this resource's own start and re-registers on whichever
       resource K9Compat.Which('target') resolves to restarting -- mirrors
       clientwellbeing_spec.lua's own oxTargetStub verification shape.
    5. RequestOpenOwnK9Inventory's own CanShowK9UI/Config.Features.K9Inventory
       gates, since this resource-global is this file's one caller-facing
       seam per its own header.

    STUBBING EFFORT: proportionate. Every native this file touches directly
    is a small, controllable stand-in (NetworkGetPlayerIndexFromPed/
    PlayerId/NetworkGetNetworkIdFromEntity/PlayerPedId/IsEntityModelK9 --
    the last one a plain resource-global this file reads at canInteract-
    invocation time, per its own header, never at load time, so a bare
    stub function is sufficient without loading client/main.lua for it).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

--- Sentinel returned by `queueCallbackThrow()` -- same rationale/shape as
--- every other spec in this suite that models ox_lib's real
--- lib.callback.await throwing on a timeout/rejection rather than
--- returning nil.
local THROW = setmetatable({}, { __tostring = function() return 'THROW' end })

--- @param opts { startedResources: table<string,boolean>?, features: table? }?
local function newInventoryFixture(opts)
    opts = opts or {}

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Only resources explicitly marked started in `opts.startedResources`
    -- resolve as such -- every candidate config.lua's real
    -- Config.Compat.Systems.{target,inventory}.candidates lists defaults to
    -- 'missing', matching every other spec's own "nothing is running unless
    -- a test says so" posture.
    local startedResources = opts.startedResources or {}
    local function GetResourceState(name)
        return startedResources[name] and 'started' or 'missing'
    end

    -- ox_target export stub -- byte-for-byte the same shape
    -- tests/clientwellbeing_spec.lua's own oxTargetStub uses, satisfying
    -- shared/compat/target.lua's OxTargetFactory required-method list so
    -- detection resolves to the real ox_target adapter whenever
    -- startedResources.ox_target is true.
    local addGlobalPlayerCalls = {}
    local oxTargetStub = {}
    function oxTargetStub.addGlobalPlayer(_, defs) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = defs end
    function oxTargetStub.addGlobalVehicle() end
    function oxTargetStub.addGlobalObject() end
    function oxTargetStub.addModel() end
    function oxTargetStub.addSphereZone() end
    function oxTargetStub.removeGlobalPlayer() end
    function oxTargetStub.removeGlobalVehicle() end
    function oxTargetStub.removeGlobalObject() end
    function oxTargetStub.removeModel() end
    function oxTargetStub.removeZone() end
    function oxTargetStub.addLocalEntity() end
    function oxTargetStub.removeLocalEntity() end

    -- ox_inventory export stub -- only the THREE exports
    -- shared/compat/inventory.lua's BuildOxInventoryClient actually probes
    -- for capability (openInventory/useItem/Items); this file's own real
    -- call site only ever exercises `openInventory`, so that is the only
    -- one this fixture records calls into.
    local openInventoryCalls = {}
    local oxInventoryStub = {
        openInventory = function(_self, invType, id)
            openInventoryCalls[#openInventoryCalls + 1] = { invType = invType, id = id }
        end,
        useItem = function() end,
        Items = function() return nil end,
    }

    local exportsProxy = setmetatable({}, {
        __index = function(_, resourceName)
            if not startedResources[resourceName] then
                error(('simulated: exports access on non-started resource "%s" threw'):format(resourceName))
            end
            if resourceName == 'ox_target' then return oxTargetStub end
            if resourceName == 'ox_inventory' then return oxInventoryStub end
            return {}
        end,
    })

    local resourceStartHandlers = {}
    local otherEventHandlers = {}
    local function AddEventHandler(eventName, handler)
        if eventName == 'onResourceStart' then
            resourceStartHandlers[#resourceStartHandlers + 1] = handler
        else
            otherEventHandlers[eventName] = otherEventHandlers[eventName] or {}
            otherEventHandlers[eventName][#otherEventHandlers[eventName] + 1] = handler
        end
    end
    local function GetCurrentResourceName() return 'john-k9' end
    local function IsDuplicityVersion() return false end -- client realm, for shared/compat/core.lua

    -- lib.callback.await -- one shared FIFO queue, sufficient because every
    -- test below only ever has one callback-awaiting action in flight.
    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local next = table.remove(callbackResponses, 1)
        if next == THROW then
            error('simulated lib.callback.await failure (timeout/rejection)')
        end
        return next
    end

    local notifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    local isOwnModelK9ByEntity = {} -- entity -> boolean, for IsEntityModelK9
    local function IsEntityModelK9(entity) return isOwnModelK9ByEntity[entity] == true end

    local localPlayerId = 0
    local playerIndexByPed = {} -- entity -> NetworkGetPlayerIndexFromPed result
    local function NetworkGetPlayerIndexFromPed(entity) return playerIndexByPed[entity] end
    local function PlayerId() return localPlayerId end

    local netIdByEntity = {} -- entity -> netId
    local function NetworkGetNetworkIdFromEntity(entity) return netIdByEntity[entity] or entity end

    local myPed = 1
    local function PlayerPedId() return myPed end

    local canShowK9UI = true
    local canShowK9UICallCount = 0
    local denyCalls = 0
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local overrides = {
        print = printStub,
        GetResourceState = GetResourceState,
        exports = exportsProxy,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        IsDuplicityVersion = IsDuplicityVersion,
        lib = lib,
        IsEntityModelK9 = IsEntityModelK9,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        PlayerId = PlayerId,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        PlayerPedId = PlayerPedId,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        QBX = { PlayerData = { job = { name = 'police' } } },
        -- Menu-parity pass (this session): client/inventory.lua now also
        -- registers a 'k9gear' chat command (RegisterCommand) alongside its
        -- existing ox_target option / resource-global -- a plain no-op
        -- stub, same shape as every other fixture in this suite that loads a
        -- production file registering a command it does not itself need to
        -- exercise.
        RegisterCommand = function(_name, _handler, _restricted) end,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- Explicit, per this suite's own convention: never depend on
    -- config.lua's own shipped Config.Features defaults.
    env.Config.Features.K9Inventory = false
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end
    -- ALWAYS keep department membership realistic for the canInteract
    -- display-only check -- 'police' is already a real Config.Departments
    -- key in the shipped config.
    env.QBX.PlayerData.job.name = next(env.Config.Departments) or 'police'

    -- REAL K9Compat, REAL target + inventory adapters -- must load before
    -- client/inventory.lua, which reads the `K9Compat` global at both
    -- onResourceStart-handler-fire time (target option registration) and
    -- OpenK9InventoryForNetId call time (inventory routing).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/target.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)

    Sandbox.loadInto('../client/inventory.lua', env)

    for _, fn in ipairs(resourceStartHandlers) do
        fn('john-k9')
    end

    return {
        env = env,
        printedLines = printedLines,
        notifyCalls = notifyCalls,
        openInventoryCalls = openInventoryCalls,
        addGlobalPlayerCallCount = function() return #addGlobalPlayerCalls end,
        petOption = function()
            for _, defs in ipairs(addGlobalPlayerCalls) do
                for _, def in ipairs(defs) do
                    if def.name == 'john-k9:openK9Inventory' then return def end
                end
            end
        end,

        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        queueCallbackThrow = function() callbackResponses[#callbackResponses + 1] = THROW end,
        callbackCallCount = function() return #callbackCallLog end,

        setEntityIsK9Model = function(entity, v) isOwnModelK9ByEntity[entity] = v end,
        setPlayerIndexForPed = function(entity, idx) playerIndexByPed[entity] = idx end,
        setLocalPlayerId = function(v) localPlayerId = v end,
        setNetIdForEntity = function(entity, netId) netIdByEntity[entity] = netId end,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        denyCallCount = function() return denyCalls end,

        fireResourceStart = function(resourceName)
            for _, fn in ipairs(resourceStartHandlers) do fn(resourceName) end
        end,

        countPrintsContaining = function(needle)
            local n = 0
            for _, line in ipairs(printedLines) do
                if line:find(needle, 1, true) then n = n + 1 end
            end
            return n
        end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity
-- ----------------------------------------------------------------------

t.test('client/inventory.lua loads, exposes RequestOpenOwnK9Inventory, and registers the ox_target option on its own start', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true } })
    t.isNotNil(f.env.RequestOpenOwnK9Inventory)
    t.isNotNil(f.petOption(), 'the "Open K9 Gear" ox_target option must be registered on this resource\'s own onResourceStart')
end)

-- ----------------------------------------------------------------------
-- SECTION A -- HAPPY PATH on the CONFIRMED reference backend (ox_inventory).
-- Proves the compat-layer migration changed nothing observable: the exact
-- same `exports.ox_inventory:openInventory('stash', stashId)` shape this
-- file called directly before this pass still fires, now via
-- K9Compat.Get('inventory').OpenStash.
-- ----------------------------------------------------------------------

t.test('happy path: server grants access -> OpenStash calls the real ox_inventory openInventory export with (\'stash\', stashId)', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true, ox_inventory = true } })
    f.queueCallbackResponse({ ok = true, stashId = 'k9inv-ABC123' })

    f.petOption().onSelect({ entity = 500 })

    t.equals(f.callbackCallCount(), 1)
    t.equals(#f.openInventoryCalls, 1, 'exactly one openInventory call must be attempted once access is granted')
    t.equals(f.openInventoryCalls[1].invType, 'stash')
    t.equals(f.openInventoryCalls[1].id, 'k9inv-ABC123')
    t.equals(#f.notifyCalls, 0, 'a successful open must not also show an error notify')
end)

-- ----------------------------------------------------------------------
-- SECTION B -- STUB-DEGRADE. THE actual point of this task, per the
-- coordinator's own framing: what happens when nothing usable is detected?
-- ----------------------------------------------------------------------

t.test('STUB-DEGRADE: no inventory backend detected at all -> generic error notify + a console warning, never an export call, never an uncaught error', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true } }) -- ox_inventory NOT started
    f.queueCallbackResponse({ ok = true, stashId = 'k9inv-ABC123' })

    local ok = pcall(function() f.petOption().onSelect({ entity = 500 }) end)

    t.isTrue(ok, 'an undetected inventory backend must never throw out of the onSelect handler')
    t.equals(#f.openInventoryCalls, 0, 'no export call may be attempted when nothing was detected')
    t.equals(#f.notifyCalls, 1, 'the player must still get SOME feedback -- a clean "feature switched off" degrade, never a silent failure')
    t.equals(f.notifyCalls[1].description, locale('inventory.unable_to_open_generic'))
    t.equals(f.notifyCalls[1].type, 'error')
    t.isTrue(f.countPrintsContaining('no usable inventory') > 0, 'operator-facing console warning must name the actual failure (no usable adapter detected), not a generic Lua error')
end)

t.test('STUB-DEGRADE: nothing at all detected (no ox_target, no ox_inventory) -- the ox_target option itself is still registered (target/inventory systems are independently pluggable), and the inventory open still degrades cleanly', function()
    local f = newInventoryFixture({ startedResources = {} })
    -- K9Compat.Get('target') resolves to the no-op stub here too, so
    -- AddGlobalPlayer is itself a stub method that does nothing -- this must
    -- not throw at RegisterK9InventoryOxTargetOption's own call site.
    local ok = pcall(function() end)
    t.isTrue(ok)
    t.equals(f.addGlobalPlayerCallCount(), 0, 'the no-op target stub never actually calls the real ox_target export -- nothing to record')
end)

-- ----------------------------------------------------------------------
-- SECTION C -- pre-existing reason handling, untouched by this pass's
-- migration, given at least one assertion each so a future edit can't
-- regress silently for lack of any coverage.
-- ----------------------------------------------------------------------

t.test('reason handling: a documented rejection reason produces its own distinct notify, on_cooldown/request_in_progress are silent no-ops, and an unrecognized reason falls back to the generic message', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true, ox_inventory = true } })

    f.queueCallbackResponse({ ok = false, reason = 'too_far' })
    f.petOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('inventory.reason_too_far'))

    f.queueCallbackResponse({ ok = false, reason = 'on_cooldown' })
    f.petOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1, 'on_cooldown must be a silent no-op -- routine, expected traffic')

    f.queueCallbackResponse({ ok = false, reason = 'request_in_progress' })
    f.petOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 1, 'request_in_progress must also be a silent no-op')

    f.queueCallbackResponse({ ok = false, reason = 'a_totally_unrecognized_future_reason' })
    f.petOption().onSelect({ entity = 500 })
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, locale('inventory.unable_to_open_generic'))

    t.equals(#f.openInventoryCalls, 0, 'no rejection path may ever reach the actual openInventory export call')
end)

t.test('FAIL-CLOSED GUARD: lib.callback.await throwing degrades to a silent no-op, never an uncaught error, never an export call', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true, ox_inventory = true } })
    f.queueCallbackThrow()
    local ok = pcall(function() f.petOption().onSelect({ entity = 500 }) end)
    t.isTrue(ok, 'a thrown lib.callback.await must never escape onSelect uncaught')
    t.equals(#f.notifyCalls, 0)
    t.equals(#f.openInventoryCalls, 0)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- ox_target option dispatch (independent of the inventory
-- routing above): re-registers on whichever resource K9Compat.Which('target')
-- resolves to restarting, never on an unrelated resource's start.
-- ----------------------------------------------------------------------

t.test('ox_target option dispatch: re-registers when the resolved target backend (ox_target) restarts, not on an unrelated resource start', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true } })
    t.equals(f.addGlobalPlayerCallCount(), 1, 'sanity: registered once already on this resource\'s own start')

    f.fireResourceStart('some_unrelated_resource')
    t.equals(f.addGlobalPlayerCallCount(), 1, 'an unrelated resource starting must never re-trigger registration')

    f.fireResourceStart('ox_target')
    t.equals(f.addGlobalPlayerCallCount(), 2, 'ox_target (the resolved target backend) restarting must re-register the option')
end)

-- ----------------------------------------------------------------------
-- SECTION E -- RequestOpenOwnK9Inventory (the radial self-service entry
-- point), gated on CanShowK9UI and Config.Features.K9Inventory.
-- ----------------------------------------------------------------------

t.test('RequestOpenOwnK9Inventory: access denied -> DenyK9UIAccess fires, nothing else happens', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true }, features = { K9Inventory = true } })
    f.setCanShowK9UI(false)
    f.env.RequestOpenOwnK9Inventory()
    t.equals(f.denyCallCount(), 1)
    t.equals(f.callbackCallCount(), 0)
end)

t.test('RequestOpenOwnK9Inventory: feature disabled -> a feature_disabled notify, no server round trip', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true }, features = { K9Inventory = false } })
    f.env.RequestOpenOwnK9Inventory()
    t.equals(f.callbackCallCount(), 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('inventory.reason_feature_disabled'))
end)

t.test('RequestOpenOwnK9Inventory: access granted and feature on -> resolves the LOCAL PLAYER\'S OWN ped netId and requests it from the server', function()
    local f = newInventoryFixture({ startedResources = { ox_target = true, ox_inventory = true }, features = { K9Inventory = true } })
    f.setNetIdForEntity(1, 999) -- PlayerPedId() stub returns 1
    f.queueCallbackResponse({ ok = true, stashId = 'k9inv-SELF' })

    f.env.RequestOpenOwnK9Inventory()

    t.equals(f.callbackCallCount(), 1)
    t.equals(#f.openInventoryCalls, 1)
    t.equals(f.openInventoryCalls[1].id, 'k9inv-SELF')
end)

os.exit(t.summary())
