--[[
    tests/partnership_spec.lua

    Direct + indirect tests of server/partnership.lua -- the mutually-
    consented "K9 partnership" registry (DEVELOPER_REFERENCE.md §12.0 item 7) --
    against the REAL, unmodified production file. Loads the real
    server/cooldowns.lua (hard file-load-time dependency: NewCooldown for
    PartnerRequestCooldown, NewMutex for PartnershipEstablishMutex) and
    server/entities.lua (fxmanifest.lua's own load-order neighbor for
    cooldowns.lua; server/partnership.lua itself never calls
    ResolveNetworkEntity/ResolveConnectedPlayerFromPed, loaded anyway to
    mirror the real server_scripts order exactly, per this task's own
    instruction -- harmless, since entities.lua defines its functions
    unconditionally at load time with no natives required until CALL time).

    server/certifications/ is DELIBERATELY NEVER loaded here.
    server/partnership.lua consumes HasK9Access and IsConfiguredK9Model as
    plain resource-globals (no runtime-existence guard on THOSE two --
    unlike GetActivePartnerCitizenId/EndActiveEffectForHolder in
    this file's own header states these are a hard,
    load-order-guaranteed dependency, not an optional one), so this spec
    controls both as test-supplied stubs -- exactly the same "this file's
    job is server/partnership.lua's OWN eligibility/consent/mutex logic,
    not a second copy of server/certifications/'s already-covered
    HasK9Access/IsConfiguredK9Model" discipline kennel_spec.lua/
    combat_spec.lua already established for the identical shape.

    locale() is NEVER stubbed (this suite's own convention) -- every
    NotifyPlayer(..., locale('partnership.xxx'), ...) call exercised below
    resolves for real against locales/en.json, so this spec also doubles as
    a regression check that every 'partnership.*'/'common.*' key it reaches
    still exists there.

    ONE FRESH SANDBOX PER TEST (never shared) -- Partnerships,
    PendingPartnershipRequests, and PartnershipEstablishMutex are all
    file-lifetime `local` upvalues; reusing one sandbox across unrelated
    cases would leak state, same discipline every other spec in this suite
    follows.

    YIELDING EVENT HANDLERS: the accept branch of respondPartnerUp
    (RegisterNetEvent('qbx_k9unit:server:respondPartnerUp', ...)) makes real
    MySQL.scalar.await/MySQL.insert.await calls inside a pcall-wrapped
    critical section guarded by PartnershipEstablishMutex -- exactly the
    kind of check-then-act sequence spanning two yielding awaits that a
    real FXServer coroutine could genuinely interleave two callers through.
    Every test in the "MUTEX" section below dispatches through REAL Lua
    coroutines (matching certifications_spec.lua's own
    "LOAD-BEARING -- two overlapping grants... through a yielding MySQL
    stub" technique and combat_spec.lua's dispatchStepped/startCoroutine
    shape) so the lock's exclusion is demonstrated by the test harness
    genuinely being unable to interleave past it, not by fixture luck or
    sequencing that happens to avoid the race.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- CheckPartnershipEligibility's proximity check does
-- `#(GetEntityCoords(a) - GetEntityCoords(b))`, so both the `-` and `#`
-- metamethods must be modeled, same shape certifications_spec.lua/
-- combat_spec.lua already use for the identical native.
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

local K9_MODEL_HASH = 111
local NON_K9_MODEL_HASH = 0

-- Real, shipped config.lua values -- see config.lua's own Config.Partnership
-- block. Boundary/timing tests below advance against THESE numbers, not
-- arbitrary round test constants, matching this suite's established
-- convention (combat_spec.lua's baseline*Config() functions).
local PROXIMITY_METERS = 5.0
local REQUEST_TTL_MS = 30000
local REQUEST_COOLDOWN_MS = 1000

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts table? { handlerPartnership: boolean (default true), departments: table (default { police = true, sheriff = true }) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local notifyLog = {} -- { {source=, message=, kind=}, ... }
    local function NotifyPlayer(src, message, kind)
        notifyLog[#notifyLog + 1] = { source = src, message = message, kind = kind }
    end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local outboundEvents = {} -- { {eventName, ...}, ... }
    local function TriggerEvent(eventName, ...)
        outboundEvents[#outboundEvents + 1] = { eventName, ... }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, playersByCitizenId = {}, {}
    --- @param src number
    --- @param citizenid string
    --- @param job table? -- { name = string } -- omit entirely for a pure K9-role party with no job relevance
    local function registerPlayer(src, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, source = src, job = job } }
        playersBySource[src] = p
        playersByCitizenId[citizenid] = p
        return p
    end
    local function disconnectPlayer(src)
        local p = playersBySource[src]
        if not p then return end
        playersBySource[src] = nil
        playersByCitizenId[p.PlayerData.citizenid] = nil
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local pedBySource, coordsByPed, modelByPed = {}, {}, {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end
    local function GetEntityModel(ped) return modelByPed[ped] or NON_K9_MODEL_HASH end

    --- @param src number
    --- @param pedHandle number
    --- @param coords table? -- vec3(x,y,z), default origin
    --- @param isK9Model boolean? -- default false
    local function setPed(src, pedHandle, coords, isK9Model)
        pedBySource[src] = pedHandle
        coordsByPed[pedHandle] = coords or vec3(0, 0, 0)
        modelByPed[pedHandle] = isK9Model and K9_MODEL_HASH or NON_K9_MODEL_HASH
    end

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end
    local function IsConfiguredK9Model(hash) return hash == K9_MODEL_HASH end

    -- K9 role/model decoupling (server/appearance.lua) -- CheckPartnershipEligibility
    -- ORs this in alongside IsConfiguredK9Model(GetEntityModel(...)) so a
    -- role-holder on a non-K9 model still counts as "the K9 party". Stubbed
    -- here (not the real server/appearance.lua), same "this file's own
    -- logic only" reasoning as HasK9Access/IsConfiguredK9Model above.
    -- Defaults false.
    local hasRoleBySource = {}
    local function HasK9Role(src) return hasRoleBySource[src] == true end

    local mysql = {
        single = { await = function(_sql, _params) return nil end }, -- RefreshPartnershipCache / DoBreakPartnership SELECT: default "no active row"
        scalar = { await = function(_sql, _params) return nil end }, -- establish critical section pre-INSERT checks: default "not already partnered"
        insert = { await = function(_sql, _params) return 1 end },   -- default: insert succeeds, fake id 1
        update = { await = function(_sql, _params) return 1 end },   -- default: exactly one row affected
    }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local onlineIds = {}
    local function GetPlayers()
        local out = {}
        for id in pairs(onlineIds) do out[#out + 1] = tostring(id) end
        return out
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local Config = {
        Features = { HandlerPartnership = opts.handlerPartnership ~= false },
        Departments = opts.departments or { police = true, sheriff = true },
        Partnership = {
            ProximityMeters = PROXIMITY_METERS,
            RequestTTLMs = REQUEST_TTL_MS,
            RequestCooldownMs = opts.requestCooldownMs or REQUEST_COOLDOWN_MS,
        },
    }

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        NotifyPlayer = NotifyPlayer,
        TriggerClientEvent = TriggerClientEvent,
        TriggerEvent = TriggerEvent,
        print = printStub,
        exports = exportsStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        HasK9Access = HasK9Access,
        IsConfiguredK9Model = IsConfiguredK9Model,
        HasK9Role = HasK9Role,
        MySQL = mysql,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        lib = libStub,
        GetPlayers = GetPlayers,
        GetCurrentResourceName = GetCurrentResourceName,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env) -- K9Store; server/partnership.lua reads and writes through it now rather than calling MySQL directly
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    -- Drop every lifecycle handler the DEPENDENCIES above registered, so
    -- the handler-count assertions below measure server/partnership.lua's
    -- own registrations and nothing else -- which is what those tests say
    -- they are checking. server/datastore.lua now registers its own
    -- onResourceStart handler (the schema-collision safety net), which
    -- would otherwise make this file's "registers exactly 1
    -- onResourceStart" assertion read 2 and fail against a handler that
    -- was never partnership.lua's.
    --
    -- SETTLE THE SCHEMA-COLLISION PROBE FIRST (boot-order-race audit, this
    -- pass), before wiping every dependency's own onResourceStart
    -- registration below: server/datastore.lua's own handler (just loaded
    -- above) is what sets SCHEMA_CHECK_SETTLED -- if it is wiped WITHOUT
    -- ever having fired, K9Store.WaitForSchemaCheckToSettle() (now called
    -- by this file's own onResourceStart backfill loop) would never settle
    -- for the life of this fixture, since nothing else in this sandbox
    -- ever fires it again. Fired here, ONCE, with no MySQL.query.await
    -- override in place yet (this file's own mysql.query is never even
    -- defined -- see `mysql` above -- so the probe's own pcall degrades to
    -- "could not run, proceeding as if no collision was found," exactly
    -- like a real restricted-DB-user install; harmless and already this
    -- probe's own documented degrade path) so every test below inherits an
    -- already-settled, "no collision" state, matching a real resource
    -- where the probe has long since resolved by the time any player
    -- action reaches partnership.lua.
    for _, fn in ipairs(eventHandlers['onResourceStart'] or {}) do fn('qbx_k9unit') end

    -- This deliberately runs BEFORE partnership.lua loads, so everything
    -- that file registers -- including PartnerRequestCooldown's own
    -- :RegisterPlayerDropped(), which is why the playerDropped count below
    -- is legitimately 2 -- is still captured exactly as before.
    for name in pairs(eventHandlers) do eventHandlers[name] = nil end

    Sandbox.loadInto('../server/partnership.lua', env)

    --- Drives `netEvents[eventName]` to completion inside a real coroutine,
    --- auto-resuming through any yield with no interaction -- correct for
    --- every handler/branch that never actually yields (which is most of
    --- them), and for the accept branch too when a test does not need to
    --- interleave anything else mid-flight.
    --- @param eventName string
    --- @param src number
    --- @param args table
    local function dispatchStepped(eventName, src, args)
        env.source = src
        local handler = capturedEvents[eventName]
        assert(handler, 'no handler registered for ' .. eventName)
        local co = coroutine.create(handler)
        local first = true
        for _ = 1, 50 do
            local result
            if first then
                result = { coroutine.resume(co, table.unpack(args)) }
                first = false
            else
                result = { coroutine.resume(co) }
            end
            if not result[1] then
                error(('dispatch(%s) coroutine error: %s'):format(eventName, tostring(result[2])))
            end
            if coroutine.status(co) == 'dead' then return end
        end
        error(('dispatch(%s) did not complete after repeated resumes -- unexpected extra yield?'):format(eventName))
    end

    return {
        env = env,
        config = Config,
        notifyLog = notifyLog,
        clientEvents = clientEvents,
        outboundEvents = outboundEvents,
        printLog = printLog,
        mysql = mysql,
        events = capturedEvents,
        eventHandlers = eventHandlers,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        setPed = setPed,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        setK9Role = function(src, hasRole) hasRoleBySource[src] = hasRole end,
        addOnline = function(id) onlineIds[id] = true end,
        setSource = function(src) env.source = src end,
        advance = function(ms) state.now = state.now + ms end,
        dispatchNetEvent = function(eventName, src, ...)
            dispatchStepped(eventName, src, { ... })
        end,
        --- Manual, caller-driven coroutine over a single net event handler --
        --- the only way to interleave a SECOND, fully independent dispatch
        --- while the first is still parked mid-yield (the mutex tests below).
        --- @param eventName string
        --- @param src number
        --- @param args table
        --- @return table handle -- { resume = fun(), isDead = fun(): boolean }
        startCoroutine = function(eventName, src, args)
            env.source = src
            local handler = capturedEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            local co = coroutine.create(handler)
            local started = false
            return {
                resume = function()
                    local result
                    if not started then
                        started = true
                        result = { coroutine.resume(co, table.unpack(args)) }
                    else
                        result = { coroutine.resume(co) }
                    end
                    if not result[1] then
                        error('startCoroutine resume error: ' .. tostring(result[2]))
                    end
                end,
                isDead = function() return coroutine.status(co) == 'dead' end,
            }
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, h in ipairs(eventHandlers['playerDropped'] or {}) do h() end
        end,
        fireResourceStart = function(resourceName)
            for _, h in ipairs(eventHandlers['onResourceStart'] or {}) do h(resourceName) end
        end,
        firePlayerLoaded = function(player)
            for _, h in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do h(player) end
        end,
    }
end

--- @param f table
--- @param src number
--- @return table? -- the LAST notifyLog entry for that source, or nil
local function lastNotifyFor(f, src)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == src then found = entry end
    end
    return found
end

--- @param f table
--- @param src number
--- @param message string
--- @param kind string
--- @return boolean
local function notifiedExactly(f, src, message, kind)
    local entry = lastNotifyFor(f, src)
    return entry ~= nil and entry.message == message and entry.kind == kind
end

--- @param f table
--- @param eventName string
--- @return table?
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then return f.clientEvents[i] end
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

--- Wires one fully-eligible K9-officer pair at mutual proximity, ready for
--- a request+accept round trip. Returns both srcs for convenience.
--- @param f table
--- @param officerSrc number
--- @param officerCid string
--- @param k9Src number
--- @param k9Cid string
--- @param opts table? { job: string (default 'police'), coords: table (default vec3(0,0,0) for both) }
local function wirePair(f, officerSrc, officerCid, k9Src, k9Cid, opts)
    opts = opts or {}
    local job = opts.job or 'police'
    f.registerPlayer(officerSrc, officerCid, { name = job })
    f.registerPlayer(k9Src, k9Cid, nil)
    f.setPed(officerSrc, officerSrc * 100, opts.coords or vec3(0, 0, 0), false)
    f.setPed(k9Src, k9Src * 100, opts.coords or vec3(0, 0, 0), true)
    f.setAccess(k9Src, true)
end

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/partnership.lua registers exactly its 3 documented server net events', function()
    local f = newFixture()
    local count = 0
    for name in pairs(f.events) do count = count + 1 end
    t.equals(count, 3)
    for _, name in ipairs({
        'qbx_k9unit:server:requestPartnerUp',
        'qbx_k9unit:server:respondPartnerUp',
        'qbx_k9unit:server:breakPartnership',
    }) do
        t.isTrue(f.events[name] ~= nil, name .. ' must be registered')
    end
end)

t.test('server/partnership.lua registers exactly its 1 documented callback', function()
    local f = newFixture()
    t.isTrue(type(f.callbacks['qbx_k9unit:server:getPartnershipState']) == 'function')
end)

t.test('server/partnership.lua registers playerDropped, onResourceStart, and QBCore:Server:PlayerLoaded handlers', function()
    local f = newFixture()
    -- 2, not 1: PartnerRequestCooldown's own :RegisterPlayerDropped() PLUS
    -- this file's own explicit AddEventHandler('playerDropped', ...) for
    -- pending-request/cache cleanup -- same "multiple independent handlers
    -- for the same event name" shape combat_spec.lua/kennel_spec.lua's own
    -- equivalent sanity tests already document for their own files.
    t.equals(#(f.eventHandlers['playerDropped'] or {}), 2)
    t.equals(#(f.eventHandlers['onResourceStart'] or {}), 1)
    t.equals(#(f.eventHandlers['QBCore:Server:PlayerLoaded'] or {}), 1)
end)

t.test('EVERY tracker in server/partnership.lua has a cleanup strategy -- source-keyed ones register a playerDropped hook, key-keyed ones sweep, and none has neither', function()
    -- THE REAL TRIPWIRE. The exact-count assertion above only catches a
    -- cleanup hook being REMOVED. It cannot catch the thing that actually
    -- happens: somebody adds a NewCooldown()/NewMutex() and forgets
    -- .RegisterPlayerDropped(), which leaves the count unchanged and this
    -- file green while a table grows for the whole uptime of the server.
    --
    -- tests/combat_spec.lua found and fixed this exact blind spot for its
    -- own file. The fix lived there and never reached the other specs
    -- asserting the same invariant the same broken way -- this is that
    -- propagation.
    --
    -- NOTE ON PartnershipEstablishMutex, which is why this file needs the
    -- ALLOWLIST the other copies of this test do not: it is deliberately
    -- keyed by ONE FIXED resource-wide key rather than by a source, so it
    -- holds at most a single entry and has nothing to leak. It correctly
    -- has neither a playerDropped hook nor a sweep, and adding either would
    -- be wrong. Every OTHER tracker must have one.
    local ALLOWED_WITHOUT_CLEANUP = { PartnershipEstablishMutex = true }

    local handle = assert(io.open('../server/partnership.lua', 'r'))
    local text = handle:read('*a')
    handle:close()

    local declared = {}
    for name in text:gmatch('local%s+([%w_]+)%s*=%s*New[CM]') do
        declared[#declared + 1] = name
    end
    t.isTrue(#declared >= 2,
        ('sanity: only found %d tracker declaration(s) in server/partnership.lua -- the pattern has probably drifted; fix it rather than lowering this floor'):format(#declared))

    local checked = 0
    for _, name in ipairs(declared) do
        if not ALLOWED_WITHOUT_CLEANUP[name] then
            checked = checked + 1
            local hasPlayerDropped = text:find(name .. '.RegisterPlayerDropped(', 1, true) ~= nil
            local hasSweep = text:find(name .. '.StartSweep(', 1, true) ~= nil
            t.isTrue(hasPlayerDropped or hasSweep,
                name .. ' has neither .RegisterPlayerDropped() nor .StartSweep() -- whatever it is keyed by, its table grows for the whole uptime of the server with nothing to bound it')
        end
    end
    t.isTrue(checked >= 1, 'the allowlist must never grow to cover every tracker -- that would make this test vacuous')
end)

-- ========================================================================
-- REGRESSION (same class of bug QA reproduced against server/combat.lua):
-- PartnerRequestCooldown = NewCooldown(Config.Partnership.RequestCooldownMs)
-- used to hand a raw, operator-editable Config value straight to
-- NewCooldown -- an uncaught non-positive/NaN value there would abort THIS
-- FILE's own load from that line onward, taking every one of its 3 net
-- events, its 1 callback, and -- critically -- ForceBreakPartnershipForCitizenId
-- (the global termination path other files, e.g. decertification/tenure,
-- depend on to unwind a partnership from outside this file) down with it.
-- Fixed via ResolveConfiguredThresholdMs (server/cooldowns.lua) at this
-- file's one raw Config-cooldown call site. Proves the fix at the exact
-- level the bug was found: does the file still load, and is the
-- termination path other files depend on still reachable, no matter what
-- an operator puts in the config.
-- ========================================================================

t.test('REGRESSION: Config.Partnership.RequestCooldownMs = 0 no longer aborts this file\'s load -- clamps to the shipped 1000ms fallback, warns loudly (naming the exact key/value/substitute), and ForceBreakPartnershipForCitizenId stays defined', function()
    local f = newFixture({ requestCooldownMs = 0 })

    t.equals(type(f.env.ForceBreakPartnershipForCitizenId), 'function',
        'the termination path other files depend on to unwind a partnership must remain reachable no matter what an operator puts in the config')

    local count = 0
    for name in pairs(f.events) do count = count + 1 end
    t.equals(count, 3, 'every net event this file documents must still register, not just the ones textually above the bad value')
    t.isTrue(type(f.callbacks['qbx_k9unit:server:getPartnershipState']) == 'function')
    t.equals(#(f.eventHandlers['playerDropped'] or {}), 2)
    t.equals(#(f.eventHandlers['onResourceStart'] or {}), 1)

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Partnership.RequestCooldownMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find('1000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted -- the operator must still find out')
end)

t.test('REGRESSION: Config.Partnership.RequestCooldownMs = NaN also no longer aborts this file\'s load', function()
    local f = newFixture({ requestCooldownMs = 0 / 0 })
    local count = 0
    for name in pairs(f.events) do count = count + 1 end
    t.equals(count, 3)
end)

-- ========================================================================
-- CheckPartnershipEligibility, exercised via requestPartnerUp.
-- ========================================================================

t.test('requestPartnerUp: feature disabled is rejected', function()
    local f = newFixture({ handlerPartnership = false })
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.feature_disabled'), 'error'))
end)

t.test('requestPartnerUp: a non-number targetServerId is rejected before any eligibility check', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 'not-a-number')
    t.isTrue(notifiedExactly(f, 1, locale('partnership.invalid_target'), 'error'))
end)

t.test('requestPartnerUp: targeting yourself is invalid_target', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 1)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.invalid_target'), 'error'))
end)

t.test('requestPartnerUp: either party offline (GetPlayerPed == 0) is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'OFF1', { name = 'police' }) -- no setPed -> GetPlayerPed(1) == 0
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('common.target_no_longer_online'), 'error'))
end)

t.test('requestPartnerUp: an already-partnered INITIATOR is rejected by the cache pre-check', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    -- Seed OFF1 as already actively partnered with someone else entirely.
    f.mysql.single.await = function() return { k9_citizenid = 'SOMEONE-ELSE', handler_citizenid = 'OFF1' } end
    f.env.RefreshPartnershipCache('OFF1')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.reject_already_partnered'), 'error'))
end)

t.test('requestPartnerUp: an already-partnered TARGET is rejected by the cache pre-check', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.mysql.single.await = function() return { k9_citizenid = 'K91', handler_citizenid = 'SOMEONE-ELSE' } end
    f.env.RefreshPartnershipCache('K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.reject_already_partnered'), 'error'))
end)

t.test('requestPartnerUp: beyond Config.Partnership.ProximityMeters is too_far', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.setPed(2, 200, vec3(100, 0, 0), true) -- 100m away
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.too_far'), 'error'))
end)

t.test('requestPartnerUp: neither party is a K9 model is no_k9_party', function()
    local f = newFixture()
    f.registerPlayer(1, 'OFF1', { name = 'police' })
    f.registerPlayer(2, 'OFF2', { name = 'police' })
    f.setPed(1, 100, vec3(0, 0, 0), false)
    f.setPed(2, 200, vec3(0, 0, 0), false)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('common.no_k9_party'), 'error'))
end)

-- K9 ROLE/MODEL DECOUPLING WIDENING -- "I also want everything to work with
-- any ped". A role-holder standing on a non-K9 model (e.g. still in their
-- human/officer model) must still be accepted as the K9 party -- previously
-- this was unconditionally rejected as no_k9_party.
t.test('requestPartnerUp: K9 ROLE/MODEL DECOUPLING -- a role-holder on a non-K9 model is still accepted as the K9 party, not no_k9_party', function()
    local f = newFixture()
    f.registerPlayer(1, 'OFF1', { name = 'police' })
    f.registerPlayer(2, 'OFF2', nil)
    f.setPed(1, 100, vec3(0, 0, 0), false)
    f.setPed(2, 200, vec3(0, 0, 0), false) -- target (2) is on a human/officer model, NOT a configured K9 model
    f.setK9Role(2, true) -- but holds the decoupled K9 role
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.partner_request_sent'), 'inform'), 'a human-modeled role-holder must be accepted as the K9 party, not rejected as no_k9_party')
end)

t.test('requestPartnerUp: the K9-role party lacking HasK9Access is not_certified', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.setAccess(2, false)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('common.k9_not_certified'), 'error'))
end)

t.test('requestPartnerUp: the officer-role party not in any configured department is officer_not_in_department', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91', { job = 'taxi' })
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('common.handler_not_in_department'), 'error'))
end)

t.test('requestPartnerUp: the officer-role party needs mere department membership, NOT their own HasK9Access (asymmetric eligibility, mirrors leash)', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.setAccess(1, false) -- the OFFICER has no cert of their own -- must not matter
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.partner_request_sent'), 'inform'))
end)

t.test('requestPartnerUp: when BOTH are K9-modeled, the REQUEST TARGET defaults to the K9 role (tie-break, mirrors leash)', function()
    local f = newFixture()
    f.registerPlayer(1, 'K9-INITIATOR', { name = 'police' })
    f.registerPlayer(2, 'K9-TARGET', { name = 'police' })
    f.setPed(1, 100, vec3(0, 0, 0), true) -- both K9-modeled
    f.setPed(2, 200, vec3(0, 0, 0), true)
    f.setAccess(2, true) -- only the TARGET (the one that must resolve to k9Src) is certified
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.partner_request_sent'), 'inform'), 'if the INITIATOR had been picked as the K9 role instead, HasK9Access(1)==false would have rejected this as not_certified')
end)

-- ========================================================================
-- BOTH-ARE-K9 REJECTION (owner-reported gap, this pass): CheckPartnershipEligibility
-- previously only ever rejected "NEITHER party is a K9" -- when BOTH
-- genuinely hold the K9 role, the tie-break above used to silently cast
-- one of them as the handler instead of refusing outright, since a K9
-- role-holder is typically ALSO a department member and so trivially
-- clears officer_not_in_department too. See server/partnership.lua's own
-- "BOTH-ARE-K9 CASE" comment and IsGenuinelyK9Party's doc comment for the
-- full "role, not model, not HasK9Access" reasoning this section pins.
-- ========================================================================

t.test('requestPartnerUp: both parties genuinely holding the K9 role (HasK9Role) is rejected as both_k9, not silently assigning one of them the handler role', function()
    local f = newFixture()
    f.registerPlayer(1, 'REAL-K9-A', { name = 'police' })
    f.registerPlayer(2, 'REAL-K9-B', { name = 'police' })
    f.setPed(1, 100, vec3(0, 0, 0), false) -- neither is even on a K9 MODEL -- role alone must be enough to catch this
    f.setPed(2, 200, vec3(0, 0, 0), false)
    f.setK9Role(1, true)
    f.setK9Role(2, true)
    f.setAccess(1, true)
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    -- Dedicated locale key (see PARTNERSHIP_REJECT_MESSAGES's own comment
    -- on 'both_k9') -- this MUST NOT be reported as no_k9_party (the wrong
    -- diagnosis for this problem) and MUST NOT silently succeed (the bug
    -- itself).
    t.isTrue(notifiedExactly(f, 1, locale('common.both_k9'), 'error'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnerUpRequest'), 0, 'no consent prompt may ever be sent when both parties are genuinely K9s')
end)

t.test('requestPartnerUp: both on a CONFIGURED K9 MODEL but only ONE genuinely holds the K9 role still succeeds -- ped model alone must never trigger both_k9 (preserves "a handler can visually be on a dog model")', function()
    local f = newFixture()
    f.registerPlayer(1, 'MODEL-ONLY-HANDLER', { name = 'police' })
    f.registerPlayer(2, 'REAL-K9', { name = 'police' })
    f.setPed(1, 100, vec3(0, 0, 0), true) -- on the configured K9 model, but...
    f.setPed(2, 200, vec3(0, 0, 0), true)
    -- ...holds no K9 role/access at all -- an ordinary department officer
    -- who merely happens to be modeled as the configured K9 species.
    f.setAccess(2, true) -- only the actual K9 (2) is certified
    f.setK9Role(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.partner_request_sent'), 'inform'), 'a department officer merely modeled as a K9, holding no real K9 role, must still be able to become the handler for a real K9')
end)

t.test('requestPartnerUp: a HasK9Access bypass (e.g. High Command/autoAccessGrade) with no actual K9 role must not be misread as "genuinely a K9" for the both_k9 check', function()
    local f = newFixture()
    f.registerPlayer(1, 'BYPASS-OFFICER', { name = 'police' })
    f.registerPlayer(2, 'REAL-K9', { name = 'police' })
    f.setPed(1, 100, vec3(0, 0, 0), false)
    f.setPed(2, 200, vec3(0, 0, 0), false)
    f.setAccess(1, true) -- HasK9Access true (bypass) but no HasK9Role -- see IsGenuinelyK9Party's own doc comment for why HasK9Access alone is deliberately too WIDE a signal for this check
    f.setAccess(2, true)
    f.setK9Role(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.partner_request_sent'), 'inform'), 'HasK9Access alone must not count as "genuinely a K9" here, or a bypass-holding officer could never anchor a real K9 at all')
end)

-- ========================================================================
-- SAME-IDENTITY GUARD, BY CITIZENID (owner-directed, this pass): a server
-- id is a per-connection number, not a stable identity -- the citizenid is.
-- ========================================================================

t.test('requestPartnerUp: two different server ids that resolve to the SAME citizenid are rejected as invalid_target, not treated as two distinct parties', function()
    local f = newFixture()
    -- Simulates a stale pending request (or any other path) resolving
    -- against a NEW session for the same citizenid: two live server ids,
    -- one underlying person.
    f.registerPlayer(1, 'SAME-CID', { name = 'police' })
    f.registerPlayer(2, 'SAME-CID', { name = 'police' })
    f.setPed(1, 100, vec3(0, 0, 0), false)
    f.setPed(2, 200, vec3(0, 0, 0), true)
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.invalid_target'), 'error'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnerUpRequest'), 0)
end)

-- ========================================================================
-- requestPartnerUp: pending-request discipline (single slot per TARGET,
-- rate limit, TTL).
-- ========================================================================

t.test('requestPartnerUp: success sends the prompt to the target and acks the initiator', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:partnerUpRequest')
    t.isNotNil(ev)
    t.equals(ev.target, 2)
    t.equals(ev.args[1], 1)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.partner_request_sent'), 'inform'))
end)

t.test('requestPartnerUp: a second, DIFFERENT initiator targeting the SAME target while a live pending request exists is rejected outright, not silently overwritten', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.registerPlayer(3, 'OFF3', { name = 'police' })
    f.setPed(3, 300, vec3(0, 0, 0), false)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2) -- OFF1's request is pending against K91

    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 3, 2) -- OFF3 tries to target the same K91
    t.isTrue(notifiedExactly(f, 3, locale('partnership.pending_request_exists'), 'error'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnerUpRequest'), 1, 'K91 must never have seen a second prompt overwriting the first')
end)

t.test('requestPartnerUp: a rejected "pending already exists" attempt does NOT burn the rejected caller\'s own rate-limit cooldown', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.registerPlayer(3, 'OFF3', { name = 'police' })
    f.registerPlayer(4, 'K94', nil)
    f.setPed(3, 300, vec3(0, 0, 0), false)
    f.setPed(4, 400, vec3(0, 0, 0), true)
    f.setAccess(4, true)

    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2) -- occupies K91's pending slot
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 3, 2) -- OFF3 rejected: pending_request_exists

    -- Same instant -- if the rejection above had wrongly consumed OFF3's own
    -- cooldown, this legitimate, UNRELATED request would be silently
    -- swallowed instead of reaching the target.
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 3, 4)
    t.isTrue(notifiedExactly(f, 3, locale('partnership.partner_request_sent'), 'inform'))
end)

t.test('requestPartnerUp: a second immediate request from the same initiator (no other target contention) is silently rate-limited', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.registerPlayer(5, 'K95', nil)
    f.setPed(5, 500, vec3(0, 0, 0), true)
    f.setAccess(5, true)

    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    local countAfter = #f.notifyLog
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 5) -- different target -- but SAME initiator, same instant
    t.equals(#f.notifyLog, countAfter, 'the per-initiator rate limit must still apply even against a completely different target')
end)

t.test('requestPartnerUp: once the previous pending request\'s TTL has genuinely expired, a fresh request against the SAME target succeeds', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.registerPlayer(3, 'OFF3', { name = 'police' })
    f.setPed(3, 300, vec3(0, 0, 0), false)

    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    f.advance(REQUEST_TTL_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 3, 2)
    t.isTrue(notifiedExactly(f, 3, locale('partnership.partner_request_sent'), 'inform'), 'an expired pending entry must not block a fresh request against the same target')
end)

-- ========================================================================
-- respondPartnerUp: verified-match + TTL discipline BEFORE any notify
-- referencing the client-supplied fromServerId (SECURITY -- mirrors
-- server/main.lua's respondLeashAttach precedent, restated here for
-- server/partnership.lua's own copy of the same shape).
-- ========================================================================

t.test('respondPartnerUp: a non-number fromServerId is a silent no-op', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 'not-a-number', true)
    t.equals(#f.notifyLog, 0)
end)

t.test('respondPartnerUp: no pending request at all self-rejects, and does NOT notify the claimed fromServerId', function()
    local f = newFixture()
    f.registerPlayer(99, 'BYSTANDER', { name = 'police' })
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 99, true)
    t.isTrue(notifiedExactly(f, 2, locale('partnership.request_no_longer_valid_self'), 'error'))
    t.isNil(lastNotifyFor(f, 99), 'an unverified/spoofed fromServerId must never receive a notification of its own')
end)

t.test('SECURITY: a MISMATCHED fromServerId (the real pending exists, but from a DIFFERENT initiator) self-rejects only -- the impostor id is never notified, closing the arbitrary-target-notify class of bug', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.registerPlayer(77, 'IMPOSTOR', { name = 'police' })
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2) -- real pending: from = 1

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 77, true) -- K91 claims fromServerId = 77 (wrong)
    t.isTrue(notifiedExactly(f, 2, locale('partnership.request_no_longer_valid_self'), 'error'))
    t.isNil(lastNotifyFor(f, 77), 'the spoofed id must never be notified about a request it was never actually part of')

    -- DISCLOSED, OBSERVED BEHAVIOR (mirrors server/main.lua's identical,
    -- already-reviewed respondLeashAttach shape, not a new gap introduced
    -- here): the mismatched claim above ALSO consumes the real pending slot
    -- (`PendingPartnershipRequests[src] = nil` runs unconditionally on this
    -- branch, regardless of whether the claim matched) -- so the REAL
    -- initiator (1) is left with no way to have their original request
    -- accepted anymore, even though nothing was established with the
    -- impostor either. Self-limiting in the same sense the leash precedent
    -- describes: the only party who loses anything here is K91 (the target
    -- who mis-cited fromServerId), never a third party, and never a forged
    -- established partnership.
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 1, true) -- K91 tries again, this time with the TRUE original initiator
    t.isTrue(notifiedExactly(f, 2, locale('partnership.request_no_longer_valid_self'), 'error'), 'the real pending was already consumed by the earlier mismatched attempt -- OFF1 must now send a fresh request')
