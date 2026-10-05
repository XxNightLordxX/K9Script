--[[
    tests/customizationregistry_spec.lua

    DRIFT GUARD for the owner's own requirement, restated verbatim: "I want
    high command to have even more control over all the features and sub
    features" -- every feature toggleable globally (Config.Features), every
    feature blockable for one specific person ('block.<Name>' via
    server/permissions.lua), and a subset tunable/actionable from the K9
    Command Tablet. The risk this file exists to catch is not that any of
    this is broken TODAY -- it is that someone adds feature #57 next month,
    wires it into ONE of these registries, and it silently becomes the one
    feature nobody can control, with no error, no warning, and no test
    failure, until an operator discovers it by hand months later.

    ======================================================================
    WHAT tests/runtimefeaturetiers_spec.lua ALREADY COVERS (read in full
    before writing this file -- NOT duplicated here):
      - Every real config.lua Config.Features key has a non-'unaudited'
        tier in server/runtimecontrol.lua's FEATURE_TIERS table (the
        Config.Features -> FEATURE_TIERS direction), via the real
        `john-k9:server:runtimeListFeatures` callback against the real,
        unmodified config.lua + server/runtimecontrol.lua.
      - That spec's own header explicitly declines to check the REVERSE
        direction (a FEATURE_TIERS entry with no matching Config.Features
        key) because FEATURE_TIERS is `local` and the real
        runtimeListFeatures callback only ever iterates
        `pairs(Config.Features)`, so an orphaned FEATURE_TIERS entry can
        never surface through that door. Section 2 below closes that
        specific, previously-declined gap using the same raw-source-text
        extraction technique tests/schemaconvergence_spec.lua and
        tests/tabletlocalization_spec.lua already established in this suite
        for reading a `local` table's key set without executing/exporting
        it.

    WHAT tests/runtimecontrol_spec.lua's SECTION 10 ALREADY COVERS (also not
    duplicated here):
      - Every TUNABLE_REGISTRY entry's `path` resolves against the REAL
        config.lua, and the shipped default falls inside that entry's own
        declared [min, max] (including the integer constraint). That spec's
        own sanity floor (`>= 90`) already guards against a truncated read.
      - This file adds NOTHING for TUNABLE_REGISTRY -- it is already fully
        pinned, by the file whose job that is.

    WHAT THIS FILE ADDS, NOT COVERED ANYWHERE ELSE IN THIS SUITE AS OF THIS
    PASS (grepped for 'ActionableFeatures'/'RequireGrant' across every
    *_spec.lua before writing this -- both are conspicuously test-free
    against the REAL config.lua; every existing reference is either inside
    config.lua/server/tablet.lua themselves, or inside another spec's own
    FIXTURE Config table, never the real, shipped one):
      1. Config.CommandTablet.ActionableFeatures keys are all real
         Config.Features keys (Section 1).
      2. server/runtimecontrol.lua's FEATURE_TIERS has no entry for a
         feature that no longer exists in Config.Features (Section 2 --
         the declined reverse direction above).
      3. Config.FeatureControl.RequireGrant keys are all real Config.Features
         keys (Section 3).
      4. Every Config.Features key classified `tier = 'clientonly'` (no
         server-side enforcement point exists or could ever exist for it)
         has a matching per-person block path in
         client/featureblocks.lua's CLIENT_ENFORCED_FEATURES set -- the
         ONLY mechanism by which one of these twelve can be blocked for one
         person at all -- and vice versa, no stale/orphaned entry in that
         set names a feature that is no longer clientonly (Section 4).
      5. THE HEADLINE CHECK: every Config.Features key that is NOT
         'clientonly' (handled by Section 4 instead) has SOME per-person
         block enforcement point somewhere in server/*.lua -- either a
         literal `HasPermission(citizenid, 'block.<Name>')` call, or
         membership in a small, explicitly disclosed, hand-verified list of
         features covered by a shared dynamic-dispatch permission checker
         (server/wellbeing.lua, server/search.lua, server/combat.lua,
         server/tracking.lua each check `HasPermission(citizenid, 'block.'
         .. featureName)` for more than one feature through one function) --
         UNLESS the feature is named in this file's own
         STRUCTURALLY_EXEMPT_FROM_PERSON_BLOCK allowlist, each entry
         individually commented with the real, existing documentation that
         justifies the exemption (Section 5). This is the concrete
         "no feature is entirely uncontrollable" invariant the task asked
         for, scoped to the one control axis (per-person block) that has no
         other dedicated spec in this suite already pinning it.

    WHY TEXT-PATTERN EXTRACTION, NOT A LOADED/EXECUTED FILE, FOR SECTIONS
    2/4/5's SOURCE TABLES: FEATURE_TIERS (server/runtimecontrol.lua) and
    CLIENT_ENFORCED_FEATURES (client/featureblocks.lua) are both `local` to
    their own file with no resource-global accessor exposed for their raw
    key SET (only per-name lookups reachable via a real callback, which is
    what Section 4's tier-map below actually uses instead, being reachable
    that way) -- and client/featureblocks.lua cannot be loaded into this
    suite's server-side sandbox at all (it calls client-only natives/
    RegisterNetEvent with a `source` global this harness does not model).
    Matches this suite's own established precedent
    (tests/schemaconvergence_spec.lua's SQL table-name extraction,
    tests/tabletlocalization_spec.lua's html/tablet.js DEFAULT_STRINGS
    extraction) for reading a table's key set straight out of source text
    when execution is not an option -- narrow pattern matching against each
    file's own real, already-established text shape, not a general parser.

    NO LONGER A HAND-MAINTAINED FILE LIST (2026-08-26). Section 5's literal
    `block.<Name>` scan used to read a fixed, hand-typed list of
    server/*.lua filenames, with a disclosed tradeoff: "a brand-new
    server/*.lua file that adds its own `block.<Name>` check must be added
    to that list in the same change, or this spec will not know to look at
    it and will report a false gap."

    That tradeoff came due. server/vehicle.lua was added, vehicle entry
    moved from tier='clientonly' to tier='live' because it gained real
    server-side enforcement, this spec correctly demanded a per-person
    block path for it -- and then could not see the one that had just been
    written, because the new file was not in the hand-typed list. The
    check reported a gap that did not exist, which is the failure mode that
    gets a test deleted rather than fixed.

    The list is now DERIVED from fxmanifest.lua's own `server_scripts`
    block, read as text. That file is the single authoritative statement of
    which server files this resource actually loads -- a server file missing
    from it does not run at all, so it cannot be a source of enforcement
    this scan needs to see. Same "read a table's key set straight out of
    source text when execution is not an option" precedent as everything
    else in this file. A floor assertion below guards against the pattern
    silently matching nothing and making Section 5 pass vacuously, which
    would be worse than the false gap it replaces.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param path string
--- @return string
local function ReadFile(path)
    local handle, err = io.open(path, 'r')
    if not handle then
        error(('could not open %s: %s'):format(path, tostring(err)), 2)
    end
    local text = handle:read('a')
    handle:close()
    return text
end

-- ----------------------------------------------------------------------
-- Loads the REAL config.lua only -- no server/*.lua production file, no
-- MySQL/cooldowns/datastore stubbing needed for Sections 1 and 3, which
-- read nothing but plain Config data.
-- ----------------------------------------------------------------------
--- @return table Config
local function loadRealConfig()
    local env = Sandbox.newEnv({})
    Sandbox.loadInto('../config.lua', env)
    return env.Config
end

-- ============================================================================
-- SECTION 1 -- Config.CommandTablet.ActionableFeatures keys are all real
-- Config.Features keys.
-- ============================================================================

t.test('every Config.CommandTablet.ActionableFeatures key is a real Config.Features key (config.lua)', function()
    local Config = loadRealConfig()
    assert(type(Config.CommandTablet) == 'table' and type(Config.CommandTablet.ActionableFeatures) == 'table',
        'Config.CommandTablet.ActionableFeatures not found or not a table -- config.lua must have changed shape')
    assert(type(Config.Features) == 'table', 'Config.Features not found -- config.lua must have changed shape')

    local orphans = {}
    for key in pairs(Config.CommandTablet.ActionableFeatures) do
        if Config.Features[key] == nil then
            orphans[#orphans + 1] = key
        end
    end

    if #orphans > 0 then
        table.sort(orphans)
        error((
            'Config.CommandTablet.ActionableFeatures (config.lua) names %d key(s) that are NOT real ' ..
            'Config.Features keys: %s.\n\nFIX THIS BY: either the feature was renamed/removed in ' ..
            'Config.Features and this allowlist entry was never updated to match (delete the stale ' ..
            'entry here), or it is a typo of a real key (correct the spelling). An entry here for a ' ..
            'name that does not exist in Config.Features gives high command a tablet button that can ' ..
            'never resolve to anything real.'
        ):format(#orphans, table.concat(orphans, ', ')), 0)
    end

    -- Sanity floor matching config.lua's own comment ("These 20 are exactly
    -- the features the tablet actually knows how to fire today") -- guards
    -- against a loadfile issue silently producing an empty table, which
    -- would make the loop above pass vacuously.
    local count = 0
    for _ in pairs(Config.CommandTablet.ActionableFeatures) do count = count + 1 end
    -- FLOOR LOWERED 2026-09-02: twelve features were removed at the owner's request (61 -> 49 Config.Features keys), so the old floor could never be met again. It stays well above zero because its job is to catch an extraction pattern going stale and silently checking nothing -- not to pin the catalogue size.
    t.isTrue(count >= 15, ('sanity: only saw %d ActionableFeatures key(s) -- expected at least 15'):format(count))
end)

-- ============================================================================
-- SECTION 2 -- server/runtimecontrol.lua's FEATURE_TIERS has no entry for a
-- feature that no longer exists in Config.Features (the direction
-- tests/runtimefeaturetiers_spec.lua's own header explicitly declines to
-- check, for the reason quoted in this file's own header above).
-- ============================================================================

--- Extracts every key of the `local FEATURE_TIERS = { ... }` table literal in
--- server/runtimecontrol.lua by raw text pattern -- see this file's header
--- "WHY TEXT-PATTERN EXTRACTION". Every real entry in that table is written
--- `Name = { tier = '...' [, note = '...'] },` (confirmed by direct read of
--- the whole table before writing this pattern) -- distinctive enough not to
--- accidentally match `local function GetFeatureTier(name)` or any other
--- shape in this file.
--- @param text string
--- @return table<string, boolean> set
local function ExtractFeatureTiersKeys(text)
    local startPos = text:find('local FEATURE_TIERS = {', 1, true)
    assert(startPos, 'local FEATURE_TIERS = { not found in server/runtimecontrol.lua -- this file must have changed shape')
    local endPos = text:find('\nlocal function GetFeatureTier', startPos, true)
    assert(endPos, 'local function GetFeatureTier(...) not found after FEATURE_TIERS -- this file must have changed shape')
    local block = text:sub(startPos, endPos)

    local set = {}
    for key in block:gmatch("(%u%w*)%s*=%s*{%s*tier%s*=") do
        set[key] = true
    end
    return set
end

t.test('LOAD-BEARING DRIFT GUARD: every server/runtimecontrol.lua FEATURE_TIERS entry names a key that still exists in the real Config.Features (no stale/orphaned tier entry for a renamed or removed feature)', function()
    local Config = loadRealConfig()
    local runtimeControlText = ReadFile('../server/runtimecontrol.lua')
    local tierKeys = ExtractFeatureTiersKeys(runtimeControlText)

    local orphans = {}
    for key in pairs(tierKeys) do
        if Config.Features[key] == nil then
            orphans[#orphans + 1] = key
        end
    end

    if #orphans > 0 then
        table.sort(orphans)
        error((
            '%d FEATURE_TIERS entr(ies) in server/runtimecontrol.lua name a key that is NOT in the real ' ..
            'Config.Features (config.lua): %s.\n\nThis is dead weight rather than a live hazard (' ..
            'GetFeatureTier can never be reached for a name runtimeSetFeature already refuses before tier ' ..
            'is ever consulted -- see server/runtimecontrol.lua\'s own header), but it is still real drift: ' ..
            'a feature was renamed or removed in config.lua and its FEATURE_TIERS entry (and this file\'s ' ..
            'own hand-written evidence comment for it) was never deleted to match. FIX THIS BY: deleting ' ..
            'the stale FEATURE_TIERS.<Name> entry, or renaming it to match config.lua\'s current key if this ' ..
            'was a rename rather than a removal.'
        ):format(#orphans, table.concat(orphans, ', ')), 0)
    end

    -- Sanity floor -- guards against the extraction pattern silently
    -- matching nothing at all (a comment reformat, a rename of the local).
    local count = 0
    for _ in pairs(tierKeys) do count = count + 1 end
    t.isTrue(count >= 45, ('sanity: only extracted %d FEATURE_TIERS key(s) from server/runtimecontrol.lua -- expected at least 45; the extraction pattern may be out of date'):format(count))
end)

-- ============================================================================
-- SECTION 3 -- Config.FeatureControl.RequireGrant keys are all real
-- Config.Features keys.
-- ============================================================================

t.test('every Config.FeatureControl.RequireGrant key is a real Config.Features key (config.lua)', function()
    local Config = loadRealConfig()
    assert(type(Config.FeatureControl) == 'table' and type(Config.FeatureControl.RequireGrant) == 'table',
        'Config.FeatureControl.RequireGrant not found or not a table -- config.lua must have changed shape')

    local orphans = {}
    for key in pairs(Config.FeatureControl.RequireGrant) do
        if Config.Features[key] == nil then
            orphans[#orphans + 1] = key
        end
    end

    if #orphans > 0 then
        table.sort(orphans)
        error((
            'Config.FeatureControl.RequireGrant (config.lua) names %d key(s) that are NOT real ' ..
            'Config.Features keys: %s.\n\nEvery consuming gate\'s own step-3 check (e.g. ' ..
            'server/tracking.lua\'s IsTrackingFeaturePermittedForCitizenId) only ever reads ' ..
            '"RequireGrant[featureName] == true" for a featureName it was already called with by its own ' ..
            'feature file -- a stale/typo\'d entry here is silently never consulted by anything, which is ' ..
            'exactly the kind of quiet, undetected gap this spec exists to catch. FIX THIS BY: deleting the ' ..
            'stale entry, or correcting the spelling to match a real Config.Features key.'
        ):format(#orphans, table.concat(orphans, ', ')), 0)
    end
end)

-- ============================================================================
-- SECTION 4 -- every 'clientonly'-tier feature (no server-side enforcement
-- point exists or could ever exist) has a matching per-person block path in
-- client/featureblocks.lua's CLIENT_ENFORCED_FEATURES set, and vice versa.
-- ============================================================================

--- Boots the REAL config.lua + server/cooldowns.lua + server/datastore.lua +
--- server/runtimecontrol.lua, exactly matching tests/runtimecontrol_spec.lua's
--- own `bootAgainstRealConfig()` (Section 10) -- duplicated here rather than
--- shared because that function is itself `local` to that spec file with no
--- shared fixture module of its own (matches this codebase's own accepted
--- "each spec keeps its own tiny copy of a genuinely small setup" convention
--- -- see server/permissions.lua's IsDuplicateKeyError doc comment for the
--- identical reasoning applied to production code).
--- @return table<string, string> tierByName
local function RealFeatureTierMap()
    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetGameTimer           = function() return 0 end,
        print                  = function() end,
        lib                    = lib,
        TriggerClientEvent     = function() end,
        exports                = { qbx_core = { GetPlayer = function() return nil end } },
        IsHighCommand          = function() return true end,
    })

    Sandbox.loadInto('../config.lua', env)
    env.Config.Database = env.Config.Database or {}
    env.Config.Database.enabled = false -- route K9Store through its in-memory backend -- no real DB needed for a read-only ListFeatures call

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('john-k9') end

    local result = callbacks['john-k9:server:runtimeListFeatures'](100)
    assert(result.ok, 'runtimeListFeatures must succeed for a high-command caller')

    local tierByName = {}
    for _, row in ipairs(result.features) do
        tierByName[row.name] = row.tier
    end
    return tierByName
end

--- Extracts every key of the `local CLIENT_ENFORCED_FEATURES = { ... }` table
--- literal in client/featureblocks.lua -- see this file's header "WHY
--- TEXT-PATTERN EXTRACTION".
--- @param text string
--- @return table<string, boolean> set
local function ExtractClientEnforcedFeatures(text)
    local startPos = text:find('local CLIENT_ENFORCED_FEATURES = {', 1, true)
    assert(startPos, 'local CLIENT_ENFORCED_FEATURES = { not found in client/featureblocks.lua -- this file must have changed shape, or been removed/renamed (client/featureblocks.lua is wired into fxmanifest.lua\'s client_scripts list -- confirmed by reading it -- and its source remains the intended source of truth for this list)')
    local endPos = text:find('\n}', startPos, true)
    assert(endPos, 'no closing "}" found for CLIENT_ENFORCED_FEATURES in client/featureblocks.lua')
    local block = text:sub(startPos, endPos)

    local set = {}
    for key in block:gmatch('(%u%w*)%s*=%s*true') do
        set[key] = true
    end
    return set
end

t.test('LOAD-BEARING DRIFT GUARD: every tier=clientonly Config.Features key has a matching entry in client/featureblocks.lua\'s CLIENT_ENFORCED_FEATURES (its only possible per-person block path), and vice versa', function()
    local tierByName = RealFeatureTierMap()
    local clientEnforced = ExtractClientEnforcedFeatures(ReadFile('../client/featureblocks.lua'))

    local clientOnlySet = {}
    for name, tier in pairs(tierByName) do
        if tier == 'clientonly' then clientOnlySet[name] = true end
    end

    local missingFromClientEnforced = {}
    for name in pairs(clientOnlySet) do
        if not clientEnforced[name] then
            missingFromClientEnforced[#missingFromClientEnforced + 1] = name
        end
    end

    local orphanedInClientEnforced = {}
    for name in pairs(clientEnforced) do
        if not clientOnlySet[name] then
            orphanedInClientEnforced[#orphanedInClientEnforced + 1] = name
        end
    end

    if #missingFromClientEnforced > 0 then
        table.sort(missingFromClientEnforced)
        error((
            '%d feature(s) are tier=\'clientonly\' in server/runtimecontrol.lua\'s FEATURE_TIERS (meaning ' ..
            'NO server-side enforcement point exists or could ever exist for them) but are NOT in ' ..
            'client/featureblocks.lua\'s CLIENT_ENFORCED_FEATURES: %s.\n\nThis means high command can set ' ..
            '`block.<Name>` for one of these on the tablet, the permission row is accepted and stored, and ' ..
            'it is SILENTLY NEVER ENFORCED ANYWHERE -- exactly the "nobody can control it, with no error, no ' ..
            'warning" failure mode this spec exists to catch, one level down (feature is blockable in the ' ..
            'UI, not actually blockable in play). FIX THIS BY: adding `<Name> = true,` to ' ..
            'client/featureblocks.lua\'s CLIENT_ENFORCED_FEATURES table AND adding an IsK9FeatureBlocked(' ..
            '\'<Name>\') check at that feature\'s own point-of-use client-side call site (never on a ' ..
            'termination/release/detach path -- see that file\'s own header), OR, if per-person blocking is ' ..
            'genuinely not meaningful for this specific feature, document why in a comment there instead of ' ..
            'leaving it silently absent.'
        ):format(#missingFromClientEnforced, table.concat(missingFromClientEnforced, ', ')), 0)
    end

    if #orphanedInClientEnforced > 0 then
        table.sort(orphanedInClientEnforced)
        error((
            '%d entr(ies) in client/featureblocks.lua\'s CLIENT_ENFORCED_FEATURES name a feature that is NOT ' ..
            'tier=\'clientonly\' (either it is not a real Config.Features key at all, or it has moved to a ' ..
            'tier with real server-side enforcement, e.g. \'live\'): %s.\n\nA feature with server-side ' ..
            'enforcement should be blocked via server/permissions.lua\'s generic `block.<Name>` path (that ' ..
            'feature\'s own file, checked directly), not via this client-only mechanism, which a modified ' ..
            'client can trivially ignore -- see this file\'s own header "THE HONEST LIMIT". FIX THIS BY: ' ..
            'removing the stale entry from CLIENT_ENFORCED_FEATURES, or re-verifying the tier classification ' ..
            'if this looks like a genuine rename.'
        ):format(#orphanedInClientEnforced, table.concat(orphanedInClientEnforced, ', ')), 0)
    end

    -- Sanity: this really compared two non-trivial sets, not two accidentally
    -- empty ones (which would make both loops above pass vacuously).
    local clientOnlyCount = 0
    for _ in pairs(clientOnlySet) do clientOnlyCount = clientOnlyCount + 1 end
    t.isTrue(clientOnlyCount >= 11, ('sanity: only saw %d tier=clientonly feature(s) -- expected at least 11'):format(clientOnlyCount))
end)

-- ============================================================================
-- SECTION 5 -- THE HEADLINE CHECK: no feature is entirely uncontrollable.
-- Every Config.Features key that is not 'clientonly' (Section 4's job) must
-- have SOME per-person block enforcement point in server/*.lua, unless it is
-- named in STRUCTURALLY_EXEMPT_FROM_PERSON_BLOCK below with a comment citing
-- the real, existing documentation that justifies the exemption.
-- ============================================================================

--- Every server/*.lua file this resource actually loads, read straight out
--- of fxmanifest.lua's own `server_scripts` block -- see this file's header
--- ("NO LONGER A HAND-MAINTAINED FILE LIST") for why this is derived rather
--- than typed out, and what went wrong when it was typed out.
---
--- Deliberately anchored to the `'server/<name>.lua'` quoted-path shape
--- fxmanifest.lua really uses, so a path mentioned in one of that file's
--- own long explanatory comments is not mistaken for a registration. The
--- floor assertion below is what stops a future reformat of fxmanifest.lua
--- silently turning this whole section into a no-op.
--- @return string[]
local function DeriveServerLuaFiles()
    local manifest = ReadFile('../fxmanifest.lua')
    local files, seen = {}, {}
    for line in manifest:gmatch('[^\n]+') do
        -- Strip a trailing line comment before matching, so a filename
        -- quoted inside a comment on the same line cannot be picked up.
        local code = line:match('^(.-)%-%-') or line
        local name = code:match("^%s*'server/([%w_]+%.lua)'%s*,?%s*$")
        if name and not seen[name] then
            seen[name] = true
            files[#files + 1] = name
        end
    end
    return files
end

local SERVER_LUA_FILES = DeriveServerLuaFiles()

-- FLOOR. Section 5's headline check reports "no per-person block path
-- exists for this feature" by finding nothing. If DeriveServerLuaFiles()
-- ever silently returns an empty or near-empty list -- fxmanifest.lua
-- reformatted, the quoted-path shape changed, the file moved -- Section 5
-- would not fail, it would report EVERY feature as uncontrollable and read
-- like a catastrophe, or (worse, depending which way the sets fall) pass
-- while checking nothing. Neither is acceptable for a guard whose whole job
-- is noticing absence, so the derivation is checked before it is trusted.
t.test('DERIVATION FLOOR: the server file list really came out of fxmanifest.lua -- a scan of nothing must never be mistaken for a clean result', function()
    t.isTrue(#SERVER_LUA_FILES >= 35,
        ('only derived %d server/*.lua file(s) from fxmanifest.lua -- expected at least 35. The quoted-path shape this parses has probably changed; fix the pattern, do not lower this number.'):format(#SERVER_LUA_FILES))

    -- A few files that must be there by construction: each is loaded by
    -- this resource and each contains a real block.<Name> check, so their
    -- absence would silently reopen exactly the gap Section 5 exists to
    -- close.
    local present = {}
    for _, name in ipairs(SERVER_LUA_FILES) do present[name] = true end
    for _, expected in ipairs({ 'combat.lua', 'kennel.lua', 'equipmentshop.lua', 'vehicle.lua', 'permissions.lua' }) do
        t.isTrue(present[expected] == true, expected .. ' must be among the derived server files')
    end
end)


--- Every literal `HasPermission(<anything-without-a-comma>, 'block.<Name>')`
--- call site across every file in SERVER_LUA_FILES -- deliberately anchored
--- to the `HasPermission(` call shape (not a bare `block%.` text search) so
--- a PROSE MENTION of a `block.<Name>` key in a comment (that file's own
--- header explains at length why that exact permission key is deliberately
--- never read) is never mistaken for a real enforcement call. Confirmed
--- against every real call site in this codebase before writing this pattern
--- (2026-08-26): every real check is `HasPermission(citizenid, 'block.X')`,
--- always single-quoted, always on one line.
--- @return table<string, boolean> set
local function LiteralBlockCoverageSet()
    local set = {}
    for _, filename in ipairs(SERVER_LUA_FILES) do
        local text = ReadFile('../server/' .. filename)
        for name in text:gmatch("HasPermission%([^,]-,%s*'block%.(%u%w*)'") do
            set[name] = true
        end
    end
    return set
end

-- Features covered by a SHARED dynamic-dispatch permission checker --
-- `HasPermission(citizenid, 'block.' .. featureName)`, where `featureName`
-- is a variable, not a literal string -- so LiteralBlockCoverageSet() above
-- can never find these by text pattern alone. Each line below was confirmed
-- by directly reading every call site of the named checker function
-- (2026-08-26), not assumed from the file's own general purpose:
--   server/wellbeing.lua's IsWellbeingFeaturePermittedForCitizenId(citizenid,
--     featureName) is called with exactly these six literal arguments --
--     A since-removed key added this pass (coder-backend, config-landing
--     pass): TickWellbeing's own Hunger/Thirst passive-decay branch already
--     called this checker with a literal removed-feature argument
--     BEFORE its own Config.Features/Config.Wellbeing
--     .Thirst existed in config.lua at all -- the block PATH was real from
--     the day that branch was written, it just had no config to turn the
--     feature on with. Same "immunity from harm, never a freeze" shape as
--     the other five: gates only the passive DECAY direction, never
--     feedK9Hunger/giveK9Water/drinkFromBowl (the relief actions), matching
--     this checker's own header ("a block ... is implemented as IMMUNITY
--     FROM THAT STAT'S NEGATIVE EFFECTS, never as a freeze").
--   server/search.lua's IsSearchFeaturePermittedForCitizenId(citizenid,
--     featureName) is called with exactly these two.
--   server/combat.lua's IsCombatFeaturePermittedForCitizenId(citizenid,
--     featureKey) is called from requestBiteHold/requestTakedown/
--     requestPropDrag with exactly these three literal featureKey arguments.
--   server/tracking.lua's IsTrackingFeaturePermittedForCitizenId(citizenid,
--     featureName) is called with TRACK_TYPE_FEATURE_FLAGS[trackType] (whose
--     own table literal maps to exactly ScentTracking/BloodTracking/
--     GunpowderSniffing) AND, separately (ScentVision pass), with the bare
--     literal 'ScentVision' at getScentVisionPoints' own call site -- same
--     shared checker function, a fourth featureName that does not come
--     through TRACK_TYPE_FEATURE_FLAGS at all since ScentVision has no
--     trackType of its own.
-- HAND-MAINTAINED (SERVER_LUA_FILES above no longer is -- see its own
-- comment; this one still is, and the tradeoff below still applies): a new
-- literal argument added to one of these four checkers' call sites must be
-- added here in the same change.
local DYNAMIC_BLOCK_COVERAGE = {
    FatigueSystem = true, SearchZones = true, ContrabandAlerts = true,
    BiteAndHold = true, NonLethalTakedown = true, PropDragging = true,
    ScentTracking = true, BloodTracking = true, GunpowderSniffing = true,
    ScentVision = true,
}

-- Features with NO per-person block path anywhere, by explicit, individually
-- justified design decision -- an ALLOWLIST, not a weakened assertion (see
-- this task's own instruction: "An allowlist entry states a decision; a
-- loosened assertion hides one"). Every entry below cites documentation that
-- ALREADY EXISTS in this codebase, independent of this spec -- this file
-- does not invent a new design decision for any of these, it only encodes
-- one that was already made and written down elsewhere.
local STRUCTURALLY_EXEMPT_FROM_PERSON_BLOCK = {
    -- server/webhook.lua posts this resource's own events into a Discord
    -- channel that staff read. It is a SERVER-WIDE LOGGING POLICY, not
    -- something one player does: there is no per-person request handler to
    -- hang a block off, because no individual ever "uses" it. Blocking one
    -- citizenid from it would have to mean "stop logging events ABOUT this
    -- person" -- which is not a capability being taken away, it is a hole
    -- deliberately punched in an audit trail, and is the opposite of what
    -- every other block in this resource does. Exempt by nature, the same
    -- way ResourceAutoDetect is. If a future pass ever wants per-person
    -- log suppression, that is a new feature with its own name and its own
    -- argument, not this key quietly gaining a block path.
    DiscordWebhook = true,

    -- server/runtimecontrol.lua's own FEATURE_TIERS: tier = 'protected'.
    -- Both gate the very authorization functions (IsHighCommand/
    -- HasPermission) every OTHER block/grant check in this entire resource
    -- depends on, and both are derived from job rank
    -- (Config.Departments.*.highCommandGrade), never from a per-citizenid
    -- feature flag the way every other entry here is. A per-person block on
    -- the mechanism that grants per-person blocks is circular by
    -- construction, not merely unimplemented.
    HighCommand = true,
    PermissionGrants = true,

    -- server/runtimecontrol.lua's own header, section "SELF-HOSTING": these
    -- two flags gate the runtime-control/theming TOOL a high-command officer
    -- USES to control every other feature in this table, including via a
    -- block. There is no distinct "block this one officer from the control
    -- panel" concept beyond simply not granting them high command (or
    -- k9.runtimecontrol/k9.tablettheme) in the first place.
    RuntimeFeatureControl = true,
    TabletTheming = true,

    -- Same family as RuntimeFeatureControl/TabletTheming directly above,
    -- confirmed by reading the real gates rather than assumed from the
    -- name: every CommandTablet surface re-derives caller authority per
    -- call from IsHighCommand / CallerHasConsoleAccess / HasPermission
    -- (server/tablet.lua:656, :825), and the flag itself is only ever read
    -- at REGISTRATION time (server/certifications/:3738,
    -- server/highcommand.lua:723, server/permissions.lua:328). So
    -- "block this one officer from the tablet" already exists and is
    -- spelled "do not grant them high command, or revoke the permission
    -- key that admits them" -- a block.CommandTablet row would be a second,
    -- weaker spelling of a control that is already per-person, and two
    -- independent answers to "may this person open the tablet" is how they
    -- drift apart.
    CommandTablet = true,

    -- A policy about WHEN a certification lapses, not an action any one
    -- person performs. It is read by the grant/renew path to decide what
    -- expiry date to stamp on a row, and by the expiry warning check --
    -- there is no per-person point of use to gate, and blocking one
    -- citizenid from "certifications expiring" would mean their
    -- certification silently never lapses, which is the opposite of a
    -- restriction. If per-person expiry exemptions are ever wanted, that
    -- is a certification-row concept, not a feature block.
    CertificationExpiry = true,

    -- Infrastructure. Decides whether the resource probes for which
    -- third-party framework/inventory/dispatch resources are installed, at
    -- boot, once, for the whole server. There is no single player it could
    -- act on -- the same reasoning this spec's own guidance text already
    -- gives for it by name.
    ResourceAutoDetect = true,

    -- server/equipmentshop.lua's own header, section "PER-PERSON FEATURE
    -- CONTROL -- WHY Config.Features.K9EquipmentShop HAS NO
    -- block.K9EquipmentShop CHECK ANYWHERE IN THIS FILE" (added the same
    -- pass as this entry, coder-backend's per-person-feature-control audit).
    -- Two independently-verified reasons, not one: (1) the actual buy/sell
    -- transaction never reaches this file's own code at all -- it is
    -- decided entirely inside whichever inventory backend is running, per
    -- that backend's OWN job-group check set once at RegisterShop time, so
    -- there is no request/response boundary in THIS resource to gate; (2)
    -- this file's one per-caller read path (equipmentShopGetLocations)
    -- cannot be turned into a real per-person control either --
    -- client/equipmentshop.lua already builds its shop-location list from
    -- Config.K9EquipmentShop.locations (shared_script data every client
    -- already holds) BEFORE that callback ever returns, and only replaces
    -- it with the callback's response on success -- denying the callback
    -- for one citizenid would not hide a single coordinate they did not
    -- already have client-side, making a "block" there pure security
    -- theater. Config.Features.K9EquipmentShop = false still turns the shop
    -- off for EVERYONE unconditionally; only the PER-PERSON half is
    -- structurally unavailable.
    K9EquipmentShop = true,
}

t.test('LOAD-BEARING DRIFT GUARD (HEADLINE): every non-clientonly Config.Features key has SOME per-person block path -- literal, dynamic-dispatch, or an explicit, commented, justified exemption -- never silently none of the three', function()
    local Config = loadRealConfig()
    local tierByName = RealFeatureTierMap()
    local literalCoverage = LiteralBlockCoverageSet()

    local uncontrollable = {}
    for name in pairs(Config.Features) do
        local tier = tierByName[name]
        if tier ~= 'clientonly' then -- Section 4's job, not this one
            local hasControl = literalCoverage[name]
                or DYNAMIC_BLOCK_COVERAGE[name]
                or STRUCTURALLY_EXEMPT_FROM_PERSON_BLOCK[name]
            if not hasControl then
                uncontrollable[#uncontrollable + 1] = name
            end
        end
    end

    if #uncontrollable > 0 then
        table.sort(uncontrollable)
        error((
            '%d Config.Features key(s) have NO per-person block path AT ALL -- no literal ' ..
            "HasPermission(citizenid, 'block.<Name>') call in any server/*.lua file, no entry in this " ..
            'spec\'s own DYNAMIC_BLOCK_COVERAGE, and no justified entry in ' ..
            'STRUCTURALLY_EXEMPT_FROM_PERSON_BLOCK: %s.\n\n' ..
            'This is the exact "feature #57 nobody can control, with no error, no warning" gap this spec ' ..
            'exists to catch -- the feature can still be switched off SERVER-WIDE (Config.Features.<Name> = ' ..
            'false always wins) but high command has no way to act on ONE specific person for it, and the ' ..
            'tablet gives no indication that pressing Block for it would do nothing.\n\n' ..
            'FIX THIS BY, for each name above, ONE of:\n' ..
            '  (a) add a real enforcement check -- `if hasPermissionAvailable and HasPermission(citizenid, ' ..
            "\"block.<Name>\") == true then return false end` -- at that feature's own point-of-use request " ..
            'handler (never a termination/release path), matching every other live-tier feature\'s own shape ' ..
            '(see server/propattachment.lua or server/fetch.lua for a direct, single-feature example); or\n' ..
            '  (b) if the feature is genuinely global-only by nature (an infrastructure/policy toggle with no ' ..
            'single person it could meaningfully act on, the way Config.Features.ResourceAutoDetect is not a ' ..
            'thing any one player does), add it to this spec\'s own STRUCTURALLY_EXEMPT_FROM_PERSON_BLOCK ' ..
            'with a comment stating that reasoning explicitly -- a decision, not a silent gap.'
        ):format(#uncontrollable, table.concat(uncontrollable, ', ')), 0)
    end
end)

os.exit(t.summary())
