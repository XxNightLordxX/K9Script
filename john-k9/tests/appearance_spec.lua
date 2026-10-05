--[[
    tests/appearance_spec.lua

    Direct tests of server/appearance.lua -- the K9 role/ped-model
    decoupling this pass introduces (see that file's own header) -- against
    the REAL, unmodified production file, loaded alongside the REAL
    server/cooldowns.lua, server/highcommand.lua and server/permissions.lua
    (ApplyK9PedRole calls GrantPermission directly; MaybeRevertK9Appearance's
    reconciliation calls HasPermission; HasK9Role calls HasPermission too --
    a fake/duplicated permissions layer here would risk silently drifting
    from the real authorization rules it is supposed to be exercising).
    Deliberately does NOT load server/certifications/: it is under heavy,
    fast-moving concurrent development this same session (a certification
    tier/expiry/specialization system landed mid-session, more than
    doubling that file's length) and server/appearance.lua's own
    IsCertifiedK9ForJob/IsCertifiedK9ForAnyJob read `k9_certifications`
    directly via MySQL rather than reaching into that file's private
    `Certifications` cache (see server/appearance.lua's own FILE-TO-FILE
    CONTRACT for why) -- so every cert-path assertion below drives the
    MySQL stub's own fake `k9_certifications` table directly, exactly the
    way the real query would see it, with zero dependency on
    certifications.lua's current internal shape.

    LOCALE: stubbed to a plain passthrough, NOT Sandbox.locale. The seven
    `appearance.*` keys this file's production code calls (see this pass's
    hand-off report for the exact key list/English text) are PROPOSED, not
    yet landed in locales/en.json (this file may not edit that file) --
    using the real locale() reader here would make this spec red until an
    orchestrator applies that request, which is exactly backwards for a
    suite that must stay green throughout. permissions.lua's own two
    (already-real, already-landed) locale calls go through this same stub
    too; this spec never asserts on exact notification text, only on
    outcomes/side effects, so the substitution costs nothing here.

    THE FOUR LOAD-BEARING CASES THIS TASK NAMED, and where each lives:
      1. "a human ped CAN hold the role with requireK9ModelForRole false" --
         section 2 below (ApplyK9PedRole never reads or cares about the
         target's ped model at all; HasK9Role reflects the grant
         immediately after).
      2. "a client cannot self-assign" -- section 3 below (ApplyK9PedRole
         is server-authoritative top to bottom via GrantPermission's own
         IsHighCommand check; a non-high-command source is denied outright,
         no DB write, no swap ever requested).
      3. "a failed model load leaves the player untouched" -- the SERVER
         half lives here (section 5: confirmK9PedSwap(ok=false) never
         writes k9_ped_assignments); the CLIENT half (SetPlayerModel is
         never actually called) is tests/clientappearance_spec.lua's job.
      4. "revoke restores the original appearance" -- section 6 below
         (MaybeRevertK9Appearance sends a 'revert' swap request carrying
         the captured original_model_hash, or Config.K9Appearance
         .fallbackHumanModel when none was ever captured).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture builder -- one fresh env + fresh load of cooldowns/highcommand/
-- permissions/appearance per top-level scenario, same "never leak state
-- between unrelated test cases" discipline as certifications_spec.lua's
-- own newFixture().
-- ----------------------------------------------------------------------

--- @param opts table? -- { requireK9ModelForRole: boolean (default false), applyPedModelOnCertify: boolean (default true), restoreOriginalPedOnRevoke: boolean (default true), fallbackHumanModel: string?, modelLoadTimeoutMs: number? }
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    -- appearance.lua's own file-load-time CreateThread(...) (the
    -- forced-timeout sweep -- see that file's own header on the
    -- confirmK9PedSwap section) creates a coroutine via
    -- Sandbox.newThreadRunner(), left dormant until a test explicitly
    -- calls f.stepSweepThread().
    local threadRunner = Sandbox.newThreadRunner()

    -- ONE Wait global has to correctly serve TWO call sites with opposite
    -- needs: the sweep thread's `while true do Wait(...) ... end` body
    -- (runs INSIDE the coroutine above -- must genuinely yield, or
    -- .step()ping it would free-spin forever the first time it's resumed,
    -- exactly the hang this comment's own test run once produced before
    -- this fix) and PlayerLoaded's short original-model-capture retry loop
    -- (called directly, synchronously, from a plain top-level test
    -- assertion -- NOT inside any coroutine, where `coroutine.yield()`
    -- would error outright with "attempt to yield from outside a
    -- coroutine"). `coroutine.isyieldable()` tells the two apart at
    -- runtime: yield (via the thread runner) only when actually running
    -- inside a resumable coroutine, no-op otherwise.
    local function Wait(ms)
        if coroutine.isyieldable() then
            threadRunner.Wait(ms)
        end
    end

    -- ---- exports.qbx_core -------------------------------------------------
    local playersBySource = {}
    local playersByCitizenId = {}

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return p
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

    -- ---- fake k9_certifications / k9_permissions / k9_ped_assignments -----
    -- Real SQL text is never parsed -- every MySQL.*.await stub below
    -- pattern-matches on which TABLE the real production query names, then
    -- reads/writes ONE shared Lua table per fake table, mirroring the exact
    -- shape a real row would have. This is deliberately not a full SQL
    -- engine: server/appearance.lua's own queries are simple enough
    -- (single-table, no joins) that this is a faithful, low-risk stand-in.
    local fakeCerts = {}       -- fakeCerts[citizenid][jobName] = true (active only; inactive rows aren't modeled, nothing here reads them)
    local fakePermissions = {} -- fakePermissions[citizenid][permissionKey] = true (active only)
    local fakeAssignments = {} -- fakeAssignments[citizenid] = { model, original_model_hash, active }

    local function mysqlScalarAwait(sql, params)
        if sql:find('FROM k9_certifications', 1, true) then
            local citizenid, jobName = params[1], params[2]
            if fakeCerts[citizenid] and fakeCerts[citizenid][jobName] then return 1 end
            return nil
        end
        if sql:find('FROM k9_permissions', 1, true) then
            local citizenid, permissionKey = params[1], params[2]
            if fakePermissions[citizenid] and fakePermissions[citizenid][permissionKey] then return 1 end
            return nil
        end
        error('unstubbed MySQL.scalar.await query in appearance_spec fixture: ' .. sql)
    end

    -- IsCertifiedK9ForAnyJob's query has no job param -- a citizenid-only
    -- scan across every department's fake row.
    local function mysqlScalarAwaitAnyJob(sql, params)
        local citizenid = params[1]
        if sql:find('WHERE citizenid = %? AND active = 1 LIMIT 1', 1) and not sql:find('AND job', 1, true) then
            if fakeCerts[citizenid] then
                for _, active in pairs(fakeCerts[citizenid]) do
                    if active then return 1 end
                end
            end
            return nil
        end
        return mysqlScalarAwait(sql, params)
    end

    local function mysqlQueryAwait(sql, params)
        -- RefreshPermissionCache's read (permissions.lua) -- an ARRAY of
        -- { permission = ... } rows, not a scalar. Must be handled here
        -- (not just in mysqlScalarAwait's pre-check SELECT) or GrantPermission's
        -- own post-write cache warm sees an empty result and PermissionCache
        -- never reflects a grant this fixture or the real INSERT below made.
        if sql:find('SELECT permission FROM k9_permissions', 1, true) then
            local citizenid = params[1]
            local out = {}
            if fakePermissions[citizenid] then
                for permissionKey, active in pairs(fakePermissions[citizenid]) do
                    if active then out[#out + 1] = { permission = permissionKey } end
                end
            end
            return out
        end
        if sql:find('INSERT INTO k9_permissions', 1, true) then
            local citizenid, permissionKey = params[1], params[2]
            fakePermissions[citizenid] = fakePermissions[citizenid] or {}
            fakePermissions[citizenid][permissionKey] = true
            return { insertId = 1, affectedRows = 1 }
        end
        if sql:find('UPDATE k9_permissions SET active = 0', 1, true) then
            local citizenid, permissionKey = params[2], params[3]
            local hadIt = fakePermissions[citizenid] and fakePermissions[citizenid][permissionKey]
            if hadIt then fakePermissions[citizenid][permissionKey] = nil; return { affectedRows = 1 } end
            return { affectedRows = 0 }
        end
        if sql:find('FROM k9_ped_assignments', 1, true) then
            local citizenid = params[1]
            local row = fakeAssignments[citizenid]
            if not row then return {} end
            return { { model = row.model, original_model_hash = row.original_model_hash, active = row.active and 1 or 0 } }
        end
        if sql:find('INSERT INTO k9_ped_assignments', 1, true) then
            local citizenid, model, originalHash, appliedBy = params[1], params[2], params[3], params[4]
            local existing = fakeAssignments[citizenid]
            local keepOriginal = existing and existing.active and existing.original_model_hash or nil
            fakeAssignments[citizenid] = {
                model = model,
                original_model_hash = keepOriginal or originalHash,
                active = true,
                applied_by = appliedBy,
            }
            return { insertId = 1, affectedRows = 1 }
        end
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            local citizenid = params[1]
            local row = fakeAssignments[citizenid]
            if row and row.active then row.active = false; return { affectedRows = 1 } end
            return { affectedRows = 0 }
        end
        if sql:find('UPDATE k9_ped_assignments SET original_model_hash', 1, true) then
            local hash, citizenid = params[1], params[2]
            local row = fakeAssignments[citizenid]
            if row and row.active and not row.original_model_hash then row.original_model_hash = hash end
            return { affectedRows = 1 }
        end
        error('unstubbed MySQL.query.await query in appearance_spec fixture: ' .. sql)
    end

    local mysql = {
        scalar = { await = function(sql, params)
            if sql:find('FROM k9_certifications', 1, true) and not sql:find('AND job', 1, true) then
                return mysqlScalarAwaitAnyJob(sql, params)
            end
            return mysqlScalarAwait(sql, params)
        end },
        query = { await = mysqlQueryAwait },
        update = { await = function(sql, params) local r = mysqlQueryAwait(sql, params); return r and r.affectedRows or 0 end },
        insert = { await = function(sql, params) local r = mysqlQueryAwait(sql, params); return r and r.insertId or 0 end },
    }

    -- ---- captured event/callback plumbing ---------------------------------
    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local clientEvents = {} -- { {targetSrc, eventName, ...}, ... }
    local function TriggerClientEvent(eventName, targetSrc, ...)
        clientEvents[#clientEvents + 1] = { targetSrc = targetSrc, eventName = eventName, ... }
    end
    --- Clears IN PLACE. `f.clearClientEvents()` from a test body would only
    --- repoint the RETURNED fixture's own field at a fresh table -- it
    --- can't reach (and therefore can't clear) THIS closure's own
    --- `clientEvents` upvalue, which is what TriggerClientEvent actually
    --- keeps appending to; every subsequent event would then land in the
    --- original table while `f.clientEvents` silently stops updating.
    --- Found by this file's own test run (four failures with a plausible
    --- but wrong "the production code returned early" explanation, until
    --- traced to this aliasing bug instead) -- exactly the kind of mistake
    --- worth leaving this comment in place to prevent a repeat of.
    local function clearClientEvents()
        for i = #clientEvents, 1, -1 do clientEvents[i] = nil end
    end

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

    -- Plain passthrough -- see this file's header for why the real
    -- Sandbox.locale is not used here.
    local function localeStub(key, ...)
        if select('#', ...) > 0 then
            local args = { ... }
            for i, v in ipairs(args) do args[i] = tostring(v) end
            return key .. ':' .. table.concat(args, ',')
        end
        return key
    end

    -- CORRECTED for this pass's own K9 IDENTITY tests: the ped handle used
    -- to be a CONSTANT `1` for every connected source -- harmless for
    -- every test that existed before this pass (none ever needed two
    -- DIFFERENT online players' peds distinguishable from one another at
    -- once), but the k9Identity callback below compares
    -- GetEntityCoords(askingPed) against GetEntityCoords(targetPed), which
    -- would silently collide onto the SAME fake coordinate row for any two
    -- different sources under the old constant. Using `source` itself as
    -- the ped handle keeps every existing behaviour identical (still
    -- non-zero for a connected source, still exactly 0 for a disconnected
    -- one) while giving each connected player their own distinct handle.
    local function GetPlayerPed(source) return playersBySource[source] and source or 0 end
    local function GetEntityModel(_ped) return 55555 end -- arbitrary "current live model" hash for PlayerLoaded's capture path

    -- K9 IDENTITY (THIS PASS) -- Vec3-alike stub, IDENTICAL shape/reasoning
    -- to tests/wellbeing_spec.lua's/
    -- tests/tenure_spec.lua's own copies (the only other files needing
    -- GetEntityCoords' real `-`/`#` operators -- see that file's own
    -- comment; Sandbox.vector3 is deliberately too minimal for this, per
    -- its own disclosed limitation).
    local Vec3MT = {}
    Vec3MT.__index = Vec3MT
    Vec3MT.__sub = function(a, b)
        return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
    end
    Vec3MT.__len = function(v)
        return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    end
    local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec3MT) end

    local coordsByPed = {} -- [ped] = vec3, defaults to the origin for any ped this fixture never explicitly positioned
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    -- K9 IDENTITY (THIS PASS) -- k9_personnel row stand-in, monkey-patched
    -- directly onto env.K9Store AFTER server/datastore.lua loads (below):
    -- simpler and more direct than extending the mysql stub above for one
    -- narrow, single-row accessor, and does not risk drifting from
    -- server/roster.lua's/server/datastore.lua's own SQL text (this
    -- fixture never asserts on that text at all, unlike the k9_certifications/
    -- k9_permissions/k9_ped_assignments tables above, which this file's own
    -- production code under test DOES read via raw MySQL.*.await calls).
    local fakePersonnelRows = {} -- fakePersonnelRows[citizenid][job] = { role = ..., callsign = ... }

    -- K9 IDENTITY (THIS PASS) -- GetActivePartnerCitizenId stand-in.
    -- server/partnership.lua is deliberately NOT loaded into this fixture
    -- (same "surgical load list" reasoning as server/certifications/'s
    -- own exclusion, this file's header) -- this is a plain, independent
    -- override, exactly like HasK9Access below, answering ONLY from this
    -- fixture's own fakePartnerships table.
    local fakePartnerships = {} -- fakePartnerships[citizenid] = { partner = citizenid, isK9 = boolean }
    local function GetActivePartnerCitizenId(citizenid)
        local row = fakePartnerships[citizenid]
        if not row then return nil, nil end
        return row.partner, row.isK9
    end

    -- Minimal, HONEST stand-in for server/certifications/'s real
    -- HasK9Access -- NOT loaded in this fixture (see this file's header),
    -- but server/permissions.lua's own LegacyOrHighCommandStillQualifies
    -- calls the real one by name for the 'k9.access' reconciliation branch
    -- (RevokePermission's `stillHasAccess` result). This stub answers
    -- ONLY from this fixture's OWN fakeCerts table (an active cert for the
    -- source's CURRENT job) -- sufficient for the one reconciliation path
    -- this file's tests exercise, not a re-implementation of
    -- autoAccessGrade/permission-bypass/high-command, none of which any
    -- test below needs.
    local function HasK9Access(source)
        local p = playersBySource[source]
        local citizenid = p and p.PlayerData and p.PlayerData.citizenid
        local job = p and p.PlayerData and p.PlayerData.job
        return citizenid ~= nil and job ~= nil and fakeCerts[citizenid] ~= nil and fakeCerts[citizenid][job.name] == true
    end

    local Config = {
        Features = { HighCommand = true, PermissionGrants = true },
        Departments = {
            police = { label = 'Police', certifierGrade = 4, auditGrade = 4, highCommandGrade = 8 },
        },
        Permissions = {
            ['k9.access'] = { label = 'K9 Access' },
        },
        Peds = {
            { model = 'a_c_shepherd' },
            { model = 'a_c_husky' },
        },
        K9Appearance = {
            applyPedModelOnCertify = opts.applyPedModelOnCertify ~= false,
            requireK9ModelForRole = opts.requireK9ModelForRole == true, -- default false, THE decoupling
            persistAcrossSessions = true,
            restoreOriginalPedOnRevoke = opts.restoreOriginalPedOnRevoke ~= false,
            fallbackHumanModel = opts.fallbackHumanModel, -- default nil (opt-in per test)
            modelLoadTimeoutMs = opts.modelLoadTimeoutMs or 8000,
        },
        -- K9 IDENTITY (THIS PASS) -- defaults match config.lua's own
        -- shipped defaults; `opts.k9Identity` lets a test override either
        -- field (see the "switched off" test below).
        K9Identity = {
            enabled = (opts.k9Identity and opts.k9Identity.enabled) ~= false,
            showHandlerName = (opts.k9Identity and opts.k9Identity.showHandlerName) ~= false,
        },
    }

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        Wait = Wait,
        CreateThread = threadRunner.CreateThread,
        exports = exportsStub,
        MySQL = mysql,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        lib = libStub,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        locale = localeStub,
        GetPlayerPed = GetPlayerPed,
        GetEntityModel = GetEntityModel,
        HasK9Access = HasK9Access,
        GetEntityCoords = GetEntityCoords,
        GetPlayerName = function(_source) return nil end, -- every registered test player below carries a full charinfo, so this native fallback is never actually exercised by this file's own tests
        GetActivePartnerCitizenId = GetActivePartnerCitizenId,
    }

    local env = Sandbox.newEnv(overrides)

    -- server/datastore.lua -- REAL, unmodified, loaded first (fxmanifest.lua's
    -- own load order: the only file allowed to call MySQL.* directly).
    -- server/appearance.lua's own k9_certifications/k9_ped_assignments reads
    -- and writes now go through K9Store.* rather than a local MySQL.*.await
    -- call -- Config.Database is deliberately absent from this fixture's
    -- Config table above, so K9Store's own DatabaseEnabled() fails safe to
    -- `true` (real-DB mode), routing every K9Store.* call straight through
    -- to this fixture's own `mysql` stub above, unchanged.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)

    -- K9 IDENTITY (THIS PASS) -- monkey-patch, AFTER the real
    -- server/datastore.lua has defined the real K9Store table (so this
    -- REPLACES just the one accessor, on the SAME table object
    -- server/appearance.lua's own bare `K9Store.Personnel_GetActiveRow`
    -- global read resolves against), BEFORE server/appearance.lua loads
    -- (irrelevant to correctness -- global resolution is at CALL time, per
    -- this resource's own established convention -- but kept in this order
    -- for readability, grouped with the other K9Store.* setup above it).
    env.K9Store.Personnel_GetActiveRow = function(citizenid, job)
        local row = fakePersonnelRows[citizenid] and fakePersonnelRows[citizenid][job]
        if not row then return nil end
        return { role = row.role, callsign = row.callsign }
    end

    Sandbox.loadInto('../server/highcommand.lua', env)
    Sandbox.loadInto('../server/permissions.lua', env)
    Sandbox.loadInto('../server/appearance.lua', env)

    return {
        env = env,
        state = state,
        Config = Config,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        fakeCerts = fakeCerts,
        fakePermissions = fakePermissions,
        fakeAssignments = fakeAssignments,
        -- Exposed so a test can monkey-patch a specific MySQL.*.await entry
        -- point to simulate a DB write failure (K9Store's own SafeWrite
        -- contract pcall-wraps every call, so an errored stub here degrades
        -- to `false`/`nil`, never an uncaught throw) -- same pattern already
        -- established by tests/certifications_spec.lua and
        -- tests/partnership_spec.lua's own `f.mysql.scalar.await = function()
        -- error(...) end` overrides.
        mysql = mysql,
        clientEvents = clientEvents,
        clearClientEvents = clearClientEvents,
        notifyLog = notifyLog,
        printLog = printLog,
        callbacks = capturedCallbacks,
        events = capturedEvents,
        eventHandlers = eventHandlers,
        advanceTime = function(ms) state.now = state.now + ms end,
        --- Grants `citizenid` an active k9.access permission directly in the
        --- fake table, bypassing GrantPermission's own cooldown/audit/self-grant
        --- machinery -- used to set up "already holds the role via the OTHER
        --- path" scenarios. HasPermission (permissions.lua) reads a
        --- CACHE (`PermissionCache`, scoped to online citizenids only, per that
        --- file's own header "SCOPE" section), not the DB directly, and that
        --- cache is `local` -- unreachable from here except by making it warm
        --- itself the SAME way a real connect would: re-firing the real
        --- captured 'QBCore:Server:PlayerLoaded' handler for this citizenid,
        --- which internally calls the real (private) RefreshPermissionCache
        --- against this fixture's own fake k9_permissions table.
        grantPermissionDirect = function(citizenid, permissionKey)
            fakePermissions[citizenid] = fakePermissions[citizenid] or {}
            fakePermissions[citizenid][permissionKey] = true
            local player = playersByCitizenId[citizenid]
            -- Deliberately fires ONLY the FIRST-registered PlayerLoaded
            -- handler -- permissions.lua's own, guaranteed first by this
            -- fixture's own fixed Sandbox.loadInto order above
            -- (cooldowns -> highcommand -> permissions -> appearance).
            -- Firing EVERY registered handler here (an earlier draft did)
            -- also fires server/appearance.lua's OWN PlayerLoaded handler,
            -- which lazily captures original_model_hash from a "live" ped
            -- the moment ANY connect-shaped event reaches it -- correct
            -- production behavior, but it silently gives a fallback-model
            -- test a captured original it was specifically trying to NOT
            -- have, since this helper's whole point is warming
            -- PermissionCache, not simulating a real reconnect.
            if player and eventHandlers['QBCore:Server:PlayerLoaded'] then
                eventHandlers['QBCore:Server:PlayerLoaded'][1](player)
            end
        end,
        grantCertDirect = function(citizenid, jobName)
            fakeCerts[citizenid] = fakeCerts[citizenid] or {}
            fakeCerts[citizenid][jobName] = true
        end,
        --- Fires ONLY server/appearance.lua's OWN PlayerLoaded handler
        --- (the second one registered, per this fixture's fixed load
        --- order) -- the deliberate counterpart to grantPermissionDirect/
        --- revokePermissionDirect above firing ONLY the first
        --- (permissions.lua's). Used by the PlayerLoaded/HasK9Role
        --- backstop tests, which need EXACTLY this file's reconnect logic
        --- to run, not permissions.lua's cache warm.
        firePlayerLoadedAppearanceHandler = function(player)
            local handler = eventHandlers['QBCore:Server:PlayerLoaded'] and eventHandlers['QBCore:Server:PlayerLoaded'][2]
            if handler then handler(player) end
        end,
        --- Steps this fixture's own thread runner once -- the ONLY caller
        --- of appearance.lua's forced-timeout sweep thread. See that
        --- thread's own header for why a cooperating client's answer gets
        --- a full grace period but cannot veto a revert forever.
        stepSweepThread = function() threadRunner.step() end,
        --- Inverse of grantPermissionDirect -- removes the fake row AND
        --- re-warms PermissionCache the same way, so HasPermission
        --- genuinely reflects the removal (not just the underlying fake
        --- table) for tests that need to simulate "no longer qualifies via
        --- ANY path" WITHOUT going through the real, audited RevokePermission
        --- (which itself already calls MaybeRevertK9Appearance as a side
        --- effect -- using it here would revert BEFORE this fixture's own
        --- explicit MaybeRevertK9Appearance call under test ever ran).
        revokePermissionDirect = function(citizenid, permissionKey)
            if fakePermissions[citizenid] then fakePermissions[citizenid][permissionKey] = nil end
            local player = playersByCitizenId[citizenid]
            -- Deliberately fires ONLY the FIRST-registered PlayerLoaded
            -- handler -- permissions.lua's own, guaranteed first by this
            -- fixture's own fixed Sandbox.loadInto order above
            -- (cooldowns -> highcommand -> permissions -> appearance).
            -- Firing EVERY registered handler here (an earlier draft did)
            -- also fires server/appearance.lua's OWN PlayerLoaded handler,
            -- which lazily captures original_model_hash from a "live" ped
            -- the moment ANY connect-shaped event reaches it -- correct
            -- production behavior, but it silently gives a fallback-model
            -- test a captured original it was specifically trying to NOT
            -- have, since this helper's whole point is warming
            -- PermissionCache, not simulating a real reconnect.
            if player and eventHandlers['QBCore:Server:PlayerLoaded'] then
                eventHandlers['QBCore:Server:PlayerLoaded'][1](player)
            end
        end,

        -- K9 IDENTITY (THIS PASS) ----------------------------------------
        --- Positions a source's ped at (x, y, z) -- GetEntityCoords(GetPlayerPed(source))
        --- reads this back, since this fixture's own GetPlayerPed returns
        --- `source` itself as the ped handle (see that function's own
        --- CORRECTED comment above).
        setCoords = function(source, x, y, z) coordsByPed[source] = vec3(x, y, z) end,
        --- Sets `citizenid`'s charinfo directly on the already-registered
        --- player table `registerPlayer` returned -- this fixture's own
        --- registerPlayer never sets charinfo (no existing test before
        --- this pass needed a real display name), and ResolveIdentityDisplayName
        --- falls through, past a nil GetPlayerName, all the way to the
        --- generic locale fallback without one.
        --- @param player table -- exactly what f.registerPlayer(...) returned
        setCharinfo = function(player, firstname, lastname)
            player.PlayerData.charinfo = { firstname = firstname, lastname = lastname }
        end,
        --- @param citizenid string
        --- @param job string
        --- @param role string? -- 'k9' | 'handler' | nil
        --- @param callsign string?
        setPersonnelRow = function(citizenid, job, role, callsign)
            fakePersonnelRows[citizenid] = fakePersonnelRows[citizenid] or {}
            fakePersonnelRows[citizenid][job] = { role = role, callsign = callsign }
        end,
        --- @param k9Citizenid string
        --- @param handlerCitizenid string
        setPartnership = function(k9Citizenid, handlerCitizenid)
            fakePartnerships[k9Citizenid] = { partner = handlerCitizenid, isK9 = true }
            fakePartnerships[handlerCitizenid] = { partner = k9Citizenid, isK9 = false }
        end,
    }
end

-- Test high-command source: police job, isboss so it clears every rank
-- gate unconditionally (IsHighCommand/IsEligibleCertifier-shaped checks
-- alike) -- this spec is about appearance/role logic, not re-litigating
-- rank-threshold math already covered by highcommand_spec.lua/
-- permissions_spec.lua.
local HIGH_COMMAND_SRC = 1
local NON_HIGH_COMMAND_SRC = 2
local TARGET_SRC = 3

local function setupGranterAndTarget(f, targetJob)
    f.registerPlayer(HIGH_COMMAND_SRC, 'CITIZEN_HC', { name = 'police', isboss = true, grade = { level = 10 } })
    f.registerPlayer(NON_HIGH_COMMAND_SRC, 'CITIZEN_PLAIN', { name = 'police', isboss = false, grade = { level = 0 } })
    f.registerPlayer(TARGET_SRC, 'CITIZEN_TARGET', targetJob or { name = 'police', isboss = false, grade = { level = 0 } })
end

-- ----------------------------------------------------------------------
-- 1. HasK9Role -- the decoupled role check itself.
-- ----------------------------------------------------------------------

t.test('HasK9Role: false for a citizenid with neither an active cert nor an active k9.access permission', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: true via an active k9.access PERMISSION alone (no certification at all)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantPermissionDirect('CITIZEN_TARGET', 'k9.access')
    t.isTrue(f.env.HasK9Role(TARGET_SRC))
end)

-- A CERTIFICATION ALONE IS NOT THE K9 ROLE (the rework pass). Handlers are
-- certified too; before, every certified handler read as a second K9 and
-- partnering/leashing refused with "Both of you are playing K9s".

t.test('HasK9Role: a CERTIFICATION alone (a certified HANDLER on a human body) is NOT the K9 role', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: certified AND an active K9 appearance assignment (Certify as K9 / Assign K9 Role) is the K9 role, whatever body they are on', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    f.env.K9Store.Appearance_UpsertApplied('CITIZEN_TARGET', 'a_c_shepherd', nil, 'test')
    t.isTrue(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: certified AND currently wearing a configured K9 model is the K9 role (servers that leave appearance to the player)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    f.env.IsConfiguredK9Model = function(hash) return hash == 55555 end -- this fixture's live model hash
    t.isTrue(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: certified AND a pinned dog character is the K9 role', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    f.env.IsPinnedDogCharacter = function(cid) return cid == 'CITIZEN_TARGET' end
    t.isTrue(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: an appearance assignment WITHOUT a certification or grant is not the role -- looks alone never grant abilities', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.K9Store.Appearance_UpsertApplied('CITIZEN_TARGET', 'a_c_shepherd', nil, 'test')
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

t.test('HasK9Role: a cert for a DIFFERENT job than the target\'s CURRENT job does not count', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantCertDirect('CITIZEN_TARGET', 'sheriff') -- target's live job is 'police'
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

-- ----------------------------------------------------------------------
-- 2. LOAD-BEARING CASE: a human ped CAN hold the role with
--    requireK9ModelForRole false -- ApplyK9PedRole never reads the
--    target's ped model at all (no GetEntityModel/GetPlayerPed call on the
--    grant path whatsoever), so it is model-independent BY CONSTRUCTION,
--    not merely "happens to pass" for a human target.
-- ----------------------------------------------------------------------

t.test('ApplyK9PedRole: grants the K9 role to an ONLINE target and HasK9Role reflects it immediately -- the target\'s ped model is never consulted (requireK9ModelForRole false, the default)', function()
    local f = newFixture({ requireK9ModelForRole = false })
    setupGranterAndTarget(f)
    t.isFalse(f.env.HasK9Role(TARGET_SRC), 'sanity: not yet a K9')

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.isTrue(f.env.HasK9Role(TARGET_SRC), 'the target now holds the K9 role, purely as a server-side assignment -- nothing here ever asked what they currently look like')
end)

t.test('ApplyK9PedRole: sends the ped swap to the ONLINE target client with the exact chosen model', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1].targetSrc, TARGET_SRC)
    t.equals(f.clientEvents[1].eventName, 'john-k9:client:applyK9Ped')
    t.equals(f.clientEvents[1][2], 'a_c_husky') -- payload: modelNameOrHash
end)

t.test('ApplyK9PedRole: an unconfigured model name is rejected outright -- no permission grant attempted, no swap ever requested', function()
    local f = newFixture()
    setupGranterAndTarget(f)

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_totally_made_up')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_model')
    t.equals(#f.clientEvents, 0)
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
end)

t.test('ApplyK9PedRole: re-applying a DIFFERENT model to a citizenid who already holds the role is NOT blocked by "already_granted" -- the swap still goes out', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantPermissionDirect('CITIZEN_TARGET', 'k9.access') -- already holds the role, e.g. via an earlier grant
    -- grantPermissionDirect above re-fires the REAL, captured
    -- 'QBCore:Server:PlayerLoaded' handler (see that helper's own doc
    -- comment) to warm PermissionCache the same way a real reconnect would
    -- -- server/permissions.lua's own PlayerLoaded handler now ALSO pushes
    -- this pass's feature-block sync on every fire (see that file's
    -- "FEATURE-BLOCK PUSH" section), which lands in this SAME captured
    -- clientEvents log. Cleared here, same as every other
    -- grantPermissionDirect/revokePermissionDirect call site in this file,
    -- so the assertion below counts only the applyK9Ped push this test is
    -- actually about.
    f.clearClientEvents()

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1][2], 'a_c_husky')
end)

t.test('ApplyK9PedRole: an OFFLINE target persists the assignment directly (no swap to send) and reports persisted_offline', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.disconnectPlayer(TARGET_SRC)
    -- GrantPermission itself requires the caller to be resolvable, but not
    -- the TARGET -- targetCitizenid is a bare string throughout that flow,
    -- matching server/permissions.lua's own citizenid-keyed, offline-capable
    -- design (see that file's header).

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'persisted_offline')
    t.equals(#f.clientEvents, 0, 'nobody is online to receive a swap request')
    t.equals(f.fakeAssignments['CITIZEN_TARGET'].model, 'a_c_husky')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'].original_model_hash, 'not yet known -- captured lazily on their next PlayerLoaded')
end)

-- ----------------------------------------------------------------------
-- 3. LOAD-BEARING CASE: a client cannot self-assign. ApplyK9PedRole is
--    server-authoritative end to end via GrantPermission's own
--    IsHighCommand(granterSrc) check -- there is no code path here that
--    ever trusts a client's own claim about its rank or authority.
-- ----------------------------------------------------------------------

t.test('ApplyK9PedRole: a NON-high-command source is denied outright -- no DB write, no swap ever requested, HasK9Role stays false', function()
    local f = newFixture()
    setupGranterAndTarget(f)

    local ok, outcome = f.env.ApplyK9PedRole(NON_HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isFalse(ok)
    t.equals(outcome, 'denied')
    t.equals(#f.clientEvents, 0)
    t.isFalse(f.env.HasK9Role(TARGET_SRC))
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'])
end)

-- OWNER'S DECISION, and the reason this test asserts the opposite of what
-- it used to. Self-granting was once blocked outright, so a high command
-- officer could not put the K9 role on their own character. The owner's
-- instruction is that high command may grant themselves anything, and
-- that high command is a handler or a K9 who also administers rather than
-- a fourth kind of person -- so an officer turning their own character
-- into a K9 is the feature working, not a hole in it.
--
-- The boundary this test still guards is the one that matters: only a
-- high command officer reaches this path at all. The companion test below
-- proves an ordinary player self-targeting is still refused. If that ever
-- goes green, the widening has escaped its intended scope.
t.test('ApplyK9PedRole: a HIGH COMMAND officer may put the K9 role on their OWN character -- self-grant is permitted by the owner\'s decision', function()
    local f = newFixture()
    f.registerPlayer(HIGH_COMMAND_SRC, 'CITIZEN_HC', { name = 'police', isboss = true, grade = { level = 10 } })

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_HC', 'a_c_husky')
    t.isTrue(ok, 'high command self-assigning the K9 role must now succeed')
    t.isNil(outcome == 'self_grant_blocked' and outcome or nil, 'the old self-grant refusal must no longer fire for high command')
    t.isTrue(#f.clientEvents > 0, 'the model swap must actually be dispatched to the caller\'s own client')
end)

-- ----------------------------------------------------------------------
-- 5. LOAD-BEARING CASE (server half): a failed model load leaves the
--    player untouched -- confirmK9PedSwap(ok=false) never writes
--    k9_ped_assignments, regardless of the reason. The client half (proving
--    SetPlayerModel itself is never called) lives in
--    tests/clientappearance_spec.lua.
-- ----------------------------------------------------------------------

t.test('confirmK9PedSwap: ok=false ("timeout") -- k9_ped_assignments is NEVER written, matching the "abandon, never half-apply" contract', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](requestId, false, 'timeout')

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'no row was ever written for a swap that never actually landed')
end)

t.test('confirmK9PedSwap: ok=false ("engaged") -- same "never half-applied" guarantee', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](requestId, false, 'engaged')

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'])
end)

t.test('confirmK9PedSwap: ok=true -- NOW the row is written, with the model actually confirmed applied', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](requestId, true, nil)

    t.equals(f.fakeAssignments['CITIZEN_TARGET'].model, 'a_c_husky')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
end)

t.test('confirmK9PedSwap: a forged/stale requestId (does not match the real pending one) is ignored -- no write, no crash', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')

    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap']('not-the-real-request-id', true, nil)

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'])
end)

-- ----------------------------------------------------------------------
-- 6. LOAD-BEARING CASE: revoke restores the original appearance.
-- ----------------------------------------------------------------------

t.test('MaybeRevertK9Appearance: no-op when the citizenid has no active k9_ped_assignments row at all (cheap common case)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')
    t.equals(#f.clientEvents, 0)
end)

t.test('MaybeRevertK9Appearance: reverts to the captured ORIGINAL model hash when the citizenid no longer qualifies via ANY path', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.fakeAssignments['CITIZEN_TARGET'].original_model_hash = -999888777 -- simulate a captured original
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- no longer qualifies via ANY path
    f.clearClientEvents() -- reset so the revert's own swap request is the only one asserted below
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1].eventName, 'john-k9:client:applyK9Ped')
    t.equals(f.clientEvents[1][2], -999888777, 'the exact original hash, restored -- not a default')
end)

t.test('MaybeRevertK9Appearance: falls back to Config.K9Appearance.fallbackHumanModel when no original was ever captured', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    -- original_model_hash is nil here (never captured) -- exactly the
    -- "install had an existing K9 before this feature shipped" case.
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- no longer qualifies via ANY path
    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')

    t.equals(#f.clientEvents, 1)
    t.equals(f.clientEvents[1][2], 'mp_m_freemode_01', 'a NAME this time, not a hash -- fallbackHumanModel is configured by string')
end)

t.test('MaybeRevertK9Appearance: REFUSES to guess when no original was captured AND no fallbackHumanModel is configured -- never strands, never invents a model', function()
    local f = newFixture({ fallbackHumanModel = nil })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')

    t.equals(#f.clientEvents, 0)
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'left exactly as they were rather than guessing -- an operator must configure fallbackHumanModel to close this gap')
end)

t.test('MaybeRevertK9Appearance: does NOT revert when the citizenid still independently qualifies via a SEPARATE active certification', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky') -- grants via k9.access permission
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.grantCertDirect('CITIZEN_TARGET', 'police') -- ALSO independently certified

    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET') -- e.g. their k9.access permission alone was revoked
    t.equals(#f.clientEvents, 0, 'still certified -- appearance must not be reverted out from under a citizenid who genuinely still holds the role')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
end)

t.test('MaybeRevertK9Appearance: disabled outright when Config.K9Appearance.restoreOriginalPedOnRevoke is false', function()
    local f = newFixture({ restoreOriginalPedOnRevoke = false })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)

    f.clearClientEvents()
    f.env.MaybeRevertK9Appearance('CITIZEN_TARGET')
    t.equals(#f.clientEvents, 0)
end)

t.test('RevokePermission: revoking a target\'s ONLY active k9.access grant (fully removed) triggers a revert', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    -- ApplyK9PedRole already consumed PermissionActionCooldown for
    -- HIGH_COMMAND_SRC (it calls GrantPermission internally, and that
    -- cooldown is shared with RevokePermission -- same instance, same key,
    -- per permissions.lua's own header) -- advance past
    -- PERMISSION_ACTION_COOLDOWN_MS (1500) or this revoke is silently rate-limited.
    f.advanceTime(2000)

    local ok, outcome, stillHasAccess = f.env.RevokePermission(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'k9.access')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.isNil(stillHasAccess, 'fully removed -- nothing else grants them k9.access')
    t.equals(#f.clientEvents, 1, 'MaybeRevertK9Appearance fired as a direct consequence of the revoke')
    t.equals(f.clientEvents[1].eventName, 'john-k9:client:applyK9Ped')
end)

t.test('RevokePermission: revoking k9.access while a SEPARATE certification still qualifies them (stillHasAccess) does NOT revert appearance', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.grantCertDirect('CITIZEN_TARGET', 'police')
    f.clearClientEvents()
    f.advanceTime(2000) -- see the previous test's identical comment on PermissionActionCooldown

    local ok, _, stillHasAccess = f.env.RevokePermission(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'k9.access')
    t.isTrue(ok)
    t.equals(stillHasAccess, 'rank_or_high_command')
    t.equals(#f.clientEvents, 0, 'still genuinely a K9 by certification -- must not be reverted')
end)

-- ----------------------------------------------------------------------
-- 7. ForceRevertK9Appearance -- the tablet's explicit, credential-BLIND
--    "remove K9 ped, revert to human" action (server/tablet.lua). See
--    that function's own doc comment: authorization is the GRANTER alone
--    (high command), NEVER the target's own credential state -- both
--    directions of the "no unbounded trap" rule apply here.
-- ----------------------------------------------------------------------

t.test('ForceRevertK9Appearance: a NON-high-command source is denied outright', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()

    local ok, outcome = f.env.ForceRevertK9Appearance(NON_HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isFalse(ok)
    t.equals(outcome, 'denied')
    t.equals(#f.clientEvents, 0)
end)

t.test('ForceRevertK9Appearance: succeeds EVEN WHILE the target still holds an active certification -- deliberately credential-blind, unlike MaybeRevertK9Appearance', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.grantCertDirect('CITIZEN_TARGET', 'police') -- still, on paper, certified
    f.clearClientEvents()
    f.advanceTime(2000) -- past AppearanceActionCooldown from the ApplyK9PedRole call above

    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#f.clientEvents, 1, 'reverted anyway -- the role and the appearance are being deliberately decoupled by this action')
    t.isTrue(f.env.HasK9Role(TARGET_SRC), 'the CERTIFICATION itself is untouched by this action -- only the appearance changed, exactly as the owner specified')
end)

t.test('ForceRevertK9Appearance: NO UNBOUNDED TRAP -- succeeds on a target who has ALREADY lost every credential (the exact case an automatic revert would already have handled, but this must not depend on that having happened)', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- simulate: credential already gone, e.g. by some other path
    f.clearClientEvents()
    f.advanceTime(2000)

    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#f.clientEvents, 1)
end)

t.test('ForceRevertK9Appearance: no active assignment at all is reported honestly, not as a false success', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isFalse(ok)
    t.equals(outcome, 'no_active_assignment')
end)

-- ----------------------------------------------------------------------
-- 8. SECURITY: a revert must complete with the client silent, hostile, or
--    gone -- it may never be vetoable by the party it terminates.
-- ----------------------------------------------------------------------

t.test('SECURITY: disconnecting mid-revert COMMITS the revert immediately -- does NOT leave the stale active=1 row for a future reconnect to resurrect', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000)

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET') -- sends the revert; NEVER confirmed below
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'not yet committed -- still awaiting the client\'s own confirm, exactly as an APPLY would be')

    -- The target disconnects before ever replying. Real FXServer's own
    -- 'playerDropped' fires BEFORE the framework fully tears down the
    -- player object (server/certifications/'s own playerDropped
    -- handler comment already establishes this for this exact fixture
    -- shape) -- so the handler runs FIRST, exports.qbx_core:GetPlayer(src)
    -- still resolves, and ONLY THEN is the player actually removed from
    -- this fixture's own registry.
    f.env.source = TARGET_SRC
    for _, handler in ipairs(f.eventHandlers['playerDropped'] or {}) do handler('testing') end
    f.disconnectPlayer(TARGET_SRC)

    t.isFalse(f.fakeAssignments['CITIZEN_TARGET'].active, 'committed on disconnect -- the decision was already made server-side; only the visual confirm was missing')
end)

t.test('SECURITY: disconnecting mid-APPLY does NOT write anything -- the apply/revert asymmetry is preserved (an apply with no pre-existing state stays a clean no-op)', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'not yet confirmed by the client at all')

    f.env.source = TARGET_SRC
    for _, handler in ipairs(f.eventHandlers['playerDropped'] or {}) do handler('testing') end
    f.disconnectPlayer(TARGET_SRC)

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'still nothing written -- a dropped pending APPLY is a genuine no-op, unlike a dropped REVERT')
end)

t.test('SECURITY: a hostile client that never confirms a revert cannot hold it open forever -- the sweep thread forces it through once the grace period elapses', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000)

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET') -- the target simply never replies from here on
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'still pending -- the grace period has not elapsed yet')

    f.stepSweepThread() -- primes the coroutine (its first statement is Wait(...)) -- no pass yet, per Sandbox.newThreadRunner's own documented stepping semantics
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'still nothing -- this step only reached the sweep loop\'s own Wait()')

    f.advanceTime(14000) -- past ApplyRequestTtlMs (modelLoadTimeoutMs 8000 default + 5000ms margin = 13000)
    f.stepSweepThread() -- NOW runs one real sweep pass
    t.isFalse(f.fakeAssignments['CITIZEN_TARGET'].active, 'forced through -- a hostile or unresponsive client cannot veto a revert past its own grace period')
end)

t.test('SECURITY BACKSTOP: PlayerLoaded refuses to re-apply a persisted active row for a citizenid who no longer holds the K9 role by any path -- clears the stale row instead', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    -- Credential lost through some OTHER path, without going through
    -- RevokePermission/MaybeRevertK9Appearance at all -- exactly the
    -- "any other way a stale active row could occur" this backstop exists
    -- for, independent of the disconnect-during-revert fix above.
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access')
    f.clearClientEvents()

    f.firePlayerLoadedAppearanceHandler({ PlayerData = { citizenid = 'CITIZEN_TARGET', source = TARGET_SRC } })

    t.isFalse(f.fakeAssignments['CITIZEN_TARGET'].active, 'the stale row was cleared, not re-applied')
    t.equals(#f.clientEvents, 0, 'no K9 model was pushed to a citizenid who no longer holds the role')
end)

t.test('PlayerLoaded: a citizenid who STILL holds the role gets the normal re-apply-on-reconnect behavior, unaffected by the HasK9Role backstop', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()

    f.firePlayerLoadedAppearanceHandler({ PlayerData = { citizenid = 'CITIZEN_TARGET', source = TARGET_SRC } })

    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
    t.equals(#f.clientEvents, 1, 'still certified -- the K9 model is re-pushed on reconnect, exactly as before this backstop existed')
end)

-- ----------------------------------------------------------------------
-- 9. DISCARDED-WRITE FIX (quality pass): every K9Store write in this file
--    follows the SafeWrite contract (a DB error degrades to `false`/`nil`
--    rather than throwing) -- these writes' own boolean results used to be
--    discarded outright at every call site below, so a DB failure was
--    silently reported as a clean success both to the player (a "success"
--    toast) and in the audit trail (outcome 'ok'). Each write site gets its
--    own DB-failure case here, injected via `f.mysql.query.await` (mirrors
--    tests/certifications_spec.lua's/tests/partnership_spec.lua's own
--    `f.mysql.scalar.await = function() error(...) end` pattern).
-- ----------------------------------------------------------------------

t.test('confirmK9PedSwap (apply): a DB write failure logs db_error, never a false "ok", and never tells the target the swap was saved', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    local requestId = f.clientEvents[1][1]

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('INSERT INTO k9_ped_assignments', 1, true) then
            error('simulated: DB unreachable for the appearance-apply write')
        end
        return originalQueryAwait(sql, params)
    end

    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](requestId, true, nil)

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'the write genuinely failed -- nothing was persisted')
    local toldTargetItSucceeded = false
    for _, entry in ipairs(f.notifyLog) do
        if entry.message == 'appearance.apply_success_target' then toldTargetItSucceeded = true end
    end
    t.isFalse(toldTargetItSucceeded, 'the target must never be told the swap was saved when it was not')
    t.contains(table.concat(f.printLog, '\n'), 'k9AppearanceApply(citizenid=CITIZEN_TARGET) -> db_error',
        'the audit trail records the real outcome, not a false "ok"')
end)

t.test('confirmK9PedSwap (revert): a DB write failure logs db_error, never a false "ok", and never tells the target the appearance was restored', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000) -- past AppearanceActionCooldown

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    local revertRequestId = f.clientEvents[1][1]

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            error('simulated: DB unreachable for the appearance-revert write')
        end
        return originalQueryAwait(sql, params)
    end

    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](revertRequestId, true, nil)

    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'the write genuinely failed -- the row was NOT cleared')
    local toldTargetItSucceeded = false
    for _, entry in ipairs(f.notifyLog) do
        if entry.message == 'appearance.revert_success_target' then toldTargetItSucceeded = true end
    end
    t.isFalse(toldTargetItSucceeded, 'the target must never be told the appearance was restored when it was not')
    t.contains(table.concat(f.printLog, '\n'), 'k9AppearanceRevert(citizenid=CITIZEN_TARGET) -> db_error')
end)

t.test('ApplyK9PedRole: re-applying a DIFFERENT model to an already-granted, now-OFFLINE target whose persist-write fails reports db_error honestly, not persisted_offline', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.grantPermissionDirect('CITIZEN_TARGET', 'k9.access') -- already holds the role
    f.clearClientEvents()
    f.disconnectPlayer(TARGET_SRC)

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('INSERT INTO k9_ped_assignments', 1, true) then
            error('simulated: DB unreachable for the offline re-apply write')
        end
        return originalQueryAwait(sql, params)
    end

    local ok, outcome = f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    t.isFalse(ok)
    t.equals(outcome, 'db_error')
    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'nothing was actually persisted')
end)

t.test('ApplyK9AppearanceOnGrant: an OFFLINE target whose automatic persist-write fails is logged as db_error, not persisted_offline', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.disconnectPlayer(TARGET_SRC)

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('INSERT INTO k9_ped_assignments', 1, true) then
            error('simulated: DB unreachable')
        end
        return originalQueryAwait(sql, params)
    end

    -- This function is a void automatic side effect (GrantCertification/
    -- GrantPermission never check a return value from it, by design) -- the
    -- audit trail is the only place this failure is ever visible.
    f.env.ApplyK9AppearanceOnGrant('CITIZEN_TARGET', 'CITIZEN_HC', 'a_c_husky')

    t.isNil(f.fakeAssignments['CITIZEN_TARGET'], 'nothing was actually persisted')
    t.contains(table.concat(f.printLog, '\n'), 'applyK9AppearanceOnGrant(model=a_c_husky target=CITIZEN_TARGET) -> db_error')
end)

t.test('ForceRevertK9Appearance: an OFFLINE target with NO captured original hash (fallback-model branch) whose revert-write fails reports db_error, not a false "ok"', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    -- original_model_hash is nil here (never captured) -- the fallback-model branch of PerformRevert.
    f.clearClientEvents()
    f.advanceTime(2000)
    f.disconnectPlayer(TARGET_SRC) -- offline: SendSwapRequest fails, PerformRevert must persist the revert directly

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            error('simulated: DB unreachable for the offline fallback-branch revert write')
        end
        return originalQueryAwait(sql, params)
    end

    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isFalse(ok)
    t.equals(outcome, 'db_error')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'the row was NOT actually cleared -- must not be reported as reverted')
end)

t.test('ForceRevertK9Appearance: an OFFLINE target WITH a captured original hash whose revert-write fails reports db_error, not a false "ok"', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.fakeAssignments['CITIZEN_TARGET'].original_model_hash = -999888777 -- simulate a captured original
    f.clearClientEvents()
    f.advanceTime(2000)
    f.disconnectPlayer(TARGET_SRC)

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            error('simulated: DB unreachable for the offline captured-hash revert write')
        end
        return originalQueryAwait(sql, params)
    end

    local ok, outcome = f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET')
    t.isFalse(ok)
    t.equals(outcome, 'db_error')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active)
end)

t.test('SWEEP: a forced-timeout revert whose DB write fails logs forced_timeout_db_error (never forced_timeout), and does not tell the target it was reverted', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000)

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET') -- the target simply never replies from here on

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            error('simulated: DB unreachable during the forced-timeout sweep')
        end
        return originalQueryAwait(sql, params)
    end

    f.stepSweepThread() -- primes the coroutine
    f.advanceTime(14000) -- past ApplyRequestTtlMs
    f.stepSweepThread() -- runs one real sweep pass

    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'the write genuinely failed -- the row must not read as cleared')
    local toldTargetItSucceeded = false
    for _, entry in ipairs(f.notifyLog) do
        if entry.message == 'appearance.revert_success_target' then toldTargetItSucceeded = true end
    end
    t.isFalse(toldTargetItSucceeded)
    t.contains(table.concat(f.printLog, '\n'), 'k9AppearanceRevert(citizenid=CITIZEN_TARGET) -> forced_timeout_db_error')
end)

t.test('SECURITY: disconnecting mid-revert whose DB write ALSO fails logs committed_on_disconnect_db_error, never a false committed_on_disconnect', function()
    local f = newFixture({ fallbackHumanModel = 'mp_m_freemode_01' })
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.clearClientEvents()
    f.advanceTime(2000)

    f.env.ForceRevertK9Appearance(HIGH_COMMAND_SRC, 'CITIZEN_TARGET') -- sends the revert; never confirmed below

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            error('simulated: DB unreachable at disconnect time')
        end
        return originalQueryAwait(sql, params)
    end

    f.env.source = TARGET_SRC
    for _, handler in ipairs(f.eventHandlers['playerDropped'] or {}) do handler('testing') end
    f.disconnectPlayer(TARGET_SRC)

    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'the write genuinely failed')
    t.contains(table.concat(f.printLog, '\n'), 'k9AppearanceRevert(citizenid=CITIZEN_TARGET) -> committed_on_disconnect_db_error')
end)

t.test('SECURITY BACKSTOP: a stale-row clear whose DB write fails still refuses to re-apply the model (fail-safe unaffected), and logs stale_row_clear_db_error', function()
    local f = newFixture()
    setupGranterAndTarget(f)
    f.env.ApplyK9PedRole(HIGH_COMMAND_SRC, 'CITIZEN_TARGET', 'a_c_husky')
    f.env.source = TARGET_SRC
    f.events['john-k9:server:confirmK9PedSwap'](f.clientEvents[1][1], true, nil)
    f.revokePermissionDirect('CITIZEN_TARGET', 'k9.access') -- no longer holds the role via any path
    f.clearClientEvents()

    local originalQueryAwait = f.mysql.query.await
    f.mysql.query.await = function(sql, params)
        if sql:find('UPDATE k9_ped_assignments SET active = 0', 1, true) then
            error('simulated: DB unreachable at reconnect')
        end
        return originalQueryAwait(sql, params)
    end

    f.firePlayerLoadedAppearanceHandler({ PlayerData = { citizenid = 'CITIZEN_TARGET', source = TARGET_SRC } })

    t.equals(#f.clientEvents, 0, 'the K9 model must never be re-applied to a citizenid who no longer holds the role, DB write outcome notwithstanding')
    t.isTrue(f.fakeAssignments['CITIZEN_TARGET'].active, 'the clear-write genuinely failed -- the row is left exactly as it was, for a future attempt')
    t.contains(table.concat(f.printLog, '\n'), 'k9AppearancePlayerLoaded(citizenid=CITIZEN_TARGET) -> stale_row_clear_db_error')
end)

-- ----------------------------------------------------------------------
-- 7. K9 IDENTITY -- 'john-k9:server:k9Identity' lib.callback. See
--    server/appearance.lua's own "K9 IDENTITY" section header for the
--    full design this exercises: bystander identity for an already-
--    visible, already-in-range, already-HasK9Role-confirmed K9 -- name,
--    roster callsign, optional partnered-handler name, nothing else.
-- ----------------------------------------------------------------------

local ASKING_SRC = 20
local K9_SRC = 21
local HANDLER_SRC = 22
local OTHER_K9_SRC = 23

--- Registers an asking player and a K9-role-holding target, both left at
--- GetEntityCoords' own default origin (vec3(0,0,0) -- see this fixture's
--- own GetEntityCoords doc comment) -- i.e. already "in range" unless a
--- test explicitly repositions one of them via f.setCoords.
--- @param f table
--- @return table asking
--- @return table k9
local function setupIdentityScene(f)
    local asking = f.registerPlayer(ASKING_SRC, 'CITIZEN_ASKING', { name = 'police', isboss = false, grade = { level = 0 } })
    local k9 = f.registerPlayer(K9_SRC, 'CITIZEN_K9', { name = 'police', isboss = false, grade = { level = 0 } })
    f.setCharinfo(asking, 'Alex', 'Asker')
    f.setCharinfo(k9, 'Rex', 'Callahan')
    -- A real K9: certified AND assigned a K9 appearance (a certification
    -- alone is a handler). HasK9Role(K9_SRC) == true.
    f.grantCertDirect('CITIZEN_K9', 'police')
    f.env.K9Store.Appearance_UpsertApplied('CITIZEN_K9', 'a_c_shepherd', nil, 'test')
    return asking, k9
end

--- @param f table
--- @param askingSrc number
--- @param targetSrc any
--- @return table
local function callIdentity(f, askingSrc, targetSrc)
    return f.callbacks['john-k9:server:k9Identity'](askingSrc, targetSrc)
end

t.test('K9 IDENTITY: shows the real name and callsign for a dog that has them', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.setPersonnelRow('CITIZEN_K9', 'police', 'k9', '9-Lincoln-3')

    local result = callIdentity(f, ASKING_SRC, K9_SRC)

    t.isTrue(result.ok)
    t.equals(result.name, 'Rex Callahan')
    t.equals(result.callsign, '9-Lincoln-3')
    t.isNil(result.handlerName)
end)

t.test('K9 IDENTITY: DEGRADES CLEANLY -- no roster row, no callsign, no partner at all -- the NORMAL case on a fresh server', function()
    local f = newFixture()
    setupIdentityScene(f)
    -- No f.setPersonnelRow, no f.setPartnership -- exactly a fresh install.

    local result = callIdentity(f, ASKING_SRC, K9_SRC)

    t.isTrue(result.ok)
    t.equals(result.name, 'Rex Callahan')
    t.isNil(result.callsign)
    t.isNil(result.handlerName)
end)

t.test('K9 IDENTITY: a personnel row that exists but was never given a callsign shows just the name', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.setPersonnelRow('CITIZEN_K9', 'police', 'k9', nil)

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
    t.isNil(result.callsign)
end)

t.test('K9 IDENTITY: shows the partnered handler\'s name when Config.K9Identity.showHandlerName is on', function()
    local f = newFixture()
    setupIdentityScene(f)
    local handler = f.registerPlayer(HANDLER_SRC, 'CITIZEN_HANDLER', { name = 'police', isboss = false, grade = { level = 0 } })
    f.setCharinfo(handler, 'Jordan', 'Alvarez')
    f.setPartnership('CITIZEN_K9', 'CITIZEN_HANDLER')

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
    t.equals(result.handlerName, 'Jordan Alvarez')
end)

t.test('K9 IDENTITY: Config.K9Identity.showHandlerName = false suppresses the handler name even with an active partnership', function()
    local f = newFixture({ k9Identity = { showHandlerName = false } })
    setupIdentityScene(f)
    local handler = f.registerPlayer(HANDLER_SRC, 'CITIZEN_HANDLER', { name = 'police', isboss = false, grade = { level = 0 } })
    f.setCharinfo(handler, 'Jordan', 'Alvarez')
    f.setPartnership('CITIZEN_K9', 'CITIZEN_HANDLER')

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
    t.isNil(result.handlerName)
end)

t.test('K9 IDENTITY: never shows a handler name for the BACKWARDS case -- citizenid is the HANDLER party, not the K9, in whatever partnership row exists', function()
    local f = newFixture()
    setupIdentityScene(f)
    -- Deliberately reaches past f.setPartnership's own always-K9-first
    -- convention (that helper always sets isK9=true for its first
    -- argument) to prove ResolveIdentityHandlerName's own `isK9 ~= true`
    -- guard, not merely that the helper never produces this shape.
    f.env.GetActivePartnerCitizenId = function(citizenid)
        if citizenid == 'CITIZEN_K9' then return 'CITIZEN_HANDLER', false end
        return nil, nil
    end

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
    t.isNil(result.handlerName)
end)

t.test('K9 IDENTITY: a thrown K9Store.Personnel_GetActiveRow (DB error) degrades to no callsign, never crashes the whole callback', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.env.K9Store.Personnel_GetActiveRow = function() error('simulated DB outage') end

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
    t.isNil(result.callsign)
end)

t.test('K9 IDENTITY: too_far when the asking player is not actually standing next to the target', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.setCoords(K9_SRC, 100, 100, 0) -- asking player stays at the origin

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'too_far')
end)

t.test('K9 IDENTITY: exactly at the interact range boundary still works -- the server re-check mirrors the client option\'s own 3.0m distance', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.setCoords(K9_SRC, 3.0, 0, 0)

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
end)

t.test('K9 IDENTITY: not_k9 when the target does not currently hold the K9 role, even standing right next to them', function()
    local f = newFixture()
    f.registerPlayer(ASKING_SRC, 'CITIZEN_ASKING', { name = 'police', isboss = false, grade = { level = 0 } })
    f.registerPlayer(K9_SRC, 'CITIZEN_BYSTANDER', { name = 'police', isboss = false, grade = { level = 0 } })
    -- No grantCertDirect, no k9.access permission -- HasK9Role is false.

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'not_k9')
end)

t.test('K9 IDENTITY: SWITCHED OFF -- Config.K9Identity.enabled = false refuses outright, even for a legitimate in-range K9', function()
    local f = newFixture({ k9Identity = { enabled = false } })
    setupIdentityScene(f)
    f.setPersonnelRow('CITIZEN_K9', 'police', 'k9', '9-Lincoln-3')

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'disabled')
end)

t.test('K9 IDENTITY: an unresolvable/never-registered targetServerId is refused, not crashed on', function()
    local f = newFixture()
    setupIdentityScene(f)

    local result = callIdentity(f, ASKING_SRC, 9999)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('K9 IDENTITY: a non-number targetServerId is refused, not crashed on', function()
    local f = newFixture()
    setupIdentityScene(f)

    local result = callIdentity(f, ASKING_SRC, 'not-a-number')
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('K9 IDENTITY: an asking player with no live ped is refused, not crashed on', function()
    local f = newFixture()
    setupIdentityScene(f)

    local result = f.callbacks['john-k9:server:k9Identity'](99999, K9_SRC) -- 99999 never registered -- GetPlayerPed(99999) == 0
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('K9 IDENTITY: cannot target yourself', function()
    local f = newFixture()
    setupIdentityScene(f)

    local result = callIdentity(f, K9_SRC, K9_SRC)
    t.isFalse(result.ok)
end)

-- ----------------------------------------------------------------------
-- CANNOT SELF-LABEL AS SOMEONE ELSE'S DOG (this task's rule 2) -- the
-- ONLY input this callback ever takes from the asking client is
-- targetServerId; everything else is resolved fresh, server-side.
-- ----------------------------------------------------------------------

t.test('CANNOT SELF-LABEL: extra/spoofed arguments beyond (source, targetServerId) are silently ignored -- Lua drops them, this callback declares no parameter for them', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.setPersonnelRow('CITIZEN_K9', 'police', 'k9', '9-Lincoln-3')

    -- Exactly what a modified client trying to smuggle a spoofed
    -- citizenid/name/callsign through an extra argument would send.
    local result = f.callbacks['john-k9:server:k9Identity'](ASKING_SRC, K9_SRC, 'FAKE_CITIZENID', 'Fake Name', '0-Fake-0')

    t.isTrue(result.ok)
    t.equals(result.name, 'Rex Callahan')
    t.equals(result.callsign, '9-Lincoln-3')
end)

t.test('CANNOT SELF-LABEL: two different K9s in the same scene never cross-contaminate -- asking about one never returns the other\'s name/callsign', function()
    local f = newFixture()
    setupIdentityScene(f)
    local otherK9 = f.registerPlayer(OTHER_K9_SRC, 'CITIZEN_K9_OTHER', { name = 'police', isboss = false, grade = { level = 0 } })
    f.setCharinfo(otherK9, 'Buddy', 'Otherdog')
    f.grantCertDirect('CITIZEN_K9_OTHER', 'police')
    f.env.K9Store.Appearance_UpsertApplied('CITIZEN_K9_OTHER', 'a_c_husky', nil, 'test')
    f.setPersonnelRow('CITIZEN_K9', 'police', 'k9', '9-Lincoln-3')
    f.setPersonnelRow('CITIZEN_K9_OTHER', 'police', 'k9', '9-Lincoln-9')

    local resultA = callIdentity(f, ASKING_SRC, K9_SRC)
    local resultB = callIdentity(f, ASKING_SRC, OTHER_K9_SRC)

    t.equals(resultA.name, 'Rex Callahan')
    t.equals(resultA.callsign, '9-Lincoln-3')
    t.equals(resultB.name, 'Buddy Otherdog')
    t.equals(resultB.callsign, '9-Lincoln-9')
end)

-- ----------------------------------------------------------------------
-- PAYLOAD SHAPE (this task's rule 1) -- asserted on the REAL returned
-- table's own key set, never on intent. See server/appearance.lua's own
-- "K9 IDENTITY" section header, "NEVER CONDITION/CERTIFICATION/POSITION".
-- ----------------------------------------------------------------------

local ALLOWED_SUCCESS_KEYS = { ok = true, name = true, callsign = true, handlerName = true }
local ALLOWED_FAILURE_KEYS = { ok = true, reason = true }

--- @param result table
--- @param allowed table<string, boolean>
local function assertOnlyAllowedKeys(result, allowed)
    for k in pairs(result) do
        if not allowed[k] then
            error(('PAYLOAD LEAK: unexpected key %q found in k9Identity result -- this must never carry anything beyond identity'):format(tostring(k)), 2)
        end
    end
end

t.test('PAYLOAD SHAPE: a successful result carries ONLY ok/name/callsign/handlerName -- nothing about condition, certification or position, ever', function()
    local f = newFixture()
    setupIdentityScene(f)
    f.setPersonnelRow('CITIZEN_K9', 'police', 'k9', '9-Lincoln-3')
    local handler = f.registerPlayer(HANDLER_SRC, 'CITIZEN_HANDLER', { name = 'police', isboss = false, grade = { level = 0 } })
    f.setCharinfo(handler, 'Jordan', 'Alvarez')
    f.setPartnership('CITIZEN_K9', 'CITIZEN_HANDLER')

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    assertOnlyAllowedKeys(result, ALLOWED_SUCCESS_KEYS)

    -- Named explicitly, not just "no extra keys": the exact fields this
    -- task singled out as forbidden must be absent BY NAME, not merely
    -- coincidentally missing from an allowlist that could itself be wrong.
    for _, forbidden in ipairs({
        'health', 'fatigue', 'thirst', 'hunger',
        'condition', 'certification', 'tier', 'certTier', 'specialization', 'specializations',
        'detects', 'detection', 'coords', 'position', 'x', 'y', 'z', 'citizenid', 'job',
    }) do
        t.isNil(result[forbidden], 'forbidden field must never appear: ' .. forbidden)
    end
end)

t.test('PAYLOAD SHAPE: a failure result carries ONLY ok/reason', function()
    local f = newFixture({ k9Identity = { enabled = false } })
    setupIdentityScene(f)

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    assertOnlyAllowedKeys(result, ALLOWED_FAILURE_KEYS)
end)

-- ----------------------------------------------------------------------
-- SANITIZATION -- defense in depth for a player-controllable display
-- string reaching ANOTHER player's screen (this task's own render-safely
-- instruction). See SanitizeIdentityDisplayString's own doc comment for
-- why this stops at stripping/clamping rather than neutralising markdown.
-- ----------------------------------------------------------------------

t.test('SANITIZATION: control characters are stripped and an oversized name is clamped before it ever reaches another client', function()
    local f = newFixture()
    local asking = f.registerPlayer(ASKING_SRC, 'CITIZEN_ASKING', { name = 'police', isboss = false, grade = { level = 0 } })
    local k9 = f.registerPlayer(K9_SRC, 'CITIZEN_K9', { name = 'police', isboss = false, grade = { level = 0 } })
    f.setCharinfo(asking, 'Alex', 'Asker')
    f.grantCertDirect('CITIZEN_K9', 'police')
    f.env.K9Store.Appearance_UpsertApplied('CITIZEN_K9', 'a_c_shepherd', nil, 'test')
    f.setCharinfo(k9, 'Rex\7\27[31m', ('X'):rep(80))

    local result = callIdentity(f, ASKING_SRC, K9_SRC)
    t.isTrue(result.ok)
    t.isNil(result.name:find('\7', 1, true), 'a raw control character must never survive into another client\'s notification')
    t.isTrue(#result.name <= 48, 'an oversized name must be clamped, not passed through as-is')
end)

os.exit(t.summary())