end)

t.test('respondPartnerUp: an expired (TTL) pending request is treated as gone -- both sides are told, and it is NOT established', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    f.advance(REQUEST_TTL_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 1, true)
    t.isTrue(notifiedExactly(f, 2, locale('partnership.request_no_longer_valid_self'), 'error'))
    t.isTrue(notifiedExactly(f, 1, locale('partnership.request_no_longer_valid_initiator'), 'error'), 'unlike a spoofed id, a VERIFIED-but-expired match must still tell the real initiator')
end)

t.test('respondPartnerUp: decline notifies the initiator and establishes nothing', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 1, false)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.request_declined'), 'inform'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEstablished'), 0)
end)

-- ========================================================================
-- MUST-MATTER: distance is RE-CHECKED at accept time, not just at request
-- time -- classic TOCTOU the file's own header calls out explicitly.
-- ========================================================================

t.test('respondPartnerUp: eligibility re-runs LIVE at accept time -- a party who moved far away after the request was sent is rejected, not established', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2) -- both at (0,0,0) -- passes

    f.setPed(2, 200, vec3(500, 0, 0), true) -- K91 wanders far away before responding
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 1, true)

    t.isTrue(notifiedExactly(f, 1, locale('partnership.too_far'), 'error'))
    t.isTrue(notifiedExactly(f, 2, locale('partnership.too_far'), 'error'))
    t.isFalse(insertCalled, 'a TOCTOU distance violation must never reach the INSERT')
