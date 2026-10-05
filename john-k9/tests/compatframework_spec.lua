--[[
    tests/compatframework_spec.lua

    Direct tests of shared/compat/framework.lua against the REAL, unmodified
    production file -- previously the ONLY file under shared/compat/ with no
    spec at all. Same "load the real source into a sandbox, drive it through
    its real registration/factory surface" discipline every sibling spec in
    this directory already uses (tests/compat_spec.lua, tests/
    compatinventory_spec.lua, tests/compattarget_spec.lua).

    WHY THIS FILE MATTERS: the citizenid this adapter resolves is the key
    every access decision in this resource is ultimately made against, so a
    wrong field path here is an access-control bug, not a cosmetic one.
    The one live call site that routed through K9Compat.Get('framework')
    went away with its feature on 2026-09-02, which makes this spec the
    only thing standing between a field-path regression and the next
    consumer that wires this adapter up -- and is exactly why it is kept.

    THE GAP THIS SPEC CLOSES, EXACTLY AS SCOPED: "adapter returns nil ->
    caller fails closed" was already proven at the call site. What NOTHING
    proved before this file existed is the more dangerous case: an adapter
    that returns a PLAUSIBLE-BUT-WRONG citizenid -- exactly what a
    field-path bug (reading the wrong table key) would produce, and which a
    caller's own "is this a non-empty string" check cannot catch. Every
    "FIELD-PATH CONFUSION" test below feeds one adapter a player/
    playerData object shaped like a DIFFERENT framework and asserts the
    result is nil, never the other framework's own real-looking value.

    FIELD PATHS: CONFIRMED VS INFERRED, verified independently THIS SESSION
    (2026-08-26) by fetching each project's live `main` branch directly
    (raw.githubusercontent.com), not carried over from shared/compat/
    framework.lua's own header on trust alone:
      * qbx_core (Qbox-project/qbx_core) -- CONFIRMED. server/functions.lua's
        `GetPlayer`/`GetPlayerByCitizenId` exports return `QBX.Players[...]`
        objects; server/player.lua's own `toPlayerJob` builds
        `PlayerData.job = { name, ..., grade = { name, level } }`, and
        `PlayerData.citizenid` is read directly at several log call sites in
        that same file. Client: modules/playerdata.lua sets
        `QBX.PlayerData = exports.qbx_core:GetPlayerData() or {}`, and
        client/functions.lua's own `GetPlayerData()` (exported under the same
        name) returns exactly that `QBX.PlayerData` table.
      * qb-core (qbcore-framework/qb-core) -- CONFIRMED. server/functions.lua
        exports `GetPlayer`/`GetPlayerByCitizenId`, both routing through
        server/player.lua's `buildInterface`, which sets
        `iface.PlayerData = internalPlayer.PlayerData`; server/player.lua's
        own job-assignment code (`self.PlayerData.job.grade.name/.level/...`)
        confirms the identical nested-grade-table shape qbx_core uses (fork
        lineage, independently re-verified rather than assumed identical).
        Client: shared/main.lua exports `GetCoreObject(filters)` returning
        the bare `QBCore` table when called with no filter argument, and
        client/functions.lua's `GetPlayerData(cb)` returns
        `QBCore.PlayerData` SYNCHRONOUSLY -- and ONLY synchronously -- when
        called with zero arguments (`if not cb then return QBCore.PlayerData
        end`); passing any argument switches it into an async
        callback-invocation branch instead, which is exactly why one test
        below asserts framework.lua's own call passes zero arguments.
      * es_extended (esx-framework/esx_core, `[core]/es_extended` subfolder)
        -- CONFIRMED. server/classes/player.lua: `getIdentifier`/`getJob` are
        OBJECT-BOUND CLOSURES over an outer `self` (`function self.getJob()
        return self.job end`), never `:`-called methods -- confirmed by
        reading the constructor directly, matching framework.lua's own
        header claim exactly. `self.setJob` builds `self.job = { ..., grade
        = tonumber(grade) or 0, grade_name, grade_label, ... }` -- a BARE
        INTEGER grade, never a nested table, the one genuine shape
        divergence from qbx_core/qb-core. shared/main.lua exports
        `getSharedObject()` returning the bare `ESX` table on both realms;
        server/functions.lua's `ESX.GetPlayerFromId`/`GetPlayerFromIdentifier`
        return `ESX.Players[...]`/`Core.playersByIdentifier[...]` entries;
        client/functions.lua's `ESX.GetPlayerData()` returns `ESX.PlayerData`.
      Nothing in this file's field-path assertions is graded "inferred" --
      every one above was re-derived from a primary source fetched this
      session, independently of shared/compat/framework.lua's own header.

    HEADLINE FINDING: no fail-open path found. Every gating/malformed-input/
    throwing-export/cross-framework-shape scenario exercised below resolves
    to nil (GetCitizenId/GetPlayer/GetPlayerByCitizenId/GetPlayerData) or
    `nil, nil` (GetJob) -- and any caller treating a non-string or
    empty-string citizenid as "cannot resolve" reaches a fail-closed
    outcome from every one of them. The one non-obvious, DISCLOSED (not a bug) observation: because
    GradeLevel() itself already tolerates BOTH a bare integer and a
    `{ level = n }` table, feeding an adapter a differently-framed job
    object still recovers a plausible grade level in a few cases below --
    this is never a citizenid-equivalent risk, because GetJob's result
    gates access nowhere in this resource.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Load helper -- same "fake K9Compat capturing RegisterAdapter" convention
-- as compattarget_spec.lua/compatinventory_spec.lua's own loaders.
-- ----------------------------------------------------------------------

--- @param opts table? -- { resourceStates, exportsStub, omitK9Compat, brokenK9Compat }
--- @return table registered -- [system][resourceName] = factory
--- @return table env
local function loadFrameworkCompat(opts)
    opts = opts or {}
    local registered = {}
    local resourceStates = opts.resourceStates or {}

    local function GetResourceState(resourceName)
        return resourceStates[resourceName] or 'missing'
    end

    local exportsStub = opts.exportsStub or {}

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Same explicit if/elseif/else as compattarget_spec.lua's own loader --
    -- NOT the classic `x and y or z` idiom, which breaks the instant `y`
    -- itself is nil/false.
    local fakeK9Compat = nil
    if opts.brokenK9Compat then
        fakeK9Compat = { RegisterAdapter = 'not-a-function' }
    elseif not opts.omitK9Compat then
        fakeK9Compat = {
            RegisterAdapter = function(system, resourceName, factory)
                registered[system] = registered[system] or {}
                registered[system][resourceName] = factory
            end,
        }
    end

    local env = Sandbox.newEnv({
        K9Compat = fakeK9Compat,
        GetResourceState = GetResourceState,
        exports = exportsStub,
        print = printStub,
    })

    Sandbox.loadInto('../shared/compat/framework.lua', env)
    env.__printedLines = printedLines
    return registered, env
end

-- ----------------------------------------------------------------------
-- Export-fixture helpers
-- ----------------------------------------------------------------------

--- Wraps a plain `function(...)` into the `(self, ...)` shape every real
--- `target[methodName](target, ...)` call in shared/compat/framework.lua's
--- own SafeCall actually uses.
--- @param fn function
--- @return function
local function asExportMethod(fn)
    return function(_self, ...) return fn(...) end
end

--- @param message string?
--- @return function
local function throwingExportMethod(message)
    return asExportMethod(function() error(message or 'boom: third-party export exploded') end)
end

--- Simulates a per-resource export table that THROWS merely on being
--- indexed for a method name -- e.g. a hostile/broken exports proxy, not
--- just a throwing method call. Exercises IsExportCapable's own pcall
--- around `exports[resourceName][methodName]` (see shared/compat/
--- framework.lua's header on why that probe is pcall-wrapped at all).
--- @return table
local function throwingExportsTable()
    return setmetatable({}, { __index = function() error('exports proxy exploded') end })
end

-- ----------------------------------------------------------------------
-- Player/job fixture builders
-- ----------------------------------------------------------------------

--- Builds a qbx_core/qb-core-SHAPED player object -- both frameworks are
--- CONFIRMED (this file's own header) to expose an IDENTICAL
--- `player.PlayerData.citizenid` / `player.PlayerData.job = { name, grade =
--- { name, level } }` shape, by fork lineage. Every DECOY field below
--- exists specifically to catch a field-path regression: if GetCitizenId/
--- GetJob is ever edited to read the wrong key, one of these decoys is what
--- a test that only checked "returns A string"/"returns A number" would
--- then silently accept instead -- these tests check the EXACT value.
--- @param opts table { citizenid, decoyTopLevelCitizenId, decoyLicense, job }
--- @return table player
local function qbxLikePlayer(opts)
    opts = opts or {}
    local player = {
        -- DECOY: a bare top-level `.citizenid` -- neither qb-core's real
        -- `buildInterface` nor qbx_core's raw `QBX.Players[...]` entry sets
        -- one (confirmed against both projects' source this session), but
        -- if a future edit ever reads `player.citizenid` instead of
        -- `player.PlayerData.citizenid`, this decoy makes that regression
        -- fail LOUD instead of silently "working".
        citizenid = opts.decoyTopLevelCitizenId,
    }
    player.PlayerData = {
        citizenid = opts.citizenid,
        -- DECOY: a REAL, DIFFERENT qb/qbx field (server/player.lua's own
        -- log lines print PlayerData.citizenid specifically BECAUSE
        -- .license is a distinct field on the same table) -- must never be
        -- confused with citizenid.
        license = opts.decoyLicense,
        job = opts.job,
    }
    return player
end

--- @param opts table { name, label, gradeLevel, gradeName, decoyTopLevelLevel, rawGrade }
--- @return table job
local function qbxLikeJob(opts)
    opts = opts or {}
    local job = { name = opts.name, label = opts.label, isboss = false }
    if opts.rawGrade ~= nil then
        job.grade = opts.rawGrade
        return job
    end
    if opts.gradeLevel ~= nil then
        job.grade = { name = opts.gradeName or 'rank', level = opts.gradeLevel }
    end
    -- DECOY: a top-level job.level, distinct from the real job.grade.level.
    job.level = opts.decoyTopLevelLevel
    return job
end

--- Client-realm equivalent of qbxLikePlayer -- GetPlayerData() returns the
--- PlayerData shape directly, not wrapped in another `.PlayerData` level.
--- @param opts table { citizenid, decoyIdentifier, job }
--- @return table playerData
local function qbxLikePlayerData(opts)
    opts = opts or {}
    return {
        citizenid = opts.citizenid,
        -- DECOY: an ESX-style `.identifier` field coexisting on the same
        -- table -- proves this adapter reads `.citizenid` specifically,
        -- never falls back to a same-table `.identifier`.
        identifier = opts.decoyIdentifier,
        job = opts.job,
    }
end

--- Real ESX xPlayer object shape -- CONFIRMED against esx-framework/
--- esx_core's server/classes/player.lua this session: `getIdentifier`/
--- `getJob` are object-bound closures over an OUTER `self` variable, NOT
--- `:`-called methods -- so these closures deliberately take ZERO
--- parameters, exactly like the real ones (a `function(self) ... end`
--- fixture would be testing against the WRONG calling convention).
--- @param opts table { identifier, job, withGetIdentifier, withGetJob }
--- @return table player
local function esxLikePlayer(opts)
    opts = opts or {}
    local player = { identifier = opts.identifier, job = opts.job }
    if opts.withGetIdentifier ~= false then
        player.getIdentifier = function() return player.identifier end
    end
    if opts.withGetJob ~= false then
        player.getJob = function() return player.job end
    end
    return player
end

--- @param opts table { id, name, label, type, grade, gradeName, gradeLabel, gradeSalary }
--- @return table job
local function esxLikeJob(opts)
    opts = opts or {}
    return {
        id = opts.id, name = opts.name, label = opts.label, type = opts.type, onDuty = true,
        grade = opts.grade, -- BARE INTEGER -- confirmed, never a nested table on real ESX
        grade_name = opts.gradeName, grade_label = opts.gradeLabel, grade_salary = opts.gradeSalary,
    }
end

-- ========================================================================
-- STRUCTURAL: load guard + coverage completeness
-- ========================================================================

t.test('loading framework.lua with no K9Compat global present never throws and registers nothing', function()
    local ok, registeredOrErr = pcall(function()
        return loadFrameworkCompat({ omitK9Compat = true })
    end)
    t.isTrue(ok, 'must not throw merely because K9Compat is not yet loaded')
    t.equals(next(registeredOrErr), nil, 'nothing should have been registered anywhere')
end)

t.test('loading framework.lua with a K9Compat table whose RegisterAdapter is not a function warns and never throws', function()
    local registered, env
    local ok = pcall(function()
        registered, env = loadFrameworkCompat({ brokenK9Compat = true })
    end)
    t.isTrue(ok)
    t.equals(next(registered), nil)
    local sawWarning = false
    for _, line in ipairs(env.__printedLines) do
        if line:find('K9Compat is not available', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning)
end)

t.test('coverage completeness: exactly qbx_core, qb-core, es_extended are registered under framework, matching config.lua\'s Config.Compat.Systems.framework.candidates list', function()
    local registered = loadFrameworkCompat({})
    local names = {}
    for name in pairs(registered.framework) do names[#names + 1] = name end
    table.sort(names)
    t.equals(#names, 3)
    local expected = { 'es_extended', 'qb-core', 'qbx_core' } -- sorted
    for i, name in ipairs(expected) do
        t.equals(names[i], name)
    end
end)

-- ========================================================================
-- qbx_core / qb-core -- IDENTICAL server-realm contract by fork lineage
-- (independently confirmed, not assumed -- see header). Parameterized over
-- both resource names so a regression in either shows up with that
-- resource's own name in the failing test, not a shared anonymous one.
-- ========================================================================

--- @param resourceName string -- 'qbx_core' | 'qb-core'
local function describeSharedServerContract(resourceName)
    local function factoryFor(opts)
        local registered = loadFrameworkCompat(opts)
        return registered.framework[resourceName]
    end

    t.test(('%s server factory: nil for both realms when the resource is not started'):format(resourceName), function()
        local factory = factoryFor({ resourceStates = {} })
        t.isNotNil(factory, 'the factory itself must still be registered even when the backing resource is absent')
        t.isNil(factory('server'))
        t.isNil(factory('client'))
    end)

    t.test(('%s server factory: nil when GetPlayer is missing'):format(resourceName), function()
        local factory = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = { GetPlayerByCitizenId = asExportMethod(function() end) } },
        })
        t.isNil(factory('server'))
    end)

    t.test(('%s server factory: nil when GetPlayerByCitizenId is missing'):format(resourceName), function()
        local factory = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = { GetPlayer = asExportMethod(function() end) } },
        })
        t.isNil(factory('server'))
    end)

    t.test(('%s server factory: nil when a required export exists but is not a function'):format(resourceName), function()
        local factory1 = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = { GetPlayer = 'not-a-function', GetPlayerByCitizenId = asExportMethod(function() end) } },
        })
        t.isNil(factory1('server'))

        local factory2 = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = { GetPlayer = asExportMethod(function() end), GetPlayerByCitizenId = 42 } },
        })
        t.isNil(factory2('server'))
    end)

    t.test(('%s server factory: nil, never throws, when merely PROBING the export table itself throws'):format(resourceName), function()
        local factory = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = throwingExportsTable() },
        })
        local ok, adapter = pcall(factory, 'server')
        t.isTrue(ok, 'a throwing exports proxy must never propagate out of the factory')
        t.isNil(adapter)
    end)

    t.test(('%s server factory: a full 4-method adapter when both exports are present'):format(resourceName), function()
        local adapter = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = {
                GetPlayer = asExportMethod(function() end),
                GetPlayerByCitizenId = asExportMethod(function() end),
            } },
        })('server')
        t.isNotNil(adapter)
        for _, methodName in ipairs({ 'GetPlayer', 'GetPlayerByCitizenId', 'GetCitizenId', 'GetJob' }) do
            t.equals(type(adapter[methodName]), 'function', methodName .. ' must be a function')
        end
    end)

    t.test(('%s GetPlayer/GetPlayerByCitizenId: pass the export result through unchanged'):format(resourceName), function()
        local sentinel = { PlayerData = { citizenid = 'PASSTHRU-1' } }
        local calls = {}
        local adapter = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = {
                GetPlayer = function(_self, source) calls[#calls + 1] = { 'GetPlayer', source }; return sentinel end,
                GetPlayerByCitizenId = function(_self, cid) calls[#calls + 1] = { 'GetPlayerByCitizenId', cid }; return sentinel end,
            } },
        })('server')

        t.equals(adapter.GetPlayer(99), sentinel)
        t.equals(calls[1][2], 99)
        t.equals(adapter.GetPlayerByCitizenId('CID-1'), sentinel)
        t.equals(calls[2][2], 'CID-1')
    end)

    t.test(('%s GetPlayer/GetPlayerByCitizenId: fail closed (nil), never throw, when the export itself throws'):format(resourceName), function()
        local adapter = factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = {
                GetPlayer = throwingExportMethod(),
                GetPlayerByCitizenId = throwingExportMethod(),
            } },
        })('server')

        local ok1, result1 = pcall(adapter.GetPlayer, 1)
        t.isTrue(ok1)
        t.isNil(result1)

        local ok2, result2 = pcall(adapter.GetPlayerByCitizenId, 'x')
        t.isTrue(ok2)
        t.isNil(result2)
    end)

    -- ================================================================
    -- GetCitizenId / GetJob field-path correctness -- THE GAP THIS SPEC
    -- EXISTS TO CLOSE. A passing test here means the field path is
    -- provably right TODAY; a future edit that swaps in the wrong field
    -- breaks one of the decoy assertions below instead of shipping
    -- silently.
    -- ================================================================

    local function newAdapter()
        return factoryFor({
            resourceStates = { [resourceName] = 'started' },
            exportsStub = { [resourceName] = {
                GetPlayer = asExportMethod(function() end),
                GetPlayerByCitizenId = asExportMethod(function() end),
            } },
        })('server')
    end

    t.test(('%s GetCitizenId: reads PlayerData.citizenid -- CONFIRMED field path -- never the decoy top-level .citizenid or PlayerData.license'):format(resourceName), function()
        local adapter = newAdapter()
        local player = qbxLikePlayer({
            citizenid = 'REAL-CID-1',
            decoyTopLevelCitizenId = 'WRONG-TOPLEVEL-CID',
            decoyLicense = 'license:deadbeef',
        })
        t.equals(adapter.GetCitizenId(player), 'REAL-CID-1')
    end)

    t.test(('%s GetJob: reads job.name / job.grade.level -- CONFIRMED field path -- never the decoy job.level'):format(resourceName), function()
        local adapter = newAdapter()
        local player = qbxLikePlayer({
            citizenid = 'CID-2',
            job = qbxLikeJob({ name = 'police', gradeLevel = 3, gradeName = 'officer', decoyTopLevelLevel = 999 }),
        })
        local jobName, jobGradeLevel = adapter.GetJob(player)
        t.equals(jobName, 'police')
        t.equals(jobGradeLevel, 3)
    end)

    t.test(('%s GetJob returns exactly two values (name, level), never a third'):format(resourceName), function()
        local adapter = newAdapter()
        local player = qbxLikePlayer({ citizenid = 'CID-3', job = qbxLikeJob({ name = 'ambulance', gradeLevel = 0 }) })
        local results = { adapter.GetJob(player) }
        t.equals(#results, 2)
    end)

    t.test(('%s GetCitizenId/GetJob: FIELD-PATH CONFUSION -- an es_extended-SHAPED player (top-level .identifier, bare-integer .job.grade, no .PlayerData) resolves to nil, never the ESX identifier -- the "plausible-but-wrong citizenid" case this spec exists to guard against'):format(resourceName), function()
        local adapter = newAdapter()
        local esxShaped = { identifier = 'license:esx-account-should-not-leak', job = { name = 'police', grade = 4 } }
        t.isNil(adapter.GetCitizenId(esxShaped), 'must fail closed, never fall through to a differently-framed identifier field')
        local jobName, jobGradeLevel = adapter.GetJob(esxShaped)
        t.isNil(jobName)
        t.isNil(jobGradeLevel)
    end)

    t.test(('%s GetCitizenId/GetJob: fail closed (never throw) on nil/string/number/empty-table/malformed player values'):format(resourceName), function()
        local adapter = newAdapter()
        local badPlayers = { nil, 'a-string', 42, {}, { PlayerData = {} }, { PlayerData = { job = 'not-a-table' } } }
        for _, badPlayer in ipairs(badPlayers) do
            local ok1, cid = pcall(adapter.GetCitizenId, badPlayer)
            t.isTrue(ok1, 'GetCitizenId must never throw for ' .. tostring(badPlayer))
            t.isNil(cid)

            local ok2, jobName, jobGradeLevel = pcall(adapter.GetJob, badPlayer)
            t.isTrue(ok2, 'GetJob must never throw for ' .. tostring(badPlayer))
            t.isNil(jobName)
            t.isNil(jobGradeLevel)
        end
    end)

    t.test(('%s GetJob: a grade table missing its own .level field resolves to a nil level, not a crash or a wrong number'):format(resourceName), function()
        local adapter = newAdapter()
        local player = qbxLikePlayer({ citizenid = 'CID-4', job = qbxLikeJob({ name = 'police', rawGrade = { name = 'rookie' } }) })
        local jobName, jobGradeLevel = adapter.GetJob(player)
        t.equals(jobName, 'police')
        t.isNil(jobGradeLevel)
    end)

    t.test(('%s GetCitizenId: an empty-string citizenid is returned as-is -- this file does not judge string content; a caller\'s own check is what rejects ""'):format(resourceName), function()
        local adapter = newAdapter()
        local player = qbxLikePlayer({ citizenid = '' })
        t.equals(adapter.GetCitizenId(player), '')
    end)
end

describeSharedServerContract('qbx_core')
describeSharedServerContract('qb-core')

-- ========================================================================
-- qbx_core -- client realm (direct GetPlayerData export)
-- ========================================================================

t.test('qbx_core client factory: nil when the resource is not started', function()
    local registered = loadFrameworkCompat({ resourceStates = {} })
    t.isNil(registered.framework.qbx_core('client'))
end)

t.test('qbx_core client factory: nil when GetPlayerData export is missing', function()
    local registered = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = {} },
    })
    t.isNil(registered.framework.qbx_core('client'))
