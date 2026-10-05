--[[
    tests/diagnostics_selfcheck_spec.lua

    Tests server/diagnostics.lua -- the boot-time dependency-version check and
    the Config.Features unrecognized-key check (see that file's own header
    for the full design reasoning). Structured the same way as
    tests/cooldowns_spec.lua/tests/runtimefeaturetiers_spec.lua: pure logic
    exercised directly with fabricated inputs, PLUS at least one test that
    loads the REAL, unmodified server/diagnostics.lua (and, for the
    Config.Features check, the REAL config.lua + server/runtimecontrol.lua)
    so this suite proves the wiring, not just the helper functions in
    isolation.

    RED/GREEN PROOF PERFORMED FOR THIS PASS (both checks, as required):
    after writing every test below, server/diagnostics.lua's two real fixes
    were each temporarily neutralized in turn (CompareSemver forced to
    compare version strings lexically instead of numerically; then
    FindUnrecognizedFeatureKeys forced to always return an empty list) and
    `lua5.4 diagnostics_selfcheck_spec.lua` was re-run against each broken copy. Both
    breaks turned the exact tests that name them red (never a whole-suite
    crash -- each failure was a clean, named assertion failure), confirming
    those tests actually exercise the fix and are not vacuously passing.
    The file was restored to its real, working form immediately after each
    check; the version in the working tree is the fixed one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Load the real, unmodified server/diagnostics.lua into a bare sandbox with
-- NO FiveM natives stubbed at all, to get at K9SelfCheck's pure functions
-- directly. Since every native touch in that file is guarded (`type(...)
-- == 'function'`), loading it here registers nothing and calls nothing --
-- exactly like server/datastore.lua's own schema probe in every OTHER
-- spec that loads that file without stubbing AddEventHandler.
-- ----------------------------------------------------------------------
local function loadPureModule()
    local env = Sandbox.newEnv({})
    Sandbox.loadInto('../server/diagnostics.lua', env)
    return env.K9SelfCheck
end

local K9SelfCheck = loadPureModule()

t.test('sanity: loading the real file in a native-less sandbox registers nothing and defines K9SelfCheck', function()
    t.isNotNil(K9SelfCheck, 'K9SelfCheck must be defined as a resource-global table')
    t.equals(type(K9SelfCheck.ParseSemver), 'function')
    t.equals(type(K9SelfCheck.FindUnrecognizedFeatureKeys), 'function')
end)

-- ----------------------------------------------------------------------
-- ParseSemver / CompareSemver
-- ----------------------------------------------------------------------

t.test('ParseSemver parses a plain MAJOR.MINOR.PATCH string', function()
    local v = K9SelfCheck.ParseSemver('3.39.0')
    t.isNotNil(v)
    t.equals(v.major, 3)
    t.equals(v.minor, 39)
    t.equals(v.patch, 0)
end)

t.test('ParseSemver tolerates a leading "v" and a missing patch component', function()
    local v = K9SelfCheck.ParseSemver('v1.2')
    t.isNotNil(v)
    t.equals(v.major, 1)
    t.equals(v.minor, 2)
    t.equals(v.patch, 0)
end)

t.test('ParseSemver ignores a trailing pre-release/build suffix', function()
    local v = K9SelfCheck.ParseSemver('2.14.1-rc1+build5')
    t.isNotNil(v)
    t.equals(v.major, 2)
    t.equals(v.minor, 14)
    t.equals(v.patch, 1)
end)

t.test('ParseSemver returns nil for a git hash (not semver at all)', function()
    t.isNil(K9SelfCheck.ParseSemver('a3f9e21'))
end)

t.test('ParseSemver returns nil for a bare date written with dashes', function()
    t.isNil(K9SelfCheck.ParseSemver('2026-08-26'))
end)

t.test('ParseSemver returns nil for an empty string, and for non-string input', function()
    t.isNil(K9SelfCheck.ParseSemver(''))
    t.isNil(K9SelfCheck.ParseSemver(nil))
    t.isNil(K9SelfCheck.ParseSemver(42))
end)

t.test('CompareSemver: THE STRING-COMPARISON TRAP -- 3.39.0 must compare NEWER than 3.4.0, never the other way around', function()
    local a = K9SelfCheck.ParseSemver('3.39.0')
    local b = K9SelfCheck.ParseSemver('3.4.0')
    t.isTrue(K9SelfCheck.CompareSemver(a, b) > 0, '3.39.0 must be greater than 3.4.0 numerically, even though "3.4.0" > "3.39.0" as a plain string')
    t.isTrue(K9SelfCheck.CompareSemver(b, a) < 0)
end)

t.test('CompareSemver: equal versions compare as 0', function()
    local a = K9SelfCheck.ParseSemver('1.18.1')
    local b = K9SelfCheck.ParseSemver('1.18.1')
    t.equals(K9SelfCheck.CompareSemver(a, b), 0)
end)

-- ----------------------------------------------------------------------
-- EvaluateDependencyVersion -- the five cases the design brief names
-- ----------------------------------------------------------------------

t.test('EvaluateDependencyVersion: dependency not started at all', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('stopped', nil, '3.39.0')
    t.equals(verdict.status, 'not_started')
end)

t.test('EvaluateDependencyVersion: started but ships no version metadata -- NOT an error, a distinct case', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', nil, '3.39.0')
    t.equals(verdict.status, 'no_metadata')
end)

t.test('EvaluateDependencyVersion: version string is not semver at all (git hash) -- UNKNOWN, never "too old"', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', 'a3f9e21', '3.39.0')
    t.equals(verdict.status, 'unknown_format')
end)

t.test('EvaluateDependencyVersion: THE REAL-WORLD TRAP -- 3.4.0 is below minimum 3.39.0, must be reported as below_minimum, never "ok" via string comparison', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', '3.4.0', '3.39.0')
    t.equals(verdict.status, 'below_minimum')
    t.equals(verdict.found, '3.4.0')
end)

t.test('EvaluateDependencyVersion: exactly at minimum is ok', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', '3.39.0', '3.39.0')
    t.equals(verdict.status, 'ok')
end)

t.test('EvaluateDependencyVersion: newer than minimum is ok ("say nothing" case)', function()
    local verdict = K9SelfCheck.EvaluateDependencyVersion('started', '4.0.0', '3.39.0')
    t.equals(verdict.status, 'ok')
end)

-- ----------------------------------------------------------------------
-- FormatDependencyWarning -- WARN LOUDLY, NEVER BLOCK; nil on the good path
-- ----------------------------------------------------------------------

t.test('FormatDependencyWarning: returns nil for an ok verdict -- the "say nothing" case', function()
    t.isNil(K9SelfCheck.FormatDependencyWarning({ name = 'ox_lib', minVersion = '3.39.0' }, { status = 'ok', found = '3.39.0' }))
end)

t.test('FormatDependencyWarning: below_minimum names the resource, the version found, and the minimum -- never claims it will refuse to start', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'ox_lib', minVersion = '3.39.0' }, { status = 'below_minimum', found = '3.4.0' })
    t.isNotNil(line)
    t.contains(line, 'ox_lib')
    t.contains(line, '3.4.0')
    t.contains(line, '3.39.0')
    t.notContains(line, 'refus', 'must never threaten to refuse to start over a version warning')
    t.notContains(line, 'assert', 'must never mention asserting/crashing')
end)

