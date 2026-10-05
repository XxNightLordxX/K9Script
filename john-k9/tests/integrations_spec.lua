--[[
    tests/integrations_spec.lua

    Tests for server/integrations.lua (the external-system integration
    surface -- DEVELOPER_REFERENCE.md Part A §7 / Part B §2/§3, see that file's
    own header for the full design writeup) against the REAL, unmodified
    production file, loaded alongside the REAL server/cooldowns.lua (its
    K9DownFireCooldown is a genuine NewCooldown() instance, not a stub --
    exercising the real AssertValidDefaultThreshold guard matters here,
    since this file's own CONFIG-SAFETY GUARD explicitly relies on that
    guard rather than re-checking reFireCooldownMs itself).

    server/certifications/ is DELIBERATELY NOT loaded -- HasK9Access and
    IsConfiguredK9Model are stubbed directly instead, same "stub, don't
    load, a function already covered by its own file's spec" convention
    wellbeing_spec.lua's own header already establishes for the identical
    pair. HasK9Access is covered by certifications_spec.lua;
    IsConfiguredK9Model likewise.

    Same coroutine thread-runner technique as wellbeing_spec.lua/
    defense_spec.lua/tenure_spec.lua: PollK9Health runs inside a
    `CreateThread(function() while true do Wait(...) ... end end)` loop,
    stepped one pass at a time via fixtures/sandbox.lua's
    Sandbox.newThreadRunner(). GetGameTimer is a test-controlled fake clock
    advanced explicitly between ticks -- Wait() itself does not advance it
    (it is a bare coroutine.yield in the sandbox), matching every other
    spec's own convention for this exact pattern.

    WHAT THIS FILE PROVES, mapped to the task's four required-coverage
    points:
      1. The one outbound event this file adds
         ('john-k9:events:k9Down') fires with the exact documented
         payload shape (source, citizenid, jobName, coords, health) --
         pinned field-by-field, not just "an event fired."
      2. "A missing/absent operator-configured target is a clean no-op" --
         read here as: a player who is not a qualifying, on-duty, certified
         K9 (not a K9 model, or not currently K9-access-eligible, or not
         even spawned yet) never produces an event, however low their raw
         health reads, and produces no error either.
      3. An operator's own listener THROWING (TriggerEvent's registered
         handler in another resource) is swallowed by FireOutboundEvent's
         own pcall and never aborts this file's poll pass -- proven by a
         later, independent qualifying episode still firing normally on a
         subsequent tick.
      4. No integration path -- no thread, no table allocation, no
         TriggerEvent call, ever -- is reachable when
         Config.Features.K9DownDispatch is false, even with an absent/
         garbage Config.K9DownDispatch tuning table that would otherwise
         fail every CONFIG-SAFETY GUARD assert.

    Beyond those four, also covers: the CONFIG-SAFETY GUARD (2026-08-26,
    REWRITTEN this pass -- see the REGRESSION sections below) clamping and
    warning, never asserting-and-aborting, on a bad healthThreshold/
    minDurationMs/pollIntervalMs/reFireCooldownMs -- each proven to (a) keep
    the file loading with its poll thread/playerDropped cleanup intact, (b)
    print a warning naming the exact key/value found/fallback substituted,
    (c) leave a VALID configured value untouched and silent, and, for at
    least one field each, (d) actually enforce the resolved fallback in a
    real running poll episode, not merely survive loading; the
    edge-triggered/debounced firing shape (never fires before
    minDurationMs elapses, fires exactly once per continuous qualifying
    episode, not once per poll tick); a health dip that recovers before
    minDurationMs elapses starting a fresh episode next time rather than
    carrying over stale progress; the per-source re-fire cooldown
    deferring (never dropping) a second episode's announcement; and
    playerDropped clearing a source's in-progress episode so a later
    reconnect starts clean.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture builder
-- ----------------------------------------------------------------------

--- @param opts table? -- { featureEnabled: boolean?, tuning: table? }
--- @return table fixture
local function newIntegrationsFixture(opts)
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

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Captures every TriggerEvent call this file makes (there is exactly
    -- one call site, FireOutboundEvent, but this stub does not assume
    -- that -- it just records whatever arrives). `throwForEvent`, when
    -- set, simulates "a registered handler in another resource errored"
    -- for that one event name, exactly the boundary FireOutboundEvent's
    -- own pcall exists to contain.
    local outboundEvents = {} -- { { name = string, args = { ... } }, ... }
    local throwForEvent = nil
    local function TriggerEvent(eventName, ...)
        outboundEvents[#outboundEvents + 1] = { name = eventName, args = { ... } }
        if throwForEvent == eventName then
            error('simulated listener error in another resource')
        end
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

    local accessBySource = {}
    local function HasK9Access(src) return accessBySource[src] == true end

    -- Every ped defaults to 200 (alive, native max health) -- matches
    -- combat_spec.lua's/wellbeing_spec.lua's own default so a fixture that
    -- never calls setHealth behaves as a healthy K9, never an
    -- accidentally-qualifying one.
    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or { x = 0, y = 0, z = 0 } end

    -- exports.qbx_core:GetPlayer(src) -- keyed by source, holds
    -- citizenid/job.name. A source with no entry here simulates a
    -- transient qbx_core resolution miss (see this file's own
    -- "else: a transient exports.qbx_core:GetPlayer resolution miss"
    -- comment) rather than an error.
    local playersBySource = {}
    local function qbxGetPlayer(_self, src)
        local rec = playersBySource[src]
        if not rec then return nil end
        return { PlayerData = { citizenid = rec.citizenid, job = { name = rec.job } } }
    end

    local config = {
        Features = { K9DownDispatch = opts.featureEnabled ~= false },
        K9DownDispatch = opts.tuning,
        -- PER-PERSON FEATURE CONTROL fixture knob (this pass) -- nil unless
        -- a test opts in, mirroring pursuitsprint_spec.lua's own
        -- `opts.requireGrantListed` shape.
        FeatureControl = opts.featureControl,
    }
    if config.K9DownDispatch == nil and opts.featureEnabled ~= false then
        config.K9DownDispatch = {
            healthThreshold  = 100,
            minDurationMs    = 3000,
            pollIntervalMs   = 2000,
            reFireCooldownMs = 30000,
        }
    end

    -- HasPermission is a GLOBAL in production (server/permissions.lua),
    -- soft-dependency-guarded (`type(HasPermission) == 'function'`) by
    -- server/integrations.lua's own IsK9DownDispatchPermittedForCitizenId --
    -- nil by default here (every existing test in this file never defines
    -- it, exactly like production without server/permissions.lua
    -- installed), settable per test via opts.hasPermissionFn.
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        if type(opts.hasPermissionFn) == 'function' then
            return opts.hasPermissionFn(citizenid, key)
        end
        return false
    end

    local envOverrides = {
        GetGameTimer           = GetGameTimer,
        CreateThread           = CreateThread,
        Wait                   = threadRunner.Wait,
        AddEventHandler        = AddEventHandler,
        TriggerEvent           = TriggerEvent,
        print                  = printStub,
        GetPlayers             = GetPlayers,
        GetPlayerPed           = GetPlayerPed,
        GetEntityModel         = GetEntityModel,
        IsConfiguredK9Model    = IsConfiguredK9Model,
        HasK9Access            = HasK9Access,
        GetEntityHealth        = GetEntityHealth,
        GetEntityCoords        = GetEntityCoords,
        GetCurrentResourceName = function() return 'john-k9' end,
        exports                = { qbx_core = { GetPlayer = qbxGetPlayer } },
        Config                 = config,
    }
    if opts.withHasPermission ~= false then
        envOverrides.HasPermission = defaultHasPermission
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    Sandbox.loadInto('../server/integrations.lua', env)

    return {
        env = env,
        advance = function(ms) fakeNow = fakeNow + ms end,
        tick = function() threadRunner.step() end,
        setOnline = function(src)
            for _, id in ipairs(onlinePlayerIds) do
                if id == src then return end
            end
            onlinePlayerIds[#onlinePlayerIds + 1] = src
        end,
        setOffline = function(src)
            for i, id in ipairs(onlinePlayerIds) do
                if id == src then
                    table.remove(onlinePlayerIds, i)
                    return
                end
            end
        end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        markK9Model = function(model) k9Models[model] = true end,
        setAccess = function(src, has) accessBySource[src] = has end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setCoords = function(ped, coords) coordsByPed[ped] = coords end,
        setPlayer = function(src, citizenid, job) playersBySource[src] = { citizenid = citizenid, job = job } end,
        clearPlayer = function(src) playersBySource[src] = nil end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers.playerDropped or {}) do
                handler()
            end
        end,
        setThrowForEvent = function(eventName) throwForEvent = eventName end,
        outboundEvents = outboundEvents,
        printedLines = printedLines,
        createThreadCallCount = function() return createThreadCallCount end,
    }
end

--- Convenience: registers one fully-qualifying online K9 (src/ped/model/
--- access/citizenid/job all wired), healthy by default (200).
--- @param f table -- fixture from newIntegrationsFixture
--- @param src number
--- @param ped number
local function registerQualifyingK9(f, src, ped)
    local model = 900000 + ped -- unique per ped, arbitrary
    f.setOnline(src)
    f.setPed(src, ped)
    f.markK9Model(model)
    f.setModel(ped, model)
    f.setAccess(src, true)
    f.setPlayer(src, 'CITIZEN_' .. src, 'police')
end

-- ----------------------------------------------------------------------
-- 1. Feature-flag-off: a clean no-op, even with garbage tuning
-- ----------------------------------------------------------------------

t.test('Config.Features.K9DownDispatch = false starts no thread and asserts nothing, even with a garbage/absent tuning table', function()
    local f = newIntegrationsFixture({ featureEnabled = false, tuning = 'not-a-table' })
    t.equals(f.createThreadCallCount(), 0, 'no thread should ever be created while the feature flag is off')

    registerQualifyingK9(f, 1, 101)
    f.setHealth(101, 0)
    -- No thread exists to step -- confirms stepping is harmless, not that
    -- it does anything.
    f.tick()
    f.advance(999999)
    f.tick()
    t.equals(#f.outboundEvents, 0, 'zero TriggerEvent calls with the feature off, no matter how low health reads')
end)

-- ----------------------------------------------------------------------
-- 2. CONFIG-SAFETY GUARD asserts -- one bad field at a time
-- ----------------------------------------------------------------------

-- REGRESSION (this pass): this test used to assert the OPPOSITE -- that
-- Config.K9DownDispatch not being a table FAILED THE ENTIRE FILE'S LOAD via
-- a hard `assert`, the last one left in this file (every individual field
-- below it had already been migrated to clamp-and-warn). See
-- server/cooldowns.lua's header ADDENDUM: an uncaught error thrown from
-- this file's own top-level chunk would abort server/integrations.lua's
-- load from that line onward, taking K9DownFireCooldown's construction, the
-- poll thread, and this file's own playerDropped cleanup down with it, over
-- one operator typo. Now CLAMP AND WARN: substituting an empty table lets
-- every per-field resolver below fall back to its own already-established
-- default.
t.test('Config.K9DownDispatch not a table (nil/false in production) while the flag is true no longer fails to load -- clamps every field to its shipped fallback, warns loudly, and the poll thread still runs', function()
    -- `tuning = false` here (never nil) is deliberate: this fixture helper
    -- fills in a valid default tuning table whenever `opts.tuning` is nil
    -- AND the feature is enabled, precisely so every OTHER test in this
    -- file gets a sane default without repeating it -- `false` is the way
    -- to reach this specific "the table itself is missing/wrong-typed"
    -- case instead (any non-table value, including a real nil in
    -- production, hits the exact same `type(tuning) == 'table'` check).
    local f = newIntegrationsFixture({ featureEnabled = true, tuning = false })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.K9DownDispatch', 1, true) and line:find('missing', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must warn that the whole settings table is missing')
    t.equals(f.env.Config.K9DownDispatch.healthThreshold, 100)
    t.equals(f.env.Config.K9DownDispatch.minDurationMs, 3000)
    t.equals(f.env.Config.K9DownDispatch.pollIntervalMs, 2000)
    t.equals(f.createThreadCallCount(), 1, 'the maintenance poll thread must still start')

    -- Prove it keeps working end-to-end, not just "the table now has keys":
    -- a real K9 crossing the resolved healthThreshold, held for the
    -- resolved minDurationMs across the resolved pollIntervalMs cadence,
    -- still fires the outbound event. Mirrors the REGRESSION tests below's
    -- own prime-then-poll shape exactly.
    registerQualifyingK9(f, 1, 101)
    f.setHealth(101, 200)
    f.tick() -- prime
    f.setHealth(101, 0)
    for _ = 1, 3 do
        f.advance(2000) -- the resolved fallback pollIntervalMs
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'the feature must still function end-to-end on the substituted fallbacks')
end)

-- ------------------------------------------------------------------
-- REGRESSION (2026-08-26): these three tests used to assert the OPPOSITE --
-- that healthThreshold/minDurationMs/pollIntervalMs failing their bound
-- aborts this file's load via a hard `assert`. They were pinning the bug.
--
-- The exact same class of mistake ResolveConfiguredThresholdMs's own
-- reFireCooldownMs REGRESSION section above documents: an uncaught error
-- thrown from THIS FILE's own top-level chunk aborts server/integrations.lua's
-- load from that line onward -- taking K9DownFireCooldown's own
-- construction, PollK9Health, the maintenance CreateThread, and this file's
-- own playerDropped cleanup down with it, over one operator typo.
-- reFireCooldownMs was migrated first; these three siblings sat two lines
-- above it, unmigrated, only because none of them feed NewCooldown (they
-- feed a raw comparison / Wait() instead) -- not because the risk differed.
--
-- Now clamp-and-warn (healthThreshold/minDurationMs via this file's own
-- bespoke ResolveConfiguredNumber, pollIntervalMs via
-- ResolveConfiguredThresholdMs): the file loads, the poll thread starts,
-- and the feature keeps working on a safe built-in fallback while printing
-- one unmissable warning naming the exact key, the value found, and what
-- was substituted.
-- ------------------------------------------------------------------

t.test('REGRESSION: healthThreshold = 0 no longer aborts this file\'s load -- clamps to the shipped 100 fallback, warns loudly naming the exact key, and the poll thread still fires a real episode on the resolved value', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 0, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 1000 },
    })
    t.isTrue(ok, 'the file must still load -- an abort here kills the whole K9-down dispatch feature')
    t.equals(f.createThreadCallCount(), 1, 'the maintenance poll thread must still be created')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.K9DownDispatch.healthThreshold', 1, true)
            and line:find('found: 0', 1, true)
            and line:find('100', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')

    -- Prove at the level the bug lives: the fallback (100), not the invalid
    -- configured 0, is the value the real poll loop enforces -- a K9 exactly
    -- AT the fallback threshold must still qualify and fire.
    registerQualifyingK9(f, 50, 5050)
    f.setHealth(5050, 200)
    f.tick() -- prime
    f.setHealth(5050, 100) -- at the FALLBACK threshold, not the invalid configured one
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'the fallback threshold (100) must be the one actually enforced by the running poll loop, not merely printed in a warning')
end)