end)

t.test('qbx_core client factory: a GetPlayerData-only adapter when the export is present', function()
    local registered = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = { GetPlayerData = asExportMethod(function() end) } },
    })
    local adapter = registered.framework.qbx_core('client')
    t.isNotNil(adapter)
    t.equals(type(adapter.GetPlayerData), 'function')
end)

t.test('qbx_core client GetPlayerData: fails closed (nil), never throws, when the export itself throws', function()
    local registered = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = { GetPlayerData = throwingExportMethod() } },
    })
    local ok, result = pcall(registered.framework.qbx_core('client').GetPlayerData)
    t.isTrue(ok)
    t.isNil(result)
end)

t.test('qbx_core client GetPlayerData: nil for nil/string/number export results; a well-shaped-but-empty table for an empty-table result', function()
    for _, badValue in ipairs({ 'x', 7 }) do
        local registered = loadFrameworkCompat({
            resourceStates = { qbx_core = 'started' },
            exportsStub = { qbx_core = { GetPlayerData = asExportMethod(function() return badValue end) } },
        })
        t.isNil(registered.framework.qbx_core('client').GetPlayerData())
    end
    local registeredNil = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = { GetPlayerData = asExportMethod(function() return nil end) } },
    })
    t.isNil(registeredNil.framework.qbx_core('client').GetPlayerData())

    local registeredEmpty = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = { GetPlayerData = asExportMethod(function() return {} end) } },
    })
    local result = registeredEmpty.framework.qbx_core('client').GetPlayerData()
    t.isNotNil(result, 'an empty-but-well-formed table is returned, never nil')
    t.isNil(result.citizenid)
    t.isNil(result.job.name)
    t.isNil(result.job.grade)
