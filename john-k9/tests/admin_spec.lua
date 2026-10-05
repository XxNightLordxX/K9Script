--[[
    tests/admin_spec.lua

    Indirect tests of server/admin.lua's local helpers (ClampLimit,
    IsValidCitizenId, NormalizePlateArg, IsAuthorizedAdmin,
    MergeSortedByIdDesc) against the REAL, unmodified production file.

    These five are all `local` -- unreachable directly from outside the
    file (per this suite's "do not modify production files to make them
    testable" constraint). They ARE reachable indirectly, the same way a
    real caller reaches them: by loading the whole file into a sandbox,
    firing 'onResourceStart' (as FXServer would) to register its three
    RegisterCommand handlers, invoking those handlers exactly as
    RegisterCommand would (source, args), and asserting on the observable
    side effects those locals gate/shape: the numeric LIMIT actually
    embedded in the SQL text handed to MySQL.query.await (ClampLimit), the
    usage-error vs. real-query branch taken (IsValidCitizenId/
    NormalizePlateArg), whether a query runs at all (IsAuthorizedAdmin),
    and the merged/sorted/truncated row set handed to PresentRows
    (MergeSortedByIdDesc).

    ClampLimit specifically was flagged upstream as a place a review found
    it could pass a non-integer to string.format('%d') and throw -- see the
    "ClampLimit: hostile numeric inputs" block below for the nan/inf/
    1e400/float/negative battery this locks in as a regression suite,
    exercised through the REAL code path (a real RegisterCommand handler,
    real ClampLimit, real string.format LIMIT embed), not a reimplementation.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer()
    return fakeNow
end

local registeredCommands = {}
local function RegisterCommand(name, handler, _restricted)
    registeredCommands[name] = handler
end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName()
    return 'john-k9'
end

-- IsPlayerAceAllowed stub: test-controlled per tostring(source).
local aceGrants = {}
local function IsPlayerAceAllowed(sourceIdStr, _ace)
    return aceGrants[sourceIdStr] == true
end

-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl) --
-- HasPermission stub, mirrors tests/combat_spec.lua's/tests/pursuitsprint_spec.lua's
-- own identical `[citizenid][key] = true/false` grant store shape exactly.
-- Present in THIS file's sandbox from the start (unlike combat_spec.lua's
-- opt-in default-absent convention) because admin_spec.lua uses ONE shared
-- module-level env for every test, not a per-test fixture -- Config.FeatureControl.RequireGrant
-- defaults to an EMPTY table (see Config below), so every one of this
-- file's OTHER, pre-existing tests (none of which ever call grantPermission)
-- falls straight through IsAdminFeaturePermittedForCitizenId's step 4
-- (default allow) exactly as before that check existed.
local permissionGrants = {}
local function HasPermissionStub(citizenid, key)
    return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
end
local function grantPermission(citizenid, key, value)
    permissionGrants[citizenid] = permissionGrants[citizenid] or {}
    permissionGrants[citizenid][key] = value
end

-- exports.qbx_core:GetPlayer(source) stub -- used only by LogAuditInvocation
-- to resolve a citizenid for the console log line; nil is a valid/expected
-- "unresolved source" response.
local playersBySource = {}

-- DISPLAY NAME RESOLUTION (this pass) -- GetPlayerByCitizenId/GetOfflinePlayer
-- stubs for server/admin.lua's own ResolveAuditDisplayName, same shape
-- tests/tabletserver_spec.lua's own newFixture() already established for
-- server/tablet.lua's ResolveDisplayName. Both default to an EMPTY table so
-- every pre-existing test in this file (none of which register a citizenid
-- here) keeps observing ResolveAuditDisplayName's own documented "nothing
-- resolves -> fall back to the citizenid itself" path, byte-for-byte
-- unchanged from before this pass -- see e.g. the 'XP snapshot for
-- ABCD1234' assertion further below, which stays true precisely because
-- AuditDisplayLabel('ABCD1234') collapses back to the bare citizenid when
-- no player is registered for it.
local playersByCitizenId = {}
local offlinePlayersByCitizenId = {}

--- @param citizenid string
--- @param charinfo table?
local function registerOnlinePlayerByCitizenId(citizenid, source, charinfo)
    playersByCitizenId[citizenid] = { PlayerData = { citizenid = citizenid, source = source, charinfo = charinfo } }
end

--- Registers a citizenid that only ever resolves through
--- exports.qbx_core:GetOfflinePlayer, never GetPlayerByCitizenId -- mirrors
--- tests/tabletserver_spec.lua's own registerOfflinePlayer helper.
--- @param citizenid string
--- @param charinfo table?
local function registerOfflinePlayerByCitizenId(citizenid, charinfo)
    offlinePlayersByCitizenId[citizenid] = { PlayerData = { citizenid = citizenid, charinfo = charinfo }, Offline = true }
end

local exportsStub = {
    qbx_core = {
        GetPlayer = function(_self, src)
            return playersBySource[src]
        end,
        GetPlayerByCitizenId = function(_self, citizenid)
            return playersByCitizenId[citizenid]
        end,
        GetOfflinePlayer = function(_self, citizenid)
            return offlinePlayersByCitizenId[citizenid]
        end,
    },
}

-- MySQL.query.await stub: records every query, and lets each test swap in a
-- `fixtureResponder(sql, params)` to hand back canned rows keyed off the
-- REAL SQL text the production file generates (never a duplicated/
-- reimplemented decision of which query "should" run).
local capturedQueries = {}
local fixtureResponder = nil
local MySQLStub = {
    query = {
        await = function(sql, params)
            -- server/datastore.lua's boot schema probe is infrastructure,
            -- not a query any test here is about. Answer it as a fully
            -- installed database (otherwise the probe concludes the SQL was
            -- never imported and forces memory-only mode, and every
            -- database-backed assertion below silently stops issuing its
            -- real query), and deliberately do NOT record it -- several
            -- tests below assert an EXACT query count, and a boot-time
            -- probe is not one of the queries they mean.
            if Sandbox.isSchemaProbe(sql) then return Sandbox.installedSchemaRows() end
            capturedQueries[#capturedQueries + 1] = { sql = sql, params = params }
            if fixtureResponder then
                return fixtureResponder(sql, params) or {}
            end
            return {}
        end,
    },
}

-- NotifyPlayer stub: server/admin.lua's local NotifyPlayer wrapper calls
-- `_G.NotifyPlayer(...)` explicitly (see that file's own header on why) --
-- Sandbox.newEnv points env._G at env itself, so this is what it reaches.
local capturedNotifications = {}
local function NotifyPlayerStub(target, description, notifyType, title)
    capturedNotifications[#capturedNotifications + 1] = {
        target = target, description = description, notifyType = notifyType, title = title,
    }
end

-- print stub: captures every line admin.lua prints (LogAuditInvocation's
-- audit trail, PrintRowsToConsole's console presentation, usage errors
-- printed for source == 0) so specs can assert on them without spamming
-- test output.
local capturedPrints = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring(select(i, ...))
    end
    capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
end

-- lib.callback.register stub -- mirrors tests/wellbeing_spec.lua's own
-- identical shape exactly: captures each registered handler by name so this
-- suite can invoke server/admin.lua's CALLBACK SURFACE (tabletAuditCert/
-- tabletAuditPartner/tabletAuditSearch/tabletAuditXp/tabletAuditDept) the
-- same way ox_lib's real dispatcher would -- `callbacks[name](source, ...)`
-- -- without needing a real ox_lib runtime.
local registeredCallbacks = {}
local LibStub = {
    callback = {
        register = function(name, handler)
            registeredCallbacks[name] = handler
        end,
    },
}

local Config = {
    CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
    Features = { AdminAuditCommands = true },
    AdminAudit = {
        AcePermission = 'k9unit.admin',
        CommandCooldownMs = 300,
        TrustConsole = false,
        -- CatalogAudit added this pass (GAP 2 closure -- backs the new
        -- john-k9:server:tabletAuditCatalog callback) -- server/admin.lua's
        -- own onResourceStart now asserts this key exists exactly like the
        -- three that were already here, so a fixture missing it would fail
        -- EVERY test in this file at boot, not just the new ones.
        MaxResults = { Certifications = 50, Partnerships = 50, SearchLog = 50, CatalogAudit = 50 },
    },
    -- Only what IsValidDepartment needs (`Config.Departments[job] ~= nil`) --
    -- a single real-shaped entry ('police', matching config.lua's own key
    -- name) plus the absence of any 'ambulance' entry is enough to exercise
    -- both the valid and unconfigured-department branches below.
    Departments = {
        police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, autoAccessGrade = nil },
    },
    -- PER-PERSON FEATURE CONTROL -- empty by default so every pre-existing
    -- test in this file (none of which pass through grantPermission) keeps
    -- falling through to step 4 (default allow), same reasoning
    -- tests/combat_spec.lua's own Config.FeatureControl doc comment gives.
    -- Individual tests below flip RequireGrant.AdminAuditCommands on/off
    -- around their own assertions and restore it afterward, same convention
    -- the TrustConsole tests above already established.
    FeatureControl = { RequireGrant = {} },
}

-- DISPLAY NAME RESOLUTION -- ResolveAuditDisplayName's own online branch
-- falls back to this native when an online player has no charinfo at all
-- (mirrors tests/tabletserver_spec.lua's own GetPlayerNameStub). Present
-- unconditionally; harmless for every pre-existing test, none of which
-- reach this branch (no citizenid is ever registered via
-- registerOnlinePlayerByCitizenId in those tests).
local function GetPlayerNameStub(source)
    return 'SteamName#' .. tostring(source)
end

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    RegisterCommand = RegisterCommand,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    IsPlayerAceAllowed = IsPlayerAceAllowed,
    HasPermission = HasPermissionStub,
    exports = exportsStub,
    MySQL = MySQLStub,
    NotifyPlayer = NotifyPlayerStub,
    print = printStub,
    Config = Config,
    lib = LibStub,
    GetPlayerName = GetPlayerNameStub,
})

