--[[
    john-k9/client/pursuitsprint.lua

    PROJECT_HISTORY.md §5 ("Pursuit sprint -- a short burst of 'the dog is
    genuinely faster than you'"). Client half of a short, cooldown-gated
    speed burst for a certified K9 actively chasing a player this server's
    own system has already flagged wanted/suspect. Server half:
    server/pursuitsprint.lua -- read that file's header IN FULL first; it
    is the authoritative source for the balance numbers, the event
    contract, the XP decision, and the per-person feature-control
    disclosure. This file only covers what is genuinely client-side: local
    candidate selection (a display-only convenience, never the security
    boundary), and applying/expiring the effect on the K9's OWN ped once
    the server has granted it.

    Explicitly NOT building "crowd-control barking" (PROJECT_HISTORY.md's own
    not-recommended section) -- see server/pursuitsprint.lua's own header
    "WHAT THIS FILE DOES NOT DO" for the full statement; nothing here
    targets, resolves, or affects any ped other than the local player's own.

    ======================================================================
    ANY PED, GATED ON ROLE/CERTIFICATION, NEVER ON PED MODEL. This file
    deliberately does NOT call CanShowK9UI()/DenyK9UIAccess() anywhere --
    unlike nearly every other self-initiated trigger in this resource
    (K9Sit, RequestLeashAttach, RequestBiteHold, RequestPartnerUp). Two
    reasons, together:
      1. CanShowK9UI() can itself be model-gated (client/main.lua's own
         doc comment: with Config.K9Appearance.requireK9ModelForRole = true,
         or if client/appearance.lua is not loaded, CanShowK9UI() reduces to
         `IsOwnModelK9() and HasK9Access()`), and this feature must work
         identically on ANY ped -- a custom streamed ped, one not listed in
         Config.Peds, or a human model -- gated on role/certification
         ALONE. Depending on a check that CAN (depending on an operator's
         own separate appearance setting) narrow to a ped-model condition
         is the wrong foundation for a feature required to never do that.
      2. The real, binding authorization gate for this feature is
         server-side anyway (server/pursuitsprint.lua's own
         HasK9Access(src) -- itself a pure role/certification check with
         no model component at all, per server/certifications/'s own
         "ROLE/MODEL DECOUPLING" header). This file's own local checks
         below (vehicle tuck, "is there a nearby candidate") are
         DISPLAY/UX-only, exactly like client/combat.lua's own
         FindNearestCombatTarget and every ox_target canInteract predicate
         in this resource -- the server independently re-resolves and
         re-validates everything regardless of what this file believes.
    A player entirely lacking K9 role/certification can still press the
    keybind; the request reaches the server and is denied there with a
    real, server-authoritative notification -- exactly the same tradeoff
    client/movement.lua's own "Attach Leash"/"Certify Handler" ox_target
    options already document and accept.

    A REAL BUG, FOUND AND FIXED (client/movement.lua): the "ANY PED...
    NEVER ON PED MODEL" promise above was FALSE in practice until this was
    fixed. This file itself never checked the model -- but the ONE place it
    hands off to, RecomputeK9MoveRate() (client/movement.lua), used to
    hard-gate on IsOwnModelK9() alone before composing anything, silently
    discarding K9MoveRateModifiers.pursuitSprint (and every other modifier)
    for a role-holder on a non-K9 body. A granted request still showed the
    "activated" toast (this file's own doing) with zero actual speed change
    (that gate's doing) -- exactly the two real configurations named in
    client/movement.lua's own "SCOPE, CORRECTED" header comment
    (requireK9ModelForRole = true, and the default-config HasK9Access()
    autoAccessGrade/High-Command-bypass case). Fixed there, not here:
    RecomputeK9MoveRate()'s gate is now `IsOwnModelK9() or HasK9Access()`,
    so this file needed no code change of its own -- it was always calling
    the right function with the right value, the composer just wasn't
    listening.

    ======================================================================
    THE BALANCE PROBLEM -- see server/pursuitsprint.lua's own header for
    the full numbers/worst-case writeup. The one fact that matters for THIS
    file specifically: this feature contributes exactly ONE multiplicative
    input (K9MoveRateModifiers.pursuitSprint) into client/movement.lua's
    ALREADY-SHIPPED move-rate composer (RecomputeK9MoveRate), which clamps
    the combined product of every active modifier to [0.1, 2.0]. This file
    NEVER calls SetPedMoveRateOverride directly, and never introduces a
    second clamp -- client/movement.lua's own header names
    RecomputeK9MoveRate() as "This resource's ONLY call site for
    SetPedMoveRateOverride, anywhere" and this file keeps that true.

    ======================================================================
    NO UNBOUNDED TRAP -- THE LOAD-BEARING INVARIANT THIS FILE EXISTS TO
    SATISFY (mirrors this resource's own established framing for its
    equivalent termination path). The code path that ENDS a burst (natural
    timeout, death, or this resource stopping) below:
      - is NEVER gated on CanShowK9UI()/HasK9Access()/any certification
        check of any kind -- confirmed by reading this file's own end-timer
        thread and onResourceStop handler below: neither calls anything
        from that family at all. A K9 that loses certification, or has its
        server-side role revoked, MID-BURST still has the multiplier reset
        on schedule -- the ability to end an effect must never depend on
        still holding the permission that started it (this resource's
        own documented invariant, applied here to a different mechanic).
      - fires even if this resource restarts mid-burst (the onResourceStop
        handler below), and even if the K9 dies mid-burst (the end-timer's
        own IsEntityDead(PlayerPedId()) check -- FiveM respawn REUSES the
        ped handle, so a stale non-1.0 override could otherwise persist
        onto the respawned character; the natural, bounded (<=
        Config.PursuitSprint.durationMs) timeout ALSO independently bounds
        this even without the death check, so this is defense-in-depth, not
        the only thing standing between a death and a stuck multiplier).
      - is guarded by a generation counter (`sprintGeneration` below) so a
        stale end-timer from an earlier grant can never clobber a NEWER,
        still-active burst's modifier -- the same "stale/foreign event must
        never clear a DIFFERENT instance's state" discipline
        client/combat.lua's own biteHoldEnded/dragEnded handlers already
        apply (`if MyEngagedTargetNetId ~= targetNetId then return end`).
        In practice this should be unreachable (the server's own
        cooldownMs default, 45s, vastly outlasts one burst's durationMs
        default, 5s, so two grants can never legitimately overlap), but
        this file does not rely on that margin alone.

    ======================================================================
    EVENT CONTRACT (see server/pursuitsprint.lua's own header for the full
    writeup):
      Client -> Server: 'john-k9:server:requestPursuitSprint' (targetNetId: number)
      Server -> Client: 'john-k9:client:pursuitSprintGranted' (speedMultiplier: number, durationMs: number)
        CARRIES A PAYLOAD (closing a real tablet-tunable sync gap; see
        server/pursuitsprint.lua's own header "EVENT CONTRACT" for the full
        writeup). This USED TO be payload-less on the theory that
        "Config.PursuitSprint.speedMultiplier/durationMs are shared_scripts
        config, already identical on both sides" -- true only as long as
        neither side's copy could ever change independently, which stopped
        being true the moment server/runtimecontrol.lua's tablet gained the
        ability to mutate the SERVER's own in-memory Config.PursuitSprint
        live, with nothing that ever reaches an already-connected client's
        own separate config.lua copy. This file now applies WHATEVER THE
        SERVER SENT for this one grant, never re-reading
        `Config.PursuitSprint.speedMultiplier`/`.durationMs` for that
        purpose again below -- those two fields are used ONLY as the
        fallback for a malformed/missing payload (see the grant handler's
        own "PAYLOAD VALIDATION" comment), never as the primary source once
        a real grant has arrived. Applying a value this client was actually
        SENT, rather than one it looked up itself, is what makes a live
        tablet edit genuinely reach an already-connected K9 on its next
        grant -- see server/pursuitsprint.lua's own "LIVE EDIT MID-SPRINT"
        note for why a burst ALREADY GRANTED keeps its own captured value
        for its full duration rather than updating mid-flight.
        NOT A NEW TRUST BOUNDARY: this event's origin is still restricted to
        the genuine server by the SOURCE-ORIGIN GUARD below, exactly as
        before -- a forged local trigger was already the only way to feed
        this handler a fabricated value, payload or not, and gains nothing
        new from the payload existing (the SERVER never reads anything back
        from this client for this feature at all; see
        server/pursuitsprint.lua's own request handler, which takes only a
        `targetNetId`).
      A rejected request is NEVER a dedicated client event -- the server
      sends a single ox_lib notify (via NotifyPlayer) and nothing else. Do
      not add a 'john-k9:client:pursuitSprintDenied' event without
      updating this comment and server/pursuitsprint.lua's own header
      together.

    ======================================================================
    SOURCE-ORIGIN GUARD on the one `john-k9:client:*` handler below
    (`if source ~= 65535 then return end`) -- mirrors client/combat.lua's
    own "SOURCE-ORIGIN GUARD" header block exactly; read that file's header
    for the full reasoning and the same honestly-graded MEDIUM-HIGH
    confidence note (official documented pattern, not independently
    re-verified against a live client) rather than re-deriving it here.
    What forging this locally would gain an attacker: a self-only speed
    buff on their OWN ped with zero cooldown enforcement (the server-side
    cooldown is bypassed entirely by construction, since a forged local
    TriggerEvent never reaches server/pursuitsprint.lua at all) -- this
    closes that gap for the same "any john-k9:client:* handler must
    require genuine server origin" resource-wide convention every other
    file already follows, not because this one instance was independently
    assessed as higher/lower risk than the others.

    ======================================================================
    NATIVES USED, AND HOW EACH IS ALREADY ESTABLISHED IN THIS EXACT
    CODEBASE (every native below already has a real, relied-upon call site
    elsewhere in this resource; none is newly introduced by this file):
      - GetGamePool('CPed'), IsEntityDead, DoesEntityExist, GetEntityCoords,
        PlayerPedId, IsPedInAnyVehicle: client/combat.lua's own
        FindNearestCombatTarget (GetGamePool/IsEntityDead/DoesEntityExist/
        GetEntityCoords/PlayerPedId) and client/agility.lua's TryVault
        (IsPedInAnyVehicle) -- byte-identical usage shape reused here.
      - NetworkGetPlayerIndexFromPed: client/movement.lua's "Attach Leash"
        ox_target onSelect handler, already established.
      - NetworkGetNetworkIdFromEntity: client/combat.lua's
        RequestBiteHold/RequestTakedown/RequestDrag, already established
        (this file's own TriggerServerEvent call mirrors those three
        exactly: `NetworkGetNetworkIdFromEntity(target)` as the sole
        argument to a `john-k9:server:request*` event).
      - SetPedMoveRateOverride: NEVER called directly by this file -- see
        "THE BALANCE PROBLEM" above. This file only ever writes
        K9MoveRateModifiers.pursuitSprint and calls the existing
        RecomputeK9MoveRate(), inheriting that native's own
        already-recorded confidence grading (client/movement.lua's "MOVE-
        RATE COMPOSER" header) rather than introducing a second,
        independent claim about it.
    ======================================================================
]]

if not Config.Features.PursuitSprint then return end

-- ======================================================================
-- CONFIG SHAPE -- CLAMP AND WARN, NOT ASSERT (see server/cooldowns.lua's
-- header ADDENDUM: "does an operator's config.lua edit alone... reach
-- this value? If yes it must be clamped and warned about, never asserted
-- and aborted"). This used to be four hard `assert`s here, deliberately
-- mirroring server/pursuitsprint.lua's own -- but that file has SINCE
-- moved to clamp-and-warn for the exact same reason this one now does: an
-- uncaught error thrown from THIS FILE's own top-level chunk (this guard
-- sits directly after the feature-flag early-return above, no deferring
-- onResourceStart/RegisterNetEvent wrapper around it) aborts
-- client/pursuitsprint.lua's load from that line onward, silently
-- un-registering 'john-k9:vault'-equivalent PursuitSprint keybind/net
-- handlers below, over one operator typo. Mirrors server/pursuitsprint.lua's
-- own ResolveConfiguredPositiveNumber shape (that file's server-only
-- ResolveConfiguredThresholdMs, from server/cooldowns.lua, is not
-- reachable from a client script, so this is a small independent copy of
-- the same idea, not a shared extraction). Resolved values are written
-- BACK into Config.PursuitSprint so every later direct read in this file
-- (durationMs/speedMultiplier/requestRangeMeters are all re-read straight
-- off Config, not captured to a local) sees the same corrected value.
-- ======================================================================
if type(Config.PursuitSprint) ~= 'table' then
    print(
        '[John-K9] WARNING: Config.Features.PursuitSprint is true but Config.PursuitSprint is missing or not ' ..
        'a table -- using this file\'s own built-in defaults (speedMultiplier=1.4, durationMs=5000, ' ..
        'requestRangeMeters=20.0) so the feature still works. Add the settings table back to config.lua.'
    )
    Config.PursuitSprint = {}
end

--- Same clamp-and-warn shape as server/pursuitsprint.lua's own
--- ResolveConfiguredPositiveNumber (a small independent copy -- see this
--- block's header comment above for why it is not shared). Never errors;
--- prints one warning naming the exact key, the bad value found, and the
--- fallback substituted.
--- @param value any
--- @param fallback number
--- @param keyName string
--- @param requirementText string
--- @return number
local function ResolveConfiguredPositiveNumber(value, fallback, keyName, requirementText)
    if type(value) == 'number' and value == value and value > 0 then
        return value
    end
    print(('[John-K9] %s must be %s (found: %s). Using the built-in fallback of %s instead so this feature ' ..
        'keeps working while the config is fixed -- find %s in config.lua and correct it.')
            :format(keyName, requirementText, tostring(value), tostring(fallback), keyName))
    return fallback
end

Config.PursuitSprint.speedMultiplier = ResolveConfiguredPositiveNumber(
    Config.PursuitSprint.speedMultiplier, 1.4, 'Config.PursuitSprint.speedMultiplier', 'a positive number')

Config.PursuitSprint.durationMs = ResolveConfiguredPositiveNumber(
    Config.PursuitSprint.durationMs, 5000, 'Config.PursuitSprint.durationMs', 'a positive number of milliseconds')

Config.PursuitSprint.requestRangeMeters = ResolveConfiguredPositiveNumber(
    Config.PursuitSprint.requestRangeMeters, 20.0, 'Config.PursuitSprint.requestRangeMeters',
    'a positive number of meters')

--- Finds the nearest OTHER live PLAYER'S ped within `rangeMeters` of the
--- local player. DISPLAY-ONLY CONVENIENCE, never the security boundary --
--- server/pursuitsprint.lua independently re-resolves and re-validates the
--- target from scratch (role, distance, player-vs-NPC, wanted status)
--- regardless of what this function picked, exactly like
--- client/combat.lua's own FindNearestCombatTarget's doc comment already
--- states for that file's equivalent search. UNLIKE that function, this
--- one filters to PLAYER peds only (`NetworkGetPlayerIndexFromPed(ped) ~=
--- -1`) -- see server/pursuitsprint.lua's own header for why this feature
--- is player-target-only (a "wanted" flag is a player-only concept in this
--- codebase).
--- @param rangeMeters number
--- @return number? targetPed
local function FindNearestPursuitTarget(rangeMeters)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPed, nearestDist

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= myPed and DoesEntityExist(ped) and not IsEntityDead(ped) and NetworkGetPlayerIndexFromPed(ped) ~= -1 then
            local dist = #(myCoords - GetEntityCoords(ped))
            if dist <= rangeMeters and (not nearestDist or dist < nearestDist) then
                nearestPed, nearestDist = ped, dist
            end
        end
    end

    return nearestPed
end

--- Self-initiated trigger -- bound to a keybind below (this resource has
--- no radial-menu entry for this feature yet; a future client/radial.lua
--- item can call RequestPursuitSprint() directly, the same "radial calls a
--- resource-global" convention every other action in this resource
--- follows).
function RequestPursuitSprint()
    local myPed = PlayerPedId()

    -- Nothing to chase on foot while seated in, or "tucked" into
    -- (client/vehicle.lua's EnterNearestK9Vehicle), a vehicle -- silent,
    -- mirrors client/agility.lua's TryVault and client/combat.lua's own
    -- IsBlockedByVehicleTuck exclusion for the identical state. Soft
    -- dependency on IsInK9Vehicle (`type(...) == 'function'` guard, this
    -- resource's established convention for this exact optional cross-file
    -- read -- see client/agility.lua/client/movement.lua's own identical
    -- guard on this same global).
    if IsPedInAnyVehicle(myPed, false) or (type(IsInK9Vehicle) == 'function' and IsInK9Vehicle()) then
        return
    end

    local targetPed = FindNearestPursuitTarget(Config.PursuitSprint.requestRangeMeters)
    if not targetPed then
        lib.notify({ title = locale('common.notify_title'), description = locale('pursuitsprint.no_target_nearby'), type = 'error' })
        return
    end

    TriggerServerEvent('john-k9:server:requestPursuitSprint', NetworkGetNetworkIdFromEntity(targetPed))
end

RegisterCommand('john-k9:pursuitsprint', function()
    -- KEYBIND SILENCE GATE (live-bug fix) -- a keypress carries no
    -- evidence that a K9 action was intended, so a player who is not a K9
    -- gets nothing at all instead of a refusal toast. See
    -- IsK9KeybindAudience() in client/main.lua for the full writeup of the
    -- city-wide toast spam this closes.
    if not IsK9KeybindAudience() then return end

    RequestPursuitSprint()
end, false)

RegisterKeyMapping('john-k9:pursuitsprint', locale('pursuitsprint.keybind_label'), 'keyboard', 'N')

-- ======================================================================
-- GRANT HANDLING -- see this file's header "NO UNBOUNDED TRAP" for the
-- full invariant this section (together with the onResourceStop handler
-- below) exists to satisfy.
-- ======================================================================

-- Incremented on every genuine grant; an end-timer only ever resets the
-- shared modifier if it is still the MOST RECENT grant's own timer by the
-- time it finishes -- see this file's header for the full reasoning.
local sprintGeneration = 0

--- Shared by the end-timer thread below AND onResourceStop, so there is
--- exactly one place that ever writes K9MoveRateModifiers.pursuitSprint
--- back to neutral -- mirrors client/movement.lua's own "there is exactly
--- one place" discipline for its analogous resets.
local function ResetPursuitSprintModifier()
    if type(K9MoveRateModifiers) == 'table' then
        K9MoveRateModifiers.pursuitSprint = 1.0
    end
    if type(RecomputeK9MoveRate) == 'function' then
        RecomputeK9MoveRate()
    end
end

--- PAYLOAD VALIDATION -- defense in depth, not a security boundary (this
--- event's origin is already restricted to the genuine server by the
--- SOURCE-ORIGIN GUARD below; a server this client trusts enough to accept
--- ANY event from is trusted for these two numbers too). Still validated
--- with the SAME rule this file's own ResolveConfiguredPositiveNumber
--- already applies to a bad config.lua value (positive, finite, non-NaN),
--- so a bug somewhere upstream -- a mis-set tunable override that somehow
--- slipped past server/runtimecontrol.lua's own [min,max] gate, a stale/
--- future version mismatch between the two files -- degrades to this
--- client's OWN last-resolved Config.PursuitSprint default rather than ever
--- reaching RecomputeK9MoveRate()/SetPedMoveRateOverride with an unchecked
--- number. Neither inversion this resource warns against elsewhere is
--- reachable here: a non-positive/NaN speedMultiplier can never silently
--- mean "no boost" or "infinite boost" (rejected outright, falls back to a
--- known-good default), and a non-positive/NaN durationMs can never mean
--- "forever" (the end-timer loop below is a plain `while elapsed <
--- durationMs`, so a non-positive value would otherwise end the burst on
--- its very first 100ms tick -- harmless in this specific direction, but
--- rejected anyway for consistency, so this file never has to reason about
--- which direction is "safe" for a value that should never be reachable in
--- the first place).
--- @param value any
--- @param fallback number
--- @return number
local function ResolveGrantedPositiveNumber(value, fallback)
    if type(value) == 'number' and value == value and value > 0 and value < math.huge then
        return value
    end
    return fallback
end

--- @param speedMultiplier number
--- @param durationMs number
RegisterNetEvent('john-k9:client:pursuitSprintGranted', function(speedMultiplier, durationMs)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD, see this file's header

    -- Soft dependency on client/movement.lua's shared move-rate composer
    -- (`type(...) == 'table'`/`type(...) == 'function'` guards, this
    -- resource's established convention for this exact pair -- see
    -- client/movement.lua's own header: "client/progression.lua's own
    -- defensive... checks"). If either symbol is missing (a renamed or
    -- removed client/movement.lua), this fails CLOSED -- no burst is
    -- ever applied, rather than erroring or applying a native call this
    -- file does not own directly.
    if type(K9MoveRateModifiers) ~= 'table' or type(RecomputeK9MoveRate) ~= 'function' then
        return
    end

    -- APPLY WHAT WAS SENT, NOT THIS CLIENT'S OWN CONFIG COPY -- see this
    -- file's header "EVENT CONTRACT" for the full writeup on why. Falls back
    -- to this client's own last-resolved Config.PursuitSprint defaults only
    -- for a malformed/missing payload -- see ResolveGrantedPositiveNumber's
    -- own doc comment above.
    speedMultiplier = ResolveGrantedPositiveNumber(speedMultiplier, Config.PursuitSprint.speedMultiplier)
    durationMs = ResolveGrantedPositiveNumber(durationMs, Config.PursuitSprint.durationMs)

    sprintGeneration = sprintGeneration + 1
    local myGeneration = sprintGeneration

    K9MoveRateModifiers.pursuitSprint = speedMultiplier
    RecomputeK9MoveRate()
    lib.notify({ title = locale('common.notify_title'), description = locale('pursuitsprint.activated'), type = 'success' })

    -- Feature-scoped thread -- exists ONLY for the bounded lifetime of one
    -- burst (the granted durationMs, a few seconds), never an always-on
    -- loop. Ticks at a fixed 100ms so an in-progress death is noticed
    -- promptly without polling every frame. Captured into a local here
    -- (already was) -- this is now doubly load-bearing, since `durationMs`
    -- is this specific grant's OWN value, not a re-readable Config field a
    -- later live edit could ever retroactively change out from under an
    -- already-running burst (see this file's header "LIVE EDIT MID-SPRINT"
    -- note in server/pursuitsprint.lua for why that is the chosen behavior,
    -- not an oversight).
    local tickMs = 100
    CreateThread(function()
        local elapsed = 0
        while elapsed < durationMs do
            Wait(tickMs)
            elapsed = elapsed + tickMs
            if IsEntityDead(PlayerPedId()) then
                break -- END-ON-DEATH -- never gated on access/cert, see header "NO UNBOUNDED TRAP"
            end
        end

        -- Only the MOST RECENT grant's own end-timer may reset the shared
        -- modifier -- see this file's header for why (guards against a
        -- should-be-impossible, but defended-anyway, stale/overlapping
        -- end-timer).
        if sprintGeneration == myGeneration then
            ResetPursuitSprintModifier()
        end
    end)
end)

-- Same reasoning as client/movement.lua's own
-- lastAppliedMoveRate/isFirstPersonK9View onResourceStop handlers: a
-- resource restart mid-burst must not leave K9MoveRateModifiers.pursuitSprint
-- (and therefore the applied native move-rate override) stuck above
-- neutral forever. Bumps sprintGeneration too, purely for consistency (no
-- thread survives a resource stop regardless -- CreateThread-created
-- coroutines die with the rest of this resource's Lua state -- so this is
-- not load-bearing on its own, just keeps the invariant "generation only
-- ever increases, reset always wins" visibly true).
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    sprintGeneration = sprintGeneration + 1
    ResetPursuitSprintModifier()
end)
