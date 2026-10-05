--[[
    tests/clientpursuitsprint_spec.lua

    Direct, black-box tests of client/pursuitsprint.lua against the REAL,
    unmodified production file -- AND, deliberately, the REAL, unmodified
    client/movement.lua alongside it. See "WHY THE REAL client/movement.lua,
    NOT A STUB" below before touching this fixture.

    client/pursuitsprint.lua exposes exactly one resource-global
    (RequestPursuitSprint) plus two captured registrations
    (RegisterCommand('john-k9:pursuitsprint', ...) and the
    'john-k9:client:pursuitSprintGranted' RegisterNetEvent handler). This
    spec drives all three, never reimplementing FindNearestPursuitTarget's
    own scan logic or the grant handler's own end-timer.

    ======================================================================
    WHY THE REAL client/movement.lua, NOT A STUB -- THIS TASK'S OWN NAMED
    TRAP, AVOIDED HERE ON PURPOSE:
    this file's own task brief states plainly that an EARLIER version of
    the sibling server-side spec (tests/pursuitsprint_spec.lua) mocked out
    RecomputeK9MoveRate()/K9MoveRateModifiers with a bare local stand-in,
    which hid a REAL bug for weeks: RecomputeK9MoveRate() used to hard-gate
    on IsOwnModelK9() ALONE, silently discarding
    K9MoveRateModifiers.pursuitSprint for a role-holder on a non-K9 body --
    exactly the "ANY PED... NEVER ON PED MODEL" case client/pursuitsprint.lua's
    own header names as this feature's whole point. A fixture that stubs the
    composer can only ever prove "this file wrote a number into a table",
    never "that number actually changed anything" -- the precise blind spot
    that hid the bug. This spec therefore loads the REAL client/movement.lua
    FIRST, then the REAL client/pursuitsprint.lua on top, and asserts
    against the REAL SetPedMoveRateOverride call the real composer makes --
    see section C ("ANY PED, GENUINELY") for the test that is this
    reasoning made concrete.

    FIXTURE CONFIG FOR client/movement.lua, NOT REAL config.lua -- same
    "minimal, LOCAL Config table" discipline tests/clientmovement_spec.lua's
    own fixture already established (only Config.Features.AgilityBasicJump
    matters at movement.lua's own load time; every OTHER Config field it
    reads lives inside ox_target registration functions this spec never
    calls).

    STUBBING EFFORT: proportionate. client/movement.lua's own overrides list
    below is a near-exact copy of tests/clientmovement_spec.lua's own proven
    fixture (same natives, same shape) -- not re-derived from scratch.
    client/pursuitsprint.lua's own additional natives (GetGamePool,
    NetworkGetPlayerIndexFromPed, IsPedInAnyVehicle, a Vec3-alike for
    GetEntityCoords' `-`/`#`) are the same small, cheap recording stand-ins
    every other client spec in this suite uses.

    INSTRUMENTED THREAD RUNNER, own copy: the end-timer thread
    (pursuitSprintGranted's own `while elapsed < durationMs do Wait(tickMs)
    elapsed = elapsed + tickMs ... end`) calls Wait(tickMs) as the FIRST
    statement of its loop body, same shape as clienttracking_spec.lua's OWN
    compute/render threads (NOT the same shape as this suite's own
    poll thread shape, where Wait is the LAST
    statement) -- so the FIRST resume of a freshly created thread only
    "primes" it (runs to the initial Wait and yields without having
    incremented `elapsed` yet); each resume AFTER that runs exactly one
    real tick. A full `durationMs=200`/`tickMs=100` burst therefore needs
    THREE resumes to reach its own reset call: one prime, then two ticks.

    ONE FRESH SANDBOX PER TEST -- client/pursuitsprint.lua's own
    sprintGeneration and client/movement.lua's own lastAppliedMoveRate/
    K9MoveRateModifiers are exactly the kind of module-lifetime state that
    must never leak between two unrelated test cases.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- same shape as clientcombat_spec.lua's own copy:
-- only `-`/`#` are needed for FindNearestPursuitTarget's distance scan.
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT) end
Vec3MT.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec3MT) end

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- same deterministic, non-native formula every
-- other client spec in this suite uses. Only needed because
-- client/movement.lua's own K9_SIT_SCENARIO_BY_MODEL_HASH table (and this
-- file's own K9BreedSpeedMultiplierByModelHash) are built from it at
-- FILE-LOAD time.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'john-k9'

-- ----------------------------------------------------------------------
-- Instrumented thread runner -- see this file's header for why this is a
-- DIFFERENT shape than Sandbox.newThreadRunner() (Wait is this loop's LAST
-- statement, not its first).
-- ----------------------------------------------------------------------
local function newTrackedRunner()
    local threads = {}
    local waitLog = {}
    local runner = {}

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(ms)
        coroutine.yield(ms)
    end

    function runner.stepOne(i)
        local co = threads[i]
        if not co or coroutine.status(co) == 'dead' then return end
        local ok, msOrErr = coroutine.resume(co)
        if not ok then
            error(('clientpursuitsprint_spec: thread %d errored: %s'):format(i, tostring(msOrErr)))
        end
        waitLog[i] = msOrErr
    end

    --- Steps threads[i] until it dies (or a safety cap is hit), for tests
    --- that just want "run the whole burst out" without hand-counting ticks.
    function runner.runToCompletion(i, maxSteps)
        for _ = 1, (maxSteps or 200) do
            local co = threads[i]
            if not co or coroutine.status(co) == 'dead' then return end
            runner.stepOne(i)
        end
    end

    return runner, threads, waitLog
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { pursuitSprint: boolean?, isOwnModelK9: boolean?, hasK9Access: boolean?, speedMultiplier: number?, durationMs: number?, requestRangeMeters: number? }?
local function newPursuitSprintFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    -- ---- client/movement.lua's own required overrides (proven shape,
    -- lifted from tests/clientmovement_spec.lua's own fixture) ----
    local isOwnModelK9 = opts.isOwnModelK9
    if isOwnModelK9 == nil then isOwnModelK9 = true end
    local function IsOwnModelK9() return isOwnModelK9 end

    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = false end
    local function HasK9Access() return hasK9Access end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local pedHandle = 1
    local existingEntities = { [1] = true }
    local pedCoordsByEntity = {}
    local pedDeadByEntity = {}
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityModel(_entity) return nil end
    local function GetEntityCoords(entity) return pedCoordsByEntity[entity] or vec3(0, 0, 0) end
    local function IsEntityDead(entity) return pedDeadByEntity[entity] == true end

    local setMoveRateCalls = {}
    local function SetPedMoveRateOverride(ped, rate)
        setMoveRateCalls[#setMoveRateCalls + 1] = { ped = ped, rate = rate }
    end

    local function SetFollowPedCamViewMode(_mode) end
    local function GetCurrentResourceName() return RESOURCE_NAME end

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local commandHandlers = {}
    local function RegisterCommand(name, handler, _restricted) commandHandlers[name] = handler end
    local keyMappingCount = 0
    local function RegisterKeyMapping(...) keyMappingCount = keyMappingCount + 1 end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- ---- client/pursuitsprint.lua's own additional overrides ----
    local cpedPool = {}
    local function GetGamePool(poolName)
        assert(poolName == 'CPed', 'clientpursuitsprint_spec: only CPed pool is modelled')
        return cpedPool
    end
    local playerIndexByPed = {}
    local function NetworkGetPlayerIndexFromPed(ped) return playerIndexByPed[ped] or -1 end
    local isPedInAnyVehicle = false
    local function IsPedInAnyVehicle(_ped, _atGetIn) return isPedInAnyVehicle end
    local isInK9Vehicle = false
    local function IsInK9Vehicle() return isInK9Vehicle end
    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(entity) return netIdByPed[entity] or (entity * 1000) end

    local Config = {
        Features = { AgilityBasicJump = true, PursuitSprint = opts.pursuitSprint ~= false },
        PursuitSprint = {
            speedMultiplier = opts.speedMultiplier or 1.5,
            durationMs = opts.durationMs or 200, -- fast test iterations: 2 ticks @ tickMs=100 (fixed in production)
            requestRangeMeters = opts.requestRangeMeters or 10.0,
        },
    }

    local overrides = {
        Config = Config,
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        IsEntityDead = IsEntityDead,
        DoesEntityExist = DoesEntityExist,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        GetGamePool = GetGamePool,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        TriggerServerEvent = TriggerServerEvent,
        lib = { notify = lib_notify },
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        GetHashKey = GetHashKey,
        GetEntityModel = GetEntityModel,
        SetFollowPedCamViewMode = SetFollowPedCamViewMode,
        IsOwnModelK9 = IsOwnModelK9,
        HasK9Access = HasK9Access,
        SetPedMoveRateOverride = SetPedMoveRateOverride,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        source = 65535,
    }
    if opts.provideIsInK9Vehicle ~= false then
        overrides.IsInK9Vehicle = IsInK9Vehicle
    end

    local env = Sandbox.newEnv(overrides)

    -- REAL client/movement.lua, loaded FIRST -- see this file's header "WHY
    -- THE REAL client/movement.lua, NOT A STUB". K9MoveRateModifiers/
    -- RecomputeK9MoveRate below are the genuine production symbols.
    Sandbox.loadInto('../client/movement.lua', env)

    -- Baseline AFTER movement.lua's own load-time CreateThread call (its
    -- always-on leash pull-back thread) but BEFORE pursuitsprint.lua ever
    -- loads -- every "how many NEW threads did this create" assertion below
    -- subtracts this baseline.
    local threadCountBaseline = #threads
    -- Same reasoning for RegisterKeyMapping -- movement.lua registers its own
    -- 'john-k9:toggleCamera' keybind unconditionally at load time.
    local keyMappingCountBaseline = keyMappingCount

    local ok, err = pcall(Sandbox.loadInto, '../client/pursuitsprint.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err }
    end
    assert(ok, 'client/pursuitsprint.lua failed to load: ' .. tostring(err))

    return {
        env = env,
        threads = threads,
        waitLog = waitLog,
        stepOne = runner.stepOne,
        runToCompletion = runner.runToCompletion,
        newThreadsSinceLoad = function() return #threads - threadCountBaseline end,
        serverEvents = serverEvents,
        notifyCalls = notifyCalls,
        setMoveRateCalls = setMoveRateCalls,
        denyCallCount = function() return denyCalls end,
        keyMappingCount = function() return keyMappingCount - keyMappingCountBaseline end,
        commandCount = function()
            local n = 0
            for _ in pairs(commandHandlers) do n = n + 1 end
            return n
        end,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEventHandlers) do n = n + 1 end
            return n
        end,
        hasCommand = function(name) return commandHandlers[name] end,
        hasNetEvent = function(name) return netEventHandlers[name] end,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setIsPedInAnyVehicle = function(v) isPedInAnyVehicle = v end,
        setIsInK9Vehicle = function(v) isInK9Vehicle = v end,
        setPedDead = function(entity, v) pedDeadByEntity[entity] = v end,
        addCandidate = function(ped, x, y, z, isPlayer, netId)
            cpedPool[#cpedPool + 1] = ped
            pedCoordsByEntity[ped] = vec3(x, y, z)
            existingEntities[ped] = true
            playerIndexByPed[ped] = isPlayer and 0 or -1
            if netId then netIdByPed[ped] = netId end
        end,
        runRequest = function()
            local handler = commandHandlers['john-k9:pursuitsprint']
            assert(handler, 'client/pursuitsprint.lua did not register john-k9:pursuitsprint')
            handler()
        end,
        dispatchGrant = function(src)
            env.source = src
            local handler = assert(netEventHandlers['john-k9:client:pursuitSprintGranted'],
                'client/pursuitsprint.lua did not register john-k9:client:pursuitSprintGranted')
            handler()
        end,
        fireResourceStop = function(resourceName)
            for _, h in ipairs(eventHandlers['onResourceStop'] or {}) do h(resourceName or RESOURCE_NAME) end
        end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- feature flag off: GENUINELY inert.
-- ----------------------------------------------------------------------

t.test('Config.Features.PursuitSprint = false: registers NEITHER its own command NOR its own net event, and RequestPursuitSprint is never (re)defined -- movement.lua own unrelated registrations are untouched either way', function()
    local f = newPursuitSprintFixture({ pursuitSprint = false })
    t.isNil(f.hasCommand('john-k9:pursuitsprint'))
    t.equals(f.keyMappingCount(), 0)
    t.isNil(f.hasNetEvent('john-k9:client:pursuitSprintGranted'))
    t.isNil(f.env.RequestPursuitSprint)
    t.equals(f.newThreadsSinceLoad(), 0, 'no load-time thread from this file when off')
end)

t.test('Config.Features.PursuitSprint = true: registers its own command, its own keybind, and its own grant net event; RequestPursuitSprint exists', function()
    local f = newPursuitSprintFixture()
    t.isNotNil(f.hasCommand('john-k9:pursuitsprint'))
    t.equals(f.keyMappingCount(), 1)
    t.isNotNil(f.hasNetEvent('john-k9:client:pursuitSprintGranted'))
    t.isNotNil(f.env.RequestPursuitSprint)
end)

-- ----------------------------------------------------------------------
-- SECTION B -- config-shape CLAMP AND WARN (input edge cases: a
-- misconfigured operator's config.lua must keep this file loading -- with
-- a loud, named warning -- not abort its load and silently un-register
-- every PursuitSprint command/keybind/event below the bad line).
--
-- REGRESSION (this pass): these two tests used to assert the OPPOSITE --
-- that a missing Config.PursuitSprint table, or an invalid speedMultiplier,
-- FAILED THE ENTIRE FILE'S LOAD via a hard `assert`. See
-- server/cooldowns.lua's header ADDENDUM and this file's own updated
-- header comment for why that was the wrong remedy: an uncaught error
-- thrown from this file's own top-level chunk (no deferring
-- onResourceStart/RegisterNetEvent wrapper around it) would silently
-- un-register every PursuitSprint client handler, over one operator typo.
-- ----------------------------------------------------------------------

t.test('Config.PursuitSprint missing entirely: no longer fails to load -- clamps every field to its shipped fallback, warns loudly, and the command/keybind still register', function()
    local runner = newTrackedRunner()
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end
    local Config = { Features = { AgilityBasicJump = true, PursuitSprint = true } } -- no Config.PursuitSprint table at all
    local registerCommandCalls, registerKeyMappingCalls = {}, {}
    local env = Sandbox.newEnv({
        Config = Config, GetHashKey = GetHashKey, CreateThread = runner.CreateThread, Wait = runner.Wait,
        print = printStub,
        RegisterCommand = function(name, handler) registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler } end,
        RegisterKeyMapping = function(commandName) registerKeyMappingCalls[#registerKeyMappingCalls + 1] = { commandName = commandName } end,
        RegisterNetEvent = function() end, AddEventHandler = function() end,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
        PlayerPedId = function() return 1 end, DoesEntityExist = function() return true end,
        GetEntityModel = function() return nil end, SetFollowPedCamViewMode = function() end,
        IsOwnModelK9 = function() return true end, HasK9Access = function() return false end,
        SetPedMoveRateOverride = function() end,
    })
    Sandbox.loadInto('../client/movement.lua', env)
    local ok, err = pcall(Sandbox.loadInto, '../client/pursuitsprint.lua', env)
    t.isTrue(ok, 'client/pursuitsprint.lua failed to load: ' .. tostring(err))

    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.PursuitSprint', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must print a warning naming Config.PursuitSprint as missing')

    t.equals(Config.PursuitSprint.speedMultiplier, 1.4)
    t.equals(Config.PursuitSprint.durationMs, 5000)
    t.equals(Config.PursuitSprint.requestRangeMeters, 20.0)

    -- Filtered BY NAME, not a raw count -- client/movement.lua (loaded
    -- first, same as every other test in this file) also registers its own
    -- unrelated 'john-k9:toggleCamera' command/keybind into this same
    -- shared list.
    local registeredCommand, registeredKeyMapping
    for _, c in ipairs(registerCommandCalls) do
        if c.name == 'john-k9:pursuitsprint' then registeredCommand = c end
    end
    for _, k in ipairs(registerKeyMappingCalls) do
        if k.commandName == 'john-k9:pursuitsprint' then registeredKeyMapping = k end
    end
    t.isNotNil(registeredCommand, 'john-k9:pursuitsprint must still register')
    t.isNotNil(registeredKeyMapping, 'its keybind must still register')
end)

t.test('Config.PursuitSprint.speedMultiplier <= 0: no longer fails to load -- clamps to the shipped 1.4 fallback and warns loudly', function()
    local runner = newTrackedRunner()
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end
    local Config = { Features = { AgilityBasicJump = true, PursuitSprint = true },
        PursuitSprint = { speedMultiplier = 0, durationMs = 200, requestRangeMeters = 10.0 } }
    local env = Sandbox.newEnv({
        Config = Config, GetHashKey = GetHashKey, CreateThread = runner.CreateThread, Wait = runner.Wait,
        print = printStub,
        RegisterCommand = function() end, RegisterKeyMapping = function() end,
        RegisterNetEvent = function() end, AddEventHandler = function() end,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
        PlayerPedId = function() return 1 end, DoesEntityExist = function() return true end,
        GetEntityModel = function() return nil end, SetFollowPedCamViewMode = function() end,
        IsOwnModelK9 = function() return true end, HasK9Access = function() return false end,
        SetPedMoveRateOverride = function() end,
    })
    Sandbox.loadInto('../client/movement.lua', env)
    local ok, err = pcall(Sandbox.loadInto, '../client/pursuitsprint.lua', env)
    t.isTrue(ok, 'client/pursuitsprint.lua failed to load: ' .. tostring(err))

    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('speedMultiplier', 1, true) and line:find('found: 0', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact key and the value found')
    t.equals(Config.PursuitSprint.speedMultiplier, 1.4)
    -- valid siblings pass through unchanged
    t.equals(Config.PursuitSprint.durationMs, 200)
    t.equals(Config.PursuitSprint.requestRangeMeters, 10.0)
end)

-- ----------------------------------------------------------------------
-- SECTION C -- ANY PED, GENUINELY: the fix this task named as the exact
-- thing an earlier, stubbed fixture hid. Proven against the REAL
-- client/movement.lua composer, not a stand-in.
-- ----------------------------------------------------------------------

t.test('ANY PED, GENUINELY: NOT on a K9 model but HasK9Access() true (a certified handler on a human/custom body) -- the grant STILL reaches the real native call with the real multiplier', function()
    local f = newPursuitSprintFixture({ isOwnModelK9 = false, hasK9Access = true, speedMultiplier = 1.75 })
    f.dispatchGrant(65535)
    t.equals(#f.setMoveRateCalls, 1, 'RecomputeK9MoveRate must have genuinely reached SetPedMoveRateOverride')
    t.equals(f.setMoveRateCalls[1].rate, 1.75)
    t.equals(f.env.K9MoveRateModifiers.pursuitSprint, 1.75)
end)

t.test('ANY PED, GENUINELY: NOT on a K9 model AND no real K9 access either -- correctly a no-op (the server would never have granted this in the first place)', function()
    local f = newPursuitSprintFixture({ isOwnModelK9 = false, hasK9Access = false })
    f.dispatchGrant(65535)
    t.equals(#f.setMoveRateCalls, 0, 'neither model nor access -- the composer must not apply anything')
end)

t.test('REQUEST PATH, ANY PED: RequestPursuitSprint() never calls CanShowK9UI() at all -- proven by omitting it from the sandbox entirely (would error, not silently pass, if it were ever called)', function()
    local f = newPursuitSprintFixture()
    f.env.CanShowK9UI = nil
    f.env.DenyK9UIAccess = nil
    f.env.IsOwnModelK9 = nil -- also never consulted by the REQUEST path itself
    t.isNil(f.env.CanShowK9UI, 'sanity: genuinely absent, not merely false')

    f.addCandidate(2, 1.0, 0.0, 0.0, true, 2222)
    f.runRequest() -- must not error even with CanShowK9UI/IsOwnModelK9 entirely undefined
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].event, 'john-k9:server:requestPursuitSprint')
    t.equals(f.serverEvents[1].args[1], 2222)
end)

-- ----------------------------------------------------------------------
-- SECTION D -- RequestPursuitSprint(): candidate selection.
-- ----------------------------------------------------------------------

t.test('RequestPursuitSprint: picks the NEAREST other player ped within range, ignoring self/dead/non-player/out-of-range peds', function()
    local f = newPursuitSprintFixture({ requestRangeMeters = 10.0 })
    f.addCandidate(1, 0.0, 0.0, 0.0, true) -- ignored: this IS myPed
    f.addCandidate(2, 20.0, 0.0, 0.0, true, 2000) -- out of range (20m > 10m)
    f.addCandidate(3, 5.0, 0.0, 0.0, false, 3000) -- not a player ped
    f.addCandidate(4, 8.0, 0.0, 0.0, true, 4000) -- farther in-range player
    f.addCandidate(5, 3.0, 0.0, 0.0, true, 5000) -- NEAREST in-range player -- expected pick
    f.setPedDead(5, false)
    f.setPedDead(4, false)

    f.runRequest()
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1].args[1], 5000)
end)

