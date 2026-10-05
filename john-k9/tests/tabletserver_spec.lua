--[[
    tests/tabletserver_spec.lua

    Tests server/tablet.lua -- the K9 Command Tablet's server aggregation
    layer -- against the REAL, unmodified production file, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/permissions_spec.lua's
    UNIT-level newFixture(): IsHighCommand/HasPermission/HasK9Access/GetXP/
    GetXPTier/ApplyK9PedRole/ForceRevertK9Appearance are TEST-CONTROLLED
    stubs (plain functions the test swaps in), matching this codebase's
    `type(fn) == 'function'` soft-dependency contract -- a real deployment
    satisfies it via the real server/permissions.lua, server/certifications/,
    server/highcommand.lua, server/progression.lua and server/appearance.lua;
    this fixture satisfies it via doubles, so server/tablet.lua's OWN logic
    (state resolution, authorization re-verification, roster bounding) is
    exercised in isolation from those five files' own already-independently-
    tested internals.

    FAKE k9_permissions / k9_certifications TABLES: two in-memory arrays the
    MySQL stub below reads, dispatched by matching the exact SQL text
    substrings server/tablet.lua's own SafeQuery/scalar calls use -- see
    that file's own four query strings (grepped before writing this stub,
    not guessed).

    tabletCertify and tabletGiveXp are NOT tested here -- per server/tablet.lua's
    own header "ARCHITECTURE DECISION", those two callbacks are registered
    inside server/certifications/ (GrantCertificationForTablet) and
    server/highcommand.lua (GrantHighCommandXp/IsAuthorizedForXpGrant)
    respectively, not in this file at all; certifications_spec.lua and
    highcommand_spec.lua are the right place for coverage of those two (see
    each file's own test additions this pass).

    ROUND TRIP SECTION (added at coder-security's own request, following
    their server/permissions.lua IsValidPermissionKey fix for the
    'feature.<Name>'/'block.<Name>' namespace): a SEPARATE, INTEGRATION-level
    newIntegrationFixture() below loads the REAL server/permissions.lua
    (cooldowns.lua first, for NewCooldown at that file's own load time)
    alongside the REAL server/tablet.lua in one shared env, backed by a
    single real in-memory k9_permissions table both files read/write
    against -- proving the full path end to end: a grant made through
    tabletGrantPermission is a real, storable row that server/tablet.lua's
    OWN QueryActivePermissionSet/ResolveFeatureState later reads back
    correctly, not merely that each half independently believes it works.
    IsHighCommand/HasK9Access remain test-controlled stubs here too (this is
    still not a full production-topology test -- server/certifications//
    server/highcommand.lua are not loaded), matching this file's own
    established UNIT-level convention for everything this round trip does
    not need a real implementation of.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param opts table? -- { isHighCommand, hasPermission, hasK9Access, getXP, getXPTier, applyK9PedRole, forceRevertK9Appearance, listPermissionCatalogKeys, config: table (full Config override) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    -- ---- fake tables ----
    local permRows = {} -- { citizenid, permission, granted_by, active }
    local certRows = {} -- { citizenid, job, granted_by, active }

    local function addPermRow(citizenid, permission, grantedBy, active)
        permRows[#permRows + 1] = { citizenid = citizenid, permission = permission, granted_by = grantedBy, active = active == nil and 1 or (active and 1 or 0) }
    end
    local function addCertRow(citizenid, job, grantedBy, active)
        certRows[#certRows + 1] = { citizenid = citizenid, job = job, granted_by = grantedBy, active = active == nil and 1 or (active and 1 or 0) }
    end

    local mysql = {
        query = { await = function(sql, params)
            if sql:find('k9_permissions', 1, true) then
                local out = {}
                for _, row in ipairs(permRows) do
                    if row.citizenid == params[1] and row.active == 1 then
                        out[#out + 1] = { permission = row.permission }
                    end
                end
                return out
            elseif sql:find('k9_certifications', 1, true) then
                if sql:find('WHERE citizenid = ?', 1, true) then
                    local out = {}
                    for _, row in ipairs(certRows) do
                        if row.citizenid == params[1] and row.active == 1 then
                            out[#out + 1] = { job = row.job, granted_by = row.granted_by }
                        end
                    end
                    return out
                elseif sql:find('WHERE job = ?', 1, true) then
                    local out = {}
                    for _, row in ipairs(certRows) do
                        if row.job == params[1] and row.active == 1 then
                            out[#out + 1] = { citizenid = row.citizenid, granted_by = row.granted_by }
                        end
                    end
                    return out
                end
            end
            return {}
        end },
        scalar = { await = function(sql, params)
            if sql:find('k9_certifications', 1, true) then
                for _, row in ipairs(certRows) do
                    if row.citizenid == params[1] and row.active == 1 then return 1 end
                end
                return nil
            end
            return nil
        end },
    }

    -- ---- event handlers (RATE LIMITING, this pass) ----
    -- server/cooldowns.lua's TabletReadCooldown.RegisterPlayerDropped() call
    -- (server/tablet.lua's own file-load time) needs a real AddEventHandler
    -- to register against -- a plain capture-and-store stub, same shape
    -- tests/runtimecontrol_spec.lua's own AddEventHandlerStub already
    -- established, though this fixture has no need to actually FIRE
    -- 'playerDropped' anywhere yet (no test here currently depends on that
    -- cleanup); it only needs the call itself not to error.
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- ---- players ----
    local playersBySource = {}
    local playersByCitizenId = {}
    -- OFFLINE roster -- deliberately separate from playersByCitizenId
    -- (an online player must never be looked up through this table; the
    -- two are mutually exclusive in production, matching qbx_core's own
    -- GetPlayerByCitizenId/GetOfflinePlayer split). See
    -- registerOfflinePlayer below.
    local offlinePlayersByCitizenId = {}

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    --- @param charinfo table?
    local function registerPlayer(source, citizenid, job, charinfo)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source, charinfo = charinfo } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return source
    end

    --- ONLINE PLAYERS LIST fixture support (this pass) -- simulates a
    --- real disconnect: removes BOTH the by-source and by-citizenid
    --- entries, exactly like a real qbx_core player object vanishing on
    --- drop. Used to build the "recycled source id" scenario:
    --- dropPlayer(5) then registerPlayer(5, otherCitizenid, ...) puts a
    --- DIFFERENT citizenid at the SAME source number, mirroring FXServer
    --- handing a freed connection slot to the next joiner.
    --- @param source number
    local function dropPlayer(source)
        local p = playersBySource[source]
        if p and p.PlayerData and playersByCitizenId[p.PlayerData.citizenid] == p then
            playersByCitizenId[p.PlayerData.citizenid] = nil
        end
        playersBySource[source] = nil
    end

    --- @return string[] -- every currently-connected source, as strings,
    --- matching FXServer's own GetPlayers() return shape (server/main.lua's
    --- own header comment: "GetPlayers() returns connected player ids as
    --- strings; tonumber'd below" -- server/tablet.lua's
    --- tabletRequestOnlinePlayers does the identical tonumber() dance).
    --- Numerically sorted so a test can assert on a stable row order.
    local function GetPlayersStub()
        local sources = {}
        for src in pairs(playersBySource) do sources[#sources + 1] = src end
        table.sort(sources)
        local out = {}
        for i, src in ipairs(sources) do out[i] = tostring(src) end
        return out
    end

    --- Registers a citizenid that is NEVER online for this fixture --
    --- exercised only through exports.qbx_core:GetOfflinePlayer, never
    --- GetPlayerByCitizenId/GetPlayer (see server/tablet.lua's
    --- ResolveDisplayName OFFLINE branch).
    --- @param citizenid string
    --- @param charinfo table?
    local function registerOfflinePlayer(citizenid, charinfo)
        offlinePlayersByCitizenId[citizenid] = { PlayerData = { citizenid = citizenid, charinfo = charinfo }, Offline = true }
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
            GetOfflinePlayer = function(_self, citizenid) return offlinePlayersByCitizenId[citizenid] end,
        },
    }

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local function GetPlayerNameStub(source)
        return 'SteamName#' .. tostring(source)
    end

    local Config = opts.config or {
        Features = {
            CommandTablet = true,
            PermissionGrants = true,
            XPProgression = true,
            HighCommand = true,
            BiteAndHold = true,
            NonLethalTakedown = true,
            LeashMechanics = true,
        },
        Departments = {
            police  = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 },
            sheriff = { label = 'Blaine County Sheriff', certifierGrade = 3, auditGrade = 3, highCommandGrade = 5 },
        },
        Permissions = {
            ['k9.access']  = { label = 'Use K9 abilities' },
            ['k9.certify'] = { label = 'Certify and decertify others' },
            ['k9.audit']   = { label = 'View the audit records' },
            ['k9.givexp']  = { label = 'Grant XP' },
        },
        FeatureControl = {
            RequireGrant = { BiteAndHold = true, NonLethalTakedown = true },
            everyoneCanViewOwnRecord = true,
        },
        CommandTablet = {
            maxRosterRows = 100,
        },
        HighCommand = { allowSelfGrant = false },
    }

    -- RATE LIMITING (this pass) -- server/tablet.lua's four read callbacks
    -- now share TabletReadCooldown (NewCooldown, keyed by source), which
    -- calls GetGameTimer() at cooldown-check time. fakeNow lets a test pin
    -- and advance that clock deterministically -- same pattern
    -- tests/runtimecontrol_spec.lua already established for its own
    -- RuntimeControlActionCooldown coverage. Starts at 0 for every fresh
    -- fixture (a new env/NewCooldown instance per newFixture() call, same
    -- as every other piece of this fixture's state), so no cross-test
    -- contamination.
    local fakeNow = { value = 0 }

    local env = Sandbox.newEnv({
        Config = Config,
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = GetPlayerNameStub,
        GetPlayers = GetPlayersStub,
        GetGameTimer = function() return fakeNow.value end,
        AddEventHandler = AddEventHandlerStub,
        print = function() end,
        -- Test-controlled soft dependencies -- see this file's header.
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasPermission = opts.hasPermission, -- deliberately nil by default (type() guard must tolerate absence)
        HasK9Access = opts.hasK9Access,
        -- DISPLAY-GAP FIX (this pass) -- server/permissions.lua's own
        -- IsHighCommandBypassCitizenId, soft-dependency guarded exactly
        -- like every other cross-file global in this list. Deliberately
        -- nil by default (like HasPermission above): every EXISTING test
        -- in this file exercises the "absent" degrade path (no bypass at
        -- all, identical to before this pass); only the new tests below
        -- pass opts.isHighCommandBypassCitizenId.
        IsHighCommandBypassCitizenId = opts.isHighCommandBypassCitizenId,
        GetXP = opts.getXP,
        GetXPTier = opts.getXPTier,
        ApplyK9PedRole = opts.applyK9PedRole,
        ForceRevertK9Appearance = opts.forceRevertK9Appearance,
        -- ASSIGNED-K9-MODEL READ-SIDE (this pass, coder-ui, for the
        -- Onboarding flow's new K9 Role step's honest summary) --
        -- server/appearance.lua's own already-exposed, DB-authoritative
        -- accessor (GetAssignedK9Model), same soft-dependency contract as
        -- every other entry in this list. Deliberately nil by default:
        -- every EXISTING test in this file exercises tabletRequestPersonSummary's
        -- own `assignedK9Model = nil` degrade path; only the new tests
        -- below pass opts.getAssignedK9Model.
        GetAssignedK9Model = opts.getAssignedK9Model,
        -- CERTIFICATION DEPTH READ-SIDE (this pass) -- server/certifications/'s
        -- own DB-authoritative, already-exposed accessor. Deliberately nil by
        -- default (like HasPermission above): BuildCertificationsArray's own
        -- `type(QueryCertificationRecord) == 'function'` guard must tolerate
        -- its absence and degrade to no tier/expiry/specializations data
        -- rather than erroring.
        QueryCertificationRecord = opts.queryCertificationRecord,
        -- PERMISSION-KEY CATALOG AWARENESS (this pass) -- server/tablet.lua's
        -- own AdminCapabilityCandidateKeys soft-depends on
        -- server/permissionkeycatalog.lua's real, global ListPermissionCatalogKeys
        -- via a `type(...) == 'function'` guard, exactly like every other
        -- entry in this list. Deliberately nil by default (like HasPermission
        -- above): every EXISTING test in this file exercises the "catalog
        -- absent" fallback path (Config.Permissions alone), matching this
        -- fixture's pre-existing, unchanged behavior; only the new
        -- catalog-aware tests below pass opts.listPermissionCatalogKeys.
        ListPermissionCatalogKeys = opts.listPermissionCatalogKeys,
        -- osTime lets a test pin "now" for expiry-boundary assertions without
        -- depending on real wall-clock time -- see NowUnixOrNil in
        -- server/tablet.lua. Omitted entirely (not even set to nil) when
        -- opts.osTime is absent, so env.os stays the REAL os table
        -- Sandbox.newEnv already shallow-copied from _G.
        os = opts.osTime and { time = opts.osTime } or nil,
    })

    -- K9Store migration (this pass): server/tablet.lua's QueryHasAnyActiveCertification/
    -- QueryActivePermissionSet now read through K9Store.Cert_GetActiveIdAnyJob/
    -- K9Store.Perm_GetActiveForCitizen (server/datastore.lua) instead of calling
    -- MySQL.* directly -- load the real datastore.lua into this SAME env, ahead of
    -- tablet.lua, so K9Store exists as a real global by the time tablet.lua's own
    -- chunk runs. `mysql` above is unchanged: K9Store's DB-mode branches call the
    -- exact same MySQL.query.await/MySQL.scalar.await this stub already dispatches
    -- on by SQL substring, since K9Store mirrors that SQL verbatim.
    -- server/cooldowns.lua -- HARD load-order requirement, same as the real
    -- fxmanifest.lua's own placement: server/tablet.lua now calls
    -- NewCooldown at its own file-load time (TabletReadCooldown), so
    -- cooldowns.lua must already be loaded into this SAME env first.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/tablet.lua', env)

    return {
        env = env,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        dropPlayer = dropPlayer,
        registerOfflinePlayer = registerOfflinePlayer,
        addPermRow = addPermRow,
        addCertRow = addCertRow,
        permRows = permRows,
        certRows = certRows,
        fakeNow = fakeNow,
        eventHandlers = eventHandlers,
    }
end

--- @param f table
--- @param name string
--- @return function
local function cb(f, name)
    local fn = f.callbacks[name]
    assert(fn, 'callback not registered: ' .. name)
    return fn
end

-- ============================================================================
-- FEATURE GATE: server/tablet.lua registers NOTHING at all when
-- Config.Features.CommandTablet is not true -- matches server/permissions.lua's
-- identical "gate at registration, not just inside the handler" convention.
-- ============================================================================

t.test('Config.Features.CommandTablet == false: none of the callbacks are registered', function()
    local f = newFixture({ config = { Features = { CommandTablet = false } } })
    t.isNil(f.callbacks['john-k9:server:tabletRequestMyRecord'])
    t.isNil(f.callbacks['john-k9:server:tabletRequestRoster'])
    t.isNil(f.callbacks['john-k9:server:tabletRequestOnlinePlayers'])
    t.isNil(f.callbacks['john-k9:server:tabletResolveOnlinePlayer'])
    t.isNil(f.callbacks['john-k9:server:tabletRequestPersonSummary'])
    t.isNil(f.callbacks['john-k9:server:tabletRequestPersonFeatures'])
    t.isNil(f.callbacks['john-k9:server:tabletAssignK9Role'])
    t.isNil(f.callbacks['john-k9:server:tabletRevertK9Ped'])
end)

t.test('Config.Features.CommandTablet == true: all eight local callbacks are registered', function()
    local f = newFixture()
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestMyRecord'])
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestRoster'])
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestOnlinePlayers'])
    t.isNotNil(f.callbacks['john-k9:server:tabletResolveOnlinePlayer'])
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestPersonSummary'])
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestPersonFeatures'])
    t.isNotNil(f.callbacks['john-k9:server:tabletAssignK9Role'])
    t.isNotNil(f.callbacks['john-k9:server:tabletRevertK9Ped'])
end)

-- ============================================================================
-- tabletRequestMyRecord
-- ============================================================================

t.test('tabletRequestMyRecord: an unresolvable caller (no Player/citizenid) fails closed', function()
    local f = newFixture()
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(999)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestMyRecord: everyoneCanViewOwnRecord == false denies a non-high-command caller', function()
    local f = newFixture({
        config = {
            Features = { CommandTablet = true },
            FeatureControl = { everyoneCanViewOwnRecord = false },
            Permissions = { ['k9.access'] = { label = 'x' } },
        },
    })
    f.registerPlayer(1, 'VIEWER1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(1)
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestMyRecord: everyoneCanViewOwnRecord == false does NOT deny a high-command caller', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            FeatureControl = { everyoneCanViewOwnRecord = false },
            Permissions = { ['k9.access'] = { label = 'x' } },
        },
    })
    f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(1)
    t.isTrue(result.ok)
    t.isTrue(result.viewer.isHighCommand)
end)

-- ======================================================================
-- viewer.surfaces -- WHICH ADMIN SCREENS THIS SERVER ACTUALLY HAS
--
-- Owner directive, verbatim: "ensure anything disabled in the config or
-- requires a restart wont show up in the tablet".
--
-- Every admin tab in html/tablet.js was gated on the viewer's CAPABILITY
-- alone. A capability says "you are allowed to use this screen"; it says
-- nothing about whether the screen's feature is switched on. So with
-- Config.Features.TabletTheming = false a holder of 'k9.tablettheme' still
-- got a Theme tab, opened it, edited every field, and had every save
-- refused by a server-side flag check the tab never mirrored. Audit was
-- worse: server/admin.lua does not even REGISTER its tabletAudit*
-- callbacks with AdminAuditCommands off, so that tab did not fail with a
-- message -- it hung until the callback timed out.
--
-- BuildAvailableSurfaces resolves this here, from the same Config.Features
-- flags those callbacks enforce, so the tab and the callback behind it
-- cannot disagree.
-- ======================================================================

--- @param features table -- the Config.Features table to run against
--- @return table surfaces
local function surfacesFor(features)
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = features,
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    return result.viewer.surfaces
end

t.test('viewer.surfaces: every admin surface reports TRUE when its own Config.Features flag is on', function()
    local surfaces = surfacesFor({
        CommandTablet = true,
        TabletTheming = true,
        K9EquipmentShop = true,
        RuntimeFeatureControl = true,
        AdminAuditCommands = true,
        PermissionGrants = true,
        XPProgression = true,
    })
    t.isTrue(surfaces.theme)
    t.isTrue(surfaces.shop_locations)
    t.isTrue(surfaces.shop_items)
    t.isTrue(surfaces.runtime_control)
    t.isTrue(surfaces.audit)
    t.isTrue(surfaces.permission_keys)
    t.isTrue(surfaces.xp_tiers)
end)

t.test('viewer.surfaces: each admin surface reports FALSE when its own flag is off, and does not drag the others down with it', function()
    -- ONE flag off at a time, everything else on, so a failure can only be
    -- the specific mapping under test -- never "the whole map collapsed".
    local cases = {
        { flag = 'TabletTheming',         surface = 'theme' },
        { flag = 'RuntimeFeatureControl', surface = 'runtime_control' },
        { flag = 'AdminAuditCommands',    surface = 'audit' },
        { flag = 'PermissionGrants',      surface = 'permission_keys' },
    }
    for _, case in ipairs(cases) do
        local features = {
            CommandTablet = true, TabletTheming = true, K9EquipmentShop = true,
            RuntimeFeatureControl = true, AdminAuditCommands = true,
            PermissionGrants = true, XPProgression = true,
        }
        features[case.flag] = false
        local surfaces = surfacesFor(features)
        t.isFalse(surfaces[case.surface], case.flag .. ' off must hide ' .. case.surface)
        for _, other in ipairs(cases) do
            if other.surface ~= case.surface then
                t.isTrue(surfaces[other.surface], other.surface .. ' must be unaffected by ' .. case.flag)
            end
        end
    end
end)

t.test('viewer.surfaces: the two shop screens share ONE flag -- K9EquipmentShop off hides both', function()
    local surfaces = surfacesFor({ CommandTablet = true, K9EquipmentShop = false })
    t.isFalse(surfaces.shop_locations)
    t.isFalse(surfaces.shop_items)
end)

t.test('viewer.surfaces: XP Ranks needs only ONE ladder -- either XPProgression or HandlerXPProgression keeps it', function()
    -- The editor edits both Config.XPTiers and Config.HandlerXPTiers, so a
    -- server running exactly one ladder still has real work to do there.
    -- Only with BOTH off does the screen have nothing to edit.
    t.isTrue(surfacesFor({ CommandTablet = true, XPProgression = true, HandlerXPProgression = false }).xp_tiers)
    t.isTrue(surfacesFor({ CommandTablet = true, XPProgression = false, HandlerXPProgression = true }).xp_tiers)
    t.isFalse(surfacesFor({ CommandTablet = true, XPProgression = false, HandlerXPProgression = false }).xp_tiers)
end)

t.test('viewer.surfaces: a flag that is entirely ABSENT from Config.Features reads as off, exactly like an explicit false', function()
    -- Config.Features[key] == true is the comparison every one of these
    -- screens' own server-side callbacks makes, and nil fails it the same
    -- way false does. This map must agree with them, or the tab would show
    -- for a feature the callback refuses.
    local surfaces = surfacesFor({ CommandTablet = true })
    t.isFalse(surfaces.theme)
    t.isFalse(surfaces.shop_locations)
    t.isFalse(surfaces.shop_items)
    t.isFalse(surfaces.runtime_control)
    t.isFalse(surfaces.audit)
    t.isFalse(surfaces.permission_keys)
    t.isFalse(surfaces.xp_tiers)
end)

t.test('viewer.surfaces: NO key is sent for a screen with no owning feature flag -- an absent key means available, so inventing one would invent a switch', function()
    -- Cert Tiers, K9 Profiles, the two Roster tabs, Guided Flows and the
    -- Command Console have no Config.Features flag of their own (verified
    -- by reading server/certtiers.lua, server/k9profiles.lua and
    -- server/roster.lua -- roster.lua's only flag gate is
    -- Config.Features.CommandTablet, already true for anyone holding an
    -- open tablet). html/tablet.js's surfaceEnabled() treats an absent key
    -- as available, so adding one here with a made-up source would be
    -- describing a setting that does not exist.
    local surfaces = surfacesFor({ CommandTablet = true, TabletTheming = true })
    for _, key in ipairs({ 'cert_tiers', 'k9_profiles', 'roster_k9', 'roster_handlers', 'flows', 'console' }) do
        t.isNil(surfaces[key], key .. ' must not be described here -- it has no owning Config.Features flag')
    end
end)

t.test('tabletRequestMyRecord: SECURITY -- never trusts a client-supplied identity; resolves everything from `source`', function()
    local f = newFixture({ isHighCommand = function(source) return source == 1 end })
    f.registerPlayer(1, 'REAL-CALLER', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'SOMEONE-ELSE', { name = 'police', grade = { level = 1 } })
    -- The callback signature is (source) only -- there is no citizenid
    -- argument to spoof at all; this test documents that fact by asserting
    -- the returned viewer identity always matches the resolved SOURCE.
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(1)
    t.equals(result.viewer.citizenid, 'REAL-CALLER')
    local result2 = cb(f, 'john-k9:server:tabletRequestMyRecord')(2)
    t.equals(result2.viewer.citizenid, 'SOMEONE-ELSE')
    t.isFalse(result2.viewer.isHighCommand)
end)

t.test('tabletRequestMyRecord: effectivePermissions -- an explicit k9_permissions grant row qualifies', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'GRANTEE', { name = 'police', grade = { level = 1 } })
    f.addPermRow('GRANTEE', 'k9.audit', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.audit' then found = true end
    end
    t.isTrue(found, 'an explicit k9.audit grant must appear in effectivePermissions')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- legacy certifierGrade rank qualifies for k9.certify without any grant', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then found = true end
    end
    t.isTrue(found)
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a grade ONE BELOW certifierGrade does NOT qualify', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'LOWRANK', { name = 'police', grade = { level = 3 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    for _, key in ipairs(result.viewer.effectivePermissions) do
        t.isFalse(key == 'k9.certify', 'k9.certify must not be present for a below-threshold rank')
    end
end)

-- ============================================================================
-- PERMISSION-KEY CATALOG AWARENESS (this pass) -- ResolveEffectivePermissions
-- must consult server/permissionkeycatalog.lua's live ListPermissionCatalogKeys,
-- not just the static Config.Permissions table, or a permission key created
-- purely at runtime can be granted but never shows as held. See
-- server/tablet.lua's own "PERMISSION-KEY CATALOG AWARENESS" header section
-- (AdminCapabilityCandidateKeys) for the full contract these tests pin down.
-- ============================================================================

t.test('tabletRequestMyRecord: effectivePermissions -- a custom, non-default GRANTED key shows as held', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'Use K9 abilities' },
                { key = 'k9.certify', label = 'Certify and decertify others' },
                { key = 'k9.audit', label = 'View the audit records' },
                { key = 'k9.givexp', label = 'Grant XP' },
                { key = 'k9.specialaudit', label = 'Special Audit', description = 'A custom, runtime-created key' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'GRANTEE', { name = 'police', grade = { level = 1 } })
    f.addPermRow('GRANTEE', 'k9.specialaudit', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.specialaudit' then found = true end
    end
    t.isTrue(found, 'a granted, purely-runtime permission key must appear as held -- this is the exact bug this pass closes')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a custom, non-default UNGRANTED key does NOT show as held', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'NOTGRANTED', { name = 'police', grade = { level = 1 } })
    -- deliberately NO addPermRow for 'k9.specialaudit' -- this citizenid does
    -- not hold it, and there is no legacy rank tier for a custom key either
    -- (server/permissions.lua's own LegacyOrHighCommandStillQualifies has no
    -- branch for it), so it must be a candidate WITHOUT qualifying.
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    for _, key in ipairs(result.viewer.effectivePermissions) do
        t.isFalse(key == 'k9.specialaudit', 'an ungranted custom key must never read as held')
    end
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a TOMBSTONED-but-held custom key still appears (so it remains revocable)', function()
    local f = newFixture({
        -- The catalog no longer lists 'k9.specialaudit' at all -- exactly
        -- what server/permissionkeycatalog.lua's ListPermissionCatalogKeys
        -- returns for a tombstoned key (see that file's header "TOMBSTONE,
        -- NOT REFERENCE-COUNTED"). Only the still-shipped defaults remain.
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'Use K9 abilities' },
                { key = 'k9.certify', label = 'Certify and decertify others' },
                { key = 'k9.audit', label = 'View the audit records' },
                { key = 'k9.givexp', label = 'Grant XP' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'RETIREE', { name = 'police', grade = { level = 1 } })
    f.addPermRow('RETIREE', 'k9.specialaudit', 'HC', true) -- still an ACTIVE grant, despite the tombstone
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.specialaudit' then found = true end
    end
    t.isTrue(found, 'a tombstoned key someone still actively holds must still surface, or nobody could ever revoke it from the tablet')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- the four shipped keys resolve unchanged when the catalog is present', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'Use K9 abilities' },
                { key = 'k9.certify', label = 'Certify and decertify others' },
                { key = 'k9.audit', label = 'View the audit records' },
                { key = 'k9.givexp', label = 'Grant XP' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    f.addPermRow('RANKED', 'k9.audit', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local foundCertify, foundAudit, foundAccess, foundGivexp = false, false, false, false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then foundCertify = true end
        if key == 'k9.audit' then foundAudit = true end
        if key == 'k9.access' then foundAccess = true end
        if key == 'k9.givexp' then foundGivexp = true end
    end
    t.isTrue(foundCertify, 'legacy certifierGrade rank resolution must still work with the catalog present')
    t.isTrue(foundAudit, 'an explicit grant must still work with the catalog present')
    t.isFalse(foundAccess, 'k9.access must not be granted just because the catalog lists it')
    t.isFalse(foundGivexp, 'k9.givexp has no legacy tier and was never granted here')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a rank-qualified certifier still qualifies for k9.certify even if the catalog has TOMBSTONED that literal key', function()
    -- server/permissionkeycatalog.lua's own header ("NO PROTECTED KEY") is
    -- explicit that tombstoning 'k9.certify' only turns off the ABILITY TO
    -- GRANT/HOLD it BY THAT ROUTE -- certifications.lua's own independent
    -- rank-based IsEligibleCertifier check is unaffected either way. This
    -- file's own effectivePermissions must not silently disagree by hiding
    -- a real, independently-qualified capability the moment the catalog
    -- entry disappears -- see LEGACY_PERMISSION_KEYS's own doc comment.
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return { { key = 'k9.access', label = 'x' } } -- k9.certify tombstoned/absent
        end,
    })
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local found = false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then found = true end
    end
    t.isTrue(found, 'a rank-qualified certifier must not lose their real capability just because the catalog entry was tombstoned')
end)

t.test('tabletRequestMyRecord: effectivePermissions -- a THROWING catalog degrades to the four shipped keys, never an empty list', function()
    local f = newFixture({
        listPermissionCatalogKeys = function() error('simulated catalog failure') end,
    })
    local src = f.registerPlayer(1, 'RANKED', { name = 'police', grade = { level = 4 } })
    f.addPermRow('RANKED', 'k9.audit', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local foundCertify, foundAudit = false, false
    for _, key in ipairs(result.viewer.effectivePermissions) do
        if key == 'k9.certify' then foundCertify = true end
        if key == 'k9.audit' then foundAudit = true end
    end
    t.isTrue(foundCertify, 'a catalog read failure must fall back to the four shipped keys, not an empty capability set')
    t.isTrue(foundAudit, 'an explicit grant must still resolve even when the catalog throws')
end)

t.test('tabletRequestMyRecord: certifications array has ONE ROW PER CONFIGURED DEPARTMENT, including ones never held', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.equals(#result.certifications, 2) -- police + sheriff, both configured
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.active)
    t.equals(byDept.police.grantedBy, 'GRANTER1')
    t.isFalse(byDept.sheriff.active)
    t.isNil(byDept.sheriff.grantedBy)
end)

-- ============================================================================
-- DISPLAY NAME RESOLUTION (owner's own request: "ensure a name actually
-- pops up and not the player id... in the tablet etc") -- BuildCertificationsArray's
-- `grantedBy` field was a raw citizenid with no name at all, and
-- html/tablet.js already renders it directly as plain text -- see
-- EnrichCertificationsWithGrantedByName's own doc comment in
-- server/tablet.lua. `grantedBy` itself must never change.
-- ============================================================================

t.test('tabletRequestMyRecord: certifications array carries grantedByName resolved via ResolveDisplayName for an ONLINE granter with charinfo', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(2, 'GRANTER1', { name = 'police', grade = { level = 5 } }, { firstname = 'Jane', lastname = 'Granter' })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.equals(byDept.police.grantedBy, 'GRANTER1', 'the raw citizenid must never be replaced by the name')
    t.equals(byDept.police.grantedByName, 'Jane Granter')
    t.isNil(byDept.sheriff.grantedBy)
    t.isNil(byDept.sheriff.grantedByName, 'a never-held department has no grantedBy at all, so no name to resolve either')
end)

t.test('tabletRequestMyRecord: certifications array grantedByName falls back to the bare citizenid when no name resolves (never blank, never a fake name)', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    -- GRANTER2 is registered neither online nor offline -- unresolvable.
    f.addCertRow('CIT1', 'police', 'GRANTER2', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.equals(byDept.police.grantedByName, 'GRANTER2', 'unresolvable name must fall back to the raw citizenid, never blank')
end)

-- ============================================================================
-- CERTIFICATION DEPTH READ-SIDE (this pass) -- BuildCertificationsArray now
-- carries tier/expiresAtUnix/expired/specializations per department, sourced
-- from server/certifications/'s DB-authoritative QueryCertificationRecord.
-- See that helper's own doc comment in server/tablet.lua for the full
-- reasoning (offline-safe, bounded per configured department, guarded soft
-- dependency).
-- ============================================================================

t.test('tabletRequestMyRecord: certifications array carries tier/expiry/specializations for an actively-held department', function()
    local f = newFixture({
        queryCertificationRecord = function(citizenid, jobName)
            if citizenid == 'CIT1' and jobName == 'police' then
                return { tier = 'senior', expiresAtUnix = 9999999999, specializations = { 'narcotics', 'explosives' } }
            end
            return nil
        end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end

    t.equals(byDept.police.tier, 'senior')
    t.equals(byDept.police.expiresAtUnix, 9999999999)
    t.isFalse(byDept.police.expired)
    t.equals(#byDept.police.specializations, 2)

    -- A department this citizen has never held must carry NO tier/expiry/
    -- specialization data at all -- see this function's own doc comment on
    -- why that read is skipped entirely for an inactive row.
    t.isNil(byDept.sheriff.tier)
    t.isNil(byDept.sheriff.expiresAtUnix)
    t.isFalse(byDept.sheriff.expired)
    t.equals(#byDept.sheriff.specializations, 0)
end)

t.test('tabletRequestMyRecord: certifications array marks expired = true once now has reached expiresAtUnix', function()
    local f = newFixture({
        osTime = function() return 2000 end,
        queryCertificationRecord = function() return { tier = 'certified', expiresAtUnix = 1000, specializations = {} } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.expired)
end)

t.test('tabletRequestMyRecord: certifications array does NOT mark expired before expiresAtUnix is reached', function()
    local f = newFixture({
        osTime = function() return 500 end,
        queryCertificationRecord = function() return { tier = 'certified', expiresAtUnix = 1000, specializations = {} } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isFalse(byDept.police.expired)
end)

t.test('tabletRequestMyRecord: certifications array never marks expired when expiresAtUnix is nil (never expires)', function()
    local f = newFixture({
        osTime = function() return 999999999999 end, -- an absurdly large "now" -- must still not flip expired
        queryCertificationRecord = function() return { tier = 'certified', expiresAtUnix = nil, specializations = {} } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isFalse(byDept.police.expired)
    t.isNil(byDept.police.expiresAtUnix)
end)

t.test('tabletRequestMyRecord: certifications array degrades cleanly (no crash, no data) when QueryCertificationRecord is unavailable', function()
    local f = newFixture() -- queryCertificationRecord omitted -- stays nil, matching every other soft dependency default
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.active)
    t.isNil(byDept.police.tier)
    t.isNil(byDept.police.expiresAtUnix)
    t.isFalse(byDept.police.expired)
    t.equals(#byDept.police.specializations, 0)
end)

t.test('tabletRequestMyRecord: certifications array degrades cleanly when QueryCertificationRecord itself returns nil for an active row', function()
    -- A genuine race (the row was revoked between the two reads) or any
    -- other reason the DB-authoritative read comes back empty must never
    -- crash this callback -- see BuildCertificationsArray's own doc comment.
    local f = newFixture({ queryCertificationRecord = function() return nil end })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.isTrue(byDept.police.active)
    t.isNil(byDept.police.tier)
end)

t.test('tabletRequestMyRecord: certifications array never queries QueryCertificationRecord for a department not actively held', function()
    local queriedJobs = {}
    local f = newFixture({
        queryCertificationRecord = function(_citizenid, jobName)
            queriedJobs[#queriedJobs + 1] = jobName
            return { tier = 'certified', expiresAtUnix = nil, specializations = {} }
        end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addCertRow('CIT1', 'police', 'GRANTER1', true) -- sheriff left unheld
    cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.equals(#queriedJobs, 1)
    t.equals(queriedJobs[1], 'police')
end)

t.test('tabletRequestMyRecord: xp/tierLabel are nil when XPProgression is off', function()
    local f = newFixture({
        getXP = function() return 500 end,
        getXPTier = function() return { label = 'Trained K9' } end,
        config = {
            Features = { CommandTablet = true, XPProgression = false },
            Departments = {}, Permissions = {}, FeatureControl = {}, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isNil(result.xp)
    t.isNil(result.tierLabel)
end)

t.test('tabletRequestMyRecord: xp/tierLabel are populated when XPProgression is on', function()
    local f = newFixture({
        getXP = function() return 500 end,
        getXPTier = function() return { label = 'Trained K9' } end,
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.equals(result.xp, 500)
    t.equals(result.tierLabel, 'Trained K9')
end)

-- ============================================================================
-- tabletRequestMyRecord: partnership (this pass, coder-backend -- closing
-- the gap an ordinary K9/handler had no way to see their OWN partnership on
-- their OWN record: tabletRequestPersonSummary already called
-- ResolvePartnershipInfo for a high-command-only TARGET lookup, but nothing
-- put the caller's own equivalent into the record every certified
-- handler/K9 actually opens). SAME function, SAME shape, and the SAME
-- `Config.Database = { enabled = false }` / K9Store.Partner_Insert seeding
-- pattern as the tabletRequestPersonSummary partnership tests above.
-- ============================================================================

t.test('tabletRequestMyRecord: partnership -- nil when Config.Features.HandlerPartnership is off', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isNil(result.partnership)
end)

t.test('tabletRequestMyRecord: partnership -- nil when the feature is on but the caller has no active partnership', function()
    local f = newFixture({
        config = {
            Features = { CommandTablet = true, HandlerPartnership = true },
            Departments = {}, Permissions = {},
            FeatureControl = { everyoneCanViewOwnRecord = true },
            CommandTablet = {},
            Database = { enabled = false },
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isNil(result.partnership)
end)

t.test('tabletRequestMyRecord: partnership -- resolves the CALLER\'s own active partner + role from the real k9_partnerships store, for BOTH roles', function()
    local f = newFixture({
        config = {
            Features = { CommandTablet = true, HandlerPartnership = true },
            Departments = {}, Permissions = {},
            FeatureControl = { everyoneCanViewOwnRecord = true },
            CommandTablet = {},
            Database = { enabled = false }, -- real K9Store in-memory mode, no MySQL stub needed
        },
    })
    local k9Src = f.registerPlayer(1, 'K9-SELF', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(2, 'HANDLER-SELF', { name = 'police', grade = { level = 1 } })
    f.env.K9Store.Partner_Insert('K9-SELF', 'HANDLER-SELF', 'HANDLER-SELF')

    local k9Result = cb(f, 'john-k9:server:tabletRequestMyRecord')(k9Src)
    t.isNotNil(k9Result.partnership)
    t.equals(k9Result.partnership.partnerCitizenid, 'HANDLER-SELF')
    t.equals(k9Result.partnership.role, 'k9')

    f.fakeNow.value = f.fakeNow.value + 1000 -- past TabletReadCooldown -- two separate reads from two different sources, not a batch
    local handlerResult = cb(f, 'john-k9:server:tabletRequestMyRecord')(2)
    t.isNotNil(handlerResult.partnership)
    t.equals(handlerResult.partnership.partnerCitizenid, 'K9-SELF')
    t.equals(handlerResult.partnership.role, 'handler')
end)

t.test('tabletRequestMyRecord: partnership -- SECURITY: never reads any other citizenid\'s partnership, even if one is active', function()
    local f = newFixture({
        config = {
            Features = { CommandTablet = true, HandlerPartnership = true },
            Departments = {}, Permissions = {},
            FeatureControl = { everyoneCanViewOwnRecord = true },
            CommandTablet = {},
            Database = { enabled = false },
        },
    })
    f.registerPlayer(1, 'K9-OTHER', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(2, 'HANDLER-OTHER', { name = 'police', grade = { level = 1 } })
    f.env.K9Store.Partner_Insert('K9-OTHER', 'HANDLER-OTHER', 'HANDLER-OTHER')

    -- A THIRD, unrelated, unpartnered caller -- this callback takes no
    -- targetCitizenId argument at all, so there is no client-suppliable
    -- input that could ever point it at the other pair's row above.
    local bystanderSrc = f.registerPlayer(3, 'BYSTANDER', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(bystanderSrc)
    t.isNil(result.partnership)
end)

-- ----------------------------------------------------------------------
-- myFeatures STATE RESOLUTION -- LOAD-BEARING: exact precedence order.
-- ----------------------------------------------------------------------

t.test('myFeatures: a globally-disabled feature reports global_off regardless of anything else', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = false },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CIT1', 'feature.BiteAndHold', 'HC', true) -- even WITH a grant
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'global_off')
end)

t.test('myFeatures: a Config.Features key entirely ABSENT from Config.Features (never set, not even to false) produces NO myFeatures[] entry at all -- the exact server-side shape html/tablet.js\'s own myFeatureState() must resolve to off, not "no gate matched" (pins the fact behind this pass\'s Command Reference fix)', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            -- 'BiteAndHold' is DELIBERATELY not listed here at all -- not
            -- `BiteAndHold = false` (already covered by the test immediately
            -- above, which was already handled correctly before this pass).
            -- This is the real shape a removed/never-added feature key takes
            -- in production config.lua: this resource's own real
            -- ScentTrailHunt (removed entirely) is a genuinely absent key,
            -- not a `= false` one -- see config.lua's own Config.Features
            -- comment.
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)

    local absentRow
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then absentRow = entry end end
    t.isNil(absentRow, 'BuildMyFeaturesArray enumerates pairs(Config.Features) fresh -- a key that was never set there gets NO array entry at all, never an entry with some off-flavored state string. This is the exact server-side fact html/tablet.js\'s own myFeatureState() must treat an absent lookup as equivalent to global_off for, instead of falling through to "available" (the client-side bug this pass fixed -- see that file\'s own myFeatureState() doc comment).')

    -- CONTROL -- a key that IS present in Config.Features still gets a real
    -- entry with a real resolved state, proving the loop above genuinely
    -- distinguishes "absent" from "present" rather than this test passing
    -- vacuously because myFeatures came back empty for some unrelated reason.
    local presentRow
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then presentRow = entry end end
    t.isNotNil(presentRow, 'CONTROL: a Config.Features key that IS present still produces a real myFeatures[] entry')
    t.equals(presentRow.state, 'available', 'CONTROL: that present key resolves its real state as normal, not swallowed by the same loop')
end)

t.test('myFeatures: an explicit block row wins over everything below it (has access, no grant needed)', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CIT1', 'block.LeashMechanics', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'blocked')
end)

t.test('myFeatures: lacking K9 access resolves not_certified (feature on, not blocked, no grant needed)', function()
    local f = newFixture({
        hasK9Access = function() return false end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true }, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'not_certified')
end)

t.test('myFeatures: RequireGrant-listed feature with K9 access but no grant resolves requires_grant_missing', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'requires_grant_missing')
end)

t.test('myFeatures: RequireGrant-listed feature WITH the grant, K9 access, unblocked resolves available', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CIT1', 'feature.BiteAndHold', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'available')
end)

t.test('myFeatures: a feature with NO RequireGrant entry, K9 access, unblocked resolves available with no grant needed', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true }, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'available')
end)

t.test('myFeatures: DYNAMIC LIST -- a feature key with no code-level awareness at all still appears and resolves correctly', function()
    -- Proves server/tablet.lua reads Config.Features live, not a hardcoded
    -- Lua-literal list -- the owner's own explicit mid-pass requirement.
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, SomeBrandNewFeatureNoOneToldTabletAbout = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true }, CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do
        if entry.key == 'SomeBrandNewFeatureNoOneToldTabletAbout' then row = entry end
    end
    t.isNotNil(row, 'a feature key never referenced anywhere in server/tablet.lua must still be rendered, purely from Config.Features')
    t.equals(row.state, 'available')
end)

-- ============================================================================
-- DISPLAY-GAP FIX (this pass) -- high command already implicitly holds
-- every permission/feature/K9 upgrade (ResolveEffectivePermissions has
-- resolved this for the four admin-capability keys for a long time); this
-- section proves myFeatures[] now reflects that SAME real authority for
-- ordinary Config.Features rows too, without ever fabricating a grant row
-- (activePermSet itself, and therefore ListActivePermissionsForCitizenId
-- reading the identical table, is untouched -- see the ROUND TRIP section
-- further down, which already pins that and must stay green).
-- ============================================================================

t.test('DISPLAY-GAP FIX: a high-command caller with NO grant and NO certification sees an ordinary feature as available, not not_certified/requires_grant_missing', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return false end, -- deliberately NO K9 access
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    -- No addPermRow at all -- no 'feature.BiteAndHold' grant, no 'k9.access'.
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'high command\'s real authority must be reflected, not under-reported as not_certified/requires_grant_missing')
end)

t.test('DISPLAY-GAP FIX: an explicit block STILL beats high command -- the owner\'s own carve-out is never quietly removed by this fix', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('HC1', 'block.LeashMechanics', 'OTHERHC', true)
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'blocked', 'a block is the one lever to restrain one specific high-command person without demoting them -- must still win')
end)

t.test('DISPLAY-GAP FIX: a globally-disabled feature stays global_off for high command too -- rank never turns a server-wide switch back on', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = false },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'global_off')
end)

t.test('DISPLAY-GAP FIX: a NON-high-command caller is completely unaffected -- still not_certified/requires_grant_missing exactly as before this pass', function()
    local f = newFixture({
        isHighCommand = function() return false end,
        hasK9Access = function() return false end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'not_certified', 'an ordinary caller must see the same honest state as always -- this fix changes nothing for them')
end)

t.test('DISPLAY-GAP FIX: does not fabricate a grant row -- activePermSet/QueryActivePermissionSet stays real for a high-command caller with no actual grant', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return false end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.equals(#f.permRows, 0, 'no k9_permissions row was ever inserted by this read-only display fix')
    t.equals(#result.viewer.effectivePermissions, 4, 'high command still resolves all four admin capabilities via the EXISTING, unrelated ResolveEffectivePermissions mechanism -- unaffected either way')
end)

t.test('DISPLAY-GAP FIX (PersonFeatures): a high-command TARGET with no personal grant/certification is shown as available, honestly labelled granted=false alongside it (never a fabricated grant)', function()
    local f = newFixture({
        isHighCommand = function(source) return source == 1 end, -- the VIEWER (source 1) is high command
        isHighCommandBypassCitizenId = function(citizenid) return citizenid == 'HCTARGET' end, -- the TARGET citizenid resolves bypass true
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local viewerSrc = f.registerPlayer(1, 'VIEWERHC', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'HCTARGET', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(viewerSrc, 'HCTARGET')
    t.isTrue(result.ok)
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'the TARGET\'s own real authority is reflected')
    t.isFalse(row.granted, 'the underlying k9_permissions record is UNCHANGED -- no grant row was fabricated just because the state now reads available')
    t.isTrue(row.viaHighCommand, 'this row would NOT be available without the bypass -- the subtle "why can they do that" marker must be true')
end)

t.test('viaHighCommand: false for a high-command target who ALSO genuinely holds the real grant -- never a second, redundant way to say "available"', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        isHighCommandBypassCitizenId = function() return true end,
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local viewerSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'HCTARGET2', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('HCTARGET2', 'feature.BiteAndHold', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(viewerSrc, 'HCTARGET2')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'available')
    t.isTrue(row.granted)
    t.isFalse(row.viaHighCommand, 'this target genuinely holds the grant -- their rank is not why this row works, so no marker')
end)

t.test('viaHighCommand: false for an ordinary feature needing no grant at all, even for a high-command target -- "available for free" is not "available via rank"', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        isHighCommandBypassCitizenId = function() return true end,
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local viewerSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'HCTARGET3', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(viewerSrc, 'HCTARGET3')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'available')
    t.isFalse(row.viaHighCommand, 'no grant was ever needed here -- high command or not, this was always going to be available')
end)


t.test('DISPLAY-GAP FIX (PersonFeatures): a high-command VIEWER looking at a THIRD, non-high-command target sees the TARGET\'s own real, ungranted state -- never the viewer\'s own rank leaking onto someone else\'s row', function()
    local f = newFixture({
        isHighCommand = function(source) return source == 1 end, -- only the viewer is high command
        isHighCommandBypassCitizenId = function(citizenid) return citizenid == 'VIEWERHC' end, -- bypass resolves true ONLY for the viewer's own citizenid, never the target's
        hasK9Access = function(source) return source == 2 end, -- the TARGET has real K9 access -- isolates this test to the RequireGrant step specifically, not a not_certified short-circuit
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local viewerSrc = f.registerPlayer(1, 'VIEWERHC', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'ORDINARYTARGET', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(viewerSrc, 'ORDINARYTARGET')
    t.isTrue(result.ok)
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'requires_grant_missing', 'the TARGET\'s own honest state, unaffected by the VIEWING officer\'s own high-command status')
    t.isFalse(row.viaHighCommand, 'no bypass applied to this target at all -- never true just because the VIEWER happens to be high command')
end)

t.test('DISPLAY-GAP FIX (PersonFeatures): OFFLINE resolves false unconditionally, by design -- soft dependency never invoked for a target with no live source at all in this fixture, matching IsHighCommandBypassCitizenId\'s own real offline contract', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        isHighCommandBypassCitizenId = function(_citizenid) return false end, -- mirrors the REAL function's own offline answer
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local viewerSrc = f.registerPlayer(1, 'VIEWERHC', { name = 'police', isboss = true, grade = { level = 0 } })
    -- OFFLINE-TARGET never registered as an online player at all -- a real,
    -- active certification (not a grant) gives them genuine K9 access
    -- offline, isolating this test to the RequireGrant step specifically
    -- rather than a not_certified short-circuit.
    f.addCertRow('OFFLINE-HC-TARGET', 'police', 'SOMEONE', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(viewerSrc, 'OFFLINE-HC-TARGET')
    t.isTrue(result.ok)
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'requires_grant_missing', 'an offline citizenid never gets the bypass, even if they would otherwise qualify while online -- under-granting offline is the deliberately safe direction')
end)

-- ============================================================================
-- DISPLAY-GAP, FAIL-OPEN FIX (coder-security pass) -- the tablet must never
-- show `available` for a feature a real HasPermission(citizenid,
-- 'block.<Name>') call would refuse. QueryActivePermissionSet used to
-- collapse "the k9_permissions read genuinely failed" and "this citizenid
-- genuinely holds zero rows" into the SAME empty table (`or {}`), and
-- ResolveFeatureState derived `blocked` purely from that table -- so a
-- database degradation (memory-mode, a per-table fallback, a schema
-- collision, or a plain transient query error) silently reported
-- `available` for a feature a real block would have refused. This mirrors
-- server/permissions.lua's own HasPermission "MEMORY-MODE BLOCK ASYMMETRY"
-- fix for the identical namespace, on the display path this time.
-- ============================================================================

t.test('FAIL-OPEN FIX: a transient k9_permissions read failure reports blocked, never available, for an otherwise-unblocked feature (myFeatures)', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    -- No block row exists at all -- a healthy read would resolve 'available'
    -- (see the control test immediately below). Simulate a real query
    -- failure (a dropped connection, a busy pool) rather than a thrown
    -- config/programmer error, exactly like RefreshPermissionCache's own
    -- bounded-retry failure mode in server/permissions.lua.
    f.env.K9Store.Perm_GetActiveForCitizen = function() error('simulated transient DB failure') end
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'blocked', 'a read that could not confirm the ABSENCE of a block must never display available -- fail closed, exactly like HasPermission')
end)

t.test('FAIL-OPEN FIX control: the SAME setup with a HEALTHY read and no block row resolves available -- the fix must not deny when nothing is actually wrong', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'a genuinely healthy read with no block row must still resolve available -- this fix must not be a blanket new denial')
end)

t.test('FAIL-OPEN FIX: an UNREADABLE k9_permissions (schema collision / this table missing from an otherwise-installed database) reports blocked too, even though the fallback read itself throws no error', function()
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    -- Memory-mode PermRows always starts empty (server/datastore.lua's own
    -- "FAIL-CLOSED, BY CONSTRUCTION" header) -- this read succeeds cleanly,
    -- ok=true, empty table -- the exact case HasPermission's own case 1
    -- exists to catch (a real, un-erroring read of a store that structurally
    -- cannot contain a row nobody has re-granted this session).
    f.env.K9Store.IsDatabaseEnabled = function(tableName)
        if tableName == 'k9_permissions' then return false end
        return true
    end
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'blocked', 'an unreadable k9_permissions must fail closed for the block namespace, matching HasPermission\'s own case 1 exactly')
end)

t.test('CASE 0: a STOCK INSTALL (Config.Database.enabled = false) reports available, not blocked -- deliberate memory-only mode is a working mode, not a degraded one', function()
    -- COMPANION TO server/permissions.lua's OWN CASE 0 (see the section of
    -- that name in tests/permissions_spec.lua for the full writeup of the
    -- live lockout this closes). This function's whole contract is that it
    -- never shows `available` for something a real HasPermission call would
    -- refuse -- and being STRICTER than HasPermission breaks that promise
    -- just as badly in the other direction: the tablet would tell every
    -- player on a stock install that every ability is blocked, while the
    -- abilities themselves work fine. The two must move together.
    local f = newFixture({
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
            -- The one difference from the test directly above: the SAME
            -- observable IsDatabaseEnabled('k9_permissions') == false, but
            -- reached deliberately, through the shipped default.
            Database = { enabled = false },
        },
    })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.env.K9Store.IsDatabaseEnabled = function(tableName)
        if tableName == 'k9_permissions' then return false end
        return true
    end
    f.env.K9Store.IsDatabaseConfiguredOff = function() return true end

    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'a stock, drag-and-drop install must not have every block-gated feature reported as blocked')
end)

t.test('FAIL-OPEN FIX: high command is NOT under-reported by this fix -- a healthy read still shows available via rank with no personal grant', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return false end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true }, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    -- Read is genuinely healthy (no failure simulated) -- high command's
    -- real authority must still surface exactly as the pre-existing
    -- DISPLAY-GAP FIX tests above already pin; this test exists specifically
    -- alongside the FAIL-OPEN fix so a future change cannot satisfy "fail
    -- closed on failure" by accidentally failing closed UNCONDITIONALLY.
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'high command must not be under-reported just because this pass hardened the failure path')
end)

t.test('FAIL-OPEN FIX: a block still wins over high command even when it is a FAILURE-INFERRED block, not a real row -- the owner\'s carve-out direction is preserved under failure too', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.env.K9Store.Perm_GetActiveForCitizen = function() error('simulated transient DB failure') end
    local result = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'blocked', 'an unreliable read must win over the high-command bypass -- exactly the same precedence a REAL block already has')
end)

t.test('FAIL-OPEN FIX (PersonFeatures): a transient read failure reports blocked for a TARGET too, never available', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = {}, everyoneCanViewOwnRecord = true },
            CommandTablet = {},
        },
    })
    local viewerSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.env.K9Store.Perm_GetActiveForCitizen = function() error('simulated transient DB failure') end
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(viewerSrc, 'ANYTARGET')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'blocked', 'the person-lookup screen must fail closed identically to myFeatures for the same reason')
    t.isFalse(row.blocked, 'the GROUND-TRUTH `blocked` field stays honest (no block row was ever confirmed) -- only the displayed `state` fails closed, exactly like the existing viaHighCommand overlay never touches granted/blocked')
end)

-- ============================================================================
-- tabletRequestRoster
-- ============================================================================

t.test('tabletRequestRoster: an unresolvable caller fails closed', function()
    local f = newFixture()
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(999, '')
    t.isFalse(result.ok)
end)

t.test('tabletRequestRoster: SECURITY -- a caller with no console access (no grant, no rank, not high command) is denied', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestRoster: a high-command caller is granted console access with an empty roster', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 0)
    t.isFalse(result.truncated)
end)

t.test('tabletRequestRoster: a caller with a plain k9.certify RANK (no grant, not high command) also gets console access', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CERTOFFICER', { name = 'police', grade = { level = 4 } }) -- certifierGrade = 4
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
end)

t.test('tabletRequestRoster: returns one row per active certification, resolves name/xp/tier', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        getXP = function(citizenid) return citizenid == 'K9-1' and 750 or 0 end,
        getXPTier = function() return { label = 'Trained K9' } end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } }, { firstname = 'Rex', lastname = 'Shepherd' })
    f.addCertRow('K9-1', 'police', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 1)
    t.equals(result.rows[1].citizenid, 'K9-1')
    t.equals(result.rows[1].name, 'Rex Shepherd')
    t.equals(result.rows[1].departmentLabel, 'Los Santos Police Department')
    t.isTrue(result.rows[1].certified)
    t.equals(result.rows[1].xp, 750)
    t.equals(result.rows[1].tierLabel, 'Trained K9')
end)

t.test('tabletRequestRoster: the free-text query matches by citizenid substring, case-insensitively', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('ALPHA-K9', 'police', 'HC1', true)
    f.addCertRow('BRAVO-K9', 'police', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, 'alpha')
    t.equals(#result.rows, 1)
    t.equals(result.rows[1].citizenid, 'ALPHA-K9')
end)

t.test('ROSTER CLAMP: Config.CommandTablet.maxRosterRows <= 0 falls back to the default, never "unlimited"', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = {}, FeatureControl = {},
            CommandTablet = { maxRosterRows = 0 }, -- the footgun value
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 150 do
        f.addCertRow(('ROSTER%03d'):format(i), 'police', 'HC1', true)
    end
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 100, 'a non-positive maxRosterRows must fall back to the documented default (100), never mean unlimited')
    t.isTrue(result.truncated)
end)

t.test('ROSTER CLAMP: more active certifications than maxRosterRows truncates and reports truncated = true', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = {}, FeatureControl = {},
            CommandTablet = { maxRosterRows = 5 },
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 20 do
        f.addCertRow(('ROSTER%03d'):format(i), 'police', 'HC1', true)
    end
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 5)
    t.isTrue(result.truncated)
    -- 'tablet.roster_truncated_notice' has landed -- truncatedMessage is a
    -- real, locale-resolved string whenever truncated == true.
    t.isNotNil(result.truncatedMessage)
end)

t.test('ROSTER CLAMP: exactly maxRosterRows candidates is NOT reported as truncated', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = {}, FeatureControl = {},
            CommandTablet = { maxRosterRows = 5 },
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 5 do
        f.addCertRow(('ROSTER%03d'):format(i), 'police', 'HC1', true)
    end
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.equals(#result.rows, 5)
    t.isFalse(result.truncated)
end)

-- ============================================================================
-- tabletRequestOnlinePlayers / tabletResolveOnlinePlayer -- owner-directed,
-- 2026-08-26: "make the add permission section... where its a list when i
-- choose a player id". SAME console-audience gate as tabletRequestRoster
-- above (CallerHasConsoleAccess), deliberately NOT the wider
-- CallerHasPersonAccess tabletRequestPersonSummary admits -- see
-- server/tablet.lua's own CALLBACK 2b/2c header for the full reasoning.
-- ============================================================================

t.test('tabletRequestOnlinePlayers: an unresolvable caller fails closed', function()
    local f = newFixture()
    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(999, '')
    t.isFalse(result.ok)
end)

t.test('tabletRequestOnlinePlayers: SECURITY -- a caller with no console access (no grant, no rank, not high command) is denied', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestOnlinePlayers: SECURITY -- UNTOUCHED by tabletRequestPersonSummary\'s own widening -- a caller holding ONLY an explicit k9.certify grant is still denied this BROWSE list', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'DELEGATE1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('DELEGATE1', 'k9.certify', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isFalse(result.ok, 'a k9.certify-only holder can still open a KNOWN person via "open by exact citizen ID" -- but must not get a free roster of everyone online')
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestOnlinePlayers: SECURITY -- a caller holding ONLY an explicit k9.givexp grant is likewise still denied', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'DELEGATE2', { name = 'police', grade = { level = 1 } })
    f.addPermRow('DELEGATE2', 'k9.givexp', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestOnlinePlayers: a high-command caller sees every connected player (including themselves), with name/job/K9-access resolved, and NEVER a citizenid field', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        hasK9Access = function(source) return source == 2 end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } }, { firstname = 'Chief', lastname = 'Hopps' })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } }, { firstname = 'Rex', lastname = 'Shepherd' })
    f.registerPlayer(3, 'SHERIFF1', { name = 'sheriff', grade = { level = 1 } }, { firstname = 'Sam', lastname = 'Deputy' })

    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 3, 'the caller themselves is a real connected player too, and must appear like anyone else')
    t.isFalse(result.truncated)

    local bySource = {}
    for _, row in ipairs(result.rows) do bySource[row.source] = row end

    t.equals(bySource[1].name, 'Chief Hopps')
    t.equals(bySource[1].jobLabel, 'Los Santos Police Department')
    t.isFalse(bySource[1].hasK9Access)
    t.isNil(bySource[1].citizenid, 'NEVER a citizenid on this response -- only source/name/jobLabel/hasK9Access/nonce (owner\'s own "nothing about the real person" bound)')

    t.equals(bySource[2].name, 'Rex Shepherd')
    t.isTrue(bySource[2].hasK9Access)

    t.equals(bySource[3].jobLabel, 'Blaine County Sheriff')

    t.isNotNil(bySource[1].nonce)
    t.equals(type(bySource[1].nonce), 'string')
end)

t.test('tabletRequestOnlinePlayers: an explicit k9.audit grant (not high command) also qualifies -- the SAME non-high-command path tabletRequestRoster already admits', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'AUDITOR1', { name = 'police', grade = { level = 1 } })
    f.addPermRow('AUDITOR1', 'k9.audit', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isTrue(result.ok)
end)

t.test('tabletRequestOnlinePlayers: the free-text query matches by name, by server id, and by job, case-insensitively', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(42, 'K9-1', { name = 'police', grade = { level = 1 } }, { firstname = 'Rex', lastname = 'Shepherd' })
    f.registerPlayer(7, 'SHERIFF1', { name = 'sheriff', grade = { level = 1 } }, { firstname = 'Sam', lastname = 'Deputy' })

    local byName = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, 'rex')
    t.equals(#byName.rows, 1)
    t.equals(byName.rows[1].source, 42)

    f.fakeNow.value = f.fakeNow.value + 501 -- past the shared read cooldown -- each call below is a SEPARATE request from the same source
    local byId = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '42')
    t.equals(#byId.rows, 1)
    t.equals(byId.rows[1].source, 42)

    f.fakeNow.value = f.fakeNow.value + 501
    local byJob = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, 'sheriff')
    t.equals(#byJob.rows, 1)
    t.equals(byJob.rows[1].source, 7)
end)

t.test('ONLINE PLAYERS CLAMP: more connected players than the row cap truncates and reports a real truncatedMessage', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    for i = 1, 105 do
        f.registerPlayer(i + 1, ('ONLINE%03d'):format(i), { name = 'police', grade = { level = 1 } })
    end
    local result = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isTrue(result.ok)
    t.equals(#result.rows, 100, 'a fixed, generous cap -- never "however many happen to be connected"')
    t.isTrue(result.truncated)
    t.isNotNil(result.truncatedMessage)
end)

t.test('tabletRequestOnlinePlayers: each call mints a FRESH nonce per row -- never reused across separate list builds', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } })

    local first = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    f.fakeNow.value = f.fakeNow.value + 501 -- past the shared read cooldown
    local second = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')

    local firstNonce, secondNonce
    for _, row in ipairs(first.rows) do if row.source == 2 then firstNonce = row.nonce end end
    for _, row in ipairs(second.rows) do if row.source == 2 then secondNonce = row.nonce end end
    t.isNotNil(firstNonce)
    t.isNotNil(secondNonce)
    t.isFalse(firstNonce == secondNonce, 'two separate list builds for the SAME row must never share a nonce')
end)

t.test('tabletResolveOnlinePlayer: SECURITY -- a caller with no console access is denied, regardless of the nonce/source given', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 999, 'garbage-nonce')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletResolveOnlinePlayer: a freshly-minted nonce resolves to the correct citizenid and name', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } }, { firstname = 'Rex', lastname = 'Shepherd' })

    local list = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    local nonce
    for _, row in ipairs(list.rows) do if row.source == 2 then nonce = row.nonce end end
    t.isNotNil(nonce)

    f.fakeNow.value = f.fakeNow.value + 501
    local result = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, nonce)
    t.isTrue(result.ok)
    t.equals(result.citizenid, 'K9-1')
    t.equals(result.name, 'Rex Shepherd')
end)

t.test('tabletResolveOnlinePlayer: an unknown/garbage nonce fails cleanly with stale_online_list, never a guessed citizenid', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, 'this-nonce-was-never-minted')
    t.isFalse(result.ok)
    t.equals(result.error, 'stale_online_list')
    t.isNil(result.citizenid)
end)

t.test('tabletResolveOnlinePlayer: invalid_args for a missing/malformed source or nonce, before any nonce lookup', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, nil, 'x').error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 'not-a-number', 'x').error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, nil).error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, '').error, 'invalid_args')
end)

t.test('tabletResolveOnlinePlayer: a nonce is SINGLE-USE -- resolving the same one twice fails the second time', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } })

    local list = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    local nonce
    for _, row in ipairs(list.rows) do if row.source == 2 then nonce = row.nonce end end

    f.fakeNow.value = f.fakeNow.value + 501
    local firstResolve = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, nonce)
    t.isTrue(firstResolve.ok)

    f.fakeNow.value = f.fakeNow.value + 501
    local secondResolve = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, nonce)
    t.isFalse(secondResolve.ok, 'a nonce already consumed must never resolve again -- replay protection, not just a one-time convenience')
    t.equals(secondResolve.error, 'stale_online_list')
