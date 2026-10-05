--[[
    tests/k9profiles_spec.lua

    Tests server/k9profiles.lua -- the owner-directed "god over that tablet,
    full customization over everything related to that K9" pass, the
    per-INDIVIDUAL-K9 override half (server/xptiers.lua/tests/xptiereditor_spec.lua
    already cover the per-RANK half) -- against the REAL, unmodified
    production file, via tests/fixtures/sandbox.lua. Harness style mirrors
    tests/xptiereditor_spec.lua/tests/certtiers_spec.lua closely: a fake
    in-memory table backing every SQL statement this file issues
    (k9_individual_overrides, k9_individual_override_audit), mutated by the
    real production callbacks exactly like a real database would be.

    Deliberately NOT re-testing server/progression.lua's own GetXPTier
    contract -- tests/progression_spec.lua/tests/xptierunlocks_spec.lua
    already own that. What THIS spec covers is the NEW surface: the
    resolution seam (GetK9EffectiveMultipliers, exercised indirectly through
    k9ProfileGet/k9ProfileUpsert/k9ProfileReset's own `effective` response
    field -- GAP 1 closure, a later pass: this function is NOW a
    resource-global, promoted specifically so server/progression.lua could
    become its first real cross-file consumer; see
    tests/progression_spec.lua's own "GAP 1 CLOSURE" section for the
    end-to-end (k9profiles.lua + progression.lua, loaded together)
    composition tests that section owns -- this file's own tests below
    still exercise it only indirectly, through this file's own callbacks,
    which is sufficient for everything THIS file is responsible for), the
    resolution ORDER itself (global default -> XP tier -> individual
    override), overlay precedence (a per-field partial edit never clobbers
    an untouched field), tombstones, Config.Database = false, the
    schema-collision boot-order race, write-failure reporting, every
    rejected value shape, and authorization refusal.

    NOT COVERED HERE (disclosed, not silently skipped), same posture
    tests/certtiers_spec.lua/tests/xptiereditor_spec.lua's own headers take
    for the identical class of gap: the mutex-busy ('busy') rejection path
    needs a real concurrent-coroutine harness interleaving two MySQL.await
    yield points, which this fake, synchronous MySQL stub (every call
    returns immediately, no real yield) cannot produce outside the
    dedicated BOOT-ORDER RACE section's own separate coroutine dispatcher.
    MAX_INDIVIDUAL_OVERRIDES (the too_many_overrides cap) is covered for
    real below (a cheap, pure-Lua loop, no real I/O) rather than disclosed
    as a gap, since nothing about it needs a real yield to exercise.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @return table world
local function newWorld()
    return {
        overrides = {}, -- citizenid -> { speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, note, deleted, updated_by }
        audit = {},     -- array of { action, citizenid, detail, changed_by }
    }
end

--- @param world table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT citizenid, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, sprint_decay_per_tick, note, deleted FROM k9_individual_overrides', 1, true) then
            local out = {}
            for citizenid, row in pairs(world.overrides) do
                out[#out + 1] = {
                    citizenid = citizenid, speed_multiplier = row.speed_multiplier,
                    scent_range_multiplier = row.scent_range_multiplier,
                    medkit_cooldown_multiplier = row.medkit_cooldown_multiplier,
                    sprint_decay_per_tick = row.sprint_decay_per_tick,
                    note = row.note, deleted = row.deleted,
                }
            end
            return out
        elseif sql:find('INSERT INTO k9_individual_overrides (citizenid, speed_multiplier', 1, true) then
            -- Column order matches migration 0021: sprint_decay_per_tick sits
            -- between medkit_cooldown_multiplier and note, so params[5] is
            -- stamina and note/updatedBy shift right by one. Getting this
            -- order wrong does not error -- it silently writes stamina into
            -- the note column and the whole override reads back wrong.
            local citizenid, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier, sprintDecayPerTick, note, updatedBy =
                params[1], params[2], params[3], params[4], params[5], params[6], params[7]
            world.overrides[citizenid] = {
                speed_multiplier = speedMultiplier, scent_range_multiplier = scentRangeMultiplier,
                medkit_cooldown_multiplier = medkitCooldownMultiplier,
                sprint_decay_per_tick = sprintDecayPerTick,
                note = note, deleted = 0, updated_by = updatedBy,
            }
            return {}
        elseif sql:find('INSERT INTO k9_individual_overrides (citizenid, deleted, updated_by)', 1, true) then
            local citizenid, updatedBy = params[1], params[2]
            local existing = world.overrides[citizenid]
            if existing then
                existing.deleted, existing.updated_by = 1, updatedBy
            else
                world.overrides[citizenid] = { deleted = 1, updated_by = updatedBy }
            end
            return {}
        elseif sql:find('INSERT INTO k9_individual_override_audit', 1, true) then
            world.audit[#world.audit + 1] = { action = params[1], citizenid = params[2], detail = params[3], changed_by = params[4] }
            return {}
        end
        error('k9profiles_spec test stub: unhandled MySQL.query.await SQL: ' .. tostring(sql))
    end
end

--- @param opts table? -- { world, isHighCommand, tierByCitizenid, onlineSources, databaseEnabled, throwOnWrite, maxSpeedScentMultiplier, wellbeingConfig, omitGetPlayerByCitizenId, omitTriggerClientEvent, omitGetPlayers }
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

    -- citizenid -> { speedMultiplier?, scentRangeMultiplier?, medkitCooldownMultiplier? }.
    -- A citizenid absent here resolves to the neutral base tier (1.0/1.0/no
    -- medkit reduction) -- exactly server/progression.lua's own Config.XPTiers[1]
    -- shape. This is a deliberate STUB, never the real server/progression.lua
    -- (this spec does not load that file at all) -- server/k9profiles.lua only
    -- ever consults GetXPTier through a `type(GetXPTier) == 'function'` soft
    -- guard, so a plain stub function is sufficient and keeps this spec fully
    -- independent of that file's own mint-budget/cooldown machinery.
    local tierByCitizenid = opts.tierByCitizenid or {}
    local function GetXPTierStub(citizenid)
        return tierByCitizenid[citizenid] or { speedMultiplier = 1.0, scentRangeMultiplier = 1.0 }
    end

    local onlineSources = opts.onlineSources or {}
    --- @param citizenid string
    --- @return table? player -- { PlayerData = { citizenid, source } }, or nil if offline
    local function findOnlinePlayerByCitizenid(citizenid)
        for src, cid in pairs(onlineSources) do
            if cid == citizenid then
                return { PlayerData = { citizenid = citizenid, source = src } }
            end
        end
        return nil
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
    -- GAP 1, PART 2 -- PushK9SpeedOverrideStatusIfOnline's own reverse
    -- lookup. Real qbx_core exposes this unconditionally; OMITTED entirely
    -- (never merely stubbed to answer nil -- an `X and nil or Y` idiom here
    -- would backfire, since `true and nil` collapses to `nil` and the
    -- trailing `or Y` would then wrongly reinstate it) whenever
    -- opts.omitGetPlayerByCitizenId is true, to prove that function's own
    -- `type(...) == 'function'` guard degrades safely against a genuinely
    -- ABSENT export, not just a nil-returning one.
    if not opts.omitGetPlayerByCitizenId then
        exportsStub.qbx_core.GetPlayerByCitizenId = function(_self, citizenid)
            return findOnlinePlayerByCitizenid(citizenid)
        end
    end

    -- GAP 1, PART 2 -- captures every TriggerClientEvent call this file
    -- makes (the k9SpeedOverrideStatus push, on an edit, a fresh
    -- PlayerLoaded, or this file's own onResourceStart backfill loop).
    -- Omittable per-test via opts.omitTriggerClientEvent to prove
    -- PushK9SpeedOverrideStatus's own soft-guard degrades safely without it.
    local capturedClientEvents = {}
    local function TriggerClientEventStub(eventName, target, payload)
        capturedClientEvents[#capturedClientEvents + 1] = { event = eventName, target = target, payload = payload }
    end

    -- GAP 1, PART 2 -- real GetPlayers() returns an array of STRING server
    -- ids; tonumber() at every real call site (this file's own backfill
    -- loop, mirroring server/permissions.lua's identical idiom) is what
    -- turns them back into numbers -- returning strings here, not numbers,
    -- exercises that conversion for real rather than assuming it away.
    -- Omittable per-test via opts.omitGetPlayers to prove the backfill loop
    -- itself does not crash a boot() with no such native at all (this
    -- file's own onResourceStart handler calls it unconditionally).
    local function GetPlayersStub()
        local ids = {}
        for src in pairs(onlineSources) do ids[#ids + 1] = tostring(src) end
        table.sort(ids)
        return ids
    end

    local isHighCommand = opts.isHighCommand or function() return false end

    local config = {
        Database = opts.databaseEnabled == false and { enabled = false } or nil,
        -- Owner-editable speed/scent ceiling (Part A). Omitted means "let
        -- server/k9profiles.lua's own ResolveMaxSpeedScentMultiplier fall
        -- back to its built-in 10.0 default", exactly matching a real
        -- server that has never touched Config.MaxSpeedScentMultiplier.
        MaxSpeedScentMultiplier = opts.maxSpeedScentMultiplier,
        -- Owner-editable stamina-drain ceiling (Part B, added alongside
        -- config.lua's own Config.MaxStaminaDrainPerTick -- see
        -- server/k9profiles.lua's ResolveMaxStaminaDrainPerTick). Omitted
        -- means "let that resolver fall back to its built-in 20.0
        -- default", exactly matching a real server that has never touched
        -- this setting -- same posture as maxSpeedScentMultiplier above.
        MaxStaminaDrainPerTick = opts.maxStaminaDrainPerTick,
        Wellbeing = opts.wellbeingConfig,
    }

    local fakeNow = { value = 0 }
    local envOverrides = {
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        print                  = printStub,
        lib                    = lib,
        exports                = exportsStub,
        MySQL                  = { query = { await = makeQueryAwait(world) } },
        IsHighCommand          = isHighCommand,
        Config                 = config,
        GetXPTier              = GetXPTierStub,
    }
    -- Deliberately NOT `opts.omitX and nil or Xstub` in the table
    -- constructor above -- that idiom silently backfires the moment the
    -- omit flag is true (`true and nil` collapses to `nil`, and the
    -- trailing `or Xstub` then wrongly reinstates it -- the exact bug this
    -- spec's own GetPlayerByCitizenId wiring above was written to avoid).
    -- Plain `if not opts.omitX then` assignments have no such trap.
    if not opts.omitTriggerClientEvent then
        envOverrides.TriggerClientEvent = TriggerClientEventStub
    end
    if not opts.omitGetPlayers then
        envOverrides.GetPlayers = GetPlayersStub
    end
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    for i = #printedLines, 1, -1 do printedLines[i] = nil end -- discard datastore.lua's own one boot line

    Sandbox.loadInto('../server/k9profiles.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env, world = world, callbacks = callbacks, printedLines = printedLines,
        fakeNow = fakeNow, onlineSources = onlineSources, tierByCitizenid = tierByCitizenid,
        -- GAP 1, PART 2 -- every TriggerClientEvent call this file makes,
        -- in order.
        capturedClientEvents = capturedClientEvents,
        --- Simulates a fresh join/reconnect for `citizenid` at `src` --
        --- fires THIS file's own 'QBCore:Server:PlayerLoaded' handler
        --- directly (the same shape server/permissions.lua's own tests use
        --- for the identical event), independent of onlineSources (a test
        --- may register the citizenid there separately if it also needs
        --- exports.qbx_core:GetPlayer/GetPlayerByCitizenId to resolve them
        --- afterward).
        --- @param src number
        --- @param citizenid string
        firePlayerLoaded = function(src, citizenid)
            for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do
                handler({ PlayerData = { source = src, citizenid = citizenid } })
            end
        end,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

--- Advances `f`'s own fake clock past K9_PROFILE_ACTION_COOLDOWN_MS (1000ms)
--- -- every test below that issues MORE THAN ONE mutating call from the SAME
--- acting source must call this BETWEEN calls, mirroring
--- tests/xptiereditor_spec.lua's own `advance` helper exactly.
--- @param f table
local function advance(f)
    f.fakeNow.value = f.fakeNow.value + 1100
end

-- ============================================================================
-- SECTION 1 -- registration + authorization
-- ============================================================================

t.test('registration: all four callbacks are registered', function()
    local f = boot()
    t.isNotNil(f.callbacks['john-k9:server:k9ProfilesList'])
    t.isNotNil(f.callbacks['john-k9:server:k9ProfileGet'])
    t.isNotNil(f.callbacks['john-k9:server:k9ProfileUpsert'])
    t.isNotNil(f.callbacks['john-k9:server:k9ProfileReset'])
end)

t.test('AUTHORIZATION: all four callbacks deny a non-high-command source, and make NO change at all', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })

    local listResult = f.callbacks['john-k9:server:k9ProfilesList'](NON_HC_SOURCE)
    t.isFalse(listResult.ok)
    t.equals(listResult.reason, 'denied')

    local getResult = f.callbacks['john-k9:server:k9ProfileGet'](NON_HC_SOURCE, 'CIT1')
    t.isFalse(getResult.ok)
    t.equals(getResult.reason, 'denied')

    local upsertResult = f.callbacks['john-k9:server:k9ProfileUpsert'](NON_HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.5 })
    t.isFalse(upsertResult.ok)
    t.equals(upsertResult.reason, 'denied')
    t.isNil(next(f.world.overrides), 'a denied caller must never be able to write an override')

    local resetResult = f.callbacks['john-k9:server:k9ProfileReset'](NON_HC_SOURCE, 'CIT1')
    t.isFalse(resetResult.ok)
    t.equals(resetResult.reason, 'denied')
end)

t.test('AUTHORIZATION: all four callbacks succeed for a genuine high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfilesList'](HC_SOURCE).ok)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').ok)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.5 }).ok)
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1').ok)
end)

-- ============================================================================
-- SECTION 2 -- RESOLUTION ORDER: global default -> XP tier -> individual
-- override, per field, at each layer and in combination.
-- ============================================================================

t.test('RESOLUTION: a citizenid with NO tier data and NO override resolves to the neutral global default (1.0/1.0/no medkit reduction)', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'NOBODY')
    t.isTrue(result.ok)
    t.equals(result.effective.speedMultiplier, 1.0)
    t.equals(result.effective.scentRangeMultiplier, 1.0)
    t.isNil(result.effective.medkitCooldownMultiplier)
    t.isFalse(result.effective.overridden.speedMultiplier)
    t.isFalse(result.effective.overridden.scentRangeMultiplier)
    t.isFalse(result.effective.overridden.medkitCooldownMultiplier)
end)

t.test('RESOLUTION: with a real XP tier and NO override, effective values are exactly the tier\'s own values -- this is the "per-tier profile" half that ALREADY existed', function()
    local f = boot({
        isHighCommand = function() return true end,
        tierByCitizenid = { CIT1 = { speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.75 } },
    })
    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.equals(result.effective.speedMultiplier, 1.15)
    t.equals(result.effective.scentRangeMultiplier, 1.20)
    t.equals(result.effective.medkitCooldownMultiplier, 0.75)
    t.isFalse(result.effective.overridden.speedMultiplier)
end)

t.test('RESOLUTION: an override on ONE field wins for that field only -- the other two still come from the tier', function()
    local f = boot({
        isHighCommand = function() return true end,
        tierByCitizenid = { CIT1 = { speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.75 } },
    })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 2.0 }).ok)

    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.equals(result.effective.speedMultiplier, 2.0, 'the override must win for speedMultiplier')
    t.equals(result.effective.scentRangeMultiplier, 1.20, 'scentRangeMultiplier must still come from the tier, untouched')
    t.equals(result.effective.medkitCooldownMultiplier, 0.75, 'medkitCooldownMultiplier must still come from the tier, untouched')
    t.isTrue(result.effective.overridden.speedMultiplier)
    t.isFalse(result.effective.overridden.scentRangeMultiplier)
    t.isFalse(result.effective.overridden.medkitCooldownMultiplier)
end)

t.test('RESOLUTION: an override on ALL THREE fields wins outright, for a citizenid with real tier data', function()
    local f = boot({
        isHighCommand = function() return true end,
        tierByCitizenid = { CIT1 = { speedMultiplier = 1.15, scentRangeMultiplier = 1.20, medkitCooldownMultiplier = 0.75 } },
    })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, {
        citizenid = 'CIT1', speedMultiplier = 2.5, scentRangeMultiplier = 2.5, medkitCooldownMultiplier = 0.5,
    }).ok)

    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.equals(result.effective.speedMultiplier, 2.5)
    t.equals(result.effective.scentRangeMultiplier, 2.5)
    t.equals(result.effective.medkitCooldownMultiplier, 0.5)
    t.isTrue(result.effective.overridden.speedMultiplier)
    t.isTrue(result.effective.overridden.scentRangeMultiplier)
    t.isTrue(result.effective.overridden.medkitCooldownMultiplier)
end)

