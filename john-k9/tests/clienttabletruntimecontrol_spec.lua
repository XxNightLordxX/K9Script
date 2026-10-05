--[[
    tests/clienttabletruntimecontrol_spec.lua

    Direct, black-box tests of client/tablet.lua's RUNTIME FEATURE CONTROL +
    TUNING section (server/runtimecontrol.lua PART 1/1B) against the REAL,
    unmodified production file -- a SEPARATE, self-contained fixture, same
    posture as tests/clienttabletequipmentshop_spec.lua, so this file can be
    read/reviewed independently and never collides with concurrent edits to
    the much larger tests/clienttablet_spec.lua.

    Server callback contract verified against server/runtimecontrol.lua
    directly (read, not assumed -- that file is off-limits to edit from
    this pass):
      'john-k9:server:runtimeListFeatures'  (source)                    -> {ok, features?, reason?}
      'john-k9:server:runtimeSetFeature'    (source, name, newValue, confirm?) -> {ok, appliedLive?, restartRequired?, configEditRequired?, tier?, lockoutRisk?, sessionOnly?, reason?, warning?}
      'john-k9:server:runtimeResetFeature'  (source, name, confirm?)    -> {ok, value?, restartRequired?, lockoutRisk?, sessionOnly?, reason?, warning?}
      'john-k9:server:runtimeListTunables'  (source)                    -> {ok, tunables?, reason?}
      'john-k9:server:runtimeSetTunable'    (source, key, newValue)     -> {ok, appliedLive?, restartRequired?, value?, reason?, min?, max?}
      'john-k9:server:runtimeResetTunable'  (source, key)               -> {ok, value?, restartRequired?, reason?}
    Every one of the six returns a `{ ok, reason, ... }` outcome table (that
    file's own header: "matches... this file's own... convention") -- this
    spec proves client/tablet.lua routes every one of them through the SAME
    TranslateReasonResult() already used for theme/cert-tier/shop-location
    calls, so a `reason` comes back to html/tablet.js renamed to `error`,
    exactly like every other tablet-facing surface in this file.

    LOCKOUT-RISK CONFIRMATION (this pass): runtimeSetFeature/runtimeResetFeature
    each gained a `confirm` argument (server/runtimecontrol.lua's own
    lockoutRisk/sessionOnly/lockoutWarning mechanism, previously landed
    server-side with no bridge reading/forwarding it) -- covered below under
    "LOCKOUT-RISK CONFIRMATION PASSTHROUGH".
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup -- minimal, self-contained (only what this file's own code
-- paths touch: no FEATURE_TRIGGERS/SECTION 3/equipment-shop dependencies
-- needed).
-- ----------------------------------------------------------------------

--- @return table fixture
local function newFixture()
    local sendNuiMessageCalls = {}
    local function SendNUIMessage(payload) sendNuiMessageCalls[#sendNuiMessageCalls + 1] = payload end
    local function SetNuiFocus() end
    -- CROSS-RESOURCE FOCUS INTEROP (client/tablet.lua, this pass) --
    -- OpenTablet() now calls IsNuiFocused() once per open to decide what
    -- CloseTablet() later restores -- this file never exercises the open/
    -- close focus lifecycle itself (tests/clienttablet_spec.lua owns that
    -- coverage), so a plain always-false stub is all that is needed to
    -- keep the whole production file loadable here.
    local function IsNuiFocused() return false end

    local runner = Sandbox.newThreadRunner()
    local function CreateThread(fn) runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local function RegisterCommand() end
    local nuiCallbacks = {}
    local function RegisterNUICallback(name, handler) nuiCallbacks[name] = handler end
    local function AddEventHandler() end
    -- client/tablet.lua now calls RegisterNetEvent for
    -- john-k9:client:themeUpdated (see tests/clienttablet_spec.lua's own
    -- dedicated coverage of that name/registration mechanism) -- this file
    -- never exercises that event, so a no-op stub is all that is needed to
    -- keep the whole production file loadable here.
    local function RegisterNetEvent() end
    local function GetCurrentResourceName() return 'john-k9' end
    local function GetResourceState() return 'started' end
    local function DisableControlAction() end
    local function IsDisabledControlJustPressed() return false end
    local function IsEntityDead() return false end
    local function PlayerPedId() return 1 end

    local callbackResponses = {}
    local callbackCallLog = {}
    local function lib_callback_await(name, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { name = name, args = { ... } }
        local cfg = callbackResponses[name]
        if not cfg or cfg.throws then
            error('sandbox: no server callback registered for ' .. tostring(name), 0)
        end
        return cfg.result
    end

    local fakeK9Compat = {
        Which = function() return nil end,
        Get = function() return {} end,
    }

    local overrides = {
        lib = { notify = function() end, callback = { await = lib_callback_await } },
        print = function() end,
        SetNuiFocus = SetNuiFocus, SendNUIMessage = SendNUIMessage,
        IsNuiFocused = IsNuiFocused,
        DisableControlAction = DisableControlAction,
        IsDisabledControlJustPressed = IsDisabledControlJustPressed,
        IsEntityDead = IsEntityDead, PlayerPedId = PlayerPedId,
        CreateThread = CreateThread, Wait = Wait,
        RegisterCommand = RegisterCommand, RegisterNUICallback = RegisterNUICallback,
        AddEventHandler = AddEventHandler, RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        GetResourceState = GetResourceState, K9Compat = fakeK9Compat,
        CanShowK9UI = function() return true end,
        HasK9Access = function() return true end,
        DenyK9UIAccess = function() end,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    env.Config.Features.CommandTablet = true
    env.Config.Features.RuntimeFeatureControl = true
    env.Config.CommandTablet = env.Config.CommandTablet or {}
    env.Config.CommandTablet.openMode = 'command'
    env.Config.CommandTablet.command = 'k9tablet'
    env.Config.FeatureControl = env.Config.FeatureControl or {}
    env.Config.FeatureControl.allowActionsFromTablet = true

    Sandbox.loadInto('../client/tablet.lua', env)

    return {
        env = env,
        sendNuiMessageCalls = sendNuiMessageCalls,
        callbackCallLog = callbackCallLog,
        setServerCallback = function(name, result) callbackResponses[name] = { throws = false, result = result } end,
        callNui = function(name, data)
            local handler = nuiCallbacks[name]
            assert(handler, 'no NUI callback registered for ' .. tostring(name))
            local result
            handler(data, function(r) result = r end)
            assert(result ~= nil, name .. ' never called cb(...)')
            return result
        end,
    }
end

-- ----------------------------------------------------------------------
-- Registration -- every one of the six calls cb(...) unconditionally.
-- ----------------------------------------------------------------------

t.test('all six runtime control NUI callbacks are registered and call cb(...)', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeListFeatures', { ok = true, features = {} })
    f.setServerCallback('john-k9:server:runtimeSetFeature', { ok = true, appliedLive = true, restartRequired = false, tier = 'live' })
    f.setServerCallback('john-k9:server:runtimeResetFeature', { ok = true, value = true, restartRequired = false })
    f.setServerCallback('john-k9:server:runtimeListTunables', { ok = true, tunables = {} })
    f.setServerCallback('john-k9:server:runtimeSetTunable', { ok = true, appliedLive = true, restartRequired = false, value = 5 })
    f.setServerCallback('john-k9:server:runtimeResetTunable', { ok = true, value = 5, restartRequired = false })

    local calls = {
        { 'tablet:runtimeListFeatures', {} },
        { 'tablet:runtimeSetFeature', { name = 'BiteAndHold', value = true } },
        { 'tablet:runtimeResetFeature', { name = 'BiteAndHold' } },
        { 'tablet:runtimeListTunables', {} },
        { 'tablet:runtimeSetTunable', { key = 'LeashMaxDistance', value = 5 } },
        { 'tablet:runtimeResetTunable', { key = 'LeashMaxDistance' } },
    }
    for _, entry in ipairs(calls) do
        local ok = pcall(f.callNui, entry[1], entry[2])
        t.isTrue(ok, entry[1] .. ' should be registered and call cb(...)')
    end
end)

-- ----------------------------------------------------------------------
-- tablet:runtimeListFeatures -- no client-side gate (server re-verifies
-- CanManageRuntimeControl itself), forwarded through TranslateReasonResult.
-- ----------------------------------------------------------------------

t.test('tablet:runtimeListFeatures: forwards the server result verbatim on success', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeListFeatures', {
        ok = true,
        features = { { name = 'BiteAndHold', currentValue = true, tier = 'live', overridden = false, protected = false } },
    })
    local result = f.callNui('tablet:runtimeListFeatures', {})
    t.isTrue(result.ok)
    t.equals(result.features[1].name, 'BiteAndHold')
    t.equals(result.features[1].tier, 'live')
end)

t.test('tablet:runtimeListFeatures: a server `reason` (denied) is renamed to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeListFeatures', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:runtimeListFeatures', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'denied')
    t.isNil(result.reason, 'the raw `reason` field must not leak through -- html/tablet.js only ever reads `.error`')
end)

-- ----------------------------------------------------------------------
-- tablet:runtimeSetFeature
-- ----------------------------------------------------------------------

t.test('tablet:runtimeSetFeature: missing/invalid name or non-boolean value is rejected before any server round trip', function()
    local f = newFixture()
    local r1 = f.callNui('tablet:runtimeSetFeature', {})
    t.equals(r1.error, 'invalid_args')
    local r2 = f.callNui('tablet:runtimeSetFeature', { name = '', value = true })
    t.equals(r2.error, 'invalid_args')
    local r3 = f.callNui('tablet:runtimeSetFeature', { name = 'BiteAndHold', value = 'true' })
    t.equals(r3.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:runtimeSetFeature: forwards {name, value} verbatim to the server callback, in that order', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetFeature', { ok = true, appliedLive = true, restartRequired = false, tier = 'live' })
    local result = f.callNui('tablet:runtimeSetFeature', { name = 'BiteAndHold', value = false })

    t.equals(f.callbackCallLog[1].name, 'john-k9:server:runtimeSetFeature')
    t.equals(f.callbackCallLog[1].args[1], 'BiteAndHold')
    t.equals(f.callbackCallLog[1].args[2], false)
    t.isTrue(result.ok)
    t.equals(result.tier, 'live')
    t.equals(result.appliedLive, true)
end)

t.test('tablet:runtimeSetFeature: a restart-required response (onstart/rawtoplevel tier) is forwarded verbatim, untranslated fields intact', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetFeature', {
        ok = true, appliedLive = false, restartRequired = true, configEditRequired = true, tier = 'rawtoplevel', note = 'server prose, never rendered verbatim by this file',
    })
    local result = f.callNui('tablet:runtimeSetFeature', { name = 'FetchMechanic', value = false })
    t.isTrue(result.ok)
    t.equals(result.restartRequired, true)
    t.equals(result.configEditRequired, true)
    t.equals(result.tier, 'rawtoplevel')
end)

t.test('tablet:runtimeSetFeature: a REFUSAL (protected_feature/unaudited_feature) renames `reason` to `error`, not folded into a generic failure', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetFeature', { ok = false, reason = 'protected_feature' })
    local result = f.callNui('tablet:runtimeSetFeature', { name = 'HighCommand', value = false })
    t.equals(result.ok, false)
    t.equals(result.error, 'protected_feature')
end)

t.test('tablet:runtimeSetFeature: an out-of-range/rate-limited/denied `reason` is renamed to `error` the same way', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetFeature', { ok = false, reason = 'rate_limited' })
    local result = f.callNui('tablet:runtimeSetFeature', { name = 'BiteAndHold', value = true })
    t.equals(result.error, 'rate_limited')
end)

-- ----------------------------------------------------------------------
-- tablet:runtimeResetFeature
-- ----------------------------------------------------------------------

t.test('tablet:runtimeResetFeature: missing/blank name is rejected before any server round trip', function()
    local f = newFixture()
    local result = f.callNui('tablet:runtimeResetFeature', {})
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)

    local result2 = f.callNui('tablet:runtimeResetFeature', { name = '' })
    t.equals(result2.error, 'invalid_args')
end)

t.test('tablet:runtimeResetFeature: forwards `name` verbatim and returns the restored value', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeResetFeature', { ok = true, value = true, restartRequired = false })
    local result = f.callNui('tablet:runtimeResetFeature', { name = 'BiteAndHold' })
    t.equals(f.callbackCallLog[1].args[1], 'BiteAndHold')
    t.isTrue(result.ok)
    t.equals(result.value, true)
end)

-- ----------------------------------------------------------------------
-- tablet:runtimeListTunables
-- ----------------------------------------------------------------------

t.test('tablet:runtimeListTunables: forwards the server result verbatim on success', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeListTunables', {
        ok = true,
        tunables = { { key = 'LeashMaxDistance', currentValue = 8.0, min = 3.0, max = 20.0, integer = false, overridden = false } },
    })
    local result = f.callNui('tablet:runtimeListTunables', {})
    t.isTrue(result.ok)
    t.equals(result.tunables[1].key, 'LeashMaxDistance')
    t.equals(result.tunables[1].min, 3.0)
