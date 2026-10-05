--[[
    tests/xptierunlocks_spec.lua

    Tests for server/progression.lua's GetXPTierMedkitCooldownMs -- Part B §8
    XP TIER UNLOCKS (see that file's own "XP TIER UNLOCKS" section header,
    directly above GetXPTierMedkitCooldownMs's own declaration, for the full
    design: which three tiers unlock what, and why every rejected candidate
    was rejected). Loaded via the REAL, unmodified server/progression.lua
    (same sandbox recipe as tests/progression_spec.lua: server/cooldowns.lua
    first, since progression.lua's own file-local AwardXPCooldown/
    XPMintBudget state needs the real NewNestedCooldown constructor at load
    time).

    Every AwardXP call below advances the fake clock by 500,000ms first --
    comfortably clearing BOTH the 500ms-per-(citizenid,actionKey) rate floor
    AND the shared XP mint budget's own refill needs for this fixture's
    60-XP award (the budget refills at exactly 1 XP per 1,000ms, so 500,000ms
    refills ~500 XP between calls -- nowhere near draining even under
    repeated 60-XP draws), mirroring tests/progression_spec.lua's own
    identical-purpose "high accumulated total" test.

    Covers:
      1. GetXPTierMedkitCooldownMs's pure numeric contract: an absent/
         non-numeric/NaN/<=0/>1 medkitCooldownMultiplier on the resolved
         tier returns baseCooldownMs UNCHANGED (the safe, "unlock not yet
         configured, or misconfigured" default); a valid (0, 1] multiplier
         reduces it; a malformed baseCooldownMs itself is returned
         unchanged, never erroring.
      1b. GetHandlerXPTierMedkitCooldownMs/GetHandlerXPTierKennelDeployCooldownMs's
          own pure numeric contract (dead-config-field pass, coder-backend)
          -- the IDENTICAL contract as item 1 above, run against the
          separate Config.HandlerXPTiers ladder instead, plus one
          CROSS-LADDER INDEPENDENCE test proving a shared citizenid's K9-XP
          standing never leaks into their handler-XP standing or vice
          versa. See server/progression.lua's own "HANDLER XP TIER
          UNLOCKS" doc comment (immediately after GetHandlerXPTier) for
          the feedback-loop-safety analysis this section does not repeat.
      2. THE LOAD-BEARING PROOF this task requires: a tier unlock cannot
         override a high-command block. There is still no SINGLE shared,
         exported Config.FeatureControl block/grant resolution function to
         load and drive directly -- each consuming file (server/medkit.lua,
         server/combat.lua, server/admin.lua, server/search.lua, and others)
         implements its own local per-feature resolution function against
         the same generic HasPermission('feature.<Name>'/'block.<Name>')
         seam, copied rather than shared (see server/progression.lua's own
         "XP TIER UNLOCKS" section for why none of this pass's three
         unlocks needed one to compose safely). This section instead proves
         the property the most concrete way currently possible against
         REAL, unmodified code: it drives the REAL GetXPTierMedkitCooldownMs
         through a small, explicitly-labelled local stand-in for the
         block-before-tier-consultation shape, and shows that a block check
         placed BEFORE the tier-multiplier consultation (the only order
         GetXPTierMedkitCooldownMs's own CALLER CONTRACT permits) denies
         outright, regardless of tier, and never even reaches the tier
         read. This proves the INTEGRATION PATTERN's correctness in the
         general case. CORRECTED (this pass, coder-backend): this used to
         call the stand-in below a proxy for server/medkit.lua's own
         "REPORTED (not yet applied)" call-site integration -- re-verified
         false by direct read. server/medkit.lua's RunUseK9MedkitMutation
         now genuinely calls GetXPTierMedkitCooldownMs (see that function's
         own CALLER CONTRACT doc comment in server/progression.lua for the
         exact call site) -- but its own per-person K9Medkit feature/block
         check (IsK9MedkitPermittedForCitizenId) runs earlier in that
         file's callback, before the mutex/cooldown resolution, not as a
         check interleaved with the tier-multiplier read itself. The
         stand-in below remains a generic proof of the ORDERING property,
         not a literal mirror of server/medkit.lua's own current structure.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup -- same minimal recipe as tests/progression_spec.lua's own
-- shared env (only the pieces server/progression.lua's own top-level/
-- onResourceStart code actually touches).
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName() return 'john-k9' end
local function GetPlayers() return {} end
local function TriggerEvent(_eventName, ...) end
local function TriggerClientEvent(_eventName, _target, ...) end

local function CreateThread(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        error(('xptierunlocks_spec.lua: a CreateThread body errored: %s'):format(tostring(err)))
    end
end
local function Wait(_ms) coroutine.yield() end

local exportsStub = {
    qbx_core = {
        GetPlayerByCitizenId = function(_self, _citizenid) return nil end,
        GetPlayer = function(_self, _src) return nil end,
    },
}

local MySQLStub = {
    scalar = { await = function(_sql, _params) return nil end },
    insert = { await = function(_sql, _params) return 1 end },
}

local Config = {
    Features = { XPProgression = true, HandlerXPProgression = true },
    XP = {
        scopePerCitizenidOrJob = 'citizenid',
        awards = { smallAward = 60 },
    },
    XPTiers = {
        { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        -- No medkitCooldownMultiplier on this tier -- exercises the
        -- "not configured yet" defensive default.
        { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        -- Valid reduction: 0.75 => 25% faster.
        { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10, medkitCooldownMultiplier = 0.75 },
        -- Deliberately non-positive -- proves a bad value on a HIGHER tier
        -- is rejected independently, never just the first bad shape found.
        { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0 },
    },
    -- HANDLER XP TIER UNLOCKS (dead-config-field pass, coder-backend) --
    -- GetHandlerXPTierMedkitCooldownMs/GetHandlerXPTierKennelDeployCooldownMs's
    -- own numeric contract, same shape as Config.XPTiers above, exercised
    -- against the SAME class of edge cases on the HANDLER ladder instead of
    -- the K9 one.
    HandlerXPTiers = {
        { xp = 0,    label = 'Rookie Handler' },
        -- No kennelDeployCooldownMultiplier on this tier -- exercises the
        -- "not configured yet" defensive default for THAT field
        -- independently of medkitTreatCooldownMultiplier.
        { xp = 750,  label = 'Certified Handler', medkitTreatCooldownMultiplier = 0.90 },
        { xp = 2500, label = 'Senior Handler',    medkitTreatCooldownMultiplier = 0.80, kennelDeployCooldownMultiplier = 0.75 },
        { xp = 6000, label = 'Master Handler',    medkitTreatCooldownMultiplier = 0.70, kennelDeployCooldownMultiplier = 0.60 },
        -- Deliberately non-positive/negative on this extra top tier --
        -- proves a bad value on a HIGHER tier is rejected independently,
        -- never just the first bad shape found (mirrors Config.XPTiers'
        -- own Elite-tier test above).
        { xp = 20000, label = 'Legendary Handler (test-only)', medkitTreatCooldownMultiplier = 0, kennelDeployCooldownMultiplier = -0.5 },
    },
    HandlerXP = {
        awards = { smallHandlerAward = 60 },
    },
}

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    GetPlayers = GetPlayers,
    TriggerEvent = TriggerEvent,
    TriggerClientEvent = TriggerClientEvent,
    CreateThread = CreateThread,
    Wait = Wait,
    exports = exportsStub,
    MySQL = MySQLStub,
    Config = Config,
})

Sandbox.loadInto('../server/cooldowns.lua', env)
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/progression.lua's own
-- LoadXPForCitizenid/AwardXP now read/write through K9Store.XP_Get/
-- K9Store.XP_UpsertAdd rather than raw SQL). Config.Database is
-- deliberately absent from this fixture's Config table above --
-- K9Store's own DatabaseEnabled() fails safe to `true`, which is exactly
-- what makes those K9Store calls run the SAME MySQL.scalar.await/
-- MySQL.insert.await calls (against this fixture's own MySQLStub) built
-- directly before this migration, so every existing assertion below
-- keeps exercising the identical SQL/params shape unchanged.
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted into its own file; the manifest loads it in the real resource, so a sandbox that omits it fails where the game would not
Sandbox.loadInto('../server/progression.lua', env)
for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('john-k9')
end

local AwardXP = env.AwardXP
local GetXPTier = env.GetXPTier
local GetXPTierMedkitCooldownMs = env.GetXPTierMedkitCooldownMs
local AwardHandlerXP = env.AwardHandlerXP
local GetHandlerXPTier = env.GetHandlerXPTier
local GetHandlerXPTierMedkitCooldownMs = env.GetHandlerXPTierMedkitCooldownMs
local GetHandlerXPTierKennelDeployCooldownMs = env.GetHandlerXPTierKennelDeployCooldownMs

t.isNotNil(GetXPTierMedkitCooldownMs, 'server/progression.lua must define global GetXPTierMedkitCooldownMs')
t.isNotNil(GetHandlerXPTierMedkitCooldownMs, 'server/progression.lua must define global GetHandlerXPTierMedkitCooldownMs')
t.isNotNil(GetHandlerXPTierKennelDeployCooldownMs, 'server/progression.lua must define global GetHandlerXPTierKennelDeployCooldownMs')

--- Awards `count` copies of 'smallAward' (60 XP) to `citizenid`, each
--- separated by 500,000ms -- see this file's header for why that spacing
--- clears both the per-actionKey rate floor and the shared mint budget's
--- own refill needs for this fixture's award size.
--- @param citizenid string
--- @param count number
local function grindToward(citizenid, count)
    for _ = 1, count do
        fakeNow = fakeNow + 500000
        AwardXP(citizenid, 'smallAward')
    end
end

--- Identical shape to grindToward above, but for the SEPARATE handler-XP
--- total (AwardHandlerXP/GetHandlerXPTier) -- same 500,000ms spacing, same
--- reasoning (this file's own header): the shared cross-mechanic mint
--- budget is the SAME bucket AwardXP draws from, but each test below uses
--- its own never-reused citizenid, so no cross-test interference either way.
--- @param citizenid string
--- @param count number
local function grindTowardHandler(citizenid, count)
    for _ = 1, count do
        fakeNow = fakeNow + 500000
        AwardHandlerXP(citizenid, 'smallHandlerAward')
    end
end

-- ----------------------------------------------------------------------
-- Pure numeric contract
-- ----------------------------------------------------------------------

t.test('GetXPTierMedkitCooldownMs: an uncached (base-tier) citizenid with no medkitCooldownMultiplier returns baseCooldownMs unchanged', function()
    t.equals(GetXPTierMedkitCooldownMs('never-seen-before', 60000), 60000)
end)

t.test('GetXPTierMedkitCooldownMs: Trained tier (no medkitCooldownMultiplier field at all) returns baseCooldownMs unchanged -- the "unlock not yet configured" default', function()
    grindToward('cid-trained', 21) -- 21 * 60 = 1260 >= 1250 (Trained), < 4000 (Veteran)
    t.equals(GetXPTier('cid-trained').label, 'Trained K9', 'sanity check on this test\'s own arithmetic')
    t.equals(GetXPTierMedkitCooldownMs('cid-trained', 60000), 60000, 'Trained tier has no medkitCooldownMultiplier configured -- must return the base value unchanged, never error or invent a number')
end)

t.test('GetXPTierMedkitCooldownMs: Veteran tier (medkitCooldownMultiplier = 0.75) reduces the cooldown', function()
    grindToward('cid-veteran', 67) -- 67 * 60 = 4020 >= 4000 (Veteran), < 9000 (Elite)
    t.equals(GetXPTier('cid-veteran').label, 'Veteran K9', 'sanity check on this test\'s own arithmetic')
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 45000, '60000 * 0.75 = 45000')
end)

t.test('GetXPTierMedkitCooldownMs: a multiplier > 1 is rejected -- an unlock must never LENGTHEN a cooldown', function()
    local original = Config.XPTiers[3].medkitCooldownMultiplier
    Config.XPTiers[3].medkitCooldownMultiplier = 1.5
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 60000, 'a multiplier > 1 must be rejected outright, never applied')
    Config.XPTiers[3].medkitCooldownMultiplier = original
end)

t.test('GetXPTierMedkitCooldownMs: a numeric-looking STRING multiplier is rejected -- only a real Lua number may reduce a cooldown', function()
    local original = Config.XPTiers[3].medkitCooldownMultiplier
    Config.XPTiers[3].medkitCooldownMultiplier = '0.5'
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 60000)
    Config.XPTiers[3].medkitCooldownMultiplier = original
end)

t.test('GetXPTierMedkitCooldownMs: a non-positive multiplier (Elite tier, 0) is rejected -- returns baseCooldownMs unchanged, never 0 or negative', function()
    grindToward('cid-elite', 151) -- 151 * 60 = 9060 >= 9000 (Elite)
    t.equals(GetXPTier('cid-elite').label, 'Elite K9', 'sanity check on this test\'s own arithmetic')
    t.equals(GetXPTierMedkitCooldownMs('cid-elite', 60000), 60000,
        'a multiplier of 0 must NEVER be applied -- server/cooldowns.lua\'s own IsOnCooldown treats a non-positive threshold as PERMANENTLY ON, the opposite of a reward')
end)

t.test('GetXPTierMedkitCooldownMs: a NEGATIVE multiplier is rejected exactly like zero -- the lower bound is a range check (<= 0), not a special-case for 0 alone', function()
    local original = Config.XPTiers[3].medkitCooldownMultiplier
    Config.XPTiers[3].medkitCooldownMultiplier = -0.5
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 60000), 60000,
        'a negative multiplier must never be applied -- it would otherwise LENGTHEN the effective value going into math.floor/math.max below in a way this function\'s own contract forbids, and must never reach server/cooldowns.lua\'s IsOnCooldown as a non-positive threshold either')
    Config.XPTiers[3].medkitCooldownMultiplier = original
end)

t.test('GetXPTierMedkitCooldownMs: a tiny baseCooldownMs with a valid multiplier can never floor to 0 or below -- the math.max(1, ...) floor holds at the extreme', function()
    -- 1ms * 0.75 = 0.75, which math.floor alone would truncate to 0 -- a
    -- 0ms cooldown would hand server/cooldowns.lua's IsOnCooldown a
    -- non-positive threshold, which that file's own header documents as
    -- PERMANENTLY ON (the opposite of an unlock). math.max(1, ...) is what
    -- prevents that at this extreme, not just the multiplier's own <= 0/> 1
    -- rejection above.
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 1), 1, 'must clamp to a minimum of 1ms, never 0')
end)