t.test('FormatDependencyWarning: no_metadata is informational, not alarming ("!!")', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'oxmysql', minVersion = '2.14.1' }, { status = 'no_metadata' })
    t.isNotNil(line)
    t.contains(line, 'oxmysql')
    t.notContains(line, '!!', 'a resource shipping no version metadata is a normal, expected case, not a loud warning')
end)

t.test('FormatDependencyWarning: unknown_format explicitly disclaims "too old" rather than silently implying it', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'ox_target', minVersion = '1.18.1' }, { status = 'unknown_format', found = 'a3f9e21' })
    t.isNotNil(line)
    t.contains(line, 'a3f9e21')
    t.contains(line, 'NOT treated as too old')
end)

t.test('FormatDependencyWarning: not_started names the resource and does not claim its version is bad', function()
    local line = K9SelfCheck.FormatDependencyWarning({ name = 'ox_inventory', minVersion = '2.47.9' }, { status = 'not_started', resourceState = 'stopped' })
    t.isNotNil(line)
    t.contains(line, 'ox_inventory')
    t.contains(line, 'stopped')
end)

-- ----------------------------------------------------------------------
-- FindUnrecognizedFeatureKeys -- the Config.Features typo check
-- ----------------------------------------------------------------------

t.test('FindUnrecognizedFeatureKeys: a typo key not present anywhere in the registry text is flagged', function()
    local configFeatures = { ScentTracking = true, ScentTraking = false }
    local registryText = "local FEATURE_TIERS = {\n    ScentTracking = { tier = 'live' },\n}"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 1)
    t.equals(unrecognized[1], 'ScentTraking')
end)

t.test('FindUnrecognizedFeatureKeys: every real key present in the registry text produces zero warnings (no false positives)', function()
    local configFeatures = { LeashMechanics = true, RadialMenu = true }
    local registryText = "LeashMechanics = { tier = 'live' },\nRadialMenu = { tier = 'onstart' },"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 0)
end)

t.test('FindUnrecognizedFeatureKeys: WHOLE-WORD BOUNDARY -- a key must not falsely match as a substring of a longer name', function()
    -- The registry only ever names 'ScentTrackingAdvanced'; a Config.Features
    -- key of plain 'ScentTracking' must NOT be considered found just because
    -- it is a textual prefix of that longer name.
    local configFeatures = { ScentTracking = true }
    local registryText = "ScentTrackingAdvanced = { tier = 'live' },"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 1)
    t.equals(unrecognized[1], 'ScentTracking')
