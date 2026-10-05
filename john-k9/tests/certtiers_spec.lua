--[[
    tests/certtiers_spec.lua

    Tests server/certtiers.lua -- the owner-directed "high command can
    edit K9 cert tiers at runtime" pass -- against the REAL, unmodified
    production file, via tests/fixtures/sandbox.lua. Harness style mirrors
    tests/runtimecontrol_spec.lua closely: a fake in-memory table backing
    every SQL statement this file issues (k9_certification_tiers,
    k9_certification_tier_capabilities, k9_certification_tier_audit, plus
    a fake k9_certifications table for the reference-count check DeleteTier
    reads), mutated by the real production callbacks exactly like a real
    database would be. TWO BOOTS, ONE FAKE DATABASE, same as that spec's
    own pattern, is what proves persistence-across-restart.

    NOT COVERED HERE (disclosed, not silently skipped): the cross-file
    TierEditMutex race this pass closes between server/certtiers.lua's own
    DeleteTier and server/certifications/'s SetCertificationTier is not
    exercised by either this spec or tests/certifications_spec.lua -- doing
    so would need a real concurrent-coroutine harness interleaving two
    MySQL.await yield points across TWO loaded production files sharing one
    TierEditMutex instance, which neither existing harness in this
    directory currently supports. What IS covered: TierEditMutex exists,
    is a real mutex object (TryAcquire/Release/IsHeld), and this file's own
    single-actor mutation paths behave correctly in isolation.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @return table world
local function newWorld()
    return {
        tiers = {},          -- tier_key -> { label, ordinal, deleted, updated_by }
        capabilities = {},   -- array of { tier_key, capability_key, granted_by }
        audit = {},          -- array of { action, tier_key, detail, changed_by }
        certifications = {}, -- array of { tier } -- fake k9_certifications rows for the reference-count check
    }
end

--- @param world table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers', 1, true) then
            local out = {}
            for key, row in pairs(world.tiers) do
                out[#out + 1] = { tier_key = key, label = row.label, ordinal = row.ordinal, deleted = row.deleted }
            end
            return out
        elseif sql:find('SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?', 1, true) then
            local row = world.tiers[params[1]]
            if row then return { { deleted = row.deleted } } end
            return {}
        elseif sql:find('INSERT INTO k9_certification_tiers', 1, true) then
            local key, label, ordinal, updatedBy = params[1], params[2], params[3], params[4]
            -- DEFECT-2 TEST HOOK: `world.throwOnTierOrdinalWrite` (a set of
            -- tier_key strings), when present, makes ONLY the
            -- Tier_UpdateOrdinal-shaped call (certTiersReorder's own write --
            -- distinguished from Tier_Upsert's write by the absence of
            -- `label = VALUES(label)` in its own ON DUPLICATE KEY UPDATE
            -- clause, see server/datastore.lua's own Tier_UpdateOrdinal doc
            -- comment) throw for a chosen key, simulating exactly the DB
            -- blip K9Store's own SafeWrite contract degrades to `false` --
            -- never a Tier_Upsert call (certTiersUpsert's own create/rename
            -- path), so tests can freely create/rename tiers before
            -- exercising a reorder-only failure.
            if world.throwOnTierOrdinalWrite and world.throwOnTierOrdinalWrite[key]
                and not sql:find('label = VALUES(label)', 1, true) then
                error('certtiers_spec test stub: simulated Tier_UpdateOrdinal failure for ' .. tostring(key))
            end
            local deletedLiteral = sql:find('VALUES (?, ?, ?, 1, ?)', 1, true) and 1 or 0
            world.tiers[key] = { label = label, ordinal = ordinal, deleted = deletedLiteral, updated_by = updatedBy }
            return {}
        elseif sql:find('SELECT tier_key, capability_key FROM k9_certification_tier_capabilities', 1, true) then
            local out = {}
            for _, row in ipairs(world.capabilities) do
                out[#out + 1] = { tier_key = row.tier_key, capability_key = row.capability_key }
            end
            return out
        elseif sql:find('SELECT capability_key FROM k9_certification_tier_capabilities WHERE tier_key = ?', 1, true) then
            local out = {}
            for _, row in ipairs(world.capabilities) do
                if row.tier_key == params[1] then out[#out + 1] = { capability_key = row.capability_key } end
            end
            return out
        elseif sql:find('INSERT INTO k9_certification_tier_capabilities', 1, true) then
            -- DEFECT-1 TEST HOOK: `world.throwOnCapabilityInsert` (a set of
            -- capability_key strings), when present, makes TierCap_Insert
            -- throw for a chosen capability key -- TierCap_Insert's own
            -- pcall turns that into `return false`, exactly the SafeWrite
            -- contract this hook exists to exercise.
            if world.throwOnCapabilityInsert and world.throwOnCapabilityInsert[params[2]] then
                error('certtiers_spec test stub: simulated TierCap_Insert failure for ' .. tostring(params[2]))
            end
            world.capabilities[#world.capabilities + 1] = { tier_key = params[1], capability_key = params[2], granted_by = params[3] }
            return {}
        elseif sql:find('DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND capability_key = ?', 1, true) then
            -- DEFECT-1 TEST HOOK, removal side: `world.throwOnCapabilityDelete`
            -- (a set of capability_key strings), when present, makes
            -- TierCap_Delete throw for a chosen capability key, the same way
            -- `world.throwOnCapabilityInsert` does for TierCap_Insert above.
            if world.throwOnCapabilityDelete and world.throwOnCapabilityDelete[params[2]] then
                error('certtiers_spec test stub: simulated TierCap_Delete failure for ' .. tostring(params[2]))
            end
            for i = #world.capabilities, 1, -1 do
                local row = world.capabilities[i]
                if row.tier_key == params[1] and row.capability_key == params[2] then
                    table.remove(world.capabilities, i)
                end
            end
            return {}
        elseif sql:find('INSERT INTO k9_certification_tier_audit', 1, true) then
            world.audit[#world.audit + 1] = { action = params[1], tier_key = params[2], detail = params[3], changed_by = params[4] }
            return {}
        end
        error('certtiers_spec test stub: unhandled MySQL.query.await SQL: ' .. tostring(sql))
    end
end

--- @param world table
local function makeScalarAwait(world)
    return function(sql, params)
        if sql:find('SELECT COUNT(*) FROM k9_certifications WHERE tier = ?', 1, true) then
            local count = 0
            for _, row in ipairs(world.certifications) do
                if row.tier == params[1] then count = count + 1 end
            end
            return count
        end
        error('certtiers_spec test stub: unhandled MySQL.scalar.await SQL: ' .. tostring(sql))
    end
end

--- @param opts table? -- { world, config, isHighCommand }
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

    local playersBySource = opts.playersBySource or {}
    local exportsStub = { qbx_core = { GetPlayer = function(_self, src) return playersBySource[src] end } }

    local isHighCommand = opts.isHighCommand or function() return false end

    local defaultConfig = {
        CertificationTiers = opts.certificationTiers or {
            { key = 'trainee',   label = 'Trainee',   ordinal = 1, capabilities = {} },
            { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} },
            { key = 'senior',    label = 'Senior',    ordinal = 3, capabilities = {} },
        },
    }
    local config = opts.config or defaultConfig

    local fakeNow = { value = 0 }
    local envOverrides = {
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        print                  = printStub,
        lib                    = lib,
        exports                = exportsStub,
        MySQL                  = { query = { await = makeQueryAwait(world) }, scalar = { await = makeScalarAwait(world) } },
        IsHighCommand          = isHighCommand,
        Config                 = config,
    }
    -- TierCapabilityPermits' own soft dependency on
    -- server/certifications/'s GetCertificationTier -- OMITTED from
    -- envOverrides entirely (not merely nil) unless a test explicitly
    -- supplies one via opts.getCertificationTier, so
    -- `type(GetCertificationTier) == 'function'` inside the production
    -- file genuinely sees it as absent, exactly like a real server
    -- running this file without server/certifications/ loaded.
    -- TIER-BYPASS-ON-EXPIRY FIX: TierCapabilityPermits now calls
    -- GetCertificationTier(citizenid, jobName, true) (the 3-argument form)
    -- rather than adding a second global -- opts.getCertificationTier's own
    -- stub is free to inspect that 3rd argument itself (see SECTION 10
    -- below) to distinguish a STALE (expired) tier assignment from a
    -- NEVER-TIERED one within a single stub function, exactly like the
    -- real production accessor does.
    if opts.getCertificationTier then
        envOverrides.GetCertificationTier = opts.getCertificationTier
    end
    -- server/permissions.lua's IsHighCommandBypassCitizenId -- "high command
    -- automatically gets every k9 upgrade" pass. Same OMITTED-unless-supplied
    -- soft-dependency treatment as GetCertificationTier immediately above:
    -- a real server always has server/permissions.lua loaded, but this spec
    -- exercises TierCapabilityPermits' own `type(...) == 'function'` guard
    -- deliberately, and lets a test drive the bypass directly (a plain
    -- citizenid -> boolean stub, exactly the same shape the real function
    -- has) without needing to boot server/permissions.lua/server/highcommand.lua
    -- for real just to prove this file's OWN consumption of it.
    if opts.isHighCommandBypassCitizenId then
        envOverrides.IsHighCommandBypassCitizenId = opts.isHighCommandBypassCitizenId
    end
    -- server/equipmentshop.lua's CountEquipmentShopItemsRequiringTier --
    -- the SECOND thing that can point at a tier. OMITTED from envOverrides
    -- entirely (not merely nil) unless a test supplies one, for exactly the
    -- same reason as GetCertificationTier immediately above: the production
    -- file's own `type(fn) == 'function'` guard must genuinely see it as
    -- absent, the way a real server would while server/certtiers.lua is
    -- still loading (fxmanifest.lua loads equipmentshop.lua after it).
    if opts.countShopItemsRequiringTier then
        envOverrides.CountEquipmentShopItemsRequiringTier = opts.countShopItemsRequiringTier
    end
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)

    -- server/datastore.lua -- REAL, unmodified, loaded alongside (that
    -- file's own header: "the ONLY place in this resource that may name a
    -- `k9_*` table or call `MySQL.*` directly" -- server/certtiers.lua's
    -- own local SafeQuery/SafeWrite helpers, plus its one raw
    -- `MySQL.scalar.await` reference-count read, are gone; every read/write
    -- below now goes through K9Store.Tier_*/TierCap_*/TierAudit_Append/
    -- Cert_CountByTier instead). Config.Database is deliberately absent
    -- from this fixture's `config`/`defaultConfig` tables above --
    -- K9Store's own DatabaseEnabled() fails safe to `true` (real-DB mode)
    -- on a missing Config.Database, which is exactly what makes every
    -- K9Store call below run the SAME MySQL.query.await/MySQL.scalar.await
    -- call (against this file's own makeQueryAwait(world)/
    -- makeScalarAwait(world) stubs, assigned as env.MySQL above) that this
    -- file's removed SafeQuery/SafeWrite/raw-scalar call sites issued
    -- directly before this migration -- so every existing SQL-substring
    -- dispatch branch in makeQueryAwait/makeScalarAwait above keeps
    -- matching, unchanged, since every new K9Store accessor mirrors that
    -- exact SQL text verbatim (see server/datastore.lua's own new
    -- "k9_certification_tiers / ..." section for the byte-for-byte
    -- comparison).
    --
    -- Discard anything server/datastore.lua printed on its way up before
    -- loading the file under test -- that file legitimately prints ONE
    -- boot line saying which backend it is using, which is not
    -- server/certtiers.lua's own output (mirrors tests/equipmentshop_spec.lua's
    -- own identical precedent).
    Sandbox.loadInto('../server/datastore.lua', env)
    for i = #printedLines, 1, -1 do printedLines[i] = nil end

    Sandbox.loadInto('../server/certtiers.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return { env = env, world = world, callbacks = callbacks, printedLines = printedLines, fakeNow = fakeNow }
end

--- @param fixture table
--- @param key string
--- @return table? -- the tier entry from a fresh certTiersList call, or nil
local function findTier(fixture, hcSource, key)
    local result = fixture.callbacks['john-k9:server:certTiersList'](hcSource)
    for _, tier in ipairs(result.tiers) do
        if tier.key == key then return tier end
    end
    return nil
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

-- ============================================================================
-- SECTION 1 -- registration + HAZARD 1 (existing rows / zero-behavior-change
-- default).
-- ============================================================================

t.test('registration: all four callbacks are registered', function()
    local f = boot()
    for _, name in ipairs({
        'john-k9:server:certTiersList', 'john-k9:server:certTiersUpsert',
        'john-k9:server:certTiersReorder', 'john-k9:server:certTiersDelete',
    }) do
        t.isNotNil(f.callbacks[name], name .. ' must always be registered')
    end
end)

t.test('HAZARD 1: default catalog (no tablet edit ever made) keeps the three legacy keys at ordinals 1/2/3 with empty capabilities', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersList'](HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(#result.tiers, 3)
    t.equals(result.tiers[1].key, 'trainee')
    t.equals(result.tiers[1].ordinal, 1)
    t.equals(result.tiers[2].key, 'certified')
    t.equals(result.tiers[2].ordinal, 2)
    t.equals(result.tiers[3].key, 'senior')
    t.equals(result.tiers[3].ordinal, 3)
    t.isNil(next(result.tiers[2].capabilities), 'certified must ship with zero capabilities by default')
end)

t.test('HAZARD 1: GetCertificationTierOrdinal/IsKnownCertificationTierKey resolve the legacy keys with no tablet edit ever made', function()
    local f = boot()
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'))
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 1)
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 2)
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 3)
    t.isFalse(f.env.IsKnownCertificationTierKey('made_up_tier'))
end)

t.test('HAZARD 1: a malformed Config.CertificationTiers (missing \'certified\') falls back to the built-in legacy defaults, never crashes', function()
    local f = boot({ config = { CertificationTiers = { { key = 'foo', label = 'Foo', ordinal = 1, capabilities = {} } } } })
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'), 'must still resolve certified via the hardcoded fallback')
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 2)
end)

-- ============================================================================
-- SECTION 2 -- AUTHORIZATION (HAZARD 4): every one of the four callbacks
-- re-verifies IsHighCommand(source) server-side, including the read-only
-- list.
-- ============================================================================

t.test('AUTHORIZATION: certTiersList denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersList'](NON_HC_SOURCE)
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('SHAPE: certTiersUpsert refuses a label that is empty, non-string, or past the VARCHAR(60) column', function()
    -- FOUND BY MUTATION TESTING (2026-08-31): deleting IsValidTierLabel's
    -- `len == 0 or len > 60` line left the whole suite green. The existing
    -- tests here all pass a well-formed label, so the length bound itself
    -- was never exercised -- the same "strong on behaviour, weak on shape"
    -- pattern the previous two mutation rounds found elsewhere.
    --
    -- Both ends are observable. `label` is VARCHAR(60) NOT NULL in
    -- sql/install.sql, so an over-long label is a truncation or a write
    -- error; and an EMPTY label is worse than a rejected one, because it
    -- writes a rank whose name renders as blank everywhere it appears --
    -- the tablet's tier list, the roster, and every certification row.
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })

    for _, bad in ipairs({ '', 123, true, {} }) do
        -- Advance past CERT_TIER_ACTION_COOLDOWN_MS between attempts, or the
        -- second onward come back 'rate_limited' and this test would be
        -- asserting the cooldown instead of the label check. (That is exactly
        -- what the first draft did.)
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
            key = 'shapecheck', label = bad, capabilities = {},
        })
        t.isFalse(result.ok,
            ('a %s label must be refused, not written'):format(bad == '' and 'empty' or type(bad)))
        t.equals(result.reason, 'invalid_label',
            ('a %s label must refuse as invalid_label'):format(bad == '' and 'empty' or type(bad)))
    end

    -- 61 characters: one past what the column can hold.
    f.fakeNow.value = f.fakeNow.value + 2000
    local tooLong = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'shapecheck', label = string.rep('L', 61), capabilities = {},
    })
    t.isFalse(tooLong.ok, 'a 61-character label exceeds label VARCHAR(60) and must be refused before the write')
    t.equals(tooLong.reason, 'invalid_label')

    -- CONTROL: exactly 60 is legal and must still be accepted, so this test
    -- pins the boundary rather than just "long strings are bad".
    f.fakeNow.value = f.fakeNow.value + 2000
    local atLimit = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'shapecheck', label = string.rep('L', 60), capabilities = {},
    })
    t.isTrue(atLimit.ok, 'exactly 60 characters fits the column and must be accepted')
