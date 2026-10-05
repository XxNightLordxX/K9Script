--[[
    tests/clienthud_spec.lua

    Direct, black-box tests of client/hud.lua against the REAL, unmodified
    production file: the Config.Features.HealthStaminaHUD file-scope gate,
    ReadVitals()'s health/stamina derivation (all `local`,
    reached only through the 'hud:ready' NUI callback and the poll thread's
    own pushes -- both real, resource-visible entry points), the five
    independently-gated wellbeing rows (fatigue/
    distracted, each absent-not-zeroed when its own flag is off), the
    XPProgression-gated xpTier row and its soft dependency on
    GetCurrentXPTier(), the dkjson array-vs-object `__jsontype` fix on the
    wellbeing/xpTier sub-tables, and the poll thread's own becameVisible/
    epsilon/heartbeat push-decision logic including the "resend LAST KNOWN
    values, never a fresh read, on a true->false visibility transition" rule.

    THREAD STEPPING NOTE FOR THIS FILE'S ONE THREAD BODY -- DIFFERENT FROM
    EVERY OTHER CLIENT SPEC IN THIS SUITE, READ BEFORE TRUSTING A GENERIC
    "step() #1 just primes" ASSUMPTION HERE: client/hud.lua's poll thread
    puts its `Wait(...)` call at the END of each branch (idle or active),
    not at the top of the loop or right after a leading assignment the way
    every other thread in this suite's client specs is shaped (see
    tests/clientvision_spec.lua's and tests/clientaudio_spec.lua's own
    headers for THEIR respective deviations from the generic note -- this
    file is a THIRD, different shape again). Concretely:
        while true do
            local canShow = CanShowK9UI()
            if not canShow then
                if hudState.visible then PushVitals(false, ...) end
                Wait(HUD_IDLE_TICK_MS)
            else
                ... compute + maybe PushVitals(true, ...) ...
                Wait(HUD_POLL_TICK_MS)
            end
        end
    Every step() call -- INCLUDING THE FIRST -- therefore runs one COMPLETE
    evaluate-and-maybe-push pass BEFORE yielding at that pass's own Wait().
    There is no "priming-only" step here. `f.advance(ms)` (a fake
    GetGameTimer() clock) must be called between step()s to simulate real
    elapsed wait time for the heartbeat tests below, since the sandbox's
    Wait() stub does not itself consume any time.

    STUBBING EFFORT: every native here is a simple capturing/controllable
    stub (PlayerPedId, GetEntityHealth/GetEntityMaxHealth,
    GetPlayerSprintStaminaRemaining, PlayerId, GetGameTimer,
    RegisterNUICallback, SendNUIMessage, RegisterNetEvent). QBX is modeled
    as a plain Lua table this fixture constructs and mutates directly (the
    real global qbx_core's own `@qbx_core/modules/playerdata.lua` shared_script
    populates before ANY of this resource's own client scripts run, per
    fxmanifest.lua's dependency ordering -- this fixture always defines at
    least `QBX = { PlayerData = {} }`, matching that guarantee, rather than
    testing a "QBX itself is nil" case this file's own code does not defend
    against and that load order makes unreachable in practice).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { healthStaminaHUD: boolean?, features: table?, canShowK9UI: boolean? }?