end)

t.test('tabletResolveOnlinePlayer: a nonce past its TTL fails with stale_online_list, even though the same player never moved', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } })

    local list = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    local nonce
    for _, row in ipairs(list.rows) do if row.source == 2 then nonce = row.nonce end end

    f.fakeNow.value = f.fakeNow.value + 60001 -- past ONLINE_PLAYER_NONCE_TTL_MS
    local result = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, nonce)
    t.isFalse(result.ok)
    t.equals(result.error, 'stale_online_list')
end)

-- ============================================================================
-- THE PART THAT MATTERS MOST (owner's own words) -- RECYCLED SOURCE IDS.
-- A server id is freed the instant its holder disconnects and can be handed
-- to a brand-new connection seconds later. These two tests prove
-- tabletResolveOnlinePlayer never lets a stale click land on whoever now
-- happens to occupy that same slot.
-- ============================================================================

t.test('RECYCLED SOURCE ID: the original occupant disconnects and a DIFFERENT player connects at the SAME source before the click -- resolve fails, and NEVER returns the new occupant\'s citizenid', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(5, 'ORIGINAL-PERSON', { name = 'police', grade = { level = 1 } })

    local list = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    local nonce
    for _, row in ipairs(list.rows) do if row.source == 5 then nonce = row.nonce end end
    t.isNotNil(nonce)

    -- ORIGINAL-PERSON disconnects; a completely different citizenid is
    -- handed the exact same freed server id, 5, before the operator's
    -- already-drawn list is clicked.
    f.dropPlayer(5)
    f.registerPlayer(5, 'RECYCLED-IMPOSTER', { name = 'police', grade = { level = 1 } })

    f.fakeNow.value = f.fakeNow.value + 501
    local result = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 5, nonce)

    t.isFalse(result.ok, 'must refuse, never silently succeed against whoever is there now')
    t.equals(result.error, 'target_disconnected')
    t.isNil(result.citizenid, 'LOAD-BEARING: this must never be RECYCLED-IMPOSTER -- that would be a permission grant landing on the wrong person')
    t.isTrue(result.citizenid ~= 'RECYCLED-IMPOSTER')
end)

