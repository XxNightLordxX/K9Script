--[[
    tests/clientvision_spec.lua

    Third client-side spec in this suite (tests/main_spec.lua is the
    worked example; tests/clientradial_spec.lua is the second). Direct,
    black-box tests of client/vision.lua against the REAL, unmodified
    production file: thermal/night vision's mutual exclusivity, the
    maintenance/cleanup thread's start-on-real-transition and
    self-termination lifecycle, the own-death and lost-access cleanup
    guards inside that thread, and the onResourceStop safety net.

    IMPORTANT CORRECTION TO THIS SPEC'S OWN TASK BRIEF -- READ BEFORE
    TRUSTING ANYTHING ELSE IN THIS FILE ABOUT "D3":
    the task this file was written under asked for a test proving "the
    `source ~= 65535` origin guard rejects a forged local trigger" in this
    file, with a comment noting that a green test here does not settle
    open decision D3 (DEVELOPER_REFERENCE.md -- formerly DECISIONS_NEEDED.md,
    merged 2026-08-25 -- the resource-wide question of
    whether the client-event origin check can fail open at the engine
    level). That premise does not hold for THIS file, and no such test
    exists below -- fabricating one would mean asserting behavior this
    file does not have. Verified directly, not assumed:
      - client/vision.lua's own header states outright, in its "EVENT/
        CALLBACK CONTRACT" section: "Phase 2: NONE. This file registers or
        triggers no network event or callback of any kind."
      - A literal grep of this file for `RegisterNetEvent`, `source`, and
        `65535` returns zero matches. There is no event handler here at
        all for a forged trigger to reach -- no `source` global is ever
        read, so there is nothing for a 65535 check to guard.
      - DEVELOPER_REFERENCE.md's own D3 write-up names the actual affected
        surface: client/combat.lua, client/medkit.lua, client/wellbeing.lua,
        client/partnership.lua, client/kennel.lua, client/fetch.lua,
        client/propattachment.lua, client/bonetool.lua, client/screenfx.lua,
        and client/main.lua (already covered by tests/main_spec.lua's own
        playBark section). client/vision.lua is not on that list, and
        reading it confirms why: it has no network-facing entry point of
        any kind to forge a trigger against in the first place -- both
        Toggle*Vision() functions are called ONLY from a local
        RegisterCommand/RegisterKeyMapping binding (an internal client
        input, not a network event), and the maintenance thread and
        onResourceStop handler below take no event payload at all.
    This is reported as a finding in this pass's own report (a factual
    mismatch in the task brief, not a defect in client/vision.lua) rather
    than worked around silently. What this file DOES test instead, in
    full, is everything else the brief asked for: mutual exclusivity, the
    maintenance thread's lifecycle, the own-death/lost-access cleanup
    guards, and onResourceStop.

    THREAD SIMULATION: uses Sandbox.newThreadRunner() (tests/fixtures/
    sandbox.lua) to step the maintenance thread's coroutine one pass at a
    time, wrapped by this fixture's own CreateThread so a test can also
    assert HOW MANY threads were ever created (the "starts only on a real
    transition" / "self-terminates, and a later toggle starts a genuinely
    NEW thread" claims both need that count, not just the ability to step
    an already-known single thread). See newVisionFixture()'s own comment
    on the exact step-by-step semantics of THIS specific thread body --
    its first statement is a plain assignment before the `while` loop even
    starts, not a `Wait(...)` the way DEVELOPER_REFERENCE.md's own generic
    stepping note assumes, so this file works out the precise resume
    boundaries for itself rather than leaning on that note uncritically.

    STUBBING EFFORT, reported honestly per this task's own instruction:
    every native this file touches is a simple boolean-flag toggle/getter
    (GetUsingseethrough/SetSeethrough, GetUsingnightvision/SetNightvision,
    IsEntityDead, PlayerPedId, GetCurrentResourceName) plus
    CreateThread/Wait/RegisterCommand/RegisterKeyMapping/AddEventHandler/
    lib.notify/locale -- all either already-established capturing-stub
    shapes from this suite's server-side specs or the exact
    Sandbox.newThreadRunner() utility built for this purpose. Nothing here
    needed disproportionate stubbing; this file more than holds up the
    "client files needing outsized stubbing" audit being stale, alongside
    tests/main_spec.lua and tests/clientradial_spec.lua.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- PENDING LOCALE KEY -- client/featureblocks.lua's own header ("LOCALE
-- KEYS THIS FILE NEEDS") and this pass's own report both REQUEST this key
-- from the locales/en.json owner; it has not landed there as of this
-- pass, and this spec file does not own that file either. Sandbox.locale()
-- deliberately asserts every key it is asked for actually exists (see its
-- own header comment) -- exactly the right behavior for every OTHER key
-- in this suite, but it would fail THIS spec's new block-teardown test for
-- a reason that has nothing to do with client/vision.lua's own logic being
-- correct: that test exercises the REAL StopCameraFeed('cameraFeed.feed_ended_blocked')
-- call this pass added, which is real production code, not a stub.
-- `localeAllowingPending` delegates every OTHER key to the real, strict
-- `locale` above unchanged -- only this one pending key gets a placeholder
-- instead of an assertion failure. DELETE this override (and
-- PENDING_LOCALE_KEYS) once locales/en.json actually carries this key --
-- Sandbox.locale will then answer it for real and this shim becomes dead
-- code.
local PENDING_LOCALE_KEYS = {
    ['cameraFeed.feed_ended_blocked'] = 'Camera feed ended -- High Command has blocked this ability for you.',
}
local function localeAllowingPending(key, ...)
    if PENDING_LOCALE_KEYS[key] then
        local value = PENDING_LOCALE_KEYS[key]
        if select('#', ...) > 0 then return value:format(...) end
        return value
    end
    return Sandbox.locale(key, ...)
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua (with
--- `opts.features` merged onto Config.Features BEFORE client/vision.lua
--- loads, since its RegisterCommand/RegisterKeyMapping calls are gated at
--- FILE-LOAD time -- same reasoning as clientradial_spec.lua's own
--- fixture) + the real client/vision.lua, plus a controllable/capturing
--- stand-in for every native it touches.
--- @param opts { features: table?, isOwnModelK9: boolean?, hasK9Access: boolean?, partnershipAvailable: boolean? }?
--- @return table fixture
local function newVisionFixture(opts)
    opts = opts or {}

    local isOwnModelK9 = opts.isOwnModelK9
    if isOwnModelK9 == nil then isOwnModelK9 = true end
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end
    local isEntityDead = false

    local function IsOwnModelK9() return isOwnModelK9 end
    local hasK9AccessCallCount = 0
    local function HasK9Access() hasK9AccessCallCount = hasK9AccessCallCount + 1; return hasK9Access end
    local function IsEntityDead(_ped) return isEntityDead end
    local function PlayerPedId() return 1 end

    -- ------------------------------------------------------------------
    -- CAMERA FEED fixture additions. Real client/vision.lua calls
    -- CanShowK9UI()/DenyK9UIAccess()/IsEntityModelK9() as bare resource-
    -- globals normally defined by client/main.lua -- this spec never loads
    -- that file (same reasoning IsOwnModelK9()/HasK9Access() above already
    -- establish: a controllable stand-in, not the real cross-file
    -- dependency), so they are stubbed here too, independently of the
    -- IsOwnModelK9()/HasK9Access() pair above (CanShowK9UI() is a DIFFERENT
    -- combinator in the real file, not derived from these two in THIS
    -- fixture -- tests that care about the real composition belong in
    -- tests/main_spec.lua, not here).
    -- ------------------------------------------------------------------
    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyK9UIAccessCallCount = 0
    local function DenyK9UIAccess() denyK9UIAccessCallCount = denyK9UIAccessCallCount + 1 end

    -- ------------------------------------------------------------------
    -- PER-PERSON BLOCK fixture additions (client/featureblocks.lua,
    -- REQUESTED). STUBBED here, exactly like CanShowK9UI/DenyK9UIAccess
    -- above -- this spec never loads the real client/featureblocks.lua
    -- file, matching this fixture's own established "controllable
    -- stand-in, not the real cross-file dependency" convention. Soft
    -- dependency shape: only added to `env` at all when
    -- `opts.featureBlocksAvailable` is true (default true unless a test
    -- explicitly asks for the "not loaded yet" fail-open case), mirroring
    -- `refreshPartnershipStateFromServerAvailable` above -- a MISSING key,
    -- not a stub returning false, is what reproduces
    -- client/featureblocks.lua genuinely not having loaded.
    -- ------------------------------------------------------------------
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end
    local denyK9FeatureBlockedCallCount = 0
    local function DenyK9FeatureBlocked() denyK9FeatureBlockedCallCount = denyK9FeatureBlockedCallCount + 1 end

    local isEntityModelK9 = false -- which role the PARTNER ped resolves as, for the eye-height-offset branch
    local function IsEntityModelK9(_entity) return isEntityModelK9 end

    -- Partnership soft dependency -- `refreshFn` being nil (the default)
    -- means client/partnership.lua's own top-of-file gate did not pass
    -- (Config.Features.HandlerPartnership false), so the resource-global
    -- is genuinely UNDEFINED, not a stub returning false -- this fixture
    -- reproduces that exact shape by simply never adding the key to `env`
    -- at all rather than adding a function that returns a "disabled"
    -- answer (see `refreshPartnershipStateFromServerAvailable` below).
    -- MUST be an `opts` input, not a post-construction setter: whether
    -- these two resource-globals are even ADDED to `env` is decided once,
    -- before Sandbox.loadInto('../client/vision.lua', env) runs -- a
    -- setter called AFTER newVisionFixture() has already returned would
    -- be too late to change what the production file's `type(...) ==
    -- 'function'` guard already saw at its own load time.
    local refreshPartnershipStateFromServerAvailable = opts.partnershipAvailable == true
    local isPartneredNowResult, partnerServerIdResult = false, nil
    local refreshCallCount = 0
    local function RefreshPartnershipStateFromServer()
        refreshCallCount = refreshCallCount + 1
        return isPartneredNowResult, partnerServerIdResult
    end
    local isPartnered = true
    local function IsPartnered() return isPartnered end

    local partnerPlayerIndex = 2 -- GetPlayerFromServerId's return; -1 simulates offline
    local function GetPlayerFromServerId(_serverId) return partnerPlayerIndex end
    local partnerPed = 999 -- GetPlayerPed's return; 0 simulates "not streamed in"
    local function GetPlayerPed(_player) return partnerPed end
    local partnerName = 'PartnerOfficer'
    local function GetPlayerName(_player) return partnerName end

    -- DoesEntityExist must answer for BOTH the local ped (id 1, always
    -- exists in this fixture -- StopCameraFeed()'s own unfreeze guard
    -- reads it) and the partner ped (configurable, id from `partnerPed`
    -- above) -- a single existence set, not two separate booleans, so a
    -- test cannot accidentally leave one stale relative to the other.
    local existingEntities = { [1] = true, [999] = true }
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    local createCamReturn = 42 -- 0 simulates CreateCam failure
    local createCamCalls = {}
    local function CreateCam(camName, active)
        createCamCalls[#createCamCalls + 1] = { camName = camName, active = active }
        return createCamReturn
    end
    local attachCamToEntityCalls = {}
    local function AttachCamToEntity(cam, entity, x, y, z, isRelative)
        attachCamToEntityCalls[#attachCamToEntityCalls + 1] = { cam = cam, entity = entity, x = x, y = y, z = z, isRelative = isRelative }
    end
    local setCamFovCalls = {}
    local function SetCamFov(cam, fov) setCamFovCalls[#setCamFovCalls + 1] = { cam = cam, fov = fov } end
    local entityRotation = { x = 11.0, y = 22.0, z = 33.0 }
    local function GetEntityRotation(_entity, _order) return entityRotation end
    local setCamRotCalls = {}
    local function SetCamRot(cam, x, y, z, order) setCamRotCalls[#setCamRotCalls + 1] = { cam = cam, x = x, y = y, z = z, order = order } end
    local setCamActiveCalls = {}
    local function SetCamActive(cam, active) setCamActiveCalls[#setCamActiveCalls + 1] = { cam = cam, active = active } end
    local renderScriptCamsCalls = {}
    local function RenderScriptCams(render, ease, easeTime, easeCoordsAnim, p4)
        renderScriptCamsCalls[#renderScriptCamsCalls + 1] = { render = render, ease = ease, easeTime = easeTime, easeCoordsAnim = easeCoordsAnim, p4 = p4 }
    end
    local camExists = true
    local function DoesCamExist(_cam) return camExists end
    local destroyCamCalls = {}
    local function DestroyCam(cam, bScriptHostCam) destroyCamCalls[#destroyCamCalls + 1] = { cam = cam, bScriptHostCam = bScriptHostCam } end
    local freezeEntityPositionCalls = {}
    local function FreezeEntityPosition(entity, toggle) freezeEntityPositionCalls[#freezeEntityPositionCalls + 1] = { entity = entity, toggle = toggle } end

    -- The two native toggle pairs -- state lives here, in the fixture, NOT
    -- re-implemented as a separate boolean the way this file's own header
    -- explicitly warns against for client/vision.lua ITSELF (its own
    -- comment: "the native's own getter is the source of truth, not a
    -- separately-tracked local boolean") -- this fixture plays the role of
    -- the REAL native/engine state, which the production file's getters
    -- read straight from.
    local seethrough, nightvision = false, false
    local setSeethroughCalls, setNightvisionCalls = {}, {}
    local function GetUsingseethrough() return seethrough end
    local function SetSeethrough(v) seethrough = v; setSeethroughCalls[#setSeethroughCalls + 1] = v end
    local function GetUsingnightvision() return nightvision end
    local function SetNightvision(v) nightvision = v; setNightvisionCalls[#setNightvisionCalls + 1] = v end

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    -- CreateThread wraps Sandbox.newThreadRunner()'s own CreateThread so
    -- this fixture can ALSO count how many threads were ever created --
    -- needed to prove EnsureVisionMaintenanceThreadRunning()'s own
    -- "already running -> no-op" guard, and later, that a stopped
    -- thread's guard resets so a FRESH transition starts a genuinely NEW
    -- one. runner.step() is exposed directly; see this fixture's own
    -- return table for the exact stepping semantics of the ONE thread
    -- body this file ever creates.
    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        runner.CreateThread(fn)
    end
    local function Wait(ms) runner.Wait(ms) end

    local registerCommandCalls = {}
    local function RegisterCommand(name, handler, restricted)
        registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler, restricted = restricted }
    end
    local registerKeyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        registerKeyMappingCalls[#registerKeyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    local RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return RESOURCE_NAME end
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local envTable = {
        IsOwnModelK9 = IsOwnModelK9,
        HasK9Access = HasK9Access,
        IsEntityDead = IsEntityDead,
        PlayerPedId = PlayerPedId,
        GetUsingseethrough = GetUsingseethrough,
        SetSeethrough = SetSeethrough,
        GetUsingnightvision = GetUsingnightvision,
        SetNightvision = SetNightvision,
        lib = { notify = lib_notify },
        CreateThread = CreateThread,
        Wait = Wait,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        IsEntityModelK9 = IsEntityModelK9,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerPed = GetPlayerPed,
        GetPlayerName = GetPlayerName,
        DoesEntityExist = DoesEntityExist,
        CreateCam = CreateCam,
        AttachCamToEntity = AttachCamToEntity,
        SetCamFov = SetCamFov,
        GetEntityRotation = GetEntityRotation,
        SetCamRot = SetCamRot,
        SetCamActive = SetCamActive,
        RenderScriptCams = RenderScriptCams,
        DoesCamExist = DoesCamExist,
        DestroyCam = DestroyCam,
        FreezeEntityPosition = FreezeEntityPosition,
    }
    if featureBlocksAvailable then
        envTable.IsK9FeatureBlocked = IsK9FeatureBlocked
        envTable.DenyK9FeatureBlocked = DenyK9FeatureBlocked
    end
    -- See this file's own top-of-file "PENDING LOCALE KEY" comment --
    -- delegates to the real, strict Sandbox.locale for every key except
    -- the one this pass's own new code path needs that has not landed in
    -- locales/en.json yet.
    envTable.locale = localeAllowingPending
    -- SOFT DEPENDENCY SHAPE (see the declaration comment above): only
    -- added to the env at all when `opts.partnershipAvailable` is true --
    -- a MISSING key, not a "returns false" stub, is what reproduces
    -- client/partnership.lua's own top-of-file gate returning early
    -- without ever defining these two resource-globals.
    if refreshPartnershipStateFromServerAvailable then
        envTable.RefreshPartnershipStateFromServer = RefreshPartnershipStateFromServer
        envTable.IsPartnered = IsPartnered
    end

    local env = Sandbox.newEnv(envTable)

    Sandbox.loadInto('../config.lua', env)

    -- THIS SPEC'S OWN FIXED BASELINE -- same reasoning and same real
    -- concurrency incident as tests/clientradial_spec.lua's own baseline
    -- (see that file's header): config.lua is edited by other agents
    -- while this suite runs, so this fixture pins ThermalVision/
    -- NightVision/CameraFeedPiP to a known value BEFORE applying
    -- `opts.features`, rather than trusting whatever config.lua's live
    -- defaults happen to be at the moment a given test runs. Same
    -- reasoning for `Config.CameraFeed` -- pinned to a known table
    -- REGARDLESS of whether config.lua has been given that table yet (see
    -- client/vision.lua's own GetCameraFeedConfig() fallback for the
    -- production-side half of this same defensiveness), so this suite's
    -- own assertions about exact fov/eye-height/toggleKey values passed to
    -- the CAM natives stay meaningful and stable either way.
    env.Config.Features.ThermalVision = false
    env.Config.Features.NightVision = false
    env.Config.Features.CameraFeedPiP = false
    env.Config.CameraFeed = { toggleKey = 'H', fov = 45.0, k9EyeHeightOffset = 0.6, handlerEyeHeightOffset = 1.5 }
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end

    Sandbox.loadInto('../client/vision.lua', env)

    return {
        env = env,
        Config = env.Config,
        notifyCalls = notifyCalls,
        setSeethroughCalls = setSeethroughCalls,
        setNightvisionCalls = setNightvisionCalls,
        registerCommandCalls = registerCommandCalls,
        registerKeyMappingCalls = registerKeyMappingCalls,
        resourceName = RESOURCE_NAME,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setIsEntityDead = function(v) isEntityDead = v end,
        hasK9AccessCallCount = function() return hasK9AccessCallCount end,
        isSeethroughActive = function() return seethrough end,
        isNightvisionActive = function() return nightvision end,
        --- Steps the (at most one, in this file) captured maintenance
        --- thread once. See this file's header + inline comments at each
        --- call site below for exactly what a given step number reaches --
        --- this thread's FIRST statement is a plain assignment before its
        --- `while` loop, not a `Wait(...)` the way DEVELOPER_REFERENCE.md's own
        --- generic note assumes, so step-by-step semantics here are worked
        --- out per-call rather than quoted wholesale from that note.
        step = function() runner.step() end,
        threadCreateCount = function() return threadCreateCount end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,

        -- CAMERA FEED fixture controls/inspectors
        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyK9UIAccessCallCount = function() return denyK9UIAccessCallCount end,
        setIsEntityModelK9 = function(v) isEntityModelK9 = v end,
        setRefreshResult = function(isPartneredNow, partnerServerId) isPartneredNowResult = isPartneredNow; partnerServerIdResult = partnerServerId end,
        refreshCallCount = function() return refreshCallCount end,
        setIsPartnered = function(v) isPartnered = v end,
        setPartnerPlayerIndex = function(v) partnerPlayerIndex = v end,
        setPartnerPed = function(v) partnerPed = v end,
        setEntityExists = function(entity, exists) existingEntities[entity] = exists or nil end,
        setPartnerName = function(v) partnerName = v end,
        setCreateCamReturn = function(v) createCamReturn = v end,
        createCamCalls = createCamCalls,
        attachCamToEntityCalls = attachCamToEntityCalls,
        setCamFovCalls = setCamFovCalls,
        setEntityRotation = function(v) entityRotation = v end,
        setCamRotCalls = setCamRotCalls,
        setCamActiveCalls = setCamActiveCalls,
        renderScriptCamsCalls = renderScriptCamsCalls,
        setCamExists = function(v) camExists = v end,
        destroyCamCalls = destroyCamCalls,
        freezeEntityPositionCalls = freezeEntityPositionCalls,

        -- PER-PERSON BLOCK fixture controls/inspectors
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        denyK9FeatureBlockedCallCount = function() return denyK9FeatureBlockedCallCount end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity
-- ----------------------------------------------------------------------

t.test('client/vision.lua exposes all four documented resource-globals', function()
    local f = newVisionFixture()
    t.isNotNil(f.env.ToggleThermalVision)
    t.isNotNil(f.env.ToggleNightVision)
    t.isNotNil(f.env.IsThermalVisionActive)
    t.isNotNil(f.env.IsNightVisionActive)
end)

-- ----------------------------------------------------------------------
-- IsThermalVisionActive / IsNightVisionActive -- thin wrappers, but with a
-- real coercion contract (`== true`) worth pinning: a native returning
-- anything other than the exact boolean `true` (nil, 0, "true") must read
-- back as `false`, never as a truthy-but-wrong value.
-- ----------------------------------------------------------------------

t.test('IsThermalVisionActive: reflects the underlying native exactly (false by default)', function()
    local f = newVisionFixture()
    t.isFalse(f.env.IsThermalVisionActive())
end)

-- DELIBERATE REVERSAL of what this test used to assert. It previously
-- pinned `== true`, i.e. a native returning 1 had to be read as "off".
-- That was the wrong way round, and this file's own history is the reason:
-- the getter underneath it was calling a native that does not exist
-- (IsSeethroughActive), so it returned nil forever and thermal vision could
-- never be switched OFF. A getter wrongly reporting "off" is exactly the
-- failure that produced.
--
-- Weigh the two readings against each other. If the native returns a real
-- boolean, as natives.json declares (GET_USINGSEETHROUGH, GRAPHICS,
-- 0x44B80ABAB9D80BD3), strict and lenient behave identically and the choice
-- does not matter. They only differ if it ever hands back 1/0 — and there
-- the strict reading silently recreates the bug just fixed, while the
-- lenient one is correct. One reading is never worse; the other is
-- sometimes catastrophic. So: anything non-nil and non-zero counts as on.
t.test('IsThermalVisionActive: a native returning 1 rather than boolean true still reads as ON -- the strict reading here is what let "cannot turn it off" hide', function()
    local f = newVisionFixture()
    f.env.GetUsingseethrough = function() return 1 end
    t.isTrue(f.env.IsThermalVisionActive(), '1 must mean on -- reading it as off is how a getter that never reports on goes unnoticed')
end)

t.test('IsThermalVisionActive: 0 and nil both read as OFF', function()
    local f = newVisionFixture()
    f.env.GetUsingseethrough = function() return 0 end
    t.isFalse(f.env.IsThermalVisionActive(), '0 must mean off')
    f.env.GetUsingseethrough = function() return nil end
    t.isFalse(f.env.IsThermalVisionActive(), 'nil -- what an unregistered native returns -- must mean off')
end)

t.test('IsNightVisionActive: reflects the underlying native exactly (false by default)', function()
    local f = newVisionFixture()
    t.isFalse(f.env.IsNightVisionActive())
end)

-- ----------------------------------------------------------------------
-- Access gate: IsOwnModelK9() ONLY -- per this file's own "RESOLVED
-- ACCESS-GATING DECISION," never CanShowK9UI().
-- ----------------------------------------------------------------------

t.test('ToggleThermalVision: not a K9 model -- denied with common.not_k9_model, native never touched', function()
    local f = newVisionFixture({ isOwnModelK9 = false })
    f.env.ToggleThermalVision()
    t.equals(#f.setSeethroughCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].title, locale('common.notify_title'))
    t.equals(f.notifyCalls[1].description, locale('common.not_k9_model'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('ToggleNightVision: not a K9 model -- denied with common.not_k9_model, native never touched', function()
    local f = newVisionFixture({ isOwnModelK9 = false })
    f.env.ToggleNightVision()
    t.equals(#f.setNightvisionCalls, 0)
    t.equals(f.notifyCalls[1].description, locale('common.not_k9_model'))
end)

t.test('ToggleThermalVision: a K9 model, currently off, turns ON -- SetSeethrough(true), an "on" notification, and the maintenance thread starts', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision()
    t.isTrue(f.isSeethroughActive())
    t.equals(f.notifyCalls[1].description, locale('vision.thermal_on'))
    -- 'info', not the old 'inform': ox_lib's REAL upstream
    -- `resource/interface/client/notify.lua` declares
    -- `---@alias NotificationType 'info' | 'warning' | 'success' | 'error'`
    -- -- 'inform' is not a member (it's a v3 leftover only remapped inside
    -- the deprecated `lib.defaultNotify` shim, which client/vision.lua's
    -- direct `lib.notify(...)` call never goes through).
    t.equals(f.notifyCalls[1].type, 'info')
    t.equals(f.threadCreateCount(), 1)
end)

t.test('ToggleThermalVision: a K9 model, currently ON, turns OFF -- SetSeethrough(false), an "off" notification, and NO new thread is created', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on (creates thread #1)
    f.env.ToggleThermalVision() -- off
    t.isFalse(f.isSeethroughActive())
    t.equals(f.notifyCalls[2].description, locale('vision.thermal_off'))
    t.equals(f.threadCreateCount(), 1, 'turning OFF must never call EnsureVisionMaintenanceThreadRunning at all')
end)

-- ----------------------------------------------------------------------
-- Mutual exclusivity -- DEVELOPER_REFERENCE.md §11.5's own confirmed judgment call:
-- turning one on forces the other off first.
-- ----------------------------------------------------------------------

t.test('mutual exclusivity: turning Thermal ON while Night is already active turns Night OFF first, then Thermal ON', function()
    local f = newVisionFixture()
    f.env.ToggleNightVision() -- night on
    t.isTrue(f.isNightvisionActive())

    f.env.ToggleThermalVision() -- thermal on -- must force night off first
    t.isTrue(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive(), 'thermal turning on must force night off -- the two are mutually exclusive')
end)

t.test('mutual exclusivity: turning Night ON while Thermal is already active turns Thermal OFF first, then Night ON', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- thermal on
    t.isTrue(f.isSeethroughActive())

    f.env.ToggleNightVision() -- night on -- must force thermal off first
    t.isTrue(f.isNightvisionActive())
    t.isFalse(f.isSeethroughActive())
end)

t.test('mutual exclusivity: turning Thermal ON when Night was never active never touches SetNightvision at all', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision()
    t.equals(#f.setNightvisionCalls, 0, 'EnsureOnlyOneVisionEffectActive must be a true no-op when the OTHER effect was never on')
end)

-- ----------------------------------------------------------------------
-- Maintenance thread lifecycle: starts only on a real ON transition,
-- self-terminates once both effects are off, and a LATER genuine
-- transition starts a fresh one (proving the guard actually reset).
--
-- STEPPING NOTES FOR THIS SPECIFIC THREAD BODY (see fixture header): the
-- thread's first statement is `local hadK9Access = HasK9Access()`, THEN
-- the `while` condition is checked, THEN (if true) the loop is entered
-- and `Wait(1000)` is the first statement INSIDE it. So:
--   step() call #1 -- resumes from the very start: runs the initial
--     HasK9Access() capture, evaluates the while-condition (true, since a
--     Toggle*Vision() call already turned an effect on before this
--     thread's body ever runs), enters the loop, and yields at Wait(1000).
--     This is the "prime" step -- it runs no branch logic yet.
--   step() call #2 (and onward, one per call) -- resumes AFTER Wait,
--     executes exactly one pass of the death/model/access-transition
--     branch, then re-checks the while-condition: if still true, it loops
--     back to Wait(1000) and yields again (ready for another step() to run
--     the NEXT pass); if now false (both effects were just cleared by
--     that same pass), it falls out of the loop, clears
--     visionMaintenanceThreadRunning, and the coroutine dies -- all within
--     that SAME step() call, with no further yield.
-- ----------------------------------------------------------------------

t.test('maintenance thread: does not exist at all before any vision effect is ever turned on', function()
    local f = newVisionFixture()
    t.equals(f.threadCreateCount(), 0)
end)

t.test('maintenance thread: own death clears BOTH effects, in a single pass, even though only one was on', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on; creates + primes reachable via step()
    f.step() -- step #1: prime (captures hadK9Access, enters loop, yields at Wait)

    f.setIsEntityDead(true)
    f.step() -- step #2: executes the death branch -> both natives forced false

    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive(), 'the death branch clears BOTH unconditionally, even though only thermal was ever on')
    t.equals(f.setSeethroughCalls[#f.setSeethroughCalls], false)
    t.equals(f.setNightvisionCalls[#f.setNightvisionCalls], false)
end)

t.test('maintenance thread: self-terminates once both effects are cleared -- a LATER toggle-on starts a genuinely NEW thread', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on -- thread #1
    t.equals(f.threadCreateCount(), 1)
    f.step() -- prime
    f.setIsEntityDead(true)
    f.step() -- clears both, while-condition now false -> thread exits, guard resets

    -- A fresh toggle-on AFTER the thread has exited must be able to start
    -- a SECOND, brand-new thread -- proving the
    -- `visionMaintenanceThreadRunning` guard actually reset to false when
    -- the old thread died, rather than staying stuck true forever.
    f.setIsEntityDead(false) -- alive again, so the new toggle actually sticks
    f.env.ToggleThermalVision() -- on again
    t.equals(f.threadCreateCount(), 2, 'a fresh ON transition after the previous thread self-terminated must start a NEW thread')
end)

t.test('maintenance thread: while an effect is still active (nothing cleared it), continuing to loop does NOT create a second thread -- EnsureVisionMaintenanceThreadRunning stays a no-op while the first thread is alive', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on -- thread #1
    f.env.ToggleNightVision() -- mutual exclusion turns thermal off, night on -- EnsureVisionMaintenanceThreadRunning() is called AGAIN here, but the thread is already running
    t.equals(f.threadCreateCount(), 1, 'the already-running guard must prevent a second thread from ever being created while the first is still alive')
end)

t.test('maintenance thread: model swap away from a K9 model (IsOwnModelK9 false) clears both effects, mirroring the death branch', function()
    local f = newVisionFixture()
    f.env.ToggleNightVision() -- on
    f.step() -- prime

    f.setIsOwnModelK9(false)
    f.step() -- executes the "not IsOwnModelK9()" branch

    t.isFalse(f.isNightvisionActive())
    t.isFalse(f.isSeethroughActive())
end)

t.test('maintenance thread: HasK9Access TRANSITION (true -> false) clears both effects', function()
    local f = newVisionFixture({ hasK9Access = true })
    f.env.ToggleThermalVision() -- on; hasK9Access is true at this moment
    f.step() -- prime: captures hadK9Access = true (HasK9Access() called once here)
    t.equals(f.hasK9AccessCallCount(), 1)

    f.setHasK9Access(false) -- access revoked between ticks
    f.step() -- executes the else-branch: hasK9Access now false, hadK9Access was true -> transition -> clear

    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
end)

t.test('maintenance thread: a player who NEVER had K9 access at all (false from the very start) is NOT force-cleared -- only a TRUE -> FALSE transition triggers the clear', function()
    local f = newVisionFixture({ hasK9Access = false })
    f.env.ToggleThermalVision() -- on; IsOwnModelK9 gate passes regardless of HasK9Access, per this file's own access-gating decision
    f.step() -- prime: captures hadK9Access = false
    f.step() -- pass #1 of the else-branch: hasK9Access still false, hadK9Access was false -> NOT a transition -> no clear
    f.step() -- pass #2, same result -- must remain stable, not clear on some later tick either

    t.isTrue(f.isSeethroughActive(), 'a player who never had access in the first place must keep their (IsOwnModelK9-gated) vision effect uncleared by this thread')
    t.equals(#f.setSeethroughCalls, 1, 'SetSeethrough must have been called exactly once (the original ToggleThermalVision turn-on) -- never again by the maintenance thread')
end)

-- ----------------------------------------------------------------------
-- onResourceStop -- forces both natives off unconditionally, matching
-- resourceName only.
-- ----------------------------------------------------------------------

t.test('onResourceStop: registers exactly one handler', function()
    local f = newVisionFixture()
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('onResourceStop: a stop event for a DIFFERENT resource is ignored -- neither native is touched', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on
    local callsBefore = #f.setSeethroughCalls
    f.fireResourceStop('some_other_resource')
    t.equals(#f.setSeethroughCalls, callsBefore, 'a different resource stopping must not touch this resource\'s vision state at all')
end)

t.test('onResourceStop: this resource stopping forces BOTH natives off unconditionally, even if only one was ever on', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- only thermal on
    t.isTrue(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())

    f.fireResourceStop(f.resourceName)
    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
    t.equals(f.setNightvisionCalls[#f.setNightvisionCalls], false, 'SetNightvision(false) must still be called even though night vision was never on this session -- a harmless idempotent no-op, per this file\'s own comment')
end)

t.test('onResourceStop: a harmless no-op when NEITHER effect was ever turned on', function()
    local f = newVisionFixture()
    local ok = pcall(f.fireResourceStop, f.resourceName)
    t.isTrue(ok)
    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
end)

-- ----------------------------------------------------------------------
-- Config-gated command + keybind REGISTRATION (not just behavior) -- each
-- flag independently gates its OWN RegisterCommand/RegisterKeyMapping
-- pair, per this file's own "the two flags are fully independent" comment.
--
-- COUNTS BELOW ADJUSTED, THIS PASS (vision merge, coder-architect): 'k9vision'
-- (the new merged cycle) registers a COMMAND + KEYMAPPING UNCONDITIONALLY,
-- regardless of either flag -- see this file's own "MERGED ENTRY POINT"
-- section below for why. Every count in this section is therefore +1
-- relative to before this pass; each test now explicitly excludes/asserts
-- around the k9vision entry rather than assuming the two OLD toggles are
-- the only thing this file ever registers.
-- ----------------------------------------------------------------------

--- Filters k9vision's own always-present command/keybind out of a raw
--- call-log array, so the tests below can keep asserting "how many OLD,
--- flag-gated registrations exist" without also having to recount k9vision
--- itself every time. `field` is 'name' for registerCommandCalls, or
--- 'commandName' for registerKeyMappingCalls.
--- @param calls table[]
--- @param field string
--- @return table[] filtered
local function excludingK9Vision(calls, field)
    local filtered = {}
    for _, call in ipairs(calls) do
        if call[field] ~= 'k9vision' then filtered[#filtered + 1] = call end
    end
    return filtered
end

t.test('both ThermalVision and NightVision false: zero OLD commands/key mappings are registered -- only the unconditional k9vision entry exists', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = false } })
    t.equals(#excludingK9Vision(f.registerCommandCalls, 'name'), 0)
    t.equals(#excludingK9Vision(f.registerKeyMappingCalls, 'commandName'), 0)
    t.equals(#f.registerCommandCalls, 1, 'k9vision itself is still registered')
    t.equals(#f.registerKeyMappingCalls, 1)
end)

t.test('NO SEPARATE THERMAL / NIGHT KEYS: with both modes on, only k9vision (I) is registered -- the K and J keys and their commands are gone (owner\'s choice)', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = true } })
    t.equals(#excludingK9Vision(f.registerCommandCalls, 'name'), 0)
    t.equals(#excludingK9Vision(f.registerKeyMappingCalls, 'commandName'), 0)
    -- The modes themselves still work -- the cycle and the K9 menu call them.
    f.env.ToggleThermalVision()
    t.isTrue(f.isSeethroughActive())
end)

-- ========================================================================
-- MERGED ENTRY POINT -- 'k9vision' / CycleVision() (vision merge,
-- coder-architect, this pass). See client/vision.lua's own "MERGED ENTRY
-- POINT" header for the full design writeup this section tests against.
-- ========================================================================

t.test('k9vision: registered UNCONDITIONALLY -- present even when BOTH ThermalVision and NightVision are false', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = false } })
    local found
    for _, call in ipairs(f.registerCommandCalls) do
        if call.name == 'k9vision' then found = call end
    end
    t.isNotNil(found, 'k9vision must exist even when neither underlying mode is available, matching k9track\'s own honest-degrade posture')

    local keyMapping
    for _, call in ipairs(f.registerKeyMappingCalls) do
        if call.commandName == 'k9vision' then keyMapping = call end
    end
    t.isNotNil(keyMapping)
    t.equals(keyMapping.defaultKey, 'I')
end)

t.test('CycleVision: both modes off -- notifies "no modes available", touches neither native', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = false } })
    f.env.CycleVision()
    t.equals(#f.setSeethroughCalls, 0)
    t.equals(#f.setNightvisionCalls, 0)
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('vision.no_modes_available'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

-- THE PINNED REQUIREMENT: "the cycle skips a mode whose feature flag is
-- off rather than landing on it." PROVEN BY BREAKING: deleting
-- IsVisionModeAvailable()'s `if not Config.Features[featureKey] then
-- return false end` line (client/vision.lua) turns this test red -- the
-- first press would land on 'night' (SetNightvision(true)) instead of
-- jumping straight to 'thermal', since the sequence would then wrongly
-- include a disabled mode.
t.test('CycleVision: NightVision off, ThermalVision on -- the cycle skips Night entirely, going straight Off -> Thermal -> Off', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = false } })

    f.env.CycleVision() -- Off -> (skip Night) -> Thermal
    t.isTrue(f.isSeethroughActive(), 'must land on Thermal, the only available mode')
    t.isFalse(f.isNightvisionActive(), 'must never land on the disabled Night mode even transiently')
    t.equals(#f.setNightvisionCalls, 0, 'a disabled mode must never even be asked to turn on')

    f.env.CycleVision() -- Thermal -> Off (2-length sequence: off, thermal)
    t.isFalse(f.isSeethroughActive())
end)

t.test('CycleVision: ThermalVision off, NightVision on -- the mirror image, cycling Off -> Night -> Off', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = true } })

    f.env.CycleVision()
    t.isTrue(f.isNightvisionActive())
    t.equals(#f.setSeethroughCalls, 0, 'a disabled mode must never even be asked to turn on')

    f.env.CycleVision()
    t.isFalse(f.isNightvisionActive())
end)

t.test('CycleVision: both modes on -- steps Off -> Night -> Thermal -> Off, exactly 3 stops, never landing on both at once', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = true } })

    f.env.CycleVision() -- Off -> Night
    t.isTrue(f.isNightvisionActive())
    t.isFalse(f.isSeethroughActive())

    f.env.CycleVision() -- Night -> Thermal (mutual exclusion turns Night off)
    t.isTrue(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())

    f.env.CycleVision() -- Thermal -> Off
    t.isFalse(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())

    f.env.CycleVision() -- Off -> Night again -- proves the cycle actually wraps, not a one-shot
    t.isTrue(f.isNightvisionActive())
end)

-- GATE-THE-STOP RULE, APPLIED TO THE CYCLE: "turning vision off works with
-- the feature flag off." A mode that was active when the cycle started
-- being pressed can go from available to disabled/blocked WHILE active
-- (a live tablet flip, a featureblocks push) -- the very next press must
-- still be able to turn it off, never strand the player in it.
t.test('CycleVision: NightVision turned off entirely WHILE it is active -- the very next press turns it off, never strands the player in it', function()
    local f = newVisionFixture({ features = { ThermalVision = false, NightVision = true } })
    f.env.CycleVision() -- Off -> Night
    t.isTrue(f.isNightvisionActive())

    -- Live flag flip -- NightVision is no longer an available cycle
    -- destination, but it is still the ACTIVE mode.
    f.Config.Features.NightVision = false

    f.env.CycleVision() -- must resolve straight to 'off', not error, not re-land on Night
    t.isFalse(f.isNightvisionActive(), 'a mode that just went unavailable while active must still be reachable to turn off on the very next press')
end)

t.test('CycleVision: ThermalVision gets feature-blocked WHILE it is active -- the very next press turns it off', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = false } })
    f.env.CycleVision() -- Off -> Thermal
    t.isTrue(f.isSeethroughActive())

    f.setBlocked('ThermalVision', true) -- live per-person block landed mid-use

    f.env.CycleVision()
    t.isFalse(f.isSeethroughActive(), 'a mode that just became blocked while active must still be reachable to turn off on the very next press')
    t.equals(f.denyK9FeatureBlockedCallCount(), 0, 'the turning-OFF path must never consult the block at all')
end)

t.test('CycleVision: IsOwnModelK9 becomes false WHILE a mode is active -- the very next press still turns it off (same gate-the-stop rule, the player-level gate this time)', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = false } })
    f.env.CycleVision() -- Off -> Thermal
    t.isTrue(f.isSeethroughActive())

    f.setIsOwnModelK9(false)

    f.env.CycleVision()
    t.isFalse(f.isSeethroughActive())
end)

t.test('CycleVision: a feature-blocked mode is skipped by the cycle just like a flag-off one, even though its Config.Features flag is still true', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = true } })
    f.setBlocked('NightVision', true) -- flag is true, but blocked

    f.env.CycleVision() -- Off -> (skip blocked Night) -> Thermal
    t.isTrue(f.isSeethroughActive())
    t.equals(#f.setNightvisionCalls, 0, 'a blocked mode must never even be asked to turn on, same as a flag-off one')
end)

t.test('EXPLICIT MODE SELECTION STILL WORKS through ToggleThermalVision()/ToggleNightVision() (the K9 menu buttons), untouched by the cycle\'s own state', function()
    local f = newVisionFixture({ features = { ThermalVision = true, NightVision = true } })
    f.env.ToggleThermalVision()
    t.isTrue(f.isSeethroughActive())
    t.isFalse(f.isNightvisionActive())
end)

-- ========================================================================
-- CAMERA FEED (Config.Features.CameraFeedPiP) -- see client/vision.lua's
-- own header "CAMERA FEED" section for the full contract this section
-- tests against.
-- ========================================================================

t.test('PARTNER CAMERA HAS NO KEY OR COMMAND: it is opened from the tablet only (owner\'s choice) -- nothing but k9vision is registered, with the feature on or off', function()
    for _, on in ipairs({ true, false }) do
        local f = newVisionFixture({ features = { CameraFeedPiP = on } })
        t.equals(#excludingK9Vision(f.registerCommandCalls, 'name'), 0)
        t.equals(#excludingK9Vision(f.registerKeyMappingCalls, 'commandName'), 0)
    end
end)

t.test('a missing Config.CameraFeed never errors client/vision.lua (defensive fallback -- this file does not own config.lua)', function()
    local env = Sandbox.newEnv({
        RegisterCommand = function() end,
        RegisterKeyMapping = function() end,
        AddEventHandler = function() end,
        lib = { notify = function() end },
    })
    Sandbox.loadInto('../config.lua', env)
    env.Config.Features.CameraFeedPiP = true
    env.Config.CameraFeed = nil
    local ok = pcall(Sandbox.loadInto, '../client/vision.lua', env)
    t.isTrue(ok)
end)

t.test('ToggleCameraFeed: not a role-holder (CanShowK9UI false) -- denied, no cam created', function()
    local f = newVisionFixture()
    f.setCanShowK9UI(false)
    f.env.ToggleCameraFeed()
    t.equals(f.denyK9UIAccessCallCount(), 1)
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: HandlerPartnership feature is off (RefreshPartnershipStateFromServer genuinely undefined, not a stub) -- notifies partnership.feature_disabled, reusing that exact locale key, no cam created', function()
    local f = newVisionFixture({ partnershipAvailable = false })
    f.env.ToggleCameraFeed()
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].description, locale('partnership.feature_disabled'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partnership enabled but not currently partnered -- notifies partnership.not_partnered_with_anyone, reused verbatim', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(false, nil)
    f.env.ToggleCameraFeed()
    t.equals(f.refreshCallCount(), 1, 'must call the FRESH server-authoritative refresh, not a cached synchronous read')
    t.equals(f.notifyCalls[1].description, locale('partnership.not_partnered_with_anyone'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partnered, but partner is offline (GetPlayerFromServerId -1) -- notifies common.target_no_longer_online, distinct from "not partnered at all"', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setPartnerPlayerIndex(-1)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('common.target_no_longer_online'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partner online but their ped is not streamed in (GetPlayerPed returns 0) -- notifies cameraFeed.partner_not_in_range', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setPartnerPed(0)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('cameraFeed.partner_not_in_range'))
    t.equals(#f.createCamCalls, 0)
end)

t.test('ToggleCameraFeed: partner ped handle is nonzero but DoesEntityExist is false -- also treated as out of range, never assumed to exist from a handle alone', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setPartnerPed(999)
    f.setEntityExists(999, false)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('cameraFeed.partner_not_in_range'))
end)

t.test('ToggleCameraFeed: CreateCam fails (returns 0) -- notifies cameraFeed.camera_create_failed, no active state, no freeze', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setCreateCamReturn(0)
    f.env.ToggleCameraFeed()
    t.equals(f.notifyCalls[1].description, locale('cameraFeed.camera_create_failed'))
    t.equals(#f.freezeEntityPositionCalls, 0)
end)

t.test('ToggleCameraFeed: full success against a HANDLER partner (IsEntityModelK9 false) -- correct cam wiring, handlerEyeHeightOffset used, freeze applied, thread started, success notification names the partner', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setIsEntityModelK9(false)
    f.setPartnerName('Officer Rivera')
    f.setEntityRotation({ x = 1.0, y = 2.0, z = 3.0 })

    f.env.ToggleCameraFeed()

    t.equals(#f.createCamCalls, 1)
    t.equals(f.createCamCalls[1].camName, 'DEFAULT_SCRIPTED_CAMERA')
    t.equals(f.createCamCalls[1].active, false, 'created inactive -- SetCamActive(true) is a separate, explicit call below')

    t.equals(#f.attachCamToEntityCalls, 1)
    t.equals(f.attachCamToEntityCalls[1].entity, 999)
    t.equals(f.attachCamToEntityCalls[1].x, 0.0)
    t.equals(f.attachCamToEntityCalls[1].y, 0.0)
    t.equals(f.attachCamToEntityCalls[1].z, f.Config.CameraFeed.handlerEyeHeightOffset, 'handler role -> handlerEyeHeightOffset, not the K9 one')
    t.isTrue(f.attachCamToEntityCalls[1].isRelative)

    t.equals(#f.setCamFovCalls, 1)
    t.equals(f.setCamFovCalls[1].fov, f.Config.CameraFeed.fov)

    t.equals(#f.setCamRotCalls, 1)
    t.equals(f.setCamRotCalls[1].x, 1.0)
    t.equals(f.setCamRotCalls[1].y, 2.0)
    t.equals(f.setCamRotCalls[1].z, 3.0)
    t.equals(f.setCamRotCalls[1].order, 2)

    t.equals(#f.setCamActiveCalls, 1)
    t.isTrue(f.setCamActiveCalls[1].active)

    t.equals(#f.renderScriptCamsCalls, 1)
    t.isTrue(f.renderScriptCamsCalls[1].render)

    t.equals(#f.freezeEntityPositionCalls, 1)
    t.equals(f.freezeEntityPositionCalls[1].entity, 1, 'freezes the LOCAL player ped (id 1 in this fixture), never the partner')
    t.isTrue(f.freezeEntityPositionCalls[1].toggle)

    t.equals(f.notifyCalls[1].description, locale('cameraFeed.feed_started', 'Officer Rivera'))
    t.equals(f.notifyCalls[1].type, 'success')

    t.equals(f.threadCreateCount(), 1)
end)

t.test('ToggleCameraFeed: full success against a K9 partner (IsEntityModelK9 true) uses k9EyeHeightOffset, not handlerEyeHeightOffset', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setIsEntityModelK9(true)

    f.env.ToggleCameraFeed()

    t.equals(f.attachCamToEntityCalls[1].z, f.Config.CameraFeed.k9EyeHeightOffset)
end)

t.test('ToggleCameraFeed: calling it AGAIN while already active toggles OFF instead of starting a second feed', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    t.equals(#f.createCamCalls, 1)

    f.env.ToggleCameraFeed() -- off
    t.equals(#f.createCamCalls, 1, 'must not create a second cam -- this call is a toggle-off, not a fresh start')
    t.equals(#f.renderScriptCamsCalls, 2)
    t.isFalse(f.renderScriptCamsCalls[2].render)
    t.equals(#f.setCamActiveCalls, 2)
    t.isFalse(f.setCamActiveCalls[2].active)
    t.equals(#f.destroyCamCalls, 1)
    t.equals(#f.freezeEntityPositionCalls, 2)
    t.isFalse(f.freezeEntityPositionCalls[2].toggle, 'unfrozen on the way out')
    t.equals(f.notifyCalls[2].description, locale('cameraFeed.feed_ended_manual'))
end)

t.test('ToggleCameraFeed: toggle-off is UNCONDITIONAL -- works even with CanShowK9UI now false, mirroring this resource\'s "termination must never be gated" convention', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on

    f.setCanShowK9UI(false) -- access revoked mid-view
    f.env.ToggleCameraFeed() -- off -- must still succeed, not re-deny

    t.equals(f.denyK9UIAccessCallCount(), 0, 'toggling OFF must never re-check CanShowK9UI at all')
    t.equals(#f.destroyCamCalls, 1)
end)

t.test('ToggleCameraFeed: StopCameraFeed is idempotent against an already-destroyed cam (DoesCamExist false) -- SetCamActive/DestroyCam are skipped, not called on a dead handle', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    f.setCamExists(false) -- simulate the cam having already been destroyed by something else

    f.env.ToggleCameraFeed() -- off
    t.equals(#f.setCamActiveCalls, 1, 'only the turn-on SetCamActive(true) -- the turn-off one is skipped since DoesCamExist is false')
    t.equals(#f.destroyCamCalls, 0)
    t.equals(#f.freezeEntityPositionCalls, 2, 'the unfreeze itself is unconditional and still happens regardless of the cam\'s own existence')
end)

-- ------------------------------------------------------------------
-- STALE-CAM GUARD -- BUG (found + fixed this pass): ToggleCameraFeed()'s
-- own RefreshPartnershipStateFromServer() call YIELDS (an ox_lib callback
-- round trip, per client/partnership.lua's own doc comment), but
-- `cameraFeedState.active` was only ever set true AFTER that round trip
-- returned. A second ToggleCameraFeed() dispatch (keybind double-press,
-- engine auto-repeat, or two inputs landing in the same/adjacent frame)
-- arriving while a first attempt's round trip was still in flight saw
-- `cameraFeedState.active` as still false, ran its own independent
-- CreateCam, and its own `cameraFeedState.cam = cam` assignment silently
-- overwrote the first attempt's only handle to the cam IT already created
-- -- orphaned, DestroyCam never called on it. Same bug class, and the same
-- fix shape, as client/agility.lua's own `vaultInProgress` guard around
-- TryVault()'s async obstacle sweep -- driven with two independent,
-- hand-created coroutines for the identical reason that file's own header
-- gives (Sandbox.newThreadRunner() steps a CreateThread-created coroutine,
-- not a plain function call like ToggleCameraFeed() -- these two calls need
-- independent coroutines this test controls directly).
-- ------------------------------------------------------------------

t.test('BUG (found + fixed this pass): a second ToggleCameraFeed() invocation overlapping the first call\'s still-in-flight RefreshPartnershipStateFromServer() round trip is rejected, not raced into a second CreateCam that orphans the first cam', function()
    local f = newVisionFixture({ partnershipAvailable = true })

    -- Replaces the fixture's own synchronous RefreshPartnershipStateFromServer
    -- stub with one that yields exactly once before answering -- modeling the
    -- real production function's ox_lib callback await. Safe to reassign
    -- post-construction: client/vision.lua looks this name up on the sandbox
    -- env fresh at EVERY call (a normal global reference inside the loaded
    -- chunk), not a reference captured once at file-load time -- only the
    -- one-time `type(RefreshPartnershipStateFromServer) == 'function'` gate
    -- needed the real function to already be present at load, which
    -- `partnershipAvailable = true` above already guaranteed.
    local refreshCalls = 0
    f.env.RefreshPartnershipStateFromServer = function()
        refreshCalls = refreshCalls + 1
        coroutine.yield()
        return true, 42
    end

    local coA = coroutine.create(function() f.env.ToggleCameraFeed() end)
    local coB = coroutine.create(function() f.env.ToggleCameraFeed() end)

    local okA = coroutine.resume(coA)
    assert(okA, 'coroutine A errored before its first yield')
    assert(coroutine.status(coA) == 'suspended', 'expected A to be mid-flight (suspended inside the RefreshPartnershipStateFromServer stub\'s own yield), not already finished')

    -- THE BUG WINDOW: A has not returned yet, so cameraFeedState.active is
    -- still false and cameraFeedState.cam is still nil -- B's own
    -- cameraFeedState.active check passes trivially, exactly like a real
    -- double-press would, on the unfixed code.
    local okB = coroutine.resume(coB)
    assert(okB, 'coroutine B errored')
    t.equals(coroutine.status(coB), 'dead', 'B must be rejected and return immediately by the cameraFeedStartInProgress guard -- it must never itself reach (and therefore never yield at) RefreshPartnershipStateFromServer')
    t.equals(refreshCalls, 1, 'B must never have called RefreshPartnershipStateFromServer at all -- only A\'s own in-flight call counts')

    -- Drain A to completion.
    while coroutine.status(coA) ~= 'dead' do
        local ok, err = coroutine.resume(coA)
        assert(ok, 'coroutine A errored mid-flight: ' .. tostring(err))
    end

    t.equals(#f.createCamCalls, 1, 'exactly one cam was ever created -- B never got the chance to race a second CreateCam into cameraFeedState.cam')
    t.equals(refreshCalls, 1, 'still exactly one RefreshPartnershipStateFromServer call after A finishes')
end)

t.test('RE-ENTRANCY GUARD RESET: once an in-flight start attempt fully completes (success or failure), a genuinely NEW, later ToggleCameraFeed() call is not permanently blocked by the guard', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)

    f.env.ToggleCameraFeed() -- on -- completes synchronously in this fixture's default (non-yielding) stub
    t.equals(#f.createCamCalls, 1)

    f.env.ToggleCameraFeed() -- off
    t.equals(#f.destroyCamCalls, 1)

    -- A fresh start attempt AFTER the first one fully completed (on, then
    -- off) must succeed normally -- proves cameraFeedStartInProgress is
    -- reset on the success path too, not just on an early-return failure
    -- path, and that it does not leak `true` forever once a feed has
    -- actually gone active and been stopped again.
    f.env.ToggleCameraFeed() -- on again
    t.equals(#f.createCamCalls, 2, 'the guard must not have been left permanently true by the first, already-completed attempt')
end)

-- ------------------------------------------------------------------
-- Per-frame tracking/exit-condition thread. STEPPING NOTES FOR THIS
-- THREAD: its body is `while cameraFeedState.active do Wait(0) ... end`
-- -- the loop CONDITION is the very first thing evaluated (unlike this
-- file's OWN thermal/night thread, which runs a plain assignment before
-- its own while-check), so:
--   step() call #1 -- resumes from the start: evaluates the while-
--     condition (true, since ToggleCameraFeed() already set it before
--     this thread's body ever runs), enters the loop, and yields
--     immediately at Wait(0). A pure "prime" step, same as the thermal/
--     night thread's own step #1, for a different structural reason.
--   step() call #2 onward -- resumes after Wait(0), runs exactly one pass
--     of the exit-condition checks (and SetCamRot if none tripped), then
--     re-checks the while-condition: still true -> loops back to Wait(0)
--     and yields again; now false (a check just called StopCameraFeed())
--     -> falls out of the loop, clears cameraFeedThreadRunning, and the
--     coroutine dies within that SAME step() call.
-- ------------------------------------------------------------------

t.test('camera feed thread: does not exist at all before any feed is ever turned on', function()
    local f = newVisionFixture()
    t.equals(f.threadCreateCount(), 0)
end)

t.test('camera feed thread: while active and nothing has changed, each pass re-reads the partner\'s live rotation and re-applies SetCamRot -- the whole point of this thread', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on; SetCamRot already called once here
    f.step() -- prime

    f.setEntityRotation({ x = 9.0, y = 8.0, z = 7.0 })
    f.step() -- one real pass

    t.equals(#f.setCamRotCalls, 2, 'the onset call plus one thread pass')
    t.equals(f.setCamRotCalls[2].x, 9.0)
    t.equals(f.setCamRotCalls[2].y, 8.0)
    t.equals(f.setCamRotCalls[2].z, 7.0)
end)

t.test('camera feed thread: local player\'s own death ends the feed with feed_ended_own_death', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setIsEntityDead(true)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_own_death'))
end)

t.test('camera feed thread: losing CanShowK9UI mid-view ends the feed with feed_ended_access_lost', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setCanShowK9UI(false)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_access_lost'))
end)

t.test('camera feed thread: the partnership itself ending (IsPartnered turns false) ends the feed with feed_ended_partner_lost', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setIsPartnered(false)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_partner_lost'))
end)

t.test('camera feed thread: partner disconnecting mid-view (GetPlayerFromServerId now -1) ends the feed with feed_ended_partner_lost', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setPartnerPlayerIndex(-1)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_partner_lost'))
end)

t.test('camera feed thread: partner streaming out mid-view (their ped stops existing) ends the feed with feed_ended_partner_lost -- re-resolved fresh every tick, never a stale cached handle', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed()
    f.step() -- prime

    f.setEntityExists(999, false)
    f.step()

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, locale('cameraFeed.feed_ended_partner_lost'))
end)

t.test('camera feed thread: self-terminates once the feed ends -- a LATER toggle-on starts a genuinely NEW thread', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on -- thread #1
    t.equals(f.threadCreateCount(), 1)
    f.step() -- prime
    f.setIsEntityDead(true)
    f.step() -- ends the feed, thread dies, guard resets

    f.setIsEntityDead(false)
    f.env.ToggleCameraFeed() -- on again
    t.equals(f.threadCreateCount(), 2, 'a fresh ON transition after the previous thread self-terminated must start a NEW thread')
end)

-- ------------------------------------------------------------------
-- onResourceStop -- extends the existing thermal/night handler; must also
-- silently (no notify) tear down an active camera feed.
-- ------------------------------------------------------------------

t.test('onResourceStop: an active camera feed is silently torn down (no notify) alongside the existing thermal/night reset', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    local notifyCountBefore = #f.notifyCalls

    f.fireResourceStop(f.resourceName)

    t.equals(#f.destroyCamCalls, 1)
    t.equals(#f.notifyCalls, notifyCountBefore, 'silent stop -- no player-facing message when the resource itself is stopping')
    t.equals(f.freezeEntityPositionCalls[#f.freezeEntityPositionCalls].toggle, false)
end)

t.test('onResourceStop: a harmless no-op when no camera feed was ever started', function()
    local f = newVisionFixture()
    local ok = pcall(f.fireResourceStop, f.resourceName)
    t.isTrue(ok)
    t.equals(#f.destroyCamCalls, 0)
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- ThermalVision,
-- NightVision, CameraFeedPiP. Three properties per feature: (1) a block
-- refuses a NEW turn-on, (2) a block NEVER refuses turning OFF (the
-- "never gate a termination path" rule), (3) an ALREADY-ACTIVE effect is
-- force-ended by the existing maintenance thread once a block arrives,
-- and (4) the whole mechanism fails OPEN (never blocked) when
-- client/featureblocks.lua has not loaded at all.
-- ----------------------------------------------------------------------

t.test('ToggleThermalVision: blocked -- refuses to turn on, SetSeethrough never called, denies via DenyK9FeatureBlocked', function()
    local f = newVisionFixture()
    f.setBlocked('ThermalVision', true)
    f.env.ToggleThermalVision()
    t.isFalse(f.isSeethroughActive())
    t.equals(#f.setSeethroughCalls, 0)
    t.equals(f.denyK9FeatureBlockedCallCount(), 1)
    t.equals(f.threadCreateCount(), 0, 'a refused turn-on must never start the maintenance thread')
end)

t.test('ToggleNightVision: blocked -- refuses to turn on, SetNightvision never called', function()
    local f = newVisionFixture()
    f.setBlocked('NightVision', true)
    f.env.ToggleNightVision()
    t.isFalse(f.isNightvisionActive())
    t.equals(#f.setNightvisionCalls, 0)
    t.equals(f.denyK9FeatureBlockedCallCount(), 1)
end)

t.test('ToggleThermalVision: blocking AFTER it is already on never refuses turning it back OFF -- termination is never gated', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on, while unblocked
    t.isTrue(f.isSeethroughActive())

    f.setBlocked('ThermalVision', true) -- blocked while already active
    f.env.ToggleThermalVision() -- the SAME toggle call, now used to turn it back OFF
    t.isFalse(f.isSeethroughActive(), 'a block must never prevent turning an already-active effect back off')
    t.equals(f.denyK9FeatureBlockedCallCount(), 0, 'the turning-OFF branch must never even consult the block')
end)

t.test('ToggleThermalVision/ToggleNightVision: a block on ONE effect does not affect the other', function()
    local f = newVisionFixture()
    f.setBlocked('ThermalVision', true)
    f.env.ToggleNightVision() -- unaffected -- NightVision is not blocked
    t.isTrue(f.isNightvisionActive())
end)

-- GATE-THE-START-NEVER-THE-STOP FIX (vision merge pass, coder-architect).
-- Mirrors the block test immediately above, for IsOwnModelK9() instead of
-- a per-person block -- the exact bug this pass found and fixed: the
-- IsOwnModelK9() check used to run BEFORE `turningOn` was even computed,
-- so a player already IN an effect who stopped being IsOwnModelK9() could
-- not turn it back off through this function at all (only the separate
-- 1000ms maintenance-thread poll would eventually notice). PROVEN BY
-- BREAKING: reverting ToggleThermalVision()'s fix (moving the
-- `if not IsOwnModelK9() then ... return end` block back above `local
-- turningOn = ...`, unconditional again) turns this test red -- the
-- turn-off branch would hit the notify-and-return path instead of ever
-- reaching SetSeethrough(false).
t.test('ToggleThermalVision: IsOwnModelK9 becomes false AFTER it is already on never refuses turning it back OFF -- termination is never gated', function()
    local f = newVisionFixture()
    f.env.ToggleThermalVision() -- on, while a K9 model
    t.isTrue(f.isSeethroughActive())

    f.setIsOwnModelK9(false) -- model swap away from K9, mid-session
    f.env.ToggleThermalVision() -- the SAME toggle call, now used to turn it back OFF
    t.isTrue(f.isSeethroughActive() == false, 'losing IsOwnModelK9() must never prevent turning an already-active effect back off')
    t.equals(#f.notifyCalls, 2, 'the turn-off must still send its own "thermal off" notify, not the not_k9_model denial')
    t.equals(f.notifyCalls[2].description, locale('vision.thermal_off'))
end)

t.test('ToggleNightVision: IsOwnModelK9 becomes false AFTER it is already on never refuses turning it back OFF', function()
    local f = newVisionFixture()
    f.env.ToggleNightVision() -- on
    t.isTrue(f.isNightvisionActive())

    f.setIsOwnModelK9(false)
    f.env.ToggleNightVision() -- turn back off
    t.isFalse(f.isNightvisionActive())
    t.equals(f.notifyCalls[2].description, locale('vision.night_off'))
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- every toggle works exactly as before this pass', function()
    local f = newVisionFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.env.ToggleThermalVision()
    t.isTrue(f.isSeethroughActive(), 'an unknown block state must never freeze an ability -- it must fail OPEN, not closed')
end)

t.test('ToggleCameraFeed: blocked -- refuses to start a NEW feed', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.setBlocked('CameraFeedPiP', true)

    f.env.ToggleCameraFeed()

    t.equals(#f.createCamCalls, 0, 'a refused start must never reach CreateCam at all')
    t.equals(f.denyK9FeatureBlockedCallCount(), 1)
end)

t.test('ToggleCameraFeed: blocking AFTER a feed is already active never refuses manually stopping it', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on, while unblocked
    t.equals(#f.createCamCalls, 1)

    f.setBlocked('CameraFeedPiP', true)
    f.env.ToggleCameraFeed() -- the manual toggle-off path -- must still work
    t.equals(#f.destroyCamCalls, 1, 'manually stopping an already-active feed must never be gated by a block')
end)

t.test('camera feed thread: a block applied while a feed is already active ends it LIVE, on the next thread pass, with feed_ended_blocked -- not merely blocking the next manual attempt', function()
    local f = newVisionFixture({ partnershipAvailable = true })
    f.setRefreshResult(true, 42)
    f.env.ToggleCameraFeed() -- on
    f.step() -- prime

    f.setBlocked('CameraFeedPiP', true)
    f.step() -- one real pass -- must detect the block and force-stop, same as death/access-loss above

    t.equals(#f.destroyCamCalls, 1)
    t.equals(f.notifyCalls[#f.notifyCalls].description, localeAllowingPending('cameraFeed.feed_ended_blocked'))
end)

os.exit(t.summary())
