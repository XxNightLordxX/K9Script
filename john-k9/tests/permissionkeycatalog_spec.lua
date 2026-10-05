--[[
    tests/permissionkeycatalog_spec.lua

    Tests server/permissionkeycatalog.lua -- the owner-directed "high
    command can add/relabel/remove PERMISSION KEYS at runtime" pass -- and
    its one seam into server/permissions.lua (IsValidPermissionKey /
    PermissionLabelFor / GrantPermission's new PermissionKeyEditMutex
    acquisition), against the REAL, unmodified production files, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/certtiers_spec.lua
    closely (read that file first -- this one follows its fake-database/
    two-boot conventions) and tests/permissions_spec.lua for the
    k9_permissions grant-row stub shape.

    ONE SHARED FAKE DATABASE covering FOUR real tables this pass's two files
    read/write through K9Store: k9_permission_keys, k9_permission_key_audit
    (this file's own new tables) and k9_permissions (server/permissions.lua's
    existing grant-row table, read via the SAME K9Store instance since both
    production files share one `require`-free Lua env in every fixture
    below) -- mutated by the real production callbacks/functions exactly
    like a real database would be.

    NOT COVERED HERE (disclosed, not silently skipped): the cross-file
    PermissionKeyEditMutex race this pass closes between
    server/permissionkeycatalog.lua's own DeleteKey/UpsertKey and
    server/permissions.lua's GrantPermission is not exercised via two
    ACTUAL concurrent coroutines (this harness has no such primitive,
    identical disclosed limitation as tests/certtiers_spec.lua's own header
    states for TierEditMutex). What IS covered: PermissionKeyEditMutex
    exists, is a real mutex, and GrantPermission genuinely observes it (a
    pre-held lock makes GrantPermission report 'busy' rather than writing a
    grant row) -- proving the wiring is real, not merely declared.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @return table world
local function newWorld()
    return {
        permKeys = {},     -- permission_key -> { label, description, deleted, updated_by }
        permKeyAudit = {}, -- array of { action, permission_key, detail, changed_by }
        grants = {},       -- array of { id, citizenid, permission, granted_by, active }
        nextGrantId = 0,
        forceKeysQueryError = false, -- toggled mid-test for the FAIL-CLOSED section
    }
end

--- @param world table
--- @param citizenid string
--- @param permission string
--- @return table?
local function findActiveGrant(world, citizenid, permission)
    for _, row in ipairs(world.grants) do
        if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
            return row
        end
    end
    return nil
end

--- @param world table
--- @return table mysql
local function makeMysqlStub(world)
    return {
        query = { await = function(sql, params)
            if world.forceKeysQueryError and sql:find('SELECT permission_key, label, description, deleted FROM k9_permission_keys', 1, true) then
                error('simulated k9_permission_keys read failure')
            end
            if sql:find('SELECT permission_key, label, description, deleted FROM k9_permission_keys', 1, true) then
                local out = {}
                for key, row in pairs(world.permKeys) do
                    out[#out + 1] = { permission_key = key, label = row.label, description = row.description, deleted = row.deleted }
                end
                return out
            elseif sql:find('SELECT deleted FROM k9_permission_keys WHERE permission_key = ?', 1, true) then
                local row = world.permKeys[params[1]]
                if row then return { { deleted = row.deleted } } end
                return {}
            elseif sql:find('INSERT INTO k9_permission_keys', 1, true) then
                local key, label, description, updatedBy = params[1], params[2], params[3], params[4]
                local deletedLiteral = sql:find('VALUES (?, ?, ?, 1, ?)', 1, true) and 1 or 0
                world.permKeys[key] = { label = label, description = description, deleted = deletedLiteral, updated_by = updatedBy }
                return {}
            elseif sql:find('INSERT INTO k9_permission_key_audit', 1, true) then
                world.permKeyAudit[#world.permKeyAudit + 1] = { action = params[1], permission_key = params[2], detail = params[3], changed_by = params[4] }
                return {}
            elseif sql:find('SELECT permission FROM k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(world.grants) do
                    if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                end
                return out
            elseif sql:find('SELECT permission, granted_by, granted_at FROM k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(world.grants) do
                    if row.citizenid == params[1] and row.active == 1 then
                        out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = '2026-01-01 00:00:00' }
                    end
                end
                return out
            elseif sql:find('SELECT citizenid, granted_by, granted_at FROM k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(world.grants) do
                    if row.permission == params[1] and row.active == 1 then
                        out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = '2026-01-01 00:00:00' }
                    end
                end
                return out
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.query.await SQL: ' .. tostring(sql))
        end },
        scalar = { await = function(sql, params)
            if sql:find('SELECT id FROM k9_permissions WHERE citizenid = ? AND permission = ? AND active = 1', 1, true) then
                local row = findActiveGrant(world, params[1], params[2])
                return row and row.id or nil
            elseif sql:find('SELECT COUNT(*) FROM k9_permissions WHERE permission = ? AND active = 1', 1, true) then
                local count = 0
                for _, row in ipairs(world.grants) do
                    if row.permission == params[1] and row.active == 1 then count = count + 1 end
                end
                return count
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.scalar.await SQL: ' .. tostring(sql))
        end },
        insert = { await = function(sql, params)
            if sql:find('INSERT INTO k9_permissions', 1, true) then
                world.nextGrantId = world.nextGrantId + 1
                world.grants[#world.grants + 1] = { id = world.nextGrantId, citizenid = params[1], permission = params[2], granted_by = params[3], active = 1 }
                return world.nextGrantId
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.insert.await SQL: ' .. tostring(sql))
        end },
        update = { await = function(sql, params)
            if sql:find('UPDATE k9_permissions SET active = 0', 1, true) then
                local revokedBy, citizenid, permission = params[1], params[2], params[3]
                local affected = 0
                for _, row in ipairs(world.grants) do
                    if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                        row.active = 0
                        row.revoked_by = revokedBy
                        affected = affected + 1
                    end
                end
                return affected
            end
            error('permissionkeycatalog_spec test stub: unhandled MySQL.update.await SQL: ' .. tostring(sql))
        end },
    }
end

local DEFAULT_PERMISSIONS = {
    ['k9.access']  = { label = 'Use K9 abilities', description = 'x' },
    ['k9.certify'] = { label = 'Certify and decertify others', description = 'x' },
    ['k9.audit']   = { label = 'View the audit records', description = 'x' },
    ['k9.givexp']  = { label = 'Grant XP', description = 'x' },
}

--- @param opts table? -- { world, database, isHighCommand (pass exactly `false`,
---   not merely nil/omitted, to leave IsHighCommand entirely UNDEFINED in the
---   sandbox env -- the strong form of the gating-function-undefined failure
---   mode, distinct from every other caller's isHighCommand, which is always a
---   real, callable function that merely RETURNS false for a non-HC source),
---   permissions, features, loadCatalog (default true) }
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
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- HC_SOURCE (100, the constant every test's own isHighCommand stub
    -- authorizes) always resolves to a real player/citizenid by default --
    -- GrantPermission's own granter-resolution step (`exports.qbx_core:
    -- GetPlayer(granterSrc)`) needs this for EVERY call, not just the tests
    -- that care about a specific target. Merged with (never silently
    -- replaced by) whatever `opts.playersBySource` a test supplies, so a
    -- test adding its own TARGET entry does not have to also remember to
    -- re-declare the granter.
    local playersBySource = { [100] = { PlayerData = { citizenid = 'HC_CIT', source = 100 } } }
    for src, p in pairs(opts.playersBySource or {}) do playersBySource[src] = p end
    local playersByCitizenId = {}
    for _, p in pairs(playersBySource) do
        if p.PlayerData and p.PlayerData.citizenid then playersByCitizenId[p.PlayerData.citizenid] = p end
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    -- opts.isHighCommand == false (an explicit false, never merely nil/omitted)
    -- means "never define IsHighCommand in the sandbox env at all" -- see this
    -- function's own doc comment above. Every other caller gets a real, callable
    -- stub (default: always denies).
    local omitIsHighCommand = opts.isHighCommand == false
    local isHighCommand = (not omitIsHighCommand) and (opts.isHighCommand or function() return false end) or nil
    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local Config = {
        Features = opts.features or { PermissionGrants = true, CommandTablet = false, BiteAndHold = true },
        Permissions = opts.permissions or DEFAULT_PERMISSIONS,
        Departments = opts.departments or { police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
        Database = opts.database, -- nil (absent) by default -> real-DB mode, per K9Store's own fail-safe default
    }

    local fakeNow = { value = 0 }
    -- COULD-NOT-DETERMINE RESYNC SWEEP: server/permissions.lua calls
    -- CreateThread(...) unconditionally at file-load time (the resync sweep
    -- for PermissionCheckUnresolved, deliberately not feature-gated). Any
    -- fixture loading that file needs a REAL CreateThread/Wait pair -- a
    -- no-op stub either throws or loops forever, since the sweep body is
    -- `while true do Wait(x) ... end`.
    local threadRunner = Sandbox.newThreadRunner()

    local envOverrides = {
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        GetGameTimer = function() return fakeNow.value end,
        AddEventHandler = AddEventHandlerStub,
        -- server/permissions.lua now unconditionally calls RegisterNetEvent
        -- at file-load time (client/featureblocks.lua's per-person feature
        -- block sync, a separate pass this file does not otherwise
        -- exercise) -- not exercised by these tests, mirrors
        -- tests/permissions_spec.lua's own identical no-op stub.
        RegisterNetEvent = function(_name, _fn) end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = printStub,
        lib = libStub,
        exports = exportsStub,
        MySQL = makeMysqlStub(world),
        NotifyPlayer = NotifyPlayer,
        GetPlayers = function() return opts.onlineSources or {} end,
        Config = Config,
    }
    -- Only added when NOT omitted -- Sandbox.newEnv's own `for key, value in
    -- pairs(overrides)` would otherwise happily set env.IsHighCommand = nil,
    -- which is a no-op in Lua (assigning nil to a table field never creates the
    -- key), so this branch is purely documentation of intent -- but written
    -- explicitly rather than relying on that no-op so a future reader/refactor
    -- never "fixes" this into always assigning a stub.
    if not omitIsHighCommand then
        envOverrides.IsHighCommand = isHighCommand
    end
    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    for i = #printedLines, 1, -1 do printedLines[i] = nil end -- discard datastore's own boot-line print

    Sandbox.loadInto('../server/permissions.lua', env)
    if opts.loadCatalog ~= false then
        Sandbox.loadInto('../server/permissionkeycatalog.lua', env)
    end

    local function triggerResourceStart()
        for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
            handler('john-k9')
        end
    end
    triggerResourceStart()

    return {
        env = env, world = world, callbacks = callbacks, printedLines = printedLines,
        fakeNow = fakeNow, notifyLog = notifyLog, triggerResourceStart = triggerResourceStart,
    }
end

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

--- @param f table
--- @param key string
--- @return table?
local function findCatalogKey(f, key)
    local result = f.callbacks['john-k9:server:permKeysList'](HC_SOURCE)
    for _, entry in ipairs(result.keys) do
        if entry.key == key then return entry end
    end
    return nil
end

-- ============================================================================
-- SECTION 1 -- registration + AUTHORIZATION
-- ============================================================================

t.test('registration: all three callbacks are registered', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, name in ipairs({
        'john-k9:server:permKeysList', 'john-k9:server:permKeysUpsert', 'john-k9:server:permKeysDelete',
    }) do
        t.isNotNil(f.callbacks[name], name .. ' must always be registered')
    end
end)

t.test('AUTHORIZATION: permKeysList denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysList'](NON_HC_SOURCE)
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('AUTHORIZATION: permKeysUpsert denies a non-high-command source even with a well-formed payload', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysUpsert'](NON_HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.custom'), 'a denied caller must never actually create the key')
end)

t.test('AUTHORIZATION: permKeysDelete denies a non-high-command source', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysDelete'](NON_HC_SOURCE, 'k9.access')
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'), 'a denied delete must not tombstone anything')
end)

t.test('AUTHORIZATION: server-side re-check ignores whatever the caller claims -- IsHighCommand alone decides, never a payload flag', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysUpsert'](NON_HC_SOURCE, { key = 'k9.custom', label = 'Custom', isHighCommand = true, ok = true })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('AUTHORIZATION: FAILS CLOSED when IsHighCommand is entirely UNDEFINED (not merely false) -- all three callbacks, for ANY source including one that would otherwise be high command', function()
    -- The STRONG form: CanManagePermissionKeys' own production guard is
    -- `type(IsHighCommand) == 'function' and IsHighCommand(source)` -- this
    -- proves that guard is real (denies when the global genuinely does not
    -- exist, e.g. a load-order break that left server/highcommand.lua never
    -- loaded), not merely that a stub returning false is honoured. Every
    -- OTHER test in this section only ever proves the weaker "a defined
    -- IsHighCommand that returns false denies" case.
    local f = boot({ isHighCommand = false })
    t.isNil(f.env.IsHighCommand, 'sanity: this fixture genuinely never defines IsHighCommand')

    local listResult = f.callbacks['john-k9:server:permKeysList'](HC_SOURCE)
    t.isFalse(listResult.ok)
    t.equals(listResult.reason, 'denied')

    local upsertResult = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isFalse(upsertResult.ok)
    t.equals(upsertResult.reason, 'denied')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.custom'), 'an undefined-gate caller must never actually create the key')

    local deleteResult = f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.access')
    t.isFalse(deleteResult.ok)
    t.equals(deleteResult.reason, 'denied')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'), 'an undefined-gate delete must not tombstone anything')
end)

-- ============================================================================
-- SECTION 2 -- default catalog (zero-behavior-change on every pre-this-pass
-- install).
-- ============================================================================

t.test('DEFAULT CATALOG: the four shipped Config.Permissions keys are all known with no tablet edit ever made', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for key in pairs(DEFAULT_PERMISSIONS) do
        t.isTrue(f.env.IsKnownPermissionCatalogKey(key), key .. ' must resolve from Config.Permissions alone')
    end
    t.equals(f.env.GetPermissionCatalogLabel('k9.access'), 'Use K9 abilities')
end)

t.test('DEFAULT CATALOG: an unknown/made-up key is not known', function()
    local f = boot()
    t.isFalse(f.env.IsKnownPermissionCatalogKey('made_up_permission'))
    t.isNil(f.env.GetPermissionCatalogLabel('made_up_permission'))
end)

-- ============================================================================
-- SECTION 3 -- OVERLAY PRECEDENCE: the database wins over Config.Permissions.
-- ============================================================================

t.test('OVERLAY: relabeling a shipped default key through the catalog wins over Config.Permissions -- the key itself is unchanged', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.access', label = 'Operate as a K9', description = 'Renamed by high command' })
    t.isTrue(result.ok)
    t.equals(f.env.GetPermissionCatalogLabel('k9.access'), 'Operate as a K9', 'the DB row must win over the config default')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'))
end)

t.test('OVERLAY: a brand-new, purely-DB-created key validates through IsValidPermissionKey (server/permissions.lua seam)', function()
    -- TARGET_CIT must be registered ONLINE for the HasPermission assertion
    -- below to mean anything -- server/permissions.lua's own PermissionCache
    -- is scoped ONLY to online citizenids (that file's own header "CACHING
    -- / SCOPE"): HasPermission for a citizenid with no cache entry at all
    -- always reads as false regardless of what the DB actually holds, by
    -- design, not a bug in this catalog.
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom_ability', label = 'Custom Ability' })
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.custom_ability'))

    -- HasPermission (server/permissions.lua) is the real proof this seam
    -- actually reaches the authorization root, not merely this file's own
    -- accessor -- GrantPermission below only succeeds if IsValidPermissionKey
    -- accepts the key.
    local ok = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.custom_ability')
    t.isTrue(ok, 'a purely-DB-created permission key must be grantable once added')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.custom_ability'))
end)

t.test('OVERLAY: PermissionLabelFor (used in the grant-notify message) reflects the LIVE catalog label, not the stale Config.Permissions one', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.access', label = 'Operate as a K9' })
    f.fakeNow.value = f.fakeNow.value + 2000

    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    local lastNotify = f.notifyLog[#f.notifyLog]
    t.isNotNil(lastNotify)
    t.contains(lastNotify.message, 'Operate as a K9', 'the notify text must use the RELABELED name, not the original Config.Permissions label')
end)

-- ============================================================================
-- SECTION 4 -- TOMBSTONE (not reference-counted -- see this file's own
-- header "TOMBSTONE, NOT REFERENCE-COUNTED").
-- ============================================================================

t.test('TOMBSTONE: deleting a key excludes it from the live catalog immediately, with no reference-count refusal', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    -- Grant it first, so a real, ACTIVE k9_permissions row exists for this
    -- key -- proving the delete below is NOT refused despite that reference,
    -- unlike server/certtiers.lua's own DeleteTier.
    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.audit')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.audit'))

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.audit')
    t.isTrue(result.ok, 'delete must succeed unconditionally -- no tier-style tier_in_use refusal exists for a permission key')
    t.equals(result.activeGrantCount, 1, 'the response still discloses how many active grants are about to go inert')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.audit'))
end)

t.test('TOMBSTONE: HasPermission resolves to false for an ALREADY-ACTIVE grant of a now-tombstoned key -- "resolves predictably", never a stale true', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.audit')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.audit'))

    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.audit')

    -- The k9_permissions row itself is UNTOUCHED (still active = 1) -- only
    -- the catalog's own validity gate changed. This is the load-bearing
    -- proof of this file's own "no reference-count refusal needed" claim.
    t.isNotNil(findActiveGrant(f.world, 'TARGET_CIT', 'k9.audit'), 'the grant row itself must be untouched by a catalog delete')
    t.isFalse(f.env.HasPermission('TARGET_CIT', 'k9.audit'), 'HasPermission must now deny it -- a tombstoned key can never resolve to true')
end)

t.test('TOMBSTONE: GrantPermission refuses to grant an already-deleted key -- invalid_permission, not a silent no-op', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.givexp')

    local ok, outcome = f.env.GrantPermission(HC_SOURCE, 'SOME_CIT', 'k9.givexp')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_permission')
end)

t.test('RESTORE: re-adding a tombstoned key restores it, and an old, never-revoked grant becomes valid again', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.audit')
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.audit')
    t.isFalse(f.env.HasPermission('TARGET_CIT', 'k9.audit'))

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.audit', label = 'View the audit records' })
    t.isTrue(result.ok)
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.audit'))
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.audit'), 'restoring the key must revive the grant that was never itself revoked')
end)

t.test('TOMBSTONE: deleting a purely-custom key removes it from ListPermissionCatalogKeys entirely', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isNotNil(findCatalogKey(f, 'k9.custom'))

    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.custom')
    t.isNil(findCatalogKey(f, 'k9.custom'))
end)

-- ============================================================================
-- SECTION 5 -- NAMESPACE PROTECTION: block.<Feature>/feature.<Feature> can
-- never be created, renamed, or shadowed through this surface.
-- ============================================================================

t.test('NAMESPACE: creating a key named feature.<Name> is refused as reserved_namespace', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'feature.BiteAndHold', label = 'Shadow' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'reserved_namespace')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('feature.BiteAndHold'))
end)

t.test('NAMESPACE: creating a key named block.<Name> is refused as reserved_namespace', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'block.BiteAndHold', label = 'Shadow' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'reserved_namespace')
end)

t.test('NAMESPACE: the bare literal keys "feature" and "block" are both refused too', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'feature', 'block' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = badKey, label = 'X' })
        t.isFalse(result.ok)
        t.equals(result.reason, 'reserved_namespace')
    end
end)

t.test('NAMESPACE: the feature./block. namespace keeps working UNAFFECTED by this catalog -- IsValidPermissionKey never routes it through the catalog at all', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'SOME_CIT', source = 300 } } },
    })
    local ok = f.env.GrantPermission(HC_SOURCE, 'SOME_CIT', 'feature.BiteAndHold')
    t.isTrue(ok, 'a real Config.Features key must still validate for feature.<Name> regardless of this catalog existing')
    t.isTrue(f.env.HasPermission('SOME_CIT', 'feature.BiteAndHold'))
    -- And the catalog itself never claims to know this key -- it belongs to
    -- an entirely different validation path.
    t.isFalse(f.env.IsKnownPermissionCatalogKey('feature.BiteAndHold'))
end)

-- ============================================================================
-- SECTION 5b -- PRIVILEGE ESCALATION REGRESSION (red-team pass, this task).
-- server/runtimecontrol.lua's CanManageRuntimeControl/CanManageTabletTheme
-- and server/equipmentshop.lua's CanManageShopLocations/CanManageShopItems
-- each hardcode a `HasPermission(citizenid, 'k9.<word>')` escape hatch that
-- was believed permanently inert because that literal is not a key of
-- Config.Permissions. Before this pass's fix, permKeysUpsert had no idea
-- those four literals were special -- any high-command officer could
-- manufacture one at runtime and GrantPermission would then hand it to ANY
-- citizenid, deputizing an ordinary player with runtime-control/shop-admin
-- authority. See server/permissionkeycatalog.lua's own header "RESERVED
-- INTERNAL CAPABILITY KEYS" for the full writeup this section proves.
-- ============================================================================

t.test('PRIVILEGE ESCALATION FIX: permKeysUpsert refuses to create k9.runtimecontrol as reserved_internal_key', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.runtimecontrol', label = 'Manage Runtime Control' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'reserved_internal_key')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.runtimecontrol'), 'the key must never actually be created')
end)

t.test('PRIVILEGE ESCALATION FIX: all four currently-known reserved internal literals are refused the same way', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'k9.runtimecontrol', 'k9.tablettheme', 'k9.equipmentshoplocations', 'k9.equipmentshopitems' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = badKey, label = 'X' })
        t.isFalse(result.ok, badKey .. ' must be refused')
        t.equals(result.reason, 'reserved_internal_key')
        t.isFalse(f.env.IsKnownPermissionCatalogKey(badKey))
    end
end)

t.test('PRIVILEGE ESCALATION FIX: GrantPermission therefore refuses k9.runtimecontrol for anyone -- invalid_permission, since the catalog never let it exist', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        playersBySource = { [300] = { PlayerData = { citizenid = 'ORDINARY_PLAYER', source = 300 } } },
    })
    -- The exact attack: high command tries to create the hatch key, then
    -- grant it to an ordinary (non-high-command) citizenid.
    f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.runtimecontrol', label = 'Manage Runtime Control' })

    local ok, outcome = f.env.GrantPermission(HC_SOURCE, 'ORDINARY_PLAYER', 'k9.runtimecontrol')
    t.isFalse(ok, 'the grant must fail -- the key was never actually created')
    t.equals(outcome, 'invalid_permission')
    t.isFalse(f.env.HasPermission('ORDINARY_PLAYER', 'k9.runtimecontrol'))
end)

t.test('PRIVILEGE ESCALATION FIX (END TO END, real server/runtimecontrol.lua loaded alongside): the deputized ordinary player still cannot call runtimeSetFeature after the exact attack chain', function()
    -- Loads the REAL, unmodified server/runtimecontrol.lua on top of the
    -- REAL server/permissions.lua + server/permissionkeycatalog.lua this
    -- spec already exercises -- the closest this harness can get to
    -- reproducing "traced end to end" against production code on both
    -- sides of the seam, not merely this file's own accessors.
    local rcWorld = { overrides = {}, overrideAudit = {}, theme = nil, themeAudit = {} }
    local permWorld = newWorld()

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local HC_SRC, TARGET_SRC = 100, 300
    local playersBySource = {
        [HC_SRC] = { PlayerData = { citizenid = 'HC_CIT', source = HC_SRC } },
        [TARGET_SRC] = { PlayerData = { citizenid = 'ORDINARY_PLAYER', source = TARGET_SRC } },
    }
    local playersByCitizenId = {}
    for _, p in pairs(playersBySource) do playersByCitizenId[p.PlayerData.citizenid] = p end
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    -- ONE combined MySQL stub covering both this catalog's own tables
    -- (k9_permission_keys/k9_permission_key_audit/k9_permissions, via
    -- makeMysqlStub above) AND server/runtimecontrol.lua's own tables
    -- (k9_runtime_feature_overrides/.../k9_tablet_theme*), since both real
    -- production files run against the SAME env.MySQL in one real boot.
    local baseMysql = makeMysqlStub(permWorld)
    local mysqlStub = {
        query = { await = function(sql, params)
            if sql:find('k9_runtime_feature_override', 1, true) or sql:find('k9_tablet_theme', 1, true) then
                if sql:find('SELECT override_key, kind, value, updated_by, updated_at FROM k9_runtime_feature_overrides', 1, true) then
                    local out = {}
                    for key, row in pairs(rcWorld.overrides) do
                        out[#out + 1] = { override_key = key, kind = row.kind, value = row.value, updated_by = row.updated_by, updated_at = row.updated_at }
                    end
                    return out
                elseif sql:find('INSERT INTO k9_runtime_feature_overrides', 1, true) then
                    local key, kind, value, updatedBy = params[1], params[2], params[3], params[4]
                    rcWorld.overrides[key] = { kind = kind, value = value, updated_by = updatedBy, updated_at = '2026-01-01 00:00:00' }
                    return {}
                elseif sql:find('DELETE FROM k9_runtime_feature_overrides', 1, true) then
                    rcWorld.overrides[params[1]] = nil
                    return {}
                elseif sql:find('INSERT INTO k9_runtime_override_audit', 1, true) then
                    return {}
                elseif sql:find('SELECT primary_color, accent_color, background_color, text_color, density, header_title FROM k9_tablet_theme', 1, true) then
                    if rcWorld.theme then return { rcWorld.theme } end
                    return {}
                elseif sql:find('INSERT INTO k9_tablet_theme_audit', 1, true) then
                    return {}
                elseif sql:find('INSERT INTO k9_tablet_theme (', 1, true) then
                    rcWorld.theme = { primary_color = params[1], accent_color = params[2], background_color = params[3], text_color = params[4], density = params[5], header_title = params[6] }
                    return {}
                end
                error('end-to-end spec: unhandled runtimecontrol SQL: ' .. tostring(sql))
            end
            return baseMysql.query.await(sql, params)
        end },
        scalar = baseMysql.scalar,
        insert = baseMysql.insert,
        update = baseMysql.update,
    }

    local fakeNow = { value = 0 }
    -- COULD-NOT-DETERMINE RESYNC SWEEP: server/permissions.lua calls
    -- CreateThread(...) unconditionally at file-load time (the resync sweep
    -- for PermissionCheckUnresolved, deliberately not feature-gated). Any
    -- fixture loading that file needs a REAL CreateThread/Wait pair -- a
    -- no-op stub either throws or loops forever, since the sweep body is
    -- `while true do Wait(x) ... end`.
    local threadRunner = Sandbox.newThreadRunner()

    local env = Sandbox.newEnv({
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        GetGameTimer = function() return fakeNow.value end,
        AddEventHandler = AddEventHandlerStub,
        RegisterNetEvent = function(_name, _fn) end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'john-k9' end,
        print = printStub,
        lib = libStub,
        exports = exportsStub,
        MySQL = mysqlStub,
        NotifyPlayer = function() end,
        GetPlayers = function() return {} end,
        IsHighCommand = function(src) return src == HC_SRC end,
        Config = {
            Features = {
                PermissionGrants = true, CommandTablet = false,
                RuntimeFeatureControl = true, TabletTheming = true,
                BiteAndHold = true, DoorInteraction = true, HighCommand = true,
            },
            Permissions = DEFAULT_PERMISSIONS,
            Departments = { police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Tracking = { Scent = {}, Blood = {}, Gunpowder = {} },
            AdminAudit = { MaxResults = {} },
        },
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/permissions.lua', env)
    Sandbox.loadInto('../server/permissionkeycatalog.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('john-k9') end

    t.isNotNil(callbacks['john-k9:server:runtimeSetFeature'], 'sanity: the real runtimecontrol.lua callback must have registered')

    -- STEP 1: high command tries to manufacture the hatch key.
    local upsertResult = callbacks['john-k9:server:permKeysUpsert'](HC_SRC, { key = 'k9.runtimecontrol', label = 'Manage Runtime Control' })
    t.isFalse(upsertResult.ok, 'the catalog must refuse to manufacture this literal')
    t.equals(upsertResult.reason, 'reserved_internal_key')

    -- STEP 2: high command tries to grant it anyway (proves GrantPermission
    -- itself never had a path around the catalog's own refusal).
    local grantOk = env.GrantPermission(HC_SRC, 'ORDINARY_PLAYER', 'k9.runtimecontrol')
    t.isFalse(grantOk, 'the grant must fail -- the key never validated')
    t.isFalse(env.HasPermission('ORDINARY_PLAYER', 'k9.runtimecontrol'))

    -- STEP 3: the "deputized" ordinary player tries the real, unmodified
    -- runtimeSetFeature callback directly -- the actual exploit surface the
    -- task named. Must still be denied.
    local setFeatureResult = callbacks['john-k9:server:runtimeSetFeature'](TARGET_SRC, 'DoorInteraction', false)
    t.isFalse(setFeatureResult.ok, 'an ordinary player must never be able to manage runtime control through this chain')
    t.equals(setFeatureResult.reason, 'denied')
end)

-- ============================================================================
-- SECTION 6 -- THE DELETE-VS-GRANT RACE.
-- ============================================================================

t.test('RACE GUARD: PermissionKeyEditMutex is a real mutex object exposed as a bare global', function()
    local f = boot()
    t.equals(type(f.env.PermissionKeyEditMutex), 'table')
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'))
    t.isFalse(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'), 'a second acquire of the same key while held must fail')
    f.env.PermissionKeyEditMutex.Release('k9.access')
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'), 'released, then re-acquirable')
end)

t.test('RACE GUARD: GrantPermission reports "busy" and writes NOTHING while a concurrent catalog edit holds the same key\'s lock', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })

    -- Simulates the exact window server/permissionkeycatalog.lua's own
    -- DeleteKey/UpsertKey hold this lock for -- a concurrent GrantPermission
    -- for the SAME key must not be able to interleave its own check-then-
    -- write around it.
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'))

    local ok, outcome = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    t.isFalse(ok)
    t.equals(outcome, 'busy')
    t.isNil(findActiveGrant(f.world, 'TARGET_CIT', 'k9.access'), 'a busy grant attempt must never write a row')

    f.env.PermissionKeyEditMutex.Release('k9.access')
    -- The rejected attempt above already consumed the SAME officer's own
    -- rate limit (the cooldown check runs before the mutex acquisition, so
    -- a busy refusal still counts as one action, matching
    -- server/certtiers.lua's own identical ordering) -- advance past it so
    -- this second call is judged on the mutex/key state alone.
    f.fakeNow.value = f.fakeNow.value + 2000
    local ok2 = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    t.isTrue(ok2, 'once released, the identical grant succeeds normally')
end)

t.test('RACE GUARD: permKeysDelete itself refuses when the key\'s lock is already held (busy), never silently skipping the hold', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(f.env.PermissionKeyEditMutex.TryAcquire('k9.access'))

    local result = f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.access')
    t.isFalse(result.ok)
    t.equals(result.reason, 'busy')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'))
end)

t.test('RACE GUARD: absent server/permissionkeycatalog.lua entirely, GrantPermission still works via the documented fallback (soft dependency)', function()
    local f = boot({
        isHighCommand = function(src) return src == HC_SOURCE end,
        loadCatalog = false,
        playersBySource = { [300] = { PlayerData = { citizenid = 'TARGET_CIT', source = 300 } } },
    })
    t.isNil(f.env.PermissionKeyEditMutex, 'this fixture genuinely has no permissionkeycatalog.lua loaded')
    t.isNil(f.env.IsKnownPermissionCatalogKey)

    local ok = f.env.GrantPermission(HC_SOURCE, 'TARGET_CIT', 'k9.access')
    t.isTrue(ok, 'GrantPermission must still succeed against Config.Permissions alone with this file entirely absent')
    t.isTrue(f.env.HasPermission('TARGET_CIT', 'k9.access'))
end)

-- ============================================================================
-- SECTION 7 -- FAIL-CLOSED, NOT FAIL-OPEN, on a genuine DB read failure.
-- ============================================================================

t.test('FAIL-CLOSED: a failed catalog refresh never WIDENS validity beyond the Config.Permissions baseline', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.custom'))

    -- Simulate a genuine DB outage on the exact read RefreshPermissionKeyCatalog
    -- performs, then force a refresh the same way a resource restart would
    -- (onResourceStart) -- this file has no OTHER externally-triggerable
    -- refresh point, matching server/certtiers.lua's own identical shape.
    f.world.forceKeysQueryError = true
    f.triggerResourceStart()

    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.custom'),
        'a degraded read must never leave a purely-DB-sourced key looking MORE valid than Config.Permissions alone would say')
    -- The four shipped defaults are UNAFFECTED -- Config.Permissions itself
    -- was never touched by the simulated database outage.
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'))
end)

t.test('FAIL-CLOSED: DISCLOSED, tier-consistent limitation -- a failed refresh can transiently un-tombstone a DEFAULT key (self-heals on the next successful refresh). Documented, not silently hidden.', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.givexp')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.givexp'))

    f.world.forceKeysQueryError = true
    f.triggerResourceStart()
    -- This mirrors server/certtiers.lua's own RefreshCertificationTierCatalog,
    -- which has the identical property for a tombstoned TIER on a failed
    -- read -- see server/permissionkeycatalog.lua's own header
    -- "FAIL-CLOSED, NOT FAIL-OPEN" for the full writeup of why this is
    -- accepted rather than engineered away, and why it never widens beyond
    -- what Config.Permissions itself already grants.
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.givexp'), 'documented limitation: a failed read cannot see the tombstone row, so a DEFAULT key reverts to its config-shipped validity until the next successful refresh')

    -- Self-heals the instant a real read succeeds again.
    f.world.forceKeysQueryError = false
    f.triggerResourceStart()
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.givexp'), 'a subsequent successful refresh must re-apply the tombstone')
end)

t.test('FAIL-CLOSED: a malformed Config.Permissions degrades this file\'s own base catalog to empty, never asserts/errors', function()
    local f = boot({ permissions = { ['not-a-table'] = 'oops' } })
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.access'), 'a malformed Config.Permissions must not silently grant anything')
    -- The file must have loaded cleanly regardless (no error thrown at load
    -- time) -- reaching this line at all proves that.
    t.isNotNil(f.env.ListPermissionCatalogKeys)
end)

-- ============================================================================
-- SECTION 8 -- Config.Database.enabled = false: still runs, forgets on
-- restart.
-- ============================================================================

t.test('MEMORY MODE: Config.Database.enabled = false -- upsert/list/delete all still work with zero real database calls', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end, database = { enabled = false } })

    local upsertResult = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.memory_only', label = 'Memory Only' })
    t.isTrue(upsertResult.ok)
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.memory_only'))

    f.fakeNow.value = f.fakeNow.value + 2000
    local deleteResult = f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.memory_only')
    t.isTrue(deleteResult.ok)
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.memory_only'))

    -- Zero rows were ever written to the fake SQL world -- proves this ran
    -- entirely through K9Store's in-memory backend, never MySQL.*.
    t.isNil(next(f.world.permKeys), 'no real database row should exist in memory mode')
    t.isNil(next(f.world.permKeyAudit), 'no real audit row should exist in memory mode either')
end)

t.test('MEMORY MODE: a custom key created while Config.Database.enabled = false is FORGOTTEN across a resource restart', function()
    local first = boot({ isHighCommand = function(src) return src == HC_SOURCE end, database = { enabled = false } })
    first.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.session_only', label = 'Session Only' })
    t.isTrue(first.env.IsKnownPermissionCatalogKey('k9.session_only'))

    -- A fresh boot = a fresh server/datastore.lua closure (its own local
    -- in-memory tables are re-initialized empty) -- this is the honest
    -- "forgotten on restart" story server/datastore.lua's own header
    -- promises for Config.Database.enabled = false.
    local second = boot({ isHighCommand = function(src) return src == HC_SOURCE end, database = { enabled = false } })
    t.isFalse(second.env.IsKnownPermissionCatalogKey('k9.session_only'), 'memory-mode state must not survive a restart')
    t.isTrue(second.env.IsKnownPermissionCatalogKey('k9.access'), 'the config-shipped defaults are unaffected either way')
end)

-- ============================================================================
-- SECTION 9 -- VALIDATION.
-- ============================================================================

t.test('VALIDATION: an invalid key format (uppercase/too long/empty/bad chars) is rejected before any write', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badKey in ipairs({ 'K9.Access', '', 'x ', 'has spaces', string.rep('a', 60), '.leadingdot' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = badKey, label = 'X' })
        t.isFalse(result.ok, 'key ' .. tostring(badKey) .. ' must be rejected')
        t.equals(result.reason, 'invalid_key')
    end
end)

t.test('VALIDATION: an invalid label (empty, too long, unsafe characters) is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    for _, badLabel in ipairs({ '', string.rep('a', 61), 'has <a> tag' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local result = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = badLabel })
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_label')
    end
end)

t.test('VALIDATION: description is optional -- nil is accepted, an over-long one is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local okResult = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    t.isTrue(okResult.ok, 'a nil description must be accepted')

    f.fakeNow.value = f.fakeNow.value + 2000
    local badResult = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom2', label = 'Custom 2', description = string.rep('a', 301) })
    t.isFalse(badResult.ok)
    t.equals(badResult.reason, 'invalid_description')
end)

t.test('VALIDATION: deleting an unknown key is refused as unknown_key, not a no-op success', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local result = f.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'never_existed')
    t.isFalse(result.ok)
    t.equals(result.reason, 'unknown_key')
end)

-- ============================================================================
-- SECTION 10 -- rate limiting (mirrors server/certtiers.lua's own
-- CertTierActionCooldown pattern).
-- ============================================================================

t.test('RATE LIMIT: a second mutating call from the same officer inside the cooldown window is rejected', function()
    local f = boot({ isHighCommand = function(src) return src == HC_SOURCE end })
    local first = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.one', label = 'One' })
    t.isTrue(first.ok)
    local second = f.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.two', label = 'Two' })
    t.isFalse(second.ok)
    t.equals(second.reason, 'rate_limited')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.two'))
end)

-- ============================================================================
-- SECTION 11 -- persistence across a restart (real-DB mode, mirrors
-- tests/certtiers_spec.lua's own two-boot pattern).
-- ============================================================================

t.test('PERSISTENCE: a custom key, a relabel, and a delete all survive a resource restart via the shared fake database', function()
    local world = newWorld()
    local first = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    first.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.custom', label = 'Custom' })
    first.fakeNow.value = first.fakeNow.value + 2000
    first.callbacks['john-k9:server:permKeysUpsert'](HC_SOURCE, { key = 'k9.access', label = 'Renamed Access' })
    first.fakeNow.value = first.fakeNow.value + 2000
    first.callbacks['john-k9:server:permKeysDelete'](HC_SOURCE, 'k9.givexp')

    local second = boot({ world = world, isHighCommand = function(src) return src == HC_SOURCE end })
    t.isTrue(second.env.IsKnownPermissionCatalogKey('k9.custom'), 'the custom key must survive a restart')
    t.equals(second.env.GetPermissionCatalogLabel('k9.access'), 'Renamed Access', 'the relabel must survive a restart')
    t.isFalse(second.env.IsKnownPermissionCatalogKey('k9.givexp'), 'the deletion (tombstone) must survive a restart, never silently un-delete')
end)

-- ============================================================================
-- SECTION 12 -- BOOT-ORDER RACE against server/datastore.lua's schema-
-- collision probe (interaction review + fix, db-schema boot-order pass).
--
-- server/datastore.lua loads before this file and registers its own
-- onResourceStart handler FIRST -- but that handler's own MySQL.query.await
-- is a real, YIELDING call, and a yielding handler does not block FXServer's
-- event dispatch from moving straight on to the NEXT registered handler
-- (this file's own, below) while the probe is still in flight. Every OTHER
-- test in this file uses the synchronous `boot()`/`makeMysqlStub` helpers
-- above, which never yield at all (plain Lua functions), so they cannot
-- exercise this. This section builds its own small, separate,
-- coroutine-based dispatcher instead, reproducing that ONE real FXServer
-- property precisely: every onResourceStart handler registered for the same
-- event runs in its OWN coroutine, in registration order, and a handler
-- that yields hands control back immediately rather than blocking the next
-- one. See server/datastore.lua's own K9Store.WaitForSchemaCheckToSettle
-- for the fix this proves.
-- ============================================================================

-- DERIVED, NEVER HAND-MAINTAINED. This used to be a hand-typed copy of
-- every table and column server/datastore.lua checks at boot -- the fifth
-- such copy in this repo. It went stale the moment migration 0018 added a
-- table, and this file's own control test started failing because the probe
-- response it handed back looked like a part-installed database.
--
-- Sandbox.installedSchemaRows() reads the real EXPECTED_TABLE_COLUMNS out of
-- server/datastore.lua's source instead, so adding a table or a column can
-- never again leave this fixture quietly describing an older schema. Use it
-- anywhere a test needs to say "a clean, fully migrated database".
--
-- Deliberately NOT used by the collision test above, which hands back a
-- partial column set on purpose -- that one is testing what happens when a
-- table's shape does NOT match, so a full, correct set would defeat it.
local function AllK9TableColumnsForSchemaProbe()
    return Sandbox.installedSchemaRows()
end

--- @param opts table? -- { foreignPermKeyRows: table? -- canned response
---   for this catalog's own `SELECT permission_key, label, description,
---   deleted FROM k9_permission_keys` if it is ever actually issued }
--- @return table fixture -- { env, printedLines, coros, fireResourceStart,
---   resumeNext, permKeysQueryCallCount }
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
    -- schedule. `permKeysQueryCalls` counts how many times this catalog's
    -- OWN narrower SELECT actually ran -- the exact thing every test below
    -- proves must never happen before the probe has settled.
    local permKeysQueryCalls = 0
    local queryStub = {
        await = function(sql, _params)
            if sql:find('SELECT permission_key, label, description, deleted FROM k9_permission_keys', 1, true) then
                permKeysQueryCalls = permKeysQueryCalls + 1
                return opts.foreignPermKeyRows or {}
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
            Permissions = opts.permissions or DEFAULT_PERMISSIONS,
            Departments = { police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Features = { PermissionGrants = true, CommandTablet = false, BiteAndHold = true },
        },
        AddEventHandler = AddEventHandlerStub,
        RegisterNetEvent = function(_name, _fn) end,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetPlayers = function() return {} end, -- keeps permissions.lua's own onResourceStart backfill loop a harmless no-op here
        GetGameTimer = function() return 0 end,
        -- Yields, mirroring the real FXServer scheduler closely enough for
        -- K9Store.WaitForSchemaCheckToSettle's own bounded poll loop to
        -- actually suspend this catalog's handler between polls -- exactly
        -- what every test below drives explicitly via `resumeNext`.
        Wait = function(_ms) coroutine.yield() end,
        -- server/permissions.lua's resync sweep calls CreateThread at
        -- file-load time. This fixture drives coroutines by hand to model
        -- FXServer's boot-order dispatch, so the sweep is PARKED rather than
        -- run: created, never resumed. That is the honest model here -- the
        -- sweep is irrelevant to a boot-order race test, and resuming it
        -- would make it yield inside the Wait stub above and interleave with
        -- the probe this test is actually about.
        CreateThread = function(fn) coroutine.create(fn) end,
        lib = { callback = { register = function() end } },
        exports = { qbx_core = { GetPlayer = function() end, GetPlayerByCitizenId = function() end } },
        MySQL = { query = queryStub },
        print = printStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/permissions.lua', env)
    Sandbox.loadInto('../server/permissionkeycatalog.lua', env)

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
        permKeysQueryCallCount = function() return permKeysQueryCalls end,
    }
end

t.test('BOOT-ORDER RACE (the actual bug, fixed): a foreign k9_permission_keys table that satisfies this catalog\'s own narrower SELECT but fails the FULL schema probe must never reach the live permission-key catalog', function()
    local f = bootWithRacingMySQL({
        foreignPermKeyRows = { { permission_key = 'someone.elses.row', label = 'NOT OURS', description = nil, deleted = 0 } },
    })

    f.fireResourceStart()
    -- Per real FXServer semantics: datastore.lua's own probe handler has
    -- yielded (its INFORMATION_SCHEMA query is "in flight") and this
    -- file's own onResourceStart handler (registered after it) has
    -- ALREADY been invoked too, up to its own first Wait().
    t.equals(f.permKeysQueryCallCount(), 0, 'the catalog must not issue its own narrower SELECT before the schema probe has settled')

    -- Resolve the probe: a foreign table with only 4 of the 7 columns
    -- k9_permission_keys is checked against -- exactly the 4 columns this
    -- catalog's own SELECT names -- a genuine collision.
    t.isTrue(f.resumeNext({
        { tbl = 'k9_permission_keys', col = 'permission_key' },
        { tbl = 'k9_permission_keys', col = 'label' },
        { tbl = 'k9_permission_keys', col = 'description' },
        { tbl = 'k9_permission_keys', col = 'deleted' },
    }), 'the probe must still be suspended, waiting to be resolved')
    t.isFalse(f.env.K9Store.IsDatabaseEnabled(), 'the collision must have been detected')
    t.equals(f.permKeysQueryCallCount(), 0, 'still not read immediately after settling')

    -- ONE EXTRA resumeNext() (boot-order-race audit, this pass):
    -- server/permissions.lua's own onResourceStart backfill loop now ALSO
    -- calls K9Store.WaitForSchemaCheckToSettle() before its own (here,
    -- harmless -- GetPlayers() is stubbed empty) GetPlayers() loop, so it
    -- is registered (and parks on its own Wait() poll) in between
    -- datastore.lua's probe and this catalog's own handler -- one more
    -- participant in this fixture's coroutine sequence than there used to
    -- be, in strict registration order (permissions.lua loads before
    -- permissionkeycatalog.lua, above). Drained here, before the catalog's
    -- own wake-up below, rather than assumed away, so this test keeps
    -- meaning exactly what its own name says.
    t.isTrue(f.resumeNext(), 'server/permissions.lua\'s own backfill handler, parked inside its own bounded wait, wakes on its next poll -- a harmless no-op here (GetPlayers() is empty)')

    t.isTrue(f.resumeNext(), 'the catalog handler, parked inside its own bounded wait, wakes on its next poll')
    t.equals(f.permKeysQueryCallCount(), 0, 'DatabaseEnabled() is now false, so the catalog takes the MEMORY branch -- it must NEVER have issued its own narrower SELECT against the foreign table, before or after settling')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('someone.elses.row'), 'the foreign row must never reach the live permission-key catalog')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'), 'falls back to config-shipped defaults exactly like Config.Database.enabled = false, never to an empty catalog')
    t.isFalse(f.resumeNext(), 'every handler has now run to completion')
end)

t.test('BOOT-ORDER RACE control: once the probe settles with NO collision, the catalog performs its real read and picks up legitimate persisted rows -- the fix must not break the ordinary, non-colliding path', function()
    local f = bootWithRacingMySQL({
        foreignPermKeyRows = { { permission_key = 'k9.real', label = 'Real DB Row', description = nil, deleted = 0 } },
    })

    f.fireResourceStart()
    t.equals(f.permKeysQueryCallCount(), 0)

    -- A schema response naming every column for EVERY table this resource
    -- owns -- a clean, fully and currently migrated database, not merely
    -- "k9_permission_keys looks fine" (see AllK9TableColumnsForSchemaProbe's
    -- own doc comment for why this must be the full set now).
    t.isTrue(f.resumeNext(AllK9TableColumnsForSchemaProbe()))
    t.isTrue(f.env.K9Store.IsDatabaseEnabled(), 'no collision, nothing missing -- the real database stays live')

    -- ONE EXTRA resumeNext() -- see the identically-named comment in the
    -- "BOOT-ORDER RACE (the actual bug, fixed)" test above for the full
    -- "why": server/permissions.lua's own onResourceStart backfill loop is
    -- now a second participant in this fixture's coroutine sequence,
    -- registered before this catalog's own handler.
    t.isTrue(f.resumeNext(), 'server/permissions.lua\'s own backfill handler wakes on its next poll -- a harmless no-op here (GetPlayers() is empty)')

    t.isTrue(f.resumeNext(), 'the catalog handler wakes on its next poll')
    t.equals(f.permKeysQueryCallCount(), 1, 'now that settlement confirmed no collision, the catalog performs its real read exactly once')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.real'), 'the legitimate persisted row must be picked up')
    t.isFalse(f.resumeNext())
end)

t.test('BOOT-ORDER RACE bounded timeout: if the schema probe never settles, this catalog gives up after a bounded number of polls and boots to config-only defaults -- it must never hang and never read the unconfirmed table', function()
    local f = bootWithRacingMySQL({
        foreignPermKeyRows = { { permission_key = 'k9.real', label = 'Real DB Row', description = nil, deleted = 0 } },
    })
    f.fireResourceStart()
    t.equals(f.permKeysQueryCallCount(), 0)

    -- Never resume coros[1] (the probe) at all -- a hung query that never
    -- comes back, not merely a slow one. Keep waking ONLY this catalog's
    -- own handler (coros[3]) on its own bounded poll loop until it either
    -- gives up (dies) or this test's own generous ceiling is hit -- the
    -- ceiling exists purely so a regression that makes the production wait
    -- loop genuinely infinite fails this test instead of hanging the whole
    -- suite.
    -- FIND the catalog's own handler rather than indexing it by a GUESSED
    -- position. This used to be `f.coros[3]`, on the assumption that the
    -- third registered onResourceStart handler is this catalog's -- broke
    -- once server/permissions.lua went from one start handler to three for
    -- an unrelated feature, shifting every index after it. Rewritten, at
    -- that point, to instead find "the one still suspended after the probe
    -- is deliberately left hung, since it is the only one polling for a
    -- settle that never comes" -- but THAT assumption broke too, silently,
    -- the moment server/permissions.lua's OWN restart-backfill
    -- onResourceStart handler independently started calling
    -- K9Store.WaitForSchemaCheckToSettle() as well (an unrelated pass):
    -- with the probe hung, BOTH that handler and this catalog's own end up
    -- "still suspended, polling for a settle that never comes" at once, so
    -- picking the first one found (registration order) silently started
    -- driving server/permissions.lua's handler instead again.
    --
    -- FIXED, this time, by position anchored to something this spec DOES
    -- control: server/permissionkeycatalog.lua is always the LAST of these
    -- four files loaded (see this fixture's own `Sandbox.loadInto` call
    -- order above) and registers exactly one onResourceStart handler, so
    -- its coroutine is always `coros[#coros]` regardless of how many OTHER
    -- handlers any earlier-loaded file registers, or how many of them
    -- happen to share this exact "still suspended, polling forever" shape.
    local catalogCo = f.coros[#f.coros]
    t.isTrue(catalogCo ~= nil and coroutine.status(catalogCo) == 'suspended', 'the catalog must have a suspended start handler polling for the schema check to settle')

    local resumes = 0
    while coroutine.status(catalogCo) == 'suspended' and resumes < 200 do
        coroutine.resume(catalogCo)
        resumes = resumes + 1
    end

    t.isTrue(resumes < 200, 'must give up within a bounded number of polls, never spin forever waiting on a probe that never answers')
    t.isTrue(coroutine.status(catalogCo) == 'dead', 'the catalog\'s own onResourceStart handler must finish (give up), not remain permanently suspended')
    t.equals(f.permKeysQueryCallCount(), 0, 'must never issue its own narrower SELECT while the collision state is genuinely unknown -- fail-closed, exactly like Config.Database.enabled = false')
    t.isFalse(f.env.IsKnownPermissionCatalogKey('k9.real'), 'no DB row -- real or foreign -- reaches the catalog while unsettled')
    t.isTrue(f.env.IsKnownPermissionCatalogKey('k9.access'), 'config-shipped defaults remain in effect')
    t.contains(table.concat(f.printedLines, '\n'), 'schema-collision check had not finished', 'the fallback must be logged clearly, never silent')
end)

os.exit(t.summary())
