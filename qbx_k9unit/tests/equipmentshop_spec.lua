--[[
    tests/equipmentshop_spec.lua

    Tests for server/equipmentshop.lua -- DEVELOPER_REFERENCE.md Part B §6 (the K9
    equipment shop). Loads the REAL, unmodified production file into an
    isolated sandbox and drives its onResourceStart handler directly --
    same style as tests/wellbeing_spec.lua's own "STARTUP VALIDATION"
    section, which this file's WarnIfItemMissing pattern is a deliberate,
    documented duplicate of (see server/equipmentshop.lua's own header,
    "THE WARNING PATTERN").

    Covers:
      - Config.Features.K9EquipmentShop absent/false: a total, silent
        no-op -- zero prints, zero exports.ox_inventory calls at all
        (matches server/integrations.lua's own documented "ABSENCE IS A
        CLEAN NO-OP" principle, applied here to a flag that may not exist
        yet at all, not merely one that exists and is off).
      - Config.K9EquipmentShop missing/malformed while the flag is true: a
        loud warning, never a thrown error, and no RegisterShop call.
      - Per-item validation: a missing/invalid price, or an item name that
        does not resolve in ox_inventory's own registry, is warned about BY
        NAME and SKIPPED -- never silently substituted, never aborting the
        whole shop over one bad entry.
      - Every item missing at once: the shop is NOT registered at all (there
        would be nothing to sell) -- still just a warning, never a throw.
      - currencyItem missing from ox_inventory's own registry: warned about,
        but does NOT block registration (a missing cash item is an operator
        misconfiguration to fix, not a reason to withhold the whole shop).
      - groups derived from Config.Departments, correctly, with no new
        config field of its own.
      - exports.ox_inventory:RegisterShop itself throwing (an incompatible
        ox_inventory version): caught, warned, never propagates.
      - The happy path: exact `inventory`/`groups`/`name` shape handed to
        RegisterShop, and the exact success log line.
      - GetCurrentResourceName() guard: an onResourceStart for a different
        resource entirely produces zero output and zero calls.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- RUNTIME SHOP LOCATIONS fake database -- backs k9_equipment_shop_locations
-- / k9_equipment_shop_locations_audit for the new callbacks this pass adds
-- (equipmentShopGetLocations/AddLocation/MoveLocation/RemoveLocation).
-- Same style as tests/runtimecontrol_spec.lua's own newWorld()/
-- makeQueryAwait(): a fake in-memory table mutated by the REAL production
-- callbacks exactly like a real database would be, so a "survives a
-- restart" test can boot twice against the same world.
-- ----------------------------------------------------------------------

--- @return table world
local function newWorld()
    return {
        locations = {}, -- [id] = { x, y, z, heading, model, scenario, label, created_by, updated_by }
        audit = {},     -- array of { location_id, action, x, y, z, heading, model, scenario, label, changed_by }
        nextId = 1,
    }
end

--- @param world table
--- @return fun(sql: string, params: table): table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT id, x, y, z, heading, model, scenario, label FROM k9_equipment_shop_locations', 1, true) then
            local out = {}
            for id, row in pairs(world.locations) do
                out[#out + 1] = { id = id, x = row.x, y = row.y, z = row.z, heading = row.heading, model = row.model, scenario = row.scenario, label = row.label }
            end
            return out
        elseif sql:find('UPDATE k9_equipment_shop_locations SET', 1, true) then
            local x, y, z, heading, model, scenario, label, updatedBy, id = params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9]
            local row = world.locations[id]
            if row then
                row.x, row.y, row.z, row.heading, row.model, row.scenario, row.label, row.updated_by = x, y, z, heading, model, scenario, label, updatedBy
            end
            return {}
        elseif sql:find('DELETE FROM k9_equipment_shop_locations WHERE id', 1, true) then
            world.locations[params[1]] = nil
            return {}
        elseif sql:find('INSERT INTO k9_equipment_shop_locations_audit', 1, true) then
            world.audit[#world.audit + 1] = {
                location_id = params[1], action = params[2], x = params[3], y = params[4], z = params[5],
                heading = params[6], model = params[7], scenario = params[8], label = params[9], changed_by = params[10],
            }
            return {}
        end
        error('equipmentshop_spec test stub: unhandled SQL (query.await): ' .. tostring(sql))
    end
end

--- @param world table
--- @return fun(sql: string, params: table): number
local function makeInsertAwait(world)
    return function(sql, params)
        if sql:find('INSERT INTO k9_equipment_shop_locations (', 1, true) then
            local id = world.nextId
            world.nextId = id + 1
            world.locations[id] = {
                x = params[1], y = params[2], z = params[3], heading = params[4],
                model = params[5], scenario = params[6], label = params[7], created_by = params[8],
            }
            return id
        end
        error('equipmentshop_spec test stub: unhandled SQL (insert.await): ' .. tostring(sql))
    end
end

--- @param opts table? -- { featureEnabled: boolean?, shopConfig: table?, departments: table?, registeredItems: table<string, boolean>?, throwOnRegisterShop: boolean?, world: table?, isHighCommand: fun(source):boolean?, hasPermission: fun(citizenid, key):boolean?, playersBySource: table?, featureControl: table? }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        local line = table.concat(parts, '\t')
        -- COMPAT-LAYER MIGRATION (this pass): shared/compat/core.lua's own
        -- `onResourceStart` handler (loaded below, alongside
        -- shared/compat/inventory.lua, since server/equipmentshop.lua now
        -- routes RegisterShop through K9Compat) fires the SAME
        -- 'qbx_k9unit' onResourceStart event this fixture's own
        -- fireResourceStart() drives, and unconditionally prints its own
        -- diagnostic-command registration line every single time (every
        -- branch of that one AddEventHandler body prints something,
        -- confirmed by reading it: registered, not registered by config,
        -- or misconfigured all print). That line is K9Compat's OWN
        -- documented output, not server/equipmentshop.lua's -- every
        -- assertion in this suite is about equipmentshop.lua's own warning
        -- surface, so K9Compat's own `[qbx_k9unit] K9Compat:`-prefixed
        -- lines are filtered out here at the source rather than chased
        -- with a one-time clear (which would not work here -- unlike
        -- server/datastore.lua's own one-time boot print, this one fires
        -- fresh on every fireResourceStart() call, i.e. inside individual
        -- tests, not just once at fixture-load time).
        if line:find('[qbx_k9unit] K9Compat:', 1, true) then return end
        printedLines[#printedLines + 1] = line
    end

    local registeredItems = opts.registeredItems or {}
    local throwOnRegisterShop = opts.throwOnRegisterShop or false
    local registerShopCalls = {}
    -- WORKFLOW CLARITY FIX (this pass -- "buying, cannot afford, no space,
    -- using each item"): captured by eventName so a test can drive
    -- RegisterEquipmentShopOpenShopBlockHook's/
    -- RegisterEquipmentShopBuyItemRequirementHook's own registered
    -- callback directly, exactly as ox_inventory's real registerHook would
    -- invoke it -- these two hooks had no test coverage at all before this
    -- pass, for either the pre-existing behavior or this pass's own
    -- feature_disabled/blocked/not_granted split.
    local registeredHooks = {}

    -- COMPAT-LAYER MIGRATION (coder-backend, this pass): server/equipmentshop.lua
    -- now calls `K9Compat.Get('inventory').RegisterShop(...)` instead of
    -- `exports.ox_inventory:RegisterShop(...)` directly. shared/compat/
    -- inventory.lua's BuildOxInventoryServer requires ALL SEVEN
    -- server-realm methods (GetInventoryItems/GetContainerFromSlot/
    -- GetItemCount/RemoveItem/RegisterStash/RegisterShop/registerHook) to
    -- be present as callable exports before it returns ANYTHING -- a
    -- partial stub (just Items/RegisterShop, as this fixture had before
    -- this pass) makes the WHOLE adapter fail verification and silently
    -- fall back to the no-op stub, so RegisterShop below would always
    -- report failure regardless of `throwOnRegisterShop`. The six methods
    -- this file never actually exercises (GetInventoryItems/
    -- GetContainerFromSlot/GetItemCount/RemoveItem/RegisterStash/
    -- registerHook) are stubbed as harmless no-ops purely so capability
    -- verification passes.
    local exportsStub = {
        ox_inventory = {
            Items = function(_self, itemName)
                if registeredItems[itemName] then return { name = itemName } end
                return nil
            end,
            RegisterShop = function(_self, shopType, shopDetails)
                if throwOnRegisterShop then
                    error('simulated incompatible ox_inventory RegisterShop signature')
                end
                registerShopCalls[#registerShopCalls + 1] = { shopType = shopType, shopDetails = shopDetails }
                return true
            end,
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            registerHook = function(_self, eventName, callback)
                registeredHooks[eventName] = callback
                return 1
            end,
        },
        qbx_core = {
            GetPlayer = function(_self, source)
                local player = (opts.playersBySource or {})[source]
                return player
            end,
        },
    }

    local Config = {
        Features = { K9EquipmentShop = opts.featureEnabled },
        K9EquipmentShop = opts.shopConfig,
        Departments = opts.departments,
        FeatureControl = opts.featureControl,
        -- COMPAT-LAYER MIGRATION (this pass): pins the 'inventory' system
        -- straight to 'ox_inventory' via `override` -- shared/compat/
        -- core.lua's TIER 1, which skips the whole candidate-scanning walk
        -- entirely (no Config.Features.ResourceAutoDetect/autoDetect
        -- needed). The other four systems (target/framework/dispatch/
        -- ambulance) are given empty-but-present tables, NOT left absent,
        -- so DetectSystem's own "Config.Compat.Systems.%s is missing or
        -- malformed" warning path (a real console print) never fires for
        -- them -- this fixture has no use for any system but 'inventory'.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {},
                framework = {},
                dispatch = {},
                ambulance = {},
            },
        },
    }

    local world = opts.world or newWorld()
    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local broadcasts = {}
    local function TriggerClientEventStub(eventName, target, payload)
        broadcasts[#broadcasts + 1] = { eventName = eventName, target = target, payload = payload }
    end

    local isHighCommand = opts.isHighCommand or function() return false end
    local hasPermission = opts.hasPermission -- nil unless a test wants the permission-grant escape hatch

    -- WORKFLOW CLARITY FIX (this pass): server/equipmentshop.lua's two
    -- ox_inventory hooks (openShop block / buyItem requirement) call the
    -- real, resource-global NotifyPlayer -- absent from this fixture's env
    -- until now, so `type(NotifyPlayer) == 'function'` always failed and
    -- every denial silently sent nothing at all in this sandbox. Captured
    -- here rather than loading the real server/notify.lua, matching this
    -- fixture's existing "small local stub, not the real file" posture for
    -- everything else it does not need the real implementation of.
    local notifyCalls = {}
    local function NotifyPlayerStub(target, message, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, message = message, type = notifyType }
    end

    -- server/cooldowns.lua's Consume falls back to GetGameTimer() whenever
    -- a caller (every mutating callback below) omits the optional `now`
    -- argument -- exactly what server/equipmentshop.lua's own call sites
    -- do. A deterministic fake clock (same shape as
    -- tests/runtimecontrol_spec.lua's own fakeNow) is what makes the
    -- rate-limiting tests below controllable rather than flaky against
    -- real wall-clock time.
    local fakeNow = { value = 0 }

    -- COMPAT-LAYER MIGRATION (this pass): shared/compat/core.lua's
    -- startup-detection thread (ScheduleInitialDetection, fired from ITS
    -- OWN onResourceStart handler the moment this fixture's
    -- fireResourceStart('qbx_k9unit') runs) needs a CreateThread -- run
    -- synchronously (no real coroutine scheduling needed here: with
    -- Config.Compat.startupGraceMs left unset, that function resolves
    -- graceMs to 0 and never calls Wait at all, so a bare `fn()` is
    -- sufficient and deterministic).
    --
    -- RUNTIME TOGGLE-ON WATCHER (this pass, coder-backend): server/
    -- equipmentshop.lua now ALSO calls CreateThread once, at its own file
    -- load time (top level, not inside any onResourceStart handler), for
    -- its own genuine `while true do Wait(...) ... end` runtime-toggle-on
    -- poll loop -- see that file's own "RUNTIME TOGGLE-ON WATCHER" header.
    -- Running THAT body to completion synchronously against a no-op Wait
    -- (the old CreateThreadStub above) would hang this entire test process
    -- forever, since the loop never terminates on its own. Fixed by
    -- capturing (never auto-running) that ONE specific thread via the
    -- shared cooperative thread runner (fixtures/sandbox.lua's own
    -- Sandbox.newThreadRunner, the exact same mechanism
    -- tests/wellbeing_spec.lua already established for a real sweep
    -- thread), while every OTHER CreateThread call this fixture ever sees
    -- (shared/compat/core.lua's ScheduleInitialDetection, the only other
    -- caller) keeps running synchronously, completely unchanged.
    --
    -- EVERY CreateThread call captured, none run synchronously (boot-order-
    -- race audit, this pass -- CORRECTS a stale "the first call is always
    -- equipmentshop.lua's own watcher, order not identity" assumption this
    -- comment used to make): that assumption broke the moment ANY earlier-
    -- loaded dependency in this SAME fixture also calls CreateThread at ITS
    -- OWN file-load time (server/cooldowns.lua, loaded above, is the
    -- earliest one -- whether or not it does so today, a future change to
    -- any earlier-loaded file legitimately could, silently shifting which
    -- call is "first" again) -- running whichever call ends up in slot 2+
    -- synchronously against a real `while true do Wait(...) ... end` body
    -- either hangs this whole test process (a no-op Wait) or throws
    -- "attempt to yield from outside a coroutine" (this fixture's real,
    -- coroutine-backed WaitStub, needed once server/equipmentshop.lua's own
    -- onResourceStart handlers started calling
    -- K9Store.WaitForSchemaCheckToSettle -- see that function's own header
    -- for why it must genuinely yield). fixtures/sandbox.lua's own
    -- Sandbox.newThreadRunner already supports capturing MULTIPLE
    -- independent threads and stepping all of them together (`runner.step()`
    -- "resumes every still-alive captured thread once") -- there was never
    -- a need for the count-based special case this replaces. Capturing
    -- rather than running shared/compat/core.lua's own ScheduleInitialDetection
    -- thread (if it is ever registered by a `fireResourceStart()` call
    -- during a test) changes nothing any test here observes, per this
    -- section's own next paragraph below (K9Compat.Get lazily self-detects
    -- synchronously on first use regardless of whether that thread ever
    -- actually runs).
    local equipmentShopThreadRunner = Sandbox.newThreadRunner()
    local function CreateThreadStub(fn)
        equipmentShopThreadRunner.CreateThread(fn)
    end
    local function WaitStub(...) return equipmentShopThreadRunner.Wait(...) end

    local env = Sandbox.newEnv({
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
        GetGameTimer = function() return fakeNow.value end,
        print = printStub,
        exports = exportsStub,
        Config = Config,
        lib = libStub,
        TriggerClientEvent = TriggerClientEventStub,
        MySQL = { query = { await = makeQueryAwait(world) }, insert = { await = makeInsertAwait(world) } },
        IsHighCommand = isHighCommand,
        HasPermission = hasPermission,
        -- COMPAT-LAYER MIGRATION (this pass): server realm, and ox_inventory
        -- (the only resource this fixture's Config.Compat.Systems.inventory.override
        -- names) reports 'started' -- everything else 'missing', matching
        -- this fixture's own "nothing is running unless a test says so"
        -- posture for every other stub in this file.
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        CreateThread = CreateThreadStub,
        Wait = WaitStub,
        NotifyPlayer = NotifyPlayerStub,
        -- `locale` is deliberately left un-overridden -- Sandbox.newEnv
        -- already wires the real locale() reader over the real
        -- locales/en.json (see tests/certifications_spec.lua's own header
        -- for the precedent), so every notify assertion below doubles as a
        -- check that the locale key it names actually resolves to real
        -- text, not a fixture-invented string that could silently drift
        -- from locales/en.json.
    })

    -- server/equipmentshop.lua's new runtime-locations section calls
    -- NewCooldown at its own file-load time (EquipmentShopLocationActionCooldown)
    -- -- load the REAL, unmodified server/cooldowns.lua first, exactly like
    -- tests/runtimecontrol_spec.lua's own boot() does for the identical
    -- reason, so this suite exercises the real cooldown behavior rather
    -- than a hand-rolled stand-in.
    --
    -- server/datastore.lua -- REAL, unmodified, loaded alongside (that
    -- file's own header: "the ONLY place in this resource that may name a
    -- `k9_*` table or call `MySQL.*` directly" -- server/equipmentshop.lua's
    -- own boot load / AddLocation / MoveLocation / RemoveLocation now read
    -- and write through K9Store.ShopLocation_GetAll/Insert/Update/Delete and
    -- K9Store.ShopLocationAudit_Insert rather than a local SafeQuery/
    -- SafeWrite/SafeInsert + raw-SQL trio). Same precedent as
    -- tests/admin_spec.lua's own identical comment. Config.Database is
    -- deliberately absent from this fixture's Config table above --
    -- K9Store's own DatabaseEnabled() fails safe to `true` (real-DB mode) on
    -- a missing Config.Database, which is exactly what makes every
    -- K9Store.ShopLocation_*/ShopLocationAudit_Insert call below run the
    -- SAME MySQL.query.await/insert.await calls (against this fixture's own
    -- makeQueryAwait/makeInsertAwait world stubs) that this file's removed
    -- SafeQuery/SafeWrite/SafeInsert helpers issued directly before this
    -- migration -- so every existing assertion below keeps exercising the
    -- identical SQL/params shape, unchanged.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)

    -- COMPAT-LAYER MIGRATION (this pass): server/equipmentshop.lua's
    -- RegisterShop call is now routed through `K9Compat.Get('inventory')`
    -- -- load the REAL, unmodified shared/compat/core.lua + shared/compat/
    -- inventory.lua (never a hand-written fake translation layer, which
    -- would just assert against itself), same "real core.lua + real
    -- adapter" pattern tests/clientwellbeing_spec.lua/tests/clientsearch_spec.lua
    -- already establish for a routed file.
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)

    -- SETTLE THE SCHEMA-COLLISION PROBE FIRST (boot-order-race audit, this
    -- pass), BEFORE the print/handler discards below (not after -- its own
    -- boot-line print and handler registration need to be swept up by
    -- those SAME discards, not leak past them): server/datastore.lua's own
    -- onResourceStart handler (just registered above) is what sets
    -- SCHEMA_CHECK_SETTLED -- if it is wiped below WITHOUT ever having
    -- fired, K9Store.WaitForSchemaCheckToSettle() (now called by
    -- server/equipmentshop.lua's own onResourceStart handlers -- see that
    -- file's own "WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST"
    -- comments) would never settle for the life of this fixture, since
    -- nothing else in this sandbox ever fires it again. This fixture's own
    -- `Wait` (WaitStub, below) IS real and genuinely yields (coroutine-
    -- backed, needed for the CreateThread capture fix directly below this
    -- comment) -- so an unsettled probe would not merely report "not
    -- settled" here, it would throw "attempt to yield from outside a
    -- coroutine" the instant WaitForSchemaCheckToSettle tried to poll,
    -- since this ONE firing call below runs as a plain synchronous
    -- function call, never inside a coroutine. Never actually reached in
    -- practice: server/datastore.lua's own onResourceStart handler settles
    -- SCHEMA_CHECK_SETTLED unconditionally, synchronously, before its own
    -- first (and only) yielding call ever happens (that yield lives inside
    -- VerifyTableShapesAgainstKnownSchema's own MySQL.query.await, which
    -- this fixture's makeQueryAwait stub above answers with a synchronous
    -- `error(...)` for the unrecognized INFORMATION_SCHEMA query -- caught
    -- by that function's own pcall, never actually yielding at all here) --
    -- disclosed anyway, so a future change to either file does not
    -- reintroduce this silently.
    for _, fn in ipairs(eventHandlers['onResourceStart'] or {}) do fn('qbx_k9unit') end

    -- Discard anything server/datastore.lua printed on its way up before
    -- loading the file under test. That file legitimately prints ONE boot
    -- line saying which backend it is using -- useful in a real server,
    -- noise here. Several tests below assert that equipmentshop prints
    -- EXACTLY ZERO lines when its feature flag is off, and they mean
    -- equipmentshop's own output, not every line any file in the sandbox
    -- happened to emit. Without this, loading the datastore made those
    -- assertions fail against a print that was never equipmentshop's.
    for i = #printedLines, 1, -1 do printedLines[i] = nil end

    -- Same reasoning as the print discard directly above, extended to
    -- event handlers. server/datastore.lua now registers its OWN
    -- onResourceStart handler (the schema-collision safety net, which
    -- checks the live table shapes against the ones this resource expects
    -- and drops to memory-only rather than writing into a table that has
    -- our name but is not ours). That handler prints. fireResourceStart()
    -- below fires every registered onResourceStart handler, so without
    -- this the datastore's line would land in printedLines AFTER the
    -- discard above, and the "equipmentshop prints exactly zero when its
    -- flag is off" tests would fail against output that was never
    -- equipmentshop's -- exactly the failure the discard above exists to
    -- prevent, arriving one step later in the lifecycle. (Already fired
    -- and already discarded above, by this point -- this wipes its
    -- HANDLER registration too, so it never fires a second time on a later
    -- fireResourceStart() call made by an actual test.)
    for name in pairs(eventHandlers) do eventHandlers[name] = nil end

    Sandbox.loadInto('../server/equipmentshop.lua', env)

    -- Drives server/equipmentshop.lua's own runtime-toggle-on watcher
    -- thread forward ONE poll tick per call -- see fixtures/sandbox.lua's
    -- own Sandbox.newThreadRunner doc comment: "because every sweep thread
    -- in this resource calls Wait(...) as its FIRST statement inside the
    -- loop, the FIRST runner.step() call only reaches that initial Wait
    -- and yields immediately -- it primes the coroutine but performs no
    -- sweep pass." Mirrors tests/wellbeing_spec.lua's own
    -- primeIfNeeded()/runOneTick() shape exactly.
    local equipmentShopWatcherPrimed = false
    local function stepEquipmentShopWatcher()
        if not equipmentShopWatcherPrimed then
            equipmentShopThreadRunner.step()
            equipmentShopWatcherPrimed = true
        end
        equipmentShopThreadRunner.step()
    end

    return {
        printedLines = printedLines,
        registerShopCalls = registerShopCalls,
        registeredHooks = registeredHooks,
        notifyCalls = notifyCalls,
        config = Config,
        world = world,
        callbacks = callbacks,
        broadcasts = broadcasts,
        fakeNow = fakeNow,
        stepEquipmentShopWatcher = stepEquipmentShopWatcher,
        --- @param resourceName string?
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'qbx_k9unit')
            end
        end,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200
local HC_CITIZENID = 'HC001'

--- @param printedLines string[]
--- @param substring string
--- @return boolean
local function anyLineContains(printedLines, substring)
    for _, line in ipairs(printedLines) do
        if line:find(substring, 1, true) then return true end
    end
    return false
end

-- ----------------------------------------------------------------------
-- Absence is a clean no-op
-- ----------------------------------------------------------------------

t.test('Config.Features.K9EquipmentShop absent (nil): zero prints, zero RegisterShop calls', function()
    local f = newFixture({ featureEnabled = nil, shopConfig = { shopType = 'k9supply', items = { { name = 'k9_medkit', price = 10 } } } })
    f.fireResourceStart()
    t.equals(#f.printedLines, 0, 'a feature flag that has not even been added yet must produce ZERO output, not a warning about its own absence')
    t.equals(#f.registerShopCalls, 0)
end)

t.test('Config.Features.K9EquipmentShop = false: zero prints, zero RegisterShop calls, even with an otherwise-valid shop config', function()
    local f = newFixture({ featureEnabled = false, shopConfig = { shopType = 'k9supply', items = { { name = 'k9_medkit', price = 10 } } } })
    f.fireResourceStart()
    t.equals(#f.printedLines, 0)
    t.equals(#f.registerShopCalls, 0)
end)

t.test('onResourceStart fired for a different resource entirely is ignored -- zero output even with the feature on and everything missing', function()
    local f = newFixture({ featureEnabled = true, shopConfig = nil })
    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0)
    t.equals(#f.registerShopCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Config.K9EquipmentShop shape validation
-- ----------------------------------------------------------------------

t.test('feature on but Config.K9EquipmentShop missing entirely: one loud warning, never a thrown error, no RegisterShop call', function()
    local f = newFixture({ featureEnabled = true, shopConfig = nil })
    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'a missing config table must never crash resource start')
    t.isTrue(anyLineContains(f.printedLines, 'WARNING'))
    t.equals(#f.registerShopCalls, 0)
end)

t.test('shopType missing/empty: warned, no RegisterShop call', function()
    local f = newFixture({ featureEnabled = true, shopConfig = { items = { { name = 'k9_medkit', price = 10 } } } })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'shopType'))
    t.equals(#f.registerShopCalls, 0)
end)

t.test('items missing/empty: warned, no RegisterShop call', function()
    local f = newFixture({ featureEnabled = true, shopConfig = { shopType = 'k9supply', items = {} } })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'items'))
    t.equals(#f.registerShopCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Per-item validation -- skip, never substitute, never abort the whole shop
-- ----------------------------------------------------------------------

t.test('one item missing from ox_inventory\'s own registry: warned by name, SKIPPED -- the shop still registers with the remaining valid items', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_treat = true }, -- k9_medkit deliberately NOT registered
        shopConfig = {
            shopType = 'k9supply',
            items = {
                { name = 'k9_medkit', price = 150 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'k9_medkit'), 'the missing item must be named in a warning')
    t.equals(#f.registerShopCalls, 1, 'the shop must still register -- one good item is enough')
    local inventory = f.registerShopCalls[1].shopDetails.inventory
    t.equals(#inventory, 1, 'only the resolvable item may be included')
    t.equals(inventory[1].name, 'k9_treat')
end)

t.test('every configured item missing: warned, and the shop is NOT registered at all (nothing to sell)', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true },
        shopConfig = {
            shopType = 'k9supply',
            items = {
                { name = 'k9_medkit', price = 150 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 0)
    t.isTrue(anyLineContains(f.printedLines, 'nothing left to sell'))
    -- One start, one set of warnings. A second boot handler used to run
    -- the failed activation again and print every line twice.
    local function countContaining(needle)
        local n = 0
        for _, line in ipairs(f.printedLines) do
            if tostring(line):find(needle, 1, true) then n = n + 1 end
        end
        return n
    end
    t.equals(countContaining('nothing left to sell'), 1, 'the summary warning prints once per start')
    t.equals(countContaining('"k9_medkit"'), 1, 'each missing item is named once per start')
end)

t.test('an item with a non-numeric/negative price is skipped and warned about, independent of whether the item name itself is real', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        shopConfig = {
            shopType = 'k9supply',
            items = {
                { name = 'k9_medkit', price = -5 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 1)
    local inventory = f.registerShopCalls[1].shopDetails.inventory
    t.equals(#inventory, 1)
    t.equals(inventory[1].name, 'k9_treat', 'the negative-priced entry must be excluded, not registered at price 0 or as a negative price')
end)

t.test('currencyItem missing from ox_inventory: warned about, but does NOT block registration', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { k9_medkit = true }, -- 'money' (the implicit default currencyItem) deliberately NOT registered
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    f.fireResourceStart()
    t.isTrue(anyLineContains(f.printedLines, 'currencyItem'), 'a missing currency item must still be warned about loudly')
    t.equals(#f.registerShopCalls, 1, 'a missing currency item is an operator misconfiguration to fix, not a reason to withhold the whole shop')
end)

-- ----------------------------------------------------------------------
-- groups derived from Config.Departments -- no new config field of its own
-- ----------------------------------------------------------------------

t.test('groups are derived from Config.Departments -- every configured department, grade 0 (any rank)', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true },
        departments = { police = {}, sheriff = {} },
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    f.fireResourceStart()
    t.equals(#f.registerShopCalls, 1)
    local groups = f.registerShopCalls[1].shopDetails.groups
    t.isNotNil(groups)
    t.equals(groups.police, 0)
    t.equals(groups.sheriff, 0)
end)

t.test('Config.Departments missing entirely: registration still succeeds, with no groups restriction rather than an error', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true },
        departments = nil,
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok)
    t.equals(#f.registerShopCalls, 1)
    t.isNil(f.registerShopCalls[1].shopDetails.groups)
end)

-- ----------------------------------------------------------------------
-- RegisterShop itself throwing -- an incompatible ox_inventory version
-- ----------------------------------------------------------------------

t.test('exports.ox_inventory:RegisterShop throwing is caught -- a distinct warning, never a thrown error out of onResourceStart', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true },
        throwOnRegisterShop = true,
        shopConfig = {
            shopType = 'k9supply',
            items = { { name = 'k9_medkit', price = 150 } },
        },
    })
    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'an incompatible ox_inventory RegisterShop shape must never crash resource start')
    t.isTrue(anyLineContains(f.printedLines, 'WARNING'))
    t.isTrue(anyLineContains(f.printedLines, 'RegisterShop'))
end)

-- ----------------------------------------------------------------------
-- Happy path -- exact shape handed to RegisterShop, exact success log
-- ----------------------------------------------------------------------

t.test('happy path: RegisterShop receives the exact shopType/name/inventory shape, and no `locations`/`targets` field at all', function()
    local f = newFixture({
        featureEnabled = true,
        registeredItems = { money = true, k9_medkit = true, k9_treat = true },
        departments = { police = {} },
        shopConfig = {
            shopType = 'k9supply',
            label = 'K9 Supply',
            currencyItem = 'money',
            items = {
                { name = 'k9_medkit', price = 150 },
                { name = 'k9_treat',  price = 15 },
            },
        },
    })
    f.fireResourceStart()

    t.equals(#f.registerShopCalls, 1)
    local call = f.registerShopCalls[1]
    t.equals(call.shopType, 'k9supply')
    t.equals(call.shopDetails.name, 'K9 Supply')
    t.isNil(call.shopDetails.locations, 'this shop must never carry a `locations` field -- see server/equipmentshop.lua\'s own header, point 2, for exactly why: ox_inventory\'s own client marker system never reads a dynamically-registered shop\'s locations at all, so client/equipmentshop.lua\'s own ox_target zone is the ONLY real interaction point')
    t.isNil(call.shopDetails.targets)
    t.equals(#call.shopDetails.inventory, 2)

    local byName = {}
    for _, item in ipairs(call.shopDetails.inventory) do byName[item.name] = item end
    t.equals(byName.k9_medkit.price, 150)
    t.equals(byName.k9_treat.price, 15)

    t.isTrue(anyLineContains(f.printedLines, 'K9 Supply shop registered'))
    t.isTrue(anyLineContains(f.printedLines, '2/2'))
end)

-- ============================================================================
-- RUNTIME SHOP LOCATIONS (this pass) -- server/equipmentshop.lua's new
-- lib.callback surface: equipmentShopGetLocations/AddLocation/MoveLocation/
-- RemoveLocation. See that file's own header "RUNTIME SHOP LOCATIONS"
-- section for the full contract this exercises.
-- ============================================================================

local BASE_SHOP_CONFIG = {
    shopType = 'k9supply',
    label = 'K9 Supply',
    pedModel = 'a_c_shepherd',
    pedHeading = 0.0,
    pedScenario = 'WORLD_DOG_SITTING_SHEPHERD',
    items = { { name = 'k9_medkit', price = 10 } },
    locations = {
        { x = 100.0, y = 200.0, z = 30.0 },
    },
}

--- @param fixture table
--- @param source number
--- @param citizenid string
local function registerPlayer(fixture, source, citizenid)
    -- Rebuilds the exportsStub's own lookup indirectly isn't possible
    -- post-construction (the stub closes over opts.playersBySource at
    -- newFixture call time) -- callers instead pass playersBySource in
    -- directly via newFixture's own opts, mirroring
    -- tests/runtimecontrol_spec.lua's identical registerPlayer helper
    -- shape. Kept here only so every test below can call
    -- `registerPlayer(playersBySource, HC_SOURCE, HC_CITIZENID)` on the
    -- SAME table passed into newFixture, for readability.
    fixture[source] = { PlayerData = { citizenid = citizenid } }
end

-- ----------------------------------------------------------------------
-- GetLocations -- open to any connected caller, no privilege check
-- ----------------------------------------------------------------------

t.test('equipmentShopGetLocations is registered even with the feature off, and refuses with feature_disabled', function()
    local f = newFixture({ featureEnabled = false, shopConfig = BASE_SHOP_CONFIG })
    t.isNotNil(f.callbacks['qbx_k9unit:server:equipmentShopGetLocations'])
    local response = f.callbacks['qbx_k9unit:server:equipmentShopGetLocations'](NON_HC_SOURCE)
    t.equals(response.ok, false)
    t.equals(response.reason, 'feature_disabled')
end)

t.test('equipmentShopGetLocations resolves a config-only location against the shop-wide pedModel/pedHeading/pedScenario/label defaults -- no privilege check needed', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return false end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopGetLocations'](NON_HC_SOURCE)
    t.isTrue(response.ok)
    local loc = response.locations['cfg:1']
    t.isNotNil(loc, 'the one Config.K9EquipmentShop.locations entry must be present, keyed cfg:1')
    t.equals(loc.x, 100.0)
    t.equals(loc.model, 'a_c_shepherd')
    t.equals(loc.heading, 0.0)
    t.equals(loc.scenario, 'WORLD_DOG_SITTING_SHEPHERD')
    t.equals(loc.label, 'K9 Supply')
end)

t.test('a per-location override (model/heading/scenario/label) wins over the shop-wide default for that ONE location only', function()
    local shopConfig = {
        shopType = 'k9supply', label = 'K9 Supply', items = { { name = 'k9_medkit', price = 10 } },
        pedModel = 'a_c_shepherd', pedHeading = 0.0, pedScenario = 'WORLD_DOG_SITTING_SHEPHERD',
        locations = {
            { x = 1.0, y = 2.0, z = 3.0 }, -- uses every shop-wide default
            { x = 4.0, y = 5.0, z = 6.0, model = 'a_c_husky', heading = 180.0, scenario = false, label = 'K9 Supply (Vespucci)' },
        },
    }
    local f = newFixture({ featureEnabled = true, shopConfig = shopConfig })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopGetLocations'](NON_HC_SOURCE)
    t.equals(response.locations['cfg:1'].model, 'a_c_shepherd')
    local overridden = response.locations['cfg:2']
    t.equals(overridden.model, 'a_c_husky')
    t.equals(overridden.heading, 180.0)
    t.equals(overridden.scenario, '', 'scenario = false must resolve to the empty string (explicitly no scenario), not fall through to the shop default')
    t.equals(overridden.label, 'K9 Supply (Vespucci)')
end)

-- ----------------------------------------------------------------------
-- Boot -- persisted runtime locations are loaded at onResourceStart
-- ----------------------------------------------------------------------

t.test('a runtime location already in the database is loaded at boot and appears in GetLocations, unioned with config locations', function()
    local world = newWorld()
    world.locations[7] = { x = 9.0, y = 9.0, z = 9.0, heading = 45.0, model = 'a_c_husky', scenario = '', label = 'Vinewood Outpost', created_by = 'SOMEONE' }
    world.nextId = 8

    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, world = world })
    f.fireResourceStart()

    local response = f.callbacks['qbx_k9unit:server:equipmentShopGetLocations'](NON_HC_SOURCE)
    t.isNotNil(response.locations['cfg:1'], 'the config-defined location must still be present')
    local dbLoc = response.locations['db:7']
    t.isNotNil(dbLoc, 'the pre-existing database row must be loaded at boot')
    t.equals(dbLoc.x, 9.0)
    t.equals(dbLoc.model, 'a_c_husky')
    t.equals(dbLoc.label, 'Vinewood Outpost')
end)

-- ----------------------------------------------------------------------
-- AddLocation -- privilege, validation, happy path, broadcast
-- ----------------------------------------------------------------------

t.test('equipmentShopAddLocation is refused with feature_disabled while Config.Features.K9EquipmentShop is off', function()
    local f = newFixture({ featureEnabled = false, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2, z = 3 })
    t.equals(response.ok, false)
    t.equals(response.reason, 'feature_disabled')
end)

t.test('equipmentShopAddLocation denies a non-high-command, non-permission caller -- SERVER-SIDE, never trusting the caller', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return false end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](NON_HC_SOURCE, { x = 1, y = 2, z = 3 })
    t.equals(response.ok, false)
    t.equals(response.reason, 'denied')
    t.equals(#f.world.locations, 0)
end)

t.test('equipmentShopAddLocation rejects non-finite/missing coordinates', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2 })
    t.equals(response.ok, false)
    t.equals(response.reason, 'invalid_coords')
end)

t.test('equipmentShopAddLocation rejects a non-numeric heading', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2, z = 3, heading = 'north' })
    t.equals(response.ok, false)
    t.equals(response.reason, 'invalid_heading')
end)

t.test('equipmentShopAddLocation normalizes an out-of-range heading into [0, 360)', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2, z = 3, heading = -30.0 })
    t.isTrue(response.ok)
    t.equals(f.world.locations[1].heading, 330.0)
end)

t.test('equipmentShopAddLocation rejects a model/scenario/label containing markup-shaped characters', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local badModel = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2, z = 3, model = '<script>' })
    t.equals(badModel.reason, 'invalid_model')

    -- Advance the fake clock so this second call isn't itself refused by
    -- the anti-fat-finger cooldown the first (also-refused) call already
    -- consumed -- a REJECTED call still consumes the rate limit slot
    -- (rejection happens inside the same handler, after Consume), same as
    -- every other mutating callback in this file.
    f.fakeNow.value = f.fakeNow.value + 5000
    local badLabel = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2, z = 3, label = 'a "shop"' })
    t.equals(badLabel.reason, 'invalid_label')