end)

t.test('respondPartnerUp: eligibility re-run at accept time also re-checks HasK9Access, department membership, and the K9-model check -- not just distance', function()
    local f = newFixture()
    wirePair(f, 1, 'OFF1', 2, 'K91')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 1, 2)

    f.setAccess(2, false) -- K91's certification revoked between request and accept
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 2, 1, true)
    t.isTrue(notifiedExactly(f, 1, locale('common.k9_not_certified'), 'error'))
end)

-- ========================================================================
-- Successful establishment -- exact wiring.
-- ========================================================================

t.test('respondPartnerUp accept: full success -- INSERT fires with (k9, handler, established_by=initiator), cache reflects both roles immediately, both parties notified, outbound event fired', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-A', 20, 'K9-A')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 5 end
    -- Same call-counter technique certifications_spec.lua uses: the pre-INSERT
    -- scalar checks must see "nobody already partnered" (nil), and the
    -- POST-insert RefreshPartnershipCache single.await must see the row this
    -- INSERT just created.
    f.mysql.single.await = function() return { k9_citizenid = 'K9-A', handler_citizenid = 'OFF-A' } end

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    t.equals(insertParams[1], 'K9-A')
    t.equals(insertParams[2], 'OFF-A')
    t.equals(insertParams[3], 'OFF-A', 'established_by must be the INITIATOR (10, OFF-A) never the accepter')

    local k9Partner, k9IsK9 = f.env.GetActivePartnerCitizenId('K9-A')
    t.equals(k9Partner, 'OFF-A')
    t.isTrue(k9IsK9)
    local offPartner, offIsK9 = f.env.GetActivePartnerCitizenId('OFF-A')
    t.equals(offPartner, 'K9-A')
    t.isFalse(offIsK9)

    local establishedToK9 = lastClientEvent(f, 'qbx_k9unit:client:partnershipEstablished')
    t.isNotNil(establishedToK9)

    local sawK9Side, sawOfficerSide = false, false
    for _, e in ipairs(f.clientEvents) do
        if e.event == 'qbx_k9unit:client:partnershipEstablished' then
            if e.target == 20 then t.equals(e.args[1], 10); t.isTrue(e.args[2]); sawK9Side = true end
            if e.target == 10 then t.equals(e.args[1], 20); t.isFalse(e.args[2]); sawOfficerSide = true end
        end
    end
    t.isTrue(sawK9Side and sawOfficerSide)

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEstablished' and ev[2] == 'K9-A' and ev[3] == 'OFF-A' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('respondPartnerUp accept: when the INITIATOR is the K9-role party, established_by is still the initiator\'s own citizenid (not always the handler)', function()
    local f = newFixture()
    -- K9 (src 20) initiates to the officer (src 10) this time.
    wirePair(f, 10, 'OFF-B', 20, 'K9-B')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 20, 10)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 6 end
    f.mysql.single.await = function() return { k9_citizenid = 'K9-B', handler_citizenid = 'OFF-B' } end

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 10, 20, true)
    t.equals(insertParams[3], 'K9-B')
