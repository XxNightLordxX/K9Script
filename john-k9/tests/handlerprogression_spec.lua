--[[
    tests/handlerprogression_spec.lua

    Covers the HANDLER half of progression: server/progression.lua's
    AwardHandlerXP/GetHandlerXPTier (Config.Features.HandlerXPProgression) and
    server/datastore.lua's K9Store.HandlerXP_Get/HandlerXP_UpsertAdd -- the
    SEPARATE, `handler_xp`-column-backed total config.lua's own
    Config.HandlerXPTiers/Config.HandlerXP headers describe at length. Modeled
    directly on tests/progression_spec.lua's own newProgressionFixture and
    PER-PERSON block-path sections -- read that file first; this one repeats
    its shape rather than inventing a new one, scoped to what is actually new
    here.

    THREE PARTS:
      PART 1 -- K9Store.HandlerXP_Get/HandlerXP_UpsertAdd tested DIRECTLY
        against server/datastore.lua, mirroring tests/datastore_spec.lua's own
        MySQL-branch (capture-based fake, parameterized/hardcoded-table-name
        checks, a thrown write degrading to `false` rather than propagating)
        and memory-branch (Config.Database.enabled = false, NO `MySQL` global
        defined at all, so any accidental reference is a hard Lua error, not a
        silent pass) conventions. This is where "a failed DB write is reported
        as failure rather than success" and "the memory-only path" are proven
        at the accessor's own boundary, independent of AwardHandlerXP.
      PART 2 -- AwardHandlerXP/GetHandlerXPTier via a fixture loading the REAL
        server/cooldowns.lua + server/datastore.lua + server/events.lua +
        server/progression.lua together (mirroring newProgressionFixture),
        covering the unknown-actionKey guard, the feature-flag gate, malformed
        arguments, and an end-to-end proof that a failed persistence write
        still logs plainly while in-memory/session state stays correct.
      PART 3 -- PER-PERSON FEATURE CONTROL (block.HandlerXPProgression /
        RequireGrant.HandlerXPProgression), same four-step shape and same
        battery of cases tests/progression_spec.lua's own XPProgression
        section already covers for its sibling flag.
      PART 4 -- THE SHARED MINT BUDGET: AwardXP and AwardHandlerXP for the
        SAME citizenid draw down the SAME XPMintBudget bucket, proven by
        contrast against a second citizenid who only ever calls AwardXP.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ============================================================================
-- PART 1 -- K9Store.HandlerXP_Get / K9Store.HandlerXP_UpsertAdd, direct
-- ============================================================================

-- ---- MySQL branch (capture-based fake, Config.Database.enabled = true) ----

local captured
local canned

local function resetCapture()
    captured = {}
end

local function capturingMySQL()
    local function record(kind)
        return function(sql, params)
            captured[#captured + 1] = { kind = kind, sql = sql, params = params }
            local c = canned
            canned = nil
            if type(c) == 'table' and c.throw then error(c.throw, 0) end
            return c
        end
    end
    return {
        scalar = { await = record('scalar') },
        insert = { await = record('insert') },
    }
end

local mysqlEnv = Sandbox.newEnv({
    Config = { Database = { enabled = true } },
    MySQL = capturingMySQL(),
    print = function(...) end,
})
Sandbox.loadInto('../server/datastore.lua', mysqlEnv)
local MysqlStore = mysqlEnv.K9Store

t.test('MySQL branch: HandlerXP_Get forwards to MySQL.scalar.await with a parameterized query against the hardcoded k9_progression table', function()
    resetCapture()
    canned = 42
    local xp = MysqlStore.HandlerXP_Get('CIT1')
    t.equals(xp, 42)
    t.equals(#captured, 1)
    t.equals(captured[1].kind, 'scalar')
    t.contains(captured[1].sql, 'SELECT handler_xp FROM k9_progression')
    t.contains(captured[1].sql, 'WHERE citizenid = ?')
    t.equals(captured[1].params[1], 'CIT1')
end)

t.test('MySQL branch: HandlerXP_UpsertAdd sends the per-award DELTA (never a running total) via a parameterized ON DUPLICATE KEY UPDATE against handler_xp, and returns true on success', function()
    resetCapture()
    canned = 1
    local ok = MysqlStore.HandlerXP_UpsertAdd('CIT1', 50)
    t.isTrue(ok, 'a successful write must report true')
    t.equals(#captured, 1)
    t.equals(captured[1].kind, 'insert')
    t.contains(captured[1].sql, 'INSERT INTO k9_progression')
    t.contains(captured[1].sql, 'ON DUPLICATE KEY UPDATE handler_xp = handler_xp + VALUES(handler_xp)')
    t.equals(captured[1].params[1], 'CIT1')
    t.equals(captured[1].params[2], 50, 'must send the DELTA, not a computed running total')
end)

t.test('MySQL branch: a thrown HandlerXP_UpsertAdd write is reported as FAILURE (false), never propagated and never mistaken for success -- deliberately DIFFERENT from XP_UpsertAdd\'s own raw-throw contract', function()
    resetCapture()
    canned = { throw = { errno = 1146, message = "ER_NO_SUCH_TABLE: Unknown column 'handler_xp'" } }
    local ok = MysqlStore.HandlerXP_UpsertAdd('CIT1', 50)
    t.isFalse(ok, 'a thrown DB error (e.g. migration 0017 not yet applied) must degrade to false, never throw to the caller and never report true')
end)

-- ---- Memory branch (Config.Database.enabled = false, NO MySQL global at all) ----

local memEnv = Sandbox.newEnv({
    Config = { Database = { enabled = false } },
    print = function(...) end,
    -- Deliberately NO `MySQL` key at all -- see tests/datastore_spec.lua's own
    -- header for why this is the strict form of this check: any accidental
    -- `if DatabaseEnabled() then` branch left enabled, or any reference to
    -- MySQL.* inside the memory branch, is a hard "attempt to index a nil
    -- value" error here, not a silent pass.
})
Sandbox.loadInto('../server/datastore.lua', memEnv)
local MemStore = memEnv.K9Store

t.isFalse(MemStore.IsDatabaseEnabled(), 'this fixture must route through the memory backend')

t.test('Memory: HandlerXP_Get on an uncached citizenid returns nil (never throws, never a default 0)', function()
    t.isNil(MemStore.HandlerXP_Get('NOBODY'))
end)

t.test('Memory: HandlerXP_UpsertAdd creates a fresh row, accumulates deltas (never overwrites), and always reports true', function()
    t.isTrue(MemStore.HandlerXP_UpsertAdd('HXPCIT1', 50))
    t.equals(MemStore.HandlerXP_Get('HXPCIT1'), 50)
    t.isTrue(MemStore.HandlerXP_UpsertAdd('HXPCIT1', 12))
    t.equals(MemStore.HandlerXP_Get('HXPCIT1'), 62, 'must ADD the delta, never overwrite with the last award amount')
end)

t.test('Memory: HandlerXP_UpsertAdd and XP_UpsertAdd accumulate independently on the SAME row/citizenid -- two columns, never one shared number', function()
    -- XP_UpsertAdd mirrors MySQL.insert.await's own contract (an insertId,
    -- not a boolean) -- see that function's own doc comment. Only
    -- HandlerXP_UpsertAdd (this section's own new accessor) uses the
    -- SafeWrite boolean contract; asserted here as "did not error", not as
    -- a specific return shape, so this test does not overreach into
    -- XP_UpsertAdd's own, unrelated, pre-existing contract.
    MemStore.XP_UpsertAdd('HXPCIT2', 25)
    t.isTrue(MemStore.HandlerXP_UpsertAdd('HXPCIT2', 50))
    t.equals(MemStore.XP_Get('HXPCIT2'), 25, 'the K9 xp column must be unaffected by a handler_xp write on the same row')
    t.equals(MemStore.HandlerXP_Get('HXPCIT2'), 50, 'the handler_xp column must be unaffected by an xp write on the same row')
end)

t.test('Memory: a row created by XP_UpsertAdd ONLY (no handler_xp write yet) reads back HandlerXP_Get as nil, not 0 or an error', function()
    MemStore.XP_UpsertAdd('HXPCIT3', 25)
    t.isNil(MemStore.HandlerXP_Get('HXPCIT3'), 'a row that has never received a handler_xp write must not fabricate a 0')
    t.isTrue(MemStore.HandlerXP_UpsertAdd('HXPCIT3', 12))
    t.equals(MemStore.HandlerXP_Get('HXPCIT3'), 12)
    t.equals(MemStore.XP_Get('HXPCIT3'), 25, 'the pre-existing xp value must survive the later handler_xp write untouched')
end)

-- ============================================================================
-- PART 2 -- AwardHandlerXP / GetHandlerXPTier, via the real
-- server/cooldowns.lua + server/datastore.lua + server/events.lua +
-- server/progression.lua, mirroring tests/progression_spec.lua's own
-- newProgressionFixture as closely as this second entry point deserves.
-- ============================================================================

--- @param opts table?
--- @return table fixture
local function newHandlerProgressionFixture(opts)
    opts = opts or {}
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceName() return 'john-k9' end
    local function GetPlayers() return {} end
    local function TriggerEvent(_eventName, ...) end
    local function TriggerClientEvent(_eventName, _target, ...) end

    local capturedRecurringThreads = {}
    local function CreateThread(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('handlerprogression_spec.lua: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
        if coroutine.status(co) ~= 'dead' then
            capturedRecurringThreads[#capturedRecurringThreads + 1] = co
        end
    end
    local function Wait(_ms) coroutine.yield() end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local playerByCitizenId = {}
    local exportsStub = {
        qbx_core = {
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId[citizenid] end,
            GetPlayer = function(_self, src)
                for _, p in pairs(playerByCitizenId) do
                    if p.PlayerData.source == src then return p end
                end
                return nil
            end,
        },
    }

    -- insert.await throws when opts.insertThrows is set -- lets one test
    -- prove a failed persistence write is reported as failure (logged), not
    -- silently treated as success, all the way up through AwardHandlerXP.
    local MySQLStub = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params)
            if opts.insertThrows then error(opts.insertThrows, 0) end
            return 1
        end },
    }

    -- REAL-shaped award/tier tables -- small and self-contained rather than
    -- the exact live config.lua values, same "fixture, not a load of the real
    -- config" approach newProgressionFixture itself uses for its own award
    -- table. Deliberately carries BOTH Config.XP and Config.HandlerXP so
    -- PART 4 below can prove the SAME shared XPMintBudget bucket is spent by
    -- both AwardXP and AwardHandlerXP for one citizenid.
    local Config = {
        Features = { XPProgression = true, HandlerXPProgression = opts.handlerXPProgression ~= false },
        Database = { enabled = opts.databaseEnabled == true },
        XP = {
            scopePerCitizenidOrJob = 'citizenid',
            awards = { takedownSuccess = 30 },
        },
        XPTiers = {
            { xp = 0,   label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 500, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
        },
        HandlerXP = {
            awards = {
                handlerCertifyK9 = 50,
                handlerTreatK9   = 12,
                zeroAward        = 0,
            },
        },
        HandlerXPTiers = {
            { xp = 0,   label = 'Rookie Handler' },
            { xp = 100, label = 'Certified Handler', medkitTreatCooldownMultiplier = 0.90 },
            { xp = 500, label = 'Senior Handler',    medkitTreatCooldownMultiplier = 0.80 },
        },
    }
    Config.FeatureControl = opts.featureControl

    local function defaultHasPermission(citizenid, key)
        if type(opts.hasPermissionFn) == 'function' then
            return opts.hasPermissionFn(citizenid, key)
        end
        return false
    end

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandlerStub,
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
    }
    if opts.withHasPermission ~= false then
        envOverrides.HasPermission = defaultHasPermission
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    -- Config.Database defaults to memory mode here (opts.databaseEnabled must
    -- be explicitly true to exercise the MySQL branch) -- so MOST of this
    -- file's Part 2/3/4 tests already exercise the memory-only path
    -- end-to-end (award -> in-memory cache -> K9Store-persisted total, both
    -- agreeing) as their ordinary mode of operation, not a special case.
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent
    Sandbox.loadInto('../server/progression.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env,
        AwardXP = env.AwardXP,
        AwardHandlerXP = env.AwardHandlerXP,
        GetXP = env.GetXP,
        GetHandlerXPTier = env.GetHandlerXPTier,
        K9Store = env.K9Store,
        printedLines = printedLines,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
    }
end

t.isNotNil(newHandlerProgressionFixture().AwardHandlerXP, 'server/progression.lua must define global AwardHandlerXP')
t.isNotNil(newHandlerProgressionFixture().GetHandlerXPTier, 'server/progression.lua must define global GetHandlerXPTier')

t.test('GetHandlerXPTier: an uncached citizenid defaults to the base tier (Rookie Handler), never nil', function()
    local f = newHandlerProgressionFixture()
    local tier = f.GetHandlerXPTier('never-seen-handler')
    t.isNotNil(tier)
    t.equals(tier.label, 'Rookie Handler')
end)

t.test('AwardHandlerXP: accumulates through K9Store.HandlerXP_Get and crosses a handler tier boundary', function()
    local f = newHandlerProgressionFixture()
    f.AwardHandlerXP('cid-hxprog', 'handlerTreatK9') -- 12
    t.equals(f.K9Store.HandlerXP_Get('cid-hxprog'), 12)
    t.equals(f.GetHandlerXPTier('cid-hxprog').label, 'Rookie Handler', 'below the 100-xp Certified Handler threshold')

    -- Advanced by 60s (not just past the 500ms rate floor) between awards
    -- deliberately: this test is about tier-boundary resolution, not the
    -- shared mint budget (see PART 4 below for that), so each gap also
    -- gives the shared bucket a real 60 XP of refill -- comfortably enough
    -- that the budget is never the limiting factor on whether an award
    -- lands, keeping this test's own pass/fail condition solely about
    -- ResolveHandlerTier's boundary walk.
    f.setNow(f.now() + 60000)
    f.AwardHandlerXP('cid-hxprog', 'handlerCertifyK9') -- + 50 = 62, still below 100
    t.equals(f.K9Store.HandlerXP_Get('cid-hxprog'), 62)
    t.equals(f.GetHandlerXPTier('cid-hxprog').label, 'Rookie Handler')

    f.setNow(f.now() + 60000)
    f.AwardHandlerXP('cid-hxprog', 'handlerCertifyK9') -- + 50 = 112, crosses 100
    t.equals(f.K9Store.HandlerXP_Get('cid-hxprog'), 112)
    t.equals(f.GetHandlerXPTier('cid-hxprog').label, 'Certified Handler')
end)

t.test('AwardHandlerXP: an unknown actionKey is a safe no-op (logged, never crashes, never grants handler XP)', function()
    local f = newHandlerProgressionFixture()
    local ok = pcall(f.AwardHandlerXP, 'cid-hxunknown', 'notARealHandlerAction')
    t.isTrue(ok, 'an unknown actionKey must never throw')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxunknown'))
    t.equals(f.GetHandlerXPTier('cid-hxunknown').label, 'Rookie Handler')

    local sawWarning = false
    for _, line in ipairs(f.printedLines) do
        if line:find('AwardHandlerXP', 1, true) and line:find('unknown actionKey', 1, true) and line:find('notARealHandlerAction', 1, true) then
            sawWarning = true
        end
    end
    t.isTrue(sawWarning, 'an unknown actionKey must be logged plainly, naming both the function and the bad key, so a caller typo is visible in server console')
end)

t.test('AwardHandlerXP: a zero-amount actionKey never GRANTS any XP -- mirrors AwardXP\'s own documented "0 is a harmless no-op, not forbidden" stance, so it still runs the mint pipeline (creating a 0-value row) rather than erroring or being treated as unknown', function()
    local f = newHandlerProgressionFixture()
    local ok = pcall(f.AwardHandlerXP, 'cid-hxzero', 'zeroAward')
    t.isTrue(ok, 'a configured 0-value actionKey must never error')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxzero'), 0, 'a 0-XP award still runs (unlike an unknown actionKey), it simply adds nothing')
    t.equals(f.GetHandlerXPTier('cid-hxzero').label, 'Rookie Handler')
end)

t.test('AwardHandlerXP: is a hard no-op while Config.Features.HandlerXPProgression is false -- the shipped default', function()
    local f = newHandlerProgressionFixture({ handlerXPProgression = false })
    f.AwardHandlerXP('cid-hxoff', 'handlerCertifyK9')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxoff'))
    t.equals(f.GetHandlerXPTier('cid-hxoff').label, 'Rookie Handler')
end)

t.test('AwardHandlerXP: a non-string citizenid is a safe no-op', function()
    local f = newHandlerProgressionFixture()
    local ok = pcall(f.AwardHandlerXP, 12345, 'handlerCertifyK9')
    t.isTrue(ok)
    t.isNil(f.K9Store.HandlerXP_Get('12345'))
end)

t.test('AwardHandlerXP: an empty-string citizenid is a safe no-op', function()
    local f = newHandlerProgressionFixture()
    f.AwardHandlerXP('', 'handlerCertifyK9')
    t.isNil(f.K9Store.HandlerXP_Get(''))
end)

t.test('AwardHandlerXP: the per-(citizenid, actionKey) rate floor silently no-ops an immediate repeat (shared AwardXPCooldown, same 500ms floor AwardXP itself uses)', function()
    local f = newHandlerProgressionFixture()
    f.AwardHandlerXP('cid-hxfloor', 'handlerTreatK9')
    f.AwardHandlerXP('cid-hxfloor', 'handlerTreatK9') -- same tick, same actionKey -- must be dropped
    t.equals(f.K9Store.HandlerXP_Get('cid-hxfloor'), 12, 'the immediate repeat must not have been paid twice')
end)

t.test('AwardHandlerXP: a failed persistence write is reported as FAILURE (logged plainly), while in-memory/session state (GetHandlerXPTier) still reflects the award -- mirrors AwardXP\'s own "gameplay effect never depends on DB round-trip" posture', function()
    local f = newHandlerProgressionFixture({ databaseEnabled = true, insertThrows = { errno = 1146, message = "Unknown column 'handler_xp'" } })
    f.AwardHandlerXP('cid-hxdbfail', 'handlerCertifyK9')

    -- The in-memory/session effect is unconditional -- HandlerXP[citizenid]
    -- is updated synchronously, before the (here, failing) DB write is even
    -- attempted, exactly like AwardXP's own K9XP write.
    t.equals(f.GetHandlerXPTier('cid-hxdbfail').label, 'Rookie Handler', '50 XP alone does not cross the 100-xp Certified Handler threshold, but the award itself must not have been silently dropped')

    local sawFailureLog = false
    for _, line in ipairs(f.printedLines) do
        if line:find('AwardHandlerXP', 1, true) and line:find('UPSERT failed', 1, true) and line:find('cid%-hxdbfail', 1) and line:find('NOT persisted', 1, true) then
            sawFailureLog = true
        end
    end
    t.isTrue(sawFailureLog, 'a failed write must be reported as a failure in server console, never silently treated as success')
end)

-- ============================================================================
-- PART 3 -- PER-PERSON FEATURE CONTROL (block.HandlerXPProgression /
-- RequireGrant.HandlerXPProgression) -- same four-step shape, same battery of
-- cases, as tests/progression_spec.lua's own XPProgression section.
-- ============================================================================

t.test('PER-PERSON: block.HandlerXPProgression denies the award outright, even for an otherwise-valid actionKey', function()
    local f = newHandlerProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.HandlerXPProgression' and citizenid == 'cid-hxblock' end,
    })
    f.AwardHandlerXP('cid-hxblock', 'handlerCertifyK9')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxblock'))
end)

t.test('PER-PERSON: block.HandlerXPProgression burns NO rate-floor/mint-budget state -- unblocking immediately after still pays in full', function()
    local f = newHandlerProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.HandlerXPProgression' and citizenid == 'cid-hxblock2' end,
    })
    f.AwardHandlerXP('cid-hxblock2', 'handlerCertifyK9')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxblock2'))

    f.env.HasPermission = function() return false end
    f.AwardHandlerXP('cid-hxblock2', 'handlerCertifyK9')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxblock2'), 50, 'a block must never burn the rate floor a legitimate follow-up award still needs')
end)

t.test('PER-PERSON: not blocked and not listed in RequireGrant -- default ALLOW (step 4), matching config.lua\'s documented default', function()
    local f = newHandlerProgressionFixture()
    f.AwardHandlerXP('cid-hxallow', 'handlerCertifyK9')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxallow'), 50)
end)

t.test('PER-PERSON: RequireGrant.HandlerXPProgression = true + no active feature.HandlerXPProgression grant -- denied', function()
    local f = newHandlerProgressionFixture({ featureControl = { RequireGrant = { HandlerXPProgression = true } } })
    f.AwardHandlerXP('cid-hxgrantreq', 'handlerCertifyK9')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxgrantreq'))
end)

t.test('PER-PERSON: RequireGrant.HandlerXPProgression = true + an active feature.HandlerXPProgression grant -- allowed', function()
    local f = newHandlerProgressionFixture({
        featureControl = { RequireGrant = { HandlerXPProgression = true } },
        hasPermissionFn = function(citizenid, key) return key == 'feature.HandlerXPProgression' and citizenid == 'cid-hxgranted' end,
    })
    f.AwardHandlerXP('cid-hxgranted', 'handlerCertifyK9')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxgranted'), 50)
end)

t.test('PER-PERSON: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local f = newHandlerProgressionFixture({ withHasPermission = false, featureControl = { RequireGrant = { HandlerXPProgression = true } } })
    local ok = pcall(f.AwardHandlerXP, 'cid-hxmissing', 'handlerCertifyK9')
    t.isTrue(ok, 'a missing HasPermission must never error AwardHandlerXP')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxmissing'), 'RequireGrant-listed + unresolvable grant machinery must deny, not silently allow')
end)

t.test('PER-PERSON: server/permissions.lua entirely absent + NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newHandlerProgressionFixture({ withHasPermission = false })
    f.AwardHandlerXP('cid-hxmissing2', 'handlerCertifyK9')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxmissing2'), 50)
end)

t.test('PER-PERSON: a block on ONE citizenid never affects a DIFFERENT citizenid\'s own award', function()
    local f = newHandlerProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.HandlerXPProgression' and citizenid == 'cid-hxblocked-other' end,
    })
    f.AwardHandlerXP('cid-hxblocked-other', 'handlerCertifyK9')
    f.AwardHandlerXP('cid-hxnotblocked-other', 'handlerCertifyK9')
    t.isNil(f.K9Store.HandlerXP_Get('cid-hxblocked-other'))
    t.equals(f.K9Store.HandlerXP_Get('cid-hxnotblocked-other'), 50)