end)

t.test('equipmentShopAddLocation happy path: creates a db:<id> row, audits it, broadcasts the updated effective list', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, HC_CITIZENID)
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end, playersBySource = playersBySource })

    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 10.0, y = 20.0, z = 30.0, model = 'a_c_husky', label = 'New Spot' })
    t.isTrue(response.ok)
    t.equals(response.locationKey, 'db:1')
    t.isNotNil(response.locations['db:1'])
    t.equals(response.locations['db:1'].model, 'a_c_husky')

    t.equals(f.world.locations[1].created_by, HC_CITIZENID)
    t.equals(#f.world.audit, 1)
    t.equals(f.world.audit[1].action, 'add')
    t.equals(f.world.audit[1].changed_by, HC_CITIZENID)

    t.equals(#f.broadcasts, 1)
    t.equals(f.broadcasts[1].eventName, 'qbx_k9unit:client:equipmentShopLocationsUpdated')
    t.equals(f.broadcasts[1].target, -1)
    t.isNotNil(f.broadcasts[1].payload['db:1'])
end)

t.test('equipmentShopAddLocation rate-limits a second call from the same source within the cooldown window', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local first = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1, y = 2, z = 3 })
    t.isTrue(first.ok)
    local second = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 4, y = 5, z = 6 })
    t.equals(second.ok, false)
    t.equals(second.reason, 'rate_limited')
    t.equals(#f.world.locations, 1, 'the rate-limited second call must not have written a second row')
end)

