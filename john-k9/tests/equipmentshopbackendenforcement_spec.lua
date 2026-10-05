--[[
    tests/equipmentshopbackendenforcement_spec.lua

    A DEDICATED, SELF-CONTAINED regression suite for one specific
    coder-security finding (red-team pass on server/equipmentshop.lua
    ~2286-2356): does the K9 Supply shop's purchase-enforcement actually
    fail closed when the detected inventory backend cannot translate the
    'openShop'/'buyItem' RegisterHook events it depends on?

    KEPT AS ITS OWN FILE, DELIBERATELY, rather than folded into
    tests/equipmentshopitems_spec.lua or tests/equipmentshop_spec.lua: both
    of those files are under heavy, active, concurrent edit by other work on
    this same shop feature (their own headers already attribute most
    sections to "this pass, coder-backend"), and this suite's own first
    draft was in fact added to tests/equipmentshopitems_spec.lua and then
    silently lost to exactly such a concurrent overwrite before it was ever
    verified end to end. A new, narrowly-scoped file nobody else is
    currently editing is the reliable way to land this coverage; tests/
    run.sh auto-discovers any `*_spec.lua` in this directory, so nothing
    else needs to change for this file to run as part of the suite.

    THE FINDING, VERIFIED (not assumed) AGAINST THE REAL, CURRENT CODE
    BEFORE WRITING ANY TEST BELOW:

      shared/compat/inventory.lua's own "RegisterHook VOCABULARY" section
      confirms ox_inventory is the ONLY adapter whose RegisterHook
      translates an ARBITRARY event name; qb-inventory (the only other
      CONFIRMED adapter) only ever translates 'swapItems' -- a
      RegisterHook('openShop', ...) or RegisterHook('buyItem', ...) call on
      it returns `false` immediately, registering nothing. Five further
      candidates (qs-inventory, origen_inventory, codem-inventory,
      core_inventory, tgiann-inventory) are UNCONFIRMED and their factories
      return `nil` unconditionally; ps-inventory is FOUND BUT SKIPPED
      (missing required methods). None of them can register either hook.

      server/equipmentshop.lua's own ActivateEquipmentShopIfEnabled (its
      "ACTIVATION" section, "HOOKS FIRST, ALWAYS") ALREADY refuses to ever
      call RegisterShop unless BOTH RegisterEquipmentShopOpenShopBlockHook
      and RegisterEquipmentShopBuyItemRequirementHook report success:

          local openOk = RegisterEquipmentShopOpenShopBlockHook(shopType)
          local buyOk = RegisterEquipmentShopBuyItemRequirementHook(shopType)
          if not (openOk and buyOk) then
              print('...REFUSING to activate the K9 Supply shop...')
              return
          end

      So the practical, CURRENT effect on qb-inventory (or any other
      unsupported backend) is already "the K9 Supply shop is never
      registered with the inventory backend at all" -- not "sold
      unenforced". This is the STRONGEST form of the fail-closed choice this
      task asked to weigh ("refuse to register gated shop items... so the
      items simply do not appear"), generalized to the WHOLE shop rather
      than only the gated items within it -- see
      server/diagnostics.lua's own new "PART 3" header for the full writeup of
      why "strip only the gated items, sell the rest" was considered and
      REJECTED (the SAME two hooks also back the per-person
      block.K9EquipmentShop/feature.K9EquipmentShop gate, which stripping
      only gated ITEMS would leave completely unenforced).

      The finding is therefore ALREADY FIXED in production code today. What
      this file actually closes is a real, separate, disclosed gap this
      pass found alongside it: this exact fail-closed path had ZERO test
      coverage anywhere in this suite before now -- every pre-existing test
      pins Config.Compat.Systems.inventory.override to 'ox_inventory',
      where both hooks always succeed, so the "hooks fail to register"
      branch of ActivateEquipmentShopIfEnabled had never actually been
      exercised. This is precisely the "shipped guards with zero coverage
      while the whole suite stayed green" failure mode this codebase has
      hit before.

    RED/GREEN PROOF PERFORMED FOR THIS PASS: server/equipmentshop.lua's own
    `if not (openOk and buyOk) then ... return end` guard was temporarily
    changed to `if false and not (openOk and buyOk) then ...` (i.e. fall
    through unconditionally, as if a partial hook-registration failure were
    acceptable). Every test below whose name contains "UNSUPPORTED BACKEND"
    immediately went red with a clean, named assertion failure (never a
    whole-suite crash) -- `#f.registerShopCalls` came back non-zero where
    the test expected 0, on the exact qb-inventory-shaped backend the
    finding names. The file was restored to its real, working form
    immediately afterward; the version in the working tree is the fixed
    one. (Re-run this proof by hand if in doubt: edit that one line, run
    `lua5.4 equipmentshopbackendenforcement_spec.lua`, watch it fail, revert.)
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local HC_SOURCE = 100

local BASE_SHOP_CONFIG = {
    shopType = 'k9supply',
    label = 'K9 Supply',
    currencyItem = 'money',
    items = {
        { name = 'k9_medkit', price = 150 },
        { name = 'k9_treat', price = 15 },
    },
}

--- @param printedLines string[]
--- @param substring string
--- @return boolean
local function anyLineContains(printedLines, substring)
    for _, line in ipairs(printedLines) do
        if line:find(substring, 1, true) then return true end
    end
    return false
end

--- @param opts table? { inventoryBackend: 'ox_inventory'|'qb-inventory', playersBySource, meetsTierRequirement, hasSpecialization }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}
    local inventoryBackend = opts.inventoryBackend or 'ox_inventory'

    local function GetCurrentResourceName() return 'john-k9' end

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
        if line:find('[John-K9] K9Compat:', 1, true) then return end
        printedLines[#printedLines + 1] = line
    end

    local registerShopCalls = {}
    local hookCallbacks = {} -- eventName -> the wrapped callback the compat layer registered

    -- ox_inventory: full-featured stub, real enough for BuildOxInventoryServer
    -- to verify. Its own RegisterHook is a pure pass-through (ANY event
    -- name), so this is the CONFIRMED-CAPABLE backend in every test below.
    local exportsStub = {
        ox_inventory = {
            Items = function(_self, itemName) return { name = itemName } end,
            RegisterShop = function(_self, shopType, shopDetails)
                registerShopCalls[#registerShopCalls + 1] = { shopType = shopType, shopDetails = shopDetails }
                return true
            end,
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            registerHook = function(_self, eventName, callback)
                hookCallbacks[eventName] = callback
                return 1
            end,
        },
        qbx_core = {
            GetPlayer = function(_self, source)
                return (opts.playersBySource or {})[source]
            end,
        },
    }

    -- qb-inventory: the REAL shape shared/compat/inventory.lua's own
    -- BuildQbInventoryServer requires before it returns a non-nil adapter at
    -- all (GetInventory/GetItemCount/RemoveItem/CreateInventory/CreateShop/
    -- AddHook). CreateShop feeds the SAME registerShopCalls array as the
    -- ox_inventory stub above -- deliberately, so a test asserting "the
    -- shop was never registered" on THIS backend actually observes that,
    -- rather than vacuously passing because the counter was only ever
    -- wired to the other backend's export table.
    if inventoryBackend == 'qb-inventory' then
        exportsStub['qb-inventory'] = {
            GetInventory = function(_self, _id) return nil end,
            GetItemCount = function(_self, _inv, _item) return 0 end,
            RemoveItem = function(_self, _id, _item, _amount, _slot) return true end,
            CreateInventory = function(_self, _id, _data) return true end,
            CreateShop = function(_self, shopData)
                registerShopCalls[#registerShopCalls + 1] = { shopType = shopData and shopData.name, shopDetails = shopData }
                return true
            end,
            AddHook = function(_self, _hookType, _callback) return 1 end,
        }
    end

    local Config = {
        Features = { K9EquipmentShop = true },
        K9EquipmentShop = BASE_SHOP_CONFIG,
        Departments = { police = { label = 'Police' } },
        FeatureControl = nil,
        -- IN-MEMORY MODE -- deliberately, so this fixture needs no MySQL
        -- stub at all (server/datastore.lua's own documented behavior for
        -- Config.Database.enabled == false: every K9Store accessor degrades
        -- to a real, working, entirely-in-memory answer, never a query).
        -- This file's own tests do not exercise the DB-backed item-catalog
        -- overlay at all -- that is tests/equipmentshopitems_spec.lua's own,
        -- separate concern -- so there is nothing here that needs it.
        Database = { enabled = false },
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = inventoryBackend },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local function TriggerClientEventStub() end

    local fakeNow = { value = 0 }

    -- Cooperative CreateThread/Wait capture -- see tests/equipmentshop_spec.lua's
    -- own identical pattern's full "why" comment (this file mirrors it):
    -- server/equipmentshop.lua's own runtime-toggle-on poll thread must
    -- never actually run a real infinite loop inside a test process.
    local threadRunner = Sandbox.newThreadRunner()
    local function CreateThreadStub(fn) threadRunner.CreateThread(fn) end
    local function WaitStub(...) return threadRunner.Wait(...) end

    local notifications = {}
    local function notifyPlayerStub(target, description, notifyType)
        notifications[#notifications + 1] = { target = target, description = description, notifyType = notifyType }
    end
    local function localeStub(key, ...)
        local parts = { ... }
        if #parts > 0 then return key .. ':' .. table.concat(parts, ',') end
        return key
    end

    local env = Sandbox.newEnv({
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
        GetGameTimer = function() return fakeNow.value end,
        print = printStub,
        exports = exportsStub,
        Config = Config,
        lib = libStub,
        TriggerClientEvent = TriggerClientEventStub,
        IsHighCommand = function() return false end,
        HasPermission = nil,
        IsKnownCertificationTierKey = function(key) return key == 'senior' end,
        MeetsTierRequirement = opts.meetsTierRequirement,
        HasSpecialization = opts.hasSpecialization,
        locale = localeStub,
        NotifyPlayer = notifyPlayerStub,
        IsDuplicityVersion = function() return true end,
        -- Both backends report 'started' -- harmless: Config.Compat.Systems
        -- .inventory's TIER 1 override probes ONLY the one named resource
        -- it is pinned to (shared/compat/core.lua's own DetectSystem,
        -- "override skips the whole candidate walk entirely"), so this
        -- never causes the OTHER backend to be considered at all.
        GetResourceState = function(name) return (name == 'ox_inventory' or name == 'qb-inventory') and 'started' or 'missing' end,
        CreateThread = CreateThreadStub,
        Wait = WaitStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)

    -- Settle the schema-collision probe first, exactly as
    -- tests/equipmentshopitems_spec.lua's own fixture does, and for the
    -- identical reason (server/equipmentshop.lua's own onResourceStart
    -- handlers call K9Store.WaitForSchemaCheckToSettle() as a plain
    -- synchronous call outside of any coroutine). Config.Database.enabled
    -- == false means this settles instantly, with no real database probe.
    for _, fn in ipairs(eventHandlers['onResourceStart'] or {}) do fn('john-k9') end

    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)

    for i = #printedLines, 1, -1 do printedLines[i] = nil end

    Sandbox.loadInto('../server/equipmentshop.lua', env)

    return {
        printedLines = printedLines,
        registerShopCalls = registerShopCalls,
        hookCallbacks = hookCallbacks,
        notifications = notifications,
        callbacks = callbacks,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'john-k9')
            end
        end,
    }
end

--- @param playersBySource table
--- @param source number
--- @param citizenid string
--- @param jobName string?
local function registerPlayer(playersBySource, source, citizenid, jobName)
    playersBySource[source] = { PlayerData = { citizenid = citizenid, job = jobName and { name = jobName } or nil } }
end

-- ============================================================================
-- CONFIRMED-CAPABLE BACKEND (ox_inventory) -- the control case. Both hooks
-- register, and the shop activates normally.
-- ============================================================================

t.test('CONFIRMED-CAPABLE BACKEND (ox_inventory): both openShop/buyItem hooks register, and RegisterShop is called', function()
    local f = newFixture({ inventoryBackend = 'ox_inventory' })
    f.fireResourceStart()

    t.equals(type(f.hookCallbacks['openShop']), 'function')
    t.equals(type(f.hookCallbacks['buyItem']), 'function')
    t.isTrue(#f.registerShopCalls > 0, 'the shop must actually register on the confirmed-capable backend')
    t.isFalse(anyLineContains(f.printedLines, 'REFUSING to activate'))
end)

-- ============================================================================
-- UNSUPPORTED BACKEND (qb-inventory) -- THE RED-TEAM SCENARIO ITSELF.
-- ============================================================================

t.test('UNSUPPORTED BACKEND (qb-inventory): neither openShop nor buyItem registers, and RegisterShop is NEVER called -- fail CLOSED, never fail open', function()
    local f = newFixture({ inventoryBackend = 'qb-inventory' })
    f.fireResourceStart()

    t.isNil(f.hookCallbacks['openShop'], 'qb-inventory has no confirmed openShop hook translation -- registration must genuinely fail, never silently succeed with an inert callback')
    t.isNil(f.hookCallbacks['buyItem'], 'qb-inventory has no confirmed buyItem hook translation')
    t.equals(#f.registerShopCalls, 0, 'RegisterShop must NEVER be called when either purchase-enforcement hook failed to register -- an unenforced live shop is worse than no shop at all')
    t.isTrue(anyLineContains(f.printedLines, 'REFUSING to activate'), 'the loud console refusal must fire so an operator can find out why the shop never appeared')
end)

t.test('UNSUPPORTED BACKEND (qb-inventory): a buyer who is NOT qualified for a gated item is refused -- because there is no shop to buy from at all', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'UNQUALIFIED01', 'police')
    local f = newFixture({
        inventoryBackend = 'qb-inventory', playersBySource = playersBySource,
        meetsTierRequirement = function() return false end,
    })
    f.fireResourceStart()

    -- There is no buyItem hook to even invoke on this backend -- the
    -- purchase path this test would otherwise drive simply does not exist,
    -- which is itself the refusal: nothing to buy from, for anyone.
    t.isNil(f.hookCallbacks['buyItem'])
    t.equals(#f.registerShopCalls, 0)
end)

t.test('UNSUPPORTED BACKEND (qb-inventory): EVEN A FULLY QUALIFIED buyer cannot purchase the gated item either -- it was never offered at all, not merely still blocked by a purchase-time check', function()
    local playersBySource = {}
    registerPlayer(playersBySource, HC_SOURCE, 'QUALIFIED01', 'police')
    local f = newFixture({
        inventoryBackend = 'qb-inventory', playersBySource = playersBySource,
        meetsTierRequirement = function() return true end, -- WOULD allow if the buyItem hook could even run
    })
    f.fireResourceStart()

    t.isNil(f.hookCallbacks['buyItem'], 'no buyItem hook exists on this backend at all -- qualification is never even consulted, because there is nothing to buy from')
    t.equals(#f.registerShopCalls, 0, 'the qualified buyer and the unqualified buyer above see the IDENTICAL outcome on this backend: no shop, for anyone -- never selectively unenforced for one and not the other')
end)

t.test('CROSS-CHECK: the qb-inventory refusal above has NO effect on a separately-booted ox_inventory fixture -- confirms the two backends are evaluated completely independently, never sharing state', function()
    local qb = newFixture({ inventoryBackend = 'qb-inventory' })
    qb.fireResourceStart()
    local ox = newFixture({ inventoryBackend = 'ox_inventory' })
    ox.fireResourceStart()

    t.equals(#qb.registerShopCalls, 0)
    t.isTrue(#ox.registerShopCalls > 0)
end)

os.exit(t.summary())
