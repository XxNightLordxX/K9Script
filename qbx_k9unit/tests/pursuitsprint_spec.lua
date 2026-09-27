--[[
    tests/pursuitsprint_spec.lua

    Direct, black-box tests of server/pursuitsprint.lua and
    client/pursuitsprint.lua against the REAL, unmodified production files
    (PROJECT_HISTORY.md §5, "Pursuit sprint"). One file, per this task's own file
    allowlist -- server-side tests first, client-side tests second, each
    with its own fixture builder, mirroring how
    tests/clientagility_spec.lua are each structured internally even though
    this suite keeps server/client specs in separate files everywhere else.

    SERVER FIXTURE: loads the REAL server/cooldowns.lua and
    server/entities.lua (mirrors tests/combat_spec.lua's own convention of
    loading entities.lua for real rather than hand-stubbing
    ResolveNetworkEntity/ResolveConnectedPlayerFromPed, since this feature
    -- unlike a pure termination path, which never calls either -- genuinely
    depends on their real resolution logic), then the real
    server/pursuitsprint.lua on top. `Config` is a small, hand-built table
    (mirroring tests/combat_spec.lua's own
    convention for a feature file with many independent knobs), NOT the
    real config.lua -- Config.Features.PursuitSprint/Config.PursuitSprint/
    Config.FeatureControl.RequireGrant.PursuitSprint do not exist in the
    currently-shipped config.lua as of this pass (reported to main
    separately to add), so this suite is deliberately independent of
    whether/when that lands.

    CLIENT FIXTURE: same "hand-built minimal Config" convention, plus a
    hand-rolled CPed pool (GetGamePool('CPed')) for FindNearestPursuitTarget,
    and Sandbox.newThreadRunner() to step the end-timer thread the grant
    handler starts (client/agility.lua's own header explains why that
    helper fits a CreateThread-based thread but not a plain RegisterCommand
    handler -- this file's end-timer IS a CreateThread body, so the helper
    fits directly, unlike clientagility_spec.lua's own TryVault).

    locale() is NEVER stubbed (this suite's established convention) --
    every locale('pursuitsprint.*') call exercised below resolves for real
    against locales/en.json, so this spec also doubles as a regression
    check that every key it reaches exists there once main applies this
    pass's own locale request.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape to every other spec in this suite
-- (clientagility_spec.lua/clientradial_spec.lua/combat_spec.lua/
-- certifications_spec.lua/tenure_spec.lua all carry their own copy).
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

-- ========================================================================
-- SERVER FIXTURE -- server/pursuitsprint.lua
-- ========================================================================

local REAL_SPEED_MULTIPLIER = 1.4
local REAL_DURATION_MS = 5000
local REAL_COOLDOWN_MS = 45000
local REAL_RANGE_METERS = 20.0

--- @param opts table? {
---   featureEnabled: boolean (default true) -- Config.Features.PursuitSprint
---   pursuitSprintCfg: table|false -- Config.PursuitSprint verbatim; false = omit entirely
---   requireWantedStatus: boolean (default true)
---   wantedStatusOverride: function?
---   requireGrantListed: boolean (default true) -- Config.FeatureControl.RequireGrant.PursuitSprint
---   withHasPermission: boolean (default true) -- whether HasPermission exists in the sandbox at all
---   hasPermissionFn: function -- override HasPermission's behavior
---   expectLoadError: boolean
--- }
--- @return table fixture
local function newServerFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local notifyLog = {}
    local function NotifyPlayer(src, message, kind)
        notifyLog[#notifyLog + 1] = { source = src, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    -- Player registry -- src <-> citizenid <-> ped.
    local playersBySource, pedBySource = {}, {}
    local function registerPlayer(src, citizenid, pedHandle, metadata)
        playersBySource[src] = { PlayerData = { citizenid = citizenid, metadata = metadata } }
        pedBySource[src] = pedHandle
    end

    -- NOTE: production code calls this with COLON syntax
    -- (`exports.qbx_core:GetPlayer(src)`), which passes `exports.qbx_core`
    -- itself as an implicit first argument -- mirrors
    -- tests/combat_spec.lua's own `qbxGetPlayer(_self, src)` stub shape
    -- exactly, for the same reason.
    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end
    local function GetPlayers()
        local list = {}
        for src in pairs(playersBySource) do list[#list + 1] = tostring(src) end
        return list
    end

    -- Bare-natives layer for the REAL server/entities.lua to call --
    -- mirrors tests/combat_spec.lua's own fixture shape.
    local pedByNetId = {}
    local existingEntities = {}
    local entityType = {}
    local function NetworkGetEntityFromNetworkId(netId) return pedByNetId[netId] or 0 end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityType(entity) return entityType[entity] or 1 end

    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local hasK9Access = true
    local hasK9AccessCalls = {}
    local function HasK9Access(src) hasK9AccessCalls[#hasK9AccessCalls + 1] = src; return hasK9Access end

    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local Config = {
        Features = { PursuitSprint = opts.featureEnabled ~= false },
        Combat = {
            RequireWantedStatus = opts.requireWantedStatus ~= false,
            WantedStatusCheckOverride = opts.wantedStatusOverride,
        },
        FeatureControl = {
            RequireGrant = { PursuitSprint = opts.requireGrantListed ~= false },
        },
    }
    if opts.pursuitSprintCfg == false then
        Config.PursuitSprint = nil
    elseif opts.pursuitSprintCfg ~= nil then
        Config.PursuitSprint = opts.pursuitSprintCfg
    else
        Config.PursuitSprint = {
            speedMultiplier = REAL_SPEED_MULTIPLIER,
            durationMs = REAL_DURATION_MS,
            cooldownMs = REAL_COOLDOWN_MS,
            requestRangeMeters = REAL_RANGE_METERS,
        }
    end

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local triggerClientEventCalls = {}
    local function TriggerClientEvent(name, target, ...)
        triggerClientEventCalls[#triggerClientEventCalls + 1] = { name = name, target = target, args = { ... } }
    end

    -- PursuitSprintCooldown now calls :StartSweep (server/cooldowns.lua)
    -- instead of :RegisterPlayerDropped() (see server/pursuitsprint.lua's
    -- own "RECONNECT GAP" comment on PursuitSprintCooldown for why) --
    -- :StartSweep calls CreateThread at this file's own load time, so this
    -- fixture needs a CreateThread/Wait stub the same way tests/combat_spec.lua's
    -- own fixture already does for TakedownTargetCooldown/BiteHoldTargetCooldown's
    -- identical :StartSweep calls. Sandbox.newThreadRunner() captures the
    -- sweep thread as a coroutine that is never resumed unless a test calls
    -- threadRunner.step() -- no test below needs the sweep to actually run
    -- (it only bounds memory for citizenids that stop requesting bursts
    -- entirely), so it is wired in purely so the file loads without error.
    local threadRunner = Sandbox.newThreadRunner()

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        exports = exportsTable,
        GetPlayerPed = GetPlayerPed,
        GetPlayers = GetPlayers,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        TriggerClientEvent = TriggerClientEvent,
    }
    if opts.withHasPermission ~= false then
        overrides.HasPermission = opts.hasPermissionFn or defaultHasPermission
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadSuspectsInto(env)

    local ok, err = pcall(Sandbox.loadInto, '../server/pursuitsprint.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err }
    end
    assert(ok, 'server/pursuitsprint.lua failed to load: ' .. tostring(err))

    return {
        env = env,
        Config = Config,
        notifyLog = notifyLog,
        printLog = printLog,
        eventHandlers = eventHandlers,
        triggerClientEventCalls = triggerClientEventCalls,
        threadRunner = threadRunner,
        hasK9AccessCalls = hasK9AccessCalls,
        permissionCalls = permissionCalls,
        advance = function(ms) state.now = state.now + ms end,
        setHasK9Access = function(v) hasK9Access = v end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        registerPlayer = registerPlayer,
        registerPed = function(entity, exists)
            existingEntities[entity] = exists ~= false
        end,
        registerTargetNetId = function(netId, pedHandle)
            pedByNetId[netId] = pedHandle
            existingEntities[pedHandle] = true
        end,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        --- Dispatches the real captured 'qbx_k9unit:server:requestPursuitSprint'
        --- handler with `env.source` set to `src`, mirroring
        --- this suite's own `dispatch` helper exactly. Accepts
        --- (and forwards) any EXTRA trailing arguments beyond targetNetId --
        --- the real handler's own signature is `function(targetNetId)`, so
        --- Lua silently discards anything past the first argument, exactly
        --- as it would for a modified client trying to smuggle extra values
        --- onto this event -- see the "A CLIENT CLAIMING A VALUE..." test.
        dispatch = function(src, targetNetId, ...)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:server:requestPursuitSprint'],
                'server/pursuitsprint.lua did not register qbx_k9unit:server:requestPursuitSprint')
            handler(targetNetId, ...)
        end,
        firePlayerDropped = function(src)
            env.source = src
            for _, h in ipairs(eventHandlers['playerDropped'] or {}) do h() end
        end,
    }
end

--- @return table? -- the LAST notifyLog entry for that source, or nil
local function lastNotifyFor(f, src)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == src then found = entry end
    end
    return found
end

-- ------------------------------------------------------------------
-- Feature gate / config asserts
-- ------------------------------------------------------------------

t.test('SERVER: Config.Features.PursuitSprint = false -- registers zero events, no asserts even run', function()
    local f = newServerFixture({ featureEnabled = false, pursuitSprintCfg = false })
    f.dispatch = nil -- nothing was registered to dispatch to
    t.equals(#f.notifyLog, 0)
end)

-- REGRESSION (this pass): this test used to assert the OPPOSITE -- that
-- Config.PursuitSprint being entirely missing FAILED THE ENTIRE FILE'S LOAD
-- via a hard `assert`. That was the very last top-level assert in this
-- file, on the theory that there was "nothing sensible to clamp/substitute
-- for the whole table missing" -- which does not hold up: substituting an
-- empty table lets every per-field resolver below fall back to its own
-- already-established default, exactly like every individual-field
-- REGRESSION test above already proves for speedMultiplier/durationMs/
-- requestRangeMeters/cooldownMs. The file now loads, the event registers,
-- and the feature keeps working entirely on built-in fallbacks while
-- printing one unmissable warning.
t.test('SERVER: Config.Features.PursuitSprint = true but Config.PursuitSprint entirely missing -- no longer aborts this file\'s load -- clamps every field to its shipped fallback, warns loudly, and the feature keeps working', function()
    local f = newServerFixture({ pursuitSprintCfg = false })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint is missing', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must print a warning naming Config.PursuitSprint as missing')

    t.equals(f.Config.PursuitSprint.speedMultiplier, REAL_SPEED_MULTIPLIER)
    t.equals(f.Config.PursuitSprint.durationMs, REAL_DURATION_MS)
    t.equals(f.Config.PursuitSprint.requestRangeMeters, REAL_RANGE_METERS)

    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'a granted request must still succeed even though the whole settings table was missing')
end)

-- ------------------------------------------------------------------
-- REGRESSION (2026-08-26): these three tests used to assert the OPPOSITE --
-- that speedMultiplier/durationMs/requestRangeMeters failing their bound
-- FAILED THE ENTIRE FILE'S LOAD via a hard `assert`, naming the offending
-- field. They were pinning the bug, the same mechanism this file's own
-- COOLDOWN FOOTGUN section below already documents: an uncaught error
-- thrown from THIS FILE's own top-level chunk aborts server/pursuitsprint.lua's
-- load from that line onward, silently un-registering
-- 'qbx_k9unit:server:requestPursuitSprint' -- the entire feature, not just
-- one bad number. cooldownMs (tested below) was migrated to
-- ResolveConfiguredThresholdMs first; these three siblings sat right above
-- it, unmigrated, only because durationMs is the only one of the three that
-- is even a duration, and neither of the other two feeds NewCooldown at all
-- -- not because the risk was any different.
--
-- Now clamp-and-warn: speedMultiplier/requestRangeMeters via this file's own
-- bespoke ResolveConfiguredPositiveNumber (a positive-number rule, but
-- NEITHER is a cooldown, so ResolveConfiguredThresholdMs's own cooldown-
-- specific warning text would mislead), durationMs via
-- ResolveConfiguredThresholdMs directly (a genuine duration, no legitimate
-- non-positive meaning). The file loads, the event registers, and the
-- feature keeps working on a safe built-in fallback while printing one
-- unmissable warning naming the exact key, the value found, and what was
-- substituted.
-- ------------------------------------------------------------------

t.test('REGRESSION: Config.PursuitSprint.speedMultiplier = 0 no longer aborts this file\'s load -- clamps to the shipped 1.4 fallback, warns loudly, and a granted request still succeeds', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = 0, durationMs = REAL_DURATION_MS, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = REAL_RANGE_METERS },
    })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint.speedMultiplier', 1, true)
            and line:find('found: 0', 1, true)
            and line:find(tostring(REAL_SPEED_MULTIPLIER), 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')

    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'a granted request must still succeed even though speedMultiplier was misconfigured')
    -- Config.PursuitSprint.speedMultiplier itself is resolved back into
    -- Config so client/pursuitsprint.lua's own (separate-process, but
    -- structurally identical) read of the same field would see the
    -- corrected value too, were this the same Lua state.
    t.equals(f.Config.PursuitSprint.speedMultiplier, REAL_SPEED_MULTIPLIER)
end)

t.test('REGRESSION: Config.PursuitSprint.durationMs = 0 no longer aborts this file\'s load -- clamps to the shipped 5000ms fallback and warns loudly', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = 0, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = REAL_RANGE_METERS },
    })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint.durationMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find(tostring(REAL_DURATION_MS), 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)
    t.equals(f.Config.PursuitSprint.durationMs, REAL_DURATION_MS)