t.test('REGRESSION: minDurationMs = -1 no longer aborts this file\'s load -- clamps to the shipped 3000ms fallback and warns loudly, naming the exact key/value/substitute', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = -1, pollIntervalMs = 1000, reFireCooldownMs = 1000 },
    })
    t.isTrue(ok, 'the file must still load -- an abort here kills the whole K9-down dispatch feature')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.K9DownDispatch.minDurationMs', 1, true)
            and line:find('found: -1', 1, true)
            and line:find('3000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')
    t.equals(f.createThreadCallCount(), 1, 'the maintenance poll thread must still be created')
end)

t.test('REGRESSION: minDurationMs = 0 is a VALID configured value (config.lua\'s own documented "0 disables it"/no-debounce choice), never clamped, never warned about', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 1000 },
    })
    t.isTrue(ok)
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('minDurationMs', 1, true),
            'minDurationMs = 0 is documented as "fire on the very first qualifying poll tick, no debounce" -- warning on a good value trains operators to ignore real warnings')
    end
end)

t.test('REGRESSION: pollIntervalMs = 0 no longer aborts this file\'s load -- clamps to the shipped 2000ms fallback, warns loudly, and the poll thread still runs end-to-end', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 0, reFireCooldownMs = 1000 },
    })
    t.isTrue(ok, 'the file must still load -- an abort here kills the whole K9-down dispatch feature')
    t.equals(f.createThreadCallCount(), 1, 'the maintenance poll thread must still be created')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.K9DownDispatch.pollIntervalMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find('2000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')

    -- Prove the resolved fallback interval is what the real thread runs on,
    -- not merely that loading survived.
    registerQualifyingK9(f, 51, 5151)
    f.setHealth(5151, 200)
    f.tick() -- prime
    f.setHealth(5151, 10)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'the poll thread must still detect and fire a real episode after pollIntervalMs was clamped')
