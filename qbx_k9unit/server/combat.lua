--[[
    qbx_k9unit/server/combat.lua

    Phase 3 implementation (coder-security), DEVELOPER_REFERENCE.md §12.5.1
    (Bite-and-Hold) and §12.5.2 (Non-lethal takedown), built under §12.0
    item 8's ("the client-relay/non-cooperating-target-client architecture
    problem") own resolution and its five binding guardrails — this file
    IS that resolution's implementation, not a separate design pass.

    PHASE 3 ADDITION (this pass, coder-architect): also owns
    `PropDragging` (DEVELOPER_REFERENCE.md §12.5.4, §12.0 item 6's downed-check
    contract, §12.0 item 8's "mixed Category A/B" split for this
    specific mechanic). The handler-down defense remained OUT OF SCOPE for this
    file — still blocked on `server/partnership.lua` (§12.0 item 7) not
    existing yet, see config.lua's own Config.Combat header comment.
    PropDragging reuses this file's existing `ActiveHolds`/`K9ActiveEffect`/
    `EndHold`/`FlagNonCompliance`/shared-maintenance-thread machinery
    (`effectType = 'drag'`, a third variant alongside `'bite'`/`'takedown'`)
    rather than standing up a parallel table — see PROP DRAGGING section
    near the bottom of this file for the full writeup, and EndHold's own
    now-three-way branch for the teardown/relay differences per effectType.

    ======================================================================
    HOW THIS FILE SATISFIES ITEM 8'S FIVE BINDING GUARDRAILS (read together
    with DEVELOPER_REFERENCE.md §12.0 item 8's own text, not a substitute for it):

    1. "The detection layer ... exists in real, tested code in
       server/combat.lua — not merely the config placeholder table." See
       NON-COMPLIANCE DETECTION below — a real, single, shared sampling
       thread, not a sketch.
    2. "PropDragging's AttachEntityToEntity call is re-asserted every
       tick..." — TRUE of THIS PASS's implementation: the re-assertion
       itself is entirely client-side (client/combat.lua's ActiveDragAsHolder
       maintenance loop, which is what actually calls AttachEntityToEntity
       every frame) — this file's own contribution to guardrail 2 is that
       requestDrag/EndHold never assume the attach "worked" for anything
       server-authoritative (see guardrail 3 below), and that the
       maxDragDistance safety valve (job (a) in NON-COMPLIANCE DETECTION
       below) and the drag-specific compliance gap check (job (b)) are both
       BLIND to whether the client-side re-assertion is actually happening —
       they only ever look at live GetEntityCoords positions, never at
       "is AttachEntityToEntity still being called," which is exactly the
       right posture per item 8's own "regardless of cause" framing for this
       specific check.
    3. "No server-authoritative consequence of any kind may ever be
       conditioned on a Category B effect having been applied successfully
       to a player target." Confirmed true of every code path below: the
       compliance sampling loop below NEVER calls EndHold early, never
       denies a cooldown refund, never blocks a future request, and never
       feeds back into HasK9Access/RequireWantedStatus/any grant — it only
       logs/notifies via Config.Combat.NonComplianceDetection.action. The
       ONLY things gating whether a hold/takedown is granted at all are
       things this server independently verifies BEFORE ever applying a
       Category B effect (feature flag, HasK9Access, live proximity,
       RequireWantedStatus, cooldowns) — see ValidateCombatRequest below.
    4. "Every player-facing string... is worded as best-effort." See
       COMBAT_REJECT_MESSAGES and every NotifyPlayer call below — none
       claim the target "cannot escape" or "is restrained."
    5. "Config.Combat.RequireWantedStatus stays true by default... and
       Config.Combat.NonComplianceDetection.action stays 'log'/
       'notify_staff' by default" — see config.lua; this file only ever
       reads those values, it never overrides them.
    ======================================================================

    ======================================================================
    EVENT/CALLBACK CONTRACT (client<->server, DEVELOPER_REFERENCE.md §12.5.1/
    §12.5.2/§12.0 item 8):

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:requestBiteHold' (targetNetId: number)
    - 'qbx_k9unit:server:releaseBiteHold' ()
    - 'qbx_k9unit:server:reportBiteHoldTargetDied' ()
      QA-fix completion (see this event's own handler doc comment for the
      full trust-boundary/verification writeup): sent by client/combat.lua's
      bite-hold TARGET death-detection thread, no arguments — `source` names
      the reporting (claimed-target) client. Re-verified against
      ActiveHolds/live server-side health (GetEntityHealth, see
      PED_DEAD_HEALTH_THRESHOLD below) before acting, never trusted alone.
    - 'qbx_k9unit:server:requestTakedown' (targetNetId: number)
    - 'qbx_k9unit:server:releaseTakedown' ()
      CANCEL-PATH FIX (this pass, coder-frontend — audit-flagged gap):
      NonLethalTakedown used to be the only one of the three combat
      mechanics with no way to end it early — bite-hold has releaseBiteHold,
      drag has releaseDrag, takedown had neither, so an auto-picked wrong
      target (FindNearestCombatTarget, client/combat.lua) stayed ragdolled/
      damage-immune for the full ragdollDurationMs with no way back. Mirrors
      releaseBiteHold's shape EXACTLY, including its authorization posture
      — see that handler's own doc comment (below) for why a release/cancel
      path must never re-check HasK9Access/Config.Features.NonLethalTakedown/
      any cooldown on the way out: this is a TERMINATION path, DEVELOPER_REFERENCE.md
      §12.0 item 4's "no unbounded trap" guarantee, restated for takedown
      specifically. Only verifies `source` is CURRENTLY the holder of an
      active 'takedown' via K9ActiveEffect[src] — the same O(1) lookup
      releaseBiteHold/releaseDrag already use — never a client-claimed
      targetNetId.
    - 'qbx_k9unit:server:reportHolderDied' ()
      LIFECYCLE QA FIX (this pass — see this event's own handler doc comment,
      near EndActiveEffectForHolder, for the full trust-boundary/
      verification writeup): mirrors reportBiteHoldTargetDied immediately
      above, for the HOLDING K9's own death instead of a target's. Sent by
      client/combat.lua's ActiveDragAsHolder/ActiveNpcEffects per-tick
      blocks, no arguments — `source` names the reporting (claimed-holder)
      client. Re-verified against K9ActiveEffect/live server-side health
      (GetEntityHealth, PED_DEAD_HEALTH_THRESHOLD below) before acting,
      never trusted alone — this is a FASTER-PATH optimization only; the
      shared maintenance thread's own HolderPedIsDead check (also this pass)
      is the always-on backstop that does not depend on this event ever
      arriving (a bite-hold/takedown on a PLAYER target has no client-side
      holder state to self-report from at all).

    Client events (server->client), registered by client/combat.lua:
    - 'qbx_k9unit:client:applyBiteHold' (holderNetId: number, expiresAt: number)
      Sent ONLY to the target's own client (never a broadcast) — the
      Category B relay itself. See client/combat.lua's own header for why
      this is registered UNCONDITIONALLY on every client, and why it is
      honestly best-effort against a hostile client (§12.0 item 8).
    - 'qbx_k9unit:client:endBiteHold' (reason: string)
      Sent ONLY to the target's own client — early release/timeout signal
      so DisableControlAction stops before its own local expiresAt.
    - 'qbx_k9unit:client:biteHoldStarted' (targetNetId: number, expiresAt: number)
      Sent ONLY to the HOLDING K9's own client — starts its own local
      cosmetic stance. This is a self-applied, Category-A-equivalent
      effect (the K9's own ped, driven by its own client — no relay
      problem), unrelated to item 8's Category B concern.
    - 'qbx_k9unit:client:biteHoldEnded' (targetNetId: number, reason: string)
      Sent ONLY to the holding K9's own client.
    - 'qbx_k9unit:client:takedownStarted' (targetNetId: number, expiresAt: number)
      CANCEL-PATH FIX (this pass) — Sent ONLY to the HOLDING K9's own
      client, unconditionally, mirroring biteHoldStarted immediately above
      exactly (same call shape, same "sent regardless of isPlayerTarget"
      posture). Before this pass, a takedown's holder received NO event of
      this kind at all — this is what lets client/combat.lua track "am I
      currently the holder of an active takedown" so IsTakedownEngaged()/
      ReleaseTakedown() have real state to work from, the same way
      MyEngagedTargetNetId/IsBiteHoldEngaged() already do for bite-hold.
    - 'qbx_k9unit:client:takedownEnded' (targetNetId: number, reason: string)
      CANCEL-PATH FIX (this pass) — Sent ONLY to the holding K9's own
      client, unconditionally (every EndHold reason, mirroring
      biteHoldEnded/dragEnded's own "always sent regardless of reason"
      posture) — this is what actually clears the holder's own
      client-side "engaged" state, for EVERY end reason (timeout,
      released_by_holder, target_died, holder_died, disconnect), not just
      a manual release.
    - 'qbx_k9unit:client:forceRagdoll' (expiresAt: number)
      Sent ONLY to the target's own client — Category B relay for
      NonLethalTakedown, same posture as applyBiteHold above.
    - 'qbx_k9unit:client:endForceRagdoll' (reason: string)
      Sent ONLY to the target's own client — restores
      SetEntityCanBeDamaged(true) on that client's own ped before/at
      expiresAt.
    - 'qbx_k9unit:client:applyNpcBiteHold' (npcNetId: number, expiresAt: number)
      Sent ONLY to the REQUESTING K9's own client — NEW, native-api-assistant
      verification pass (this session). See "NPC-TARGET NATIVE EXECUTION
      CONTEXT" below for why an NPC target's bite-suppression is relayed
      here rather than applied directly server-side as originally written.
    - 'qbx_k9unit:client:endNpcBiteHold' (npcNetId: number, reason: string)
      Sent ONLY to the requesting K9's own client — same relay, teardown
      side.
    - 'qbx_k9unit:client:applyNpcTakedown' (npcNetId: number, expiresAt: number)
      Sent ONLY to the requesting K9's own client — NEW, same session/reason
      as applyNpcBiteHold above, for NonLethalTakedown's NPC-target path.
    - 'qbx_k9unit:client:endNpcTakedown' (npcNetId: number, reason: string)
      Sent ONLY to the requesting K9's own client — same relay, teardown
      side.

    PROP DRAGGING (coder-architect, this pass, DEVELOPER_REFERENCE.md §12.5.4) —
    NEW server events (client->server), THIS FILE:
    - 'qbx_k9unit:server:requestDrag' (targetNetId: number)
    - 'qbx_k9unit:server:releaseDrag' () — either the HOLDING K9 or, when
      the target is a player, the TARGET can send this; server resolves
      which side `source` is and ends the drag either way. Zero consent
      needed from the other side either direction — mirrors leash's own
      "no consent needed to get free" rule, DEVELOPER_REFERENCE.md §12.0 item 4/
      §12.5.4, and is stronger than BiteAndHold/NonLethalTakedown's own
      target (who has NO self-release action at all — apprehension, not a
      cooperative mechanic).

    NEW client events (server->client), registered by client/combat.lua:
    - 'qbx_k9unit:client:dragStarted' (targetNetId: number, isPlayerTarget:
      boolean, expiresAt: number)
      Sent ONLY to the HOLDING K9's own client. Starts that client's own
      per-tick AttachEntityToEntity re-assertion loop (Category A, see this
      file's header "PROP DRAGGING — CATEGORY A/B SPLIT" section below) and,
      when `isPlayerTarget` is false, ALSO the direct
      SetPedMoveRateOverride(npcPed, ...) re-assertion on the NPC target
      every tick (no relay problem for an NPC — same posture as
      applyNpcBiteHold/applyNpcTakedown above, just for move-rate instead of
      flee-suppression/ragdoll).
    - 'qbx_k9unit:client:dragEnded' (targetNetId: number, reason: string)
      Sent ONLY to the holding K9's own client — stops the re-assertion
      loop, calls DetachEntity once, and (NPC target only) resets that
      NPC's move rate back to 1.0.
    - 'qbx_k9unit:client:applyDragSpeedLimit' (expiresAt: number)
      Sent ONLY to a PLAYER target's own client (never to an NPC — NPCs have
      no "own client," see dragStarted above) — the Category B half of
      dragging, DEVELOPER_REFERENCE.md §12.0 item 8. Re-asserted by that client
      every tick via SetPedMoveRateOverride, either directly or through
      client/movement.lua's shared move-rate composer depending on whether
      THAT client's own ped is currently a K9 model — see client/combat.lua's
      own header for why a blanket "always go through the composer" reading
      would silently no-op for the common (non-K9 target) case.
    - 'qbx_k9unit:client:endDragSpeedLimit' (reason: string)
      Sent ONLY to a player target's own client — restores move rate to 1.0
      and self-detaches as a defense-in-depth backstop (see client/combat.lua).

    ======================================================================
    NPC-TARGET NATIVE EXECUTION CONTEXT — RESTRUCTURED this session
    (native-api-assistant verification pass), superseding this file's own
    ORIGINAL "NPC target: this server already fully commands this entity,
    no relay problem" reasoning for BiteAndHold/NonLethalTakedown's
    NPC-target branches. That reasoning assumed
    SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes/SetEntityCanBeDamaged/
    SetPedToRagdollWithFall are all plainly callable server-side against a
    server-spawned NPC ped. Verified against the canonical
    citizenfx/fivem native declarations this session:
    - SetEntityCanBeDamaged (0x1760FFA8AB074D66, `ENTITY` namespace) is
      CONFIRMED CLIENT-ONLY. CORRECTION (later verification pass, folded in
      here rather than left in a separate note): this was originally
      justified as "no `apiset` entry in the primary source", but that test
      is invalid on its own — GetEntityCoords, definitely server-callable
      (this file calls it server-side directly), has byte-for-byte
      identical apiset-less frontmatter, so absence of the field doesn't
      distinguish the two. The client-only conclusion still holds, just on
      a different, valid basis: a docs.fivem.net search-index snippet
      quoting that native's own page badge verbatim, "this native is part
      of the 'client' API set" (MEDIUM-HIGH confidence — a search-index
      snippet of the real page, not a direct fetch, but a specific,
      unambiguous quote, not an inference). The original
      server-side call in HandleTakedownRequest's NPC branch was
      therefore a SILENT NO-OP, a real correctness/safety bug: the
      damage-bracket that is supposed to make a takedown non-lethal never
      actually applied to a server-spawned NPC target, and the health-floor
      backstop alone is a reactive one-time top-up, not a continuous damage
      block, so it cannot honestly cover sustained damage from another
      source during the ragdoll window on its own.
    - SetPedFleeAttributes, SetBlockingOfNonTemporaryEvents, and
      SetPedToRagdollWithFall (all `PED` namespace) could NOT be confirmed
      either way this session — the primary source's PED section and every
      mirror/doc host tried were unreachable. Indirect community
      corroboration is consistent with "client-only, same as
      SetEntityCanBeDamaged" but is NOT independent primary-source
      confirmation — graded MEDIUM confidence / single indirect source,
      honestly, not upgraded to match the one native that WAS confirmed.
    - SetEntityHealth (`ENTITY` namespace) — NEW FINDING, native-sweep
      follow-up pass, coder-backend: the health-floor backstop below
      (`if GetEntityHealth(targetPed2) < healthFloor then
      SetEntityHealth(targetPed2, healthFloor) end`) was, until this pass,
      the ONE remaining native in this exact NPC branch still called
      directly server-side, on the strength of a claim (this file's own
      prior comment, and .luacheckrc's) that "GetEntityHealth/SetEntityHealth's
      server-side validity is not in question." That claim did not survive
      the SAME verification method already applied to
      IsEntityDead/IsPedDeadOrDying elsewhere in this file (see
      PED_DEAD_HEALTH_THRESHOLD's own doc comment): `ext/native-decls` has
      NO doc page for SetEntityHealth at all (unlike GetEntityHealth/
      GetEntityMaxHealth, both of which have one with `apiset: server`),
      and a full-text search of every native-registering file in
      citizen-server-impl/src/state (the exact component that registers
      GET_ENTITY_HEALTH/GET_ENTITY_MAX_HEALTH via `makeEntityFunction` +
      `syncTree->GetPedHealth()/GetVehicleHealth()` reads) contains ZERO
      occurrence of `SET_ENTITY_HEALTH`/`SET_PED_HEALTH`, or of the
      substring `HEALTH` in any context other than a `GET_*` native.
      Architecturally consistent with that absence, not just coincidental:
      every health value this server reads comes from a sync-tree node
      populated by the entity's OWNING CLIENT and ACKed to the server — the
      server has a read path for that data but, unlike a getter, a "set"
      would require injecting a value into a client-owned sync node from
      the server side, a fundamentally different capability the getters'
      own implementation gives no evidence of existing. GRADED THE SAME AS
      SetEntityCanBeDamaged above: no confirmed server registration, so
      this call is a SUSPECTED silent no-op — the health-floor top-up for
      an already-low-health NPC target never actually applied. Fixed the
      same way as the other three: moved to the REQUESTING K9's OWN client,
      alongside the damage-bracket/ragdoll relay immediately below it in
      HandleTakedownRequest — no new payload field needed on
      `applyNpcTakedown` since `Config.Combat.NonLethalTakedown.healthFloor`
      is already a `shared_scripts`-loaded config value client/combat.lua
      can read directly. THIS FILE'S OWN HALF of that fix (stop calling the
      suspect native server-side) is complete below. STALE-COMMENT FIX
      (this pass, cross-change regression review — re-verified against the
      actual current client/combat.lua before rewriting this paragraph, not
      taken on the report alone): the CLIENT half has SINCE LANDED —
      client/combat.lua's `applyNpcTakedown` handler now calls
      `SetEntityHealth(npcPed, Config.Combat.NonLethalTakedown.healthFloor)`,
      guarded the same `< healthFloor` way, ordered between the
      damage-bracket and the ragdoll task, exactly matching what this
      paragraph originally asked for. This comment used to say that call
      was "OUT OF SCOPE for this file... until that lands, [the gap] widens
      slightly further" as though still pending — that framing is what went
      stale, not the underlying fix. The one-time top-up is therefore no
      longer unapplied; the damage-bracket/ragdoll relay (both independently
      confirmed working, see above) remain the primary, continuous
      protection during the window regardless — the health-floor call was
      always disclosed as a one-time supplement on top of them, never a
      replacement for either.
    Rather than assert an unresolved server-side legitimacy for these
    natives just to keep one code shape, or leave one bug fixed and the
    rest standing on an unverified assumption, ALL FIVE are relayed to
    the REQUESTING K9's OWN client instead — unambiguously a valid
    execution context for all five regardless of their server-side status
    (their CLIENT-side validity was never in question; SetPedToRagdollWithFall
    is already independently confirmed client-callable by this same file's
    own player-target relay, applied via client/combat.lua's forceRagdoll
    handler, and SetEntityHealth is already independently confirmed
    client-callable by server/medkit.lua's own applyMedkitHeal relay,
    the identical "server decides the number, the entity's own client
    writes it" pattern). This is not a weakening of server authority: the
    server has already independently completed every real check (feature
    flag, HasK9Access, live proximity, cooldowns, the speed gate for
    takedown) BEFORE ever sending one of these five relay events — only the
    MECHANICAL "make the NPC do X" step moves client-side, to the one actor
    already fully trusted for this action, mirroring the exact posture this
    file already uses for a PLAYER target (relay to the target's own
    client) just relayed to the K9 instead, since an NPC has no "own
    client" to relay to. See client/combat.lua's own header for the
    receiving-side implementation.
    ======================================================================

    No anim-dictionary/TASK_PLAY_ANIM asset is used for BiteAndHold in this
    pass — DEVELOPER_REFERENCE.md#phase-3-combat's own §1 write-up flags
    the one candidate clip (`creatures@rottweiler@melee@streamed_core@` /
    `takedown_from_back`) as MEDIUM confidence, one-shot (not a sustained
    hold loop), model-specific to the Rottweiler only, and explicitly
    "needs actual in-engine testing... a design/asset call for
    coder-frontend once someone has direct game access." Resolving that
    asset question is out of scope for a security-lens implementation pass
    — client/combat.lua instead reuses the ALREADY-CONFIRMED
    `WORLD_DOG_BARKING_*` aggressive-stance scenario (per that same note's
    own option (a)) as a safe, already-shipped-elsewhere placeholder for
    the K9's own visual during a hold. Flagged here, not silently decided:
    revisit once coder-frontend has previewed the takedown clip in-engine.
    NonLethalTakedown needs no new asset at all (fully native-only per that
    same note's §2).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls HasK9Access(source) (server/certifications/),
      ResolveNetworkEntity(netId, expectedEntityType?) (server/entities.lua),
      and ResolveConnectedPlayerFromPed(entity) (server/entities.lua,
      DEVELOPER_REFERENCE.md item 2b — see the PLAYER-VS-NPC RESOLUTION
      section below) — does not re-implement any of the three.
    - Calls NewCooldown()/NewMutex() (server/cooldowns.lua) — every
      cooldown/in-flight-guard below is one of these constructors, never a
      hand-rolled table, per DEVELOPER_REFERENCE.md item 1's own standing
      convention for this resource. The four cooldowns constructed straight
      from a Config.Combat.*.cooldownMs/targetCooldownMs field are each
      first passed through ResolveConfiguredThresholdMs (also
      server/cooldowns.lua) — see that call's own comment block and
      cooldowns.lua's header ADDENDUM for why a raw Config read must never
      reach NewCooldown's constructor unguarded in this file specifically.
    - Calls AwardXP(citizenid, awardKey), resource-global from
      server/progression.lua, ONLY IF IT EXISTS (same runtime-existence-guard
      convention, mirroring server/tracking.lua's own trackSourceResolved
      call site exactly) — see EndHold (BiteAndHold) and
      HandleTakedownRequest (NonLethalTakedown) for the two award call
      sites and their own anti-farm reasoning. Config.XP.awards.biteHoldSuccess/
      .takedownSuccess (config.lua) are the two award keys this file owns;
      searchContrabandFound/trackSourceResolved belong to
      server/search.lua/server/tracking.lua respectively, not here.
    - Loaded in fxmanifest.lua's server_scripts after cooldowns.lua,
      entities.lua, and certifications.lua (all three are load-time
      dependencies of this file). No ordering dependency on
      server/wellbeing.lua or server/progression.lua either way (both are
      consumed through runtime existence guards, not a load-order
      assumption) — same posture fxmanifest.lua documents for every soft
      cross-file dependency in this resource.
    - Calls `ClaimBody(citizenid, 'combat_target', ttlMs, detail)` and
      `ReleaseBody(citizenid, 'combat_target')`, exposed by
      server/bodyclaims.lua (kennel-vs-vehicle-seat race fix pass,
      coder-backend) — the shared exclusive body-claim registry. Every one
      of requestBiteHold/HandleTakedownRequest/requestDrag claims the
      PLAYER target's own citizenid (never an NPC's, which has none) the
      instant its own ActiveHolds entry is written, with `ttlMs` set to
      that exact hold's own remaining duration and `detail` set to the
      effectType ('bite'/'takedown'/'drag') so a denying caller elsewhere
      can pick an accurate rejection message; EndHold — the single choke
      point every termination path already funnels through — releases it.
      ALSO calls `IsBodyClaimed(citizenid)` (same file) inside
      ValidateCombatRequest, for the REQUESTING K9's own citizenid — a K9
      currently resting in a kennel or mid-vehicle-seat-claim must not be
      grantable as a bite-hold/takedown/drag HOLDER either; see that call
      site's own comment (immediately after the `already_engaged` check)
      for the full writeup, including why `IsBodyClaimed` and not
      `IsBodyClaimedByOther` is the correct primitive for this direction.
      Also EXPOSES `GetActiveHoldEffectTypeForHolder(holderSrc)` (this pass,
      alongside the pre-existing `IsK9CurrentlyHolding`) for
      server/kennel.lua's requestEnterKennel and server/vehicle.lua's
      requestVehicleSeatClaim to consult directly — a combat HOLDER's own
      busy-state, from THEIR side of the check, is answered by these two
      small accessors, not by a fourth participant in the shared registry;
      see server/bodyclaims.lua's own header for the full reasoning on all
      three halves of this design.
    ======================================================================

    PLAYER-VS-NPC RESOLUTION — DELIBERATE DEVIATION FROM DEVELOPER_REFERENCE.md'S
    OWN INFORMAL PROSE, flagged explicitly rather than silently diverging:
    §12.5.1/§12.5.2/§12.0 item 8's prose names `IsPedAPlayer(targetPed)` as
    the resolution mechanism. This file instead reuses
    `ResolveConnectedPlayerFromPed(entity)` — the SAME pattern
    server/search.lua's own security-reviewed
    `DEVELOPER_REFERENCE.md#contraband-search`-driven implementation already
    uses for the identical fact ("does this entity belong to a real,
    currently-connected player?"), for the SAME reason that file's own
    header gives: `IsPedAPlayer`/`NetworkGetPlayerIndexFromPed` combos were
    never independently confirmed reliable SERVER-side in this codebase's
    own native-verification passes (DEVELOPER_REFERENCE.md#phase-3-combat
    does not list `IS_PED_A_PLAYER` in its confirmed-natives table for
    either feature at all), whereas the `GetPlayers()`/`GetPlayerPed(id)`
    scan is already proven reliable server-side elsewhere in this exact
    codebase. This is a strictly more conservative choice (it can only
    ever resolve to an entity that IS some connected player's own ped) and
    gets both facts (is-a-player, AND that player's own server id) from
    one already-trusted mechanism instead of two natives of differing
    verified reliability.

    EXTRACTION UPDATE (DEVELOPER_REFERENCE.md item 2b): this file's own copy
    was flagged above (when this comment was first written) as "worth
    flagging to coder-architect as an extraction candidate now that there
    are two" — that observation was already stale on arrival, since
    server/inventory.lua had independently hand-copied the identical
    function before this file landed, making three. `ResolveConnectedPlayerFromPed`
    is now a resource-global exposed by server/entities.lua (same file,
    same responsibility, as `ResolveNetworkEntity`); this file's own local
    copy is deleted and ValidateCombatRequest below calls the shared
    global instead, with no change to its own logic or call site.
    ======================================================================

    NON-COMPLIANCE DETECTION (DEVELOPER_REFERENCE.md §12.0 item 8, point 2) — real,
    implemented sampling, not a sketch. TWO shared maintenance threads (never
    one thread per active effect, mirroring server/tracking.lua's
    PruneTrackableLogs single-pass-over-a-shared-table discipline), each
    doing exactly one job, on two DELIBERATELY DECOUPLED intervals:
      (a) the expiry thread (MAINTENANCE_INTERVAL_MS below, hardcoded,
          NEVER Config.Combat.NonComplianceDetection.positionSampleWindowMs)
          enforces every active hold/ragdoll's hard expiresAt cap — ALWAYS,
          regardless of Config.Combat.NonComplianceDetection.enabled — this
          is item 4's "no unbounded trap" guarantee and must never be gated
          behind, or have its timing at the mercy of, the detection
          feature's own (separately configurable) sampling interval;
      (b) IF NonComplianceDetection.enabled, a second, independent thread
          runs on its own positionSampleWindowMs interval and samples the
          target's live, server-authoritative position (GetEntityCoords —
          NEVER a client-reported value), applying the PER-EFFECT heuristic
          DEVELOPER_REFERENCE.md §12.0 item 8 specifies:
            - BiteAndHold: near-stationary check, flagged only after
              `biteHoldViolationSamples` CONSECUTIVE over-threshold
              samples (never a single noisy sample — server/tracking.lua's
              own FORGED TRAIL DECISION reasoning against auto-punishing on
              one noisy signal applies here too).
            - NonLethalTakedown: net displacement from the ragdoll-open
              baseline position, NOT a continuous speed check (a genuine
              ragdoll produces noisy, non-directional per-tick velocity a
              speed check would false-positive on).
      DISCLOSED SIMPLIFICATION vs. item 8's fuller text: item 8's own
      writeup additionally asks for "a sustained consistent heading rather
      than random tumbling drift" as the stronger tell for takedown. This
      pass implements the simpler, honestly-weaker "net displacement past a
      flat threshold" half of that only — full heading-consistency
      discrimination (distinguishing a directed walk-away from a scripted
      knockdown from random tumbling scatter) is NOT implemented here.
      This is a disclosed narrowing of a NON-PUNITIVE, log-only heuristic,
      not a silent gap — flagged for whoever next tunes this table to
      decide whether the added complexity is worth it before this feature
      is ever enabled on a live server.
    On a flagged violation: always printed (the 'log' baseline, per
    Config.Combat.NonComplianceDetection.action's own doc comment — 'log'
    cannot mean "don't log"); ADDITIONALLY alerts any currently-connected
    player holding the 'command' ACE permission via an ox_lib notify when
    action == 'notify_staff' (a generic, ecosystem-standard staff-permission
    convention — this resource assumes no particular admin resource exists,
    per DEVELOPER_REFERENCE.md §2's "exports/events exposed so integration is possible, no
    particular external resource assumed" posture, same as
    WantedStatusCheckOverride/IsPlayerDownedOverride elsewhere in this
    codebase). Config.Combat.NonComplianceDetection.OnViolationOverride, if
    supplied, is ALWAYS invoked on a flagged violation (pcall-wrapped,
    logged-not-thrown on error) regardless of `action`'s value — it is an
    independent, additive opt-in hook, not a gate on the built-in log/
    notify_staff behavior.
    NEVER auto-kick/auto-ban, never any effect on this resource's own
    server-authoritative state (guardrail 3 above) — detection only.
    ======================================================================

    RED-TEAM TRUST-BOUNDARY PASS (this pass, coder-security) — three gaps
    traced against ValidateCombatRequest and its four callers
    (requestBiteHold, requestTakedown/HandleTakedownRequest, requestDrag):
    1. "Teleport-bite/teleport-takedown" — the only proximity gate was a
       single live-distance read at request time, with no check that the
       K9's OWN position was plausible in the preceding ticks. FIXED: see
       K9PositionHistory's own declaration comment (near ActiveHolds/
       K9ActiveEffect below) and the dedicated background sampling thread
       (near this file's other maintenance threads) for the full writeup —
       adapted from, not copied from, server/tracking.lua's own
       PendingTrackArrival/minElapsedMs anti-"teleport-and-report" design.
    2. "Bite/takedown through walls" — no line-of-sight check exists
       anywhere server-side, confirmed both by an exhaustive grep of every
       server/*.lua in this resource and by tracing citizen-server-impl's
       own native-registration source directly. NOT FIXED — genuinely not
       fixable server-side (FXServer loads no collision/physics world at
       all) without a materially larger witness-corroboration design out of
       this pass's scope. See the dedicated comment at ValidateCombatRequest's
       own live-proximity check (below) for the full verification trail and
       the honest disclosed residual risk.
    3. "No vehicle-occupancy exclusion" — neither ValidateCombatRequest nor
       HandleTakedownRequest checked whether the TARGET was seated in a
       vehicle. FIXED: see the IsPedInAnyVehicle check inside
       ValidateCombatRequest (below) — gated behind
       Config.Combat.ExcludeVehicleSeatedTargets (landed in config.lua,
       `true` by default; reads `~= false`, defaulting to EXCLUDE). Also
       re-checked MID-HOLD (STATE-MACHINE FIX, this pass), not just at
       request time — see ExcludeVehicleSeatedTargetsMidHold's own
       declaration comment (near the shared expiry maintenance thread) for
       the full writeup: a target who gets INTO a vehicle after a
       bite/takedown/drag was already granted no longer had anything
       re-checking that fact before this fix.
    ======================================================================
]]

-- Ephemeral, in-memory only (mirrors server/main.lua's LeashPairs and
-- server/tracking.lua's own precedent — live-session data, not account
-- data, does not survive a resource restart, and does not need to).
-- Keyed by the TARGET'S network id (stable regardless of whether the
-- target is an NPC ped or a live player's own ped) — one entry per
-- currently-held/ragdolled target, never more than one at a time per
-- target (enforced by the 'already_held' check below).
--
-- ActiveHolds[targetNetId] = {
--     effectType   = 'bite' | 'takedown' | 'drag',
--     holderSrc    = number,           -- the K9 player's own source
--     isPlayerTarget = boolean,        -- resolved server-side via ResolveConnectedPlayerFromPed, NEVER client-claimed
--     targetSrc    = number?,          -- present only when isPlayerTarget
--     startedAt    = number,           -- GetGameTimer() at open
--     expiresAt    = number,           -- GetGameTimer() hard cap -- DEVELOPER_REFERENCE.md §12.0 item 4's "no unbounded trap" guarantee
--     compliance   = { ... },          -- see NON-COMPLIANCE DETECTION above; shape differs slightly per effectType, see the two sampling branches below
-- }
local ActiveHolds = {}

-- K9ActiveEffect[holderSrc] = targetNetId -- "one hold at a time per K9"
-- (DEVELOPER_REFERENCE.md §12.5.1: "One hold at a time per K9"), enforced across
-- BOTH BiteAndHold and NonLethalTakedown (a single K9 engaging one target
-- at a time, not one slot per effect type) -- also lets releaseBiteHold
-- resolve its own target without a linear scan of ActiveHolds.
local K9ActiveEffect = {}

-- RED-TEAM FINDING 1 FIX (this pass, coder-security): "teleport-bite" /
-- "teleport-takedown". ValidateCombatRequest's own live-proximity check
-- below (`#(k9Pos - GetEntityCoords(targetPed))`) only ever reads a SINGLE
-- instantaneous position at the moment the event is processed -- it has no
-- opinion on whether the K9 got there plausibly. A modded client can
-- SetEntityCoords the K9 ped to within range, fire requestBiteHold/
-- requestTakedown/requestDrag, then teleport back out, and for takedown
-- specifically (whose own ValidateCombatRequest re-check happens a second
-- time, post-Wait, at :2310 below) simply hold position for the short
-- speedSampleWindowMs and teleport away immediately after.
--
-- MIRRORS server/tracking.lua's OWN already-shipped anti-"teleport-and-
-- report" design (that file's PendingTrackArrival/`minElapsedMs`/
-- MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS, see its own declaration comments for the
-- full ECONOMY-AUDIT FIX HOLE 2 writeup) as directed, but adapted rather than
-- copied verbatim: tracking.lua's mechanic is a two-PHASE "resolve now,
-- arrive later" flow with a natural gap to measure real elapsed time across
-- -- BiteAndHold/PropDragging's own requestBiteHold/requestDrag are
-- SINGLE-SHOT (one client->server event, no second phase), and even
-- NonLethalTakedown's own two ValidateCombatRequest samples are only
-- speedSampleWindowMs (250ms shipped) apart, an interval a fast teleport
-- can straddle entirely. Measuring "distance travelled BETWEEN two
-- ValidateCombatRequest calls from the SAME request" therefore cannot work
-- here the way it does for tracking.lua's resolve/arrive pair -- worse,
-- this resource's own 20-35s combat cooldowns (BiteHoldCooldown/
-- TakedownCooldown/etc.) mean the gap between two SEPARATE requests from the
-- same K9 is already so large that almost any teleport distance would read
-- as "plausible" travel if measured that way, making the check a no-op in
-- practice.
--
-- FIX ACTUALLY BUILT: an INDEPENDENT background sampling thread (see
-- K9_POSITION_SAMPLE_INTERVAL_MS's own thread near the bottom of this
-- file's maintenance-thread section) records every online player's own live
-- GetEntityCoords position on a fixed cadence, completely decoupled from
-- request timing -- exactly the property tracking.lua's own createdAt/
-- minElapsedMs pair achieves via its two-phase flow, achieved here instead
-- via continuous, request-independent sampling since no second phase
-- exists to piggyback on. ValidateCombatRequest below then compares the
-- K9's CURRENT position against this independently-sampled history and
-- rejects the request if the IMPLIED SPEED between the two exceeds
-- MAX_PLAUSIBLE_K9_SPEED_MPS -- the same "server-measured distance /
-- server-measured elapsed time, never a client-supplied value" discipline
-- tracking.lua's own fix already established.
--
-- FAILS OPEN ONLY ON MISSING DATA, never on a detected violation: a K9 with
-- no history entry yet (freshly connected, within the first
-- K9_POSITION_SAMPLE_INTERVAL_MS of joining, before the sampling thread's
-- own first tick has run for them) is ALLOWED through with no plausibility
-- opinion at all -- there is no baseline to compare against, and rejecting
-- on "insufficient data" would false-positive every legitimate K9's very
-- first request after a resource restart or reconnect. This is a disclosed,
-- BOUNDED residual gap (see this file's own final report to the team for
-- the honest writeup), not a silent one: it narrows the exploit from
-- "any time, repeatedly" to "at most once per fresh connection, and only
-- within roughly one sampling interval of connecting" -- reconnecting to a
-- FiveM server is far slower than the cooldowns this mechanic already
-- imposes, so this is not a practically repeatable bypass.
--
-- K9PositionHistory[src] = { pos = vector3, time = number } -- GetGameTimer()
-- of the LAST independent background sample, never updated by
-- ValidateCombatRequest itself (see the sampling thread's own comment for
-- why a request-time update would defeat this check against this file's own
-- cooldowns) and never keyed by anything client-supplied.
local K9PositionHistory = {}

-- ALL FOUR ResolveConfiguredThresholdMs CALLS BELOW (this pass, coder-backend
-- -- QA sandbox repro): these four constructors used to hand a raw
-- Config.Combat.*.cooldownMs value straight to NewCooldown. A single
-- non-positive one of them (e.g. an operator setting cooldownMs = 0 meaning
-- "no cooldown", this resource's own repeatedly-documented FOOTGUN) threw
-- inside NewCooldown's own AssertValidDefaultThreshold at THIS file's
-- top-level load time -- which does not just disable that one cooldown, it
-- aborts this entire file's execution from that line onward, silently
-- un-defining EndActiveEffectForHolder (near the bottom of this file, this
-- codebase's own termination primitive several other files depend on)
-- along with every
-- BiteAndHold/NonLethalTakedown/PropDragging RegisterNetEvent below it.
-- ResolveConfiguredThresholdMs (server/cooldowns.lua, see that file's header
-- ADDENDUM for the full incident) resolves each value to something always
-- valid BEFORE NewCooldown ever sees it -- printing one unmissable warning
-- naming the exact key/found value/substituted fallback instead of erroring
-- -- so a bad Config number degrades to "this one cooldown uses a safe
-- built-in value" rather than "this file, and everything depending on it,
-- stops existing." Fallback literals below match config.lua's own shipped
-- defaults for each field exactly.
local BiteHoldCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.BiteAndHold.cooldownMs, 20000, 'Config.Combat.BiteAndHold.cooldownMs'))
BiteHoldCooldown.RegisterPlayerDropped()

local TakedownCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.NonLethalTakedown.cooldownMs, 25000, 'Config.Combat.NonLethalTakedown.cooldownMs'))
TakedownCooldown.RegisterPlayerDropped()

-- Keyed by targetNetId, NOT a player source -- no per-connection cleanup
-- hook exists for this key domain (mirrors server/search.lua's
-- TargetSearchCooldown, keyed by a resolved plate/citizenid string for the
-- exact same reason). Swept periodically below rather than relying on
-- RegisterPlayerDropped.
local TakedownTargetCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.NonLethalTakedown.targetCooldownMs, 30000, 'Config.Combat.NonLethalTakedown.targetCooldownMs'))

-- XP-FARM FIX (this pass, coder-backend -- coordinator-flagged, independently
-- re-verified by re-reading requestBiteHold/HandleTakedownRequest side by
-- side, not taken on the report alone): BiteAndHold, UNLIKE NonLethalTakedown
-- immediately above, had ONLY a per-K9 cooldown (BiteHoldCooldown, keyed by
-- `src`) and no per-TARGET cooldown at all. `ActiveHolds[targetNetId]`
-- ('already_held' in ValidateCombatRequest) only blocks a DIFFERENT K9 from
-- concurrently holding the same target while a hold is active -- it does
-- NOT stop the SAME K9 from re-targeting the SAME already-released target
-- again the instant its own per-K9 cooldown clears. Against one fixed,
-- non-fleeing target (an NPC, or a wanted-but-stationary player), that meant
-- an unlimited "hold >= MIN_BITE_HOLD_XP_DURATION_MS, release, wait
-- BiteAndHold.cooldownMs, repeat" loop, each cycle minting
-- Config.XP.awards.biteHoldSuccess XP for a few seconds of standing still --
-- exactly the per-target throttle TakedownTargetCooldown already exists to
-- prevent for the sibling mechanic, just never applied here. Mirrors
-- TakedownTargetCooldown exactly: keyed by targetNetId (NOT a player
-- source -- an NPC target has none, and a player target's own cooldown must
-- outlive any one connection the same way TakedownTargetCooldown's already
-- does), swept periodically below rather than RegisterPlayerDropped.
-- Config.Combat.BiteAndHold.targetCooldownMs (config.lua) landed this pass
-- at the coordinator's request -- see that key's own comment in config.lua
-- for why it is set slightly above NonLethalTakedown's 30000 rather than
-- copied verbatim (a bite hold can pay out repeatedly inside its 15s
-- window; a takedown is one discrete event).
local BiteHoldTargetCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.BiteAndHold.targetCooldownMs, 35000, 'Config.Combat.BiteAndHold.targetCooldownMs'))

-- PROPDRAGGING HAD NO COOLDOWN OF ANY KIND -- neither per-K9 nor
-- per-target -- while KNOWN_ISSUES.md's own combat section claimed "every
-- cooldown (per-K9, per-target...)" applied uniformly across all three
-- mechanics. It did not; drag was simply never given any, and the prose
-- was written from the other two. (KNOWN_ISSUES.md corrected in the same
-- pass as this.)
--
-- Why it matters more here than the missing-cooldown shape usually does.
-- Drag is the one mechanic whose TARGET has a self-release of their own
-- (releaseDrag accepts the target as well as the holder -- see that
-- handler below). That escape is only worth anything if the K9 cannot
-- immediately re-grab: with no per-target cooldown, "let go, grab again"
-- was an unbounded loop against an already-downed player who, by the
-- mechanic's own precondition, cannot stand up and walk away from it.
-- Bite and takedown do not have this problem, not because they are gentler
-- but because their targets never had a self-release to render useless in
-- the first place, and both already carry a per-target cooldown regardless.
--
-- Construction mirrors the two pairs above exactly: per-K9 keyed by `src`
-- with RegisterPlayerDropped, per-target keyed by targetNetId (an NPC
-- target has no source, and a player target's cooldown must outlive any
-- one connection) with a periodic TTL sweep below instead. Both stamp at
-- drag START, same as their siblings -- see config.lua's own comment on
-- Config.Combat.PropDragging.targetCooldownMs for why stamping at the
-- start (rather than at release) is what makes the escape meaningful.
local DragCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.PropDragging.cooldownMs, 8000, 'Config.Combat.PropDragging.cooldownMs'))
DragCooldown.RegisterPlayerDropped()

local DragTargetCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Combat.PropDragging.targetCooldownMs, 20000, 'Config.Combat.PropDragging.targetCooldownMs'))

-- Guards the SHORT yield inside HandleTakedownRequest (the server-computed
-- speed-sample window) against the SAME K9 firing a second overlapping
-- requestTakedown before the first one's wait resolves -- mirrors
-- server/search.lua's SearchMutex exactly (same "reject outright, never
-- queue/race a concurrent call from the same source" rationale), needed
-- here specifically because, unlike requestBiteHold, requestTakedown's
-- handler yields (Wait(...)) before completing.
local TakedownMutex = NewMutex()
TakedownMutex.RegisterPlayerDropped()

-- Anti-farm floor for BiteAndHold's XP award (Config.XP.awards.biteHoldSuccess,
-- config.lua) — see EndHold's own award call site below for the full
-- reasoning. UNTUNED placeholder, same "flag the number, don't pretend it's
-- reviewed" convention as every other numeric constant in this file/this
-- codebase pending a config-validator pass. A hold that ends via 'timeout'
-- always clears this floor trivially (timeout cannot fire before
-- Config.Combat.BiteAndHold.maxDurationMs elapses); this constant only ever
-- actually gates the 'released' path, specifically to block an
-- accept-then-immediately-release macro from minting XP with no real
-- restraint ever having happened.
local MIN_BITE_HOLD_XP_DURATION_MS = 3000

--- NATIVE-AVAILABILITY FIX (this pass, coder-backend, native-sweep
--- follow-up): `IsEntityDead`/`IsPedDeadOrDying` have NO server
--- implementation in FXServer at all -- confirmed against the primary
--- source, not just the 404 on their `ext/native-decls` doc pages. Traced
--- `citizenfx/fivem`'s own C++ native-registration list
--- (code/components/citizen-server-impl/src/state/ServerGameState_Scripting.cpp,
--- the exact file that implements every entity/ped-related native FXServer
--- DOES expose server-side): it contains zero `RegisterNativeHandler` call
--- for `IS_ENTITY_DEAD` or `IS_PED_DEAD_OR_DYING` anywhere -- while
--- `IS_PED_RAGDOLL` and `GET_ENTITY_HEALTH` (both already relied on
--- elsewhere in this file) ARE registered there. Confirmed a second way:
--- a full-repo source search for the literal registration strings
--- `"IS_ENTITY_DEAD"` / `"IS_PED_DEAD_OR_DYING"` returns zero matches
--- anywhere in the citizenfx/fivem monorepo. FXServer does not throw on an
--- unregistered native -- it silently no-ops and the result buffer is
--- never written, so every prior `IsEntityDead(...)`/`IsPedDeadOrDying(...)`
--- call in THIS file always returned `false`, forever, regardless of the
--- target's actual state. Every server-side call site below is rewritten
--- to use `GetEntityHealth`, which IS confirmed registered
--- (`GET_ENTITY_HEALTH` in that same file) and already used elsewhere here.
---
--- THRESHOLD, CHOSEN DELIBERATELY, NOT COPIED NAIVELY:
--- `GetEntityHealth(ped) <= 0` is NOT what the game engine means by "dead."
--- GTA peds are conventionally declared dead once health drops to (or
--- below) 100, not 0 -- the well-documented CPed convention behind why a
--- ped's default max health is 200 rather than 100: the bottom 100 points
--- are the "already dead" floor, not usable HP. Using `<= 0` here would
--- silently make this check an near-permanent no-op again (a ped's health
--- essentially never reaches literal 0 before the engine already considers
--- it dead at 100), reproducing the exact fail-open bug this pass exists to
--- fix while LOOKING fixed -- exactly the "subtler fail-closed [substitution
--- gone wrong]" trap flagged for this pass. `<= 100` is used instead:
---   1. It matches the actual engine death threshold `IsEntityDead`/
---      `IsPedDeadOrDying` were themselves querying, for both NPC and
---      player peds alike (this is an engine-wide ped mechanic, not a
---      scripted one).
---   2. It is INTERNALLY CORROBORATED by this exact file's own
---      `Config.Combat.NonLethalTakedown.healthFloor = 100` (config.lua) --
---      NonLethalTakedown's own health-floor backstop is already using 100
---      as "the line a target must stay above to not actually die," the
---      same convention from the other direction.
---   3. It does NOT falsely flag a genuine laststand/downed PLAYER as dead:
---      every laststand/EMS framework this codebase already reasons about
---      (see IsTargetDowned's player branch and config.lua's own comments
---      on IsPlayerDownedOverride/WantedStatusCheckOverride) deliberately
---      keeps a downed player's REAL ped health well above the engine's
---      death floor specifically so the engine itself never auto-kills
---      them -- so a laststand player's raw health legitimately stays
---      `> 100`, and this check correctly does not reject them as dead
---      here, matching the intended (and previously, accidentally,
---      achieved-via-no-op) behavior for that case. This is confirmed
---      server-side data (GetEntityHealth reads the live synced ped health
---      value, same field the client itself reads), never a client claim.
--- This is a targeted, minimal substitution -- it restores the ORIGINAL
--- intended behavior (reject an actually-dead ped) without narrowing it to
--- also reject a merely-downed/laststand one, which is exactly the failure
--- mode flagged for a naive `<= 0` (or worse, `== 0`) substitution.
local PED_DEAD_HEALTH_THRESHOLD = 100

-- RED-TEAM FINDING 1 FIX (this pass, coder-security) -- see K9PositionHistory's
-- own declaration comment above for the full writeup this trio of constants
-- backs. FILE-LOCAL CONSTANTS, NOT Config.* FIELDS -- deliberately, same
-- reasoning BiteHoldXpMintCooldown's own declaration comment and
-- server/tracking.lua's MIN_TRACK_XP_DISTANCE/MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS
-- already establish for this exact class of anti-abuse floor: this is a
-- security backstop, not an operator-facing balance knob, and there is no
-- validation this file could add that would catch "an operator set this to
-- a technically-valid but useless value" the way NewCooldown's own
-- AssertValidDefaultThreshold already catches non-positive cooldowns.
-- Keeping it a local means the only way to weaken it is a reviewed source
-- edit, not a config change.
--
-- K9_POSITION_SAMPLE_INTERVAL_MS: cadence of the independent background
-- sampling thread (near this file's other maintenance threads, below). 1s
-- is coarse enough to be cheap (one GetPlayerPed+GetEntityCoords pair per
-- online player per second, the same order of cost as the existing
-- notify_staff fan-out's own per-tick GetPlayers() scan) while still being
-- far finer than this mechanic's own 20-35s cooldowns.
local K9_POSITION_SAMPLE_INTERVAL_MS = 1000

-- MIN_TELEPORT_CHECK_ELAPSED_MS: the plausibility check in
-- ValidateCombatRequest below FLOORS the elapsed-time DIVISOR at this value
-- when less than this much time has elapsed since the K9's own last
-- background sample -- guards against dividing by a near-zero elapsed time
-- (which would make even ordinary, non-teleport movement read as an absurd
-- implied speed) in the narrow window right after the sampling thread's own
-- most recent tick.
--
-- QA-FIX (this pass, coder-security -- red-team retry-bypass, found testing
-- against this exact check's own "an implausible jump is refused" test
-- immediately below in this file's usage): this used to SKIP the check
-- entirely (return with no opinion at all) rather than floor the divisor,
-- on the theory that "too little elapsed time to evaluate" should never
-- itself cause a rejection. That is true for a GENUINE small movement, but
-- the skip made the check a NO-OP for ANY movement, however large, landing
-- inside the first MIN_TELEPORT_CHECK_ELAPSED_MS of every
-- K9_POSITION_SAMPLE_INTERVAL_MS sampling cycle (~20% of every cycle at
-- shipped defaults, 200/1000) -- and a REJECTED ValidateCombatRequest call
-- costs the caller nothing (requestBiteHold/requestDrag only ever
-- IsOnCooldown/Touch a cooldown AFTER ValidateCombatRequest already
-- returned ok == true, so a failed attempt never burns anything). A hostile
-- client could therefore teleport next to a target and simply retry
-- requestBiteHold/requestDrag every well-under-200ms until one attempt
-- happened to land inside that window, bypassing this entire check on a
-- practically guaranteed handful of attempts -- silently defeating the
-- exact "teleport-bite"/"teleport-drag" fix this constant exists to
-- implement (HandleTakedownRequest's own SECOND, post-yield
-- ValidateCombatRequest call happens to make takedown far less exposed to
-- this specific retry, since a real teleport that slipped through the FIRST
-- call's skip window is then measured again ~speedSampleWindowMs later,
-- almost never inside a second skip window against the SAME stale sample --
-- but requestBiteHold/requestDrag call ValidateCombatRequest exactly once
-- each, with no such second chance to catch it). FLOORING the divisor
-- instead of skipping keeps the intended anti-jitter property (a genuinely
-- tiny real movement over a genuinely tiny elapsed time still computes a
-- low speed once floored) while ensuring a LARGE distance over a tiny
-- elapsed time is still caught -- flooring can only ever make the computed
-- speed larger (stricter), never smaller, than the skip it replaces, so no
-- previously-legitimate request is newly rejected by this change.
local MIN_TELEPORT_CHECK_ELAPSED_MS = 200

-- MAX_PLAUSIBLE_K9_SPEED_MPS: deliberately generous -- ~216 km/h, well above
-- any in-game vehicle's realistic top speed -- specifically so a K9 handler
-- who legitimately arrives fast BY VEHICLE (a patrol car, or even a fast
-- pursuit vehicle screeching to a halt right at the trigger range) is never
-- false-flagged; this exists to catch a teleport (which shows up as
-- hundreds-to-thousands of m/s over a ~1s sampling gap), not to second-guess
-- fast-but-real driving. Per this file's own "Anti-cheat false-positive
-- risk" mandate: this is a narrow, disclosed, request-denial-only check --
-- it never teleports, freezes, or otherwise touches the K9's own ped, and a
-- false positive costs the K9 nothing but having to re-issue the same
-- request a moment later once a fresh, closer sample lands.
local MAX_PLAUSIBLE_K9_SPEED_MPS = 60.0

local TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS = 60000
TakedownTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (Config.Combat.NonLethalTakedown.targetCooldownMs * 2)
end)

-- Same sweep shape, for the new BiteHoldTargetCooldown above (XP-farm fix,
-- this pass) -- keyed by targetNetId, no per-connection cleanup hook, so it
-- needs its own independent TTL sweep exactly like TakedownTargetCooldown's
-- does immediately above.
BiteHoldTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    return (now - loggedAt) > (Config.Combat.BiteAndHold.targetCooldownMs * 2)
end)

-- Same sweep shape again, for DragTargetCooldown (the missing-cooldown fix
-- above) -- keyed by targetNetId, no per-connection cleanup hook, so it
-- needs its own independent TTL sweep exactly like the two above.
--
-- The multiplicand is read defensively rather than straight out of Config
-- the way its two siblings do: this predicate runs inside a bare thread, so
-- a Config value that is nil or a string would throw INSIDE the sweep and
-- kill it silently and permanently, leaving the very table it exists to
-- bound growing for the rest of the session. The siblings have the same
-- shape and are flagged elsewhere; this one is written the safe way rather
-- than copying a known-sharp edge into new code.
DragTargetCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    local configured = Config.Combat.PropDragging.targetCooldownMs
    local ttlMs = (type(configured) == 'number' and configured > 0) and (configured * 2) or 40000
    return (now - loggedAt) > ttlMs
end)

-- SEVENTH XP-FARM FIX (this pass, coder-security, economy-audit follow-up --
-- independently re-verified against ValidateCombatRequest and both AwardXP
-- call sites below before acting, not taken on the report alone): every
-- cooldown declared above (BiteHoldCooldown/TakedownCooldown per-K9,
-- BiteHoldTargetCooldown/TakedownTargetCooldown per-target) gates the
-- ACTION -- none of them gate the XP MINT itself, independent of how cheaply
-- the action can be repeated. That gap is exploitable on its own (switch
-- between two targets and each one's own per-target cooldown never binds,
-- leaving only the per-K9 cooldown standing), and is made trivially
-- reachable with zero risk/collusion by ValidateCombatRequest's own NPC
-- branch a few lines up (`isPlayerTarget and not
-- IsPlayerWantedEligible(targetSrc)` -- an NPC target never runs the
-- eligibility check at all): two ambient, non-hostile NPC pedestrians in
-- range are a fully qualifying farm pair. Measured ceilings, from this
-- file's own shipped config.lua numbers: biteHoldSuccess (20 XP @
-- BiteAndHold.cooldownMs=20000) = 3,600 XP/hr; takedownSuccess (30 XP @
-- NonLethalTakedown.cooldownMs=25000) = 4,320 XP/hr -- both against a fixed
-- target this resource never required to actually be fleeing, wanted, or
-- carrying any risk to pay out. This is the same shape server/tracking.lua's
-- TrackTicketMintCooldown and server/search.lua's ContrabandXpMintCooldown
-- already closed for trackSourceResolved/searchContrabandFound respectively
-- -- ported here verbatim rather than reinvented: a flat, per-HOLDER (never
-- per-target -- that dimension is exactly what BiteHoldTargetCooldown/
-- TakedownTargetCooldown above already cover, and exactly the dimension
-- switching targets already defeats), cross-target cooldown on the MINT,
-- CONSUMED only at the exact instant a real award is about to happen -- see
-- both AwardXP call sites below (EndHold's 'bite' branch, HandleTakedownRequest's
-- own award block) for the gate itself, deliberately the LAST condition
-- checked in both places, mirroring TrackTicketMintCooldown.Consume/
-- ContrabandXpMintCooldown.Consume's own "ordered after every other
-- would-never-have-paid-anyway check" placement, so a hold/takedown that
-- was never going to pay out regardless (wrong end reason, under the
-- duration floor, a failed speed gate, no citizenid resolved) never burns
-- this budget for nothing, and a denied mint never stamps any other
-- "already paid" state -- neither AwardXP call site below writes anything
-- to ActiveHolds/K9ActiveEffect/any other table on this path, so a denial
-- can only ever cost this ONE award, never anything permanent (unlike the
-- near-miss this exact ordering exists to prevent in ContrabandXpState's own
-- history: stamping a permanent "already accounted for" record BEFORE
-- confirming the mint actually succeeded would turn a rate limit into a
-- standing denial).
--
-- 60000ms for both (recommended, not derived from a formula) lands in the
-- SAME ORDER OF MAGNITUDE the two prior fixes already established
-- (TrackTicketMintCooldown: 30s @ 10 XP = 1,200 XP/hr; ContrabandXpMintCooldown:
-- 60s @ 25 XP = 1,500 XP/hr) rather than inventing a new economy tier for
-- this mechanic: biteHoldSuccess becomes 60s @ 20 XP = 1,200 XP/hr,
-- takedownSuccess becomes 60s @ 30 XP = 1,800 XP/hr.
--
-- FILE-LOCAL CONSTANTS, NOT CONFIG KEYS -- same call TrackTicketMintCooldown's
-- own declaration comment already made for the identical reasoning,
-- re-verified here rather than assumed to still hold: this is an ANTI-FARM
-- FLOOR, not an operator-tunable balance knob. Config.Combat.BiteAndHold.
-- cooldownMs/targetCooldownMs and Config.Combat.NonLethalTakedown.cooldownMs/
-- targetCooldownMs are already the legitimate, operator-facing dials for how
-- often this mechanic can be used; these two constants exist ONLY to close
-- the "switch targets to dodge the per-target gate" mint farm, a security
-- floor rather than a balance decision. Exposing this as a Config field
-- would reopen exactly the footgun server/cooldowns.lua's own
-- IsValidThreshold/AssertValidDefaultThreshold pass exists to catch for
-- OTHER thresholds but structurally cannot catch for this one: an
-- operator-set value that is merely TOO LOW (as opposed to non-positive,
-- which NewCooldown's fail-closed handling already protects against) still
-- reads as a perfectly valid positive threshold, passes every existing
-- assert/guard in this codebase without complaint, and silently reopens
-- this exact farm at whatever cadence was chosen -- there is no validation
-- this file or cooldowns.lua could add that would catch "500ms is a valid
-- but useless value here" the way it already catches "0 means permanently
-- blocked, not disabled". Keeping this a file-local constant means the only
-- way to weaken it is to edit this file's own source under code review, not
-- a config edit.
local BiteHoldXpMintCooldown = NewCooldown()
BiteHoldXpMintCooldown.RegisterPlayerDropped()
local BITE_HOLD_XP_MINT_COOLDOWN_MS = 60000

local TakedownXpMintCooldown = NewCooldown()
TakedownXpMintCooldown.RegisterPlayerDropped()
local TAKEDOWN_XP_MINT_COOLDOWN_MS = 60000

-- EIGHTH XP-FARM FIX, CROSS-FILE POINTER (this pass, red-team-flagged
-- compound-farm follow-up to the SEVENTH fix immediately above): the two
-- per-holder mint cooldowns declared above, server/search.lua's
-- ContrabandXpMintCooldown, and server/tracking.lua's TrackTicketMintCooldown
-- are each keyed by the SAME acting player but were never summed -- a
-- player round-robining all four mechanics was blocked by none of them
-- (1,200 + 1,800 + 1,500 + 1,200 = 5,700 XP/hr combined, uncapped, reaching
-- the 9,000-XP Elite tier in ~1h 35m -- BELOW config.lua's own "over 2
-- hours" retuning goal). CLOSED by server/progression.lua's new SHARED,
-- cross-mechanic XP mint budget (XP_MINT_BUDGET_CAP_XP/
-- XP_MINT_BUDGET_WINDOW_MS, consulted inside AwardXP itself) -- see that
-- file's own declaration comment for the full derivation. Nothing in THIS
-- file needed to change for that half of the fix: AwardXP is the single
-- chokepoint both of this file's award call sites already went through, so
-- the shared budget applies to them automatically. BiteHoldXpMintCooldown/
-- TakedownXpMintCooldown above are KEPT, unchanged -- they still shape
-- WHICH mechanic can mint and at what per-mechanic cadence; the shared
-- budget in server/progression.lua caps the TOTAL across mechanics. This
-- file's OWN half of the compound-farm fix is the NPC-eligibility gate at
-- both AwardXP call sites below (Config.XP.mintXpForNpcCombatTargets) --
-- see each call site's own comment.

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

-- ResolveConnectedPlayerFromPed(entity) used to be defined here as a local
-- function (duplicated from server/search.lua's own copy). Extracted to
-- server/entities.lua as a resource-global per DEVELOPER_REFERENCE.md item
-- 2b — see this file's header "PLAYER-VS-NPC RESOLUTION" section's
-- "EXTRACTION UPDATE" note for the full reasoning. ValidateCombatRequest
-- below now calls that shared global instead.

--- DEVELOPER_REFERENCE.md §12.0 item 5. Never trusts a client-supplied "I am
--- wanted" (or "that target is wanted") claim — always reads server-side
--- state for `targetSrc` itself. FAILS CLOSED (returns false) if
--- Config.Combat.WantedStatusCheckOverride is supplied but errors — a
--- broken override must never silently widen who can be targeted.
--- @param targetSrc number
--- @return boolean eligible
local function IsPlayerWantedEligible(targetSrc)
    -- One implementation for every combat path: server/suspects.lua
    -- (officer marks, the setK9Suspect server event, the override, and the
    -- metadata default). Fails closed if that file somehow did not load.
    if type(IsPlayerK9Wanted) ~= 'function' then return not Config.Combat.RequireWantedStatus end
    return IsPlayerK9Wanted(targetSrc)
end

--- DEVELOPER_REFERENCE.md §12.0 item 6 / §12.5.4 — PropDragging's "is this target
--- actually downed" gate. NEVER reuses ValidateCombatRequest's own
--- dead-target check (that check exists specifically to REJECT a dead
--- target for BiteAndHold/NonLethalTakedown, the exact opposite of what
--- dragging wants) — called as a SEPARATE step, after
--- ValidateCombatRequest({requireAlive = false}) has already succeeded.
---
--- NPC branch: RESTRUCTURED (native-sweep follow-up pass, coder-backend) —
--- §12.5.4's original prose named `IsPedDeadOrDying(ped, true) OR
--- IsPedRagdoll(ped)`; the earlier version of this comment graded
--- IsPedDeadOrDying's server-side callability as "reasoned about by
--- analogy, not independently re-verified." That analogy has since been
--- independently checked against the primary source AND FOUND WRONG:
--- IsPedDeadOrDying, unlike GetEntityHealth/IsPedRagdoll, has NO FXServer
--- server implementation at all (traced citizenfx/fivem's own C++
--- native-registration list — see PED_DEAD_HEALTH_THRESHOLD's own doc
--- comment above for the full finding) and always silently returned
--- `false` here, degrading this OR into just `IsPedRagdoll` (a
--- dead-but-not-yet-ragdolled NPC was never recognised as downed). Now
--- `GetEntityHealth(ped) <= PED_DEAD_HEALTH_THRESHOLD OR IsPedRagdoll(ped)`
--- — both halves confirmed server-callable, and the NPC-only nature of
--- this branch means the player-branch laststand caveat below does not
--- apply (an NPC has no scripted laststand state to false-positive
--- against).
---
--- Player branch: NEVER the native checks above (§12.0 item 6 — raw
--- physics/AI state is a category mismatch for a server's own scripted
--- laststand state, with concrete false-positive/false-negative modes) —
--- override function first, FAILS CLOSED on error (same discipline as
--- IsPlayerWantedEligible above — a broken override must never silently
--- widen who can be dragged); else, if no override is configured, the
--- detected K9Compat ambulance adapter's `true`/`false` answer (COMPAT-
--- LAYER, this pass — see shared/compat/ambulance.lua's header for the
--- three-valued contract this step honours); else (adapter `nil`/
--- UNKNOWN, or nothing detected) the default best-effort
--- metadata.isdead/.inlaststand guess, exactly as before this pass.
--- @param targetPed number
--- @param isPlayerTarget boolean
--- @param targetSrc number?
--- @return boolean downed
local function IsTargetDowned(targetPed, isPlayerTarget, targetSrc)
    if not isPlayerTarget then
        -- NATIVE-AVAILABILITY FIX (see PED_DEAD_HEALTH_THRESHOLD's own doc
        -- comment above for the full finding): was `IsPedDeadOrDying(ped,
        -- true) or IsPedRagdoll(ped)`. `IsPedDeadOrDying` has no FXServer
        -- server implementation (confirmed against the same primary source
        -- as the ValidateCombatRequest fix above) and always returned
        -- false here, silently degrading this OR to just `IsPedRagdoll` --
        -- a dead-but-not-yet-ragdolled NPC was never recognised as downed
        -- (fails CLOSED: blocks a legitimate drag rather than allowing an
        -- illegitimate one, lower severity than the two fail-open sites,
        -- but still wrong). `IsPedRagdoll` is confirmed registered
        -- server-side and untouched below. The NPC-only nature of this
        -- branch means none of the player-branch laststand caveats above
        -- apply -- an NPC has no scripted laststand state, so a raw
        -- engine-death-floor health check is unambiguously the right
        -- signal here, not merely an approximation.
        return GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD or IsPedRagdoll(targetPed)
    end

    local override = Config.Combat.PropDragging.IsPlayerDownedOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, targetSrc)
        if not ok then
            print(('[qbx_k9unit] Config.Combat.PropDragging.IsPlayerDownedOverride errored for source %s: %s -- failing closed (target treated as NOT downed)'):format(targetSrc, tostring(result)))
            return false
        end
        return result == true
    end

    -- COMPAT-LAYER (this pass): only reached when no override is
    -- configured -- consult the detected ambulance adapter (shared/compat/
    -- ambulance.lua) as a FALLBACK, never a replacement, for the
    -- best-effort metadata guess below, exactly the resolution order that
    -- file's own header PRECEDENCE section requires: override (already
    -- handled above) wins unconditionally; only if absent, the adapter's
    -- `true`/`false` are trusted directly (a real, positive signal from
    -- whichever ambulance resource this server actually runs); its `nil`
    -- (UNKNOWN -- nothing detected, the resource isn't started, or it
    -- genuinely has no answer yet for this src) falls through to the SAME
    -- metadata guess this file already used before this pass, unchanged.
    -- `K9Compat.Get` is NEVER nil and its methods never throw (shared/
    -- compat/core.lua's own BuildSafeAdapter/BuildNoOpStub contract) -- no
    -- extra pcall/type guard needed here, matching every other
    -- K9Compat.Get call site in this resource (server/search.lua,
    -- server/medkit.lua, server/inventory.lua, etc. all call it bare; a
    -- couple of call sites add a defensive `type(K9Compat) == 'table'`
    -- belt-and-suspenders check on top for other reasons -- see server/
    -- integrations.lua's own comment on THAT --
    -- but none of them add a pcall around the call itself, because none
    -- need one). This function's own boolean contract (no third "unknown"
    -- state) is exactly why `true`/`false` short-circuit here but `nil`
    -- does not -- see shared/compat/ambulance.lua's header for why
    -- flattening `nil` into either boolean at a call site would be wrong.
    local ambulanceDowned = K9Compat.Get('ambulance').IsDowned(targetSrc)
    if ambulanceDowned == true then return true end
    if ambulanceDowned == false then return false end

    -- Default best-effort check -- see config.lua's own comment on this
    -- field for the confidence note (HIGHER confidence than
    -- WantedStatusCheckOverride's equivalent default, per DEVELOPER_REFERENCE.md
    -- §12.0 item 6 vs. item 5).
    local player = exports.qbx_core:GetPlayer(targetSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) ~= 'table' then return false end
    return metadata.isdead == true or metadata.inlaststand == true
end

-- RED-TEAM FINDING (PropDragging), resource-start WARNING, not an assert.
-- Config.Combat.PropDragging.IsPlayerDownedOverride is nil by default --
-- IsTargetDowned's own doc comment above and config.lua's own comment on
-- this field both already disclose that the fallback
-- (metadata.isdead/.inlaststand) is a best-effort guess, not a verified
-- state machine. What neither previously spelled out this loudly: on most
-- QB/qbx ambulance integrations that metadata is set by a CLIENT-self-
-- reported event, not a server-verified one, so on a default install a
-- player can flip it true to become an always-eligible drag target (LOW
-- impact -- they can self-release at any time via releaseDrag below, and no
-- XP/reward is attached to being the drag TARGET), or flip it false while
-- genuinely downed to become permanently undraggable -- which defeats the
-- mechanic's entire purpose against an incapacitated player.
--
-- WARNING, NOT ASSERT -- deliberately a WEAKER guard than
-- server/inventory.lua's accessScope assert or server/main.lua's
-- nudgeRequiresUnlocked/server/search.lua's own onResourceStart asserts.
-- Those asserts exist because their misconfigured value provided NO real
-- access control at all (a total defeat). This default is different in
-- kind, not just degree: it is a documented, already-disclosed
-- "best-effort" default (the SAME framing config.lua already gives
-- WantedStatusCheckOverride's identical nil-default case), it still
-- functions in the mechanic's intended direction for the ordinary,
-- non-adversarial case, and Config.Features.PropDragging itself defaults to
-- `false` (this codebase's "ship disabled until acceptance criteria are
-- fully met" convention) -- hard-failing resource start over a
-- disabled-by-default, already-disclosed best-effort gap would block every
-- server that flips PropDragging on without also wiring a real override on
-- day one, for a risk this file already discloses rather than hides. A
-- loud, actionable, printed warning -- impossible to miss in server console
-- output, unlike a comment only read by whoever opens this file -- is the
-- proportionate response here, not a hard stop.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if Config.Features.PropDragging and Config.Combat.PropDragging.IsPlayerDownedOverride == nil then
        print('[qbx_k9unit] WARNING: Config.Features.PropDragging is enabled but ' ..
            'Config.Combat.PropDragging.IsPlayerDownedOverride is nil. The default fallback ' ..
            '(metadata.isdead/.inlaststand) is typically a CLIENT-self-reported flag on QB/qbx ' ..
            'ambulance integrations, not a server-verified state machine -- a player can spoof it ' ..
            'true to always qualify as a drag target, or spoof it false to become permanently ' ..
            'undraggable while genuinely downed. Supply a real IsPlayerDownedOverride tied to your ' ..
            "own ambulance/laststand resource for a server-authoritative check (see config.lua's " ..
            'own comment on this field).')
    end
end)

--- Best-effort, non-restraint-implying rejection copy (guardrail 4) —
--- shared between BiteAndHold, NonLethalTakedown, and PropDragging since
--- their reason vocabularies overlap almost entirely.
local COMBAT_REJECT_MESSAGES = {
    feature_disabled   = locale('combat.feature_disabled'),
    -- Byte-identical to certifications.lua's own `type(targetServerId) ~=
    -- 'number'` rejection ("Invalid target.") -- same generic "the supplied
    -- target id failed basic type validation" concept, confirmed by reading
    -- that file's GrantCertification/RevokeCertification call sites before
    -- reusing, not a coincidental short-string collision. Reused rather
    -- than minted as a new combat.invalid_target duplicate.
    invalid_target     = locale('certifications.invalid_target'),
    no_access          = locale('combat.no_access'),
    -- Reuses client/search.lua's own half of the same mutual guard, rather
    -- than minting a second sentence for the identical situation seen from
    -- the other side. That file refuses a SEARCH while a bite/drag is
    -- running; this refuses a bite/drag while a SEARCH is running, and the
    -- dog is equally busy either way.
    busy_searching     = locale('combat.blocked_while_searching'),
    -- Was borrowed from the handler-down-defense locale group until
    -- 2026-09-02, when that feature (and its whole group) was removed at the
    -- owner's request. Combat is the only remaining consumer, so the exact
    -- same sentence now lives under combat's own namespace where it belongs.
    already_engaged    = locale('combat.already_engaged'),
    offline            = locale('combat.offline'),
    self_target        = locale('combat.self_target'),
    target_not_downed  = locale('combat.target_not_downed'),
    target_dead        = locale('combat.target_dead'),
    too_far            = locale('combat.too_far'),
    already_held       = locale('combat.already_held'),
    not_eligible_target = locale('combat.not_eligible_target'),
    not_fleeing        = locale('combat.not_fleeing'),
    on_cooldown        = locale('combat.on_cooldown'),
    -- server/wellbeing.lua-driven — these describe the REQUESTING K9's own
    -- state, never the target's (see this file's header FILE-TO-FILE
    -- CONTRACT entry for a since-removed wellbeing accessor).
    -- MESSAGE-ROUTING FIX (coder-backend handoff, this pass): 'permission_denied'
    -- used to be the ONE reason both an explicit block.<Name> AND a missing
    -- feature.<Name> grant collapsed into, mapped to the same generic
    -- locale('combat.reject_fallback') = "Unable to complete that action." --
    -- indistinguishable from any other unmapped failure, telling the player
    -- nothing about a personal grant/block even existing as a concept. Kept
    -- here, UNCHANGED, for the one case that still genuinely has no more
    -- specific story to tell (ValidateCombatRequest could not resolve a
    -- citizenid for the requester AT ALL -- see that call site's own updated
    -- comment) -- the two REAL per-person-feature-control outcomes now get
    -- their own distinct reasons/messages immediately below instead of
    -- sharing this one.
    permission_denied  = locale('combat.reject_fallback'),
    -- 'combat_blocked' / 'combat_not_granted' (this pass, coder-backend
    -- handoff -- see ValidateCombatRequest's own updated PER-PERSON FEATURE
    -- CONTROL comment for the full writeup): the two outcomes
    -- 'permission_denied' used to flatten together. Each now names the
    -- specific mechanic (CombatRejectMessage's own second `featureKey`
    -- argument, resolved through COMBAT_FEATURE_DISPLAY_LABEL below) and the
    -- real, distinct remedy for each -- "ask High Command why" for an
    -- explicit block (a deliberate decision, not a missing step) vs. "ask
    -- High Command to grant it" for a simply-never-granted capability.
    -- Deliberately NOT mapped as plain strings in this table the way every
    -- OTHER reason above is -- both need the featureKey substituted in via
    -- locale()'s own %s formatting, which this table's flat
    -- reason->already-resolved-string shape cannot express -- CombatRejectMessage
    -- below special-cases these two BEFORE ever consulting this table.
    -- CERTIFICATION TIER CAPABILITY denial (server/certtiers.lua's
    -- TierCapabilityPermits, wired into ValidateCombatRequest's
    -- BiteAndHold/NonLethalTakedown branch this pass -- see that call
    -- site's own comment for the full reasoning, including why this is
    -- kept a DISTINCT reason rather than collapsed into 'permission_denied'
    -- immediately above). The real key landed in locales/en.json on
    -- 2026-08-26 and this now uses it. Worth knowing why it was briefly
    -- mapped to reject_fallback instead: this table is a top-level literal
    -- evaluated at file-load time, and the test sandbox's locale() hard-
    -- asserts on a missing key -- so naming a key before it exists breaks
    -- every spec that loads this file, not just the ones exercising this
    -- reason. If you add another reason here, land its key first.
    tier_capability_denied = locale('combat.tier_capability_denied'),
    -- STALE-COMMENT FIX (this pass -- re-verified against the actual current
    -- locales/en.json before rewriting this paragraph, not left
    -- contradicting it): this comment used to say the RED-TEAM FINDINGS 1 &
    -- 3 keys immediately below ('implausible_movement', 'target_in_vehicle')
    -- were "DELIBERATELY NOT mapped here yet" pending the real locale keys
    -- landing -- that already happened (both exist in locales/en.json), just
    -- without ever swapping this table's own mapping in to match, exactly
    -- the "land the keys, then swap the mapping in" step tier_capability_denied's
    -- own history above already modeled. Fixed the same way, now that both
    -- ValidateCombatRequest's own call sites below (RED-TEAM FINDINGS 1 & 3)
    -- have had this fallen through to the generic reject_fallback message
    -- for longer than intended.
    implausible_movement = locale('combat.implausible_movement'),
    target_in_vehicle    = locale('combat.target_in_vehicle'),
    -- EXCLUSIVE BODY-CLAIM REGISTRY denial (server/bodyclaims.lua, this
    -- pass — see ValidateCombatRequest's own call site for the full
    -- writeup). Kept as an explicit mapping here, same "a reader of this
    -- table sees the reason was deliberately handled, not merely unmapped"
    -- reasoning 'permission_denied' above already states, even though it
    -- resolves to the exact same string CombatRejectMessage would already
    -- fall back to for an unmapped reason — locales/en.json is outside this
    -- pass's file ownership, so a dedicated key (naming kennel/vehicle
    -- specifically) is not available to land here the way
    -- tier_capability_denied's own history shows this file usually prefers.
    target_body_claimed = locale('combat.reject_fallback'),
    -- HOLDER-side half of the identical registry check immediately above --
    -- see ValidateCombatRequest's own `already_engaged`-adjacent call site
    -- for the full writeup. Same reasoning for reusing combat.reject_fallback
    -- rather than inventing a locales/en.json key this pass cannot land.
    holder_body_claimed = locale('combat.reject_fallback'),
}

--- COMBAT_FEATURE_DISPLAY_LABEL (this pass, coder-backend handoff): the
--- three literal featureKey strings ValidateCombatRequest's own call sites
--- already pass ('BiteAndHold' | 'NonLethalTakedown' | 'PropDragging'),
--- resolved to a human-readable label for the two per-person-feature-control
--- messages below. A featureKey missing from this table (should never
--- happen -- these three are this file's own complete, literal set) falls
--- back to the raw key string itself, never an error.
local COMBAT_FEATURE_DISPLAY_LABEL = {
    BiteAndHold = 'Bite and Hold',
    NonLethalTakedown = 'Non-Lethal Takedown',
    PropDragging = 'Prop Dragging',
}

--- @param reason string?
--- @param featureKey string? -- ONLY consulted for 'combat_blocked'/'combat_not_granted' below -- every other reason ignores it, so passing it unconditionally at every call site (this file's own convention now) is always safe.
--- @return string
--- @param reason string
--- @param featureKey string|nil -- 'BiteAndHold'|'NonLethalTakedown'|'PropDragging'
--- @param detail table|nil -- per-reason numbers the message can name:
---   { remainingMs = number }   for 'on_cooldown'
---   { observedSpeed = number } for 'not_fleeing'
--- A TABLE RATHER THAN MORE POSITIONAL ARGUMENTS on purpose: each reason
--- needs a different number, and two or three optional numbers in a row is
--- the kind of signature where a caller eventually passes the right value
--- in the wrong slot and the message quietly lies.
local function CombatRejectMessage(reason, featureKey, detail)
    local label = COMBAT_FEATURE_DISPLAY_LABEL[featureKey] or featureKey or '?'
    if reason == 'combat_blocked' then
        return locale('combat.denied_blocked', label)
    end
    if reason == 'combat_not_granted' then
        return locale('combat.denied_not_granted', label)
    end

    -- TWO REFUSALS THAT USED TO TELL THE PLAYER NOTHING ACTIONABLE, and
    -- both land mid-pursuit, which is the worst moment to be given a
    -- shrug. Resolved at call time (like the two denied_* cases above)
    -- rather than out of the pre-resolved COMBAT_REJECT_MESSAGES table,
    -- because both need a number the table cannot hold.
    --
    -- 'too_far' now names the range you have to be inside. Read from
    -- Config.Combat.<feature>.range -- the SAME field every caller passes
    -- into ValidateCombatRequest as its `rangeMeters` parameter, so the
    -- message and the check can never disagree. (Note the mismatch in
    -- names: the config key is `range`, the parameter it feeds is
    -- `rangeMeters`. Reading `rangeMeters` off the config table, as a first
    -- pass here did, silently found nothing and degraded to the generic
    -- sentence forever.) Only used when the lookup produces a real
    -- number, so a missing or malformed config still degrades cleanly
    -- rather than printing "nilm".
    --
    -- Deliberately NOT the live distance: that would mean threading a
    -- seventh return value out through all nineteen of
    -- ValidateCombatRequest's `return false` paths, and the actionable
    -- half is the range you need, not the gap you currently have.
    if reason == 'too_far' then
        local cfg = type(Config) == 'table' and type(Config.Combat) == 'table' and Config.Combat[featureKey]
        local range = type(cfg) == 'table' and tonumber(cfg.range)
        if range and range > 0 then
            return locale('combat.too_far_within', string.format('%.1f', range))
        end
    end

    -- 'on_cooldown' now says how many seconds are left. Rounded UP, so it
    -- never reads "0s" while still refusing, and never promises a shorter
    -- wait than the player actually has.
    local remainingMs = type(detail) == 'table' and tonumber(detail.remainingMs)
    if reason == 'on_cooldown' and remainingMs and remainingMs > 0 then
        return locale('combat.on_cooldown_seconds', tostring(math.ceil(remainingMs / 1000)))
    end

    -- 'not_fleeing' USED TO BE THE MOST MYSTIFYING REFUSAL IN THE FILE, and
    -- it lands mid-chase. The player presses takedown, the server samples
    -- the target's position twice across speedSampleWindowMs, and only THEN
    -- refuses -- so the button feels laggy and then says "the target does
    -- not appear to be fleeing" about someone the player is watching run.
    --
    -- It now names what was measured and what was needed, so the refusal is
    -- a fact about a speed rather than an opinion about intent. Both numbers
    -- are already in scope at the one call site.
    --
    -- WORTH KNOWING, and NOT changed here because it is a balance decision:
    -- the measurement is straight-line displacement between two samples, so
    -- a suspect who turns a hard corner or circles inside that window reads
    -- as slower than they are actually running, and can defeat the check
    -- without ever slowing down.
    local observed = type(detail) == 'table' and tonumber(detail.observedSpeed)
    if reason == 'not_fleeing' and observed then
        local cfg = type(Config) == 'table' and type(Config.Combat) == 'table' and Config.Combat.NonLethalTakedown
        local needed = type(cfg) == 'table' and tonumber(cfg.minTargetSpeed)
        if needed and needed > 0 then
            return locale('combat.not_fleeing_speed',
                string.format('%.1f', observed), string.format('%.1f', needed))
        end
    end

    return COMBAT_REJECT_MESSAGES[reason] or locale('combat.reject_fallback')
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- 4-step "first match wins" resolution, steps 2-4 (step 1 -- the feature's
-- own Config.Features.<Name> flag -- is already the `featureEnabled`
-- parameter ValidateCombatRequest below checks before this can ever run).
-- Mirrors server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId
-- byte-for-byte in SHAPE (read that function's own doc comment for the
-- full reasoning this does not repeat) -- generalised here to accept a
-- `featureKey` parameter since THIS file shares one validator across
-- THREE RequireGrant-listed features (BiteAndHold, NonLethalTakedown,
-- PropDragging) rather than pursuitsprint.lua's single hardcoded key. Kept
-- as this file's own tiny local copy rather than a shared export, matching
-- this resource's established "each file keeps its own tiny copy of a
-- genuinely small, self-contained check" convention (see e.g.
-- server/permissions.lua's IsDuplicateKeyError doc comment for the same
-- precedent named explicitly).
--
-- PRECEDENCE, PRESERVED EXACTLY per config.lua's own header: global off
-- (step 1, checked by the caller) beats everything; a block (step 2) beats
-- an active grant; RequireGrant (step 3) is checked ONLY once step 2 has
-- already passed; nothing here can ever WIDEN access -- both dynamic
-- lookups below (`RequireGrant[featureKey]`, `HasPermission`) fail CLOSED
-- on every unresolvable shape (missing Config.FeatureControl, missing
-- RequireGrant table, HasPermission entirely absent), matching
-- server/pursuitsprint.lua's identical fail-closed posture. NEVER called
-- for a termination/cleanup path (EndHold, releaseDrag, the maintenance
-- threads' own expiry sweep) -- only for the REQUEST that OPENS a new
-- effect -- so a mid-effect block/revoke can never strand an already-open
-- hold/drag; see EndHold's own header for why teardown is unconditional.
-- ======================================================================
--- @param citizenid string
--- @param featureKey string -- 'BiteAndHold' | 'NonLethalTakedown' | 'PropDragging' -- always a literal passed by this file's own call sites, never derived from anything client-supplied
--- @return boolean allowed
--- @return string? denyReason -- MESSAGE-ROUTING FIX (coder-backend handoff, this pass): nil when allowed==true, otherwise 'blocked' (step 2, an explicit block.<Name>) or 'not_granted' (step 3, RequireGrant-listed with no active feature.<Name> grant) -- see ValidateCombatRequest's own call site below for why this distinction matters. Purely an ADDITIVE second return value: every pre-existing call site that only reads the first return value (there were none outside this file before this pass; ValidateCombatRequest is the sole caller) is unaffected, and the authorization OUTCOME itself (the boolean) is byte-for-byte unchanged -- this is message-routing only, never a widened or narrowed check.
local function IsCombatFeaturePermittedForCitizenId(citizenid, featureKey)
    -- Soft dependency, this resource's established convention
    -- (`type(...) == 'function'`) -- server/permissions.lua may be absent
    -- from an install, or Config.Features.PermissionGrants may be off;
    -- HasPermission itself already returns false in either case. When it
    -- is entirely absent, step 2 (below) simply cannot fire -- nobody could
    -- ever hold a block -- and step 3 further down still fails CLOSED on a
    -- grant this resource is structurally unable to check.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.' .. featureKey) == true then
        return false, 'blocked' -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant[featureKey] == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        if hasPermissionAvailable and HasPermission(citizenid, 'feature.' .. featureKey) == true then
            return true
        end
        return false, 'not_granted'
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Shared request-time validation for BiteAndHold, NonLethalTakedown, AND
--- (this pass) PropDragging — DEVELOPER_REFERENCE.md §12.5.1/§12.5.2/§12.5.4's own
--- contract blocks specify an identical validation prefix for all three
--- (`requestBiteHold`/`requestTakedown`/`requestDrag`'s own doc text:
--- "re-validates ... HasK9Access(source), live proximity ..., resolves
--- player-vs-NPC ..., and — if the target is a player — RequireWantedStatus").
--- Feature-flag and range are passed in since those differ per effect;
--- everything else here is identical.
---
--- @param opts table? -- OPTIONAL, PropDragging-only knob (added this pass,
---   never passed by requestBiteHold/requestTakedown, so their behavior is
---   byte-for-byte unchanged): `opts.requireAlive` (default true via
---   `opts.requireAlive ~= false`). PropDragging passes
---   `{ requireAlive = false }` because its ENTIRE premise is a DOWNED
---   target — the dead-target rejection below (GetEntityHealth-based -- see PED_DEAD_HEALTH_THRESHOLD above) exists specifically to
---   REJECT BiteAndHold/NonLethalTakedown's target when dead, the opposite
---   of what dragging wants. PropDragging's own IsTargetDowned (above) is
---   the real "is this specific target eligible" check for that mechanic,
---   run by the caller AFTER this function returns ok == true — it is
---   deliberately NOT folded into this shared function, to keep this
---   function's own contract (identical prefix, effect-agnostic) honest
---   rather than growing a per-effect branch inside a "shared" validator.
---
--- PROXIMITY-BEFORE-MUTATION: this function performs ZERO mutation
--- (no cooldown Touch/Consume, no ActiveHolds write) — every check here is
--- read-only, matching this codebase's established bar (server/main.lua's
--- CheckLeashEligibility, server/search.lua's HandleSearchTarget) of
--- resolving every read-only precondition before a single state mutation
--- happens. Cooldown consumption and ActiveHolds mutation both happen at
--- the call site, strictly after this returns ok == true.
--- @param src number
--- @param targetNetId any
--- @param featureEnabled boolean
--- @param rangeMeters number
--- @param featureKey string -- 'BiteAndHold' | 'NonLethalTakedown' | 'PropDragging' -- passed to IsCombatFeaturePermittedForCitizenId below for the PER-PERSON FEATURE CONTROL check (config.lua's Config.FeatureControl), a REQUIRED parameter (not folded into `opts`, unlike PropDragging's own `requireAlive` knob) because all three call sites need it identically -- there is no effect-agnostic default that would make sense to omit.
--- @param opts table?
--- @return boolean ok
--- @return number? k9Ped
--- @return number? targetPed
--- @return boolean? isPlayerTarget
--- @return number? targetSrc
--- @return string? reason
local function ValidateCombatRequest(src, targetNetId, featureEnabled, rangeMeters, featureKey, opts)
    opts = opts or {}
    if not featureEnabled then
        return false, nil, nil, nil, nil, 'feature_disabled'
    end

    if type(targetNetId) ~= 'number' then
        return false, nil, nil, nil, nil, 'invalid_target'
    end

    if not HasK9Access(src) then
        return false, nil, nil, nil, nil, 'no_access'
    end

    -- MUTUAL GUARD vs. a contraband search, SERVER SIDE.
    --
    -- client/combat.lua and client/search.lua already refuse each other in
    -- both directions, but both of those run on the player's own machine and
    -- a modified game simply does not run them. Server-side the two halves
    -- were asymmetric: server/search.lua refuses a search from a dog that is
    -- already holding somebody (via IsK9CurrentlyHolding, further up this
    -- file), and nothing refused the reverse -- a bite, takedown or drag
    -- could still be started while a search was genuinely in flight on the
    -- server, tearing the dog out of its own search.
    --
    -- Placed after HasK9Access (an uncertified caller is not owed a "you are
    -- busy" message about something they could not do anyway) and before
    -- every other state read, matching this validator's own established
    -- cheapest-checks-first ordering.
    --
    -- Guarded call: server/search.lua defines this, and a server running
    -- with Config.Features.SearchZones off never loads it. An absent
    -- optional global is a skipped check here, never an error -- the same
    -- rule every other cross-file call in this resource follows.
    if type(IsSearchInProgressForSource) == 'function' and IsSearchInProgressForSource(src) then
        return false, nil, nil, nil, nil, 'busy_searching'
    end

    -- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl, steps
    -- 2-4 of its documented "first match wins" resolution -- step 1,
    -- `featureEnabled`, is already checked above). Placed here, immediately
    -- after HasK9Access and before every other state read below, mirroring
    -- server/pursuitsprint.lua's requestPursuitSprint call-site placement of
    -- its own identically-shaped check exactly. See
    -- IsCombatFeaturePermittedForCitizenId's own doc comment for the full
    -- fail-closed/precedence contract this implements.
    do
        local k9Player = exports.qbx_core:GetPlayer(src)
        local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
        if not k9Citizenid then
            -- No Player/citizenid resolved at all -- a different, far rarer
            -- edge case than an actual per-person feature-control denial
            -- (see IsCombatFeaturePermittedForCitizenId's own new second
            -- return value immediately below for that case) -- kept as the
            -- pre-existing generic 'permission_denied' reason, unchanged.
            return false, nil, nil, nil, nil, 'permission_denied'
        end
        -- MESSAGE-ROUTING FIX (coder-backend handoff, this pass -- see that
        -- message's own writeup): 'permission_denied' used to collapse BOTH
        -- an explicit block.<Name> AND a missing feature.<Name> grant into
        -- the SAME generic reason, which CombatRejectMessage mapped to
        -- locale('combat.reject_fallback') = "Unable to complete that
        -- action." -- telling the player nothing actionable: not that a
        -- personal grant exists as a concept, not which of the three
        -- abilities needs it, not who can fix it. `denyReason` now
        -- distinguishes the two so CombatRejectMessage (below) can build a
        -- specific, actionable message naming the feature and the real
        -- remedy for each. Never widens/narrows the underlying check --
        -- `citizenPermitted` alone is byte-for-byte the same boolean the old
        -- single-return call already produced.
        local citizenPermitted, denyReason = IsCombatFeaturePermittedForCitizenId(k9Citizenid, featureKey)
        if not citizenPermitted then
            return false, nil, nil, nil, nil, (denyReason == 'blocked') and 'combat_blocked' or 'combat_not_granted'
        end
    end

    -- CERTIFICATION TIER CAPABILITY (this pass -- server/certtiers.lua's
    -- TierCapabilityPermits, wired here per that file's own "CAPABILITY
    -- COMPOSITION" header section, which names THIS exact call site as one
    -- of its two identified-but-not-yet-wired consumers). A FLOOR laid
    -- UNDERNEATH HasK9Access and the PER-PERSON FEATURE CONTROL block
    -- immediately above -- checked only AFTER both have already said
    -- "allowed", and only able to NARROW that population further, never
    -- widen it: see TierCapabilityPermits' own doc comment (and this
    -- resource's .luacheckrc entry for it) for the fail-PERMISSIVE
    -- contract this relies on (allow unless the capability is actively
    -- granted by >=1 tier AND this citizenid's own resolved tier is not
    -- among them; every unresolvable case -- no tier, no lookup function,
    -- bad arguments -- is an allow, never a deny).
    --
    -- BiteAndHold/NonLethalTakedown ONLY -- deliberately NOT PropDragging,
    -- which shares this same validator for an unrelated mechanic. Checked
    -- against CAPABILITY_CATALOG (server/certtiers.lua): the ONE capability
    -- key that exists for this validator's mechanics is
    -- 'bite_hold_and_takedown', whose own label names bite-and-hold and
    -- non-lethal takedown explicitly and nothing else -- dragging is a
    -- separately-gated feature (its own Config.Features.PropDragging flag,
    -- its own range/cooldown config, and a target precondition -- already
    -- downed -- that is the OPPOSITE of what BiteAndHold/NonLethalTakedown
    -- require) with no capability key of its own in that closed, code-owned
    -- catalog. Folding dragging into 'bite_hold_and_takedown' here would
    -- silently widen what an operator ticking that ONE checkbox on the
    -- tablet actually controls, past what its own label says -- not this
    -- pass's call to make. If a future pass wants dragging gated by tier
    -- too, that needs its own reviewed CAPABILITY_CATALOG entry in
    -- server/certtiers.lua, not a silent piggyback here.
    --
    -- 'tier_capability_denied' is a NEW, deliberately DISTINCT reason --
    -- not collapsed into 'permission_denied' (or 'no_access') above, even
    -- though this resource establishes a real "don't invent a distinction
    -- the server doesn't give data for" precedent elsewhere. That precedent does not apply here: it covers
    -- cases where two failure causes are genuinely INDISTINGUISHABLE in
    -- their consequence for the player (server/combat.lua's OWN
    -- 'permission_denied' above is exactly such a case -- "blocked" and
    -- "never granted" read identically to whoever is denied, per that
    -- entry's own comment). A tier-capability denial is a DIFFERENT fact:
    -- this handler already has real K9 access and no admin-set
    -- block/missing-grant against them -- reusing 'no_access' would be
    -- FACTUALLY WRONG (HasK9Access already passed), and collapsing into
    -- 'permission_denied' would misreport which of two different remedies
    -- applies (ask an admin for a feature grant, vs. ask high command to
    -- either promote this handler's tier or grant the tier the
    -- capability). Mirrors the sibling call site landed this same pass,
    -- server/certifications/'s GrantSpecialization, which minted its own
    -- distinct 'certifications.specialization_requires_tier_capability' key
    -- rather than reusing 'specialization_requires_active_cert' for the
    -- identical reason.
    --
    -- LOCALE KEY -- LANDED (STALE-COMMENT FIX, re-verified against the
    -- actual current locales/en.json before rewriting this paragraph):
    -- this comment used to say combat.tier_capability_denied was "NOT YET
    -- LANDED" / "proposed... sent to main directly" and that
    -- COMBAT_REJECT_MESSAGES deliberately left it unmapped, falling through
    -- to the generic reject_fallback string. That already happened -- the
    -- key exists in locales/en.json and COMBAT_REJECT_MESSAGES maps it
    -- directly (see that table's own 'tier_capability_denied' entry above,
    -- with its own "the real key landed... on 2026-08-26" note) -- so
    -- CombatRejectMessage('tier_capability_denied') now returns the real,
    -- specific message, not the fallback.
    --
    -- REQUEST-TIME ONLY: this is ValidateCombatRequest, called only from
    -- requestBiteHold/requestTakedown's own opening checks -- never from
    -- EndHold, EndActiveEffectForHolder, the maintenance expiry sweep, or
    -- releaseBiteHold/releaseDrag. A handler whose tier loses this
    -- capability mid-hold must still be able to end that hold -- see this
    -- function's own doc comment and server/certtiers.lua's "NO UNBOUNDED
    -- TRAP" section for why a termination path may never gate on this.
    if featureKey == 'BiteAndHold' or featureKey == 'NonLethalTakedown' then
        local k9Player = exports.qbx_core:GetPlayer(src)
        local k9Citizenid = k9Player and k9Player.PlayerData and k9Player.PlayerData.citizenid
        local k9JobName = k9Player and k9Player.PlayerData and k9Player.PlayerData.job and k9Player.PlayerData.job.name
        if type(TierCapabilityPermits) == 'function' and k9Citizenid and k9JobName
            and not TierCapabilityPermits(k9Citizenid, k9JobName, 'bite_hold_and_takedown') then
            return false, nil, nil, nil, nil, 'tier_capability_denied'
        end
    end

    if K9ActiveEffect[src] then
        return false, nil, nil, nil, nil, 'already_engaged'
    end

    -- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
    -- THE HOLDER'S OWN SIDE, not just the target's (see the SEPARATE check
    -- near this function's own `return true` for the target-side half,
    -- landed earlier in this same pass and flagged by review as
    -- one-directional on its own -- this closes the other direction).
    -- Without this, a K9 currently resting in a kennel (a permanent,
    -- server-confirmed 'kennel_rest' claim) or mid-vehicle-seat-claim
    -- ('vehicle_seat') could still fire requestBiteHold/requestTakedown/
    -- requestDrag and be GRANTED as the holder -- attributing a real combat
    -- effect, and on success a real biteHoldSuccess/takedownSuccess XP
    -- mint, to a citizenid the server itself believes is attached inside a
    -- kennel or seated in a vehicle. `IsBodyClaimed` (not
    -- `IsBodyClaimedByOther`) is used deliberately here: a HOLDER never
    -- claims anything of its OWN in this registry (see
    -- server/bodyclaims.lua's own header "WHY NOT THE HOLDER SIDE"
    -- paragraph), so there is no "own mechanic" to exempt the way
    -- IsBodyClaimedByOther's renewal semantics exempt a caller re-confirming
    -- its own prior claim -- passing 'combat_target' here instead would
    -- WRONGLY exempt the one case that most needs catching: a K9 who is
    -- ALREADY the TARGET of a different combat effect (someone else's
    -- ActiveHolds entry against THIS citizenid) trying to ALSO become a
    -- holder against a third party. GATE THE START, NEVER THE STOP: this
    -- lives inside ValidateCombatRequest, which this file's own doc comment
    -- already establishes is ONLY ever called to OPEN a hold — never from
    -- EndHold, EndActiveEffectForHolder, the maintenance expiry sweep, or
    -- releaseBiteHold/releaseTakedown/releaseDrag — so a K9 who somehow
    -- ends up claimed by another mechanic mid-hold (this check cannot
    -- itself produce that state, since 'already_engaged' above already
    -- refuses a second grant to an existing holder) can still always let go
    -- of whatever it already holds, unaffected by this gate.
    do
        local holderPlayer = exports.qbx_core:GetPlayer(src)
        local holderCitizenid = holderPlayer and holderPlayer.PlayerData and holderPlayer.PlayerData.citizenid
        if holderCitizenid and IsBodyClaimed(holderCitizenid) then
            return false, nil, nil, nil, nil, 'holder_body_claimed'
        end
    end

    local k9Ped = GetPlayerPed(src)
    if k9Ped == 0 then
        return false, nil, nil, nil, nil, 'offline' -- defensive: src disconnected between the event firing and this line
    end

    -- Read once, reused below both for the teleport-plausibility check
    -- immediately following AND for the live-proximity check further down
    -- -- a single source of truth for "where is the K9 right now" within
    -- this one call, and one fewer native call than reading it twice.
    local k9Pos = GetEntityCoords(k9Ped)

    -- RED-TEAM FINDING 1 FIX (this pass, coder-security) -- see
    -- K9PositionHistory's own declaration comment (near ActiveHolds/
    -- K9ActiveEffect above) for the full writeup this implements, and the
    -- three constants immediately below PED_DEAD_HEALTH_THRESHOLD for the
    -- specific numbers used here. Placed BEFORE target resolution -- this
    -- check is entirely about the REQUESTING K9's own recent movement, it
    -- needs no target at all, so there is no reason to pay for
    -- ResolveNetworkEntity/player-vs-NPC resolution first.
    --
    -- FAILS OPEN on missing history (no baseline yet -- see the declaration
    -- comment's own disclosed, bounded residual-risk writeup), FAILS CLOSED
    -- (rejects the request) the moment a baseline exists and the implied
    -- speed between it and the K9's CURRENT position exceeds
    -- MAX_PLAUSIBLE_K9_SPEED_MPS. This is a REQUEST-TIME-ONLY gate, exactly
    -- like every other check in this function (see this function's own doc
    -- comment) -- it can never strand an already-open hold/takedown/drag,
    -- because ValidateCombatRequest itself is only ever called to OPEN one,
    -- never to end/maintain one (EndHold, EndActiveEffectForHolder, the
    -- maintenance expiry sweep, releaseBiteHold/releaseDrag all bypass this
    -- function entirely).
    do
        local history = K9PositionHistory[src]
        if history then
            local elapsedMs = GetGameTimer() - history.time
            -- FLOOR, never skip -- see MIN_TELEPORT_CHECK_ELAPSED_MS's own
            -- declaration comment above for the full retry-bypass writeup
            -- this replaces. A negative elapsedMs (should not normally
            -- happen, but cheaply guarded here rather than assumed away)
            -- floors the same way a too-small positive one does.
            local speedElapsedMs = elapsedMs >= MIN_TELEPORT_CHECK_ELAPSED_MS
                and elapsedMs or MIN_TELEPORT_CHECK_ELAPSED_MS
            local impliedSpeed = #(k9Pos - history.pos) / (speedElapsedMs / 1000.0)
            if impliedSpeed > MAX_PLAUSIBLE_K9_SPEED_MPS then
                return false, nil, nil, nil, nil, 'implausible_movement'
            end
        end
    end

    -- expectedEntityType = 1 (ped) -- see server/entities.lua's
    -- ResolveNetworkEntity doc comment for the GetEntityType numbering.
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then
        return false, nil, nil, nil, nil, 'invalid_target'
    end

    if targetPed == k9Ped then
        return false, nil, nil, nil, nil, 'self_target'
    end

    -- NATIVE-AVAILABILITY FIX (see PED_DEAD_HEALTH_THRESHOLD's own doc
    -- comment above for the full finding/reasoning): was `IsEntityDead
    -- (targetPed)`, which has no FXServer implementation and always
    -- returned false server-side, silently never rejecting an
    -- already-dead target here.
    if opts.requireAlive ~= false and GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD then
        return false, nil, nil, nil, nil, 'target_dead'
    end

    -- RED-TEAM FINDING 3 FIX (this pass, coder-security): neither this
    -- function nor HandleTakedownRequest previously checked whether the
    -- TARGET was seated in a vehicle at all -- a bite/takedown/drag could be
    -- initiated against someone sitting in a car (tests/vehiclecombatguard_spec.lua
    -- only ever guarded the K9's OWN vehicle-loaded conflict, client-side,
    -- never a seated TARGET). `IsPedInAnyVehicle` is confirmed
    -- server-registered (citizen-server-impl's own
    -- ServerGameState_Scripting.cpp, the same authoritative source this
    -- file's own PED_DEAD_HEALTH_THRESHOLD/HolderPedIsDead findings already
    -- cite -- reads `pedGameState->curVehicleSeat ~= -1` directly off the
    -- entity's own synced state, never a client claim), so this is a real,
    -- server-authoritative check, not a client-attested one.
    --
    -- Config.Combat.ExcludeVehicleSeatedTargets (STALE-COMMENT FIX, this
    -- pass, coder-security cross-change regression review -- re-verified
    -- against the actual current config.lua before rewriting this
    -- paragraph, not taken on an earlier draft alone: this field HAS SINCE
    -- LANDED, `true` by default -- the "NOT YET LANDED" framing below is
    -- what went stale, not the underlying check). `~= false` means a
    -- missing/nil field (e.g. an older config.lua predating this field)
    -- still reads as the RECOMMENDED default (EXCLUDE a vehicle-seated
    -- target) -- an operator
    -- who wants the pre-fix behavior back (e.g. a server that deliberately
    -- wants K9 units to be able to drag a downed driver out of a car -- see
    -- this check's own placement relative to PropDragging's requireAlive =
    -- false path immediately above) can opt back in with an explicit
    -- `false`. Applied uniformly to BiteAndHold/NonLethalTakedown/
    -- PropDragging alike (same shared validator, same target-physical-state
    -- question for all three) -- flagged in this pass's own report as a
    -- product/design question for PropDragging specifically, since pulling
    -- an unconscious driver out of their seat is a plausible legitimate use
    -- case the shared default now blocks unless the operator opts out.
    local excludeVehicleSeatedTargets = Config.Combat.ExcludeVehicleSeatedTargets ~= false
    if excludeVehicleSeatedTargets and IsPedInAnyVehicle(targetPed, false) then
        return false, nil, nil, nil, nil, 'target_in_vehicle'
    end

    -- RED-TEAM FINDING 2, DELIBERATELY NOT FIXED (this pass, coder-security):
    -- the distance check immediately below is Euclidean-only -- there is no
    -- line-of-sight check anywhere in this file (confirmed: zero references
    -- to any raycast/shape-test native across every server/*.lua in this
    -- resource), so a K9 within `rangeMeters` on the far side of a thin
    -- wall or door can initiate a bite/takedown/drag exactly as if standing
    -- in the open.
    --
    -- VERIFIED, NOT ASSUMED, that no server-side fix is possible: checked
    -- citizen-server-impl's own ServerGameState_Scripting.cpp/
    -- ServerGameState.cpp (the same authoritative source this file's own
    -- PED_DEAD_HEALTH_THRESHOLD/IsPedInAnyVehicle findings already cite) --
    -- zero RegisterNativeHandler calls for any SHAPETEST/raycast/
    -- HAS_ENTITY_CLEAR_LOS_TO_ENTITY native anywhere in either file, or
    -- anywhere else this session's search reached. This is architectural,
    -- not a mere registration gap: FXServer does not load or simulate world
    -- collision geometry at all (no physics/rendering world exists
    -- server-side), so a raycast against level geometry is not merely
    -- unimplemented, it has nothing to query even if it were. (The
    -- `natives.json` `apiset` field this session was directed to fall back
    -- on turned out UNRELIABLE for this determination -- independently
    -- verified absent/None for the overwhelming majority of natives in that
    -- file regardless of real client/server status, INCLUDING
    -- GetEntityHealth/IsPedRagdoll/GetEntityCoords, all three already
    -- confirmed server-callable elsewhere in this exact file by the C++
    -- source directly; a 404 on `docs.fivem.net`'s natives reference is
    -- likewise uninformative on its own, matching this file's own existing
    -- SetEntityCanBeDamaged/SetEntityHealth findings above that the primary
    -- C++ registration list is the only conclusive source.)
    --
    -- DELIBERATELY NOT ADDING A CLIENT-ATTESTED LOS RESULT INSTEAD: a
    -- client-reported "I have LOS" boolean would be worthless against
    -- exactly the modified client this whole file defends against (it could
    -- simply always claim true) -- adding one and calling this fixed would
    -- be strictly worse than the honest gap, since it would look resolved
    -- in a future review while adding zero real protection. Not done.
    --
    -- FAILURE DIRECTION, CHOSEN DELIBERATELY: since no real check exists to
    -- run, there is nothing to fail open OR closed on here -- this is a
    -- disclosed absence, not a check that defaults permissively. The
    -- request proceeds on distance/access/wanted-status/etc. alone, exactly
    -- as before this pass.
    --
    -- WHAT A REAL FIX WOULD REQUIRE: the raycast must run on a client that
    -- actually has the world loaded. The only trustworthy shape is a
    -- SERVER-INITIATED, SERVER-INTERPRETED check that does not simply take
    -- the requesting K9's own word for it -- e.g. the server asks a THIRD
    -- PARTY (not the K9, not the target) client already near both
    -- positions to run the shape test and report the result, corroborated
    -- across multiple nearby witnesses before being trusted, the same
    -- "never trust the one client with an incentive to lie" posture
    -- RequireWantedStatus/IsPlayerWantedEligible already apply elsewhere in
    -- this file -- genuinely more work than this pass's scope, and only
    -- viable at all when a third witness happens to be nearby.
    --
    -- HONEST RESIDUAL RISK: a K9 can still initiate a bite/takedown/drag
    -- through a thin wall/door within `rangeMeters` (2.5-3.0m shipped). This
    -- is a real, unresolved gap in this pass, reported as such rather than
    -- silently accepted or papered over.
    --
    -- Live server-side proximity — NEVER a client-claimed distance.
    local dist = #(k9Pos - GetEntityCoords(targetPed))
    if dist > rangeMeters then
        return false, nil, nil, nil, nil, 'too_far'
    end

    if ActiveHolds[targetNetId] then
        return false, nil, nil, nil, nil, 'already_held'
    end

    -- Player-vs-NPC resolution — see this file's header for why this is
    -- ResolveConnectedPlayerFromPed, not IsPedAPlayer.
    local targetSrc = ResolveConnectedPlayerFromPed(targetPed)
    local isPlayerTarget = targetSrc ~= nil

    if isPlayerTarget and not IsPlayerWantedEligible(targetSrc) then
        return false, nil, nil, nil, nil, 'not_eligible_target'
    end


    -- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
    -- a PLAYER target already resting inside a kennel (attached to it,
    -- server-confirmed) or already mid-vehicle-seat-claim cannot ALSO be
    -- granted as a bite-hold/takedown/drag target at the same instant --
    -- the identical class of "two exclusive mechanics grant the same body
    -- at once" race this pass's own audit traced concretely for
    -- kennel-vs-vehicle, applied here to combat's own target side. NPC
    -- targets have no citizenid and therefore cannot participate in this
    -- registry at all -- `isPlayerTarget` gates this to the one case where
    -- a real citizenid exists to check. `already_held` (ActiveHolds' own
    -- netId-keyed check, above) already prevents a SECOND combat effect
    -- from targeting the same entity, so this is checking a DIFFERENT
    -- exclusive claim, not a redundant re-check of that one.
    if isPlayerTarget then
        local targetPlayer = exports.qbx_core:GetPlayer(targetSrc)
        local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
        if targetCitizenid and IsBodyClaimedByOther(targetCitizenid, 'combat_target') then
            return false, nil, nil, nil, nil, 'target_body_claimed'
        end
    end

    return true, k9Ped, targetPed, isPlayerTarget, targetSrc
end

--- Shared teardown for ALL THREE effect types — release, timeout, or
--- disconnect all funnel through here so there is exactly one place that
--- mutates ActiveHolds/K9ActiveEffect on the way out (mirrors
--- server/main.lua's own doDetachLeash "there is exactly one place that
--- mutates LeashPairs on detach" discipline).
---
--- RESTRUCTURED this pass (PropDragging addition): the relay-selection
--- logic below used to be an implicit two-way "'bite' vs. else(=takedown)"
--- branch — adding a third effectType on top of that binary would have
--- silently sent 'drag' down the 'takedown' relay paths (endForceRagdoll/
--- endNpcTakedown), which is wrong (dragging has its own, differently-shaped
--- event contract — see this file's header EVENT/CALLBACK CONTRACT). Made
--- explicit as a real three-way `if/elseif/else` instead, with each of the
--- three branches' behavior for 'bite'/'takedown' kept byte-for-byte
--- identical to before this restructure.
--- @param targetNetId number
--- @param reason string
local function EndHold(targetNetId, reason)
    local hold = ActiveHolds[targetNetId]
    if not hold then return end

    ActiveHolds[targetNetId] = nil
    if K9ActiveEffect[hold.holderSrc] == targetNetId then
        K9ActiveEffect[hold.holderSrc] = nil
    end

    -- EXCLUSIVE BODY-CLAIM REGISTRY release (server/bodyclaims.lua, this
    -- pass) -- mirrors the ClaimBody call at each of this file's three
    -- grant sites (requestBiteHold/HandleTakedownRequest/requestDrag). EndHold
    -- is THE single choke point every termination path (manual release,
    -- timeout, target/holder disconnect, target/holder death) already
    -- funnels through -- releasing here, once, covers all of them without
    -- duplicating this call at every one of those call sites. `hold.targetCitizenid`
    -- is nil for an NPC target (never claimed anything here to begin with)
    -- or a player target whose citizenid could not be resolved at grant
    -- time, both harmless no-ops for ReleaseBody.
    if hold.targetCitizenid then
        ReleaseBody(hold.targetCitizenid, 'combat_target')
    end

    if hold.effectType == 'bite' then
        if hold.isPlayerTarget then
            -- Category B teardown relay -- best-effort, same posture as the
            -- apply side (DEVELOPER_REFERENCE.md §12.0 item 8). If the target's
            -- client ignored the apply event in the first place, it will
            -- almost certainly ignore this one too — that is an accepted,
            -- disclosed limitation (item 8's own guardrail 3 is exactly why
            -- nothing server-authoritative depends on this succeeding).
            TriggerClientEvent('qbx_k9unit:client:endBiteHold', hold.targetSrc, reason)
        else
            -- NPC target — RESTRUCTURED, native-api-assistant verification
            -- pass (an earlier session): see this file's header "NPC-TARGET
            -- NATIVE EXECUTION CONTEXT" note for the full finding. Relayed
            -- to the REQUESTING K9's OWN client (client/combat.lua), same
            -- as the apply side — never called directly server-side.
            TriggerClientEvent('qbx_k9unit:client:endNpcBiteHold', hold.holderSrc, targetNetId, reason)
        end

        TriggerClientEvent('qbx_k9unit:client:biteHoldEnded', hold.holderSrc, targetNetId, reason)

        -- Config.XP.awards.biteHoldSuccess (config.lua) — QA-flagged as dead
        -- code (configured, never granted) until an earlier pass.
        -- "Genuinely successful" is deliberately narrower than "a hold
        -- merely existed": excludes 'holder_disconnected'/
        -- 'target_disconnected' (incomplete, not an intentional outcome)
        -- outright, and further requires MIN_BITE_HOLD_XP_DURATION_MS to
        -- have elapsed for a 'released' end (never for 'timeout', which
        -- cannot fire early — see that constant's own declaration comment
        -- for the full anti-farm reasoning). Runtime existence guard, same
        -- convention as server/tracking.lua's own trackSourceResolved call
        -- site — no load-order assumption on server/progression.lua.
        if reason == 'released' or reason == 'timeout' then
            local heldDurationMs = GetGameTimer() - hold.startedAt
            if reason == 'timeout' or heldDurationMs >= MIN_BITE_HOLD_XP_DURATION_MS then
                -- SEVENTH XP-FARM FIX (this pass) -- see
                -- BiteHoldXpMintCooldown's own declaration comment above for
                -- the full writeup. Gates ONLY this AwardXP call, checked
                -- LAST (after the reason exclusion and the duration floor
                -- above), so a hold that was never going to pay out anyway
                -- never burns this per-holder mint budget for nothing.
                -- Everything else in this branch (both relay
                -- TriggerClientEvent calls above, ActiveHolds/K9ActiveEffect
                -- already having been cleared at the top of EndHold) is
                -- entirely unaffected by whether this Consume succeeds -- a
                -- K9 out of mint budget still gets its hold/release/relay
                -- exactly as before, it just is not paid for this one.
                --
                -- EIGHTH XP-FARM FIX, NPC-ELIGIBILITY HALF (this pass,
                -- red-team-flagged compounding factor -- server/progression.lua
                -- owns the OTHER half, the shared cross-mechanic budget):
                -- ValidateCombatRequest's NPC branch (this file, above) never
                -- calls IsPlayerWantedEligible at all -- Config.Combat.
                -- RequireWantedStatus's own comment already documents that
                -- field as NOT affecting NPC targets. An ambient, non-wanted,
                -- non-dangerous NPC pedestrian was therefore a fully
                -- qualifying biteHoldSuccess source requiring zero real
                -- police work. Config.XP.mintXpForNpcCombatTargets
                -- (config.lua; boolean; default false/unset) gates the MINT
                -- ONLY -- it does NOT gate whether NPC bite-hold itself is
                -- ALLOWED (Config.Features.BiteAndHold, unaffected; the
                -- owner's standing decision that K9 combat targets players
                -- AND NPCs is not re-litigated here). Checked FIRST in this
                -- `and` chain, before BiteHoldXpMintCooldown.Consume, for the
                -- same "never burn the mint budget on something that was
                -- never going to pay anyway" reasoning this comment already
                -- states for the duration floor above it -- a K9 that only
                -- ever engages ineligible NPCs must not find its OWN mint
                -- budget spent when a genuinely eligible target later comes
                -- along. `Config.XP and ...` guards a fixture/test sandbox
                -- that never sets up Config.XP at all; production's real
                -- config.lua always defines Config.XP, so this is a pure
                -- defensive no-op there. `nil == true` is false in Lua, so
                -- this already defaults to the recommended "off" behavior
                -- even before config.lua adds the key.
                if (hold.isPlayerTarget or (Config.XP and Config.XP.mintXpForNpcCombatTargets == true))
                    and type(AwardXP) == 'function'
                    and BiteHoldXpMintCooldown.Consume(hold.holderSrc, BITE_HOLD_XP_MINT_COOLDOWN_MS) then
                    local holderPlayer = exports.qbx_core:GetPlayer(hold.holderSrc)
                    local holderCitizenid = holderPlayer and holderPlayer.PlayerData and holderPlayer.PlayerData.citizenid
                    if holderCitizenid then
                        AwardXP(holderCitizenid, 'biteHoldSuccess')
                    end
                end
            end
        end
    elseif hold.effectType == 'takedown' then
        if hold.isPlayerTarget then
            TriggerClientEvent('qbx_k9unit:client:endForceRagdoll', hold.targetSrc, reason)
        else
            TriggerClientEvent('qbx_k9unit:client:endNpcTakedown', hold.holderSrc, targetNetId, reason)
        end

        -- CANCEL-PATH FIX (this pass) — sent unconditionally, every reason,
        -- mirroring biteHoldEnded/dragEnded immediately above/below: this is
        -- what clears the holder's own client-side "am I engaged" state
        -- (MyEngagedTakedownTargetNetId/IsTakedownEngaged(), client/combat.lua)
        -- for EVERY end reason, not only a manual release.
        TriggerClientEvent('qbx_k9unit:client:takedownEnded', hold.holderSrc, targetNetId, reason)

        -- CANCEL-PATH FIX (this pass): takedown NOW has a manual "release"
        -- action too (releaseTakedown below, mirroring releaseBiteHold) —
        -- 'released_by_holder' is EXCLUDED from this notify for the exact
        -- same reason drag_ended already excludes its own two manual-release
        -- reasons (see the 'drag' branch below): a manual release is
        -- self-evident to the actor who just pressed the button/keybind —
        -- announcing it back to them would be a redundant, not a new, signal.
        -- Every OTHER non-timeout reason (target disconnecting mid-ragdoll,
        -- holder_died via EndActiveEffectForHolder's own 'recalled' path,
        -- etc.) still gets the existing "ended early" notify, unchanged.
        if reason ~= 'timeout' and reason ~= 'released_by_holder' then
            NotifyPlayer(hold.holderSrc, locale('combat.takedown_ended_early'), 'inform')
        end
    else -- 'drag' (DEVELOPER_REFERENCE.md §12.5.4, this pass)
        -- Category A (attach) teardown ALWAYS goes to the HOLDING K9's own
        -- client regardless of target kind — that client is the one
        -- actually calling AttachEntityToEntity/DetachEntity, §12.0 item 8's
        -- new finding on DetachEntity's own lack of an ownership gate. The
        -- Category B speed-limit half ADDITIONALLY goes to the target's own
        -- client, but ONLY when that target is a player — an NPC's move
        -- rate is reset by this SAME dragEnded handler on the K9's own
        -- client instead (see client/combat.lua's own header) — there is no
        -- separate "NPC drag speed" relay event, unlike bite/takedown's own
        -- applyNpc*/endNpc* pair, because the K9's client already receives
        -- everything it needs via dragStarted's own isPlayerTarget field.
        TriggerClientEvent('qbx_k9unit:client:dragEnded', hold.holderSrc, targetNetId, reason)
        if hold.isPlayerTarget then
            TriggerClientEvent('qbx_k9unit:client:endDragSpeedLimit', hold.targetSrc, reason)
        end

        if reason ~= 'released_by_holder' and reason ~= 'released_by_target' then
            -- Only notify for a NON-manual end (timeout/disconnect/the
            -- maxDragDistance safety valve) -- a manual release from either
            -- side is self-evident to that side already (the
            -- button/keybind press itself is the feedback), mirroring
            -- takedown's own "only notify for a non-expected end" posture
            -- above.
            NotifyPlayer(hold.holderSrc, locale('combat.drag_ended'), 'inform')
        end
    end
end

--- Resource-global (no `local`) accessor exposed for OTHER files that need
--- to unconditionally end whatever engagement (bite/takedown/drag) a K9 is
--- CURRENTLY the HOLDER of, regardless of who is asking or that K9's own
--- current certification/access state. Its callers today are the
--- decertification and permission-revocation cleanup paths
--- (server/certifications/core.lua, server/permissions.lua) -- each
--- resolved through the SAME `type(...) == 'function'`
--- runtime-existence-guard convention this file already uses for AwardXP
--- (see FILE-TO-FILE CONTRACT above), never a load-order assumption, since
--- a caller's own position in fxmanifest.lua's server_scripts relative to
--- THIS file is not, and should not need to be, load-bearing.
---
--- DELIBERATELY NEVER CHECKS HasK9Access/Config.Features.* ITSELF -- this is
--- a TERMINATION path, and DEVELOPER_REFERENCE.md's own "no unbounded trap"
--- guarantee (§12.0 item 4, restated for Recall specifically at §12.5.1)
--- requires that a K9 whose certification is revoked, or whose feature flag
--- is toggled off, mid-engagement can still be called off; gating this
--- function on either would reintroduce exactly the trap that guarantee
--- forbids. Each caller is responsible for its OWN authorization --
--- this function's own
--- contract is narrower and unconditional: "does this holder have an active
--- engagement, and if so, end it," nothing more.
---
--- pcall-wrapped internally (mirrors this file's own shared-maintenance-
--- thread precedent for EndHold above) so an unexpected error inside
--- EndHold/AwardXP/a TriggerClientEvent argument can never propagate into an
--- unrelated caller's own event handler and abort IT for a reason that has
--- nothing to do with that caller's own logic.
--- @param holderSrc number
--- @return boolean ended -- false if `holderSrc` has no active engagement (a genuine no-op, not an error)
function EndActiveEffectForHolder(holderSrc)
    local targetNetId = K9ActiveEffect[holderSrc]
    if not targetNetId then return false end

    local ok, err = pcall(EndHold, targetNetId, 'recalled')
    if not ok then
        print(('[qbx_k9unit] EndActiveEffectForHolder(recalled) errored for holderSrc %s, targetNetId %s: %s'):format(holderSrc, targetNetId, tostring(err)))
        return false
    end
    return true
end

--- How many currently-open ActiveHolds entries have exactly this
--- `effectType` right now -- exposed as a plain global function (this
--- resource's established "global helper, private per-file state"
--- convention, same shape as EndActiveEffectForHolder directly above) for
--- server/runtimecontrol.lua's own active-usage confirmation gate (see
--- that file's "ACTIVE-USAGE CONFIRMATION FEATURES" section): a real,
--- live headcount of "how many players are mid-bite-and-hold/takedown/
--- drag right now", read fresh on every call, never cached. A READ-ONLY
--- accessor -- never mutates ActiveHolds, never ends or affects a hold,
--- exactly like GetActivePartnerCitizenId/IsActivePartnerOf's own
--- read-only role in server/partnership.lua for a different registry.
--- @param effectType 'bite'|'takedown'|'drag'
--- @return integer count
function CountActiveHoldsByEffectType(effectType)
    local count = 0
    for _, hold in pairs(ActiveHolds) do
        if hold.effectType == effectType then
            count = count + 1
        end
    end
    return count
end

--- Is `holderSrc` currently the active holder of ANY combat effect -- a bite
--- hold, a non-lethal takedown, or a drag?
---
--- Read-only over this file's own K9ActiveEffect table. Never mutates
--- ActiveHolds or K9ActiveEffect, same posture as
--- CountActiveHoldsByEffectType immediately above.
---
--- WHY IT EXISTS. server/search.lua needs to refuse a search from a dog that
--- is already holding somebody, and until now the only thing that refused it
--- ran on the player's own machine (client/search.lua's
--- IsBusyWithSomethingElse), which a modified game simply does not run. The
--- server had no way to ask the question at all.
---
--- ALL THREE EFFECTS, deliberately, not just bite and drag. K9ActiveEffect
--- already enforces "one hold at a time per K9" across all three by design,
--- so answering for a subset would need extra iteration over ActiveHolds for
--- no benefit, and would arbitrarily exempt takedown -- a dog mid-takedown
--- is exactly as occupied as a dog mid-bite.
---
--- Three inputs, two answers: a holder is true; a non-holder is false; an
--- unknown or never-seen src is false. There is no third state to get wrong,
--- because K9ActiveEffect[src] is simply nil in both of the latter cases.
---
--- @param holderSrc number
--- @return boolean
function IsK9CurrentlyHolding(holderSrc)
    return K9ActiveEffect[holderSrc] ~= nil
end

--- Which effectType (if any) `holderSrc` is CURRENTLY the active holder of
--- -- 'bite' | 'takedown' | 'drag' | nil. Read-only, same posture as
--- IsK9CurrentlyHolding/CountActiveHoldsByEffectType immediately above --
--- never mutates ActiveHolds or K9ActiveEffect.
---
--- WHY THIS EXISTS (this pass, kennel-vs-vehicle-seat race fix): a HOLDER's
--- own busy-state is already fully answered by IsK9CurrentlyHolding above
--- for a plain yes/no, but server/vehicle.lua's requestVehicleSeatClaim
--- needs to pick BETWEEN two already-shipped, effect-specific rejection
--- messages (locale('vehicle.blocked_by_bite_hold') vs.
--- locale('vehicle.blocked_by_drag'), both pre-existing keys
--- client/vehicle.lua's own — previously CLIENT-only, therefore racy —
--- guard already used) rather than one generic one. Exposing the effectType
--- itself here lets that file choose accurately without reaching into
--- ActiveHolds/K9ActiveEffect directly, the same "read a small accessor,
--- never the other file's private table" discipline this resource's
--- cross-file contracts already establish everywhere else.
--- @param holderSrc number
--- @return string? effectType
function GetActiveHoldEffectTypeForHolder(holderSrc)
    local targetNetId = K9ActiveEffect[holderSrc]
    if not targetNetId then return nil end
    local hold = ActiveHolds[targetNetId]
    return hold and hold.effectType or nil
end

--- LIFECYCLE QA FIX (this pass) — closes the gap a lifecycle QA pass found:
--- when the K9 HOLDER dies mid-hold or mid-drag while remaining connected
--- (the DISCONNECT case is already handled correctly by playerDropped
--- below, via 'holder_disconnected'), nothing previously noticed. Before
--- this pass, the shared maintenance thread below checked hold.expiresAt,
--- target resolvability, and (for drags) DragExceedsMaxDistance — never the
--- HOLDER's own health — so a target stayed flee-suppressed/damage-immune/
--- move-rate-limited (or, for a drag, physically attached to a corpse)
--- until that hold's own hard timeout. Mirrors
--- 'qbx_k9unit:server:reportBiteHoldTargetDied' above EXACTLY, just for the
--- HOLDER's own death instead of a (player) TARGET's — client/combat.lua's
--- ActiveDragAsHolder/ActiveNpcEffects per-tick blocks self-report here the
--- instant THAT client observes its own ped has died. This report is a
--- FASTER-PATH optimization only, not the only closer of the gap — see
--- HolderPedIsDead's own doc comment (near DragExceedsMaxDistance above)
--- for the ALWAYS-ON backstop half that does not depend on this event ever
--- arriving at all (a bite-hold/takedown on a PLAYER target has no
--- client-side holder state to self-report from in the first place).
---
--- TRUST BOUNDARY, not a convenience event — same two-part discipline as
--- reportBiteHoldTargetDied above, mirrored exactly rather than
--- reinvented:
---   1. `source` must currently be the HOLDER of an active hold of ANY
---      effectType — resolved via K9ActiveEffect[src], the SAME O(1)
---      lookup releaseBiteHold/releaseDrag already use to resolve their own
---      caller's target, never a client-supplied targetNetId. A source that
---      is not genuinely the holder of anything is a silent no-op.
---   2. The claim itself ("I died") is independently RE-VERIFIED against
---      this player's own live server-side ped via the same
---      GetEntityHealth <= PED_DEAD_HEALTH_THRESHOLD check
---      reportBiteHoldTargetDied and ValidateCombatRequest already use —
---      never trusted alone.
--- THIS IS A TERMINATION PATH (DEVELOPER_REFERENCE.md §12.0 item 4's "no unbounded
--- trap" guarantee, restated for EndActiveEffectForHolder immediately
--- above): it must never be gated on HasK9Access/Config.Features.*/a
--- cooldown/mutex/any check that can fail closed, same discipline
--- EndActiveEffectForHolder's own doc comment already establishes for
--- Recall. The two checks above are read-only facts about server-held
--- state, neither of which can ever "deny" a genuine claim the way an
--- access/cooldown check could strand one — a holder who is not actually
--- dead simply gets a no-op, never a rejection.
--- Even a successful lie has a low ceiling regardless: the worst outcome of
--- a false report is ending a hold `source` is already the HOLDER of —
--- something releaseBiteHold/releaseDrag/EndActiveEffectForHolder already
--- let this same holder do unconditionally (or near-unconditionally)
--- anyway, not a capability escalation against anyone else.
---
--- AWARD-FARM CHECK (explicitly verified, not assumed): EndHold's own
--- BiteAndHold XP-award branch only pays out for reason == 'released' or
--- 'timeout' — 'holder_died' (used below) is neither, so this termination
--- path can never mint biteHoldSuccess XP, the same exclusion
--- 'target_died' already relies on for the sibling report above.
RegisterNetEvent('qbx_k9unit:server:reportHolderDied', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if not targetNetId then return end -- src is not currently the holder of anything -- ignore

    local holderPed = GetPlayerPed(src)
    if holderPed == 0 or GetEntityHealth(holderPed) > PED_DEAD_HEALTH_THRESHOLD then
        return -- claim does not match this player's own live server-side state -- ignore, never trust the claim alone
    end

    EndHold(targetNetId, 'holder_died')
end)

--[[ ================= NON-COMPLIANCE DETECTION ================= ]]

--- ACE->JOB-RANK REWRITE (this pass, project-owner-directed, mirroring
--- server/admin.lua's IsAuthorizedAdmin -- same shape, deliberately not
--- reinvented): the notify_staff fan-out below used to gate on
--- `IsPlayerAceAllowed(tostring(playerId), 'command')`. Config.AdminAudit.
--- AcePermission is now dead config (removed from config.lua per that
--- file's own admin-audit ACE->job-rank pass), and this call site was a
--- second, independent ACE check this file still owned on top of it.
---
--- Same Config.Departments[job.name] membership requirement, same
--- job.isboss short-circuit, same explicit `type(job.grade.level) ==
--- 'number'` guard before ever comparing it, as IsAuthorizedAdmin -- applied
--- against a NEW, SEPARATE threshold, Config.Departments[job.name].
--- nonComplianceAlertGrade, deliberately NOT Config.Departments[job.name].
--- auditGrade. These two concerns are not the same principal: auditGrade
--- gates the k9_search_log/k9_progression AUDIT TRAIL (who searched whom,
--- and when) -- a genuine privacy boundary, appropriately set to a senior
--- rank. A non-compliance alert carries no citizen-identifying search
--- history at all (`targetLabel` below is only ever a raw player source
--- number or NPC netId, never a citizenid or search result) and is
--- operational, real-time situational awareness about a K9 UNIT's own
--- conduct during an active bite-hold/takedown/drag -- closer in kind to a
--- dispatch/BOLO broadcast than to pulling someone's audit history. Reusing
--- auditGrade would gate it behind the SAME high bar as full audit-log
--- access for no privacy reason, and would mean on-duty officers below that
--- rank never see a live "this K9 interaction might not be compliant"
--- signal that could matter in the moment. Recommended (to whoever owns
--- config.lua -- not added here): Config.Departments[job].
--- nonComplianceAlertGrade, a new NUMBER field per department, same
--- semantics as auditGrade/certifierGrade (job.isboss always qualifies;
--- otherwise job.grade.level >= this value). Suggested default: 0 (any
--- sworn member of a configured department sees these -- operational, not
--- privacy-sensitive, per the reasoning above); raise it per-department if
--- a server wants this restricted to supervisors instead. This is a product
--- call, disclosed rather than silently decided -- the operator may prefer
--- a higher default.
---
--- FAILS CLOSED on every path where a job cannot be fully resolved: no
--- Player, no PlayerData, no job, job.name not a configured department, no
--- dept.nonComplianceAlertGrade (or a non-number one), no job.grade, or a
--- non-number job.grade.level all return false -- none of them ever reach
--- the `>=` comparison, so none of them can throw. Matches IsAuthorizedAdmin
--- exactly on this point.
---
--- PERFORMANCE (coordinator-flagged, this pass): this resolves one
--- exports.qbx_core:GetPlayer(...) call per online player, same as the ACE
--- check it replaces did per online player (that one paid GetPlayers()
--- itself, unchanged here). NOT cached/memoized -- measured against how
--- often this loop can actually run before adding that complexity: every
--- FlagNonCompliance call site (SampleCompliance, below) guards on
--- `hold.compliance.flagged`, a single boolean set true on the FIRST
--- violation of ANY kind for a given hold and never reset -- so this
--- notify_staff loop fires AT MOST ONCE per ActiveHolds entry for its
--- entire lifetime, not once per sampling tick. A per-tick cost concern
--- does not apply; a cache would add real complexity (staleness on
--- job/grade change, eviction on disconnect) for a code path that already
--- cannot repeat for the same hold.
--- @param playerId number
--- @return boolean
local function IsAuthorizedForNonComplianceAlert(playerId)
    local player = exports.qbx_core:GetPlayer(playerId)
    if not player or not player.PlayerData then return false end

    local job = player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    if job.isboss then return true end

    -- HIGH COMMAND, for consistency with every other rank gate in this
    -- resource (owner's own instruction: "high command automatically get
    -- every permission every feature every k9 upgrade"). A permission audit
    -- found this was the ONE rank gate with no high-command branch, which
    -- made it quietly inconsistent with HasK9Access, IsEligibleCertifier and
    -- IsAuthorizedAdmin, all of which have one.
    --
    -- It is currently a difference that does not show: nonComplianceAlertGrade
    -- ships as 0, so every sworn member of a configured department already
    -- qualifies and high command comes in under the ordinary grade check
    -- below. It only bites an owner who raises that threshold above their own
    -- high-command grade -- at which point the officers most responsible for
    -- a pursuit would be the only ones not told it had gone wrong. Fixing it
    -- while it is invisible is cheaper than discovering it mid-shift.
    --
    -- Deliberately BEFORE the numeric grade check and AFTER isboss, matching
    -- the order the other three gates already use, so the reading order is
    -- the same wherever you look: boss, then rank, then the configured
    -- number.
    --
    -- Soft-guarded: server/highcommand.lua is a separate file and this
    -- resource's convention is to reach a cross-file global through a
    -- type check rather than assume load order.
    if type(IsHighCommand) == 'function' and IsHighCommand(playerId) then return true end

    local dept = Config.Departments[job.name]
    if type(dept.nonComplianceAlertGrade) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.nonComplianceAlertGrade
end

--- @param hold table -- an ActiveHolds entry
--- @param targetNetId number
--- @param kind string
--- @param detail string -- already human-formatted; see call sites
local function FlagNonCompliance(hold, targetNetId, kind, detail)
    local cfg = Config.Combat.NonComplianceDetection
    -- LOCALE FIX (locale-migration pass, coder-backend): was two `..`
    -- string-concatenated variants ('player source ' .. tostring(...) /
    -- 'NPC netId ' .. tostring(...)) — the exact "glue a literal prefix onto
    -- a dynamic value with `..`" shape this migration's own README already
    -- flagged and fixed four times elsewhere (this is the fifth). Fixed the
    -- same way: two independent, complete `%s`-templated locale keys
    -- selected by a plain if/else, not one template with a conditional
    -- prefix. This value is ALSO consumed by the print() line immediately
    -- below (console diagnostics, out of migration scope on its own) — that
    -- is fine and expected, same as client/bonetool.lua's own
    -- known_sweep console print consuming already-locale()-sourced text.
    local targetLabel = hold.isPlayerTarget
        and locale('combat.noncompliance_target_player', tostring(hold.targetSrc))
        or locale('combat.noncompliance_target_npc', tostring(targetNetId))

    -- 'log' is the BASELINE, always-on behavior -- 'log' cannot mean
    -- "don't log." This print is the forensic record regardless of
    -- `action`'s value.
    print(('[qbx_k9unit] NON-COMPLIANCE (detection-only, NEVER punitive) kind=%s effect=%s target=%s holderSrc=%s detail=%s')
        :format(kind, hold.effectType, targetLabel, tostring(hold.holderSrc), detail))

    if cfg.action == 'notify_staff' then
        local message = locale('combat.noncompliance_message', kind, targetLabel, detail)
        for _, playerIdStr in ipairs(GetPlayers()) do
            local playerId = tonumber(playerIdStr)
            if playerId and IsAuthorizedForNonComplianceAlert(playerId) then
                TriggerClientEvent('ox_lib:notify', playerId, {
                    title = locale('combat.noncompliance_notify_title'),
                    description = message,
                    type = 'warning',
                    duration = 8000,
                })
            end
        end
    end

    if type(cfg.OnViolationOverride) == 'function' then
        -- Independent, additive opt-in hook -- invoked regardless of
        -- `action`'s own value (see this file's header). pcall-wrapped:
        -- an error in a server owner's own override must never interrupt
        -- sampling for OTHER active holds in the same maintenance tick.
        local ok, err = pcall(cfg.OnViolationOverride, hold.targetSrc, hold.effectType, {
            kind = kind,
            detail = detail,
            targetNetId = targetNetId,
            isPlayerTarget = hold.isPlayerTarget,
        })
        if not ok then
            print(('[qbx_k9unit] Config.Combat.NonComplianceDetection.OnViolationOverride errored: %s'):format(tostring(err)))
        end
    end
end

--- One sampling pass for a single active hold. Never mutates ActiveHolds
--- itself beyond the hold's own `compliance` sub-record — see this file's
--- header for the full per-effect heuristic writeup.
--- @param targetNetId number
--- @param hold table
--- @param now number
local function SampleCompliance(targetNetId, hold, now)
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then return end -- DEFENSE IN DEPTH: the expiry thread's own resolvability check (RED-TEAM FINDING, see its own comment) ends an unresolvable hold on ITS OWN next tick, but this function now runs on a SEPARATE, independently-configurable sampling thread (positionSampleWindowMs) rather than sharing the expiry thread's tick — so a target can legitimately go unresolvable in the gap between the two threads' ticks. Silently returning here (never erroring) is the correct handling for that ordinary race, not just a "should not normally trigger" backstop.

    local cfg = Config.Combat.NonComplianceDetection
    local compliance = hold.compliance
    local currentPos = GetEntityCoords(targetPed)

    if hold.effectType == 'bite' then
        local dtSeconds = (now - compliance.lastTime) / 1000.0
        if dtSeconds > 0 then
            local observedSpeed = #(currentPos - compliance.lastPos) / dtSeconds
            local ceiling = cfg.biteHoldIdleCeiling + cfg.biteHoldSpeedTolerance
            if observedSpeed > ceiling then
                compliance.consecutiveViolations = compliance.consecutiveViolations + 1
            else
                compliance.consecutiveViolations = 0
            end

            if not compliance.flagged and compliance.consecutiveViolations >= cfg.biteHoldViolationSamples then
                compliance.flagged = true -- single-shot per hold -- do not re-flag every sample for the rest of the same window
                FlagNonCompliance(hold, targetNetId, 'bite_hold_movement',
                    ('observedSpeed=%.2fm/s ceiling=%.2fm/s consecutiveSamples=%d'):format(observedSpeed, ceiling, compliance.consecutiveViolations))
            end
        end
    elseif hold.effectType == 'takedown' then
        -- Net displacement from the ragdoll-open baseline, NOT a
        -- continuous speed check — see this file's header for why, and for
        -- the disclosed "heading consistency not implemented" narrowing.
        local netDisplacement = #(currentPos - compliance.baselinePos)
        if not compliance.flagged and netDisplacement > cfg.takedownNetDisplacementMeters then
            compliance.flagged = true
            FlagNonCompliance(hold, targetNetId, 'takedown_displacement',
                ('netDisplacement=%.2fm threshold=%.2fm'):format(netDisplacement, cfg.takedownNetDisplacementMeters))
        end
    else -- 'drag' (DEVELOPER_REFERENCE.md §12.5.4/§12.0 item 8, this pass)
        -- Only meaningful for a PLAYER target -- an NPC target has no "own
        -- client" to ignore the speed-limit relay in the first place (the
        -- K9's own already-trusted client directly commands the NPC's move
        -- rate every tick, same posture as bite/takedown's NPC branches) --
        -- so there is no hostile party to detect here, unlike bite/takedown
        -- above which sample BOTH target kinds uniformly (a pre-existing
        -- choice this pass does not relitigate). Compares the target's live
        -- position against the K9's OWN live position (never an absolute
        -- speed ceiling) -- DEVELOPER_REFERENCE.md §12.0 item 8's own framing:
        -- "regardless of cause (self-detach, a bypassed move-rate override,
        -- or the K9's own client failing to re-assert the attach)" — this
        -- single geometric check catches all three failure modes at once
        -- without needing to distinguish which one occurred.
        if hold.isPlayerTarget then
            local k9Ped = GetPlayerPed(hold.holderSrc)
            if k9Ped ~= 0 then
                local gap = #(currentPos - GetEntityCoords(k9Ped))
                if not compliance.flagged and gap > cfg.dragComplianceSlackMeters then
                    compliance.flagged = true
                    FlagNonCompliance(hold, targetNetId, 'drag_gap',
                        ('gap=%.2fm slack=%.2fm'):format(gap, cfg.dragComplianceSlackMeters))
                end
            end
        end
    end

    compliance.lastPos = currentPos
    compliance.lastTime = now
end

--- DEVELOPER_REFERENCE.md §12.0 item 4's "no unbounded trap" guarantee for
--- PropDragging specifically — item 4's own text names `maxDragDistance`
--- (not a duration) as this mechanic's analog of BiteAndHold/
--- NonLethalTakedown's hard `maxDurationMs`/ragdoll-window caps. ALWAYS
--- enforced (see the maintenance thread's own call site below — checked
--- unconditionally, never gated behind `NonComplianceDetection.enabled`,
--- exactly like the `hold.expiresAt` check it sits alongside) — distinct
--- from the drag_gap NON-PUNITIVE detection signal above, which is a
--- smaller, log-only slack meant to catch a likely-hostile target sooner;
--- this is the hard, always-on safety valve that actually ends the drag.
--- @param hold table
--- @param targetNetId number
--- @return boolean exceeded
local function DragExceedsMaxDistance(hold, targetNetId)
    local targetPed = ResolveNetworkEntity(targetNetId, 1)
    if not targetPed then return false end -- DEFENSE IN DEPTH ONLY, should not normally trigger: same "maintenance thread's own resolvability check already ends this hold first" reasoning as SampleCompliance's own identical guard above

    local k9Ped = GetPlayerPed(hold.holderSrc)
    if k9Ped == 0 then return false end -- holder already disconnected; the playerDropped handler tears this down independently

    local dist = #(GetEntityCoords(k9Ped) - GetEntityCoords(targetPed))
    return dist > Config.Combat.PropDragging.maxDragDistance
end

--- LIFECYCLE QA FIX (this pass): the shared maintenance thread below used to
--- check hold.expiresAt, target resolvability, and (for drags)
--- DragExceedsMaxDistance above -- but never the HOLDER's own health. If the
--- HOLDING K9 died mid-hold/mid-drag while remaining connected (never
--- disconnecting -- the DISCONNECT case is already handled correctly, see
--- playerDropped below), nothing noticed: the target stayed
--- flee-suppressed/damage-immune/move-rate-limited (or, for a drag,
--- physically attached to a corpse) until that hold's own hard timeout, up
--- to Config.Combat.BiteAndHold.maxDurationMs/
--- Config.Combat.NonLethalTakedown.ragdollDurationMs/
--- Config.Combat.PropDragging.maxDragDurationMs later -- bounded (never an
--- unbounded trap), but the effect visibly outlived its cause. This
--- function is the ALWAYS-ON backstop half of the fix (see the maintenance
--- thread's own call site below); 'qbx_k9unit:server:reportHolderDied'
--- above (near EndActiveEffectForHolder) is the faster, client-reported
--- half for the two cases (drag-as-holder, NPC-effect-as-holder) where the
--- holder's own client already tracks enough state to self-detect its own
--- death within a frame -- this function is what closes the gap
--- UNCONDITIONALLY even if that report is lost, never sent (a
--- bite-hold/takedown on a PLAYER target has no client-side holder state to
--- self-report from at all -- see reportHolderDied's own doc comment), or
--- sent by a hostile/frozen/crashed client that never runs its own
--- self-check.
---
--- Deliberately narrow, mirroring HolderPedIsDead's sibling
--- DragExceedsMaxDistance's own "holder already disconnected" early-return
--- immediately above: only reports a HOLDER who is genuinely still
--- connected (GetPlayerPed ~= 0) AND whose own live health has crossed
--- PED_DEAD_HEALTH_THRESHOLD. A DISCONNECTED holder is a different,
--- already-handled case (the playerDropped handler below ends the hold
--- immediately with 'holder_disconnected') -- this function deliberately
--- does not re-label that same, already-correct case with a different
--- reason string for what would otherwise only ever be a benign, momentary
--- race between the two (this thread's own tick landing in the brief
--- window before playerDropped fires for the same disconnect).
--- @param hold table -- an ActiveHolds entry
--- @return boolean dead
local function HolderPedIsDead(hold)
    local holderPed = GetPlayerPed(hold.holderSrc)
    return holderPed ~= 0 and GetEntityHealth(holderPed) <= PED_DEAD_HEALTH_THRESHOLD
end

-- Shared EXPIRY maintenance thread — see this file's header for why this
-- is ALWAYS running (expiry enforcement, job (a)) regardless of whether
-- detection sampling (job (b), its own separate thread below) is enabled.
-- A fixed interval, deliberately NOT derived from
-- Config.Combat.NonComplianceDetection.positionSampleWindowMs — expiry
-- (the "no unbounded trap" guarantee) must never be delayed by a large/
-- misconfigured detection-sampling interval.
local MAINTENANCE_INTERVAL_MS = 500

-- STATE-MACHINE FIX (this pass, coder-security) — RED-TEAM FINDING 3's own
-- IsPedInAnyVehicle check (ValidateCombatRequest, above) only ever runs at
-- REQUEST time. Nothing previously re-checked vehicle occupancy for an
-- ALREADY-ACTIVE hold/takedown/drag: a target who was on foot when a bite/
-- takedown/drag was granted, then got into (or was pulled into) a vehicle
-- mid-effect, kept the Category B effect running against them regardless —
-- for NonLethalTakedown specifically that means SetEntityCanBeDamaged(ped,
-- false) can keep a target briefly undamageable WHILE DRIVING AWAY, and for
-- BiteAndHold it means DisableControlAction(ATTACK) keeps firing against a
-- driver who is no longer the pedestrian this mechanic was granted against.
-- Bounded already by each effect's own hard expiresAt cap (never an
-- unbounded trap), but the effect outlives the physical situation it was
-- granted for, the same class of gap HolderPedIsDead/target-unresolvable
-- above already close for the holder-died/ped-replaced cases.
--
-- Read ONCE at thread-creation time, same "Config is read once at resource
-- start and never mutated at runtime" precedent this file's own sibling
-- comments already establish immediately below — never re-read Config
-- inside the loop. Uses the SAME flag ValidateCombatRequest's own
-- request-time check reads (`~= false` defaults to EXCLUDE), deliberately:
-- an operator who has explicitly opted OUT of vehicle exclusion (set this
-- `false`, e.g. specifically so PropDragging can pull a downed driver OUT
-- of a car — see ValidateCombatRequest's own comment on this exact
-- tension) gets a mid-hold check that can never fire either, matching their
-- own stated intent instead of silently re-imposing the exclusion they
-- turned off. Applied UNIFORMLY to all three effectTypes (bite/takedown/
-- drag) for the same reason: when this flag is at its default (true), a
-- vehicle-seated target should never be under an active Category B/A effect
-- at all, regardless of whether they were seated in a vehicle at grant time
-- or got into one afterward; when the operator has opted out, this check is
-- provably a no-op for every effectType (a drag against a target ALLOWED to
-- start vehicle-seated must not be immediately undone by the very state
-- that made it eligible).
local ExcludeVehicleSeatedTargetsMidHold = Config.Combat.ExcludeVehicleSeatedTargets ~= false

-- CONFIRMED LIVE-FLIP BUG, FIXED (this pass, coder-backend) — this thread
-- used to be wrapped in `if Config.Features.BiteAndHold or
-- Config.Features.NonLethalTakedown or Config.Features.PropDragging then
-- CreateThread(...) end`, a boot-time snapshot of those flags read exactly
-- once, at this file's own load time. The stated justification
-- ("ActiveHolds cannot receive an entry unless one of these is on, so with
-- all of them false the table is provably always empty, so not running
-- this thread is behaviorally identical to running it forever against an
-- empty table") was true only for as long as those flags stayed exactly
-- what they were at boot —
-- server/runtimecontrol.lua's own FEATURE_TIERS registry lists
-- BiteAndHold/NonLethalTakedown/PropDragging as `tier = 'live'`, and
-- ApplyFeatureOverride mutates Config.Features.* immediately and
-- unconditionally, so an operator booting with all four off and then
-- flipping ONE on live (high command, from the tablet, in one click) broke
-- the premise: requestBiteHold/HandleTakedownRequest/requestDrag each
-- re-check their OWN flag fresh via ValidateCombatRequest and would start
-- writing real entries into ActiveHolds, while THIS thread — the only place
-- any hold/takedown/drag is ever auto-ended by timeout, holder-death,
-- target-unresolvable, target-entered-vehicle, or
-- drag-max-distance-exceeded — would never have started, for the rest of
-- that server's uptime. A hold that can be created must always be
-- releasable; gating this thread's START on a boot-time flag snapshot let a
-- release path be permanently absent instead. This is a TERMINATION path
-- (DEVELOPER_REFERENCE.md §12.0 item 4's own "no unbounded trap"
-- guarantee) — this resource's own standing rule is to gate the START of a
-- thing, never the STOP, and this gate was on the stop.
--
-- FIXED by removing the wrapper entirely: this thread now always starts.
-- The "provably always empty" argument the old gate relied on still holds
-- exactly as before with all four flags off — pairs(ActiveHolds) on an
-- empty table is a single, immediate no-op, so an idle server pays for one
-- MAINTENANCE_INTERVAL_MS (500ms) Wait() per tick and nothing else, the
-- same "walk a provably-empty table for free rather than gate the START"
-- shape server/main.lua's own DoorScratchByDoorCooldown.StartSweep already
-- established for exactly this class of problem (see that call's own
-- PERFORMANCE AUDIT NOTE). Unlike the K9-POSITION-HISTORY thread below
-- (also fixed this pass, see its own comment), this loop's body has no work
-- to do at all when ActiveHolds is empty — it never iterates GetPlayers()
-- or any other always-populated collection — so unconditional start is the
-- right shape here specifically, not merely the convenient one.
CreateThread(function()
    while true do
        Wait(MAINTENANCE_INTERVAL_MS)
        local now = GetGameTimer()

        for targetNetId, hold in pairs(ActiveHolds) do
            if now >= hold.expiresAt then
                -- MEDIUM, QA-flagged this session: EndHold reaches AwardXP
                -- (guarded only by a `type(...) == 'function'` existence
                -- check, no pcall of its own) and TriggerClientEvent calls
                -- that could theoretically error on bad state — the
                -- compliance-sampling thread's own SampleCompliance call
                -- is already pcall-wrapped for exactly this reason; this
                -- call was not, despite both being shared, resource-wide
                -- maintenance coroutines. An uncaught
                -- error here would kill this thread PERMANENTLY (Lua
                -- coroutines/threads do not resume after an unhandled
                -- error), silently disabling expiry enforcement — the "no
                -- unbounded trap" guarantee itself — for every future hold/
                -- takedown/drag for the rest of the resource's uptime, and
                -- would wedge whatever ActiveHolds/K9ActiveEffect entries
                -- existed at that moment into a permanent already_held/
                -- already_engaged lockout with nothing left running to ever
                -- clear them. Mirrored here, not left asymmetric.
                local ok, err = pcall(EndHold, targetNetId, 'timeout')
                if not ok then
                    print(('[qbx_k9unit] combat EndHold(timeout) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            elseif HolderPedIsDead(hold) then
                -- LIFECYCLE QA FIX (this pass) — see HolderPedIsDead's
                -- own doc comment above for the full writeup: this is
                -- the ALWAYS-ON backstop half of the holder-death fix,
                -- never gated behind NonComplianceDetection.enabled or
                -- any other feature flag/access/cooldown check — this is
                -- a TERMINATION path (DEVELOPER_REFERENCE.md §12.0 item 4's own
                -- "no unbounded trap" guarantee, same discipline
                -- EndActiveEffectForHolder's own doc comment above
                -- already establishes for Recall) and must never be
                -- blockable. Catches the case within one
                -- MAINTENANCE_INTERVAL_MS tick (500ms) even if the
                -- client-reported 'qbx_k9unit:server:reportHolderDied'
                -- event is lost, never sent (a bite-hold/takedown on a
                -- PLAYER target has no client-side holder state to
                -- self-report from at all), or sent by a client that
                -- never runs its own self-check.
                local ok, err = pcall(EndHold, targetNetId, 'holder_died')
                if not ok then
                    print(('[qbx_k9unit] combat EndHold(holder_died) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            elseif not ResolveNetworkEntity(targetNetId, 1) then
                -- RED-TEAM FINDING (PropDragging), generalized to every
                -- effectType: DragExceedsMaxDistance below (this thread)
                -- and SampleCompliance (its own, separate compliance-
                -- sampling thread) both used to bail out silently the
                -- moment their own internal ResolveNetworkEntity(targetNetId, 1)
                -- call returned nil, on the stated assumption that "the
                -- maintenance loop's own expiry/disconnect cleanup handles
                -- teardown" — but the ONLY disconnect cleanup that exists
                -- (the playerDropped handler below) fires on a full
                -- disconnect, never on ped destruction/recreation without
                -- one. If a held/dragged player's ped is destroyed and
                -- replaced with a new network id without disconnecting
                -- (e.g. some ambulance/revive flows), the OLD targetNetId
                -- becomes permanently unresolvable, silently skipped by
                -- both checks forever — leaving nothing but the hard
                -- `hold.expiresAt` timeout above to ever clear it, up to
                -- Config.Combat.BiteAndHold.maxDurationMs/
                -- Config.Combat.PropDragging.maxDragDurationMs later. This
                -- check catches that gap directly, for every effectType at
                -- once (bite/takedown/drag, player or NPC target alike) —
                -- a target that has become permanently unresolvable is
                -- ended immediately rather than left to the hard timeout,
                -- the same class of fix as this file's own
                -- reportBiteHoldTargetDied handler above (a target that
                -- "went away without disconnecting"), applied generically
                -- here instead of only for the client-reported-death case.
                -- Server-side ResolveNetworkEntity reflects real global
                -- entity existence (not "streamed to a particular client"),
                -- so a nil result for an ALREADY-successfully-resolved
                -- hold's target is a strong, not a transient, signal.
                local ok, err = pcall(EndHold, targetNetId, 'target_unresolvable')
                if not ok then
                    print(('[qbx_k9unit] combat EndHold(target_unresolvable) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            elseif ExcludeVehicleSeatedTargetsMidHold and IsPedInAnyVehicle(ResolveNetworkEntity(targetNetId, 1), false) then
                -- STATE-MACHINE FIX (this pass) — see
                -- ExcludeVehicleSeatedTargetsMidHold's own declaration
                -- comment above for the full writeup. targetNetId is
                -- guaranteed resolvable here (the elseif immediately
                -- above already ended this hold this same tick if it
                -- were not) — re-resolving costs one extra native call,
                -- matching this thread's own existing style of each
                -- branch resolving its own entity independently rather
                -- than threading a shared local through the whole
                -- if/elseif chain (see DragExceedsMaxDistance's own
                -- identical independent resolve immediately below).
                -- TERMINATION path — never gated on HasK9Access/
                -- Config.Features.*/a cooldown/mutex, same discipline
                -- HolderPedIsDead above already establishes.
                local ok, err = pcall(EndHold, targetNetId, 'target_entered_vehicle')
                if not ok then
                    print(('[qbx_k9unit] combat EndHold(target_entered_vehicle) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            elseif hold.effectType == 'drag' and DragExceedsMaxDistance(hold, targetNetId) then
                local ok, err = pcall(EndHold, targetNetId, 'max_distance_exceeded')
                if not ok then
                    print(('[qbx_k9unit] combat EndHold(max_distance_exceeded) errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            end
        end
    end
end)

-- Shared COMPLIANCE-SAMPLING thread — job (b) from this file's header,
-- deliberately a SEPARATE thread from the expiry thread above rather than
-- a branch sharing its tick, on its own Config.Combat.NonComplianceDetection.
-- positionSampleWindowMs interval (this field's own doc comment in
-- config.lua already called it "the shared sampling thread", i.e. its own
-- thread, distinct from expiry — this wires that up for real). Sampling is
-- non-punitive and log-only (see FlagNonCompliance/this file's header), so
-- decoupling its cadence from the hard expiry/max-distance safety valves
-- above is safe: nothing here ever ends a hold or mutates authoritative
-- state, it only ever writes to a hold's own `compliance` sub-record.
-- Started only when NonComplianceDetection.enabled — Config is read once
-- at resource start and never mutated at runtime, so gating thread
-- creation itself (rather than looping forever just to no-op every tick)
-- costs nothing.
--
-- POLL-INTERVAL VALIDATION (audit follow-up, same shape another file's
-- own pollIntervalMs fix just addressed there, see that file's own comment
-- and server/cooldowns.lua's header ADDENDUM): positionSampleWindowMs feeds
-- a bare `Wait()` directly, never NewCooldown/ResolveConfiguredThresholdMs,
-- so it was validated by neither of this file's other backstops. A
-- non-numeric/non-positive value here would throw inside `Wait()` on this
-- thread's very first iteration, killing THIS thread permanently (Lua
-- coroutines do not resume after an unhandled error) and silently
-- disabling non-compliance sampling for the rest of the resource's
-- uptime — quieter than the expiry-thread failure modes above only because
-- this feature is itself "non-punitive and log-only," never because a
-- config typo here is somehow safe. Resolved the same way, not with a hard
-- `assert` — an `error()` thrown from this file's own top-level chunk (this
-- `if` block runs at file-load time) would abort server/combat.lua's own
-- load from this line onward, taking EndActiveEffectForHolder and every
-- BiteAndHold/NonLethalTakedown/PropDragging event down with it, exactly
-- the failure cooldowns.lua's header ADDENDUM used THIS file as its own
-- worked example of. Same fallback (500ms) as config.lua's own shipped
-- default for this field.
local PositionSampleWindowMs = ResolveConfiguredThresholdMs(
    Config.Combat.NonComplianceDetection.positionSampleWindowMs, 500, 'Config.Combat.NonComplianceDetection.positionSampleWindowMs')

if Config.Combat.NonComplianceDetection.enabled then
    CreateThread(function()
        while true do
            Wait(PositionSampleWindowMs)
            local now = GetGameTimer()

            for targetNetId, hold in pairs(ActiveHolds) do
                -- pcall-wrapped for the same reason as every other call
                -- site in this shared coroutine's siblings: an error
                -- sampling ONE hold must never stop sampling for every
                -- OTHER active hold on this same tick, nor kill this
                -- thread permanently for the rest of the resource's
                -- uptime (Lua coroutines do not resume after an
                -- unhandled error).
                local ok, err = pcall(SampleCompliance, targetNetId, hold, now)
                if not ok then
                    print(('[qbx_k9unit] combat compliance sampling errored for netId %s: %s'):format(targetNetId, tostring(err)))
                end
            end
        end
    end)
end

-- Shared K9 POSITION-HISTORY sampling thread -- RED-TEAM FINDING 1 FIX (this
-- pass, coder-security). See K9PositionHistory's own declaration comment
-- (near ActiveHolds/K9ActiveEffect above) for the full writeup; this is the
-- independent, request-timing-decoupled sampling half of that fix.
-- Deliberately its OWN thread rather than folded into either thread above:
-- job (a) (expiry) iterates ActiveHolds and must never be delayed; job (b)
-- (compliance sampling) also iterates ActiveHolds and is gated behind
-- NonComplianceDetection.enabled; THIS job iterates every ONLINE PLAYER
-- (GetPlayers(), same source this file's own notify_staff fan-out already
-- scans) regardless of whether any hold is currently active at all -- a K9
-- position history must already exist BEFORE that K9's first request, not
-- start only once ActiveHolds has an entry, or the very race this fix
-- exists to close would simply move to "the very first request after a
-- hold ends."
--
-- CONFIRMED LIVE-FLIP BUG, FIXED (this pass, coder-backend) -- this thread
-- used to be wrapped in `if Config.Features.BiteAndHold or
-- Config.Features.NonLethalTakedown or Config.Features.PropDragging then
-- CreateThread(...) end`, the same boot-time-snapshot shape as the expiry
-- thread's own gate above (now also fixed -- see that thread's own comment
-- for the full writeup of WHY a `tier = 'live'` flag makes a boot-time `if`
-- around a CreateThread unsafe). The consequence here is different from the
-- expiry thread's (this is not a termination path -- ValidateCombatRequest's
-- own teleport-plausibility check, above, FAILS OPEN on a missing
-- K9PositionHistory entry, so this never traps anyone), but it is the same
-- bug shape: an operator booting with BiteAndHold/NonLethalTakedown/
-- PropDragging all off, then flipping ONE on live, got a fully-live
-- requestBiteHold/HandleTakedownRequest/requestDrag (each re-checks its own
-- flag fresh) with a K9PositionHistory table that would stay permanently
-- empty for the rest of that server's uptime -- silently widening RED-TEAM
-- FINDING 1's own disclosed "at most once per fresh connection" residual gap
-- (see K9PositionHistory's own declaration comment) into "every single
-- request, forever," since a table that can never gain its first entry
-- fails open every time, not just once per reconnect.
--
-- NOT fixed the same way as the expiry thread (unconditional start, no
-- inner check): unlike ActiveHolds (provably empty with the three flags
-- off, so pairs() over it is free), this loop's body iterates GetPlayers()
-- -- NOT provably empty merely because the combat flags are off; a server
-- with real online players and BiteAndHold/NonLethalTakedown/PropDragging
-- permanently disabled would pay one GetPlayerPed+GetEntityCoords pair per
-- online player per K9_POSITION_SAMPLE_INTERVAL_MS (1s) tick forever, for a
-- table nothing would ever read -- real, non-free work on what should be an
-- idle server profile. So the thread itself now starts unconditionally
-- (matching the expiry thread's shape, and DoorScratchByDoorCooldown.
-- StartSweep's precedent), but the three-flag check moves INSIDE the loop
-- instead of disappearing -- read fresh every tick, exactly like
-- ValidateCombatRequest's own per-call flag reads, so a live flip takes
-- effect within at most one K9_POSITION_SAMPLE_INTERVAL_MS (1s), never
-- "not until this resource restarts." When all three are off, the tick
-- costs one Wait() and three cheap table-field reads -- no GetPlayers()
-- call, no per-player natives -- which is cheaper than the OLD gate's
-- "thread never exists at all" only in the sense that it is still
-- effectively free, not in any way that matters against this file's
-- per-tick budget.
CreateThread(function()
    while true do
        Wait(K9_POSITION_SAMPLE_INTERVAL_MS)

        if Config.Features.BiteAndHold or Config.Features.NonLethalTakedown or Config.Features.PropDragging then
            local now = GetGameTimer()

            -- No pcall needed per-iteration (unlike the two threads above):
            -- GetPlayerPed/GetEntityCoords are simple, non-throwing native
            -- reads with no user-supplied override/hook involved anywhere
            -- in this loop, the same posture the notify_staff fan-out this
            -- loop mirrors already takes for its own identical GetPlayers()
            -- scan.
            for _, playerIdStr in ipairs(GetPlayers()) do
                local playerId = tonumber(playerIdStr)
                if playerId then
                    local ped = GetPlayerPed(playerId)
                    if ped ~= 0 then
                        K9PositionHistory[playerId] = { pos = GetEntityCoords(ped), time = now }
                    end
                end
            end
        end
    end
end)

--[[ ================= BITE-AND-HOLD ================= ]]

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestBiteHold', function(targetNetId)
    local src = source

    local ok, k9Ped, targetPed, isPlayerTarget, targetSrc, reason =
        ValidateCombatRequest(src, targetNetId, Config.Features.BiteAndHold, Config.Combat.BiteAndHold.range, 'BiteAndHold')
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason, 'BiteAndHold'), 'error')
        return
    end

    -- XP-FARM FIX (this pass) -- BOTH cooldowns are CHECKED first (read-only,
    -- neither one stamped yet) before EITHER is consumed, same "cheapest
    -- checks first, mutation last" discipline this file's own
    -- ValidateCombatRequest doc comment already establishes, and the same
    -- shape HandleTakedownRequest below already uses for its own per-K9 +
    -- per-target cooldown pair. This matters here specifically because a
    -- request that is ultimately rejected for being on ONE of the two
    -- cooldowns must never consume the OTHER -- burning BiteHoldTargetCooldown
    -- (a per-TARGET cooldown) for a request that never actually happened
    -- would incorrectly penalize the NEXT K9 who tries this same target,
    -- and burning BiteHoldCooldown (per-K9) here for nothing would cost this
    -- K9 20s for a request that was never granted.
    --
    -- NO EXPLICIT thresholdMs ARGUMENT BELOW (this pass, QA sandbox repro --
    -- see server/cooldowns.lua's header ADDENDUM): this used to re-read
    -- Config.Combat.BiteAndHold.cooldownMs/targetCooldownMs RAW, directly
    -- from Config, as a per-call override -- completely redundant with (and,
    -- worse, silently SHADOWING) each tracker's own constructor default a
    -- few lines above, which is now the SAFE, ResolveConfiguredThresholdMs-
    -- resolved value. Since `local threshold = thresholdMs or
    -- defaultThresholdMs` treats a non-nil override as authoritative and 0
    -- is truthy in Lua, that raw re-read would have silently REOPENED this
    -- exact footgun at the one place that actually enforces it at runtime,
    -- even after the constructor-level fix: a misconfigured
    -- Config.Combat.BiteAndHold.cooldownMs = 0 would still have permanently
    -- fail-closed this ONE mechanic, ignoring the safe fallback the
    -- constructor already computed. Config.Combat.BiteAndHold.cooldownMs/
    -- targetCooldownMs are never mutated at runtime anywhere in this
    -- codebase (grep-verified), so omitting them here changes nothing for a
    -- valid config and gets the safe fallback for an invalid one, for free.
    if BiteHoldCooldown.IsOnCooldown(src)
        or BiteHoldTargetCooldown.IsOnCooldown(targetNetId) then
        -- The LONGER of the two waits -- telling the player about the one
        -- that expires first would have them try again and be refused by
        -- the other.
        local waitMs = math.max(BiteHoldCooldown.RemainingMs(src), BiteHoldTargetCooldown.RemainingMs(targetNetId))
        NotifyPlayer(src, CombatRejectMessage('on_cooldown', 'BiteAndHold', { remainingMs = waitMs }), 'error')
        return
    end

    BiteHoldCooldown.Touch(src)
    BiteHoldTargetCooldown.Touch(targetNetId)

    local now = GetGameTimer()
    local expiresAt = now + Config.Combat.BiteAndHold.maxDurationMs
    local k9NetId = NetworkGetNetworkIdFromEntity(k9Ped)

    -- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
    -- resolved HERE, once, while targetSrc is confirmed still connected
    -- (ValidateCombatRequest just re-verified it moments ago), and stored
    -- on the hold itself so EndHold can release the claim later without
    -- re-resolving a citizenid for a target who may have disconnected by
    -- then -- see EndHold's own release call for why.
    local targetCitizenid = nil
    if isPlayerTarget then
        local targetPlayer = exports.qbx_core:GetPlayer(targetSrc)
        targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    end

    ActiveHolds[targetNetId] = {
        effectType      = 'bite',
        holderSrc       = src,
        isPlayerTarget  = isPlayerTarget,
        targetSrc       = targetSrc,
        targetCitizenid = targetCitizenid,
        startedAt       = now,
        expiresAt       = expiresAt,
        compliance = {
            lastPos               = GetEntityCoords(targetPed),
            lastTime              = now,
            consecutiveViolations = 0,
            flagged               = false,
        },
    }
    K9ActiveEffect[src] = targetNetId

    if targetCitizenid then
        -- ttlMs = the hold's OWN remaining duration -- this claim can never
        -- outlive Config.Combat.BiteAndHold.maxDurationMs's own hard cap
        -- (DEVELOPER_REFERENCE.md §12.0 item 4), and EndHold's own release
        -- (below in this file) fires well before that TTL in the common
        -- case regardless.
        ClaimBody(targetCitizenid, 'combat_target', expiresAt - now, 'bite')
    end

    if isPlayerTarget then
        -- Category B relay -- DEVELOPER_REFERENCE.md §12.0 item 8. Sent ONLY to
        -- the target's own client, never a broadcast.
        TriggerClientEvent('qbx_k9unit:client:applyBiteHold', targetSrc, k9NetId, expiresAt)
    else
        -- NPC target — RESTRUCTURED, native-api-assistant verification
        -- pass (this session): see this file's header "NPC-TARGET NATIVE
        -- EXECUTION CONTEXT" note. DEVELOPER_REFERENCE.md §12.5.1's own prose calls
        -- this "no relay problem" on the theory the server can just call
        -- these natives directly — that theory did not survive
        -- verification (SetBlockingOfNonTemporaryEvents/SetPedFleeAttributes'
        -- SERVER-side validity could not be confirmed either way this
        -- session; the sibling SetEntityCanBeDamaged call in
        -- HandleTakedownRequest below WAS independently confirmed
        -- CLIENT-ONLY). Relayed to the REQUESTING K9's OWN client instead
        -- — that client is already this resource's trusted actor for this
        -- action (server has already independently verified
        -- access/proximity/cooldowns above; only the mechanical
        -- "make the NPC stop fleeing/reacting" step moves client-side),
        -- and is unambiguously a valid execution context for both natives
        -- regardless of their unresolved server-side status.
        TriggerClientEvent('qbx_k9unit:client:applyNpcBiteHold', src, targetNetId, expiresAt)
    end

    TriggerClientEvent('qbx_k9unit:client:biteHoldStarted', src, targetNetId, expiresAt)
    -- BEST-EFFORT WORDING (guardrail 4) -- never claims the target cannot
    -- escape.
    NotifyPlayer(src, locale('combat.bite_hold_attempted'), 'inform')
end)

RegisterNetEvent('qbx_k9unit:server:releaseBiteHold', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if not targetNetId then return end

    local hold = ActiveHolds[targetNetId]
    if not hold or hold.effectType ~= 'bite' or hold.holderSrc ~= src then return end

    EndHold(targetNetId, 'released')
end)

--- QA-fix completion: client/combat.lua's bite-hold TARGET death-detection
--- thread reports its own death here so the HOLDER's side gets freed
--- properly. Without this, the holder's MyEngagedTargetNetId/
--- IsBiteHoldEngaged() state (client/combat.lua) only ever clears on a
--- 'qbx_k9unit:client:biteHoldEnded' relay, which EndHold below only ever
--- sends when THIS file ends the hold — until now, nothing did that for a
--- target who died mid-hold, so the holder stayed stuck on the
--- already_engaged lockout for up to Config.Combat.BiteAndHold.maxDurationMs
--- (15s default). client/combat.lua's own death-detection thread already
--- clears the TARGET's own local restriction on death; this closes the
--- remaining HOLDER-side half of that same finding.
---
--- TRUST BOUNDARY, not a convenience event: `source` here is the CLAIMED
--- TARGET reporting its own death, and a modified client could fire this
--- unprompted at any time. Two independent checks gate it, not one:
---   1. `source` must currently be the (player) TARGET of an active 'bite'
---      hold — reverse-scans ActiveHolds by hold.targetSrc rather than
---      trusting a client-supplied targetNetId, the same "never trust a
---      client-claimed id, only ever act on server-held state" posture
---      every other handler in this file already applies. A source that
---      isn't genuinely the target of anything is a silent no-op.
---   2. The claim itself ("I died") is independently RE-VERIFIED against
---      this player's own live server-side ped via a GetEntityHealth <=
---      PED_DEAD_HEALTH_THRESHOLD check — a DELIBERATE choice to verify,
---      not the "can't verify, so don't pretend to" call this codebase
---      makes elsewhere for tracking's forged-trail risk. UPDATED, native-
---      sweep follow-up pass: this comment previously named IsEntityDead as
---      "the SAME native ValidateCombatRequest above already calls" and
---      framed that as reassurance that "a real, already-trusted
---      verification mechanism exists." That reassurance was backwards —
---      IsEntityDead has NO FXServer server implementation (see
---      PED_DEAD_HEALTH_THRESHOLD's own doc comment above for the primary-
---      source finding) and always silently returned false, so THIS
---      handler unconditionally rejected every claim, genuine or not, and
---      the holder-side fix this handler exists to provide never actually
---      worked. Both this site and ValidateCombatRequest now share the same
---      GetEntityHealth-based check instead — the "same mechanism, reused"
---      property this comment always intended is now actually true.
--- Even a successful lie has a low ceiling regardless: the worst outcome of
--- a false report is ending a hold `source` is already the target of —
--- something that player could otherwise only end by genuinely dying or
--- waiting out the timer, not a capability escalation against anyone else.
RegisterNetEvent('qbx_k9unit:server:reportBiteHoldTargetDied', function()
    local src = source

    local targetNetId = nil
    for netId, hold in pairs(ActiveHolds) do
        if hold.effectType == 'bite' and hold.isPlayerTarget and hold.targetSrc == src then
            targetNetId = netId
            break
        end
    end
    if not targetNetId then return end -- src is not the target of any active bite hold -- ignore

    -- NATIVE-AVAILABILITY FIX (found this pass, same native-sweep as
    -- PED_DEAD_HEALTH_THRESHOLD's own doc comment above): this handler's
    -- own doc comment above claims this re-verification is "not a new or
    -- unverified native here -- it is the SAME native ValidateCombatRequest
    -- above already calls" -- true, but that native (IsEntityDead) has NO
    -- FXServer server implementation and always returned false, meaning
    -- `not IsEntityDead(targetPed)` was always `true` and this handler
    -- UNCONDITIONALLY returned early on every single call, regardless of
    -- whether the claim was genuine. The holder-side stuck-lockout bug this
    -- handler exists to fix (see this handler's own doc comment above) was
    -- therefore NEVER actually fixed by this code path -- a target who
    -- genuinely died mid-hold could never get their holder released via
    -- this report, only ever via the maxDurationMs timeout. Rewritten to
    -- use GetEntityHealth against the same PED_DEAD_HEALTH_THRESHOLD as
    -- every other server-side "is this ped dead" check in this file.
    local targetPed = GetPlayerPed(src)
    if targetPed == 0 or GetEntityHealth(targetPed) > PED_DEAD_HEALTH_THRESHOLD then
        return -- claim does not match this player's own live server-side state -- ignore, never trust the claim alone
    end

    EndHold(targetNetId, 'target_died')
end)

--[[ ================= NON-LETHAL TAKEDOWN ================= ]]

--- Core takedown logic, wrapped in pcall by the event handler below
--- (mirrors server/search.lua's HandleSearchTarget/searchTarget split) so
--- an unexpected runtime error can never leave TakedownMutex held or
--- K9ActiveEffect/ActiveHolds in an inconsistent state.
--- @param src number
--- @param targetNetId any
local function HandleTakedownRequest(src, targetNetId)
    -- k9Ped/isPlayerTarget/targetSrc from THIS pre-yield call are
    -- deliberately discarded (`_`), same "unused-by-design, not
    -- unfinished" pattern already established at server/main.lua:701
    -- (`local ok, _, _, reason = CheckLeashEligibility(...)`) — everything
    -- except targetPed (needed for basePos below) and reason (needed for
    -- the early-return message) is RE-DERIVED from scratch by the second
    -- ValidateCombatRequest call after the yield below ("RE-VALIDATE
    -- EVERYTHING after the yield" — see that call site's own comment), so
    -- carrying the pre-yield k9Ped/isPlayerTarget/targetSrc forward would
    -- only invite an accidental use of a value that may already be stale by
    -- the time this function's second half runs.
    local ok, _, targetPed, _, _, reason =
        ValidateCombatRequest(src, targetNetId, Config.Features.NonLethalTakedown, Config.Combat.NonLethalTakedown.range, 'NonLethalTakedown')
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason, 'NonLethalTakedown'), 'error')
        return
    end

    -- Cooldowns CHECKED (not yet consumed) before the yield below — actual
    -- Consume happens only after re-validation post-yield, so a request
    -- that ultimately fails the speed gate never burns either cooldown.
    --
    -- NO EXPLICIT thresholdMs ARGUMENT BELOW (this pass, QA sandbox repro --
    -- same reasoning as requestBiteHold's identical fix above, see that
    -- comment / server/cooldowns.lua's header ADDENDUM for the full
    -- writeup): relies on TakedownCooldown/TakedownTargetCooldown's own
    -- ResolveConfiguredThresholdMs-resolved constructor default instead of
    -- re-reading Config.Combat.NonLethalTakedown.cooldownMs/targetCooldownMs
    -- raw, which would silently shadow that safe default with an invalid
    -- Config value again at the one place this actually gates a real
    -- request.
    if TakedownCooldown.IsOnCooldown(src)
        or TakedownTargetCooldown.IsOnCooldown(targetNetId) then
        local waitMs = math.max(TakedownCooldown.RemainingMs(src), TakedownTargetCooldown.RemainingMs(targetNetId))
        NotifyPlayer(src, CombatRejectMessage('on_cooldown', 'NonLethalTakedown', { remainingMs = waitMs }), 'error')
        return
    end

    -- SERVER-COMPUTED SPEED GATE — DEVELOPER_REFERENCE.md §12.5.2 / §12.0 item 8's
    -- "rolling speed history per targetable entity" open item, resolved
    -- NARROWLY this pass: a short, bounded, two-sample measurement window
    -- taken at request time, rather than a continuously-running per-ped
    -- tracker scanning every pool ped every tick. See
    -- config.lua's own Config.Combat.NonLethalTakedown.speedSampleWindowMs
    -- comment for the full rationale and the explicit "revisit if a fuller
    -- continuous tracker is wanted" note. NEVER a client-claimed "I am
    -- sprinting" flag.
    local basePos = GetEntityCoords(targetPed)
    Wait(Config.Combat.NonLethalTakedown.speedSampleWindowMs)

    -- RE-VALIDATE EVERYTHING after the yield — TOCTOU discipline already
    -- established elsewhere in this resource (server/search.lua's own
    -- "RE-CHECK HasK9Access(source) NOW, immediately after the awaited
    -- ox_inventory call" precedent). Anything could have changed during
    -- the wait: the K9's own access, proximity, the target already being
    -- held by someone else, or the target's own eligibility.
    -- k9Ped2 (the second, post-yield k9Ped) is deliberately discarded (`_`)
    -- this pass: it was previously only used to compute a k9NetId for the
    -- now-removed dead `ActiveHolds.holderNetId` field (QA-flagged this
    -- session, see this file's own header/report — server/combat.lua never
    -- read that field back; every relay payload that needs a K9 reference
    -- uses a LOCAL k9NetId computed at its own call site instead, and
    -- forceRagdoll/applyNpcTakedown need no K9 reference at all). Same
    -- "unused-by-design, not unfinished" pattern already established at
    -- this file's own pre-yield call above (`local ok, _, targetPed, _, _,
    -- reason = ValidateCombatRequest(...)`).
    local ok2, _, targetPed2, isPlayerTarget2, targetSrc2, reason2 =
        ValidateCombatRequest(src, targetNetId, Config.Features.NonLethalTakedown, Config.Combat.NonLethalTakedown.range, 'NonLethalTakedown')
    if not ok2 then
        NotifyPlayer(src, CombatRejectMessage(reason2, 'NonLethalTakedown'), 'error')
        return
    end

    local afterPos = GetEntityCoords(targetPed2)
    local dtSeconds = Config.Combat.NonLethalTakedown.speedSampleWindowMs / 1000.0
    local observedSpeed = dtSeconds > 0 and (#(afterPos - basePos) / dtSeconds) or 0.0
    if observedSpeed < Config.Combat.NonLethalTakedown.minTargetSpeed then
        NotifyPlayer(src, CombatRejectMessage('not_fleeing', 'NonLethalTakedown',
            { observedSpeed = observedSpeed }), 'error')
        return
    end

    -- NO EXPLICIT thresholdMs ARGUMENT BELOW either -- same reasoning as the
    -- pre-yield IsOnCooldown check above; both must resolve the SAME
    -- threshold the pre-yield check just used, which is only guaranteed by
    -- both reading the tracker's own constructor default rather than each
    -- independently re-reading (and each independently risking shadowing)
    -- raw Config.
    if not TakedownCooldown.Consume(src)
        or not TakedownTargetCooldown.Consume(targetNetId) then
        -- Extremely narrow race: something else consumed one of these
        -- cooldowns during the wait above despite the pre-check. Fail
        -- closed rather than apply a takedown with an inconsistent
        -- cooldown state.
        --
        -- Says the wait here too. This is the rarest of the four cooldown
        -- refusals, and the ONE most likely to feel like a bug from the
        -- player's side: the pre-check passed, they waited out the speed
        -- sample, and only then were refused. A silent "you must wait"
        -- after that sequence reads as the takedown being broken.
        local waitMs = math.max(TakedownCooldown.RemainingMs(src), TakedownTargetCooldown.RemainingMs(targetNetId))
        NotifyPlayer(src, CombatRejectMessage('on_cooldown', 'NonLethalTakedown', { remainingMs = waitMs }), 'error')
        return
    end

    local now = GetGameTimer()
    local expiresAt = now + Config.Combat.NonLethalTakedown.ragdollDurationMs

    -- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
    -- see requestBiteHold's own identical comment above for the full
    -- writeup this mirrors.
    local targetCitizenid2 = nil
    if isPlayerTarget2 then
        local targetPlayer2 = exports.qbx_core:GetPlayer(targetSrc2)
        targetCitizenid2 = targetPlayer2 and targetPlayer2.PlayerData and targetPlayer2.PlayerData.citizenid
    end

    ActiveHolds[targetNetId] = {
        effectType      = 'takedown',
        holderSrc       = src,
        isPlayerTarget  = isPlayerTarget2,
        targetSrc       = targetSrc2,
        targetCitizenid = targetCitizenid2,
        startedAt       = now,
        expiresAt       = expiresAt,
        compliance = {
            baselinePos = afterPos,
            lastPos     = afterPos,
            lastTime    = now,
            flagged     = false,
        },
    }
    K9ActiveEffect[src] = targetNetId

    if targetCitizenid2 then
        -- ttlMs = this hold's OWN remaining duration
        -- (Config.Combat.NonLethalTakedown.ragdollDurationMs) -- see
        -- requestBiteHold's own identical comment for the full reasoning.
        ClaimBody(targetCitizenid2, 'combat_target', expiresAt - now, 'takedown')
    end

    if isPlayerTarget2 then
        -- Category B relay -- DEVELOPER_REFERENCE.md §12.0 item 8.
        TriggerClientEvent('qbx_k9unit:client:forceRagdoll', targetSrc2, expiresAt)
    else
        -- NPC target — RESTRUCTURED, native-api-assistant verification
        -- pass (this session), REAL BUG FIX not just a lint workaround: see
        -- this file's header "NPC-TARGET NATIVE EXECUTION CONTEXT" note for
        -- the full finding. SetEntityCanBeDamaged was CONFIRMED CLIENT-ONLY
        -- (0x1760FFA8AB074D66, ENTITY namespace, no apiset entry — FXServer
        -- never receives this native at all), which means the previous
        -- server-side call here was a silent no-op: the damage-bracket that
        -- is supposed to make this takedown non-lethal never actually
        -- applied to a server-spawned NPC target. The health floor below is
        -- NOT a sufficient substitute on its own — it is a REACTIVE
        -- top-up (fires only once, only if health has already dropped
        -- below the floor at the instant this line runs), not a continuous
        -- damage block, so it cannot honestly cover sustained damage from
        -- another source during the multi-second ragdoll window (e.g. a
        -- different player still shooting the downed NPC). Fixed by
        -- relaying BOTH the damage-bracket and the ragdoll to the
        -- REQUESTING K9's own client — SetPedToRagdollWithFall's
        -- server-side validity also could not be confirmed either way this
        -- session, so this sidesteps that open question entirely rather
        -- than resolve it by assertion, the same way the bite-hold NPC
        -- branch above does.
        --
        -- NATIVE-AVAILABILITY FIX (this pass, coder-backend, native-sweep
        -- follow-up -- see this file's header "NPC-TARGET NATIVE EXECUTION
        -- CONTEXT" section, SetEntityHealth bullet, for the full finding):
        -- this branch used to ALSO call `SetEntityHealth(targetPed2, ...)`
        -- directly, server-side, as a "real, independently server-callable
        -- backstop" -- that claim did not survive verification. No
        -- `ext/native-decls` doc page exists for SetEntityHealth at all
        -- (unlike GetEntityHealth/GetEntityMaxHealth, both confirmed
        -- `apiset: server`), and citizen-server-impl's own
        -- ServerGameState_Scripting.cpp -- the exact file that registers
        -- GET_ENTITY_HEALTH/GET_ENTITY_MAX_HEALTH -- registers no
        -- SET_ENTITY_HEALTH/SET_PED_HEALTH handler anywhere. That call was
        -- therefore a SUSPECTED silent no-op, the same class of bug already
        -- fixed for SetEntityCanBeDamaged in this same branch above --
        -- kept, it would have quietly done nothing while this comment
        -- claimed otherwise. REMOVED here rather than left in as a harmless
        -- guess: the health-floor top-up now belongs entirely to
        -- client/combat.lua's own `applyNpcTakedown` handler, which already
        -- receives this same NPC target and can read
        -- `Config.Combat.NonLethalTakedown.healthFloor` directly (a
        -- `shared_scripts`-loaded config value, no new payload field
        -- needed on the TriggerClientEvent below) and self-apply
        -- `SetEntityHealth` the same already-client-confirmed way
        -- server/medkit.lua's applyMedkitHeal relay already does for a
        -- player target. THIS FILE'S HALF of the fix is complete (no
        -- longer calling a suspect native, no longer documenting it as
        -- trustworthy). STALE-COMMENT FIX (this pass, cross-change
        -- regression review, re-verified against the actual current
        -- client/combat.lua before rewriting this paragraph, not taken on
        -- the report alone): the CLIENT HALF has SINCE LANDED --
        -- client/combat.lua's `applyNpcTakedown` handler now calls
        -- `SetEntityHealth(npcPed, Config.Combat.NonLethalTakedown.healthFloor)`
        -- guarded the same `< healthFloor` way, ordered between the
        -- damage-bracket and the ragdoll task below, exactly matching this
        -- paragraph's own original ask. The one-time top-up is therefore no
        -- longer unapplied for an NPC target whose health was already below
        -- the floor at ragdoll-open time -- the damage-bracket
        -- (SetEntityCanBeDamaged) and the ragdoll itself, both relayed
        -- below, remain the primary, continuous protection during the
        -- window regardless; the health-floor call was always disclosed as
        -- a one-time supplement on top of them, not a replacement for
        -- either.
        TriggerClientEvent('qbx_k9unit:client:applyNpcTakedown', src, targetNetId, expiresAt)
    end

    -- CANCEL-PATH FIX (this pass) — sent unconditionally, regardless of
    -- isPlayerTarget2, mirroring biteHoldStarted's own "sent to the HOLDING
    -- K9's own client either way" placement exactly (requestBiteHold, above
    -- in this file). Gives client/combat.lua real per-takedown state to
    -- drive IsTakedownEngaged()/ReleaseTakedown() from, the same way
    -- biteHoldStarted already does for MyEngagedTargetNetId/
    -- IsBiteHoldEngaged().
    TriggerClientEvent('qbx_k9unit:client:takedownStarted', src, targetNetId, expiresAt)

    -- Config.XP.awards.takedownSuccess (config.lua) — QA-flagged as dead
    -- code (configured, never granted) until this pass.
    --
    -- STALE-COMMENT FIX (this pass, cancel-path addition — re-verified
    -- against the actual current code before rewriting, not left
    -- contradicting it): this comment used to say "there is no 'immediate
    -- release' farm vector to guard against since takedown has no manual
    -- release action at all" — that premise no longer holds, releaseTakedown
    -- (below) now exists. The CONCLUSION still holds regardless, for a
    -- different, still-valid reason: AwardXP is called HERE, at GRANT time
    -- (a few lines below), strictly BEFORE ActiveHolds/K9ActiveEffect are
    -- ever written for THIS request, and both TakedownCooldown/
    -- TakedownTargetCooldown.Consume have ALREADY run above this point —
    -- releaseTakedown only ever reaches EndHold (which never calls AwardXP,
    -- never touches either cooldown, for its 'takedown' branch), so a
    -- manual release can end the ragdoll early but cannot re-trigger this
    -- AwardXP call a second time, and cannot free either cooldown sooner
    -- than it would have expired anyway. No anti-farm change needed here as
    -- a result — flagged explicitly rather than left as a comment that no
    -- longer matches the code around it.
    --
    -- Unlike BiteAndHold, no anti-farm floor is needed here: reaching this
    -- line already means the server-computed speed gate (genuinely fleeing,
    -- never a client-claimed flag), both cooldowns (per-K9 AND per-target),
    -- and the full ValidateCombatRequest re-check all passed. Runtime
    -- existence guard, same convention as server/tracking.lua's own
    -- trackSourceResolved call site — no load-order assumption on
    -- server/progression.lua.
    -- SEVENTH XP-FARM FIX (this pass) -- see TakedownXpMintCooldown's own
    -- declaration comment (near BiteHoldXpMintCooldown, above) for the full
    -- writeup. Gates ONLY this AwardXP call, checked LAST -- reaching this
    -- line already means the feature flag, HasK9Access, live proximity, the
    -- full ValidateCombatRequest re-check, the server-computed speed gate,
    -- AND both TakedownCooldown/TakedownTargetCooldown.Consume calls above
    -- all already succeeded, so this is the very last thing that can still
    -- gate whether this specific takedown pays out. The relay
    -- (applyNpcTakedown/forceRagdoll above), ActiveHolds/K9ActiveEffect
    -- (already written above), and the notify call below are all entirely
    -- unaffected by whether this Consume succeeds -- a K9 out of mint budget
    -- still performs a fully normal takedown, it just is not paid for this
    -- one.
    --
    -- EIGHTH XP-FARM FIX, NPC-ELIGIBILITY HALF -- see EndHold's own bite-hold
    -- branch (above in this file) for the full writeup; identical reasoning
    -- applied to takedownSuccess. Checked FIRST in this `and` chain, before
    -- TakedownXpMintCooldown.Consume, for the same reason every other
    -- condition on this line is already ordered this way: a target that was
    -- never going to pay out anyway must never burn this per-holder mint
    -- budget, or a K9 that only ever gets ambient NPCs could exhaust its own
    -- real budget on takedowns that were never eligible to pay, then find
    -- itself falsely "out of budget" the next time a genuinely eligible
    -- wanted player comes along.
    if (isPlayerTarget2 or (Config.XP and Config.XP.mintXpForNpcCombatTargets == true))
        and type(AwardXP) == 'function'
        and TakedownXpMintCooldown.Consume(src, TAKEDOWN_XP_MINT_COOLDOWN_MS) then
        local holderPlayer = exports.qbx_core:GetPlayer(src)
        local holderCitizenid = holderPlayer and holderPlayer.PlayerData and holderPlayer.PlayerData.citizenid
        if holderCitizenid then
            AwardXP(holderCitizenid, 'takedownSuccess')
        end
    end

    -- BEST-EFFORT WORDING (guardrail 4).
    NotifyPlayer(src, locale('combat.takedown_attempted'), 'inform')
end

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestTakedown', function(targetNetId)
    local src = source

    -- Guards the yield inside HandleTakedownRequest against a second
    -- overlapping call from the SAME K9 — see TakedownMutex's own
    -- declaration comment above.
    if not TakedownMutex.TryAcquire(src) then
        NotifyPlayer(src, locale('combat.takedown_already_in_progress'), 'error')
        return
    end

    local ok, err = pcall(HandleTakedownRequest, src, targetNetId)

    TakedownMutex.Release(src) -- ALWAYS clear, success or error

    if not ok then
        print(('[qbx_k9unit] requestTakedown error for source %s: %s'):format(src, tostring(err)))
    end
end)

--- CANCEL-PATH FIX (this pass, coder-frontend — audit-flagged gap: bite-hold
--- has releaseBiteHold, drag has releaseDrag, takedown had neither, so an
--- auto-picked wrong target — FindNearestCombatTarget, client/combat.lua,
--- picks the NEAREST eligible ped, not necessarily the intended one — had no
--- way back short of waiting out the full Config.Combat.NonLethalTakedown.
--- ragdollDurationMs). MIRRORS releaseBiteHold's shape EXACTLY (see that
--- handler above), NOT reinvented:
---   - Same O(1) K9ActiveEffect[src] lookup to resolve `src`'s own current
---     target, never a client-supplied targetNetId.
---   - Same two-part shape check (`hold` exists, `hold.effectType` matches
---     the mechanic this handler owns, `hold.holderSrc == src`) before ever
---     calling EndHold — an impostor `releaseTakedown` from a source that is
---     not genuinely the holder of THIS takedown is a silent no-op, exactly
---     like releaseBiteHold's own impostor case.
---   - Same authorization posture: DELIBERATELY NEVER re-checks
---     HasK9Access(src)/Config.Features.NonLethalTakedown/any cooldown on the
---     way out. THIS IS A TERMINATION PATH — DEVELOPER_REFERENCE.md §12.0 item 4's
---     "no unbounded trap" guarantee (already binding for takedown's own hard
---     expiresAt cap, see the shared maintenance thread) requires that a K9
---     whose certification is revoked, or whose feature flag is toggled off,
---     mid-takedown can still call it off — gating this on either would
---     reintroduce exactly the trap that guarantee forbids, the same
---     reasoning EndActiveEffectForHolder's own doc comment (above) already
---     establishes for Recall.
--- Reason 'released_by_holder' — deliberately the SAME string releaseDrag's
--- own holder-side release already uses (not BiteAndHold's 'released'): both
--- mean the identical thing, "the holder manually let go," and EndHold
--- branches on `hold.effectType` FIRST, before ever looking at `reason`, so
--- reusing the string across the 'drag' and 'takedown' branches creates no
--- ambiguity — it is simply the same semantic reason, consistently spelled,
--- for the same kind of event on two different mechanics. Takedown has no
--- target-side release counterpart (unlike releaseDrag, which legitimately
--- accepts a target-initiated release too — DEVELOPER_REFERENCE.md §12.5.2 lists no
--- such capability for NonLethalTakedown, and this handler does not add
--- one), so only the one reason string is needed here.
--- AWARD-FARM CHECK (explicitly verified, not assumed — see
--- HandleTakedownRequest's own updated comment on this above): AwardXP for
--- takedownSuccess already ran at GRANT time, strictly before this handler
--- can ever run for this hold — EndHold's own 'takedown' branch never calls
--- AwardXP and never touches TakedownCooldown/TakedownTargetCooldown, so
--- this termination path cannot mint XP a second time and cannot free
--- either cooldown any sooner than it would have expired on its own.
RegisterNetEvent('qbx_k9unit:server:releaseTakedown', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if not targetNetId then return end -- src is not currently the holder of anything -- ignore

    local hold = ActiveHolds[targetNetId]
    if not hold or hold.effectType ~= 'takedown' or hold.holderSrc ~= src then return end

    EndHold(targetNetId, 'released_by_holder')
end)

--[[ ================= PROP DRAGGING ================= ]]
--[[
    DEVELOPER_REFERENCE.md §12.5.4 / §12.0 items 1, 4, 5, 6, 8 (coder-architect,
    this pass). Reuses ActiveHolds/K9ActiveEffect/EndHold/FlagNonCompliance/
    the shared maintenance thread above wholesale (effectType = 'drag') —
    see this file's own header for why (avoids exactly the kind of
    unforced duplicate-table/duplicate-lifecycle problem DEVELOPER_REFERENCE.md
    §12.0 item 8 itself warns against for this class of state).

    CATEGORY A/B SPLIT FOR THIS MECHANIC, restated concretely against the
    code below (DEVELOPER_REFERENCE.md §12.0 item 8's own framing): the attach
    (AttachEntityToEntity, entirely client/combat.lua's responsibility —
    THIS file only ever grants/denies the request and tracks state, it
    never calls that native itself) is Category A and comparatively robust
    -- but ONLY under the "re-asserted every tick, never one-shot"
    discipline binding guardrail 2 requires, because DetachEntity is very
    likely NOT ownership-gated either (§12.0 item 8's own citation of
    citizenfx/fivem issue #3726) -- a hostile target's own client can call
    DetachEntity on itself at any moment, and the ONLY thing that puts the
    attach back is the K9's client calling AttachEntityToEntity again on
    its very next frame. THIS FILE'S OWN CONTRIBUTION to that guarantee is
    narrow and honest: it never assumes the attach "is holding" for any
    server-authoritative purpose (guardrail 3), and DragExceedsMaxDistance
    above / the drag_gap compliance signal above are BOTH blind to *why* the
    gap grew (self-detach, a bypassed move-rate override, or the K9 client
    simply failing to keep re-asserting) — by design, per item 8's own
    "regardless of cause" framing, since this file has no way to observe
    client-side attach state directly anyway. The speed-limit half is
    Category B in full, same posture as bite/takedown's own restrictive
    effects.

    "IS THIS TARGET DOWNED" — see IsTargetDowned (above, near
    IsPlayerWantedEligible) for the full two-branch contract (native-only
    for an NPC, override-or-metadata-guess for a player, DEVELOPER_REFERENCE.md
    §12.0 item 6). Called as an explicit SEPARATE step after
    ValidateCombatRequest({requireAlive = false}) succeeds — see that
    function's own updated header for why this could not simply reuse its
    built-in dead-target check (GetEntityHealth-based -- see PED_DEAD_HEALTH_THRESHOLD above).

    NO XP AWARD for PropDragging in this pass — DEVELOPER_REFERENCE.md §12.2's own
    config sketch names no `Config.XP.awards.*` key for dragging (unlike
    biteHoldSuccess/takedownSuccess), so none is invented here; this is a
    disclosed omission, not an oversight, and a config-validator/product
    pass can add one later the same way biteHoldSuccess/takedownSuccess
    were wired up if a reward is wanted.
]]

--- @param targetNetId any
RegisterNetEvent('qbx_k9unit:server:requestDrag', function(targetNetId)
    local src = source

    -- requireAlive = false: PropDragging's ENTIRE premise is a DOWNED
    -- target -- ValidateCombatRequest's own dead-target rejection exists
    -- to protect BiteAndHold/NonLethalTakedown from a target that is
    -- ALREADY dead/dying, the opposite of what this mechanic wants. The
    -- REAL "is this specific target downed" check is IsTargetDowned below,
    -- run only after every other shared precondition (access, proximity,
    -- already_held, wellbeing, RequireWantedStatus) has independently
    -- passed.
    -- k9Ped is deliberately discarded (`_`): dragStarted's payload carries
    -- no K9 netId (the K9's own client already knows its own PlayerPedId()
    -- locally for the attach), same "unused-by-design" pattern as
    -- HandleTakedownRequest's own discarded k9Ped2 above.
    local ok, _, targetPed, isPlayerTarget, targetSrc, reason =
        ValidateCombatRequest(src, targetNetId, Config.Features.PropDragging, Config.Combat.PropDragging.range, 'PropDragging', { requireAlive = false })
    if not ok then
        NotifyPlayer(src, CombatRejectMessage(reason, 'PropDragging'), 'error')
        return
    end

    if not IsTargetDowned(targetPed, isPlayerTarget, targetSrc) then
        NotifyPlayer(src, CombatRejectMessage('target_not_downed'), 'error')
        return
    end

    -- MISSING-COOLDOWN FIX -- see DragCooldown/DragTargetCooldown's own
    -- declaration comment above for what was wrong and why it mattered here
    -- more than the shape usually does.
    --
    -- BOTH are CHECKED before EITHER is stamped, for the same reason spelled
    -- out at requestBiteHold's own identical pair below: a request rejected
    -- because of ONE cooldown must never burn the OTHER -- stamping the
    -- per-target one for a drag that never happened would penalise the next
    -- K9 to reach this same person, and stamping the per-K9 one would cost
    -- this K9 its own next drag for nothing.
    --
    -- Deliberately placed AFTER IsTargetDowned rather than before it, unlike
    -- bite/takedown, whose pairs sit immediately after ValidateCombatRequest.
    -- IsTargetDowned is this mechanic's real precondition and the one most
    -- likely to fail on an honest attempt (the suspect got back up, the
    -- laststand override says otherwise); rejecting on the cooldown first
    -- would answer "wait 8 seconds" to a K9 whose actual problem is that
    -- there is nothing here to drag.
    --
    -- No explicit thresholdMs argument -- each tracker's constructor default
    -- above is already the ResolveConfiguredThresholdMs-checked value, and
    -- passing the raw Config number here would silently shadow it (0 is
    -- truthy in Lua). Same trap, same reasoning, as documented at length on
    -- requestBiteHold's own pair.
    if DragCooldown.IsOnCooldown(src)
        or DragTargetCooldown.IsOnCooldown(targetNetId) then
        local waitMs = math.max(DragCooldown.RemainingMs(src), DragTargetCooldown.RemainingMs(targetNetId))
        NotifyPlayer(src, CombatRejectMessage('on_cooldown', 'PropDragging', { remainingMs = waitMs }), 'error')
        return
    end

    DragCooldown.Touch(src)
    DragTargetCooldown.Touch(targetNetId)

    local now = GetGameTimer()
    -- maxDragDurationMs: a defensive hard-duration backstop ADDED beyond
    -- DEVELOPER_REFERENCE.md §12.2's literal sketch (which names only
    -- maxDragDistance as this mechanic's "no unbounded trap" cap, §12.0
    -- item 4) — LANDED in config.lua (Config.Combat.PropDragging.maxDragDurationMs
    -- = 20000; see that field's own comment there for the full disclosed
    -- reasoning). Reuses the SAME `hold.expiresAt` / maintenance-thread-timeout
    -- mechanism bite/takedown already use, no new enforcement path. NOTE:
    -- unlike the cooldown fields above, this value is read directly with
    -- no positive-number validation anywhere in this file — a misconfigured
    -- non-positive/non-numeric value here would either error at this line
    -- or silently expire a drag hold instantly, not fail loudly the way
    -- cooldowns.lua's own guarded fields do; flagged, not fixed, since no
    -- Config.Combat.* field in this file is validated this way today.
    local expiresAt = now + Config.Combat.PropDragging.maxDragDurationMs

    -- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
    -- see requestBiteHold's own identical comment (above in this file) for
    -- the full writeup this mirrors.
    local targetCitizenid = nil
    if isPlayerTarget then
        local targetPlayer = exports.qbx_core:GetPlayer(targetSrc)
        targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    end

    ActiveHolds[targetNetId] = {
        effectType      = 'drag',
        holderSrc       = src,
        isPlayerTarget  = isPlayerTarget,
        targetSrc       = targetSrc,
        targetCitizenid = targetCitizenid,
        startedAt       = now,
        expiresAt       = expiresAt,
        compliance = {
            -- lastPos/lastTime are stamped for parity with bite/takedown's
            -- own compliance records (SampleCompliance's shared tail always
            -- writes them) but are NOT read by the 'drag' branch itself —
            -- that branch compares LIVE positions each sample, it has no
            -- use for a historical baseline/rate the way bite/takedown do.
            lastPos  = GetEntityCoords(targetPed),
            lastTime = now,
            flagged  = false,
        },
    }
    K9ActiveEffect[src] = targetNetId

    if targetCitizenid then
        -- ttlMs = this hold's OWN remaining duration
        -- (Config.Combat.PropDragging.maxDragDurationMs) -- see
        -- requestBiteHold's own identical comment for the full reasoning.
        ClaimBody(targetCitizenid, 'combat_target', expiresAt - now, 'drag')
    end

    -- Category A: tells the HOLDING K9's own client to start its per-tick
    -- AttachEntityToEntity re-assertion loop (client/combat.lua). isPlayerTarget
    -- is included so that SAME client also knows whether to ALSO drive the
    -- NPC's own move-rate directly (no relay needed for an NPC) or leave
    -- the speed-limit half to the target's own client (Category B, below).
    TriggerClientEvent('qbx_k9unit:client:dragStarted', src, targetNetId, isPlayerTarget, expiresAt)

    if isPlayerTarget then
        -- Category B relay -- DEVELOPER_REFERENCE.md §12.0 item 8.
        TriggerClientEvent('qbx_k9unit:client:applyDragSpeedLimit', targetSrc, expiresAt)
    end
    -- NPC target: no separate relay event needed -- dragStarted above
    -- already told the K9's own client isPlayerTarget = false, which is
    -- all that client needs to also drive SetPedMoveRateOverride on the
    -- NPC directly, every tick, alongside the attach re-assertion.

    -- BEST-EFFORT WORDING (guardrail 4) -- never claims the target cannot
    -- escape, mirrors requestBiteHold/HandleTakedownRequest's own copy.
    NotifyPlayer(src, locale('combat.drag_attempted'), 'inform')
end)

RegisterNetEvent('qbx_k9unit:server:releaseDrag', function()
    local src = source

    -- Either the HOLDING K9 or, when the target is a player, the TARGET
    -- itself may release at will -- DEVELOPER_REFERENCE.md §12.5.4 / §12.0 item 4:
    -- mirrors leash's own "no consent needed to get free" rule, and is
    -- STRONGER than bite/takedown's own target (who has no self-release
    -- action at all -- apprehension by design, not a cooperative
    -- mechanic). Checks the holder side first (cheap O(1) lookup via
    -- K9ActiveEffect) before falling back to the O(n) target-side scan.
    local targetNetId = K9ActiveEffect[src]
    if targetNetId then
        local hold = ActiveHolds[targetNetId]
        if hold and hold.effectType == 'drag' and hold.holderSrc == src then
            EndHold(targetNetId, 'released_by_holder')
            return
        end
    end

    for netId, hold in pairs(ActiveHolds) do
        if hold.effectType == 'drag' and hold.isPlayerTarget and hold.targetSrc == src then
            EndHold(netId, 'released_by_target')
            return
        end
    end
end)

--[[ ================= DISCONNECT CLEANUP ================= ]]

--- If the HOLDING K9 disconnects mid-hold/mid-takedown, tear it down
--- immediately rather than leaving a target's client-side relay (or, for
--- an NPC, the direct suppression/damage-bracket) active until the hard
--- expiresAt cap. If the TARGET disconnects instead, there is no client
--- left to relay a teardown to — just drop the bookkeeping.
AddEventHandler('playerDropped', function()
    local src = source

    local targetNetId = K9ActiveEffect[src]
    if targetNetId then
        EndHold(targetNetId, 'holder_disconnected')
    end

    for netId, hold in pairs(ActiveHolds) do
        if hold.isPlayerTarget and hold.targetSrc == src then
            EndHold(netId, 'target_disconnected')
        end
    end

    -- RED-TEAM FINDING 1 FIX, cleanup half (this pass, coder-security): a
    -- stale K9PositionHistory[src] entry left behind after disconnect would
    -- be keyed to a `src` number FiveM WILL eventually reuse for a
    -- completely unrelated new connection -- without this, that brand-new
    -- player's very first combat request could be compared against a
    -- position that belonged to a different person entirely (either
    -- wrongly rejecting them for "implausible movement" relative to a
    -- stranger's old location, or, if the stale entry happened to sit right
    -- next to wherever they spawned, wrongly granting a free pass). This is
    -- a pure cleanup, never a gate -- removing this line would only
    -- reintroduce that stale-reuse edge case, it could never strand a hold
    -- (K9PositionHistory is read only by ValidateCombatRequest, a
    -- REQUEST-TIME-ONLY function per its own doc comment, never by any
    -- termination path).
    K9PositionHistory[src] = nil
end)