end)

t.test('AUTHORIZATION: certTiersUpsert denies a non-high-command source even with a well-formed payload', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersUpsert'](NON_HC_SOURCE, { key = 'master', label = 'Master', capabilities = {} })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.isFalse(f.env.IsKnownCertificationTierKey('master'), 'a denied caller must never actually create the tier')
end)

t.test('AUTHORIZATION: certTiersReorder and certTiersDelete both deny a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local reorderResult = f.callbacks['john-k9:server:certTiersReorder'](NON_HC_SOURCE, { 'senior', 'certified', 'trainee' })
    t.isFalse(reorderResult.ok)
    t.equals(reorderResult.reason, 'denied')
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 1, 'a denied reorder must not touch any ordinal')

    local deleteResult = f.callbacks['john-k9:server:certTiersDelete'](NON_HC_SOURCE, 'trainee')
    t.isFalse(deleteResult.ok)
    t.equals(deleteResult.reason, 'denied')
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'), 'a denied delete must not tombstone anything')
end)

t.test('AUTHORIZATION: server-side re-check ignores whatever the caller claims -- IsHighCommand alone decides, never a payload flag', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    -- A forged payload trying to smuggle its own authorization claim
    -- changes nothing -- CanManageCertTiers never reads the payload at all.
    local result = f.callbacks['john-k9:server:certTiersUpsert'](NON_HC_SOURCE, { key = 'master', label = 'Master', isHighCommand = true, ok = true })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

-- ============================================================================
-- SECTION 3 -- ADD A ROLE / EDIT PERMISSIONS (the owner's literal ask).
-- ============================================================================

t.test('ADD A ROLE: a brand-new tier is appended at the end of the ordinal list, with only catalog capabilities accepted', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'master', label = 'Master Handler', capabilities = { 'advanced_tracking', 'mentor_trainees' },
    })
    t.isTrue(result.ok)
    local masterTier = findTier(f, HC_SOURCE, 'master')
    t.isNotNil(masterTier)
    t.equals(masterTier.ordinal, 4, 'a new tier is appended after ordinal 3 (senior)')
    t.isTrue(masterTier.capabilities.advanced_tracking)
    t.isTrue(masterTier.capabilities.mentor_trainees)
    t.equals(f.env.GetCertificationTierOrdinal('master'), 4)
end)