t.test('RECYCLED SOURCE ID: the original occupant simply disconnects with nobody replacing them -- resolve fails cleanly, not a crash or a guess', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(5, 'ORIGINAL-PERSON', { name = 'police', grade = { level = 1 } })

    local list = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    local nonce
    for _, row in ipairs(list.rows) do if row.source == 5 then nonce = row.nonce end end

    f.dropPlayer(5) -- nobody takes source 5 afterward

    f.fakeNow.value = f.fakeNow.value + 501
    local result = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 5, nonce)
    t.isFalse(result.ok)
    t.equals(result.error, 'target_disconnected')
    t.isNotNil(result.message, 'a plain, visible explanation, not a bare error code')
end)

t.test('RATE LIMIT: applies to tabletRequestOnlinePlayers too -- a second rapid call from the same console-access source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '').ok)
    local second = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: applies to tabletResolveOnlinePlayer too, and shares the SAME budget as tabletRequestOnlinePlayers', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'K9-1', { name = 'police', grade = { level = 1 } })

    local list = cb(f, 'john-k9:server:tabletRequestOnlinePlayers')(src, '')
    local nonce
    for _, row in ipairs(list.rows) do if row.source == 2 then nonce = row.nonce end end

    -- Immediately after the list call above, still within the same 500ms
    -- window -- the resolve call must be rejected by the SAME shared
    -- budget, never its own independent allowance.
    local resolveAttempt = cb(f, 'john-k9:server:tabletResolveOnlinePlayer')(src, 2, nonce)
    t.isFalse(resolveAttempt.ok)
    t.equals(resolveAttempt.error, 'rate_limited')
end)