end)

t.test('a duplicate-key error thrown by the INSERT (DB backstop) is treated as already_partnered, not a hard error, and both caches are refreshed', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-C', 20, 'K9-C')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.insert.await = function() error({ errno = 1062, message = 'Duplicate entry' }) end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    t.isTrue(notifiedExactly(f, 10, locale('partnership.reject_already_partnered'), 'error'))
    t.isTrue(notifiedExactly(f, 20, locale('partnership.reject_already_partnered'), 'error'))
end)

-- ========================================================================
-- ITEM 1: pending-request leak on disconnect for BOTH parties -- server ids
-- are recycled; a new occupant of a freed id must inherit NOTHING.
-- ========================================================================

t.test('playerDropped (INITIATOR side): disconnecting the initiator clears the pending slot it occupies against its target', function()
    local f = newFixture()
    wirePair(f, 60, 'OFF-INIT', 61, 'K9-TARGET')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 60, 61) -- pending[61] = { from = 60 }

    f.disconnectPlayer(60)
    f.firePlayerDropped(60)

    -- The real target tries to accept, citing the (now-disconnected)
    -- original initiator -- must be cleanly rejected, no establishment.
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 61, 60, true)
    t.isTrue(notifiedExactly(f, 61, locale('partnership.request_no_longer_valid_self'), 'error'))
end)

t.test('playerDropped (INITIATOR side): a RECYCLED occupant of the freed initiator id inherits NOTHING -- a stray accept citing that id is safely rejected, not silently attributed to the new player', function()
    local f = newFixture()
    wirePair(f, 60, 'OFF-INIT', 61, 'K9-TARGET')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 60, 61)
    f.disconnectPlayer(60)
    f.firePlayerDropped(60)

    -- id 60 is now recycled to a BRAND NEW, unrelated connection.
    f.registerPlayer(60, 'BRAND-NEW-OCCUPANT', { name = 'sheriff' })
    f.setPed(60, 6099, vec3(0, 0, 0), false)

    -- Snapshot BEFORE the respond attempt: source 60 already legitimately
    -- received its own 'partner_request_sent' ack from the ORIGINAL,
    -- successful request above -- the claim under test is "no NEW
    -- notification reaches the recycled occupant", not "source 60 has never
    -- been notified of anything, ever".
    local notifyCountBefore = #f.notifyLog
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 61, 60, true)

    t.isTrue(notifiedExactly(f, 61, locale('partnership.request_no_longer_valid_self'), 'error'))
    local newNotifyToRecycledOccupant = false
    for i = notifyCountBefore + 1, #f.notifyLog do
        if f.notifyLog[i].source == 60 then newNotifyToRecycledOccupant = true end
    end
    t.isFalse(newNotifyToRecycledOccupant, 'the new occupant of id 60 must never be drawn into a request they never sent')
    t.isFalse(insertCalled, 'the recycled id must never let a stale request establish a partnership involving the wrong citizenid')
end)

t.test('playerDropped (INITIATOR side): disconnecting an initiator with MULTIPLE outstanding requests to DIFFERENT targets clears ALL of them, not just one', function()
    local f = newFixture()
    f.registerPlayer(70, 'OFF-MULTI', { name = 'police' })
    f.setPed(70, 7000, vec3(0, 0, 0), false)
    f.registerPlayer(71, 'K9-X', nil)
    f.setPed(71, 7100, vec3(0, 0, 0), true)
    f.setAccess(71, true)
    f.registerPlayer(72, 'K9-Y', nil)
    f.setPed(72, 7200, vec3(0, 0, 0), true)
    f.setAccess(72, true)

    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 70, 71)
    f.advance(REQUEST_COOLDOWN_MS + 1) -- clear the per-initiator cooldown so the SECOND request below isn't rejected by it
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 70, 72)

    f.disconnectPlayer(70)
    f.firePlayerDropped(70)

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 71, 70, true)
    t.isTrue(notifiedExactly(f, 71, locale('partnership.request_no_longer_valid_self'), 'error'))
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 72, 70, true)
    t.isTrue(notifiedExactly(f, 72, locale('partnership.request_no_longer_valid_self'), 'error'))
end)

t.test('playerDropped (TARGET side): disconnecting the target clears the pending slot addressed to it directly', function()
    local f = newFixture()
    wirePair(f, 80, 'OFF-T', 81, 'K9-T')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 80, 81)

    f.disconnectPlayer(81)
    f.firePlayerDropped(81)

    -- id 81 is recycled to a completely different-shaped occupant (an
    -- OFFICER this time, not a K9 at all) -- if anything had leaked, this
    -- occupant could never sensibly "accept" a K9-role request anyway; the
    -- sharpest proof is that a stray accept citing the ORIGINAL initiator
    -- is still safely rejected with nothing established.
    f.registerPlayer(81, 'RECYCLED-OFFICER', { name = 'sheriff' })
    f.setPed(81, 8199, vec3(0, 0, 0), false)

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 81, 80, true)

    t.isTrue(notifiedExactly(f, 81, locale('partnership.request_no_longer_valid_self'), 'error'))
    t.isFalse(insertCalled, 'the recycled target id must never inherit the original K9-role request')
end)

t.test('playerDropped (TARGET side): the original initiator can send a genuinely FRESH request to the recycled target id afterward, independent of any stale state', function()
    local f = newFixture()
    wirePair(f, 80, 'OFF-T', 81, 'K9-T')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 80, 81)
    f.disconnectPlayer(81)
    f.firePlayerDropped(81)

    f.registerPlayer(81, 'K9-NEW', nil)
    f.setPed(81, 8198, vec3(0, 0, 0), true)
    f.setAccess(81, true)

    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 80, 81)
    t.isTrue(notifiedExactly(f, 80, locale('partnership.partner_request_sent'), 'inform'), 'a fresh request to the recycled id must work exactly like any other first-time request')
end)

t.test('playerDropped: only the disconnecting citizenid\'s in-memory CACHE entry is dropped -- an established partnership row is NOT torn down, and the still-online partner keeps full access to it (documented divergence from leash)', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-D', 20, 'K9-D')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-D', handler_citizenid = 'OFF-D' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    t.isTrue(f.env.GetActivePartnerCitizenId('K9-D') ~= nil, 'sanity: really partnered first')

    -- Fire playerDropped WITHOUT first removing the K9 from the exportsStub
    -- lookup maps: this handler's own citizenid-cache-drop branch calls
    -- exports.qbx_core:GetPlayer(src) itself, expecting it to still resolve
    -- at the moment the event fires -- exactly the same assumption every
    -- other playerDropped-citizenid-resolving handler in this resource
    -- (server/certifications/'s own included) already relies on.
    -- disconnectPlayer() below (AFTER firing the event) is what represents
    -- "now genuinely gone", for the later RefreshPartnershipCache call.
    f.firePlayerDropped(20)
    f.disconnectPlayer(20)

    t.isNil((f.env.GetActivePartnerCitizenId('K9-D')), 'the DISCONNECTING citizenid\'s own in-memory cache entry is dropped immediately')

    -- The still-online handler's OWN cache entry is untouched by the K9's
    -- disconnect -- proving the DB row itself was never torn down (a fresh
    -- RefreshPartnershipCache for the K9 -- the cheap rebuild this file's
    -- header promises -- still finds the real, still-active row).
    local officerPartner = f.env.GetActivePartnerCitizenId('OFF-D')
    t.equals(officerPartner, 'K9-D')
    local rebuiltPartner = f.env.RefreshPartnershipCache('K9-D')
    t.equals(rebuiltPartner, 'OFF-D', 'a fresh DB read for the disconnected K9 must still find the real, still-active partnership row')
end)

-- ========================================================================
-- ITEM 2: double-accept fails closed.
-- ========================================================================

t.test('double-accept (sequential, after full completion): a second accept for the same (now-consumed) pending is rejected cleanly, no second INSERT, no duplicate establishment notice', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-E', 20, 'K9-E')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    local insertCount = 0
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end
    f.mysql.single.await = function() return { k9_citizenid = 'K9-E', handler_citizenid = 'OFF-E' } end

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true) -- succeeds
    t.equals(insertCount, 1)

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true) -- double-fire
    t.equals(insertCount, 1, 'a second accept after the pending was already consumed must never reach a second INSERT')
    t.isTrue(notifiedExactly(f, 20, locale('partnership.request_no_longer_valid_self'), 'error'))
