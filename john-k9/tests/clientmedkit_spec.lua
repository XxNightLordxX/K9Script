--[[
    tests/clientmedkit_spec.lua

    Direct, black-box tests of client/medkit.lua against the REAL,
    unmodified production file -- the client half of "Treat K9" (server/
    medkit.lua's own contract). Follows this suite's worked example: a
    real file loaded into a
    fresh sandbox per test, driven only through its captured
    'john-k9:client:applyMedkitHeal' RegisterNetEvent handler.

    THIS PASS'S PRIORITY, per the task brief that produced this file: put
    regression coverage on client/medkit.lua's `applyMedkitHeal` handler
    (previously loaded by NO spec at all -- confirmed by grepping every
    *_spec.lua for 'client/medkit' before writing this file), specifically
    its five distinct guards, each an adversarial bypass-attempt test, not
    merely a happy-path proof:
      1. SOURCE-ORIGIN GUARD (`source ~= 65535`) -- section B.
      2. FEATURE GATE (`Config.Features.K9Medkit`) -- section A (now a true
         registration-time gate, see FINDING below) and section C (the
         kept-as-defense-in-depth inner check).
      3. DEAD-K9 GUARD (`IsEntityDead(ped)`) -- section D.
      4/5. MONOTONIC-HEAL FLOOR and MAX-HEALTH RANGE CLAMP (the single
         `math.max(currentHealth, math.min(newHealth, GetEntityMaxHealth
         (ped)))` line) -- section E, including the extremes (zero,
         negative, absurdly large, NaN, non-numeric, a table) and the
         guards COMPOSING (a forged event that also carries a hostile
         value) -- section F.

    FINDING, THIS PASS (fixed in client/medkit.lua, not just documented
    here): the FEATURE GATE's own comment claimed this handler matched
    "client/hud.lua / client/vision.lua / client/combat.lua's 'gate at
    registration' precedent" -- it did not. RegisterNetEvent was called
    unconditionally at file load; Config.Features.K9Medkit was only checked
    as the FIRST statement INSIDE the handler body, a materially weaker
    pattern than the one the comment named (a client whose server never
    enables K9Medkit still had a live function listening on this event
    name, merely one that declined to act -- not the "nothing is listening
    at all" guarantee the comment claimed). Closed by wrapping the
    RegisterNetEvent call itself in `if Config.Features.K9Medkit then ...
    end` (client/kennel.lua's own "REGISTRATION-TIME FEATURE GATE" shape),
    with the inner check kept as deliberate defense-in-depth, never
    deleted. Section A below proves BOTH halves: no net event is
    registered at all when the feature is off (the fix), and section C
    proves the inner check still independently blocks a call that reaches
    it (belt-and-suspenders, exercised directly against the captured
    handler bypassing the registration gate, the only way to reach the
    inner check in isolation from a spec).

    THE CLIENT IS NOT A SECURITY BOUNDARY -- see this spec's own trailing
    "WHAT THIS FILE DOES NOT COVER, AND WHY" note for the full analysis of
    whether server/medkit.lua remains safe if every one of these five
    guards were deleted (short answer: yes, for every path that goes
    through a real ox_target interaction and server round trip; these
    guards exist for a DIFFERENT, narrower threat -- a forged LOCAL
    TriggerEvent on this exact event name reaching a live, unmodified
    client's own already-loaded john-k9 resource, with zero server
    contact at all).

    STUBBING EFFORT: proportionate. Every native this handler's own
    exercised path touches (PlayerPedId, IsEntityDead, GetEntityHealth,
    GetEntityMaxHealth, SetEntityHealth, RegisterNetEvent, source) is a
    small, cheap recording/controllable stand-in, same shape as
    every other client spec's own fixtures.
    RegisterMedkitOxTargetOption()'s own onResourceStart/K9Compat wiring
    (the REQUEST side, a UX-only affordance per this file's own header, not
    this spec's concern) is stubbed only enough that the file loads without
    erroring -- K9Compat.Get('target').AddGlobalPlayer is a bare capturing
    no-op, never exercised for its own behavior here (that is
    clienttracking_spec.lua-style coverage for a DIFFERENT feature, out of
    this file's scope).

    ONE FRESH SANDBOX PER TEST -- client/medkit.lua exposes no file-load-time
    mutable locals of its own (RequestTreatK9/RegisterMedkitOxTargetOption/
    FindNearestTreatableK9 are all pure, stateless functions over their own
    arguments/globals), but a fresh sandbox per test is still used, matching
    this suite's own blanket convention and guarding against a future edit
    introducing module state without this spec silently developing a leak.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { k9Medkit: boolean? }?
local function newMedkitFixture(opts)
    opts = opts or {}

    local myPed = 1
    local pedDead = false
    local healthByPed = { [myPed] = 120 }
    local maxHealthByPed = { [myPed] = 200 }
    local setHealthCalls = {}

    local function PlayerPedId() return myPed end
    local function IsEntityDead(_entity) return pedDead end
    local function GetEntityHealth(entity) return healthByPed[entity] or 0 end
    local function GetEntityMaxHealth(entity) return maxHealthByPed[entity] or 0 end
    local function SetEntityHealth(entity, hp)
        setHealthCalls[#setHealthCalls + 1] = { entity = entity, health = hp }
        healthByPed[entity] = hp
    end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    -- ---- request-side (ox_target/onResourceStart) plumbing -- present so
    -- the file loads without erroring, and ALSO (this pass, coder-backend
    -- reason-mapping fix) reused by SECTION G below to exercise
    -- RequestTreatK9's reason-mapping table specifically -- see this file's
    -- header for the still-current, narrower scope boundary on the REST of
    -- the request side (FindNearestTreatableK9/RequestTreatNearestK9/the
    -- real K9Compat target-adapter wiring itself).
    local addGlobalPlayerCalls = {}
    local K9Compat = {
        Get = function(_system)
            return { AddGlobalPlayer = function(opt) addGlobalPlayerCalls[#addGlobalPlayerCalls + 1] = opt end }
        end,
        Redetect = function() end,
        Which = function() return 'ox_target' end,
    }
    local resourceStartHandlers = {}
    local function AddEventHandler(eventName, handler)
        resourceStartHandlers[eventName] = resourceStartHandlers[eventName] or {}
        resourceStartHandlers[eventName][#resourceStartHandlers[eventName] + 1] = handler
    end
    local function IsEntityModelK9(_entity) return false end
    local function IsK9RoleForPlayer(_serverId) return false end
    -- Settable via f.setResolvedServerId (SECTION G) -- defaults to nil,
    -- matching this fixture's own pre-existing default, so every test
    -- ABOVE section G that never calls that setter is completely
    -- unaffected by this addition.
    local resolvedServerId = nil
    local function ResolvePlayerServerIdFromPed(_ped) return resolvedServerId end
    -- Settable via f.setAwaitResult (SECTION G) -- defaults to nil, the
    -- exact same "no result" shape this fixture's own pre-existing stub
    -- always returned, so nothing above section G observes any change.
    local awaitResult = nil
    local notifyCalls = {}
    local libStub = {
        callback = { await = function() return awaitResult end },
        notify = function(notifyOpts) notifyCalls[#notifyCalls + 1] = notifyOpts end,
    }

    local overrides = {
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        SetEntityHealth = SetEntityHealth,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = function() return 'john-k9' end,
        K9Compat = K9Compat,
        IsEntityModelK9 = IsEntityModelK9,
        IsK9RoleForPlayer = IsK9RoleForPlayer,
        ResolvePlayerServerIdFromPed = ResolvePlayerServerIdFromPed,
        lib = libStub,
        source = 65535,
        -- Menu-parity pass (this session): client/medkit.lua now also
        -- registers a 'k9treat' chat command (RegisterCommand) alongside its
        -- existing ox_target option / resource-global -- a plain no-op
        -- stub, same shape as every other fixture in this suite that loads a
        -- production file registering a command it does not itself need to
        -- exercise.
        RegisterCommand = function(_name, _handler, _restricted) end,
    }

    local env = Sandbox.newEnv(overrides)
    env.Config = {
        Features = { K9Medkit = opts.k9Medkit ~= false },
        K9Medkit = { range = 2.0 },
    }

    Sandbox.loadInto('../client/medkit.lua', env)

    return {
        env = env,
        setHealthCalls = setHealthCalls,
        getHealth = function() return healthByPed[myPed] end,
        setHealth = function(hp) healthByPed[myPed] = hp end,
        setMaxHealth = function(hp) maxHealthByPed[myPed] = hp end,
        setPedDead = function(v) pedDead = v end,
        netEventCount = function()
            local n = 0
            for _ in pairs(netEventHandlers) do n = n + 1 end
            return n
        end,
        hasHealEvent = function() return netEventHandlers['john-k9:client:applyMedkitHeal'] ~= nil end,
        --- Fires the real, captured handler. `forged` (default false) models
        --- a local self-TriggerEvent (any source other than 65535) -- same
        --- convention as every other client spec's
        --- own fireFoundEvent/fireHintTier helpers.
        fireHealEvent = function(forged, newHealth)
            env.source = forged and 999 or 65535
            local handler = netEventHandlers['john-k9:client:applyMedkitHeal']
            assert(handler, 'applyMedkitHeal was never registered -- fixture bug or Config.Features.K9Medkit is off')
            handler(newHealth)
        end,
        --- Calls the captured handler DIRECTLY, bypassing whether it was
        --- ever registered at all -- the only way to exercise the INNER
        --- feature-flag check (kept as defense-in-depth, see this file's
        --- header FINDING) in isolation from the outer registration gate.
        --- Requires the handler to have been captured by a PRIOR fixture
        --- built with k9Medkit = true (see section C below).
        rawHandler = function() return netEventHandlers['john-k9:client:applyMedkitHeal'] end,

        -- ---- SECTION G plumbing (RequestTreatK9 reason-mapping) ----
        --- Fires every captured `onResourceStart` handler, exactly like a
        --- real FXServer resource start would -- same convention as
        --- clientkennel_spec.lua's own `fireResourceStart`. Needed to reach
        --- `RegisterMedkitOxTargetOption()`, which this file's own
        --- `AddEventHandler('onResourceStart', ...)` call only registers
        --- FROM, never runs eagerly at load time.
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(resourceStartHandlers['onResourceStart'] or {}) do handler(resourceName) end
        end,
        --- The captured "Treat This K9's Injuries" ox_target option's own
        --- `onSelect` closure -- nil until `fireResourceStart('john-k9')`
        --- has run at least once.
        getTreatOnSelect = function()
            local optsList = addGlobalPlayerCalls[1]
            return optsList and optsList[1] and optsList[1].onSelect
        end,
        setResolvedServerId = function(id) resolvedServerId = id end,
        --- @param result table|nil -- the `{ ok, reason? }` shape server/medkit.lua's own useK9Medkit callback returns
        setAwaitResult = function(result) awaitResult = result end,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
    }
end

-- ----------------------------------------------------------------------
-- SECTION A -- REGISTRATION-TIME FEATURE GATE (the fix, this pass). Feature
-- off means NO net event handler exists at all, not merely one that
-- declines to act -- see this file's header FINDING.
-- ----------------------------------------------------------------------

t.test('Config.Features.K9Medkit = false: registers NO net event handler at all -- true registration-time gate, not merely an inert one', function()
    local f = newMedkitFixture({ k9Medkit = false })
    t.equals(f.netEventCount(), 0, 'no RegisterNetEvent call at all when the feature is off')
    t.isFalse(f.hasHealEvent())
end)

t.test('Config.Features.K9Medkit = true: registers exactly the applyMedkitHeal net event', function()
    local f = newMedkitFixture()
    t.equals(f.netEventCount(), 1)
    t.isTrue(f.hasHealEvent())
end)

t.test('feature off: a forged local TriggerEvent on this exact event name has nothing to call -- structurally unreachable, proven by the handler genuinely not existing', function()
    local f = newMedkitFixture({ k9Medkit = false })
    t.isNil(f.rawHandler(), 'sanity: the handler function itself must not exist, not merely be a no-op')
end)

-- ----------------------------------------------------------------------
-- SECTION B -- GUARD 1: SOURCE-ORIGIN GUARD (`source ~= 65535`). A forged
-- local trigger (any source other than 65535) must never reach
-- SetEntityHealth, even carrying an otherwise perfectly legitimate heal
-- value.
-- ----------------------------------------------------------------------

t.test('SOURCE-ORIGIN GUARD: a forged (non-65535 source) heal push is rejected outright, even with an in-range, legitimate-looking newHealth', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.fireHealEvent(true, 150) -- forged; 150 is well within [120, 200], would be a "valid" heal if genuine
    t.equals(#f.setHealthCalls, 0, 'a forged push must never reach SetEntityHealth at all')
    t.equals(f.getHealth(), 120, 'health must be completely unchanged')
end)

t.test('SOURCE-ORIGIN GUARD: the genuine push (source == 65535) still works, proving the guard discriminates rather than blocking everything', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.fireHealEvent(false, 150)
    t.equals(#f.setHealthCalls, 1)
    t.equals(f.getHealth(), 150)
end)

-- ----------------------------------------------------------------------
-- SECTION C -- GUARD 2: FEATURE GATE, THE INNER CHECK KEPT AS
-- DEFENSE-IN-DEPTH. Reached only by calling the captured handler directly
-- (bypassing whether the outer registration gate let it be captured at
-- all) -- the only way a spec can isolate this specific line from the
-- registration-time gate section A already covers.
-- ----------------------------------------------------------------------

t.test('FEATURE GATE (inner, defense-in-depth): a genuine-origin push still no-ops if Config.Features.K9Medkit reads false AT APPLY TIME, independent of the registration gate', function()
    local f = newMedkitFixture() -- feature on at load time, so the handler exists
    local handler = f.rawHandler()
    t.isNotNil(handler, 'sanity: handler must exist to isolate the inner check from the outer registration gate')

    -- Flip the flag OFF after registration -- models the inner check being
    -- the only thing standing between a stale/forged genuine-origin call
    -- and a live heal, with no reliance on the outer wrapper having run
    -- again (it does not re-run per event; this proves the inner line
    -- itself, not merely that section A's wrapper works).
    f.env.Config.Features.K9Medkit = false
    f.env.source = 65535
    handler(150)
    t.equals(#f.setHealthCalls, 0, 'the inner check must independently block this, with zero reliance on the outer registration gate')
end)

-- ----------------------------------------------------------------------
-- SECTION D -- GUARD 3: DEAD-K9 GUARD (`IsEntityDead(ped)`). A heal must
-- never act as a de-facto revive.
-- ----------------------------------------------------------------------

t.test('DEAD-K9 GUARD: a genuine push arriving after this K9 died in transit is dropped, never applied as a de-facto revive', function()
    local f = newMedkitFixture()
    f.setHealth(50)
    f.setPedDead(true)
    f.fireHealEvent(false, 150)
    t.equals(#f.setHealthCalls, 0, 'a heal must never land on an already-dead ped')
    t.equals(f.getHealth(), 50, 'health must be completely unchanged')
end)

t.test('DEAD-K9 GUARD: an alive K9 still receives the heal normally (the guard discriminates, not a blanket block)', function()
    local f = newMedkitFixture()
    f.setPedDead(false)
    f.setHealth(120)
    f.fireHealEvent(false, 150)
    t.equals(#f.setHealthCalls, 1)
    t.equals(f.getHealth(), 150)
end)

-- ----------------------------------------------------------------------
-- SECTION E -- GUARDS 4/5: MONOTONIC-HEAL FLOOR and MAX-HEALTH RANGE
-- CLAMP. `newHealth = math.max(currentHealth, math.min(newHealth,
-- GetEntityMaxHealth(ped)))`. Extremes: zero, negative, absurdly large,
-- NaN, non-numeric, a table.
-- ----------------------------------------------------------------------

t.test('MAX-HEALTH CLAMP: an absurdly large forged/stale newHealth (99999) is clamped to live GetEntityMaxHealth, never applied verbatim', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.setMaxHealth(200)
    f.fireHealEvent(false, 99999)
    t.equals(#f.setHealthCalls, 1)
    t.equals(f.getHealth(), 200, 'must clamp to live maxHealth(200), never the raw uncapped 99999')
end)

t.test('MONOTONIC FLOOR: a newHealth BELOW this ped\'s own current live health (a "heal event that hurts") is floored at currentHealth, never applied verbatim', function()
    local f = newMedkitFixture()
    f.setHealth(150)
    f.setMaxHealth(200)
    f.fireHealEvent(false, 10) -- a stale/reordered heal computed when this K9 had far less health
    t.equals(#f.setHealthCalls, 1)
    t.equals(f.getHealth(), 150, 'must floor at currentHealth(150), never drop to 10')
end)

t.test('MONOTONIC FLOOR: newHealth == 0 is floored at currentHealth, never zeroes this ped out', function()
    local f = newMedkitFixture()
    f.setHealth(140)
    f.fireHealEvent(false, 0)
    t.equals(f.getHealth(), 140)
end)

t.test('MONOTONIC FLOOR: a negative newHealth is floored at currentHealth, never applied as a negative/near-zero value', function()
    local f = newMedkitFixture()
    f.setHealth(140)
    f.fireHealEvent(false, -500)
    t.equals(f.getHealth(), 140)
end)

t.test('NaN newHealth (0/0): degrades SAFELY to a pure no-op at currentHealth -- every comparison against NaN is false, so math.max/math.min\'s own algorithm keeps currentHealth rather than propagating NaN into SetEntityHealth', function()
    local f = newMedkitFixture()
    f.setHealth(130)
    local nan = 0 / 0
    t.isTrue(nan ~= nan, 'sanity: this really is NaN')
    f.fireHealEvent(false, nan)
    t.equals(#f.setHealthCalls, 1, 'the handler still runs to completion and calls SetEntityHealth -- it does not crash or short-circuit on NaN')
    local applied = f.setHealthCalls[1].health
    t.isTrue(applied == 130, 'NaN must resolve to currentHealth, not propagate NaN into a native call')
end)

t.test('non-numeric newHealth (a string): the type check rejects it before ever reaching the clamp or SetEntityHealth', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.fireHealEvent(false, 'not-a-number')
    t.equals(#f.setHealthCalls, 0)
    t.equals(f.getHealth(), 120)
end)

t.test('a table payload (a completely malformed/hostile shape): the type check rejects it before ever reaching the clamp or SetEntityHealth, never errors', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.fireHealEvent(false, { malicious = true })
    t.equals(#f.setHealthCalls, 0)
    t.equals(f.getHealth(), 120)
end)

t.test('a nil payload (no argument at all): the type check rejects it, never errors', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.fireHealEvent(false, nil)
    t.equals(#f.setHealthCalls, 0)
    t.equals(f.getHealth(), 120)
end)

t.test('a genuinely valid mid-range heal applies exactly the value sent, unmodified by the clamp -- proves the clamp is a true no-op for a real server push, not merely "harmless"', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.setMaxHealth(200)
    f.fireHealEvent(false, 170) -- server would compute 120 + healthRestore(50) = 170, well within bounds
    t.equals(f.setHealthCalls[1].health, 170)
end)

-- ----------------------------------------------------------------------
-- SECTION F -- GUARDS COMPOSING: a forged event that ALSO carries a
-- hostile value must still be blocked by the origin guard alone -- the
-- clamp is never the only thing standing between a forged event and an
-- exploit.
-- ----------------------------------------------------------------------

t.test('COMPOSED: a forged (non-65535) push carrying an absurd newHealth(999999) is blocked by the SOURCE-ORIGIN GUARD alone -- never even reaches the clamp', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.setMaxHealth(200)
    f.fireHealEvent(true, 999999)
    t.equals(#f.setHealthCalls, 0, 'the origin guard must reject this before the clamp ever runs')
    t.equals(f.getHealth(), 120)
end)

t.test('COMPOSED: a forged push targeting an already-dead K9 with a hostile value is blocked -- both the origin guard and the dead-K9 guard would each independently reject this', function()
    local f = newMedkitFixture()
    f.setHealth(50)
    f.setPedDead(true)
    f.fireHealEvent(true, 999999)
    t.equals(#f.setHealthCalls, 0)
    t.equals(f.getHealth(), 50)
end)

t.test('COMPOSED: feature off (registration gate) plus a forged source plus a hostile value -- every layer independently would reject this; the net effect is still zero calls', function()
    local f = newMedkitFixture({ k9Medkit = false })
    t.isNil(f.rawHandler(), 'no handler exists at all -- the strongest possible composed rejection')
end)

t.test('COMPOSED: a genuine, alive, in-bounds push still succeeds even after exercising every rejection path above in the same fixture -- the guards never wrongly latch closed', function()
    local f = newMedkitFixture()
    f.setHealth(120)
    f.setMaxHealth(200)

    f.fireHealEvent(true, 999999) -- forged, rejected
    f.setPedDead(true)
    f.fireHealEvent(false, 150) -- dead, rejected
    f.setPedDead(false)
    f.fireHealEvent(false, 'nope') -- bad type, rejected
    t.equals(#f.setHealthCalls, 0, 'sanity: nothing has applied yet')

    f.fireHealEvent(false, 150) -- genuine, alive, in-bounds
    t.equals(#f.setHealthCalls, 1)
    t.equals(f.getHealth(), 150)
end)

-- ----------------------------------------------------------------------
-- SECTION G -- RequestTreatK9's REASON-MAPPING TABLE (added this pass,
-- coder-backend). Server/medkit.lua's own useK9Medkit callback can refuse
-- for ten distinct `reason` values; this table is the ONLY place any of
-- them ever reaches player-visible text. A reason present on the server
-- but absent from this table is not a crash and not untested-looking --
-- it silently falls through to the generic `medkit_failed` text, exactly
-- the "split exists and the player still cannot see it" defect class this
-- pass exists to close (`not_granted` was the one real instance found).
-- These tests drive the REAL onSelect closure captured off a REAL
-- `fireResourceStart`, not a reimplementation of RequestTreatK9's own
-- logic, so a future edit to the mapping table is proven correct against
-- the production file itself, not against this spec's assumptions about
-- it. `locale()` here is the REAL reader (tests/fixtures/sandbox.lua's own
-- Sandbox.locale), which raises loudly if a mapped key is missing from
-- locales/en.json -- so every case below also doubles as a check that the
-- key it names actually exists.
-- ----------------------------------------------------------------------

--- @param f table fixture returned by newMedkitFixture
--- @param reason string
local function selectAndAwaitReason(f, reason)
    f.fireResourceStart('john-k9')
    local onSelect = f.getTreatOnSelect()
    assert(onSelect, 'ox_target option was never registered -- fixture bug')
    f.setResolvedServerId(7)
    f.setAwaitResult({ ok = false, reason = reason })
    onSelect({ entity = 999 })
end

t.test('REASON MAPPING: "not_granted" (this pass\'s own fix) renders its OWN distinct text, not the no_access text and not the generic fallback', function()
    local f = newMedkitFixture()
    selectAndAwaitReason(f, 'not_granted')
    local notice = f.lastNotify()
    t.isNotNil(notice, 'lib.notify must have been called')
    t.equals(notice.description, Sandbox.locale('medkit.reason_not_granted'))
    t.isTrue(notice.description ~= Sandbox.locale('medkit.reason_no_access'), 'not_granted must not collapse into the job-based no_access text')
    t.isTrue(notice.description ~= Sandbox.locale('medkit.reason_medkit_failed'), 'not_granted must not fall through to the generic catch-all')
end)

t.test('REASON MAPPING: every OTHER reason server/medkit.lua can return still maps to its own distinct, non-fallback text', function()
    local reasonToLocaleKey = {
        feature_disabled      = 'medkit.reason_feature_disabled',
        no_access             = 'medkit.reason_no_access',
        invalid_target        = 'medkit.reason_invalid_target',
        target_dead           = 'medkit.reason_target_dead',
        on_cooldown           = 'medkit.reason_on_cooldown',
        no_item               = 'medkit.reason_no_item',
        treatment_in_progress = 'medkit.reason_treatment_in_progress',
    }
    for reason, localeKey in pairs(reasonToLocaleKey) do
        local f = newMedkitFixture()
        selectAndAwaitReason(f, reason)
        local notice = f.lastNotify()
        t.isNotNil(notice, 'lib.notify must have been called for reason ' .. reason)
        t.equals(notice.description, Sandbox.locale(localeKey), 'reason ' .. reason .. ' must render its own dedicated text')
    end
end)

t.test('REASON MAPPING: "too_far" is deliberately mapped to the SHARED common.too_far_from_k9 key, not a medkit-only duplicate', function()
    local f = newMedkitFixture()
    selectAndAwaitReason(f, 'too_far')
    t.equals(f.lastNotify().description, Sandbox.locale('common.too_far_from_k9'))
end)

t.test('REASON MAPPING: an unrecognized reason value falls back to the generic medkit_failed text, never a raw key or a crash', function()
    local f = newMedkitFixture()
    selectAndAwaitReason(f, 'some_future_reason_this_client_does_not_know_yet')
    t.equals(f.lastNotify().description, Sandbox.locale('medkit.reason_medkit_failed'))
end)

t.test('REASON MAPPING: a successful result (ok = true) never fires a notify at all -- the server\'s own success notify is the only feedback, no client-side duplicate', function()
    local f = newMedkitFixture()
    f.fireResourceStart('john-k9')
    local onSelect = f.getTreatOnSelect()
    f.setResolvedServerId(7)
    f.setAwaitResult({ ok = true })
    onSelect({ entity = 999 })
    t.equals(#f.notifyCalls, 0)
end)

-- ----------------------------------------------------------------------
-- WHAT THIS FILE DOES NOT COVER, AND WHY:
--
-- 1. THE REST OF THE REQUEST SIDE (FindNearestTreatableK9,
--    RequestTreatNearestK9, and the real K9Compat/ox_target ADAPTER
--    wiring itself) -- pure UX affordance per this file's own header
--    ("nothing below is a security boundary... the client hides the
--    option, server is the real gate"). SECTION G above now DOES cover
--    RequestTreatK9's own reason-mapping table specifically (added this
--    pass, alongside the client-side fix it verifies) -- this exclusion no
--    longer applies to that one piece, corrected here rather than left to
--    go stale. The remaining pieces still excluded would require a real
--    K9Compat target-adapter fixture (a DIFFERENT file's own
--    concern, per this suite's per-file ownership convention) for
--    marginal, non-security-relevant value.
--
-- 2. IS THE SERVER SAFE IF ALL FIVE CLIENT GUARDS WERE DELETED? -- Read
--    directly from server/medkit.lua this pass (not assumed): YES, for
--    every path that goes through a real "Treat K9" interaction and a real
--    server round trip. server/medkit.lua's own useK9Medkit callback
--    independently re-verifies, EVERY time, with no trust in anything the
--    client claims: the feature flag itself (returns feature_disabled
--    before touching anything), the using player's real job/grant
--    (IsMedkitUserAuthorized / IsK9MedkitPermittedForCitizenId),
--    server-side LIVE PROXIMITY between two live GetEntityCoords reads
--    (never a client-claimed distance), the target's REAL re-derived ped
--    model/role (IsConfiguredK9Model/HasK9Role, never trusting the
--    client's ox_target selection), the target's REAL liveness
--    (GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD, itself
--    fixed this codebase's own worst-documented native-availability bug --
--    see tests/medkit_spec.lua's own header), a per-target cooldown
--    (MedkitCooldown, TOCTOU-safe via MedkitMutex), and REAL item
--    possession+consumption via K9Compat.Get('inventory') BEFORE any
--    health value is even computed. The newHealth value server/medkit.lua
--    computes and pushes is already clamped to
--    [currentHealth, GetEntityMaxHealth(targetPed)] AT SERVER COMPUTE TIME
--    (RunUseK9MedkitMutation's own math.min/math.max pair) -- deleting
--    every client-side guard would not let a real "Treat K9" interaction
--    produce a value the server did not already authorize.
--    WHAT WOULD ACTUALLY BREAK: only the narrower, DIFFERENT threat these
--    five guards exist for in the first place (this file's own header,
--    and DEVELOPER_REFERENCE.md's "Flag-off-safety defect class" audit
--    item) -- a forged LOCAL 'john-k9:client:applyMedkitHeal' dispatch
--    on an already-running, unmodified john-k9 client, requiring ZERO
--    server contact and ZERO game-memory modification (reachable by any
--    other loaded resource's plain Lua calling TriggerEvent, or by a
--    leaked/cracked companion resource -- a materially lower bar than
--    memory-editing a game client, and the reason these guards are real
--    security value despite "the client is not a security boundary" being
--    true in the memory-editing sense). Deleting these five guards would
--    restore exactly the five bugs each guard's own header comment
--    documents as "previously real": an uncapped, cooldown-free,
--    feature-flag-ignoring, dead-K9-revive-capable, downward-movable
--    self-heal reachable with nothing more than a same-client
--    TriggerEvent call. Severity: real but NARROW -- it cannot heal a
--    DIFFERENT player's K9 (the event only ever self-applies to
--    PlayerPedId(), see this file's own doc comment on applyMedkitHeal),
--    cannot consume/deny another player's item or cooldown, and cannot
--    forge the source id needed to make a genuinely networked dispatch
--    look server-authored (source is set by the FX runtime per-invocation
--    based on real transport, not attacker-suppliable data -- confirmed
--    against FiveM's own documented event model this pass, see the
--    SOURCE-ORIGIN GUARD's own updated comment in client/medkit.lua) -- so
--    the realistic exposure is "a same-client resource can give itself (or
--    ITS OWN K9) a free, unlimited, revive-capable heal," not a
--    cross-player or server-state exploit.
-- ----------------------------------------------------------------------

os.exit(t.summary())