t.test('EDIT PERMISSIONS: toggling capabilities on an already-live tier never touches its ordinal', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })
    local seniorTier = findTier(f, HC_SOURCE, 'senior')
    t.equals(seniorTier.ordinal, 3, 'editing capabilities must not move the ordinal')
    t.isTrue(seniorTier.capabilities.bite_hold_and_takedown)
    t.isTrue(f.env.TierHasCapability('senior', 'bite_hold_and_takedown'))

    -- Re-upsert with an EMPTY capability set revokes the one just granted.
    -- fakeNow advanced past CERT_TIER_ACTION_COOLDOWN_MS so this second
    -- call from the SAME officer is not itself rejected as rate_limited.
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = {} })
    t.isFalse(f.env.TierHasCapability('senior', 'bite_hold_and_takedown'))
end)

t.test('EDIT PERMISSIONS: an unrecognized capability key rejects the WHOLE request -- the fixed catalog is closed (HAZARD 4)', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'master', label = 'Master', capabilities = { 'become_high_command' },
    })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_capabilities')
    t.isFalse(f.env.IsKnownCertificationTierKey('master'), 'the whole upsert must be refused, not partially applied')
end)

t.test('RENAME: an existing tier\'s label can change while its key (the load-bearing identity) stays fixed', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'certified', label = 'Standard Handler', capabilities = {} })
    local certifiedTier = findTier(f, HC_SOURCE, 'certified')
    t.equals(certifiedTier.label, 'Standard Handler')
    t.equals(certifiedTier.ordinal, 2, 'renaming must never change the ordinal')
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'), 'the KEY must remain \'certified\' -- this is what k9_certifications.tier rows reference')
end)

t.test('VALIDATION: an invalid tier key (uppercase/too long/empty) is rejected before any write', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'Master', '', 'x', 'has spaces', string.rep('a', 40) }) do
        -- Advance past the cooldown before EVERY attempt in this loop --
        -- otherwise the second+ attempt would report 'rate_limited'
        -- (correct production behavior: the cooldown is consumed before
        -- payload validation, mirroring server/runtimecontrol.lua's own
        -- ordering) rather than exercising this test's own 'invalid_key'
        -- assertion.
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = badKey, label = 'X', capabilities = {} })
        t.isFalse(result.ok, 'key ' .. tostring(badKey) .. ' must be rejected')
        t.equals(result.reason, 'invalid_key')
    end
end)

-- ============================================================================
-- SECTION 4 -- HAZARD 2: a deleted tier with rows still pointing at it.
-- ============================================================================