t.test('RequestPursuitSprint: a dead candidate is skipped even if it is otherwise the nearest', function()
    local f = newPursuitSprintFixture({ requestRangeMeters = 10.0 })
    f.addCandidate(5, 1.0, 0.0, 0.0, true, 5000)
    f.setPedDead(5, true)
    f.addCandidate(6, 4.0, 0.0, 0.0, true, 6000)

    f.runRequest()
    t.equals(f.serverEvents[1].args[1], 6000)
end)

t.test('RequestPursuitSprint: no candidate in range notifies no_target_nearby and never contacts the server', function()
    local f = newPursuitSprintFixture({ requestRangeMeters = 5.0 })
    f.addCandidate(2, 50.0, 0.0, 0.0, true, 2000)
    f.runRequest()
    t.equals(#f.serverEvents, 0)
    t.equals(f.notifyCalls[1].description, locale('pursuitsprint.no_target_nearby'))
end)

t.test('RequestPursuitSprint: tucked into (or seated in) a vehicle silently blocks the request -- no notify, no server event', function()
    local fVehicle = newPursuitSprintFixture()
    fVehicle.setIsPedInAnyVehicle(true)
    fVehicle.addCandidate(2, 1.0, 0.0, 0.0, true, 2000)
    fVehicle.runRequest()
    t.equals(#fVehicle.serverEvents, 0)
    t.equals(#fVehicle.notifyCalls, 0)

    local fTuck = newPursuitSprintFixture()
    fTuck.setIsInK9Vehicle(true)
    fTuck.addCandidate(2, 1.0, 0.0, 0.0, true, 2000)
    fTuck.runRequest()
    t.equals(#fTuck.serverEvents, 0)
end)

t.test('RequestPursuitSprint: silently tolerates IsInK9Vehicle being entirely undefined (soft dependency), never errors', function()
    local f = newPursuitSprintFixture({ provideIsInK9Vehicle = false })
    t.isNil(f.env.IsInK9Vehicle)
    f.addCandidate(2, 1.0, 0.0, 0.0, true, 2000)
    f.runRequest() -- must not error
    t.equals(#f.serverEvents, 1)
end)

-- ----------------------------------------------------------------------
-- SECTION E -- grant handling: source-origin guard, notify, and the
-- end-timer's own bounded lifetime.
-- ----------------------------------------------------------------------

t.test('pursuitSprintGranted: a forged (non-65535 source) push is rejected outright -- no modifier change, no notify, no new thread', function()
    local f = newPursuitSprintFixture()
    f.dispatchGrant(999)
    t.equals(#f.setMoveRateCalls, 0)
    t.equals(#f.notifyCalls, 0)
    t.equals(f.newThreadsSinceLoad(), 0)
end)

t.test('pursuitSprintGranted: a genuine grant applies the configured multiplier, notifies success, and starts exactly one new thread', function()
    local f = newPursuitSprintFixture({ speedMultiplier = 2.0 })
    f.dispatchGrant(65535)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 2.0)
    t.equals(f.notifyCalls[1].description, locale('pursuitsprint.activated'))
    t.equals(f.newThreadsSinceLoad(), 1)
end)

t.test('fail-closed when K9MoveRateModifiers/RecomputeK9MoveRate are absent: never applies anything, never errors', function()
    local f = newPursuitSprintFixture()
    f.env.K9MoveRateModifiers = nil
    f.env.RecomputeK9MoveRate = nil
    f.dispatchGrant(65535) -- must not error even though the composer is gone
    t.equals(#f.setMoveRateCalls, 0)
    t.equals(#f.notifyCalls, 0, 'a fail-closed grant does not fire the success notify either')
end)

-- ----------------------------------------------------------------------
-- SECTION F -- NO UNBOUNDED TRAP: the end-timer's termination path is
-- NEVER gated on access, even for access lost mid-burst. See this file's
-- own header "NO UNBOUNDED TRAP" for the full invariant this pins.
-- ----------------------------------------------------------------------

t.test('natural timeout: after durationMs elapses (2 ticks @ 100ms), the modifier resets to neutral via the REAL composer', function()
    local f = newPursuitSprintFixture({ durationMs = 200, isOwnModelK9 = true, hasK9Access = false })
    f.dispatchGrant(65535)
    local threadIndex = #f.threads -- index of the end-timer thread (the most recently created one)
    f.stepOne(threadIndex) -- PRIME (reaches the initial Wait, elapsed still 0)
    f.stepOne(threadIndex) -- tick 1 (elapsed = 100)
    f.stepOne(threadIndex) -- tick 2 (elapsed = 200 >= durationMs) -- resets
    local last = f.setMoveRateCalls[#f.setMoveRateCalls]
    t.equals(last.rate, 1.0)
end)

t.test('termination NEVER gated on access: access revoked MID-BURST (neither model nor access true anymore) still resets the native override on timeout, because lastAppliedMoveRate tracking forces the reset', function()
    local f = newPursuitSprintFixture({ durationMs = 200, isOwnModelK9 = false, hasK9Access = true, speedMultiplier = 1.6 })
    f.dispatchGrant(65535)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.6)

    -- Access revoked mid-burst -- the termination path must still work.
    f.setIsOwnModelK9(false)
    f.setHasK9Access(false)

    local threadIndex = #f.threads
    f.stepOne(threadIndex) -- PRIME
    f.stepOne(threadIndex) -- tick 1
    f.stepOne(threadIndex) -- tick 2 -- resets
    local last = f.setMoveRateCalls[#f.setMoveRateCalls]
    t.equals(last.rate, 1.0, 'the native override must still be reset to neutral even though neither gate currently holds')
end)

t.test('death mid-burst ends the burst EARLY, before durationMs elapses, regardless of access', function()
    local f = newPursuitSprintFixture({ durationMs = 100000 }) -- long enough that only death, not timeout, could end it within 2 ticks
    f.dispatchGrant(65535)
    local threadIndex = #f.threads

    f.stepOne(threadIndex) -- PRIME (reaches the initial Wait; death is only checked AFTER Wait returns)
    f.setPedDead(1, true)
    f.stepOne(threadIndex) -- this tick observes the death and breaks out of the loop, long before durationMs
    local last = f.setMoveRateCalls[#f.setMoveRateCalls]
    t.equals(last.rate, 1.0, 'own-death must end the burst immediately, not wait out the full duration')
end)

t.test('onResourceStop: resets a currently-applied non-neutral override via the real composer, even outside any active burst timer', function()
    local f = newPursuitSprintFixture({ speedMultiplier = 1.8 })
    f.dispatchGrant(65535)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.8)

    f.fireResourceStop(RESOURCE_NAME)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0)
end)

t.test('onResourceStop: ignores a stop event for a DIFFERENT resource name -- no reset', function()
    local f = newPursuitSprintFixture({ speedMultiplier = 1.8 })
    f.dispatchGrant(65535)
    local beforeCount = #f.setMoveRateCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.setMoveRateCalls, beforeCount, 'a different resource stopping must not touch this modifier at all')
end)

-- ----------------------------------------------------------------------
-- SECTION G -- DOUBLE-FIRE / RE-ENTRANCY: sprintGeneration must ensure only
-- the MOST RECENT grant's own end-timer ever resets the shared modifier.
-- ----------------------------------------------------------------------

t.test('DOUBLE-FIRE / RE-ENTRANCY: a second grant while the first end-timers thread is still pending creates its OWN, distinct timer; the FIRST (now-stale) timer completing later must NOT clobber the second grants still-active modifier', function()
    local f = newPursuitSprintFixture({ durationMs = 200, speedMultiplier = 1.5 })
    f.dispatchGrant(65535) -- grant 1 -> thread A
    local threadA = #f.threads

    f.dispatchGrant(65535) -- grant 2 (re-grant before grant 1's timer finished) -> thread B
    local threadB = #f.threads
    t.equals(threadB, threadA + 1, 'a second grant must start its own, distinct end-timer thread')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.5)

    -- Run thread A (the STALE end-timer) all the way to completion (prime + 2 ticks).
    f.stepOne(threadA)
    f.stepOne(threadA)
    f.stepOne(threadA)
    -- sprintGeneration has already moved on to grant 2 -- thread A's own
    -- completion must be a no-op, never resetting grant 2's still-live
    -- modifier back to neutral.
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.5, 'the stale timer must not have reset anything')

    -- Thread B (the CURRENT end-timer) still resets correctly on its own schedule.
    f.stepOne(threadB)
    f.stepOne(threadB)
    f.stepOne(threadB)
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'the genuinely current end-timer must still reset on schedule')
end)

os.exit(t.summary())
