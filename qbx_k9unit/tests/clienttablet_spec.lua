--[[
    tests/clienttablet_spec.lua

    Direct, black-box tests of client/tablet.lua against the REAL,
    unmodified production file -- same fresh-sandbox-per-test discipline
    as tests/clientradial_spec.lua/tests/clientvision_spec.lua, whose
    fixture-construction style this file follows closely (a `calls` call
    log for every plain "do a thing" cross-file global, `queryState` for
    controllable state-query predicates, Sandbox.newThreadRunner() for the
    ESC/death watch thread).

    PRIORITIES, per this pass's own task brief: focus is released on
    close (NUI-initiated, ESC, own death, resource stop), a THROWN server
    callback fails closed without ever leaving focus held, and the
    Config.Features.CommandTablet flag genuinely gates registration (not
    just behavior). Also covered: Config.CommandTablet.openMode's three
    modes plus its invalid-value fallback, the grant/revoke ->
    html/tablet.js reason/message translation (including the two
    "still has it"/"target offline" nuance cases server/permissions.lua's
    own header calls out by name), the SECTION 3 ExecuteCommand allowlist
    (including tablet:decertify's reuse of it), and a representative
    sample of the SECTION 2 tablet:triggerFeature dispatch table -- one of
    each gate shape (always-gated, ungated-release/gated-attempt toggle,
    HasK9Access-only, fully self-gating passthrough, missing-seam
    soft-fail) rather than all ~20 entries individually, since every entry
    shares one of a small handful of already-proven shapes.

    WATCH-THREAD STEPPING NOTES (see EnsureTabletWatchThreadRunning() in
    client/tablet.lua): unlike client/vision.lua's maintenance thread
    (whose first statement is a plain assignment BEFORE its `while` even
    starts), this thread's loop body itself performs a real check
    (DisableControlAction + the ESC/death branch) BEFORE its own Wait(0)
    -- there is no separate "prime" statement outside the loop. So:
      step() call N -- resumes at (or, for N=1, enters and immediately
        runs) the loop body: re-checks `while tabletOpen do`, and if still
        true, runs ONE real ESC/death check pass, then yields at Wait(0).
      Consequence: if a test's setup makes the NEXT check pass trip
        CloseTablet() (which flips `tabletOpen` false), that flip is only
        OBSERVED by the loop's own `while` condition on the step AFTER the
        one that called CloseTablet() -- so proving full self-termination
        (threadCreateCount resets, a later re-open starts a genuinely NEW
        thread) takes one extra step() beyond the one that visibly closed
        the tablet. Each test below says explicitly which step is which.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { features: table?, commandTablet: table?, featureControl: table?, canShowK9UI: boolean?, hasK9Access: boolean? }?
--- @return table fixture
local function newTabletFixture(opts)
    opts = opts or {}

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local hasK9Access = opts.hasK9Access
    if hasK9Access == nil then hasK9Access = true end

    local canShowK9UICalls, hasK9AccessCalls, denyCalls = 0, 0, 0
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    local function HasK9Access() hasK9AccessCalls = hasK9AccessCalls + 1; return hasK9Access end
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    -- Generic call log -- calls[name] is a list of arg-tuples, one per
    -- invocation, for every plain "do a thing" cross-file global below.
    -- Mirrors tests/clientradial_spec.lua's own `record`/`calls` shape.
    local calls = {}
    local function record(name)
        return function(...)
            calls[name] = calls[name] or {}
            calls[name][#calls[name] + 1] = { ... }
            return calls[name].returnValue
        end
    end

    -- Controllable "current state" query stubs, same shape as
    -- tests/clientradial_spec.lua's own `queryState`/`queryFn`.
    local queryState = {
        isLeashed = false, isInK9Vehicle = false, activeTrackType = nil,
        isBiteHoldEngaged = false, isDragEngaged = false,
        isFetchCarryEngaged = false, isPartnered = false,
    }
    local function queryFn(name, field)
        return function(...)
            calls[name] = calls[name] or {}
            calls[name][#calls[name] + 1] = { ... }
            return queryState[field]
        end
    end

    -- FindNearest*Candidate -- controllable return value (nil = "no
    -- candidate found"), and can be OMITTED entirely (see omitSeams
    -- below) to prove the missing-seam soft-fail path.
    local leashCandidate, partnerCandidate = nil, nil

    local notifyCalls = {}
    local function lib_notify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local printLines = {}
    local function customPrint(...)
        local parts = { ... }
        local strs = {}
        for i = 1, select('#', ...) do strs[i] = tostring(parts[i]) end
        printLines[#printLines + 1] = table.concat(strs, '\t')
    end

    -- SetNuiFocus / SendNUIMessage -- the whole point of this file.
    local setNuiFocusCalls = {}
    local function SetNuiFocus(hasFocus, hasCursor) setNuiFocusCalls[#setNuiFocusCalls + 1] = { hasFocus, hasCursor } end
    local sendNuiMessageCalls = {}
    local function SendNUIMessage(payload) sendNuiMessageCalls[#sendNuiMessageCalls + 1] = payload end

    -- CROSS-RESOURCE FOCUS INTEROP (this pass) -- controllable stand-in for
    -- whether some OTHER resource already holds NUI focus the instant
    -- OpenTablet() checks -- default false (the common case: nobody else
    -- has it), same "opt in to the interesting case" posture as every
    -- other queryState field in this fixture.
    local isNuiFocused = false
    local isNuiFocusedThrows = false
    local function IsNuiFocused()
        if isNuiFocusedThrows then error('sandbox: IsNuiFocused unavailable', 0) end
        return isNuiFocused
    end

    -- ESC/death/takedown watch thread natives.
    local disabledControlJustPressed = false
    local isEntityDead = false
    local disableControlActionCalls = {}
    local function DisableControlAction(...) disableControlActionCalls[#disableControlActionCalls + 1] = { ... } end
    local function IsDisabledControlJustPressed(_pad, _control) return disabledControlJustPressed end
    local function IsEntityDead(_ped) return isEntityDead end
    local function PlayerPedId() return 1 end

    -- DOWNED-BY-TAKEDOWN (this pass, focus-and-state audit finding #2) --
    -- controllable stand-in for client/combat.lua's own
    -- IsLocalPlayerForceRagdolled() resource-global. OMITTED entirely
    -- unless opts.withForceRagdollSeam (default true) -- proving the
    -- `type(fn) == 'function'` soft-dependency guard degrades cleanly,
    -- same "omit the seam, prove the guard" shape as
    -- FindNearestLeashCandidate/FindNearestPartnerCandidate's own
    -- opts.withSeams below.
    local isLocalPlayerForceRagdolled = false

    -- CreateThread/Wait -- Sandbox.newThreadRunner() wrapped so this
    -- fixture can ALSO count how many threads were ever created (same
    -- "already running -> no-op, self-terminate -> a later transition
    -- starts fresh" proof shape as tests/clientvision_spec.lua's own
    -- fixture).
    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        runner.CreateThread(fn)
    end
    local function Wait(ms) runner.Wait(ms) end

    -- RegisterCommand / RegisterNUICallback / AddEventHandler -- capturing.
    local registerCommandCalls = {}
    local function RegisterCommand(name, handler, restricted)
        registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler, restricted = restricted }
    end
    local nuiCallbacks = {}
    local function RegisterNUICallback(name, handler)
        nuiCallbacks[name] = handler -- last registration wins, matching FiveM's own real dedup-by-name behavior
    end
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    -- RegisterNetEvent -- kept in a SEPARATE table from AddEventHandler's
    -- own eventHandlers above on purpose: this sandbox must be able to
    -- prove a given event name was registered as a genuinely NETWORKED
    -- handler (the only kind a real server->client TriggerClientEvent can
    -- ever reach) rather than merely a same-realm AddEventHandler one a
    -- server-fired event never invokes at all -- see
    -- tests/clientequipmentshop_spec.lua's own identical `netEvents`
    -- table/assertion for the sibling case this mirrors.
    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local RESOURCE_NAME = 'qbx_k9unit'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- lib.callback.await -- controllable per-name response/throw, same
    -- "pcall-wrapped, fails closed" contract this whole suite already
    -- exercises for client/main.lua's HasK9Access(). Default: every name
    -- not explicitly configured throws (a truthy simulation of "server
    -- callback not registered yet"), so a test must opt IN a real
    -- response rather than accidentally relying on an unconfigured one.
    local callbackResponses = {} -- name -> { throws: boolean, result: table }
    local callbackCallLog = {}
    local function lib_callback_await(name, _timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { name = name, args = { ... } }
        local cfg = callbackResponses[name]
        if not cfg or cfg.throws then
            error('sandbox: no server callback registered for ' .. tostring(name), 0)
        end
        return cfg.result
    end

    -- FAKE K9COMPAT -- client/tablet.lua no longer calls
    -- `exports.ox_inventory:useItem` directly (routed through
    -- `K9Compat.Get('inventory').UseItem` this pass, see that file's own
    -- IsInventoryUseCapable doc comment); the real shared/compat/
    -- inventory.lua adapter is covered by its own dedicated spec
    -- (tests/compatinventory_spec.lua), so this fixture only needs a
    -- minimal fake whose `Which('inventory')` mirrors the OLD
    -- IsOxInventoryUseCapable's "is a usable inventory currently detected"
    -- gate (`setOxInventoryStarted` below still drives it, same test
    -- semantics as before) and whose `Get('inventory').UseItem` behaves
    -- like the real ox_inventory adapter's own UseItem -- calls `cb`
    -- synchronously with `useItemApproves`, recording `data` the same way
    -- every existing assertion on `f.useItemCalls` already expects.
    local oxInventoryStarted = true
    local useItemApproves = true
    local useItemCalls = {}
    local fakeK9Compat = {
        Which = function(system)
            if system == 'inventory' then
                return oxInventoryStarted and 'ox_inventory' or nil
            end
            return nil
        end,
        Get = function(system)
            if system == 'inventory' then
                return {
                    UseItem = function(data, cb)
                        useItemCalls[#useItemCalls + 1] = data
                        cb(useItemApproves)
                    end,
                }
            end
            return {}
        end,
    }
    local function GetResourceState(_resourceName)
        return 'started'
    end

    local executeCommandCalls = {}
    local function ExecuteCommand(commandString) executeCommandCalls[#executeCommandCalls + 1] = commandString end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(...) triggerServerEventCalls[#triggerServerEventCalls + 1] = { ... } end

    local overrides = {
        CanShowK9UI = CanShowK9UI, HasK9Access = HasK9Access, DenyK9UIAccess = DenyK9UIAccess,
        lib = { notify = lib_notify, callback = { await = lib_callback_await } },
        print = customPrint,
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
        ExecuteCommand = ExecuteCommand, TriggerServerEvent = TriggerServerEvent,

        -- FEATURE_TRIGGERS dependencies -- plain call-recording stand-ins
        -- (record()) for every "just do it" action, queryFn() for every
        -- "am I currently..." predicate.
        K9Sit = record('K9Sit'),
        IsLeashed = queryFn('IsLeashed', 'isLeashed'), DetachLeash = record('DetachLeash'),
        RequestLeashAttach = record('RequestLeashAttach'),
        IsInK9Vehicle = queryFn('IsInK9Vehicle', 'isInK9Vehicle'),
        ExitK9Vehicle = record('ExitK9Vehicle'), EnterNearestK9Vehicle = record('EnterNearestK9Vehicle'),
        GetActiveTrackType = function(...)
            calls['GetActiveTrackType'] = calls['GetActiveTrackType'] or {}
            calls['GetActiveTrackType'][#calls['GetActiveTrackType'] + 1] = { ... }
            return queryState.activeTrackType
        end,
        StopTracking = record('StopTracking'), StartScentTrack = record('StartScentTrack'),
        StartBloodTrack = record('StartBloodTrack'), StartGunpowderTrack = record('StartGunpowderTrack'),
        ToggleThermalVision = record('ToggleThermalVision'), ToggleNightVision = record('ToggleNightVision'),
        IsBiteHoldEngaged = queryFn('IsBiteHoldEngaged', 'isBiteHoldEngaged'),
        ReleaseBiteHold = record('ReleaseBiteHold'), RequestBiteHold = record('RequestBiteHold'),
        RequestTakedown = record('RequestTakedown'),
        IsDragEngaged = queryFn('IsDragEngaged', 'isDragEngaged'),
        ReleaseDrag = record('ReleaseDrag'), RequestDrag = record('RequestDrag'),
        IsPartnered = queryFn('IsPartnered', 'isPartnered'), BreakPartnership = record('BreakPartnership'),
        RequestPartnerUp = record('RequestPartnerUp'),
        IsFetchCarryEngaged = queryFn('IsFetchCarryEngaged', 'isFetchCarryEngaged'),
        ReleaseFetchBall = record('ReleaseFetchBall'), RequestThrowFetchBall = record('RequestThrowFetchBall'),
        RequestToggleK9PropAttachment = record('RequestToggleK9PropAttachment'),
        RequestDeployKennel = record('RequestDeployKennel'),
        RequestOpenOwnK9Inventory = record('RequestOpenOwnK9Inventory'),
        RequestTreatNearestK9 = record('RequestTreatNearestK9'),
    }

    -- FindNearestLeashCandidate/FindNearestPartnerCandidate are OMITTED
    -- entirely unless opts.withSeams (default true) -- proving the
    -- `type(fn) == 'function'` soft-dependency guard degrades cleanly
    -- when client/radial.lua's own seam has not (yet) been opened.
    if opts.withSeams ~= false then
        overrides.FindNearestLeashCandidate = function() return leashCandidate end
        overrides.FindNearestPartnerCandidate = function() return partnerCandidate end
    end

    -- See isLocalPlayerForceRagdolled's own declaration comment above.
    if opts.withForceRagdollSeam ~= false then
        overrides.IsLocalPlayerForceRagdolled = function() return isLocalPlayerForceRagdolled end
    end

    local env = Sandbox.newEnv(overrides)

    Sandbox.loadInto('../config.lua', env)

    -- FIXED BASELINE -- config.lua is edited concurrently by other agents;
    -- pin exactly the fields this spec cares about BEFORE loading
    -- client/tablet.lua (openMode/command/allowActionsFromTablet are all
    -- read at FILE-LOAD time), same reasoning as
    -- tests/clientradial_spec.lua's/tests/clientvision_spec.lua's own
    -- fixed-baseline sections.
    env.Config.Features.CommandTablet = true
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end
    env.Config.CommandTablet = env.Config.CommandTablet or {}
    env.Config.CommandTablet.openMode = 'both'
    env.Config.CommandTablet.command = 'k9tablet'
    -- DEFAULT DISABLED (matching config.lua's new default, this pass's
    -- "one command, routed by rank" change) -- a test that specifically
    -- exercises the OPTIONAL shortcut opts back in via
    -- `commandTablet = { highCommandCommand = 'k9hqtablet' }`, same as any
    -- other opts.commandTablet override in this fixture.
    env.Config.CommandTablet.highCommandCommand = false
    env.Config.CommandTablet.itemName = 'k9_tablet'
    for key, value in pairs(opts.commandTablet or {}) do
        env.Config.CommandTablet[key] = value
    end
    env.Config.FeatureControl = env.Config.FeatureControl or {}
    env.Config.FeatureControl.allowActionsFromTablet = true
    for key, value in pairs(opts.featureControl or {}) do
        env.Config.FeatureControl[key] = value
    end

    Sandbox.loadInto('../client/tablet.lua', env)

    return {
        env = env,
        Config = env.Config,
        notifyCalls = notifyCalls,
        printLines = printLines,
        setNuiFocusCalls = setNuiFocusCalls,
        sendNuiMessageCalls = sendNuiMessageCalls,
        registerCommandCalls = registerCommandCalls,
        nuiCallbacks = nuiCallbacks,
        executeCommandCalls = executeCommandCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        useItemCalls = useItemCalls,
        calls = calls,
        callbackCallLog = callbackCallLog,
        canShowK9UICalls = function() return canShowK9UICalls end,
        hasK9AccessCalls = function() return hasK9AccessCalls end,
        denyCalls = function() return denyCalls end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setQueryState = function(field, v) queryState[field] = v end,
        setLeashCandidate = function(v) leashCandidate = v end,
        setPartnerCandidate = function(v) partnerCandidate = v end,
        setDisabledControlJustPressed = function(v) disabledControlJustPressed = v end,
        setIsEntityDead = function(v) isEntityDead = v end,
        setIsNuiFocused = function(v) isNuiFocused = v end,
        setIsNuiFocusedThrows = function(v) isNuiFocusedThrows = v end,
        setIsLocalPlayerForceRagdolled = function(v) isLocalPlayerForceRagdolled = v end,
        setOxInventoryStarted = function(v) oxInventoryStarted = v end,
        setUseItemApproves = function(v) useItemApproves = v end,
        setServerCallback = function(name, result) callbackResponses[name] = { throws = false, result = result } end,
        threadCreateCount = function() return threadCreateCount end,
        step = function() runner.step() end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        fireItemUse = function(data, slot)
            for _, handler in ipairs(eventHandlers['qbx_k9unit:client:useTabletItem'] or {}) do
                handler(data, slot)
            end
        end,
        --- Generic AddEventHandler-firing helper for events this file
        --- doesn't already expose a named shortcut for -- mirrors
        --- fireResourceStop/fireItemUse's own shape exactly, just not
        --- hardcoded to one name. Only ever finds a handler for a name
        --- registered via AddEventHandler -- see fireNetEvent below for
        --- anything server-fired (e.g. qbx_k9unit:client:themeUpdated),
        --- which a real AddEventHandler-only registration could never
        --- reach at all.
        fireEvent = function(eventName, ...)
            for _, handler in ipairs(eventHandlers[eventName] or {}) do
                handler(...)
            end
        end,
        --- Asserts `eventName` was actually registered via RegisterNetEvent
        --- -- the only kind of registration a real, network-originated
        --- TriggerClientEvent can ever reach -- and fires it. Use this,
        --- never fireEvent, for any event this file documents as
        --- server-fired (qbx_k9unit:client:themeUpdated,
        --- qbx_k9unit:client:equipmentShopLocationsUpdated's OWN real
        --- registration in client/equipmentshop.lua, ...): same
        --- registration-mechanism assertion as
        --- tests/clientequipmentshop_spec.lua's own triggerLocationsUpdated
        --- helper, generalized to any event name instead of one hardcoded
        --- shortcut.
        fireNetEvent = function(eventName, ...)
            local handler = netEvents[eventName]
            assert(handler, 'client/tablet.lua did not register ' .. tostring(eventName) .. ' via RegisterNetEvent')
            handler(...)
        end,
        isRegisteredAsNetEvent = function(eventName) return netEvents[eventName] ~= nil end,
        --- Awaits a NUI callback the same way FiveM's own dispatch would:
        --- calls the captured handler and returns whatever it passed to `cb`.
        --- @param name string
        --- @param data table?
        --- @return table result
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
-- Feature-flag gating -- "gate at registration, not just inside the
-- handler."
-- ----------------------------------------------------------------------

t.test('Config.Features.CommandTablet = false: OpenTablet/CloseTablet are not even defined', function()
    local f = newTabletFixture({ features = { CommandTablet = false } })
    t.isNil(f.env.OpenTablet)
    t.isNil(f.env.CloseTablet)
end)

t.test('Config.Features.CommandTablet = false: zero commands, zero NUI callbacks, zero event handlers registered', function()
    local f = newTabletFixture({ features = { CommandTablet = false } })
    t.equals(#f.registerCommandCalls, 0)
    t.isNil(f.nuiCallbacks['tablet:close'])
    t.isNil(f.nuiCallbacks['tablet:ready'])
    t.equals(f.fireResourceStop('qbx_k9unit'), nil) -- no onResourceStop handler to even find/throw
end)

t.test('Config.Features.CommandTablet = true: OpenTablet/CloseTablet exist and tablet:close is registered', function()
    local f = newTabletFixture()
    t.isNotNil(f.env.OpenTablet)
    t.isNotNil(f.env.CloseTablet)
    t.isNotNil(f.nuiCallbacks['tablet:close'])
end)

-- ----------------------------------------------------------------------
-- openMode resolution -- registration-time, not behavior-time.
--
-- Every test in this block passes `highCommandCommand = ''` to disable
-- the SECOND entry point (see its own dedicated section further below) --
-- these tests are specifically about the ORIGINAL command's/item's own
-- openMode-driven registration, and the second command registers
-- UNCONDITIONALLY regardless of openMode (by design -- see config.lua's
-- own comment on that field), so leaving it at its pinned baseline value
-- here would silently change every one of these counts by one and hide
-- what each assertion is actually about.
-- ----------------------------------------------------------------------

t.test('openMode = "command": the command is registered, no item-use event handler exists', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'command', highCommandCommand = '' } })
    t.equals(#f.registerCommandCalls, 1)
    t.equals(f.registerCommandCalls[1].name, 'k9tablet')
    f.fireItemUse({}, 1)
    t.equals(#f.useItemCalls, 0, 'no handler should exist to ever call useItem in command-only mode')
end)

t.test('openMode = "item": the command is NOT registered at all, the item-use handler is', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'item', highCommandCommand = '' } })
    t.equals(#f.registerCommandCalls, 0)
    f.fireItemUse({}, 1)
    t.equals(#f.useItemCalls, 1)
end)

t.test('openMode = "both": both the command and the item-use handler exist', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'both', highCommandCommand = '' } })
    t.equals(#f.registerCommandCalls, 1)
    f.fireItemUse({}, 1)
    t.equals(#f.useItemCalls, 1)
end)

t.test('openMode = an unrecognised value: falls back to "command" (registered) and warns loudly, never leaving zero ways in', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'sometypo', highCommandCommand = '' } })
    t.equals(#f.registerCommandCalls, 1)
    local warned = false
    for _, line in ipairs(f.printLines) do
        if line:find('openMode') and line:find('sometypo') then warned = true end
    end
    t.isTrue(warned, 'must name the bad value in the warning')
end)

t.test('openMode = nil (missing entirely): also falls back to "command"', function()
    local f = newTabletFixture({ commandTablet = { openMode = nil, highCommandCommand = '' } })
    t.equals(#f.registerCommandCalls, 1)
end)

t.test('Config.CommandTablet.command missing/invalid in "command" mode: warns, registers nothing, still no crash', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'command', command = '', highCommandCommand = '' } })
    t.equals(#f.registerCommandCalls, 0)
    local warned = false
    for _, line in ipairs(f.printLines) do
        if line:find('Config.CommandTablet.command') then warned = true end
    end
    t.isTrue(warned)
end)

t.test('the registered command handler really calls the production OpenTablet(), not a copy', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'command' } })
    f.registerCommandCalls[1].handler()
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:open')
end)

-- ----------------------------------------------------------------------
-- ONE COMMAND, ROUTED BY RANK (owner-directed, 2026-08-26) -- the
-- ORIGINAL command above now always sends `requestedView = 'auto'`, which
-- html/tablet.js's loadMyRecord() uses to auto-land a canAccessConsole()-
-- qualifying caller (high command, or an explicit 'k9.audit' grant) on
-- the console, and everyone else exactly where they always landed. That
-- rank-based routing itself is a JS-side behavior (html/tests/
-- tablet_auto_console_landing_spec.js owns proving it); this file only
-- proves the LUA SIDE of the contract -- which literal string is sent,
-- and when.
--
-- OPTIONAL SECOND ENTRY POINT -- Config.CommandTablet.highCommandCommand.
-- Still a shortcut to the SAME OpenTablet(), just requesting the console
-- screen explicitly (`requestedView = 'highCommand'`, which additionally
-- surfaces a refusal notice for an insufficient caller -- the 'auto' path
-- above never does). DEFAULT DISABLED (`false`) as of this pass -- this
-- fixture's own baseline now matches that default, so every test below
-- that needs the shortcut opts back in explicitly via
-- `commandTablet = { highCommandCommand = 'k9hqtablet' }`. When
-- configured, it is registered UNCONDITIONALLY (independent of openMode
-- -- that field only governs the ORIGINAL command's/item's own
-- reachability), and routes through the exact same tabletOpen guard /
-- SetNuiFocus / CloseTablet as everything else -- it is never a second
-- focus-taking or focus-release path.
-- ----------------------------------------------------------------------

--- @param f table fixture
--- @param name string
--- @return table? call {name, handler, restricted}
local function findRegisteredCommand(f, name)
    for _, call in ipairs(f.registerCommandCalls) do
        if call.name == name then return call end
    end
    return nil
end

t.test('highCommandCommand defaults to false/disabled: NOT registered, and no warning at all -- this is the new, intended "one command" state, not a misconfiguration', function()
    local f = newTabletFixture() -- baseline: openMode='both', command='k9tablet', highCommandCommand=false
    t.equals(#f.registerCommandCalls, 1, 'only the single command registers')
    t.isNotNil(findRegisteredCommand(f, 'k9tablet'))
    t.isNil(findRegisteredCommand(f, 'k9hqtablet'))
    for _, line in ipairs(f.printLines) do
        t.isFalse(line:find('highCommandCommand') ~= nil, 'the default-disabled state must never print a warning: ' .. line)
    end
end)

t.test('highCommandCommand = false explicitly: identical to the default -- no registration, no warning', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = false } })
    t.equals(#f.registerCommandCalls, 1)
    t.isNil(findRegisteredCommand(f, 'k9hqtablet'))
    for _, line in ipairs(f.printLines) do
        t.isFalse(line:find('highCommandCommand') ~= nil, line)
    end
end)

t.test('highCommandCommand configured to a real command name: registers a SECOND, separate command alongside the original -- both reachable', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 'k9hqtablet' } })
    t.equals(#f.registerCommandCalls, 2)
    t.isNotNil(findRegisteredCommand(f, 'k9tablet'))
    t.isNotNil(findRegisteredCommand(f, 'k9hqtablet'))
end)

t.test('highCommandCommand still registers when openMode = "item" -- a wholly separate reachability decision from the original command/item', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'item', highCommandCommand = 'k9hqtablet' } })
    t.isNil(findRegisteredCommand(f, 'k9tablet'), 'the ORIGINAL command must stay unreachable in item mode')
    t.isNotNil(findRegisteredCommand(f, 'k9hqtablet'), 'the NEW shortcut command is independent of openMode')
end)

t.test('highCommandCommand set to an invalid, non-false, non-string value: warns loudly, but the ORIGINAL command/item are completely unaffected', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = '' } })
    t.isNotNil(findRegisteredCommand(f, 'k9tablet'), 'this is a pure addition -- an invalid value here must never take the old command with it')
    t.isNil(findRegisteredCommand(f, 'k9hqtablet'))
    local warned = false
    for _, line in ipairs(f.printLines) do
        if line:find('Config.CommandTablet.highCommandCommand') then warned = true end
    end
    t.isTrue(warned)