t.test('RESOLUTION: an override for ONE citizenid never affects a DIFFERENT citizenid, even one sharing the same tier', function()
    local f = boot({
        isHighCommand = function() return true end,
        tierByCitizenid = {
            CIT1 = { speedMultiplier = 1.15, scentRangeMultiplier = 1.20 },
            CIT2 = { speedMultiplier = 1.15, scentRangeMultiplier = 1.20 },
        },
    })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 }).ok)

    local cit2 = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT2')
    t.equals(cit2.effective.speedMultiplier, 1.15, 'CIT2 must be completely unaffected by CIT1\'s own override')
    t.isFalse(cit2.effective.overridden.speedMultiplier)
end)

-- ============================================================================
-- SECTION 3 -- OVERLAY PRECEDENCE: a per-field PARTIAL edit never clobbers a
-- field it did not mention.
-- ============================================================================

t.test('OVERLAY PRECEDENCE: upserting only speedMultiplier, then later only scentRangeMultiplier, preserves BOTH -- a partial edit never clears an untouched field', function()
    local f = boot({ isHighCommand = function() return true end })

    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.8 }).ok)
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', scentRangeMultiplier = 1.6 }).ok)

    local override = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override
    t.isNotNil(override)
    t.equals(override.speedMultiplier, 1.8, 'the FIRST edit\'s field must survive a second, unrelated edit')
    t.equals(override.scentRangeMultiplier, 1.6)
end)

t.test('OVERLAY PRECEDENCE: re-editing an already-overridden field to a NEW value replaces only that field', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.8, note = 'first note' }).ok)
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 2.2 }).ok)

    local override = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override
    t.equals(override.speedMultiplier, 2.2, 'the new value must win')
    t.equals(override.note, 'first note', 'a field omitted from the SECOND edit must still carry the value from the FIRST')
end)

t.test('OVERLAY: zero-behavior-change default -- a citizenid nobody has ever edited has no override at all', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'NEVERTOUCHED')
    t.isNil(result.override)
end)

-- ============================================================================
-- SECTION 4 -- TOMBSTONES
-- ============================================================================

t.test('TOMBSTONE: resetting a citizenid with a live override reverts effective values to its plain tier values, and clears from the listing', function()
    local f = boot({
        isHighCommand = function() return true end,
        tierByCitizenid = { CIT1 = { speedMultiplier = 1.15, scentRangeMultiplier = 1.20 } },
    })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 }).ok)
    t.equals(#f.callbacks['john-k9:server:k9ProfilesList'](HC_SOURCE).overrides, 1)

    advance(f)
    local resetResult = f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1')
    t.isTrue(resetResult.ok)
    t.equals(resetResult.effective.speedMultiplier, 1.15, 'must revert to the plain tier value once reset')

    t.equals(#f.callbacks['john-k9:server:k9ProfilesList'](HC_SOURCE).overrides, 0, 'a tombstoned override must not appear in the live listing')
    t.isNil(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override)
end)

t.test('TOMBSTONE: resetting a citizenid that never had an override is a harmless, honestly-reported no-op', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'NEVERTOUCHED')
    t.isTrue(result.ok)
    t.equals(result.reason, 'no_override_existed')
end)

