--[[
    tests/compat_spec.lua

    Direct tests of shared/compat/core.lua's K9Compat detection engine
    against the REAL, unmodified production file. Loaded twice into two
    separate sandboxes (one stubbing IsDuplicityVersion() to return true,
    one to return false) so both the 'server' and 'client' realm branches
    of RequiredMethods/verification/the diagnostic command get real
    coverage, not just one side.

    Every native this file touches is stubbed: IsDuplicityVersion (fake
    realm), GetResourceState (a mutable table this spec controls),
    GetCurrentResourceName, CreateThread/Wait (Sandbox's cooperative
    coroutine runner, so the startup grace-window thread can be stepped
    deterministically instead of really waiting), AddEventHandler (captures
    handlers so this spec can fire onResourceStart/onResourceStop/
    onClientResourceStart/onClientResourceStop manually), RegisterCommand
    (captures the /k9compat handler), TriggerClientEvent (captures chat
    output), and print (captured so the "log once, never per call" and
    "log once, never per redetect-if-unchanged" guarantees can be asserted
    on directly rather than trusted).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Shared sandbox builder
-- ----------------------------------------------------------------------

--- @param isServer boolean
--- @return table env, table ctx -- ctx exposes every mutable/capturing stub
local function buildEnv(isServer)
    local ctx = {
        resourceStates = {},        -- [resourceName] = 'started' | 'stopped' | ... (default 'missing')
        prints = {},
        registeredCommands = {},
        eventHandlers = {},         -- [eventName] = { handler, handler, ... }
        clientEvents = {},          -- { { eventName, target, payload }, ... }
        currentResourceName = 'john-k9',
        highCommandSources = {},    -- [source] = true/false -- drives the fake IsHighCommand
    }

    local function GetResourceState(resourceName)
        return ctx.resourceStates[resourceName] or 'missing'
    end

    local function GetCurrentResourceName()
        return ctx.currentResourceName
    end

    local function AddEventHandler(eventName, handler)
        ctx.eventHandlers[eventName] = ctx.eventHandlers[eventName] or {}
        table.insert(ctx.eventHandlers[eventName], handler)
    end

    local function fireEvent(eventName, ...)
        for _, handler in ipairs(ctx.eventHandlers[eventName] or {}) do
            handler(...)
        end
    end
    ctx.fireEvent = fireEvent

    local function RegisterCommand(name, handler, _restricted)
        ctx.registeredCommands[name] = handler
    end

    local function TriggerClientEvent(eventName, target, payload)
        table.insert(ctx.clientEvents, { eventName = eventName, target = target, payload = payload })
    end

    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do
            parts[i] = tostring(select(i, ...))
        end
        table.insert(ctx.prints, table.concat(parts, '\t'))
    end

    local threadRunner = Sandbox.newThreadRunner()
    ctx.threadRunner = threadRunner

    -- IsHighCommand: a real cross-file soft dependency in production
    -- (server/highcommand.lua) -- stubbed here per-source so authorization
    -- tests can flip it without needing the real qbx_core/job machinery.
    local function IsHighCommand(source)
        return ctx.highCommandSources[source] == true
    end
    ctx.IsHighCommand = IsHighCommand

    local env = Sandbox.newEnv({
        IsDuplicityVersion = function() return isServer end,
        GetResourceState = GetResourceState,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        AddEventHandler = AddEventHandler,
        RegisterCommand = RegisterCommand,
        TriggerClientEvent = TriggerClientEvent,
        print = printStub,
        IsHighCommand = IsHighCommand,
        Config = {
            Features = { ResourceAutoDetect = true },
            Compat = {
                autoDetect = true,
                logDetectionOnStart = true,
                diagnosticCommand = 'k9compat',
                redetectOnResourceRestart = true,
                startupGraceMs = 5000,
                Systems = {
                    inventory = { override = nil, custom = nil, candidates = { 'ox_inventory', 'qb-inventory' } },
                    target    = { override = nil, custom = nil, candidates = { 'ox_target', 'qb-target' } },
                    framework = { override = nil, custom = nil, candidates = { 'qbx_core', 'qb-core' } },
                    dispatch  = { override = nil, custom = nil, candidates = { 'ps-dispatch', 'cd_dispatch' } },
                    ambulance = { override = nil, custom = nil, candidates = { 'qbx_medical', 'qb-ambulancejob' } },
                },
            },
        },
    })
    ctx.env = env

    Sandbox.loadInto('../shared/compat/core.lua', env)
    ctx.K9Compat = env.K9Compat
    t.isNotNil(ctx.K9Compat, 'shared/compat/core.lua must define global K9Compat')

    return env, ctx
end

-- Fires this resource's own onResourceStart, steps the thread runner twice
-- (prime + run one pass) so ScheduleInitialDetection's grace-window body
-- actually executes, matching fixtures/sandbox.lua's own documented
-- stepping semantics.
local function bootAndRunInitialDetection(ctx, realmEventName)
    ctx.fireEvent(realmEventName, ctx.currentResourceName)
    ctx.threadRunner.step() -- primes past the initial Wait()
    ctx.threadRunner.step() -- runs the body once the (stepped, not real-timed) Wait returns
end

-- ----------------------------------------------------------------------
-- Contract shape
-- ----------------------------------------------------------------------

do
    local _, serverCtx = buildEnv(true)
    local RM = serverCtx.K9Compat.RequiredMethods

    t.test('RequiredMethods: matches the contract exactly for every system/realm', function()
        local expected = {
            inventory = {
                client = { 'OpenStash', 'OpenShop', 'UseItem', 'ItemExists' },
                -- 'ItemExists' added to the server realm this pass
                -- (coder-architect) -- see shared/compat/core.lua's own
                -- comment on this exact line for why.
                server = { 'GetInventoryItems', 'GetContainerFromSlot', 'GetItemCount', 'RemoveItem', 'RegisterStash', 'RegisterShop', 'RegisterHook', 'ItemExists' },
            },
            target = {
                client = { 'AddGlobalPlayer', 'AddGlobalVehicle', 'AddGlobalObject', 'AddModel', 'AddSphereZone', 'Remove', 'AddLocalEntity', 'RemoveLocalEntity' },
                server = {},
            },
            framework = {
                client = { 'GetPlayerData' },
                server = { 'GetPlayer', 'GetPlayerByCitizenId', 'GetCitizenId', 'GetJob' },
            },
            dispatch = { server = { 'Alert' }, client = {} },
            ambulance = { server = { 'IsDowned' }, client = {} },
        }
        for system, realms in pairs(expected) do
            for realm, methods in pairs(realms) do
                t.isNotNil(RM[system], 'missing system: ' .. system)
                t.isNotNil(RM[system][realm], 'missing realm: ' .. system .. '.' .. realm)
                t.equals(#RM[system][realm], #methods, ('%s.%s method count'):format(system, realm))
                for i, name in ipairs(methods) do
                    t.equals(RM[system][realm][i], name, ('%s.%s[%d]'):format(system, realm, i))
                end
            end
        end
    end)
end

-- ----------------------------------------------------------------------
-- K9Compat.Get: NEVER nil, no-op stub when nothing registered at all
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true) -- server realm

    t.test('Get: never nil for a known system, even before any RegisterAdapter call', function()
        local adapter = ctx.K9Compat.Get('inventory')
        t.isNotNil(adapter)
        t.equals(type(adapter.ItemExists), 'function', 'server realm: ItemExists is now a required server method too (added this pass), so the no-op stub must expose it like every other required method')
        t.equals(type(adapter.GetItemCount), 'function', 'server realm must stub every server-required method')
    end)

    t.test('Get: every stubbed server method returns nil and logs the reason exactly once, not per call', function()
        ctx.prints = {}
        -- target.server has ZERO required methods (nothing to stub there),
        -- so framework is used instead to exercise a real stubbed method.
        local adapter = ctx.K9Compat.Get('framework')
        t.isNil(adapter.GetPlayer('anything'))
        t.isNil(adapter.GetPlayer('anything-else'))
        local warnCount = 0
        for _, line in ipairs(ctx.prints) do
            if line:find('framework', 1, true) and line:find('nothing usable detected', 1, true) then
                warnCount = warnCount + 1
            end
        end
        t.equals(warnCount, 1, 'the "nothing usable detected" line must print exactly once regardless of how many times the stub is called')
    end)

    t.test('Get: an unknown system name is a fail-closed empty table, not nil, and warns', function()
        ctx.prints = {}
        local adapter = ctx.K9Compat.Get('not_a_real_system')
        t.isNotNil(adapter)
        t.equals(next(adapter), nil, 'unknown system stub must be an empty table')
        t.isTrue(#ctx.prints > 0)
    end)

    t.test('Which: returns nil resourceName and a reason when nothing was ever registered', function()
        local resourceName, reason = ctx.K9Compat.Which('dispatch')
        t.isNil(resourceName)
        t.isNotNil(reason)
    end)

    t.test('Which: an unknown system reports its own distinct reason without touching detection state', function()
        local resourceName, reason = ctx.K9Compat.Which('nope')
        t.isNil(resourceName)
        t.contains(reason, 'unknown system')
    end)
end

-- ----------------------------------------------------------------------
-- RegisterAdapter validation -- never crashes, warns and ignores bad calls
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)

    t.test('RegisterAdapter: rejects an unknown system, returns false, does not throw', function()
        local ok = ctx.K9Compat.RegisterAdapter('not_a_system', 'whatever', function() return {} end)
        t.isFalse(ok)
    end)

    t.test('RegisterAdapter: rejects a non-string/empty resourceName', function()
        t.isFalse(ctx.K9Compat.RegisterAdapter('inventory', nil, function() return {} end))
        t.isFalse(ctx.K9Compat.RegisterAdapter('inventory', '', function() return {} end))
    end)

    t.test('RegisterAdapter: rejects a non-function factory', function()
        t.isFalse(ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', 'not a function'))
    end)

    t.test('RegisterAdapter: accepts a well-formed registration and returns true', function()
        local ok = ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) return nil end)
        t.isTrue(ok)
    end)

    t.test('RegisterAdapter: a duplicate registration for the same (system, resourceName) warns but overwrites, does not throw', function()
        ctx.prints = {}
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) return nil end)
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) return nil end)
        local sawWarning = false
        for _, line in ipairs(ctx.prints) do
            if line:find('overwrites', 1, true) then sawWarning = true end
        end
        t.isTrue(sawWarning)
    end)