end)

t.test('double-accept (RACING, interleaved mid-flight through a yielding MySQL stub): the second accept sees the pending already consumed and never reaches a query', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-F', 20, 'K9-F')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)

    local scalarCallCount, insertCount = 0, 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        coroutine.yield()
        return nil
    end
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end

    -- PendingPartnershipRequests[20] is cleared SYNCHRONOUSLY, before any
    -- yield, on the very first line of the verified-match branch -- so even
    -- a second call arriving while the first is still parked mid-flight
    -- must already see it gone.
    local co1 = f.startCoroutine('qbx_k9unit:server:respondPartnerUp', 20, { 10, true })
    co1.resume() -- runs synchronously up through pending-consumption + eligibility + TryAcquire, then yields inside the first MySQL.scalar.await
    t.isFalse(co1.isDead())

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true) -- the racing double-fire -- must complete in one shot, no yield of its own
    t.isTrue(notifiedExactly(f, 20, locale('partnership.request_no_longer_valid_self'), 'error'))
    t.equals(scalarCallCount, 1, 'the racing double-fire must never have reached MySQL at all -- the one call so far is attributable to co1 alone')

    while not co1.isDead() do co1.resume() end
    t.equals(insertCount, 1, 'exactly one INSERT despite the interleaved double-accept')
end)

-- ========================================================================
-- ITEM 4: PartnershipEstablishMutex around the already-partnered check +
-- the INSERT.
-- ========================================================================

t.test('MUTEX, LOAD-BEARING: two overlapping accepts for COMPLETELY UNRELATED pairs, interleaved through a yielding MySQL stub, serialize through the single global lock -- the second never reaches a query while the first holds it', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-A', 20, 'K9-A')
    wirePair(f, 30, 'OFF-B', 40, 'K9-B')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 30, 40)

    local scalarCallCount, insertCount = 0, 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        coroutine.yield()
        return nil -- nobody already partnered, in every call, for this test
    end
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end
    f.mysql.single.await = function(_sql, params)
        -- Used by the post-insert RefreshPartnershipCache re-query --
        -- distinguish pair A vs pair B by the citizenid parameter.
        local cid = params[1]
        if cid == 'K9-A' or cid == 'OFF-A' then return { k9_citizenid = 'K9-A', handler_citizenid = 'OFF-A' } end
        if cid == 'K9-B' or cid == 'OFF-B' then return { k9_citizenid = 'K9-B', handler_citizenid = 'OFF-B' } end
        return nil
    end

    -- A: K9-A (src 20) accepts, gets as far as its own FIRST yielding
    -- MySQL.scalar.await call -- at this point A already holds
    -- PartnershipEstablishMutex synchronously (TryAcquire happened before
    -- this yield), and is suspended.
    local coA = f.startCoroutine('qbx_k9unit:server:respondPartnerUp', 20, { 10, true })
    coA.resume()
    t.isFalse(coA.isDead())
    t.equals(scalarCallCount, 1)

    -- B: an entirely UNRELATED pair's K9-B (src 40) accepts. Its own
    -- eligibility check is independently fine (different citizenids
    -- entirely), so if the mutex were per-citizenid rather than a single
    -- global lock, this would proceed unimpeded. It is a SINGLE global
    -- lock (by design -- see PartnershipEstablishMutex's own doc comment),
    -- so B must be rejected at TryAcquire and complete in ONE resume,
    -- never touching MySQL at all.
    local coB = f.startCoroutine('qbx_k9unit:server:respondPartnerUp', 40, { 30, true })
    coB.resume()
    t.isTrue(coB.isDead(), 'B must run to completion in a single resume -- proving it never reached (and therefore never yielded at) a MySQL call')
    t.equals(scalarCallCount, 1, 'B must never have called MySQL.scalar.await at all')
    t.isTrue(notifiedExactly(f, 30, locale('partnership.setup_busy'), 'error'))
    t.isTrue(notifiedExactly(f, 40, locale('partnership.setup_busy'), 'error'))

    -- Drain A to completion.
    while not coA.isDead() do coA.resume() end
    t.equals(insertCount, 1, 'exactly one INSERT -- pair A\'s own')
    t.isTrue(countClientEvents(f, 'qbx_k9unit:client:partnershipEstablished') == 2, 'pair A must have genuinely established (both parties notified) despite pair B contending for the same global lock')
    local aPartner = f.env.GetActivePartnerCitizenId('K9-A')
    t.equals(aPartner, 'OFF-A')
end)

t.test('MUTEX, LOAD-BEARING: the lock RELEASES afterward -- pair B (rejected above with setup_busy) is NOT permanently blocked; a fresh request+accept for it succeeds once the lock is free', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-A', 20, 'K9-A')
    wirePair(f, 30, 'OFF-B', 40, 'K9-B')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 30, 40)

    f.mysql.scalar.await = function()
        coroutine.yield()
        return nil
    end
    local insertCount = 0
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end
    f.mysql.single.await = function(_sql, params)
        local cid = params[1]
        if cid == 'K9-A' or cid == 'OFF-A' then return { k9_citizenid = 'K9-A', handler_citizenid = 'OFF-A' } end
        if cid == 'K9-B' or cid == 'OFF-B' then return { k9_citizenid = 'K9-B', handler_citizenid = 'OFF-B' } end
        return nil
    end

    local coA = f.startCoroutine('qbx_k9unit:server:respondPartnerUp', 20, { 10, true })
    coA.resume() -- A holds the lock, suspended
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 40, 30, true) -- B: rejected, setup_busy (mutex held by A)
    t.isTrue(notifiedExactly(f, 40, locale('partnership.setup_busy'), 'error'))
    while not coA.isDead() do coA.resume() end -- A completes, releases the lock
    t.equals(insertCount, 1)

    -- B's OWN pending slot was already consumed by the rejected accept
    -- above (same "consumed either way" discipline as every other
    -- respondPartnerUp branch) -- a fresh round trip for the SAME pair must
    -- now succeed cleanly, proving the lock was not left permanently held.
    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 30, 40)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 40, 30, true)
    t.equals(insertCount, 2, 'pair B must be able to establish normally once the lock is free -- it must never be permanently denied by the earlier contention')
    t.equals(f.env.GetActivePartnerCitizenId('K9-B'), 'OFF-B')
end)

t.test('MUTEX, LOAD-BEARING: the lock RELEASES even when the critical section throws an unexpected error, so a thrown error can never permanently block ALL future establishments', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-G', 20, 'K9-G')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)

    local shouldThrow = true
    f.mysql.scalar.await = function()
        if shouldThrow then error('simulated connection drop mid-flight') end
        return nil
    end
    local insertCount = 0
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end
    f.mysql.single.await = function() return { k9_citizenid = 'K9-G', handler_citizenid = 'OFF-G' } end

    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true) -- errors inside the pcall-wrapped critical section
    t.isTrue(notifiedExactly(f, 10, locale('partnership.establish_error'), 'error'))
    t.isTrue(notifiedExactly(f, 20, locale('partnership.establish_error'), 'error'))
    t.equals(insertCount, 0)

    -- If the mutex had leaked (never released on the thrown-error path), a
    -- SECOND, entirely UNRELATED pair's establishment attempt would be
    -- rejected forever with setup_busy, never reaching MySQL at all --
    -- exactly the permanent-denial-of-the-whole-feature regression this
    -- test guards against.
    shouldThrow = false
    wirePair(f, 30, 'OFF-H', 40, 'K9-H')
    f.mysql.single.await = function() return { k9_citizenid = 'K9-H', handler_citizenid = 'OFF-H' } end
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 30, 40)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 40, 30, true)
    t.equals(insertCount, 1, 'a completely unrelated pair must be able to establish normally after the earlier thrown error -- proving the lock was genuinely released, not left held')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEstablished'), 2, 'the second pair must have genuinely established -- both parties get the partnershipEstablished client event')
end)

-- ========================================================================
-- ITEM 5: GetActivePartnerCitizenId / IsActivePartnerOf -- public
-- resource-global accessors; pin their exact contracts directly.
-- ========================================================================

t.test('GetActivePartnerCitizenId: an unknown/never-refreshed citizenid returns nil, nil', function()
    local f = newFixture()
    local partner, isK9 = f.env.GetActivePartnerCitizenId('NEVER-SEEN')
    t.isNil(partner)
    t.isNil(isK9)
end)

t.test('GetActivePartnerCitizenId: the K9-role party of an active partnership resolves the handler citizenid with isK9 == true', function()
    local f = newFixture()
    f.mysql.single.await = function() return { k9_citizenid = 'K9-CONTRACT', handler_citizenid = 'OFF-CONTRACT' } end
    f.env.RefreshPartnershipCache('K9-CONTRACT')
    local partner, isK9 = f.env.GetActivePartnerCitizenId('K9-CONTRACT')
    t.equals(partner, 'OFF-CONTRACT')
    t.isTrue(isK9)
end)

t.test('GetActivePartnerCitizenId: the handler-role party of the SAME active partnership resolves the K9 citizenid with isK9 == false', function()
    local f = newFixture()
    f.mysql.single.await = function() return { k9_citizenid = 'K9-CONTRACT', handler_citizenid = 'OFF-CONTRACT' } end
    f.env.RefreshPartnershipCache('OFF-CONTRACT')
    local partner, isK9 = f.env.GetActivePartnerCitizenId('OFF-CONTRACT')
    t.equals(partner, 'K9-CONTRACT')
    t.isFalse(isK9)
end)

t.test('GetActivePartnerCitizenId: fail-closed after a query error never leaves a stale/unknown cache entry readable as active', function()
    local f = newFixture()
    f.mysql.single.await = function() return { k9_citizenid = 'K9-FAIL', handler_citizenid = 'OFF-FAIL' } end
    f.env.RefreshPartnershipCache('K9-FAIL')
    t.isTrue(f.env.GetActivePartnerCitizenId('K9-FAIL') ~= nil, 'sanity: really partnered first')

    f.mysql.single.await = function() error('connection lost') end
    local returnedPartner = f.env.RefreshPartnershipCache('K9-FAIL')
    t.isNil(returnedPartner, 'the return value itself must report the fail-closed result')
    t.isNil((f.env.GetActivePartnerCitizenId('K9-FAIL')))
end)

t.test('IsActivePartnerOf: true only for the GENUINE current partner, false for an unrelated citizenid, false when not partnered at all', function()
    local f = newFixture()
    t.isFalse(f.env.IsActivePartnerOf('NEVER-SEEN', 'ANYONE'))

    f.mysql.single.await = function() return { k9_citizenid = 'K9-IAO', handler_citizenid = 'OFF-IAO' } end
    f.env.RefreshPartnershipCache('K9-IAO')
    t.isTrue(f.env.IsActivePartnerOf('K9-IAO', 'OFF-IAO'))
    t.isFalse(f.env.IsActivePartnerOf('K9-IAO', 'SOMEONE-ELSE'))
end)

t.test('RefreshPartnershipCache: type-guards its own input -- nil/empty-string citizenid is a defensive no-op returning nil, nil, never a crash', function()
    local f = newFixture()
    t.isNil((f.env.RefreshPartnershipCache(nil)))
    t.isNil((f.env.RefreshPartnershipCache('')))
end)