t.test('a HasPermission grant of k9.equipmentshoplocations authorizes a non-high-command caller, independently of IsHighCommand', function()
    local playersBySource = {}
    registerPlayer(playersBySource, NON_HC_SOURCE, 'GRANTED01')
    local f = newFixture({
        featureEnabled = true, shopConfig = BASE_SHOP_CONFIG,
        isHighCommand = function() return false end,
        hasPermission = function(citizenid, key) return citizenid == 'GRANTED01' and key == 'k9.equipmentshoplocations' end,
        playersBySource = playersBySource,
    })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](NON_HC_SOURCE, { x = 1, y = 2, z = 3 })
    t.isTrue(response.ok)
end)

-- ----------------------------------------------------------------------
-- MoveLocation -- only ever valid on a db:<id> key, never a cfg:<n> one
-- ----------------------------------------------------------------------

t.test('equipmentShopMoveLocation refuses a cfg:<n> key outright -- config.lua stays the source of truth for its own entries', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopMoveLocation'](HC_SOURCE, 'cfg:1', { x = 999 })
    t.equals(response.ok, false)
    t.equals(response.reason, 'invalid_key')
end)

t.test('equipmentShopMoveLocation refuses a db:<id> key that does not exist', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopMoveLocation'](HC_SOURCE, 'db:999', { x = 1 })
    t.equals(response.ok, false)
    t.equals(response.reason, 'invalid_key')
end)

