--[[
    tests/clientfeatureblocks_spec.lua

    Direct, black-box tests of client/featureblocks.lua against the REAL,
    unmodified production file: IsK9FeatureBlocked()'s plain table read and
    its "unknown name" / "before first sync" fail-OPEN answer, the
    `john-k9:client:featureBlocksSync` handler's origin check
    (`source ~= 65535`), its defensive allowlist filtering (a name outside
    the twelve CLIENT_ENFORCED_FEATURES, or a non-string entry, is dropped
    rather than stored), its full-REPLACE-not-merge semantics (a feature
    absent from a later sync is authoritatively "not blocked now"), and the
    local `john-k9:client:featureBlocksApplied` re-broadcast this file
    fires after every processed sync (consumed by client/radial.lua -- see
    tests/clientradial_spec.lua for that side).

    PENDING LOCALE KEY -- same accommodation as tests/clientvision_spec.lua's
    own "PENDING LOCALE KEY" section (read that file's header first if this
    one looks unfamiliar): DenyK9FeatureBlocked() calls the REAL
    `locale('common.k9_feature_blocked')`, a key this pass's own report
    requests from the locales/en.json owner but that has not landed there
    yet. Sandbox.locale() deliberately asserts every key it is asked for
    actually exists -- correct for every OTHER key in this suite, but it
    would fail this file's own DenyK9FeatureBlocked() test for a reason
    that has nothing to do with this file's own logic being correct.
    `localeAllowingPending` below delegates every OTHER key to the real,
    strict `Sandbox.locale` unchanged. DELETE once locales/en.json actually
    carries this key.

    STUBBING EFFORT: `lib.notify` is the only cross-file surface this file
    touches at all -- a trivial capturing stub. No natives, no threads, no
    coroutines.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local PENDING_LOCALE_KEYS = {
    ['common.k9_feature_blocked'] = 'High Command has blocked this ability for you.',
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

--- @return table fixture
local function newFeatureBlocksFixture()
    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local eventHandlers = {}
    local function RegisterNetEvent(eventName, handler)
        eventHandlers[eventName] = handler
    end
    local localHandlers = {}
    local function AddEventHandler(eventName, handler)
        localHandlers[eventName] = localHandlers[eventName] or {}
        localHandlers[eventName][#localHandlers[eventName] + 1] = handler
    end
    local triggerEventCalls = {}
    local function TriggerEvent(eventName, ...)
        triggerEventCalls[#triggerEventCalls + 1] = eventName
        -- Faithfully dispatch to any locally-registered AddEventHandler,
        -- exactly like the real FiveM TriggerEvent would for a same-resource
        -- local event -- this is what lets a consumer fixture (this file's
        -- own tests below, and tests/clientradial_spec.lua's
        -- `fireFeatureBlocksApplied`) observe the re-broadcast for real.
        for _, handler in ipairs(localHandlers[eventName] or {}) do
            handler(...)
        end
    end

    local env = Sandbox.newEnv({
        lib = { notify = lib_notify },
        locale = localeAllowingPending,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        TriggerEvent = TriggerEvent,
    })

    Sandbox.loadInto('../client/featureblocks.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        triggerEventCalls = triggerEventCalls,
        --- Fires the real, captured `john-k9:client:featureBlocksSync`
        --- RegisterNetEvent handler, exactly as a server-sent
        --- TriggerClientEvent would.
        --- @param sourceValue any -- 65535 for a genuine server-origin event
        --- @param blockedKeys any
        fireSync = function(sourceValue, blockedKeys)
            local handler = assert(eventHandlers['john-k9:client:featureBlocksSync'],
                'client/featureblocks.lua did not register a john-k9:client:featureBlocksSync handler')
            env.source = sourceValue
            handler(blockedKeys)
        end,
        localAppliedHandlerCount = function() return #(localHandlers['john-k9:client:featureBlocksApplied'] or {}) end,
    }
end

-- ----------------------------------------------------------------------
-- IsK9FeatureBlocked -- plain reads, fail-OPEN defaults
-- ----------------------------------------------------------------------

t.test('IsK9FeatureBlocked: false for every recognised feature before any sync has ever arrived -- fails OPEN, not closed', function()
    local f = newFeatureBlocksFixture()
    for _, name in ipairs({
        'RadialMenu', 'VehicleEntryExit', 'AgilityBasicJump', 'AgilityAdvanced',
        'ThermalVision', 'NightVision', 'HealthStaminaHUD', 'ContrabandScreenFX',
        'AdvancedBarkRadial', 'ProximityAudioFX', 'WaterTrackingDecay', 'CameraFeedPiP',
    }) do
        t.isFalse(f.env.IsK9FeatureBlocked(name), name)
    end
end)

t.test('IsK9FeatureBlocked: false for an unrecognised name, even after a sync -- never errors, never treated as blocked', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, { 'SomeFutureFeatureThisFileDoesNotYetKnowAbout' })
    t.isFalse(f.env.IsK9FeatureBlocked('SomeFutureFeatureThisFileDoesNotYetKnowAbout'))
end)

t.test('a real sync correctly reports a blocked feature as blocked, and every other feature as not blocked', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, { 'NightVision', 'RadialMenu' })
    t.isTrue(f.env.IsK9FeatureBlocked('NightVision'))
    t.isTrue(f.env.IsK9FeatureBlocked('RadialMenu'))
    t.isFalse(f.env.IsK9FeatureBlocked('ThermalVision'))
end)

-- ----------------------------------------------------------------------
-- TRUST BOUNDARY -- source ~= 65535
-- ----------------------------------------------------------------------

t.test('origin guard: source ~= 65535 (a forged local self-trigger) is rejected -- the sync is never applied', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(1234, { 'NightVision' })
    t.isFalse(f.env.IsK9FeatureBlocked('NightVision'))
end)

t.test('origin guard: a real, 65535-sourced sync IS applied', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, { 'NightVision' })
    t.isTrue(f.env.IsK9FeatureBlocked('NightVision'))
end)

-- ----------------------------------------------------------------------
-- DEFENSIVE ALLOWLIST -- a payload entry outside CLIENT_ENFORCED_FEATURES,
-- or of the wrong type, is dropped rather than stored, and a malformed
-- payload shape overall degrades to "nothing blocked" rather than erroring.
-- ----------------------------------------------------------------------

t.test('a feature name outside the twelve-key allowlist is silently dropped, never stored', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, { 'BasicBarkSounds' }) -- server-enforced already; not one of this file's twelve
    t.isFalse(f.env.IsK9FeatureBlocked('BasicBarkSounds'))
end)

t.test('a non-string entry in the payload is silently skipped, never crashes the handler', function()
    local f = newFeatureBlocksFixture()
    local ok = pcall(f.fireSync, 65535, { 'NightVision', 42, {}, true })
    t.isTrue(ok)
    t.isTrue(f.env.IsK9FeatureBlocked('NightVision'), 'the one valid entry alongside the malformed ones must still be applied')
end)

t.test('a non-table payload (nil, a bare string, a number) degrades to "nothing blocked", never errors', function()
    local f = newFeatureBlocksFixture()
    local ok1 = pcall(f.fireSync, 65535, nil)
    t.isTrue(ok1)
    local ok2 = pcall(f.fireSync, 65535, 'NightVision') -- a bare string is NOT a table
    t.isTrue(ok2)
    t.isFalse(f.env.IsK9FeatureBlocked('NightVision'))
end)

-- ----------------------------------------------------------------------
-- FULL REPLACE, NEVER A MERGE
-- ----------------------------------------------------------------------

t.test('a later sync that omits a previously-blocked feature un-blocks it -- full replace, not a merge', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, { 'NightVision', 'ThermalVision' })
    t.isTrue(f.env.IsK9FeatureBlocked('NightVision'))
    t.isTrue(f.env.IsK9FeatureBlocked('ThermalVision'))

    f.fireSync(65535, { 'ThermalVision' }) -- NightVision no longer listed
    t.isFalse(f.env.IsK9FeatureBlocked('NightVision'), 'absence from a later sync must un-block, never leave a stale block standing')
    t.isTrue(f.env.IsK9FeatureBlocked('ThermalVision'))
end)