t.test('GetXPTierMedkitCooldownMs: a malformed baseCooldownMs (non-number, NaN, <= 0) is returned unchanged, never erroring', function()
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', nil), nil)
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 'not-a-number'), 'not-a-number')
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', 0), 0)
    t.equals(GetXPTierMedkitCooldownMs('cid-veteran', -5), -5)
    local nan = 0/0
    local result = GetXPTierMedkitCooldownMs('cid-veteran', nan)
    t.isTrue(result ~= result, 'NaN in, NaN out (NaN ~= NaN is always true for a real Lua number) -- proves the function returned the input unchanged rather than computing on it')
end)

-- ----------------------------------------------------------------------
-- COMPOSITION WITH THE PERMISSION/BLOCK LAYER -- the load-bearing property
-- this task requires: "a tier unlock cannot override a high-command
-- block." See this file's own header for exactly what this section proves
-- and what it does not.
-- ----------------------------------------------------------------------

--- Generic stand-in for the "block check runs before the tier-multiplier
--- consultation" ordering -- see server/progression.lua's own
--- GetXPTierMedkitCooldownMs doc comment, "CALLER CONTRACT", for the real
--- call site this mirrors (that call site is genuinely applied in
--- server/medkit.lua today -- see this file's own header for the full,
--- corrected story). `blocked` simulates whatever per-file
--- feature/block-resolution function ends up gating the real call (there is
--- still no single shared, exported Config.FeatureControl block-resolution
--- function -- each consuming file implements its own) -- this test does
--- not assume its exact name/signature, only that SOME block check exists
--- and runs BEFORE this function is ever consulted, per
--- GetXPTierMedkitCooldownMs's own documented CALLER CONTRACT.
--- @param citizenid string
--- @param blocked boolean
--- @param baseCooldownMs number
--- @return boolean allowed
--- @return number? effectiveCooldownMs -- present only when allowed
local function SimulateGatedMedkitCooldownResolution(citizenid, blocked, baseCooldownMs)
    -- Steps 1-3 of Config.FeatureControl's own documented resolution order
    -- (config.lua: "Config.Features.<Name> false -> deny always; an
    -- explicit BLOCK -> deny; RequireGrant -> needs a grant") ALWAYS run
    -- BEFORE step 4's "otherwise -> allow" -- and this function's own tier
    -- consultation is not even a step in that order at all. It is reached
    -- only once the caller has ALREADY allowed the action.
    if blocked then
        return false, nil -- denied -- GetXPTierMedkitCooldownMs is NEVER called
    end
    return true, GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs)
