--[[
    tests/clientappearance_spec.lua

    Direct, black-box tests of client/appearance.lua against the REAL,
    unmodified production file -- the client half of the K9 role/ped-model
    decoupling (see server/appearance.lua's header for the full design).

    THREE of the FOUR load-bearing cases this task named live here (the
    fourth, "a human ped CAN hold the role", is a server-side/role-check
    concern and lives in tests/appearance_spec.lua):
      - "a client cannot self-assign" is reinforced here too: this file's
        ONLY entry point that changes a model, the 'john-k9:client:applyK9Ped'
        handler, is entirely SERVER-DRIVEN (RegisterNetEvent, source-origin
        guarded) -- there is no client-callable function anywhere in this
        file that a local script could invoke to assign itself the role.
      - "a failed model load leaves the player untouched" -- the TIMEOUT
        section below: SetPlayerModel is never called when HasModelLoaded
        never returns true within Config.K9Appearance.modelLoadTimeoutMs.
      - "revoke restores the original appearance" -- the REVERT section:
        the same handler accepts a raw numeric HASH (not just a model
        NAME) for exactly this path, and applies it identically.

    STUBBING EFFORT, reported honestly per this task's own instruction: the
    RequestModel/HasModelLoaded polling loop (LoadModelWithTimeout) is a
    plain, non-coroutine `while ... do Wait(50) end` loop that runs
    synchronously to completion inside ONE call to the captured
    'john-k9:client:applyK9Ped' handler -- unlike client/vision.lua's
    maintenance thread or a CreateThread-based sweep, this needs no
    coroutine/thread-runner simulation at all; Wait is a plain counting
    no-op stub, and the loop's own natural termination condition
    (HasModelLoaded flipping true, or the elapsed-time ceiling) drives the
    test directly.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param opts table? -- { modelLoadTimeoutMs: number? }
local function newFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    -- ox_lib lib.callback.await stub -- a FIFO queue of canned responses
    -- PLUS a call log, mirroring tests/main_spec.lua's own established
    -- HasK9Access fixture shape (the throw-modeling reasoning there is not
    -- re-derived here; see that file for the full citation against real
    -- ox_lib/FiveM source).
    local ThrowMarkerMT = {}
    local function callbackThrow(message) return setmetatable({ message = message }, ThrowMarkerMT) end
    local roleCallbackQueue = {}
    local roleCallbackCallCount = 0
    local roleForTargetCallbackQueue = {}
    local roleForTargetCallCount = 0
    -- K9 IDENTITY (THIS PASS) -- same FIFO-queue-plus-call-count shape as
    -- the two queues above, backing the new 'john-k9:server:k9Identity'
    -- callback client/appearance.lua's "Identify K9" onSelect handler
    -- awaits.
    local identityCallbackQueue = {}
    local identityCallCount = 0
    local identityCallArgs = {} -- [n] = targetServerId, one entry per call, in order

    local function lib_callback_await(name, ...)
        if name == 'john-k9:server:hasK9Role' then
            roleCallbackCallCount = roleCallbackCallCount + 1
            local response = table.remove(roleCallbackQueue, 1)
            if getmetatable(response) == ThrowMarkerMT then error(response.message, 0) end
            return response
        elseif name == 'john-k9:server:isK9RoleForTarget' then
            roleForTargetCallCount = roleForTargetCallCount + 1
            local response = table.remove(roleForTargetCallbackQueue, 1)
            if getmetatable(response) == ThrowMarkerMT then error(response.message, 0) end
            return response
        elseif name == 'john-k9:server:k9Identity' then
            identityCallCount = identityCallCount + 1
            -- lib.callback.await(name, false, targetServerId) -- the SECOND
            -- vararg is the real payload (ox_lib's own "no timeout override"
            -- convention, same shape as the two branches above), so this is
            -- select(2, ...), not select(1, ...).
            identityCallArgs[#identityCallArgs + 1] = select(2, ...)
            local response = table.remove(identityCallbackQueue, 1)
            if getmetatable(response) == ThrowMarkerMT then error(response.message, 0) end
            return response
        end
        error('unstubbed lib.callback.await in clientappearance_spec fixture: ' .. tostring(name))
    end

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local serverEvents = {} -- { {eventName, ...}, ... }
    local function TriggerServerEvent(eventName, ...)
        serverEvents[#serverEvents + 1] = { eventName, ... }
    end

    -- Engaged-state stubs -- each independently settable, to prove the OR
    -- across all six (see client/appearance.lua's own IsCurrentlyEngaged
    -- doc comment for the full list/reasoning). CORRECTED this pass: this
    -- fixture used to stub only five of the six predicates -- missing
    -- IsPropAttachmentEngaged entirely (added to production per that file's
    -- own "CLOSED GAP" header note, but never given fixture coverage here),
    -- silently leaving that sixth engagement source untested this whole
    -- time.
    local engaged = {}
    local function IsLeashed() return engaged.leashed == true end
    local function IsBiteHoldEngaged() return engaged.biteHold == true end
    local function IsDragEngaged() return engaged.drag == true end
    local function IsFetchCarryEngaged() return engaged.fetchCarry == true end
    local function IsInK9Vehicle() return engaged.vehicle == true end
    local function IsPropAttachmentEngaged() return engaged.propAttachment == true end
    -- TARGET-SIDE ADDITIONS (this pass) -- see client/appearance.lua's own
    -- IsCurrentlyEngaged() doc comment for the full "none of the six above
    -- ever asked whether this ped is the TARGET of something" writeup.
    -- IsBiteHoldTargetEngaged is stubbed here even though client/combat.lua
    -- does not define it yet in production (it is a `type(fn) == 'function'`
    -- PENDING call site there, same precedent as .luacheckrc's own
    -- ForceRevertK9Appearance entry) -- this fixture proves
    -- client/appearance.lua's OWN call site reacts correctly the moment that
    -- global exists, independent of when client/combat.lua actually lands
    -- it.
    local function IsDragTargetEngaged() return engaged.dragTarget == true end
    local function IsLocalPlayerForceRagdolled() return engaged.forceRagdolled == true end
    local function IsBiteHoldTargetEngaged() return engaged.biteHoldTarget == true end
    local function IsRestingInKennel() return engaged.restingInKennel == true end

    -- K9 IDENTITY (THIS PASS) -- client/appearance.lua's new "Identify K9"
    -- ox_target(-equivalent) registration needs AddEventHandler (the
    -- 'onResourceStart' lifecycle hook, same pattern client/wellbeing.lua's
    -- RegisterMoodOxTargetOptions already established -- see that file's
    -- own comment), GetCurrentResourceName (to recognise "this resource
    -- just started" as the sole unconditional trigger), a K9Compat stub
    -- (captures the ONE AddGlobalPlayer call this registration makes,
    -- close enough to shared/compat/target.lua's real
    -- K9Compat.Get('target').AddGlobalPlayer(options) shape for this
    -- file's own call site), lib.notify (captures what "Identify K9"'s
    -- onSelect actually shows), and IsEntityModelK9/
    -- ResolvePlayerServerIdFromPed -- both REAL resource-globals from
    -- client/main.lua in production (not this file), independently
    -- settable stand-ins here exactly like every other externally-owned
    -- predicate this fixture already stubs (IsLeashed, IsBiteHoldEngaged,
    -- etc., all above).
    local capturedEventHandlers = {} -- [name] = { fn, fn, ... }, ALL handlers for that name, in registration order
    local function AddEventHandler(name, fn)
        capturedEventHandlers[name] = capturedEventHandlers[name] or {}
        capturedEventHandlers[name][#capturedEventHandlers[name] + 1] = fn
    end

    local CURRENT_RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return CURRENT_RESOURCE_NAME end

    local targetAddGlobalPlayerCalls = {} -- [n] = options table passed to AddGlobalPlayer
    local k9CompatWhichTarget = 'ox_target'
    local K9Compat = {
        Get = function(systemName)
            if systemName ~= 'target' then
                error('unstubbed K9Compat.Get in clientappearance_spec fixture: ' .. tostring(systemName))
            end
            return {
                AddGlobalPlayer = function(options)
                    targetAddGlobalPlayerCalls[#targetAddGlobalPlayerCalls + 1] = options
                    return { kind = 'player' }
                end,
            }
        end,
        Redetect = function() end,
        Which = function(systemName)
            if systemName == 'target' then return k9CompatWhichTarget end
            return nil
        end,
    }

    local notifyCalls = {}
    local function libNotify(payload) notifyCalls[#notifyCalls + 1] = payload end

    local entityModelK9 = {}         -- [entity] = true/false
    local function IsEntityModelK9(entity) return entityModelK9[entity] == true end

    local playerServerIdByEntity = {} -- [entity] = serverId or nil
    local function ResolvePlayerServerIdFromPed(entity) return playerServerIdByEntity[entity] end

    -- RequestModel/HasModelLoaded/SetModelAsNoLongerNeeded/IsModelValid --
    -- same shape as tests covering client/kennel.lua's identical
    -- LoadModelWithTimeout pattern would need, but no existing spec in
    -- this suite happened to cover that pattern yet; built fresh here,
    -- following client/kennel.lua's own production shape exactly.
    local requestModelCalls = {}
    local releaseModelCalls = {}
    local modelLoadedHashes = {} -- [hash] = true once "loaded"
    local invalidHashes = {}     -- [hash] = true -- IsModelValid returns false for these
    local function RequestModel(hash) requestModelCalls[#requestModelCalls + 1] = hash end
    local function HasModelLoaded(hash) return modelLoadedHashes[hash] == true end
    local function SetModelAsNoLongerNeeded(hash) releaseModelCalls[#releaseModelCalls + 1] = hash end
    local function IsModelValid(hash) return invalidHashes[hash] ~= true end

    local waitCalls = 0
    local function Wait(_ms) waitCalls = waitCalls + 1 end

    -- The swapped ped, and what it currently looks like. SetPlayerModel
    -- moves `currentPedModel`, mirroring the real native's observable
    -- effect, so GetEntityModel below can answer honestly for the
    -- next-frame re-apply's own guard.
    local LOCAL_PED = 4242
    local currentPedModel = 'HASH(a_m_m_business_01)'
    local defaultComponentVariationCalls = {}

    local setPlayerModelCalls = {}
    local function SetPlayerModel(playerId, hash)
        setPlayerModelCalls[#setPlayerModelCalls + 1] = { playerId = playerId, hash = hash }
        currentPedModel = hash
    end
    local function PlayerPedId() return LOCAL_PED end
    local function GetEntityModel(ped) return ped == LOCAL_PED and currentPedModel or nil end
    local function SetPedDefaultComponentVariation(ped)
        defaultComponentVariationCalls[#defaultComponentVariationCalls + 1] = ped
    end

    -- Deferred bodies are collected rather than run, so a test decides when
    -- the "next frame" happens (f.runPendingThreads()) and can assert on
    -- what the world looked like before AND after it.
    local pendingThreads = {}
    local function CreateThread(fn) pendingThreads[#pendingThreads + 1] = fn end

    local function PlayerId() return 0 end -- FiveM's own local-player index; irrelevant which literal, only that it's passed through
    local function GetHashKey(name) return 'HASH(' .. name .. ')' end -- deliberately NOT a real hash algorithm -- only used to prove name-vs-number handling, never compared against a real game hash

    local Config = {
        K9Appearance = {
            modelLoadTimeoutMs = opts.modelLoadTimeoutMs or 5000,
        },
        -- K9 IDENTITY (THIS PASS) -- defaults match config.lua's own
        -- shipped defaults; `opts.k9Identity` lets a test override either
        -- field (see the "switched off" test below).
        K9Identity = {
            enabled = (opts.k9Identity and opts.k9Identity.enabled) ~= false,
            showHandlerName = (opts.k9Identity and opts.k9Identity.showHandlerName) ~= false,
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        lib = { callback = { await = lib_callback_await }, notify = libNotify },
        RegisterNetEvent = RegisterNetEvent,
        TriggerServerEvent = TriggerServerEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        K9Compat = K9Compat,
        IsEntityModelK9 = IsEntityModelK9,
        ResolvePlayerServerIdFromPed = ResolvePlayerServerIdFromPed,
        IsLeashed = IsLeashed,
        IsBiteHoldEngaged = IsBiteHoldEngaged,
        IsDragEngaged = IsDragEngaged,
        IsFetchCarryEngaged = IsFetchCarryEngaged,
        IsInK9Vehicle = IsInK9Vehicle,
        IsPropAttachmentEngaged = IsPropAttachmentEngaged,
        IsDragTargetEngaged = IsDragTargetEngaged,
        IsLocalPlayerForceRagdolled = IsLocalPlayerForceRagdolled,
        IsBiteHoldTargetEngaged = IsBiteHoldTargetEngaged,
        IsRestingInKennel = IsRestingInKennel,
        RequestModel = RequestModel,
        HasModelLoaded = HasModelLoaded,
        SetModelAsNoLongerNeeded = SetModelAsNoLongerNeeded,
        IsModelValid = IsModelValid,
        Wait = Wait,
        SetPlayerModel = SetPlayerModel,
        PlayerPedId = PlayerPedId,
        GetEntityModel = GetEntityModel,
        SetPedDefaultComponentVariation = SetPedDefaultComponentVariation,
        CreateThread = CreateThread,
        PlayerId = PlayerId,
        GetHashKey = GetHashKey,
        Config = Config,
    })

    Sandbox.loadInto('../client/appearance.lua', env)

    return {
        env = env,
        events = capturedEvents,
        serverEvents = serverEvents,
        defaultComponentVariationCalls = defaultComponentVariationCalls,
        runPendingThreads = function()
            local queued = pendingThreads
            pendingThreads = {}
            for _, fn in ipairs(queued) do fn() end
        end,
        pendingThreadCount = function() return #pendingThreads end,
        setPedModel = function(hash) currentPedModel = hash end,
        localPed = function() return LOCAL_PED end,
        setNow = function(ms) fakeNow = ms end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        queueRoleResponse = function(v) roleCallbackQueue[#roleCallbackQueue + 1] = v end,
        queueRoleThrow = function(msg) roleCallbackQueue[#roleCallbackQueue + 1] = callbackThrow(msg or 'thrown') end,
        roleCallCount = function() return roleCallbackCallCount end,
        queueRoleForTargetResponse = function(v) roleForTargetCallbackQueue[#roleForTargetCallbackQueue + 1] = v end,
        queueRoleForTargetThrow = function(msg) roleForTargetCallbackQueue[#roleForTargetCallbackQueue + 1] = callbackThrow(msg or 'thrown') end,
        roleForTargetCallCount = function() return roleForTargetCallCount end,
        setEngaged = function(key, v) engaged[key] = v end,
        markModelLoaded = function(hash) modelLoadedHashes[hash] = true end,
        markModelInvalid = function(hash) invalidHashes[hash] = true end,
        requestModelCalls = requestModelCalls,
        releaseModelCalls = releaseModelCalls,
        setPlayerModelCalls = setPlayerModelCalls,
        waitCallCount = function() return waitCalls end,

        -- K9 IDENTITY (THIS PASS) --------------------------------------
        queueIdentityResponse = function(v) identityCallbackQueue[#identityCallbackQueue + 1] = v end,
        queueIdentityThrow = function(msg) identityCallbackQueue[#identityCallbackQueue + 1] = callbackThrow(msg or 'thrown') end,
        identityCallCount = function() return identityCallCount end,
        identityCallArgs = identityCallArgs,
        notifyCalls = notifyCalls,
        setEntityModelK9 = function(entity, v) entityModelK9[entity] = v end,
        setPlayerServerIdForEntity = function(entity, id) playerServerIdByEntity[entity] = id end,
        --- Fires the captured 'onResourceStart' handler(s) as if `resourceName`
        --- just started -- the ONLY way client/appearance.lua's new
        --- "Identify K9" registration actually runs (see that file's own
        --- section header: registration is deferred behind this event, never
        --- run at file-load time). Defaults to THIS resource's own name (the
        --- unconditional bootstrap trigger every real server also fires once
        --- at this resource's own startup).
        --- @param resourceName string?
        triggerResourceStart = function(resourceName)
            local handlers = capturedEventHandlers['onResourceStart']
            if not handlers then return end
            for _, fn in ipairs(handlers) do fn(resourceName or CURRENT_RESOURCE_NAME) end
        end,
        --- The single ox_target(-equivalent) option this pass's
        --- RegisterIdentityOxTargetOptions() registers, or nil if
        --- triggerResourceStart() was never called (or K9Compat.Get('target')
        --- was never reached for some other reason). AddGlobalPlayer is only
        --- ever called ONCE per registration pass in production, with an
        --- array of exactly one option -- indexed here accordingly rather
        --- than exposing the raw call log.
        --- @return table?
        identityTargetOption = function()
            local lastCall = targetAddGlobalPlayerCalls[#targetAddGlobalPlayerCalls]
            return lastCall and lastCall[1]
        end,
        targetAddGlobalPlayerCallCount = function() return #targetAddGlobalPlayerCalls end,
        setK9CompatWhichTarget = function(v) k9CompatWhichTarget = v end,
    }
end

-- ----------------------------------------------------------------------
-- IsK9Role() -- TTL debounce cache, same shape/TTL as client/main.lua's
-- own HasK9Access() -- see tests/main_spec.lua's own HasK9Access section
-- for the fuller worked example this mirrors.
-- ----------------------------------------------------------------------

local HAS_K9_ROLE_CACHE_TTL_MS = 1000 -- must match client/appearance.lua's own HAS_K9_ROLE_CACHE_TTL_MS

t.test('IsK9Role: a cold cache is a MISS -- awaits the real server callback', function()
    local f = newFixture()
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    t.equals(f.roleCallCount(), 1)
end)

t.test('IsK9Role: a second call at the SAME instant is a cache HIT -- no second round trip', function()
    local f = newFixture()
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    t.isTrue(f.env.IsK9Role())
    t.equals(f.roleCallCount(), 1, 'still cached -- the second call never touched the queue')
end)

t.test('IsK9Role: at exactly the TTL boundary the cache has EXPIRED -- a fresh round trip is made', function()
    local f = newFixture()
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    f.advance(HAS_K9_ROLE_CACHE_TTL_MS)
    f.queueRoleResponse(false)
    t.isFalse(f.env.IsK9Role(), 'the newly-queued response, proving a real re-check happened')
    t.equals(f.roleCallCount(), 2)
end)

t.test('IsK9Role: a callback THROW (timeout/unregistered) fails closed -- returns false, never lets the error escape, and does NOT poison the cache', function()
    local f = newFixture()
    f.queueRoleThrow()
    t.isFalse(f.env.IsK9Role())

    -- Immediately after, a SUCCEEDING call must re-attempt rather than
    -- serve a cached false for the full TTL -- see client/appearance.lua's
    -- own doc comment on why `checkedAt` is deliberately left untouched on
    -- the throw path.
    f.queueRoleResponse(true)
    t.isTrue(f.env.IsK9Role())
    t.equals(f.roleCallCount(), 2, 'the throw did not consume a cache window -- the very next call re-attempted immediately')
end)

-- ----------------------------------------------------------------------
-- IsK9RoleForPlayer(targetServerId) -- the "one real gap" primitive a peer
-- audit this pass flagged: per-TARGET TTL cache, same shape.
-- ----------------------------------------------------------------------

t.test('IsK9RoleForPlayer: awaits the server for a given target, caches per-target', function()
    local f = newFixture()
    f.queueRoleForTargetResponse(true)
    t.isTrue(f.env.IsK9RoleForPlayer(42))
    t.isTrue(f.env.IsK9RoleForPlayer(42))
    t.equals(f.roleForTargetCallCount(), 1, 'second call for the SAME target within the TTL is a cache hit')
end)

t.test('IsK9RoleForPlayer: a DIFFERENT target is not served from the first target\'s cache entry', function()
    local f = newFixture()
    f.queueRoleForTargetResponse(true)
    t.isTrue(f.env.IsK9RoleForPlayer(42))
    f.queueRoleForTargetResponse(false)
    t.isFalse(f.env.IsK9RoleForPlayer(99))
    t.equals(f.roleForTargetCallCount(), 2)
end)

t.test('IsK9RoleForPlayer: a non-number argument fails closed without ever touching the network', function()
    local f = newFixture()
    t.isFalse(f.env.IsK9RoleForPlayer('not-a-number'))
    t.equals(f.roleForTargetCallCount(), 0)
end)

t.test('IsK9RoleForPlayer: a resolved-nil response (not a throw) is treated as false, and IS cached like any other real answer', function()
    local f = newFixture()
    f.queueRoleForTargetResponse(nil)
    t.isFalse(f.env.IsK9RoleForPlayer(7))
    t.isFalse(f.env.IsK9RoleForPlayer(7))
    t.equals(f.roleForTargetCallCount(), 1, 'a genuine nil answer is cached exactly like `false` -- only a THROW skips caching')
end)

t.test('IsK9RoleForPlayer: a callback THROW fails closed, same as IsK9Role, and does NOT poison that target\'s cache', function()
    local f = newFixture()
    f.queueRoleForTargetThrow()
    t.isFalse(f.env.IsK9RoleForPlayer(7))

    f.queueRoleForTargetResponse(true)
    t.isTrue(f.env.IsK9RoleForPlayer(7), 'the throw did not consume a cache window -- the very next call re-attempted immediately')
    t.equals(f.roleForTargetCallCount(), 2)
end)

-- ----------------------------------------------------------------------
-- applyK9Ped -- SOURCE-ORIGIN GUARD. "A client cannot self-assign": this
-- handler is the ONLY place SetPlayerModel is ever called, and it is
-- entirely server-triggered.
-- ----------------------------------------------------------------------

t.test('applyK9Ped: a forged LOCAL trigger (source ~= 65535) is rejected outright -- no model requested, no confirm sent', function()
    local f = newFixture()
    f.env.source = 1 -- NOT the server sentinel
    f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.setPlayerModelCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('applyK9Ped: a genuine server-origin trigger (source == 65535) is processed', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_husky)')
    f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.setPlayerModelCalls, 1)
end)

-- ----------------------------------------------------------------------
-- "REFUSE, DON'T FORCE-CLEAR" -- engaged in ANY of the now TEN tracked
-- states refuses the swap outright, before RequestModel is ever called.
-- The last four (dragTarget/forceRagdolled/biteHoldTarget/restingInKennel)
-- are THIS PASS's own addition -- see client/appearance.lua's own
-- IsCurrentlyEngaged() doc comment "TARGET-SIDE ADDITIONS" section for why:
-- every one of the original six is HOLDER-side (or self-administered), and
-- none of them ever asked whether this ped is the TARGET of a bite hold/
-- drag/takedown someone ELSE's client is currently driving native calls
-- against, or is attached inside a kennel.
-- ----------------------------------------------------------------------

local ENGAGED_KEYS = {
    'leashed', 'biteHold', 'drag', 'fetchCarry', 'vehicle', 'propAttachment',
    'dragTarget', 'forceRagdolled', 'biteHoldTarget', 'restingInKennel',
}
for _, key in ipairs(ENGAGED_KEYS) do
    t.test(('applyK9Ped: refuses outright when engaged via %s -- no model ever requested, reports "engaged"'):format(key), function()
        local f = newFixture()
        f.env.source = 65535
        f.setEngaged(key, true)
        f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_husky')

        t.equals(#f.requestModelCalls, 0, 'never even attempted -- refuse, not force-clear')
        t.equals(#f.setPlayerModelCalls, 0)
        t.equals(#f.serverEvents, 1)
        t.equals(f.serverEvents[1][1], 'john-k9:server:confirmK9PedSwap')
        t.equals(f.serverEvents[1][3], false)
        t.equals(f.serverEvents[1][4], 'engaged')
    end)
end

t.test('applyK9Ped: not engaged in any tracked way -- proceeds normally', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_husky)')
    f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_husky')
    t.equals(#f.setPlayerModelCalls, 1)
end)

-- ----------------------------------------------------------------------
-- BUG (found + fixed this pass): the ORIGINAL IsCurrentlyEngaged() check
-- above only proves the ped was unengaged at the INSTANT this handler
-- started -- LoadModelWithTimeout's own Wait(50) polling loop can run for
-- however long the configured modelLoadTimeoutMs allows, and nothing
-- re-checked engagement after that wait before this pass's own fix. This
-- reproduces the race directly: the model loads successfully, but the
-- player becomes engaged (an independent action landing while this handler
-- was suspended, e.g. another player leashing this one) DURING the wait,
-- not before it.
-- ----------------------------------------------------------------------

t.test('BUG (found + fixed this pass): becoming engaged DURING the model-load wait (not before it started) still refuses the swap, releases the successfully-loaded model, and reports "engaged"', function()
    local f = newFixture()
    f.env.source = 65535

    -- Not engaged at dispatch time (the FIRST IsCurrentlyEngaged() check
    -- must pass, or this test would prove nothing about the SECOND,
    -- post-wait check this pass added). The model reports "still loading"
    -- for its first poll -- during which this fixture's own Wait stub flips
    -- the player LEASHED -- then "loaded" from the second poll onward.
    local pollCount = 0
    f.env.Wait = function(_ms)
        pollCount = pollCount + 1
        f.setEngaged('leashed', true) -- lands mid-wait, independent of this handler
        f.markModelLoaded('HASH(a_c_husky)')
    end

    f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.requestModelCalls, 1, 'the load was genuinely attempted -- this is not the "refused before RequestModel" path')
    t.equals(#f.setPlayerModelCalls, 0, 'FIXED: must NOT apply the swap -- the player became engaged during the wait, even though it started unengaged')
    t.equals(#f.releaseModelCalls, 1, 'the successfully-loaded model\'s streaming reference must still be released even though it ends up unused')
    t.equals(f.releaseModelCalls[1], 'HASH(a_c_husky)')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1][3], false)
    t.equals(f.serverEvents[1][4], 'engaged', 'reported the same way as the pre-existing "engaged at dispatch time" case, not "timeout" or a silent drop')
    t.isTrue(pollCount >= 1, 'sanity: the Wait stub above must have actually run for this test to prove anything')
end)

-- ----------------------------------------------------------------------
-- LOAD-BEARING CASE: a failed model load leaves the player untouched.
-- ----------------------------------------------------------------------

t.test('applyK9Ped: HasModelLoaded never flips true within modelLoadTimeoutMs -- ABANDONS the swap: SetPlayerModel is NEVER called, the model reference is released (leak fix), and the server is told "timeout"', function()
    local f = newFixture({ modelLoadTimeoutMs = 500 })
    f.env.source = 65535
    -- markModelLoaded is deliberately never called -- HasModelLoaded stays
    -- false for the entire polling window.
    f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_husky')

    t.equals(#f.setPlayerModelCalls, 0, 'the player is exactly as they were -- never half-applied')
    t.equals(#f.requestModelCalls, 1, 'the load WAS attempted')
    t.equals(#f.releaseModelCalls, 1, 'LEAK FIX: the streaming reference RequestModel incremented is released on the timeout exit path too')
    t.equals(f.releaseModelCalls[1], 'HASH(a_c_husky)')
    t.equals(#f.serverEvents, 1)
    t.equals(f.serverEvents[1][3], false)
    t.equals(f.serverEvents[1][4], 'timeout')
end)

t.test('applyK9Ped: an invalid/unrecognized model hash on THIS client is rejected immediately -- RequestModel is never even called (mirrors client/kennel.lua\'s identical guard)', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelInvalid('HASH(a_c_nonexistent)')
    f.events['john-k9:client:applyK9Ped']('req-1', 'a_c_nonexistent')

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.setPlayerModelCalls, 0)
    t.equals(f.serverEvents[1][4], 'timeout', 'LoadModelWithTimeout returns false uniformly for "invalid" and "never loaded" -- both are reported the same way upstream')
end)

-- ----------------------------------------------------------------------
-- SUCCESS PATH -- and the LOAD-BEARING revert case: a raw numeric HASH
-- (not a name) is accepted identically, exactly as server/appearance.lua
-- sends for a revert-to-original-model request.
-- ----------------------------------------------------------------------

t.test('applyK9Ped: success -- RequestModel is called with the resolved hash, SetPlayerModel is called with PlayerId() and that hash, the model reference is released, and the server is told ok=true', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['john-k9:client:applyK9Ped']('req-42', 'a_c_shepherd')

    t.equals(f.requestModelCalls[1], 'HASH(a_c_shepherd)')
    t.equals(#f.setPlayerModelCalls, 1)
    t.equals(f.setPlayerModelCalls[1].hash, 'HASH(a_c_shepherd)')
    t.equals(f.releaseModelCalls[1], 'HASH(a_c_shepherd)')
    t.equals(f.serverEvents[1][1], 'john-k9:server:confirmK9PedSwap')
    t.equals(f.serverEvents[1][2], 'req-42')
    t.equals(f.serverEvents[1][3], true)
end)

-- ----------------------------------------------------------------------
-- INVISIBLE-PED FIX. Reported from a live server: certifying somebody with
-- /k9certify "changes me to air". The swap fired, the dog model was right,
-- and nothing rendered at all.
--
-- SET_PLAYER_MODEL builds the new ped with NO component variation set. A
-- human ped mostly survives that; an animal ped does not, because every
-- part of the dog IS a component -- so a ped with none set has nothing to
-- draw. The player stands there, collides, can be targeted, and is
-- invisible to everyone including themselves.
-- ----------------------------------------------------------------------

t.test('INVISIBLE-PED FIX: a successful swap applies the default component variation to the new ped -- without it the dog renders as nothing at all', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['john-k9:client:applyK9Ped']('req-42', 'a_c_shepherd')

    t.equals(#f.defaultComponentVariationCalls, 1, 'the swap is not finished until the ped has something to draw')
    t.equals(f.defaultComponentVariationCalls[1], f.localPed())
end)

t.test('INVISIBLE-PED FIX: it is applied AGAIN on the next frame, since on some builds a ped is not fully built until the frame after the swap', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['john-k9:client:applyK9Ped']('req-42', 'a_c_shepherd')

    t.equals(f.pendingThreadCount(), 1, 'a next-frame re-apply must actually be scheduled, not just intended')
    f.runPendingThreads()
    t.equals(#f.defaultComponentVariationCalls, 2,
        'a variation applied to a half-built ped is silently dropped -- an intermittent invisible dog is worse to diagnose than a consistent one')
end)

t.test('INVISIBLE-PED FIX: the next-frame re-apply is a NO-OP if something swapped the player again in the meantime -- it never stomps whatever they legitimately became', function()
    local f = newFixture()
    f.env.source = 65535
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['john-k9:client:applyK9Ped']('req-42', 'a_c_shepherd')
    t.equals(#f.defaultComponentVariationCalls, 1)

    -- Another resource, a revoke racing the certify, or a death and
    -- respawn -- anything that moves them off the model this handler applied.
    f.setPedModel('HASH(a_m_m_business_01)')
    f.runPendingThreads()

    t.equals(#f.defaultComponentVariationCalls, 1, 'still just the immediate one -- the deferred pass correctly declined to act')
end)

t.test('INVISIBLE-PED FIX: an ABANDONED swap (model never streamed in) applies no variation and schedules no re-apply -- there is no new ped to dress', function()
    local f = newFixture({ modelLoadTimeoutMs = 200 })
    f.env.source = 65535
    -- deliberately never markModelLoaded -- HasModelLoaded stays false
    f.events['john-k9:client:applyK9Ped']('req-timeout', 'a_c_shepherd')

    t.equals(#f.setPlayerModelCalls, 0, 'precondition: the swap really was abandoned')
    t.equals(#f.defaultComponentVariationCalls, 0)
    t.equals(f.pendingThreadCount(), 0)
end)

t.test('INVISIBLE-PED FIX: a swap REFUSED because the ped is engaged applies no variation either -- nothing was swapped', function()
    local f = newFixture()
    f.env.source = 65535
    f.setEngaged('leashed', true)
    f.markModelLoaded('HASH(a_c_shepherd)')
    f.events['john-k9:client:applyK9Ped']('req-engaged', 'a_c_shepherd')

    t.equals(#f.setPlayerModelCalls, 0)
    t.equals(#f.defaultComponentVariationCalls, 0)
    t.equals(f.pendingThreadCount(), 0)
end)

t.test('REVERT CASE: a raw NUMERIC hash (not a string name) is applied directly -- GetHashKey is never called on it, since it is already a hash', function()
    local f = newFixture()
    f.env.source = 65535
    local originalHash = -123456789
    f.markModelLoaded(originalHash)
    f.events['john-k9:client:applyK9Ped']('req-revert', originalHash)

    t.equals(f.requestModelCalls[1], originalHash)
    t.equals(f.setPlayerModelCalls[1].hash, originalHash)
    t.isTrue(f.serverEvents[1][3])
end)

t.test('applyK9Ped: a malformed payload (neither string nor number) is ignored -- no crash, nothing requested', function()
    local f = newFixture()
    f.env.source = 65535
    f.events['john-k9:client:applyK9Ped']('req-1', { not_a = 'valid payload' })

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

t.test('applyK9Ped: an empty/non-string requestId is ignored -- no crash, nothing requested', function()
    local f = newFixture()
    f.env.source = 65535
    f.events['john-k9:client:applyK9Ped']('', 'a_c_husky')
    f.events['john-k9:client:applyK9Ped'](nil, 'a_c_husky')

    t.equals(#f.requestModelCalls, 0)
    t.equals(#f.serverEvents, 0)
end)

-- ----------------------------------------------------------------------
-- K9 IDENTITY (THIS PASS) -- "Identify K9" ox_target(-equivalent) option.
-- See client/appearance.lua's own "K9 IDENTITY" section header for the
-- full design; this section proves the CLIENT half: registration only
-- happens on 'onResourceStart' (never at file-load time), the option is
-- gated correctly, and NotifyIdentity renders exactly what the server
-- handed back -- nothing more, nothing invented, nothing shown for a
-- field the server left nil.
-- ----------------------------------------------------------------------

local IDENTITY_ENTITY = 777

t.test('K9 IDENTITY: registration is DEFERRED -- no option exists until onResourceStart fires for this resource', function()
    local f = newFixture()
    t.isNil(f.identityTargetOption(), 'nothing registered yet -- Sandbox.loadInto only ran this file\'s top-level chunk, which merely ADDS the onResourceStart handler')
    f.triggerResourceStart() -- defaults to this resource's own name
    t.isTrue(f.identityTargetOption() ~= nil, 'registration happens the moment this resource\'s own onResourceStart fires')
end)

t.test('K9 IDENTITY: re-registers when whichever resource backs "target" restarts, but NOT for an unrelated resource', function()
    local f = newFixture()
    f.triggerResourceStart()
    t.equals(f.targetAddGlobalPlayerCallCount(), 1)

    f.triggerResourceStart('some_unrelated_resource')
    t.equals(f.targetAddGlobalPlayerCallCount(), 1, 'an unrelated resource starting must never re-register')

    f.setK9CompatWhichTarget('ox_target')
    f.triggerResourceStart('ox_target')
    t.equals(f.targetAddGlobalPlayerCallCount(), 2, 'the resource that actually backs "target" restarting DOES re-register (survives a bare restart of that resource)')
end)

t.test('K9 IDENTITY: the option itself -- name/label/distance are exactly what production promises', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()
    t.equals(option.name, 'john-k9:k9Identity')
    t.equals(option.label, 'Identify K9') -- real locale('appearance.identity_target_label') via Sandbox.locale -- proves the key is landed in locales/en.json
    t.equals(option.distance, 3.0)
end)

t.test('K9 IDENTITY canInteract: false outright when Config.K9Identity.enabled is false, regardless of model or role', function()
    local f = newFixture({ k9Identity = { enabled = false } })
    f.triggerResourceStart()
    local option = f.identityTargetOption()

    f.setEntityModelK9(IDENTITY_ENTITY, true)
    t.isFalse(option.canInteract(IDENTITY_ENTITY), 'switched off means switched off -- even a real K9 model never shows this option')
end)

t.test('K9 IDENTITY canInteract: true for a real K9 model even with no resolvable server id', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()

    f.setEntityModelK9(IDENTITY_ENTITY, true)
    t.isTrue(option.canInteract(IDENTITY_ENTITY))
end)

t.test('K9 IDENTITY canInteract: true for a role-holder on a NON-K9 model (the role/model decoupling case)', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()

    f.setEntityModelK9(IDENTITY_ENTITY, false)
    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 55)
    f.queueRoleForTargetResponse(true)
    t.isTrue(option.canInteract(IDENTITY_ENTITY))
end)

t.test('K9 IDENTITY canInteract: false for an ordinary bystander -- not a K9 model, and not a role-holder', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()

    f.setEntityModelK9(IDENTITY_ENTITY, false)
    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 55)
    f.queueRoleForTargetResponse(false)
    t.isFalse(option.canInteract(IDENTITY_ENTITY))
end)

t.test('K9 IDENTITY onSelect: an unresolvable target (not a real player ped) never touches the network', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()

    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, nil)
    option.onSelect({ entity = IDENTITY_ENTITY })

    t.equals(f.identityCallCount(), 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('K9 IDENTITY onSelect: awaits the server callback with the resolved targetServerId', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()

    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 91)
    f.queueIdentityResponse({ ok = true, name = 'Rex Callahan' })
    option.onSelect({ entity = IDENTITY_ENTITY })

    t.equals(f.identityCallCount(), 1)
    t.equals(f.identityCallArgs[1], 91, 'the exact targetServerId this onSelect resolved, and nothing else, is what reaches the server')
end)

t.test('K9 IDENTITY onSelect: name + callsign + handler all present -- every line shown, in order', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()
    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 91)

    f.queueIdentityResponse({ ok = true, name = 'Rex Callahan', callsign = '9-Lincoln-3', handlerName = 'Officer Alvarez' })
    option.onSelect({ entity = IDENTITY_ENTITY })

    t.equals(#f.notifyCalls, 1)
    local shown = f.notifyCalls[1]
    t.equals(shown.title, 'K9 Identity') -- real locale('appearance.identity_notify_title')
    t.equals(shown.description, 'K9: Rex Callahan\nCallsign: 9-Lincoln-3\nHandler: Officer Alvarez')
end)

-- THE NORMAL CASE ON A FRESH SERVER: no roster row, no callsign, no
-- partner at all -- degrades to showing just the name, never a blank
-- line, never the literal text "nil".
t.test('K9 IDENTITY onSelect: DEGRADES CLEANLY -- a dog with no callsign and no partner shows ONLY its name', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()
    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 91)

    f.queueIdentityResponse({ ok = true, name = 'Rex Callahan', callsign = nil, handlerName = nil })
    option.onSelect({ entity = IDENTITY_ENTITY })

    t.equals(#f.notifyCalls, 1)
    local shown = f.notifyCalls[1]
    t.equals(shown.description, 'K9: Rex Callahan')
    t.isNil(shown.description:find('Callsign', 1, true))
    t.isNil(shown.description:find('Handler', 1, true))
    t.isNil(shown.description:find('nil', 1, true), 'never the literal text "nil" for a field the server left unset')
end)

t.test('K9 IDENTITY onSelect: SWITCHED OFF server-side (ok=false, reason=disabled) -- no notification, same as every other failure reason', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()
    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 91)

    f.queueIdentityResponse({ ok = false, reason = 'disabled' })
    option.onSelect({ entity = IDENTITY_ENTITY })

    t.equals(#f.notifyCalls, 0)
end)

t.test('K9 IDENTITY onSelect: too_far / not_k9 / invalid_target all degrade to a silent no-op, never a crash or a bystander-facing error', function()
    for _, reason in ipairs({ 'too_far', 'not_k9', 'invalid_target' }) do
        local f = newFixture()
        f.triggerResourceStart()
        local option = f.identityTargetOption()
        f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 91)

        f.queueIdentityResponse({ ok = false, reason = reason })
        option.onSelect({ entity = IDENTITY_ENTITY })

        t.equals(#f.notifyCalls, 0, 'reason=' .. reason)
    end
end)

t.test('K9 IDENTITY onSelect: a thrown/rejected lib.callback.await (timeout) is caught -- no crash, no notification', function()
    local f = newFixture()
    f.triggerResourceStart()
    local option = f.identityTargetOption()
    f.setPlayerServerIdForEntity(IDENTITY_ENTITY, 91)

    f.queueIdentityThrow()
    option.onSelect({ entity = IDENTITY_ENTITY }) -- must not raise out of this test

    t.equals(#f.notifyCalls, 0)
end)

os.exit(t.summary())
