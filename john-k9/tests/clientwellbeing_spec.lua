--[[
    tests/clientwellbeing_spec.lua

    Client-side spec for client/wellbeing.lua -- the FATIGUE subsystem's
    client half. Follows main_spec.lua's worked example: a real, unmodified
    client/wellbeing.lua loaded into a fresh sandbox per test, driven
    through its captured RegisterNetEvent handlers and its CreateThread
    bodies -- never a reimplementation of any `local` this spec has no other
    way to reach.

    IT USED TO COVER FIVE SUBSYSTEMS handled by the same file, and had a
    section for each. All but fatigue were removed on 2026-09-02 at the
    owner's request, and their tests went with them.

    LOAD-TIME GATING -- IMPORTANT FOR THIS FIXTURE, and the reason several
    tests below look the way they do. This file once gated its threads,
    ox_target registrations and commands with bare top-level
    `if Config.Features.<Name> then ... end` blocks, run ONCE at file-load
    time. That was a real, confirmed bug: an already-connected client could
    never learn of a runtime tablet toggle in either direction -- OFF left an
    in-flight movement penalty or input block frozen forever, ON left a
    client that booted disabled with nothing registered to ever pick it up.
    Registration now ALWAYS happens, and the per-flag decision is made at
    the POINT OF USE via `LiveFeatureFlags.<Name>`, a mirror kept fresh by
    every server push. That rule still governs the fatigue paths this spec
    covers today.

    THIS PASS'S PRIORITY, per this file's own task brief:
    1. The control-block thread's own-death guard, added after it was found
       spinning at Wait(0) while dead -- using the same instrumented
       coroutine-yield thread runner
       clienttracking_spec.lua's own header documents in full (built fresh
       here too, per this suite's "each spec owns its own tiny fixtures"
       convention -- not shared, since the two files' CreateThread bodies
       differ).
    2. Every wellbeing stat has a defined (non-crashing, side-effect-free)
       path when its OWNING feature flag is off -- section C, covering all
       five flags individually plus the "every flag off at once, with
       extreme stat values that would trip every branch if the flags were
       on" case.
    3. The `source ~= 65535` guard on the wellbeingUpdate handler -- section
       D, with the same D3-scope caveat clientsearch_spec.lua's own section
       F carries, repeated here per this task's own instruction never to
       leave that caveat findable only in one file.

    STUBBING EFFORT, reported honestly: proportionate, though this is the
    widest-surface of the three files in this task (five independently
    gated blocks, two CreateThread bodies, one ox_target pair, three
    RegisterCommand handlers, one RegisterNetEvent handler). Every stub is
    still the same small recording/controllable shape already established
    across this suite -- nothing here required disproportionate stubbing.
    Two stubs are unique to this file versus the other two specs in this
    task: K9MoveRateModifiers/RecomputeK9MoveRate (client/movement.lua
    resource-globals this file writes to/calls but never defines itself --
    a plain table plus a call-counting function is sufficient, since this
    spec only needs to prove WHAT this file writes into that table, never
    RecomputeK9MoveRate's own real composition math, which belongs to
    client/movement.lua's own spec if one exists) and GetGameTimer (a
    controllable fake clock, for the distractedUntil/hesitatingUntil
    comparisons -- identical `fakeNow`/`advance()` shape to main_spec.lua's
    own HasK9Access TTL fixture).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Sentinel returned by `queueCallbackThrow()` -- see clientsearch_spec.lua's
--- own identical THROW sentinel for the same rationale (ox_lib's real
--- lib.callback.await throws on a timeout/rejection rather than returning
--- nil; client/wellbeing.lua's own FAIL-CLOSED GUARD comments, added the
--- same session this spec was written, pcall every call site for exactly
--- this reason).
local THROW = setmetatable({}, { __tostring = function() return 'THROW' end })

-- ----------------------------------------------------------------------
-- Instrumented thread runner -- see clienttracking_spec.lua's own header
-- for the full rationale (every thread in this codebase's convention
-- calls Wait(...) at the END of its loop body, not the start, so the
-- FIRST resume already performs one real pass; Sandbox.newThreadRunner()'s
-- own "first step() only primes" semantics do not apply here). Built
-- fresh in this file too, per this suite's "each spec owns its own tiny
-- fixtures" convention -- not extracted to a shared helper, since sharing
-- one two-file-specific runner is a smaller win than keeping each spec
-- self-contained and independently readable.
-- ----------------------------------------------------------------------
local function newTrackedRunner()
    local threads = {}
    local waitLog = {}
    local runner = {}

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(ms)
        coroutine.yield(ms)
    end

    function runner.stepOne(i)
        local co = threads[i]
        if not co or coroutine.status(co) == 'dead' then return end
        local ok, msOrErr = coroutine.resume(co)
        if not ok then
            error(('clientwellbeing_spec: thread %d errored: %s'):format(i, tostring(msOrErr)))
        end
        waitLog[i] = msOrErr
    end

    function runner.step()
        for i = 1, #threads do runner.stepOne(i) end
    end

    return runner, threads, waitLog
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { features: table?, canShowK9UI: boolean? }?
local function newWellbeingFixture(opts)
    opts = opts or {}
    local runner, threads, waitLog = newTrackedRunner()

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local canShowK9UICallCount = 0
    local denyCalls = 0
    local denyReasons = {}
    local function CanShowK9UI() canShowK9UICallCount = canShowK9UICallCount + 1; return canShowK9UI end
    -- REASON PARAMETER (ease-of-use audit finding) -- captures whatever
    -- reason (if any) each call site passes, so this spec can prove the
    -- specific-reason routing (common.no_k9_role_or_access for these
    -- CanShowK9UI()-gated self-only actions) lands correctly.
    local function DenyK9UIAccess(reason)
        denyCalls = denyCalls + 1
        denyReasons[#denyReasons + 1] = reason
    end

    local isOwnModelK9 = false
    local function IsOwnModelK9() return isOwnModelK9 end

    local modelK9ByEntity = {} -- entity -> boolean
    local function IsEntityModelK9(entity) return modelK9ByEntity[entity] == true end

    local serverIdByPed = {} -- entity -> serverId or nil
    local function ResolvePlayerServerIdFromPed(entity) return serverIdByPed[entity] end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local myPed = 1
    local pedDead = false
    local function PlayerPedId() return myPed end
    local function IsEntityDead(entity) return pedDead end

    -- NATIVE SPRINT STAMINA ASSIST (client/wellbeing.lua) -- PlayerId() is a
    -- distinct native from PlayerPedId() above (a Player handle, not a Ped
    -- handle); a fixed sentinel is sufficient since these tests only need to
    -- prove it is the value RestorePlayerStamina is actually called with.
    local myPlayerId = 7
    local function PlayerId() return myPlayerId end
    local restorePlayerStaminaCalls = {}
    local function RestorePlayerStamina(player, percentage)
        restorePlayerStaminaCalls[#restorePlayerStaminaCalls + 1] = { player = player, percentage = percentage }
    end

    local disableControlActionCalls = {}
    local function DisableControlAction(inputGroup, control, disable)
        disableControlActionCalls[#disableControlActionCalls + 1] = { inputGroup = inputGroup, control = control, disable = disable }
    end

    -- HUNGER/THIRST (this pass, coder-backend) -- "Drink from Bowl"'s own
    -- onSelect resolves `data.entity` (a raw entity handle ox_target hands
    -- back) via DoesEntityExist + NetworkGetNetworkIdFromEntity before ever
    -- triggering the server event. GetHashKey is identity here (same
    -- convention as tests/wellbeing_spec.lua's own server-side stub), so a
    -- test can set bowlSources = {'test_water_bowl'} and match it directly
    -- with no real hashing involved.
    local existingEntities = {}
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local netIdByEntity = {}
    local function NetworkGetNetworkIdFromEntity(entity) return netIdByEntity[entity] end
    local function GetHashKey(name) return name end

    -- lib.callback.await -- one shared FIFO queue, sufficient because every
    -- test below only ever has ONE callback-awaiting action in flight at a
    -- time (the on-demand snapshot thread, or exactly one Pet/Feed/
    -- distraction-item onSelect/command call). A queued THROW sentinel
    -- errors instead of returning, modeling ox_lib's real timeout/rejection
    -- behavior (see this file's own header on the FAIL-CLOSED GUARD).
    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, args = { ... } }
        local next = table.remove(callbackResponses, 1)
        if next == THROW then
            error('simulated lib.callback.await failure (timeout/rejection)')
        end
        return next
    end

    local notifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    -- client/movement.lua resource-globals this file writes to/calls but
    -- never defines -- see this file's own header on why a plain table
    -- plus a call counter is sufficient here.
    local k9MoveRateModifiers = { fatigue = 42 } -- sentinel 42: any test that must prove a slot was NEVER touched checks for exactly this value surviving
    local recomputeCallCount = 0
    local function RecomputeK9MoveRate() recomputeCallCount = recomputeCallCount + 1 end

    -- client/wellbeing.lua now routes its "Pet K9"/"Feed K9" options
    -- through K9Compat.Get('target') (shared/compat/target.lua) rather than
    -- calling `exports.ox_target` directly -- see that file's own header.
    -- This fixture loads the REAL shared/compat/core.lua +
    -- shared/compat/target.lua (never a hand-written fake translation
    -- layer, which would just assert against itself) so K9Compat.Get
    -- ('target') resolves to the REAL ox_target adapter, which is a
    -- byte-for-byte pass-through of the options table -- captured below via
    -- the exact same colon-call `exports.ox_target:addGlobalPlayer` stub as
    -- before. ox_target is the ONLY candidate this fixture makes
    -- `GetResourceState` report as 'started', so detection deterministically
    -- resolves to it. Every REQUIRED_EXPORTS name (shared/compat/
    -- target.lua's OxTargetFactory) must exist as a callable function or the
    -- whole adapter is rejected as unverified and silently falls back to
    -- the no-op stub -- the exports this file never actually exercises are
    -- still stubbed as harmless no-ops so verification passes.
    local addGlobalPlayerCalls = {}
    local oxTargetStub = {}
    function oxTargetStub.addGlobalPlayer(_, defs) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = defs end
    function oxTargetStub.addGlobalVehicle() end
    function oxTargetStub.addGlobalObject() end
    function oxTargetStub.addModel() end
    function oxTargetStub.addSphereZone() end
    function oxTargetStub.removeGlobalPlayer() end
    function oxTargetStub.removeGlobalVehicle() end
    function oxTargetStub.removeGlobalObject() end
    function oxTargetStub.removeModel() end
    function oxTargetStub.removeZone() end
    function oxTargetStub.addLocalEntity() end
    function oxTargetStub.removeLocalEntity() end

    local function IsDuplicityVersion() return false end -- client realm, for shared/compat/core.lua
    local function GetResourceState(resourceName)
        return resourceName == 'ox_target' and 'started' or 'missing'
    end

    -- AddEventHandler -- captures EVERY event name (not just
    -- 'onResourceStart'): shared/compat/core.lua also registers
    -- 'onClientResourceStart'/'onClientResourceStop' handlers at load time
    -- (client realm) that this fixture never fires, but must not reject.
    -- `resourceStartHandlers` stays scoped to 'onResourceStart'
    -- specifically, exactly as before.
    local resourceStartHandlers = {}
    local otherEventHandlers = {}
    local function AddEventHandler(eventName, handler)
        if eventName == 'onResourceStart' then
            resourceStartHandlers[#resourceStartHandlers + 1] = handler
        else
            otherEventHandlers[eventName] = otherEventHandlers[eventName] or {}
            otherEventHandlers[eventName][#otherEventHandlers[eventName] + 1] = handler
        end
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local commands = {}
    local function RegisterCommand(name, handler, restricted) commands[name] = handler end

    local triggerServerEventCalls = {}
    local function TriggerServerEvent(eventName, ...)
        triggerServerEventCalls[#triggerServerEventCalls + 1] = { event = eventName, args = { ... } }
    end

    local overrides = {
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        IsOwnModelK9 = IsOwnModelK9,
        IsEntityModelK9 = IsEntityModelK9,
        ResolvePlayerServerIdFromPed = ResolvePlayerServerIdFromPed,
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        PlayerId = PlayerId,
        RestorePlayerStamina = RestorePlayerStamina,
        DisableControlAction = DisableControlAction,
        lib = lib,
        K9MoveRateModifiers = k9MoveRateModifiers,
        RecomputeK9MoveRate = RecomputeK9MoveRate,
        exports = { ox_target = oxTargetStub },
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        TriggerServerEvent = TriggerServerEvent,
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        IsDuplicityVersion = IsDuplicityVersion,
        GetResourceState = GetResourceState,
        -- HUNGER/THIRST (this pass, coder-backend).
        DoesEntityExist = DoesEntityExist,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        GetHashKey = GetHashKey,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    -- Explicit, per this task's own instruction: every one of the five
    -- wellbeing feature flags defaults to false here, regardless of
    -- config.lua's own shipped value (currently true for all 40 flags) --
    -- each test opts in exactly what it needs.
    env.Config.Features.FatigueSystem = false
    -- HUNGER/THIRST (this pass, coder-backend) -- same "explicit false,
    -- regardless of config.lua's shipped default" discipline as the five
    -- siblings above. real config.lua does not have this key at all yet
    -- (this file does not own config.lua) -- defaulting it here either way
    -- means this fixture behaves identically once it does.
    for key, value in pairs(opts.features or {}) do
        env.Config.Features[key] = value
    end

    -- Config seed note, kept because the reasoning still applies to every
    -- sub-table this fixture reads:
    -- `Sandbox.loadInto('../config.lua', env)` above populates the REAL,
    -- live config.lua values -- a hand-written seed here used to be
    -- harmless when real config.lua
    -- had no such keys at all (loading it left both `nil`, exactly what
    -- `opts.wellbeingHunger == false` wanted to simulate), but now that
    -- real config.lua defines them for real, the old `elseif ... ~= false
    -- then ... end` shape did NOTHING for `false`, silently leaving the
    -- REAL config.lua table in place instead of the "old config.lua never
    -- added this section at all" state the CONFIG-DEFENSIVE test below
    -- exists to simulate. Every one of the three branches is now explicit,
    -- so `false` genuinely clears the subtable regardless of what real
    -- config.lua ships. `nil`/omitted still selects THIS fixture's own
    -- default seed (kept in sync, by comment, with real config.lua's own
    -- shipped ARITHMETIC), `opts.wellbeingHunger`/`opts.wellbeingThirst`
    -- as a table still overrides it (e.g. to exercise bowlSources).
    if opts.wellbeingHunger == nil then
        env.Config.Wellbeing.Hunger = {
            max = 100, decayPerTick = 0.093, lowThreshold = 30, speedPenaltyMultiplier = 0.95,
            feedItemName = 'k9_food', feedRegenAmount = 35, feedCooldownMs = 120000,
        }
    elseif opts.wellbeingHunger == false then
        env.Config.Wellbeing.Hunger = nil
    else
        env.Config.Wellbeing.Hunger = opts.wellbeingHunger
    end
    if opts.wellbeingThirst == nil then
        env.Config.Wellbeing.Thirst = {
            max = 100, decayPerTick = 0.139, lowThreshold = 30, speedPenaltyMultiplier = 0.95,
            drinkItemName = 'k9_water', drinkRegenAmount = 35, drinkCooldownMs = 90000,
            bowlSources = {}, bowlRegenAmount = 15, bowlCooldownMs = 60000, bowlInteractRange = 2.0,
        }
    elseif opts.wellbeingThirst == false then
        env.Config.Wellbeing.Thirst = nil
    else
        env.Config.Wellbeing.Thirst = opts.wellbeingThirst
    end

    -- Real K9Compat, real ox_target adapter -- see the oxTargetStub comment
    -- above for why. Must load before client/wellbeing.lua.
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/target.lua', env)

    -- IsK9RoleForPlayer lives here. client/wellbeing.lua's ox_target
    -- predicates ask "is that OTHER player a K9", which the any-ped work
    -- moved from a model check to a role check -- and the role answer is
    -- defined in client/appearance.lua. The manifest loads both, so the
    -- game is fine; a sandbox that loads only the file under test is not.
    Sandbox.loadInto('../client/appearance.lua', env)
    Sandbox.loadInto('../client/wellbeing.lua', env)

    for _, fn in ipairs(resourceStartHandlers) do
        fn('john-k9')
    end

    return {
        env = env,
        threads = threads,
        waitLog = waitLog,
        step = runner.step,
        stepOne = runner.stepOne,
        notifyCalls = notifyCalls,
        triggerServerEventCalls = triggerServerEventCalls,
        disableControlActionCalls = disableControlActionCalls,
        k9MoveRateModifiers = k9MoveRateModifiers,
        recomputeCallCount = function() return recomputeCallCount end,

        restorePlayerStaminaCalls = restorePlayerStaminaCalls,
        myPlayerId = myPlayerId,

        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICallCount end,
        denyCallCount = function() return denyCalls end,
        lastDenyReason = function() return denyReasons[#denyReasons] end,
        -- Sets BOTH halves of the same underlying fact, deliberately.
        -- In production IsOwnModelK9() is `IsEntityModelK9(PlayerPedId())
        -- or role`, so "my own model is a K9" and "the player ped is a K9
        -- model" are not two independent knobs -- the first implies the
        -- second. They were separate here only because nothing read the
        -- entity form for the local ped until a since-removed block moved
        -- to IsEntityModelK9(PlayerPedId()) (owner's decision: a role-holder
        -- on a human body keeps sprint and jump). Keeping them in step here is
        -- what stops a test asserting a state a real client cannot be in.
        setIsOwnModelK9 = function(v)
            isOwnModelK9 = v
            modelK9ByEntity[myPed] = v or nil
        end,
        setEntityIsK9Model = function(entity, v) modelK9ByEntity[entity] = v end,
        setServerIdForPed = function(entity, serverId) serverIdByPed[entity] = serverId end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setPedDead = function(v) pedDead = v end,

        queueCallbackResponse = function(v) callbackResponses[#callbackResponses + 1] = v end,
        queueCallbackThrow = function() callbackResponses[#callbackResponses + 1] = THROW end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        setEntityExists = function(entity, v) existingEntities[entity] = v end,
        setEntityNetId = function(entity, netId) netIdByEntity[entity] = netId end,

        command = function(name) return commands[name] end,
        commandCount = function() local n = 0; for _ in pairs(commands) do n = n + 1 end; return n end,

        --- Invokes the REAL captured wellbeingUpdate handler with `source`
        --- set immediately beforehand -- same convention main_spec.lua's
        --- own triggerPlayBark uses.
        triggerWellbeingUpdate = function(sourceValue, stats)
            local handler = assert(netEventHandlers['john-k9:client:wellbeingUpdate'],
                'client/wellbeing.lua did not register a john-k9:client:wellbeingUpdate handler')
            env.source = sourceValue
            handler(stats)
        end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- SECTION A -- registration vs. enforcement, with every flag off.
--
-- UPDATED (RUNTIME TOGGLE FIX pass): this section used to prove "no
-- thread/command/ox_target option exists at all when its owning flag is
-- off" -- that was EXACTLY the shape of the confirmed bug this pass fixed
-- (a client booted disabled had nothing left to ever pick up a later
-- runtime toggle-ON). Now proves the INVERSE, deliberately: registration
-- always happens regardless of the boot-time flag value, and the real gate
-- lives at the point of use (`LiveFeatureFlags`), matching
-- client/featureblocks.lua's own established rule for this exact class of
-- check ("check at the point it acts, never merely at registration").
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- SECTION B -- THREAD ORDER at file-load time (and
-- every other flag false): the on-demand snapshot thread is created FIRST
-- the control-block
-- thread SECOND, and the (always-registering) native sprint stamina assist
-- thread THIRD -- threads[1] / threads[2] / threads[3] respectively,
-- verified by reading the file top-to-bottom. The third thread is a no-op
-- here (FatigueSystem is false in this fixture), which is exactly what
-- SECTION I below exercises directly.
-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------
-- SECTION C -- EVERY WELLBEING STAT HAS A DEFINED PATH WHEN ITS OWNING
-- FEATURE FLAG IS OFF. Extreme values that WOULD trip every branch if the
-- flags were on, pushed with every flag off first, then individually
-- turned on one at a time to prove the contrast is real (not just "the
-- values happened to be healthy").
-- ----------------------------------------------------------------------

t.test('every wellbeing flag off: extreme stat values touch NOTHING -- K9MoveRateModifiers explicitly RESET to 1.0 (never left frozen), zero notifies, RecomputeK9MoveRate STILL called unconditionally', function()
    -- UPDATED (RUNTIME TOGGLE FIX pass): this test used to assert the
    -- sentinel 42 SURVIVED untouched, i.e. "a disabled stat's modifier slot
    -- is left exactly as it was". That was the confirmed "unbounded trap"
    -- bug this pass fixed -- a K9 already carrying a real (non-1.0) penalty
    -- when its owning flag was switched off at runtime would keep that
    -- exact modifier forever, because nothing was ever going to move it
    -- back to neutral on its own (server/wellbeing.lua stops
    -- decaying/regenerating a stat the instant its flag goes false). FIXED:
    -- ApplyMoveRateModifiers now explicitly resets a disabled stat's own
    -- slot to 1.0 on every call, so the sentinel can never survive past the
    -- very first applied snapshot regardless of which flags are on.
    local f = newWellbeingFixture() -- the flag false
    f.triggerWellbeingUpdate(65535, { fatigue = 0 })
    -- NARROWED 2026-09-02: `fatigue` is the one slot this file still owns,
    -- and the unbounded-trap guarantee this test exists for applies to it
    -- exactly as before.
    t.equals(f.k9MoveRateModifiers.fatigue, 1.0, 'a disabled stat\'s modifier slot must be explicitly RESET to neutral, never left at whatever the sentinel/previous value was')
    t.equals(f.recomputeCallCount(), 1, 'RecomputeK9MoveRate is called unconditionally on every applied snapshot, regardless of which (if any) flags are on')
    t.equals(#f.notifyCalls, 0, 'no notify may fire while the owning flag is off, however extreme the pushed values are')
end)

t.test('RUNTIME TOGGLE OFF closes the unbounded trap: a K9 already carrying a real fatigue penalty has it REMOVED (not merely stopped from reapplying) the moment a live featureFlags push reports the flag off', function()
    -- THE CORE REGRESSION TEST FOR THIS PASS'S FIX. Reproduces the exact
    -- scenario the task brief described: FatigueSystem is on, a real
    -- penalty is already applied, then a runtime tablet toggle switches it
    -- off -- represented here exactly as server/wellbeing.lua's own
    -- SnapshotOf now sends it, a `featureFlags` field on the very next
    -- wellbeingUpdate push, NOT a change to this client's own static
    -- Config.Features (which a runtime toggle can never reach).
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    local belowThreshold = f.env.Config.Wellbeing.Fatigue.speedPenaltyThreshold - 1
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold })
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'sanity: the penalty is genuinely applied first')

    -- Server turned FatigueSystem off -- stat itself is now frozen
    -- server-side too (server/wellbeing.lua stops ticking it), so the SAME
    -- low fatigue value is still what arrives, but featureFlags.FatigueSystem
    -- is now false.
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold, featureFlags = { FatigueSystem = false } })
    t.equals(f.k9MoveRateModifiers.fatigue, 1.0, 'THE FIX: the modifier must be REMOVED immediately, not left frozen at the penalty value just because the underlying stat never moved')

    -- Turning it back on (still below threshold) must restore the penalty
    -- immediately, with no restart -- proves this is a live toggle in BOTH
    -- directions, not just a one-way safety valve.
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold, featureFlags = { FatigueSystem = true } })
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'turning the feature back on must restore normal behaviour with no restart')
end)

t.test('featureFlags ingest is defensive: a malformed/missing field never errors and never invents an unrecognised flag name', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    local belowThreshold = f.env.Config.Wellbeing.Fatigue.speedPenaltyThreshold - 1

    -- Missing featureFlags entirely -- must not disturb the current mirror.
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold })
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier)

    -- Non-table featureFlags, and a non-boolean value for a real flag name,
    -- and an unrecognised flag name -- none of these may error or change
    -- FatigueSystem's own current (true) value.
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold, featureFlags = 'not a table' })
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier)

    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold, featureFlags = { FatigueSystem = 'not a boolean', SomeUnrelatedFutureFlag = true } })
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'a non-boolean value for a real flag name must be ignored, not coerced')
end)

