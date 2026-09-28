--[[
    tests/notify_spec.lua

    Direct tests of server/notify.lua's shared NotifyPlayer against the
    REAL, unmodified production file (resource-global, no `local` --
    reachable directly, unlike server/search.lua's ResolveAlertTier), plus
    tests of the two files that DELIBERATELY keep a same-named local
    NotifyPlayer wrapper shadowing this global (server/admin.lua,
    server/bonetool.lua -- see notify.lua's own header "TWO CALL SITES
    DELIBERATELY KEPT AS LOCAL WRAPPERS" section).

    The delegation tests below load the REAL server/notify.lua alongside the
    REAL server/admin.lua / server/bonetool.lua in the SAME sandbox env
    (env._G points at env itself, per fixtures/sandbox.lua) and drive an
    actual RegisterCommand handler through to a real notification, so a
    regression that turned the documented `_G.NotifyPlayer(...)` call back
    into a bare `NotifyPlayer(...)` (which this resource's own header warns
    would recurse forever, since `local function NotifyPlayer` is already in
    scope inside its own body) would show up here as this spec HANGING or
    erroring with a stack overflow, not merely a wrong assertion -- a
    stronger regression guard than stubbing NotifyPlayer directly the way
    admin_spec.lua does for its own, unrelated purposes.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Part 1: server/notify.lua's NotifyPlayer directly -- varying arity
-- ----------------------------------------------------------------------

local capturedEvents = {}
local function TriggerClientEvent(eventName, target, payload)
    capturedEvents[#capturedEvents + 1] = { eventName = eventName, target = target, payload = payload }
end

local notifyEnv = Sandbox.newEnv({
    TriggerClientEvent = TriggerClientEvent,
})
Sandbox.loadInto('../server/notify.lua', notifyEnv)

local NotifyPlayer = notifyEnv.NotifyPlayer
t.isNotNil(NotifyPlayer, 'server/notify.lua must define global NotifyPlayer')

local function resetEvents()
    capturedEvents = {}
end

t.test('NotifyPlayer: 2-arg call (target, description) uses both documented defaults', function()
    resetEvents()
    NotifyPlayer(101, 'hello')
    t.equals(#capturedEvents, 1)
    local e = capturedEvents[1]
    t.equals(e.eventName, 'ox_lib:notify')
    t.equals(e.target, 101)
    t.equals(e.payload.description, 'hello')
    -- 'info' (not the old 'inform') -- verified against ox_lib's REAL
    -- upstream `resource/interface/client/notify.lua`:
    -- `---@alias NotificationType 'info' | 'warning' | 'success' | 'error'`.
    -- 'inform' is not, and never was, a member of that alias; it is a
    -- leftover from ox_lib v3 only remapped to 'info' inside the
    -- DEPRECATED `lib.defaultNotify` back-compat shim, which this file's
    -- `TriggerClientEvent('ox_lib:notify', ...)` never routes through
    -- (the client registers that event directly against `lib.notify`) --
    -- see server/notify.lua's own header for the full writeup.
    t.equals(e.payload.type, 'info', 'notifyType must default to the valid ox_lib NotificationType "info", not the invalid legacy "inform"')
    t.equals(e.payload.title, 'K9 Unit', 'title must default to K9 Unit')
end)

t.test('NotifyPlayer: 3-arg call overrides notifyType, title still defaults', function()
    resetEvents()
    NotifyPlayer(102, 'oops', 'error')
    local e = capturedEvents[1]
    t.equals(e.payload.type, 'error')
    t.equals(e.payload.title, 'K9 Unit')
end)

t.test('NotifyPlayer: 4-arg call overrides both notifyType and title', function()
    resetEvents()
    NotifyPlayer(103, 'custom', 'success', 'Custom Title')
    local e = capturedEvents[1]
    t.equals(e.payload.type, 'success')
    t.equals(e.payload.title, 'Custom Title')
end)

t.test('NotifyPlayer: an explicit nil notifyType/title (positional) still falls back to defaults', function()
    resetEvents()
    NotifyPlayer(104, 'explicit nils', nil, nil)
    local e = capturedEvents[1]
    -- 'info', not 'inform' -- ox_lib's NotificationType alias only
    -- contains 'info' | 'warning' | 'success' | 'error'; see the first
    -- test above for the full citation.
    t.equals(e.payload.type, 'info')
    t.equals(e.payload.title, 'K9 Unit')
end)

t.test('NotifyPlayer: title-only override (notifyType nil, title given) -- mirrors a caller that only ever varies title', function()
    resetEvents()
    NotifyPlayer(105, 'desc', nil, 'K9 Unit — Something')
    local e = capturedEvents[1]
    -- 'info', not 'inform' -- see the first test in this file for the
    -- ox_lib NotificationType citation.
    t.equals(e.payload.type, 'info', 'a nil notifyType with a real title must still default type to the valid "info"')
    t.equals(e.payload.title, 'K9 Unit — Something')
end)

t.test('NotifyPlayer: sequential calls to different targets do not leak state between calls', function()
    resetEvents()
    NotifyPlayer(201, 'first', 'error', 'Title A')
    NotifyPlayer(202, 'second')
    t.equals(#capturedEvents, 2)
    t.equals(capturedEvents[1].target, 201)
    t.equals(capturedEvents[1].payload.type, 'error')
    t.equals(capturedEvents[2].target, 202)
    -- 'info', not 'inform' -- see the first test in this file for the
    -- ox_lib NotificationType citation.
    t.equals(capturedEvents[2].payload.type, 'info', 'the second, default call must not inherit the first call\'s override, and must default to the valid "info"')
end)

-- ----------------------------------------------------------------------
-- Part 2: server/bonetool.lua's local NotifyPlayer wrapper -- delegates to
-- the REAL server/notify.lua global via `_G.NotifyPlayer(...)`, never
-- recurses.
-- ----------------------------------------------------------------------

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
    return 'qbx_k9unit'
end

-- server/bonetool.lua switched from an ACE grant to police job rank on
-- 2026-08-25, so an ACE stub here would authorize nothing. A source is
-- authorized by having a resolvable qbx_core player whose job is a
-- configured department and who is either a boss of it or at/above its
-- auditGrade. Register a shape here, then drive the command.
local boneToolPlayersBySource = {}
local boneToolExportsStub = {
    qbx_core = {
        GetPlayer = function(_self, src) return boneToolPlayersBySource[src] end,
    },
}

--- The dev tool now requires a SECOND, explicit opt-in on top of
--- Config.Features.BoneSweepDevTool: an operator must deliberately set a
--- convar too, so "all features enabled" alone cannot expose it. These two
--- cases are about the NotifyPlayer wrapper, not the gate, so the convar
--- reads as set -- tests/bonetool_spec.lua owns the gate's own coverage.
local boneToolConvars = { qbx_k9unit_enable_bone_dev_tool = 1 }
local function GetConvarInt(name, default)
    local v = boneToolConvars[name]
    if v == nil then return default end
    return v
end

local boneToolCapturedClientEvents = {}
local function TriggerClientEventForBoneTool(eventName, target, ...)
    boneToolCapturedClientEvents[#boneToolCapturedClientEvents + 1] = { eventName, target, ... }
end

local boneToolFakeNow = 0
local function GetGameTimerForBoneTool()
    return boneToolFakeNow
end

local Config = {
    Features = { BoneSweepDevTool = true },
    -- IsAuthorizedBoneTool resolves the caller's own department threshold
    -- from this, the same way server/admin.lua's IsAuthorizedAdmin does.
    Departments = {
        police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, autoAccessGrade = nil },
    },
    BoneSweepTool = {
        TestPropModel = 'prop_test_model',
        MaxBoneIndex = 200,
        TestOffsetX = 0, TestOffsetY = 0, TestOffsetZ = 0,
        CommandCooldownMs = 500,
    },
}

local function printStubBoneTool(...) end

local boneToolEnv = Sandbox.newEnv({
    TriggerClientEvent = TriggerClientEventForBoneTool,
    RegisterCommand = RegisterCommand,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    exports = boneToolExportsStub,
    GetConvarInt = GetConvarInt,
    GetGameTimer = GetGameTimerForBoneTool,
    print = printStubBoneTool,
    Config = Config,
})

-- Load order per fxmanifest.lua: cooldowns.lua, then notify.lua, then
-- bonetool.lua (bonetool.lua calls NewCooldown() at its own file-load time).
Sandbox.loadInto('../server/cooldowns.lua', boneToolEnv)
Sandbox.loadInto('../server/notify.lua', boneToolEnv)
Sandbox.loadInto('../server/bonetool.lua', boneToolEnv)

for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('qbx_k9unit')
end

t.isNotNil(registeredCommands.k9bonetool, 'onResourceStart must register k9bonetool when Config.Features.BoneSweepDevTool is true')

t.test('bonetool local NotifyPlayer: delegates to the REAL notify.lua global with its OWN title, no recursion', function()
    boneToolCapturedClientEvents = {}
    local src = 5001
    -- Unauthorized: no resolvable player record at all -> the authorization
    -- check fails closed and hits the local NotifyPlayer wrapper.
    boneToolPlayersBySource[src] = nil
    -- If this ever regresses to a bare `NotifyPlayer(...)` call inside
    -- bonetool.lua's own local wrapper, this line hangs/stack-overflows
    -- instead of returning -- that IS the regression signal.
    registeredCommands.k9bonetool(src, {})
    t.equals(#boneToolCapturedClientEvents, 1, 'the unauthorized notification is a real client event, ox_lib:notify')
    local e = boneToolCapturedClientEvents[1]
    t.equals(e[1], 'ox_lib:notify')
    t.equals(e[2], src)
    t.equals(e[3].title, 'K9 Unit — Bone Tool', 'must use bonetool.lua\'s OWN deliberately-different title, not the K9 Unit default')
    t.equals(e[3].type, 'error')
    t.contains(e[3].description, 'not authorized')
end)

t.test('bonetool local NotifyPlayer: an authorized "help" invocation also carries the bonetool title', function()
    boneToolCapturedClientEvents = {}
    boneToolFakeNow = boneToolFakeNow + 1000
    local src = 5002
    boneToolPlayersBySource[src] = {
        PlayerData = {
            citizenid = 'CITBONE',
            job = { name = 'police', isboss = true, grade = { level = 4 } },
        },
    }
    registeredCommands.k9bonetool(src, { 'help' })
    t.equals(#boneToolCapturedClientEvents, 1)
    t.equals(boneToolCapturedClientEvents[1][3].title, 'K9 Unit — Bone Tool')
    -- 'info', not the old 'inform'. server/bonetool.lua's 'help' call
    -- site passes its type literally rather than relying on
    -- server/notify.lua's default, so it needed its own fix; that fix
    -- has now landed and this assertion tracks it. ox_lib's real
    -- NotificationType alias is 'info' | 'warning' | 'success' | 'error'
    -- -- 'inform' was never a member. It is a v3 leftover that ox_lib
    -- only remaps inside the deprecated lib.defaultNotify shim, which
    -- this resource never calls, so it reached the frontend unmapped and
    -- rendered correctly purely by falling through the same default:
    -- branch as 'info'.
    t.equals(boneToolCapturedClientEvents[1][3].type, 'info')
end)

-- ----------------------------------------------------------------------
-- Part 3: server/admin.lua's local NotifyPlayer wrapper -- same delegation
-- pattern, its OWN distinct title ('K9 Unit — Admin Audit').
-- ----------------------------------------------------------------------

local adminRegisteredCommands = {}
local function RegisterCommandForAdmin(name, handler, _restricted)
    adminRegisteredCommands[name] = handler
end

local adminEventHandlers = {}
local function AddEventHandlerForAdmin(eventName, handler)
    adminEventHandlers[eventName] = adminEventHandlers[eventName] or {}
    adminEventHandlers[eventName][#adminEventHandlers[eventName] + 1] = handler
end

local adminAceGrants = {}
local function IsPlayerAceAllowedForAdmin(sourceIdStr, _ace)
    return adminAceGrants[sourceIdStr] == true
end

local adminCapturedClientEvents = {}
local function TriggerClientEventForAdmin(eventName, target, ...)
    adminCapturedClientEvents[#adminCapturedClientEvents + 1] = { eventName, target, ... }
end

local fakeNow = 0
local function GetGameTimerForAdmin()
    return fakeNow
end

local adminExportsStub = {
    qbx_core = {
        GetPlayer = function(_self, _src) return nil end, -- unresolved source is a valid path (LogAuditInvocation)
    },
}

local AdminConfig = {
    CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
    Features = { AdminAuditCommands = true },
    AdminAudit = {
        CommandCooldownMs = 300,
        TrustConsole = false,
        -- CatalogAudit (GAP 2 closure) -- server/admin.lua's own
        -- onResourceStart now asserts this key exists exactly like the
        -- three that were already here, so a fixture missing it would fail
        -- EVERY test in this file at boot, not just the new ones.
        MaxResults = { Certifications = 50, Partnerships = 50, SearchLog = 50, CatalogAudit = 50 },
    },
    -- server/admin.lua asserts Config.Departments is present whenever
    -- AdminAuditCommands is on: since 2026-08-25 IsAuthorizedAdmin resolves
    -- the caller's own department threshold from it instead of an ACE grant.
    -- This spec never authorizes anyone (its GetPlayer stub always returns
    -- nil), so a single real-shaped entry is all the assert needs.
    Departments = {
        police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, autoAccessGrade = nil },
    },
}

-- lib.callback.register stub -- server/admin.lua now registers a CALLBACK
-- SURFACE (tabletAuditCert/tabletAuditPartner/tabletAuditSearch/tabletAuditXp/
-- tabletAuditDept) inside the same onResourceStart block this spec fires
-- below; this file's own assertions are about the NotifyPlayer delegation
-- path only (Part 3's header), so a pure no-op capture is enough -- same
-- shape tests/permissions_spec.lua's own second `libStub` already uses for
-- the identical "just don't let lib.callback.register error" purpose.
local adminLibStub = { callback = { register = function(_name, _fn) end } }

local adminEnv = Sandbox.newEnv({
    GetGameTimer = GetGameTimerForAdmin,
    RegisterCommand = RegisterCommandForAdmin,
    AddEventHandler = AddEventHandlerForAdmin,
    GetCurrentResourceName = GetCurrentResourceName,
    IsPlayerAceAllowed = IsPlayerAceAllowedForAdmin,
    exports = adminExportsStub,
    MySQL = { query = { await = function(_sql, _params) return {} end } },
    TriggerClientEvent = TriggerClientEventForAdmin,
    print = function(...) end,
    Config = AdminConfig,
    lib = adminLibStub,
})

Sandbox.loadInto('../server/cooldowns.lua', adminEnv)
Sandbox.loadInto('../server/notify.lua', adminEnv)
-- server/datastore.lua -- DISPLAY NAME RESOLUTION / GAP 2 closure pass:
-- server/admin.lua's own onResourceStart now builds CATALOG_AUDIT_SOURCES
-- (a table literal that indexes K9Store.*Audit_GetRecent EAGERLY, at
-- registration time, not lazily inside a query function the way every
-- other K9Store reference in this file already was) -- so K9Store must
-- already be a real global by the time onResourceStart fires below, same
-- load-order requirement tests/admin_spec.lua's own env already satisfies
-- for the identical reason.
Sandbox.loadInto('../server/datastore.lua', adminEnv)
Sandbox.loadInto('../server/admin.lua', adminEnv)

for _, handler in ipairs(adminEventHandlers['onResourceStart'] or {}) do
    handler('qbx_k9unit')
end

t.isNotNil(adminRegisteredCommands.k9audit, 'onResourceStart must register the merged k9audit dispatcher')

t.test('admin local NotifyPlayer: delegates to the REAL notify.lua global with its OWN title, no recursion', function()
    adminCapturedClientEvents = {}
    local src = 6001
    adminAceGrants[tostring(src)] = false -- unauthorized -> hits the local NotifyPlayer wrapper
    adminRegisteredCommands.k9audit(src, { 'cert', 'ABCD1234' })
    t.equals(#adminCapturedClientEvents, 1)
    local e = adminCapturedClientEvents[1]
    t.equals(e[1], 'ox_lib:notify')
    t.equals(e[3].title, 'K9 Unit — Admin Audit', 'must use admin.lua\'s OWN deliberately-different title')
    t.equals(e[3].type, 'error')
    t.contains(e[3].description, 'not authorized')
end)

os.exit(t.summary())
