--[[
    tests/xptiereditor_spec.lua

    Tests server/xptiers.lua -- the owner-directed "set experience level for
    each rank up" pass -- against the REAL, unmodified production file, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/certtiers_spec.lua
    closely: a fake in-memory table backing every SQL statement this file
    issues (k9_xp_tiers, k9_xp_tier_audit), mutated by the real production
    callbacks exactly like a real database would be.

    Deliberately NOT re-testing server/progression.lua's own ResolveTier/
    GetXPTier/GetXPTierMedkitCooldownMs contract -- tests/xptierunlocks_spec.lua
    and tests/progression_spec.lua already own that, and server/xptiers.lua's
    own header states plainly that this pass makes ZERO changes to that file
    (verified: this spec never loads server/progression.lua at all). What
    THIS spec covers is the NEW surface: the overlay itself, its validation,
    its authorization, and its composition with a `GetXPTier`-shaped
    dependency -- a small, explicit, in-test STUB (never the real
    server/progression.lua) that resolves a citizenid's tier the exact same
    way ResolveTier does (walk Config.XPTiers, `xp >= tier.xp`), so this
    spec can control exactly which citizenid holds which XP total without
    dragging in that file's own mint-budget/cooldown machinery, which is
    irrelevant to what this file needs to prove.

    NOT COVERED HERE (disclosed, not silently skipped), same posture
    tests/certtiers_spec.lua's own header takes for the identical class of
    gap: the mutex-busy ('busy') rejection path needs a real concurrent-
    coroutine harness interleaving two MySQL.await yield points, which this
    fake, synchronous MySQL stub (every call returns immediately, no real
    yield) cannot produce -- there is nothing to interleave. What IS
    covered: the whole-ladder ascending-order re-validation this mutex
    protects behaves correctly for a SEQUENCE of edits from one actor,
    including the specific "walk-into-invalid-state" shape a validator
    comparing against STALE data would get wrong (see SECTION 3 below).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @return table world
local function newWorld()
    return {
        tiers = {},  -- ordinal -> { xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge, updated_by }
        audit = {},  -- array of { action, ordinal, detail, changed_by }
    }
end

--- @param world table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT ordinal, xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge FROM k9_xp_tiers', 1, true) then
            local out = {}
            for ordinal, row in pairs(world.tiers) do
                out[#out + 1] = {
                    ordinal = ordinal, xp_threshold = row.xp_threshold, label = row.label,
                    speed_multiplier = row.speed_multiplier, scent_range_multiplier = row.scent_range_multiplier,
                    medkit_cooldown_multiplier = row.medkit_cooldown_multiplier, badge = row.badge,
                }
            end
            return out
        elseif sql:find('INSERT INTO k9_xp_tiers', 1, true) then
            local ordinal, xpThreshold, label, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier, badge, updatedBy =
                params[1], params[2], params[3], params[4], params[5], params[6], params[7], params[8]
            world.tiers[ordinal] = {
                xp_threshold = xpThreshold, label = label, speed_multiplier = speedMultiplier,
                scent_range_multiplier = scentRangeMultiplier, medkit_cooldown_multiplier = medkitCooldownMultiplier,
                badge = badge, updated_by = updatedBy,
            }
            return {}
        elseif sql:find('INSERT INTO k9_xp_tier_audit', 1, true) then
            world.audit[#world.audit + 1] = { action = params[1], ordinal = params[2], detail = params[3], changed_by = params[4] }
            return {}
        end
        error('xptiereditor_spec test stub: unhandled MySQL.query.await SQL: ' .. tostring(sql))
    end
end

--- Default fixture Config.XPTiers -- byte-shaped like config.lua's real
--- shipped ladder (four ranks, base=0, Veteran carries medkitCooldownMultiplier,
--- Elite carries badge) so every test below exercises the real optional-field
--- shape, not a simplified stand-in.
--- @return table[]
local function defaultXpTiers()
    return {
        { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10, medkitCooldownMultiplier = 0.75 },
        { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, badge = 'elite' },
    }
end

--- @param opts table? -- { world, config, isHighCommand, xpByCitizenid, onlineSources, databaseEnabled }
--- @return table fixture
local function boot(opts)
    opts = opts or {}
    local world = opts.world or newWorld()

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- citizenid -> accumulated XP, entirely test-controlled. Both
    -- exports.qbx_core:GetPlayerByCitizenId (server/xptiers.lua does not
    -- call this directly -- kept for parity/future use) and the GetXPTier
    -- stub below read from this SAME table, so a test can move a
    -- citizenid's XP and have both "who is online" and "what tier do they
    -- currently resolve to" agree automatically.
    local xpByCitizenid = opts.xpByCitizenid or {}

    -- onlineSources[src] = citizenid -- what GetPlayers()/exports.qbx_core:GetPlayer
    -- report as currently connected.
    local onlineSources = opts.onlineSources or {}

    local function GetPlayersStub()
        local out = {}
        for src in pairs(onlineSources) do out[#out + 1] = tostring(src) end
        return out
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = onlineSources[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid, source = src } }
            end,
        },
    }

    -- Declared BEFORE GetXPTierStub below (Lua's `local` scoping is
    -- position-based -- a closure defined ABOVE a later `local config = ...`
    -- would otherwise silently capture an unrelated GLOBAL `config`, not
    -- this variable) -- moved up here specifically to avoid that trap.
    local config = opts.config or {
        XPTiers = opts.xpTiers or defaultXpTiers(),
        Features = { HighCommand = true, XPProgression = opts.xpProgressionEnabled ~= false },
        Database = opts.databaseEnabled == false and { enabled = false } or nil,
    }

    -- STUB, never the real server/progression.lua -- see this file's own
    -- header for why. Resolves EXACTLY like the real ResolveTier: walk
    -- Config.XPTiers (the live, possibly-just-mutated-by-this-pass array),
    -- `xp >= tier.xp`, no `break`, last match wins.
    local function GetXPTierStub(citizenid)
        local xp = xpByCitizenid[citizenid] or 0
        local resolved = config.XPTiers[1]
        for _, tier in ipairs(config.XPTiers) do
            if xp >= tier.xp then resolved = tier end
        end
        return resolved
    end

    local pushedEvents = {} -- array of { eventName, targetSrc, payload }
    local function TriggerClientEventStub(eventName, targetSrc, payload)
        pushedEvents[#pushedEvents + 1] = { eventName = eventName, targetSrc = targetSrc, payload = payload }
    end

    local isHighCommand = opts.isHighCommand or function() return false end

    local fakeNow = { value = 0 }
    local envOverrides = {
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetPlayers             = GetPlayersStub,
        TriggerClientEvent     = TriggerClientEventStub,
        print                  = printStub,
        lib                    = lib,
        exports                = exportsStub,
        MySQL                  = { query = { await = makeQueryAwait(world) } },
        IsHighCommand          = isHighCommand,
        Config                 = config,
        GetXPTier              = GetXPTierStub,
    }
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)

    -- server/datastore.lua -- REAL, unmodified, loaded alongside (same
    -- "the ONLY place in this resource that may name a `k9_*` table or call
    -- `MySQL.*` directly" precedent tests/certtiers_spec.lua's own header
    -- documents). Config.Database is honored via this fixture's own
    -- `databaseEnabled` option -- when omitted/true, K9Store.DatabaseEnabled()
    -- reads real-DB mode and every K9Store.XPTier_* call below runs the SAME
    -- MySQL.query.await call (against this file's own makeQueryAwait(world)
    -- stub) the production accessors issue; when `databaseEnabled = false`,
    -- K9Store's own in-memory branch is exercised instead, with ZERO
    -- production-code change needed to reach it.
    Sandbox.loadInto('../server/datastore.lua', env)
    for i = #printedLines, 1, -1 do printedLines[i] = nil end -- discard datastore.lua's own one boot line

    Sandbox.loadInto('../server/xptiers.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env, world = world, callbacks = callbacks, printedLines = printedLines,
        fakeNow = fakeNow, pushedEvents = pushedEvents, xpByCitizenid = xpByCitizenid,
        onlineSources = onlineSources, config = config,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

--- Valid payload for editing `ordinal`, defaulting every OTHER field to
--- whatever `f.config.XPTiers[ordinal]` currently holds -- so a test only
--- needs to name the one field it actually wants to change.
--- @param f table
--- @param ordinal number
--- @param overrides table?
local function validPayload(f, ordinal, overrides)
    local tier = f.config.XPTiers[ordinal]
    local payload = {
        ordinal = ordinal,
        xp = tier.xp,
        label = tier.label,
        speedMultiplier = tier.speedMultiplier,
        scentRangeMultiplier = tier.scentRangeMultiplier,
        medkitCooldownMultiplier = tier.medkitCooldownMultiplier,
        badge = tier.badge,
    }
    for k, v in pairs(overrides or {}) do payload[k] = v end
    return payload
end

--- Advances `f`'s own fake clock past XP_TIER_ACTION_COOLDOWN_MS (1000ms) --
--- every test below that issues MORE THAN ONE xpTiersUpsert call from the
--- SAME acting source must call this BETWEEN calls, or the second call
--- observes 'rate_limited' instead of whatever this file actually wants to
--- assert about it (the real anti-fat-finger cooldown is checked BEFORE
--- payload validation in server/xptiers.lua, deliberately -- see that
--- file's own callback ordering). The dedicated RATE LIMIT test below is
--- the one place this is NEVER called between two calls, on purpose.
--- @param f table
local function advance(f)
    f.fakeNow.value = f.fakeNow.value + 1100
end

-- ============================================================================
-- SECTION 1 -- registration + authorization
-- ============================================================================

t.test('registration: both callbacks are registered', function()
    local f = boot()
    t.isNotNil(f.callbacks['john-k9:server:xpTiersList'], 'xpTiersList must be registered')
    t.isNotNil(f.callbacks['john-k9:server:xpTiersUpsert'], 'xpTiersUpsert must be registered')
end)

t.test('AUTHORIZATION: xpTiersList denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersList'](NON_HC_SOURCE)
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('AUTHORIZATION: xpTiersUpsert denies a non-high-command source, and makes NO change at all', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local before = f.config.XPTiers[4].xp
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](NON_HC_SOURCE, validPayload(f, 4, { xp = 20000 }))
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.equals(f.config.XPTiers[4].xp, before, 'a denied caller must never be able to mutate Config.XPTiers')
end)

t.test('AUTHORIZATION: xpTiersList succeeds for a genuine high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersList'](HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(#result.tiers, 4)
end)

-- ============================================================================
-- SECTION 2 -- OVERLAY PRECEDENCE (DB row wins; an un-touched rank stays at
-- config.lua's own default, byte for byte).
-- ============================================================================

t.test('OVERLAY: a persisted k9_xp_tiers row for one rank overrides config.lua\'s default for THAT rank only', function()
    local world = newWorld()
    world.tiers[2] = { xp_threshold = 1500, label = 'Rookie K9', speed_multiplier = 1.06, scent_range_multiplier = 1.06, updated_by = 'ABC' }
    local f = boot({ world = world })

    t.equals(f.config.XPTiers[2].xp, 1500, 'rank 2 threshold must reflect the persisted override')
    t.equals(f.config.XPTiers[2].label, 'Rookie K9')
    t.equals(f.config.XPTiers[2].speedMultiplier, 1.06)

    -- Untouched ranks stay EXACTLY at config.lua's own shipped defaults.
    t.equals(f.config.XPTiers[1].xp, 0)
    t.equals(f.config.XPTiers[3].xp, 4000)
    t.equals(f.config.XPTiers[3].medkitCooldownMultiplier, 0.75)
    t.equals(f.config.XPTiers[4].badge, 'elite')
end)

t.test('OVERLAY: zero-behavior-change default -- no tablet edit ever made leaves Config.XPTiers byte-identical to config.lua', function()
    local f = boot()
    local tiers = defaultXpTiers()
    for i = 1, 4 do
        t.equals(f.config.XPTiers[i].xp, tiers[i].xp)
        t.equals(f.config.XPTiers[i].label, tiers[i].label)
        t.equals(f.config.XPTiers[i].speedMultiplier, tiers[i].speedMultiplier)
        t.equals(f.config.XPTiers[i].scentRangeMultiplier, tiers[i].scentRangeMultiplier)
    end
end)

t.test('OVERLAY: xpTiersList reflects the live (possibly overridden) values, and marks ONLY rank 1 as xpLocked', function()
    local world = newWorld()
    world.tiers[3] = { xp_threshold = 5000, label = 'Veteran K9', speed_multiplier = 1.10, scent_range_multiplier = 1.10, medkit_cooldown_multiplier = 0.75, updated_by = 'ABC' }
    local f = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })

    local result = f.callbacks['john-k9:server:xpTiersList'](HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(result.tiers[3].xp, 5000)
    t.isTrue(result.tiers[1].xpLocked, 'rank 1 must be reported as locked')
    t.isFalse(result.tiers[2].xpLocked)
    t.isFalse(result.tiers[3].xpLocked)
    t.isFalse(result.tiers[4].xpLocked)
end)

-- ============================================================================
-- SECTION 3 -- ASCENDING-ORDER ENFORCEMENT, including the WALK-INTO-INVALID
-- -STATE sequence this file's own header names explicitly.
-- ============================================================================

t.test('ORDER: an edit that would tie or invert two ranks is REJECTED outright', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })

    local tie = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 9000 })) -- ties rank 4
    t.isFalse(tie.ok)
    t.equals(tie.reason, 'invalid_order')

    advance(f)
    local invert = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 9500 })) -- exceeds rank 4
    t.isFalse(invert.ok)
    t.equals(invert.reason, 'invalid_order')

    t.equals(f.config.XPTiers[3].xp, 4000, 'a rejected edit must leave the live ladder completely unchanged')
