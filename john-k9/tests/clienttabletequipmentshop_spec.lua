--[[
    tests/clienttabletequipmentshop_spec.lua

    Direct, black-box tests of client/tablet.lua's K9 EQUIPMENT SHOP
    LOCATIONS section against the REAL, unmodified production file -- a
    SEPARATE, self-contained fixture rather than an addition to
    tests/clienttablet_spec.lua's already-large one, so this file can be
    read/reviewed independently and never collides with concurrent edits to
    that file.

    Server callback contract verified against server/equipmentshop.lua
    (read, not assumed -- that file is off-limits to edit from this pass):
      'john-k9:server:equipmentShopGetLocations' (source) -> {ok, locations?, reason?}
      'john-k9:server:equipmentShopAddLocation' (source, location) -> {ok, locationKey?, locations?, reason?}
      'john-k9:server:equipmentShopMoveLocation' (source, locationKey, updates) -> {ok, locations?, reason?}
      'john-k9:server:equipmentShopRemoveLocation' (source, locationKey) -> {ok, locations?, reason?}
    All four return a `{ ok, reason, ... }` outcome table (that file's own
    header: "matches server/runtimecontrol.lua's own... precedent") -- this
    spec proves client/tablet.lua routes every one of them through the SAME
    TranslateReasonResult() already used for theme/cert-tier calls, so a
    `reason` comes back to html/tablet.js renamed to `error`, exactly like
    every other tablet-facing surface in this file.

    COORDINATES: server/equipmentshop.lua's own AddLocation/MoveLocation
    callbacks have no way to know where the calling officer is standing --
    this file is the ONLY layer with native access to GetEntityCoords/
    GetEntityHeading (html/tablet.js, a CEF browser page, has none at all).
    The tests below assert those TWO natives are actually called and their
    values actually forwarded, not merely that SOME location table reaches
    the server callback.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup -- minimal, self-contained (only what this file's own
-- code paths touch: no FEATURE_TRIGGERS/SECTION 3 dependencies needed).
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
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
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

    -- PlayerPedId/GetEntityCoords/GetEntityHeading -- the whole point of
    -- this file's own COORDINATES section. Controllable per test.
    local pedId = 42
    local playerCoords = { x = 111.25, y = -222.5, z = 30.0 }
    local playerHeading = 271.5
    local function PlayerPedId() return pedId end
    local getEntityCoordsCalls = {}
    local function GetEntityCoords(entity)
        getEntityCoordsCalls[#getEntityCoordsCalls + 1] = entity
        return playerCoords
    end
    local getEntityHeadingCalls = {}
    local function GetEntityHeading(entity)
        getEntityHeadingCalls[#getEntityHeadingCalls + 1] = entity
        return playerHeading
    end

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
        GetEntityCoords = GetEntityCoords, GetEntityHeading = GetEntityHeading,
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
        getEntityCoordsCalls = getEntityCoordsCalls,
        getEntityHeadingCalls = getEntityHeadingCalls,
        playerCoords = playerCoords,
        playerHeading = playerHeading,
        pedId = pedId,
        setServerCallback = function(name, result) callbackResponses[name] = { throws = false, result = result } end,
        fireEvent = function(eventName, ...)
            for _, handler in ipairs(eventHandlers[eventName] or {}) do
                handler(...)
            end
        end,
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
-- Registration
-- ----------------------------------------------------------------------

t.test('all four equipmentShop NUI callbacks are registered', function()
    local f = newFixture()
    for _, name in ipairs({
        'tablet:equipmentShopGetLocations', 'tablet:equipmentShopAddLocation',
        'tablet:equipmentShopMoveLocation', 'tablet:equipmentShopRemoveLocation',
    }) do
        f.setServerCallback('john-k9:server:equipmentShopGetLocations', { ok = true, locations = {} })
        f.setServerCallback('john-k9:server:equipmentShopAddLocation', { ok = true, locations = {} })
        f.setServerCallback('john-k9:server:equipmentShopMoveLocation', { ok = true, locations = {} })
        f.setServerCallback('john-k9:server:equipmentShopRemoveLocation', { ok = true, locations = {} })
        local ok = pcall(f.callNui, name, {})
        t.isTrue(ok, name .. ' should be registered and call cb(...)')
    end
end)

-- ----------------------------------------------------------------------
-- tablet:equipmentShopGetLocations -- open (no client-side gate at all,
-- matching tablet:getTheme's own no-gate posture), forwarded through
-- TranslateReasonResult.
-- ----------------------------------------------------------------------

t.test('tablet:equipmentShopGetLocations: forwards the server result verbatim on success', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopGetLocations', { ok = true, locations = { ['cfg:1'] = { x = 1, y = 2, z = 3 } } })
    local result = f.callNui('tablet:equipmentShopGetLocations', {})
    t.isTrue(result.ok)
    t.equals(result.locations['cfg:1'].x, 1)
end)

t.test('tablet:equipmentShopGetLocations: a server `reason` (feature_disabled) is renamed to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopGetLocations', { ok = false, reason = 'feature_disabled' })
    local result = f.callNui('tablet:equipmentShopGetLocations', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'feature_disabled')
    t.isNil(result.reason, 'the raw `reason` field must not leak through -- html/tablet.js only ever reads `.error`')
end)

-- ----------------------------------------------------------------------
-- tablet:equipmentShopAddLocation -- COORDINATES captured HERE.
-- ----------------------------------------------------------------------

t.test('tablet:equipmentShopAddLocation: captures GetEntityCoords/GetEntityHeading on PlayerPedId() and forwards them', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopAddLocation', { ok = true, locationKey = 'db:1', locations = {} })
    f.callNui('tablet:equipmentShopAddLocation', {})

    t.equals(#f.getEntityCoordsCalls, 1)
    t.equals(f.getEntityCoordsCalls[1], f.pedId)
    t.equals(#f.getEntityHeadingCalls, 1)

    t.equals(f.callbackCallLog[1].name, 'john-k9:server:equipmentShopAddLocation')
    local sentLocation = f.callbackCallLog[1].args[1]
    t.equals(sentLocation.x, f.playerCoords.x)
    t.equals(sentLocation.y, f.playerCoords.y)
    t.equals(sentLocation.z, f.playerCoords.z)
    t.equals(sentLocation.heading, f.playerHeading)
end)

t.test('tablet:equipmentShopAddLocation: a blank label/model/scenario is OMITTED entirely, never sent as an empty string', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopAddLocation', { ok = true, locations = {} })
    f.callNui('tablet:equipmentShopAddLocation', { label = '', model = '', scenario = '' })

    local sentLocation = f.callbackCallLog[1].args[1]
    t.isNil(sentLocation.label)
    t.isNil(sentLocation.model)
    t.isNil(sentLocation.scenario)
end)

t.test('tablet:equipmentShopAddLocation: a non-empty label/model/scenario is forwarded verbatim', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopAddLocation', { ok = true, locations = {} })
    f.callNui('tablet:equipmentShopAddLocation', { label = 'Downtown K9 Supply', model = 'a_m_m_business_01', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' })

    local sentLocation = f.callbackCallLog[1].args[1]
    t.equals(sentLocation.label, 'Downtown K9 Supply')
    t.equals(sentLocation.model, 'a_m_m_business_01')
    t.equals(sentLocation.scenario, 'WORLD_HUMAN_STAND_IMPATIENT')
end)

t.test('tablet:equipmentShopAddLocation: a rejected add renames `reason` to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopAddLocation', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:equipmentShopAddLocation', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'denied')
end)

-- ----------------------------------------------------------------------
-- tablet:equipmentShopMoveLocation -- serves BOTH "Edit" (metadata) and
-- "Move Here" (position) through the ONE server callback.
-- ----------------------------------------------------------------------

t.test('tablet:equipmentShopMoveLocation: missing/blank locationKey is rejected before any server round trip', function()
    local f = newFixture()
    local result = f.callNui('tablet:equipmentShopMoveLocation', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'invalid_key')
    t.equals(#f.callbackCallLog, 0)

    local result2 = f.callNui('tablet:equipmentShopMoveLocation', { locationKey = '' })
    t.equals(result2.error, 'invalid_key')
end)

t.test('tablet:equipmentShopMoveLocation (Edit): forwards updates.label/model/scenario verbatim, including `false` to reset', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopMoveLocation', { ok = true, locations = {} })
    f.callNui('tablet:equipmentShopMoveLocation', {
        locationKey = 'db:5',
        updates = { label = 'New Label', model = false, scenario = 'WORLD_HUMAN_GUARD_STAND' },
    })

    t.equals(f.callbackCallLog[1].name, 'john-k9:server:equipmentShopMoveLocation')
    t.equals(f.callbackCallLog[1].args[1], 'db:5')
    local updates = f.callbackCallLog[1].args[2]
    t.equals(updates.label, 'New Label')
    t.equals(updates.model, false)
    t.equals(updates.scenario, 'WORLD_HUMAN_GUARD_STAND')
    t.isNil(updates.x, 'Edit alone must never touch position')
    t.equals(#f.getEntityCoordsCalls, 0, 'Edit alone must never capture the caller\'s position')
end)

t.test('tablet:equipmentShopMoveLocation (Move Here): useCurrentPosition captures GetEntityCoords/GetEntityHeading, sends no label/model/scenario', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopMoveLocation', { ok = true, locations = {} })
    f.callNui('tablet:equipmentShopMoveLocation', { locationKey = 'db:5', useCurrentPosition = true })

    t.equals(#f.getEntityCoordsCalls, 1)
    t.equals(#f.getEntityHeadingCalls, 1)
    local updates = f.callbackCallLog[1].args[2]
    t.equals(updates.x, f.playerCoords.x)
    t.equals(updates.y, f.playerCoords.y)
    t.equals(updates.z, f.playerCoords.z)
    t.equals(updates.heading, f.playerHeading)
    t.isNil(updates.label)
    t.isNil(updates.model)
    t.isNil(updates.scenario)
end)

t.test('tablet:equipmentShopMoveLocation: a rejected move (invalid_key from the server itself, e.g. a cfg: key) renames `reason` to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopMoveLocation', { ok = false, reason = 'invalid_key' })
    local result = f.callNui('tablet:equipmentShopMoveLocation', { locationKey = 'cfg:1', useCurrentPosition = true })
    t.equals(result.ok, false)
    t.equals(result.error, 'invalid_key')
end)

-- ----------------------------------------------------------------------
-- tablet:equipmentShopRemoveLocation
-- ----------------------------------------------------------------------

t.test('tablet:equipmentShopRemoveLocation: missing/blank locationKey is rejected before any server round trip', function()
    local f = newFixture()
    local result = f.callNui('tablet:equipmentShopRemoveLocation', {})
    t.equals(result.error, 'invalid_key')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:equipmentShopRemoveLocation: valid key forwards to the server and returns the updated locations', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopRemoveLocation', { ok = true, locations = { ['cfg:1'] = { x = 1, y = 2, z = 3 } } })
    local result = f.callNui('tablet:equipmentShopRemoveLocation', { locationKey = 'db:9' })
    t.isTrue(result.ok)
    t.equals(f.callbackCallLog[1].args[1], 'db:9')
    t.isNotNil(result.locations['cfg:1'])
end)

-- ----------------------------------------------------------------------
-- Live push relay -- john-k9:client:equipmentShopLocationsUpdated
-- ----------------------------------------------------------------------

t.test('john-k9:client:equipmentShopLocationsUpdated relays into SendNUIMessage verbatim, registered unconditionally', function()
    local f = newFixture()
    local before = #f.sendNuiMessageCalls
    local locations = { ['db:2'] = { x = 5, y = 6, z = 7, heading = 90, model = 'a', scenario = '', label = 'L' } }
    f.fireEvent('john-k9:client:equipmentShopLocationsUpdated', locations)

    t.equals(#f.sendNuiMessageCalls, before + 1)
    local msg = f.sendNuiMessageCalls[#f.sendNuiMessageCalls]
    t.equals(msg.action, 'tablet:equipmentShopLocationsUpdated')
    t.equals(msg.data['db:2'].label, 'L')
end)

-- ----------------------------------------------------------------------
-- OpenTablet(): shopLocationsEnabled UX hint, mirrors themingEnabled.
-- ----------------------------------------------------------------------

t.test('OpenTablet(): shopLocationsEnabled reflects Config.Features.K9EquipmentShop live', function()
    local f = newFixture()
    f.env.Config.Features.K9EquipmentShop = true
    f.env.OpenTablet()
    local msg = f.sendNuiMessageCalls[1]
    t.equals(msg.action, 'tablet:open')
    t.equals(msg.data.shopLocationsEnabled, true)
end)

t.test('OpenTablet(): shopLocationsEnabled is false when the feature flag is off/missing', function()
    local f = newFixture()
    f.env.Config.Features.K9EquipmentShop = false
    f.env.OpenTablet()
    t.equals(f.sendNuiMessageCalls[1].data.shopLocationsEnabled, false)
end)

-- ============================================================================
-- K9 EQUIPMENT SHOP ITEM CATALOG bridge (this pass) -- server/equipmentshop.lua's
-- own "EQUIPMENT SHOP ITEM CATALOG" section:
--   'john-k9:server:equipmentShopItemsList' (source) -> {ok, items?, reason?}
--   'john-k9:server:equipmentShopItemsUpsert' (source, payload) -> {ok, items?, reason?}
--   'john-k9:server:equipmentShopItemsReorder' (source, orderedKeys) -> {ok, items?, reason?}
--   'john-k9:server:equipmentShopItemsDelete' (source, key) -> {ok, items?, reason?}
-- Same TranslateReasonResult translation, same "forward the whole payload
-- table verbatim for Upsert, a bare array for Reorder, a bare string key
-- for Delete" shapes as the sibling LOCATIONS bridge above.
-- ============================================================================

t.test('all four equipmentShopItems NUI callbacks are registered', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopItemsList', { ok = true, items = {} })
    f.setServerCallback('john-k9:server:equipmentShopItemsUpsert', { ok = true, items = {} })
    f.setServerCallback('john-k9:server:equipmentShopItemsReorder', { ok = true, items = {} })
    f.setServerCallback('john-k9:server:equipmentShopItemsDelete', { ok = true, items = {} })

    t.isTrue(pcall(f.callNui, 'tablet:equipmentShopItemsList', {}))
    t.isTrue(pcall(f.callNui, 'tablet:equipmentShopItemsUpsert', { key = 'k9_medkit', price = 100 }))
    t.isTrue(pcall(f.callNui, 'tablet:equipmentShopItemsReorder', { orderedKeys = {} }))
    t.isTrue(pcall(f.callNui, 'tablet:equipmentShopItemsDelete', { key = 'k9_medkit' }))
end)

t.test('tablet:equipmentShopItemsList: forwards the server result verbatim on success', function()
    local f = newFixture()
    local items = { { key = 'k9_medkit', label = 'Field Medkit', price = 150, sortOrder = 1 } }
    f.setServerCallback('john-k9:server:equipmentShopItemsList', { ok = true, items = items })
    local result = f.callNui('tablet:equipmentShopItemsList', {})
    t.isTrue(result.ok)
    t.equals(result.items, items)
end)

t.test('tablet:equipmentShopItemsList: a server `reason` (denied) is renamed to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopItemsList', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:equipmentShopItemsList', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'denied')
    t.isNil(result.reason)
end)

t.test('tablet:equipmentShopItemsUpsert: missing key or non-numeric price is invalid_args before any server round trip', function()
    local f = newFixture()
    local missingKey = f.callNui('tablet:equipmentShopItemsUpsert', { price = 100 })
    t.equals(missingKey.error, 'invalid_args')
    local badPrice = f.callNui('tablet:equipmentShopItemsUpsert', { key = 'k9_medkit', price = 'free' })
    t.equals(badPrice.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0, 'neither malformed payload may reach the server at all')
end)

t.test('tablet:equipmentShopItemsUpsert: forwards the WHOLE payload table verbatim as ONE argument', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopItemsUpsert', { ok = true, items = {} })
    local payload = { key = 'k9_medkit', price = 200, label = 'Field Medkit', requiredTierKey = 'senior' }
    f.callNui('tablet:equipmentShopItemsUpsert', payload)
    t.equals(#f.callbackCallLog, 1)
    t.equals(f.callbackCallLog[1].name, 'john-k9:server:equipmentShopItemsUpsert')
    t.equals(f.callbackCallLog[1].args[1], payload)
end)

t.test('tablet:equipmentShopItemsUpsert: reason="invalid_price"/"invalid_required_tier"/"busy" all forward as the plain error code', function()
    local f = newFixture()
    for _, reason in ipairs({ 'invalid_price', 'invalid_required_tier', 'busy' }) do
        f.setServerCallback('john-k9:server:equipmentShopItemsUpsert', { ok = false, reason = reason })
        local result = f.callNui('tablet:equipmentShopItemsUpsert', { key = 'k9_medkit', price = 1 })
        t.equals(result.error, reason)
    end
end)

t.test('tablet:equipmentShopItemsReorder: a non-table orderedKeys is invalid_args before any server round trip', function()
    local f = newFixture()
    local result = f.callNui('tablet:equipmentShopItemsReorder', { orderedKeys = 'not-a-table' })
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:equipmentShopItemsReorder: forwards the bare orderedKeys array as the sole argument', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopItemsReorder', { ok = true, items = {} })
    local orderedKeys = { 'k9_treat', 'k9_medkit' }
    f.callNui('tablet:equipmentShopItemsReorder', { orderedKeys = orderedKeys })
    t.equals(f.callbackCallLog[1].args[1], orderedKeys)
end)

t.test('tablet:equipmentShopItemsDelete: missing/blank key is rejected before any server round trip', function()
    local f = newFixture()
    local missing = f.callNui('tablet:equipmentShopItemsDelete', {})
    t.equals(missing.error, 'invalid_args')
    local blank = f.callNui('tablet:equipmentShopItemsDelete', { key = '' })
    t.equals(blank.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:equipmentShopItemsDelete: forwards the bare key string as the sole argument, and a rejected delete renames `reason` to `error`', function()
    local f = newFixture()
    f.setServerCallback('john-k9:server:equipmentShopItemsDelete', { ok = false, reason = 'unknown_item' })
    local result = f.callNui('tablet:equipmentShopItemsDelete', { key = 'k9_ghost_item' })
    t.equals(result.error, 'unknown_item')
    t.equals(f.callbackCallLog[1].args[1], 'k9_ghost_item')
end)

-- Sanity: the tablet's own localization plumbing already covers that every
-- TABLET_STRING_KEYS entry this pass added resolves against locales/en.json
-- (tests/tabletlocalization_spec.lua) -- not re-duplicated here.
local _ = locale

os.exit(t.summary())