-- ============================================================================
-- tabletRequestPersonSummary
-- ============================================================================

t.test('tabletRequestPersonSummary: SECURITY -- console access is denied for a non-qualifying caller regardless of the target argument', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'NOBODY') -- even targeting themselves
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

-- ============================================================================
-- WORKFLOW AUDIT FINDING #1, 2026-08-26 -- CallerHasPersonAccess():
-- tabletRequestPersonSummary specifically (NOT tabletRequestRoster, which
-- keeps CallerHasConsoleAccess exactly as it was) now also admits a caller
-- holding an explicit 'k9.certify' or 'k9.givexp' grant alone -- neither is
-- high command, neither holds 'k9.audit', and grade level 1 is below this
-- fixture's own certifierGrade/auditGrade thresholds (4) for 'police', so
-- neither qualifies via rank either. Before this pass, a delegated
-- certifier/XP-granter had a real, server-granted capability and no
-- reachable screen to use it from at all (html/tablet.js's own
-- buildPersonScreen() already gated Certify/Give XP on exactly these two
-- capabilities -- the screen itself was simply unreachable).
-- ============================================================================

t.test('tabletRequestPersonSummary: WIDENED -- a caller holding ONLY an explicit k9.certify grant (no rank, no k9.audit, not high command) is now admitted', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CERTIFIER', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CERTIFIER', 'k9.certify', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'SOMEONE-ELSE')
    t.isTrue(result.ok, 'a bare k9.certify grant is enough to open a specific person\'s record')
