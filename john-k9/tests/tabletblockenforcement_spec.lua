--[[
    tests/tabletblockenforcement_spec.lua

    Covers server/tablet.lua's new `blockEnforcement` field on
    BuildPersonFeaturesArray's `features` rows (tabletRequestPersonFeatures'
    own PersonFeaturesResult contract -- see html/tablet.js's own doc
    comment for the four-state contract this implements).

    THE BUG THIS FIELD FIXES: twelve client-only features
    (client/featureblocks.lua) now have a REAL, WORKING per-person block --
    but server/tablet.lua never computed `blockEnforcement` at all, so
    html/tablet.js's own client-side fallback rendered them as
    'not_yet_enforced' ("Not enforced yet"), telling an operator a working
    block does nothing. This spec proves the fix: the twelve land on
    'client_enforced' (not 'enforced', not 'not_enforceable', and NEVER the
    'not_yet_enforced' fallback -- that value is JS-only, never sent by this
    file), Recall and the other structurally-unenforceable keys land on
    'not_enforceable' for their own DISCLOSED, DIFFERENT reasons, and every
    ordinary ability lands on 'enforced'.

    Loads the REAL, unmodified config.lua (not a hand-built feature list)
    so this spec is exercised against the actual, current Config.Features
    table -- catching drift if a feature is ever renamed, removed, or moved
    between categories without server/tablet.lua's own
    CLIENT_ENFORCED_FEATURES/NOT_ENFORCEABLE_FEATURES tables being updated
    to match. Harness style mirrors tests/tabletlocalization_spec.lua's own
    minimal fixture (real config.lua + test-controlled soft dependencies),
    not tests/tabletserver_spec.lua's own richer newFixture() (a `local`
    function private to that file, not reusable from here).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- The twelve features client/featureblocks.lua's own header names as
--- purely client-rendered/client-local -- kept here, independently, as
--- this spec's own expected-value fixture (never read from
--- server/tablet.lua's own CLIENT_ENFORCED_FEATURES table, which would
--- make this spec unable to catch that table drifting away from the real
--- list).
local EXPECTED_CLIENT_ENFORCED = {
    'RadialMenu', 'VehicleEntryExit', 'AgilityBasicJump', 'AgilityAdvanced',
    'ThermalVision', 'NightVision', 'HealthStaminaHUD', 'ContrabandScreenFX',
    'AdvancedBarkRadial', 'ProximityAudioFX', 'WaterTrackingDecay', 'CameraFeedPiP',
}

--- A representative sample of ordinary, server-enforced abilities --
--- confirmed, this pass, by direct code read (each file's own
--- HasPermission(citizenid, 'block.<Name>') call site) -- deliberately
--- spanning several different owning files rather than only one, so this
--- spec cannot pass by accident if only one file's convention were
--- actually wired.
local EXPECTED_ENFORCED = {
    'LeashMechanics',    -- server/main.lua (static)
    'BasicBarkSounds',   -- server/main.lua (static)
    'DoorInteraction',   -- server/main.lua (static)
    'K9Medkit',          -- server/medkit.lua
    'BiteAndHold',       -- server/combat.lua (dynamic featureKey)
    'NonLethalTakedown', -- server/combat.lua (dynamic featureKey)
    'PropDragging',      -- server/combat.lua (dynamic featureKey)
    'ScentTracking',     -- server/tracking.lua (dynamic featureName)
    'BloodTracking',     -- server/tracking.lua (dynamic featureName)
    'GunpowderSniffing', -- server/tracking.lua (dynamic featureName)
    'SearchZones',       -- server/search.lua (dynamic featureName)
    'ContrabandAlerts',  -- server/search.lua (dynamic featureName)
    'FatigueSystem',     -- server/wellbeing.lua (dynamic featureName)
    'XPProgression',     -- server/progression.lua
    'K9Inventory',       -- server/inventory.lua
    'K9Leaderboard',     -- server/leaderboard.lua
    'AdminAuditCommands',-- server/admin.lua
    'HandlerPartnership',-- server/partnership.lua
    -- K9EquipmentShop -- server/equipmentshop.lua (dynamic featureKey via
    -- IsEquipmentShopPermittedForCitizenId, gated at ox_inventory's own
    -- registerHook('openShop'/'buyItem', ...) hooks). MOVED HERE, this
    -- pass, from EXPECTED_NOT_ENFORCEABLE below -- a PRIOR analysis
    -- concluded no server-side boundary existed to gate; that was found
    -- to be WRONG, not merely superseded, by re-reading ox_inventory's own
    -- real source. See server/equipmentshop.lua's own "PER-PERSON FEATURE
    -- CONTROL" section for the full writeup.
    'K9EquipmentShop',
}