end

t.test('COMPOSITION: a blocked citizenid is denied outright regardless of tier, and the tier multiplier is never even consulted', function()
    -- cid-veteran (Veteran tier, 0.75 multiplier) would normally get a
    -- reduced cooldown -- prove the block wins outright.
    local allowed, effectiveMs = SimulateGatedMedkitCooldownResolution('cid-veteran', true, 60000)
    t.isFalse(allowed, 'a high-command block must deny the action outright, even for a citizenid who has genuinely earned the Veteran-tier unlock')
    t.isNil(effectiveMs, 'a denied action must produce no cooldown value at all -- there is nothing to apply it to')
end)

t.test('COMPOSITION: an unblocked citizenid still gets their real, earned tier reduction', function()
    local allowed, effectiveMs = SimulateGatedMedkitCooldownResolution('cid-veteran', false, 60000)
    t.isTrue(allowed)
    t.equals(effectiveMs, 45000, 'once genuinely unblocked, the earned Veteran-tier reduction must still apply normally -- a block is the only thing this task asked to take priority, not tier progression itself')
end)

t.test('COMPOSITION: reaching a tier cannot itself flip a block to an allow -- same citizenid, same tier, same base cooldown, differing ONLY by the block flag', function()
    local allowedBlocked = SimulateGatedMedkitCooldownResolution('cid-elite', true, 60000)
    local allowedFree = SimulateGatedMedkitCooldownResolution('cid-elite', false, 60000)
    t.isFalse(allowedBlocked)
    t.isTrue(allowedFree, 'the ONLY variable that changed between the two calls above is the block flag -- cid-elite is genuinely Elite-tier in this fixture in BOTH calls, proving tier alone has no power to override a block either way')
end)

