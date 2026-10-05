--[[
    tests/compatinventory_spec.lua

    Direct tests of shared/compat/inventory.lua against the REAL, unmodified
    production file -- same "load the real source into a sandbox, drive it
    through its real registration/callback surface" discipline every other
    *_spec.lua in this directory already uses (see tests/fixtures/sandbox.lua).

    shared/compat/inventory.lua has no shared/compat/core.lua to load
    alongside it yet (a sibling agent owns that file, landing separately) --
    this suite supplies a minimal, capturing STUB `K9Compat` instead (just
    `RegisterAdapter(system, name, factory)` recording into a table), which
    is exactly the same amount of the real contract this file's own header
    documents needing. Once shared/compat/core.lua exists for real, nothing
    here needs to change: this suite exercises the FACTORY functions this
    file registers, not core.lua's own detection/selection logic (out of
    this file's scope).

    SCOPE, per this task's own brief -- this file covers:
      1. The K9Compat-missing/malformed load guard: a clean, non-throwing
         no-op with one warning, never a hard resource-start failure.
      2. ox_inventory (CONFIRMED, full contract): per-realm/per-method
         capability gating, correct export names/argument shapes on the
         real call, FAIL CLOSED behavior on a throwing export (never
         propagates, never leaves a UseItem caller's callback un-invoked),
         and RegisterHook as a PURE, GENERIC pass-through onto ox_inventory's
         own real `registerHook(eventName, callback)` -- per
         DEVELOPER_REFERENCE.md §21's "match the reference resource's calling
         convention" rule, no fixed event list, no payload translation, the
         caller's own `false` return forwarded as ox_inventory's real veto
         signal, and a throwing caller callback never propagates into
         ox_inventory's own hook-dispatch call stack.
      3. qb-inventory (CONFIRMED for a real server-side subset; client
         realm is a confirmed, disclosed nil): the COMPOSED
         GetInventoryItems (via GetInventory().items), the CONFIRMED-ABSENT
         GetContainerFromSlot no-op, RegisterStash's CreateInventory mapping
         (owner/groups silently dropped, never forwarded as a fake ACL),
         RegisterShop's CreateShop mapping (disclosed stock-amount default),
         and RegisterHook: ONLY the literal eventName 'swapItems' (ox_inventory's
         own vocabulary, per the README rule above) has a confirmed
         translation on this backend, onto the real AddHook('ItemAdded', ...)
         veto point, with the payload translated onto ox_inventory's OWN
         real field names (toInventory/fromSlot/toType/fromInventory/source)
         rather than this backend's own differently-shaped hookData fields
         -- any other eventName returns false without ever calling AddHook.
      4. Every UNCONFIRMED candidate (qs-inventory, ps-inventory,
         origen_inventory, codem-inventory, core_inventory,
         tgiann-inventory) returns nil unconditionally -- including when the
         fixture pretends the resource is fully started with a complete,
         plausible export table, proving these are deliberate, unconditional
         skips rather than accidentally-passing capability checks -- and
         the "unconfirmed" warning is printed at most once per resource name
         even when probed on both realms.
      5. Coverage-completeness: exactly the eight resource names
         config.lua's own Config.Compat.Systems.inventory.candidates list
         names are registered under the 'inventory' system, no more, no
         fewer -- so a future candidate added to config.lua without a
         matching adapter here fails this suite loudly instead of silently
         detecting as "nothing found".
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
--- Builds one complete, independent sandbox for shared/compat/inventory.lua.
--- @param opts table? -- { resourceStates: table<string,string>, exportTables: table<string,table>, noK9Compat: boolean, brokenK9Compat: boolean }
--- @return table fixture
-- ----------------------------------------------------------------------
local function newCompatFixture(opts)
    opts = opts or {}

    local registered = {} -- system -> resourceName -> factory
    local K9Compat = {
        RegisterAdapter = function(system, name, factory)
            registered[system] = registered[system] or {}
            registered[system][name] = factory
        end,
    }

    local resourceStates = opts.resourceStates or {}
    local function GetResourceState(name)
        return resourceStates[name] or 'missing'
    end

    local exportTables = opts.exportTables or {} -- resourceName -> { exportName = function(self, ...) ... end, ... }

    -- Mirrors the real, documented FiveM risk this file's own header cites:
    -- merely INDEXING `exports.<name>` on a resource that is not currently
    -- 'started' can itself throw, not just calling into it. A resourceName
    -- with no entry in `exportTables` at all (but a 'started' state) models
    -- a real, started resource that simply has never registered that
    -- export -- resolves to an empty table, never a throw, matching a
    -- genuine "export does not exist" outcome rather than "resource is not
    -- running" (a different failure this suite tests separately).
    local exportsProxy = setmetatable({}, {
        __index = function(_, resourceName)
            if resourceStates[resourceName] ~= 'started' then
                error(('simulated: exports access on non-started resource "%s" threw'):format(resourceName))
            end
            return exportTables[resourceName] or {}
        end,
    })

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local envOverrides = {
        GetResourceState = GetResourceState,
        exports = exportsProxy,
        print = printStub,
    }
    if not opts.noK9Compat then
        envOverrides.K9Compat = opts.brokenK9Compat and { RegisterAdapter = 'not-a-function' } or K9Compat
    end

    local env = Sandbox.newEnv(envOverrides)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)

    return {
        env = env,
        registered = registered,
        printedLines = printedLines,
        countPrintsContaining = function(needle)
            local n = 0
            for _, line in ipairs(printedLines) do
                if line:find(needle, 1, true) then n = n + 1 end
            end
            return n
        end,
        getFactory = function(system, name)
            return registered[system] and registered[system][name]
        end,
    }
end

-- ========================================================================
-- POINT 1: the K9Compat-missing/malformed load guard.
-- ========================================================================

t.test('K9Compat entirely absent: the file loads without error, prints exactly one warning naming K9Compat, and registers nothing', function()
    local f = newCompatFixture({ noK9Compat = true })
    t.equals(#f.printedLines, 1)
    t.contains(f.printedLines[1], 'K9Compat')
    t.isNil(f.registered.inventory)
end)

t.test('K9Compat present but RegisterAdapter is not a function: the same clean guard fires, never a hard error', function()
    local f = newCompatFixture({ brokenK9Compat = true })
    t.equals(#f.printedLines, 1)
    t.contains(f.printedLines[1], 'K9Compat')
    t.isNil(f.registered.inventory)
end)

-- ========================================================================
-- COVERAGE COMPLETENESS: exactly config.lua's eight candidate names.
-- ========================================================================

t.test('exactly the eight resource names config.lua\'s own Config.Compat.Systems.inventory.candidates list names are registered -- no more, no fewer', function()
    local f = newCompatFixture()
    local expected = {
        'ox_inventory', 'qs-inventory', 'qb-inventory', 'ps-inventory',
        'origen_inventory', 'codem-inventory', 'core_inventory', 'tgiann-inventory',
    }
    local seen = {}
    local count = 0
    for name in pairs(f.registered.inventory) do
        seen[name] = true
        count = count + 1
    end
    t.equals(count, #expected)
    for _, name in ipairs(expected) do
        t.isTrue(seen[name] == true, ('expected %s to be registered'):format(name))
    end
end)

-- ========================================================================
-- POINT 2: ox_inventory.
-- ========================================================================

local function oxFullExports(overrides)
    local base = {
        openInventory = function(_self, kind, data) return { kind = kind, data = data } end,
        useItem = function(_self, data, cb) if cb then cb(true) end return true end,
        Items = function(_self, name) if name == 'k9_medkit' then return { name = name } end return nil end,
        GetInventoryItems = function(_self, inv, owner) return { { name = 'weapon_pistol', slot = 1, weight = 10 } } end,
        GetContainerFromSlot = function(_self, inv, slot) return { id = 'container-1', items = {} } end,
        GetItemCount = function(_self, inv, item) if item == 'k9_treat' then return 3 end return 0 end,
        RemoveItem = function(_self, inv, item, count) return true, nil end,
        RegisterStash = function(_self, id, label, slots, maxWeight, owner, groups) return true end,
        RegisterShop = function(_self, shopType, shopDetails) return true end,
        registerHook = function(_self, event, callback) return 'ox_inventory:swapItems:1' end,
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return base
end

t.test('ox_inventory: unrecognized realm returns nil without probing anything', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local factory = f.getFactory('inventory', 'ox_inventory')
    t.isNil(factory('bogus'))
    t.isNil(factory(nil))
end)

t.test('ox_inventory CLIENT: all three capabilities present returns a full 4-method table', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    t.equals(type(client.OpenStash), 'function')
    t.equals(type(client.OpenShop), 'function')
    t.equals(type(client.UseItem), 'function')
    t.equals(type(client.ItemExists), 'function')
end)

t.test('ox_inventory CLIENT: missing openInventory export -> nil (whole client adapter skipped)', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports({ openInventory = false }) } })
    t.isNil(f.getFactory('inventory', 'ox_inventory')('client'))
end)

t.test('ox_inventory CLIENT: missing useItem export -> nil', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports({ useItem = false }) } })
    t.isNil(f.getFactory('inventory', 'ox_inventory')('client'))
end)