t.test('equipmentShopMoveLocation happy path: partial update merges onto the current row, leaves other fields untouched, re-broadcasts', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local added = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1.0, y = 2.0, z = 3.0, model = 'a_c_husky', label = 'Original' })
    t.isTrue(added.ok)

    -- Advance the fake clock so the rate limiter (already consumed by the
    -- Add above) does not also swallow this Move.
    f.fakeNow.value = f.fakeNow.value + 5000

    local moved = f.callbacks['qbx_k9unit:server:equipmentShopMoveLocation'](HC_SOURCE, added.locationKey, { x = 100.0, y = 200.0 })
    t.isTrue(moved.ok)
    local loc = moved.locations[added.locationKey]
    t.equals(loc.x, 100.0)
    t.equals(loc.y, 200.0)
    t.equals(loc.z, 3.0, 'z was not part of this update and must be preserved')
    t.equals(loc.model, 'a_c_husky', 'model was not part of this update and must be preserved')
    t.equals(loc.label, 'Original', 'label was not part of this update and must be preserved')

    t.equals(#f.world.audit, 2)
    t.equals(f.world.audit[2].action, 'move')
end)

t.test('equipmentShopMoveLocation: model = false explicitly resets that field back to the shop-wide default', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local added = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1.0, y = 2.0, z = 3.0, model = 'a_c_husky' })
    f.fakeNow.value = f.fakeNow.value + 5000

    local moved = f.callbacks['qbx_k9unit:server:equipmentShopMoveLocation'](HC_SOURCE, added.locationKey, { model = false })
    t.isTrue(moved.ok)
    t.equals(moved.locations[added.locationKey].model, 'a_c_shepherd', 'must fall back to Config.K9EquipmentShop.pedModel once the per-location override is cleared')