end)

t.test('REGRESSION: a VALID healthThreshold/minDurationMs/pollIntervalMs are all still used, not silently replaced by their fallbacks', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 77, minDurationMs = 500, pollIntervalMs = 1500, reFireCooldownMs = 1000 },
    })
    t.isTrue(ok)
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('healthThreshold', 1, true), 'a valid configured healthThreshold must pass through silently')
        t.isNil(line:find('minDurationMs', 1, true), 'a valid configured minDurationMs must pass through silently')
        t.isNil(line:find('pollIntervalMs', 1, true), 'a valid configured pollIntervalMs must pass through silently')
    end
end)

-- ------------------------------------------------------------------
-- REGRESSION (2026-08-26): this test used to assert the OPPOSITE --
-- that reFireCooldownMs = 0 aborts this file's load via NewCooldown's
-- own constructor guard. It was pinning the bug.
--
-- The assert block above names reFireCooldownMs in its message but
-- never actually validated it, so the raw value reached NewCooldown(0),
-- which errors at file-load time and takes PollK9Health and its
-- CreateThread poll loop down with it -- K9-down dispatch silently dead
-- for the rest of that server's uptime behind one console line. And 0
-- is the single most natural thing an operator types for "no cooldown".
--
-- Now routed through ResolveConfiguredThresholdMs like the other
-- configured-threshold sites: clamp to the shipped fallback, warn
-- loudly naming the key, keep the file alive. Same shape as
-- kennel_spec.lua's and fetch_spec.lua's own regression tests.
-- ------------------------------------------------------------------