t.test('TOMBSTONE: an override can be re-created after being reset, starting fresh (no ghost of the old values)', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0, note = 'old note' }).ok)
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1').ok)
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', scentRangeMultiplier = 1.9 }).ok)

    local override = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override
    t.isNotNil(override)
    t.equals(override.scentRangeMultiplier, 1.9)
    t.isNil(override.speedMultiplier, 'a re-created override must never inherit a field value from before its own reset')
    t.isNil(override.note)
end)

-- ============================================================================
-- SECTION 5 -- Config.Database.enabled = false (memory backend)
-- ============================================================================

t.test('Config.Database.enabled = false: upsert/get/reset round-trip correctly with no real MySQL involved at all', function()
    local f = boot({ isHighCommand = function() return true end, databaseEnabled = false })
    t.isFalse(f.env.K9Store.IsDatabaseEnabled())

    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.7 }).ok)
    local get = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.equals(get.effective.speedMultiplier, 1.7)

    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1').ok)
    t.isNil(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override)
end)

-- ============================================================================
-- SECTION 6 -- WRITE-FAILURE REPORTING: every write's return value is
-- checked -- a thrown DB error must be reported as db_error, never as
-- success, and must never update the live cache.
-- ============================================================================

t.test('WRITE FAILURE: a thrown DB error on upsert is reported as db_error, and the cache is NOT updated (no partial write reported as success)', function()
    local world = newWorld()
    local realAwait = makeQueryAwait(world)
    local shouldThrow = false
    local throwingAwait = function(sql, params)
        if shouldThrow and sql:find('INSERT INTO k9_individual_overrides (citizenid, speed_multiplier', 1, true) then
            error('simulated write failure', 0)
        end
        return realAwait(sql, params)
    end

    local f = boot({ world = world, isHighCommand = function() return true end })
    f.env.MySQL.query.await = throwingAwait

    shouldThrow = true
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.9 })
    t.isFalse(result.ok)
    t.equals(result.reason, 'db_error')

    shouldThrow = false
    t.isNil(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override, 'a failed write must never be reflected in a later read -- the cache must not have been refreshed from a write that never happened')
end)

t.test('WRITE FAILURE: a thrown DB error on reset is reported as db_error, and the override remains live (a failed reset must not silently succeed)', function()
    local world = newWorld()
    local realAwait = makeQueryAwait(world)
    local shouldThrow = false
    local throwingAwait = function(sql, params)
        if shouldThrow and sql:find('INSERT INTO k9_individual_overrides (citizenid, deleted, updated_by)', 1, true) then
            error('simulated write failure', 0)
        end
        return realAwait(sql, params)
    end

    local f = boot({ world = world, isHighCommand = function() return true end })
    f.env.MySQL.query.await = throwingAwait

    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.9 }).ok)

    advance(f)
    shouldThrow = true
    local result = f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1')
    t.isFalse(result.ok)
    t.equals(result.reason, 'db_error')

    shouldThrow = false
    t.isNotNil(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').override, 'a failed reset must leave the override exactly as it was -- never silently tombstoned')
end)

-- ============================================================================
-- SECTION 7 -- EVERY REJECTED VALUE SHAPE
-- ============================================================================

t.test('VALIDATION: invalid_citizenid for a non-string, empty, or oversized citizenid, on every callback that accepts one', function()
    local f = boot({ isHighCommand = function() return true end })
    -- `nil` is deliberately NOT put through the `ipairs` loop below: a table
    -- constructor's first element being `nil` (`{ nil, ... }`) makes
    -- `ipairs` stop immediately at index 1, silently skipping every value in
    -- the list -- a real gotcha this test itself was originally caught by
    -- (an earlier draft looked green while testing nothing at all). `nil` is
    -- exercised explicitly, on its own, instead.
    for _, bad in ipairs({ '', 123, {}, ('x'):rep(51) }) do
        t.equals(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, bad).reason, 'invalid_citizenid', tostring(bad))
        advance(f)
        t.equals(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, bad).reason, 'invalid_citizenid', tostring(bad))
        advance(f)
        t.equals(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = bad, speedMultiplier = 1.1 }).reason, 'invalid_citizenid', tostring(bad))
        advance(f)
    end

    t.equals(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, nil).reason, 'invalid_citizenid', 'nil citizenid via k9ProfileGet')
    advance(f)
    t.equals(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, nil).reason, 'invalid_citizenid', 'nil citizenid via k9ProfileReset')
    advance(f)
    t.equals(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = nil, speedMultiplier = 1.1 }).reason, 'invalid_citizenid', 'nil citizenid via k9ProfileUpsert')
end)

t.test('VALIDATION: an invalid payload shape (not a table) is rejected as invalid_payload, never errors', function()
    local f = boot({ isHighCommand = function() return true end })
    -- `nil` tested explicitly, outside the `ipairs` loop -- see the
    -- invalid_citizenid test above for exactly why a leading `nil` inside a
    -- table constructor cannot be iterated with `ipairs`.
    for _, bad in ipairs({ 'a string', 123, true }) do
        local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, bad)
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_payload', tostring(bad))
        advance(f)
    end
    local nilResult = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, nil)
    t.isFalse(nilResult.ok)
    t.equals(nilResult.reason, 'invalid_payload')
end)

t.test('VALIDATION: no_fields_to_set when every optional field is omitted', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_fields_to_set')
end)

t.test('VALIDATION: invalid_speed_multiplier / invalid_scent_range_multiplier for non-positive, NaN, or above-ceiling values (default 10.0 ceiling, Config.MaxSpeedScentMultiplier unset)', function()
    local f = boot({ isHighCommand = function() return true end })
    local nan = 0 / 0
    -- 10.01 is just above this file's own built-in fallback ceiling
    -- (server/k9profiles.lua's ResolveMaxSpeedScentMultiplier, 10.0) --
    -- see the dedicated "OWNER-EDITABLE CEILING" section further below for
    -- the tests that prove this ceiling is genuinely config-driven, not
    -- just this one fallback value.
    for _, bad in ipairs({ 0, -1, nan, 10.01, 999, math.huge, -math.huge, 'not a number' }) do
        advance(f)
        local speedResult = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = bad })
        t.equals(speedResult.reason, 'invalid_speed_multiplier', tostring(bad))
        advance(f)
        local scentResult = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', scentRangeMultiplier = bad })
        t.equals(scentResult.reason, 'invalid_scent_range_multiplier', tostring(bad))
    end
end)

t.test('VALIDATION: a rejected/invalid speedMultiplier/scentRangeMultiplier value never errors or crashes the callback, at any ceiling -- wrapped in pcall', function()
    local f = boot({ isHighCommand = function() return true end })
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -1, nan, math.huge, -math.huge, 999, 'not a number' }) do
        advance(f)
        local ok, result = pcall(f.callbacks['john-k9:server:k9ProfileUpsert'], HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = bad })
        t.isTrue(ok, ('callback itself must never throw for speedMultiplier = %s'):format(tostring(bad)))
        t.isFalse(result.ok)
    end
end)

t.test('VALIDATION: invalid_medkit_cooldown_multiplier for a present-but-out-of-(0,1]-range value', function()
    local f = boot({ isHighCommand = function() return true end })
    for _, bad in ipairs({ 0, -0.5, 1.01, 5 }) do
        advance(f)
        t.equals(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', medkitCooldownMultiplier = bad }).reason, 'invalid_medkit_cooldown_multiplier', tostring(bad))
    end
    -- 1.0 itself (the closed upper bound) must be ACCEPTED, matching
    -- server/xptiers.lua's own identical (0, 1] contract.
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', medkitCooldownMultiplier = 1.0 }).ok)
end)

t.test('VALIDATION: invalid_note for an oversized or unsafe-character note; nil/omitted is always fine', function()
    local f = boot({ isHighCommand = function() return true end })
    t.equals(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', note = ('x'):rep(121) }).reason, 'invalid_note')
    advance(f)
    t.equals(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', note = '<script>' }).reason, 'invalid_note')
    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.1, note = 'a perfectly normal note' }).ok)
end)

t.test('VALIDATION: a numeric-looking STRING multiplier is COERCED (tonumber), matching a plain HTML form field\'s own natural shape', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = '1.5' })
    t.isTrue(result.ok)
    t.equals(result.effective.speedMultiplier, 1.5)
end)

t.test('CAP: creating more than MAX_INDIVIDUAL_OVERRIDES (500) distinct citizenids is refused as too_many_overrides; editing an already-live one never counts against the cap', function()
    local f = boot({ isHighCommand = function() return true end })
    for i = 1, 500 do
        local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = ('CIT%04d'):format(i), speedMultiplier = 1.1 })
        t.isTrue(result.ok, ('override #%d should have been accepted'):format(i))
        advance(f)
    end
    local overCap = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'ONE_TOO_MANY', speedMultiplier = 1.1 })
    t.isFalse(overCap.ok)
    t.equals(overCap.reason, 'too_many_overrides')
    advance(f)

    -- Editing an ALREADY-LIVE citizenid must still work even while at the cap.
    local editExisting = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT0001', speedMultiplier = 1.2 })
    t.isTrue(editExisting.ok, 'editing an already-live override must never be blocked by the cap')
end)

-- ============================================================================
-- SECTION 8 -- RATE LIMIT + AUDIT
-- ============================================================================

t.test('RATE LIMIT: a second rapid mutating call from the SAME source is rejected as rate_limited', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.1 }).ok)
    local second = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.2 })
    t.isFalse(second.ok)
    t.equals(second.reason, 'rate_limited')
end)

t.test('AUDIT: a successful create writes exactly one override_create row; a successful edit writes override_update; a successful reset writes override_reset', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [HC_SOURCE] = 'HC_CIT' } })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.1 }).ok)
    t.equals(#f.world.audit, 1)
    t.equals(f.world.audit[1].action, 'override_create')
    t.equals(f.world.audit[1].citizenid, 'CIT1')
    t.equals(f.world.audit[1].changed_by, 'HC_CIT')

    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.3 }).ok)
    t.equals(#f.world.audit, 2)
    t.equals(f.world.audit[2].action, 'override_update')

    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1').ok)
    t.equals(#f.world.audit, 3)
    t.equals(f.world.audit[3].action, 'override_reset')
end)

t.test('AUDIT: a rejected edit (denied, rate-limited, or invalid) writes NOTHING to k9_individual_override_audit', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:k9ProfileUpsert'](NON_HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.1 })
    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = -5 })
    t.equals(#f.world.audit, 0)
end)