-- ========================================================================
-- HANDLER XP TIER UNLOCKS (dead-config-field pass, coder-backend) --
-- GetHandlerXPTierMedkitCooldownMs/GetHandlerXPTierKennelDeployCooldownMs's
-- own pure numeric contract -- the mirror image of GetXPTierMedkitCooldownMs's
-- own battery above, run against the SEPARATE handler-XP ladder
-- (Config.HandlerXPTiers/AwardHandlerXP/GetHandlerXPTier) instead of the K9
-- one. See server/progression.lua's own doc comment on both functions
-- ("HANDLER XP TIER UNLOCKS" section, immediately after GetHandlerXPTier)
-- for the full feedback-loop-safety writeup this section does not repeat.
-- ========================================================================

t.test('GetHandlerXPTierMedkitCooldownMs: an uncached (base-tier) citizenid with no medkitTreatCooldownMultiplier returns baseCooldownMs unchanged', function()
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-never-seen-before', 60000), 60000)
end)

t.test('GetHandlerXPTierKennelDeployCooldownMs: Certified Handler tier (no kennelDeployCooldownMultiplier field at all) returns baseCooldownMs unchanged -- the "unlock not yet configured" default', function()
    grindTowardHandler('handler-certified', 13) -- 13 * 60 = 780 >= 750 (Certified), < 2500 (Senior)
    t.equals(GetHandlerXPTier('handler-certified').label, 'Certified Handler', 'sanity check on this test\'s own arithmetic')
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-certified', 5000), 5000, 'Certified Handler has no kennelDeployCooldownMultiplier configured -- must return the base value unchanged, never error or invent a number')
end)