end)

t.test('ORDER: a genuinely valid re-threshold between its two live neighbors is accepted', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 5000 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.equals(f.config.XPTiers[3].xp, 5000)
end)

t.test('WALK-INTO-INVALID-STATE: two sequential edits that a validator comparing against STALE (config-only) neighbor data would wrongly allow, correctly rejected by this file\'s LIVE whole-ladder re-check', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })

    -- Edit 1: rank 3 (Veteran, config default 4000) -> 8990. Valid against
    -- its LIVE neighbors (rank 2 = 1250, rank 4 = 9000).
    local edit1 = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 8990 }))
    t.isTrue(edit1.ok, tostring(edit1.reason))
    t.equals(f.config.XPTiers[3].xp, 8990)

    -- Edit 2: rank 4 (Elite, config default 9000) -> 5000. A validator
    -- comparing against rank 3's STATIC CONFIG value (4000) would see
    -- 5000 > 4000 and wrongly ALLOW this -- but the LIVE rank 3 is now 8990,
    -- so 5000 must be REJECTED. This is the exact two-edit sequence this
    -- file's own header describes under "THE WALK-INTO-INVALID-STATE
    -- HAZARD".
    advance(f)
    local edit2 = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { xp = 5000 }))
    t.isFalse(edit2.ok, 'a validator comparing against stale config data would wrongly accept this -- the real file must not')
    t.equals(edit2.reason, 'invalid_order')
    t.equals(f.config.XPTiers[4].xp, 9000, 'the rejected edit must leave rank 4 completely unchanged')