t.test('an empty-array sync un-blocks everything', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, { 'NightVision' })
    t.isTrue(f.env.IsK9FeatureBlocked('NightVision'))

    f.fireSync(65535, {})
    t.isFalse(f.env.IsK9FeatureBlocked('NightVision'))
end)

-- ----------------------------------------------------------------------
-- LOCAL RE-BROADCAST -- john-k9:client:featureBlocksApplied
-- ----------------------------------------------------------------------

t.test('a genuinely processed sync fires the local featureBlocksApplied re-broadcast exactly once; a rejected (wrong-origin) one never fires it at all', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(1234, { 'NightVision' }) -- rejected by the origin guard, returns before the broadcast
    t.equals(#f.triggerEventCalls, 0, 'a forged/rejected sync must never fire the local re-broadcast either')

    f.fireSync(65535, { 'NightVision' })
    t.equals(#f.triggerEventCalls, 1)
    t.equals(f.triggerEventCalls[1], 'john-k9:client:featureBlocksApplied')
end)

t.test('the local re-broadcast fires even when a sync changes nothing observable (an empty array arriving when already unblocked) -- consumers are cheap to re-run, per this file\'s own header', function()
    local f = newFeatureBlocksFixture()
    f.fireSync(65535, {})
    t.equals(#f.triggerEventCalls, 1)
end)

t.test('a locally-registered featureBlocksApplied listener (e.g. client/radial.lua\'s own) genuinely receives the re-broadcast', function()
    local f = newFeatureBlocksFixture()
    local received = 0
    f.env.AddEventHandler('john-k9:client:featureBlocksApplied', function() received = received + 1 end)

    f.fireSync(65535, { 'RadialMenu' })
    t.equals(received, 1)
end)

-- ----------------------------------------------------------------------
-- DenyK9FeatureBlocked -- the shared denial notify
-- ----------------------------------------------------------------------

t.test('DenyK9FeatureBlocked: notifies exactly once, error type, using the generic k9_feature_blocked message', function()
    local f = newFeatureBlocksFixture()
    f.env.DenyK9FeatureBlocked()
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].type, 'error')
    t.equals(f.notifyCalls[1].description, localeAllowingPending('common.k9_feature_blocked'))
end)

os.exit(t.summary())