end)

t.test('qbx_core client GetPlayerData: CORRECT FIELD PATH -- citizenid/job.name/job.grade.level, never the decoy .identifier', function()
    local playerData = qbxLikePlayerData({
        citizenid = 'CLIENT-CID-1',
        decoyIdentifier = 'license:should-never-be-read',
        job = qbxLikeJob({ name = 'police', gradeLevel = 2 }),
    })
    local registered = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = { GetPlayerData = asExportMethod(function() return playerData end) } },
    })
    local result = registered.framework.qbx_core('client').GetPlayerData()
    t.equals(result.citizenid, 'CLIENT-CID-1')
    t.equals(result.job.name, 'police')
    t.equals(result.job.grade, 2)
end)

t.test('qbx_core client GetPlayerData: FIELD-PATH CONFUSION -- an es_extended-shaped playerData (.identifier, bare-int job.grade) yields a nil citizenid, never the identifier value', function()
    local registered = loadFrameworkCompat({
        resourceStates = { qbx_core = 'started' },
        exportsStub = { qbx_core = { GetPlayerData = asExportMethod(function()
            return { identifier = 'license:esx-account-should-not-leak', job = { name = 'police', grade = 4 } }
        end) } },
    })
    local result = registered.framework.qbx_core('client').GetPlayerData()
    t.isNil(result.citizenid, 'must never silently promote a differently-framed identifier into citizenid')
    t.equals(result.job.name, 'police')
    t.equals(result.job.grade, 4, 'GradeLevel() itself is shape-tolerant of a bare integer -- not a citizenid-equivalent risk, since GetPlayerData\'s .job is never used for an access decision anywhere in this resource')
end)