t.test('HAZARD 2: deleting a tier with zero referencing k9_certifications rows succeeds and tombstones it', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isTrue(result.ok)
    t.isFalse(f.env.IsKnownCertificationTierKey('trainee'), 'a deleted tier must disappear from the live catalog')
    t.equals(#result.tiers, 2, 'the response reflects the post-delete catalog immediately')
end)

t.test('HAZARD 2: deleting a tier with at least one referencing k9_certifications row is REFUSED, never silently reassigned', function()
    local world = newWorld()
    world.certifications = { { tier = 'trainee' } }
    local f = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isFalse(result.ok)
    t.equals(result.reason, 'tier_in_use')
    t.equals(result.referenceCount, 1)
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'), 'a refused delete must leave the tier fully intact')
end)

-- ----------------------------------------------------------------------
-- HAZARD 2, SECOND REFERRER. Certifications were the only thing counted.
-- A supply shop item can also require a tier, and deleting a tier an item
-- requires does not fail loudly -- it makes that item unbuyable for every
-- player on the server, forever, with the refusal naming a tier that no
-- longer exists and can never be granted to anybody. Nothing told the
-- officer doing the deleting, and nothing in the shop said why it had
-- stopped selling something.
-- ----------------------------------------------------------------------

t.test('HAZARD 2 (SHOP): deleting a tier that a supply shop item still requires is REFUSED, with its own distinct reason and the item named', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        countShopItemsRequiringTier = function(tierKey)
            if tierKey == 'trainee' then return 2, { 'k9_vest', 'k9_medkit' } end
            return 0, {}
        end,
    })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isFalse(result.ok)
    t.equals(result.reason, 'tier_in_use_by_shop_items',
        'a separate reason from tier_in_use on purpose -- the two send the person to completely different screens')
    t.equals(result.referenceCount, 2)
    t.equals(result.shopItemKeys[1], 'k9_vest')
    t.equals(result.shopItemKeys[2], 'k9_medkit')
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'), 'a refused delete must leave the tier fully intact')
end)

t.test('HAZARD 2 (SHOP): the refusal names the blocking items in the console too, so an operator can act on it without the tablet open', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        countShopItemsRequiringTier = function() return 1, { 'k9_vest' } end,
    })
    f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')

    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('REFUSED to delete tier trainee', 1, true) and line:find('k9_vest', 1, true) then found = true end
    end
    t.isTrue(found, 'naming the tier but not the items would leave them hunting through the whole shop')
end)

t.test('HAZARD 2 (SHOP): a tier NO shop item requires still deletes normally -- the new check must not block ordinary deletes', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        countShopItemsRequiringTier = function() return 0, {} end,
    })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isTrue(result.ok)
    t.isFalse(f.env.IsKnownCertificationTierKey('trainee'))
end)

t.test('HAZARD 2 (SHOP): certifications are checked FIRST -- a tier blocked by both reports the certification refusal, which is the one that must be cleared first', function()
    local world = newWorld()
    world.certifications = { { tier = 'trainee' } }
    local f = boot({
        world = world,
        isHighCommand = function(src) return src == HC_SOURCE end,
        countShopItemsRequiringTier = function() return 3, { 'a', 'b', 'c' } end,
    })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isFalse(result.ok)
    t.equals(result.reason, 'tier_in_use')
    t.equals(result.referenceCount, 1, 'the two counts must never be added together -- one number covering both would be meaningless')
end)

t.test('HAZARD 2 (SHOP): server/equipmentshop.lua not loaded at all is a skipped check, never an error -- the delete behaves exactly as it did before this existed', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end }) -- countShopItemsRequiringTier deliberately absent from the env
    t.isNil(f.env.CountEquipmentShopItemsRequiringTier)
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isTrue(result.ok)
end)

t.test('HAZARD 2 (SHOP): a THROWING counter is a skipped check, never a delete that errors out halfway with the tier mutex still held', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        countShopItemsRequiringTier = function() error('simulated equipmentshop failure', 0) end,
    })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')
    t.isTrue(result.ok, 'a broken referrer check must never strand the tier editor')

    -- The mutex really was released: a second, unrelated edit still works.
    local second = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'senior')
    t.isTrue(second.ok or second.reason == 'rate_limited', 'whatever the outcome, it must not be "busy" -- that would mean a leaked lock')
end)

t.test('HAZARD 2: \'certified\' can NEVER be deleted, even with zero referencing rows -- unconditional protection independent of reference count', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end }) -- fresh world, zero k9_certifications rows at all
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'certified')
    t.isFalse(result.ok)
    t.equals(result.reason, 'protected_tier')
    t.isTrue(f.env.IsKnownCertificationTierKey('certified'))
end)

t.test('HAZARD 2: deleting an unknown tier key is refused as unknown_tier, not a no-op success', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'never_existed')
    t.isFalse(result.ok)
    t.equals(result.reason, 'unknown_tier')
end)

t.test('RESTORE: re-adding a deleted (tombstoned) key un-deletes it, appended at a NEW end-of-list ordinal, not its old position', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee') -- ordinal 1, now tombstoned
    t.isFalse(f.env.IsKnownCertificationTierKey('trainee'))

    f.fakeNow.value = f.fakeNow.value + 2000 -- past the same-officer cooldown from the delete above
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'trainee', label = 'Trainee', capabilities = {} })
    t.isTrue(result.ok)
    t.isTrue(f.env.IsKnownCertificationTierKey('trainee'))
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 4, 'a restore is appended after the current max (certified=2, senior=3 -- trainee itself is excluded while tombstoned, so max+1 = 4), never reclaiming its old ordinal 1')
end)

-- ============================================================================
-- SECTION 5 -- HAZARD 3: reordering.
-- ============================================================================

t.test('HAZARD 3: a full, valid reorder succeeds, reassigns sequential ordinals, and returns a non-empty retroactive-rerank warning', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee', 'certified' })
    t.isTrue(result.ok)
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 1)
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 2)
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 3)
    t.isTrue(type(result.warning) == 'string' and #result.warning > 0, 'a successful reorder must always carry a non-empty warning string')
    t.contains(result.warning:lower(), 'retroactiv')
end)

t.test('HAZARD 3: a PARTIAL reorder (missing a known key) is refused outright -- no ordinal is touched', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee' }) -- missing 'certified'
    t.isFalse(result.ok)
    t.equals(result.reason, 'must_include_every_tier')
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 1, 'refused reorder must leave every ordinal exactly as it was')
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 3)
end)

t.test('HAZARD 3: a reorder listing an unknown key is refused as invalid_key_set', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee', 'certified', 'made_up' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key_set')
end)

t.test('HAZARD 3: a reorder listing the same key twice is refused (duplicate), never silently deduped', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersReorder'](HC_SOURCE, { 'senior', 'senior', 'certified' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key_set')
end)

-- ============================================================================
-- SECTION 6 -- persistence across a restart (mirrors
-- tests/runtimecontrol_spec.lua's own two-boot pattern).
-- ============================================================================

t.test('PERSISTENCE: a tablet-added tier, a rename, and a delete all survive a resource restart via the shared fake database', function()
    local world = newWorld()
    local first = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    first.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'master', label = 'Master', capabilities = { 'advanced_tracking' } })
    first.fakeNow.value = first.fakeNow.value + 2000
    first.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'certified', label = 'Standard Handler', capabilities = {} })
    first.fakeNow.value = first.fakeNow.value + 2000
    first.callbacks['john-k9:server:certTiersDelete'](HC_SOURCE, 'trainee')

    local second = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(second.env.IsKnownCertificationTierKey('master'), 'the custom tier must survive a restart')
    t.equals(second.env.GetCertificationTierOrdinal('master'), 4)
    t.isTrue(second.env.TierHasCapability('master', 'advanced_tracking'))
    local certifiedTier = findTier(second, HC_SOURCE, 'certified')
    t.equals(certifiedTier.label, 'Standard Handler', 'the rename must survive a restart')
    t.isFalse(second.env.IsKnownCertificationTierKey('trainee'), 'the deletion (tombstone) must survive a restart, never silently un-delete')