end)

t.test('FindUnrecognizedFeatureKeys: WHOLE-WORD BOUNDARY, the other direction -- a longer real key is not falsely matched by a shorter substring appearing elsewhere', function()
    local configFeatures = { ScentTrackingAdvanced = true }
    local registryText = "ScentTracking = { tier = 'live' },"
    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registryText)
    t.equals(#unrecognized, 1)
    t.equals(unrecognized[1], 'ScentTrackingAdvanced')
end)

t.test('FindUnrecognizedFeatureKeys: malformed input (nil/non-table) never errors, just reports nothing', function()
    t.equals(#K9SelfCheck.FindUnrecognizedFeatureKeys(nil, 'text'), 0)
    t.equals(#K9SelfCheck.FindUnrecognizedFeatureKeys({ A = true }, nil), 0)
end)

t.test('LOAD-BEARING, AGAINST THE REAL CODEBASE: every real Config.Features key (config.lua) is found somewhere in the real feature registry (server/runtimecontrol.lua) -- zero false positives against what actually ships today', function()
    local configEnv = Sandbox.newEnv({})
    Sandbox.loadInto('../config.lua', configEnv)

    local handle = assert(io.open('../server/runtimecontrol.lua', 'r'), 'expected to run with cwd = qbx_k9unit/tests')
    local registryText = handle:read('a')
    handle:close()

    local totalFeatures = 0
    for _ in pairs(configEnv.Config.Features) do totalFeatures = totalFeatures + 1 end
    -- Sanity, same discipline as tests/runtimefeaturetiers_spec.lua's own
    -- "a loadfile typo silently produces an empty table" guard.
    -- FLOOR LOWERED 2026-09-02: twelve features were removed at the owner's request (61 -> 49 Config.Features keys), so the old floor could never be met again. It stays well above zero because its job is to catch an extraction pattern going stale and silently checking nothing -- not to pin the catalogue size.
    t.isTrue(totalFeatures >= 45, ('sanity: only saw %d Config.Features key(s); config.lua may not have loaded correctly for this spec'):format(totalFeatures))

    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(configEnv.Config.Features, registryText)
    if #unrecognized > 0 then
        error(('%d real Config.Features key(s) were not found anywhere in server/runtimecontrol.lua, and would be warned about at real boot: %s'):format(#unrecognized, table.concat(unrecognized, ', ')), 0)
    end
end)

-- ----------------------------------------------------------------------
-- BuildBootSummaryLine -- one line, real information, never fabricated
-- ----------------------------------------------------------------------

t.test('BuildBootSummaryLine: a healthy boot produces exactly one line with real counts', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        version = '0.1.0',
        deps = { total = 5, ok = 5, unverified = 0, problems = 0 },
        features = { total = 58, unrecognized = 0 },
        databaseState = 'connected (no whole-resource schema collision detected)',
    })
    t.notContains(line, '\n', 'must be exactly one line, never a banner')
    t.contains(line, '0.1.0')
    t.contains(line, '5/5')
    t.contains(line, '58/58')
    t.contains(line, 'connected')
end)

t.test('BuildBootSummaryLine: never fabricates a state it was not given -- missing deps/features report "not checked", not a made-up number', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        version = nil,
        deps = nil,
        features = nil,
        databaseState = 'unknown (server/datastore.lua not loaded)',
    })
    t.contains(line, 'version unknown')
    t.contains(line, 'dependencies: not checked')
    t.contains(line, 'Config.Features: not checked')
    t.notContains(line, '\n')
end)

t.test('BuildBootSummaryLine: a boot with warnings still reports honest counts on the same one line', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        version = '0.1.0',
        deps = { total = 5, ok = 4, unverified = 0, problems = 1 },
        features = { total = 58, unrecognized = 2 },
        databaseState = 'memory-only (see any warning above from server/datastore.lua for why)',
    })
    t.notContains(line, '\n')
    t.contains(line, '4/5')
    t.contains(line, '56/58')
end)

-- ----------------------------------------------------------------------
-- FULL BOOT WIRING -- loads the REAL server/diagnostics.lua with every
-- native it touches stubbed, fires the real 'onResourceStart' handler it
-- registers, and asserts on what it actually prints. Same shape as
-- tests/runtimefeaturetiers_spec.lua's own boot() helper.
-- ----------------------------------------------------------------------