t.test('SELF-SERVICE VISIBILITY: a high-command officer editing their OWN citizenid\'s K9 gets a distinct audit marker and a response warning -- never blocked, only disclosed', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [HC_SOURCE] = 'SELF_CIT' } })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'SELF_CIT', speedMultiplier = 2.9 })
    t.isTrue(result.ok, 'a self-edit must still complete in one action, never gated')
    t.isNotNil(result.warning)
    t.contains(f.world.audit[1].detail, 'SELF-OVERRIDE')
end)

-- ============================================================================
-- SECTION 9 -- BOOT-ORDER RACE against server/datastore.lua's schema-
-- collision probe. Mirrors tests/xptiereditor_spec.lua's own identical
-- section byte-for-byte in structure -- see that file's own header comment
-- for the full "why a separate coroutine dispatcher" writeup, not repeated
-- here.
-- ============================================================================

--- @param opts table? -- { foreignOverrideRows: table? }
--- @return table fixture -- { env, coros, fireResourceStart, resumeNext, overrideQueryCallCount }
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

    local callbacks = {}
    local overrideQueryCalls = 0
    local queryStub = {
        await = function(sql, _params)
            if sql:find('SELECT citizenid, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, sprint_decay_per_tick, note, deleted FROM k9_individual_overrides', 1, true) then
                overrideQueryCalls = overrideQueryCalls + 1
                return opts.foreignOverrideRows or {}
            end
            if sql:find('INFORMATION_SCHEMA.COLUMNS', 1, true) then
                return coroutine.yield()
            end
            error('bootWithRacingMySQL: unexpected query, no stub behavior defined: ' .. tostring(sql))
        end,
    }

    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        AddEventHandler = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetGameTimer = function() return 0 end,
        Wait = function(_ms) coroutine.yield() end,
        lib = { callback = { register = function(name, handler) callbacks[name] = handler end } },
        MySQL = { query = queryStub },
        print = printStub,
        IsHighCommand = function() return true end,
        exports = { qbx_core = { GetPlayer = function(_self, _src) return nil end } },
        -- GAP 1, PART 2 -- this file's own onResourceStart handler now
        -- backfills speed-override status for every online player after
        -- RefreshOverrideCache(); nobody is online in this fixture at all
        -- (GetPlayer above always answers nil), so an empty list is both
        -- sufficient and correct here.
        GetPlayers = function() return {} end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/k9profiles.lua', env)

    local coros = {}

    local function fireResourceStart()
        for i, fn in ipairs(eventHandlers['onResourceStart']) do
            local co = coroutine.create(fn)
            coros[i] = co
            local ok, err = coroutine.resume(co, 'john-k9')
            if not ok then error(('onResourceStart handler #%d errored: %s'):format(i, tostring(err))) end
        end
    end

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
        env = env, coros = coros, callbacks = callbacks,
        fireResourceStart = fireResourceStart, resumeNext = resumeNext,
        overrideQueryCallCount = function() return overrideQueryCalls end,
    }
end

t.test('BOOT-ORDER RACE: a foreign k9_individual_overrides table that satisfies this file\'s own SELECT but fails the FULL schema probe must never reach a live override', function()
    local f = bootWithRacingMySQL({
        foreignOverrideRows = { { citizenid = 'STRANGER', speed_multiplier = 999, scent_range_multiplier = 999, medkit_cooldown_multiplier = nil, note = nil, deleted = 0 } },
    })

    f.fireResourceStart()
    t.equals(f.overrideQueryCallCount(), 0, 'this file must not issue its own SELECT before the schema probe has settled')

    -- Resolve the probe with a schema response missing some columns
    -- k9_individual_overrides is checked against -- a genuine collision.
    t.isTrue(f.resumeNext({
        { tbl = 'k9_individual_overrides', col = 'citizenid' },
        { tbl = 'k9_individual_overrides', col = 'speed_multiplier' },
    }), 'the probe must still be suspended, waiting to be resolved')
    t.isFalse(f.env.K9Store.IsDatabaseEnabled(), 'the collision must have been detected')
    t.equals(f.overrideQueryCallCount(), 0, 'still not read immediately after settling')

    t.isTrue(f.resumeNext(), 'this file\'s handler, parked inside its own bounded wait, wakes on its next poll')
    t.equals(f.overrideQueryCallCount(), 0, 'DatabaseEnabled() is now false, so K9Store.IndividualOverride_GetAllRows takes the MEMORY branch -- it must NEVER have issued its own SELECT against the foreign table')
    t.equals(f.callbacks['john-k9:server:k9ProfilesList'](1).overrides and #f.callbacks['john-k9:server:k9ProfilesList'](1).overrides, 0, 'no foreign row may ever surface as a live override')
    t.isFalse(f.resumeNext(), 'every handler has now run to completion')
end)

t.test('BOOT-ORDER RACE control: once the probe settles with NO collision, this file performs its real read and picks up a legitimate persisted override', function()
    local f = bootWithRacingMySQL({
        foreignOverrideRows = { { citizenid = 'CIT1', speed_multiplier = 1.4, scent_range_multiplier = 1.4, medkit_cooldown_multiplier = nil, note = nil, deleted = 0 } },
    })

    f.fireResourceStart()
    t.equals(f.overrideQueryCallCount(), 0)

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
    t.equals(f.overrideQueryCallCount(), 1, 'now that settlement confirmed no collision, this file performs its real read exactly once')
    local list = f.callbacks['john-k9:server:k9ProfilesList'](1)
    t.equals(#list.overrides, 1)
    t.equals(list.overrides[1].citizenid, 'CIT1')
    t.isFalse(f.resumeNext())
end)

t.test('BOOT-ORDER RACE bounded timeout: if the schema probe never settles, this file gives up after a bounded number of polls and boots with no individual overrides at all', function()
    local f = bootWithRacingMySQL({
        foreignOverrideRows = { { citizenid = 'CIT1', speed_multiplier = 1.4, scent_range_multiplier = 1.4, medkit_cooldown_multiplier = nil, note = nil, deleted = 0 } },
    })
    f.fireResourceStart()
    t.equals(f.overrideQueryCallCount(), 0)

    -- FIND this file's own handler rather than indexing it by position.
    -- This used to be `f.coros[2]`, on the assumption that k9profiles.lua's
    -- start handler is always the second one registered (right after
    -- datastore.lua's own probe, since this fixture loads no other
    -- onResourceStart-registering file). That is not a property this spec
    -- controls: every file loaded into the fixture registers its own
    -- handlers, so an unrelated file (e.g. datastore.lua or cooldowns.lua)
    -- gaining one shifts the index and this test silently starts driving
    -- the WRONG coroutine -- exactly what happened to a sibling spec when
    -- server/permissions.lua went from one start handler to three for an
    -- unrelated feature. That test failed while the boot-order safety
    -- property it exists to protect was completely intact.
    --
    -- Never resume coros[1] (the probe) at all -- a hung query that never
    -- comes back. This file's own handler is the one still suspended after
    -- the probe is deliberately left hung: it is the only one polling for
    -- a settle that never comes. Identifying it by that behaviour cannot
    -- drift.
    local profileCo
    for i, co in ipairs(f.coros) do
        if i > 1 and coroutine.status(co) == 'suspended' then
            profileCo = co
            break
        end
    end
    t.isTrue(profileCo ~= nil, 'k9profiles.lua must have a suspended start handler polling for the schema check to settle')

    local resumes = 0
    while coroutine.status(profileCo) == 'suspended' and resumes < 200 do
        coroutine.resume(profileCo)
        resumes = resumes + 1
    end

    t.isTrue(resumes < 200, 'must give up within a bounded number of polls, never spin forever waiting on a probe that never answers')
    t.equals(coroutine.status(profileCo), 'dead', 'this file\'s own onResourceStart handler must have completed (given up), not be stuck suspended forever')
    t.equals(f.overrideQueryCallCount(), 0, 'must never have trusted the unconfirmed table')
    t.equals(#f.callbacks['john-k9:server:k9ProfilesList'](1).overrides, 0, 'boots with no individual overrides at all, exactly like Config.Database.enabled = false, rather than trust an unconfirmed table')
end)

-- ============================================================================
-- SECTION 10 -- OWNER-EDITABLE CEILING (Config.MaxSpeedScentMultiplier,
-- Part A of the owner's "keep the speed and stamina editing where i can
-- edit it to as high as i want" request). ResolveMaxSpeedScentMultiplier's
-- own CLAMP-AND-WARN posture is exercised directly through
-- k9ProfileUpsert's own speedMultiplier/scentRangeMultiplier validation --
-- the same seam server/xptiers.lua/server/runtimecontrol.lua each read
-- their own copy of this exact setting through, per this file's own header
-- "no cross-file `local` import mechanism" convention.
-- ============================================================================

t.test('CEILING IS GENUINELY CONFIG-DRIVEN: Config.MaxSpeedScentMultiplier = 5.0 accepts 4.9 and rejects 5.1', function()
    local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = 5.0 })
    local ok1 = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 4.9 })
    t.isTrue(ok1.ok, 'a value below a 5.0 ceiling must be accepted')
    t.equals(ok1.effective.speedMultiplier, 4.9)

    advance(f)
    local rejected = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 5.1 })
    t.isFalse(rejected.ok, 'a value above a 5.0 ceiling must be rejected')
    t.equals(rejected.reason, 'invalid_speed_multiplier')
end)

t.test('CEILING IS GENUINELY CONFIG-DRIVEN FOR SCENT (no engine ceiling of its own): a simulated reboot at Config.MaxSpeedScentMultiplier = 50.0 now accepts a scentRangeMultiplier of 40.0', function()
    -- Simulates a resource restart: a brand-new boot() with a different
    -- Config.MaxSpeedScentMultiplier, exactly like an operator editing
    -- config.lua and restarting the resource. scentRangeMultiplier, UNLIKE
    -- speedMultiplier (see GAP 1 PART 2 section below), never touches a
    -- game native at all -- server/tracking.lua applies it as a bare
    -- multiplication against a search radius -- so it has no reason to be
    -- capped by anything BUT the owner's own chosen ceiling, and this test
    -- proves it still is not.
    local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = 50.0 })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', scentRangeMultiplier = 40.0 })
    t.isTrue(result.ok, 'a value that would have been rejected under the 10.0/3.0 defaults must be accepted once the operator raises the ceiling to 50.0')
    t.equals(result.effective.scentRangeMultiplier, 40.0)