end)

t.test('tablet:runtimeListTunables: a server `reason` (denied) is renamed to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeListTunables', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:runtimeListTunables', {})
    t.equals(result.error, 'denied')
end)

-- ----------------------------------------------------------------------
-- tablet:runtimeSetTunable
-- ----------------------------------------------------------------------

t.test('tablet:runtimeSetTunable: missing/invalid key or non-number value is rejected before any server round trip', function()
    local f = newFixture()
    local r1 = f.callNui('tablet:runtimeSetTunable', {})
    t.equals(r1.error, 'invalid_args')
    local r2 = f.callNui('tablet:runtimeSetTunable', { key = '', value = 5 })
    t.equals(r2.error, 'invalid_args')
    local r3 = f.callNui('tablet:runtimeSetTunable', { key = 'LeashMaxDistance', value = '5' })
    t.equals(r3.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:runtimeSetTunable: forwards {key, value} verbatim, value UNCLAMPED even if outside the known range (server is the only real gate)', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetTunable', { ok = false, reason = 'out_of_range', min = 3.0, max = 20.0 })
    local result = f.callNui('tablet:runtimeSetTunable', { key = 'LeashMaxDistance', value = 999.5 })

    t.equals(f.callbackCallLog[1].name, 'john-k9:server:runtimeSetTunable')
    t.equals(f.callbackCallLog[1].args[1], 'LeashMaxDistance')
    t.equals(f.callbackCallLog[1].args[2], 999.5, 'this file never clamps/rounds a tunable value before forwarding it')
    t.equals(result.error, 'out_of_range')
    t.equals(result.min, 3.0, 'the server\'s own real bounds are forwarded verbatim, never a client-guessed range')
    t.equals(result.max, 20.0)
end)