--- Confirmed, by direct code read this pass, to have NO server-side point
--- that would ever consult `block.<Name>` -- see server/tablet.lua's own
--- "BLOCK ENFORCEMENT CLASSIFICATION" section for the full per-key
--- reasoning this mirrors.
local EXPECTED_NOT_ENFORCEABLE = {
    'ResourceAutoDetect',     -- pure infra switch, not a per-citizenid ability
    'HighCommand',            -- pure infra switch
    'PermissionGrants',       -- pure infra switch
    'CommandTablet',          -- pure infra switch
    'CertificationExpiry',    -- pure infra switch
    'RuntimeFeatureControl',  -- pure infra switch
    'TabletTheming',          -- pure infra switch
}

--- @return table fixture -- { callbacks, registerPlayer, env }
local function newFixture()
    local mysql = {
        query = { await = function() return {} end },
        scalar = { await = function() return nil end },
    }

    local playersBySource = {}
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function() return nil end,
        },
    }

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local env = Sandbox.newEnv({
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = function(source) return 'Player#' .. tostring(source) end,
        print = function() end,
        IsHighCommand = function() return true end, -- this spec only needs to REACH BuildPersonFeaturesArray, not test authorization (tabletserver_spec.lua already covers that)
        HasPermission = function() return false end,
        HasK9Access = function() return false end,
        -- server/cooldowns.lua's own NewCooldown(...).RegisterPlayerDropped()
        -- calls AddEventHandler('playerDropped', ...) at THIS file's load
        -- time (loaded below, ahead of server/tablet.lua, for its own
        -- NewCooldown dependency) -- a no-op stub, mirroring
        -- tests/tabletserver_spec.lua's own simpler (non-capturing) form,
        -- since this spec never needs to fire a drop itself.
        AddEventHandler = function() end,
        -- TabletReadCooldown.Consume (server/cooldowns.lua) reads
        -- GetGameTimer() at call time -- this spec is about blockEnforcement
        -- classification, not cooldown behavior, so a monotonically
        -- increasing fake clock (every read jumps 1000ms, comfortably past
        -- TABLET_READ_COOLDOWN_MS's own 500ms floor) means back-to-back
        -- calls in the SAME test (e.g. two different target citizenids from
        -- the same high-command source) never spuriously rate-limit each
        -- other.
        GetGameTimer = (function()
            local fakeNow = 0
            return function()
                fakeNow = fakeNow + 1000
                return fakeNow
            end
        end)(),
    })

    -- REAL, unmodified config.lua -- see this file's own header for why.
    Sandbox.loadInto('../config.lua', env)
    env.Config.Features.CommandTablet = true -- already true in the shipped config; asserted explicitly so this spec never silently no-ops if that default is ever flipped

    -- server/cooldowns.lua -- HARD load-order requirement, same as the real
    -- fxmanifest.lua's own placement: server/tablet.lua now calls
    -- NewCooldown at its own file-load time (TabletReadCooldown), so
    -- cooldowns.lua must already be loaded into this SAME env first --
    -- mirrors tests/tabletserver_spec.lua's own identical fix.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/tablet.lua', env)

    local function registerPlayer(source, citizenid, job)
        playersBySource[source] = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        return source
    end

    return { env = env, callbacks = capturedCallbacks, registerPlayer = registerPlayer }