t.test('RefreshPartnershipCache: no active row at all (nil) clears any prior cache entry and returns nil, nil', function()
    local f = newFixture()
    f.mysql.single.await = function() return { k9_citizenid = 'K9-CLR', handler_citizenid = 'OFF-CLR' } end
    f.env.RefreshPartnershipCache('K9-CLR')
    t.isTrue(f.env.GetActivePartnerCitizenId('K9-CLR') ~= nil)

    f.mysql.single.await = function() return nil end
    local partner = f.env.RefreshPartnershipCache('K9-CLR')
    t.isNil(partner)
    t.isNil((f.env.GetActivePartnerCitizenId('K9-CLR')))
end)

-- ========================================================================
-- breakPartnership -- zero-consent teardown, either party, at any time.
-- ========================================================================

t.test('breakPartnership: an unpartnered caller is a distinguishable no-op, not an error', function()
    local f = newFixture()
    f.registerPlayer(1, 'LONE-CID', { name = 'police' })
    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 1)
    t.isTrue(notifiedExactly(f, 1, locale('partnership.not_partnered_with_anyone'), 'inform'))
end)

t.test('breakPartnership: a disconnected caller (unresolvable citizenid) is a silent no-op', function()
    local f = newFixture()
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 9999)
    t.isTrue(ok)
    t.equals(#f.notifyLog, 0)
end)

t.test('breakPartnership: full success -- both parties online -- UPDATE fires, both caches clear, BOTH clients told, outbound event fired with reason "broken"', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-BRK', 20, 'K9-BRK')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-BRK', handler_citizenid = 'OFF-BRK' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    t.isTrue(f.env.GetActivePartnerCitizenId('K9-BRK') ~= nil, 'sanity: really partnered first')

    -- The stub must reflect the UPDATE's own effect: DoBreakPartnership's
    -- own pre-UPDATE SELECT must still see the active row, but the TWO
    -- RefreshPartnershipCache calls that run AFTER the UPDATE (one per
    -- citizenid) must now see it as gone -- a static "always return the
    -- active row" stub would wrongly leave both caches still reporting
    -- active afterward, a fixture bug, not a real production one.
    local rowActive = true
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; rowActive = false; return 1 end
    f.mysql.single.await = function(_sql, _params)
        if not rowActive then return nil end
        return { id = 1, k9_citizenid = 'K9-BRK', handler_citizenid = 'OFF-BRK' }
    end

    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 10) -- the OFFICER initiates the break, zero consent needed

    t.equals(updateParams[1], 'OFF-BRK', 'ended_by must be the BREAKING party\'s own citizenid for a self-initiated break')
    t.equals(updateParams[2], 1)
    t.isNil((f.env.GetActivePartnerCitizenId('OFF-BRK')))
    t.isNil((f.env.GetActivePartnerCitizenId('K9-BRK')))

    local sawK9, sawOfficer = false, false
    for _, e in ipairs(f.clientEvents) do
        if e.event == 'qbx_k9unit:client:partnershipEnded' then
            if e.target == 20 then sawK9 = true; t.equals(e.args[1], 'broken') end
            if e.target == 10 then sawOfficer = true; t.equals(e.args[1], 'broken') end
        end
    end
    t.isTrue(sawK9 and sawOfficer)

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' and ev[2] == 'K9-BRK' and ev[3] == 'OFF-BRK' and ev[4] == 'broken' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('breakPartnership: only the currently-online party of the two is sent partnershipEnded -- the offline one is skipped, not erroring', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-OFFLN', 20, 'K9-OFFLN')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-OFFLN', handler_citizenid = 'OFF-OFFLN' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    f.disconnectPlayer(20) -- the K9 goes offline; the row itself remains active
    f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-OFFLN', handler_citizenid = 'OFF-OFFLN' } end
    f.mysql.update.await = function() return 1 end

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 10)
    t.isTrue(ok)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEnded'), 1, 'only the still-online officer can be told directly')
    local ev = lastClientEvent(f, 'qbx_k9unit:client:partnershipEnded')
    t.equals(ev.target, 10)
end)

t.test('breakPartnership: a thrown DB error is caught and reported, not a hard crash', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-ERR', 20, 'K9-ERR')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-ERR', handler_citizenid = 'OFF-ERR' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    f.mysql.single.await = function() error('connection lost') end
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 10)
    t.isTrue(ok)
    t.isTrue(notifiedExactly(f, 10, locale('partnership.break_error'), 'error'))
end)

-- ----------------------------------------------------------------------
-- REGRESSION (dependency-verification pass): oxmysql's `.await` funnels
-- every query through one shared `await(fn, query, parameters)` whose
-- callback does `if error then return p:reject(error) end`, and a
-- REJECTED promise raises via `error(promise.value, 2)` inside
-- `Citizen.Await` -- a real DB error THROWS out of a bare `.await` call,
-- it does not return nil. The test directly above already covers
-- DoBreakPartnership's SELECT throwing; the three cases below specifically
-- drive its UPDATE (the "half-succeeds" case this file's own doc comment
-- on DoBreakPartnership calls out: the SELECT worked, and now the ONLY
-- write throws) through a REAL, unmodified DoBreakPartnership, and assert
-- (1) the thrown error never propagates, (2) the caller is told something
-- sensible, and (3) neither the in-memory cache nor any broadcast ever
-- diverges from what the DB actually ended up persisting.
-- ----------------------------------------------------------------------

t.test('breakPartnership: REGRESSION -- a throwing UPDATE that genuinely never committed (reconciliation confirms still active) is caught, notifies break_error, and leaves the partnership COMPLETELY intact -- no partial state', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-UPD1', 20, 'K9-UPD1')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-UPD1', handler_citizenid = 'OFF-UPD1' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    t.isTrue(f.env.GetActivePartnerCitizenId('K9-UPD1') ~= nil, 'sanity: really partnered first')

    -- DoBreakPartnership's own pre-UPDATE SELECT still sees the real active
    -- row; the UPDATE itself throws.
    f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-UPD1', handler_citizenid = 'OFF-UPD1' } end
    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- The reconciliation read (MySQL.scalar.await, a DIFFERENT method from
    -- the SELECT above) confirms the row is STILL active (1).
    f.mysql.scalar.await = function() return 1 end

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 10)
    t.isTrue(ok, 'the event handler must never propagate a thrown DB error')

    t.isTrue(notifiedExactly(f, 10, locale('partnership.break_error'), 'error'), 'the caller must see a sensible error notification, not silence')
    t.equals(f.env.GetActivePartnerCitizenId('OFF-UPD1'), 'K9-UPD1', 'NO PARTIAL STATE: the cache must still report the real partnership active, matching the DB (the UPDATE never committed)')
    t.equals(f.env.GetActivePartnerCitizenId('K9-UPD1'), 'OFF-UPD1')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEnded'), 0, 'nobody must be told a partnership ended that never actually did')

    local endedFired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' then endedFired = true end
    end
    t.isFalse(endedFired, 'no outbound partnershipEnded event for a break that never actually happened')
end)

t.test('breakPartnership: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was -- caches and broadcasts match the confirmed DB truth, never left diverging', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-UPD2', 20, 'K9-UPD2')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-UPD2', handler_citizenid = 'OFF-UPD2' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    -- Same "the stub must reflect the UPDATE's own effect" technique as the
    -- full-success test above: DoBreakPartnership's own pre-UPDATE SELECT
    -- must still see the active row, but the reconciliation read AND the
    -- two post-reconciliation RefreshPartnershipCache calls must now see it
    -- as gone -- modeling the row having genuinely flipped in the DB
    -- despite the client-side error.
    local rowActive = true
    f.mysql.single.await = function(_sql, _params)
        if not rowActive then return nil end
        return { id = 1, k9_citizenid = 'K9-UPD2', handler_citizenid = 'OFF-UPD2' }
    end
    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    f.mysql.scalar.await = function() rowActive = false; return 0 end -- reconciliation: confirmed inactive

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 10)
    t.isTrue(ok, 'must not propagate: reconciled success must still return normally')

    t.isNil((f.env.GetActivePartnerCitizenId('OFF-UPD2')), 'the cache must reflect the CONFIRMED true outcome (ended), never the failed client-side call alone')
    t.isNil((f.env.GetActivePartnerCitizenId('K9-UPD2')))

    local sawK9, sawOfficer = false, false
    for _, e in ipairs(f.clientEvents) do
        if e.event == 'qbx_k9unit:client:partnershipEnded' then
            if e.target == 20 then sawK9 = true; t.equals(e.args[1], 'broken') end
            if e.target == 10 then sawOfficer = true; t.equals(e.args[1], 'broken') end
        end
    end
    t.isTrue(sawK9 and sawOfficer, 'both parties must be told the partnership genuinely ended, since it genuinely did')

    local endedFired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' and ev[2] == 'K9-UPD2' and ev[3] == 'OFF-UPD2' and ev[4] == 'broken' then endedFired = true end
    end
    t.isTrue(endedFired)
end)

t.test('breakPartnership: REGRESSION -- the reconciliation read ITSELF also failing (true outcome unknown) still degrades safely, never propagates, and never claims success it cannot confirm', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-UPD3', 20, 'K9-UPD3')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-UPD3', handler_citizenid = 'OFF-UPD3' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-UPD3', handler_citizenid = 'OFF-UPD3' } end
    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    f.mysql.scalar.await = function() error('simulated: DB still unreachable for the reconciliation read too') end

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 10)
    t.isTrue(ok, 'must not propagate even when BOTH the UPDATE and the reconciliation read throw')

    t.isTrue(notifiedExactly(f, 10, locale('partnership.break_error'), 'error'), 'an unconfirmable outcome must still notify an honest error, never silence')
    t.equals(f.env.GetActivePartnerCitizenId('OFF-UPD3'), 'K9-UPD3', 'an unconfirmed outcome must never flip the cache toward "ended" on a guess')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEnded'), 0)
end)