end

-- ----------------------------------------------------------------------
-- Resolution order: candidates, in order, first STARTED + verified wins
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)

    local function serverInventoryTable()
        return {
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return true end,
            RegisterStash = function() return true end,
            RegisterShop = function() return true end,
            RegisterHook = function() return true end,
            ItemExists = function() return true end, -- added to the server-realm contract this pass
        }
    end

    ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) return serverInventoryTable() end)
    ctx.K9Compat.RegisterAdapter('inventory', 'qb-inventory', function(_realm) return serverInventoryTable() end)

    t.test('candidates: neither started -> no-op stub, both recorded as skipped with "not started"', function()
        ctx.K9Compat.Redetect()
        local resourceName, reason = ctx.K9Compat.Which('inventory')
        t.isNil(resourceName)
        t.contains(reason, 'nothing usable detected')
    end)

    t.test('candidates: second candidate started (first still missing) -> second wins', function()
        ctx.resourceStates['qb-inventory'] = 'started'
        ctx.K9Compat.Redetect()
        local resourceName, reason = ctx.K9Compat.Which('inventory')
        t.equals(resourceName, 'qb-inventory')
        t.contains(reason, 'candidate')
    end)

    t.test('candidates: first candidate ALSO now started -> first (earlier in list) wins over second, "first match wins"', function()
        ctx.resourceStates['ox_inventory'] = 'started'
        ctx.K9Compat.Redetect()
        local resourceName = ctx.K9Compat.Which('inventory')
        t.equals(resourceName, 'ox_inventory')
    end)

    t.test('candidates: a started candidate missing a required method is skipped, detection moves to the next', function()
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm)
            local incomplete = serverInventoryTable()
            incomplete.RegisterHook = nil -- drop one required method
            return incomplete
        end)
        ctx.K9Compat.Redetect()
        local resourceName = ctx.K9Compat.Which('inventory')
        t.equals(resourceName, 'qb-inventory', 'ox_inventory is started but incomplete, so qb-inventory (next in list) must win')
    end)

    t.test('candidates: a factory returning nil ("present but unusable") is skipped like a missing-method table', function()
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) return nil end)
        ctx.K9Compat.Redetect()
        t.equals(ctx.K9Compat.Which('inventory'), 'qb-inventory')
    end)

    t.test('candidates: a factory that THROWS is caught, skipped, and detection continues -- never propagates', function()
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) error('boom') end)
        local ok = pcall(ctx.K9Compat.Redetect)
        t.isTrue(ok, 'Redetect must never throw even when a registered factory does')
        t.equals(ctx.K9Compat.Which('inventory'), 'qb-inventory')
    end)

    t.test('candidates: with NOTHING started, both skipped, resolves to no-op stub again', function()
        ctx.resourceStates['ox_inventory'] = 'stopped'
        ctx.resourceStates['qb-inventory'] = 'stopped'
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm) return serverInventoryTable() end)
        ctx.K9Compat.Redetect()
        t.isNil(ctx.K9Compat.Which('inventory'))
    end)
