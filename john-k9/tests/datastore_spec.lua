--[[
    tests/datastore_spec.lua

    Tests server/datastore.lua -- the single database accessor layer behind
    Config.Database.enabled -- against the REAL, unmodified production file.

    THE WHOLE POINT OF THIS SPEC, so it doesn't get read as "just another
    CRUD test": server/datastore.lua exists so a server can run with
    `Config.Database.enabled = false` and never touch a database at all,
    while still keeping every certification/XP/partnership/permission/
    runtime-override/tablet-theme/K9-appearance check working for the life
    of the process. A spec that only ever exercises the MySQL branch proves
    NOTHING about that promise -- see PART 2 below, which deliberately loads
    this file into a sandbox with NO `MySQL` global defined AT ALL, so any
    accidental reference to it (a bug that left a stray `if
    DatabaseEnabled()` branch swapped, or a table function that forgot its
    own guard) is a hard Lua error ("attempt to index a nil value") rather
    than a silent pass.

    THREE PARTS:
      PART 1 -- MYSQL BRANCH. A capture-based fake MySQL (records the exact
        SQL text and bound params, returns a canned value) proves each
        function forwards to the right oxmysql method with the right
        arguments, and that a thrown MySQL-mode error propagates unchanged
        (this resource's callers already pcall around every K9Store.*
        call exactly like they pcall a raw MySQL.*.await today -- see
        datastore.lua's own header "CONTRACT DISCIPLINE").
      PART 2 -- MEMORY BRANCH, NO MySQL GLOBAL AT ALL. Exercises the
        invariants the owner's requirement demands directly: fail-closed on
        a miss, at-most-one-active-row uniqueness (including partnerships'
        TWO independent uniqueness dimensions), a bounded k9_search_log
        ring buffer that never grows past its cap, and the exact
        `{ errno = 1062 }` shape every existing `IsDuplicateKeyError`
        helper elsewhere in this resource already recognizes.
      PART 3 -- PARITY. The identical sequence of calls against BOTH a
        fresh MySQL-mode fixture (backed by a tiny fake relational table,
        not just a capture stub) and a fresh memory-mode fixture must reach
        the identical externally-observable outcome -- proving the two
        backends do not merely both "work" in isolation, but agree.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- PART 1 -- MySQL branch (capture-based fake, Config.Database.enabled = true)
-- ----------------------------------------------------------------------

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
        single = { await = record('single') },
        query  = { await = record('query') },
        insert = { await = record('insert') },
        update = { await = record('update') },
    }
end

local mysqlEnv = Sandbox.newEnv({
    Config = { Database = { enabled = true } },
    MySQL = capturingMySQL(),
    print = function(...) end,
})
Sandbox.loadInto('../server/datastore.lua', mysqlEnv)
local MysqlStore = mysqlEnv.K9Store

t.isNotNil(MysqlStore, 'server/datastore.lua must define global K9Store')
t.isTrue(mysqlEnv.K9Store.IsDatabaseEnabled(), 'IsDatabaseEnabled must reflect Config.Database.enabled = true')

t.test('MySQL branch: Cert_GetActiveId forwards to MySQL.scalar.await with the real SQL/params and passes the value through', function()
    resetCapture()
    canned = 77
    local id = MysqlStore.Cert_GetActiveId('CIT1', 'police')
    t.equals(id, 77)
    t.equals(#captured, 1)
    t.equals(captured[1].kind, 'scalar')
    t.contains(captured[1].sql, 'FROM k9_certifications')
    t.contains(captured[1].sql, 'active = 1')
    t.equals(captured[1].params[1], 'CIT1')
    t.equals(captured[1].params[2], 'police')
end)

t.test('MySQL branch: Cert_Insert with an expiry uses DATE_ADD, without one omits it entirely', function()
    resetCapture()
    canned = 5
    MysqlStore.Cert_Insert('CIT1', 'police', 'GRANTER1', 90)
    t.contains(captured[1].sql, 'DATE_ADD(NOW(), INTERVAL ? DAY)')
    t.equals(captured[1].params[4], 90)

    resetCapture()
    canned = 6
    MysqlStore.Cert_Insert('CIT2', 'police', 'GRANTER1', nil)
    t.notContains(captured[1].sql, 'DATE_ADD')
    t.equals(#captured[1].params, 3)
end)

t.test('MySQL branch: a thrown insert error propagates to the caller unchanged (the existing pcall-at-call-site contract)', function()
    resetCapture()
    canned = { throw = { errno = 1062, message = 'ER_DUP_ENTRY' } }
    local ok, err = pcall(MysqlStore.Cert_Insert, 'CIT1', 'police', 'G', nil)
    t.isFalse(ok)
    t.equals(err.errno, 1062, 'the real oxmysql-shaped error object must reach the caller exactly as thrown, not be swallowed or rewrapped')
end)

t.test('MySQL branch: Partner_Insert forwards k9/handler/establishedBy in the documented column order', function()
    resetCapture()
    canned = 9
    MysqlStore.Partner_Insert('K9CIT', 'HANDLERCIT', 'HANDLERCIT')
    t.equals(captured[1].params[1], 'K9CIT')
    t.equals(captured[1].params[2], 'HANDLERCIT')
    t.equals(captured[1].params[3], 'HANDLERCIT')
end)

t.test('MySQL branch: PairProgress_UpsertHighestTenureTier/GetHighestTenureTier forward the real SQL/params -- the fully durable half of the partnership-tenure anti-farm guard (migration 0018, server/partnership.lua\'s CaptureTenureSeedForPair)', function()
    resetCapture()
    canned = 1
    MysqlStore.PairProgress_UpsertHighestTenureTier('K9CIT', 'HANDLERCIT', 2)
    t.equals(captured[1].kind, 'insert')
    t.contains(captured[1].sql, 'INSERT INTO k9_partnership_pair_progress')
    t.contains(captured[1].sql, 'ON DUPLICATE KEY UPDATE highest_tenure_tier_granted = GREATEST(highest_tenure_tier_granted, VALUES(highest_tenure_tier_granted))')
    t.equals(captured[1].params[1], 'K9CIT')
    t.equals(captured[1].params[2], 'HANDLERCIT')
    t.equals(captured[1].params[3], 2)

    resetCapture()
    canned = 3
    local tier = MysqlStore.PairProgress_GetHighestTenureTier('K9CIT', 'HANDLERCIT')
    t.equals(tier, 3)
    t.equals(captured[1].kind, 'scalar')
    t.contains(captured[1].sql, 'FROM k9_partnership_pair_progress')
    t.equals(captured[1].params[1], 'K9CIT')
    t.equals(captured[1].params[2], 'HANDLERCIT')
end)

t.test('MySQL branch: XP_UpsertAdd sends the per-award DELTA, not a running total, via ON DUPLICATE KEY UPDATE', function()
    resetCapture()
    canned = 1
    MysqlStore.XP_UpsertAdd('CIT1', 25)
    t.contains(captured[1].sql, 'ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp)')
    t.equals(captured[1].params[2], 25)
end)

t.test('MySQL branch: Override_Upsert/Delete/OverrideAudit_Append never throw to the caller -- mirrors SafeWrite\'s own boolean contract', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Override_Upsert('feature:Recall', 'feature', 'false', 'CIT1'))
    canned = { throw = 'simulated write failure' }
    t.isFalse(MysqlStore.Override_Delete('feature:Recall'), 'a thrown DB error must degrade to false, never propagate raw, matching every SafeWrite call site this replaces')
end)

t.test('MySQL branch: NAME COLLISION REGRESSION -- Override_Upsert (k9_runtime_feature_overrides) and IndividualOverride_Upsert (k9_individual_overrides) are two DISTINCT functions, each hitting only its own table', function()
    -- Records an incident, not a hypothetical: an early draft of the
    -- per-individual-K9 override accessors (added the same pass as
    -- k9_individual_overrides/k9_individual_override_audit) reused the bare
    -- names `Override_Upsert`/`OverrideRows`/`OverrideAuditRows`/
    -- `OVERRIDE_AUDIT_MEMORY_CAP` already claimed by the PRE-EXISTING
    -- k9_runtime_feature_overrides subsystem immediately above (consumed by
    -- server/runtimecontrol.lua's runtimeSetFeature/runtimeSetTunable). Lua
    -- silently let the later top-level `function K9Store.Override_Upsert`
    -- overwrite the earlier one in the shared K9Store table, and the later
    -- `local OverrideRows = {}` shadow the earlier `local` of the same name
    -- -- every existing runtime-feature-override write would have silently
    -- landed on the wrong 5-argument signature (citizenid where a feature
    -- key was expected, a string dropped into a DOUBLE column) while still
    -- returning `true`, so the operator would have seen "saved" for a write
    -- that changed nothing real. Caught by QA before merge; this test is
    -- the automated backstop so it can never happen again silently -- see
    -- server/datastore.lua's own "NAMING" comment on the
    -- k9_individual_overrides section for the fix (every symbol there is
    -- now prefixed `IndividualOverride*`, never bare `Override*`).
    t.isTrue(MysqlStore.Override_Upsert ~= MysqlStore.IndividualOverride_Upsert,
        'K9Store.Override_Upsert and K9Store.IndividualOverride_Upsert must be two SEPARATE functions -- if this ever fails, one has silently overwritten the other again')
    t.isTrue(MysqlStore.Override_GetAll ~= MysqlStore.IndividualOverride_GetAllRows,
        'K9Store.Override_GetAll and K9Store.IndividualOverride_GetAllRows must be two SEPARATE functions')

    resetCapture()
    canned = {}
    MysqlStore.Override_Upsert('feature:Recall', 'feature', 'false', 'HC1')
    t.equals(#captured, 1)
    t.contains(captured[1].sql, 'k9_runtime_feature_overrides', 'the ORIGINAL runtime-feature-override writer must still target its own table')
    t.notContains(captured[1].sql, 'k9_individual_overrides')

    resetCapture()
    canned = {}
    MysqlStore.IndividualOverride_Upsert('CIT1', 1.1, 1.2, nil, 'note', 'HC1')
    t.equals(#captured, 1)
    t.contains(captured[1].sql, 'k9_individual_overrides', 'the per-individual-K9 override writer must target ITS OWN table')
    t.notContains(captured[1].sql, 'k9_runtime_feature_overrides')
end)

t.test('MySQL branch: IndividualOverride_Tombstone/IndividualOverrideAudit_Append never throw to the caller -- mirrors SafeWrite\'s own boolean contract', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.IndividualOverride_Tombstone('CIT1', 'HC1'))
    t.contains(captured[1].sql, 'k9_individual_overrides')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.IndividualOverrideAudit_Append('override_reset', 'CIT1', 'reset', 'HC1'))
    t.contains(captured[1].sql, 'k9_individual_override_audit')

    canned = { throw = 'simulated write failure' }
    t.isFalse(MysqlStore.IndividualOverride_Upsert('CIT1', 1.1, nil, nil, nil, 'HC1'), 'a thrown DB error must degrade to false, never propagate raw')
end)

t.test('MySQL branch: Appearance_GetRow mirrors GetAppearanceRow\'s own single-row-or-nil contract over a query.await array', function()
    resetCapture()
    canned = { { model = 'a_c_shepherd', original_model_hash = 123, active = 1 } }
    local row = MysqlStore.Appearance_GetRow('CIT1')
    t.equals(row.model, 'a_c_shepherd')
    resetCapture()
    canned = {}
    t.isNil(MysqlStore.Appearance_GetRow('CIT2'))
end)

t.test('MySQL branch: Cert_GetActiveJobsForCitizen forwards the real SQL/params, degrades to {} on a thrown error (SafeQuery contract)', function()
    resetCapture()
    canned = { { job = 'police', granted_by = 'G1' } }
    local rows = MysqlStore.Cert_GetActiveJobsForCitizen('CIT1')
    t.equals(#rows, 1)
    t.contains(captured[1].sql, 'FROM k9_certifications WHERE citizenid = ? AND active = 1')
    t.notContains(captured[1].sql, 'LIMIT')
    t.equals(captured[1].params[1], 'CIT1')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.equals(#MysqlStore.Cert_GetActiveJobsForCitizen('CIT1'), 0, 'a thrown error must degrade to {}, never propagate raw -- this is a SafeQuery-contract accessor, unlike a scalar mirror')
end)

t.test('MySQL branch: Cert_GetActiveRosterByJobUnordered embeds the server-computed LIMIT and issues NO ORDER BY (the filesort this accessor exists to avoid)', function()
    resetCapture()
    canned = { { citizenid = 'CIT1', granted_by = 'G1' } }
    local rows = MysqlStore.Cert_GetActiveRosterByJobUnordered('police', 250)
    t.equals(#rows, 1)
    t.contains(captured[1].sql, 'WHERE job = ? AND active = 1 LIMIT 250')
    t.notContains(captured[1].sql, 'ORDER BY', 'this accessor must never sort -- that is the whole point of NOT reusing Cert_GetActiveRosterByJob')
    t.equals(captured[1].params[1], 'police')
end)

t.test('MySQL branch: Cert_CountByTier mirrors MySQL.scalar.await DIRECTLY -- no active filter, and a thrown error propagates unchanged (NOT the SafeQuery contract)', function()
    resetCapture()
    canned = 3
    local count = MysqlStore.Cert_CountByTier('trainee')
    t.equals(count, 3)
    t.equals(captured[1].kind, 'scalar')
    t.contains(captured[1].sql, 'SELECT COUNT(*) FROM k9_certifications WHERE tier = ?')
    t.notContains(captured[1].sql, 'active', 'must count EVERY row, active or not -- see certtiers.lua\'s own HAZARD 2')

    resetCapture()
    canned = { throw = 'simulated failure' }
    local ok = pcall(MysqlStore.Cert_CountByTier, 'trainee')
    t.isFalse(ok, 'unlike every SafeQuery-contract accessor above, this one must propagate a thrown error to its caller unchanged -- certtiers.lua\'s own DeleteTier pcalls this itself, exactly like it pcalled a raw MySQL.scalar.await before this migration')
end)

t.test('MySQL branch: Tier_GetAllRows / Tier_GetDeletedFlagByKey forward correctly and degrade to {} on failure', function()
    resetCapture()
    canned = { { tier_key = 'master', label = 'Master', ordinal = 4, deleted = 0 } }
    t.equals(#MysqlStore.Tier_GetAllRows(), 1)
    t.contains(captured[1].sql, 'SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers')

    resetCapture()
    canned = { { deleted = 1 } }
    local rows = MysqlStore.Tier_GetDeletedFlagByKey('master')
    t.equals(rows[1].deleted, 1)
    t.contains(captured[1].sql, 'SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?')
    t.equals(captured[1].params[1], 'master')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.equals(#MysqlStore.Tier_GetDeletedFlagByKey('master'), 0)
end)

t.test('MySQL branch: Tier_Upsert writes label AND ordinal on conflict; Tier_UpdateOrdinal/Tier_Tombstone deliberately do NOT mention label in their own ON DUPLICATE KEY UPDATE clause', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Tier_Upsert('master', 'Master', 4, 'HC1'))
    t.contains(captured[1].sql, 'label = VALUES(label)')
    t.contains(captured[1].sql, 'ordinal = VALUES(ordinal)')
    t.contains(captured[1].sql, 'deleted = 0')
    t.equals(captured[1].params[1], 'master')
    t.equals(captured[1].params[2], 'Master')
    t.equals(captured[1].params[3], 4)
    t.equals(captured[1].params[4], 'HC1')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Tier_UpdateOrdinal('master', 'Master', 9, 'HC2'))
    t.notContains(captured[1].sql, 'label = VALUES(label)', 'a reorder write must never be able to overwrite label on an existing row -- see this function\'s own doc comment for the race this closes')
    t.contains(captured[1].sql, 'ordinal = VALUES(ordinal)')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.Tier_Tombstone('master', 'Master', 9, 'HC3'))
    t.contains(captured[1].sql, 'VALUES (?, ?, ?, 1, ?)', 'a tombstone write is a literal deleted=1 in the VALUES list, never a bound placeholder')
    t.notContains(captured[1].sql, 'label = VALUES(label)')
    t.notContains(captured[1].sql, 'ordinal = VALUES(ordinal)', 'a delete must never touch ordinal on an existing row either')
    t.contains(captured[1].sql, 'deleted = 1')
end)

t.test('MySQL branch: TierCap_GetAllRows/GetForTier/Insert/Delete forward the real SQL/params', function()
    resetCapture()
    canned = { { tier_key = 'master', capability_key = 'advanced_tracking' } }
    t.equals(#MysqlStore.TierCap_GetAllRows(), 1)
    t.contains(captured[1].sql, 'SELECT tier_key, capability_key FROM k9_certification_tier_capabilities')

    resetCapture()
    canned = { { capability_key = 'advanced_tracking' } }
    local rows = MysqlStore.TierCap_GetForTier('master')
    t.equals(rows[1].capability_key, 'advanced_tracking')
    t.contains(captured[1].sql, 'WHERE tier_key = ?')
    t.equals(captured[1].params[1], 'master')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.TierCap_Insert('master', 'advanced_tracking', 'HC1'))
    t.contains(captured[1].sql, 'INSERT INTO k9_certification_tier_capabilities')
    t.equals(captured[1].params[1], 'master')
    t.equals(captured[1].params[2], 'advanced_tracking')
    t.equals(captured[1].params[3], 'HC1')

    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.TierCap_Delete('master', 'advanced_tracking'))
    t.contains(captured[1].sql, 'DELETE FROM k9_certification_tier_capabilities WHERE tier_key = ? AND capability_key = ?')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.isFalse(MysqlStore.TierCap_Insert('master', 'advanced_tracking', 'HC1'), 'SafeWrite contract: a thrown error degrades to false, never propagates')
end)

t.test('MySQL branch: TierAudit_Append forwards the real SQL/params and never throws (SafeWrite contract)', function()
    resetCapture()
    canned = {}
    t.isTrue(MysqlStore.TierAudit_Append('tier_create', 'master', 'label=Master ordinal=4', 'HC1'))
    t.contains(captured[1].sql, 'INSERT INTO k9_certification_tier_audit')
    t.equals(captured[1].params[1], 'tier_create')
    t.equals(captured[1].params[2], 'master')
    t.equals(captured[1].params[4], 'HC1')

    resetCapture()
    canned = { throw = 'simulated failure' }
    t.isFalse(MysqlStore.TierAudit_Append('tier_create', 'master', 'x', 'HC1'))
end)

-- ----------------------------------------------------------------------
-- PART 2 -- Memory branch, Config.Database.enabled = false, NO `MySQL`
-- global defined at all in this sandbox -- see this file's header.
-- ----------------------------------------------------------------------

local memEnv = Sandbox.newEnv({
    Config = { Database = { enabled = false } },
    -- Deliberately NOT setting MySQL here. Sandbox.newEnv copies the real
    -- process _G first, and the real process has no MySQL global either
    -- (this is plain lua5.4, not FXServer), so `env.MySQL` is genuinely
    -- nil, not just unset-by-convention.
    print = function(...) end,
})
Sandbox.loadInto('../server/datastore.lua', memEnv)
local MemStore = memEnv.K9Store

t.isFalse(MemStore.IsDatabaseEnabled(), 'IsDatabaseEnabled must reflect Config.Database.enabled = false')
t.isNil(memEnv.MySQL, 'sanity check on the fixture itself: MySQL must be genuinely absent from this sandbox')

t.test('Memory: a fresh process starts with EVERY table empty -- fail-closed by construction, not by discipline', function()
    t.isNil(MemStore.Cert_GetActiveId('NOBODY', 'police'))
    t.isNil(MemStore.Perm_GetActiveId('NOBODY', 'k9.access'))
    t.equals(#MemStore.Perm_GetActiveForCitizen('NOBODY'), 0)
    t.isNil(MemStore.Partner_GetActiveRowByParty('NOBODY'))
    t.isNil(MemStore.XP_Get('NOBODY'))
    t.equals(#MemStore.SearchLog_GetRecent(50), 0)
    t.equals(#MemStore.Override_GetAll(), 0)
    t.equals(#MemStore.Theme_GetRows(), 0)
    t.isNil(MemStore.Appearance_GetRow('NOBODY'))
    -- GAP 2 CLOSURE -- every one of the eight catalog-edit audit read
    -- accessors must ALSO start empty on a fresh process, matching this
    -- test's own "fail-closed by construction" framing: `Config.Database.enabled
    -- = false` with nothing yet written THIS session must read back as
    -- nothing, never a hardcoded empty regardless of real state (see each
    -- accessor's own doc comment in server/datastore.lua). Placed HERE
    -- (the very first Part 2 test) deliberately -- every one of these eight
    -- tables is still genuinely untouched by any earlier test in this file
    -- at this exact point, so this is a real assertion about a truly fresh
    -- process, not a coincidence of test order.
    t.equals(#MemStore.OverrideAudit_GetRecent(50), 0)
    t.equals(#MemStore.ThemeAudit_GetRecent(50), 0)
    t.equals(#MemStore.ShopLocationAudit_GetRecent(50), 0)
    t.equals(#MemStore.TierAudit_GetRecent(50), 0)
    t.equals(#MemStore.PermKeyAudit_GetRecent(50), 0)
    t.equals(#MemStore.XPTierAudit_GetRecent(50), 0)
    t.equals(#MemStore.IndividualOverrideAudit_GetRecent(50), 0)
    t.equals(#MemStore.ShopItemAudit_GetRecent(50), 0)
end)

t.test('Memory: Cert_Insert/GetActiveId/RevokeActive round-trip, fails closed again after revoke', function()
    local id = MemStore.Cert_Insert('CITA', 'police', 'GRANTERA', nil)
    t.isNotNil(id)
    t.equals(MemStore.Cert_GetActiveId('CITA', 'police'), id)
    t.isNotNil(MemStore.Cert_GetActiveMeta('CITA', 'police'))

    local affected = MemStore.Cert_RevokeActive('CITA', 'police', 'GRANTERA', 'reassigned')
    t.equals(affected, 1)
    t.isNil(MemStore.Cert_GetActiveId('CITA', 'police'), 'revoked row must no longer be found as active')
    t.equals(MemStore.Cert_RevokeActive('CITA', 'police', 'GRANTERA', 'reassigned'), 0, 'revoking an already-inactive row affects zero rows, same as the real UPDATE')
end)

t.test('Memory: Cert_Insert raises a real MySQL-1062-shaped error on a duplicate ACTIVE (citizenid, job)', function()
    MemStore.Cert_Insert('CITB', 'sheriff', 'G', nil)
    local ok, err = pcall(MemStore.Cert_Insert, 'CITB', 'sheriff', 'G', nil)
    t.isFalse(ok)
    t.equals(err.errno, 1062, 'must be the exact shape certifications.lua/permissions.lua/partnership.lua\'s own IsDuplicateKeyError already checks first (err.errno == 1062)')
end)

t.test('Memory: a DIFFERENT job for the same citizenid is NOT a duplicate -- the invariant is scoped per (citizenid, job)', function()
    MemStore.Cert_Insert('CITC', 'police', 'G', nil)
    local ok = pcall(MemStore.Cert_Insert, 'CITC', 'sheriff', 'G', nil)
    t.isTrue(ok, 'holding an active cert for a different department must never block a new one -- cross-department granting is allowed')
end)

t.test('Memory: Cert_SetTier / Cert_RenewExpiry only touch the currently active row', function()
    MemStore.Cert_Insert('CITD', 'police', 'G', nil)
    t.equals(MemStore.Cert_SetTier('CITD', 'police', 'senior'), 1)
    t.equals(MemStore.Cert_GetActiveMeta('CITD', 'police').tier, 'senior')
    t.equals(MemStore.Cert_SetTier('NOBODY', 'police', 'senior'), 0)
end)

t.test('Memory: specializations require nothing beyond their own (citizenid, job, specialization) key; cascade-revoke clears every active one at once', function()
    MemStore.Cert_Insert('CITE', 'police', 'G', nil)
    MemStore.Spec_Insert('CITE', 'police', 'narcotics', 'G')
    MemStore.Spec_Insert('CITE', 'police', 'explosives', 'G')
    t.equals(#MemStore.Spec_GetActiveKeys('CITE', 'police'), 2)

    local ok, err = pcall(MemStore.Spec_Insert, 'CITE', 'police', 'narcotics', 'G')
    t.isFalse(ok)
    t.equals(err.errno, 1062)

    local revoked = MemStore.Spec_RevokeAllForJob('CITE', 'police', 'G')
    t.equals(revoked, 2)
    t.equals(#MemStore.Spec_GetActiveKeys('CITE', 'police'), 0)
end)

t.test('Memory: Partner_Insert enforces BOTH independent uniqueness dimensions -- a citizenid cannot be active as K9 in one row and handler in another', function()
    MemStore.Partner_Insert('K9A', 'HANDLERA', 'HANDLERA')

    local ok1 = pcall(MemStore.Partner_Insert, 'K9A', 'HANDLERB', 'HANDLERB')
    t.isFalse(ok1, 'K9A already active as a K9 -- must reject a second partnership naming it in EITHER role')

    local ok2 = pcall(MemStore.Partner_Insert, 'K9B', 'HANDLERA', 'HANDLERA')
    t.isFalse(ok2, 'HANDLERA already active as a handler -- must reject a second partnership naming it in EITHER role')

    local row = MemStore.Partner_GetActiveRowByParty('K9A')
    t.isNotNil(row)
    local ended = MemStore.Partner_EndById(row.id, 'HANDLERA')
    t.equals(ended, 1)
    t.isNil(MemStore.Partner_GetActiveRowByParty('K9A'))

    -- Now that the row is ended, both citizenids are free to form NEW pairs.
    local ok3 = pcall(MemStore.Partner_Insert, 'K9A', 'HANDLERB', 'HANDLERB')
    t.isTrue(ok3, 'ending a partnership must free both parties to re-partner -- this is not a permanent lock')
end)

t.test('Memory: Partner_GetActiveFlagById reads by id alone, regardless of current active state -- the reconciliation shape DoBreakPartnership needs', function()
    local id = MemStore.Partner_Insert('K9C', 'HANDLERC', 'HANDLERC')
    t.equals(MemStore.Partner_GetActiveFlagById(id), 1)
    MemStore.Partner_EndById(id, 'HANDLERC')
    t.equals(MemStore.Partner_GetActiveFlagById(id), 0, 'must still resolve after ending -- this is NOT the same as GetActiveRowByParty, which only finds ACTIVE rows')
    t.isNil(MemStore.Partner_GetActiveFlagById(99999))
end)

t.test('Memory: tenure CAS only applies when the row is still active AND the expected old tier still matches -- a lost race affects zero rows', function()
    local id = MemStore.Partner_Insert('K9D', 'HANDLERD', 'HANDLERD')
    t.equals(MemStore.Partner_SetTenureTierCAS(id, 1, 0), 1)
    t.equals(MemStore.Partner_SetTenureTierCAS(id, 2, 0), 0, 'stale expected-old-tier (0) must not apply on top of the already-advanced tier (1)')
    t.equals(MemStore.Partner_SetTenureTierCAS(id, 2, 1), 1, 'the correct current tier (1) is accepted')
    local tenureRow = MemStore.Partner_GetTenureRow('K9D')
    t.equals(tenureRow.tenure_bonus_tier_granted, 2)
    t.isTrue(tenureRow.tenure_seconds >= 0)
end)

t.test('Memory: PairProgress_UpsertHighestTenureTier is a GREATEST upsert keyed by the EXACT (k9, handler) pair -- never lowers an existing value, is role-order-sensitive, and is completely independent of any k9_partnerships ROW (survives that row being replaced by a break+reform)', function()
    t.isNil(MemStore.PairProgress_GetHighestTenureTier('K9E', 'HANDLERE'), 'a pair that has never earned anything starts with no row at all')

    MemStore.PairProgress_UpsertHighestTenureTier('K9E', 'HANDLERE', 1)
    t.equals(MemStore.PairProgress_GetHighestTenureTier('K9E', 'HANDLERE'), 1)

    MemStore.PairProgress_UpsertHighestTenureTier('K9E', 'HANDLERE', 0)
    t.equals(MemStore.PairProgress_GetHighestTenureTier('K9E', 'HANDLERE'), 1, 'writing a SMALLER tier than what is already on file must never lower it')

    MemStore.PairProgress_UpsertHighestTenureTier('K9E', 'HANDLERE', 3)
    t.equals(MemStore.PairProgress_GetHighestTenureTier('K9E', 'HANDLERE'), 3)

    -- A role-swapped "pair" (the same two humans, K9 and handler roles
    -- reversed) is a DIFFERENT relationship -- never shares a row with the
    -- original, mirroring server/partnership.lua's own role-order-sensitive
    -- key construction (that file's own TenurePairKey-equivalent doc
    -- comment).
    t.isNil(MemStore.PairProgress_GetHighestTenureTier('HANDLERE', 'K9E'), 'a role-reversed lookup must not find the original pair\'s row')

    -- Independent of any k9_partnerships ROW -- this is the entire reason
    -- this table exists (see sql/install.sql's own header on this table):
    -- ending a k9_partnerships row must never affect it.
    local id = MemStore.Partner_Insert('K9E', 'HANDLERE', 'HANDLERE')
    MemStore.Partner_EndById(id, 'HANDLERE')
    t.equals(MemStore.PairProgress_GetHighestTenureTier('K9E', 'HANDLERE'), 3, 'this table is keyed by the pair, never by any one partnership row -- ending the row must not touch it')
end)

t.test('Memory: Perm_Insert/RevokeActive round-trip and duplicate-active rejection, same shape as certifications', function()
    local id = MemStore.Perm_Insert('CITF', 'k9.access', 'HC1')
    t.equals(MemStore.Perm_GetActiveId('CITF', 'k9.access'), id)
    local ok, err = pcall(MemStore.Perm_Insert, 'CITF', 'k9.access', 'HC1')
    t.isFalse(ok)
    t.equals(err.errno, 1062)
    t.equals(MemStore.Perm_RevokeActive('CITF', 'k9.access', 'HC1'), 1)
    t.isNil(MemStore.Perm_GetActiveId('CITF', 'k9.access'))
end)

t.test('Memory: XP_Get/XP_UpsertAdd/XP_GetTop -- accumulates deltas, never overwrites, ranks correctly', function()
    t.isNil(MemStore.XP_Get('XPCIT1'))
    MemStore.XP_UpsertAdd('XPCIT1', 20)
    MemStore.XP_UpsertAdd('XPCIT1', 25)
    t.equals(MemStore.XP_Get('XPCIT1'), 45, 'must ADD the delta, never overwrite with the last award amount')

    MemStore.XP_UpsertAdd('XPCIT2', 100)
    local top = MemStore.XP_GetTop(1)
    t.equals(#top, 1)
    t.equals(top[1].citizenid, 'XPCIT2')
    t.equals(top[1].xp, 100)

    local snap = MemStore.XP_GetSnapshotRows('XPCIT1')
    t.equals(#snap, 1)
    t.equals(snap[1].xp, 45)
    t.equals(#MemStore.XP_GetSnapshotRows('NOBODY'), 0)
end)

t.test('Memory: k9_search_log is a BOUNDED ring buffer -- inserting well past capacity never grows the table without limit', function()
    for i = 1, 520 do
        MemStore.SearchLog_Insert('OFFICERX', 'police', 'vehicle', ('PLATE%d'):format(i), nil, 'clean', 0, 'clean')
    end
    local recent = MemStore.SearchLog_GetRecent(1000)
    t.isTrue(#recent <= 500, 'must never exceed the documented in-memory cap regardless of how many rows are inserted')
    -- The MOST RECENT insert (id-wise) must still be present -- eviction
    -- drops the OLDEST rows, never the newest.
    t.equals(recent[1].target_plate, 'PLATE520')
    -- And the very first insert must be long gone.
    local foundOldest = false
    for _, row in ipairs(MemStore.SearchLog_GetByPlate('PLATE1', 1000)) do
        foundOldest = true
    end
    t.isFalse(foundOldest, 'the oldest row must have been evicted once the cap was exceeded')
end)

t.test('Memory: SearchLog_GetByOfficer/ByPlate/ByPerson filter correctly and never see each other\'s rows', function()
    MemStore.SearchLog_Insert('OFF1', 'police', 'vehicle', 'ABC123', nil, 'found', 5, 'aggressive_bark')
    MemStore.SearchLog_Insert('OFF2', 'police', 'person', nil, 'TARGETCIT', 'clean', 0, 'clean')
    t.equals(#MemStore.SearchLog_GetByOfficer('OFF1', 10), 1)
    t.equals(#MemStore.SearchLog_GetByPlate('ABC123', 10), 1)
    t.equals(#MemStore.SearchLog_GetByPerson('TARGETCIT', 10), 1)
    t.equals(#MemStore.SearchLog_GetByPerson('ABC123', 10), 0)
end)

t.test('Memory: runtime overrides are a plain upsert-in-place key/value store, not an active-row table', function()
    t.isTrue(MemStore.Override_Upsert('feature:Recall', 'feature', 'false', 'HC1'))
    t.equals(#MemStore.Override_GetAll(), 1)
    t.isTrue(MemStore.Override_Upsert('feature:Recall', 'feature', 'true', 'HC2'), 'upserting the SAME key must update in place, not add a second row')
    t.equals(#MemStore.Override_GetAll(), 1)
    t.isTrue(MemStore.OverrideAudit_Append('feature:Recall', 'feature', 'false', 'true', 'HC2'))
    t.isTrue(MemStore.Override_Delete('feature:Recall'))
    t.equals(#MemStore.Override_GetAll(), 0)
end)

t.test('Memory: NAME COLLISION REGRESSION -- runtime-feature-override rows and individual-K9-override rows live in two INDEPENDENT in-memory tables, never a shared one', function()
    t.isTrue(MemStore.Override_Upsert('feature:Recall', 'feature', 'false', 'HC1'))
    t.isTrue(MemStore.IndividualOverride_Upsert('CIT1', 1.1, 1.2, nil, 'note', 'HC1'))
    t.equals(#MemStore.Override_GetAll(), 1, 'the runtime-feature-override table must be unaffected by an individual-K9-override write')
    t.equals(#MemStore.IndividualOverride_GetAllRows(), 1, 'the individual-K9-override table must be unaffected by a runtime-feature-override write')
    t.isTrue(MemStore.Override_Delete('feature:Recall'))
    t.equals(#MemStore.IndividualOverride_GetAllRows(), 1, 'deleting a runtime feature override must not touch the individual-K9-override table')
end)

--- @param citizenid string
--- @return table? row
local function findIndividualOverrideRow(citizenid)
    for _, row in ipairs(MemStore.IndividualOverride_GetAllRows()) do
        if row.citizenid == citizenid then return row end
    end
    return nil
end

t.test('Memory: k9_individual_overrides upsert-in-place, per-field NULL preserved, tombstone excludes from GetAllRows filtering (deleted flag surfaced raw)', function()
    -- NOTE: this fixture's own K9Store is shared, module-level state across
    -- every test in this file (same convention every other Memory test
    -- above already relies on -- see e.g. SearchLog's own accumulating rows)
    -- -- an EARLIER test in this same file already wrote a 'CIT1' row, so
    -- this test scopes every assertion to its OWN citizenid ('CITY') rather
    -- than asserting a total row count, which would be order-dependent.
    t.isNil(findIndividualOverrideRow('CITY'), 'a citizenid with no prior write must have no row at all')

    t.isTrue(MemStore.IndividualOverride_Upsert('CITY', 1.25, nil, 0.8, 'fast dog', 'HC1'))
    local row = findIndividualOverrideRow('CITY')
    t.isNotNil(row)
    t.equals(row.speed_multiplier, 1.25)
    t.isNil(row.scent_range_multiplier, 'an omitted field must persist as NULL, not 0 or false')
    t.equals(row.medkit_cooldown_multiplier, 0.8)
    t.equals(row.deleted, 0)

    t.isTrue(MemStore.IndividualOverride_Upsert('CITY', 1.25, 1.30, 0.8, 'fast dog', 'HC2'), 'upserting the SAME citizenid must update in place, not add a second row')
    local rowsForCity = 0
    for _, r in ipairs(MemStore.IndividualOverride_GetAllRows()) do
        if r.citizenid == 'CITY' then rowsForCity = rowsForCity + 1 end
    end
    t.equals(rowsForCity, 1, 'upserting the same citizenid twice must never produce a second row for it')

    t.isTrue(MemStore.IndividualOverride_Tombstone('CITY', 'HC1'))
    row = findIndividualOverrideRow('CITY')
    t.isNotNil(row, 'GetAllRows returns tombstoned rows too -- filtering deleted=1 out of the LIVE catalog is server/k9profiles.lua\'s own job, mirroring K9Store.Tier_GetAllRows exactly')
    t.equals(row.deleted, 1)

    t.isTrue(MemStore.IndividualOverride_Tombstone('NEVER_EXISTED', 'HC1'), 'tombstoning a citizenid with no prior row must still succeed (creates a deleted-only row), matching Tier_Tombstone\'s identical shape')
    t.isTrue(MemStore.IndividualOverrideAudit_Append('override_reset', 'CITX', 'reset', 'HC1'))
end)

t.test('Memory: tablet theme is a SINGLETON -- upserting twice never produces two rows', function()
    t.equals(#MemStore.Theme_GetRows(), 0, 'no theme has ever been saved yet in this fresh fixture')
    MemStore.Theme_Upsert('#111111', '#222222', '#333333', '#444444', 'comfortable', 'K9 Tablet', 'HC1')
    MemStore.Theme_Upsert('#000000', '#222222', '#333333', '#444444', 'comfortable', 'K9 Tablet', 'HC1')
    local rows = MemStore.Theme_GetRows()
    t.equals(#rows, 1)
    t.equals(rows[1].primary_color, '#000000', 'the second upsert must overwrite the singleton row, not add another')
    t.isTrue(MemStore.ThemeAudit_Append('#000000', '#222222', '#333333', '#444444', 'comfortable', 'K9 Tablet', 'HC1'))
end)

t.test('Memory: k9_ped_assignments preserves original_model_hash across a re-apply while active (COALESCE semantics), but captures a NEW original after a revert', function()
    t.isTrue(MemStore.Appearance_UpsertApplied('CITG', 'a_c_shepherd', 555, 'HC1'))
    t.isTrue(MemStore.Appearance_UpsertApplied('CITG', 'a_c_husky', nil, 'HC1'), 'a re-apply with no new hash supplied must COALESCE onto the existing one')
    t.equals(MemStore.Appearance_GetRow('CITG').original_model_hash, 555)

    t.isTrue(MemStore.Appearance_MarkReverted('CITG'))
    t.equals(MemStore.Appearance_GetRow('CITG').active, 0)

    t.isTrue(MemStore.Appearance_UpsertApplied('CITG', 'a_c_rottweiler', 999, 'HC1'), 'a fresh assignment after a genuine revert must capture a NEW original, never reuse the stale one')
    t.equals(MemStore.Appearance_GetRow('CITG').original_model_hash, 999)
end)

t.test('Memory: Appearance_SetOriginalHashIfMissing only fills a NULL hash on an active row, never overwrites a real one', function()
    MemStore.Appearance_UpsertApplied('CITH', 'a_c_shepherd', nil, 'HC1')
    t.isNil(MemStore.Appearance_GetRow('CITH').original_model_hash)
    MemStore.Appearance_SetOriginalHashIfMissing('CITH', 4242)
    t.equals(MemStore.Appearance_GetRow('CITH').original_model_hash, 4242)
    MemStore.Appearance_SetOriginalHashIfMissing('CITH', 9999)
    t.equals(MemStore.Appearance_GetRow('CITH').original_model_hash, 4242, 'must never clobber an already-known original')
end)

t.test('Memory: Cert_GetActiveJobsForCitizen returns one row per ACTIVE department, excludes a revoked one, never leaks another citizenid\'s row', function()
    t.equals(#MemStore.Cert_GetActiveJobsForCitizen('NEVERCERT'), 0)
    MemStore.Cert_Insert('CITI', 'police', 'G1', nil)
    MemStore.Cert_Insert('CITI', 'sheriff', 'G2', nil)
    MemStore.Cert_Insert('OTHERCIT', 'police', 'G3', nil)
    local rows = MemStore.Cert_GetActiveJobsForCitizen('CITI')
    t.equals(#rows, 2)
    local byJob = {}
    for _, row in ipairs(rows) do byJob[row.job] = row.granted_by end
    t.equals(byJob.police, 'G1')
    t.equals(byJob.sheriff, 'G2')

    MemStore.Cert_RevokeActive('CITI', 'sheriff', 'G2', 'reassigned')
    t.equals(#MemStore.Cert_GetActiveJobsForCitizen('CITI'), 1, 'a revoked department must disappear from this accessor exactly like the real active=1 filter')
end)

t.test('Memory: Cert_GetActiveRosterByJobUnordered filters by job, respects LIMIT, and never sorts (no ORDER BY to reproduce)', function()
    -- Unique job name ('rosterdept') deliberately NOT reused by any other
    -- test in this shared-MemStore file -- every job used elsewhere
    -- ('police'/'sheriff') already accumulates rows from earlier tests
    -- above, which would make a LIMIT-3-of-exactly-these-5 assertion
    -- flaky/order-dependent through no fault of the accessor itself.
    for i = 1, 5 do
        MemStore.Cert_Insert(('ROSTERCIT%d'):format(i), 'rosterdept', 'HC1', nil)
    end
    MemStore.Cert_Insert('SHERIFFCIT', 'sheriff', 'HC1', nil)

    local rows = MemStore.Cert_GetActiveRosterByJobUnordered('rosterdept', 3)
    t.equals(#rows, 3, 'LIMIT must be honored in memory mode exactly like a real SQL LIMIT clause')
    for _, row in ipairs(rows) do
        t.isTrue(row.citizenid:find('ROSTERCIT', 1, true) ~= nil, 'must never leak a different job\'s row')
    end

    local allRosterDept = MemStore.Cert_GetActiveRosterByJobUnordered('rosterdept', 100)
    t.equals(#allRosterDept, 5)
end)

t.test('Memory: Cert_CountByTier counts EVERY row referencing a tier, active or revoked, never filtered by active -- matches HAZARD 2\'s own reasoning', function()
    -- Unique tier strings ('countertierA'/'countertierB') deliberately NOT
    -- reused by any other test -- Cert_Insert's own memory-mode default
    -- ('certified') and Cert_SetTier('senior') are both already exercised,
    -- and contaminated, by earlier tests sharing this same MemStore.
    t.equals(MemStore.Cert_CountByTier('countertierA'), 0)
    MemStore.Cert_Insert('TIERCIT1', 'countertierdept', 'HC1', nil) -- defaults to tier='certified', per the real DB DEFAULT
    MemStore.Cert_Insert('TIERCIT2', 'countertierdept', 'HC1', nil)
    MemStore.Cert_SetTier('TIERCIT2', 'countertierdept', 'countertierA')
    t.equals(MemStore.Cert_CountByTier('countertierA'), 1)

    -- Revoking must NOT remove the row from this count -- an inactive row
    -- still holds a real, audit-trail-relevant tier value.
    MemStore.Cert_RevokeActive('TIERCIT2', 'countertierdept', 'HC1', 'reassigned')
    t.equals(MemStore.Cert_CountByTier('countertierA'), 1, 'a revoked row must still be counted -- this is what makes DeleteTier\'s reference-count check correctly refuse a delete for a tier only historical rows still reference')
end)

t.test('Memory: Tier_GetAllRows/TierCap_GetAllRows/TierCap_GetForTier/Cert_CountByTier all start empty on a fresh process', function()
    t.equals(#MemStore.Tier_GetAllRows(), 0)
    t.equals(#MemStore.TierCap_GetAllRows(), 0)
    t.equals(#MemStore.TierCap_GetForTier('anything'), 0)
    t.equals(#MemStore.Tier_GetDeletedFlagByKey('anything'), 0)
end)

t.test('Memory: Tier_Upsert creates a brand-new row and later renames/re-ordinals it in place -- both label AND ordinal move', function()
    t.isTrue(MemStore.Tier_Upsert('mastert', 'Master', 4, 'HC1'))
    local rows = MemStore.Tier_GetAllRows()
    t.equals(#rows, 1)
    t.equals(rows[1].tier_key, 'mastert')
    t.equals(rows[1].label, 'Master')
    t.equals(rows[1].ordinal, 4)
    t.equals(rows[1].deleted, 0)

    t.isTrue(MemStore.Tier_Upsert('mastert', 'Standard Handler', 4, 'HC2'), 'renaming an already-live tier via Tier_Upsert must update label in place')
    t.equals(MemStore.Tier_GetAllRows()[1].label, 'Standard Handler')
end)

t.test('Memory: Tier_UpdateOrdinal (the reorder write) moves ordinal but NEVER touches an already-existing row\'s label -- the exact race this accessor exists to close', function()
    MemStore.Tier_Upsert('reordert', 'Real Label', 3, 'HC1')
    MemStore.Tier_UpdateOrdinal('reordert', 'STALE-SNAPSHOT-LABEL', 9, 'HC2')
    local rows = MemStore.Tier_GetAllRows()
    local found
    for _, row in ipairs(rows) do if row.tier_key == 'reordert' then found = row end end
    t.isNotNil(found)
    t.equals(found.ordinal, 9, 'ordinal must move')
    t.equals(found.label, 'Real Label', 'label must be COMPLETELY UNTOUCHED by a reorder write, even though a label value was passed through as a parameter -- reusing Tier_Upsert here would have silently overwritten this with the stale snapshot')

    -- The brand-new-row branch DOES use the passed label, matching the
    -- real SQL's own INSERT column list (only reachable when no row
    -- exists yet at all for this key).
    MemStore.Tier_UpdateOrdinal('brandnewviareorder', 'From Config Default', 1, 'HC3')
    local created = MemStore.Tier_GetDeletedFlagByKey('brandnewviareorder')
    t.equals(#created, 1)
    t.equals(created[1].deleted, 0)
end)

t.test('Memory: Tier_Tombstone deletes (tombstones) an existing row without touching its label/ordinal, and can also create a fresh tombstone for a never-before-seen key', function()
    MemStore.Tier_Upsert('tombstonet', 'Tombstone Me', 2, 'HC1')
    t.isTrue(MemStore.Tier_Tombstone('tombstonet', 'IGNORED-LABEL', 999, 'HC2'))
    local rows = MemStore.Tier_GetAllRows()
    local found
    for _, row in ipairs(rows) do if row.tier_key == 'tombstonet' then found = row end end
    t.equals(found.deleted, 1)
    t.equals(found.label, 'Tombstone Me', 'a tombstone of an EXISTING row must never touch label')
    t.equals(found.ordinal, 2, 'a tombstone of an EXISTING row must never touch ordinal')

    -- A legacy config-only key (e.g. 'trainee') that has never had a row
    -- in this table before -- Tier_Tombstone's own brand-new-row branch.
    t.isTrue(MemStore.Tier_Tombstone('trainee', 'Trainee', 1, 'HC3'))
    t.equals(MemStore.Tier_GetDeletedFlagByKey('trainee')[1].deleted, 1)
end)

t.test('Memory: TierCap_Insert/GetForTier/GetAllRows/Delete round-trip correctly, scoped per tier_key, idempotent on a duplicate insert', function()
    MemStore.TierCap_Insert('capt1', 'advanced_tracking', 'HC1')
    MemStore.TierCap_Insert('capt1', 'mentor_trainees', 'HC1')
    MemStore.TierCap_Insert('capt2', 'advanced_tracking', 'HC1')
    t.equals(#MemStore.TierCap_GetForTier('capt1'), 2)
    t.equals(#MemStore.TierCap_GetForTier('capt2'), 1)
    t.equals(#MemStore.TierCap_GetAllRows(), 3)

    -- Re-inserting the SAME (tier_key, capability_key) pair must never
    -- duplicate -- matches the real table's own composite PRIMARY KEY.
    MemStore.TierCap_Insert('capt1', 'advanced_tracking', 'HC2')
    t.equals(#MemStore.TierCap_GetForTier('capt1'), 2, 'a re-insert of the same pair must not create a second row')

    MemStore.TierCap_Delete('capt1', 'advanced_tracking')
    t.equals(#MemStore.TierCap_GetForTier('capt1'), 1)
    t.equals(#MemStore.TierCap_GetAllRows(), 2)
end)

t.test('Memory: TierAudit_Append never throws regardless of volume (bounded ring buffer, same treatment as every other admin-gated audit table in this file)', function()
    for i = 1, 250 do
        t.isTrue(MemStore.TierAudit_Append('tier_update', 'sometier', ('detail %d'):format(i), 'HC1'))
    end
end)

-- ----------------------------------------------------------------------
-- PART 3 -- Parity: the SAME sequence against a fresh instance of EACH
-- backend must reach the SAME externally-observable outcome. The MySQL
-- fixture here is a small fake relational table (not just a capture
-- stub) so its own duplicate-key/affected-row behavior is real, not
-- asserted by fiat.
-- ----------------------------------------------------------------------

--- @return table mysql -- a minimal fake honoring k9_certifications' one
--- invariant this parity check exercises: at most one ACTIVE row per
--- (citizenid, job).
local function newFakeCertMySQL()
    local rows, nextId = {}, 0
    local function findActive(citizenid, job)
        for _, r in ipairs(rows) do
            if r.active == 1 and r.citizenid == citizenid and r.job == job then return r end
        end
    end
    return {
        scalar = { await = function(_sql, p)
            local r = findActive(p[1], p[2])
            return r and r.id or nil
        end },
        insert = { await = function(_sql, p)
            if findActive(p[1], p[2]) then error({ errno = 1062, message = 'ER_DUP_ENTRY' }, 0) end
            nextId = nextId + 1
            rows[#rows + 1] = { id = nextId, citizenid = p[1], job = p[2], granted_by = p[3], active = 1 }
            return nextId
        end },
        update = { await = function(_sql, p)
            -- p = { revokedBy, reason, citizenid, job } for Cert_RevokeActive
            local r = findActive(p[3], p[4])
            if not r then return 0 end
            r.active = 0
            return 1
        end },
    }
end

--- @param store table -- a K9Store instance (either backend)
local function runCertParitySequence(store)
    local outcomes = {}
    outcomes.initialLookup = store.Cert_GetActiveId('PARITYCIT', 'police')
    local grantOk = pcall(store.Cert_Insert, 'PARITYCIT', 'police', 'G', nil)
    outcomes.grantOk = grantOk
    outcomes.afterGrantLookup = store.Cert_GetActiveId('PARITYCIT', 'police') ~= nil
    local dupOk = pcall(store.Cert_Insert, 'PARITYCIT', 'police', 'G', nil)
    outcomes.dupOk = dupOk
    outcomes.revokedRows = store.Cert_RevokeActive('PARITYCIT', 'police', 'G', 'reassigned')
    outcomes.afterRevokeLookup = store.Cert_GetActiveId('PARITYCIT', 'police')
    return outcomes
end

t.test('Parity: certification grant/duplicate-reject/revoke sequence reaches the IDENTICAL outcome on both backends', function()
    local mysqlParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = true } }, MySQL = newFakeCertMySQL(), print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', mysqlParityEnv)

    local memParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = false } }, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', memParityEnv)

    local mysqlOutcome = runCertParitySequence(mysqlParityEnv.K9Store)
    local memOutcome = runCertParitySequence(memParityEnv.K9Store)

    t.isNil(mysqlOutcome.initialLookup)
    t.isNil(memOutcome.initialLookup)
    t.equals(mysqlOutcome.grantOk, memOutcome.grantOk)
    t.isTrue(mysqlOutcome.grantOk)
    t.equals(mysqlOutcome.afterGrantLookup, memOutcome.afterGrantLookup)
    t.isTrue(mysqlOutcome.afterGrantLookup)
    t.equals(mysqlOutcome.dupOk, memOutcome.dupOk)
    t.isFalse(mysqlOutcome.dupOk, 'both backends must reject the duplicate active grant identically')
    t.equals(mysqlOutcome.revokedRows, memOutcome.revokedRows)
    t.equals(mysqlOutcome.revokedRows, 1)
    t.equals(mysqlOutcome.afterRevokeLookup, memOutcome.afterRevokeLookup)
    t.isNil(mysqlOutcome.afterRevokeLookup)
end)

--- @return table mysql -- a minimal fake honoring k9_certification_tiers'
--- real semantics closely enough to matter for THIS parity check: on a
--- conflicting key, an ON DUPLICATE KEY UPDATE clause only overwrites the
--- COLUMNS IT ACTUALLY MENTIONS (real MySQL/MariaDB behavior) -- this fake
--- inspects the SQL text for `label = VALUES(label)` / `ordinal =
--- VALUES(ordinal)` before applying either, exactly like a real server
--- would, rather than blindly overwriting every column from the VALUES
--- list. This is what makes the Tier_UpdateOrdinal-must-never-touch-label
--- assertion below a REAL parity proof, not merely two implementations
--- that happen to agree by coincidence.
local function newFakeTierMySQL()
    local tiers = {}
    return {
        query = { await = function(sql, p)
            if sql:find('SELECT tier_key, label, ordinal, deleted FROM k9_certification_tiers', 1, true) then
                local out = {}
                for key, row in pairs(tiers) do
                    out[#out + 1] = { tier_key = key, label = row.label, ordinal = row.ordinal, deleted = row.deleted }
                end
                return out
            elseif sql:find('SELECT deleted FROM k9_certification_tiers WHERE tier_key = ?', 1, true) then
                local row = tiers[p[1]]
                if row then return { { deleted = row.deleted } } end
                return {}
            elseif sql:find('INSERT INTO k9_certification_tiers', 1, true) then
                local key, label, ordinal, updatedBy = p[1], p[2], p[3], p[4]
                local deletedLiteral = sql:find('VALUES (?, ?, ?, 1, ?)', 1, true) and 1 or 0
                local existing = tiers[key]
                if existing then
                    if sql:find('label = VALUES(label)', 1, true) then existing.label = label end
                    if sql:find('ordinal = VALUES(ordinal)', 1, true) then existing.ordinal = ordinal end
                    existing.deleted = deletedLiteral
                    existing.updated_by = updatedBy
                else
                    tiers[key] = { label = label, ordinal = ordinal, deleted = deletedLiteral, updated_by = updatedBy }
                end
                return {}
            end
            error('newFakeTierMySQL: unhandled SQL: ' .. tostring(sql))
        end },
    }
end

--- @param store table -- a K9Store instance (either backend)
local function runTierParitySequence(store)
    local outcomes = {}
    store.Tier_Upsert('paritytier', 'Original Label', 4, 'HC1')

    -- The reorder write: passes a STALE label snapshot through, exactly
    -- like server/certtiers.lua's ReorderTiers loop does -- must NEVER
    -- stick.
    store.Tier_UpdateOrdinal('paritytier', 'STALE-LABEL-FROM-REORDER', 9, 'HC2')
    local rows = store.Tier_GetAllRows()
    for _, row in ipairs(rows) do
        if row.tier_key == 'paritytier' then
            outcomes.labelAfterReorder = row.label
            outcomes.ordinalAfterReorder = row.ordinal
        end
    end

    outcomes.deletedBeforeTombstone = store.Tier_GetDeletedFlagByKey('paritytier')[1].deleted
    store.Tier_Tombstone('paritytier', 'IGNORED', 999, 'HC3')
    outcomes.deletedAfterTombstone = store.Tier_GetDeletedFlagByKey('paritytier')[1].deleted

    return outcomes
end

t.test('Parity: Tier_Upsert/Tier_UpdateOrdinal/Tier_Tombstone reach the IDENTICAL outcome on both backends -- INCLUDING that a reorder write never overwrites label', function()
    local mysqlParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = true } }, MySQL = newFakeTierMySQL(), print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', mysqlParityEnv)

    local memParityEnv = Sandbox.newEnv({ Config = { Database = { enabled = false } }, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', memParityEnv)

    local mysqlOutcome = runTierParitySequence(mysqlParityEnv.K9Store)
    local memOutcome = runTierParitySequence(memParityEnv.K9Store)

    t.equals(mysqlOutcome.labelAfterReorder, memOutcome.labelAfterReorder)
    t.equals(mysqlOutcome.labelAfterReorder, 'Original Label', 'BOTH backends must preserve the pre-reorder label -- neither may adopt the stale snapshot the reorder call passed through')
    t.equals(mysqlOutcome.ordinalAfterReorder, memOutcome.ordinalAfterReorder)
    t.equals(mysqlOutcome.ordinalAfterReorder, 9)
    t.equals(mysqlOutcome.deletedBeforeTombstone, memOutcome.deletedBeforeTombstone)
    t.equals(mysqlOutcome.deletedBeforeTombstone, 0)
    t.equals(mysqlOutcome.deletedAfterTombstone, memOutcome.deletedAfterTombstone)
    t.equals(mysqlOutcome.deletedAfterTombstone, 1)
end)

-- ----------------------------------------------------------------------
-- RESTART-DURABILITY (this pass -- closes the KNOWN_ISSUES.md item
-- "the partnership tenure-bonus anti-farm fix is in-memory only... a
-- restart re-opens the exploit once, for any pair that happens to break
-- up and reform around that restart"). A resource restart discards EVERY
-- Lua-level table this file owns -- both K9Store's own in-memory fallback
-- rows AND server/partnership.lua's local state -- but leaves a REAL
-- database untouched. Reloading server/datastore.lua fresh (a brand-new
-- `K9Store` table, a brand-new `PairProgressRows`) into TWO different
-- fixtures models exactly that: one backed by a fake table that survives
-- the reload (standing in for a real database), one that does not
-- (Config.Database.enabled = false, memory mode) -- proving the DB-mode
-- guard is genuinely restart-proof, and that the disclosed memory-mode
-- limit is exactly what KNOWN_ISSUES.md now says it is (a real, meaningful
-- improvement for that process's own uptime, not a restart-proof one).
-- ----------------------------------------------------------------------

--- @return table mysql -- a minimal fake persistent table for
--- k9_partnership_pair_progress's own GREATEST-upsert shape, kept in an
--- upvalue OUTSIDE any one K9Store instance so it survives that instance
--- being thrown away and a fresh one loaded against the SAME fake table --
--- the one thing a real database does that this process's own Lua state
--- never can.
local function newFakePairProgressMySQL()
    local rows = {} -- pairKey -> tier
    local function key(k9, handler) return k9 .. ':' .. handler end
    return {
        scalar = { await = function(_sql, p)
            return rows[key(p[1], p[2])]
        end },
        insert = { await = function(_sql, p)
            local k = key(p[1], p[2])
            local existing = rows[k]
            if not existing or p[3] > existing then rows[k] = p[3] end
            return 1
        end },
    }
end

t.test('RESTART-DURABILITY: DB mode -- PairProgress_UpsertHighestTenureTier written by one K9Store instance is read back correctly by a BRAND NEW K9Store instance loaded afterward against the SAME (fake) persistent database, modelling a genuine resource restart with Config.Database.enabled = true', function()
    local fakeMysql = newFakePairProgressMySQL()

    local beforeRestartEnv = Sandbox.newEnv({ Config = { Database = { enabled = true } }, MySQL = fakeMysql, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', beforeRestartEnv)
    beforeRestartEnv.K9Store.PairProgress_UpsertHighestTenureTier('K9RESTART', 'HANDLERRESTART', 2)

    -- Model the restart: a completely FRESH env, a completely fresh
    -- server/datastore.lua load (fresh `K9Store` table, fresh
    -- `PairProgressRows` upvalue) -- the same "everything in this
    -- process is gone" reset a real FXServer restart performs -- but
    -- reusing the SAME `fakeMysql` table, standing in for the one thing
    -- that genuinely does survive a restart: a real database.
    local afterRestartEnv = Sandbox.newEnv({ Config = { Database = { enabled = true } }, MySQL = fakeMysql, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', afterRestartEnv)

    t.equals(afterRestartEnv.K9Store.PairProgress_GetHighestTenureTier('K9RESTART', 'HANDLERRESTART'), 2,
        'a value written before the (simulated) restart must still read back correctly after it, when the database is on -- this is the exact restart-proofing KNOWN_ISSUES.md used to disclose as missing')
end)

t.test('RESTART-DURABILITY: memory mode (Config.Database.enabled = false) -- the DISCLOSED, ACCEPTED limit -- a value written by one K9Store instance does NOT survive a brand new instance being loaded, because there is no real database standing behind it', function()
    local beforeRestartEnv = Sandbox.newEnv({ Config = { Database = { enabled = false } }, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', beforeRestartEnv)
    beforeRestartEnv.K9Store.PairProgress_UpsertHighestTenureTier('K9RESTART2', 'HANDLERRESTART2', 2)
    t.equals(beforeRestartEnv.K9Store.PairProgress_GetHighestTenureTier('K9RESTART2', 'HANDLERRESTART2'), 2, 'sanity: the write is visible within the SAME process, same as the guard\'s own running-uptime coverage')

    local afterRestartEnv = Sandbox.newEnv({ Config = { Database = { enabled = false } }, print = function(...) end })
    Sandbox.loadInto('../server/datastore.lua', afterRestartEnv)
    t.isNil(afterRestartEnv.K9Store.PairProgress_GetHighestTenureTier('K9RESTART2', 'HANDLERRESTART2'),
        'a genuinely fresh process (no database backing it) must NOT see a value written by a previous process -- this is the honest, disclosed boundary of what running WITHOUT a database can promise, unchanged by migration 0018 (which only closes the gap for servers that have the database on)')
end)

-- ----------------------------------------------------------------------
-- ADDITIONAL COVERAGE (coder-security pass) -- SanitizeLimit hardening.
--
-- Every current caller of a `limit`-taking accessor already clamps its own
-- value before reaching this file (server/admin.lua's ClampLimit,
-- server/leaderboard.lua's independent copy) -- these specs deliberately
-- do NOT re-test that (already covered by admin_spec.lua/leaderboard_spec.lua).
-- What they DO test is this file's OWN backstop: a malformed/hostile
-- `limit` reaching server/datastore.lua directly -- via a future caller
-- that forgets to clamp, or a bug -- must never throw an uncaught Lua error
-- out of a net event/callback handler (`string.format('%d', ...)` on a
-- non-integer-representable value, or a `>= ` comparison against a
-- non-number in the memory branch), and must never silently become an
-- unbounded or negative-LIMIT query either.
-- ----------------------------------------------------------------------

t.test('MySQL branch: a non-numeric limit (string, table, boolean) never throws -- degrades to a safe LIMIT 1 rather than erroring out of string.format', function()
    for _, badLimit in ipairs({ 'not-a-number', {}, true, false }) do
        resetCapture()
        canned = {}
        local ok, rows = pcall(MysqlStore.SearchLog_GetRecent, badLimit)
        t.isTrue(ok, ('a non-numeric limit (%s) must never throw'):format(tostring(badLimit)))
        t.equals(#rows, 0)
        t.contains(captured[1].sql, 'LIMIT 1', ('a non-numeric limit (%s) must fall back to the smallest safe default'):format(tostring(badLimit)))
    end

    -- `nil` tested separately -- a literal `nil` inside a `{ ... }` table
    -- constructor creates a hole that would silently truncate the ipairs()
    -- loop above rather than actually exercising a nil limit.
    resetCapture()
    canned = {}
    local ok, rows = pcall(MysqlStore.SearchLog_GetRecent, nil)
    t.isTrue(ok, 'a nil limit must never throw')
    t.equals(#rows, 0)
    t.contains(captured[1].sql, 'LIMIT 1')
end)

t.test('MySQL branch: a negative or zero limit is floored up to 1, never embedded as a negative/zero LIMIT (invalid SQL syntax on a real server)', function()
    resetCapture()
    canned = {}
    MysqlStore.Cert_GetHistory('CIT1', -5)
    t.contains(captured[1].sql, 'LIMIT 1')
    t.notContains(captured[1].sql, 'LIMIT -5')

    resetCapture()
    canned = {}
    MysqlStore.Cert_GetHistory('CIT1', 0)
    t.contains(captured[1].sql, 'LIMIT 1')
end)

t.test('MySQL branch: NaN and +-infinity never reach string.format\'s %d (both raise "number has no integer representation" if unsanitized) -- both degrade to a safe, finite LIMIT', function()
    local nan = 0 / 0

    resetCapture()
    canned = {}
    local ok1 = pcall(MysqlStore.XP_GetTop, nan)
    t.isTrue(ok1, 'NaN must never throw')
    t.contains(captured[1].sql, 'LIMIT 1')

    resetCapture()
    canned = {}
    local ok2 = pcall(MysqlStore.XP_GetTop, math.huge)
    t.isTrue(ok2, '+infinity must never throw')
    t.contains(captured[1].sql, 'LIMIT 100000', 'a fixed backstop ceiling, not a caller-specific business cap -- see SanitizeLimit\'s own doc comment')

    resetCapture()
    canned = {}
    local ok3 = pcall(MysqlStore.XP_GetTop, -math.huge)
    t.isTrue(ok3, '-infinity must never throw')
    t.contains(captured[1].sql, 'LIMIT 1')
end)

t.test('MySQL branch: a fractional limit is floored, never passed through with a fractional part (string.format(\'%d\', ...) raises on a non-integer-representable float)', function()
    resetCapture()
    canned = {}
    MysqlStore.SearchLog_GetByOfficer('CIT1', 10.9)
    t.contains(captured[1].sql, 'LIMIT 10')
end)

t.test('MySQL branch: a legitimate, already-clamped limit is passed through completely unchanged -- SanitizeLimit is a backstop, not a second business-rule cap', function()
    resetCapture()
    canned = {}
    MysqlStore.SearchLog_GetRecent(1000)
    t.contains(captured[1].sql, 'LIMIT 1000')
end)

t.test('Memory branch: a non-numeric/negative/NaN limit never throws against a >= comparison either, and degrades the same way as the MySQL branch', function()
    -- Scoped to a plate no other test in this file ever inserts, so this
    -- test's row count assertions can never be perturbed by fixture state
    -- any other test in this file leaves behind in the SAME long-lived
    -- MemStore instance.
    local PLATE = 'SANITIZELIMITTEST'
    MemStore.SearchLog_Insert('SANOFF1', 'police', 'vehicle', PLATE, nil, 'clean', 0, nil)
    MemStore.SearchLog_Insert('SANOFF1', 'police', 'vehicle', PLATE, nil, 'clean', 0, nil)

    for _, badLimit in ipairs({ 'nope', {}, 0 / 0, -5, -math.huge }) do
        local ok, rows = pcall(MemStore.SearchLog_GetByPlate, PLATE, badLimit)
        t.isTrue(ok, ('a bad limit (%s) must never throw in memory mode either'):format(tostring(badLimit)))
        t.equals(#rows, 1, 'floors up to the smallest safe default (1 row), never 0 and never every matching row')
    end

    local okNil, rowsNil = pcall(MemStore.SearchLog_GetByPlate, PLATE, nil)
    t.isTrue(okNil, 'a nil limit must never throw in memory mode')
    t.equals(#rowsNil, 1)

    local okInf, rowsInf = pcall(MemStore.SearchLog_GetByPlate, PLATE, math.huge)
    t.isTrue(okInf, '+infinity must never throw in memory mode')
    t.equals(#rowsInf, 2, 'capped at the backstop ceiling, far above the 2 real matching rows here -- not an unbounded read of the whole log')
end)

-- ----------------------------------------------------------------------
-- PART 4 -- SCHEMA COLLISION SAFETY NET + K9Store.WaitForSchemaCheckToSettle
-- (interaction review + fix, db-schema boot-order pass).
--
-- This part proves the SHARED PRIMITIVE in isolation -- every one of this
-- resource's own onResourceStart-driven boot reads (permissionkeycatalog.lua,
-- xptiers.lua, equipmentshop.lua) is expected to call
-- K9Store.WaitForSchemaCheckToSettle() before its own first read; the
-- REAL, end-to-end proof that two of those three files actually do so
-- correctly (including the exact "a foreign table satisfies a catalog's
-- narrower SELECT but fails the full probe" bug) lives in
-- tests/permissionkeycatalog_spec.lua and tests/xptiereditor_spec.lua's own
-- "BOOT-ORDER RACE" sections instead (this file does not load those two
-- files at all) -- this part only needs to prove the mechanism THEY both
-- depend on.
-- ----------------------------------------------------------------------

t.test('SETTLEMENT: Config.Database.enabled = false settles instantly, with zero Wait() calls -- there was never a probe to run', function()
    local waitCalls = 0
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = false } },
        Wait = function() waitCalls = waitCalls + 1 end,
        print = function(...) end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)

    t.isFalse(env.K9Store.IsDatabaseEnabled())
    t.isTrue(env.K9Store.WaitForSchemaCheckToSettle(), 'nothing to wait for when the database is off by config')
    t.equals(waitCalls, 0, 'must not poll at all -- the probe never even attempts to run when the database is off by config')
end)

t.test('SETTLEMENT: no AddEventHandler at all (a sandbox with no FXServer natives) never registers the probe -- WaitForSchemaCheckToSettle degrades to "not settled" rather than erroring or spinning', function()
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        print = function(...) end,
        -- Deliberately no AddEventHandler, no Wait -- models
        -- tests/*_spec.lua's own plain sandbox loads that never fire
        -- onResourceStart at all.
    })
    Sandbox.loadInto('../server/datastore.lua', env)

    local ok, settled = pcall(env.K9Store.WaitForSchemaCheckToSettle)
    t.isTrue(ok, 'must never throw just because no scheduler/dispatcher exists in this sandbox')
    t.isFalse(settled, 'honest "cannot confirm" answer, never a false positive "yes, settled"')
end)

t.test('SETTLEMENT: a database where every table already matches (a real, migrated install) settles true after the probe runs, DatabaseEnabled stays true', function()
    local eventHandlers = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function()
            -- Every table this resource owns, WITH its own full expected
            -- column set -- the one case that must NOT flip the fallback.
            local rows = {}
            for tableName, columns in pairs({
                k9_certifications = { 'citizenid', 'job', 'granted_by', 'granted_at', 'revoked_by', 'revoked_at', 'active' },
                k9_search_log = { 'searcher_citizenid', 'searcher_job', 'target_type', 'target_plate', 'target_citizenid', 'result', 'total_weight', 'alert_tier', 'searched_at' },
                k9_partnerships = { 'k9_citizenid', 'handler_citizenid', 'established_by', 'established_at', 'ended_by', 'ended_at', 'active' },
                k9_partnership_pair_progress = { 'k9_citizenid', 'handler_citizenid', 'highest_tenure_tier_granted' },
                k9_progression = { 'citizenid', 'xp', 'created_at', 'updated_at' },
                k9_permissions = { 'citizenid', 'permission', 'granted_by', 'granted_at', 'revoked_by', 'revoked_at', 'active' },
                k9_certification_specializations = { 'citizenid', 'job', 'specialization', 'granted_by', 'granted_at', 'revoked_by', 'revoked_at', 'active' },
                k9_runtime_feature_overrides = { 'override_key', 'kind', 'value', 'updated_by', 'updated_at' },
                k9_runtime_override_audit = { 'override_key', 'kind', 'old_value', 'new_value', 'changed_by', 'changed_at' },
                k9_tablet_theme = { 'primary_color', 'accent_color', 'background_color', 'text_color', 'density', 'header_title', 'updated_by', 'updated_at' },
                k9_tablet_theme_audit = { 'primary_color', 'accent_color', 'background_color', 'text_color', 'density', 'header_title', 'changed_by', 'changed_at' },
                k9_ped_assignments = { 'citizenid', 'model', 'original_model_hash', 'active', 'applied_by', 'applied_at', 'revoked_at' },
                k9_certification_tiers = { 'tier_key', 'label', 'ordinal', 'deleted', 'created_at', 'updated_by', 'updated_at' },
                k9_certification_tier_capabilities = { 'tier_key', 'capability_key', 'granted_by', 'granted_at' },
                k9_certification_tier_audit = { 'id', 'action', 'tier_key', 'detail', 'changed_by', 'changed_at' },
                k9_equipment_shop_locations = { 'x', 'y', 'z', 'created_by' },
                k9_equipment_shop_locations_audit = { 'location_id', 'action', 'changed_by', 'changed_at' },
                k9_xp_tiers = { 'ordinal', 'xp_threshold', 'label', 'speed_multiplier', 'scent_range_multiplier', 'updated_by', 'updated_at' },
                k9_xp_tier_audit = { 'id', 'action', 'ordinal', 'detail', 'changed_by', 'changed_at' },
                k9_individual_overrides = { 'citizenid', 'speed_multiplier', 'scent_range_multiplier', 'medkit_cooldown_multiplier', 'note', 'deleted', 'updated_by' },
                k9_individual_override_audit = { 'id', 'action', 'citizenid', 'detail', 'changed_by', 'changed_at' },
                k9_equipment_shop_items = { 'item_key', 'price', 'sort_order', 'required_tier_key', 'required_specialization', 'deleted', 'updated_by' },
                k9_equipment_shop_item_audit = { 'id', 'action', 'item_key', 'detail', 'changed_by', 'changed_at' },
                k9_permission_keys = { 'permission_key', 'label', 'description', 'deleted', 'created_at', 'updated_by', 'updated_at' },
                k9_permission_key_audit = { 'id', 'action', 'permission_key', 'detail', 'changed_by', 'changed_at' },
            }) do
                for _, col in ipairs(columns) do
                    rows[#rows + 1] = { tbl = tableName, col = col }
                end
            end
            return rows
        end } },
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = function(...) end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)
    for _, fn in ipairs(eventHandlers['onResourceStart']) do fn('john-k9') end

    t.isTrue(env.K9Store.IsDatabaseEnabled(), 'every expected table exists with every expected column -- a real, correctly migrated install')
    t.isTrue(env.K9Store.WaitForSchemaCheckToSettle())
end)

t.test('SETTLEMENT: a clean/never-installed database (every table absent -- sql/install.sql never run) settles true, but forces DatabaseEnabled FALSE (memory-only) rather than proceeding to run real queries against tables that do not exist', function()
    local eventHandlers = {}
    local printedLines = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function() return {} end } }, -- no rows at all -- no table this resource owns exists yet
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = function(line) printedLines[#printedLines + 1] = line end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)
    for _, fn in ipairs(eventHandlers['onResourceStart']) do fn('john-k9') end

    t.isFalse(env.K9Store.IsDatabaseEnabled(), 'no john-k9 table exists yet at all -- this is "the SQL was never imported", not "nothing to collide with", and must fall back to memory mode instead of letting every real query throw ER_NO_SUCH_TABLE later, mid-session, uncaught and unexplained')
    t.isTrue(env.K9Store.WaitForSchemaCheckToSettle())

    local sawExplanation = false
    for _, line in ipairs(printedLines) do
        if line:find('were not found in this database', 1, true) then sawExplanation = true end
    end
    t.isTrue(sawExplanation, 'must print a plain-English explanation naming the actual situation (SQL not yet imported), not stay silent about why memory mode kicked in')
end)

t.test('SETTLEMENT: a PARTIAL install (some but not all of our tables exist, e.g. install.sql ran but a later migration did not) falls back to memory mode ONLY for the missing tables, names exactly which features are affected, and leaves every intact table on the real database (per-table fallback, this pass -- REPLACES the old whole-resource-for-any-missing-table behavior; see server/datastore.lua\'s own VerifyTableShapesAgainstKnownSchema header for the full "why")', function()
    local eventHandlers = {}
    local printedLines = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function()
            -- Only k9_certifications exists (with its own full, correct
            -- column set) -- every other table this resource owns is
            -- absent, modelling an interrupted/out-of-date install.
            return {
                { tbl = 'k9_certifications', col = 'citizenid' },
                { tbl = 'k9_certifications', col = 'job' },
                { tbl = 'k9_certifications', col = 'granted_by' },
                { tbl = 'k9_certifications', col = 'granted_at' },
                { tbl = 'k9_certifications', col = 'revoked_by' },
                { tbl = 'k9_certifications', col = 'revoked_at' },
                { tbl = 'k9_certifications', col = 'active' },
            }
        end } },
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = function(line) printedLines[#printedLines + 1] = line end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)
    for _, fn in ipairs(eventHandlers['onResourceStart']) do fn('john-k9') end

    t.isTrue(env.K9Store.IsDatabaseEnabled(), 'the resource-wide flag must stay true -- this is not a whole-resource fallback anymore, only specific tables are affected')
    t.isTrue(env.K9Store.IsDatabaseEnabled('k9_certifications'), 'k9_certifications itself is fully intact and present -- it must keep using the real database, unaffected by every OTHER table being missing')
    t.isFalse(env.K9Store.IsDatabaseEnabled('k9_search_log'), 'k9_search_log is genuinely missing -- it alone must fall back to memory mode')
    t.isFalse(env.K9Store.IsDatabaseEnabled('k9_progression'), 'k9_progression is genuinely missing -- it alone must fall back to memory mode')
    t.isTrue(env.K9Store.WaitForSchemaCheckToSettle())

    local sawMissingList, sawFeatureName = false, false
    for _, line in ipairs(printedLines) do
        if line:find('k9_search_log', 1, true) and line:find('do not', 1, true) then sawMissingList = true end
        if line:find('search audit log', 1, true) then sawFeatureName = true end
    end
    t.isTrue(sawMissingList, 'must name at least one of the actually-missing tables so an operator can tell which migration to run')
    t.isTrue(sawFeatureName, 'must name the FEATURE (not just the bare table name) so an operator immediately understands what will not be remembered this session')
end)

t.test('SETTLEMENT: PART-INSTALLED database, CASCADE CASE -- a missing k9_certifications forces the intact k9_certification_specializations into memory mode too, even though its own columns matched (the one identified cross-table coupling -- see MISSING_TABLE_CASCADES in server/datastore.lua for the full "why")', function()
    local eventHandlers = {}
    local printedLines = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function()
            -- Every OTHER table exists and matches, EXCEPT k9_certifications
            -- itself, which is entirely absent -- modelling an operator who
            -- dropped/never migrated that one table while everything built
            -- on top of it (specializations) survived untouched.
            -- Sandbox.installedSchemaRows() (fixtures/sandbox.lua) derives
            -- the full, always-current expected table/column set directly
            -- from server/datastore.lua's own EXPECTED_TABLE_COLUMNS
            -- source, rather than a sixth hand-typed copy of that same
            -- list going stale here too (five already had, before this
            -- helper existed).
            local rows = {}
            for _, row in ipairs(Sandbox.installedSchemaRows()) do
                if row.tbl ~= 'k9_certifications' then
                    rows[#rows + 1] = row
                end
            end
            return rows
        end } },
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = function(line) printedLines[#printedLines + 1] = line end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)
    for _, fn in ipairs(eventHandlers['onResourceStart']) do fn('john-k9') end

    t.isTrue(env.K9Store.IsDatabaseEnabled(), 'resource-wide flag stays true -- all but one of this resource\'s real tables (whatever EXPECTED_TABLE_COLUMNS currently lists, minus k9_certifications here) are genuinely fine')
    t.isFalse(env.K9Store.IsDatabaseEnabled('k9_certifications'), 'k9_certifications is genuinely missing')
    t.isFalse(env.K9Store.IsDatabaseEnabled('k9_certification_specializations'), 'CASCADE: specializations must ALSO fall back to memory this session even though its own table is fully intact, because it depends on live certification state -- see MISSING_TABLE_CASCADES')
    t.isTrue(env.K9Store.IsDatabaseEnabled('k9_permissions'), 'an unrelated, uncoupled table must NOT be swept into the cascade -- only the one documented coupling is affected')
    t.isTrue(env.K9Store.IsDatabaseEnabled('k9_progression'), 'an unrelated, uncoupled table must NOT be swept into the cascade')

    local sawCascadeExplanation = false
    for _, line in ipairs(printedLines) do
        if line:find('k9_certification_specializations', 1, true) and line:find('this table itself is fine', 1, true) then sawCascadeExplanation = true end
    end
    t.isTrue(sawCascadeExplanation, 'the console message must explain WHY a fine table is also running in memory, not just list it bare')
end)

t.test('SETTLEMENT: a real collision (a foreign table sharing one of our names) settles true, forces DatabaseEnabled false, and names the offending table', function()
    local eventHandlers = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function()
            -- A foreign `k9_certifications` with only 2 of the 7 columns
            -- this resource's own EXPECTED_TABLE_COLUMNS checks for it.
            return {
                { tbl = 'k9_certifications', col = 'citizenid' },
                { tbl = 'k9_certifications', col = 'active' },
            }
        end } },
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = function(...) end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)
    for _, fn in ipairs(eventHandlers['onResourceStart']) do fn('john-k9') end

    t.isFalse(env.K9Store.IsDatabaseEnabled(), 'a real collision must force memory-only mode for the rest of this process')
    t.isTrue(env.K9Store.WaitForSchemaCheckToSettle())
end)

t.test('SETTLEMENT: the probe query throwing synchronously still settles (the probe\'s own pre-existing "degrade to no collision found" policy is unchanged by this pass) -- DatabaseEnabled stays true', function()
    local eventHandlers = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function() error('simulated: restricted DB user, no SELECT on INFORMATION_SCHEMA') end } },
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = function(...) end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)
    for _, fn in ipairs(eventHandlers['onResourceStart']) do fn('john-k9') end

    t.isTrue(env.K9Store.IsDatabaseEnabled(), 'a probe that cannot run at all degrades to "no collision found" -- unchanged, pre-existing policy')
    t.isTrue(env.K9Store.WaitForSchemaCheckToSettle(), 'settled is still true -- the probe reached its own end via its internal pcall, it just could not determine anything')
end)

t.test('SETTLEMENT: a probe that never resumes (a hung query, not an error) makes WaitForSchemaCheckToSettle give up after a BOUNDED number of polls, never spin forever', function()
    local eventHandlers = {}
    local env = Sandbox.newEnv({
        Config = { Database = { enabled = true } },
        MySQL = { query = { await = function() return coroutine.yield() end } }, -- yields, never resumed by this test
        AddEventHandler = function(name, fn)
            eventHandlers[name] = eventHandlers[name] or {}
            eventHandlers[name][#eventHandlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'john-k9' end,
        Wait = function(_ms) coroutine.yield() end,
        print = function(...) end,
    })
    Sandbox.loadInto('../server/datastore.lua', env)

    -- Fire the probe's own onResourceStart handler in its own coroutine --
    -- it suspends immediately (inside MySQL.query.await) and this test
    -- deliberately never resumes it, modelling a database that is
    -- reachable but never answers.
    local probeCo = coroutine.create(eventHandlers['onResourceStart'][1])
    local ok = coroutine.resume(probeCo, 'john-k9')
    t.isTrue(ok)
    t.equals(coroutine.status(probeCo), 'suspended')

    -- A SEPARATE coroutine, standing in for any real catalog's own boot
    -- read, calling the exact same shared primitive every real caller uses.
    local settled
    local waiterCo = coroutine.create(function() settled = env.K9Store.WaitForSchemaCheckToSettle() end)

    local resumes = 0
    while coroutine.status(waiterCo) ~= 'dead' and resumes < 200 do
        local resumeOk, err = coroutine.resume(waiterCo)
        if not resumeOk then error('waiter coroutine errored: ' .. tostring(err)) end
        resumes = resumes + 1
    end

    t.isTrue(resumes < 200, 'must give up within a bounded number of polls, never spin forever waiting on a probe that never answers')
    t.equals(coroutine.status(waiterCo), 'dead', 'the waiting coroutine must finish (give up), not remain permanently suspended')
    t.isFalse(settled, 'unknown must be reported honestly as unknown -- callers are responsible for treating this as "assume collision" for their own boot-time read')
end)

-- ----------------------------------------------------------------------
-- PART 4 -- GAP 2 CLOSURE: the eight catalog-edit audit tables (cert
-- tiers, permission keys, XP tiers, equipment shop items, equipment shop
-- locations, per-K9 individual overrides, runtime feature/tunable
-- overrides, tablet theme) were WRITE-ONLY until this pass -- every
-- `*Audit_Append`/`*Audit_Insert` writer had no matching read accessor
-- anywhere in this resource, so every catalog edit high command made was
-- logged perfectly and invisible forever. These eight new `*_GetRecent`
-- accessors are the read side; see server/admin.lua's own new
-- `john-k9:server:tabletAuditCatalog` callback for the ONE generic,
-- catalog-name-parameterized tablet consumer built on top of them (tested
-- in tests/admin_spec.lua, not here -- this file owns server/datastore.lua
-- alone). Same SafeQuery contract as every other accessor in this file
-- (K9Store.SearchLog_GetRecent's own shape, PART 1/2 above): most recent
-- first, bounded by SanitizeLimit, NEVER throws, ALWAYS a table.
-- ----------------------------------------------------------------------

t.test('MySQL branch: every new catalog-audit *_GetRecent accessor queries its OWN table, most-recent-first, with a bound LIMIT -- never another catalog\'s table', function()
    local cases = {
        { fn = 'OverrideAudit_GetRecent', tableName = 'k9_runtime_override_audit' },
        { fn = 'ThemeAudit_GetRecent', tableName = 'k9_tablet_theme_audit' },
        { fn = 'ShopLocationAudit_GetRecent', tableName = 'k9_equipment_shop_locations_audit' },
        { fn = 'TierAudit_GetRecent', tableName = 'k9_certification_tier_audit' },
        { fn = 'PermKeyAudit_GetRecent', tableName = 'k9_permission_key_audit' },
        { fn = 'XPTierAudit_GetRecent', tableName = 'k9_xp_tier_audit' },
        { fn = 'IndividualOverrideAudit_GetRecent', tableName = 'k9_individual_override_audit' },
        { fn = 'ShopItemAudit_GetRecent', tableName = 'k9_equipment_shop_item_audit' },
    }
    for _, case in ipairs(cases) do
        resetCapture()
        canned = { { changed_by = 'CANNED-' .. case.tableName } }
        local rows = MysqlStore[case.fn](5)
        t.equals(#captured, 1, case.fn .. ' must issue exactly one query')
        t.equals(captured[1].kind, 'query')
        t.contains(captured[1].sql, 'FROM ' .. case.tableName, case.fn .. ' must read its own table')
        t.contains(captured[1].sql, 'ORDER BY id DESC', case.fn .. ' must return most-recent-first')
        t.contains(captured[1].sql, 'LIMIT 5', case.fn .. ' must embed the sanitized limit')
        t.equals(#rows, 1)
        t.equals(rows[1].changed_by, 'CANNED-' .. case.tableName, case.fn .. ' must pass the query result through unchanged')
    end
end)

t.test('MySQL branch: every new catalog-audit *_GetRecent accessor degrades to {} (never throws) on a thrown query error', function()
    local fns = {
        'OverrideAudit_GetRecent', 'ThemeAudit_GetRecent', 'ShopLocationAudit_GetRecent',
        'TierAudit_GetRecent', 'PermKeyAudit_GetRecent', 'XPTierAudit_GetRecent',
        'IndividualOverrideAudit_GetRecent', 'ShopItemAudit_GetRecent',
    }
    for _, fn in ipairs(fns) do
        resetCapture()
        canned = { throw = 'simulated connection drop' }
        local ok, rows = pcall(MysqlStore[fn], 10)
        t.isTrue(ok, fn .. ' must never let a thrown query error escape to the caller')
        t.equals(#rows, 0, fn .. ' must degrade to an empty table on a thrown error')
    end
end)

t.test('Memory: OverrideAudit_GetRecent -- append order reversed (most recent first), limit respected', function()
    t.isTrue(MemStore.OverrideAudit_Append('gap2.testkey', 'feature', 'old1', 'new1', 'GAP2-A'))
    t.isTrue(MemStore.OverrideAudit_Append('gap2.testkey', 'feature', 'new1', 'new2', 'GAP2-B'))
    t.isTrue(MemStore.OverrideAudit_Append('gap2.testkey', 'feature', 'new2', 'new3', 'GAP2-C'))
    local top2 = MemStore.OverrideAudit_GetRecent(2)
    t.equals(#top2, 2)
    t.equals(top2[1].changed_by, 'GAP2-C', 'most recent append must be first')
    t.equals(top2[1].new_value, 'new3')
    t.equals(top2[2].changed_by, 'GAP2-B')
end)

t.test('Memory: ThemeAudit_GetRecent -- append order reversed, limit respected', function()
    t.isTrue(MemStore.ThemeAudit_Append('#111111', '#222222', '#333333', '#444444', 'comfortable', 'Theme A', 'GAP2-A'))
    t.isTrue(MemStore.ThemeAudit_Append('#aaaaaa', '#bbbbbb', '#cccccc', '#dddddd', 'compact', 'Theme B', 'GAP2-B'))
    local top1 = MemStore.ThemeAudit_GetRecent(1)
    t.equals(#top1, 1)
    t.equals(top1[1].changed_by, 'GAP2-B')
    t.equals(top1[1].header_title, 'Theme B')
end)

t.test('Memory: ShopLocationAudit_GetRecent -- append order reversed, limit respected', function()
    t.isTrue(MemStore.ShopLocationAudit_Insert(1, 'add', 1.0, 2.0, 3.0, 90.0, 'a_c_husky', 'WORLD_HUMAN_STAND_IMPATIENT', 'Loc A', 'GAP2-A'))
    t.isTrue(MemStore.ShopLocationAudit_Insert(1, 'move', 4.0, 5.0, 6.0, 180.0, 'a_c_husky', 'WORLD_HUMAN_STAND_IMPATIENT', 'Loc A', 'GAP2-B'))
    local rows = MemStore.ShopLocationAudit_GetRecent(10)
    t.isTrue(#rows >= 2)
    t.equals(rows[1].changed_by, 'GAP2-B', 'most recent append must be first')
    t.equals(rows[1].action, 'move')
    t.equals(rows[2].changed_by, 'GAP2-A')
end)

t.test('Memory: TierAudit_GetRecent -- append order reversed, limit respected', function()
    t.isTrue(MemStore.TierAudit_Append('tier_create', 'gap2tier', 'label=Gap2', 'GAP2-A'))
    t.isTrue(MemStore.TierAudit_Append('tier_update', 'gap2tier', 'label=Gap2Updated', 'GAP2-B'))
    local top1 = MemStore.TierAudit_GetRecent(1)
    t.equals(#top1, 1)
    t.equals(top1[1].changed_by, 'GAP2-B')
    t.equals(top1[1].action, 'tier_update')
end)

t.test('Memory: PermKeyAudit_GetRecent -- append order reversed, limit respected, starts empty (untouched by any earlier test in this file)', function()
    t.equals(#MemStore.PermKeyAudit_GetRecent(1000), 0, 'sanity: no other test in this file touches k9_permission_key_audit')
    t.isTrue(MemStore.PermKeyAudit_Append('permkey_create', 'gap2.key', 'label="Gap2"', 'GAP2-A'))
    t.isTrue(MemStore.PermKeyAudit_Append('permkey_delete', 'gap2.key', 'tombstoned', 'GAP2-B'))
    local rows = MemStore.PermKeyAudit_GetRecent(10)
    t.equals(#rows, 2)
    t.equals(rows[1].action, 'permkey_delete', 'most recent append must be first')
    t.equals(rows[2].action, 'permkey_create')
end)

t.test('Memory: XPTierAudit_GetRecent -- append order reversed, limit respected, starts empty', function()
    t.equals(#MemStore.XPTierAudit_GetRecent(1000), 0, 'sanity: no other test in this file touches k9_xp_tier_audit')
    t.isTrue(MemStore.XPTierAudit_Append(2, 'xpThreshold=1250 -> 1300', 'GAP2-A'))
    t.isTrue(MemStore.XPTierAudit_Append(2, 'xpThreshold=1300 -> 1400', 'GAP2-B'))
    local rows = MemStore.XPTierAudit_GetRecent(10)
    t.equals(#rows, 2)
    t.equals(rows[1].changed_by, 'GAP2-B', 'most recent append must be first')
    t.equals(rows[1].ordinal, 2)
end)

t.test('Memory: IndividualOverrideAudit_GetRecent -- append order reversed, limit respected', function()
    t.isTrue(MemStore.IndividualOverrideAudit_Append('override_create', 'GAP2CIT', 'speedMultiplier=3.0', 'GAP2-A'))
    t.isTrue(MemStore.IndividualOverrideAudit_Append('override_reset', 'GAP2CIT', 'reset', 'GAP2-B'))
    local top1 = MemStore.IndividualOverrideAudit_GetRecent(1)
    t.equals(#top1, 1)
    t.equals(top1[1].changed_by, 'GAP2-B')
    t.equals(top1[1].action, 'override_reset')
end)

t.test('Memory: ShopItemAudit_GetRecent -- append order reversed, limit respected, starts empty', function()
    t.equals(#MemStore.ShopItemAudit_GetRecent(1000), 0, 'sanity: no other test in this file touches k9_equipment_shop_item_audit')
    t.isTrue(MemStore.ShopItemAudit_Append('item_create', 'gap2_item', 'price=100', 'GAP2-A'))
    t.isTrue(MemStore.ShopItemAudit_Append('item_update', 'gap2_item', 'price=100 -> 150', 'GAP2-B'))
    local rows = MemStore.ShopItemAudit_GetRecent(10)
    t.equals(#rows, 2)
    t.equals(rows[1].action, 'item_update', 'most recent append must be first')
    t.equals(rows[2].action, 'item_create')
end)

t.test('Memory: every new catalog-audit *_GetRecent accessor never throws on a non-numeric/negative/NaN limit -- same SanitizeLimit backstop every other accessor in this file already relies on', function()
    local fns = {
        'OverrideAudit_GetRecent', 'ThemeAudit_GetRecent', 'ShopLocationAudit_GetRecent',
        'TierAudit_GetRecent', 'PermKeyAudit_GetRecent', 'XPTierAudit_GetRecent',
        'IndividualOverrideAudit_GetRecent', 'ShopItemAudit_GetRecent',
    }
    for _, fn in ipairs(fns) do
        for _, badLimit in ipairs({ 'notanumber', {}, true, -5, 0, 0/0 }) do
            local ok, rows = pcall(MemStore[fn], badLimit)
            t.isTrue(ok, fn .. ' must never throw on limit=' .. tostring(badLimit))
            t.isTrue(type(rows) == 'table', fn .. ' must always return a table')
        end
    end
end)

-- ----------------------------------------------------------------------
-- PART 5 -- k9_personnel (migration 0020, docs/history/ROSTER_SPEC.md §3/§4). The
-- K9/Handler roster assignment + callsign table -- one active row per
-- (citizenid, job), plus a SECOND invariant this table alone has: at most
-- one active callsign per department, case-insensitive, shared across
-- BOTH roles (docs/history/ROSTER_SPEC.md §4's combined-namespace decision).
-- ----------------------------------------------------------------------

t.test('MySQL branch: Personnel_GetActiveRow forwards citizenid/job and passes the row through', function()
    resetCapture()
    canned = { role = 'k9', callsign = '12-Adam-1', granted_by = 'HC1', granted_at = '2026-01-01 00:00:00' }
    local row = MysqlStore.Personnel_GetActiveRow('CITP1', 'police')
    t.equals(#captured, 1)
    t.equals(captured[1].kind, 'single')
    t.contains(captured[1].sql, 'FROM k9_personnel')
    t.contains(captured[1].sql, 'active = 1')
    t.equals(captured[1].params[1], 'CITP1')
    t.equals(captured[1].params[2], 'police')
    t.equals(row.role, 'k9')
    t.equals(row.callsign, '12-Adam-1')
end)

t.test('MySQL branch: Personnel_GetActiveRowsByJob queries by job only, degrades to {} on a thrown query error', function()
    resetCapture()
    canned = { { citizenid = 'CITP2', role = 'handler', callsign = nil } }
    local rows = MysqlStore.Personnel_GetActiveRowsByJob('sheriff')
    t.equals(captured[1].kind, 'query')
    t.contains(captured[1].sql, 'FROM k9_personnel')
    t.equals(captured[1].params[1], 'sheriff')
    t.equals(#rows, 1)
    t.equals(rows[1].role, 'handler')

    resetCapture()
    canned = { throw = 'simulated connection drop' }
    local ok, rowsOnFail = pcall(MysqlStore.Personnel_GetActiveRowsByJob, 'sheriff')
    t.isTrue(ok, 'must never let a thrown query error escape to the caller')
    t.equals(#rowsOnFail, 0)
end)

t.test('MySQL branch: Personnel_Insert forwards citizenid/job/role/grantedBy in column order; a thrown duplicate error propagates unchanged', function()
    resetCapture()
    canned = 42
    local id = MysqlStore.Personnel_Insert('CITP3', 'police', 'k9', 'HC1')
    t.equals(id, 42)
    t.equals(captured[1].kind, 'insert')
    t.contains(captured[1].sql, 'INSERT INTO k9_personnel')
    t.equals(captured[1].params[1], 'CITP3')
    t.equals(captured[1].params[2], 'police')
    t.equals(captured[1].params[3], 'k9')
    t.equals(captured[1].params[4], 'HC1')

    resetCapture()
    canned = { throw = { errno = 1062, message = 'ER_DUP_ENTRY' } }
    local ok, err = pcall(MysqlStore.Personnel_Insert, 'CITP3', 'police', 'k9', 'HC1')
    t.isFalse(ok)
    t.equals(err.errno, 1062, 'the real oxmysql-shaped duplicate error must reach the caller exactly as thrown')
end)

t.test('MySQL branch: Personnel_UpdateRole clears the callsign in the SAME statement (docs/history/ROSTER_SPEC.md §4)', function()
    resetCapture()
    canned = 1
    MysqlStore.Personnel_UpdateRole('CITP4', 'police', 'handler')
    t.equals(captured[1].kind, 'update')
    t.contains(captured[1].sql, 'SET role = ?, callsign = NULL')
    t.equals(captured[1].params[1], 'handler')
    t.equals(captured[1].params[2], 'CITP4')
    t.equals(captured[1].params[3], 'police')
end)

t.test('MySQL branch: Personnel_SetCallsign forwards a real callsign, and forwards nil to clear it', function()
    resetCapture()
    canned = 1
    MysqlStore.Personnel_SetCallsign('CITP5', 'police', '12-Adam-1')
    t.equals(captured[1].kind, 'update')
    t.contains(captured[1].sql, 'SET callsign = ?')
    t.equals(captured[1].params[1], '12-Adam-1')

    resetCapture()
    canned = 1
    MysqlStore.Personnel_SetCallsign('CITP5', 'police', nil)
    t.isNil(captured[1].params[1], 'a nil callsign must be forwarded as-is (clears the column), never coerced to a placeholder string')
end)

t.test('MySQL branch: Personnel_ClearActive forwards clearedBy/citizenid/job in the documented order', function()
    resetCapture()
    canned = 1
    MysqlStore.Personnel_ClearActive('CITP6', 'police', 'HC1')
    t.equals(captured[1].kind, 'update')
    t.contains(captured[1].sql, 'active = 0')
    t.equals(captured[1].params[1], 'HC1')
    t.equals(captured[1].params[2], 'CITP6')
    t.equals(captured[1].params[3], 'police')
end)

t.test('Memory: a fresh process has no personnel rows at all -- fail-closed by construction', function()
    t.isNil(MemStore.Personnel_GetActiveRow('NOBODY', 'police'))
    t.equals(#MemStore.Personnel_GetActiveRowsByJob('police'), 0)
end)

t.test('Memory: Personnel_Insert/GetActiveRow round-trip; a fresh row always starts with a NULL callsign', function()
    local id = MemStore.Personnel_Insert('CITQ1', 'police', 'k9', 'HC1')
    t.isNotNil(id)
    local row = MemStore.Personnel_GetActiveRow('CITQ1', 'police')
    t.equals(row.id, id)
    t.equals(row.role, 'k9')
    t.isNil(row.callsign, 'docs/history/ROSTER_SPEC.md §4: a fresh assignment never starts with a callsign')
    t.equals(row.granted_by, 'HC1')
end)

t.test('Memory: TWO ACTIVE ROWS FOR THE SAME (citizenid, job) IS IMPOSSIBLE -- Personnel_Insert throws the real 1062-shaped error', function()
    MemStore.Personnel_Insert('CITQ2', 'police', 'k9', 'HC1')
    local ok, err = pcall(MemStore.Personnel_Insert, 'CITQ2', 'police', 'handler', 'HC1')
    t.isFalse(ok, 'a second active personnel row for the same (citizenid, job) must be refused, not silently created')
    t.equals(err.errno, 1062, 'must be the exact shape every existing IsDuplicateKeyError helper already recognizes')
end)

t.test('Memory: a citizenid may hold INDEPENDENT roster rows in two different departments at once', function()
    MemStore.Personnel_Insert('CITQ3', 'police', 'k9', 'HC1')
    local ok = pcall(MemStore.Personnel_Insert, 'CITQ3', 'sheriff', 'handler', 'HC1')
    t.isTrue(ok, 'holding an active roster row in one department must never block one in a different department')
    t.equals(MemStore.Personnel_GetActiveRow('CITQ3', 'police').role, 'k9')
    t.equals(MemStore.Personnel_GetActiveRow('CITQ3', 'sheriff').role, 'handler')
end)

t.test('Memory: FIRE-THEN-REHIRE produces a NEW row and does NOT resurrect the old callsign', function()
    local firstId = MemStore.Personnel_Insert('CITQ4', 'police', 'k9', 'HC1')
    t.isTrue(MemStore.Personnel_SetCallsign('CITQ4', 'police', '9-Lincoln-3') > 0)
    t.equals(MemStore.Personnel_GetActiveRow('CITQ4', 'police').callsign, '9-Lincoln-3')

    -- Fire: clear the active row (mirrors ClearPersonnelRowForCitizenJob).
    t.equals(MemStore.Personnel_ClearActive('CITQ4', 'police', 'HC1'), 1)
    t.isNil(MemStore.Personnel_GetActiveRow('CITQ4', 'police'), 'a cleared row must no longer read as active')

    -- Re-hire: a brand-new row, never a revived one.
    local secondId = MemStore.Personnel_Insert('CITQ4', 'police', 'k9', 'HC1')
    t.isTrue(secondId ~= firstId, 'a re-hire must be a NEW row, not the same history row reactivated')
    local row = MemStore.Personnel_GetActiveRow('CITQ4', 'police')
    t.equals(row.id, secondId)
    t.isNil(row.callsign, 'a re-hire must never resurrect the old, now-inactive row\'s callsign')
end)

t.test('Memory: Personnel_UpdateRole clears the callsign in the same action', function()
    MemStore.Personnel_Insert('CITQ5', 'police', 'k9', 'HC1')
    MemStore.Personnel_SetCallsign('CITQ5', 'police', '7-David-2')
    t.equals(MemStore.Personnel_UpdateRole('CITQ5', 'police', 'handler'), 1)
    local row = MemStore.Personnel_GetActiveRow('CITQ5', 'police')
    t.equals(row.role, 'handler')
    t.isNil(row.callsign, 'a role change must clear the callsign -- a K9 callsign and a handler callsign mean different things')
end)

t.test('Memory: CALLSIGN COLLISION WITHIN A DEPARTMENT is refused, case-insensitively, and does NOT overwrite the existing holder', function()
    MemStore.Personnel_Insert('CITQ6A', 'police', 'k9', 'HC1')
    MemStore.Personnel_Insert('CITQ6B', 'police', 'handler', 'HC1')
    t.isTrue(MemStore.Personnel_SetCallsign('CITQ6A', 'police', '5-Mary-9') > 0)

    -- Same department, different citizenid, same callsign, different case.
    local ok, err = pcall(MemStore.Personnel_SetCallsign, 'CITQ6B', 'police', '5-mary-9')
    t.isFalse(ok, 'a case-insensitive collision within the same department must be refused')
    t.equals(err.errno, 1062)

    -- The ORIGINAL holder's callsign must be untouched.
    t.equals(MemStore.Personnel_GetActiveRow('CITQ6A', 'police').callsign, '5-Mary-9', 'a rejected collision must never silently overwrite the existing holder')
    -- The rejected caller must not have picked up the callsign either.
    t.isNil(MemStore.Personnel_GetActiveRow('CITQ6B', 'police').callsign)
end)

t.test('Memory: a callsign collision across the TWO ROSTERS in the SAME department is also rejected (combined-namespace decision, §4)', function()
    -- CITQ7A is a K9, CITQ7B is a HANDLER, same department -- the
    -- combined-namespace decision means these two share one callsign
    -- pool, not two separate ones.
    MemStore.Personnel_Insert('CITQ7A', 'sheriff', 'k9', 'HC1')
    MemStore.Personnel_Insert('CITQ7B', 'sheriff', 'handler', 'HC1')
    t.isTrue(MemStore.Personnel_SetCallsign('CITQ7A', 'sheriff', 'Adam-12') > 0)

    local ok = pcall(MemStore.Personnel_SetCallsign, 'CITQ7B', 'sheriff', 'ADAM-12')
    t.isFalse(ok, 'a K9\'s callsign and a handler\'s callsign in the SAME department must share one namespace')
end)

t.test('Memory: the SAME callsign in a DIFFERENT department is not a collision -- the namespace is scoped per department', function()
    MemStore.Personnel_Insert('CITQ8A', 'police', 'k9', 'HC1')
    MemStore.Personnel_Insert('CITQ8B', 'sheriff', 'k9', 'HC1')
    t.isTrue(MemStore.Personnel_SetCallsign('CITQ8A', 'police', '1-Adam-1') > 0)
    local ok = pcall(MemStore.Personnel_SetCallsign, 'CITQ8B', 'sheriff', '1-Adam-1')
    t.isTrue(ok, 'the same callsign text in a DIFFERENT department must never collide')
end)

t.test('Memory: re-saving a citizenid\'s own unchanged callsign is never reported as a collision against itself', function()
    MemStore.Personnel_Insert('CITQ9', 'police', 'k9', 'HC1')
    MemStore.Personnel_SetCallsign('CITQ9', 'police', '2-Baker-4')
    local ok = pcall(MemStore.Personnel_SetCallsign, 'CITQ9', 'police', '2-Baker-4')
    t.isTrue(ok, 'a citizenid re-saving its own current callsign must never be treated as a collision against itself')
end)

t.test('Memory: Personnel_SetCallsign(nil) clears an existing callsign without error', function()
    MemStore.Personnel_Insert('CITQ10', 'police', 'k9', 'HC1')
    MemStore.Personnel_SetCallsign('CITQ10', 'police', '3-Charlie-7')
    t.equals(MemStore.Personnel_SetCallsign('CITQ10', 'police', nil), 1)
    t.isNil(MemStore.Personnel_GetActiveRow('CITQ10', 'police').callsign)
end)

t.test('Memory: Personnel_ClearActive affects zero rows for a citizenid with no active row, one for a real one', function()
    t.equals(MemStore.Personnel_ClearActive('NOBODY-PERSONNEL', 'police', 'HC1'), 0)
    MemStore.Personnel_Insert('CITQ11', 'police', 'k9', 'HC1')
    t.equals(MemStore.Personnel_ClearActive('CITQ11', 'police', 'HC1'), 1)
    t.equals(MemStore.Personnel_ClearActive('CITQ11', 'police', 'HC1'), 0, 'clearing an already-inactive row affects zero rows, same as the real UPDATE')
end)

t.test('Memory: Personnel_GetActiveRowsByJob never leaks a different department\'s rows', function()
    MemStore.Personnel_Insert('CITQ12', 'police', 'k9', 'HC1')
    MemStore.Personnel_Insert('CITQ13', 'sheriff', 'handler', 'HC1')
    local policeRows = MemStore.Personnel_GetActiveRowsByJob('police')
    for _, row in ipairs(policeRows) do
        t.isTrue(row.citizenid ~= 'CITQ13', 'a sheriff row must never appear in a police-scoped read')
    end
end)

os.exit(t.summary())