-- ========================================================================
-- ForceBreakPartnershipForCitizenId -- citizenid-keyed, OFFLINE-CAPABLE by
-- design (server/certifications/'s own call sites depend on this).
-- ========================================================================

t.test('ForceBreakPartnershipForCitizenId: works for a GENUINELY OFFLINE citizenid -- the DB row is torn down even with no live client to notify', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-FORCE', 20, 'K9-FORCE')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-FORCE', handler_citizenid = 'OFF-FORCE' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    f.disconnectPlayer(10)
    f.disconnectPlayer(20) -- BOTH now genuinely offline

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-FORCE', handler_citizenid = 'OFF-FORCE' } end

    local ended = f.env.ForceBreakPartnershipForCitizenId('K9-FORCE', 'certification_revoked')
    t.isTrue(ended)
    t.equals(updateParams[1], 'system:certification_revoked', 'ended_by must carry the system: sentinel, never the raw reason alone')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEnded'), 0, 'nobody is online to tell -- must not error trying')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' and ev[4] == 'certification_revoked' then fired = true end
    end
    t.isTrue(fired, 'the broadcastReason passed to the outbound event must be the UNPREFIXED reason, distinct from the DB\'s system:-prefixed ended_by')
end)

t.test('ForceBreakPartnershipForCitizenId: when a PERSON ended it (high command from the tablet), ended_by names that officer, not the system -- and the broadcast reason is unchanged', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-ACT', 20, 'K9-ACT')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-ACT', handler_citizenid = 'OFF-ACT' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-ACT', handler_citizenid = 'OFF-ACT' } end

    t.isTrue(f.env.ForceBreakPartnershipForCitizenId('K9-ACT', 'admin_forced_from_tablet', 'CHIEF-CID'))
    t.equals(updateParams[1], 'CHIEF-CID', 'the partnership history must say WHICH officer ended it')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' and ev[4] == 'admin_forced_from_tablet' then fired = true end
    end
    t.isTrue(fired, 'the reason both players are told stays the plain reason tag, whoever ended it')
end)

t.test('ForceBreakPartnershipForCitizenId: an empty or non-string actor falls back to the system sentinel -- never an empty ended_by', function()
    for _, actor in ipairs({ '', 42, false }) do
        local f = newFixture()
        wirePair(f, 10, 'OFF-EMP', 20, 'K9-EMP')
        f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
        f.mysql.single.await = function() return { k9_citizenid = 'K9-EMP', handler_citizenid = 'OFF-EMP' } end
        f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

        local updateParams
        f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
        f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-EMP', handler_citizenid = 'OFF-EMP' } end

        t.isTrue(f.env.ForceBreakPartnershipForCitizenId('K9-EMP', 'department_changed', actor))
        t.equals(updateParams[1], 'system:department_changed', 'actor ' .. tostring(actor) .. ' must not be written as ended_by')
    end
end)

t.test('ForceBreakPartnershipForCitizenId: a citizenid with no active partnership at all is a clean no-op returning false', function()
    local f = newFixture()
    t.isFalse(f.env.ForceBreakPartnershipForCitizenId('NEVER-PARTNERED', 'department_changed'))
end)

t.test('ForceBreakPartnershipForCitizenId: type-guards its own input -- non-string/empty citizenid returns false without touching the DB', function()
    local f = newFixture()
    local dbTouched = false
    f.mysql.single.await = function() dbTouched = true end
    t.isFalse(f.env.ForceBreakPartnershipForCitizenId(nil, 'x'))
    t.isFalse(f.env.ForceBreakPartnershipForCitizenId('', 'x'))
    t.isFalse(dbTouched)
end)

t.test('ForceBreakPartnershipForCitizenId: a thrown DB error is caught and returns false rather than propagating', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-FERR', 20, 'K9-FERR')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-FERR', handler_citizenid = 'OFF-FERR' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    f.mysql.single.await = function() error('boom') end
    local ok, ended = pcall(f.env.ForceBreakPartnershipForCitizenId, 'K9-FERR', 'x')
    t.isTrue(ok)
    t.isFalse(ended)
end)

t.test('ForceBreakPartnershipForCitizenId: REGRESSION -- a throwing UPDATE that never committed (reconciliation confirms still active) returns false without propagating, and leaves the partnership COMPLETELY intact -- no partial state', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-FU1', 20, 'K9-FU1')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-FU1', handler_citizenid = 'OFF-FU1' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    f.disconnectPlayer(10)
    f.disconnectPlayer(20) -- BOTH now genuinely offline -- this is the offline-capable call site

    f.mysql.single.await = function() return { id = 1, k9_citizenid = 'K9-FU1', handler_citizenid = 'OFF-FU1' } end
    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    f.mysql.scalar.await = function() return 1 end -- reconciliation: confirmed STILL active

    local ok, ended = pcall(f.env.ForceBreakPartnershipForCitizenId, 'K9-FU1', 'certification_revoked')
    t.isTrue(ok, 'must never propagate: ' .. tostring(ended))
    t.isFalse(ended, 'a genuinely failed break must report false, not a guessed true')
    t.equals(f.env.GetActivePartnerCitizenId('K9-FU1'), 'OFF-FU1', 'NO PARTIAL STATE: the cache must still reflect the real, still-active partnership')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:partnershipEnded'), 0, 'nobody is online to tell, and nothing actually ended either way')

    local endedFired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' then endedFired = true end
    end
    t.isFalse(endedFired, 'no outbound event for a break that never actually happened')
end)

t.test('ForceBreakPartnershipForCitizenId: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost) is confirmed via reconciliation and reported as the genuine success it was', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-FU2', 20, 'K9-FU2')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-FU2', handler_citizenid = 'OFF-FU2' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    f.disconnectPlayer(10)
    f.disconnectPlayer(20)

    local rowActive = true
    f.mysql.single.await = function(_sql, _params)
        if not rowActive then return nil end
        return { id = 1, k9_citizenid = 'K9-FU2', handler_citizenid = 'OFF-FU2' }
    end
    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    f.mysql.scalar.await = function() rowActive = false; return 0 end -- reconciliation: confirmed inactive

    local ok, ended = pcall(f.env.ForceBreakPartnershipForCitizenId, 'K9-FU2', 'certification_revoked')
    t.isTrue(ok, 'must not propagate: ' .. tostring(ended))
    t.isTrue(ended, 'the confirmed-genuine success must be reported as true, not a false negative from the client-side error alone')
    t.isNil((f.env.GetActivePartnerCitizenId('K9-FU2')), 'the cache must reflect the CONFIRMED true outcome (ended)')
    t.isNil((f.env.GetActivePartnerCitizenId('OFF-FU2')))

    local endedFired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:partnershipEnded' and ev[4] == 'certification_revoked' then endedFired = true end
    end
    t.isTrue(endedFired)
end)

-- ========================================================================
-- getPartnershipState callback -- server-authoritative, always a fresh read.
-- ========================================================================

t.test('getPartnershipState callback: unpartnered caller reports false, nil, nil', function()
    local f = newFixture()
    f.registerPlayer(1, 'LONE-CB', { name = 'police' })
    local isPartnered, partnerServerId, isK9 = f.callbacks['qbx_k9unit:server:getPartnershipState'](1)
    t.isFalse(isPartnered)
    t.isNil(partnerServerId)
    t.isNil(isK9)
end)

t.test('getPartnershipState callback: a genuinely partnered, online caller resolves the LIVE partner server id via a fresh DB read, not a stale local flag', function()
    local f = newFixture()
    wirePair(f, 10, 'OFF-CB', 20, 'K9-CB')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-CB', handler_citizenid = 'OFF-CB' } end
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local isPartnered, partnerServerId, isK9 = f.callbacks['qbx_k9unit:server:getPartnershipState'](20)
    t.isTrue(isPartnered)
    t.equals(partnerServerId, 10)
    t.isTrue(isK9)
end)

-- ========================================================================
-- onResourceStart backfill + QBCore:Server:PlayerLoaded -- structural gap
-- fill for a resource restart while players are already online.
-- ========================================================================

t.test('onResourceStart: with HandlerPartnership disabled, the backfill loop never touches MySQL at all (performance fix)', function()
    local f = newFixture({ handlerPartnership = false })
    f.registerPlayer(1, 'CID1', { name = 'police' })
    f.addOnline(1)
    local touched = false
    f.mysql.single.await = function() touched = true end
    f.fireResourceStart('qbx_k9unit')
    t.isFalse(touched)
end)

t.test('onResourceStart: with HandlerPartnership enabled, already-connected players\' partnership cache is backfilled from the DB', function()
    local f = newFixture()
    f.registerPlayer(1, 'CID-BACKFILL', { name = 'police' })
    f.addOnline(1)
    f.mysql.single.await = function() return { k9_citizenid = 'K9-BACKFILL', handler_citizenid = 'CID-BACKFILL' } end
    f.fireResourceStart('qbx_k9unit')
    t.equals(f.env.GetActivePartnerCitizenId('CID-BACKFILL'), 'K9-BACKFILL')
end)

t.test('onResourceStart: ignores a different resource restarting', function()
    local f = newFixture()
    f.registerPlayer(1, 'CID-OTHER', { name = 'police' })
    f.addOnline(1)
    local touched = false
    f.mysql.single.await = function() touched = true end
    f.fireResourceStart('some_other_resource')
    t.isFalse(touched)
end)

t.test('QBCore:Server:PlayerLoaded: refreshes that player\'s own partnership cache immediately on load', function()
    local f = newFixture()
    f.mysql.single.await = function() return { k9_citizenid = 'K9-PL', handler_citizenid = 'OFF-PL' } end
    f.firePlayerLoaded({ PlayerData = { citizenid = 'OFF-PL' } })
    t.equals(f.env.GetActivePartnerCitizenId('OFF-PL'), 'K9-PL')
end)

t.test('QBCore:Server:PlayerLoaded: tolerates a malformed Player object without erroring', function()
    local f = newFixture()
    local ok = pcall(f.firePlayerLoaded, nil)
    t.isTrue(ok)
    local ok2 = pcall(f.firePlayerLoaded, { PlayerData = nil })
    t.isTrue(ok2)
end)

-- ========================================================================
-- DEEPER PROGRESSION PASS (this pass, coder-backend) -- ANTI-FARM GUARD
-- EXTENSION: PairTenureSeed / CaptureTenureSeedForPair / the seed-CAS in
-- respondPartnerUp's establish critical section. See both functions' own
-- doc comments (this file) and PairTenureSeed's own header block for the
-- full "why" writeup.
--
-- MEMORY-MODE (Config.Database.enabled = false), DELIBERATELY, for the
-- establish-break-reform round trips below: this exercises the REAL
-- K9Store in-memory backend end to end (Partner_Insert/Partner_EndById/
-- Partner_GetTenureRow/Partner_SetTenureTierCAS, server/datastore.lua,
-- unmodified) rather than a hand-rolled MySQL stub having to correctly
-- distinguish four different SQL statement shapes across a multi-step
-- sequence -- both simpler to get right AND, per this task's own required
-- coverage list, a genuine test of "the DB being off".
-- ========================================================================

t.test('ANTI-FARM (Config.Database.enabled = false): breaking and immediately reforming with the SAME partner seeds the brand-new row from the highest tier that exact pair already earned -- an already-earned tenure milestone is never re-grantable by farming break+reform', function()
    local f = newFixture()
    f.config.Database = { enabled = false }
    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true

    wirePair(f, 10, 'OFF-ANTIFARM', 20, 'K9-ANTIFARM')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    -- Simulate server/tenure.lua's own tick having already paid out
    -- milestone tier 1 for this partnership (bypassing that file's tick --
    -- this suite is exercising server/partnership.lua's OWN anti-farm
    -- mechanism, not re-testing tenure.lua's grant logic, which
    -- tests/tenure_spec.lua already covers directly).
    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-ANTIFARM')
    t.isNotNil(firstRowId)
    local casApplied = f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 1, 0)
    t.equals(casApplied, 1, 'sanity: the simulated grant itself must apply')

    -- Break, then IMMEDIATELY reform the exact same pair -- the farming
    -- vector this guard exists to close.
    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 20)
    t.isNil(f.env.GetActivePartnerCitizenId('K9-ANTIFARM'), 'sanity: really broken')

    -- Clear the per-INITIATOR-source request cooldown before the SECOND
    -- requestPartnerUp below -- both rounds are sent by the SAME src (10),
    -- and PartnerRequestCooldown (1000ms, config.lua's own shipped default)
    -- would otherwise silently rate-limit this second request to a no-op:
    -- PendingPartnershipRequests[20] would never be (re)populated, and the
    -- respondPartnerUp dispatch immediately below would then self-reject as
    -- "no longer valid" BEFORE ever reaching the establish/seed logic this
    -- test exists to exercise -- exactly the trap that made this whole
    -- section fail for the wrong reason before this fix (see this section's
    -- own header comment).
    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local secondRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-ANTIFARM')
    t.isNotNil(secondRowId)
    t.isTrue(secondRowId ~= firstRowId, 'reforming must create a genuinely NEW row, never reactivate the old one (append-mostly audit-row schema)')

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-ANTIFARM')
    t.equals(tenureRow.tenure_bonus_tier_granted, 1, 'the brand-new row must already be seeded to tier 1 -- this exact pair already earned it once and must not be able to earn it again')
end)

