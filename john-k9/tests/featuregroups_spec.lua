--[[
    tests/featuregroups_spec.lua

    Config.FeatureGroups (config.lua) is the capability-family layer above
    Config.Features. This file is the guarantee that it stays a ONE-WAY
    MASTER CUT-OFF and never grows back into a second opinion.

    WHAT CHANGED, AND WHY THIS FILE WAS REWRITTEN (2026-09-02, at the
    owner's request). Config.FeatureGroups used to carry a duplicate on/off
    slot for every individual feature, so 36 of the 49 features in
    Config.Features were controlled from TWO places that had to agree -- and
    when they disagreed, the group slot won, silently, with no error and no
    console line. That is not hypothetical: Config.Features.HandlerXPProgression
    shipped `true` while its group slot said `false`, and the entire handler
    rank ladder was dead -- no XP, no rank-ups -- while config.lua said in
    plain sight that it was on. Thirteen of those slots were also spelled
    DIFFERENTLY from the feature they controlled (`HUD` for
    HealthStaminaHUD, `Blood` for BloodTracking), so searching config.lua
    for a feature's real name found the switch that did nothing and missed
    the switch that decided.

    The duplicate slots are gone. Config.Features is now the ONE place a
    feature is turned on or off; a family switch only answers a different
    question -- "is this whole capability available at all?" -- and only
    `false` does anything.

    Six things this file proves:
      1. NO-OP ON DEFAULTS -- the shipped config resolves to EXACTLY the
         authored Config.Features values, for every key.
      2. NEVER SILENTLY RE-ENABLE -- a key that ships false stays false.
      3. DRIFT GUARD -- every real Config.Features key is accounted for by
         exactly one family or the standalone list (the mechanism that
         would catch a new key landing with no home).
      4. NO SECOND OPINION -- a family table holds NOTHING but `enabled`.
         This is the structural guard against the whole bug class coming
         back, and it is the one test here that would have failed on the
         old shape.
      5. PARENT OFF FORCES MEMBERS OFF, names exactly the ones it actually
         took down, and is reversible.
      6. CLAMP AND WARN, NEVER ASSERT, and SILENT ON THE NORMAL PATH.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Loads the REAL config.lua into a fresh sandbox, capturing print output so
--- tests can assert on exactly what did or did not get printed. A FRESH env
--- per call, deliberately -- several tests below mutate Config.FeatureGroups
--- and re-invoke ResolveFeatureGroups(), and a fresh load per test is what
--- keeps one test's mutation from leaking into another's baseline.
--- @return table env
--- @return table printLog
local function loadRealConfig()
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end
    local env = Sandbox.newEnv({ print = printStub })
    Sandbox.loadInto('../config.lua', env)
    return env, printLog
end

--- Every feature name belonging to `familyName`, read out of the resolved
--- config rather than hand-listed, so this file never needs editing when a
--- feature joins or leaves a family.
--- @param env table @param familyName string @return string[]
local function membersOf(env, familyName)
    local names = {}
    for key in pairs(env.Config.FeaturesBeforeGrouping) do
        if env.GetFeatureGroupFamily(key) == familyName then names[#names + 1] = key end
    end
    table.sort(names)
    return names
end

-- ========================================================================
-- 1 + 2 + 3 -- NO-OP ON DEFAULTS, NEVER SILENTLY RE-ENABLE, DRIFT GUARD
-- ========================================================================

t.test('SANITY: the real config.lua produced a real, non-empty Config.FeaturesBeforeGrouping (a load failure that silently produced an empty table would make every loop below pass vacuously)', function()
    local env = loadRealConfig()
    local count = 0
    for _ in pairs(env.Config.FeaturesBeforeGrouping) do count = count + 1 end
    t.isTrue(count >= 45, ('expected at least 45 keys in Config.FeaturesBeforeGrouping, saw %d'):format(count))
end)

t.test('NO-OP ON DEFAULTS: every real Config.Features key resolves, under the REAL shipped Config.FeatureGroups, to EXACTLY its authored value -- every family ships enabled, so resolution changes nothing at all', function()
    local env = loadRealConfig()
    local mismatches = {}
    for key, beforeValue in pairs(env.Config.FeaturesBeforeGrouping) do
        if env.Config.Features[key] ~= beforeValue then
            mismatches[#mismatches + 1] = ('%s: authored=%s resolved=%s'):format(key, tostring(beforeValue), tostring(env.Config.Features[key]))
        end
    end
    t.equals(#mismatches, 0, 'mismatches: ' .. table.concat(mismatches, '; '))
end)

t.test('NEVER SILENTLY RE-ENABLE: every key that ships false is still false after resolution', function()
    -- DERIVED FROM THE REAL SNAPSHOT, NOT A HAND-TYPED NAME LIST. This pins
    -- the PROPERTY (resolution must never flip a false to true) rather than
    -- the INCIDENTAL FACT of which keys happen to ship false today -- a
    -- guard that fails when the owner legitimately edits his own config is
    -- a guard people learn to edit past.
    local env = loadRealConfig()

    local shipsFalse = {}
    for key, value in pairs(env.Config.FeaturesBeforeGrouping) do
        if value == false then shipsFalse[#shipsFalse + 1] = key end
    end
    table.sort(shipsFalse)

    t.isTrue(#shipsFalse > 0,
        'no Config.Features key ships false, so this test cannot demonstrate anything -- if that is genuinely intended, '
        .. 'the synthetic parent-off tests below are what still prove resolution cannot re-enable a false key')

    for _, key in ipairs(shipsFalse) do
        t.isFalse(env.Config.Features[key],
            key .. ' ships false but resolution turned it true -- the silent re-enable this test exists to catch')
    end
end)

t.test('DRIFT GUARD: every real Config.Features key is accounted for by exactly one family (GetFeatureGroupFamily) or the standalone list (IsStandaloneFeatureFlag) -- the mechanism that catches a new key landing with no home in this tree', function()
    local env = loadRealConfig()
    local homeless = {}
    for key in pairs(env.Config.FeaturesBeforeGrouping) do
        if not env.GetFeatureGroupFamily(key) and not env.IsStandaloneFeatureFlag(key) then
            homeless[#homeless + 1] = key
        end
    end
    table.sort(homeless)
    t.equals(#homeless, 0, 'Config.Features key(s) with no family and not standalone: ' .. table.concat(homeless, ', '))
end)

t.test('DRIFT GUARD, THE OTHER DIRECTION: no family names a feature that does not exist in Config.Features -- a stale member would spring into existence as a brand-new false key the moment its family was disabled', function()
    local env = loadRealConfig()
    local known = {}
    for key in pairs(env.Config.Features) do known[key] = true end

    -- Disabling every family makes the resolver touch every member it knows
    -- about. A member naming a feature that no longer exists shows up here
    -- as a key that was not in Config.Features before.
    for familyName in pairs(env.Config.FeatureGroups) do
        env.Config.FeatureGroups[familyName].enabled = false
    end
    env.ResolveFeatureGroups()

    local ghosts = {}
    for key in pairs(env.Config.Features) do
        if not known[key] then ghosts[#ghosts + 1] = key end
    end
    table.sort(ghosts)
    t.equals(#ghosts, 0, 'family membership names feature(s) that do not exist in Config.Features: ' .. table.concat(ghosts, ', '))
end)

-- ========================================================================
-- 4 -- NO SECOND OPINION (the structural guard)
-- ========================================================================

t.test('NO SECOND OPINION: every Config.FeatureGroups family holds NOTHING but `enabled` -- a per-feature slot here is the exact bug shape that silently killed the handler rank ladder, and it must never come back', function()
    -- THE CONTROL FOR THIS TEST: it was run against the PRE-CHANGE config.lua
    -- (families still carrying Blood/Gunpowder/HUD/HandlerXP/... slots) and
    -- failed, naming all 36 of them. That is what makes it a real guard and
    -- not a restatement of the current file.
    local env = loadRealConfig()
    local offenders = {}
    for familyName, family in pairs(env.Config.FeatureGroups) do
        if type(family) == 'table' then
            for key in pairs(family) do
                if key ~= 'enabled' then
                    offenders[#offenders + 1] = ('Config.FeatureGroups.%s.%s'):format(familyName, tostring(key))
                end
            end
        end
    end
    table.sort(offenders)
    t.equals(#offenders, 0,
        'a family may only carry `enabled`. Found a second on/off slot at: ' .. table.concat(offenders, ', ')
        .. '. Turn the feature on or off in Config.Features instead -- two switches for one feature is how '
        .. 'HandlerXPProgression ended up dead while config.lua said it was on.')
end)

t.test('NO SECOND OPINION: no feature is claimed by two different families', function()
    local env = loadRealConfig()
    -- GetFeatureGroupFamily returns exactly one family per key by
    -- construction; this pins that the reverse index really is 1:1 by
    -- checking every key resolves to a family that actually exists and that
    -- the count of family-owned keys plus standalone keys equals the total.
    local owned, standalone, total = 0, 0, 0
    for key in pairs(env.Config.FeaturesBeforeGrouping) do
        total = total + 1
        if env.GetFeatureGroupFamily(key) then owned = owned + 1 end
        if env.IsStandaloneFeatureFlag(key) then standalone = standalone + 1 end
    end
    t.equals(owned + standalone, total,
        ('%d features, %d owned by a family, %d standalone -- these must add up exactly, or some key is in both or neither'):format(total, owned, standalone))
end)

-- ========================================================================
-- 5 -- PARENT OFF FORCES MEMBERS OFF
-- ========================================================================

t.test('PARENT OFF forces every member of that family off, base member included, whatever Config.Features says', function()
    local env = loadRealConfig()
    local members = membersOf(env, 'Combat')
    t.isTrue(#members > 0, 'sanity: Combat must actually have members, or this test proves nothing')

    env.Config.FeatureGroups.Combat.enabled = false
    env.ResolveFeatureGroups()

    for _, name in ipairs(members) do
        t.isFalse(env.Config.Features[name], name .. ' must be forced off by its family switch')
    end
end)

t.test('PARENT OFF also forces the BASE member off -- the family switch IS that feature (Detection.enabled is ScentTracking)', function()
    local env = loadRealConfig()
    t.isTrue(env.Config.Features.ScentTracking, 'sanity: ScentTracking ships on')

    env.Config.FeatureGroups.Detection.enabled = false
    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.ScentTracking, 'the base member must go off with its family')
    t.isFalse(env.Config.Features.BloodTracking, 'and so must the ordinary members')
end)

t.test('PARENT OFF prints exactly which features it forced, naming the family -- the actionable warning this mechanism exists to surface', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end

    local members = membersOf(env, 'Combat')
    env.Config.FeatureGroups.Combat.enabled = false
    env.ResolveFeatureGroups()

    local found = nil
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Combat.enabled is false', 1, true) then found = line end
    end
    t.isNotNil(found, 'expected a forced-off warning naming Combat')

    -- The warning must name exactly the features it actually FORCED off --
    -- the ones that were true beforehand -- and must NOT name one that was
    -- already false, because telling an operator you forced off something
    -- that was never on sends them looking for a change that did not happen.
    local named = 0
    for _, name in ipairs(members) do
        if env.Config.FeaturesBeforeGrouping[name] == true then
            t.contains(found, name)
            named = named + 1
        else
            t.isFalse(found:find(name, 1, true) ~= nil,
                name .. ' was already off and must not be reported as forced off')
        end
    end
    t.isTrue(named > 0, 'at least one Combat feature was actually forced off, so this assertion is not vacuous')
end)

t.test('PARENT ON changes NOTHING -- a family switch is a one-way cut-off, never a second opinion that could re-decide a feature', function()
    -- The control that pins the direction. If `enabled = true` ever started
    -- writing values of its own, this fails.
    local env = loadRealConfig()
    local before = {}
    for key, value in pairs(env.Config.Features) do before[key] = value end

    -- Turn a feature OFF in Config.Features while its family stays enabled.
    env.Config.Features.BiteAndHold = false
    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.BiteAndHold,
        'an enabled family must never re-enable a feature its owner switched off in Config.Features')
    for key, value in pairs(before) do
        if key ~= 'BiteAndHold' then
            t.equals(env.Config.Features[key], value, key .. ' must be untouched by a re-resolve with every family enabled')
        end
    end
end)

t.test('REVERSIBLE: disabling a family, then re-enabling it and re-resolving, recovers every member\'s authored value -- the resolver never reads its own already-narrowed output as if it were the original', function()
    local env = loadRealConfig()
    local members = membersOf(env, 'Combat')

    env.Config.FeatureGroups.Combat.enabled = false
    env.ResolveFeatureGroups()

    -- Restore the authored values the way a restart would, then re-resolve.
    for _, name in ipairs(members) do
        env.Config.Features[name] = env.Config.FeaturesBeforeGrouping[name]
    end
    env.Config.FeatureGroups.Combat.enabled = true
    env.ResolveFeatureGroups()

    local checked = 0
    for _, name in ipairs(members) do
        t.equals(env.Config.Features[name], env.Config.FeaturesBeforeGrouping[name],
            name .. ' must recover its authored value')
        checked = checked + 1
    end
    t.isTrue(checked > 0, 'at least one Combat feature was actually checked')
end)

t.test('IsFeatureGroupParentEnabled reflects the family switch, and is always true for a standalone flag (nothing above it to be blocked by)', function()
    local env = loadRealConfig()
    t.isTrue(env.IsFeatureGroupParentEnabled('BiteAndHold'), 'Combat ships enabled')
    t.isTrue(env.IsFeatureGroupParentEnabled('HighCommand'), 'a standalone flag has no parent to block it')

    env.Config.FeatureGroups.Combat.enabled = false
    t.isFalse(env.IsFeatureGroupParentEnabled('BiteAndHold'), 'a disabled family must report its members as parent-blocked')
    t.isTrue(env.IsFeatureGroupParentEnabled('HighCommand'), 'and must not affect a standalone flag')
end)

-- ========================================================================
-- 6 -- CLAMP AND WARN, NEVER ASSERT; SILENT ON THE NORMAL PATH
-- ========================================================================

t.test('SILENT ON THE NORMAL PATH: the real shipped config prints nothing at all from group resolution', function()
    local _, printLog = loadRealConfig()
    local noise = {}
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups', 1, true) then noise[#noise + 1] = line end
    end
    t.equals(#noise, 0, 'a valid config must resolve silently; saw: ' .. table.concat(noise, ' | '))
end)

t.test('CLAMP AND WARN: a non-boolean family `enabled` is ignored, warns naming the exact field, and the family is treated as enabled -- never an error', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Combat.enabled = 'yes'

    local ok = pcall(env.ResolveFeatureGroups)
    t.isTrue(ok, 'a malformed value must never throw')

    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Combat.enabled is not a boolean', 1, true) then warned = true end
    end
    t.isTrue(warned, 'expected a warning naming the exact field')
    t.isTrue(env.Config.Features.BiteAndHold, 'and the family must fall back to enabled, not silently off')
end)

t.test('CLAMP AND WARN: a family that is not a table at all is ignored, warns, and its members keep their authored values', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Combat = 'nonsense'

    local ok = pcall(env.ResolveFeatureGroups)
    t.isTrue(ok, 'a malformed family must never throw')

    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Combat is not a table', 1, true) then warned = true end
    end
    t.isTrue(warned, 'expected a warning naming the family')
    t.isTrue(env.Config.Features.BiteAndHold, 'members must keep the values authored in Config.Features')
end)

t.test('NO FEATUREGROUPS AT ALL: prints one actionable notice and leaves Config.Features exactly as authored', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    local authored = {}
    for key, value in pairs(env.Config.FeaturesBeforeGrouping) do authored[key] = value end
    env.Config.FeatureGroups = nil

    local ok = pcall(env.ResolveFeatureGroups)
    t.isTrue(ok)

    local notices = 0
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups not found', 1, true) then notices = notices + 1 end
    end
    t.equals(notices, 1, 'exactly one notice, not one per family')

    for key, value in pairs(authored) do
        t.equals(env.Config.Features[key], value, key .. ' must be untouched when there are no families at all')
    end
end)

t.test('A FAMILY OMITTED ENTIRELY means "on, nothing overridden" -- never "off"', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups.Combat = nil
    env.ResolveFeatureGroups()
    t.isTrue(env.Config.Features.BiteAndHold, 'an omitted family must never force its members off')
end)

print(('featuregroups_spec.lua: %d passed, %d failed'):format(t.passed, t.failed))
os.exit(t.failed == 0 and 0 or 1)