end)

t.test('SCOPE: rank 1\'s threshold can never be moved off 0 -- rejected with a distinct reason, not folded into invalid_order/invalid_xp', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 1, { xp = 500 }))
    t.isFalse(result.ok)
    t.equals(result.reason, 'base_tier_xp_fixed')
    t.equals(f.config.XPTiers[1].xp, 0)
end)

t.test('SCOPE: rank 1\'s label/multipliers ARE still editable -- only the threshold is fixed', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 1, { label = 'Rookie K9', speedMultiplier = 1.02 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.equals(f.config.XPTiers[1].xp, 0)
    t.equals(f.config.XPTiers[1].label, 'Rookie K9')
    t.equals(f.config.XPTiers[1].speedMultiplier, 1.02)
end)

-- ============================================================================
-- SECTION 4 -- THE ALREADY-PROMOTED PLAYER
-- ============================================================================

t.test('ALREADY-PROMOTED PLAYER: raising a threshold above an online citizenid\'s real XP demotes them immediately, pushes a fresh snapshot, and the response discloses it', function()
    local citizenid = 'ABC123'
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        xpByCitizenid = { [citizenid] = 10000 }, -- currently Elite (>= 9000)
        onlineSources = { [65] = citizenid },
    })

    t.equals(f.env.GetXPTier(citizenid).label, 'Elite K9', 'sanity check on this test\'s own fixture')

    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { xp = 15000 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.isNotNil(result.warning, 'a demotion must be disclosed in the response, not just logged')
    t.isTrue(result.warning:find('1', 1, true) ~= nil, 'the warning should name the count of demoted, currently-online K9s')

    t.equals(f.env.GetXPTier(citizenid).label, 'Veteran K9', 'the citizenid must now resolve to a LOWER rank -- their real XP total is unchanged, only the threshold moved')

    t.equals(#f.pushedEvents, 1, 'exactly one fresh snapshot must be pushed to the one online, affected citizenid')
    t.equals(f.pushedEvents[1].eventName, 'john-k9:client:xpTierChanged')
    t.equals(f.pushedEvents[1].targetSrc, 65)
    t.equals(f.pushedEvents[1].payload.label, 'Veteran K9')
end)

t.test('ALREADY-PROMOTED PLAYER: an edit that does NOT cross anyone\'s current bracket reports no warning at all', function()
    local citizenid = 'ABC123'
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        xpByCitizenid = { [citizenid] = 500 }, -- Recruit -- nowhere near rank 4
        onlineSources = { [65] = citizenid },
    })

    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { xp = 15000 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.isNil(result.warning, 'nobody currently online was demoted by this edit -- no warning should be manufactured')

    -- The online citizenid still gets a refreshed (unchanged) snapshot --
    -- harmless, and client/progression.lua's own existing "notify only on a
    -- real label change" rule means this produces no visible toast either.
    t.equals(#f.pushedEvents, 1)
    t.equals(f.pushedEvents[1].payload.label, 'Recruit K9')
end)

t.test('ALREADY-PROMOTED PLAYER: an OFFLINE citizenid at the same XP is silently unaffected by this edit\'s own push (nothing to push to)', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        xpByCitizenid = { ['NOBODY_ONLINE'] = 10000 },
        onlineSources = {}, -- nobody connected
    })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { xp = 15000 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.isNil(result.warning, 'an offline citizenid is never counted -- there is no live session to disclose a demotion to')
    t.equals(#f.pushedEvents, 0)
end)

-- ============================================================================
-- SECTION 4B -- SELF-SERVICE VISIBILITY (economy red-team follow-up,
-- coder-security pass): LOWERING a threshold never demotes anyone -- it can
-- only PROMOTE an online citizenid with zero additional XP earned. Before
-- this pass, that direction produced `demotedCount == 0`, so the response
-- carried NO warning and the audit line carried no trace of who gained a
-- rank -- exactly the "quietly self-grant, then quietly revert" shape this
-- section closes.
-- ============================================================================

t.test('SELF-SERVICE VISIBILITY: lowering a threshold promotes an online citizenid immediately, and the response NAMES them (the exact gap this pass closes)', function()
    local citizenid = 'PROMO1'
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        xpByCitizenid = { [citizenid] = 2000 }, -- currently Trained (1250 <= 2000 < 4000)
        onlineSources = { [77] = citizenid },
    })
    t.equals(f.env.GetXPTier(citizenid).label, 'Trained K9', 'sanity check on this test\'s own fixture')

    -- Lowers rank 3 (Veteran, default 4000) to 1500 -- still a valid ladder
    -- (1250 < 1500 < 9000) -- but now PROMOTES citizenid (2000 XP) from
    -- Trained straight to Veteran with zero additional XP earned.
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 1500 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.isNotNil(result.warning, 'a promotion must be disclosed in the response -- BEFORE this pass this exact edit shape produced NO warning at all')
    t.isTrue(result.warning:find('HIGHER', 1, true) ~= nil, 'the warning must name this as a promotion, not a generic re-rank')
    t.isTrue(result.warning:find(citizenid, 1, true) ~= nil, 'the warning must NAME the promoted citizenid, not just count them')
    t.isNil(result.warning:find('SELF%-PROMOTION'), 'the acting officer here is a different citizenid than the one promoted -- no self-promotion callout is warranted')

    t.equals(f.env.GetXPTier(citizenid).label, 'Veteran K9', 'the citizenid must now resolve to a HIGHER rank -- their real XP total is unchanged, only the threshold moved')

    t.equals(#f.world.audit, 1)
    t.isTrue(f.world.audit[1].detail:find('HIGHER', 1, true) ~= nil, 'the audit detail must record the promotion, not just the raw xp field change')
    t.isTrue(f.world.audit[1].detail:find(citizenid, 1, true) ~= nil, 'the audit detail must NAME the promoted citizenid')
end)