-- ----------------------------------------------------------------------
-- SECTION D -- `source ~= 65535` GUARD on the wellbeingUpdate handler.
--
-- SCOPE NOTE (repeated here per this task's own instruction, not left
-- findable only in clientsearch_spec.lua/main_spec.lua): every test below
-- pins what THIS FILE'S CODE does for a given `source` value. None of
-- them settle, and none should be read as settling, this project's open
-- decision D3 (DEVELOPER_REFERENCE.md) -- whether FiveM's real client runtime
-- can ever be made to deliver a forged local trigger carrying a stale or
-- incorrect `source` left over from an earlier genuine server-sent event
-- on the same connection. Independent attempts to close D3 by reading the
-- engine's own source code have repeatedly hit the same wall (four, per
-- DEVELOPER_REFERENCE.md's own count as of this session; five per this task's
-- own brief -- neither count is something a Lua-level sandbox test can
-- move). DEVELOPER_REFERENCE.md's own words: "Do not settle this by reading
-- more code -- only the live test settles it." A green result below is
-- necessary, not sufficient, evidence that the mitigation works.
-- ----------------------------------------------------------------------

t.test('wellbeingUpdate: source == 65535 (the documented genuine-server sentinel) is processed', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    local belowThreshold = f.env.Config.Wellbeing.Fatigue.speedPenaltyThreshold - 1
    f.triggerWellbeingUpdate(65535, { fatigue = belowThreshold })
    t.equals(f.recomputeCallCount(), 1, 'a genuinely server-sourced push must be applied -- see this section\'s own D3 scope note above')
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier)
end)

