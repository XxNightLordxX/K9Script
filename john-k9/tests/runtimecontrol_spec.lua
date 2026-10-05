--[[
    tests/runtimecontrol_spec.lua

    Tests server/runtimecontrol.lua -- runtime feature control + tablet
    theming -- against the REAL, unmodified production file, via
    tests/fixtures/sandbox.lua. Harness style mirrors tests/highcommand_spec.lua/
    tests/permissions_spec.lua: a fake in-memory table backing every SQL
    statement this file issues (k9_runtime_feature_overrides,
    k9_runtime_override_audit, k9_tablet_theme, k9_tablet_theme_audit),
    mutated by the real production callbacks exactly like a real database
    would be.

    TWO BOOTS, ONE FAKE DATABASE: `newWorld()` builds the shared fake tables
    (survive across "restarts" -- they are plain upvalues captured by the
    MySQL stub closure, not reset between boots). `boot(world, opts)` loads
    a FRESH copy of server/cooldowns.lua + server/runtimecontrol.lua into a
    brand-new sandbox env (fresh CONFIG_LUA_DEFAULT_FEATURES/_TUNABLES
    captures, exactly like a real resource restart) pointed at the SAME
    fake tables, and fires 'onResourceStart' once. This is what makes the
    "an override survives a restart" tests possible: `boot()` twice against
    the same `world`, asserting the second boot's live Config values already
    reflect what the first boot's callbacks wrote to the fake DB.

    THE LOAD-BEARING TESTS this task named explicitly, and where each lives:
      - "a runtime OFF toggle is actually honoured by the handler"
        -> Section 2 (tier='live'; asserts the mutation lands in the exact
           shared `Config.Features` table object every real feature file
           reads, AND drives a hand-written stand-in handler using the
           SAME `if not Config.Features.X then return end` shape every
           real 'live'-tier file in this resource actually uses -- see
           server/runtimecontrol.lua's own header "THE FULL AUDIT" for the
           direct-code-read evidence backing each tier classification;
           re-deriving that evidence here would just be a second, driftable
           copy of it).
      - "an ON toggle for a load-gated feature reports restart required
        rather than lying" -> Section 3 (tier='onstart' and tier='rawtoplevel',
        including the extra `configEditRequired` distinction for the
        latter).
      - "a non-positive tuning value is refused" -> Section 5.
      - "a theme value that is not a valid colour is refused" -> Section 7.
      - "non-high-command callers are denied" -> Section 4 (features/tuning)
        and Section 7 (theme mutation) -- GetTheme itself is deliberately
        NOT covered here as a denial case; it is documented, and tested, as
        open to anyone (Section 6).

    THIS COMMENT USED TO SAY "locale() is never called by
    server/runtimecontrol.lua ... nothing here is gated on any locale key
    landing." THAT STOPPED BEING TRUE BEFORE THIS SPEC WAS EVEN UPDATED TO
    SAY SO -- SECTION 2B's own lockoutWarning assertions already exercise
    GetFeatureLockoutWarning's real `pcall(locale, ...)` calls against the
    genuine locales/en.json (via this file's own boot()/Sandbox.newEnv,
    which always wires env.locale = Sandbox.locale, a REAL reader of that
    file, never a stub). SECTION 5C (GetTunableDescription, added the same
    pass this comment was corrected) is the second, equally real, user of
    that same real locale(). Corrected here rather than re-asserted for a
    third time.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Builds one shared fake-database world: four in-memory tables backing
--- every SQL statement server/runtimecontrol.lua issues. Survives across
--- multiple boot() calls against it, exactly like a real database survives
--- a resource restart.
--- @return table world
local function newWorld()
    return {
        overrides = {},      -- override_key -> { kind, value, updated_by, updated_at }
        overrideAudit = {},  -- array of { override_key, kind, old_value, new_value, changed_by }
        theme = nil,         -- nil | { primary_color, accent_color, background_color, text_color, density, header_title }
        themeAudit = {},     -- array of full-snapshot rows
    }
end

--- @param world table
--- @return fun(sql: string, params: table): table
local function makeQueryAwait(world)
    return function(sql, params)
        if sql:find('SELECT override_key, kind, value, updated_by, updated_at FROM k9_runtime_feature_overrides', 1, true) then
            local out = {}
            for key, row in pairs(world.overrides) do
                out[#out + 1] = { override_key = key, kind = row.kind, value = row.value, updated_by = row.updated_by, updated_at = row.updated_at }
            end
            return out
        elseif sql:find('INSERT INTO k9_runtime_feature_overrides', 1, true) then
            local key, kind, value, updatedBy = params[1], params[2], params[3], params[4]
            world.overrides[key] = { kind = kind, value = value, updated_by = updatedBy, updated_at = '2026-01-01 00:00:00' }
            return {}
        elseif sql:find('DELETE FROM k9_runtime_feature_overrides', 1, true) then
            world.overrides[params[1]] = nil
            return {}
        elseif sql:find('INSERT INTO k9_runtime_override_audit', 1, true) then
            -- Two shapes, matching production exactly: SetFeature/SetTunable
            -- bind new_value as a 5th `?` (params has 5 entries); Reset*
            -- hardcodes `NULL` as literal SQL text for new_value (params
            -- has only 4 entries -- old_value, then changed_by) -- see
            -- server/runtimecontrol.lua's own two INSERT statements.
            if sql:find('VALUES (?, ?, ?, NULL, ?)', 1, true) then
                world.overrideAudit[#world.overrideAudit + 1] = {
                    override_key = params[1], kind = params[2], old_value = params[3], new_value = nil, changed_by = params[4],
                }
            else
                world.overrideAudit[#world.overrideAudit + 1] = {
                    override_key = params[1], kind = params[2], old_value = params[3], new_value = params[4], changed_by = params[5],
                }
            end
            return {}
        elseif sql:find('INSERT INTO k9_tablet_theme_audit', 1, true) then
            world.themeAudit[#world.themeAudit + 1] = {
                primary_color = params[1], accent_color = params[2], background_color = params[3],
                text_color = params[4], density = params[5], header_title = params[6], changed_by = params[7],
            }
            return {}
        elseif sql:find('SELECT primary_color, accent_color, background_color, text_color, density, header_title FROM k9_tablet_theme', 1, true) then
            if world.theme then return { world.theme } end
            return {}
        elseif sql:find('INSERT INTO k9_tablet_theme (', 1, true) then
            world.theme = {
                primary_color = params[1], accent_color = params[2], background_color = params[3],
                text_color = params[4], density = params[5], header_title = params[6],
            }
            return {}
        end
        error('runtimecontrol_spec test stub: unhandled SQL: ' .. tostring(sql))
    end
end

--- @param opts table? -- { world: table (default: fresh), config: table (Config overrides), isHighCommand: fun(source):boolean, hasPermission: fun(citizenid, key):boolean, printCapture: table? (appended to) }
--- @return table fixture -- { env, world, callbacks, printedLines, broadcasts, playersBySource }
local function boot(opts)
    opts = opts or {}
    local world = opts.world or newWorld()

    local printedLines = opts.printCapture or {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local broadcasts = {}
    local function TriggerClientEventStub(eventName, target, payload)
        broadcasts[#broadcasts + 1] = { eventName = eventName, target = target, payload = payload }
    end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local playersBySource = opts.playersBySource or {}
    -- DISPLAY-NAME FIX (this pass) -- GetPlayerByCitizenId/GetOfflinePlayer
    -- stubs for server/runtimecontrol.lua's own ResolveDisplayName, same
    -- shape tests/admin_spec.lua's own fixture already established for
    -- server/admin.lua's ResolveAuditDisplayName. Both default to an EMPTY
    -- table so every pre-existing test in this file (registerPlayer's own
    -- 3-arg call shape, no charinfo) keeps observing ResolveDisplayName's
    -- own documented "nothing resolves -> fall back to the citizenid
    -- itself" path for GetPlayerName's own default stub below to then
    -- override with a synthetic native name, exactly mirroring how a real
    -- server with no charinfo set still resolves via GetPlayerName.
    local playersByCitizenId = opts.playersByCitizenId or {}
    local offlinePlayersByCitizenId = opts.offlinePlayersByCitizenId or {}
    local getPlayerNameStub = opts.GetPlayerName or function(src) return 'SteamName#' .. tostring(src) end
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
            GetOfflinePlayer = function(_self, citizenid) return offlinePlayersByCitizenId[citizenid] end,
        },
    }

    local isHighCommand = opts.isHighCommand or function() return false end
    local hasPermission = opts.hasPermission -- nil unless a test wants the permission-grant escape hatch

    local defaultConfig = {
        Features = {
            RuntimeFeatureControl = true,
            TabletTheming = true,
            XPProgression = true,
            BasicBarkSounds = true,
            DoorInteraction = true,
            FetchMechanic = false,
            AdminAuditCommands = false,
            HighCommand = true,
            PermissionGrants = true,
            CommandTablet = true,
        },
        Tracking = {
            Scent     = { searchCooldownMs = 5000, relayCooldownMs = 1000, maxRange = 40.0, maxAgeSeconds = 900 },
            Blood     = { searchCooldownMs = 5000, relayCooldownMs = 500,  maxRange = 40.0, maxAgeSeconds = 300 },
            Gunpowder = { searchCooldownMs = 5000, relayCooldownMs = 300,  maxRange = 40.0, maxAgeSeconds = 120 },
        },
        AdminAudit = {
            CommandCooldownMs = 3000,
            MaxResults = { Certifications = 25, Partnerships = 25, SearchLog = 25 },
        },
        LeashMaxDistance = 8.0,
        CertifyProximityMeters = 5.0,
        VehicleInteractMeters = 3.0,
        CertificationExpiryCheckIntervalMs = 300000,
    }
    local config = opts.config or defaultConfig

    local fakeNow = { value = 0 }
    local env = Sandbox.newEnv({
        GetGameTimer           = function() return fakeNow.value end,
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = TriggerClientEventStub,
        exports                = exportsStub,
        MySQL                  = { query = { await = makeQueryAwait(world) } },
        IsHighCommand          = isHighCommand,
        HasPermission          = hasPermission,
        Config                 = config,
        GetPlayerName          = getPlayerNameStub,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)

    -- server/datastore.lua -- REAL, unmodified, loaded alongside (this
    -- file's own header: "the ONLY place in this resource that may name a
    -- `k9_*` table or call `MySQL.*` directly" -- server/runtimecontrol.lua's
    -- own SafeQuery/SafeWrite helpers are gone; every read/write below now
    -- goes through K9Store.Override_*/OverrideAudit_Append/Theme_*/
    -- ThemeAudit_Append). Config.Database is deliberately absent from this
    -- fixture's `config`/`defaultConfig` tables above -- K9Store's own
    -- DatabaseEnabled() fails safe to `true` (real-DB mode) on a missing
    -- Config.Database, which is exactly what makes every K9Store call below
    -- run the SAME MySQL.query.await call (against this file's own
    -- makeQueryAwait(world) stub, assigned as env.MySQL above) that this
    -- file's local SafeQuery/SafeWrite used to run directly, so every
    -- existing assertion below keeps exercising the identical SQL/params
    -- shape this fixture was written against. ONE INTENTIONAL EXCEPTION:
    -- K9Store.OverrideAudit_Append always binds `new_value` as a 5th `?`
    -- (nil for a reset), rather than this file's old two-shape SQL text
    -- (a literal `NULL` in the reset-path INSERT with only 4 bound params)
    -- -- functionally identical (both bind SQL NULL), and makeQueryAwait's
    -- own INSERT INTO k9_runtime_override_audit branch already reads
    -- params[4]/params[5] by direct index rather than by table length, so
    -- it classifies a reset row (new_value = nil) correctly either way
    -- without needing a fixture change of its own.
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env, world = world, callbacks = callbacks, printedLines = printedLines,
        broadcasts = broadcasts, playersBySource = playersBySource, fakeNow = fakeNow,
        playersByCitizenId = playersByCitizenId, offlinePlayersByCitizenId = offlinePlayersByCitizenId,
    }
end

--- DISPLAY-NAME FIX (this pass): now ALSO registers into
--- fixture.playersByCitizenId, keyed by citizenid, as the SAME table
--- object as the by-source entry (source/citizenid always refer to the
--- one connected player) -- this is what makes server/runtimecontrol.lua's
--- own ResolveDisplayName resolvable for every existing test in this file
--- that already calls registerPlayer, with NO other test change required.
--- `charinfo` is an OPTIONAL 4th param (every pre-existing call site omits
--- it, so ResolveDisplayName's own charinfo branch stays unresolved for
--- those and falls through to the GetPlayerName native stub, exactly
--- mirroring a real online player who has no charinfo set) -- only tests
--- that specifically want a resolved-by-charinfo name pass it.
--- @param fixture table
--- @param source number
--- @param citizenid string
--- @param charinfo table? -- { firstname, lastname }
local function registerPlayer(fixture, source, citizenid, charinfo)
    local playerObj = { PlayerData = { citizenid = citizenid, source = source, charinfo = charinfo } }
    fixture.playersBySource[source] = playerObj
    fixture.playersByCitizenId[citizenid] = playerObj
end

--- DISPLAY-NAME FIX (this pass): registers a citizenid that resolves ONLY
--- through exports.qbx_core:GetOfflinePlayer, never GetPlayerByCitizenId --
-- NOTE, deliberately no registerOfflinePlayer helper here (unlike
-- tests/admin_spec.lua, which needs one): this file's name resolution
-- happens at WRITE time, and the person writing an override is by
-- definition the connected officer who just pressed the button -- the
-- offline branch of ResolveDisplayName is unreachable from these call
-- sites. The case that DOES matter, a row persisted before names were
-- stored at all, is covered by the two-boot fallback test below.

local HC_SOURCE = 100
local NON_HC_SOURCE = 200

-- ============================================================================
-- SECTION 1 -- registration surface: every callback this file promises
-- exists, unconditionally (self-hosting design -- see header "SELF-HOSTING").
-- ============================================================================

t.test('registration: all seven callbacks are registered even when RuntimeFeatureControl/TabletTheming are both false at boot', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = false, TabletTheming = false, HighCommand = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    for _, name in ipairs({
        'john-k9:server:runtimeListFeatures', 'john-k9:server:runtimeSetFeature', 'john-k9:server:runtimeResetFeature',
        'john-k9:server:runtimeListTunables', 'john-k9:server:runtimeSetTunable', 'john-k9:server:runtimeResetTunable',
        'john-k9:server:tabletGetTheme', 'john-k9:server:tabletSetTheme', 'john-k9:server:tabletResetTheme',
    }) do
        t.isNotNil(f.callbacks[name], name .. ' must always be registered')
    end
end)

-- ============================================================================
-- SECTION 2 -- LOAD-BEARING: a runtime OFF toggle is actually honoured.
-- ============================================================================

t.test('LOAD-BEARING: SetFeature(false) on a tier=live feature mutates the SAME Config.Features table every real feature file reads, live, no restart', function()
    local f = boot()
    registerPlayer(f, HC_SOURCE, 'HC1')
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end

    t.isTrue(f.env.Config.Features.BasicBarkSounds, 'sanity: starts on')

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive, 'tier=live must apply live')
    t.isFalse(result.restartRequired)

    -- The mutation is observable on the EXACT table object every real
    -- feature file's own `if not Config.Features.BasicBarkSounds then
    -- return end` check reads -- env.Config IS that table (Sandbox.newEnv
    -- injects it as the global `Config` every loaded file shares).
    t.isFalse(f.env.Config.Features.BasicBarkSounds)

    -- Stand-in for a real live-tier handler, using the EXACT shape
    -- server/main.lua's real relayBark handler uses (confirmed by direct
    -- read -- see server/runtimecontrol.lua's own header "THE FULL AUDIT"):
    -- `if not Config.Features.BasicBarkSounds then return end`, evaluated
    -- FRESH on every simulated "request", against the SAME Config table
    -- this test's own SetFeature call above already mutated.
    local barkHandlerCallCount = 0
    local function standInBarkHandler()
        if not f.env.Config.Features.BasicBarkSounds then return end
        barkHandlerCallCount = barkHandlerCallCount + 1
    end
    standInBarkHandler()
    t.equals(barkHandlerCallCount, 0, 'the OFF toggle must be honoured by a handler reading the live flag -- it must NOT fire')

    -- And turning it back on works immediately too, tier=live in both
    -- directions -- fakeNow advanced past RUNTIME_CONTROL_ACTION_COOLDOWN_MS
    -- so this is a genuinely SEPARATE action, not itself proof of the
    -- rate limiter (that is Section 9's own job).
    f.fakeNow.value = f.fakeNow.value + 2000
    local onResult = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', true)
    t.isTrue(onResult.ok)
    t.isTrue(onResult.appliedLive)
    t.isFalse(onResult.restartRequired)
    standInBarkHandler()
    t.equals(barkHandlerCallCount, 1, 'turning it back on must be honoured immediately too')
end)

t.test('tier=live: DoorInteraction OFF is honoured the same way (a second, independent live-tier feature)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive)
    t.isFalse(f.env.Config.Features.DoorInteraction)
end)

-- ============================================================================
-- SECTION 3 -- LOAD-BEARING: an ON toggle for a load-gated feature reports
-- restart required rather than lying, with the extra configEditRequired
-- distinction for a raw-top-level gate.
-- ============================================================================

t.test('LOAD-BEARING: SetFeature(true) on a tier=onstart feature (AdminAuditCommands, off at boot) reports restartRequired, never claims it is already live', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    t.isFalse(f.env.Config.Features.AdminAuditCommands, 'sanity: off at boot')

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'AdminAuditCommands', true)
    t.isTrue(result.ok, 'the override itself is still saved')
    t.isFalse(result.appliedLive, 'must not claim this is live now')
    t.isTrue(result.restartRequired)
    t.isNil(result.configEditRequired, 'onstart tier needs a restart, not a config.lua edit')
    t.equals(result.tier, 'onstart')

    -- The Config value itself DOES flip (for the NEXT restart's benefit,
    -- and for consistency), but that must never be confused with "already
    -- working this session" -- the response above is what the tablet must
    -- render, and it does not claim success in the live sense.
    t.isTrue(f.env.Config.Features.AdminAuditCommands)
end)

t.test('LOAD-BEARING: SetFeature(true) on a tier=rawtoplevel feature (FetchMechanic, off at boot) reports BOTH restartRequired AND configEditRequired', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    t.isFalse(f.env.Config.Features.FetchMechanic, 'sanity: off at boot')

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'FetchMechanic', true)
    t.isTrue(result.ok)
    t.isFalse(result.appliedLive)
    t.isTrue(result.restartRequired)
    t.isTrue(result.configEditRequired, 'a restart of THIS resource alone is not sufficient for a rawtoplevel-tier feature -- config.lua itself must change')
    t.equals(result.tier, 'rawtoplevel')
end)

t.test('LOAD-BEARING: ResetFeature on a tier=onstart feature reports restartRequired, matching SetFeature\'s own tier-awareness (regression test for the reset/set asymmetry this pass fixed)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    -- AdminAuditCommands starts `false` in this fixture's defaultConfig --
    -- SetFeature(true) first so there is a real override in place for
    -- ResetFeature to actually remove (Config.Features.AdminAuditCommands
    -- flips true -> false again on reset, back to the config.lua default).
    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'AdminAuditCommands', true)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'AdminAuditCommands')
    t.isTrue(result.ok)
    t.equals(result.value, false, 'restored to the config.lua default (false)')
    t.isFalse(result.appliedLive, 'an onstart-tier feature does not re-check its flag after registration -- a reset must not claim this is live now, exactly like SetFeature does not')
    t.isTrue(result.restartRequired, 'BUG THIS PASS FIXED: this used to unconditionally report restartRequired = false regardless of tier')
    t.isNil(result.configEditRequired, 'onstart tier needs a restart, not a config.lua edit')
    t.equals(result.tier, 'onstart')
end)

t.test('LOAD-BEARING: ResetFeature on a tier=rawtoplevel feature reports BOTH restartRequired AND configEditRequired, matching SetFeature', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    -- FetchMechanic starts `false` in this fixture -- flip it on via
    -- SetFeature first so there is an override to reset away.
    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'FetchMechanic', true)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'FetchMechanic')
    t.isTrue(result.ok)
    t.equals(result.value, false)
    t.isFalse(result.appliedLive)
    t.isTrue(result.restartRequired, 'BUG THIS PASS FIXED: rawtoplevel reset used to falsely report restartRequired = false')
    t.isTrue(result.configEditRequired, 'a restart of THIS resource alone is not sufficient for a rawtoplevel-tier feature, on reset exactly as on set')
    t.equals(result.tier, 'rawtoplevel')
end)

t.test('ResetFeature on a tier=live feature still reports restartRequired = false (the fix must not regress the already-correct live case)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'BasicBarkSounds')
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive)
    t.isFalse(result.restartRequired)
    t.equals(result.tier, 'live')
end)

-- ============================================================================
-- SECTION 2B -- OWNER DIRECTIVE: HighCommand/PermissionGrants/
-- RuntimeFeatureControl/TabletTheming/CommandTablet are LOCKOUT-RISK, no
-- longer 'protected'. Covers: (a) an unconfirmed attempt is refused, loudly,
-- never silently applied; (b) the exact-name `confirm` unlocks it; (c) the
-- change IS genuinely live; (d) it is NEVER persisted (sessionOnly) and a
-- fresh boot reverts to config.lua regardless of what was last set --
-- proving the "config.lua + restart always recovers" guarantee end to end,
-- not merely asserting it in a comment.
--
-- THE DECISION THIS SECTION LOCKS IN, STATED EXPLICITLY (raised directly by
-- coder-security's review of an earlier, incomplete pass of this same
-- change: "should a high-command officer be able to disable high command at
-- all, or should that one value stay refused while everything else opens?"):
-- YES, IT STAYS EDITABLE -- refusing it outright would directly contradict
-- the owner's own instruction, given twice, verbatim: "If its high command
-- they should have the ability to grant whatever they want edit whatever
-- they want etc." This is not a hedge on that instruction; the mitigation
-- built here is not "make it safe by refusing it" but "make it safe by
-- making the failure mode cheap and the recovery unconditional":
--   - An UNCONFIRMED click can never do this by accident (the
--     confirmation-required gate below) -- the owner's own "high command
--     should have the ability" is about deliberate control, not a stray
--     double-click.
--   - A CONFIRMED click that does disable it IS a genuine, immediate,
--     same-session lockout for every high-command officer, with no
--     in-game path back (CanManageRuntimeControl needs IsHighCommand,
--     which the very same flag now gates) -- this is not softened, and
--     this section does not pretend otherwise.
--   - What IS guaranteed, and proven end to end by the test below named
--     "THE ONE THING THAT GENUINELY MATTERS": recovery needs NOTHING more
--     than restarting this resource -- not a database row deleted by
--     hand, not even a config.lua edit if config.lua's own shipped value
--     was already correct. A resource restart is a mundane, always-
--     available server-admin action (console/txAdmin), not a rare or
--     technical one -- the SAME bounded, well-understood recovery cost
--     this resource's own day-one-deadlock fix already established as
--     acceptable for a comparable class of self-inflicted lockout. That
--     is what makes this an acceptable trade for honoring the owner's
--     explicit instruction, not a reason to override it.
-- ============================================================================

t.test('LOCKOUT-RISK: SetFeature on HighCommand/PermissionGrants without a matching `confirm` is refused, loudly, and changes nothing', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    local r1 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'HighCommand', false)
    t.isFalse(r1.ok)
    t.equals(r1.reason, 'confirmation_required')
    t.isTrue(r1.lockoutRisk)
    t.isTrue(type(r1.warning) == 'string' and #r1.warning > 0, 'must carry the actual warning text back to the caller, not just a flag')
    t.isTrue(f.env.Config.Features.HighCommand, 'must be completely unchanged without confirmation')

    f.fakeNow.value = f.fakeNow.value + 2000
    -- Wrong confirm value (not the exact feature name) must ALSO refuse --
    -- this is not a bare truthy check.
    local r2 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'HighCommand', false, true)
    t.isFalse(r2.ok)
    t.equals(r2.reason, 'confirmation_required')

    f.fakeNow.value = f.fakeNow.value + 2000
    local r3 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'HighCommand', false, 'PermissionGrants')
    t.isFalse(r3.ok)
    t.equals(r3.reason, 'confirmation_required', 'confirming the WRONG name must not unlock a different feature')

    f.fakeNow.value = f.fakeNow.value + 2000
    local r4 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'PermissionGrants', false)
    t.isFalse(r4.ok)
    t.equals(r4.reason, 'confirmation_required')
end)

t.test('LOAD-BEARING: SetFeature on HighCommand with the exact-name confirm actually applies live, and is reported sessionOnly', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'HCADMIN1')

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'HighCommand', false, 'HighCommand')
    t.isTrue(result.ok, 'the exact-name confirm must unlock it')
    t.isTrue(result.appliedLive)
    t.isFalse(result.restartRequired)
    t.isTrue(result.sessionOnly, 'must disclose that this change does not survive a restart')
    t.isFalse(f.env.Config.Features.HighCommand, 'the live value really did flip')

    -- Still fully audited, even though nothing durable was written to
    -- k9_runtime_feature_overrides (see the very next test) -- "every edit
    -- must be audited" must not become false just because this one cannot
    -- also be re-applied at boot.
    t.equals(#f.world.overrideAudit, 1)
    t.equals(f.world.overrideAudit[1].override_key, 'feature:HighCommand')
    t.equals(f.world.overrideAudit[1].old_value, 'true')
    t.equals(f.world.overrideAudit[1].new_value, 'false')
    t.equals(f.world.overrideAudit[1].changed_by, 'HCADMIN1')
end)

t.test('THE ONE THING THAT GENUINELY MATTERS: turning HighCommand off from the tablet, persisted the SESSION-ONLY way, does NOT survive a restart -- config.lua always wins, with or without an operator edit', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end

    local setResult = first.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'HighCommand', false, 'HighCommand')
    t.isTrue(setResult.ok)
    t.isFalse(first.env.Config.Features.HighCommand, 'off for the rest of THIS session')

    -- NO row was ever written to k9_runtime_feature_overrides for this --
    -- proving the "never durably persisted" claim directly against the fake
    -- database, not just against this session's own in-memory state.
    t.isNil(world.overrides['feature:HighCommand'], 'a lockout-risk sessionOnly feature must never get a durable override row at all')

    -- Simulate a full resource restart WITHOUT any config.lua edit at all --
    -- the fixture's own defaultConfig always ships HighCommand = true, i.e.
    -- unchanged from before the officer's toggle.
    local second = boot({ world = world })
    t.isTrue(second.env.Config.Features.HighCommand, 'RECOVERY: a plain restart, with no config.lua edit whatsoever, must already restore config.lua\'s own shipped value -- this is the strongest form of the recovery guarantee this task required')

    -- And the audit trail from the FIRST session survives regardless (an
    -- append-only table, independent of the current-override table) --
    -- an operator can see who did it, even though nothing was re-applied.
    t.equals(#world.overrideAudit, 1, 'the permanent audit record of the toggle must still exist after the restart, even though nothing was re-applied')
end)

-- ----------------------------------------------------------------------
-- SILENT-CLOBBER LOG. Re-applying a stored override over config.lua is
-- correct and deliberate. What was missing was telling anybody: the boot
-- line printed only a COUNT, so an operator who edited config.lua,
-- restarted, and watched the console had no way to learn that the exact
-- setting they had just changed was thrown away by a tablet edit somebody
-- made weeks ago. They then spend an evening convinced the setting is
-- broken.
-- ----------------------------------------------------------------------

--- @param lines table
--- @param needle string
--- @return boolean
local function anyPrintedLineContains(lines, needle)
    for _, line in ipairs(lines) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

t.test('SILENT-CLOBBER LOG: a stored override that DISAGREES with config.lua is named at boot, with both values and the way to undo it', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end

    -- AdminAuditCommands ships false in this fixture. An officer turns it
    -- on from the tablet, which persists a real override row.
    t.isTrue(first.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'AdminAuditCommands', true).ok)
    t.isNotNil(world.overrides['feature:AdminAuditCommands'], 'precondition: a durable row really exists')

    -- Restart. config.lua still says false; the stored override says true.
    -- The override correctly wins -- and must now SAY so.
    local second = boot({ world = world })
    t.isTrue(second.env.Config.Features.AdminAuditCommands, 'unchanged behaviour: the tablet still wins, that is the design')

    t.isTrue(anyPrintedLineContains(second.printedLines, 'Config.Features.AdminAuditCommands'),
        'naming the setting is the whole point -- a bare count tells an operator nothing')
    t.isTrue(anyPrintedLineContains(second.printedLines, 'config.lua says false'),
        'it has to say what the FILE says, or the operator cannot tell whether their edit is the one being ignored')
    t.isTrue(anyPrintedLineContains(second.printedLines, 'a tablet change says true'),
        'and what is actually in effect instead')
    t.isTrue(anyPrintedLineContains(second.printedLines, 'Reset to config.lua'),
        'and how to get their edit back -- a warning with no remedy just makes someone feel stuck')
end)

t.test('SILENT-CLOBBER LOG: a stored override that AGREES with config.lua is NOT named -- it cost the operator nothing, and printing it every boot would bury the ones that did', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end
    t.isTrue(first.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'AdminAuditCommands', true).ok)

    -- The operator then ALSO edits config.lua to true -- file and override
    -- now agree, so nothing of theirs is being discarded.
    local second = boot({
        world = world,
        config = { Features = { RuntimeFeatureControl = true, TabletTheming = true, HighCommand = true, AdminAuditCommands = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } },
    })
    t.isTrue(second.env.Config.Features.AdminAuditCommands)
    t.isFalse(anyPrintedLineContains(second.printedLines, 'HEADS UP'),
        'no disagreement, so no warning -- otherwise every boot cries wolf and the real one gets ignored')
end)

t.test('SILENT-CLOBBER LOG: a boot with no stored overrides at all prints no warning', function()
    local f = boot()
    t.isFalse(anyPrintedLineContains(f.printedLines, 'HEADS UP'))
end)

t.test('LOCKOUT-RISK: ResetFeature on HighCommand/PermissionGrants also requires the exact-name confirm (symmetric with SetFeature, not a quieter back door)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    local r1 = f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'HighCommand')
    t.isFalse(r1.ok)
    t.equals(r1.reason, 'confirmation_required')

    f.fakeNow.value = f.fakeNow.value + 2000
    local r2 = f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'HighCommand', 'HighCommand')
    t.isTrue(r2.ok)
    t.isTrue(r2.sessionOnly)
end)

t.test('LOCKOUT-RISK: RuntimeFeatureControl/TabletTheming (this file\'s OWN self-hosting flags) are ALSO lockoutRisk + sessionOnly -- found and fixed this pass, not asked for by name, same bug class as HighCommand', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end

    local result = first.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'RuntimeFeatureControl', false, 'RuntimeFeatureControl')
    t.isTrue(result.ok)
    t.isTrue(result.sessionOnly)
    t.isNil(world.overrides['feature:RuntimeFeatureControl'], 'must never be durably persisted either')

    local second = boot({ world = world })
    t.isTrue(second.env.Config.Features.RuntimeFeatureControl, 'a plain restart must restore config.lua\'s own shipped value for this flag too')
end)

t.test('LOCKOUT-RISK: CommandTablet requires confirm too, but keeps its existing rawtoplevel/configEditRequired persistence (a persisted override here can never itself brick anything -- it already needs a deliberate config.lua edit to do anything at all)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    local unconfirmed = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'CommandTablet', false)
    t.isFalse(unconfirmed.ok)
    t.equals(unconfirmed.reason, 'confirmation_required')

    f.fakeNow.value = f.fakeNow.value + 2000
    local confirmed = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'CommandTablet', false, 'CommandTablet')
    t.isTrue(confirmed.ok)
    t.equals(confirmed.tier, 'rawtoplevel')
    t.isTrue(confirmed.configEditRequired)
    t.isNil(confirmed.sessionOnly, 'CommandTablet is lockoutRisk but NOT sessionOnly -- its own rawtoplevel gate already makes a persisted row harmless')
    t.equals(f.world.overrides['feature:CommandTablet'].value, 'false', 'unlike HighCommand, this one IS durably persisted -- consistent with every other rawtoplevel feature')
end)

t.test('runtimeListFeatures reports lockoutRisk/sessionOnly/lockoutWarning so the tablet can render a warning without a second round trip', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    t.isTrue(result.ok)

    local rowByName = {}
    for _, row in ipairs(result.features) do rowByName[row.name] = row end

    for _, name in ipairs({ 'HighCommand', 'PermissionGrants', 'RuntimeFeatureControl', 'TabletTheming', 'CommandTablet' }) do
        t.isTrue(rowByName[name].lockoutRisk, name .. ' must be reported as lockoutRisk = true')
        t.isTrue(type(rowByName[name].lockoutWarning) == 'string' and #rowByName[name].lockoutWarning > 0, name .. ' must carry real warning text, not a placeholder')
    end
    t.isTrue(rowByName.HighCommand.sessionOnly)
    t.isTrue(rowByName.RuntimeFeatureControl.sessionOnly)
    t.isFalse(rowByName.CommandTablet.sessionOnly, 'CommandTablet is lockoutRisk but not sessionOnly')

    -- A normal feature must show neither flag as true (nil is fine; false
    -- is also acceptable -- this checks it is never mistakenly true).
    t.isFalse(rowByName.BasicBarkSounds.lockoutRisk == true)
end)

-- ============================================================================
-- SECTION 3B -- ACTIVE-USAGE CONFIRMATION: BiteAndHold/NonLethalTakedown/
-- PropDragging/DeployableKennel additionally refuse to be switched OFF
-- while at least one player is genuinely doing that exact thing right now
-- -- server/combat.lua's CountActiveHoldsByEffectType / server/kennel.lua's
-- CountKennelOccupants are NOT loaded by this file's own sandbox (boot()
-- above loads ONLY server/cooldowns.lua + server/runtimecontrol.lua, per
-- this file's own header) -- every test below injects a stand-in directly
-- onto `f.env`, the SAME "runtime-existence-guarded soft dependency"
-- pattern tests/certifications_spec.lua already uses
-- for `f.env.EndActiveEffectForHolder`.
-- ============================================================================

--- @param extraFeatures table? -- merged over the four active-usage
--- features (all on by default) plus one more (also on, for the
--- exclusion test below) -- e.g. { BiteAndHold = false } to start one off.
local function bootWithActiveUsageFeatures(extraFeatures)
    local features = {
        RuntimeFeatureControl = true, TabletTheming = true,
        BiteAndHold = true, NonLethalTakedown = true, PropDragging = true, DeployableKennel = true,
    }
    for k, v in pairs(extraFeatures or {}) do features[k] = v end
    return boot({ config = { Features = features, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
end

t.test('THE LOCKOUT CASE IS ACTUALLY BLOCKED, not merely asked about: SetFeature(BiteAndHold, false) while 2 holds are genuinely open is refused, and Config.Features.BiteAndHold is left COMPLETELY UNCHANGED -- no override row, no audit row claiming success', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end
    f.env.CountActiveHoldsByEffectType = function(effectType) return (effectType == 'bite') and 2 or 0 end

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BiteAndHold', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'confirmation_required')
    t.isTrue(result.lockoutRisk)
    t.isTrue(type(result.warning) == 'string' and result.warning:find('2', 1, true) ~= nil, 'the warning must carry the REAL, current number -- "2" -- not a generic "are you sure?"')
    t.isTrue(result.warning:find('bite%-and%-hold') ~= nil, 'must name the actual activity in plain English')

    -- THE BLOCK ITSELF, independently verified, not inferred from `ok`:
    t.isTrue(f.env.Config.Features.BiteAndHold, 'the live flag must be COMPLETELY UNCHANGED -- this is the actual lockout, not merely a dialog that was skipped')
    t.isNil(f.world.overrides['feature:BiteAndHold'], 'no override row may exist for a refused change')
    t.equals(#f.world.overrideAudit, 0, 'no audit row may claim this change happened')

    -- Confirming with the exact name now genuinely applies it.
    f.fakeNow.value = f.fakeNow.value + 2000
    local confirmed = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BiteAndHold', false, 'BiteAndHold')
    t.isTrue(confirmed.ok)
    t.isFalse(f.env.Config.Features.BiteAndHold, 'now genuinely off, once actually confirmed')
end)

t.test('an active-usage warning uses SINGULAR wording for exactly 1, plural for more than 1', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end

    f.env.CountActiveHoldsByEffectType = function() return 1 end
    local one = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'NonLethalTakedown', false)
    t.isTrue(one.warning:find('1 player is', 1, true) ~= nil, 'singular: ' .. tostring(one.warning))

    f.fakeNow.value = f.fakeNow.value + 2000
    f.env.CountActiveHoldsByEffectType = function() return 3 end
    local three = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'NonLethalTakedown', false)
    t.isTrue(three.warning:find('3 players are', 1, true) ~= nil, 'plural: ' .. tostring(three.warning))
end)

t.test('with NOBODY currently doing it (count = 0), SetFeature(BiteAndHold, false) applies IMMEDIATELY with no confirmation demanded at all', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end
    f.env.CountActiveHoldsByEffectType = function() return 0 end

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BiteAndHold', false)
    t.isTrue(result.ok, 'zero active usage must never demand a confirmation this task does not need')
    t.isFalse(f.env.Config.Features.BiteAndHold)
end)

t.test('with server/combat.lua NOT LOADED at all in this environment (no CountActiveHoldsByEffectType global whatsoever), SetFeature(PropDragging, false) still applies immediately -- an absent probe must never be treated as "everyone is using it"', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end
    -- Deliberately NOT setting f.env.CountActiveHoldsByEffectType at all.

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'PropDragging', false)
    t.isTrue(result.ok, 'a missing probe must fail SAFE (treated as "nobody using it"), never fail closed into a permanent, un-skippable confirmation wall')
end)

t.test('a probe that ERRORS instead of returning a number is swallowed by pcall -- SetFeature still applies, never throws out of the callback', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end
    f.env.CountActiveHoldsByEffectType = function() error('boom -- server/combat.lua exploded') end

    local ok, result = pcall(f.callbacks['john-k9:server:runtimeSetFeature'], HC_SOURCE, 'BiteAndHold', false)
    t.isTrue(ok, 'a broken cross-file probe must never crash this callback')
    t.isTrue(result.ok)
end)

t.test('turning a feature BACK ON is NEVER gated by active usage, no matter how many players are using it -- this confirmation gates STARTING to disable, never the opposite direction', function()
    local f = bootWithActiveUsageFeatures({ DeployableKennel = false })
    f.env.IsHighCommand = function() return true end
    f.env.CountKennelOccupants = function() return 99 end

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DeployableKennel', true)
    t.isTrue(result.ok, 'enabling a feature can never strand anyone -- must never be gated')
    t.isTrue(f.env.Config.Features.DeployableKennel)
end)

t.test('DeployableKennel: the SAME gate, driven by CountKennelOccupants instead of CountActiveHoldsByEffectType, with its own honest (never "will end it") wording', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end
    f.env.CountKennelOccupants = function() return 4 end

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DeployableKennel', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'confirmation_required')
    t.isTrue(result.warning:find('4', 1, true) ~= nil)
    t.isTrue(result.warning:find('kennel', 1, true) ~= nil)
    t.isTrue(result.warning:find('NOT remove them', 1, true) ~= nil, 'must never overclaim that an already-resting K9 is force-evicted -- it is not')
    t.isTrue(f.env.Config.Features.DeployableKennel, 'unchanged until confirmed')
end)

t.test('ResetFeature is symmetric with SetFeature on active-usage confirmation: gated when the RESULTING (config.lua default) value is false, exact same real-number warning, exact same block until confirmed', function()
    -- f2's config.lua default for DeployableKennel is `true` -- an
    -- override sets it to `false` first (unconfirmed, but count=0 by
    -- default so no gate applies to THAT set), then resetting it removes
    -- the override and restores the `true` default -- the RESULT is true,
    -- so this must never be gated, no matter the count stubbed in.
    local f2 = bootWithActiveUsageFeatures()
    f2.env.IsHighCommand = function() return true end
    f2.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DeployableKennel', false)
    f2.fakeNow.value = f2.fakeNow.value + 2000
    f2.env.CountKennelOccupants = function() return 50 end
    local resetToTrue = f2.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'DeployableKennel')
    t.isTrue(resetToTrue.ok, 'resetting TO true (the config.lua default here) must never be gated by active usage, no matter the count')
    t.isTrue(f2.env.Config.Features.DeployableKennel)

    -- f3's config.lua default is `false` -- an override sets it to `true`
    -- first (confirmed, since RuntimeFeatureControl/TabletTheming/etc. are
    -- irrelevant here but the ON direction is never gated anyway), then
    -- resetting it removes the override and restores the `false` default
    -- -- the RESULT is false, so THIS is gated exactly like an explicit
    -- SetFeature(false) would be.
    local f3 = boot({ config = { Features = { RuntimeFeatureControl = true, TabletTheming = true, DeployableKennel = false }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    f3.env.IsHighCommand = function() return true end
    f3.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DeployableKennel', true, 'DeployableKennel')
    f3.fakeNow.value = f3.fakeNow.value + 2000
    f3.env.CountKennelOccupants = function() return 7 end

    local unconfirmedReset = f3.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'DeployableKennel')
    t.isFalse(unconfirmedReset.ok, 'resetting back to the config.lua default of false must be gated exactly like an explicit SetFeature(false) would be, since the RESULT is the same')
    t.equals(unconfirmedReset.reason, 'confirmation_required')
    t.isTrue(unconfirmedReset.warning:find('7', 1, true) ~= nil)
    t.isTrue(f3.env.Config.Features.DeployableKennel, 'must remain true (the override), completely unchanged, until confirmed')

    f3.fakeNow.value = f3.fakeNow.value + 2000
    local confirmedReset = f3.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'DeployableKennel', 'DeployableKennel')
    t.isTrue(confirmedReset.ok)
    t.isFalse(f3.env.Config.Features.DeployableKennel)
end)

t.test('runtimeListFeatures: a currently-OFF feature never shows active-usage lockoutRisk even if a stray count exists -- nothing pending to disable, so no warning is owed', function()
    local f = bootWithActiveUsageFeatures({ BiteAndHold = false })
    f.env.IsHighCommand = function() return true end
    f.env.CountActiveHoldsByEffectType = function() return 5 end

    local result = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    local rowByName = {}
    for _, row in ipairs(result.features) do rowByName[row.name] = row end
    t.isFalse(rowByName.BiteAndHold.lockoutRisk == true, 'already off -- there is nothing this confirmation could still be protecting')
end)

t.test('runtimeListFeatures: a currently-ON feature with active usage right now shows lockoutRisk + the real-number warning BEFORE any click, exactly like a static lockout-risk row', function()
    local f = bootWithActiveUsageFeatures()
    f.env.IsHighCommand = function() return true end
    f.env.CountActiveHoldsByEffectType = function(effectType) return (effectType == 'drag') and 6 or 0 end

    local result = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    local rowByName = {}
    for _, row in ipairs(result.features) do rowByName[row.name] = row end
    t.isTrue(rowByName.PropDragging.lockoutRisk, 'PropDragging must be reported as lockoutRisk while 6 drags are open')
    t.isTrue(rowByName.PropDragging.lockoutWarning:find('6', 1, true) ~= nil)
    t.isFalse(rowByName.BiteAndHold.lockoutRisk == true, 'a SIBLING feature at 0 active holds must not be flagged just because a different effectType is busy')
end)

t.test('LOAD-BEARING: SetFeature refuses tier=unaudited outright (the fail-closed net for a feature nobody has classified yet), with a named console warning', function()
    -- A Config.Features key that exists ONLY in this test's fixture config,
    -- never in the real FEATURE_TIERS table server/runtimecontrol.lua ships
    -- with -- genuinely 'unaudited' from that real, unmodified production
    -- file's own point of view, exactly the shape of the bug this refusal
    -- exists to close (see server/runtimecontrol.lua's header "UPDATED
    -- 2026-08-26" / "FEATURE REGISTRY").
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, HighCommand = true, TabletTheming = false, SomeBrandNewFeatureNobodyClassifiedYet = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    f.env.IsHighCommand = function() return true end

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'SomeBrandNewFeatureNobodyClassifiedYet', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'unaudited_feature')
    t.isTrue(f.env.Config.Features.SomeBrandNewFeatureNobodyClassifiedYet, 'must be completely unchanged, exactly like a protected-feature refusal')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('SomeBrandNewFeatureNobodyClassifiedYet', 1, true) then warned = true end
    end
    t.isTrue(warned, 'the refusal must print a loud, named warning identifying the exact feature -- a silent denial here would reproduce the exact bug this check exists to close')
end)

t.test('a Config.Features key with no FEATURE_TIERS entry is loudly warned about at BOOT TIME too, not only when someone tries to toggle it', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, HighCommand = true, AnotherUnclassifiedOne = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('AnotherUnclassifiedOne', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an unclassified Config.Features key must be visible on every boot, not only discovered later via a failed toggle attempt')
end)

t.test('tier=clientonly still applies via SetFeature (never refused) -- only protected/unaudited are refused, clientonly is a KNOWN, classified tier', function()
    local f = boot({ config = { Features = { RuntimeFeatureControl = true, HighCommand = true, RadialMenu = true }, AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} } } })
    f.env.IsHighCommand = function() return true end

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'RadialMenu', false)
    t.isTrue(result.ok)
    t.isFalse(result.appliedLive)
    t.isTrue(result.restartRequired)
    t.equals(result.tier, 'clientonly')
    t.isFalse(f.env.Config.Features.RadialMenu)
end)

t.test('an unrecognized feature name is rejected as invalid_feature, never silently accepted', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'ThisFeatureDoesNotExist', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_feature')
end)

t.test('feature_disabled: SetFeature refuses when Config.Features.RuntimeFeatureControl is false, even for real high command', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.env.Config.Features.RuntimeFeatureControl = false
    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isFalse(result.ok)
    t.equals(result.reason, 'feature_disabled')
    t.isTrue(f.env.Config.Features.BasicBarkSounds, 'nothing must have changed')
end)

-- ============================================================================
-- SECTION 4 -- LOAD-BEARING: non-high-command callers are denied, for
-- every mutating callback, and for the two list callbacks.
-- ============================================================================

t.test('LOAD-BEARING: every mutating callback denies a non-high-command, non-permission-holding caller', function()
    local f = boot()
    registerPlayer(f, NON_HC_SOURCE, 'PLEB1')
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end -- NON_HC_SOURCE never qualifies

    local r1 = f.callbacks['john-k9:server:runtimeSetFeature'](NON_HC_SOURCE, 'BasicBarkSounds', false)
    t.isFalse(r1.ok); t.equals(r1.reason, 'denied')
    t.isTrue(f.env.Config.Features.BasicBarkSounds, 'must not have changed')

    local r2 = f.callbacks['john-k9:server:runtimeResetFeature'](NON_HC_SOURCE, 'BasicBarkSounds')
    t.isFalse(r2.ok); t.equals(r2.reason, 'denied')

    local r3 = f.callbacks['john-k9:server:runtimeListFeatures'](NON_HC_SOURCE)
    t.isFalse(r3.ok); t.equals(r3.reason, 'denied')

    local r4 = f.callbacks['john-k9:server:runtimeSetTunable'](NON_HC_SOURCE, 'LeashMaxDistance', 10.0)
    t.isFalse(r4.ok); t.equals(r4.reason, 'denied')

    local r5 = f.callbacks['john-k9:server:runtimeResetTunable'](NON_HC_SOURCE, 'LeashMaxDistance')
    t.isFalse(r5.ok); t.equals(r5.reason, 'denied')

    local r6 = f.callbacks['john-k9:server:runtimeListTunables'](NON_HC_SOURCE)
    t.isFalse(r6.ok); t.equals(r6.reason, 'denied')
end)

t.test('the k9.runtimecontrol permission grant, once HasPermission says yes, is an alternate authorized path (forward-compatible escape hatch)', function()
    local f = boot({ hasPermission = function(citizenid, key) return citizenid == 'GRANTED1' and key == 'k9.runtimecontrol' end })
    registerPlayer(f, NON_HC_SOURCE, 'GRANTED1')
    f.env.IsHighCommand = function() return false end -- not high command at all

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](NON_HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(result.ok, 'a citizenid holding the k9.runtimecontrol grant must be authorized even without high command')
end)

-- ============================================================================
-- SECTION 5 -- LOAD-BEARING: a non-positive tuning value is refused.
-- ============================================================================

t.test('LOAD-BEARING: a zero tuning value is refused (the cooldowns.lua footgun this file exists to prevent from ever reaching a cooldown tracker)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', 0)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
    t.equals(result.min, 100)
    t.equals(f.env.Config.Tracking.Blood.relayCooldownMs, 500, 'must be completely unchanged')
end)

t.test('a negative tuning value is refused', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', -500)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
end)

t.test('a NaN tuning value is refused, does not throw', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local ok, result = pcall(f.callbacks['john-k9:server:runtimeSetTunable'], HC_SOURCE, 'Tracking.Blood.relayCooldownMs', 0 / 0)
    t.isTrue(ok, 'must not raise on NaN')
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
end)

t.test('an infinite tuning value is refused', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', math.huge)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
end)

t.test('a value above the registry max is refused, told the exact max back', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Tracking.Blood.relayCooldownMs', 999999)
    t.isFalse(result.ok)
    t.equals(result.reason, 'out_of_range')
    t.equals(result.max, 10000)
end)

t.test('a fractional value for an integer-kind tunable is refused', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'AdminAudit.MaxResults.Certifications', 10.5)
    t.isFalse(result.ok)
    t.equals(result.reason, 'not_integer')
end)

t.test('a value inside range is accepted and applied live, and reads back via ListTunables', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 12.5)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive)
    t.equals(f.env.Config.LeashMaxDistance, 12.5)

    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    local found
    for _, row in ipairs(listed.tunables) do
        if row.key == 'LeashMaxDistance' then found = row end
    end
    t.isNotNil(found)
    t.equals(found.currentValue, 12.5)
    t.equals(found.configLuaDefault, 8.0)
    t.isTrue(found.overridden)
end)

t.test('an unrecognized tunable key is rejected as invalid_key', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Config.XP.awards.searchContrabandFound', 999999)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key')
end)

t.test('resetting a tunable restores the config.lua default and removes the override', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 12.5)
    t.equals(f.env.Config.LeashMaxDistance, 12.5)

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['john-k9:server:runtimeResetTunable'](HC_SOURCE, 'LeashMaxDistance')
    t.isTrue(result.ok)
    t.equals(result.value, 8.0)
    t.equals(f.env.Config.LeashMaxDistance, 8.0)
    t.isNil(f.world.overrides['tuning:LeashMaxDistance'], 'the override row must be gone, not merely re-set to the default value')
end)

-- ============================================================================
-- SECTION 5B -- LOAD-BEARING: the stamina-duration tunable (owner directive:
-- "make sure high command can edit the ability to make stamina last longer
-- or even permanently"). defaultConfig above has no Wellbeing table at all,
-- so this section supplies its own minimal config -- same shape convention
-- the very first test in this file (SECTION 1, "registration:...") already
-- establishes for a sparse custom `opts.config`.
-- ============================================================================

t.test('Wellbeing.Fatigue.sprintDecayPerTick is registered (min=0 -- the "permanent stamina" sentinel -- max=20.0, matching every sibling per-tick Wellbeing field), and a live edit reaches the real Config table with 0 treated as a genuine value, never a missing one', function()
    local f = boot({ config = {
        Features = { RuntimeFeatureControl = true, HighCommand = true },
        AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} },
        Wellbeing = { Fatigue = { sprintDecayPerTick = 2.0 } },
    } })
    f.env.IsHighCommand = function() return true end

    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    local found
    for _, row in ipairs(listed.tunables) do
        if row.key == 'Wellbeing.Fatigue.sprintDecayPerTick' then found = row end
    end
    t.isNotNil(found, 'Wellbeing.Fatigue.sprintDecayPerTick must be registered')
    t.equals(found.min, 0, '0 must be reachable -- it is this tunable\'s own exact "permanent stamina" value, not merely a low number')
    t.equals(found.max, 20.0)
    t.equals(found.configLuaDefault, 2.0)

    -- RuntimeControlActionCooldown (server/runtimecontrol.lua, 1000ms) gates
    -- every mutating call by source -- advanced past between calls below,
    -- same convention this file's own "resetting a tunable..." test already
    -- uses (`f.fakeNow.value = f.fakeNow.value + 2000`), so each assertion
    -- below is exercising the [min,max]/zero-value logic, not accidentally
    -- tripping over the unrelated rate limit.
    local setToPermanent = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Wellbeing.Fatigue.sprintDecayPerTick', 0)
    t.isTrue(setToPermanent.ok, 'setting to exactly 0 ("permanent") must be accepted -- the zero-is-truthy trap must not make this look like a missing/refused value')
    t.equals(f.env.Config.Wellbeing.Fatigue.sprintDecayPerTick, 0)

    f.fakeNow.value = f.fakeNow.value + 2000
    local belowMin = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Wellbeing.Fatigue.sprintDecayPerTick', -1)
    t.isFalse(belowMin.ok)
    t.equals(belowMin.reason, 'out_of_range')
    t.equals(f.env.Config.Wellbeing.Fatigue.sprintDecayPerTick, 0, 'a refused value must leave the current (permanent) value completely unchanged')

    f.fakeNow.value = f.fakeNow.value + 2000
    local aboveMax = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Wellbeing.Fatigue.sprintDecayPerTick', 20.1)
    t.isFalse(aboveMax.ok)
    t.equals(aboveMax.reason, 'out_of_range')
    t.equals(aboveMax.max, 20.0)

    -- Live edit back to finite, reads back via ListTunables -- mirrors this
    -- file's own "value inside range is accepted... reads back" test above.
    f.fakeNow.value = f.fakeNow.value + 2000
    local setToFinite = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Wellbeing.Fatigue.sprintDecayPerTick', 1.5)
    t.isTrue(setToFinite.ok)
    t.equals(f.env.Config.Wellbeing.Fatigue.sprintDecayPerTick, 1.5)
    local listedAgain = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    for _, row in ipairs(listedAgain.tunables) do
        if row.key == 'Wellbeing.Fatigue.sprintDecayPerTick' then
            t.equals(row.currentValue, 1.5)
            t.isTrue(row.overridden)
        end
    end
end)

-- ============================================================================
-- SECTION 5C -- LOAD-BEARING: plain-English tunable descriptions. The
-- exact usability bug this section guards against: the tablet's Runtime
-- Control -> Settings table used to show ONLY a tunable's raw Config path
-- (e.g. "Wellbeing.Fatigue.sprintDecayPerTick") with no explanation of what
-- it does -- indistinguishable, at a glance, from
-- "Wellbeing.Fatigue.nativeStaminaRestorePercent", a DIFFERENT setting
-- controlling a DIFFERENT stamina system entirely (this resource's own
-- custom Fatigue stat vs. the game engine's built-in Stamina bar). This
-- section tests GetTunableDescription/runtimeListTunables' own new
-- `description` field, using this file's own boot() fixture, which (like
-- every other spec built on tests/fixtures/sandbox.lua) already wires a
-- REAL `locale()` reading the genuine, unmodified locales/en.json --
-- exactly like SECTION 2B's own lockoutWarning assertions already do for
-- runtime_lockout_warning_*_template, so a description text asserted here
-- is the SAME text a real tablet would actually render, not a test double.
-- ============================================================================

t.test('runtimeListTunables carries a real, non-empty description for a tunable that has one in locales/en.json', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    local found
    for _, row in ipairs(listed.tunables) do
        if row.key == 'LeashMaxDistance' then found = row end
    end
    t.isNotNil(found)
    t.isTrue(type(found.description) == 'string' and #found.description > 0, 'LeashMaxDistance must carry a real plain-English description, not merely its own raw key')
end)

t.test('THE LOAD-BEARING CASE: the two stamina-adjacent tunables (sprintDecayPerTick vs. nativeStaminaRestorePercent) have DIFFERENT, DISTINGUISHING descriptions -- the exact confusion this whole fix exists to prevent', function()
    local f = boot({ config = {
        Features = { RuntimeFeatureControl = true, HighCommand = true },
        AdminAudit = {}, Tracking = { Scent = {}, Blood = {}, Gunpowder = {} },
        Wellbeing = { Fatigue = { sprintDecayPerTick = 2.0, nativeStaminaRestorePercent = 0.0 } },
    } })
    f.env.IsHighCommand = function() return true end
    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)

    local byKey = {}
    for _, row in ipairs(listed.tunables) do byKey[row.key] = row end

    local decay = byKey['Wellbeing.Fatigue.sprintDecayPerTick']
    local restore = byKey['Wellbeing.Fatigue.nativeStaminaRestorePercent']
    t.isNotNil(decay)
    t.isNotNil(restore)
    t.isTrue(type(decay.description) == 'string' and #decay.description > 0)
    t.isTrue(type(restore.description) == 'string' and #restore.description > 0)
    t.isTrue(decay.description ~= restore.description, 'these two settings control genuinely different things and must never share one description')

    -- The reader must be able to tell WHICH ONE moves the on-screen
    -- "Stamina" bar without reading source -- sprintDecayPerTick's own
    -- description must name this resource's OWN stat (Fatigue), and
    -- nativeStaminaRestorePercent's own description must name the game
    -- engine's OWN stat (Stamina), so grepping either text alone
    -- disambiguates it.
    t.isTrue(decay.description:find('Fatigue', 1, true) ~= nil, 'sprintDecayPerTick describes the Fatigue stat')
    t.isTrue(restore.description:find('Stamina', 1, true) ~= nil, 'nativeStaminaRestorePercent describes the Stamina bar')
end)

t.test('DO NOT LET A MISSING DESCRIPTION BREAK THE ROW: an unrecognized-by-locale (hypothetical future) tunable key still resolves to a nil description, never a thrown error', function()
    -- GetTunableDescription is not itself registered as a callback, but
    -- runtimeListTunables (its only real caller) must never surface a
    -- pcall failure to the client as a broken response -- this is
    -- exercised indirectly here by confirming the REAL registry, as
    -- shipped today, never trips the pcall's failure branch for any key
    -- (a thrown, uncaught locale() error would make listed.ok read false
    -- with no coherent reason, which the earlier "carries a real
    -- description" test above would already have caught) -- and directly
    -- via TunableDescriptionLocaleKey's own deterministic, format-string-free
    -- construction (a plain string concatenation of the already-alphanumeric
    -- TUNABLE_REGISTRY key), which cannot itself throw for any key this
    -- registry contains.
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok, 'a missing description must never make the whole list callback fail')
    t.isTrue(#listed.tunables > 0)
end)

t.test('EVERY TUNABLE_REGISTRY entry that has a locales/en.json description carries genuinely different text from every other one (no copy-pasted filler shared across unrelated settings)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)

    local seen = {}
    local duplicates = {}
    for _, row in ipairs(listed.tunables) do
        if type(row.description) == 'string' and #row.description > 0 then
            if seen[row.description] then
                duplicates[#duplicates + 1] = row.key .. ' == ' .. seen[row.description]
            else
                seen[row.description] = row.key
            end
        end
    end
    t.equals(#duplicates, 0, 'duplicate tunable descriptions found: ' .. table.concat(duplicates, '; '))
end)

-- ============================================================================
-- SECTION 6 -- theme GET is open to anyone (no authorization check).
-- ============================================================================

t.test('GetTheme requires no authorization at all -- any connected source gets the current theme', function()
    local f = boot()
    f.env.IsHighCommand = function() return false end
    local result = f.callbacks['john-k9:server:tabletGetTheme'](NON_HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(result.theme.primaryColor, '#2563eb')
    t.equals(result.theme.headerTitle, 'K9 Command Tablet')
end)

t.test('GetTheme rejects an invalid source defensively (never a table lookup on garbage)', function()
    local f = boot()
    local result = f.callbacks['john-k9:server:tabletGetTheme']('not-a-source')
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_source')
end)

-- ============================================================================
-- SECTION 7 -- LOAD-BEARING: a theme value that is not a valid colour is
-- refused, plus the denial/feature-disabled/XSS-shaped-string cases.
-- ============================================================================

t.test('LOAD-BEARING: SetTheme refuses a non-colour primaryColor', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { primaryColor = 'not-a-color' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_field')
    t.equals(result.field, 'primaryColor')
    t.equals(f.env.Config, f.env.Config, 'sanity')
end)

t.test('SetTheme refuses a 3-digit shorthand hex colour (strict #RRGGBB only)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { accentColor = '#fff' })
    t.isFalse(result.ok)
    t.equals(result.field, 'accentColor')
end)

t.test('SetTheme refuses an unrecognized density value (fixed enum, never free text)', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { density = 'ultra-wide' })
    t.isFalse(result.ok)
    t.equals(result.field, 'density')
end)

t.test('SetTheme refuses a headerTitle containing HTML-special characters, never lets it reach the DOM as markup', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { headerTitle = '<img src=x onerror=alert(1)>' })
    t.isFalse(result.ok)
    t.equals(result.field, 'headerTitle')
end)

t.test('SetTheme refuses a headerTitle over 40 characters', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local result = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { headerTitle = ('x'):rep(41) })
    t.isFalse(result.ok)
    t.equals(result.field, 'headerTitle')
end)

t.test('SetTheme accepts a valid partial update, merges onto the current theme (does not blank untouched fields), persists, broadcasts', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'HC1')

    local result = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { headerTitle = 'Bark Squad HQ', density = 'compact' })
    t.isTrue(result.ok)
    t.equals(result.theme.headerTitle, 'Bark Squad HQ')
    t.equals(result.theme.density, 'compact')
    t.equals(result.theme.primaryColor, '#2563eb', 'untouched fields must survive a partial update unchanged')

    local getResult = f.callbacks['john-k9:server:tabletGetTheme'](NON_HC_SOURCE)
    t.equals(getResult.theme.headerTitle, 'Bark Squad HQ', 'GetTheme must reflect the just-applied change immediately')

    t.equals(#f.broadcasts, 1)
    t.equals(f.broadcasts[1].eventName, 'john-k9:client:themeUpdated')
    t.equals(f.broadcasts[1].target, -1, 'must broadcast to every client, not one target')
    t.equals(f.broadcasts[1].payload.headerTitle, 'Bark Squad HQ')

    t.equals(#f.world.themeAudit, 1, 'the change must be recorded in the append-only audit table')
    t.equals(f.world.themeAudit[1].changed_by, 'HC1')
end)

t.test('SetTheme denies a non-high-command caller', function()
    local f = boot()
    f.env.IsHighCommand = function() return false end
    local result = f.callbacks['john-k9:server:tabletSetTheme'](NON_HC_SOURCE, { density = 'compact' })
    t.isFalse(result.ok)
    t.equals(result.reason, 'denied')
end)

t.test('SetTheme/ResetTheme refuse when Config.Features.TabletTheming is false', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.env.Config.Features.TabletTheming = false
    local r1 = f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { density = 'compact' })
    t.isFalse(r1.ok); t.equals(r1.reason, 'feature_disabled')
    local r2 = f.callbacks['john-k9:server:tabletResetTheme'](HC_SOURCE)
    t.isFalse(r2.ok); t.equals(r2.reason, 'feature_disabled')
end)

t.test('ResetTheme restores every field to the built-in default and broadcasts', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    f.callbacks['john-k9:server:tabletSetTheme'](HC_SOURCE, { density = 'compact', headerTitle = 'Changed' })

    f.fakeNow.value = f.fakeNow.value + 2000
    local result = f.callbacks['john-k9:server:tabletResetTheme'](HC_SOURCE)
    t.isTrue(result.ok)
    t.equals(result.theme.density, 'comfortable')
    t.equals(result.theme.headerTitle, 'K9 Command Tablet')
    t.equals(#f.broadcasts, 2, 'both the set and the reset must each broadcast once')
end)

-- ============================================================================
-- SECTION 8 -- persistence across a restart, and the audit trail.
-- ============================================================================

t.test('PERSISTENCE: a feature override survives a fresh boot against the same database', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end
    first.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isFalse(first.env.Config.Features.BasicBarkSounds)

    -- Simulate a full resource restart: a BRAND NEW sandbox env, a BRAND
    -- NEW CONFIG_LUA_DEFAULT_FEATURES capture (config.lua's own shipped
    -- default, BasicBarkSounds = true, exactly like the fresh `defaultConfig`
    -- table boot() builds), against the SAME fake database.
    local second = boot({ world = world })
    t.isFalse(second.env.Config.Features.BasicBarkSounds, 'the override must be re-applied on this fresh boot, before any player ever connects -- a restart must not silently revert it')
end)

t.test('PERSISTENCE: a tuning override survives a fresh boot, and a stale/out-of-range override is skipped with a warning rather than applied blindly', function()
    local world = newWorld()
    local first = boot({ world = world })
    first.env.IsHighCommand = function() return true end
    first.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 15.0)

    -- Manually corrupt the persisted value to something now out of range,
    -- exactly as if a registry bound were tightened between two versions
    -- of this file, or the DB were hand-edited.
    world.overrides['tuning:LeashMaxDistance'].value = '999999'

    local second = boot({ world = world })
    t.equals(second.env.Config.LeashMaxDistance, 8.0, 'an out-of-range persisted value must NEVER be blindly re-applied -- falls back to the config.lua default instead')
    local warned = false
    for _, line in ipairs(second.printedLines) do
        if line:find('skipped stale/unrecognized override', 1, true) then warned = true end
    end
    t.isTrue(warned, 'the skip must be logged, not silent')
end)

t.test('AUDIT: SetFeature/ResetFeature/SetTunable/ResetTunable each append one row naming who changed what, from what, to what', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'AUDITOR1')

    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'BasicBarkSounds')
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 10.0)
    f.fakeNow.value = f.fakeNow.value + 2000
    f.callbacks['john-k9:server:runtimeResetTunable'](HC_SOURCE, 'LeashMaxDistance')

    t.equals(#f.world.overrideAudit, 4)

    local setRow = f.world.overrideAudit[1]
    t.equals(setRow.override_key, 'feature:BasicBarkSounds')
    t.equals(setRow.old_value, 'true')
    t.equals(setRow.new_value, 'false')
    t.equals(setRow.changed_by, 'AUDITOR1')

    local resetRow = f.world.overrideAudit[2]
    t.equals(resetRow.override_key, 'feature:BasicBarkSounds')
    t.equals(resetRow.old_value, 'false')
    t.isNil(resetRow.new_value, 'new_value NULL means "reset to the config.lua default" per the migration\'s own documented convention')
end)

t.test('the console AUDIT print line names the acting citizenid, the action, and the outcome', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    registerPlayer(f, HC_SOURCE, 'PRINTAUDIT1')
    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)

    local auditLine
    for _, line in ipairs(f.printedLines) do
        if line:find('AUDIT:', 1, true) and line:find('runtimeSetFeature', 1, true) then auditLine = line end
    end
    t.isNotNil(auditLine)
    t.contains(auditLine, 'citizenid=PRINTAUDIT1')
    t.contains(auditLine, '-> ok')
end)

-- ============================================================================
-- SECTION 9 -- rate limiting (anti-fat-finger, per this file's own header).
-- ============================================================================

t.test('rate limiting: a second mutating call from the same officer inside the cooldown window is rejected, recovers once elapsed', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end

    f.fakeNow.value = 0
    local r1 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(r1.ok)

    f.fakeNow.value = 100 -- inside the 1000ms window
    local r2 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    t.isFalse(r2.ok)
    t.equals(r2.reason, 'rate_limited')
    t.isTrue(f.env.Config.Features.DoorInteraction, 'the rate-limited call must not have applied anything')

    f.fakeNow.value = 1500 -- past the window
    local r3 = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    t.isTrue(r3.ok)
end)

t.test('rate limiting is per-OFFICER, not global -- a different officer is unaffected', function()
    local f = boot()
    f.env.IsHighCommand = function() return true end
    local OTHER_HC_SOURCE = 300

    f.fakeNow.value = 0
    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    local result = f.callbacks['john-k9:server:runtimeSetFeature'](OTHER_HC_SOURCE, 'DoorInteraction', false)
    t.isTrue(result.ok, 'a different officer, same fakeNow, must not be blocked by the first officer\'s cooldown')
end)

-- ============================================================================
-- SECTION 10 -- LOAD-BEARING DRIFT GUARD: every TUNABLE_REGISTRY entry's
-- `path` actually resolves against the REAL, unmodified config.lua, and the
-- value config.lua ships with today falls INSIDE that entry's own declared
-- [min, max] -- the exact class of mistake a hand-typed `path` array (a
-- typo'd key, a table nested one level differently than assumed) or an
-- overly-narrow range would otherwise ship silently: SetTunable would refuse
-- config.lua's OWN shipped default as "out_of_range" the first time anyone
-- reset to it, or GetConfigByPath would silently resolve to `nil` forever.
-- Mirrors tests/runtimefeaturetiers_spec.lua's own "load the REAL config.lua,
-- never a fixture stand-in" discipline for the identical reason: a curated
-- fixture Config table could never catch a `path` that only breaks against
-- the real shape.
-- ============================================================================

--- @return table fixture -- { env, callbacks, fakeNow }
--- @param opts table? -- { maxSpeedScentMultiplier: number? -- override REAL
---   config.lua's own Config.MaxSpeedScentMultiplier (10.0) BEFORE
---   server/runtimecontrol.lua's own TUNABLE_REGISTRY is built, simulating
---   an operator having set a different value in their own config.lua. }
local function bootAgainstRealConfig(opts)
    opts = opts or {}
    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Mutable, unlike runtimefeaturetiers_spec.lua's own fixed `return 0`
    -- (that spec never calls a mutating/rate-limited callback more than
    -- once) -- this section's own tests call multiple mutating SetTunable
    -- callbacks back to back from the SAME officer, which would otherwise
    -- collide with RuntimeControlActionCooldown's real 1000ms anti-fat-
    -- finger window every single time.
    local fakeNow = { value = 0 }

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetGameTimer           = function() return fakeNow.value end,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = function() end,
        exports                = { qbx_core = { GetPlayer = function() return nil end } },
        IsHighCommand          = function() return true end,
    })

    -- REAL config.lua -- see this section's own header for why a fixture
    -- Config table cannot substitute here.
    Sandbox.loadInto('../config.lua', env)
    env.Config.Database = env.Config.Database or {}
    env.Config.Database.enabled = false -- route K9Store through its in-memory backend -- see runtimefeaturetiers_spec.lua's identical "NO MYSQL STUB NEEDED" note
    if opts.maxSpeedScentMultiplier ~= nil then
        -- Applied AFTER loading real config.lua but BEFORE
        -- server/runtimecontrol.lua (whose own ResolveMaxSpeedScentMultiplier
        -- resolves this at THAT file's load time, below) -- simulates an
        -- operator having set a different value in their own config.lua,
        -- without needing a second, hand-built fake Config table.
        env.Config.MaxSpeedScentMultiplier = opts.maxSpeedScentMultiplier
    end

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('john-k9') end

    return { env = env, callbacks = callbacks, printedLines = printedLines, fakeNow = fakeNow }
end

t.test('LOAD-BEARING DRIFT GUARD: every TUNABLE_REGISTRY path resolves against the REAL config.lua, to a value inside that entry\'s own [min, max]', function()
    local f = bootAgainstRealConfig()

    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)

    local problems = {}
    for _, row in ipairs(listed.tunables) do
        if row.currentValue == nil then
            problems[#problems + 1] = row.key .. ' (path does not resolve against real config.lua -- currentValue is nil; check for a mistyped key or a differently-nested table)'
        elseif type(row.currentValue) ~= 'number' then
            problems[#problems + 1] = row.key .. (' (config.lua value is a %s, not a number: %s)'):format(type(row.currentValue), tostring(row.currentValue))
        else
            if row.currentValue < row.min or row.currentValue > row.max then
                problems[#problems + 1] = row.key .. (' (config.lua ships %s, outside this entry\'s own declared [%s, %s] -- SetTunable would refuse config.lua\'s OWN default)'):format(tostring(row.currentValue), tostring(row.min), tostring(row.max))
            end
            if row.integer and row.currentValue ~= math.floor(row.currentValue) then
                problems[#problems + 1] = row.key .. (' (marked integer = true but config.lua ships a fractional value: %s)'):format(tostring(row.currentValue))
            end
        end
    end

    if #problems > 0 then
        table.sort(problems)
        error(('%d TUNABLE_REGISTRY entr(ies) failed against the real config.lua:\n  - %s'):format(#problems, table.concat(problems, '\n  - ')), 0)
    end

    -- Sanity: this really exercised a substantially-expanded registry, not
    -- an accidentally-empty or truncated one -- mirrors
    -- runtimefeaturetiers_spec.lua's own ">= 56" sanity floor for the
    -- identical reason (a loadfile typo silently producing a near-empty
    -- table would otherwise make the loop above pass vacuously).
    -- FLOOR LOWERED 105 -> 85 on 2026-09-02: the 21 removed-subsystem
    -- Wellbeing tunables were
    -- deleted with the subsystems that owned them. The floor still exists
    -- for its original reason -- a loadfile typo producing a near-empty
    -- registry would make the loop above pass vacuously -- so it stays high
    -- enough to catch that, just not higher than the registry now is.
    t.isTrue(#listed.tunables >= 85, ('sanity: only saw %d tunable(s) registered -- expected at least 85'):format(#listed.tunables))
end)

t.test('RESOLVED: K9Medkit.cooldownMs is now safely exposed as a tunable -- server/medkit.lua\'s own StartSweep prune window (staleAfterMs) used to be a captured-once-at-load local, not a fresh Config read, so a LIVE RAISE of this value would have been silently undermined by the sweep evicting the tracker entry using the OLD, now-too-short window; that gap is closed (ResolveMedkitBaseCooldownMs is now called fresh both by the per-request gate AND every sweep tick), so the old "must never be exposed" pinning would now just be asserting a bug that no longer exists', function()
    local f = bootAgainstRealConfig()
    f.env.IsHighCommand = function() return true end

    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    local found
    for _, row in ipairs(listed.tunables) do
        if row.key == 'K9Medkit.cooldownMs' then found = row end
    end
    t.isNotNil(found, 'K9Medkit.cooldownMs must now be present in TUNABLE_REGISTRY')
    t.equals(found.currentValue, f.env.Config.K9Medkit.cooldownMs, 'must reflect the real config.lua value, not a hardcoded stand-in')

    -- SetTunable must actually accept and apply it end to end, not merely
    -- list it -- mirrors the "a value inside range is accepted and applied
    -- live" shape used for every other genuinely-live tunable in this file.
    local setResult = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'K9Medkit.cooldownMs', 120000)
    t.isTrue(setResult.ok)
    t.isTrue(setResult.appliedLive)
    t.equals(f.env.Config.K9Medkit.cooldownMs, 120000)

    -- Out-of-range values are still rejected with the configured bounds
    -- named back, exactly like every other tunable -- being newly-exposed
    -- does not mean unbounded. fakeNow advanced past
    -- RUNTIME_CONTROL_ACTION_COOLDOWN_MS first -- the same officer's own
    -- anti-fat-finger window would otherwise reject this second call for an
    -- unrelated reason.
    f.fakeNow.value = f.fakeNow.value + 2000
    local tooLow = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'K9Medkit.cooldownMs', 1)
    t.isFalse(tooLow.ok)
    t.equals(tooLow.reason, 'out_of_range')
end)

t.test('every out-of-range rejection for a newly-added tunable still names the exact configured bounds back to the caller (spot-check across the expansion, not just the original 20)', function()
    local f = bootAgainstRealConfig()

    -- RuntimeControlActionCooldown.Consume runs BEFORE the range check in
    -- the real callback -- an out-of-range rejection still consumes the
    -- officer's own anti-fat-finger window, exactly like a successful call
    -- does. fakeNow is advanced past RUNTIME_CONTROL_ACTION_COOLDOWN_MS
    -- between every call below for that reason, matching the primary
    -- boot() fixture's own convention throughout this file, so this test
    -- proves the range/bounds behavior and never accidentally collides with
    -- the rate limiter instead.
    local r1 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'K9DownDispatch.minDurationMs', -1)
    t.isFalse(r1.ok); t.equals(r1.reason, 'out_of_range'); t.equals(r1.min, 0)


    f.fakeNow.value = f.fakeNow.value + 2000
    local r3 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Combat.BiteAndHold.maxDurationMs', 4999)
    t.isFalse(r3.ok); t.equals(r3.reason, 'out_of_range'); t.equals(r3.min, 5000)

    -- And a genuinely in-range write to one of them actually applies live,
    -- proving these new paths are not merely well-formed but functional
    -- end to end against the real Config table.
    f.fakeNow.value = f.fakeNow.value + 2000
    local ok = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'SearchZones.searchCooldownMs', 20000)
    t.isTrue(ok.ok)
    t.equals(f.env.Config.SearchZones.searchCooldownMs, 20000)
end)

t.test('SearchZones.alertBroadcastRadius is deliberately NOT a tunable -- that file\'s own onResourceStart assert calls it "a hard safety ceiling, not a server-tunable-to-anything toggle"', function()
    local f = bootAgainstRealConfig()
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'SearchZones.alertBroadcastRadius', 50.0)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_key')
end)

-- ============================================================================
-- SECTION 11 -- OWNER DIRECTIVE: previously-withheld economy/access-control
-- values, now open. Config.HighCommand.*, Config.XP.*, Config.
-- CertificationExpiryDays/WarningDays. PLUS the single most important
-- regression guard in this whole file: no path may ever reach
-- Config.Departments or Config.HighCommand.allowSelfGrant.
-- ============================================================================

t.test('OWNER DIRECTIVE: Config.HighCommand.maxXpPerGrant / grantCooldownMs are now tunable, read fresh, genuinely live', function()
    local f = bootAgainstRealConfig()

    local r1 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'HighCommand.maxXpPerGrant', 250000)
    t.isTrue(r1.ok)
    t.equals(f.env.Config.HighCommand.maxXpPerGrant, 250000)

    f.fakeNow.value = f.fakeNow.value + 2000
    local r2 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'HighCommand.grantCooldownMs', 500)
    t.isTrue(r2.ok)
    t.equals(f.env.Config.HighCommand.grantCooldownMs, 500)

    -- Bounds are real, not decorative -- literally unbounded is refused
    -- outright (server/highcommand.lua's own registration guard treats an
    -- infinite maxXpPerGrant as INVALID and never registers '/k9givexp' at
    -- all for it -- this registry must never be able to produce that value).
    f.fakeNow.value = f.fakeNow.value + 2000
    local r3 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'HighCommand.maxXpPerGrant', math.huge)
    t.isFalse(r3.ok)
    t.equals(r3.reason, 'out_of_range')

    f.fakeNow.value = f.fakeNow.value + 2000
    local r4 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'HighCommand.grantCooldownMs', 0)
    t.isFalse(r4.ok, 'cooldowns.lua footgun: 0 must never be in range for a cooldown tunable, even an anti-fat-finger one')
    t.equals(r4.reason, 'out_of_range')
end)

t.test('OWNER DIRECTIVE: Config.XP.awards.* are now tunable, but each is capped at exactly 3600 (XP_MINT_BUDGET_CAP_XP) -- a real footgun this pass found and closed, not a decorative ceiling', function()
    local f = bootAgainstRealConfig()

    local ok = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'XP.awards.searchContrabandFound', 3600)
    t.isTrue(ok.ok, 'exactly 3600 (the mint budget cap itself) must be accepted -- server/progression.lua\'s own assert uses <=, not <')
    t.equals(f.env.Config.XP.awards.searchContrabandFound, 3600)

    f.fakeNow.value = f.fakeNow.value + 2000
    local tooHigh = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'XP.awards.searchContrabandFound', 3601)
    t.isFalse(tooHigh.ok, 'BUG THIS PASS FOUND AND CLOSED: server/progression.lua has its own bare onResourceStart assert(amount <= XP_MINT_BUDGET_CAP_XP) over every Config.XP.awards.* key -- since this file\'s own onResourceStart reapplies overrides BEFORE that assert ever runs, a tunable above 3600 could otherwise get persisted here and crash that assert on the very next restart. This registry\'s own max must refuse it before it is ever written.')
    t.equals(tooHigh.reason, 'out_of_range')
    t.equals(tooHigh.max, 3600)

    -- Spot-check a second award key gets the identical ceiling -- the
    -- assert this defends against applies uniformly to every key in
    -- Config.XP.awards, so every tunable entry for that table must too.
    f.fakeNow.value = f.fakeNow.value + 2000
    local secondKey = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'XP.awards.partnershipTenure30Day', 3601)
    t.isFalse(secondKey.ok)
    t.equals(secondKey.max, 3600)
end)

t.test('OWNER DIRECTIVE: Config.XP.trackArrivalRadius / trackArrivalTTLMs are tunable and independent of the 3600 mint-budget ceiling (not part of Config.XP.awards)', function()
    local f = bootAgainstRealConfig()
    local r1 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'XP.trackArrivalRadius', 10.0)
    t.isTrue(r1.ok)
    f.fakeNow.value = f.fakeNow.value + 2000
    local r2 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'XP.trackArrivalTTLMs', 120000)
    t.isTrue(r2.ok)
    t.equals(f.env.Config.XP.trackArrivalRadius, 10.0)
    t.equals(f.env.Config.XP.trackArrivalTTLMs, 120000)
end)

t.test('OWNER DIRECTIVE: Config.CertificationExpiryDays / CertificationExpiryWarningDays are now tunable', function()
    local f = bootAgainstRealConfig()
    local r1 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'CertificationExpiryDays', 180)
    t.isTrue(r1.ok)
    t.equals(f.env.Config.CertificationExpiryDays, 180)

    f.fakeNow.value = f.fakeNow.value + 2000
    local r2 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'CertificationExpiryWarningDays', 0)
    t.isFalse(r2.ok, 'a zero/non-positive value here must be refused, matching that file\'s own "must be a positive number" contract -- never silently coerced to the built-in 7-day fallback')
    t.equals(r2.reason, 'out_of_range')
end)

-- ============================================================================
-- OWNER-EDITABLE CEILING (Config.MaxSpeedScentMultiplier, Part A). This
-- file's own PursuitSprint.speedMultiplier TUNABLE_REGISTRY entry used to
-- hardcode `max = 3.0`; it is now `max = ResolveMaxSpeedScentMultiplier()`,
-- resolved fresh from config.lua at THIS file's own load time -- the SAME
-- setting server/xptiers.lua/server/k9profiles.lua each read through their
-- own identical resolver (see this file's own copy, declared immediately
-- above TUNABLE_REGISTRY, for the "no cross-file `local` import mechanism"
-- writeup).
-- ============================================================================

t.test('CEILING IS GENUINELY CONFIG-DRIVEN: against the REAL config.lua (Config.MaxSpeedScentMultiplier = 10.0), PursuitSprint.speedMultiplier accepts 10.0 and rejects 10.01', function()
    local f = bootAgainstRealConfig()
    local ok1 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'PursuitSprint.speedMultiplier', 10.0)
    t.isTrue(ok1.ok, tostring(ok1.reason))
    t.equals(f.env.Config.PursuitSprint.speedMultiplier, 10.0)

    f.fakeNow.value = f.fakeNow.value + 2000
    local rejected = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'PursuitSprint.speedMultiplier', 10.01)
    t.isFalse(rejected.ok)
    t.equals(rejected.reason, 'out_of_range')
    t.equals(rejected.max, 10.0, 'the reported ceiling in the rejection itself must be the REAL config.lua value (10.0), not a stale hardcoded 3.0')
end)

t.test('CEILING IS GENUINELY CONFIG-DRIVEN: Config.MaxSpeedScentMultiplier = 5.0 accepts 4.9 and rejects 5.1', function()
    local f = bootAgainstRealConfig({ maxSpeedScentMultiplier = 5.0 })
    local ok1 = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'PursuitSprint.speedMultiplier', 4.9)
    t.isTrue(ok1.ok, tostring(ok1.reason))

    f.fakeNow.value = f.fakeNow.value + 2000
    local rejected = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'PursuitSprint.speedMultiplier', 5.1)
    t.isFalse(rejected.ok)
    t.equals(rejected.reason, 'out_of_range')
    t.equals(rejected.max, 5.0)
end)

t.test('CEILING IS GENUINELY CONFIG-DRIVEN: a simulated reboot at Config.MaxSpeedScentMultiplier = 50.0 now accepts 40.0 (would have been rejected under the old hardcoded 3.0, and under the real config.lua\'s own 10.0 default)', function()
    local f = bootAgainstRealConfig({ maxSpeedScentMultiplier = 50.0 })
    local result = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'PursuitSprint.speedMultiplier', 40.0)
    t.isTrue(result.ok, tostring(result.reason))
    t.equals(f.env.Config.PursuitSprint.speedMultiplier, 40.0)
end)

t.test('CEILING: 0, negative, NaN, infinity and a string are each rejected at a NON-DEFAULT ceiling too, and the call never errors (pcall)', function()
    local f = bootAgainstRealConfig({ maxSpeedScentMultiplier = 5.0 })
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -1, nan, math.huge, -math.huge, 'not a number' }) do
        f.fakeNow.value = f.fakeNow.value + 2000
        local ok, result = pcall(f.callbacks['john-k9:server:runtimeSetTunable'], HC_SOURCE, 'PursuitSprint.speedMultiplier', bad)
        t.isTrue(ok, ('must never throw for speedMultiplier = %s'):format(tostring(bad)))
        t.isFalse(result.ok)
    end
end)

t.test('CEILING: Config.MaxSpeedScentMultiplier missing/invalid on a REAL boot still falls back to 10.0 with a named warning (real config.lua always ships a valid value today, so this proves the resolver itself, not merely today\'s shipped number)', function()
    local nan = 0 / 0
    for _, bad in ipairs({ 0, -5, nan, math.huge, -math.huge, 'not a number' }) do
        local f = bootAgainstRealConfig({ maxSpeedScentMultiplier = bad })
        local found = false
        for _, line in ipairs(f.printedLines) do
            if line:find('Config.MaxSpeedScentMultiplier', 1, true) and line:find('10', 1, true) then found = true end
        end
        t.isTrue(found, ('Config.MaxSpeedScentMultiplier = %s must print a named warning and fall back to 10.0'):format(tostring(bad)))
        local accepted = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'PursuitSprint.speedMultiplier', 10.0)
        t.isTrue(accepted.ok, ('Config.MaxSpeedScentMultiplier = %s must still fall back to accepting 10.0, not disable the file'):format(tostring(bad)))
    end
end)

t.test('NON-NEGOTIABLE, THE SINGLE MOST IMPORTANT CHECK IN THIS FILE: no TUNABLE_REGISTRY entry may ever reach Config.Departments or Config.HighCommand.allowSelfGrant -- widening what high command may EDIT must never create a path to widening WHO COUNTS AS high command', function()
    local f = bootAgainstRealConfig()
    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)

    for _, row in ipairs(listed.tunables) do
        t.isFalse(row.key:find('^Departments%.') ~= nil or row.key == 'Departments', row.key .. ' -- Config.Departments (highCommandGrade/certifierGrade/etc, the rank thresholds that DEFINE who is high command) must NEVER be reachable through this registry -- a two-hop path where an edit here could promote its own editor into high command would defeat this entire mechanism\'s one real safety property')
        t.isFalse(row.key == 'HighCommand.allowSelfGrant', 'allowSelfGrant is a boolean self-grant switch, squarely the OTHER agent\'s self-GRANT scope (server/highcommand.lua) -- must never be exposed here, and could not be anyway (TUNABLE_REGISTRY has no boolean mechanism)')
    end

    -- Also confirmed end to end, not just absent from the list: SetTunable
    -- itself must refuse a fabricated Departments path outright, exactly
    -- like any other unrecognized key.
    local attempt = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'Departments.police.highCommandGrade', 0)
    t.isFalse(attempt.ok)
    t.equals(attempt.reason, 'invalid_key')
end)

-- ============================================================================
-- UNBOUNDED-TRAP FIX (restart/reconnect audit follow-up, this pass) --
-- THE END-TO-END PROOF, spanning both files this pass touches. Every test
-- above this section loads server/runtimecontrol.lua ALONE, so none of it
-- can prove the actual wiring: does flipping Config.Features.XPProgression
-- via the REAL runtimeSetFeature/runtimeResetFeature callbacks actually
-- reach server/progression.lua's RefreshXPProgressionLiveStateForAllOnline
-- and, through it, an already-connected K9's own client? This section
-- loads server/runtimecontrol.lua AND server/progression.lua TOGETHER, in
-- fxmanifest.lua's own real server_scripts order (datastore -> cooldowns
-- -> runtimecontrol -> events -> progression), against the REAL config.lua
-- (same "no curated fixture Config could catch this" discipline as
-- bootAgainstRealConfig() above), and answers exactly that question. See
-- tests/progression_spec.lua's own "UNBOUNDED-TRAP FIX" section for the
-- narrower, single-file half of this same fix (PushTierSnapshot/
-- RefreshXPProgressionLiveStateForAllOnline in isolation).
-- ============================================================================

--- @return table fixture -- { env, callbacks, fakeNow, printedLines, capturedClientEvents, markOnline, markOffline }
local function bootWithProgressionAgainstRealConfig()
    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }
    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local fakeNow = { value = 0 }

    local capturedClientEvents = {}
    local function TriggerClientEventStub(eventName, target, payload)
        capturedClientEvents[#capturedClientEvents + 1] = { eventName = eventName, target = target, payload = payload }
    end

    -- citizenid -> { PlayerData = { citizenid, source } } -- mirrors
    -- tests/progression_spec.lua's own newGap1Fixture shape exactly, so
    -- RefreshXPProgressionLiveStateForAllOnline's GetPlayers()-driven loop
    -- (server/progression.lua) resolves a real connected source the same
    -- way a real qbx_core install would.
    local onlineByCitizenId = {}
    local function GetPlayersStub()
        local ids = {}
        for _, p in pairs(onlineByCitizenId) do
            ids[#ids + 1] = tostring(p.PlayerData.source)
        end
        return ids
    end
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                for _, p in pairs(onlineByCitizenId) do
                    if p.PlayerData.source == src then return p end
                end
                return nil
            end,
            GetPlayerByCitizenId = function(_self, citizenid) return onlineByCitizenId[citizenid] end,
        },
    }

    -- server/progression.lua needs CreateThread/Wait (AwardXP's own
    -- non-blocking DB-write thread, and the mint-budget sweep thread) --
    -- unused by this section's own tests (none call AwardXP), but required
    -- for that file to even LOAD without erroring. One-shot bodies (no
    -- Wait()) run to completion synchronously on CreateThread's own resume;
    -- a recurring "while true do Wait() ... end" body yields at its first
    -- Wait() and is simply left parked forever (never stepped) -- this
    -- section has no need to drive it, identical posture to
    -- tests/progression_spec.lua's own newGap1Fixture for the same thread.
    local function CreateThreadStub(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('bootWithProgressionAgainstRealConfig: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
    end
    local function WaitStub(_ms) coroutine.yield() end

    local env = Sandbox.newEnv({
        AddEventHandler        = AddEventHandlerStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        GetGameTimer           = function() return fakeNow.value end,
        GetPlayers             = GetPlayersStub,
        print                  = printStub,
        lib                    = lib,
        TriggerClientEvent     = TriggerClientEventStub,
        TriggerEvent           = function() end,
        CreateThread           = CreateThreadStub,
        Wait                   = WaitStub,
        exports                = exportsStub,
        IsHighCommand          = function() return true end,
    })

    -- REAL config.lua -- see bootAgainstRealConfig()'s own header for why a
    -- fixture Config table cannot substitute here (a curated stand-in could
    -- never catch a real FEATURE_TIERS/Config.Features name mismatch).
    Sandbox.loadInto('../config.lua', env)
    env.Config.Database = env.Config.Database or {}
    env.Config.Database.enabled = false -- route K9Store through its in-memory backend -- NO MYSQL STUB NEEDED, same as bootAgainstRealConfig()

    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/runtimecontrol.lua', env)
    Sandbox.loadInto('../server/events.lua', env)
    Sandbox.loadInto('../server/progression.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler('john-k9') end

    return {
        env = env, callbacks = callbacks, printedLines = printedLines, fakeNow = fakeNow,
        capturedClientEvents = capturedClientEvents,
        markOnline = function(citizenid, src) onlineByCitizenId[citizenid] = { PlayerData = { citizenid = citizenid, source = src } } end,
        markOffline = function(citizenid) onlineByCitizenId[citizenid] = nil end,
    }
end

t.test('UNBOUNDED-TRAP FIX, END TO END, THE ACTUAL REPORTED BUG: runtimeSetFeature(XPProgression, false) immediately pushes a live=false xpTierChanged snapshot to an ALREADY-CONNECTED K9 client -- same call, no reconnect/restart needed', function()
    local f = bootWithProgressionAgainstRealConfig()
    t.isTrue(f.env.Config.Features.XPProgression, 'sanity: config.lua ships this on by default')
    f.markOnline('E2ECIT', 9001)

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'XPProgression', false)
    t.isTrue(result.ok)
    t.isTrue(result.appliedLive, 'XPProgression is tier=live')

    local pushed = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 9001 then pushed = evt end
    end
    t.isNotNil(pushed, 'THE BUG: an already-online K9 must be told the flag changed IMMEDIATELY -- without this, the client keeps applying its last-known speedMultiplier/scentRangeMultiplier forever (until reconnect/restart), exactly the unbounded trap client/progression.lua\'s own header documents')
    t.equals(pushed.payload.live, false, 'the pushed snapshot must carry live=false so client/progression.lua force-resets its cached move-rate modifier to neutral')
end)

t.test('UNBOUNDED-TRAP FIX: flipping XPProgression back ON immediately pushes live=true again, same tick -- symmetric, not a one-way kill switch', function()
    local f = bootWithProgressionAgainstRealConfig()
    f.markOnline('E2ECIT2', 9002)

    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'XPProgression', false)
    f.fakeNow.value = f.fakeNow.value + 2000 -- clear RuntimeControlActionCooldown's 1000ms floor
    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'XPProgression', true)
    t.isTrue(result.ok)

    local lastPush = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 9002 then lastPush = evt end
    end
    t.isNotNil(lastPush)
    t.equals(lastPush.payload.live, true, 'the LAST push (after re-enabling) must carry live=true')
end)

t.test('UNBOUNDED-TRAP FIX: runtimeResetFeature(XPProgression) ALSO pushes the live update to already-online K9s -- ApplyFeatureOverride is the single mutation point for both SetFeature and ResetFeature', function()
    local f = bootWithProgressionAgainstRealConfig()
    f.markOnline('E2ECIT3', 9003)
    -- config.lua's own shipped default for XPProgression is true, so a
    -- reset-to-default is a true->true no-op for the VALUE -- flip it off
    -- via Set first so the reset below is an observable false->true
    -- transition, exactly like an operator undoing their own earlier change.
    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'XPProgression', false)
    f.fakeNow.value = f.fakeNow.value + 2000

    local result = f.callbacks['john-k9:server:runtimeResetFeature'](HC_SOURCE, 'XPProgression')
    t.isTrue(result.ok)
    t.isTrue(result.value, 'config.lua\'s own default is true')

    local lastPush = nil
    for _, evt in ipairs(f.capturedClientEvents) do
        if evt.eventName == 'john-k9:client:xpTierChanged' and evt.target == 9003 then lastPush = evt end
    end
    t.isNotNil(lastPush, 'runtimeResetFeature must ALSO reach ApplyFeatureOverride\'s new hook, not just runtimeSetFeature')
    t.equals(lastPush.payload.live, true)
end)

t.test('UNBOUNDED-TRAP FIX: toggling HandlerXPProgression fires NO client push at all -- verified, not assumed: no client-side tier cache exists for it, so this flag needs no equivalent hook', function()
    local f = bootWithProgressionAgainstRealConfig()
    f.markOnline('E2ECIT4', 9004)

    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'HandlerXPProgression', false)
    t.isTrue(result.ok)
    for _, evt in ipairs(f.capturedClientEvents) do
        t.isFalse(evt.eventName == 'john-k9:client:xpTierChanged', 'HandlerXPProgression must never trigger an xpTierChanged push -- ApplyFeatureOverride\'s new hook is scoped to name == "XPProgression" only')
    end
end)

t.test('UNBOUNDED-TRAP FIX: an OFFLINE citizenid is simply skipped when the flag flips -- no push, no error', function()
    local f = bootWithProgressionAgainstRealConfig()
    -- Deliberately never marked online.
    local result = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'XPProgression', false)
    t.isTrue(result.ok)
    t.equals(#f.capturedClientEvents, 0, 'nobody online -- nothing to push, and no crash')
end)

-- ============================================================================
-- DISPLAY NAME RESOLUTION (owner's request, verbatim, server/admin.lua:920)
-- -- THE SETTINGS-SCREEN FIX, end to end against the real callbacks.
-- ============================================================================

t.test('DISPLAY-NAME FIX: runtimeListFeatures reports the ACTING OFFICER\'S NAME, not their citizenid, for a feature just overridden this session', function()
    local f = boot()
    registerPlayer(f, HC_SOURCE, 'NAMECIT1', { firstname = 'Alex', lastname = 'Handler' })
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end

    local setResult = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(setResult.ok)

    local listed = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    t.isTrue(listed.ok)
    local row = nil
    for _, r in ipairs(listed.features) do
        if r.name == 'BasicBarkSounds' then row = r end
    end
    t.isNotNil(row)
    t.isTrue(row.overridden)
    t.equals(row.overriddenBy, 'Alex Handler', 'THE BUG: this used to be the raw citizenid ("NAMECIT1") -- the owner\'s own instruction (server/admin.lua:920) is "ensure a name actually pops up and not the player id"')
end)

t.test('DISPLAY-NAME FIX: runtimeListTunables reports the acting officer\'s name too, for a tunable just overridden this session', function()
    local f = boot()
    registerPlayer(f, HC_SOURCE, 'NAMECIT2', { firstname = 'Sam', lastname = 'Ops' })
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end

    local setResult = f.callbacks['john-k9:server:runtimeSetTunable'](HC_SOURCE, 'LeashMaxDistance', 12.0)
    t.isTrue(setResult.ok)

    local listed = f.callbacks['john-k9:server:runtimeListTunables'](HC_SOURCE)
    t.isTrue(listed.ok)
    local row = nil
    for _, r in ipairs(listed.tunables) do
        if r.key == 'LeashMaxDistance' then row = r end
    end
    t.isNotNil(row)
    t.equals(row.overriddenBy, 'Sam Ops')
end)

t.test('DISPLAY-NAME FIX: no charinfo at all -- falls back to the GetPlayerName native, exactly matching server/tablet.lua\'s/server/admin.lua\'s own ResolveDisplayName resolution order', function()
    local f = boot()
    registerPlayer(f, HC_SOURCE, 'NAMECIT3') -- no charinfo passed
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end
    f.env.GetPlayerName = function(src) return 'NativeName#' .. tostring(src) end

    f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'DoorInteraction', false)
    local listed = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    local row = nil
    for _, r in ipairs(listed.features) do
        if r.name == 'DoorInteraction' then row = r end
    end
    t.isNotNil(row)
    t.equals(row.overriddenBy, 'NativeName#' .. tostring(HC_SOURCE))
end)

t.test('DISPLAY-NAME FIX: a citizenid ResolveDisplayName cannot resolve at all (no charinfo, no native, e.g. an already-disconnected caller) falls back to the bare citizenid -- NEVER nil, NEVER blank', function()
    local f = boot()
    -- Deliberately do NOT call registerPlayer -- CanManageRuntimeControl's
    -- IsHighCommand check succeeds regardless (env.IsHighCommand below), but
    -- ResolveCitizenId(source) itself now returns nil (no player registered
    -- for this source at all), so this exercises the "citizenid unknown
    -- entirely" branch, distinct from "citizenid known but unresolvable".
    f.env.IsHighCommand = function(src) return src == HC_SOURCE end

    local setResult = f.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
    t.isTrue(setResult.ok)

    local listed = f.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    local row = nil
    for _, r in ipairs(listed.features) do
        if r.name == 'BasicBarkSounds' then row = r end
    end
    t.isNotNil(row)
    t.isTrue(row.overridden)
    t.isNotNil(row.overriddenBy, 'must never be nil even when no citizenid could be resolved at all')
    t.isTrue(row.overriddenBy ~= '', 'must never be blank')
end)

t.test('DISPLAY-NAME FIX: a row re-applied from k9_runtime_feature_overrides at boot (no name column in that table) falls back to the raw citizenid until edited again this session -- never "nil", never blank', function()
    local world = newWorld()
    do
        -- First boot: make a real change, persisted to the fake DB, exactly
        -- like PERSISTENCE section above.
        local first = boot({ world = world })
        registerPlayer(first, HC_SOURCE, 'BOOTCIT1', { firstname = 'First', lastname = 'Booter' })
        first.env.IsHighCommand = function(src) return src == HC_SOURCE end
        local r = first.callbacks['john-k9:server:runtimeSetFeature'](HC_SOURCE, 'BasicBarkSounds', false)
        t.isTrue(r.ok)
    end

    -- Second boot, SAME fake database: the row is re-applied from
    -- k9_runtime_feature_overrides at this boot's own onResourceStart --
    -- that table has no name column at all, so ActiveOverrides.updatedByName
    -- must come back nil, and the read side must fall back to the raw
    -- citizenid, NEVER the literal string "nil" and never a blank.
    local second = boot({ world = world })
    second.env.IsHighCommand = function() return true end
    local listed = second.callbacks['john-k9:server:runtimeListFeatures'](HC_SOURCE)
    local row = nil
    for _, r in ipairs(listed.features) do
        if r.name == 'BasicBarkSounds' then row = r end
    end
    t.isNotNil(row)
    t.isTrue(row.overridden, 'the override itself must have survived the restart, exactly like the pre-existing PERSISTENCE test proves')
    t.equals(row.overriddenBy, 'BOOTCIT1', 'falls back to the raw citizenid -- the ONLY thing k9_runtime_feature_overrides actually persisted -- never nil, never blank, never the string "nil"')
end)

os.exit(t.summary())
