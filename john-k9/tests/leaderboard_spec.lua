--[[
    tests/leaderboard_spec.lua

    Direct tests of server/leaderboard.lua ('/k9stats') against the REAL,
    unmodified production file.

    Covers: the whole-file Config.Features.K9Leaderboard registration-time
    gate (mirrors server/admin.lua's own AdminAuditCommands convention --
    the command must not exist at all when the flag is off, not merely
    no-op at runtime), the HasK9Access(source) access gate (this file's own
    header ACCESS MODEL decision -- current K9 handlers only, no
    audit-grade senior-officer bar, no open-to-everyone bar either), the
    per-source rate limit, the empty-results / query-failure fail-safe
    paths (never a raw DB error surfaced to the player), the exact SQL
    LIMIT-embedding discipline (ClampLimit's own hostile-numeric-input
    battery, mirroring tests/admin_spec.lua's identical section for its own
    ClampLimit -- same class of bug, same regression coverage, a SEPARATE
    local copy per this file's own header "duplicated here, not imported"
    note), and the notify-chunking behavior for more than
    ROWS_PER_NOTIFY_CHUNK rows.

    Deliberately does NOT assert on any derived XP TIER for a row -- this
    file's own header "WHY NOT GetXPTier()" section is the reason there is
    no such thing to assert on; only the raw `xp` integer this spec's own
    MySQL stub hands back is ever displayed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local registeredCommands = {}
local function RegisterCommand(name, handler) registeredCommands[name] = handler end

local hasAccess = true
local hasAccessCallLog = {}
local function HasK9Access(src)
    hasAccessCallLog[#hasAccessCallLog + 1] = src
    return hasAccess
end

local notifyCalls = {}
local function NotifyPlayer(target, description, notifyType)
    notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
end

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

-- PER-PERSON FEATURE CONTROL (this pass) -- server/leaderboard.lua's
-- IsK9LeaderboardPermittedForCitizenId now resolves the caller's own
-- citizenid via exports.qbx_core:GetPlayer(source) before running the
-- query, mirroring every other migrated file's fixture shape
-- (tests/pursuitsprint_spec.lua's own `exportsTable`/`grantPermission`
-- convention). `playerCitizenidBySource` auto-assigns a stable, unique
-- citizenid per source the first time it's asked for -- every existing
-- test in this file drives HasK9Access/the query/cooldown paths through
-- freshSource() without ever needing to know or care about a specific
-- citizenid, so this must never require a test to opt in just to keep
-- passing.
local playerCitizenidBySource = {}
local function citizenidFor(src)
    if not playerCitizenidBySource[src] then
        playerCitizenidBySource[src] = 'CIT' .. tostring(src)
    end
    return playerCitizenidBySource[src]
end
local exportsStub = {
    qbx_core = {
        GetPlayer = function(_self, src)
            return { PlayerData = { source = src, citizenid = citizenidFor(src) } }
        end,
    },
}

local permissionGrants = {} -- [citizenid][key] = true/false
local permissionCalls = {}
local function defaultHasPermission(citizenid, key)
    permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
    return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
end
local function grantPermission(citizenid, key, value)
    permissionGrants[citizenid] = permissionGrants[citizenid] or {}
    permissionGrants[citizenid][key] = value
end

local capturedQueries = {}
local fixtureRows = nil -- nil => real stub returns {}; set per-test
local fixtureShouldThrow = false
local MySQLStub = {
    query = {
        await = function(sql, params)
            capturedQueries[#capturedQueries + 1] = { sql = sql, params = params }
            if fixtureShouldThrow then
                error('simulated MySQL.query.await failure')
            end
            return fixtureRows or {}
        end,
    },
}

local Config = {
    Features = { K9Leaderboard = true },
    Leaderboard = { MaxRows = 20, CommandCooldownMs = 5000 },
    FeatureControl = { RequireGrant = {} },
}

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    RegisterCommand = RegisterCommand,
    HasK9Access = HasK9Access,
    NotifyPlayer = NotifyPlayer,
    MySQL = MySQLStub,
    Config = Config,
    exports = exportsStub,
    HasPermission = defaultHasPermission,
})

-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/leaderboard.lua's own
-- QueryTopXp now reads through K9Store.XP_GetTop rather than a raw SQL
-- string). Config.Database is deliberately absent from this fixture's
-- Config table above -- K9Store's own DatabaseEnabled() fails safe to
-- `true` (real-DB mode) on a missing Config.Database, which is exactly
-- what makes XP_GetTop below run the SAME MySQL.query.await call (against
-- this file's own MySQLStub) that QueryTopXp built directly before this
-- migration, so every existing assertion below keeps exercising the
-- identical SQL/params shape unchanged. See tests/admin_spec.lua for the
-- precedent this comment mirrors.
Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/leaderboard.lua', env)

t.isNotNil(registeredCommands.k9stats, 'server/leaderboard.lua must register /k9stats when Config.Features.K9Leaderboard is true')

-- ----------------------------------------------------------------------
-- Test helpers
-- ----------------------------------------------------------------------

local function resetCaptures()
    notifyCalls = {}
    capturedQueries = {}
    hasAccessCallLog = {}
    permissionCalls = {}
end

local function lastNotify() return notifyCalls[#notifyCalls] end

local nextSource = 1
local function freshSource()
    nextSource = nextSource + 1
    return nextSource
end

-- ----------------------------------------------------------------------
-- Whole-file registration gate
-- ----------------------------------------------------------------------

t.test('Config.Features.K9Leaderboard = false: the command is never registered at all, not merely a runtime no-op', function()
    local gatedCommands = {}
    local function gatedRegisterCommand(name, handler) gatedCommands[name] = handler end
    local gatedEnv = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterCommand = gatedRegisterCommand,
        HasK9Access = HasK9Access,
        NotifyPlayer = NotifyPlayer,
        MySQL = MySQLStub,
        Config = { Features = { K9Leaderboard = false } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', gatedEnv)
    Sandbox.loadInto('../server/leaderboard.lua', gatedEnv)
    t.isNil(gatedCommands.k9stats)
end)

t.test('a missing Config.Features table entirely is treated identically to false -- no crash, no registration', function()
    local gatedCommands = {}
    local function gatedRegisterCommand(name, handler) gatedCommands[name] = handler end
    local gatedEnv = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterCommand = gatedRegisterCommand,
        HasK9Access = HasK9Access,
        NotifyPlayer = NotifyPlayer,
        MySQL = MySQLStub,
        Config = {},
    })
    Sandbox.loadInto('../server/cooldowns.lua', gatedEnv)
    Sandbox.loadInto('../server/leaderboard.lua', gatedEnv)
    t.isNil(gatedCommands.k9stats)
end)

t.test('a missing Config.Leaderboard block entirely degrades to built-in defaults rather than erroring at load time', function()
    local loadedCommands = {}
    local function localRegisterCommand(name, handler) loadedCommands[name] = handler end
    local localEnv = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterCommand = localRegisterCommand,
        HasK9Access = HasK9Access,
        NotifyPlayer = NotifyPlayer,
        MySQL = MySQLStub,
        Config = { Features = { K9Leaderboard = true } }, -- no Config.Leaderboard at all
    })
    Sandbox.loadInto('../server/cooldowns.lua', localEnv)
    Sandbox.loadInto('../server/leaderboard.lua', localEnv)
    t.isNotNil(loadedCommands.k9stats, 'a missing Config.Leaderboard must not prevent the command from registering')
end)