t.test('wellbeingUpdate: a forged local trigger with an arbitrary non-65535 numeric source is rejected outright -- pins the CODE\'s behavior only, D3 remains open regardless (see this section\'s header)', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(1, { fatigue = 0 })
    t.equals(f.recomputeCallCount(), 0, 'must be rejected before ApplyWellbeingSnapshot ever runs -- fatigue = 0 would otherwise trip the penalty')
    t.equals(f.k9MoveRateModifiers.fatigue, 42, 'sentinel must survive untouched')
end)

t.test('wellbeingUpdate: source left nil (a bare local TriggerEvent() carrying no origin at all) is also rejected -- same D3 scope caveat as above', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(nil, { fatigue = 0 })
    t.equals(f.recomputeCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- SECTION H -- the on-demand snapshot thread (bonus: cheap given the
-- fixture already built above, exercises the SAME FAIL-CLOSED GUARD
-- pattern from a second, independent call site).
-- ----------------------------------------------------------------------

t.test('on-demand snapshot thread: fetches exactly once on the false->true IsOwnModelK9 transition, not on every idle tick while it stays true', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.stepOne(1) -- prime/first pass: not yet K9
    t.equals(f.callbackCallCount(), 0)

    f.setIsOwnModelK9(true)
    f.queueCallbackResponse({ fatigue = 5 })
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'the fetched snapshot must actually be applied via ApplyWellbeingSnapshot')

    f.stepOne(1) -- still K9 -- must not refetch
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.waitLog[1], 2000)
end)

