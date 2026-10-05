--[[
    tests/tabletfeaturedomains_spec.lua

    Owner-directed, 2026-08-26, verbatim: "same with features and sub
    features" -- Config.Features' 60 flat flags are now grouped into
    eleven labelled domains (server/tablet.lua's own FEATURE_DOMAINS),
    the same way commands were grouped. This file is the guarantee that
    grouping never silently rots: it loads the REAL, unmodified config.lua
    (never a hand-typed duplicate of its Config.Features key list, which
    could drift from the real thing the moment a key is added, renamed, or
    removed) and proves every single key resolves to a real domain via the
    REAL server/tablet.lua's own tabletRequestMyRecord/
    tabletRequestPersonFeatures callbacks -- i.e. this tests the OBSERVABLE
    CONTRACT (what a real caller's response actually contains), not
    server/tablet.lua's internal FEATURE_DOMAINS table directly (which is
    `local` and not exposed for a reason -- see that file's own
    "AUTHORIZATION-SHAPED HELPERS" header for this codebase's established
    reluctance to export a local purely for a test to poke at).

    Harness style borrows tests/tabletserver_spec.lua's own newFixture()
    shape (UNIT-level doubles for IsHighCommand/HasK9Access/etc.), but with
    ONE deliberate difference: `Config` here is the REAL config.lua's own
    table, loaded fresh into its own throwaway sandbox first, not the
    smaller, hand-authored default Config that file's own newFixture()
    uses for every OTHER test in this suite. That default table only lists
    a handful of Config.Features keys (CommandTablet, PermissionGrants,
    XPProgression, HighCommand, BiteAndHold, NonLethalTakedown,
    LeashMechanics) -- exactly the ones each of THOSE tests happens to
    need -- so it would prove nothing about the other ~53 keys this file
    exists to cover.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Load the REAL config.lua into its own throwaway env, so this file's own
-- fixture can hand its REAL Config.Features (and REAL Config.Departments/
-- Permissions/FeatureControl/CommandTablet, which server/tablet.lua's own
-- top-level code and callbacks also read) to server/tablet.lua below --
-- never a second, hand-typed copy of any of those tables.
-- ----------------------------------------------------------------------
local realConfigEnv = Sandbox.newEnv({})
Sandbox.loadInto('../config.lua', realConfigEnv)
local RealConfig = realConfigEnv.Config

--- @return table fixture
local function newFixture()
    local mysql = {
        query = { await = function() return {} end },
        scalar = { await = function() return nil end },
    }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local playersBySource = {}
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        return source
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function() return nil end,
            GetOfflinePlayer = function() return nil end,
        },
    }

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local fakeNow = { value = 0 }

    local env = Sandbox.newEnv({
        Config = RealConfig,
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = function(source) return 'Player#' .. tostring(source) end,
        GetGameTimer = function() return fakeNow.value end,
        GetPlayers = function() return {} end,
        AddEventHandler = AddEventHandlerStub,
        print = function() end,
        -- ALWAYS high command -- this file is not testing authorization
        -- (tabletserver_spec.lua already owns that in full); it needs
        -- every domain-bearing row to actually be BUILT and RETURNED for
        -- one real, admitted caller, for both tabletRequestMyRecord (every
        -- key, via BuildMyFeaturesArray) and tabletRequestPersonFeatures
        -- (every key, via the sibling person-features builder).
        IsHighCommand = function() return true end,
        HasK9Access = function() return true end,
        HasPermission = nil,
        GetXP = nil,
        GetXPTier = nil,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/tablet.lua', env)

    return {
        env = env,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        fakeNow = fakeNow,
    }
end

--- @param f table
--- @param name string
--- @return function
local function cb(f, name)
    local fn = f.callbacks[name]
    assert(fn, 'callback not registered: ' .. name)
    return fn
end

--- @return string[] -- every real Config.Features key, sorted
local function RealFeatureKeys()
    local keys = {}
    for key in pairs(RealConfig.Features) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

t.test('diagnostic: the real config.lua currently ships at least 45 Config.Features keys (a catastrophic parse failure/empty table fails here, not silently passing with zero keys checked)', function()
    local keys = RealFeatureKeys()
    -- FLOOR LOWERED 2026-09-02: twelve features were removed at the owner's request (61 -> 49 Config.Features keys), so the old floor could never be met again. It stays well above zero because its job is to catch an extraction pattern going stale and silently checking nothing -- not to pin the catalogue size.
    t.isTrue(#keys >= 45, ('expected at least 45 real Config.Features keys, got %d -- either config.lua failed to load or this fixture is not seeing it'):format(#keys))
end)

t.test('NO KEY LEFT BEHIND: every real Config.Features key gets a non-nil category in tabletRequestMyRecord\'s own myFeatures[]', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok, 'tabletRequestMyRecord must succeed for this fixture\'s own high-command caller')

    local byKey = {}
    for _, row in ipairs(result.myFeatures) do byKey[row.key] = row end

    local missing = {}
    for _, key in ipairs(RealFeatureKeys()) do
        local row = byKey[key]
        if not row then
            missing[#missing + 1] = key .. ' (missing from myFeatures entirely)'
        elseif type(row.category) ~= 'string' or row.category == '' then
            missing[#missing + 1] = key .. ' (category = ' .. tostring(row.category) .. ')'
        end
    end

    t.equals(#missing, 0, 'every Config.Features key must resolve to a real domain -- uncategorised: ' .. table.concat(missing, ', '))
end)

t.test('NO KEY LEFT BEHIND: every real Config.Features key gets a non-nil category in tabletRequestPersonFeatures\'s own features[] too', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'TARGET1')
    t.isTrue(result.ok, 'tabletRequestPersonFeatures must succeed for this fixture\'s own high-command caller')

    local byKey = {}
    for _, row in ipairs(result.features) do byKey[row.key] = row end

    local missing = {}
    for _, key in ipairs(RealFeatureKeys()) do
        local row = byKey[key]
        if not row then
            missing[#missing + 1] = key .. ' (missing from features entirely)'
        elseif type(row.category) ~= 'string' or row.category == '' then
            missing[#missing + 1] = key .. ' (category = ' .. tostring(row.category) .. ')'
        end
    end

    t.equals(#missing, 0, 'every Config.Features key must resolve to a real domain -- uncategorised: ' .. table.concat(missing, ', '))
end)

t.test('category is STABLE for a given key across both callbacks -- the same feature never renders under two different domain headings depending on which screen you view it from', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    local myRecord = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    f.fakeNow.value = f.fakeNow.value + 501 -- past the shared read cooldown -- these are two separate requests from the same source
    local personFeatures = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'TARGET1')
    t.isTrue(myRecord.ok and personFeatures.ok, 'both requests must succeed for this comparison to mean anything')

    local myByKey, personByKey = {}, {}
    for _, row in ipairs(myRecord.myFeatures) do myByKey[row.key] = row.category end
    for _, row in ipairs(personFeatures.features) do personByKey[row.key] = row.category end

    for _, key in ipairs(RealFeatureKeys()) do
        t.equals(myByKey[key], personByKey[key], 'category mismatch for ' .. key)
    end
end)

os.exit(t.summary())
