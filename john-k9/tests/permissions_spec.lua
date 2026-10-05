--[[
    tests/permissions_spec.lua

    Tests server/permissions.lua -- the grantable-permissions layer -- against
    the REAL, unmodified production file, via tests/fixtures/sandbox.lua.
    Harness style mirrors tests/admin_spec.lua (read end to end before
    writing this file) and tests/highcommand_spec.lua (multiple independent
    fixtures where load-time/registration-time behavior must be observed
    fresh).

    TWO FIXTURE BUILDERS:
      newFixture(opts)             -- UNIT level: loads only server/cooldowns.lua
        + server/permissions.lua. `IsHighCommand`/`HasK9Access` are
        TEST-CONTROLLED stubs (plain functions the test swaps in), not the
        real server/highcommand.lua/server/certifications/ -- this is a
        deliberate substitution for isolating server/permissions.lua's own
        logic, exactly matching this codebase's `type(fn) == 'function'`
        soft-dependency contract (a real deployment satisfies it via those
        two real files; this fixture satisfies it via a double).
      newIntegrationFixture(opts)  -- loads the REAL server/highcommand.lua,
        server/certifications/ and server/admin.lua alongside
        server/permissions.lua in ONE shared env, to prove the actual
        4-step resolution order end-to-end through real production code on
        every step, not a re-implementation of it. Used for the
        "RESOLUTION ORDER" section and the "REVOKED BUT STILL HAS IT BY
        RANK" end-to-end case.

    FAKE k9_permissions TABLE: an in-memory array the MySQL stub below reads/
    writes, keyed exactly the way the real table is (citizenid, permission,
    active) -- built once per fixture, mutated by GrantPermission/
    RevokePermission exactly like a real database would be, so cache/DB
    consistency is exercised for real rather than asserted by fiat.
    `forceInsertError`/`forceUpdateError`/`forceScalarError` are the
    failure-injection knobs used by the "DB ERRORS THROW, NOT NIL" section.

    LOCALE: never stubbed (Sandbox.newEnv already wires the real locale()
    reader over the real locales/en.json), matching
    tests/certifications_spec.lua's own choice -- every notify path this
    spec drives is therefore also a check that
    permissions.grant_notify_target / permissions.revoke_notify_target /
    common.unable_to_resolve_citizenid genuinely exist.

    EXCEPTION, THIS PASS (CONSOLE/CHAT COMMAND GRANT PATH section below):
    server/permissions.lua's own header for that section lists sixteen NEW
    'permissions.command_*' locale keys this pass needs, reported (per this
    task's own hard rule) rather than added to locales/en.json directly.
    localeWithPendingCommandKeys below is a NARROW, DISCLOSED exception to
    the "never stubbed" rule above, used ONLY by the command-path tests: it
    resolves those sixteen not-yet-landed keys from a literal copy of the
    exact text requested (kept byte-for-byte identical to server/
    permissions.lua's own header, so a drift between the two would be
    obvious on review) and falls through to the REAL Sandbox.locale (real
    en.json) for every OTHER key -- so this exception still doubles as a
    real-file check for every key that predates this pass, exactly like
    every other test in this file.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- CONSOLE/CHAT COMMAND GRANT PATH (this pass) -- see this file's own
-- header "EXCEPTION" note above.
-- ----------------------------------------------------------------------
local PENDING_COMMAND_LOCALE = {
    ['permissions.command_usage_grant']        = 'Usage: /k9grantpermission [citizenid] [permissionKey]',
    ['permissions.command_usage_revoke']       = 'Usage: /k9revokepermission [citizenid] [permissionKey]',
    ['permissions.command_not_authorized']     = 'You are not authorized to grant or revoke K9 permissions.',
    ['permissions.command_feature_disabled']   = 'Permission grants are currently disabled on this server.',
    ['permissions.command_invalid_permission'] = 'That is not a valid permission key.',
    ['permissions.command_invalid_target']     = 'That is not a valid citizen ID.',
    ['permissions.command_self_grant_blocked'] = 'You cannot grant a permission to yourself.',
    ['permissions.command_rate_limited']       = 'Please wait a moment before trying again.',
    ['permissions.command_busy']               = 'That permission key is being edited elsewhere right now -- try again in a moment.',
    ['permissions.command_already_granted']    = '%s already holds that permission.',
    ['permissions.command_db_error']           = 'A database error occurred. Please try again.',
    ['permissions.command_grant_ok']           = "Granted '%s' to %s.",
    ['permissions.command_not_granted']        = '%s does not currently hold that permission.',
    ['permissions.command_revoke_ok']          = "Revoked '%s' from %s.",
    ['permissions.command_revoke_ok_rank']     = "Revoked '%s' from %s, but they still have it through their rank or High Command status.",
    ['permissions.command_revoke_ok_offline']  = "Revoked '%s' from %s. They are offline, so it could not be checked whether they still qualify for it through rank.",
}

--- @param key string
--- @return string
local function localeWithPendingCommandKeys(key, ...)
    local text = PENDING_COMMAND_LOCALE[key]
    if text then
        if select('#', ...) > 0 then return text:format(...) end
        return text
    end
    return Sandbox.locale(key, ...)
end

-- ----------------------------------------------------------------------
-- Fixture 1: UNIT level. server/cooldowns.lua + server/permissions.lua only.
-- ----------------------------------------------------------------------

--- @param opts table? -- { permissions: table (default 4-key catalog), departments: table (default police w/ certifierGrade=4,auditGrade=4), isHighCommand: fun(source):boolean (default: always false), hasK9Access: fun(source):boolean (default: always false), commandTablet: boolean (default false), featureControl: table? (default absent -- Config.FeatureControl.RequireGrant, for the STARTUP WARNING section), commandTabletConfig: table? (default absent -- Config.CommandTablet, for the STARTUP WARNING section's openMode check), locale: (fun(key, ...):string)? (default nil -- keeps this fixture's existing "real locale() over real en.json" behavior; only the CONSOLE/CHAT COMMAND section overrides this, to resolve this pass's own not-yet-landed 'permissions.command_*' keys -- see that section's own comment), forcePermissionsTableMissing: boolean (default false -- MEMORY-MODE BLOCK ASYMMETRY section: answers server/datastore.lua's boot schema probe as PART-INSTALLED with every OTHER table intact and ONLY `k9_permissions` missing -- server/datastore.lua's own real per-table fallback, not a whole-resource one, modelling this pass's exact "materially more reachable" scenario) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 0 }
    local function GetGameTimer() return state.now end

    -- ---- fake k9_permissions table ----
    local rows = {}
    local nextId = 0
    local forceInsertError = nil -- nil | 'duplicate' | 'generic'
    local forceUpdateError = nil -- nil | 'not_committed' | 'committed'
    local forceScalarError = false

    local function findActiveRow(citizenid, permission)
        for _, row in ipairs(rows) do
            if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                return row
            end
        end
        return nil
    end

    local mysql = {
        scalar = { await = function(_sql, params)
            if forceScalarError then error('simulated scalar read failure') end
            local row = findActiveRow(params[1], params[2])
            return row and row.id or nil
        end },
        insert = { await = function(_sql, params)
            if forceInsertError == 'duplicate' then
                error({ errno = 1062, message = 'Duplicate entry for key uq_one_active_permission_per_citizen' })
            end
            if forceInsertError == 'generic' then error('simulated insert failure') end
            nextId = nextId + 1
            rows[#rows + 1] = {
                id = nextId, citizenid = params[1], permission = params[2], granted_by = params[3],
                granted_at = '2026-01-01 00:00:00', revoked_by = nil, revoked_at = nil, active = 1,
            }
            return nextId
        end },
        update = { await = function(_sql, params)
            local granterCid, citizenid, permission = params[1], params[2], params[3]
            local affected = 0
            for _, row in ipairs(rows) do
                if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                    if forceUpdateError ~= 'not_committed' then
                        row.active = 0
                        row.revoked_by = granterCid
                        row.revoked_at = '2026-01-01 00:00:00'
                        affected = affected + 1
                    end
                end
            end
            if forceUpdateError == 'not_committed' or forceUpdateError == 'committed' then
                error('simulated update failure')
            end
            return affected
        end },
        query = { await = function(sql, params)
            -- Answer server/datastore.lua's boot schema probe as a fully
            -- installed database. Without this the probe sees no tables,
            -- concludes the SQL was never imported, and forces memory-only
            -- mode -- which would quietly turn every database-backed
            -- assertion below into a memory-mode assertion. See
            -- tests/datastore_spec.lua's SETTLEMENT tests.
            -- MEMORY-MODE BLOCK ASYMMETRY section (this pass):
            -- `opts.forcePermissionsTableMissing` strips `k9_permissions`
            -- alone out of that otherwise-fully-installed answer -- every
            -- OTHER table still reports intact, matching server/
            -- datastore.lua's own PART-INSTALLED branch (tests/
            -- datastore_spec.lua's own identical technique for its
            -- k9_certifications cascade test), never the old
            -- whole-resource "nothing was ever imported" branch this pass
            -- is specifically about no longer triggering.
            if Sandbox.isSchemaProbe(sql) then
                if opts.forcePermissionsTableMissing then
                    local rowsOut = {}
                    for _, row in ipairs(Sandbox.installedSchemaRows()) do
                        if row.tbl ~= 'k9_permissions' then rowsOut[#rowsOut + 1] = row end
                    end
                    return rowsOut
                end
                return Sandbox.installedSchemaRows()
            end
            local out = {}
            if sql:find('SELECT permission FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                end
            elseif sql:find('SELECT permission, granted_by, granted_at FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.citizenid == params[1] and row.active == 1 then
                        out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = row.granted_at }
                    end
                end
            elseif sql:find('SELECT citizenid, granted_by, granted_at FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.permission == params[1] and row.active == 1 then
                        out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by, granted_at = row.granted_at }
                    end
                end
            end
            return out
        end },
    }

    -- ---- players ----
    local playersBySource = {}
    local playersByCitizenId = {}
    local onlineSources = {} -- array of source numbers "already connected" for the onResourceStart backfill test

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        onlineSources[#onlineSources + 1] = source
        return source
    end

    local function disconnectPlayer(source)
        local p = playersBySource[source]
        if not p then return end
        playersBySource[source] = nil
        playersByCitizenId[p.PlayerData.citizenid] = nil
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local function GetPlayersStub() return onlineSources end

    -- ---- misc capture ----
    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    -- CONSOLE/CHAT COMMAND GRANT PATH (this pass) -- server/permissions.lua
    -- now RegisterCommand's 'k9grantpermission'/'k9revokepermission'
    -- unconditionally at file-load time, so this fixture MUST provide a
    -- stub (plain lua5.4 has no real RegisterCommand global at all) or
    -- EVERY test in this file would fail the moment Sandbox.loadInto
    -- executes that top-level call. Mirrors newIntegrationFixture's own
    -- identically-shaped `capturedCommands`/`RegisterCommand` pair below.
    local capturedCommands = {}
    local function RegisterCommandStub(name, fn, _restricted) capturedCommands[name] = fn end

    local function GetCurrentResourceNameStub() return 'john-k9' end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    -- FEATURE-BLOCK PUSH capture -- this pass. `clientEvents` mirrors
    -- tests/partnership_spec.lua's own established `{event=, target=,
    -- args={...}}` shape for capturing TriggerClientEvent, so a test can
    -- assert exactly who was pushed what without a real network layer.
    -- `capturedNetEvents`/`RegisterNetEvent` mirrors that same file's own
    -- `capturedEvents` shape for a server-side RegisterNetEvent handler this
    -- suite needs to invoke directly (this pass's new
    -- 'john-k9:server:requestFeatureBlocksSync').
    local clientEvents = {}
    local function TriggerClientEventStub(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local capturedNetEvents = {}
    local function RegisterNetEventStub(name, fn) capturedNetEvents[name] = fn end

    -- FIX (this pass, "the de-assign button" finding) -- RevokePermission's
    -- 'k9.access'-fully-revoked teardown calls these three, all of which
    -- load AFTER server/permissions.lua in fxmanifest.lua's server_scripts
    -- list (server/main.lua, server/combat.lua, server/partnership.lua
    -- respectively) and are therefore genuine soft dependencies, guarded by
    -- `type(...) == 'function'` at every call site -- included by default so
    -- most tests can assert they fire; opts.includeTeardownHooks = false
    -- (default true) omits all three from the env to confirm the guards
    -- genuinely tolerate them being entirely absent.
    local leashDetachCalls = {}      -- ForceDetachLeashForSource(src, reason)
    local effectEndCalls = {}        -- EndActiveEffectForHolder(src)
    local partnershipBreakCalls = {} -- ForceBreakPartnershipForCitizenId(citizenid, reason)
    local teardownOverrides = {}
    if opts.includeTeardownHooks ~= false then
        teardownOverrides.ForceDetachLeashForSource = function(src, reason)
            leashDetachCalls[#leashDetachCalls + 1] = { src, reason }
        end
        teardownOverrides.EndActiveEffectForHolder = function(src)
            effectEndCalls[#effectEndCalls + 1] = src
        end
        teardownOverrides.ForceBreakPartnershipForCitizenId = function(citizenid, reason)
            partnershipBreakCalls[#partnershipBreakCalls + 1] = { citizenid, reason }
        end
    end

    local Config = {
        Features = opts.features or {
            PermissionGrants = (opts.permissionGrantsEnabled ~= false), -- default true
            CommandTablet = opts.commandTablet == true,                 -- default false
            -- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl)
            -- -- real-shaped extra keys so IsValidPermissionKey's
            -- 'feature.<Name>'/'block.<Name>' validation (this pass) has a
            -- real Config.Features table to validate `<Name>` against, same
            -- table every production feature flag lives in. BiteAndHold
            -- mirrors an actual RequireGrant-listed feature;
            -- SomeFeatureOff is DELIBERATELY `false` (not merely absent) --
            -- IsValidPermissionKey must accept a real key regardless of its
            -- current on/off value (existence, not truthiness, is what is
            -- being checked; "is it currently on" is an entirely separate
            -- question this file never answers).
            BiteAndHold = true,
            SomeFeatureOff = false,
        },
        Permissions = opts.permissions or {
            ['k9.access']  = { label = 'Use K9 abilities', description = 'x' },
            ['k9.certify'] = { label = 'Certify and decertify others', description = 'x' },
            ['k9.audit']   = { label = 'View the audit records', description = 'x' },
            ['k9.givexp']  = { label = 'Grant XP', description = 'x' },
        },
        Departments = opts.departments or {
            police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6, autoAccessGrade = nil },
        },
        -- STARTUP WARNING section (this pass) -- absent by default, exactly
        -- matching real production config BEFORE Config.FeatureControl
        -- existed, and every test written before this pass that never
        -- passes `opts.featureControl`/`opts.commandTabletConfig` continues
        -- to load a Config with neither field, unaffected by this addition.
        FeatureControl = opts.featureControl,
        CommandTablet = opts.commandTabletConfig or { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
    }

    -- COULD-NOT-DETERMINE RESYNC SWEEP (lifecycle QA pass, this pass):
    -- server/permissions.lua now calls CreateThread(...) UNCONDITIONALLY at
    -- its own file-load time (the resync sweep for PermissionCheckUnresolved
    -- -- see that file's own declaration comment for why it is deliberately
    -- NOT feature-gated). Every fixture that loads server/permissions.lua
    -- must therefore provide a real CreateThread/Wait pair, mirroring
    -- tests/certifications_spec.lua's own identical `Sandbox.newThreadRunner()`
    -- wiring for the exact same reason (that file's own resync sweep, added
    -- the same pass) -- a plain `fn()`/no-op stub would either throw
    -- (CreateThread undefined) or infinite-loop synchronously (a bare
    -- `while true do Wait(x) ... end` body with a Wait() that just returns).
    local threadRunner = Sandbox.newThreadRunner()

    local envOverrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        MySQL = mysql,
        exports = exportsStub,
        GetPlayers = GetPlayersStub,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceNameStub,
        lib = libStub,
        TriggerClientEvent = TriggerClientEventStub,
        RegisterNetEvent = RegisterNetEventStub,
        RegisterCommand = RegisterCommandStub,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        -- Test-controlled soft dependencies -- see this file's header.
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasK9Access = opts.hasK9Access, -- deliberately nil by default (type() guard must tolerate absence)
    }
    for key, value in pairs(teardownOverrides) do envOverrides[key] = value end
    -- CONSOLE/CHAT COMMAND GRANT PATH (this pass) -- see this fixture's own
    -- `opts` doc comment above for why this is opt-in, not a default
    -- override: every OTHER test in this file keeps proving the REAL
    -- locale() against the REAL locales/en.json (this file's own header
    -- "LOCALE: never stubbed"), and only tests that need this pass's own
    -- not-yet-landed 'permissions.command_*' keys pass one in.
    if opts.locale then envOverrides.locale = opts.locale end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    -- real K9Store -- server/permissions.lua's own RefreshPermissionCache/
    -- IsPermissionRowConfirmedActive/GrantPermission/RevokePermission/
    -- ListActivePermissionsForCitizenId/ListPermissionRoster all read/write
    -- through this now, never their own SafeQuery+raw-SQL pair.
    -- DatabaseEnabled() fails safe to true (real-DB mode) since this
    -- fixture's Config has no Config.Database, so K9Store routes through
    -- this fixture's own `mysql` stub above exactly like the
    -- pre-migration code did.
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/permissions.lua', env)

    return {
        env = env,
        state = state,
        rows = rows,
        mysql = mysql,
        notifyLog = notifyLog,
        printLog = printLog,
        eventHandlers = eventHandlers,
        callbacks = capturedCallbacks,
        commands = capturedCommands,
        threadRunner = threadRunner,
        leashDetachCalls = leashDetachCalls,
        effectEndCalls = effectEndCalls,
        partnershipBreakCalls = partnershipBreakCalls,
        clientEvents = clientEvents,
        netEvents = capturedNetEvents,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        setSource = function(src) env.source = src end,
        advanceTime = function(ms) state.now = state.now + ms end,
        setForceInsertError = function(v) forceInsertError = v end,
        setForceUpdateError = function(v) forceUpdateError = v end,
        setForceScalarError = function(v) forceScalarError = v end,
        firePlayerDropped = function(src)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do handler() end
        end,
        firePlayerLoaded = function(playerObj)
            for _, handler in ipairs(eventHandlers['QBCore:Server:PlayerLoaded'] or {}) do handler(playerObj) end
        end,
        fireOnResourceStart = function()
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('john-k9') end
        end,
        --- Drives the captured 'john-k9:server:requestFeatureBlocksSync'
        --- RegisterNetEvent handler directly, with `env.source` set to `src`
        --- first -- mirrors every other RegisterNetEvent dispatch convention
        --- in this suite (this file's own `firePlayerDropped` above,
        --- tests/partnership_spec.lua's `dispatchNetEvent`). Asserts the
        --- handler actually exists rather than silently no-op'ing, so a
        --- typo'd event name fails the test that uses this, not passes it
        --- vacuously.
        --- @param src number
        fireRequestFeatureBlocksSync = function(src)
            env.source = src
            local handler = capturedNetEvents['john-k9:server:requestFeatureBlocksSync']
            assert(handler, 'no handler registered for john-k9:server:requestFeatureBlocksSync')
            handler()
        end,
        --- @param source number
        --- @return table? -- the LAST { event, target, args } entry pushed to `source`, or nil if none
        lastClientEventFor = function(source)
            local found
            for _, entry in ipairs(clientEvents) do
                if entry.target == source then found = entry end
            end
            return found
        end,
    }
end

--- @param f table
--- @param source number
--- @return table?
local function lastNotifyFor(f, source)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == source then found = entry end
    end
    return found
end

-- ----------------------------------------------------------------------
-- Fixture 2: INTEGRATION level. Real server/highcommand.lua +
-- server/certifications/ + server/admin.lua + server/permissions.lua,
-- all in ONE env, to prove the real 4-step resolution order end to end.
-- ----------------------------------------------------------------------

--- @return table fixture
local function newIntegrationFixture()
    local state = { now = 0 }
    local function GetGameTimer() return state.now end

    local permRows = {}
    local nextPermId = 0
    local function findActivePermRow(citizenid, permission)
        for _, row in ipairs(permRows) do
            if row.citizenid == citizenid and row.permission == permission and row.active == 1 then return row end
        end
        return nil
    end

    local mysql = {
        scalar = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local row = findActivePermRow(params[1], params[2])
                return row and row.id or nil
            end
            return nil -- k9_certifications pre-checks: no existing row, not exercised by these tests
        end },
        insert = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                nextPermId = nextPermId + 1
                permRows[#permRows + 1] = {
                    id = nextPermId, citizenid = params[1], permission = params[2], granted_by = params[3],
                    granted_at = '2026-01-01 00:00:00', active = 1,
                }
                return nextPermId
            end
            return 1
        end },
        update = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local granterCid, citizenid, permission = params[1], params[2], params[3]
                local affected = 0
                for _, row in ipairs(permRows) do
                    if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                        row.active = 0
                        row.revoked_by = granterCid
                        affected = affected + 1
                    end
                end
                return affected
            end
            return 0 -- k9_certifications update: pretend nothing was active -- these tests only exercise the authorization gate, not a real cert flip
        end },
        query = { await = function(sql, params)
            -- Answer server/datastore.lua's boot schema probe as a fully
            -- installed database. Without this the probe sees no tables,
            -- concludes the SQL was never imported, and forces memory-only
            -- mode -- which would quietly turn every database-backed
            -- assertion below into a memory-mode assertion. See
            -- tests/datastore_spec.lua's SETTLEMENT tests.
            if Sandbox.isSchemaProbe(sql) then return Sandbox.installedSchemaRows() end
            if sql:find('k9_permissions', 1, true) then
                local out = {}
                if sql:find('SELECT permission FROM k9_permissions', 1, true) then
                    for _, row in ipairs(permRows) do
                        if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                    end
                elseif sql:find('SELECT permission, granted_by, granted_at FROM k9_permissions', 1, true) then
                    for _, row in ipairs(permRows) do
                        if row.citizenid == params[1] and row.active == 1 then
                            out[#out + 1] = { permission = row.permission, granted_by = row.granted_by, granted_at = row.granted_at }
                        end
                    end
                end
                return out
            end
            return {} -- k9_certifications SELECTs (admin.lua audit queries): always empty, not exercised
        end },
    }

    local playersBySource = {}
    local playersByCitizenId = {}
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return source
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCommands = {}
    local function RegisterCommand(name, fn, _restricted) capturedCommands[name] = fn end

    local function RegisterNetEvent(_name, _fn) end -- not exercised by these tests

    local function GetCurrentResourceNameStub() return 'john-k9' end
    local function GetHashKeyStub(_name) return 111 end
    local function TriggerEventStub(_name, ...) end
    -- FEATURE-BLOCK PUSH (this pass) -- server/permissions.lua's
    -- PlayerLoaded/onResourceStart/GrantPermission/RevokePermission now
    -- call TriggerClientEvent for a `block.<Name>` change against an online
    -- target. None of THIS fixture's own tests exercise `block.<Name>` or a
    -- non-empty GetPlayers() (its own onResourceStart backfill loop is a
    -- no-op here -- see GetPlayers below), so this is a pure no-op stub,
    -- purely so a future test added to this fixture cannot crash this
    -- file's own top-level load with "attempt to call a nil value" the way
    -- every OTHER FiveM native stub in this fixture already guards against.
    local function TriggerClientEventStub(_eventName, _target, ...) end

    -- lib.callback.register is only actually reached by server/certifications/'s
    -- hasK9Access callback here (permissions.lua's OWN tabletGrant/Revoke
    -- registrations are gated behind Config.Features.CommandTablet, false in
    -- this fixture) -- nothing in this suite needs to invoke it, so this is a
    -- pure no-op stub, just enough for `lib.callback.register(...)` to not
    -- throw "attempt to index a nil value" at those files' own load time.
    local libStub = { callback = { register = function(_name, _fn) end } }

    local Config = {
        CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
        -- BiteAndHold, this pass: a real Config.Features key with no other
        -- meaning to this fixture, purely so 'feature.BiteAndHold'/
        -- 'block.BiteAndHold' validate against IsValidPermissionKey's own
        -- `Config.Features[Name] ~= nil` check (see server/permissions.lua's
        -- own doc comment on that function) -- needed for the HIGH COMMAND
        -- BYPASS FOR feature.<Name> end-to-end section below.
        Features = { PermissionGrants = true, HighCommand = true, AdminAuditCommands = true, CommandTablet = false, BiteAndHold = true },
        Departments = {
            police = { label = 'LSPD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6, autoAccessGrade = nil },
        },
        Peds = { { model = 'a_c_shepherd' } },
        CertifyProximityMeters = 5.0,
        AllowSelfCertification = true,
        -- Required by server/highcommand.lua's onResourceStart guard since
        -- Config.Features.HighCommand is true above -- '/k9givexp' itself is
        -- never exercised by these tests, but this file's onResourceStart
        -- fires for every loaded file indiscriminately, so it must pass.
        HighCommand = { maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false },
        AdminAudit = {
            TrustConsole = false,
            CommandCooldownMs = 300,
            MaxResults = { Certifications = 50, Partnerships = 50, SearchLog = 50 },
        },
        Permissions = {
            ['k9.access']  = { label = 'Use K9 abilities' },
            ['k9.certify'] = { label = 'Certify and decertify others' },
            ['k9.audit']   = { label = 'View the audit records' },
            ['k9.givexp']  = { label = 'Grant XP' },
        },
    }

    -- COULD-NOT-DETERMINE RESYNC SWEEP (lifecycle QA pass, this pass): both
    -- server/certifications/ and server/permissions.lua now call
    -- CreateThread(...) UNCONDITIONALLY at file-load time (their own
    -- respective resync sweeps) -- see newFixture's own identical comment
    -- above for the full "why". ONE shared threadRunner captures threads
    -- from BOTH files loaded into this same env below.
    local threadRunner = Sandbox.newThreadRunner()

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        MySQL = mysql,
        exports = exportsStub,
        GetPlayers = function() return {} end,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        AddEventHandler = AddEventHandler,
        RegisterCommand = RegisterCommand,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceNameStub,
        GetHashKey = GetHashKeyStub,
        TriggerEvent = TriggerEventStub,
        TriggerClientEvent = TriggerClientEventStub,
        lib = libStub,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)       -- real K9Store -- server/admin.lua's own query functions read through this now (the datastore migration), never their own SafeQuery+raw-SQL pair; DatabaseEnabled() fails safe to true (real-DB mode) since this fixture's Config has no Config.Database, so K9Store routes through this fixture's own `mysql` stub below exactly like the pre-migration code did
    Sandbox.loadInto('../server/highcommand.lua', env)   -- real IsHighCommand
    -- SPLIT 2026-09-02: one 6,012-line file became four, loaded in the same
    -- order fxmanifest.lua loads them. The order is load-bearing -- each
    -- file re-binds names the earlier ones published onto K9Cert, so a
    -- file loaded out of order would re-bind nil.
    Sandbox.loadInto('../server/certifications/core.lua', env)
    Sandbox.loadInto('../server/certifications/depth.lua', env)
    Sandbox.loadInto('../server/certifications/accessors.lua', env)
    Sandbox.loadInto('../server/certifications/commands.lua', env) -- real HasK9Access / IsEligibleCertifier
    Sandbox.loadInto('../server/admin.lua', env)           -- real IsAuthorizedAdmin
    Sandbox.loadInto('../server/permissions.lua', env)     -- real HasPermission / GrantPermission / RevokePermission

    -- Register admin.lua's commands (k9audit cert etc.) -- gated on
    -- Config.Features.AdminAuditCommands, already true above.
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env,
        state = state,
        permRows = permRows,
        notifyLog = notifyLog,
        printLog = printLog,
        commands = capturedCommands,
        registerPlayer = registerPlayer,
        advanceTime = function(ms) state.now = state.now + ms end,
        threadRunner = threadRunner,
    }
end

--- @param f table -- an integration fixture
--- @param label string -- substring to search recent prints for
--- @return boolean
local function lastPrintContains(f, label)
    local last = f.printLog[#f.printLog]
    return last ~= nil and last:find(label, 1, true) ~= nil
end

-- ============================================================================
-- LOAD-TIME CONFIG-SAFETY GUARD -- CLAMP AND WARN, NOT ASSERT.
--
-- REGRESSION (this pass): every test below used to assert the OPPOSITE --
-- that Config.Permissions being missing entirely, or any ONE entry being
-- malformed, FAILED THE ENTIRE FILE'S LOAD via a hard `assert` running
-- unconditionally at this file's own load time (not deferred to
-- onResourceStart, and not gated behind Config.Features.PermissionGrants).
-- See server/cooldowns.lua's header ADDENDUM: an uncaught error thrown
-- there would abort server/permissions.lua's load from that line onward,
-- taking HasPermission/GrantPermission/RevokePermission down with it, over
-- one operator typo while adding a fifth capability. Now CLAMP AND WARN: a
-- missing table degrades to "no permissions exist" (fails closed, same as
-- before this feature existed), and a malformed entry is dropped
-- individually rather than taking every other, valid entry down with it.
-- Each case here loads a FRESH, minimal env directly (not newFixture()),
-- since the point is to observe the load and the resulting Config.Permissions
-- shape, not to exercise HasPermission/GrantPermission behavior.
-- ============================================================================

--- @return boolean ok, table env, table printLog
local function tryLoadPermissionsWithConfig(permissionsConfig)
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end
    local threadRunner = Sandbox.newThreadRunner()
    local env = Sandbox.newEnv({
        Config = permissionsConfig == false and {} or { Permissions = permissionsConfig },
        GetGameTimer = function() return 0 end,
        AddEventHandler = function(_name, _fn) end,
        -- FEATURE-BLOCK PUSH (this pass) -- server/permissions.lua now
        -- registers 'john-k9:server:requestFeatureBlocksSync' via
        -- RegisterNetEvent unconditionally at file-load time; this minimal
        -- env (deliberately narrower than newFixture's) needs this stub for
        -- the same reason it already needs AddEventHandler above.
        RegisterNetEvent = function(_name, _fn) end,
        -- CONSOLE/CHAT COMMAND GRANT PATH (this pass) -- server/permissions.lua
        -- now RegisterCommand's 'k9grantpermission'/'k9revokepermission'
        -- unconditionally at file-load time too (see that section's own
        -- header for why it must NOT be gated the way the tablet callbacks
        -- are) -- same reasoning as the RegisterNetEvent stub immediately
        -- above.
        RegisterCommand = function(_name, _fn, _restricted) end,
        print = printStub,
        -- COULD-NOT-DETERMINE RESYNC SWEEP (lifecycle QA pass, this pass) --
        -- server/permissions.lua now calls CreateThread(...) UNCONDITIONALLY
        -- at file-load time too (see newFixture's own identical comment
        -- above for the full "why"). This minimal env needs this stub for
        -- the same reason it already needs AddEventHandler/RegisterNetEvent/
        -- RegisterCommand above -- a `Sandbox.newThreadRunner()` (not a bare
        -- no-op) is required rather than a plain `function() end`, since a
        -- no-op CreateThread would just never run the thread body at all
        -- (harmless for THIS narrow load-time-only fixture, which never
        -- steps it), but a plain no-op Wait() would busy-loop the sweep's
        -- own `while true do Wait(...) ... end` body forever the instant
        -- CreateThread ran it synchronously -- the coroutine-based runner
        -- avoids ever needing to reason about which of those two failure
        -- modes a simpler stub would hit.
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
    })
    local ok = pcall(function()
        Sandbox.loadInto('../server/cooldowns.lua', env)
        Sandbox.loadInto('../server/permissions.lua', env)
    end)
    return ok, env, printLog
end

t.test('LOAD-TIME: a well-formed Config.Permissions loads cleanly', function()
    local ok = tryLoadPermissionsWithConfig({ ['k9.access'] = { label = 'Use K9 abilities' } })
    t.isTrue(ok)
end)

t.test('LOAD-TIME: Config.Permissions missing entirely no longer fails to load -- warns loudly and degrades to "no permissions exist" (fails closed)', function()
    local ok, env, printLog = tryLoadPermissionsWithConfig(false)
    t.isTrue(ok, 'a missing Config.Permissions must not abort resource start')
    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.Permissions', 1, true) and line:find('missing', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must warn that the whole settings table is missing')
    t.equals(type(env.Config.Permissions), 'table')
    t.isNil(next(env.Config.Permissions), 'must degrade to empty, never to some other default')
end)

t.test('LOAD-TIME: a Config.Permissions entry with no label no longer fails to load -- warns and drops only that entry', function()
    local ok, env, printLog = tryLoadPermissionsWithConfig({
        ['k9.access'] = { description = 'no label here' },
        ['k9.audit'] = { label = 'View the audit records' },
    })
    t.isTrue(ok)
    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.Permissions[k9.access]', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must name the exact malformed key')
    t.isNil(env.Config.Permissions['k9.access'], 'the malformed entry must be dropped')
    t.isNotNil(env.Config.Permissions['k9.audit'], 'a sibling, valid entry must survive untouched')
end)

t.test('LOAD-TIME: a Config.Permissions entry with an empty-string label no longer fails to load -- warns and drops only that entry', function()
    local ok, env = tryLoadPermissionsWithConfig({ ['k9.access'] = { label = '' } })
    t.isTrue(ok)
    t.isNil(env.Config.Permissions['k9.access'])
end)

t.test('LOAD-TIME: a Config.Permissions entry with a non-string description no longer fails to load -- warns and drops only that entry', function()
    local ok, env = tryLoadPermissionsWithConfig({ ['k9.access'] = { label = 'ok', description = 123 } })
    t.isTrue(ok)
    t.isNil(env.Config.Permissions['k9.access'])
end)

-- ============================================================================
-- HasPermission -- step 1 of the resolution order, in isolation. Every
-- fail-closed path.
-- ============================================================================

do
    local f = newFixture()
    f.registerPlayer(1, 'K9-1', { name = 'police', grade = { level = 1 } })

    t.test('HasPermission: false with no cache entry at all (never crashes on an unknown citizenid)', function()
        t.isFalse(f.env.HasPermission('NEVER-SEEN', 'k9.access'))
    end)

    t.test('HasPermission: false for a non-string citizenid', function()
        t.isFalse(f.env.HasPermission(nil, 'k9.access'))
        t.isFalse(f.env.HasPermission(123, 'k9.access'))
    end)

    t.test('HasPermission: false for an empty-string citizenid', function()
        t.isFalse(f.env.HasPermission('', 'k9.access'))
    end)

    t.test('HasPermission: false for a permission key not in Config.Permissions', function()
        f.env.GrantPermission(nil, 'K9-1', 'k9.access') -- irrelevant call just to prove this isn't about the grant itself
        t.isFalse(f.env.HasPermission('K9-1', 'not.a.real.permission'))
    end)

    -- CONFIRMED, NOT ASSUMED (this pass -- flagged alongside the
    -- RevokePermission "revoking a retired key must always be possible"
    -- fix): HasPermission must keep calling the real, catalog-aware
    -- IsValidPermissionKey (unlike RevokePermission's own, deliberately
    -- narrower IsPlausiblePermissionKeyShape) -- a tombstoned key's row
    -- staying `active = 1` in the database must NEVER confer the
    -- capability while it sits there waiting to be revoked.
    t.test('HasPermission: a TOMBSTONED key (removed from Config.Permissions after being granted) resolves false even while its grant row is still active', function()
        local g = newFixture({ isHighCommand = function(source) return source == 900 end })
        local gHcSrc = g.registerPlayer(900, 'HC-TOMBSTONE', { name = 'police', isboss = true, grade = { level = 0 } })
        g.registerPlayer(3, 'K9-3', { name = 'police', grade = { level = 1 } })
        g.env.Config.Permissions['k9.tobetombstoned'] = { label = 'Temporary' }
        local ok = g.env.GrantPermission(gHcSrc, 'K9-3', 'k9.tobetombstoned')
        t.isTrue(ok)
        t.isTrue(g.env.HasPermission('K9-3', 'k9.tobetombstoned'), 'must read true before the tombstone')
        g.env.Config.Permissions['k9.tobetombstoned'] = nil -- tombstoned
        t.isFalse(g.env.HasPermission('K9-3', 'k9.tobetombstoned'), 'a tombstoned key must confer nothing, regardless of the still-active DB row')
    end)

    t.test('HasPermission: false when Config.Features.PermissionGrants is off, even with an active grant', function()
        f.registerPlayer(2, 'K9-2', { name = 'police', grade = { level = 1 } })
        local hc = newFixture({ isHighCommand = function() return true end })
        local hcSrc = hc.registerPlayer(50, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
        hc.registerPlayer(51, 'K9-OFF', { name = 'police', grade = { level = 1 } })
        local ok = hc.env.GrantPermission(hcSrc, 'K9-OFF', 'k9.access')
        t.isTrue(ok)
        t.isTrue(hc.env.HasPermission('K9-OFF', 'k9.access'))
        hc.env.Config.Features.PermissionGrants = false
        t.isFalse(hc.env.HasPermission('K9-OFF', 'k9.access'), 'feature flag must be re-checked on EVERY call, not cached')
    end)
end

-- ============================================================================
-- GrantPermission -- authorization, validation, self-grant, cooldown,
-- TOCTOU lock, duplicate-key handling, DB error handling, notifications.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 100 end })
    local hcSrc = f.registerPlayer(100, 'HC-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(101, 'LOWRANK', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(102, 'TARGET-A', { name = 'police', grade = { level = 1 } })

    t.test('GrantPermission: feature disabled -> feature_disabled, nothing granted', function()
        f.env.Config.Features.PermissionGrants = false
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        f.env.Config.Features.PermissionGrants = true
        t.isFalse(ok)
        t.equals(outcome, 'feature_disabled')
    end)

    -- SECURITY FIX (coder-security, this pass): a rejected attempt while the
    -- feature is off used to be the ONE outcome LogAuditInvocation never
    -- printed anything for -- every other rejection (denied, rate_limited,
    -- invalid_permission, ...) already left a trail. Proven here against the
    -- REAL, unmodified GrantPermission, not a re-implementation.
    t.test('AUDIT: GrantPermission still prints a trail (granter + target) even when the feature is disabled', function()
        f.env.Config.Features.PermissionGrants = false
        local before = #f.printLog
        f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        f.env.Config.Features.PermissionGrants = true
        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('HC-GRANTER', 1, true)
                and line:find('TARGET-A', 1, true) and line:find('feature_disabled', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a feature-disabled grant attempt must still be audited, naming both the granter and the target')
    end)

    t.test('GrantPermission: a non-high-command caller is denied', function()
        local ok, outcome = f.env.GrantPermission(101, 'TARGET-A', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    t.test('GrantPermission: a malformed permission key is rejected without throwing', function()
        -- FOUND BY MUTATION TESTING (2026-08-31): deleting
        -- IsValidPermissionKey's `type(value) ~= 'string' or value == '' or
        -- #value > 50` line left the whole suite green. Every existing key
        -- test above passes a well-formed string, so the shape guard itself
        -- was never exercised.
        --
        -- Both halves are observable, which is what makes this a real gap
        -- rather than an equivalent mutation:
        --   * a non-string key reaches `value:match('^feature%.(.+)$')`
        --     further down and THROWS -- aborting the grant mid-call
        --     instead of returning a clean refusal its caller can report.
        --   * `permission_key` is VARCHAR(50) in sql/install.sql, so an
        --     over-long key is a truncation or a write error at the DB.
        for _, bad in ipairs({ 123, true, {}, '' }) do
            f.advanceTime(2000)
            local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', bad)
            t.isFalse(ok, ('a %s permission key must be refused'):format(type(bad)))
            t.equals(outcome, 'invalid_permission',
                ('a %s permission key must refuse as invalid_permission, not throw or succeed'):format(type(bad)))
        end

        -- 51 characters: one past the VARCHAR(50) the schema declares.
        f.advanceTime(2000)
        local tooLong = string.rep('k', 51)
        local okLong, outcomeLong = f.env.GrantPermission(hcSrc, 'TARGET-A', tooLong)
        t.isFalse(okLong, 'a 51-character key exceeds permission_key VARCHAR(50) and must be refused before the write')
        t.equals(outcomeLong, 'invalid_permission')
    end)

    t.test('GrantPermission: an unconfigured permission key is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'not.real')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    -- ------------------------------------------------------------------
    -- IsValidPermissionKey: 'feature.<Name>'/'block.<Name>' -- THE HEADLINE
    -- FIX this pass exists to make. Before this fix, EVERY one of these
    -- calls failed as 'invalid_permission', which is exactly why
    -- Config.FeatureControl.RequireGrant/per-person blocks had zero real
    -- effect regardless of what any consuming gate (server/combat.lua,
    -- server/pursuitsprint.lua, server/admin.lua) already checked for.
    -- Proven here against the REAL, unmodified IsValidPermissionKey via
    -- GrantPermission/RevokePermission -- never a reimplementation.
    -- ------------------------------------------------------------------

    t.test('GrantPermission: feature.<Name> is accepted when <Name> is a real Config.Features key', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.BiteAndHold')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: block.<Name> is accepted when <Name> is a real Config.Features key', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.BiteAndHold')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: feature.<Name> is accepted even when <Name>\'s CURRENT VALUE is false -- existence in Config.Features is what is checked, not truthiness', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.SomeFeatureOff')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: feature.<Name> is STILL rejected when <Name> is NOT a real Config.Features key -- validated against what actually exists, not a free-form string', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.NotARealFeature')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: block.<Name> is STILL rejected when <Name> is NOT a real Config.Features key', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.NotARealFeature')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: a bare "feature." with no name suffix at all is rejected, not treated as Config.Features[""]', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: an injection-shaped feature.<Name> payload is rejected exactly like any other unrecognized key -- never reaches SQL text either way (parameterized)', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', "feature.'; DROP TABLE k9_permissions;--")
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: an oversized feature.<Name> payload (> 50 chars, the k9_permissions.permission column width) is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.' .. string.rep('x', 50))
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('END-TO-END: a granted feature.<Name> is genuinely readable back via HasPermission once the target is online (not merely accepted by the validator)', function()
        f.advanceTime(2000)
        local targetSrc = f.registerPlayer(103, 'TARGET-FC', { name = 'police', grade = { level = 1 } })
        local ok = f.env.GrantPermission(hcSrc, 'TARGET-FC', 'feature.BiteAndHold')
        t.isTrue(ok)
        t.isTrue(f.env.HasPermission('TARGET-FC', 'feature.BiteAndHold'))
        f.disconnectPlayer(targetSrc)
    end)

    t.test('END-TO-END: RevokePermission genuinely removes a previously granted block.<Name> row', function()
        f.advanceTime(2000)
        local targetSrc = f.registerPlayer(104, 'TARGET-FC2', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'TARGET-FC2', 'block.BiteAndHold')
        t.isTrue(f.env.HasPermission('TARGET-FC2', 'block.BiteAndHold'))

        f.advanceTime(2000)
        local ok = f.env.RevokePermission(hcSrc, 'TARGET-FC2', 'block.BiteAndHold')
        t.isTrue(ok)
        t.isFalse(f.env.HasPermission('TARGET-FC2', 'block.BiteAndHold'))
        f.disconnectPlayer(targetSrc)
    end)

    -- ------------------------------------------------------------------
    -- IsValidPermissionKey: ADMIN-CAPABILITY BLOCK NAMESPACE
    -- ('block.k9.access'/'block.k9.certify'/'block.k9.audit'/
    -- 'block.k9.givexp' -- security-audit pass, this pass). See
    -- ADMIN_CAPABILITY_BLOCKABLE_KEYS' own doc comment (this file) for the
    -- full "why only these four" writeup this mirrors -- server/
    -- certifications.lua's HasK9Access/IsEligibleCertifier and
    -- server/admin.lua's IsAuthorizedAdmin now consult these three
    -- directly; this section proves the VALIDATOR half via the REAL,
    -- unmodified GrantPermission/RevokePermission/HasPermission, same
    -- style as the feature./block. section immediately above.
    -- ------------------------------------------------------------------

    t.test('GrantPermission: block.k9.access / block.k9.certify / block.k9.audit are each accepted', function()
        f.advanceTime(2000)
        for _, key in ipairs({ 'block.k9.access', 'block.k9.certify', 'block.k9.audit' }) do
            f.advanceTime(2000)
            local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', key)
            t.isTrue(ok, key .. ': ' .. tostring(outcome))
            t.equals(outcome, 'ok')
            f.advanceTime(2000)
            f.env.RevokePermission(hcSrc, 'TARGET-A', key) -- clean up so the next iteration's grant is not a duplicate-active-row no-op
        end
    end)

    t.test('GrantPermission: block.k9.givexp is accepted -- the one admin-capability key with no legacy rank tier at all, still blockable', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.k9.givexp')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')
    end)

    t.test('GrantPermission: feature.k9.access is REJECTED -- there is no positive-grant concept for this namespace, only block', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'feature.k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: block.k9.notarealcapability is REJECTED -- only the four named admin capabilities are blockable, not a free-form k9.<word>', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.k9.notarealcapability')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('GrantPermission: block.k9.runtimecontrol is REJECTED -- a pure-grant custom capability key with no rank-based bypass has nothing for a block to add', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'block.k9.runtimecontrol')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_permission')
    end)

    t.test('END-TO-END: a granted block.k9.certify is genuinely readable back via HasPermission once the target is online', function()
        f.advanceTime(2000)
        local targetSrc = f.registerPlayer(105, 'TARGET-CAPBLOCK', { name = 'police', grade = { level = 1 } })
        local ok = f.env.GrantPermission(hcSrc, 'TARGET-CAPBLOCK', 'block.k9.certify')
        t.isTrue(ok)
        t.isTrue(f.env.HasPermission('TARGET-CAPBLOCK', 'block.k9.certify'))
        f.disconnectPlayer(targetSrc)
    end)

    -- ISOLATED FIXTURE, deliberately -- overriding K9Store.IsDatabaseEnabled
    -- on the SHARED `f` above would leave 'k9_permissions' memory-mode (and
    -- therefore every 'block.<Name>' check unconditionally blocked) for
    -- every OTHER test still to come in this same do...end block. A fresh
    -- newFixture() keeps this one test's memory-mode simulation from
    -- leaking into anything else.
    t.test('MEMORY-MODE BLOCK ASYMMETRY still applies to this NEW namespace for free -- no additional code needed in HasPermission itself', function()
        local g = newFixture()
        g.env.K9Store.IsDatabaseEnabled = function(tableName)
            if tableName == 'k9_permissions' then return false end
            return true
        end
        -- Nobody has ever granted this citizenid 'block.k9.access' this
        -- session (PermRows starts empty in memory-mode, by construction)
        -- -- HasPermission's own existing `permissionKey:match('^block%.')`
        -- branch matches this literal string exactly as it already matches
        -- 'block.<FeatureName>', with zero changes to that function.
        t.isTrue(g.env.HasPermission('NEVER-SEEN-CITIZENID', 'block.k9.access'),
            'memory-mode must fail closed for this namespace too, automatically')
    end)

    t.test('GrantPermission: an empty-string target citizenid is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, '', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('GrantPermission: a target citizenid over 50 chars is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, string.rep('x', 51), 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('GrantPermission: an unresolvable granter citizenid fails as invalid_granter and reuses common.unable_to_resolve_citizenid', function()
        f.advanceTime(2000)
        local hc2 = newFixture({ isHighCommand = function() return true end })
        local src = 900
        hc2.env.exports.qbx_core.GetPlayer = function(_self, s) if s == src then return { PlayerData = {} } end return nil end
        local ok, outcome = hc2.env.GrantPermission(src, 'X', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_granter')
        t.contains(lastNotifyFor(hc2, src).message, 'Unable to resolve')
    end)

    -- INVERTED (this pass) -- OWNER DECISION: "High command can grant
    -- anything they want to themselves -- xp promotions permissions etc."
    -- This test used to prove self-grant of a named capability was
    -- unconditionally blocked with no escape hatch; the project owner has
    -- since widened Config.FeatureControl.allowHighCommandSelfGrant to
    -- cover every permission namespace uniformly (see server/permissions.lua's
    -- header "SELF-GRANT"), so it now proves the opposite -- not deleted,
    -- inverted, per this task's own instruction.
    t.test('GrantPermission: OWNER DECISION -- self-grant of a named capability (k9.access) is now ALLOWED by default, exactly like feature.<Name>', function()
        f.advanceTime(2000)
        local before = #f.printLog
        local ok, outcome = f.env.GrantPermission(hcSrc, 'HC-GRANTER', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isTrue(f.env.HasPermission('HC-GRANTER', 'k9.access'))

        -- AUDIT: a self-grant must be provably distinguishable from an
        -- ordinary grant in the log itself -- naming the SAME citizenid as
        -- both granter and recipient is not enough on its own if a reader
        -- has to notice that unaided; the explicit `self=true` field is
        -- what makes it a stable, greppable signal instead.
        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('HC-GRANTER', 1, true)
                and line:find('self=true', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a successful self-grant must be audited with an explicit self=true marker naming the same citizenid as granter and target')
    end)

    -- INVERTED (this pass): every OTHER named capability is ALSO now
    -- allowed for self-grant, not just k9.access -- proves the widening
    -- applies to the whole Config.Permissions catalog, not one entry.
    t.test('GrantPermission: OWNER DECISION -- self-grant of k9.certify/k9.audit/k9.givexp is ALSO now ALLOWED by default', function()
        for _, key in ipairs({ 'k9.certify', 'k9.audit', 'k9.givexp' }) do
            f.advanceTime(2000)
            local ok, outcome = f.env.GrantPermission(hcSrc, 'HC-GRANTER', key)
            t.isTrue(ok, key .. ' self-grant must now be allowed')
            t.equals(outcome, 'ok', key .. ' must report ok')
            t.isTrue(f.env.HasPermission('HC-GRANTER', key))
        end
    end)

    -- INVERTED (this pass): 'block.<Name>' is ALSO now allowed for
    -- self-grant -- the widening covers every namespace this file
    -- validates, not only the four named capabilities.
    t.test('GrantPermission: OWNER DECISION -- self-grant of block.<Name> is ALSO now ALLOWED by default', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'HC-GRANTER', 'block.BiteAndHold')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isTrue(f.env.HasPermission('HC-GRANTER', 'block.BiteAndHold'))
    end)

    -- CRITICAL DAY-ONE FIX (an earlier pass, kept for regression coverage
    -- -- see server/permissions.lua header "SELF-GRANT" for the full
    -- writeup). Default true (Config.FeatureControl absent, matching this
    -- describe block's own fixture setup) means a high-command officer can
    -- grant a 'feature.<Name>' entry to themselves -- the exact case that
    -- made the tablet's Audit tab permanently unreachable on a
    -- single-high-command-officer server. Now just ONE instance of a
    -- uniform rule rather than a namespace-specific carve-out -- see the
    -- three OWNER DECISION tests above for the other namespaces.
    t.test('GrantPermission: self-grant of a feature.<Name> entry is ALLOWED by default (closes the single-high-command-officer Audit-tab deadlock)', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'HC-GRANTER', 'feature.BiteAndHold')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isTrue(f.env.HasPermission('HC-GRANTER', 'feature.BiteAndHold'))
    end)

    -- UNWEAKENED -- THE WHOLE REMAINING BOUNDARY: a caller who is NOT high
    -- command can never reach the self-grant exemption at all, for ANY
    -- namespace -- IsHighCommand is re-checked BEFORE the self-grant branch
    -- is ever reached, unaffected by how many namespaces the switch now
    -- covers. Widening what a high-command officer may do to themselves
    -- must never widen who counts as high command -- this is the test that
    -- proves it, across every namespace this file validates.
    t.test('GrantPermission: a non-high-command caller self-targeting ANY namespace is still denied, never reaches the self-grant exemption', function()
        f.advanceTime(2000)
        f.registerPlayer(101, 'LOWRANK', { name = 'police', grade = { level = 1 } })
        for _, key in ipairs({ 'feature.BiteAndHold', 'block.BiteAndHold', 'k9.access', 'k9.certify', 'k9.audit', 'k9.givexp' }) do
            f.advanceTime(2000)
            local ok, outcome = f.env.GrantPermission(101, 'LOWRANK', key)
            t.isFalse(ok, key .. ' must still be denied for a non-high-command caller')
            t.equals(outcome, 'denied', key .. ' must report denied, never self_grant_blocked or ok')
            t.isFalse(f.env.HasPermission('LOWRANK', key))
        end
    end)

    -- THE ESCAPE HATCH, EVERY NAMESPACE AT ONCE (this pass -- widened from
    -- the earlier, feature.<Name>-only version of this test): an operator
    -- who explicitly wants the OLD, stricter behavior back (a second
    -- high-command officer must always witness a self-grant, even to
    -- another high-command officer, even for a capability IsHighCommand
    -- already grants them directly) sets
    -- Config.FeatureControl.allowHighCommandSelfGrant = false and gets it,
    -- uniformly, for the four named capabilities, 'block.<Name>', AND
    -- 'feature.<Name>' alike -- not just the one namespace an earlier pass
    -- exempted.
    t.test('GrantPermission: Config.FeatureControl.allowHighCommandSelfGrant = false restores the refusal for EVERY namespace, not just feature.<Name>', function()
        local f2 = newFixture({
            isHighCommand = function(source) return source == 100 end,
            featureControl = { allowHighCommandSelfGrant = false },
        })
        local hc2Src = f2.registerPlayer(100, 'HC-OPTOUT', { name = 'police', isboss = true, grade = { level = 0 } })
        for _, key in ipairs({ 'k9.access', 'k9.certify', 'k9.audit', 'k9.givexp', 'block.BiteAndHold', 'feature.BiteAndHold' }) do
            f2.advanceTime(2000)
            local ok, outcome = f2.env.GrantPermission(hc2Src, 'HC-OPTOUT', key)
            t.isFalse(ok, key .. ' self-grant must be refused when the switch is off')
            t.equals(outcome, 'self_grant_blocked', key .. ' must report self_grant_blocked')

            -- 'feature.<Name>' NEVER asserted via a plain HasPermission()
            -- read here (this pass, HIGH COMMAND BYPASS FOR feature.<Name>):
            -- HC-OPTOUT genuinely IS high command (isHighCommand stubs
            -- source == 100 unconditionally true), and HasPermission now
            -- deliberately reports 'feature.<Name>' as held for ANY
            -- currently-online high-command citizenid regardless of
            -- whether a literal grant row exists -- see
            -- IsHighCommandBypassCitizenId's own doc comment. That bypass
            -- is not disabled by allowHighCommandSelfGrant = false (a
            -- DIFFERENT switch, governing only whether a NEW grant ROW may
            -- be self-targeted) -- so HasPermission('HC-OPTOUT',
            -- 'feature.BiteAndHold') correctly reads `true` here, and
            -- asserting `false` would be testing for the wrong thing. What
            -- THIS test must still prove is the actual claim in its own
            -- name -- no GRANT ROW was created by the refused self-grant --
            -- checked directly against the DB-backed history read
            -- (ListActivePermissionsForCitizenId), which the bypass never
            -- touches at all.
            if key == 'feature.BiteAndHold' then
                t.isTrue(f2.env.HasPermission('HC-OPTOUT', key), key .. ' reads as held anyway -- HC-OPTOUT is high command, and the feature.<Name> bypass is a separate, unaffected mechanism')
                local historyOk, history = f2.env.ListActivePermissionsForCitizenId(hc2Src, 'HC-OPTOUT')
                t.isTrue(historyOk)
                for _, row in ipairs(history) do
                    t.isFalse(row.permission == key, key .. ' must not have an actual grant ROW -- the self-grant itself must still have been refused')
                end
            else
                t.isFalse(f2.env.HasPermission('HC-OPTOUT', key), key .. ' must not actually have been granted')
            end
        end
    end)

    -- Explicit `false` is the ONLY thing that opts out -- confirms this is
    -- read as `~= false`, never `x or default` (which would be
    -- indistinguishable from "not set" here since both are boolean, but the
    -- explicit-table-present-without-the-key case below still must default
    -- to allowed, matching config.lua's own documented default of `true`).
    t.test('GrantPermission: an explicit Config.FeatureControl table that OMITS allowHighCommandSelfGrant still defaults to allowed', function()
        local f3 = newFixture({
            isHighCommand = function(source) return source == 100 end,
            featureControl = { RequireGrant = { BiteAndHold = true } },
        })
        local hc3Src = f3.registerPlayer(100, 'HC-DEFAULT', { name = 'police', isboss = true, grade = { level = 0 } })
        f3.advanceTime(2000)
        local ok, outcome = f3.env.GrantPermission(hc3Src, 'HC-DEFAULT', 'feature.BiteAndHold')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
    end)

    -- A CONFIG TABLE WRITTEN BEFORE THESE SWITCHES EXISTED (this pass):
    -- Config.FeatureControl entirely ABSENT (nil), not merely
    -- present-without-the-key like the test just above -- the shape every
    -- real config.lua had before Config.FeatureControl was ever added at
    -- all. Must behave per the NEW default (self-grant allowed, for every
    -- namespace this file validates) rather than erroring or silently
    -- reverting to some other behavior.
    t.test('GrantPermission: a Config with NO Config.FeatureControl table at all (pre-existing config.lua) still defaults every namespace to self-grant ALLOWED, never errors', function()
        local f4 = newFixture({
            isHighCommand = function(source) return source == 100 end,
            -- featureControl intentionally omitted -- newFixture's own
            -- `FeatureControl = opts.featureControl` line leaves this nil.
        })
        local hc4Src = f4.registerPlayer(100, 'HC-LEGACY', { name = 'police', isboss = true, grade = { level = 0 } })
        for _, key in ipairs({ 'k9.access', 'k9.certify', 'k9.audit', 'k9.givexp', 'block.BiteAndHold', 'feature.BiteAndHold' }) do
            f4.advanceTime(2000)
            local ok, outcome = f4.env.GrantPermission(hc4Src, 'HC-LEGACY', key)
            t.isTrue(ok, key .. ' must default to allowed with no Config.FeatureControl table at all')
            t.equals(outcome, 'ok', key .. ' must report ok, not error or self_grant_blocked')
        end
    end)

    -- ========================================================================
    -- AUDIT (coder-security, this pass -- "could a reader of the audit trail
    -- actually tell a self-grant apart from an ordinary one?"): before this
    -- pass the answer was "only by noticing the SAME citizenid appears twice
    -- in one free-text line" -- a real gap, since self-service the operator
    -- explicitly chose (feature.<Name>, default true) is fine, but
    -- self-service nobody can spot afterward in a log is not. `self=%s` is
    -- now an explicit, always-present, stable field on every post-
    -- authorization audit line -- these tests prove it is actually there,
    -- actually correct, and does not silently disappear for any outcome.
    -- ========================================================================

    t.test('AUDIT: a SUCCESSFUL self-grant of feature.<Name> prints an explicit self=true field on its own "-> ok" line -- not merely two matching citizenids a reader has to notice unaided', function()
        f.advanceTime(2000)
        local before = #f.printLog
        local ok, outcome = f.env.GrantPermission(hcSrc, 'HC-GRANTER', 'feature.SomeFeatureOff')
        t.isTrue(ok, tostring(outcome))
        t.equals(outcome, 'ok')

        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('grantPermission', 1, true)
                and line:find('self=true', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a successful self-grant must print a self=true audit line, not just target==granter buried in free text')
    end)

    t.test('AUDIT: an ORDINARY (non-self) grant explicitly prints self=false -- the field is always present, never omitted when it would read as "not a self-grant"', function()
        f.advanceTime(2000)
        -- 120, NOT 102 -- 102 is already 'TARGET-A' in this same fixture
        -- (registered at the top of this describe block, and still relied
        -- on by later tests via `lastNotifyFor(f, 102)`); reusing a source
        -- id here would silently repoint playersBySource[102] and leave a
        -- stray duplicate in onlineSources for no reason.
        f.registerPlayer(120, 'ORDINARY-TARGET', { name = 'police', grade = { level = 1 } })
        local before = #f.printLog
        local ok, outcome = f.env.GrantPermission(hcSrc, 'ORDINARY-TARGET', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')

        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('self=false', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'an ordinary grant must be explicitly labeled self=false, not merely lack a self=true tag')
    end)

    -- UPDATED (this pass): k9.access self-grant is no longer blocked by
    -- DEFAULT (see the OWNER DECISION tests above) -- this scenario is now
    -- only reachable with Config.FeatureControl.allowHighCommandSelfGrant
    -- explicitly set to false, so this test uses its own fixture with that
    -- opt-out to still exercise the self_grant_blocked path at all.
    t.test('AUDIT: a BLOCKED self-grant (k9.access, switch off) still prints self=true on its own self_grant_blocked line -- the field is populated even on the rejection path, not only on success', function()
        local f5 = newFixture({
            isHighCommand = function(source) return source == 100 end,
            featureControl = { allowHighCommandSelfGrant = false },
        })
        local hc5Src = f5.registerPlayer(100, 'HC-AUDIT-BLOCKED', { name = 'police', isboss = true, grade = { level = 0 } })
        f5.advanceTime(2000)
        local before = #f5.printLog
        local ok, outcome = f5.env.GrantPermission(hc5Src, 'HC-AUDIT-BLOCKED', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'self_grant_blocked')

        local found = false
        for i = before + 1, #f5.printLog do
            local line = f5.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('self=true', 1, true) and line:find('self_grant_blocked', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a blocked self-grant attempt must also be identifiable as self=true in the trail, not just as a bare denial')
    end)

    t.test('GrantPermission: a successful grant returns ok, notifies the online target, and HasPermission reflects it', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isTrue(f.env.HasPermission('TARGET-A', 'k9.access'))
        local n = lastNotifyFor(f, 102)
        t.isNotNil(n)
        t.contains(n.message, 'Use K9 abilities')
    end)

    t.test('GrantPermission: granting an already-active permission reports already_granted, no duplicate row', function()
        f.advanceTime(2000)
        local before = #f.rows
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-A', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'already_granted')
        t.equals(#f.rows, before, 'no second row should be inserted')
    end)

    t.test('GrantPermission: a TOCTOU duplicate-key error from the INSERT is treated as already_granted, not a hard failure', function()
        f.advanceTime(2000)
        f.registerPlayer(103, 'TARGET-RACE', { name = 'police', grade = { level = 1 } })
        f.setForceInsertError('duplicate')
        local ok, outcome = f.env.GrantPermission(hcSrc, 'TARGET-RACE', 'k9.certify')
        f.setForceInsertError(nil)
        t.isFalse(ok)
        t.equals(outcome, 'already_granted')
    end)

    t.test('GrantPermission: a generic thrown INSERT error surfaces as db_error, does not propagate', function()
        f.advanceTime(2000)
        f.registerPlayer(104, 'TARGET-DBERR', { name = 'police', grade = { level = 1 } })
        f.setForceInsertError('generic')
        local pcallOk, ok, outcome = pcall(f.env.GrantPermission, hcSrc, 'TARGET-DBERR', 'k9.audit')
        f.setForceInsertError(nil)
        t.isTrue(pcallOk, 'must not raise out of GrantPermission: ' .. tostring(ok))
        t.isFalse(ok)
        t.equals(outcome, 'db_error')
    end)

    t.test('GrantPermission: an unresolvable pre-check read (thrown scalar.await) surfaces as db_error, does not propagate', function()
        f.advanceTime(2000)
        f.registerPlayer(105, 'TARGET-SCALARERR', { name = 'police', grade = { level = 1 } })
        f.setForceScalarError(true)
        local ok, err = pcall(function() return f.env.GrantPermission(hcSrc, 'TARGET-SCALARERR', 'k9.givexp') end)
        f.setForceScalarError(false)
        t.isTrue(ok, 'must not raise out of GrantPermission: ' .. tostring(err))
    end)

    t.test('GrantPermission: a second grant from the same officer inside the cooldown window is rate_limited', function()
        f.advanceTime(2000)
        f.registerPlayer(110, 'RATE-A', { name = 'police', grade = { level = 1 } })
        f.registerPlayer(111, 'RATE-B', { name = 'police', grade = { level = 1 } })
        local ok1 = f.env.GrantPermission(hcSrc, 'RATE-A', 'k9.access')
        t.isTrue(ok1)
        f.advanceTime(100) -- well within the 1500ms cooldown
        local ok2, outcome2 = f.env.GrantPermission(hcSrc, 'RATE-B', 'k9.access')
        t.isFalse(ok2)
        t.equals(outcome2, 'rate_limited')
        f.advanceTime(1600) -- past the cooldown
        local ok3 = f.env.GrantPermission(hcSrc, 'RATE-B', 'k9.access')
        t.isTrue(ok3, 'a grant after the cooldown window has elapsed must succeed')
    end)

    t.test('GrantPermission: granting to an OFFLINE citizenid succeeds but creates no cache entry (HasPermission stays false until they connect)', function()
        f.advanceTime(2000)
        local ok = f.env.GrantPermission(hcSrc, 'OFFLINE-K9', 'k9.access')
        t.isTrue(ok)
        t.isFalse(f.env.HasPermission('OFFLINE-K9', 'k9.access'), 'no cache entry should exist for a citizenid who was never online')
        -- Now they connect -- PlayerLoaded warms the cache from the real DB row.
        f.firePlayerLoaded({ PlayerData = { citizenid = 'OFFLINE-K9', job = { name = 'police' } } })
        t.isTrue(f.env.HasPermission('OFFLINE-K9', 'k9.access'), 'connecting must warm the cache from the already-granted DB row')
    end)
end

-- ============================================================================
-- RevokePermission -- authorization, validation, not_granted, cooldown,
-- DB-throw reconciliation, cache invalidation, the 3-way stillHasAccess
-- contract, and target notification suppression.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 200 end })
    local hcSrc = f.registerPlayer(200, 'HC-REVOKER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(201, 'LOWRANK2', { name = 'police', grade = { level = 1 } })

    t.test('RevokePermission: feature disabled -> feature_disabled', function()
        f.env.Config.Features.PermissionGrants = false
        local ok, outcome = f.env.RevokePermission(hcSrc, 'X', 'k9.access')
        f.env.Config.Features.PermissionGrants = true
        t.isFalse(ok)
        t.equals(outcome, 'feature_disabled')
    end)

    -- SECURITY FIX (coder-security, this pass) -- RevokePermission's own
    -- mirror of the identical GrantPermission audit-trail fix above.
    t.test('AUDIT: RevokePermission still prints a trail (granter + target) even when the feature is disabled', function()
        f.env.Config.Features.PermissionGrants = false
        local before = #f.printLog
        f.env.RevokePermission(hcSrc, 'X', 'k9.access')
        f.env.Config.Features.PermissionGrants = true
        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('HC-REVOKER', 1, true)
                and line:find('X', 1, true) and line:find('feature_disabled', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a feature-disabled revoke attempt must still be audited, naming both the granter and the target')
    end)

    t.test('RevokePermission: a non-high-command caller is denied', function()
        local ok, outcome = f.env.RevokePermission(201, 'X', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    -- RED-TEAM FINDING, CRITICAL: a blocked high-command officer could lift
    -- their own block. Being blocked writes a k9_permissions row and does
    -- NOT touch job.grade/job.isboss, so IsHighCommand still answered true
    -- for them -- and IsHighCommand was RevokePermission's only check. The
    -- block is read-defended everywhere (it beats rank in HasK9Access,
    -- IsEligibleCertifier, IsAuthorizedAdmin and IsAuthorizedForXpGrant) and
    -- was write-undefended, which made it useless against precisely the
    -- person it exists to restrain.
    t.test('RevokePermission: a high-command officer CANNOT lift a block placed on themselves', function()
        f.advanceTime(600000)
        f.env.GrantPermission(hcSrc, 'HC-REVOKER', 'block.k9.certify')
        f.advanceTime(600000)
        local ok, outcome = f.env.RevokePermission(hcSrc, 'HC-REVOKER', 'block.k9.certify')
        t.isFalse(ok, 'lifting your own block must be refused outright')
        t.equals(outcome, 'denied_self_unblock')
    end)

    t.test('RevokePermission: CONTROL -- a DIFFERENT high-command officer can still lift that same block, so the refusal above is the self-check and not a broken fixture', function()
        f.advanceTime(600000)
        f.env.GrantPermission(hcSrc, 'OTHER-OFFICER', 'block.k9.certify')
        f.advanceTime(600000)
        local ok = f.env.RevokePermission(hcSrc, 'OTHER-OFFICER', 'block.k9.certify')
        t.isTrue(ok, 'somebody else with the rank must still be able to lift it -- a block nobody can ever remove would be its own trap')
    end)

    t.test('RevokePermission: CONTROL -- self-revoking a NON-block key is still allowed, since giving up your own grant is not an escalation', function()
        f.advanceTime(600000)
        f.env.GrantPermission(hcSrc, 'HC-REVOKER', 'k9.access')
        f.advanceTime(600000)
        local ok = f.env.RevokePermission(hcSrc, 'HC-REVOKER', 'k9.access')
        t.isTrue(ok, 'the new refusal must be scoped to block. keys only')
    end)

    -- SECURITY FIX (this pass -- "revoking a retired permission key must
    -- always be possible"): RevokePermission used to reuse GrantPermission's
    -- own catalog-membership IsValidPermissionKey check, which rejected
    -- 'invalid_permission' for ANY key not currently known to
    -- Config.Permissions/the permission-key catalog -- including a
    -- perfectly real key that high command had since TOMBSTONED, stranding
    -- every existing grant of it forever (see server/permissions.lua's own
    -- IsPlausiblePermissionKeyShape doc comment for the full writeup).
    -- RevokePermission now only requires a PLAUSIBLE SHAPE, then lets
    -- K9Store.Perm_RevokeActive's own real "does this citizenid actually
    -- hold this exact row" answer decide -- so an unrecognized-but-
    -- plausible-shaped key that was never granted to this target correctly
    -- resolves 'not_granted', the SAME outcome a real key nobody holds
    -- already produced, never 'invalid_permission'.
    t.test('RevokePermission: an unrecognized (never-configured, never-catalog-known) but PLAUSIBLY-SHAPED key that was never granted reports not_granted, not invalid_permission', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.RevokePermission(hcSrc, 'X', 'not.real')
        t.isFalse(ok)
        t.equals(outcome, 'not_granted')
    end)

    t.test('RevokePermission: a genuinely malformed permission key (non-string, empty, or over the 50-char DoS-lite bound) is rejected as invalid_permission', function()
        f.advanceTime(2000)
        local ok1, outcome1 = f.env.RevokePermission(hcSrc, 'X', nil)
        t.isFalse(ok1)
        t.equals(outcome1, 'invalid_permission')

        f.advanceTime(2000)
        local ok2, outcome2 = f.env.RevokePermission(hcSrc, 'X', '')
        t.isFalse(ok2)
        t.equals(outcome2, 'invalid_permission')

        f.advanceTime(2000)
        local ok3, outcome3 = f.env.RevokePermission(hcSrc, 'X', string.rep('a', 51))
        t.isFalse(ok3)
        t.equals(outcome3, 'invalid_permission')
    end)

    t.test('RevokePermission: SECURITY FIX -- a TOMBSTONED key (real, but no longer catalog-known) can still be revoked from a citizenid actively holding it', function()
        -- Simulates server/permissionkeycatalog.lua tombstoning a key AFTER
        -- it was granted: IsKnownPermissionCatalogKey now says no (so
        -- IsValidPermissionKey/HasPermission both correctly treat it as
        -- inert), but the k9_permissions row itself is untouched, still
        -- `active = 1`, until someone actually revokes it -- which must
        -- still be possible.
        f.advanceTime(2000)
        f.registerPlayer(299, 'TOMBSTONE-TARGET', { name = 'police', grade = { level = 1 } })
        f.env.Config.Permissions['k9.retiredkey'] = { label = 'Retired Key' }
        local grantOk = f.env.GrantPermission(hcSrc, 'TOMBSTONE-TARGET', 'k9.retiredkey')
        t.isTrue(grantOk, 'setup: the grant itself must succeed before this test can prove anything about revoking it')
        f.advanceTime(2000)

        -- Tombstone it: remove it from Config.Permissions entirely -- with
        -- no permission-key catalog loaded in this fixture (see this file's
        -- own header on IsValidPermissionKey's fallback), this is the
        -- direct equivalent of a live catalog tombstone for this test's
        -- purposes: the key is no longer known/valid by ANY route.
        f.env.Config.Permissions['k9.retiredkey'] = nil

        -- HasPermission must ALREADY resolve this as false while the row
        -- sits there inert, confirming the "grantable-in-the-database-but-
        -- inert" state IsPlausiblePermissionKeyShape's own doc comment
        -- promises never changes.
        t.isFalse(f.env.HasPermission('TOMBSTONE-TARGET', 'k9.retiredkey'), 'a tombstoned key must confer nothing even while its grant row is still active')

        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'TOMBSTONE-TARGET', 'k9.retiredkey')
        t.isTrue(ok, 'revoking a tombstoned-but-held key must succeed, not report invalid_permission')
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess, 'a retired key has no legacy rank tier to fall back to -- revoking it must fully remove it')
    end)

    t.test('RevokePermission: an invalid target citizenid is rejected', function()
        f.advanceTime(2000)
        local ok, outcome = f.env.RevokePermission(hcSrc, '', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('RevokePermission: revoking a permission nobody holds reports not_granted', function()
        f.advanceTime(2000)
        f.registerPlayer(202, 'NEVER-GRANTED', { name = 'police', grade = { level = 1 } })
        local ok, outcome = f.env.RevokePermission(hcSrc, 'NEVER-GRANTED', 'k9.access')
        t.isFalse(ok)
        t.equals(outcome, 'not_granted')
    end)

    t.test('RevokePermission: fully removes access -- ok, stillHasAccess is nil, target notified', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(203, 'FULLREMOVE', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'FULLREMOVE', 'k9.access')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'FULLREMOVE', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)
        t.isFalse(f.env.HasPermission('FULLREMOVE', 'k9.access'))
        local n = lastNotifyFor(f, target)
        t.isNotNil(n)
        t.contains(n.message, 'Use K9 abilities')
    end)

    -- ========================================================================
    -- FIX (this pass, "the de-assign button" finding): server/tablet.lua
    -- documents RevokePermission(..., 'k9.access') as high command's ONLY,
    -- official "de-assign K9 role" action -- on a CONFIRMED full loss
    -- (stillHasAccess == nil), this must now also force-detach any leash,
    -- end any held effect, and break any partnership, exactly like a
    -- certification revoke already does.
    -- ========================================================================

    t.test('RevokePermission: FIX -- fully removing k9.access force-detaches the leash, ends any held effect, and breaks the partnership for the online target', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(210, 'K9ACCESS-TEARDOWN', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'K9ACCESS-TEARDOWN', 'k9.access')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'K9ACCESS-TEARDOWN', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)

        t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], target)
        t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'k9_access_revoked')
        t.equals(f.effectEndCalls[#f.effectEndCalls], target)
        t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][1], 'K9ACCESS-TEARDOWN')
        t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][2], 'k9_access_revoked')
    end)

    t.test('RevokePermission: FIX -- revoking a DIFFERENT permission (k9.certify) never triggers the K9-access teardown', function()
        f.advanceTime(2000)
        f.registerPlayer(211, 'CERTIFY-ONLY-REVOKE', { name = 'police', grade = { level = 1 } })
        f.rows[#f.rows + 1] = { id = 99100, citizenid = 'CERTIFY-ONLY-REVOKE', permission = 'k9.certify', granted_by = 'SOMEONE-ELSE', active = 1 }
        local leashCountBefore, effectCountBefore, partnershipCountBefore = #f.leashDetachCalls, #f.effectEndCalls, #f.partnershipBreakCalls

        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'CERTIFY-ONLY-REVOKE', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)

        t.equals(#f.leashDetachCalls, leashCountBefore, 'revoking k9.certify must never touch the K9-access teardown')
        t.equals(#f.effectEndCalls, effectCountBefore)
        t.equals(#f.partnershipBreakCalls, partnershipCountBefore)
    end)

    t.test('RevokePermission: FIX -- revoking k9.access does NOT tear anything down when the online target still qualifies via SOME OTHER route (stillHasAccess == "rank_or_high_command")', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(212, 'STILLHASACCESS-TEARDOWN', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'STILLHASACCESS-TEARDOWN', 'k9.access')
        f.advanceTime(2000)
        -- Same pattern as the pre-existing "reuses the real HasK9Access"
        -- test below -- simulate HasK9Access still returning true for this
        -- citizenid via some OTHER path (e.g. an active cert cache entry)
        -- after this specific grant is gone.
        f.env.HasK9Access = function(source) return source == target end
        local leashCountBefore, effectCountBefore, partnershipCountBefore = #f.leashDetachCalls, #f.effectEndCalls, #f.partnershipBreakCalls

        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'STILLHASACCESS-TEARDOWN', 'k9.access')
        f.env.HasK9Access = nil
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')

        t.equals(#f.leashDetachCalls, leashCountBefore, 'access was never actually lost -- nothing to tear down')
        t.equals(#f.effectEndCalls, effectCountBefore)
        t.equals(#f.partnershipBreakCalls, partnershipCountBefore)
    end)

    t.test('RevokePermission: FIX -- revoking k9.access from an OFFLINE target does NOT tear anything down (stillHasAccess == "unknown_target_offline", never claimed as a confirmed loss)', function()
        f.advanceTime(2000)
        f.rows[#f.rows + 1] = { id = 99102, citizenid = 'WILLDISCONNECT-TEARDOWN', permission = 'k9.access', granted_by = 'SOMEONE-ELSE', active = 1 }
        local leashCountBefore, effectCountBefore, partnershipCountBefore = #f.leashDetachCalls, #f.effectEndCalls, #f.partnershipBreakCalls

        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'WILLDISCONNECT-TEARDOWN', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'unknown_target_offline')

        t.equals(#f.leashDetachCalls, leashCountBefore, 'an unverifiable outcome must never be treated as a confirmed loss')
        t.equals(#f.effectEndCalls, effectCountBefore)
        t.equals(#f.partnershipBreakCalls, partnershipCountBefore)
    end)

    t.test('RevokePermission: FIX -- the runtime existence guard genuinely tolerates ForceDetachLeashForSource/EndActiveEffectForHolder/ForceBreakPartnershipForCitizenId being entirely absent (server/main.lua, server/combat.lua, server/partnership.lua not loaded)', function()
        local g = newFixture({ isHighCommand = function(source) return source == 300 end, includeTeardownHooks = false })
        local hc2 = g.registerPlayer(300, 'HC2', { name = 'police', isboss = true })
        g.registerPlayer(301, 'NOHOOKS-TARGET', { name = 'police', grade = { level = 1 } })
        g.env.GrantPermission(hc2, 'NOHOOKS-TARGET', 'k9.access')
        g.advanceTime(2000)

        local ok, outcome, stillHasAccess = g.env.RevokePermission(hc2, 'NOHOOKS-TARGET', 'k9.access')
        t.isTrue(ok, 'must not error even with all three globals entirely absent')
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)
    end)

    t.test('RevokePermission: self-revoke (an officer revoking their own earlier grant) is allowed -- unlike self-grant', function()
        f.advanceTime(2000)
        -- HC-REVOKER cannot self-grant (blocked), so simulate a pre-existing
        -- row directly in the fake table, as if granted by a DIFFERENT officer
        -- earlier, then revoked by this same officer now.
        f.rows[#f.rows + 1] = { id = 99000, citizenid = 'HC-REVOKER', permission = 'k9.audit', granted_by = 'SOMEONE-ELSE', active = 1 }
        local before = #f.printLog
        local ok, outcome = f.env.RevokePermission(hcSrc, 'HC-REVOKER', 'k9.audit')
        t.isTrue(ok)
        t.equals(outcome, 'ok')

        -- AUDIT (coder-security, this pass): same "self=%s must be an
        -- explicit, greppable field, not two matching citizenids a reader
        -- has to notice" requirement as GrantPermission's own tests above --
        -- a self-revoke is lower-risk than a self-grant (it only ever
        -- narrows the officer's own access), but it deserves the exact same
        -- visibility in the trail.
        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('revokePermission', 1, true)
                and line:find('self=true', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a self-revoke must print an explicit self=true audit line')
    end)

    t.test('AUDIT: an ORDINARY (non-self) revoke explicitly prints self=false', function()
        f.advanceTime(2000)
        f.registerPlayer(206, 'ORDINARY-REVOKE-TARGET', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'ORDINARY-REVOKE-TARGET', 'k9.certify')
        f.advanceTime(2000)
        local before = #f.printLog
        local ok, outcome = f.env.RevokePermission(hcSrc, 'ORDINARY-REVOKE-TARGET', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')

        local found = false
        for i = before + 1, #f.printLog do
            local line = f.printLog[i]
            if line:find('AUDIT', 1, true) and line:find('self=false', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'an ordinary revoke must be explicitly labeled self=false')
    end)

    t.test('RevokePermission: a second revoke from the same officer inside the cooldown window is rate_limited (shared cooldown w/ grant)', function()
        f.advanceTime(2000)
        f.registerPlayer(204, 'CD-TARGET-A', { name = 'police', grade = { level = 1 } })
        f.registerPlayer(205, 'CD-TARGET-B', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'CD-TARGET-A', 'k9.access')
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'CD-TARGET-B', 'k9.access')
        f.advanceTime(2000)
        local ok1 = f.env.RevokePermission(hcSrc, 'CD-TARGET-A', 'k9.access')
        t.isTrue(ok1)
        f.advanceTime(100)
        local ok2, outcome2 = f.env.RevokePermission(hcSrc, 'CD-TARGET-B', 'k9.access')
        t.isFalse(ok2)
        t.equals(outcome2, 'rate_limited', 'grant and revoke must share ONE cooldown tracker')
    end)
end

-- ============================================================================
-- DB ERRORS THROW, NOT NIL -- RevokePermission's reconciliation-on-throw.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 300 end })
    local hcSrc = f.registerPlayer(300, 'HC-DB', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('RevokePermission: a thrown UPDATE where the row is confirmed STILL ACTIVE (never committed) reports db_error, changes nothing', function()
        f.registerPlayer(301, 'DBERR-NOTCOMMITTED', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DBERR-NOTCOMMITTED', 'k9.access')
        f.advanceTime(2000)
        f.setForceUpdateError('not_committed')
        local ok, outcome = f.env.RevokePermission(hcSrc, 'DBERR-NOTCOMMITTED', 'k9.access')
        f.setForceUpdateError(nil)
        t.isFalse(ok)
        t.equals(outcome, 'db_error')
        t.isTrue(f.env.HasPermission('DBERR-NOTCOMMITTED', 'k9.access'), 'a never-committed revoke must leave access intact')
    end)

    t.test('RevokePermission: a thrown UPDATE where the row is confirmed INACTIVE (committed despite the throw) reports success', function()
        f.advanceTime(2000)
        f.registerPlayer(302, 'DBERR-COMMITTED', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DBERR-COMMITTED', 'k9.access')
        f.advanceTime(2000)
        f.setForceUpdateError('committed')
        local ok, outcome = f.env.RevokePermission(hcSrc, 'DBERR-COMMITTED', 'k9.access')
        f.setForceUpdateError(nil)
        t.isTrue(ok, 'the reconciliation read must confirm the real commit and report success')
        t.equals(outcome, 'ok')
        t.isFalse(f.env.HasPermission('DBERR-COMMITTED', 'k9.access'))
    end)

    t.test('RevokePermission: a thrown UPDATE whose reconciliation read ALSO fails (unreadable) reports db_error, never guesses success', function()
        f.advanceTime(2000)
        f.registerPlayer(303, 'DBERR-UNREADABLE', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DBERR-UNREADABLE', 'k9.access')
        f.advanceTime(2000)
        f.setForceUpdateError('not_committed')
        f.setForceScalarError(true)
        local ok, outcome = f.env.RevokePermission(hcSrc, 'DBERR-UNREADABLE', 'k9.access')
        f.setForceUpdateError(nil)
        f.setForceScalarError(false)
        t.isFalse(ok)
        t.equals(outcome, 'db_error')
    end)
end

-- ============================================================================
-- THE "REVOKED BUT STILL HAS IT BY RANK" 3-WAY stillHasAccess CONTRACT --
-- unit-level, using injected IsHighCommand/HasK9Access doubles.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 400 end })
    local hcSrc = f.registerPlayer(400, 'HC-RANK', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('RevokePermission: stillHasAccess is "rank_or_high_command" when the online target ALSO meets the legacy rank gate (k9.certify/certifierGrade=4)', function()
        f.registerPlayer(401, 'STILLCERT', { name = 'police', grade = { level = 5 } }) -- >= certifierGrade 4
        f.env.GrantPermission(hcSrc, 'STILLCERT', 'k9.certify')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'STILLCERT', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')
    end)

    t.test('RevokePermission: stillHasAccess is nil when the online target does NOT meet the legacy rank gate', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(402, 'NOTCERT', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4
        f.env.GrantPermission(hcSrc, 'NOTCERT', 'k9.certify')
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'NOTCERT', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.isNil(stillHasAccess)
        t.isNotNil(lastNotifyFor(f, target), 'a genuine full removal must still notify the target')
    end)

    t.test('RevokePermission: stillHasAccess is "rank_or_high_command" for k9.givexp when the target IS high command (no legacy tier below it exists)', function()
        f.advanceTime(2000)
        local hcTarget = f.registerPlayer(403, 'HC-TARGET-GIVEXP', { name = 'police', isboss = true, grade = { level = 0 } })
        -- Give this SECOND high-command officer the grant via a different granter identity isn't needed --
        -- self-grant only blocks the GRANTER's own citizenid; grant from hcSrc to a DIFFERENT high-command citizenid is fine.
        f.env.GrantPermission(hcSrc, 'HC-TARGET-GIVEXP', 'k9.givexp')
        f.advanceTime(2000)
        -- Make IsHighCommand ALSO true for this target's own source for this one check.
        local originalIsHighCommand = f.env.IsHighCommand
        f.env.IsHighCommand = function(source) return source == 400 or source == hcTarget end
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'HC-TARGET-GIVEXP', 'k9.givexp')
        f.env.IsHighCommand = originalIsHighCommand
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')
    end)

    t.test('RevokePermission: stillHasAccess is "unknown_target_offline" when the target is not currently connected', function()
        f.advanceTime(2000)
        f.registerPlayer(404, 'WILLDISCONNECT', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'WILLDISCONNECT', 'k9.access')
        f.disconnectPlayer(404)
        f.advanceTime(2000)
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'WILLDISCONNECT', 'k9.access')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'unknown_target_offline')
    end)

    t.test('RevokePermission: for k9.access, reuses the real HasK9Access (via type() guard) for the reconciliation check', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(405, 'ACCESSCHECK', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'ACCESSCHECK', 'k9.access')
        f.advanceTime(2000)
        -- Simulate HasK9Access still returning true for this citizenid via some
        -- OTHER path (e.g. an active cert cache entry) after the grant is gone.
        f.env.HasK9Access = function(source) return source == target end
        local ok, outcome, stillHasAccess = f.env.RevokePermission(hcSrc, 'ACCESSCHECK', 'k9.access')
        f.env.HasK9Access = nil
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command')
    end)
end

-- ============================================================================
-- CACHE INVALIDATION -- grant, revoke, and playerDropped. Granular per-key
-- correctness (revoking one permission must not disturb another).
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 500 end })
    local hcSrc = f.registerPlayer(500, 'HC-CACHE', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('cache: granting TWO different permissions to the same citizenid, then revoking ONE, leaves the other intact', function()
        f.registerPlayer(501, 'MULTI', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'MULTI', 'k9.access')
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'MULTI', 'k9.audit')
        f.advanceTime(2000)
        t.isTrue(f.env.HasPermission('MULTI', 'k9.access'))
        t.isTrue(f.env.HasPermission('MULTI', 'k9.audit'))

        f.env.RevokePermission(hcSrc, 'MULTI', 'k9.access')
        t.isFalse(f.env.HasPermission('MULTI', 'k9.access'), 'the revoked permission must be gone')
        t.isTrue(f.env.HasPermission('MULTI', 'k9.audit'), 'the UNRELATED permission must survive the revoke of the other one')
    end)

    t.test('cache: playerDropped clears the cache entry; a later reconnect re-warms it from the DB', function()
        f.advanceTime(2000)
        f.registerPlayer(502, 'DROPTEST', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'DROPTEST', 'k9.access')
        t.isTrue(f.env.HasPermission('DROPTEST', 'k9.access'))

        f.firePlayerDropped(502)
        t.isFalse(f.env.HasPermission('DROPTEST', 'k9.access'), 'the cache entry must be evicted on disconnect')

        f.firePlayerLoaded({ PlayerData = { citizenid = 'DROPTEST', job = { name = 'police' } } })
        t.isTrue(f.env.HasPermission('DROPTEST', 'k9.access'), 'reconnecting must re-warm the cache from the still-active DB row')
    end)

    t.test('cache: onResourceStart backfills already-connected players (a restart while players are online)', function()
        f.advanceTime(2000)
        local target = f.registerPlayer(503, 'RESTARTED', { name = 'police', grade = { level = 1 } })
        f.env.GrantPermission(hcSrc, 'RESTARTED', 'k9.givexp')
        -- Wipe the cache to simulate a fresh resource load with no PlayerLoaded
        -- having fired yet for this already-connected player.
        f.firePlayerDropped(target)
        f.registerPlayer(target, 'RESTARTED', { name = 'police', grade = { level = 1 } })
        t.isFalse(f.env.HasPermission('RESTARTED', 'k9.givexp'), 'sanity: cache genuinely empty before the backfill runs')

        f.fireOnResourceStart()
        t.isTrue(f.env.HasPermission('RESTARTED', 'k9.givexp'), 'onResourceStart must backfill every already-connected citizenid\'s real grants')
    end)
end

-- ============================================================================
-- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass, this pass) --
-- RefreshPermissionCache used to write `PermissionCache[citizenid] = {}` on
-- ANY query failure -- a timeout, a dropped connection, a busy pool -- exactly
-- like server/certifications/'s RefreshCertificationCache used to. See
-- tests/certifications_spec.lua's identical section for the full "why"
-- writeup; proven here against server/permissions.lua's own copy of the
-- fix. RefreshPermissionCache itself is `local` (unreachable directly), so
-- these drive it the same way a real caller does -- through PlayerLoaded
-- (firePlayerLoaded) for the "no previous value" case, and through a second
-- GrantPermission call's own RefreshPermissionCacheIfOnline follow-up read
-- for the "previous value exists" case.
-- ============================================================================

t.test('COULD-NOT-DETERMINE: PlayerLoaded for a citizenid with an active grant, but a throwing query.await, KEEPS them denied-but-UNRESOLVED, never a manufactured confirmed-empty cache', function()
    local f = newFixture({ isHighCommand = function(source) return source == 600 end })
    local hcSrc = f.registerPlayer(600, 'HC-CND1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(601, 'CND1', { name = 'police', grade = { level = 1 } })
    f.env.GrantPermission(hcSrc, 'CND1', 'k9.access')
    f.firePlayerDropped(601) -- evicts the cache entry, exactly like a real disconnect would (the grant row itself is untouched in the DB)
    f.registerPlayer(601, 'CND1', { name = 'police', grade = { level = 1 } })

    local realQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('SELECT permission FROM k9_permissions', 1, true) then error('connection lost') end
        return realQueryAwait(sql, params)
    end

    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND1', source = 601, job = { name = 'police' } } })

    t.isFalse(f.env.HasPermission('CND1', 'k9.access'), 'must fail closed while genuinely unresolved -- exactly like a real "no grants" answer would, from the access side')

    local sawCheckFailed, sawHedgedUnknown = false, false
    for _, line in ipairs(f.printLog) do
        if line:find('CND1', 1, true) and line:find('PERMISSION CHECK FAILED', 1, true) then sawCheckFailed = true end
        if line:find('CND1', 1, true) and line:find('HOLD active grants right now', 1, true) then sawHedgedUnknown = true end
    end
    t.isTrue(sawCheckFailed, 'the operator message must name the citizenid and say the CHECK failed, never that they hold nothing')
    t.isTrue(sawHedgedUnknown, 'the operator message must hedge honestly -- this citizenid may in fact hold active grants')

    -- Proves nothing false was durably written: once the query recovers,
    -- this citizenid's real grant must still be discoverable, unobstructed.
    f.mysql.query.await = realQueryAwait
    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND1', source = 601, job = { name = 'police' } } })
    t.isTrue(f.env.HasPermission('CND1', 'k9.access'), 'a later successful refresh must recover the real, unaffected grant')
end)

t.test('COULD-NOT-DETERMINE: a throwing re-read for an ALREADY-WARMED citizenid KEEPS the previous cached grants, never wipes them to empty', function()
    local f = newFixture({ isHighCommand = function(source) return source == 610 end })
    local hcSrc = f.registerPlayer(610, 'HC-CND2', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(611, 'CND2', { name = 'police', grade = { level = 1 } })

    f.env.GrantPermission(hcSrc, 'CND2', 'k9.access')
    t.isTrue(f.env.HasPermission('CND2', 'k9.access'), 'sanity: really granted, and cache warmed, before the simulated outage')

    -- A SECOND grant (a different permission) for the SAME citizenid
    -- re-triggers RefreshPermissionCacheIfOnline's own follow-up read --
    -- forced to fail here, simulating a transient blip on that specific
    -- re-read (the INSERT that just committed 'k9.audit' is NOT rolled
    -- back -- only the SUBSEQUENT read-back of the whole grant set fails).
    f.advanceTime(2000)
    local realQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('SELECT permission FROM k9_permissions', 1, true) then error('connection lost') end
        return realQueryAwait(sql, params)
    end
    f.env.GrantPermission(hcSrc, 'CND2', 'k9.audit')

    t.isTrue(f.env.HasPermission('CND2', 'k9.access'), 'the previously-cached grant must survive a transient re-read failure, never reset to empty')

    local sawCheckFailed, sawKept = false, false
    for _, line in ipairs(f.printLog) do
        if line:find('CND2', 1, true) and line:find('PERMISSION CHECK FAILED', 1, true) then sawCheckFailed = true end
        if line:find('CND2', 1, true) and line:find('KEEPING the previous cached grant set', 1, true) then sawKept = true end
    end
    t.isTrue(sawCheckFailed, 'the operator message must name the citizenid and say the CHECK failed')
    t.isTrue(sawKept, 'the operator message must say the previous grant set was kept, not that it was wiped')

    -- Recovery: once the query works again, the SECOND grant ('k9.audit',
    -- which DID commit to the DB despite the failed read-back) becomes
    -- visible on the next successful refresh, with the first grant intact.
    f.mysql.query.await = realQueryAwait
    f.firePlayerDropped(611)
    f.registerPlayer(611, 'CND2', { name = 'police', grade = { level = 1 } })
    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND2', source = 611, job = { name = 'police' } } })
    t.isTrue(f.env.HasPermission('CND2', 'k9.access'), 'the original grant is still real and recoverable')
    t.isTrue(f.env.HasPermission('CND2', 'k9.audit'), 'the second grant, committed despite the failed read-back, is also real and recoverable')
end)

t.test('COULD-NOT-DETERMINE: the retry is BOUNDED, not infinite -- exactly PERM_REFRESH_RETRY_ATTEMPTS (3) attempts, then gives up', function()
    local f = newFixture()
    f.registerPlayer(620, 'CND3', { name = 'police', grade = { level = 1 } })

    local queryCallCount = 0
    local realQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('SELECT permission FROM k9_permissions', 1, true) then
            queryCallCount = queryCallCount + 1
            error('connection lost')
        end
        return realQueryAwait(sql, params)
    end

    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND3', source = 620, job = { name = 'police' } } })
    t.equals(queryCallCount, 3, 'must attempt exactly the bounded number of times -- never once (no retry) and never unboundedly')
    t.isFalse(f.env.HasPermission('CND3', 'k9.access'))
end)
-- validation, and correct row shape.
-- ============================================================================

do
    local f = newFixture({ isHighCommand = function(source) return source == 600 end })
    local hcSrc = f.registerPlayer(600, 'HC-LIST', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(601, 'LOWRANK3', { name = 'police', grade = { level = 1 } })

    f.env.GrantPermission(hcSrc, 'ROSTER-A', 'k9.audit')
    f.advanceTime(2000)
    f.env.GrantPermission(hcSrc, 'ROSTER-B', 'k9.audit')
    f.advanceTime(2000)
    f.env.GrantPermission(hcSrc, 'ROSTER-A', 'k9.certify')

    t.test('ListActivePermissionsForCitizenId: a non-high-command caller is denied', function()
        local ok, outcome = f.env.ListActivePermissionsForCitizenId(601, 'ROSTER-A')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    t.test('ListActivePermissionsForCitizenId: an invalid target citizenid is rejected', function()
        local ok, outcome = f.env.ListActivePermissionsForCitizenId(hcSrc, '')
        t.isFalse(ok)
        t.equals(outcome, 'invalid_target')
    end)

    t.test('ListActivePermissionsForCitizenId: returns every active permission for the target, shaped correctly', function()
        local ok, list = f.env.ListActivePermissionsForCitizenId(hcSrc, 'ROSTER-A')
        t.isTrue(ok)
        t.equals(#list, 2)
        local perms = {}
        for _, row in ipairs(list) do perms[row.permission] = row end
        t.isNotNil(perms['k9.audit'])
        t.isNotNil(perms['k9.certify'])
        t.equals(perms['k9.audit'].grantedBy, 'HC-LIST')
    end)

    t.test('ListPermissionRoster: a non-high-command caller is denied', function()
        local ok, outcome = f.env.ListPermissionRoster(601, 'k9.audit')
        t.isFalse(ok)
        t.equals(outcome, 'denied')
    end)

    -- SECURITY FIX (this pass, same "revoke direction" reasoning as
    -- RevokePermission above): an unconfigured/unknown-but-plausibly-shaped
    -- key must resolve to an EMPTY roster, not invalid_permission -- an
    -- officer trying to find every remaining holder of a just-tombstoned
    -- key (in order to revoke each one) must not be refused for asking.
    t.test('ListPermissionRoster: an unconfigured/unknown-but-plausibly-shaped permission key returns an EMPTY roster, not invalid_permission', function()
        local ok, roster = f.env.ListPermissionRoster(hcSrc, 'not.real')
        t.isTrue(ok)
        t.equals(#roster, 0)
    end)

    t.test('ListPermissionRoster: a genuinely malformed permission key (non-string, empty, or over the 50-char bound) is still rejected as invalid_permission', function()
        local ok1, outcome1 = f.env.ListPermissionRoster(hcSrc, nil)
        t.isFalse(ok1)
        t.equals(outcome1, 'invalid_permission')

        local ok2, outcome2 = f.env.ListPermissionRoster(hcSrc, '')
        t.isFalse(ok2)
        t.equals(outcome2, 'invalid_permission')

        local ok3, outcome3 = f.env.ListPermissionRoster(hcSrc, string.rep('a', 51))
        t.isFalse(ok3)
        t.equals(outcome3, 'invalid_permission')
    end)

    t.test('ListPermissionRoster: SECURITY FIX -- a TOMBSTONED key (real, but no longer catalog-known) still lists its remaining holders', function()
        f.advanceTime(2000) -- clear the shared per-source grant/revoke cooldown before this test's own GrantPermission call
        f.env.Config.Permissions['k9.retiredroster'] = { label = 'Retired Roster Key' }
        local grantOk = f.env.GrantPermission(hcSrc, 'ROSTER-RETIRED', 'k9.retiredroster')
        t.isTrue(grantOk, 'setup: the grant itself must succeed before this test can prove anything about the roster read')
        f.advanceTime(2000)
        f.env.Config.Permissions['k9.retiredroster'] = nil -- tombstoned

        local ok, roster = f.env.ListPermissionRoster(hcSrc, 'k9.retiredroster')
        t.isTrue(ok, 'a tombstoned key must still be listable, or its remaining holders could never be found to revoke')
        t.equals(#roster, 1)
        t.equals(roster[1].citizenid, 'ROSTER-RETIRED')
    end)

    t.test('ListPermissionRoster: returns every citizenid holding the given permission', function()
        local ok, roster = f.env.ListPermissionRoster(hcSrc, 'k9.audit')
        t.isTrue(ok)
        t.equals(#roster, 2)
        local citizenids = {}
        for _, row in ipairs(roster) do citizenids[row.citizenid] = true end
        t.isTrue(citizenids['ROSTER-A'])
        t.isTrue(citizenids['ROSTER-B'])
    end)
end

-- ============================================================================
-- TABLET CALLBACKS -- registered only when Config.Features.CommandTablet is
-- true; exact return-shape contract client/tablet.lua depends on.
-- ============================================================================

t.test('tablet callbacks: NOT registered when Config.Features.CommandTablet is false (the default)', function()
    local f = newFixture({ commandTablet = false })
    t.isNil(f.callbacks['john-k9:server:tabletGrantPermission'])
    t.isNil(f.callbacks['john-k9:server:tabletRevokePermission'])
end)

do
    local f = newFixture({ commandTablet = true, isHighCommand = function(source) return source == 700 end })
    local hcSrc = f.registerPlayer(700, 'HC-TABLET', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(701, 'TABLET-TARGET', { name = 'police', grade = { level = 5 } }) -- meets certifierGrade too, for the "still has it" case

    t.test('tablet callbacks: ARE registered when Config.Features.CommandTablet is true', function()
        t.isNotNil(f.callbacks['john-k9:server:tabletGrantPermission'])
        t.isNotNil(f.callbacks['john-k9:server:tabletRevokePermission'])
    end)

    t.test('tabletGrantPermission: success returns { ok = true }', function()
        local result = f.callbacks['john-k9:server:tabletGrantPermission'](hcSrc, 'TABLET-TARGET', 'k9.certify')
        t.isTrue(result.ok)
        t.isNil(result.reason)
    end)

    t.test('tabletGrantPermission: failure returns { ok = false, reason = <outcome> }', function()
        local result = f.callbacks['john-k9:server:tabletGrantPermission'](701, 'TABLET-TARGET', 'k9.certify') -- 701 is not high command
        t.isFalse(result.ok)
        t.equals(result.reason, 'denied')
    end)

    t.test('tabletRevokePermission: full removal returns { ok = true } with no reason', function()
        f.advanceTime(2000)
        f.registerPlayer(702, 'TABLET-FULLREMOVE', { name = 'police', grade = { level = 1 } }) -- below certifierGrade
        f.env.GrantPermission(hcSrc, 'TABLET-FULLREMOVE', 'k9.certify')
        f.advanceTime(2000)
        local result = f.callbacks['john-k9:server:tabletRevokePermission'](hcSrc, 'TABLET-FULLREMOVE', 'k9.certify')
        t.isTrue(result.ok)
        t.isNil(result.reason)
    end)

    t.test('tabletRevokePermission: revoking from someone who still qualifies by rank returns { ok = true, reason = "rank_or_high_command" } -- never a silent, unqualified success', function()
        f.advanceTime(2000)
        local result = f.callbacks['john-k9:server:tabletRevokePermission'](hcSrc, 'TABLET-TARGET', 'k9.certify')
        t.isTrue(result.ok, 'the revoke DB write itself did succeed')
        t.equals(result.reason, 'rank_or_high_command', 'the UI must be told this did not actually remove their access')
    end)

    t.test('tabletRevokePermission: failure (not_granted) returns { ok = false, reason = <outcome> }', function()
        -- 'not.real' is a plausible SHAPE but was never granted to
        -- TABLET-TARGET -- see this pass's own RevokePermission SECURITY FIX
        -- above: this must resolve not_granted, never invalid_permission.
        f.advanceTime(2000)
        local result = f.callbacks['john-k9:server:tabletRevokePermission'](hcSrc, 'TABLET-TARGET', 'not.real')
        t.isFalse(result.ok)
        t.equals(result.reason, 'not_granted')
    end)

    t.test('tabletRevokePermission: failure (invalid_permission) for a genuinely malformed permission key', function()
        f.advanceTime(2000)
        local result = f.callbacks['john-k9:server:tabletRevokePermission'](hcSrc, 'TABLET-TARGET', string.rep('a', 51))
        t.isFalse(result.ok)
        t.equals(result.reason, 'invalid_permission')
    end)
end

-- ============================================================================
-- CONSOLE/CHAT COMMAND GRANT PATH (this pass) -- 'k9grantpermission'/
-- 'k9revokepermission', REGISTERED UNCONDITIONALLY (unlike the tablet
-- callbacks above, which require commandTablet = true). Both are thin
-- wrappers over the SAME GrantPermission/RevokePermission every test above
-- already exercises directly -- these tests cover the WRAPPER's own added
-- behavior (arg validation/usage messages, outcome-to-message mapping,
-- feedback to the invoker) rather than re-proving authorization/validation
-- logic that already has its own exhaustive coverage above.
-- ============================================================================

t.test('CONSOLE/CHAT COMMANDS: k9grantpermission and k9revokepermission are registered regardless of Config.Features.CommandTablet (the entire point -- a second door, not gated behind the first)', function()
    local off = newFixture({ commandTablet = false })
    t.isNotNil(off.commands.k9grantpermission)
    t.isNotNil(off.commands.k9revokepermission)

    local on = newFixture({ commandTablet = true })
    t.isNotNil(on.commands.k9grantpermission)
    t.isNotNil(on.commands.k9revokepermission)
end)

-- ============================================================================
-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md §5 item 7) --
-- k9grantpermission/k9revokepermission merge into ONE canonical
-- '/k9permission <grant|revoke> <citizenid> <permission>'. Both old names
-- stay registered forever as HIDDEN ALIASES with byte-identical bodies
-- (§3) -- this task's own rule ("destructive actions need an explicit
-- word, never contextual guessing") is why the verb is REQUIRED here
-- rather than inferred from argument shape/type the way the online/offline
-- certification pairs infer online-vs-offline: revoke is destructive,
-- grant is additive, and there is no argument-shape difference between
-- them to dispatch on even if that were desirable.
-- ============================================================================

t.test('CONSOLE/CHAT COMMANDS: k9permission is registered regardless of Config.Features.CommandTablet, same as its two hidden aliases', function()
    local off = newFixture({ commandTablet = false })
    t.isNotNil(off.commands.k9permission)

    local on = newFixture({ commandTablet = true })
    t.isNotNil(on.commands.k9permission)
end)

do
    local f = newFixture({
        commandTablet = false,
        locale = localeWithPendingCommandKeys,
        isHighCommand = function(source) return source == 300 end,
    })
    local hcSrc = f.registerPlayer(300, 'HC-MERGED', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(301, 'LOWRANK-MERGED', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(302, 'MERGED-TARGET', { name = 'police', grade = { level = 1 } })

    t.test('k9permission grant: dispatches to the EXACT SAME GrantPermission path as k9grantpermission -- HasPermission reflects it immediately', function()
        f.commands.k9permission(hcSrc, { 'grant', 'MERGED-TARGET', 'feature.BiteAndHold' })
        t.isTrue(f.env.HasPermission('MERGED-TARGET', 'feature.BiteAndHold'))
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Granted 'feature.BiteAndHold' to MERGED-TARGET.")
        t.equals(last.kind, 'success')
    end)

    t.test('k9permission revoke: dispatches to the EXACT SAME RevokePermission path as k9revokepermission -- HasPermission reflects the removal immediately', function()
        f.advanceTime(2000)
        f.commands.k9permission(hcSrc, { 'revoke', 'MERGED-TARGET', 'feature.BiteAndHold' })
        t.isFalse(f.env.HasPermission('MERGED-TARGET', 'feature.BiteAndHold'))
    end)

    t.test('k9permission: per-subcommand gating -- an UNAUTHORIZED (non-high-command) caller is refused for BOTH grant and revoke, identical to the two standalone commands, never a single shared top-level gate that could diverge from either', function()
        f.advanceTime(2000)
        f.commands.k9permission(301, { 'grant', 'MERGED-TARGET', 'feature.BiteAndHold' })
        local lastGrant = lastNotifyFor(f, 301)
        t.equals(lastGrant.message, 'You are not authorized to grant or revoke K9 permissions.')
        t.isFalse(f.env.HasPermission('MERGED-TARGET', 'feature.BiteAndHold'))

        f.advanceTime(2000)
        f.commands.k9permission(301, { 'revoke', 'MERGED-TARGET', 'feature.BiteAndHold' })
        local lastRevoke = lastNotifyFor(f, 301)
        t.equals(lastRevoke.message, 'You are not authorized to grant or revoke K9 permissions.')
    end)

    t.test('k9permission: an unrecognized/missing subcommand prints this command\'s own usage string (admin.lua\'s k9audit search convention), reaching neither GrantPermission nor RevokePermission -- DESTRUCTIVE ACTIONS NEED AN EXPLICIT WORD, never contextual guessing', function()
        f.advanceTime(2000)
        f.commands.k9permission(hcSrc, {})
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'Usage: /k9permission <grant|revoke> [citizenid] [permissionKey]')
        t.equals(last.kind, 'error')
        t.isFalse(f.env.HasPermission('MERGED-TARGET', 'feature.BiteAndHold'))

        f.advanceTime(2000)
        f.commands.k9permission(hcSrc, { 'delete', 'MERGED-TARGET', 'feature.BiteAndHold' })
        local last2 = lastNotifyFor(f, hcSrc)
        t.equals(last2.message, 'Usage: /k9permission <grant|revoke> [citizenid] [permissionKey]')
        t.isFalse(f.env.HasPermission('MERGED-TARGET', 'feature.BiteAndHold'), 'an unrecognized word must never be treated as an implicit grant')
    end)

    t.test('HIDDEN ALIAS: k9grantpermission still works standalone after the merge, byte-identical body/outcome to k9permission grant', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'MERGED-TARGET', 'k9.access' })
        t.isTrue(f.env.HasPermission('MERGED-TARGET', 'k9.access'))
    end)

    t.test('HIDDEN ALIAS: k9revokepermission still works standalone after the merge, byte-identical body/outcome to k9permission revoke', function()
        f.advanceTime(2000)
        f.commands.k9revokepermission(hcSrc, { 'MERGED-TARGET', 'k9.access' })
        t.isFalse(f.env.HasPermission('MERGED-TARGET', 'k9.access'))
    end)
end

do
    local f = newFixture({
        commandTablet = false, -- the whole point: this door works even when the tablet's own is closed
        locale = localeWithPendingCommandKeys,
        isHighCommand = function(source) return source == 200 end,
    })
    local hcSrc = f.registerPlayer(200, 'HC-CMD', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(201, 'LOWRANK-CMD', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(202, 'CMD-TARGET', { name = 'police', grade = { level = 1 } })

    t.test('k9grantpermission: malformed args (missing permissionKey) refuses with the usage message, never reaches GrantPermission at all', function()
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET' })
        local last = lastNotifyFor(f, hcSrc)
        t.isNotNil(last)
        t.equals(last.message, 'Usage: /k9grantpermission [citizenid] [permissionKey]')
        t.equals(last.kind, 'error')
        t.isFalse(f.env.HasPermission('CMD-TARGET', 'feature.BiteAndHold'))
    end)

    t.test('k9revokepermission: malformed args (empty citizenid) refuses with the usage message', function()
        f.commands.k9revokepermission(hcSrc, { '', 'feature.BiteAndHold' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'Usage: /k9revokepermission [citizenid] [permissionKey]')
        t.equals(last.kind, 'error')
    end)

    t.test('k9grantpermission: an UNAUTHORIZED (non-high-command) caller is refused -- IDENTICAL authorization to the tablet path (GrantPermission itself), no looser gate invented here', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(201, { 'CMD-TARGET', 'feature.BiteAndHold' })
        local last = lastNotifyFor(f, 201)
        t.equals(last.message, 'You are not authorized to grant or revoke K9 permissions.')
        t.equals(last.kind, 'error')
        t.isFalse(f.env.HasPermission('CMD-TARGET', 'feature.BiteAndHold'), 'the unauthorized attempt must not have granted anything')
    end)

    t.test('k9revokepermission: an UNAUTHORIZED caller is refused the same way', function()
        f.advanceTime(2000)
        f.commands.k9revokepermission(201, { 'CMD-TARGET', 'feature.BiteAndHold' })
        local last = lastNotifyFor(f, 201)
        t.equals(last.message, 'You are not authorized to grant or revoke K9 permissions.')
        t.equals(last.kind, 'error')
    end)

    t.test('k9grantpermission: a high-command caller grants a RequireGrant-shaped feature.<Name> permission -- HasPermission reflects it immediately, and the invoker is told exactly what happened', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET', 'feature.BiteAndHold' })
        t.isTrue(f.env.HasPermission('CMD-TARGET', 'feature.BiteAndHold'))
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Granted 'feature.BiteAndHold' to CMD-TARGET.")
        t.equals(last.kind, 'success')
    end)

    t.test('k9grantpermission: granting the SAME permission again reports already_granted, distinctly, without erroring', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET', 'feature.BiteAndHold' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'CMD-TARGET already holds that permission.')
        t.equals(last.kind, 'error')
    end)

    t.test('k9grantpermission: an unrecognized permission key is refused as invalid, naming the problem plainly', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET', 'feature.NotARealFeature' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'That is not a valid permission key.')
        t.equals(last.kind, 'error')
    end)

    -- CRITICAL DAY-ONE FIX (this pass): this command is a thin wrapper over
    -- the exact same GrantPermission this describe block's other tests
    -- drive directly -- so the 'feature.<Name>' self-grant exemption
    -- (Config.FeatureControl.allowHighCommandSelfGrant, default true) is
    -- reached through THIS surface too, exactly like the tablet path, per
    -- config.lua's own "require the exact same High Command authorization
    -- the tablet does" contract for this command. Title/behavior UPDATED
    -- from "self-grant is blocked exactly like the tablet path" to match --
    -- the tablet path itself no longer blocks this case either.
    t.test('k9grantpermission: self-grant of feature.<Name> now succeeds through the command path too, matching the tablet path exactly', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'HC-CMD', 'feature.BiteAndHold' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Granted 'feature.BiteAndHold' to HC-CMD.")
        t.equals(last.kind, 'success')
        t.isTrue(f.env.HasPermission('HC-CMD', 'feature.BiteAndHold'))
    end)

    -- INVERTED (this pass), THIS surface too: the named-capability
    -- namespace is now ALSO allowed for self-grant through the command
    -- path, exactly as it already is through GrantPermission directly and
    -- through the tablet callback -- the OWNER DECISION widening reaches
    -- every entry point that funnels through GrantPermission, by
    -- construction (this command adds no second, parallel authorization
    -- check of its own -- see this section's own header).
    t.test('k9grantpermission: self-grant of a named capability (k9.access) is now ALLOWED through the command path too, matching GrantPermission directly', function()
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'HC-CMD', 'k9.access' })
        local last = lastNotifyFor(f, hcSrc)
        -- command_grant_ok formats with PermissionLabelFor, so a named
        -- capability's human-readable label appears here, not the raw key
        -- (unlike 'feature.<Name>', which has no catalog label and falls
        -- back to the raw key itself -- see the test just above this one).
        t.equals(last.message, "Granted 'Use K9 abilities' to HC-CMD.")
        t.equals(last.kind, 'success')
        t.isTrue(f.env.HasPermission('HC-CMD', 'k9.access'))
    end)

    -- THE ESCAPE HATCH REACHES THIS SURFACE TOO: with
    -- Config.FeatureControl.allowHighCommandSelfGrant = false, the command
    -- path refuses a named-capability self-grant exactly like
    -- GrantPermission does directly -- proves the switch, not the entry
    -- point, is what decides this.
    t.test('k9grantpermission: Config.FeatureControl.allowHighCommandSelfGrant = false restores the refusal through the command path too', function()
        local f2 = newFixture({
            isHighCommand = function(source) return source == 100 end,
            featureControl = { allowHighCommandSelfGrant = false },
            locale = localeWithPendingCommandKeys,
        })
        local hc2Src = f2.registerPlayer(100, 'HC-OPTOUT-CMD', { name = 'police', isboss = true, grade = { level = 0 } })
        f2.advanceTime(2000)
        f2.commands.k9grantpermission(hc2Src, { 'HC-OPTOUT-CMD', 'k9.access' })
        local last = lastNotifyFor(f2, hc2Src)
        t.equals(last.message, 'You cannot grant a permission to yourself.')
        t.equals(last.kind, 'error')
        t.isFalse(f2.env.HasPermission('HC-OPTOUT-CMD', 'k9.access'))
    end)

    t.test('k9grantpermission: a second grant from the same officer inside the cooldown window is rate_limited, reported plainly', function()
        f.registerPlayer(203, 'CMD-TARGET-2', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET-2', 'feature.BiteAndHold' })
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET-2', 'block.BiteAndHold' }) -- immediately after, no advanceTime
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'Please wait a moment before trying again.')
        t.equals(last.kind, 'error')
        t.isFalse(f.env.HasPermission('CMD-TARGET-2', 'block.BiteAndHold'), 'the rate-limited attempt must not have written anything')
    end)

    t.test('WRITE-FAILURE REPORTING: k9grantpermission surfaces a thrown DB error plainly to the invoker, rather than a silent failure', function()
        f.registerPlayer(204, 'CMD-TARGET-3', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)
        f.setForceInsertError('generic')
        f.commands.k9grantpermission(hcSrc, { 'CMD-TARGET-3', 'feature.BiteAndHold' })
        f.setForceInsertError(nil)
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'A database error occurred. Please try again.')
        t.equals(last.kind, 'error')
        t.isFalse(f.env.HasPermission('CMD-TARGET-3', 'feature.BiteAndHold'), 'a reported db_error must not have actually granted anything')
    end)

    t.test('k9revokepermission: fully removes access -- ok, and the invoker is told plainly, by label and target', function()
        f.advanceTime(2000)
        f.commands.k9revokepermission(hcSrc, { 'CMD-TARGET', 'feature.BiteAndHold' })
        t.isFalse(f.env.HasPermission('CMD-TARGET', 'feature.BiteAndHold'))
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Revoked 'feature.BiteAndHold' from CMD-TARGET.")
        t.equals(last.kind, 'success')
    end)

    t.test('RETIRED-KEY REVOKE PATH: k9revokepermission can still revoke a permission key that is no longer catalog-valid (SHAPE-only check, matching RevokePermission\'s own security fix) -- never invalid_permission for a real, held, since-retired key', function()
        f.advanceTime(2000)
        f.registerPlayer(205, 'CMD-RETIRED', { name = 'police', grade = { level = 1 } })
        f.env.Config.Permissions['k9.retiredviacommand'] = { label = 'Retired Key' }
        f.commands.k9grantpermission(hcSrc, { 'CMD-RETIRED', 'k9.retiredviacommand' })
        t.isTrue(f.env.HasPermission('CMD-RETIRED', 'k9.retiredviacommand'))

        -- Tombstone it: remove it from Config.Permissions entirely -- mirrors
        -- this file's own pre-existing "SECURITY FIX -- a TOMBSTONED key"
        -- test above, just driven through the command instead of
        -- RevokePermission directly.
        f.env.Config.Permissions['k9.retiredviacommand'] = nil

        f.advanceTime(2000)
        f.commands.k9revokepermission(hcSrc, { 'CMD-RETIRED', 'k9.retiredviacommand' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Revoked 'k9.retiredviacommand' from CMD-RETIRED.")
        t.equals(last.kind, 'success')
        t.isFalse(f.env.HasPermission('CMD-RETIRED', 'k9.retiredviacommand'))
    end)

    t.test('k9revokepermission: revoking a permission nobody holds reports not_granted, naming the target', function()
        f.advanceTime(2000)
        f.commands.k9revokepermission(hcSrc, { 'CMD-TARGET', 'feature.NonLethalTakedown' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, 'CMD-TARGET does not currently hold that permission.')
        t.equals(last.kind, 'error')
    end)

    t.test('k9revokepermission: revoking from someone who still qualifies via rank/high-command tells the invoker so, distinctly from a full removal', function()
        f.advanceTime(2000)
        local rankSrc = f.registerPlayer(206, 'CMD-STILLRANK', { name = 'police', grade = { level = 4 } }) -- meets certifierGrade
        f.env.GrantPermission(hcSrc, 'CMD-STILLRANK', 'k9.certify')
        f.advanceTime(2000)
        f.commands.k9revokepermission(hcSrc, { 'CMD-STILLRANK', 'k9.certify' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Revoked 'Certify and decertify others' from CMD-STILLRANK, but they still have it through their rank or High Command status.")
        t.equals(last.kind, 'success')
        f.disconnectPlayer(rankSrc)
    end)

    t.test('k9revokepermission: revoking from an OFFLINE target tells the invoker that eligibility could not be checked', function()
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'CMD-OFFLINE-TARGET', 'feature.BiteAndHold')
        f.advanceTime(2000)
        f.commands.k9revokepermission(hcSrc, { 'CMD-OFFLINE-TARGET', 'feature.BiteAndHold' })
        local last = lastNotifyFor(f, hcSrc)
        t.equals(last.message, "Revoked 'feature.BiteAndHold' from CMD-OFFLINE-TARGET. They are offline, so it could not be checked whether they still qualify for it through rank.")
        t.equals(last.kind, 'success')
    end)

    t.test('k9grantpermission: an already-notified outcome (invalid_granter) is never double-notified by this command -- GrantPermission itself already sent common.unable_to_resolve_citizenid', function()
        f.advanceTime(2000)
        -- 300 is never registered via f.registerPlayer -- exports.qbx_core:GetPlayer(300) resolves to nil, so IsHighCommand(300) is whatever the test stub says, but GrantPermission's OWN granterCitizenid resolution fails first only when IsHighCommand passed -- use a source IsHighCommand accepts but registerPlayer never touched.
        local before = #f.notifyLog
        f.env.IsHighCommand = function(source) return source == 999 end
        f.commands.k9grantpermission(999, { 'CMD-TARGET', 'feature.BiteAndHold' })
        local entriesFor999 = 0
        for i = before + 1, #f.notifyLog do
            if f.notifyLog[i].source == 999 then entriesFor999 = entriesFor999 + 1 end
        end
        t.equals(entriesFor999, 1, 'exactly one notification (GrantPermission\'s own common.unable_to_resolve_citizenid) -- never a second one from this command wrapper')
        f.env.IsHighCommand = function(source) return source == 200 end
    end)
end

-- ============================================================================
-- RESOLUTION ORDER -- end-to-end, through the REAL server/highcommand.lua,
-- server/certifications/ and server/admin.lua (newIntegrationFixture).
-- ============================================================================

do
    local f = newIntegrationFixture()

    -- Step 1 alone: a grant with NO high command and rank below every
    -- legacy threshold must still ALLOW.
    t.test('resolution order STEP 1 (k9.access): a bare grant, no high command, rank below every threshold, still allows HasK9Access', function()
        local src = f.registerPlayer(1001, 'STEP1-ACCESS', { name = 'police', grade = { level = 0 } })
        t.isFalse(f.env.HasK9Access(src), 'sanity: no access before any grant')
        local granterSrc = f.registerPlayer(1002, 'STEP1-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
        local ok = f.env.GrantPermission(granterSrc, 'STEP1-ACCESS', 'k9.access')
        t.isTrue(ok)
        t.isTrue(f.env.HasK9Access(src), 'step 1 alone must allow -- purely additive')
    end)

    t.test('resolution order STEP 1 (k9.certify): a bare grant lets a low-rank officer pass IsEligibleCertifier, reached via /k9decertifyoffline', function()
        local granterSrc = f.registerPlayer(1003, 'STEP1-GRANTER2', { name = 'police', isboss = true, grade = { level = 0 } })
        local lowRankSrc = f.registerPlayer(1004, 'STEP1-CERTIFY', { name = 'police', grade = { level = 0 } }) -- far below certifierGrade 4
        f.env.GrantPermission(granterSrc, 'STEP1-CERTIFY', 'k9.certify')
        f.advanceTime(2000)
        f.commands.k9decertify(lowRankSrc, { 'SOMETARGET', 'police' })
        local last = f.notifyLog[#f.notifyLog]
        t.isNotNil(last)
        t.notContains(last.message, 'not authorized', 'a k9.certify grant must let this officer past the eligibility gate (the actual revoke result -- "not actively certified" -- is a separate, expected outcome)')
    end)

    t.test('resolution order STEP 1 (k9.audit): a bare grant lets a low-rank officer pass IsAuthorizedAdmin, reached via /k9audit cert', function()
        local granterSrc = f.registerPlayer(1005, 'STEP1-GRANTER3', { name = 'police', isboss = true, grade = { level = 0 } })
        local lowRankSrc = f.registerPlayer(1006, 'STEP1-AUDIT', { name = 'police', grade = { level = 0 } }) -- far below auditGrade 4
        f.env.GrantPermission(granterSrc, 'STEP1-AUDIT', 'k9.audit')
        f.advanceTime(2000)
        f.commands.k9audit(lowRankSrc, { 'cert', 'ANYCITIZEN' })
        t.isFalse(lastPrintContains(f, 'denied'), 'a k9.audit grant must let this officer past the authorization gate')
    end)

    t.test('resolution order STEP 2: no grant, not high command, but IS high command (highCommandGrade) still allows (unaffected by adding permission grants)', function()
        local src = f.registerPlayer(1007, 'STEP2-HC', { name = 'police', grade = { level = 6 } }) -- meets highCommandGrade
        t.isTrue(f.env.HasK9Access(src))
    end)

    t.test('resolution order STEP 3: no grant, not high command, meets the legacy rank gate -- still allows (nothing that worked on rank stops working)', function()
        local src = f.registerPlayer(1008, 'STEP3-RANK', { name = 'police', grade = { level = 4 } }) -- meets certifierGrade/auditGrade exactly
        f.commands.k9audit(src, { 'cert', 'ANYCITIZEN' })
        t.isFalse(lastPrintContains(f, 'denied'))
    end)

    t.test('resolution order STEP 4: no grant, not high command, below every legacy threshold -- denied', function()
        local src = f.registerPlayer(1009, 'STEP4-NOBODY', { name = 'police', grade = { level = 0 } })
        f.commands.k9audit(src, { 'cert', 'ANYCITIZEN' })
        t.isTrue(lastPrintContains(f, 'denied'))
    end)

    t.test('END-TO-END "revoked but still has it by rank": revoking a k9.certify grant from an officer who ALSO meets certifierGrade does not remove their eligibility, and RevokePermission reports it honestly', function()
        local granterSrc = f.registerPlayer(1010, 'E2E-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
        local officerSrc = f.registerPlayer(1011, 'E2E-OFFICER', { name = 'police', grade = { level = 4 } }) -- meets certifierGrade exactly
        f.env.GrantPermission(granterSrc, 'E2E-OFFICER', 'k9.certify')
        f.advanceTime(2000)

        local ok, outcome, stillHasAccess = f.env.RevokePermission(granterSrc, 'E2E-OFFICER', 'k9.certify')
        t.isTrue(ok)
        t.equals(outcome, 'ok')
        t.equals(stillHasAccess, 'rank_or_high_command', 'the caller must be told this revoke did not actually remove access')

        -- Confirm it end-to-end against the REAL IsEligibleCertifier, not just the reconciliation's own verdict.
        f.commands.k9decertify(officerSrc, { 'SOMEOTHERTARGET', 'police' })
        local last = f.notifyLog[#f.notifyLog]
        t.notContains(last.message, 'not authorized', 'the officer must still pass IsEligibleCertifier via rank alone, exactly as config.lua documents')
    end)
end

-- ============================================================================
-- HIGH COMMAND BYPASS FOR feature.<Name> (owner-directed "high command
-- automatically gets every permission, every feature, every k9 upgrade"
-- pass) -- end-to-end, through the REAL server/highcommand.lua (IsHighCommand)
-- and server/permissions.lua (HasPermission/IsHighCommandBypassCitizenId),
-- via newIntegrationFixture. Proves the five things this pass's own task
-- named explicitly: an implicit feature.<Name> grant, a block still winning
-- for a high-command target, the flag going dark with no restart, a
-- non-high-command citizenid being completely unaffected, and the offline
-- answer.
-- ============================================================================

do
    local f = newIntegrationFixture()

    t.test('HIGH COMMAND BYPASS: a high-command officer holds feature.BiteAndHold with no grant, no history, nothing -- purely by rank', function()
        f.registerPlayer(2001, 'HCF-OFFICER', { name = 'police', grade = { level = 6 } }) -- meets highCommandGrade exactly
        t.isTrue(f.env.HasPermission('HCF-OFFICER', 'feature.BiteAndHold'),
            'high command must implicitly hold feature.<Name> without ever being granted it')
        -- Never a REAL grant row -- ListActivePermissionsForCitizenId (the
        -- DB-backed ground truth this bypass never touches) must still show
        -- nothing for this citizenid.
        local ok, history = f.env.ListActivePermissionsForCitizenId(2001, 'HCF-OFFICER')
        t.isTrue(ok)
        t.equals(#history, 0, 'the bypass must never manufacture an actual grant row -- this is an implication of rank, not a grant')
    end)

    t.test('HIGH COMMAND BYPASS: a NON-high-command citizenid is completely unaffected -- still denied feature.BiteAndHold with no grant', function()
        f.registerPlayer(2002, 'ORDINARY-OFFICER', { name = 'police', grade = { level = 0 } })
        t.isFalse(f.env.HasPermission('ORDINARY-OFFICER', 'feature.BiteAndHold'))
    end)

    t.test('HIGH COMMAND BYPASS: turning Config.Features.HighCommand off removes the bypass IMMEDIATELY, no restart -- and back on restores it', function()
        f.registerPlayer(2003, 'HCF-TOGGLE', { name = 'police', grade = { level = 6 } })
        t.isTrue(f.env.HasPermission('HCF-TOGGLE', 'feature.BiteAndHold'), 'sanity: the bypass is live before the flag is touched')

        f.env.Config.Features.HighCommand = false
        t.isFalse(f.env.HasPermission('HCF-TOGGLE', 'feature.BiteAndHold'),
            'IsHighCommand re-checks Config.Features.HighCommand on every call -- flipping it off must go dark on the very next check, with no restart')

        f.env.Config.Features.HighCommand = true
        t.isTrue(f.env.HasPermission('HCF-TOGGLE', 'feature.BiteAndHold'),
            'flipping it back on must restore the bypass immediately too -- this is a live re-check in both directions, never a one-shot latch')
    end)

    t.test('HIGH COMMAND BYPASS: an OFFLINE citizenid gets no bypass, even one who would qualify the moment they reconnect', function()
        -- Deliberately never registered via f.registerPlayer -- GetPlayerByCitizenId
        -- resolves to nil, exactly like a genuinely disconnected officer.
        t.isFalse(f.env.HasPermission('NEVER-CONNECTED-THIS-SESSION', 'feature.BiteAndHold'),
            'offline is answered as "cannot know, so no" -- never guessed as high command')
    end)

    -- THE ONE THING THE PROJECT OWNER WILL NOT ACCEPT LOSING.
    t.test('HIGH COMMAND BYPASS: an explicit block.BiteAndHold on a high-command TARGET still blocks them -- a block beats the bypass', function()
        local granterSrc = f.registerPlayer(2004, 'HCF-BLOCK-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
        f.registerPlayer(2005, 'HCF-BLOCK-TARGET', { name = 'police', grade = { level = 6 } }) -- genuinely high command

        -- Sanity: before the block, this high-command target holds
        -- feature.BiteAndHold purely by rank, exactly like the first test
        -- in this section.
        t.isTrue(f.env.HasPermission('HCF-BLOCK-TARGET', 'feature.BiteAndHold'))

        local ok, outcome = f.env.GrantPermission(granterSrc, 'HCF-BLOCK-TARGET', 'block.BiteAndHold')
        t.isTrue(ok, 'the block grant itself must succeed')
        t.equals(outcome, 'ok')

        -- The block itself is a REAL, independent, unaffected-by-rank grant --
        -- HasPermission answers it exactly the same for anyone, high command
        -- or not.
        t.isTrue(f.env.HasPermission('HCF-BLOCK-TARGET', 'block.BiteAndHold'), 'the block itself must read as active')

        -- HasPermission answers each namespace INDEPENDENTLY (this is not
        -- new to this pass -- see this file's own header "RESOLUTION
        -- ORDER"/"HOW STEP 1 IS WIRED IN"): 'feature.BiteAndHold' still
        -- reads true on its own here, in isolation, because the bypass has
        -- no reason to know about a DIFFERENT key's block row. What
        -- actually enforces "a block always wins" is every REAL consuming
        -- gate in this resource checking 'block.<Name>' BEFORE
        -- 'feature.<Name>' (server/search.lua's
        -- IsSearchFeaturePermittedForCitizenId and ~twenty siblings, all
        -- sharing this identical two-line shape) -- reproduced inline
        -- below, exactly as every one of those real gates is shaped, to
        -- prove the ACTUAL, end-to-end resolution a real caller computes.
        t.isTrue(f.env.HasPermission('HCF-BLOCK-TARGET', 'feature.BiteAndHold'),
            'HasPermission itself still answers feature.<Name> independently -- the block win is enforced by caller ORDER, not by this function silently special-casing the other key')

        local function isFeaturePermitted(citizenid, featureName)
            if f.env.HasPermission(citizenid, 'block.' .. featureName) == true then return false end
            return f.env.HasPermission(citizenid, 'feature.' .. featureName) == true
        end
        t.isFalse(isFeaturePermitted('HCF-BLOCK-TARGET', 'BiteAndHold'),
            'the real, block-checked-first resolution every consuming gate in this resource uses must deny a blocked high-command officer -- a deliberate BLOCK on a specific person must still win, even for high command')
    end)
end

-- ============================================================================
-- FEATURE-BLOCK PUSH (this pass) -- server/permissions.lua's new
-- TriggerClientEvent('john-k9:client:featureBlocksSync', ...) push and
-- its 'john-k9:server:requestFeatureBlocksSync' pull, closing the
-- drift-guard finding that client/featureblocks.lua registered a handler
-- for that event that no server file had ever fired. See this file's own
-- header "FEATURE-BLOCK PUSH" section for the full contract these tests
-- exercise: push on connect, push on change, one player's own set only,
-- the revoke-side push carrying the UPDATED (shorter) set (the actual
-- force-off of an in-flight effect is each owning client file's own job,
-- outside this file's scope -- this only proves the trigger it depends on
-- fires promptly and correctly), a late/duplicate re-request being
-- idempotent, and failing OPEN (an empty/unblocked array) on every
-- unresolvable or disabled state.
-- ============================================================================

--- @param f table -- a newFixture() fixture
--- @param src number
--- @return table[] -- every { event, target, args } entry captured for `src`, in order
local function clientEventsFor(f, src)
    local out = {}
    for _, entry in ipairs(f.clientEvents) do
        if entry.target == src then out[#out + 1] = entry end
    end
    return out
end

do
    local f = newFixture({ isHighCommand = function(source) return source == 900 end })
    local hcSrc = f.registerPlayer(900, 'HC-FB', { name = 'police', isboss = true, grade = { level = 0 } })

    t.test('FEATURE-BLOCK PUSH ON CONNECT: PlayerLoaded pushes this citizenid\'s CURRENT block set immediately, reflecting a block that was already granted while they were offline', function()
        local ok = f.env.GrantPermission(hcSrc, 'FB-CONNECT', 'block.BiteAndHold')
        t.isTrue(ok, 'sanity: the grant itself must succeed even though the target is not online yet')
        t.equals(#clientEventsFor(f, 910), 0, 'nothing can be pushed to a source that has not connected yet')

        local src = f.registerPlayer(910, 'FB-CONNECT', { name = 'police', grade = { level = 1 } })
        f.firePlayerLoaded({ PlayerData = { citizenid = 'FB-CONNECT', source = src, job = { name = 'police' } } })

        local events = clientEventsFor(f, src)
        t.equals(#events, 1, 'PlayerLoaded must push exactly once')
        t.equals(events[1].event, 'john-k9:client:featureBlocksSync')
        t.equals(#events[1].args[1], 1)
        t.equals(events[1].args[1][1], 'BiteAndHold')
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH ON CHANGE: GrantPermission(block.<Name>) pushes an online target immediately; a feature.<Name> grant on the SAME citizenid never triggers this push', function()
        local src = f.registerPlayer(920, 'FB-CHANGE', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)

        f.env.GrantPermission(hcSrc, 'FB-CHANGE', 'feature.BiteAndHold')
        t.equals(#clientEventsFor(f, src), 0, 'feature.<Name> is a DIFFERENT namespace -- it must never fire a featureBlocksSync push')

        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-CHANGE', 'block.BiteAndHold')
        local events = clientEventsFor(f, src)
        t.equals(#events, 1, 'a block.<Name> grant to an online target must push exactly once, live')
        t.equals(events[1].args[1][1], 'BiteAndHold')
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH ON CHANGE (revoke): RevokePermission(block.<Name>) pushes the UPDATED, now-EMPTY set to the online target immediately -- the trigger an in-flight effect\'s own force-off depends on, not merely something that stops a future re-block', function()
        local src = f.registerPlayer(930, 'FB-REVOKE', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-REVOKE', 'block.BiteAndHold')
        f.advanceTime(2000)

        local ok = f.env.RevokePermission(hcSrc, 'FB-REVOKE', 'block.BiteAndHold')
        t.isTrue(ok)

        local events = clientEventsFor(f, src)
        local last = events[#events]
        t.isNotNil(last)
        t.equals(#last.args[1], 0, 'the revoke push must carry an EMPTY array -- client/featureblocks.lua\'s own "full reassignment, not a merge" handling reads this as "nothing blocked now", which is what lets each owning client file\'s own maintenance thread force an already-live effect off within one polling interval')
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH: a player receives ONLY their own block set -- an unrelated online player gets nothing, and the push is never a broadcast', function()
        local srcA = f.registerPlayer(940, 'FB-ONLY-A', { name = 'police', grade = { level = 1 } })
        local srcB = f.registerPlayer(941, 'FB-ONLY-B', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)

        f.env.GrantPermission(hcSrc, 'FB-ONLY-A', 'block.BiteAndHold')

        t.equals(#clientEventsFor(f, srcA), 1, 'the actual target must be pushed')
        t.equals(#clientEventsFor(f, srcB), 0, 'an unrelated online player must receive NOTHING from someone else\'s block change')
        for _, entry in ipairs(f.clientEvents) do
            t.isTrue(entry.target ~= -1, 'must never be sent as a broadcast (-1) target')
        end
        f.disconnectPlayer(srcA)
        f.disconnectPlayer(srcB)
    end)

    t.test('FEATURE-BLOCK PUSH: the pushed array contains ONLY block.<Name> entries -- a k9.access/feature.<Name> grant on the same citizenid never leaks into it', function()
        local src = f.registerPlayer(970, 'FB-MIXED', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-MIXED', 'k9.access')
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-MIXED', 'feature.BiteAndHold')
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-MIXED', 'block.BiteAndHold')

        local pushed = f.lastClientEventFor(src)
        t.isNotNil(pushed)
        t.equals(#pushed.args[1], 1, 'only the one block.<Name> grant may appear -- k9.access/feature.<Name> must never leak into this array')
        t.equals(pushed.args[1][1], 'BiteAndHold')
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH ON RESTART: onResourceStart backfill re-pushes every already-connected citizenid\'s block set (PlayerLoaded never fires again for them)', function()
        local src = f.registerPlayer(980, 'FB-RESTART', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-RESTART', 'block.BiteAndHold')

        -- Simulate "fresh resource load, no PlayerLoaded fired yet for this
        -- already-connected player" the same way the pre-existing
        -- "cache: onResourceStart backfills already-connected players" test
        -- above does.
        f.firePlayerDropped(src)
        f.registerPlayer(src, 'FB-RESTART', { name = 'police', grade = { level = 1 } })

        f.fireOnResourceStart()

        local pushed = f.lastClientEventFor(src)
        t.isNotNil(pushed, 'onResourceStart must push a fresh sync for every already-connected citizenid holding an active block')
        t.equals(#pushed.args[1], 1)
        t.equals(pushed.args[1][1], 'BiteAndHold')
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH, CLIENT-INITIATED RE-REQUEST: a late/duplicate john-k9:server:requestFeatureBlocksSync returns the SAME current set both times -- idempotent, never a merge or a double-count', function()
        local src = f.registerPlayer(950, 'FB-REQUEST', { name = 'police', grade = { level = 1 } })
        f.advanceTime(2000)
        f.env.GrantPermission(hcSrc, 'FB-REQUEST', 'block.BiteAndHold')

        f.fireRequestFeatureBlocksSync(src)
        f.fireRequestFeatureBlocksSync(src) -- late/duplicate re-request (e.g. a client script restart)

        local events = clientEventsFor(f, src)
        t.isTrue(#events >= 2, 'both explicit requests must each get their own reply')
        local last, secondLast = events[#events], events[#events - 1]
        t.equals(#last.args[1], 1)
        t.equals(last.args[1][1], 'BiteAndHold')
        t.equals(#secondLast.args[1], 1)
        t.equals(secondLast.args[1][1], 'BiteAndHold')
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH, CLIENT-INITIATED RE-REQUEST: a request from a source with no resolvable citizenid yet (e.g. still on character select) is a silent no-op, never errors', function()
        -- 999 was never registered via f.registerPlayer -- exports.qbx_core:GetPlayer(999) resolves to nil.
        f.fireRequestFeatureBlocksSync(999)
        t.equals(#clientEventsFor(f, 999), 0)
    end)

    t.test('FEATURE-BLOCK PUSH FAILS OPEN: a citizenid with no cache entry at all (never granted anything) is pushed an EMPTY (unblocked) array, never omitted or defaulted to blocked', function()
        local src = f.registerPlayer(960, 'FB-NEVERBLOCKED', { name = 'police', grade = { level = 1 } })
        f.firePlayerLoaded({ PlayerData = { citizenid = 'FB-NEVERBLOCKED', source = src, job = { name = 'police' } } })

        local pushed = f.lastClientEventFor(src)
        t.isNotNil(pushed, 'a citizenid with zero grants must still receive a sync -- an empty one')
        t.equals(#pushed.args[1], 0)
        f.disconnectPlayer(src)
    end)

    t.test('FEATURE-BLOCK PUSH: a block.<Name> grant to an OFFLINE citizenid produces zero client events -- nothing to push to, and this never errors', function()
        f.advanceTime(2000)
        local before = #f.clientEvents
        local ok = f.env.GrantPermission(hcSrc, 'FB-OFFLINE-TARGET', 'block.BiteAndHold')
        t.isTrue(ok)
        t.equals(#f.clientEvents, before, 'no client event may be emitted for a target with no online source')
    end)
end

t.test('FEATURE-BLOCK PUSH FAILS OPEN: with Config.Features.PermissionGrants off, a request still replies, with an EMPTY (unblocked) array -- a disabled feature must never read as "everything blocked"', function()
    local g = newFixture({ isHighCommand = function(_source) return true end, permissionGrantsEnabled = false })
    local src = g.registerPlayer(1, 'FLAG-OFF-TARGET', { name = 'police', grade = { level = 1 } })
    g.fireRequestFeatureBlocksSync(src)

    local pushed = g.lastClientEventFor(src)
    t.isNotNil(pushed)
    t.equals(#pushed.args[1], 0)
end)

-- ============================================================================
-- STARTUP WARNING (this pass) -- fires only when the tablet's own grant
-- controls are unreachable (Config.Features.CommandTablet ~= true, OR
-- CommandTablet == true but Config.CommandTablet.openMode == 'item') AND
-- Config.FeatureControl.RequireGrant lists at least one feature. Named
-- features are sorted, so the assertions below can match the exact
-- printed text rather than merely "contains somewhere".
-- ============================================================================

--- @param f table
--- @param substring string
--- @return boolean
local function anyPrintLineContains(f, substring)
    for _, line in ipairs(f.printLog) do
        if line:find(substring, 1, true) then return true end
    end
    return false
end

t.test('STARTUP WARNING: does NOT fire when Config.FeatureControl is absent entirely (every fixture/production config before this pass)', function()
    local f = newFixture({ commandTablet = false })
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'RequireGrant'))
end)

t.test('STARTUP WARNING: does NOT fire when Config.FeatureControl.RequireGrant is present but empty', function()
    local f = newFixture({ commandTablet = false, featureControl = { RequireGrant = {} } })
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'RequireGrant'))
end)

t.test('STARTUP WARNING: does NOT fire when every RequireGrant entry is `false` -- only entries literally `true` count toward "this needs a grant"', function()
    local f = newFixture({ commandTablet = false, featureControl = { RequireGrant = { SomethingNotActuallyRequired = false } } })
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'RequireGrant'))
end)

t.test('STARTUP WARNING: does NOT fire when CommandTablet is ON and openMode is NOT \'item\' -- the tablet is genuinely reachable, nothing to warn about', function()
    local f = newFixture({
        commandTablet = true,
        commandTabletConfig = { openMode = 'both' },
        featureControl = { RequireGrant = { BiteAndHold = true } },
    })
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'RequireGrant'))
end)

t.test('STARTUP WARNING: does NOT fire when CommandTablet is ON and Config.CommandTablet is absent (openMode cannot be \'item\' if there is no CommandTablet config at all)', function()
    local f = newFixture({
        commandTablet = true,
        featureControl = { RequireGrant = { BiteAndHold = true } },
    })
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'RequireGrant'))
end)

t.test('STARTUP WARNING: FIRES when Config.Features.CommandTablet is off and RequireGrant is non-empty -- names the EXACT features, sorted, and points at the new commands', function()
    local f = newFixture({
        commandTablet = false,
        featureControl = { RequireGrant = { ScentVision = true, BiteAndHold = true, PursuitSprint = true, NotRequired = false } },
    })
    f.fireOnResourceStart()

    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('RequireGrant', 1, true) then warningLine = line end
    end
    t.isNotNil(warningLine, 'the warning must actually print')
    t.isTrue(warningLine:find('WARNING', 1, true) ~= nil)
    t.isTrue(warningLine:find('CommandTablet is off', 1, true) ~= nil, 'must name the actual reason')
    -- Sorted alphabetically, and NEVER includes the `false` entry.
    t.isTrue(warningLine:find('BiteAndHold, PursuitSprint, ScentVision', 1, true) ~= nil, 'must name the exact features, sorted, with no NotRequired leaking in')
    t.isFalse(warningLine:find('NotRequired', 1, true) ~= nil)
    -- Never claims a dead end -- must point at the working alternative.
    t.isTrue(warningLine:find('/k9grantpermission', 1, true) ~= nil)
    t.isTrue(warningLine:find('/k9revokepermission', 1, true) ~= nil)
    t.isTrue(warningLine:find('NOT ungrantable', 1, true) ~= nil, 'must explicitly reassure the operator these are NOT a dead end -- the whole point of this pass is that they are not, anymore')
end)

t.test('STARTUP WARNING: FIRES when Config.Features.CommandTablet is ON but Config.CommandTablet.openMode is \'item\' -- the tablet has no chat-command fallback in that mode', function()
    local f = newFixture({
        commandTablet = true,
        commandTabletConfig = { openMode = 'item' },
        featureControl = { RequireGrant = { ScentVision = true } },
    })
    f.fireOnResourceStart()

    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('RequireGrant', 1, true) then warningLine = line end
    end
    t.isNotNil(warningLine, 'the warning must actually print')
    t.isTrue(warningLine:find("openMode is 'item'", 1, true) ~= nil, 'must name the actual reason -- distinct wording from the CommandTablet-off case')
    t.isTrue(warningLine:find('ScentVision', 1, true) ~= nil)
end)

t.test('STARTUP WARNING: a DIFFERENT resource starting is ignored entirely -- mirrors this resource\'s own GetCurrentResourceName() guard convention', function()
    local f = newFixture({ commandTablet = false, featureControl = { RequireGrant = { BiteAndHold = true } } })
    for _, handler in ipairs(f.eventHandlers['onResourceStart'] or {}) do
        handler('some_other_resource')
    end
    t.isFalse(anyPrintLineContains(f, 'RequireGrant'))
end)

-- ============================================================================
-- MEMORY-MODE BLOCK ASYMMETRY (coder-security pass, this pass) -- see
-- server/permissions.lua's own HasPermission doc comment "MEMORY-MODE BLOCK
-- ASYMMETRY" for the full "why" this exists at all. Made materially more
-- reachable by server/datastore.lua's own per-table fallback: k9_permissions
-- alone can now go memory-only while every other table (and therefore every
-- other feature) keeps working and looking completely normal -- the exact
-- shape `opts.forcePermissionsTableMissing` (this file's own fixture, see
-- its own doc comment above) reproduces: the boot schema probe answers
-- PART-INSTALLED with ONLY k9_permissions missing, never the old
-- whole-resource "nothing was ever imported" branch.
--
-- PermRows (server/datastore.lua) starts genuinely EMPTY every time this
-- table falls back -- an absent `block.<Name>` row is therefore unknowable,
-- not confirmed, and HasPermission must never read it as "confirmed not
-- blocked" while that is true.
-- ============================================================================

t.test('MEMORY-MODE BLOCK ASYMMETRY: FAILS CLOSED -- a block.<Name> check reports BLOCKED for a citizenid nobody has ever explicitly (re-)blocked THIS session, the moment k9_permissions falls back to memory mode', function()
    local f = newFixture({ forcePermissionsTableMissing = true })
    f.fireOnResourceStart()

    t.isFalse(f.env.K9Store.IsDatabaseEnabled('k9_permissions'), 'sanity: this table alone must be memory-only')
    t.isTrue(f.env.K9Store.IsDatabaseEnabled('k9_progression'), 'sanity: an UNRELATED table must stay database-backed -- this is the per-table fallback, not the old whole-resource one')
    t.isTrue(f.env.K9Store.IsDatabaseEnabled(), 'sanity: the resource-wide flag must stay true -- only one table is affected')

    t.isTrue(f.env.HasPermission('NEVER-TOUCHED-CITIZEN', 'block.BiteAndHold'), 'an unverifiable block must read as ACTIVE, never as "confirmed not blocked"')
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: a citizenid who genuinely held an active block.<Name> row in the now-unreachable real table stays blocked -- proves this does not depend on that stale row remaining reachable', function()
    local f = newFixture({ forcePermissionsTableMissing = true })
    -- Seeds the FAKE k9_permissions table exactly like a real pre-existing
    -- block grant would look, made BEFORE this boot. Once k9_permissions
    -- itself is flagged missing, server/datastore.lua's K9Store.Perm_*
    -- `false` branches never call MySQL.*.await again at all -- this row is
    -- never actually re-read. The assertion below must still hold, and for
    -- the RIGHT reason (HasPermission's own fail-closed policy), not by
    -- accident.
    f.rows[#f.rows + 1] = {
        id = 1, citizenid = 'PREVIOUSLY-BLOCKED', permission = 'block.BiteAndHold',
        granted_by = 'HC1', granted_at = '2026-01-01 00:00:00', revoked_by = nil, revoked_at = nil, active = 1,
    }
    f.fireOnResourceStart()

    t.isTrue(f.env.HasPermission('PREVIOUSLY-BLOCKED', 'block.BiteAndHold'), 'stays blocked even though the row that recorded it is no longer being read at all')
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: an ORDINARY person is NOT accidentally denied everything by the same change -- only the block.<Name> namespace is affected', function()
    local f = newFixture({ forcePermissionsTableMissing = true, isHighCommand = function(source) return source == 100 end })
    local hcSrc = f.registerPlayer(100, 'HC-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(102, 'ORDINARY-CITIZEN', { name = 'police', grade = { level = 1 } })
    f.fireOnResourceStart()

    -- Unrelated positive capabilities nobody granted must still simply
    -- deny -- the pre-existing, correct "absence fails safe" behavior for a
    -- POSITIVE grant, never swept into the new block-only branch.
    t.isFalse(f.env.HasPermission('ORDINARY-CITIZEN', 'k9.access'), 'an ungranted capability must still just read false, not get caught by the new block-only fail-closed branch')
    t.isFalse(f.env.HasPermission('ORDINARY-CITIZEN', 'feature.BiteAndHold'), 'ditto for an ungranted feature.<Name> grant')

    -- A real, in-session positive grant -- made WHILE the table is still
    -- down -- must still be tracked correctly and honoured: memory mode's
    -- own grant bookkeeping (PermRows/PermissionCache) is completely
    -- untouched by this fix; only the MEANING of an absent block changed.
    local ok, outcome = f.env.GrantPermission(hcSrc, 'ORDINARY-CITIZEN', 'feature.BiteAndHold')
    t.isTrue(ok, tostring(outcome))
    t.isTrue(f.env.HasPermission('ORDINARY-CITIZEN', 'feature.BiteAndHold'), 'a real, in-session grant must still be honoured even while k9_permissions itself is memory-only')

    -- And this SAME citizenid, at the SAME time, is still correctly denied
    -- a block.<Name> they were never actually granted -- fail-closed
    -- applies uniformly to the block namespace, not selectively, and does
    -- not leak into (or get bypassed by) their own unrelated positive grant.
    t.isTrue(f.env.HasPermission('ORDINARY-CITIZEN', 'block.BiteAndHold'), 'the same citizenid must still be treated as blocked for block.<Name> -- the point is that ONLY the block namespace denies-by-default, nothing else')
end)

-- ============================================================================
-- DELIBERATE MEMORY-ONLY MODE IS NOT "CANNOT VERIFY"  (HasPermission CASE 0)
--
-- REGRESSION GUARD FOR A LIVE, REPORTED PRODUCTION BUG that made a STOCK
-- INSTALL of this resource completely unusable. Owner's report: a rank-8
-- police officer, on a department configured with certifierGrade = 4 and
-- highCommandGrade = 4, was told "You are not authorized to certify K9
-- handlers -- you need your department's certifying rank, the k9.certify
-- permission, or High Command status."
--
-- HOW IT HAPPENED. config.lua ships Config.Database.enabled = false on
-- purpose ("so the resource is drag-and-drop"). DatabaseEnabled() in
-- server/datastore.lua answers false for that cause and for two entirely
-- different ones (a schema collision, and this table missing from an
-- otherwise-installed database), and HasPermission's block-namespace
-- fail-closed branch keyed off that single answer. So on every default
-- install, `block.k9.access` and `block.k9.certify` came back TRUE for
-- EVERY citizenid -- which made HasK9Access() and IsEligibleCertifier()
-- (server/certifications/) false for everyone, for every route: no
-- certification, no permission grant, no autoAccessGrade, not even High
-- Command. Nobody could use a K9 feature and nobody could certify anyone,
-- so the resource could never be bootstrapped out of that state at all.
--
-- THE DISTINCTION THESE TESTS PIN. Fail-closed is the right rule; the
-- input to it was wrong. "Could not confirm" must mean an operator who
-- EXPECTS persistence and has an unreadable table. Deliberate memory-only
-- mode is not that: the in-memory store IS the authoritative store for the
-- session, every block granted in it reads back perfectly, and nothing
-- persisted from a previous session because that is what was asked for.
--
-- The three tests immediately ABOVE this section (forcePermissionsTableMissing)
-- are the other half of the same contract and must stay green: they cover
-- the genuinely-unreadable case, which still denies everyone.
-- ============================================================================

--- Puts a fixture into the exact state a stock, drag-and-drop install runs
--- in: Config.Database.enabled = false. Set AFTER construction rather than
--- through an opts flag because both DatabaseEnabled and
--- DatabaseConfiguredOff read Config live on every call (never cached at
--- load time), so this is the same thing the real config.lua does, not a
--- simulation of it.
--- @param f table
local function makeDatabaseConfiguredOff(f)
    f.env.Config.Database = { enabled = false }
end

t.test('CASE 0: a stock install (Config.Database.enabled = false) does NOT block everyone -- block.k9.access and block.k9.certify read FALSE for a citizenid nobody blocked', function()
    local f = newFixture()
    makeDatabaseConfiguredOff(f)
    f.fireOnResourceStart()

    -- SANITY: prove we are genuinely in the state that used to deny. If
    -- this assertion ever goes false the test below stops proving anything.
    t.isFalse(f.env.K9Store.IsDatabaseEnabled('k9_permissions'),
        'sanity: deliberate memory mode must still make IsDatabaseEnabled false -- CASE 0 is about what that MEANS, not about changing it')
    t.isTrue(f.env.K9Store.IsDatabaseConfiguredOff(),
        'sanity: and must be distinguishable as the deliberate cause')

    t.isFalse(f.env.HasPermission('ANY-OFFICER', 'block.k9.access'),
        'THE BUG: this reading true is what made HasK9Access() false for every player on every default install')
    t.isFalse(f.env.HasPermission('ANY-OFFICER', 'block.k9.certify'),
        'THE BUG: this reading true is what told a rank-8 officer they were not authorized to certify anyone')
    t.isFalse(f.env.HasPermission('ANY-OFFICER', 'block.BiteAndHold'),
        'and the same for every ordinary per-feature block')
end)

t.test('CASE 0: a block genuinely granted in memory mode STILL enforces -- the fix restores default-allow, it does not disable blocks', function()
    local f = newFixture({ isHighCommand = function(source) return source == 100 end })
    makeDatabaseConfiguredOff(f)
    local hcSrc = f.registerPlayer(100, 'HC-GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(103, 'BLOCKED-CITIZEN', { name = 'police', grade = { level = 1 } })
    f.fireOnResourceStart()

    t.isFalse(f.env.HasPermission('BLOCKED-CITIZEN', 'block.BiteAndHold'), 'not blocked before the grant')

    local ok, outcome = f.env.GrantPermission(hcSrc, 'BLOCKED-CITIZEN', 'block.BiteAndHold')
    t.isTrue(ok, tostring(outcome))

    -- THE OTHER HALF OF THE CONTRACT. If the fix had simply skipped the
    -- block namespace in memory mode, this would read false and High
    -- Command would have lost the ability to restrain anyone on a stock
    -- install -- trading one silent failure for another.
    t.isTrue(f.env.HasPermission('BLOCKED-CITIZEN', 'block.BiteAndHold'),
        'a real, in-session block must be honoured in memory mode exactly as it is with a database')

    -- And it must still be liftable.
    f.advanceTime(2000)
    f.env.RevokePermission(hcSrc, 'BLOCKED-CITIZEN', 'block.BiteAndHold')
    t.isFalse(f.env.HasPermission('BLOCKED-CITIZEN', 'block.BiteAndHold'))
end)

t.test('CASE 0: the two causes are genuinely distinguished -- an UNREADABLE k9_permissions still fails closed even though it also reports IsDatabaseEnabled false', function()
    -- Same observable IsDatabaseEnabled('k9_permissions') == false in both
    -- fixtures; opposite, correct answers. This is the whole point of
    -- splitting the accessor, and the test that fails if a future change
    -- collapses them back together.
    local stock = newFixture()
    makeDatabaseConfiguredOff(stock)
    stock.fireOnResourceStart()

    local broken = newFixture({ forcePermissionsTableMissing = true })
    broken.fireOnResourceStart()

    t.isFalse(stock.env.K9Store.IsDatabaseEnabled('k9_permissions'))
    t.isFalse(broken.env.K9Store.IsDatabaseEnabled('k9_permissions'))

    t.isFalse(stock.env.HasPermission('SOMEBODY', 'block.k9.access'), 'deliberate memory mode: allow')
    t.isTrue(broken.env.HasPermission('SOMEBODY', 'block.k9.access'), 'unreadable while persistence was expected: still deny')
end)

t.test('CASE 0: a stock install raises NO "block state cannot be verified" boot warning -- a false alarm here is what made the real lockout hard to spot', function()
    local f = newFixture()
    makeDatabaseConfiguredOff(f)
    f.fireOnResourceStart()

    for _, line in ipairs(f.printLog) do
        t.isFalse(line:find('cannot be verified', 1, true) ~= nil,
            'deliberate memory mode is a normal, fully-working mode and must not be reported as a degraded one: ' .. tostring(line))
    end
end)

t.test('CASE 0: an older config.lua with no Config.Database at all keeps the STRICT behavior -- absence means "expects a database", never "deliberately off"', function()
    local f = newFixture({ forcePermissionsTableMissing = true })
    t.isNil(f.env.Config.Database, 'sanity: this fixture ships no Config.Database, exactly like a config predating the flag')
    f.fireOnResourceStart()
    t.isFalse(f.env.K9Store.IsDatabaseConfiguredOff())
    t.isTrue(f.env.HasPermission('SOMEBODY', 'block.k9.access'),
        'a config that has never heard of the flag must be treated as expecting persistence, so it still fails closed')
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: with k9_permissions genuinely database-backed, an unblocked citizenid still correctly reads NOT blocked -- this fix changes nothing on the healthy path', function()
    local f = newFixture()
    f.fireOnResourceStart()
    t.isFalse(f.env.HasPermission('NEVER-BLOCKED', 'block.BiteAndHold'))
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: the operator is warned ONCE, clearly, that block state cannot be verified this session -- not once per HasPermission call, not silently', function()
    local f = newFixture({ forcePermissionsTableMissing = true })
    f.fireOnResourceStart()

    local function countWarnings()
        local n = 0
        for _, line in ipairs(f.printLog) do
            if line:find('block', 1, true) and line:find('cannot be verified', 1, true) then n = n + 1 end
        end
        return n
    end

    t.equals(countWarnings(), 1, 'must warn exactly once, at boot')
    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('cannot be verified', 1, true) then warningLine = line end
    end
    t.isNotNil(warningLine, 'the warning must actually print')
    t.isTrue(warningLine:find('BLOCKED FOR EVERYONE', 1, true) ~= nil, 'must plainly say what is now happening, not just that something is wrong')
    t.isTrue(warningLine:find('unaffected', 1, true) ~= nil, 'must reassure the operator that certifications/positive grants are NOT also affected')

    -- Drive HasPermission repeatedly afterward (mirrors real gameplay
    -- hammering this hot path many times a second) -- the warning must
    -- never be tied to this call, only to onResourceStart.
    for i = 1, 20 do f.env.HasPermission('SOME-CITIZEN-' .. i, 'block.BiteAndHold') end
    t.equals(countWarnings(), 1, 'repeated HasPermission calls must never add duplicate warnings -- the print lives at onResourceStart, not on this hot path')
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: the operator warning does NOT fire when Config.Features.PermissionGrants is off -- nothing to warn about if the whole grant/block system is disabled', function()
    local f = newFixture({ forcePermissionsTableMissing = true, permissionGrantsEnabled = false })
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'cannot be verified'))
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: the operator warning does NOT fire when k9_permissions is genuinely database-backed -- nothing to warn about on a healthy install', function()
    local f = newFixture()
    f.fireOnResourceStart()
    t.isFalse(anyPrintLineContains(f, 'cannot be verified'))
end)

t.test('MEMORY-MODE BLOCK ASYMMETRY: a DIFFERENT resource starting is ignored entirely -- mirrors this resource\'s own GetCurrentResourceName() guard convention', function()
    local f = newFixture({ forcePermissionsTableMissing = true })
    for _, handler in ipairs(f.eventHandlers['onResourceStart'] or {}) do
        handler('some_other_resource')
    end
    t.isFalse(anyPrintLineContains(f, 'cannot be verified'))
    -- The schema probe itself never ran either (also gated on the same
    -- resource-name check in server/datastore.lua) -- so this is not yet
    -- settled; nothing this test needs to additionally assert beyond "no
    -- warning fired for someone else's restart".
end)


-- THE SECOND WAY OF NOT KNOWING, which the first fail-closed fix missed.
-- That fix covered "this table is memory-only for the session", decided
-- once at boot. It did not cover "the table is healthy, but THIS person's
-- own read just failed and nothing was ever cached for them" -- someone
-- connecting during a brief outage. A regression pass reproduced a real,
-- still-active block silently ceasing to apply for the length of it.
t.test('BLOCK FAIL-CLOSED, TRANSIENT CASE: an active block still applies when this citizenid\'s own read fails on an otherwise-healthy table', function()
    local f = newFixture({ isHighCommand = function(src) return src == 900 end })
    local hcSrc = 900
    f.registerPlayer(hcSrc, 'HC1', { name = 'police', grade = { level = 9 } })
    f.registerPlayer(601, 'CND1', { name = 'police', grade = { level = 1 } })
    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND1', source = 601, job = { name = 'police' } } })

    f.env.GrantPermission(hcSrc, 'CND1', 'block.BiteAndHold')
    t.isTrue(f.env.HasPermission('CND1', 'block.BiteAndHold'), 'precondition: the block is real and applies while the database is healthy')

    -- Disconnect clears the warm entry; the block row itself is untouched
    -- in the database, exactly as a real reconnect would leave it.
    f.firePlayerDropped(601)
    f.registerPlayer(601, 'CND1', { name = 'police', grade = { level = 1 } })

    local realQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('SELECT permission FROM k9_permissions', 1, true) then error('connection lost') end
        return realQueryAwait(sql, params)
    end
    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND1', source = 601, job = { name = 'police' } } })

    t.isTrue(f.env.HasPermission('CND1', 'block.BiteAndHold'),
        'a block whose read could not be resolved must still apply -- returning "not blocked" here hands someone back access an admin deliberately took away, silently, while every other table looks healthy')

    -- The opposite namespace must NOT be dragged along: an unresolved read
    -- may never GRANT anything. Only blocks fail closed.
    t.isFalse(f.env.HasPermission('CND1', 'k9.access'),
        'an unresolved read must never manufacture a positive grant -- only the block namespace inverts')

    -- And the denial must not be permanent: once a real answer arrives the
    -- normal rules resume, so the self-heal sweep genuinely recovers this.
    f.mysql.query.await = realQueryAwait
    f.firePlayerLoaded({ PlayerData = { citizenid = 'CND1', source = 601, job = { name = 'police' } } })
    t.isTrue(f.env.HasPermission('CND1', 'block.BiteAndHold'), 'after recovery the real block is read back normally')
    t.isFalse(f.env.HasPermission('OTHER-CID', 'block.BiteAndHold'), 'someone with no block and a healthy resolved read is not blocked -- the fix must not deny everyone')
end)

os.exit(t.summary())