end)

t.test('tabletRequestPersonSummary: WIDENED -- a caller holding ONLY an explicit k9.givexp grant (no rank, no k9.audit, not high command) is now admitted', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'GRANTER', { name = 'police', grade = { level = 1 } })
    f.addPermRow('GRANTER', 'k9.givexp', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'SOMEONE-ELSE')
    t.isTrue(result.ok, 'a bare k9.givexp grant is enough to open a specific person\'s record')
end)

t.test('tabletRequestPersonSummary: a bare k9.access grant alone still does NOT qualify -- the widening is specifically k9.certify/k9.givexp, not "any permission"', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'HANDLER', { name = 'police', grade = { level = 1 } })
    f.addPermRow('HANDLER', 'k9.access', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'SOMEONE-ELSE')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestRoster: SECURITY -- UNTOUCHED by the widening above -- a caller holding ONLY k9.certify (no k9.audit, not high command) is still denied the full roster', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CERTIFIER2', { name = 'police', grade = { level = 1 } })
    f.addPermRow('CERTIFIER2', 'k9.certify', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isFalse(result.ok, 'browsing/searching the full roster still needs k9.audit or high command -- see CallerHasConsoleAccess\'s own OWNER\'S DECISION comment, deliberately untouched')
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestRoster: SECURITY -- UNTOUCHED by the widening above -- a caller holding ONLY k9.givexp (no k9.audit, not high command) is still denied the full roster', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'GRANTER2', { name = 'police', grade = { level = 1 } })
    f.addPermRow('GRANTER2', 'k9.givexp', 'HC', true)
    local result = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestPersonSummary: invalid_args for a non-string / empty target citizenid', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, '').error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, nil).error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 123).error, 'invalid_args')
end)

