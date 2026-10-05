--[[
    tests/findalert_spec.lua

    Direct, black-box tests of server/findalert.lua AND client/findalert.lua
    (PROJECT_HISTORY.md §1, "Make finds feel like a real alert, not a pop-up
    message") against the REAL, unmodified production files -- both loaded
    into their own independent sandboxes in this ONE spec file (this
    feature's file-ownership allowance for this pass was exactly these two
    production files plus this single test file).

    Config IS SYNTHETIC (hand-built here), NOT loaded from the real
    config.lua -- same convention tests/coopsearchbonus_spec.lua's own
    fixture already establishes for the identical reason: config.lua is
    owned/edited by a different agent concurrently this session, so this
    file must not depend on its real, current content to stay green. Every
    field referenced below matches EXACTLY what this feature's own request
    to main asks config.lua to contain (Config.Features.FindAlerts,
    Config.FindAlerts.reactionsByAlertTier, Config.FindAlerts.
    reactOnTrackArrival) -- see server/findalert.lua's/client/findalert.lua's
    own header comments for the authoritative shape.

    PER-PERSON FEATURE CONTROL FIXTURE CHOICE (added alongside
    server/findalert.lua's own IsFindAlertsPermittedForCitizenId this pass):
    the fixture's Config.FeatureControl.RequireGrant.FindAlerts defaults to
    FALSE (not listed) UNLESS a test opts in via `requireGrantListed`. This
    was a deliberate choice, not an oversight -- every pre-existing test in
    this file is testing the REACTION logic (tier lookup, cooldown sharing,
    online-resolution, HasK9Access) and has nothing to do with the
    per-person grant/block mechanism; forcing every one of them to also
    grant 'feature.FindAlerts' the way tests/pursuitsprint_spec.lua's own
    fixture does (requireGrantListed defaults to true there, so EVERY
    single dispatch call in that file grants explicitly) would bury the
    thing each test is actually about under boilerplate unrelated to it.
    Instead, per-person resolution gets its OWN dedicated section below
    ("PER-PERSON FEATURE CONTROL"), mirroring pursuitsprint_spec.lua's own
    dedicated section for the identical steps 2-4, with RequireGrant
    explicitly turned on only there. `setPlayerOnline` still ALWAYS
    registers a resolvable citizenid for forward (src -> citizenid) lookups
    too (see exportsStub.GetPlayer below) -- IsFindAlertsPermittedForCitizenId
    fails CLOSED with no citizenid at all, matching
    server/pursuitsprint.lua's own identical fail-closed behavior, so every
    test that expects a reaction to actually fire must resolve one.

    SERVER SECTION loads the REAL server/cooldowns.lua (NewCooldown is
    called at server/findalert.lua's own file-load time) plus the REAL
    server/findalert.lua. CLIENT SECTION loads only the REAL
    client/findalert.lua (it has no file-load-time dependency on any other
    production file -- every cross-file call, e.g. PlaySoundOnNetworkEntity,
    is a runtime call inside the event handler, stubbed directly here rather
    than loading the real client/main.lua).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ============================================================================
-- SERVER: server/findalert.lua
-- ============================================================================

--- @param opts { findAlerts: boolean?, scentTracking: boolean?, reactOnTrackArrival: boolean?,
---   requireGrantListed: boolean (default false) -- Config.FeatureControl.RequireGrant.FindAlerts
---   withHasPermission: boolean (default true) -- whether HasPermission exists in the sandbox at all
--- }?
--- @return table fixture
local function newServerFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local triggeredClientEvents = {}
    local function TriggerClientEvent(eventName, targetSrc, ...)
        triggeredClientEvents[#triggeredClientEvents + 1] = { eventName = eventName, targetSrc = targetSrc, args = { ... } }
    end

    -- DISCOVERABILITY FIX (this pass) -- server/findalert.lua now sends a
    -- direct NotifyPlayer for a CONFIRMED block/not-granted denial (never
    -- for the pre-existing silent branches -- see that file's own updated
    -- comment). Not previously stubbed at all, since the production file
    -- never called it before this pass.
    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    -- playerByCitizenId indexes by citizenid (existing, reverse-resolution
    -- use -- ResolveOnlineSourceForCitizenid); playerBySrc indexes the SAME
    -- objects by src (NEW, forward-resolution use --
    -- IsFindAlertsPermittedForCitizenId's caller, `exports.qbx_core:
    -- GetPlayer(targetSrc)`). Both are populated together by
    -- setPlayerOnline below so every existing call site keeps working
    -- unchanged.
    local playerByCitizenId = {}
    local playerBySrc = {}
    local exportsStub = {
        qbx_core = {
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId[citizenid] end,
            GetPlayer = function(_self, src) return playerBySrc[src] end,
        },
    }

    local accessBySource = {}
    local function HasK9Access(src) return accessBySource[src] == true end

    -- Per-person feature control -- mirrors tests/pursuitsprint_spec.lua's
    -- own permissionGrants/defaultHasPermission shape exactly.
    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local capturedPrints = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
    end

    local Config = {
        Features = {
            FindAlerts        = opts.findAlerts ~= false,
            ScentTracking     = opts.scentTracking ~= false,
            BloodTracking     = false,
            GunpowderSniffing = false,
        },
        FindAlerts = {
            reactionsByAlertTier = {
                whine           = { sit = true, sound = 'Bark_Alert' },
                aggressive_bark = { sit = true, sound = 'Bark_Aggressive' },
            },
            reactOnTrackArrival = opts.reactOnTrackArrival ~= false,
        },
        FeatureControl = {
            RequireGrant = { FindAlerts = opts.requireGrantListed == true },
        },
    }

    local overrides = {
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        exports = exportsStub,
        HasK9Access = HasK9Access,
        Config = Config,
        print = printStub,
    }
    if opts.withHasPermission ~= false then
        overrides.HasPermission = defaultHasPermission
    end

    local env = Sandbox.newEnv(overrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/findalert.lua', env)

    return {
        Config = Config,
        triggeredClientEvents = triggeredClientEvents,
        notifyCalls = notifyCalls,
        capturedPrints = capturedPrints,
        permissionCalls = permissionCalls,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setPlayerOnline = function(citizenid, src)
            local player = { PlayerData = { citizenid = citizenid, source = src } }
            playerByCitizenId[citizenid] = player
            playerBySrc[src] = player
        end,
        setOffline = function(citizenid)
            local player = playerByCitizenId[citizenid]
            if player then playerBySrc[player.PlayerData.source] = nil end
            playerByCitizenId[citizenid] = nil
        end,
        setAccess = function(src, allowed) accessBySource[src] = allowed end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,

        fireSearchCompleted = function(searcherCitizenid, searcherJob, targetType, result, totalWeightOrNil, alertTierOrNil)
            local handler = assert(
                (eventHandlers['john-k9:events:searchCompleted'] or {})[1],
                'server/findalert.lua did not register a john-k9:events:searchCompleted handler'
            )
            handler(searcherCitizenid, searcherJob, targetType, result, totalWeightOrNil, alertTierOrNil)
        end,

        fireTrackArrival = function(sourceValue)
            local handler = assert(
                (eventHandlers['john-k9:server:reportTrackSourceArrival'] or {})[1],
                'server/findalert.lua did not register a john-k9:server:reportTrackSourceArrival handler'
            )
            env.source = sourceValue
            handler()
        end,
    }
end

-- ----------------------------------------------------------------------
-- searchCompleted: happy path + reaction lookup gating
-- ----------------------------------------------------------------------

t.test('server: happy path -- an online, access-holding searcher gets exactly one unicast playFindAlertReaction with the real alertTier', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-1', 501)
    f.setAccess(501, true)

    f.fireSearchCompleted('CITIZEN-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 1)
    t.equals(f.triggeredClientEvents[1].eventName, 'john-k9:client:playFindAlertReaction')
    t.equals(f.triggeredClientEvents[1].targetSrc, 501)
    t.equals(f.triggeredClientEvents[1].args[1], 'aggressive_bark')
end)

t.test('server: search_failed (alertTier nil) never reacts', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-2', 502)
    f.setAccess(502, true)

    f.fireSearchCompleted('CITIZEN-2', 'police', 'vehicle', 'search_failed', nil, nil)

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server: a clean result (alertTier == "clean") never reacts -- no entry in reactionsByAlertTier by design', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-3', 503)
    f.setAccess(503, true)

    f.fireSearchCompleted('CITIZEN-3', 'police', 'vehicle', 'clean', 0, 'clean')

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server: an unrecognized/future alertTier never reacts -- fail closed, never a guessed default', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-4', 504)
    f.setAccess(504, true)

    f.fireSearchCompleted('CITIZEN-4', 'police', 'vehicle', 'found', 500, 'some_future_tier')

    t.equals(#f.triggeredClientEvents, 0)
end)

-- ----------------------------------------------------------------------
-- ABSOLUTE DENY / gating
-- ----------------------------------------------------------------------

t.test('server: Config.Features.FindAlerts = false denies outright, even for a valid tier + online + access', function()
    local f = newServerFixture({ findAlerts = false })
    f.setPlayerOnline('CITIZEN-5', 505)
    f.setAccess(505, true)

    f.fireSearchCompleted('CITIZEN-5', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server: no reaction when HasK9Access denies, and the denial does not consume the cooldown (a later legitimate call still succeeds)', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-6', 506)
    f.setAccess(506, false)

    f.fireSearchCompleted('CITIZEN-6', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 0, 'access denied -- no reaction')

    f.setAccess(506, true)
    f.fireSearchCompleted('CITIZEN-6', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 1, 'a denied attempt must not have consumed the cooldown for the legitimate one right after it')
end)

t.test('server: no reaction, and no crash, when the searcher is not currently online', function()
    local f = newServerFixture()
    -- CITIZEN-7 never registered via setPlayerOnline.
    local ok = pcall(f.fireSearchCompleted, 'CITIZEN-7', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.isTrue(ok)
    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server: malformed payload (non-string citizenid) is rejected defensively, no crash, no reaction', function()
    local f = newServerFixture()
    local ok = pcall(f.fireSearchCompleted, 12345, 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.isTrue(ok)
    t.equals(#f.triggeredClientEvents, 0)
    t.equals(#f.capturedPrints, 0, 'a clean, handled early-return must not print an error line -- only a genuine throw does')
end)

-- ----------------------------------------------------------------------
-- Cooldown -- per-source, shared across BOTH trigger paths
-- ----------------------------------------------------------------------

t.test('server: the reaction cooldown throttles rapid repeats for the SAME source, then allows again once elapsed', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-8', 508)
    f.setAccess(508, true)

    f.setNow(0)
    f.fireSearchCompleted('CITIZEN-8', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 1)

    f.setNow(500) -- well within the 1500ms cooldown
    f.fireSearchCompleted('CITIZEN-8', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 1, 'a second reaction within the cooldown window must be suppressed')

    f.setNow(1600) -- past the cooldown
    f.fireSearchCompleted('CITIZEN-8', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 2, 'once the cooldown has genuinely elapsed, the reaction must fire again')
end)

t.test('server: the cooldown is keyed per-source -- a different searcher is never blocked by another one\'s recent reaction', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-9A', 509)
    f.setPlayerOnline('CITIZEN-9B', 510)
    f.setAccess(509, true)
    f.setAccess(510, true)

    f.setNow(0)
    f.fireSearchCompleted('CITIZEN-9A', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    f.fireSearchCompleted('CITIZEN-9B', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 2, 'two independent sources, both within the SAME instant, must both react')
end)

-- ----------------------------------------------------------------------
-- reportTrackSourceArrival -- ADDITIONAL consumer, no citizenid resolution
-- needed (uses the event's own real `source` directly)
-- ----------------------------------------------------------------------

t.test('server: reportTrackSourceArrival reacts with the "aggressive_bark" tier for the real event source, when eligible', function()
    local f = newServerFixture()
    f.setAccess(701, true)
    f.setPlayerOnline('CITIZEN-701', 701) -- resolvable citizenid required for the per-person feature-control check

    f.fireTrackArrival(701)

    t.equals(#f.triggeredClientEvents, 1)
    t.equals(f.triggeredClientEvents[1].targetSrc, 701)
    t.equals(f.triggeredClientEvents[1].args[1], 'aggressive_bark')
end)

t.test('server: reportTrackSourceArrival does nothing when Config.FindAlerts.reactOnTrackArrival is false', function()
    local f = newServerFixture({ reactOnTrackArrival = false })
    f.setAccess(702, true)

    f.fireTrackArrival(702)

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server: reportTrackSourceArrival does nothing when none of ScentTracking/BloodTracking/GunpowderSniffing are enabled', function()
    local f = newServerFixture({ scentTracking = false }) -- Blood/Gunpowder already false by default in this fixture
    f.setAccess(703, true)

    f.fireTrackArrival(703)

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server: reportTrackSourceArrival and searchCompleted share ONE cooldown bucket per source -- one path can throttle the other', function()
    local f = newServerFixture()
    f.setPlayerOnline('CITIZEN-10', 704)
    f.setAccess(704, true)

    f.setNow(0)
    f.fireSearchCompleted('CITIZEN-10', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 1)

    f.setNow(200) -- within the 1500ms cooldown
    f.fireTrackArrival(704)
    t.equals(#f.triggeredClientEvents, 1, 'the track-arrival path must be throttled by the search path\'s own very recent reaction on the same source')

    f.setNow(1600)
    f.fireTrackArrival(704)
    t.equals(#f.triggeredClientEvents, 2, 'once the shared cooldown elapses, the track-arrival path fires normally')
end)

t.test('server: reportTrackSourceArrival never reacts without HasK9Access, no crash', function()
    local f = newServerFixture()
    f.setAccess(705, false)

    local ok = pcall(f.fireTrackArrival, 705)

    t.isTrue(ok)
    t.equals(#f.triggeredClientEvents, 0)
end)

-- ----------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL -- Config.FeatureControl.RequireGrant's
-- documented 4-step resolution (steps 2-4; step 1, Config.Features.
-- FindAlerts, is already covered above), keyed on the K9 the reaction is
-- dispatched TO (targetSrc / the searcher's own citizenid) -- mirrors
-- tests/pursuitsprint_spec.lua's own "Per-person feature control" section.
-- ----------------------------------------------------------------------

t.test('grant_required: RequireGrant.FindAlerts = true + no grant held -- denied even though HasK9Access is true and the tier/online checks all pass', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-BLOCKED-1', 801)
    f.setAccess(801, true)
    -- deliberately NOT granted

    f.fireSearchCompleted('CITIZEN-BLOCKED-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('RequireGrant.FindAlerts = true + an active feature.FindAlerts grant -- allowed', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-GRANTED-1', 802)
    f.setAccess(802, true)
    f.grantPermission('CITIZEN-GRANTED-1', 'feature.FindAlerts', true)

    f.fireSearchCompleted('CITIZEN-GRANTED-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 1)
end)

t.test('BLOCK ALWAYS WINS: an explicit block.FindAlerts denies even a citizenid who ALSO holds an active feature.FindAlerts grant, with the global flag still on', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-BLOCKED-2', 803)
    f.setAccess(803, true)
    f.grantPermission('CITIZEN-BLOCKED-2', 'feature.FindAlerts', true)
    f.grantPermission('CITIZEN-BLOCKED-2', 'block.FindAlerts', true)

    f.fireSearchCompleted('CITIZEN-BLOCKED-2', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('BLOCK STILL APPLIES even when NOT listed in RequireGrant (step 2 fires independently of step 3)', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.setPlayerOnline('CITIZEN-BLOCKED-3', 804)
    f.setAccess(804, true)
    f.grantPermission('CITIZEN-BLOCKED-3', 'block.FindAlerts', true)

    f.fireSearchCompleted('CITIZEN-BLOCKED-3', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('RequireGrant.FindAlerts = false (not listed) -- default ALLOW, no grant needed, matching config.lua\'s own documented step 4', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.setPlayerOnline('CITIZEN-DEFAULT-1', 805)
    f.setAccess(805, true)
    -- deliberately NOT granted -- must still succeed since it is not listed

    f.fireSearchCompleted('CITIZEN-DEFAULT-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 1)
end)

t.test('server/permissions.lua entirely absent (HasPermission not even defined): RequireGrant-listed feature fails CLOSED (deny), never open', function()
    local f = newServerFixture({ requireGrantListed = true, withHasPermission = false })
    f.setPlayerOnline('CITIZEN-NOPERM-1', 806)
    f.setAccess(806, true)

    local ok = pcall(f.fireSearchCompleted, 'CITIZEN-NOPERM-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.isTrue(ok, 'a missing HasPermission must never error the handler')
    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('server/permissions.lua entirely absent + feature NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newServerFixture({ requireGrantListed = false, withHasPermission = false })
    f.setPlayerOnline('CITIZEN-NOPERM-2', 807)
    f.setAccess(807, true)

    f.fireSearchCompleted('CITIZEN-NOPERM-2', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 1)
end)

t.test('a citizenid that cannot be resolved at all (targetSrc not registered with exports.qbx_core:GetPlayer) fails CLOSED, even with RequireGrant off and HasK9Access true', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.setAccess(808, true)
    -- deliberately no setPlayerOnline call for source 808 -- GetPlayer(808) resolves to nil

    local ok = pcall(f.fireTrackArrival, 808)

    t.isTrue(ok, 'an unresolvable citizenid must be a fail-closed no-op, never a crash')
    t.equals(#f.triggeredClientEvents, 0)
end)

t.test('a BLOCKED/no-grant reaction never consumes the shared per-source cooldown -- a later legitimate reaction on the SAME source still fires (no unbounded side effect from a denied attempt)', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-COOLDOWN-1', 809)
    f.setAccess(809, true)
    -- deliberately NOT granted for the first attempt

    f.setNow(0)
    f.fireSearchCompleted('CITIZEN-COOLDOWN-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 0, 'denied for lack of a grant')

    -- Grant it, then retry almost immediately (well within the 1500ms
    -- reaction cooldown) -- if the earlier denial had wrongly consumed the
    -- cooldown, this would still be throttled.
    f.grantPermission('CITIZEN-COOLDOWN-1', 'feature.FindAlerts', true)
    f.setNow(100)
    f.fireSearchCompleted('CITIZEN-COOLDOWN-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.triggeredClientEvents, 1, 'a denied attempt must never have spent the cooldown budget of the legitimate one right after it')
end)

-- ----------------------------------------------------------------------
-- DISCOVERABILITY FIX (this pass) -- a CONFIRMED block/not-granted denial
-- now sends a direct, distinct NotifyPlayer -- see IsFindAlertsPermittedForCitizenId's
-- own doc comment and FIND_ALERT_DENY_MESSAGES' declaration comment in
-- server/findalert.lua for why every OTHER silent branch (feature off, no
-- HasK9Access, unresolvable citizenid, unmapped tier) is deliberately left
-- untouched.
-- ----------------------------------------------------------------------

t.test('grant_required denial now also sends a distinct, actionable NotifyPlayer naming FindAlerts and High Command', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-NOTIFY-1', 901)
    f.setAccess(901, true)
    -- deliberately NOT granted

    f.fireSearchCompleted('CITIZEN-NOTIFY-1', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.triggeredClientEvents, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].target, 901)
    t.equals(f.notifyCalls[1].description, locale('findalert.not_granted'))
    t.equals(f.notifyCalls[1].notifyType, 'error')
end)

t.test('an explicit block sends the DIFFERENT blocked message, never the not_granted one', function()
    local f = newServerFixture({ requireGrantListed = false })
    f.setPlayerOnline('CITIZEN-NOTIFY-2', 902)
    f.setAccess(902, true)
    f.grantPermission('CITIZEN-NOTIFY-2', 'block.FindAlerts', true)

    f.fireSearchCompleted('CITIZEN-NOTIFY-2', 'police', 'vehicle', 'found', 250, 'aggressive_bark')

    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('findalert.blocked'))
    t.isTrue(f.notifyCalls[1].description ~= locale('findalert.not_granted'), 'blocked and not_granted must read as two different, actionable messages, not one collapsed generic denial')
end)

t.test('the denial-notify reminder is throttled independently of the reaction cooldown -- repeated denied searches do not spam a notification every time', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-NOTIFY-3', 903)
    f.setAccess(903, true)

    f.setNow(0)
    f.fireSearchCompleted('CITIZEN-NOTIFY-3', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.notifyCalls, 1)

    f.setNow(2000) -- past FindAlertReactionCooldown's 1500ms, but nowhere near the 5-minute denial-notify reminder
    f.fireSearchCompleted('CITIZEN-NOTIFY-3', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.notifyCalls, 1, 'a second denied attempt shortly after the first must not resend the reminder')

    f.setNow(300001) -- past the 5-minute reminder throttle
    f.fireSearchCompleted('CITIZEN-NOTIFY-3', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.notifyCalls, 2, 'once the reminder throttle genuinely elapses, the player is reminded again')
end)

t.test('no HasK9Access and an unresolvable citizenid stay silent -- no NotifyPlayer at all, matching this file\'s established silent-no-op posture for those two cases', function()
    local f = newServerFixture({ requireGrantListed = true })
    f.setPlayerOnline('CITIZEN-NOTIFY-4', 904)
    f.setAccess(904, false)

    f.fireSearchCompleted('CITIZEN-NOTIFY-4', 'police', 'vehicle', 'found', 250, 'aggressive_bark')
    t.equals(#f.notifyCalls, 0, 'no HasK9Access must stay silent')

    f.setAccess(905, true)
    -- deliberately no setPlayerOnline for 905 -- reportTrackSourceArrival's own `source` cannot resolve a citizenid
    f.fireTrackArrival(905)
    t.equals(#f.notifyCalls, 0, 'an unresolvable citizenid must stay silent, not guess a message')
end)

-- ============================================================================
-- CLIENT: client/findalert.lua
-- ============================================================================

--- @param opts { findAlerts: boolean?, reactions: table?, removeFindAlertsConfig: boolean? }?
--- @return table fixture
local function newClientFixture(opts)
    opts = opts or {}

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local myPed = 1
    local function PlayerPedId() return myPed end

    local isDead = false
    local function IsEntityDead(_ped) return isDead end

    local inVehicle = false
    local function IsPedInAnyVehicle(_ped, _atGetIn) return inVehicle end

    -- Identity stub: this fixture sets `modelHash` directly to whichever
    -- MODEL NAME STRING a test wants GetEntityModel() to report, and
    -- GetHashKey() is the identity function -- so
    -- K9_FIND_ALERT_SIT_SCENARIO_BY_MODEL_HASH ends up keyed by the plain
    -- model-name strings themselves, letting tests address entries by name
    -- ('a_c_shepherd', etc.) without needing to reproduce a real hash.
    local modelHash = 'unmapped_model'
    local function GetEntityModel(_ped) return modelHash end
    local function GetHashKey(name) return name end

    local clearCalls = 0
    local function ClearPedTasksImmediately(_ped) clearCalls = clearCalls + 1 end

    local scenarioCalls = {}
    local function TaskStartScenarioInPlace(_ped, scenarioName, _startNow, _playEnter)
        scenarioCalls[#scenarioCalls + 1] = scenarioName
    end

    local function NetworkGetNetworkIdFromEntity(ped) return 9000 + ped end

    local soundCalls = {}
    local function PlaySoundOnNetworkEntity(netId, soundName)
        soundCalls[#soundCalls + 1] = { netId = netId, soundName = soundName }
    end

    -- NOTE: deliberately NOT `Config.FindAlerts = opts.removeFindAlertsConfig
    -- and nil or {...}` -- that's the classic Lua `x and nil or y` footgun:
    -- since `nil` is itself falsy, `true and nil` already evaluates to `nil`,
    -- which then falls through to `or {...}` regardless of
    -- removeFindAlertsConfig's value, silently defeating the whole point of
    -- this option. An explicit `if` avoids it.
    local Config = {
        Features = { FindAlerts = opts.findAlerts ~= false },
    }
    if not opts.removeFindAlertsConfig then
        Config.FindAlerts = {
            reactionsByAlertTier = opts.reactions or {
                whine           = { sit = true, sound = 'Bark_Alert' },
                aggressive_bark = { sit = true, sound = 'Bark_Aggressive' },
            },
        }
    end

    local env = Sandbox.newEnv({
        RegisterNetEvent = RegisterNetEvent,
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        GetEntityModel = GetEntityModel,
        GetHashKey = GetHashKey,
        ClearPedTasksImmediately = ClearPedTasksImmediately,
        TaskStartScenarioInPlace = TaskStartScenarioInPlace,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        PlaySoundOnNetworkEntity = PlaySoundOnNetworkEntity,
        Config = Config,
    })

    Sandbox.loadInto('../client/findalert.lua', env)

    return {
        Config = Config,
        setDead = function(v) isDead = v end,
        setInVehicle = function(v) inVehicle = v end,
        setModel = function(m) modelHash = m end,
        clearCallCount = function() return clearCalls end,
        scenarioCalls = scenarioCalls,
        soundCalls = soundCalls,
        ownPedNetId = function() return 9000 + myPed end,
        fire = function(sourceValue, alertTier)
            local handler = assert(
                netEventHandlers['john-k9:client:playFindAlertReaction'],
                'client/findalert.lua did not register a john-k9:client:playFindAlertReaction handler'
            )
            env.source = sourceValue
            handler(alertTier)
        end,
    }
end

-- ----------------------------------------------------------------------
-- Origin guard
-- ----------------------------------------------------------------------

t.test('client: source ~= 65535 (a forged local trigger) is rejected -- no sit pose, no sound', function()
    local f = newClientFixture()
    f.fire(1234, 'aggressive_bark')
    t.equals(f.clearCallCount(), 0)
    t.equals(#f.scenarioCalls, 0)
    t.equals(#f.soundCalls, 0)
end)

t.test('client: source == 65535 (a genuine server-sent trigger) is processed normally', function()
    local f = newClientFixture()
    f.fire(65535, 'aggressive_bark')
    t.equals(f.clearCallCount(), 1)
    t.equals(#f.scenarioCalls, 1)
    t.equals(#f.soundCalls, 1)
end)

-- ----------------------------------------------------------------------
-- Gating / lookup
-- ----------------------------------------------------------------------

t.test('client: Config.Features.FindAlerts = false denies outright even for a valid tier', function()
    local f = newClientFixture({ findAlerts = false })
    f.fire(65535, 'aggressive_bark')
    t.equals(f.clearCallCount(), 0)
    t.equals(#f.soundCalls, 0)
end)

t.test('client: an unrecognized alertTier (e.g. "clean", no entry by design) never reacts', function()
    local f = newClientFixture()
    f.fire(65535, 'clean')
    t.equals(f.clearCallCount(), 0)
    t.equals(#f.soundCalls, 0)
end)

t.test('client: a non-string alertTier (nil) is rejected defensively, no crash', function()
    local f = newClientFixture()
    local ok = pcall(f.fire, 65535, nil)
    t.isTrue(ok)
    t.equals(f.clearCallCount(), 0)
end)

t.test('client: a missing Config.FindAlerts table entirely degrades to a harmless no-op, never an error', function()
    local f = newClientFixture({ removeFindAlertsConfig = true })
    local ok = pcall(f.fire, 65535, 'aggressive_bark')
    t.isTrue(ok)
    t.equals(f.clearCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- Per-reaction sit/sound independence
-- ----------------------------------------------------------------------

t.test('client: reaction.sit == false plays no sit pose but still plays the sound', function()
    local f = newClientFixture({ reactions = { quiet_find = { sit = false, sound = 'Bark_Calm' } } })
    f.fire(65535, 'quiet_find')
    t.equals(f.clearCallCount(), 0, 'sit = false must never clear tasks/start a scenario')
    t.equals(#f.scenarioCalls, 0)
    t.equals(#f.soundCalls, 1)
    t.equals(f.soundCalls[1].soundName, 'Bark_Calm')
end)

t.test('client: reaction.sound absent plays the sit pose but no sound', function()
    local f = newClientFixture({ reactions = { silent_sit = { sit = true } } })
    f.fire(65535, 'silent_sit')
    t.equals(f.clearCallCount(), 1)
    t.equals(#f.scenarioCalls, 1)
    t.equals(#f.soundCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Own-death / own-vehicle guards
-- ----------------------------------------------------------------------

t.test('client: own-death guard -- a dead ped gets no sit pose and no sound at all', function()
    local f = newClientFixture()
    f.setDead(true)
    f.fire(65535, 'aggressive_bark')
    t.equals(f.clearCallCount(), 0)
    t.equals(#f.soundCalls, 0)
end)

t.test('client: own-vehicle guard -- a ped currently in a vehicle gets no sit pose and no sound at all', function()
    local f = newClientFixture()
    f.setInVehicle(true)
    f.fire(65535, 'aggressive_bark')
    t.equals(f.clearCallCount(), 0)
    t.equals(#f.soundCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Per-breed sit-scenario mapping -- verbatim parity with client/movement.lua's
-- own K9_SIT_SCENARIO_BY_MODEL_HASH, per this file's own header citation.
-- ----------------------------------------------------------------------

t.test('client: per-breed sit scenario mapping matches client/movement.lua\'s K9Sit() exactly for every mapped breed', function()
    local cases = {
        { model = 'a_c_shepherd',   scenario = 'WORLD_DOG_SITTING_SHEPHERD' },
        { model = 'a_c_rottweiler', scenario = 'WORLD_DOG_SITTING_ROTTWEILER' },
        { model = 'a_c_chop',       scenario = 'WORLD_DOG_SITTING_ROTTWEILER' },
        { model = 'a_c_husky',      scenario = 'WORLD_DOG_SITTING_RETRIEVER' },
    }
    for _, case in ipairs(cases) do
        local f = newClientFixture()
        f.setModel(case.model)
        f.fire(65535, 'aggressive_bark')
        t.equals(f.scenarioCalls[1], case.scenario, ('model %s must map to scenario %s'):format(case.model, case.scenario))
    end
end)

t.test('client: an unmapped/future model falls back to the default WORLD_DOG_SITTING_SHEPHERD scenario', function()
    local f = newClientFixture()
    f.setModel('some_future_dog_model')
    f.fire(65535, 'aggressive_bark')
    t.equals(f.scenarioCalls[1], 'WORLD_DOG_SITTING_SHEPHERD')
end)

-- ----------------------------------------------------------------------
-- Sound targets the LOCAL player's own ped/netId, never another entity
-- ----------------------------------------------------------------------

t.test('client: the sound is always played against the LOCAL player\'s own resolved netId', function()
    local f = newClientFixture()
    f.fire(65535, 'whine')
    t.equals(f.soundCalls[1].netId, f.ownPedNetId())
    t.equals(f.soundCalls[1].soundName, 'Bark_Alert')
end)

os.exit(t.summary())