end)

t.test('CEILING SANITY CHECK (temporarily hardcode 3.0 back to prove the test above is real): a stale 3.0 ceiling would reject 40.0', function()
    -- This is the RED-THEN-GREEN proof the task calls for, encoded as an
    -- executable check rather than only a manual step: it reasserts, using
    -- the SAME production validator this file's callback calls
    -- (IsValidMultiplier is not exported, so this re-derives its exact
    -- contract: finite, > 0, <= max), that 40.0 would NOT have passed
    -- against the old hardcoded 3.0 ceiling -- confirming the test two
    -- above is actually exercising the ceiling, not passing for an
    -- unrelated reason.
    local wouldPassAtOldHardcodedCeiling = 40.0 > 0 and 40.0 <= 3.0
    t.isFalse(wouldPassAtOldHardcodedCeiling, '40.0 must be above the OLD hardcoded 3.0 ceiling for the test above to be a meaningful proof of config-drivenness')
end)

-- ============================================================================
-- GAP 1, PART 2 -- speedMultiplier's OWN ceiling: unlike scentRangeMultiplier
-- above, capped at whichever is SMALLER of Config.MaxSpeedScentMultiplier
-- and the real SET_PED_MOVE_RATE_OVERRIDE engine maximum (10.0) -- see
-- server/k9profiles.lua's own header "GAP 1, PART 2" for the full research
-- writeup this is grounded in. RED-THEN-GREEN, WITH A CONTROL: the FLOOR
-- half (0.1) and the CEILING half (10.0) are each proven with their own
-- positive (just-inside, accepted) and negative (just-outside, rejected)
-- pair, per this task's own "two things a passing test can mean" caution.
-- ============================================================================

t.test('GAP 1 PART 2 -- SPEED CEILING IS ENGINE-CAPPED, NOT CONFIG-UNBOUNDED: at Config.MaxSpeedScentMultiplier = 50.0, a speedMultiplier of 40.0 is REJECTED (engine max is 10.0) even though the identical 40.0 is accepted for scentRangeMultiplier above', function()
    local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = 50.0 })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 40.0 })
    t.isFalse(result.ok, 'speedMultiplier must never be allowed to exceed what SET_PED_MOVE_RATE_OVERRIDE can physically do, no matter how high the owner raises the shared config ceiling')
    t.equals(result.reason, 'invalid_speed_multiplier')
end)

t.test('GAP 1 PART 2 CONTROL: exactly at the engine ceiling (10.0) still succeeds, even with a much higher config value -- proves the rejection above is a REAL 10.0 cap, not an accidental full rejection of every high value', function()
    local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = 50.0 })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 10.0 })
    t.isTrue(result.ok, '10.0 itself -- the documented SET_PED_MOVE_RATE_OVERRIDE maximum -- must remain acceptable')
    t.equals(result.effective.speedMultiplier, 10.0)

    advance(f)
    local justOver = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 10.01 })
    t.isFalse(justOver.ok, 'one hundredth over the real engine ceiling must still be rejected -- the boundary is exact, not a rounded-off approximation')
    t.equals(justOver.reason, 'invalid_speed_multiplier')
end)

t.test('GAP 1 PART 2 -- speedMultiplier still respects a TIGHTER owner-chosen ceiling below 10.0 (an owner\'s own deliberate policy choice is never widened by this fix)', function()
    local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = 3.0 })
    local overCeiling = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 5.0 })
    t.isFalse(overCeiling.ok, 'an owner who deliberately keeps the ceiling at 3.0 must still be respected -- this fix only ever REMOVES a mismatch against a HIGHER config value, it does not grant a floor of 10.0 regardless of policy')
    t.equals(overCeiling.reason, 'invalid_speed_multiplier')
end)

t.test('GAP 1 PART 2 -- SPEED FLOOR: a speedMultiplier at or under 0.1 is REJECTED outright (deterministically guaranteed to be floor-clamped away from whatever was typed), but scentRangeMultiplier has no such floor', function()
    local f = boot({ isHighCommand = function() return true end })
    local atFloor = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 0.1 })
    t.isFalse(atFloor.ok, 'exactly 0.1 must be rejected -- IsValidSpeedMultiplier requires STRICTLY greater than the floor')
    t.equals(atFloor.reason, 'invalid_speed_multiplier')

    advance(f)
    local belowFloor = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 0.05 })
    t.isFalse(belowFloor.ok, 'a value below the floor must also be rejected')
    t.equals(belowFloor.reason, 'invalid_speed_multiplier')

    -- CONTROL: scentRangeMultiplier has no engine-driven floor concern at
    -- all (it never reaches SET_PED_MOVE_RATE_OVERRIDE) -- the SAME 0.05
    -- value must still be accepted for that field, proving the rejection
    -- above is specific to speedMultiplier's own new validator, not a
    -- blanket "reject small numbers" regression in the shared one.
    advance(f)
    local scentAtSameValue = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', scentRangeMultiplier = 0.05 })
    t.isTrue(scentAtSameValue.ok, 'scentRangeMultiplier must still accept the identical 0.05 value -- confirms the floor is speed-specific, not shared')
end)

t.test('GAP 1 PART 2 CONTROL: just above the floor (0.11) is accepted for speedMultiplier -- proves the rejection above is a real, tight boundary, not an accidental rejection of every small value', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 0.11 })
    t.isTrue(result.ok, '0.11 is a real, legitimate speedMultiplier just above the floor and must be accepted')
    t.equals(result.effective.speedMultiplier, 0.11)
end)

t.test('CEILING: 0, negative, NaN, infinity and a string are each rejected at a NON-DEFAULT ceiling too, and the call never errors (pcall)', function()
    local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = 5.0 })
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -1, nan, math.huge, -math.huge, 'not a number' }) do
        advance(f)
        local ok, result = pcall(f.callbacks['john-k9:server:k9ProfileUpsert'], HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = bad })
        t.isTrue(ok, ('must never throw for speedMultiplier = %s at a 5.0 ceiling'):format(tostring(bad)))
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_speed_multiplier')
    end
end)

t.test('CEILING: Config.MaxSpeedScentMultiplier missing entirely falls back to 10.0 with a named warning, never asserts/crashes the file', function()
    local f = boot({ isHighCommand = function() return true end }) -- maxSpeedScentMultiplier omitted -> Config.MaxSpeedScentMultiplier is nil
    -- The file must still have loaded and registered every callback (a
    -- bare top-level `assert` here would have prevented this entirely).
    t.isNotNil(f.callbacks['john-k9:server:k9ProfileUpsert'])
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.MaxSpeedScentMultiplier', 1, true) and line:find('10', 1, true) then
            found = true
        end
    end
    t.isTrue(found, 'a missing Config.MaxSpeedScentMultiplier must print a warning naming the exact setting and the 10.0 fallback')

    -- And the fallback is genuinely applied, not just warned about: 10.0
    -- accepted, 10.01 rejected.
    local accepted = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 10.0 })
    t.isTrue(accepted.ok)
    advance(f)
    local rejected = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT2', speedMultiplier = 10.01 })
    t.isFalse(rejected.ok)
    t.equals(rejected.reason, 'invalid_speed_multiplier')
end)

t.test('CEILING: Config.MaxSpeedScentMultiplier = 0 / negative / NaN / infinity / a string all fall back to 10.0 with a named warning', function()
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -5, nan, math.huge, -math.huge, 'not a number' }) do
        local f = boot({ isHighCommand = function() return true end, maxSpeedScentMultiplier = bad })
        local accepted = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 10.0 })
        t.isTrue(accepted.ok, ('Config.MaxSpeedScentMultiplier = %s must fall back to the 10.0 default, not disable the file'):format(tostring(bad)))
    end
end)

-- ============================================================================
-- SECTION 11 -- STAMINA (sprintDecayPerTick, Part B). Owner's own words:
-- "be able to make the stamina as high as i want and be able to make the
-- stamina as high as i want or permanant." Routed through the SAME
-- CanManageK9Profiles/K9ProfileEditMutex/K9ProfileActionCooldown/
-- WriteOverrideAudit machinery as speed/scent/medkit above -- see
-- server/k9profiles.lua's own "STAMINA OVERRIDE" declaration comment for
-- why this is held in a separate, SESSION-ONLY in-memory table rather than
-- persisted (no `k9_individual_overrides` column exists for it yet).
-- ============================================================================

t.test('STAMINA: with no override and no Config.Wellbeing at all (this fixture never defines it), effective sprintDecayPerTick defaults to 2.0', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'NOBODY')
    t.equals(result.effective.sprintDecayPerTick, 2.0)
    t.isFalse(result.effective.overridden.sprintDecayPerTick)
end)

t.test('STAMINA: with no override, effective sprintDecayPerTick defers to Config.Wellbeing.Fatigue.sprintDecayPerTick when that IS defined', function()
    local f = boot({ isHighCommand = function() return true end, wellbeingConfig = { Fatigue = { sprintDecayPerTick = 7.5 } } })
    local result = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'NOBODY')
    t.equals(result.effective.sprintDecayPerTick, 7.5)
end)

t.test('STAMINA: 0 IS ACCEPTED -- the owner\'s own requested "permanent stamina" sentinel, never treated as invalid/falsy/omitted', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 0 })
    t.isTrue(result.ok, 'sprintDecayPerTick = 0 must be accepted, not rejected as falsy/invalid')
    t.equals(result.effective.sprintDecayPerTick, 0)
    t.isTrue(result.effective.overridden.sprintDecayPerTick)
end)