end)

-- ============================================================================
-- SECTION 7 -- rate limiting (anti-fat-finger, mirrors
-- server/runtimecontrol.lua's own RuntimeControlActionCooldown pattern).
-- ============================================================================

t.test('RATE LIMIT: a second mutating call from the same officer inside the cooldown window is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local first = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'master', label = 'Master', capabilities = {} })
    t.isTrue(first.ok)
    local second = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'master2', label = 'Master 2', capabilities = {} })
    t.isFalse(second.ok)
    t.equals(second.reason, 'rate_limited')
    t.isFalse(f.env.IsKnownCertificationTierKey('master2'))
end)

t.test('RATE LIMIT: is per-OFFICER, not global -- a different high-command officer is unaffected', function()
    local OTHER_HC_SOURCE = 300
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE or src == OTHER_HC_SOURCE end })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'master', label = 'Master', capabilities = {} })
    local result = f.callbacks['john-k9:server:certTiersUpsert'](OTHER_HC_SOURCE, { key = 'elite', label = 'Elite', capabilities = {} })
    t.isTrue(result.ok, 'a different officer\'s own action must not be blocked by the first officer\'s cooldown')
end)

-- ============================================================================
-- SECTION 8 -- HAZARD 4: the mutex primitive this pass introduces exists
-- and behaves as a real mutex (the cross-file race it closes is exercised
-- indirectly via server/certifications/'s own SetCertificationTier
-- soft-dependency guard, covered in tests/certifications_spec.lua, which
-- passes with TierEditMutex entirely ABSENT from that spec's sandbox --
-- proving the soft-dependency fallback works when this file is not
-- loaded at all).
-- ============================================================================

t.test('HAZARD 4: TierEditMutex is a real mutex object exposed as a bare global', function()
    local f = boot()
    t.equals(type(f.env.TierEditMutex), 'table')
    t.isTrue(f.env.TierEditMutex.TryAcquire('trainee'))
    t.isFalse(f.env.TierEditMutex.TryAcquire('trainee'), 'a second acquire of the same key while held must fail')
    f.env.TierEditMutex.Release('trainee')
    t.isTrue(f.env.TierEditMutex.TryAcquire('trainee'), 'released, then re-acquirable')
end)

-- ============================================================================
-- SECTION 9 -- CAPABILITY COMPOSITION: TierCapabilityPermits (this pass's
-- owner-directed follow-up: "wire the capabilities to something real").
-- See server/certtiers.lua's own header "CAPABILITY COMPOSITION" for the
-- full rule this section proves. Every case is driven through
-- TierCapabilityPermits itself -- its own internal "is this capability
-- active anywhere" check is a `local` helper with no life of its own
-- outside that function (deliberately not a second new resource-global --
-- see that function's own doc comment), so this spec verifies it only
-- through the one real public contract a consumer would actually call,
-- never by reaching around it. `opts.getCertificationTier` (this file's
-- own extension to boot(), above) stands in for server/certifications/'s
-- real GetCertificationTier -- production code never runs with that file
-- absent in a shipped install, but this spec exercises this file's OWN
-- soft-dependency fallback deliberately, the same discipline
-- tests/certifications_spec.lua already applies to TierEditMutex's
-- absence in the other direction.
-- ============================================================================

t.test('COMPOSITION: DORMANT by default -- zero-behavior-change on every pre-this-pass install, for every tier including trainee', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return 'trainee' end,
    })
    -- None of the three default tiers ship with any capability granted
    -- (HAZARD 1) -- 'trainee' (the lowest tier, the exact one the owner's
    -- own example names -- "a trainee tier to not allow bite-and-hold")
    -- must still be ALLOWED, because nobody has ever used the tablet to
    -- grant or deny this capability to anyone.
    t.isTrue(f.env.TierCapabilityPermits('CIT1', 'police', 'bite_hold_and_takedown'))
end)

t.test('COMPOSITION: an unrecognized capability key is allowed unconditionally, regardless of tier', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function() return 'trainee' end,
    })
    t.isTrue(f.env.TierCapabilityPermits('CIT1', 'police', 'not_a_real_capability'))
end)

t.test('COMPOSITION: once a tier is granted a capability, it goes ACTIVE resource-wide -- a tier that lacks it is now genuinely denied -- the owner\'s own worked example', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    -- High command grants bite_hold_and_takedown to 'certified' and
    -- 'senior' only -- 'trainee' is deliberately left without it, exactly
    -- the scenario named in this pass's own task ("set a trainee tier to
    -- not allow bite-and-hold").
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'certified', label = 'Certified', capabilities = { 'bite_hold_and_takedown' } })
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    f.env.GetCertificationTier = function(_citizenid, _jobName) return 'trainee' end
    t.isFalse(f.env.TierCapabilityPermits('TRAINEE_CIT', 'police', 'bite_hold_and_takedown'),
        'a trainee-tier handler must be genuinely denied once the capability is active and trainee does not hold it')
end)

t.test('COMPOSITION: once ACTIVE, a tier that HOLDS the capability is genuinely allowed', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    f.env.GetCertificationTier = function(_citizenid, _jobName) return 'senior' end
    t.isTrue(f.env.TierCapabilityPermits('SENIOR_CIT', 'police', 'bite_hold_and_takedown'),
        'a senior-tier handler holding the now-active capability must be allowed')
end)

t.test('COMPOSITION: revoking the capability from every tier that held it returns to DORMANT -- allowed again for everyone', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })
    f.env.GetCertificationTier = function(_citizenid, _jobName) return 'trainee' end
    t.isFalse(f.env.TierCapabilityPermits('TRAINEE_CIT', 'police', 'bite_hold_and_takedown'), 'active, and trainee does not hold it')

    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = {} })
    t.isTrue(f.env.TierCapabilityPermits('TRAINEE_CIT', 'police', 'bite_hold_and_takedown'),
        'dormant again once the only tier holding it has it revoked -- trainee is allowed again, same as before anyone ever touched the tablet')
end)

t.test('COMPOSITION: allows when the acting citizenid\'s tier cannot be resolved at all (nil), even while the capability is active', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return nil end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    -- e.g. K9 access reached via a 'k9.access' permission grant or a
    -- high-command bypass, with no matching certification record at all --
    -- HasK9Access can independently be true here; this file cannot express
    -- that citizenid as any tier, so it must never be the reason they are
    -- denied.
    t.isTrue(f.env.TierCapabilityPermits('NO_CERT_CIT', 'police', 'bite_hold_and_takedown'))
end)

t.test('COMPOSITION: allows when GetCertificationTier is entirely absent (soft dependency, server/certifications/ not loaded)', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end }) -- no getCertificationTier supplied
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })
    t.isNil(f.env.GetCertificationTier, 'this test\'s own sandbox genuinely has no GetCertificationTier defined')

    t.isTrue(f.env.TierCapabilityPermits('ANY_CIT', 'police', 'bite_hold_and_takedown'))
end)

t.test('COMPOSITION: allows on a malformed citizenid/jobName rather than erroring or denying', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function() error('must never be reached for a bad-shaped input') end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isTrue(f.env.TierCapabilityPermits(nil, 'police', 'bite_hold_and_takedown'))
    t.isTrue(f.env.TierCapabilityPermits('CIT1', nil, 'bite_hold_and_takedown'))
    t.isTrue(f.env.TierCapabilityPermits(42, 'police', 'bite_hold_and_takedown'))
end)