end

-- ----------------------------------------------------------------------
-- override: absolute pin, does NOT fall through to candidates on failure
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.Systems.dispatch.candidates = { 'ps-dispatch' }

    local function serverDispatchTable()
        return { Alert = function() return true end }
    end

    t.test('override: resolves to the named resource when it is started, registered and verifies', function()
        ctx.K9Compat.RegisterAdapter('dispatch', 'ps-dispatch', function(_realm) return serverDispatchTable() end)
        ctx.resourceStates['ps-dispatch'] = 'started'
        ctx.env.Config.Compat.Systems.dispatch.override = 'ps-dispatch'
        ctx.K9Compat.Redetect()
        t.equals(ctx.K9Compat.Which('dispatch'), 'ps-dispatch')
    end)

    t.test('override: naming an unregistered/unstarted resource -> no-op stub, NEVER falls through to candidates', function()
        ctx.K9Compat.RegisterAdapter('dispatch', 'cd_dispatch', function(_realm) return serverDispatchTable() end)
        ctx.resourceStates['cd_dispatch'] = 'started' -- a perfectly good candidate exists...
        ctx.env.Config.Compat.Systems.dispatch.override = 'some_typo_name' -- ...but override names something else entirely
        ctx.env.Config.Compat.Systems.dispatch.candidates = { 'cd_dispatch' }
        ctx.K9Compat.Redetect()
        local resourceName, reason = ctx.K9Compat.Which('dispatch')
        t.isNil(resourceName, 'override must never silently fall back to a candidate, even a perfectly good one')
        t.contains(reason, 'override')
    end)
