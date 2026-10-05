--[[
    tests/exports_spec.lua

    Direct tests of BOTH public cross-resource API surfaces this resource
    ships -- server/exports.lua (9 exports) and client/exports.lua (19
    exports) -- against the REAL, unmodified production files. Written
    following a security audit pass (2026-08-25) that read every export body
    in both files, found them already hardened (every argument type-checked,
    every call into resource state pcall-wrapped, every table return
    defensively copied), made zero code changes, and flagged this exact gap:
    this resource's entire public export surface -- the one thing OTHER
    resources on a server actually call -- had zero direct spec coverage.
    This file closes that gap. It does not change server/exports.lua or
    client/exports.lua; if a case here ever fails, that is a real regression
    finding to report, not something to "fix" by editing this file's
    expectations.

    WHY THE WRAPPED GLOBALS ARE HAND-WRITTEN STUBS HERE, NOT THE REAL
    server/progression.lua etc.: unlike entities_spec.lua/cooldowns_spec.lua
    (which test a file's OWN logic), this file's job is to test
    server/exports.lua's and client/exports.lua's OWN thin-wrapper behavior
    in isolation -- the type/nil/pcall guards these two files add ON TOP OF
    whatever the wrapped global does. server/progression.lua's real
    ResolveTier/AwardXP/GetXP logic is already directly covered by
    progression_spec.lua; re-loading that whole file here would test the
    same logic twice while making it harder to force the exact failure
    modes this file exists to prove (a wrapped global that is simply
    undefined, or one that throws on demand). A controllable stub lets every
    test assert precisely which of the three documented safety nets
    (argument type guard / existence guard / pcall) actually fired.

    Both `serverEnv`/`clientEnv` below start with a "happy path" stub for
    every wrapped global (so tests that aren't specifically about that
    global's failure mode don't need to redeclare it), and individual tests
    reassign `serverEnv.<Name>` / `clientEnv.<Name>` before calling the
    export under test. This works because Lua 5.2+ compiles every global
    read inside the loaded chunk as a GETTABUP against that env table taken
    FRESH on every call (never a captured upvalue value) -- see
    fixtures/sandbox.lua's own header -- so mutating the env table after
    Sandbox.loadInto has already run is picked up by the very next export
    call, exactly like cooldowns_spec.lua mutating `env.source` between
    calls to a captured playerDropped handler.

    FINDINGS recorded inline as tests (not fixed here -- not this file's
    job): several exports do not validate the wrapped global's RETURN value
    against their own doc comment's declared type, unlike the exports that
    sit right next to them in the same file doing exactly that. See each
    "FINDING" test below for the specific export and the exact gap.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param tbl table
--- @return integer
local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

-- ======================================================================
-- SERVER SECTION -- server/exports.lua (9 exports)
-- ======================================================================

local capturedServerExports = {}
local function serverExportsStub(name, fn)
    capturedServerExports[name] = fn
end

-- Real-shaped Config, close enough to config.lua's own XPTiers/Departments/
-- Features tables to exercise IsK9Department/IsFeatureEnabled/GetXPTier's
-- fallback honestly, without importing config.lua itself (this file's own
-- values are placeholders per that file's own comments, so pinning a copy
-- of them here would just be one more thing to keep in sync for no benefit
-- -- these tests only care about shape, not this resource's real balance
-- numbers).
local Config = {
    Departments = {
        police = { label = 'Police' },
        sast = { label = 'SAST' },
    },
    Features = {
        XPProgression = true,
        HandlerPartnership = false,
    },
    XPTiers = {
        { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        { xp = 500,  label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        { xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
    },
}

local serverEnv = Sandbox.newEnv({
    exports = serverExportsStub,
    Config = Config,
    -- Happy-path defaults: citizenid 'ABC123' / source 1 / modelHash 12345
    -- are this section's chosen "known good" identifiers throughout.
    HasK9Access = function(source) return source == 1 end,
    IsConfiguredK9Model = function(modelHash) return modelHash == 12345 end,
    GetActivePartnerCitizenId = function(citizenid)
        if citizenid == 'ABC123' then return 'XYZ789', true end
        return nil, nil
    end,
    IsActivePartnerOf = function(citizenid, allegedPartnerCitizenid)
        return citizenid == 'ABC123' and allegedPartnerCitizenid == 'XYZ789'
    end,
    GetXP = function(citizenid)
        if citizenid == 'ABC123' then return 750 end
        return 0
    end,
    -- Mirrors the REAL server/progression.lua ResolveTier behavior this
    -- file's own header warns about: returns the SAME Config.XPTiers[n]
    -- table object, never a copy, for every citizenid in that bracket. If
    -- this stub silently returned a copy instead, the CopyTier assertions
    -- below would pass for the wrong reason -- so this is written to match
    -- the documented real hazard exactly.
    GetXPTier = function(citizenid)
        if citizenid == 'ABC123' then return Config.XPTiers[2] end
        return Config.XPTiers[1]
    end,
})

Sandbox.loadInto('../server/exports.lua', serverEnv)
local ServerExports = capturedServerExports

local SERVER_EXPORT_NAMES = {
    'GetAPIVersion', 'HasK9Access', 'IsConfiguredK9Model', 'IsK9Department',
    'GetActivePartnerCitizenId', 'IsActivePartnerOf', 'GetXP', 'GetXPTier',
    'IsFeatureEnabled',
}

t.test('server/exports.lua registers exactly the 9 documented exports, no more, no fewer', function()
    t.equals(countKeys(ServerExports), 9)
    for _, name in ipairs(SERVER_EXPORT_NAMES) do
        t.equals(type(ServerExports[name]), 'function', name .. ' must be a registered export')
    end
end)

-- ----------------------------------------------------------------------
-- GetAPIVersion
-- ----------------------------------------------------------------------

t.test('server GetAPIVersion(): matches the documented 1.0.0 shape', function()
    local version = ServerExports.GetAPIVersion()
    t.equals(version.major, 1)
    t.equals(version.minor, 0)
    t.equals(version.patch, 0)
    t.equals(version.string, '1.0.0')
end)

t.test('server GetAPIVersion(): returns a fresh table every call, never a cached/shared one', function()
    local a = ServerExports.GetAPIVersion()
    local b = ServerExports.GetAPIVersion()
    t.isTrue(a ~= b, 'two calls must not return the same table object')
    a.major = 999
    t.equals(ServerExports.GetAPIVersion().major, 1, 'mutating one call\'s result must not affect a later call')
end)

-- ----------------------------------------------------------------------
-- HasK9Access(source)
-- ----------------------------------------------------------------------

t.test('server HasK9Access(): a string source is rejected outright, never reaches the wrapped global', function()
    local called = false
    serverEnv.HasK9Access = function() called = true; return true end
    t.isFalse(ServerExports.HasK9Access('1'))
    t.isFalse(called, 'a bad-type argument must never reach the wrapped function')
end)

t.test('server HasK9Access(): a nil source is rejected outright', function()
    t.isFalse(ServerExports.HasK9Access(nil))
end)

t.test('server HasK9Access(): a table source is rejected outright', function()
    t.isFalse(ServerExports.HasK9Access({}))
end)

t.test('server HasK9Access(): a boolean source is rejected outright', function()
    t.isFalse(ServerExports.HasK9Access(true))
end)

t.test('server HasK9Access(): a missing wrapped global (existence guard) returns false', function()
    serverEnv.HasK9Access = nil
    t.isFalse(ServerExports.HasK9Access(1))
end)

t.test('server HasK9Access(): a throwing wrapped global returns false (pcall genuinely exercised)', function()
    serverEnv.HasK9Access = function() error('certifications cache corrupted') end
    t.isFalse(ServerExports.HasK9Access(1))
end)

t.test('server HasK9Access(): a real true result from the wrapped global passes through', function()
    serverEnv.HasK9Access = function(source) return source == 1 end
    t.isTrue(ServerExports.HasK9Access(1))
end)

t.test('server HasK9Access(): FINDING -- a truthy-but-not-exactly-true return (e.g. 1) is coerced to false, not passed through', function()
    serverEnv.HasK9Access = function() return 1 end
    t.isFalse(ServerExports.HasK9Access(1), 'the implementation does `result == true`, so a non-boolean truthy return is normalized to false -- matches the documented @return boolean, but is worth pinning since it silently discards a caller bug in the wrapped function rather than surfacing it')
end)

t.test('server HasK9Access(): a negative source number is type-valid and reaches the wrapped global unmodified (no positivity/range check at this layer)', function()
    local capturedSource
    serverEnv.HasK9Access = function(source) capturedSource = source; return false end
    ServerExports.HasK9Access(-7)
    t.equals(capturedSource, -7, 'this export only type-checks; a negative/zero/huge source is the wrapped global\'s own problem to reject')
end)

-- ----------------------------------------------------------------------
-- IsConfiguredK9Model(modelHash)
-- ----------------------------------------------------------------------

t.test('server IsConfiguredK9Model(): a string modelHash is rejected outright, never reaches the wrapped global', function()
    local called = false
    serverEnv.IsConfiguredK9Model = function() called = true; return true end
    t.isFalse(ServerExports.IsConfiguredK9Model('12345'))
    t.isFalse(called)
end)

t.test('server IsConfiguredK9Model(): a nil modelHash is rejected outright', function()
    t.isFalse(ServerExports.IsConfiguredK9Model(nil))
end)

t.test('server IsConfiguredK9Model(): a missing wrapped global returns false', function()
    serverEnv.IsConfiguredK9Model = nil
    t.isFalse(ServerExports.IsConfiguredK9Model(12345))
end)

t.test('server IsConfiguredK9Model(): a throwing wrapped global returns false (pcall exercised)', function()
    serverEnv.IsConfiguredK9Model = function() error('roster lookup failed') end
    t.isFalse(ServerExports.IsConfiguredK9Model(12345))
end)

t.test('server IsConfiguredK9Model(): a real true result passes through', function()
    serverEnv.IsConfiguredK9Model = function(modelHash) return modelHash == 12345 end
    t.isTrue(ServerExports.IsConfiguredK9Model(12345))
end)

t.test('server IsConfiguredK9Model(): a negative modelHash is type-valid and reaches the wrapped global unmodified', function()
    local capturedHash
    serverEnv.IsConfiguredK9Model = function(modelHash) capturedHash = modelHash; return false end
    ServerExports.IsConfiguredK9Model(-1)
    t.equals(capturedHash, -1)
end)

-- ----------------------------------------------------------------------
-- IsK9Department(jobName) -- pure Config read, no wrapped function
-- ----------------------------------------------------------------------

t.test('server IsK9Department(): a non-string jobName is rejected outright', function()
    t.isFalse(ServerExports.IsK9Department(123))
end)

t.test('server IsK9Department(): a nil jobName is rejected outright', function()
    t.isFalse(ServerExports.IsK9Department(nil))
end)

t.test('server IsK9Department(): an empty string is not a configured department (falls out of the table lookup, not an explicit == \'\' guard like its siblings below)', function()
    t.isFalse(ServerExports.IsK9Department(''))
end)

t.test('server IsK9Department(): an unrecognized job name returns false', function()
    t.isFalse(ServerExports.IsK9Department('taxi'))
end)

t.test('server IsK9Department(): a configured department returns true', function()
    t.isTrue(ServerExports.IsK9Department('police'))
end)

-- ----------------------------------------------------------------------
-- GetActivePartnerCitizenId(citizenid)
-- ----------------------------------------------------------------------

t.test('server GetActivePartnerCitizenId(): a non-string citizenid is rejected outright, returns (nil, nil), never reaches the wrapped global', function()
    local called = false
    serverEnv.GetActivePartnerCitizenId = function() called = true; return 'X', true end
    local partner, isK9 = ServerExports.GetActivePartnerCitizenId(123)
    t.isNil(partner)
    t.isNil(isK9)
    t.isFalse(called)
end)

t.test('server GetActivePartnerCitizenId(): a nil citizenid is rejected outright', function()
    local partner, isK9 = ServerExports.GetActivePartnerCitizenId(nil)
    t.isNil(partner)
    t.isNil(isK9)
end)

t.test('server GetActivePartnerCitizenId(): an empty-string citizenid is explicitly guarded, returns (nil, nil)', function()
    local called = false
    serverEnv.GetActivePartnerCitizenId = function() called = true; return 'X', true end
    local partner = ServerExports.GetActivePartnerCitizenId('')
    t.isNil(partner)
    t.isFalse(called, 'unlike IsActivePartnerOf below, this export DOES special-case citizenid == \'\'')
end)

t.test('server GetActivePartnerCitizenId(): a missing wrapped global returns (nil, nil)', function()
    serverEnv.GetActivePartnerCitizenId = nil
    local partner, isK9 = ServerExports.GetActivePartnerCitizenId('ABC123')
    t.isNil(partner)
    t.isNil(isK9)
end)

t.test('server GetActivePartnerCitizenId(): a throwing wrapped global returns (nil, nil) (pcall exercised)', function()
    serverEnv.GetActivePartnerCitizenId = function() error('partnership cache corrupted') end
    local partner, isK9 = ServerExports.GetActivePartnerCitizenId('ABC123')
    t.isNil(partner)
    t.isNil(isK9)
end)

t.test('server GetActivePartnerCitizenId(): a real match passes both return values through unmodified', function()
    serverEnv.GetActivePartnerCitizenId = function(citizenid)
        if citizenid == 'ABC123' then return 'XYZ789', true end
        return nil, nil
    end
    local partner, isK9 = ServerExports.GetActivePartnerCitizenId('ABC123')
    t.equals(partner, 'XYZ789')
    t.isTrue(isK9)
end)

t.test('server GetActivePartnerCitizenId(): FINDING -- unlike the boolean-returning exports in this same file, neither return value is type/shape-validated; a malformed isK9 from the wrapped global is passed through raw', function()
    serverEnv.GetActivePartnerCitizenId = function() return 42, 'not-a-boolean' end
    local partner, isK9 = ServerExports.GetActivePartnerCitizenId('ABC123')
    t.equals(partner, 42, 'the doc comment says @return string?, but a non-string partner is never rejected here')
    t.equals(isK9, 'not-a-boolean', 'the doc comment says @return boolean?, but this is passed through exactly as given -- no `== true` normalization like HasK9Access/IsConfiguredK9Model apply')
end)

-- ----------------------------------------------------------------------
-- IsActivePartnerOf(citizenid, allegedPartnerCitizenid)
-- ----------------------------------------------------------------------

t.test('server IsActivePartnerOf(): a non-string citizenid is rejected outright, never reaches the wrapped global', function()
    local called = false
    serverEnv.IsActivePartnerOf = function() called = true; return true end
    t.isFalse(ServerExports.IsActivePartnerOf(123, 'XYZ789'))
    t.isFalse(called)
end)

t.test('server IsActivePartnerOf(): a non-string allegedPartnerCitizenid is rejected outright', function()
    local called = false
    serverEnv.IsActivePartnerOf = function() called = true; return true end
    t.isFalse(ServerExports.IsActivePartnerOf('ABC123', 456))
    t.isFalse(called)
end)

t.test('server IsActivePartnerOf(): a nil citizenid is rejected outright', function()
    t.isFalse(ServerExports.IsActivePartnerOf(nil, 'XYZ789'))
end)

t.test('server IsActivePartnerOf(): FINDING -- an empty-string citizenid is NOT specially rejected here, unlike GetActivePartnerCitizenId/GetXP/GetXPTier -- it reaches the wrapped global unmodified', function()
    local capturedCitizenid
    serverEnv.IsActivePartnerOf = function(citizenid) capturedCitizenid = citizenid; return false end
    ServerExports.IsActivePartnerOf('', 'XYZ789')
    t.equals(capturedCitizenid, '', 'this export only checks type(citizenid) == \'string\', with no citizenid == \'\' guard, unlike its three siblings elsewhere in this file')
end)

t.test('server IsActivePartnerOf(): a missing wrapped global returns false', function()
    serverEnv.IsActivePartnerOf = nil
    t.isFalse(ServerExports.IsActivePartnerOf('ABC123', 'XYZ789'))
end)

t.test('server IsActivePartnerOf(): a throwing wrapped global returns false (pcall exercised)', function()
    serverEnv.IsActivePartnerOf = function() error('partnership lookup exploded') end
    t.isFalse(ServerExports.IsActivePartnerOf('ABC123', 'XYZ789'))
end)

t.test('server IsActivePartnerOf(): a real true match passes through', function()
    serverEnv.IsActivePartnerOf = function(citizenid, allegedPartnerCitizenid)
        return citizenid == 'ABC123' and allegedPartnerCitizenid == 'XYZ789'
    end
    t.isTrue(ServerExports.IsActivePartnerOf('ABC123', 'XYZ789'))
end)

t.test('server IsActivePartnerOf(): a truthy-but-not-exactly-true return is coerced to false', function()
    serverEnv.IsActivePartnerOf = function() return 'yes' end
    t.isFalse(ServerExports.IsActivePartnerOf('ABC123', 'XYZ789'))
end)

-- ----------------------------------------------------------------------
-- GetXP(citizenid)
-- ----------------------------------------------------------------------

t.test('server GetXP(): a non-string citizenid is rejected outright, returns 0, never reaches the wrapped global', function()
    local called = false
    serverEnv.GetXP = function() called = true; return 750 end
    t.equals(ServerExports.GetXP(123), 0)
    t.isFalse(called)
end)

t.test('server GetXP(): a nil citizenid returns 0', function()
    t.equals(ServerExports.GetXP(nil), 0)
end)

t.test('server GetXP(): an empty-string citizenid is explicitly guarded, returns 0', function()
    local called = false
    serverEnv.GetXP = function() called = true; return 750 end
    t.equals(ServerExports.GetXP(''), 0)
    t.isFalse(called)
end)

t.test('server GetXP(): a missing wrapped global returns 0', function()
    serverEnv.GetXP = nil
    t.equals(ServerExports.GetXP('ABC123'), 0)
end)

t.test('server GetXP(): a throwing wrapped global returns 0 (pcall exercised)', function()
    serverEnv.GetXP = function() error('progression cache corrupted') end
    t.equals(ServerExports.GetXP('ABC123'), 0)
end)

t.test('server GetXP(): a non-number result from the wrapped global is rejected, returns 0', function()
    serverEnv.GetXP = function() return 'a lot' end
    t.equals(ServerExports.GetXP('ABC123'), 0)
end)

t.test('server GetXP(): a real numeric result passes through', function()
    serverEnv.GetXP = function(citizenid) if citizenid == 'ABC123' then return 750 end return 0 end
    t.equals(ServerExports.GetXP('ABC123'), 750)
end)

t.test('server GetXP(): a negative XP value from the wrapped global is passed through unmodified (no clamp at this layer -- type(xp) == \'number\' is the only check)', function()
    serverEnv.GetXP = function() return -500 end
    t.equals(ServerExports.GetXP('ABC123'), -500)
end)

-- ----------------------------------------------------------------------
-- GetXPTier(citizenid) -- the audit's own highest-value single assertion:
-- must never leak the live Config.XPTiers[n] reference.
-- ----------------------------------------------------------------------

t.test('server GetXPTier(): a non-string citizenid falls back to a COPY of the base tier, never reaching the wrapped global', function()
    local called = false
    serverEnv.GetXPTier = function() called = true; return Config.XPTiers[2] end
    local tier = ServerExports.GetXPTier(123)
    t.equals(tier.xp, 0)
    t.equals(tier.label, 'Recruit K9')
    t.isFalse(called)
end)

t.test('server GetXPTier(): an empty-string citizenid falls back to the base tier copy', function()
    local tier = ServerExports.GetXPTier('')
    t.equals(tier.xp, 0)
end)

t.test('server GetXPTier(): a nil citizenid falls back to the base tier copy', function()
    local tier = ServerExports.GetXPTier(nil)
    t.equals(tier.xp, 0)
end)

t.test('server GetXPTier(): a missing wrapped global falls back to the base tier copy', function()
    serverEnv.GetXPTier = nil
    local tier = ServerExports.GetXPTier('ABC123')
    t.equals(tier.xp, 0)
    t.equals(tier.label, 'Recruit K9')
end)

t.test('server GetXPTier(): a throwing wrapped global falls back to the base tier copy (pcall exercised)', function()
    serverEnv.GetXPTier = function() error('progression cache corrupted') end
    local tier = ServerExports.GetXPTier('ABC123')
    t.equals(tier.xp, 0)
end)

t.test('server GetXPTier(): a non-table result from the wrapped global falls back to the base tier copy', function()
    serverEnv.GetXPTier = function() return 'not-a-table' end
    local tier = ServerExports.GetXPTier('ABC123')
    t.equals(tier.xp, 0)
end)

t.test('server GetXPTier(): the base-tier FALLBACK itself must never leak the live Config.XPTiers[1] reference either', function()
    local tier = ServerExports.GetXPTier(nil) -- forces the fallback path, never touches the wrapped global
    tier.speedMultiplier = -1
    tier.label = 'CORRUPTED'
    t.equals(Config.XPTiers[1].speedMultiplier, 1.00, 'mutating the fallback copy must never corrupt the real Config.XPTiers[1]')
    t.equals(Config.XPTiers[1].label, 'Recruit K9')
end)

t.test('server GetXPTier(): LOAD-BEARING -- success path returns a copy, never the live Config.XPTiers[n] reference the wrapped global itself returns', function()
    serverEnv.GetXPTier = function(citizenid)
        if citizenid == 'ABC123' then return Config.XPTiers[2] end
        return Config.XPTiers[1]
    end

    local tier = ServerExports.GetXPTier('ABC123')
    t.equals(tier.xp, 500)
    t.equals(tier.label, 'Trained K9')
    t.equals(tier.speedMultiplier, 1.05)

    -- The exact scenario this file's header warns about: mutating THIS
    -- caller's own copy must never move movement speed for every other K9
    -- sharing this tier bracket.
    tier.speedMultiplier = 999
    tier.label = 'CORRUPTED'

    t.equals(Config.XPTiers[2].speedMultiplier, 1.05, 'GetXPTier export must never leak a live reference to Config.XPTiers[n] -- this is the audit\'s own highest-value assertion')
    t.equals(Config.XPTiers[2].label, 'Trained K9')
end)

t.test('server GetXPTier(): two separate successful calls never return the same table object as each other or as Config.XPTiers[n]', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end
    local tierA = ServerExports.GetXPTier('X')
    local tierB = ServerExports.GetXPTier('X')
    t.isTrue(tierA ~= tierB, 'two calls must not share the same copy')
    t.isTrue(tierA ~= Config.XPTiers[2], 'must never be the live object itself')
end)

t.test('server GetXPTier(): CopyTier genuinely recurses -- a nested table field is copied too, not shared by reference (the exact regression its own header comment warns about)', function()
    local nestedPerk = { name = 'bonus-sniff' }
    local hypotheticalTier = {
        xp = 999, label = 'Hypothetical', speedMultiplier = 1.0, scentRangeMultiplier = 1.0,
        perks = { nestedPerk },
    }
    serverEnv.GetXPTier = function() return hypotheticalTier end

    local tier = ServerExports.GetXPTier('X')
    t.isTrue(tier.perks ~= hypotheticalTier.perks, 'the nested perks table must be a fresh copy, not the original')
    t.isTrue(tier.perks[1] ~= nestedPerk, 'a table nested two levels deep must also be copied')
    t.equals(tier.perks[1].name, 'bonus-sniff', 'the copy must still preserve the nested value')
end)

-- ----------------------------------------------------------------------
-- GetXPTier(citizenid) -- BUGFIX COVERAGE (this pass): composing
-- server/k9profiles.lua's GetK9EffectiveMultipliers(citizenid) onto the
-- raw tier copy, so a caller resource asking "what is this K9's speed
-- multiplier" sees the operator's per-K9 override, exactly like
-- server/progression.lua's BuildEffectiveTierSnapshot and
-- server/tracking.lua's own scent-range consumer already do. Not stubbed
-- in the base `serverEnv` above (deliberately -- see that env's own
-- comment for why every wrapped global gets a "happy path" default): a
-- missing GetK9EffectiveMultipliers here is the REAL, common case (an
-- install that never touched server/k9profiles.lua), so every test in this
-- file BEFORE this block already exercised the intended "no override
-- available" degrade path without knowing it. Each test below sets
-- `serverEnv.GetK9EffectiveMultipliers` explicitly and clears it back to
-- nil afterward so later, unrelated tests in this file are not affected.
-- ----------------------------------------------------------------------

t.test('server GetXPTier(): composes a live individual override onto the raw tier copy -- the exact gap this pass closes', function()
    serverEnv.GetXPTier = function(citizenid)
        if citizenid == 'ABC123' then return Config.XPTiers[2] end
        return Config.XPTiers[1]
    end
    serverEnv.GetK9EffectiveMultipliers = function(citizenid)
        if citizenid == 'ABC123' then
            return { speedMultiplier = 2.5, scentRangeMultiplier = 1.8, medkitCooldownMultiplier = 0.5 }
        end
        return { speedMultiplier = 1.0, scentRangeMultiplier = 1.0 }
    end

    local tier = ServerExports.GetXPTier('ABC123')
    t.equals(tier.xp, 500, 'non-overridable fields (xp/label) still come from the raw tier, unchanged')
    t.equals(tier.label, 'Trained K9')
    t.equals(tier.speedMultiplier, 2.5, 'the operator override must win over the plain tier value (1.05)')
    t.equals(tier.scentRangeMultiplier, 1.8)
    t.equals(tier.medkitCooldownMultiplier, 0.5)

    serverEnv.GetK9EffectiveMultipliers = nil
end)

t.test('server GetXPTier(): a citizenid with NO live override is unaffected by a present, healthy GetK9EffectiveMultipliers (strict widening, never a narrowing)', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end
    -- Mirrors GetK9EffectiveMultipliers' own real contract: with no override
    -- row, it returns the plain tier-derived values unchanged.
    serverEnv.GetK9EffectiveMultipliers = function() return { speedMultiplier = 1.05, scentRangeMultiplier = 1.05 } end

    local tier = ServerExports.GetXPTier('X')
    t.equals(tier.speedMultiplier, 1.05)
    t.equals(tier.scentRangeMultiplier, 1.05)

    serverEnv.GetK9EffectiveMultipliers = nil
end)

t.test('server GetXPTier(): a missing GetK9EffectiveMultipliers global degrades to the plain tier copy -- this export\'s own pre-fix behavior, never an error, never nil', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end
    serverEnv.GetK9EffectiveMultipliers = nil -- an install predating server/k9profiles.lua

    local tier = ServerExports.GetXPTier('X')
    t.equals(tier.speedMultiplier, 1.05)
    t.equals(tier.scentRangeMultiplier, 1.05)
end)

t.test('server GetXPTier(): a throwing GetK9EffectiveMultipliers degrades to the plain tier copy (pcall exercised)', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end
    serverEnv.GetK9EffectiveMultipliers = function() error('k9profiles cache corrupted') end

    local tier = ServerExports.GetXPTier('X')
    t.equals(tier.speedMultiplier, 1.05)

    serverEnv.GetK9EffectiveMultipliers = nil
end)

t.test('server GetXPTier(): a non-table result from GetK9EffectiveMultipliers is ignored, degrading to the plain tier copy', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end
    serverEnv.GetK9EffectiveMultipliers = function() return 'not-a-table' end

    local tier = ServerExports.GetXPTier('X')
    t.equals(tier.speedMultiplier, 1.05)

    serverEnv.GetK9EffectiveMultipliers = nil
end)

t.test('server GetXPTier(): only the fields GetK9EffectiveMultipliers actually sets as numbers are overlaid -- a field it omits keeps the raw tier value, never becomes nil', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end -- speedMultiplier=1.05, scentRangeMultiplier=1.05
    serverEnv.GetK9EffectiveMultipliers = function() return { speedMultiplier = 3.0 } end -- scentRangeMultiplier omitted

    local tier = ServerExports.GetXPTier('X')
    t.equals(tier.speedMultiplier, 3.0)
    t.equals(tier.scentRangeMultiplier, 1.05, 'a field the effective-multipliers result does not set must keep the raw tier value')

    serverEnv.GetK9EffectiveMultipliers = nil
end)

t.test('server GetXPTier(): the composed snapshot is still a fresh copy -- mutating it must never corrupt Config.XPTiers[n] even when an override was applied', function()
    serverEnv.GetXPTier = function() return Config.XPTiers[2] end
    serverEnv.GetK9EffectiveMultipliers = function() return { speedMultiplier = 3.0 } end

    local tier = ServerExports.GetXPTier('X')
    tier.speedMultiplier = -1
    t.equals(Config.XPTiers[2].speedMultiplier, 1.05, 'the override overlay must still land on a private copy, never Config.XPTiers[n] itself')

    serverEnv.GetK9EffectiveMultipliers = nil
end)

t.test('server GetXPTier(): a non-string citizenid never reaches GetK9EffectiveMultipliers either, exactly like it never reaches the wrapped GetXPTier', function()
    local called = false
    serverEnv.GetK9EffectiveMultipliers = function() called = true; return {} end

    ServerExports.GetXPTier(123)
    t.isFalse(called, 'an invalid citizenid has no override to look up and must short-circuit before this call')

    serverEnv.GetK9EffectiveMultipliers = nil
end)

-- ----------------------------------------------------------------------
-- IsFeatureEnabled(featureKey)
-- ----------------------------------------------------------------------

t.test('server IsFeatureEnabled(): a non-string featureKey returns nil', function()
    t.isNil(ServerExports.IsFeatureEnabled(123))
end)

t.test('server IsFeatureEnabled(): a nil featureKey returns nil', function()
    t.isNil(ServerExports.IsFeatureEnabled(nil))
end)

t.test('server IsFeatureEnabled(): an empty-string featureKey returns nil (no Config.Features[\'\'] entry exists)', function()
    t.isNil(ServerExports.IsFeatureEnabled(''))
end)

t.test('server IsFeatureEnabled(): an unrecognized featureKey returns nil, distinguishing "unknown key" from "known and false"', function()
    t.isNil(ServerExports.IsFeatureEnabled('TotallyMadeUpFeature'))
end)

t.test('server IsFeatureEnabled(): a recognized feature that is enabled returns true', function()
    t.isTrue(ServerExports.IsFeatureEnabled('XPProgression'))
end)

t.test('server IsFeatureEnabled(): a recognized feature that is disabled returns false, not nil', function()
    t.isFalse(ServerExports.IsFeatureEnabled('HandlerPartnership'))
end)

-- ======================================================================
-- CLIENT SECTION -- client/exports.lua (19 exports)
-- ======================================================================

local capturedClientExports = {}
local function clientExportsStub(name, fn)
    capturedClientExports[name] = fn
end

local clientEnv = Sandbox.newEnv({
    exports = clientExportsStub,
    HasK9Access = function() return true end,
    IsOwnModelK9 = function() return true end,
    CanShowK9UI = function() return true end,
    IsLeashed = function() return false end,
    IsInK9Vehicle = function() return false end,
    IsPartnered = function() return true end,
    GetPartnerServerId = function() return 5 end,
    GetCurrentXPTier = function() return { xp = 0, label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 } end,
    IsTracking = function() return false end,
    GetActiveTrackType = function() return nil end,
    IsThermalVisionActive = function() return false end,
    IsNightVisionActive = function() return false end,
    IsBiteHoldEngaged = function() return false end,
    IsDragEngaged = function() return false end,
    IsFetchCarryEngaged = function() return false end,
    IsPropAttachmentEngaged = function() return false end,
})

Sandbox.loadInto('../client/exports.lua', clientEnv)
local ClientExports = capturedClientExports

local CLIENT_EXPORT_NAMES = {
    'GetAPIVersion', 'HasK9Access', 'IsOwnModelK9', 'CanShowK9UI', 'IsLeashed',
    'IsInK9Vehicle', 'IsPartnered', 'GetPartnerServerId', 'GetCurrentXPTier',
    'IsTracking', 'GetActiveTrackType', 'IsThermalVisionActive', 'IsNightVisionActive',
    'IsBiteHoldEngaged', 'IsDragEngaged', 'IsFetchCarryEngaged', 'IsPropAttachmentEngaged',
}

t.test('client/exports.lua registers exactly the 17 documented exports, no more, no fewer', function()
    t.equals(countKeys(ClientExports), 17)
    for _, name in ipairs(CLIENT_EXPORT_NAMES) do
        t.equals(type(ClientExports[name]), 'function', name .. ' must be a registered export')
    end
end)

-- ----------------------------------------------------------------------
-- GetAPIVersion
-- ----------------------------------------------------------------------

t.test('client GetAPIVersion(): matches the documented 1.2.0 shape (deliberately NOT kept numerically in sync with the server file\'s 1.0.0 -- see that file\'s own VERSIONING correction)', function()
    local version = ClientExports.GetAPIVersion()
    t.equals(version.major, 1)
    t.equals(version.minor, 2)
    t.equals(version.patch, 0)
    t.equals(version.string, '1.2.0')
end)

t.test('client GetAPIVersion(): returns a fresh table every call', function()
    local a = ClientExports.GetAPIVersion()
    local b = ClientExports.GetAPIVersion()
    t.isTrue(a ~= b)
    a.major = 999
    t.equals(ClientExports.GetAPIVersion().major, 1)
end)

-- ----------------------------------------------------------------------
-- The 14 zero-argument boolean exports (HasK9Access, IsOwnModelK9,
-- CanShowK9UI, IsLeashed, IsInK9Vehicle, IsPartnered, IsTracking,
-- IsThermalVisionActive, IsNightVisionActive, IsBiteHoldEngaged,
-- IsDragEngaged, IsFetchCarryEngaged,
-- IsPropAttachmentEngaged) all share the IDENTICAL body shape, verified by
-- direct read of every one of the 14 bodies in client/exports.lua, not
-- assumed from the first one:
--     if type(X) ~= 'function' then return false end
--     local ok, result = pcall(X)
--     if not ok then return false end
--     return result == true
-- Driven through a table + loop rather than 14 hand-copies of the same 3
-- tests, exactly because the shape really is byte-identical across all of
-- them -- a hand-copy-paste risk this loop avoids entirely.
-- ----------------------------------------------------------------------

local CLIENT_BOOLEAN_EXPORTS = {
    'HasK9Access', 'IsOwnModelK9', 'CanShowK9UI', 'IsLeashed', 'IsInK9Vehicle',
    'IsPartnered', 'IsTracking', 'IsThermalVisionActive', 'IsNightVisionActive',
    'IsBiteHoldEngaged', 'IsDragEngaged', 'IsFetchCarryEngaged',
    'IsPropAttachmentEngaged',
}

for _, exportName in ipairs(CLIENT_BOOLEAN_EXPORTS) do
    t.test(('client %s(): a missing wrapped global (existence guard) returns false'):format(exportName), function()
        clientEnv[exportName] = nil
        t.isFalse(ClientExports[exportName]())
    end)

    t.test(('client %s(): a throwing wrapped global returns false (pcall genuinely exercised)'):format(exportName), function()
        clientEnv[exportName] = function() error('boom from ' .. exportName) end
        t.isFalse(ClientExports[exportName]())
    end)

    t.test(('client %s(): a real true result passes through'):format(exportName), function()
        clientEnv[exportName] = function() return true end
        t.isTrue(ClientExports[exportName]())
    end)

    t.test(('client %s(): a real false result passes through'):format(exportName), function()
        clientEnv[exportName] = function() return false end
        t.isFalse(ClientExports[exportName]())
    end)
end

t.test('client HasK9Access(): FINDING -- same coercion as the server file -- a truthy-but-not-exactly-true return is normalized to false, not passed through', function()
    clientEnv.HasK9Access = function() return 'yes' end
    t.isFalse(ClientExports.HasK9Access())
end)

-- ----------------------------------------------------------------------
-- GetPartnerServerId() -- number? passthrough, NO type(result) validation
-- ----------------------------------------------------------------------

t.test('client GetPartnerServerId(): a missing wrapped global returns nil', function()
    clientEnv.GetPartnerServerId = nil
    t.isNil(ClientExports.GetPartnerServerId())
end)

t.test('client GetPartnerServerId(): a throwing wrapped global returns nil (pcall exercised)', function()
    clientEnv.GetPartnerServerId = function() error('boom') end
    t.isNil(ClientExports.GetPartnerServerId())
end)

t.test('client GetPartnerServerId(): a real server id passes through unmodified', function()
    clientEnv.GetPartnerServerId = function() return 7 end
    t.equals(ClientExports.GetPartnerServerId(), 7)
end)

t.test('client GetPartnerServerId(): FINDING -- this export has NO type(result) == \'number\' guard; a non-number return from the wrapped global is passed through raw, contradicting its own @return number? doc comment', function()
    clientEnv.GetPartnerServerId = function() return 'not-a-number' end
    t.equals(ClientExports.GetPartnerServerId(), 'not-a-number', 'this pins the real, currently-observed behavior -- not an endorsement of it')
end)

-- ----------------------------------------------------------------------
-- GetActiveTrackType() -- 'scent'|'blood'|'gunpowder'|nil passthrough, NO
-- enum validation
-- ----------------------------------------------------------------------

t.test('client GetActiveTrackType(): a missing wrapped global returns nil', function()
    clientEnv.GetActiveTrackType = nil
    t.isNil(ClientExports.GetActiveTrackType())
end)

t.test('client GetActiveTrackType(): a throwing wrapped global returns nil (pcall exercised)', function()
    clientEnv.GetActiveTrackType = function() error('boom') end
    t.isNil(ClientExports.GetActiveTrackType())
end)

t.test('client GetActiveTrackType(): a documented value passes through unmodified', function()
    clientEnv.GetActiveTrackType = function() return 'scent' end
    t.equals(ClientExports.GetActiveTrackType(), 'scent')
end)

t.test('client GetActiveTrackType(): FINDING -- no validation against the documented \'scent\'|\'blood\'|\'gunpowder\'|nil enum; any string the wrapped global returns is passed through raw', function()
    clientEnv.GetActiveTrackType = function() return 'not-a-real-track-type' end
    t.equals(ClientExports.GetActiveTrackType(), 'not-a-real-track-type')
end)

-- ----------------------------------------------------------------------
-- GetCurrentXPTier() -- the client-side counterpart to server GetXPTier's
-- highest-value assertion: must never leak the live cached tier reference.
-- ----------------------------------------------------------------------

t.test('client GetCurrentXPTier(): a missing wrapped global returns nil (no snapshot pushed yet this session)', function()
    clientEnv.GetCurrentXPTier = nil
    t.isNil(ClientExports.GetCurrentXPTier())
end)

t.test('client GetCurrentXPTier(): a throwing wrapped global returns nil (pcall exercised)', function()
    clientEnv.GetCurrentXPTier = function() error('boom') end
    t.isNil(ClientExports.GetCurrentXPTier())
end)

t.test('client GetCurrentXPTier(): a non-table result from the wrapped global returns nil', function()
    clientEnv.GetCurrentXPTier = function() return 'not-a-table' end
    t.isNil(ClientExports.GetCurrentXPTier())
end)

t.test('client GetCurrentXPTier(): LOAD-BEARING -- success returns a copy, never the live cached tier table client/progression.lua itself owns', function()
    local cachedTier = { xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 }
    clientEnv.GetCurrentXPTier = function() return cachedTier end

    local tier = ClientExports.GetCurrentXPTier()
    t.equals(tier.label, 'Veteran K9')
    tier.speedMultiplier = 999
    t.equals(cachedTier.speedMultiplier, 1.10, 'GetCurrentXPTier must never leak client/progression.lua\'s own cached tier table -- same guarantee, and same load-bearing status, as server GetXPTier')
    t.isTrue(tier ~= cachedTier, 'must be a genuinely different table object')
end)

t.test('client GetCurrentXPTier(): CopyTier genuinely recurses here too -- a nested field is copied, not shared by reference', function()
    local nestedPerk = { name = 'bonus-sniff' }
    local cachedTier = {
        xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10,
        perks = { nestedPerk },
    }
    clientEnv.GetCurrentXPTier = function() return cachedTier end

    local tier = ClientExports.GetCurrentXPTier()
    t.isTrue(tier.perks ~= cachedTier.perks, 'the nested perks table must be a fresh copy')
    t.isTrue(tier.perks[1] ~= nestedPerk, 'a table nested two levels deep must also be copied')
    t.equals(tier.perks[1].name, 'bonus-sniff')
end)

os.exit(t.summary())