t.test('COMPOSITION: activating one capability never affects a DIFFERENT, still-dormant capability', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function() return 'trainee' end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })
    t.isTrue(f.env.TierCapabilityPermits('CIT1', 'police', 'specializations_eligible'),
        'a sibling capability nobody has touched stays dormant independently, so it still permits unconditionally')
end)

-- ============================================================================
-- SECTION 9b -- HIGH COMMAND BYPASS (owner-directed "high command
-- automatically gets every k9 upgrade" pass). Proves TierCapabilityPermits'
-- own new IsHighCommandBypassCitizenId consultation, via a plain stub (see
-- boot()'s own opts.isHighCommandBypassCitizenId doc comment above) --
-- never the real server/permissions.lua/server/highcommand.lua, exactly
-- like `opts.getCertificationTier` stands in for GetCertificationTier
-- immediately above.
-- ============================================================================

t.test('HIGH COMMAND BYPASS: satisfies an active capability the citizenid\'s own real tier does not grant', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return 'trainee' end, -- real, active, job-matching cert -- trainee does NOT hold this capability
        isHighCommandBypassCitizenId = function(citizenid, _jobName) return citizenid == 'HC-OFFICER' end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    -- Control: an ordinary trainee-tier officer is genuinely denied once the
    -- capability is active -- unaffected by this pass.
    t.isFalse(f.env.TierCapabilityPermits('ORDINARY_TRAINEE', 'police', 'bite_hold_and_takedown'))

    -- The high-command officer holds the SAME trainee-tier certification
    -- (getCertificationTier answers identically for both citizenids) and
    -- has never earned 'bite_hold_and_takedown' either -- yet is permitted,
    -- because they are high command right now.
    t.isTrue(f.env.TierCapabilityPermits('HC-OFFICER', 'police', 'bite_hold_and_takedown'),
        'high command must be granted a tier capability their own real, active certification tier does not carry')
end)

t.test('HIGH COMMAND BYPASS: job-scoped -- a citizenid who is high command of a DIFFERENT job does not borrow that status here', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return 'trainee' end,
        -- Stub answers true only when the JOB matches 'ambulance' -- proving
        -- TierCapabilityPermits passes its own `jobName` argument through as
        -- `expectedJobName`, never just the citizenid alone.
        isHighCommandBypassCitizenId = function(citizenid, jobName) return citizenid == 'HC-OFFICER' and jobName == 'ambulance' end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isFalse(f.env.TierCapabilityPermits('HC-OFFICER', 'police', 'bite_hold_and_takedown'),
        'high command of "ambulance" must not bypass a capability check scoped to "police"')
end)

t.test('HIGH COMMAND BYPASS: an OFFLINE citizenid (or one who is simply not high command) gets no bypass at all -- real resolution, unaffected', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return 'trainee' end,
        isHighCommandBypassCitizenId = function(_citizenid, _jobName) return false end, -- mirrors the real function's own offline/not-high-command answer
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isFalse(f.env.TierCapabilityPermits('OFFLINE_OR_NOT_HC', 'police', 'bite_hold_and_takedown'))
end)

t.test('HIGH COMMAND BYPASS: soft dependency -- allows exactly as before when IsHighCommandBypassCitizenId is entirely absent (server/permissions.lua not loaded)', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return 'trainee' end,
        -- no isHighCommandBypassCitizenId supplied at all
    })
    t.isNil(f.env.IsHighCommandBypassCitizenId, 'this test\'s own sandbox genuinely has no IsHighCommandBypassCitizenId defined')
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isFalse(f.env.TierCapabilityPermits('ANY_CIT', 'police', 'bite_hold_and_takedown'),
        'with the bypass function entirely absent, resolution falls straight through to the real tier check, unaffected')
end)

t.test('HIGH COMMAND BYPASS: never consulted at all while the capability is DORMANT -- pure floor, changes nothing about the "allow by default" story', function()
    local calls = 0
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName) return 'trainee' end,
        isHighCommandBypassCitizenId = function(citizenid, jobName) calls = calls + 1; return citizenid == 'HC-OFFICER' end,
    })
    -- No certTiersUpsert call at all this test -- 'bite_hold_and_takedown' stays DORMANT.
    t.isTrue(f.env.TierCapabilityPermits('HC-OFFICER', 'police', 'bite_hold_and_takedown'))
    t.equals(calls, 0, 'IsCapabilityActiveInternal\'s own early return must short-circuit before ever reaching the high-command bypass')
end)

-- ============================================================================
-- SECTION 10 -- TIER-BYPASS-ON-EXPIRY FIX (coder-security, red-team finding):
-- GetCertificationTier(citizenid, jobName) folds "expired" into "no tier"
-- for every OTHER consumer (correctly). TierCapabilityPermits used to be
-- the ONE place that collapse was WRONG: it called that same 2-argument
-- form, so it treated "expired" exactly like "genuinely never tiered" --
-- a citizenid who kept K9 access via the 'k9.access' permission grant /
-- autoAccessGrade / high-command bypass (HasK9Access's other three routes)
-- silently regained any capability withheld from their now-stale tier the
-- instant their certification lapsed -- no exploitation needed, ordinary
-- certification lifecycle produced it. FIXED: TierCapabilityPermits now
-- calls the 3-argument form, GetCertificationTier(citizenid, jobName,
-- true), which distinguishes "a real, active, job-matching row exists but
-- is stale" from "no such row exists at all" using the underlying cache's
-- own independent `active`/`expired` flags (see that accessor's own doc
-- comment, server/certifications/). These tests drive
-- TierCapabilityPermits with a SINGLE getCertificationTier stub that
-- itself branches on the 3rd argument, exactly mirroring what the real
-- production accessor does for an expired-but-still-K9-accessible handler.
-- ============================================================================

t.test('EXPIRY FIX: a STALE (expired) tier assignment is evaluated for real -- denied when the active capability excludes it', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        -- A real, active, job-matching row assigned 'trainee' -- it has
        -- simply expired. The 2-arg form (every OTHER consumer) folds that
        -- into nil; only `includeExpired = true` still resolves it.
        getCertificationTier = function(_citizenid, _jobName, includeExpired)
            if includeExpired then return 'trainee' end
            return nil
        end,
    })
    -- High command withholds bite-and-hold from trainee (grants it to
    -- certified/senior only) -- the exact scenario the red-team finding
    -- names: a rookie's certification expires while their K9 access is kept
    -- alive by some other route, and they must NOT silently regain this.
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'certified', label = 'Certified', capabilities = { 'bite_hold_and_takedown' } })

    t.isFalse(f.env.TierCapabilityPermits('EXPIRED_TRAINEE_CIT', 'police', 'bite_hold_and_takedown'),
        'an expired trainee-tier assignment must still be denied a capability trainee never held -- expiry must not silently unlock it')
end)

t.test('EXPIRY FIX: a STALE (expired) tier assignment that DOES hold the active capability is still allowed', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(_citizenid, _jobName, includeExpired)
            if includeExpired then return 'senior' end
            return nil
        end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isTrue(f.env.TierCapabilityPermits('EXPIRED_SENIOR_CIT', 'police', 'bite_hold_and_takedown'),
        'a stale tier that DOES hold the capability must still be allowed -- expiry only narrows, it never invents a NEW denial')
end)