t.test('ox_inventory CLIENT: missing Items export -> nil', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports({ Items = false }) } })
    t.isNil(f.getFactory('inventory', 'ox_inventory')('client'))
end)

t.test('ox_inventory CLIENT: resource not started -> nil, even with a full export table sitting there', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'starting' }, exportTables = { ox_inventory = oxFullExports() } })
    t.isNil(f.getFactory('inventory', 'ox_inventory')('client'))
end)

t.test("ox_inventory CLIENT OpenStash: calls openInventory('stash', stashId) with the exact real argument shape", function()
    local captured
    local exportsTbl = oxFullExports({ openInventory = function(_self, kind, data) captured = { kind = kind, data = data } end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    local attempted = client.OpenStash('k9inv-REX')
    t.isTrue(attempted)
    t.equals(captured.kind, 'stash')
    t.equals(captured.data, 'k9inv-REX')
end)

t.test('ox_inventory CLIENT OpenStash: an invalid (non-string/number) stashId is rejected before any export call is attempted', function()
    local called = false
    local exportsTbl = oxFullExports({ openInventory = function() called = true end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    local attempted = client.OpenStash({ not_a = 'string_or_number' })
    t.isFalse(attempted)
    t.isFalse(called)
end)

t.test('ox_inventory CLIENT OpenStash: the underlying export throwing is caught and reported as a failed attempt, never propagated', function()
    local exportsTbl = oxFullExports({ openInventory = function() error('simulated ox_inventory internal error') end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    local ok, attempted = pcall(client.OpenStash, 'k9inv-REX')
    t.isTrue(ok, 'a throwing third-party export must never propagate out of this adapter')
    t.isFalse(attempted)
end)

t.test("ox_inventory CLIENT OpenShop: calls openInventory('shop', { type = shopType }) with the exact real argument shape", function()
    local captured
    local exportsTbl = oxFullExports({ openInventory = function(_self, kind, data) captured = { kind = kind, data = data } end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    local attempted = client.OpenShop('k9supply')
    t.isTrue(attempted)
    t.equals(captured.kind, 'shop')
    t.equals(captured.data.type, 'k9supply')
end)

t.test('ox_inventory CLIENT OpenShop: an empty/invalid shopType never reaches the export', function()
    local called = false
    local exportsTbl = oxFullExports({ openInventory = function() called = true end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    t.isFalse(client.OpenShop(''))
    t.isFalse(client.OpenShop(nil))
    t.isFalse(called)
end)

t.test('ox_inventory CLIENT UseItem: success path forwards data/cb unchanged and the real export\'s own cb(true) call reaches the caller', function()
    local seenApproved
    local exportsTbl = oxFullExports({ useItem = function(_self, data, cb) cb(data.approve) end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    client.UseItem({ approve = true }, function(approved) seenApproved = approved end)
    t.isTrue(seenApproved)
end)

t.test('ox_inventory CLIENT UseItem: FAIL CLOSED -- when the export call itself throws, cb is invoked synchronously with false exactly once, never left hanging', function()
    local calls = 0
    local lastApproved
    local exportsTbl = oxFullExports({ useItem = function() error('simulated failure') end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    local ok = pcall(client.UseItem, { item = 'k9_tablet' }, function(approved) calls = calls + 1 lastApproved = approved end)
    t.isTrue(ok)
    t.equals(calls, 1, 'the caller\'s callback must be invoked exactly once, never zero (a hang) and never more than once')
    t.isFalse(lastApproved)
end)

t.test('ox_inventory CLIENT ItemExists: a real, resolvable item name is true', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    t.isTrue(client.ItemExists('k9_medkit'))
end)

t.test('ox_inventory CLIENT ItemExists: an unresolvable item name is false, never an error', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    t.isFalse(client.ItemExists('totally_made_up_item'))
    t.isFalse(client.ItemExists(''))
    t.isFalse(client.ItemExists(nil))
end)

t.test('ox_inventory CLIENT ItemExists: the Items() export itself throwing resolves to false, never propagated', function()
    local exportsTbl = oxFullExports({ Items = function() error('simulated') end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local client = f.getFactory('inventory', 'ox_inventory')('client')
    local ok, result = pcall(client.ItemExists, 'k9_medkit')
    t.isTrue(ok)
    t.isFalse(result)
end)

-- ---- ox_inventory SERVER ----

t.test('ox_inventory SERVER: all eight capabilities present returns a full 8-method table', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    for _, name in ipairs({ 'GetInventoryItems', 'GetContainerFromSlot', 'GetItemCount', 'RemoveItem', 'RegisterStash', 'RegisterShop', 'RegisterHook', 'ItemExists' }) do
        t.equals(type(server[name]), 'function', name .. ' must be a function')
    end
end)

t.test('ox_inventory SERVER: missing GetInventoryItems -> nil (whole server adapter skipped)', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports({ GetInventoryItems = false }) } })
    t.isNil(f.getFactory('inventory', 'ox_inventory')('server'))
end)

t.test('ox_inventory SERVER: missing registerHook -> nil (whole server adapter skipped)', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports({ registerHook = false }) } })
    t.isNil(f.getFactory('inventory', 'ox_inventory')('server'))
end)

t.test('ox_inventory SERVER: missing Items does NOT skip the whole adapter, unlike the other seven -- ItemExists alone degrades to false, every other method keeps working', function()
    -- DELIBERATE, see shared/compat/inventory.lua's own comment on this
    -- exact line in BuildOxInventoryServer: gating construction of the
    -- whole table on 'Items' would break every existing fixture across this
    -- suite (search_spec.lua, inventory_spec.lua, coopsearchbonus_spec.lua,
    -- ...) that never stubbed that one export, none of which call
    -- ItemExists at all today.
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports({ Items = false }) } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    t.isNotNil(server, 'the adapter as a whole must still be returned')
    t.equals(type(server.GetItemCount), 'function', 'every other method must be unaffected')
    local ok, result = pcall(server.ItemExists, 'k9_medkit')
    t.isTrue(ok)
    t.isFalse(result, 'ItemExists itself fails closed to false when Items is not actually callable')
end)

t.test('ox_inventory SERVER ItemExists: a real, resolvable item name is true', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    t.isTrue(server.ItemExists('k9_medkit'))
end)

t.test('ox_inventory SERVER ItemExists: an unresolvable item name is false, never an error', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    t.isFalse(server.ItemExists('totally_made_up_item'))
    t.isFalse(server.ItemExists(''))
    t.isFalse(server.ItemExists(nil))
end)

t.test('ox_inventory SERVER ItemExists: the Items() export itself throwing resolves to false, never propagated', function()
    local exportsTbl = oxFullExports({ Items = function() error('simulated') end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local ok, result = pcall(server.ItemExists, 'k9_medkit')
    t.isTrue(ok)
    t.isFalse(result)
end)

t.test('ox_inventory SERVER GetInventoryItems: forwards the table-shaped vehicle inv argument unchanged (server/search.lua\'s own {id=,netid=} shape)', function()
    local captured
    local exportsTbl = oxFullExports({ GetInventoryItems = function(_self, inv, owner) captured = inv return {} end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    server.GetInventoryItems({ id = 'veh-1', netid = 555 })
    t.equals(captured.id, 'veh-1')
    t.equals(captured.netid, 555)
end)

t.test('ox_inventory SERVER GetInventoryItems: a throwing export resolves to nil, never propagated', function()
    local exportsTbl = oxFullExports({ GetInventoryItems = function() error('simulated') end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local ok, result = pcall(server.GetInventoryItems, 'k9inv-REX')
    t.isTrue(ok)
    t.isNil(result)
end)

t.test('ox_inventory SERVER GetItemCount: passthrough on success, fails closed to 0 on a throw', function()
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = oxFullExports() } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    t.equals(server.GetItemCount(1, 'k9_treat'), 3)
    t.equals(server.GetItemCount(1, 'nonexistent_item'), 0)

    local throwing = oxFullExports({ GetItemCount = function() error('simulated') end })
    local f2 = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = throwing } })
    local server2 = f2.getFactory('inventory', 'ox_inventory')('server')
    local ok, count = pcall(server2.GetItemCount, 1, 'k9_treat')
    t.isTrue(ok)
    t.equals(count, 0)
end)

t.test('ox_inventory SERVER RemoveItem: passes through (success, reason) on real failure, and never fabricates true when the call itself throws', function()
    local failing = oxFullExports({ RemoveItem = function() return false, 'not_enough_items' end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = failing } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local success, reason = server.RemoveItem('k9inv-REX', 'k9_treat', 1)
    t.isFalse(success)
    t.equals(reason, 'not_enough_items')

    local throwing = oxFullExports({ RemoveItem = function() error('simulated') end })
    local f2 = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = throwing } })
    local server2 = f2.getFactory('inventory', 'ox_inventory')('server')
    local ok, success2 = pcall(server2.RemoveItem, 'k9inv-REX', 'k9_treat', 1)
    t.isTrue(ok)
    t.isFalse(success2)
end)

t.test('ox_inventory SERVER RegisterStash: forwards every argument positionally, unchanged, to the real export', function()
    local captured
    local exportsTbl = oxFullExports({ RegisterStash = function(_self, id, label, slots, maxWeight, owner, groups) captured = { id, label, slots, maxWeight, owner, groups } return true end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local ok = server.RegisterStash('k9inv-REX', 'K9 Gear', 5, 8000, false, { police = 0 })
    t.isTrue(ok)
    t.equals(captured[1], 'k9inv-REX')
    t.equals(captured[3], 5)
    t.equals(captured[4], 8000)
    t.equals(captured[5], false)
    t.equals(captured[6].police, 0)
end)

t.test('ox_inventory SERVER RegisterShop: translates this adapter\'s {label,items,groups} shape onto ox_inventory\'s real {name,inventory,groups}', function()
    local captured
    local exportsTbl = oxFullExports({ RegisterShop = function(_self, shopType, shopDetails) captured = { shopType = shopType, shopDetails = shopDetails } return true end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local ok = server.RegisterShop('k9supply', { label = 'K9 Supply', items = { { name = 'k9_treat', price = 10 } }, groups = { police = 0 } })
    t.isTrue(ok)
    t.equals(captured.shopType, 'k9supply')
    t.equals(captured.shopDetails.name, 'K9 Supply')
    t.equals(captured.shopDetails.inventory[1].name, 'k9_treat')
    t.equals(captured.shopDetails.groups.police, 0)
end)

t.test('ox_inventory SERVER RegisterShop: a malformed shopDetails (no items table) is rejected before any export call', function()
    local called = false
    local exportsTbl = oxFullExports({ RegisterShop = function() called = true end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    t.isFalse(server.RegisterShop('k9supply', { label = 'K9 Supply' }))
    t.isFalse(called)
end)

-- ---- ox_inventory SERVER RegisterHook -- PURE, GENERIC PASS-THROUGH ----
-- (per DEVELOPER_REFERENCE.md §21's "match the reference resource's calling
-- convention" rule -- eventName and payload are exactly ox_inventory's own)

t.test("ox_inventory SERVER RegisterHook: an invalid eventName (empty/non-string) or a non-function callback returns false immediately, without ever calling registerHook", function()
    local called = false
    local exportsTbl = oxFullExports({ registerHook = function() called = true return 'id' end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    t.isFalse(server.RegisterHook('', function() end))
    t.isFalse(server.RegisterHook(nil, function() end))
    t.isFalse(server.RegisterHook('swapItems', 'not-a-function'))
    t.isFalse(called)
end)

t.test("ox_inventory SERVER RegisterHook: registers against the EXACT eventName given, unrestricted -- 'swapItems', 'buyItem', or anything else ox_inventory itself fires", function()
    local capturedEvent, capturedCallback
    local exportsTbl = oxFullExports({ registerHook = function(_self, event, callback) capturedEvent = event capturedCallback = callback return 'id' end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local ok = server.RegisterHook('swapItems', function() end)
    t.isTrue(ok)
    t.equals(capturedEvent, 'swapItems')
    t.equals(type(capturedCallback), 'function')

    local ok2 = server.RegisterHook('buyItem', function() end)
    t.isTrue(ok2, 'this adapter must never restrict eventName to a fixed list -- it is a pure pass-through')
    t.equals(capturedEvent, 'buyItem')
end)

t.test("ox_inventory SERVER RegisterHook wrapper: the payload handed to the caller's callback is EXACTLY ox_inventory's own real payload, unmodified", function()
    local capturedCallback
    local exportsTbl = oxFullExports({ registerHook = function(_self, event, callback) capturedCallback = callback return 'id' end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local seenPayload
    server.RegisterHook('swapItems', function(payload) seenPayload = payload end)

    local realPayload = { fromInventory = 'player:1', toInventory = 'k9inv-REX', fromSlot = { name = 'weapon_pistol', count = 1 }, toType = 'stash', source = 5 }
    capturedCallback(realPayload)
    t.equals(seenPayload, realPayload, 'no translation/normalization must happen for the reference adapter -- the payload is passed through as-is')
end)

t.test("ox_inventory SERVER RegisterHook wrapper: the caller's callback returning the literal false is forwarded as the real ox_inventory veto signal", function()
    local capturedCallback
    local exportsTbl = oxFullExports({ registerHook = function(_self, event, callback) capturedCallback = callback return 'id' end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    server.RegisterHook('swapItems', function() return false end)
    local result = capturedCallback({ toInventory = 'k9inv-REX', fromSlot = { name = 'weapon_pistol', count = 1 } })
    t.equals(result, false)
end)

t.test("ox_inventory SERVER RegisterHook wrapper: allowing (callback returns nil/true) never rejects, and the caller's callback itself throwing is caught, never propagated into ox_inventory's own call stack", function()
    local capturedCallback
    local exportsTbl = oxFullExports({ registerHook = function(_self, event, callback) capturedCallback = callback return 'id' end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    server.RegisterHook('swapItems', function() return true end)
    t.isNil(capturedCallback({ toInventory = 'k9inv-REX' }))

    local throwingCapturedCallback
    local throwingExports = oxFullExports({ registerHook = function(_self, event, callback) throwingCapturedCallback = callback return 'id' end })
    local f2 = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = throwingExports } })
    local server2 = f2.getFactory('inventory', 'ox_inventory')('server')
    server2.RegisterHook('swapItems', function() error('caller bug inside its own callback') end)
    local ok, result = pcall(throwingCapturedCallback, { toInventory = 'k9inv-REX' })
    t.isTrue(ok, 'a throwing CALLER callback must never propagate into ox_inventory\'s own hook-dispatch call stack either')
    t.isNil(result)
end)

t.test('ox_inventory SERVER RegisterHook: the underlying registerHook call throwing is caught, reported false, never propagated', function()
    local exportsTbl = oxFullExports({ registerHook = function() error('simulated ox_inventory internal error') end })
    local f = newCompatFixture({ resourceStates = { ox_inventory = 'started' }, exportTables = { ox_inventory = exportsTbl } })
    local server = f.getFactory('inventory', 'ox_inventory')('server')
    local ok, result = pcall(server.RegisterHook, 'swapItems', function() end)
    t.isTrue(ok)
    t.isFalse(result)
end)

-- ========================================================================
-- POINT 3: qb-inventory.
-- ========================================================================

local function qbFullExports(overrides)
    local base = {
        GetInventory = function(_self, id) if id == 'k9inv-REX' then return { items = { { name = 'k9_treat', amount = 2, slot = 1 } } } end return nil end,
        GetItemCount = function(_self, inv, item) if item == 'k9_treat' then return 4 end return 0 end,
        RemoveItem = function(_self, id, item, amount, slot) return true end,
        CreateInventory = function(_self, id, data) return true end,
        CreateShop = function(_self, shopData) return true end,
        AddHook = function(_self, hookType, callback) return 1 end,
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return base
end

t.test('qb-inventory CLIENT: always nil, regardless of resource state or export completeness -- confirmed architectural mismatch, not a capability gap', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    t.isNil(f.getFactory('inventory', 'qb-inventory')('client'))
end)

t.test('qb-inventory SERVER: all six required export capabilities present returns a full 8-method table (ItemExists needs no export of its own -- see its own doc comment)', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    for _, name in ipairs({ 'GetInventoryItems', 'GetContainerFromSlot', 'GetItemCount', 'RemoveItem', 'RegisterStash', 'RegisterShop', 'RegisterHook', 'ItemExists' }) do
        t.equals(type(server[name]), 'function', name .. ' must be a function')
    end
end)

t.test('qb-inventory SERVER ItemExists: DISCLOSED PLACEHOLDER -- always true, no confirmed catalog-lookup export exists on this backend, never a guess', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isTrue(server.ItemExists('k9_medkit'))
    t.isTrue(server.ItemExists('totally_made_up_item'))
    t.isTrue(server.ItemExists(nil), 'unconditional placeholder -- does not even validate the argument, since it never uses it')
end)

t.test('qb-inventory SERVER: missing AddHook -> nil (whole server adapter skipped)', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports({ AddHook = false }) } })
    t.isNil(f.getFactory('inventory', 'qb-inventory')('server'))
end)

t.test('qb-inventory SERVER GetInventoryItems: composed via GetInventory(id).items', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local items = server.GetInventoryItems('k9inv-REX')
    t.equals(items[1].name, 'k9_treat')
end)

t.test('qb-inventory SERVER GetInventoryItems: an unknown identifier resolves to nil, never an error', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isNil(server.GetInventoryItems('no-such-id'))
end)

t.test('qb-inventory SERVER GetInventoryItems: a TABLE-shaped inv (the ox_inventory vehicle form) fails closed to nil without ever calling GetInventory', function()
    local called = false
    local exportsTbl = qbFullExports({ GetInventory = function() called = true end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isNil(server.GetInventoryItems({ id = 'veh-1', netid = 555 }))
    t.isFalse(called, 'qb-inventory has no confirmed table-shaped inv lookup -- must never guess what it would do with one')
end)

t.test('qb-inventory SERVER GetContainerFromSlot: always nil -- a confirmed-absent capability, never a guess', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isNil(server.GetContainerFromSlot('k9inv-REX', 1))
end)

t.test('qb-inventory SERVER GetItemCount: passthrough with the real two-argument shape, fails closed to 0', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.equals(server.GetItemCount('k9inv-REX', 'k9_treat'), 4)
    t.equals(server.GetItemCount('k9inv-REX', 'nope'), 0)
end)

t.test('qb-inventory SERVER RemoveItem: passthrough success, and never fabricates true on a throw', function()
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = qbFullExports() } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local success = server.RemoveItem('k9inv-REX', 'k9_treat', 1)
    t.isTrue(success)

    local throwing = qbFullExports({ RemoveItem = function() error('simulated') end })
    local f2 = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = throwing } })
    local server2 = f2.getFactory('inventory', 'qb-inventory')('server')
    local ok, success2, reason2 = pcall(server2.RemoveItem, 'k9inv-REX', 'k9_treat', 1)
    t.isTrue(ok)
    t.isFalse(success2)
    t.equals(reason2, 'compat_call_failed')
end)

t.test('qb-inventory SERVER RegisterStash: maps onto CreateInventory(id, {label,slots,maxweight}) and SILENTLY DROPS owner/groups -- never forwards them as a fake ACL', function()
    local captured
    local exportsTbl = qbFullExports({ CreateInventory = function(_self, id, data) captured = { id = id, data = data } return true end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local ok = server.RegisterStash('k9inv-REX', 'K9 Gear', 5, 8000, false, { police = 0 })
    t.isTrue(ok)
    t.equals(captured.id, 'k9inv-REX')
    t.equals(captured.data.label, 'K9 Gear')
    t.equals(captured.data.slots, 5)
    t.equals(captured.data.maxweight, 8000)
    t.isNil(captured.data.owner)
    t.isNil(captured.data.groups)
end)

t.test('qb-inventory SERVER RegisterShop: maps items onto CreateShop, applying the disclosed default stock amount when none is given, and preserving an explicit one', function()
    local captured
    local exportsTbl = qbFullExports({ CreateShop = function(_self, shopData) captured = shopData return true end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local ok = server.RegisterShop('k9supply', { label = 'K9 Supply', items = { { name = 'k9_treat', price = 10 }, { name = 'k9_medkit', price = 50, amount = 3 } } })
    t.isTrue(ok)
    t.equals(captured.name, 'k9supply')
    t.equals(captured.label, 'K9 Supply')
    t.equals(captured.items[1].amount, 999999, 'no confirmed unlimited-stock mode exists on this backend -- a disclosed large default stands in for it')
    t.equals(captured.items[2].amount, 3, 'an explicit amount must be preserved, never overridden by the default')
end)

t.test('qb-inventory SERVER RegisterShop: a malformed shopDetails (no items table) is rejected before any export call', function()
    local called = false
    local exportsTbl = qbFullExports({ CreateShop = function() called = true end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isFalse(server.RegisterShop('k9supply', { label = 'K9 Supply' }))
    t.isFalse(called)
end)

-- ---- qb-inventory SERVER RegisterHook -- ONLY 'swapItems' has a confirmed
-- translation on this backend (per DEVELOPER_REFERENCE.md §21's "match the
-- reference resource's calling convention" rule); the payload is translated
-- onto ox_inventory's OWN real field names (fromInventory/fromSlot/
-- toInventory/toType/source), never this backend's own hookData names.
--
-- UPDATED this pass (coder-backend): a single RegisterHook('swapItems', ...)
-- call now registers TWO real qb-inventory hooks, not one --
-- AddHook('ItemAdded', ...) (the veto point, unchanged) AND
-- AddHook('ItemDropped', ...) (NEWLY confirmed -- see
-- shared/compat/inventory.lua's own doc comment for the citation: qb-inventory
-- genuinely fires this on every real ground drop, which an earlier revision
-- of this file incorrectly recorded as never firing at all). `qbFullExports`'s
-- `AddHook` stub below is captured PER-hookType (a table), not a single
-- overwritten variable, specifically so these tests can distinguish the two
-- independent registrations. ----

t.test("qb-inventory SERVER RegisterHook('swapItems'): registers against BOTH the real AddHook('ItemAdded', ...) veto point AND the real AddHook('ItemDropped', ...) ground-drop hook", function()
    local capturedCallbacks = {}
    local exportsTbl = qbFullExports({ AddHook = function(_self, hookType, callback) capturedCallbacks[hookType] = callback return 1 end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local ok = server.RegisterHook('swapItems', function() end)
    t.isTrue(ok)
    t.equals(type(capturedCallbacks.ItemAdded), 'function')
    t.equals(type(capturedCallbacks.ItemDropped), 'function')
end)

t.test("qb-inventory SERVER RegisterHook('swapItems') wrapper (ItemAdded): a disallowed item is a real veto (the literal false); the normalized payload uses ox_inventory's OWN field names, translated from qb-inventory's real hookData", function()
    local capturedCallbacks = {}
    local exportsTbl = qbFullExports({ AddHook = function(_self, hookType, callback) capturedCallbacks[hookType] = callback return 1 end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local seenPayload
    server.RegisterHook('swapItems', function(payload) seenPayload = payload return false end)

    local result = capturedCallbacks.ItemAdded('weapon', { toId = 'k9inv-REX', toType = 'stash', item = { name = 'weapon_pistol' }, amount = 1 })
    t.equals(result, false)
    t.equals(seenPayload.toInventory, 'k9inv-REX', 'ox_inventory\'s own toInventory is an ID STRING -- qb-inventory\'s hookData.toId is the field that matches that semantic, never hookData.toInventory (a resolved data table)')
    t.equals(seenPayload.fromSlot.name, 'weapon_pistol')
    t.equals(seenPayload.fromSlot.count, 1, 'ox_inventory item slots use .count, not qb-inventory\'s own .amount field name -- translated, not copied verbatim')
    t.equals(seenPayload.toType, 'stash')
    t.isNil(seenPayload.fromInventory, 'confirmed absent from qb-inventory\'s ItemAdded payload -- never guessed')
    t.isNil(seenPayload.source, 'confirmed absent from qb-inventory\'s ItemAdded payload -- never guessed')
end)

t.test("qb-inventory SERVER RegisterHook('swapItems') wrapper (ItemAdded): allowing an item never rejects, and a malformed hookData fails open", function()
    local capturedCallbacks = {}
    local exportsTbl = qbFullExports({ AddHook = function(_self, hookType, callback) capturedCallbacks[hookType] = callback return 1 end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local called = false
    server.RegisterHook('swapItems', function() called = true return true end)

    local allowed = capturedCallbacks.ItemAdded('item', { toId = 'k9inv-REX', item = { name = 'k9_treat' }, amount = 1 })
    t.isNil(allowed)
    t.isTrue(called, 'a well-formed payload must reach the caller\'s callback')

    called = false
    local r1 = capturedCallbacks.ItemAdded('item', { toId = 'k9inv-REX', item = 'not-a-table' })
    local r2 = capturedCallbacks.ItemAdded('item', 'not-a-table')
    t.isNil(r1)
    t.isNil(r2)
    t.isFalse(called)
end)

-- ---- qb-inventory SERVER RegisterHook wrapper (ItemDropped) -- THE FIX FOR
-- "scent tracking never fires on qb-inventory" (KNOWN_ISSUES.md). CONFIRMED this
-- pass against qbcore-framework/qb-inventory's real `main` branch source:
-- server/main.lua's `qb-inventory:server:createDrop` callback runs
-- `TriggerHook('ItemDropped', hookData.item.type, hookData)` on every real
-- ground drop, and server/hooks.lua's `buildItemDroppedData` confirms the
-- payload shape: `{ source, sourceInventory, coords, item, amount }`. ----

t.test("qb-inventory SERVER RegisterHook('swapItems') wrapper (ItemDropped): a real ground drop reaches the caller's callback as toType == 'drop' with the real source, never vetoed by default", function()
    local capturedCallbacks = {}
    local exportsTbl = qbFullExports({ AddHook = function(_self, hookType, callback) capturedCallbacks[hookType] = callback return 1 end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    local seenPayload
    local ok = server.RegisterHook('swapItems', function(payload) seenPayload = payload end)
    t.isTrue(ok)

    local result = capturedCallbacks.ItemDropped('weed_baggy', { source = 42, sourceInventory = { slots = 50, maxweight = 120000, items = {} }, coords = { x = 1, y = 2, z = 3 }, item = { name = 'weed_baggy' }, amount = 1 })
    t.isNil(result, 'ScentTracking\'s own callback never vetoes -- a real drop must never be cancelled by this translation')
    t.equals(seenPayload.toType, 'drop', 'SYNTHESIZED literal -- confirmed by the event TYPE firing at all, not read from any qb-inventory field')
    t.equals(seenPayload.source, 42, 'the real dropping player\'s server id, confirmed present on qb-inventory\'s own ItemDropped payload (unlike ItemAdded, which never carries one)')
    t.equals(seenPayload.fromSlot.name, 'weed_baggy')
    t.isNil(seenPayload.toInventory, 'a ground drop has no destination inventory identifier at this point -- confirmed absent, never guessed')
    t.isNil(seenPayload.fromInventory, 'confirmed absent from qb-inventory\'s ItemDropped payload')
end)

t.test("qb-inventory SERVER RegisterHook('swapItems') wrapper (ItemDropped): the caller explicitly returning false is forwarded as a real veto, and a malformed hookData fails open", function()
    local capturedCallbacks = {}
    local exportsTbl = qbFullExports({ AddHook = function(_self, hookType, callback) capturedCallbacks[hookType] = callback return 1 end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    server.RegisterHook('swapItems', function(payload) if payload.toType == 'drop' then return false end end)

    local vetoed = capturedCallbacks.ItemDropped('weed_baggy', { source = 42, item = { name = 'weed_baggy' }, amount = 1 })
    t.equals(vetoed, false)

    local r1 = capturedCallbacks.ItemDropped('weed_baggy', 'not-a-table')
    local r2 = capturedCallbacks.ItemDropped('weed_baggy', { item = { name = 'weed_baggy' }, amount = 1 }) -- missing/non-numeric source
    t.isNil(r1)
    t.isNil(r2)
end)

t.test("qb-inventory SERVER RegisterHook('swapItems'): AddHook('ItemDropped', ...) failing while AddHook('ItemAdded', ...) succeeds still returns true overall -- the veto capability this backend has always had keeps working", function()
    local exportsTbl = qbFullExports({ AddHook = function(_self, hookType, callback)
        if hookType == 'ItemDropped' then return nil end
        return 1
    end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isTrue(server.RegisterHook('swapItems', function() end))
end)

t.test("qb-inventory SERVER RegisterHook('swapItems'): AddHook returning nil (its own documented 'registration failed' signal) for ItemAdded is reported as a failed registration, not a silent success", function()
    local exportsTbl = qbFullExports({ AddHook = function() return nil end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isFalse(server.RegisterHook('swapItems', function() end))
end)

t.test('qb-inventory SERVER RegisterHook: any event name OTHER than \'swapItems\' returns false without ever calling AddHook -- no confirmed translation exists, never guessed', function()
    local called = false
    local exportsTbl = qbFullExports({ AddHook = function() called = true return 1 end })
    local f = newCompatFixture({ resourceStates = { ['qb-inventory'] = 'started' }, exportTables = { ['qb-inventory'] = exportsTbl } })
    local server = f.getFactory('inventory', 'qb-inventory')('server')
    t.isFalse(server.RegisterHook('buyItem', function() end))
    t.isFalse(server.RegisterHook('somethingElse', function() end))
    t.isFalse(called)
end)

-- ========================================================================
-- POINT 4: unconfirmed candidates -- unconditional nil, never an
-- accidentally-passing capability check, warned at most once per name.
-- ========================================================================

local UNCONFIRMED = { 'qs-inventory', 'ps-inventory', 'origen_inventory', 'codem-inventory', 'core_inventory', 'tgiann-inventory' }

for _, name in ipairs(UNCONFIRMED) do
    t.test(('%s: returns nil for BOTH realms even when the fixture pretends the resource is fully started with a plausible export table'):format(name), function()
        local f = newCompatFixture({
            resourceStates = { [name] = 'started' },
            exportTables = {
                [name] = {
                    openInventory = function() end, useItem = function() end, Items = function() return true end,
                    GetInventoryItems = function() return {} end, GetContainerFromSlot = function() end,
                    GetItemCount = function() return 0 end, RemoveItem = function() return true end,
                    RegisterStash = function() return true end, RegisterShop = function() return true end,
                    registerHook = function() return 'id' end, AddHook = function() return 1 end,
                },
            },
        })
        local factory = f.getFactory('inventory', name)
        t.equals(type(factory), 'function', name .. ' must still be registered (present but unusable), never simply absent')
        t.isNil(factory('client'))
        t.isNil(factory('server'))
    end)
end

t.test('unconfirmed candidates: the "no public source" warning is printed at most once per resource name, even when probed on both realms', function()
    local f = newCompatFixture()
    local factory = f.getFactory('inventory', 'origen_inventory')
    factory('client')
    factory('server')
    factory('client')
    t.equals(f.countPrintsContaining('origen_inventory'), 1)
end)

os.exit(t.summary())