-- ========================================================================
-- qb-core -- client realm (GetCoreObject -> Functions.GetPlayerData)
-- ========================================================================

t.test('qb-core client factory: nil when the resource is not started', function()
    local registered = loadFrameworkCompat({ resourceStates = {} })
    t.isNil(registered.framework['qb-core']('client'))
end)

t.test('qb-core client factory: nil when GetCoreObject export is missing', function()
    local registered = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = {} },
    })
    t.isNil(registered.framework['qb-core']('client'))
end)

t.test('qb-core client factory: an adapter is returned once GetCoreObject exists, even before Functions.GetPlayerData is checked -- that check is deferred to call time', function()
    local registered = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function() return {} end) } },
    })
    local adapter = registered.framework['qb-core']('client')
    t.isNotNil(adapter, 'GetCoreObject alone is the only registration-time capability check for this adapter')
    t.equals(type(adapter.GetPlayerData), 'function')
end)

t.test('qb-core client GetPlayerData: fails closed, never throws, when GetCoreObject itself throws', function()
    local registered = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = { GetCoreObject = throwingExportMethod() } },
    })
    local ok, result = pcall(registered.framework['qb-core']('client').GetPlayerData)
    t.isTrue(ok)
    t.isNil(result)
end)

t.test('qb-core client GetPlayerData: nil when GetCoreObject returns nil/string/number/a table with no usable .Functions', function()
    local cores = { 'x', 5, {}, { Functions = 'not-a-table' } }
    for _, core in ipairs(cores) do
        local registered = loadFrameworkCompat({
            resourceStates = { ['qb-core'] = 'started' },
            exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function() return core end) } },
        })
        t.isNil(registered.framework['qb-core']('client').GetPlayerData())
    end
    local registeredNil = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function() return nil end) } },
    })
    t.isNil(registeredNil.framework['qb-core']('client').GetPlayerData())