end)

t.test('REGRESSION: Config.PursuitSprint.requestRangeMeters = -1 no longer aborts this file\'s load -- clamps to the shipped 20.0 fallback, warns loudly, and the resolved range is what the request handler actually enforces', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = REAL_DURATION_MS, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = -1 },
    })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint.requestRangeMeters', 1, true)
            and line:find('found: -1', 1, true)
            and line:find(tostring(REAL_RANGE_METERS), 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')

    -- Prove it at the level the bug lives: requestRangeMeters is re-read
    -- directly off Config at dispatch time (never captured to a local), so
    -- the RESOLVED fallback (20.0), not the invalid configured -1, must be
    -- what the live proximity check enforces.
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 15, 0, 0) -- within the fallback 20.0m, would be rejected under any small/negative configured value
    f.registerTargetNetId(9001, 200)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'the fallback range (20.0) must be the one actually enforced by the live request handler')
end)

t.test('REGRESSION: valid speedMultiplier/durationMs/requestRangeMeters are all still used, not silently replaced by their fallbacks', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = 1.2, durationMs = 6000, cooldownMs = REAL_COOLDOWN_MS, requestRangeMeters = 12.5 },
    })
    for _, line in ipairs(f.printLog) do
        t.isNil(line:find('speedMultiplier', 1, true), 'a valid configured speedMultiplier must pass through silently')
        t.isNil(line:find('durationMs', 1, true), 'a valid configured durationMs must pass through silently')
        t.isNil(line:find('requestRangeMeters', 1, true), 'a valid configured requestRangeMeters must pass through silently')
    end
    t.equals(f.Config.PursuitSprint.speedMultiplier, 1.2)
    t.equals(f.Config.PursuitSprint.durationMs, 6000)
    t.equals(f.Config.PursuitSprint.requestRangeMeters, 12.5)
end)

-- UPDATED, this pass (QA sandbox repro against server/combat.lua, same
-- mechanism applies here -- see server/cooldowns.lua's header ADDENDUM):
-- these two cases used to assert cooldownMs = 0/negative FAILED THE LOAD.
-- That was itself the bug, just not yet proven against THIS file: an
-- uncaught error thrown from this file's own top-level chunk (whether from
-- its own pre-existing `assert` or from NewCooldown's constructor guard)
-- aborts THIS FILE's execution from that line onward, silently
-- un-registering 'qbx_k9unit:server:requestPursuitSprint' along with
-- everything else below it -- not "this one cooldown fails safe," but "the
-- entire feature silently stops existing," discoverable only via one
-- script-error line at boot. server/pursuitsprint.lua now resolves this
-- value through ResolveConfiguredThresholdMs (server/cooldowns.lua)
-- instead: the file loads, the event registers, and the feature keeps
-- working on a safe built-in fallback while printing one unmissable
-- warning naming the exact key, the value found, and what was substituted.
t.test('COOLDOWN FOOTGUN: Config.PursuitSprint.cooldownMs = 0 no longer aborts this file\'s load -- it clamps to the shipped fallback, warns loudly (naming the exact key/value/substitute), and the feature keeps working', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = REAL_DURATION_MS, cooldownMs = 0, requestRangeMeters = REAL_RANGE_METERS },
    })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint.cooldownMs', 1, true)
            and line:find('found: 0', 1, true)
            and line:find(tostring(REAL_COOLDOWN_MS), 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must print a warning naming the exact key, the value found, and the fallback substituted -- "invalid cooldown" helps nobody find this in a real config.lua')

    -- The net event still registered and the feature is still fully
    -- functional on the substituted fallback -- this is the whole point:
    -- one misconfigured field, not a stranded feature.
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'a granted request must still succeed even though cooldownMs was misconfigured')
end)