end)

-- ----------------------------------------------------------------------
-- RemoveLocation -- only ever valid on a db:<id> key
-- ----------------------------------------------------------------------

t.test('equipmentShopRemoveLocation refuses a cfg:<n> key outright', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local response = f.callbacks['qbx_k9unit:server:equipmentShopRemoveLocation'](HC_SOURCE, 'cfg:1')
    t.equals(response.ok, false)
    t.equals(response.reason, 'invalid_key')
end)

t.test('equipmentShopRemoveLocation happy path: deletes the row, audits it, the location no longer appears in GetLocations, re-broadcasts', function()
    local f = newFixture({ featureEnabled = true, shopConfig = BASE_SHOP_CONFIG, isHighCommand = function() return true end })
    local added = f.callbacks['qbx_k9unit:server:equipmentShopAddLocation'](HC_SOURCE, { x = 1.0, y = 2.0, z = 3.0 })
    f.fakeNow.value = f.fakeNow.value + 5000

    local removed = f.callbacks['qbx_k9unit:server:equipmentShopRemoveLocation'](HC_SOURCE, added.locationKey)
    t.isTrue(removed.ok)
    t.isNil(removed.locations[added.locationKey])
    t.isNil(f.world.locations[1], 'the row itself must actually be gone from the current-state table')

    t.equals(#f.world.audit, 2)
    t.equals(f.world.audit[2].action, 'remove')

    local getResponse = f.callbacks['qbx_k9unit:server:equipmentShopGetLocations'](NON_HC_SOURCE)
    t.isNil(getResponse.locations[added.locationKey], 'a removed location must never resurface via GetLocations')
    t.isNotNil(getResponse.locations['cfg:1'], 'the config-defined location must be unaffected by removing a db: one')
end)

-- ============================================================================
-- WORKFLOW CLARITY FIX (this pass -- "buying, cannot afford, no space,
-- using each item" walkthrough): IsEquipmentShopPermittedForCitizenId used
-- to be a bare boolean, and BOTH ox_inventory hooks below reported every
-- refusal reason through the SAME 'equipmentshop.blocked_from_shop' text
-- ("High Command has blocked you...") even when nobody blocked this
-- citizenid individually at all -- the shop being off server-wide, or a
-- RequireGrant listed feature this citizenid simply never received, both
-- collapsed into that one, factually wrong sentence. Neither ox_inventory
-- hook had ANY test coverage before this pass. These tests drive the real,
-- registered hook callback directly (exactly as ox_inventory's own
-- registerHook would invoke it), covering all three distinct refusal
-- reasons plus the allowed case, for both the openShop and buyItem hooks.
-- ============================================================================

local SHOP_TYPE = 'k9supply'
local PLAYER_SOURCE = 300
local PLAYER_CITIZENID = 'PLAYER01'

--- @param overrides table?
--- @return table fixture
local function newHookFixture(overrides)
    overrides = overrides or {}
    local playersBySource = {}
    registerPlayer(playersBySource, PLAYER_SOURCE, PLAYER_CITIZENID)

    local f = newFixture({
        featureEnabled = true,
        shopConfig = { shopType = SHOP_TYPE, items = {} },
        playersBySource = playersBySource,
        hasPermission = overrides.hasPermission,
        featureControl = overrides.featureControl,
    })
    f.fireResourceStart()
    return f
end

t.test('openShop hook: feature disabled server-wide -- feature_disabled text, never the "High Command blocked you" text', function()
    local f = newFixture({
        featureEnabled = false,
        shopConfig = { shopType = SHOP_TYPE, items = {} },
    })
    f.fireResourceStart()
    -- The hooks are only ever registered while the feature is on (this
    -- file's own top-of-function `if not (Config.Features... ) then
    -- return end` guard) -- confirm the setup itself proves the point:
    -- with the feature off, ox_inventory's openShop hook is never even
    -- registered, so there is nothing here for a real buyer to hit at all.
    t.isNil(f.registeredHooks.openShop, 'no hook is registered while the feature is off -- ox_inventory sees no gate at all, not a refusal')
end)

t.test('openShop hook: an explicit block.K9EquipmentShop -- blocked text, names High Command', function()
    local f = newHookFixture({
        hasPermission = function(citizenid, key) return citizenid == PLAYER_CITIZENID and key == 'block.K9EquipmentShop' end,
    })
    local veto = f.registeredHooks.openShop({ shopType = SHOP_TYPE, source = PLAYER_SOURCE })
    t.equals(veto, false)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].message, Sandbox.locale('equipmentshop.blocked_from_shop'))
end)

t.test('openShop hook: RequireGrant.K9EquipmentShop=true and no grant held -- not_granted text, never blames High Command', function()
    local f = newHookFixture({
        featureControl = { RequireGrant = { K9EquipmentShop = true } },
        hasPermission = function() return false end,
    })
    local veto = f.registeredHooks.openShop({ shopType = SHOP_TYPE, source = PLAYER_SOURCE })
    t.equals(veto, false)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].message, Sandbox.locale('equipmentshop.not_granted'))
    t.isTrue(f.notifyCalls[1].message ~= Sandbox.locale('equipmentshop.blocked_from_shop'),
        'a never-granted citizenid must not be told High Command blocked them personally -- nobody made that decision about them')
end)

t.test('openShop hook: RequireGrant.K9EquipmentShop=true WITH an active feature.K9EquipmentShop grant -- allowed, no veto, no notify', function()
    local f = newHookFixture({
        featureControl = { RequireGrant = { K9EquipmentShop = true } },
        hasPermission = function(citizenid, key) return citizenid == PLAYER_CITIZENID and key == 'feature.K9EquipmentShop' end,
    })
    local veto = f.registeredHooks.openShop({ shopType = SHOP_TYPE, source = PLAYER_SOURCE })
    t.isNil(veto)
    t.equals(#f.notifyCalls, 0)
end)

t.test('openShop hook: not listed in RequireGrant at all -- default allow, no veto, no notify', function()
    local f = newHookFixture({})
    local veto = f.registeredHooks.openShop({ shopType = SHOP_TYPE, source = PLAYER_SOURCE })
    t.isNil(veto)
    t.equals(#f.notifyCalls, 0)
end)

t.test('openShop hook: an explicit block always wins even with an active grant held -- blocked text, not allowed', function()
    local f = newHookFixture({
        featureControl = { RequireGrant = { K9EquipmentShop = true } },
        hasPermission = function(citizenid, key)
            if key == 'feature.K9EquipmentShop' then return true end
            if key == 'block.K9EquipmentShop' then return true end
            return false
        end,
    })
    local veto = f.registeredHooks.openShop({ shopType = SHOP_TYPE, source = PLAYER_SOURCE })
    t.equals(veto, false)
    t.equals(f.notifyCalls[1].message, Sandbox.locale('equipmentshop.blocked_from_shop'))
end)

t.test('openShop hook: a different shopType payload is never our shop -- no veto, no notify', function()
    local f = newHookFixture({ hasPermission = function() return false end, featureControl = { RequireGrant = { K9EquipmentShop = true } } })
    local veto = f.registeredHooks.openShop({ shopType = 'someone_elses_shop', source = PLAYER_SOURCE })
    t.isNil(veto)
    t.equals(#f.notifyCalls, 0)
end)

t.test('buyItem hook: the SAME three-way split (feature_disabled is proven by no-registration above; blocked and not_granted here)', function()
    local blockedFixture = newHookFixture({
        hasPermission = function(citizenid, key) return citizenid == PLAYER_CITIZENID and key == 'block.K9EquipmentShop' end,
    })
    local blockedVeto = blockedFixture.registeredHooks.buyItem({ shopType = SHOP_TYPE, source = PLAYER_SOURCE, itemName = 'k9_medkit' })
    t.equals(blockedVeto, false)
    t.equals(blockedFixture.notifyCalls[1].message, Sandbox.locale('equipmentshop.blocked_from_shop'))

    local notGrantedFixture = newHookFixture({
        featureControl = { RequireGrant = { K9EquipmentShop = true } },
        hasPermission = function() return false end,
    })
    local notGrantedVeto = notGrantedFixture.registeredHooks.buyItem({ shopType = SHOP_TYPE, source = PLAYER_SOURCE, itemName = 'k9_medkit' })
    t.equals(notGrantedVeto, false)
    t.equals(notGrantedFixture.notifyCalls[1].message, Sandbox.locale('equipmentshop.not_granted'))
end)

os.exit(t.summary())