-- server/admin.lua calls NewCooldown() at file-load time (AuditCooldown) --
-- must load server/cooldowns.lua into the SAME env first, same load-order
-- requirement fxmanifest.lua's own server_scripts list documents.
--
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/admin.lua's own
-- QueryCertificationHistory now reads through K9Store.Cert_GetHistory
-- rather than a local SafeQuery+raw-SQL pair). fxmanifest.lua loads it
-- before every other resource-owned server file for the same load-time-
-- global reason cooldowns.lua does. Config.Database is deliberately absent
-- from this fixture's Config table above -- K9Store's own DatabaseEnabled()
-- fails safe to `true` (real-DB mode) on a missing Config.Database, which
-- is exactly what makes Cert_GetHistory below run the SAME MySQL.query.await
-- call (against this file's own MySQLStub) that QueryCertificationHistory
-- built directly before this migration, so every existing assertion below
-- keeps exercising the identical SQL/params shape unchanged.
Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/admin.lua', env)

-- Fire 'onResourceStart' as FXServer would -- this is what actually
-- registers the three commands (gated at registration time, per the
-- production file's own header).
for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('john-k9')
end

-- The five single-purpose audit names were deleted in the 2026-09-02
-- merge; /k9audit is now the only registration, dispatching all five
-- subcommands into the same Handle* functions.
t.isNotNil(registeredCommands.k9audit, 'onResourceStart must register the merged k9audit dispatcher')

-- The original 28 cases never asserted these two -- added here (not a
-- behavior change to any existing case) since this pass adds real coverage
-- of both commands below.

-- CALLBACK SURFACE (this pass) -- registered inside the SAME onResourceStart
-- block, behind the SAME Config.Features.AdminAuditCommands gate, as the
-- five commands above.
t.isNotNil(registeredCallbacks['john-k9:server:tabletAuditCert'], 'onResourceStart must register tabletAuditCert')
t.isNotNil(registeredCallbacks['john-k9:server:tabletAuditPartner'], 'onResourceStart must register tabletAuditPartner')
t.isNotNil(registeredCallbacks['john-k9:server:tabletAuditSearch'], 'onResourceStart must register tabletAuditSearch')
t.isNotNil(registeredCallbacks['john-k9:server:tabletAuditXp'], 'onResourceStart must register tabletAuditXp')
t.isNotNil(registeredCallbacks['john-k9:server:tabletAuditDept'], 'onResourceStart must register tabletAuditDept')

--- Test helper: runs one command invocation from a FRESH, always-authorized,
--- never-previously-rate-limited source (a new integer every call), so each
--- test case is isolated from AuditCooldown's shared per-source state
--- without needing to fast-forward the fake clock. Returns nothing; inspect
--- capturedQueries/capturedNotifications/capturedPrints afterward.
local nextSource = 1000
--- Authorization moved from an ACE grant to police job rank on 2026-08-25.
--- IsAuthorizedAdmin no longer calls IsPlayerAceAllowed at all, so granting
--- an ACE here would authorize nothing. A source is now authorized by having
--- a resolvable player whose job is a configured department at or above that
--- department's auditGrade -- grade 4 against the fixture's police entry.
local function freshAuthorizedSource()
    nextSource = nextSource + 1
    playersBySource[nextSource] = {
        PlayerData = {
            citizenid = 'CIT' .. tostring(nextSource),
            job = { name = 'police', grade = { level = 4 } },
        },
    }
    return nextSource
end

local function resetCaptures()
    capturedQueries = {}
    capturedNotifications = {}
    capturedPrints = {}
    fixtureResponder = nil
end

-- ----------------------------------------------------------------------
-- ClampLimit: hostile numeric inputs, exercised through the real
-- RegisterCommand handler + real string.format LIMIT embed.
-- ----------------------------------------------------------------------

--- @param limitArg string?
--- @return number embeddedLimit
local function clampLimitViaCommand(limitArg)
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234', limitArg })
    t.equals(#capturedQueries, 1, 'a valid citizenid + authorized source must reach exactly one query')
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.isNotNil(limitStr, 'query SQL must contain a plain integer LIMIT: ' .. tostring(capturedQueries[1].sql))
    return tonumber(limitStr)
end

t.test('ClampLimit: nil arg falls back to the configured default (50)', function()
    t.equals(clampLimitViaCommand(nil), 50)
end)

t.test('ClampLimit: non-numeric garbage falls back to the configured default', function()
    t.equals(clampLimitViaCommand('abc'), 50)
end)

t.test('ClampLimit: "nan" never reaches string.format unclamped (PUC Lua tonumber("nan") is nil here)', function()
    -- Locks in current observed behavior as a regression guard: if a future
    -- Lua build's tonumber("nan") ever returns a real NaN instead of nil,
    -- this test starts failing LOUDLY (an uncaught error via
    -- string.format('%d', nan)) instead of the bug silently reappearing.
    t.equals(clampLimitViaCommand('nan'), 50)
end)

t.test('ClampLimit: "-nan" behaves the same as "nan"', function()
    t.equals(clampLimitViaCommand('-nan'), 50)
end)

t.test('ClampLimit: "inf" falls back to default, never reaches string.format as infinity', function()
    t.equals(clampLimitViaCommand('inf'), 50)
end)

t.test('ClampLimit: "1e400" (numeric overflow to +inf) clamps to hardMax (100), never crashes', function()
    t.equals(clampLimitViaCommand('1e400'), 100)
end)

t.test('ClampLimit: "-1e400" (overflow to -inf) clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('-1e400'), 1)
end)

t.test('ClampLimit: a fractional value is floored, not rejected', function()
    t.equals(clampLimitViaCommand('3.9'), 3)
end)

t.test('ClampLimit: a negative value clamps to the floor (1), not passed through negative', function()
    t.equals(clampLimitViaCommand('-5'), 1)
end)

t.test('ClampLimit: zero clamps to the floor (1)', function()
    t.equals(clampLimitViaCommand('0'), 1)
end)

t.test('ClampLimit: a value above hardMax clamps down to 100, never embeds the raw huge number', function()
    t.equals(clampLimitViaCommand('999999'), 100)
end)

t.test('ClampLimit: a normal in-range integer passes through unchanged', function()
    t.equals(clampLimitViaCommand('7'), 7)
end)

t.test('ClampLimit: whitespace-padded numeric strings are still parsed', function()
    t.equals(clampLimitViaCommand('  10  '), 10)
end)

-- ----------------------------------------------------------------------
-- IsValidCitizenId gating (k9audit cert / k9audit partner / k9audit search
-- officer|person): malformed input must never reach a query at all.
-- ----------------------------------------------------------------------

t.test('IsValidCitizenId: empty string is rejected before any query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', '' })
    t.equals(#capturedQueries, 0, 'an invalid citizenid must never reach MySQL.query.await')
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'Usage:')
end)

t.test('IsValidCitizenId: missing arg (nil) is rejected before any query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert' })
    t.equals(#capturedQueries, 0)
end)

t.test('IsValidCitizenId: a value over 50 chars (VARCHAR(50) column width) is rejected', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', string.rep('x', 51) })
    t.equals(#capturedQueries, 0)
end)

t.test('IsValidCitizenId: exactly 50 chars is accepted (boundary)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', string.rep('x', 50) })
    t.equals(#capturedQueries, 1)
end)

-- ----------------------------------------------------------------------
-- NormalizePlateArg gating (k9audit search plate)
-- ----------------------------------------------------------------------

t.test('NormalizePlateArg: whitespace is trimmed and the TRIMMED value reaches the query params', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'plate', '  ABC 123  ' })
    t.equals(#capturedQueries, 1)
    t.equals(capturedQueries[1].params[1], 'ABC 123')
end)

t.test('NormalizePlateArg: an all-whitespace plate is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'plate', '   ' })
    t.equals(#capturedQueries, 0)
end)

t.test('NormalizePlateArg: over 15 chars (VARCHAR(15) column width) is rejected', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'plate', string.rep('P', 16) })
    t.equals(#capturedQueries, 0)
end)

t.test('IsValidSearchLogModes: an unrecognized mode is rejected before any query, before even inspecting value', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'DROP TABLE k9_search_log', 'x' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage:')
end)

-- ----------------------------------------------------------------------
-- IsAuthorizedAdmin: access control, checked BEFORE argument validity
-- ----------------------------------------------------------------------

