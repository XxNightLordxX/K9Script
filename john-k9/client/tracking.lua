--[[
    john-k9/client/tracking.lua

    Phase 2 (coder-frontend). Owns the three self-initiated "Track <Type>"
    trail mechanics (scent, blood, gunpowder) and the water-crossing degrade
    modifier that applies to whichever trail is currently rendering —
    DEVELOPER_REFERENCE.md §11.1 sub-phases 2d/2e/2f, §11.3's `client/tracking.lua` row.
    All three trail types share ONE file (not one file per type) and call
    ONE parameterized server callback, per §11.3/§11.4 item 1.

    Supplementary implementation detail (non-authoritative — DEVELOPER_REFERENCE.md §11 is
    the source of truth if anything here drifts from it):
    DEVELOPER_REFERENCE.md#tracking, DEVELOPER_REFERENCE.md#tracking,
    DEVELOPER_REFERENCE.md#tracking, DEVELOPER_REFERENCE.md#tracking.
    NOTE ON THE "§N" SUFFIXES cited below (e.g. "#tracking §1.2", "#tracking
    §0"): those are leftover pinpoints from the pre-2026-08-25 research
    archive's own internal numbering, which did not survive that file's
    consolidation into DEVELOPER_REFERENCE.md's §15 prose — see that
    section's own header note for the full explanation. Read the anchor
    (#tracking) as the real target; the number after it will not resolve to
    a matching subsection.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per DEVELOPER_REFERENCE.md §11.4 items 1, 3, 4 and
    item 7's "no dedicated result-delivery event" note. Server side lives in
    server/tracking.lua (confirmed against that file's own header as of this
    pass — same contract, no drift).

    Callbacks (ox_lib lib.callback):
    1. 'john-k9:server:findTrackableSource' (trackType: 'scent'|'blood'|'gunpowder')
       -> { found: boolean, coords: vector3?, breaksAtWater: boolean }
       [server/tracking.lua]
       Re-validates Config.Features.<Type> and HasK9Access(source)
       server-side regardless of client UI state. Resolves the CALLER'S
       OWN live server-side position — never a client-supplied coordinate.
       Enforces Config.Tracking.<Type>.searchCooldownMs per caller.
       `breaksAtWater` is documented (§11.4 item 1) as informational only
       — since config.lua is a shared_script, THIS FILE reads
       Config.WaterTrackingDecay.breaksTrail directly rather than trusting
       this echoed field (DEVELOPER_REFERENCE.md#tracking §1.2).
       No `reason` field exists on this response (unlike searchTarget's) —
       "nothing nearby" / "on cooldown" / "no access" all collapse to the
       same `found = false` here; ship one generic message
       (DEVELOPER_REFERENCE.md#tracking §2.4).

    Server events (RegisterNetEvent, client->server; THIS FILE triggers,
    does not receive, these two):
    2. 'john-k9:server:relayDamageEvent' () [server/tracking.lua]
       Fired by THIS FILE's own 'gameEventTriggered' handler below when the
       LOCAL player is the CEventNetworkEntityDamage victim. No payload —
       the server resolves the reporting client's own live coordinates
       itself, this file never sends a coordinate.
    3. 'john-k9:server:relayWeaponFire' () [server/tracking.lua]
       Fired by THIS FILE on a debounced false->true transition of
       IsPedShooting(PlayerPedId()). No payload, same reasoning as above.
    4. 'john-k9:server:reportTrackSourceArrival' () [server/tracking.lua]
       PHASE 4 ADDITION (Config.Features.XPProgression,
       Config.XP.awards.trackSourceResolved). Fired by THIS FILE's render
       thread below the FIRST tick it observes its own live distance to the
       resolved source coordinate drop to/below Config.XP.trackArrivalRadius
       — gated by a per-session `trackingState.arrivalReported` flag so it
       fires exactly once per resolved source, never once per tick (the
       server's own TrackArrivalReportCooldown is defense-in-depth against a
       modified client, not something this file relies on to paper over a
       spam-every-frame implementation here). No payload — this is a
       TRIGGER only, never a claimed distance/arrival boolean/coordinate;
       the server re-measures the caller's own live position against its
       own server-held resolved coordinate before awarding anything (see
       server/tracking.lua's own doc comment on this handler).

    No other client events (server->client) for this file at all — §11.4
    item 7 is explicit that tracking-result delivery is request/response
    shaped (the callback above), not a fire-and-forget event pair, matching
    the already-shipped 'john-k9:server:hasK9Access' pattern.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes five resource-global (no `local`) functions.
      STALE AS OF THE 2026-08-26 MERGE (see StartTrack()'s own doc comment
      below): client/radial.lua's three former "Track Scent" / "Track
      Blood" / "Track Gunpowder" items are GONE — collapsed into the one
      certification-driven radial item that calls StartCertifiedTrack()/
      StopTracking() (client/tracking.lua's own StartTrack(nil) path), so
      radial.lua no longer calls StartScentTrack()/StartBloodTrack()/
      StartGunpowderTrack() at all. Those three per-type globals are still
      reachable, but only via client/tablet.lua's FEATURE_TRIGGERS table
      (ScentTracking/BloodTracking/GunpowderSniffing entries), which uses
      the same GetActiveTrackType()/StopTracking() toggle-off-vs-reject
      pattern described below before calling the matching Start*Track():
        StartScentTrack()
        StartBloodTrack()
        StartGunpowderTrack()
        StopTracking()   -- not named by DEVELOPER_REFERENCE.md §11 itself; fills the
            open gap DEVELOPER_REFERENCE.md#tracking §2.1/§5 item 2
            flags (no self-service "stop" affordance is specified anywhere
            in §11's acceptance criteria) — a manual-cancel item, mirroring
            Attach/Detach Leash's single context-sensitive radial item.
        IsTracking() -> boolean
        GetActiveTrackType() -> 'scent'|'blood'|'gunpowder'|nil
    - THIS FILE calls client/main.lua's HasK9Access() at the top of every
      Start*Track() call — "don't trust the caller already checked," the
      same posture client/movement.lua's RequestLeashAttach() documents for
      itself. UPDATED (ANY-PED SWEEP FIX, this pass): this used to be
      CanShowK9UI(), which is strictly narrower than what
      server/tracking.lua's own findTrackableSource actually enforces
      (HasK9Access(source) alone, by that file's own explicit design —
      see StartTrack()'s own doc comment below for the full writeup).
    - THIS FILE reads Config.Tracking.Scent / .Blood / .Gunpowder and
      Config.WaterTrackingDecay (DEVELOPER_REFERENCE.md §11.2's config.lua additions,
      confirmed landed in config.lua as of this pass, including the
      relayCooldownMs amendments beyond §11.2's original text — those
      fields are server/tracking.lua's own concern, not read by this file).
    - PHASE 4 ADDITION: THIS FILE also reads Config.Features.XPProgression
      and Config.XP.trackArrivalRadius (config.lua is a shared_script, same
      access pattern as the Config.Tracking reads above) to decide WHEN to
      fire event 4 above — never to decide whether to award XP itself (that
      stays entirely server-side, server/tracking.lua's own concern).

    DEPENDENCY NOTE: this file has no compile-time dependency on
    client/search.lua (different trust model, different file) or
    client/vision.lua (unrelated feature). Load order relative to those two
    doesn't matter.

    ======================================================================
    LEGIBILITY FIX (this pass, coder-frontend) — every OTHER way a trail
    can stop already says so (water break: 'tracking.trail_lost_water';
    manual stop: silent BY DESIGN, per StopTracking()'s own doc comment,
    since the keypress itself is the feedback). The one remaining ending —
    the K9's own death mid-track, which already forced a StopTracking()
    call — said nothing at all: the markers this player was watching just
    stopped appearing, indistinguishable from the render thread having
    broken. Fixed at that one call site (see the OWN-DEATH EXIT PATH branch
    below) with a new notify, not inside StopTracking() itself, so the
    manual-stop path's own deliberate silence is untouched. New locale key,
    see this pass's report: tracking.trail_lost_death. Every other flow in
    this file (start refusals, the already-tracking/starting-in-progress
    guards, the trail render itself as the visible "still live" state, and
    arrival — which deliberately stays a client-side non-event per this
    file's own "never hand the player the answer" design, left to
    server/findalert.lua's existing bark-and-sit reaction on
    'john-k9:server:reportTrackSourceArrival', Config.FindAlerts.
    reactOnTrackArrival, default on) was reviewed and left unchanged this
    pass.
    ======================================================================
]]


-- SERVER-CALLBACK TIMEOUT (added 2026-08-31, from live testing).
-- Every lib.callback.await in this file previously passed `false` here.
-- Each call is wrapped in a pcall written on the stated assumption that
-- await "THROWS on a timeout" -- but `false` is the timeout argument, and
-- passing it is what disables the timeout. So nothing ever threw: a server
-- callback that does not answer left the caller waiting indefinitely rather
-- than failing cleanly. On the tablet that means a fetch promise that never
-- resolves, which is exactly the "I have to keep clicking Retry on almost
-- everything" the owner reported.
--
-- An explicit number is correct whichever way ox_lib treats `false` (I could
-- not reach its source from this environment to confirm): if false disabled
-- the timeout, this restores it; if false was already ignored, this only
-- makes the value explicit. Ten seconds is far longer than any call here
-- needs -- with Config.Database.enabled false everything is in-memory -- and
-- still bounded, so a wedged callback surfaces as a clear error instead of a
-- hang.
local K9_CALLBACK_TIMEOUT_MS = 10000
--- Local-only view of the CURRENT tracking session, if any. Set by a
--- successful Start*Track() call below, cleared by StopTracking() or by
--- the state/compute thread's own water-break/own-death bookkeeping below.
--- Not exposed directly — always go through IsTracking()/StopTracking().
--- `arrivalReported` (PHASE 4 addition): set true the first tick this
--- session's live distance to `coords` drops to/below
--- Config.XP.trackArrivalRadius, so 'john-k9:server:reportTrackSourceArrival'
--- fires exactly once per resolved source — see this file's header EVENT/
--- CALLBACK CONTRACT item 4 and the state/compute thread below.
--- @type { trackType: 'scent'|'blood'|'gunpowder', coords: vector3, breaksAtWater: boolean, brokenByWater: boolean, arrivalReported: boolean } | nil
local trackingState = nil

--- CORRECTNESS FIX (coder-frontend, this pass): cached snapshot of the
--- current tick's trail markers, `{ coords: vector3, underwater: boolean }[]`,
--- or nil when nothing should currently be rendered. Populated by the
--- state/compute thread below every TRACK_TICK_MS, then drawn EVERY FRAME by
--- a separate, lightweight render thread further below. This split exists
--- because DrawMarker (like every GTA "draw this frame" native) only stays
--- visible for the single frame it's called on — the previous single-thread
--- implementation called DrawMarker only once per TRACK_TICK_MS (250ms,
--- ~15 frames at 60fps), so the trail was actually only ever visible for 1
--- out of every ~15 rendered frames: a hard strobe/flicker, not a rendered
--- trail, despite the old code's own header comment already flagging that
--- "DrawMarker itself needs calling every frame it should be visible."
--- Cleared to nil (never left stale) by StopTracking() and by the
--- state/compute thread itself the moment there is nothing left to draw
--- (not tracking, water-broken, or already arrived at the source).
--- @type { coords: vector3, underwater: boolean }[] | nil
local currentTrailMarkers = nil

--- @return boolean
function IsTracking()
    return trackingState ~= nil
end

--- In-flight guard + staleness token for StartTrack()'s awaited server
--- callback (qa-tester finding, this pass): `lib.callback.await` yields for
--- the duration of a full server round-trip, during which `trackingState`
--- is still nil/unchanged, so neither `IsTracking()` nor
--- `trackingState.brokenByWater` can catch a second concurrent
--- Start*Track() call, or a StopTracking() call, that happens WHILE the
--- first call is still pending. `startInFlight` rejects a second concurrent
--- Start*Track() outright (cheap — never even issues a second server
--- callback). `trackRequestGeneration` additionally guards against the
--- narrower race `startInFlight` alone can't close: StopTracking() firing
--- while the ONE in-flight request is still pending, which must not let
--- that pending request "resurrect" a session the player already
--- explicitly stopped once it finally resolves.
local startInFlight = false
local trackRequestGeneration = 0

--- @return 'scent'|'blood'|'gunpowder'|nil
--- regression-tester finding: client/radial.lua's three Track items each
--- need to tell "currently tracking THIS type (real toggle-off)" apart from
--- "currently tracking a DIFFERENT type (should hit StartTrack()'s own
--- 'already tracking — stop first' rejection/notify, not silently cancel
--- the wrong trail)". IsTracking() alone can't make that distinction.
function GetActiveTrackType()
    return trackingState and trackingState.trackType or nil
end

--- Shared implementation behind StartScentTrack()/StartBloodTrack()/
--- StartGunpowderTrack() AND StartCertifiedTrack() below. DEVELOPER_REFERENCE.md §11.5's
--- three trail-type acceptance-criteria blocks are textually identical
--- (only the trackType string and its Config.Tracking.<Type> sub-table
--- differ), so this is one function instead of three near-duplicate copies
--- — mirrors e.g. client/vehicle.lua's ReleasePedFromVehicleState being
--- shared rather than duplicated.
---
--- EXTENDED this pass (coder-architect, owner-directed decluttering pass,
--- 2026-08-26 -- "merge all the scent tracking stuff into one thing") to
--- ALSO back the one new merged action: `trackType == nil` means "ask the
--- server to resolve whichever type(s) this K9 is entitled to and find the
--- nearest match across all of them" (calls the NEW
--- 'john-k9:server:findNearestTrackableSource' callback, which takes no
--- trackType argument at all — the server decides, never this file, per
--- this pass's explicit "the client must not decide this" requirement —
--- and echoes back WHICH type it matched in `result.trackType`, since this
--- file needs that to pick the right Config.Tracking.<Type> tuning for
--- rendering). A caller-supplied `trackType` string keeps calling the
--- OLDER, still-live, single-type 'john-k9:server:findTrackableSource'
--- callback exactly as before — StartScentTrack()/StartBloodTrack()/
--- StartGunpowderTrack() are UNCHANGED in behavior, kept as resource-globals
--- per this file's own header (other files/DEVELOPER_REFERENCE.md reference them by
--- name), even though nothing in this resource's own UI calls them anymore
--- (client/radial.lua's three Track items collapsed into StartCertifiedTrack()
--- below).
--- @param trackType ('scent'|'blood'|'gunpowder')? -- nil selects the merged, server-resolved action
local function StartTrack(trackType)
    -- ANY-PED SWEEP FIX (coder-frontend, this pass — coordinator finding:
    -- "StartTrack() gates on CanShowK9UI(), which is stricter than what the
    -- server itself checks (HasK9Access(source) alone in
    -- findTrackableSource) — a role-holder the server would allow can be
    -- refused by their own client"). CanShowK9UI() (client/main.lua) is
    -- `IsK9Role() and HasK9Access()` at the Config.K9Appearance.
    -- requireK9ModelForRole == false default (or `IsOwnModelK9() and
    -- HasK9Access()` otherwise) — either way it ANDs in an extra role/model
    -- check on top of HasK9Access(). server/tracking.lua's own
    -- findTrackableSource has NO such extra check: that file's header FILE-
    -- TO-FILE CONTRACT states outright "tracking access is gated purely on
    -- HasK9Access (job + certification), never on the caller's CURRENT ped
    -- model" and deliberately does not call IsConfiguredK9Model, flagging
    -- that a future edit must not "helpfully" add one. A K9-role holder
    -- whose access comes from server/certifications/'s HasK9Access()
    -- High Command/autoAccessGrade bypass — which IsK9Role() deliberately
    -- EXCLUDES per server/appearance.lua's own header — therefore failed
    -- BOTH halves of the old CanShowK9UI() gate on a non-K9 body
    -- (IsOwnModelK9() false, IsK9Role() false) even though the server would
    -- have answered `found = true` for the identical request: this client
    -- silently refused an action its own server-side authority would have
    -- granted, exactly the "checks whether a player is SHAPED like a dog
    -- where it should check whether they HOLD the role" pattern this sweep
    -- exists to close. Fixed by gating on HasK9Access() alone instead,
    -- matching the server's own real boundary exactly, and reusing this
    -- resource's own established precedent for a role-not-model gate:
    -- client/fetch.lua's RequestThrowFetchBall() and client/radial.lua's
    -- "Throw" item are both documented as deliberately "HasK9Access() alone,
    -- NOT CanShowK9UI()/IsOwnModelK9()" for the identical reason (a
    -- human-handler action must not depend on being modeled as a K9), and
    -- client/movement.lua's RecomputeK9MoveRate() was independently widened
    -- the same way in this same sweep. See
    -- tests/clienttracking_spec.lua for the regression pinning this: a
    -- HasK9Access()-true, IsK9Role()-false, non-K9-model caller must still
    -- reach the real findTrackableSource callback path, not a stubbed
    -- replacement of the function under test.
    if not HasK9Access() then
        -- Migrated to the shared client/main.lua helper (DEVELOPER_REFERENCE.md
        -- Part B item 1 -- formerly DEVELOPER_REFERENCE.md, merged 2026-08-25)
        -- — this was the last raw inline copy of the
        -- common.no_k9_access lib.notify() pattern; DenyK9UIAccess()'s own
        -- payload (title/description/type) is byte-identical to what this
        -- call site used to build directly.
        DenyK9UIAccess()
        return
    end

    -- OPEN QUESTION, not decided by DEVELOPER_REFERENCE.md §11 (DEVELOPER_REFERENCE.md#tracking
    -- §2.1/§5 item 2): should starting a NEW track type while already
    -- tracking something else silently replace the old session, or be
    -- rejected until StopTracking() is called first? This implementation
    -- rejects, matching IsLeashed()'s own "already leashed" rejection in
    -- client/movement.lua's RequestLeashAttach() — flagging the choice
    -- rather than silently picking the other way. A session already broken
    -- by water is NOT treated as "already tracking" for this check — §11.5
    -- requires "a fresh 'Track <Type>' command" to re-acquire after a water
    -- break to actually work, which would be permanently impossible if a
    -- broken session still counted as blocking a new one (with no
    -- self-service StopTracking() affordance wired into client/radial.lua
    -- yet to clear it manually).
    if IsTracking() and not trackingState.brokenByWater then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.already_tracking'), type = 'error' })
        return
    end

    -- In-flight guard (qa-tester finding, this pass) — reject a second
    -- concurrent Start*Track() outright rather than letting two overlapping
    -- lib.callback.await calls race each other; see this function's own
    -- startInFlight/trackRequestGeneration declaration comment above for
    -- the full race description.
    if startInFlight then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.starting_in_progress'), type = 'error' })
        return
    end

    startInFlight = true
    trackRequestGeneration = trackRequestGeneration + 1
    local myGeneration = trackRequestGeneration

    -- FAIL-CLOSED GUARD (dependency-verification finding, this pass):
    -- `lib.callback.await` throws rather than returning nil on a timeout
    -- or unregistered-callback rejection (see client/main.lua's
    -- HasK9Access() doc comment for the full ox_lib/FiveM source
    -- citation). Uncaught here, a throw would skip the `startInFlight =
    -- false` reset below entirely, permanently wedging `startInFlight`
    -- true and bricking every future Start*Track() call for the rest of
    -- this client's session (this function's own in-flight-guard comment
    -- above already flags why that flag must always get reset). pcall it;
    -- the `not result or not result.found` branch further below already
    -- treats a nil `result` the same as "nothing nearby."
    --
    -- CALLBACK SELECTION (this pass) — see this function's own doc comment
    -- above: `trackType == nil` calls the NEW merged, server-resolved
    -- callback (no trackType argument sent at all — the server decides);
    -- a caller-supplied trackType keeps calling the OLDER single-type
    -- callback exactly as every existing Start*Track() global already did.
    local ok, result
    if trackType then
        ok, result = pcall(lib.callback.await, 'john-k9:server:findTrackableSource', K9_CALLBACK_TIMEOUT_MS, trackType)
    else
        ok, result = pcall(lib.callback.await, 'john-k9:server:findNearestTrackableSource', K9_CALLBACK_TIMEOUT_MS)
    end
    if not ok then result = nil end

    startInFlight = false

    -- Staleness check — if StopTracking() (or, defensively, another
    -- Start*Track() call) ran WHILE the await above was pending, this
    -- result is stale and must not resurrect/stomp whatever the player's
    -- most recent action actually was.
    if myGeneration ~= trackRequestGeneration then
        return
    end

    -- NOTE: §11.4 item 1's response shape has no `reason` field (unlike
    -- searchTarget's, §11.4 item 2), so "nothing nearby" / "on cooldown" /
    -- "no access" all collapse to the same found = false here
    -- (DEVELOPER_REFERENCE.md#tracking §2.4) — ship one generic
    -- message, don't invent a distinction the server doesn't give data for.
    if not result or not result.found then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.nothing_to_track'), type = 'error' })
        return
    end

    -- RESOLVED TRACK TYPE (this pass) — a caller-supplied trackType is used
    -- as-is (findTrackableSource never echoes one back); the merged action
    -- reads it from the server's own response instead, since this file
    -- never told the server which type to look for. Defensively validated
    -- against the three real track-type strings (never trusted blindly,
    -- even though the server is authoritative here) so a malformed/future
    -- response can never wedge `trackingState` into a type this file's own
    -- TRACKING_STATE_CONFIG lookup (further below) doesn't recognize.
    local resolvedTrackType = trackType or result.trackType
    if resolvedTrackType ~= 'scent' and resolvedTrackType ~= 'blood' and resolvedTrackType ~= 'gunpowder' then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.nothing_to_track'), type = 'error' })
        return
    end

    -- Read breaksTrail from the LOCAL shared_script config directly rather
    -- than trusting result.breaksAtWater (documented informational-only,
    -- see this file's EVENT/CALLBACK CONTRACT above).
    trackingState = {
        trackType = resolvedTrackType,
        coords = result.coords,
        breaksAtWater = Config.WaterTrackingDecay.breaksTrail,
        brokenByWater = false,
        arrivalReported = false, -- PHASE 4 addition, see this file's header EVENT/CALLBACK CONTRACT item 4
    }
    -- Setting trackingState is sufficient to "wake" the render thread below
    -- — mirrors the exact comment already on client/movement.lua's
    -- leashAttached handler ("simply setting it here is sufficient... no
    -- separate thread-start call needed").
end

--- FORMERLY the radial-facing entry point for scent tracking. UPDATED this
--- pass (coder-architect, owner-directed decluttering, 2026-08-26): kept
--- as a resource-global by name (other files/DEVELOPER_REFERENCE.md may still
--- reference it), but client/radial.lua's three separate Track items
--- collapsed into ONE ("K9: Search" — see that file's own comment) calling
--- StartCertifiedTrack() below instead, so nothing in this resource's own
--- shipped UI calls this specific function anymore. Behavior is otherwise
--- completely unchanged — still calls the OLDER single-type
--- findTrackableSource callback for 'scent' specifically, still no
--- specialization scoping possible for a fixed-type request (that
--- callback's own server-side specialization gate — see server/tracking.lua
--- — would simply always allow 'scent' anyway, since it is never
--- specialization-gated).
function StartScentTrack()
    StartTrack('scent')
end

--- FORMERLY the radial-facing entry point for blood-trail tracking. See
--- StartScentTrack()'s own updated doc comment above — identical story.
function StartBloodTrack()
    StartTrack('blood')
end

--- FORMERLY the radial-facing entry point for gunpowder-residue tracking.
--- See StartScentTrack()'s own updated doc comment above — identical story.
function StartGunpowderTrack()
    StartTrack('gunpowder')
end

--- THE ONE MERGED ACTION (owner-directed decluttering pass, 2026-08-26 --
--- "merge all the scent tracking stuff into one thing so that way it[’s]
--- less clutter and when certed for extra stuff it just does it"). THE
--- single entry point client/radial.lua's one collapsed "K9: Search" item
--- and this file's own new 'k9track' chat command (registered below) both
--- call. Delegates to the shared StartTrack() above with `trackType = nil`,
--- which is what selects the NEW merged, server-resolved
--- 'john-k9:server:findNearestTrackableSource' callback instead of the
--- older single-type one — see that function's own doc comment for the
--- full "which callback, and why" writeup.
---
--- THE SERVER DECIDES, NEVER THIS FILE: this function does not read
--- Config.SpecializationTracking, does not call HasSpecialization, and does
--- not know or guess which track type(s) the local player's K9 is
--- currently entitled to — a client-side filter here would be exactly the
--- "a client-side filter is a client-side filter, and a modded client
--- would just turn it off" trap this pass's own design explicitly rules
--- out. Every bit of scoping happens server-side
--- (server/tracking.lua's ResolveEnabledTrackTypesForCitizenId), and this
--- function just asks "find whatever I'm certified for" and renders
--- whatever comes back.
function StartCertifiedTrack()
    StartTrack(nil)
end

--- Manual cancel — fills the open gap DEVELOPER_REFERENCE.md#tracking
--- §2.1/§5 item 2 flags (no self-service "stop" affordance is specified
--- anywhere in DEVELOPER_REFERENCE.md §11 itself, only a fresh Start*Track() call after a
--- water-break). No-op if not currently tracking. Silent, cosmetic,
--- low-stakes action (per §11.6's framing of tracking as "no real
--- capability granted") — no confirmation notification needed, matching
--- how DetachLeash() doesn't narrate every internal-state clear either.
function StopTracking()
    -- Bumps trackRequestGeneration so a StartTrack() call still awaiting
    -- its server callback at the moment this runs discards its eventual
    -- result as stale instead of resurrecting the session being stopped
    -- here — see StartTrack()'s own startInFlight/trackRequestGeneration
    -- declaration comment (qa-tester finding, this pass) for the full race.
    trackRequestGeneration = trackRequestGeneration + 1
    trackingState = nil
    -- Explicitly cleared here (not left for the state thread to notice on
    -- its own next tick) so the separate per-frame render thread stops
    -- drawing the instant this is called, rather than up to one
    -- TRACK_TICK_MS late — a stale trail rendering for up to 250ms after an
    -- explicit stop would be exactly the "half-started/leftover trail" this
    -- file is required to avoid.
    currentTrailMarkers = nil
    -- The state thread below naturally idles once IsTracking() is false,
    -- mirroring how client/movement.lua's DetachLeash() comment describes
    -- its own elastic thread "naturally stopping" once IsLeashed() is
    -- false — no separate thread-teardown call needed.
end

-- ======================================================================
-- 'k9track' CHAT COMMAND (owner-directed decluttering pass, 2026-08-26 --
-- "when certed for extra stuff it just does it so if i am certed in
-- drugs and i have the command or third eye it will only search for
-- drugs"). The COMMAND half of the ONE merged action — client/radial.lua's
-- collapsed single item is the THIRD-EYE half. Both call the exact same
-- StartCertifiedTrack() above; this command adds no logic of its own.
--
-- Registered UNCONDITIONALLY, mirroring client/keybinds.lua's own 'k9sit'
-- precedent ("no dedicated Config.Features flag of its own... the real
-- function already performs the real gate internally on every call") —
-- StartCertifiedTrack()/StartTrack() above already re-check HasK9Access()
-- client-side and the server independently re-validates
-- Config.Features.<Type> per candidate type regardless of client UI state,
-- so a second, redundant Config.Features gate here would only make this
-- command's availability diverge from the radial item's own (which is
-- gated on "is at least one of the three types even switched on at all",
-- a coarser, display-only check — see client/radial.lua's own comment on
-- that item).
-- ======================================================================
--
-- ONE KEY STARTS AND STOPS (the owner's rework pass). The radial item and
-- the tablet trigger both already stop a running track; this command used
-- to answer "already tracking" instead, so the same action behaved
-- differently depending on where you pressed it. Stopping is checked first
-- and is never gated -- "gate the start, never the stop".
RegisterCommand('k9track', function()
    if IsTracking() then
        StopTracking()
        return
    end
    StartCertifiedTrack()
end, false)

-- State/compute thread. Reuses the exact idle/active tick-rate-switch
-- pattern client/movement.lua's leash pull-back thread already establishes
-- (its LEASH_TICK_MS / LEASH_IDLE_TICK_MS constants) — sleeps long while
-- IsTracking() is false, switches to a short tick only while a session is
-- active. CORRECTNESS FIX (coder-frontend, this pass): this thread now only
-- RECOMPUTES the trail (distance, water-crossing sampling, arrival check)
-- at this cadence and writes the result into `currentTrailMarkers` above —
-- it no longer calls DrawMarker directly. The old single-thread version
-- called DrawMarker only once per TRACK_TICK_MS (250ms, ~15 frames at
-- 60fps), which — despite this exact comment already flagging that
-- "DrawMarker itself needs calling every frame it should be visible" —
-- meant the trail was only ever actually visible for 1 out of every ~15
-- rendered frames: a hard strobe, not a rendered trail. The dedicated
-- per-frame render thread further below now owns calling DrawMarker every
-- frame from the cached snapshot this thread produces, so the recompute
-- cost stays at this cheap interval while the visual is actually
-- continuous.
local TRACK_TICK_MS = 250
local TRACK_IDLE_TICK_MS = 1000

-- trackType -> the Config.Tracking sub-table holding its tuning values.
-- Built once at file load rather than re-derived per tick via a
-- ternary/if-else chain (refactor-strategist finding, cosmetic-only, zero
-- behavior change) -- mirrors server/tracking.lua's own TRACK_TYPE_CONFIG
-- lookup table for the identical trackType-to-config mapping.
local TRACKING_STATE_CONFIG = {
    scent = Config.Tracking.Scent,
    blood = Config.Tracking.Blood,
    gunpowder = Config.Tracking.Gunpowder,
}

-- DrawMarker type 1 = a flat cylinder/checkpoint ring — a reasonable,
-- unremarkable choice for a ground breadcrumb (matches the "checkpoint"
-- framing DEVELOPER_REFERENCE.md#tracking §3 item 4 uses).
local TRAIL_MARKER_TYPE = 1
local TRAIL_MARKER_SCALE = 0.5
local TRAIL_MARKER_COLOR = { r = 255, g = 220, b = 90, a = 180 }
local TRAIL_MARKER_COLOR_UNDERWATER_ALPHA = 60 -- reduced-opacity rendering for breaksTrail == false, per §11.5

--- Draws one breadcrumb marker at `coords`, at reduced alpha if `underwater`.
--- Not independently native-verified this pass (DrawMarker is a
--- long-standing, extremely well-established FiveM/GTA native per
--- DEVELOPER_REFERENCE.md#tracking §4 — not re-verified against
--- current docs this session, same "high confidence, not re-confirmed"
--- caveat that note already flags).
--- @param coords vector3
--- @param underwater boolean
local function DrawTrailMarker(coords, underwater)
    local alpha = underwater and TRAIL_MARKER_COLOR_UNDERWATER_ALPHA or TRAIL_MARKER_COLOR.a
    DrawMarker(
        TRAIL_MARKER_TYPE,
        coords.x, coords.y, coords.z - 0.9,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE,
        TRAIL_MARKER_COLOR.r, TRAIL_MARKER_COLOR.g, TRAIL_MARKER_COLOR.b, alpha,
        false, false, 2, false, '', '', false
    )
end

--- Samples the live line from `startCoords` to `endCoords` for a water
--- crossing, per Config.WaterTrackingDecay.sampleIntervalMeters. Returns
--- the distance along the line to the first water hit, or nil if none
--- found before reaching endCoords.
--- Uses GetWaterHeightNoWaves — NOT plain GetWaterHeight, per
--- DEVELOPER_REFERENCE.md#tracking §1's explicit recommendation
--- (frame-stable, appropriate for a fixed-step poll like this; plain
--- GetWaterHeight is wave-jittered and can disagree between adjacent
--- samples on a calm shoreline). CORRECTION (final native-correctness
--- sweep, this session): the native's `float* height` out-param becomes an
--- extra Lua RETURN value, not an input argument — called here as
--- `GetWaterHeightNoWaves(x, y, z)` returning `(found, height)`, matching
--- the real, community-confirmed convention (e.g. the sibling
--- GetWaterHeight's own documented usage
--- `local retval, waterHeight = GetWaterHeight(x, y, z)`). The previous
--- trailing `0.0` argument was inert (Lua silently discards an extra
--- argument the function doesn't consume) — this was never a behavior
--- bug, only an inaccurate comment/call-shape cleanup. The height value
--- itself is still unused here, only the boolean matters.
-- Warned ONCE for the resource-session lifetime of this client, not once
-- per FindWaterCrossingDistance call -- this function runs from inside a
-- `while true` tracking-render loop below, so a per-call print would spam
-- the console every tick for as long as tracking stays active.
local warnedInvalidWaterTrackingSampleInterval = false

--- @param startCoords vector3
--- @param endCoords vector3
--- @return number? distanceToWater
local function FindWaterCrossingDistance(startCoords, endCoords)
    local total = #(endCoords - startCoords)
    if total <= 0.0 then return nil end

    local dir = (endCoords - startCoords) / total
    -- Clamped defensively, mirroring client/movement.lua's leash thread
    -- precedent (math.max(_, 0.1), line ~751): a misconfigured
    -- Config.WaterTrackingDecay.sampleIntervalMeters of 0 (or negative)
    -- would otherwise spin this while loop forever with no Wait() inside
    -- it, freezing this thread until FiveM's watchdog intervenes.
    --
    -- TYPE-CHECKED BEFORE math.max, not just range-clamped -- this used to
    -- be a bare `math.max(Config.WaterTrackingDecay.sampleIntervalMeters,
    -- 0.1)`, which guards against 0 and negative numbers but NOT against a
    -- non-number (a quoted "2" from a hand-edited config, nil, a boolean, a
    -- stray table): math.max errors on a non-number argument, and this
    -- function runs from inside a `while true` client thread with no pcall
    -- around it, so that error would silently and permanently kill this
    -- client's ENTIRE water-crossing/trail-decay thread for the rest of
    -- this resource session, not merely this one call. CLAMP AND WARN
    -- instead, mirroring client/proximityaudio.lua's own
    -- triggerDistance guard (same file-load-time-vs-per-call distinction:
    -- that one runs once at file scope, this one runs from a live loop, but
    -- the "a non-number reaches a math.* call and throws" failure mode is
    -- identical) -- warned ONCE (see warnedInvalidWaterTrackingSampleInterval
    -- above), never per call.
    local configuredSampleInterval = Config.WaterTrackingDecay.sampleIntervalMeters
    if type(configuredSampleInterval) ~= 'number' then
        if not warnedInvalidWaterTrackingSampleInterval then
            warnedInvalidWaterTrackingSampleInterval = true
            print(
                ('[John-K9] WARNING: Config.WaterTrackingDecay.sampleIntervalMeters must be a number (found: ' ..
                 '%s) -- math.max would otherwise throw and permanently kill this water-crossing detection ' ..
                 "thread for the rest of this client's session. Using the built-in fallback of 2.0m instead. " ..
                 'Fix Config.WaterTrackingDecay.sampleIntervalMeters in config.lua to silence this warning.'
                ):format(tostring(configuredSampleInterval))
            )
        end
        configuredSampleInterval = 2.0
    end
    local step = math.max(configuredSampleInterval, 0.1)
    local traveled = 0.0

    while traveled < total do
        local sample = startCoords + dir * traveled
        local found = GetWaterHeightNoWaves(sample.x, sample.y, sample.z)
        if found then
            return traveled
        end
        traveled = traveled + step
    end

    return nil
end

CreateThread(function()
    while true do
        local sleepMs = TRACK_IDLE_TICK_MS

        if IsTracking() and not trackingState.brokenByWater then
            local myPed = PlayerPedId()

            -- OWN-DEATH EXIT PATH (coder-frontend correctness pass, this
            -- session — not previously handled): mirrors this codebase's own
            -- established "own ped death forces an active perception/render
            -- feature to end" precedent (client/vision.lua's maintenance
            -- thread, client/propattachment.lua's "OWN-DEATH AUTO-DETACH").
            -- Continuing to recompute/render a scent/blood/gunpowder trail
            -- from a dead ped's position is narratively nonsensical and, on
            -- respawn, would silently resume rendering a "trail" from
            -- whatever coordinate the player respawns at — unrelated to the
            -- K9's actual path to the resolved source. StopTracking() clears
            -- trackingState AND currentTrailMarkers together and bumps
            -- trackRequestGeneration defensively, same as an explicit manual
            -- stop — a fresh "Track <Type>" is required after respawning,
            -- matching this file's existing "no self-service silent resume"
            -- precedent already established for the water-break case below.
            if IsEntityDead(myPed) then
                -- LEGIBILITY FIX (this pass) — StopTracking() itself stays
                -- silent by design for a MANUAL stop (see its own doc
                -- comment: "no confirmation notification needed"), but an
                -- own-death auto-stop is a genuinely different case: the
                -- trail markers this player was watching simply stop
                -- appearing, on this same tick, with nothing said about why
                -- — indistinguishable from the render thread having broken.
                -- Notified HERE, at this specific call site, not inside
                -- StopTracking() itself, so a manual stop (and the
                -- water-break/generation-staleness paths, which already
                -- have their own explicit notify or are deliberately silent
                -- per this file's own documented reasoning) are entirely
                -- unaffected. New locale key, see this pass's report:
                -- tracking.trail_lost_death.
                StopTracking()
                lib.notify({ title = locale('common.notify_title'), description = locale('tracking.trail_lost_death'), type = 'error' })
            else
                sleepMs = TRACK_TICK_MS

                local myCoords = GetEntityCoords(myPed)
                local sourceCoords = trackingState.coords

                -- Recomputed fresh every tick from the K9's LIVE position
                -- toward the fixed resolved source coordinate — NOT a
                -- one-time snapshot (DEVELOPER_REFERENCE.md#tracking
                -- §1.2: the K9's position moves every tick, the resolved
                -- source coordinate does not, for the lifetime of one
                -- Start*Track() call).
                local totalDist = #(sourceCoords - myCoords)

                -- PHASE 4 ADDITION (Config.Features.XPProgression,
                -- Config.XP.awards.trackSourceResolved) — see this file's
                -- header EVENT/CALLBACK CONTRACT item 4. Fired the FIRST
                -- tick our own live distance to the resolved source drops
                -- to/below Config.XP.trackArrivalRadius, gated by
                -- `arrivalReported` so a sustained standstill at the source
                -- doesn't retrigger this every tick — this is a TRIGGER
                -- only, the server re-measures its OWN live distance against
                -- its OWN stored coordinate before awarding anything
                -- (server/tracking.lua's reportTrackSourceArrival handler
                -- never trusts this call as a claim of arrival). Checked
                -- unconditionally (not nested inside the `totalDist > 0.1`
                -- marker-collection branch below) so arriving close enough
                -- that totalDist itself falls under 0.1 still reports — that
                -- branch only guards collecting markers along a remaining
                -- line, not this check.
                -- DELIBERATELY NOT gated on Config.Features.XPProgression.
                -- It used to be, because this event started life as this
                -- file's own XP trigger. It has a second, independent
                -- consumer now -- server/findalert.lua's trail-arrival
                -- bark-and-sit reaction -- and gating the SEND on an
                -- unrelated flag made that reaction silently dead whenever
                -- XPProgression was off, while FindAlerts' other reaction
                -- (search completion) kept working. That presents to an
                -- operator as "find alerts work for searches but not for
                -- tracking", with no reason to suspect an XP flag.
                -- Sending unconditionally is safe: server/tracking.lua's own
                -- handler returns early on Config.Features.XPProgression at
                -- its top, so no XP is minted when the flag is off. The
                -- server never trusts this as a claim of arrival either --
                -- it re-derives the distance itself.
                if not trackingState.arrivalReported
                    and totalDist <= Config.XP.trackArrivalRadius then
                    trackingState.arrivalReported = true
                    TriggerServerEvent('john-k9:server:reportTrackSourceArrival')
                end

                if totalDist > 0.1 then
                    local trackingConfig = TRACKING_STATE_CONFIG[trackingState.trackType]
                    local dir = (sourceCoords - myCoords) / totalDist

                    -- OPEN QUESTION, not resolved by DEVELOPER_REFERENCE.md §11 either way
                    -- (DEVELOPER_REFERENCE.md#tracking §2.3, §5 item 1):
                    -- reveal the WHOLE remaining line at once, or only a
                    -- capped preview window near the player? This
                    -- implementation reveals the whole remaining line —
                    -- simpler, and matches "a trail of markers toward the
                    -- nearest source" read literally — flagged per that
                    -- note's own recommendation to confirm with
                    -- product-manager/feature-ideation before this is
                    -- treated as final, not silently asserted as the only
                    -- right answer.
                    local waterCrossingDist = nil
                    -- PER-PERSON BLOCK (client/featureblocks.lua hand-off
                    -- item 1 -- see that file's own header for the full
                    -- contract this follows). This is the EASY hand-off
                    -- case that file's own header describes: this whole
                    -- branch already runs once per tick, unconditionally,
                    -- inside the compute thread above (TRACK_TICK_MS while
                    -- IsTracking() and not brokenByWater), so folding the
                    -- block check into this SAME existing condition is
                    -- enough, by itself, to make a block applied mid-trail
                    -- stop breaking trails at water within one tick, and a
                    -- block cleared mid-trail resume doing so within one
                    -- tick -- no new thread, no new poll, no new cost of any
                    -- kind. `type(...) == 'function'` guarded per this
                    -- resource's soft-dependency convention (see
                    -- client/featureblocks.lua's own header) -- if that file
                    -- is not loaded, this reads exactly as it did before
                    -- this pass (fails OPEN: water crossings still decay the
                    -- trail normally, never silently "always blocked").
                    if Config.Features.WaterTrackingDecay
                        and not (type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('WaterTrackingDecay')) then
                        waterCrossingDist = FindWaterCrossingDistance(myCoords, sourceCoords)

                        if waterCrossingDist and trackingState.breaksAtWater then
                            -- Hard break: stop rendering markers past the
                            -- crossing point, mark broken, notify, and do NOT
                            -- auto-resume — per §11.5's explicit "does not
                            -- silently resume" bullet, a fresh Start*Track()
                            -- call (subject to that type's own
                            -- searchCooldownMs) is required to re-acquire.
                            trackingState.brokenByWater = true
                            lib.notify({
                                title = locale('common.notify_title'),
                                description = locale('tracking.trail_lost_water'),
                                type = 'error',
                            })
                        end
                    end

                    -- Deliberately NOT gated on `not trackingState.
                    -- brokenByWater` here — the outer `IsTracking() and not
                    -- trackingState.brokenByWater` check (top of this tick's
                    -- block) already stops FUTURE ticks once broken, and the
                    -- break condition two lines above already cuts the line
                    -- off exactly at waterCrossingDist. Gating this loop on
                    -- brokenByWater too was a real bug: brokenByWater gets
                    -- set to true a few lines above in THIS SAME tick the
                    -- instant water is first detected anywhere on the
                    -- remaining path, so the old code skipped collecting
                    -- anything at all that tick — the whole trail (including
                    -- the already-walked near-bank portion) vanished
                    -- instantly instead of rendering up to the water's edge
                    -- as §11.5 requires. Running this loop unconditionally
                    -- lets the current tick still render the partial line
                    -- before the broken state takes effect next tick
                    -- (qa-tester/correctness-overseer finding).
                    -- Clamped defensively, same rationale/precedent as
                    -- FindWaterCrossingDistance's own `step` clamp above: a
                    -- misconfigured Config.Tracking.<Type>.markerSpacing of 0
                    -- (or negative) would otherwise spin this while loop
                    -- forever with no Wait() inside it (qa-tester finding).
                    local markerStep = math.max(trackingConfig.markerSpacing, 0.1)
                    local traveled = 0.0
                    local markers = {}
                    while traveled < totalDist do
                        -- If breaksTrail, stop rendering past the crossing
                        -- point entirely. If not breaksTrail (soft fade),
                        -- keep rendering past it at reduced alpha — the
                        -- sampling logic runs identically either way, only
                        -- the marker-drawing parameter changes (§11.5).
                        if waterCrossingDist and trackingState.breaksAtWater and traveled >= waterCrossingDist then
                            break
                        end

                        local markerCoords = myCoords + dir * traveled
                        local underwater = waterCrossingDist ~= nil and traveled >= waterCrossingDist
                        markers[#markers + 1] = { coords = markerCoords, underwater = underwater }

                        traveled = traveled + markerStep
                    end

                    -- Handed off to the dedicated per-frame render thread
                    -- below — see currentTrailMarkers' own declaration
                    -- comment for why DrawMarker itself must not be called
                    -- from this (only-every-TRACK_TICK_MS) thread directly.
                    currentTrailMarkers = markers
                else
                    -- Already at (or within 0.1m of) the resolved source —
                    -- nothing left to render.
                    currentTrailMarkers = nil
                end
            end
        else
            -- Not tracking, or the trail just broke at water (that break's
            -- own final partial-line snapshot was already produced by the
            -- branch above on the exact tick the break was first detected —
            -- see the comment on that branch). Cleared explicitly here on
            -- every subsequent idle tick, rather than left for the render
            -- thread to infer on its own, so a stopped/broken trail's last
            -- rendered frame does not keep rendering forever — exactly the
            -- kind of indefinite, self-inflicted "stuck visual" this file is
            -- required to avoid.
            currentTrailMarkers = nil
        end

        Wait(sleepMs)
    end
end)

-- Per-frame render thread (CORRECTNESS FIX, coder-frontend, this pass) —
-- see currentTrailMarkers' own declaration comment above for the full
-- writeup of the bug this closes (DrawMarker previously only being invoked
-- once per TRACK_TICK_MS, causing a visible strobe instead of a rendered
-- trail). Runs at Wait(0) ONLY while there is something to draw; idles at
-- TRACK_RENDER_IDLE_TICK_MS the rest of the time (the overwhelming majority
-- of a normal session, since tracking is opt-in and short-lived) — mirrors
-- this file's own idle/active tick-rate-switch convention
-- (TRACK_TICK_MS/TRACK_IDLE_TICK_MS above), applied to the render half
-- specifically because that half — unlike the state/compute half above —
-- genuinely does need per-frame execution to actually be visible.
local TRACK_RENDER_IDLE_TICK_MS = 250

-- FORWARD DECLARATION (ScentVision hand-off, this pass): the real
-- implementation lives further below in this file's own SCENT VISION
-- section, alongside the state (`scentVisionSnapshot`) it reads and the
-- config it validates — kept together there rather than splitting that
-- feature's logic across two widely separated parts of this file. Declared
-- `local` here, ASSIGNED (not `local function`-redeclared) later, so this
-- existing thread — which loads first, textually — captures it as a real
-- upvalue and always sees whatever the later assignment set by the time
-- this loop actually runs (file loading completes, in full, before any
-- CreateThread body's first resume). Folding ScentVision's own dots into
-- THIS SAME per-frame thread (rather than a second Wait(0) loop) is a
-- deliberate perf choice — see this resource's own "no thread left
-- spinning at full frequency while its feature is inactive" standard;
-- two independent Wait(0) render loops would double the per-frame
-- call overhead for as long as EITHER feature is active, for no benefit.
-- @type fun(): boolean drewAnything
local DrawScentVisionPoints

CreateThread(function()
    while true do
        -- CORRECTNESS FIX (coder-frontend, this pass): must check for a
        -- non-EMPTY table, not merely a non-nil one. The state/compute
        -- thread above can hand off `markers = {}` (present but empty) on
        -- the exact tick a hard water-break is detected at traveled == 0
        -- (the K9 is already standing in/at the water's edge the instant
        -- Start*Track() resolves) — the break-condition guard there stops
        -- the loop before it ever appends a marker, but still assigns the
        -- (empty) table rather than nil. The old `if currentTrailMarkers
        -- then` check treated that empty table as truthy, so this thread
        -- spun at Wait(0) — a real per-frame cost — despite the for loop
        -- below it having nothing to iterate and drawing nothing at all.
        -- Bounded to at most one TRACK_TICK_MS (the compute thread clears
        -- it to nil on its very next tick once brokenByWater is set), but
        -- still a genuine "idle path doesn't actually idle" instance, not
        -- just a cosmetic no-op.
        local drewTrailMarkers = false
        if currentTrailMarkers and #currentTrailMarkers > 0 then
            for i = 1, #currentTrailMarkers do
                local marker = currentTrailMarkers[i]
                DrawTrailMarker(marker.coords, marker.underwater)
            end
            drewTrailMarkers = true
        end

        -- ScentVision (this pass) — a SEPARATE feature/state from the
        -- Track <Type> trail above (see this file's own SCENT VISION
        -- section header for the full "why separate" writeup); folded into
        -- this SAME frame/Wait decision purely for perf, not because the
        -- two features are otherwise related. `DrawScentVisionPoints` is
        -- nil until the section below runs at file-load time (which always
        -- happens before this thread's first resume) — guarded anyway,
        -- defensively, in case this file is ever loaded partially by a
        -- future test harness.
        local drewScentVisionPoints = false
        if type(DrawScentVisionPoints) == 'function' then
            drewScentVisionPoints = DrawScentVisionPoints()
        end

        if drewTrailMarkers or drewScentVisionPoints then
            Wait(0)
        else
            Wait(TRACK_RENDER_IDLE_TICK_MS)
        end
    end
end)

-- Blood-trail capture (Config.Features.BloodTracking): relays a
-- payload-less event to the server on CEventNetworkEntityDamage where the
-- LOCAL player is the victim. Real, documented FiveM game event per
-- DEVELOPER_REFERENCE.md §11.6 and independently confirmed against citizenfx/fivem source
-- in DEVELOPER_REFERENCE.md#tracking §0 — victim identity is data[1],
-- confirmed reliable across multiple independent sources; do NOT depend on
-- any other args[] index (weapon hash, etc.) without a fresh confirmation
-- pass, per that note's own explicit caveat (args[3], [5], [6] are NOT
-- independently confirmed).
AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    -- Gate read at the point of firing (DEVELOPER_REFERENCE.md §3's hard requirement — a
    -- disabled feature must be a real no-op, not just hidden UI).
    if not Config.Features.BloodTracking then return end

    local victim = tonumber(data[1])
    if victim ~= PlayerPedId() then return end -- only relay when WE are the victim, per §11.4 item 3's exact filter

    -- No payload — the server resolves OUR live coordinates itself
    -- (GetEntityCoords(GetPlayerPed(source))), never a value sent from here.
    TriggerServerEvent('john-k9:server:relayDamageEvent')
end)

-- Gunpowder capture thread (Config.Features.GunpowderSniffing), DEVELOPER_REFERENCE.md
-- §11.4 item 4/§11.6. Debounced local poll of IsPedShooting(PlayerPedId())
-- watching for a false->true transition — NOT a nearby-ped scan (an
-- earlier, discarded hypothesis; see DEVELOPER_REFERENCE.md#tracking
-- §0.1 item 2 for why "search a suspect for residue" isn't this feature's
-- actual shape). Each client only ever checks its OWN single ped handle, so
-- this is cheap regardless of how many other players are nearby
-- (DEVELOPER_REFERENCE.md#tracking §2's own note on why this
-- sidesteps the generic "scan nearby peds" perf concern it otherwise flags
-- for a naive implementation). Gated on Config.Features.GunpowderSniffing —
-- idles at a cheap 1000ms poll while the flag is false, mirroring
-- client/movement.lua's AgilityBasicJump thread's "if not
-- Config.Features.X then ... else idle" shape, so this file's thread always
-- exists (simpler than conditionally creating it) but does real work only
-- when the feature is enabled.
local GUNPOWDER_POLL_MS = 200 -- debounce poll interval, per
    -- DEVELOPER_REFERENCE.md#tracking §2's perf note on the
    -- (rejected) nearby-ped-scan variant, applied here to the single-ped
    -- case too as a reasonable default (100-250ms range).
local GUNPOWDER_IDLE_POLL_MS = 1000

-- PERF-AUDIT FINDING, THIS PASS (coder-frontend) — a role/model/access gate
-- was CONSIDERED and REJECTED here, not overlooked. A performance audit
-- flagged this thread as polling IsPedShooting() on every connected client
-- forever "for a mechanic only on-duty K9 handlers can ever act on," and
-- suggested gating the active branch below behind CanShowK9UI() or
-- IsOwnModelK9() so only K9 handlers pay the 200ms tick (mirroring
-- client/hud.lua's CanShowK9UI()-gated poll).
--
-- That premise does not hold for THIS specific thread. Confirmed by
-- reading server/tracking.lua directly rather than inheriting the audit's
-- framing (per this pass's own instruction to verify, not assume):
--   1. relayWeaponFire's own handler (server/tracking.lua) has NO
--      HasK9Access(source) check on the SENDER — only
--      Config.Features.GunpowderSniffing and its relayCooldownMs. The
--      sibling relayDamageEvent (blood) is identically ungated on the
--      sender. Neither trail type's CAPTURE path checks the reporting
--      player's K9 status — only the SEARCH path does.
--   2. server/tracking.lua's own header "FORGED TRAIL DECISION" names the
--      threat model for this exact event as "a griefer" who can "plant a
--      decoy at their own current position" — i.e. the file's own author
--      builds it assuming ANY connected player, not a K9 handler, is a
--      legitimate (if occasionally adversarial) caller of this relay.
--   3. findTrackableSource — the SEARCH side, what "Track Gunpowder"
--      actually invokes (gated by StartTrack()'s HasK9Access() call above
--      in this file — UPDATED, ANY-PED SWEEP FIX, this pass, was
--      CanShowK9UI(); see StartTrack()'s own doc comment — and by
--      HasK9Access(source) server-side, the same real check on both ends
--      now) — is the ONLY point in this mechanic where K9-handler status is
--      meant to matter. Capture (this thread, blood's relayDamageEvent, and
--      scent's ox_inventory swapItems hook) is deliberately population-
--      wide: any player's fired shot / taken damage / dropped item
--      becomes a source a K9 handler can LATER search for. That is the
--      entire point of the mechanic — tracking a suspect who is, by
--      construction, essentially never the K9 handler doing the tracking.
--
-- Gating this thread's poll behind CanShowK9UI()/IsOwnModelK9() would
-- therefore not be a perf fix — it would silently stop logging shots
-- fired by every non-handler player (the actual suspects this mechanic
-- exists to make trackable) while leaving K9 handlers, who rarely need to
-- track each other, as the only population still generating entries. That
-- gates the wrong side of the feature. Config.Features.GunpowderSniffing
-- (checked below, unchanged) remains the ONLY correct gate for this
-- thread: when it is on, every connected client legitimately needs to be
-- able to report its own shot. If a future pass revisits this, re-read
-- server/tracking.lua's relayWeaponFire/relayDamageEvent/
-- findTrackableSource before "fixing" it again — see
-- tests/clienttracking_spec.lua's own regression test asserting a
-- CanShowK9UI() == false caller still relays.
CreateThread(function()
    local wasShooting = false

    while true do
        if Config.Features.GunpowderSniffing then
            local isShooting = IsPedShooting(PlayerPedId())

            -- NOTE (DEVELOPER_REFERENCE.md#tracking §0.2/§2.3,
            -- still unconfirmed this session): IsPedShooting's exact
            -- per-shot vs. per-burst semantics across a sustained
            -- automatic-weapon fire are NOT independently verified — the
            -- real flood protection is server/tracking.lua's own dedicated
            -- rate limit on relayWeaponFire (§11.4 item 4, explicitly
            -- required to be separate from
            -- Config.Tracking.Gunpowder.searchCooldownMs) — this
            -- client-side debounce is a courtesy reduction, not the safety
            -- net itself.
            if isShooting and not wasShooting then
                -- No payload, same "server resolves our own live position"
                -- rule as the damage-event relay above.
                TriggerServerEvent('john-k9:server:relayWeaponFire')
            end

            wasShooting = isShooting
            Wait(GUNPOWDER_POLL_MS)
        else
            wasShooting = false
            Wait(GUNPOWDER_IDLE_POLL_MS)
        end
    end
end)

--[[
    ======================================================================
    SCENT VISION (Config.Features.ScentVision) — owner-directed pass: "make
    scent tracking... a keybind that makes a colour dot appear where players'
    blood etc have walked and have a delay before the scent markers go
    away... if multiple people, multiple different colours... to
    differentiate smells." Coordinator follow-ups folded in as the design
    evolved: "person" (colour per PERSON, never per permission); "handful
    near the dog" / "they go away after 45 seconds" (server scopes colours
    and reveal to a small proximity-ranked set, 45s default lifetime);
    "diffrent dots will be all seprate timers... slowly go away" (EACH DOT
    expires on its OWN individual timer from its OWN capture time).

    A SEPARATE feature/state from this file's Track Scent/Blood/Gunpowder
    trio above (`trackingState`/`currentTrailMarkers`) — that trio resolves
    and walks toward exactly ONE nearest logged event; this instead shows
    several OTHER people's own recent walked paths at once, colour-coded so
    more than one trail can be told apart. The two can run concurrently
    (there is no reason to force mutual exclusion — one is "walk to this one
    thing", the other is "look around"); only the per-frame RENDER decision
    is shared (see the forward-declared `DrawScentVisionPoints` hook near
    this file's own TRACK_RENDER_IDLE_TICK_MS declaration above), purely for
    the perf reason documented at that call site.

    SERVER IS AUTHORITATIVE THROUGHOUT — this file never decides who may use
    this, never decides what is "nearby", and never learns anyone's raw
    identity. Every point this file ever draws is exactly what
    server/tracking.lua's getScentVisionPoints callback chose to send —
    already position-checked, already range-checked, already capped to a
    "handful" of trails, already coloured. See that callback's own header
    for the full trust-boundary and scale writeup (population-wide capture
    cost, storage ceiling, per-query cost bound, and why colours can never
    collide within one visible set).

    PER-DOT EXPIRY, EVALUATED AGAINST A TIMESTAMP, NEVER A COUNTDOWN (owner's
    own explicit requirement): the server sends each point's own age AT THE
    MOMENT OF THE RESPONSE (`ageMs`, relative — never a raw server
    GetGameTimer() value, since server and client run independent
    GetGameTimer() counters and are not the same clock). This file anchors
    that relative age to ITS OWN GetGameTimer() the instant the response
    arrives (`receivedAtClientMs` below) and, every frame, recomputes each
    point's CURRENT effective age as `ageMs + (GetGameTimer() -
    receivedAtClientMs)` — never a value decremented once per frame. A
    stutter, an alt-tab, or a paused resource therefore cannot stretch a 45s
    dot into something longer: whatever real wall-clock time actually
    passed is exactly what this subtraction reflects the next time this
    file's thread actually resumes.

    THE ENTIRE "DELAY BEFORE MARKERS GO AWAY" MECHANISM, ON TOGGLE-OFF:
    ToggleScentVision() turning the ability OFF does NOT clear
    `scentVisionSnapshot` — it only stops polling for FRESH data. The render
    hook below keeps drawing whatever was last received, with each
    individual dot still fading/expiring on its own already-established
    per-dot timer, until the snapshot naturally empties (every dot expired)
    — at which point `DrawScentVisionPoints` clears it itself and the shared
    render thread above goes back to idling. There is deliberately no
    second "linger" timer to configure or maintain: each dot's own
    dotLifetimeMs already IS the delay the owner asked for, so a second
    knob would only be a second, redundant way to get the same answer wrong.

    MODE (Config.Tracking.ScentVision.mode) — LATER pass, owner-directed:
    "make the scent tracking a keybind and choose always active or [not]".
    Three values ('always'/'keybind'/'off' — see config.lua's own comment
    for the full plain-English writeup) resolved into SCENT_VISION_MODE
    below. 'keybind' is everything documented above, unchanged. 'off' makes
    ToggleScentVision() a genuine no-op (own dedicated notify, never
    DenyK9UIAccess() — that path means something different). 'always' hands
    START to a dedicated watcher thread further below instead of the
    keybind, with ToggleScentVision() itself becoming a no-op too (not
    player-controlled). ALL THREE share the exact same STOP path this
    header already describes — getScentVisionPoints' own echoed live `mode`
    (learned by EnsureScentVisionPollThreadRunning below, in
    `scentVisionServerMode`) can force a stop from ANY of the three at any
    time, unconditionally, the moment the server says 'off' — this is what
    keeps an admin's live 'always'->'off' edit from stranding an
    already-rendering player, per this codebase's own "gate the start,
    never the stop" rule.

    CONTRABAND BODY HIGHLIGHT (owner-directed follow-up, 2026-08-26 --
    "diffrent colors on there body if they have explosives drugs etc") rides
    THIS SAME poll/response rather than a second one. server/tracking.lua's
    own getScentVisionPoints callback already reduces this down to nothing
    but a network id and a short list of pre-resolved RGB swatches per
    visible person (see that callback's own "CONTRABAND BODY HIGHLIGHT"
    header for the full five-point design writeup) -- this file's job is
    purely "resolve that network id to a local entity and draw the swatches
    on it", the same DUMB-RENDERER posture it already has for trail points.
    See SCENT_VISION_CONTRABAND_HIGHLIGHT_LINGER_MS's own comment for why
    this half gets a SHORTER, separate on-screen lifetime than a trail dot's
    own dotLifetimeMs.
    ======================================================================
]]

-- CLAMP AND WARN (this resource's standing "a non-positive/invalid
-- millisecond value must never silently mean something dangerous" rule —
-- server/cooldowns.lua's own header names the sibling risk for a cooldown
-- threshold; the risk here is a Wait(0)-or-worse poll loop). Resolved ONCE
-- at file load, mirroring this resource's own PULSE_MAX_INTERVAL_MS
-- precedent exactly (read before writing this), rather than re-validated on
-- every poll.
local SCENT_VISION_POLL_INTERVAL_MS_DEFAULT = 1500
local SCENT_VISION_POLL_INTERVAL_MS = SCENT_VISION_POLL_INTERVAL_MS_DEFAULT
do
    local configured = Config.Tracking.ScentVision and Config.Tracking.ScentVision.pollIntervalMs
    if type(configured) == 'number' and configured == configured and configured > 0 then
        SCENT_VISION_POLL_INTERVAL_MS = configured
    else
        print(('[John-K9] ScentVision: Config.Tracking.ScentVision.pollIntervalMs must be a positive number of milliseconds (got %s) -- falling back to the shipped default of %dms.'):format(tostring(configured), SCENT_VISION_POLL_INTERVAL_MS_DEFAULT))
    end
end

-- Used ONLY until the first server response arrives (which always echoes
-- back the lifetime it actually enforced for that response — see
-- server/tracking.lua's own comment on `dotLifetimeMs`) — never trusted
-- over a real response. Kept numerically equal to config.lua's own shipped
-- Config.Tracking.ScentVision.dotLifetimeMs default and
-- server/tracking.lua's own ResolveConfiguredThresholdMs fallback so a
-- fresh client's very first frame (before any response has arrived at all,
-- which cannot happen anyway since `scentVisionSnapshot` starts nil and
-- this constant is never read until a response exists) stays consistent
-- with the rest of this resource's defaults.
local SCENT_VISION_DOT_LIFETIME_MS_DEFAULT = 45000

-- Same clamp-and-warn treatment as SCENT_VISION_POLL_INTERVAL_MS above.
-- Clamped to [0, 1) — a dot must stay fully opaque for SOME leading
-- fraction of its life (0 is allowed: fade starts immediately) and must
-- never be told to start fading at or past 100% of its own lifetime (which
-- would either never fade at all before expiring or divide by zero in the
-- fade-progress math below).
local SCENT_VISION_FADE_START_FRACTION_DEFAULT = 0.5
local SCENT_VISION_FADE_START_FRACTION = SCENT_VISION_FADE_START_FRACTION_DEFAULT
do
    local configured = Config.Tracking.ScentVision and Config.Tracking.ScentVision.fadeStartFraction
    if type(configured) == 'number' and configured == configured and configured >= 0.0 and configured < 1.0 then
        SCENT_VISION_FADE_START_FRACTION = configured
    else
        print(('[John-K9] ScentVision: Config.Tracking.ScentVision.fadeStartFraction must be a number in [0, 1) (got %s) -- falling back to the shipped default of %.2f.'):format(tostring(configured), SCENT_VISION_FADE_START_FRACTION_DEFAULT))
    end
end

-- CONTRABAND BODY HIGHLIGHT (owner-directed follow-up, 2026-08-26 -- see
-- server/tracking.lua's own "CONTRABAND BODY HIGHLIGHT" header for the full
-- design writeup and the five decisions recorded there). Unlike a trail
-- point (which carries its OWN ageMs and fades on its OWN per-dot timer),
-- a highlight is a LIVE, right-now truth about a specific nearby person --
-- there is no sensible "per-item age" for it, so it is instead given a
-- short, SESSION-LOCAL linger window measured from the moment the
-- containing response was received: a highlight simply stops being drawn
-- once this much time has passed since the last successful poll, rather
-- than persisting for up to a full dotLifetimeMs (45s shipped) the way an
-- already-drawn trail point deliberately does. That distinction is
-- deliberate, not an oversight: dot lingering is the owner's own explicit
-- "delay before markers go away" ask for FOOTPRINTS; a lingering
-- contraband highlight after the handler has already moved on or the
-- ability was switched off would be a materially MORE sensitive kind of
-- leftover information, so it gets its own, much shorter, budget instead --
-- long enough to smooth over one missed poll, never long enough to read as
-- "still watching" well after the fact.
local SCENT_VISION_CONTRABAND_HIGHLIGHT_LINGER_MS = SCENT_VISION_POLL_INTERVAL_MS * 2

-- DrawMarker parameters for a contraband highlight -- the EXACT same
-- already-verified native/call shape DrawTrailMarker/DrawScentVisionPoints
-- below already use (see DrawScentVisionPoints' own doc comment for the
-- native-verification citation; no new native is introduced for this).
-- Deliberately a SMALLER scale and a different base Z offset than
-- TRAIL_MARKER_SCALE/TRAIL_MARKER_TYPE above -- a highlight sits ON the
-- person's own body (stacked upward from roughly waist height, one ring
-- per colour), never on the ground the way a footprint trail dot does.
local CONTRABAND_HIGHLIGHT_MARKER_TYPE = 1
local CONTRABAND_HIGHLIGHT_MARKER_SCALE = 0.35
local CONTRABAND_HIGHLIGHT_BASE_Z_OFFSET = 0.4 -- roughly waist/stomach height above GetEntityCoords' own root-bone-ish return for a standing ped
local CONTRABAND_HIGHLIGHT_STACK_SPACING = 0.35 -- vertical gap between stacked colour rings when more than one category (or the baseline colour) matches at once

-- Full opacity for a not-yet-fading dot -- matches TRAIL_MARKER_COLOR.a
-- above (180) closely enough to read as "the same kind of marker", picked
-- independently since ScentVision markers carry their own per-point colour
-- rather than one fixed TRAIL_MARKER_COLOR.
local SCENT_VISION_MARKER_ALPHA = 200

-- MODE (Config.Tracking.ScentVision.mode) -- owner-directed pass: "make the
-- scent tracking a keybind and choose always active or [not]". See
-- config.lua's own comment on this exact setting for the full plain-English
-- writeup of what each of the three choices costs -- this is just the
-- resolution/enforcement side.
--
-- Resolved ONCE at file load, same "client-only, resolved once" shape as
-- SCENT_VISION_POLL_INTERVAL_MS/SCENT_VISION_FADE_START_FRACTION above (see
-- config.lua's own "CLIENT-SIDE EXCEPTION, DISCLOSED" comment on this whole
-- block for why that is an honest limitation, not a bug) -- a config edit
-- from 'keybind' to 'always' does not retroactively start rendering for a
-- player already connected before the next restart. CLAMP AND WARN, same
-- posture as every other setting in this section: an unrecognised value
-- (anything other than the three exact strings config.lua documents) never
-- silently becomes 'always' (the one choice that puts something on an
-- eligible player's screen unasked) -- it falls back to 'keybind', the
-- safest and most conservative of the three, with one clear console
-- warning naming this exact setting.
local SCENT_VISION_MODE_DEFAULT = 'keybind'
local SCENT_VISION_MODE = SCENT_VISION_MODE_DEFAULT
do
    local configured = Config.Tracking.ScentVision and Config.Tracking.ScentVision.mode
    if configured == 'always' or configured == 'keybind' or configured == 'off' then
        SCENT_VISION_MODE = configured
    else
        print(('[John-K9] ScentVision: Config.Tracking.ScentVision.mode must be one of "always", "keybind", or "off" (got %s) -- falling back to the shipped default of "%s".'):format(tostring(configured), SCENT_VISION_MODE_DEFAULT))
    end
end

--- The freshest `mode` the SERVER has actually told us, learned from
--- getScentVisionPoints' own echoed field (see that callback's own comment
--- server-side) every time a poll succeeds -- nil until the very first
--- response ever arrives. THIS is what makes turning the ability off reach
--- an already-polling client live (no restart) -- see
--- EnsureScentVisionPollThreadRunning below, which is also the ONLY place
--- this is ever written. Never used to auto-START anything (this file's own
--- "gate the start, never the stop" rule) -- only ever consulted to decide
--- whether an ALREADY-RUNNING poll loop or the always-on watcher below
--- should keep going.
--- @type 'always'|'keybind'|'off'|nil
local scentVisionServerMode = nil

--- @return 'always'|'keybind'|'off'
local function EffectiveScentVisionMode()
    return scentVisionServerMode or SCENT_VISION_MODE
end

--- @type boolean
local scentVisionActive = false
--- In-flight/staleness token — same shape/reasoning as this file's own
--- `trackRequestGeneration` above and this resource's own
--- `huntGeneration`: bumped by every toggle so a poll loop started before a
--- toggle-off can never keep acting past it.
--- @type number
local scentVisionGeneration = 0
--- Cached last-received render snapshot, or nil when nothing has ever been
--- received (or everything in it has since individually expired — see
--- DrawScentVisionPoints below, which is the ONLY place this is ever set
--- back to nil once populated).
--- @type { dotLifetimeMs: number, receivedAtClientMs: number, points: { x: number, y: number, z: number, r: number, g: number, b: number, ageMs: number }[], highlights: { netId: number, colors: { r: number, g: number, b: number }[] }[] } | nil
local scentVisionSnapshot = nil

--- @return boolean
function IsScentVisionActive()
    return scentVisionActive
end

--- Draws every still-live point in `scentVisionSnapshot` this frame
--- (already-expired ones are skipped, never drawn), and every still-fresh
--- contraband body highlight (see SCENT_VISION_CONTRABAND_HIGHLIGHT_LINGER_MS
--- above for that half's own, separate freshness rule), and reports whether
--- ANYTHING was actually drawn (either half), so the shared render thread
--- (this file's own TRACK_RENDER_IDLE_TICK_MS block above) can decide
--- whether to keep running at Wait(0) or go back to idling. Also clears
--- `scentVisionSnapshot` to nil entirely once EVERY point in it has
--- individually expired AND no highlight is still fresh, so that thread
--- does not keep re-evaluating an empty, fully-expired snapshot forever —
--- this is also the ENTIRE mechanism behind dots persisting for a while
--- after ToggleScentVision() turns the ability off (see this section's own
--- header).
---
--- DrawMarker — VERIFIED (this pass): its own ext/native-decls page 404s
--- (https://raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/DrawMarker.md
--- — a 404 there is NOT proof of absence for a legacy R* native, per this
--- resource's own standing rule and .luacheckrc's own DrawMarker precedent).
--- Confirmed instead against the documented fallback,
--- runtime.fivem.net/doc/natives.json (fetched this pass): GRAPHICS
--- namespace, hash 0x28477EC23D892089, name DRAW_MARKER, no `apiset` key —
--- which, per this resource's own established reading of that field
--- elsewhere (.luacheckrc's own comments on SetPlayerModel/CreatePed/etc.),
--- means the default, CLIENT-ONLY, matching this file's own existing,
--- already-shipped DrawTrailMarker() call site above and the realm this
--- function itself runs in. No new native is introduced here — this
--- function reuses the EXACT same already-verified DrawMarker call shape
--- DrawTrailMarker() above already uses (type 1, a flat cylinder/checkpoint
--- ring), only parameterized by each point's own colour instead of one
--- fixed TRAIL_MARKER_COLOR.
--- @return boolean drewAnything
DrawScentVisionPoints = function()
    if not scentVisionSnapshot then return false end

    local nowClient = GetGameTimer()
    local elapsedSinceReceived = nowClient - scentVisionSnapshot.receivedAtClientMs
    local lifetimeMs = scentVisionSnapshot.dotLifetimeMs
    local fadeEnabled = Config.Tracking.ScentVision and Config.Tracking.ScentVision.fadeEnabled == true

    local anyLive = false
    local points = scentVisionSnapshot.points
    for i = 1, #points do
        local point = points[i]
        -- EACH DOT'S OWN individual age, evaluated against a TIMESTAMP —
        -- see this section's own header for why this is never a
        -- per-frame-decremented countdown.
        local effectiveAgeMs = point.ageMs + elapsedSinceReceived
        if effectiveAgeMs < lifetimeMs then
            anyLive = true
            local alpha = SCENT_VISION_MARKER_ALPHA
            if fadeEnabled then
                local lifeFraction = effectiveAgeMs / lifetimeMs
                if lifeFraction > SCENT_VISION_FADE_START_FRACTION then
                    local fadeProgress = (lifeFraction - SCENT_VISION_FADE_START_FRACTION) / (1.0 - SCENT_VISION_FADE_START_FRACTION)
                    alpha = math.floor(SCENT_VISION_MARKER_ALPHA * (1.0 - fadeProgress) + 0.5)
                    if alpha < 0 then alpha = 0 end
                end
            end

            DrawMarker(
                TRAIL_MARKER_TYPE,
                point.x, point.y, point.z - 0.9,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE, TRAIL_MARKER_SCALE,
                point.r, point.g, point.b, alpha,
                false, false, 2, false, '', '', false
            )
        end
    end

    -- CONTRABAND BODY HIGHLIGHT -- see this section's own comment on
    -- SCENT_VISION_CONTRABAND_HIGHLIGHT_LINGER_MS above for why this uses
    -- its OWN, much shorter linger window instead of riding each point's
    -- own ageMs. Drawn from `scentVisionSnapshot.highlights`, which the
    -- poll loop below replaces wholesale on every successful response —
    -- server/tracking.lua's own getScentVisionPoints already resolved every
    -- swatch server-side, so this is purely "draw what I was told, on the
    -- entity I was told to draw it on", the same posture DrawTrailMarker/
    -- the point loop above already have.
    local highlightsFresh = type(scentVisionSnapshot.highlights) == 'table'
        and #scentVisionSnapshot.highlights > 0
        and elapsedSinceReceived < SCENT_VISION_CONTRABAND_HIGHLIGHT_LINGER_MS

    if highlightsFresh then
        local highlights = scentVisionSnapshot.highlights
        for i = 1, #highlights do
            local highlight = highlights[i]
            -- Single, non-yielding check (attempts defaults to 1) — this
            -- runs inside a per-frame render loop, where a Wait() would be
            -- wrong (ResolveNetworkEntity's own doc comment, client/main.lua).
            local entity = ResolveNetworkEntity(highlight.netId)
            if entity then
                local coords = GetEntityCoords(entity)
                local colors = highlight.colors
                for c = 1, #colors do
                    local color = colors[c]
                    DrawMarker(
                        CONTRABAND_HIGHLIGHT_MARKER_TYPE,
                        coords.x, coords.y, coords.z + CONTRABAND_HIGHLIGHT_BASE_Z_OFFSET + (c - 1) * CONTRABAND_HIGHLIGHT_STACK_SPACING,
                        0.0, 0.0, 0.0,
                        0.0, 0.0, 0.0,
                        CONTRABAND_HIGHLIGHT_MARKER_SCALE, CONTRABAND_HIGHLIGHT_MARKER_SCALE, CONTRABAND_HIGHLIGHT_MARKER_SCALE,
                        color.r, color.g, color.b, SCENT_VISION_MARKER_ALPHA,
                        false, false, 2, false, '', '', false
                    )
                end
            end
        end
    end

    if not anyLive and not highlightsFresh then
        scentVisionSnapshot = nil
    end

    return anyLive or highlightsFresh
end

--- Poll loop — same pcall/generation-staleness shape as this file's own
--- StartTrack() above and this resource's own
--- EnsureHuntPollThreadRunning (read before writing this, per this pass's
--- own instruction to extend an established pattern rather than invent a
--- new one). Runs on an INTERVAL, never per-frame — all per-frame work is
--- the separate, shared render thread's job (DrawScentVisionPoints above),
--- reading whatever this loop last stored in `scentVisionSnapshot`.
local function EnsureScentVisionPollThreadRunning()
    CreateThread(function()
        local myGeneration = scentVisionGeneration

        while scentVisionActive and myGeneration == scentVisionGeneration do
            -- OWN-DEATH EXIT PATH — same precedent as this file's own
            -- Track <Type> compute thread above (see that block's own doc
            -- comment for the full reasoning): continuing to poll from a
            -- dead ped's position is narratively nonsensical, and silently
            -- resuming on respawn from an unrelated coordinate would be
            -- worse than just stopping and saying so.
            if IsEntityDead(PlayerPedId()) then
                scentVisionGeneration = scentVisionGeneration + 1
                scentVisionActive = false
                lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_lost_death'), type = 'error' })
                break
            end

            -- FAIL-CLOSED GUARD — same reasoning/precedent as StartTrack()
            -- above and every other poll loop in this resource:
            -- lib.callback.await throws rather than returning nil on a
            -- timeout/rejection. Uncaught here, a throw would abort this
            -- whole CreateThread body, silently killing the poll loop with
            -- `scentVisionActive` still stuck true and no further updates
            -- ever arriving.
            local ok, result = pcall(lib.callback.await, 'john-k9:server:getScentVisionPoints', K9_CALLBACK_TIMEOUT_MS)
            if not ok then result = nil end

            -- Staleness check — a ToggleScentVision() off-then-on cycle
            -- that ran while the await above was pending must not let this
            -- stale result resurrect a session the player already moved
            -- past.
            if myGeneration ~= scentVisionGeneration then break end

            -- LIVE STOP (Config.Tracking.ScentVision.mode / master feature
            -- flag) — THE TRAP THIS EXISTS TO CLOSE: never gate the STOP
            -- path behind a mode check, only ever the START. Learn the
            -- server's own live-resolved mode from THIS response
            -- (server/tracking.lua's own getScentVisionPoints echoes it
            -- fresh on every call, whether the feature is fully off or the
            -- caller is simply mid-query) and, the moment it says 'off',
            -- stop UNCONDITIONALLY — regardless of whether this session
            -- started from the keybind or from the always-on watcher below.
            -- CHECKED BEFORE the snapshot update just below, DELIBERATELY:
            -- the master-feature-off early return server-side always
            -- carries an EMPTY `points` array alongside `mode = 'off'` (see
            -- that callback's own comment), and letting THIS response
            -- overwrite `scentVisionSnapshot` before reacting to `mode`
            -- would wipe out whatever was already on screen a frame early,
            -- instead of leaving it to fade on its own already-established
            -- timer — the exact "delay before markers go away" contract
            -- ToggleScentVision()'s own manual-off already promises. Same
            -- shape as that manual path (bump the generation, drop
            -- `scentVisionActive`, leave `scentVisionSnapshot` untouched) —
            -- the ONLY difference is telling the player why, since this one
            -- was not their own choice.
            if result and (result.mode == 'always' or result.mode == 'keybind' or result.mode == 'off') then
                scentVisionServerMode = result.mode
            end
            if result and result.mode == 'off' then
                scentVisionGeneration = scentVisionGeneration + 1
                scentVisionActive = false
                lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_disabled_live'), type = 'inform' })
                break
            end

            if result and type(result.points) == 'table' then
                scentVisionSnapshot = {
                    dotLifetimeMs = type(result.dotLifetimeMs) == 'number' and result.dotLifetimeMs or SCENT_VISION_DOT_LIFETIME_MS_DEFAULT,
                    receivedAtClientMs = GetGameTimer(),
                    points = result.points,
                    -- `highlights` is REPLACED WHOLESALE alongside `points`
                    -- on every successful poll (never merged) -- see
                    -- SCENT_VISION_CONTRABAND_HIGHLIGHT_LINGER_MS's own
                    -- comment for why a contraband highlight deliberately
                    -- does NOT get to ride an already-established per-point
                    -- ageMs the way a trail dot does.
                    highlights = type(result.highlights) == 'table' and result.highlights or {},
                }
            end
            -- A failed/empty response (that is NOT a live 'off' signal,
            -- handled above) is NOT treated as "clear the snapshot" — the
            -- last-known trails simply keep fading on their own
            -- already-established per-dot timers (same "a transient hiccup
            -- should not visibly blank the screen" posture as leaving
            -- `scentVisionSnapshot` alone on ToggleScentVision() off, per
            -- this section's own header).

            Wait(SCENT_VISION_POLL_INTERVAL_MS)
        end
    end)
end

--- Resource-global keybind entry point (client/keybinds.lua). A single
--- context-sensitive toggle — mirrors this resource's own established
--- Toggle*() shape (ToggleThermalVision/ToggleNightVision/ToggleK9Camera in
--- client/vision.lua/client/movement.lua) rather than a Start/Stop pair,
--- since there is exactly one on/off state here with no third "which one"
--- choice to make.
---
--- TERMINATION IS NEVER GATED — turning the ability OFF always works,
--- unconditionally, per this resource's standing "no unbounded trap" rule
--- (the same rule StopTracking() above and elsewhere in
--- this resource already document for themselves). Toggling off does NOT
--- clear `scentVisionSnapshot` — see this section's own header for why
--- that omission IS the "delay before markers go away" mechanism, not a
--- bug.
--- MODE-AWARE, this pass — Config.Tracking.ScentVision.mode (see config.lua's
--- own comment on that setting). Both new branches below are checked AFTER
--- the existing Config.Features.ScentVision/scentVisionActive-already-on
--- checks above them, and BEFORE the existing CanShowK9UI() gate — neither
--- one touches the STOP path (`scentVisionActive` already true, above) at
--- all, only the START path, per this file's own "never gate the stop"
--- rule this whole section's header already documents.
---
--- 'off': genuinely inert — the keybind exists (client/keybinds.lua
--- registers it whenever Config.Features.ScentVision is on, independent of
--- this mode) but this function refuses to ever start anything for it, so
--- pressing the key costs one lib.notify() call and nothing else: no poll
--- thread, no network round trip, no per-frame render work.
---
--- 'always': not player-controlled at all — the always-on watcher thread
--- below is what starts/keeps this running for an eligible player, with
--- nothing to press. A keybind press in this mode is a deliberate no-op
--- (with its own explanatory notify) rather than a toggle, so it can never
--- fight the watcher into a flicker.
function ToggleScentVision()
    if not Config.Features.ScentVision then
        DenyK9UIAccess()
        return
    end

    -- CHECKED BEFORE the "already active" branch just below, DELIBERATELY:
    -- in 'always' mode, `scentVisionActive` is already true whenever this
    -- watcher-started session is running, and this function must NOT treat
    -- a keybind press as the toggle-off in that case (that would be the
    -- player fighting the always-on watcher, which would just restart it
    -- again on its very next pass — see that thread's own comment below).
    -- This is a UX/policy no-op, not "gating the stop": the ONE real stop
    -- path for an admin-driven 'always'->'off' change is
    -- EnsureScentVisionPollThreadRunning()'s own live-mode check above,
    -- which is unconditional and never consults this function at all.
    local mode = EffectiveScentVisionMode()
    if mode == 'off' then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_mode_off'), type = 'error' })
        return
    end
    if mode == 'always' then
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_mode_always_notice'), type = 'inform' })
        return
    end

    if scentVisionActive then
        scentVisionGeneration = scentVisionGeneration + 1
        scentVisionActive = false
        -- Confirmed, not silent. See the ON branch below for why this
        -- ability in particular cannot be left to speak through its own
        -- visuals.
        lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_off'), type = 'inform' })
        return
    end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    scentVisionGeneration = scentVisionGeneration + 1
    scentVisionActive = true
    -- SAYS SO, both edges, matching client/vision.lua's own thermal/night
    -- toggles (vision.thermal_on / vision.thermal_off) rather than being
    -- the one ability in the set that answers a keypress with nothing.
    --
    -- THE REASON THIS ONE MATTERS MORE THAN A CONSISTENCY ARGUMENT: thermal
    -- and night vision change the whole screen the instant they engage, so
    -- they are self-evidencing even without their notify. Scent vision
    -- draws dots ONLY where the server reports a scent, and only after the
    -- first poll returns. Turn it on with nothing in range -- the ordinary
    -- case, since you switch it on to go looking -- and absolutely nothing
    -- happens on screen. Silence there is indistinguishable from a dead
    -- keybind, and gets reported as one.
    --
    -- The message says so outright rather than just "on", so a handler
    -- standing in an empty street knows the ability engaged and there is
    -- simply nothing to smell yet, instead of pressing the key again.
    lib.notify({ title = locale('common.notify_title'), description = locale('tracking.scent_vision_on'), type = 'inform' })
    EnsureScentVisionPollThreadRunning()
end

-- ALWAYS-ON AUTO-START WATCHER (Config.Tracking.ScentVision.mode ==
-- 'always') — the ONLY place this file ever starts ScentVision without a
-- keybind press. Gated on the STATIC, boot-time SCENT_VISION_MODE (not
-- EffectiveScentVisionMode()) for whether this thread is created AT ALL —
-- a session that boots in 'keybind' or 'off' never spins this thread up in
-- the first place, matching this resource's own "no thread left running for
-- a feature that is not relevant right now" performance rule, and matching
-- config.lua's own disclosed limitation that flipping 'keybind' to 'always'
-- live does not retroactively start rendering for an already-connected
-- player before the next restart.
--
-- The thread BODY, once it exists, checks EffectiveScentVisionMode() (not
-- the static value) on every pass — so the moment
-- EnsureScentVisionPollThreadRunning() above learns, live, that the server
-- now says 'off' (or the feature itself went off), this watcher stops
-- trying to restart it too. That is what stops "always" from fighting a
-- live "off" signal: once the server has said stop, this watcher agrees,
-- for the rest of this session.
--
-- CanShowK9UI() is re-checked every pass, not just once, so a handler who
-- is not YET eligible at resource start (no active certification loaded
-- yet, not currently controlling their K9, etc.) starts seeing this the
-- moment they become eligible, without needing to press anything or
-- reconnect.
if Config.Features.ScentVision and SCENT_VISION_MODE == 'always' then
    local SCENT_VISION_ALWAYS_ON_WATCH_INTERVAL_MS = 3000

    CreateThread(function()
        while true do
            if EffectiveScentVisionMode() == 'always' and not scentVisionActive and CanShowK9UI() then
                scentVisionGeneration = scentVisionGeneration + 1
                scentVisionActive = true
                EnsureScentVisionPollThreadRunning()
            end
            Wait(SCENT_VISION_ALWAYS_ON_WATCH_INTERVAL_MS)
        end
    end)
end