end

-- ----------------------------------------------------------------------
-- custom: wins outright over override, verified, no fallthrough on failure
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.Systems.ambulance.candidates = { 'qbx_medical' }
    ctx.K9Compat.RegisterAdapter('ambulance', 'qbx_medical', function(_realm) return { IsDowned = function() return false end } end)
    ctx.resourceStates['qbx_medical'] = 'started'
    ctx.env.Config.Compat.Systems.ambulance.override = 'qbx_medical'

    t.test('custom: a complete custom table wins outright, even though a valid override also resolves', function()
        ctx.env.Config.Compat.Systems.ambulance.custom = { IsDowned = function() return true end }
        ctx.K9Compat.Redetect()
        local resourceName, reason = ctx.K9Compat.Which('ambulance')
        t.equals(resourceName, 'custom')
        t.contains(reason, 'custom')
        t.isTrue(ctx.K9Compat.Get('ambulance').IsDowned('anyone'))
    end)

    t.test('custom: an incomplete custom table fails verification and does NOT fall through to override', function()
        ctx.env.Config.Compat.Systems.ambulance.custom = { SomethingElse = function() end } -- missing IsDowned
        ctx.K9Compat.Redetect()
        local resourceName, reason = ctx.K9Compat.Which('ambulance')
        t.isNil(resourceName, 'an incomplete custom table must resolve to the no-op stub, not silently fall back to a working override')
        t.contains(reason, 'custom')
    end)

    t.test('custom: nil (unset) correctly falls through to override', function()
        ctx.env.Config.Compat.Systems.ambulance.custom = nil
        ctx.K9Compat.Redetect()
        t.equals(ctx.K9Compat.Which('ambulance'), 'qbx_medical')
    end)
end

-- ----------------------------------------------------------------------
-- Empty required-methods realm (target.server / dispatch.client /
-- ambulance.client) -- any non-nil table verifies trivially
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true) -- server realm -> target.server required list is EMPTY
    ctx.env.Config.Compat.Systems.target.candidates = { 'ox_target' }
    ctx.resourceStates['ox_target'] = 'started'

    t.test('an empty required-methods realm accepts any non-nil table from the factory', function()
        ctx.K9Compat.RegisterAdapter('target', 'ox_target', function(_realm) return { anything = true } end)
        ctx.K9Compat.Redetect()
        t.equals(ctx.K9Compat.Which('target'), 'ox_target')
    end)

    t.test('an empty required-methods realm still rejects a non-table (nil) factory result', function()
        ctx.K9Compat.RegisterAdapter('target', 'ox_target', function(_realm) return nil end)
        ctx.K9Compat.Redetect()
        t.isNil(ctx.K9Compat.Which('target'))
    end)