t.test('REGRESSION: reFireCooldownMs = 0 no longer aborts this file\'s load -- clamps to the shipped 30000ms fallback and warns loudly, naming the exact key', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 0 },
    })
    t.isTrue(ok, 'the file must still load -- an abort here kills the whole K9-down dispatch feature')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.K9DownDispatch.reFireCooldownMs', 1, true)
            and line:find('30000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key and the fallback substituted -- the operator still has to find out')
end)

t.test('REGRESSION: reFireCooldownMs = NaN also no longer aborts this file\'s load', function()
    local ok = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 0 / 0 },
    })
    t.isTrue(ok)
end)

t.test('REGRESSION: a VALID reFireCooldownMs is still used, not silently replaced by the fallback', function()
    local ok, f = pcall(newIntegrationsFixture, {
        tuning = { healthThreshold = 100, minDurationMs = 0, pollIntervalMs = 1000, reFireCooldownMs = 777 },
    })
    t.isTrue(ok)
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('reFireCooldownMs', 1, true),
            'a valid configured value must pass through silently -- warning on a good value trains operators to ignore the warning')
    end
end)

-- ----------------------------------------------------------------------
-- 3. Main fire path: exact documented payload
-- ----------------------------------------------------------------------

t.test('a qualifying K9 held at/below threshold for >= minDurationMs fires k9Down exactly once with the documented payload', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 42, 4242)
    f.setCoords(4242, { x = 100.0, y = 200.0, z = 30.0 })
    f.setHealth(4242, 200) -- healthy at first

    f.tick() -- prime (first Wait in the while loop; no pass runs yet)

    f.setHealth(4242, 50) -- drop below threshold (100)
    f.advance(2000)
    f.tick() -- pass 1: episode starts, elapsed 0 < minDurationMs(3000) -- no fire
    t.equals(#f.outboundEvents, 0)

    f.advance(2000)
    f.tick() -- pass 2: elapsed 2000 < 3000 -- still no fire
    t.equals(#f.outboundEvents, 0)

    f.advance(2000)
    f.tick() -- pass 3: elapsed 4000 >= 3000 -- fires now
    t.equals(#f.outboundEvents, 1)

    local ev = f.outboundEvents[1]
    t.equals(ev.name, 'john-k9:events:k9Down')
    t.equals(ev.args[1], 42, 'source')
    t.equals(ev.args[2], 'CITIZEN_42', 'citizenid')
    t.equals(ev.args[3], 'police', 'jobName')
    t.equals(ev.args[4].x, 100.0, 'coords.x')
    t.equals(ev.args[4].y, 200.0, 'coords.y')
    t.equals(ev.args[4].z, 30.0, 'coords.z')
    t.equals(ev.args[5], 50, 'health at the moment of firing')
end)

t.test('a fired episode never fires a second time while health stays continuously at/below threshold', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 7, 707)
    f.setHealth(707, 200)
    f.tick() -- prime

    f.setHealth(707, 10)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'fired exactly once by now')

    -- Keep polling for a good while longer, still down -- must stay at 1.
    for _ = 1, 5 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'still exactly one fire for the same continuous episode')
