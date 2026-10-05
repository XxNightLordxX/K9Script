--[[
    tests/runtimefeaturetiers_spec.lua

    DRIFT GUARD, and only that -- see server/runtimecontrol.lua's own header
    "UPDATED 2026-08-26" for the incident this spec exists to make
    unrepeatable: eleven Config.Features keys (CameraFeedPiP, FindAlerts,
    K9DownDispatch, K9EquipmentShop, K9Leaderboard, PursuitSprint,
    ResourceAutoDetect, SARCalls, ScentLineup, ScentTrailHunt, TrainingMode)
    shipped in config.lua with NO matching entry in that file's own
    FEATURE_TIERS table -- silently resolving to tier = 'unaudited' for
    months, with nothing anywhere printing a word about it. This spec loads
    the REAL, unmodified config.lua (every one of its 56 Config.Features
    keys, verbatim -- never a fabricated/partial stand-in list, which would
    defeat the entire point) alongside the REAL, unmodified
    server/runtimecontrol.lua, and fails the whole suite the moment a
    56th/57th/... key ships without a matching FEATURE_TIERS entry ever
    again.

    WHY THIS GOES THROUGH THE REAL runtimeListFeatures CALLBACK, NOT A
    DIRECT REQUIRE OF FEATURE_TIERS: FEATURE_TIERS and GetFeatureTier are
    both `local` to server/runtimecontrol.lua (see tests/fixtures/
    sandbox.lua's own header on this exact limitation: "a `local function
    Foo()` in the production file is still only reachable from code inside
    that same file... a spec... does so the same way a real caller would:
    by invoking whatever resource-global entry point... the production
    file itself already wires that local function into"). runtimeListFeatures
    is exactly that entry point -- it iterates `pairs(Config.Features)`
    directly (server/runtimecontrol.lua's own real, unmodified loop) and
    reports `tier = GetFeatureTier(name)` for every single one, so reading
    its response IS reading the real FEATURE_TIERS table's coverage,
    through the same door the tablet itself uses -- no second, driftable
    copy of either list is transcribed into this file.

    ONE DIRECTION ONLY, DELIBERATELY: this only catches "a Config.Features
    key with no FEATURE_TIERS entry" (tier = 'unaudited'), which is the
    exact, one-directional gap server/runtimecontrol.lua's own header
    confirms this resource actually had ("Nothing is in FEATURE_TIERS but
    missing from Config.Features") and the only direction with a live
    behavioral consequence (an orphaned FEATURE_TIERS entry for a feature
    that no longer exists in Config.Features can never be reached by
    GetFeatureTier at all -- runtimeSetFeature already refuses any `name`
    not present in Config.Features before tier is ever consulted -- so it
    is dead weight, not a hazard, and not what this spec is built to catch).
    Checking that reverse direction from outside this file is not reachable
    without exporting FEATURE_TIERS' own key list, which server/
    runtimecontrol.lua's header explicitly declines to do ("THIS FILE
    exposes no resource-global functions") -- not done here for one test.

    NO MYSQL STUB NEEDED: this spec sets `Config.Database.enabled = false`
    (real config.lua defaults it to `true`) so server/datastore.lua's own
    DatabaseEnabled() check routes every K9Store call through its in-memory
    backend instead of MySQL.query.await -- this spec never calls a
    mutating callback (only the read-only runtimeListFeatures), so there is
    nothing for a real or fake database to persist either way.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local HC_SOURCE = 100

--- Boots a fresh sandbox against the REAL config.lua + REAL
--- server/cooldowns.lua + REAL server/datastore.lua + REAL
--- server/runtimecontrol.lua -- no fixture-authored Config.Features list of
--- any kind, so there is no way for this spec's own setup to accidentally
--- narrow the very list it exists to check in full.
--- @return table fixture -- { env, callbacks, printedLines }
local function boot()
    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = function() end,
        exports                = { qbx_core = { GetPlayer = function() return nil end } },
        IsHighCommand          = function() return true end,
    })

    -- REAL config.lua -- every one of its current Config.Features keys,
    -- verbatim. This is the entire point of this spec: it must see exactly
    -- what a real server would ship, not a curated subset.
    Sandbox.loadInto('../config.lua', env)

    -- Force the in-memory K9Store backend -- see this file's header "NO
    -- MYSQL STUB NEEDED".
    env.Config.Database = env.Config.Database or {}
    env.Config.Database.enabled = false

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return { env = env, callbacks = callbacks, printedLines = printedLines }
end

t.test('LOAD-BEARING DRIFT GUARD: every real config.lua Config.Features key has a non-"unaudited" tier in server/runtimecontrol.lua\'s FEATURE_TIERS', function()
    local f = boot()

    local result = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    t.isTrue(result.ok, 'runtimeListFeatures must succeed for a high-command caller')

    local rowByName = {}
    for _, row in ipairs(result.features) do
        rowByName[row.name] = row
    end

    local problems = {}
    local totalConfigFeatures = 0
    for name in pairs(f.env.Config.Features) do
        totalConfigFeatures = totalConfigFeatures + 1
        local row = rowByName[name]
        if not row then
            -- Should be structurally impossible: runtimeListFeatures's own
            -- loop iterates pairs(Config.Features) directly, so every key
            -- this spec's own loop above just saw, that callback saw too.
            -- Kept as a real, checked assertion (not a comment) rather than
            -- an assumption, matching this codebase's own "a grep count is
            -- a hypothesis, not a result" discipline extended to this case.
            problems[#problems + 1] = name .. ' (MISSING FROM runtimeListFeatures ENTIRELY -- that callback\'s own loop iterates Config.Features directly; this should never happen and points at a bug in that loop, not merely a missing tier)'
        elseif row.tier == 'unaudited' then
            problems[#problems + 1] = name
        end
    end

    if #problems > 0 then
        table.sort(problems)
        error((
            '%d feature(s) in Config.Features (config.lua) have NO tier classification in FEATURE_TIERS ' ..
            '(server/runtimecontrol.lua): %s.\n\n' ..
            'FIX THIS BY: reading that feature\'s actual server/client implementation -- does its handler ' ..
            're-check Config.Features.<Name> live on every call (tier = \'live\'), only inside an ' ..
            '`AddEventHandler(\'onResourceStart\', ...)` registration (tier = \'onstart\'), behind a bare ' ..
            '`if not Config.Features.<Name> then return end` at that file\'s own raw top level (tier = ' ..
            '\'rawtoplevel\'), nowhere in any server/*.lua file at all (tier = \'clientonly\'), or does it ' ..
            'gate the very authorization check this control system itself depends on (tier = \'protected\')? ' ..
            '-- then add FEATURE_TIERS.<Name> = { tier = \'...\' } to server/runtimecontrol.lua, in the ' ..
            'matching tier group, with a note citing the exact line(s) of evidence, the same way every one ' ..
            'of the other entries in that table already does. Do NOT silence this by widening what this ' ..
            'spec accepts, and do NOT "fix" it by relaxing runtimeSetFeature\'s own refusal of an ' ..
            '\'unaudited\' tier -- that refusal, and this spec, both exist specifically because eleven ' ..
            'features shipped once already without anyone doing this classification step.'
        ):format(#problems, table.concat(problems, ', ')), 0)
    end

    -- Sanity: this really did exercise the full, real config.lua feature
    -- list, not an accidentally-empty or truncated one (a loadfile typo
    -- that silently produced an empty Config.Features table would
    -- otherwise make the loop above pass vacuously and this spec would
    -- prove nothing).
    -- FLOOR LOWERED 2026-09-02: twelve features were removed at the owner's request (61 -> 49 Config.Features keys), so the old floor could never be met again. It stays well above zero because its job is to catch an extraction pattern going stale and silently checking nothing -- not to pin the catalogue size.
    t.isTrue(totalConfigFeatures >= 45, ('sanity: only saw %d Config.Features key(s) -- expected at least 45; config.lua may have failed to load correctly for this spec'):format(totalConfigFeatures))
end)

t.test('a still-genuinely-unaudited feature (this spec\'s own fixture, never server/runtimecontrol.lua\'s real FEATURE_TIERS) prints a named boot warning -- confirms the warning mechanism itself works against the real file, not just the test fixture in runtimecontrol_spec.lua', function()
    -- Deliberately NOT using the real config.lua for this one case -- this
    -- test's own point is to prove the WARNING MECHANISM fires against the
    -- real, unmodified server/runtimecontrol.lua when handed a name that
    -- really does have no FEATURE_TIERS entry, which the real config.lua
    -- (now fully classified) can no longer exercise on its own.
    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetGameTimer           = function() return 0 end,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = function() end,
        exports                = { qbx_core = { GetPlayer = function() return nil end } },
        IsHighCommand          = function() return true end,
        Config                 = { Features = { RuntimeFeatureControl = true, HighCommand = true, TotallyHypotheticalFeature58 = true }, Database = { enabled = false }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } },
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('john-k9') end

    local bootWarned = false
    for _, line in ipairs(printedLines) do
        if line:find('WARNING', 1, true) and line:find('TotallyHypotheticalFeature58', 1, true) then bootWarned = true end
    end
    t.isTrue(bootWarned, 'boot-time enumeration warning must name the unclassified feature')

    local result = callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'TotallyHypotheticalFeature58', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'unaudited_feature')
end)

-- INVERTED ON PURPOSE (2026-08-26). This test used to REQUIRE a disclosure
-- note on BiteAndHold/NonLethalTakedown/PropDragging, because server/combat.lua's
-- auto-release maintenance thread and its K9-position-history sampling thread
-- each only STARTED if one of those flags was already
-- true when that file loaded -- so flipping one on live, from all-four-off at
-- boot, created holds that nothing would ever time out. That gap is fixed:
-- both threads now start unconditionally and re-check their governing flag(s)
-- fresh every tick. The honest disclosure has therefore become a LIE, and a
-- note that describes a gap which no longer exists is worse than no note --
-- it tells an operator not to trust a safety net that now works.
--
-- So this test now asserts the OPPOSITE of what it once did. If you are here
-- because you spotted three bare `tier = 'live'` entries and thought the
-- disclosure had been dropped by accident: it was not. Read
-- tests/combat_spec.lua's two "LIVE-FLIP FIX" tests -- they are the real
-- regression coverage proving a hold created after a live flip still
-- auto-releases, and that position-history sampling starts within one
-- interval of that flip. Re-adding a note here would need those two tests to
-- be failing first.
t.test('RESOLVED PARTIAL LIVENESS: BiteAndHold/NonLethalTakedown/PropDragging are tier = \'live\' with NO caveat note -- both the request-time gate and the auto-release maintenance thread are genuinely live now', function()
    local f = boot()
    local result = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    t.isTrue(result.ok)

    local rowByName = {}
    for _, row in ipairs(result.features) do
        rowByName[row.name] = row
    end

    for _, name in ipairs({ 'BiteAndHold', 'NonLethalTakedown', 'PropDragging' }) do
        local row = rowByName[name]
        t.isNotNil(row, name .. ' must be present in config.lua\'s Config.Features')
        t.equals(row.tier, 'live', name .. ' -- the request-time gate (ValidateCombatRequest) really is checked fresh every call')
        t.isTrue(row.note == nil, name .. ' must carry NO note: the maintenance-thread gap it used to disclose is fixed (server/combat.lua starts both threads unconditionally), and a stale caveat would tell an operator not to trust an auto-release that now works')
    end
end)

os.exit(t.summary())