t.test('GetHandlerXPTierMedkitCooldownMs: Certified Handler tier (medkitTreatCooldownMultiplier = 0.90) reduces the cooldown', function()
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-certified', 60000), 54000, '60000 * 0.90 = 54000')
end)

t.test('GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs: Senior Handler tier reduces both cooldowns', function()
    grindTowardHandler('handler-senior', 42) -- 42 * 60 = 2520 >= 2500 (Senior), < 6000 (Master)
    t.equals(GetHandlerXPTier('handler-senior').label, 'Senior Handler', 'sanity check on this test\'s own arithmetic')
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-senior', 60000), 48000, '60000 * 0.80 = 48000')
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-senior', 5000), 3750, '5000 * 0.75 = 3750')
end)

-- NOTE ON THIS TEST'S NUMBERS: they are THIS FIXTURE'S ladder (0.70 /
-- 0.60), which is no longer the SHIPPED ladder -- the XP-rebalance pass
-- retuned config.lua's real Master Handler row to 0.50 / 0.45. This test
-- deliberately keeps its own fixture numbers (it is testing the ACCESSOR'S
-- ARITHMETIC, which must not change when a server owner retunes their
-- config); the shipped ladder's own real values are pinned separately by
-- the SHIPPED-CONFIG TRIPWIRE at the bottom of this file, which is what
-- actually fails if config.lua and the doc comments drift apart again.
t.test('GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs: Master Handler tier -- this FIXTURE ladder\'s worst-case floors (31500ms combined medkit, 3000ms kennel); the shipped ladder is pinned separately below', function()
    grindTowardHandler('handler-master', 101) -- 101 * 60 = 6060 >= 6000 (Master), < 20000 (Legendary)
    t.equals(GetHandlerXPTier('handler-master').label, 'Master Handler', 'sanity check on this test\'s own arithmetic')
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', 60000), 42000, '60000 * 0.70 = 42000 -- combined with a Veteran-tier K9 target\'s own 0.75 (GetXPTierMedkitCooldownMs, applied by the caller BEFORE this function per server/medkit.lua\'s real chained call site), the true worst case is 60000 * 0.75 * 0.70 = 31500')
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-master', 5000), 3000, '5000 * 0.60 = 3000 -- this fixture ladder\'s own floor, not the shipped one (see the note above this test)')
end)