--- @param overrides table { resourceStates, resourceVersions, resourceFiles, config, k9Store, k9Compat }
local function boot(overrides)
    overrides = overrides or {}
    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local resourceStates = overrides.resourceStates or {}
    local resourceVersions = overrides.resourceVersions or {}
    local resourceFiles = overrides.resourceFiles or {}

    local env = Sandbox.newEnv({
        AddEventHandler = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        GetResourceState = function(name) return resourceStates[name] or 'started' end,
        GetResourceMetadata = function(name, key, _index)
            if key ~= 'version' then return nil end
            return resourceVersions[name]
        end,
        LoadResourceFile = function(_name, path) return resourceFiles[path] end,
        print = printStub,
        Config = overrides.config or { Features = {} },
        K9Store = overrides.k9Store,
        K9Compat = overrides.k9Compat,
    })

    Sandbox.loadInto('../server/diagnostics.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end

    return { env = env, printedLines = printedLines }
end

local ALL_OK_VERSIONS = {
    qbx_core = '1.24.0', ox_lib = '3.39.0', ox_target = '1.18.1',
    oxmysql = '2.14.1', ox_inventory = '2.47.9',
}
local REGISTRY_WITH_ALL_58_KEYS_STUB = "-- fabricated for this spec only\nRadialMenu = { tier = 'onstart' },"

t.test('END-TO-END: a below-minimum ox_lib prints a named, loud warning at real boot', function()
    local versions = {}
    for k, v in pairs(ALL_OK_VERSIONS) do versions[k] = v end
    versions.ox_lib = '3.4.0' -- the string-comparison trap version, below the real 3.39.0 minimum

    local f = boot({
        resourceVersions = versions,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true } },
    })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) and line:find('ox_lib', 1, true) and line:find('3.4.0', 1, true) and line:find('3.39.0', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'expected a loud warning naming ox_lib, 3.4.0, and 3.39.0')
end)

t.test('END-TO-END: every dependency at/above minimum prints NO per-dependency warning at all', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true } },
    })
    for _, line in ipairs(f.printedLines) do
        t.notContains(line, '!!', 'no dependency warning expected when every real dependency is at/above its minimum: ' .. line)
    end
end)

t.test('END-TO-END: an unrecognized Config.Features key prints a named warning at real boot', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true, ScentTraking = false } },
    })
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) and line:find('ScentTraking', 1, true) then warned = true end
    end
    t.isTrue(warned, 'expected a named warning for the unrecognized key ScentTraking')
end)

-- ----------------------------------------------------------------------
-- MEMORY-ONLY, FOR TWO VERY DIFFERENT REASONS.
--
-- Config.Database.enabled = false is the SHIPPED DEFAULT (the resource is
-- drag-and-drop out of the box), so memory-only is now the ordinary case,
-- not a fault. The summary used to say "see any warning above from
-- server/datastore.lua for why" unconditionally, which sent every operator
-- running the default configuration hunting for an explanation that was
-- never printed -- the deliberate path prints no warning precisely because
-- nothing is wrong.
--
-- The other reason (the schema probe forcing memory-only because another
-- resource owns a k9_* table) IS a fault, DOES print a warning, and must
-- keep pointing at it.
-- ----------------------------------------------------------------------

t.test('MEMORY-ONLY BY CONFIG: the summary says it was the config, names the cost, and does NOT point at a warning that was never printed', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = {}, Database = { enabled = false } },
        k9Store = { IsDatabaseEnabled = function() return false end },
    })
    local lastLine = f.printedLines[#f.printedLines]

    t.contains(lastLine, 'memory-only BY CONFIG')
    t.contains(lastLine, 'nothing survives a restart')
    t.contains(lastLine, 'sql/install.sql')
    t.notContains(lastLine, 'see the warning above')
    t.notContains(lastLine, 'UNEXPECTEDLY')
end)

t.test('MEMORY-ONLY UNEXPECTEDLY: with the config NOT set to false, the summary says it was forced and still points at the warning', function()
    -- The runtime-forced case: Config says the database is on, but the
    -- store reports it off, which only happens when the schema probe
    -- forced it. That genuinely does have a warning above to read.
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = {}, Database = { enabled = true } },
        k9Store = { IsDatabaseEnabled = function() return false end },
    })
    local lastLine = f.printedLines[#f.printedLines]

    t.contains(lastLine, 'UNEXPECTEDLY')
    t.contains(lastLine, 'server/datastore.lua')
    t.notContains(lastLine, 'BY CONFIG')
end)

t.test('MEMORY-ONLY: a MISSING Config.Database block reads as the unexpected case, not the deliberate one', function()
    -- Only a literal false is deliberate. An absent block means the
    -- operator did not choose memory mode, so if the store still reports
    -- off, something forced it and they should be told to look.
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = {} },
        k9Store = { IsDatabaseEnabled = function() return false end },
    })
    t.contains(f.printedLines[#f.printedLines], 'UNEXPECTEDLY')
end)

t.test('END-TO-END: the final line is a single, informative summary printed last, after any warnings', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true, ScentTraking = false } },
        k9Store = { IsDatabaseEnabled = function() return false end },
    })
    t.isTrue(#f.printedLines > 0)
    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'boot summary')
    t.contains(lastLine, 'memory-only')
    t.notContains(lastLine, '\n')
