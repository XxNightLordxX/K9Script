--[[
    tests/progression_spec.lua

    Indirect tests of server/progression.lua's local ResolveTier against the
    REAL, unmodified production file, via the two resource-global entry
    points that actually call it: AwardXP (the only write path to the
    K9XP cache) and GetXPTier (the only tier-lookup accessor). Both are
    exposed globals (no `local`) per that file's own FILE-TO-FILE CONTRACT,
    so this spec never needs to reach into a local directly -- it drives the
    real cache through the real public API, exactly as server/search.lua and
    server/tracking.lua do.

    Loads server/cooldowns.lua into the SAME sandbox env FIRST: progression.lua
    now declares its own file-local `AwardXPCooldown = NewNestedCooldown(500)`
    rate floor (citizenid+actionKey, 500ms) -- same load-order requirement
    fxmanifest.lua's own server_scripts list already documents for every
    other consumer of server/cooldowns.lua. Because of that floor, any test
    below that calls AwardXP more than once for the SAME (citizenid,
    actionKey) pair must advance the fake clock by > 500ms between calls, or
    the 2nd+ call is a silent, by-design no-op -- see each such test's own
    comment.

    Covers: Config.XPTiers boundary resolution (>= vs. just-under a
    threshold), the "unknown/uncached citizenid defaults to the base tier"
    fail-safe, the unknown-actionKey guard, the XPProgression feature-flag
    gate, malformed-citizenid rejection, the tier-crossing outbound event's
    defensive CopyTier (never leaking a live Config.XPTiers[n] reference),
    and the playerDropped cache-eviction fix.

    EIGHTH XP-FARM FIX (this pass, red-team-flagged compound-farm follow-up)
    -- a dedicated section near the bottom of this file covers the NEW
    shared cross-mechanic XP mint budget: the compound-farm ceiling itself
    (round-robining the four REAL shipped mechanics for a full simulated
    hour must not exceed the shared budget, even though their four
    independent per-mechanic ceilings sum higher), the non-positive-
    threshold footgun (IsValidXpMintBudgetParam, a resource-global test seam
    -- see server/progression.lua's own doc comment on it for why a `local`
    validity function needed one), the memory-bounding sweep thread's own
    eviction behavior, and the reconnect-does-not-reset-the-budget property.
    That section uses its own FRESH, independent sandbox (newProgressionFixture,
    with the REAL Config.XP.awards values from config.lua) rather than the
    ONE shared env/Config every test above it already depends on, so it can
    use real production numbers without perturbing any existing test's own
    fictional Config.XP.awards-derived arithmetic (this file's shared
    XP_MINT_BUDGET_STARTER_TOKENS is itself derived from whatever
    Config.XP.awards happens to contain at load time -- see that constant's
    own declaration comment in server/progression.lua).
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

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName()
    return 'john-k9'
end

local function GetPlayers()
    return {} -- no online players to backfill in this spec
end

local capturedTriggerEvents = {}
local function TriggerEvent(eventName, ...)
    capturedTriggerEvents[#capturedTriggerEvents + 1] = { eventName, ... }
end

local function TriggerClientEvent(_eventName, _target, ...) end

-- AwardXP's DB write runs inside its own CreateThread(...) (silent-failure
-- fix: MySQL.insert.await instead of a callback-less MySQL.insert). The
-- stubbed MySQL.insert.await below never yields, so that thread still runs
-- to completion the instant CreateThread is called (resuming a coroutine
-- whose body never hits a Wait() runs it to completion in that one resume,
-- exactly like a plain `fn()` call would) -- no behavior change for any
-- existing test below that relies on the DB write happening synchronously
-- inline.
--
-- EIGHTH-XP-FARM-FIX ADDITION: server/progression.lua's new shared XP mint
-- budget also starts a SECOND, RECURRING
-- `CreateThread(function() while true do Wait(...) ... end end)` sweep
-- thread (memory-bounding -- see that file's own declaration comment) -- the
-- first genuine "while true do Wait(...) ... end" shaped thread this spec
-- has ever needed to sandbox. A plain `fn()` call would infinite-loop
-- forever the instant this spec loads server/progression.lua (Wait() never
-- returns inside a real while-true loop with no real clock). Handled the
-- same way tests/fixtures/sandbox.lua's own newThreadRunner is documented
-- to work, but inlined here (not that shared helper) specifically so the
-- ONE-SHOT DB-write thread keeps running immediately/synchronously at
-- CreateThread-call time, exactly as before: `CreateThread` creates a
-- coroutine and resumes it ONCE right away -- a one-shot body (no Wait())
-- runs to completion on that single resume and is never captured; a
-- recurring body yields at its first Wait() and IS captured, so a later
-- test can advance it deterministically via stepMintBudgetSweep() (no
-- wall-clock delay) to exercise the sweep's own eviction logic directly.
local capturedRecurringThreads = {}
local waitCalls = {} -- every ms value passed to Wait() -- lets a test assert on the sweep's own cadence, not just its effect
local function CreateThread(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        error(('progression_spec.lua: a captured CreateThread body errored: %s'):format(tostring(err)))
    end
    if coroutine.status(co) ~= 'dead' then
        capturedRecurringThreads[#capturedRecurringThreads + 1] = co
    end
end
local function Wait(ms)
    waitCalls[#waitCalls + 1] = ms
    coroutine.yield()
end

--- Resumes every still-alive recurring thread once -- one full sweep pass
--- per call (each thread is already parked at its own Wait(), either from
--- CreateThread's own initial resume or this function's previous call),
--- matching tests/fixtures/sandbox.lua's own newThreadRunner stepping
--- semantics.
local function stepMintBudgetSweep()
    for _, co in ipairs(capturedRecurringThreads) do
        if coroutine.status(co) ~= 'dead' then
            local ok, err = coroutine.resume(co)
            if not ok then
                error(('progression_spec.lua: stepMintBudgetSweep: a captured thread errored: %s'):format(tostring(err)))
            end
        end
    end
end

local playerByCitizenId = {}
local exportsStub = {
    qbx_core = {
        GetPlayerByCitizenId = function(_self, citizenid)
            return playerByCitizenId[citizenid]
        end,
        GetPlayer = function(_self, src)
            for _, p in pairs(playerByCitizenId) do
                if p.PlayerData.source == src then return p end
            end
            return nil
        end,
    },
}

local capturedPrints = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
    capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
end

local MySQLStub = {
    scalar = { await = function(_sql, _params) return nil end }, -- "no row yet" path
    insert = { await = function(_sql, _params) return 1 end },
}

local Config = {
    Features = { XPProgression = true },
    XP = {
        scopePerCitizenidOrJob = 'citizenid',
        awards = {
            smallAward = 60,   -- two of these cross the 100-xp tier boundary
            exact100 = 100,    -- lands exactly ON a tier boundary
            ninetynine = 99,   -- lands exactly one below a tier boundary
            zeroAward = 0,
        },
    },
    XPTiers = {
        { xp = 0,   label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        { xp = 100, label = 'Trained', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        { xp = 500, label = 'Veteran', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
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
    print = printStub,
    MySQL = MySQLStub,
    Config = Config,
})

-- progression.lua's own file-local AwardXPCooldown = NewNestedCooldown(500)
-- needs the real constructor in scope at progression.lua's own load time --
-- same load-order requirement as server/admin.lua.
Sandbox.loadInto('../server/cooldowns.lua', env)
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/progression.lua's own
-- LoadXPForCitizenid/AwardXP/AwardXPDirect now read/write through
-- K9Store.XP_Get/K9Store.XP_UpsertAdd rather than raw SQL). Config.Database
-- is deliberately absent from this fixture's Config table above --
-- K9Store's own DatabaseEnabled() fails safe to `true` (real-DB mode) on a
-- missing Config.Database, which is exactly what makes those K9Store
-- calls run the SAME MySQL.scalar.await/MySQL.insert.await calls (against
-- this fixture's own MySQLStub) built directly before this migration, so
-- every existing assertion below keeps exercising the identical
-- SQL/params shape unchanged. See tests/admin_spec.lua for the precedent
-- this comment mirrors.
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
Sandbox.loadInto('../server/progression.lua', env)

for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('john-k9')
end

local AwardXP = env.AwardXP
local GetXPTier = env.GetXPTier
local GetXP = env.GetXP

t.isNotNil(AwardXP, 'server/progression.lua must define global AwardXP')
t.isNotNil(GetXPTier, 'server/progression.lua must define global GetXPTier')
t.isNotNil(GetXP, 'server/progression.lua must define global GetXP')

--- Advances the fake clock past AwardXPCooldown's 500ms per-(citizenid,
--- actionKey) rate floor -- see this file's header. Needed between any two
--- AwardXP calls in the same test that reuse the same citizenid+actionKey
--- pair and are meant to BOTH actually apply.
local function advancePastRateFloor()
    fakeNow = fakeNow + 501
end

-- ----------------------------------------------------------------------
-- ResolveTier via GetXPTier: uncached / baseline behavior
-- ----------------------------------------------------------------------

t.test('GetXPTier: an uncached citizenid defaults to the base tier (xp=0), never nil', function()
    local tier = GetXPTier('never-seen-before')
    t.isNotNil(tier)
    t.equals(tier.label, 'Recruit')
end)

t.test('GetXP: an uncached citizenid reads back as 0', function()
    t.equals(GetXP('never-seen-before-2'), 0)
end)

-- ----------------------------------------------------------------------
-- ResolveTier boundary behavior via AwardXP-driven accumulation
-- ----------------------------------------------------------------------

t.test('ResolveTier: exactly AT a tier boundary (xp >= tier.xp) resolves to that tier, not the one below', function()
    AwardXP('cid-exact-100', 'exact100')
    t.equals(GetXP('cid-exact-100'), 100)
    t.equals(GetXPTier('cid-exact-100').label, 'Trained', 'xp == 100 must resolve to Trained (>=), not Recruit')
end)

t.test('ResolveTier: one XP below a tier boundary stays on the lower tier', function()
    AwardXP('cid-ninetynine', 'ninetynine')
    t.equals(GetXP('cid-ninetynine'), 99)
    t.equals(GetXPTier('cid-ninetynine').label, 'Recruit', 'xp == 99 must NOT reach Trained (threshold is 100)')
end)

t.test('ResolveTier: accumulation across multiple AwardXP calls crosses a tier boundary', function()
    AwardXP('cid-accum', 'smallAward') -- 60
    t.equals(GetXPTier('cid-accum').label, 'Recruit')
    advancePastRateFloor() -- same citizenid+actionKey pair -- must clear the 500ms rate floor
    AwardXP('cid-accum', 'smallAward') -- 120
    t.equals(GetXP('cid-accum'), 120)
    t.equals(GetXPTier('cid-accum').label, 'Trained', '60+60=120 must cross the 100-xp boundary into Trained')
end)

t.test('ResolveTier: a high accumulated total resolves to the top tier, not the first match', function()
    -- EIGHTH-XP-FARM-FIX INTERACTION: the shared cross-mechanic XP mint
    -- budget (server/progression.lua) now also gates this loop's 10 calls
    -- for the SAME citizenid -- unrelated to what THIS test actually checks
    -- (ResolveTier's ascending tier walk), but real and unconditional (the
    -- budget has no per-test/per-Config opt-out, by design -- see that
    -- section's own "FILE-LOCAL CONSTANTS, NOT CONFIG KEYS" comment).
    -- Advances the clock by far more than advancePastRateFloor()'s own
    -- 501ms between each award specifically so the real
    -- XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS refill rate (1 XP per
    -- 1000ms, hardcoded in server/progression.lua, independent of this
    -- spec's own Config.XP.awards values) keeps pace with this loop's
    -- 100-XP-per-call demand, isolating ResolveTier's own tier-walk logic
    -- from the separate budget concern (covered on its own, with the REAL
    -- shipped award table and cadence, in the EIGHTH-XP-FARM-FIX section
    -- below).
    for _ = 1, 10 do
        AwardXP('cid-veteran', 'exact100') -- 10 * 100 = 1000
        fakeNow = fakeNow + 500000 -- comfortably clears both the 500ms rate floor and the shared mint budget's own refill needs
    end
    t.equals(GetXP('cid-veteran'), 1000)
    t.equals(GetXPTier('cid-veteran').label, 'Veteran', 'must keep walking to the LAST tier whose xp threshold is met')
end)

-- ----------------------------------------------------------------------
-- AwardXP guard rails
-- ----------------------------------------------------------------------

t.test('AwardXP: an unknown actionKey is a safe no-op (logged, never crashes, never grants XP)', function()
    AwardXP('cid-unknown-action', 'thisActionKeyDoesNotExist')
    t.equals(GetXP('cid-unknown-action'), 0)
    local found = false
    for _, line in ipairs(capturedPrints) do
        if line:find('unknown actionKey', 1, true) then found = true end
    end
    t.isTrue(found, 'an unknown actionKey must be logged to console, not silently swallowed')
end)

t.test('AwardXP: a non-string citizenid is a safe no-op', function()
    AwardXP(12345, 'smallAward')
    -- Real assertions, not merely "this line does not throw" (which
    -- t.test's own pcall wrapper already guarantees on its own): a numeric
    -- citizenid must not silently coerce into a string-keyed award under
    -- either the raw numeric key or its string form -- both must read back
    -- as untouched.
    t.equals(GetXP(12345), 0, 'a non-string citizenid must never accumulate XP under its own raw (numeric) key')
    t.equals(GetXP(tostring(12345)), 0, 'a non-string citizenid must never be silently coerced into a string key either')
end)

t.test('AwardXP: an empty-string citizenid is a safe no-op', function()
    AwardXP('', 'smallAward')
    t.equals(GetXP(''), 0)
end)

t.test('AwardXP: is a hard no-op while Config.Features.XPProgression is false', function()
    Config.Features.XPProgression = false
    AwardXP('cid-flag-off', 'smallAward')
    t.equals(GetXP('cid-flag-off'), 0, 'no XP may be granted while the feature flag is off')
    Config.Features.XPProgression = true
    -- The flag-off call above returned before ever touching AwardXPCooldown
    -- (the flag check runs first), so this second call is NOT rate-floored
    -- by it -- it is a genuinely fresh first attempt for this citizenid.
    AwardXP('cid-flag-off', 'smallAward')
    t.equals(GetXP('cid-flag-off'), 60, 'once re-enabled, the SAME citizenid must be able to earn XP normally')
end)

t.test('AwardXP: the per-(citizenid, actionKey) rate floor silently no-ops an immediate repeat', function()
    AwardXP('cid-ratefloor', 'smallAward')
    t.equals(GetXP('cid-ratefloor'), 60)
    AwardXP('cid-ratefloor', 'smallAward') -- same citizenid+actionKey, no clock advance
    t.equals(GetXP('cid-ratefloor'), 60, 'an immediate repeat of the same (citizenid, actionKey) must be rate-floored, not double-applied')
    local found = false
    for _, line in ipairs(capturedPrints) do
        if line:find('rate floor tripped', 1, true) then found = true end
    end
    t.isTrue(found, 'a rate-floor trip must be logged to console')
end)

t.test('AwardXP: the rate floor is per-actionKey, not a blanket per-citizenid floor', function()
    -- Mirrors server/tenure.lua's own documented legitimate case: several
    -- DIFFERENT actionKeys for the same citizenid in the same instant must
    -- all still apply.
    AwardXP('cid-multikey', 'smallAward')
    AwardXP('cid-multikey', 'exact100') -- different actionKey, same instant -- must NOT be floored
    t.equals(GetXP('cid-multikey'), 160, 'a different actionKey for the same citizenid must not share the floor')
end)

-- ----------------------------------------------------------------------
-- CopyTier defensive copy: a tier-crossing event must never leak a live
-- reference to the shared Config.XPTiers[n] table.
-- ----------------------------------------------------------------------

t.test('AwardXP: a tier crossing fires the outbound event with COPIES, never the live Config.XPTiers[n] reference', function()
    capturedTriggerEvents = {}
    AwardXP('cid-copytier', 'exact100') -- crosses 0 -> 100, Recruit -> Trained
    t.equals(GetXPTier('cid-copytier').label, 'Trained')

    local firedEvent = nil
    for _, event in ipairs(capturedTriggerEvents) do
        if event[1] == 'john-k9:events:xpTierReached' then firedEvent = event end
    end
    t.isNotNil(firedEvent, 'a real tier crossing must fire john-k9:events:xpTierReached')

    local newTierArg = firedEvent[3]
    t.equals(newTierArg.label, 'Trained')
    t.isTrue(newTierArg ~= Config.XPTiers[2],
        'the event payload must be a COPY -- handing out the live Config.XPTiers[2] table would let an external ' ..
        'resource mutate speedMultiplier/scentRangeMultiplier for every K9 in that tier, server-wide')

    -- Mutating the copy must never affect the real config table.
    newTierArg.speedMultiplier = 999
    t.equals(Config.XPTiers[2].speedMultiplier, 1.05, 'mutating the event payload copy must not corrupt the real Config.XPTiers entry')
end)

-- ----------------------------------------------------------------------
-- playerDropped cache eviction (bounded-memory-growth fix)
-- ----------------------------------------------------------------------

t.test('playerDropped: evicts the disconnecting source\'s K9XP cache entry', function()
    AwardXP('cid-dropper', 'exact100')
    t.equals(GetXP('cid-dropper'), 100)

    playerByCitizenId['cid-dropper'] = { PlayerData = { citizenid = 'cid-dropper', source = 777 } }
    env.source = 777
    for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
        handler('some reason')
    end

    t.equals(GetXP('cid-dropper'), 0, 'K9XP cache entry must be evicted on disconnect, resetting to the uncached baseline')
end)

-- ----------------------------------------------------------------------
-- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass, this pass) -- mirrors
-- tests/certifications_spec.lua's identical section for
-- RefreshCertificationCache; proven here against LoadXPForCitizenid's own
-- copy of the fix. LoadXPForCitizenid is `local`, unreachable directly --
-- driven the same way a real caller does, by firing the captured
-- 'QBCore:Server:PlayerLoaded' handler directly (mirrors the playerDropped
-- eviction test immediately above).
-- ----------------------------------------------------------------------

t.test('COULD-NOT-DETERMINE: PlayerLoaded for a citizenid with no prior cached XP, but a throwing MySQL.scalar.await, never manufactures a confirmed 0', function()
    -- PlayerLoaded ALSO unconditionally warms the SEPARATE HandlerXP cache
    -- (LoadHandlerXPForCitizenid, `SELECT handler_xp ...`) via this SAME
    -- MySQL.scalar.await -- filtered out here by SQL text so this test
    -- forces a failure on LoadXPForCitizenid's own `SELECT xp ...` query
    -- ONLY, never that unrelated one.
    local realScalarAwait = MySQLStub.scalar.await
    MySQLStub.scalar.await = function(sql, params)
        if sql:find('SELECT xp ', 1, true) then error('connection lost') end
        return realScalarAwait(sql, params)
    end

    playerByCitizenId['cid-cnd1'] = { PlayerData = { citizenid = 'cid-cnd1', source = 801 } }
    for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do
        handler(playerByCitizenId['cid-cnd1'])
    end

    t.equals(GetXP('cid-cnd1'), 0, 'with nothing known at all, the best-effort DISPLAY value degrades to 0 (base tier), same as an uncached citizenid')

    local sawCheckFailed, sawHedged = false, false
    for _, line in ipairs(capturedPrints) do
        if line:find('cid-cnd1', 1, true) and line:find('XP CHECK FAILED', 1, true) then sawCheckFailed = true end
        if line:find('cid-cnd1', 1, true) and line:find('persisted XP in the', 1, true) then sawHedged = true end
    end
    t.isTrue(sawCheckFailed, 'the operator message must name the citizenid and say the CHECK failed')
    t.isTrue(sawHedged, 'the operator message must reassure that persisted XP is unaffected, never claim a confirmed 0')

    -- Proves nothing false was durably written: a later successful award
    -- must accumulate from the REAL prior total (0, since this citizenid
    -- never actually had a k9_progression row), not from some corrupted
    -- state left behind by the failed read.
    MySQLStub.scalar.await = realScalarAwait
    AwardXP('cid-cnd1', 'exact100')
    t.equals(GetXP('cid-cnd1'), 100, 'a later successful award must apply cleanly with no lingering effect from the earlier failed read')
end)

t.test('COULD-NOT-DETERMINE: a throwing re-read for an ALREADY-CACHED citizenid KEEPS the previous XP total, never resets to 0', function()
    playerByCitizenId['cid-cnd2'] = { PlayerData = { citizenid = 'cid-cnd2', source = 802 } }
    -- First PlayerLoaded succeeds normally (no row yet -> 0, matching the
    -- "no row yet = 0 XP" doc comment), then a real award establishes a
    -- known, non-zero total this test can prove survives the outage below.
    for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do
        handler(playerByCitizenId['cid-cnd2'])
    end
    AwardXP('cid-cnd2', 'exact100')
    t.equals(GetXP('cid-cnd2'), 100, 'sanity: really has 100 XP cached before the simulated outage')

    -- A SECOND PlayerLoaded for the SAME, still-connected citizenid (no
    -- intervening disconnect) re-triggers LoadXPForCitizenid -- forced to
    -- fail here to simulate a transient blip on that specific re-read
    -- (filtered by SQL text -- see the sibling test above for why the
    -- separate HandlerXP read must stay unaffected).
    local realScalarAwait = MySQLStub.scalar.await
    MySQLStub.scalar.await = function(sql, params)
        if sql:find('SELECT xp ', 1, true) then error('connection lost') end
        return realScalarAwait(sql, params)
    end
    for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do
        handler(playerByCitizenId['cid-cnd2'])
    end

    t.equals(GetXP('cid-cnd2'), 100, 'the previously-cached total must survive a transient read failure, never reset to 0')

    local sawCheckFailed, sawKept = false, false
    for _, line in ipairs(capturedPrints) do
        if line:find('cid-cnd2', 1, true) and line:find('XP CHECK FAILED', 1, true) then sawCheckFailed = true end
        if line:find('cid-cnd2', 1, true) and line:find('KEEPING the previous cached total', 1, true) then sawKept = true end
    end
    t.isTrue(sawCheckFailed, 'the operator message must name the citizenid and say the CHECK failed')
    t.isTrue(sawKept, 'the operator message must say the previous total was kept, not that it was reset')

    MySQLStub.scalar.await = realScalarAwait
end)

t.test('COULD-NOT-DETERMINE: the retry is BOUNDED, not infinite -- exactly XP_LOAD_RETRY_ATTEMPTS (3) attempts, then gives up', function()
    playerByCitizenId['cid-cnd3'] = { PlayerData = { citizenid = 'cid-cnd3', source = 803 } }
    local scalarCallCount = 0
    local realScalarAwait = MySQLStub.scalar.await
    MySQLStub.scalar.await = function(sql, params)
        if sql:find('SELECT xp ', 1, true) then
            scalarCallCount = scalarCallCount + 1
            error('connection lost')
        end
        return realScalarAwait(sql, params)
    end

    for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do
        handler(playerByCitizenId['cid-cnd3'])
    end

    t.equals(scalarCallCount, 3, 'must attempt exactly the bounded number of times -- never once (no retry) and never unboundedly')
    t.equals(GetXP('cid-cnd3'), 0)

    MySQLStub.scalar.await = realScalarAwait
end)

t.test('EIGHTH XP-FARM FIX: the shared env\'s own mint-budget sweep thread (created at server/progression.lua\'s own load time, captured by this file\'s CreateThread stub above) can be stepped without erroring', function()
    -- Distinct from the fresh, independently-constructed fixtures the
    -- dedicated EIGHTH-XP-FARM-FIX section below uses -- this is the ONE
    -- sweep thread tied to the SAME env every other test in this file
    -- shares, exercised here at least once so it is not merely
    -- load-and-forget. Advances the shared clock well past a full
    -- XP_MINT_BUDGET_WINDOW_MS of total inactivity for every citizenid this
    -- shared env has touched so far, then steps the sweep once.
    fakeNow = fakeNow + 3600001
    local ok = pcall(stepMintBudgetSweep)
    t.isTrue(ok, 'the shared env\'s own mint-budget sweep thread must run a pass without erroring')
end)

-- ============================================================================
-- EIGHTH XP-FARM FIX: shared cross-mechanic XP mint budget
-- (server/progression.lua's XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS/
-- XP_MINT_BUDGET_STARTER_TOKENS, consulted inside AwardXP). See this file's
-- own header for why this section builds its own FRESH sandbox instead of
-- reusing the shared `env` above.
-- ============================================================================

--- Builds a fresh, independent sandbox for server/progression.lua -- its own
--- Config (with the REAL shipped Config.XP.awards/Config.XPTiers values from
--- config.lua, not this file's shared toy award table), its own K9XP/
--- XPMintBudget/AwardXPCooldown state, its own fake clock, and its own
--- CreateThread/Wait capture for the mint-budget sweep thread (identical
--- coroutine-capture technique to the one this file's shared `CreateThread`
--- above already uses, and for the exact same reason -- see that one's own
--- declaration comment for the full writeup: a plain `fn()` call would
--- infinite-loop on the sweep thread's `while true do Wait(...) ... end`).
--- @return table fixture
--- @param opts table? { featureControl: table?, hasPermissionFn: function?, withHasPermission: boolean? } -- PER-PERSON FEATURE CONTROL knobs, this pass. Every existing call site passes no opts at all and is unaffected (opts defaults to {}, HasPermission defaults to present-but-always-false, matching this fixture's pre-existing behavior of never defining HasPermission at all -- see IsXPProgressionPermittedForCitizenId's own `type(HasPermission) == 'function'` soft-dependency guard, which treats "absent" and "present but returns false" identically for every existing test's own default-allow expectations).
local function newProgressionFixture(opts)
    opts = opts or {}
    local fakeNow2 = 0
    local function GetGameTimer2() return fakeNow2 end

    local eventHandlers2 = {}
    local function AddEventHandler2(eventName, handler)
        eventHandlers2[eventName] = eventHandlers2[eventName] or {}
        eventHandlers2[eventName][#eventHandlers2[eventName] + 1] = handler
    end

    local function GetCurrentResourceName2() return 'john-k9' end
    local function GetPlayers2() return {} end
    local function TriggerEvent2(_eventName, ...) end
    local function TriggerClientEvent2(_eventName, _target, ...) end

    local capturedRecurringThreads2 = {}
    local function CreateThread2(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newProgressionFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
        if coroutine.status(co) ~= 'dead' then
            capturedRecurringThreads2[#capturedRecurringThreads2 + 1] = co
        end
    end
    local function Wait2(_ms) coroutine.yield() end
    local function stepSweep2()
        for _, co in ipairs(capturedRecurringThreads2) do
            if coroutine.status(co) ~= 'dead' then
                local ok, err = coroutine.resume(co)
                if not ok then
                    error(('newProgressionFixture: stepSweep: a captured thread errored: %s'):format(tostring(err)))
                end
            end
        end
    end

    local printedLines2 = {}
    local function printStub2(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines2[#printedLines2 + 1] = table.concat(parts, '\t')
    end

    local playerByCitizenId2 = {}
    local exportsStub2 = {
        qbx_core = {
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId2[citizenid] end,
            GetPlayer = function(_self, src)
                for _, p in pairs(playerByCitizenId2) do
                    if p.PlayerData.source == src then return p end
                end
                return nil
            end,
        },
    }

    local MySQLStub2 = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    -- REAL shipped values (config.lua) -- not this file's shared toy table.
    -- awards match Config.XP.awards exactly, INCLUDING the three
    -- partnershipTenure milestone keys -- not just the four mechanics this
    -- pass's own red-team finding named -- because
    -- XP_MINT_BUDGET_STARTER_TOKENS (server/progression.lua) sums EVERY
    -- Config.XP.awards value, and this section's own numbers must match
    -- that real 240-XP sum (25+10+20+30+15+40+100), not a partial one.
    -- XPTiers match Config.XPTiers exactly (0/1250/4000/9000) so this
    -- section's own Elite-tier assertions are directly comparable to the
    -- real economy, not an analogy.
    local Config2 = {
        Features = { XPProgression = true },
        XP = {
            scopePerCitizenidOrJob = 'citizenid',
            -- CONFIG-ABORT REGRESSION knob (this pass): opts.xpAwards lets a
            -- test substitute a MALFORMED Config.XP.awards table (a value
            -- above XP_MINT_BUDGET_CAP_XP, or negative) to prove
            -- ValidateXPAwardAmount clamps and warns instead of throwing --
            -- defaults to the real shipped award table for every other,
            -- pre-existing test that never passes this option.
            awards = opts.xpAwards or {
                searchContrabandFound  = 25,
                trackSourceResolved    = 10,
                biteHoldSuccess        = 20,
                takedownSuccess        = 30,
                partnershipTenure1Day  = 15,
                partnershipTenure7Day  = 40,
                partnershipTenure30Day = 100,
            },
        },
        -- CONFIG-ABORT REGRESSION knob (this pass): opts.xpTiers lets a test
        -- substitute a MALFORMED Config.XPTiers table to prove
        -- GetValidatedXPTiers clamps and warns instead of throwing --
        -- defaults to the real shipped tier ladder for every other,
        -- pre-existing test that never passes this option.
        XPTiers = opts.xpTiers or {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
            { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20 },
        },
        -- HIGH COMMAND COOLDOWN-MULTIPLIER BYPASS section (this pass) knob --
        -- nil unless a test opts in, mirroring opts.xpTiers/opts.xpAwards
        -- immediately above; every pre-existing test in this file that never
        -- passes opts.handlerXpTiers continues to load a Config2 with no
        -- Config.HandlerXPTiers at all, unaffected.
        HandlerXPTiers = opts.handlerXpTiers,
    }

    -- PER-PERSON FEATURE CONTROL fixture knob (this pass) -- nil unless a
    -- test opts in, mirroring pursuitsprint_spec.lua's own
    -- `opts.requireGrantListed` shape.
    Config2.FeatureControl = opts.featureControl

    -- HasPermission is a GLOBAL in production (server/permissions.lua),
    -- soft-dependency-guarded (`type(HasPermission) == 'function'`) by
    -- server/progression.lua's own IsXPProgressionPermittedForCitizenId --
    -- present by default here (always returning false, i.e. "never
    -- blocked, no grant held"), settable per test via opts.hasPermissionFn,
    -- and omittable entirely via opts.withHasPermission = false.
    local function defaultHasPermission2(citizenid, key)
        if type(opts.hasPermissionFn) == 'function' then
            return opts.hasPermissionFn(citizenid, key)
        end
        return false
    end

    local envOverrides2 = {
        GetGameTimer = GetGameTimer2,
        AddEventHandler = AddEventHandler2,
        GetCurrentResourceName = GetCurrentResourceName2,
        GetPlayers = GetPlayers2,
        TriggerEvent = TriggerEvent2,
        TriggerClientEvent = TriggerClientEvent2,
        CreateThread = CreateThread2,
        Wait = Wait2,
        exports = exportsStub2,
        print = printStub2,
        MySQL = MySQLStub2,
        Config = Config2,
    }
    if opts.withHasPermission ~= false then
        envOverrides2.HasPermission = defaultHasPermission2
    end
    -- server/permissions.lua's IsHighCommandBypassCitizenId -- HIGH COMMAND
    -- COOLDOWN-MULTIPLIER BYPASS section (this pass). Same
    -- OMITTED-ENTIRELY-unless-supplied soft-dependency treatment as
    -- HasPermission above/GetCertificationTier in tests/certtiers_spec.lua:
    -- a real server always has server/permissions.lua loaded, but this
    -- fixture exercises server/progression.lua's own
    -- `type(IsHighCommandBypassCitizenId) == 'function'` guard directly, via
    -- a plain citizenid -> boolean stub (the real function's own shape),
    -- without booting server/permissions.lua/server/highcommand.lua for real.
    if opts.isHighCommandBypassCitizenId then
        envOverrides2.IsHighCommandBypassCitizenId = opts.isHighCommandBypassCitizenId
    end

    local env2 = Sandbox.newEnv(envOverrides2)

    Sandbox.loadInto('../server/cooldowns.lua', env2)
    -- server/datastore.lua -- REAL, unmodified, loaded alongside (see this
    -- file's own top-of-file loadInto comment above for the full
    -- reasoning). Config2.Database is deliberately absent, so
    -- DatabaseEnabled() fails safe to `true` and every K9Store.XP_* call
    -- forwards straight through to MySQLStub2 exactly as before this
    -- migration.
    Sandbox.loadInto('../server/datastore.lua', env2)
    Sandbox.loadInto('../server/events.lua', env2) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    Sandbox.loadInto('../server/progression.lua', env2)
    for _, handler in ipairs(eventHandlers2['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env2,
        AwardXP = env2.AwardXP,
        AwardXPDirect = env2.AwardXPDirect,
        GetXP = env2.GetXP,
        GetXPTier = env2.GetXPTier,
        GetHandlerXPTier = env2.GetHandlerXPTier,
        GetXPTierMedkitCooldownMs = env2.GetXPTierMedkitCooldownMs,
        GetHandlerXPTierMedkitCooldownMs = env2.GetHandlerXPTierMedkitCooldownMs,
        GetHandlerXPTierKennelDeployCooldownMs = env2.GetHandlerXPTierKennelDeployCooldownMs,
        printedLines = printedLines2,
        setNow = function(ms) fakeNow2 = ms end,
        now = function() return fakeNow2 end,
        stepSweep = stepSweep2,
        firePlayerDropped = function(citizenid, src)
            playerByCitizenId2[citizenid] = { PlayerData = { citizenid = citizenid, source = src } }
            env2.source = src
            for _, handler in ipairs(eventHandlers2['playerDropped'] or {}) do
                handler('some reason')
            end
        end,
    }
end

--- Drives AwardXP for a single citizenid using the four REAL shipped mint
--- cadences (server/combat.lua's BiteHoldXpMintCooldown/
--- TakedownXpMintCooldown, server/search.lua's ContrabandXpMintCooldown --
--- all 60000ms -- and server/tracking.lua's TrackTicketMintCooldown --
--- 30000ms) round-robined together from t=0 up to `toMs` -- the exact
--- compound-farm shape the red-team finding described. This spec calls
--- AwardXP directly (server/combat.lua/search.lua/tracking.lua are not
--- loaded here) -- the shared budget lives entirely inside AwardXP itself,
--- so driving it directly exercises the REAL production gate with no
--- re-implementation. Always starts a FRESH simulation from t=0 for
--- whichever citizenid is passed in (never resumes a prior partial run),
--- so two different `toMs` checkpoints are driven as two independent calls
--- with two different citizenids, never as one paused-and-resumed run.
---
--- BUILDS ONE TIME-SORTED EVENT LIST, deliberately NOT two separate
--- sequential `for` loops (an earlier draft of this helper did exactly
--- that, and it produced a real, subtle bug: the SECOND loop's `f.setNow`
--- calls "rewind" fakeNow backward relative to the first loop's final
--- timestamp before climbing again, and RefillMintBudget's own `elapsed <=
--- 0` guard -- correct, deliberate wraparound-safety behavior, matching
--- server/cooldowns.lua's own documented caveat -- then skips EVERY refill
--- for nearly the entire second loop, since `now` never exceeds the frozen
--- `lastRefillAt` from the end of the first loop until the very last
--- iteration. That silently starved the track-mechanic half of this
--- round-robin of almost all its real refill share). A single event list,
--- sorted once by timestamp, keeps fakeNow genuinely monotonic across the
--- whole simulated hour, exactly like a real server's clock.
--- @param f table
--- @param citizenid string
--- @param toMs number
--- @return number uncappedTotal -- what the four independent per-mechanic ceilings would have summed to, ignoring the shared budget entirely
local function roundRobinRealMechanics(f, citizenid, toMs)
    local events = {}
    for tms = 60000, toMs, 60000 do
        events[#events + 1] = { tms, 'biteHoldSuccess',       20 }
        events[#events + 1] = { tms, 'takedownSuccess',       30 }
        events[#events + 1] = { tms, 'searchContrabandFound', 25 }
    end
    for tms = 30000, toMs, 30000 do
        events[#events + 1] = { tms, 'trackSourceResolved', 10 }
    end
    for i, ev in ipairs(events) do ev[4] = i end -- stable tie-break: preserve insertion order for same-timestamp events
    table.sort(events, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[4] < b[4]
    end)

    local uncappedTotal = 0
    for _, ev in ipairs(events) do
        f.setNow(ev[1])
        f.AwardXP(citizenid, ev[2])
        uncappedTotal = uncappedTotal + ev[3]
    end
    return uncappedTotal
end

t.test('EIGHTH XP-FARM FIX: round-robining all four REAL award mechanics (biteHoldSuccess/takedownSuccess/searchContrabandFound/trackSourceResolved) at their real shipped cadence for one full simulated hour is capped at the shared budget, NOT the four independent per-mechanic ceilings\' uncapped sum', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-compound-farm'

    local uncappedTotal = roundRobinRealMechanics(f, citizenid, 3600000)

    t.equals(uncappedTotal, 5700, 'sanity check on this test\'s own arithmetic -- the four independent per-mechanic ceilings really do sum to 5,700 XP/hr uncapped, matching this pass\'s own report')
    t.equals(f.GetXP(citizenid), 3810, 'the shared budget (3,600 XP/hr cap + a 240-XP one-time starter allowance -- see XP_MINT_BUDGET_STARTER_TOKENS\'s own comment) is the binding constraint, not the uncapped 5,700 XP/hr sum -- exact value re-verified by direct simulation before asserting it here, not guessed')
    t.isTrue(f.GetXP(citizenid) < uncappedTotal, 'the compound farm must be measurably closed, not merely renamed')
end)

t.test('EIGHTH XP-FARM FIX: the REAL combined ceiling still comfortably clears config.lua\'s own ">2 hours to Elite" retuning goal', function()
    -- Two INDEPENDENT fixtures/citizenids, each a fresh from-t=0 simulation
    -- to its own checkpoint -- see roundRobinRealMechanics's own doc comment
    -- for why this is simpler and less error-prone than pausing one
    -- simulation partway through to check an interim state.
    local fAt2h = newProgressionFixture()
    roundRobinRealMechanics(fAt2h, 'cid-elite-at-2h', 7200000)
    t.isTrue(fAt2h.GetXP('cid-elite-at-2h') < 9000, 'at exactly 2 hours of maximal round-robin farming, Elite (9,000 XP) must NOT yet be reached -- this is the floor this whole fix exists to restore')
    t.equals(fAt2h.GetXPTier('cid-elite-at-2h').label, 'Veteran K9', 'still Veteran, not Elite, at the 2-hour mark')

    local fAt25h = newProgressionFixture()
    roundRobinRealMechanics(fAt25h, 'cid-elite-at-2.5h', 9000000)
    t.isTrue(fAt25h.GetXP('cid-elite-at-2.5h') >= 9000, 'by 2.5 simulated hours of maximal four-mechanic round-robin farming, Elite (9,000 XP) must be reached -- matching this pass\'s own report of ~2.44h as the real worst-case time')
    t.equals(fAt25h.GetXPTier('cid-elite-at-2.5h').label, 'Elite K9')
end)

t.test('EIGHTH XP-FARM FIX FOOTGUN: IsValidXpMintBudgetParam (the exact validity check the shared budget\'s fail-OPEN decision is built on) rejects 0/negative/nil/NaN and accepts a real positive number', function()
    -- Resource-global test seam (server/progression.lua's own doc comment on
    -- IsValidXpMintBudgetParam explains why one was needed here) -- this
    -- file's shared `env` from the top of this file already has it, no new
    -- sandbox required. See server/progression.lua's own XPMintBudgetEnabled
    -- comment for why this section cannot ALSO drive AwardXP's actual
    -- disabled/fail-open code path from here: XP_MINT_BUDGET_CAP_XP/
    -- XP_MINT_BUDGET_WINDOW_MS are file-local Lua literals (deliberately not
    -- Config-driven -- same "FILE-LOCAL CONSTANT, NOT A CONFIG KEY" posture
    -- as every per-mechanic mint cooldown), so no test, real config, or
    -- runtime input can ever inject a bad value into them the way
    -- server/cooldowns.lua's own Config-driven thresholds can be tested end
    -- to end -- pinning the validity function itself (the ONLY moving part
    -- this fail-open decision actually depends on) is the most direct
    -- coverage structurally possible for this footgun without adding a
    -- production behavior change purely to make it more testable.
    local IsValidXpMintBudgetParam = env.IsValidXpMintBudgetParam
    t.isNotNil(IsValidXpMintBudgetParam, 'server/progression.lua must define global IsValidXpMintBudgetParam')

    t.isFalse(IsValidXpMintBudgetParam(0), '0 must never mean "no budget enforced" -- see server/cooldowns.lua\'s own identical rejection for the historical reason why')
    t.isFalse(IsValidXpMintBudgetParam(-1))
    t.isFalse(IsValidXpMintBudgetParam(-3600))
    t.isFalse(IsValidXpMintBudgetParam(nil))
    t.isFalse(IsValidXpMintBudgetParam('3600'), 'a numeric-looking STRING must not silently pass -- only a real Lua number')
    t.isFalse(IsValidXpMintBudgetParam(0/0), 'NaN must be rejected -- `value > 0` alone does NOT catch it (every comparison against NaN is false), which would otherwise fail OPEN by accident')
    t.isTrue(IsValidXpMintBudgetParam(3600), 'the real shipped XP_MINT_BUDGET_CAP_XP value must pass')
    t.isTrue(IsValidXpMintBudgetParam(3600000), 'the real shipped XP_MINT_BUDGET_WINDOW_MS value must pass')
    t.isTrue(IsValidXpMintBudgetParam(0.5), 'any finite positive number is valid, not just integers')
end)

--- Drains a fresh citizenid's shared-budget bucket to exactly 0 tokens by
--- t=3,600,000ms, reusing the SAME proven-correct round-robin pattern (and
--- the SAME exact numbers) as the 1-hour compound-farm test above -- that
--- test already establishes (and asserts) this leaves 0 tokens remaining at
--- that instant. Reusing it here rather than a new hand-rolled drain loop
--- avoids re-deriving timing math that is easy to get subtly wrong (an
--- earlier draft of this section did exactly that, repeatedly calling the
--- SAME actionKey with no time advance between calls and tripping
--- AwardXPCooldown's own pre-existing 500ms-per-actionKey floor instead of
--- draining the budget at all).
--- @param f table -- from newProgressionFixture()
--- @param citizenid string
local function drainToZeroOverOneHour(f, citizenid)
    roundRobinRealMechanics(f, citizenid, 3600000)
end

--- Fires exactly 10 takedownSuccess (30 XP each) awards at the CURRENT
--- fixture time, spaced 501ms apart (just past AwardXPCooldown's own
--- PRE-EXISTING 500ms-per-(citizenid,actionKey) floor -- an earlier draft of
--- this helper called the SAME actionKey back-to-back with zero elapsed
--- time and got every call after the first blocked by that floor instead of
--- by the mint budget it meant to probe). 501ms * 9 gaps = 4,509ms of
--- additional real time during the whole probe -- refills a negligible
--- ~4.5 XP at this section's own 3,600-XP/hr rate, nowhere near enough to
--- blur the distinction this probe exists to draw: "bucket refilled to
--- ~1,800 XP over a real 30-minute idle gap" -- all 10 succeed, 300 XP
--- total -- vs. "bucket was evicted and recreated at the 240-XP starter
--- allowance" -- only 8 of 10 fit (240 XP), 2 are denied.
--- @param f table
--- @param citizenid string
--- @return number grantedCount
local function burstProbe10Takedowns(f, citizenid)
    local before = f.GetXP(citizenid)
    for _ = 1, 10 do
        f.AwardXP(citizenid, 'takedownSuccess')
        f.setNow(f.now() + 501)
    end
    return (f.GetXP(citizenid) - before) / 30
end

t.test('EIGHTH XP-FARM FIX: the memory-bounding sweep does NOT evict a citizenid\'s bucket before a full XP_MINT_BUDGET_WINDOW_MS of inactivity has elapsed', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-sweep-early'
    drainToZeroOverOneHour(f, citizenid) -- ends at fakeNow=3,600,000, 0 tokens remaining

    -- 30 more minutes of inactivity -- well UNDER the 1-hour window. The
    -- bucket should have refilled to ~1,800 XP (30min * 3,600 XP/hr) via
    -- lazy RefillMintBudget, NOT been evicted -- a sweep pass here must not
    -- touch it early.
    f.setNow(f.now() + 1800000)
    f.stepSweep()

    local grantedCount = burstProbe10Takedowns(f, citizenid)
    t.equals(grantedCount, 10, 'a bucket refilled to ~1,800 XP over 30 real minutes must afford all 10 probe takedowns (300 XP) -- if the sweep had evicted it early, only 8 of 10 (240 XP, the fresh starter allowance) would have fit')
end)

t.test('EIGHTH XP-FARM FIX: the memory-bounding sweep DOES safely evict a citizenid\'s bucket once a full XP_MINT_BUDGET_WINDOW_MS of inactivity has elapsed, recreating it at the small starter allowance (not full capacity) on next use', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-sweep-late'
    drainToZeroOverOneHour(f, citizenid) -- ends at fakeNow=3,600,000, 0 tokens remaining

    -- A full hour plus one ms of further inactivity -- now stale by this
    -- section's own eviction rule (RefillMintBudget would already have
    -- clamped this bucket to full capacity, 3,600 XP, had anyone looked).
    -- Eviction here is the DESIGNED-CONSERVATIVE path -- see XPMintBudget's
    -- sweep-thread comment for why recreating at the small starter
    -- allowance afterward, rather than resuming from what would have been a
    -- full 3,600-XP bucket, is deliberate and safe (strictly less budget,
    -- never more).
    f.setNow(f.now() + 3600001)
    f.stepSweep()

    local grantedCount = burstProbe10Takedowns(f, citizenid)
    t.equals(grantedCount, 8, 'a swept-and-recreated bucket starts at the 240-XP starter allowance, not the 3,600-XP full capacity a non-evicted bucket would have held -- only 8 of 10 probe takedowns (240 XP) fit')
end)

t.test('EIGHTH XP-FARM FIX: reconnecting with a fresh player source never resets the shared budget (it is keyed by citizenid, not source)', function()
    local f = newProgressionFixture()
    local citizenid = 'cid-reconnect'
    drainToZeroOverOneHour(f, citizenid) -- ends at fakeNow=3,600,000, 0 tokens remaining

    -- Disconnect (source 111), "reconnect" as a DIFFERENT source (222) --
    -- exactly what a real player reconnecting produces (a fresh FiveM
    -- server-id each session; the citizenid is the only stable identity).
    -- No further time advance -- the budget should still read as fully
    -- spent (0 tokens, nothing has refilled).
    f.firePlayerDropped(citizenid, 111)

    -- K9XP's own in-memory cache IS intentionally evicted by playerDropped
    -- (pre-existing, unrelated behavior -- the real total is reloaded from
    -- k9_progression on the next PlayerLoaded in production, not simulated
    -- by this fixture) -- GetXP reading 0 here is expected and is NOT what
    -- this test is checking.
    t.equals(f.GetXP(citizenid), 0, 'sanity check: K9XP cache eviction on disconnect is pre-existing, unrelated behavior -- not this test\'s own concern')

    -- The real check: if XPMintBudget had been incorrectly reset by the
    -- reconnect, this citizenid would behave like a brand-new one (240-XP
    -- starter allowance) and this single takedownSuccess (30 XP) would be
    -- granted. Since the real budget correctly survived (still at 0 tokens,
    -- no time has passed to refill any), it must be denied.
    f.AwardXP(citizenid, 'takedownSuccess')
    t.equals(f.GetXP(citizenid), 0, 'a reconnect must never grant a fresh starter allowance on top of an already-fully-spent budget -- XPMintBudget is deliberately never cleared on playerDropped')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsXPProgressionPermittedForCitizenId, gating AwardXP's own
-- entry point. Uses newProgressionFixture (fresh env per test, real
-- Config.XP.awards) -- same fixture the EIGHTH XP-FARM FIX section above
-- already uses.
-- ----------------------------------------------------------------------

t.test('PER-PERSON: block.XPProgression denies the award outright, even for an otherwise-valid actionKey', function()
    local f = newProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.XPProgression' and citizenid == 'cid-xpblock' end,
    })
    f.AwardXP('cid-xpblock', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpblock'), 0)
end)

t.test('PER-PERSON: block.XPProgression burns NO rate-floor/mint-budget state -- unblocking immediately after still pays in full', function()
    local f = newProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.XPProgression' and citizenid == 'cid-xpblock2' end,
    })
    f.AwardXP('cid-xpblock2', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpblock2'), 0)

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had consumed the 500ms rate floor for this (citizenid, actionKey)
    -- pair, this would now be silently rate-limited instead of succeeding.
    f.env.HasPermission = function() return false end
    f.AwardXP('cid-xpblock2', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpblock2'), 30, 'a block must never burn the rate floor a legitimate follow-up award still needs')
end)

t.test('PER-PERSON: not blocked and not listed in RequireGrant -- default ALLOW (step 4), matching config.lua\'s documented default', function()
    local f = newProgressionFixture()
    f.AwardXP('cid-xpallow', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpallow'), 30)
end)

t.test('PER-PERSON: RequireGrant.XPProgression = true + no active feature.XPProgression grant -- denied', function()
    local f = newProgressionFixture({ featureControl = { RequireGrant = { XPProgression = true } } })
    f.AwardXP('cid-xpgrantreq', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpgrantreq'), 0)
end)

t.test('PER-PERSON: RequireGrant.XPProgression = true + an active feature.XPProgression grant -- allowed', function()
    local f = newProgressionFixture({
        featureControl = { RequireGrant = { XPProgression = true } },
        hasPermissionFn = function(citizenid, key) return key == 'feature.XPProgression' and citizenid == 'cid-xpgranted' end,
    })
    f.AwardXP('cid-xpgranted', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpgranted'), 30)
end)

t.test('PER-PERSON: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local f = newProgressionFixture({ withHasPermission = false, featureControl = { RequireGrant = { XPProgression = true } } })
    local ok = pcall(f.AwardXP, 'cid-xpmissing', 'takedownSuccess')
    t.isTrue(ok, 'a missing HasPermission must never error AwardXP')
    t.equals(f.GetXP('cid-xpmissing'), 0, 'RequireGrant-listed + unresolvable grant machinery must deny, not silently allow')
end)

t.test('PER-PERSON: server/permissions.lua entirely absent + NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newProgressionFixture({ withHasPermission = false })
    f.AwardXP('cid-xpmissing2', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpmissing2'), 30)
end)

t.test('PER-PERSON: a block on ONE citizenid never affects a DIFFERENT citizenid\'s own award', function()
    local f = newProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.XPProgression' and citizenid == 'cid-xpblocked-other' end,
    })
    f.AwardXP('cid-xpblocked-other', 'takedownSuccess')
    f.AwardXP('cid-xpnotblocked-other', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpblocked-other'), 0)
    t.equals(f.GetXP('cid-xpnotblocked-other'), 30)
end)

t.test('PER-PERSON: AwardXPDirect (/k9givexp, a deliberate high-command override) is DELIBERATELY NOT gated by block.XPProgression -- still pays a blocked citizenid', function()
    local f = newProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.XPProgression' and citizenid == 'cid-xpdirect' end,
    })
    -- The ordinary, farmable path is genuinely blocked...
    f.AwardXP('cid-xpdirect', 'takedownSuccess')
    t.equals(f.GetXP('cid-xpdirect'), 0)

    -- ...but a deliberate, rank-gated, capped, fully-audited manual grant
    -- still reaches the same citizenid -- see AwardXPDirect's own doc
    -- comment in server/progression.lua for why this is a stated decision,
    -- not an oversight matching AwardXP's own gap this pass closed.
    local newTotal = f.AwardXPDirect('cid-xpdirect', 50, 'manual correction')
    t.equals(newTotal, 50)
    t.equals(f.GetXP('cid-xpdirect'), 50)
end)

-- ============================================================================
-- GAP 1 CLOSURE: server/k9profiles.lua's per-INDIVIDUAL-K9 override,
-- traced END TO END through the REAL, unmodified production
-- server/progression.lua AND server/k9profiles.lua loaded TOGETHER in one
-- sandbox -- this is deliberately NOT the same shared `env`/`newProgressionFixture`
-- fixture every test above this section uses (neither loads
-- server/k9profiles.lua at all), and deliberately NOT
-- tests/k9profiles_spec.lua either (that file never loads the REAL
-- server/progression.lua -- see its own header -- so it cannot exercise
-- this cross-file chain for real). This section is the ONE place in this
-- resource's test suite that proves the full chain the owner's own report
-- named -- "set a K9's speed multiplier to 3.0 and NOTHING HAPPENS" -- is
-- actually closed: k9ProfileUpsert (k9profiles.lua) -> RefreshOverrideCache
-- -> PushXPTierSnapshotIfOnline (progression.lua) -> PushTierSnapshot ->
-- BuildEffectiveTierSnapshot -> GetK9EffectiveMultipliers ->
-- TriggerClientEvent('john-k9:client:xpTierChanged', ...). The one
-- link this suite cannot exercise directly is client/progression.lua's own
-- handler turning that event into a real SetPedMoveRateOverride call --
-- tests/clientprogression_spec.lua already owns that half, against the
-- REAL, unmodified client file, so the chain is fully covered end to end
-- across the two suites together, never merely asserted from either side.
-- ============================================================================

--- @return table fixture
local function newGap1Fixture()
    local fakeNow3 = 0
    local function GetGameTimer3() return fakeNow3 end

    local eventHandlers3 = {}
    local function AddEventHandler3(eventName, handler)
        eventHandlers3[eventName] = eventHandlers3[eventName] or {}
        eventHandlers3[eventName][#eventHandlers3[eventName] + 1] = handler
    end

    local function GetCurrentResourceName3() return 'john-k9' end

    -- citizenid -> { PlayerData = { citizenid, source } } -- present only
    -- for a citizenid this test explicitly marks online, mirroring every
    -- other fixture in this file. Declared HERE (moved up from its
    -- original spot further below, unchanged in shape) so GetPlayers3
    -- immediately below can close over it -- a `local` must be declared
    -- before a function that captures it as an upvalue, or that function
    -- would instead silently resolve to an unrelated global of the same
    -- name.
    local onlineByCitizenId3 = {}

    -- UNBOUNDED-TRAP FIX (restart/reconnect audit follow-up, this pass):
    -- now reflects `onlineByCitizenId3` DYNAMICALLY (an array of STRING
    -- source ids, matching real GetPlayers()'s own return shape and
    -- server/progression.lua's own `tonumber(playerIdStr)` read of it) --
    -- used to be a fixed `return {}` because nothing in this fixture ever
    -- called GetPlayers() before RefreshXPProgressionLiveStateForAllOnline
    -- existed. Harmless for every PRE-EXISTING test below: at boot time
    -- (when this file's own onResourceStart backfill loop is the only
    -- caller), `onlineByCitizenId3` is always still empty (no test calls
    -- markOnline until AFTER newGap1Fixture() has already returned), so
    -- this returns `{}` at that point exactly as before.
    local function GetPlayers3()
        local ids = {}
        for _, p in pairs(onlineByCitizenId3) do
            ids[#ids + 1] = tostring(p.PlayerData.source)
        end
        return ids
    end
    local function TriggerEvent3(_eventName, ...) end

    local capturedClientEvents3 = {}
    local function TriggerClientEvent3(eventName, target, payload)
        capturedClientEvents3[#capturedClientEvents3 + 1] = { eventName = eventName, target = target, payload = payload }
    end

    -- Coroutine capture for progression.lua's recurring mint-budget sweep
    -- thread -- identical technique to this file's own top-of-file
    -- CreateThread/Wait stubs (see that declaration's own comment for the
    -- full "why" writeup); a one-shot body still runs to completion
    -- synchronously, a recurring body is captured and never auto-stepped.
    local capturedRecurringThreads3 = {}
    local function CreateThread3(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newGap1Fixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
        if coroutine.status(co) ~= 'dead' then
            capturedRecurringThreads3[#capturedRecurringThreads3 + 1] = co
        end
    end
    local function Wait3(_ms) coroutine.yield() end

    local printedLines3 = {}
    local function printStub3(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines3[#printedLines3 + 1] = table.concat(parts, '\t')
    end

    local callbacks3 = {}
    local lib3 = { callback = { register = function(name, handler) callbacks3[name] = handler end } }

    local exportsStub3 = {
        qbx_core = {
            GetPlayerByCitizenId = function(_self, citizenid) return onlineByCitizenId3[citizenid] end,
            GetPlayer = function(_self, src)
                for _, p in pairs(onlineByCitizenId3) do
                    if p.PlayerData.source == src then return p end
                end
                return nil
            end,
        },
    }

    local MySQLStub3 = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    local Config3 = {
        Features = { XPProgression = true },
        -- Config.Database = { enabled = false } (below, on the table
        -- itself) -- K9Store.WaitForSchemaCheckToSettle() settles
        -- INSTANTLY in this mode (server/datastore.lua's own header), so
        -- k9profiles.lua's own onResourceStart handler needs no coroutine
        -- dance to finish -- it runs to completion synchronously, exactly
        -- like every real memory-mode boot.
        Database = { enabled = false },
        XP = {
            scopePerCitizenidOrJob = 'citizenid',
            awards = { smallAward = 60, exact100 = 100 },
        },
        XPTiers = {
            { xp = 0,   label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 100, label = 'Trained', speedMultiplier = 1.05, scentRangeMultiplier = 1.05, medkitCooldownMultiplier = 0.75 },
        },
    }

    local isHighCommand3 = true
    local function IsHighCommand3(_source) return isHighCommand3 end

    local env3 = Sandbox.newEnv({
        GetGameTimer = GetGameTimer3,
        AddEventHandler = AddEventHandler3,
        GetCurrentResourceName = GetCurrentResourceName3,
        GetPlayers = GetPlayers3,
        TriggerEvent = TriggerEvent3,
        TriggerClientEvent = TriggerClientEvent3,
        CreateThread = CreateThread3,
        Wait = Wait3,
        exports = exportsStub3,
        print = printStub3,
        MySQL = MySQLStub3,
        Config = Config3,
        lib = lib3,
        IsHighCommand = IsHighCommand3,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env3)
    Sandbox.loadInto('../server/datastore.lua', env3)
    Sandbox.loadInto('../server/events.lua', env3)
    Sandbox.loadInto('../server/progression.lua', env3)
    -- fxmanifest.lua's REAL server_scripts order: server/k9profiles.lua
    -- loads AFTER server/progression.lua. Loaded in that same real order
    -- here, deliberately -- this is exactly the load-order this pass's own
    -- soft-dependency guards (`type(GetK9EffectiveMultipliers) ==
    -- 'function'`, `type(PushXPTierSnapshotIfOnline) == 'function'`) are
    -- written to survive, so testing it in the real order is the honest
    -- version of this test, not the easy one.
    Sandbox.loadInto('../server/k9profiles.lua', env3)

    for _, handler in ipairs(eventHandlers3['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env3,
        AwardXP = env3.AwardXP,
        GetXPTier = env3.GetXPTier,
        GetXPTierMedkitCooldownMs = env3.GetXPTierMedkitCooldownMs,
        callbacks = callbacks3,
        capturedClientEvents = capturedClientEvents3,
        printedLines = printedLines3,
        setHighCommand = function(v) isHighCommand3 = v end,
        -- Advances past K9_PROFILE_ACTION_COOLDOWN_MS (1000ms, server/k9profiles.lua)
        -- -- every test below that issues MORE THAN ONE mutating
        -- k9Profile* call from the SAME acting source must call this
        -- between calls, mirroring tests/k9profiles_spec.lua's own
        -- `advance` helper exactly.
        advance = function() fakeNow3 = fakeNow3 + 1100 end,
        markOnline = function(citizenid, src)
            onlineByCitizenId3[citizenid] = { PlayerData = { citizenid = citizenid, source = src } }
        end,
        markOffline = function(citizenid) onlineByCitizenId3[citizenid] = nil end,
    }
end

t.test('GAP 1: k9ProfileUpsert on an ONLINE citizenid pushes a LIVE, override-composed xpTierChanged snapshot immediately -- not merely on the next tier crossing/login', function()
    local f = newGap1Fixture()
    f.markOnline('GAP1CIT', 4242)

    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](100, { citizenid = 'GAP1CIT', speedMultiplier = 3.0 })
    t.isTrue(result.ok, 'the upsert itself must succeed')
    t.equals(result.effective.speedMultiplier, 3.0, 'the callback response must already reflect the override')

    local pushed = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 4242 then pushed = evt end
    end
    t.isNotNil(pushed, 'setting an override for an ONLINE citizenid must push a fresh xpTierChanged snapshot to their own client, immediately, not deferred to their next real tier crossing')
    t.equals(pushed.payload.speedMultiplier, 3.0, 'the pushed payload must carry the OVERRIDDEN value, not the plain tier default (1.00) -- this IS the "set it to 3.0 and something happens" property')
    t.equals(pushed.payload.label, 'Recruit', 'every OTHER field on the pushed tier snapshot is untouched -- only the composed multiplier fields change')
end)

t.test('GAP 1: k9ProfileUpsert on an OFFLINE citizenid writes the override successfully but pushes NOTHING (no client to push to) -- never throws', function()
    local f = newGap1Fixture()
    -- deliberately never call f.markOnline for this citizenid

    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](100, { citizenid = 'GAP1OFFLINE', speedMultiplier = 2.0 })
    t.isTrue(result.ok)
    t.equals(result.effective.speedMultiplier, 2.0, 'the write itself must still succeed for an offline citizenid')
    t.equals(#f.capturedClientEvents, 0, 'nothing should be pushed to a citizenid with no live client to push to')
end)

t.test('GAP 1: k9ProfileReset on an ONLINE citizenid pushes the PLAIN tier value back immediately, snapping an already-overridden K9 back to normal live', function()
    local f = newGap1Fixture()
    f.markOnline('GAP1RESET', 5252)
    f.callbacks['john-k9:server:k9ProfileUpsert'](100, { citizenid = 'GAP1RESET', speedMultiplier = 3.0 })
    f.advance() -- clear K9ProfileActionCooldown's 1000ms floor before the 2nd mutating call from the same source

    local resetResult = f.callbacks['john-k9:server:k9ProfileReset'](100, 'GAP1RESET')
    t.isTrue(resetResult.ok)
    t.equals(resetResult.effective.speedMultiplier, 1.0, 'after reset, the effective value must be the plain base tier (1.00), never the just-removed override')

    local lastPush = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 5252 then lastPush = evt end
    end
    t.isNotNil(lastPush)
    t.equals(lastPush.payload.speedMultiplier, 1.0, 'the LAST push (the reset) must carry the plain tier value, not the 3.0 override the upsert just pushed a moment earlier')
end)

t.test('GAP 1: GetXPTierMedkitCooldownMs composes the individual override, layered on top of the XP tier -- GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE', function()
    local f = newGap1Fixture()
    -- 'GAP1MEDKIT' never earns XP -> resolves to the base Recruit tier,
    -- which carries NO medkitCooldownMultiplier at all (only 'Trained'
    -- does, in this fixture's own Config3.XPTiers) -- so, with no
    -- individual override, this accessor must be a pure no-op.
    t.equals(f.GetXPTierMedkitCooldownMs('GAP1MEDKIT', 10000), 10000, 'no tier multiplier and no override -- baseCooldownMs must pass through unchanged')

    -- Setting an individual override on top of that SAME base tier must now
    -- take effect -- this is the exact composition GetK9EffectiveMultipliers
    -- exists to provide, and the exact seam GetXPTierMedkitCooldownMs was
    -- rewired to consult this pass.
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](100, { citizenid = 'GAP1MEDKIT', medkitCooldownMultiplier = 0.5 })
    t.isTrue(result.ok)
    t.equals(f.GetXPTierMedkitCooldownMs('GAP1MEDKIT', 10000), 5000, 'a 0.5 individual override must halve the base cooldown, even though this citizenid\'s own XP tier (Recruit) carries no medkitCooldownMultiplier of its own')
end)

t.test('GAP 1: without server/k9profiles.lua loaded at all, GetXPTierMedkitCooldownMs and the xpTierChanged push degrade cleanly to their pre-this-pass behavior -- the soft-dependency guard genuinely degrades, not merely "does not crash"', function()
    -- Reuses the file's OWN shared `env`/AwardXP/GetXPTier (top of this
    -- file) -- that fixture never loads server/k9profiles.lua at all, so
    -- GetK9EffectiveMultipliers/PushXPTierSnapshotIfOnline are genuinely
    -- undefined here, exactly like every real install that predates this
    -- pass's own server/k9profiles.lua ever existing.
    t.isNil(env.GetK9EffectiveMultipliers, 'sanity check on the fixture itself: this shared env must not have loaded server/k9profiles.lua')

    -- Trained's own medkitCooldownMultiplier (0.75) is exercised directly by
    -- tests/xptierunlocks_spec.lua -- this assertion only needs to prove
    -- k9profiles.lua's ABSENCE changes nothing, using whichever tier a
    -- citizenid already ends up on in THIS shared fixture.
    local baseCooldown = env.GetXPTierMedkitCooldownMs('cid-no-k9profiles-a', 8000)
    t.equals(baseCooldown, 8000, 'the base (Recruit) tier in this shared fixture carries no medkitCooldownMultiplier at all -- this must be a pure passthrough regardless of k9profiles.lua\'s absence')

    playerByCitizenId['cid-no-k9profiles-b'] = { PlayerData = { citizenid = 'cid-no-k9profiles-b', source = 9998 } }
    capturedTriggerEvents = {}
    AwardXP('cid-no-k9profiles-b', 'exact100') -- crosses Recruit -> Trained
    t.equals(GetXPTier('cid-no-k9profiles-b').label, 'Trained', 'AwardXP/GetXPTier must keep working identically whether or not server/k9profiles.lua is present')
end)

-- ============================================================================
-- UNBOUNDED-TRAP FIX (restart/reconnect audit follow-up, this pass) --
-- client/progression.lua's own header names this bug and the exact server
-- function needed to close it, verbatim: PushTierSnapshot must stop
-- withholding the payload while Config.Features.XPProgression is off (it
-- now tags every payload with `.live` instead), and a NEW resource-global,
-- RefreshXPProgressionLiveStateForAllOnline, must push a fresh snapshot to
-- every currently-connected citizenid the INSTANT that flag changes at
-- runtime -- not merely on that citizenid's next tier crossing, reconnect,
-- or a full resource restart. This section tests server/progression.lua's
-- OWN half of that fix directly (calling env3.RefreshXPProgressionLiveStateForAllOnline()
-- and flipping Config3.Features.XPProgression exactly the way
-- server/runtimecontrol.lua's ApplyFeatureOverride does) -- the OTHER
-- half, that ApplyFeatureOverride genuinely calls this function when an
-- officer flips XPProgression via the real runtimeSetFeature/
-- runtimeResetFeature callbacks, is proved end to end in
-- tests/runtimecontrol_spec.lua's own "UNBOUNDED-TRAP FIX" section
-- (loading server/runtimecontrol.lua AND server/progression.lua together)
-- -- the two together are what make this fixture's own use of newGap1Fixture
-- (which never loads server/runtimecontrol.lua at all) an honest, narrow
-- unit-level check of this file's own contribution, not a claim that the
-- wiring itself is proved here.
-- ============================================================================

t.test('UNBOUNDED-TRAP FIX: PushTierSnapshot now ALWAYS sends (never withheld while the flag is off), tagging the payload with the CURRENT Config.Features.XPProgression value rather than staying silent', function()
    local f = newGap1Fixture()
    f.markOnline('TRAPCIT', 6001)

    -- Flag ON: k9ProfileUpsert (which internally calls PushXPTierSnapshotIfOnline
    -- -> PushTierSnapshot) must tag the payload `.live = true`, explicitly,
    -- not merely "absent" -- see PushTierSnapshot's own doc comment for why
    -- this is a real boolean assignment, not a conditional field.
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](100, { citizenid = 'TRAPCIT', speedMultiplier = 2.0 })
    t.isTrue(result.ok)

    local pushedWhileOn = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 6001 then pushedWhileOn = evt end
    end
    t.isNotNil(pushedWhileOn, 'sanity: the pre-existing GAP-1 push must still fire while the flag is on')
    t.equals(pushedWhileOn.payload.live, true, 'the payload must explicitly carry live=true while Config.Features.XPProgression is true')

    -- Flag OFF: the SAME BuildEffectiveTierSnapshot/PushTierSnapshot chain,
    -- triggered again via k9ProfileReset (any PushTierSnapshot call site
    -- works identically -- this one is convenient since it needs no
    -- cooldown dance), must NOT be withheld anymore -- this is the exact
    -- gap client/progression.lua's own header names: PushTierSnapshot used
    -- to `if not Config.Features.XPProgression then return end` before
    -- ever calling TriggerClientEvent.
    f.env.Config.Features.XPProgression = false
    f.advance()
    local resetResult = f.callbacks['john-k9:server:k9ProfileReset'](100, 'TRAPCIT')
    t.isTrue(resetResult.ok, 'the override write/removal itself is NOT gated on XPProgression -- only the client push semantics are under test here')

    local pushedWhileOff = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 6001 and evt.payload.live == false then pushedWhileOff = evt end
    end
    t.isNotNil(pushedWhileOff, 'THE FIX: a PushTierSnapshot call must still reach an online client even while the flag is off, now carrying live=false -- an unpatched PushTierSnapshot would have withheld this payload entirely')
end)

t.test('UNBOUNDED-TRAP FIX: RefreshXPProgressionLiveStateForAllOnline pushes a fresh live=false snapshot to EVERY currently-connected citizenid the instant the flag flips off -- the exact function client/progression.lua\'s own header names as the missing piece', function()
    local f = newGap1Fixture()
    t.equals(type(f.env.RefreshXPProgressionLiveStateForAllOnline), 'function', 'server/progression.lua must expose this as a resource-global (no `local`), per its own FILE-TO-FILE CONTRACT')

    f.markOnline('TRAPCIT2A', 7001)
    f.markOnline('TRAPCIT2B', 7002)
    -- Deliberately never marked online -- must receive nothing, and must
    -- not make this function throw.
    -- (TRAPCIT2C stays offline)

    f.env.Config.Features.XPProgression = false
    f.env.RefreshXPProgressionLiveStateForAllOnline()

    local seenTargets = {}
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' then
            seenTargets[evt.target] = evt.payload
        end
    end
    t.isNotNil(seenTargets[7001], 'the first already-online citizenid must receive a fresh snapshot immediately')
    t.equals(seenTargets[7001].live, false)
    t.isNotNil(seenTargets[7002], 'the second already-online citizenid must ALSO receive one -- every currently-connected K9, not just one')
    t.equals(seenTargets[7002].live, false)
end)

t.test('UNBOUNDED-TRAP FIX: RefreshXPProgressionLiveStateForAllOnline also re-enables the buff live when the flag flips back ON -- symmetric, not a one-way kill switch', function()
    local f = newGap1Fixture()
    f.markOnline('TRAPCIT3', 8001)

    f.env.Config.Features.XPProgression = false
    f.env.RefreshXPProgressionLiveStateForAllOnline()
    f.env.Config.Features.XPProgression = true
    f.env.RefreshXPProgressionLiveStateForAllOnline()

    local lastPush = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 8001 then lastPush = evt end
    end
    t.isNotNil(lastPush)
    t.equals(lastPush.payload.live, true, 'the LAST push (after flipping back on) must carry live=true, re-arming client/progression.lua\'s own reset-guard for this citizenid')
end)

t.test('UNBOUNDED-TRAP FIX: RefreshXPProgressionLiveStateForAllOnline is a safe no-op when nobody is online -- never throws against an empty GetPlayers()', function()
    local f = newGap1Fixture()
    -- Deliberately no markOnline calls at all.
    local ok, err = pcall(f.env.RefreshXPProgressionLiveStateForAllOnline)
    t.isTrue(ok, 'must never throw: ' .. tostring(err))
    t.equals(#f.capturedClientEvents, 0, 'nothing to push to -- no events at all')
end)

-- ============================================================================
-- CONFIG-ABORT REGRESSION (this pass): Config.XPTiers and Config.XP.awards
-- both used to be validated via bare `assert`s inside their own
-- onResourceStart handlers here. A malformed value must now warn and fall
-- back instead of throwing -- and, the part a bare "does not throw" test
-- would miss, GetXPTier/AwardXP must keep working correctly afterward, off
-- the substituted safe values, exactly as if the malformed table had never
-- existed. Each case needs its OWN fresh fixture (GetValidatedXPTiers is
-- memoized on first use, so a pre-existing env that already resolved a
-- valid table can never be used to observe the fallback path).
-- ============================================================================

t.test('CONFIG-ABORT REGRESSION: Config.XPTiers missing the mandatory xp=0 baseline warns and falls back to the built-in Recruit K9 tier, never throws', function()
    local f = newProgressionFixture({
        xpTiers = {
            -- MALFORMED: no { xp = 0, ... } baseline entry at all -- the
            -- exact plausible owner typo this regression guards against.
            { xp = 100, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        },
    })

    local ok, tier = pcall(f.GetXPTier, 'never-seen-before')
    t.isTrue(ok, 'GetXPTier must not throw against a malformed Config.XPTiers: ' .. tostring(tier))
    t.equals(tier.label, 'Recruit K9', 'must resolve to the built-in fallback base tier')
    t.equals(tier.speedMultiplier, 1.00)
    t.equals(tier.xp, 0)

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.XPTiers', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a malformed Config.XPTiers must print a warning naming it')

    -- AwardXP must still actually WORK end to end off the fallback ladder --
    -- clamp-and-warn means "still functions", not merely "does not crash".
    f.AwardXP('cid-fallback-tiers', 'searchContrabandFound')
    t.equals(f.GetXP('cid-fallback-tiers'), 25, 'AwardXP must still accumulate real XP even while the tier LADDER is unavailable')
    t.equals(f.GetXPTier('cid-fallback-tiers').label, 'Recruit K9', 'every citizenid resolves to the single fallback tier while Config.XPTiers stays malformed')
end)

t.test('CONFIG-ABORT REGRESSION: an out-of-order Config.XPTiers warns and falls back, never throws', function()
    local f = newProgressionFixture({
        xpTiers = {
            { xp = 0,   label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 50,  label = 'Backwards',  speedMultiplier = 1.20, scentRangeMultiplier = 1.20 },
            { xp = 10,  label = 'OutOfOrder', speedMultiplier = 1.50, scentRangeMultiplier = 1.50 }, -- MALFORMED: lower xp than the entry before it
        },
    })

    local ok, tier = pcall(f.GetXPTier, 'never-seen-before')
    t.isTrue(ok, 'GetXPTier must not throw against an out-of-order Config.XPTiers: ' .. tostring(tier))
    t.equals(tier.label, 'Recruit K9', 'must resolve to the built-in fallback base tier, not silently trust the out-of-order array')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('ascending', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an out-of-order Config.XPTiers must print a warning naming the ascending-order requirement')
end)

t.test('CONFIG-ABORT REGRESSION: warns only ONCE for Config.XPTiers, no matter how many times GetXPTier/AwardXP are called against the malformed table', function()
    local f = newProgressionFixture({
        xpTiers = { { xp = 5, label = 'NoBaseline', speedMultiplier = 1.0, scentRangeMultiplier = 1.0 } }, -- MALFORMED: xp ~= 0
    })

    f.GetXPTier('a')
    f.GetXPTier('b')
    f.AwardXP('c', 'searchContrabandFound')
    f.GetXPTier('d')

    local warnCount = 0
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.XPTiers', 1, true) then warnCount = warnCount + 1 end
    end
    t.equals(warnCount, 1, 'must warn ONCE per resource lifetime, not once per call')
end)

t.test('CONFIG-ABORT REGRESSION: a Config.XP.awards value above XP_MINT_BUDGET_CAP_XP (3600) warns and treats that actionKey as unpayable, never throws, and every OTHER actionKey keeps working', function()
    local f = newProgressionFixture({
        xpAwards = {
            searchContrabandFound = 25,     -- valid, unaffected
            -- MALFORMED: larger than the shared budget could ever cover.
            legendaryQuest = 5000,
        },
    })

    local ok = pcall(f.AwardXP, 'cid-overcap', 'legendaryQuest')
    t.isTrue(ok, 'AwardXP must not throw against an over-cap Config.XP.awards value')
    t.equals(f.GetXP('cid-overcap'), 0, 'an unpayable award must never grant any XP at all')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('legendaryQuest', 1, true) and line:find('exceeds XP_MINT_BUDGET_CAP_XP', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an over-cap award must print a warning naming the actionKey')

    -- Every OTHER actionKey must be completely unaffected -- this is the
    -- part a bare "does not throw" test would miss: the malformed key must
    -- not take down the whole awards table.
    f.AwardXP('cid-overcap', 'searchContrabandFound')
    t.equals(f.GetXP('cid-overcap'), 25, 'an unrelated, validly-configured actionKey must still pay out normally')
end)

t.test('CONFIG-ABORT REGRESSION: a negative Config.XP.awards value warns and treats that actionKey as unpayable, never throws, and never deducts XP', function()
    local f = newProgressionFixture({
        xpAwards = {
            searchContrabandFound = 25, -- valid, unaffected
            -- MALFORMED: negative -- must never reach the direct
            -- `K9XP[citizenid] = oldXp + amount` mutation and silently
            -- subtract XP.
            brokenPenalty = -500,
        },
    })

    f.AwardXP('cid-negative', 'searchContrabandFound') -- establish a real, positive XP total first
    t.equals(f.GetXP('cid-negative'), 25)

    f.setNow(f.now() + 501) -- clear the per-(citizenid, actionKey) rate floor
    local ok = pcall(f.AwardXP, 'cid-negative', 'brokenPenalty')
    t.isTrue(ok, 'AwardXP must not throw against a negative Config.XP.awards value')
    t.equals(f.GetXP('cid-negative'), 25, 'a negative award must be treated as unpayable -- the citizenid\'s real, already-earned XP must never be silently deducted')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('brokenPenalty', 1, true) and line:find('must not be negative', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a negative award must print a warning naming the actionKey')
end)

t.test('CONFIG-ABORT REGRESSION: a Config.XP.awards value of exactly XP_MINT_BUDGET_CAP_XP (the boundary) passes validation without warning -- the ceiling is inclusive', function()
    -- NOTE: this only proves ValidateXPAwardAmount's own boundary check
    -- (`amount <= XP_MINT_BUDGET_CAP_XP`) accepts 3600 without warning --
    -- it deliberately does NOT assert the full 3600 is paid out in one
    -- call, since a brand-new citizenid's bucket starts at
    -- XP_MINT_BUDGET_STARTER_TOKENS (a fraction of the cap, by design --
    -- see that constant's own declaration comment), not a full bucket; that
    -- is a SEPARATE mechanism from the value-range validation this test
    -- targets, and asserting on it here would conflate the two.
    local f = newProgressionFixture({
        xpAwards = { atCap = 3600 },
    })
    local ok = pcall(f.AwardXP, 'cid-atcap', 'atCap')
    t.isTrue(ok)
    local warnedAboutAwards = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.XP.awards', 1, true) then warnedAboutAwards = true end
    end
    t.isFalse(warnedAboutAwards, 'a valid boundary value must never warn about Config.XP.awards at all (unrelated boot-time datastore prints are expected and irrelevant here)')
end)

-- ============================================================================
-- RETURN VALUE (this pass -- server/tenure.lua's honest per-party
-- notification fix needs to know whether an award genuinely succeeded, not
-- just that it was attempted). Uses the SHARED top-of-file env/AwardXP --
-- fresh citizenid, so it does not interact with any other test's own
-- accumulated total.
-- ============================================================================

t.test('AwardXP: returns the real amount actually applied on success, and returns nothing on an unknown actionKey (never a number for a rejected call)', function()
    fakeNow = fakeNow + 10000
    local granted = AwardXP('cid-retval', 'smallAward')
    t.equals(granted, 60, 'must return the exact amount just applied to K9XP')

    fakeNow = fakeNow + 10000
    local rejected = AwardXP('cid-retval', 'totallyUnknownActionKeyForThisTest')
    t.isNil(rejected, 'an unknown actionKey must return nothing, never a number')
end)

-- ============================================================================
-- HANDLER TIER CLIENT VISIBILITY (this pass, coder-backend -- "a handler
-- cannot see their own rank or XP anywhere" gap closure). Own FRESH
-- sandbox, mirroring newProgressionFixture's own reasoning for needing one
-- (real, tunable Config.HandlerXPTiers/Config.HandlerXP), but going
-- further: every fixture above this point gives TriggerClientEvent a
-- byte-discarding no-op body, which cannot prove anything about a PAYLOAD
-- this section needs to inspect -- so this one CAPTURES every call
-- instead.
-- ============================================================================

--- @param opts table? -- { handlerXPProgression: boolean? (default true), handlerXpByCitizenid: table<string, number>? (seeds K9Store.HandlerXP_Get's own "no row yet" MySQL.scalar.await stub), prewarmedPlayers: {{src=number, citizenid=string}}? (populates GetPlayers()/exports.qbx_core BEFORE onResourceStart's own backfill loop runs, simulating players already connected across a restart) }
--- @return table fixture
local function newHandlerTierSnapshotFixture(opts)
    opts = opts or {}
    local fakeNow3 = 0
    local function GetGameTimer3() return fakeNow3 end

    local eventHandlers3 = {}
    local function AddEventHandler3(eventName, handler)
        eventHandlers3[eventName] = eventHandlers3[eventName] or {}
        eventHandlers3[eventName][#eventHandlers3[eventName] + 1] = handler
    end

    local function GetCurrentResourceName3() return 'john-k9' end

    local onlineSources = {}
    local playerByCitizenId3 = {}
    for _, p in ipairs(opts.prewarmedPlayers or {}) do
        onlineSources[#onlineSources + 1] = p.src
        playerByCitizenId3[p.citizenid] = { PlayerData = { citizenid = p.citizenid, source = p.src } }
    end

    local function GetPlayers3()
        local out = {}
        for i, src in ipairs(onlineSources) do out[i] = tostring(src) end
        return out
    end

    local function TriggerEvent3(_eventName, ...) end

    -- THE ONE MEANINGFUL DIFFERENCE FROM EVERY OTHER FIXTURE ABOVE: a REAL,
    -- capturing TriggerClientEvent, because this section's own tests need
    -- to inspect the exact payload shape server/progression.lua sends, not
    -- merely that "some event fired."
    local capturedClientEvents = {}
    local function TriggerClientEvent3(eventName, target, payload)
        capturedClientEvents[#capturedClientEvents + 1] = { eventName = eventName, target = target, payload = payload }
    end

    local capturedRecurringThreads3 = {}
    local function CreateThread3(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newHandlerTierSnapshotFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
        if coroutine.status(co) ~= 'dead' then
            capturedRecurringThreads3[#capturedRecurringThreads3 + 1] = co
        end
    end
    local function Wait3(_ms) coroutine.yield() end

    local printedLines3 = {}
    local function printStub3(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines3[#printedLines3 + 1] = table.concat(parts, '\t')
    end

    local exportsStub3 = {
        qbx_core = {
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId3[citizenid] end,
            GetPlayer = function(_self, src)
                for _, p in pairs(playerByCitizenId3) do
                    if p.PlayerData.source == src then return p end
                end
                return nil
            end,
        },
    }

    local handlerXpByCitizenid = opts.handlerXpByCitizenid or {}
    local MySQLStub3 = {
        scalar = { await = function(_sql, params) return handlerXpByCitizenid[params[1]] end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    local Config3 = {
        Features = { XPProgression = true, HandlerXPProgression = opts.handlerXPProgression ~= false },
        XP = { scopePerCitizenidOrJob = 'citizenid', awards = { takedownSuccess = 30 } },
        XPTiers = { { xp = 0, label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 } },
        HandlerXP = { awards = { handlerCertifyK9 = 50 } },
        HandlerXPTiers = {
            { xp = 0,  label = 'Rookie Handler' },
            { xp = 50, label = 'Certified Handler', medkitTreatCooldownMultiplier = 0.90 },
        },
        FeatureControl = opts.featureControl,
    }

    local env3 = Sandbox.newEnv({
        GetGameTimer = GetGameTimer3,
        AddEventHandler = AddEventHandler3,
        GetCurrentResourceName = GetCurrentResourceName3,
        GetPlayers = GetPlayers3,
        TriggerEvent = TriggerEvent3,
        TriggerClientEvent = TriggerClientEvent3,
        CreateThread = CreateThread3,
        Wait = Wait3,
        exports = exportsStub3,
        print = printStub3,
        MySQL = MySQLStub3,
        Config = Config3,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env3)
    Sandbox.loadInto('../server/datastore.lua', env3)
    Sandbox.loadInto('../server/events.lua', env3)
    Sandbox.loadInto('../server/progression.lua', env3)

    for _, handler in ipairs(eventHandlers3['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env3,
        Config = Config3,
        AwardHandlerXP = env3.AwardHandlerXP,
        RefreshHandlerXPProgressionLiveStateForAllOnline = env3.RefreshHandlerXPProgressionLiveStateForAllOnline,
        capturedClientEvents = capturedClientEvents,
        printedLines = printedLines3,
        setOnline = function(src, citizenid)
            onlineSources[#onlineSources + 1] = src
            playerByCitizenId3[citizenid] = { PlayerData = { citizenid = citizenid, source = src } }
        end,
        firePlayerLoaded = function(citizenid, src)
            playerByCitizenId3[citizenid] = { PlayerData = { citizenid = citizenid, source = src } }
            for _, handler in ipairs(eventHandlers3['QBCore:Server:PlayerLoaded'] or {}) do
                handler(playerByCitizenId3[citizenid])
            end
        end,
        --- Last 'john-k9:client:handlerXpTierChanged' sent to `target`
        --- (or the last one sent to ANYONE, if `target` is nil).
        lastHandlerEvent = function(target)
            for i = #capturedClientEvents, 1, -1 do
                local e = capturedClientEvents[i]
                if e.eventName == 'john-k9:client:handlerXpTierChanged' and (target == nil or e.target == target) then
                    return e
                end
            end
            return nil
        end,
        countHandlerEvents = function()
            local n = 0
            for _, e in ipairs(capturedClientEvents) do
                if e.eventName == 'john-k9:client:handlerXpTierChanged' then n = n + 1 end
            end
            return n
        end,
    }
end

t.test('HANDLER TIER PUSH: AwardHandlerXP returns the real amount on success, and nothing on a rejected call (feature off)', function()
    local fxOn = newHandlerTierSnapshotFixture({ handlerXPProgression = true })
    local granted = fxOn.AwardHandlerXP('cid-hxp1', 'handlerCertifyK9')
    t.equals(granted, 50, 'must return the exact amount just applied to HandlerXP')

    local fxOff = newHandlerTierSnapshotFixture({ handlerXPProgression = false })
    local rejected = fxOff.AwardHandlerXP('cid-hxp2', 'handlerCertifyK9')
    t.isNil(rejected, 'the whole-function no-op (feature off) must return nothing, never a number')
end)

t.test('HANDLER TIER PUSH: PlayerLoaded pushes john-k9:client:handlerXpTierChanged UNCONDITIONALLY -- even with Config.Features.HandlerXPProgression OFF, tagged live=false, never withheld', function()
    local fx = newHandlerTierSnapshotFixture({ handlerXPProgression = false })
    fx.firePlayerLoaded('cid-login1', 501)

    local e = fx.lastHandlerEvent(501)
    t.isNotNil(e, 'the push must happen regardless of the flag -- this pass\'s own "do not gate the push itself on the flag" requirement')
    t.equals(e.payload.totalXp, 0, 'an uncached/no-row citizenid must show 0, never nil or an error')
    t.equals(e.payload.tier.label, 'Rookie Handler')
    t.isFalse(e.payload.live, 'must be tagged with the flag\'s REAL current value, never omitted')
end)

t.test('HANDLER TIER PUSH: PlayerLoaded pushes the REAL persisted total/tier and tags live=true when the flag is on -- this is what makes an offline-earned crossing visible on next login', function()
    local fx = newHandlerTierSnapshotFixture({ handlerXPProgression = true, handlerXpByCitizenid = { ['cid-login2'] = 75 } })
    fx.firePlayerLoaded('cid-login2', 502)

    local e = fx.lastHandlerEvent(502)
    t.isNotNil(e)
    t.equals(e.payload.totalXp, 75, 'must reflect the REAL persisted total read fresh from the database, not a session-only accumulator')
    t.equals(e.payload.tier.label, 'Certified Handler', 'must resolve to the tier that total actually earns (75 >= 50)')
    t.isTrue(e.payload.live)
end)

t.test('HANDLER TIER PUSH: AwardHandlerXP pushes a tier-crossing snapshot to the online citizenid, and does NOT push at all when no tier boundary was crossed', function()
    local fx = newHandlerTierSnapshotFixture({ handlerXPProgression = true })
    fx.setOnline(503, 'cid-cross1')

    -- Below the 50-xp Certified Handler threshold -- no crossing yet.
    fx.AwardHandlerXP('cid-cross1', 'handlerCertifyK9') -- 50 XP -- lands EXACTLY on the boundary, so this SHOULD cross
    local e = fx.lastHandlerEvent(503)
    t.isNotNil(e, 'a genuine tier crossing (0 -> 50, Rookie -> Certified) must push')
    t.equals(e.payload.totalXp, 50)
    t.equals(e.payload.tier.label, 'Certified Handler')
    t.isTrue(e.payload.live)

    local countAfterCrossing = fx.countHandlerEvents()
    -- A SECOND award for the same citizenid that does NOT cross another
    -- tier boundary (Certified Handler is this fixture's own top tier)
    -- must NOT push again -- mirrors AwardXP's own "only on newTier ~=
    -- oldTier" discipline for the K9 side exactly.
    fx.env.HasPermission = nil -- no-op, just documents nothing else gates this
    local secondCallOk = pcall(fx.AwardHandlerXP, 'cid-cross1', 'handlerCertifyK9')
    t.isTrue(secondCallOk)
    t.equals(fx.countHandlerEvents(), countAfterCrossing, 'no NEW push when no tier boundary was crossed')
end)

t.test('HANDLER TIER PUSH: RefreshHandlerXPProgressionLiveStateForAllOnline pushes a snapshot to every currently-online citizenid, tagged with the CURRENT flag value -- the runtime-toggle "unbounded trap" fix, mirrored from the K9 side', function()
    local fx = newHandlerTierSnapshotFixture({ handlerXPProgression = true })
    fx.setOnline(504, 'cid-refresh1')
    fx.setOnline(505, 'cid-refresh2')

    fx.RefreshHandlerXPProgressionLiveStateForAllOnline()
    local e504 = fx.lastHandlerEvent(504)
    local e505 = fx.lastHandlerEvent(505)
    t.isNotNil(e504)
    t.isNotNil(e505)
    t.isTrue(e504.payload.live)
    t.isTrue(e505.payload.live)

    -- Flip the flag off (simulating a runtime toggle from the tablet) and
    -- refresh again -- BOTH already-online citizenids must now see
    -- live=false, the same "never withheld, tagged instead" discipline
    -- 144a432 established for the K9 side.
    fx.Config.Features.HandlerXPProgression = false
    fx.RefreshHandlerXPProgressionLiveStateForAllOnline()
    t.isFalse(fx.lastHandlerEvent(504).payload.live)
    t.isFalse(fx.lastHandlerEvent(505).payload.live)
end)

t.test('HANDLER TIER PUSH: onResourceStart backfill pushes for an already-connected citizenid when HandlerXPProgression was on at restart -- mirrors the K9 side\'s own "/restart while online" backfill', function()
    local fx = newHandlerTierSnapshotFixture({
        handlerXPProgression = true,
        handlerXpByCitizenid = { ['cid-backfill1'] = 60 },
        prewarmedPlayers = { { src = 601, citizenid = 'cid-backfill1' } },
    })

    local e = fx.lastHandlerEvent(601)
    t.isNotNil(e, 'the backfill loop must push for a citizenid already connected across the simulated restart')
    t.equals(e.payload.totalXp, 60)
    t.equals(e.payload.tier.label, 'Certified Handler')
    t.isTrue(e.payload.live)
end)

t.test('HANDLER TIER PUSH: onResourceStart backfill pushes NOTHING when HandlerXPProgression was OFF at restart -- same wasted-query avoidance the K9 side\'s own backfill already applies, not a withheld payload', function()
    local fx = newHandlerTierSnapshotFixture({
        handlerXPProgression = false,
        prewarmedPlayers = { { src = 602, citizenid = 'cid-backfill2' } },
    })

    t.equals(fx.countHandlerEvents(), 0, 'no backfill push at all when the flag has never been enabled -- there is no real handler_xp row to warm or show')
end)

-- ============================================================================
-- HANDLER LADDER CLIMBABILITY (this pass, coder-backend -- "the handler
-- rank ladder cannot be reached in a human lifetime" audit). Loads the
-- REAL, unmodified config.lua directly (not a fixture copy) so this is a
-- genuine regression guard on the SHIPPED Config.HandlerXPTiers/
-- Config.HandlerXP values, not on a description of them -- reverting the
-- rescale back toward the old 750/2500/6000 thresholds (or changing the
-- wired award amounts this arithmetic depends on) fails this test.
-- ============================================================================

local function loadRealConfig()
    local realConfigEnv = Sandbox.newEnv({})
    Sandbox.loadInto('../config.lua', realConfigEnv)
    return realConfigEnv.Config
end

t.test('HANDLER LADDER: the real, shipped Config.HandlerXPTiers is non-empty, ascending, and starts at xp = 0 (the same baseline contract GetValidatedHandlerXPTiers enforces at runtime)', function()
    local RealConfig = loadRealConfig()
    local tiers = RealConfig.HandlerXPTiers
    t.isTrue(type(tiers) == 'table' and #tiers >= 2)
    t.equals(tiers[1].xp, 0)
    for i = 2, #tiers do
        t.isTrue(tiers[i].xp > tiers[i - 1].xp, ('tier %d (xp=%s) must exceed tier %d (xp=%s)'):format(i, tostring(tiers[i].xp), i - 1, tostring(tiers[i - 1].xp)))
    end
end)

t.test('HANDLER LADDER: the FIRST promotion (rank index 2) is reachable via a SINGLE personally-granted certification (handlerCertifyK9) -- "a first promotion within a few shifts"', function()
    local RealConfig = loadRealConfig()
    local firstPromotionThreshold = RealConfig.HandlerXPTiers[2].xp
    local certifyAward = RealConfig.HandlerXP.awards.handlerCertifyK9
    t.isTrue(type(certifyAward) == 'number' and certifyAward > 0)
    t.isTrue(firstPromotionThreshold <= certifyAward,
        ('first promotion (xp=%d) must be reachable in ONE certification (worth %d XP) -- otherwise it is not a "few shifts" rank'):format(firstPromotionThreshold, certifyAward))
end)

t.test('HANDLER LADDER: the SECOND rank is reachable from the tenure-milestone trickle ALONE (no certifying required) -- a handler who only ever stays partnered still climbs at least this far in about a month', function()
    local RealConfig = loadRealConfig()
    local secondRankThreshold = RealConfig.HandlerXPTiers[3].xp
    local tenureLifetimeCap = RealConfig.HandlerXP.awards.handlerPartnershipTenure1Day
        + RealConfig.HandlerXP.awards.handlerPartnershipTenure7Day
        + RealConfig.HandlerXP.awards.handlerPartnershipTenure30Day
    t.isTrue(secondRankThreshold <= tenureLifetimeCap,
        ('the second rank (xp=%d) must be reachable from tenure alone (lifetime cap=%d XP, ~30 days) -- a handler who never certifies anyone must not be stuck below it'):format(secondRankThreshold, tenureLifetimeCap))
end)

t.test('HANDLER LADDER: the TOP rank is deliberately ABOVE the tenure-alone lifetime cap (a genuine long-term goal, not a passive one) but still reachable within roughly ten personally-granted certifications, not hundreds', function()
    local RealConfig = loadRealConfig()
    local topTier = RealConfig.HandlerXPTiers[#RealConfig.HandlerXPTiers]
    local tenureLifetimeCap = RealConfig.HandlerXP.awards.handlerPartnershipTenure1Day
        + RealConfig.HandlerXP.awards.handlerPartnershipTenure7Day
        + RealConfig.HandlerXP.awards.handlerPartnershipTenure30Day
    local certifyAward = RealConfig.HandlerXP.awards.handlerCertifyK9

    t.isTrue(topTier.xp > tenureLifetimeCap,
        ('the top rank (xp=%d) must stay OUT of reach of tenure alone (cap=%d) -- otherwise idling a single partnership for a month would be enough for the top rank'):format(topTier.xp, tenureLifetimeCap))

    -- "Roughly ten" certifications, generously combined with the full
    -- tenure cap, must clear it -- this is the "weeks, not years" half of
    -- the requirement. 15 certifications is a deliberately loose ceiling
    -- (this pass's own report cites ~7-10) so this test does not become an
    -- exact-tuning tripwire for a reasonable future adjustment.
    local reachableWithGenerousCertifying = tenureLifetimeCap + (certifyAward * 15)
    t.isTrue(topTier.xp <= reachableWithGenerousCertifying,
        ('the top rank (xp=%d) must be reachable within roughly a dozen certifications plus full tenure (%d) -- otherwise it is a multi-year wall again, just a smaller one'):format(topTier.xp, reachableWithGenerousCertifying))
end)

t.test('HANDLER LADDER: the OLD, pre-rescale thresholds (750/2500/6000) would fail the "first promotion" and "second rank from tenure alone" checks above -- documents exactly what this rescale fixed, using the real award amounts', function()
    local RealConfig = loadRealConfig()
    local certifyAward = RealConfig.HandlerXP.awards.handlerCertifyK9
    local tenureLifetimeCap = RealConfig.HandlerXP.awards.handlerPartnershipTenure1Day
        + RealConfig.HandlerXP.awards.handlerPartnershipTenure7Day
        + RealConfig.HandlerXP.awards.handlerPartnershipTenure30Day

    local OLD_CERTIFIED_HANDLER_XP = 750
    local OLD_SENIOR_HANDLER_XP = 2500

    t.isTrue(OLD_CERTIFIED_HANDLER_XP > certifyAward, 'sanity: the OLD first-promotion threshold could NOT be reached by a single certification')
    t.isTrue(OLD_SENIOR_HANDLER_XP > tenureLifetimeCap, 'sanity: the OLD second-rank threshold could NOT be reached by tenure alone, ever (155 XP lifetime cap)')
end)

-- ============================================================================
-- HIGH COMMAND COOLDOWN-MULTIPLIER BYPASS (owner-directed "high command
-- automatically gets every k9 upgrade" pass). Drives GetXPTierMedkitCooldownMs/
-- GetHandlerXPTierMedkitCooldownMs/GetHandlerXPTierKennelDeployCooldownMs
-- directly, via newProgressionFixture's own IsHighCommandBypassCitizenId/
-- handlerXpTiers knobs (soft-dependency stubs -- see that fixture's own doc
-- comments) -- never the real server/permissions.lua/server/highcommand.lua.
-- No server/k9profiles.lua loaded here, so GetK9EffectiveMultipliers stays
-- entirely absent for every test in this section -- the bypass is exercised
-- against the PLAIN tier resolution path, exactly like every citizenid who
-- has never had an individual override set.
-- ============================================================================

t.test('HIGH COMMAND BYPASS: GetXPTierMedkitCooldownMs grants the ladder\'s best multiplier to a high-command citizenid whose own real tier has none', function()
    -- Neither citizenid has earned any XP -- both resolve to the base
    -- 'Recruit K9' tier. This fixture's own ladder sets
    -- medkitCooldownMultiplier only on the top ('Elite K9') tier, so a
    -- citizenid at the base tier ordinarily gets no discount at all.
    local f = newProgressionFixture({
        isHighCommandBypassCitizenId = function(citizenid) return citizenid == 'HC-K9' end,
        xpTiers = {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.5 },
        },
    })

    t.equals(f.GetXPTierMedkitCooldownMs('ORDINARY-K9', 10000), 10000, 'control: an ordinary, non-high-command K9 at the base tier is unaffected -- no discount')
    t.equals(f.GetXPTierMedkitCooldownMs('HC-K9', 10000), 5000, 'high command must receive the BEST configured medkitCooldownMultiplier (0.5) even though their own real tier (Recruit) carries none')

    -- REQUIREMENT 2 (never let a bypass read as an earned grant): GetXPTier/
    -- GetXP themselves stay completely PURE -- the high-command citizenid's
    -- own real, earned standing is untouched, so a tablet reading either
    -- directly (server/tablet.lua's PersonSummaryResult) still tells the
    -- truth about this citizenid's actual progression.
    t.equals(f.GetXP('HC-K9'), 0, 'GetXP must never be inflated by the bypass')
    t.equals(f.GetXPTier('HC-K9').label, 'Recruit K9', 'GetXPTier must never report a tier this citizenid has not actually earned')
end)

t.test('HIGH COMMAND BYPASS: never a ceiling -- a citizenid\'s own genuinely earned, already-best multiplier is never replaced', function()
    local f = newProgressionFixture({
        isHighCommandBypassCitizenId = function(citizenid) return citizenid == 'HC-K9' end,
        xpTiers = {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.5 },
        },
    })
    f.AwardXPDirect('HC-K9', 9000, 'test-setup')
    t.equals(f.GetXPTier('HC-K9').label, 'Elite K9', 'sanity: HC-K9 genuinely earned the top tier this time')
    t.equals(f.GetXPTierMedkitCooldownMs('HC-K9', 10000), 5000, 'the real, earned Elite multiplier is used -- identical to what the bypass would have supplied, never doubled up or replaced with something worse')
end)

t.test('HIGH COMMAND BYPASS: an OFFLINE citizenid (or one who is simply not high command) gets no bypass -- real resolution, unaffected', function()
    local f = newProgressionFixture({
        isHighCommandBypassCitizenId = function(_citizenid) return false end, -- mirrors the real function's own offline/not-high-command answer
        xpTiers = {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.5 },
        },
    })
    t.equals(f.GetXPTierMedkitCooldownMs('OFFLINE-OR-NOT-HC', 10000), 10000)
end)

t.test('HIGH COMMAND BYPASS: soft dependency -- GetXPTierMedkitCooldownMs behaves exactly as before when IsHighCommandBypassCitizenId is entirely absent', function()
    local f = newProgressionFixture({
        xpTiers = {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.5 },
        },
        -- no isHighCommandBypassCitizenId supplied at all
    })
    t.isNil(f.env.IsHighCommandBypassCitizenId, 'this fixture genuinely has no IsHighCommandBypassCitizenId defined by default')
    t.equals(f.GetXPTierMedkitCooldownMs('ANYONE', 10000), 10000)
end)

t.test('HIGH COMMAND BYPASS: GetHandlerXPTierMedkitCooldownMs / GetHandlerXPTierKennelDeployCooldownMs both grant the ladder\'s best multiplier to a high-command handler with no earned rank', function()
    local f = newProgressionFixture({
        isHighCommandBypassCitizenId = function(citizenid) return citizenid == 'HC-HANDLER' end,
        handlerXpTiers = {
            { xp = 0,    label = 'Rookie Handler' },
            { xp = 5000, label = 'Master Handler', medkitTreatCooldownMultiplier = 0.70, kennelDeployCooldownMultiplier = 0.60 },
        },
    })

    t.equals(f.GetHandlerXPTierMedkitCooldownMs('ORDINARY-HANDLER', 60000), 60000, 'control: an ordinary, non-high-command handler at the base rank is unaffected')
    t.equals(f.GetHandlerXPTierKennelDeployCooldownMs('ORDINARY-HANDLER', 5000), 5000, 'control: same for the kennel-deploy cooldown')

    t.equals(f.GetHandlerXPTierMedkitCooldownMs('HC-HANDLER', 60000), 42000, 'high command must receive the BEST configured medkitTreatCooldownMultiplier (0.70) even though their own real rank (Rookie) carries none')
    t.equals(f.GetHandlerXPTierKennelDeployCooldownMs('HC-HANDLER', 5000), 3000, 'and the same for kennelDeployCooldownMultiplier (0.60)')

    -- Real earned standing stays truthful for the handler ladder too.
    t.equals(f.GetHandlerXPTier('HC-HANDLER').label, 'Rookie Handler', 'GetHandlerXPTier must never report a rank this citizenid has not actually earned')
end)

os.exit(t.summary())