end)

t.test('qb-core client GetPlayerData: nil when Functions.GetPlayerData is missing or not a function', function()
    local functionsTables = { {}, { GetPlayerData = 'nope' } }
    for _, functionsTable in ipairs(functionsTables) do
        local registered = loadFrameworkCompat({
            resourceStates = { ['qb-core'] = 'started' },
            exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function() return { Functions = functionsTable } end) } },
        })
        t.isNil(registered.framework['qb-core']('client').GetPlayerData())
    end
end)

t.test('qb-core client GetPlayerData: fails closed, never throws, when Functions.GetPlayerData itself throws', function()
    local registered = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function()
            return { Functions = { GetPlayerData = function() error('boom') end } }
        end) } },
    })
    local ok, result = pcall(registered.framework['qb-core']('client').GetPlayerData)
    t.isTrue(ok)
    t.isNil(result)
end)

t.test('qb-core client GetPlayerData: CORRECT FIELD PATH -- calls Functions.GetPlayerData with ZERO arguments (the confirmed synchronous branch), reading citizenid/job.name/job.grade.level from its result', function()
    local seenArgCount
    local playerData = qbxLikePlayerData({
        citizenid = 'QB-CLIENT-CID-1',
        decoyIdentifier = 'license:should-never-be-read',
        job = qbxLikeJob({ name = 'ambulance', gradeLevel = 1 }),
    })
    local registered = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function()
            return { Functions = { GetPlayerData = function(...)
                seenArgCount = select('#', ...)
                return playerData
            end } }
        end) } },
    })
    local result = registered.framework['qb-core']('client').GetPlayerData()
    t.equals(seenArgCount, 0, 'must call GetPlayerData with zero arguments -- passing a callback switches real qb-core into its async branch instead of returning synchronously')
    t.equals(result.citizenid, 'QB-CLIENT-CID-1')
    t.equals(result.job.name, 'ambulance')
    t.equals(result.job.grade, 1)