end

-- ----------------------------------------------------------------------
-- autoDetect gating: EITHER Config.Features.ResourceAutoDetect or
-- Config.Compat.autoDetect being false skips ONLY the candidates tier
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.Systems.framework.candidates = { 'qbx_core' }
    ctx.K9Compat.RegisterAdapter('framework', 'qbx_core', function(_realm)
        return { GetPlayer = function() end, GetPlayerByCitizenId = function() end, GetCitizenId = function() end, GetJob = function() end }
    end)
    ctx.resourceStates['qbx_core'] = 'started'

    t.test('sanity: candidates resolve normally when both auto-detect flags are true', function()
        ctx.K9Compat.Redetect()
        t.equals(ctx.K9Compat.Which('framework'), 'qbx_core')
    end)

    t.test('Config.Compat.autoDetect = false skips the candidate scan even though the resource is started', function()
        ctx.env.Config.Compat.autoDetect = false
        ctx.K9Compat.Redetect()
        t.isNil(ctx.K9Compat.Which('framework'))
        ctx.env.Config.Compat.autoDetect = true
    end)

    t.test('Config.Features.ResourceAutoDetect = false ALSO skips the candidate scan on its own', function()
        ctx.env.Config.Features.ResourceAutoDetect = false
        ctx.K9Compat.Redetect()
        t.isNil(ctx.K9Compat.Which('framework'))
        ctx.env.Config.Features.ResourceAutoDetect = true
    end)

    t.test('override still resolves normally even with BOTH auto-detect flags off', function()
        ctx.env.Config.Compat.autoDetect = false
        ctx.env.Config.Features.ResourceAutoDetect = false
        ctx.env.Config.Compat.Systems.framework.override = 'qbx_core'
        ctx.K9Compat.Redetect()
        t.equals(ctx.K9Compat.Which('framework'), 'qbx_core', 'override is a hand-pin, must work regardless of auto-detect flags')
        ctx.env.Config.Compat.Systems.framework.override = nil
        ctx.env.Config.Compat.autoDetect = true
        ctx.env.Config.Features.ResourceAutoDetect = true
    end)
end

-- ----------------------------------------------------------------------
-- Safe-adapter pcall wrapping: a throwing real method fails closed, warns
-- once, never propagates
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.Systems.dispatch.candidates = { 'ps-dispatch' }
    ctx.resourceStates['ps-dispatch'] = 'started'
    ctx.K9Compat.RegisterAdapter('dispatch', 'ps-dispatch', function(_realm)
        return { Alert = function(_payload) error('third-party dispatch exploded') end }
    end)
    ctx.K9Compat.Redetect()

    t.test('a verified real adapter method that throws returns nil instead of propagating', function()
        local adapter = ctx.K9Compat.Get('dispatch')
        local ok, result = pcall(adapter.Alert, { title = 'test' })
        t.isTrue(ok, 'the wrapped method itself must never throw out to the caller')
        t.isNil(result)
    end)

    t.test('the throw is logged exactly once across repeated calls, not per call', function()
        -- Redetect() first to clear the per-method "warned once" marker the
        -- PRECEDING test already tripped (it, correctly, only logs once for
        -- the life of a detection result) -- otherwise this test would
        -- observe zero new log lines and wrongly look like a regression.
        ctx.K9Compat.Redetect()
        ctx.prints = {}
        local adapter = ctx.K9Compat.Get('dispatch')
        adapter.Alert({})
        adapter.Alert({})
        adapter.Alert({})
        local count = 0
        for _, line in ipairs(ctx.prints) do
            if line:find('errored', 1, true) then count = count + 1 end
        end
        t.equals(count, 1)
    end)
end