end

--- @param f table
--- @param name string
--- @return function
local function cb(f, name)
    local fn = f.callbacks[name]
    assert(fn, 'callback not registered: ' .. name)
    return fn
end

--- @param features table -- result.features array
--- @param key string
--- @return table row
local function findRow(features, key)
    for _, row in ipairs(features) do
        if row.key == key then return row end
    end
    error('no such feature row: ' .. key)
end

local function requestFeatures(f, targetCitizenId)
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, targetCitizenId)
    assert(result.ok, 'tabletRequestPersonFeatures unexpectedly failed: ' .. tostring(result.error))
    return result.features
end

-- ============================================================================
-- THE FOUR STATES, EACH RESOLVING CORRECTLY
-- ============================================================================

t.test('an ordinary, server-enforced ability resolves blockEnforcement == "enforced"', function()
    local f = newFixture()
    local features = requestFeatures(f, 'TARGET1')
    for _, key in ipairs(EXPECTED_ENFORCED) do
        t.equals(findRow(features, key).blockEnforcement, 'enforced', key .. ' should resolve "enforced"')
    end
end)

t.test('every one of the twelve client-only features resolves blockEnforcement == "client_enforced"', function()
    local f = newFixture()
    local features = requestFeatures(f, 'TARGET1')
    t.equals(#EXPECTED_CLIENT_ENFORCED, 12, 'sanity check on this spec\'s own fixture -- must stay the real twelve')
    for _, key in ipairs(EXPECTED_CLIENT_ENFORCED) do
        t.equals(findRow(features, key).blockEnforcement, 'client_enforced', key .. ' should resolve "client_enforced"')
    end
end)

t.test('pure administrative/infrastructure switches (no per-citizenid ability to gate at all) resolve "not_enforceable"', function()
    local f = newFixture()
    local features = requestFeatures(f, 'TARGET1')
    for _, key in ipairs(EXPECTED_NOT_ENFORCEABLE) do
        t.equals(findRow(features, key).blockEnforcement, 'not_enforceable', key .. ' should resolve "not_enforceable"')
    end
end)

t.test('blockEnforcement is NEVER the string "not_yet_enforced" -- that value is html/tablet.js\'s own client-side fallback for a field this file did not send, never something this file emits itself', function()
    local f = newFixture()
    local features = requestFeatures(f, 'TARGET1')
    for _, row in ipairs(features) do
        t.isFalse(row.blockEnforcement == 'not_yet_enforced', row.key .. ' must never be sent as not_yet_enforced by the server')
    end
end)

t.test('every row in a real Config.Features response carries a non-nil blockEnforcement -- the field is never simply absent for a known key', function()
    local f = newFixture()
    local features = requestFeatures(f, 'TARGET1')
    t.isTrue(#features > 0, 'sanity check -- the real config.lua must produce at least one feature row')
    for _, row in ipairs(features) do
        local v = row.blockEnforcement
        t.isTrue(v == 'enforced' or v == 'client_enforced' or v == 'not_enforceable',
            row.key .. ' has an unexpected blockEnforcement value: ' .. tostring(v))
    end
end)

t.test('blockEnforcement is a pure function of the feature key -- identical for two different targets', function()
    local f = newFixture()
    local featuresA = requestFeatures(f, 'TARGET-A')
    local featuresB = requestFeatures(f, 'TARGET-B')
    t.equals(findRow(featuresA, 'ThermalVision').blockEnforcement, findRow(featuresB, 'ThermalVision').blockEnforcement)
    t.equals(findRow(featuresA, 'K9Medkit').blockEnforcement, findRow(featuresB, 'K9Medkit').blockEnforcement)
end)

os.exit(t.summary())