t.test('SELF-PROMOTION: when the acting officer\'s OWN citizenid is among those promoted by their own edit, both the response and the audit flag it distinctly', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    -- The acting officer must be "online" (per ResolveCitizenId) for their
    -- own citizenid to be resolvable at all -- exactly the same fixture
    -- requirement the pre-existing AUDIT section below already documents.
    f.onlineSources[HC_SOURCE] = 'OFFICER1'
    f.xpByCitizenid['OFFICER1'] = 2000 -- currently Trained, same shape as above

    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 1500 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.isNotNil(result.warning)
    t.isTrue(result.warning:find('SELF%-PROMOTION') ~= nil, 'the response must call out that the ACTING OFFICER is among those promoted by their own edit')

    t.equals(#f.world.audit, 1)
    t.isTrue(f.world.audit[1].detail:find('SELF%-PROMOTION') ~= nil, 'the audit trail must record the self-promotion distinctly, not fold it into a generic re-rank line')
    t.isTrue(f.world.audit[1].detail:find('OFFICER1', 1, true) ~= nil, 'the audit trail must name the promoted (self) citizenid')
end)

t.test('SELF-SERVICE VISIBILITY: a REVERT (raising the threshold back) is exactly as visible in the log as the promotion it undoes', function()
    local citizenid = 'PROMO1'
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        xpByCitizenid = { [citizenid] = 2000 },
        onlineSources = { [77] = citizenid },
    })

    local promote = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 1500 }))
    t.isTrue(promote.ok, tostring(promote.reason))
    t.equals(f.env.GetXPTier(citizenid).label, 'Veteran K9')

    advance(f)
    local revert = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { xp = 4000 }))
    t.isTrue(revert.ok, tostring(revert.reason))
    t.isNotNil(revert.warning, 'the revert demotes citizenid back down -- it must be disclosed exactly like the original promotion was')
    t.isTrue(revert.warning:find('LOWER', 1, true) ~= nil)
    t.equals(f.env.GetXPTier(citizenid).label, 'Trained K9', 'the revert must actually put them back where they started')

    t.equals(#f.world.audit, 2, 'both the original promotion and its revert must each produce their own audit row')
    t.isTrue(f.world.audit[1].detail:find('HIGHER', 1, true) ~= nil, 'row 1: the original promotion')
    t.isTrue(f.world.audit[2].detail:find('LOWER', 1, true) ~= nil, 'row 2: the revert, equally visible')
end)

t.test('SELF-SERVICE VISIBILITY: legitimate equivalent still works -- a normal threshold edit HC is authorized to make completes with no self-service noise', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    -- No online citizenid anywhere near rank 2's own bracket -- an ordinary,
    -- unremarkable tuning edit must still succeed cleanly, with neither a
    -- promotion nor a demotion warning manufactured for it.
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 1300 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.isNil(result.warning, 'an edit with no online population near the crossed threshold must not manufacture a warning')
    t.equals(f.config.XPTiers[2].xp, 1300)
end)

-- ============================================================================
-- SECTION 5 -- CLAMP AND WARN, NEVER ASSERT, ON BAD PERSISTED VALUES
-- ============================================================================

t.test('CLAMP-AND-WARN: a persisted row with an out-of-range ordinal is ignored entirely, with a warning, and boot does not error', function()
    local world = newWorld()
    world.tiers[99] = { xp_threshold = 5000, label = 'Ghost', speed_multiplier = 1.0, scent_range_multiplier = 1.0, updated_by = 'ABC' }
    local f = boot({ world = world })
    t.equals(#f.config.XPTiers, 4, 'an out-of-range ordinal must never grow or shrink the ladder')
    local sawWarning = false
    for _, line in ipairs(f.printedLines) do
        if line:find('out-of-range ordinal', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning, 'a warning naming the problem must be printed')
end)

t.test('CLAMP-AND-WARN: a persisted rank-1 row attempting a non-zero threshold is CLAMPED to 0, not rejected wholesale -- the rest of the row still applies', function()
    local world = newWorld()
    world.tiers[1] = { xp_threshold = 500, label = 'Rookie K9', speed_multiplier = 1.01, scent_range_multiplier = 1.01, updated_by = 'ABC' }
    local f = boot({ world = world })
    t.equals(f.config.XPTiers[1].xp, 0, 'rank 1 must always resolve to exactly 0 XP regardless of what was persisted')
    t.equals(f.config.XPTiers[1].label, 'Rookie K9', 'the rest of the row is still legitimate and must still apply')
    t.equals(f.config.XPTiers[1].speedMultiplier, 1.01)
end)

t.test('CLAMP-AND-WARN: an invalid persisted label falls back to config.lua\'s own default for that rank alone', function()
    local world = newWorld()
    world.tiers[2] = { xp_threshold = 1300, label = '<script>', speed_multiplier = 1.06, scent_range_multiplier = 1.06, updated_by = 'ABC' }
    local f = boot({ world = world })
    t.equals(f.config.XPTiers[2].xp, 1300, 'the valid field on this same row must still apply')
    t.equals(f.config.XPTiers[2].label, 'Trained K9', 'an unsafe label must fall back to the config default, never reach a live table verbatim')
end)

t.test('CLAMP-AND-WARN: an invalid persisted multiplier (out of range) falls back to config.lua\'s own default for that field alone', function()
    local world = newWorld()
    world.tiers[2] = { xp_threshold = 1300, label = 'Trained K9', speed_multiplier = 999, scent_range_multiplier = 1.06, updated_by = 'ABC' }
    local f = boot({ world = world })
    t.equals(f.config.XPTiers[2].speedMultiplier, 1.05, 'an absurd persisted multiplier must never reach the live movement-speed composer')
    t.equals(f.config.XPTiers[2].scentRangeMultiplier, 1.06, 'the OTHER, valid field on this same row must still apply')
end)

t.test('ZERO-THRESHOLD FOOTGUN: a persisted medkit_cooldown_multiplier of 0 is rejected at load time, never reaching GetXPTierMedkitCooldownMs as a permanently-on threshold', function()
    local world = newWorld()
    world.tiers[3] = { xp_threshold = 4000, label = 'Veteran K9', speed_multiplier = 1.10, scent_range_multiplier = 1.10, medkit_cooldown_multiplier = 0, updated_by = 'ABC' }
    local f = boot({ world = world })
    t.equals(f.config.XPTiers[3].medkitCooldownMultiplier, 0.75, 'a non-positive persisted multiplier must fall back to the config default (or nil), never apply 0 verbatim')
end)

t.test('CLAMP-AND-WARN: TWO individually-valid rows that combine into a non-ascending ladder are refused ALL-OR-NOTHING -- every rank falls back to its config.lua default', function()
    local world = newWorld()
    -- Each row is individually well-typed and in-range -- the problem only
    -- exists in COMBINATION (rank 3 ends up above rank 4), which can only
    -- happen through a hand-edited database (this file's own xpTiersUpsert
    -- re-validates the whole ladder before every write it makes, so this
    -- combination could never be produced through the tablet itself).
    world.tiers[3] = { xp_threshold = 8990, label = 'Veteran K9', speed_multiplier = 1.10, scent_range_multiplier = 1.10, updated_by = 'ABC' }
    world.tiers[4] = { xp_threshold = 5000, label = 'Elite K9', speed_multiplier = 1.15, scent_range_multiplier = 1.20, updated_by = 'ABC' }
    local f = boot({ world = world })

    t.equals(f.config.XPTiers[3].xp, 4000, 'refused as a whole -- rank 3 must fall back to its config default')
    t.equals(f.config.XPTiers[4].xp, 9000, 'refused as a whole -- rank 4 must fall back to its config default')

    local sawRefusal = false
    for _, line in ipairs(f.printedLines) do
        if line:find('REFUSING to apply ANY persisted', 1, true) then sawRefusal = true end
    end
    t.isTrue(sawRefusal, 'a loud, explicit refusal must be printed -- this must never fail silently')
end)

-- ============================================================================
-- SECTION 6 -- Config.Database.enabled = false (memory mode) still fully
-- works for a live session -- it only forgets on the NEXT restart, which is
-- an inherent, already-covered property of K9Store's own memory-mode
-- design (tests/datastore_spec.lua), not re-proven here.
-- ============================================================================

t.test('Config.Database.enabled = false: list/upsert/list round-trips correctly with no real MySQL involved at all', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end, databaseEnabled = false })

    local before = f.callbacks['john-k9:server:xpTiersList'](HC_SOURCE)
    t.equals(before.tiers[2].xp, 1250)

    local upserted = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 1500, label = 'Rookie K9' }))
    t.isTrue(upserted.ok, tostring(upserted.reason))

    local after = f.callbacks['john-k9:server:xpTiersList'](HC_SOURCE)
    t.equals(after.tiers[2].xp, 1500)
    t.equals(after.tiers[2].label, 'Rookie K9')