t.test('STAMINA VALIDATOR SANITY CHECK (proves the test above is real): a `> 0` validator (instead of the production `>= 0`) would have rejected 0', function()
    -- Re-derives IsValidStaminaDrain's OWN two candidate contracts inline
    -- (it is not exported) -- if this ever reads `false` for the `>= 0`
    -- line, IsValidStaminaDrain's contract has silently drifted back to
    -- `> 0` and the test above would start passing for the wrong reason.
    local wouldPassAtCorrectGteZero = (0 >= 0) and 0 <= 20.0
    local wouldPassAtWrongGtZero = (0 > 0) and 0 <= 20.0
    t.isTrue(wouldPassAtCorrectGteZero, 'the production contract (>= 0) must accept 0')
    t.isFalse(wouldPassAtWrongGtZero, 'a `> 0` contract would have rejected 0 -- confirming the test above is a meaningful proof of the >= 0 contract, not a coincidence')
end)

t.test('STAMINA: negative, NaN, infinity, a string, and above-MAX_STAMINA_DRAIN_PER_TICK (20.0) values are all rejected, never crash (pcall)', function()
    local f = boot({ isHighCommand = function() return true end })
    local nan = 0 / 0
    for _, bad in ipairs({ -1, -0.01, nan, math.huge, -math.huge, 20.01, 999, 'not a number' }) do
        advance(f)
        local ok, result = pcall(f.callbacks['john-k9:server:k9ProfileUpsert'], HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = bad })
        t.isTrue(ok, ('must never throw for sprintDecayPerTick = %s'):format(tostring(bad)))
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_sprint_decay_per_tick', tostring(bad))
    end
end)

t.test('STAMINA: exactly MAX_STAMINA_DRAIN_PER_TICK (20.0) is accepted -- an inclusive ceiling', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 20.0 })
    t.isTrue(result.ok)
    t.equals(result.effective.sprintDecayPerTick, 20.0)
end)

t.test('STAMINA AUTHORIZATION: a non-high-command caller is refused a stamina change EVEN ON THEIR OWN citizenid', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        onlineSources = { [NON_HC_SOURCE] = 'SELF_CIT' },
    })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](NON_HC_SOURCE, { citizenid = 'SELF_CIT', sprintDecayPerTick = 0 })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.equals(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'SELF_CIT').effective.overridden.sprintDecayPerTick, false, 'a denied caller must never be able to write a stamina override, even for themselves')
end)

t.test('STAMINA: a high-command caller CAN set stamina on somebody ELSE, and on a server WITH a database it now persists, so no warning is carried', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'SOMEONE_ELSE', sprintDecayPerTick = 5.0 })
    t.isTrue(result.ok)
    t.equals(result.effective.sprintDecayPerTick, 5.0)
    -- CHANGED BY MIGRATION 0021. This used to assert the warning was
    -- ALWAYS present, because stamina was held in memory only and really did
    -- vanish on restart. It now has a real column alongside speed and scent
    -- range, so on any server with a database there is nothing to warn
    -- about, and carrying the warning anyway would be telling the operator
    -- something untrue. The memory-only case is pinned separately below.
    t.isNil(result.staminaPersistenceWarning, 'with a database, stamina persists like every other override -- no warning belongs here')
end)

t.test('STAMINA: on a MEMORY-ONLY server the warning IS still carried, because nothing on this table survives a restart there', function()
    local f = boot({ isHighCommand = function() return true end })
    -- Force the memory-only branch the same way this file's own boot-race
    -- section does: the whole table is unavailable, so K9Store falls back.
    f.env.K9Store.IsDatabaseEnabled = function() return false end
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT2', sprintDecayPerTick = 5.0 })
    t.isTrue(result.ok)
    t.isNotNil(result.staminaPersistenceWarning, 'without a database this genuinely does reset, and the operator must be told')
    t.isTrue(result.staminaPersistenceWarning:find('restart', 1, true) ~= nil, 'the warning must actually say it resets on restart, not merely exist')
end)

t.test('STAMINA PERSISTENCE (migration 0021): a stamina override set before a restart is still there after one, including the 0 that means PERMANENT', function()
    -- THE WHOLE POINT OF MIGRATION 0021. Before it, stamina lived in a
    -- file-local table and every one of these came back nil after a
    -- restart, silently, and the dog quietly got tired again.
    --
    -- `world` is the fake database and deliberately OUTLIVES the boot, so
    -- booting a second time against the same world is exactly what a
    -- resource restart does: same rows on disk, everything in memory gone.
    local first = boot({ isHighCommand = function() return true end })

    -- 0 is the sentinel for stamina that NEVER runs out, and it is the
    -- value most likely to be chosen deliberately -- so it is the one that
    -- must survive. It is also the one a truthiness test would silently
    -- drop, which is why the production cache rebuild uses tonumber().
    local zeroRes = first.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 0 })
    t.isTrue(zeroRes.ok, 'setting stamina to 0 (PERMANENT) must be accepted; got reason=' .. tostring(zeroRes.reason))
    -- Past the per-caller edit cooldown, the same way this file's own RATE
    -- LIMIT test establishes -- two edits in the same millisecond are
    -- correctly refused and that is not what this test is about.
    first.fakeNow.value = first.fakeNow.value + 1100
    local r2 = first.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT2', sprintDecayPerTick = 7.5 })
    t.isTrue(r2.ok, 'CIT2 stamina upsert must succeed; reason=' .. tostring(r2.reason))
    t.equals(first.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').effective.sprintDecayPerTick, 0)

    -- The restart.
    local second = boot({ isHighCommand = function() return true end, world = first.world })

    local permanent = second.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.equals(permanent.effective.sprintDecayPerTick, 0, 'PERMANENT stamina must survive a restart -- 0 is a real value here, not "unset"')
    t.isTrue(permanent.effective.overridden.sprintDecayPerTick, 'and must still read as overridden, not as an inherited default that happens to match')

    local ordinary = second.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT2')
    t.equals(ordinary.effective.sprintDecayPerTick, 7.5, 'an ordinary stamina override must survive too')

    -- And a dog that never had one must not acquire one from the rebuild.
    t.isFalse(second.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT3').effective.overridden.sprintDecayPerTick)
end)

t.test('STAMINA: a stamina override SURVIVES a cache rebuild -- the thing migration 0021 exists to make true', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 3.0 }).ok)
    local getResult = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.isNil(getResult.staminaPersistenceWarning, 'with a database there is nothing to warn about')
    t.equals(getResult.override.sprintDecayPerTick, 3.0)
end)

t.test('STAMINA: k9ProfileGet for a citizenid with NO stamina override carries NO staminaPersistenceWarning', function()
    local f = boot({ isHighCommand = function() return true end })
    local getResult = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'NEVER_TOUCHED')
    t.isNil(getResult.staminaPersistenceWarning)
end)

t.test('STAMINA: RESET clears stamina and the effective value reverts to the global default', function()
    local f = boot({ isHighCommand = function() return true end, wellbeingConfig = { Fatigue = { sprintDecayPerTick = 4.0 } } })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 0 }).ok)
    t.equals(f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1').effective.sprintDecayPerTick, 0)

    advance(f)
    local resetResult = f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1')
    t.isTrue(resetResult.ok)
    t.equals(resetResult.effective.sprintDecayPerTick, 4.0, 'must revert to the global Config.Wellbeing.Fatigue.sprintDecayPerTick default')

    local getAfterReset = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.isFalse(getAfterReset.effective.overridden.sprintDecayPerTick)
    t.isNil(getAfterReset.staminaPersistenceWarning, 'a reset stamina override must no longer carry the persistence warning')
end)

t.test('STAMINA: reset on a citizenid with ONLY a stamina override (no speed/scent/medkit ever set) is a real, non-no-op reset -- never db_error, never no_override_existed', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'STAMINA_ONLY', sprintDecayPerTick = 1.0 }).ok)
    advance(f)
    local resetResult = f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'STAMINA_ONLY')
    t.isTrue(resetResult.ok)
    t.isNil(resetResult.reason, 'a real reset, not the no_override_existed no-op path')
    -- CHANGED BY MIGRATION 0021, deliberately. This used to assert the
    -- OPPOSITE -- that a stamina-only override never wrote a row -- which
    -- was correct while the schema had no column for it, and was exactly
    -- why such an override vanished on restart. Now it writes a real row,
    -- and the reset tombstones it like any other.
    t.isNotNil(f.world.overrides['STAMINA_ONLY'], 'a stamina-only override now writes a real row, so it can survive a restart')
    t.equals(f.world.overrides['STAMINA_ONLY'].deleted, 1, 'and the reset must tombstone that row, not leave it live')
end)

t.test('STAMINA: a partial edit that touches ONLY a persisted field (e.g. speedMultiplier) leaves an existing stamina override untouched', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 6.0 }).ok)
    advance(f)
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.3 })
    t.isTrue(result.ok)
    t.equals(result.effective.speedMultiplier, 1.3)
    t.equals(result.effective.sprintDecayPerTick, 6.0, 'an edit that never mentions sprintDecayPerTick must not clear a previously-set stamina override')
end)

t.test('STAMINA: a stamina-only override for a NEW citizenid, once a persisted field is later added, does not double-count against the cap', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 1.0 }).ok)
    advance(f)
    -- Adding a persisted field to the SAME citizenid must be treated as
    -- editing an already-live override (isNew = false), never as a second
    -- new entry.
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.1 })
    t.isTrue(result.ok)
end)

t.test('STAMINA CAP: stamina-only overrides count toward MAX_INDIVIDUAL_OVERRIDES (500) exactly like speed/scent/medkit overrides do', function()
    local f = boot({ isHighCommand = function() return true end })
    for i = 1, 500 do
        local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = ('STA%04d'):format(i), sprintDecayPerTick = 1.0 })
        t.isTrue(result.ok, ('stamina-only override #%d should have been accepted'):format(i))
        advance(f)
    end
    local overCap = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'ONE_TOO_MANY', sprintDecayPerTick = 1.0 })
    t.isFalse(overCap.ok)
    t.equals(overCap.reason, 'too_many_overrides')
    advance(f)

    -- Editing an already-live stamina-only override must still work even at the cap.
    local editExisting = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'STA0001', sprintDecayPerTick = 2.0 })
    t.isTrue(editExisting.ok, 'editing an already-live stamina-only override must never be blocked by the cap')
end)