end)

t.test('highCommandCommand set to a stray non-string, non-boolean value (e.g. a leftover number): still warns, same as an empty string', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 123 } })
    t.isNil(findRegisteredCommand(f, 'k9hqtablet'))
    local warned = false
    for _, line in ipairs(f.printLines) do
        if line:find('Config.CommandTablet.highCommandCommand') then warned = true end
    end
    t.isTrue(warned)
end)

t.test('Config.Features.CommandTablet = false: the high command shortcut is exactly as inert as the original command, even when configured', function()
    local f = newTabletFixture({ features = { CommandTablet = false }, commandTablet = { highCommandCommand = 'k9hqtablet' } })
    t.equals(#f.registerCommandCalls, 0)
    t.isNil(findRegisteredCommand(f, 'k9hqtablet'))
end)

t.test('the hq command handler calls the SAME production OpenTablet(), requesting the console view -- not a parallel open path', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 'k9hqtablet' } })
    local hq = findRegisteredCommand(f, 'k9hqtablet')
    hq.handler()
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:open')
    t.equals(f.sendNuiMessageCalls[1].data.requestedView, 'highCommand')
    t.equals(#f.setNuiFocusCalls, 1, 'the ONE OpenTablet() focus grab, not a second one')
    t.isTrue(f.setNuiFocusCalls[1][1])
end)