end)

t.test('qb-core client GetPlayerData: FIELD-PATH CONFUSION -- an es_extended-shaped playerData yields a nil citizenid, never the identifier', function()
    local registered = loadFrameworkCompat({
        resourceStates = { ['qb-core'] = 'started' },
        exportsStub = { ['qb-core'] = { GetCoreObject = asExportMethod(function()
            return { Functions = { GetPlayerData = function()
                return { identifier = 'license:esx-account-should-not-leak', job = { name = 'police', grade = 4 } }
            end } }
        end) } },
    })
    local result = registered.framework['qb-core']('client').GetPlayerData()
    t.isNil(result.citizenid)
    t.equals(result.job.name, 'police')
end)

-- ========================================================================
-- es_extended -- registration/gating (shared by both realms)
-- ========================================================================

t.test('es_extended factory: nil for both realms when the resource is not started', function()
    local registered = loadFrameworkCompat({ resourceStates = {} })
    t.isNil(registered.framework.es_extended('server'))
    t.isNil(registered.framework.es_extended('client'))
end)

t.test('es_extended factory: nil for both realms when getSharedObject export is missing', function()
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = {} },
    })
    t.isNil(registered.framework.es_extended('server'))
    t.isNil(registered.framework.es_extended('client'))
end)

t.test('es_extended factory: nil, never throws, when merely PROBING the export table itself throws', function()
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = throwingExportsTable() },
    })
    local ok, adapter = pcall(registered.framework.es_extended, 'server')
    t.isTrue(ok)
    t.isNil(adapter)
end)

t.test('es_extended factory: a full 4-method server adapter once getSharedObject exists, even before any ESX method exists -- deferred to call time', function()
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = { getSharedObject = asExportMethod(function() return {} end) } },
    })
    local adapter = registered.framework.es_extended('server')
    t.isNotNil(adapter)
    for _, methodName in ipairs({ 'GetPlayer', 'GetPlayerByCitizenId', 'GetCitizenId', 'GetJob' }) do
        t.equals(type(adapter[methodName]), 'function', methodName .. ' must be a function')
    end
end)

t.test('es_extended factory: a GetPlayerData-only client adapter once getSharedObject exists', function()
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = { getSharedObject = asExportMethod(function() return {} end) } },
    })
    local adapter = registered.framework.es_extended('client')
    t.isNotNil(adapter)
    t.equals(type(adapter.GetPlayerData), 'function')
end)

-- ========================================================================
-- es_extended -- server realm
-- ========================================================================

--- @param getSharedObjectResult any
--- @return table adapter
local function esxServerAdapter(getSharedObjectResult)
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = { getSharedObject = asExportMethod(function() return getSharedObjectResult end) } },
    })
    return registered.framework.es_extended('server')
end

t.test('es_extended GetPlayer/GetPlayerByCitizenId: fail closed, never throw, when getSharedObject itself throws', function()
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = { getSharedObject = throwingExportMethod() } },
    })
    local adapter = registered.framework.es_extended('server')
    local ok1, r1 = pcall(adapter.GetPlayer, 1)
    t.isTrue(ok1)
    t.isNil(r1)
    local ok2, r2 = pcall(adapter.GetPlayerByCitizenId, 'x')
    t.isTrue(ok2)
    t.isNil(r2)
end)

