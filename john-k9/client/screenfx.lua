--[[
    john-k9/client/screenfx.lua

    Implements Config.Features.ContrabandScreenFX --
    DEVELOPER_REFERENCE.md §13.4.5 / §13.2 / §13.3's file-plan row for this feature --
    the last Phase 4 feature that had a written spec but no implementation
    anywhere in this resource before this file.

    ======================================================================
    FILENAME/FILE-PLAN DEVIATION -- READ BEFORE ASSUMING THIS MATCHES
    DEVELOPER_REFERENCE.md §13.3'S TABLE VERBATIM:

    §13.3's file-plan row for this feature puts the CLIENT-side handling
    inside `client/search.lua` as an "Extends" entry ("Handles
    john-k9:client:applyContrabandScreenFx -- calls SetTimecycleModifier
    ... Mirrors client/vision.lua's exit-path discipline"). This file
    deliberately does NOT do that -- instead, this file (client/screenfx.lua)
    registers the SAME event name directly and owns 100% of the effect's
    client-side lifecycle itself, entirely independent of client/search.lua.

    This is a strictly smaller footprint than §13.3 sketched, not a
    different design: `RegisterNetEvent` lets any number of client files
    each independently register their own handler for the same event name
    (FiveM fires every registered handler for a given event -- the same
    "an additional CONSUMER, not a replacement" framing DEVELOPER_REFERENCE.md
    §13.0/fxmanifest.lua already uses for server/wellbeing.lua and
    server/tracking.lua both consuming relayDamageEvent/relayWeaponFire).
    client/search.lua therefore needs ZERO changes for this feature to
    work end-to-end -- it never has to know this file exists. The ONLY
    integration point still required is server-side (see "REQUIRED
    SERVER-SIDE HOOK" below), which was already true under §13.3's own
    plan regardless of which client file consumes the event.
    ======================================================================

    Supplementary implementation detail cited below (non-authoritative --
    DEVELOPER_REFERENCE.md §13.4.5 is the source of truth if anything here drifts
    from it): client/vision.lua (this resource's only other file that owns
    a full-screen post-effect native, and the closest structural precedent --
    its "gate at registration," "force off on every exit path," and "the
    native's own state persists with no automatic reset" lessons are all
    reused directly below) and client/audio.lua (this resource's other file
    using the same `if not Config.Features.X then return end` file-scope
    gating shape).

    ======================================================================
    EVENT/CALLBACK CONTRACT -- Phase 4, per DEVELOPER_REFERENCE.md §13.4.5:

    1. 'john-k9:client:applyContrabandScreenFx' (durationMs: number)
       [server->client, REQUESTER ONLY, never a broadcast -- see REQUIRED
       SERVER-SIDE HOOK below]
       Sent from inside server/search.lua's existing searchTarget success
       path once that file's own server-computed alertTier is resolved and
       Config.Features.ContrabandScreenFX + Config.ContrabandScreenFX.
       triggerTiers say it should fire for this result. This file only ever
       CONSUMES this event -- it never triggers it, and has no
       client-triggerable path of its own to request this effect on demand
       (there is no legitimate reason a client would ever need to ask for
       this cosmetic effect outside a real, already-validated search
       result. DEVELOPER_REFERENCE.md §13.4.5's own event contract text is
       explicit on this point).

    TRUST BOUNDARY -- see DEVELOPER_REFERENCE.md#trust-boundary: a
    client-side RegisterNetEvent handler cannot otherwise distinguish a
    genuine server-sent TriggerClientEvent from a local, zero-server-contact
    TriggerEvent('john-k9:client:applyContrabandScreenFx', <anything>)
    self-invocation using only the public Lua API -- that note's own
    §1 finding (graded MEDIUM-HIGH confidence there, not blindly copied
    here as certain) is that `source ~= 65535` inside the handler is the
    documented, official way to reject the self-triggered case (FiveM's
    own "Secure your events" guidance: "The server will send net id 65535
    for events from the server"). Applied below as this handler's first
    statement, matching that convention. Unlike that note's client/combat.lua
    findings (a forged event there could grant invincibility/griefing
    capability), forging THIS event grants no actual advantage to the
    forger -- worst case for a self-triggering cheat menu is applying a
    purely cosmetic, self-only visual effect to their own screen, i.e. the
    same net effect as if this check didn't exist at all -- but the check
    costs one line and keeps this file consistent with the resource-wide
    convention rather than being a silent, unexplained exception to it.

    ======================================================================
    SERVER-SIDE HOOK -- IMPLEMENTED. Live at server/search.lua, firing
    john-k9:client:applyContrabandScreenFx at the resolved alert tier, sent
    to `source` only and never broadcast (broadcasting would hand every nearby
    player a free contraband detector). The block below documents exactly
    what was added there -- do NOT apply it a second time:

    Inside server/search.lua's searchTarget callback success path, after
    `alertTier` is resolved (that file's own `ResolveAlertTier` call,
    already landed) and BEFORE or alongside the existing
    Config.Features.ContrabandAlerts bystander-broadcast block, add:

        if Config.Features.ContrabandScreenFX and Config.ContrabandScreenFX then
            for _, triggerTier in ipairs(Config.ContrabandScreenFX.triggerTiers) do
                if triggerTier == alertTier.alert then
                    TriggerClientEvent('john-k9:client:applyContrabandScreenFx', source, Config.ContrabandScreenFX.durationMs)
                    break
                end
            end
        end

    Sent to `source` (the requesting player) ONLY -- never
    TriggerClientEvent(-1, ...) -- matching DEVELOPER_REFERENCE.md §13.4.5's own
    "requester-only, never target-identifying" framing, the same broadcast
    discipline server/search.lua's own playContrabandAlert broadcast
    already follows for a DIFFERENT (bystander-audible) event. This is a
    read of an already-server-computed, already-trustworthy value
    (alertTier) -- it adds no new trust surface of its own; see
    DEVELOPER_REFERENCE.md §13.4.5's own "Server-authority points" section.

    ======================================================================
    CONFIDENCE NOTE -- SetTimecycleModifier/ClearTimecycleModifier (the
    NATIVES) vs. 'drug_wobbly' (the MODIFIER STRING) are graded SEPARATELY:

    - SetTimecycleModifier / ClearTimecycleModifier as NATIVE FUNCTIONS:
      not independently re-verified against a native-declaration fetch for
      this file, but these are long-standing, extremely widely-used
      FiveM/GTA natives across the ecosystem for exactly this "apply a
      named post-process look, clear it later" shape -- DEVELOPER_REFERENCE.md
      §13.4.5's own reality-check section independently reaches the same
      "confirmed native-only per DEVELOPER_REFERENCE.md §7" conclusion for
      the mechanism. Treated as reasonably high confidence for the native
      call shape itself, distinct from the string below.
    - The specific modifier name is a GENUINE, UNRESOLVED UNCERTAINTY,
      exactly as DEVELOPER_REFERENCE.md §13.4.5 already flags it ("a candidate
      only... no equivalent verification pass has been done for this
      specific modifier name"). This file does NOT hardcode that string --
      it reads Config.ContrabandScreenFX.modifierName (in config.lua) and
      only falls back to the spec's own candidate value if that config
      field is missing, so a future verification pass can correct the real
      value with a one-line config edit, never a code change. Worst case if
      the string is wrong: SetTimecycleModifier silently no-ops (per this
      codebase's own established "an unrecognized name is a harmless
      no-op, not an error" convention, already relied on identically for
      client/main.lua's placeholder bark-sound names) -- the player sees no
      visual effect at all, not a crash, not a stuck-on effect, not a
      gameplay-blocking failure.

    ======================================================================
    INTENSITY / DURATION CONCERN: DEVELOPER_REFERENCE.md §13.2's sketch
    defaults `durationMs` to 8000 (8 seconds). A "wobbly shroom"-family
    timecycle modifier is, by its own name and by every public description
    of that GTA effect family, a strong, saturating, warping full-screen
    look -- not a subtle one. Combined with an 8-second hold, that reads as
    disorienting/gameplay-obscuring, in tension with this feature's own
    brief ("subtle and non-punitive... feedback for the handler, not a
    screen-blocking penalty"). This file does not silently accept whatever
    durationMs Config.ContrabandScreenFX or the event payload carries:
    SCREENFX_MAX_DURATION_MS below hard-clamps the EFFECTIVE duration well
    under the spec's own 8000ms sketch, regardless of what config or the
    event payload requests -- see that constant's own comment for the
    exact number and reasoning. This is a defensible, disclosed judgment
    call by this file, not a silent override -- the config owner is free
    to raise Config.ContrabandScreenFX.durationMs, but this file will not
    honor a value past its own safety ceiling. Recommended (not enforced
    beyond the ceiling) config default: something in the 2500-4000ms
    range, not 8000.

    ======================================================================
    GATING -- "gate at registration, not just inside the handler," the SAME
    convention as client/audio.lua's/client/hud.lua's/client/partnership.lua's
    own file headers, and client/vision.lua's per-toggle Config.Features.*
    gate. This file returns entirely, registering NEITHER the net event
    handler NOR the onResourceStop safety net, while Config.Features.
    ContrabandScreenFX is false -- so a hostile client cannot reach this
    file's logic at all by forging the event when the feature is disabled
    (there is no handler for FiveM to dispatch the forged event to in the
    first place), closing the exact "registered unconditionally, reachable
    even with the feature off" defect class already found and fixed
    elsewhere in this resource (client/combat.lua).
]]

if not Config.Features.ContrabandScreenFX then return end

-- ----------------------------------------------------------------------
-- Tuning constants -- code-local, not Config.* entries, matching how
-- client/audio.lua's AUDIO_MAX_DISTANCE/AUDIO_MAX_LOOP_MS and
-- client/hud.lua's HUD_POLL_TICK_MS are file-local safety/tuning knobs
-- rather than exposed config (these are implementation-detail ceilings,
-- not something a server operator should need to tune per-deployment).
-- ----------------------------------------------------------------------

-- Hard ceiling on the EFFECTIVE applied duration, independent of whatever
-- Config.ContrabandScreenFX.durationMs or the event's own durationMs
-- argument requests -- see this file's header "INTENSITY / DURATION
-- CONCERN" section. Deliberately well under DEVELOPER_REFERENCE.md §13.2's own
-- 8000ms sketch: a strong full-screen post-process effect held for that
-- long reads as disorienting/gameplay-obscuring, in tension with this
-- feature's own "subtle... feedback for the handler, not a
-- screen-blocking penalty" brief. 4 seconds is long enough to register as
-- a distinct "something just happened" cue without meaningfully impairing
-- the player's ability to keep playing through it.
local SCREENFX_MAX_DURATION_MS = 4000

-- Floor on the effective duration -- guards against a durationMs of 0,
-- a negative number, or some other degenerate value making the effect
-- flash on and immediately clear before it could ever register as
-- feedback at all (the entire point of this feature, per DEVELOPER_REFERENCE.md
-- §13.4.5's own "representing the K9 getting a... reaction" framing).
local SCREENFX_MIN_DURATION_MS = 500

-- How often the maintenance thread below re-checks its exit conditions
-- (player death) while the effect is active. Short enough that a death
-- mid-effect clears the modifier promptly rather than leaving it applied
-- on a dead ped's screen for however much of the duration remained --
-- mirrors client/vision.lua's own maintenance thread's 1000ms poll for the
-- identical "detect death, force off" exit path, tightened here since this
-- effect's own total duration is much shorter than a vision toggle's
-- open-ended "until the player turns it off" lifetime.
local SCREENFX_POLL_MS = 250

-- Fallback ONLY if Config.ContrabandScreenFX.modifierName is missing or
-- not a string -- the exact same candidate DEVELOPER_REFERENCE.md §13.2/§13.4.5
-- names, not a value this file invents independently. See this file's
-- header CONFIDENCE NOTE: this string itself is NOT independently verified.
-- VERIFIED: 'drug_wobbly_shroom' does not exist. Every `drug_`-prefixed
-- entry in a 2806-entry game-data extraction was checked and only
-- 'drug_wobbly' is real. The old value would have made this feature a
-- permanent silent no-op with nothing in the logs to explain it.
local FALLBACK_MODIFIER_NAME = 'drug_wobbly'

-- Fallback ONLY if neither the event payload's durationMs nor
-- Config.ContrabandScreenFX.durationMs resolve to a usable number.
-- Deliberately inside this file's own recommended 2500-4000ms range (see
-- header), not the spec sketch's 8000ms, since a fallback path is exactly
-- where this file has no config-supplied value to defer to at all.
local FALLBACK_DURATION_MS = 3000

-- Session-local lifecycle state. Only ever mutated from this file --
-- nothing else in this resource needs to read or drive this effect (no
-- resource-global function is exposed; see the header's file-plan
-- deviation note for why this file is fully self-contained).
local screenFxThreadRunning = false
-- GetGameTimer() timestamp the currently-active effect should clear at.
-- A retrigger while already active (e.g. a second qualifying search result
-- lands before the first effect finishes) EXTENDS this rather than
-- spawning a second competing thread -- see EnsureScreenFxThreadRunning's
-- own comment for why two independent threads racing to clear the same
-- global post-effect would be a real bug, not a hypothetical one.
local screenFxExpiresAt = 0

--- Unconditionally clears the timecycle post-effect. Safe to call whether
--- or not one is actually active -- ClearTimecycleModifier is treated the
--- same way this codebase's own client/vision.lua already treats
--- SetSeethrough(false)/SetNightvision(false): an idempotent "ensure off"
--- call, not a stacking counter, so calling it when nothing is active is a
--- harmless no-op. (Not independently re-verified for this specific
--- native -- extending client/vision.lua's own established reasoning for
--- the same shape of native, not asserting new evidence.)
local function ClearScreenFx()
    ClearTimecycleModifier()
end

--- Starts the maintenance thread that holds the effect on for its
--- (clamped) duration and force-clears it early on death, if it isn't
--- already running. Safe to call on every trigger, including a retrigger
--- while already active -- mirrors client/vision.lua's
--- EnsureVisionMaintenanceThreadRunning()'s own "no-op if already running"
--- guard shape exactly, for the identical reason: a feature most players
--- never trigger should not run any thread at all until it's actually used
--- at least once, and should never end up with two threads simultaneously
--- racing to decide when to clear the same global post-effect (whichever
--- one clears first would cut the other's still-intended hold time short,
--- and whichever clears LAST could re-clear an already-cleared, possibly
--- by-then-different, effect).
local function EnsureScreenFxThreadRunning()
    if screenFxThreadRunning then return end
    screenFxThreadRunning = true

    CreateThread(function()
        -- Deliberately re-reads screenFxExpiresAt every iteration (not
        -- captured once at thread start) so a retrigger's extended expiry
        -- (set by the event handler below, before this function is called
        -- again) is picked up by THIS same loop rather than requiring a
        -- second thread.
        while GetGameTimer() < screenFxExpiresAt do
            Wait(SCREENFX_POLL_MS)

            if IsEntityDead(PlayerPedId()) then
                -- Exit path: death. Mirrors client/vision.lua's own
                -- maintenance thread's death handling exactly (DEVELOPER_REFERENCE.md
                -- §13.4.5 / that file's §11.6-derived discipline: "force off
                -- on every exit path," not just after the timer) -- a dead
                -- player's screen should not stay visually altered for
                -- whatever duration happened to remain.
                break
            end
        end

        ClearScreenFx()
        screenFxThreadRunning = false
    end)
end

-- Listening for this event is the ONLY way this file's logic can run at all
-- (no ox_target option, no command, no keybind -- purely a server-pushed
-- reaction to an already-validated search result, per DEVELOPER_REFERENCE.md
-- §13.4.5's own contract). Registered unconditionally at THIS point in the
-- file only because the file-scope `if not Config.Features.ContrabandScreenFX
-- then return end` guard above already prevented this line from ever
-- executing while the feature is disabled -- this IS the "gate at
-- registration" this file's header commits to, not a redundant inner check
-- duplicated here.
RegisterNetEvent('john-k9:client:applyContrabandScreenFx', function(durationMs)
    -- DEVELOPER_REFERENCE.md#trust-boundary's origin check -- see this
    -- file's header TRUST BOUNDARY section for the full citation and
    -- confidence grading. First statement in the handler body, per that
    -- note's own recommended shape.
    if source ~= 65535 then return end

    -- Per-person block (client/featureblocks.lua, REQUESTED -- see that
    -- file's header for the full contract). This event is the ONLY
    -- acting point this feature has (see this file's own header: no
    -- ox_target option, no command, no keybind) -- checked here, before
    -- the effect is ever applied, rather than at registration. There is
    -- no "already active, force it off early" concern to add on top: this
    -- effect is a short, self-expiring one-shot (SCREENFX_MAX_DURATION_MS
    -- above), not a toggle the player holds, so there is no persistent
    -- state a live block could strand someone in.
    if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('ContrabandScreenFX') then
        return
    end

    local cfg = Config.ContrabandScreenFX
    local modifierName = FALLBACK_MODIFIER_NAME
    if type(cfg) == 'table' and type(cfg.modifierName) == 'string' and cfg.modifierName ~= '' then
        modifierName = cfg.modifierName
    end

    -- Prefer the event payload's own durationMs (this is what
    -- server/search.lua actually sends, per the contract above), falling
    -- back to config, then to this file's own fallback constant --
    -- defensive against a malformed/missing payload from a not-yet-wired
    -- or misconfigured server-side hook rather than trusting the argument
    -- unconditionally.
    local requestedDurationMs = FALLBACK_DURATION_MS
    if type(durationMs) == 'number' then
        requestedDurationMs = durationMs
    elseif type(cfg) == 'table' and type(cfg.durationMs) == 'number' then
        requestedDurationMs = cfg.durationMs
    end

    -- Clamp regardless of source -- see header "INTENSITY / DURATION
    -- CONCERN" -- this ceiling is enforced no matter what config or the
    -- event payload requested.
    requestedDurationMs = math.max(SCREENFX_MIN_DURATION_MS, math.min(SCREENFX_MAX_DURATION_MS, requestedDurationMs))

    SetTimecycleModifier(modifierName)
    -- Extends (never shortens, since this is a fresh assignment based on
    -- "now") the hold time -- a retrigger while already active restarts
    -- the countdown from this moment rather than stacking on top of
    -- whatever remained, which is the simplest behavior that still can't
    -- leave the effect on for less time than a single trigger's own
    -- requested duration.
    screenFxExpiresAt = GetGameTimer() + requestedDurationMs
    EnsureScreenFxThreadRunning()
end)

-- Resource-stop safety net -- mirrors client/vision.lua's ALREADY-SHIPPED
-- onResourceStop pattern for the identical underlying reason (that file's
-- own header, reused verbatim here): SetTimecycleModifier's effect
-- persists across a resource restart independent of script state -- with
-- no script alive to clear it, a player could be stranded with this
-- looking-wobbly full-screen effect on indefinitely. Force off
-- unconditionally regardless of whether this session ever actually
-- triggered the effect (ClearTimecycleModifier is a harmless no-op
-- otherwise, per this file's own ClearScreenFx() comment above). Also
-- covers disconnect, per client/vision.lua's own header reasoning: FiveM
-- stops every currently-loaded resource as part of a player disconnecting,
-- firing this same handler.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    ClearScreenFx()
end)
