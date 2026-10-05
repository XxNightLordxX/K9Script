--[[
    tests/diagnostics_dump_spec.lua

    Tests server/diagnostics.lua -- the `/k9debug` command -- against the
    REAL, unmodified production file, loaded alongside the REAL
    server/diagnostics.lua (so A4's re-surfaced K9SelfCheck.EvaluateDependencyVersion/
    FormatDependencyWarning behavior is genuine, not a second, hand-written
    copy of that logic).

    Everything in server/diagnostics.lua is `local` except the deliberate
    `_G[name] = wrapper` reassignment of HasK9Access/IsHighCommand/
    HasPermission at verbose level -- there is no other public API surface
    at all, on purpose (see that file's own header). So this spec reaches
    every check the SAME way a real caller would: through the captured
    RegisterCommand('k9debug', ...) handler, the captured
    AddEventHandler('john-k9:server:debugDumpClientHeartbeat'/
    'playerDropped'/'onResourceStart', ...) handlers, and the captured
    SaveResourceFile calls -- asserting on the WRITTEN JSON TEXT's content
    (string contains/notContains, testkit's own established idiom for
    exactly this "assert on captured output without depending on exact
    formatting" need) rather than reaching into any individual check
    function directly.

    LoadResourceFile, BY DEFAULT, reads the REAL files off disk
    ('../server/datastore.lua', '../server/diagnostics.lua') -- so the A3/A4
    table-name/dependency EXTRACTION regexes are exercised against the
    ACTUAL current production files by every test that does not explicitly
    override `resourceFiles[...]`, the same "read the real source, don't
    re-type it" guarantee tests/fixtures/sandbox.lua's own
    Sandbox.installedSchemaRows() already relies on. Individual tests
    override `resourceFiles[...]` only where they need tight, deterministic
    control over exactly which table/dependency names are "found".

    ======================================================================
    RED-THEN-GREEN PROOF PERFORMED FOR THIS PASS (A1, the check named
    directly in this task's own brief): after writing every test below,
    CheckFeatureGroupsDisagreement's `anyFamilyDisabled` guard was
    temporarily forced to `false` unconditionally (so a genuine
    parent-disabled cascade would always be misreported as a FINDING). Both
    of the "A1" tests below immediately went red -- the WORTH-CHECKING test
    failed because its expected wording never appeared (the FINDING wording
    appeared in its place instead), proving the tier distinction is real,
    not vacuous. The file was restored to its real, working form
    immediately after, and both tests pass again below.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Deterministic GetHashKey stand-in -- see propattachment_spec.lua/
-- kennel_spec.lua's own identical comment for why the real native's exact
-- algorithm does not matter here, only that equal strings hash equal and
-- different strings (almost always) hash different.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

-- ----------------------------------------------------------------------
-- Minimal, REAL (not stubbed-to-a-fixed-answer) JSON encode/decode,
-- sufficient for the one thing this file's own manifest logic needs: a
-- flat JSON array of strings. Deliberately tiny -- this is test
-- infrastructure proving server/diagnostics.lua's OWN retention logic
-- degrades correctly when `json` is unavailable AND behaves correctly
-- when it is, not a general-purpose JSON library.
-- ----------------------------------------------------------------------
local function jsonEncodeStringArray(list)
    local parts = {}
    for i, s in ipairs(list) do
        parts[i] = '"' .. tostring(s):gsub('[\\"]', '\\%0') .. '"'
    end
    return '[' .. table.concat(parts, ',') .. ']'
end

local function jsonDecodeStringArray(text)
    local out = {}
    for s in text:gmatch('"(.-)"') do
        out[#out + 1] = s
    end
    return out
end

local jsonStub = {
    encode = function(v) return jsonEncodeStringArray(v) end,
    decode = function(s) return jsonDecodeStringArray(s) end,
}

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts table? -- { enabled, level, maxRetainedDumps, autoOnBoot, noJson }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}
    local enabled = opts.enabled
    if enabled == nil then enabled = true end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    -- Minimal stand-in for server/cooldowns.lua's real NewCooldown --
    -- server/diagnostics.lua is not loaded alongside the real cooldowns.lua
    -- here (this spec is scoped to server/diagnostics.lua + server/diagnostics.lua
    -- only, matching this suite's own "stub genuinely other files' logic"
    -- convention -- see e.g. propattachment_spec.lua's own header). Only
    -- the two methods server/diagnostics.lua actually calls are provided:
    -- `.Consume(key)` (uses the SAME fake GetGameTimer clock above, so
    -- fakeNow()/setNow() below drive it exactly like the real one would)
    -- and `.RegisterPlayerDropped()` (a real no-op is faithful: this fake
    -- tracker's key space is either a citizenid or a source, both already
    -- naturally bounded to "currently relevant players" in a test).
    local function NewCooldown(defaultThresholdMs)
        local lastTouchedAt = {}
        return {
            Consume = function(key, thresholdMs)
                thresholdMs = thresholdMs or defaultThresholdMs
                local last = lastTouchedAt[key]
                if last ~= nil and (fakeNow - last) < thresholdMs then return false end
                lastTouchedAt[key] = fakeNow
                return true
            end,
            RegisterPlayerDropped = function() end,
        }
    end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function RegisterNetEvent(_eventName) end

    local commands = {} -- name -> { handler = fn, restricted = bool }
    local function RegisterCommand(name, handler, restricted)
        commands[name] = { handler = handler, restricted = restricted }
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local savedFiles = {} -- path -> { content, ... } every write, in order -- this fixture's own fake filesystem
    local function SaveResourceFile(_resourceName, path, content, _len)
        savedFiles[path] = savedFiles[path] or {}
        savedFiles[path][#savedFiles[path] + 1] = content
        return true
    end

    -- Read order: (1) anything THIS test session already wrote via
    -- SaveResourceFile above (the manifest, an earlier dump this same run
    -- emptied) -- a real SaveResourceFile/LoadResourceFile pair round-trips
    -- through the SAME real disk, so this fixture's fake filesystem must
    -- too, or server/diagnostics.lua's own manifest-based retention could
    -- never be exercised at all; (2) an explicit per-test override via
    -- resourceFiles[relativePath] = <string|false>; (3) the REAL file off
    -- disk (tests run with cwd = tests/) -- see this file's own header.
    --
    -- PERFORMANCE FIX (load audit, this pass) -- `loadResourceFileCallCounts`
    -- (relativePath -> count, every call, regardless of which of the three
    -- branches above ends up answering it) added purely as an OBSERVATION
    -- point for the ExtractDatastoreTableNames/ExtractSelfcheckDependencies
    -- memoization tests further down -- it does not change LoadResourceFile's
    -- own behavior for any existing test in this file at all.
    local resourceFiles = {}
    local loadResourceFileCallCounts = {}
    local function LoadResourceFile(_resourceName, relativePath)
        loadResourceFileCallCounts[relativePath] = (loadResourceFileCallCounts[relativePath] or 0) + 1
        if savedFiles[relativePath] then
            return savedFiles[relativePath][#savedFiles[relativePath]]
        end
        if resourceFiles[relativePath] ~= nil then
            local v = resourceFiles[relativePath]
            if v == false then return nil end
            return v
        end
        local handle = io.open('../' .. relativePath, 'r')
        if not handle then return nil end
        local content = handle:read('a')
        handle:close()
        return content
    end

    local printLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLines[#printLines + 1] = table.concat(parts, '\t')
    end

    local notifyCalls = {} -- { {target=, description=, notifyType=}, ... }
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local playersBySource = {} -- source -> { citizenid = ..., firstname = ..., lastname = ... }
    local itemsInInventory = {} -- itemName -> true (exists) -- absent = does not exist
    local resourceStates = { ox_inventory = 'started' } -- name -> state
    local resourceVersions = {} -- name -> version string
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local p = playersBySource[src]
                if not p then return nil end
                return { PlayerData = { citizenid = p.citizenid, charinfo = { firstname = p.firstname, lastname = p.lastname } } }
            end,
        },
        ox_inventory = {
            Items = function(_self, name)
                if itemsInInventory[name] then return { name = name } end
                return nil
            end,
        },
    }

    local function GetResourceState(name) return resourceStates[name] or 'missing' end
    local function GetResourceMetadata(name, key, _idx)
        if key == 'version' then return resourceVersions[name] end
        return nil
    end

    local dbEnabledByTable = {} -- tableName (or '__whole__') -> boolean, default true
    local K9Store = {
        IsDatabaseEnabled = function(tableName)
            local key = tableName or '__whole__'
            if dbEnabledByTable[key] == nil then return true end
            return dbEnabledByTable[key]
        end,
        WaitForSchemaCheckToSettle = function() return true end,
        Override_GetAll = function() return {} end,
    }

    local worldObjects, worldVehicles = {}, {}
    local function GetAllObjects() return worldObjects end
    local function GetAllVehicles() return worldVehicles end
    local entityModels = {} -- handle -> hash
    local function GetEntityModel(handle) return entityModels[handle] end

    local Config = {
        DebugDump = {
            enabled = enabled,
            level = opts.level or 'normal',
            maxRetainedDumps = opts.maxRetainedDumps or 200,
            autoOnBoot = (opts.autoOnBoot == nil) and true or opts.autoOnBoot,
        },
        Features = {},
        FeaturesBeforeGrouping = nil,
        FeatureGroups = nil,
        Wellbeing = { Fatigue = { restSources = {} }, Thirst = { bowlSources = {} }, Mood = {}, Distraction = {} },
        K9Medkit = {},
        HighCommand = { allowSelfGrant = true },
        FeatureControl = { allowHighCommandSelfGrant = true },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        NewCooldown = NewCooldown,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        GetCurrentResourceName = GetCurrentResourceName,
        LoadResourceFile = LoadResourceFile,
        SaveResourceFile = SaveResourceFile,
        print = printStub,
        NotifyPlayer = NotifyPlayer,
        exports = exportsStub,
        GetResourceState = GetResourceState,
        GetResourceMetadata = GetResourceMetadata,
        K9Store = K9Store,
        GetAllObjects = GetAllObjects,
        GetAllVehicles = GetAllVehicles,
        GetEntityModel = GetEntityModel,
        GetHashKey = GetHashKey,
        Config = Config,
        json = opts.noJson and nil or jsonStub,
        CreateThread = function() end, -- never called by server/diagnostics.lua; present only so a stray reference never errors
    })

    -- server/diagnostics.lua loads LAST in fxmanifest.lua specifically so
    -- K9SelfCheck already exists as a real global by the time it wraps/reads
    -- anything -- reproduced here by loading the REAL server/diagnostics.lua
    -- into this SAME env first.
    -- ONE load since the 2026-09-02 merge: server/diagnostics.lua and
    -- server/diagnostics.lua are now server/diagnostics.lua, sections 1 and 2
    -- of the same file. Loading it twice, as this used to, would have
    -- re-registered the command.
    Sandbox.loadInto('../server/diagnostics.lua', env)

    return {
        env = env,
        Config = Config,
        setNow = function(ms) fakeNow = ms end,
        commands = commands,
        eventHandlers = eventHandlers,
        savedFiles = savedFiles,
        printLines = printLines,
        notifyCalls = notifyCalls,
        loadResourceFileCallCounts = loadResourceFileCallCounts,
        setPlayer = function(src, citizenid, firstname, lastname)
            playersBySource[src] = { citizenid = citizenid, firstname = firstname, lastname = lastname }
        end,
        setItemExists = function(name, exists) itemsInInventory[name] = exists end,
        setTableEnabled = function(tableName, isEnabled) dbEnabledByTable[tableName] = isEnabled end,
        setResourceFile = function(path, content) resourceFiles[path] = content end,
        resourceFiles = resourceFiles,
        setResourceVersion = function(name, v) resourceVersions[name] = v end,
        setResourceState = function(name, state) resourceStates[name] = state end,
        addWorldObject = function(handle, modelHash) worldObjects[#worldObjects + 1] = handle; entityModels[handle] = modelHash end,
    }
end

--- Fires the 'k9debug' RegisterCommand handler and returns the LAST thing
--- written to the diagnostics/ folder (the dump itself), or nil.
--- @return string? content, string? filename
local function runCommandAndGetLastDump(f, source, args)
    f.commands.k9debug.handler(source, args or {})
    local lastPath, lastContent = nil, nil
    for path, writes in pairs(f.savedFiles) do
        if path:match('^diagnostics/k9debug_') and not path:match('_manifest') then
            lastPath, lastContent = path, writes[#writes]
        end
    end
    return lastContent, lastPath
end

-- ======================================================================
-- SHIPS OFF
-- ======================================================================

t.test('Config.DebugDump.enabled = false registers NOTHING at all -- no command, no event handlers', function()
    local f = newFixture({ enabled = false })
    t.isNil(f.commands.k9debug, 'RegisterCommand("k9debug", ...) must never be called while disabled')
    t.isNil(f.eventHandlers['john-k9:server:debugDumpClientHeartbeat'], 'the heartbeat listener must never be registered while disabled')
end)

t.test('Config.DebugDump.enabled = true registers the command and the heartbeat/playerDropped listeners', function()
    local f = newFixture({ enabled = true })
    t.isNotNil(f.commands.k9debug)
    t.isNotNil(f.eventHandlers['john-k9:server:debugDumpClientHeartbeat'])
    t.isNotNil(f.eventHandlers['playerDropped'])
end)

-- ======================================================================
-- CLAMP-AND-WARN
-- ======================================================================

t.test('a non-boolean Config.DebugDump.enabled clamps to false (ships off) and warns, never asserts', function()
    local f = newFixture({ enabled = 'yes' })
    t.equals(f.Config.DebugDump.enabled, false)
    t.isNil(f.commands.k9debug)
    local sawWarning = false
    for _, line in ipairs(f.printLines) do
        if line:find('Config.DebugDump.enabled', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning, 'a console warning must name the bad field')
end)

t.test('an invalid Config.DebugDump.level clamps to "normal" and warns', function()
    local f = newFixture({ enabled = true, level = 'extremely verbose' })
    t.equals(f.Config.DebugDump.level, 'normal')
end)

t.test('a non-positive Config.DebugDump.maxRetainedDumps clamps to 200 and warns', function()
    local f = newFixture({ enabled = true, maxRetainedDumps = -5 })
    t.equals(f.Config.DebugDump.maxRetainedDumps, 200)
end)

-- ======================================================================
-- OWN STATE ONLY / BASIC COMMAND BEHAVIOR
-- ======================================================================

t.test('source = 0 (server console) is refused -- no NotifyPlayer, no dump written', function()
    local f = newFixture()
    f.commands.k9debug.handler(0, {})
    t.equals(#f.notifyCalls, 0)
    local wroteDump = false
    for path in pairs(f.savedFiles) do
        if path:match('^diagnostics/k9debug_') then wroteDump = true end
    end
    t.isFalse(wroteDump)
end)

t.test('an unresolvable citizenid (exports.qbx_core:GetPlayer finds nobody) is refused with debugdump.no_citizenid', function()
    local f = newFixture()
    f.commands.k9debug.handler(7, {})
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, Sandbox.locale('debugdump.no_citizenid'))
end)

t.test('a successful run writes ONE valid-looking JSON dump, notifies the player, and names the file', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123', 'Jane', 'Doe')
    local content, path = runCommandAndGetLastDump(f, 7)
    t.isNotNil(content, 'a dump must have been written')
    t.contains(path, 'diagnostics/k9debug_ABC123_')
    t.contains(content, '"readMeFirst"')
    t.contains(content, '"findings"')
    t.contains(content, '"worthChecking"')
    t.contains(content, '"fullState"')
    t.contains(content, '"requestedByCitizenid": "ABC123"')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].notifyType, 'success')
end)

t.test('the command cooldown refuses a second run too soon, and allows one again after the threshold', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')
    f.commands.k9debug.handler(7, {})
    f.commands.k9debug.handler(7, {})
    t.equals(#f.notifyCalls, 2)
    t.equals(f.notifyCalls[2].description, Sandbox.locale('debugdump.cooldown'))

    f.setNow(10001) -- past the 10000ms constant this file uses
    f.commands.k9debug.handler(7, {})
    t.equals(#f.notifyCalls, 3)
    t.equals(f.notifyCalls[3].notifyType, 'success')
end)

t.test('an invalid level argument is rejected with debugdump.bad_level_arg, and the dump still writes at the configured level', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7, { 'bogus' })
    t.equals(#f.notifyCalls, 2) -- the bad-arg warning, then the written notification
    t.equals(f.notifyCalls[1].description, Sandbox.locale('debugdump.bad_level_arg', 'bogus', 'normal'))
    t.contains(content, '"level": "normal"')
end)

t.test('requesting "verbose" when Config.DebugDump.level is "normal" downgrades to normal and warns, never fabricating a trail', function()
    local f = newFixture({ level = 'normal' })
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7, { 'verbose' })
    t.equals(f.notifyCalls[1].description, Sandbox.locale('debugdump.verbose_not_collected'))
    t.contains(content, '"level": "normal"')
    t.notContains(content, '"decisionTrail"')
end)

-- ======================================================================
-- A1 -- Config.Features vs Config.FeatureGroups (see this file's own
-- header for the RED-THEN-GREEN proof performed on this section).
-- ======================================================================

t.test('A1: a healthy config (Features already equals FeaturesBeforeGrouping) reports NO disagreement at all', function()
    local f = newFixture()
    f.Config.Features = { Foo = true }
    f.Config.FeaturesBeforeGrouping = { Foo = true }
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.notContains(content, '[A1]')
end)

t.test('A1: no family disabled + a quiet Config.FeatureGroups override -- reported as a FINDING', function()
    local f = newFixture()
    f.Config.Features = { HandlerXPProgression = false } -- what is ACTUALLY in effect
    f.Config.FeaturesBeforeGrouping = { HandlerXPProgression = true } -- what the flat switch says
    f.Config.FeatureGroups = { Progression = { enabled = true } } -- nothing disabled
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, 'no Config.FeatureGroups family is disabled right now')
    t.notContains(content, 'MAY be an intentional cascade')
end)

t.test('A1: a disabled family -- the SAME kind of mismatch is downgraded to WORTH-CHECKING, worded as a possibility', function()
    local f = newFixture()
    f.Config.Features = { HandlerXPProgression = false }
    f.Config.FeaturesBeforeGrouping = { HandlerXPProgression = true }
    f.Config.FeatureGroups = { Progression = { enabled = false } } -- a real, disabled family
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, 'MAY be an intentional cascade')
    t.notContains(content, 'no Config.FeatureGroups family is disabled right now')
end)

-- ======================================================================
-- A3 -- database schema state
-- ======================================================================

t.test('A3: a notable table reported memory-only by K9Store.IsDatabaseEnabled is a FINDING naming it by name', function()
    local f = newFixture()
    f.setResourceFile('server/datastore.lua', [[
local EXPECTED_TABLE_COLUMNS = {
    k9_wellbeing = { 'citizenid' },
    k9_search_log = { 'searcher_citizenid' },
}
]])
    f.setTableEnabled('k9_wellbeing', false)
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, 'Table `k9_wellbeing`')
    t.contains(content, 'memory-only this session')
end)

t.test('A3: every table healthy reports plain OK state, no findings', function()
    local f = newFixture()
    f.setResourceFile('server/datastore.lua', [[
local EXPECTED_TABLE_COLUMNS = {
    k9_wellbeing = { 'citizenid' },
}
]])
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.notContains(content, '[A3]')
    t.contains(content, 'Table `k9_wellbeing`: OK (database-backed).')
end)

-- ======================================================================
-- A4 -- dependency versions, via the REAL K9SelfCheck
-- ======================================================================

-- No source-file pinning here any more. This test used to load the real
-- server file's text into the fixture, because the dependency list reached
-- the dump by being pattern-matched back out of that text. Since the
-- diagnostics merge the dump reads the REAL, in-scope DEPENDENCIES table
-- directly (see DependencyList in server/diagnostics.lua), so this test is
-- now pinned to the real minimums by construction and cannot be fooled by a
-- fixture whose text has drifted from the table the boot check enforces.
t.test('A4: a dependency below its minimum version is reported', function()
    local f = newFixture()
    f.setResourceState('ox_lib', 'started')
    f.setResourceVersion('ox_lib', '0.0.1')
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, "'ox_lib' version 0.0.1 is older than")
end)

-- ======================================================================
-- PERFORMANCE FIX (load audit) -- ExtractDatastoreTableNames (A3) used to
-- call LoadResourceFile and re-parse the FULL text of server/datastore.lua
-- (~238KB) on EVERY /k9debug run, even though that file cannot change while
-- this resource is running -- pure waste past the first call. It is now
-- memoized, module-level, nil-checked (see its own doc comment in
-- server/diagnostics.lua).
--
-- RED-THEN-GREEN PROOF PERFORMED: the test below ("re-read on a second run")
-- was run against the PRE-FIX source (the extraction function with its
-- memoization guard removed, restored to unconditionally re-reading and
-- re-parsing on every call) and failed -- server/datastore.lua's call count
-- DOUBLED on the second /k9debug run instead of staying flat. Restoring the
-- real, memoized function made it pass again. The safety test just below it
-- was written specifically to catch the WRONG way to fix this (caching based
-- on "have we tried" rather than "did we succeed") -- see that test's own
-- comment.
--
-- A4's dependency list used to be the SECOND memoized extraction here, read
-- and parsed out of server/diagnostics.lua's source text for exactly the same
-- reason. The diagnostics merge put the self-check and the dump in one file,
-- so that list is now an ordinary in-scope table reference -- no read, no
-- parse, no cache, nothing left to memoize. The second assertion below
-- therefore now proves the read never happens AT ALL, rather than that it
-- happens only once.
t.test('PERFORMANCE: server/datastore.lua is read at most once per session, and server/diagnostics.lua is never read at all', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')
    f.setPlayer(8, 'DEF456')

    runCommandAndGetLastDump(f, 7)
    local firstDatastoreReads = f.loadResourceFileCallCounts['server/datastore.lua'] or 0
    t.isTrue(firstDatastoreReads >= 1, 'the first run must actually read server/datastore.lua at least once -- otherwise this test proves nothing')

    -- A DIFFERENT player, deliberately -- the cache is module-level (the
    -- extraction result is invariant for the whole resource's uptime, not
    -- per-caller), so a second run by anyone at all must hit it.
    runCommandAndGetLastDump(f, 8)
    t.equals(f.loadResourceFileCallCounts['server/datastore.lua'], firstDatastoreReads,
        'a second /k9debug run must NEVER re-read server/datastore.lua once the table-name extraction has already succeeded once this session')

    -- Post-merge: the dependency list is an in-scope table, so no run should
    -- ever open the diagnostics source at all. A non-zero count here means
    -- someone reintroduced the read-and-parse-my-own-source approach.
    t.equals(f.loadResourceFileCallCounts['server/diagnostics.lua'] or 0, 0,
        '/k9debug must never read its own source file -- the dependency list it reports IS the DEPENDENCIES table the boot check enforces, in scope, not a re-parse of the text around it')
end)

t.test('PERFORMANCE FIX SAFETY: a transient read failure on the first run is never cached as success -- a LATER run with the file readable again still extracts the real data', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')

    -- Simulates LoadResourceFile failing on the FIRST run (a genuinely
    -- transient condition this fix must never turn into a permanent one).
    f.setResourceFile('server/datastore.lua', false)
    local firstContent, firstPath = runCommandAndGetLastDump(f, 7)
    t.contains(firstContent, 'Could not automatically read the list of tables')

    -- The file is readable again on a LATER run -- if the memoization were
    -- wrongly keyed on "have we tried" instead of "did we succeed", this
    -- would incorrectly keep failing forever from here on.
    f.setResourceFile('server/datastore.lua', [[
local EXPECTED_TABLE_COLUMNS = {
    k9_wellbeing = { 'citizenid' },
}
]])
    f.setNow(10001) -- past DebugDumpCommandCooldown (10000ms)
    f.commands.k9debug.handler(7, {})

    -- Deliberately NOT a second runCommandAndGetLastDump call: with TWO
    -- dump files now saved for the same citizenid, that helper's own
    -- unordered `pairs()` scan over ALL matching diagnostics/k9debug_*
    -- files could pick EITHER one back up -- exactly the kind of ambiguity
    -- the retention tests above this one avoid by keying off an explicit,
    -- already-known path instead. Isolate the SECOND run's own file
    -- unambiguously by excluding the already-known `firstPath`.
    local secondPath
    for path in pairs(f.savedFiles) do
        if path:match('^diagnostics/k9debug_') and not path:match('_manifest') and path ~= firstPath then
            secondPath = path
        end
    end
    t.isNotNil(secondPath, 'the second run must have written its own, distinct dump file')
    local secondContent = f.savedFiles[secondPath][#f.savedFiles[secondPath]]

    t.notContains(secondContent, 'Could not automatically read the list of tables',
        'a transient first-run failure must never be cached as a permanent one')
    t.contains(secondContent, 'Table `k9_wellbeing`: OK (database-backed).')
end)

-- ======================================================================
-- B2 -- ox_inventory item existence
-- ======================================================================

t.test('B2: an enabled feature whose configured item name does not exist in ox_inventory is a FINDING', function()
    -- REPOINTED 2026-09-02: this used a removed subsystem's two item names
    -- until that feature was removed. K9Medkit is now the only feature whose
    -- configured item name debugdump validates, so it is what B2 has to be
    -- tested against -- the CHECK is unchanged, only the feature it runs on.
    local f = newFixture()
    f.Config.Features.K9Medkit = true
    f.Config.K9Medkit = { itemName = 'k9_medkit' }
    f.setItemExists('k9_medkit', false)
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, '[B2]')
    t.contains(content, 'k9_medkit')
end)

t.test('B2: every configured item existing produces no findings', function()
    local f = newFixture()
    f.Config.Features.K9Medkit = true
    f.Config.K9Medkit = { itemName = 'k9_medkit' }
    f.setItemExists('k9_medkit', true)
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.notContains(content, '[B2]')
end)

-- ======================================================================
-- H1 -- self-grant switches, always reported as fact, never a finding
-- ======================================================================

t.test('H1: both self-grant switches are always reported, plainly, regardless of value', function()
    local f = newFixture()
    f.Config.HighCommand.allowSelfGrant = false
    f.Config.FeatureControl.allowHighCommandSelfGrant = true
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, 'Config.HighCommand.allowSelfGrant = false')
    t.contains(content, 'Config.FeatureControl.allowHighCommandSelfGrant = true')
end)

-- ======================================================================
-- FILENAME SAFETY -- a citizenid engineered to look like a path escape
-- must never reach SaveResourceFile un-sanitized.
-- ======================================================================

t.test('a citizenid containing path-escape characters is sanitized before ever reaching SaveResourceFile', function()
    local f = newFixture()
    f.setPlayer(7, '../../etc/passwd')
    local content, path = runCommandAndGetLastDump(f, 7)
    t.isNotNil(content)
    t.isFalse(path:find('..', 1, true) ~= nil, 'the written path must never contain ..')
    t.isFalse(path:find('/etc', 1, true) ~= nil, 'the written path must never contain the raw citizenid\'s slashes')
    t.contains(path, 'diagnostics/k9debug_')
end)

-- ======================================================================
-- RETENTION -- emptying, not deleting (see server/diagnostics.lua's own
-- header "WHY EMPTYING, NOT DELETING").
-- ======================================================================

t.test('once over maxRetainedDumps, the OLDEST tracked dump is emptied (overwritten), never left with real content', function()
    local f = newFixture({ maxRetainedDumps = 2 })
    f.setPlayer(7, 'ABC123')

    f.setNow(0)
    local _, firstPath = runCommandAndGetLastDump(f, 7)
    f.setNow(11000)
    runCommandAndGetLastDump(f, 7)
    f.setNow(22000)
    runCommandAndGetLastDump(f, 7)

    local writes = f.savedFiles[firstPath]
    t.isNotNil(writes, 'the first dump\'s own filename must have been written to again (emptied), never silently ignored')
    t.isTrue(#writes >= 2, 'the first file must have been written at creation AND emptied later')
    t.contains(writes[#writes], 'emptied')
end)

t.test('retention still works to the extent possible when `json` is unavailable -- never throws', function()
    local f = newFixture({ maxRetainedDumps = 1, noJson = true })
    f.setPlayer(7, 'ABC123')
    local ok = pcall(function()
        runCommandAndGetLastDump(f, 7)
        runCommandAndGetLastDump(f, 7)
    end)
    t.isTrue(ok, 'a missing `json` global must never throw -- it only means retention bookkeeping cannot persist across runs this session')
end)

-- ======================================================================
-- CLIENT SELF-REPORT (heartbeat)
-- ======================================================================

t.test('a heartbeat payload is clamped, cached, and surfaces in the next dump; a wildly out-of-range value is clamped, not passed through', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')
    f.env.source = 7
    f.eventHandlers['john-k9:server:debugDumpClientHeartbeat'][1]({
        modelHash = 12345,
        pedHealth = 999999, -- way over the 2000 clamp ceiling
        pedMaxHealth = 200,
        isDead = false,
        isRagdoll = false,
        inVehicle = false,
        vehicleModelHash = 0,
        nuiFocused = true,
        clientGameTimerMs = 5000,
    })

    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, '"received": true')
    t.contains(content, '"pedHealth": 2000') -- clamped, never 999999
    t.contains(content, '"nuiFocused": true')
end)

t.test('no heartbeat received yet is reported honestly, never fabricated', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')
    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, '"received": false')
end)

t.test('playerDropped clears that source\'s cached self-report', function()
    local f = newFixture()
    f.setPlayer(7, 'ABC123')
    f.env.source = 7
    f.eventHandlers['john-k9:server:debugDumpClientHeartbeat'][1]({ pedHealth = 100 })
    f.eventHandlers['playerDropped'][1]()

    local content = runCommandAndGetLastDump(f, 7)
    t.contains(content, '"received": false')
end)

t.test('a malformed (non-table) heartbeat payload is ignored outright, never throws', function()
    local f = newFixture()
    f.env.source = 7
    local ok = pcall(f.eventHandlers['john-k9:server:debugDumpClientHeartbeat'][1], 'not a table')
    t.isTrue(ok)
end)

-- ======================================================================
-- THE DECISION TRAIL (verbose only) -- pass-through correctness AND
-- own-state-only filtering.
-- ======================================================================

t.test('verbose decision trail: an own HasK9Access/HasPermission call appears in this player\'s own dump; another citizenid\'s does not; wrapping never changes the real return value', function()
    local f
    do
        -- Build the env by hand (not newFixture) so HasK9Access/HasPermission
        -- exist as real globals BEFORE server/diagnostics.lua's own
        -- InstallDecisionWrapping runs at that file's load time.
        local fakeNow = 0
        local eventHandlers, commands, savedFiles, notifyCalls = {}, {}, {}, {}
        local playersBySource = { [7] = { citizenid = 'CIT_A' }, [8] = { citizenid = 'CIT_B' } }
        local env = Sandbox.newEnv({
            GetGameTimer = function() return fakeNow end,
            NewCooldown = function(defaultThresholdMs)
                local lastTouchedAt = {}
                return {
                    Consume = function(key, thresholdMs)
                        thresholdMs = thresholdMs or defaultThresholdMs
                        local last = lastTouchedAt[key]
                        if last ~= nil and (fakeNow - last) < thresholdMs then return false end
                        lastTouchedAt[key] = fakeNow
                        return true
                    end,
                    RegisterPlayerDropped = function() end,
                }
            end,
            AddEventHandler = function(name, h) eventHandlers[name] = eventHandlers[name] or {}; eventHandlers[name][#eventHandlers[name] + 1] = h end,
            RegisterNetEvent = function() end,
            RegisterCommand = function(name, h) commands[name] = { handler = h } end,
            GetCurrentResourceName = function() return 'john-k9' end,
            LoadResourceFile = function() return nil end,
            SaveResourceFile = function(_r, path, content) savedFiles[path] = savedFiles[path] or {}; savedFiles[path][#savedFiles[path] + 1] = content; return true end,
            print = function() end,
            NotifyPlayer = function(target, description, notifyType) notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType } end,
            exports = { qbx_core = { GetPlayer = function(_s, src) local p = playersBySource[src]; return p and { PlayerData = { citizenid = p.citizenid } } end } },
            K9Store = { IsDatabaseEnabled = function() return true end, WaitForSchemaCheckToSettle = function() return true end, Override_GetAll = function() return {} end },
            HasK9Access = function(src) return src == 7 end,
            IsHighCommand = function(_src) return false end,
            HasPermission = function(citizenid, _key) return citizenid == 'CIT_B' end,
            Config = {
                DebugDump = { enabled = true, level = 'verbose', maxRetainedDumps = 200, autoOnBoot = false },
                Features = {}, Wellbeing = { Fatigue = { restSources = {} }, Thirst = { bowlSources = {} } },
                K9Medkit = {}, HighCommand = {}, FeatureControl = {},
            },
        })
        Sandbox.loadInto('../server/diagnostics.lua', env)

        -- Pass-through correctness: the wrapped functions must still return
        -- exactly what the real ones do.
        t.isTrue(env.HasK9Access(7))
        t.isFalse(env.HasK9Access(8))
        t.isTrue(env.HasPermission('CIT_B', 'k9.access'))
        env.IsHighCommand(7) -- recorded too, result false -- exercised for coverage, not separately asserted

        f = { env = env, eventHandlers = eventHandlers, commands = commands, savedFiles = savedFiles, notifyCalls = notifyCalls }
    end

    f.commands.k9debug.handler(7, {})
    local content
    for path, writes in pairs(f.savedFiles) do
        if path:match('^diagnostics/k9debug_') then content = writes[#writes] end
    end

    t.isNotNil(content)
    t.contains(content, 'HasK9Access(7) -> true')
    t.notContains(content, 'HasPermission(CIT_B') -- CIT_A's own dump must never show CIT_B's own HasPermission call
end)

print('')
print(('diagnostics_dump_spec.lua: %d passed, %d failed'):format(t.passed, t.failed))
os.exit(t.summary())