t.test('es_extended GetPlayer/GetPlayerByCitizenId: nil when getSharedObject returns nil/string/number/a table missing the needed method', function()
    local esxObjects = { nil, 'x', 3, {}, { GetPlayerFromId = 'nope', GetPlayerFromIdentifier = 'nope' } }
    for _, esx in ipairs(esxObjects) do
        local adapter = esxServerAdapter(esx)
        t.isNil(adapter.GetPlayer(1))
        t.isNil(adapter.GetPlayerByCitizenId('x'))
    end
end)

t.test('es_extended GetPlayer/GetPlayerByCitizenId: fail closed when ESX.GetPlayerFromId/GetPlayerFromIdentifier itself throws', function()
    local adapter = esxServerAdapter({
        GetPlayerFromId = function() error('boom') end,
        GetPlayerFromIdentifier = function() error('boom') end,
    })
    local ok1, r1 = pcall(adapter.GetPlayer, 1)
    t.isTrue(ok1)
    t.isNil(r1)
    local ok2, r2 = pcall(adapter.GetPlayerByCitizenId, 'x')
    t.isTrue(ok2)
    t.isNil(r2)
end)

t.test('es_extended GetPlayer/GetPlayerByCitizenId: pass through the real ESX call unchanged, keyed by identifier not citizenid', function()
    local sentinel = { identifier = 'license:passthru' }
    local calls = {}
    local adapter = esxServerAdapter({
        GetPlayerFromId = function(source) calls[#calls + 1] = { 'ById', source }; return sentinel end,
        GetPlayerFromIdentifier = function(identifier) calls[#calls + 1] = { 'ByIdentifier', identifier }; return sentinel end,
    })
    t.equals(adapter.GetPlayer(42), sentinel)
    t.equals(calls[1][2], 42)
    t.equals(adapter.GetPlayerByCitizenId('license:x'), sentinel)
    t.equals(calls[2][2], 'license:x')
end)

t.test('es_extended GetCitizenId: CORRECT FIELD PATH -- calls the object-bound getIdentifier() closure with zero arguments', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ identifier = 'license:real-1' })
    t.equals(adapter.GetCitizenId(player), 'license:real-1')
end)

t.test('es_extended GetCitizenId: falls back to the raw .identifier field when getIdentifier is absent', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ identifier = 'license:real-2', withGetIdentifier = false })
    t.equals(adapter.GetCitizenId(player), 'license:real-2')
end)

t.test('es_extended GetCitizenId: falls back to the raw .identifier field when getIdentifier throws', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ identifier = 'license:real-3' })
    player.getIdentifier = function() error('boom') end
    t.equals(adapter.GetCitizenId(player), 'license:real-3')
end)

t.test('es_extended GetCitizenId: falls back to .identifier when getIdentifier is present but returns nil', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ identifier = 'license:real-4' })
    player.getIdentifier = function() return nil end
    t.equals(adapter.GetCitizenId(player), 'license:real-4')
end)

t.test('es_extended GetCitizenId: fails closed (nil), never throws, for nil/string/number/empty-table player values', function()
    local adapter = esxServerAdapter({})
    local badPlayers = { nil, 'x', 5, {} }
    for _, badPlayer in ipairs(badPlayers) do
        local ok, cid = pcall(adapter.GetCitizenId, badPlayer)
        t.isTrue(ok)
        t.isNil(cid)
    end
end)

t.test('es_extended GetCitizenId: FIELD-PATH CONFUSION -- a qbx_core/qb-core-SHAPED player (nested .PlayerData.citizenid, no top-level .identifier, no getIdentifier) resolves to nil, never digs into the nested PlayerData table -- the "plausible-but-wrong citizenid" case', function()
    local adapter = esxServerAdapter({})
    local qbxShaped = qbxLikePlayer({ citizenid = 'QBX-SHOULD-NOT-LEAK-AS-ESX-IDENTIFIER' })
    t.isNil(adapter.GetCitizenId(qbxShaped))
end)

t.test('es_extended GetCitizenId: a getIdentifier closure present alongside a decoy nested .PlayerData.citizenid still returns the real .identifier value, not the decoy', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ identifier = 'license:real-5' })
    player.PlayerData = { citizenid = 'DECOY-SHOULD-NOT-BE-READ' }
    t.equals(adapter.GetCitizenId(player), 'license:real-5')
end)

t.test('es_extended GetJob: CORRECT FIELD PATH -- calls the object-bound getJob() closure; grade is a BARE INTEGER, confirmed, never nested', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ job = esxLikeJob({ name = 'police', grade = 3, gradeName = 'boss' }) })
    local jobName, jobGradeLevel = adapter.GetJob(player)
    t.equals(jobName, 'police')
    t.equals(jobGradeLevel, 3, 'must read the bare-integer grade directly, never .grade_name or a nested .grade.level that does not exist on real ESX')
end)

t.test('es_extended GetJob: falls back to the raw .job field when getJob is absent', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ job = esxLikeJob({ name = 'ambulance', grade = 0 }), withGetJob = false })
    local jobName, jobGradeLevel = adapter.GetJob(player)
    t.equals(jobName, 'ambulance')
    t.equals(jobGradeLevel, 0)
end)

t.test('es_extended GetJob: falls back to raw .job when getJob throws', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ job = esxLikeJob({ name = 'ambulance', grade = 1 }) })
    player.getJob = function() error('boom') end
    local jobName, jobGradeLevel = adapter.GetJob(player)
    t.equals(jobName, 'ambulance')
    t.equals(jobGradeLevel, 1)
end)

t.test('es_extended GetJob: falls back to raw .job when getJob succeeds but returns nil', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ job = esxLikeJob({ name = 'ambulance', grade = 2 }) })
    player.getJob = function() return nil end
    local jobName, jobGradeLevel = adapter.GetJob(player)
    t.equals(jobName, 'ambulance')
    t.equals(jobGradeLevel, 2)