t.test('ANTI-FARM (DB off): reforming the SAME K9 with a DIFFERENT handler does NOT inherit the old pair\'s seeded tier -- only the EXACT pair is protected, preserving server/tenure.lua\'s own documented "grab a different partner" reset design', function()
    local f = newFixture()
    f.config.Database = { enabled = false }
    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true

    wirePair(f, 10, 'OFF-DIFF-1', 20, 'K9-DIFF')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-DIFF')
    f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 1, 0)
    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 20)

    -- A genuinely DIFFERENT officer this time, at the same coords wirePair
    -- already placed the K9 at.
    f.registerPlayer(30, 'OFF-DIFF-2', { name = 'police' })
    f.setPed(30, 3000, vec3(0, 0, 0), false)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 30, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 30, true)

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-DIFF')
    t.equals(tenureRow.tenure_bonus_tier_granted, 0, 'a genuinely different pair starts completely fresh -- the seed is keyed on the EXACT (k9, handler) pair, never carried to an unrelated new partner')
end)

t.test('ANTI-FARM (DB off): a FORCED break (ForceBreakPartnershipForCitizenId -- the same entry point server/certifications/ calls on decertification AND job/department changes) captures the seed exactly like a self-initiated break', function()
    local f = newFixture()
    f.config.Database = { enabled = false }
    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true

    wirePair(f, 10, 'OFF-FORCED', 20, 'K9-FORCED')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-FORCED')
    t.isNotNil(firstRowId)
    t.equals(f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 2, 0), 1, 'sanity: the simulated grant itself must apply')

    local ended = f.env.ForceBreakPartnershipForCitizenId('K9-FORCED', 'department_changed')
    t.isTrue(ended)
    t.isNil(f.env.GetActivePartnerCitizenId('K9-FORCED'), 'sanity: really broken')

    -- Same per-INITIATOR-source cooldown as the self-break test above -- see
    -- that test's own comment for why this is required before a SECOND
    -- requestPartnerUp from the same src (10).
    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local secondRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-FORCED')
    t.isNotNil(secondRowId)
    t.isTrue(secondRowId ~= firstRowId, 'reforming must create a genuinely NEW row, never reactivate the old one')

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-FORCED')
    t.equals(tenureRow.tenure_bonus_tier_granted, 2, 'a job-change/decertification-forced break must be protected by the SAME guard as a self-initiated break -- both route through the same shared DoBreakPartnership core')
end)

t.test('ANTI-FARM (DB off): reconnecting (disconnect then reconnect) BETWEEN the break and the reform does not defeat the guard -- the seed is keyed by citizenid, never cleared on playerDropped', function()
    local f = newFixture()
    f.config.Database = { enabled = false }
    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true

    wirePair(f, 10, 'OFF-RECONNECT', 20, 'K9-RECONNECT')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-RECONNECT')
    t.isNotNil(firstRowId)
    t.equals(f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 1, 0), 1, 'sanity: the simulated grant itself must apply')
    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 20)
    t.isNil(f.env.GetActivePartnerCitizenId('K9-RECONNECT'), 'sanity: really broken')

    -- The K9-role party disconnects and reconnects (a NEW source id,
    -- mirroring how FiveM recycles/reassigns them) before reforming --
    -- server/partnership.lua's own header documents that ONLY the
    -- in-memory Partnerships CACHE entry is dropped on disconnect, never
    -- the underlying persisted state; this guard's own PairTenureSeed must
    -- behave identically (keyed on citizenid, never touched by
    -- playerDropped).
    f.disconnectPlayer(20)
    f.firePlayerDropped(20)
    f.registerPlayer(21, 'K9-RECONNECT', nil)
    f.setPed(21, 2100, vec3(0, 0, 0), true)
    f.setAccess(21, true)

    -- The OFFICER side (src 10) is the one re-sending requestPartnerUp here
    -- -- same per-INITIATOR-source cooldown as the self-break test above
    -- applies even though the K9's own source id changed.
    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 21)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 21, 10, true)

    local secondRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-RECONNECT')
    t.isNotNil(secondRowId)
    t.isTrue(secondRowId ~= firstRowId, 'reforming must create a genuinely NEW row, never reactivate the old one')

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-RECONNECT')
    t.equals(tenureRow.tenure_bonus_tier_granted, 1, 'a disconnect/reconnect between break and reform must not reset or bypass the anti-farm seed')
end)

t.test('ANTI-FARM: seed capture is a complete no-op (and never errors) when Config.Features.PartnershipTenureBonus is off -- the resource-wide default -- so a pair may re-earn a milestone ONCE if the feature is only turned on LATER, between the break and the reform (a disclosed, narrow, accepted gap, not a silent double-grant against a server that had the feature on throughout)', function()
    local f = newFixture()
    f.config.Database = { enabled = false } -- Features.XPProgression / PartnershipTenureBonus left unset (falsy) at break time

    wirePair(f, 10, 'OFF-NOOP', 20, 'K9-NOOP')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-NOOP')
    t.isNotNil(firstRowId)
    t.equals(f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 1, 0), 1, 'sanity: the simulated grant itself must apply')

    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:breakPartnership', 20)
    t.isTrue(ok, 'breaking must never error just because the tenure-bonus feature happens to be off')
    t.isNil(f.env.GetActivePartnerCitizenId('K9-NOOP'), 'sanity: really broken')

    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true
    -- Same per-INITIATOR-source cooldown as the self-break test above.
    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local secondRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-NOOP')
    t.isNotNil(secondRowId, 'sanity: the reform (feature now on) must actually establish')
    t.isTrue(secondRowId ~= firstRowId, 'reforming must create a genuinely NEW row, never reactivate the old one')

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-NOOP')
    t.equals(tenureRow.tenure_bonus_tier_granted, 0, 'the feature was OFF at break time, so nothing was captured to seed from -- this is the disclosed narrow gap, not the failure this guard closes')
end)

t.test('ANTI-FARM: every write is checked -- a THROWING seed-CAS during reform is logged and does NOT abort/crash establishment; the new partnership still forms, with its own default (unseeded) tier', function()
    local f = newFixture()
    f.config.Database = { enabled = false }
    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true

    wirePair(f, 10, 'OFF-WFAIL', 20, 'K9-WFAIL')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-WFAIL')
    t.isNotNil(firstRowId)
    t.equals(f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 1, 0), 1, 'sanity: the simulated grant itself must apply')

    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 20)
    t.isNil(f.env.GetActivePartnerCitizenId('K9-WFAIL'), 'sanity: really broken')

    -- Every K9Store.Partner_SetTenureTierCAS call the PRODUCTION code makes
    -- from here on must throw -- simulating a DB error on exactly the write
    -- this task's own brief requires be checked. Monkey-patching the real
    -- in-memory K9Store function directly (rather than hand-rolling a
    -- stateful MySQL.single.await stub that has to separately track "active
    -- before the break, gone after it" across four different SQL statement
    -- shapes -- the earlier version of this test used exactly that shape
    -- and could never actually reach this seed-CAS path, because
    -- DoBreakPartnership's own post-UPDATE RefreshPartnershipCache call
    -- re-read through the SAME stub and saw a still-truthy row regardless of
    -- the real WHERE clause, so the reform below was refused as
    -- already_partnered before ever reaching establishment) is what
    -- actually exercises this path. K9Store is a resource-global table
    -- (server/datastore.lua: `K9Store = {}`, no `local`), so reassigning
    -- this field is visible to server/partnership.lua's own
    -- `K9Store.Partner_SetTenureTierCAS(...)` call inside respondPartnerUp
    -- -- Lua re-indexes the table on every call, there is nothing cached to
    -- go stale.
    f.env.K9Store.Partner_SetTenureTierCAS = function()
        error('simulated DB error on the seed CAS UPDATE')
    end

    -- Same per-INITIATOR-source (10) request cooldown as the memory-mode
    -- ANTI-FARM tests above -- required before this SECOND requestPartnerUp
    -- from the same src, or it silently no-ops and respondPartnerUp below
    -- self-rejects as "no longer valid" before ever reaching the seed-CAS
    -- logic this test exists to exercise.
    f.advance(REQUEST_COOLDOWN_MS + 1)
    local ok1 = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:requestPartnerUp', 10, 20)
    t.isTrue(ok1)
    local ok2 = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    t.isTrue(ok2, 'a thrown seed-CAS must never abort/crash the establish flow')

    local secondRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-WFAIL')
    t.isNotNil(secondRowId, 'the new partnership must still be established despite the seed-write failure')
    t.isTrue(secondRowId ~= firstRowId, 'reforming must create a genuinely NEW row, never reactivate the old one')

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-WFAIL')
    t.equals(tenureRow.tenure_bonus_tier_granted, 0, 'the seed-write threw, so the new row must keep its true default -- fail SAFE, never fail open toward an extra grant')

    local sawLoggedFailure = false
    for _, line in ipairs(f.printLog) do
        if line:find('tenure anti-farm seed CAS threw', 1, true) then sawLoggedFailure = true end
    end
    t.isTrue(sawLoggedFailure, 'a thrown seed-write must be logged, never silently swallowed')
end)

t.test('ANTI-FARM: every write is checked -- a seed-CAS that reports ZERO affected rows (lost race, or a pre-migration schema missing the column) is logged and does NOT abort establishment either', function()
    local f = newFixture()
    f.config.Database = { enabled = false }
    f.config.Features.XPProgression = true
    f.config.Features.PartnershipTenureBonus = true

    wirePair(f, 10, 'OFF-WFAIL2', 20, 'K9-WFAIL2')
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    f.dispatchNetEvent('qbx_k9unit:server:respondPartnerUp', 20, 10, true)

    local firstRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-WFAIL2')
    t.isNotNil(firstRowId)
    t.equals(f.env.K9Store.Partner_SetTenureTierCAS(firstRowId, 1, 0), 1, 'sanity: the simulated grant itself must apply')

    f.dispatchNetEvent('qbx_k9unit:server:breakPartnership', 20)
    t.isNil(f.env.GetActivePartnerCitizenId('K9-WFAIL2'), 'sanity: really broken')

    -- See the THROWING-CAS test immediately above for why this reassigns
    -- K9Store.Partner_SetTenureTierCAS directly rather than a raw-SQL MySQL
    -- stub -- this variant reports a clean "0 rows affected" (a lost race /
    -- pre-migration schema) instead of throwing.
    f.env.K9Store.Partner_SetTenureTierCAS = function() return 0 end

    -- Same per-INITIATOR-source cooldown as the test immediately above.
    f.advance(REQUEST_COOLDOWN_MS + 1)
    f.dispatchNetEvent('qbx_k9unit:server:requestPartnerUp', 10, 20)
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:respondPartnerUp', 20, 10, true)
    t.isTrue(ok)

    local secondRowId = f.env.K9Store.Partner_GetActiveIdByParty('K9-WFAIL2')
    t.isNotNil(secondRowId, 'the new partnership must still be established despite the seed-write applying zero rows')
    t.isTrue(secondRowId ~= firstRowId, 'reforming must create a genuinely NEW row, never reactivate the old one')

    local tenureRow = f.env.K9Store.Partner_GetTenureRow('K9-WFAIL2')
    t.equals(tenureRow.tenure_bonus_tier_granted, 0, 'the seed-write applied zero rows, so the new row must keep its true default')

    local sawLoggedFailure = false
    for _, line in ipairs(f.printLog) do
        if line:find('tenure anti-farm seed CAS did not apply', 1, true) then sawLoggedFailure = true end
    end
    t.isTrue(sawLoggedFailure, 'a seed-CAS reporting zero affected rows must be logged, never silently ignored')
end)

os.exit(t.summary())