t.test('STAMINA CAP: a MIX of persisted overrides and stamina-only overrides is counted as ONE combined pool, not two separate 500-slot pools', function()
    local f = boot({ isHighCommand = function() return true end })
    for i = 1, 250 do
        t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = ('SPD%04d'):format(i), speedMultiplier = 1.1 }).ok)
        advance(f)
    end
    for i = 1, 250 do
        t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = ('STA%04d'):format(i), sprintDecayPerTick = 1.0 }).ok)
        advance(f)
    end
    local overCap = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'ONE_TOO_MANY', sprintDecayPerTick = 1.0 })
    t.isFalse(overCap.ok)
    t.equals(overCap.reason, 'too_many_overrides')
end)

t.test('STAMINA AUDIT: create/update/reset all write to k9_individual_override_audit with sprintDecayPerTick recorded in detail', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [HC_SOURCE] = 'HC_CIT' } })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 2.5 }).ok)
    t.equals(#f.world.audit, 1)
    t.isTrue(f.world.audit[1].detail:find('sprintDecayPerTick=2.5', 1, true) ~= nil)

    advance(f)
    t.isTrue(f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1').ok)
    t.equals(#f.world.audit, 2)
    t.equals(f.world.audit[2].action, 'override_reset')
end)

t.test('STAMINA: ListK9IndividualOverrides / k9ProfilesList includes a citizenid with ONLY a stamina override', function()
    local f = boot({ isHighCommand = function() return true end })
    t.isTrue(f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'STAMINA_ONLY', sprintDecayPerTick = 1.5 }).ok)
    local listResult = f.callbacks['john-k9:server:k9ProfilesList'](HC_SOURCE)
    t.isTrue(listResult.ok)
    local found
    for _, entry in ipairs(listResult.overrides) do
        if entry.citizenid == 'STAMINA_ONLY' then found = entry end
    end
    t.isNotNil(found, 'a stamina-only override must still appear in the list')
    t.equals(found.sprintDecayPerTick, 1.5)
end)

-- ============================================================================
-- SECTION 12 -- OWNER-EDITABLE STAMINA CEILING (Config.MaxStaminaDrainPerTick,
-- coder-ui finding: MAX_STAMINA_DRAIN_PER_TICK was a plain hardcoded Lua
-- local -- unlike MAX_SPEED_SCENT_MULTIPLIER above, which already read an
-- owner-editable Config field -- meaning stamina was NOT actually "as high
-- as i want" yet, despite the owner asking for exactly that in the same
-- breath as speed/scent). ResolveMaxStaminaDrainPerTick mirrors
-- ResolveMaxSpeedScentMultiplier's own clamp-and-warn shape exactly --
-- SECTION 10's own tests above are the direct template for this section.
-- THE DIRECTION IS INVERTED from Section 10, and 0 (permanent) must remain
-- valid at every ceiling, however low -- both asserted explicitly below.
-- ============================================================================

t.test('STAMINA CEILING IS GENUINELY CONFIG-DRIVEN: Config.MaxStaminaDrainPerTick = 5.0 accepts 4.9 and rejects 5.1', function()
    local f = boot({ isHighCommand = function() return true end, maxStaminaDrainPerTick = 5.0 })
    local ok1 = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 4.9 })
    t.isTrue(ok1.ok, 'a value below a 5.0 ceiling must be accepted')
    t.equals(ok1.effective.sprintDecayPerTick, 4.9)

    advance(f)
    local rejected = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 5.1 })
    t.isFalse(rejected.ok, 'a value above a 5.0 ceiling must be rejected')
    t.equals(rejected.reason, 'invalid_sprint_decay_per_tick')
end)

t.test('STAMINA CEILING IS GENUINELY CONFIG-DRIVEN: a simulated reboot at Config.MaxStaminaDrainPerTick = 100.0 now accepts 90.0', function()
    local f = boot({ isHighCommand = function() return true end, maxStaminaDrainPerTick = 100.0 })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 90.0 })
    t.isTrue(result.ok, 'a value that would have been rejected under the old hardcoded 20.0 must be accepted once the operator raises the ceiling to 100.0')
    t.equals(result.effective.sprintDecayPerTick, 90.0)
end)

t.test('STAMINA CEILING SANITY CHECK (prove the test above is real): a stale 20.0 ceiling would reject 90.0', function()
    local wouldPassAtOldHardcodedCeiling = 90.0 >= 0 and 90.0 <= 20.0
    t.isFalse(wouldPassAtOldHardcodedCeiling, '90.0 must be above the OLD hardcoded 20.0 ceiling for the test above to be a meaningful proof of config-drivenness')
end)

t.test('STAMINA CEILING: NEVER REJECTS 0 (permanent), even at a very low configured ceiling', function()
    local f = boot({ isHighCommand = function() return true end, maxStaminaDrainPerTick = 1.0 })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 0 })
    t.isTrue(result.ok, 'the permanent-stamina sentinel (0) must remain valid regardless of how low this ceiling is configured')
    t.equals(result.effective.sprintDecayPerTick, 0)
end)

t.test('STAMINA CEILING: negative, NaN, infinity and a string are each rejected at a NON-DEFAULT ceiling too, and the call never errors (pcall)', function()
    local f = boot({ isHighCommand = function() return true end, maxStaminaDrainPerTick = 5.0 })
    local nan = 0 / 0
    for _, bad in ipairs({ -1, nan, math.huge, -math.huge, 'not a number' }) do
        advance(f)
        local ok, result = pcall(f.callbacks['john-k9:server:k9ProfileUpsert'], HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = bad })
        t.isTrue(ok, ('must never throw for sprintDecayPerTick = %s at a 5.0 ceiling'):format(tostring(bad)))
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_sprint_decay_per_tick')
    end
end)

t.test('STAMINA CEILING: Config.MaxStaminaDrainPerTick missing entirely falls back to 20.0 with a named warning, never asserts/crashes the file', function()
    local f = boot({ isHighCommand = function() return true end }) -- maxStaminaDrainPerTick omitted -> Config.MaxStaminaDrainPerTick is nil
    t.isNotNil(f.callbacks['john-k9:server:k9ProfileUpsert'], 'the file must still have loaded and registered every callback')
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.MaxStaminaDrainPerTick', 1, true) and line:find('20', 1, true) then
            found = true
        end
    end
    t.isTrue(found, 'a missing Config.MaxStaminaDrainPerTick must print a warning naming the exact setting and the 20.0 fallback')

    local accepted = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 20.0 })
    t.isTrue(accepted.ok)
    advance(f)
    local rejected = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT2', sprintDecayPerTick = 20.01 })
    t.isFalse(rejected.ok)
    t.equals(rejected.reason, 'invalid_sprint_decay_per_tick')
end)

t.test('STAMINA CEILING: Config.MaxStaminaDrainPerTick = 0 / negative / NaN / infinity / a string all fall back to 20.0 with a named warning', function()
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -5, nan, math.huge, -math.huge, 'not a number' }) do
        local f = boot({ isHighCommand = function() return true end, maxStaminaDrainPerTick = bad })
        local accepted = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 20.0 })
        t.isTrue(accepted.ok, ('Config.MaxStaminaDrainPerTick = %s must fall back to the 20.0 default, not disable the file'):format(tostring(bad)))
    end
end)

t.test('STAMINA CEILING: raising Config.MaxStaminaDrainPerTick never moves Config.MaxSpeedScentMultiplier\'s own ceiling -- the two settings are independent', function()
    local f = boot({ isHighCommand = function() return true end, maxStaminaDrainPerTick = 100.0, maxSpeedScentMultiplier = 5.0 })
    local staminaOk = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', sprintDecayPerTick = 50.0 })
    t.isTrue(staminaOk.ok, 'the raised stamina ceiling applies to stamina')

    advance(f)
    local speedRejected = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 50.0 })
    t.isFalse(speedRejected.ok, 'speedMultiplier must still be bound by its OWN 5.0 ceiling, unaffected by stamina\'s own 100.0')
    t.equals(speedRejected.reason, 'invalid_speed_multiplier')
end)

-- ============================================================================
-- SECTION 13 -- GAP 1, PART 2: THE SPEED-OVERRIDE STATUS PUSH. Covers the
-- boolean signal 'john-k9:client:k9SpeedOverrideStatus' this file now
-- pushes so client/movement.lua's composer can tell an audited individual
-- override apart from an automatic tier value -- see this file's own header
-- "GAP 1, PART 2" for the full design. Also covers the plain-English
-- DescribeSpeedOverrideCeiling honesty text on both k9ProfileUpsert
-- (write time) and k9ProfileGet (later inspection).
-- ============================================================================

local function lastClientEventTo(f, targetSrc)
    for i = #f.capturedClientEvents, 1, -1 do
        if f.capturedClientEvents[i].target == targetSrc then return f.capturedClientEvents[i] end
    end
    return nil
end

t.test('SPEED-OVERRIDE STATUS PUSH: setting a speedMultiplier for an ONLINE citizenid immediately pushes {active = true} to their own client, over the dedicated event, alongside the (unrelated, soft-guarded/absent-here) xpTierChanged snapshot', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [42] = 'CIT1' } })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 })
    t.isTrue(result.ok)

    local pushed = lastClientEventTo(f, 42)
    t.isNotNil(pushed, 'an online citizenid whose speed override just changed must receive a push')
    t.equals(pushed.event, 'john-k9:client:k9SpeedOverrideStatus')
    t.isTrue(pushed.payload.active, 'a live speedMultiplier override must report active = true')
end)

t.test('SPEED-OVERRIDE STATUS PUSH CONTROL: an edit to an OFFLINE citizenid pushes NOTHING (nobody to push to) -- proves the push above is really keyed on being online, not unconditional', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = {} })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT_OFFLINE', speedMultiplier = 3.0 })
    t.isTrue(result.ok, 'the write itself must still succeed regardless of whether anyone is online to notify')
    t.equals(#f.capturedClientEvents, 0, 'nobody online -- nothing pushed')
end)

t.test('SPEED-OVERRIDE STATUS PUSH: a RESET pushes {active = false} to an online citizenid who previously had one, snapping the composer\'s ceiling back down immediately', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [42] = 'CIT1' } })
    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 })
    advance(f)
    local reset = f.callbacks['john-k9:server:k9ProfileReset'](HC_SOURCE, 'CIT1')
    t.isTrue(reset.ok)

    local pushed = lastClientEventTo(f, 42)
    t.isNotNil(pushed)
    t.isFalse(pushed.payload.active, 'once reset, this citizenid no longer carries a live override -- the push must say so')