-- ----------------------------------------------------------------------
-- Access gate
-- ----------------------------------------------------------------------

t.test('HasK9Access = false: denied, notified, and NO query is ever run', function()
    resetCaptures()
    hasAccess = false
    registeredCommands.k9stats(freshSource(), {})
    t.equals(#capturedQueries, 0, 'a denied caller must never reach the database at all')
    t.equals(lastNotify().notifyType, 'error')
    hasAccess = true
end)

t.test('source == 0 (console): denied (HasK9Access(0) naturally fails closed), and NEVER calls NotifyPlayer (no client to notify)', function()
    resetCaptures()
    hasAccess = false -- console has no real job/player either way; forcing false here isolates this test from that natural behavior
    registeredCommands.k9stats(0, {})
    t.equals(#notifyCalls, 0, 'console has no client to notify -- this file must not call NotifyPlayer(0, ...)')
    hasAccess = true
end)

t.test('HasK9Access = true: the query runs and results are presented', function()
    resetCaptures()
    fixtureRows = { { citizenid = 'ABCD1234', xp = 9500 } }
    registeredCommands.k9stats(freshSource(), {})
    t.equals(#capturedQueries, 1)
    t.isTrue(#notifyCalls >= 1)
end)

-- ----------------------------------------------------------------------
-- Rate limiting
-- ----------------------------------------------------------------------

t.test('a second immediate call from the SAME source is rate-limited (silent no-op, no second query)', function()
    resetCaptures()
    fixtureRows = { { citizenid = 'ABCD1234', xp = 100 } }
    local src = freshSource()
    registeredCommands.k9stats(src, {})
    local queriesAfterFirst = #capturedQueries
    registeredCommands.k9stats(src, {})
    t.equals(#capturedQueries, queriesAfterFirst, 'a rate-limited second call must not reach the database again')
end)

t.test('a DIFFERENT source is never blocked by another source\'s cooldown', function()
    resetCaptures()
    fixtureRows = { { citizenid = 'ABCD1234', xp = 100 } }
    registeredCommands.k9stats(freshSource(), {})
    local queriesAfterFirst = #capturedQueries
    registeredCommands.k9stats(freshSource(), {})
    t.equals(#capturedQueries, queriesAfterFirst + 1)
end)

-- ----------------------------------------------------------------------
-- Per-person feature control (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsK9LeaderboardPermittedForCitizenId. Mirrors
-- tests/pursuitsprint_spec.lua's own section of the same name.
-- ----------------------------------------------------------------------

t.test('BLOCK: an explicit block.K9Leaderboard grant denies even though HasK9Access is true, and burns NO cooldown', function()
    resetCaptures()
    local src = freshSource()
    grantPermission(citizenidFor(src), 'block.K9Leaderboard', true)

    registeredCommands.k9stats(src, {})
    t.equals(#capturedQueries, 0, 'a blocked caller must never reach the database')
    t.equals(lastNotify().notifyType, 'error')

    -- Unblock and retry IMMEDIATELY (same instant, fakeNow unchanged) -- if
    -- the block above had consumed StatsCooldown, this would now be
    -- rejected as rate-limited instead of succeeding.
    permissionGrants[citizenidFor(src)]['block.K9Leaderboard'] = false
    fixtureRows = { { citizenid = 'ABCD1234', xp = 100 } }
    registeredCommands.k9stats(src, {})
    t.equals(#capturedQueries, 1, 'a block must never burn the cooldown a legitimate follow-up request still needs')
end)

t.test('not blocked: an ordinary caller with no grant/block row at all still works (default allow, step 4)', function()
    resetCaptures()
    fixtureRows = { { citizenid = 'ABCD1234', xp = 100 } }
    registeredCommands.k9stats(freshSource(), {})
    t.equals(#capturedQueries, 1)
end)

t.test('RequireGrant listed + no grant held -- denied even though HasK9Access is true', function()
    resetCaptures()
    Config.FeatureControl.RequireGrant.K9Leaderboard = true
    local src = freshSource()
    -- deliberately NOT granted
    registeredCommands.k9stats(src, {})
    t.equals(#capturedQueries, 0)
    t.equals(lastNotify().notifyType, 'error')
    Config.FeatureControl.RequireGrant.K9Leaderboard = nil -- restore for every test below
end)

t.test('RequireGrant listed + an active feature.K9Leaderboard grant -- allowed', function()
    resetCaptures()
    Config.FeatureControl.RequireGrant.K9Leaderboard = true
    local src = freshSource()
    grantPermission(citizenidFor(src), 'feature.K9Leaderboard', true)
    fixtureRows = { { citizenid = 'ABCD1234', xp = 100 } }
    registeredCommands.k9stats(src, {})
    t.equals(#capturedQueries, 1)
    Config.FeatureControl.RequireGrant.K9Leaderboard = nil -- restore for every test below
end)

-- ----------------------------------------------------------------------
-- Fail-safe paths
-- ----------------------------------------------------------------------

t.test('zero rows returned: a plain "no results" notice, never an error or a blank message', function()
    resetCaptures()
    fixtureRows = {}
    registeredCommands.k9stats(freshSource(), {})
    t.equals(lastNotify().notifyType, 'info')
end)

t.test('a DB failure (MySQL.query.await throws) degrades to the SAME "no results" path, never an uncaught error or a raw DB error shown to the player', function()
    resetCaptures()
    fixtureShouldThrow = true
    local ok = pcall(registeredCommands.k9stats, freshSource(), {})
    fixtureShouldThrow = false
    t.isTrue(ok, 'a thrown MySQL.query.await must never escape the command handler uncaught')
    t.equals(lastNotify().notifyType, 'info', 'a failed query must present as "no results", never a raw error')
end)

-- ----------------------------------------------------------------------
-- ClampLimit: hostile numeric inputs (mirrors tests/admin_spec.lua's own
-- identical battery for its OWN, separately-duplicated ClampLimit).
-- ----------------------------------------------------------------------

--- @param limitArg string?
--- @return number embeddedLimit
local function clampLimitViaCommand(limitArg)
    resetCaptures()
    fixtureRows = { { citizenid = 'X', xp = 1 } }
    registeredCommands.k9stats(freshSource(), { limitArg })
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.isNotNil(limitStr, 'query SQL must contain a plain integer LIMIT: ' .. tostring(capturedQueries[1].sql))
    return tonumber(limitStr)
end

t.test('ClampLimit: nil arg falls back to the configured default (20)', function()
    t.equals(clampLimitViaCommand(nil), 20)
end)

t.test('ClampLimit: non-numeric garbage falls back to the configured default', function()
    t.equals(clampLimitViaCommand('abc'), 20)
end)

t.test('ClampLimit: "nan" never reaches string.format unclamped', function()
    t.equals(clampLimitViaCommand('nan'), 20)
end)

t.test('ClampLimit: "-nan" behaves the same as "nan"', function()
    t.equals(clampLimitViaCommand('-nan'), 20)
end)

t.test('ClampLimit: "inf" falls back to default, never reaches string.format as infinity', function()
    t.equals(clampLimitViaCommand('inf'), 20)
end)

t.test('ClampLimit: "1e400" (overflow to +inf) clamps to hardMax (100), never crashes', function()
    t.equals(clampLimitViaCommand('1e400'), 100)
end)

t.test('ClampLimit: "-1e400" (overflow to -inf) clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('-1e400'), 1)
end)

t.test('ClampLimit: a fractional value is floored, not rejected', function()
    t.equals(clampLimitViaCommand('3.9'), 3)
end)

t.test('ClampLimit: a negative value clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('-5'), 1)
end)

t.test('ClampLimit: zero clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('0'), 1)
end)

t.test('ClampLimit: a value above hardMax (100) clamps down to 100, never embeds the raw huge number', function()
    t.equals(clampLimitViaCommand('999999'), 100)
end)

t.test('ClampLimit: a normal in-range integer passes through unchanged', function()
    t.equals(clampLimitViaCommand('7'), 7)
end)

t.test('ClampLimit: whitespace-padded numeric strings are still parsed', function()
    t.equals(clampLimitViaCommand('  10  '), 10)
end)

-- ----------------------------------------------------------------------
-- Presentation / chunking
-- ----------------------------------------------------------------------

t.test('more than ROWS_PER_NOTIFY_CHUNK (5) rows are split across multiple notify calls, never one giant wall of text', function()
    resetCaptures()
    fixtureRows = {}
    for i = 1, 8 do
        fixtureRows[i] = { citizenid = 'CIT' .. i, xp = 1000 - i }
    end
    registeredCommands.k9stats(freshSource(), {})
    -- 1 title notify + ceil(8/5) = 2 row-chunk notifies = 3 total
    t.equals(#notifyCalls, 3)
end)

t.test('row content: rank, citizenid, and xp all appear in the formatted output, in rank order', function()
    resetCaptures()
    fixtureRows = {
        { citizenid = 'TOPDOG', xp = 9000 },
        { citizenid = 'RUNNERUP', xp = 4000 },
    }
    registeredCommands.k9stats(freshSource(), {})
    local combined = table.concat((function()
        local parts = {}
        for _, n in ipairs(notifyCalls) do parts[#parts + 1] = n.description end
        return parts
    end)(), '\n')
    t.contains(combined, 'TOPDOG')
    t.contains(combined, '9000')
    t.contains(combined, 'RUNNERUP')
    t.contains(combined, '4000')
end)

-- ----------------------------------------------------------------------
-- Never mutates anything -- this file is read-only by construction
-- ----------------------------------------------------------------------

t.test('SOURCE-LEVEL: server/leaderboard.lua never references AwardXP, INSERT, UPDATE, or DELETE anywhere in its own text', function()
    local handle = assert(io.open('../server/leaderboard.lua', 'r'))
    local text = handle:read('a')
    handle:close()
    text = text:gsub('%-%-%[%[.-%]%]', '')
    local codeLines = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        codeLines[#codeLines + 1] = line:match('^(.-)%-%-') or line
    end
    local code = table.concat(codeLines, '\n')
    t.notContains(code, 'AwardXP')
    t.notContains(code:upper(), 'INSERT ')
    t.notContains(code:upper(), 'UPDATE ')
    t.notContains(code:upper(), 'DELETE ')
end)

t.test('ClampLimit: a REAL NaN -- not the string "nan" -- falls back to the default', function()
    -- THE ONE CASE THE BATTERY ABOVE CANNOT REACH, and the reason this
    -- file's ClampLimit silently drifted from admin.lua's while looking
    -- thoroughly covered. Every test above passes with or without the
    -- `parsed ~= parsed` guard, because they all pass STRINGS and
    -- tonumber('nan') is nil in PUC Lua -- the `or defaultMaxRows` fallback
    -- catches those on its own. Only a real NaN number reaches the guard.
    --
    -- OBSERVED, not predicted: with the guard removed this fails with a
    -- LIMIT of 1 instead of the configured 20 -- a silently wrong query,
    -- not a crash. Worth stating precisely, because in ISOLATION the same
    -- value throws instead: math.floor(0/0) is -nan, both clamp
    -- comparisons against it are false, and ('LIMIT %d'):format(-nan)
    -- raises "number has no integer representation". Both are wrong; the
    -- guard removes both.
    --
    -- Not reachable through /k9stats today (args[1] is always a string or
    -- nil). This pins the boundary so the guard cannot be dropped again,
    -- and so wiring this to a callback that CAN carry a real float is safe.
    t.equals(clampLimitViaCommand(0 / 0), 20)
end)

os.exit(t.summary())