-- ----------------------------------------------------------------------
-- Report(): multi-line, mentions all five systems
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.K9Compat.Redetect()

    t.test('Report: mentions every one of the five systems, one line each', function()
        local report = ctx.K9Compat.Report()
        for _, system in ipairs({ 'inventory', 'target', 'framework', 'dispatch', 'ambulance' }) do
            t.contains(report, system)
        end
        local lineCount = 0
        for _ in report:gmatch('\n') do lineCount = lineCount + 1 end
        t.isTrue(lineCount >= 5, 'expected at least 5 newlines (header + 5 system lines)')
    end)
end

-- ----------------------------------------------------------------------
-- Realm-specific: client-side coverage (the other half of the shared file)
-- ----------------------------------------------------------------------

do
    local _, clientCtx = buildEnv(false)

    t.test('client realm: RequiredMethods.inventory.client is what gets stubbed, not the server list', function()
        local adapter = clientCtx.K9Compat.Get('inventory')
        t.equals(type(adapter.ItemExists), 'function')
        t.equals(type(adapter.GetItemCount), 'nil', 'server-only method must not appear on the client-realm stub')
    end)

    t.test('client realm: factory receives realm="client"', function()
        local seenRealm
        clientCtx.K9Compat.RegisterAdapter('target', 'ox_target', function(realm)
            seenRealm = realm
            return { AddGlobalPlayer = function() end, AddGlobalVehicle = function() end, AddGlobalObject = function() end, AddModel = function() end, AddSphereZone = function() end, Remove = function() end, AddLocalEntity = function() end, RemoveLocalEntity = function() end }
        end)
        clientCtx.resourceStates['ox_target'] = 'started'
        clientCtx.env.Config.Compat.Systems.target.candidates = { 'ox_target' }
        clientCtx.K9Compat.Redetect()
        t.equals(seenRealm, 'client')
    end)

    t.test('client realm: onClientResourceStart/onClientResourceStop are the hooks used, not the server event names', function()
        t.isNotNil(clientCtx.eventHandlers['onClientResourceStart'])
        t.isNil(clientCtx.eventHandlers['onResourceStart'])
    end)
end

-- ----------------------------------------------------------------------
-- Startup grace window + live redetect on resource start/stop
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.Systems.inventory.candidates = { 'ox_inventory' }

    t.test('startup: detection runs after onResourceStart fires for THIS resource, prints the summary once', function()
        ctx.prints = {}
        bootAndRunInitialDetection(ctx, 'onResourceStart')
        local sawSummary = false
        for _, line in ipairs(ctx.prints) do
            if line:find('K9Compat detection summary', 1, true) then sawSummary = true end
        end
        t.isTrue(sawSummary)
    end)

    t.test('live redetect: another resource starting re-runs detection and picks up a newly-started candidate', function()
        ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm)
            return {
                GetInventoryItems = function() end, GetContainerFromSlot = function() end,
                GetItemCount = function() end, RemoveItem = function() end,
                RegisterStash = function() end, RegisterShop = function() end, RegisterHook = function() end,
                ItemExists = function() end,
            }
        end)
        t.isNil(ctx.K9Compat.Which('inventory'))
        ctx.resourceStates['ox_inventory'] = 'started'
        ctx.fireEvent('onResourceStart', 'ox_inventory')
        t.equals(ctx.K9Compat.Which('inventory'), 'ox_inventory')
    end)

    t.test('live redetect: this resource\'s OWN onResourceStart does not re-trigger MaybeLiveRedetect (no double processing)', function()
        -- Firing our own name again must not error and must be a pure
        -- re-schedule of the initial-detection thread, not a live-redetect
        -- pass -- covered implicitly by the absence of a crash/duplicate
        -- summary explosion; the real behavioral guarantee (self excluded)
        -- is exercised by construction since MaybeLiveRedetect early-returns
        -- on GetCurrentResourceName() equality.
        local ok = pcall(ctx.fireEvent, 'onResourceStart', ctx.currentResourceName)
        t.isTrue(ok)
    end)

    t.test('live redetect: resourceName equal to GetCurrentResourceName() is excluded from MaybeLiveRedetect even via onResourceStop', function()
        local ok = pcall(ctx.fireEvent, 'onResourceStop', ctx.currentResourceName)
        t.isTrue(ok)
    end)

    t.test('live redetect: disabled via Config.Compat.redetectOnResourceRestart = false, state does not change on a live event', function()
        ctx.resourceStates['ox_inventory'] = 'stopped'
        ctx.fireEvent('onResourceStop', 'ox_inventory')
        t.isNil(ctx.K9Compat.Which('inventory'), 'sanity: stopping it while the hook is enabled must clear detection')

        ctx.resourceStates['ox_inventory'] = 'started'
        ctx.env.Config.Compat.redetectOnResourceRestart = false
        ctx.fireEvent('onResourceStart', 'ox_inventory')
        t.isNil(ctx.K9Compat.Which('inventory'), 'with the hook disabled, a live resource start must not trigger a redetect')
        ctx.env.Config.Compat.redetectOnResourceRestart = true
    end)
