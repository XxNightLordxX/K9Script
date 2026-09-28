--[[
    qbx_k9unit/client/movement.lua

    Phase 1 scaffold (coder-architect). Owns everything about the K9
    player's own body: the camera toggle, the "Sit" self-emote, and the
    two-player leash mechanic in full (consent handshake, the elastic
    movement restriction while attached, and zero-consent detach). Native
    run/jump/crouch locomotion needs no wrapper code — it's inherent to
    the ped model — so it isn't stubbed here beyond the AgilityBasicJump
    note near the bottom.

    PHASE 3 ADDITION (that pass, coder-architect): also owned
    Config.Features.AgilityAdvanced (fence/window vault approximation) —
    DEVELOPER_REFERENCE.md §12.5.5, §12.1 sub-phase 3a. Entirely client-local,
    self-body movement only, no target ped/player involved anywhere,
    unaffected by DEVELOPER_REFERENCE.md §12.0 item 8's still-open (as of that
    pass) client-relay question, which only concerns effects applied to a
    DIFFERENT entity. Every other Phase 3 sub-feature (BiteAndHold/
    NonLethalTakedown/PropDragging) is deliberately NOT
    touched here — see config.lua's own Config.Combat header comment for
    exactly why each one is still blocked.

    EXTRACTED (this pass): the ADVANCED AGILITY block above has moved out
    to its own file, client/agility.lua — see that file's own header for
    the full "why this one, not the rest of this file" reasoning. Short
    version: it was the one concern in this file that shared no local
    state with anything else here and had no other file depending on its
    locals, confirmed by reading this whole file and grepping the tree
    before moving it. Every OTHER concern this file still owns (camera
    toggle, Sit self-emote, the leash mechanic, the move-rate composer,
    AgilityBasicJump's suppression thread, door interaction) was
    deliberately left in place — none of them stand alone the same way
    (the move-rate composer alone is read by three other files, and the
    leash pull-back thread/door-interaction canInteract checks/vault all
    shared the exact same IsInK9Vehicle()-tucked-K9 exclusion, evidence
    they're one connected "own-body movement gating" concern, not several
    independent ones). "This file is the largest client file" was
    deliberately NOT treated as its own reason to split further — a prior
    refactor pass already advised against cosmetic restructuring of this
    codebase's long files, and every remaining section here earns its
    place through real cross-references to the others, not just proximity.

    ======================================================================
    EVENT/CALLBACK CONTRACT — certification events are documented in full
    in server/certifications/ / client/main.lua (kept in sync manually,
    not re-duplicated here). THIS FILE owns the client side of the leash
    subsystem, documented in full in server/main.lua's header — read that
    file together with this one for the complete picture. Summary of what
    THIS FILE registers/triggers:

    Server events (client->server):
    - 'qbx_k9unit:server:requestLeashAttach' (targetServerId: number)
    - 'qbx_k9unit:server:respondLeashAttach' (fromServerId: number, accepted: boolean)
    - 'qbx_k9unit:server:detachLeash' ()

    Client events (server->client):
    - 'qbx_k9unit:client:leashAttachRequest' (fromServerId: number) [THIS FILE]
    - 'qbx_k9unit:client:leashAttached' (partnerServerId: number, isConstrained: boolean) [THIS FILE]
    - 'qbx_k9unit:client:leashDetached' (reason: string) [THIS FILE]
    - 'qbx_k9unit:client:k9SpeedOverrideStatus' (status: { active: boolean })
      [THIS FILE, GAP 1 PART 2 addition -- server/k9profiles.lua fires this;
      documented in full in that file's own header "GAP 1, PART 2" and in
      the MOVE-RATE COMPOSER block's own "EXPLICIT INDIVIDUAL OVERRIDE VS.
      AUTOMATIC MULTIPLIER" section below]
    ======================================================================

    PHASE 4 ADDITION (this pass, coder-frontend, real-bug fix): also owns
    the shared K9 move-rate composer, `K9MoveRateModifiers` (table) +
    `RecomputeK9MoveRate()` (function) — DEVELOPER_REFERENCE.md §13.0 Decision 2.
    QA had found client/wellbeing.lua unconditionally writing
    `K9MoveRateModifiers.fatigue` and calling
    `RecomputeK9MoveRate()` with neither symbol defined anywhere in this
    codebase — latent only because every wellbeing feature flag defaults to
    `false` in config.lua, and a real bug (hard error, "attempt to index a
    nil value") the instant one is enabled. This is the real fix: the
    composer itself, not a guard added to wellbeing.lua that would have
    silently swallowed every wellbeing speed-penalty write instead. See the
    "MOVE-RATE COMPOSER" block below (near AgilityBasicJump) for the full
    writeup: composition rule, clamp range and why, the check that this
    doesn't fight AgilityBasicJump/the leash pull-back/client/agility.lua's
    AgilityAdvanced vault, and an honest confidence grading on
    `SetPedMoveRateOverride` itself.

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        ToggleK9Camera()
        K9Sit()
        RequestLeashAttach(targetPlayerServerId: number)  -- was named
            AttachLeash() in the earlier (pre-consent) scaffold draft;
            renamed because it no longer attaches anything by itself, it
            only sends a request.
        DetachLeash()
        IsLeashed() -> boolean
    - THIS FILE exposes the resource-global move-rate composer consumed by
      client/wellbeing.lua and client/progression.lua (DEVELOPER_REFERENCE.md §13.0
      Decision 2). Phase 3 has since landed and client/combat.lua's own
      PropDragging now writes the `dragging` key below directly:
        K9MoveRateModifiers (table)  -- named multiplier contributions, one
            key per contributing system (`fatigue`, `injury`, `mood`,
            `xpTier`, `dragging`, `breed`), each defaulting to 1.0 (no effect).
            Callers set their OWN key directly (e.g.
            `K9MoveRateModifiers.fatigue = 0.85`) and then call
            RecomputeK9MoveRate() — never call SetPedMoveRateOverride
            directly from any other file. `breed` is the one exception to
            "callers set their own key": THIS FILE writes it itself, inside
            RecomputeK9MoveRate(), from Config.Peds[n].speedMultiplier for
            the ped's CURRENT model — see the "BREED MOVE-RATE WEIGHT"
            block near that function's own definition for the full
            reasoning (DEVELOPER_REFERENCE.md Part A §4).
        RecomputeK9MoveRate() -- composes every present modifier
            multiplicatively, clamps to [0.1, 2.0], and makes the single
            real SetPedMoveRateOverride call for the K9's own ped. Safe to
            call with no valid/K9 ped (no-op/neutral-reset, never an error).
    - THIS FILE calls client/main.lua's global CanShowK9UI() before
      initiating a request (radial.lua is also expected to gate
      visibility, but per DEVELOPER_REFERENCE.md §3's "must not be triggerable by a
      modified client" spirit, don't rely solely on the caller having
      already checked — and the server re-validates independently anyway,
      see server/main.lua's CheckLeashEligibility).
    - THIS FILE registers the "Attach Leash" ox_target option on nearby
      player peds (the DEVELOPER_REFERENCE.md §6.1 leash bullet's "either the K9 or a
      nearby officer initiates 'Attach Leash' (ox_target) on the other").
      client/vehicle.lua owns the vehicle ox_target option instead; keep
      that split — this file should never touch vehicles, vehicle.lua
      should never touch leash/ox_target-on-peds.
    - client/radial.lua's "Attach/Detach Leash" item is a context-sensitive
      SELF-initiated alternative entry point: if not IsLeashed(), it finds
      a nearby candidate and calls RequestLeashAttach(candidateServerId);
      if IsLeashed(), it calls DetachLeash(). Both surfaces (ox_target and
      radial) end up calling the SAME two functions — don't let a second,
      divergent leash-request code path grow in radial.lua.
    - THIS FILE fires a purely LOCAL 'qbx_k9unit:client:leashStateChanged'
      event (TriggerEvent, never RegisterNetEvent — same "local-only
      re-broadcast" shape as client/featureblocks.lua's own
      'qbx_k9unit:client:featureBlocksApplied') every time `leashState` is
      set or cleared (leashAttached/leashDetached below), so
      client/radial.lua can re-run RegisterK9RadialMenu() and pick up the
      new state immediately. RADIAL DETACH-AVAILABILITY BUG FIX: this
      exists because client/radial.lua's "Attach/Detach Leash" item used to
      be built ONLY inside `if Config.Features.LeashMechanics then ... end`
      -- that flag is THIS CLIENT's own local copy, read once at ITS OWN
      resource start from its own copy of config.lua, never updated again
      for an already-connected client even when server/runtimecontrol.lua's
      runtimeSetFeature flips the flag live server-side. A server booting
      with LeashMechanics off, then turned on live, then a pairing actually
      forming (CheckLeashEligibility re-checks the flag live, server-side,
      independent of this client's stale copy) left this client with
      IsLeashed() == true but no "Detach" item ever added to its own radial
      menu at all -- the button to press simply did not exist. See
      client/radial.lua's own header/RegisterK9RadialMenu for the other
      half of this fix (the item's build-time visibility condition itself).
    - THIS FILE also registers the "Certify K9 Handler" / "Revoke K9
      Certification" ox_target options on nearby player peds (DEVELOPER_REFERENCE.md
      §4.3's flow table, §8 step 3 — the previously-missing entry point;
      the events themselves were always reachable via /k9certify /
      /k9decertify). These directly TriggerServerEvent the two events
      documented in full in server/certifications/'s header
      ('qbx_k9unit:server:certifyHandler' / '...:revokeHandler', both
      (targetServerId: number)) — no new client-side contract of THIS
      FILE's own is introduced, just another entry point into that
      existing, unchanged server contract. Mirrors the "Attach Leash"
      option's structure directly (display-only plausibility gate via
      IsEntityModelK9, server re-validates everything authoritatively).
    - THIS FILE also registers the "Scratch to Alert" ox_target option on
      nearby door-shaped objects (Phase 2, DEVELOPER_REFERENCE.md §11.3's file/module plan
      row for this file) and the 'qbx_k9unit:client:playDoorScratch'
      broadcast receiver — see the DOOR INTERACTION block near the header
      above and the implementation near the bottom of this file. Exposes NO
      new resource-global function of its own (ox_target-only entry point,
      same shape as client/search.lua's search options — nothing else in
      this resource needs to call into door interaction directly).
    - THIS FILE also registers a SEPARATE "Nudge Door" ox_target option
      alongside "Scratch to Alert" on the same door-like objects (the
      previously-deferred nudge-open sub-feature, now implemented — see the
      DOOR INTERACTION block below for the full safety reasoning). Unlike
      every other ox_target option in this file, NudgeDoor() has ZERO server
      involvement of any kind: no TriggerServerEvent, no callback, nothing
      server-authoritative at stake — the entire feature is a local
      self-impulse on the K9's own ped, never touching the door entity's
      state in any way. Exposes no new resource-global function either
      (same ox_target-only entry point shape as ScratchAtDoor above it).

    LEASH SUBSYSTEM DESIGN (per requester's confirmation, resolving
    DEVELOPER_REFERENCE.md §9 item 3b — see server/main.lua's header for the full
    rationale, repeated here only as it affects THIS file):
    1. Attach requires consent — RequestLeashAttach() only ever sends a
       request; the actual pairing is formed server-side after the OTHER
       player accepts via the ox_lib prompt this file shows them.
    2. While attached, the CONSTRAINED party (always the K9-role side,
       server-assigned — see leashAttached's `isConstrained` flag) runs an
       elastic pull-back on THEIR OWN ped as they approach
       Config.LeashMaxDistance from their partner. This must run on the
       constrained player's own client because a client can only reliably
       control its own ped's position — you cannot dependably force
       another client's ped to a position from here, their own game
       instance keeps simulating and re-networking their own movement.
    3. DetachLeash() must work at ANY time for EITHER role, no
       confirmation/consent step of its own — hard requirement, no trapped
       state.
    4. If the elastic pull-back still can't keep distance under control
       (disconnect, teleport, desync) and a hard cap is exceeded, the
       CONSTRAINED client calls DetachLeash() itself as a safety valve —
       reuse this exact function, don't build a second detach code path.

    ======================================================================
    DOOR INTERACTION — Phase 2, SCRATCH-TO-ALERT + NUDGE-OPEN. DEVELOPER_REFERENCE.md
    §11.1 sub-phase 2a/2b, §11.3's file/module plan (this file's row), §11.4
    items 5/6, §11.5's door-interaction acceptance criteria;
    DEVELOPER_REFERENCE.md#door-interaction (the design note,
    native verification, and security review that used to be three separate
    files are now merged into this one section; all three were read in full
    before this section was written — the security review in particular was
    written pre-implementation against server/main.lua's ALREADY-SHIPPED
    relayDoorScratch handler, so this file is built to that handler's exact,
    fixed contract rather than re-deriving it).

    NOTE ON THE "§N"/"Finding N" SUFFIXES cited after #door-interaction
    below (e.g. "§3.1", "§4.2/§7", "Finding 3"): those are leftover
    pinpoints from the pre-2026-08-25 research archive's own internal
    numbering, which did not survive that file's consolidation into
    DEVELOPER_REFERENCE.md's §15 prose (the current #door-interaction
    section is unnumbered prose) — see that section's own header note for
    the full explanation. Read the anchor (#door-interaction) as the real
    target; the suffix after it will not resolve to a matching subsection.
    Citations already hedged as "(§N in its original form)" below already
    say this explicitly; the unhedged ones mean the same thing.

    "Nudge-open" is now implemented — see the "NUDGE-OPEN" comment further
    down, immediately above the door-interaction code itself, for the full
    reasoning, the hard safety constraint it follows (never consults GTA's
    native door-lock/CDoor system, by design), and which of the two
    design-note-flagged implementation paths was actually taken (the
    zero-gating cosmetic-only fallback, since a real "already passable"
    detection method was never confirmed to exist anywhere in
    DEVELOPER_REFERENCE.md#door-interaction).

    Nudge-open has NO server event of its own — it is 100% client-local
    (ZERO TriggerServerEvent, ZERO callback, nothing server-authoritative
    touched at all), unlike scratch-to-alert below. Do not add one; that
    would be a structural deviation from DEVELOPER_REFERENCE.md §11.3/§11.5/§11.6's
    explicit, repeated framing, not a judgment call left open by this file.

    Server events (client->server):
    - 'qbx_k9unit:server:relayDoorScratch' (doorNetId: number)
      [server/main.lua, already implemented — THIS FILE only triggers it].
      Structurally mirrors 'qbx_k9unit:server:relayBark' above, EXCEPT the
      payload names a DIFFERENT entity (the door) than the sender's own ped
      — the server independently resolves/existence-checks/proximity-checks
      doorNetId before ever broadcasting it (closes DEVELOPER_REFERENCE.md §9 item 16, per
      server/main.lua's own header comment on that handler). This file's own
      pre-send checks (CanShowK9UI(), DoesEntityExist(entity)) are UX only,
      never the security boundary — the server re-validates everything
      regardless of what this client claims.

    Client events (server->client):
    - 'qbx_k9unit:client:playDoorScratch' (doorNetId: number) [THIS FILE]
      Mirrors client/main.lua's existing playBark handler exactly (resolve
      the network entity, no-op if not streamed in/nonexistent, play a
      sound) — per DEVELOPER_REFERENCE.md §11.4 item 6. The resolve step calls
      client/main.lua's global ResolveNetworkEntity(netId)
      (DEVELOPER_REFERENCE.md near-term item 2) rather than re-implementing
      it locally.
    ======================================================================
]]

-- Local-only view-mode state for the camera toggle below. Not exposed —
-- ToggleK9Camera() is the only entry point.
local isFirstPersonK9View = false

--- Toggles first/third-person camera at the K9's eye height while playing
--- a K9 character. See client/main.lua's OPEN QUESTION about whether this
--- needs to be gated by CanShowK9UI() at all — per this scaffold's lean
--- (and the top-level task's explicit direction) this does NOT gate on
--- CanShowK9UI() (a QoL toggle, not a granted capability); it DOES gate on
--- the cheap, local, free IsOwnModelK9() check, since "while playing their
--- K9 character" (DEVELOPER_REFERENCE.md §6.1 bullet 2) implies it's meaningless for a
--- human-model character, not that it requires job/cert.
--- DEVELOPER_REFERENCE.md §6.1 bullet 2, §8 step 5. Bound to a rebindable keymapping
--- (FiveM's own Settings > Key Bindings screen lets a player/server change
--- the default) rather than a radial item — camera toggle isn't in the
--- Phase 1 radial item list (Bark/Sit/Leash/Vehicle only, see
--- client/radial.lua), so it needs its own input path.
--- SetFollowPedCamViewMode drives the game's OWN built-in first/third
--- person camera system, which already derives eye/vantage height from
--- the CURRENT ped model's actual skeleton (including quadruped models)
--- generically — this is why no manual CreateCam/AttachCamToEntity rig is
--- needed to satisfy "camera at the dog's eye height": the native camera
--- modes already do that for any ped model without per-model tuning.
function ToggleK9Camera()
    if not IsOwnModelK9() then
        lib.notify({ title = locale('common.notify_title'), description = locale('common.not_k9_model'), type = 'error' })
        return
    end

    isFirstPersonK9View = not isFirstPersonK9View
    SetFollowPedCamViewMode(isFirstPersonK9View and 4 or 1)
    lib.notify({
        title = locale('common.notify_title'),
        description = isFirstPersonK9View and locale('movement.camera_first_person') or locale('movement.camera_third_person'),
        type = 'info',
    })
end

RegisterCommand('qbx_k9unit:toggleCamera', function()
    -- KEYBIND SILENCE GATE (live-bug fix) -- a keypress carries no
    -- evidence that a K9 action was intended, so a player who is not a K9
    -- gets nothing at all instead of a refusal toast. See
    -- IsK9KeybindAudience() in client/main.lua for the full writeup of the
    -- city-wide toast spam this closes.
    if not IsK9KeybindAudience() then return end

    ToggleK9Camera()
end, false)

RegisterKeyMapping('qbx_k9unit:toggleCamera', locale('movement.toggle_camera_keybind_label'), 'keyboard', 'L')

-- qa-tester finding: a resource restart while isFirstPersonK9View is true
-- previously left the game's follow-cam stuck in mode 4 (first-person)
-- with no code left running to ever set it back — the same "sticky native
-- state must be reversed on stop" class of bug client/vehicle.lua's own
-- onResourceStop handler already exists to prevent. Only reset when this
-- resource actually changed the mode, so a player's own unrelated camera
-- preference is never clobbered by a restart of this resource.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if isFirstPersonK9View then
        SetFollowPedCamViewMode(1)
        isFirstPersonK9View = false
    end
end)

--- Self-emote "Sit" action triggered from the radial menu. DEVELOPER_REFERENCE.md §6.1
--- radial bullet, §8 step 7. Gated with CanShowK9UI() at the top (per
--- radial.lua's own contract, every Phase 1 radial item is a real granted
--- capability check, unlike camera/locomotion above) — return early (and
--- notify) if false, don't just rely on radial.lua having already hidden
--- the item.
--- VERIFIED (native-api-assistant pass, 2026-08-23): "WORLD_DOG_SIT" (the
--- earlier scaffold's guess) is NOT a real scenario — there is no generic
--- dog-sit scenario name at all. Cross-checked against two independently
--- maintained community scenario dumps (DioneB/GTAV-Scenarios and
--- kibook/spooner's scenarios.lua, both decompiled-game-data-derived lists
--- that agree exactly on the dog entries), the real names are PER-BREED:
---   WORLD_DOG_SITTING_SHEPHERD / _ROTTWEILER / _RETRIEVER / _SMALL
--- (plus WORLD_DOG_BARKING_* siblings, not used here). Confidence: HIGH on
--- these exact strings existing (two independent authoritative-for-FiveM-
--- purposes sources agree); MEDIUM on the breed-to-scenario mapping below
--- for a_c_chop/a_c_husky specifically, since neither has an exact-name
--- match and dog scenario anims are shared across the generic quadruped
--- skeleton rather than being model-locked — untested in-engine this
--- session, so if a mapped breed looks visibly off, that's the first
--- place to revisit. TaskStartScenarioInPlace on a PLAYER-controlled ped
--- (vs. an AI ped) is expected/normal here: same native, it plays the pose
--- and exits automatically the moment the player provides movement input,
--- which is the desired "self-emote until you move" behavior for this
--- radial item, not a bug — no anim-dict/TaskPlayAnim fallback is needed
--- since a real scripted scenario exists for every configured breed.
--- Precomputed model-hash -> scenario lookup, built once at file load.
--- Mirrors the precomputed-hash-table convention already used elsewhere
--- in this codebase (client/main.lua's K9ModelHashes, which also backs
--- IsEntityModelK9 per DEVELOPER_REFERENCE.md item 3) rather than calling
--- GetHashKey per lookup.
local K9_SIT_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists
    a_c_husky = 'WORLD_DOG_SITTING_RETRIEVER', -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit
}) do
    K9_SIT_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_SIT_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD' -- fallback if playing an unmapped/future Config.Peds model

function K9Sit()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    local ped = PlayerPedId()
    local scenarioName = K9_SIT_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_SIT_DEFAULT_SCENARIO

    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
end

--- Local-only UI/role bookkeeping for the CURRENT leash pairing, if any.
--- The pairing's existence is server-authoritative (server/main.lua's
--- LeashPairs); this is just this client's cached view of it, refreshed
--- by the leashAttached/leashDetached handlers below. Not exposed
--- directly — always go through IsLeashed()/DetachLeash().
--- @type { partnerServerId: number, isConstrained: boolean }|nil
local leashState = nil

--- Guards the hard-cap safety-valve branch below from firing more than
--- once per attach: the pull-back thread ticks every LEASH_TICK_MS, so
--- under latency the server's detach round-trip can take longer than one
--- tick, and without this flag the branch would re-fire and duplicate the
--- notification/DetachLeash() call every tick until leashState actually
--- clears. Reset in the leashAttached/leashDetached handlers below.
local detachRequestedForSafety = false

--- @return boolean
function IsLeashed()
    return leashState ~= nil
end

--- Sends a leash request to `targetPlayerServerId`. Does NOT attach
--- anything by itself — see leashAttached event handler below for where
--- the pairing actually activates, after the target accepts.
--- @param targetPlayerServerId number
function RequestLeashAttach(targetPlayerServerId)
    -- BUG FIX (this pass, cross-checked against a real bug of the exact
    -- same shape client/partnership.lua's RequestPartnerUp() found and
    -- fixed in itself -- see that function's own doc comment for the full
    -- writeup this one mirrors). This used to be an unconditional
    -- `if not CanShowK9UI() then` -- correct for client/radial.lua's
    -- "Attach/Detach Leash" item (a genuinely K9-only self-actions
    -- submenu, DEVELOPER_REFERENCE.md's own radial item list), but WRONG for this
    -- function's OTHER, equally-real caller: the "Attach Leash" ox_target
    -- option registered below, whose own canInteract predicate
    -- (`IsOwnModelK9() or IsEntityModelK9(entity)`) already permits an
    -- OFFICER to target a nearby K9 and select it, and DEVELOPER_REFERENCE.md's own
    -- wording ("Either the K9 or a nearby officer initiates 'Attach
    -- Leash' (ox_target) on the other") requires exactly that to work.
    -- CanShowK9UI() == IsOwnModelK9() and HasK9Access(), which is false
    -- for every officer-role player by construction (an officer is never
    -- modeled as a K9) -- so the unconditional gate silently denied every
    -- officer-initiated "Attach Leash" attempt with a "you cannot use K9
    -- features right now" notice before the request ever reached the
    -- server. Confirmed this pass that the server side was never the
    -- blocker: server/main.lua's CheckLeashEligibility determines the
    -- K9/officer role purely from each party's LIVE ped model, never from
    -- who initiated -- an officer-initiated request is accepted or
    -- rejected there on exactly the same terms as a K9-initiated one.
    -- Never a security hole (the server was always the real authority
    -- either way), but a real, total functional break of half the
    -- documented consent handshake.
    --
    -- FIX: only apply the K9-shaped CanShowK9UI() pre-check when the LOCAL
    -- player would actually be the prospective K9-role party
    -- (IsOwnModelK9() true) -- mirrors CheckLeashEligibility's own
    -- role-via-live-model design and RequestPartnerUp()'s identical fix.
    -- An officer-role initiator has no cheap client-side
    -- Config.Departments-membership equivalent exposed as a
    -- resource-global to pre-check locally -- same "no cheap client-side
    -- equivalent, let the server answer with a specific reason" tradeoff
    -- this file's own "Certify K9 Handler" ox_target option already
    -- documents for IsEligibleCertifier -- so this simply defers that
    -- branch to the server's own CheckLeashEligibility, which notifies the
    -- caller either way (LeashRejectReasonMessage).
    if IsOwnModelK9() and not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if IsLeashed() then
        lib.notify({ title = locale('common.notify_title'), description = locale('movement.already_leashed'), type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestLeashAttach', targetPlayerServerId)
    -- Bug fix (this pass): this used to ALSO show its own optimistic local
    -- "Leash request sent." notify here, immediately, unconditionally —
    -- but server/main.lua's requestLeashAttach handler already sends the
    -- one real, authoritative confirmation via NotifyPlayer (which itself
    -- triggers 'ox_lib:notify', an ox_lib-owned client event this resource
    -- doesn't need to duplicate) ONLY once the request is actually
    -- accepted server-side (passes CheckLeashEligibility, isn't a
    -- duplicate pending request, isn't rate-limited) — using the EXACT
    -- same locale string this local call used (locale('leash.request_sent')
    -- vs. this call's locale('movement.leash_request_sent'), both "Leash
    -- request sent."). On the success path this meant the requester saw
    -- the same message twice; on every rejection path (invalid target,
    -- ineligible, a duplicate pending request already exists, or the
    -- silent rate-limit no-op) it was actively WRONG — the requester saw
    -- "Leash request sent." first regardless, then either a contradicting
    -- error right after or, in the rate-limited case, incorrect
    -- confirmation with no error ever following it. Removed here in favor
    -- of the server's single authoritative notify for both outcomes — the
    -- target's client is the one that shows the actual accept/decline
    -- prompt (see leashAttachRequest below) either way.
end

--- Detaches the current leash, if any, with ZERO consent required from
--- the other party. No-op (locally and server-side) if not currently
--- leashed. This is the SAME function the elastic-restriction safety
--- valve calls automatically — see the CreateThread below.
function DetachLeash()
    if not IsLeashed() then return end

    -- Let the server-authoritative leashDetached broadcast (handled
    -- below) be what actually clears leashState/stops the thread, rather
    -- than clearing local state immediately here, so this client's view
    -- stays in sync with whatever the server decides.
    TriggerServerEvent('qbx_k9unit:server:detachLeash')
end

-- ======================================================================
-- CHAT COMMAND -- Attach/Detach Leash (menu-parity pass: "chat commands,
-- 3rd eye, and radial menus" -- every feature reachable from all three).
-- Before this pass, this mechanic had an ox_target entry point AND a
-- client/radial.lua item, but no chat command at all.
--
-- SAME CONTEXTUAL-DISPATCH SHAPE AS client/radial.lua's own 'k9_leash' item
-- AND client/tablet.lua's FEATURE_TRIGGERS.LeashMechanics (read both before
-- changing this) -- ONE command, not two, matching the owner's own
-- direction that a family like this "should all work together like the
-- scen[t] command does." IsLeashed() is resolved FIRST, UNGATED, exactly
-- like those two surfaces -- "gate the start, never the stop" applies here
-- identically. The Attach branch below is the same shape as
-- client/tablet.lua's own LeashMechanics trigger (same
-- 'common.no_k9_role_or_access' reason, same 'radial.no_leash_candidate'
-- notify on no candidate) -- not a fourth, independently-derived copy of
-- this decision. Reaches the SAME two resource-globals
-- (DetachLeash()/RequestLeashAttach()) either way; neither is reimplemented
-- here and no new access rule is introduced -- both already perform their
-- own real gating internally (DetachLeash() unconditionally;
-- RequestLeashAttach() via its own IsOwnModelK9()-and-CanShowK9UI() check
-- a few lines above). This command only decides WHICH of the two to call
-- and, for Attach, which nearby candidate to send.
--
-- FindNearestLeashCandidate() is client/radial.lua's own resource-global
-- (promoted from `local` specifically so a second caller like this one, or
-- client/tablet.lua, can reuse it rather than carrying a second, drifting
-- copy -- see that function's own "SEAM OPENED" doc comment). Reached here
-- behind a `type(...) == 'function'` runtime existence guard: client/radial.lua
-- loads AFTER this file (fxmanifest.lua's client_scripts order), but by the
-- time a player can type this command every client script has already
-- finished loading regardless -- a runtime existence guard, not a
-- load-order assumption, matching this resource's established convention.
-- ======================================================================
RegisterCommand('k9leash', function()
    if IsLeashed() then
        DetachLeash()
        return
    end

    if not CanShowK9UI() then
        DenyK9UIAccess('common.no_k9_role_or_access')
        return
    end

    if type(FindNearestLeashCandidate) ~= 'function' then return end
    local candidateServerId = FindNearestLeashCandidate()
    if not candidateServerId then
        lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_leash_candidate'), type = 'error' })
        return
    end

    RequestLeashAttach(candidateServerId)
end, false)

--- Step 1 of the consent handshake, received on the TARGET's client.
--- @param fromServerId number
RegisterNetEvent('qbx_k9unit:client:leashAttachRequest', function(fromServerId)
    -- SOURCE-ORIGIN GUARD (coder-security pass, applied uniformly across
    -- this file's `qbx_k9unit:client:*` handlers here — see
    -- client/combat.lua's own "SOURCE-ORIGIN GUARD" header block for the
    -- full sourced writeup/confidence grading, not re-derived per file).
    -- Without this, a locally-forged `fromServerId` would pop a fake
    -- accept/decline prompt for a leash request that was never actually
    -- sent — a real-server response is still required to do anything, but
    -- this closes the "arbitrary event with zero server contact" gap this
    -- resource's own convention now expects for every client:* handler.
    -- Confidence: MEDIUM-HIGH, not certain — see client/combat.lua's
    -- header for the honest caveat (official documented pattern, not
    -- empirically verified in-engine as part of this change).
    if source ~= 65535 then return end
    local fromPlayer = GetPlayerFromServerId(fromServerId)
    local fromName = (fromPlayer ~= -1 and GetPlayerName(fromPlayer)) or locale('movement.officer_fallback_name', fromServerId)

    -- If the local player leashes/unleashes/disconnects mid-prompt, or
    -- either side is no longer eligible by the time they answer, the
    -- server re-validates everything at accept time regardless (see
    -- server/main.lua's CheckLeashEligibility TOCTOU note) — this client
    -- just needs to send the response and handle a later rejection
    -- gracefully, not assume acceptance always succeeds.
    local response = lib.alertDialog({
        header = locale('movement.leash_request_header'),
        content = locale('movement.leash_request_content', fromName),
        centered = true,
        cancel = true,
        labels = { confirm = locale('movement.accept_label'), cancel = locale('movement.decline_label') },
    })

    TriggerServerEvent('qbx_k9unit:server:respondLeashAttach', fromServerId, response == 'confirm')
end)

--- Step 2 of the consent handshake: the server has confirmed the pairing
--- and told THIS client its role. Sent individually to each party with
--- their own `isConstrained` value — do not assume both clients receive
--- the same boolean.
--- @param partnerServerId number
--- @param isConstrained boolean  -- true only on the K9-role party's client
RegisterNetEvent('qbx_k9unit:client:leashAttached', function(partnerServerId, isConstrained)
    -- SOURCE-ORIGIN GUARD — see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. Forging this
    -- locally would set this client's OWN leashState directly (no
    -- server-side pairing exists to back it) — low real-world payoff either
    -- way (the elastic-restriction thread only constrains THIS client, and
    -- a hostile client could already ignore that thread's DisableControlAction-
    -- equivalent restrictions by other means), but applied for the same
    -- resource-wide consistency reasoning as every other handler here.
    if source ~= 65535 then return end
    leashState = { partnerServerId = partnerServerId, isConstrained = isConstrained }
    detachRequestedForSafety = false
    lib.notify({
        title = locale('common.notify_title'),
        description = isConstrained and locale('movement.leash_now_leashed') or locale('movement.leash_now_anchoring'),
        type = 'success',
    })
    -- The elastic-restriction thread below is a perpetual loop that reads
    -- `leashState` fresh every iteration, so simply setting it here is
    -- sufficient to "wake" the tighter-interval pulling behavior on the
    -- constrained client — no separate thread-start call needed.

    -- RADIAL DETACH-AVAILABILITY BUG FIX -- see this file's own
    -- FILE-TO-FILE CONTRACT header for the full writeup. Local-only
    -- re-broadcast (never RegisterNetEvent) so client/radial.lua's
    -- RegisterK9RadialMenu() re-runs and re-evaluates IsLeashed() right
    -- now, not merely at this client's own resource start / ox_lib
    -- restart / featureBlocksApplied sync.
    TriggerEvent('qbx_k9unit:client:leashStateChanged')
end)

--- The pairing has ended — manual detach by either side, the constrained
--- client's own safety valve, or a partner disconnect (server/main.lua's
--- playerDropped cleanup). Sent to whichever client(s) are still around.
--- @param reason string  -- e.g. 'detached' | 'partner_disconnected'
RegisterNetEvent('qbx_k9unit:client:leashDetached', function(reason)
    -- SOURCE-ORIGIN GUARD — see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. This one has a real
    -- self-benefit shape, not merely cosmetic: a CONSTRAINED party forging
    -- this locally clears `leashState` on THIS client only, which silences
    -- the elastic-restriction thread's pull-back enforcement below —
    -- functionally the same as escaping the leash — while server/main.lua's
    -- own leash bookkeeping (and the other party's client) still believes
    -- the pairing is active, since no real `qbx_k9unit:server:detachLeash`
    -- was ever sent.
    if source ~= 65535 then return end
    leashState = nil
    detachRequestedForSafety = false

    -- Every reason the server can send needs its own sentence here, or it
    -- falls through to the generic "leash detached" and the player is left
    -- guessing why. server/main.lua's own detach path sends 'partner_died'
    -- as well as 'partner_disconnected'; only the latter had wording, which
    -- that file honestly disclosed rather than hid.
    local description = locale('movement.leash_detached')
    if reason == 'partner_disconnected' then
        description = locale('movement.leash_detached_partner_disconnected')
    elseif reason == 'partner_died' then
        description = locale('movement.leash_detached_partner_died')
    end
    lib.notify({ title = locale('common.notify_title'), description = description, type = 'info' })
    -- The elastic-restriction thread below naturally stops doing anything
    -- once IsLeashed() is false — nothing else to tear down here.

    -- RADIAL DETACH-AVAILABILITY BUG FIX -- see this file's own
    -- FILE-TO-FILE CONTRACT header for the full writeup. Mirrors the
    -- identical re-broadcast on the leashAttached handler above: without
    -- this, a radial item that only exists right now because IsLeashed()
    -- was true at the last rebuild (Config.Features.LeashMechanics -- this
    -- client's own stale local copy -- being false) would keep lingering
    -- after the pairing actually ends, instead of disappearing along with
    -- it. onSelect's own IsLeashed() re-check (see client/radial.lua) means
    -- clicking a stale leftover item was never unsafe, only visually
    -- wrong; this call makes the item's disappearance immediate, matching
    -- its appearance.
    TriggerEvent('qbx_k9unit:client:leashStateChanged')
end)

-- Elastic movement-restriction thread — the part of the leash mechanic
-- that must be an actual constraint, not a passive monitor. Only does
-- anything while IsLeashed() AND leashState.isConstrained is true (the
-- anchor/officer side does nothing here beyond having already received
-- its own notify above). Re-resolves the partner ped from
-- leashState.partnerServerId every tick rather than caching the handle,
-- since a cached ped handle can go stale across a respawn/reconnect.
local LEASH_TICK_MS = 250
local LEASH_IDLE_TICK_MS = 1000
local LEASH_PULL_ZONE_FACTOR = 0.75 -- start elastic pull-back at 75% of Config.LeashMaxDistance
local LEASH_HARD_CAP_FACTOR = 1.5   -- safety-valve auto-detach threshold, relative to Config.LeashMaxDistance
local LEASH_PULL_EASE = 0.20        -- fraction of the excess distance corrected per tick (feel/tuning knob)

CreateThread(function()
    while true do
        local sleepMs = LEASH_IDLE_TICK_MS

        if leashState and leashState.isConstrained then
            sleepMs = LEASH_TICK_MS

            local partnerPlayer = GetPlayerFromServerId(leashState.partnerServerId)
            local partnerPed = partnerPlayer ~= -1 and GetPlayerPed(partnerPlayer) or 0

            if partnerPed ~= 0 and DoesEntityExist(partnerPed) then
                local myPed = PlayerPedId()
                local myCoords = GetEntityCoords(myPed)
                local partnerCoords = GetEntityCoords(partnerPed)
                local dist = #(myCoords - partnerCoords)

                local softLimit = Config.LeashMaxDistance
                local hardCap = softLimit * LEASH_HARD_CAP_FACTOR
                local pullZoneStart = softLimit * LEASH_PULL_ZONE_FACTOR

                if dist >= hardCap then
                    -- Safety-valve fallback (point 4 in this file's
                    -- header): the elastic pull-back below couldn't keep
                    -- distance under control (disconnect/teleport/desync).
                    -- Reuse the exact same detach path, don't build a
                    -- second one. Guarded so this only fires once per
                    -- attach — the server round-trip can outlast one tick
                    -- under latency, and leashState doesn't clear until
                    -- the server confirms via leashDetached.
                    if not detachRequestedForSafety then
                        detachRequestedForSafety = true
                        lib.notify({ title = locale('common.notify_title'), description = locale('movement.leash_snapped_too_far'), type = 'error' })
                        DetachLeash()
                    end
                elseif dist > pullZoneStart and not IsPedInAnyVehicle(myPed, false) and not (IsInK9Vehicle and IsInK9Vehicle()) and not (IsRestingInKennel and IsRestingInKennel()) then
                    -- Proportional soft pull-back, not a hard snap at the
                    -- exact threshold: the closer to hardCap, the stronger
                    -- the correction applied this tick. Skipped while in a
                    -- vehicle (IsPedInAnyVehicle), "tucked" into a K9
                    -- cruiser via client/vehicle.lua's attach-based load-in
                    -- (IsInK9Vehicle), or (THIS PASS, trap-hunt follow-up)
                    -- resting in a kennel via client/kennel.lua's own
                    -- attach-based "Rest in Kennel" (IsRestingInKennel) --
                    -- all three exclusions exist to avoid fighting the
                    -- AttachEntityToEntity that's holding the ped in place.
                    -- A leashed K9 resting in a kennel whose partner walks
                    -- away would otherwise get SetEntityCoords called on it
                    -- every tick by THIS thread while the kennel attachment
                    -- is independently repositioning it back every tick too
                    -- -- a physics fight, not a stranding on its own (the
                    -- hard-cap safety valve above still force-detaches the
                    -- leash unconditionally regardless of this branch), but
                    -- one that breaks this file's own stated rule of
                    -- excluding every attach-based tucked state from the
                    -- elastic pull-back. IsRestingInKennel is a REAL,
                    -- always-defined cross-file global once client/kennel.lua
                    -- loads (exposed outside that file's own
                    -- REGISTRATION-TIME FEATURE GATE specifically so callers
                    -- like this one can reach it unconditionally) — guarded
                    -- with the SAME `X and X()` existence-check idiom this
                    -- line already uses for IsInK9Vehicle, not the
                    -- `type(X) == 'function'` idiom this resource's OTHER
                    -- files use for the identical soft-dependency purpose,
                    -- to stay consistent with this exact line rather than
                    -- mix two different guard styles in one boolean
                    -- expression. A defensive edge case, not spelled out in
                    -- DEVELOPER_REFERENCE.md. The existence checks guard
                    -- load order between these independent client scripts
                    -- within the resource.
                    local excess = dist - pullZoneStart
                    local zoneSize = math.max(hardCap - pullZoneStart, 0.1)
                    local pullFactor = math.min(excess / zoneSize, 1.0)
                    local pullAmount = excess * pullFactor * LEASH_PULL_EASE
                    local dir = (partnerCoords - myCoords) / dist
                    local newCoords = myCoords + dir * pullAmount
                    SetEntityCoords(myPed, newCoords.x, newCoords.y, newCoords.z, false, false, false, true)
                end
            end
            -- If the partner ped isn't resolvable this tick (streamed
            -- out/not yet loaded), just skip pulling for now — a real
            -- disconnect is independently handled by server/main.lua's
            -- playerDropped cleanup broadcasting leashDetached.
        end

        Wait(sleepMs)
    end
end)

-- Bug fix (this pass): a resource restart (not a disconnect -- the
-- player stays connected, this resource just stops and restarts on
-- their client) while IsLeashed() is true used to leave a real orphaned
-- pairing: the thread above (this resource's ONLY enforcement of the
-- elastic pull-back / hard-cap safety valve) dies along with the rest of
-- this resource on stop, but leashState lives on server-side
-- (server/main.lua's LeashPairs) with nothing left client-side to ever
-- correct drift or auto-detach on a runaway distance -- the constrained
-- party could end up leashed-in-name-only, with zero of the restriction
-- this feature exists to provide, until either party manually detaches.
-- Same "don't leave sticky cross-resource state behind on stop" class of
-- bug this file's isFirstPersonK9View/lastAppliedMoveRate onResourceStop
-- handlers above already guard against, and the exact convention
-- client/vehicle.lua's own onResourceStop (ReleasePedFromVehicleState)
-- follows for its own stranding case. DetachLeash() is a no-op if not
-- leashed, and reuses the SAME server round-trip DetachLeash() always
-- uses -- no second detach path introduced. Only meaningful on the
-- CONSTRAINED party's client (the anchor/officer side has no local
-- enforcement to lose either way), but calling it unconditionally on
-- both is harmless and keeps this one code path in charge of every
-- detach, per this file's own header point 4.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if IsLeashed() then
        DetachLeash()
    end
end)

-- IsEntityModelK9(entity) used to be defined here as a small local copy
-- (with its own private k9ModelHashesForTargeting hash set) of the same
-- generic Config.Peds-driven display-only check, since client/main.lua only
-- exposed IsOwnModelK9() (not its private model-hash table) at the time
-- this file was written. Promoted to a client/main.lua resource-global per
-- DEVELOPER_REFERENCE.md item 3 — this file's own signature was the one
-- promoted verbatim (see client/main.lua's own doc comment on
-- IsEntityModelK9 for the full "5 independent copies" finding this
-- consolidation closes). Every call site below now calls that shared
-- global instead.

-- config-validator finding: this option's `distance` used to be a bare
-- 2.5 with no relationship to any Config value at all, even though the
-- REAL server-side range check for initiating a leash attach is
-- Config.LeashMaxDistance (server/main.lua's CheckLeashEligibility, which
-- reuses that same raw value directly per config.lua's own comment on it
-- — see the "too far to request" check there). Deriving from it here means
-- an installer who edits Config.LeashMaxDistance now sees this option's
-- visible range move with it, instead of it silently staying frozen at an
-- unrelated magic number.
--
-- Kept at HALF Config.LeashMaxDistance rather than the full value: this is
-- a DISPLAY-ONLY UI gate (the server re-validates authoritatively
-- regardless — see below), so it's deliberately tighter than the server
-- bound on purpose, not because it needs to match exactly. An ox_target
-- option that only appears right at the exact edge of what the server
-- would accept is a bad experience — a half-step of player movement
-- between opening the ox_target menu and the server actually processing
-- the resulting 'qbx_k9unit:server:requestLeashAttach' event can flip a
-- borderline case from accepted to rejected. Halving the server bound
-- gives comfortable margin against that without being so tight the option
-- feels unreasonably hard to find.
--
-- NOTE for reviewers: with the current default (Config.LeashMaxDistance =
-- 8.0), this evaluates to 4.0m, WIDER than the previous hardcoded 2.5m —
-- this is an intentional, documented widening (not an incidental
-- side-effect of this change), and remains well inside
-- Config.LeashMaxDistance, so the server's own authoritative check is
-- still what actually gates the action either way.
local LEASH_TARGET_DISTANCE_FACTOR = 0.5

-- Register the "Attach Leash" ox_target option on nearby player peds
-- (DEVELOPER_REFERENCE.md §6.1 leash bullet's "either the K9 or a nearby officer
-- initiates 'Attach Leash' (ox_target) on the other"). This is a DISPLAY
-- optimization only — the server independently re-validates everything
-- for real in CheckLeashEligibility (server/main.lua), so this predicate
-- doesn't need to be perfect.
--
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call -- every canInteract/onSelect pair in
-- this file is unchanged (still authored against ox_target's own
-- convention), so an operator running a different supported target script
-- gets every one of these options translated automatically instead of
-- losing them outright.
--
-- LIFECYCLE FIX (this pass): extracted into a named function — see the
-- combined `AddEventHandler('onResourceStart', ...)` near the end of this
-- file (after all three target-registration functions it dispatches are
-- defined) for why: every supported target script keeps its own
-- addGlobalPlayer/addGlobalObject-equivalent registry in a plain
-- file-local Lua table inside its own client chunk, reloaded empty on THAT
-- resource's own restart with nothing else prompting a re-add. Mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. DUPLICATE-VS-REPLACE: every
-- option this file registers always sets `name`, and every adapter's own
-- registration primitive dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running any of
-- these three functions never duplicates an entry.
--
-- THIRD-EYE CLARITY PASS (this pass, owner-directed): this used to be ONE
-- option ('qbx_k9unit:attachLeash', a bare "Attach Leash" label) shown to
-- EITHER side of the handshake — a K9 targeting a prospective officer, OR
-- an officer targeting a K9 — via a single `IsOwnModelK9() or
-- IsEntityModelK9(entity) or IsK9RoleForPlayer(...)` predicate. That is
-- exactly the "flat, jargon-y option with no indication of who it's for"
-- complaint: the same static label/icon can't read correctly for both
-- actors at once (ox_target's `label`/`icon` fields are plain values, not
-- per-viewer functions — confirmed against the real ox_target source this
-- pass, and shared/compat/target.lua's own qb-target/sleepless_interact
-- adapters key removal BY that label, so it must stay a stable string
-- either way). Split into two options with mutually exclusive
-- canInteract predicates instead — each one only ever shows to the actor
-- it actually describes, in that actor's own plain English:
--   - 'qbx_k9unit:attachLeashAsHandler' (icon fas fa-user-tie, the
--     resource-wide "a separate human acts on/for a K9" icon): shown to a
--     human targeting a K9-modeled/K9-roled ped. Never shown to a K9-bodied
--     actor (`if IsOwnModelK9() then return false end`), so the two options
--     never both appear on the same target for the same viewer.
--   - 'qbx_k9unit:attachLeashAsK9' (icon fas fa-dog, the resource-wide
--     K9-role icon): shown only while the LOCAL player's own body is the K9
--     (IsOwnModelK9()), matching this option's own long-standing "any
--     nearby player is a plausible prospective handler, let the server
--     answer with a specific reason" tradeoff (unchanged from before this
--     split).
-- Both still funnel into the exact same RequestLeashAttach(targetServerId)
-- — this is a display/labeling split only, never a second, divergent
-- request path, and CheckLeashEligibility (server/main.lua) remains the
-- one real authority either way.
local function RegisterLeashOxTargetOption()
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'qbx_k9unit:attachLeashAsHandler',
            icon = 'fas fa-user-tie',
            label = locale('movement.attach_leash_handler_target_label'),
            distance = LEASH_TARGET_DISTANCE_FACTOR * Config.LeashMaxDistance,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.LeashMechanics then return false end
                if IsLeashed() then return false end
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't target self
                if IsOwnModelK9() then return false end -- HANDLER direction only -- a K9-bodied actor gets the K9-direction option below instead, never both

                -- WIDENED (K9 role/model decoupling): IsEntityModelK9(entity)
                -- alone misses a target who holds the decoupled K9 ROLE on a
                -- human/custom model -- IsK9RoleForPlayer(...) is
                -- client/appearance.lua's own per-target-cached (1s TTL,
                -- same shape as HasK9Access() above) server round trip for
                -- exactly that question, so it is only ever awaited here on
                -- a cache miss, never on every frame.
                return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
            end,
            onSelect = function(data)
                local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
                if not targetPlayer or targetPlayer == -1 then return end

                RequestLeashAttach(GetPlayerServerId(targetPlayer))
            end,
        },
        {
            name = 'qbx_k9unit:attachLeashAsK9',
            icon = 'fas fa-dog',
            label = locale('movement.attach_leash_k9_target_label'),
            distance = LEASH_TARGET_DISTANCE_FACTOR * Config.LeashMaxDistance,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.LeashMechanics then return false end
                if IsLeashed() then return false end
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't target self

                -- K9 direction: any nearby player is a plausible prospective
                -- handler -- no cheap client-side "is that specific player
                -- department-eligible" check exists (same tradeoff this
                -- file's "Certify K9 Handler" option below already
                -- documents), so this shows broadly and CheckLeashEligibility
                -- (server/main.lua) answers with a specific reason either way.
                return IsOwnModelK9()
            end,
            onSelect = function(data)
                local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
                if not targetPlayer or targetPlayer == -1 then return end

                RequestLeashAttach(GetPlayerServerId(targetPlayer))
            end,
        },
    })
end

-- Register the "Certify K9 Handler" / "Revoke K9 Certification" ox_target
-- options on nearby player peds (DEVELOPER_REFERENCE.md §4.3's flow table, §8 step 3 —
-- this is the gap integration-verifier flagged: the server-side grant/
-- revoke system in server/certifications/ was fully implemented and
-- correct, but was only reachable via /k9certify [id] / /k9decertify [id],
-- never through any in-world interaction). Mirrors the "Attach Leash"
-- option's structure immediately above: DISPLAY-ONLY plausibility gates
-- here, the server independently re-validates granter eligibility
-- (IsEligibleCertifier), proximity (Config.CertifyProximityMeters), and
-- (grant-only) the target's live model in GrantCertification /
-- RevokeCertification — see server/certifications/'s header for the
-- full contract and its quoted DEVELOPER_REFERENCE.md §4.3 security note. Deliberately
-- does NOT attempt to check "is the local player an eligible certifier"
-- client-side: IsEligibleCertifier is a server-only check with no cheap
-- client-side equivalent (it reads qbx_core job/grade data this client
-- doesn't have), and a new callback purely to gate visibility isn't worth
-- adding here — showing the option broadly (to any player near a
-- K9-modeled ped) and letting the server accept-or-reject-with-notification
-- is the exact same tradeoff the leash option above already makes.
--
-- No Config.Features flag gates this pair, unlike every other ox_target
-- option in this resource (LeashMechanics above, VehicleEntryExit in
-- client/vehicle.lua, etc.): certify/revoke IS the access-control system
-- itself (DEVELOPER_REFERENCE.md hard requirement 2), not a togglable *feature area* sitting
-- behind that system the way Phase 1+'s other leaf features are framed in
-- §3's acceptance criteria ("every leaf feature... has a corresponding
-- Config.Features.X"). config.lua has no Certifications/CertifyHandler
-- entry in Config.Features, and the existing /k9certify, /k9decertify,
-- /k9decertifyoffline commands are likewise registered unconditionally —
-- this follows that same, already-established convention rather than
-- inventing a new toggle for it.
--
-- NO THIRD-EYE CERTIFY / REVOKE. Certifying and decertifying are done on
-- the K9 Command Tablet only (owner's choice); the walk-up "Certify K9
-- Handler" / "Revoke Certification" options were removed.

-- ======================================================================
-- MOVE-RATE COMPOSER (DEVELOPER_REFERENCE.md §13.0 Decision 2) -- REAL BUG FIX,
-- qa-tester finding: client/wellbeing.lua (Phase 4) writes
-- K9MoveRateModifiers.fatigue and calls RecomputeK9MoveRate()
-- unconditionally (no existence guard, unlike client/progression.lua's own
-- defensive `if K9MoveRateModifiers then`/`type(RecomputeK9MoveRate) ==
-- 'function'` checks) on the assumption that THIS FILE defines both --
-- which, until this pass, it did not: neither symbol existed anywhere in
-- this codebase (confirmed by grep before this pass). The moment any
-- wellbeing feature flag flips true, client/wellbeing.lua's own
-- ApplyMoveRateModifiers() would hard-error on its very first write
-- ("attempt to index a nil value") -- latent only because every wellbeing
-- flag defaults to false in config.lua. This section is the real fix:
-- implementing the composer for real, not bolting a guard onto
-- wellbeing.lua that would have silently swallowed every wellbeing
-- speed-penalty write instead (a worse failure -- it would look like it
-- works while doing nothing).
--
-- WHY THIS LIVES HERE: this file already owns every other "own body,
-- native locomotion" concern (camera mode, AgilityBasicJump's suppression
-- below, the leash elastic pull-back above) -- DEVELOPER_REFERENCE.md §13.3's
-- file/module plan names this file as the composer's home for exactly
-- that reason, not a new module.
--
-- WHY MULTIPLICATIVE COMPOSITION: each contributing system (Fatigue,
-- Injury, Mood, XPProgression's tier bonus, and the reserved slot for
-- Phase 3's PropDragging) expresses its own effect as an independent
-- fractional scale of NORMAL speed (e.g. "0.85x while fatigued", "1.15x at
-- Elite tier") -- these are proportions of the base rate, not independent
-- absolute deltas meant to be summed. Proportional penalties should
-- compound proportionally: 0.85 * 0.85 (a fatigued AND injured K9 running
-- two independent 15% penalties) is the mathematically correct combined
-- effect; an additive model (1 - (0.15 + 0.15)) would need a different
-- unit entirely and doesn't generalize past two simultaneous penalties
-- without going negative. Multiplying every active modifier together is
-- the standard way to combine several independent fractional-scale
-- effects, and it has the convenient property that any modifier left at
-- its neutral default of 1.0 (an inactive/disabled system) is a true no-op
-- in the product -- nothing below has to special-case "this system isn't
-- contributing right now."
--
-- CLAMP RANGE [0.1, 2.0], AND WHY: mirrors this codebase's own established
-- defensive-clamping precedent for exactly this failure class -- the
-- `math.max(_, 0.1)` floor this file's own leash pull-back thread already
-- uses above (zoneSize guard) and client/tracking.lua uses twice
-- (sampleIntervalMeters/markerSpacing guards) against a
-- misconfigured-to-zero-or-negative value. 0.1 as the floor: the lowest
-- realistic legitimate combination shipped today (Injury 0.7 * Fatigue
-- 0.85 * Mood 0.9 ~= 0.535, config.lua's Config.Wellbeing) sits
-- comfortably above it, so this floor is a defensive backstop against a
-- MISCONFIGURED multiplier (a config typo, or a future PropDragging value
-- near 0) freezing the K9 solid, not a value any correct combination of
-- today's shipped systems is expected to reach. 2.0 as the ceiling:
-- today's highest shipped multiplier (XPProgression's Elite tier, 1.15,
-- config.lua's Config.XPTiers) is well under it, so 2.0 exists purely to
-- stop a misconfigured or unreviewed-future-system multiplier from
-- launching the K9 to an unreasonable speed, while leaving generous
-- headroom for a legitimate future stacked-bonus design without needing
-- this clamp revisited.
--
-- ======================================================================
-- EXPLICIT INDIVIDUAL OVERRIDE VS. AUTOMATIC MULTIPLIER -- TWO DIFFERENT
-- QUESTIONS, TWO DIFFERENT CEILINGS (GAP 1, PART 2 -- "a setting that
-- saves, displays, and silently does nothing"). REAL BUG, FOUND BY TRACING
-- server/k9profiles.lua's per-individual override all the way through
-- server/progression.lua's tier-snapshot push to THIS composer's own
-- single clamp above: a high-command officer's deliberately-typed,
-- server-audited speedMultiplier override (server/k9profiles.lua,
-- validated up to that file's own MAX_SPEED_SCENT_MULTIPLIER, 10.0 by
-- default) arrived here exactly like any other contributor, was multiplied
-- in correctly via K9MoveRateModifiers.xpTier, and was then silently
-- clamped back down to 2.0 by the SAME line that (correctly) protects
-- against a misconfigured AUTOMATIC multiplier -- saved, displayed,
-- audited, and inert, with nothing anywhere telling the officer who set
-- it. See server/k9profiles.lua's own header "GAP 1, PART 2" for the full
-- incident writeup, the engine-limit research this fix is grounded in, and
-- the save-time honesty half of the fix (a plain-English note/rejection at
-- the moment an officer saves an affected value) -- this comment covers
-- only the CLIENT half: why the ceiling itself now has two answers instead
-- of one.
--
-- THE CLAMP CANNOT TELL THE TWO CASES APART FROM THE NUMBER ALONE, on
-- purpose -- 5.0 in K9MoveRateModifiers.xpTier means something completely
-- different depending on WHERE it came from: an unreviewed config typo (a
-- real, still-live risk this composer must still catch) or a specific
-- officer's specific, audited, deliberate decision about a specific dog
-- (which the owner explicitly asked to have no ceiling). The fix is not
-- "raise 2.0" -- that would just move the identical silent-mismatch bug to
-- a new number, AND weaken the real protection 2.0 still correctly
-- provides against every AUTOMATIC system (fatigue/injury/mood/breed/
-- dragging, and a non-overridden xpTier value). The fix is a SECOND,
-- separate ceiling, selected by a boolean this composer did not have
-- before: `K9IndividualSpeedOverrideActive` (declared just below).
--
-- WHY THE NUMBER NEEDED NO CHANGE AT ALL, ONLY A MISSING SIGNAL:
-- server/k9profiles.lua's GetK9EffectiveMultipliers REPLACES (never
-- stacks/multiplies) a citizenid's plain tier speedMultiplier with the
-- override's own value when one is set -- so K9MoveRateModifiers.xpTier
-- (written by client/progression.lua, unchanged by this pass) is, at all
-- times, already "the one true speed number for this citizenid right
-- now," whichever of the two produced it. What was missing was WHICH of
-- the two produced it -- a fact server/progression.lua's own
-- BuildEffectiveTierSnapshot (a file this pass does not own) never
-- forwarded, since it only ever needed the number for its own, pre-existing
-- purpose. Rather than extend that cross-file snapshot's shape,
-- server/k9profiles.lua pushes the ONE missing boolean directly, over its
-- own brand new, narrow, self-contained event -- see
-- 'qbx_k9unit:client:k9SpeedOverrideStatus' below for the receiving half.
--
-- MOVE_RATE_MAX (2.0) IS UNCHANGED AND STILL APPLIES to every composed
-- value while K9IndividualSpeedOverrideActive is false -- this is NOT a
-- ceiling increase for the common case, only a documented, disclosed
-- EXCEPTION for the one case that is provably not "automatic": an already
-- human-reviewed, server-validated, audited individual override.
-- MOVE_RATE_OVERRIDE_MAX applies INSTEAD OF MOVE_RATE_MAX (never on top of
-- it, never stacked) to the FINAL composed value while an override is
-- active -- not merely to the raw override number in isolation -- because
-- the automatic modifiers (breed in particular, documented up to 1.03) are
-- still multiplied in on top of an overridden speed value, and a maxed-out
-- override (10.0) combined with a fast breed could otherwise nudge the
-- FINAL number a few percent past what the engine itself can actually do.
-- MOVE_RATE_MIN (the floor) is UNCHANGED and UNCONDITIONAL either way --
-- see this section's own "CLAMP RANGE" paragraph above: a frozen player is
-- a trapped player, override or not, and this pass does not bend that.
--
-- DISCLOSED, HONEST RESIDUAL GAP (not solved here, not hidden either):
-- server/k9profiles.lua's own IsValidSpeedMultiplier rejects, at save
-- time, a raw override value that is DETERMINISTICALLY guaranteed to be
-- floor-clamped (at/under 0.1, with every other modifier neutral). It
-- CANNOT deterministically catch a value ABOVE that floor which only
-- breaches it once combined, AT RUNTIME, with a low-enough simultaneous
-- combination of fatigue/injury/mood/dragging (all of which change
-- continuously and are not knowable at save time) -- nor can it catch the
-- mirror case at the top end (an override combined with a fast breed
-- nudging past MOVE_RATE_OVERRIDE_MAX, described above). Both residual
-- cases are rare (they require an ALREADY near-extreme override typed
-- deliberately, combined with a coincident extreme automatic state), are
-- bounded by the SAME two hard clamps every other caller of this composer
-- already relies on, and are NOT the "ordinary value silently does
-- nothing" failure shape this pass exists to close -- they are the clamps
-- doing exactly the job they were always meant to do. No live push-back-
-- to-the-tablet warning is built for either (impractical for a dynamic,
-- small-magnitude, rare edge case) -- flagged honestly in this pass's own
-- report instead of silently accepted.
-- ======================================================================
--
-- INTERACTION CHECK WITH THIS FILE'S OTHER MOVEMENT LOGIC (done before
-- writing this, per this task's explicit instruction):
--   - AgilityBasicJump's suppression thread below calls
--     DisableControlAction(0, INPUT_JUMP/INPUT_DUCK, true) every frame --
--     a different native entirely (blocks an input action, doesn't touch
--     move rate) -- no interaction with SetPedMoveRateOverride below.
--   - The leash elastic pull-back thread above corrects position directly
--     via SetEntityCoords, never via a move-rate override -- again no
--     shared native, no interaction. A leashed K9's move RATE (as opposed
--     to how far it's allowed to drift from its partner) is unaffected by
--     leash state and is expected to keep responding normally to whatever
--     this composer computes.
--   - client/agility.lua's AgilityAdvanced vault (extracted from this file,
--     this pass — see this file's own "EXTRACTED" header note) drives an
--     instantaneous velocity impulse via SetEntityVelocity, a one-shot
--     native distinct from the persistent move-rate override this
--     composer maintains -- no interaction (a vault's brief arc is an
--     externally-applied velocity kick, not ground-locomotion animation
--     speed, which is the documented scope of SetPedMoveRateOverride).
--   - This resource's ONLY call site for SetPedMoveRateOverride, anywhere,
--     is RecomputeK9MoveRate() below (confirmed by grep before writing
--     this) -- exactly DEVELOPER_REFERENCE.md §13.0 Decision 2's "one and only
--     call" requirement.
--
-- CONFIDENCE NOTE ON SetPedMoveRateOverride ITSELF, stated honestly per
-- this codebase's own convention (see client/hud.lua's "STAMINA NATIVE --
-- CONFIDENCE NOTE" for the standard this follows): the native's
-- NAME/existence as a real, callable FiveM ped native is HIGH confidence
-- (linked from DEVELOPER_REFERENCE.md#phase-3-combat's own
-- natives-to-verify list, and independently named by both
-- DEVELOPER_REFERENCE.md §12.5.4 and DEVELOPER_REFERENCE.md §13.0 as the intended
-- mechanism for exactly this class of effect -- multiple independent
-- planning passes converge on the same native). Its PRECISE runtime
-- semantics -- specifically (a) whether a set value persists indefinitely
-- until explicitly changed vs. decaying/resetting on its own, and (b)
-- whether it needs to be re-asserted every tick to keep affecting a live
-- player ped, the way DisableControlAction's own contract explicitly
-- requires -- were NOT independently re-verified against
-- raw.githubusercontent.com/citizenfx/natives or a live client this
-- session. DEVELOPER_REFERENCE.md §12.5.4 already flags an expectation that
-- PropDragging will need to "re-assert every tick" for this same native.
-- This composer is written to be SAFE either way regardless of which is
-- true: every real caller (client/wellbeing.lua on each pushed snapshot,
-- client/progression.lua on each tier change, and this file's own
-- onResourceStop reset below) re-invokes RecomputeK9MoveRate() on its own
-- change events rather than assuming one set-and-forget call is
-- sufficient, so if the native DOES require periodic re-assertion, the
-- overall system degrades to "correct within one state-change event," not
-- "silently wrong forever." A native-api-assistant pass to independently
-- confirm exact persistence semantics is recommended before this ships to
-- a live server, same standard this file already applies to its own
-- door-interaction natives (and client/agility.lua applies to its own
-- AgilityAdvanced natives).
-- ======================================================================

--- Named multiplier contributions toward the K9's own single effective
--- move-rate override (DEVELOPER_REFERENCE.md §13.0 Decision 2). Every contributing
--- system sets its OWN named key here and then calls RecomputeK9MoveRate()
--- -- nothing should ever call SetPedMoveRateOverride directly except
--- RecomputeK9MoveRate() itself, below. An absent/nil key is treated
--- identically to 1.0 (no effect) by the compose loop below, so a
--- contributing system whose owning Config.Features flag is disabled
--- simply never touches its key and never affects the product.
---
--- SCOPE, CORRECTED (this pass -- two independent agents separately found
--- the same real bug, confirmed here and fixed below): RecomputeK9MoveRate()
--- used to be HARD-GATED on IsOwnModelK9() ALONE -- it reset to neutral and
--- returned early for any ped IsOwnModelK9() did not recognize. That gate's
--- own justification used to claim "there is no modifier here that would
--- ever mean anything on a human ped in the first place" -- TRUE when this
--- composer was wellbeing/XP-only, but FALSIFIED the moment
--- client/pursuitsprint.lua landed: that file's own header states, at
--- length, "ANY PED, GATED ON ROLE/CERTIFICATION, NEVER ON PED MODEL" and
--- deliberately writes K9MoveRateModifiers.pursuitSprint for a role-holder
--- regardless of model. With the old gate, that promise was false in
--- practice: a role-holder on a non-K9 body got the server's grant, the
--- "activated" toast, and a silent no-op speed-wise, in two real,
--- non-hypothetical configurations --
---   (a) Config.K9Appearance.requireK9ModelForRole = true (a real, named,
---       supported mode -- client/pursuitsprint.lua's own header names this
---       EXACT mode as the one it is trying not to depend on, yet ended up
---       depending on transitively through this function); and
---   (b) even at the false DEFAULT, for a K9-access holder whose access
---       comes from server/certifications/'s HasK9Access() High Command
---       or autoAccessGrade bypass rather than an actual certification --
---       server/appearance.lua's own header states HasK9Role()/IsK9Role()
---       "Deliberately EXCLUDES the autoAccessGrade/high-command BYPASSES
---       inside HasK9Access()", so IsOwnModelK9()'s own IsK9Role() widening
---       (see client/main.lua) never covers this case, even though
---       server/pursuitsprint.lua's grant is bare HasK9Access(src) with no
---       IsK9Role/model check of its own at all.
---
--- THE FIX: the early-return condition below is now
--- `not (IsOwnModelK9() or HasK9Access())`, not `not IsOwnModelK9()` alone.
--- HasK9Access() -- NOT IsK9Role()/CanShowK9UI() -- is the deliberate choice
--- for the second half of that OR, for two reasons: (1) it is the EXACT
--- same server-side check server/pursuitsprint.lua's grant already uses
--- (HasK9Access(src), a pure role/certification check, per
--- server/certifications/'s own "ROLE/MODEL DECOUPLING" header), so this
--- client-side mirror cannot under- or over-cover what the server actually
--- grants; IsK9Role() would silently exclude the autoAccessGrade/High
--- Command case by the same documented design decision that creates gap
--- (b) above, and CanShowK9UI() is narrower still (it ANDs a role check
--- in), which would regress today's working "uncertified player wearing a
--- K9 skin still gets breed weight" case this composer's model half
--- already covers on its own. (2) this resource already has an established
--- precedent for exactly this shape: client/fetch.lua's
--- RequestThrowFetchBall() and client/radial.lua's "Throw" item are both
--- documented, deliberately gated on "HasK9Access() alone, NOT
--- CanShowK9UI()/IsOwnModelK9()" for the identical reason (a human-handler
--- action must not depend on being modeled as a K9) -- this fix reuses that
--- same idiom rather than inventing a new one. Performance: `or`
--- short-circuits, so HasK9Access()'s own (already 1000ms-TTL-cached)
--- network round trip is only ever consulted when IsOwnModelK9() is
--- false -- the common, already-K9-modeled case pays nothing extra.
---
--- STILL TRUE, UNCHANGED BY THIS FIX: (1) RecomputeK9MoveRate() takes no ped
--- argument at all -- it only ever reads PlayerPedId(), the CALLING
--- CLIENT's own currently-controlled ped, never an arbitrary target entity;
--- (2) every modifier key in this table is only ever written by a caller
--- for THAT SAME client (client/wellbeing.lua and client/progression.lua
--- both scope their writes to their own eligibility gate first; `breed`,
--- is written by THIS FILE itself, from INSIDE RecomputeK9MoveRate(),
--- after the OR-gate above has already passed -- see "BREED MOVE-RATE
--- WEIGHT" near K9MoveRateModifiers' own declaration; note `breed` itself
--- still naturally resolves to the neutral 1.0 default for a non-K9 model
--- either way, since K9BreedSpeedMultiplierByModelHash is keyed purely by
--- Config.Peds models -- widening this gate restores fatigue/mood/injury/
--- xpTier/pursuitSprint for a role-holder off-model, not a breed value that
--- was never meaningful off-model to begin with). A caller
--- that genuinely needs to set a DIFFERENT (non-K9, or not-necessarily-K9)
--- ped's move rate cannot route through this composer at all -- it must
--- call SetPedMoveRateOverride directly on that ped instead. This already
--- happened once: client/combat.lua's PropDragging runs its speed-limit
--- handler on the dragged TARGET's own client (each client only reliably
--- controls its own ped, same reasoning this file's leash pull-back thread
--- above documents), and the overwhelmingly common target is a human
--- suspect, not another K9 -- see that file's own "MOVE-RATE COMPOSER
--- SCOPE" header comment for the full resolution it shipped (route through
--- this composer only when IsOwnModelK9() is true for the applying client,
--- call SetPedMoveRateOverride directly otherwise). That resolution predates
--- this fix and is NOT touched by it (client/combat.lua is a different
--- file's ownership) -- but the exact same "ANY PED" reasoning that
--- motivated widening the gate here may be worth re-checking there too, for
--- a K9-role handler who is dragging a prop while on a non-K9 body; flagged
--- as a related, out-of-scope observation, not fixed in this pass.
---
--- NOT THE SAME DECISION AS AgilityBasicJump/wellbeing's injured-sprint
--- block, AND MUST NOT BE UNIFIED WITH THEM: this gate answers "does the
--- calling client currently have a legitimate ROLE-based reason for a move-
--- rate EFFECT to apply", which is exactly why it now includes HasK9Access().
--- AgilityBasicJump's jump/crouch suppression below and
--- client/wellbeing.lua's own injured-sprint block instead answer "can this
--- ped's own SKELETON/RIG physically jump or sprint the way a human's can",
--- which is a body/animation-rig question with no role component at all --
--- a four-legged model has no jump animation regardless of who is playing
--- it, and a human-shaped role-holder never lost anything a jump animation
--- would have given them. That is the owner's own recorded decision (see
--- AgilityBasicJump's own comment below, "OWNER'S DECISION, 2026-08-25:
--- MODEL, not role") and is deliberately left exactly as-is by this pass --
--- do not "fix" it to match this OR-gate, and do not narrow this OR-gate to
--- match it. Two different questions, two different answers, both correct.
--- @type table<string, number>
K9MoveRateModifiers = {
    fatigue = 1.0,  -- client/wellbeing.lua, Config.Features.FatigueSystem
    xpTier = 1.0,   -- client/progression.lua, Config.Features.XPProgression
    dragging = 1.0, -- RESERVED for Phase 3's PropDragging (client/combat.lua, DEVELOPER_REFERENCE.md §12.5.4) -- not yet a real contributor; present so that file's eventual composer write has a ready slot without needing to edit this table.
    breed = 1.0,    -- THIS FILE's own contribution -- see "BREED MOVE-RATE WEIGHT" below. Recomputed fresh on every RecomputeK9MoveRate() call from the CALLING client's own current ped model, never left stale across a model change the way a server-pushed modifier (xpTier) could be.
}

-- ======================================================================
-- BREED MOVE-RATE WEIGHT (DEVELOPER_REFERENCE.md Part A §4 -- "give Config.Peds'
-- breed data actual mechanical weight"). Config.Peds entries carry no
-- per-model stat today (README.md: every recognized K9 model is
-- mechanically identical). This section gives ONE stat -- base move
-- speed -- real, live weight, through this composer's own `breed` slot
-- above, per this task's explicit instruction: "if breed affects movement,
-- it MUST go through that composer and reserve its own slot; do not call
-- SetPedMoveRateOverride directly, and do not stack a second clamp." This
-- section does neither -- it only ever writes K9MoveRateModifiers.breed
-- and relies entirely on RecomputeK9MoveRate()'s own single
-- SetPedMoveRateOverride call and single [0.1, 2.0] clamp below.
--
-- CONFIG FIELD: `Config.Peds[n].speedMultiplier` (number, optional).
-- CORRECTED (this pass, coder-backend): this comment used to say the field
-- was not yet in config.lua and was reported separately -- re-verified
-- false by direct read. config.lua's own Config.Peds entries now carry
-- this field (Shepherd 1.00, Rottweiler 0.98, Husky 1.03, Chop 1.00 --
-- matching the values this section originally proposed). Still read
-- defensively below (`type(...) == 'number'` guard), so a custom/streamed
-- entry an operator adds WITHOUT this field still safely resolves to the
-- neutral 1.0 default rather than erroring.
--
-- PRECOMPUTED ONCE AT FILE LOAD, keyed by GetHashKey(pedEntry.model) --
-- mirrors client/main.lua's own K9ModelHashes construction loop exactly
-- (same source table, same per-entry GetHashKey call), but this is NOT a
-- second copy of that file's consolidated "is this a recognized K9 model"
-- boolean set (DEVELOPER_REFERENCE.md item 3, IsEntityModelK9/K9ModelHashes --
-- six prior duplicates of THAT specific check were found and deleted; see
-- client/main.lua's own header). This table answers a genuinely different
-- question no existing table in this resource answers -- "what breed-
-- specific speed MULTIPLIER does this recognized model carry" -- so it is
-- additive, not a regression of that consolidation. Kept as its own local
-- copy rather than reusing client/main.lua's K9ModelHashes (a plain
-- hash->true set has no multiplier value to read out of it).
--
-- SPREAD, AND WHY IT STAYS SMALL: this is a flavor/identity axis, not a
-- second progression system -- Config.XPTiers' OWN speedMultiplier already
-- spans 1.00 -> 1.15 (a full session-to-session progression arc) and
-- composes multiplicatively with this one. A breed axis anywhere near that
-- size would let breed choice alone rival hours of earned progression,
-- and a large spread on a single axis structurally means whichever breed
-- sits at the top of it is the unconditionally fastest pick -- there is no
-- second axis for a small spread to trade off against. Proposed values
-- (report to config.lua's owner, not applied by this pass) span only
-- 0.98 - 1.03 (5 percentage points total): Husky 1.03 (bred for
-- endurance/speed), Shepherd 1.00 (baseline -- see this section's own
-- "OTHER STATS" note below for why its specialty is elsewhere), Chop 1.00
-- (the roster's generic/mascot entry -- deliberately neutral), Rottweiler
-- 0.98 (bulkier gait). See "OTHER STATS" below for why Rottweiler being
-- slowest here is a trade-off, not a flaw.
--
-- OTHER STATS CONSIDERED, AND WHY ONLY SPEED IS WIRED THIS PASS: scent
-- range (server/tracking.lua's findTrackableSource, which already applies
-- Config.XPTiers' own scentRangeMultiplier) and bite-and-hold effectiveness
-- (server/combat.lua) are the two other mechanics this resource's own
-- multiplier conventions could plausibly extend to a breed. Both live in
-- files this pass does not own (concurrently owned by another agent this
-- session) -- reported as a precise, ready-to-apply follow-up rather than
-- edited here (see this pass's own report for the exact proposed
-- Config.Peds.scentRangeMultiplier/biteMultiplier values and the small
-- tracking.lua diff this would need), specifically so that ONCE wired, no
-- single breed ends up strictly dominant across all three axes: Husky
-- trades scent for speed, Rottweiler trades speed for (future) bite power,
-- Shepherd trades (future) bite power for scent, and Chop stays neutral
-- across all three -- every pairwise comparison has at least one axis each
-- breed wins, by construction (verified by hand this pass, not asserted).
-- ======================================================================
-- DEFENSIVE READ on Config.Peds itself (`type(...) == 'table'` guard, not a
-- bare `ipairs(Config.Peds)`): this loop runs at THIS FILE's own load time,
-- same as client/main.lua's K9ModelHashes loop -- a missing/malformed
-- Config.Peds would otherwise throw here and take the whole client resource
-- down before a single line of gameplay code ever ran. server/certifications/
-- already asserts Config.Peds is a real, non-empty array at SERVER resource
-- start, but that assert cannot protect a CLIENT file's own independent
-- load, and does not run at all inside this suite's sandbox (tests/fixtures/
-- sandbox.lua loads this file directly, with whatever minimal Config fixture
-- each spec supplies -- several existing specs for this file supply no
-- `Config.Peds` at all, since they predate this addition).
local K9BreedSpeedMultiplierByModelHash = {}
if type(Config.Peds) == 'table' then
    for _, pedEntry in ipairs(Config.Peds) do
        if type(pedEntry) == 'table' and type(pedEntry.model) == 'string' then
            local multiplier = pedEntry.speedMultiplier
            K9BreedSpeedMultiplierByModelHash[GetHashKey(pedEntry.model)] =
                (type(multiplier) == 'number' and multiplier > 0) and multiplier or 1.0
        end
    end
end

local MOVE_RATE_MIN = 0.1 -- see this section's header comment for the full clamp-range justification
local MOVE_RATE_MAX = 2.0 -- AUTOMATIC-modifier ceiling, UNCHANGED by GAP 1 PART 2 -- see "EXPLICIT INDIVIDUAL OVERRIDE VS. AUTOMATIC MULTIPLIER" above

--- The REAL, documented ceiling of the underlying SET_PED_MOVE_RATE_OVERRIDE
--- native itself -- see "EXPLICIT INDIVIDUAL OVERRIDE VS. AUTOMATIC
--- MULTIPLIER" above and server/k9profiles.lua's own header "GAP 1, PART 2"
--- for the full research writeup (Rockstar native, PED namespace,
--- documented [0.00, 10.00] range, HIGH confidence; one disclosed,
--- unverified, LOW-confidence counter-claim not acted on). Hardcoded, NOT
--- owner-editable -- this is a fact about the game engine, not a policy
--- choice. Duplicated in server/k9profiles.lua's own MOVE_RATE_ENGINE_MAX
--- (this resource's established "duplicated, not shared" convention) -- the
--- two MUST be kept in agreement, or this exact bug reopens in a new shape.
local MOVE_RATE_ENGINE_MAX = 10.0

--- Mirrors server/k9profiles.lua's own ResolveMaxSpeedScentMultiplier
--- (same "duplicated, not shared" convention, same clamp-and-warn-never-
--- assert shape), but ADDITIONALLY capped by MOVE_RATE_ENGINE_MAX above --
--- so an owner who raises the shared Config.MaxSpeedScentMultiplier past 10
--- for scentRangeMultiplier's sake (which has no engine ceiling of its own
--- at all -- see server/k9profiles.lua's header) can never thereby also ask
--- THIS composer to exceed what the engine can physically do. Falls back to
--- MOVE_RATE_ENGINE_MAX itself (not some other arbitrary number) for
--- anything that is not a real, positive, finite number -- the same
--- "missing/invalid config degrades to the safe, real engine limit, never
--- to something worse" posture server/k9profiles.lua's own resolver
--- documents for its own fallback.
--- @return number
local function ResolveMoveRateOverrideCeiling()
    local raw = Config and Config.MaxSpeedScentMultiplier
    local value = tonumber(raw)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or value <= 0 then
        value = MOVE_RATE_ENGINE_MAX
    end
    return math.min(value, MOVE_RATE_ENGINE_MAX)
end
local MOVE_RATE_OVERRIDE_MAX = ResolveMoveRateOverrideCeiling()

-- Tracks the last value THIS resource actually applied via
-- SetPedMoveRateOverride, so onResourceStop below only resets the native
-- when this resource actually changed it away from neutral -- same "don't
-- clobber state we never touched" discipline as this file's existing
-- isFirstPersonK9View onResourceStop handler above.
local lastAppliedMoveRate = 1.0

--- Whether the CALLING CLIENT's own citizenid currently carries a
--- server-audited INDIVIDUAL speed override (server/k9profiles.lua's
--- per-individual override layer) -- see "EXPLICIT INDIVIDUAL OVERRIDE VS.
--- AUTOMATIC MULTIPLIER" above for the full reasoning this flag exists to
--- support. Written ONLY by the 'qbx_k9unit:client:k9SpeedOverrideStatus'
--- handler below -- read ONLY by RecomputeK9MoveRate()'s own ceiling
--- selection immediately below it. Starts false (the safe, tighter
--- default) until/unless server/k9profiles.lua's own initial-connect push,
--- restart backfill, or a live edit says otherwise -- so a brand new
--- session, or a client resource restart racing that push, degrades to the
--- OLD, tighter 2.0 ceiling rather than to the wide one, matching this
--- file's own established "when in doubt, fail toward the more
--- conservative state" posture elsewhere (e.g. the ANY-PED move-rate gate's
--- own reset-to-neutral branch above).
local K9IndividualSpeedOverrideActive = false

--- The single, only call site for SetPedMoveRateOverride in this resource
--- (DEVELOPER_REFERENCE.md §13.0 Decision 2). Composes every entry currently in
--- K9MoveRateModifiers multiplicatively (see this section's header comment
--- for why multiplicative, not additive), clamps the result defensively,
--- and applies it once. Safe to call at any time, from any file, whether
--- or not the local player currently has a valid/K9 ped -- every early
--- return below is a deliberate no-op, never an error.
function RecomputeK9MoveRate()
    local ped = PlayerPedId()
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return -- no valid ped to apply anything to yet (e.g. between spawns) -- nothing to do, not an error
    end

    if not (IsOwnModelK9() or HasK9Access()) then
        -- Neither on a recognized K9 model NOR currently holding real K9
        -- access (server-authoritative HasK9Access(), the same check
        -- server/pursuitsprint.lua's own grant uses) -- see this table's own
        -- "SCOPE, CORRECTED" header comment above for the real bug this OR
        -- replaces (a bare IsOwnModelK9() check) and why. Reset to neutral
        -- rather than silently no-op-ing: FiveM's SetPlayerModel keeps the
        -- SAME ped index across a model swap, so a stale non-1.0 override
        -- applied while this ped last qualified (by EITHER model or access)
        -- could otherwise persist onto a player who currently qualifies by
        -- neither -- e.g. a K9-to-human model change for someone who also
        -- holds no K9 access, or a certification/access revocation for
        -- someone who was never K9-modeled to begin with.
        if lastAppliedMoveRate ~= 1.0 then
            SetPedMoveRateOverride(ped, 1.0)
            lastAppliedMoveRate = 1.0
        end
        return
    end

    -- BREED MOVE-RATE WEIGHT -- see this table's own declaration/header
    -- above for the full reasoning. Recomputed from the CURRENT model on
    -- every call (never cached across a model change) -- cheap (a single
    -- table lookup keyed by a hash this line already needs to read once),
    -- and correct regardless of whether this composer happens to run
    -- again before or after a K9-to-K9 model swap (there is no such swap
    -- in this resource today, but nothing here assumes there cannot be
    -- one later).
    K9MoveRateModifiers.breed = K9BreedSpeedMultiplierByModelHash[GetEntityModel(ped)] or 1.0

    local effective = 1.0
    for _, modifier in pairs(K9MoveRateModifiers) do
        if type(modifier) == 'number' then
            effective = effective * modifier
        end
        -- non-number entries are ignored defensively rather than erroring
        -- -- should never happen with every documented caller, but a
        -- composer this many independent systems write into is exactly the
        -- kind of shared state worth being defensive about.
    end

    -- CEILING SELECTION -- see "EXPLICIT INDIVIDUAL OVERRIDE VS. AUTOMATIC
    -- MULTIPLIER" above for the full reasoning. K9IndividualSpeedOverrideActive
    -- picks between the two ceilings; MOVE_RATE_MIN (the floor) is applied
    -- either way, unconditionally, never bypassed.
    local ceiling = K9IndividualSpeedOverrideActive and MOVE_RATE_OVERRIDE_MAX or MOVE_RATE_MAX
    effective = math.max(MOVE_RATE_MIN, math.min(ceiling, effective))

    SetPedMoveRateOverride(ped, effective)
    lastAppliedMoveRate = effective
end

--- Server-authoritative push: server/k9profiles.lua tells THIS client
--- whether ITS OWN citizenid currently carries a live individual speed
--- override, independent of (and delivered alongside, not instead of) the
--- NUMBER itself, which still arrives exactly as before via
--- client/progression.lua's own K9MoveRateModifiers.xpTier write -- see
--- this section's own header for why the number needed no change at all,
--- only this one boolean was ever missing. Fired by server/k9profiles.lua
--- on: this citizenid's own initial connect, a resource restart while
--- already connected (that file's own onResourceStart backfill loop), and
--- immediately after every k9ProfileUpsert/k9ProfileReset edit that changes
--- it -- see that file's own header "GAP 1, PART 2" for the full trace.
--- @param status { active: boolean }
RegisterNetEvent('qbx_k9unit:client:k9SpeedOverrideStatus', function(status)
    -- SOURCE-ORIGIN GUARD -- see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. A forged local
    -- TriggerEvent here would only ever be able to WIDEN this client's own
    -- ceiling from 2.0 to the engine's real 10.0 for whatever automatic
    -- modifiers already happen to be sitting in K9MoveRateModifiers at the
    -- time -- a real, if narrow, self-benefit vector, closed the same way
    -- every other 'qbx_k9unit:client:*' handler in this file already is.
    if source ~= 65535 then return end

    -- Defensive shape validation, same posture as client/progression.lua's
    -- own xpTierChanged ingest guard -- never assume a network payload
    -- arrives well-formed. A malformed/missing `active` degrades to
    -- `false` (the tighter, safer default), never to "leave whatever was
    -- there before" -- this event is meant to be a complete, authoritative
    -- statement of current status each time it fires, not a partial patch.
    K9IndividualSpeedOverrideActive = type(status) == 'table' and status.active == true

    RecomputeK9MoveRate()
end)

-- qa-tester-class hygiene, same reasoning as isFirstPersonK9View's own
-- onResourceStop handler above: a resource restart while a non-neutral
-- move-rate override is active would otherwise leave the K9 permanently
-- sped up/slowed down with no code left running to ever reverse it. Only
-- resets when THIS resource actually applied a non-1.0 value, so an
-- unrelated resource's own independent SetPedMoveRateOverride call (the
-- disclosed, pre-existing FiveM limitation DEVELOPER_REFERENCE.md §13.0 Decision 2
-- itself flags -- a single global-per-entity native this resource cannot
-- fully own) is never clobbered by this handler.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if lastAppliedMoveRate ~= 1.0 then
        local ped = PlayerPedId()
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            SetPedMoveRateOverride(ped, 1.0)
        end
        lastAppliedMoveRate = 1.0
    end
end)

-- ======================================================================
-- MOVE-RATE WATCHDOG -- closes a real, verified "unbounded trap" this
-- composer's own ANY-PED widening (the "SCOPE, CORRECTED" gate above,
-- `IsOwnModelK9() or HasK9Access()`) opened, found while auditing that fix
-- for a guaranteed removal path on losing the role ("close the any-ped
-- speed-system gap" task, this pass).
--
-- THE GAP, CONFIRMED BY READING THE REAL CALL GRAPH, NOT ASSUMED: every
-- caller of RecomputeK9MoveRate() other than this file's own onResourceStop
-- handler above is itself gated behind a SERVER-PUSHED event --
-- client/wellbeing.lua's wellbeingUpdate, client/progression.lua's
-- xpTierChanged, client/pursuitsprint.lua's own start/tick/end calls -- and
-- server/wellbeing.lua's own TickWellbeing (its one source for the first of
-- those three) skips its ENTIRE per-player body, including the broadcast
-- itself, the instant `ResolveK9Ped(source)` answers `isK9 = false` (that
-- file's own gate, `(looksLikeK9 or holdsK9Role) and HasK9Access(source)`).
-- Certification revocation (server/certifications/'s RevokeCertification)
-- sends the revoked player a plain ox_lib notify (NotifyPlayer) and NOTHING
-- else -- no event this file, client/wellbeing.lua, or client/progression.lua
-- listens for. Before the ANY-PED widening this was harmless: an off-model
-- player's gate was `not IsOwnModelK9()` alone, always true for them, so
-- RecomputeK9MoveRate() always forced 1.0 regardless of whether anything
-- ever called it again. AFTER the widening, an off-model role-holder can
-- carry a REAL non-1.0 rate (fatigue/injury/mood/xpTier/pursuitSprint) --
-- and if their role/access is revoked while they stay online and off-model,
-- NOTHING left in this resource ever calls RecomputeK9MoveRate() for them
-- again. The override applied at the moment of revocation would otherwise
-- persist until a full client relog or a restart of this resource -- exactly
-- the unbounded case this task's own rules forbid, and strictly worse than
-- the pre-widening behavior for exactly the population this widening was
-- meant to help.
--
-- THE FIX: a slow, self-gating poll that re-invokes RecomputeK9MoveRate()
-- ONLY while lastAppliedMoveRate is currently non-neutral -- i.e., only
-- while THIS resource genuinely believes it has a real effect applied right
-- now. This is deliberately NOT an unconditional "recompute for everyone,
-- always" loop: HasK9Access() is a network round trip once its own 1000ms
-- TTL cache (client/main.lua) lapses, and this poll's own interval is
-- longer than that TTL by design (see the interval constants below) -- an
-- unconditional loop would force a fresh server callback for EVERY
-- connected player, forever, the overwhelming majority of whom have never
-- touched a K9 feature at all, a real server-wide cost this design avoids
-- by construction. Gated on the cheap, purely-local lastAppliedMoveRate
-- comparison FIRST, so the idle case (the common case, for players who are
-- not currently benefiting from any move-rate effect) never even reads
-- IsOwnModelK9()/HasK9Access() at all.
--
-- Idles at MOVE_RATE_WATCHDOG_IDLE_MS while lastAppliedMoveRate == 1.0
-- (nothing to watch), tightens to MOVE_RATE_WATCHDOG_ACTIVE_MS once a real
-- effect is applied -- comparable in cadence to server/wellbeing.lua's own
-- TICK_INTERVAL_MS default (5000ms, Config.Wellbeing.tickIntervalMs), so
-- this does not introduce staleness meaningfully worse than what this
-- resource already accepts elsewhere for the SAME stats while everything is
-- working normally. Worst case, this thread is the ONLY thing that ever
-- notices a lost role/access again: convergence to neutral happens within
-- one MOVE_RATE_WATCHDOG_ACTIVE_MS window, never "forever."
--
-- Deliberately does NOT replace or duplicate any existing caller -- every
-- one of those still applies its own change immediately, on its own event,
-- exactly as before. This is a backstop for the specific case where no
-- such event ever arrives again, not a replacement for any of them.
-- ======================================================================
local MOVE_RATE_WATCHDOG_ACTIVE_MS = 5000
local MOVE_RATE_WATCHDOG_IDLE_MS = 15000

CreateThread(function()
    while true do
        if lastAppliedMoveRate ~= 1.0 then
            RecomputeK9MoveRate()
            Wait(MOVE_RATE_WATCHDOG_ACTIVE_MS)
        else
            Wait(MOVE_RATE_WATCHDOG_IDLE_MS)
        end
    end
end)

-- NOT THE SAME QUESTION AS THE MOVE-RATE COMPOSER ABOVE, DELIBERATELY: that
-- section's gate now includes HasK9Access() (a role check) alongside
-- IsOwnModelK9(), because a move-rate EFFECT is something a ROLE grants.
-- The suppression thread immediately below stays MODEL-only (IsOwnModelK9(),
-- unchanged by that fix) because it answers a different question entirely --
-- whether this ped's own SKELETON has a jump/crouch animation to suppress in
-- the first place, which no role grants or removes. See that section's own
-- "SCOPE, CORRECTED" comment for the full writeup of this distinction; do
-- not unify the two.
--
-- AgilityBasicJump (Config.Features.AgilityBasicJump): DEVELOPER_REFERENCE.md §6.1 bullet
-- 3 bundles jump AND crouch together ("The K9 player can run, jump, and
-- crouch using the native quadruped locomotion..."), matching this flag's
-- own inline comment ("native jump/crouch only, no fence-vault logic
-- yet") — so both controls are gated together here, not just jump.
--
-- When the flag is true (the Phase 1 default) AND nobody is per-person
-- blocked from it (see PER-PERSON BLOCK below), native jump/crouch just
-- works via the ped model's own locomotion — no thread is ever CREATED for
-- that case (avoiding an unnecessary always-on loop for the common/default
-- population), only for the two cases that actually need suppression.
--
-- When suppression IS needed (the flag is false, or a live per-person
-- block applies), jump/crouch must be actively suppressed for a K9-modeled
-- player, otherwise it's a no-op (the gap correctness-overseer originally
-- flagged for the flag alone: jump/crouch are inherent to any ped's native
-- locomotion and nothing gates them by default). DisableControlAction(0,
-- <control>, true) every frame is the standard FiveM pattern for
-- suppressing a specific native control action.
--
-- Control indices (HIGH confidence, standard/well-established GTA V
-- control mapping used throughout the FiveM ecosystem):
--   22 = INPUT_JUMP
--   36 = INPUT_DUCK (crouch)
--
-- OWNER'S CALL, NOT GUESSED (K9 role/model decoupling pass): this thread's
-- gate below is IsOwnModelK9(), a RESTRICTION, not an access grant — it
-- TAKES jump/crouch AWAY from whoever it applies to. IsOwnModelK9()'s own
-- widening (client/main.lua: `Config.K9Appearance.requireK9ModelForRole ==
-- false` makes it answer IsK9Role() instead of a pure model check) already
-- swept this in: at the shipped default, a certified handler who holds the
-- K9 role while still on a HUMAN model now also has jump/crouch suppressed
-- here, despite never having had quadruped locomotion to restrict in the
-- first place. Deliberately left AS-IS rather than "fixed" either
-- direction — reasonable owners could want either answer, and nothing
-- about this resource's own docs picks one. Reverting to model-only (jump/
-- crouch suppression applies ONLY to an actual K9-modeled ped, never a
-- human-modeled role-holder) is exactly a ONE-LINE change: replace
-- `IsOwnModelK9()` on the very next line with `IsEntityModelK9(PlayerPedId())`.
--
-- ======================================================================
-- PER-PERSON BLOCK (client/featureblocks.lua hand-off item 2 -- see that
-- file's own header for the full contract) -- THE ONE HAND-OFF ITEM THAT
-- NEEDED A REAL JUDGMENT CALL, not a mechanical copy of the ten call sites
-- that file's own pass added directly. Every one of THOSE ten gates an
-- ALREADY-LIVE per-tick/per-frame thread (that file's header, "WHERE THE
-- CHECK GOES, PER CALLER"). This one is not already live in the common
-- case: the block immediately below only ever created a thread when
-- Config.Features.AgilityBasicJump was false. At the shipped default
-- (true), NO thread of any kind existed here before this pass -- so there
-- was no per-tick condition to fold a block check into, and a per-person
-- block on this specific feature (while the GLOBAL flag stayed enabled)
-- had no code path capable of ever seeing it.
--
-- THE QUESTION: does an already-cheap `IsK9FeatureBlocked` read justify an
-- always-on thread for every K9-modeled ped, when the overwhelming common
-- case (no block on this feature for this person, true for every server
-- until a high-command tablet action ever changes it) needs to do nothing
-- at all? The hand-off note proposed a 1Hz poll. REJECTED, for a reason
-- stronger than "it has a small ongoing cost": 1Hz means up to a full
-- second between a block arriving and this thread ever noticing it, and
-- with a native as immediate as jump, that gap is not a rounding error --
-- "a jump suppression that reacts a second late is a jump that happened."
-- A slower decision interval cannot be traded for a lower steady-state
-- cost here the way it legitimately can be for, e.g., the MOVE-RATE
-- WATCHDOG above (that thread is a slow-converging BACKSTOP for a case
-- every other caller already handles immediately on its own -- this one
-- would be the ONLY thing that ever reacts to a fresh block at all).
--
-- THE FIX TAKEN: no polling of any kind is needed to detect a freshly
-- applied or cleared block. `IsK9FeatureBlocked`'s own backing state
-- (client/featureblocks.lua's ClientFeatureBlocks) changes from exactly
-- ONE place -- that file's 'qbx_k9unit:client:featureBlocksSync' handler
-- -- which already fires a LOCAL, synchronous, same-tick
-- 'qbx_k9unit:client:featureBlocksApplied' re-broadcast every single time
-- it runs (that file's own header: "Fired unconditionally on every
-- sync"). client/radial.lua already reacts to this exact event for the
-- identical reason (see that file's own "SECOND call site" comment) --
-- this is that same, already-established mechanism, not a new one
-- invented for this file. Listening for it here means: (1) the
-- suppression thread below is only ever CREATED at the moment it is first
-- genuinely needed -- global flag off at load, or a block newly arriving
-- -- so the idle steady-state cost for the population this widening is
-- for (blocked == false, which is everyone today) is EXACTLY ZERO threads,
-- not a cheap poll, not even a Wait(15000) -- genuinely nothing; and (2) a
-- freshly-applied block takes effect the SAME GAME TICK the sync arrives,
-- not up to one polling interval later -- strictly faster than the
-- proposal this replaces, at a strictly lower idle cost, not a tradeoff
-- between the two.
--
-- WHAT STILL NEEDS A POLL, AND WHY THAT ONE IS FINE: once suppression is
-- genuinely active (this player is either globally suppressed or live-
-- blocked right now), DisableControlAction's own contract still requires
-- re-asserting it EVERY FRAME (Wait(0)) for as long as that's true -- no
-- event exists for "a native control input was just pressed" that this
-- resource could subscribe to instead, and this is exactly the same
-- unavoidable per-frame cost the pre-existing global-off case already
-- paid, not a new one. Within that same active loop, detecting the ped's
-- MODEL changing back and forth (a K9 body swapping to/from human) also
-- has no event to hook in this codebase, so it stays a Wait(1000) poll --
-- identical to, and no more expensive than, this thread's own pre-existing
-- global-off idle behavior, now also covering the "blocked but temporarily
-- not K9-modeled" case the exact same way.
--
-- RELEASE, NEVER GATED ON THE BLOCK CHECK ITSELF (this task's own hard
-- rule): the while-loop's own condition below is what ends the loop, and
-- it is re-read fresh on every single iteration -- at most one frame away
-- while actively suppressing, at most 1000ms away while temporarily
-- off-model -- covering the block clearing, the K9 model being lost, and
-- (since Config.Features.AgilityBasicJump does not change at runtime) the
-- feature-flag case is moot once loaded. Death needs no separate release
-- path either: a dead ped's model doesn't change, so the SAME
-- IsEntityModelK9(PlayerPedId()) branch below already governs it exactly
-- as it does any other moment, and GTA's own death/ragdoll state already
-- restricts input on its own regardless of this thread. DisableControlAction
-- itself needs no explicit "undo" the way SetPedMoveRateOverride/
-- SetFollowPedCamViewMode elsewhere in this file do (see this file's own
-- onResourceStop handlers for those) -- it only ever affects the ONE frame
-- it's called on, so the instant this loop stops calling it, for ANY
-- reason including this resource being stopped (FiveM guarantees a
-- stopped resource's own threads stop running), native jump/crouch is
-- available again on the very next frame with zero extra code. This is
-- also why this feature gets no dedicated onResourceStop handler of its
-- own, unlike the camera/leash/move-rate state above: there is no sticky
-- native state here left to reverse.
-- ======================================================================
local INPUT_JUMP = 22
local INPUT_DUCK = 36

-- True once client/featureblocks.lua has told this client this feature is
-- blocked for it right now -- mirrored into this plain local so the
-- suppression loop below never has to call IsK9FeatureBlocked() itself
-- just to decide whether to KEEP running (only the featureBlocksApplied
-- handler further below ever calls it, to decide whether to START).
-- `type(IsK9FeatureBlocked) == 'function'` guarded at that one call site,
-- per this resource's soft-dependency convention (client/featureblocks.lua's
-- own header) -- if that file is never loaded, this simply never becomes
-- true, the correct fail-open direction (unblockable, exactly as this
-- feature already behaved before this pass).
local agilityJumpBlocked = false

--- Either independent reason -- the static config flag, or the live
--- per-person block -- currently requires jump/crouch to be suppressed.
--- Re-read fresh every time (never cached beyond `agilityJumpBlocked`
--- itself, which the event handler below keeps current), including as the
--- suppression loop's own while-condition, so it is also this thread's own
--- release check.
local function ShouldSuppressAgilityJump()
    return (not Config.Features.AgilityBasicJump) or agilityJumpBlocked
end

-- Guards against ever starting a second copy of the loop below (e.g. two
-- featureBlocksApplied syncs arriving close together while the first
-- thread hasn't looped around yet).
local agilityJumpSuppressionThreadRunning = false

--- Starts the suppression loop if (and only if) it isn't already running
--- AND it's actually needed right now. Safe to call unconditionally from
--- both the file-load-time check below and the featureBlocksApplied
--- handler -- a no-op in every case that doesn't need it.
local function EnsureAgilityJumpSuppressionThread()
    if agilityJumpSuppressionThreadRunning then return end
    if not ShouldSuppressAgilityJump() then return end

    agilityJumpSuppressionThreadRunning = true
    CreateThread(function()
        while ShouldSuppressAgilityJump() do
            -- OWNER'S DECISION, 2026-08-25: MODEL, not role. A player holding
            -- the K9 role on a HUMAN body keeps jump and crouch.
            -- This suppression exists because a quadruped has no jump or
            -- crouch animation -- it is a consequence of the body, not of the
            -- job. Applying it to a human-shaped role-holder would be a rule
            -- copied past its own reason, taking away movement they never had
            -- cause to lose. So this stays IsEntityModelK9(PlayerPedId())
            -- deliberately, and must NOT be "corrected" to IsOwnModelK9()
            -- (which now answers role-OR-model) by a future any-ped sweep --
            -- true regardless of WHICH of the two reasons above is why this
            -- loop is running right now.
            if IsEntityModelK9(PlayerPedId()) then
                DisableControlAction(0, INPUT_JUMP, true)
                DisableControlAction(0, INPUT_DUCK, true)
                Wait(0) -- must disable every frame while active, per DisableControlAction's own contract
            else
                Wait(1000) -- cheap idle poll while not currently a K9-modeled ped
            end
        end
        -- Loop condition went false (block cleared, or -- moot at runtime,
        -- since this Config value doesn't change post-load -- the global
        -- flag). Nothing left to release (see this block's own header
        -- comment on why DisableControlAction needs no explicit undo); just
        -- let a future EnsureAgilityJumpSuppressionThread() call start a
        -- fresh thread if this feature is ever blocked again.
        agilityJumpSuppressionThreadRunning = false
    end)
end

-- Mirrors the ORIGINAL, pre-this-pass behavior exactly for the
-- global-flag-off case: start suppressing immediately at load, unconditionally.
EnsureAgilityJumpSuppressionThread()

-- Wakes the suppression thread the INSTANT a fresh per-person block
-- arrives -- see this section's own header comment for why this, not a
-- poll, is what keeps this feature correct without an unconditional
-- always-on thread. Local-only (same client, same resource -- never a
-- network event of its own), so no source-origin guard is needed here:
-- client/featureblocks.lua's own RegisterNetEvent handler for the REAL
-- network event ('qbx_k9unit:client:featureBlocksSync') already owns that
-- check before ever re-triggering this one. Mirrors client/radial.lua's
-- own identical "SECOND call site" listener.
AddEventHandler('qbx_k9unit:client:featureBlocksApplied', function()
    agilityJumpBlocked = type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('AgilityBasicJump') == true
    if agilityJumpBlocked then
        EnsureAgilityJumpSuppressionThread()
    end
    -- No corresponding "stop" call needed on the false branch: if the loop
    -- is currently running, its own while-condition (ShouldSuppressAgilityJump())
    -- already re-reads `agilityJumpBlocked` fresh on its very next
    -- iteration and exits on its own; if it isn't running, there's nothing
    -- to stop.
end)

-- ======================================================================
-- DOOR INTERACTION — Phase 2, SCRATCH-TO-ALERT + NUDGE-OPEN
-- (Config.Features.DoorInteraction). See this file's header DOOR
-- INTERACTION block for the full event contract and source-document list.
-- Scratch-to-alert is built directly against server/main.lua's
-- ALREADY-SHIPPED 'qbx_k9unit:server:relayDoorScratch' handler (search that
-- file for "relayDoorScratch" for the exact, currently-live contract this
-- code targets) rather than re-deriving the server side from the design
-- notes alone — the design notes and the shipped handler agree, but the
-- handler is the actual source of truth.
--
-- NUDGE-OPEN — DESIGN PATH TAKEN (read this before touching NudgeDoor()):
--
-- The hard, non-negotiable constraint (DEVELOPER_REFERENCE.md §11.5/§11.6,
-- DEVELOPER_REFERENCE.md#door-interaction §0.5/§4,
-- DEVELOPER_REFERENCE.md#door-interaction Finding 3): nudge-open
-- must NEVER consult GTA's native door-lock/CDoor system
-- (DoorSystemGetDoorState / IsDoorClosed / GetStateOfClosestDoorOfType /
-- etc.) as a safety check. An unregistered door — the common case, since
-- most real FiveM door-lock resources (ox_doorlock-style, custom MLOs)
-- manage their own lock flag entirely outside GTA's CDoor system — reads as
-- "nothing to say" to every one of those natives, which risks being
-- misread as "unlocked." Treating "not registered" as license to nudge
-- would make this a concrete lockpick-equivalent bypass, not a theoretical
-- one (native_natives.md §0.5 spells out exactly this failure mode). This
-- file does not call ANY door-system native anywhere, for any purpose —
-- not even the read-only ones — full stop.
--
-- Given that constraint, the only structurally safe design is purely
-- cosmetic: something that can NEVER open a door a lock resource considers
-- closed, because it never touches door state (position, heading, freeze
-- flag, CDoor registration, anything) at all. This mirrors
-- client/vehicle.lua's documented "no real capability granted" exception
-- (vehicle entry/exit grants nothing a modified client couldn't already do
-- to itself) — same reasoning, applied to a door instead of a vehicle seat.
--
-- WHICH FALLBACK WAS ACTUALLY TAKEN — flagged explicitly per this task's
-- own instruction, for exploit-tester to verify against: nothing in
-- DEVELOPER_REFERENCE.md#door-interaction ever settled on a
-- confirmed "is this door already passable" detection method beyond
-- distance.
--   - The design note (§7/§8 in its original form) explicitly leaves "the exact model-hash
--     list (or alternative detection method)" as "a real implementation
--     task, not a design-note-level decision" — i.e. still open, not
--     resolved.
--   - DEVELOPER_REFERENCE.md#door-interaction (§7 in its original form) explicitly flags "whether there's any
--     lighter-weight way to detect 'this CObject is currently a
--     swinging/hinged door' (vs. a static prop)... Not verified."
--   - DEVELOPER_REFERENCE.md#door-interaction (§4 in its original form)'s own "Practical recommendation" (the
--     most concrete guidance that exists) describes the walk-through-able
--     framing at a CONCEPTUAL level only ("play the K9's push animation as
--     it passes through a door the player can already physically walk
--     through") — it does not supply a concrete native/algorithm for
--     confirming that a specific, arbitrary door object is in that state
--     ahead of time, only for the (separately unavailable, CDoor-only)
--     registered-door subset this design deliberately avoids relying on.
-- Since no confirmed "already passable" detection method exists to gate
-- on, this implements the SIMPLEST SAFE VERSION explicitly named as the
-- fallback: NudgeDoor() plays a push impulse/animation ONLY, gated by
-- nothing beyond distance (Config.DoorInteraction.interactDistance, via
-- ox_target's own `distance` option) and CanShowK9UI() — see NudgeDoor()'s
-- own header comment below for exactly why zero additional gating is safe
-- here regardless of the target door's real state.
--
-- Config.DoorInteraction.nudgeRequiresUnlocked (Finding 3): this field's own
-- inline comment says "hard requirement, not a toggle" — but per the hard
-- constraint above, there is no real lock-state read anywhere in this file
-- for that flag to gate. Building a branch off it that behaves differently
-- based on its value would require somehow determining real lock state,
-- which is exactly the thing this design must never do. Rather than leave
-- it as a silent, unenforced no-op that could look load-bearing to a server
-- owner (the exact risk Finding 3 raises) or invent a fake lock check just
-- to give it something to gate, this ships the review's recommended
-- Option A: a resource-start assertion (see below, immediately before the
-- ox_target registration) that fails loudly if the field is ever set to
-- anything other than `true`. That is the full extent to which this flag is
-- "applied as a config gate" — it gates whether this ENTIRE RESOURCE starts
-- at all, not a runtime branch inside NudgeDoor() — which is the only way to
-- honor both "this field must do something real" and "nudge-open must never
-- branch on believed lock state."
-- ======================================================================

--- Best-effort "is this object entity plausibly a door" heuristic, used
--- ONLY to decide whether to offer the "Scratch to Alert" ox_target option
--- on a given nearby object — NOT a security check of any kind. The server
--- (server/main.lua's relayDoorScratch handler) independently resolves,
--- existence-checks, and proximity-checks whatever netId this file ends up
--- sending regardless of what this predicate decided, so a wrong answer
--- here is a UX miss (option doesn't appear on a real door, or appears on
--- something that isn't one), never a security gap — this is the same
--- "display-only plausibility gate" framing this file's header already
--- applies to IsEntityModelK9() for the leash/certify options above.
---
--- No generic "is this entity a door" native/predicate exists (confirmed by
--- DEVELOPER_REFERENCE.md#door-interaction — GTA's native door SYSTEM only
--- covers doors explicitly registered via AddDoorToSystem/IPL data, a small
--- fraction of visible door props on a typical interior-heavy server, and
--- is unsuitable here anyway since Scratch-to-alert must work "on any door
--- ... regardless of lock state" per DEVELOPER_REFERENCE.md §11.5, i.e. registered or not).
--- Rather than hand-maintain a model-hash allow-list of specific door prop
--- names (DEVELOPER_REFERENCE.md#door-interaction §3.1's "Option 1" — flagged
--- there as LOW-MEDIUM confidence and something that would need updating
--- for every interior/MLO a server adds), this checks the entity's own
--- model name STRING for the substring "door", via GetEntityArchetypeName —
--- the same naming-pattern observation that design note makes
--- ("v_ilev_*door*, prop_*_door_*, plyr_dlc_gengarage_door" all contain the
--- literal word "door") applied generically instead of enumerated exactly.
--- CONFIDENCE: MEDIUM that GetEntityArchetypeName behaves as documented
--- (a FiveM-added native returning the entity's model/archetype name as a
--- string) — not independently re-confirmed against a live client this
--- session; LOW-MEDIUM that the substring check covers "most doors a player
--- would expect this to work on" for the same reason
--- DEVELOPER_REFERENCE.md#door-interaction §3.1 grades its own model-list approach
--- LOW-MEDIUM (door prop naming isn't fully standardized across the base
--- map). If this predicate turns out to under/over-match badly in
--- real-world testing, that's the first place to revisit — ideally with
--- native-api-assistant confirming GetEntityArchetypeName's exact behavior,
--- same verification standard this file's own K9Sit() scenario-name comment
--- already applies to itself.
--- @param entity number
--- @return boolean
local function IsLikelyDoorEntity(entity)
    local archetypeName = GetEntityArchetypeName(entity)
    return type(archetypeName) == 'string' and archetypeName:lower():find('door', 1, true) ~= nil
end

--- Precomputed model-hash -> scenario lookup for the scratch-to-alert
--- action's local visual cue on the K9 itself, built the exact same way
--- K9_SIT_SCENARIO_BY_MODEL_HASH is above. No "dog scratches at a door"
--- scenario has been confirmed to exist anywhere this session —
--- DEVELOPER_REFERENCE.md#door-interaction §4.2/§7 flags this explicitly ("no ...
--- scenario/clipset name ... has been confirmed to exist at all this
--- session — treat as unconfirmed, not assumed absent, same caveat
--- movement.lua's Sit-action header already applies to its own scenario
--- names"). Rather than fabricate an unverified "scratch" scenario name,
--- this reuses the SAME confirmed-real WORLD_DOG_BARKING_* scenarios
--- K9_SIT_SCENARIO_BY_MODEL_HASH's own comment above already names as
--- existing siblings of the sitting scenarios ("plus WORLD_DOG_BARKING_*
--- siblings, not used here" — now used here instead of an unverified
--- scratch anim). Thematically apt for an "alert" action (drawing
--- attention, per the feature's own name), and inherits that comment's
--- exact confidence grading: HIGH the scenario strings themselves exist
--- (two independently-maintained community scenario dumps agree), MEDIUM on
--- the breed-to-scenario mapping for a_c_chop/a_c_husky specifically
--- (shared substitutions, same reasoning as K9_SIT_SCENARIO_BY_MODEL_HASH).
local K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_BARKING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_BARKING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_BARKING_ROTTWEILER', -- Chop is Rottweiler-framed, same substitution as K9_SIT_SCENARIO_BY_MODEL_HASH
    a_c_husky = 'WORLD_DOG_BARKING_RETRIEVER', -- no husky-specific scenario, same substitution as K9_SIT_SCENARIO_BY_MODEL_HASH
}) do
    K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_DOOR_SCRATCH_DEFAULT_SCENARIO = 'WORLD_DOG_BARKING_SHEPHERD' -- fallback for an unmapped/future Config.Peds model, mirrors K9_SIT_DEFAULT_SCENARIO

-- Sound reference for the ACTING player's own local cue, played immediately
-- on the K9 itself (distinct from the shared/broadcast alert cue played on
-- the DOOR via the playDoorScratch receiver further below).
--
-- CORRECTED THIS PASS: earlier revisions of this comment (and the sibling
-- DOOR_NUDGE_SOUND_NAME/playDoorScratch call sites below) called
-- 'qbx_k9unit_sounds' a "harmless no-op until a real asset exists" the same
-- way client/main.lua's BARK_SOUND_NAME/K9_SOUND_SET header does — true of
-- the RAGE-audio soundset name itself (no `.awc`/`.dat54` bank named
-- 'qbx_k9unit_sounds' ships with this resource, or ever has), but that
-- comment stopped being the whole story once client/audio.lua's real NUI
-- audio bridge (PlayK9Sound) shipped: client/main.lua's playBark handler,
-- client/search.lua's contraband-alert receiver and client/findalert.lua
-- ALL dual-path every one of
-- their sound cues through PlaySoundOnNetworkEntity, which tries the dead
-- native call AND client/audio.lua's PlayK9Sound (the one path that can
-- actually produce sound today, once an operator drops a matching .ogg into
-- html/sounds/). This file's three door-audio call sites (this one,
-- DOOR_NUDGE_SOUND_NAME's NudgeDoor, and the playDoorScratch receiver
-- further below) used to be the ONLY sound cues left in this resource that
-- called the native PlaySoundFromEntity directly and skipped that bridge
-- entirely — silent forever, with no path to ever change that short of
-- editing this file again. Fixed this pass: all three now go through
-- PlaySoundOnNetworkEntity too, for the same "silent until an operator
-- supplies a real file, never silent-forever-by-construction" property
-- every other cue in this resource already has. See ToAudioFileKey() in
-- client/audio.lua for why no matching .ogg shipping yet is fine — it
-- degrades to the same silent no-op the native call already was.
local DOOR_SCRATCH_SOUND_NAME = 'DoorScratch'

--- Shared implementation behind the "Scratch to Alert" ox_target option's
--- onSelect below.
--- @param entity number  -- resolved live entity handle from the ox_target callback's own `data.entity`
local function ScratchAtDoor(entity)
    -- Defensive re-check, same posture as every other gated action in this
    -- file (RequestLeashAttach, K9Sit, etc.) — canInteract below is a
    -- DISPLAY optimization only; server/main.lua's relayDoorScratch handler
    -- independently re-verifies Config.Features.DoorInteraction AND
    -- HasK9Access(source) regardless of what this client claims.
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- ISSUE-CLOSER FIX: canInteract below already excludes a K9 "tucked"
    -- into a vehicle (client/vehicle.lua's IsInK9Vehicle, via
    -- AttachEntityToEntity) from ever seeing this option — but per this
    -- file's own established rule that canInteract is a DISPLAY optimization
    -- only, the function itself must re-check too (exactly the posture the
    -- comment above already claims for CanShowK9UI). CanShowK9UI() alone
    -- does not catch this case: IsOwnModelK9() stays true and HasK9Access()
    -- is unaffected while tucked into a vehicle, so without this re-check a
    -- stale ox_target entry or a direct call could still play the scratch
    -- scenario/sound on a ped that is currently attached inside a vehicle.
    -- Existence-guarded exactly like the leash pull-back thread's own
    -- identical exclusion elsewhere in this file — client/vehicle.lua loads
    -- after this file, so IsInK9Vehicle may not exist yet at file-load time.
    if IsInK9Vehicle and IsInK9Vehicle() then return end

    if not DoesEntityExist(entity) then
        lib.notify({ title = locale('common.notify_title'), description = locale('movement.nothing_to_scratch'), type = 'error' })
        return
    end

    -- Resolve the netId NOW, before doing anything else — same
    -- handle-can-go-stale reasoning client/search.lua's PerformSearch()
    -- documents for its own identical capture-up-front pattern (entity
    -- handles get recycled once an entity is deleted/streamed out).
    local doorNetId = NetworkGetNetworkIdFromEntity(entity)

    -- Local visual/audio feedback cue on the ACTING player's own K9,
    -- per DEVELOPER_REFERENCE.md#door-interaction §4.2 ("Play a scratch/paw
    -- animation + sound cue locally on the K9 ... TriggerServerEvent(...)").
    -- This plays immediately and unconditionally (unlike client/radial.lua's
    -- Bark item, which plays no local cue at all and relies entirely on the
    -- eventual broadcast) — deliberately different from Bark's shape here,
    -- per this feature's own design note, not an inconsistency to "fix"
    -- later. The shared/broadcast alert cue (anchored to the DOOR, for
    -- every client that has it streamed in, including this one) is a
    -- SEPARATE sound played by the playDoorScratch receiver below once the
    -- server round-trips it back — this call does not substitute for that.
    local ped = PlayerPedId()
    local scenarioName = K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_DOOR_SCRATCH_DEFAULT_SCENARIO
    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
    -- Routed through the shared PlaySoundOnNetworkEntity (client/main.lua)
    -- rather than a direct PlaySoundFromEntity call — see
    -- DOOR_SCRATCH_SOUND_NAME's own comment above for why. Own netId, same
    -- pattern as every other own-ped sound helper's
    -- PlayPulse (both play a one-shot cue on THIS client's own ped).
    PlaySoundOnNetworkEntity(NetworkGetNetworkIdFromEntity(ped), DOOR_SCRATCH_SOUND_NAME)

    TriggerServerEvent('qbx_k9unit:server:relayDoorScratch', doorNetId)
end

-- Sound reference for the nudge-open cosmetic cue, played locally on the
-- ACTING player's own K9 ONLY — there is no broadcast/relay of any kind for
-- nudge (unlike DOOR_SCRATCH_SOUND_NAME above, which is also played on the
-- door itself for every OTHER client once the server round-trips it back).
-- Same "routes through PlaySoundOnNetworkEntity, same as everything else in
-- this resource" fix as DOOR_SCRATCH_SOUND_NAME above — see that constant's
-- own comment for the full "CORRECTED THIS PASS" writeup.
local DOOR_NUDGE_SOUND_NAME = 'DoorNudge'

-- Feel/tuning knob for the cosmetic push impulse below — NOT a structural
-- decision (DEVELOPER_REFERENCE.md#door-interaction §8 explicitly lists "the exact
-- push-force magnitude/direction tuning for a convincing nudge animation"
-- as a tuning knob, not a design-level choice) and has zero bearing on this
-- function's safety properties either way, since it only ever scales a
-- force applied to the K9's OWN ped (see NudgeDoor()'s header comment).
local NUDGE_IMPULSE_FORCE = 2.0

--- Shared implementation behind the "Nudge Door" ox_target option's
--- onSelect below.
---
--- SAFETY DESIGN — read this file's "NUDGE-OPEN — DESIGN PATH TAKEN" header
--- comment above the door-interaction registration block further down for
--- the full writeup; summarized here at the actual point of implementation:
--- - This function NEVER calls any door-lock/CDoor native
---   (DoorSystemGetDoorState, IsDoorClosed, GetStateOfClosestDoorOfType, or
---   any sibling) and NEVER reads/writes/freezes/moves/rotates the door
---   `entity` argument in any way. The ONLY thing this function does with
---   `entity` at all is read its CURRENT POSITION (GetEntityCoords), purely
---   to compute which direction the K9's own cosmetic push impulse should
---   face — reading a position is not a lock-state check and cannot itself
---   reveal or change lock state.
--- - The impulse below is applied to the K9's OWN PED, never to `entity` —
---   deliberately more conservative than "push the door and trust a
---   door-lock resource's freeze flag to make that push a no-op when
---   locked," since that would still depend on an assumption about how some
---   unknown, unintegrated door-lock resource happens to implement its lock
---   (freezing the object is common but not guaranteed for every such
---   resource). Never touching the door object at all removes that
---   assumption entirely — there is structurally nothing for a locked door
---   to "defend against" here, regardless of how any given server's
---   door-lock resource works internally.
--- - Gating is ONLY distance (via the ox_target option's own `distance`
---   field below, Config.DoorInteraction.interactDistance) and
---   CanShowK9UI() — no reachability/"already passable" check of any kind.
---   This is the explicit fallback this file's header comment names: none
---   of what used to be three separate phase2_notes documents (now merged
---   into DEVELOPER_REFERENCE.md#door-interaction) ever settled on
---   a confirmed method for
---   detecting "is this specific door object already passable" beyond the
---   conceptual framing itself, so there is nothing concrete to gate on
---   instead — and a self-only cosmetic impulse cannot grant any capability
---   regardless of the target door's real state, so skipping that gate adds
---   no risk.
--- - ZERO server involvement: no TriggerServerEvent, no callback, nothing
---   server-authoritative touched anywhere in this function — confirmed by
---   inspection (there is no TriggerServerEvent call below at all, unlike
---   ScratchAtDoor above it).
---
--- CONFIDENCE NOTE on ApplyForceToEntity's exact parameter semantics: MEDIUM
--- (a very commonly used FiveM native with a well-established call shape in
--- community scripts, but not independently re-verified against
--- raw.githubusercontent.com/citizenfx/natives this session the way
--- DEVELOPER_REFERENCE.md#door-interaction verified the door-system
--- natives) — worth a native-api-assistant pass before shipping if the feel
--- is off in testing, same standard this file's own K9Sit()/ScratchAtDoor()
--- scenario-name comments already apply to themselves. This has NO bearing
--- on the safety properties above either way, since the target of the force
--- is always the K9's own ped, never the door.
--- @param entity number -- resolved live entity handle from the ox_target callback's own `data.entity`
local function NudgeDoor(entity)
    -- Defensive re-check, same posture as ScratchAtDoor/every other gated
    -- action in this file — canInteract below is a DISPLAY optimization
    -- only. Unlike ScratchAtDoor there is no server round-trip afterward to
    -- ALSO independently re-validate anything (nudge is fully client-local
    -- by design, see this file's header comment) — so this local check is
    -- the only gate that will ever run for this action, which is fine
    -- precisely because nothing below grants any real capability regardless
    -- (see the SAFETY DESIGN notes above).
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- ISSUE-CLOSER FIX: same re-check as ScratchAtDoor's own identical fix
    -- immediately above in this file — see that function's own comment for
    -- the full reasoning. Doubly important here since nudge is fully
    -- client-local (no server round trip to fall back on at all): without
    -- this, a K9 currently attached inside a vehicle could still have a
    -- forward impulse applied to its own ped.
    if IsInK9Vehicle and IsInK9Vehicle() then return end

    if not DoesEntityExist(entity) then
        lib.notify({ title = locale('common.notify_title'), description = locale('movement.nothing_to_nudge'), type = 'error' })
        return
    end

    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    local doorCoords = GetEntityCoords(entity) -- POSITION ONLY -- never lock/open state, see header comment above
    local toDoor = doorCoords - pedCoords
    local dist = #toDoor

    -- Degenerate-distance guard (ped and door coordinates coincide almost
    -- exactly — a bugged/zero-size prop, or the door entity resolving to
    -- the same spot as the ped) -- fall back to the ped's own current
    -- facing direction rather than dividing by ~0.
    local dir
    if dist > 0.05 then
        dir = toDoor / dist
    else
        dir = GetEntityForwardVector(ped)
    end

    -- Cosmetic forward impulse on the K9's OWN body only (never on
    -- `entity`, per the SAFETY DESIGN notes above). forceType 3 =
    -- APPLY_TYPE_IMPULSE (a single instantaneous push, not a continuous
    -- force); offset (0,0,0)/component 0 = applied at the ped's own center
    -- of mass, not an off-center torque.
    ApplyForceToEntity(ped, 3, dir.x * NUDGE_IMPULSE_FORCE, dir.y * NUDGE_IMPULSE_FORCE, 0.0, 0.0, 0.0, 0.0, 0, false, true, true, false, true)
    -- Routed through PlaySoundOnNetworkEntity — see DOOR_SCRATCH_SOUND_NAME's
    -- comment above (ScratchAtDoor's identical fix, same reasoning).
    PlaySoundOnNetworkEntity(NetworkGetNetworkIdFromEntity(ped), DOOR_NUDGE_SOUND_NAME)
end

-- Register the "Scratch to Alert" ox_target option on nearby door-like
-- objects (DEVELOPER_REFERENCE.md §11.5: "available on any door within
-- Config.DoorInteraction.interactDistance regardless of lock state").
-- Config-gated AT REGISTRATION (the whole K9Compat.Get('target').AddGlobalObject
-- call below is wrapped in `if Config.Features.DoorInteraction`), not just
-- inside canInteract/onSelect — mirrors client/vision.lua's "config-gated
-- registration, not just config-gated behavior" precedent
-- (Config.Features.ThermalVision/NightVision gating RegisterCommand/
-- RegisterKeyMapping directly), a stricter pattern than this file's OWN
-- earlier convention of registering unconditionally and checking the flag
-- only inside canInteract (see the "Attach Leash" option above, gated by
-- Config.Features.LeashMechanics only inside canInteract). Both patterns
-- already coexist in this codebase; this option follows the stricter one on
-- purpose, per this task's explicit direction for this specific feature.
--
-- LIFECYCLE FIX (this pass): extracted into a named function — see this
-- file's "Attach Leash" option above for the full ox_target-lifecycle
-- writeup this shares (same bug, same fix shape, same combined
-- `AddEventHandler` immediately below). The Config.Features.DoorInteraction
-- gate stays AT REGISTRATION (inside this function, wrapping both the
-- assert and the addGlobalObject call), exactly as before, so a
-- re-registration on ox_target's restart never adds these options when the
-- original load-time code would have skipped them entirely.
local function RegisterDoorInteractionOxTargetOptions()
    if Config.Features.DoorInteraction then
        -- Config.DoorInteraction.nudgeRequiresUnlocked "applied as a config
        -- gate" (Finding 3, DEVELOPER_REFERENCE.md#door-interaction):
        -- per this file's "NUDGE-OPEN — DESIGN PATH TAKEN" header comment
        -- above, NudgeDoor() has no real lock-state read anywhere to build a
        -- runtime branch off this flag with — doing so would require exactly
        -- the kind of believed-lock-state check this design must never perform.
        -- Instead of leaving the flag as a silent, unenforced no-op (Finding
        -- 3's core complaint — a field whose own comment claims "hard
        -- requirement, not a toggle" but that no code anywhere reads), this
        -- ships the review's recommended Option A: fail resource start LOUDLY
        -- if it's ever set to anything other than `true`, converting it from
        -- "looks load-bearing but isn't" into an active guardrail against a
        -- FUTURE implementer wiring a real (dangerous) lock-state branch off it
        -- without deliberately, reviewedly removing this assertion first.
        assert(Config.DoorInteraction.nudgeRequiresUnlocked == true,
            'Config.DoorInteraction.nudgeRequiresUnlocked must remain true -- ' ..
            'nudge-open (client/movement.lua NudgeDoor) has no lock-state check ' ..
            'of any kind, by design (it never consults GTA\'s door-lock/CDoor ' ..
            'system, see this file\'s "NUDGE-OPEN" header comment) -- this ' ..
            'assertion exists solely to fail loudly if this field is ever ' ..
            'repurposed as a real gate without a reviewed code change. See ' ..
            'DEVELOPER_REFERENCE.md#door-interaction Finding 3.')

        -- THIRD-EYE CLARITY PASS (this pass, owner-directed): both icons
        -- below now use fas fa-dog, the resource-wide K9-role icon (same
        -- convention as this file's "Attach Leash" K9-direction option and
        -- client/vehicle.lua/client/kennel.lua/client/search.lua/
        -- client/fetch.lua's own K9-role options, confirmed with the
        -- sibling agent covering that half of this pass) -- NOT fas fa-paw
        -- (scratchDoor's previous icon) or fas fa-hand-paper (nudgeDoor's
        -- previous icon): both of these options are only ever shown while
        -- the local player's own body IS the K9 (CanShowK9UI() below), so
        -- they belong in the same icon bucket as every other K9-role
        -- option in this resource, not a bespoke per-action icon. Labels
        -- reworded to plain English; canInteract/onSelect are UNCHANGED.
        K9Compat.Get('target').AddGlobalObject({
            {
                name = 'qbx_k9unit:scratchDoor',
                icon = 'fas fa-dog',
                label = locale('movement.scratch_door_target_label'),
                distance = Config.DoorInteraction.interactDistance,
                canInteract = function(entity, distance, coords, name)
                    if not CanShowK9UI() then return false end
                    -- qa-tester finding: a K9 seated inside a vehicle
                    -- (client/vehicle.lua's EnterNearestK9Vehicle, a real
                    -- vehicle seat via SET_PED_INTO_VEHICLE) is nowhere near
                    -- this door in any way that should let it play
                    -- a scratch scenario and broadcast an alert — mirrors the
                    -- leash pull-back thread's own `IsInK9Vehicle and
                    -- IsInK9Vehicle()` exclusion for the identical state
                    -- (client/vehicle.lua loads after this file, hence the
                    -- existence guard, same reason that thread uses it).
                    if IsInK9Vehicle and IsInK9Vehicle() then return false end
                    return IsLikelyDoorEntity(entity)
                end,
                onSelect = function(data)
                    ScratchAtDoor(data.entity)
                end,
            },
            {
                -- SEPARATE ox_target option from "Scratch to Alert" above (per
                -- this task's explicit direction), registered on the SAME
                -- door-like objects, gated behind the same
                -- Config.Features.DoorInteraction check at registration (this
                -- whole block). See NudgeDoor()'s own header comment for the
                -- full safety design this option's canInteract/onSelect below
                -- are deliberately minimal because of.
                name = 'qbx_k9unit:nudgeDoor',
                icon = 'fas fa-dog',
                label = locale('movement.nudge_door_target_label'),
                distance = Config.DoorInteraction.interactDistance,
                canInteract = function(entity, distance, coords, name)
                    if not CanShowK9UI() then return false end
                    -- Same vehicle-tucked-K9 exclusion as "Scratch to Alert"
                    -- above, same reasoning — a tucked K9 is nowhere near this
                    -- door in any way that should let it play a push impulse.
                    if IsInK9Vehicle and IsInK9Vehicle() then return false end
                    return IsLikelyDoorEntity(entity)
                end,
                onSelect = function(data)
                    NudgeDoor(data.entity)
                end,
            },
        })
    end
end

-- Sole call site for RegisterLeashOxTargetOption() /
-- RegisterDoorInteractionOxTargetOptions() above: this resource's own
-- start, or a restart of whatever resource actually backs the 'target'
-- system -- mirrors server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical class of gap against ox_inventory. Combined into one handler
-- (rather than one per function) since all three share the identical
-- two-branch condition and this file already defines all three by this
-- point. This file never names a third-party target resource directly (see
-- shared/compat/target.lua) -- K9Compat.Redetect() is forced before
-- checking K9Compat.Which('target') so this is correct regardless of
-- relative handler-registration order against shared/compat/core.lua's own
-- onResourceStart/onClientResourceStart redetect hook for this SAME event.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterLeashOxTargetOption()
        RegisterDoorInteractionOxTargetOptions()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterLeashOxTargetOption()
        RegisterDoorInteractionOxTargetOptions()
    end
end)

--- Broadcast receiver for the shared "door was scratched" alert cue —
--- mirrors client/main.lua's existing playBark handler EXACTLY per DEVELOPER_REFERENCE.md
--- §11.4 item 6 (resolve the network entity, no-op if not streamed in, play
--- a sound), including the same defensive "0 or nonexistent" guard
--- server/main.lua's own relayDoorScratch handler already applies to this
--- SAME netId server-side before ever broadcasting it — belt-and-suspenders
--- here, since a client should never assume a netId it receives over the
--- network still resolves to something real by the time this fires
--- (streamed out between broadcast and receipt is a normal, expected race,
--- not an error worth logging/notifying about).
---
--- CORRECTED THIS PASS: now calls client/main.lua's shared
--- PlaySoundOnNetworkEntity() directly instead of resolving the entity here
--- and calling the native PlaySoundFromEntity by hand — that function
--- already performs the exact same ResolveNetworkEntity()-guarded resolve
--- internally (DEVELOPER_REFERENCE.md near-term item 2), AND additionally
--- dual-paths the cue through client/audio.lua's PlayK9Sound NUI bridge,
--- same as client/main.lua's own playBark handler and every other sound cue
--- in this resource. See DOOR_SCRATCH_SOUND_NAME's own comment above for why
--- that bridge, not just the native call, matters here.
--- @param doorNetId number
RegisterNetEvent('qbx_k9unit:client:playDoorScratch', function(doorNetId)
    -- SOURCE-ORIGIN GUARD — see leashAttachRequest above / client/combat.lua's
    -- header for the full reasoning/confidence grading. Cosmetic-only
    -- payoff here (a forged call just plays a sound at an arbitrary
    -- resolvable netId), applied for the same resource-wide consistency as
    -- every other handler in this file, not because this one carries real
    -- exploit severity on its own.
    if source ~= 65535 then return end

    PlaySoundOnNetworkEntity(doorNetId, DOOR_SCRATCH_SOUND_NAME)
end)

-- The ADVANCED AGILITY block (Config.Features.AgilityAdvanced's fence/
-- window vault approximation) used to live here. EXTRACTED (this pass) to
-- its own file, client/agility.lua, since it shares no local state with
-- anything above and nothing else in this resource depends on its locals
-- (confirmed by grep before moving it) -- see this file's own header
-- "EXTRACTED" note and client/agility.lua's own header for the full
-- reasoning. No behavior change: same feature flag, same command/keybind
-- name, same natives, same constants.