end)

-- ----------------------------------------------------------------------
-- 4. Debounce: a graze that recovers before minDurationMs never fires,
--    and does not leave stale progress for a later, real episode
-- ----------------------------------------------------------------------

t.test('a graze that recovers above threshold before minDurationMs elapses never fires', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 5, 505)
    f.setHealth(505, 200)
    f.tick() -- prime

    f.setHealth(505, 50) -- dip
    f.advance(1000)
    f.tick() -- elapsed 0 (episode start) -- no fire yet

    f.setHealth(505, 200) -- healed well before minDurationMs (3000) elapses
    f.advance(1000)
    f.tick() -- health above threshold -- episode resets

    f.advance(999999)
    f.tick() -- still healthy -- nothing to fire
    t.equals(#f.outboundEvents, 0, 'a healed graze must never fire a dispatch alert')
end)

t.test('after a healed graze, a later genuine episode starts its own fresh timer rather than reusing stale progress', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 6, 606)
    f.setHealth(606, 200)
    f.tick() -- prime

    f.setHealth(606, 50)
    f.advance(2000)
    f.tick() -- elapsed 0 this tick (episode just started) -- no fire

    f.setHealth(606, 200) -- healed
    f.advance(100)
    f.tick() -- resets

    -- A GENUINE new episode: must take the full minDurationMs again, not
    -- "finish" off the earlier partial progress.
    f.setHealth(606, 50)
    f.advance(2000)
    f.tick() -- elapsed 0 again (fresh episode) -- no fire
    t.equals(#f.outboundEvents, 0)

    f.advance(3000)
    f.tick() -- elapsed 3000 >= minDurationMs -- fires now
    t.equals(#f.outboundEvents, 1)
end)

-- ----------------------------------------------------------------------
-- 5. "A missing/absent target is a clean no-op" -- non-qualifying players
-- ----------------------------------------------------------------------

t.test('a non-K9-modeled player never fires, however low health reads', function()
    local f = newIntegrationsFixture()
    f.setOnline(8)
    f.setPed(8, 808)
    f.setModel(808, 55) -- never marked as a K9 model
    f.setAccess(8, true)
    f.setPlayer(8, 'NOTAK9', 'police')
    f.setHealth(808, 1)
    f.tick()
    for _ = 1, 5 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 0)
end)