t.test('the ORIGINAL command now sends requestedView = "auto" (not nil) -- the single command auto-routes by rank on its own', function()
    local f = newTabletFixture()
    local original = findRegisteredCommand(f, 'k9tablet')
    original.handler()
    t.equals(f.sendNuiMessageCalls[1].data.requestedView, 'auto')
end)

t.test('OpenTablet() called directly with no argument sends requestedView = "auto" (every existing caller -- item, radial -- gets the same auto-routing)', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    t.equals(f.sendNuiMessageCalls[1].data.requestedView, 'auto')
end)

t.test('typing the hq command while already open via the ORIGINAL command is a safe no-op -- no second focus grab, no second push, same one watch thread', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 'k9hqtablet' } })
    findRegisteredCommand(f, 'k9tablet').handler()
    findRegisteredCommand(f, 'k9hqtablet').handler()
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(#f.setNuiFocusCalls, 1)
    t.equals(f.threadCreateCount(), 1)
end)

t.test('typing the ORIGINAL command while already open via the hq command is a safe no-op -- same one focus lifecycle either direction', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 'k9hqtablet' } })
    findRegisteredCommand(f, 'k9hqtablet').handler()
    findRegisteredCommand(f, 'k9tablet').handler()
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(#f.setNuiFocusCalls, 1)
    t.equals(f.threadCreateCount(), 1)
end)

t.test('typing the hq command twice in a row is a safe no-op, same as the original command', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 'k9hqtablet' } })
    local hq = findRegisteredCommand(f, 'k9hqtablet')
    hq.handler()
    hq.handler()
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(#f.setNuiFocusCalls, 1)
end)

t.test('closing via CloseTablet() after opening through the hq command releases focus through the SAME single close path', function()
    local f = newTabletFixture({ commandTablet = { highCommandCommand = 'k9hqtablet' } })
    findRegisteredCommand(f, 'k9hqtablet').handler()
    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2)
    t.isFalse(f.setNuiFocusCalls[2][1])
    t.equals(f.sendNuiMessageCalls[2].action, 'tablet:close')
end)

-- ----------------------------------------------------------------------
-- Item-use path (ox_inventory) -- the trap: a missing/outdated
-- ox_inventory, or a server-declined use, must never crash and must
-- never silently "half open" the tablet.
-- ----------------------------------------------------------------------

t.test('item use: ox_inventory not started -- warns, notifies, OpenTablet is never actually triggered', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'item' } })
    f.setOxInventoryStarted(false)
    f.fireItemUse({ slot = 1 }, 1)
    t.equals(#f.sendNuiMessageCalls, 0)
    t.equals(#f.setNuiFocusCalls, 0)
    t.equals(#f.notifyCalls, 1)
end)

t.test('item use: ox_inventory approves the use -- OpenTablet() really runs (focus grabbed, tablet:open pushed)', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'item' } })
    f.setUseItemApproves(true)
    f.fireItemUse({ slot = 1 }, 1)
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:open')
    t.equals(#f.setNuiFocusCalls, 1)
    t.isTrue(f.setNuiFocusCalls[1][1])
end)