end)

-- ============================================================================
-- SECTION 7 -- INPUT VALIDATION: non-numeric/non-positive/malformed values,
-- treated as adversarial input, never asserted on.
-- ============================================================================

t.test('VALIDATION: invalid_ordinal for a non-number, out-of-range, or fractional ordinal', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { ordinal = 'two' })).reason, 'invalid_ordinal')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { ordinal = 99 })).reason, 'invalid_ordinal')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { ordinal = 2.5 })).reason, 'invalid_ordinal')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { ordinal = 0 })).reason, 'invalid_ordinal')
end)

t.test('VALIDATION: invalid_xp for a negative, fractional, NaN, or non-numeric threshold on a non-base rank', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = -5 })).reason, 'invalid_xp')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 1500.5 })).reason, 'invalid_xp')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 0/0 })).reason, 'invalid_xp')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 'lots' })).reason, 'invalid_xp')
end)

t.test('VALIDATION: a numeric-looking STRING xp/multiplier is COERCED (tonumber), matching a plain HTML form field\'s own natural shape', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = '1500', speedMultiplier = '1.06' }))
    t.isTrue(result.ok, tostring(result.reason))
    t.equals(f.config.XPTiers[2].xp, 1500)
    t.equals(f.config.XPTiers[2].speedMultiplier, 1.06)
end)

t.test('VALIDATION: invalid_label for an empty, oversized, or unsafe-character label', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { label = '' })).reason, 'invalid_label')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { label = ('x'):rep(61) })).reason, 'invalid_label')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { label = '<b>Trained</b>' })).reason, 'invalid_label')
end)

t.test('VALIDATION: invalid_speed_multiplier / invalid_scent_range_multiplier for non-positive, NaN, or above-ceiling values', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 0 })).reason, 'invalid_speed_multiplier')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = -1 })).reason, 'invalid_speed_multiplier')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 500 })).reason, 'invalid_speed_multiplier')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { scentRangeMultiplier = 0/0 })).reason, 'invalid_scent_range_multiplier')
end)

-- ============================================================================
-- OWNER-EDITABLE CEILING (Config.MaxSpeedScentMultiplier, Part A). This
-- file's own MAX_SPEED_SCENT_MULTIPLIER used to be a hardcoded 3.0; it is
-- now resolved fresh from config.lua at file-load time via this file's own
-- local ResolveMaxSpeedScentMultiplier (server/k9profiles.lua's identical
-- resolver already carries the full "no cross-file `local` import
-- mechanism" writeup -- not repeated here).
-- ============================================================================

t.test('CEILING IS GENUINELY CONFIG-DRIVEN: Config.MaxSpeedScentMultiplier = 5.0 accepts 4.9 and rejects 5.1', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        config = { XPTiers = defaultXpTiers(), Features = { HighCommand = true, XPProgression = true }, Database = { enabled = false }, MaxSpeedScentMultiplier = 5.0 },
    })
    t.isTrue(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 4.9 })).ok)
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 5.1 })).reason, 'invalid_speed_multiplier')
end)

t.test('CEILING IS GENUINELY CONFIG-DRIVEN: a simulated reboot at Config.MaxSpeedScentMultiplier = 50.0 now accepts 40.0 (would have been rejected under the old hardcoded 3.0)', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        config = { XPTiers = defaultXpTiers(), Features = { HighCommand = true, XPProgression = true }, Database = { enabled = false }, MaxSpeedScentMultiplier = 50.0 },
    })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 40.0 }))
    t.isTrue(result.ok, tostring(result.reason))
    t.equals(f.config.XPTiers[2].speedMultiplier, 40.0)
end)

t.test('CEILING: 0, negative, NaN, infinity and a string are each rejected at a NON-DEFAULT ceiling too, and the call never errors (pcall)', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        config = { XPTiers = defaultXpTiers(), Features = { HighCommand = true, XPProgression = true }, Database = { enabled = false }, MaxSpeedScentMultiplier = 5.0 },
    })
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -1, nan, math.huge, -math.huge, 'not a number' }) do
        advance(f)
        local ok, result = pcall(f.callbacks['john-k9:server:xpTiersUpsert'], HC_SOURCE, validPayload(f, 2, { speedMultiplier = bad }))
        t.isTrue(ok, ('must never throw for speedMultiplier = %s'):format(tostring(bad)))
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_speed_multiplier', tostring(bad))
    end
end)

t.test('CEILING: Config.MaxSpeedScentMultiplier missing entirely falls back to 10.0 with a named warning, never asserts/crashes the file', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end }) -- default config from boot() never sets MaxSpeedScentMultiplier
    t.isNotNil(f.callbacks['john-k9:server:xpTiersUpsert'])
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.MaxSpeedScentMultiplier', 1, true) and line:find('10', 1, true) then found = true end
    end
    t.isTrue(found, 'a missing Config.MaxSpeedScentMultiplier must print a warning naming the exact setting and the 10.0 fallback')

    t.isTrue(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 10.0 })).ok)
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { speedMultiplier = 10.01 })).reason, 'invalid_speed_multiplier')
end)

t.test('VALIDATION: invalid_medkit_cooldown_multiplier for a present-but-out-of-(0,1]-range value; nil/omitted is always fine', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { medkitCooldownMultiplier = 0 })).reason, 'invalid_medkit_cooldown_multiplier')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 3, { medkitCooldownMultiplier = 1.5 })).reason, 'invalid_medkit_cooldown_multiplier')

    -- Built WITHOUT the `overrides` merge helper above: `{ medkitCooldownMultiplier
    -- = nil }` as an OVERRIDES table would never even set the key (a nil-valued
    -- entry in a Lua table constructor is indistinguishable from an absent
    -- one), so this explicitly CLEARS an already-real value on the payload
    -- table after construction -- the only way to actually exercise "the
    -- field was omitted" from a payload that otherwise defaults every field
    -- to the rank's current value.
    advance(f)
    local clearedPayload = validPayload(f, 3)
    clearedPayload.medkitCooldownMultiplier = nil
    local removedOk = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, clearedPayload)
    t.isTrue(removedOk.ok, tostring(removedOk.reason))
    t.isNil(f.config.XPTiers[3].medkitCooldownMultiplier, 'an omitted optional field must clear it, matching an absent config.lua field exactly')
end)

t.test('VALIDATION: invalid_badge for a present-but-unsafe/oversized value; nil/omitted is always fine', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { badge = ('x'):rep(31) })).reason, 'invalid_badge')
    advance(f)
    t.equals(f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { badge = '<x>' })).reason, 'invalid_badge')

    advance(f)
    local ok = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 4, { badge = 'legend' }))
    t.isTrue(ok.ok, tostring(ok.reason))
    t.equals(f.config.XPTiers[4].badge, 'legend')