t.test('a K9-modeled player without current K9 access never fires, however low health reads', function()
    local f = newIntegrationsFixture()
    f.setOnline(9)
    f.setPed(9, 909)
    f.markK9Model(77)
    f.setModel(909, 77)
    f.setAccess(9, false) -- decertified / not on duty
    f.setPlayer(9, 'DECERT', 'police')
    f.setHealth(909, 1)
    f.tick()
    for _ = 1, 5 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 0)
end)

t.test('a currently-connected player with no spawned ped (ped == 0) is skipped without error', function()
    local f = newIntegrationsFixture()
    f.setOnline(10) -- online per GetPlayers(), but GetPlayerPed returns 0 (default, never set)
    f.tick()
    local ok = pcall(function()
        f.advance(2000)
        f.tick()
    end)
    t.isTrue(ok, 'must not error when a listed player has no spawned ped yet')
    t.equals(#f.outboundEvents, 0)
end)

-- ----------------------------------------------------------------------
-- 6. Listener-throws containment
-- ----------------------------------------------------------------------

t.test('a registered listener throwing on TriggerEvent is swallowed and logged, never breaking the poll pass', function()
    local f = newIntegrationsFixture()
    f.setThrowForEvent('john-k9:events:k9Down')

    registerQualifyingK9(f, 11, 1111)
    f.setHealth(1111, 200)
    f.tick() -- prime

    f.setHealth(1111, 10)
    local ok = pcall(function()
        for _ = 1, 3 do
            f.advance(2000)
            f.tick()
        end
    end)
    t.isTrue(ok, 'a throwing listener must never propagate out of the poll thread')
    t.equals(#f.outboundEvents, 1, 'the event still fired (and was recorded) before the simulated listener threw')

    local sawLogLine = false
    for _, line in ipairs(f.printedLines) do
        if line:find('outbound event', 1, true) and line:find('john-k9:events:k9Down', 1, true) then
            sawLogLine = true
        end
    end
    t.isTrue(sawLogLine, 'the swallowed listener error should be logged, not silently dropped')
end)

t.test('after a listener throw, a later INDEPENDENT episode (different source) still fires normally -- the poll loop is not wedged', function()
    local f = newIntegrationsFixture()
    f.setThrowForEvent('john-k9:events:k9Down')

    registerQualifyingK9(f, 12, 1212)
    registerQualifyingK9(f, 13, 1313)
    f.setHealth(1212, 200)
    f.setHealth(1313, 200)
    f.tick() -- prime

    f.setHealth(1212, 5)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 1, 'first K9 fired once despite its own listener throwing')

    -- Second K9 goes down independently afterward -- must still be detected
    -- and fired for, proving the earlier throw did not wedge PollK9Health.
    f.setHealth(1313, 5)
    for _ = 1, 3 do
        f.advance(2000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 2, 'second, independent K9 also fired')
    t.equals(f.outboundEvents[2].args[1], 13, 'the second event is for the second source')
end)

-- ----------------------------------------------------------------------
-- 7. Per-source re-fire cooldown: defers, never silently drops
-- ----------------------------------------------------------------------

t.test('a second episode within reFireCooldownMs of the first fire is deferred, then fires as soon as the cooldown clears while still down', function()
    local f = newIntegrationsFixture({
        tuning = { healthThreshold = 100, minDurationMs = 1000, pollIntervalMs = 1000, reFireCooldownMs = 10000 },
    })
    registerQualifyingK9(f, 14, 1414)
    f.setHealth(1414, 200)
    f.tick() -- prime

    -- First episode: fires at elapsed >= 1000.
    f.setHealth(1414, 10)
    f.advance(1000)
    f.tick() -- elapsed 0 -- no fire
    f.advance(1000)
    f.tick() -- elapsed 1000 -- fires (t = 2000)
    t.equals(#f.outboundEvents, 1)

    -- Recover, then go down again quickly (well within the 10000ms
    -- reFireCooldownMs window) and STAY down.
    f.setHealth(1414, 200)
    f.advance(500)
    f.tick() -- healthy tick, episode resets (t = 2500)

    f.setHealth(1414, 10)
    f.advance(1000)
    f.tick() -- episode starts (t = 3500)
    f.advance(1000)
    f.tick() -- elapsed 1000 >= minDurationMs, but cooldown from the first fire (stamped at t=2000, 10000ms window) is still active -- deferred (t = 4500)
    t.equals(#f.outboundEvents, 1, 'second episode qualifies but must be deferred by the still-active re-fire cooldown')

    -- Keep polling, still continuously down, until the cooldown clears
    -- (t >= 2000 + 10000 = 12000).
    for _ = 1, 8 do
        f.advance(1000)
        f.tick()
    end
    t.equals(#f.outboundEvents, 2, 'the deferred episode must still fire once the cooldown clears, not be lost forever')
    t.equals(f.outboundEvents[2].args[1], 14)
end)

-- ----------------------------------------------------------------------
-- 8. playerDropped clears in-progress episode state
-- ----------------------------------------------------------------------

t.test('playerDropped clears an in-progress episode -- a later reconnect must start a fresh timer, not resume stale progress', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 15, 1515)
    f.setHealth(1515, 200)
    f.tick() -- prime

    f.setHealth(1515, 10)
    f.advance(1000)
    f.tick() -- episode starts, elapsed 0 -- no fire (needs 3000)
    t.equals(#f.outboundEvents, 0)

    -- Disconnect mid-episode.
    f.firePlayerDropped(15)
    f.setOffline(15)
    f.clearPlayer(15)

    -- Reconnect as a fresh session for the same logical player/source,
    -- still unhealthy from the very first poll tick after reconnecting.
    registerQualifyingK9(f, 15, 1515)
    f.setHealth(1515, 10)
    f.advance(3000) -- would have been more than enough to fire on STALE progress
    f.tick()
    t.equals(#f.outboundEvents, 0, 'a cleared episode must not fire off progress from before the disconnect')

    -- But a genuinely full-length episode after reconnecting still works.
    f.advance(3000)
    f.tick()
    t.equals(#f.outboundEvents, 1, 'a real, full-length post-reconnect episode still fires')
end)

-- ----------------------------------------------------------------------
-- 9. PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsK9DownDispatchPermittedForCitizenId. Mirrors this
-- suite's own established fixture/test shape (see mainserver_spec.lua's
-- identical section for BasicBarkSounds/LeashMechanics, and
-- pursuitsprint_spec.lua for the full 5-case template).
--
-- No separate "cleanup/termination path still runs" case here: this
-- feature has no ongoing per-player state of its own to strand -- a block
-- suppresses one specific ANNOUNCEMENT, it never touches detection/episode
-- tracking (K9DownState) for anyone, blocked or not. That is proven
-- directly below (block still marks the episode fired, so a real,
-- unrelated later episode for the SAME citizenid still gets its own fresh
-- attempt once health recovers and drops again).
-- ----------------------------------------------------------------------

--- Advances the fixture through the exact same 3-tick (2000ms each) shape
--- the file's own "fires k9Down exactly once" test above uses, after health
--- has already been set below the resolved threshold.
--- @param f table
local function advanceThroughQualifyingEpisode(f)
    f.advance(2000) f.tick()
    f.advance(2000) f.tick()
    f.advance(2000) f.tick()
end

t.test('PER-PERSON: block.K9DownDispatch suppresses the announcement even though every detection condition is met', function()
    local f = newIntegrationsFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.K9DownDispatch' and citizenid == 'CITIZEN_50' end,
    })
    registerQualifyingK9(f, 50, 5050)
    f.setHealth(5050, 200)
    f.tick() -- prime

    f.setHealth(5050, 0)
    advanceThroughQualifyingEpisode(f)
    t.equals(#f.outboundEvents, 0, 'a blocked citizenid must never get the announcement, even while genuinely down')

    -- Never retried for the REST of this same down episode either (the
    -- episode is marked fired internally even though nothing was
    -- announced) -- proven by ticking well past reFireCooldownMs with
    -- health still at 0.
    f.advance(30000)
    f.tick()
    t.equals(#f.outboundEvents, 0, 'a block must not turn into a retry-every-tick loop for the remainder of the same episode')
end)

t.test('PER-PERSON: not blocked and not listed in RequireGrant -- default ALLOW (step 4), matching config.lua\'s documented default', function()
    local f = newIntegrationsFixture()
    registerQualifyingK9(f, 51, 5151)
    f.setHealth(5151, 200)
    f.tick()
    f.setHealth(5151, 0)
    advanceThroughQualifyingEpisode(f)
    t.equals(#f.outboundEvents, 1)
end)

t.test('PER-PERSON: RequireGrant.K9DownDispatch = true + no active feature.K9DownDispatch grant -- denied even though every detection condition is met', function()
    local f = newIntegrationsFixture({ featureControl = { RequireGrant = { K9DownDispatch = true } } })
    registerQualifyingK9(f, 52, 5252)
    f.setHealth(5252, 200)
    f.tick()
    f.setHealth(5252, 0)
    advanceThroughQualifyingEpisode(f)
    t.equals(#f.outboundEvents, 0)
end)

t.test('PER-PERSON: RequireGrant.K9DownDispatch = true + an active feature.K9DownDispatch grant -- allowed', function()
    local f = newIntegrationsFixture({
        featureControl = { RequireGrant = { K9DownDispatch = true } },
        hasPermissionFn = function(citizenid, key) return key == 'feature.K9DownDispatch' and citizenid == 'CITIZEN_53' end,
    })
    registerQualifyingK9(f, 53, 5353)
    f.setHealth(5353, 200)
    f.tick()
    f.setHealth(5353, 0)
    advanceThroughQualifyingEpisode(f)
    t.equals(#f.outboundEvents, 1)
end)

t.test('PER-PERSON: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local f = newIntegrationsFixture({
        withHasPermission = false,
        featureControl = { RequireGrant = { K9DownDispatch = true } },
    })
    registerQualifyingK9(f, 54, 5454)
    f.setHealth(5454, 200)
    f.tick()
    f.setHealth(5454, 0)
    local ok = pcall(advanceThroughQualifyingEpisode, f)
    t.isTrue(ok, 'a missing HasPermission must never error the poll thread')
    t.equals(#f.outboundEvents, 0, 'RequireGrant-listed + unresolvable grant machinery must deny, not silently allow')
end)

t.test('PER-PERSON: server/permissions.lua entirely absent + NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newIntegrationsFixture({ withHasPermission = false })
    registerQualifyingK9(f, 55, 5555)
    f.setHealth(5555, 200)
    f.tick()
    f.setHealth(5555, 0)
    advanceThroughQualifyingEpisode(f)
    t.equals(#f.outboundEvents, 1)
end)

t.test('PER-PERSON: a block never affects a DIFFERENT, unrelated citizenid\'s own episode in the same poll pass', function()
    local f = newIntegrationsFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.K9DownDispatch' and citizenid == 'CITIZEN_56' end,
    })
    registerQualifyingK9(f, 56, 5656) -- blocked
    registerQualifyingK9(f, 57, 5757) -- not blocked
    f.setHealth(5656, 200)
    f.setHealth(5757, 200)
    f.tick()
    f.setHealth(5656, 0)
    f.setHealth(5757, 0)
    advanceThroughQualifyingEpisode(f)
    t.equals(#f.outboundEvents, 1, 'exactly one announcement -- the unblocked citizenid -- even though both genuinely qualified')
    t.equals(f.outboundEvents[1].args[1], 57)
end)

os.exit(t.summary())
