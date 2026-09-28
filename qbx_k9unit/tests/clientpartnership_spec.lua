--[[
    tests/clientpartnership_spec.lua

    Direct, black-box tests of client/partnership.lua against the REAL,
    unmodified production file -- the client half of
    Config.Features.HandlerPartnership (server/partnership.lua's own header
    is the authoritative contract). One of six client files this pass
    writes a spec for (see tests/vehiclecombatguard_spec.lua's own header,
    whose disclosed gap this batch exists to close).

    STYLE: fresh sandbox per test, a local fixture Config (never the real
    config.lua, per this suite's established convention -- see
    tests/clientcombat_spec.lua's header), a direct K9Compat stub (not the
    real shared/compat/core.lua + shared/compat/target.lua adapter pair --
    same reasoning as tests/clientkennel_spec.lua's own header: this
    file's own registration logic, not the compat translation layer, is
    what this spec exists to exercise).

    HARD (NOT SOFT) CROSS-FILE DEPENDENCIES, stubbed directly rather than
    loaded for real (this suite's established convention for a dependency
    outside the file under test -- see tests/clientcombat_spec.lua's own
    IsOwnModelK9()/HasK9Access() treatment): `IsOwnModelK9`/`CanShowK9UI`/
    `DenyK9UIAccess` (client/main.lua), `IsEntityModelK9` (client/main.lua),
    `IsK9RoleForPlayer` (client/appearance.lua) -- the "Partner Up"
    canInteract predicate calls all three of the latter UNGUARDED (no
    `type(fn) == 'function'` check), which is correct: both source files are
    always-loaded foundational files per fxmanifest.lua's own client_scripts
    order comment, never a soft/optional dependency the way
    e.g. client/wellbeing.lua's `RestoreInjury` is.

    NO NET-EVENT DISPATCH NEEDS A COROUTINE WRAPPER HERE -- unlike
    tests/clientkennel_spec.lua/tests/clientfetch_spec.lua/
    tests/clientpropattachment_spec.lua, none of this file's three
    RegisterNetEvent handler BODIES ever call Wait (confirmed by reading the
    whole file: no model loading, no shape tests, nothing that yields) --
    each is invoked directly, synchronously, exactly like
    tests/clientcombat_spec.lua's own `dispatchNetEvent` for that file's
    identical reason.

    lib.callback.await IS USED, ONCE -- `RefreshPartnershipStateFromServer`.
    Modeled the same way tests/clientcombat_spec.lua's header confirms this
    resource-wide "pcall-wrapped, fails closed on a throw" contract for
    every OTHER `lib.callback.await` call site -- this fixture's
    `lib.callback.await` stub is directly controllable to return a
    tuple OR to throw, so both the success path and the FAIL-CLOSED GUARD
    this function's own doc comment describes are exercised against real
    behavior, not a mock that always agrees with the assertion.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

local RESOURCE_NAME = 'qbx_k9unit'

--- @param opts { handlerPartnership: boolean? }?
--- @return table fixture
local function newPartnershipFixture(opts)
    opts = opts or {}

    local isOwnModelK9 = false
    local function IsOwnModelK9() return isOwnModelK9 end
    local canShowK9UI = true
    local function CanShowK9UI() return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local isEntityModelK9 = false
    local function IsEntityModelK9(_entity) return isEntityModelK9 end
    local isK9RoleForPlayer = false
    local isK9RoleForPlayerCalls = {}
    local function IsK9RoleForPlayer(targetServerId)
        isK9RoleForPlayerCalls[#isK9RoleForPlayerCalls + 1] = targetServerId
        return isK9RoleForPlayer
    end

    local notifyCalls = {}
    local alertDialogResponse = 'confirm'
    local alertDialogCalls = {}
    local callbackAwaitBehavior = { ok = true, isPartnered = false, partnerServerId = nil, isK9 = nil }
    local callbackAwaitCalls = {}
    local lib = {
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
        alertDialog = function(payload)
            alertDialogCalls[#alertDialogCalls + 1] = payload
            return alertDialogResponse
        end,
        callback = {
            await = function(name, ...)
                callbackAwaitCalls[#callbackAwaitCalls + 1] = { name = name, ... }
                if not callbackAwaitBehavior.ok then
                    error('simulated lib.callback.await rejection/timeout', 0)
                end
                return callbackAwaitBehavior.isPartnered, callbackAwaitBehavior.partnerServerId, callbackAwaitBehavior.isK9
            end,
        },
    }

    local serverEvents = {}
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { event = eventName, args = { ... } }
    end

    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local threadCount = 0
    local function CreateThread(_fn) threadCount = threadCount + 1 end

    local playerIndexByServerId = {}
    local function GetPlayerFromServerId(serverId) return playerIndexByServerId[serverId] or -1 end
    local function GetPlayerName(playerIndex) return 'Player#' .. tostring(playerIndex) end

    -- ---- K9Compat -- direct stub, see this file's header ----
    local addGlobalPlayerCalls = {}
    local K9Compat = {
        Get = function(_system)
            return {
                AddGlobalPlayer = function(options) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = options end,
            }
        end,
        Redetect = function() end,
        Which = function(_system) return 'ox_target' end,
    }

    local myPlayerId = 1
    local otherPlayerIndex = 7
    local function PlayerId() return myPlayerId end
    local function NetworkGetPlayerIndexFromPed(entity)
        if entity == 999 then return otherPlayerIndex end
        return -1
    end
    local function GetPlayerServerId(playerIndex) return playerIndex == otherPlayerIndex and 55 or -1 end
    -- Direct, controllable stand-in for client/main.lua's cross-file
    -- ResolvePlayerServerIdFromPed -- this spec tests client/partnership.lua,
    -- not client/main.lua's own resolve sequence (already covered
    -- elsewhere), matching this suite's established convention.
    local function ResolvePlayerServerIdFromPed(entity)
        local playerIndex = NetworkGetPlayerIndexFromPed(entity)
        if playerIndex == -1 then return nil end
        local serverId = GetPlayerServerId(playerIndex)
        if serverId == -1 then return nil end
        return serverId
    end

    local config = {
        Features = { HandlerPartnership = opts.handlerPartnership ~= false },
        Partnership = { ProximityMeters = 5.0 },
    }

    local env = Sandbox.newEnv({
        Config = config,
        IsOwnModelK9 = IsOwnModelK9,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        IsEntityModelK9 = IsEntityModelK9,
        IsK9RoleForPlayer = IsK9RoleForPlayer,
        lib = lib,
        TriggerServerEvent = TriggerServerEvent,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        CreateThread = CreateThread,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerName = GetPlayerName,
        K9Compat = K9Compat,
        PlayerId = PlayerId,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        GetPlayerServerId = GetPlayerServerId,
        ResolvePlayerServerIdFromPed = ResolvePlayerServerIdFromPed,
        GetCurrentResourceName = function() return RESOURCE_NAME end,
        -- Menu-parity pass (this session): client/partnership.lua now also
        -- registers a 'k9partner' chat command (RegisterCommand) alongside
        -- its existing ox_target option / resource-globals -- a plain no-op
        -- stub, same shape as every other fixture in this suite that loads a
        -- production file registering a command it does not itself need to
        -- exercise.
        RegisterCommand = function(_name, _handler, _restricted) end,
    })

    Sandbox.loadInto('../client/partnership.lua', env)

    return {
        env = env,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        alertDialogCalls = alertDialogCalls,
        setAlertDialogResponse = function(v) alertDialogResponse = v end,
        callbackAwaitCalls = callbackAwaitCalls,
        setCallbackAwaitBehavior = function(v) callbackAwaitBehavior = v end,
        serverEvents = serverEvents,
        lastServerEvent = function() return serverEvents[#serverEvents] end,
        netEventNames = netEvents,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEvents) do n = n + 1 end
            return n
        end,
        threadCount = function() return threadCount end,
        onResourceStartHandlerCount = function() return #(eventHandlers['onResourceStart'] or {}) end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        addGlobalPlayerCalls = addGlobalPlayerCalls,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        denyCallCount = function() return denyCalls end,
        setIsEntityModelK9 = function(v) isEntityModelK9 = v end,
        setIsK9RoleForPlayer = function(v) isK9RoleForPlayer = v end,
        isK9RoleForPlayerCalls = isK9RoleForPlayerCalls,
        registerPlayer = function(serverId, playerIndex) playerIndexByServerId[serverId] = playerIndex end,
        --- Invokes a captured `qbx_k9unit:client:*` handler directly --
        --- never yields, see this file's own header for why no coroutine
        --- wrapper is needed here.
        dispatchNetEvent = function(eventName, sourceValue, ...)
            local handler = assert(netEvents[eventName], 'no handler registered for ' .. eventName)
            env.source = sourceValue
            handler(...)
        end,
    }
end

-- ========================================================================
-- Feature off: this file HAS a real top-of-file
-- `if not Config.Features.HandlerPartnership then return end` gate -- see
-- this file's own header block ("A file-wide top gate is the concrete fix
-- for the exact gap a red-team pass just found in client/combat.lua").
-- Genuinely inert, provably, not just claimed.
-- ========================================================================

t.test('feature off: no globals, no net events, no thread, no onResourceStart handler', function()
    local f = newPartnershipFixture({ handlerPartnership = false })
    t.isNil(f.env.IsPartnered)
    t.isNil(f.env.GetPartnerServerId)
    t.isNil(f.env.RefreshPartnershipStateFromServer)
    t.isNil(f.env.RequestPartnerUp)
    t.isNil(f.env.BreakPartnership)
    t.equals(f.netEventCount(), 0)
    t.equals(f.threadCount(), 0)
    t.equals(f.onResourceStartHandlerCount(), 0)
end)

-- ========================================================================
-- Sanity + no onResourceStop -- see this file's header "TERMINATION MUST
-- NEVER BE GATED": a partnership is DB-backed, server-side state, with no
-- native/physical client-side effect to clean up, so THIS file (unlike
-- kennel/fetch/propattachment/vehicle) has no onResourceStop handler at
-- all -- pinned explicitly, not left untested by omission.
-- ========================================================================

t.test('feature on: exposes all five documented resource-globals, registers exactly 3 net events, 1 onResourceStart handler, ZERO onResourceStop handlers and ZERO threads', function()
    local f = newPartnershipFixture()
    t.isNotNil(f.env.IsPartnered)
    t.isNotNil(f.env.GetPartnerServerId)
    t.isNotNil(f.env.RefreshPartnershipStateFromServer)
    t.isNotNil(f.env.RequestPartnerUp)
    t.isNotNil(f.env.BreakPartnership)
    t.equals(f.netEventCount(), 3)
    t.isNotNil(f.netEventNames['qbx_k9unit:client:partnerUpRequest'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:partnershipEstablished'])
    t.isNotNil(f.netEventNames['qbx_k9unit:client:partnershipEnded'])
    t.equals(f.onResourceStartHandlerCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 0, 'no native/physical state to clean up on a restart -- see this file\'s own header')
    t.equals(f.threadCount(), 0)
    t.isFalse(f.env.IsPartnered())
    t.isNil(f.env.GetPartnerServerId())
end)

-- ========================================================================
-- RequestPartnerUp -- the asymmetric K9-role-vs-officer-role gate this
-- pass's own header documents as a real, previously-shipped bug fix.
-- ========================================================================

t.test('RequestPartnerUp: K9-role initiator (IsOwnModelK9 true) BLOCKED locally when CanShowK9UI is false', function()
    local f = newPartnershipFixture()
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(false)
    f.env.RequestPartnerUp(999)
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.serverEvents, 0)
end)

t.test('RequestPartnerUp: K9-role initiator with CanShowK9UI true reaches the server', function()
    local f = newPartnershipFixture()
    f.setIsOwnModelK9(true)
    f.setCanShowK9UI(true)
    f.env.RequestPartnerUp(42)
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPartnerUp')
    t.equals(f.lastServerEvent().args[1], 42)
end)

t.test('THE REGRESSION FIX: an officer-role initiator (IsOwnModelK9 false) reaches the server even with CanShowK9UI false, and CanShowK9UI is never even consulted', function()
    local f = newPartnershipFixture()
    f.setIsOwnModelK9(false)
    f.setCanShowK9UI(false) -- would have wrongly blocked under the pre-fix unconditional gate
    f.env.RequestPartnerUp(7)
    t.equals(#f.serverEvents, 1, 'an officer-initiated Partner Up request must reach the server')
    t.equals(f.denyCallCount(), 0)
end)

-- ========================================================================
-- TogglePartnership -- the ONE action behind /k9partner, the radial item and
-- the tablet button. Asks the server first, then breaks or partners up.
-- ========================================================================

t.test('TogglePartnership: the server says partnered -> breaks it, even with the local cache empty (the reconnect case) and with no K9 access', function()
    local f = newPartnershipFixture()
    f.setCanShowK9UI(false)
    f.setCallbackAwaitBehavior({ ok = true, isPartnered = true, partnerServerId = 55, isK9 = false })
    t.isFalse(f.env.IsPartnered(), 'sanity: the local cache starts empty, as after a reconnect')

    t.isTrue(f.env.TogglePartnership())

    t.equals(f.callbackAwaitCalls[1].name, 'qbx_k9unit:server:getPartnershipState', 'the server was asked first')
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:breakPartnership')
    t.equals(f.denyCallCount(), 0, 'breaking is never gated')
end)

t.test('TogglePartnership: not partnered -> partner up with the nearest player', function()
    local f = newPartnershipFixture()
    f.setCallbackAwaitBehavior({ ok = true, isPartnered = false })
    f.env.FindNearestPartnerCandidate = function() return 55 end

    t.isTrue(f.env.TogglePartnership())

    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPartnerUp')
    t.equals(f.lastServerEvent().args[1], 55)
end)

t.test('TogglePartnership: not partnered and nobody nearby -> says so, sends nothing', function()
    local f = newPartnershipFixture()
    f.setCallbackAwaitBehavior({ ok = true, isPartnered = false })
    f.env.FindNearestPartnerCandidate = function() return nil end
    local before = #f.serverEvents

    local acted = f.env.TogglePartnership()

    t.isFalse(acted)
    t.equals(#f.serverEvents, before)
    t.equals(f.lastNotify().description, locale('radial.no_partner_candidate'))
end)

t.test('TogglePartnership: not partnered and no K9 access -> refused before looking for anyone', function()
    local f = newPartnershipFixture()
    f.setCanShowK9UI(false)
    f.setCallbackAwaitBehavior({ ok = true, isPartnered = false })
    local looked = false
    f.env.FindNearestPartnerCandidate = function() looked = true; return 55 end

    t.isFalse(f.env.TogglePartnership())
    t.equals(f.denyCallCount(), 1)
    t.isFalse(looked)
end)

t.test('RequestPartnerUp: already partnered blocks locally with a notify, no server contact, regardless of which side initiated', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    t.isTrue(f.env.IsPartnered())

    f.setIsOwnModelK9(true)
    f.env.RequestPartnerUp(999)
    t.equals(#f.serverEvents, 0)
    t.equals(f.lastNotify().description, locale('partnership.already_partnered'))
    t.equals(f.lastNotify().type, 'error')
end)

-- ========================================================================
-- BreakPartnership -- TERMINATION MUST NEVER BE GATED. No CanShowK9UI()
-- check, no local IsPartnered() pre-check -- see this file's own header for
-- exactly why the pre-check is deliberately absent here (unlike
-- DetachLeash's own local IsLeashed() pre-check).
-- ========================================================================

t.test('BreakPartnership: sends unconditionally -- no access gate, and no local IsPartnered() pre-check either', function()
    local f = newPartnershipFixture()
    f.setCanShowK9UI(false)
    f.env.BreakPartnership() -- never even partnered
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:breakPartnership')
    t.equals(#f.lastServerEvent().args, 0, 'no client-claimed identifier of any kind -- the server resolves from `source`')
    t.equals(f.denyCallCount(), 0, 'BreakPartnership must never call DenyK9UIAccess')
end)

t.test('BreakPartnership: sends even while genuinely partnered, still unconditionally', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.env.BreakPartnership()
    t.equals(#f.serverEvents, 1)
end)

-- ========================================================================
-- partnerUpRequest (consent prompt, target side)
-- ========================================================================

t.test('partnerUpRequest: source guard rejects a forged local trigger -- no prompt, no relay', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnerUpRequest', 1, 10)
    t.equals(#f.alertDialogCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('partnerUpRequest: shows the prompt with the real player name when resolvable, and relays acceptance', function()
    local f = newPartnershipFixture()
    f.registerPlayer(10, 3)
    f.setAlertDialogResponse('confirm')
    f.dispatchNetEvent('qbx_k9unit:client:partnerUpRequest', 65535, 10)
    t.equals(#f.alertDialogCalls, 1)
    t.equals(f.alertDialogCalls[1].content, locale('partnership.partner_request_content', 'Player#3'))
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:respondPartnerUp')
    t.equals(f.lastServerEvent().args[1], 10)
    t.equals(f.lastServerEvent().args[2], true)
end)

t.test('partnerUpRequest: falls back to the "Officer #N" name when the sender is not resolvable, and relays a decline as accepted=false', function()
    local f = newPartnershipFixture()
    f.setAlertDialogResponse('cancel')
    f.dispatchNetEvent('qbx_k9unit:client:partnerUpRequest', 65535, 999)
    t.equals(f.alertDialogCalls[1].content, locale('partnership.partner_request_content', locale('movement.officer_fallback_name', 999)))
    t.equals(f.lastServerEvent().args[2], false)
end)

-- ========================================================================
-- partnershipEstablished -- sets PartnershipState from server-authoritative
-- truth, with a DIFFERENT notify text depending on WHICH role this client
-- holds (isK9 describes the PARTNER's role, not this client's own -- see
-- this file's own locale key naming).
-- ========================================================================

t.test('partnershipEstablished: source guard rejects a forged local trigger', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 1, 10, true)
    t.isFalse(f.env.IsPartnered())
    t.equals(#f.notifyCalls, 0)
end)

t.test('partnershipEstablished: isK9=true (this client IS the K9, partner is the handler) shows the "partnered with your handler" text', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    t.isTrue(f.env.IsPartnered())
    t.equals(f.env.GetPartnerServerId(), 55)
    t.equals(f.lastNotify().description, locale('partnership.now_partnered_as_handler'))
    t.equals(f.lastNotify().type, 'success')
end)

t.test('partnershipEstablished: isK9=false (this client is the handler, partner is the K9) shows the "partnered with your K9" text', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, false)
    t.equals(f.lastNotify().description, locale('partnership.now_partnered_as_k9'))
end)

-- ========================================================================
-- partnershipEnded
-- ========================================================================

t.test('partnershipEnded: source guard rejects a forged local trigger -- PartnershipState survives untouched', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 1, 'broken')
    t.isTrue(f.env.IsPartnered(), 'a forged local trigger must never desync PartnershipState from server truth')
end)

t.test('partnershipEnded: reason="broken" (self-initiated) shows the generic ended message', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'broken')
    t.isFalse(f.env.IsPartnered())
    t.equals(f.lastNotify().description, locale('partnership.ended_generic'))
end)

t.test('partnershipEnded: a known server-triggered reason shows its OWN dedicated sentence, never the raw internal tag', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'certification_revoked')
    t.equals(f.lastNotify().description, locale('partnership.ended_certification_revoked'))
    -- WORKFLOW CLARITY FIX regression guard: this used to be
    -- locale('partnership.ended_with_reason', 'certification_revoked'),
    -- i.e. the literal string "Partnership ended (certification_revoked)."
    -- shown to a real player. Confirm that raw tag never appears in the
    -- rendered text, whichever wording the dedicated sentence above uses.
    t.isNil(f.lastNotify().description:find('certification_revoked', 1, true),
        'the raw internal reason tag must never leak into player-facing text')
end)

t.test('partnershipEnded: department_changed shows its own sentence', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'department_changed')
    t.equals(f.lastNotify().description, locale('partnership.ended_department_changed'))
end)

t.test('partnershipEnded: k9_access_lost and k9_access_revoked share the same dedicated sentence', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'k9_access_lost')
    t.equals(f.lastNotify().description, locale('partnership.ended_k9_access_lost'))

    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'k9_access_revoked')
    t.equals(f.lastNotify().description, locale('partnership.ended_k9_access_lost'))
end)

t.test('partnershipEnded: admin_forced_from_tablet (server/tablet.lua CALLBACK 9) shows its own sentence', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'admin_forced_from_tablet')
    t.equals(f.lastNotify().description, locale('partnership.ended_admin_action'))
end)

t.test('partnershipEnded: an unrecognized future reason degrades to the plain generic message, never the raw tag', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEnded', 65535, 'some_future_reason_this_file_does_not_know_yet')
    t.equals(f.lastNotify().description, locale('partnership.ended_generic'))
end)

-- ========================================================================
-- RefreshPartnershipStateFromServer -- the fix for the KNOWN
-- CACHE-STALENESS GAP this file's own header documents at length.
-- ========================================================================

t.test('RefreshPartnershipStateFromServer: re-syncs from a genuinely fresh server answer, overwriting a stale LOCAL "not partnered" cache', function()
    local f = newPartnershipFixture()
    t.isFalse(f.env.IsPartnered(), 'sanity: local cache starts unpartnered, as if freshly reconnected')

    f.setCallbackAwaitBehavior({ ok = true, isPartnered = true, partnerServerId = 55, isK9 = true })
    local isPartneredNow, partnerServerId = f.env.RefreshPartnershipStateFromServer()
    t.isTrue(isPartneredNow, 'THE FIX: the stale local cache must not be trusted -- the server\'s own fresh answer wins')
    t.equals(partnerServerId, 55)
    t.isTrue(f.env.IsPartnered())
    t.equals(f.env.GetPartnerServerId(), 55)
end)

t.test('RefreshPartnershipStateFromServer: a genuinely fresh "not partnered" answer overwrites a STALE local "partnered" cache too (both directions)', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    t.isTrue(f.env.IsPartnered())

    f.setCallbackAwaitBehavior({ ok = true, isPartnered = false })
    local isPartneredNow, partnerServerId = f.env.RefreshPartnershipStateFromServer()
    t.isFalse(isPartneredNow)
    t.isNil(partnerServerId)
    t.isFalse(f.env.IsPartnered())
end)

t.test('RefreshPartnershipStateFromServer: FAIL-CLOSED GUARD -- a throwing lib.callback.await (timeout/cb_invalid) is treated as "not partnered", never lets the throw escape', function()
    local f = newPartnershipFixture()
    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    f.setCallbackAwaitBehavior({ ok = false })

    local ok, isPartneredNow, partnerServerId = pcall(f.env.RefreshPartnershipStateFromServer)
    t.isTrue(ok, 'a throwing lib.callback.await must never propagate out of this function')
    t.isFalse(isPartneredNow)
    t.isNil(partnerServerId)
    t.isFalse(f.env.IsPartnered(), 'a fail-closed guard must not leave a stale PARTNERED cache in place either')
end)

-- ========================================================================
-- ANY PED -- the "Partner Up" ox_target predicate must offer a K9-ROLE
-- HOLDER on a human/custom body, not just an entity that already looks
-- dog-shaped -- see this file's own "WIDENED" comment.
-- ========================================================================

t.test('ANY PED: canInteract offers the option via IsK9RoleForPlayer() alone, when NEITHER side already looks like a K9 by model', function()
    local f = newPartnershipFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local option = f.addGlobalPlayerCalls[1][1]
    t.equals(option.name, 'qbx_k9unit:partnerUp')

    f.setIsOwnModelK9(false)
    f.setIsEntityModelK9(false)
    f.setIsK9RoleForPlayer(true)
    t.isTrue(option.canInteract(999, 1.0, {}, 'x'), 'a role-holder on a non-K9 body must still be offered as a valid partner')
end)

t.test('ANY PED: canInteract still refuses when NONE of the three conditions hold', function()
    local f = newPartnershipFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local option = f.addGlobalPlayerCalls[1][1]

    f.setIsOwnModelK9(false)
    f.setIsEntityModelK9(false)
    f.setIsK9RoleForPlayer(false)
    t.isFalse(option.canInteract(999, 1.0, {}, 'x'))
end)

t.test('canInteract: IsK9RoleForPlayer is short-circuited (never called) once IsOwnModelK9() already answers true -- Lua\'s `or` short-circuits, avoiding an unnecessary network round trip', function()
    local f = newPartnershipFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local option = f.addGlobalPlayerCalls[1][1]

    f.setIsOwnModelK9(true)
    option.canInteract(999, 1.0, {}, 'x')
    t.equals(#f.isK9RoleForPlayerCalls, 0)
end)

t.test('canInteract: already partnered or targeting self both hide the option regardless of role/model', function()
    local f = newPartnershipFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local option = f.addGlobalPlayerCalls[1][1]
    f.setIsOwnModelK9(true)

    t.isTrue(option.canInteract(999, 1.0, {}, 'x'), 'sanity: offered before partnering')

    f.dispatchNetEvent('qbx_k9unit:client:partnershipEstablished', 65535, 55, true)
    t.isFalse(option.canInteract(999, 1.0, {}, 'x'), 'must hide once already partnered')
end)

t.test('onSelect: resolves the targeted player and calls RequestPartnerUp with their real server id', function()
    local f = newPartnershipFixture()
    f.fireResourceStart(RESOURCE_NAME)
    local option = f.addGlobalPlayerCalls[1][1]
    f.setIsOwnModelK9(false) -- officer-initiated, reaches the server unconditionally

    option.onSelect({ entity = 999 })
    t.equals(#f.serverEvents, 1)
    t.equals(f.lastServerEvent().event, 'qbx_k9unit:server:requestPartnerUp')
    t.equals(f.lastServerEvent().args[1], 55)
end)

-- ========================================================================
-- DOUBLE-FIRE / RE-ENTRANCY
-- ========================================================================

t.test('RequestPartnerUp: two rapid calls both reach the server -- no client-side in-flight guard (only the local IsPartnered() cache, which is not yet true immediately after sending)', function()
    local f = newPartnershipFixture()
    f.setIsOwnModelK9(false)
    f.env.RequestPartnerUp(7)
    f.env.RequestPartnerUp(7)
    t.equals(#f.serverEvents, 2, 'server/partnership.lua\'s own CheckPartnershipEligibility is the real authority that must reject a duplicate request')
end)

t.test('BreakPartnership: double-fire sends two independent events, exactly like RequestRecall -- a termination path must never itself throttle', function()
    local f = newPartnershipFixture()
    f.env.BreakPartnership()
    f.env.BreakPartnership()
    t.equals(#f.serverEvents, 2)
end)

os.exit(t.summary())