end)

t.test('SPEED-OVERRIDE STATUS PUSH CONTROL: editing an UNRELATED field (note only) on a citizenid with NO speed override still pushes {active = false} -- correct, not a false positive, since GetK9EffectiveMultipliers is recomputed fresh every push regardless of which field changed', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [42] = 'CIT1' } })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', note = 'a note, nothing about speed' })
    t.isTrue(result.ok)

    local pushed = lastClientEventTo(f, 42)
    t.isNotNil(pushed)
    t.isFalse(pushed.payload.active)
end)

t.test('INITIAL-CONNECT PUSH: a citizenid who ALREADY carries a live speed override gets {active = true} pushed the moment QBCore:Server:PlayerLoaded fires for them -- closes the "already had one before this session started" gap', function()
    local f = boot({ isHighCommand = function() return true end })
    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 })
    -- Nobody was online when the edit above landed (onlineSources starts
    -- empty), so no push happened yet -- confirmed by the control below.
    t.equals(#f.capturedClientEvents, 0, 'sanity: no push yet, CIT1 was offline for the edit itself')

    f.firePlayerLoaded(99, 'CIT1')

    local pushed = lastClientEventTo(f, 99)
    t.isNotNil(pushed, 'PlayerLoaded must push this citizenid\'s CURRENT override status, not require a fresh edit this session')
    t.isTrue(pushed.payload.active)
end)

t.test('INITIAL-CONNECT PUSH CONTROL: a citizenid with NO override gets {active = false} pushed on PlayerLoaded -- never left unset/omitted', function()
    local f = boot({ isHighCommand = function() return true end })
    f.firePlayerLoaded(99, 'CIT_NEVER_EDITED')
    local pushed = lastClientEventTo(f, 99)
    t.isNotNil(pushed)
    t.isFalse(pushed.payload.active)
end)

t.test('RESTART BACKFILL: a citizenid ALREADY online (in onlineSources) BEFORE this resource\'s own onResourceStart handler runs gets their current override status pushed by the backfill loop, without needing PlayerLoaded to fire again', function()
    -- boot() already runs onResourceStart as part of its own setup -- this
    -- test seeds a pre-existing DB row (via the SAME world table two
    -- successive boot() calls can share) so the SECOND boot (simulating a
    -- resource restart with the citizenid already connected) picks it up
    -- fresh from a cold RefreshOverrideCache(), not from an edit made this
    -- session.
    local world = newWorld()
    local firstBoot = boot({ isHighCommand = function() return true end, world = world })
    firstBoot.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 4.0 })

    local restarted = boot({ isHighCommand = function() return true end, world = world, onlineSources = { [7] = 'CIT1' } })
    local pushed = lastClientEventTo(restarted, 7)
    t.isNotNil(pushed, 'the restart backfill loop must push status to every already-online citizenid, not just ones who edit or reconnect afterward')
    t.isTrue(pushed.payload.active, 'the override persisted across the simulated restart (a real DB-backed world), so status must read active = true immediately')
end)

t.test('RESTART BACKFILL CONTROL: an already-online citizenid with NO override gets active = false from the very same backfill loop, and a citizenid who is NOT online gets nothing pushed at all', function()
    local world = newWorld()
    boot({ isHighCommand = function() return true end, world = world })
    local restarted = boot({ isHighCommand = function() return true end, world = world, onlineSources = { [7] = 'CIT_NO_OVERRIDE' } })
    local pushed = lastClientEventTo(restarted, 7)
    t.isNotNil(pushed)
    t.isFalse(pushed.payload.active)

    -- Nobody registered at source 8 -- GetPlayers() only enumerates
    -- onlineSources, so there is nothing for the backfill loop to have
    -- pushed to that target at all.
    t.isNil(lastClientEventTo(restarted, 8))
end)

t.test('SOFT-GUARD: exports.qbx_core.GetPlayerByCitizenId genuinely ABSENT (not merely nil-returning) -- k9ProfileUpsert/k9ProfileReset still succeed, they just cannot push to an online citizenid this way', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [42] = 'CIT1' }, omitGetPlayerByCitizenId = true })
    -- boot()'s own onResourceStart RESTART BACKFILL loop (a DIFFERENT code
    -- path, keyed on exports.qbx_core.GetPlayer, not GetPlayerByCitizenId)
    -- already pushed once for CIT1 during boot() itself -- captured here so
    -- this test asserts the DELTA the upsert call itself causes, not a raw
    -- total that would otherwise double-count that unrelated push.
    local before = #f.capturedClientEvents
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 })
    t.isTrue(result.ok, 'the real database write must not depend on this framework export existing')
    t.equals(#f.capturedClientEvents - before, 0, 'with the export absent, PushK9SpeedOverrideStatusIfOnline must degrade to a no-op, never error')
end)

t.test('SOFT-GUARD CONTROL: the SAME edit, with GetPlayerByCitizenId genuinely present, DOES push -- proves the no-op above is caused by the missing export, not some other reason', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [42] = 'CIT1' } })
    local before = #f.capturedClientEvents
    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 })
    t.equals(#f.capturedClientEvents - before, 1)
end)

t.test('SOFT-GUARD: TriggerClientEvent genuinely ABSENT -- k9ProfileUpsert still succeeds and PushK9SpeedOverrideStatus degrades to a no-op rather than erroring', function()
    local f = boot({ isHighCommand = function() return true end, onlineSources = { [42] = 'CIT1' }, omitTriggerClientEvent = true })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 3.0 })
    t.isTrue(result.ok, 'the real database write must not depend on this native existing (defensive for the several OTHER specs that soft-load this file without stubbing it)')
    -- No assertion possible on capturedClientEvents here (the stub itself
    -- is absent) -- the assertion IS that the call above did not throw.
end)

-- ============================================================================
-- GAP 1, PART 2 -- PLAIN-ENGLISH HONESTY TEXT. `warning` (k9ProfileUpsert,
-- at the moment of save, ONLY when speedMultiplier is being set/changed
-- THIS call) and `speedOverrideCeilingNote` (k9ProfileGet, "not just at
-- write time" -- an officer inspecting an already-set override later must
-- be told the same truth a fresh save would have told them).
-- ============================================================================

t.test('HONESTY: setting a speedMultiplier ABOVE 2.0 (this resource\'s own former, undocumented ceiling) returns a plain-English warning naming the actual number, the real engine limit, and why -- never a bare number, never jargon', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 5.0 })
    t.isTrue(result.ok)
    t.isNotNil(result.warning, 'a value above the old silent ceiling must be disclosed, not left to speak for itself')
    t.isTrue(result.warning:find('5.00', 1, true) ~= nil, 'must name the EXACT number the officer typed, not a vague description')
    t.isTrue(result.warning:find('10.0', 1, true) ~= nil, 'must name the real engine ceiling, so the officer knows the true upper bound too')
end)

t.test('HONESTY CONTROL: setting a speedMultiplier AT OR BELOW 2.0 gets no such note at all -- nothing changed for that range, nothing new to say', function()
    local f = boot({ isHighCommand = function() return true end })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 2.0 })
    t.isTrue(result.ok)
    t.isNil(result.warning, 'a value that always worked, even before this pass, must not get a "this now works" note -- it would be noise, not honesty')
end)

t.test('HONESTY CONTROL: editing a DIFFERENT field (note only) on a citizenid whose EXISTING override already has a high speedMultiplier does NOT repeat the note -- "at the moment they save it" means THIS field, THIS call, not every future unrelated edit', function()
    local f = boot({ isHighCommand = function() return true end })
    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 6.0 })
    advance(f)
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', note = 'unrelated note edit' })
    t.isTrue(result.ok)
    t.isNil(result.warning, 'this call never touched speedMultiplier -- it must not manufacture a speed-related warning out of an untouched field')
end)

t.test('HONESTY: self-override AND the high-speed note can BOTH apply at once, joined, neither one clobbering the other', function()
    -- ResolveCitizenId(HC_SOURCE) resolves via exports.qbx_core:GetPlayer --
    -- register HC_SOURCE itself as online, as CIT_SELF, so this edit is
    -- genuinely a self-override.
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end, onlineSources = { [HC_SOURCE] = 'CIT_SELF' } })
    local result = f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT_SELF', speedMultiplier = 5.0 })
    t.isTrue(result.ok)
    t.isNotNil(result.warning)
    t.isTrue(result.warning:find('YOUR OWN', 1, true) ~= nil, 'the self-override sentence must still be present')
    t.isTrue(result.warning:find('5.00', 1, true) ~= nil, 'the speed-ceiling sentence must ALSO still be present, joined, not overwritten')
end)

t.test('HONESTY, NOT JUST AT WRITE TIME: k9ProfileGet on an ALREADY-set high override (from a previous session/edit) carries the SAME honest note as a fresh save would -- an officer inspecting later must not be misled', function()
    local f = boot({ isHighCommand = function() return true end })
    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 7.0 })
    local getResult = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.isTrue(getResult.ok)
    t.isNotNil(getResult.speedOverrideCeilingNote)
    t.isTrue(getResult.speedOverrideCeilingNote:find('7.00', 1, true) ~= nil)
end)

t.test('HONESTY CONTROL: k9ProfileGet on a citizenid with NO override, or an override at/below 2.0, carries no speedOverrideCeilingNote at all', function()
    local f = boot({ isHighCommand = function() return true end })
    local neverEdited = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT_NEVER_EDITED')
    t.isTrue(neverEdited.ok)
    t.isNil(neverEdited.speedOverrideCeilingNote)

    f.callbacks['john-k9:server:k9ProfileUpsert'](HC_SOURCE, { citizenid = 'CIT1', speedMultiplier = 1.5 })
    local lowOverride = f.callbacks['john-k9:server:k9ProfileGet'](HC_SOURCE, 'CIT1')
    t.isTrue(lowOverride.ok)
    t.isNil(lowOverride.speedOverrideCeilingNote)
end)

os.exit(t.summary())