t.test('GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs: a multiplier > 1 is rejected on EACH function independently -- an unlock must never LENGTHEN a cooldown', function()
    local originalMedkit = Config.HandlerXPTiers[4].medkitTreatCooldownMultiplier
    local originalKennel = Config.HandlerXPTiers[4].kennelDeployCooldownMultiplier
    Config.HandlerXPTiers[4].medkitTreatCooldownMultiplier = 1.5
    Config.HandlerXPTiers[4].kennelDeployCooldownMultiplier = 2.0
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', 60000), 60000, 'a multiplier > 1 must be rejected outright, never applied')
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-master', 5000), 5000)
    Config.HandlerXPTiers[4].medkitTreatCooldownMultiplier = originalMedkit
    Config.HandlerXPTiers[4].kennelDeployCooldownMultiplier = originalKennel
end)

t.test('GetHandlerXPTierMedkitCooldownMs: a numeric-looking STRING multiplier is rejected -- only a real Lua number may reduce a cooldown', function()
    local original = Config.HandlerXPTiers[4].medkitTreatCooldownMultiplier
    Config.HandlerXPTiers[4].medkitTreatCooldownMultiplier = '0.5'
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', 60000), 60000)
    Config.HandlerXPTiers[4].medkitTreatCooldownMultiplier = original
end)

t.test('GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs: a non-positive or negative multiplier (Legendary tier, this fixture\'s own test-only top row) is rejected -- returns baseCooldownMs unchanged, never 0 or negative', function()
    grindTowardHandler('handler-legendary', 334) -- 334 * 60 = 20040 >= 20000 (Legendary)
    t.equals(GetHandlerXPTier('handler-legendary').label, 'Legendary Handler (test-only)', 'sanity check on this test\'s own arithmetic')
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-legendary', 60000), 60000,
        'a multiplier of 0 must NEVER be applied -- server/cooldowns.lua\'s own IsOnCooldown treats a non-positive threshold as PERMANENTLY ON, the opposite of a reward')
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-legendary', 5000), 5000,
        'a NEGATIVE multiplier must never be applied either -- the lower bound is a range check (<= 0), not a special-case for 0 alone')
end)

t.test('GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs: a tiny baseCooldownMs with a valid multiplier can never floor to 0 or below -- the math.max(1, ...) floor holds at the extreme', function()
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', 1), 1, 'must clamp to a minimum of 1ms, never 0')
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-master', 1), 1, 'must clamp to a minimum of 1ms, never 0')
end)

t.test('GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs: a malformed baseCooldownMs (non-number, NaN, <= 0) is returned unchanged, never erroring', function()
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', nil), nil)
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', 'not-a-number'), 'not-a-number')
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', 0), 0)
    t.equals(GetHandlerXPTierMedkitCooldownMs('handler-master', -5), -5)
    local nan = 0/0
    local result = GetHandlerXPTierMedkitCooldownMs('handler-master', nan)
    t.isTrue(result ~= result, 'NaN in, NaN out -- proves the function returned the input unchanged rather than computing on it')

    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-master', nil), nil)
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-master', 0), 0)
    t.equals(GetHandlerXPTierKennelDeployCooldownMs('handler-master', -5), -5)
end)

t.test('CROSS-LADDER INDEPENDENCE: a citizenid\'s K9-side tier (Config.XPTiers) has no bearing on their HANDLER-side tier (Config.HandlerXPTiers), even when the two totals happen to share a citizenid string', function()
    -- Same citizenid string grinds BOTH ladders to very different tiers --
    -- the K9-XP total (Elite-level, 9000+) must not leak into what
    -- GetHandlerXPTierMedkitCooldownMs sees, and vice versa. Proves
    -- config.lua's own "two independent totals, one row" design actually
    -- holds at the accessor level, not just in the schema.
    grindToward('shared-cid', 151)         -- K9 side: Elite (9000+), medkitCooldownMultiplier = 0 (rejected -> unchanged)
    grindTowardHandler('shared-cid', 13)   -- Handler side: Certified only (780 XP), medkitTreatCooldownMultiplier = 0.90

    t.equals(GetXPTier('shared-cid').label, 'Elite K9')
    t.equals(GetHandlerXPTier('shared-cid').label, 'Certified Handler')
    t.equals(GetXPTierMedkitCooldownMs('shared-cid', 60000), 60000, 'K9 side: Elite\'s own medkitCooldownMultiplier (0) is rejected, unchanged')
    t.equals(GetHandlerXPTierMedkitCooldownMs('shared-cid', 60000), 54000, 'Handler side: Certified\'s own 0.90 still applies normally, unaffected by the K9 side\'s Elite standing')
end)