end)

t.test('END-TO-END: a healthy boot (no dependency or config problems) still prints the one summary line, proving the check ran even when there is nothing to warn about', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB },
        config = { Features = { RadialMenu = true } },
        k9Store = {
            IsDatabaseEnabled = function() return true end,
            WaitForSchemaCheckToSettle = function() return true end,
        },
    })
    local sawBangBang = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) then sawBangBang = true end
    end
    t.isFalse(sawBangBang, 'a fully healthy boot must print no loud warnings at all')

    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'boot summary')
    t.contains(lastLine, '5/5')
    t.contains(lastLine, '1/1')
    t.contains(lastLine, 'connected')
end)

t.test('SAFETY: with no FiveM natives available at all (plain Lua), loading the real file registers nothing and errors nothing', function()
    local env = Sandbox.newEnv({})
    -- No AddEventHandler, no GetResourceState/GetResourceMetadata/LoadResourceFile,
    -- no Config, no K9Store -- the exact shape of a plain lua5.4 process.
    Sandbox.loadInto('../server/diagnostics.lua', env)
    t.isNotNil(env.K9SelfCheck)
end)


-- ======================================================================
-- SPECIALIZATION GATE WARNING. Blood and gunpowder tracking used to work
-- for every certified dog and now need a specialization. An existing
-- server therefore loses two capabilities on update, silently -- the
-- radial entry is still there and the answer is just "nothing found",
-- forever, with no explanation anywhere. These pin the boot line that
-- stops that being a mystery.
-- ======================================================================

local FLAGS = { scent = 'ScentTracking', blood = 'BloodTracking', gunpowder = 'GunpowderSniffing' }