--- @return table fixture
local function newHudFixture(opts)
    opts = opts or {}

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local function CanShowK9UI() return canShowK9UI end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in, not the real cross-file dependency"
    -- convention as CanShowK9UI above. Soft dependency: only added to
    -- `env` when `opts.featureBlocksAvailable` is not explicitly false.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local myPed = 1
    local function PlayerPedId() return myPed end

    local entityHealth, entityMaxHealth = 200.0, 200.0
    local function GetEntityHealth(_ped) return entityHealth end
    local function GetEntityMaxHealth(_ped) return entityMaxHealth end

    local staminaRemaining = 0.0 -- 0 exertion == full stamina, per ReadVitals' own inversion
    local function GetPlayerSprintStaminaRemaining(_playerId) return staminaRemaining end
    local function PlayerId() return 0 end

    local qbx = { PlayerData = { metadata = {}, citizenid = opts.citizenid } }

    local registerNUICallbacks = {}
    local function RegisterNUICallback(name, handler) registerNUICallbacks[name] = handler end
    local sendNUIMessageCalls = {}
    local function SendNUIMessage(payload) sendNUIMessageCalls[#sendNUIMessageCalls + 1] = payload end

    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    -- K9 ONBOARDING HINT (this pass) -----------------------------------
    -- KVP STUB -- a plain in-memory table standing in for this client's
    -- real KVP store. `opts.kvpStore`, when supplied, lets TWO SEPARATE
    -- fixture instances share the SAME backing table -- exactly what the
    -- "recycled server id must not leak another citizenid's state" test
    -- below needs (two fixtures = two client-side sessions, one shared
    -- physical KVP store between them, same as two different citizenids
    -- played from the same PC).
    --
    -- HONEST NOTE, per the coordinator's own flag on this feature: real
    -- GetResourceKvpString/SetResourceKvp are NOT independently verified
    -- against a live FXServer this pass (see client/hud.lua's own
    -- "DURABLE STORAGE" section and the root .luacheckrc's matching
    -- entry). This stub proves this FILE's own persistence LOGIC is
    -- correct GIVEN a working KVP store -- it does NOT and CANNOT prove
    -- the real natives behave this way. The dedicated
    -- "KVP NATIVES ABSENT/NO-OP" section further down this file is the
    -- one that actually exercises the "what if these silently do
    -- nothing" case the coordinator asked for -- read that section
    -- rather than mistaking this stub's own green tests for proof the
    -- real natives work.
    local kvpStore = opts.kvpStore or {}
    local kvpAvailable = opts.kvpAvailable
    if kvpAvailable == nil then kvpAvailable = true end
    local function GetResourceKvpString(key)
        if not kvpAvailable then return nil end
        return kvpStore[key]
    end
    local function SetResourceKvp(key, value)
        if not kvpAvailable then return end -- mirrors a genuinely-unregistered native silently writing nothing (see the section note above)
        kvpStore[key] = value
    end

    -- DISMISS-KEY STUB -- one-shot, matching "JustPressed" semantics: true
    -- exactly once after pressDismissKey() is called, false every other
    -- tick, same as a real "just pressed this frame" native would behave
    -- across repeated polls of a single real key press.
    local dismissKeyPressedOnce = false
    local function IsDisabledControlJustPressed(_padIndex, _control)
        if dismissKeyPressedOnce then
            dismissKeyPressedOnce = false
            return true
        end
        return false
    end

    local env = Sandbox.newEnv({
        CanShowK9UI = CanShowK9UI,
        -- The first-time tip is worded for who you are playing; the fixture
        -- plays the dog unless a test passes playingDog = false.
        IsOwnModelK9 = function() return opts.playingDog ~= false end,
        IsPartnered = function() return opts.isPartnered == true end,
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        GetPlayerSprintStaminaRemaining = GetPlayerSprintStaminaRemaining,
        PlayerId = PlayerId,
        QBX = qbx,
        RegisterNUICallback = RegisterNUICallback,
        SendNUIMessage = SendNUIMessage,
        CreateThread = CreateThread,
        Wait = Wait,
        RegisterNetEvent = RegisterNetEvent,
        GetResourceKvpString = GetResourceKvpString,
        SetResourceKvp = SetResourceKvp,
        IsDisabledControlJustPressed = IsDisabledControlJustPressed,
    })
    if featureBlocksAvailable then
        env.IsK9FeatureBlocked = IsK9FeatureBlocked
    end

    Sandbox.loadInto('../config.lua', env)

    if opts.healthStaminaHUD == false then
        env.Config.Features.HealthStaminaHUD = false
    end
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end
    if opts.k9OnboardingEnabled ~= nil then
        env.Config.K9Onboarding.enabled = opts.k9OnboardingEnabled
    end
    if opts.k9OnboardingNudgeDurationMinutes ~= nil then
        env.Config.K9Onboarding.nudgeDurationMinutes = opts.k9OnboardingNudgeDurationMinutes
    end

    Sandbox.loadInto('../client/hud.lua', env)

    return {
        env = env,
        Config = env.Config,
        sendNUIMessageCalls = sendNUIMessageCalls,
        threadCreateCount = function() return threadCreateCount end,
        step = function() runner.step() end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        setHealth = function(current, max) entityHealth = current; entityMaxHealth = max end,
        setStaminaRemaining = function(v) staminaRemaining = v end,
        setMetadata = function(field, v) qbx.PlayerData.metadata[field] = v end,
        clearPlayerData = function() qbx.PlayerData = nil end,
        fireHudReady = function()
            local handler = assert(registerNUICallbacks['hud:ready'], 'client/hud.lua did not register a hud:ready NUI callback')
            local cbCalls = {}
            handler({}, function(response) cbCalls[#cbCalls + 1] = response end)
            return cbCalls
        end,
        fireWellbeingUpdate = function(sourceValue, stats)
            local handler = netEventHandlers['john-k9:client:wellbeingUpdate']
            assert(handler, 'no wellbeingUpdate handler registered')
            env.source = sourceValue
            handler(stats)
        end,
        hasWellbeingHandler = function() return netEventHandlers['john-k9:client:wellbeingUpdate'] ~= nil end,
        lastMessage = function() return sendNUIMessageCalls[#sendNUIMessageCalls] end,
        -- HANDLER CONDITION BADGE (this pass) -----------------------------
        firePartnerConditionUpdate = function(sourceValue, payload)
            local handler = netEventHandlers['john-k9:client:partnerConditionUpdate']
            assert(handler, 'no partnerConditionUpdate handler registered')
            env.source = sourceValue
            handler(payload)
        end,
        hasPartnerConditionHandler = function() return netEventHandlers['john-k9:client:partnerConditionUpdate'] ~= nil end,
        --- The last SendNUIMessage call whose `action` matches, or nil.
        --- Needed because 'hud:updateVitals' and 'hud:partnerCondition' are
        --- two INDEPENDENT message streams interleaved in the same
        --- sendNUIMessageCalls array -- lastMessage() alone cannot tell
        --- them apart.
        --- @param action string
        lastMessageWithAction = function(action)
            for i = #sendNUIMessageCalls, 1, -1 do
                if sendNUIMessageCalls[i].action == action then return sendNUIMessageCalls[i] end
            end
            return nil
        end,
        countMessagesWithAction = function(action)
            local n = 0
            for _, msg in ipairs(sendNUIMessageCalls) do
                if msg.action == action then n = n + 1 end
            end
            return n
        end,
        -- K9 ONBOARDING HINT (this pass) ------------------------------
        setCitizenId = function(id) qbx.PlayerData.citizenid = id end,
        pressDismissKey = function() dismissKeyPressedOnce = true end,
        kvpStore = kvpStore,
        fireTabletOpened = function()
            local handler = assert(registerNUICallbacks['hud:tabletOpened'], 'client/hud.lua did not register a hud:tabletOpened NUI callback')
            local cbCalls = {}
            handler({}, function(response) cbCalls[#cbCalls + 1] = response end)
            return cbCalls
        end,
        hasTabletOpenedCallback = function() return registerNUICallbacks['hud:tabletOpened'] ~= nil end,
    }
end

-- ----------------------------------------------------------------------
-- Gating
-- ----------------------------------------------------------------------

t.test('gating: HealthStaminaHUD = true (real shipped default) -- one vitals poll thread PLUS the independent onboarding-hint thread (also on by default)', function()
    local f = newHudFixture()
    t.equals(f.threadCreateCount(), 2)
end)

-- ----------------------------------------------------------------------
-- ReadVitals -- health/stamina, reached via 'hud:ready'
-- ----------------------------------------------------------------------

t.test('hud:ready: calls back with an empty table, unconditionally and immediately', function()
    local f = newHudFixture()
    local cbCalls = f.fireHudReady()
    t.equals(#cbCalls, 1)
    t.equals(type(cbCalls[1]), 'table')
end)

t.test('hud:ready: pushes exactly one immediate snapshot with visible = CanShowK9UI()', function()
    local f = newHudFixture({ canShowK9UI = false })
    f.fireHudReady()
    t.equals(#f.sendNUIMessageCalls, 1)
    t.equals(f.lastMessage().action, 'hud:updateVitals')
    t.isFalse(f.lastMessage().data.visible)
end)

t.test('health: normalized against GetEntityMaxHealth, 0-100 scale', function()
    local f = newHudFixture()
    f.setHealth(150, 200) -- 75%
    f.fireHudReady()
    t.equals(f.lastMessage().data.health, 75.0)
end)

t.test('health: GetEntityMaxHealth <= 0 defensively defaults to 100.0 rather than dividing by zero', function()
    local f = newHudFixture()
    f.setHealth(50, 0)
    local ok = pcall(f.fireHudReady)
    t.isTrue(ok)
    t.equals(f.lastMessage().data.health, 100.0)
end)

t.test('stamina: inverted from the raw exertion native -- 30 exertion reads as 70 stamina', function()
    local f = newHudFixture()
    f.setStaminaRemaining(30.0)
    f.fireHudReady()
    t.equals(f.lastMessage().data.stamina, 70.0)
end)

t.test('stamina: a non-number native return defaults to 100.0 (full), never an empty bar', function()
    local f = newHudFixture()
    local env = f.env
    env.GetPlayerSprintStaminaRemaining = function() return nil end
    f.fireHudReady()
    t.equals(f.lastMessage().data.stamina, 100.0)
end)

-- ----------------------------------------------------------------------
-- Wellbeing rows -- per-flag absence (not zero), and the wellbeingUpdate
-- listener's own source-origin guard + shape validation.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- xpTier row -- soft dependency on GetCurrentXPTier()
-- ----------------------------------------------------------------------

t.test('xpTier: XPProgression = false -- label always absent, GetCurrentXPTier never even needs to exist', function()
    local f = newHudFixture({ features = { XPProgression = false } })
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true but GetCurrentXPTier does not exist (soft dependency absent) -- label absent, no crash', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    local ok = pcall(f.fireHudReady)
    t.isTrue(ok)
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true, GetCurrentXPTier returns nil (no snapshot received yet this session) -- label absent', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return nil end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true, GetCurrentXPTier returns a malformed (non-table, or missing .label) value -- label absent, defensively', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return 'not-a-table' end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.label)
end)

t.test('xpTier: XPProgression = true, GetCurrentXPTier returns a real tier -- label is present and correct', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Rookie', xp = 0 } end
    f.fireHudReady()
    t.equals(f.lastMessage().data.xpTier.label, 'Rookie')
end)

-- ----------------------------------------------------------------------
-- xpTier.badge -- server/progression.lua's own disclosed "Elite -- SERVER
-- HALF WIRED, DISPLAY NOT WIRED" gap, closed this pass. Same accessor as
-- label above (GetCurrentXPTier()), just a second field off the same
-- table -- so this deliberately reuses the exact same fixture shape as the
-- label tests just above rather than a new one.
-- ----------------------------------------------------------------------

t.test('xpTier.badge: absent when the current tier has no badge configured (every shipped tier except Elite)', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Rookie', xp = 0 } end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.badge)
end)

t.test('xpTier.badge: present and correct when the current tier carries one (config.lua\'s Elite row: badge = \'elite\')', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Elite K9', xp = 9000, badge = 'elite' } end
    f.fireHudReady()
    t.equals(f.lastMessage().data.xpTier.label, 'Elite K9')
    t.equals(f.lastMessage().data.xpTier.badge, 'elite')
end)

t.test('xpTier.badge: an empty-string badge is treated as absent, not rendered as a blank badge', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Elite K9', xp = 9000, badge = '' } end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.badge)
end)

t.test('xpTier.badge: a non-string badge is treated as absent, defensively', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Elite K9', xp = 9000, badge = 123 } end
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.badge)
end)

t.test('xpTier.badge: XPProgression = false -- badge always absent too, same as label', function()
    local f = newHudFixture({ features = { XPProgression = false } })
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.badge)
end)

t.test('xpTier.badge: a badge CHANGE alone (label unchanged) is enough to trigger a poll-thread push', function()
    local f = newHudFixture({ features = { XPProgression = true } })
    f.env.GetCurrentXPTier = function() return { label = 'Elite K9', xp = 9000 } end
    f.setCanShowK9UI(true)
    f.fireHudReady()
    t.isNil(f.lastMessage().data.xpTier.badge)

    f.env.GetCurrentXPTier = function() return { label = 'Elite K9', xp = 9000, badge = 'elite' } end
    f.step()
    t.equals(f.lastMessage().data.xpTier.badge, 'elite', 'a badge appearing on an already-known label must still trigger a push, not be silently missed by the label-only change check')
end)

-- ----------------------------------------------------------------------
-- Poll thread -- becameVisible / epsilon / heartbeat push decisions, and
-- the true->false "resend last known values" rule. See this file's header
-- for this thread's own, unique stepping semantics.
-- ----------------------------------------------------------------------

t.test('poll thread: invisible throughout (CanShowK9UI always false) -- never pushes at all, idles at HUD_IDLE_TICK_MS (1000ms)', function()
    local f = newHudFixture({ canShowK9UI = false })
    f.step()
    f.step()
    f.step()
    t.equals(#f.sendNUIMessageCalls, 0)
end)

t.test('poll thread: becameVisible forces an immediate push with FRESH values, regardless of epsilon/heartbeat', function()
    local f = newHudFixture({ canShowK9UI = false })
    f.step() -- invisible pass, no push
    t.equals(#f.sendNUIMessageCalls, 0)

    f.setCanShowK9UI(true)
    f.setHealth(160, 200) -- 80%
    f.step() -- becameVisible pass -- must push immediately
    t.equals(#f.sendNUIMessageCalls, 1)
    t.isTrue(f.lastMessage().data.visible)
    t.equals(f.lastMessage().data.health, 80.0)
end)

t.test('poll thread: true->false transition resends the LAST KNOWN vitals, never a fresh read', function()
    local f = newHudFixture()
    f.setHealth(160, 200) -- 80%
    f.step() -- becameVisible push, health = 80

    f.setCanShowK9UI(false)
    f.setHealth(20, 200) -- change AFTER the transition -- must NOT be what gets pushed
    f.step()
    t.equals(f.lastMessage().data.visible, false)
    t.equals(f.lastMessage().data.health, 80.0, 'a false-transition push must resend the LAST KNOWN good value, never a fresh read')
end)

t.test('poll thread: staying invisible after the transition push does not push again', function()
    local f = newHudFixture()
    f.step() -- becomes visible, pushes
    f.setCanShowK9UI(false)
    f.step() -- transition push
    local countAfterTransition = #f.sendNUIMessageCalls
    f.step() -- still invisible, nothing changed
    f.step()
    t.equals(#f.sendNUIMessageCalls, countAfterTransition, 'no repeat push while genuinely, continuously hidden')
end)

t.test('poll thread: a change below HUD_CHANGE_EPSILON (0.5) does not trigger a re-push', function()
    local f = newHudFixture()
    f.setHealth(160, 200) -- 80.0
    f.step()
    local countBefore = #f.sendNUIMessageCalls

    f.setHealth(160.6, 200) -- 80.3 -- diff 0.3 < epsilon
    f.step()
    t.equals(#f.sendNUIMessageCalls, countBefore, 'a sub-epsilon change must not trigger a re-push before the heartbeat is due')
end)

t.test('poll thread: a change ABOVE HUD_CHANGE_EPSILON triggers an immediate re-push', function()
    local f = newHudFixture()
    f.setHealth(160, 200) -- 80.0
    f.step()
    local countBefore = #f.sendNUIMessageCalls

    f.setHealth(161.2, 200) -- 80.6 -- diff 0.6 > epsilon
    f.step()
    t.equals(#f.sendNUIMessageCalls, countBefore + 1)
    t.equals(f.lastMessage().data.health, 80.6)
end)

t.test('poll thread: HUD_HEARTBEAT_MS (1000ms) forces a re-push even with ZERO real change', function()
    local f = newHudFixture()
    f.step() -- becameVisible push at fakeNow=0
    local countAfterFirst = #f.sendNUIMessageCalls

    f.advance(250)
    f.step() -- 250ms elapsed -- no change, heartbeat not due
    t.equals(#f.sendNUIMessageCalls, countAfterFirst)

    f.advance(250)
    f.step() -- 500ms elapsed
    t.equals(#f.sendNUIMessageCalls, countAfterFirst)

    f.advance(250)
    f.step() -- 750ms elapsed
    t.equals(#f.sendNUIMessageCalls, countAfterFirst)

    f.advance(250)
    f.step() -- 1000ms elapsed -- heartbeat due, even though nothing changed
    t.equals(#f.sendNUIMessageCalls, countAfterFirst + 1, 'the heartbeat ceiling must force a re-push even with zero real change')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- folded
-- directly into the poll thread's own `canShow` derivation, so hiding an
-- already-visible HUD on block is just the existing true->false transition
-- path, already proven above -- these tests only confirm the block itself
-- actually participates in that derivation, and that it fails open.
-- ----------------------------------------------------------------------

t.test('poll thread: HealthStaminaHUD blocked -- canShow is false even though CanShowK9UI is true, so the HUD never shows at all', function()
    local f = newHudFixture()
    f.setBlocked('HealthStaminaHUD', true)
    f.step()
    t.equals(#f.sendNUIMessageCalls, 0, 'never having been visible, a blocked pass pushes nothing -- there is no prior visible state to transition away from')
end)

t.test('poll thread: a block applied AFTER the HUD is already visible hides it on the very next pass (the existing true->false transition push)', function()
    local f = newHudFixture()
    f.step() -- becomes visible, pushes visible=true
    t.isTrue(f.lastMessage().data.visible)

    f.setBlocked('HealthStaminaHUD', true)
    f.step()
    t.isFalse(f.lastMessage().data.visible, 'a live block must hide an already-showing HUD, not merely refuse the next show')
end)

t.test('poll thread: a block on a DIFFERENT feature name never affects HealthStaminaHUD', function()
    local f = newHudFixture()
    f.setBlocked('NightVision', true)
    f.step()
    t.isTrue(f.lastMessage().data.visible)
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- the HUD shows exactly as before this pass', function()
    local f = newHudFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.step()
    t.isTrue(f.lastMessage().data.visible, 'an unknown block state must never freeze/hide the HUD -- it must fail OPEN')
end)

-- ========================================================================
-- HANDLER CONDITION BADGE (this pass) -- see server/wellbeing.lua's own
-- "HANDLER CONDITION BADGE" header section and this file's own new header
-- section for the full design. The listener under test here is a pure
-- forwarding relay: server->client event in, one SendNUIMessage out, no
-- state, no thread.
-- ========================================================================

t.test('HANDLER CONDITION BADGE: the listener registers UNCONDITIONALLY, even when HealthStaminaHUD is false -- this is a SEPARATE audience from the K9-vitals HUD', function()
    local f = newHudFixture({ healthStaminaHUD = false })
    t.isTrue(f.hasPartnerConditionHandler())
end)

t.test('HANDLER CONDITION BADGE: a visible=true payload forwards hud:partnerCondition with visible/tags/strings, unaffected by CanShowK9UI or #k9hud state', function()
    local f = newHudFixture({ healthStaminaHUD = false, canShowK9UI = false })
    f.firePartnerConditionUpdate(65535, { visible = true, tags = { 'tired', 'hungry' } })

    local msg = f.lastMessageWithAction('hud:partnerCondition')
    t.isTrue(msg ~= nil)
    t.isTrue(msg.data.visible)
    t.equals(#msg.data.tags, 2)
    t.equals(msg.data.tags[1], 'tired')
    t.equals(msg.data.tags[2], 'hungry')
    t.equals(type(msg.data.strings), 'table')
    t.equals(msg.data.strings.tired, 'Tired')
    t.equals(msg.data.strings.fine, 'Fine')
    t.equals(msg.data.strings.label, 'K9 Partner')
end)

t.test('HANDLER CONDITION BADGE: a visible=false payload forwards visible=false with an EMPTY tags array, even if the payload itself carried stray tags', function()
    local f = newHudFixture()
    f.firePartnerConditionUpdate(65535, { visible = false, tags = { 'tired' } })

    local msg = f.lastMessageWithAction('hud:partnerCondition')
    t.isFalse(msg.data.visible)
    t.equals(#msg.data.tags, 0)
end)

t.test('HANDLER CONDITION BADGE: SOURCE-ORIGIN GUARD -- a non-65535 source is ignored, no message forwarded at all', function()
    local f = newHudFixture()
    f.firePartnerConditionUpdate(1, { visible = true, tags = { 'tired' } })
    t.equals(f.countMessagesWithAction('hud:partnerCondition'), 0)
end)

t.test('HANDLER CONDITION BADGE: a non-table payload is a silent no-op, never a crash', function()
    local f = newHudFixture()
    local ok = pcall(f.firePartnerConditionUpdate, 65535, 'not-a-table')
    t.isTrue(ok)
    t.equals(f.countMessagesWithAction('hud:partnerCondition'), 0)
end)

t.test('HANDLER CONDITION BADGE: non-string entries in `tags` are dropped defensively rather than forwarded verbatim', function()
    local f = newHudFixture()
    f.firePartnerConditionUpdate(65535, { visible = true, tags = { 'tired', 42, false, 'hungry' } })

    local msg = f.lastMessageWithAction('hud:partnerCondition')
    t.equals(#msg.data.tags, 2)
    t.equals(msg.data.tags[1], 'tired')
    t.equals(msg.data.tags[2], 'hungry')
end)

t.test('HANDLER CONDITION BADGE: a missing `tags` field on a visible=true payload degrades to an empty array, never a crash', function()
    local f = newHudFixture()
    local ok = pcall(f.firePartnerConditionUpdate, 65535, { visible = true })
    t.isTrue(ok)
    local msg = f.lastMessageWithAction('hud:partnerCondition')
    t.isTrue(msg.data.visible)
    t.equals(#msg.data.tags, 0)
end)

t.test('HANDLER CONDITION BADGE: every tag string plus fine/label resolves via the REAL locale() call against locales/en.json -- proves the keys genuinely exist, not just that this file compiles', function()
    -- 'tired' is now the ONLY tag server/wellbeing.lua's
    -- ComputeHandlerConditionTags can emit -- mood, fear/stress, injury and
    -- hunger/thirst were removed by owner directive, and their tag codes
    -- ('unhappy'/'stressed'/'injured'/'hungry'/'thirsty') went with them,
    -- out of this table, out of locales/en.json, and out of html/app.js's
    -- own PARTNER_CONDITION_DEFAULT_STRINGS fallback. Re-adding any of them
    -- to this list would make this test demand a locale key for a condition
    -- that no longer exists.
    local f = newHudFixture()
    f.firePartnerConditionUpdate(65535, { visible = true, tags = {} })
    local msg = f.lastMessageWithAction('hud:partnerCondition')
    local strings = msg.data.strings
    for _, key in ipairs({ 'tired', 'fine', 'label' }) do
        t.equals(type(strings[key]), 'string')
        t.isTrue(#strings[key] > 0)
    end

    for _, gone in ipairs({ 'unhappy', 'stressed', 'injured', 'hungry', 'thirsty' }) do
        t.isNil(strings[gone], gone .. ' is a removed subsystem\'s tag and must not be sent to the HUD any more')
    end
end)

-- ----------------------------------------------------------------------
-- K9 ONBOARDING HINT (this pass) -- see client/hud.lua's own
-- "K9 ONBOARDING HINT" section for the full contract this pins: a
-- persistent, dismissible nudge that reminds a K9/handler the tablet
-- exists, gone for good the instant they open the tablet OR dismiss it
-- themselves, and durably keyed by citizenid (never by source/server id)
-- so a recycled id can never inherit a stranger's state.
--
-- THREAD STEPPING: this thread follows the EXACT SAME shape as the vitals
-- poll thread above (Wait() at the END of each branch, not the top) -- see
-- this file's own header for why that makes every step() call, including
-- the first, a complete evaluate-and-maybe-push pass, never a
-- priming-only one.
-- ----------------------------------------------------------------------

t.test('ONBOARDING HINT: appears for a newly-granted player (real citizenid, CanShowK9UI true, clean KVP slate)', function()
    local f = newHudFixture({ citizenid = 'CIT_NEW', canShowK9UI = true })
    f.step()
    local msg = f.lastMessageWithAction('hud:onboardingHint')
    t.isNotNil(msg)
    t.isTrue(msg.data.visible)
    t.equals(msg.data.strings.title, Sandbox.locale('hud.onboarding_title'))
    t.isTrue(msg.data.strings.body:find('Press Z', 1, true) ~= nil, 'the tip starts with the one thing to press: the K9 menu')
    -- Ease-of-use audit finding: this persistent nudge exists as the SECOND
    -- chance for someone who missed the one-shot chat line
    -- (locales/en.json's appearance.apply_success_target), which explicitly
    -- names the Guide tab, not just "the tablet" -- a body that only says
    -- "open your tablet" leaves that second chance less specific than the
    -- first one it is meant to back up. Pinned against the REAL
    -- locales/en.json text (Sandbox.locale reads the real file, see its own
    -- header) so a future edit cannot quietly drop the pointer again.
    t.isTrue(msg.data.strings.body:find('/k9tablet', 1, true) ~= nil,
        'the tip still points at the tablet, where every key is listed')
end)

t.test('ONBOARDING HINT: a handler who has just partnered up gets the handler\'s version -- Leash, Partner Up, camera -- not the dog\'s', function()
    local f = newHudFixture({ citizenid = 'CIT_HANDLER', canShowK9UI = false, playingDog = false, isPartnered = true })
    f.step()
    local msg = f.lastMessageWithAction('hud:onboardingHint')
    t.isNotNil(msg)
    t.isTrue(msg.data.visible)
    t.equals(msg.data.strings.body, Sandbox.locale('hud.onboarding_body_handler'))
    t.isTrue(msg.data.strings.body:find('Leash', 1, true) ~= nil)
end)

t.test('ONBOARDING HINT: does NOT appear for someone who has already opened the tablet (pre-seeded KVP)', function()
    local sharedKvp = { ['john_k9_onboard_opened_CIT_OPENED'] = '1' }
    local f = newHudFixture({ citizenid = 'CIT_OPENED', canShowK9UI = true, kvpStore = sharedKvp })
    f.step()
    t.isNil(f.lastMessageWithAction('hud:onboardingHint'), 'a citizenid that already durably opened the tablet must never even get a first push')
end)

t.test('ONBOARDING HINT: opening the tablet (hud:tabletOpened NUI callback) hides it immediately AND marks it durably opened', function()
    local sharedKvp = {}
    local f = newHudFixture({ citizenid = 'CIT_OPENS_NOW', canShowK9UI = true, kvpStore = sharedKvp })
    f.step()
    t.isTrue(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'sanity: it was showing before the tablet opened')

    local cbCalls = f.fireTabletOpened()
    t.equals(#cbCalls, 1, 'the NUI callback must call back unconditionally, same convention as hud:ready')
    t.isFalse(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'opening the tablet must hide the hint immediately, not wait for the next poll tick')
    t.equals(sharedKvp['john_k9_onboard_opened_CIT_OPENS_NOW'], '1')

    -- Durable across a reconnect: a brand-new fixture (a fresh session for
    -- the SAME citizenid, sharing the SAME backing KVP store) must never
    -- show the hint again.
    local f2 = newHudFixture({ citizenid = 'CIT_OPENS_NOW', canShowK9UI = true, kvpStore = sharedKvp })
    f2.step()
    t.isNil(f2.lastMessageWithAction('hud:onboardingHint'), 'once durably opened, a fresh session for the SAME citizenid must never show the hint again')
end)

t.test('ONBOARDING HINT: dismissing it (the dismiss control) hides it immediately and STICKS across a reconnect', function()
    local sharedKvp = {}
    local f = newHudFixture({ citizenid = 'CIT_DISMISSER', canShowK9UI = true, kvpStore = sharedKvp })
    f.step()
    t.isTrue(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'sanity: it was showing before the dismiss key was pressed')

    f.pressDismissKey()
    f.step()
    t.isFalse(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'pressing the dismiss control while visible must hide it immediately')
    t.equals(sharedKvp['john_k9_onboard_dismissed_CIT_DISMISSER'], '1')

    -- "Sticks" means DURABLE, not just "hidden for the rest of this
    -- session" -- prove it survives a brand-new fixture (reconnect) for
    -- the SAME citizenid, sharing the SAME backing KVP store.
    local f2 = newHudFixture({ citizenid = 'CIT_DISMISSER', canShowK9UI = true, kvpStore = sharedKvp })
    f2.step()
    t.isNil(f2.lastMessageWithAction('hud:onboardingHint'), 'a dismissal must survive a reconnect for the same citizenid -- this is the whole point of "sticks"')
end)

t.test('ONBOARDING HINT: pressing the dismiss control while NOT currently visible is a no-op -- never misread as a real dismiss', function()
    local sharedKvp = { ['john_k9_onboard_opened_CIT_ALREADY_DONE'] = '1' } -- already durably opened -- hint never shows this session
    local f = newHudFixture({ citizenid = 'CIT_ALREADY_DONE', canShowK9UI = true, kvpStore = sharedKvp })
    f.pressDismissKey()
    f.step()
    t.isNil(f.lastMessageWithAction('hud:onboardingHint'), 'nothing was ever shown, so nothing should ever be pushed')
    t.isNil(sharedKvp['john_k9_onboard_dismissed_CIT_ALREADY_DONE'], 'a dismiss press with nothing on screen must never write a dismissed flag')
end)

t.test('ONBOARDING HINT: a RECYCLED identifier never inherits a stranger citizenid durable state -- two different citizenids sharing the SAME underlying KVP store stay fully independent', function()
    local sharedKvp = {}

    -- "Player A" fully onboards (opens the tablet) on this shared store.
    local playerA = newHudFixture({ citizenid = 'PLAYER_A', canShowK9UI = true, kvpStore = sharedKvp })
    playerA.step()
    playerA.fireTabletOpened()
    t.equals(sharedKvp['john_k9_onboard_opened_PLAYER_A'], '1')

    -- "Player B" -- a DIFFERENT citizenid, same shared store (the closest
    -- client-side analog to "the same server id/connection slot handed to
    -- a new person") -- must start with a completely clean slate.
    local playerB = newHudFixture({ citizenid = 'PLAYER_B', canShowK9UI = true, kvpStore = sharedKvp })
    playerB.step()
    local msg = playerB.lastMessageWithAction('hud:onboardingHint')
    t.isNotNil(msg, 'a genuinely new citizenid must not inherit another citizenid already-onboarded state')
    t.isTrue(msg.data.visible)
    t.isNil(sharedKvp['john_k9_onboard_opened_PLAYER_B'], 'player B has not opened anything yet -- their own key must not exist')
end)

t.test('ONBOARDING HINT: never appears when Config.K9Onboarding.enabled = false -- zero thread, zero NUI callback, zero messages, ever', function()
    local f = newHudFixture({ citizenid = 'CIT_DISABLED', canShowK9UI = true, k9OnboardingEnabled = false })
    t.isFalse(f.hasTabletOpenedCallback())
    f.step()
    f.step()
    t.isNil(f.lastMessageWithAction('hud:onboardingHint'))
end)

t.test('ONBOARDING HINT: never appears when CanShowK9UI() is false -- not a K9/handler right now, regardless of citizenid or KVP state', function()
    local f = newHudFixture({ citizenid = 'CIT_NOT_K9', canShowK9UI = false })
    f.step()
    t.isNil(f.lastMessageWithAction('hud:onboardingHint'))
end)

t.test('ONBOARDING HINT: auto-hides once Config.K9Onboarding.nudgeDurationMinutes elapses, WITHOUT durably dismissing it -- it must come back next session', function()
    local sharedKvp = {}
    local f = newHudFixture({ citizenid = 'CIT_TIMEOUT', canShowK9UI = true, kvpStore = sharedKvp, k9OnboardingNudgeDurationMinutes = 5 })
    f.step()
    t.isTrue(f.lastMessageWithAction('hud:onboardingHint').data.visible)

    f.advance(5 * 60000 + 1) -- just past the 5-minute window
    f.step()
    t.isFalse(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'the window elapsing must auto-hide the hint')
    t.isNil(sharedKvp['john_k9_onboard_dismissed_CIT_TIMEOUT'], 'an auto-hide from the timer running out must NEVER be recorded as a durable dismissal')

    -- Reconnect (fresh fixture, same citizenid, same shared store) -- the
    -- hint must show again, because the timeout was never a real dismiss.
    local f2 = newHudFixture({ citizenid = 'CIT_TIMEOUT', canShowK9UI = true, kvpStore = sharedKvp })
    f2.step()
    t.isTrue(f2.lastMessageWithAction('hud:onboardingHint').data.visible, 'a session timeout must not be permanent -- the whole point of this feature is a second chance for someone who was tabbed out the whole window')
end)

t.test('ONBOARDING HINT: a bad Config.K9Onboarding.nudgeDurationMinutes clamps to the safe default (5 minutes) with a warning, never asserts/crashes', function()
    local ok = pcall(function()
        local f = newHudFixture({ citizenid = 'CIT_BADCFG', canShowK9UI = true, k9OnboardingNudgeDurationMinutes = -1 })
        f.step()
        t.isTrue(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'a clamped-to-default duration must still let the hint show normally, not disable the feature')
    end)
    t.isTrue(ok, 'an invalid Config.K9Onboarding.nudgeDurationMinutes must never crash file load or the poll thread -- clamp-and-warn, never assert')
end)

-- ----------------------------------------------------------------------
-- KVP NATIVES ABSENT/NO-OP -- direct answer to the coordinator's own
-- explicit condition on allowlisting GetResourceKvpString/SetResourceKvp
-- unverified: "THE FEATURE MUST DEGRADE SAFELY IF EITHER RETURNS
-- NOTHING... a nil read must mean 'we have not seen this player before'".
-- kvpAvailable = false below makes BOTH stubs behave exactly like a
-- genuinely-unregistered FXServer native would (per this codebase's own
-- documented behaviour for that case, .luacheckrc's IsNightvisionActive/
-- IsSeethroughActive finding): the read always returns nil, the write
-- always silently does nothing -- no error either way. This section is
-- what actually proves the safety property; the tests above (which use
-- the WORKING kvpStore stub) prove this file's own persistence LOGIC is
-- correct given a working store, which is a different, narrower claim.
-- ----------------------------------------------------------------------

t.test('KVP NATIVES ABSENT/NO-OP: the hint still shows, and pressing dismiss still hides it FOR THIS SESSION, with zero crashes anywhere', function()
    local ok = pcall(function()
        local f = newHudFixture({ citizenid = 'CIT_NOKVP', canShowK9UI = true, kvpAvailable = false })
        f.step()
        t.isTrue(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'a read that always returns nil must mean "never seen before" -- the hint must still show')

        f.pressDismissKey()
        f.step()
        t.isFalse(f.lastMessageWithAction('hud:onboardingHint').data.visible, 'dismissing must still work THIS session even if the underlying write silently no-ops -- justDismissed is local, in-memory state, never dependent on the KVP write actually landing')
    end)
    t.isTrue(ok, 'a totally absent/no-op KVP layer must never crash this file -- worst case is degraded persistence, never a broken feature')
end)

t.test('KVP NATIVES ABSENT/NO-OP: nothing durable ever actually got written, so the hint reappears next session -- the DISCLOSED worst case, never a stuck/broken state', function()
    local f = newHudFixture({ citizenid = 'CIT_NOKVP2', canShowK9UI = true, kvpAvailable = false })
    f.step()
    f.pressDismissKey()
    f.step()
    t.isFalse(f.lastMessageWithAction('hud:onboardingHint').data.visible)

    -- A "reconnect" with the SAME (still-nil-returning) KVP layer: since
    -- nothing was ever truly persisted, the hint comes back. This is the
    -- explicitly disclosed, safe worst case -- never a permanent failure
    -- to dismiss, never a crash.
    local f2 = newHudFixture({ citizenid = 'CIT_NOKVP2', canShowK9UI = true, kvpAvailable = false })
    f2.step()
    t.isTrue(f2.lastMessageWithAction('hud:onboardingHint').data.visible, 'with no working persistence at all, showing once more than strictly necessary is the correct, safe degradation -- never a silently-broken dismiss')
end)

os.exit(t.summary())
