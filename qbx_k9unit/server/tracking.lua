--[[
    qbx_k9unit/server/tracking.lua

    Phase 2 implementation (coder-backend). Owns the event-relay log backing
    blood-trail and gunpowder-sniff (damage-event / weapon-fire coordinate
    capture, read server-side from the REPORTING CLIENT'S OWN live ped
    position, never a client-supplied coordinate — same "never trust client
    claims" standard server/certifications/'s header established for
    §4.3), a server-side ox_inventory 'swapItems' hook backing scent-trail
    coordinate capture (added this pass — see AUTHORITATIVE SOURCES item 9
    below), a periodic prune pass dropping entries older than
    Config.Tracking.Scent/Blood/Gunpowder.maxAgeSeconds, and the
    `qbx_k9unit:server:findTrackableSource` callback that resolves the
    nearest matching source (scent/blood/gunpowder) within
    Config.Tracking.<Type>.maxRange of the calling K9's live server-side
    position.

    Ephemeral/in-memory only, deliberately not persisted — mirrors
    server/main.lua's `LeashPairs` precedent (both are live-session data,
    not account data). DEVELOPER_REFERENCE.md §10 flags this as still needing db-schema's
    confirmation that the precedent holds here too; not assumed settled by
    this file.

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE:
    1. DEVELOPER_REFERENCE.md §11.4 items 1, 3, 4 (event/callback contract) and §11.5's
       "Scent tracking" / "Blood trail tracking" / "Gunpowder residue
       sniffing" / "Water tracking" acceptance criteria — the base
       contract.
    2. DEVELOPER_REFERENCE.md §11.6's reality-check refinements (gunpowder/blood relay is
       genuinely authored code, not free). Its framing of scent's
       ox_inventory hook as unconfirmed is SUPERSEDED by item 9 below —
       kept here verbatim rather than edited so the historical reasoning
       trail stays intact.
    3. DEVELOPER_REFERENCE.md#tracking — client-logic-lens refinement
       of §11.4 items 1/3, plus two explicit "flag for coder-security"
       notes worth restating here since THIS file is where they land:
       (a) `findTrackableSource`'s signature must never grow a
       client-supplied coordinate parameter, (b) `relayDamageEvent` trusts
       the FACT of damage but never the reported location.
    4. DEVELOPER_REFERENCE.md#tracking — confirms the
       `CEventNetworkEntityDamage` relay pattern is real and sound, but
       flags that it does NOT fire for script-applied damage (only organic
       gameplay damage) — a real, documented gap, not a bug to fix here.
    5. DEVELOPER_REFERENCE.md#tracking — confirms `IsPedShooting`
       debounce is the right client-side
       trigger for gunpowder (this file only ever receives the resulting
       relay event, it does no shooting-detection itself), and that the
       water-crossing modifier is entirely a CLIENT-side concern
       (client/tracking.lua) — this file never needs to know about water.
    6. DEVELOPER_REFERENCE.md §9 items 10, 11, 14 — standing open questions touching this
       file specifically (relay-code effort is real authored work, not
       free; whether tracking needs abuse-limits beyond the per-type
       cooldown is an explicit open judgment call, not decided here). Item
       11's "ox_inventory export for scent-source detection is UNCONFIRMED"
       framing is SUPERSEDED by item 9 below — kept verbatim for the same
       reason as item 2 above.
    7. Coordinator amendment (2026-08-23, this pass): Config.Tracking.Blood
       /Gunpowder.relayCooldownMs are the LOGGING-side rate limits §11.4
       items 3/4 call for (distinct from the QUERY-side searchCooldownMs
       above) — the timestamp is stamped BEFORE any log-append work, since
       CEventNetworkEntityDamage can legitimately fire multiple times per
       hit and a modified client can call TriggerServerEvent directly,
       bypassing the client-side debounce entirely.
    8. exploit-tester finding (2026-08-23, red-team pass against the
       finished client files) + coordinator decision, same day — see
       "FORGED TRAIL DECISION" below.
    9. DEVELOPER_REFERENCE.md#scent-source-resolution (tech-scout pass, same day)
       + this pass's implementation (coder-backend, 2026-08-23) — CONFIRMS
       and CLOSES items 2/6's "scent's ox_inventory hook is unconfirmed"
       framing. A real, first-party `ox_inventory` server-side hook,
       `exports.ox_inventory:registerHook('swapItems', callback)`, fires
       synchronously on every item move ox_inventory processes, including a
       ground-drop (`payload.toType == 'drop'`), carrying `payload.source`
       (ox_inventory's own resolved source for the request — the same trust
       level as any RegisterNetEvent's ambient `source`, not a
       client-relabelable value). This is now wired up below (see the
       `exports.ox_inventory:registerHook` call site's own doc comment for
       the full confidence grading) — the "SCENT BRANCH STATUS" note
       further down reflects the new, implemented state; do not trust the
       older "always returns found = false" framing that used to live there
       if you're reading a stale copy of this comment from history/diff.

    FORGED TRAIL DECISION (deliberate, not an oversight — read before
    "fixing" this): relayDamageEvent/relayWeaponFire are payload-less BY
    DESIGN (§11.4 items 3/4 — never trust a client-claimed coordinate), but
    that also means a modified client can call either event directly with
    NO actual damage/shot having occurred at all, skipping
    client/tracking.lua's local "am I really the victim/shooter" filters
    entirely. relayCooldownMs (500ms blood / 300ms gunpowder) throttles the
    RATE of fabricated entries but does not, and structurally cannot,
    prevent an attacker from seeding a decoy at their own current position
    an unlimited number of times over a session, leading a K9 officer's
    subsequent "Track Blood"/"Track Gunpowder" to a fabricated location.
    This CANNOT be closed client-side (any client-side "proof" is exactly
    the claim already established as untrustworthy), and no cheap
    server-side corroboration was added deliberately: the two candidates
    considered (checking the reporter's current health isn't full; checking
    an ammo-consumption delta against a per-player cache) both introduce
    real false-negative risk against legitimate reports (armor can absorb
    all health loss from a genuine hit; weapon switches/reloads would need
    their own extra state) for a feature DEVELOPER_REFERENCE.md §11.6 and
    DEVELOPER_REFERENCE.md#tracking §3 item 2 already explicitly frame
    as acceptable-risk: tracking grants no real capability (DEVELOPER_REFERENCE.md §11.6),
    and "a false report just plants a harmless phantom blood-trail
    location" (DEVELOPER_REFERENCE.md#tracking §3 item 2's own words, written
    before this exact scenario was raised again by exploit-tester).
    DECISION: accept this as a known, documented limitation — a griefer can
    waste a K9 officer's time with a fabricated trail, never anything
    server-authoritative (no money/items/permissions/evidence hinges on
    trail accuracy) — rather than add corroboration logic that would
    degrade the legitimate feature for real players wearing armor or
    switching weapons. Revisit ONLY if a later phase ever conditions
    something server-authoritative on a resolved trail source (mirrors the
    exact "revisit if a later phase changes the stakes" framing DEVELOPER_REFERENCE.md
    §4.1 already uses for the vehicle-entry-exit exception).

    NOTE — THIS DECISION DOES NOT APPLY TO SCENT (added this pass, see item
    9 above): scent's `swapItems` hook is not a client-triggerable event at
    all — ox_inventory calls it server-to-server, and `payload.source`
    cannot be relabeled by a client to claim a drop that didn't happen.
    There is no "modified client calls the report event directly with
    nothing having actually occurred" vector for scent the way there is for
    blood/gunpowder, so scent's ingest path deliberately has no
    forged-trail-style accepted-risk framing to write — there is no risk of
    that specific shape to accept.

    ADDENDUM (coder-security finding A, this pass — THE "revisit ONLY if a
    later phase..." TRIGGER ABOVE HAS NOW FIRED): Config.Features.XPProgression
    landed this same pass and is precisely that later phase — it conditions
    something server-authoritative (real XP, and therefore a real
    speedMultiplier/scentRangeMultiplier bonus via Config.XPTiers) on a resolved trail
    source, via trackSourceResolved (PendingTrackArrival /
    reportTrackSourceArrival below). Revisiting confirmed this decision's
    own reasoning still holds for the REVEAL itself (a forged/phantom
    location remains cosmetic-only — no money/items/permissions/evidence
    hinges on where the marker trail points), but exposed a SEPARATE,
    orthogonal gap the XP wiring introduced: nothing required the K9 to
    travel any meaningful distance between a source being logged and that
    same K9 reporting arrival at it, so a K9 who plants a source at their
    own feet (forged, for blood/gunpowder) or simply already happens to be
    standing right next to one (true for ANY trackType, including scent's
    non-forgeable hook) could round-trip resolve→arrive for XP with zero
    travel — a stationary farm, not a forged-location problem. This is NOT
    fixed by adding corroboration to relayDamageEvent/relayWeaponFire (the
    false-negative-risk reasoning above for why that was rejected still
    applies unchanged) — it's fixed at the ARRIVAL-ELIGIBILITY layer
    instead, orthogonally to the forged-trail question this section
    otherwise concerns itself with: see `MIN_TRACK_XP_DISTANCE` and its
    call site in findTrackableSource below. The forged-trail accepted-risk
    DECISION above still stands, unmodified, for the REVEAL; only the new
    XP-ticket eligibility gate is new.

    ADDENDUM 2 (economy-audit finding, this pass — MIN_TRACK_XP_DISTANCE
    alone was NOT sufficient): a live economy audit independently confirmed
    trackSourceResolved was still a real, ~3,600-4,200 XP/hr farm even with
    finding A's fix in place, via two holes finding A's own distance-only
    check never touched: (1) a single TrackableLog entry stayed matchable
    for its ENTIRE maxAgeSeconds window, so walking MIN_TRACK_XP_DISTANCE
    away from the SAME still-fresh entry and back re-earned XP off the one
    real logged event indefinitely — no NEW source was ever required; (2)
    MIN_TRACK_XP_DISTANCE and Config.XP.trackArrivalRadius are both
    POSITION-only checks, so a client capable of `SetEntityCoords` could
    satisfy both with a single teleport and ~0ms of real elapsed time. Both
    are now closed: TrackableLog entries carry a `ticketIssued` flag rationing
    each real logged event to at most one ticket ever (see that field's own
    declaration comment), and every PendingTrackArrival ticket now also
    requires genuine elapsed server time, scaled to distance, before it can
    be redeemed (see MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's own declaration
    comment). Neither change touches the forged-trail DECISION above or the
    REVEAL — only trackSourceResolved's XP-ticket eligibility.

    ADDENDUM 3 (coder-backend correctness pass, this pass — ADDENDUM 2's own
    fix was STILL not sufficient): ADDENDUM 2 rations a single TrackableLog
    ENTRY to one ticket ever and requires genuine elapsed time to redeem one,
    but never touched how fast a fresh, never-ticketed entry can be produced
    in the first place — and producing one is cheap: a modified client can
    call the payload-less relayDamageEvent/relayWeaponFire directly (the same
    forgeable-by-design surface the FORGED TRAIL DECISION above already
    accepts for the REVEAL, but that decision was never re-evaluated against
    this XP angle), and 'scent' needs no forgery at all — an ordinary,
    unmodified drop/walk-away/walk-back/pick-up-and-repeat loop manufactures
    a fresh entry every cycle. Config.Tracking.<Type>.searchCooldownMs
    (5000ms shipped) was the only per-cycle throttle either path was actually
    bound by, comfortably longer than MIN_TRACK_XP_DISTANCE's own real-travel
    floor — enough for a farmer to sustain roughly one ticket every ~5s this
    way, ~7,200 XP/hr, HIGHER than the ~3,600-4,200 XP/hr ADDENDUM 2 itself
    treats as worth closing. Closed by `TrackTicketMintCooldown` (see its own
    declaration comment below): a per-source, cross-trackType cooldown on
    ticket-MINTING itself, independent of entry-manufacturing cost or which
    trackType is used. Does not touch the REVEAL (`found = true`/`coords` is
    unaffected) or ADDENDUM 1/2's own mechanisms, which still apply on top of
    this for whatever tickets do get minted.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per DEVELOPER_REFERENCE.md §11.4 items 1, 3, 4.
    Identical in shape to server/certifications/'s contract block so
    coder-backend/coder-frontend can work in parallel without live
    coordination, per that file's own stated rationale for this format.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:findTrackableSource' (trackType: 'scent'|'blood'|'gunpowder')
       -> { found: boolean, coords: vector3?, breaksAtWater: boolean }
       [THIS FILE]
       Re-validates Config.Features.<Type> and HasK9Access(source)
       server-side regardless of client UI state. Resolves the caller's
       OWN live position via GetEntityCoords(GetPlayerPed(source)) —
       NEVER a client-supplied coordinate (the signature deliberately
       takes only `trackType`, no coords parameter — do not add one
       later, see DEVELOPER_REFERENCE.md#tracking §3 item 1).
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:relayDamageEvent' () [THIS FILE]
       Triggered by a client's own `gameEventTriggered('CEventNetworkEntityDamage', ...)`
       handler when the LOCAL PLAYER IS THE VICTIM (confirmed real pattern,
       DEVELOPER_REFERENCE.md#tracking §0). Takes no meaningful
       payload — the server logs the reporting client's own live
       coordinates, never a client-supplied position, exactly like
       server/main.lua's relayBark "resolve the sender's own ped, don't
       trust a claimed netId" pattern. Rate-limited by
       Config.Tracking.Blood.relayCooldownMs, stamped BEFORE the log
       append.
    3. 'qbx_k9unit:server:relayWeaponFire' () [THIS FILE]
       Triggered by a client on a debounced local false->true transition
       of IsPedShooting(PlayerPedId()). Same "server logs the reporting
       client's own live coordinates" rule as event 2. Rate-limited by
       Config.Tracking.Gunpowder.relayCooldownMs — independent of, and in
       addition to, Config.Tracking.Gunpowder.searchCooldownMs, which is a
       QUERY-side cooldown (how often a K9 can re-run "Track Gunpowder"),
       not this LOGGING-side cooldown (how often a single shooter's fire
       events get recorded at all). Do not conflate the two.
    4. 'qbx_k9unit:server:reportTrackSourceArrival' () [THIS FILE] PHASE 4
       ADDITION (Config.Features.XPProgression, DEVELOPER_REFERENCE.md §13.4.1).
       Fired by client/tracking.lua's render thread the first tick it
       observes its own live distance to a resolved source drop to/below
       Config.XP.trackArrivalRadius (client/tracking.lua's own header, EVENT/
       CALLBACK CONTRACT item 4, confirms this wiring — added same pass as
       this entry). No payload — a trigger only. THIS FILE re-measures the
       caller's OWN live server-side position against the coordinate it
       already resolved and stored in `PendingTrackArrival` (below) —
       NEVER a client-claimed distance/arrival boolean. Rate-limited by
       `TrackArrivalReportCooldown` (defense-in-depth only, see that
       tracker's own declaration comment — the primary anti-farm mechanisms
       are `PendingTrackArrival`'s single-use-then-cleared shape, the
       underlying TrackableLog entry's own one-ticket-ever `ticketIssued`
       rationing, and the real-elapsed-time-vs-distance `minElapsedMs`
       check (ADDENDUM 2, economy-audit fix, this file's header), not this
       rate limit).

    ox_inventory hooks (exports.ox_inventory:registerHook, ox_inventory ->
    THIS FILE, server-to-server — added this pass, DEVELOPER_REFERENCE.md §9 items 11/17,
    DEVELOPER_REFERENCE.md#scent-source-resolution):
    5. 'swapItems' [THIS FILE]
       ADDENDUM (coordinator decision, 2026-08-24): registration is now
       GATED on a runtime capability check in addition to
       Config.Features.ScentTracking — fxmanifest.lua's
       `dependencies` block has no version-constraint syntax at all, so it
       cannot guarantee `registerHook` actually exists on whatever
       `ox_inventory` ends up running. If the check fails, this hook is
       never registered at all (not registered-then-early-returning) and
       one warning is printed; see `RegisterScentInventoryHook()` below for
       the full reasoning. (That check WAS a local `IsOxInventoryHookCapable()`
       in this file. It was deleted in the compat-layer migration and its job
       is now done by the boolean `K9Compat.Get('inventory').RegisterHook`
       returns — same guarantee, one less hand-rolled probe. Corrected
       2026-08-31: three comments in this file still described the deleted
       function in the present tense.) LIFECYCLE FIX (this pass):
       registration is re-run (via `RegisterScentInventoryHook()`) not only
       on THIS resource's own start but also on ox_inventory's OWN start —
       see the `AddEventHandler('onResourceStart', ...)` call site's own
       doc comment for why a bare `restart ox_inventory` would otherwise
       silently and permanently kill scent tracking without ever restarting
       this resource. Otherwise unchanged: fires
       synchronously, server-side, whenever ox_inventory processes ANY
       slot-to-slot item move — filtered here to `payload.toType == 'drop'`
       (a ground-drop) only.
       Logs the DROPPING PLAYER'S OWN live position, resolved via
       GetEntityCoords(GetPlayerPed(payload.source)) — same "never trust a
       claimed coordinate" rule as events 2/3 above, except there is no
       client relay step at all here: `payload.source` is ox_inventory's
       own resolved source, not a value any client can relabel. Rate-limited
       by Config.Tracking.Scent.relayCooldownMs — see that call site's own
       doc comment for why this is defense-in-depth against ingest volume,
       NOT an anti-forgery measure the way events 2/3's relayCooldownMs is.

    Client events (RegisterNetEvent, server->client): none from this file
    — per DEVELOPER_REFERENCE.md §11.4 item 7's own reasoning (already applied to
    Phase 1's `hasK9Access`), tracking-result delivery is
    request/response shaped, so `findTrackableSource` above being a
    lib.callback is sufficient; no fire-and-forget result event is needed.

    Commands: none.

    Automatic path: the internal prune thread (self-scheduled, no external
    trigger) and, as of this pass, the 'swapItems' ox_inventory hook above
    (externally triggered by ox_inventory's own item-move handling, not by
    anything this resource's own client ever calls directly) — otherwise,
    unlike server/certifications/'s QBCore:Server:OnJobUpdate hook,
    nothing in this file runs outside a direct response to an explicit
    client-initiated event/callback above.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, resource-global from
      server/certifications/ — reused, never re-derived, per that
      file's own "SINGLE source of truth" rule.
    - THIS FILE does NOT call `IsConfiguredK9Model` — unlike leash
      role-assignment (server/main.lua) or certification grants
      (server/certifications/), tracking access is gated purely on
      HasK9Access (job + certification), never on the caller's CURRENT
      ped model. This mirrors HasK9Access's own documented Phase 1
      tradeoff (a certified handler who later isn't K9-modeled still
      passes access checks; client-side display hides the UI for them
      instead) — flagged here so a future edit doesn't "helpfully" add a
      model check that contradicts that established Phase 1 precedent.
    - THIS FILE exposes NO resource-global functions. Nothing outside
      this file calls into it directly — client/tracking.lua interacts
      with it exclusively through the callback/events documented above.
      Do not add exported globals here without updating this contract
      block and README.md's "Public API (exports)" section's function-name table.
    - THIS FILE also CONSUMES one export from ox_inventory (a dependency
      per fxmanifest.lua, already running by the time this file's file-load
      code executes) — `exports.ox_inventory:registerHook('swapItems', ...)`
      — added this pass. This is a one-way consumption (this file registers
      a callback ox_inventory invokes); THIS FILE still exposes nothing of
      its own for ox_inventory or any other resource to call.
      ADDENDUM (coordinator decision, 2026-08-24): fxmanifest.lua's
      `dependencies` block only guarantees ORDERING (ox_inventory starts
      before this resource) — it has no version-constraint syntax at all, so
      it cannot guarantee `registerHook` actually exists on whatever
      `ox_inventory` build ends up running. The boolean that
      `K9Compat.Get('inventory').RegisterHook` returns is the runtime
      substitute for the version pin fxmanifest.lua cannot express, checked
      once from an `onResourceStart` handler before this hook is ever
      registered.
    - THIS FILE owns `TrackableLog` (scent/blood/gunpowder event log) and
      the cooldown tables below as file-local state. STRUCTURAL NOTE,
      UPDATED THIS PASS (mirrors server/certifications/'s own
      "STRUCTURAL NOTE" pattern for `Certifications`): 'scent' now HAS an
      entry in `TrackableLog`, fed by the 'swapItems' ox_inventory hook
      documented in the EVENT/CALLBACK CONTRACT block above, structurally
      identical to the blood/gunpowder entries (append-only array of
      `{coords, loggedAt}`, pruned by `Config.Tracking.Scent.maxAgeSeconds`,
      queried by the same nearest-fresh-entry-within-maxRange loop in
      `findTrackableSource` below). This supersedes the OLDER version of
      this note (visible in history/diff) that said scent intentionally had
      no entry here pending a live-query design — that plan was superseded
      by DEVELOPER_REFERENCE.md#scent-source-resolution's confirmed
      registerHook-based design (see item 9 in this file's header
      AUTHORITATIVE SOURCES list) before it was ever built.
    - SCENT BRANCH STATUS, UPDATED THIS PASS: the ox_inventory
      `swapItems` hook is now confirmed (DEVELOPER_REFERENCE.md#scent-source-resolution,
      tech-scout pass, 2026-08-23 — HIGH confidence on the hook name/payload
      shape from direct source-reading, see that note's §6 confidence table)
      and wired up below. `findTrackableSource`'s 'scent' branch no longer
      special-cases `sourceCoords = nil` — see the "CONFIDENCE NOTE" on the
      `exports.ox_inventory:registerHook` call site itself for the one
      residual sliver of doubt (no independent re-verification against a
      live ox_inventory install this session, and the hook-name enum was
      not confirmed against the canonical docs site directly, both blocked
      by egress restrictions) — this is a real, disclosed confidence
      ceiling, not treated as 100% certain.
    ======================================================================
]]

-- Ephemeral, in-memory only per-type event log backing Scent/Blood/
-- Gunpowder tracking (DEVELOPER_REFERENCE.md §11.3, §11.4 items 3/4; scent's entry added
-- this pass per DEVELOPER_REFERENCE.md#scent-source-resolution — see the
-- FILE-TO-FILE CONTRACT "STRUCTURAL NOTE, UPDATED THIS PASS" above for why
-- it's now structurally identical to blood/gunpowder rather than absent) —
-- NOT persisted, mirrors server/main.lua's `LeashPairs` precedent (DEVELOPER_REFERENCE.md
-- §10 flags this precedent as still needing db-schema's confirmation, not
-- assumed settled here).
--
-- PERFORMANCE FIX (load audit, this pass -- follow-up to the ENTRY-COUNT
-- CEILING section further down): each TrackableLog.<type> is now a RING
-- BUFFER, not a plain chronologically-ordered array. { entries = {},
-- writeIndex = 0, count = 0 } -- `entries[i]` holds a live logged entry
-- ({ coords = vector3, loggedAt = <GetGameTimer() ms>, ticketIssued =
-- boolean }) at PHYSICAL slot `i`, but physical slot order stops matching
-- chronological (append) order the moment `count` first reaches this
-- type's own TRACKABLE_LOG_MAX_ENTRIES ceiling and a write wraps around --
-- see AppendTrackableLogEntry's own doc comment for why, and
-- TrackableRingLogEntriesOldestFirst for the ONLY sanctioned way to read
-- these back out in true oldest-first order. `writeIndex` is the physical
-- slot most recently written (0 before the first write ever); `count` is
-- the number of currently-live logical entries, 0..TRACKABLE_LOG_MAX_ENTRIES
-- (never higher -- the ring never grows past its own ceiling). This
-- replaced a plain array evicted via `table.remove(log, 1)` on every write
-- once at the cap -- an O(n)-per-write shape that, at this resource's own
-- documented worst case (128 players bleeding, 500ms relay floor), cost
-- roughly 2 million slot copies per second purely from eviction. The ring
-- shape here follows server/diagnostics.lua's own DecisionTrail ring-index
-- pattern (`writeIndex = (writeIndex % CAP) + 1`) exactly, per that pass's
-- own explicit instruction to reuse the in-repo pattern rather than invent a
-- new one -- see AppendTrackableLogEntry below.
-- `ticketIssued` ADDED an earlier pass (ANTI-FARM FIX, see findTrackableSource's
-- own doc comment below for the full writeup) — false at log-append time,
-- flipped true the one time (ever) this exact entry is selected as the
-- nearest match AND clears MIN_TRACK_XP_DISTANCE, i.e. the one time it is
-- ever used to mint a PendingTrackArrival ticket. Rations a single real
-- logged event to at most one XP-eligible ticket for its entire lifetime,
-- independent of how many times it is later re-resolved (cosmetically) or
-- how long it remains within maxAgeSeconds.
local TrackableLog = {
    scent = { entries = {}, writeIndex = 0, count = 0 },
    blood = { entries = {}, writeIndex = 0, count = 0 },
    gunpowder = { entries = {}, writeIndex = 0, count = 0 },
}

-- Per-(source, trackType) QUERY-side cooldown backing
-- Config.Tracking.<Type>.searchCooldownMs (DEVELOPER_REFERENCE.md §11.4 item 1). Distinct
-- from the LOGGING-side rate limits below (relayDamageEvent/
-- relayWeaponFire) — this one throttles how often a K9 can re-run
-- "Track <Type>", not how often a shooter/victim's own client can report
-- a source event.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled
-- `LastTrackQueryAt[source][trackType]` table, now a NewNestedCooldown()
-- instance (server/cooldowns.lua) — same two-level (source, trackType) key,
-- no default threshold baked in (each call site passes the relevant
-- trackingConfig.searchCooldownMs explicitly, since it varies by
-- trackType), same playerDropped-based cleanup that drops every trackType
-- for a disconnecting source in one call (see
-- TrackQueryCooldown.RegisterPlayerDropped() below), behavior unchanged.
local TrackQueryCooldown = NewNestedCooldown()
TrackQueryCooldown.RegisterPlayerDropped()

-- Per-source LOGGING-side rate limits (DEVELOPER_REFERENCE.md §11.4 items 3/4, sized by
-- the coordinator-amendment fields Config.Tracking.Blood/Gunpowder.relayCooldownMs
-- — "needs its own tight per-player rate limit... independent of, and in
-- addition to, Config.Tracking.Gunpowder's *search*-side cooldown, since
-- this is a *logging* cooldown, not a *query* cooldown"). Stamped BEFORE
-- any log-append work in both relay handlers below — this is the
-- highest-frequency-potential ingest surface in this resource
-- (CEventNetworkEntityDamage can legitimately fire multiple times per hit,
-- and a modified client can call TriggerServerEvent directly, bypassing
-- the client-side debounce entirely).
--
-- DEVELOPER_REFERENCE.md item 1: both were their own hand-rolled per-source
-- tables, now NewCooldown() instances (server/cooldowns.lua) — same
-- per-source key, same playerDropped-based cleanup, behavior unchanged.
local DamageRelayCooldown = NewCooldown()
DamageRelayCooldown.RegisterPlayerDropped()
local WeaponFireRelayCooldown = NewCooldown()
WeaponFireRelayCooldown.RegisterPlayerDropped()

-- PHASE 4 ADDITION (coder-backend, XPProgression pass) -- PendingTrackArrival[src]
-- = { trackType, coords, expiresAt, createdAt, minElapsedMs }. Backs
-- Config.XP.awards.trackSourceResolved (config.lua, DEVELOPER_REFERENCE.md §13.4.1
-- open question 3): findTrackableSource's own `found = true` reveal below
-- is deliberately NOT the XP award trigger -- awarding there would let a K9
-- farm XP by repeatedly triggering a search without ever completing it (the
-- exact gap that open question flags, explicitly left unresolved by
-- DEVELOPER_REFERENCE.md and closed here). Instead, a successful resolve stores
-- where the K9 would need to walk to, and XP is only granted once
-- 'qbx_k9unit:server:reportTrackSourceArrival' below confirms the K9's OWN
-- LIVE server-side position is within Config.XP.trackArrivalRadius of that
-- stored coordinate -- never a client-claimed distance/arrival boolean.
-- Single-slot per source (a fresh resolve overwrites any earlier pending
-- arrival for that source, mirroring server/main.lua's
-- PendingLeashRequests single-slot-per-target shape) -- plain table +
-- manual playerDropped cleanup, NOT a NewCooldown/NewMutex shape (this
-- isn't a rate limiter, it's a short-lived one-shot claim ticket), same
-- reasoning server/main.lua's own PendingLeashRequests declaration gives
-- for its own shape. `createdAt`/`minElapsedMs` ADDED this pass -- see
-- MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's own declaration comment below for the
-- economy-audit finding they close.
local PendingTrackArrival = {}

-- SECURITY FIX (coder-security finding A, this pass) -- see this file's
-- header FORGED TRAIL DECISION addendum for the full exploit writeup this
-- closes. A deliberately LOCAL implementation constant (mirrors
-- server/search.lua's own MAX_CONTAINER_RECURSION_DEPTH precedent for the
-- same "internal defensive bound, not a server-owner tuning knob" posture),
-- not a Config.* field: findTrackableSource below only creates a
-- PendingTrackArrival ticket (i.e. only makes a resolved source eligible
-- for trackSourceResolved XP at all) when the K9's OWN live distance to the
-- resolved source, AT THE MOMENT OF RESOLUTION, is at least this far --
-- otherwise arrival would already be satisfied (or nearly so) with no
-- meaningful travel required, which is exactly the stationary-farm gap
-- finding A identified. Sized well above Config.XP.trackArrivalRadius
-- (3.0 as shipped) so reaching the source from resolve-time position always
-- requires genuine, non-trivial movement -- comfortably below every
-- Config.Tracking.<Type>.maxRange default (40.0), so this does not make
-- otherwise-legitimate, genuinely-distant resolves ineligible.
local MIN_TRACK_XP_DISTANCE = 15.0

-- ECONOMY-AUDIT FIX (this pass, closing two independently-confirmed
-- trackSourceResolved XP-farm holes on top of finding A's stationary-farm
-- fix above):
--
-- HOLE 1 -- REUSABLE SOURCE: MIN_TRACK_XP_DISTANCE above only ever gated
-- whether a TICKET gets created; it never touched the underlying
-- TrackableLog ENTRY itself. A single logged event (one real gunfight, one
-- real item drop) stayed matchable by findTrackableSource's nearest-fresh-
-- entry loop for its ENTIRE maxAgeSeconds window (120-900s) -- so a K9
-- could walk MIN_TRACK_XP_DISTANCE away from that SAME still-fresh entry
-- and back, re-resolve it (once every searchCooldownMs), and re-earn
-- trackSourceResolved XP off the one real event indefinitely, turning any
-- real gunfight or item drop anywhere on the map into a recyclable piñata.
-- FIX: TrackableLog entries now carry their own `ticketIssued` flag (see
-- each log-append call site above and the TrackableLog declaration comment
-- for the full field writeup) -- findTrackableSource below marks the
-- resolved entry `ticketIssued = true` the one time it is ever used to mint
-- a ticket, and refuses to mint a second one for an already-ticketed entry.
-- The cosmetic reveal (`found = true` / `coords`) is completely unaffected
-- either way -- only ticket-minting is gated on this, same "reveal is
-- cosmetic, XP-eligibility is the real gate" split finding A already
-- established.
--
-- HOLE 2 -- NO ELAPSED-TIME REQUIREMENT: reportTrackSourceArrival below
-- only ever compared LIVE POSITION at the moment of the report against
-- `pending.coords` -- it never compared TIME. A client capable of
-- `SetEntityCoords` (teleport) could resolve a source MIN_TRACK_XP_DISTANCE
-- away (satisfying finding A's own check) and then teleport straight onto
-- it, satisfying both the distance-at-resolution AND distance-at-arrival
-- checks with zero real travel and near-zero elapsed time. FIX: every
-- ticket now also stores `createdAt` (GetGameTimer() at ticket-creation)
-- and `minElapsedMs`, computed below from the SAME server-measured
-- `nearestDist` finding A's own check already gates on -- never a
-- client-supplied value -- as `nearestDist / MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS`.
-- reportTrackSourceArrival now additionally requires real elapsed server
-- time (`GetGameTimer() - pending.createdAt`) to be at least that long
-- before paying XP. MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS below is deliberately
-- generous (well above an on-foot sprint, comparable to a patrol vehicle at
-- a brisk city-street pace) precisely so a legitimate K9 handler who
-- reaches the source quickly BY VEHICLE is never falsely blocked -- this
-- closes the "zero elapsed time" teleport case without penalizing
-- genuinely fast, genuinely real travel. Combined with HOLE 1's per-entry
-- rationing above, a farmer can no longer manufacture free tickets by
-- reusing one entry, and even a freshly-earned single ticket can no longer
-- be redeemed with a 0ms teleport-and-report round trip.
local MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS = 25.0 -- ~90 km/h -- a local implementation constant, not a Config.* field, for the same "internal defensive bound" reasoning MIN_TRACK_XP_DISTANCE's own declaration comment gives

-- Defense-in-depth rate limit on the reportTrackSourceArrival event below --
-- same "never leave a per-source ingest path fully unbounded" posture this
-- file already applies to every other event handler (DamageRelayCooldown,
-- WeaponFireRelayCooldown, ScentDropRelayCooldown). This is NOT the primary
-- anti-farm mechanism (that's PendingTrackArrival's single-use-then-cleared
-- shape below, plus TrackQueryCooldown already throttling how often a fresh
-- pending arrival can even be created) -- it just bounds how fast a client
-- can spam this specific event while a pending arrival exists but the K9
-- hasn't reached it yet.
local TrackArrivalReportCooldown = NewCooldown()
TrackArrivalReportCooldown.RegisterPlayerDropped()
local TRACK_ARRIVAL_REPORT_COOLDOWN_MS = 2000

-- SECURITY FIX (coder-backend, this pass -- correctness-pass follow-up on
-- ADDENDUM 2 above): ADDENDUM 2's `ticketIssued` + `minElapsedMs` pair closes
-- "reuse the SAME stale entry indefinitely" and "teleport for ~0ms elapsed
-- time" -- but neither one limits how FAST a brand-new, never-before-ticketed
-- TrackableLog entry can be manufactured in the first place, only what a
-- single already-existing entry can ever yield (one ticket, ever) or how
-- much real travel a single redemption requires. That gap still lets a
-- steady-state farm through both accepted-risk surfaces this file already
-- documents:
--   - Blood/Gunpowder: relayDamageEvent/relayWeaponFire are payload-less and
--     forgeable BY DESIGN (see the FORGED TRAIL DECISION above, which
--     explicitly scoped its "cosmetic-only, acceptable risk" verdict to the
--     REVEAL -- it pre-dates, and was never re-evaluated against, this XP
--     angle). A modified client can call either directly, at its own current
--     position, on nothing but that event's relayCooldownMs (300-500ms).
--   - Scent: needs NO forgery at all -- a genuine, unmodified client
--     drop/walk-15m-away/walk-back/pick-back-up loop (ordinary ox_inventory
--     actions) manufactures a fresh, never-ticketed entry every cycle.
-- Either way, the only per-cycle throttle actually binding this loop today
-- is Config.Tracking.<Type>.searchCooldownMs (5000ms shipped) -- comfortably
-- longer than MIN_TRACK_XP_DISTANCE's own real-travel floor
-- (15m / MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS = 600ms), so a farmer can sustain
-- roughly one trackSourceResolved ticket every ~5s this way: ~7,200 XP/hr at
-- the shipped 10-XP award -- HIGHER than the ~3,600-4,200 XP/hr ADDENDUM 2
-- itself already treats as a real, worth-closing problem, and reachable via
-- 'scent' by any ordinary player with zero forgery whatsoever.
--
-- FIX: one more cooldown, deliberately flat across ALL THREE trackTypes (not
-- nested by trackType the way TrackQueryCooldown is) -- gates how often THIS
-- SOURCE may ever MINT a new PendingTrackArrival ticket at all, independent
-- of which trackType, independent of how cheaply a fresh entry was produced,
-- and independent of the per-type searchCooldownMs above (which only ever
-- throttled the QUERY, never the AWARD). Consumed at the exact point a
-- ticket is minted (see the call site below) -- never at plain resolve-time,
-- so a `found = false`-or-cosmetic-only resolve (nearestDist too small, no
-- match, already-ticketed entry, or feature disabled) never spends this
-- budget. TRACK_TICKET_MINT_COOLDOWN_MS is a local implementation constant,
-- not a Config.* field -- same "internal defensive bound" posture
-- MIN_TRACK_XP_DISTANCE's and MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's own
-- declaration comments already establish for this identical economy-audit
-- context -- sized well above every Config.Tracking.<Type>.searchCooldownMs
-- default (5000ms) specifically so THIS becomes the binding constraint on
-- AWARD frequency regardless of entry-manufacturing cost, while never
-- blocking the cosmetic reveal itself (`found = true`/`coords` above is
-- entirely unaffected either way) or a single legitimate resolve-and-arrive.
local TrackTicketMintCooldown = NewCooldown()
TrackTicketMintCooldown.RegisterPlayerDropped()
local TRACK_TICKET_MINT_COOLDOWN_MS = 30000

-- EIGHTH XP-FARM FIX, CROSS-FILE POINTER (red-team-flagged compound-farm
-- follow-up, this pass): this cooldown's own 1,200 XP/hr ceiling is real and
-- unchanged, but it was never summed against server/search.lua's
-- ContrabandXpMintCooldown (1,500 XP/hr) or server/combat.lua's
-- BiteHoldXpMintCooldown/TakedownXpMintCooldown (1,200 + 1,800 XP/hr) --
-- all four keyed by the same acting player, combining to 5,700 XP/hr
-- uncapped. CLOSED by server/progression.lua's new SHARED, cross-mechanic
-- XP mint budget (XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS, consulted
-- inside AwardXP itself) -- see that file's own declaration comment for the
-- full derivation. Nothing in THIS file needed to change for that half of
-- the fix: AwardXP is the single chokepoint this file's own award call site
-- already goes through. TrackTicketMintCooldown above is KEPT, unchanged --
-- it still shapes how often THIS mechanic can mint; the shared budget in
-- server/progression.lua caps the TOTAL across mechanics.

-- Per-source rate limit on the 'swapItems' ox_inventory hook below (added
-- this pass, DEVELOPER_REFERENCE.md §9 items 11/17, DEVELOPER_REFERENCE.md#scent-source-resolution).
-- UNLIKE DamageRelayCooldown/WeaponFireRelayCooldown above, this is NOT
-- closing an anti-forgery gap — the hook is server-to-server, so
-- `payload.source` cannot be relabeled by a client to claim a drop that
-- never happened (see this file's header "NOTE — THIS DECISION DOES NOT
-- APPLY TO SCENT"). This exists purely as the same defense-in-depth this
-- file already applies to every ingest surface (never leave a per-source
-- write path fully unbounded) — bounds how fast a rapid drop/pickup/drop
-- loop can grow TrackableLog.scent between prune passes. Costs nothing
-- legitimate: multiple items dropped in the same burst are indistinguishable
-- as scent sources anyway (same coordinate, sub-second apart).
local ScentDropRelayCooldown = NewCooldown()
ScentDropRelayCooldown.RegisterPlayerDropped()

-- trackType -> the Config.Features flag gating that type, and the
-- Config.Tracking sub-table holding its tuning values. Built once at file
-- load (config.lua is a shared_script loaded before this file per
-- fxmanifest.lua's ordering) — no per-call string-casing/lookup needed.
local TRACK_TYPE_FEATURE_FLAGS = {
    scent = 'ScentTracking',
    blood = 'BloodTracking',
    gunpowder = 'GunpowderSniffing',
}
local TRACK_TYPE_CONFIG = {
    scent = Config.Tracking.Scent,
    blood = Config.Tracking.Blood,
    gunpowder = Config.Tracking.Gunpowder,
}

-- ======================================================================
-- SPECIALIZATION-SCOPED TRACKING (owner-directed decluttering pass,
-- 2026-08-26 -- see Config.SpecializationTracking's own header comment in
-- config.lua for the full plain-English writeup this implements, including
-- the deliberate MONOTONIC design -- a specialization only ever ADDS a
-- trail type, there is no "generalist fallback" that grants everything to
-- an uncertified dog).
--
-- VALIDATION (CLAMP AND WARN, never assert -- a bare top-level assert in
-- this codebase kills every registration below it silently for the whole
-- server uptime, per this resource's standing rule). Built ONCE at file
-- load into a defensive copy: any Config.SpecializationTracking entry
-- whose key is not a real Config.K9Specializations key, or whose value is
-- not an array of real TRACK_TYPE_CONFIG track-type strings, is dropped
-- (with one console warning naming the exact problem) rather than trusted
-- or asserted.
local VALIDATED_SPECIALIZATION_TRACK_TYPES = {}
do
    local rawMap = type(Config.SpecializationTracking) == 'table' and Config.SpecializationTracking or {}
    local knownSpecializations = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    for specKey, trackTypes in pairs(rawMap) do
        if knownSpecializations[specKey] == nil then
            print(('[qbx_k9unit] WARNING: Config.SpecializationTracking has an entry for %q, which is not a key in Config.K9Specializations -- ignoring it entirely (it will never unlock a track type for anyone). Fix Config.SpecializationTracking or Config.K9Specializations in config.lua to silence this warning.'):format(tostring(specKey)))
        elseif type(trackTypes) ~= 'table' then
            print(('[qbx_k9unit] WARNING: Config.SpecializationTracking[%q] must be an array of track type strings (got %s) -- ignoring it entirely.'):format(tostring(specKey), type(trackTypes)))
        else
            local validated = {}
            for _, trackType in ipairs(trackTypes) do
                if trackType == 'scent' then
                    print(('[qbx_k9unit] WARNING: Config.SpecializationTracking[%q] lists \'scent\', which can never be specialization-gated (it is the base capability every K9-access handler already has -- see that config field\'s own header comment) -- ignoring just this entry.'):format(tostring(specKey)))
                elseif TRACK_TYPE_CONFIG[trackType] then
                    validated[#validated + 1] = trackType
                else
                    print(('[qbx_k9unit] WARNING: Config.SpecializationTracking[%q] lists unknown track type %q -- ignoring it (valid: blood, gunpowder).'):format(tostring(specKey), tostring(trackType)))
                end
            end
            if #validated > 0 then
                VALIDATED_SPECIALIZATION_TRACK_TYPES[specKey] = validated
            end
        end
    end
end

--- Resolves the set of Track <Type> trail types `citizenid` may search for
--- through the ONE merged tracking action (findNearestTrackableSource
--- below), and also used to re-validate the OLDER single-type
--- findTrackableSource callback further down so a client cannot bypass
--- this gate by calling that event directly with an unlisted trackType.
---
--- 'scent' is unconditionally true -- see VALIDATED_SPECIALIZATION_TRACK_TYPES'
--- own header and Config.SpecializationTracking's config.lua comment for why
--- it can never be gated. Every OTHER track type is enabled if AND ONLY IF
--- `citizenid` currently holds a specialization Config.SpecializationTracking
--- maps to it (HasSpecialization, server/certifications/ -- carries that
--- function's own High Command bypass, so a high-command officer with no
--- personally-granted specialization still gets every track type).
---
--- DELIBERATELY NOT MONOTONIC-BROKEN: there is NO "citizenid holds zero
--- specializations -> enable everything" branch here (that was an earlier,
--- rejected design -- see config.lua's own header for the full "make it
--- more fluid" writeup). Adding a specialization can only ever turn a
--- `false`/absent entry into `true` for this citizenid; it can never turn
--- an already-true entry back to false. A citizenid with zero specializations
--- gets exactly `{ scent = true }` -- the same baseline every dog already
--- has today, nothing more, nothing less.
--- @param citizenid string
--- @param jobName string?
--- @return table<string, boolean> enabled -- e.g. { scent = true, blood = true }
local function ResolveEnabledTrackTypesForCitizenId(citizenid, jobName)
    local enabled = { scent = true } -- base capability, NEVER gated -- see this function's own doc comment

    -- ROLES (server/roles.lua): a trail type is on when a held, unlocked
    -- role has track_<type>. Replaces the fixed specialization -> trail
    -- mapping below whenever the roles module is loaded.
    if type(GetHeldRoleUnlocks) == 'function' and type(citizenid) == 'string' then
        for unlock in pairs(GetHeldRoleUnlocks(citizenid, jobName)) do
            local trackType = unlock:match('^track_(.+)$')
            if trackType then enabled[trackType] = true end
        end
        return enabled
    end

    -- Soft dependency, this resource's established `type(...) == 'function'`
    -- convention (server/equipmentshop.lua's own HasSpecialization call
    -- site) -- if server/certifications/ is ever unavailable, this
    -- simply resolves to "no specializations held," i.e. the same
    -- `{ scent = true }` baseline, never an error.
    if type(HasSpecialization) == 'function' and type(citizenid) == 'string' then
        for specKey, trackTypes in pairs(VALIDATED_SPECIALIZATION_TRACK_TYPES) do
            if HasSpecialization(citizenid, jobName, specKey) then
                for _, trackType in ipairs(trackTypes) do
                    enabled[trackType] = true
                end
            end
        end
    end

    return enabled
end

-- ======================================================================
-- ENTRY-COUNT CEILING (performance audit at 128 players, this pass --
-- coder-backend). PruneTrackableLogs further down only ever enforced an AGE
-- limit (Config.Tracking.<Type>.maxAgeSeconds) -- exactly the gap that
-- function's own former doc comment flagged and invited a look at ("flag
-- for resource-performance-profiler if real entry-count numbers under load
-- ever suggest otherwise"). They did: worked out from this resource's OWN
-- shipped relayCooldownMs/maxAgeSeconds pairs, ONE continuously-active
-- player can push Blood to 600 entries (300s / 500ms), Gunpowder to 400
-- (120s / 300ms), and Scent to 900 (900s / 1000ms) before their own oldest
-- entry ages out. At 128 players sustaining that simultaneously -- a busy
-- roleplay server's normal evening of full-server combat, not an
-- adversarial edge case -- that is up to 76,800 / 51,200 / 115,200 entries
-- (roughly 243,000 total, 35-50MB), by far the largest structure in this
-- resource (everything else here is single-digit KB). Two consequences:
-- PruneTrackableLogs' own full linear rebuild (every
-- TRACKABLE_LOG_PRUNE_INTERVAL_MS, 15s) would be doing up to ~243,000 table
-- inserts every pass, and findTrackableSource's own nearest-match scan
-- further down would be linearly scanning a log that size on every single
-- "Track <Type>" request.
--
-- FIX: each Config.Tracking.<Type> table now also carries its own
-- `maxLoggedEntries` -- a HARD, ABSOLUTE ceiling, entirely independent of
-- maxAgeSeconds/relayCooldownMs (see each field's own config.lua comment
-- for the full per-type arithmetic and the specific default chosen).
-- Resolved ONCE here, at file-load time, into TRACKABLE_LOG_MAX_ENTRIES
-- below -- the same "hand-edit-only setting, resolved once, never re-read
-- live" posture this resource already uses for its TICK_INTERVAL_MS-shaped
-- fields (e.g. server/wellbeing.lua), and deliberately NOT the "re-read
-- fresh on every call" posture this file's own ScentVision section uses
-- further down -- there is no tablet/RuntimeFeatureControl path that can
-- reach this field live, so resolving once here avoids re-validating (and
-- re-warning) on every single write instead of once at startup.
--
-- Enforced on EVERY write via AppendTrackableLogEntry below, oldest entry
-- evicted first -- the exact same discard-on-write shape this file's own
-- ScentVision section's RecordScentVisionPoint already uses successfully
-- for maxPointsPerPerson (see that function's own doc comment further
-- down), applied here to the whole server's shared per-type log instead of
-- one person's trail. Deliberately NEVER drops the newest entry to make
-- room -- the newest entry is exactly the one a dog is most likely to be
-- tracking, so eviction always takes the oldest, never the newest.
--
-- PERFORMANCE FIX, LATER PASS (load audit): the sentence this comment used
-- to have here -- "the log is naturally in chronological-append order... so
-- the OLDEST entry is always at index 1" -- described the ORIGINAL
-- implementation (a plain array, evicted via `table.remove(log, 1)`), which
-- is no longer how this works: TrackableLog.<type> is now a ring buffer
-- (AppendTrackableLogEntry below), and physical index 1 stops being the
-- oldest entry the moment a log first wraps. "Oldest evicted first" is still
-- exactly true LOGICALLY -- see AppendTrackableLogEntry's and
-- TrackableRingLogEntriesOldestFirst's own doc comments for how the ring
-- preserves that guarantee in O(1) without needing entries to sit in
-- chronological PHYSICAL order at all.
-- ======================================================================

--- ======================================================================
--- UPPER CEILING (performance audit at 128 players, this pass -- follow-up
--- to the ENTRY-COUNT CEILING above). maxLoggedEntries closed the unbounded
--- growth problem, but ResolveTrackableLogMaxEntries below used to enforce
--- ONLY a `>= 1` floor -- no ceiling at all. Every field this whole ceiling
--- exists to bound is hand-edit-only (§ header above: "deliberately NOT
--- tablet-editable"), so an owner who opens config.lua and sets
--- maxLoggedEntries back up to, say, 250000 "to be safe" would put the
--- EXACT 243,000-entry / 35-50MB problem this ceiling was built to close
--- straight back -- with the ceiling mechanism itself now actively
--- laundering that mistake through, since ResolveTrackableLogMaxEntries
--- would accept it as "a valid number >= 1" without comment.
---
--- ARITHMETIC (not a round number picked by feel): this file's own
--- combined-total comment a few lines above already establishes this
--- codebase's own working estimate for one TrackableLog entry --
--- 20,000 combined entries costing roughly 3-4MB, i.e. ~150-200
--- bytes/entry (`{ coords = vector3, loggedAt = number, ticketIssued =
--- boolean }`, a small STRING-keyed table, not a cheap array-style one).
--- Using 200 bytes/entry (the upper, more conservative end of that same
--- established range) as the basis here rather than inventing a fresh
--- estimate:
---   MAX_LOGGED_ENTRIES_CEILING (50,000 per type) x 200 bytes
---     = ~10MB for ONE type at its ceiling.
---   All three types (Scent + Blood + Gunpowder) simultaneously cranked to
--- this ceiling at once (the actual worst case this clamp has to bound,
--- since nothing stops an operator raising all three): 150,000 entries x
--- 200 bytes = ~30MB total -- comfortably below the 35-50MB figure this
--- resource's own audit measured for the ORIGINAL uncapped bug at 128
--- players (a real reduction, not just "still bad but now a round number"),
--- while still leaving every shipped default (6,000 / 8,000 / 6,000 --
--- 12-16% of this ceiling) enormous headroom to be raised for a genuinely
--- bigger or busier deployment than the 128-player baseline this pass's own
--- numbers are computed from, without ever tripping this warning on a
--- reasonable config.
--- ======================================================================
local MAX_LOGGED_ENTRIES_CEILING = 50000

--- CLAMP-AND-WARN for a Config.Tracking.<Type>.maxLoggedEntries value --
--- same posture this resource applies to every operator-editable Config
--- field: never throw, print one clear line naming the exact key and what
--- was substituted, and keep this file loading. A count (not a millisecond
--- threshold), so this deliberately does NOT go through
--- server/cooldowns.lua's ResolveConfiguredThresholdMs -- mirrors
--- ResolveScentVisionNumber further down in this same file (also a plain
--- count/distance floor, not a threshold), reimplemented locally with
--- wording specific to THIS field rather than reused, for the same
--- "cooldown-specific/ScentVision-specific wording would be misleading
--- here" reason server/certifications/'s own
--- ResolveConfiguredPositiveNumber doc comment already gives for not
--- calling a differently-worded sibling function directly.
---
--- UPPER CEILING added this pass -- see MAX_LOGGED_ENTRIES_CEILING's own
--- declaration comment immediately above for the full worked arithmetic
--- behind the 50,000 figure and why this field needed one at all (it is
--- the one Config value that can single-handedly reintroduce the exact
--- unbounded-growth incident this whole ceiling mechanism exists to close).
--- @param configuredValue any
--- @param fallback number -- a positive, hardcoded call-site literal (this file's own shipped default for the field), never itself read from Config
--- @param configKeyName string
--- @return number
local function ResolveTrackableLogMaxEntries(configuredValue, fallback, configKeyName)
    if type(configuredValue) ~= 'number' or configuredValue ~= configuredValue or configuredValue < 1 then
        print(
            ('[qbx_k9unit] tracking.lua: %s must be a number >= 1 (found: %s). This log would otherwise have no ' ..
             'absolute ceiling at all -- Config.Tracking.<Type>.maxAgeSeconds is an AGE limit, not a COUNT limit, ' ..
             'and cannot substitute for one. Using the built-in fallback of %s instead so this log stays bounded ' ..
             'while the config is fixed -- find %s in config.lua and set it to a positive number.')
                :format(configKeyName, tostring(configuredValue), tostring(fallback), configKeyName)
        )
        return fallback
    end
    if configuredValue > MAX_LOGGED_ENTRIES_CEILING then
        print(
            ('[qbx_k9unit] tracking.lua: %s (%s) exceeds this resource\'s own %d-entry ceiling -- see ' ..
             'MAX_LOGGED_ENTRIES_CEILING\'s own declaration comment in this file for the worked memory arithmetic ' ..
             '(a value this high risks reintroducing the exact unbounded-growth memory problem this field was ' ..
             'added to close: ~243,000 entries / 35-50MB at 128 players sustaining full combat). Clamping to %d ' ..
             'instead so this log stays bounded -- find %s in config.lua and lower it if this warning should not ' ..
             'be appearing.')
                :format(configKeyName, tostring(configuredValue), MAX_LOGGED_ENTRIES_CEILING, MAX_LOGGED_ENTRIES_CEILING, configKeyName)
        )
        return MAX_LOGGED_ENTRIES_CEILING
    end
    return configuredValue
end

-- Resolved ONCE, at file-load time -- see the ENTRY-COUNT CEILING header
-- above for why this is not re-read live the way ScentVision's own settings
-- are. Defaults chosen generously above real usage while still bounding the
-- worst case -- see each field's own config.lua comment for the exact
-- arithmetic.
local TRACKABLE_LOG_MAX_ENTRIES = {
    scent     = ResolveTrackableLogMaxEntries(Config.Tracking.Scent.maxLoggedEntries, 6000, 'Config.Tracking.Scent.maxLoggedEntries'),
    blood     = ResolveTrackableLogMaxEntries(Config.Tracking.Blood.maxLoggedEntries, 8000, 'Config.Tracking.Blood.maxLoggedEntries'),
    gunpowder = ResolveTrackableLogMaxEntries(Config.Tracking.Gunpowder.maxLoggedEntries, 6000, 'Config.Tracking.Gunpowder.maxLoggedEntries'),
}

--- PERFORMANCE FIX (load audit, this pass): appends `entry` to `ringLog`
--- (one of TrackableLog.scent/blood/gunpowder) in O(1), REPLACING the former
--- O(n)-per-write shape (`log[#log+1] = entry; while #log > maxEntries do
--- table.remove(log, 1) end`) -- `table.remove(t, 1)` shifts every remaining
--- element down by one, so once a log is saturated at its cap (8000 for
--- Blood, 6000 each for Scent/Gunpowder), EVERY write was paying for a full
--- shift of up to that many slots. At this resource's own documented worst
--- case (128 players bleeding, Blood's 500ms relay floor) that was roughly 2
--- million slot copies per second purely from eviction.
---
--- Follows server/diagnostics.lua's own DecisionTrail ring-index pattern
--- exactly (`writeIndex = (writeIndex % CAP) + 1`) -- the SAME formula is
--- correct whether `ringLog` is still filling up for the first time
--- (`count < maxEntries`) or has already wrapped and is now overwriting old
--- slots in place (`count == maxEntries`): once full, the physical slot
--- about to be written is ALWAYS exactly the slot holding the current
--- oldest live entry (see TrackableRingLogEntriesOldestFirst below for why),
--- so eviction is not a separate step at all here -- it is a side effect of
--- the write itself, at zero extra cost. Physical slot order does NOT match
--- chronological order once `ringLog` has wrapped -- see
--- TrackableRingLogEntriesOldestFirst below for the only sanctioned way to
--- read these back out in true oldest-first order; every consumer of
--- TrackableLog.scent/blood/gunpowder (PruneTrackableLogs and
--- FindNearestFreshTrackableEntry, the only two in this file) goes through
--- it, never a raw `ipairs`/`#ringLog` on the ring itself.
--- @param ringLog table -- TrackableLog.scent | .blood | .gunpowder -- { entries, writeIndex, count }
--- @param entry table -- { coords, loggedAt, ticketIssued }
--- @param maxEntries number -- this exact type's TRACKABLE_LOG_MAX_ENTRIES[trackType] -- must be the SAME value on every call for a given ringLog, or the physical/logical mapping breaks
local function AppendTrackableLogEntry(ringLog, entry, maxEntries)
    ringLog.writeIndex = (ringLog.writeIndex % maxEntries) + 1
    ringLog.entries[ringLog.writeIndex] = entry
    if ringLog.count < maxEntries then
        ringLog.count = ringLog.count + 1
    end
end

--- Iterates `ringLog`'s currently-live entries OLDEST FIRST, in true
--- chronological (append) order -- REQUIRED reading for both of this file's
--- own TrackableLog consumers (PruneTrackableLogs' age filter and
--- FindNearestFreshTrackableEntry's nearest-match scan) now that
--- AppendTrackableLogEntry above overwrites slots in place once a log has
--- wrapped: the physical `entries` array stops being in append order at
--- that point (e.g. cap 3, 4 appends -- physical slot 1 now holds the
--- 4th/newest entry, not the 1st), so a plain `ipairs(ringLog.entries)`
--- would silently visit entries in the WRONG order -- among other things,
--- flipping FindNearestFreshTrackableEntry's own documented "ties keep the
--- OLDEST-encountered entry" behavior (`dist < nearestDist`, strict) into
--- "ties keep whatever happens to sit in the lowest physical slot", which is
--- not the same guarantee at all once wrapped.
---
--- When `count < maxEntries` (never wrapped yet), physical slot 1 already
--- IS the oldest entry, so the walk starts there. Once `count == maxEntries`
--- (wrapped at least once), the physical slot about to be overwritten NEXT
--- (`(writeIndex % maxEntries) + 1`, the exact same expression
--- AppendTrackableLogEntry itself just used to pick where it wrote) is
--- always exactly the current oldest live entry -- so that is where this
--- walk starts, then wraps forward through every other live slot exactly
--- once. O(1) per `next()` call, O(n) total for a full walk -- the SAME
--- total complexity a plain `ipairs` walk over the old plain array always
--- had; this changes WHICH slot order is visited, not how much work a full
--- walk costs (this file's own periodic PruneTrackableLogs sweep, and each
--- individual findTrackableSource query's own nearest-match scan, both stay
--- exactly as expensive as before -- only the O(n)-per-WRITE cost is what
--- this pass closes).
--- @param ringLog table -- TrackableLog.scent | .blood | .gunpowder
--- @param maxEntries number -- this type's ceiling (TRACKABLE_LOG_MAX_ENTRIES[trackType]) -- MUST match what AppendTrackableLogEntry was called with for this ringLog
--- @return fun(): number?, table? -- use with a generic `for _, entry in TrackableRingLogEntriesOldestFirst(...) do`
local function TrackableRingLogEntriesOldestFirst(ringLog, maxEntries)
    local count = ringLog.count
    local startIndex = (count < maxEntries) and 1 or ((ringLog.writeIndex % maxEntries) + 1)
    local i = 0
    return function()
        i = i + 1
        if i > count then return nil end
        local physicalIndex = ((startIndex - 1 + i - 1) % maxEntries) + 1
        return i, ringLog.entries[physicalIndex]
    end
end

-- Prune pass interval. Deliberately well under the shortest maxAgeSeconds
-- in play (Gunpowder's 120s, "residue is time-sensitive") so a stale entry
-- never lingers past its window by more than this margin — an
-- implementation detail, not a spec-mandated number (DEVELOPER_REFERENCE.md §11.4 items
-- 3/4 only require that pruning happen on some periodic interval).
local TRACKABLE_LOG_PRUNE_INTERVAL_MS = 15000

--- Drops any TrackableLog.scent/blood/gunpowder entry older than that
--- type's Config.Tracking.<Type>.maxAgeSeconds. Rebuilds each type's ring
--- via a single linear pass, walked OLDEST FIRST via
--- TrackableRingLogEntriesOldestFirst (never a raw `ipairs`/`pairs` over the
--- ring's own physical `entries` array -- see that function's own doc
--- comment for why physical slot order cannot be trusted directly once a
--- ring has wrapped). RESOLVED, an earlier pass (performance audit at 128
--- players): this comment used to end with "cheap relative to how
--- infrequently this runs and how small these logs are expected to stay on
--- a normal server (flag for resource-performance-profiler if real
--- entry-count numbers under load ever suggest otherwise)" -- that
--- profiling happened, the worst case WAS real (up to ~243,000 entries
--- across all three logs, see the ENTRY-COUNT CEILING section above), and
--- that pass closed it: AppendTrackableLogEntry enforces
--- TRACKABLE_LOG_MAX_ENTRIES on every write, so this rebuild's own worst
--- case is bounded by that same ceiling regardless of population or combat
--- duration, not just by how infrequently this thread happens to run.
--- This pass's OWN fix (converting AppendTrackableLogEntry to an O(1)
--- ring-buffer write, see that function's doc comment) does not touch this
--- function's own complexity -- PruneTrackableLogs already only ran once per
--- TRACKABLE_LOG_PRUNE_INTERVAL_MS (15s), never per write, so its O(n)
--- periodic rebuild was never the "2 million slot copies per second"
--- problem the write path was; it still fully rebuilds each type's ring
--- into a fresh, freshly-compacted one every pass (age-based pruning can
--- drop entries from the MIDDLE of the live set, unlike cap eviction, so a
--- full rebuild is the simplest correct way to re-derive a clean ring
--- afterward) -- the rebuilt ring's `writeIndex`/`count` are set to exactly
--- describe that fresh, compact set, so the very next AppendTrackableLogEntry
--- call resumes correctly whether or not this type is still below its cap.
--- @param ringLog table -- TrackableLog.scent | .blood | .gunpowder
--- @param maxEntries number -- TRACKABLE_LOG_MAX_ENTRIES[trackType] for this ringLog
--- @param maxAgeMs number
--- @param now number
local function PruneOneTrackableRingLog(ringLog, maxEntries, maxAgeMs, now)
    local fresh = {}
    for _, entry in TrackableRingLogEntriesOldestFirst(ringLog, maxEntries) do
        if (now - entry.loggedAt) < maxAgeMs then
            fresh[#fresh + 1] = entry
        end
    end
    ringLog.entries = fresh
    ringLog.writeIndex = #fresh
    ringLog.count = #fresh
end

local function PruneTrackableLogs()
    local now = GetGameTimer()

    PruneOneTrackableRingLog(TrackableLog.scent, TRACKABLE_LOG_MAX_ENTRIES.scent, Config.Tracking.Scent.maxAgeSeconds * 1000, now)
    PruneOneTrackableRingLog(TrackableLog.blood, TRACKABLE_LOG_MAX_ENTRIES.blood, Config.Tracking.Blood.maxAgeSeconds * 1000, now)
    PruneOneTrackableRingLog(TrackableLog.gunpowder, TRACKABLE_LOG_MAX_ENTRIES.gunpowder, Config.Tracking.Gunpowder.maxAgeSeconds * 1000, now)
end

CreateThread(function()
    while true do
        Wait(TRACKABLE_LOG_PRUNE_INTERVAL_MS)
        PruneTrackableLogs()
    end
end)

--- DEVELOPER_REFERENCE.md §11.4 item 3. Triggered by a client's own `gameEventTriggered`
--- ('CEventNetworkEntityDamage') handler, filtered CLIENT-SIDE to "local
--- player is the victim" (confirmed real pattern,
--- DEVELOPER_REFERENCE.md#tracking §0 — `data[1]` is the
--- cross-source-corroborated victim entity handle). Takes no meaningful
--- payload by design — do not add a coordinate argument later (see this
--- file's header FILE-TO-FILE CONTRACT / DEVELOPER_REFERENCE.md#tracking
--- §3 item 2's explicit warning that this is an easy regression).
---
--- CAVEAT (DEVELOPER_REFERENCE.md#tracking §0): `CEventNetworkEntityDamage`
--- does NOT fire for script-applied damage (only organic gameplay damage —
--- real weapon hits, falls, vehicle impacts, melee). Not a bug to fix here,
--- just a documented gap worth this comment so a future "why didn't blood
--- tracking pick this up" report isn't mysterious.
---
--- ACCEPTED RISK, not an oversight — see this file's header "FORGED TRAIL
--- DECISION": relayCooldownMs below throttles the RATE a modified client
--- can call this event directly (skipping the "am I really the victim"
--- filter entirely) but cannot prevent it outright. Deliberately not
--- corroborated further.
RegisterNetEvent('qbx_k9unit:server:relayDamageEvent', function()
    local src = source

    if not Config.Features.BloodTracking then return end -- silent no-op, per DEVELOPER_REFERENCE.md §3

    -- LOGGING-side rate limit — stamped BEFORE any log-append work (see
    -- DamageRelayCooldown's own doc comment above for why this ordering
    -- matters on this specific ingest surface).
    local now = GetGameTimer()
    if not DamageRelayCooldown.Consume(src, Config.Tracking.Blood.relayCooldownMs, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    AppendTrackableLogEntry(TrackableLog.blood, {
        coords = GetEntityCoords(ped), -- NEVER a client-supplied coordinate
        loggedAt = now,
        ticketIssued = false, -- ANTI-FARM FIX (this pass) -- see findTrackableSource's own comment on this field for the full writeup
    }, TRACKABLE_LOG_MAX_ENTRIES.blood) -- ENTRY-COUNT CEILING (this pass) -- see that table's own declaration comment
end)

--- DEVELOPER_REFERENCE.md §11.4 item 4. Triggered by a client on a debounced local
--- false->true transition of IsPedShooting(PlayerPedId()) (confirmed
--- real, stable native — DEVELOPER_REFERENCE.md#tracking §0 "adjacent
--- check", DEVELOPER_REFERENCE.md#tracking §2 Option A). Takes no
--- meaningful payload — same "never trust a client-supplied coordinate"
--- rule as relayDamageEvent above.
---
--- NOTE: `IsPedShooting`'s exact per-round vs. per-burst semantics are
--- UNCONFIRMED this session (DEVELOPER_REFERENCE.md#tracking
--- §2.3) — a high-fire-rate weapon could generate many debounced
--- transitions in a short window even with client-side debouncing, so this
--- server-side rate limit does not assume the client-side debounce alone
--- is sufficient.
---
--- ACCEPTED RISK, not an oversight — see this file's header "FORGED TRAIL
--- DECISION": same as relayDamageEvent above, relayCooldownMs throttles
--- rate, not possibility, of a modified client calling this directly with
--- no real shot fired. Deliberately not corroborated further (e.g. against
--- an ammo-consumption delta) — see the header for why.
RegisterNetEvent('qbx_k9unit:server:relayWeaponFire', function()
    local src = source

    if not Config.Features.GunpowderSniffing then return end -- silent no-op, per §3

    -- LOGGING-side rate limit — stamped BEFORE any log-append work, SEPARATE
    -- from Config.Tracking.Gunpowder.searchCooldownMs (§11.4 item 4's
    -- explicit distinction between query-side and logging-side cooldowns).
    local now = GetGameTimer()
    if not WeaponFireRelayCooldown.Consume(src, Config.Tracking.Gunpowder.relayCooldownMs, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    AppendTrackableLogEntry(TrackableLog.gunpowder, {
        coords = GetEntityCoords(ped), -- NEVER a client-supplied coordinate
        loggedAt = now,
        ticketIssued = false, -- ANTI-FARM FIX (this pass) -- see findTrackableSource's own comment on this field for the full writeup
    }, TRACKABLE_LOG_MAX_ENTRIES.gunpowder) -- ENTRY-COUNT CEILING (this pass) -- see that table's own declaration comment
end)

--- RUNTIME CAPABILITY CHECK (coordinator decision, 2026-08-24) for the
--- ox_inventory `registerHook` export the 'swapItems' hook below depends on.
--- fxmanifest.lua's `dependencies` block has NO version-constraint syntax at
--- all (confirmed against FiveM's own manifest-parsing source): a
--- dependency string is only ever a constraint when it begins with '/', and
--- the sole defined forms are '/server:BUILD', '/onesync', '/gameBuild:BUILD',
--- '/native:0xHASH' — none of which can pin a DEPENDENT resource's own
--- exports surface. So `dependencies { 'ox_inventory' }` alone cannot
--- guarantee `registerHook` exists on whatever `ox_inventory` actually ends
--- up running — a stale pinned build predating hook support, or a fork that
--- renamed/dropped it, both look identical to fxmanifest.lua. A RUNTIME
--- check is the only thing that can actually confirm it, and is strictly
--- better anyway: a fork can self-declare any version string regardless of
--- its real capabilities, so a version pin (even if the syntax existed)
--- would have been no more trustworthy than this.
---
--- `GetResourceState(...) ~= 'started'` is checked FIRST and treated as an
--- unconditional "unavailable": accessing `exports.ox_inventory` at all on a
--- resource that is not started can itself throw a Lua error (not merely
--- return nil), so this must gate BEFORE any export access is attempted —
--- never be inferred from one.
---
--- The second check deliberately only INDEXES `exports.ox_inventory.registerHook`
--- — it never CALLS it. Calling it is what performs ox_inventory's real
--- hook-registration side effect, so a disposable "probe" call (e.g.
--- registering a throwaway hook just to see if it succeeds) would leave a
--- live, orphaned hook registered forever just to answer this yes/no
--- question — deliberately not done here. The surrounding `pcall` is
--- defense-in-depth against `exports.ox_inventory` itself throwing (see the
--- `GetResourceState` note above — kept as a second layer even with that
--- pre-check in place, the same "never trust a single layer" posture this
--- file already applies everywhere else, e.g. DamageRelayCooldown/
--- WeaponFireRelayCooldown/ScentDropRelayCooldown all being independent
--- per-surface rate limits rather than one shared one).
---
--- HONEST CONFIDENCE NOTE: indexing (not calling) an export is understood,
--- from FiveM's documented exports behavior, to always return a callable
--- wrapper function regardless of whether the target resource actually
--- registered that export name — the real "does it exist" answer is only
--- resolved when the wrapper is CALLED. This was not independently
--- re-verified against FiveM's Lua scripting-runtime source this session
--- (only the fxmanifest.lua dependency-constraint parsing was verified
--- against engine source — a different subsystem). Given that, this
--- indexing check's practical value is mostly as a defensive belt against
--- `exports.ox_inventory` itself erroring (the GetResourceState race noted
--- above); it is NOT guaranteed to catch every case of `registerHook`
--- being absent from an otherwise-started `ox_inventory` (e.g. a fork that
--- removed the hooks module entirely but is still `GetResourceState`
--- `'started'`) — disclosed here rather than silently assumed airtight.
---
--- COMPAT-LAYER MIGRATION (this pass, coder-backend): this whole function is
--- DELETED, not kept alongside a new call, and every word of reasoning
--- above is preserved here (not deleted with it) because it is EXACTLY the
--- reasoning `IsResourceExportCapable` in shared/compat/inventory.lua now
--- implements generically, per-adapter, for WHATEVER inventory backend
--- Config.Compat actually resolved — same order (`GetResourceState(...) ==
--- 'started'` checked first, unconditionally, before any export access is
--- attempted), same shape (a pcall'd INDEX, never a probe CALL), same
--- disclosed honesty limit (indexing an export cannot prove a specific
--- name truly exists on FXServer, only that accessing it didn't throw). A
--- second, ox_inventory-only copy of this exact check would have answered
--- the wrong question on any other backend (ox_inventory not started ->
--- always `false`, even when e.g. qb-inventory's own real hook mechanism IS
--- available) — this is the identical REFACTOR_ROADMAP duplicate
--- server/inventory.lua's own header already flagged for its byte-for-byte
--- copy of this same function, now resolved on both sides by routing
--- through the shared adapter layer instead of keeping either local copy.
--- `RegisterScentInventoryHook` below now reads `K9Compat.Get('inventory').RegisterHook`'s
--- own boolean return value in place of this function's result, preserving
--- the exact "warn once, feature stays cleanly inert" behavior this file's
--- own doc comment below already documents.

--- DEVELOPER_REFERENCE.md §9 items 11/17. GATED AT REGISTRATION (this pass) on BOTH
--- Config.Features.ScentTracking AND the routed `RegisterHook` call's own
--- boolean return below (see the migration note above this doc comment) —
--- matches this resource's established "config-gated registration, not
--- just config-gated behavior" convention (client/vision.lua's `if
--- Config.Features.ThermalVision then RegisterCommand(...) end`,
--- server/admin.lua's/server/combat.lua's own `onResourceStart`-gated
--- blocks below this comment mirrors): if the feature flag is off,
--- `K9Compat.Get('inventory').RegisterHook` is never called at all — not
--- registered-then-early-returning inside its own callback body the way
--- relayDamageEvent/relayWeaponFire above stay registered and check
--- Config.Features internally (those are payload-less RegisterNetEvent
--- handlers with no equivalent "leave something live in another resource"
--- cost to avoiding; registering this hook when it should not exist at all
--- is exactly that cost, hence the different shape here).
---
--- Wrapped in `onResourceStart` (THIS resource's own start, per the
--- `GetCurrentResourceName() ~= resourceName` guard — same idiom as
--- server/combat.lua's PropDragging warning and server/admin.lua's command
--- registration) rather than run at bare top-level file-load time, so this
--- is an explicit, one-time "at resource start" checkpoint distinct from
--- mere script-load ordering. Fires exactly once per resource start
--- (`onResourceStart` only ever fires once for a given start), does not
--- poll, and is safe to run this late: ox_inventory is a hard
--- `dependencies` entry in fxmanifest.lua, so it is already running (or
--- knowably not) well before this resource's own `onResourceStart` fires —
--- no player-facing drop can occur before this resource itself has finished
--- starting anyway, so nothing is missed by not registering at bare
--- file-load time instead.
---
--- ON FAILURE (ScentTracking enabled but RegisterHook returns false):
--- prints ONE warning naming ox_inventory, the missing `registerHook`
--- capability, and the exact consequence ("scent tracking disabled"), then
--- leaves the feature genuinely inert — TrackableLog.scent simply never
--- receives an entry (nothing ever calls the hook body below), so
--- findTrackableSource's 'scent' branch always falls through to
--- `{ found = false }` further down, exactly as if no scent source had ever
--- existed. Deliberately NOT an `assert`: this resource reserves hard
--- asserts for actively-dangerous states. (An earlier revision of this
--- sentence cited "server/certifications/'s two, both access-control
--- invariants". That file contains ZERO asserts -- the claim appears to have
--- conflated it with certifications.lua's two REVOKE PATHS, a different
--- "two" entirely. The real inventory is 25 assert sites across 8 files,
--- each either behind a default-false feature flag or validating a config
--- value config.lua already ships in the safe shape. Corrected because this
--- wrong claim was read as fact and fed straight into a review brief.) — a missing hook here makes the feature
--- silently INERT, never silently EXPLOITABLE, so blocking this entire
--- resource's startup over one disabled-by-default cosmetic feature would
--- be a disproportionate response, mirroring server/combat.lua's own
--- PropDragging warning's identical "enabled but underlying
--- capability/config is missing -> loud warning, not a hard stop" reasoning.
---
--- Confirmed real mechanism otherwise unchanged from the original
--- implementation, DEVELOPER_REFERENCE.md#scent-source-resolution §2/§4
--- (tech-scout pass, 2026-08-23): `swapItems` fires SERVER-SIDE,
--- synchronously, on every slot-to-slot item move ox_inventory processes
--- (trunk/stash transfers, giving an item to another player, AND dropping
--- an item on the ground) — `payload.toType == 'drop'` below isolates
--- specifically a drop-to-ground action from the other move types.
---
--- UNLIKE relayDamageEvent/relayWeaponFire above, this is NOT a
--- client-triggerable event at all — ox_inventory calls this hook
--- server-to-server, and `payload.source` is ox_inventory's own resolved
--- `source` for the underlying request (the same trust level as any
--- RegisterNetEvent's ambient `source` global — cannot be relabeled by the
--- client to claim a different player dropped the item). This is why the
--- "FORGED TRAIL DECISION" in this file's header does NOT apply to scent —
--- see the header's own note on this. `ScentDropRelayCooldown` below is
--- NOT closing an anti-forgery gap; it is the same "never leave a
--- per-source write path fully unbounded" defense-in-depth this file
--- already applies to every other ingest surface (see that cooldown's own
--- declaration comment above).
---
--- CONFIDENCE NOTE (honest grading, not independently re-verified against a
--- live ox_inventory install this session — full breakdown in
--- DEVELOPER_REFERENCE.md#scent-source-resolution §2/§6): HIGH confidence the hook
--- name/payload shape (`source`, `toType`, `dropId`) is real and current —
--- corroborated two independent ways this session (direct read of
--- `modules/inventory/server.lua`'s `dropItem` function's own
--- `TriggerEventHooks('swapItems', {...})` call site, plus an independent
--- doc-snippet example registration). NOT independently confirmed: the
--- complete, current, version-pinned hook-name enum was never fetched from
--- the canonical docs site (`overextended.dev`/`coxdocs.dev`, both blocked
--- by this environment's egress proxy every time this was checked this
--- session) — a future ox_inventory version renaming/restructuring
--- `swapItems` cannot be ruled out with 100% certainty from source-reading
--- alone. The note's own recommended one-time mitigation (log
--- `json.encode(payload)` once in dev against the actual target-server
--- ox_inventory version to confirm field names before relying on this in
--- production) has NOT been performed as part of this implementation pass —
--- flagging explicitly rather than silently skipping it, so whoever
--- deploys this does it once before going live.
--- Pulled out to a named function (this pass) so it can be invoked from BOTH
--- lifecycle points below — THIS resource's own `onResourceStart` (the
--- original, only call site before this pass) and, NEW this pass,
--- ox_inventory's OWN `onResourceStart` — see the `AddEventHandler` below
--- this function for why the second call site is needed. Behavior at each
--- individual call is completely unchanged from the original single-call-site
--- version.
-- COMPAT-LAYER MIGRATION + STUB-DEGRADE ANALYSIS (coder-backend, this pass):
-- ROUTED THROUGH K9Compat.Get('inventory') (shared/compat/core.lua's
-- RequiredMethods.inventory.server.RegisterHook) below, never a direct
-- `exports.ox_inventory:registerHook` call. `RegisterHook`'s own boolean
-- return replaces the deleted `IsOxInventoryHookCapable()` (see that
-- function's own migration note above) for deciding whether to print the
-- warning -- the plain-Lua-function calling convention for `callback`
-- itself is UNCHANGED (confirmed correct: any function crossing a resource
-- export boundary is msgpack-packed into a callable table by the runtime
-- before it ever reaches the far side, so a plain function here is, and has
-- always been, the only convention that works -- see
-- shared/compat/inventory.lua's own RegisterHook doc comment for the full
-- citation) -- do not wrap `callback` in anything else.
--
-- STUB-DEGRADE, undetected inventory: `RegisterHook` returns `false`, the
-- warning below prints once, and TrackableLog.scent simply never receives
-- an entry -- `findTrackableSource('scent')` already, correctly, falls
-- through to `{ found = false }`, exactly the pre-existing "silently
-- inert, loudly warned once" posture this file's own header already
-- documents for an ox_inventory-missing session. A clean, disclosed
-- "feature switched off" degrade, never a crash.
--
-- STUB-DEGRADE, qb-inventory specifically (the other CONFIRMED backend) --
-- CORRECTED this pass (coder-backend): an EARLIER revision of this comment
-- recorded a "registers successfully but silently does nothing" failure
-- shape here -- the worst one in the codebase, per this task's own framing
-- -- based on a claim that qb-inventory never fires any real event for a
-- ground drop. That claim was WRONG: re-fetching and re-reading
-- qbcore-framework/qb-inventory's `main` branch directly this session found
-- the real, current call site the earlier pass missed (server/main.lua's
-- own `qb-inventory:server:createDrop` callback: `TriggerHook('ItemDropped',
-- hookData.item.type, hookData)`, firing on every real ground drop with a
-- payload containing the dropping player's own `source`). See
-- shared/compat/inventory.lua's own qb-inventory RegisterHook doc comment
-- for the full citation and the translation this file's `RegisterHook`
-- call below now benefits from with NO code change needed at this call
-- site: `RegisterHook('swapItems', ...)` now also registers a second, real
-- `AddHook('ItemDropped', ...)` internally, and translates it onto this
-- same `'swapItems'`-with-`toType == 'drop'` vocabulary this callback
-- already expects -- `payload.toType` and `payload.source` (the only two
-- fields this callback body reads) are both genuinely populated for a real
-- qb-inventory ground drop now, so the `if payload.toType ~= 'drop' then
-- return end` guard below is reached for real, and scent tracking is a
-- real, working feature on qb-inventory, not merely a disclosed gap.
--
-- The one residual degrade left to disclose: if qb-inventory's own
-- `AddHook('ItemDropped', ...)` registration specifically fails while the
-- unrelated `AddHook('ItemAdded', ...)` veto registration succeeds -- a REAL
-- possibility, not merely a hypothetical one: fxmanifest.lua's
-- `dependencies` mechanism has no version-constraint syntax, so an operator
-- could genuinely be running an older qb-inventory build (or a fork) that
-- predates `Events.ItemDropped` while still having `Events.ItemAdded` --
-- `RegisterHook` still returns `true` here (the capability this feature does
-- NOT depend on keeps working) -- shared/compat/inventory.lua's own adapter
-- prints a dedicated, one-time warning for exactly that narrower case, so it
-- is still never a silent gap even then; this call site needs no
-- separate handling for it.
local function RegisterScentInventoryHook()
    if not Config.Features.ScentTracking then return end -- nothing to gate for; do not probe/warn about a disabled-by-default feature

    local registered = K9Compat.Get('inventory').RegisterHook('swapItems', function(payload)
        if payload.toType ~= 'drop' then return end -- only a ground-drop counts as a scent source; trunk/stash/give moves are not

        -- payload.source must be a real number before it is used as a cooldown
        -- KEY. Not defensive padding: the qb-inventory adapter's ItemAdded
        -- translation hardcodes `source = nil` (that event genuinely does not
        -- carry one), and its toType vocabulary is documented as unconfirmed --
        -- so if that backend ever reports toType == 'drop' via ItemAdded, this
        -- reached Consume(nil, ...) -> Touch(nil) -> `store[nil] = now`, which
        -- is a hard "table index is nil" error. It was swallowed by the
        -- adapter's own pcall, so it failed safe and vetoed nothing, but it
        -- silently dropped the scent observation AND hid a real Lua error from
        -- the operator -- the worst combination for diagnosing why tracking is
        -- missing drops on that backend. Found by a red-team pass over the
        -- ItemDropped hook, 2026-08-26.
        if type(payload.source) ~= 'number' then return end

        -- Defense-in-depth rate limit, stamped BEFORE any log-append work, same
        -- ordering discipline as every other ingest surface in this file — see
        -- ScentDropRelayCooldown's own declaration comment for why this is NOT
        -- an anti-forgery measure the way relayCooldownMs is for blood/gunpowder.
        if not ScentDropRelayCooldown.Consume(payload.source, Config.Tracking.Scent.relayCooldownMs, GetGameTimer()) then
            return -- silent no-op: rate-limited, not an error worth notifying about
        end

        local ped = GetPlayerPed(payload.source)
        if ped == 0 then return end -- defensive: no live ped (e.g. a system/script-originated drop with no real connected player behind payload.source)

        AppendTrackableLogEntry(TrackableLog.scent, {
            coords = GetEntityCoords(ped), -- the DROPPING PLAYER'S OWN live position — NEVER ox_inventory's internal/eventual drop-inventory .coords (not yet created at this point in ox_inventory's own dropItem flow anyway, per DEVELOPER_REFERENCE.md#scent-source-resolution §2) and NEVER anything client-supplied
            loggedAt = GetGameTimer(),
            ticketIssued = false, -- ANTI-FARM FIX (this pass) — see findTrackableSource's own comment on this field for the full writeup
        }, TRACKABLE_LOG_MAX_ENTRIES.scent) -- ENTRY-COUNT CEILING (this pass) -- see that table's own declaration comment
    end)

    if not registered then
        print('[qbx_k9unit] WARNING: Config.Features.ScentTracking is enabled but ' ..
            'no compatible inventory backend hook registration succeeded (see /k9compat, if ' ..
            'enabled, for exactly why) -- scent tracking disabled. No scent sources will ever be ' ..
            'logged; findTrackableSource(\'scent\') will always report found = false.')
    end
end

-- LIFECYCLE FIX (coder-backend, this pass): dispatches to
-- RegisterScentInventoryHook() above on TWO distinct triggers, not just one.
--
-- Branch 1 (original, unchanged behavior): THIS resource's own start — see
-- RegisterScentInventoryHook's own doc comment / the original single-call-site
-- version's comments (still accurate) for the full "why onResourceStart, not
-- file-load time" reasoning.
--
-- Branch 2 (NEW this pass — closes a real gap): ox_inventory's OWN start.
-- Confirmed by direct source read of ox_inventory's `modules/hooks/server.lua`
-- this pass: that module keeps its entire hook table in a plain file-local
-- Lua variable (`local eventHooks = {}`), re-initialized empty every single
-- time ox_inventory (re)loads. It DOES clean up correctly when THIS resource
-- (the one that called registerHook) stops — it has its own
-- `AddEventHandler('onResourceStop', ...)` that drops every hook whose
-- `resource` field matches the stopping resource, confirmed via source, so
-- this resource restarting alone (branch 1 re-firing) can never leave a
-- stacked/duplicate hook behind. But it has NO symmetric mechanism to ask a
-- still-running OTHER resource (this one) to re-register after ox_inventory
-- ITSELF restarts — ox_inventory's fresh `eventHooks` table on restart simply
-- has no memory of a hook a still-running qbx_k9unit registered against the
-- PREVIOUS ox_inventory instance. Without this branch, a bare
-- `restart ox_inventory` (a normal, real ops action, e.g. after an
-- ox_inventory update) that does NOT also restart qbx_k9unit would leave
-- scent tracking silently, permanently inert for the rest of qbx_k9unit's
-- uptime — worse than the already-accepted "silently inert, loudly warned
-- ONCE at our own startup" posture RegisterScentInventoryHook's own doc
-- comment describes, since in this specific case no warning would ever print
-- at all (nothing about THIS resource changed to trigger one). Re-running
-- the exact same registration path here re-arms the hook against the
-- freshly-restarted ox_inventory — idempotent to call repeatedly across
-- however many times ox_inventory itself restarts, precisely because each
-- restart already wiped ox_inventory's own hook table clean first, so there
-- is never anything stale here to duplicate.
--
-- COMPAT-LAYER MIGRATION (this pass): branch 2's condition used to hardcode
-- `resourceName == 'ox_inventory'` -- now asks K9Compat itself which
-- resource actually backs the 'inventory' system, same pattern
-- server/inventory.lua's own RegisterK9InventoryItemFilterHook dispatch and
-- client/inventory.lua's own RegisterK9InventoryOxTargetOption dispatch
-- already establish for this exact class of gap. `K9Compat.Redetect()` is
-- forced here (not relying on shared/compat/core.lua's own onResourceStart
-- redetect hook having already run for this SAME event) for the same
-- "correct regardless of relative handler-registration order" reason those
-- two call sites give. Hardcoding 'ox_inventory' here would have silently
-- reopened exactly the single-backend gap this whole pass exists to close.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterScentInventoryHook()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('inventory') then
        RegisterScentInventoryHook()
    end
end)

-- ======================================================================
-- PER-PERSON FEATURE CONTROL (Config.FeatureControl -- config.lua's own
-- header documents the 4-step resolution; step 1, Config.Features.<Type>,
-- is checked separately below before this function is ever reached).
-- Mirrors server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId
-- shape verbatim (that file's own header says to read it before writing
-- another variant) -- parameterized by featureName here since this file
-- gates THREE independent Config.Features flags (ScentTracking/
-- BloodTracking/GunpowderSniffing) through the identical shape, one call
-- site each, rather than three near-duplicate functions.
--
-- SCOPE, DELIBERATE: this gates ONLY the QUERY side (findTrackableSource
-- below -- the "use the ability" entry point a K9 actually presses a
-- button for). It does NOT gate relayDamageEvent/relayWeaponFire (blood/
-- gunpowder CAPTURE) or the 'swapItems' ox_inventory hook (scent CAPTURE)
-- above -- those log an AMBIENT world event (a victim taking damage, a
-- shooter firing, an item hitting the ground) keyed by WHOEVER caused it,
-- not by the K9 who might later search for it. Gating capture on a
-- searching K9's own block/grant status would be a category error (the
-- reporting party is frequently a suspect, never the K9 in question), and
-- for gunpowder specifically this was examined and deliberately rejected
-- today: gating capture would stop logging shots fired by exactly the
-- people this feature exists to track, defeating the feature for every K9
-- who might legitimately search that log later, blocked or not. See
-- tests/tracking_spec.lua's regression coverage asserting capture stays
-- ungated.
--- @param citizenid string
--- @param featureName string -- exact Config.Features key: 'ScentTracking' | 'BloodTracking' | 'GunpowderSniffing'
--- @return boolean allowed
local function IsTrackingFeaturePermittedForCitizenId(citizenid, featureName)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.' .. featureName) == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant[featureName] == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.' .. featureName) == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- DEVELOPER_REFERENCE.md §11.4 item 1. Resolves the nearest trackable source of
--- `trackType` for the CALLING K9's own live server-side position.
--- Validation order (cheapest/most-defensive checks first, same discipline
--- DEVELOPER_REFERENCE.md#contraband-search §3 establishes for the
--- higher-stakes searchTarget callback in server/search.lua — applied here
--- too even though the stakes are lower, since this reveal is
--- client-cosmetic only, no real capability granted, per DEVELOPER_REFERENCE.md §11.6's
--- own framing):
---   1. Payload-shape / trackType validity.
---   2. Config.Features.<Type> — real server-side no-op regardless of
---      client UI state.
---   3. HasK9Access(source).
---   3b. PER-PERSON FEATURE CONTROL (IsTrackingFeaturePermittedForCitizenId
---      above) -- checked BEFORE the cooldown below is ever consumed, so a
---      blocked/not-yet-granted K9 never burns their own query cooldown on
---      a request that was always going to be refused.
---   4. Per-(source, trackType) cooldown — stamped BEFORE any lookup work
---      below, mirroring the ordering fix DEVELOPER_REFERENCE.md#contraband-search §3
---      step 13 mandates for searchTarget's cooldown-vs-await race (applies
---      here in case the 'scent' branch ever awaits an ox_inventory call).
---   5. Resolve the caller's own LIVE position — never a client-supplied
---      coordinate (this callback's signature only takes `trackType`, no
---      coords parameter, BY DESIGN — do not add one later).
---   6. Branch by trackType and resolve the nearest matching source.
---
--- STILL-OPEN, NOT DECIDED BY THIS FILE (flag before finalizing elsewhere):
---   - §11 doesn't specify a distinguishing `reason` field for WHY
---     `found = false` (no source in range vs. on cooldown vs. no access) —
---     DEVELOPER_REFERENCE.md#tracking §2.4 flags this as a small,
---     genuinely open UX question, not decided here. This implementation
---     collapses all three into a bare `{ found = false }`, matching the
---     signature DEVELOPER_REFERENCE.md §11.4 item 1 actually specifies.
---   - Whether an in-progress tracking session should auto-cancel on
---     mid-session loss of K9 access (mirroring
---     ForceDetachLeashForSource's precedent for leash) —
---     DEVELOPER_REFERENCE.md#tracking §5 item 4 flags this as
---     lower-stakes than leash (cosmetic only) but explicitly undecided;
---     not implemented here since a client re-polling this callback next
---     "Track" attempt already re-verifies access on its own.
--- Shared by BOTH findTrackableSource (single-type) below and
--- findNearestTrackableSource (merged, multi-type) further down -- EXTRACTED
--- this pass (coder-architect) rather than duplicated, so the two callbacks'
--- XP-tier/individual-override resolution can never drift apart. Pure
--- refactor of what used to be findTrackableSource's own inline block --
--- behavior byte-identical, see git history if a line-by-line diff is ever
--- needed.
--- @param trackerCitizenid string?
--- @param baseMaxRange number -- trackingConfig.maxRange for whichever trackType is being resolved
--- @return number maxRange -- baseMaxRange, or a raised value per an XP-tier/individual scentRangeMultiplier bonus
local function ResolveMaxRangeForCitizenId(trackerCitizenid, baseMaxRange)
    local maxRange = baseMaxRange
    if Config.Features.XPProgression and trackerCitizenid then
        -- INDIVIDUAL-OVERRIDE FIX (coder-backend pass) -- see
        -- server/k9profiles.lua's own header, "INTEGRATION HANDOFF", for the
        -- exact one-line gap this closes: resolves through
        -- GetK9EffectiveMultipliers (server/k9profiles.lua) FIRST, the SAME
        -- single seam server/progression.lua's own GetXPTierMedkitCooldownMs
        -- already calls for the sibling medkit-cooldown field -- never
        -- GetXPTier directly when an override might apply, per that file's
        -- own resolution-order contract (GLOBAL DEFAULT -> XP TIER ->
        -- INDIVIDUAL OVERRIDE). Falls back to a direct GetXPTier read when
        -- GetK9EffectiveMultipliers is unavailable (an install that predates
        -- server/k9profiles.lua, or one that had it removed). Only ever
        -- RAISES maxRange (never lowers it below baseMaxRange) -- the
        -- `> 1.0` check below means an uncached/base-tier citizenid's
        -- tier.scentRangeMultiplier (Config.XPTiers[1] = 1.00) never changes
        -- maxRange at all.
        local scentRangeMultiplier
        if type(GetK9EffectiveMultipliers) == 'function' then
            local ok, effective = pcall(GetK9EffectiveMultipliers, trackerCitizenid)
            if ok and type(effective) == 'table' and type(effective.scentRangeMultiplier) == 'number' then
                scentRangeMultiplier = effective.scentRangeMultiplier
            end
        end
        if scentRangeMultiplier == nil and type(GetXPTier) == 'function' then
            local tier = GetXPTier(trackerCitizenid)
            if tier and type(tier.scentRangeMultiplier) == 'number' then
                scentRangeMultiplier = tier.scentRangeMultiplier
            end
        end
        if type(scentRangeMultiplier) == 'number' and scentRangeMultiplier > 1.0 then
            maxRange = baseMaxRange * scentRangeMultiplier
        end
    end
    return maxRange
end

--- Scans TrackableLog[trackType] for the nearest still-fresh entry to
--- `myCoords` within `maxRange` -- EXTRACTED this pass (coder-architect),
--- pure refactor of findTrackableSource's own former inline loop, now
--- shared with findNearestTrackableSource's own per-candidate-type scan
--- further down. Discards entries already older than maxAgeSeconds even if
--- PruneTrackableLogs hasn't swept them yet (belt-and-suspenders against a
--- prune-timing gap, not a substitute for pruning).
--- @param trackType 'scent'|'blood'|'gunpowder'
--- @param myCoords vector3
--- @param maxRange number
--- @param maxAgeMs number
--- @param now number
--- @return number? nearestDist, vector3? sourceCoords, table? nearestEntry
local function FindNearestFreshTrackableEntry(trackType, myCoords, maxRange, maxAgeMs, now)
    local nearestDist, sourceCoords, nearestEntry

    -- PERFORMANCE FIX (load audit, this pass) -- TrackableLog[trackType] is
    -- now a ring buffer (see AppendTrackableLogEntry's own doc comment);
    -- walked OLDEST FIRST here specifically so the tie-break rule just below
    -- (`dist < nearestDist`, strict -- ties keep whichever entry was
    -- encountered FIRST) still means "ties keep the OLDEST entry", exactly
    -- as it always has, rather than "ties keep whatever happens to sit in
    -- the lowest physical ring slot" (a real, silent behavior change a plain
    -- `ipairs(TrackableLog[trackType])` walk would have introduced the
    -- moment this ring first wraps).
    for _, entry in TrackableRingLogEntriesOldestFirst(TrackableLog[trackType], TRACKABLE_LOG_MAX_ENTRIES[trackType]) do
        if (now - entry.loggedAt) < maxAgeMs then
            local dist = #(myCoords - entry.coords)
            if dist <= maxRange and (not nearestDist or dist < nearestDist) then
                nearestDist = dist
                sourceCoords = entry.coords
                nearestEntry = entry
            end
        end
    end

    return nearestDist, sourceCoords, nearestEntry
end

--- Anti-farm PendingTrackArrival ticket-minting -- EXTRACTED this pass
--- (coder-architect), pure refactor of findTrackableSource's own former
--- inline block (see MIN_TRACK_XP_DISTANCE/MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS/
--- TrackTicketMintCooldown's own declaration comments above for the full
--- anti-farm rationale this preserves unchanged), now shared with
--- findNearestTrackableSource further down so a K9 arriving via the NEW
--- merged action earns tickets under the exact same rules as the OLD
--- single-type path, never a looser or stricter copy.
--- @param source number
--- @param trackType 'scent'|'blood'|'gunpowder'
--- @param nearestDist number
--- @param sourceCoords vector3
--- @param nearestEntry table
--- @param now number
local function MaybeMintTrackArrivalTicket(source, trackType, nearestDist, sourceCoords, nearestEntry, now)
    if Config.Features.XPProgression and nearestDist >= MIN_TRACK_XP_DISTANCE
        and nearestEntry and not nearestEntry.ticketIssued
        and TrackTicketMintCooldown.Consume(source, TRACK_TICKET_MINT_COOLDOWN_MS, now) then
        nearestEntry.ticketIssued = true -- ration this entry to one ticket, ever -- the cosmetic reveal below is unaffected either way
        PendingTrackArrival[source] = {
            trackType = trackType,
            coords = sourceCoords, -- the SAME server-resolved coordinate returned to the client below -- never re-derived from a later client claim
            expiresAt = now + Config.XP.trackArrivalTTLMs,
            createdAt = now, -- ECONOMY-AUDIT FIX, HOLE 2 -- real elapsed time is measured from this, never a client-reported duration
            minElapsedMs = (nearestDist / MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS) * 1000, -- derived from the SAME server-measured nearestDist gated on just above
        }
    end
end

lib.callback.register('qbx_k9unit:server:findTrackableSource', function(source, trackType)
    if type(trackType) ~= 'string' or not TRACK_TYPE_CONFIG[trackType] then
        return { found = false } -- defensive: never trust client payload shape
    end

    if not Config.Features[TRACK_TYPE_FEATURE_FLAGS[trackType]] then
        return { found = false } -- real server-side no-op regardless of client UI state, per §3
    end

    if not HasK9Access(source) then
        return { found = false } -- reuse the global from server/certifications/, do not re-derive
    end

    -- PER-PERSON FEATURE CONTROL -- see IsTrackingFeaturePermittedForCitizenId
    -- above for the full 4-step resolution and why this gates the QUERY only,
    -- never blood/gunpowder/scent CAPTURE. Deliberately BEFORE the cooldown
    -- consume just below -- a block must never burn a cooldown slot.
    local trackerPlayerForPermission = exports.qbx_core:GetPlayer(source)
    local trackerCitizenidForPermission = trackerPlayerForPermission and trackerPlayerForPermission.PlayerData
        and trackerPlayerForPermission.PlayerData.citizenid
    if not trackerCitizenidForPermission
        or not IsTrackingFeaturePermittedForCitizenId(trackerCitizenidForPermission, TRACK_TYPE_FEATURE_FLAGS[trackType]) then
        return { found = false } -- same bare, reasonless shape every other denial in this callback already uses (§11.4 item 1's own signature has no reason field)
    end

    -- SPECIALIZATION GATE (owner-directed decluttering pass, 2026-08-26) --
    -- this OLDER single-type callback's signature never grows (per this
    -- file's own header) and STAYS reachable (client/tracking.lua's
    -- Start*Track() globals are kept, see that file's own header), so it
    -- must enforce the exact same specialization scoping the NEW merged
    -- findNearestTrackableSource below does -- otherwise a client (modified,
    -- or simply still calling the old Start*Track() global) could bypass
    -- specialization scoping entirely just by asking for a specific
    -- trackType directly instead of going through the merged action. "The
    -- server resolves which types apply. The client must NOT decide this."
    -- Deliberately BEFORE the cooldown consume just below, same "a denial
    -- must never burn a cooldown slot" discipline as the permission check
    -- immediately above.
    local jobNameForSpecialization = trackerPlayerForPermission.PlayerData.job
        and trackerPlayerForPermission.PlayerData.job.name
    local enabledTrackTypesForCaller = ResolveEnabledTrackTypesForCitizenId(trackerCitizenidForPermission, jobNameForSpecialization)
    if not enabledTrackTypesForCaller[trackType] then
        return { found = false } -- not certified for this specific track type -- same bare, reasonless shape as every other denial here
    end

    local trackingConfig = TRACK_TYPE_CONFIG[trackType]

    -- Stamp BEFORE doing any lookup work below — see this function's own
    -- doc comment (step 4) for why. TrackQueryCooldown.Consume checks and
    -- (iff allowed) stamps in one call, at the SAME `now` reused for the
    -- freshness filtering further below.
    local now = GetGameTimer()
    if not TrackQueryCooldown.Consume(source, trackType, trackingConfig.searchCooldownMs, now) then
        return { found = false }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { found = false } end -- defensive: no live ped to read a position from
    local myCoords = GetEntityCoords(ped) -- NEVER a client-supplied coordinate

    -- PHASE 4 ADDITION (coder-backend, XPProgression pass, DEVELOPER_REFERENCE.md
    -- §13.4.1 item (a)) -- resolution logic now lives in the shared
    -- ResolveMaxRangeForCitizenId helper above (coder-architect extraction,
    -- this pass), behavior unchanged.
    local maxRange = ResolveMaxRangeForCitizenId(trackerCitizenidForPermission, trackingConfig.maxRange)

    -- 'scent' / 'blood' / 'gunpowder': nearest still-fresh logged entry
    -- within maxRange -- now the shared FindNearestFreshTrackableEntry
    -- helper above (coder-architect extraction, this pass), behavior
    -- unchanged.
    local maxAgeMs = trackingConfig.maxAgeSeconds * 1000
    local nearestDist, sourceCoords, nearestEntry = FindNearestFreshTrackableEntry(trackType, myCoords, maxRange, maxAgeMs, now)

    if not sourceCoords then
        return { found = false }
    end

    -- Anti-farm PendingTrackArrival ticket-minting -- now the shared
    -- MaybeMintTrackArrivalTicket helper above (coder-architect extraction,
    -- this pass), behavior unchanged. See MIN_TRACK_XP_DISTANCE/
    -- MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS/TrackTicketMintCooldown's own
    -- declaration comments for the full anti-farm rationale.
    MaybeMintTrackArrivalTicket(source, trackType, nearestDist, sourceCoords, nearestEntry, now)

    return {
        found = true,
        coords = sourceCoords,
        -- Informational only (DEVELOPER_REFERENCE.md#tracking
        -- §1.2) — config.lua is a shared_script so the client can already
        -- read Config.WaterTrackingDecay.breaksTrail directly; populate it
        -- anyway for future-proofing (e.g. a later per-type override).
        breaksAtWater = Config.WaterTrackingDecay.breaksTrail,
    }
end)

-- Deterministic iteration order for the merged callback below -- plain
-- `pairs()` over TRACK_TYPE_CONFIG would work for correctness (every
-- candidate type is scored independently and the nearest one wins
-- regardless of scan order) but makes which type wins a TIE (two entries at
-- the exact same distance, a realistic outcome in a test fixture using
-- round-number coordinates) depend on Lua's per-VM-instance string hash
-- seed -- mirrors tests/tracking_spec.lua's own TRACK_TYPES_ORDERED
-- precedent and rationale exactly.
local TRACK_TYPES_ORDER = { 'scent', 'blood', 'gunpowder' }

-- Sentinel TrackQueryCooldown key for the merged action below -- see
-- findNearestTrackableSource's own doc comment ("ONE COOLDOWN, DELIBERATE")
-- for the full reasoning. Deliberately NOT one of 'scent'/'blood'/
-- 'gunpowder' (TrackQueryCooldown is a NewNestedCooldown keyed by
-- (source, trackType) as a plain string, so this can never collide with a
-- real trackType).
local MERGED_TRACK_QUERY_KEY = '__merged__'

--- ONE MERGED ACTION, SERVER SIDE (owner-directed decluttering pass,
--- 2026-08-26 -- "merge all the scent tracking stuff into one thing...
--- when certed for extra stuff it just does it"). The ONE server callback
--- backing client/tracking.lua's single StartCertifiedTrack() entry point
--- (one radial item, one chat command, per that file's own header) --
--- resolves EVERY track type `source`'s own citizenid is currently entitled
--- to (ResolveEnabledTrackTypesForCitizenId above) in ONE round trip, and
--- returns the nearest matching source across all of them, WITH which
--- trackType actually matched (the client needs this to pick the right
--- Config.Tracking.<Type> tuning/marker-spacing for whatever trail it ends
--- up rendering -- see client/tracking.lua's own StartCertifiedTrack).
---
--- findTrackableSource above is UNCHANGED in shape and is NOT called three
--- times from the client to build this -- doing so would mean three round
--- trips and three separate cooldown consumptions, per this pass's own
--- explicit instruction. This callback shares its VALIDATION LOGIC with
--- that one (IsTrackingFeaturePermittedForCitizenId, ResolveMaxRangeForCitizenId,
--- FindNearestFreshTrackableEntry, MaybeMintTrackArrivalTicket -- all
--- extracted, shared functions above) but is its own registration with its
--- own cooldown key, not a wrapper that calls the other callback's handler
--- function three times.
---
--- ONE COOLDOWN, DELIBERATE (this pass's own explicit design question --
--- "decide deliberately whether the merged action consumes one cooldown or
--- one per type"): this callback consumes exactly ONE TrackQueryCooldown
--- entry, keyed on the sentinel MERGED_TRACK_QUERY_KEY above -- entirely
--- independent of the three per-(source, trackType) keys
--- findTrackableSource's own single-type path uses (that path is only
--- reachable today via the kept-but-orphaned Start*Track() globals, per
--- client/tracking.lua's own header -- nothing in the live UI calls it
--- anymore). The cooldown DURATION used is the MAXIMUM (slowest)
--- searchCooldownMs among the candidate types this specific call actually
--- searches, not the minimum/fastest: this one query already covers every
--- enabled type at once, so throttling it at the fastest type's rate would
--- let a handler re-run a full multi-type sweep MORE often than any single
--- type's own configured throttle would ever have allowed on its own --
--- three times cheaper to spam than pressing "Track <Type>" three separate
--- times, exactly the trap this design was told to avoid. Using an
--- independent sentinel key (rather than, say, requiring all three
--- per-type keys to be simultaneously off cooldown) also means this action
--- can never "refuse itself": it has no dependency on whatever unrelated
--- state the three per-type keys happen to be in.
lib.callback.register('qbx_k9unit:server:findNearestTrackableSource', function(source)
    if not HasK9Access(source) then
        return { found = false } -- reuse the global from server/certifications/, do not re-derive
    end

    local trackerPlayer = exports.qbx_core:GetPlayer(source)
    local trackerCitizenid = trackerPlayer and trackerPlayer.PlayerData and trackerPlayer.PlayerData.citizenid
    if not trackerCitizenid then
        return { found = false } -- no resolvable citizenid -- cannot evaluate any per-person gate below, fail closed
    end
    local jobName = trackerPlayer.PlayerData.job and trackerPlayer.PlayerData.job.name

    -- SERVER RESOLVES, CLIENT NEVER ASKS -- this callback takes NO trackType
    -- argument at all (unlike findTrackableSource above); the enabled set is
    -- entirely a function of `source`'s own server-held citizenid, per this
    -- pass's own explicit "the client must not decide this" requirement.
    local enabledTrackTypes = ResolveEnabledTrackTypesForCitizenId(trackerCitizenid, jobName)

    -- Same three gates findTrackableSource's own single-type path enforces
    -- per trackType (Config.Features.<Type>, HasSpecialization-derived
    -- enabledTrackTypes, IsTrackingFeaturePermittedForCitizenId) -- evaluated
    -- once per candidate type here instead of once per callback invocation.
    local candidateTypes = {}
    for _, trackType in ipairs(TRACK_TYPES_ORDER) do
        if enabledTrackTypes[trackType]
            and Config.Features[TRACK_TYPE_FEATURE_FLAGS[trackType]]
            and IsTrackingFeaturePermittedForCitizenId(trackerCitizenid, TRACK_TYPE_FEATURE_FLAGS[trackType]) then
            candidateTypes[#candidateTypes + 1] = trackType
        end
    end

    if #candidateTypes == 0 then
        return { found = false } -- nothing this citizenid is both entitled to AND currently permitted to search
    end

    -- ONE COOLDOWN, sized to the SLOWEST candidate type -- see this
    -- function's own doc comment "ONE COOLDOWN, DELIBERATE" above for the
    -- full reasoning. Stamped BEFORE any TrackableLog scan below, same
    -- "a denial must never burn a slot for nothing, but an ALLOWED request
    -- stamps before doing lookup work" discipline findTrackableSource's own
    -- doc comment establishes.
    local mergedCooldownMs = 0
    for _, trackType in ipairs(candidateTypes) do
        mergedCooldownMs = math.max(mergedCooldownMs, TRACK_TYPE_CONFIG[trackType].searchCooldownMs)
    end

    local now = GetGameTimer()
    if not TrackQueryCooldown.Consume(source, MERGED_TRACK_QUERY_KEY, mergedCooldownMs, now) then
        return { found = false }
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { found = false } end -- defensive: no live ped to read a position from
    local myCoords = GetEntityCoords(ped) -- NEVER a client-supplied coordinate

    local bestTrackType, bestDist, bestCoords, bestEntry
    for _, trackType in ipairs(candidateTypes) do
        local trackingConfig = TRACK_TYPE_CONFIG[trackType]
        local maxRange = ResolveMaxRangeForCitizenId(trackerCitizenid, trackingConfig.maxRange)
        local maxAgeMs = trackingConfig.maxAgeSeconds * 1000
        local dist, coords, entry = FindNearestFreshTrackableEntry(trackType, myCoords, maxRange, maxAgeMs, now)
        if dist and (not bestDist or dist < bestDist) then
            bestTrackType = trackType
            bestDist = dist
            bestCoords = coords
            bestEntry = entry
        end
    end

    if not bestCoords then
        return { found = false }
    end

    MaybeMintTrackArrivalTicket(source, bestTrackType, bestDist, bestCoords, bestEntry, now)

    return {
        found = true,
        trackType = bestTrackType, -- NEW field vs. findTrackableSource's response shape -- the client needs to know WHICH type matched, since it never told the server which one to look for
        coords = bestCoords,
        breaksAtWater = Config.WaterTrackingDecay.breaksTrail, -- informational only, same as findTrackableSource above
    }
end)

--- PHASE 4 ADDITION (coder-backend, XPProgression pass). Fired by
--- client/tracking.lua's own render thread the FIRST tick it observes its
--- local distance to the resolved source coordinate drop to/below
--- Config.XP.trackArrivalRadius — see that file's own comment for the exact
--- client-side trigger. No payload: this handler re-measures the CALLER'S
--- OWN LIVE server-side position against the coordinate THIS SERVER already
--- resolved and stored in PendingTrackArrival above — never a client-claimed
--- distance, arrival boolean, or coordinate. A modified client calling this
--- event with no real search having resolved anything, or from far away, or
--- repeatedly, gets nothing: no pending entry / an expired entry / a live
--- distance still over the radius all fall through to a silent no-op below.
-- DELIBERATELY NOT RE-CHECKED against IsTrackingFeaturePermittedForCitizenId
-- here: the block/grant gate is the ENTRY POINT (findTrackableSource above,
-- where the ticket was minted) -- by the time a K9 is walking toward an
-- already-resolved, already-authorized source, they hold a ticket earned
-- fair and square. Re-checking here would gate the SYMPTOM (claiming an
-- already-earned reward) rather than the entry point, and would strand a K9
-- who was blocked one tick after a legitimate find, with real travel already
-- spent, out of an XP award they had already qualified for -- the same
-- "no unbounded trap" reasoning this resource applies to termination paths,
-- applied here to an in-flight reward instead.
RegisterNetEvent('qbx_k9unit:server:reportTrackSourceArrival', function()
    local src = source

    if not Config.Features.XPProgression then return end -- real server-side no-op regardless of client UI state, per §3
    if not HasK9Access(src) then return end -- reuse the global from server/certifications/, do not re-derive

    local now = GetGameTimer()

    if not TrackArrivalReportCooldown.Consume(src, TRACK_ARRIVAL_REPORT_COOLDOWN_MS, now) then
        return -- silent no-op: rate-limited, not an error worth notifying about
    end

    local pending = PendingTrackArrival[src]
    if not pending then return end -- no resolved-but-unreached source is currently pending for this source

    if now > pending.expiresAt then
        PendingTrackArrival[src] = nil -- stale — drop it rather than leave it around for a later, unrelated report to consume
        return
    end

    -- ECONOMY-AUDIT FIX, HOLE 2 (this pass) -- see MAX_PLAUSIBLE_ARRIVAL_SPEED_MPS's
    -- own declaration comment above for the full writeup. `pending.createdAt`/
    -- `now` are both server GetGameTimer() values -- never a client-reported
    -- duration. Deliberately does NOT clear the pending ticket on this
    -- branch (unlike the expiry/single-use paths below) -- a genuine K9 who
    -- simply arrived faster than expected just needs to wait out the
    -- remainder of `minElapsedMs` and report again (bounded by
    -- TrackArrivalReportCooldown above), not lose their in-flight ticket.
    if (now - pending.createdAt) < pending.minElapsedMs then
        return -- too little real time has passed to be genuine travel
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: no live ped to read a position from

    local dist = #(GetEntityCoords(ped) - pending.coords) -- LIVE server-side measurement, never a client-supplied distance
    if dist > Config.XP.trackArrivalRadius then return end -- not actually there yet, regardless of what the client's own render thread believes

    -- Single-use: consumed now, regardless of what AwardXP below does with
    -- it, so a second report for the same resolved source (whether a
    -- retry, a race, or an attempted repeat) cannot double-award.
    PendingTrackArrival[src] = nil

    local trackerPlayer = exports.qbx_core:GetPlayer(src)
    local trackerCitizenid = trackerPlayer and trackerPlayer.PlayerData and trackerPlayer.PlayerData.citizenid
    if not trackerCitizenid then return end

    -- Runtime existence guard, same soft-dependency convention as this
    -- file's own GetXPTier call site above — no load-order assumption on
    -- server/progression.lua either way.
    if type(AwardXP) == 'function' then
        AwardXP(trackerCitizenid, 'trackSourceResolved')
    end
end)

-- Cleans up this file's per-source ephemeral state on disconnect, same
-- rationale as server/main.lua's playerDropped handler (drop
-- cooldown-table entries so they don't leak one per session) and
-- server/certifications/'s own "regression-test fix" for unbounded
-- per-citizenid cache growth. `TrackableLog` itself needs NO per-source
-- cleanup here — its entries are keyed by coordinate/timestamp, not by
-- the reporting source, and are already pruned on their own
-- maxAgeSeconds schedule regardless of whether the original reporter is
-- still connected.
--
-- DEVELOPER_REFERENCE.md item 1: TrackQueryCooldown/DamageRelayCooldown/
-- WeaponFireRelayCooldown/ScentDropRelayCooldown each already registered
-- their OWN independent `playerDropped` handler via
-- :RegisterPlayerDropped() at their own declaration above, so there is no
-- longer a dedicated handler for this file's cooldown state — each tracker
-- owns clearing its own entry for the disconnecting source, same net
-- effect as before.
--
-- QA FIX (this pass): `PendingTrackArrival` is NOT one of those tracker
-- instances (it's a plain table storing {trackType, coords, expiresAt}, not
-- a `key -> lastTouchedAtMs` cooldown shape — see its own declaration
-- comment above for why none of NewCooldown/NewNestedCooldown/NewMutex
-- fit), so it was never actually covered by any of the RegisterPlayerDropped
-- calls above, DESPITE that same declaration comment's own claim of "plain
-- table + manual playerDropped cleanup" — no such handler previously
-- existed anywhere in this file. Left uncleaned, a disconnecting source's
-- pending ticket would sit until its own `expiresAt` TTL lapses (up to
-- Config.XP.trackArrivalTTLMs, 60s) — not just an unbounded-growth concern
-- (bounded anyway by the TTL and by there being at most one connected
-- player per source id at a time) but a genuine misattribution risk: FiveM
-- recycles numeric server ids, so a new, unrelated player could be assigned
-- the disconnecting player's old source id before that TTL lapses and,
-- inside that window, unknowingly stand within Config.XP.trackArrivalRadius
-- of a coordinate resolved for a DIFFERENT citizenid's earlier search
-- entirely — awarding trackSourceResolved XP to the wrong K9 for a search
-- they never made. Clearing this below on the disconnecting source's own
-- playerDropped closes that window, mirroring server/main.lua's
-- PendingLeashRequests target-side cleanup (that table's own precedent for
-- "plain table, manual handler" — see this file's PendingTrackArrival
-- declaration comment) for the exact same key shape (keyed by a single
-- source, no initiator/target pairing to additionally scan for, unlike
-- PendingLeashRequests' own two-sided cleanup).
-- ======================================================================
-- SCENT VISION (Config.Features.ScentVision) -- owner-directed pass: "make
-- scent tracking... a keybind that makes a colour dot appear where players['
-- ] blood etc have walked and have a delay before the scent markers go
-- away... if multiple people, multiple different colours... to
-- differentiate smells." Coordinator follow-ups (verbatim, folded into this
-- design as it evolved): "person" (colour is per PERSON, never per
-- permission -- that reading was raised and explicitly closed); "big
-- population... won't cause an issue" (bounded capture, bounded reveal, no
-- server-wide broadcast); "handful near the dog" / "they go away after 45
-- seconds" (colours scoped to a small proximity-ranked set, 45s default dot
-- lifetime); "diffrent dots will be all seprate timers... slowly go away"
-- (EACH DOT expires on its OWN individual timer from its OWN capture time --
-- never one shared trail-wide clock).
--
-- WHAT THIS IS, AND IS NOT, RELATIVE TO THE REST OF THIS FILE: Track
-- Scent/Blood/Gunpowder above (findTrackableSource) resolve and reveal
-- exactly ONE nearest logged EVENT (a damage hit, a gunshot, an item drop)
-- and hand the client a coordinate to walk toward. ScentVision instead
-- reveals SEVERAL people's own recent walked PATHS at once, colour-coded so
-- more than one trail through the same ground can be told apart -- a
-- different SHAPE of reveal, built on a NEW, separate capture stream
-- (PositionTrail below), not on TrackableLog. Kept separate deliberately:
-- TrackableLog's own anti-farm ticket-minting machinery (ticketIssued,
-- MIN_TRACK_XP_DISTANCE, TrackTicketMintCooldown, ...) exists entirely to
-- guard trackSourceResolved XP, which ScentVision never awards (this
-- feature mints ZERO XP, same "cosmetic reveal, no real capability granted"
-- framing DEVELOPER_REFERENCE.md §11.6 already established for the three trail types
-- above) -- entangling a brand-new, always-on, population-wide capture
-- stream with that machinery would have changed its risk profile for no
-- reason. This does mean an existing K9 handler's own recent
-- blood/gunpowder/scent-drop TrackableLog events are NOT folded in as extra
-- ScentVision dots this pass -- a disclosed, deliberate scope decision (see
-- this pass's own report), not an oversight; nothing here prevents adding
-- that later as a genuinely separate, additive reveal source.
--
-- THE "NO WALLHACK" DESIGN TENSION, WEIGHED EXPLICITLY (qa-tester finding,
-- this pass -- not silently left unwritten the way this resource's own
-- convention forbids): a sibling file's header argued, at length,
-- against "a menu that hands you the answer" (its own citation of the
-- Batman/Witcher detective-vision criticism) and deliberately ships a
-- SMALLER information surface than even THIS file's own Track Scent/Blood/
-- Gunpowder trio for exactly that reason. ScentVision does not touch that
-- hunt mechanic's own hidden coordinate at all (separate state, separate
-- files, confirmed by direct read before this feature was built) -- but it
-- IS, honestly, a LARGER reveal than the trio it sits next to in this same
-- file: Track Blood/Gunpowder/Scent only ever produce a point when the
-- SUBJECT does something specific (bleeds, fires a weapon, drops an item)
-- -- a triggered, event-shaped disclosure. ScentVision instead reveals
-- every nearby connected player's ordinary walked path, continuously, with
-- NO triggering act required of the subject at all -- the closest thing
-- this resource has shipped to "always know roughly who has been nearby."
-- This was weighed, not overlooked, and the answer is: built anyway, on the
-- owner's own explicit, repeated, increasingly specific direction (a
-- keybind, colours per person, a "handful near the dog", a 45-second
-- per-dot timer) -- not a case of this file's own judgment call filling a
-- gap the owner left open. The mitigations actually in place are the ones
-- the owner himself asked for and that also happen to narrow the exposure:
-- range-limited (queryRangeMeters), count-limited (maxVisibleTrails x
-- queryMaxPointsPerTrail), time-limited (dotLifetimeMs), and per-person
-- block/grant-gated the same as every other tracking feature in this file
-- (IsTrackingFeaturePermittedForCitizenId('ScentVision')) -- so an operator
-- who decides this crosses a line for their server can narrow it (lower the
-- range/handful/lifetime) or block it per-person without touching code. A
-- narrower design -- e.g. only ever showing a trail for a citizenid already
-- wanted/flagged by something else in this resource -- was NOT built this
-- pass: that is a scope/gameplay-design call for the owner/product side,
-- not one this file's own author should make unilaterally by quietly
-- narrowing what was explicitly asked for. Recorded here so the next reader
-- does not mistake silence for the question never having been asked.
--
-- SCALE, WORKED OUT, NOT ASSUMED (owner's own explicit requirement: this
-- must stay smooth on a populated server) -- full arithmetic in this pass's
-- own report; summarised at each bound below:
--   - CAPTURE cost: one GetPlayerPed+GetEntityCoords pair per CONNECTED
--     player, once per sampleIntervalMs (4s shipped) -- at 200 concurrent
--     players that is 50 native-call-pairs/sec, the same shape and order of
--     magnitude as this file's own pre-existing GetPlayers() population
--     scans (server/entities.lua's ResolveConnectedPlayerFromPed) and
--     server/wellbeing.lua's GetAllObjects/GetAllVehicles scans -- nothing
--     new in KIND, only in cadence.
--   - STORAGE ceiling: maxPointsPerPerson (15 shipped) is a HARD cap,
--     independent of dotLifetimeMs/sampleIntervalMs math, enforced on every
--     write (oldest evicted first) -- so total stored points can never
--     exceed connectedPlayers x maxPointsPerPerson regardless of how the
--     other two are configured. Each point is a 4-number array-style table
--     ({x, y, z, loggedAt}, never string-keyed) -- a conservative ~150
--     bytes/point estimate (a reasoned order-of-magnitude figure, NOT
--     profiled against a live FXServer's real Lua 5.4 allocator this pass --
--     disclosed as an estimate, not measured) puts 200 players x 15 points
--     x 150 bytes at roughly 440KB, and even FiveM's documented 1024-slot
--     hard ceiling x 15 x 150 bytes at roughly 2.2MB -- trivial against a
--     real server's memory budget either way, and a number the owner can
--     lower further via maxPointsPerPerson/dotLifetimeMs if a real profile
--     ever disagrees. DISCARDED ON WRITE (every capture pass drops that
--     SAME person's already-expired points before appending a new one, per
--     each point's OWN loggedAt timestamp -- never a decremented countdown)
--     -- never accumulated indefinitely and filtered only at query time; the
--     sweep thread below additionally catches a person who stops moving
--     (and so stops triggering that on-write sweep) on its own periodic
--     cadence.
--   - REVEAL cost: a query scans PositionTrail once (O(connectedPlayers x
--     maxPointsPerPerson) point-distance checks -- 200 x 15 = 3,000 at the
--     shipped defaults, microseconds of Lua work), then returns AT MOST
--     maxVisibleTrails (5, "a handful", the owner's own word) distinct
--     people's trails, each capped at queryMaxPointsPerTrail (12) points,
--     nearest-first -- so the PAYLOAD sent to any one client, and the
--     number of dots that client ever has to draw, is bounded at 60 points
--     REGARDLESS of server population. Degradation under load always drops
--     the FURTHEST trail/point first, per the owner's own instruction, at
--     both the trail-selection and per-trail-point levels below.
--   - COLOUR SPACE: `maxVisibleTrails` (5) fixed, curated swatches
--     (Config.Tracking.ScentVision.palette) -- see ResolveScentVisionColors/
--     HashStringToIndex below. UPDATED (owner-directed follow-up,
--     2026-08-26 -- "hold a colour stable... the same person is the same
--     colour... for every handler looking"): colour is now a DETERMINISTIC
--     HASH of the trail owner's own durable citizenid into this palette,
--     never sent to the client -- resolved fresh on every query, needs no
--     server-side memory of its own at all (a pure function of the string),
--     and is the SAME colour for the SAME person across every handler and
--     the whole session, which the OLDER per-observer "first free slot"
--     scheme this replaces could not promise (it only held a colour stable
--     for as long as one handler kept that trail in view). The trade-off,
--     stated honestly: the old scheme made a colour COLLISION between two
--     SIMULTANEOUSLY SHOWN trails structurally impossible as long as the
--     palette was at least `maxVisibleTrails` long; a hash can always,
--     rarely, send two different citizenids to the same swatch even below
--     that count. Config.Tracking.ScentVision.palette's own comment
--     discloses this trade explicitly -- accepted for the same reason
--     `maxVisibleTrails` already accepted "colours repeat once there are
--     more people than swatches": telling trails apart most of the time
--     with a real handful-sized palette is the actual ask, not a
--     cryptographic guarantee.
--
-- TRUST BOUNDARY: every point returned by getScentVisionPoints below is
-- this SERVER's own resolved position for some OTHER connected player,
-- gathered by this file's own capture thread -- never a client-supplied
-- coordinate, and never a coordinate for anyone outside the caller's own
-- queryRangeMeters/maxVisibleTrails/queryMaxPointsPerTrail limits. A client
-- is never handed the whole server's positions, and never learns WHO a dot
-- belongs to (no citizenid/name/source is ever put on the wire) -- only
-- WHERE, and which of its own "handful" colours that trail currently holds.
--
-- CONTRABAND BODY HIGHLIGHT (owner-directed follow-up, 2026-08-26 --
-- "diffrent colors on there body if they have explosives drugs etc"), added
-- to this SAME callback/poll rather than a second one -- see
-- Config.Tracking.ScentVision.contrabandHighlight's own config.lua header
-- for the full plain-English writeup, and CONTRABAND_ITEM_CATEGORY's own
-- comment further below for the one piece of this that is a disclosed,
-- temporary duplication rather than a clean reuse. FIVE DECISIONS RECORDED
-- HERE, so a future reader does not have to re-derive them:
--   1. GATED IDENTICALLY TO SEARCH: a category only ever highlights if the
--      OBSERVING K9's own citizenid currently holds that
--      Config.K9Specializations key (HasSpecialization -- the exact same
--      gate server/search.lua's own contraband weighing uses), and
--      uncategorised contraband is the same "found by everyone with K9
--      access" baseline search already treats it as. A dog with zero
--      matching specializations gets the baseline highlight only, same as
--      it can only ever find baseline items on a real search.
--   2. MINIMAL, SERVER-DECIDED PAYLOAD: the server sends only pre-resolved
--      RGB swatches per visible target, never a category NAME, never an
--      item name, never a count, never a weight, and never a boolean for
--      every possible category (only entries for categories that actually
--      matched are ever present at all) -- a modified client learns
--      nothing beyond "this many coloured marks, these colours" for a
--      person it can already see in front of it.
--   3. RANGE: capped far tighter than the trail reveal above
--      (`contrabandHighlight.rangeMeters`, ceilinged in code at
--      Config.SearchZones.personSearchDistance -- the SAME distance a real
--      "Search Person" already requires), checked here against this
--      SERVER's own live GetEntityCoords for both the caller and the
--      target, never a client-supplied position for either.
--   4. RELATIONSHIP TO REAL SEARCHING, DECIDED DELIBERATELY: this highlight
--      answers ONLY "is something in a category I can detect present on
--      this person right now" -- never what, never how much. It mints ZERO
--      XP, never calls BroadcastContrabandAlert, and never writes to
--      k9_search_log. Actually running "Search Person" is still the only
--      action that reveals the alert tier, awards XP, and can warn nearby
--      officers -- this is a nose twitch that tells a handler to go search,
--      not a replacement for searching. If this bullet is ever weakened
--      (e.g. this highlight starts distinguishing WEIGHT/tier, or starts
--      minting XP itself) that is a deliberate, disclosed scope change, not
--      a drive-by addition.
--   5. RATE/COST: reuses THIS SAME poll (ScentVisionQueryCooldown above
--      already floors the cadence) rather than a second loop, and the
--      per-query cost is bounded by `visibleSources` (already capped at
--      `maxVisibleTrails`, 5 shipped) -- at most 5 extra GetPlayerPed/
--      GetEntityCoords pairs, and at most 5 inventory reads GATED BEHIND
--      the tight proximity check in decision 3 above (in practice, usually
--      0-1 of the 5 visible trails are ever actually within
--      contrabandHighlight.rangeMeters at once) -- never O(connected
--      players).
-- ======================================================================

-- Load-time sanity check -- see `palette`'s own config.lua comment for the
-- full, honestly-updated writeup of what "too short" means now that colour
-- is a HASH of the trail owner's citizenid (HashStringToIndex/
-- ResolveScentVisionColors below) rather than a per-observer slot: this
-- warning still fires for the same "maxVisibleTrails > palette length"
-- condition as before (a real, guaranteed-reuse case once more than
-- paletteLen distinct people are ever shown to the same K9 at once), but a
-- hash collision between two DIFFERENT citizenids can now, rarely, produce
-- the same colour for two simultaneously-visible trails even when this
-- check finds nothing wrong (paletteLen >= maxVisibleTrails) -- there is no
-- load-time check that can catch that case, since it depends on which
-- citizenids happen to be online, not on any config value alone. Disclosed
-- here and in config.lua's own comment, not silently accepted.
do
    local svConfig = Config.Tracking.ScentVision
    if type(svConfig) == 'table' then
        local paletteLen = type(svConfig.palette) == 'table' and #svConfig.palette or 0
        local wantSlots = type(svConfig.maxVisibleTrails) == 'number' and svConfig.maxVisibleTrails or 0
        if paletteLen > 0 and wantSlots > paletteLen then
            print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.maxVisibleTrails (%s) exceeds ' ..
                'Config.Tracking.ScentVision.palette\'s length (%d) -- colours will be REUSED across ' ..
                'simultaneously-visible trails once more than %d distinct people are shown to the same K9 ' ..
                'at once. Add more palette entries or lower maxVisibleTrails to keep every visible trail a ' ..
                'genuinely distinct colour.'):format(tostring(wantSlots), paletteLen, paletteLen))
        end
    end
end

-- PositionTrail[source] = { {x, y, z, loggedAt}, ... } -- one array-style
-- (never string-keyed) table per CONNECTED player, oldest points evicted
-- first. TrackableLog above is the event-based cousin -- see this section's
-- own header for why the two are kept deliberately separate. Ephemeral,
-- in-memory only, cleared entirely on that source's own playerDropped (see
-- the bottom of this file) -- never persisted, same "live-session data, not
-- account data" posture TrackableLog's own header already documents for
-- itself.
local PositionTrail = {}

-- NO PER-OBSERVER COLOUR STATE ANY MORE (owner-directed follow-up,
-- 2026-08-26 -- see this section's own header "COLOUR SPACE" bullet for the
-- full writeup). This used to be a `ScentVisionColorSlots[observerSource]
-- [slotIndex] = targetSource` table, cleared on the OBSERVING source's own
-- playerDropped -- replaced entirely by ResolveScentVisionColors/
-- HashStringToIndex below, which are pure functions of a citizenid string
-- and need no server-side memory at all. Removed rather than left dead, so
-- a future reader does not wonder whether it is still load-bearing for
-- something.

local ScentVisionQueryCooldown = NewCooldown()
ScentVisionQueryCooldown.RegisterPlayerDropped()

-- How often this thread merely re-checks Config.Features.ScentVision while
-- the feature is off -- cheap, matches client/tracking.lua's own
-- gunpowder-capture-thread idle-poll precedent for the identical
-- "always-existing thread, real work only while the flag is on" shape.
local SCENT_VISION_CAPTURE_IDLE_MS = 5000

--- Simple clamp-and-warn for a ScentVision numeric field that is NOT a
--- millisecond threshold (those go through ResolveConfiguredThresholdMs at
--- each of their own call sites below instead -- see server/cooldowns.lua's
--- own header for why that specific helper exists and is reused rather than
--- duplicated). This one is for a plain count/distance floor -- clamps and
--- warns once per bad read, never throws, same "clamp and warn, never
--- assert" posture this whole resource applies to every operator-editable
--- Config field (a bare assert here would kill every registration below it
--- for this file's whole uptime over one bad number in a 2,000+ line
--- config.lua).
---
--- UPPER CEILING (`maxAllowed`, performance audit at 128 players, this
--- pass): optional, and nil by default -- MOST fields this function
--- resolves (e.g. minSampleMovementMeters) only get SAFER as they get
--- larger (a bigger required-movement distance means FEWER capture writes,
--- never more memory), so they pass no `maxAllowed` and this branch never
--- runs for them. maxPointsPerPerson is the one caller below that DOES pass
--- one, because it is the opposite shape -- a direct per-person storage
--- multiplier -- see that call site's own comment for the exact figure and
--- why it was chosen to match server/runtimecontrol.lua's own tablet-side
--- ceiling for the identical field, rather than inventing a second, looser
--- number for the hand-edit path the tablet does not police.
--- @param configuredValue any
--- @param fallback number
--- @param minAllowed number
--- @param configKeyName string
--- @param maxAllowed number? -- see UPPER CEILING note above; nil (the default at every pre-existing call site) means "no ceiling checked here"
--- @return number
local function ResolveScentVisionNumber(configuredValue, fallback, minAllowed, configKeyName, maxAllowed)
    if type(configuredValue) ~= 'number' or configuredValue ~= configuredValue or configuredValue < minAllowed then
        print(('[qbx_k9unit] ScentVision: %s must be a number >= %s (found: %s) -- falling back to %s.')
            :format(configKeyName, tostring(minAllowed), tostring(configuredValue), tostring(fallback)))
        return fallback
    end
    if maxAllowed and configuredValue > maxAllowed then
        print(
            ('[qbx_k9unit] ScentVision: %s (%s) exceeds the %s ceiling this resource enforces for this field -- ' ..
             'clamping to %s instead. See this field\'s own config.lua/call-site comment for the memory arithmetic ' ..
             'behind that ceiling -- a hand-edit this high bypasses the tablet\'s own %s cap on the identical field ' ..
             'with nothing else in the way.')
                :format(configKeyName, tostring(configuredValue), tostring(maxAllowed), tostring(maxAllowed), tostring(maxAllowed))
        )
        return maxAllowed
    end
    return configuredValue
end

--- Clamp-and-warn for Config.Tracking.ScentVision.mode -- a THREE-WAY
--- STRING choice ('always'/'keybind'/'off'), not a number, so this is its
--- own small resolver rather than a reuse of ResolveScentVisionNumber
--- above. Read FRESH on every getScentVisionPoints call (never captured
--- once), same "server-side is always the live truth" posture every other
--- svConfig.* read in that callback already follows -- this is also
--- EXACTLY what lets an admin's edit reach an already-connected,
--- currently-polling client's own screen live: that client's poll loop
--- treats this echoed value as the authoritative signal to keep rendering
--- or stop, never its own boot-time copy of config.lua alone (see
--- client/tracking.lua's own EnsureScentVisionPollThreadRunning comment).
--- An unrecognised value NEVER silently becomes 'always' (the one choice
--- that puts something on every eligible player's screen unasked) -- it
--- falls back to 'keybind', the same safe default config.lua itself ships.
--- @param configuredValue any
--- @return 'always'|'keybind'|'off'
local function ResolveScentVisionMode(configuredValue)
    if configuredValue == 'always' or configuredValue == 'keybind' or configuredValue == 'off' then
        return configuredValue
    end
    print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.mode must be one of "always", "keybind", or "off" (got %s) -- falling back to "keybind".')
        :format(tostring(configuredValue)))
    return 'keybind'
end

--- Drops every already-expired point from `bucket` IN PLACE, evaluated
--- against EACH POINT'S OWN `loggedAt` timestamp compared to `now` -- never
--- a decremented per-frame countdown (owner's own explicit requirement: a
--- stutter, an alt-tab, or a paused resource must never stretch a 45s dot
--- into something longer). Used both at CAPTURE time (discard-on-write,
--- below) and by the periodic sweep thread further below (for a person who
--- has stopped moving and so stopped triggering the on-write sweep).
--- @param bucket table
--- @param now number
--- @param lifetimeMs number
local function DiscardExpiredScentVisionPoints(bucket, now, lifetimeMs)
    local i = 1
    while i <= #bucket do
        if (now - bucket[i][4]) >= lifetimeMs then
            table.remove(bucket, i) -- cheap: bucket is capped at maxPointsPerPerson (15 shipped), never a real hot-path array
        else
            i = i + 1
        end
    end
end

--- Records one fresh sample of `src`'s own live position, IF they have
--- moved far enough since their own last recorded point. DISCARD ON WRITE
--- (owner's own explicit instruction): every call first drops this SAME
--- person's already-expired points before deciding whether to append a new
--- one -- never accumulate-then-filter-only-at-read.
---
--- LOITER FIX (this pass, coder-frontend -- competitor-parity request:
--- mana_policedogs "if a player hasn't moved far enough away from their
--- last dropped scent, their existing scent will have its decay reset").
--- CONFIRMED BUG, this pass: the "hasn't moved far enough" branch below
--- used to just `return` -- doing nothing at all to the existing nearest
--- point. That point's own `[4]` (loggedAt) timestamp was never touched,
--- so a player standing (or hiding) perfectly still had their ONE dot
--- silently age out on schedule regardless -- indistinguishable, from
--- DiscardExpiredScentVisionPoints' own perspective, from that player
--- having left minutes ago. FIXED: the SAME branch that decides not to add
--- a new point now refreshes that existing point's own timestamp to `now`
--- instead of leaving it untouched -- so a player who stays within
--- `minMovement` of their own last recorded spot keeps a single dot fresh
--- there for as long as they stay, and it only starts counting down for
--- real the moment they actually move away past `minMovement` (which
--- immediately records a genuinely NEW point at the new spot on the very
--- next capture pass, per the branch below this one, unchanged).
---
--- STORAGE IMPACT: this can only ever REDUCE growth relative to before,
--- never increase it. The "moved far enough" check already existed and
--- already skipped appending in this exact case -- this fix only changes
--- what happens to the ALREADY-existing point in that same skip, never
--- adds a new array slot, and never bypasses maxPoints/dotLifetimeMs
--- (a refreshed point still counts as exactly one entry against
--- maxPointsPerPerson, same as before). If anything this REDUCES the
--- steady-state entry count for a stationary player: without this fix, a
--- player standing still for longer than dotLifetimeMs would have their
--- one dot expire and then get reinstated as a brand-new dot the next time
--- they took one big step, or simply stay at zero dots between then; with
--- this fix that same player holds exactly one live, continuously-refreshed
--- dot the entire time -- never more than the one dot minMovement was
--- already limiting them to.
--- @param src number
--- @param coords vector3
--- @param now number
--- @param minMovement number
--- @param maxPoints number
--- @param lifetimeMs number
local function RecordScentVisionPoint(src, coords, now, minMovement, maxPoints, lifetimeMs)
    local bucket = PositionTrail[src]
    if not bucket then
        bucket = {}
        PositionTrail[src] = bucket
    end

    DiscardExpiredScentVisionPoints(bucket, now, lifetimeMs)

    local last = bucket[#bucket]
    if last then
        local dx, dy, dz = coords.x - last[1], coords.y - last[2], coords.z - last[3]
        if (dx * dx + dy * dy + dz * dz) < (minMovement * minMovement) then
            -- LOITER FIX -- refresh this SAME point's own age instead of
            -- leaving it to decay on a clock that no longer reflects
            -- reality (see this function's own doc comment above).
            -- Deliberately mutates index [4] in place (never re-appends),
            -- so this can never grow `bucket` past its current length.
            last[4] = now
            return -- hasn't moved far enough since their own last recorded point -- decay reset, not a new point
        end
    end

    bucket[#bucket + 1] = { coords.x, coords.y, coords.z, now }

    -- Hard count ceiling, independent of the age-based discard above -- see
    -- this section's own header "STORAGE ceiling" note for why this is the
    -- number this pass's memory math is actually computed from.
    while #bucket > maxPoints do
        table.remove(bucket, 1)
    end
end

-- ======================================================================
-- UPPER CEILING for maxPointsPerPerson (performance audit at 128 players,
-- this pass). Matches server/runtimecontrol.lua's own tablet-editable bound
-- for this EXACT field (`['Tracking.ScentVision.maxPointsPerPerson'] =
-- { ..., min = 1, max = 50, ... }`) -- deliberately the SAME number, not a
-- separately-chosen one, so a config.lua hand-edit cannot reach a value the
-- tablet's own UI already refuses to let an admin set. Without this, the
-- worked example from this section's own header comment above ("STORAGE
-- ceiling") stops holding: a hand-edited maxPointsPerPerson of 100,000
-- would multiply directly into PositionTrail's per-player storage (this
-- section's own header already establishes ~150 bytes/point as this
-- resource's working estimate for one point) --
--   100,000 points x 150 bytes = ~14.3MB PER CONNECTED PLAYER, i.e. up to
--   ~1.8GB at 128 players, or ~14.6GB at FiveM's documented 1024-slot hard
--   ceiling (already cited in this section's own header) -- entirely
--   bypassing the "trivial, ~440KB-2.2MB" conclusion that header's own
--   arithmetic reached for the shipped default.
-- At the ceiling enforced here instead (50, matching the tablet):
--   128 players x 50 points x 150 bytes = ~960KB; even at the 1024-slot
--   hard ceiling, 1024 x 50 x 150 bytes = ~7.3MB -- both comfortably inside
--   "trivial against a real server's memory budget", the same conclusion
--   this section's header already draws for the shipped default of 15.
-- ======================================================================
local SCENT_VISION_MAX_POINTS_PER_PERSON_CEILING = 50

-- CAPTURE THREAD -- population-wide, unconditional while the feature flag
-- is on (mirrors this file's own established "capture is population-wide by
-- design" posture already documented above for blood/gunpowder/scent --
-- ScentVision is not a suspect-targeted mechanic, it is a general "who
-- walked through here" reveal). `Wait` is the FIRST statement of every pass
-- through this loop, matching PruneTrackableLogs' own thread above and this
-- resource's general sweep-thread convention.
CreateThread(function()
    while true do
        if Config.Features.ScentVision then
            local svConfig = Config.Tracking.ScentVision or {}
            local interval = ResolveConfiguredThresholdMs(svConfig.sampleIntervalMs, 4000, 'Config.Tracking.ScentVision.sampleIntervalMs')
            Wait(interval)

            local minMovement = ResolveScentVisionNumber(svConfig.minSampleMovementMeters, 2.0, 0.0, 'Config.Tracking.ScentVision.minSampleMovementMeters')
            local maxPoints = ResolveScentVisionNumber(svConfig.maxPointsPerPerson, 15, 1, 'Config.Tracking.ScentVision.maxPointsPerPerson', SCENT_VISION_MAX_POINTS_PER_PERSON_CEILING)
            local lifetimeMs = ResolveConfiguredThresholdMs(svConfig.dotLifetimeMs, 45000, 'Config.Tracking.ScentVision.dotLifetimeMs')
            local now = GetGameTimer()

            for _, playerIdStr in ipairs(GetPlayers()) do
                local src = tonumber(playerIdStr)
                if src then
                    local ped = GetPlayerPed(src)
                    if ped ~= 0 then
                        RecordScentVisionPoint(src, GetEntityCoords(ped), now, minMovement, maxPoints, lifetimeMs)
                    end
                end
            end
        else
            Wait(SCENT_VISION_CAPTURE_IDLE_MS)
        end
    end
end)

--- Age-based sweep for PositionTrail, on its OWN independent thread/cadence
--- (TRACKABLE_LOG_PRUNE_INTERVAL_MS, the same interval PruneTrackableLogs'
--- own thread already uses above, reused here for consistency rather than
--- inventing a second magic number -- kept as a SEPARATE thread rather than
--- folded into that existing one so this section stays self-contained and
--- does not require editing that earlier, already-tested thread body).
--- Belt-and-suspenders alongside RecordScentVisionPoint's own
--- discard-on-write above, for a person who has stopped moving (and so
--- stopped triggering that on-write sweep) or disconnected without a clean
--- playerDropped firing for some reason. Drops the whole bucket once it
--- holds no remaining live points, so an idle/departed player's entry does
--- not linger in PositionTrail forever.
local function PruneScentVisionPoints()
    local svConfig = Config.Tracking.ScentVision or {}
    local lifetimeMs = ResolveConfiguredThresholdMs(svConfig.dotLifetimeMs, 45000, 'Config.Tracking.ScentVision.dotLifetimeMs')
    local now = GetGameTimer()

    for src, bucket in pairs(PositionTrail) do
        DiscardExpiredScentVisionPoints(bucket, now, lifetimeMs)
        if #bucket == 0 then
            PositionTrail[src] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(TRACKABLE_LOG_PRUNE_INTERVAL_MS)
        PruneScentVisionPoints()
    end
end)

--- @return table[] -- Config.Tracking.ScentVision.palette, defensively
--- defaulted to a single fallback swatch if config.lua's own array is
--- missing/empty (should never happen with a shipped config.lua -- see this
--- section's own load-time sanity check above for the "too SHORT" case,
--- which degrades to colour reuse rather than this near-impossible "empty"
--- case).
local function ResolveScentVisionPalette()
    local palette = Config.Tracking.ScentVision and Config.Tracking.ScentVision.palette
    if type(palette) == 'table' and #palette > 0 then
        return palette
    end
    return { { r = 255, g = 255, b = 255 } }
end

--- Deterministic, stateless string -> palette-index hash (owner-directed
--- follow-up, 2026-08-26 -- see this section's own header "COLOUR SPACE"
--- bullet). DJB2-shaped (multiply-and-add accumulate) -- chosen only for
--- being a well-known, trivially reproducible byte hash; this has NO
--- cryptographic requirement, the only property leaned on is "the same
--- string always yields the same index, and different strings spread
--- reasonably evenly across a small palette", which any stable string hash
--- gives for free. Used for BOTH the per-person trail colour
--- (`citizenid` -> Config.Tracking.ScentVision.palette index) and the
--- per-category contraband highlight colour (a Config.K9Specializations key
--- -> Config.Tracking.ScentVision.contrabandHighlight.categoryPalette
--- index) below -- ONE shared utility, not two copies, since both are the
--- exact same "stable string -> small palette" problem. Lua 5.4 integers
--- wrap on overflow rather than erroring (confirmed language behaviour, not
--- an assumption -- Lua 5.4 manual §3.4.1), so this never throws regardless
--- of input length.
--- @param value string
--- @param paletteLen number -- must be >= 1 (every caller below resolves its
--- own palette through a defensively-defaulted Resolve*Palette function
--- first, so this is never called with 0)
--- @return number index -- 1-based, in [1, paletteLen]
local function HashStringToIndex(value, paletteLen)
    local hash = 5381
    for i = 1, #value do
        hash = (hash * 33 + value:byte(i)) % 2147483647
    end
    return (hash % paletteLen) + 1
end

--- @param src number
--- @return string? citizenid -- nil if `src` is not a currently-connected,
--- fully-loaded qbx_core player (matches every other "soft" citizenid
--- resolution already in this file/server/search.lua -- never throws).
local function ResolveCitizenIdForSource(src)
    local player = exports.qbx_core:GetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

--- Resolves a STABLE colour for each entry in `visibleSources` (already
--- ranked nearest-first, length already capped at maxVisibleTrails by the
--- caller) -- DETERMINISTICALLY, from each trail owner's own durable
--- citizenid, via HashStringToIndex above. Pure function of who is
--- currently visible: no server-side memory of its own (see this section's
--- own "NO PER-OBSERVER COLOUR STATE ANY MORE" comment above for what this
--- replaced and why), so the SAME person is the SAME colour for EVERY
--- handler watching and across the whole session -- the owner's own
--- explicit ask this pass. A trail owner whose citizenid cannot be resolved
--- right now (mid-disconnect race -- see this file's own recycled-source
--- discipline elsewhere) is simply given no colour at all and dropped by
--- the caller, rather than guessed at.
--- @param visibleSources number[]
--- @return table<number, table> colorBySource
local function ResolveScentVisionColors(visibleSources)
    local palette = ResolveScentVisionPalette()

    local colorBySource = {}
    for _, src in ipairs(visibleSources) do
        local citizenid = ResolveCitizenIdForSource(src)
        if citizenid then
            colorBySource[src] = palette[HashStringToIndex(citizenid, #palette)]
        end
    end

    return colorBySource
end

-- ======================================================================
-- CONTRABAND CATEGORY LOOKUP -- TEMPORARY, DISCLOSED DUPLICATION of
-- server/search.lua's own `ContrabandItemInfo` parse of
-- Config.SearchContrabandItems (same dual array/keyed-entry shape, same
-- clamp-and-warn degrade for a category naming something that is not a
-- real Config.K9Specializations key -- see that file's own ContrabandItemInfo
-- header for the full writeup this mirrors). This is the SAME config
-- table, read the SAME way, for the SAME reason server/search.lua reads it
-- -- NOT a second, independently-evolving notion of "what is contraband".
-- It is duplicated here, rather than called via a single shared function,
-- ONLY because server/search.lua exposes no export today for this file to
-- call into instead, and this pass's own file-ownership boundary puts
-- server/search.lua out of reach to edit directly (a minimal, read-only
-- export has been requested from coder-backend -- see this pass's own
-- report). THE INSTANT that export lands: delete this table and
-- CollectContrabandCategoriesPresent below, and call into it instead. Until
-- then, if this table and server/search.lua's ContrabandItemInfo ever
-- disagree because one was edited without the other, that is a real bug --
-- re-diff the two whenever Config.SearchContrabandItems' own shape changes.
-- Note this DOES mean a malformed Config.SearchContrabandItems category
-- entry now prints its clamp-and-warn TWICE at boot (once from this file,
-- once from server/search.lua) -- harmless, if slightly noisy; both warn
-- about the exact same misconfiguration and both degrade the exact same
-- way (uncategorised, found by everyone).
-- ======================================================================
local CONTRABAND_ITEM_CATEGORY = {}
do
    local knownSpecializations = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    local rawList = type(Config.SearchContrabandItems) == 'table' and Config.SearchContrabandItems or {}
    for key, value in pairs(rawList) do
        if type(key) == 'number' then
            -- Array entry: `value` is the item name, uncategorised. `false`
            -- (never `nil`) is the sentinel -- see
            -- CollectContrabandCategoriesPresent below for why the
            -- distinction between "absent" (nil, not contraband at all) and
            -- "present but uncategorised" (false) matters.
            if type(value) == 'string' then
                CONTRABAND_ITEM_CATEGORY[value] = false
            end
        elseif type(key) == 'string' then
            if type(value) == 'string' and knownSpecializations[value] ~= nil then
                CONTRABAND_ITEM_CATEGORY[key] = value
            else
                print(('[qbx_k9unit] ScentVision contraband highlight: Config.SearchContrabandItems[%q] names category %q, which is not a key in Config.K9Specializations -- treating %q as UNCATEGORISED (highlighted for every K9 with search access, regardless of specialization), matching server/search.lua\'s own identical degrade for the same malformed entry.'):format(key, tostring(value), key))
                CONTRABAND_ITEM_CATEGORY[key] = false
            end
        end
    end
end

-- Mirrors server/search.lua's own MAX_CONTAINER_RECURSION_DEPTH -- same
-- reasoning (DEVELOPER_REFERENCE.md#contraband-search §2: "an explicitly
-- chosen max depth -- not unbounded, and not skipped"), same number,
-- disclosed duplication for the same reason CONTRABAND_ITEM_CATEGORY above
-- is.
local CONTRABAND_HIGHLIGHT_MAX_RECURSION_DEPTH = 3

--- Recurses into `items` (and any nested container, up to
--- CONTRABAND_HIGHLIGHT_MAX_RECURSION_DEPTH -- "put the drugs in a bag" must
--- not defeat this the same way it must not defeat a real search) and
--- records WHICH categories are physically present -- never a weight, a
--- count, or an item name. Mirrors SumContrabandWeight's own recursion
--- shape (server/search.lua) but stops at "is at least one matching slot
--- present", since the highlight only ever needs a boolean per category.
--- @param inventoryId string|number
--- @param items table<number, table>?
--- @param depth number
--- @param presentCategories table<string, boolean> -- mutated in place
--- @return boolean hasUncategorised
local function CollectContrabandCategoriesPresent(inventoryId, items, depth, presentCategories)
    local hasUncategorised = false
    if not items then return hasUncategorised end

    for _, slot in pairs(items) do
        local category = CONTRABAND_ITEM_CATEGORY[slot.name]
        if category ~= nil then
            if category == false then
                hasUncategorised = true
            else
                presentCategories[category] = true
            end
        end

        if depth < CONTRABAND_HIGHLIGHT_MAX_RECURSION_DEPTH then
            -- Same K9Compat.Get('inventory').GetContainerFromSlot route
            -- SumContrabandWeight uses, same pcall-wrapped defensive
            -- posture (a mid-scan entity/inventory change could error
            -- rather than cleanly return nil).
            local containerOk, containerInv = pcall(function()
                return K9Compat.Get('inventory').GetContainerFromSlot(inventoryId, slot.slot)
            end)
            if containerOk and containerInv and containerInv.items then
                local nestedUncategorised = CollectContrabandCategoriesPresent(
                    containerInv.id or inventoryId, containerInv.items, depth + 1, presentCategories)
                hasUncategorised = hasUncategorised or nestedUncategorised
            end
        end
    end

    return hasUncategorised
end

--- Mirrors server/search.lua's own ResolveHeldContrabandCategoriesForCitizenId
--- (same HasSpecialization + Config.K9Specializations read). This specific
--- check -- "does citizenid hold specialization X" -- is ALREADY
--- independently duplicated between this file's own
--- ResolveEnabledTrackTypesForCitizenId (above, gating
--- Config.SpecializationTracking) and server/search.lua's version (gating
--- Config.SearchContrabandItems categories), and that has always been fine:
--- the check itself is one global call with no ITEM-level state of its own
--- to drift. What must NOT be duplicated is server/search.lua's own
--- Config.SearchContrabandItems ITEM-categorisation table -- see
--- CONTRABAND_ITEM_CATEGORY's own header above for why that one really is a
--- temporary, disclosed duplication rather than an accepted pattern.
--- @param citizenid string?
--- @param jobName string?
--- @return table<string, boolean> heldCategories
local function ResolveHeldContrabandSpecializationsForCitizenId(citizenid, jobName)
    local held = {}
    if type(HasSpecialization) ~= 'function' or type(citizenid) ~= 'string' then
        return held
    end
    -- ROLES (server/roles.lua): a category counts when a held, unlocked
    -- role has detect_<category>.
    if type(GetHeldRoleUnlocks) == 'function' then
        for unlock in pairs(GetHeldRoleUnlocks(citizenid, jobName)) do
            local category = unlock:match('^detect_(.+)$')
            if category then held[category] = true end
        end
        return held
    end
    local knownSpecializations = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    for specKey in pairs(knownSpecializations) do
        if HasSpecialization(citizenid, jobName, specKey) then
            held[specKey] = true
        end
    end
    return held
end

--- @return boolean
local function IsContrabandHighlightEnabled()
    local ch = Config.Tracking.ScentVision and Config.Tracking.ScentVision.contrabandHighlight
    return type(ch) == 'table' and ch.enabled == true
end

--- Clamp-and-warn: Config.Tracking.ScentVision.contrabandHighlight.rangeMeters
--- must be a positive number, and is HARD-CEILINGED at
--- Config.SearchZones.personSearchDistance -- the SAME distance a real
--- "Search Person" interaction already requires -- see that config
--- field's own contrabandHighlight comment for why: a bigger number here is
--- exactly the "scan a crowd from range" x-ray this feature must never
--- become. A hand-edit above that ceiling is CLAMPED DOWN to it, never
--- honoured -- same "clamp and warn, never assert, never silently honour a
--- dangerous value" posture this whole file applies everywhere else.
--- @param configuredValue any
--- @return number
local function ResolveContrabandHighlightRangeMeters(configuredValue)
    local ceiling = 2.0
    if type(Config.SearchZones) == 'table' and type(Config.SearchZones.personSearchDistance) == 'number'
        and Config.SearchZones.personSearchDistance > 0 then
        ceiling = Config.SearchZones.personSearchDistance
    end

    if type(configuredValue) ~= 'number' or configuredValue ~= configuredValue or configuredValue <= 0 then
        print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.contrabandHighlight.rangeMeters must be a positive number (found: %s) -- falling back to %s.'):format(tostring(configuredValue), tostring(ceiling)))
        return ceiling
    end
    if configuredValue > ceiling then
        print(('[qbx_k9unit] ScentVision: Config.Tracking.ScentVision.contrabandHighlight.rangeMeters (%s) exceeds Config.SearchZones.personSearchDistance (%s) -- this feature must never see further than a real search already reaches, so it is clamped down to %s instead.'):format(tostring(configuredValue), tostring(ceiling), tostring(ceiling)))
        return ceiling
    end
    return configuredValue
end

--- @return table[]
local function ResolveContrabandCategoryPalette()
    local ch = Config.Tracking.ScentVision and Config.Tracking.ScentVision.contrabandHighlight
    local palette = ch and ch.categoryPalette
    if type(palette) == 'table' and #palette > 0 then
        return palette
    end
    return { { r = 255, g = 255, b = 255 } }
end

--- @return table
local function ResolveContrabandBaselineColor()
    local ch = Config.Tracking.ScentVision and Config.Tracking.ScentVision.contrabandHighlight
    local color = ch and ch.baselineColor
    if type(color) == 'table' and type(color.r) == 'number' and type(color.g) == 'number' and type(color.b) == 'number' then
        return color
    end
    return { r = 241, g = 196, b = 15 }
end

--- Owner-directed pass ("scent vision" keybind). Resolves the caller's own
--- live server position (never a client-supplied one) and returns AT MOST
--- Config.Tracking.ScentVision.maxVisibleTrails distinct OTHER connected
--- players' own recent walked-path points, nearest trail first, each
--- ALREADY coloured server-side (see ResolveScentVisionColors above) -- the
--- client never learns WHO a dot belongs to, never learns about anyone
--- outside range/the visible-set cap, and never receives the server's whole
--- population regardless of how many people are actually connected. Also
--- returns `highlights` -- at most `visibleSources` entries (so bounded by
--- the SAME maxVisibleTrails cap), each ALREADY reduced server-side to
--- nothing but a network id and a short list of pre-resolved RGB swatches
--- for contraband categories that BOTH the caller holds the matching
--- specialization for AND the target is actually carrying right now (see
--- this section's own header, "CONTRABAND BODY HIGHLIGHT", for the full
--- five-point design writeup). See this section's own header for the full
--- per-query cost bound.
lib.callback.register('qbx_k9unit:server:getScentVisionPoints', function(source)
    -- `mode = 'off'` echoed here too, deliberately -- the master feature
    -- being off is functionally IDENTICAL to mode == 'off' from a
    -- currently-polling client's own point of view (nothing to show, the
    -- keybind should do nothing), and client/tracking.lua's own live-stop
    -- check only ever looks at THIS field, never at a second "was it the
    -- feature or the mode" distinction -- one signal, one stop path. This
    -- is also, TODAY, the only way an admin's LIVE tablet edit (this
    -- feature flag already carries `tier = 'live'` in
    -- server/runtimecontrol.lua's own FEATURE_TIERS) reaches an
    -- already-rendering player's screen without a restart: `mode` itself
    -- is not yet tablet-editable (see config.lua's own comment on
    -- Config.Tracking.ScentVision.mode for why), but this flag already is.
    if not Config.Features.ScentVision then return { points = {}, highlights = {}, mode = 'off' } end
    if not HasK9Access(source) then return { points = {}, highlights = {} } end

    -- PER-PERSON FEATURE CONTROL -- same shared 4-step resolution as
    -- Scent/Blood/Gunpowder above (IsTrackingFeaturePermittedForCitizenId),
    -- checked BEFORE the query cooldown below is ever consumed, same "a
    -- block must never burn a cooldown slot" ordering findTrackableSource
    -- already establishes.
    local callerPlayer = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = callerPlayer and callerPlayer.PlayerData and callerPlayer.PlayerData.citizenid
    local callerJobName = callerPlayer and callerPlayer.PlayerData and callerPlayer.PlayerData.job
        and callerPlayer.PlayerData.job.name
    if not callerCitizenid or not IsTrackingFeaturePermittedForCitizenId(callerCitizenid, 'ScentVision') then
        return { points = {}, highlights = {} }
    end

    local svConfig = Config.Tracking.ScentVision or {}

    -- MODE IS A SERVER-SIDE GATE, NOT A CLIENT-SIDE COURTESY.
    --
    -- This was a real, reproduced leak. `mode` used to be resolved further
    -- down purely so it could be echoed back for the client to decide
    -- whether to render, and client/tracking.lua duly stopped polling when
    -- it read 'off'. But an operator setting mode = 'off' is switching the
    -- feature OFF, and config.lua promises exactly that ("nobody sees this
    -- at all, ever"). Enforcing that only on the client meant any certified
    -- handler with a modified client could call this callback directly on
    -- the 1s cooldown floor and receive live, colour-coded position trails
    -- of every player in range -- a real-time wallhack, precisely while the
    -- admin control that was supposed to prevent it was switched on.
    -- Background capture keeps running in 'off' mode by design, so the data
    -- was always fresh and waiting.
    --
    -- Checked BEFORE the query cooldown below is consumed, matching this
    -- file's own established ordering: a refusal must never burn a
    -- cooldown slot for a request that was never going to be answered.
    -- This file's header already promised a trust boundary on the RANGE and
    -- POPULATION axes; the mode axis is new and the promise now covers it
    -- too.
    if ResolveScentVisionMode(svConfig.mode) == 'off' then
        return { points = {}, highlights = {}, mode = 'off' }
    end

    local now = GetGameTimer()
    local cooldownMs = ResolveConfiguredThresholdMs(svConfig.queryCooldownMs, 1000, 'Config.Tracking.ScentVision.queryCooldownMs')
    if not ScentVisionQueryCooldown.Consume(source, cooldownMs, now) then
        return { points = {}, highlights = {} } -- rate-limited -- same bare, reasonless shape every other denial in this callback uses
    end

    local ped = GetPlayerPed(source)
    if ped == 0 then return { points = {}, highlights = {} } end
    local myCoords = GetEntityCoords(ped)

    local range = ResolveScentVisionNumber(svConfig.queryRangeMeters, 40.0, 1.0, 'Config.Tracking.ScentVision.queryRangeMeters')
    local rangeSq = range * range
    local lifetimeMs = ResolveConfiguredThresholdMs(svConfig.dotLifetimeMs, 45000, 'Config.Tracking.ScentVision.dotLifetimeMs')
    local maxVisible = ResolveScentVisionNumber(svConfig.maxVisibleTrails, 5, 1, 'Config.Tracking.ScentVision.maxVisibleTrails')
    local maxPerTrail = ResolveScentVisionNumber(svConfig.queryMaxPointsPerTrail, 12, 1, 'Config.Tracking.ScentVision.queryMaxPointsPerTrail')
    local mode = ResolveScentVisionMode(svConfig.mode)

    -- Rank every OTHER connected player with at least one still-live point
    -- in range by THAT trail's OWN nearest point -- never the caller's own
    -- trail (showing a K9 handler their own footprints is not useful; see
    -- this section's header).
    local ranked = {}
    for src, bucket in pairs(PositionTrail) do
        if src ~= source then
            local nearestDistSq
            for _, pt in ipairs(bucket) do
                if (now - pt[4]) < lifetimeMs then
                    local dx, dy, dz = pt[1] - myCoords.x, pt[2] - myCoords.y, pt[3] - myCoords.z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= rangeSq and (not nearestDistSq or distSq < nearestDistSq) then
                        nearestDistSq = distSq
                    end
                end
            end
            if nearestDistSq then
                ranked[#ranked + 1] = { src = src, distSq = nearestDistSq }
            end
        end
    end
    table.sort(ranked, function(a, b) return a.distSq < b.distSq end)

    -- DEGRADE RULE (owner's own explicit instruction): under load, drop the
    -- FURTHEST trail first -- `ranked` is already nearest-first, so simple
    -- truncation IS that rule.
    local visibleSources = {}
    for i = 1, math.min(#ranked, maxVisible) do
        visibleSources[#visibleSources + 1] = ranked[i].src
    end

    local colorBySource = ResolveScentVisionColors(visibleSources)

    -- CONTRABAND BODY HIGHLIGHT -- see this section's own header (bullets
    -- 1-5) for the full design writeup. Computed here, inside the SAME
    -- guarded flow/poll as the trail reveal above (feature flag, per-person
    -- block, live mode, and rate-limit have all already been checked and
    -- consumed above this point) -- never a second callback, never a second
    -- cooldown.
    local highlights = {}
    if IsContrabandHighlightEnabled() then
        local highlightRange = ResolveContrabandHighlightRangeMeters(
            svConfig.contrabandHighlight and svConfig.contrabandHighlight.rangeMeters)
        local highlightRangeSq = highlightRange * highlightRange
        local heldCategories = ResolveHeldContrabandSpecializationsForCitizenId(callerCitizenid, callerJobName)
        local categoryPalette = ResolveContrabandCategoryPalette()
        local baselineColor = ResolveContrabandBaselineColor()

        for _, src in ipairs(visibleSources) do
            local targetPed = GetPlayerPed(src)
            if targetPed ~= 0 then
                -- REAL, SERVER-READ coordinates for BOTH peds -- never a
                -- client-supplied position for either side, and never the
                -- (possibly several-seconds-stale) PositionTrail sample
                -- used for trail reveal above.
                local targetCoords = GetEntityCoords(targetPed)
                local dx, dy, dz = targetCoords.x - myCoords.x, targetCoords.y - myCoords.y, targetCoords.z - myCoords.z
                local distSq = dx * dx + dy * dy + dz * dz
                if distSq <= highlightRangeSq then
                    local queryOk, items = pcall(function()
                        return K9Compat.Get('inventory').GetInventoryItems(src)
                    end)
                    if queryOk and items then
                        local presentCategories = {}
                        local collectOk, hasUncategorised = pcall(
                            CollectContrabandCategoriesPresent, src, items, 1, presentCategories)
                        if collectOk then
                            local colors = {}
                            if hasUncategorised then
                                colors[#colors + 1] = baselineColor
                            end

                            -- Sorted so the ORDER these render in is stable
                            -- frame-to-frame/poll-to-poll -- never dependent
                            -- on pairs()' unspecified iteration order.
                            local matchedCategories = {}
                            for category in pairs(presentCategories) do
                                if heldCategories[category] then
                                    matchedCategories[#matchedCategories + 1] = category
                                end
                            end
                            table.sort(matchedCategories)

                            for _, category in ipairs(matchedCategories) do
                                colors[#colors + 1] = categoryPalette[HashStringToIndex(category, #categoryPalette)]
                            end

                            -- Only ever emit an entry when there is actually
                            -- something to show -- never a present-but-empty
                            -- entry a modified client could use to learn
                            -- "the server checked this person and found
                            -- nothing", which would itself leak more than
                            -- intended (see this section's own header,
                            -- decision 2).
                            if #colors > 0 then
                                highlights[#highlights + 1] = {
                                    -- Identifies WHICH already-visible, real
                                    -- player entity to draw on -- never a
                                    -- citizenid/name, and never anything a
                                    -- client could not already read off that
                                    -- same entity locally (a nearby ped's own
                                    -- network id is ordinary client-visible
                                    -- state, not privileged identity).
                                    netId = NetworkGetNetworkIdFromEntity(targetPed),
                                    colors = colors,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    local points = {}
    for _, src in ipairs(visibleSources) do
        local bucket = PositionTrail[src]
        local color = colorBySource[src]
        if bucket and color then
            -- Nearest-first WITHIN this one trail too, so a per-trail cap
            -- also drops the FURTHEST points of that one trail first.
            local trailPoints = {}
            for _, pt in ipairs(bucket) do
                local age = now - pt[4]
                if age < lifetimeMs then
                    local dx, dy, dz = pt[1] - myCoords.x, pt[2] - myCoords.y, pt[3] - myCoords.z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= rangeSq then
                        trailPoints[#trailPoints + 1] = { x = pt[1], y = pt[2], z = pt[3], ageMs = age, distSq = distSq }
                    end
                end
            end
            table.sort(trailPoints, function(a, b) return a.distSq < b.distSq end)

            for i = 1, math.min(#trailPoints, maxPerTrail) do
                local tp = trailPoints[i]
                points[#points + 1] = {
                    x = tp.x, y = tp.y, z = tp.z,
                    -- RELATIVE age, in milliseconds, as measured by THIS
                    -- SERVER's own clock at THIS instant -- never a raw
                    -- GetGameTimer() timestamp handed to the client. Server
                    -- and client each run their OWN independent
                    -- GetGameTimer() counter (process uptime, not a shared
                    -- wall clock), so sending a raw server timestamp for the
                    -- client to compare against its own GetGameTimer() would
                    -- be comparing two unrelated counters. The client instead
                    -- anchors this relative age to ITS OWN GetGameTimer() the
                    -- instant this response arrives and counts up locally
                    -- from there -- see client/tracking.lua's own comment on
                    -- this exact field for the receiving side.
                    ageMs = tp.ageMs,
                    r = color.r, g = color.g, b = color.b,
                }
            end
        end
    end

    return {
        points = points,
        highlights = highlights,
        -- Echoed back so the client fades/expires every point in THIS
        -- response against the SAME lifetime THIS SERVER actually enforced
        -- for it, rather than trusting its own possibly-stale local config
        -- copy -- informational/defense-in-depth, same posture
        -- findTrackableSource's own `breaksAtWater` field already documents
        -- for itself above.
        dotLifetimeMs = lifetimeMs,
        -- THE SERVER'S OWN LIVE VALUE, resolved fresh above -- NEVER the
        -- client's own boot-time copy of config.lua. client/tracking.lua's
        -- poll loop treats `mode == 'off'` here as an unconditional,
        -- immediate stop (see that file's own comment on this exact field)
        -- -- this is the one channel that makes turning ScentVision off
        -- reach an already-rendering player's screen live, on THIS pass,
        -- without waiting for a restart. It is informational for 'always'/
        -- 'keybind' -- the client never auto-STARTS off this field, only
        -- ever auto-STOPS, per this codebase's own "gate the start, never
        -- the stop" rule.
        mode = mode,
    }
end)

AddEventHandler('playerDropped', function(_reason)
    local src = source
    PendingTrackArrival[src] = nil
    -- SCENT VISION cleanup -- see PositionTrail's own declaration comment
    -- above. Clearing PositionTrail[src] here (rather than waiting for
    -- PruneScentVisionPoints' own periodic sweep) means a disconnecting
    -- player can never again appear in a future query's `ranked` candidate
    -- list for anyone. There is no colour-slot state to clean up any more
    -- (ResolveScentVisionColors is now a pure function of citizenid -- see
    -- that function's own declaration comment above for what this
    -- replaced).
    PositionTrail[src] = nil
end)