t.test('SPECIALIZATION GATE: an enabled trail that needs a specialization is named, with the specialization that unlocks it', function()
    local gated = K9SelfCheck.FindSpecializationGatedTrackTypes(
        { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true },
        { explosives = { 'gunpowder' }, patrol = { 'blood' } },
        FLAGS)
    t.equals(#gated, 2, 'both blood and gunpowder are gated and switched on')
    -- Sorted, so the warning reads identically every boot rather than
    -- reordering run to run and looking like something changed.
    t.equals(gated[1].trackType, 'blood')
    t.equals(gated[1].specialization, 'patrol')
    t.equals(gated[2].trackType, 'gunpowder')
    t.equals(gated[2].specialization, 'explosives')
end)

t.test('SPECIALIZATION GATE: a trail the owner has switched OFF is never warned about -- they lost nothing', function()
    local gated = K9SelfCheck.FindSpecializationGatedTrackTypes(
        { ScentTracking = true, BloodTracking = false, GunpowderSniffing = true },
        { explosives = { 'gunpowder' }, patrol = { 'blood' } },
        FLAGS)
    t.equals(#gated, 1, 'only the enabled one is named')
    t.equals(gated[1].trackType, 'gunpowder')
end)

t.test('SPECIALIZATION GATE: scent is never gated, so a scent-only config warns about nothing at all', function()
    local gated = K9SelfCheck.FindSpecializationGatedTrackTypes(
        { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true },
        {}, -- an owner who cleared Config.SpecializationTracking entirely
        FLAGS)
    t.equals(#gated, 0, 'nothing is gated, so nothing is warned about')
end)

t.test('SPECIALIZATION GATE: a missing or malformed Config.SpecializationTracking degrades to silence, never an error', function()
    t.equals(#K9SelfCheck.FindSpecializationGatedTrackTypes({ BloodTracking = true }, nil, FLAGS), 0)
    t.equals(#K9SelfCheck.FindSpecializationGatedTrackTypes({ BloodTracking = true }, 'not a table', FLAGS), 0)
    t.equals(#K9SelfCheck.FindSpecializationGatedTrackTypes({ BloodTracking = true }, { patrol = 'not a list' }, FLAGS), 0)
    t.equals(#K9SelfCheck.FindSpecializationGatedTrackTypes(nil, { patrol = { 'blood' } }, FLAGS), 0)
end)

t.test('SPECIALIZATION GATE: a trail listed under two specializations is reported once, not twice', function()
    local gated = K9SelfCheck.FindSpecializationGatedTrackTypes(
        { BloodTracking = true },
        { patrol = { 'blood' }, explosives = { 'blood' } },
        FLAGS)
    t.equals(#gated, 1, 'one trail, one line -- never duplicated per specialization that unlocks it')
    t.equals(gated[1].trackType, 'blood')
    -- WHICH specialization is named here is deliberately NOT asserted:
    -- pairs() order is implementation-defined, so either answer is correct
    -- and pinning one would make this test a coin toss. See the production
    -- function's own comment.
end)

t.test('SPECIALIZATION GATE: the result is always in ascending trail order, so the boot line never reshuffles between restarts', function()
    -- PROPERTY ASSERTION, NOT A RED-GREEN PROOF, and deliberately labelled
    -- as such: deleting the sort in the production function cannot be made
    -- to fail reliably, because pairs() may happen to yield sorted order
    -- anyway. This pins the property that matters -- an owner comparing two
    -- boot logs must not see the same facts in a different order and think
    -- something changed.
    local gated = K9SelfCheck.FindSpecializationGatedTrackTypes(
        { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true },
        { explosives = { 'gunpowder' }, patrol = { 'blood' }, narcotics = { 'scent' } },
        FLAGS)
    t.isTrue(#gated >= 2, 'need at least two entries for order to mean anything')
    for i = 2, #gated do
        t.isTrue(gated[i - 1].trackType < gated[i].trackType,
            'entry ' .. i .. ' must sort after entry ' .. (i - 1))
    end
end)

-- Roles (server/roles.lua) replaced Config.SpecializationTracking as what
-- unlocks a trail, so the boot line names roles from the live catalog.
t.test('ROLE GATE: an enabled trail some role unlocks is named with every role that unlocks it', function()
    local gated = K9SelfCheck.FindRoleGatedTrackTypes(
        { ScentTracking = true, BloodTracking = true, GunpowderSniffing = true },
        { gunpowder = { 'Explosives' }, blood = { 'Patrol', 'Search and Rescue' } },
        FLAGS)
    t.equals(#gated, 2)
    t.equals(gated[1].trackType, 'blood')
    t.equals(table.concat(gated[1].roles, ','), 'Patrol,Search and Rescue')
    t.equals(gated[2].trackType, 'gunpowder')
    t.equals(gated[2].roles[1], 'Explosives')
end)

t.test('ROLE GATE: a switched-off trail, scent, and a trail no role unlocks are never named', function()
    local gated = K9SelfCheck.FindRoleGatedTrackTypes(
        { ScentTracking = true, BloodTracking = false, GunpowderSniffing = true },
        { blood = { 'Patrol' }, scent = { 'Patrol' }, gunpowder = {} },
        FLAGS)
    t.equals(#gated, 0)
end)

t.test('ROLE GATE: missing or malformed input degrades to silence, never an error', function()
    t.equals(#K9SelfCheck.FindRoleGatedTrackTypes({ BloodTracking = true }, nil, FLAGS), 0)
    t.equals(#K9SelfCheck.FindRoleGatedTrackTypes({ BloodTracking = true }, 'nope', FLAGS), 0)
    t.equals(#K9SelfCheck.FindRoleGatedTrackTypes({ BloodTracking = true }, { blood = 'Patrol' }, FLAGS), 0)
    t.equals(#K9SelfCheck.FindRoleGatedTrackTypes(nil, { blood = { 'Patrol' } }, FLAGS), 0)
end)

-- ======================================================================
-- K9 EQUIPMENT SHOP PURCHASE-ENFORCEMENT BACKEND CHECK (coder-security,
-- this pass). The red-team finding this answers claimed that on a
-- qb-inventory server, a modified client could buy a tier/specialization-
-- gated K9 Supply shop item for free because the buyItem hook silently
-- fails to register there. VERIFIED against the real code: it does not --
-- server/equipmentshop.lua's own ActivateEquipmentShopIfEnabled already
-- refuses to ever call RegisterShop unless BOTH the openShop and buyItem
-- hooks confirm registered, so the real, current behavior on such a
-- backend is "the shop is not offered at all", never "sold unenforced".
-- These tests pin THAT fact (never re-litigate a bug that isn't there),
-- and pin the NEW part: that fact is now also visible on the one line an
-- owner actually reads (the boot summary), not just in scrollback.
--
-- RED/GREEN PROOF PERFORMED FOR THIS PASS: K9SelfCheck.EvaluateEquipmentShopEnforcement
-- was temporarily changed to `return 'ok'` unconditionally (i.e. every
-- backend "supported", the exact bug this check exists to prevent an owner
-- from being told). Every test in this section named 'unsupported_backend'
-- or 'unknown' immediately went red (clean, named assertion failures, never
-- a whole-suite crash). The file was restored to its real, working form
-- immediately afterward; the version in the working tree is the fixed one.
-- ======================================================================

--- @param inventoryBackendName string? -- nil = K9Compat.Which('inventory') itself returns nil (no usable backend detected)
--- @return table -- a fake K9Compat exposing only Which(system), which is all this check ever calls
local function fakeK9Compat(inventoryBackendName)
    return {
        Which = function(system)
            if system == 'inventory' then return inventoryBackendName end
            return nil
        end,
    }
end

t.test('EvaluateEquipmentShopEnforcement: feature off -- not_applicable, regardless of backend', function()
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(false, 'ox_inventory'), 'not_applicable')
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(nil, 'qb-inventory'), 'not_applicable')
end)

t.test('EvaluateEquipmentShopEnforcement: feature on, ox_inventory detected -- ok (the only CONFIRMED-capable backend)', function()
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(true, 'ox_inventory'), 'ok')
end)

t.test('EvaluateEquipmentShopEnforcement: feature on, qb-inventory detected -- unsupported_backend (the exact finding this check answers)', function()
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(true, 'qb-inventory'), 'unsupported_backend')
end)

t.test('EvaluateEquipmentShopEnforcement: feature on, no backend detected at all (nil) -- unsupported_backend, never treated as "unknown, say nothing"', function()
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(true, nil), 'unsupported_backend')
end)

t.test('EvaluateEquipmentShopEnforcement: feature on, some other named backend (e.g. ps-inventory) -- unsupported_backend', function()
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(true, 'ps-inventory'), 'unsupported_backend')
end)

t.test('EvaluateEquipmentShopEnforcement: feature on, an operator-authored custom adapter -- unknown, never a false "unsupported" alarm', function()
    t.equals(K9SelfCheck.EvaluateEquipmentShopEnforcement(true, 'custom'), 'unknown')
end)

t.test('FormatEquipmentShopEnforcementWarning: ok/not_applicable print nothing -- the "say nothing" cases', function()
    t.isNil(K9SelfCheck.FormatEquipmentShopEnforcementWarning('ok', 'ox_inventory'))
    t.isNil(K9SelfCheck.FormatEquipmentShopEnforcementWarning('not_applicable', nil))
end)

t.test('FormatEquipmentShopEnforcementWarning: unsupported_backend names the detected backend and is LOUD ("!!")', function()
    local line = K9SelfCheck.FormatEquipmentShopEnforcementWarning('unsupported_backend', 'qb-inventory')
    t.isNotNil(line)
    t.contains(line, '!!')
    t.contains(line, 'qb-inventory')
    t.contains(line, 'K9EquipmentShop')
end)

t.test('FormatEquipmentShopEnforcementWarning: unsupported_backend with no backend at all still names something readable, never "nil"', function()
    local line = K9SelfCheck.FormatEquipmentShopEnforcementWarning('unsupported_backend', nil)
    t.isNotNil(line)
    t.notContains(line, 'nil')
    t.contains(line, 'no inventory backend detected')
end)

t.test('FormatEquipmentShopEnforcementWarning: unknown (custom adapter) is informational, never alarming ("!!")', function()
    local line = K9SelfCheck.FormatEquipmentShopEnforcementWarning('unknown', 'custom')
    t.isNotNil(line)
    t.notContains(line, '!!', 'an unverifiable custom adapter is not a confirmed problem -- must not read as one')
end)

t.test('BuildBootSummaryLine: equipmentShop clause is omitted entirely when not_applicable (feature off)', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        databaseState = 'connected',
        equipmentShop = { status = 'not_applicable' },
    })
    t.notContains(line, 'K9 Supply shop')
end)

t.test('BuildBootSummaryLine: equipmentShop clause reports "enforced" when ok', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        databaseState = 'connected',
        equipmentShop = { status = 'ok' },
    })
    t.contains(line, 'K9 Supply shop: enforced')
end)

t.test('BuildBootSummaryLine: equipmentShop clause reports NOT offered when unsupported_backend', function()
    local line = K9SelfCheck.BuildBootSummaryLine({
        databaseState = 'connected',
        equipmentShop = { status = 'unsupported_backend' },
    })
    t.contains(line, 'K9 Supply shop: NOT offered')
end)

-- ----------------------------------------------------------------------
-- END-TO-END: real onResourceStart wiring, real K9Compat.Which() call
-- ----------------------------------------------------------------------

t.test('END-TO-END: Config.Features.K9EquipmentShop on ox_inventory prints no equipment-shop warning, and the boot summary says enforced', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB .. '\nK9EquipmentShop = { tier = \'onstart\' },' },
        config = { Features = { RadialMenu = true, K9EquipmentShop = true } },
        k9Compat = fakeK9Compat('ox_inventory'),
    })
    for _, line in ipairs(f.printedLines) do
        t.notContains(line, 'cannot enforce', 'ox_inventory is the confirmed-capable backend -- no warning expected: ' .. line)
    end
    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'K9 Supply shop: enforced')
end)

t.test('END-TO-END: Config.Features.K9EquipmentShop on qb-inventory prints a loud, named warning, and the boot summary says NOT offered -- THE EXACT RED-TEAM SCENARIO', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB .. '\nK9EquipmentShop = { tier = \'onstart\' },' },
        config = { Features = { RadialMenu = true, K9EquipmentShop = true } },
        k9Compat = fakeK9Compat('qb-inventory'),
    })
    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('!!', 1, true) and line:find('qb-inventory', 1, true) and line:find('K9EquipmentShop', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'expected a loud, named warning about qb-inventory being unable to enforce K9EquipmentShop')
    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'K9 Supply shop: NOT offered')