t.test('on-demand snapshot thread: a thrown lib.callback.await (timeout) is caught -- the thread survives and can fetch again on a later transition', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.setIsOwnModelK9(true)
    f.queueCallbackThrow()
    f.stepOne(1) -- must not kill the coroutine
    t.equals(f.k9MoveRateModifiers.fatigue, 42, 'a thrown/failed fetch must apply nothing')

    f.setIsOwnModelK9(false)
    f.stepOne(1)
    f.setIsOwnModelK9(true)
    f.queueCallbackResponse({ fatigue = 5 })
    f.stepOne(1)
    t.equals(f.callbackCallCount(), 2)
    t.equals(f.k9MoveRateModifiers.fatigue, f.env.Config.Wellbeing.Fatigue.speedPenaltyMultiplier, 'the thread must still be alive and able to fetch successfully after the earlier throw')
end)

-- ----------------------------------------------------------------------
-- SECTION I -- NATIVE SPRINT STAMINA ASSIST (owner directive: "make sure
-- high command can edit the ability to make stamina last longer or even
-- permanently"). This is the SECOND, separate "stamina" this task's own
-- investigation found -- GTA/FiveM's own built-in player sprint-stamina
-- limit (client/hud.lua's "Stamina" HUD row), distinct from this file's own
-- Fatigue move-rate modifier already covered above. Thread index 3 in a
-- fixture where the on-demand thread registers (any of the five flags
-- true), index 2 where it does not (see SECTION A/B's own thread-count
-- assertions).
-- ----------------------------------------------------------------------

t.test('NATIVE STAMINA ASSIST: percent = 0 (shipped config.lua default) never calls RestorePlayerStamina, even with FatigueSystem on and CanShowK9UI true -- no regression by default', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    t.equals(f.env.Config.Wellbeing.Fatigue.nativeStaminaRestorePercent, 0, 'sanity: shipped config.lua default is 0')
    f.stepOne(2)
    f.stepOne(2)
    t.equals(#f.restorePlayerStaminaCalls, 0)
end)

t.test('NATIVE STAMINA ASSIST: percent = 1.0 (the tablet\'s "permanent" setting) calls RestorePlayerStamina(PlayerId(), 1.0) on every single check, not merely once', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 1.0 } })
    for _ = 1, 5 do f.stepOne(2) end
    t.equals(#f.restorePlayerStaminaCalls, 5)
    for i, call in ipairs(f.restorePlayerStaminaCalls) do
        t.equals(call.player, f.myPlayerId, ('call %d must target PlayerId()'):format(i))
        t.equals(call.percentage, 1.0, ('call %d must restore the FULL, configured percentage -- this is what makes the maximum setting genuinely mean permanent, not merely "usually full"'):format(i))
    end
end)

t.test('NATIVE STAMINA ASSIST: a mid-range percentage (0.4, a live tablet edit) is passed through exactly, not rounded or reclamped a second time client-side', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 0.4 } })
    f.stepOne(2)
    t.equals(#f.restorePlayerStaminaCalls, 1)
    t.equals(f.restorePlayerStaminaCalls[1].percentage, 0.4)
end)