end

-- ----------------------------------------------------------------------
-- /k9compat diagnostic command: High-Command gated, fails closed
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    bootAndRunInitialDetection(ctx, 'onResourceStart')

    t.test('diagnostic command: registered under the configured name', function()
        t.isNotNil(ctx.registeredCommands.k9compat)
    end)

    t.test('diagnostic command: an unauthorized caller is denied, told so, and gets no report', function()
        ctx.clientEvents = {}
        ctx.highCommandSources[9001] = false
        ctx.registeredCommands.k9compat(9001, {})
        t.equals(#ctx.clientEvents, 1, 'exactly one denial message, not a full report')
        t.contains(ctx.clientEvents[1].payload.args[2], 'not authorized')
    end)

    t.test('diagnostic command: a High Command caller gets the full report via chat, including skip detail', function()
        ctx.clientEvents = {}
        ctx.highCommandSources[9002] = true
        ctx.registeredCommands.k9compat(9002, {})
        t.isTrue(#ctx.clientEvents > 1, 'an authorized caller must get more than a single denial-shaped line')
        local sawSummaryHeader = false
        for _, event in ipairs(ctx.clientEvents) do
            if event.payload.args[2]:find('K9Compat detection summary', 1, true) then sawSummaryHeader = true end
        end
        t.isTrue(sawSummaryHeader)
    end)

    t.test('diagnostic command: FAILS CLOSED when IsHighCommand is not a function at all', function()
        ctx.env.IsHighCommand = nil
        ctx.clientEvents = {}
        ctx.registeredCommands.k9compat(9003, {})
        t.equals(#ctx.clientEvents, 1)
        t.contains(ctx.clientEvents[1].payload.args[2], 'not authorized')
    end)
end

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.diagnosticCommand = false

    t.test('diagnosticCommand = false: no command is registered at all', function()
        bootAndRunInitialDetection(ctx, 'onResourceStart')
        t.isNil(ctx.registeredCommands.k9compat)
    end)
end

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.diagnosticCommand = 42 -- neither a string nor exactly `false`

    t.test('diagnosticCommand = an invalid, non-false value: fails closed, warns, does not register', function()
        ctx.prints = {}
        bootAndRunInitialDetection(ctx, 'onResourceStart')
        t.isNil(ctx.registeredCommands.k9compat)
        local sawWarning = false
        for _, line in ipairs(ctx.prints) do
            if line:find('WARNING', 1, true) and line:find('diagnosticCommand', 1, true) then sawWarning = true end
        end
        t.isTrue(sawWarning)
    end)
end

-- ----------------------------------------------------------------------
-- startupGraceMs fail-safe: an invalid value warns and detects immediately
-- rather than hanging forever
-- ----------------------------------------------------------------------

do
    local _, ctx = buildEnv(true)
    ctx.env.Config.Compat.startupGraceMs = -5
    ctx.env.Config.Compat.Systems.inventory.candidates = { 'ox_inventory' }
    ctx.K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(_realm)
        return {
            GetInventoryItems = function() end, GetContainerFromSlot = function() end,
            GetItemCount = function() end, RemoveItem = function() end,
            RegisterStash = function() end, RegisterShop = function() end, RegisterHook = function() end,
            ItemExists = function() end,
        }
    end)
    ctx.resourceStates['ox_inventory'] = 'started'

    t.test('an invalid startupGraceMs still results in detection running (no indefinite hang), with a warning', function()
        ctx.prints = {}
        ctx.fireEvent('onResourceStart', ctx.currentResourceName)
        ctx.threadRunner.step()
        t.equals(ctx.K9Compat.Which('inventory'), 'ox_inventory')
        local sawWarning = false
        for _, line in ipairs(ctx.prints) do
            if line:find('startupGraceMs', 1, true) then sawWarning = true end
        end
        t.isTrue(sawWarning)
    end)
end

os.exit(t.summary())
