--[[
    john-k9/client/vision.lua

    Phase 2. fxmanifest.lua lists this file under client_scripts. Its old
    per-mode key settings were removed with the thermal/night keys; the one
    vision key is k9vision (I).

    CORRECTED (owner's standing "reachable from chat, 3rd eye, and radial"
    audit, this pass) — THIS PARAGRAPH USED TO CLAIM "client/radial.lua
    deliberately gets NO items for this feature (this is keybind-only, by
    design)." That was true when first written, but went stale the moment
    the "CYCLE — EXTRA, OPTIONAL CONVENIENCE" section further down shipped
    and was never revisited here afterward — a comment trusted over the
    code is exactly the bug class this audit exists to catch. THE ACTUAL,
    CURRENT STATE: client/radial.lua has THREE items for thermal/night
    vision today ("Thermal Vision", "Night Vision", and the CycleVision()
    convenience, `k9_vision_cycle`) — see that section below for the full
    history of why radial coverage was added, removed, and restored. THE
    ONE TOGGLE IN THIS FILE STILL WITHOUT A RADIAL ITEM (OR AN ox_target
    OPTION) IS CameraFeedPiP, added in a later pass than the sentence above
    — see this file's own "CAMERA FEED" header section, "SURFACE COVERAGE"
    paragraph, for that decision's OWN, separately-reconsidered reasoning
    (not this same stale claim reapplied to a different feature).

    Owns the two independent thermal/night vision toggle keybinds —
    DEVELOPER_REFERENCE.md §11.1 sub-phase 2a, §11.3's `client/vision.lua` row (new file,
    not folded into client/movement.lua, "vision is a big enough sibling
    concern... to warrant its own file rather than a fourth unrelated
    concern bolted onto that one"). Both toggles mirror
    client/movement.lua's ToggleK9Camera()'s exact shape and gating
    philosophy (a perception/QoL toggle, not a granted departmental
    capability) — see §1 below for the one place that shape is
    DELIBERATELY extended beyond ToggleK9Camera()'s precedent
    (config-gated registration).

    Supplementary implementation detail cited below (non-authoritative —
    DEVELOPER_REFERENCE.md §11 is the source of truth if anything here drifts
    from it): DEVELOPER_REFERENCE.md#vision (the
    revised, §11-reconciled pass — read its own header before trusting
    anything in it that contradicts DEVELOPER_REFERENCE.md §11.5/§11.6 directly) and
    DEVELOPER_REFERENCE.md#vision /
    DEVELOPER_REFERENCE.md#tracking §3 (two independent native
    confirmation passes, both agreeing on the same hashes).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2: NONE. This file registers or
    triggers no network event or callback of any kind — thermal/night
    vision are purely client-local render toggles (DEVELOPER_REFERENCE.md §11.6: "both
    natives are global local-render toggles," no server-side fact to
    check, no other player's state affected). This mirrors
    client/vehicle.lua's own "no dedicated server event" precedent for
    vehicle entry/exit almost exactly, for the identical underlying
    reason (a purely single-player-local cosmetic state with nothing to
    persist or broadcast).
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE will expose four resource-global (no `local`) functions.
      These names are already settled — DEVELOPER_REFERENCE.md §11 left this an open
      naming slot, DEVELOPER_REFERENCE.md#vision §7 filled it, and
      README.md's "Public API for developers (exports/events)" section
      confirms no other design note proposed a competing name for the
      same slot:
        ToggleThermalVision()
        ToggleNightVision()
        IsThermalVisionActive()
        IsNightVisionActive()
      No other Phase 2 file currently needs to call into these (§1 of
      DEVELOPER_REFERENCE.md#vision: "no radial item; no other
      Phase 2 file's design references vision toggling" — HISTORICAL ONLY,
      describing the state AT THE TIME this file was first written, already
      superseded by the very next bullet below and by this file's own
      corrected opening paragraph above; client/radial.lua has three vision
      items today, not zero) — exposed as
      resource-globals anyway, per this codebase's established convention
      that every toggle/action function is a resource-global (see
      README.md's "Public API for developers (exports/events)" section's
      Phase 1 contract table), in case a later phase wants to call in
      from outside this file.
    - A later pass added a FIFTH resource-global: CycleVision(). See the
      "CYCLE — EXTRA, OPTIONAL CONVENIENCE" section further down this file,
      right above its definition, for the full design writeup and its
      current status. OWNER REVERSAL (coder-architect, this pass): that
      pass had temporarily made CycleVision()'s 'k9vision' the ONLY
      discoverable vision control (chat-suggested/tablet-documented),
      demoting ToggleThermalVision()/ToggleNightVision()'s own commands to
      hidden aliases. The owner has since asked for thermal and night
      vision to be separate, first-class controls again — both are back to
      being independently chat-suggested and tablet-documented (see
      client/commandsuggestions.lua, html/tablet.js). CycleVision()/
      'k9vision' is KEPT, per the owner's own steer, as an extra, optional
      convenience alongside the two explicit toggles, not a replacement for
      them — client/radial.lua's "K9 Vision" item is the other caller,
      alongside 'k9vision' below, same "one function, every entry point
      calls it" shape StartCertifiedTrack() established for the scent
      merge.
    - THIS FILE calls client/main.lua's IsOwnModelK9() — see the RESOLVED
      ACCESS-GATING DECISION section immediately below for why this is
      IsOwnModelK9() and explicitly NOT CanShowK9UI().

    ======================================================================
    RESOLVED ACCESS-GATING DECISION (do not re-litigate — settled by
    DEVELOPER_REFERENCE.md §11.5, quoted here so it can't be silently drifted from again):
    thermal/night vision gate on IsOwnModelK9() ONLY, the SAME cheap,
    local, free check client/movement.lua's ToggleK9Camera() already uses
    — NOT CanShowK9UI() (the full server-backed combinator Bark/Sit/
    Leash/Vehicle use). §11.5's own stated reasoning: "thermal/night
    vision is presented in DEVELOPER_REFERENCE.md as the K9's own innate perception, not
    a granted departmental privilege." Apply IDENTICALLY to both Thermal
    and Night vision — §11.5 is explicit that whichever answer is chosen
    must apply to both for consistency with each other.

    HISTORY WORTH KNOWING (not a live disagreement — recorded so nobody
    re-opens this by reading stale material out of order): the FIRST
    draft of DEVELOPER_REFERENCE.md#vision picked the OPPOSITE
    answer (CanShowK9UI()), reasoning by analogy to ScentTracking/
    BloodTracking being certified-K9 capabilities. That note's OWN
    revised pass (§3) explicitly corrects itself once DEVELOPER_REFERENCE.md §11.5
    landed and settled the question the other way — the correction is
    already made in that note; this file's implementation should reflect
    §11.5's settled answer directly, not the earlier draft's guess.

    Practical effect (intentional, not a gap): an uncertified K9-model
    player (or one whose job isn't in Config.Departments) can still
    toggle thermal/night vision, exactly as they can already toggle the
    first/third-person camera.
    ======================================================================

    ======================================================================
    CAMERA FEED (Config.Features.CameraFeedPiP), owner directive: "do
    whatever it takes to finish the CameraFeedPiP." Zero implementing code
    existed anywhere in this resource for this flag before this file
    (confirmed by grep; the only reference was config.lua's own comment
    declaring it impossible, and this file's own header did not mention it
    either). This section is the first real implementation.

    WHAT THIS IS NOT, RE-VERIFIED INDEPENDENTLY, NOT JUST INHERITED FROM
    CONFIG.LUA'S EARLIER RESEARCH: a genuine simultaneous inset (two live
    3D views on screen at once, the literal meaning of "picture-in-picture")
    remains IMPOSSIBLE with documented natives. Verified by live-fetching
    the authoritative CFX native reference
    (https://runtime.fivem.net/doc/natives.json — reachable and used here
    rather than the native-decls repo alone, which only documents
    CFX-specific natives and 404s on ordinary GTA5 natives regardless of
    whether they exist) and enumerating the ENTIRE `CAM` namespace (202
    natives) plus every `RENDERTARGET`-named native (`HUD` namespace:
    REGISTER_NAMED_RENDERTARGET, LINK_NAMED_RENDERTARGET,
    GET_NAMED_RENDERTARGET_RENDER_ID, IS_NAMED_RENDERTARGET_REGISTERED/
    LINKED, RELEASE_NAMED_RENDERTARGET). The render-target natives that DO
    exist let a script draw 2D sprites/text (or a DUI/NUI page, via
    CREATE_RUNTIME_TEXTURE_FROM_DUI_HANDLE) onto a prop's texture (arcade
    cabinets, in-world screens) — none of them render a live 3D scene from
    an arbitrary CAM object into that texture. Nothing in the CAM
    namespace above does the reverse either (there is no
    "render this cam to a texture" native, only natives that manipulate a
    cam's own state or make it the ONE active full-screen view via
    RENDER_SCRIPT_CAMS). This confirms and strengthens config.lua's own
    prior conclusion (citizenfx/fivem#3835 open, no native, no ecosystem
    resource has solved this either) with a positive, dated, sourced
    check against the full namespace, not just a handful of 404s.

    WHAT THIS IS INSTEAD, PER OWNER-APPROVED SCOPE ("a full-screen camera
    view the handler toggles into rather than an inset... build that and
    be explicit about what it is and is not"): ToggleCameraFeed() below
    swaps the LOCAL player's entire view (RENDER_SCRIPT_CAMS) to a script
    camera anchored to their ACTIVE PARTNER's ped (client/partnership.lua's
    HandlerPartnership registry — the two-real-players Partner Up
    mechanic, not a spawned/despawned companion), oriented to match that
    partner's current body rotation every frame, until toggled off again
    or an exit condition fires. This is a real, live, per-frame-updated
    view of what your partner is near and facing — not a texture inset,
    not a recording, not a still image — but it is a full camera SWITCH,
    matching the "full camera switch" category config.lua's own research
    already flagged as the ecosystem's actual practice for this class of
    feature (as opposed to the "cosmetic overlay on your own view"
    category, which this deliberately is not — it is a real second
    vantage point, not decoration).

    GATING — SAME COMBINATOR AS EVERY OTHER DEPARTMENTAL CAPABILITY,
    DELIBERATELY NOT IsOwnModelK9() ALONE (contrast thermal/night vision
    above): CanShowK9UI(), client/main.lua's role/model-decoupled
    combinator. This is the owner's explicit requirement for this feature
    specifically ("it works for a role-holder on any ped... a handler on a
    human body must get it too") satisfied for free, with no new gating
    code invented: under this resource's DEFAULT config
    (Config.K9Appearance.requireK9ModelForRole == false),
    CanShowK9UI() already reduces to `IsK9Role() and HasK9Access()` —
    model-independent by construction — the exact decoupling
    client/appearance.lua's own header cites as landing specifically for
    "I also want everything to work with any ped." A human-modeled
    handler viewing their K9 partner's feed, or a K9-modeled player
    viewing their human handler partner's feed, both pass identically.

    SOFT DEPENDENCY ON client/partnership.lua, SAME CONVENTION AS
    client/hud.lua's GetCurrentXPTier() GUARD: this file never assumes
    Config.Features.HandlerPartnership is on. `IsPartnered`/
    `GetPartnerServerId`/`RefreshPartnershipStateFromServer` are only
    defined resource-globals when that file's own top-of-file gate passed
    — every call site below is guarded with `type(...) == 'function'`
    first, and ToggleCameraFeed() reuses that file's existing
    'partnership.feature_disabled' / 'partnership.not_partnered_with_anyone'
    locale keys verbatim (this resource's established "reuse an existing
    key, don't mint a near-duplicate" convention) rather than inventing
    parallel copies with a different wording.

    DISCLOSED LIMITATIONS (do not silently paper over these — an honest
    partial feature per the owner's own "partial-but-honest beats absent"
    framing, not a feature that quietly does less than it implies):
    1. VANTAGE HEIGHT IS APPROXIMATE, NOT SKELETON-DERIVED. Contrast
       ToggleK9Camera() above, which gets a per-model-correct eye height
       for FREE from SetFollowPedCamViewMode because that native mode
       reads the LOCAL player's own live skeleton — there is no
       equivalent "give me a REMOTE entity's real eye-bone height" native
       exposed to scripts. This file instead anchors the camera to the
       partner ped's root position via a config-tunable, role-specific
       CONSTANT (Config.CameraFeed.k9EyeHeightOffset /
       .handlerEyeHeightOffset), picked by `IsEntityModelK9(partnerPed)`.
       This will look reasonable for a typical human or typical
       configured K9 model and may look slightly high/low for an
       unusually large or small model an operator has added to
       Config.Peds — tune those two constants for your installed models,
       the same "tune this for your roster" posture
       Config.DeployableKennel.propModel's own comment already documents
       for a different asset.
    2. FACING FOLLOWS BODY ROTATION, NOT HEAD/EYE AIM. GetEntityRotation
       is the partner's whole-body yaw/pitch/roll — GTA does not expose a
       ped's independent head/eye aim direction to scripts. The feed
       therefore shows "the direction your partner's body is facing," a
       reasonable proxy, not literally "exactly where their eyes are
       looking" (a human partner looking left without turning their torso
       will not be reflected).
    3. RANGE IS BOUNDED BY ORDINARY FIveM ENTITY STREAMING, NOT ANYTHING
       THIS RESOURCE CONTROLS OR WIDENS. GetPlayerPed(partnerPlayer)
       returns 0 the moment the partner's ped is not currently streamed
       into the local client's world (typically on the order of a few
       hundred meters, dynamic, server/client-streaming-config dependent)
       — ToggleCameraFeed() below detects exactly this (`partnerPed == 0
       or not DoesEntityExist(partnerPed)`) and refuses with a clear
       notification rather than pretending to show a feed it cannot
       render. This is a real, load-bearing constraint on how useful this
       feature is for a partner who is genuinely far away, not a bug to
       silently work around — there is no native that would let this
       resource widen it.
    4. THE LOCAL PLAYER IS BLIND TO THEIR OWN SURROUNDINGS WHILE ACTIVE
       (their entire view is replaced) — FreezeEntityPosition(true) is
       applied for exactly this reason, the same safety posture published
       community "full camera switch" bodycam/cctv resources use (per
       config.lua's own research citation), removed unconditionally the
       moment the feed ends through ANY exit path (manual toggle-off,
       partner disconnect/out-of-range, this player's own death, or losing
       CanShowK9UI() mid-view) — see StopCameraFeed() below, the single
       choke point every exit path routes through, so freezing can never
       be applied without a matching unfreeze on every single exit.

    SURFACE COVERAGE — RE-EXAMINED, NOT MERELY INHERITED (this pass,
    owner's standing "reachable from chat, 3rd eye, and radial" audit
    finding). `john-k9:toggleCameraFeed` is STILL a command + keybind
    only — no radial item, no ox_target option. This file's OWN opening
    header paragraph used to justify that with the SAME sentence applied to
    thermal/night vision too ("client/radial.lua deliberately gets NO items
    for this feature") — that sentence is now corrected up there because it
    went stale for thermal/night vision the moment the CYCLE shipped three
    radial items for it, and it was fair to ask whether it was just as
    stale here, never actually re-examined for CameraFeedPiP specifically.
    IT WAS RE-EXAMINED THIS PASS. The conclusion is unchanged, but for a
    reason specific to this feature, not a carried-over assumption:

    WHY STILL NO RADIAL ITEM: StartCameraFeedAttempt() above only succeeds
    through a STACK of preconditions client/radial.lua's own "Partner Up"/
    "Break Partnership" items do not share — Config.Features.HandlerPartnership
    on, CanShowK9UI(), not feature-blocked, ACTUALLY partnered with someone
    RIGHT NOW (an explicit two-consent opt-in most players are not
    currently in), that partner online, AND that partner's ped currently
    streamed into this client's world. Contrast "Partner Up"'s own doc
    comment (client/radial.lua), which explicitly tolerates its one refusal
    case ("clicking Partner Up while already partnered just costs one
    harmless... round trip") precisely because that refusal is the
    EXCEPTION — the common case for most players, most of the time, is "not
    partnered yet, a nearby candidate exists," which succeeds. CameraFeedPiP
    is the mirror image: for any player who has not separately opted into
    an active partnership right now — the default state for most players,
    most of the time, since it requires a second consenting player and
    starts every session off — a standalone "Camera Feed" radial item would
    refuse with `partnership.not_partnered_with_anyone` EVERY TIME, not
    occasionally, until that player goes and partners up first. That is the
    "menu item that lands on a step which always refuses" failure mode this
    codebase's own radial design already rejects elsewhere — the "WHY
    CameraFeedPiP AND ScentVision ARE NOT STEPS IN THIS CYCLE" section
    earlier in this header made exactly this point about the CYCLE
    specifically; this paragraph is that same finding, re-applied on
    purpose to the standalone-item question this pass actually asked, not
    a stale answer copied across from a different question.

    A DIFFERENT SURFACE WAS CONSIDERED, AND IS NOT RULED OUT — JUST NOT
    BUILT THIS PASS: an ox_target option placed on the ACTIVE PARTNER's own
    ped (rather than a flag-gated radial slot, and unlike every ox_target
    option this resource registers today, which targets a prop/model, not
    a player) would not have the always-refuses problem above — its own
    canInteract would be naturally scoped to "a player currently standing
    near a specific, already-identified, in-range partner," which
    structurally cannot fire for someone with no partner or an
    out-of-range one, sidestepping the failure mode entirely rather than
    merely tolerating it. Left for a genuinely separate design pass instead
    of being folded in as a rushed afterthought to this specific audit
    finding — it deserves its own deliberate treatment (candidate
    resolution against client/partnership.lua's own partner-identification
    precedent, icon/label convention for a player-entity target, whether it
    belongs in this file or that one) rather than a guess bolted on here.
    ======================================================================
]]

--- Thin wrapper over the native's OWN getter — the native is the source of
--- truth for "is thermal vision currently on," not a separately tracked
--- local boolean that could desync from it.
---
--- THE NAME WAS WRONG AND THE FEATURE WAS HALF-DEAD BECAUSE OF IT. This
--- called IsSeethroughActive(), and its sibling below called
--- IsNightvisionActive(). NEITHER NATIVE EXISTS. An unregistered native
--- returns nil forever and logs nothing, so both getters answered false on
--- every call, for every player, on every server, since the day they were
--- written. What that actually broke:
---   * ToggleThermalVision()'s `local turningOn = not IsThermalVisionActive()`
---     was permanently true, so the keybind could only ever switch the
---     effect ON. THERMAL AND NIGHT VISION COULD NOT BE TURNED OFF.
---   * the mutual-exclusion helper never fired, so both could be on at once.
---   * the maintenance thread's `while IsThermalVisionActive() or
---     IsNightVisionActive() do` exited on its first check, making the
---     death-exit, access-loss-exit and live feature-block paths inside it
---     dead code.
---   * client/exports.lua reported false to every other resource.
--- tests/clientvision_spec.lua passed the whole time because it stubbed the
--- made-up names into its own sandbox — the textbook version of a test
--- proving only that the test agrees with itself.
---
--- The real natives, verified against runtime.fivem.net/doc/natives.json
--- (both under GRAPHICS): GET_USINGSEETHROUGH 0x44B80ABAB9D80BD3 and
--- GET_USINGNIGHTVISION 0x2202A3F42C8E5F79, which CitizenFX's Lua name
--- generator exposes as GetUsingseethrough / GetUsingnightvision. Neither
--- has a page under ext/native-decls (both 404), which is normal for a
--- legacy Rockstar native and is NOT evidence of absence — natives.json is
--- the authority here, and the alt:V binding generator, working from the
--- same underlying table, independently produces the same two names.
---
--- Truthiness is handled rather than assumed: natives.json declares a BOOL
--- return, but this codebase has been bitten before by a native handing
--- back 1/0 where `== true` was expected, so anything non-nil and non-zero
--- counts as on.
--- @return boolean
local function NativeReportsActive(value)
    return value ~= nil and value ~= false and value ~= 0
end

--- @return boolean
function IsThermalVisionActive()
    return NativeReportsActive(GetUsingseethrough())
end

--- Thin wrapper over GetUsingnightvision(), same reasoning as above.
--- @return boolean
function IsNightVisionActive()
    return NativeReportsActive(GetUsingnightvision())
end

--- Shared internal helper for the mutual-exclusivity judgment call
--- confirmed (not mandated by the engine) in DEVELOPER_REFERENCE.md §11.5: "Thermal and
--- night vision are mutually exclusive at any given moment (toggling one
--- off the other if both were somehow active)... a reasonable default
--- given both are full-screen post-effects that would otherwise visually
--- conflict." One small shared helper here rather than duplicating the
--- check-and-turn-off logic once per toggle function below, per
--- DEVELOPER_REFERENCE.md#vision §4's explicit implementation-shape
--- recommendation.
--- @param keepingActive 'thermal'|'night'  -- the effect about to be turned ON; turn OFF whichever of the two this is NOT
local function EnsureOnlyOneVisionEffectActive(keepingActive)
    -- Checked via the Is*Active() getters above (authoritative,
    -- native-backed), never a locally-tracked boolean that could desync —
    -- same reasoning as the getters themselves.
    if keepingActive == 'thermal' and IsNightVisionActive() then
        SetNightvision(false)
    elseif keepingActive == 'night' and IsThermalVisionActive() then
        SetSeethrough(false)
    end
end

-- Maintenance/cleanup thread lifecycle guard — see the thread definition
-- further below for the full shape. Started explicitly from each
-- Toggle*Vision() function's "turning on" branch rather than an
-- always-idling poll (unlike client/movement.lua's leash thread, which can
-- afford to idle at 1000ms forever since it's a single perpetual thread for
-- a Phase 1 feature already always loaded) — this resource's own
-- established performance posture: a feature most players never touch
-- should not run any thread at all until it's actually used at least once.
local visionMaintenanceThreadRunning = false

--- Starts the maintenance/cleanup thread (see below) if it isn't already
--- running. Safe to call from both Toggle*Vision() functions on every
--- "turning on" transition — a no-op if the thread is already active.
local function EnsureVisionMaintenanceThreadRunning()
    if visionMaintenanceThreadRunning then return end
    visionMaintenanceThreadRunning = true

    CreateThread(function()
        -- Captured once at thread start, then refreshed every tick below —
        -- this is what makes the HasK9Access() check a TRANSITION check
        -- (true -> false) rather than a plain "is it currently false"
        -- check. This distinction matters: the toggle itself is
        -- deliberately gated on IsOwnModelK9() only (see the RESOLVED
        -- ACCESS-GATING DECISION in this file's header), so a player who
        -- never had K9 access at all (always false) must NOT have their
        -- vision force-cleared by this thread every tick — only a player
        -- who HAD access and just lost it gets the one-time defensive
        -- clear.
        local hadK9Access = HasK9Access()

        while IsThermalVisionActive() or IsNightVisionActive() do
            Wait(1000) -- cleanup/safety poll, not a rendering concern — no sub-frame precision needed

            if IsEntityDead(PlayerPedId()) then
                -- §11.6's "player death" exit path — not automatic, the
                -- natives have "no automatic reset" full stop.
                SetSeethrough(false)
                SetNightvision(false)
            elseif not IsOwnModelK9() then
                -- The player's live model has stopped being a configured
                -- K9 model (the same rare appearance-swap edge case DEVELOPER_REFERENCE.md
                -- §9 item 8 flags for certification) — a direct corollary
                -- of the exact gate Toggle*Vision() already uses: if the
                -- gate that allows turning it on no longer holds, the same
                -- check should also be able to turn it back off.
                SetSeethrough(false)
                SetNightvision(false)
            else
                -- Deliberate ~1s-latency POLLING detection, not an event
                -- push — a one-time defensive UX courtesy (§11.6: "a player
                -- left in a stuck thermal/NV view after losing K9 access
                -- would be a real bug"). Does NOT, and structurally cannot,
                -- prevent the player from immediately toggling it back on a
                -- moment later, since the toggle itself is gated on
                -- IsOwnModelK9() only, never on HasK9Access() — this is not
                -- a persistent "vision disabled while uncertified" state
                -- machine.
                local hasK9Access = HasK9Access()
                if hadK9Access and not hasK9Access then
                    SetSeethrough(false)
                    SetNightvision(false)
                end
                hadK9Access = hasK9Access
            end

            -- Per-person block, applied LIVE to an ALREADY-ACTIVE effect --
            -- see client/featureblocks.lua's own header: "a block applied
            -- while someone is already using night vision should take
            -- effect". Independent per-effect (blocking one must not force
            -- the other off) and independent of the death/access-loss
            -- branches above -- this poll already runs every 1000ms
            -- regardless, so no new thread is needed for this to become
            -- live within that same ~1s latency this thread's own comment
            -- above already discloses for its other exit paths.
            if type(IsK9FeatureBlocked) == 'function' then
                if IsThermalVisionActive() and IsK9FeatureBlocked('ThermalVision') then
                    SetSeethrough(false)
                end
                if IsNightVisionActive() and IsK9FeatureBlocked('NightVision') then
                    SetNightvision(false)
                end
            end
        end

        -- Once both effects are off (checked at the top of the loop above,
        -- including immediately after this iteration's own force-off), the
        -- thread exits — no reason to keep polling once there's nothing
        -- left to clean up. The next Toggle*Vision() call that turns
        -- something on calls EnsureVisionMaintenanceThreadRunning() again.
        visionMaintenanceThreadRunning = false
    end)
end

--- Toggles GTA's built-in heat-vision effect. DEVELOPER_REFERENCE.md §11.5/§11.6:
--- SetSeethrough(BOOL) — confirmed real, toggle-and-forget (no per-frame
--- re-assertion needed to HOLD the effect, only the maintenance/cleanup
--- thread further below is needed, and only while at least one vision
--- effect is active).
--- See RESOLVED ACCESS-GATING DECISION above: gates on IsOwnModelK9()
--- only, NOT CanShowK9UI().
---
--- GATE-THE-START-NEVER-THE-STOP FIX (vision merge pass, coder-architect):
--- the IsOwnModelK9() check below used to run UNCONDITIONALLY, before
--- `turningOn` was even computed -- so a player already IN thermal vision
--- who stopped being IsOwnModelK9() (an appearance swap mid-session, or
--- simply this getting called from CycleVision() below after some other
--- exit condition already flipped) could not turn it back OFF through this
--- function at all; only the separate 1000ms maintenance-thread poll would
--- eventually notice and force it off. That is a latent version of exactly
--- the "stuck in thermal with no way out" trap this resource's own standing
--- doctrine exists to prevent -- the maintenance thread covers it within
--- ~1s, but a direct, immediate stop request should never be refused for a
--- reason that only matters for STARTING. Moved inside the `if turningOn`
--- branch below, alongside the per-person block check (which already had
--- this right) -- turning off is now unconditional, matching every other
--- release/termination path in this resource (DetachLeash(),
--- ReleaseBiteHold(), StopCameraFeed(), etc.).
function ToggleThermalVision()
    local turningOn = not IsThermalVisionActive()

    if turningOn then
        if not IsOwnModelK9() then
            lib.notify({ title = locale('common.notify_title'), description = locale('common.not_k9_model'), type = 'error' })
            return
        end

        -- Per-person block (client/featureblocks.lua -- see that file's
        -- header for the full contract). Checked ONLY on the turning-ON
        -- branch, never on turning off -- this must never be able to trap
        -- someone with thermal vision stuck active. `type(...) ==
        -- 'function'` guard per this resource's soft-dependency convention:
        -- if client/featureblocks.lua is not yet loaded, this degrades to
        -- "never blocked", the correct fail-open direction.
        if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('ThermalVision') then
            if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
            return
        end

        -- Mutual exclusion happens BEFORE flipping this effect on, per
        -- DEVELOPER_REFERENCE.md#vision §4's ordering.
        EnsureOnlyOneVisionEffectActive('thermal')
    end

    SetSeethrough(turningOn)
    lib.notify({
        title = locale('common.notify_title'),
        description = turningOn and locale('vision.thermal_on') or locale('vision.thermal_off'),
        type = 'info',
    })

    if turningOn then
        EnsureVisionMaintenanceThreadRunning()
    end
end

--- Toggles GTA's built-in night-vision-goggle effect. DEVELOPER_REFERENCE.md §11.5/§11.6:
--- SetNightvision(BOOL) — confirmed real, same toggle-and-forget shape as
--- thermal above. Identical shape to ToggleThermalVision() above,
--- substituting SetNightvision/IsNightVisionActive and
--- EnsureOnlyOneVisionEffectActive('night').
---
--- GATE-THE-START-NEVER-THE-STOP FIX -- see ToggleThermalVision()'s
--- identical fix immediately above for the full writeup; same bug, same
--- fix, mirrored here.
function ToggleNightVision()
    local turningOn = not IsNightVisionActive()

    if turningOn then
        if not IsOwnModelK9() then
            lib.notify({ title = locale('common.notify_title'), description = locale('common.not_k9_model'), type = 'error' })
            return
        end

        -- Per-person block -- see ToggleThermalVision()'s identical block
        -- above for the full contract/reasoning; checked ONLY on the
        -- turning-ON branch, never on turning off.
        if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('NightVision') then
            if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
            return
        end

        EnsureOnlyOneVisionEffectActive('night')
    end

    SetNightvision(turningOn)
    lib.notify({
        title = locale('common.notify_title'),
        description = turningOn and locale('vision.night_on') or locale('vision.night_off'),
        type = 'info',
    })

    if turningOn then
        EnsureVisionMaintenanceThreadRunning()
    end
end

-- ======================================================================
-- CYCLE — EXTRA, OPTIONAL CONVENIENCE — 'k9vision' (STATUS, owner
-- reversal, coder-architect, this pass: "I want the thermal and night
-- vision separate"). HISTORY, so this section is not silently re-read out
-- of order: an earlier decluttering pass built this cycle AND demoted
-- ToggleThermalVision()/ToggleNightVision()'s own commands to hidden
-- aliases, making 'k9vision' the only chat-suggested/tablet-documented
-- vision control. The owner has since reversed that specific part of the
-- decision — thermal and night vision are separate, first-class controls
-- again (their own command, own keybind, own radial entry, both visible in
-- chat autocomplete and the tablet's Commands tab: see
-- client/commandsuggestions.lua, html/tablet.js). THE CYCLE ITSELF IS KEPT,
-- per the owner's own explicit steer ("keep it as an extra... it costs
-- nothing, someone may prefer it") — this section documents it as exactly
-- that: an extra, optional convenience alongside the two explicit toggles,
-- never their replacement, discoverable through its own command + radial
-- item + keybind ('k9vision', default I) but not the primary or only way
-- to reach either mode.
--
-- WHY A CYCLE SHAPE STILL WORKS HERE EVEN AS AN EXTRA, NOT A COPY OF THE
-- SCENT MERGE — read before touching this again. Scent's three track types
-- merged into ONE action (StartCertifiedTrack(), client/tracking.lua)
-- because they are three ALTERNATIVE ANSWERS to one one-shot question
-- ("what should my K9 search for"), resolved server-side from
-- certification and fired once. Vision is a different shape: Thermal/Night
-- are HELD STATES a player stays in, not actions that fire and finish, and
-- there is no server-side fact ("this player is certified for X") to
-- resolve which one they want — a bare press-to-cycle genuinely can walk
-- past the mode someone wanted, in a way re-running a search cannot. Two
-- things keep that survivable rather than making the cycle a worse control
-- than just using the two explicit toggles directly:
--   1. The cycle is only 3 stops long (Off -> Night -> Thermal -> Off), so
--      the absolute worst case is one extra press, not a long menu to walk
--      past.
--   2. THE TWO EXPLICIT TOGGLES ARE THE PRIMARY, FIRST-CLASS CONTROLS,
--      UNCHANGED, FOREVER. A player who wants Thermal specifically and
--      doesn't want to think about cycle position presses K (or
--      /john-k9:toggleThermalVision) directly — that is now the
--      documented, discoverable default again, with the cycle as the
--      bonus, not the other way around.
--
-- WHY CameraFeedPiP AND ScentVision ARE NOT STEPS IN THIS CYCLE.
-- Config.FeatureGroups.Sensory's own comment (config.lua) already states
-- this: "CameraFeedPiP... own entry point, requires an active partnership,
-- deliberately not folded into the night/thermal cycle" — this reflects
-- that pre-existing, config-documented decision, not a new one invented
-- here. Two independent reasons, matching docs/history/FEATURE_STRUCTURE_SPEC.md
-- §2.1/§5's Sensory row:
--   - CameraFeedPiP needs AN ACTIVE, IN-RANGE PARTNER to mean anything at
--     all. Folding it into a flag-gated cycle would mean the cycle could
--     land on a step that always refuses (no partner online / partner out
--     of range) purely because it was that step's "turn" — precisely the
--     "lands on it and refuses" failure mode this shape was explicitly
--     built to avoid. A partner-dependent action stays its own explicit
--     entry point (`john-k9:toggleCameraFeed`, untouched), the same way
--     a removed feature's own pick/cancel stayed outside Detection's
--     merged entry point for an analogous "different precondition, cannot
--     silently inherit a shared gate" reason.
--   - ScentVision (client/tracking.lua, out of this file's edit scope
--     entirely) is a live, continuously-polling nearest-trails overlay
--     with its own three-way mode (`always`/`keybind`/`off`,
--     Config.Tracking.ScentVision.mode) and its own per-tick cost profile
--     — a materially different resource/perf shape than a toggle-and-forget
--     native post-effect. It keeps its own keybind (`k9scentvision`,
--     client/keybinds.lua) exactly as docs/history/FEATURE_STRUCTURE_SPEC.md §2.1 says
--     it should.
--
-- GATE-THE-STOP RULE, APPLIED TO THE CYCLE ITSELF: stepping to a mode
-- (`night`/`thermal`) reuses Toggle*Vision() above unchanged, so starting a
-- mode is gated exactly as it always was (IsOwnModelK9() + the per-person
-- block, both fixed above to run ONLY on their own turning-ON branch).
-- Stepping TOWARD 'off' never consults either gate — see
-- DispatchVisionTransition() below, which always turns off whatever is
-- ACTUALLY active (read from the native-backed Is*VisionActive() getters,
-- never from what the availability-filtered cycle THINKS should be active)
-- regardless of whether that mode's flag is still on, still unblocked, or
-- even still in the cycle at all. A mode that goes from available to
-- blocked/disabled WHILE a player is actively using it (a live tablet
-- flip, a featureblocks push) is not stranded: the very next `k9vision`
-- press routes straight to 'off' for it, same as pressing that mode's own
-- explicit toggle key would.
-- ======================================================================

--- Ordered set of the real modes CycleVision() steps through. 'off' is not
--- listed — it is not a Config.Features-gated destination; it is always
--- reachable, by construction (DispatchVisionTransition() below), matching
--- this resource's "never gate a stop" doctrine.
local VISION_CYCLE_MODES = { 'night', 'thermal' }

--- @return 'off'|'night'|'thermal' — native-backed, authoritative, same
--- reasoning as Is*VisionActive() above (never a locally tracked flag that
--- could desync from the real native state).
local function GetActiveVisionMode()
    if IsThermalVisionActive() then return 'thermal' end
    if IsNightVisionActive() then return 'night' end
    return 'off'
end

--- Whether CycleVision() is allowed to STEP INTO this mode right now — the
--- one place the cycle pre-filters, so pressing the key can never land on
--- (and then have to refuse) a mode that is flagged off or currently
--- feature-blocked. Deliberately does NOT check IsOwnModelK9() here — that
--- gate is about the PLAYER, not the mode, and is left to Toggle*Vision()'s
--- own turning-ON branch to enforce at the moment a step is actually taken
--- (same division of labour client/tracking.lua's server-side per-candidate
--- re-check already uses for the scent merge: this function narrows which
--- modes are worth offering, the real gate still runs where the action
--- actually happens).
--- @param mode 'night'|'thermal'
--- @return boolean
local function IsVisionModeAvailable(mode)
    local featureKey = mode == 'night' and 'NightVision' or 'ThermalVision'
    if not Config.Features[featureKey] then return false end
    if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked(featureKey) then return false end
    return true
end

--- Turns the cycle's decision (`targetMode`) into the one native-backed
--- call that gets there, given what is ACTUALLY active (`currentMode`) —
--- never assumes the two must agree, because the whole point of routing
--- 'off' through here is to handle the case where they don't (see this
--- section's own "GATE-THE-STOP RULE" header comment).
--- @param currentMode 'off'|'night'|'thermal'
--- @param targetMode 'off'|'night'|'thermal'
local function DispatchVisionTransition(currentMode, targetMode)
    if targetMode == 'off' then
        -- Turn off whichever mode is ACTUALLY running, not whichever the
        -- availability-filtered sequence expected — see this function's own
        -- doc comment. Toggle*Vision() called against the mode that is
        -- ACTIVE always computes turningOn = false internally, which (after
        -- this pass's gate-the-start-not-the-stop fix above) never consults
        -- IsOwnModelK9()/the block check, so this is unconditional in
        -- practice, not just in intent.
        if currentMode == 'night' then
            ToggleNightVision()
        elseif currentMode == 'thermal' then
            ToggleThermalVision()
        end
        return
    end

    if targetMode == 'night' then
        ToggleNightVision()
    elseif targetMode == 'thermal' then
        ToggleThermalVision()
    end
end

--- THE MERGED ACTION. Steps Off -> Night -> Thermal -> Off, skipping any
--- mode IsVisionModeAvailable() says is not worth offering right now.
--- Both `k9vision`'s command handler and client/radial.lua's "K9 Vision"
--- item call this directly, same "one function, every entry point calls
--- it" shape as client/tracking.lua's StartCertifiedTrack().
function CycleVision()
    local sequence = { 'off' }
    for _, mode in ipairs(VISION_CYCLE_MODES) do
        if IsVisionModeAvailable(mode) then
            sequence[#sequence + 1] = mode
        end
    end

    local currentMode = GetActiveVisionMode()

    if #sequence == 1 then
        -- Neither Night nor Thermal is available right now (both disabled,
        -- or both currently feature-blocked).
        if currentMode == 'off' then
            -- Nothing to offer and nothing running -- an honest, explicit
            -- "there is nothing here" notify beats a silent no-op a player
            -- would read as a missed keypress.
            lib.notify({ title = locale('common.notify_title'), description = locale('vision.no_modes_available'), type = 'error' })
            return
        end

        -- Something is ACTIVE despite being unavailable right now (a block
        -- or a live flag flip landed mid-use) -- route straight to the
        -- universal, ungated stop rather than pretending there is a "next"
        -- position to cycle to. See this section's own "GATE-THE-STOP RULE".
        DispatchVisionTransition(currentMode, 'off')
        return
    end

    local currentIndex
    for i, mode in ipairs(sequence) do
        if mode == currentMode then
            currentIndex = i
            break
        end
    end

    -- currentIndex is ALWAYS found when currentMode == 'off' ('off' is
    -- unconditionally sequence[1], set at this function's own top, so a
    -- fresh Off -> Night press correctly wraps to sequence[2] below) and
    -- whenever currentMode is a mode IsVisionModeAvailable() currently
    -- allows. It is nil ONLY when a mode is ACTIVE despite no longer being
    -- available (a live block/flag-flip landed mid-use) -- in that one
    -- case, route straight to the universal stop rather than guess a "next"
    -- position for a mode that is not even in the cycle right now. See this
    -- section's own "GATE-THE-STOP RULE" header comment.
    local targetMode = currentIndex and sequence[(currentIndex % #sequence) + 1] or 'off'

    DispatchVisionTransition(currentMode, targetMode)
end

-- Registered UNCONDITIONALLY, matching client/tracking.lua's StartCertifiedTrack()
-- / 'k9track' precedent: this is an EXTRA, OPTIONAL entry point (see this
-- file's own "CYCLE — EXTRA, OPTIONAL CONVENIENCE" section above) with no
-- dedicated Config.Features flag of its own (Config.FeatureGroups.Sensory
-- has no single "Vision" base flag the way Detection has ScentTracking) --
-- IsVisionModeAvailable() above already re-checks each real mode's own flag
-- and block state on every single press, so a second, coarser gate on
-- registration here would only make this command's existence diverge from
-- what pressing it actually does. Unlike the two explicit per-mode toggles
-- below (still conditionally registered on their OWN flag, unchanged, and
-- the PRIMARY, first-class controls), this command's job is precisely to
-- exist and say "nothing available" when both underlying modes are off,
-- the same honest-degrade posture client/tracking.lua's 'k9track' already
-- established for "certified for nothing right now."
RegisterCommand('k9vision', function()
    -- KEYBIND SILENCE GATE (live-bug fix) -- a keypress carries no
    -- evidence that a K9 action was intended, so a player who is not a K9
    -- gets nothing at all instead of a refusal toast. See
    -- IsK9KeybindAudience() in client/main.lua for the full writeup of the
    -- city-wide toast spam this closes.
    if not IsK9KeybindAudience() then return end

    CycleVision()
end, false)

RegisterKeyMapping('k9vision', locale('vision.cycle_keybind_label'), 'keyboard', 'I')

-- ----------------------------------------------------------------------
-- CAMERA FEED (Config.Features.CameraFeedPiP) — see this file's header
-- "CAMERA FEED" section for the full contract, what this is/is not, the
-- gating rationale, and the disclosed limitations. Everything below is a
-- direct implementation of that section.
-- ----------------------------------------------------------------------

-- DEFENSIVE FALLBACK, NOT THE REAL TUNING SOURCE: this file does not own
-- config.lua, so it cannot guarantee Config.CameraFeed stays in sync with
-- Config.Features.CameraFeedPiP if the two are ever edited separately.
-- Missing config for an ENABLED feature must degrade to a sane default,
-- never a hard top-level-chunk error that would also take down
-- ThermalVision/NightVision above (a `Config.CameraFeed.x` index on a nil
-- table at file-load time inside the registration block below would do
-- exactly that) -- this table is consulted everywhere below instead of
-- reading `Config.CameraFeed` directly. Real values from config.lua (now
-- shipped, matching these exactly) win the moment that table exists;
-- these constants are the fallback defaults, used only if config.lua
-- is ever missing this table.
local CAMERA_FEED_DEFAULTS = {
    fov = 50.0,
    k9EyeHeightOffset = 0.65,
    handlerEyeHeightOffset = 1.6,
}

--- @return table
local function GetCameraFeedConfig()
    if type(Config.CameraFeed) == 'table' then return Config.CameraFeed end
    return CAMERA_FEED_DEFAULTS
end

--- Local-only state for the currently-active camera feed, if any. Never
--- read from another file — StopCameraFeed()/ToggleCameraFeed() are the
--- only mutators, mirroring this file's own `visionMaintenanceThreadRunning`
--- convention above (file-local, not exposed).
--- @type { active: boolean, cam: number?, partnerServerId: number? }
local cameraFeedState = {
    active = false,
    cam = nil,
    partnerServerId = nil,
}

--- Single choke point for ending an active camera feed, from ANY exit
--- path (manual toggle-off, partner disconnect/out-of-range, own death,
--- losing CanShowK9UI() mid-view, or this resource stopping). Every path
--- routes through here so the render-cams-off / cam-destroy / unfreeze
--- triple can never be applied partially or skipped on one path but not
--- another — the same "one place every exit path shares" discipline
--- client/movement.lua's DetachLeash() and this file's own
--- EnsureVisionMaintenanceThreadRunning() cleanup already apply elsewhere
--- in this resource. Safe to call when no feed is active (no-op) or more
--- than once (idempotent) — every native call below is itself idempotent
--- or guarded by an existence check first.
--- @param notifyLocaleKey string? -- locale key to notify with, or nil for a silent stop (this resource stopping, no player-facing message needed)
local function StopCameraFeed(notifyLocaleKey)
    if not cameraFeedState.active then return end

    -- Order matters: stop rendering the script cam BEFORE destroying it
    -- (destroying an actively-rendering cam with nothing else to fall
    -- back on is the class of bug this resource's own "reverse sticky
    -- native state in the right order" convention exists to avoid — see
    -- client/vehicle.lua's onResourceStop header for the general
    -- statement of this principle).
    RenderScriptCams(false, true, 350, true, false)
    if cameraFeedState.cam and DoesCamExist(cameraFeedState.cam) then
        SetCamActive(cameraFeedState.cam, false)
        DestroyCam(cameraFeedState.cam, false)
    end

    local localPed = PlayerPedId()
    if DoesEntityExist(localPed) then
        FreezeEntityPosition(localPed, false)
    end

    cameraFeedState.active = false
    cameraFeedState.cam = nil
    cameraFeedState.partnerServerId = nil

    if notifyLocaleKey then
        lib.notify({ title = locale('common.notify_title'), description = locale(notifyLocaleKey), type = 'info' })
    end
end

-- Maintenance thread lifecycle guard for the camera feed — same
-- "started explicitly on the turning-on transition, exits itself once
-- there is nothing left to do" shape as `visionMaintenanceThreadRunning`
-- above, kept as an independent flag/thread rather than folded into that
-- one: thermal/night vision's maintenance thread polls at 1000ms
-- (a cleanup/safety net, not a rendering concern, per that thread's own
-- comment); this one must run every frame while active to keep the
-- camera's rotation tracking the partner's live body rotation smoothly,
-- an entirely different responsiveness requirement that would force the
-- shared thermal/night thread to needlessly tighten to Wait(0) forever
-- for a feature most sessions never touch.
local cameraFeedThreadRunning = false

--- Starts the per-frame camera-feed tracking/exit-condition thread if it
--- isn't already running. Wait(0) is deliberate and correctly scoped, not
--- a stray tight loop left running: this thread does not exist at all
--- until ToggleCameraFeed() turns a feed on, and it exits itself the
--- instant that feed ends through any path (see the `while
--- cameraFeedState.active do` loop condition below) — the same "no thread
--- at all until actually used, exits the moment there's nothing left to
--- do" posture EnsureVisionMaintenanceThreadRunning() above already
--- documents, applied here at Wait(0) instead of Wait(1000) because
--- smooth per-frame rotation tracking (this file's header, disclosed
--- limitation 2) is the entire point of this specific thread while it
--- runs, not a cleanup poll.
local function EnsureCameraFeedThreadRunning()
    if cameraFeedThreadRunning then return end
    cameraFeedThreadRunning = true

    CreateThread(function()
        while cameraFeedState.active do
            Wait(0)

            if IsEntityDead(PlayerPedId()) then
                StopCameraFeed('cameraFeed.feed_ended_own_death')
                break
            end

            if not CanShowK9UI() then
                StopCameraFeed('cameraFeed.feed_ended_access_lost')
                break
            end

            -- Per-person block, applied LIVE to an already-active feed --
            -- see client/featureblocks.lua's own header. This thread
            -- already runs every frame (Wait(0), see this function's own
            -- header comment) while a feed is active, so a block applied
            -- mid-feed ends it on the very next frame, not merely on the
            -- next ToggleCameraFeed() attempt. `type(...) == 'function'`
            -- guard: fails open if client/featureblocks.lua has not
            -- loaded.
            if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('CameraFeedPiP') then
                StopCameraFeed('cameraFeed.feed_ended_blocked')
                break
            end

            -- Cheap, local, synchronous read (see client/partnership.lua's
            -- own doc comment on IsPartnered()) — no round trip every
            -- frame. Only reachable here with `type(...) == 'function'`
            -- already true (ToggleCameraFeed() could not have started this
            -- thread otherwise), guarded again anyway per this resource's
            -- established soft-dependency convention.
            if type(IsPartnered) == 'function' and not IsPartnered() then
                StopCameraFeed('cameraFeed.feed_ended_partner_lost')
                break
            end

            -- Re-resolved FRESH every tick, never cached across frames:
            -- a player ped handle is not guaranteed stable across a
            -- respawn, and GetPlayerPed/GetPlayerFromServerId are cheap
            -- local natives, not network round trips — caching either
            -- here would risk driving the camera off a stale handle after
            -- exactly the kind of transition (partner death/respawn) this
            -- feed most needs to survive gracefully.
            local partnerPlayer = GetPlayerFromServerId(cameraFeedState.partnerServerId)
            if not partnerPlayer or partnerPlayer == -1 then
                StopCameraFeed('cameraFeed.feed_ended_partner_lost')
                break
            end

            local partnerPed = GetPlayerPed(partnerPlayer)
            if not partnerPed or partnerPed == 0 or not DoesEntityExist(partnerPed) then
                StopCameraFeed('cameraFeed.feed_ended_partner_lost')
                break
            end

            -- Disclosed limitation 2 (this file's header): whole-body
            -- rotation, not independent head/eye aim -- no native exposes
            -- the latter for a remote ped.
            local rot = GetEntityRotation(partnerPed, 2)
            SetCamRot(cameraFeedState.cam, rot.x, rot.y, rot.z, 2)
        end

        cameraFeedThreadRunning = false
    end)
end

-- STALE-CAM GUARD (same bug class as client/kennel.lua's own
-- "STALE-KENNEL GUARD" and client/fetch.lua's own "STALE-CARRY GUARD" --
-- read either one first, not re-derived here -- and the identical
-- re-entrancy shape as client/agility.lua's own `vaultInProgress` around
-- TryVault()'s async obstacle sweep). StartCameraFeedAttempt() below calls
-- RefreshPartnershipStateFromServer(), which YIELDS (client/partnership.lua's
-- own doc comment: "an ox_lib callback round-trip"). `cameraFeedState.active`
-- is only ever set true at the very end of a successful attempt, AFTER that
-- yield returns -- so a second ToggleCameraFeed() dispatch (keybind
-- double-press, engine auto-repeat, or two inputs landing in the same/
-- adjacent frame) arriving while a first attempt's own round trip is still
-- in flight would see `cameraFeedState.active` as still false, run its own
-- independent StartCameraFeedAttempt(), and its own `cameraFeedState.cam =
-- cam` assignment at the end would silently overwrite the first attempt's
-- only handle to the cam IT already created via CreateCam -- orphaned,
-- DestroyCam never called on it, StopCameraFeed()/onResourceStop below can
-- only ever destroy whichever cam happens to still be in
-- `cameraFeedState.cam` when they run. This flag closes that window: a
-- second call arriving while a start attempt is already in flight is
-- rejected outright, silently, same posture as `vaultInProgress`'s own
-- rejection branch.
local cameraFeedStartInProgress = false

--- Runs every gate + the actual CreateCam/attach/activate sequence for
--- starting a camera feed. Extracted out of ToggleCameraFeed() so that
--- function can wrap this ENTIRE sequence (every internal `return` included)
--- in the cameraFeedStartInProgress guard above with a single set/call/clear,
--- rather than needing that guard reset duplicated at every one of this
--- function's own early-return branches.
local function StartCameraFeedAttempt()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- Per-person block -- checked here (the STARTING branch only; the
    -- `cameraFeedState.active` early-return above already lets an
    -- already-active feed be stopped unconditionally, per this resource's
    -- "termination must never be gated" posture this function's own doc
    -- comment already states). `type(...) == 'function'` guard: fails
    -- open (never blocked) if client/featureblocks.lua has not loaded.
    if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('CameraFeedPiP') then
        if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
        return
    end

    -- SOFT DEPENDENCY (this file's header) -- client/partnership.lua may
    -- not have registered these resource-globals at all if
    -- Config.Features.HandlerPartnership is false. Reuses that file's own
    -- 'partnership.feature_disabled' key verbatim rather than minting a
    -- near-duplicate, per this resource's established locale convention.
    if type(RefreshPartnershipStateFromServer) ~= 'function' then
        lib.notify({ title = locale('common.notify_title'), description = locale('partnership.feature_disabled'), type = 'error' })
        return
    end

    -- Fresh, server-authoritative check -- NOT the synchronous
    -- IsPartnered()/GetPartnerServerId() pair, for the exact reason
    -- client/partnership.lua's own header documents under "KNOWN
    -- CACHE-STALENESS GAP": those two can under-report immediately after
    -- a reconnect/restart even for a genuinely still-partnered player.
    local isPartneredNow, partnerServerId = RefreshPartnershipStateFromServer()
    if not isPartneredNow or not partnerServerId then
        lib.notify({ title = locale('common.notify_title'), description = locale('partnership.not_partnered_with_anyone'), type = 'error' })
        return
    end

    local partnerPlayer = GetPlayerFromServerId(partnerServerId)
    if not partnerPlayer or partnerPlayer == -1 then
        -- Partnership persists across a disconnect (client/partnership.lua's
        -- own header) -- this is the "partnered, but they are not online
        -- right now" case, distinct from "not partnered at all" above.
        lib.notify({ title = locale('common.notify_title'), description = locale('common.target_no_longer_online'), type = 'error' })
        return
    end

    local partnerPed = GetPlayerPed(partnerPlayer)
    if not partnerPed or partnerPed == 0 or not DoesEntityExist(partnerPed) then
        -- Disclosed limitation 3 (this file's header): ordinary FiveM
        -- entity streaming range, not a distance this resource controls.
        lib.notify({ title = locale('common.notify_title'), description = locale('cameraFeed.partner_not_in_range'), type = 'error' })
        return
    end

    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', false)
    if not cam or cam == 0 then
        lib.notify({ title = locale('common.notify_title'), description = locale('cameraFeed.camera_create_failed'), type = 'error' })
        return
    end

    -- Disclosed limitation 1 (this file's header): approximate,
    -- config-tunable vantage height, not skeleton-derived. A pure Z
    -- offset only (no X/Y) is deliberate -- rotation-invariant around
    -- yaw, so this stays anchored correctly above the partner regardless
    -- of which way isRelative resolves the horizontal offset frame for a
    -- turning entity (not independently verified in-engine).
    local cameraFeedConfig = GetCameraFeedConfig()
    local eyeHeightOffset = IsEntityModelK9(partnerPed)
        and cameraFeedConfig.k9EyeHeightOffset
        or cameraFeedConfig.handlerEyeHeightOffset
    AttachCamToEntity(cam, partnerPed, 0.0, 0.0, eyeHeightOffset, true)
    SetCamFov(cam, cameraFeedConfig.fov)

    local rot = GetEntityRotation(partnerPed, 2)
    SetCamRot(cam, rot.x, rot.y, rot.z, 2)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 350, true, false)
    FreezeEntityPosition(PlayerPedId(), true)

    cameraFeedState.active = true
    cameraFeedState.cam = cam
    cameraFeedState.partnerServerId = partnerServerId

    lib.notify({
        title = locale('common.notify_title'),
        description = locale('cameraFeed.feed_started', GetPlayerName(partnerPlayer)),
        type = 'success',
    })

    EnsureCameraFeedThreadRunning()
end

--- Toggles the K9<->handler partner camera feed. See this file's header
--- "CAMERA FEED" section for the full contract. Toggle-off (pressing the
--- same key again while a feed is active) always succeeds unconditionally
--- through StopCameraFeed() -- mirrors this resource's established
--- "termination must never be gated" posture (client/partnership.lua's
--- BreakPartnership(), client/movement.lua's DetachLeash()) -- only
--- STARTING a feed is gated (both by StartCameraFeedAttempt()'s own checks
--- and by the cameraFeedStartInProgress guard immediately below, which that
--- function's own doc comment explains).
function ToggleCameraFeed()
    if cameraFeedState.active then
        StopCameraFeed('cameraFeed.feed_ended_manual')
        return
    end

    if cameraFeedStartInProgress then
        -- See cameraFeedStartInProgress's own declaration comment above --
        -- silent rejection, same posture client/agility.lua's own
        -- `vaultInProgress` branch already established for this bug class.
        return
    end
    cameraFeedStartInProgress = true
    StartCameraFeedAttempt()
    cameraFeedStartInProgress = false
end

-- The partner camera has no key or command: it is opened from the tablet
-- only (owner's choice) -- client/tablet.lua's FEATURE_TRIGGERS.CameraFeedPiP
-- calls ToggleCameraFeed() above.

-- NO SEPARATE THERMAL / NIGHT VISION KEYS (owner: "the thermal and night
-- vision keybinds are completely removed, only keep the cycle vision"). The
-- K and J keys and their commands are gone; k9vision (I) above cycles off ->
-- night -> thermal, and the K9 menu's Senses group still has a button for
-- each mode. ToggleThermalVision()/ToggleNightVision() stay -- the cycle and
-- the menu call them.
-- These two OLD per-mode toggles are still deliberately NOT added to
-- client/radial.lua individually — per §11.3's original file-plan row,
-- "Vision toggles and door interaction are not added to the radial...
-- consistent with the camera toggle's existing precedent." UPDATED, THIS
-- PASS: that precedent still holds for these two BARE toggles, but
-- client/radial.lua now DOES carry one merged "K9 Vision" item that calls
-- CycleVision() above (see this file's own "MERGED ENTRY POINT" section) —
-- a single cycle entry point is not the same thing §11.3 was refusing, and
-- does not reopen it: it does not add either mode back as its OWN separate
-- radial item.

-- Resource-stop safety net — mirrors client/vehicle.lua's ALREADY-SHIPPED
-- onResourceStop pattern for the identical underlying reason: per DEVELOPER_REFERENCE.md
-- §11.5's own thermal-vision acceptance bullet, "the native effect itself
-- persists across a resource restart independent of script state, exactly
-- the same class of bug client/vehicle.lua's header already documents and
-- fixes for vehicle entry/exit." Unlike the maintenance thread above
-- (genuinely open tick-rate/ordering questions), this handler's body is a
-- zero-ambiguity, spec-mandated pair of native calls — safe to write
-- directly rather than leaving as a TODO. Force BOTH off unconditionally,
-- regardless of which (if either) was actually on this session: both
-- natives are idempotent boolean toggles, not stacking counters, so
-- calling SetSeethrough(false)/SetNightvision(false) when an effect was
-- never on this session is a harmless no-op (DEVELOPER_REFERENCE.md#vision
-- §6 item 2). Also covers disconnect per that note's §6 item 3 (FiveM
-- stops every currently-loaded resource, firing this same handler, as
-- part of a player disconnecting) — high confidence per that note's own
-- reasoning, flagged there as "verify this assumption once real code
-- exists" rather than asserted with certainty, since it was not
-- independently tested in-engine.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    SetSeethrough(false)
    SetNightvision(false)

    -- Silent stop (nil notify key) -- the resource (and every keybind/NUI
    -- surface it owns) is stopping anyway, so a player-facing message here
    -- would be pointless. StopCameraFeed() itself is the single choke
    -- point that reverses RENDER_SCRIPT_CAMS/the cam/the freeze
    -- regardless -- see this file's header, disclosed limitation 4.
    StopCameraFeed(nil)
end)