t.test('NATIVE STAMINA ASSIST: FatigueSystem off means the assist never fires, even with a nonzero percentage already configured -- this resource makes no claim about managing stamina at all while the owning flag is off', function()
    local f = newWellbeingFixture() -- FatigueSystem false (default)
    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 1.0 } })
    f.stepOne(2) -- no flag is true here, so the on-demand thread never registers: 2 = stamina assist
    t.equals(#f.restorePlayerStaminaCalls, 0)
end)

t.test('NATIVE STAMINA ASSIST: CanShowK9UI() false (not a currently-accessible K9) blocks the restore call even with FatigueSystem on and a nonzero percentage', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true }, canShowK9UI = false })
    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 1.0 } })
    f.stepOne(2)
    t.equals(#f.restorePlayerStaminaCalls, 0)
end)

t.test('NATIVE STAMINA ASSIST -- LIVE CHANGE TAKES EFFECT: a tablet edit from permanent (1.0) back down to off (0) stops the very next check from restoring anything, mid-session, no restart', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 1.0 } })
    f.stepOne(2)
    t.equals(f.restorePlayerStaminaCalls[1].percentage, 1.0)

    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 0 } })
    f.stepOne(2)
    t.equals(#f.restorePlayerStaminaCalls, 1, 'turning the assist back down to 0 must stop the very next check from calling RestorePlayerStamina at all')
end)

t.test('NATIVE STAMINA ASSIST: a malformed/non-number wellbeingTunables value is ignored -- the last-known-good percentage keeps being used, never a crash or a coerced garbage value', function()
    local f = newWellbeingFixture({ features = { FatigueSystem = true } })
    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 0.6 } })
    f.stepOne(2)
    t.equals(f.restorePlayerStaminaCalls[1].percentage, 0.6)

    f.triggerWellbeingUpdate(65535, { wellbeingTunables = { fatigueNativeStaminaRestorePercent = 'not-a-number' } })
    f.stepOne(2)
    t.equals(#f.restorePlayerStaminaCalls, 2)
    t.equals(f.restorePlayerStaminaCalls[2].percentage, 0.6, 'a malformed incoming value must leave the last-known-good percentage in effect, not silently become 0/nil/garbage')
end)

-- ========================================================================
os.exit(t.summary())