end)

t.test('PER-PERSON: block.XPProgression (the K9-side flag) does NOT block AwardHandlerXP -- the two are independent gates on independent totals', function()
    local f = newHandlerProgressionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.XPProgression' and citizenid == 'cid-hxindependent' end,
    })
    f.AwardXP('cid-hxindependent', 'takedownSuccess')
    t.isNil(f.K9Store.XP_Get('cid-hxindependent'), 'the K9 side must be blocked')
    f.AwardHandlerXP('cid-hxindependent', 'handlerCertifyK9')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxindependent'), 50, 'the handler side must be entirely unaffected by a K9-side block')
end)

-- ============================================================================
-- PART 4 -- THE SHARED MINT BUDGET: AwardXP and AwardHandlerXP for the SAME
-- citizenid draw down the SAME XPMintBudget bucket (server/progression.lua's
-- EIGHTH-XP-FARM-FIX section), never two independent ones. Proven by direct
-- contrast against a second citizenid who only ever calls AwardXP -- if the
-- budget were split per award-table instead of shared, the "combined" citizen
-- below would behave identically to the "K9-only" one; it does not.
-- ============================================================================

t.test('EIGHTH XP-FARM FIX, HANDLER EXTENSION: AwardXP and AwardHandlerXP for the SAME citizenid spend the SAME shared budget, not two independent ones', function()
    -- Fixture award table here sums to 30 (XP) + 50 + 12 (HandlerXP, ignoring
    -- the 0-value zeroAward key) = 92 -- so a fresh bucket for either
    -- citizenid below starts at XP_MINT_BUDGET_STARTER_TOKENS = 92 (well
    -- under XP_MINT_BUDGET_CAP_XP = 3600, so the clamp never engages here;
    -- see server/progression.lua's own constant for why 92, not some other
    -- number, is what a fresh bucket actually starts with).
    local combined = newHandlerProgressionFixture()
    local k9Only = newHandlerProgressionFixture()

    -- COMBINED citizen: takedownSuccess (30) then handlerCertifyK9 (50) in
    -- the SAME tick -- 30 + 50 = 80, comfortably inside the 92-token starter
    -- allowance, so BOTH succeed.
    combined.AwardXP('cid-shared', 'takedownSuccess')
    combined.AwardHandlerXP('cid-shared', 'handlerCertifyK9')
    t.equals(combined.K9Store.XP_Get('cid-shared'), 30, 'first K9 award must have been paid')
    t.equals(combined.K9Store.HandlerXP_Get('cid-shared'), 50, 'handler award must have been paid from the SAME still-sufficient bucket')

    -- A second takedownSuccess, past the 500ms per-(citizenid, actionKey)
    -- rate floor (negligible refill over 501ms: 501/3600000 * 3600 =~ 0.5 XP,
    -- nowhere near enough to matter against the math below) needs 30 more
    -- tokens. Only ~12 remain (92 - 30 - 50 = 12) -- if AwardHandlerXP had
    -- drawn from a SEPARATE budget instead of this SAME one, this K9-side
    -- bucket would still hold 62 (92 - 30) and this award would succeed. It
    -- must NOT succeed, because the two award tables share one bucket.
    combined.setNow(combined.now() + 501)
    combined.AwardXP('cid-shared', 'takedownSuccess')
    t.equals(combined.K9Store.XP_Get('cid-shared'), 30, 'the shared budget must already be exhausted by the earlier handler award, so this K9 award must be silently refused')

    -- CONTROL citizen: the exact same two AwardXP calls, with NO
    -- AwardHandlerXP call in between, on a citizenid whose bucket therefore
    -- only ever has K9-side demand placed on it. 92 - 30 - 30 = 32 >= 0, so
    -- BOTH succeed -- proving the earlier failure above was caused
    -- specifically by the handler award sharing the bucket, not by some
    -- unrelated property of AwardXP itself (e.g. a second per-mechanic
    -- cooldown this fixture does not model).
    k9Only.AwardXP('cid-k9only', 'takedownSuccess')
    k9Only.setNow(k9Only.now() + 501)
    k9Only.AwardXP('cid-k9only', 'takedownSuccess')
    t.equals(k9Only.K9Store.XP_Get('cid-k9only'), 60, 'with no competing handler award, the SAME shared bucket has enough left for a second K9 award -- confirming the earlier failure was caused by sharing, not some other difference between the two fixtures')
end)

t.test('EIGHTH XP-FARM FIX, HANDLER EXTENSION: two DIFFERENT citizenids never share a bucket -- a handler award for one never affects the other\'s own K9 budget', function()
    local f = newHandlerProgressionFixture()
    f.AwardHandlerXP('cid-hxbudgetA', 'handlerCertifyK9') -- spends from cid-hxbudgetA's own bucket only
    f.AwardXP('cid-hxbudgetB', 'takedownSuccess')
    t.equals(f.K9Store.HandlerXP_Get('cid-hxbudgetA'), 50)
    t.equals(f.K9Store.XP_Get('cid-hxbudgetB'), 30, 'a different citizenid\'s own bucket must be completely unaffected by cid-hxbudgetA\'s spend')
end)

os.exit(t.summary())