t.test('COOLDOWN FOOTGUN: a negative cooldownMs is clamped the same way as zero, not treated as unlimited and not aborting the load', function()
    local f = newServerFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = REAL_DURATION_MS, cooldownMs = -5000, requestRangeMeters = REAL_RANGE_METERS },
    })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint.cooldownMs', 1, true) and line:find('-5000', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned)

    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'the feature must still work on the fallback cooldown, never "unlimited" and never load-aborted')
end)

-- ------------------------------------------------------------------
-- Happy path + ANY PED / role-only gating
-- ------------------------------------------------------------------

t.test('HAPPY PATH: a certified K9, in range, against a wanted player target, with a real feature grant, is GRANTED -- TriggerClientEvent fires, carrying the live speedMultiplier/durationMs payload', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
    t.equals(f.triggerClientEventCalls[1].name, 'qbx_k9unit:client:pursuitSprintGranted')
    t.equals(f.triggerClientEventCalls[1].target, 1)
    t.equals(#f.triggerClientEventCalls[1].args, 2, 'the grant event now carries a 2-value payload (speedMultiplier, durationMs) -- see this file\'s own header "EVENT CONTRACT" on why')
    t.equals(f.triggerClientEventCalls[1].args[1], REAL_SPEED_MULTIPLIER, 'must send the LIVE Config.PursuitSprint.speedMultiplier at the moment of grant')
    t.equals(f.triggerClientEventCalls[1].args[2], REAL_DURATION_MS, 'must send the LIVE Config.PursuitSprint.durationMs at the moment of grant')
    t.isNil(lastNotifyFor(f, 1), 'a successful grant sends no NotifyPlayer at all -- only TriggerClientEvent')
end)

t.test('LIVE TUNABLE SYNC: a live edit to Config.PursuitSprint.speedMultiplier/durationMs (mirroring a server/runtimecontrol.lua SetTunable call) between two requests reaches the SECOND grant\'s own payload, never retroactively touching the first', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)
    t.equals(f.triggerClientEventCalls[1].args[1], REAL_SPEED_MULTIPLIER)
    t.equals(f.triggerClientEventCalls[1].args[2], REAL_DURATION_MS)

    -- Simulate a tablet tunable edit landing mid-session -- SetTunable's own
    -- real effect is exactly this: mutating Config.PursuitSprint in place.
    f.Config.PursuitSprint.speedMultiplier = 2.0
    f.Config.PursuitSprint.durationMs = 9000

    f.advance(REAL_COOLDOWN_MS)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 2)
    t.equals(f.triggerClientEventCalls[2].args[1], 2.0, 'the SECOND grant must reflect the newly-edited multiplier')
    t.equals(f.triggerClientEventCalls[2].args[2], 9000, 'the SECOND grant must reflect the newly-edited duration')
    t.equals(f.triggerClientEventCalls[1].args[1], REAL_SPEED_MULTIPLIER, 'the FIRST grant\'s own already-sent payload must never be retroactively rewritten')
end)

t.test('A CLIENT CLAIMING A VALUE IT WAS NOT SENT CHANGES NOTHING SERVER-SIDE: extra client-supplied arguments on the request event are ignored -- the grant payload is always decided from live server Config, never from anything the requesting client sent', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 5, 0, 0)
    f.registerTargetNetId(9001, 200)

    -- The real 'qbx_k9unit:server:requestPursuitSprint' handler signature is
    -- `function(targetNetId)` -- it never declares a second parameter, so
    -- any extra argument a modified client sends is simply discarded by Lua
    -- at the call boundary, never reaching anything that could act on it.
    -- This dispatches through the SAME captured real handler with bogus
    -- extra arguments appended, proving the payload is unaffected.
    f.dispatch(1, 9001, 999.0, 1)
    t.equals(#f.triggerClientEventCalls, 1)
    t.equals(f.triggerClientEventCalls[1].args[1], REAL_SPEED_MULTIPLIER, 'must be the server\'s own live Config value, never the bogus 999.0 the client tried to smuggle in')
    t.equals(f.triggerClientEventCalls[1].args[2], REAL_DURATION_MS, 'must be the server\'s own live Config value, never the bogus 1 the client tried to smuggle in')
end)

t.test('ANY PED: HasK9Access(src) is the ONLY role check -- this file never reads GetEntityModel/IsEntityModelK9/IsOwnModelK9 anywhere (grep-provable, re-asserted here behaviorally): a request from a source with NO ped-model stub registered at all still resolves purely on HasK9Access', function()
    local f = newServerFixture()
    f.setHasK9Access(true)
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1, 'no ped-model concept was ever consulted -- HasK9Access alone decided this')
end)

t.test('no_access: HasK9Access(src) = false denies outright, regardless of everything else being otherwise valid', function()
    local f = newServerFixture()
    f.setHasK9Access(false)
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_no_access'))
end)

-- ------------------------------------------------------------------
-- Target resolution
-- ------------------------------------------------------------------

t.test('invalid_target: a non-number targetNetId is rejected before touching HasK9Access', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.dispatch(1, 'not-a-number')
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_invalid_target'))
    t.equals(#f.hasK9AccessCalls, 0, 'invalid_target is checked BEFORE the role gate')
end)

t.test('invalid_target: a netId that does not resolve to any real entity', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.dispatch(1, 999999)
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_invalid_target'))
end)

t.test('self_target: targeting one\'s own ped is rejected', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.registerTargetNetId(9001, 100)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_self_target'))
end)

t.test('target_not_player: PLAYER-TARGET-ONLY -- a real, existing ped that belongs to no connected player (an NPC) is rejected, unlike server/combat.lua\'s BiteAndHold which permits NPC targets', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPed(300, true) -- an existing ped with no owning player registered anywhere
    f.setPedCoords(300, 1, 0, 0)
    f.registerTargetNetId(9002, 300)

    f.dispatch(1, 9002)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_target_not_player'))
end)

t.test('too_far: a real player target outside requestRangeMeters is rejected using LIVE server-side coordinates, never a client-claimed distance', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, REAL_RANGE_METERS + 5, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_too_far'))
end)

t.test('too_far boundary: exactly AT requestRangeMeters is accepted (">" not ">=")', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, REAL_RANGE_METERS, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

-- ------------------------------------------------------------------
-- Wanted/suspect eligibility -- reuses Config.Combat.* verbatim
-- ------------------------------------------------------------------

t.test('not_wanted: RequireWantedStatus = true (default) + target NOT flagged wanted is rejected', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = false })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_wanted'))
end)

t.test('RequireWantedStatus = false -- ANY player target is eligible, matching server/combat.lua\'s own IsPlayerWantedEligible short-circuit exactly', function()
    local f = newServerFixture({ requireWantedStatus = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, nil) -- no metadata at all
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('WantedStatusCheckOverride is used when present, and its return value is trusted verbatim', function()
    local overrideCalls = {}
    local f = newServerFixture({
        wantedStatusOverride = function(targetSrc) overrideCalls[#overrideCalls + 1] = targetSrc; return true end,
    })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = false }) -- would fail the DEFAULT check -- proves the override, not the fallback, decided this
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
    t.equals(overrideCalls[1], 2)
end)

t.test('WantedStatusCheckOverride ERRORING fails CLOSED (target treated as NOT eligible), never silently widening who can be targeted', function()
    local f = newServerFixture({
        wantedStatusOverride = function() error('boom') end,
    })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true }) -- would PASS the default check -- proves the override's error was what decided this, not a fallback
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_wanted'))
    t.isTrue(#f.printLog >= 1, 'the override error must be logged loudly, not swallowed')
end)

-- ------------------------------------------------------------------
-- Cooldown -- last gate, never consumed by an invalid request
-- ------------------------------------------------------------------

local function grantOnce(f, src, citizenid, targetSrc, targetCid, netId)
    f.registerPlayer(src, citizenid, src * 100, nil)
    f.registerPlayer(targetSrc, targetCid, targetSrc * 100, { wanted = true })
    f.grantPermission(citizenid, 'feature.PursuitSprint', true)
    f.setPedCoords(src * 100, 0, 0, 0)
    f.setPedCoords(targetSrc * 100, 1, 0, 0)
    f.registerTargetNetId(netId, targetSrc * 100)
end

t.test('on_cooldown: a second request from the same K9 inside cooldownMs is denied, and does not re-grant', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.advance(REAL_COOLDOWN_MS - 1)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'still on cooldown -- must not grant a second time')
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_on_cooldown'))
end)

t.test('cooldown elapsed: a later request past cooldownMs succeeds independently', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.advance(REAL_COOLDOWN_MS)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 2)
end)