t.test('tabletRequestPersonSummary: works for a genuinely OFFLINE target citizenid', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9', 'police', 'HC1', true)
    f.addPermRow('OFFLINE-K9', 'k9.access', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    t.equals(result.target.citizenid, 'OFFLINE-K9')
    t.equals(result.target.name, 'OFFLINE-K9', 'an offline citizenid with no verified name source falls back to the citizenid itself')
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.access' then found = true end end
    t.isTrue(found)
end)

t.test('tabletRequestPersonSummary: an OFFLINE target resolves a real name via qbx_core:GetOfflinePlayer, not the citizenid fallback', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9-2', 'police', 'HC1', true)
    f.registerOfflinePlayer('OFFLINE-K9-2', { firstname = 'Rex', lastname = 'Handler' })

    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9-2')
    t.isTrue(result.ok)
    t.equals(result.target.name, 'Rex Handler', 'GetOfflinePlayer charinfo must resolve a real name for an offline target')
end)

t.test('tabletRequestPersonSummary: certifications array carries grantedByName resolved via ResolveDisplayName, including for an OFFLINE granter', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerOfflinePlayer('GRANTER3', { firstname = 'Old', lastname = 'Sergeant' })
    f.addCertRow('TARGET1', 'police', 'GRANTER3', true)

    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.equals(byDept.police.grantedBy, 'GRANTER3', 'the raw citizenid must never be replaced by the name')
    t.equals(byDept.police.grantedByName, 'Old Sergeant')
end)

t.test('tabletRequestPersonSummary: qbx_core WITHOUT a GetOfflinePlayer export still falls back to the citizenid safely (soft-guarded)', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9-3', 'police', 'HC1', true)
    f.env.exports.qbx_core.GetOfflinePlayer = nil -- simulate an older qbx_core without this export

    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9-3')
    t.isTrue(result.ok)
    t.equals(result.target.name, 'OFFLINE-K9-3', 'a missing GetOfflinePlayer export must not error -- must degrade to the citizenid fallback')
end)

t.test('tabletRequestPersonSummary: certifications array carries tier/expiry/specializations for a genuinely OFFLINE target', function()
    -- The whole point of QueryCertificationRecord being DB-authoritative
    -- (not the online-only in-memory cert cache) is that a high-command
    -- lookup on a disconnected handler must still show their tier -- this
    -- is the read-side gap the owner's task named explicitly.
    local f = newFixture({
        isHighCommand = function() return true end,
        queryCertificationRecord = function(citizenid, jobName)
            if citizenid == 'OFFLINE-K9' and jobName == 'police' then
                return { tier = 'trainee', expiresAtUnix = nil, specializations = { 'patrol' } }
            end
            return nil
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9', 'police', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    local byDept = {}
    for _, row in ipairs(result.certifications) do byDept[row.departmentKey] = row end
    t.equals(byDept.police.tier, 'trainee')
    t.equals(#byDept.police.specializations, 1)
    t.equals(byDept.police.specializations[1], 'patrol')
end)

-- ============================================================================
-- PERMISSION-KEY CATALOG AWARENESS (this pass) -- tabletRequestPersonSummary's
-- own inline `permissions` builder has the SAME bug/fix as
-- ResolveEffectivePermissions above: it must consult the live catalog, or a
-- custom key's Grant/Revoke row on the tablet's person screen reads "not
-- held" forever even after a real grant. See
-- server/tablet.lua's own AdminCapabilityCandidateKeys for the shared
-- contract these mirror.
-- ============================================================================

t.test('tabletRequestPersonSummary: permissions -- a custom, non-default GRANTED key shows as held', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.specialaudit' then found = true end end
    t.isTrue(found, 'a granted custom key must appear in the person-summary permissions array -- this is the exact bug this pass closes')
end)

t.test('tabletRequestPersonSummary: permissions -- a custom, non-default UNGRANTED key does NOT show as held', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    -- TARGET1 exists (implicitly, offline) but never received a grant.
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    for _, key in ipairs(result.permissions) do
        t.isFalse(key == 'k9.specialaudit', 'an ungranted custom key must never read as held')
    end
end)

t.test('tabletRequestPersonSummary: permissions -- a TOMBSTONED-but-held custom key still appears (so it remains revocable)', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        -- 'k9.specialaudit' is no longer in the live catalog at all --
        -- exactly what a tombstoned key looks like.
        listPermissionCatalogKeys = function()
            return { { key = 'k9.access', label = 'x' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true) -- still an ACTIVE grant, despite the tombstone
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.specialaudit' then found = true end end
    t.isTrue(found, 'a tombstoned key someone still actively holds must still surface, or high command could never revoke it from this screen')
end)

t.test('tabletRequestPersonSummary: permissions -- the four shipped keys resolve unchanged when the catalog is present', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return {
                { key = 'k9.access', label = 'x' }, { key = 'k9.certify', label = 'x' },
                { key = 'k9.audit', label = 'x' }, { key = 'k9.givexp', label = 'x' },
            }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.access', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.equals(#result.permissions, 1)
    t.equals(result.permissions[1], 'k9.access')
end)

t.test('tabletRequestPersonSummary: permissions -- a THROWING catalog degrades to the four shipped keys, never an empty capability panel', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function() error('simulated catalog failure') end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'k9.access', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    local found = false
    for _, key in ipairs(result.permissions) do if key == 'k9.access' then found = true end end
    t.isTrue(found, 'a catalog read failure must never empty this response -- an empty capability panel reads as "no permissions", which is false and alarming')
end)

t.test('tabletRequestPersonSummary: permissions -- never leaks a feature./block. per-feature grant disguised as an admin capability', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'feature.BiteAndHold', 'HC1', true)
    f.addPermRow('TARGET1', 'block.NightVision', 'HC1', true)
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.equals(#result.permissions, 1, 'only the genuine admin-capability grant may appear here')
    t.equals(result.permissions[1], 'k9.specialaudit')
end)

t.test('tabletRequestPersonSummary: SECURITY -- an unauthorized caller gets nothing, even when the target holds a custom granted key', function()
    local f = newFixture({
        listPermissionCatalogKeys = function()
            return { { key = 'k9.specialaudit', label = 'Special Audit' } }
        end,
    })
    local src = f.registerPlayer(1, 'NOBODY', { name = 'police', grade = { level = 1 } }) -- no console access
    f.addPermRow('TARGET1', 'k9.specialaudit', 'HC1', true)
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isNil(result.permissions, 'a denied caller must receive no permissions data at all, custom key or not')
end)

-- ============================================================================
-- tabletRequestPersonSummary: job/rank + partnership READ-ONLY fields
-- (owner-directed "roster panel should show everything about a person" pass
-- -- cert+tier, rank, XP+tier, partnership, permissions, all from one
-- screen). See ResolveJobGradeInfo/ResolvePartnershipInfo's own doc
-- comments in server/tablet.lua for exactly what each does and does not do
-- -- in particular, NO promotion/rank-change control exists anywhere in
-- this resource; these fields are read-only, and html/tablet.js renders no
-- control for them at all (never a disabled button implying a capability
-- that is not actually there).
-- ============================================================================

t.test('tabletRequestPersonSummary: job -- resolves department label + grade name/level for an ONLINE target', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'TARGET1', { name = 'police', isboss = false, grade = { level = 4, name = 'Sergeant' } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.isNotNil(result.job)
    t.equals(result.job.departmentLabel, 'Los Santos Police Department', 'must prefer Config.Departments[job.name].label over a raw job name')
    t.equals(result.job.gradeLabel, 'Sergeant')
    t.equals(result.job.gradeLevel, 4)
    t.isFalse(result.job.isBoss)
end)

t.test('tabletRequestPersonSummary: job -- resolves via qbx_core:GetOfflinePlayer for an OFFLINE target, matching ResolveDisplayName\'s own online/offline split', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.env.exports.qbx_core.GetOfflinePlayer = function(_self, citizenid)
        if citizenid ~= 'OFFLINE-TARGET' then return nil end
        return { PlayerData = { citizenid = citizenid, job = { name = 'sheriff', isboss = true, grade = { level = 5, name = 'Sheriff' } } } }
    end
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-TARGET')
    t.isTrue(result.ok)
    t.isNotNil(result.job)
    t.equals(result.job.departmentLabel, 'Blaine County Sheriff')
    t.equals(result.job.gradeLabel, 'Sheriff')
    t.equals(result.job.gradeLevel, 5)
    t.isTrue(result.job.isBoss)
end)

t.test('tabletRequestPersonSummary: job -- nil (never guessed) when neither an online nor an offline PlayerData resolves at all', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'NEVER-SEEN')
    t.isTrue(result.ok)
    t.isNil(result.job)
end)

-- ============================================================================
-- tabletRequestPersonSummary: target.exists (this pass, coder-backend, at
-- coder-ui's own request -- see server/tablet.lua's ResolvePlayerExists own
-- doc comment). THE REAL FIX for the "no way to tell a real person from a
-- typo" gap: previously this callback returned `ok = true` for ANY
-- syntactically valid citizenid, with nothing distinguishing a genuine
-- handler who holds zero certs/XP/partnership from a typo'd or
-- deleted-character id. `exists` is a REAL qbx_core player-row lookup
-- (online OR offline), never inferred from any other field being empty.
-- ============================================================================

t.test('tabletRequestPersonSummary: target.exists -- true for an ONLINE target', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'ONLINE-TARGET', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'ONLINE-TARGET')
    t.isTrue(result.ok)
    t.isNotNil(result.target)
    t.isTrue(result.target.exists)
end)

t.test('tabletRequestPersonSummary: target.exists -- true for a genuinely OFFLINE target with a real qbx_core row', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerOfflinePlayer('OFFLINE-TARGET', { firstname = 'Rex', lastname = 'Handler' })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-TARGET')
    t.isTrue(result.ok)
    t.isTrue(result.target.exists)
end)

t.test('tabletRequestPersonSummary: target.exists -- FALSE for a citizenid with no player row at all, online or offline (the typo/ghost case)', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TYPO-OR-DELETED')
    t.isTrue(result.ok)
    t.isFalse(result.target.exists, 'a citizenid qbx_core has never heard of must resolve exists = false, never true, and never merely absent')
end)

t.test('tabletRequestPersonSummary: target.exists -- true for a REAL person who genuinely holds zero certs/XP/partnership (the case the frontend heuristic used to misclassify)', function()
    -- This is the exact scenario the old, client-only "everything is empty"
    -- heuristic could not distinguish from a typo: a real, existing handler
    -- with a resolvable job but nothing else on record yet.
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'BRAND-NEW-HANDLER', { name = 'police', grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'BRAND-NEW-HANDLER')
    t.isTrue(result.ok)
    t.isTrue(result.target.exists)
    t.equals(#result.certifications > 0, true, 'sanity: still one row per configured department, but every one inactive')
end)

t.test('tabletRequestPersonSummary: partnership -- nil when Config.Features.HandlerPartnership is off', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.isNil(result.partnership)
end)

t.test('tabletRequestPersonSummary: partnership -- resolves the active partner + role from the real k9_partnerships store for BOTH parties, DB-authoritative not the online-only cache', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, HandlerPartnership = true },
            Departments = {}, Permissions = {}, FeatureControl = {}, CommandTablet = {},
            Database = { enabled = false }, -- real K9Store in-memory mode, no MySQL stub needed
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.env.K9Store.Partner_Insert('K9-CIT', 'HANDLER-CIT', 'HC1')

    local k9Side = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'K9-CIT')
    t.isTrue(k9Side.ok)
    t.isNotNil(k9Side.partnership)
    t.equals(k9Side.partnership.partnerCitizenid, 'HANDLER-CIT')
    t.equals(k9Side.partnership.role, 'k9')

    f.fakeNow.value = f.fakeNow.value + 1000 -- past TabletReadCooldown -- these are two separate reads from the same source, not a batch
    local handlerSide = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'HANDLER-CIT')
    t.isTrue(handlerSide.ok)
    t.isNotNil(handlerSide.partnership)
    t.equals(handlerSide.partnership.partnerCitizenid, 'K9-CIT')
    t.equals(handlerSide.partnership.role, 'handler')
end)

-- ============================================================================
-- tabletRequestPersonSummary: assignedK9Model -- the re-derivation field the
-- Onboarding flow's K9 Role step's own summary reads instead of trusting a
-- tablet:assignK9Role click's own `ok:true` (see server/tablet.lua's own
-- doc comment on this field, right above where it is added to the
-- response).
-- ============================================================================

t.test('tabletRequestPersonSummary: assignedK9Model -- nil when server/appearance.lua\'s GetAssignedK9Model is not loaded (soft-dependency degrade, never an error)', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.isNil(result.assignedK9Model)
end)

t.test('tabletRequestPersonSummary: assignedK9Model -- forwards GetAssignedK9Model(targetCitizenId)\'s own string verbatim when a K9 model is actively assigned', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        getAssignedK9Model = function(citizenid) return citizenid == 'TARGET1' and 'a_c_shepherd' or nil end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.equals(result.assignedK9Model, 'a_c_shepherd')
end)

t.test('tabletRequestPersonSummary: assignedK9Model -- nil for a DIFFERENT citizenid GetAssignedK9Model does not recognize as currently assigned, never guessed from the caller\'s own', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        getAssignedK9Model = function(citizenid) return citizenid == 'SOMEONE-ELSE' and 'a_c_shepherd' or nil end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isTrue(result.ok)
    t.isNil(result.assignedK9Model)
end)

t.test('tabletRequestPersonSummary: assignedK9Model -- resolves for a genuinely OFFLINE target too (never online-registered in this fixture at all), matching every other DB-authoritative field in this response', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        getAssignedK9Model = function(citizenid) return citizenid == 'OFFLINE-K9' and 'a_c_husky' or nil end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    t.equals(result.assignedK9Model, 'a_c_husky')
end)

-- ============================================================================
-- tabletRequestPersonFeatures -- HIGH COMMAND ONLY (load-bearing).
-- ============================================================================

t.test('tabletRequestPersonFeatures: LOAD-BEARING -- a non-high-command caller is denied, even one with full console access via a rank/grant', function()
    local f = newFixture({
        hasPermission = function(citizenid, key) return citizenid == 'CERTIFIER' and key == 'k9.certify' end,
    })
    local src = f.registerPlayer(1, 'CERTIFIER', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'SOMEONE')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
end)

t.test('tabletRequestPersonFeatures: invalid_args for a malformed target', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, '').error, 'invalid_args')
end)

t.test('tabletRequestPersonFeatures: an OFFLINE target with an active certification resolves not_certified == false (available, if unblocked/no-grant-needed)', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = { ['k9.access'] = { label = 'x' } },
            FeatureControl = { RequireGrant = {} },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addCertRow('OFFLINE-K9', 'police', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'OFFLINE-K9')
    t.isTrue(result.ok)
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.isNotNil(row)
    t.equals(row.state, 'available', 'an offline target with a real active certification must resolve K9 access from the DB, never as unknowable')
end)

t.test('tabletRequestPersonFeatures: an OFFLINE target with NO credential at all resolves not_certified', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = { police = { label = 'PD', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 } },
            Permissions = { ['k9.access'] = { label = 'x' } },
            FeatureControl = { RequireGrant = {} },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })

    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'NEVER-CERTIFIED')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'not_certified')
end)

t.test('tabletRequestPersonFeatures: an ONLINE target reuses the real, live HasK9Access(source) for that target', function()
    local f = newFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function(source) return source == 2 end, -- only the ONLINE target's own source qualifies
        config = {
            Features = { CommandTablet = true, LeashMechanics = true },
            Departments = {}, Permissions = {}, FeatureControl = { RequireGrant = {} }, CommandTablet = {},
        },
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.registerPlayer(2, 'ONLINE-TARGET', { name = 'police', grade = { level = 1 } })

    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(hcSrc, 'ONLINE-TARGET')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'LeashMechanics' then row = entry end end
    t.equals(row.state, 'available')
end)

t.test('tabletRequestPersonFeatures: globallyEnabled/requiresGrant/granted/blocked fields are all reported per-row', function()
    local f = newFixture({
        isHighCommand = function() return true end,
        config = {
            Features = { CommandTablet = true, BiteAndHold = true },
            Departments = {}, Permissions = {},
            FeatureControl = { RequireGrant = { BiteAndHold = true } },
            CommandTablet = {},
        },
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    f.addPermRow('TARGET1', 'block.BiteAndHold', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'TARGET1')
    local row
    for _, entry in ipairs(result.features) do if entry.key == 'BiteAndHold' then row = entry end end
    t.isTrue(row.globallyEnabled)
    t.isTrue(row.requiresGrant)
    t.isFalse(row.granted)
    t.isTrue(row.blocked)
    t.equals(row.state, 'blocked')
end)

-- ============================================================================
-- RATE LIMITING (this pass) -- the four read/aggregation callbacks above had
-- NO cooldown at all, unlike every other client-triggered, DB-touching read
-- this resource exposes (server/admin.lua's own AuditCooldown covers its
-- read-only audit callbacks the same way). Shared TabletReadCooldown, keyed
-- by source, 500ms floor -- see server/tablet.lua's own header comment on
-- TABLET_READ_COOLDOWN_MS for the full reasoning.
-- ============================================================================

t.test('RATE LIMIT: a second rapid tabletRequestMyRecord from the SAME source is rejected as rate_limited', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local first = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(first.ok)
    local second = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: tabletRequestMyRecord recovers once the cooldown window elapses', function()
    local f = newFixture()
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestMyRecord')(src).ok)
    f.fakeNow.value = f.fakeNow.value + 501
    local third = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.isTrue(third.ok, 'must succeed again once the 500ms floor has elapsed')
end)

t.test('RATE LIMIT: is PER SOURCE -- a different source is unaffected by another source\'s cooldown entry', function()
    local f = newFixture()
    local src1 = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local src2 = f.registerPlayer(2, 'CIT2', { name = 'police', grade = { level = 1 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestMyRecord')(src1).ok)
    local other = cb(f, 'john-k9:server:tabletRequestMyRecord')(src2)
    t.isTrue(other.ok, 'a fresh source must never be blocked by a DIFFERENT source\'s own cooldown entry')
end)

t.test('RATE LIMIT: an UNAUTHORIZED caller never spends the shared cooldown budget -- denial always returns before Consume', function()
    local f = newFixture({ config = { Features = { CommandTablet = true }, FeatureControl = { everyoneCanViewOwnRecord = false } } })
    local src = f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    local denied = cb(f, 'john-k9:server:tabletRequestMyRecord')(src)
    t.equals(denied.error, 'not_authorized')
    -- The SAME source, now authorized, must not find itself already
    -- rate_limited from the denied attempt above.
    local f2 = newFixture()
    local authorizedSrc = f2.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    t.isTrue(cb(f2, 'john-k9:server:tabletRequestMyRecord')(authorizedSrc).ok)
end)

t.test('RATE LIMIT: applies to tabletRequestRoster too -- a second rapid call from the same console-access source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestRoster')(src, '').ok)
    local second = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: SHARED across all four read callbacks -- one budget per source, not one independent allowance per callback', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestMyRecord')(src).ok, 'first call, own budget, must succeed')
    local rosterAttempt = cb(f, 'john-k9:server:tabletRequestRoster')(src, '')
    t.isFalse(rosterAttempt.ok, 'a DIFFERENT callback from the SAME source, immediately after, must still be rejected -- one shared budget, not a per-callback allowance')
    t.equals(rosterAttempt.error, 'rate_limited')
    f.fakeNow.value = f.fakeNow.value + 501
    t.isTrue(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1').ok, 'a third, different callback recovers once the shared window elapses')
end)

t.test('RATE LIMIT: applies to tabletRequestPersonSummary -- second rapid call from the same console-access source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1').ok)
    local second = cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: applies to tabletRequestPersonFeatures -- second rapid call from the same high-command source is rejected', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'TARGET1').ok)
    local second = cb(f, 'john-k9:server:tabletRequestPersonFeatures')(src, 'TARGET1')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
end)

t.test('RATE LIMIT: invalid_args on tabletRequestPersonSummary/PersonFeatures never consumes the shared budget -- three malformed-target calls in a row all report invalid_args, never rate_limited', function()
    local f = newFixture({ isHighCommand = function() return true end })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, '').error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, nil).error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 123).error, 'invalid_args')
    -- A real request from the SAME source must still succeed afterward --
    -- none of the three invalid_args calls above may have silently spent
    -- the cooldown budget this real request now needs.
    t.isTrue(cb(f, 'john-k9:server:tabletRequestPersonSummary')(src, 'TARGET1').ok)
end)

-- ============================================================================
-- tabletAssignK9Role -- thin wrapper over server/appearance.lua's
-- ApplyK9PedRole. Authorization is ApplyK9PedRole's OWN job (already
-- covered by that file's own test suite) -- these tests only prove the
-- wrapper forwards correctly and degrades gracefully when the primitive
-- is absent.
-- ============================================================================

t.test('tabletAssignK9Role: invalid_args for a missing/empty citizenid or model', function()
    local f = newFixture({ applyK9PedRole = function() return true, 'ok' end })
    t.equals(cb(f, 'john-k9:server:tabletAssignK9Role')(1, '', 'a_c_shepherd').error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletAssignK9Role')(1, 'CIT1', '').error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletAssignK9Role')(1, 'CIT1', nil).error, 'invalid_args')
end)