t.test('IsAuthorizedAdmin: a source with no resolvable player record is denied, no query ever runs', function()
    resetCaptures()
    local src = 9001
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: denial is checked before argument shape (malformed args never even inspected)', function()
    resetCaptures()
    local src = 9002
    -- Deliberately malformed AND unauthorized: if auth were checked after
    -- args, this would fail on citizenid validity with an 'invalid_args'
    -- audit outcome instead of 'denied'.
    registeredCommands.k9audit(src, { 'cert' })
    t.equals(#capturedPrints, 1)
    t.contains(capturedPrints[1], 'denied')
    t.notContains(capturedPrints[1], 'invalid_args')
end)

t.test('IsAuthorizedAdmin: console (source == 0) is denied by default (TrustConsole == false)', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = false
    registeredCommands.k9audit(0, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    -- source == 0 has no client to notify -- the denial surfaces via
    -- LogAuditInvocation's print(), not NotifyPlayer.
    t.equals(#capturedNotifications, 0)
    t.contains(capturedPrints[1], 'denied')
end)

t.test('IsAuthorizedAdmin: console (source == 0) is allowed once TrustConsole is opted in', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = true
    registeredCommands.k9audit(0, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    Config.AdminAudit.TrustConsole = false -- restore for subsequent tests
end)

--- Registers a player record of an ARBITRARY shape at a fresh source, so the
--- cases below can drive IsAuthorizedAdmin's job-rank branches directly
--- rather than only its always-authorized happy path.
--- @param playerData table? the PlayerData table to expose, or nil for "no record"
--- @return number source
local function freshSourceWithPlayerData(playerData)
    nextSource = nextSource + 1
    if playerData ~= nil then
        playersBySource[nextSource] = { PlayerData = playerData }
    end
    return nextSource
end

t.test('IsAuthorizedAdmin: a job that is not a configured K9 department is denied', function()
    resetCaptures()
    -- 'ambulance' is deliberately absent from the Config.Departments fixture.
    -- Grade 10 is far above any auditGrade -- rank must not substitute for
    -- being in a K9 department at all.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITAMB1',
        job = { name = 'ambulance', grade = { level = 10 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: a configured department at a grade BELOW auditGrade is denied', function()
    resetCaptures()
    -- The fixture's police auditGrade is 4; grade 3 is one short. This is the
    -- case that proves the threshold is really compared, not merely that a
    -- configured department was found.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITLOW1',
        job = { name = 'police', grade = { level = 3 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: job.isboss authorizes regardless of grade level', function()
    resetCaptures()
    -- Grade 0 is below auditGrade 4, but qbx_core's isboss flag marks a job
    -- owner -- they are authorized without meeting the numeric threshold.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITBOSS',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)
end)

t.test('IsAuthorizedAdmin: a non-number job.grade.level fails CLOSED, it does not throw', function()
    resetCaptures()
    -- A hand-corrupted DB row (or a future qbx_core shape change) could hand
    -- back a string where a number is expected. A `>=` against a string would
    -- raise an uncaught 'attempt to compare' error inside the command
    -- handler; the guard must deny instead. pcall proves no error escapes.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITBAD1',
        job = { name = 'police', grade = { level = '4' } },
    })
    local ok, err = pcall(registeredCommands.k9audit, src, { 'cert', 'ABCD1234' })
    t.isTrue(ok, 'a non-number grade level must not raise: ' .. tostring(err))
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: a job table with no grade sub-table at all fails CLOSED', function()
    resetCaptures()
    local src = freshSourceWithPlayerData({
        citizenid = 'CITNOG1',
        job = { name = 'police' },
    })
    local ok, err = pcall(registeredCommands.k9audit, src, { 'cert', 'ABCD1234' })
    t.isTrue(ok, 'a missing grade table must not raise: ' .. tostring(err))
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: a player record with no job at all fails CLOSED', function()
    resetCaptures()
    local src = freshSourceWithPlayerData({ citizenid = 'CITNOJ1' })
    local ok, err = pcall(registeredCommands.k9audit, src, { 'cert', 'ABCD1234' })
    t.isTrue(ok, 'a missing job table must not raise: ' .. tostring(err))
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL -- config.lua's Config.FeatureControl, steps
-- 2-4 of its documented "first match wins" resolution, layered ON TOP OF
-- every qualification path above (job.isboss / k9.audit capability grant /
-- high command / auditGrade rank) via IsAdminFeaturePermittedForCitizenId
-- (this pass). This is the headline finding this pass exists to fix:
-- server/permissions.lua's IsValidPermissionKey previously rejected EVERY
-- 'feature.<Name>'/'block.<Name>' grant outright, so a block or a
-- RequireGrant listing had ZERO real effect on who could run these
-- commands, regardless of what the tablet displayed. These tests prove a
-- block ACTUALLY blocks and a grant ACTUALLY grants at the real gate --
-- specifically including the job.isboss bypass, since that path used to
-- `return true` unconditionally and is the most likely place a narrowing
-- change like this one could be accidentally dropped.
-- ----------------------------------------------------------------------

t.test('IsAuthorizedAdmin: RequireGrant.AdminAuditCommands = true + no grant held -- denied even for job.isboss', function()
    resetCaptures()
    Config.FeatureControl.RequireGrant.AdminAuditCommands = true
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-BOSS-1',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    -- deliberately NOT granted
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'not authorized')
    Config.FeatureControl.RequireGrant.AdminAuditCommands = nil -- restore for subsequent tests
end)

t.test('IsAuthorizedAdmin: RequireGrant.AdminAuditCommands = true + an active feature.AdminAuditCommands grant -- allowed (job.isboss path)', function()
    resetCaptures()
    Config.FeatureControl.RequireGrant.AdminAuditCommands = true
    grantPermission('CITFC-BOSS-2', 'feature.AdminAuditCommands', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-BOSS-2',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    Config.FeatureControl.RequireGrant.AdminAuditCommands = nil
end)

t.test('IsAuthorizedAdmin: BLOCK ALWAYS WINS -- an explicit block.AdminAuditCommands denies job.isboss even with an active feature.AdminAuditCommands grant', function()
    resetCaptures()
    Config.FeatureControl.RequireGrant.AdminAuditCommands = true
    grantPermission('CITFC-BOSS-3', 'feature.AdminAuditCommands', true)
    grantPermission('CITFC-BOSS-3', 'block.AdminAuditCommands', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-BOSS-3',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'not authorized')
    Config.FeatureControl.RequireGrant.AdminAuditCommands = nil
end)

t.test('IsAuthorizedAdmin: BLOCK ALSO WINS against an ordinary rank-qualified officer (grade >= auditGrade, not a boss)', function()
    resetCaptures()
    -- NOT listed in RequireGrant this time (step 2 fires independently of
    -- step 3 -- config.lua's own documented ordering) -- an ordinary
    -- grade-4 officer would otherwise pass via the final auditGrade
    -- comparison branch.
    grantPermission('CITFC-RANK-1', 'block.AdminAuditCommands', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-RANK-1',
        job = { name = 'police', grade = { level = 4 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: RequireGrant.AdminAuditCommands not listed -- default ALLOW even with no grant (step 4, matches every pre-existing test in this file)', function()
    resetCaptures()
    -- Config.FeatureControl.RequireGrant.AdminAuditCommands is nil here
    -- (restored by every test above) -- this is the SAME state every other
    -- test in this file already runs under; asserted explicitly once so the
    -- per-person feature control addition is proven non-regressive, not
    -- merely assumed from the other tests passing.
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-DEFAULT-1',
        job = { name = 'police', grade = { level = 4 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)
end)

t.test('IsAuthorizedAdmin: a block on a DIFFERENT feature key does not affect AdminAuditCommands -- feature keys are independent', function()
    resetCaptures()
    grantPermission('CITFC-OTHERKEY-1', 'block.BiteAndHold', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-OTHERKEY-1',
        job = { name = 'police', grade = { level = 4 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'AdminAuditCommands must be unaffected by a block on a different feature key')
end)

-- ----------------------------------------------------------------------
-- ADMIN-CAPABILITY BLOCK NAMESPACE (security-audit pass, this pass --
-- "assess, then decide": k9.access/k9.certify/k9.audit/k9.givexp had NO
-- block mechanism at all, distinct from the Config.Features
-- 'block.AdminAuditCommands' proven above -- that one narrows only THIS
-- FILE's own five slash commands; 'block.k9.audit' narrows whether
-- `citizenid` holds the k9.audit CAPABILITY at all, the same fact
-- server/tablet.lua's own effectivePermissions listing and every other
-- 'k9.audit' consumer cares about. Both are independently meaningful and
-- both are proven here.
-- ----------------------------------------------------------------------

t.test('IsAuthorizedAdmin: block.k9.audit denies even job.isboss, independently of block.AdminAuditCommands', function()
    resetCaptures()
    grantPermission('CITAUD-BOSS-1', 'block.k9.audit', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITAUD-BOSS-1',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: block.k9.audit denies an ordinary rank-qualified officer (grade >= auditGrade, not a boss)', function()
    resetCaptures()
    grantPermission('CITAUD-RANK-1', 'block.k9.audit', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITAUD-RANK-1',
        job = { name = 'police', grade = { level = 4 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'not authorized')
end)

t.test('IsAuthorizedAdmin: block.k9.audit is scoped to that ONE citizenid -- a different, unblocked officer is unaffected', function()
    resetCaptures()
    grantPermission('SOMEONE-ELSE', 'block.k9.audit', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITAUD-UNAFFECTED-1',
        job = { name = 'police', grade = { level = 4 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'a block on a DIFFERENT citizenid must never leak onto this one')
end)

t.test('IsAuthorizedAdmin: a block on a DIFFERENT capability key (k9.certify) does not affect k9.audit -- capability keys are independent', function()
    resetCaptures()
    grantPermission('CITAUD-OTHERKEY-1', 'block.k9.certify', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITAUD-OTHERKEY-1',
        job = { name = 'police', grade = { level = 4 } },
    })
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'k9.audit must be unaffected by a block on a different capability key')
end)

-- ----------------------------------------------------------------------
-- Rate limiting: AuditCooldown shared across all three commands, keyed by
-- the caller's own source.
-- ----------------------------------------------------------------------

t.test('Rate limiting: a second command from the same source inside the cooldown window is denied', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 0
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 100 -- still within Config.AdminAudit.CommandCooldownMs (300)
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'the rate-limited second call must not reach a query')
    t.contains(capturedPrints[#capturedPrints], 'rate_limited')

    fakeNow = 400 -- now past the 300ms cooldown
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 2, 'a call after the cooldown window has elapsed must succeed')
end)

t.test('Rate limiting: is shared ACROSS commands for the same source, not per-command', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 1000
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 1050 -- within cooldown
    registeredCommands.k9audit(src, { 'partner', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'k9audit partner must be rate-limited by k9audit cert\'s own recent call from the same source')
end)

-- ----------------------------------------------------------------------
-- MergeSortedByIdDesc (k9audit partner): two independently-LIMITed row sets,
-- one per unique index, merged and re-sorted by id DESC, then truncated.
-- ----------------------------------------------------------------------

t.test('MergeSortedByIdDesc: merges both role queries, sorts by id DESC, truncates to limit', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('k9_citizenid = ?', 1, true) then
            return {
                { id = 2, k9_citizenid = 'K9-2', handler_citizenid = 'H', active = 1 },
                { id = 5, k9_citizenid = 'K9-5', handler_citizenid = 'H', active = 1 },
            }
        elseif sql:find('handler_citizenid = ?', 1, true) then
            return {
                { id = 8, k9_citizenid = 'K9-8', handler_citizenid = 'H', active = 0 },
                { id = 1, k9_citizenid = 'K9-1', handler_citizenid = 'H', active = 0 },
            }
        end
        return {}
    end

    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'partner', 'ABCD1234', '3' })

    t.equals(#capturedQueries, 2, 'one query per unique index, per this file\'s own documented design')

    -- capturedNotifications[1] is the "N result(s)" summary; [2] is the
    -- formatted-row chunk (<= ROWS_PER_NOTIFY_CHUNK == 5, so all 3 rows
    -- land in one chunk here).
    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    local body = capturedNotifications[2].description

    local posK98 = body:find('K9-8', 1, true)
    local posK95 = body:find('K9-5', 1, true)
    local posK92 = body:find('K9-2', 1, true)
    t.isNotNil(posK98)
    t.isNotNil(posK95)
    t.isNotNil(posK92)
    t.isTrue(posK98 < posK95, 'id=8 must sort before id=5 (DESC)')
    t.isTrue(posK95 < posK92, 'id=5 must sort before id=2 (DESC)')
    t.notContains(body, 'K9-1', 'limit=3 must truncate the 4th-ranked row (id=1) out entirely')
end)

-- ----------------------------------------------------------------------
-- COVERAGE GAP FOUND IN THE ORIGINAL 28 CASES (reported here, not fixed by
-- silently editing any of those 28 -- see this file's own header and the
-- task that produced this pass): NONE of them ever populate
-- MySQL.query.await's stubbed return with actual rows for k9audit cert,
-- k9audit search, or k9audit xp -- every one of those 28 either stops before
-- a query runs (denied/rate_limited/invalid_args) or reaches
-- PresentRows/PrintRowsToConsole with an EMPTY row set (no fixtureResponder
-- configured --> MySQLStub returns {}). The one exception is the
-- MergeSortedByIdDesc case, which incidentally exercises FormatPartnershipRow
-- (admin.partnership_row_format) only because it has to supply real rows to
-- prove the merge/sort/truncate logic. That means:
--   - FormatCertRow (admin.cert_row_format),
--   - FormatSearchLogRow (admin.search_log_row_format, plus BOTH of its
--     target-label branches: admin.search_log_target_plate_label and
--     admin.search_log_target_citizenid_label),
--   - FormatProgressionRow (admin.progression_row_format),
-- were NEVER exercised by this suite. This is the EXACT SAME SHAPE as the
-- /k9audit dept locale gap this task's brief names by example: a case that
-- never drives the "render a real row" branch cannot catch a missing or
-- renamed locale key on that branch.
--
-- SEPARATELY, and more starkly: k9audit xp was never invoked AT ALL by any
-- of the 28 (not even once, valid or invalid) -- its entire command surface,
-- including admin.usage_auditxp and admin.xp_snapshot_label, was untested.
-- k9audit search's 'officer', 'person', and 'recent' modes were likewise
-- NEVER invoked (only 'plate' and one invalid-mode case were) -- meaning the
-- `(mode == 'officer') and QuerySearchLogByOfficer(...) or
-- QuerySearchLogByPerson(...)` dispatch, QuerySearchLogRecent's no-WHERE
-- shape, and admin.usage_auditsearch_mode were all unexercised. And
-- k9audit partner's OWN invalid-citizenid branch (admin.usage_auditpartner)
-- was never reached either -- every k9audit partner invocation in the
-- original 28 used a valid citizenid.
--
-- All closed below with NEW cases. None of the original 28 above are
-- modified.
-- ----------------------------------------------------------------------

t.test('COVERAGE GAP CLOSED: k9audit cert with a populated result set renders via FormatCertRow (admin.cert_row_format) -- no case among the original 28 ever populated a row', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications WHERE citizenid = ?', 1, true) then
            return {
                { job = 'police', active = 1, granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00', revoked_by = nil, revoked_at = nil },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    local body = capturedNotifications[2].description
    t.contains(body, 'job=police')
    t.contains(body, 'active=true')
    t.contains(body, 'granted_by=ADMIN1')
    t.contains(body, 'granted_at=2024-01-01 00:00:00')
    t.contains(body, 'revoked_by=N/A')
    t.contains(body, 'revoked_at=N/A')
end)

t.test('COVERAGE GAP CLOSED: k9audit partner invalid-citizenid usage message (admin.usage_auditpartner) -- never reached by the original 28 (every k9audit partner case there used a valid citizenid)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'partner', '' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage: /k9audit partner')
end)

t.test('COVERAGE GAP CLOSED: k9audit search "officer" mode -- never invoked by the original 28. Dispatches to QuerySearchLogByOfficer (searcher_citizenid = ?), renders via FormatSearchLogRow using the target_citizenid_label branch', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('searcher_citizenid = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER1', searcher_job = 'police', target_type = 'person', target_plate = nil, target_citizenid = 'SUSPECT1', result = 'clean', total_weight = nil, alert_tier = nil, searched_at = '2024-02-02 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'officer', 'OFFICER1' })
    t.equals(#capturedQueries, 1)
    t.contains(capturedQueries[1].sql, 'searcher_citizenid = ?')
    t.equals(capturedQueries[1].params[1], 'OFFICER1')
    local body = capturedNotifications[2].description
    t.contains(body, 'searcher=OFFICER1(police)')
    t.contains(body, 'target=person(citizenid=SUSPECT1)')
    t.contains(body, 'result=clean')
    t.contains(body, 'weight=N/A')
    t.contains(body, 'tier=N/A')
end)

t.test('COVERAGE GAP CLOSED: k9audit search "person" mode -- never invoked by the original 28. Dispatches to QuerySearchLogByPerson (target_citizenid = ?), NOT QuerySearchLogByOfficer -- a swapped ternary would fail this case while leaving the "officer" case above green', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('target_citizenid = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER2', searcher_job = 'sheriff', target_type = 'person', target_plate = nil, target_citizenid = 'SUSPECT2', result = 'contraband_found', total_weight = nil, alert_tier = nil, searched_at = '2024-02-03 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'person', 'SUSPECT2' })
    t.equals(#capturedQueries, 1)
    t.contains(capturedQueries[1].sql, 'target_citizenid = ?')
    t.notContains(capturedQueries[1].sql, 'searcher_citizenid = ?')
    t.equals(capturedQueries[1].params[1], 'SUSPECT2')
end)

t.test('COVERAGE GAP CLOSED: k9audit search "plate" mode with a populated result set renders via FormatSearchLogRow, target_plate_label branch (admin.search_log_target_plate_label) -- the original 3 plate cases never populated a row', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('target_plate = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER3', searcher_job = 'bcso', target_type = 'vehicle', target_plate = 'ABC123', target_citizenid = nil, result = 'contraband_found', total_weight = 2.5, alert_tier = 3, searched_at = '2024-03-03 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'plate', 'ABC123' })
    t.equals(#capturedQueries, 1)
    local body = capturedNotifications[2].description
    t.contains(body, 'target=vehicle(plate=ABC123)')
    t.contains(body, 'weight=2.5')
    t.contains(body, 'tier=3')
end)

t.test('COVERAGE GAP CLOSED: k9audit search "recent" mode -- never invoked by the original 28. No WHERE clause, ordered by id DESC, no bound params', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'recent' })
    t.equals(#capturedQueries, 1)
    t.notContains(capturedQueries[1].sql, 'WHERE')
    t.contains(capturedQueries[1].sql, 'ORDER BY id DESC')
    t.equals(#capturedQueries[1].params, 0, 'recent mode takes no WHERE-bound params')
end)

t.test('COVERAGE GAP CLOSED: k9audit search officer/person invalid-citizenid usage message (admin.usage_auditsearch_mode) -- never reached by the original 28 (only "plate" and an invalid mode were ever tried)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'search', 'officer', '' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage: /k9audit search officer')
end)

t.test('COVERAGE GAP CLOSED: k9audit xp was never invoked by any of the original 28 cases -- invalid-citizenid usage message (admin.usage_auditxp) exercised here', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'xp', '' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage: /k9audit xp')
end)

t.test('COVERAGE GAP CLOSED: k9audit xp with a populated result renders via FormatProgressionRow (admin.progression_row_format) and admin.xp_snapshot_label', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_progression', 1, true) then
            return { { xp = 4200, updated_at = '2024-04-04 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'xp', 'ABCD1234' })
    t.equals(#capturedQueries, 1)
    t.contains(capturedNotifications[1].description, 'XP snapshot for ABCD1234')
    local body = capturedNotifications[2].description
    t.contains(body, 'xp=4200')
    t.contains(body, 'updated_at=2024-04-04 00:00:00')
end)

-- ----------------------------------------------------------------------
-- /k9audit dept <job> [limit] -- new command, covered the same way the other
-- four are covered above: ACE gate + TrustConsole carve-out, shared
-- cooldown, LogAuditInvocation on every branch, argument validation,
-- ClampLimit reuse, parameterized/read-only query shape, and every locale
-- key this command's own code path can reach (this IS the regression guard
-- for the admin.usage_auditdept / admin.dept_roster_label /
-- admin.dept_cert_row_format keys that shipped missing once already --
-- Sandbox.locale raises on a missing key, so simply reaching each branch
-- below is what would have caught that).
-- ----------------------------------------------------------------------

t.test('k9audit dept: a source with no resolvable player record is denied, no query ever runs', function()
    resetCaptures()
    local src = 9101
    registeredCommands.k9audit(src, { 'dept', 'police' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'not authorized')
    t.contains(capturedPrints[#capturedPrints], 'ran k9audit dept(n/a) -> denied')
end)

t.test('k9audit dept: console (source == 0) is denied by default (TrustConsole == false)', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = false
    registeredCommands.k9audit(0, { 'dept', 'police' })
    t.equals(#capturedQueries, 0)
    t.equals(#capturedNotifications, 0, 'source == 0 has no client to notify')
    t.contains(capturedPrints[#capturedPrints], 'ran k9audit dept(n/a) -> denied')
end)

t.test('k9audit dept: console (source == 0) is allowed once TrustConsole is opted in', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = true
    -- Advance the shared fake clock comfortably past CommandCooldownMs (300)
    -- since key `0` may have been touched by an earlier console-path case
    -- elsewhere in this file -- this is the SAME shared-cooldown state every
    -- console (source == 0) case in this suite reads and writes, so this
    -- guards against test-order coupling rather than assuming a fresh key.
    fakeNow = fakeNow + 1000
    registeredCommands.k9audit(0, { 'dept', 'police' })
    t.equals(#capturedQueries, 1)
    Config.AdminAudit.TrustConsole = false -- restore for subsequent tests
end)

t.test('Rate limiting: k9audit dept participates in the shared AuditCooldown -- blocked shortly after another command from the same source, recovers once the window elapses', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 5000
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 5100 -- within CommandCooldownMs (300)
    registeredCommands.k9audit(src, { 'dept', 'police' })
    t.equals(#capturedQueries, 1, 'k9audit dept must be rate-limited by a recent k9audit cert call from the same source')
    t.contains(capturedPrints[#capturedPrints], 'ran k9audit dept(n/a) -> rate_limited')

    fakeNow = 5500 -- past the 300ms cooldown
    registeredCommands.k9audit(src, { 'dept', 'police' })
    t.equals(#capturedQueries, 2, 'a k9audit dept call after the cooldown window has elapsed must succeed')
end)

t.test('Rate limiting: k9audit dept itself feeds the shared AuditCooldown -- blocks a subsequent DIFFERENT command from the same source', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 6000
    registeredCommands.k9audit(src, { 'dept', 'police' })
    t.equals(#capturedQueries, 1)

    fakeNow = 6100 -- within cooldown
    registeredCommands.k9audit(src, { 'partner', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'k9audit partner must be rate-limited by k9audit dept\'s own recent call from the same source')
end)

t.test('k9audit dept: a valid, configured department reaches the query; zero rows renders admin.no_results_found with the admin.dept_roster_label', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 'police' })
    t.equals(#capturedQueries, 1)
    t.equals(#capturedNotifications, 1)
    t.contains(capturedNotifications[1].description, 'Certified handlers for department police')
    t.contains(capturedNotifications[1].description, 'no results found')
    t.contains(capturedPrints[#capturedPrints], 'ran k9audit dept(police) -> ok')
end)

t.test('k9audit dept: an unconfigured department is rejected as invalid_args, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 'ambulance' })
    t.equals(#capturedQueries, 0)
    t.contains(capturedNotifications[1].description, 'Usage:')
    t.contains(capturedPrints[#capturedPrints], 'ran k9audit dept(n/a) -> invalid_args')
end)

t.test('k9audit dept: a non-string job argument is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 42 })
    t.equals(#capturedQueries, 0)
end)

t.test('k9audit dept: an empty string job argument is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', '' })
    t.equals(#capturedQueries, 0)
end)

t.test('k9audit dept: a limit above the hard maximum clamps down to 100', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 'police', '999999' })
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.equals(tonumber(limitStr), 100)
end)

t.test('k9audit dept: a non-numeric limit falls back to the configured default (Certifications = 50)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 'police', 'not-a-number' })
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.equals(tonumber(limitStr), 50)
end)

t.test('k9audit dept: the query is parameterized (job never concatenated into SQL text) and strictly read-only', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 'police', '10' })
    t.equals(#capturedQueries, 1)
    local sql = capturedQueries[1].sql
    t.contains(sql, 'WHERE job = ?')
    t.contains(sql, 'AND active = 1')
    t.equals(capturedQueries[1].params[1], 'police')
    t.equals(#capturedQueries[1].params, 1, 'job is the ONLY bound parameter -- limit is a server-clamped integer embedded via string.format, never a placeholder')
    t.notContains(sql, "'police'", 'job must never be concatenated as a literal into the SQL text -- it must only ever reach a bound placeholder')
    local upperSql = sql:upper()
    t.notContains(upperSql, 'INSERT')
    t.notContains(upperSql, 'UPDATE')
    t.notContains(upperSql, 'DELETE')
end)

t.test('k9audit dept: a populated roster renders via FormatDeptCertRow (admin.dept_cert_row_format) and admin.result_count -- this IS the regression guard for the three locale keys that shipped missing', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications', 1, true) and sql:find('job = ?', 1, true) then
            return {
                { citizenid = 'ABCD1111', granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00' },
                { citizenid = 'ABCD2222', granted_by = 'ADMIN2', granted_at = '2024-01-02 00:00:00' },
            }
        end
        return {}
    end

    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'dept', 'police' })

    t.equals(#capturedQueries, 1)
    t.isNotNil(capturedNotifications[1], 'expected the "N result(s)" summary notification')
    t.contains(capturedNotifications[1].description, 'Certified handlers for department police')
    t.contains(capturedNotifications[1].description, '2 result(s)')

    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    local body = capturedNotifications[2].description
    t.contains(body, 'citizenid=ABCD1111')
    t.contains(body, 'granted_by=ADMIN1')
    t.contains(body, 'granted_at=2024-01-01 00:00:00')
    t.contains(body, 'citizenid=ABCD2222')
    t.contains(body, 'granted_by=ADMIN2')
end)

-- ----------------------------------------------------------------------
-- CALLBACK SURFACE (this pass) -- tabletAuditCert/tabletAuditPartner/
-- tabletAuditSearch/tabletAuditXp/tabletAuditDept. Each callback mirrors its
-- command counterpart's authorization, rate limiting, argument validation,
-- and query layer exactly -- these cases specifically prove that mirroring
-- (not merely that the callback "works" in isolation), plus the ONE new
-- behavior a callback has that a command never could: `rows` is the RAW row
-- table, never a formatted string, and `limit` arrives as a genuine Lua
-- number rather than a chat-command string (exercising ClampLimit's NaN
-- hardening, unreachable via any command).
-- ----------------------------------------------------------------------

t.test('tabletAuditCert: an unauthorized caller is denied, no query runs, shape is { ok = false, error = "not_authorized", message }', function()
    resetCaptures()
    local src = 9201
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.contains(result.message, 'not authorized')
    t.contains(capturedPrints[#capturedPrints], 'ran tabletAuditCert(n/a) -> denied')
end)

t.test('tabletAuditCert: an invalid citizenid is rejected as invalid_args, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, '')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
    t.contains(capturedPrints[#capturedPrints], 'ran tabletAuditCert(n/a) -> invalid_args')
end)

t.test('tabletAuditCert: a valid authorized call returns RAW rows (not a formatted string), plus ok/label', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications WHERE citizenid = ?', 1, true) then
            return {
                { job = 'police', active = 1, granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00', revoked_by = nil, revoked_at = nil },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(#capturedQueries, 1)
    t.isTrue(result.ok)
    t.equals(type(result.rows), 'table')
    t.equals(#result.rows, 1)
    t.equals(result.rows[1].job, 'police', 'rows must be the RAW k9_certifications row -- a real field, not a substring of a formatted line')
    t.equals(result.rows[1].granted_by, 'ADMIN1')
    t.contains(result.label, 'ABCD1234')
    -- Callbacks never call NotifyPlayer/PresentRows -- the notification path
    -- this task explicitly says must not be rewritten stays untouched.
    t.equals(#capturedNotifications, 0, 'a callback invocation must never also fire a chat toast')
    t.contains(capturedPrints[#capturedPrints], 'ran tabletAuditCert(ABCD1234) -> ok')
end)

-- ============================================================================
-- DISPLAY NAME RESOLUTION (owner's own request: "ensure a name actually
-- pops up and not the player id... in the tablet etc"). Every raw
-- citizenid column these five callbacks' `rows` already carried is now
-- ADDITIVELY paired with a `<field>_name` sibling (granted_by_name,
-- revoked_by_name, k9_citizenid_name, handler_citizenid_name,
-- established_by_name, ended_by_name, searcher_citizenid_name,
-- target_citizenid_name, citizenid_name) -- the raw column itself is never
-- removed or replaced (this task's own "keep the identifier" rule), and
-- the SAME enrichment feeds both this callback surface's JSON `rows` and
-- the /k9audit* commands' own chat/console text (FormatCertRow etc., via
-- PresentRows/PrintRowsToConsole) -- see server/admin.lua's own
-- "DISPLAY NAME RESOLUTION" header section.
-- ============================================================================

t.test('tabletAuditCert: rows carry granted_by_name/revoked_by_name as ADDITIVE fields -- the raw granted_by/revoked_by columns are never replaced', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('ADMIN1', 501, { firstname = 'Alex', lastname = 'Admin' })
    registerOfflinePlayerByCitizenId('OLDADMIN', { firstname = 'Sam', lastname = 'Retired' })
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications WHERE citizenid = ?', 1, true) then
            return {
                { job = 'police', active = 0, granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00', revoked_by = 'OLDADMIN', revoked_at = '2024-02-01 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.isTrue(result.ok)
    t.equals(result.rows[1].granted_by, 'ADMIN1', 'the raw identifier must never be replaced')
    t.equals(result.rows[1].granted_by_name, 'Alex Admin', 'an ONLINE granter with charinfo resolves to their real name')
    t.equals(result.rows[1].revoked_by, 'OLDADMIN')
    t.equals(result.rows[1].revoked_by_name, 'Sam Retired', 'an OFFLINE revoker resolves via GetOfflinePlayer charinfo')
end)

t.test('tabletAuditCert: an unresolvable granted_by falls back to the bare citizenid, never blank or a fake name -- and revoked_by_name stays nil when the row was never revoked', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications WHERE citizenid = ?', 1, true) then
            return {
                { job = 'police', active = 1, granted_by = 'GHOST1', granted_at = '2024-01-01 00:00:00', revoked_by = nil, revoked_at = nil },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(result.rows[1].granted_by_name, 'GHOST1', 'unresolvable -> the citizenid itself, matching this file\'s own established fallback')
    t.isNil(result.rows[1].revoked_by_name, 'a still-active row has no revoked_by, so no name to resolve either')
end)

t.test('/k9audit cert chat/console output resolves the SAME name the callback does -- "Name (citizenid)", not the citizenid alone', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('ADMIN1', 501, { firstname = 'Alex', lastname = 'Admin' })
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications WHERE citizenid = ?', 1, true) then
            return {
                { job = 'police', active = 1, granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00', revoked_by = nil, revoked_at = nil },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.isNotNil(capturedNotifications[2], 'expected a formatted-rows notification chunk')
    t.contains(capturedNotifications[2].description, 'Alex Admin (ADMIN1)', 'the chat line must show the resolved name alongside the citizenid, not the citizenid alone')
end)

t.test('/k9audit cert chat/console "Certification history for ..." header ALSO resolves the target citizenid\'s own name', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('ABCD1234', 502, { firstname = 'Terry', lastname = 'Target' })
    local src = freshAuthorizedSource()
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.contains(capturedNotifications[1].description, 'Terry Target (ABCD1234)')
end)

t.test('tabletAuditPartner: rows carry k9_citizenid_name/handler_citizenid_name/established_by_name/ended_by_name -- a K9 is a citizenid too', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('K9-2', 601, { firstname = 'Rex', lastname = 'K9' })
    registerOnlinePlayerByCitizenId('H', 602, { firstname = 'Han', lastname = 'Dler' })
    fixtureResponder = function(sql)
        if sql:find('k9_citizenid = ?', 1, true) then
            return { { id = 2, k9_citizenid = 'K9-2', handler_citizenid = 'H', established_by = 'H', established_at = '2024-01-01', ended_by = nil, ended_at = nil, active = 1 } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditPartner'](src, 'ABCD1234', 3)
    t.isTrue(result.ok)
    t.equals(result.rows[1].k9_citizenid, 'K9-2')
    t.equals(result.rows[1].k9_citizenid_name, 'Rex K9')
    t.equals(result.rows[1].handler_citizenid_name, 'Han Dler')
    t.equals(result.rows[1].established_by_name, 'Han Dler')
    t.isNil(result.rows[1].ended_by_name, 'a still-active partnership has no ended_by, so no name to resolve either')
end)

t.test('tabletAuditSearch: "person" mode rows carry searcher_citizenid_name/target_citizenid_name; a vehicle-type row never resolves a name for target_plate', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('OFFICERX', 701, { firstname = 'Off', lastname = 'Icer' })
    fixtureResponder = function(sql)
        if sql:find('target_citizenid = ?', 1, true) then
            return { { searcher_citizenid = 'OFFICERX', searcher_job = 'police', target_type = 'person', target_plate = nil, target_citizenid = 'SUSPECT2', result = 'clean', total_weight = nil, alert_tier = nil, searched_at = '2024-02-02 00:00:00', id = 1 } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'person', 'SUSPECT2')
    t.equals(result.rows[1].searcher_citizenid_name, 'Off Icer')
    t.equals(result.rows[1].target_citizenid_name, 'SUSPECT2', 'unresolved target falls back to the bare citizenid')
end)

t.test('tabletAuditDept: rows carry citizenid_name/granted_by_name additively -- raw citizenid/granted_by unchanged', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('ABCD1111', 801, { firstname = 'Roster', lastname = 'Member' })
    registerOnlinePlayerByCitizenId('ADMIN1', 802, { firstname = 'Alex', lastname = 'Admin' })
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications', 1, true) and sql:find('job = ?', 1, true) then
            return { { citizenid = 'ABCD1111', granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditDept'](src, 'police', 10)
    t.equals(result.rows[1].citizenid, 'ABCD1111')
    t.equals(result.rows[1].citizenid_name, 'Roster Member')
    t.equals(result.rows[1].granted_by, 'ADMIN1')
    t.equals(result.rows[1].granted_by_name, 'Alex Admin')
end)

t.test('tabletAuditXp: label resolves the target citizenid\'s own name, matching every other label builder', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('ABCD1234', 901, { firstname = 'Xavier', lastname = 'Player' })
    fixtureResponder = function(sql)
        if sql:find('FROM k9_progression', 1, true) then
            return { { xp = 4200, updated_at = '2024-04-04 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditXp'](src, 'ABCD1234')
    t.contains(result.label, 'Xavier Player (ABCD1234)')
end)

t.test('tabletAuditCert: limit is clamped exactly like the command path -- an out-of-range numeric limit clamps to the hard max (100)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', 999999)
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.equals(tonumber(limitStr), 100)
end)

t.test('tabletAuditCert: NaN HARDENING -- a raw NaN Lua number (only reachable via a callback, never a chat command) falls back to the configured default instead of reaching string.format unclamped', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local nan = 0 / 0
    local ok, result = pcall(registeredCallbacks['john-k9:server:tabletAuditCert'], src, 'ABCD1234', nan)
    t.isTrue(ok, 'a NaN limit must never raise an uncaught error: ' .. tostring(result))
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.isNotNil(limitStr, 'the embedded LIMIT must still be a plain integer even when the caller supplied NaN')
    t.equals(tonumber(limitStr), 50, 'NaN must fall back to the configured default (Certifications = 50), same as an unparseable string')
    t.isTrue(result.ok)
end)

t.test('tabletAuditCert: rate limiting is the SAME shared AuditCooldown budget the commands use -- a recent command call blocks a subsequent callback call from the same source', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 7000
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1)

    fakeNow = 7100 -- within CommandCooldownMs (300)
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(#capturedQueries, 1, 'the callback must be rate-limited by the command\'s own recent call from the same source')
    t.isFalse(result.ok)
    t.equals(result.error, 'rate_limited')

    fakeNow = 7500 -- past the cooldown window
    local result2 = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(#capturedQueries, 2)
    t.isTrue(result2.ok)
end)

t.test('tabletAuditCert: a callback call ALSO feeds the shared cooldown -- blocks a subsequent command from the same source', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = 8000
    registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(#capturedQueries, 1)

    fakeNow = 8100 -- within cooldown
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#capturedQueries, 1, 'the command must be rate-limited by the callback\'s own recent call from the same source')
end)

t.test('tabletAuditCert: PER-PERSON FEATURE CONTROL applies identically -- an explicit block denies even job.isboss', function()
    resetCaptures()
    grantPermission('CITFC-CB-1', 'block.AdminAuditCommands', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-CB-1',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletAuditPartner: an invalid citizenid is rejected as invalid_args', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditPartner'](src, '')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
end)

t.test('tabletAuditPartner: returns the SAME merged/sorted/truncated raw rows MergeSortedByIdDesc produces for the command path', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('k9_citizenid = ?', 1, true) then
            return {
                { id = 2, k9_citizenid = 'K9-2', handler_citizenid = 'H', active = 1 },
                { id = 5, k9_citizenid = 'K9-5', handler_citizenid = 'H', active = 1 },
            }
        elseif sql:find('handler_citizenid = ?', 1, true) then
            return {
                { id = 8, k9_citizenid = 'K9-8', handler_citizenid = 'H', active = 0 },
                { id = 1, k9_citizenid = 'K9-1', handler_citizenid = 'H', active = 0 },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditPartner'](src, 'ABCD1234', 3)
    t.equals(#capturedQueries, 2, 'one query per unique index, same as the command path')
    t.isTrue(result.ok)
    t.equals(#result.rows, 3, 'limit=3 truncates the 4th-ranked row out entirely')
    t.equals(result.rows[1].id, 8)
    t.equals(result.rows[2].id, 5)
    t.equals(result.rows[3].id, 2)
end)

t.test('tabletAuditSearch: an unrecognized mode is rejected before value is even inspected', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'DROP TABLE k9_search_log', 'x')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
end)

t.test('tabletAuditSearch: "officer" mode dispatches to searcher_citizenid = ? and returns raw rows', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('searcher_citizenid = ?', 1, true) then
            return {
                { searcher_citizenid = 'OFFICER1', searcher_job = 'police', target_type = 'person', target_plate = nil, target_citizenid = 'SUSPECT1', result = 'clean', total_weight = nil, alert_tier = nil, searched_at = '2024-02-02 00:00:00', id = 1 },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'officer', 'OFFICER1')
    t.equals(#capturedQueries, 1)
    t.contains(capturedQueries[1].sql, 'searcher_citizenid = ?')
    t.isTrue(result.ok)
    t.equals(result.rows[1].searcher_citizenid, 'OFFICER1')
    t.equals(result.rows[1].result, 'clean')
end)

t.test('tabletAuditSearch: "person" mode dispatches to target_citizenid = ?, NOT searcher_citizenid = ?', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'person', 'SUSPECT2')
    t.equals(#capturedQueries, 1)
    t.contains(capturedQueries[1].sql, 'target_citizenid = ?')
    t.notContains(capturedQueries[1].sql, 'searcher_citizenid = ?')
    t.equals(capturedQueries[1].params[1], 'SUSPECT2')
end)

t.test('tabletAuditSearch: "plate" mode trims whitespace via NormalizePlateArg, same as the command path', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'plate', '  ABC 123  ')
    t.equals(#capturedQueries, 1)
    t.equals(capturedQueries[1].params[1], 'ABC 123')
end)

t.test('tabletAuditSearch: an all-whitespace plate is rejected, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'plate', '   ')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
end)

t.test('tabletAuditSearch: "recent" mode takes no WHERE clause and no `value` argument', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'recent')
    t.equals(#capturedQueries, 1)
    t.notContains(capturedQueries[1].sql, 'WHERE')
    t.contains(capturedQueries[1].sql, 'ORDER BY id DESC')
    t.isTrue(result.ok)
end)

t.test('tabletAuditSearch: limit is clamped -- an out-of-range numeric limit on "recent" clamps to the hard max (100)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'recent', nil, 999999)
    t.equals(#capturedQueries, 1)
    local limitStr = capturedQueries[1].sql:match('LIMIT (%d+)')
    t.equals(tonumber(limitStr), 100)
end)

t.test('tabletAuditXp: an invalid citizenid is rejected as invalid_args', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditXp'](src, '')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
end)

t.test('tabletAuditXp: a populated result returns the raw xp/updated_at row, not a formatted string', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_progression', 1, true) then
            return { { xp = 4200, updated_at = '2024-04-04 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditXp'](src, 'ABCD1234')
    t.equals(#capturedQueries, 1)
    t.isTrue(result.ok)
    t.equals(result.rows[1].xp, 4200)
    t.equals(result.rows[1].updated_at, '2024-04-04 00:00:00')
end)

t.test('tabletAuditDept: an unconfigured department is rejected as invalid_args, no query runs', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditDept'](src, 'ambulance')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
end)

t.test('tabletAuditDept: a valid department returns the same three-column active roster shape the command exposes -- nothing wider', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certifications', 1, true) and sql:find('job = ?', 1, true) then
            return {
                { citizenid = 'ABCD1111', granted_by = 'ADMIN1', granted_at = '2024-01-01 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditDept'](src, 'police', 10)
    t.equals(#capturedQueries, 1)
    t.isTrue(result.ok)
    t.equals(result.rows[1].citizenid, 'ABCD1111')
    t.equals(result.rows[1].granted_by, 'ADMIN1')
    t.equals(result.rows[1].granted_at, '2024-01-01 00:00:00')
end)

t.test('tabletAuditDept: console (source == 0) IS NOT a valid caller of a callback -- IsAuthorizedAdmin still resolves it via TrustConsole exactly like the command path (regression guard: no special-casing was added for source == 0 in the callback body)', function()
    resetCaptures()
    Config.AdminAudit.TrustConsole = true
    fakeNow = fakeNow + 1000
    local result = registeredCallbacks['john-k9:server:tabletAuditDept'](0, 'police')
    t.equals(#capturedQueries, 1, 'TrustConsole = true must still authorize source == 0 through the exact same IsAuthorizedAdmin call the commands use')
    t.isTrue(result.ok)
    Config.AdminAudit.TrustConsole = false
end)

-- ============================================================================
-- tabletAuditCatalog (GAP 2 closure, pre-existing this pass) -- DISPLAY NAME
-- RESOLUTION applies here too: every one of its eight sources carries a
-- `changed_by` citizenid, and k9Profiles ALSO carries a `citizenid` column
-- (the K9/handler an individual override targets). See server/admin.lua's
-- own EnrichChangedByRows.
-- ============================================================================

t.test('tabletAuditCatalog: certTiers rows carry changed_by_name additively', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('HC1', 1001, { firstname = 'High', lastname = 'Command' })
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certification_tier_audit', 1, true) then
            return { { action = 'update', tier_key = 'senior', detail = 'raised requirement', changed_by = 'HC1', changed_at = '2024-05-01 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    t.isTrue(result.ok)
    t.equals(result.rows[1].changed_by, 'HC1', 'the raw identifier must never be replaced')
    t.equals(result.rows[1].changed_by_name, 'High Command')
end)

t.test('tabletAuditCatalog: k9Profiles rows carry BOTH changed_by_name and citizenid_name (the only one of the eight sources with a second citizenid column)', function()
    resetCaptures()
    registerOnlinePlayerByCitizenId('HC1', 1002, { firstname = 'High', lastname = 'Command' })
    registerOnlinePlayerByCitizenId('K9-9', 1003, { firstname = 'Rex', lastname = 'Nine' })
    fixtureResponder = function(sql)
        if sql:find('FROM k9_individual_override_audit', 1, true) then
            return { { action = 'set', citizenid = 'K9-9', detail = 'speedMultiplier=1.1', changed_by = 'HC1', changed_at = '2024-05-02 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'k9Profiles')
    t.isTrue(result.ok)
    t.equals(result.rows[1].citizenid_name, 'Rex Nine')
    t.equals(result.rows[1].changed_by_name, 'High Command')
end)

t.test('tabletAuditCatalog: runtimeOverrides rows (a source with NO extra citizenid column) never get a citizenid_name field at all', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_runtime_override_audit', 1, true) then
            return { { override_key = 'Config.Features.Foo', kind = 'boolean', old_value = 'false', new_value = 'true', changed_by = 'HC1', changed_at = '2024-05-03 00:00:00' } }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'runtimeOverrides')
    t.isTrue(result.ok)
    t.isNil(result.rows[1].citizenid_name, 'runtimeOverrides rows have no citizenid column at all -- hasCitizenidColumn must stay false for every source except k9Profiles')
end)

-- ----------------------------------------------------------------------
-- cap / limit / truncated (this pass) -- server/admin.lua's HARD_MAX_RESULTS
-- is now echoed back on every successful tabletAudit* response instead of
-- being a private number html/tablet.js had to separately hardcode and
-- hope stayed in sync. See ClampLimit's own doc comment (second return
-- value, `truncated`) and the CALLBACK SURFACE comment block above the
-- five lib.callback.register calls in server/admin.lua for the exact
-- contract these cases lock in.
-- ----------------------------------------------------------------------

t.test('tabletAuditCert: cap is always HARD_MAX_RESULTS (100), and a request within range is reported truncated = false with limit = the value actually used', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', 30)
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.equals(result.limit, 30)
    t.isFalse(result.truncated)
end)

t.test('tabletAuditCert: an absent limit falls back to the configured default (50) and is never reported truncated', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.equals(result.limit, 50)
    t.isFalse(result.truncated)
end)

t.test('tabletAuditCert: requesting more than the cap (999999) reports truncated = true and limit = 100 -- "you asked for 999999, here are the first 100"', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', 999999)
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.equals(result.limit, 100)
    t.isTrue(result.truncated)
end)

t.test('tabletAuditCert: requesting EXACTLY the cap (100) is NOT reported truncated -- the caller got exactly what they asked for', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', 100)
    t.isTrue(result.ok)
    t.equals(result.limit, 100)
    t.isFalse(result.truncated)
end)

t.test('tabletAuditCert: a raw +infinity Lua number (only reachable via a callback) clamps to the cap and reports truncated = true, no crash', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local ok, result = pcall(registeredCallbacks['john-k9:server:tabletAuditCert'], src, 'ABCD1234', math.huge)
    t.isTrue(ok, 'a +infinity limit must never raise an uncaught error: ' .. tostring(result))
    t.isTrue(result.ok)
    t.equals(result.limit, 100)
    t.isTrue(result.truncated)
end)

t.test('tabletAuditCert: a raw -infinity Lua number clamps to the floor (1) and is NOT reported truncated -- that clamp is a different, lower-bound case', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local ok, result = pcall(registeredCallbacks['john-k9:server:tabletAuditCert'], src, 'ABCD1234', -math.huge)
    t.isTrue(ok, 'a -infinity limit must never raise an uncaught error: ' .. tostring(result))
    t.isTrue(result.ok)
    t.equals(result.limit, 1)
    t.isFalse(result.truncated)
end)

t.test('tabletAuditCert: a NaN limit falls back to the configured default and is NOT reported truncated', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local nan = 0 / 0
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', nan)
    t.isTrue(result.ok)
    t.equals(result.limit, 50)
    t.isFalse(result.truncated)
end)

t.test('tabletAuditPartner: requesting more than the cap reports truncated = true and limit = 100', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditPartner'](src, 'ABCD1234', 500)
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.equals(result.limit, 100)
    t.isTrue(result.truncated)
end)

t.test('tabletAuditSearch ("recent" mode): requesting more than the cap reports truncated = true and limit = 100', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'recent', nil, 500)
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.equals(result.limit, 100)
    t.isTrue(result.truncated)
end)

t.test('tabletAuditSearch ("officer" mode): a within-range limit is reported truncated = false with the exact limit used', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditSearch'](src, 'officer', 'OFFICER1', 12)
    t.isTrue(result.ok)
    t.equals(result.limit, 12)
    t.isFalse(result.truncated)
end)

t.test('tabletAuditDept: requesting more than the cap reports truncated = true and limit = 100', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditDept'](src, 'police', 999999)
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.equals(result.limit, 100)
    t.isTrue(result.truncated)
end)

t.test('tabletAuditXp: carries cap for a uniform response shape, but no limit/truncated fields -- there is nothing to clamp (citizenid is the PRIMARY KEY, always 0 or 1 rows)', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditXp'](src, 'ABCD1234')
    t.isTrue(result.ok)
    t.equals(result.cap, 100)
    t.isNil(result.limit, 'tabletAuditXp takes no limit argument at all -- limit must be absent, never a guessed/default value')
    t.isNil(result.truncated, 'truncated is meaningless with no limit concept -- must be absent, never false')
end)

-- ----------------------------------------------------------------------
-- "Do not widen authorization" -- an unauthorized/rate-limited/malformed
-- caller must learn NOTHING new from this pass's cap/limit/truncated
-- fields. Every refusal branch returns before HARD_MAX_RESULTS is ever
-- attached to a response -- these cases lock that in across all three
-- refusal kinds, on both a limit-taking callback (tabletAuditCert) and the
-- one that never takes a limit at all (tabletAuditXp).
-- ----------------------------------------------------------------------

t.test('tabletAuditCert: not_authorized carries no cap/limit/truncated -- an unauthorized caller learns nothing about the server-side cap', function()
    resetCaptures()
    local src = 9301 -- no playersBySource entry -- unresolvable, denied
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', 999999)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isNil(result.cap)
    t.isNil(result.limit)
    t.isNil(result.truncated)
end)

t.test('tabletAuditCert: rate_limited carries no cap/limit/truncated', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    fakeNow = fakeNow + 100000
    registeredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234', 999999)
    t.isFalse(result.ok)
    t.equals(result.error, 'rate_limited')
    t.isNil(result.cap)
    t.isNil(result.limit)
    t.isNil(result.truncated)
end)

t.test('tabletAuditCert: invalid_args carries no cap/limit/truncated', function()
    resetCaptures()
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, '', 999999)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_args')
    t.isNil(result.cap)
    t.isNil(result.limit)
    t.isNil(result.truncated)
end)

t.test('tabletAuditXp: not_authorized carries no cap either -- the no-limit callback must not leak the cap any more freely than the limit-taking ones', function()
    resetCaptures()
    local src = 9302
    local result = registeredCallbacks['john-k9:server:tabletAuditXp'](src, 'ABCD1234')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isNil(result.cap)
end)

t.test('tabletAuditDept: not_authorized carries no cap/limit/truncated', function()
    resetCaptures()
    local src = 9303
    local result = registeredCallbacks['john-k9:server:tabletAuditDept'](src, 'police', 999999)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isNil(result.cap)
    t.isNil(result.limit)
    t.isNil(result.truncated)
end)

-- ----------------------------------------------------------------------
-- GAP 2 CLOSURE -- 'john-k9:server:tabletAuditCatalog'. The eight
-- catalog-edit audit tables (cert tiers, permission keys, XP tiers, shop
-- items, shop locations, per-K9 overrides, runtime overrides, tablet
-- themes) were write-only until this pass; this is the ONE generic,
-- catalog-name-parameterized read callback that replaces what would
-- otherwise be eight near-identical copies of tabletAuditCert's own shape.
-- Reuses the EXACT SAME IsAuthorizedAdmin/AuditCooldown/ClampLimit/
-- HARD_MAX_RESULTS/LogAuditInvocation scaffolding every callback above
-- already does -- these cases prove that reuse, not merely that the new
-- callback "works" in isolation.
-- ----------------------------------------------------------------------

t.test('tabletAuditCatalog: registered exactly like the other five audit callbacks', function()
    t.isNotNil(registeredCallbacks['john-k9:server:tabletAuditCatalog'], 'onResourceStart must register tabletAuditCatalog')
end)

t.test('tabletAuditCatalog: an unauthorized caller is denied, no query runs, shape is { ok = false, error = "not_authorized", message }', function()
    resetCaptures()
    local src = 9401
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.contains(result.message, 'not authorized')
    t.contains(capturedPrints[#capturedPrints], 'ran tabletAuditCatalog(n/a) -> denied')
end)

t.test('tabletAuditCatalog: an unknown catalog name is rejected as invalid_args, no query runs -- the HARDCODED allowlist, not a client-suppliable table name', function()
    -- A FRESH source per case (never the same one twice) -- reusing one
    -- source across several calls in the same test would trip the shared
    -- AuditCooldown on the 2nd+ call and report rate_limited instead of the
    -- invalid_args this test actually means to exercise.
    local badNames = {
        'k9_certifications', -- a REAL table name in this schema, but not a valid catalogName key -- must still be refused
        'certTiers; DROP TABLE k9_certification_tier_audit;--',
        '', 123, {}, true,
    }
    for _, badName in ipairs(badNames) do
        resetCaptures()
        local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](freshAuthorizedSource(), badName)
        t.equals(#capturedQueries, 0, 'catalogName=' .. tostring(badName) .. ' must never reach a query')
        t.isFalse(result.ok)
        t.equals(result.error, 'invalid_args')
    end
    -- `nil` handled separately -- embedding a literal nil inside the array
    -- above would make `ipairs` stop early (a nil hole ends iteration), so
    -- every case after it would silently never run.
    resetCaptures()
    local nilResult = registeredCallbacks['john-k9:server:tabletAuditCatalog'](freshAuthorizedSource(), nil)
    t.equals(#capturedQueries, 0, 'catalogName=nil must never reach a query')
    t.isFalse(nilResult.ok)
    t.equals(nilResult.error, 'invalid_args')
end)

t.test('tabletAuditCatalog: a valid catalogName returns RAW rows, plus ok/label/cap/limit/truncated -- same shape as every other tabletAudit* callback', function()
    resetCaptures()
    fixtureResponder = function(sql)
        if sql:find('FROM k9_certification_tier_audit', 1, true) then
            return {
                { action = 'tier_create', tier_key = 'master', detail = 'label=Master ordinal=4', changed_by = 'HC1', changed_at = '2024-01-01 00:00:00' },
            }
        end
        return {}
    end
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    t.equals(#capturedQueries, 1)
    t.isTrue(result.ok)
    t.equals(type(result.rows), 'table')
    t.equals(#result.rows, 1)
    t.equals(result.rows[1].tier_key, 'master', 'rows must be the RAW k9_certification_tier_audit row -- a real field, never a formatted string')
    t.equals(result.rows[1].changed_by, 'HC1')
    t.contains(result.label, 'audit')
    t.equals(result.cap, 100)
    t.equals(result.limit, 50, 'absent limit falls back to the configured Config.AdminAudit.MaxResults.CatalogAudit default')
    t.isFalse(result.truncated)
    t.equals(#capturedNotifications, 0, 'a callback invocation must never also fire a chat toast')
    t.contains(capturedPrints[#capturedPrints], 'ran tabletAuditCatalog(certTiers) -> ok')
end)

t.test('tabletAuditCatalog: every one of the eight real catalog names routes to its OWN table, never a different one', function()
    local cases = {
        { name = 'certTiers', tableName = 'k9_certification_tier_audit' },
        { name = 'permissionKeys', tableName = 'k9_permission_key_audit' },
        { name = 'xpTiers', tableName = 'k9_xp_tier_audit' },
        { name = 'shopItems', tableName = 'k9_equipment_shop_item_audit' },
        { name = 'shopLocations', tableName = 'k9_equipment_shop_locations_audit' },
        { name = 'k9Profiles', tableName = 'k9_individual_override_audit' },
        { name = 'runtimeOverrides', tableName = 'k9_runtime_override_audit' },
        { name = 'tabletThemes', tableName = 'k9_tablet_theme_audit' },
    }
    for _, case in ipairs(cases) do
        resetCaptures()
        fixtureResponder = nil
        local src = freshAuthorizedSource()
        local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, case.name)
        t.isTrue(result.ok, case.name .. ' must be a recognized catalog name')
        t.equals(#capturedQueries, 1, case.name .. ' must issue exactly one query')
        t.contains(capturedQueries[1].sql, 'FROM ' .. case.tableName, case.name .. ' must query its own table')
    end
end)

t.test('tabletAuditCatalog: rate limiting is the SAME shared AuditCooldown budget every other tabletAudit* callback uses', function()
    resetCaptures()
    fixtureResponder = nil
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    t.isTrue(result.ok)
    local result2 = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    t.isFalse(result2.ok)
    t.equals(result2.error, 'rate_limited')
end)

t.test('tabletAuditCatalog: a callback call ALSO feeds the shared cooldown -- blocks a subsequent tabletAuditCert call from the same source', function()
    resetCaptures()
    fixtureResponder = nil
    local src = freshAuthorizedSource()
    registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    local result = registeredCallbacks['john-k9:server:tabletAuditCert'](src, 'ABCD1234')
    t.isFalse(result.ok)
    t.equals(result.error, 'rate_limited')
end)

t.test('tabletAuditCatalog: limit is clamped exactly like every other tabletAudit* callback -- an out-of-range numeric limit clamps to the hard max (100)', function()
    resetCaptures()
    fixtureResponder = nil
    local src = freshAuthorizedSource()
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers', 999999)
    t.isTrue(result.ok)
    t.equals(result.limit, 100)
    t.isTrue(result.truncated)
end)

t.test('tabletAuditCatalog: PER-PERSON FEATURE CONTROL applies identically -- an explicit block denies even job.isboss', function()
    resetCaptures()
    fixtureResponder = nil
    grantPermission('CITFC-CATALOG-1', 'block.AdminAuditCommands', true)
    local src = freshSourceWithPlayerData({
        citizenid = 'CITFC-CATALOG-1',
        job = { name = 'police', isboss = true, grade = { level = 0 } },
    })
    local result = registeredCallbacks['john-k9:server:tabletAuditCatalog'](src, 'certTiers')
    t.equals(#capturedQueries, 0)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

-- ----------------------------------------------------------------------
-- CONFIG-ABORT REGRESSION GUARD (this pass) -- NON-NEGOTIABLE: "NEVER use a
-- bare top-level assert on a config value... one bad assert silently kills
-- every registration below it for the server's entire uptime." A fresh,
-- fully independent fixture (never the shared `env`/`Config` above, since
-- those already carry a valid CatalogAudit key from file-load time) whose
-- Config.AdminAudit.MaxResults is missing CatalogAudit ENTIRELY -- modelling
-- an operator who already had Config.Features.AdminAuditCommands = true and
-- their own MaxResults table from BEFORE this pass ever added the new key.
-- ----------------------------------------------------------------------

t.test('CONFIG-ABORT REGRESSION: a MISSING Config.AdminAudit.MaxResults.CatalogAudit must NOT abort registration of the other five commands/six callbacks -- clamp-and-warn, never assert', function()
    local printed = {}
    local function printStub2(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printed[#printed + 1] = table.concat(parts, '\t')
    end

    local eventHandlers2 = {}
    local function AddEventHandler2(eventName, handler)
        eventHandlers2[eventName] = eventHandlers2[eventName] or {}
        eventHandlers2[eventName][#eventHandlers2[eventName] + 1] = handler
    end

    local registeredCommands2 = {}
    local function RegisterCommand2(name, handler, _restricted)
        registeredCommands2[name] = handler
    end

    local callbacks2 = {}
    local lib2 = { callback = { register = function(name, handler) callbacks2[name] = handler end } }

    local Config2 = {
        Features = { AdminAuditCommands = true },
        CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
        AdminAudit = {
            CommandCooldownMs = 300,
            TrustConsole = false,
            -- CatalogAudit DELIBERATELY ABSENT -- the exact pre-this-pass
            -- operator config shape this regression guard exists to protect.
            MaxResults = { Certifications = 50, Partnerships = 50, SearchLog = 50 },
        },
        Departments = {
            police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4 },
        },
        FeatureControl = { RequireGrant = {} },
    }

    local env2 = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        RegisterCommand = RegisterCommand2,
        AddEventHandler = AddEventHandler2,
        GetCurrentResourceName = function() return 'john-k9' end,
        IsPlayerAceAllowed = function() return false end,
        HasPermission = function() return false end,
        exports = { qbx_core = { GetPlayer = function(_self, src)
            if src == 555 then
                return { PlayerData = { citizenid = 'CIT555', job = { name = 'police', grade = { level = 4 } } } }
            end
            return nil
        end } },
        -- Answers server/datastore.lua's boot schema probe as a fully
        -- installed database; every other query returns no rows, which is
        -- all these tests need. Before the probe existed this was just
        -- `return {}`, and that now reads as "the SQL was never imported".
        MySQL = { query = { await = function(sql, _params)
            if Sandbox.isSchemaProbe(sql) then return Sandbox.installedSchemaRows() end
            return {}
        end } },
        NotifyPlayer = function(...) end,
        print = printStub2,
        Config = Config2,
        lib = lib2,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env2)
    Sandbox.loadInto('../server/datastore.lua', env2)

    -- THE ACTUAL REGRESSION TEST: this must complete WITHOUT throwing.
    -- Wrapped in pcall purely so a real regression (an assert firing) is
    -- reported as a clear, named test failure below rather than a raw Lua
    -- error aborting this whole spec file's run.
    local loadOk, loadErr = pcall(Sandbox.loadInto, '../server/admin.lua', env2)
    t.isTrue(loadOk, 'server/admin.lua must load without throwing: ' .. tostring(loadErr))

    local fireOk, fireErr = pcall(function()
        for _, handler in ipairs(eventHandlers2['onResourceStart'] or {}) do
            handler('john-k9')
        end
    end)
    t.isTrue(fireOk, 'onResourceStart must complete without throwing on a MISSING CatalogAudit key: ' .. tostring(fireErr))

    -- Every pre-existing command AND callback (including the five that have
    -- nothing to do with CatalogAudit) must still be registered -- the whole
    -- point of clamp-and-warn over assert is that ONE missing/malformed key
    -- must never take the rest of this file's registration down with it.
    t.isNotNil(registeredCommands2.k9audit, 'the merged k9audit dispatcher must still register')
    t.isNotNil(callbacks2['john-k9:server:tabletAuditCert'], 'tabletAuditCert must still register')
    t.isNotNil(callbacks2['john-k9:server:tabletAuditPartner'], 'tabletAuditPartner must still register')
    t.isNotNil(callbacks2['john-k9:server:tabletAuditSearch'], 'tabletAuditSearch must still register')
    t.isNotNil(callbacks2['john-k9:server:tabletAuditXp'], 'tabletAuditXp must still register')
    t.isNotNil(callbacks2['john-k9:server:tabletAuditDept'], 'tabletAuditDept must still register')
    t.isNotNil(callbacks2['john-k9:server:tabletAuditCatalog'], 'tabletAuditCatalog itself must ALSO still register')

    -- A clear, named warning must have been printed -- "loud, never fatal".
    local warned = false
    for _, line in ipairs(printed) do
        if line:find('CatalogAudit', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a missing CatalogAudit key must print a warning naming it, not fail silently either')

    -- The new callback must actually WORK, using the built-in fallback (25)
    -- as its default limit -- clamp-and-warn means "still functions", not
    -- merely "does not crash at boot".
    local result = callbacks2['john-k9:server:tabletAuditCatalog'](555, 'certTiers')
    t.isTrue(result.ok, 'tabletAuditCatalog must actually work off the built-in fallback, not just boot without erroring')
    t.equals(result.limit, 25, 'the built-in fallback (25) must be the effective default limit when CatalogAudit was never configured')
end)

-- ----------------------------------------------------------------------
-- CONFIG-ABORT REGRESSION (this pass): Config.Departments[*].auditGrade,
-- Config.AdminAudit.CommandCooldownMs, and Config.AdminAudit.MaxResults.*
-- used to be bare `assert`s inside this SAME onResourceStart handler. A
-- malformed value must now warn and fall back instead of throwing -- and,
-- the part a bare "does not throw" test would miss, every command/callback
-- this handler registers must still exist AND actually work afterward, off
-- the substituted safe values.
-- ----------------------------------------------------------------------

t.test('CONFIG-ABORT REGRESSION: malformed auditGrade (one department), CommandCooldownMs, and MaxResults.Certifications must all warn and fall back, never assert -- every command/callback still registers and actually works', function()
    local printed3 = {}
    local function printStub3(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printed3[#printed3 + 1] = table.concat(parts, '\t')
    end

    local eventHandlers3 = {}
    local function AddEventHandler3(eventName, handler)
        eventHandlers3[eventName] = eventHandlers3[eventName] or {}
        eventHandlers3[eventName][#eventHandlers3[eventName] + 1] = handler
    end

    local registeredCommands3 = {}
    local function RegisterCommand3(name, handler, _restricted)
        registeredCommands3[name] = handler
    end

    local callbacks3 = {}
    local lib3 = { callback = { register = function(name, handler) callbacks3[name] = handler end } }

    local playersBySource3 = {}

    local Config3 = {
        Features = { AdminAuditCommands = true },
        CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
        AdminAudit = {
            -- MALFORMED: a string instead of a number.
            CommandCooldownMs = 'oops',
            TrustConsole = false,
            -- MALFORMED: Certifications is above HARD_MAX_RESULTS (100).
            MaxResults = { Certifications = 999999, Partnerships = 25, SearchLog = 25, CatalogAudit = 25 },
        },
        Departments = {
            police  = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4 },
            -- MALFORMED: a quoted string instead of a number -- the exact
            -- plausible owner typo this regression guards against.
            sheriff = { label = 'Blaine County Sheriff', certifierGrade = 3, auditGrade = '4' },
        },
        FeatureControl = { RequireGrant = {} },
    }

    local env3 = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        RegisterCommand = RegisterCommand3,
        AddEventHandler = AddEventHandler3,
        GetCurrentResourceName = function() return 'john-k9' end,
        IsPlayerAceAllowed = function() return false end,
        HasPermission = function() return false end,
        exports = { qbx_core = { GetPlayer = function(_self, src) return playersBySource3[src] end } },
        NotifyPlayer = function(...) end,
        MySQL = { query = { await = function(sql, _params)
            if Sandbox.isSchemaProbe(sql) then return Sandbox.installedSchemaRows() end
            return {}
        end } },
        print = printStub3,
        Config = Config3,
        lib = lib3,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env3)
    Sandbox.loadInto('../server/datastore.lua', env3)

    local loadOk, loadErr = pcall(Sandbox.loadInto, '../server/admin.lua', env3)
    t.isTrue(loadOk, 'server/admin.lua must load without throwing: ' .. tostring(loadErr))

    local fireOk, fireErr = pcall(function()
        for _, handler in ipairs(eventHandlers3['onResourceStart'] or {}) do
            handler('john-k9')
        end
    end)
    t.isTrue(fireOk, 'onResourceStart must complete without throwing on a malformed auditGrade/CommandCooldownMs/MaxResults: ' .. tostring(fireErr))

    -- Every command AND callback must still be registered -- none of these
    -- three malformed values have anything to do with most of them.
    t.isNotNil(registeredCommands3.k9audit, 'the merged k9audit dispatcher must still register')
    t.isNotNil(callbacks3['john-k9:server:tabletAuditCert'], 'tabletAuditCert must still register')
    t.isNotNil(callbacks3['john-k9:server:tabletAuditPartner'], 'tabletAuditPartner must still register')
    t.isNotNil(callbacks3['john-k9:server:tabletAuditSearch'], 'tabletAuditSearch must still register')
    t.isNotNil(callbacks3['john-k9:server:tabletAuditXp'], 'tabletAuditXp must still register')
    t.isNotNil(callbacks3['john-k9:server:tabletAuditDept'], 'tabletAuditDept must still register')
    t.isNotNil(callbacks3['john-k9:server:tabletAuditCatalog'], 'tabletAuditCatalog must still register')

    -- A clear, named warning for each of the three bad settings.
    local warnedAuditGrade, warnedCooldown, warnedMaxResults = false, false, false
    for _, line in ipairs(printed3) do
        if line:find('auditGrade', 1, true) and line:find('sheriff', 1, true) then warnedAuditGrade = true end
        if line:find('CommandCooldownMs', 1, true) then warnedCooldown = true end
        if line:find('MaxResults.Certifications', 1, true) then warnedMaxResults = true end
    end
    t.isTrue(warnedAuditGrade, 'a malformed Config.Departments.sheriff.auditGrade must print a warning naming both the field and the department')
    t.isTrue(warnedCooldown, 'a malformed Config.AdminAudit.CommandCooldownMs must print a warning naming it')
    t.isTrue(warnedMaxResults, 'a malformed Config.AdminAudit.MaxResults.Certifications must print a warning naming it')

    -- The substituted values must actually be in effect afterward, not
    -- merely warned about.
    t.isNil(Config3.Departments.sheriff.auditGrade, 'the malformed sheriff.auditGrade must be forced to nil')
    t.equals(Config3.Departments.police.auditGrade, 4, 'the unrelated police department\'s own valid auditGrade must be untouched')
    t.isTrue(Config3.AdminAudit.CommandCooldownMs >= 250, 'CommandCooldownMs must have been resolved to a valid, usable cooldown')
    t.equals(Config3.AdminAudit.MaxResults.Certifications, 25, 'the malformed MaxResults.Certifications must be forced to the built-in fallback of 25')

    -- k9audit cert must actually WORK end to end off the corrected values,
    -- not merely "be registered": a sheriff BOSS still qualifies (job.isboss
    -- bypasses auditGrade entirely, unaffected by the fix), a sheriff
    -- NON-boss is now denied (fails closed on the corrected nil
    -- auditGrade), and the unrelated police department keeps working
    -- exactly as configured.
    playersBySource3[701] = { PlayerData = { citizenid = 'SHERIFF_BOSS', job = { name = 'sheriff', isboss = true, grade = { level = 0 } } } }
    playersBySource3[702] = { PlayerData = { citizenid = 'SHERIFF_OFFICER', job = { name = 'sheriff', grade = { level = 99 } } } }
    playersBySource3[703] = { PlayerData = { citizenid = 'POLICE_OFFICER', job = { name = 'police', grade = { level = 4 } } } }

    -- No citizenid arg -> IsValidCitizenId fails -> 'invalid_args', but ONLY
    -- if authorization already passed; an unauthorized caller is denied
    -- first and never reaches that check (see IsAuthorizedAdmin's own call
    -- order at the top of this command).
    registeredCommands3.k9audit(701, { 'cert' })
    t.contains(printed3[#printed3], 'invalid_args', 'a sheriff BOSS must pass authorization despite the corrected nil auditGrade')

    registeredCommands3.k9audit(702, { 'cert' })
    t.contains(printed3[#printed3], 'denied', 'a sheriff NON-boss must now be denied -- fails closed on the corrected nil auditGrade')

    registeredCommands3.k9audit(703, { 'cert' })
    t.contains(printed3[#printed3], 'invalid_args', 'the unrelated police department\'s own valid auditGrade=4 must still authorize its officers exactly as configured')
end)

os.exit(t.summary())