end)

t.test('es_extended GetJob: fails closed (nil, nil), never throws, when getJob returns a non-table truthy value (Lua\'s own "" is truthy" footgun)', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ withGetJob = false })
    player.job = nil
    player.getJob = function() return '' end -- '' is truthy in Lua -- must still fail closed, never be indexed as a table
    local ok, jobName, jobGradeLevel = pcall(adapter.GetJob, player)
    t.isTrue(ok, 'must never attempt to index a non-table job result')
    t.isNil(jobName)
    t.isNil(jobGradeLevel)
end)

t.test('es_extended GetJob: fails closed for nil/string/number/empty-table player values', function()
    local adapter = esxServerAdapter({})
    local badPlayers = { nil, 'x', 5, {} }
    for _, badPlayer in ipairs(badPlayers) do
        local ok, jobName, jobGradeLevel = pcall(adapter.GetJob, badPlayer)
        t.isTrue(ok)
        t.isNil(jobName)
        t.isNil(jobGradeLevel)
    end
end)

t.test('es_extended GetJob: a job table missing .name still resolves a real .grade', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ job = { grade = 5 } })
    local jobName, jobGradeLevel = adapter.GetJob(player)
    t.isNil(jobName)
    t.equals(jobGradeLevel, 5)
end)

t.test('es_extended GetJob: a qbx_core/qb-core-SHAPED job (nested .grade.level, no getJob function) still resolves correctly via GradeLevel()\'s own dual-shape handling -- documented, not a bug: GetJob never gates access anywhere in this resource', function()
    local adapter = esxServerAdapter({})
    local player = esxLikePlayer({ withGetJob = false })
    player.job = qbxLikeJob({ name = 'police', gradeLevel = 7 })
    local jobName, jobGradeLevel = adapter.GetJob(player)
    t.equals(jobName, 'police')
    t.equals(jobGradeLevel, 7)
end)

-- ========================================================================
-- es_extended -- client realm
-- ========================================================================

--- @param getSharedObjectResult any
--- @return table adapter
local function esxClientAdapter(getSharedObjectResult)
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = { getSharedObject = asExportMethod(function() return getSharedObjectResult end) } },
    })
    return registered.framework.es_extended('client')
end

t.test('es_extended client GetPlayerData: fails closed when getSharedObject throws', function()
    local registered = loadFrameworkCompat({
        resourceStates = { es_extended = 'started' },
        exportsStub = { es_extended = { getSharedObject = throwingExportMethod() } },
    })
    local ok, result = pcall(registered.framework.es_extended('client').GetPlayerData)
    t.isTrue(ok)
    t.isNil(result)
end)

t.test('es_extended client GetPlayerData: nil when getSharedObject returns nil/string/number/a table missing GetPlayerData', function()
    local esxObjects = { nil, 'x', 4, {}, { GetPlayerData = 'nope' } }
    for _, esx in ipairs(esxObjects) do
        local adapter = esxClientAdapter(esx)
        t.isNil(adapter.GetPlayerData())
    end
end)

t.test('es_extended client GetPlayerData: fails closed when ESX.GetPlayerData itself throws', function()
    local adapter = esxClientAdapter({ GetPlayerData = function() error('boom') end })
    local ok, result = pcall(adapter.GetPlayerData)
    t.isTrue(ok)
    t.isNil(result)
end)

t.test('es_extended client GetPlayerData: nil for a string/number result, a well-shaped-but-empty table for an empty-table result', function()
    local badValues = { 'x', 9 }
    for _, badValue in ipairs(badValues) do
        local adapter = esxClientAdapter({ GetPlayerData = function() return badValue end })
        t.isNil(adapter.GetPlayerData())
    end
    local adapterEmpty = esxClientAdapter({ GetPlayerData = function() return {} end })
    local result = adapterEmpty.GetPlayerData()
    t.isNotNil(result)
    t.isNil(result.citizenid)
    t.isNil(result.job.name)
    t.isNil(result.job.grade)
end)

t.test('es_extended client GetPlayerData: CORRECT FIELD PATH -- .identifier -> citizenid, bare-integer job.grade preserved', function()
    local adapter = esxClientAdapter({ GetPlayerData = function()
        return { identifier = 'license:client-real-1', job = esxLikeJob({ name = 'police', grade = 6 }) }
    end })
    local result = adapter.GetPlayerData()
    t.equals(result.citizenid, 'license:client-real-1')
    t.equals(result.job.name, 'police')
    t.equals(result.job.grade, 6)
end)

t.test('es_extended client GetPlayerData: FIELD-PATH CONFUSION -- a qbx_core/qb-core-shaped playerData (top-level .citizenid, no .identifier) resolves citizenid to nil, never the plausible-looking decoy value -- the headline "plausible-but-wrong citizenid" case this spec exists to guard against', function()
    local adapter = esxClientAdapter({ GetPlayerData = function()
        return { citizenid = 'QBX-SHOULD-NOT-LEAK-AS-CITIZENID', job = { name = 'police', grade = { name = 'boss', level = 1 } } }
    end })
    local result = adapter.GetPlayerData()
    t.isNil(result.citizenid, 'this is exactly the shape this spec exists to guard against -- it must resolve to nil, never the decoy')
    t.equals(result.job.name, 'police')
    t.equals(result.job.grade, 1, 'GradeLevel() tolerates the nested-table shape too -- again, not an access-relevant risk, see GetJob\'s own equivalent note above')
end)

os.exit(t.summary())