t.test('tabletAssignK9Role: not_available when server/appearance.lua is not loaded', function()
    local f = newFixture() -- no applyK9PedRole stub -- type(fn) == 'function' guard must trip
    local result = cb(f, 'john-k9:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
end)

t.test('tabletAssignK9Role: forwards ApplyK9PedRole success verbatim', function()
    local calls = {}
    local f = newFixture({ applyK9PedRole = function(granterSrc, citizenid, model)
        calls[#calls + 1] = { granterSrc = granterSrc, citizenid = citizenid, model = model }
        return true, 'ok'
    end })
    local result = cb(f, 'john-k9:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isTrue(result.ok)
    t.equals(#calls, 1)
    t.equals(calls[1].granterSrc, 1)
    t.equals(calls[1].citizenid, 'CIT1')
    t.equals(calls[1].model, 'a_c_shepherd')
end)

t.test('tabletAssignK9Role: forwards ApplyK9PedRole failure outcome (e.g. denied -- caller was not high command) verbatim', function()
    local f = newFixture({ applyK9PedRole = function() return false, 'denied' end })
    local result = cb(f, 'john-k9:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
end)

t.test('tabletAssignK9Role: a persisted_offline success is translated with a real, existing locale message', function()
    local f = newFixture({ applyK9PedRole = function() return true, 'persisted_offline' end })
    local result = cb(f, 'john-k9:server:tabletAssignK9Role')(1, 'CIT1', 'a_c_shepherd')
    t.isTrue(result.ok)
    t.isNotNil(result.message)
end)

-- ============================================================================
-- DOG-CHARACTER PIN (tabletPinDogCharacter / tabletUnpinDogCharacter) --
-- the tablet replacement for /k9setdog, /k9removedog and /k9dog.
-- SetDogCharacter/RemoveDogCharacter check high command themselves; the
-- callbacks validate arguments and translate 'denied' into not_authorized.
-- ============================================================================

t.test('tabletPinDogCharacter: forwards caller, target and breed to SetDogCharacter and reports ok', function()
    local calls = {}
    local f = newFixture()
    f.env.SetDogCharacter = function(granterSrc, cid, model) calls[#calls + 1] = { granterSrc, cid, model }; return true, 'applied' end
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletPinDogCharacter')(src, 'DOG1', 'a_c_husky')
    t.isTrue(result.ok)
    t.equals(#calls, 1)
    t.equals(calls[1][1], src)
    t.equals(calls[1][2], 'DOG1')
    t.equals(calls[1][3], 'a_c_husky')
end)

t.test('tabletPinDogCharacter: a non-high-command caller is refused as not_authorized; missing arguments are refused before anything runs', function()
    local called = 0
    local f = newFixture()
    f.env.SetDogCharacter = function() called = called + 1; return false, 'denied' end
    local src = f.registerPlayer(1, 'NOTHC', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletPinDogCharacter')(src, 'DOG1', 'a_c_husky')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.equals(cb(f, 'john-k9:server:tabletPinDogCharacter')(src, 'DOG1', nil).error, 'invalid_args')
    t.equals(cb(f, 'john-k9:server:tabletPinDogCharacter')(src, '', 'a_c_husky').error, 'invalid_args')
    t.equals(called, 1, 'invalid arguments never reach SetDogCharacter')
end)

t.test('tabletUnpinDogCharacter: forwards to RemoveDogCharacter and passes its outcome through', function()
    local f = newFixture()
    f.env.RemoveDogCharacter = function(_, cid) if cid == 'DOG1' then return true, 'ok' end return false, 'not_a_dog_character' end
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(cb(f, 'john-k9:server:tabletUnpinDogCharacter')(src, 'DOG1').ok)
    t.equals(cb(f, 'john-k9:server:tabletUnpinDogCharacter')(src, 'HUMAN2').error, 'not_a_dog_character')
end)

-- ============================================================================
-- tabletRevertK9Ped -- THE NO-UNBOUNDED-TRAP action. Unlike tabletAssignK9Role,
-- THIS file's own callback checks IsHighCommand itself (ForceRevertK9Appearance
-- is requested, not yet a self-authorizing function at the time of writing)
-- -- see server/tablet.lua's own header for why.
-- ============================================================================

t.test('tabletRevertK9Ped: LOAD-BEARING -- a non-high-command caller is denied server-side, the underlying revert is never invoked', function()
    local invoked = false
    local f = newFixture({ forceRevertK9Appearance = function() invoked = true; return true, 'ok' end })
    local src = f.registerPlayer(1, 'NOTHC', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletRevertK9Ped')(src, 'TARGET1')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isFalse(invoked, 'a denied caller must never reach the actual revert primitive')
end)

t.test('tabletRevertK9Ped: not_available when the underlying primitive is not yet loaded (disclosed, temporary state)', function()
    local f = newFixture({ isHighCommand = function() return true end }) -- no forceRevertK9Appearance stub
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local result = cb(f, 'john-k9:server:tabletRevertK9Ped')(src, 'TARGET1')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
end)

t.test('tabletRevertK9Ped: a high-command caller reaches the underlying primitive and its result is forwarded, UNCONDITIONALLY of target credential state', function()
    -- This test's own point: the wrapper does NOT check HasK9Access/
    -- HasPermission/certification status on the TARGET at all before
    -- calling through -- see server/tablet.lua's own "NO UNBOUNDED TRAP"
    -- header note. If this test needed a HasK9Access stub to pass, that
    -- would itself be evidence of a reintroduced gate.
    local calls = {}
    local f = newFixture({
        isHighCommand = function() return true end,
        forceRevertK9Appearance = function(granterSrc, citizenid)
            calls[#calls + 1] = { granterSrc = granterSrc, citizenid = citizenid }
            return true, 'ok'
        end,
    })
    local src = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    -- STILL CERTIFIED on paper -- the revert must still go through.
    f.addCertRow('STILL-CERTIFIED-K9', 'police', 'HC1', true)
    f.addPermRow('STILL-CERTIFIED-K9', 'k9.access', 'HC1', true)

    local result = cb(f, 'john-k9:server:tabletRevertK9Ped')(src, 'STILL-CERTIFIED-K9')
    t.isTrue(result.ok)
    t.equals(#calls, 1)
    t.equals(calls[1].citizenid, 'STILL-CERTIFIED-K9')
end)

-- ============================================================================
-- ROUND TRIP -- REAL server/permissions.lua + REAL server/tablet.lua,
-- sharing one real in-memory k9_permissions table. See this file's own
-- header "ROUND TRIP SECTION" for why this is a separate, integration-level
-- fixture rather than an extension of newFixture() above.
-- ============================================================================

--- @param opts table? -- { isHighCommand, hasK9Access, config: table (full Config override) }
--- @return table fixture
local function newIntegrationFixture(opts)
    opts = opts or {}

    -- Advancing fake clock -- server/permissions.lua's PermissionActionCooldown
    -- (1500ms, shared by GrantPermission/RevokePermission) means a SECOND
    -- grant/revoke from the SAME granter source at the SAME instant is
    -- rate-limited; tests that issue more than one action from `hcSrc` call
    -- `advanceTime` between them, matching tests/permissions_spec.lua's own
    -- established convention for this exact cooldown.
    local clockState = { now = 0 }
    local function GetGameTimerStub() return clockState.now end

    -- ---- fake k9_permissions table -- same shape/dispatch as
    -- tests/permissions_spec.lua's own newFixture() mysql stub, since this
    -- fixture must satisfy the REAL GrantPermission/RefreshPermissionCache
    -- query shapes AND server/tablet.lua's own QueryActivePermissionSet
    -- query against the exact same rows.
    local rows = {}
    local nextId = 0

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
            local row = findActiveRow(params[1], params[2])
            return row and row.id or nil
        end },
        insert = { await = function(_sql, params)
            nextId = nextId + 1
            rows[#rows + 1] = {
                id = nextId, citizenid = params[1], permission = params[2], granted_by = params[3], active = 1,
            }
            return nextId
        end },
        update = { await = function(_sql, params)
            local citizenid, permission = params[2], params[3]
            local affected = 0
            for _, row in ipairs(rows) do
                if row.citizenid == citizenid and row.permission == permission and row.active == 1 then
                    row.active = 0
                    affected = affected + 1
                end
            end
            return affected
        end },
        query = { await = function(sql, params)
            local out = {}
            if sql:find('SELECT permission FROM k9_permissions', 1, true) then
                for _, row in ipairs(rows) do
                    if row.citizenid == params[1] and row.active == 1 then out[#out + 1] = { permission = row.permission } end
                end
            end
            return out
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

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local Config = opts.config or {
        Features = {
            CommandTablet = true,
            PermissionGrants = true,
            BiteAndHold = true,
        },
        Departments = {
            police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, highCommandGrade = 6 },
        },
        Permissions = {
            ['k9.access']  = { label = 'Use K9 abilities' },
            ['k9.certify'] = { label = 'Certify and decertify others' },
            ['k9.audit']   = { label = 'View the audit records' },
            ['k9.givexp']  = { label = 'Grant XP' },
        },
        FeatureControl = {
            RequireGrant = { BiteAndHold = true },
            everyoneCanViewOwnRecord = true,
        },
        CommandTablet = { maxRosterRows = 100 },
        HighCommand = { allowSelfGrant = false },
    }

    -- COULD-NOT-DETERMINE RESYNC SWEEP: server/permissions.lua (loaded into
    -- THIS env below) calls CreateThread(...) unconditionally at file-load
    -- time -- the resync sweep for PermissionCheckUnresolved, deliberately
    -- not feature-gated, see that file's own declaration comment. Any
    -- fixture loading server/permissions.lua must supply a REAL
    -- CreateThread/Wait pair: a no-op stub either throws (CreateThread
    -- undefined) or loops forever synchronously, because the sweep body is
    -- `while true do Wait(x) ... end`. Same wiring tests/permissions_spec.lua
    -- and tests/certifications_spec.lua already use for the same reason.
    local threadRunner = Sandbox.newThreadRunner()

    local env = Sandbox.newEnv({
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        Config = Config,
        MySQL = mysql,
        exports = exportsStub,
        lib = libStub,
        GetPlayerName = function(source) return 'SteamName#' .. tostring(source) end,
        print = function() end,
        IsHighCommand = opts.isHighCommand or function(_source) return false end,
        HasK9Access = opts.hasK9Access or function(_source) return false end,
        NotifyPlayer = function() end,
        AddEventHandler = function(_name, _fn) end,
        -- FEATURE-BLOCK PUSH (this pass) -- server/permissions.lua now
        -- registers 'john-k9:server:requestFeatureBlocksSync' via
        -- RegisterNetEvent unconditionally at file-load time, and calls
        -- TriggerClientEvent from GrantPermission/RevokePermission's own
        -- block.<Name> tail whenever the target below (TARGET1) is online
        -- -- both genuinely exercised by this fixture's own "ROUND TRIP...
        -- BLOCK" test further down. Neither is asserted on by name here
        -- (that contract has its own dedicated coverage in
        -- tests/permissions_spec.lua); these are just enough stub for
        -- server/permissions.lua's own load and normal grant/revoke calls
        -- to not crash this fixture with "attempt to call a nil value".
        RegisterNetEvent = function(_name, _fn) end,
        TriggerClientEvent = function(_eventName, _target, ...) end,
        GetPlayers = function() return {} end,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetGameTimer = GetGameTimerStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env) -- K9Store; server/permissions.lua reads and writes through it now rather than calling MySQL directly
    Sandbox.loadInto('../server/events.lua', env)    -- FireOutboundEvent, extracted into its own file
    Sandbox.loadInto('../server/permissions.lua', env)
    Sandbox.loadInto('../server/tablet.lua', env)

    return {
        env = env,
        callbacks = capturedCallbacks,
        registerPlayer = registerPlayer,
        advanceTime = function(ms) clockState.now = clockState.now + ms end,
    }
end

t.test('ROUND TRIP: a feature grant made through the REAL tabletGrantPermission is visible in ResolveFeatureState via tabletRequestMyRecord afterward', function()
    local f = newIntegrationFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function() return true end,
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local targetSrc = f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    -- Before the grant: RequireGrant-listed, has access, unblocked, no
    -- grant yet -> requires_grant_missing.
    local before = f.callbacks['john-k9:server:tabletRequestMyRecord'](targetSrc)
    local rowBefore
    for _, entry in ipairs(before.myFeatures) do if entry.key == 'BiteAndHold' then rowBefore = entry end end
    t.equals(rowBefore.state, 'requires_grant_missing')

    -- The REAL grant, through the REAL callback server/permissions.lua registers.
    local grantResult = f.callbacks['john-k9:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold')
    t.isTrue(grantResult.ok, 'the fixed IsValidPermissionKey must accept feature.BiteAndHold end to end')

    f.advanceTime(2000) -- clear server/tablet.lua's own TabletReadCooldown (targetSrc's first tabletRequestMyRecord call above already consumed it) before this second call from the SAME source
    -- After the grant: server/tablet.lua's own QueryActivePermissionSet must
    -- see the SAME row GrantPermission just wrote.
    local after = f.callbacks['john-k9:server:tabletRequestMyRecord'](targetSrc)
    local rowAfter
    for _, entry in ipairs(after.myFeatures) do if entry.key == 'BiteAndHold' then rowAfter = entry end end
    t.equals(rowAfter.state, 'available', 'a real feature.BiteAndHold grant must resolve the tablet\'s own state to available')
end)

t.test('ROUND TRIP: revoking that same feature grant through the REAL tabletRevokePermission makes ResolveFeatureState regress to requires_grant_missing', function()
    local f = newIntegrationFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function() return true end,
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local targetSrc = f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    t.isTrue(f.callbacks['john-k9:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold').ok)
    local granted = f.callbacks['john-k9:server:tabletRequestMyRecord'](targetSrc)
    local grantedRow
    for _, entry in ipairs(granted.myFeatures) do if entry.key == 'BiteAndHold' then grantedRow = entry end end
    t.equals(grantedRow.state, 'available')

    f.advanceTime(2000) -- clear PermissionActionCooldown before the granter's second action
    local revokeResult = f.callbacks['john-k9:server:tabletRevokePermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold')
    t.isTrue(revokeResult.ok)

    local revoked = f.callbacks['john-k9:server:tabletRequestMyRecord'](targetSrc)
    local revokedRow
    for _, entry in ipairs(revoked.myFeatures) do if entry.key == 'BiteAndHold' then revokedRow = entry end end
    t.equals(revokedRow.state, 'requires_grant_missing', 'a real revoke must be visible immediately -- no stale cache in either direction')
end)

t.test('ROUND TRIP: a BLOCK made through the REAL tabletGrantPermission (block.<Name> namespace) is visible as blocked, even with an active feature grant', function()
    local f = newIntegrationFixture({
        isHighCommand = function(source) return source == 1 end,
        hasK9Access = function() return true end,
    })
    local hcSrc = f.registerPlayer(1, 'HC1', { name = 'police', isboss = true, grade = { level = 0 } })
    local targetSrc = f.registerPlayer(2, 'TARGET1', { name = 'police', grade = { level = 1 } })

    t.isTrue(f.callbacks['john-k9:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'feature.BiteAndHold').ok)
    f.advanceTime(2000) -- clear PermissionActionCooldown before the granter's second action
    local blockResult = f.callbacks['john-k9:server:tabletGrantPermission'](hcSrc, 'TARGET1', 'block.BiteAndHold')
    t.isTrue(blockResult.ok, 'the fixed IsValidPermissionKey must accept block.BiteAndHold end to end')

    local result = f.callbacks['john-k9:server:tabletRequestMyRecord'](targetSrc)
    local row
    for _, entry in ipairs(result.myFeatures) do if entry.key == 'BiteAndHold' then row = entry end end
    t.equals(row.state, 'blocked', 'block must win over an active grant, matching the documented precedence order')
end)

-- ============================================================================
-- THE PARTNERS TAB -- tabletRequestMyPartnerships (CALLBACK 7),
-- tabletRequestPartnershipsForTarget (CALLBACK 8), tabletForceEndPartnership
-- (CALLBACK 9). Real K9Store in memory mode for 7/8, so the history rows are
-- the store's own, not a hand-built stub. 9 stubs its one delegate,
-- ForceBreakPartnershipForCitizenId, so a test can see exactly what the
-- handler asked it to do (the delegate itself is covered in
-- tests/partnership_spec.lua).
-- ============================================================================

local function partnersConfig(featureOn)
    return {
        Features = { CommandTablet = true, HandlerPartnership = featureOn ~= false },
        Departments = {}, Permissions = {},
        FeatureControl = { everyoneCanViewOwnRecord = true },
        CommandTablet = {},
        Database = { enabled = false },
    }
end

--- @param f table
--- @param k9Cid string
--- @param handlerCid string
--- @param endedBy string? -- nil leaves the partnership active
local function seedPartnership(f, k9Cid, handlerCid, endedBy)
    local id = f.env.K9Store.Partner_Insert(k9Cid, handlerCid, handlerCid)
    if endedBy then f.env.K9Store.Partner_EndById(id, endedBy) end
    return id
end

t.test('Partners tab: all three partnership callbacks are registered when the tablet is on', function()
    local f = newFixture({ config = partnersConfig() })
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestMyPartnerships'])
    t.isNotNil(f.callbacks['john-k9:server:tabletRequestPartnershipsForTarget'])
    t.isNotNil(f.callbacks['john-k9:server:tabletForceEndPartnership'])
end)

-- ---- CALLBACK 7: my own history ----

t.test('tabletRequestMyPartnerships: returns the caller\'s whole history across BOTH roles, newest first, with partner names and who ended each one', function()
    local f = newFixture({ config = partnersConfig() })
    local src = f.registerPlayer(1, 'ME', { name = 'police', grade = { level = 1 } }, { firstname = 'Sam', lastname = 'Handler' })
    f.registerPlayer(2, 'DOG-A', { name = 'police', grade = { level = 1 } }, { firstname = 'Rex', lastname = 'Dog' })
    f.registerOfflinePlayer('DOG-B', { firstname = 'Max', lastname = 'Dog' })
    f.registerOfflinePlayer('OFFICER-X', { firstname = 'Old', lastname = 'Partner' })

    -- 1st: I was the handler, I ended it myself.
    seedPartnership(f, 'DOG-B', 'ME', 'ME')
    -- 2nd: I was the K9 (role is per partnership), ended automatically.
    seedPartnership(f, 'ME', 'OFFICER-X', 'system:certification_revoked')
    -- 3rd: still active, I am the handler.
    seedPartnership(f, 'DOG-A', 'ME', nil)

    local result = cb(f, 'john-k9:server:tabletRequestMyPartnerships')(src)
    t.isTrue(result.ok)
    t.isTrue(result.featureEnabled)
    t.isFalse(result.truncated)
    t.equals(#result.partnerships, 3)

    local newest, middle, oldest = result.partnerships[1], result.partnerships[2], result.partnerships[3]
    t.equals(newest.partnerCitizenid, 'DOG-A')
    t.equals(newest.partnerName, 'Rex Dog')
    t.equals(newest.role, 'handler')
    t.isTrue(newest.active)
    t.isNil(newest.endedByName)
    t.isNil(newest.endedBySystemReason)

    t.equals(middle.partnerCitizenid, 'OFFICER-X')
    t.equals(middle.partnerName, 'Old Partner', 'an OFFLINE past partner still resolves to a name')
    t.equals(middle.role, 'k9')
    t.isFalse(middle.active)
    t.equals(middle.endedBySystemReason, 'certification_revoked')
    t.isNil(middle.endedByName, 'a system teardown never shows a person as the one who ended it')

    t.equals(oldest.partnerCitizenid, 'DOG-B')
    t.equals(oldest.role, 'handler')
    t.equals(oldest.endedByName, 'Sam Handler')
    t.isNil(oldest.endedBySystemReason)
end)

t.test('tabletRequestMyPartnerships: SECURITY -- never includes a partnership the caller was not part of', function()
    local f = newFixture({ config = partnersConfig() })
    local src = f.registerPlayer(1, 'ME', { name = 'police', grade = { level = 1 } })
    seedPartnership(f, 'OTHER-DOG', 'OTHER-HANDLER', nil)
    seedPartnership(f, 'OTHER-DOG-2', 'OTHER-HANDLER-2', 'OTHER-HANDLER-2')

    local result = cb(f, 'john-k9:server:tabletRequestMyPartnerships')(src)
    t.isTrue(result.ok)
    t.equals(#result.partnerships, 0)
end)

t.test('tabletRequestMyPartnerships: feature off -- ok, but flagged off and empty, even when history exists', function()
    local f = newFixture({ config = partnersConfig(false) })
    local src = f.registerPlayer(1, 'ME', { name = 'police', grade = { level = 1 } })
    seedPartnership(f, 'DOG', 'ME', nil)

    local result = cb(f, 'john-k9:server:tabletRequestMyPartnerships')(src)
    t.isTrue(result.ok)
    t.isFalse(result.featureEnabled)
    t.equals(#result.partnerships, 0)
end)

t.test('tabletRequestMyPartnerships: an unresolvable caller is refused; everyoneCanViewOwnRecord=false refuses a non-high-command caller but not high command', function()
    local f = newFixture({ config = partnersConfig() })
    t.equals(cb(f, 'john-k9:server:tabletRequestMyPartnerships')(999).error, 'not_authorized')

    local cfg = partnersConfig()
    cfg.FeatureControl.everyoneCanViewOwnRecord = false
    local g = newFixture({ config = cfg, isHighCommand = function(s) return s == 2 end })
    g.registerPlayer(1, 'OFFICER', { name = 'police', grade = { level = 1 } })
    g.registerPlayer(2, 'CHIEF', { name = 'police', grade = { level = 6 } })
    t.equals(cb(g, 'john-k9:server:tabletRequestMyPartnerships')(1).error, 'not_authorized')
    t.isTrue(cb(g, 'john-k9:server:tabletRequestMyPartnerships')(2).ok, 'high command always sees their own record')
end)

t.test('tabletRequestMyPartnerships: rate limited per caller, and allowed again once the window passes', function()
    local f = newFixture({ config = partnersConfig() })
    local src = f.registerPlayer(1, 'ME', { name = 'police', grade = { level = 1 } })
    local fn = cb(f, 'john-k9:server:tabletRequestMyPartnerships')
    t.isTrue(fn(src).ok)
    t.equals(fn(src).error, 'rate_limited')
    f.fakeNow.value = f.fakeNow.value + 1000
    t.isTrue(fn(src).ok)
end)

-- ---- CALLBACK 8: high command looks up anyone ----

t.test('tabletRequestPartnershipsForTarget: refused for a non-high-command caller, and the target\'s history is never built', function()
    local f = newFixture({ config = partnersConfig() })
    f.registerPlayer(1, 'OFFICER', { name = 'police', grade = { level = 1 } })
    seedPartnership(f, 'DOG', 'TARGET', nil)

    local result = cb(f, 'john-k9:server:tabletRequestPartnershipsForTarget')(1, 'TARGET')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.isNil(result.partnerships)
end)

t.test('tabletRequestPartnershipsForTarget: high command gets the TARGET\'s history (not their own), with the target\'s name', function()
    local f = newFixture({ config = partnersConfig(), isHighCommand = function() return true end })
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    f.registerOfflinePlayer('TARGET', { firstname = 'Tara', lastname = 'Get' })
    seedPartnership(f, 'DOG', 'TARGET', nil)
    seedPartnership(f, 'CHIEFS-DOG', 'CHIEF', nil) -- the caller's own must not leak in

    local result = cb(f, 'john-k9:server:tabletRequestPartnershipsForTarget')(1, 'TARGET')
    t.isTrue(result.ok)
    t.equals(result.target.citizenid, 'TARGET')
    t.equals(result.target.name, 'Tara Get')
    t.equals(#result.partnerships, 1)
    t.equals(result.partnerships[1].partnerCitizenid, 'DOG')
    t.equals(result.partnerships[1].role, 'handler')
end)

t.test('tabletRequestPartnershipsForTarget: bad target ids are rejected before anything else', function()
    local f = newFixture({ config = partnersConfig(), isHighCommand = function() return true end })
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    local fn = cb(f, 'john-k9:server:tabletRequestPartnershipsForTarget')
    t.equals(fn(1, nil).error, 'invalid_args')
    t.equals(fn(1, '').error, 'invalid_args')
    t.equals(fn(1, 12345).error, 'invalid_args')
    t.equals(fn(1, string.rep('X', 51)).error, 'invalid_args')
end)

t.test('tabletRequestPartnershipsForTarget: feature off -- ok and flagged off, target still named', function()
    local f = newFixture({ config = partnersConfig(false), isHighCommand = function() return true end })
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    local result = cb(f, 'john-k9:server:tabletRequestPartnershipsForTarget')(1, 'TARGET')
    t.isTrue(result.ok)
    t.isFalse(result.featureEnabled)
    t.equals(result.target.citizenid, 'TARGET')
    t.equals(#result.partnerships, 0)
end)

-- ---- CALLBACK 9: high command force-ends a partnership ----

--- @return table fixture, table calls -- every ForceBreakPartnershipForCitizenId call, as { citizenid, reason, actor }
local function forceEndFixture(opts)
    opts = opts or {}
    local f = newFixture({ config = partnersConfig(), isHighCommand = opts.isHighCommand or function() return true end })
    local calls = {}
    f.env.ForceBreakPartnershipForCitizenId = function(cid, reason, actor)
        calls[#calls + 1] = { cid, reason, actor }
        if opts.result ~= nil then return opts.result end
        return true
    end
    return f, calls
end

t.test('tabletForceEndPartnership: a non-high-command caller is refused and nothing is torn down', function()
    local f, calls = forceEndFixture({ isHighCommand = function() return false end })
    f.registerPlayer(1, 'OFFICER', { name = 'police', grade = { level = 1 } })
    local result = cb(f, 'john-k9:server:tabletForceEndPartnership')(1, 'TARGET')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.equals(#calls, 0)
end)

t.test('tabletForceEndPartnership: bad target ids are rejected and nothing is torn down', function()
    local f, calls = forceEndFixture()
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    local fn = cb(f, 'john-k9:server:tabletForceEndPartnership')
    t.equals(fn(1, nil).error, 'invalid_args')
    t.equals(fn(1, '').error, 'invalid_args')
    t.equals(fn(1, {}).error, 'invalid_args')
    t.equals(fn(1, string.rep('X', 51)).error, 'invalid_args')
    t.equals(#calls, 0)
end)

t.test('tabletForceEndPartnership: records WHICH officer ended it -- the caller\'s own citizenid, resolved server-side -- never "system"', function()
    local f, calls = forceEndFixture()
    f.registerPlayer(1, 'CHIEF-CID', { name = 'police', grade = { level = 6 } })
    local result = cb(f, 'john-k9:server:tabletForceEndPartnership')(1, 'TARGET')
    t.isTrue(result.ok)
    t.equals(#calls, 1)
    t.equals(calls[1][1], 'TARGET')
    t.equals(calls[1][2], 'admin_forced_from_tablet', 'the reason tag both players are told about is unchanged')
    t.equals(calls[1][3], 'CHIEF-CID', 'the officer must be named in the partnership history')
end)

t.test('tabletForceEndPartnership: a high-command caller the server cannot identify is refused -- an action on two other players must be attributable', function()
    local f, calls = forceEndFixture()
    -- source 7 passes IsHighCommand (the stub says yes to everyone) but has no player record.
    local result = cb(f, 'john-k9:server:tabletForceEndPartnership')(7, 'TARGET')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.equals(#calls, 0)
end)

t.test('tabletForceEndPartnership: rate limited per officer -- a second press inside 1.5s is refused, and allowed again after', function()
    local f, calls = forceEndFixture()
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    f.registerPlayer(2, 'DEPUTY-CHIEF', { name = 'police', grade = { level = 6 } })
    local fn = cb(f, 'john-k9:server:tabletForceEndPartnership')

    t.isTrue(fn(1, 'TARGET-1').ok)
    local second = fn(1, 'TARGET-2')
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')
    t.equals(#calls, 1, 'the refused press tore nothing down')

    t.isTrue(fn(2, 'TARGET-2').ok, 'the cooldown is per officer -- a different officer is not blocked')

    f.fakeNow.value = f.fakeNow.value + 1500
    t.isTrue(fn(1, 'TARGET-3').ok, 'the same officer can act again once the window has passed')
    t.equals(#calls, 3)
end)

t.test('tabletForceEndPartnership: a refused (non-high-command) press does not start the cooldown for that source', function()
    local allow = false
    local f, calls = forceEndFixture({ isHighCommand = function() return allow end })
    f.registerPlayer(1, 'OFFICER', { name = 'police', grade = { level = 1 } })
    local fn = cb(f, 'john-k9:server:tabletForceEndPartnership')
    t.equals(fn(1, 'TARGET').error, 'not_authorized')
    allow = true -- promoted between presses, same instant
    t.isTrue(fn(1, 'TARGET').ok)
    t.equals(#calls, 1)
end)

t.test('tabletForceEndPartnership: target has no active partnership -> not_partnered', function()
    local f = forceEndFixture({ result = false })
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    local result = cb(f, 'john-k9:server:tabletForceEndPartnership')(1, 'NOBODY')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_partnered')
end)

t.test('tabletForceEndPartnership: partnership system not loaded -> not_available, not a crash', function()
    local f = newFixture({ config = partnersConfig(), isHighCommand = function() return true end })
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } })
    f.env.ForceBreakPartnershipForCitizenId = nil
    local result = cb(f, 'john-k9:server:tabletForceEndPartnership')(1, 'TARGET')
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
end)

t.test('Partners tab END TO END: a force-end by high command shows up in BOTH players\' history as ended by that officer, by name', function()
    local f = newFixture({ config = partnersConfig(), isHighCommand = function(s) return s == 1 end })
    f.registerPlayer(1, 'CHIEF', { name = 'police', grade = { level = 6 } }, { firstname = 'Chief', lastname = 'Allday' })
    local handlerSrc = f.registerPlayer(2, 'HANDLER', { name = 'police', grade = { level = 1 } })
    local k9Src = f.registerPlayer(3, 'DOG', { name = 'police', grade = { level = 1 } })
    local id = seedPartnership(f, 'DOG', 'HANDLER', nil)

    -- The real primitive's job, done against the real store: end the
    -- active row with whatever ended_by the handler passed.
    f.env.ForceBreakPartnershipForCitizenId = function(cid, _reason, actor)
        local row = f.env.K9Store.Partner_GetActiveRowByParty(cid)
        if not row then return false end
        return f.env.K9Store.Partner_EndById(row.id, actor) == 1
    end

    t.isTrue(cb(f, 'john-k9:server:tabletForceEndPartnership')(1, 'HANDLER').ok)

    for _, src in ipairs({ handlerSrc, k9Src }) do
        local mine = cb(f, 'john-k9:server:tabletRequestMyPartnerships')(src)
        t.isTrue(mine.ok)
        t.equals(#mine.partnerships, 1)
        t.equals(mine.partnerships[1].id, id)
        t.isFalse(mine.partnerships[1].active)
        t.equals(mine.partnerships[1].endedByName, 'Chief Allday', 'the history names the officer who ended it')
        t.isNil(mine.partnerships[1].endedBySystemReason)
    end
end)

os.exit(t.summary())