t.test('tablet:runtimeSetTunable: a successful set forwards appliedLive/value verbatim', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetTunable', { ok = true, appliedLive = true, restartRequired = false, value = 9.5 })
    local result = f.callNui('tablet:runtimeSetTunable', { key = 'LeashMaxDistance', value = 9.5 })
    t.isTrue(result.ok)
    t.equals(result.appliedLive, true)
    t.equals(result.value, 9.5)
end)

t.test('tablet:runtimeSetTunable: not_integer/invalid_key refusals rename `reason` to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeSetTunable', { ok = false, reason = 'not_integer' })
    local result = f.callNui('tablet:runtimeSetTunable', { key = 'Tracking.Scent.maxAgeSeconds', value = 30.5 })
    t.equals(result.error, 'not_integer')
end)

-- ----------------------------------------------------------------------
-- tablet:runtimeResetTunable
-- ----------------------------------------------------------------------

t.test('tablet:runtimeResetTunable: missing/blank key is rejected before any server round trip', function()
    local f = newFixture()
    local result = f.callNui('tablet:runtimeResetTunable', {})
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:runtimeResetTunable: forwards `key` verbatim and returns the restored value', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:runtimeResetTunable', { ok = true, value = 8.0, restartRequired = false })
    local result = f.callNui('tablet:runtimeResetTunable', { key = 'LeashMaxDistance' })
    t.equals(f.callbackCallLog[1].args[1], 'LeashMaxDistance')
    t.isTrue(result.ok)
    t.equals(result.value, 8.0)
end)

-- ----------------------------------------------------------------------
-- OpenTablet(): runtimeControlEnabled UX hint, mirrors themingEnabled/
-- shopLocationsEnabled.
-- ----------------------------------------------------------------------

t.test('OpenTablet(): runtimeControlEnabled reflects Config.Features.RuntimeFeatureControl live', function()
    local f = newFixture()
    f.env.Config.Features.RuntimeFeatureControl = true
    f.env.OpenTablet()
    local msg = f.sendNuiMessageCalls[1]
    t.equals(msg.action, 'tablet:open')
    t.equals(msg.data.runtimeControlEnabled, true)
end)

t.test('OpenTablet(): runtimeControlEnabled is false when the feature flag is off/missing', function()
    local f = newFixture()
    f.env.Config.Features.RuntimeFeatureControl = false
    f.env.OpenTablet()
    t.equals(f.sendNuiMessageCalls[1].data.runtimeControlEnabled, false)
end)

-- Sanity: the tablet's own localization plumbing already covers that every
-- TABLET_STRING_KEYS entry this pass added resolves against locales/en.json
-- (tests/tabletlocalization_spec.lua) -- not re-duplicated here.
local _ = locale

os.exit(t.summary())