end)

t.test('END-TO-END: Config.Features.K9EquipmentShop off prints no equipment-shop line at all, on any backend', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB .. '\nK9EquipmentShop = { tier = \'onstart\' },' },
        config = { Features = { RadialMenu = true, K9EquipmentShop = false } },
        k9Compat = fakeK9Compat('qb-inventory'),
    })
    for _, line in ipairs(f.printedLines) do
        t.notContains(line, 'cannot enforce', 'the feature is off -- nothing about equipment-shop enforcement should be mentioned at all: ' .. line)
    end
    local lastLine = f.printedLines[#f.printedLines]
    t.notContains(lastLine, 'K9 Supply shop')
end)

t.test('END-TO-END: K9Compat entirely absent from the environment never throws -- degrades to nil backend, still reported honestly', function()
    local f = boot({
        resourceVersions = ALL_OK_VERSIONS,
        resourceFiles = { ['server/runtimecontrol.lua'] = REGISTRY_WITH_ALL_58_KEYS_STUB .. '\nK9EquipmentShop = { tier = \'onstart\' },' },
        config = { Features = { RadialMenu = true, K9EquipmentShop = true } },
        -- k9Compat deliberately omitted -- exactly the plain-Lua-sandbox shape
    })
    local lastLine = f.printedLines[#f.printedLines]
    t.contains(lastLine, 'K9 Supply shop: NOT offered', 'no K9Compat at all means no usable backend either -- must still fail closed, never silently say nothing')
end)


-- ======================================================================
-- CONFIG.DEPARTMENTS vs THE SERVER'S REAL JOBS
--
-- The worst day-one misconfiguration: Config.Departments ships 'police',
-- 'sheriff', 'bcso', and a server whose jobs are named anything else gets a
-- resource that is completely inert while the boot summary reports all
-- green -- because the feature keys and dependencies genuinely ARE fine.
-- Nothing checked this before 2026-08-31.
-- ======================================================================

t.test('FindUnknownDepartmentJobs: names that do not exist on the server are reported, sorted', function()
    local missing = K9SelfCheck.FindUnknownDepartmentJobs(
        { police = {}, lspd = {}, bcso = {} },
        { police = {}, sheriff = {}, ambulance = {} })
    t.equals(#missing, 2)
    t.equals(missing[1], 'bcso')
    t.equals(missing[2], 'lspd')
end)

t.test('FindUnknownDepartmentJobs: accepts either job-list shape, and is case-insensitive', function()
    -- A framework may hand back { police = {...} } or { 'police', ... }.
    t.equals(#K9SelfCheck.FindUnknownDepartmentJobs({ police = {} }, { 'police', 'ems' }), 0,
        'an array of job names must work as well as a keyed table')
    t.equals(#K9SelfCheck.FindUnknownDepartmentJobs({ POLICE = {} }, { police = {} }), 0,
        'job names must not be treated as case-sensitive')
end)

t.test('FindUnknownDepartmentJobs: an unreadable or empty job list reports NOTHING rather than everything', function()
    -- The critical fail-safe. If the server's job list comes back empty or
    -- malformed, every configured department would look "unknown" and the
    -- warning would scream that a correctly-configured server is broken.
    -- Silence is the only honest output when the comparison has no basis.
    t.equals(#K9SelfCheck.FindUnknownDepartmentJobs({ police = {} }, {}), 0)
    t.equals(#K9SelfCheck.FindUnknownDepartmentJobs({ police = {} }, nil), 0)
    t.equals(#K9SelfCheck.FindUnknownDepartmentJobs({ police = {} }, 'not a table'), 0)
end)

t.test('FormatUnknownDepartmentWarning: says nothing when every configured job exists', function()
    t.isNil(K9SelfCheck.FormatUnknownDepartmentWarning({}, 3))
    t.isNil(K9SelfCheck.FormatUnknownDepartmentWarning(nil, 3))
end)

t.test('FormatUnknownDepartmentWarning: a PARTIAL mismatch names the bad entries and what it costs', function()
    local line = K9SelfCheck.FormatUnknownDepartmentWarning({ 'bcso', 'lspd' }, 3)
    t.isNotNil(line)
    t.contains(line, 'bcso')
    t.contains(line, 'lspd')
    t.contains(line, '2 of 3')
    t.contains(line, 'config.lua', 'the warning must say where to fix it')
end)

t.test('FormatUnknownDepartmentWarning: a TOTAL mismatch says the resource is effectively off', function()
    -- This is the case worth wording differently. With no valid department
    -- at all, nobody can certify, reach High Command, or open the tablet --
    -- and the owner needs to be told that plainly, not given a count.
    local line = K9SelfCheck.FormatUnknownDepartmentWarning({ 'lspd', 'sast' }, 2)
    t.isNotNil(line)
    t.contains(line, 'NONE')
    t.contains(line, 'effectively off')
    t.contains(line, 'NOBODY')
end)

os.exit(t.summary())