t.test('item use: the server DECLINES the use (approved=false) -- the tablet never opens', function()
    local f = newTabletFixture({ commandTablet = { openMode = 'item' } })
    f.setUseItemApproves(false)
    f.fireItemUse({ slot = 1 }, 1)
    t.equals(#f.sendNuiMessageCalls, 0)
    t.equals(#f.setNuiFocusCalls, 0)
end)

-- ----------------------------------------------------------------------
-- OpenTablet() / CloseTablet() -- the core focus lifecycle.
-- ----------------------------------------------------------------------

t.test('OpenTablet(): no server round trip -- opens immediately with capabilities/strings/maxXpPerGrant', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    t.equals(#f.callbackCallLog, 0, 'opening must never await a server callback')
    t.equals(#f.sendNuiMessageCalls, 1)
    local msg = f.sendNuiMessageCalls[1]
    t.equals(msg.action, 'tablet:open')
    t.equals(msg.data.capabilities, f.Config.Permissions)
    t.isNotNil(msg.data.strings)
    t.equals(#f.setNuiFocusCalls, 1)
    t.isTrue(f.setNuiFocusCalls[1][1])
    t.isTrue(f.setNuiFocusCalls[1][2])
end)

t.test('OpenTablet(): calling it again while already open is a true no-op -- no second focus grab, no second push', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.env.OpenTablet()
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(#f.setNuiFocusCalls, 1)
    t.equals(f.threadCreateCount(), 1, 'the watch thread must not be started twice either')
end)

t.test('CloseTablet(): while not open, is a harmless no-op -- never calls SetNuiFocus at all', function()
    local f = newTabletFixture()
    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 0)
    t.equals(#f.sendNuiMessageCalls, 0)
end)

t.test('CloseTablet(): after an open, releases focus and pushes tablet:close', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2)
    t.isFalse(f.setNuiFocusCalls[2][1])
    t.isFalse(f.setNuiFocusCalls[2][2])
    t.equals(#f.sendNuiMessageCalls, 2)
    t.equals(f.sendNuiMessageCalls[2].action, 'tablet:close')
end)

t.test('CloseTablet(): calling it twice in a row is idempotent -- the second call touches nothing further', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.env.CloseTablet()
    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2, 'no second release for an already-released tablet')
end)

t.test('CloseTablet() is never gated on CanShowK9UI/HasK9Access -- "no unbounded trap": losing access must not strand an open tablet', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.setCanShowK9UI(false)
    f.setHasK9Access(false)
    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2, 'close must still succeed even with zero K9 access')
    t.equals(f.denyCalls(), 0, 'close must never fire a denial notification')
end)

t.test('a re-open after a real close pushes a brand-new tablet:open (proves it was genuinely closed, not just visually)', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.env.CloseTablet()
    f.env.OpenTablet()
    t.equals(#f.sendNuiMessageCalls, 3)
    t.equals(f.sendNuiMessageCalls[3].action, 'tablet:open')
end)

-- ----------------------------------------------------------------------
-- CROSS-RESOURCE FOCUS INTEROP (this pass, focus-and-state audit finding
-- #1) -- see client/tablet.lua's own header of the same name.
-- ----------------------------------------------------------------------

t.test('the common case: nobody else holds NUI focus -- OpenTablet() still grabs it, CloseTablet() releases it fully, exactly as before', function()
    local f = newTabletFixture()
    f.setIsNuiFocused(false)
    f.env.OpenTablet()
    t.equals(#f.setNuiFocusCalls, 1)
    t.isTrue(f.setNuiFocusCalls[1][1])
    t.isTrue(f.setNuiFocusCalls[1][2])

    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2)
    t.isFalse(f.setNuiFocusCalls[2][1], 'no foreign focus to restore -- release fully')
    t.isFalse(f.setNuiFocusCalls[2][2])
end)

t.test('another resource already holds NUI focus: OpenTablet() still opens unconditionally -- no refusal, same push, same focus grab', function()
    local f = newTabletFixture()
    f.setIsNuiFocused(true)
    f.env.OpenTablet()
    t.equals(#f.sendNuiMessageCalls, 1, 'opening is never gated on some other resource already holding focus')
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:open')
    t.equals(#f.setNuiFocusCalls, 1, 'this file still grabs focus for its own NUI page regardless')
    t.isTrue(f.setNuiFocusCalls[1][1])
    t.isTrue(f.setNuiFocusCalls[1][2])
end)

t.test('another resource already holds NUI focus: CloseTablet() RESTORES it (SetNuiFocus(true, true)) instead of blanking it out from under them', function()
    local f = newTabletFixture()
    f.setIsNuiFocused(true) -- captured the instant BEFORE OpenTablet()'s own SetNuiFocus(true, true) call
    f.env.OpenTablet()
    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2)
    t.isTrue(f.setNuiFocusCalls[2][1], 'restores the pre-existing focus rather than SetNuiFocus(false, false)')
    t.isTrue(f.setNuiFocusCalls[2][2])
    t.equals(#f.sendNuiMessageCalls, 2, 'tablet:close is still pushed exactly as normal -- only the SetNuiFocus arguments differ')
    t.equals(f.sendNuiMessageCalls[2].action, 'tablet:close')
end)

t.test('foreign-focus capture is PER-OPEN, not sticky: a later close/reopen cycle with nobody else holding focus releases fully again', function()
    local f = newTabletFixture()
    f.setIsNuiFocused(true)
    f.env.OpenTablet()
    f.env.CloseTablet()
    t.isTrue(f.setNuiFocusCalls[2][1], 'sanity: restored the first time')

    f.setIsNuiFocused(false) -- the other resource released its own focus in the meantime
    f.env.OpenTablet()
    f.env.CloseTablet()
    t.isFalse(f.setNuiFocusCalls[4][1], 're-captured fresh on THIS open, not carried over from the previous session')
    t.isFalse(f.setNuiFocusCalls[4][2])
end)

t.test('IsNuiFocused() throwing at open time never aborts OpenTablet() and never leaves CloseTablet() unable to release focus -- fails closed to the old, always-safe "release fully" behavior', function()
    local f = newTabletFixture()
    f.setIsNuiFocusedThrows(true)
    local ok = pcall(f.env.OpenTablet)
    t.isTrue(ok, 'a throwing IsNuiFocused() must never abort the open itself')
    t.equals(#f.sendNuiMessageCalls, 1, 'the tablet genuinely opened')
    t.equals(#f.setNuiFocusCalls, 1)

    f.env.CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2, 'the close path is NEVER skipped, even after a failed capture')
    t.isFalse(f.setNuiFocusCalls[2][1], 'a failed capture collapses to the pre-existing "release fully" behavior, never nil, never "restore"')
    t.isFalse(f.setNuiFocusCalls[2][2])
end)

t.test('foreign focus at open time never appears anywhere in the tablet:open/tablet:close NUI payloads -- Lua-side bookkeeping only', function()
    local f = newTabletFixture()
    f.setIsNuiFocused(true)
    f.env.OpenTablet()
    f.env.CloseTablet()
    t.isNil(f.sendNuiMessageCalls[1].data.tabletHadForeignFocusOnOpen)
    t.equals(next(f.sendNuiMessageCalls[2].data), nil, 'tablet:close payload stays the empty table it always was')
end)

-- ----------------------------------------------------------------------
-- tablet:close / tablet:ready NUI callbacks.
-- ----------------------------------------------------------------------

t.test('tablet:ready always acks, does nothing else', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:ready', {})
    t.equals(next(result), nil)
end)

t.test('tablet:close: closes the real tablet and acks -- calling it while already closed is still safe', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    local result = f.callNui('tablet:close', {})
    t.isNotNil(result)
    t.equals(#f.setNuiFocusCalls, 2)

    -- html/tablet-bridge.js's own header: fires tablet:close from more
    -- than one path and expects a repeat to be a safe no-op.
    local ok = pcall(f.callNui, 'tablet:close', {})
    t.isTrue(ok)
    t.equals(#f.setNuiFocusCalls, 2, 'a second tablet:close must not release focus a second time')
end)

-- ----------------------------------------------------------------------
-- ESC-close + own-death watch thread. See this file's header
-- "WATCH-THREAD STEPPING NOTES" for exactly what each step() reaches.
-- ----------------------------------------------------------------------

t.test('watch thread: does not exist before OpenTablet() is ever called', function()
    local f = newTabletFixture()
    t.equals(f.threadCreateCount(), 0)
end)

t.test('watch thread: DisableControlAction(0, 200, true) is asserted on the very first pass', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step() -- pass 1
    t.isNotNil(f.calls) -- sanity: fixture alive
end)

t.test('ESC closes the tablet via the watch thread, independent of any NUI callback', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step() -- pass 1: nothing pressed yet
    t.equals(#f.setNuiFocusCalls, 1)

    f.setDisabledControlJustPressed(true)
    f.step() -- pass 2: detects ESC, calls CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2, 'ESC must release focus without any NUI callback ever firing')
    t.isFalse(f.setNuiFocusCalls[2][1])
end)

t.test('own death closes the tablet via the SAME watch thread', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step() -- pass 1

    f.setIsEntityDead(true)
    f.step() -- pass 2: detects death, calls CloseTablet()
    t.equals(#f.setNuiFocusCalls, 2)
    t.isFalse(f.setNuiFocusCalls[2][1])
end)

t.test('watch thread self-terminates once closed, and a LATER open starts a genuinely NEW thread', function()
    local f = newTabletFixture()
    f.env.OpenTablet() -- thread #1
    t.equals(f.threadCreateCount(), 1)
    f.step() -- pass 1
    f.setDisabledControlJustPressed(true)
    f.step() -- pass 2: closes (tabletOpen -> false)
    f.step() -- pass 3: loop observes tabletOpen=false, exits, resets the running guard

    f.setDisabledControlJustPressed(false)
    f.env.OpenTablet() -- a fresh open after the old thread fully died
    t.equals(f.threadCreateCount(), 2, 'the running-guard must have reset to false, or this would still read 1')
end)

t.test('while still open (nothing tripped), continuing to step never creates a second thread', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step()
    f.step()
    f.step()
    t.equals(f.threadCreateCount(), 1)
end)

-- ----------------------------------------------------------------------
-- DOWNED-BY-TAKEDOWN ALSO FORCE-CLOSES (this pass, focus-and-state audit
-- finding #2) -- see client/tablet.lua's own header of the same name.
-- client/combat.lua's real IsLocalPlayerForceRagdolled() is stood in for
-- by isLocalPlayerForceRagdolled's own controllable stub (see this file's
-- header on this fixture's opts.withForceRagdollSeam).
-- ----------------------------------------------------------------------

t.test('a non-lethal K9 takedown (IsLocalPlayerForceRagdolled true) force-closes the tablet even though IsEntityDead stays false throughout', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step() -- pass 1: neither tripped yet
    t.equals(#f.setNuiFocusCalls, 1)

    f.setIsLocalPlayerForceRagdolled(true)
    f.step() -- pass 2: detects the takedown, calls CloseTablet() -- note IsEntityDead was never touched/set true anywhere in this test, so this is exclusively the new branch firing
    t.equals(#f.setNuiFocusCalls, 2, 'a taken-down player must not keep their tablet (and NUI focus) open')
    t.isFalse(f.setNuiFocusCalls[2][1])
end)

t.test('the takedown branch is a genuine ADDITION, not a replacement -- own death still force-closes exactly as before', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step() -- pass 1
    f.setIsEntityDead(true)
    f.step() -- pass 2: death branch, unaffected by this pass
    t.equals(#f.setNuiFocusCalls, 2)
    t.isFalse(f.setNuiFocusCalls[2][1])
end)

t.test('IsLocalPlayerForceRagdolled entirely absent (client/combat.lua not loaded / all three combat features off): the watch thread degrades cleanly, never throws', function()
    local f = newTabletFixture({ withForceRagdollSeam = false })
    f.env.OpenTablet()
    local ok = pcall(f.step) -- pass 1: must not error just because the seam is missing
    t.isTrue(ok)
    t.equals(#f.setNuiFocusCalls, 1, 'still open -- nothing tripped, and the missing seam alone must never force a close')
end)

t.test('IsLocalPlayerForceRagdolled = false: the tablet stays open exactly as it would with no combat activity at all', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.step()
    f.step()
    f.step()
    t.equals(#f.setNuiFocusCalls, 1, 'no false-positive close from a query that consistently returns false')
end)

-- ----------------------------------------------------------------------
-- Resource-stop safety net.
-- ----------------------------------------------------------------------

t.test('onResourceStop for THIS resource while open: releases focus', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.fireResourceStop('qbx_k9unit')
    t.equals(#f.setNuiFocusCalls, 2)
    t.isFalse(f.setNuiFocusCalls[2][1])
end)

t.test('onResourceStop for a DIFFERENT resource: no effect at all', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.fireResourceStop('some_other_resource')
    t.equals(#f.setNuiFocusCalls, 1, 'only the original open call, nothing from the unrelated stop')
end)

t.test('onResourceStop while never opened: a harmless no-op', function()
    local f = newTabletFixture()
    local ok = pcall(f.fireResourceStop, 'qbx_k9unit')
    t.isTrue(ok)
    t.equals(#f.setNuiFocusCalls, 0)
end)

-- ----------------------------------------------------------------------
-- AwaitServerCallback fail-closed behavior -- a thrown lib.callback.await
-- must never propagate and must never leave the tablet's own state
-- (focus, in this file's case) in a bad spot.
-- ----------------------------------------------------------------------

t.test('a server callback that throws (unregistered/timeout) fails closed to {ok=false, error="timeout"}, never raises', function()
    local f = newTabletFixture()
    -- No f.setServerCallback() call for this name -- the fixture's default
    -- lib.callback.await throws for any unconfigured name.
    local result = f.callNui('tablet:requestMyRecord', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'timeout')
end)

t.test('a thrown callback during tablet:requestRoster never leaves focus in an inconsistent state (tablet stays open, exactly as before)', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    local focusCallsBefore = #f.setNuiFocusCalls
    f.callNui('tablet:requestRoster', { query = 'x' })
    t.equals(#f.setNuiFocusCalls, focusCallsBefore, 'a failed data refresh must never touch focus either way')
end)

t.test('a successful server callback is forwarded through untouched', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRequestMyRecord', { ok = true, viewer = { citizenid = 'ABC123' } })
    local result = f.callNui('tablet:requestMyRecord', {})
    t.isTrue(result.ok)
    t.equals(result.viewer.citizenid, 'ABC123')
end)

-- ----------------------------------------------------------------------
-- Pass-through query/mutation callbacks -- shape validation + correct
-- server callback name/args.
-- ----------------------------------------------------------------------

t.test('tablet:requestRoster: missing/non-string query defaults to an empty string, never errors', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRequestRoster', { ok = true, rows = {} })
    f.callNui('tablet:requestRoster', {})
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletRequestRoster')
    t.equals(f.callbackCallLog[1].args[1], '')
end)

t.test('tablet:requestPersonSummary: invalid targetCitizenId is rejected before any server round trip', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:requestPersonSummary', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:requestPersonFeatures: same shape guard as requestPersonSummary', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:requestPersonFeatures', { targetCitizenId = '' })
    t.equals(result.error, 'invalid_args')
end)

-- ----------------------------------------------------------------------
-- K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) -- three thin
-- forwards straight onto server/roster.lua's own `qbx_k9unit:server:roster*`
-- lib.callback registrations (Phase A). This file adds no authorization of
-- its own -- IsHighCommand is re-verified server-side on every call (THE
-- SECURITY RULE), which this suite cannot exercise directly (that lives in
-- tests/roster_spec.lua); every test below only proves the BRIDGE forwards
-- the right name/shape and never invents a second mutation path.
-- ----------------------------------------------------------------------

t.test('tablet:rosterList: takes no payload and forwards straight to qbx_k9unit:server:rosterList', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:rosterList', { ok = true, k9 = {}, handlers = {}, unassigned = {} })
    local result = f.callNui('tablet:rosterList', {})
    t.isTrue(result.ok)
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:rosterList')
end)

t.test('tablet:rosterList: a thrown/unregistered server callback fails closed to timeout, never raises', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:rosterList', {})
    t.equals(result.ok, false)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:rosterSetPersonnelRole: requires citizenid, job, and personnelRole, all rejected before any server round trip when missing', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:rosterSetPersonnelRole', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:rosterSetPersonnelRole', { citizenid = 'ABC' }).error, 'invalid_args')
    t.equals(f.callNui('tablet:rosterSetPersonnelRole', { citizenid = 'ABC', job = 'police' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0, 'not one malformed call reached the server')
end)

t.test('tablet:rosterSetPersonnelRole: forwards citizenid/job/personnelRole as ONE payload table, verbatim', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:rosterSetPersonnelRole', { ok = true, outcome = 'assigned' })
    local result = f.callNui('tablet:rosterSetPersonnelRole', { citizenid = 'ABC123', job = 'police', personnelRole = 'k9' })
    t.isTrue(result.ok)
    t.equals(result.outcome, 'assigned')
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:rosterSetPersonnelRole')
    local payload = f.callbackCallLog[1].args[1]
    t.equals(payload.citizenid, 'ABC123')
    t.equals(payload.job, 'police')
    t.equals(payload.personnelRole, 'k9')
end)

t.test('tablet:rosterSetPersonnelRole: a server refusal (e.g. department_mismatch) forwards verbatim, never silently swallowed', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:rosterSetPersonnelRole', { ok = false, error = 'department_mismatch' })
    local result = f.callNui('tablet:rosterSetPersonnelRole', { citizenid = 'ABC123', job = 'police', personnelRole = 'k9' })
    t.equals(result.ok, false)
    t.equals(result.error, 'department_mismatch')
end)

t.test('tablet:rosterSetCallsign: requires citizenid and job; callsign may be omitted (clears it)', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:rosterSetCallsign', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:rosterSetCallsign', { citizenid = 'ABC' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)

    f.setServerCallback('qbx_k9unit:server:rosterSetCallsign', { ok = true, outcome = 'callsign_cleared' })
    local result = f.callNui('tablet:rosterSetCallsign', { citizenid = 'ABC123', job = 'police' })
    t.isTrue(result.ok)
    local payload = f.callbackCallLog[1].args[1]
    t.equals(payload.citizenid, 'ABC123')
    t.equals(payload.job, 'police')
    t.isNil(payload.callsign)
end)

t.test('tablet:rosterSetCallsign: a non-string, non-nil callsign is rejected before any server round trip', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:rosterSetCallsign', { citizenid = 'ABC123', job = 'police', callsign = 12 })
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:rosterSetCallsign: forwards a real callsign string verbatim, and a callsign_taken refusal is never translated away', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:rosterSetCallsign', { ok = false, error = 'callsign_taken' })
    local result = f.callNui('tablet:rosterSetCallsign', { citizenid = 'ABC123', job = 'police', callsign = '4-Adam-1' })
    t.equals(result.ok, false)
    t.equals(result.error, 'callsign_taken')
    t.equals(f.callbackCallLog[1].args[1].callsign, '4-Adam-1')
end)

t.test('tablet:certify: requires both targetCitizenId and departmentKey, forwards both on success', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:certify', { targetCitizenId = 'ABC' }).error, 'invalid_args')

    f.setServerCallback('qbx_k9unit:server:tabletCertify', { ok = true })
    f.callNui('tablet:certify', { targetCitizenId = 'ABC', departmentKey = 'police' })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletCertify')
    t.equals(f.callbackCallLog[1].args[1], 'ABC')
    t.equals(f.callbackCallLog[1].args[2], 'police')
end)

-- ----------------------------------------------------------------------
-- Certification depth bridges -- tier, renewal, specialization grant/
-- revoke. Each forwards to its server/certifications/commands.lua callback
-- in that callback's exact argument order, and refuses a malformed payload
-- before any round trip.
-- ----------------------------------------------------------------------

local CERT_DEPTH_BRIDGES = {
    { nui = 'tablet:setCertificationTier', server = 'qbx_k9unit:server:tabletSetCertificationTier',
      payload = { targetCitizenId = 'ABC', departmentKey = 'police', tier = 'senior' }, order = { 'targetCitizenId', 'departmentKey', 'tier' } },
    { nui = 'tablet:renewCertification', server = 'qbx_k9unit:server:tabletRenewCertification',
      payload = { targetCitizenId = 'ABC', departmentKey = 'police' }, order = { 'targetCitizenId', 'departmentKey' } },
    { nui = 'tablet:grantSpecialization', server = 'qbx_k9unit:server:tabletGrantSpecialization',
      payload = { targetCitizenId = 'ABC', departmentKey = 'police', specialization = 'narcotics' }, order = { 'targetCitizenId', 'departmentKey', 'specialization' } },
    { nui = 'tablet:revokeSpecialization', server = 'qbx_k9unit:server:tabletRevokeSpecialization',
      payload = { targetCitizenId = 'ABC', departmentKey = 'police', specialization = 'narcotics' }, order = { 'targetCitizenId', 'departmentKey', 'specialization' } },
}

for _, bridge in ipairs(CERT_DEPTH_BRIDGES) do
    t.test(bridge.nui .. ': forwards every field to the server callback in its exact argument order', function()
        local f = newTabletFixture()
        f.setServerCallback(bridge.server, { ok = true })
        local result = f.callNui(bridge.nui, bridge.payload)
        t.isTrue(result.ok)
        t.equals(#f.callbackCallLog, 1)
        t.equals(f.callbackCallLog[1].name, bridge.server)
        for i, field in ipairs(bridge.order) do
            t.equals(f.callbackCallLog[1].args[i], bridge.payload[field], 'argument ' .. i .. ' must be ' .. field)
        end
    end)

    t.test(bridge.nui .. ': a missing or empty field is refused before any server round trip', function()
        local f = newTabletFixture()
        t.equals(f.callNui(bridge.nui, nil).error, 'invalid_args')
        for _, field in ipairs(bridge.order) do
            for _, bad in ipairs({ false, '', 12 }) do
                local payload = {}
                for k, v in pairs(bridge.payload) do payload[k] = v end
                if bad == false then payload[field] = nil else payload[field] = bad end
                t.equals(f.callNui(bridge.nui, payload).error, 'invalid_args', field .. '=' .. tostring(bad))
            end
        end
        t.equals(#f.callbackCallLog, 0)
    end)

    t.test(bridge.nui .. ': a server refusal is passed through untouched, so the tablet can say why', function()
        local f = newTabletFixture()
        f.setServerCallback(bridge.server, { ok = false, error = 'requires_active_cert', message = 'They need an active certification first.' })
        local result = f.callNui(bridge.nui, bridge.payload)
        t.isFalse(result.ok)
        t.equals(result.error, 'requires_active_cert')
        t.equals(result.message, 'They need an active certification first.')
    end)
end

-- ----------------------------------------------------------------------
-- Permission-key catalog bridges -- server/permissionkeycatalog.lua's
-- permKeysUpsert/permKeysDelete, which answer with `reason`; the bridge
-- translates that to the `error` field html/tablet.js reads.
-- ----------------------------------------------------------------------

t.test('tablet:permKeysUpsert: missing/empty key is refused before any round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:permKeysUpsert', nil).error, 'invalid_args')
    t.equals(f.callNui('tablet:permKeysUpsert', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:permKeysUpsert', { key = '' }).error, 'invalid_args')
    t.equals(f.callNui('tablet:permKeysUpsert', { key = 5 }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:permKeysUpsert: forwards the whole payload, and a field REFUSAL comes back as error + field', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:permKeysUpsert', { ok = false, reason = 'invalid_label', field = 'label' })
    local payload = { key = 'k9.narcotics', label = '', description = 'Narcotics search' }
    local result = f.callNui('tablet:permKeysUpsert', payload)
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_label')
    t.equals(result.field, 'label')
    t.isNil(result.reason, 'the raw server `reason` is translated away, not left for the page to guess at')
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:permKeysUpsert')
    t.equals(f.callbackCallLog[1].args[1].key, 'k9.narcotics')
    t.equals(f.callbackCallLog[1].args[1].description, 'Narcotics search')
end)

t.test('tablet:permKeysUpsert: success forwards the refreshed catalog', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:permKeysUpsert', { ok = true, keys = { { key = 'k9.narcotics', label = 'Narcotics' } } })
    local result = f.callNui('tablet:permKeysUpsert', { key = 'k9.narcotics', label = 'Narcotics' })
    t.isTrue(result.ok)
    t.equals(result.keys[1].key, 'k9.narcotics')
end)

t.test('tablet:permKeysDelete: missing/empty key is refused before any round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:permKeysDelete', nil).error, 'invalid_args')
    t.equals(f.callNui('tablet:permKeysDelete', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:permKeysDelete', { key = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:permKeysDelete: forwards the bare key, and "reserved_namespace" comes back as a readable error code', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:permKeysDelete', { ok = false, reason = 'reserved_namespace' })
    local result = f.callNui('tablet:permKeysDelete', { key = 'feature.BiteAndHold' })
    t.isFalse(result.ok)
    t.equals(result.error, 'reserved_namespace')
    t.equals(f.callbackCallLog[1].args[1], 'feature.BiteAndHold')
end)

t.test('tablet:permKeysDelete: a server that never answers is reported as a failure, never a silent success', function()
    local f = newTabletFixture()
    -- no setServerCallback: the fixture's lib.callback.await throws
    local result = f.callNui('tablet:permKeysDelete', { key = 'k9.narcotics' })
    t.isFalse(result.ok)
    t.isNotNil(result.error)
end)

t.test('tablet:givexp: amount must be a number', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:givexp', { targetCitizenId = 'ABC', amount = '500' }).error, 'invalid_args')

    f.setServerCallback('qbx_k9unit:server:tabletGiveXp', { ok = true })
    f.callNui('tablet:givexp', { targetCitizenId = 'ABC', amount = 500 })
    t.equals(f.callbackCallLog[1].args[2], 500)
end)

-- ----------------------------------------------------------------------
-- tablet:decertify -- BUGFIX (docs/history/COMMAND_CONSOLIDATION_SPEC.md §6). Used to
-- shell out to the OFFLINE-ONLY 'k9decertifyoffline' command via
-- SubmitAllowlistedCommand/ExecuteCommand for EVERY target, online or
-- offline -- and server/certifications/'s RevokeCertificationOffline
-- explicitly refuses when the target is actually online, so the button
-- silently did nothing against anyone currently connected. Now calls a
-- real server callback (qbx_k9unit:server:tabletDecertify, backed by
-- RevokeCertificationForTablet), symmetric with tablet:certify above --
-- see that function's own header for the full online/offline resolution
-- writeup. `ExecuteCommand` is no longer used by this file at all.
-- ----------------------------------------------------------------------

t.test('REGRESSION PIN (the actual bug): tablet:decertify calls the real server callback, NOT ExecuteCommand -- this is what made an ONLINE target unreachable before this fix', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletDecertify', { ok = true })
    local result = f.callNui('tablet:decertify', { targetCitizenId = 'ABC123', departmentKey = 'police' })
    t.isTrue(result.ok)
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletDecertify')
    t.equals(f.callbackCallLog[1].args[1], 'ABC123')
    t.equals(f.callbackCallLog[1].args[2], 'police')
    -- The OLD implementation would have made this assertion fail (0 calls,
    -- because it went through ExecuteCommand instead) -- this is the exact
    -- "make it fail first against the old command-bridge path" pin: if
    -- this file ever regresses back to a command bridge for decertify,
    -- executeCommandCalls stops being empty here and this line catches it.
    t.equals(#f.executeCommandCalls, 0, 'decertify must never fall back to a fire-and-forget command bridge again')
end)

t.test('tablet:decertify: server refusal (e.g. target too far, still online-checked server-side) is forwarded verbatim, never silently swallowed', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletDecertify', { ok = false, error = 'target_too_far' })
    local result = f.callNui('tablet:decertify', { targetCitizenId = 'ABC123', departmentKey = 'police' })
    t.equals(result.ok, false)
    t.equals(result.error, 'target_too_far')
end)

t.test('tablet:decertify: missing departmentKey is rejected before any server round trip', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:decertify', { targetCitizenId = 'ABC123' })
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:decertify: missing targetCitizenId is rejected before any server round trip', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:decertify', { departmentKey = 'police' })
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

-- ----------------------------------------------------------------------
-- Grant/Revoke + feature/block translation -- server/permissions.lua's
-- REAL {ok, reason?} shape -> html/tablet.js's {ok, error?, message?}.
-- ----------------------------------------------------------------------

t.test('tablet:grantPermission: valid payload forwards (citizenid, permission) to tabletGrantPermission', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletGrantPermission', { ok = true })
    local result = f.callNui('tablet:grantPermission', { targetCitizenId = 'ABC', permission = 'k9.access' })
    t.isTrue(result.ok)
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletGrantPermission')
    t.equals(f.callbackCallLog[1].args[1], 'ABC')
    t.equals(f.callbackCallLog[1].args[2], 'k9.access')
end)

t.test('tablet:grantPermission: invalid payload never reaches the server', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:grantPermission', { targetCitizenId = 'ABC' })
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:revokePermission: a plain denial is forwarded as error = the raw reason code', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRevokePermission', { ok = false, reason = 'rate_limited' })
    local result = f.callNui('tablet:revokePermission', { targetCitizenId = 'ABC', permission = 'k9.access' })
    t.isFalse(result.ok)
    t.equals(result.error, 'rate_limited')
end)

t.test('tablet:revokePermission: "still has it by rank/high command" gets its own real, locale-resolved message, and IS a success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRevokePermission', { ok = true, reason = 'rank_or_high_command' })
    local result = f.callNui('tablet:revokePermission', { targetCitizenId = 'ABC', permission = 'k9.access' })
    t.isTrue(result.ok)
    t.equals(result.message, locale('tablet.revoke_still_has_access'))
end)

t.test('tablet:revokePermission: "target offline, cannot re-check" gets its own distinct message, still a success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRevokePermission', { ok = true, reason = 'unknown_target_offline' })
    local result = f.callNui('tablet:revokePermission', { targetCitizenId = 'ABC', permission = 'k9.access' })
    t.isTrue(result.ok)
    t.equals(result.message, locale('tablet.revoke_target_offline'))
    t.notContains(result.message, locale('tablet.revoke_still_has_access'), 'the two outcomes must render as genuinely different text')
end)

t.test('tablet:revokePermission: a plain success (no reason at all) carries no message', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRevokePermission', { ok = true })
    local result = f.callNui('tablet:revokePermission', { targetCitizenId = 'ABC', permission = 'k9.access' })
    t.isTrue(result.ok)
    t.isNil(result.message)
end)

t.test('a THROWN grant/revoke callback fails closed through the SAME translation -- error = "timeout", never a raised error', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:grantPermission', { targetCitizenId = 'ABC', permission = 'k9.access' })
    t.isFalse(result.ok)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:grantFeature / revokeFeature / blockFeature / unblockFeature reuse the SAME two server callbacks with the feature./block. key namespace -- no new server surface', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletGrantPermission', { ok = true })
    f.setServerCallback('qbx_k9unit:server:tabletRevokePermission', { ok = true })

    f.callNui('tablet:grantFeature', { targetCitizenId = 'ABC', feature = 'BiteAndHold' })
    t.equals(f.callbackCallLog[#f.callbackCallLog].name, 'qbx_k9unit:server:tabletGrantPermission')
    t.equals(f.callbackCallLog[#f.callbackCallLog].args[2], 'feature.BiteAndHold')

    f.callNui('tablet:revokeFeature', { targetCitizenId = 'ABC', feature = 'BiteAndHold' })
    t.equals(f.callbackCallLog[#f.callbackCallLog].name, 'qbx_k9unit:server:tabletRevokePermission')
    t.equals(f.callbackCallLog[#f.callbackCallLog].args[2], 'feature.BiteAndHold')

    f.callNui('tablet:blockFeature', { targetCitizenId = 'ABC', feature = 'PropDragging' })
    t.equals(f.callbackCallLog[#f.callbackCallLog].name, 'qbx_k9unit:server:tabletGrantPermission')
    t.equals(f.callbackCallLog[#f.callbackCallLog].args[2], 'block.PropDragging')

    f.callNui('tablet:unblockFeature', { targetCitizenId = 'ABC', feature = 'PropDragging' })
    t.equals(f.callbackCallLog[#f.callbackCallLog].name, 'qbx_k9unit:server:tabletRevokePermission')
    t.equals(f.callbackCallLog[#f.callbackCallLog].args[2], 'block.PropDragging')
end)

-- ----------------------------------------------------------------------
-- SECTION 2 -- tablet:triggerFeature. One representative case per gate
-- shape, per this file's own header note.
-- ----------------------------------------------------------------------

t.test('triggerFeature: Config.FeatureControl.allowActionsFromTablet = false disables the WHOLE surface, never even looks up the feature', function()
    local f = newTabletFixture({ featureControl = { allowActionsFromTablet = false } })
    local result = f.callNui('tablet:triggerFeature', { feature = 'BiteAndHold' })
    t.equals(result.error, 'actions_disabled')
    t.equals(#(f.calls['RequestBiteHold'] or {}), 0)
end)

t.test('triggerFeature: missing/non-string `feature` is invalid_args', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:triggerFeature', {}).error, 'invalid_args')
end)

t.test('triggerFeature: an unrecognised feature key is unknown_action', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:triggerFeature', { feature = 'NotARealFeature' }).error, 'unknown_action')
end)

t.test('LeashMechanics (release-ungated / attempt-gated toggle): IsLeashed() true detaches WITHOUT ever consulting CanShowK9UI', function()
    local f = newTabletFixture()
    f.setQueryState('isLeashed', true)
    local result = f.callNui('tablet:triggerFeature', { feature = 'LeashMechanics' })
    t.isTrue(result.ok)
    t.equals(#f.calls['DetachLeash'], 1)
    t.equals(f.canShowK9UICalls(), 0, 'detach must never gate on access')
end)

t.test('LeashMechanics: not leashed, CanShowK9UI false -- denied, RequestLeashAttach never called', function()
    local f = newTabletFixture({ canShowK9UI = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'LeashMechanics' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(f.denyCalls(), 1)
    t.equals(#(f.calls['RequestLeashAttach'] or {}), 0)
end)

t.test('LeashMechanics: not leashed, CanShowK9UI true, a nearest candidate exists -- attaches to it', function()
    local f = newTabletFixture()
    f.setLeashCandidate(42)
    local result = f.callNui('tablet:triggerFeature', { feature = 'LeashMechanics' })
    t.isTrue(result.ok)
    t.equals(f.calls['RequestLeashAttach'][1][1], 42)
end)

t.test('LeashMechanics: no nearby candidate -- the SAME radial.no_leash_candidate notify fires, action reports not_available', function()
    local f = newTabletFixture()
    f.setLeashCandidate(nil)
    local result = f.callNui('tablet:triggerFeature', { feature = 'LeashMechanics' })
    t.isFalse(result.ok)
    t.equals(f.notifyCalls[1].description, locale('radial.no_leash_candidate'))
end)

t.test('LeashMechanics: the FindNearestLeashCandidate seam is not open yet (radial.lua flag off) -- soft-fails, never errors', function()
    local f = newTabletFixture({ withSeams = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'LeashMechanics' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
end)

t.test('VehicleEntryExit (release-ungated / attempt-gated toggle): IsInK9Vehicle() true exits WITHOUT ever consulting CanShowK9UI/HasK9Access, even with zero access', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    f.setQueryState('isInK9Vehicle', true)
    local result = f.callNui('tablet:triggerFeature', { feature = 'VehicleEntryExit' })
    t.isTrue(result.ok)
    t.equals(#f.calls['ExitK9Vehicle'], 1)
    t.equals(#(f.calls['EnterNearestK9Vehicle'] or {}), 0)
    t.equals(f.canShowK9UICalls(), 0, 'exit must never gate on the role/model combinator')
    t.equals(f.hasK9AccessCalls(), 0, 'exit must never gate on access either -- a K9 whose certification lapses mid-ride must always be able to get out')
    t.equals(f.denyCalls(), 0)
end)

t.test('VehicleEntryExit (Enter branch): GATE WIDENED TO HasK9Access() ALONE -- a High Command/autoAccessGrade-bypass holder (HasK9Access true, CanShowK9UI false) still enters, matching server/vehicle.lua\'s requestVehicleSeatClaim (HasK9Access(src) alone, no model/role check)', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'VehicleEntryExit' })
    t.isTrue(result.ok)
    t.equals(#f.calls['EnterNearestK9Vehicle'], 1)
    t.equals(f.canShowK9UICalls(), 0, 'the enter branch must consult HasK9Access() alone, never the broader CanShowK9UI() combinator')
    t.isTrue(f.hasK9AccessCalls() > 0)
    t.equals(f.denyCalls(), 0)
end)

t.test('VehicleEntryExit (Enter branch) CONTROL: a caller with NO K9 access at all (HasK9Access false) is still denied -- the widening does not open the door to everyone, only to the documented HasK9Access()-true bypass case', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'VehicleEntryExit' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['EnterNearestK9Vehicle'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('BasicBarkSounds: GATE WIDENED TO HasK9Access() ALONE -- a High Command/autoAccessGrade-bypass holder (HasK9Access true, CanShowK9UI false) still barks, matching server/main.lua\'s relayBark handler (HasK9Access(src) alone)', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'BasicBarkSounds' })
    t.isTrue(result.ok)
    t.equals(f.triggerServerEventCalls[1][1], 'qbx_k9unit:server:relayBark')
    t.equals(f.triggerServerEventCalls[1][2], 'bark')
    t.equals(f.canShowK9UICalls(), 0)
    t.isTrue(f.hasK9AccessCalls() > 0)
    t.equals(f.denyCalls(), 0)
end)

t.test('BasicBarkSounds CONTROL: a caller with NO K9 access at all (HasK9Access false) is still denied, and the bark event never fires', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'BasicBarkSounds' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#f.triggerServerEventCalls, 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('ScentTracking (release-ungated / attempt-gated toggle): already tracking scent -> stops WITHOUT ever consulting CanShowK9UI/HasK9Access', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    f.setQueryState('activeTrackType', 'scent')
    local result = f.callNui('tablet:triggerFeature', { feature = 'ScentTracking' })
    t.isTrue(result.ok)
    t.equals(#f.calls['StopTracking'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.equals(f.hasK9AccessCalls(), 0)
end)

t.test('ScentTracking (Start branch): GATE WIDENED TO HasK9Access() ALONE -- a High Command/autoAccessGrade-bypass holder still starts a scent track, matching server/tracking.lua\'s findTrackableSource (HasK9Access(source) alone) and StartTrack()\'s own already-widened internal gate', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'ScentTracking' })
    t.isTrue(result.ok)
    t.equals(#f.calls['StartScentTrack'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.isTrue(f.hasK9AccessCalls() > 0)
end)

t.test('ScentTracking (Start branch) CONTROL: a caller with NO K9 access at all is still denied, and StartScentTrack never fires', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'ScentTracking' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['StartScentTrack'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('BloodTracking: same HasK9Access()-alone widening as ScentTracking -- bypass holder starts, zero-access caller is denied', function()
    local bypass = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local bypassResult = bypass.callNui('tablet:triggerFeature', { feature = 'BloodTracking' })
    t.isTrue(bypassResult.ok)
    t.equals(#bypass.calls['StartBloodTrack'], 1)
    t.equals(bypass.canShowK9UICalls(), 0)

    local noAccess = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local noAccessResult = noAccess.callNui('tablet:triggerFeature', { feature = 'BloodTracking' })
    t.isFalse(noAccessResult.ok)
    t.equals(#(noAccess.calls['StartBloodTrack'] or {}), 0)
end)

t.test('GunpowderSniffing: same HasK9Access()-alone widening as ScentTracking -- bypass holder starts, zero-access caller is denied', function()
    local bypass = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local bypassResult = bypass.callNui('tablet:triggerFeature', { feature = 'GunpowderSniffing' })
    t.isTrue(bypassResult.ok)
    t.equals(#bypass.calls['StartGunpowderTrack'], 1)
    t.equals(bypass.canShowK9UICalls(), 0)

    local noAccess = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local noAccessResult = noAccess.callNui('tablet:triggerFeature', { feature = 'GunpowderSniffing' })
    t.isFalse(noAccessResult.ok)
    t.equals(#(noAccess.calls['StartGunpowderTrack'] or {}), 0)
end)

t.test('BiteAndHold: engaged -> Release fires ungated, even with zero access; not engaged + no access -> Request never fires', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    f.setQueryState('isBiteHoldEngaged', true)
    local result = f.callNui('tablet:triggerFeature', { feature = 'BiteAndHold' })
    t.isTrue(result.ok)
    t.equals(#f.calls['ReleaseBiteHold'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.equals(f.hasK9AccessCalls(), 0)
end)

t.test('BiteAndHold (Start branch): GATE WIDENED TO HasK9Access() ALONE -- a High Command/autoAccessGrade-bypass holder still requests a bite-and-hold, matching server/combat.lua\'s shared ValidateCombatRequest (HasK9Access(src) alone) and RequestBiteHold()\'s own already-widened internal gate', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'BiteAndHold' })
    t.isTrue(result.ok)
    t.equals(#f.calls['RequestBiteHold'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.isTrue(f.hasK9AccessCalls() > 0)
end)

t.test('BiteAndHold (Start branch) CONTROL: a caller with NO K9 access at all is still denied, and RequestBiteHold never fires', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'BiteAndHold' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['RequestBiteHold'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('NonLethalTakedown: GATE WIDENED TO HasK9Access() ALONE -- a High Command/autoAccessGrade-bypass holder still requests a takedown, matching server/combat.lua\'s shared ValidateCombatRequest (HasK9Access(src) alone)', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'NonLethalTakedown' })
    t.isTrue(result.ok)
    t.equals(#f.calls['RequestTakedown'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.isTrue(f.hasK9AccessCalls() > 0)
end)

t.test('NonLethalTakedown CONTROL: a caller with NO K9 access at all is still denied, and RequestTakedown never fires', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'NonLethalTakedown' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['RequestTakedown'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('PropDragging (release-ungated / attempt-gated toggle): either release branch fires WITHOUT ever consulting CanShowK9UI/HasK9Access, even with zero access', function()
    local draggedTarget = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    draggedTarget.setQueryState('isDragEngaged', true)
    local draggedResult = draggedTarget.callNui('tablet:triggerFeature', { feature = 'PropDragging' })
    t.isTrue(draggedResult.ok)
    t.equals(#draggedTarget.calls['ReleaseDrag'], 1)
    t.equals(draggedTarget.canShowK9UICalls(), 0)
    t.equals(draggedTarget.hasK9AccessCalls(), 0)
end)

t.test('PropDragging (Start branch): GATE WIDENED TO HasK9Access() ALONE -- a High Command/autoAccessGrade-bypass holder still requests a drag, matching server/combat.lua\'s shared ValidateCombatRequest (HasK9Access(src) alone)', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'PropDragging' })
    t.isTrue(result.ok)
    t.equals(#f.calls['RequestDrag'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.isTrue(f.hasK9AccessCalls() > 0)
end)

t.test('PropDragging (Start branch) CONTROL: a caller with NO K9 access at all is still denied, and RequestDrag never fires', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'PropDragging' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['RequestDrag'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('ThermalVision: fully self-gating passthrough -- this file never consults CanShowK9UI/HasK9Access for it at all', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:triggerFeature', { feature = 'ThermalVision' })
    t.isTrue(result.ok)
    t.equals(#f.calls['ToggleThermalVision'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.equals(f.hasK9AccessCalls(), 0)
end)

t.test('FetchMechanic (throw branch): gated on HasK9Access() ONLY, matching RequestThrowFetchBall()\'s own documented contract -- CanShowK9UI is never consulted', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:triggerFeature', { feature = 'FetchMechanic' })
    t.isTrue(result.ok)
    t.equals(#f.calls['RequestThrowFetchBall'], 1)
    t.equals(f.canShowK9UICalls(), 0)
    t.isTrue(f.hasK9AccessCalls() > 0)
end)

t.test('FetchMechanic (carrying already): releases ungated', function()
    local f = newTabletFixture({ hasK9Access = false })
    f.setQueryState('isFetchCarryEngaged', true)
    local result = f.callNui('tablet:triggerFeature', { feature = 'FetchMechanic' })
    t.isTrue(result.ok)
    t.equals(#f.calls['ReleaseFetchBall'], 1)
end)

-- THIS PIN WAS FLIPPED. It used to assert the OPPOSITE -- that a High
-- Command/autoAccessGrade holder is denied here -- on the stated grounds
-- that a since-removed confirm function re-gated on the full CanShowK9UI()
-- combinator anyway, so widening this wrapper would be a no-op. That was
-- true when written and became false when that file's own gate was
-- widened to HasK9Access() alone. The pin then outlived its own premise and
-- started defending the bug: this wrapper's pre-check was, by then, the ONLY
-- thing refusing, one layer above an already-correct callee.
--
-- A test whose justification has quietly expired is worse than no test,
-- because it reads as a deliberate decision. When the reasoning in a pin's
-- own name stops matching the code, the pin must be re-derived, not trusted.
t.test('HandlerPartnership: toggles exactly like Leash -- partnered releases ungated, else attempts + seam-guarded', function()
    local f = newTabletFixture()
    f.setQueryState('isPartnered', true)
    f.callNui('tablet:triggerFeature', { feature = 'HandlerPartnership' })
    t.equals(#f.calls['BreakPartnership'], 1)
    t.equals(f.canShowK9UICalls(), 0)
end)

t.test('HandlerPartnership NOT-WIDENED PIN: a High Command/autoAccessGrade-bypass holder (HasK9Access true, CanShowK9UI false) is still denied -- server/partnership.lua\'s CheckPartnershipEligibility requires model-or-role for at least one party before HasK9Access is ever consulted, matching radial.lua\'s own "k9_partner_up" item exactly', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'HandlerPartnership' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['RequestPartnerUp'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('K9Inventory: gated on the full CanShowK9UI() combinator -- a normal, on-duty certified K9 opens their own gear', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:triggerFeature', { feature = 'K9Inventory' })
    t.isTrue(result.ok)
    t.equals(#f.calls['RequestOpenOwnK9Inventory'], 1)
end)

t.test('K9Inventory NOT-WIDENED PIN: a High Command/autoAccessGrade-bypass holder (HasK9Access true, CanShowK9UI false) is still denied -- server/inventory.lua\'s openK9Inventory requires HasK9Access(target) AND (a real K9 model OR the decoupled K9 role) for the K9 whose gear is opened, matching radial.lua\'s own "k9_open_inventory" item exactly', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = true })
    local result = f.callNui('tablet:triggerFeature', { feature = 'K9Inventory' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_available')
    t.equals(#(f.calls['RequestOpenOwnK9Inventory'] or {}), 0)
    t.equals(f.denyCalls(), 1)
end)

t.test('K9Medkit: CanShowK9UI() PRE-CHECK REMOVED -- "Treat K9" is a human-handler, job-only action (server/medkit.lua\'s IsMedkitUserAuthorized never calls HasK9Access, model, or role), so this fires even for a caller with ZERO K9 access/role/model of their own', function()
    local f = newTabletFixture({ canShowK9UI = false, hasK9Access = false })
    local result = f.callNui('tablet:triggerFeature', { feature = 'K9Medkit' })
    t.isTrue(result.ok)
    t.equals(#f.calls['RequestTreatNearestK9'], 1)
    t.equals(f.canShowK9UICalls(), 0, 'this wrapper must never consult CanShowK9UI() at all -- the server-side gate is job-only, not K9-access-based')
    t.equals(f.hasK9AccessCalls(), 0, 'nor HasK9Access() -- widening to HasK9Access() alone would still be stricter than the real, job-only server gate')
    t.equals(f.denyCalls(), 0)
end)

-- ----------------------------------------------------------------------
-- SECTION 3 -- ALLOWLISTED_TABLET_COMMANDS / SubmitAllowlistedCommand.
--
-- REMOVED (an earlier pass): a broader 'tablet:runCommand' NUI callback
-- used to expose SubmitAllowlistedCommand generically over a nine-name
-- allowlist (k9certify, k9decertify, k9decertifyoffline, k9givexp, plus
-- the five k9audit* commands from server/admin.lua). A frontend sweep
-- found zero callers of 'tablet:runCommand' anywhere in html/, and it was
-- never part of client/tablet.lua's own documented NUI CONTRACT -- a
-- registered capability nothing could reach.
--
-- REMOVED ENTIRELY THIS PASS (docs/history/COMMAND_CONSOLIDATION_SPEC.md §6 bugfix):
-- tablet:decertify was the LAST remaining caller of
-- SubmitAllowlistedCommand/ALLOWLISTED_TABLET_COMMANDS/
-- IsSafeCommandArgToken -- now that it calls a real server callback
-- instead (tested above), that entire SECTION 3 helper block is dead code
-- and was deleted from client/tablet.lua rather than left as an unreachable
-- stub (the exact "dead code that looks live" failure mode this file's own
-- header already warns about). Nothing in client/tablet.lua calls
-- ExecuteCommand anymore -- pinned below.
-- ----------------------------------------------------------------------

t.test('tablet:decertify: disabled entirely when allowActionsFromTablet is false, never reaches the server callback', function()
    local f = newTabletFixture({ featureControl = { allowActionsFromTablet = false } })
    local result = f.callNui('tablet:decertify', { targetCitizenId = 'ABC123', departmentKey = 'police' })
    t.equals(result.error, 'actions_disabled')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('SECTION 3 REMOVED: client/tablet.lua never calls ExecuteCommand at all anymore -- SubmitAllowlistedCommand and its allowlist are gone, not merely unreachable', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletDecertify', { ok = true })
    f.callNui('tablet:decertify', { targetCitizenId = 'ABC123', departmentKey = 'police' })
    t.equals(#f.executeCommandCalls, 0)
end)

t.test('ALLOWLISTED_TABLET_COMMANDS/tablet:runCommand: neither the generic bridge nor the decertify-only allowlist survive as a registered NUI callback', function()
    local f = newTabletFixture()
    t.isNil(f.nuiCallbacks['tablet:runCommand'], 'tablet:runCommand must no longer be registered -- it had no caller in html/ and backed an unreachable command allowlist')
end)

-- ----------------------------------------------------------------------
-- OpenTablet() payload -- peds / themingEnabled additions.
-- ----------------------------------------------------------------------

t.test('OpenTablet(): payload carries peds (shared Config.Peds, no round trip) and themingEnabled', function()
    local f = newTabletFixture({ features = { TabletTheming = true } })
    f.env.OpenTablet()
    local msg = f.sendNuiMessageCalls[1]
    t.equals(msg.data.peds, f.Config.Peds)
    t.isTrue(msg.data.themingEnabled)
end)

t.test('OpenTablet(): themingEnabled reflects Config.Features.TabletTheming = false', function()
    local f = newTabletFixture({ features = { TabletTheming = false } })
    f.env.OpenTablet()
    t.isFalse(f.sendNuiMessageCalls[1].data.themingEnabled)
end)

t.test('OpenTablet(): payload carries branding verbatim (shared Config.CommandTablet.branding, no round trip)', function()
    local customBranding = { serverName = 'Crimson Roleplay', logo = 'images/logo.png', theme = { primaryColor = '#C8102E', accentColor = '#FF2D2D', backgroundColor = '#0B0B0D', textColor = '#F5F5F5' } }
    local f = newTabletFixture({ commandTablet = { branding = customBranding } })
    f.env.OpenTablet()
    t.equals(f.sendNuiMessageCalls[1].data.branding, customBranding)
end)

t.test('OpenTablet(): a missing/malformed Config.CommandTablet.branding degrades to an empty table, never nil/error', function()
    local f = newTabletFixture({ commandTablet = { branding = 'not-a-table' } })
    f.env.OpenTablet()
    t.isNotNil(f.sendNuiMessageCalls[1].data.branding)
    t.equals(next(f.sendNuiMessageCalls[1].data.branding), nil)
end)

-- ----------------------------------------------------------------------
-- tablet:assignK9Role / tablet:revertK9Ped -- forwarded verbatim,
-- server/tablet.lua's own tabletAssignK9Role/tabletRevertK9Ped already do
-- every authorization/validation check. See this file's header NUI
-- CONTRACT note.
-- ----------------------------------------------------------------------

t.test('tablet:assignK9Role: missing/empty targetCitizenId or modelName is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:assignK9Role', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:assignK9Role', { targetCitizenId = 'ABC' }).error, 'invalid_args')
    t.equals(f.callNui('tablet:assignK9Role', { targetCitizenId = '', modelName = 'a_c_shepherd' }).error, 'invalid_args')
    t.equals(f.callNui('tablet:assignK9Role', { targetCitizenId = 'ABC', modelName = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:assignK9Role: a valid payload forwards (citizenid, modelName) to tabletAssignK9Role and forwards the result verbatim', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAssignK9Role', { ok = true })
    local result = f.callNui('tablet:assignK9Role', { targetCitizenId = 'ABC', modelName = 'a_c_husky' })
    t.isTrue(result.ok)
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAssignK9Role')
    t.equals(f.callbackCallLog[1].args[1], 'ABC')
    t.equals(f.callbackCallLog[1].args[2], 'a_c_husky')
end)

t.test('tablet:assignK9Role: a server denial (e.g. caller not high command) is forwarded verbatim, never swallowed', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAssignK9Role', { ok = false, error = 'denied' })
    local result = f.callNui('tablet:assignK9Role', { targetCitizenId = 'ABC', modelName = 'a_c_husky' })
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
end)

t.test('tablet:assignK9Role: a THROWN server callback fails closed to error="timeout", never raises', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:assignK9Role', { targetCitizenId = 'ABC', modelName = 'a_c_husky' })
    t.isFalse(result.ok)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:revertK9Ped: missing/empty targetCitizenId is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:revertK9Ped', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:revertK9Ped', { targetCitizenId = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:revertK9Ped: LOAD-BEARING no-unbounded-trap -- forwards (citizenid) and the result verbatim regardless of what the target holds; this file adds no additional target-side gate of its own', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRevertK9Ped', { ok = true })
    local result = f.callNui('tablet:revertK9Ped', { targetCitizenId = 'ALREADY-DECERTIFIED' })
    t.isTrue(result.ok)
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletRevertK9Ped')
    t.equals(f.callbackCallLog[1].args[1], 'ALREADY-DECERTIFIED')
end)

t.test('tablet:revertK9Ped: a server denial is forwarded verbatim', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletRevertK9Ped', { ok = false, error = 'denied' })
    local result = f.callNui('tablet:revertK9Ped', { targetCitizenId = 'ABC' })
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
end)

-- ----------------------------------------------------------------------
-- Tablet theming -- tablet:getTheme / tablet:setTheme / tablet:resetTheme.
-- Translated through ThemeResultToJs (reason -> error, field forwarded).
-- ----------------------------------------------------------------------

t.test('tablet:getTheme: forwards the server theme verbatim on success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletGetTheme', { ok = true, theme = { primaryColor = '#2563eb', density = 'comfortable', headerTitle = 'K9 Command Tablet' } })
    local result = f.callNui('tablet:getTheme', {})
    t.isTrue(result.ok)
    t.equals(result.theme.primaryColor, '#2563eb')
    t.equals(result.theme.headerTitle, 'K9 Command Tablet')
end)

t.test('tablet:getTheme: a thrown/unregistered callback fails closed to error="timeout"', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:getTheme', {})
    t.isFalse(result.ok)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:setTheme: a non-table payload is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:setTheme', nil)
    t.equals(result.error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:setTheme: forwards the WHOLE payload table verbatim to tabletSetTheme -- no client-side re-validation of individual fields', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletSetTheme', { ok = true, theme = { headerTitle = 'Bark Squad HQ' } })
    local result = f.callNui('tablet:setTheme', { headerTitle = 'Bark Squad HQ', density = 'compact' })
    t.isTrue(result.ok)
    t.equals(result.theme.headerTitle, 'Bark Squad HQ')
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletSetTheme')
    t.equals(f.callbackCallLog[1].args[1].headerTitle, 'Bark Squad HQ')
    t.equals(f.callbackCallLog[1].args[1].density, 'compact')
end)

t.test('tablet:setTheme: reason="invalid_field" is translated to error="invalid_field" with `field` forwarded, so the tablet can highlight exactly which input failed', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletSetTheme', { ok = false, reason = 'invalid_field', field = 'primaryColor' })
    local result = f.callNui('tablet:setTheme', { primaryColor = 'not-a-color' })
    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_field')
    t.equals(result.field, 'primaryColor')
end)

t.test('tablet:setTheme: reason="denied"/"feature_disabled"/"rate_limited" are all forwarded as the plain error code, unchanged', function()
    local f = newTabletFixture()
    for _, reason in ipairs({ 'denied', 'feature_disabled', 'rate_limited', 'db_error', 'invalid_payload' }) do
        f.setServerCallback('qbx_k9unit:server:tabletSetTheme', { ok = false, reason = reason })
        local result = f.callNui('tablet:setTheme', { density = 'compact' })
        t.isFalse(result.ok)
        t.equals(result.error, reason)
    end
end)

t.test('tablet:setTheme: a THROWN server callback fails closed to error="timeout"', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:setTheme', { density = 'compact' })
    t.isFalse(result.ok)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:resetTheme: forwards the reset theme verbatim on success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletResetTheme', { ok = true, theme = { density = 'comfortable' } })
    local result = f.callNui('tablet:resetTheme', {})
    t.isTrue(result.ok)
    t.equals(result.theme.density, 'comfortable')
end)

t.test('tablet:resetTheme: a denial is translated the same way as setTheme', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletResetTheme', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:resetTheme', {})
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
end)

-- ----------------------------------------------------------------------
-- qbx_k9unit:client:themeUpdated push -- relayed verbatim into
-- SendNUIMessage, registered unconditionally (not only while tabletOpen).
--
-- MUST be fired via fireNetEvent (RegisterNetEvent), never fireEvent
-- (AddEventHandler): server/runtimecontrol.lua's own tabletSetTheme/
-- tabletResetTheme/runtime theme reload all reach this ONLY through a
-- real TriggerClientEvent, which a plain AddEventHandler-only
-- registration can never receive at all -- see client/tablet.lua's own
-- comment on this handler for the full wiring-bug history (an
-- already-open tablet never updated live until this was fixed to
-- RegisterNetEvent). The dedicated registration-mechanism test below
-- fails loudly if this ever regresses back to AddEventHandler.
-- ----------------------------------------------------------------------

t.test('qbx_k9unit:client:themeUpdated is registered via RegisterNetEvent, not merely AddEventHandler -- a real, network-originated TriggerClientEvent must actually be able to reach it', function()
    local f = newTabletFixture()
    t.isTrue(f.isRegisteredAsNetEvent('qbx_k9unit:client:themeUpdated'),
        'client/tablet.lua must call RegisterNetEvent for this name -- AddEventHandler alone never receives a server-fired TriggerClientEvent')
end)

t.test('themeUpdated push: relayed into SendNUIMessage as {action="tablet:themeUpdated", data=theme}, verbatim', function()
    local f = newTabletFixture()
    local theme = { primaryColor = '#ff0000', density = 'compact', headerTitle = 'Bark Squad HQ' }
    f.fireNetEvent('qbx_k9unit:client:themeUpdated', theme)
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:themeUpdated')
    t.equals(f.sendNuiMessageCalls[1].data, theme)
end)

t.test('themeUpdated push: fires even while the tablet is CLOSED -- this file never gates the listener on tabletOpen', function()
    local f = newTabletFixture()
    -- Tablet never opened this test at all.
    f.fireNetEvent('qbx_k9unit:client:themeUpdated', { density = 'compact' })
    t.equals(#f.sendNuiMessageCalls, 1, 'the push must reach SendNUIMessage regardless of local open/closed state')
end)

t.test('themeUpdated push: fires again while the tablet IS open, alongside the original tablet:open push', function()
    local f = newTabletFixture()
    f.env.OpenTablet()
    f.fireNetEvent('qbx_k9unit:client:themeUpdated', { density = 'compact' })
    t.equals(#f.sendNuiMessageCalls, 2)
    t.equals(f.sendNuiMessageCalls[2].action, 'tablet:themeUpdated')
end)

t.test('themeUpdated push: a nil payload never throws and is still forwarded to the NUI (data simply absent) -- html/tablet.js\'s own handleThemeUpdated is the layer that actually guards against blanking the visible theme', function()
    local f = newTabletFixture()
    f.fireNetEvent('qbx_k9unit:client:themeUpdated', nil)
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:themeUpdated')
    t.isNil(f.sendNuiMessageCalls[1].data)
end)

t.test('themeUpdated push: a malformed (non-table) payload never throws and is forwarded as-is -- this file does no field validation itself, matching equipmentShopLocationsUpdated\'s own additive listener above; server/runtimecontrol.lua\'s ValidateFullTheme is the real gate, html/tablet.js\'s own type/field fallbacks are the NUI-side defense in depth', function()
    local f = newTabletFixture()
    f.fireNetEvent('qbx_k9unit:client:themeUpdated', 'not-a-table')
    t.equals(#f.sendNuiMessageCalls, 1)
    t.equals(f.sendNuiMessageCalls[1].action, 'tablet:themeUpdated')
    t.equals(f.sendNuiMessageCalls[1].data, 'not-a-table')
end)

t.test('themeUpdated push: a partial theme (missing most fields) is still forwarded verbatim, not stripped or replaced with a full default table -- html/tablet.js\'s own per-field DEFAULT_THEME fallback is what keeps this from blanking any one field', function()
    local f = newTabletFixture()
    local partial = { primaryColor = '#abcdef' }
    f.fireNetEvent('qbx_k9unit:client:themeUpdated', partial)
    t.equals(f.sendNuiMessageCalls[1].data, partial)
    t.isNil(f.sendNuiMessageCalls[1].data.headerTitle)
    t.isNil(f.sendNuiMessageCalls[1].data.density)
end)

-- ----------------------------------------------------------------------
-- Certification tier editing -- server/certtiers.lua. Same
-- TranslateReasonResult bridge as tablet theming (reason -> error), plus
-- the extra fields (tiers/capabilityCatalog/warning/referenceCount) that
-- generic bridge must forward untouched.
-- ----------------------------------------------------------------------

t.test('tablet:certTiersList: forwards tiers + capabilityCatalog verbatim on success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersList', {
        ok = true,
        tiers = { { key = 'trainee', label = 'Trainee', ordinal = 1, capabilities = {} } },
        capabilityCatalog = { specializations_eligible = { label = 'Eligible for specializations' } },
    })
    local result = f.callNui('tablet:certTiersList', {})
    t.isTrue(result.ok)
    t.equals(result.tiers[1].key, 'trainee')
    t.equals(result.capabilityCatalog.specializations_eligible.label, 'Eligible for specializations')
end)

t.test('tablet:certTiersList: reason="denied" (non-high-command caller) is translated to error="denied"', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersList', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:certTiersList', {})
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
    t.isNil(result.reason, 'the raw `reason` key must not leak through to the JS-facing contract')
end)

t.test('tablet:certTiersList: a THROWN server callback fails closed to error="timeout"', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:certTiersList', {})
    t.isFalse(result.ok)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:certTiersUpsert: missing/empty key is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:certTiersUpsert', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:certTiersUpsert', { key = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:certTiersUpsert: forwards the WHOLE {key,label,capabilities} table verbatim as ONE argument', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersUpsert', { ok = true, tiers = {}, capabilityCatalog = {} })
    f.callNui('tablet:certTiersUpsert', { key = 'master', label = 'Master', capabilities = { 'advanced_tracking' } })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:certTiersUpsert')
    t.equals(f.callbackCallLog[1].args[1].key, 'master')
    t.equals(f.callbackCallLog[1].args[1].label, 'Master')
    t.equals(f.callbackCallLog[1].args[1].capabilities[1], 'advanced_tracking')
end)

t.test('tablet:certTiersUpsert: reason="invalid_label"/"too_many_tiers"/"busy" all forward as the plain error code', function()
    local f = newTabletFixture()
    for _, reason in ipairs({ 'invalid_label', 'invalid_key', 'invalid_capabilities', 'too_many_tiers', 'busy', 'rate_limited' }) do
        f.setServerCallback('qbx_k9unit:server:certTiersUpsert', { ok = false, reason = reason })
        local result = f.callNui('tablet:certTiersUpsert', { key = 'master', label = 'Master', capabilities = {} })
        t.isFalse(result.ok)
        t.equals(result.error, reason)
    end
end)

t.test('tablet:certTiersReorder: missing/non-table orderedKeys is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:certTiersReorder', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:certTiersReorder', { orderedKeys = 'not-a-table' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:certTiersReorder: forwards the bare orderedKeys array (not wrapped) as the server\'s own second argument, and surfaces the retroactive-rerank `warning` on success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersReorder', {
        ok = true,
        tiers = {},
        warning = 'Reordering tiers changes rank comparisons RETROACTIVELY.',
    })
    local result = f.callNui('tablet:certTiersReorder', { orderedKeys = { 'senior', 'trainee', 'certified' } })
    t.isTrue(result.ok)
    t.contains(result.warning, 'RETROACTIVELY')
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:certTiersReorder')
    t.equals(f.callbackCallLog[1].args[1][1], 'senior')
    t.equals(f.callbackCallLog[1].args[1][2], 'trainee')
    t.equals(f.callbackCallLog[1].args[1][3], 'certified')
end)

t.test('tablet:certTiersReorder: reason="must_include_every_tier"/"invalid_key_set" forward as the plain error code', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersReorder', { ok = false, reason = 'must_include_every_tier' })
    local result = f.callNui('tablet:certTiersReorder', { orderedKeys = { 'trainee' } })
    t.isFalse(result.ok)
    t.equals(result.error, 'must_include_every_tier')
end)

t.test('tablet:certTiersDelete: missing/empty key is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:certTiersDelete', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:certTiersDelete', { key = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:certTiersDelete: forwards the bare key string, and a "tier_in_use" REFUSAL carries referenceCount through untouched', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersDelete', { ok = false, reason = 'tier_in_use', referenceCount = 7 })
    local result = f.callNui('tablet:certTiersDelete', { key = 'trainee' })
    t.isFalse(result.ok)
    t.equals(result.error, 'tier_in_use')
    t.equals(result.referenceCount, 7)
    t.equals(f.callbackCallLog[1].args[1], 'trainee')
end)

t.test('tablet:certTiersDelete: "protected_tier" (the unconditional \'certified\' protection) forwards as the plain error code', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersDelete', { ok = false, reason = 'protected_tier' })
    local result = f.callNui('tablet:certTiersDelete', { key = 'certified' })
    t.isFalse(result.ok)
    t.equals(result.error, 'protected_tier')
end)

t.test('tablet:certTiersDelete: a successful delete forwards the refreshed tiers list', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:certTiersDelete', { ok = true, tiers = { { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} } } })
    local result = f.callNui('tablet:certTiersDelete', { key = 'trainee' })
    t.isTrue(result.ok)
    t.equals(result.tiers[1].key, 'certified')
end)

-- ----------------------------------------------------------------------
-- K9 Audit Trail viewer -- server/admin.lua's six tabletAudit* callbacks
-- (Cert/Partner/Search/Xp/Dept/Catalog), bridged one-to-one by
-- tablet:auditCert/Partner/Search/Xp/Dept/Catalog. Every one is forwarded
-- VERBATIM (no TranslateReasonResult -- server/admin.lua's own response
-- shape already matches this contract's `{ok, error, message}` directly),
-- so these tests cover only: shape validation (rejected before any
-- server round trip), correct callback name/argument order, and the
-- `limit`/`value`/`catalogName` optional/verbatim-argument handling
-- client/tablet.lua's own OptionalNumericLimit/tablet:auditSearch/
-- tablet:auditCatalog comments describe.
-- ----------------------------------------------------------------------

t.test('tablet:auditCert: missing/blank targetCitizenId is rejected before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:auditCert', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:auditCert', { targetCitizenId = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:auditCert: forwards citizenid + limit, in that order, and returns the server response verbatim', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCert', { ok = true, rows = { { job = 'police', active = 1 } }, label = 'Certification history for ABC123' })
    local result = f.callNui('tablet:auditCert', { targetCitizenId = 'ABC123', limit = 40 })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditCert')
    t.equals(f.callbackCallLog[1].args[1], 'ABC123')
    t.equals(f.callbackCallLog[1].args[2], 40)
    t.isTrue(result.ok)
    t.equals(result.rows[1].job, 'police')
    t.equals(result.label, 'Certification history for ABC123')
end)

t.test('tablet:auditCert: a non-number limit (or an absent one) is dropped to nil, never forwarded raw', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCert', { ok = true, rows = {}, label = '' })
    f.callNui('tablet:auditCert', { targetCitizenId = 'ABC123', limit = 'not-a-number' })
    t.isNil(f.callbackCallLog[1].args[2])

    f.callNui('tablet:auditCert', { targetCitizenId = 'ABC123' })
    t.isNil(f.callbackCallLog[2].args[2])
end)

t.test('tablet:auditCert: not_authorized/rate_limited from the server forward verbatim, no translation', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCert', { ok = false, error = 'not_authorized', message = 'You are not authorized to view this.' })
    local result = f.callNui('tablet:auditCert', { targetCitizenId = 'ABC123' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.equals(result.message, 'You are not authorized to view this.')
end)

t.test('tablet:auditPartner: same shape guard and forwarding as tablet:auditCert', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:auditPartner', {}).error, 'invalid_args')

    f.setServerCallback('qbx_k9unit:server:tabletAuditPartner', { ok = true, rows = {}, label = 'Partnership history for ABC123' })
    f.callNui('tablet:auditPartner', { targetCitizenId = 'ABC123', limit = 5 })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditPartner')
    t.equals(f.callbackCallLog[1].args[1], 'ABC123')
    t.equals(f.callbackCallLog[1].args[2], 5)
end)

t.test('tablet:auditXp: requires targetCitizenId, forwards it ALONE -- no limit argument at all', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:auditXp', {}).error, 'invalid_args')

    f.setServerCallback('qbx_k9unit:server:tabletAuditXp', { ok = true, rows = { { xp = 1234, updated_at = '2026-01-01' } }, label = 'XP snapshot for ABC123' })
    local result = f.callNui('tablet:auditXp', { targetCitizenId = 'ABC123', limit = 99 })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditXp')
    t.equals(f.callbackCallLog[1].args[1], 'ABC123')
    t.isNil(f.callbackCallLog[1].args[2], 'limit is never forwarded for auditXp, even if the caller sent one')
    t.equals(result.rows[1].xp, 1234)
end)

t.test('tablet:auditDept: requires departmentKey, forwards it verbatim (never validated against a hardcoded department list client-side)', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:auditDept', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:auditDept', { departmentKey = '' }).error, 'invalid_args')

    f.setServerCallback('qbx_k9unit:server:tabletAuditDept', { ok = true, rows = { { citizenid = 'ABC123' } }, label = 'Roster for police' })
    f.callNui('tablet:auditDept', { departmentKey = 'police', limit = 10 })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditDept')
    t.equals(f.callbackCallLog[1].args[1], 'police')
    t.equals(f.callbackCallLog[1].args[2], 10)
end)

t.test('tablet:auditSearch: requires a non-blank mode string, rejected before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:auditSearch', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:auditSearch', { mode = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:auditSearch: `mode` is forwarded VERBATIM, unchecked against any client-side whitelist -- the server is the real gate', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditSearch', { ok = false, error = 'invalid_args' })
    f.callNui('tablet:auditSearch', { mode = 'not-a-real-mode' })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditSearch')
    t.equals(f.callbackCallLog[1].args[1], 'not-a-real-mode')
end)

t.test('tablet:auditSearch: officer/person modes forward {mode, value, limit} in order', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditSearch', { ok = true, rows = {}, label = '' })
    f.callNui('tablet:auditSearch', { mode = 'officer', value = 'ABC123', limit = 15 })
    t.equals(f.callbackCallLog[1].args[1], 'officer')
    t.equals(f.callbackCallLog[1].args[2], 'ABC123')
    t.equals(f.callbackCallLog[1].args[3], 15)
end)

t.test('tablet:auditSearch: a missing/non-string value is sent as an empty string, NEVER nil -- value is not this call\'s last positional argument', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditSearch', { ok = true, rows = {}, label = '' })
    f.callNui('tablet:auditSearch', { mode = 'recent' })
    t.equals(f.callbackCallLog[1].args[1], 'recent')
    t.equals(f.callbackCallLog[1].args[2], '', 'empty string, not nil, so a NON-TRAILING nil can never shift limit out of position')
    t.isNil(f.callbackCallLog[1].args[3], 'limit itself is still correctly nil when the caller sent none')
end)

t.test('tablet:auditSearch: recent mode forwards a real limit correctly positioned after the empty value', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditSearch', { ok = true, rows = {}, label = 'Most recent searches' })
    f.callNui('tablet:auditSearch', { mode = 'recent', limit = 25 })
    t.equals(f.callbackCallLog[1].args[1], 'recent')
    t.equals(f.callbackCallLog[1].args[2], '')
    t.equals(f.callbackCallLog[1].args[3], 25)
end)

t.test('tablet:auditCatalog: requires a non-blank catalogName, rejected before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:auditCatalog', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:auditCatalog', { catalogName = '' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:auditCatalog: `catalogName` is forwarded VERBATIM, unchecked against any client-side whitelist -- server/admin.lua\'s own CATALOG_AUDIT_SOURCES lookup is the real gate', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCatalog', { ok = false, error = 'invalid_args' })
    f.callNui('tablet:auditCatalog', { catalogName = 'not-a-real-catalog' })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditCatalog')
    t.equals(f.callbackCallLog[1].args[1], 'not-a-real-catalog')
end)

t.test('tablet:auditCatalog: forwards catalogName + limit, in that order, and returns the server response verbatim', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCatalog', {
        ok = true,
        rows = { { action = 'update', tier_key = 'master', detail = 'multiplier 1.0 -> 1.2', changed_by = 'HC1', changed_at = '2026-01-01 00:00:00' } },
        label = 'Certification tier catalog audit trail',
    })
    local result = f.callNui('tablet:auditCatalog', { catalogName = 'certTiers', limit = 30 })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:tabletAuditCatalog')
    t.equals(f.callbackCallLog[1].args[1], 'certTiers')
    t.equals(f.callbackCallLog[1].args[2], 30)
    t.isTrue(result.ok)
    t.equals(result.rows[1].tier_key, 'master')
    t.equals(result.label, 'Certification tier catalog audit trail')
end)

t.test('tablet:auditCatalog: a non-number limit (or an absent one) is dropped to nil, never forwarded raw', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCatalog', { ok = true, rows = {}, label = '' })
    f.callNui('tablet:auditCatalog', { catalogName = 'tabletThemes', limit = 'not-a-number' })
    t.isNil(f.callbackCallLog[1].args[2])

    f.callNui('tablet:auditCatalog', { catalogName = 'tabletThemes' })
    t.isNil(f.callbackCallLog[2].args[2])
end)

t.test('tablet:auditCatalog: not_authorized/rate_limited from the server forward verbatim, no translation', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:tabletAuditCatalog', { ok = false, error = 'not_authorized', message = 'You are not authorized to view this.' })
    local result = f.callNui('tablet:auditCatalog', { catalogName = 'certTiers' })
    t.isFalse(result.ok)
    t.equals(result.error, 'not_authorized')
    t.equals(result.message, 'You are not authorized to view this.')
end)

-- ----------------------------------------------------------------------
-- XP-RANK EDITOR -- server/xptiers.lua, owner-directed "set experience
-- level for each rank up" pass. Mirrors the certTiersList/certTiersUpsert
-- test shape immediately above (SECTION near line 1278) exactly -- same
-- TranslateReasonResult bridge, same fail-closed-to-timeout contract.
-- ----------------------------------------------------------------------

t.test('tablet:xpTiersList: forwards tiers verbatim on success', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:xpTiersList', {
        ok = true,
        tiers = { { ordinal = 1, xp = 0, label = 'Recruit K9', speedMultiplier = 1.0, scentRangeMultiplier = 1.0, xpLocked = true } },
    })
    local result = f.callNui('tablet:xpTiersList', {})
    t.isTrue(result.ok)
    t.equals(result.tiers[1].label, 'Recruit K9')
    t.isTrue(result.tiers[1].xpLocked)
end)

t.test('tablet:xpTiersList: reason="denied" (non-high-command caller) is translated to error="denied"', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:xpTiersList', { ok = false, reason = 'denied' })
    local result = f.callNui('tablet:xpTiersList', {})
    t.isFalse(result.ok)
    t.equals(result.error, 'denied')
    t.isNil(result.reason, 'the raw `reason` key must not leak through to the JS-facing contract')
end)

t.test('tablet:xpTiersList: a THROWN server callback fails closed to error="timeout"', function()
    local f = newTabletFixture()
    local result = f.callNui('tablet:xpTiersList', {})
    t.isFalse(result.ok)
    t.equals(result.error, 'timeout')
end)

t.test('tablet:xpTiersUpsert: a non-numeric/missing ordinal is invalid_args before any server round trip', function()
    local f = newTabletFixture()
    t.equals(f.callNui('tablet:xpTiersUpsert', {}).error, 'invalid_args')
    t.equals(f.callNui('tablet:xpTiersUpsert', { ordinal = 'two' }).error, 'invalid_args')
    t.equals(#f.callbackCallLog, 0)
end)

t.test('tablet:xpTiersUpsert: forwards the WHOLE payload table verbatim as ONE argument', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:xpTiersUpsert', { ok = true, tiers = {} })
    f.callNui('tablet:xpTiersUpsert', { ordinal = 2, xp = 1500, label = 'Rookie K9', speedMultiplier = 1.06, scentRangeMultiplier = 1.06 })
    t.equals(f.callbackCallLog[1].name, 'qbx_k9unit:server:xpTiersUpsert')
    t.equals(f.callbackCallLog[1].args[1].ordinal, 2)
    t.equals(f.callbackCallLog[1].args[1].xp, 1500)
    t.equals(f.callbackCallLog[1].args[1].label, 'Rookie K9')
end)

t.test('tablet:xpTiersUpsert: a demotion warning is forwarded verbatim, unmodified', function()
    local f = newTabletFixture()
    f.setServerCallback('qbx_k9unit:server:xpTiersUpsert', { ok = true, tiers = {}, warning = '1 currently-connected K9(s) just moved to a LOWER rank' })
    local result = f.callNui('tablet:xpTiersUpsert', { ordinal = 4, xp = 15000, label = 'Elite K9', speedMultiplier = 1.15, scentRangeMultiplier = 1.20 })
    t.isTrue(result.ok)
    t.isNotNil(result.warning)
    t.isTrue(result.warning:find('LOWER rank', 1, true) ~= nil)
end)

t.test('tablet:xpTiersUpsert: reason="invalid_order"/"base_tier_xp_fixed"/"busy" all forward as the plain error code', function()
    local f = newTabletFixture()
    for _, reason in ipairs({ 'invalid_order', 'base_tier_xp_fixed', 'invalid_xp', 'invalid_label', 'busy', 'rate_limited' }) do
        f.setServerCallback('qbx_k9unit:server:xpTiersUpsert', { ok = false, reason = reason })
        local result = f.callNui('tablet:xpTiersUpsert', { ordinal = 2, xp = 1500, label = 'x', speedMultiplier = 1, scentRangeMultiplier = 1 })
        t.isFalse(result.ok)
        t.equals(result.error, reason)
    end
end)

os.exit(t.summary())