t.test('EXPIRY FIX: NEVER-TIERED (no certification row at all -- never certified for this job, or manually revoked) stays allowed, distinct from STALE', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        -- No certification row for this citizenid/job at all, regardless of
        -- `includeExpired` -- there is nothing to be "stale". This is the
        -- population reached via a 'k9.access' permission grant, an
        -- autoAccessGrade job grade, or high command, with no certification
        -- record of their own ever -- HasK9Access's other three routes.
        getCertificationTier = function(_citizenid, _jobName, _includeExpired) return nil end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isTrue(f.env.TierCapabilityPermits('NEVER_CERTIFIED_CIT', 'police', 'bite_hold_and_takedown'),
        'someone who never held a certification (or was manually revoked) for this job has nothing to resolve a tier from -- must stay allowed, unlike the stale case above')
end)

t.test('EXPIRY FIX: GetCertificationTier is called with includeExpired=true, not the bare 2-argument form', function()
    local capturedArgs
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function(citizenid, jobName, includeExpired)
            capturedArgs = { citizenid, jobName, includeExpired }
            return nil
        end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    f.env.TierCapabilityPermits('CIT1', 'police', 'bite_hold_and_takedown')

    t.equals(capturedArgs[1], 'CIT1')
    t.equals(capturedArgs[2], 'police')
    t.isTrue(capturedArgs[3], 'must pass includeExpired=true so a stale (expired) tier assignment is still resolved, never folded into "no tier"')
end)

t.test('EXPIRY FIX: GetCertificationTier is never called at all for a malformed citizenid/jobName, includeExpired or not', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        getCertificationTier = function() error('must never be reached for a bad-shaped input') end,
    })
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })

    t.isTrue(f.env.TierCapabilityPermits(nil, 'police', 'bite_hold_and_takedown'))
    t.isTrue(f.env.TierCapabilityPermits('CIT1', nil, 'bite_hold_and_takedown'))
end)

-- ============================================================================
-- SECTION 11 -- PARTIAL-WRITE DEFECTS (audit-confirmed): certTiersUpsert's
-- capability reconciliation loop and certTiersReorder's per-key ordinal
-- write both used to discard K9Store.TierCap_Insert/TierCap_Delete/
-- Tier_UpdateOrdinal's own `@return boolean ok` (the SafeWrite contract --
-- a thrown DB error degrades to `false` rather than propagating, see
-- tests/datastore_spec.lua's own "SafeWrite contract" pin), so a mid-loop
-- DB blip left the mutation partially applied while the caller still
-- received a bare `ok = true` and an audit trail claiming the full
-- REQUESTED change, not what actually landed.
-- ============================================================================

t.test('DEFECT 1: certTiersUpsert reports failure, not a bare ok = true, when a capability INSERT throws mid-loop', function()
    local world = newWorld()
    world.throwOnCapabilityInsert = { specializations_eligible = true }
    local f = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })

    -- Two brand-new capabilities requested on a brand-new tier -- one
    -- (specializations_eligible) is rigged to throw on its own INSERT.
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'master', label = 'Master', capabilities = { 'advanced_tracking', 'specializations_eligible' },
    })

    t.isFalse(result.ok, 'a mid-loop capability write failure must never be reported as a bare ok = true')
    t.equals(result.reason, 'capability_write_failed')
    t.isNotNil(result.failedCapabilities)
    t.equals(#result.failedCapabilities.added, 1)
    t.equals(result.failedCapabilities.added[1], 'specializations_eligible', 'the response must name exactly what failed')

    -- The returned catalog reflects what ACTUALLY landed, not the fully
    -- requested set: Tier_Upsert itself succeeded (the tier row exists),
    -- advanced_tracking's own insert succeeded, but
    -- specializations_eligible's did not.
    local masterTier = findTier(f, HC_SOURCE, 'master')
    t.isNotNil(masterTier, 'the tier row itself is unaffected by a capability-only failure')
    t.isTrue(masterTier.capabilities.advanced_tracking, 'the capability whose write succeeded must be reflected as granted')
    t.isNil(masterTier.capabilities.specializations_eligible, 'the capability whose write failed must NOT be reflected as granted')
    t.isTrue(f.env.TierHasCapability('master', 'advanced_tracking'))
    t.isFalse(f.env.TierHasCapability('master', 'specializations_eligible'))

    -- The audit trail records only what actually succeeded, never the
    -- full intended request.
    local lastAudit = world.audit[#world.audit]
    t.equals(lastAudit.action, 'tier_create')
    t.contains(lastAudit.detail, 'capabilities_added=[advanced_tracking]')
    t.notContains(lastAudit.detail, 'specializations_eligible', 'the audit must not claim a capability that never actually landed')

    -- The mutex must never be left held after a mid-loop failure.
    t.isTrue(f.env.TierEditMutex.TryAcquire('master'), 'the mutex must be released even after a capability write failure')
    f.env.TierEditMutex.Release('master')
end)

t.test('DEFECT 1: certTiersUpsert reports failure when a capability DELETE (revocation) throws mid-loop', function()
    local world = newWorld()
    local f = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })

    -- First, successfully grant two capabilities to 'senior'.
    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'senior', label = 'Senior', capabilities = { 'advanced_tracking', 'bite_hold_and_takedown' },
    })
    t.isTrue(f.env.TierHasCapability('senior', 'advanced_tracking'))
    t.isTrue(f.env.TierHasCapability('senior', 'bite_hold_and_takedown'))

    -- Now request removing BOTH -- rig bite_hold_and_takedown's own DELETE
    -- to throw, so only advanced_tracking's removal actually lands.
    world.throwOnCapabilityDelete = { bite_hold_and_takedown = true }
    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = {} })

    t.isFalse(result.ok, 'a mid-loop capability revocation failure must never be reported as a bare ok = true')
    t.equals(result.reason, 'capability_write_failed')
    t.equals(#result.failedCapabilities.removed, 1)
    t.equals(result.failedCapabilities.removed[1], 'bite_hold_and_takedown')

    -- Reflects DB truth: advanced_tracking was actually revoked,
    -- bite_hold_and_takedown's revocation never landed and it is STILL
    -- granted.
    t.isFalse(f.env.TierHasCapability('senior', 'advanced_tracking'), 'the removal that succeeded must be reflected')
    t.isTrue(f.env.TierHasCapability('senior', 'bite_hold_and_takedown'), 'the removal that failed must leave the capability still granted, never silently dropped')

    t.isTrue(f.env.TierEditMutex.TryAcquire('senior'), 'the mutex must be released even after a revocation failure')
    f.env.TierEditMutex.Release('senior')
end)