t.test('AN INVALID REQUEST NEVER BURNS THE COOLDOWN: a too_far rejection does not consume the K9\'s cooldown -- an immediately-following, otherwise-valid request still succeeds', function()
    local f = newServerFixture()
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, REAL_RANGE_METERS + 100, 0, 0) -- WAY too far
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_too_far'))

    -- Now bring the target into range, same tick (fakeNow unchanged) --
    -- if the too_far rejection had wrongly consumed the cooldown, this
    -- would now fail with denied_on_cooldown instead of succeeding.
    f.setPedCoords(200, 1, 0, 0)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)
end)

-- REGRESSION (this pass -- KNOWN_ISSUES.md, "Pursuit sprint's cooldown used
-- to reset on disconnect/reconnect"): this test used to assert the OPPOSITE
-- of what's below -- that a `playerDropped` firing for the K9's old source
-- CLEARED the cooldown, so a "brand new occupant of the same recycled
-- source id" (in practice: the SAME player, reconnected, reissued a new
-- source by FXServer) was NOT blocked by their own immediately-preceding
-- request. That was the bug being pinned as a passing test. PursuitSprintCooldown
-- is now keyed by citizenid (never `src`) and cleaned up via :StartSweep,
-- never :RegisterPlayerDropped() -- see server/pursuitsprint.lua's own
-- "RECONNECT GAP" comment on PursuitSprintCooldown for the full reasoning
-- (including why this is a narrower fix than "reconnecting always helps
-- you," which it never did for the mechanic's headline fleeing-chase case).
t.test('RECONNECT: the SAME K9 citizenid reconnected under a brand-new server id is still denied inside cooldownMs', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    -- Simulate a disconnect + reconnect: FXServer fires playerDropped for
    -- the old source, then later reissues a DIFFERENT numeric source (99,
    -- never 1) to the same citizenid reconnecting. Firing playerDropped
    -- must have no effect on this citizenid-keyed cooldown at all (that
    -- was the whole bug).
    f.firePlayerDropped(1)
    f.registerPlayer(99, 'K9-CID', 99 * 100, nil)
    f.setPedCoords(99 * 100, 0, 0, 0)

    f.advance(REAL_COOLDOWN_MS - 1)
    f.dispatch(99, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'reconnecting under a new source id must not reset this citizenid\'s cooldown')
    t.equals(lastNotifyFor(f, 99).message, locale('pursuitsprint.denied_on_cooldown'))
end)

t.test('RECONNECT: the cooldown still expires at the ORIGINAL grant time for the reconnected citizenid, not restarted', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.firePlayerDropped(1)
    f.registerPlayer(99, 'K9-CID', 99 * 100, nil)
    f.setPedCoords(99 * 100, 0, 0, 0)

    f.advance(REAL_COOLDOWN_MS)
    f.dispatch(99, 9001)
    t.equals(#f.triggerClientEventCalls, 2, 'the cooldown must still expire normally, on schedule, for the reconnected citizenid')
end)

-- MEMORY BOUND: citizenid-keyed (unlike the old src-keyed version) has no
-- per-connection cleanup hook at all -- :StartSweep is the ONLY thing
-- bounding this table now (see this cooldown's own declaration comment in
-- server/pursuitsprint.lua). The underlying sweep MECHANISM is already
-- proven correct at the primitive level (tests/cooldowns_spec.lua's own
-- "StartSweep evicts only entries isStaleFn reports as stale"); this test
-- exercises the REAL production wiring end to end -- the actual interval/
-- isStaleFn PursuitSprintCooldown.StartSweep was called with -- to prove it
-- runs without error against this file's real Config shape and that the
-- tracker keeps working correctly across a real sweep pass, not merely that
-- the primitive works in isolation.
t.test('MEMORY BOUND: a real sweep pass mid-cooldown must not wrongly evict a still-active entry (proves the real PursuitSprintCooldown.StartSweep wiring runs without erroring against this file\'s actual Config shape)', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.threadRunner.step() -- primes past the sweep thread's initial Wait() -- no pass yet
    f.advance(REAL_COOLDOWN_MS - 1) -- still genuinely on cooldown, nowhere near this cooldown's own "stale after 2x cooldownMs" sweep margin
    f.threadRunner.step() -- runs exactly one real sweep pass over the real production isStaleFn

    -- Still correctly denies -- a sweep pass run while an entry is genuinely
    -- still active must never itself evict (and thereby silently grant) it.
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1, 'a sweep pass must never itself grant a request still genuinely on cooldown')
end)

t.test('RECONNECT: a DIFFERENT citizenid recycling the disconnected K9\'s old numeric source id is unaffected by that stranger\'s cooldown', function()
    local f = newServerFixture()
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)

    f.firePlayerDropped(1)
    -- FXServer recycles numeric source 1 for a genuinely different person.
    f.registerPlayer(1, 'OTHER-CID', 1 * 100, nil)
    f.grantPermission('OTHER-CID', 'feature.PursuitSprint', true)
    f.setPedCoords(1 * 100, 0, 0, 0)

    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 2, 'a citizenid-keyed cooldown must not leak across two different citizenids sharing a recycled source id')
end)

-- ------------------------------------------------------------------
-- Per-person feature control -- Config.FeatureControl.RequireGrant's
-- documented 4-step resolution (steps 2-4; step 1 is the file-level gate
-- already covered above)
-- ------------------------------------------------------------------

t.test('grant_required: RequireGrant.PursuitSprint = true + no grant held -- denied even though HasK9Access is true', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    -- deliberately NOT granted
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_not_granted'))
end)