-- ========================================================================
-- SHIPPED-CONFIG TRIPWIRE (XP-rebalance pass).
--
-- WHY THIS EXISTS. Every other test in this file runs against a FIXTURE
-- ladder, on purpose -- they test the accessor's arithmetic, which must
-- hold for whatever numbers a server owner configures. That is correct, and
-- it is also exactly why the shipped ladder itself went unpinned: three
-- separate doc comments (config.lua's Master Handler block,
-- server/progression.lua's "THE NUMBERS" section, and the SOURCE AUDIT
-- headers in tests/medkit_spec.lua and tests/kennel_spec.lua) quote precise
-- worst-case floors derived from config.lua's REAL multipliers, and nothing
-- in the suite read those real multipliers at all. When the rebalance pass
-- retuned them, all four comments went stale and every test stayed green.
--
-- This test closes that specific hole: it loads the REAL config.lua and
-- asserts the shipped multipliers still produce the exact floors those
-- comments quote. Retune a multiplier in config.lua and this goes RED,
-- naming the comments that need updating with it. It intentionally pins
-- the MULTIPLIERS and the derived floors only -- never the xp thresholds,
-- which are pure server-owner balance and which no comment's arithmetic
-- depends on.
-- ========================================================================

t.test('SHIPPED-CONFIG TRIPWIRE: config.lua\'s real multipliers still produce the exact worst-case floors every doc comment quotes', function()
    local shipped = { Config = { Features = {}, FeatureGroups = {} } }
    shipped._G = shipped
    setmetatable(shipped, { __index = _G })
    Sandbox.loadInto('../config.lua', shipped)

    local k9 = shipped.Config.XPTiers
    local handler = shipped.Config.HandlerXPTiers
    t.isTrue(type(k9) == 'table' and #k9 >= 4, 'sanity: the shipped K9 ladder loaded')
    t.isTrue(type(handler) == 'table' and #handler >= 4, 'sanity: the shipped handler ladder loaded')

    local master = handler[#handler]
    local elite = k9[#k9]
    t.equals(master.label, 'Master Handler', 'sanity: the top handler rank is still the one these floors are derived from')
    t.equals(elite.label, 'Elite K9', 'sanity: the top K9 rank is still the one these floors are derived from')

    -- The two multipliers every quoted floor is derived from.
    t.equals(master.medkitTreatCooldownMultiplier, 0.50,
        'config.lua Master Handler medkitTreatCooldownMultiplier changed -- update the quoted medkit floors in config.lua\'s own Master Handler block, server/progression.lua\'s "THE NUMBERS" section, and tests/medkit_spec.lua\'s SOURCE AUDIT header')
    t.equals(master.kennelDeployCooldownMultiplier, 0.45,
        'config.lua Master Handler kennelDeployCooldownMultiplier changed -- update the quoted kennel floors in config.lua\'s own Master Handler block, server/progression.lua\'s "THE NUMBERS" section, and tests/kennel_spec.lua\'s SOURCE AUDIT header')
    t.equals(elite.medkitCooldownMultiplier, 0.60,
        'config.lua Elite K9 medkitCooldownMultiplier changed -- it is the TARGET-side half of the combined medkit floor, so every quoted combined figure moves with it')

    -- The derived floors themselves, computed the same way server/medkit.lua
    -- and server/kennel.lua compose them (target-side first, then
    -- handler-side), so a drift in either half is caught as an arithmetic
    -- failure and not just a changed constant.
    t.equals(math.floor(60000 * master.medkitTreatCooldownMultiplier), 30000,
        'medkit floor, handler rank alone: the 30000ms every doc comment quotes')
    t.equals(math.floor(60000 * elite.medkitCooldownMultiplier * master.medkitTreatCooldownMultiplier), 18000,
        'medkit floor, combined worst case against an Elite K9 target: the 18000ms every doc comment quotes')
    t.equals(math.floor(5000 * master.kennelDeployCooldownMultiplier), 2250,
        'kennel-deploy floor: the 2250ms every doc comment quotes')

    -- ANTI-FARM SEPARATION, asserted rather than assumed (see
    -- server/progression.lua's BINDING REQUIREMENT note): the dedicated
    -- per-actor MINT cooldowns must stay far above the rank-reduced ACTION
    -- floors above, so deepening a rank multiplier can never speed up
    -- earning. If a future pass shortens a mint cooldown toward these
    -- floors, this fails before the farm ships.
    local function mintMsFrom(path, pattern)
        local handle = assert(io.open(path, 'r'))
        local text = handle:read('a')
        handle:close()
        local expr = text:match(pattern)
        t.isTrue(expr ~= nil, 'could not find the mint cooldown declaration in ' .. path)
        return assert(load('return ' .. expr))()
    end

    local treatMint = mintMsFrom('../server/medkit.lua', 'local%s+TREAT_XP_MINT_COOLDOWN_MS%s*=%s*([^\r\n-]+)')
    local deployMint = mintMsFrom('../server/kennel.lua', 'local%s+KENNEL_DEPLOY_XP_MINT_COOLDOWN_MS%s*=%s*([^\r\n-]+)')
    t.isTrue(treatMint >= 18000 * 20,
        'TREAT_XP_MINT_COOLDOWN_MS (' .. tostring(treatMint) .. 'ms) is no longer far above the 18000ms rank-reduced medkit action floor -- a handler rank could now shorten its own earning rate, the exact loop server/progression.lua\'s BINDING REQUIREMENT note rules out')
    t.isTrue(deployMint >= 2250 * 20,
        'KENNEL_DEPLOY_XP_MINT_COOLDOWN_MS (' .. tostring(deployMint) .. 'ms) is no longer far above the 2250ms rank-reduced kennel-deploy action floor -- same loop, same rule')
end)


-- ========================================================================
-- SHIPPED-LADDER INVARIANTS (mutation-testing pass, 2026-08-31).
--
-- FOUND BY MUTATION TESTING, not by reading: changing the shipped Elite
-- threshold from 9000 to 90 -- and Veteran 4000 to 40, and Trained 1250 to
-- 12500 -- left the ENTIRE 117-file suite green. No test read the shipped
-- thresholds at all.
--
-- THE TRIPWIRE ABOVE DECLINED TO PIN THEM ON PURPOSE, and it was right to:
-- thresholds are "pure server-owner balance", and freezing exact numbers
-- would fight the owner every time they retune. This test does not pin
-- values. It pins the INVARIANTS that must hold whatever numbers anyone
-- picks -- which is what separates a retune from a typo:
--
--   * 9000 -> 8000 is a retune. Still ascending. Stays green.
--   * 9000 -> 90 is a typo. Now lower than Veteran's 4000. Goes RED.
--
-- WHY IT MATTERS BEYOND TIDINESS: server/xptiers.lua ALREADY enforces
-- exactly this (IsStrictlyAscending) on tablet edits and on persisted
-- overrides at boot -- but never on Config.XPTiers itself. So the identical
-- bad value is rejected when typed into the tablet and accepted when typed
-- into config.lua. A non-ascending ladder does not error; it silently makes
-- a rank unreachable, because tier resolution walks the list and takes the
-- highest threshold the player has passed.
-- ========================================================================

t.test('SHIPPED LADDERS: both are strictly ascending, start at 0, and hold plain non-negative integers', function()
    local shipped = { Config = { Features = {}, FeatureGroups = {} } }
    shipped._G = shipped
    setmetatable(shipped, { __index = _G })
    Sandbox.loadInto('../config.lua', shipped)

    local ladders = {
        { name = 'Config.XPTiers (K9)', rows = shipped.Config.XPTiers },
        { name = 'Config.HandlerXPTiers', rows = shipped.Config.HandlerXPTiers },
    }

    for _, ladder in ipairs(ladders) do
        local rows = ladder.rows
        t.isTrue(type(rows) == 'table' and #rows >= 2,
            ('%s must load with at least two ranks'):format(ladder.name))

        t.equals(rows[1].xp, 0,
            ('%s: the first rank must start at 0 xp -- every player begins there, and a ' ..
             'non-zero floor leaves brand-new players with NO rank at all'):format(ladder.name))

        local seen = {}
        for index, tier in ipairs(rows) do
            local xp = tier.xp
            t.isTrue(type(xp) == 'number',
                ('%s rank %d (%s): xp must be a number, got %s')
                    :format(ladder.name, index, tostring(tier.label), type(xp)))
            t.isTrue(xp == xp and xp >= 0 and xp < math.huge,
                ('%s rank %d (%s): xp must be a finite, non-negative number, got %s')
                    :format(ladder.name, index, tostring(tier.label), tostring(xp)))
            t.equals(math.floor(xp), xp,
                ('%s rank %d (%s): xp must be a whole number, got %s')
                    :format(ladder.name, index, tostring(tier.label), tostring(xp)))
            t.isNil(seen[xp],
                ('%s rank %d (%s): two ranks share the threshold %s -- one of them is ' ..
                 'unreachable'):format(ladder.name, index, tostring(tier.label), tostring(xp)))
            seen[xp] = true

            if index > 1 then
                local prev = rows[index - 1]
                t.isTrue(xp > prev.xp,
                    ('%s: %s (%s xp) must sit ABOVE %s (%s xp). A ladder that is not strictly ' ..
                     'ascending silently makes a rank unreachable -- server/xptiers.lua already ' ..
                     'refuses this exact shape from the tablet, and config.lua must meet the ' ..
                     'same bar.')
                        :format(ladder.name, tostring(tier.label), tostring(xp),
                                tostring(prev.label), tostring(prev.xp)))
            end
        end
    end
end)

os.exit(t.summary())