end)

t.test('VALIDATION: an invalid payload shape (not a table) is rejected as invalid_payload, never errors', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, 'not-a-table')
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_payload')
end)

t.test('RATE LIMIT: a second rapid xpTiersUpsert from the SAME source is rejected as rate_limited', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local first = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 1300 }))
    t.isTrue(first.ok, tostring(first.reason))
    local second = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 1400 }))
    t.isFalse(second.ok)
    t.equals(second.reason, 'rate_limited')
end)

-- ============================================================================
-- SECTION 8 -- AUDIT
-- ============================================================================

t.test('AUDIT: a successful edit writes exactly one k9_xp_tier_audit row naming the rank, the acting citizenid, and every changed field', function()
    local f = boot({ isHighCommand = function(src)
        return src == HC_SOURCE
    end })
    -- IsHighCommand does not resolve a citizenid on its own in this fixture
    -- -- server/xptiers.lua's own ResolveCitizenId reads
    -- exports.qbx_core:GetPlayer(source).PlayerData.citizenid, so the
    -- acting officer must be "online" in this fixture for a real citizenid
    -- (rather than 'unknown') to land in the audit row.
    f.onlineSources[HC_SOURCE] = 'OFFICER1'

    local result = f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = 1300, label = 'Rookie K9' }))
    t.isTrue(result.ok, tostring(result.reason))

    t.equals(#f.world.audit, 1)
    t.equals(f.world.audit[1].action, 'xp_tier_update')
    t.equals(f.world.audit[1].ordinal, 2)
    t.equals(f.world.audit[1].changed_by, 'OFFICER1')
    t.isTrue(f.world.audit[1].detail:find('xp: 1250 %-> 1300') ~= nil, 'detail must record the OLD -> NEW xp')
    t.isTrue(f.world.audit[1].detail:find('Trained K9') ~= nil, 'detail must record the OLD label')
    t.isTrue(f.world.audit[1].detail:find('Rookie K9') ~= nil, 'detail must record the NEW label')
end)