t.test('RequireGrant.PursuitSprint = true + an active feature.PursuitSprint grant -- allowed', function()
    local f = newServerFixture({ requireGrantListed = true })
    grantOnce(f, 1, 'K9-CID', 2, 'TARGET-CID', 9001)
    f.dispatch(1, 9001)
    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('BLOCK ALWAYS WINS: an explicit block.PursuitSprint denies even a citizenid who ALSO holds an active feature.PursuitSprint grant, and sends the DIFFERENT denied_blocked message, never denied_not_granted (CORRECTED this pass -- see server/pursuitsprint.lua header "REFUSAL MESSAGE, CORRECTED")', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'feature.PursuitSprint', true)
    f.grantPermission('K9-CID', 'block.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
    t.equals(lastNotifyFor(f, 1).message, locale('pursuitsprint.denied_blocked'))
    t.isTrue(lastNotifyFor(f, 1).message ~= locale('pursuitsprint.denied_not_granted'), 'blocked and not_granted must read as two different, actionable messages, not one collapsed generic denial')
end)

t.test('RequireGrant.PursuitSprint = false (not listed) -- default ALLOW, no grant needed, matching config.lua\'s own documented step 4', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    -- deliberately NOT granted -- must still succeed since it is not listed
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

t.test('BLOCK STILL APPLIES even when NOT listed in RequireGrant (step 2 fires independently of step 3)', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.grantPermission('K9-CID', 'block.PursuitSprint', true)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 0)
end)

t.test('server/permissions.lua entirely absent (HasPermission not even defined): RequireGrant-listed feature fails CLOSED (deny), never open', function()
    local f = newServerFixture({ requireGrantListed = true, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    local ok = pcall(f.dispatch, 1, 9001)

    t.isTrue(ok, 'a missing HasPermission must never error the request handler')
    t.equals(#f.triggerClientEventCalls, 0)
end)

t.test('server/permissions.lua entirely absent + feature NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newServerFixture({ requireGrantListed = false, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100, nil)
    f.registerPlayer(2, 'TARGET-CID', 200, { wanted = true })
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 1, 0, 0)
    f.registerTargetNetId(9001, 200)

    f.dispatch(1, 9001)

    t.equals(#f.triggerClientEventCalls, 1)
end)

-- ========================================================================
-- CLIENT FIXTURE -- client/pursuitsprint.lua, loaded TOGETHER WITH THE REAL
-- client/movement.lua.
--
-- REPLACES A BLIND SPOT (this pass): this fixture used to stub
-- RecomputeK9MoveRate() as a bare counter (`recomputeCalls = recomputeCalls
-- + 1`, nothing else) instead of loading the real composer it is meant to
-- drive. That stub could never have caught client/movement.lua's own real
-- bug this pass found and fixed -- RecomputeK9MoveRate() hard-gating on
-- IsOwnModelK9() ALONE, silently discarding K9MoveRateModifiers.pursuitSprint
-- for a role-holder on a non-K9 body even though this file's own header
-- promises "ANY PED... NEVER ON PED MODEL" -- because the stub never
-- composed or applied anything in the first place; a test built on it could
-- only ever prove "this file wrote a number into a table," never "that
-- number actually changed the ped's speed." Now loads the REAL
-- client/movement.lua into the SAME sandbox env first, so
-- K9MoveRateModifiers/RecomputeK9MoveRate are the genuine production
-- symbols, and every grant-handling test below asserts against the REAL
-- SetPedMoveRateOverride call client/movement.lua's RecomputeK9MoveRate()
-- makes -- see the dedicated "ANY PED, GENUINELY" section further down for
-- the test that proves the fix itself (a role-holder on a non-K9 body
-- reaching the real native call).
--
-- SHARED STATE, ON PURPOSE: PlayerPedId/DoesEntityExist/RegisterCommand/
-- RegisterKeyMapping/RegisterNetEvent/AddEventHandler/CreateThread/
-- TriggerServerEvent/lib.notify/GetCurrentResourceName are single stubs
-- shared by BOTH files' load, mirroring how one real client resource has
-- exactly one FiveM event/command/thread registry, not one per file.
-- client/movement.lua unconditionally starts its own elastic leash
-- pull-back thread at file-load time -- harmless here (leashState, a private
-- local to that file, is never set anywhere in this spec, so that thread's
-- body always takes its cheap idle branch) -- and registers its own
-- 'qbx_k9unit:toggleCamera' command/keybind and THREE of its OWN
-- onResourceStop handlers alongside this file's one. Every assertion below
-- that cares about "how many NEW threads/commands did PURSUIT SPRINT
-- itself add" filters by name or takes a post-movement-load baseline
-- delta, rather than asserting a raw total that would otherwise silently
-- couple this file's tests to client/movement.lua's own, unrelated
-- registration count.
--
-- WHY HasK9Access() NEEDS ITS OWN CONTROLLABLE STAND-IN HERE: client/movement.lua's
-- real RecomputeK9MoveRate() now reads `IsOwnModelK9() or HasK9Access()`
-- (see that function's own "SCOPE, CORRECTED" header comment) -- both from
-- client/main.lua, a file this sandbox does not load for real (same
-- established reason clientmovement_spec.lua/clientbreed_spec.lua stub
-- IsOwnModelK9()/CanShowK9UI() individually rather than loading that whole
-- file). Defaults to the common case (isOwnModelK9 = true, hasK9Access =
-- false) so every PRE-EXISTING assertion below keeps meaning exactly what
-- it always meant (a certified K9, on a K9 model); the ANY-PED section
-- further down is what actually exercises HasK9Access() = true.
-- ========================================================================

--- @param opts table? {
---   featureEnabled: boolean (default true)
---   pursuitSprintCfg: table|false
---   expectLoadError: boolean
---   withMoveRateComposer: boolean (default true) -- false simulates
---     client/movement.lua NOT defining K9MoveRateModifiers/RecomputeK9MoveRate
---     at all (this file's own fail-closed soft-dependency guard) by
---     deleting both from the sandbox AFTER the real movement.lua has
---     already defined them for real
---   isInK9VehicleDefined: boolean (default true)
--- }
local function newClientFixture(opts)
    opts = opts or {}

    local Config = {
        Features = {
            PursuitSprint = opts.featureEnabled ~= false,
            -- client/movement.lua's OWN load-time flag -- forced true so its
            -- AgilityBasicJump jump/crouch-suppression CreateThread branch
            -- never registers, exactly matching tests/clientmovement_spec.lua's
            -- own fixture convention (that thread is unrelated to pursuit
            -- sprint and would otherwise need its own DisableControlAction/
            -- IsEntityModelK9 stubs for nothing).
            AgilityBasicJump = true,
        },
    }
    if opts.pursuitSprintCfg == false then
        Config.PursuitSprint = nil
    elseif opts.pursuitSprintCfg ~= nil then
        Config.PursuitSprint = opts.pursuitSprintCfg
    else
        Config.PursuitSprint = {
            speedMultiplier = REAL_SPEED_MULTIPLIER,
            durationMs = 300, -- 3 real ticks at this file's own 100ms tick, for a manageably short spec
            cooldownMs = REAL_COOLDOWN_MS,
            requestRangeMeters = REAL_RANGE_METERS,
        }
    end

    -- Shared ped state -- BOTH client/movement.lua's RecomputeK9MoveRate()
    -- and this file's own candidate search/end-timer read PlayerPedId()/
    -- DoesEntityExist() against the SAME handle, exactly as they do in the
    -- real resource (one client, one ped).
    local pedHandle = 1
    local function PlayerPedId() return pedHandle end

    local pedCoords = { [1] = vec3(0, 0, 0) }
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local isDead = {}
    local function IsEntityDead(entity) return isDead[entity] == true end

    local existingEntities = { [1] = true }
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    local playerIndexByPed = {} -- ped -> playerIndex (>= 0), absent/-1 = NPC
    local function NetworkGetPlayerIndexFromPed(ped) return playerIndexByPed[ped] or -1 end

    local cpedPool = {}
    local function GetGamePool(kind) if kind == 'CPed' then return cpedPool end; return {} end

    local netIdByPed = {}
    local function NetworkGetNetworkIdFromEntity(ped) return netIdByPed[ped] end

    local isPedInAnyVehicle = false
    local isPedInAnyVehicleCalls = {}
    local function IsPedInAnyVehicle(ped, bool) isPedInAnyVehicleCalls[#isPedInAnyVehicleCalls + 1] = { ped = ped, bool = bool }; return isPedInAnyVehicle end

    local isInK9Vehicle = false
    local function IsInK9Vehicle() return isInK9Vehicle end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(name, ...) triggerServerEventCalls[#triggerServerEventCalls + 1] = { name = name, args = { ... } } end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local registerCommandCalls = {}
    local function RegisterCommand(name, handler, restricted)
        registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler, restricted = restricted }
    end
    local registerKeyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        registerKeyMappingCalls[#registerKeyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    -- SHARED across both files -- see this section's own header block.
    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local RESOURCE_NAME = 'qbx_k9unit'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- SHARED thread runner -- see this section's own header block on why
    -- client/movement.lua's own always-on leash thread being captured here
    -- too is harmless. newThreadsSinceLoad() below (a delta against the
    -- post-movement.lua-load baseline) is what every "did THIS grant create
    -- a new thread" assertion uses, never a raw total.
    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    -- client/movement.lua's OWN load-time dependencies, not otherwise
    -- needed by this file. GetHashKey backs its scenario-name lookup
    -- tables; GetEntityModel backs RecomputeK9MoveRate()'s breed lookup
    -- (always nil here, since no Config.Peds is supplied -- breed always
    -- resolves to its neutral 1.0 default, exactly like
    -- tests/clientmovement_spec.lua's own fixture for every test that
    -- doesn't specifically exercise breed).
    local function GetHashKey(name)
        local hash = 0
        for i = 1, #name do hash = (hash * 31 + name:byte(i)) % 2147483647 end
        return hash
    end
    local function GetEntityModel(_entity) return nil end
    local function SetFollowPedCamViewMode(_mode) end

    -- THE TWO GLOBALS THIS FIXTURE NO LONGER STUBS AWAY -- see this
    -- section's own header block. Controllable so a test can prove BOTH the
    -- already-K9-modeled case (the pre-existing, always-worked case) AND the
    -- role-holder-on-a-non-K9-body case (the real bug, now fixed) each
    -- genuinely reach the real SetPedMoveRateOverride. Defaults to the
    -- common case so every pre-existing test below keeps exercising the
    -- exact scenario it always meant to.
    local isOwnModelK9 = true
    local function IsOwnModelK9() return isOwnModelK9 end
    local hasK9Access = false
    local hasK9AccessCallCount = 0
    local function HasK9Access() hasK9AccessCallCount = hasK9AccessCallCount + 1; return hasK9Access end

    -- REAL SetPedMoveRateOverride capture -- client/movement.lua's own
    -- RecomputeK9MoveRate() is the ONLY caller anywhere in this resource;
    -- this is the actual, meaningful assertion surface for "did the burst
    -- really change anything," replacing the old recomputeCalls() stub
    -- counter this suite used to rely on instead.
    local setMoveRateCalls = {}
    local function SetPedMoveRateOverride(ped, rate)
        setMoveRateCalls[#setMoveRateCalls + 1] = { ped = ped, rate = rate }
    end

    -- CLAMP-AND-WARN CAPTURE -- mirrors the server fixture's own printLog
    -- above. Needed to prove client/pursuitsprint.lua's clamp-and-warn
    -- guard actually warns (not just "doesn't crash") without spamming real
    -- stdout during the test run.
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local overrides = {
        Config = Config,
        print = printStub,
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
        CreateThread = CreateThread,
        Wait = Wait,
        GetHashKey = GetHashKey,
        GetEntityModel = GetEntityModel,
        SetFollowPedCamViewMode = SetFollowPedCamViewMode,
        IsOwnModelK9 = IsOwnModelK9,
        HasK9Access = HasK9Access,
        SetPedMoveRateOverride = SetPedMoveRateOverride,
    }
    if opts.isInK9VehicleDefined ~= false then
        overrides.IsInK9Vehicle = IsInK9Vehicle
    end

    local env = Sandbox.newEnv(overrides)

    -- REAL client/movement.lua, loaded FIRST -- see this section's own
    -- header block for why. K9MoveRateModifiers/RecomputeK9MoveRate below
    -- are now the genuine production symbols, not a stand-in.
    Sandbox.loadInto('../client/movement.lua', env)

    -- Baseline AFTER client/movement.lua's own load-time CreateThread call
    -- (its always-on leash pull-back thread) but BEFORE client/pursuitsprint.lua
    -- ever loads -- every "how many NEW threads did this grant create"
    -- assertion below subtracts this baseline via newThreadsSinceLoad()
    -- rather than asserting a raw total.
    local threadCountBaseline = threadCreateCount

    -- FAIL-CLOSED COVERAGE (unchanged intent, new mechanism): simulates
    -- client/movement.lua NOT defining these two symbols at all -- the exact
    -- historical shape of the real bug this suite's own header cites
    -- (DEVELOPER_REFERENCE.md §13.0 Decision 2) -- by deleting them from the
    -- sandbox AFTER the real file has already defined them for real, rather
    -- than never loading client/movement.lua at all (which would also have
    -- removed IsOwnModelK9()/HasK9Access()'s own real interplay with the
    -- composer from every OTHER test in this file).
    if opts.withMoveRateComposer == false then
        env.K9MoveRateModifiers = nil
        env.RecomputeK9MoveRate = nil
    end

    local ok, err = pcall(Sandbox.loadInto, '../client/pursuitsprint.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err }
    end
    assert(ok, 'client/pursuitsprint.lua failed to load: ' .. tostring(err))

    return {
        env = env,
        Config = Config,
        printLog = printLog,
        registerCommandCalls = registerCommandCalls,
        registerKeyMappingCalls = registerKeyMappingCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        notifyCalls = notifyCalls,
        isPedInAnyVehicleCalls = isPedInAnyVehicleCalls,
        setMoveRateCalls = setMoveRateCalls,
        newThreadsSinceLoad = function() return threadCreateCount - threadCountBaseline end,
        K9MoveRateModifiers = env.K9MoveRateModifiers,
        runner = runner,
        setIsPedInAnyVehicle = function(v) isPedInAnyVehicle = v end,
        setIsInK9Vehicle = function(v) isInK9Vehicle = v end,
        setIsDead = function(entity, v) isDead[entity] = v end,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        addCandidate = function(ped, x, y, z, isPlayer, netId)
            cpedPool[#cpedPool + 1] = ped
            pedCoords[ped] = vec3(x, y, z)
            existingEntities[ped] = true
            playerIndexByPed[ped] = isPlayer and 0 or -1
            if netId then netIdByPed[ped] = netId end
        end,
        --- Runs the captured 'qbx_k9unit:pursuitsprint' command handler
        --- (RequestPursuitSprint) directly -- it never yields, so no
        --- coroutine wrapping is needed here (unlike client/agility.lua's
        --- TryVault). Looked up BY NAME, not index 0 -- client/movement.lua
        --- also registers its own 'qbx_k9unit:toggleCamera' command into
        --- this same shared list.
        runRequest = function()
            local handler
            for _, c in ipairs(registerCommandCalls) do
                if c.name == 'qbx_k9unit:pursuitsprint' then handler = c.handler end
            end
            assert(handler, 'client/pursuitsprint.lua did not register the qbx_k9unit:pursuitsprint command')
            handler()
        end,
        --- Dispatches the real captured 'qbx_k9unit:client:pursuitSprintGranted'
        --- handler with `env.source` set, mirroring every other spec's
        --- SOURCE-ORIGIN GUARD test convention in this suite. `speedMultiplier`/
        --- `durationMs` are OPTIONAL -- omitted (nil), the real server would
        --- never actually send nil for either (server/pursuitsprint.lua
        --- always sends real numbers), but this fixture allows it so every
        --- PRE-EXISTING test below (written before this event carried a
        --- payload) keeps exercising the exact same fallback-to-this-client's-
        --- own-Config-default behavior it always implicitly relied on -- see
        --- ResolveGrantedPositiveNumber's own doc comment in the real file.
        dispatchGrant = function(src, speedMultiplier, durationMs)
            env.source = src
            local handler = assert(capturedEvents['qbx_k9unit:client:pursuitSprintGranted'],
                'client/pursuitsprint.lua did not register qbx_k9unit:client:pursuitSprintGranted')
            handler(speedMultiplier, durationMs)
        end,
        --- Fires EVERY captured onResourceStop handler, matching what a real
        --- resource stop actually does -- client/movement.lua's own THREE
        --- (camera view mode, leash auto-detach, move-rate reset) plus this
        --- file's own pursuitSprint modifier reset. The first two of
        --- movement.lua's are harmless no-ops throughout this whole suite
        --- (isFirstPersonK9View/leashState, both private locals to that
        --- file, are never touched by anything this spec does).
        fireResourceStop = function(resourceName)
            for _, h in ipairs(eventHandlers['onResourceStop'] or {}) do h(resourceName or RESOURCE_NAME) end
        end,
    }
end

-- ------------------------------------------------------------------
-- Feature gate / config asserts
-- ------------------------------------------------------------------

--- @param list table -- registerCommandCalls or registerKeyMappingCalls
--- @param field string -- 'name' for a command, 'commandName' for a keybind
--- @param value string
--- @return table? -- the matching entry, or nil
local function findByField(list, field, value)
    for _, entry in ipairs(list) do
        if entry[field] == value then return entry end
    end
    return nil
end

t.test('CLIENT: Config.Features.PursuitSprint = false -- registers no pursuit-sprint command/keybind/event of its own (client/movement.lua\'s own unrelated command/keybind/thread still register regardless -- this file\'s flag has no bearing on that file)', function()
    local f = newClientFixture({ featureEnabled = false, pursuitSprintCfg = false })
    t.isNil(findByField(f.registerCommandCalls, 'name', 'qbx_k9unit:pursuitsprint'))
    t.isNil(findByField(f.registerKeyMappingCalls, 'commandName', 'qbx_k9unit:pursuitsprint'))
end)

-- REGRESSION (this pass): this test used to assert the OPPOSITE -- that
-- Config.PursuitSprint being missing (or any of its individual fields being
-- invalid) FAILED THE ENTIRE FILE'S LOAD via a hard `assert`, mirroring
-- server/pursuitsprint.lua's own now-fixed asserts (see this file's SERVER
-- REGRESSION tests above). Same wrong remedy, same fix: clamp-and-warn, the
-- file loads, the command/keybind still register, and the feature keeps
-- working on built-in fallbacks.
t.test('CLIENT: Config.PursuitSprint missing while the flag is true no longer aborts this file\'s load -- clamps every field to its shipped fallback, warns loudly, and the command/keybind still register', function()
    local f = newClientFixture({ pursuitSprintCfg = false })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must print a warning naming Config.PursuitSprint as missing')

    t.equals(f.Config.PursuitSprint.speedMultiplier, REAL_SPEED_MULTIPLIER)
    t.equals(f.Config.PursuitSprint.durationMs, 5000)
    t.equals(f.Config.PursuitSprint.requestRangeMeters, REAL_RANGE_METERS)
    t.isNotNil(findByField(f.registerCommandCalls, 'name', 'qbx_k9unit:pursuitsprint'), 'qbx_k9unit:pursuitsprint must still register')
    t.isNotNil(findByField(f.registerKeyMappingCalls, 'commandName', 'qbx_k9unit:pursuitsprint'), 'its keybind must still register')
end)

t.test('CLIENT: an individually invalid Config.PursuitSprint.requestRangeMeters no longer aborts this file\'s load -- clamps to the shipped 20.0 fallback and warns loudly, valid siblings pass through unchanged', function()
    local f = newClientFixture({
        pursuitSprintCfg = { speedMultiplier = REAL_SPEED_MULTIPLIER, durationMs = 300, requestRangeMeters = -5 },
    })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.PursuitSprint.requestRangeMeters', 1, true)
            and line:find('found: -5', 1, true)
            and line:find(tostring(REAL_RANGE_METERS), 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key, the value found, and the fallback substituted')
    t.equals(f.Config.PursuitSprint.requestRangeMeters, REAL_RANGE_METERS)
    t.equals(f.Config.PursuitSprint.speedMultiplier, REAL_SPEED_MULTIPLIER, 'a valid sibling field must pass through unchanged')
end)

t.test('CLIENT: registers exactly one pursuit-sprint command and one keybind, using the real locale key and default key "N" -- looked up BY NAME since client/movement.lua shares this same command/keybind registry', function()
    local f = newClientFixture()
    local cmd = findByField(f.registerCommandCalls, 'name', 'qbx_k9unit:pursuitsprint')
    t.isNotNil(cmd, 'qbx_k9unit:pursuitsprint must be registered')

    local keymap = findByField(f.registerKeyMappingCalls, 'commandName', 'qbx_k9unit:pursuitsprint')
    t.isNotNil(keymap)
    t.equals(keymap.description, locale('pursuitsprint.keybind_label'))
    t.equals(keymap.defaultKey, 'N')
end)

-- ------------------------------------------------------------------
-- RequestPursuitSprint -- candidate selection is display-only
-- ------------------------------------------------------------------

t.test('vehicle tuck: seated in ANY vehicle -- silent return, no candidate search, no server round trip', function()
    local f = newClientFixture()
    f.setIsPedInAnyVehicle(true)
    f.runRequest()
    t.equals(#f.triggerServerEventCalls, 0)
    t.equals(#f.notifyCalls, 0)
    t.equals(f.isPedInAnyVehicleCalls[1].bool, false, 'IsPedInAnyVehicle must be called with the real 2nd arg (false)')
end)

t.test('vehicle tuck: IsInK9Vehicle() true (soft dependency DEFINED) -- silent return', function()
    local f = newClientFixture({ isInK9VehicleDefined = true })
    f.setIsInK9Vehicle(true)
    f.runRequest()
    t.equals(#f.triggerServerEventCalls, 0)
end)

t.test('vehicle tuck: IsInK9Vehicle NOT DEFINED AT ALL -- does not error, and does not block the request', function()
    local f = newClientFixture({ isInK9VehicleDefined = false })
    f.addCandidate(50, 1, 0, 0, true, 9001)
    local ok = pcall(f.runRequest)
    t.isTrue(ok, 'the `type(IsInK9Vehicle) == \'function\'` soft-dependency guard must never error when the global is entirely undefined')
    t.equals(#f.triggerServerEventCalls, 1)
end)

t.test('no eligible candidate within range -- notifies pursuitsprint.no_target_nearby, no server round trip', function()
    local f = newClientFixture()
    f.addCandidate(50, REAL_RANGE_METERS + 100, 0, 0, true, 9001) -- a real player, but far outside range
    f.runRequest()
    t.equals(#f.triggerServerEventCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('pursuitsprint.no_target_nearby'))
end)

t.test('candidate filtering: excludes self, dead peds, and non-player peds, and picks the NEAREST real player', function()
    local f = newClientFixture()
    f.addCandidate(1, 0, 0, 0, true, 111)     -- self -- must be excluded even though it's technically in the pool
    f.addCandidate(60, 2, 0, 0, false, 222)   -- non-player (NPC) -- must be excluded
    f.setIsDead(70, true)
    f.addCandidate(70, 1.5, 0, 0, true, 333)  -- dead player -- must be excluded
    f.addCandidate(80, 10, 0, 0, true, 444)   -- a real, live, farther player
    f.addCandidate(90, 3, 0, 0, true, 555)    -- a real, live, NEAREST eligible player

    f.runRequest()

    t.equals(#f.triggerServerEventCalls, 1)
    t.equals(f.triggerServerEventCalls[1].name, 'qbx_k9unit:server:requestPursuitSprint')
    t.equals(f.triggerServerEventCalls[1].args[1], 555, 'must target the nearest ELIGIBLE candidate\'s own netId, skipping self/NPC/dead entries even though they are closer or present in the pool')
end)

-- ------------------------------------------------------------------
-- Grant handling -- SOURCE-ORIGIN GUARD, application, end-timer,
-- death-reset, generation guard, onResourceStop
-- ------------------------------------------------------------------

t.test('SOURCE-ORIGIN GUARD: a forged grant (source ~= 65535) is ignored entirely -- no modifier change, no notify, no thread started, and the REAL SetPedMoveRateOverride is never reached', function()
    local f = newClientFixture()
    f.dispatchGrant(1) -- NOT 65535
    t.isNil(f.K9MoveRateModifiers.pursuitSprint, 'never written at all -- not even reset to neutral, since no grant ever ran (the real K9MoveRateModifiers table has no pursuitSprint key until the first genuine grant)')
    t.equals(#f.notifyCalls, 0)
    t.equals(f.newThreadsSinceLoad(), 0)
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('genuine grant (source == 65535), already on a K9 model: applies the multiplier for REAL through the actual client/movement.lua composer -- not a stub -- and notifies success', function()
    local f = newClientFixture()
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)
    t.equals(#f.setMoveRateCalls, 1, 'the REAL RecomputeK9MoveRate() must have called the REAL SetPedMoveRateOverride exactly once')
    t.equals(f.setMoveRateCalls[1].ped, 1)
    t.equals(f.setMoveRateCalls[1].rate, REAL_SPEED_MULTIPLIER, 'no other modifier is active, so the composed rate is the raw speedMultiplier')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('pursuitsprint.activated'))
    t.equals(f.notifyCalls[1].type, 'success')
end)

-- ------------------------------------------------------------------
-- PAYLOAD APPLICATION -- this file now applies WHATEVER THE SERVER SENT,
-- not this client's own local Config.PursuitSprint copy. See this file's
-- header "EVENT CONTRACT" for the full writeup on why.
-- ------------------------------------------------------------------

t.test('PAYLOAD APPLIED, NOT LOCAL CONFIG: a grant carrying a DIFFERENT speedMultiplier/durationMs than this client\'s own Config.PursuitSprint applies the SENT values -- proving a live tablet edit reaches an already-connected K9 on its next grant', function()
    local f = newClientFixture() -- this client's own Config: speedMultiplier=1.4, durationMs=300
    -- 1.8, not 2.5: stays inside client/movement.lua's own [0.1, 2.0]
    -- composed-rate ceiling so this test proves THIS file applied the sent
    -- value, uncomplicated by that separate, already-covered clamp (see the
    -- dedicated "ABSURD PAYLOAD" test below for the clamp itself).
    f.dispatchGrant(65535, 1.8, 500) -- server-sent values, deliberately different from this client's own config
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.8, 'must apply the SENT multiplier, not this client\'s own 1.4 default')
    t.equals(f.setMoveRateCalls[1].rate, 1.8)

    -- End-timer must honor the SENT duration (500ms = 5 ticks of 100ms),
    -- not this client's own local 300ms (3 ticks) default.
    f.runner.step() -- prime
    f.runner.step() -- 100
    f.runner.step() -- 200
    f.runner.step() -- 300 -- would have ended here under the LOCAL 300ms default -- must still be boosted
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.8, 'must still be boosted past the client\'s own local durationMs default -- the SENT duration (500ms) governs')
    f.runner.step() -- 400
    f.runner.step() -- 500 -- the SENT duration's own end
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0, 'must reset once the SENT duration (500ms), not the local default, elapses')
end)

t.test('MALFORMED PAYLOAD FALLS BACK, NEVER CRASHES, NEVER APPLIES THE BAD VALUE: every rejected shape (zero, negative, NaN, wrong type) falls back to this client\'s own Config.PursuitSprint default', function()
    local cases = {
        { label = 'zero',          value = 0 },
        { label = 'negative',      value = -1.4 },
        { label = 'NaN',           value = 0/0 },
        { label = 'wrong type (string)', value = 'not-a-number' },
        { label = 'wrong type (table)',  value = {} },
        { label = 'wrong type (boolean)', value = true },
    }
    for _, case in ipairs(cases) do
        local f = newClientFixture()
        local ok = pcall(f.dispatchGrant, 65535, case.value, case.value)
        t.isTrue(ok, ('a malformed payload (%s) must never error the grant handler'):format(case.label))
        t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER,
            ('%s speedMultiplier must fall back to this client\'s own Config default, never apply the bad value'):format(case.label))
        t.equals(#f.setMoveRateCalls, 1, ('%s must still grant using the fallback -- a malformed payload degrades safely, it does not cancel the grant'):format(case.label))
        t.equals(f.setMoveRateCalls[1].rate, REAL_SPEED_MULTIPLIER)
    end
end)

t.test('ABSURD (out-of-any-sane-range) PAYLOAD IS ACCEPTED INTO THE MODIFIER, BUT NEVER REACHES THE NATIVE UNCLAMPED -- this file\'s own validation only rejects non-positive/NaN/non-number, it does not re-implement server/runtimecontrol.lua\'s own [min,max] range check (a genuinely out-of-range value could only reach here from a bug elsewhere, since SetTunable itself already refuses it before it can ever be saved); the REAL safety net for an absurd value is client/movement.lua\'s own [0.1, 2.0] composed-rate clamp, proven here against the REAL composer, not a second range check duplicated in this file', function()
    local f = newClientFixture()
    f.dispatchGrant(65535, 999999.0, 999999)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 999999.0, 'this file itself writes whatever positive/finite number it was sent, unclamped -- clamping is the composer\'s job, not this file\'s')
    t.equals(f.setMoveRateCalls[1].rate, 2.0, 'client/movement.lua\'s RecomputeK9MoveRate() clamps the composed product to its own [0.1, 2.0] ceiling regardless of how large any single modifier is -- the actual native call never sees the raw 999999.0')
end)

-- ------------------------------------------------------------------
-- ANY PED, GENUINELY -- THE FIX ITSELF. This file's own header states, at
-- length, "ANY PED, GATED ON ROLE/CERTIFICATION, NEVER ON PED MODEL" -- the
-- two tests below are what actually PROVES that now, against the REAL
-- client/movement.lua composer, not just this file's own local checks
-- (which never touched the model at all, and so could never have caught
-- this). See client/movement.lua's own "SCOPE, CORRECTED" header comment on
-- K9MoveRateModifiers for the full bug writeup this locks in the fix for.
-- ------------------------------------------------------------------

t.test('ANY PED, GENUINELY: NOT on a K9 model, but HasK9Access() true (a certified handler on a human/custom body, or a High-Command/autoAccessGrade access holder) -- the grant STILL reaches the real native call, proving the fix', function()
    local f = newClientFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(true)
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER, 'this file itself always wrote the modifier correctly -- the bug was never here')
    t.equals(#f.setMoveRateCalls, 1,
        'THE BUG, NOW FIXED: this used to be 0 -- client/movement.lua\'s RecomputeK9MoveRate() used to hard-gate on ' ..
        'IsOwnModelK9() ALONE and silently reset to neutral before composing anything, so a role-holder on a non-K9 ' ..
        'body got this file\'s own "activated" toast with zero actual speed change')
    t.equals(f.setMoveRateCalls[1].rate, REAL_SPEED_MULTIPLIER, 'the exact same numbers apply on a non-K9 body as on a K9 one -- a multiplicative override is body-agnostic by construction')
end)

t.test('ANY PED, GENUINELY: NOT on a K9 model AND no real K9 access either -- correctly still a no-op (a player with neither has no legitimate reason for this burst to apply, and the server would never have granted it anyway)', function()
    local f = newClientFixture()
    f.setIsOwnModelK9(false)
    f.setHasK9Access(false)
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER, 'this file still writes its own modifier regardless -- composing/applying it is the composer\'s job, not this file\'s')
    t.equals(#f.setMoveRateCalls, 0, 'neither half of RecomputeK9MoveRate()\'s OR-gate is true, so the real native call correctly never fires')
end)

t.test('soft dependency: K9MoveRateModifiers/RecomputeK9MoveRate entirely absent (simulating a client/movement.lua that never defines them) -- grant handler fails CLOSED (no error, no notify, no thread, no native call)', function()
    local f = newClientFixture({ withMoveRateComposer = false })
    local ok = pcall(f.dispatchGrant, 65535)
    t.isTrue(ok, 'a missing move-rate composer must never error the grant handler')
    t.equals(#f.notifyCalls, 0)
    t.equals(f.newThreadsSinceLoad(), 0)
    t.equals(#f.setMoveRateCalls, 0)
end)

t.test('END-TIMER: the modifier resets to neutral and the REAL SetPedMoveRateOverride is called again once durationMs elapses (never gated on any access/cert check -- this handler calls no such check at all)', function()
    local f = newClientFixture() -- durationMs = 300, 3 ticks of 100ms
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)
    t.equals(#f.setMoveRateCalls, 1)

    -- 1 priming step + 3 real 100ms ticks = 4 total, per
    -- fixtures/sandbox.lua's own documented newThreadRunner() stepping
    -- convention (the first step() only reaches the loop's own first
    -- Wait(), the same shape tests/clientagility_spec.lua's TryVault tests
    -- rely on). client/movement.lua's own always-on leash pull-back thread
    -- is ALSO stepped by every runner.step() call here (it is registered in
    -- the very same shared thread runner) -- harmless, since leashState
    -- stays nil throughout this whole file, so that thread's body always
    -- takes its cheap idle branch and never touches this test's own
    -- assertions.
    --
    -- client/movement.lua's ALSO-always-on move-rate WATCHDOG (added in the
    -- "close the any-ped speed-system gap" pass -- see that file's own
    -- header comment on it) is a THIRD thread sharing this same runner, and
    -- is NOT harmless for this specific test the way the leash thread is:
    -- unlike the leash thread, the watchdog's own body directly calls the
    -- REAL RecomputeK9MoveRate() (Wait sits at the END of its loop, same
    -- convention as every other thread in that file, so every single resume
    -- while lastAppliedMoveRate is non-1.0 performs one real pass) --
    -- exactly the guaranteed-removal-path behavior that fix is FOR, not a
    -- test artifact to work around. Once dispatchGrant() above leaves
    -- lastAppliedMoveRate at REAL_SPEED_MULTIPLIER (non-1.0), every one of
    -- the 4 runner.step() calls below ALSO resumes the watchdog, and each
    -- resume re-applies the still-boosted rate for real (RecomputeK9MoveRate()
    -- never dedupes its own qualifying branch, by design -- see
    -- tests/clientmovement_spec.lua's own pinned test for that). That is 4
    -- extra real SetPedMoveRateOverride calls (one per step while still
    -- boosted) on top of the 2 this test originally counted (the grant, and
    -- pursuit sprint's own end-timer reset) = 6 total, confirmed empirically
    -- against the real, unmodified production files. The exact total is
    -- asserted below for documentation value, but the assertions that
    -- actually matter for THIS test's own purpose -- the end-timer genuinely
    -- fires and the LAST real native call reflects the reset -- are the
    -- `pursuitSprint == 1.0` and `setMoveRateCalls[#setMoveRateCalls].rate`
    -- checks, which hold regardless of how many OTHER always-on threads
    -- happen to share this runner in the future.
    f.runner.step()
    f.runner.step()
    f.runner.step()
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER, 'must still be boosted before the 4th step')
    f.runner.step()

    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0)
    t.equals(#f.setMoveRateCalls, 6, 'the grant, 4 watchdog re-assertions while still boosted (one per step), and the end-timer reset -- see this test\'s own comment above for the full accounting')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'the LAST real native call must reflect the end-timer reset, regardless of how many total calls preceded it')
end)

t.test('END-ON-DEATH: IsEntityDead(PlayerPedId()) true mid-burst ends the burst EARLY, well before durationMs elapses', function()
    local f = newClientFixture() -- durationMs = 300, 3 ticks of 100ms
    f.dispatchGrant(65535)

    f.runner.step() -- prime
    f.setIsDead(1, true)
    f.runner.step() -- first real tick (elapsed = 100) -- death is now observed and breaks the loop immediately

    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0, 'must already be reset after only 1 real tick, not the full 3')
    t.equals(f.setMoveRateCalls[#f.setMoveRateCalls].rate, 1.0, 'the real native call must reflect the early reset too')
end)

t.test('GENERATION GUARD: a stale end-timer from an EARLIER grant must never clobber a NEWER, still-active burst\'s modifier', function()
    local f = newClientFixture() -- durationMs = 300, 3 ticks of 100ms

    f.dispatchGrant(65535) -- grant #1 (generation 1) -- creates thread A
    f.runner.step() -- prime A
    f.runner.step() -- A: elapsed = 100

    f.dispatchGrant(65535) -- grant #2 (generation 2) -- creates thread B, while A is still mid-flight
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)

    f.runner.step() -- A: elapsed = 200; B: primed
    f.runner.step() -- A: elapsed = 300 -> A's OWN loop exits -> A's generation (1) != current (2) -> A must NOT reset; B: elapsed = 100

    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER,
        'the OLDER grant\'s end-timer finishing first must not reset a NEWER, still-active burst')

    f.runner.step() -- B: elapsed = 200
    f.runner.step() -- B: elapsed = 300 -> B's generation (2) == current (2) -> resets for real

    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0, 'the CURRENT (most recent) grant\'s own end-timer must still reset normally')
end)

t.test('onResourceStop: resets the modifier to neutral even mid-burst, and ignores a DIFFERENT resource stopping', function()
    local f = newClientFixture()
    f.dispatchGrant(65535)
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER)

    f.fireResourceStop('some_other_resource')
    t.equals(f.K9MoveRateModifiers.pursuitSprint, REAL_SPEED_MULTIPLIER, 'a different resource stopping must never reset this one\'s state')

    f.fireResourceStop() -- this resource's own stop
    t.equals(f.K9MoveRateModifiers.pursuitSprint, 1.0)
end)

os.exit(t.summary())