t.test('DEFECT 2: certTiersReorder reports failure when an ordinal write throws after a successful mutex acquire', function()
    local world = newWorld()
    local f = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })

    world.throwOnTierOrdinalWrite = { senior = true }
    local result = f.callbacks['john-k9:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee', 'certified' })

    t.isFalse(result.ok, 'a genuine post-acquire DB write failure must never be reported as a bare ok = true')
    t.equals(result.reason, 'ordinal_write_failed')
    t.isNotNil(result.failedKeys)
    t.equals(#result.failedKeys, 1)
    t.equals(result.failedKeys[1], 'senior', 'the response must name exactly which key failed to write')

    -- senior's ordinal must reflect its REAL, unchanged value (3) -- the
    -- write never actually landed, so it must never be reported/left as
    -- the intended new position (1).
    t.equals(f.env.GetCertificationTierOrdinal('senior'), 3, 'a failed ordinal write must leave the real ordinal untouched')
    -- The two keys whose writes DID succeed actually moved.
    t.equals(f.env.GetCertificationTierOrdinal('trainee'), 2)
    t.equals(f.env.GetCertificationTierOrdinal('certified'), 3)

    -- The existing retroactive-ranking warning must still be present
    -- alongside the new failure signal.
    t.isTrue(type(result.warning) == 'string' and #result.warning > 0, 'the warning must still be surfaced even on failure')
    t.contains(result.warning:lower(), 'retroactiv')

    -- The mutex for the failed key must never be left held.
    t.isTrue(f.env.TierEditMutex.TryAcquire('senior'), 'the mutex must be released even after a write failure')
    f.env.TierEditMutex.Release('senior')
end)

t.test('DEFECT 2: a busy-skip (lock contention) alone remains ok = true -- unchanged, pre-existing, disclosed behavior, distinct from a genuine write failure', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.env.TierEditMutex.TryAcquire('trainee') -- simulate a concurrent in-flight edit holding the lock
    local result = f.callbacks['john-k9:server:certTiersReorder'](HC_SOURCE, { 'senior', 'trainee', 'certified' })
    t.isTrue(result.ok, 'a busy-skip alone must not fail the whole reorder response -- only a genuine DB write failure should')
    f.env.TierEditMutex.Release('trainee')
end)

-- ============================================================================
-- SECTION 12 -- SELF-SERVICE VISIBILITY (economy red-team follow-up,
-- coder-security pass). HAZARD 4 already establishes there is no privilege-
-- escalation shape here (CAPABILITY_CATALOG cannot grant a permission or
-- become high command) -- these tests cover a DIFFERENT property: granting
-- or revoking a capability on the tier the ACTING OFFICER currently holds
-- themselves must be named distinctly in both the audit trail and the
-- response, never indistinguishable from an ordinary, unrelated tier edit.
-- ============================================================================

t.test('SELF-TIER CAPABILITY EDIT: granting a capability to the tier the acting officer currently holds is flagged distinctly in both the audit and the response', function()
    local world = newWorld()
    local f = boot({
        world = world,
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = {
            [HC_SOURCE] = { PlayerData = { citizenid = 'CHIEF1', job = { name = 'police' } } },
        },
        getCertificationTier = function(citizenid, jobName, _includeExpired)
            if citizenid == 'CHIEF1' and jobName == 'police' then return 'senior' end
            return nil
        end,
    })

    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' },
    })
    t.isTrue(result.ok, tostring(result.reason))
    t.isNotNil(result.warning, 'granting a capability to your OWN currently-held tier must be disclosed in the response, not silently applied')
    t.contains(result.warning, 'senior')

    t.equals(#world.audit, 1)
    t.contains(world.audit[1].detail, 'SELF-TIER CAPABILITY EDIT')
    t.contains(world.audit[1].detail, 'CHIEF1')
end)

t.test('SELF-TIER CAPABILITY EDIT: editing a DIFFERENT tier than the one the acting officer holds is NOT flagged', function()
    local world = newWorld()
    local f = boot({
        world = world,
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = {
            [HC_SOURCE] = { PlayerData = { citizenid = 'CHIEF1', job = { name = 'police' } } },
        },
        getCertificationTier = function(_citizenid, _jobName) return 'senior' end,
    })

    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'trainee', label = 'Trainee', capabilities = { 'advanced_tracking' },
    })
    t.isTrue(result.ok, tostring(result.reason))
    t.isNil(result.warning, 'editing a tier the officer does NOT themselves hold must not manufacture a self-tier warning')
    t.notContains(world.audit[1].detail, 'SELF-TIER')
end)

t.test('SELF-TIER CAPABILITY EDIT: a REVOKE from the officer\'s own tier is exactly as visible in the audit trail as the original grant', function()
    local world = newWorld()
    local f = boot({
        world = world,
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = {
            [HC_SOURCE] = { PlayerData = { citizenid = 'CHIEF1', job = { name = 'police' } } },
        },
        getCertificationTier = function(_citizenid, _jobName) return 'senior' end,
    })

    f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = { 'bite_hold_and_takedown' } })
    f.fakeNow.value = f.fakeNow.value + 2000
    local revoke = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, { key = 'senior', label = 'Senior', capabilities = {} })

    t.isTrue(revoke.ok, tostring(revoke.reason))
    t.isNotNil(revoke.warning, 'revoking a capability from your own tier must be disclosed exactly like the original grant was')
    t.equals(#world.audit, 2)
    t.contains(world.audit[2].detail, 'SELF-TIER CAPABILITY EDIT')
end)

t.test('SELF-TIER CAPABILITY EDIT: still flagged when the request PARTIALLY fails -- the marker reflects what actually succeeded, not the full request', function()
    local world = newWorld()
    world.throwOnCapabilityInsert = { specializations_eligible = true }
    local f = boot({
        world = world,
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = {
            [HC_SOURCE] = { PlayerData = { citizenid = 'CHIEF1', job = { name = 'police' } } },
        },
        getCertificationTier = function(_citizenid, _jobName) return 'senior' end,
    })

    -- advanced_tracking succeeds; specializations_eligible is rigged to
    -- throw -- both targeted at 'senior', the officer's own tier.
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'senior', label = 'Senior', capabilities = { 'advanced_tracking', 'specializations_eligible' },
    })
    t.isFalse(result.ok, 'a mid-loop capability write failure must still be reported as a failure, self-tier or not')
    t.equals(result.reason, 'capability_write_failed')
    t.isNotNil(result.warning, 'the self-tier warning must still be surfaced on a partial failure -- what DID succeed still affected the officer\'s own tier')

    -- The audit record is written on this partial failure (not skipped),
    -- names only what actually succeeded, and still carries the SELF-TIER
    -- marker because advanced_tracking's grant to 'senior' genuinely landed.
    t.equals(#world.audit, 1, 'an audit row must be written even when the request partially fails')
    t.contains(world.audit[1].detail, 'SELF-TIER CAPABILITY EDIT')
    t.contains(world.audit[1].detail, 'capabilities_added=[advanced_tracking]')
    t.notContains(world.audit[1].detail, 'specializations_eligible', 'the audit must not claim a capability that never actually landed')
end)

t.test('SELF-TIER CAPABILITY EDIT: never flagged when the acting officer\'s own tier cannot be resolved (soft dependency, no GetCertificationTier loaded)', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    -- No getCertificationTier stub supplied at all -- production code must
    -- degrade exactly like server/certifications/ not being loaded,
    -- never error, matching this file's own established soft-dependency
    -- convention (SECTION 9's own "allows when GetCertificationTier is
    -- entirely absent" case).
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'senior', label = 'Senior', capabilities = { 'advanced_tracking' },
    })
    t.isTrue(result.ok, tostring(result.reason))
    t.isNil(result.warning)
end)

t.test('SELF-TIER CAPABILITY EDIT: legitimate equivalent still works -- an ordinary capability grant to an unrelated tier completes cleanly with no self-service noise', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:certTiersUpsert'](HC_SOURCE, {
        key = 'trainee', label = 'Trainee', capabilities = { 'advanced_tracking' },
    })
    t.isTrue(result.ok, tostring(result.reason))
    t.isNil(result.warning)
    t.isTrue(f.env.TierHasCapability('trainee', 'advanced_tracking'))
end)

os.exit(t.summary())