t.test('AUDIT: a rejected edit (denied, rate-limited, or invalid) writes NOTHING to k9_xp_tier_audit', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:xpTiersUpsert'](NON_HC_SOURCE, validPayload(f, 2, { xp = 1300 }))
    f.callbacks['john-k9:server:xpTiersUpsert'](HC_SOURCE, validPayload(f, 2, { xp = -5 }))
    t.equals(#f.world.audit, 0)
end)

-- ============================================================================
-- SECTION 9 -- BOOT-ORDER RACE against server/datastore.lua's schema-
-- collision probe (interaction review + fix, db-schema boot-order pass).
--
-- server/datastore.lua loads before this file and registers its own
-- onResourceStart handler FIRST -- but that handler's own MySQL.query.await
-- is a real, YIELDING call, and a yielding handler does not block FXServer's
-- event dispatch from moving straight on to the NEXT registered handler
-- (this file's own, below) while the probe is still in flight. The `boot()`
-- helper above uses a synchronous `makeQueryAwait(world)` stub (a plain Lua
-- function -- never yields), so it cannot exercise this, same disclosed
-- limitation this file's own header already states for the SEPARATE
-- mutex-busy race. This section builds its own small, separate,
-- coroutine-based dispatcher instead, reproducing that ONE real FXServer
-- property precisely: every onResourceStart handler registered for the same
-- event runs in its OWN coroutine, in registration order, and a handler
-- that yields hands control back immediately rather than blocking the next
-- one. See server/datastore.lua's own K9Store.WaitForSchemaCheckToSettle
-- for the fix this proves.
-- ============================================================================

--- @param opts table? -- { foreignXpTierRows: table? -- canned response for
---   this file's own `SELECT ordinal, xp_threshold, label, speed_multiplier,
---   scent_range_multiplier, medkit_cooldown_multiplier, badge FROM
---   k9_xp_tiers` if it is ever actually issued }
--- @return table fixture -- { env, printedLines, coros, fireResourceStart,
---   resumeNext, xpTierQueryCallCount }
local function bootWithRacingMySQL(opts)
    opts = opts or {}

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, fn)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = fn
    end

    -- The probe's own INFORMATION_SCHEMA query YIELDS and is resumed only
    -- when the test explicitly resumes that coroutine -- modelling a real,
    -- in-flight oxmysql promise precisely, never returning on its own
    -- schedule. `xpTierQueryCalls` counts how many times this file's OWN
    -- SELECT actually ran -- the exact thing every test below proves must
    -- never happen before the probe has settled.
    local xpTierQueryCalls = 0
    local queryStub = {
        await = function(sql, _params)
            if sql:find('SELECT ordinal, xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge FROM k9_xp_tiers', 1, true) then
                xpTierQueryCalls = xpTierQueryCalls + 1
                return opts.foreignXpTierRows or {}
            end
            if sql:find('INFORMATION_SCHEMA.COLUMNS', 1, true) then
                return coroutine.yield()
            end
            error('bootWithRacingMySQL: unexpected query, no stub behavior defined: ' .. tostring(sql))
        end,
    }

    local env = Sandbox.newEnv({
        Config = {
            Database = { enabled = true },
            XPTiers = defaultXpTiers(),
            Features = { HighCommand = true, XPProgression = true },
        },
        AddEventHandler = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetPlayers = function() return {} end,
        GetGameTimer = function() return 0 end,
        -- Yields, mirroring the real FXServer scheduler closely enough for
        -- K9Store.WaitForSchemaCheckToSettle's own bounded poll loop to
        -- actually suspend this file's handler between polls -- exactly
        -- what every test below drives explicitly via `resumeNext`.
        Wait = function(_ms) coroutine.yield() end,
        lib = { callback = { register = function() end } },
        MySQL = { query = queryStub },
        print = printStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/xptiers.lua', env)

    local coros = {}

    local function fireResourceStart()
        for i, fn in ipairs(eventHandlers['onResourceStart']) do
            local co = coroutine.create(fn)
            coros[i] = co
            local ok, err = coroutine.resume(co, 'john-k9')
            if not ok then error(('onResourceStart handler #%d errored: %s'):format(i, tostring(err))) end
        end
    end

    --- Resumes the FIRST currently-suspended coroutine (registration
    --- order), passing `value` through as whatever that coroutine's own
    --- `coroutine.yield()` call is waiting on. Returns `false`, resuming
    --- nothing, once every handler has already run to completion.
    local function resumeNext(value)
        for _, co in ipairs(coros) do
            if coroutine.status(co) == 'suspended' then
                local ok, err = coroutine.resume(co, value)
                if not ok then error('resumeNext: handler errored on resume: ' .. tostring(err)) end
                return true
            end
        end
        return false
    end

    return {
        env = env, printedLines = printedLines, coros = coros,
        fireResourceStart = fireResourceStart, resumeNext = resumeNext,
        xpTierQueryCallCount = function() return xpTierQueryCalls end,
    }
end

t.test('BOOT-ORDER RACE (the actual bug, fixed): a foreign k9_xp_tiers table that satisfies this file\'s own SELECT but fails the FULL schema probe must never reach a live rank', function()
    local f = bootWithRacingMySQL({
        foreignXpTierRows = { { ordinal = 1, xp_threshold = 999999, label = 'NOT OURS', speed_multiplier = 9, scent_range_multiplier = 9, medkit_cooldown_multiplier = nil, badge = nil } },
    })

    f.fireResourceStart()
    t.equals(f.xpTierQueryCallCount(), 0, 'this file must not issue its own SELECT before the schema probe has settled')

    -- Resolve the probe with a schema response missing updated_by/updated_at
    -- (2 of the 7 columns k9_xp_tiers is checked against) -- exactly what a
    -- foreign table sharing this name, but shaped for THIS file's own
    -- SELECT instead, would look like -- a genuine collision.
    t.isTrue(f.resumeNext({
        { tbl = 'k9_xp_tiers', col = 'ordinal' },
        { tbl = 'k9_xp_tiers', col = 'xp_threshold' },
        { tbl = 'k9_xp_tiers', col = 'label' },
        { tbl = 'k9_xp_tiers', col = 'speed_multiplier' },
        { tbl = 'k9_xp_tiers', col = 'scent_range_multiplier' },
    }), 'the probe must still be suspended, waiting to be resolved')
    t.isFalse(f.env.K9Store.IsDatabaseEnabled(), 'the collision must have been detected')
    t.equals(f.xpTierQueryCallCount(), 0, 'still not read immediately after settling')

    t.isTrue(f.resumeNext(), 'this file\'s handler, parked inside its own bounded wait, wakes on its next poll')
    t.equals(f.xpTierQueryCallCount(), 0, 'DatabaseEnabled() is now false, so K9Store.XPTier_GetAllRows takes the MEMORY branch -- it must NEVER have issued its own SELECT against the foreign table, before or after settling')
    t.equals(f.env.Config.XPTiers[1].xp, 0, 'rank 1 must still be the config.lua default (0), never overwritten by the foreign row\'s 999999')
    t.equals(f.env.Config.XPTiers[1].label, 'Recruit K9', 'falls back to config-shipped defaults exactly like Config.Database.enabled = false, never to a foreign value')
    t.isFalse(f.resumeNext(), 'every handler has now run to completion')
end)

t.test('BOOT-ORDER RACE control: once the probe settles with NO collision, this file performs its real read and picks up a legitimate persisted override -- the fix must not break the ordinary, non-colliding path', function()
    local f = bootWithRacingMySQL({
        foreignXpTierRows = { { ordinal = 1, xp_threshold = 0, label = 'Recruit K9 (renamed)', speed_multiplier = 1.0, scent_range_multiplier = 1.0, medkit_cooldown_multiplier = nil, badge = nil } },
    })

    f.fireResourceStart()
    t.equals(f.xpTierQueryCallCount(), 0)

    -- A schema response describing a FULLY INSTALLED database. Derived from
    -- server/datastore.lua's own expected-column list rather than typed out
    -- here, so this stays correct as tables are added. It used to name only
    -- this file's own table, which was enough back when the boot probe only
    -- looked for name collisions -- it now ALSO refuses to use a database
    -- that is missing tables at all ("the SQL was never imported", or a
    -- part-finished install), and one table out of twenty-five reads as
    -- exactly that. See tests/datastore_spec.lua's own SETTLEMENT tests.
    t.isTrue(f.resumeNext(Sandbox.installedSchemaRows()))
    t.isTrue(f.env.K9Store.IsDatabaseEnabled(), 'no collision -- the real database stays live')

    t.isTrue(f.resumeNext(), 'this file\'s handler wakes on its next poll')
    t.equals(f.xpTierQueryCallCount(), 1, 'now that settlement confirmed no collision, this file performs its real read exactly once')
    t.equals(f.env.Config.XPTiers[1].label, 'Recruit K9 (renamed)', 'the legitimate persisted override must be applied')
    t.isFalse(f.resumeNext())
end)

t.test('BOOT-ORDER RACE bounded timeout: if the schema probe never settles, this file gives up after a bounded number of polls and boots every rank to its config.lua default -- it must never hang and never read the unconfirmed table', function()
    local f = bootWithRacingMySQL({
        foreignXpTierRows = { { ordinal = 1, xp_threshold = 0, label = 'Recruit K9 (renamed)', speed_multiplier = 1.0, scent_range_multiplier = 1.0, medkit_cooldown_multiplier = nil, badge = nil } },
    })
    f.fireResourceStart()
    t.equals(f.xpTierQueryCallCount(), 0)

    -- FIND this file's own handler rather than indexing it by position.
    -- This used to be `f.coros[2]`, on the assumption that xptiers.lua's
    -- start handler is always the second one registered (right after
    -- datastore.lua's own probe, since xptiers.lua does not load
    -- permissions.lua or any other onResourceStart-registering file in
    -- this fixture). That is not a property this spec controls: every
    -- file loaded into the fixture registers its own handlers, so an
    -- unrelated file (e.g. datastore.lua or cooldowns.lua) gaining one
    -- shifts the index and this test silently starts driving the WRONG
    -- coroutine -- exactly what happened to a sibling spec when
    -- server/permissions.lua went from one start handler to three for an
    -- unrelated feature. That test failed while the boot-order safety
    -- property it exists to protect was completely intact.
    --
    -- Never resume coros[1] (the probe) at all -- a hung query that never
    -- comes back, not merely a slow one. This file's own handler is the
    -- one still suspended after the probe is deliberately left hung: it is
    -- the only one polling for a settle that never comes. Identifying it
    -- by that behaviour cannot drift. The 200-poll ceiling exists purely
    -- so a regression that makes the production wait loop genuinely
    -- infinite fails this test instead of hanging the whole suite.
    local xpTierCo
    for i, co in ipairs(f.coros) do
        if i > 1 and coroutine.status(co) == 'suspended' then
            xpTierCo = co
            break
        end
    end
    t.isTrue(xpTierCo ~= nil, 'xptiers.lua must have a suspended start handler polling for the schema check to settle')

    local resumes = 0
    while coroutine.status(xpTierCo) == 'suspended' and resumes < 200 do
        coroutine.resume(xpTierCo)
        resumes = resumes + 1
    end

    t.isTrue(resumes < 200, 'must give up within a bounded number of polls, never spin forever waiting on a probe that never answers')
    t.isTrue(coroutine.status(xpTierCo) == 'dead', 'this file\'s own onResourceStart handler must finish (give up), not remain permanently suspended')
    t.equals(f.xpTierQueryCallCount(), 0, 'must never issue its own SELECT while the collision state is genuinely unknown -- fail-closed, exactly like Config.Database.enabled = false')
    t.equals(f.env.Config.XPTiers[1].label, 'Recruit K9', 'config-shipped defaults remain in effect -- no DB row, real or foreign, reaches this file while unsettled')
    t.contains(table.concat(f.printedLines, '\n'), 'schema-collision check had not finished', 'the fallback must be logged clearly, never silent')
end)

-- ============================================================================
-- GAP 2 CLOSURE (this pass, coder-backend): server/xptiers.lua's own
-- PushRefreshedSnapshotsAfterEdit (the push a live tier-threshold edit uses
-- to refresh every currently-connected, potentially-re-ranked citizenid)
-- used to push a PLAIN CopyXPTier(afterTier) snapshot, with no composition
-- of a citizenid's own individual override (server/k9profiles.lua) at all.
-- That meant a live edit to a WHOLE RANK could silently REVERT an
-- already-online K9's individual override on their own client -- worse than
-- never composing it in the first place (a value that visibly reverts, not
-- merely one that was never applied). Fixed via
-- ComposeEffectiveXPTierSnapshot (this file, above) -- calls
-- GetK9EffectiveMultipliers, never re-implements or reorders its
-- resolution contract.
--
-- This section loads the REAL, unmodified server/k9profiles.lua alongside
-- the real server/xptiers.lua (fxmanifest.lua's real order: xptiers before
-- k9profiles) -- this file's own SHARED `boot()` above never loads
-- server/k9profiles.lua at all, so it could never have caught this
-- regression either way; a dedicated fixture is required to prove the fix.
-- `GetXPTier` stays a plain STUB here, this file's own established
-- convention (see `boot()`'s own header for why) -- GetK9EffectiveMultipliers
-- itself is the REAL production function from server/k9profiles.lua, and its
-- own soft dependency on GetXPTier is satisfied by this same stub, so the
-- GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE resolution order is
-- exercised for real even though the "XP TIER" layer underneath it is a
-- stub, not the real server/progression.lua (out of this pass's own file
-- ownership; tests/progression_spec.lua's own "GAP 1 CLOSURE" section
-- already covers that file's side of the identical composition contract).
-- Config.Database.enabled = false throughout -- both files' own K9Store
-- calls take the proven-safe memory-mode branch (same convention as
-- tests/k9profiles_spec.lua's own SECTION 5 and
-- tests/progression_spec.lua's own newGap1Fixture), so no MySQL stub needs
-- to additionally understand k9_individual_overrides' own SQL shape.
-- ============================================================================

--- @param opts table? -- { xpByCitizenid, onlineSources, xpTiers, isHighCommand }
--- @return table fixture
local function bootWithK9Profiles(opts)
    opts = opts or {}

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local xpByCitizenid = opts.xpByCitizenid or {}
    local onlineSources = opts.onlineSources or {} -- src -> citizenid

    local function GetPlayersStub()
        local out = {}
        for src in pairs(onlineSources) do out[#out + 1] = tostring(src) end
        return out
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local citizenid = onlineSources[src]
                if not citizenid then return nil end
                return { PlayerData = { citizenid = citizenid, source = src } }
            end,
        },
    }

    local config = {
        XPTiers = opts.xpTiers or defaultXpTiers(),
        Features = { HighCommand = true, XPProgression = true },
        Database = { enabled = false },
    }

    -- Same shape as this file's own shared GetXPTierStub above -- resolves
    -- exactly like the real ResolveTier against the live (possibly
    -- just-edited) Config.XPTiers array.
    local function GetXPTierStub(citizenid)
        local xp = xpByCitizenid[citizenid] or 0
        local resolved = config.XPTiers[1]
        for _, tier in ipairs(config.XPTiers) do
            if xp >= tier.xp then resolved = tier end
        end
        return resolved
    end

    local pushedEvents = {}
    local function TriggerClientEventStub(eventName, targetSrc, payload)
        pushedEvents[#pushedEvents + 1] = { eventName = eventName, targetSrc = targetSrc, payload = payload }
    end

    local isHighCommand = opts.isHighCommand or function() return true end

    local fakeNow = { value = 0 }
    local env = Sandbox.newEnv({
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetPlayers             = GetPlayersStub,
        TriggerClientEvent     = TriggerClientEventStub,
        print                  = printStub,
        lib                    = lib,
        exports                = exportsStub,
        IsHighCommand          = isHighCommand,
        Config                 = config,
        GetXPTier              = GetXPTierStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/xptiers.lua', env)
    Sandbox.loadInto('../server/k9profiles.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env, callbacks = callbacks, printedLines = printedLines,
        fakeNow = fakeNow, pushedEvents = pushedEvents, xpByCitizenid = xpByCitizenid,
        onlineSources = onlineSources, config = config,
    }
end

t.test('GAP 2 CLOSURE: editing a WHOLE RANK\'s threshold pushes a snapshot to an online, ALREADY-OVERRIDDEN citizenid that still carries their individual override -- never silently reverting it to the plain rank value', function()
    local f = bootWithK9Profiles({
        xpByCitizenid = { ['GAP2CIT'] = 0 },
        onlineSources = { [50] = 'GAP2CIT' },
    })

    -- A genuine individual override, through the REAL k9ProfileUpsert
    -- callback -- server/k9profiles.lua's own LIVE PUSH
    -- (PushXPTierSnapshotIfOnline) is a soft dependency on
    -- server/progression.lua, not loaded in this fixture, so it silently
    -- no-ops here; only server/xptiers.lua's OWN push is under test below.
    local upsert = f.callbacks['john-k9:server:k9ProfileUpsert'](100, { citizenid = 'GAP2CIT', speedMultiplier = 2.9 })
    t.isTrue(upsert.ok, 'the override write itself must succeed')
    for i = #f.pushedEvents, 1, -1 do f.pushedEvents[i] = nil end -- discard whatever, if anything, that call produced

    f.fakeNow.value = f.fakeNow.value + 1100 -- clear XPTierActionCooldown's 1000ms floor

    -- A WHOLE-RANK edit, unrelated to GAP2CIT's own individual override,
    -- through the real xpTiersUpsert callback.
    local tier1 = f.config.XPTiers[1]
    local editResult = f.callbacks['john-k9:server:xpTiersUpsert'](100, {
        ordinal = 1, xp = 0, label = tier1.label, speedMultiplier = 1.30,
        scentRangeMultiplier = tier1.scentRangeMultiplier,
        medkitCooldownMultiplier = tier1.medkitCooldownMultiplier, badge = tier1.badge,
    })
    t.isTrue(editResult.ok)

    local pushedToGap2
    for _, evt in ipairs(f.pushedEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.targetSrc == 50 then pushedToGap2 = evt end
    end
    t.isNotNil(pushedToGap2, 'a whole-rank edit must still push a refreshed snapshot to this online citizenid')
    t.equals(pushedToGap2.payload.speedMultiplier, 2.9, 'the pushed snapshot must still carry the individual override (2.9), NEVER the plain, just-edited rank value (1.30) -- reverting it here would be exactly the GAP 2 bug this pass closes')
end)

t.test('GAP 2 CLOSURE control: an online citizenid with NO individual override still receives the plain, just-edited rank value -- composition only ever overlays a REAL override, it never invents one', function()
    local f = bootWithK9Profiles({
        xpByCitizenid = { ['GAP2NOOVERRIDE'] = 0 },
        onlineSources = { [51] = 'GAP2NOOVERRIDE' },
    })

    f.fakeNow.value = f.fakeNow.value + 1100

    local tier1 = f.config.XPTiers[1]
    local editResult = f.callbacks['john-k9:server:xpTiersUpsert'](100, {
        ordinal = 1, xp = 0, label = tier1.label, speedMultiplier = 1.45,
        scentRangeMultiplier = tier1.scentRangeMultiplier,
        medkitCooldownMultiplier = tier1.medkitCooldownMultiplier, badge = tier1.badge,
    })
    t.isTrue(editResult.ok)

    local pushed
    for _, evt in ipairs(f.pushedEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.targetSrc == 51 then pushed = evt end
    end
    t.isNotNil(pushed)
    t.equals(pushed.payload.speedMultiplier, 1.45, 'with no override at all, the plain, just-edited rank value must reach the client unchanged')
end)

os.exit(t.summary())
