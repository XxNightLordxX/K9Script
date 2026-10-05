--[[
    john-k9/server/progression.lua

    Phase 4 (coder-backend). Owns `Config.Features.XPProgression` end to
    end: server-authoritative XP accumulation, the `k9_progression`
    persistence table (sql/install.sql), the `K9XP[citizenid]` in-memory
    cache mirroring `server/certifications/`'s `Certifications` cache
    pattern exactly (per DEVELOPER_REFERENCE.md#xp-schema §5's own
    recommendation), and the tier-lookup helper walking `Config.XPTiers` the
    same way `server/search.lua` walks `Config.ContrabandAlertTiers`.

    PERSISTENCE DECISION (not re-litigated here — see
    DEVELOPER_REFERENCE.md#xp-schema, db-schema's design note, and
    DEVELOPER_REFERENCE.md §13.4.1/§13.5's own header claiming this note is
    "adopted"): a dedicated table, `k9_progression`, ONE ROW PER CITIZENID —
    NOT a qbx_core metadata field. XP is real, mechanical, capability-
    adjacent state (a tier crossing changes a K9's actual scent range and
    movement speed, per Config.XPTiers), the same category of decision this
    resource already made once for `k9_certifications` over metadata
    (DEVELOPER_REFERENCE.md §4.3), for the same three reasons: offline correction must
    work, atomic accumulation needs a single UPSERT (not a Lua-side
    read-modify-write race), and admin/ops queryability without scanning
    every player's JSON blob. See sql/install.sql's own `k9_progression`
    header comment for the schema itself.

    SCOPING: per Config.XP.scopePerCitizenidOrJob (currently only
    'citizenid' is implemented — see that config field's own comment and
    DEVELOPER_REFERENCE.md §13.6 item 2 for the still-open 'job' alternative, a
    product call this file does not attempt to resolve). `k9_progression`
    has a plain `citizenid` PRIMARY KEY, no job column — XP survives a
    department change, unlike `k9_certifications`.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4. Identical in format to
    server/certifications/'s contract block.

    Callbacks: none. There is no "what's my current XP/tier" callback —
    every tier-relevant push is the server-initiated event below; a future
    UI wanting to *display* XP can read from that push, not poll for it.

    Server events (RegisterNetEvent, client->server): NONE for awarding XP.
    Every award is server-triggered internally, from inside the existing
    server-side success paths of server/search.lua, server/tracking.lua,
    and server/combat.lua (Phase 3 landed after this pass and now calls
    AwardXP directly from both requestBiteHold's and requestTakedown's own
    success paths — see Config.XP.awards' own comments in config.lua) —
    never from a client-fired "I earned XP" event. There is no legitimate
    reason for a client to ever claim this, and none is exposed.

    Client events (RegisterNetEvent, server->client):
    1. 'john-k9:client:xpTierChanged' (newTier: table — a copy of the
       citizenid's resolved Config.XPTiers entry: { xp, label,
       speedMultiplier, scentRangeMultiplier, ... }, WITH speedMultiplier/
       scentRangeMultiplier/medkitCooldownMultiplier OVERLAID by
       server/k9profiles.lua's per-INDIVIDUAL-K9 override, if this citizenid
       has one live — GAP 1 closure, this pass; see PushTierSnapshot/
       BuildEffectiveTierSnapshot below for the exact composition contract.
       A citizenid with no override sees byte-identical values to before
       this pass. UNBOUNDED-TRAP FIX (this pass): ALSO now always carries a
       `.live` boolean — Config.Features.XPProgression's CURRENT value at
       the moment this snapshot was built, never withheld the way the
       payload itself used to be entirely while the flag was off. See
       PushTierSnapshot's own doc comment below and
       client/progression.lua's own header for the full "AN UNBOUNDED TRAP"
       writeup this closes.)
       [client/progression.lua] — sent to the K9's own client ONLY
       (never broadcast), on: (a) PlayerLoaded / resource-start backfill
       (an authoritative snapshot so a returning K9 doesn't need to earn
       fresh XP this session before their tier's effects apply again),
       (b) any real tier crossing caused by AwardXP below, and (c) NEW,
       this pass: RefreshXPProgressionLiveStateForAllOnline (below), called
       by server/runtimecontrol.lua's ApplyFeatureOverride the instant an
       operator flips Config.Features.XPProgression at runtime, for every
       currently-connected citizenid. client/progression.lua does not need
       to distinguish (a)/(b)/(c) for correctness (it always applies
       newTier.speedMultiplier to K9MoveRateModifiers.xpTier, then
       force-resets to neutral if `.live` reads false, either way) — it
       only distinguishes (a) from a real tier-up for whether to show a
       "you leveled up" notification (never on the initial post-login
       snapshot).
    2. 'john-k9:client:handlerXpTierChanged' (NEW, this pass -- "a
       handler cannot see their own rank or XP anywhere" gap closure):
       { totalXp: number, tier: table (a CopyTier()'d Config.HandlerXPTiers
       entry), live: boolean }. Same delivery discipline as #1 above (the
       handler's own client only, never broadcast; `.live` always carried,
       never withheld while the flag is off) and the SAME three trigger
       points: PlayerLoaded/resource-start backfill, a real tier crossing
       inside AwardHandlerXP, and RefreshHandlerXPProgressionLiveStateForAllOnline
       (a runtime-toggle refresh mirroring #1's own — see that function's
       own doc comment for the one piece of wiring it still needs from
       server/runtimecontrol.lua, out of this pass's own edit scope). See
       PushHandlerTierSnapshot's own doc comment (further down this file)
       for the full payload/"why a separate event" writeup.

    Commands: none.

    Automatic path: 'QBCore:Server:PlayerLoaded' (cache warm + initial
    snapshot push) and the resource-start backfill loop below (mirrors
    server/main.lua's own onResourceStart backfill for Certifications,
    same structural-gap rationale: a `/restart john-k9` while players are
    already online needs to re-warm K9XP for them too, since PlayerLoaded
    never re-fires for an already-connected player).
    ======================================================================

    FILE-TO-FILE CONTRACT — THIS FILE exposes four resource-global (no
    `local`) functions (a fourth, RefreshXPProgressionLiveStateForAllOnline,
    added this pass — see its own declaration below for the full contract;
    not repeated here since server/runtimecontrol.lua is its only caller
    and that call site's own comment already carries the "why". NOT an
    exhaustive inventory of every resource-global this file has ever added
    — AwardHandlerXP/GetHandlerXPTier/GetHandlerXPTierMedkitCooldownMs/
    GetHandlerXPTierKennelDeployCooldownMs/RefreshHandlerXPProgressionLiveStateForAllOnline/
    AwardXPDirect/GetXP/PushXPTierSnapshotIfOnline are each documented at
    their own declaration instead, same as this "fourth" one already was):
        AwardXP(citizenid, actionKey)
            actionKey is a string key into Config.XP.awards (e.g.
            'searchContrabandFound', 'trackSourceResolved',
            'biteHoldSuccess', 'takedownSuccess'). Re-checks
            Config.Features.XPProgression itself (defensive no-op if
            disabled, per DEVELOPER_REFERENCE.md §3 — callers are not required to gate
            this themselves, though every current call site already does
            for clarity). Updates the in-memory K9XP cache SYNCHRONOUSLY
            before firing a non-blocking DB UPSERT (DEVELOPER_REFERENCE.md#xp-schema
            §5 — correctness of the applied gameplay effect never depends on
            DB round-trip latency). Called from server/search.lua and
            server/tracking.lua this pass via a `type(AwardXP) == 'function'`
            runtime existence guard (the same guard every equivalent soft
            cross-file dependency in this resource uses) — NOT a load-order assumption, so
            this file's position in fxmanifest.lua's server_scripts list is
            not load-bearing for those callers. server/combat.lua, once
            built, should call this the same way for 'biteHoldSuccess'/
            'takedownSuccess' — see config.lua's own comment on those two
            award keys.
        GetXPTier(citizenid) -> table
            Always returns a real Config.XPTiers entry (never nil) — an
            unknown/not-yet-cached citizenid resolves to the base tier
            (Config.XPTiers[1], 0 XP), the same "unknown state defaults to
            least privilege" posture this resource already applies
            elsewhere. Read by server/tracking.lua's findTrackableSource to
            apply the tier's `scentRangeMultiplier` server-side — callers are
            responsible for gating this read behind
            Config.Features.XPProgression themselves (this accessor does
            not gate internally, so it stays a plain, always-correct cache
            read regardless of caller).
            DELIBERATELY STILL RAW, NOT OVERRIDE-AWARE BY DESIGN (GAP 1
            closure, original pass — stated explicitly so this does not
            read as an oversight): this function's own return value is
            UNCHANGED — still the plain XP-tier lookup, never composed with
            server/k9profiles.lua's per-INDIVIDUAL-K9 override internally.
            Widening THIS accessor itself to compose the override was
            rejected: doing so would silently change what every one of its
            existing callers (server/tracking.lua, server/search.lua,
            server/tablet.lua, server/highcommand.lua, server/exports.lua)
            receives, several of which have no documented need for the
            override at all — too wide a blast radius for one accessor to
            take on for those files' own owners. Instead, each caller that
            genuinely needs the composed answer calls
            GetK9EffectiveMultipliers(citizenid) directly, as its own
            separate, explicit step — see that function's own doc comment
            (server/k9profiles.lua).
            CORRECTED (this pass, coder-backend): this paragraph used to say
            "server/tracking.lua's own scent-range consumer is DISCLOSED,
            NOT YET WIRED" and that only one caller "could actually use" the
            override — both re-verified false by direct read before writing
            this correction. server/tracking.lua's own scent-range consumer
            IS WIRED (its own findTrackableSource now calls
            GetK9EffectiveMultipliers(trackerCitizenid) directly, with a
            documented fallback to the raw GetXPTier read when that global
            is unavailable — see that file's own "INDIVIDUAL-OVERRIDE FIX"
            comment). server/exports.lua's own public GetXPTier export is
            ALSO now wired the same way (composes GetK9EffectiveMultipliers
            onto its own tier copy before handing it to a third-party
            resource, with the identical raw-tier fallback) — so this is no
            longer "only one" consumer. server/search.lua and
            server/tablet.lua remain on the plain GetXPTier value; that is
            not a disclosed gap, since neither has a documented need to
            reflect an individual override today — a genuine future need
            there should follow the same GetK9EffectiveMultipliers(citizenid)
            call pattern, never a widening of this accessor.
        GetXP(citizenid) -> number
            Raw accumulated total (0 if uncached). Not currently consumed
            anywhere in this resource — exposed for a future HUD/display
            need (DEVELOPER_REFERENCE.md §13.4.1's own "additive read, not a new
            authorization surface" framing) rather than re-deriving a
            second cache elsewhere.

    XP TIER UNLOCKS ADDITION (this pass, DEVELOPER_REFERENCE.md Part B §8) — one
    more resource-global, documented in full at its own declaration below
    (search this file for "GetXPTierMedkitCooldownMs") rather than repeated
    here: GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs) -> number. See
    the dedicated "XP TIER UNLOCKS" section further down this file for the
    full design (which three tiers unlock what, and why every rejected
    candidate was rejected — both on farmability grounds and on composition
    with server/permissions.lua's grant/block resolution order).
    THIS FILE calls `HasK9Access`... it does NOT — AwardXP is only ever
    invoked from a caller that has already independently re-verified
    HasK9Access for the acting player at its own call site (server/search.lua,
    server/tracking.lua); duplicating that check here would be redundant,
    not defense-in-depth, since AwardXP is not itself a network-facing
    surface (no RegisterNetEvent/lib.callback reaches it directly).
    THIS FILE owns `K9XP` (citizenid -> number) as file-local state,
    structurally identical to server/certifications/'s `Certifications`
    cache (refreshed on PlayerLoaded/resource-start backfill, evicted on
    playerDropped to bound memory growth, per that file's own "regression-
    test fix" precedent).
    ======================================================================
]]

-- K9XP[citizenid] = number (accumulated total). Local: nothing outside this
-- file should read/write it directly — always go through AwardXP/GetXPTier/
-- GetXP. Mirrors server/certifications/'s `Certifications` cache shape
-- and its own "nothing outside this file should read it directly" rule.
local K9XP = {}

-- CHOKEPOINT-LEVEL RATE FLOOR (audit finding, this pass). Every anti-farm
-- defence that exists today (server/search.lua's contraband-weight-change
-- dedup, server/tracking.lua's travel-distance/minimum-elapsed-time arrival
-- gate, server/combat.lua's MIN_BITE_HOLD_XP_DURATION_MS) was built
-- per-call-site, tailored to that action's own semantics — and each of
-- those is a BETTER fit for its own action than anything generic could be
-- (only server/tracking.lua's own pending-arrival state knows what "genuine
-- travel time" means for a track resolution; only server/search.lua's own
-- ContrabandXpState knows what "a materially different search result"
-- means). This tracker is NOT trying to replace or re-litigate any of
-- those — it exists for the failure mode none of them can cover: a FUTURE
-- call site (a new Config.XP.awards key, a new subsystem calling AwardXP
-- the same soft-dependency way server/search.lua and server/tracking.lua
-- already do) that simply forgets to add its own rate limiting at all,
-- e.g. a bug that lets a per-tick/per-frame handler re-fire the same
-- successful action every server tick instead of once. Without a floor
-- HERE, that class of bug has no ceiling whatsoever — AwardXP itself
-- imposes none, and a caller bug is exactly the situation where "the caller
-- is expected to have already handled it" fails.
--
-- Keyed by (citizenid, actionKey) via NewNestedCooldown, NOT a blanket
-- per-citizenid floor — server/tenure.lua's CheckTenureMilestonesForK9
-- legitimately calls AwardXP more than once for the SAME citizenid within
-- the SAME server tick (a K9 reunited after a long absence can cross
-- several milestone thresholds in one pass, per that file's own "pays every
-- newly-crossed milestone" comment), each with a DIFFERENT actionKey
-- (partnershipTenure1Day/7Day/30Day) — a per-citizenid-any-action floor
-- would silently drop the 2nd/3rd milestone's XP in exactly that legitimate
-- case, the same class of silent-loss bug this pass was asked to rule out
-- elsewhere. Per-(citizenid, actionKey) never collides with that: each
-- milestone key is touched at most once ever per partnership (non-repeating
-- by tenure.lua's own design), so this floor is never even reached there.
--
-- THRESHOLD (500ms) chosen against every real call site's own already-
-- established minimum real-world spacing between two GENUINE awards of the
-- SAME actionKey for the SAME citizenid, so a real player can never
-- perceive this floor: searchContrabandFound (Config.SearchZones.
-- searchCooldownMs = 10000ms per target — a different target still needs
-- physical travel time between two genuine finds), trackSourceResolved
-- (TRACK_ARRIVAL_REPORT_COOLDOWN_MS = 2000ms, plus its own minElapsedMs
-- travel gate), biteHoldSuccess (MIN_BITE_HOLD_XP_DURATION_MS = 3000ms),
-- takedownSuccess (Config.Combat.NonLethalTakedown.targetCooldownMs =
-- 30000ms per target), tenure milestones (one-time, never repeating). 500ms
-- sits comfortably below all of those, so it only ever bites a call pattern
-- no genuine player action can produce — a runaway/looping caller bug (or a
-- future actionKey added without its own gate) — while still turning
-- "unbounded per tick" into "at most 2/second," a bounded, investigable
-- ceiling instead of an open one.
--
-- Cleaned up in the playerDropped handler below (NewNestedCooldown's
-- :Clear(primaryKey) drops every actionKey entry for that citizenid in one
-- call, mirroring server/tracking.lua's own LastTrackQueryAt[src] = nil
-- shape) rather than via :RegisterPlayerDropped(), since that helper clears
-- by the raw `source` value and this tracker's primaryKey is citizenid, not
-- a player source.
local AwardXPCooldown = NewNestedCooldown(500)

-- ==========================================================================
-- EIGHTH XP-FARM FIX (this pass, coder-backend, red-team-flagged COMPOUND-
-- FARM follow-up to the SEVENTH fix -- every number below independently
-- re-verified against the real, currently-shipped source before acting, not
-- taken on the report alone; see this file's own report for the full
-- arithmetic). The four per-mechanic MINT cooldowns this codebase already
-- built (server/combat.lua's BiteHoldXpMintCooldown/TakedownXpMintCooldown,
-- server/search.lua's ContrabandXpMintCooldown, server/tracking.lua's
-- TrackTicketMintCooldown -- see each one's own declaration comment for its
-- own "SEVENTH XP-FARM FIX" writeup) are each a real, independently correct
-- per-ACTOR ceiling for ITS OWN mechanic -- but every one of them is keyed
-- by the SAME acting player's source/citizenid, and nothing before this pass
-- ever summed the four together. A single player round-robining all four --
-- bite-hold one NPC, takedown a different NPC, run their own
-- self-controlled contraband stash, resolve their own track -- is blocked
-- by NONE of them, because each cooldown only ever sees its own single
-- mechanic's calls.
--
-- RE-DERIVED FROM THE REAL SHIPPED CONSTANTS (not copied from the report):
--   biteHoldSuccess:       20 XP / BITE_HOLD_XP_MINT_COOLDOWN_MS  (60000ms) = 1,200 XP/hr
--   takedownSuccess:       30 XP / TAKEDOWN_XP_MINT_COOLDOWN_MS   (60000ms) = 1,800 XP/hr
--   searchContrabandFound: 25 XP / CONTRABAND_XP_MINT_COOLDOWN_MS (60000ms) = 1,500 XP/hr
--   trackSourceResolved:   10 XP / TRACK_TICKET_MINT_COOLDOWN_MS  (30000ms) = 1,200 XP/hr
--   SUM (uncapped, structurally independent today) .................. = 5,700 XP/hr
-- Config.XPTiers' own economy comment (config.lua) was retuned specifically
-- so the worst-case farmable ceiling takes "over 2 hours" to reach the
-- 9,000-XP Elite tier. At the uncapped 5,700 XP/hr sum above, Elite is
-- reachable in 9000/5700 = 1.579 hours (~1h 35m) -- BELOW that floor, and
-- reachable with close to zero real police work once server/combat.lua's
-- own NPC-mint gate (Config.XP.mintXpForNpcCombatTargets, see that file) is
-- also accounted for.
--
-- FIX: a SHARED, cross-mechanic budget, keyed by citizenid (matching
-- Config.XP.scopePerCitizenidOrJob -- asserted 'citizenid' by the
-- onResourceStart handler below -- the same identity every award in this
-- file is already scoped by), consulted by EVERY AwardXP call regardless of
-- actionKey. This is the single chokepoint every mechanic's award already
-- passes through (that is the whole point of AwardXP being resource-global
-- and the sole write path to K9XP), so putting the shared budget HERE, once,
-- is sufficient -- no call site in server/combat.lua, server/search.lua, or
-- server/tracking.lua needs to change for this budget itself to apply to it.
--
-- NOT A REPLACEMENT for the four per-mechanic mint cooldowns -- kept
-- unchanged, deliberately (do not weaken or remove either half alongside
-- this): they shape WHICH mechanic can mint and at what per-mechanic
-- cadence (e.g. takedownSuccess's own 1,800 XP/hr ceiling is still the
-- right number for takedown ALONE); this budget caps the TOTAL across all
-- of them combined. Removing either half reopens a real gap the other half
-- cannot cover on its own: without the per-mechanic cooldowns, a single
-- mechanic could burn the ENTIRE shared budget in seconds (the exact
-- runaway-caller shape AwardXPCooldown above already exists to catch --
-- this budget is not a substitute for that floor either); without this
-- shared budget, the four independent ceilings simply never interact, which
-- is exactly the gap this section exists to close.
--
-- IMPLEMENTATION: a per-citizenid TOKEN BUCKET, refilling continuously
-- toward XP_MINT_BUDGET_CAP_XP at a constant rate -- NOT a fixed-window
-- counter that resets to 0 on a wall-clock boundary. A fixed window has a
-- well-known boundary-doubling flaw for this exact use case: a player could
-- spend a full budget in the last instant of window N, then spend a full
-- budget again in the first instant of window N+1, minting up to 2x the
-- intended cap within a couple of real seconds around every window edge. A
-- token bucket has no such edge -- capacity refills continuously, never
-- resets to 0 on a clock boundary.
--
-- STARTING BALANCE -- THIS TOOK THREE ATTEMPTS TO GET RIGHT, in this same
-- pass, each verified by direct simulation rather than assumed correct on
-- reasoning alone (see this pass's own report for the full numbers):
--   1. REJECTED: start FULL (tokens = XP_MINT_BUDGET_CAP_XP). The textbook
--      token-bucket default, and it does let a brand-new citizenid's first
--      award through -- but it re-opens exactly the burst-doubling flaw the
--      fixed-window rejection above already exists to avoid, just shifted to
--      "every citizenid's first hour" (and every hour immediately following
--      a long-idle-triggered sweep eviction, see the sweep thread's own
--      comment below): a full starting balance PLUS a full hour's continuous
--      refill-and-spend on top of it. Simulated: up to 7,150 XP in a
--      citizenid's first simulated hour of continuous max-rate farming --
--      pushing worst-case time-to-Elite back down to ~1.5 hours, BELOW the
--      >2-hour floor this entire section exists to restore.
--   2. REJECTED: start EMPTY (tokens = 0). This makes the bound rigorous
--      instead of approximate for a bucket already in motion (cumulative XP
--      granted by any elapsed time T becomes provably <= CAP * T / WINDOW_MS)
--      -- but it has a fatal edge case at T=0 itself: a bucket created AND
--      checked inside the SAME AwardXP call has, by definition, zero elapsed
--      time since its own creation, so it can never have refilled anything
--      yet -- meaning EVERY citizenid's FIRST-EVER AwardXP call, every
--      session, was silently denied before K9XP was ever touched. Caught by
--      two independent agents hitting it live via tests/progression_spec.lua
--      (9 failures, every one consistent with "AwardXP never grants on a
--      fresh citizenid") before this shipped -- a full regression of the
--      happy path, not a theoretical edge case, and THE SAME FOOTGUN SHAPE
--      server/cooldowns.lua's own IsOnCooldown has for a non-positive
--      threshold: a boundary condition silently meaning "blocked forever"
--      instead of "unrestricted."
--   3. CHOSEN: start at XP_MINT_BUDGET_STARTER_TOKENS (see its own
--      declaration below) -- a small, ONE-TIME allowance, sized to the
--      worst-case realistic SAME-TICK burst this file's own award table can
--      produce for a single citizenid (the SUM of every Config.XP.awards
--      value, computed once from the real live config, never hardcoded), NOT
--      the full cap. This exists specifically because AwardXP can
--      legitimately fire more than once in the SAME tick for the SAME
--      citizenid with DIFFERENT actionKeys (server/tenure.lua's
--      CheckTenureMilestonesForK9 -- see AwardXPCooldown's own declaration
--      comment above: a K9 reunited after a long absence can cross several
--      one-time, non-repeating milestones in a single pass, and every one of
--      them must still be paid). A starting balance this small barely moves
--      the long-run bound at all (see NUMBERS CHOSEN below for the exact,
--      simulated impact) while completely fixing both rejected attempts'
--      failure modes: a brand-new citizenid's first award (or first-tick
--      burst) is never denied, and no citizenid can ever bank close to a
--      whole extra cap's worth of "free" tokens the way a full start would.
--
-- Re-verified by direct simulation with the REAL shipped award table AND
-- the REAL bucket-created-at-first-use semantics (a bucket's own
-- `lastRefillAt` is set to the instant of its OWN first AwardXP call,
-- crediting ZERO prior elapsed time -- an earlier draft of this simulation
-- wrongly assumed a bucket already existed, accruing, from some earlier
-- "time 0" baseline, which overstated every number below; re-simulated and
-- cross-checked directly against tests/progression_spec.lua's own EIGHTH-
-- XP-farm-fix section, which exercises the REAL AwardXP function end to
-- end, not a re-implementation, before landing these final figures):
--
-- CORRECTED (economy audit, 2026-08-26) -- the figures immediately below
-- this note used to read "search 25 + track 10 + bite 20 + takedown 30 +
-- tenure 15+40+100 = 240 starter tokens" and "2.45 hours (2h 27m)" to
-- Elite. Both had gone stale relative to the REAL, currently-shipped
-- config.lua and were re-verified, not taken on the old comment's word:
-- Config.XP.awards alone now sums to 250 (the 240 above predates
-- coopSearchBonus (10), added to Config.XP.awards after this section was
-- first written; a second award of 30 also lived here between that
-- recount and 2026-09-02, when the feature behind it was removed), and
-- the
-- starter-token sum this file's own code below has computed since the
-- "EXTENDED (HANDLER XP pass...)" addition ALSO adds every
-- Config.HandlerXP.awards value (225: handlerCertifyK9 50 + handlerTreatK9
-- 12 + handlerKennelDeploy 8 + handlerPartnershipTenure1Day 15 +
-- handlerPartnershipTenure7Day 40 + handlerPartnershipTenure30Day 100) --
-- 250 + 225 = 475 real starter tokens today, not 240. The CODE was never
-- wrong (the summing loops below always drew from the live Config tables,
-- which is exactly why nothing crashed or silently mis-behaved) -- only
-- THIS COMMENT'S cited numbers were, because they were never revisited
-- when either award table grew. Recomputed by the SAME direct-simulation
-- method as the original figures (round-robining the four REAL K9-mechanic
-- award mint cooldowns for a full simulated run, driving the REAL
-- RefillMintBudget/AwardXP code, not a re-implementation):
-- continuous max-rate round-robin farming across all four mechanics grants
-- 4,075 XP at T=1hr (vs. the four independent per-mechanic ceilings' own
-- UNCAPPED sum of 5,700 XP/hr -- this budget is still the binding
-- constraint), and the 9,000-XP Elite tier is first reached at
-- T=8,550,000ms = 2.375 hours (2h 22.5m) -- still comfortably over the
-- 2-hour floor, with a smaller margin (~22.5 minutes) than the 240-token
-- comment's own ~27 minutes, and smaller still than a pure start-empty
-- design's clean 2.5h would have had. THE FLOOR STILL HOLDS, but the
-- margin shrinks every time either award table grows without anyone
-- re-running this simulation -- see XP_MINT_BUDGET_STARTER_TOKENS_CEILING_XP
-- below for the hard backstop against that margin ever silently reaching
-- zero (or reopening the rejected-attempt-1 burst above) as a consequence
-- of nothing more than ordinary future feature growth.
--
-- NUMBERS CHOSEN (XP_MINT_BUDGET_CAP_XP / XP_MINT_BUDGET_WINDOW_MS below):
-- 3,600 XP per 3,600,000ms (1 hour) -- clean, round numbers to reason about.
-- Needed: comfortably below 4,500 XP/hr (9000 / 4500 = exactly 2.0 hours --
-- the retuned floor requires MORE than 2 hours, so the cap must clear that
-- with real margin, not sit on the boundary), which it does even with the
-- REAL starter offset above (2.375h > 2.0h). Recomputed tier times
-- at this REAL post-fix ceiling, with a 505-token starter (simulated
-- AND test-verified, not a pure-continuous approximation), reported to
-- whoever owns config.lua for that file's own Config.XPTiers economy
-- comment (not edited by this pass):
--   Trained (1,250 XP): reached at 0.233h   (14m)
--   Veteran (4,000 XP): reached at 0.983h   (~59m)
--   Elite   (9,000 XP): reached at 2.375h   (2h 22.5m -- clears the floor)
--
-- THOSE THREE FIGURES WERE SIMULATED AT A 505-TOKEN STARTER, and the real
-- starter is 475 as of 2026-09-02 (an award of 30 left Config.XP.awards
-- when the feature behind it was removed). They are NOT re-simulated
-- here, and they do not need to be: a SMALLER starter balance can only
-- move every one of those times LATER, never earlier, because the starter
-- is a head start on a budget that refills at a fixed rate. So 2.375h is
-- now a lower bound on the real time to Elite rather than the exact
-- figure, and the 2-hour floor clears by MORE margin than it did, not
-- less. Anything that GROWS the starter sum is the direction that needs
-- the simulation re-run -- that is what the ceiling below exists for.
--
-- FILE-LOCAL CONSTANTS, NOT CONFIG KEYS -- same reasoning as every one of
-- the four per-mechanic mint cooldowns' own "FILE-LOCAL CONSTANTS, NOT
-- CONFIG KEYS" comment (server/combat.lua, server/search.lua,
-- server/tracking.lua): this is a security floor, not an operator-tunable
-- balance knob, and a merely-too-low operator-set value would pass every
-- existing validity check while silently reopening the exact farm this
-- exists to close. The only way to weaken it is to edit this file's own
-- source under code review.
-- ==========================================================================
local XP_MINT_BUDGET_CAP_XP    = 3600     -- XP -- the bucket's max capacity (a citizenid can never hold more than this many unspent tokens at once, however long they go without earning)
local XP_MINT_BUDGET_WINDOW_MS = 3600000  -- 1 hour -- the refill PERIOD: a bucket held at 0 reaches full capacity after exactly this many real ms of continuous refill

-- HARD CEILING on the derived starter-token sum below (economy audit,
-- 2026-08-26 -- the same audit that caught the stale 240/2.45h numbers
-- corrected above). Previously the sum of Config.XP.awards +
-- Config.HandlerXP.awards was clamped only to XP_MINT_BUDGET_CAP_XP itself
-- (3,600) -- true today (475 is nowhere near 3,600) but that clamp does
-- nothing to stop the sum CREEPING toward the cap as more awards are added
-- over time, and this section's own "STARTING BALANCE" writeup above
-- already proved what happens as the starter balance approaches the full
-- cap: REJECTED ATTEMPT 1 (start full, tokens = XP_MINT_BUDGET_CAP_XP)
-- simulated to ~1.5h to Elite -- BELOW the 2-hour floor. A starter sum that
-- silently grew large enough, one added award at a time, with nobody
-- re-running the simulation, would eventually reopen that exact rejected
-- outcome even though no single change looked dangerous on its own -- the
-- 240 -> 505 drift already cost ~4.5 minutes of margin (2.45h -> 2.375h)
-- from two awards nobody re-checked this arithmetic for. This ceiling is
-- the backstop: a fixed 25% of XP_MINT_BUDGET_CAP_XP, chosen so the sum can
-- keep growing with future features (475 today has room to nearly
-- double before hitting it) while GUARANTEEING -- independent of how large
-- Config.XP.awards/Config.HandlerXP.awards ever grow -- that continuous
-- max-rate round-robin farming still cannot reach Elite before 2.2667h
-- (2h 16m, ~16 minutes of real margin over the 2-hour floor; re-verified by
-- the same direct-simulation method as every other figure in this section).
-- A future author who blows through this ceiling gets a silent CLAMP, not
-- a silent reopening of a farm this file has already rejected once -- the
-- clamp itself is not a substitute for re-running the simulation when a
-- large new award lands, just a guarantee that forgetting to cannot regress
-- past this specific floor.
local XP_MINT_BUDGET_STARTER_TOKENS_CEILING_XP = 900 -- XP -- 25% of XP_MINT_BUDGET_CAP_XP; see this comment block for the full derivation

-- STARTER TOKENS -- see the "STARTING BALANCE" writeup above for the full
-- reasoning (start-full and start-empty were both tried and rejected first,
-- this pass, before landing here). Sized as the SUM of every configured
-- Config.XP.awards value -- not the largest single one -- specifically to
-- cover server/tenure.lua's documented multi-milestone-in-one-tick case
-- (several one-time, non-repeating awards for the SAME citizenid in the SAME
-- AwardXP-call-adjacent moment), computed once here from the REAL live
-- config rather than hardcoded, so it can never silently drift out of sync
-- if config.lua's award list changes shape later. Clamped to
-- XP_MINT_BUDGET_STARTER_TOKENS_CEILING_XP (NOT the full
-- XP_MINT_BUDGET_CAP_XP -- see that ceiling constant's own declaration
-- comment immediately above for why a much tighter clamp than "never
-- literally exceed the bucket's own capacity" is needed) so a starting
-- balance can never itself violate this bucket's own "never more than CAP
-- tokens at once" invariant AND can never silently erode this section's own
-- >2-hour design floor as future award tables grow (not true of any
-- currently shipped value at either clamp, but this constant is derived,
-- not asserted, so it must clamp itself rather than rely on the assert
-- below alone). Falls back to a safe, small, non-zero default (100) if
-- Config.XP.awards is not yet a usable table at this file's OWN load time
-- -- never 0, since 0 here would silently reintroduce the exact "first
-- award always denied" regression this constant exists to fix, just for
-- the narrower case of a malformed config.
--
-- EXTENDED (HANDLER XP pass, coder-backend) to ALSO sum Config.HandlerXP.
-- awards, for the identical reason: AwardHandlerXP (below) draws on this
-- SAME shared bucket, and server/tenure.lua's own multi-milestone-in-one-
-- tick case pays the handler-role party up to three
-- handlerPartnershipTenure{1,7,30}Day awards in the same tick it pays the
-- K9-role party its own three -- a DIFFERENT citizenid's bucket in the
-- common case (handler and K9 are normally two different characters), but
-- there is nothing structurally preventing one citizenid from holding a
-- handler-role partnership and a K9-role partnership at once, so this
-- constant's own "never silently drift out of sync" promise now covers
-- both tables it is actually spent against, not just one of them. A
-- fixture/spec Config with no Config.HandlerXP table at all (e.g. every
-- existing progression_spec.lua fixture predating this pass) is unaffected
-- -- the guard below simply adds nothing in that case, identical to its
-- pre-existing behavior.
local XP_MINT_BUDGET_STARTER_TOKENS = 100
do
    local sum = 0
    if type(Config.XP) == 'table' and type(Config.XP.awards) == 'table' then
        for _, amount in pairs(Config.XP.awards) do
            if type(amount) == 'number' and amount > 0 then
                sum = sum + amount
            end
        end
    end
    if type(Config.HandlerXP) == 'table' and type(Config.HandlerXP.awards) == 'table' then
        for _, amount in pairs(Config.HandlerXP.awards) do
            if type(amount) == 'number' and amount > 0 then
                sum = sum + amount
            end
        end
    end
    if sum > 0 then
        XP_MINT_BUDGET_STARTER_TOKENS = math.min(sum, XP_MINT_BUDGET_STARTER_TOKENS_CEILING_XP)
    end
end

--- Shared validity test, deliberately mirroring server/cooldowns.lua's own
--- IsValidThreshold (identical rejection list: non-number, NaN, non-
--- positive) -- NOT calling that function directly (this file has no
--- `local` access to it -- it is an internal helper of that file's own two
--- constructors, correctly not exposed as a resource-global), duplicated
--- here rather than newly invented.
--- @param value any
--- @return boolean
local function IsValidBudgetParam(value)
    return type(value) == 'number' and value == value and value > 0
end

--- TEST/INSPECTION SEAM (resource-global, no `local`) -- same precedent and
--- reasoning as server/search.lua's GetContrabandAlertTier: a thin pass-
--- through to a file-local pure function, added specifically so a spec can
--- exercise the exact validity logic this section's fail-OPEN decision is
--- built on with ARBITRARY inputs (0, negative, nil, NaN), not just the two
--- hardcoded constants above -- there is no other way to reach a `local`
--- function's behavior for inputs other than the ones this file's own
--- top-level code happens to call it with (see tests/fixtures/sandbox.lua's
--- own header on this exact limitation). Widens no trust boundary: this
--- performs a plain, side-effect-free math/type check on a number the
--- caller already has, reads no player/citizenid/XP state, and cannot be
--- used to influence or observe any real award.
--- @param value any
--- @return boolean
function IsValidXpMintBudgetParam(value)
    return IsValidBudgetParam(value)
end

-- CRITICAL DESIGN CHOICE, READ BEFORE EVER CHANGING EITHER CONSTANT ABOVE:
-- FAIL OPEN HERE, DELIBERATELY -- THE OPPOSITE DIRECTION FROM
-- server/cooldowns.lua's OWN IsOnCooldown, AND FROM EVERY PER-MECHANIC MINT
-- COOLDOWN ABOVE.
--
-- server/cooldowns.lua's own header documents the non-positive-cooldown
-- footgun at length: a non-positive threshold there silently means
-- "permanently blocked," never "no cooldown," and that fail-CLOSED choice is
-- the RIGHT one for a single-mechanic cooldown, because the blast radius of
-- getting it wrong is contained -- one action, for players who happen to
-- touch that one mechanic, recoverable by a targeted fix. THIS budget is
-- different in kind, not just degree: it is consulted by EVERY AwardXP
-- call, for EVERY actionKey, for EVERY citizenid, resource-wide --
-- server/search.lua, server/tracking.lua, server/combat.lua,
-- server/tenure.lua's partnership milestones, and any future caller.
-- Reusing cooldowns.lua's fail-closed convention here would mean a single
-- bad constant (a future edit that typos XP_MINT_BUDGET_WINDOW_MS to 0, or
-- a future refactor that starts reading either constant from Config without
-- re-deriving the same validation GetValidatedXPTiers/ValidateXPAwardAmount
-- below already apply to Config.XPTiers/Config.XP.awards) could silently and
-- PERMANENTLY block ALL XP progression for the ENTIRE server, forever, until
-- a restart -- a far larger and far less visible outcome than this one
-- security floor going
-- temporarily unenforced while the four independent per-mechanic mint
-- cooldowns above (unaffected by this flag either way) keep doing their own
-- job. Explicit, not accidental: when either constant fails validation,
-- this budget is DISABLED (never denies, never mutates XPMintBudget, never
-- touches the timer at all) and says so loudly exactly once, rather than
-- silently doing either extreme.
local XPMintBudgetEnabled = IsValidBudgetParam(XP_MINT_BUDGET_CAP_XP) and IsValidBudgetParam(XP_MINT_BUDGET_WINDOW_MS)
if not XPMintBudgetEnabled then
    print(
        ('[John-K9] progression: XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS are invalid ' ..
         '(capXp=%s, windowMs=%s) -- the SHARED cross-mechanic XP mint budget is DISABLED for this ' ..
         'entire session (fail OPEN, deliberately -- see this file\'s own comment on XPMintBudgetEnabled ' ..
         'for why this is the opposite of server/cooldowns.lua\'s usual fail-closed convention). The four ' ..
         'independent per-mechanic mint cooldowns (server/combat.lua, server/search.lua, ' ..
         'server/tracking.lua) are UNAFFECTED and keep enforcing their own limits regardless. Fix these ' ..
         'two constants in server/progression.lua.'):format(tostring(XP_MINT_BUDGET_CAP_XP), tostring(XP_MINT_BUDGET_WINDOW_MS))
    )
end

-- Deliberately NOT also exposing a read-only status/enabled accessor here as
-- a second test seam -- tests/progression_spec.lua's own EIGHTH-XP-farm-fix
-- compound-farm test already proves the REAL shipped constants are valid
-- and enabled, more precisely than a boolean flag could: it asserts the
-- EXACT total (3,600 XP after one simulated hour of round-robined real
-- awards, 9,000 XP after 2.5) that is only reachable at all if
-- XPMintBudgetEnabled is true AND both constants are exactly what they
-- claim to be. A second global purely for this would be redundant surface
-- for no extra coverage.

-- XPMintBudget[citizenid] = { tokens = number, lastRefillAt = gameTimerMs }.
-- DELIBERATELY NOT cleared on playerDropped (unlike K9XP/AwardXPCooldown
-- below -- see the playerDropped handler's own comment near the bottom of
-- this file for the full reasoning): clearing this on disconnect would let
-- a farmer reset their own budget early simply by reconnecting, defeating
-- the entire point of this section. Bounded instead by the periodic sweep
-- below, which only ever evicts an entry once it would already have
-- refilled to full capacity anyway -- behaviorally identical to leaving it
-- in place, just reclaiming memory for a citizenid that has been inactive
-- for a full window.
local XPMintBudget = {}

--- Refills `bucket` in place for the elapsed time since its own last
--- refill, capped at XP_MINT_BUDGET_CAP_XP (a token bucket's capacity is
--- also its max burst allowance -- see this section's header for why that
--- is fine here). `now` is a single GetGameTimer() value the caller already
--- captured, never re-read here, mirroring server/cooldowns.lua's own
--- IsOnCooldown `now` parameter convention.
---
--- GetGameTimer() WRAPAROUND CAVEAT (same disclosed, not-fixed-here issue as
--- server/cooldowns.lua's own IsOnCooldown -- see that file's header for the
--- full writeup): if `elapsed` reads negative (the ~24.85-day int32 wrap),
--- this function does nothing rather than let a negative elapsed *
--- refillRate corrupt `tokens` -- the safe direction here is "skip this
--- refill," not "guess," since briefly under-refilling is recoverable and
--- over-refilling is not (it would hand out budget that was never earned).
--- @param bucket table
--- @param now number
local function RefillMintBudget(bucket, now)
    local elapsed = now - bucket.lastRefillAt
    if elapsed <= 0 then return end
    local refillRate = XP_MINT_BUDGET_CAP_XP / XP_MINT_BUDGET_WINDOW_MS -- XP per ms
    bucket.tokens = math.min(XP_MINT_BUDGET_CAP_XP, bucket.tokens + elapsed * refillRate)
    bucket.lastRefillAt = now
end

-- Bounds XPMintBudget's memory growth WITHOUT resetting any citizenid's
-- remaining budget EARLY (see XPMintBudget's own declaration comment above
-- for why playerDropped cannot be used here the way K9XP/AwardXPCooldown
-- use it). An entry is only ever dropped once `now - lastRefillAt >=
-- XP_MINT_BUDGET_WINDOW_MS` -- the exact point at which RefillMintBudget
-- would have clamped it back to a FULL bucket had anyone looked. Dropping it
-- here and letting AwardXP recreate a fresh bucket at
-- XP_MINT_BUDGET_STARTER_TOKENS (see AwardXP's own comment on why a new/
-- recreated bucket starts there, not at 0 and not at capacity) on that
-- citizenid's next award is therefore CONSERVATIVE, not exactly identical to
-- leaving the old (by then full) entry in place -- a citizenid who returns
-- right after this sweep evicted them starts back at the small starter
-- allowance instead of resuming from a full bucket. That is always the SAFE
-- direction (strictly less budget available than an always-resident
-- implementation would have had, never more), and never actually reachable
-- by a genuinely legitimate player (see AwardXP's own comment: real play
-- never gets remotely close to a full bucket in the first place), so it
-- costs nothing in practice while keeping this sweep's own logic simple.
-- Sweep interval (5 minutes) is well under the window (1 hour) so no entry lingers
-- long past the point it became safe to drop; not built on
-- server/cooldowns.lua's own :StartSweep helper since this tracker's shape
-- (tokens + lastRefillAt, not a single timestamp) does not fit that
-- constructor's isStaleFn(now, loggedAt) signature. Only started when the
-- budget itself is enabled -- when disabled, XPMintBudget is never written
-- to at all, so a sweep thread would just be an empty no-op loop forever.
if XPMintBudgetEnabled then
    CreateThread(function()
        while true do
            Wait(300000)
            local now = GetGameTimer()
            for citizenid, bucket in pairs(XPMintBudget) do
                if (now - bucket.lastRefillAt) >= XP_MINT_BUDGET_WINDOW_MS then
                    XPMintBudget[citizenid] = nil
                end
            end
        end
    end)
end

-- Config.XP.awards' own value-range validation -- CLAMP AND WARN, same
-- shape as ValidateHandlerAwardAmount below (Config.HandlerXP.awards'
-- identical guard) -- this REPLACES what used to be a pair of bare
-- per-actionKey `assert`s inside an onResourceStart handler here. Every
-- value in Config.XP.awards is documented in config.lua as a "pure balance
-- placeholder -- tune freely" -- exactly the plausible-owner-typo class
-- this codebase has already been bitten by twice (this file's own header
-- names the ambient-audio incident; a handler-rank assert was removed
-- elsewhere in this same pass). The old asserts' own comment argued
-- Config.Features.XPProgression shipping `true` by default made a bare
-- assert "correct" here, unlike Config.HandlerXP.awards -- that reasoning
-- does not survive a closer look: nothing else was ever registered in that
-- onResourceStart handler either, so the assert bought no sibling-
-- registration protection, while still being able to abort resource start
-- outright over one placeholder value an owner is explicitly invited to
-- tune. Warns AT MOST ONCE per actionKey per resource lifetime, checked
-- lazily inside AwardXP itself rather than eagerly at boot -- see
-- ValidateHandlerAwardAmount's own header for the fuller "why clamp-and-
-- warn, not assert" writeup this mirrors.
local XPAwardAmountWarned = {} -- actionKey -> true

--- @param actionKey string
--- @param amount number -- already confirmed `type(amount) == 'number'` by the caller
--- @return number? validAmount -- `amount` unchanged if it passes, nil if it does not (caller then treats this exactly like any other unpayable award: a silent no-op)
local function ValidateXPAwardAmount(actionKey, amount)
    if amount >= 0 and (not XPMintBudgetEnabled or amount <= XP_MINT_BUDGET_CAP_XP) then
        return amount
    end
    if not XPAwardAmountWarned[actionKey] then
        XPAwardAmountWarned[actionKey] = true
        if amount < 0 then
            -- The real risk a negative amount creates: AwardXP's own
            -- XPMintBudget block only ever runs `if ... and amount > 0`
            -- (see that function's own comment on this exact guard), so a
            -- negative amount skips the shared budget ENTIRELY -- it does
            -- not "spend" it, positive or negative -- and falls straight
            -- through to `K9XP[citizenid] = oldXp + amount`, silently
            -- SUBTRACTING XP directly from that citizenid's own persisted
            -- total, completely bypassing the mint-budget mechanism this
            -- section exists to enforce.
            print(('[John-K9] progression: Config.XP.awards.%s (%s XP) must not be negative -- a negative amount would bypass the shared XP mint budget entirely (it is only ever consulted for amount > 0) and instead subtract directly from the citizenid\'s own persisted XP total. Treating this actionKey as unpayable rather than risking that. Fix this value in config.lua.'):format(actionKey, tostring(amount)))
        else
            print(('[John-K9] progression: Config.XP.awards.%s (%s XP) exceeds XP_MINT_BUDGET_CAP_XP (%d XP) -- this award could never be paid, for any citizenid, ever, regardless of how long they wait. Treating this actionKey as unpayable rather than crashing. Fix this value in config.lua, or raise XP_MINT_BUDGET_CAP_XP (server/progression.lua).'):format(actionKey, tostring(amount), XP_MINT_BUDGET_CAP_XP))
        end
    end
    return nil
end

-- CONFIG-SAFETY GUARD (config audit finding, this pass — same precedent as
-- server/inventory.lua's `Config.K9Inventory.accessScope` assert and
-- server/main.lua's `nudgeRequiresUnlocked` assert). This file's own header
-- SCOPING section, config.lua's own comment on this field, and README.md's
-- `Config.Features.XPProgression` section all already document that only
-- `'citizenid'` is implemented — but until now nothing ever READ the value
-- to enforce that, so a server owner who set `'job'` (a documented, but
-- explicitly NOT-YET-built, alternative — DEVELOPER_REFERENCE.md §13.6 item 2) got
-- silently citizenid-scoped behaviour with no warning at all: every award
-- and lookup in this file goes straight through K9XP[citizenid] and the
-- `k9_progression` table's plain `citizenid` key, never once branching on
-- this config field.
--
-- This is NOT a "feature merely unimplemented, pick the other value and
-- wait" situation the way an inert placeholder would be — `k9_progression`
-- (sql/install.sql) has a plain `VARCHAR(50) citizenid` PRIMARY KEY and NO
-- job column at all. 'job' scoping would need a composite (citizenid, job)
-- key instead (mirroring `k9_certifications`), which is a SCHEMA change,
-- not a config choice this file could honor today even if it tried to
-- switch on the value — the current schema cannot express per-job XP
-- totals at all. Failing loudly at resource start, rather than letting a
-- misconfigured value silently produce behaviour the operator did not
-- choose, matches the established precedent above.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    assert(
        Config.XP.scopePerCitizenidOrJob == 'citizenid',
        "[John-K9] Config.XP.scopePerCitizenidOrJob must be 'citizenid' -- " ..
        "'job' is a documented-but-unimplemented alternative (DEVELOPER_REFERENCE.md §13.6 item 2), " ..
        'not a selectable config choice this file can honor: the `k9_progression` table ' ..
        '(sql/install.sql) has a plain `citizenid` PRIMARY KEY and no job column at all, so ' ..
        "job-scoped XP totals cannot even be persisted under the current schema, let alone " ..
        'read/written correctly by this file, which unconditionally keys every K9XP cache ' ..
        'entry and every k9_progression query by citizenid alone. Setting this to anything ' ..
        "other than 'citizenid' would silently keep citizenid-scoped behaviour with no " ..
        'warning, misleading an operator who believes they configured job-scoped progression.'
    )

end)

-- TIER-SHAPE GUARD (audit finding, an earlier pass). ResolveTier/GetXPTier's
-- own doc comments both promise "always returns a real Config.XPTiers
-- entry, never nil" -- but nothing ever checked that promise against the
-- config's actual shape; it has only ever been true because Config.XPTiers
-- (config.lua, still marked "placeholder numbers pending economy-balance-
-- agent review") happens to already be well-formed today. ResolveTier's own
-- walk (`for _, tier in ipairs(...) do if xp >= tier.xp then resolvedTier =
-- tier end end`, no `break`) has two load-bearing assumptions this guard
-- verifies rather than silently trusting:
--   1. Config.XPTiers is non-empty AND its first entry's `xp` is exactly 0.
--      If either fails, `Config.XPTiers[1]` (ResolveTier's pre-loop
--      default) is either nil (an EMPTY table) or a non-zero floor (some
--      xp > 0 could then resolve to no tier if the loop body somehow still
--      ran zero times, and more importantly a brand-new citizenid at 0 XP
--      would incorrectly inherit whatever that first entry's
--      speedMultiplier/scentRangeMultiplier is, rather than the neutral 1.0
--      baseline every other file in this resource assumes "unknown
--      citizenid" means).
--   2. Every `xp` threshold is a number, in STRICTLY ASCENDING order.
--      ResolveTier never `break`s early -- it keeps overwriting
--      `resolvedTier` with EVERY entry whose `xp` the current total already
--      clears, in ARRAY order, not threshold order. That is only equivalent
--      to "the tier with the highest threshold not exceeding xp" (the
--      intended, documented semantics) if the array is sorted ascending by
--      `xp` -- exactly the same caller-maintained-order contract
--      Config.ContrabandAlertTiers and server/tenure.lua's own milestone
--      walk already require and document for the identical reason. An
--      out-of-order or non-numeric entry would not crash this loop, but
--      would silently resolve some XP totals to the WRONG tier -- directly
--      changing a K9's real movement speed and scent range, this file's
--      header's own definition of a "live gameplay effect," with no error
--      or log line anywhere to reveal it.
--
-- CLAMP AND WARN, DELIBERATELY NEVER THROW -- this used to be a bare
-- `assert` (three of them, plus a per-tier loop) inside the
-- `onResourceStart` handler directly above. Removed, not merely softened,
-- for a sharper reason than the usual "one bad value kills every sibling
-- registration in this handler": THIS PARTICULAR ASSERT PROTECTED NOTHING.
-- Nothing else was ever registered below it in that handler, and — the part
-- that actually matters — ResolveTier below reads `Config.XPTiers` (now
-- `GetValidatedXPTiers()`) directly, on every call, completely independent
-- of whether this onResourceStart handler ever ran to completion. Whether
-- the assert fired or not, a malformed Config.XPTiers table would reach
-- ResolveTier's own walk exactly the same either way — the old assert's own
-- comment even said so ("a malformed Config.XPTiers should block startup,
-- not quietly hand out wrong-tier gameplay effects"), but throwing here
-- never actually stopped that from happening; it only turned a recoverable
-- misconfiguration into a scarier, less informative stack trace for an
-- owner config.lua itself calls "placeholder numbers pending
-- economy-balance-agent review" -- i.e. explicitly invites tuning of. This
-- is now the SAME lazy, memoized clamp-and-warn shape as
-- GetValidatedHandlerXPTiers below (that function's own header used to
-- single this guard out as the one deliberate exception to its shape --
-- updated alongside this change) -- computed on ResolveTier's own first
-- call, warned at most ONCE per resource lifetime, never registered against
-- `onResourceStart` at all.
local FALLBACK_XP_TIERS = {
    -- Same neutral 1.0/1.0 baseline as config.lua's own real base tier
    -- ('Recruit K9') -- a K9 stuck on this fallback forever is exactly as
    -- safe as one correctly resolved to the real base tier: neither ever
    -- grants a bonus beyond "no bonus at all". Never a security-relevant
    -- fail-open (matches GetXPTier's own doc comment: "can only ever
    -- under-grant, never over-grant").
    { xp = 0, label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
}

local ValidatedXPTiers -- memoized result of GetValidatedXPTiers below
local XPTiersWarned = false

--- Prints the "K9 XP tiers are unavailable" warning at most ONCE per
--- resource lifetime, no matter how many times GetValidatedXPTiers below is
--- called against a broken config.
--- @param reason string -- what specifically is wrong with Config.XPTiers, appended to a fixed prefix
local function WarnXPTiersOnce(reason)
    if XPTiersWarned then return end
    XPTiersWarned = true
    print(
        ('[John-K9] progression: Config.XPTiers %s -- every citizenid resolves to the single ' ..
         'built-in base tier, \'Recruit K9\' (speedMultiplier/scentRangeMultiplier = 1.00, no bonus ' ..
         "effect), for this session. This does NOT affect AwardXP's own ability to accumulate and " ..
         'persist xp -- only the LADDER used to describe standing/effects is unavailable; every ' ..
         'already-earned xp total is untouched and will resolve correctly again the moment this table ' ..
         'is fixed. Fix Config.XPTiers in config.lua (a non-empty array, ascending by xp, first entry ' ..
         'xp = 0, every entry a table with numeric xp/speedMultiplier/scentRangeMultiplier) to restore ' ..
         'it.'):format(reason)
    )
end

--- @return table tiers -- either the real, validated Config.XPTiers, or FALLBACK_XP_TIERS
local function GetValidatedXPTiers()
    if ValidatedXPTiers then return ValidatedXPTiers end

    local tiers = Config.XPTiers
    if type(tiers) ~= 'table' or #tiers == 0 then
        WarnXPTiersOnce('is missing, not a table, or empty')
        ValidatedXPTiers = FALLBACK_XP_TIERS
        return ValidatedXPTiers
    end
    if type(tiers[1]) ~= 'table' or type(tiers[1].xp) ~= 'number' or tiers[1].xp ~= 0 then
        WarnXPTiersOnce(('[1].xp must be exactly 0 (found: %s)'):format(tostring(tiers[1] and tiers[1].xp)))
        ValidatedXPTiers = FALLBACK_XP_TIERS
        return ValidatedXPTiers
    end
    for i = 1, #tiers do
        local tier = tiers[i]
        if type(tier) ~= 'table' or type(tier.xp) ~= 'number'
            or type(tier.speedMultiplier) ~= 'number' or type(tier.scentRangeMultiplier) ~= 'number' then
            WarnXPTiersOnce(('[%d] must be a table with numeric xp/speedMultiplier/scentRangeMultiplier fields'):format(i))
            ValidatedXPTiers = FALLBACK_XP_TIERS
            return ValidatedXPTiers
        end
        if i > 1 and tier.xp <= tiers[i - 1].xp then
            WarnXPTiersOnce(('must be strictly ascending by xp -- entry %d (xp=%s) does not exceed entry %d (xp=%s)'):format(i, tostring(tier.xp), i - 1, tostring(tiers[i - 1].xp)))
            ValidatedXPTiers = FALLBACK_XP_TIERS
            return ValidatedXPTiers
        end
    end

    ValidatedXPTiers = tiers
    return ValidatedXPTiers
end

--- Resolves `xp` to the matching entry in the VALIDATED Config.XPTiers (see
--- GetValidatedXPTiers above -- never the raw config table directly).
--- Identical walk shape to server/search.lua's ResolveAlertTier --
--- GetValidatedXPTiers()[1] is the mandatory `xp = 0` baseline (same role
--- Config.ContrabandAlertTiers' `minWeight = 0` baseline plays there), so
--- this never returns nil. Returns the SAME table object (by reference) for
--- every xp value that falls in one tier's bracket, which AwardXP below
--- relies on to detect a tier crossing via plain `~=` comparison rather
--- than a deep-equality check.
--- @param xp number
--- @return table tier -- { xp, label, speedMultiplier, scentRangeMultiplier }
local function ResolveTier(xp)
    local tiers = GetValidatedXPTiers()
    local resolvedTier = tiers[1]
    for _, tier in ipairs(tiers) do
        if xp >= tier.xp then
            resolvedTier = tier
        end
    end
    return resolvedTier
end

--- Resource-global — see FILE-TO-FILE CONTRACT above. Always returns a real
--- Config.XPTiers entry, defaulting to the base tier for an uncached
--- citizenid (never nil, never a security-relevant fail-open — the base
--- tier grants the SMALLEST scentRangeMultiplier/speedMultiplier in the table, so an
--- unresolved cache entry can only ever under-grant, never over-grant).
--- @param citizenid string
--- @return table tier
function GetXPTier(citizenid)
    return ResolveTier(K9XP[citizenid] or 0)
end

--- Resource-global — see FILE-TO-FILE CONTRACT above.
--- @param citizenid string
--- @return number
function GetXP(citizenid)
    return K9XP[citizenid] or 0
end

-- ==========================================================================
-- HANDLER XP (Config.Features.HandlerXPProgression) -- the handler-facing
-- twin of the K9-facing block immediately above. See config.lua's own
-- Config.HandlerXPTiers/Config.HandlerXP headers for the full "why a
-- SECOND accumulated total, on the SAME k9_progression row, not a second
-- reading of the K9's own `xp`" design -- not re-litigated here.
--
-- HandlerXP[citizenid] = number (accumulated handler total). Local, same
-- "nothing outside this file should read/write it directly" rule as K9XP
-- above -- always go through AwardHandlerXP/GetHandlerXPTier.
-- ==========================================================================
local HandlerXP = {}

-- FALLBACK LADDER, used only when Config.HandlerXPTiers turns out to be
-- missing or malformed (see GetValidatedHandlerXPTiers below) -- a single
-- base-tier entry, the same "unknown state defaults to least privilege"
-- baseline every other tier fallback in this file already uses. Safe as a
-- PERMANENT fallback, not just a momentary one: every one of
-- Config.HandlerXPTiers' own effect fields is OPTIONAL and only ever
-- SHORTENS a cooldown or LENGTHENS a distance (config.lua's own header --
-- never grants access), so a citizenid stuck on this fallback forever is
-- exactly as safe as one correctly resolved to 'Rookie Handler' -- neither
-- ever unlocks anything beyond the base tier's own (absence of) effects.
local FALLBACK_HANDLER_XP_TIERS = { { xp = 0, label = 'Rookie Handler' } }

local ValidatedHandlerXPTiers -- memoized result of GetValidatedHandlerXPTiers below
local HandlerXPTiersWarned = false

--- Prints the "handler ranks are unavailable" warning at most ONCE per
--- resource lifetime, no matter how many times GetValidatedHandlerXPTiers
--- below is called against a broken config.
--- @param reason string -- what specifically is wrong with Config.HandlerXPTiers, appended to a fixed prefix
local function WarnHandlerXPTiersOnce(reason)
    if HandlerXPTiersWarned then return end
    HandlerXPTiersWarned = true
    print(
        ('[John-K9] progression: Config.HandlerXPTiers %s -- handler ranks are UNAVAILABLE for this ' ..
         'session (GetHandlerXPTier will resolve every citizenid to the single built-in base tier, ' ..
         "'Rookie Handler', with no bonus effect fields). This does NOT affect AwardHandlerXP's own " ..
         'ability to accumulate and persist handler_xp -- only the LADDER used to describe standing is ' ..
         'unavailable; every already-earned handler_xp total is untouched and will resolve correctly ' ..
         'again the moment this table is fixed. Fix Config.HandlerXPTiers in config.lua (a non-empty ' ..
         'array, ascending by xp, first entry xp = 0) to restore it.'):format(reason)
    )
end

--- CLAMP AND WARN, DELIBERATELY NEVER THROW -- mirrors the established
--- precedent in server/cooldowns.lua's own ResolveConfiguredThresholdMs
--- (read that function's header for the full "why clamp-and-warn, not
--- assert" reasoning this mirrors). SAME SHAPE as GetValidatedXPTiers above
--- (Config.XPTiers' own identical guard) -- an earlier pass here argued this
--- function was DELIBERATELY the odd one out because Config.XPTiers backs a
--- flag that ships `true` by default and is load-bearing, so "a malformed
--- table there is a genuine, always-relevant operator bug worth stopping
--- the boot over." That argument did not survive a closer look: nothing was
--- ever registered below that assert in its own onResourceStart handler,
--- and ResolveTier read the same raw, unvalidated Config.XPTiers on every
--- call regardless of whether the assert fired -- so the assert protected
--- nothing, it only turned a recoverable misconfiguration into a scarier
--- stack trace. See GetValidatedXPTiers' own header for the full account of
--- why that guard was converted to this exact shape. A bare `assert` INSIDE
--- an `onResourceStart` handler aborts that ENTIRE handler function the
--- instant it fires, silently skipping every line still to run below the
--- throw, for the rest of this resource's uptime -- exactly the "one bad
--- config value silently deletes an unrelated feature" incident class this
--- codebase has already found and fixed once (see commit "Stop one bad
--- config value silently deleting the ambient audio feature"). Computed
--- lazily, on ResolveHandlerTier's own first call -- not registered against
--- `onResourceStart` at all, so there is no handler here that could ever
--- abort anything else.
--- @return table tiers -- either the real, validated Config.HandlerXPTiers, or FALLBACK_HANDLER_XP_TIERS
local function GetValidatedHandlerXPTiers()
    if ValidatedHandlerXPTiers then return ValidatedHandlerXPTiers end

    local tiers = Config.HandlerXPTiers
    if type(tiers) ~= 'table' or #tiers == 0 then
        WarnHandlerXPTiersOnce('is missing, not a table, or empty')
        ValidatedHandlerXPTiers = FALLBACK_HANDLER_XP_TIERS
        return ValidatedHandlerXPTiers
    end
    if type(tiers[1]) ~= 'table' or type(tiers[1].xp) ~= 'number' or tiers[1].xp ~= 0 then
        WarnHandlerXPTiersOnce(('[1].xp must be exactly 0 (found: %s)'):format(tostring(tiers[1] and tiers[1].xp)))
        ValidatedHandlerXPTiers = FALLBACK_HANDLER_XP_TIERS
        return ValidatedHandlerXPTiers
    end
    for i = 1, #tiers do
        local tier = tiers[i]
        if type(tier) ~= 'table' or type(tier.xp) ~= 'number' then
            WarnHandlerXPTiersOnce(('[%d] must be a table with a numeric xp field'):format(i))
            ValidatedHandlerXPTiers = FALLBACK_HANDLER_XP_TIERS
            return ValidatedHandlerXPTiers
        end
        if i > 1 and tier.xp <= tiers[i - 1].xp then
            WarnHandlerXPTiersOnce(('must be strictly ascending by xp -- entry %d (xp=%s) does not exceed entry %d (xp=%s)'):format(i, tostring(tier.xp), i - 1, tostring(tiers[i - 1].xp)))
            ValidatedHandlerXPTiers = FALLBACK_HANDLER_XP_TIERS
            return ValidatedHandlerXPTiers
        end
    end

    ValidatedHandlerXPTiers = tiers
    return ValidatedHandlerXPTiers
end

--- Resolves `xp` to the matching entry in the VALIDATED Config.HandlerXPTiers
--- (GetValidatedHandlerXPTiers above -- never the raw config table directly).
--- Identical walk shape to ResolveTier above -- kept as its own, separate
--- function rather than a parameterized ResolveTier(xp, tiers) because the
--- two tier tables are genuinely independent axes (a citizenid's K9-role
--- standing and handler-role standing never share a walk, per config.lua's
--- own "why a second ladder" reasoning), and collapsing them into one
--- shared helper would invite a future edit to accidentally thread a K9-XP
--- value through the handler ladder, or vice versa.
--- @param xp number
--- @return table tier -- { xp, label, ...optional bonus multiplier fields }
local function ResolveHandlerTier(xp)
    local tiers = GetValidatedHandlerXPTiers()
    local resolvedTier = tiers[1]
    for _, tier in ipairs(tiers) do
        if xp >= tier.xp then
            resolvedTier = tier
        end
    end
    return resolvedTier
end

--- Resource-global. Always returns a real Config.HandlerXPTiers entry,
--- defaulting to the base tier ('Rookie Handler', config.lua) for an
--- uncached citizenid -- never nil, same fail-safe posture as GetXPTier
--- above. Unlike GetXPTierMedkitCooldownMs's own individual-override
--- composition, this returns the PLAIN tier value -- no per-INDIVIDUAL-K9
--- override layer exists for the handler ladder (server/k9profiles.lua's
--- own override rows are about an individual K9's ped/mechanics, not a
--- human handler's own standing).
--- @param citizenid string
--- @return table tier
function GetHandlerXPTier(citizenid)
    return ResolveHandlerTier(HandlerXP[citizenid] or 0)
end

--- Resource-global -- the handler-side twin of GetXP above, added this pass
--- because the tablet needed a handler's accumulated TOTAL and there was no
--- way to ask for one. GetHandlerXPTier existed and returns a tier object
--- whose own `xp` field is that tier's THRESHOLD, not the handler's running
--- total, so it could not answer "how far into this rank am I" or "how much
--- until the next one" -- the two things a progression screen is for.
---
--- Same 0-not-nil contract as GetXP: an unknown or uncached citizenid reads
--- as 0, which is also the genuine starting total, so callers never have to
--- distinguish the two here. The one place that distinction DOES matter is
--- the tablet payload, and it draws it from whether the FEATURE is on
--- (server/tablet.lua's ResolveHandlerXpAndTierLabel returns nil when the
--- ladder is switched off) rather than from this value.
--- @param citizenid string
--- @return number
function GetHandlerXP(citizenid)
    return HandlerXP[citizenid] or 0
end

-- ======================================================================
-- LADDERS FOR DISPLAY (owner-directed progression pass) --
-- server/tablet.lua's Progression screen needs the shape of each ladder to
-- answer "what is my next rank, and how far away is it". Both validated
-- ladder builders are file-local here and stay that way; these two return
-- a DISPLAY-SAFE COPY instead of exposing them.
--
-- LABEL AND THRESHOLD ONLY, DELIBERATELY. A tier row also carries
-- speedMultiplier / scentRangeMultiplier / medkitCooldownMultiplier and the
-- handler equivalents -- internal tuning the player has no use for, and
-- which would quietly publish how a server has tuned its own K9s to anyone
-- who opens a tablet. A progression screen needs to know that Veteran
-- starts at 3000 XP; it does not need to know what Veteran does to a move
-- rate. Narrow on purpose, not an oversight to "complete" later.
--
-- Sorted ascending by threshold so a caller can walk it in rank order
-- without re-sorting, and returned as a fresh table every call so a
-- consumer mutating what it got back cannot corrupt the validated ladder.
-- ======================================================================

--- @param tiers table -- a validated ladder
--- @return table -- array of { xp = number, label = string }, ascending
local function LadderForDisplay(tiers)
    local out = {}
    for _, tier in ipairs(tiers or {}) do
        if type(tier) == 'table' and type(tier.xp) == 'number' and type(tier.label) == 'string' then
            out[#out + 1] = { xp = tier.xp, label = tier.label }
        end
    end
    table.sort(out, function(a, b) return a.xp < b.xp end)
    return out
end

--- Resource-global. Empty array (never nil) when the ladder is switched
--- off, so a caller never has to nil-check before iterating -- "off" and
--- "on but empty" render identically and correctly as "no ranks to show".
--- @return table
function GetXPLadderForDisplay()
    if not (Config.Features and Config.Features.XPProgression == true) then return {} end
    return LadderForDisplay(GetValidatedXPTiers())
end

--- Resource-global. Handler-side twin of the above, on its own independent
--- feature switch -- see GetHandlerXP's own comment for why these two
--- ladders are never resolved through one shared flag check.
--- @return table
function GetHandlerXPLadderForDisplay()
    if not (Config.Features and Config.Features.HandlerXPProgression == true) then return {} end
    return LadderForDisplay(GetValidatedHandlerXPTiers())
end

-- ======================================================================
-- HANDLER XP TIER UNLOCKS -- the two of Config.HandlerXPTiers' three effect
-- fields actually wired to a live consumer this pass (dead-config-field
-- audit, coder-backend). See config.lua's own Config.HandlerXPTiers header
-- for why the third (leashRangeMultiplier) was pulled instead of wired.
--
-- BOTH FUNCTIONS BELOW MIRROR GetXPTierMedkitCooldownMs's OWN SHAPE
-- EXACTLY, on purpose: same defensive-bounds contract (a multiplier that
-- is missing, non-numeric, NaN, <= 0, or > 1 returns baseCooldownMs
-- UNCHANGED -- this is an UNLOCK, only ever a reduction, never a way to
-- lengthen a cooldown or hand server/cooldowns.lua a non-positive
-- threshold, which that file's own header documents as PERMANENTLY ON),
-- same "consulted only after an existing gate has already allowed the
-- action, never a gate itself" posture, same 1ms floor
-- (math.max(1, math.floor(...))). NO per-individual-K9 override
-- composition here (unlike GetXPTierMedkitCooldownMs's own
-- GetK9EffectiveMultipliers layer) -- see GetHandlerXPTier's own doc
-- comment immediately above for why no such layer exists for the handler
-- ladder.
--
-- FEEDBACK-LOOP SAFETY, WORKED OUT BEFORE WIRING EITHER (owner-directed;
-- flagged because both cooldowns these unlock also gate an action that
-- Config.HandlerXP.awards prices -- handlerTreatK9 for medkit,
-- handlerKennelDeploy for kennel deploy -- so a rank that shortens either
-- cooldown could, in principle, make the ladder faster to climb the
-- higher you climb it):
--
--   NO LOOP EXISTS TODAY. AwardHandlerXP is called from NOWHERE for either
--   handlerTreatK9 or handlerKennelDeploy -- config.lua's own
--   Config.Features.HandlerXPProgression header documents this in detail
--   (verified by grep before writing this note, not assumed) and gives the
--   exact reason: neither server/medkit.lua's MedkitCooldown nor
--   server/kennel.lua's DeployCooldown is a per-actor XP MINT throttle --
--   MedkitCooldown is keyed by the TARGET K9's citizenid, not the treating
--   handler's, and DeployCooldown throttles the DEPLOY ACTION, not a mint
--   -- so awarding through either today, unthrottled, would be unsafe (that
--   header's own arithmetic: handlerKennelDeploy alone would mint
--   5,760 XP/hr uncapped gross at the default 5000ms deployCooldownMs,
--   enough to exhaust the entire shared 3,600 XP/hr mint budget in under
--   40 minutes solo). Both awards are therefore left UNWIRED, exactly like
--   the pre-fix state server/certifications/'s own CertifyXpMintCooldown
--   comment describes for handlerCertifyK9's old self-cert/decertify loop.
--   With neither award ever actually paid, shortening the ACTION cooldown
--   these two functions unlock cannot shorten any XP-MINTING cadence,
--   because there is no minting cadence riding on either cooldown yet.
--
--   THE NUMBERS, RE-DERIVED FROM THE REAL SHIPPED CONSTANTS SO NOBODY HAS
--   TO GUESS THEM LATER (coordinator-directed addition -- an economy audit
--   the same day this landed measured handlerCertifyK9, an award believed
--   safe because it rode an existing action cooldown, reaching the hourly
--   mint cap in 33 seconds once someone actually did the arithmetic; the
--   fix here is to leave that arithmetic sitting right next to the risk,
--   not in a report nobody rereads before wiring the award):
--     * MEDKIT: Config.K9Medkit.cooldownMs ships at 60000ms. A Master
--       Handler (medkitTreatCooldownMultiplier = 0.50, RETUNED from 0.70 by
--       the XP-rebalance pass) alone shortens that to 30000ms via
--       GetHandlerXPTierMedkitCooldownMs below. STACKED with the TARGET
--       K9's own medkitCooldownMultiplier (Config.XPTiers,
--       GetXPTierMedkitCooldownMs) -- both apply to the SAME MedkitCooldown
--       threshold, server/medkit.lua composes them in sequence -- the real
--       worst-case floor is 60000 * 0.60 * 0.50 = 18000ms (18s) against an
--       ELITE-tier K9, or 22500ms against a Veteran (0.75). NOTE THE ELITE
--       FIGURE IS NEW: before the rebalance, Elite carried NO
--       medkitCooldownMultiplier at all and Veteran's 0.75 was the deepest
--       target-side reduction in existence, which is why this note
--       previously cited 31500ms as the floor. AT TODAY'S FLOOR, IF
--       handlerTreatK9 (12 XP) WERE PAID ON EVERY SUCCESS: 12 XP / 18s =
--       2,400 XP/hr PER (actor, target) PAIR -- two thirds of the whole
--       shared 3,600 XP/hr budget from ONE pair alone, and MedkitCooldown
--       is keyed by the TARGET's citizenid, not the actor's (this file's
--       own Config.Features.HandlerXPProgression header, verified above),
--       so an actor with several K9 partners/alts to round-robin across
--       multiplies that further with NO per-target throttle standing in
--       the way at all. A future per-actor mint cooldown for this award
--       MUST be keyed by the ACTOR (never reuse MedkitCooldown's
--       target-keyed shape, which cannot see a multi-target actor at all)
--       and sized well below what 18,000ms alone would suggest.
--     * KENNEL DEPLOY: Config.DeployableKennel.deployCooldownMs ships at
--       5000ms -- config.lua's own header already measured this as
--       5,760 XP/hr gross UNWIRED (8 XP every 5s), enough alone to exhaust
--       the shared budget in under 40 minutes. A Master Handler
--       (kennelDeployCooldownMultiplier = 0.45, RETUNED from 0.60 by the
--       XP-rebalance pass) shortens that floor to 2250ms via
--       GetHandlerXPTierKennelDeployCooldownMs below -- 8 XP every 2.25s =
--       12,800 XP/hr gross, PER ACTOR (DeployCooldown, unlike
--       MedkitCooldown, is already keyed by the deploying actor's own
--       source) -- i.e. this pass makes the already-judged-unsafe number
--       122% WORSE. A future per-actor mint cooldown for this award must be
--       sized against 2250ms, never the unreduced 5000ms config default.
--
--   BINDING REQUIREMENT FOR WHOEVER WIRES handlerTreatK9/handlerKennelDeploy
--   NEXT: gate that award through a DEDICATED per-actor MINT cooldown,
--   entirely separate from MedkitCooldown/DeployCooldown, sized against
--   the RANK-REDUCED floors above (18000ms / 2250ms), not the unreduced
--   config defaults (60000ms / 5000ms) -- mirroring server/certifications/'s
--   own CertifyXpMintCooldown fix for handlerCertifyK9 (keyed by the actor,
--   its own TTL, independent of the action-throttling cooldown). Never
--   derive mint eligibility from MedkitCooldown.IsOnCooldown/
--   DeployCooldown.Consume directly once this pass ships -- a handler's own
--   rank can now shorten both of those, so treating either as a mint
--   throttle would let a higher rank both mint AND shorten its own
--   throttle at once, reintroducing exactly the climbing-the-ladder-makes-
--   the-ladder-faster loop this note exists to rule out. This requirement
--   is why these two award keys stay in Config.Features.HandlerXPProgression's
--   own "DELIBERATELY LEFT UNWIRED" list even after this pass -- wiring the
--   COOLDOWN EFFECT is not the same change as wiring the AWARD, and this
--   pass only does the former.
--
--   ENFORCED, NOT JUST DOCUMENTED: tests/medkit_spec.lua and
--   tests/kennel_spec.lua each carry a SOURCE AUDIT test (mirroring
--   an earlier spec's own "SOURCE AUDIT" precedent) that fails the
--   moment AwardHandlerXP('handlerTreatK9'/'handlerKennelDeploy') actually
--   appears in server/medkit.lua/server/kennel.lua UNLESS that same file
--   also names a dedicated *_XP_MINT_COOLDOWN tracker (the
--   CERTIFY_XP_MINT_COOLDOWN_MS/CertifyXpMintCooldown naming convention
--   server/certifications/ already established) -- a red test, not a
--   comment someone can wire past without reading.
--
--   CLOSED (WIRING PASS, coder-backend -- the "top handler rank cannot be
--   reached by playing" anti-farm audit finding). The BINDING REQUIREMENT
--   above is now satisfied by both files: server/medkit.lua declares
--   HandlerTreatXpMintCooldown (a flat NewCooldown(), keyed on the USING
--   player's own citizenid, 30 real minutes, swept -- never
--   :RegisterPlayerDropped()'d, so it survives the actor's own
--   disconnect/reconnect) and calls AwardHandlerXP(usingCitizenid,
--   'handlerTreatK9') only when that tracker's own .Consume(...) allows it
--   AND the heal was genuine (target strictly below max health beforehand --
--   never a no-op top-off of an already-healthy K9). server/kennel.lua
--   declares HandlerKennelDeployXpMintCooldown (same shape, keyed on the
--   DEPLOYING player's own citizenid, 60 real minutes) and calls
--   AwardHandlerXP(citizenid, 'handlerKennelDeploy') only at
--   confirmKennelPlaced's own success line -- a REAL, confirmed, registered
--   kennel object, never the earlier requestDeployKennel step, which can
--   still fail after that step.
--
--   THE FEEDBACK LOOP THIS SECTION'S OWN HEADER FLAGS STILL DOES NOT EXIST,
--   RE-VERIFIED (not re-argued from the old reasoning alone): both new mint
--   cooldowns are FIXED FILE-LOCAL CONSTANTS (TREAT_XP_MINT_COOLDOWN_MS /
--   KENNEL_DEPLOY_XP_MINT_COOLDOWN_MS), never derived from
--   GetHandlerXPTierMedkitCooldownMs/GetHandlerXPTierKennelDeployCooldownMs
--   or from MedkitCooldown/DeployCooldown themselves -- a handler's own rank
--   still shortens the ACTION cooldown (how often treating/deploying may be
--   RETRIED), exactly as before this pass, but the MINT cadence (how often
--   the ACTION actually PAYS) is completely unaffected by rank, at every
--   tier. Climbing the ladder therefore still cannot make the ladder itself
--   climb any faster.
--
--   RESULTING ARITHMETIC (see each tracker's own declaration comment in its
--   own file for the full derivation, reproduced briefly here since this is
--   the section the BINDING REQUIREMENT above points at): handlerTreatK9 is
--   now capped at 12 XP / 30 min = 24 XP/hr per actor (independent of how
--   many different K9s that actor round-robins, since the tracker is keyed
--   on the actor alone); handlerKennelDeploy is now capped at 8 XP / 60 min
--   = 8 XP/hr per actor (independent of how fast a disconnect/reconnect loop
--   could otherwise force fresh deploys). Combined, 32 XP/hr worst-case
--   theoretical ceiling from these two actions alone -- nowhere near the
--   shared 3,600 XP/hr budget, and nowhere near fast enough to reach
--   Config.HandlerXPTiers' 500-XP Master threshold "in an afternoon": even a
--   handler with ZERO tenure/certification income needs 500 / 32 = 15.625
--   continuous, uninterrupted, never-missed hours at this theoretical
--   ceiling to reach Master from these two actions alone (a handler who also
--   earns the full 155-XP tenure trickle needs only 345 / 32 = 10.78 such
--   hours for the remainder) -- and a realistic, non-maxed pace (an
--   occasional genuine injury to treat, one kennel redeploy per session)
--   spreads that same total across roughly one to a few weeks of ordinary
--   duty, the same order of magnitude config.lua's own Config.HandlerXPTiers
--   header already describes for a certifying handler's path to Master.
--   config.lua's own Config.Features.HandlerXPProgression and
--   Config.HandlerXPTiers headers carry the full write-up and are the
--   source of truth for this arithmetic going forward -- re-derive it there
--   (not here) before ever retuning either mint-cooldown constant.
--
-- NO LIVE CLIENT PUSH: unlike Config.XPTiers' speedMultiplier/
-- scentRangeMultiplier (which visibly change a K9's own ped behavior in
-- real time and so need PushTierSnapshot to reach an already-connected
-- client the moment a tier is crossed), both functions below are consulted
-- fresh, server-side only, at the exact moment their action's own gate is
-- checked -- there is no cached or client-visible copy of "my current
-- effective cooldown" to go stale, so no outbound event is needed here,
-- unlike this file's own AwardHandlerXP doc comment used to speculate.
-- ======================================================================

-- ======================================================================
-- HIGH COMMAND COOLDOWN-MULTIPLIER BYPASS (owner-directed, this pass --
-- "high command automatically gets every k9 upgrade"). Applies to THIS
-- file's own three cooldown-multiplier unlocks ONLY (GetHandlerXPTierMedkitCooldownMs
-- and GetHandlerXPTierKennelDeployCooldownMs immediately below, and
-- GetXPTierMedkitCooldownMs further down) -- see this
-- file's own "COMPOSITION WITH THE PERMISSION/FEATURE-CONTROL LAYER"
-- section further up for why this stops exactly here and goes no further:
--
--   * DELIBERATELY NOT applied to GetXPTier/GetXP/GetHandlerXPTier
--     themselves. Those three remain the PURE, real-earned-data read every
--     OTHER consumer in this resource relies on for a truthful answer --
--     AwardXP's own tier-crossing detection compares GetXPTier's return
--     BY REFERENCE (ResolveTier's own doc comment), server/tablet.lua's
--     PersonSummaryResult renders GetXP/GetXPTier's `.label` as this
--     citizenid's REAL standing, and server/search.lua's coop-search-bonus
--     eligibility gate reads GetXPTier(...).xp as a real "has this citizenid
--     progressed past zero" signal. Fabricating a top-tier answer inside
--     any of those would make a high-command officer's tablet entry LIE
--     about their own real, earned XP -- exactly the "a bypass must never
--     read as an earned grant" property this pass's own instructions call
--     out by name. A citizenid's real GetXPTier/GetXP answer is therefore
--     completely unaffected by being high command; only the two COOLDOWN
--     NUMBERS below are.
--   * DELIBERATELY NOT applied to the speedMultiplier/scentRangeMultiplier
--     movement/scent-range effects (server/k9profiles.lua's
--     GetK9EffectiveMultipliers, consumed by client/movement.lua's
--     K9MoveRateModifiers and server/tracking.lua's scent-range calc) --
--     out of this file's own ownership for this pass (server/k9profiles.lua
--     is not an owned file here) and, independently, a genuine anti-cheat
--     concern this pass's own instructions flag by name: an INSTANT,
--     rank-triggered jump in a K9's live movement speed is exactly the
--     "speed/velocity change outside normal flow" class of thing that gets
--     legitimate play flagged by common anti-cheat heuristics, unlike a
--     pure timing NUMBER (how often a cooldown-gated action may be reused)
--     which has no physical/movement signature at all. Reported to
--     whoever owns server/k9profiles.lua/server/highcommand.lua rather than
--     silently extended here.
--
-- FLOOR, NEVER A CEILING: BestValidTierMultiplier below only ever REPLACES
-- an invalid/missing/worse-than-best multiplier with the single best value
-- any REAL, configured tier in the same ladder already offers to an
-- ordinary citizenid who earned it -- it can never make a high-command
-- officer's own cooldown WORSE than their real tier/individual override
-- already gives them, and it never invents a value better than what this
-- server operator has actually configured somewhere in that ladder. This
-- mirrors config.lua's own "high command implies every GRANT, it does not
-- invent a new one out of thin air" posture for the permission-grant
-- namespace.
-- ======================================================================

--- Smallest (most favorable -- every consumer of this value treats it as a
--- cooldown-REDUCTION ratio, so a smaller number is a bigger discount)
--- value of `fieldName` across every tier in `tiers` that independently
--- passes the exact defensive-bounds check every consumer already applies
--- on its own (number, not NaN, > 0, <= 1) -- never a raw, unchecked config
--- value. Returns nil when no tier in `tiers` carries a valid value for
--- this field at all (every tier omits it, or `tiers` is one of this
--- file's own FALLBACK_XP_TIERS/FALLBACK_HANDLER_XP_TIERS single-entry
--- safety nets, neither of which sets any cooldown-multiplier field) --
--- callers must treat nil as "no bypass available", never invent a 0/1.0
--- fallback of their own.
--- @param tiers table -- GetValidatedXPTiers()/GetValidatedHandlerXPTiers()'s own return value
--- @param fieldName string
--- @return number?
local function BestValidTierMultiplier(tiers, fieldName)
    local best = nil
    for i = 1, #tiers do
        local tier = tiers[i]
        local value = type(tier) == 'table' and tier[fieldName]
        if type(value) == 'number' and value == value and value > 0 and value <= 1 then
            if best == nil or value < best then best = value end
        end
    end
    return best
end

--- Given `multiplier` (a caller's own already-resolved value for
--- `fieldName` -- BEFORE that caller's own bounds check runs, so this may
--- be nil, non-numeric, NaN, or out of the valid (0, 1] range), returns
--- the BEST (smallest) valid value found across `tiers` for `fieldName`
--- INSTEAD, but ONLY when `citizenid` is currently an online high-command
--- officer (IsHighCommandBypassCitizenId -- soft dependency,
--- `type(...) == 'function'` guarded; offline or feature-off both answer
--- `false`, in which case `multiplier` is returned completely unchanged)
--- AND that replacement is a genuine improvement (the caller's own
--- multiplier is missing/invalid, or the best available value is strictly
--- smaller/more generous) -- see this section's own header "FLOOR, NEVER A
--- CEILING". Every defensive bound the caller was already going to apply
--- to whatever this returns (non-numeric/NaN/<=0/>1 all fail closed back
--- to `baseCooldownMs`) is UNCHANGED and still runs on the caller's own
--- side -- this function never bypasses that check, it only supplies a
--- different candidate value for it to evaluate.
--- @param citizenid string
--- @param multiplier any
--- @param tiers table
--- @param fieldName string
--- @return any -- `multiplier` unchanged, or the best valid tier value found
local function ApplyHighCommandCooldownBypass(citizenid, multiplier, tiers, fieldName)
    if not (type(IsHighCommandBypassCitizenId) == 'function' and IsHighCommandBypassCitizenId(citizenid)) then
        return multiplier
    end

    local best = BestValidTierMultiplier(tiers, fieldName)
    if best == nil then return multiplier end

    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 or multiplier > 1 or best < multiplier then
        return best
    end
    return multiplier
end

--- @param citizenid string
--- @param baseCooldownMs number
--- @return number effectiveCooldownMs
function GetHandlerXPTierMedkitCooldownMs(citizenid, baseCooldownMs)
    if type(baseCooldownMs) ~= 'number' or baseCooldownMs ~= baseCooldownMs or baseCooldownMs <= 0 then
        return baseCooldownMs
    end

    local tier = GetHandlerXPTier(citizenid)
    local multiplier = tier.medkitTreatCooldownMultiplier
    multiplier = ApplyHighCommandCooldownBypass(citizenid, multiplier, GetValidatedHandlerXPTiers(), 'medkitTreatCooldownMultiplier')

    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 or multiplier > 1 then
        return baseCooldownMs
    end

    return math.max(1, math.floor(baseCooldownMs * multiplier))
end

--- @param citizenid string
--- @param baseCooldownMs number
--- @return number effectiveCooldownMs
function GetHandlerXPTierKennelDeployCooldownMs(citizenid, baseCooldownMs)
    if type(baseCooldownMs) ~= 'number' or baseCooldownMs ~= baseCooldownMs or baseCooldownMs <= 0 then
        return baseCooldownMs
    end

    local tier = GetHandlerXPTier(citizenid)
    local multiplier = tier.kennelDeployCooldownMultiplier
    multiplier = ApplyHighCommandCooldownBypass(citizenid, multiplier, GetValidatedHandlerXPTiers(), 'kennelDeployCooldownMultiplier')

    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 or multiplier > 1 then
        return baseCooldownMs
    end

    return math.max(1, math.floor(baseCooldownMs * multiplier))
end

--- Loads a citizenid's real handler-XP total from k9_progression.handler_xp
--- into the HandlerXP cache. Mirrors LoadXPForCitizenid above exactly,
--- including its pcall-wrapped, fail-to-a-safe-0-baseline posture -- a
--- database that has not yet applied sql/migrations/0017_add_k9_progression_
--- handler_xp.sql throws "Unknown column 'handler_xp'" out of
--- K9Store.HandlerXP_Get, which this function catches and degrades to 0,
--- exactly like an ordinary "no row yet" result.
--- @param citizenid string
--- @return number handlerXp -- the freshly-cached value
local function LoadHandlerXPForCitizenid(citizenid)
    local queryOk, xpOrErr = pcall(K9Store.HandlerXP_Get, citizenid)

    if not queryOk then
        print(('[John-K9] progression: LoadHandlerXPForCitizenid query failed for %s (has migration 0017 been applied?): %s'):format(citizenid, tostring(xpOrErr)))
        HandlerXP[citizenid] = 0
        return 0
    end

    HandlerXP[citizenid] = xpOrErr or 0
    return HandlerXP[citizenid]
end

-- Config.HandlerXPTiers' own shape validation lives entirely in
-- GetValidatedHandlerXPTiers above now (lazy, clamp-and-warn, never an
-- onResourceStart assert) -- see that function's own doc comment for why
-- an assert-inside-onResourceStart shape is specifically wrong for a
-- flag that ships off by default.

-- Config.HandlerXP.awards' own value-range validation -- CLAMP AND WARN,
-- same reasoning as GetValidatedHandlerXPTiers above, applied to a
-- DIFFERENT malformed-config shape (an individual award amount, not the
-- tier ladder). Deliberately NOT the assert-inside-onResourceStart shape
-- Config.XP.awards' own identical guard further below uses -- that guard
-- is correct for Config.XP.awards specifically because XPProgression is
-- on-by-default and load-bearing; Config.HandlerXP.awards backs a flag
-- that ships off, so a missing/malformed table here must never abort an
-- onResourceStart handler for an unrelated, always-loaded feature (this
-- exact incident -- five unrelated specs failing at boot on a table they
-- never define -- is what prompted this rewrite; see git history/PR
-- discussion for the full report). Warns AT MOST ONCE per actionKey per
-- resource lifetime, checked lazily inside AwardHandlerXP itself rather
-- than eagerly at boot, so a feature that is never turned on and never
-- called never even evaluates this.
local HandlerAwardAmountWarned = {} -- actionKey -> true

--- @param actionKey string
--- @param amount number -- already confirmed `type(amount) == 'number'` by the caller
--- @return number? validAmount -- `amount` unchanged if it passes, nil if it does not (caller then treats this exactly like any other unpayable award: a silent no-op)
local function ValidateHandlerAwardAmount(actionKey, amount)
    if amount >= 0 and (not XPMintBudgetEnabled or amount <= XP_MINT_BUDGET_CAP_XP) then
        return amount
    end
    if not HandlerAwardAmountWarned[actionKey] then
        HandlerAwardAmountWarned[actionKey] = true
        if amount < 0 then
            print(('[John-K9] progression: Config.HandlerXP.awards.%s (%s XP) must not be negative -- a negative amount would silently INFLATE the shared XP mint budget instead of spending it (see AwardXP\'s own identical runtime guard for the exact mechanism). Treating this actionKey as unpayable rather than risking that. Fix this value in config.lua.'):format(actionKey, tostring(amount)))
        else
            print(('[John-K9] progression: Config.HandlerXP.awards.%s (%s XP) exceeds XP_MINT_BUDGET_CAP_XP (%d XP) -- this award could never be paid, for any citizenid, ever, regardless of how long they wait. Treating this actionKey as unpayable rather than crashing. Fix this value in config.lua, or raise XP_MINT_BUDGET_CAP_XP (server/progression.lua).'):format(actionKey, tostring(amount), XP_MINT_BUDGET_CAP_XP))
        end
    end
    return nil
end

-- ==========================================================================
-- XP TIER UNLOCKS -- DEVELOPER_REFERENCE.md Part B §8 (coder-backend, this pass).
-- Config.XPTiers previously only ever changed speedMultiplier/
-- scentRangeMultiplier -- two numbers invisible to the player except as "a
-- slightly faster dog." This section connects tiers to real, checkable
-- capability by reusing systems that already exist (the doc's own framing:
-- "connects them instead of adding a new subsystem"), NOT a new
-- authorization layer of its own.
--
-- THREE UNLOCKS DEFINED, ONE PER NON-BASE TIER. WIRED STATUS BELOW IS THE
-- CURRENT GROUND TRUTH, RE-VERIFIED AGAINST THE REAL FILES BEFORE WRITING
-- THIS -- not a status this comment is allowed to go stale on. CORRECTED
-- (this pass, coder-backend): this used to say "the two UNWIRED items
-- below" -- Veteran's own bullet below was one of those two, and is now
-- WIRED (re-verified this pass; see its own bullet for what changed), so
-- only Elite's HUD-display half remains genuinely unwired below. If you
-- wire that one too, flip its own line to WIRED and say where, in the same
-- edit; do not leave a dangling "not wired yet" note once it is no longer
-- true.
--   Trained (1,250 XP) -- WIRED. Eligibility for the cooperative search
--     bonus (server/search.lua, Part B §10): BOTH the searcher and their
--     currently active partner must be Trained+ (`GetXPTier(citizenid).xp >
--     0` on both citizenids -- never by label/index, so this stays correct
--     even if the tier table is retuned later). Confirmed live in
--     server/search.lua's TryAwardCoopSearchBonus (`GetXPTier(searcherCitizenid
--     ).xp <= 0 or GetXPTier(partnerCitizenid).xp <= 0` gate) -- nothing
--     needed here beyond the already-existing GetXPTier this reuses
--     unchanged.
--   Veteran (4,000 XP) -- WIRED, CALL SITE APPLIED. CORRECTED (this pass,
--     coder-backend) -- this bullet used to read "ACCESSOR WIRED, CALL SITE
--     NOT YET APPLIED" and claimed server/medkit.lua reads
--     Config.K9Medkit.cooldownMs raw; both claims are false today and were
--     re-verified false by direct read of the real server/medkit.lua before
--     writing this correction, not assumed. GetXPTierMedkitCooldownMs below
--     is complete, defensively bounded (see its own doc comment) and
--     covered end to end by tests/xptierunlocks_spec.lua -- config.lua's
--     Elite/Veteran rows already carry `medkitCooldownMultiplier = 0.75`.
--     The one-line call this bullet used to describe as "sent to main, not
--     yet applied" IS APPLIED: server/medkit.lua's RunUseK9MedkitMutation
--     resolves `baseCooldownMs` via `ResolveMedkitBaseCooldownMs()` (the
--     validated, never-raw config read) and then calls
--     `GetXPTierMedkitCooldownMs(targetCitizenid, baseCooldownMs)`
--     (soft-guarded, `type(GetXPTierMedkitCooldownMs) == 'function'`) to
--     get the threshold its own `MedkitCooldown.IsOnCooldown` call actually
--     checks against — see that file's own FILE-TO-FILE CONTRACT entry for
--     GetXPTierMedkitCooldownMs, and tests/medkit_spec.lua's own "GAP
--     CLOSURE" section, which loads the REAL server/datastore.lua +
--     server/progression.lua + server/medkit.lua together and proves a
--     Veteran-tier citizenid's medkit cooldown is genuinely shortened, not
--     merely wired-but-unreachable. Every K9 medkit cooldown DOES reflect
--     this tier unlock today, and config.lua's own Veteran-row comment no
--     longer overpromises.
--   Elite (9,000 XP) -- SERVER HALF WIRED, DISPLAY NOT WIRED. NO CODE
--     CHANGE NEEDED IN THIS FILE: PushTierSnapshot/CopyTier already forward
--     EVERY field present on a Config.XPTiers[n] row to the client verbatim
--     (CopyTier's own `for key, value in pairs(tier) do copy[key] = value
--     end`), config.lua's Elite row already carries `badge = 'elite'`, and
--     client/progression.lua's `currentXPTier` (confirmed by reading that
--     file) caches the FULL received tier table, badge field included --
--     so `GetCurrentXPTier().badge` already resolves to `'elite'` for an
--     Elite-tier client today, with zero further server/progression.lua or
--     client/progression.lua work. What is verified NOT present, by
--     grepping both files directly, is any *consumer* of that field:
--     client/hud.lua's PushVitals only ever sends `xpTier.label` to the
--     NUI, and html/app.js has no `badge` handling at all -- so the value
--     is computed, forwarded, and cached, but never rendered. Handed to
--     coder-ui (owns both files) as a wiring request, not applied here.
--
-- COMPOSITION WITH THE PERMISSION/FEATURE-CONTROL LAYER (server/
-- permissions.lua's HasPermission, config.lua's Config.FeatureControl
-- resolution order -- this task's own explicit requirement). That order is
-- FOUR steps long ("Config.Features.<Name> false -> deny always; an
-- explicit BLOCK -> deny; RequireGrant -> needs a grant; otherwise ->
-- allow"), and reaching an XP tier is not, and must never become, a fifth.
-- None of the three unlocks above adds one:
--   * GetXPTierMedkitCooldownMs returns a NUMBER, never a boolean, and is
--     documented to be consulted ONLY AFTER the caller's own
--     Config.Features.K9Medkit / HasK9Access / department / proximity /
--     item gate has already allowed the action. If K9Medkit is off, blocked
--     for that citizenid, or they are not certified, medkit.lua's own
--     existing gate denies BEFORE this function is ever reached, tier or no
--     tier -- there is nothing this function could do to "silently
--     re-enable" a block, because it never participates in the allow/deny
--     decision at all. It only ever adjusts a duration for an action that
--     was already independently authorized.
--   * The coop-search-bonus tier gate (server/search.lua) only ever
--     WITHHOLDS a bonus XP amount. Reaching Trained tier cannot make anyone
--     able to search who couldn't already -- HasK9Access is re-checked,
--     unchanged, at the top of the real searchTarget callback, exactly as
--     before this pass.
--   * The HUD badge is pure display. It grants no capability at all, so
--     there is nothing for a block to conflict with.
-- REJECTED ON THIS EXACT BASIS -- composing badly with the block/grant
-- layer, not merely "not chosen": auto-granting BiteAndHold/
-- NonLethalTakedown/PropDragging (Config.FeatureControl.RequireGrant), or
-- the 'k9.access'/'k9.certify'/'k9.audit'/'k9.givexp' permissions
-- (Config.Permissions), via a tier threshold. All five are EXPLICITLY the
-- capabilities those two tables exist to put behind a deliberate, named,
-- revocable, AUDITED human decision (config.lua's own words: "this hands it
-- to one specific person," "every use is logged"). A tier-based auto-unlock
-- of any of them would be a SECOND, ungoverned path to the exact same
-- capability -- reachable purely by grinding, with no grant, no audit row,
-- and, specifically, no way for a human BLOCK to ever catch up to it, since
-- a block only stops the grant/rank path, never an XP total.
--
-- TIERS ARE REACHABLE BY FARMING -- REJECTED UNLOCKS ON THAT BASIS ALONE,
-- separate from the composition concern above (an unlock can fail this test
-- even with zero permission/block interaction). This project has closed
-- eight XP farms; the current, closed, TESTED ceiling is 3,600 XP/hr shared
-- per citizenid (XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS above),
-- reaching Elite (9,000 XP) in ~2h27m of deliberate, maximal grinding, not
-- incidental play. Considered and rejected as unsafe in the hands of a
-- citizenid who did nothing but grind for it:
--   * Any reduction of a per-mechanic MINT cooldown (BiteHoldXpMintCooldown/
--     TakedownXpMintCooldown/ContrabandXpMintCooldown/
--     TrackTicketMintCooldown/the new CoopSearchXpMintCooldown), or of
--     XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS themselves, or a raised
--     Config.XP.awards value. Every one of these IS the anti-farm floor the
--     EIGHTH-XP-FARM-FIX section above documents at length -- making any of
--     them tier-dependent would let a farmer's OWN grinding progressively
--     widen the exact ceiling meant to bound that same grinding, a
--     compounding/runaway shape strictly worse than a static farm.
--   * A reduced NonLethalTakedown/BiteAndHold ACTION cooldown (
--     Config.Combat.NonLethalTakedown.targetCooldownMs and its bite-hold
--     equivalent -- the cooldown on the ABILITY itself, not on its XP
--     mint). K9 combat is player-vs-player (a settled decision) -- a faster
--     action cooldown is a genuine PvP re-engagement advantage, not a
--     cosmetic or economy concern, and handing one to whoever ground the
--     longest is exactly the "harmful in the hands of a farmer" case this
--     task named explicitly.
--   * A raised wellbeing stat MAX (Fatigue) via
--     tier -- the doc's own suggested example. Investigated this pass:
--     every single Clamp(...) call site in server/wellbeing.lua's tick loop
--     reads Config.Wellbeing.<Stat>.max directly, as one GLOBAL constant --
--     there is no per-citizenid cap composer to add one more input to, the
--     way client/movement.lua's K9MoveRateModifiers already composes the
--     speed/scent tier bonus. Making the cap per-citizenid would mean
--     threading a new parameter through dozens of call sites in a
--     security/balance-reviewed file this pass does not own -- a real,
--     invasive refactor, not the "small-moderate, mostly reads" effort the
--     doc estimated. Rejected on cost/ownership grounds, not a farmability
--     concern -- flagged here so a future pass with wellbeing.lua ownership
--     does not have to rediscover this from scratch.
--
-- ADDENDUM (owner-directed "high command gets every k9 upgrade" pass, this
-- file's own "HIGH COMMAND COOLDOWN-MULTIPLIER BYPASS" section further
-- down): none of the above is reopened by that pass. Every rejection above
-- is about an XP TOTAL (a grindable, farmable number ANY citizenid can
-- reach solo) auto-unlocking a capability with no human decision behind it
-- -- being HIGH COMMAND is the opposite of that: a real, config-bounded,
-- revocable job-rank threshold a human promotion decision already governs,
-- exactly the "deliberate, named, revocable, audited human decision" this
-- section's own words say IS the correct way to gate a capability. High
-- command's own cooldown-multiplier bypass never lets a citizenid GRIND
-- its way to the same effect, and a block still fully overrides it (see
-- that section for the structural reason why) -- neither rejection above
-- ever applied to a rank-based gate.
-- ==========================================================================

--- Resource-global — Part B §8 XP TIER UNLOCKS (see the section header
--- immediately above for the full "why this is safe" writeup, and for this
--- reward's current WIRED/UNWIRED status — this comment documents the
--- function's own contract, not a standing status note that can go stale).
--- Returns the EFFECTIVE K9Medkit cooldown for `citizenid`'s own tier given
--- the feature's own configured `baseCooldownMs` — never a boolean, never
--- an access decision. A pass-through-with-clamping over an OPTIONAL
--- `medkitCooldownMultiplier` field on the citizenid's current
--- Config.XPTiers row (config.lua's Veteran row carries `0.75` today; still
--- OPTIONAL and defensively checked below, not assumed present, so an
--- operator-edited config missing it on some future row still gets a
--- clean `baseCooldownMs` no-op, never an error).
---
--- CALLER CONTRACT (server/medkit.lua). CORRECTED (this pass, coder-backend):
--- this paragraph used to describe the call site below as a "currently
--- UNAPPLIED change... see this pass's own report for the ready-to-apply
--- patch," with a hypothetical snippet reading `Config.K9Medkit.cooldownMs`
--- raw — false today, re-verified false by direct read of the real
--- server/medkit.lua before writing this correction, not assumed. The real,
--- APPLIED call site (RunUseK9MedkitMutation) does not match that
--- hypothetical snippet either: it never reads `Config.K9Medkit.cooldownMs`
--- directly at all, even as a fallback — it resolves the base cooldown via
--- that file's own `ResolveMedkitBaseCooldownMs()` (the validated-every-call
--- config read, never the raw value) and passes THAT into this function:
---   local baseCooldownMs = ResolveMedkitBaseCooldownMs()
---   local effectiveCooldownMs = baseCooldownMs
---   if type(GetXPTierMedkitCooldownMs) == 'function' then
---       effectiveCooldownMs = GetXPTierMedkitCooldownMs(targetCitizenid, baseCooldownMs)
---   end
---   if MedkitCooldown.IsOnCooldown(targetCitizenid, effectiveCooldownMs, requestedAt) then
--- (quoted verbatim from that file's own RunUseK9MedkitMutation — see its
--- FILE-TO-FILE CONTRACT entry for GetXPTierMedkitCooldownMs for the same
--- story from that file's side, and tests/medkit_spec.lua's own "GAP
--- CLOSURE" section for the end-to-end proof). `targetCitizenid` (not the
--- using player's own citizenid) is deliberate:
--- `MedkitCooldown` is already keyed on the TARGET K9's citizenid (that
--- file's own header — the cooldown limits how often a given K9 can be
--- re-healed), so the tier that should shorten it is the K9 BEING healed's
--- own earned tier, not whoever happens to be holding the medkit.
--- Consult this ONLY AFTER every one of that file's own existing gates
--- (Config.Features.K9Medkit, the proximity/item/department checks) has
--- already allowed the action. This function performs NONE of those checks
--- itself and must never be treated as one — it is a pure numeric modifier
--- for an action the caller has already independently authorized, the same
--- "modifier, never a gate" role speedMultiplier/scentRangeMultiplier
--- already play for movement/tracking.
---
--- DEFENSIVE BOUNDS, never trust the config value blindly: a multiplier
--- that is missing, non-numeric, NaN, <= 0, or > 1 returns `baseCooldownMs`
--- UNCHANGED rather than applying it — this is an UNLOCK (only ever a
--- reduction), never a way to lengthen a cooldown, and a <= 0 result would
--- hand server/cooldowns.lua's IsOnCooldown a non-positive threshold, which
--- that file's own header documents as PERMANENTLY ON — the opposite of a
--- Veteran-tier reward, and exactly the kind of footgun this guard exists
--- to prevent.
---
--- GAP 1 CLOSURE (owner-directed "god over that tablet ... over everything
--- related to that K9" pass, server/k9profiles.lua's own per-INDIVIDUAL-K9
--- override layer): the multiplier consulted below is now
--- `GetK9EffectiveMultipliers(citizenid).medkitCooldownMultiplier` — GLOBAL
--- DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE, server/k9profiles.lua's own
--- documented resolution order, composed for this citizenid — rather than
--- `GetXPTier(citizenid).medkitCooldownMultiplier` raw. Soft-guarded
--- (`type(GetK9EffectiveMultipliers) == 'function'`, pcall-wrapped): when
--- server/k9profiles.lua is absent or throws, this falls back to the exact
--- same raw `GetXPTier(citizenid).medkitCooldownMultiplier` read this
--- function used before this pass — byte-for-byte unaffected for a
--- citizenid with no individual override either way, since
--- GetK9EffectiveMultipliers itself already returns the plain tier value
--- when no override row sets this field. Every defensive bound below is
--- UNCHANGED and applies identically regardless of which source the
--- multiplier came from — an override cannot bypass this function's own
--- <= 0 / > 1 / NaN guard any more than a tier's own config-shipped value
--- could.
--- @param citizenid string
--- @param baseCooldownMs number
--- @return number effectiveCooldownMs
function GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs)
    if type(baseCooldownMs) ~= 'number' or baseCooldownMs ~= baseCooldownMs or baseCooldownMs <= 0 then
        return baseCooldownMs
    end

    local multiplier
    if type(GetK9EffectiveMultipliers) == 'function' then
        local ok, effective = pcall(GetK9EffectiveMultipliers, citizenid)
        if ok and type(effective) == 'table' then
            multiplier = effective.medkitCooldownMultiplier
        end
    end
    if multiplier == nil then
        local tier = GetXPTier(citizenid)
        multiplier = tier.medkitCooldownMultiplier
    end

    -- HIGH COMMAND BYPASS -- see this file's own "HIGH COMMAND
    -- COOLDOWN-MULTIPLIER BYPASS" section header above for the full
    -- contract. Consulted AFTER the individual-override/tier resolution
    -- above (never overrides a MORE generous individual override --
    -- "FLOOR, NEVER A CEILING"), and still subject to the exact same
    -- defensive-bounds check immediately below regardless of which of the
    -- three sources it came from.
    multiplier = ApplyHighCommandCooldownBypass(citizenid, multiplier, GetValidatedXPTiers(), 'medkitCooldownMultiplier')

    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 or multiplier > 1 then
        return baseCooldownMs
    end

    return math.max(1, math.floor(baseCooldownMs * multiplier))
end

-- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass, this pass) -- mirrors
-- server/certifications/'s RefreshCertificationCache fix of the
-- identical class of bug (a transient query failure recorded as a
-- confirmed answer instead of "we don't know"), applied here to K9XP. See
-- LoadXPForCitizenid's own doc comment below for the full contract.
--
-- SEVERITY, STATED EXPLICITLY (lower than the certification case, but the
-- SAME CLASS -- fixed for the same reason, not skipped for this reason):
-- a wrong K9XP value has NO access-control consequence -- GetXPTier/GetXP
-- only ever drive a bounded scentRangeMultiplier/speedMultiplier cosmetic
-- bonus, never a permission (see this file's own header FILE-TO-FILE
-- CONTRACT). It is also already partially self-healing regardless of this
-- fix: AwardXP persists a DELTA to the database (K9Store.XP_UpsertAdd,
-- `xp = xp + VALUES(xp)`), never this in-memory total, so a citizenid whose
-- session-local cache got reset to 0 by the OLD bug still had their real DB
-- total intact and correctly incremented by every subsequent award — only
-- THIS SESSION's displayed tier/speed bonus was ever at risk, never their
-- persisted progress.
local XP_LOAD_RETRY_ATTEMPTS = 3
local XP_LOAD_RETRY_BACKOFF_MS = 200

-- XPLoadUnresolved[citizenid] = true once LoadXPForCitizenid exhausts its
-- own retry budget with no confirmed answer either way. Purely a
-- bookkeeping flag for the operator-facing message and the resync sweep
-- below -- never read by GetXP/GetXPTier/AwardXP, and never merged into
-- K9XP itself. Local: nothing outside this file needs it.
local XPLoadUnresolved = {}

--- Runs `fn()` up to `attempts` times, waiting `backoffMs * attemptNumber`
--- between tries -- identical shape and reasoning to
--- server/certifications/'s own PcallWithBoundedRetry, duplicated here
--- rather than shared, matching this resource's own established "each file
--- keeps its own tiny copy of a genuinely small, self-contained helper"
--- convention (see e.g. that file's own IsDuplicateKeyError precedent,
--- independently re-implemented in server/permissions.lua for the same
--- reason).
--- @param fn function
--- @param attempts number
--- @param backoffMs number
--- @return boolean ok
--- @return any resultOrErr
---
--- `coroutine.isyieldable()` GUARD -- see server/certifications/'s own
--- identical guard on its own PcallWithBoundedRetry for the full "why":
--- every real call site here runs inside an FXServer-managed coroutine
--- (event handler, this file's own resync sweep), where `Wait()` is always
--- safe -- this guard exists so the function is ALSO safe to call directly
--- from a plain, non-coroutine Lua call (this resource's own test suite
--- calls LoadXPForCitizenid this way throughout
--- tests/progression_spec.lua), where `Wait()` -> `coroutine.yield()`
--- would otherwise error outright.
local function PcallWithBoundedRetry(fn, attempts, backoffMs)
    local ok, result
    for attempt = 1, attempts do
        ok, result = pcall(fn)
        if ok then return ok, result end
        if attempt < attempts and coroutine.isyieldable() then
            Wait(backoffMs * attempt)
        end
    end
    return ok, result
end

--- Loads a citizenid's real XP total from k9_progression into the K9XP
--- cache. Bounded-retry-wrapped mirroring server/certifications/'s
--- RefreshCertificationCache precedent — an uncaught error here must not
--- abort the caller's own loop (PlayerLoaded fires per-player, but the
--- resource-start backfill loop below iterates every connected player in
--- one handler invocation, and FXServer's dispatch pcalls the whole
--- handler, not each iteration, so one bad row would otherwise wedge every
--- subsequent player — the exact bug class server/main.lua's own backfill
--- loop header already documents finding and fixing once for
--- certifications). Unlike certification access, a failed XP read has no
--- security consequence either way (XP grants a bounded scent/speed bonus,
--- never a permission) — see "SEVERITY" above.
---
--- COULD-NOT-DETERMINE (lifecycle QA pass): a query failure that survives
--- CERT-style bounded retry is NOT the same fact as a confirmed "0 XP, no
--- row yet" answer, and this function no longer conflates the two. On
--- total failure: if a previous cached total already exists for this
--- citizenid (i.e. an earlier call this session already confirmed one),
--- it is KEPT, unchanged — never reset to 0. If no previous total exists
--- (the common case: this is this citizenid's first load this session,
--- exactly like the certification cache's own common case), K9XP[citizenid]
--- is left COMPLETELY UNSET rather than written as `0` — the RETURN value
--- below still degrades to a best-effort `0` for THIS call's own immediate
--- display use (ResolveTier/PushTierSnapshot need a real number right now,
--- and the base tier is the correct, most-conservative display default —
--- see GetXPTier's own doc comment on "an unresolved cache entry can only
--- ever under-grant, never over-grant"), but that guessed value is
--- DELIBERATELY never persisted into K9XP itself, so a later successful
--- retry, reconnect, or the bounded resync sweep below can still tell "we
--- do not know yet" apart from "we confirmed zero" and correct the real
--- cache without first having to un-confirm a fake confirmation.
--- @param citizenid string
--- @return number xp -- the best currently-known total for immediate
--- display use: freshly confirmed, retained from a previous confirmation,
--- or a best-effort `0` when nothing is known at all (that last case is
--- NEVER written into K9XP itself — see doc comment above).
local function LoadXPForCitizenid(citizenid)
    local queryOk, xpOrErr = PcallWithBoundedRetry(
        function() return K9Store.XP_Get(citizenid) end,
        XP_LOAD_RETRY_ATTEMPTS, XP_LOAD_RETRY_BACKOFF_MS
    )

    if not queryOk then
        local previous = K9XP[citizenid]
        XPLoadUnresolved[citizenid] = true

        if previous ~= nil then
            print((
                '[John-K9] progression: XP CHECK FAILED for citizenid=%s after %d attempt(s): %s -- ' ..
                'this is NOT a confirmed 0-XP reset. KEEPING the previous cached total (%d XP) rather than ' ..
                'dropping this citizenid back to the base tier. A bounded resync sweep will keep retrying ' ..
                'this citizenid automatically.'
            ):format(citizenid, XP_LOAD_RETRY_ATTEMPTS, tostring(xpOrErr), previous))
            return previous
        end

        print((
            '[John-K9] progression: XP CHECK FAILED for citizenid=%s after %d attempt(s): %s -- no ' ..
            'previous cached total exists, so nothing is being written to the cache (left UNSET, never a ' ..
            'manufactured confirmed 0). This citizenid displays at the base tier for THIS session only, ' ..
            'until the resync sweep or a reconnect confirms their real total -- their persisted XP in the ' ..
            'database is unaffected either way (AwardXP writes a delta, never this cached total).'
        ):format(citizenid, XP_LOAD_RETRY_ATTEMPTS, tostring(xpOrErr)))
        return 0 -- best-effort DISPLAY value only -- K9XP[citizenid] is deliberately left unset, never written as 0
    end

    XPLoadUnresolved[citizenid] = nil
    K9XP[citizenid] = xpOrErr or 0 -- no row yet = 0 XP / base tier, same as k9_certifications' "no active cert row" = false
    return K9XP[citizenid]
end

--- Copies a Config.XPTiers-shaped entry (xp/label/speedMultiplier/
--- scentRangeMultiplier) into a fresh table — identical shape/purpose to
--- server/exports.lua's own `ShallowCopyTier`, duplicated here rather than
--- shared, since this file has no import mechanism to reach that one.
--- ResolveTier above deliberately returns the SAME Config.XPTiers[n] table
--- object (by reference) for every citizenid whose xp falls in one tier's
--- bracket (see that function's own doc comment) — handing that reference
--- out in an outbound event payload would let an external resource's
--- handler mutate `tier.speedMultiplier` and corrupt movement speed for
--- every K9 in that tier, server-wide, for the rest of this resource's
--- uptime. Always copy before it leaves this file via FireOutboundEvent.
--- @param tier table
--- @return table copy
local function CopyTier(tier)
    local copy = {}
    for key, value in pairs(tier) do
        copy[key] = value
    end
    return copy
end

--- GAP 1 CLOSURE (owner-directed "god over that tablet ... over everything
--- related to that K9" pass, server/k9profiles.lua's own per-INDIVIDUAL-K9
--- override layer). Composes `tier`'s own speedMultiplier/scentRangeMultiplier/
--- medkitCooldownMultiplier with `citizenid`'s LIVE individual override, if
--- any, into a FRESH COPY -- never the shared Config.XPTiers[n] reference
--- `tier` may hold (same defensive-copy requirement CopyTier's own doc
--- comment above already states; this function calls CopyTier itself so
--- every caller gets that guarantee for free).
---
--- RESOLUTION ORDER IS NOT RE-IMPLEMENTED HERE -- it is server/k9profiles.lua's
--- own GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE order (that file's
--- own header), consulted through its one resource-global seam,
--- `GetK9EffectiveMultipliers(citizenid)`, and forwarded verbatim. This
--- function's only job is turning that answer into a snapshot shape safe to
--- hand to `TriggerClientEvent`.
---
--- SOFT-GUARDED (`type(GetK9EffectiveMultipliers) == 'function'`), same
--- convention as every other cross-file dependency in this resource: when
--- server/k9profiles.lua is absent, or throws (pcall-wrapped — an override
--- lookup must never be able to crash a real tier push), this degrades to a
--- PLAIN COPY of `tier` with no override applied — byte-for-byte this
--- function's own pre-existing (pre-GAP-1) behavior. Even present-and-
--- healthy, a citizenid with no live override is unaffected: GetK9EffectiveMultipliers
--- itself already returns the plain tier-derived values for that case (its
--- own "STEP 3" only overwrites a field when an override row actually sets
--- it), so this is a strict, provably-safe WIDENING — never a narrowing —
--- of what a citizenid without any override ever saw pushed before this
--- pass.
---
--- LOAD ORDER: server/k9profiles.lua loads AFTER this file in
--- fxmanifest.lua's server_scripts list (that file's own requested
--- placement, "runtime-only soft dependency" on this file's own GetXPTier).
--- This is safe specifically BECAUSE this function is only ever called at
--- RUNTIME (from PushTierSnapshot below, itself only reachable from
--- AwardXP/AwardXPDirect/PlayerLoaded/the onResourceStart backfill loop, all
--- of which fire long after every server_scripts file has finished
--- loading) — never at either file's own file-load time. Matches this
--- resource's own established "runtime existence guard, not a load-order
--- assumption" convention (see fxmanifest.lua's own comment on
--- server/medkit.lua's ordering for the precedent).
--- @param citizenid any
--- @param tier table
--- @return table snapshot
local function BuildEffectiveTierSnapshot(citizenid, tier)
    local snapshot = CopyTier(tier)
    if type(citizenid) == 'string' and citizenid ~= '' and type(GetK9EffectiveMultipliers) == 'function' then
        local ok, effective = pcall(GetK9EffectiveMultipliers, citizenid)
        if ok and type(effective) == 'table' then
            if type(effective.speedMultiplier) == 'number' then snapshot.speedMultiplier = effective.speedMultiplier end
            if type(effective.scentRangeMultiplier) == 'number' then snapshot.scentRangeMultiplier = effective.scentRangeMultiplier end
            if type(effective.medkitCooldownMultiplier) == 'number' then snapshot.medkitCooldownMultiplier = effective.medkitCooldownMultiplier end
        end
    end
    return snapshot
end

--- Pushes an authoritative tier snapshot to a specific, currently-connected
--- player's client. UNBOUNDED-TRAP FIX (this pass, closing the gap
--- client/progression.lua's own header names verbatim -- "AN UNBOUNDED
--- TRAP" -- and its "THE EXACT SERVER-SIDE CHANGE THIS DEPENDS ON" section
--- specifies exactly this edit): this function ALWAYS sends now -- it used
--- to `if not Config.Features.XPProgression then return end` before ever
--- calling TriggerClientEvent, a hard no-op that withheld the payload
--- entirely while the flag was off, which is exactly why an
--- already-connected client that had already applied a real
--- speedMultiplier/scentRangeMultiplier had NOTHING left to tell it the
--- flag had gone false -- no restart, no reconnect, and the resource's own
--- "flag off means genuinely inert" invariant silently broken for that
--- session. Fixed the same way server/wellbeing.lua's own "LIVE FEATURE
--- FLAG PUSH" section fixed the identical shape of bug for its own five
--- flags: the flag's CURRENT value now rides along on the SAME payload
--- (`snapshot.live`) rather than being enforced by withholding the
--- payload. `BuildEffectiveTierSnapshot` already returns a fresh
--- `CopyTier`-derived table on every call (never a live reference into
--- Config.XPTiers[n]), so writing `.live` onto it here cannot corrupt a
--- shared tier entry for any other citizenid. client/progression.lua's own
--- `LiveXPProgressionEnabled`/`CachedXPTierSpeedMultiplier` reset logic is
--- what actually turns `.live = false` into "stop applying the buff" --
--- this function's only job is to stop withholding that field. The K9XP
--- cache itself is still warmed/kept in sync regardless of the flag
--- (cheap, and avoids losing real accumulated progress data just because
--- the feature is temporarily toggled off) -- unchanged by this pass.
---
--- GAP 1 CLOSURE: `citizenid` is a NEW required parameter, this pass (every
--- call site below updated in the SAME change) — needed so this function can
--- ask server/k9profiles.lua whether THIS specific K9 carries a live
--- individual override before the snapshot goes out. See
--- BuildEffectiveTierSnapshot's own doc comment immediately above for the
--- full composition contract; this function's own behavior is otherwise
--- completely unchanged (same event name, same target-only delivery —
--- never a broadcast).
--- @param targetSrc number
--- @param citizenid string
--- @param tier table
local function PushTierSnapshot(targetSrc, citizenid, tier)
    local snapshot = BuildEffectiveTierSnapshot(citizenid, tier)
    snapshot.live = Config.Features.XPProgression == true
    TriggerClientEvent('john-k9:client:xpTierChanged', targetSrc, snapshot)
end

--- GAP 1 CLOSURE, THE PIECE THAT MAKES THIS ACTUALLY LIVE (not merely
--- "exposed and tested") -- resource-global, exposed specifically for
--- server/k9profiles.lua's own k9ProfileUpsert/k9ProfileReset tablet
--- callbacks to call immediately after a successful individual-override
--- write, so a high-command edit reaches an ALREADY-CONNECTED citizenid's
--- client THE MOMENT it is made, without waiting for that citizenid's next
--- real XP-tier crossing, reconnect, or a resource restart -- the three
--- ONLY other events that would otherwise ever cause a fresh snapshot to be
--- sent (PlayerLoaded, the onResourceStart backfill loop, and a tier
--- crossing inside AwardXP/AwardXPDirect). Without this function, an
--- override write is real in the database and in GetK9EffectiveMultipliers'
--- own answer, but an already-online citizenid's client would keep showing
--- their OLD speed until one of those three unrelated events happened to
--- fire next -- exactly the "set it to 3.0 and NOTHING HAPPENS" complaint
--- this whole pass exists to close, just deferred rather than fixed.
---
--- No-op (never throws, never notifies) when: `citizenid` cannot be
--- resolved to a CURRENTLY connected player (nothing to push to -- the
--- next real PlayerLoaded/backfill snapshot will already carry the
--- override once they do connect, since BuildEffectiveTierSnapshot
--- consults the live override on every call, not a cached copy), or
--- `citizenid` is not a non-empty string. UPDATED (unbounded-trap fix,
--- this pass): PushTierSnapshot no longer gates on the feature flag
--- itself -- see that function's own doc comment -- so this now always
--- reaches an online `citizenid` with a real `.live`-tagged snapshot
--- regardless of the flag's current value, same as every other caller of
--- PushTierSnapshot. Reuses PushTierSnapshot/BuildEffectiveTierSnapshot
--- verbatim -- this is a thin "resolve online source, then push" wrapper,
--- not a second implementation of the composition contract.
--- @param citizenid string
function PushXPTierSnapshotIfOnline(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    if type(onlineSrc) ~= 'number' then return end
    PushTierSnapshot(onlineSrc, citizenid, ResolveTier(K9XP[citizenid] or 0))
end

--- UNBOUNDED-TRAP FIX (this pass) -- resource-global, THE piece that makes
--- a runtime XPProgression toggle genuinely live for every ALREADY-ONLINE
--- K9, not merely for the next citizenid who happens to cross a tier,
--- reconnect, or wait for a restart. client/progression.lua's own header
--- names this exact function verbatim in its "THE EXACT SERVER-SIDE
--- CHANGE THIS DEPENDS ON" section -- this is that change, applied here as
--- specified. Called from server/runtimecontrol.lua's ApplyFeatureOverride
--- (the SINGLE mutation point for every path that changes
--- Config.Features.XPProgression at runtime) immediately after the flag
--- flips, behind a soft-dependency `type(...) == 'function'` guard --
--- see that file's own call site for why the guard, even though this
--- function is always defined in a real boot (same convention as
--- server/search.lua's `type(AwardXP) == 'function'`).
---
--- Deliberately WITHOUT PlayerLoaded's own onResourceStart backfill loop's
--- `if not Config.Features.XPProgression then return end` early exit --
--- unlike that loop (which exists to avoid a wasted LoadXPForCitizenid
--- query when the feature has never been enabled), this function's entire
--- reason to exist is to run precisely at the moment that flag may have
--- just gone false, so an early exit here would defeat its own purpose.
--- Same iteration shape as that backfill loop (GetPlayers() +
--- exports.qbx_core:GetPlayer(src)) -- not PushXPTierSnapshotIfOnline's
--- own GetPlayerByCitizenId-per-call shape, since this needs every
--- CURRENTLY connected source once, not a single citizenid lookup.
---
--- Uses the already-cached K9XP[citizenid] (falling back to 0 for a
--- citizenid never warmed this session, identical to every other read
--- site in this file) -- never a fresh database read -- so this stays
--- cheap even on a server with hundreds of connected officers; this is an
--- in-memory-only refresh of who gets told what, not a re-derivation of
--- anyone's real XP total.
--- @return nil
function RefreshXPProgressionLiveStateForAllOnline()
    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                local citizenid = Player.PlayerData.citizenid
                PushTierSnapshot(src, citizenid, ResolveTier(K9XP[citizenid] or 0))
            end
        end
    end
end

--- MOVED to server/events.lua (2026-08-25 cross-file cleanup pass): this
--- file's own `FireOutboundEvent` copy — byte-for-byte identical to the
--- five other copies that existed alongside it — is now the single shared
--- resource-global implementation in that file. See server/events.lua's
--- header for the full extraction writeup. Every call site below is
--- unchanged: same event names, arguments, order, and firing conditions.

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- header documents the 4-step resolution; step 1, Config.Features.XPProgression,
-- is already AwardXP's own first line below. Mirrors
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId shape
-- verbatim. NOT the same question as this file's own "COMPOSITION WITH THE
-- PERMISSION/FEATURE-CONTROL LAYER" section further up (whether reaching an
-- XP TIER should auto-grant a capability -- rejected there, unchanged by
-- this) -- this is the plain step-2/3 admission gate on AwardXP itself,
-- the one thing every other Config.Features entry in this resource already
-- gets and this file's own AAward entry point did not yet have. A block
-- here stops a specific citizenid from EARNING any further XP through this
-- entry point; it never touches XP already on their row, never freezes
-- their current tier display, and never affects any OTHER citizenid's
-- award in the same call graph (e.g. server/tenure.lua's own milestone
-- bonus already gates the K9-role party independently, before ever
-- reaching this function, via its own IsPartnershipTenureBonusPermittedForCitizenId).
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsXPProgressionPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.XPProgression') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.XPProgression == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.XPProgression') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Resource-global — see FILE-TO-FILE CONTRACT above for the full contract.
--- THE single server-authoritative XP-award entry point. Never trusts a
--- client-claimed XP delta or tier — `actionKey` selects a flat, config-owned
--- amount; there is no path for a caller (or, transitively, a client) to
--- specify an arbitrary amount.
--- RETURN VALUE (this pass): returns the actual `amount` applied on
--- success, or nothing (`nil` in a single-value context) if the award was
--- rejected for ANY reason (feature off, malformed citizenid, unknown
--- actionKey, unpayable amount, per-person block, rate floor, or the
--- shared mint budget). Purely additive — every existing caller ignores
--- the return value already, so this changes nothing for them. Added so
--- server/tenure.lua's milestone notification can say what a party
--- actually earned instead of assuming every call succeeds.
--- @param citizenid string
--- @param actionKey string -- a key in Config.XP.awards
--- @return number? amount
function AwardXP(citizenid, actionKey)
    if not Config.Features.XPProgression then return end -- real server-side no-op regardless of caller state, per DEVELOPER_REFERENCE.md §3
    if type(citizenid) ~= 'string' or citizenid == '' then return end -- defensive: never trust a malformed caller argument

    local amount = Config.XP.awards[actionKey]
    if type(amount) ~= 'number' then
        -- Defensive: an unknown actionKey is a CALLER bug (a typo'd string
        -- literal at a new call site), not a runtime condition to silently
        -- swallow — log it so it's visible in server console rather than
        -- silently granting 0 XP forever.
        print(('[John-K9] progression: AwardXP called with unknown actionKey %q for citizenid %s'):format(tostring(actionKey), citizenid))
        return
    end

    -- Value-range validation -- see ValidateXPAwardAmount's own doc comment
    -- for why this is clamp-and-warn, not an onResourceStart assert. A known
    -- actionKey with an unpayable amount (negative, or larger than the
    -- shared budget could ever cover) is treated as a silent no-op here,
    -- same as the unknown-actionKey branch above, except the warning (at
    -- most once per actionKey) names the value problem specifically rather
    -- than "unknown actionKey".
    amount = ValidateXPAwardAmount(actionKey, amount)
    if type(amount) ~= 'number' then return end

    -- PER-PERSON FEATURE CONTROL -- see IsXPProgressionPermittedForCitizenId
    -- above. Checked here, BEFORE AwardXPCooldown.Consume below -- no state
    -- has been touched yet at this point (same "pure entry guard" territory
    -- the rate-floor comment immediately below already claims for itself),
    -- so a blocked citizenid never burns so much as the 500ms rate-floor
    -- slot for an award that was always going to be refused. Silent no-op,
    -- matching every other AwardXP early-return above -- this is a
    -- server-internal accounting entry point with no caller expecting a
    -- response, not a player-facing request with a rejection message to show.
    if not IsXPProgressionPermittedForCitizenId(citizenid) then return end

    -- CHOKEPOINT-LEVEL RATE FLOOR — see AwardXPCooldown's own declaration
    -- comment above for the full reasoning/threshold justification. Gated
    -- AFTER the actionKey validity check above (a malformed/unknown-key call
    -- is already rejected and should not consume this budget), BEFORE any
    -- cache mutation or DB write below — this is a pure entry guard, no
    -- state has been touched yet if this returns early. Silent no-op on
    -- trip (consistent with every existing per-site cooldown's own "still on
    -- cooldown = quiet no-op" convention, e.g. server/tracking.lua's
    -- TrackArrivalReportCooldown), but logged — unlike those per-site
    -- cooldowns, a real player's own normal play can never trip this one
    -- (see threshold reasoning above), so a trip here is itself a signal
    -- worth surfacing to server console rather than staying silent forever.
    if not AwardXPCooldown.Consume(citizenid, actionKey, 500) then
        print(('[John-K9] progression: AwardXP rate floor tripped for citizenid %s actionKey %q -- this should never happen from genuine play; investigate the calling code path'):format(citizenid, actionKey))
        return
    end

    -- EIGHTH XP-FARM FIX -- see the XP_MINT_BUDGET_*/XPMintBudget
    -- declarations above this function for the full derivation and the
    -- fail-OPEN reasoning. Checked AFTER the actionKey-validity and
    -- per-(citizenid, actionKey) rate-floor checks above (an already-
    -- rejected call must never spend this shared budget either), BEFORE any
    -- cache/DB mutation below -- same "reject before touching state" order
    -- this function already follows throughout.
    -- `amount > 0` here (rather than merely `type(amount) == 'number'`) is
    -- ONLY ever false for a genuinely valid, currently-shipped 0-XP award
    -- now -- ValidateXPAwardAmount above already rejects every negative or
    -- over-cap amount outright (returns nil, which the earlier `if
    -- type(amount) ~= 'number' then return end` check has already turned
    -- into an early return), so `amount` reaching this line is guaranteed
    -- `>= 0` and `<= XP_MINT_BUDGET_CAP_XP`. This condition therefore exists
    -- purely to skip the budget bucket for a harmless 0-XP award (some
    -- callers legitimately use a 0-value actionKey as a placeholder -- this
    -- file's own test suite does), not as a safety backstop against a
    -- malformed config value reaching this math -- that risk is closed
    -- earlier, at the validation call above, not here.
    if XPMintBudgetEnabled and amount > 0 then
        local budgetNow = GetGameTimer()
        local bucket = XPMintBudget[citizenid]
        if not bucket then
            -- Starts at XP_MINT_BUDGET_STARTER_TOKENS -- NEITHER 0 NOR the
            -- full cap. See that constant's own declaration comment (and the
            -- XP_MINT_BUDGET_* section's "STARTING BALANCE" writeup above
            -- this function) for the full history: both other options were
            -- tried and rejected THIS SAME PASS after simulation showed each
            -- one broken in a different, serious way -- start-full re-opens
            -- a burst-doubling exploit that defeats this section's own
            -- >2-hour design goal; start-EMPTY-with-no-elapsed-time silently
            -- denies every citizenid's very first-ever AwardXP call, every
            -- session (caught live via tests/progression_spec.lua before
            -- this shipped). Do not change this back to either without
            -- re-reading that history first.
            bucket = { tokens = XP_MINT_BUDGET_STARTER_TOKENS, lastRefillAt = budgetNow }
            XPMintBudget[citizenid] = bucket
        else
            RefillMintBudget(bucket, budgetNow)
        end
        if bucket.tokens < amount then
            -- Silent no-op on trip -- same convention as every per-mechanic
            -- mint cooldown's own Consume-fails-silently posture. Unlike
            -- AwardXPCooldown's own trip above, this is the EXPECTED
            -- steady-state outcome for a citizenid genuinely farming at or
            -- near the combined ceiling, not a caller-bug signal -- logging
            -- every occurrence here would spam console under exactly the
            -- sustained-farming behavior this section exists to bound.
            return
        end
        bucket.tokens = bucket.tokens - amount
    end

    local oldXp = K9XP[citizenid] or 0
    local oldTier = ResolveTier(oldXp)

    local newXp = oldXp + amount
    -- Update the in-memory cache SYNCHRONOUSLY, before the DB write below —
    -- DEVELOPER_REFERENCE.md#xp-schema §5: correctness of the applied
    -- gameplay effect (tier-derived scentRangeMultiplier/speedMultiplier) depends only
    -- on this line, never on DB round-trip latency.
    K9XP[citizenid] = newXp

    -- Non-blocking, atomic UPSERT — never delays or risks whatever
    -- server-side success path just called this function. `amount` (the
    -- delta), not `newXp` (the new total), is the second bound parameter —
    -- `VALUES(xp)` on the ON DUPLICATE KEY branch refers to the
    -- just-inserted delta, giving a single-statement atomic
    -- increment-or-create with no separate SELECT-then-UPDATE round trip
    -- (DEVELOPER_REFERENCE.md#xp-schema §4). CONCURRENCY: this is safe
    -- against a lost update even with several of these in flight at once for
    -- the SAME citizenid (e.g. two award paths landing in the same tick) —
    -- MySQL/MariaDB serializes concurrent UPSERTs against the same unique
    -- key via row-level locking, and `xp = xp + VALUES(xp)` is evaluated
    -- inside that same locked, single statement, so there is no read-then-
    -- write gap for a second statement to race into. The in-memory K9XP
    -- cache write above is ALSO safe under concurrency for a more basic
    -- reason: FXServer's Lua VM is single-threaded/cooperatively
    -- scheduled, and AwardXP contains no `await`/yield point before that
    -- line, so two calls for the same citizenid can never interleave
    -- between the read of `oldXp` and the write of `K9XP[citizenid]`.
    --
    -- SILENT-FAILURE FIX, this pass (audit finding): this used to be
    -- `pcall(MySQL.insert, [[...]], {...})` — a fire-and-forget call with NO
    -- callback at all. That pcall is decorative, not protective: oxmysql's
    -- non-`.await` entry point (server/cooldowns.lua's sibling files'
    -- comments call this "Non-blocking (`MySQL.insert(...)` WITHOUT
    -- `.await`)") returns to the caller the instant the query is HANDED OFF
    -- to oxmysql's own async worker, before the query has actually run
    -- against the database — a real failure (a missing `k9_progression`
    -- table from an unapplied migration, a constraint violation, a
    -- transient connection drop) surfaces later, asynchronously, entirely
    -- outside this pcall's stack frame. Worse, oxmysql only forwards a
    -- query's error into a caller-supplied callback when
    -- `return_callback_errors` is enabled (fxmanifest.lua's own
    -- `mysql_option` metadata — grepped this resource's fxmanifest.lua
    -- before writing this comment: not set anywhere), which the original
    -- callback-less call never opted into either way. Net effect: a broken
    -- `k9_progression` table could make every single award silently fail to
    -- persist forever, while every in-memory/gameplay effect (tier bonuses,
    -- the xpTierChanged push) kept working normally — completely invisible
    -- until someone happened to compare a player's real DB row against
    -- their session's tier. FIXED by moving the write into its own
    -- CreateThread and using `MySQL.insert.await` inside it: `.await`
    -- (server/oxmysql's own promise-based wrapper) unconditionally requests
    -- error propagation regardless of the `return_callback_errors` resource
    -- metadata setting, so a real query failure now raises a genuine Lua
    -- error that this pcall actually catches and logs. The CreateThread
    -- wrapper is what keeps this non-blocking for AwardXP's own caller:
    -- `.await` yields the coroutine it runs IN, and running it inside a
    -- freshly spawned thread means the coroutine that suspends is this
    -- write's own, never the search/tracking/combat/tenure call site's own
    -- execution path — AwardXP itself still returns immediately either way.
    CreateThread(function()
        local insertOk, insertErr = pcall(K9Store.XP_UpsertAdd, citizenid, amount)
        if not insertOk then
            print(('[John-K9] progression: AwardXP UPSERT failed for citizenid %s -- %d XP for actionKey %q was NOT persisted to k9_progression (in-memory tier/session effects already applied and are unaffected): %s'):format(citizenid, amount, actionKey, tostring(insertErr)))
        end
    end)

    local newTier = ResolveTier(newXp)
    if newTier ~= oldTier then
        -- Outbound integration event (server/exports.lua's EVENT CONTRACT
        -- §6) — fired here, at the exact crossing this branch already
        -- exists to detect, with FRESH COPIES of both tiers (never the
        -- shared Config.XPTiers[n] reference newTier/oldTier actually hold
        -- — see CopyTier's own doc comment above for exactly why that
        -- matters). Deliberately fired regardless of whether `citizenid`
        -- currently resolves to an online player, unlike the client-facing
        -- PushTierSnapshot call below it: this is a citizenid-keyed
        -- integration signal for OTHER resources, not a client HUD push, so
        -- there is no reason to suppress it just because this K9's own
        -- client happens not to be connected right now (mirrors
        -- server/certifications/'s certificationRevoked event, which
        -- likewise fires for both online and offline targets).
        FireOutboundEvent('john-k9:events:xpTierReached', citizenid, CopyTier(newTier), CopyTier(oldTier))

        -- Only push the CLIENT-facing snapshot if the citizenid resolves to
        -- a CURRENTLY connected player — every real call site today only
        -- ever awards XP to the player who just performed the action
        -- (always online at call time), but this stays generic
        -- (GetPlayerByCitizenId, not an assumed `source`) rather than
        -- asserting that invariant, mirroring server/certifications/'s
        -- ForceDetachLeashIfOnline's own "resolve by citizenid, no-op if
        -- not currently online" shape.
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            PushTierSnapshot(onlineSrc, citizenid, newTier)
        end
    end

    -- RETURN VALUE, ADDED (tenure-notification honesty pass, this pass) --
    -- every early `return` above this point returns nothing (bare
    -- `return`), which Lua callers already see as `nil` in a single-value
    -- context -- so this addition is purely ADDITIVE, not a behavior change
    -- for any existing caller that ignores the return value (every current
    -- one does). `amount` is the real, validated XP just applied to
    -- `K9XP[citizenid]` above -- server/tenure.lua's own
    -- CheckTenureMilestonesForK9 is the first caller that actually reads
    -- this, so it can tell a K9-role party what they genuinely earned this
    -- crossing instead of assuming the call always succeeds.
    -- @return number amount -- the XP actually applied (never reached if any check above returned early/nil)
    return amount
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- HANDLER XP. Identical four-step shape to
-- IsXPProgressionPermittedForCitizenId above (config.lua's own
-- Config.FeatureControl header documents the 4-step resolution; step 1,
-- Config.Features.HandlerXPProgression, is already AwardHandlerXP's own
-- first line below) -- mirrors server/pursuitsprint.lua's
-- IsPursuitSprintPermittedForCitizenId shape verbatim, same as its K9-XP
-- sibling. A block here stops a specific citizenid from EARNING any
-- further HANDLER XP through this entry point; it never touches handler
-- XP already on their row, and never affects the SAME citizenid's own K9
-- XP (a separate total, gated by its own separate `block.XPProgression`
-- check above) or any OTHER citizenid's award.
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsHandlerXPProgressionPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- IsXPProgressionPermittedForCitizenId's own identical comment above.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.HandlerXPProgression') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.HandlerXPProgression == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.HandlerXPProgression') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

-- ======================================================================
-- HANDLER TIER CLIENT VISIBILITY (this pass, coder-backend -- "a handler
-- cannot see their own rank or XP anywhere" gap closure). Confirmed by
-- direct grep before writing any of this: HandlerXP/GetHandlerXPTier were
-- tracked and read server-side (GetHandlerXPTierMedkitCooldownMs/
-- GetHandlerXPTierKennelDeployCooldownMs, server/tablet.lua's roster
-- reads) but NOTHING ever reached the handler's own client -- unlike the
-- K9 side, which has had PushTierSnapshot/xpTierChanged since Phase 4.
-- Mirrors PushTierSnapshot/RefreshXPProgressionLiveStateForAllOnline's own
-- shape for the K9 side as closely as this second ladder deserves,
-- including the 144a432 "never withhold the payload, tag `.live` instead"
-- fix -- see PushTierSnapshot's own doc comment above for the full
-- "AN UNBOUNDED TRAP" writeup this follows verbatim.
--
-- WHY A SEPARATE EVENT, NOT A NEW FIELD ON xpTierChanged: the K9 and
-- handler ladders are independent totals/tiers for the same citizenid
-- (config.lua's own Config.HandlerXPTiers header, "why a second ladder,
-- not a second reading") -- collapsing both into one event would force
-- every existing xpTierChanged consumer (client/progression.lua) to start
-- ignoring fields it does not own, and would fire that event for a
-- citizenid whose K9 tier never changed at all. Kept as its own event,
-- the same "one event per independent concern" precedent this resource
-- already follows for wellbeing/certification/etc.
--
-- PAYLOAD SHAPE -- 'john-k9:client:handlerXpTierChanged':
--     { totalXp: number, tier: table, live: boolean }
-- `tier` is a CopyTier()'d snapshot of the resolved Config.HandlerXPTiers
-- entry (xp = that TIER'S OWN THRESHOLD, label, and whichever optional
-- multiplier fields that tier carries) -- the SAME shape xpTierChanged's
-- own payload already uses for the K9 side. `totalXp` is the field this
-- event carries that xpTierChanged does not: the citizenid's real,
-- persisted accumulated handler_xp total (HandlerXP[citizenid]) -- needed
-- because a tier object's own `xp` field is a THRESHOLD, not a running
-- total, and "the handler's own XP total" was this pass's own explicit
-- requirement, not just "their rank".
--
-- SENT TO THE HANDLER'S OWN CLIENT ONLY -- never broadcast, matching
-- PushTierSnapshot's own delivery discipline.
-- ======================================================================

--- @param targetSrc number
--- @param citizenid string
--- @param totalXp number
--- @param tier table
local function PushHandlerTierSnapshot(targetSrc, citizenid, totalXp, tier)
    TriggerClientEvent('john-k9:client:handlerXpTierChanged', targetSrc, {
        totalXp = totalXp,
        tier = CopyTier(tier),
        -- UNBOUNDED-TRAP DISCIPLINE (144a432, mirrored exactly): ALWAYS
        -- sent, regardless of the flag's current value -- withholding this
        -- while the flag is off is exactly the bug that commit fixed for
        -- the K9 side. The flag's CURRENT value rides along instead, so a
        -- client keeping any handler-rank display up across a runtime
        -- toggle can hide/gray it out immediately rather than staying
        -- stuck showing a rank that no longer means anything.
        live = Config.Features.HandlerXPProgression == true,
    })
end

--- UNBOUNDED-TRAP FIX, HANDLER SIDE -- mirrors
--- RefreshXPProgressionLiveStateForAllOnline above (same iteration shape,
--- same in-memory-only/no-DB-read posture, same "runs precisely at the
--- moment the flag may have just gone false" reasoning) -- see that
--- function's own doc comment for the full writeup, not repeated here.
---
--- INTEGRATION NOTE FOR WHOEVER OWNS server/runtimecontrol.lua's
--- ApplyFeatureOverride (NOT edited by this pass -- that file is outside
--- this pass's own edit scope): that function's existing comment on
--- HandlerXPProgression ("deliberately gets NO equivalent hook here...
--- there is no client-side tier cache... for this flag to leave stranded")
--- was accurate ONLY because no client push existed yet for this ladder.
--- Now that PushHandlerTierSnapshot exists, that reasoning no longer
--- holds -- an already-connected handler who already received a
--- `live=true` snapshot (their own login push, or a real tier crossing)
--- would be left stranded showing it forever if
--- `Config.Features.HandlerXPProgression` is later flipped off at
--- runtime, exactly the K9-side bug 144a432 fixed. ApplyFeatureOverride
--- needs one more branch, symmetric with its existing XPProgression one:
---     if name == 'HandlerXPProgression' and type(RefreshHandlerXPProgressionLiveStateForAllOnline) == 'function' then
---         RefreshHandlerXPProgressionLiveStateForAllOnline()
---     end
--- and that file's own stale comment above HandlerXPProgression's case
--- needs updating to match. Flagged here, not silently left for a future
--- reader to rediscover, since this file cannot make that edit itself
--- under this pass's own scope.
--- @return nil
function RefreshHandlerXPProgressionLiveStateForAllOnline()
    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                local citizenid = Player.PlayerData.citizenid
                local totalXp = HandlerXP[citizenid] or 0
                PushHandlerTierSnapshot(src, citizenid, totalXp, ResolveHandlerTier(totalXp))
            end
        end
    end
end

--- Resource-global -- HANDLER XP (Config.Features.HandlerXPProgression).
--- Mirrors AwardXP above as closely as this second, HANDLER-facing total
--- deserves -- the SAME order of checks (feature flag, malformed-argument
--- guard, unknown-actionKey log, per-person block/grant gate, THE SAME
--- 500ms-per-(citizenid, actionKey) AwardXPCooldown chokepoint rate floor
--- AwardXP already enforces -- shared, not a second NewNestedCooldown
--- instance, which is safe because Config.HandlerXP.awards' actionKey
--- strings (handlerCertifyK9, handlerTreatK9, ...) are a disjoint
--- namespace from Config.XP.awards' own (searchContrabandFound,
--- takedownSuccess, ...), so a K9 award and a handler award for the same
--- citizenid can never collide on the same (citizenid, actionKey) key --
--- and, per this task's own explicit requirement, THE SAME shared
--- cross-mechanic XP_MINT_BUDGET_*/XPMintBudget token bucket AwardXP
--- already draws from, keyed by the SAME citizenid, never a second,
--- independent bucket. A citizenid grinding both a K9 role and a handler
--- role at once still only ever mints 3,600 XP/hr COMBINED across both
--- totals, never 3,600 of each -- see this file's own EIGHTH-XP-FARM-FIX
--- header for why that budget exists and why splitting it per-mechanic-
--- family would reopen the exact compound-farm gap that section closes.
---
--- CORRECTED, THIS PASS ("a handler cannot see their own rank or XP
--- anywhere" gap closure) -- this doc comment used to claim AwardHandlerXP
--- was "DELIBERATELY SIMPLER THAN AwardXP IN ONE RESPECT: no tier-crossing
--- outbound event and no client-facing push," reasoning that neither wired
--- effect field (medkitTreatCooldownMultiplier/kennelDeployCooldownMultiplier)
--- has a client-visible cached value that could go stale. That reasoning
--- was correct for THOSE TWO FIELDS and remains true of them -- but it
--- silently generalized to "no client push is needed at all," which
--- stopped being true the moment anyone wanted to actually SHOW a handler
--- their own rank/XP: there was no server->client channel to read it from,
--- an oversight independent of the two cooldown-multiplier fields' own
--- correct reasoning. FIXED here: this function now pushes
--- 'john-k9:client:handlerXpTierChanged' to the handler's OWN client
--- (never broadcast) on a real tier crossing, via PushHandlerTierSnapshot
--- immediately below -- see that function's own doc comment for the exact
--- payload shape and the "why a separate event, not a new xpTierChanged
--- field" reasoning. The PlayerLoaded/onResourceStart-backfill call sites
--- (further down this file) push the SAME shape on login/restart, so an
--- offline tier crossing (e.g. a tenure milestone paid while the handler
--- was logged out is not currently possible -- server/tenure.lua requires
--- both parties online -- but a future award path might not share that
--- constraint) is still caught up on next login, mirroring PushTierSnapshot's
--- own K9-side contract exactly.
---
--- RETURN VALUE (this pass, same addition as AwardXP above): returns the
--- actual `amount` applied on success, or nothing (`nil`) if the award was
--- rejected for any reason. Purely additive for every existing caller.
--- Added for the SAME reason as AwardXP's own identical addition:
--- server/tenure.lua's milestone notification needs to know what the
--- handler-role party actually got, not assume the call always succeeds.
---
--- Persistence uses K9Store.HandlerXP_UpsertAdd's own SafeWrite (boolean)
--- contract, DELIBERATELY UNLIKE AwardXP's own K9Store.XP_UpsertAdd call
--- (which raw-mirrors MySQL.insert.await and relies on ITS OWN pcall to
--- catch a thrown error) -- see that accessor's own doc comment
--- (server/datastore.lua) for why. Still non-blocking via the same
--- CreateThread wrapper AwardXP uses, for the identical reason (`.await`
--- yields the coroutine it runs in; running it inside a freshly spawned
--- thread keeps AwardHandlerXP itself returning immediately to its own
--- caller regardless).
--- @param citizenid string
--- @param actionKey string -- a key in Config.HandlerXP.awards
--- @return number? amount
function AwardHandlerXP(citizenid, actionKey)
    if not Config.Features.HandlerXPProgression then return end -- real server-side no-op regardless of caller state, per DEVELOPER_REFERENCE.md §3
    if type(citizenid) ~= 'string' or citizenid == '' then return end -- defensive: never trust a malformed caller argument

    local handlerAwards = type(Config.HandlerXP) == 'table' and Config.HandlerXP.awards or nil
    local amount = type(handlerAwards) == 'table' and handlerAwards[actionKey] or nil
    if type(amount) ~= 'number' then
        -- Defensive: an unknown actionKey is a CALLER bug (a typo'd string
        -- literal at a new call site), not a runtime condition to silently
        -- swallow -- log it so it's visible in server console rather than
        -- silently granting 0 handler XP forever. Mirrors AwardXP's own
        -- identical guard.
        print(('[John-K9] progression: AwardHandlerXP called with unknown actionKey %q for citizenid %s'):format(tostring(actionKey), citizenid))
        return
    end

    -- Value-range validation -- see ValidateHandlerAwardAmount's own doc
    -- comment for why this is clamp-and-warn, not an onResourceStart
    -- assert. A known actionKey with an unpayable amount (negative, or
    -- larger than the shared budget could ever cover) is treated as a
    -- silent no-op here, same as the unknown-actionKey branch above,
    -- except the warning (at most once per actionKey) names the value
    -- problem specifically rather than "unknown actionKey".
    amount = ValidateHandlerAwardAmount(actionKey, amount)
    if type(amount) ~= 'number' then return end

    -- PER-PERSON FEATURE CONTROL -- see IsHandlerXPProgressionPermittedForCitizenId
    -- above. Checked before any rate-floor/budget state is touched, same
    -- "pure entry guard" discipline AwardXP's own identical check follows.
    if not IsHandlerXPProgressionPermittedForCitizenId(citizenid) then return end

    -- CHOKEPOINT-LEVEL RATE FLOOR -- reuses AwardXPCooldown, THE SAME
    -- NewNestedCooldown(500) instance AwardXP consumes above -- see this
    -- function's own doc comment for why sharing it is safe (disjoint
    -- actionKey namespaces between the two award tables).
    if not AwardXPCooldown.Consume(citizenid, actionKey, 500) then
        print(('[John-K9] progression: AwardHandlerXP rate floor tripped for citizenid %s actionKey %q -- this should never happen from genuine play; investigate the calling code path'):format(citizenid, actionKey))
        return
    end

    -- EIGHTH XP-FARM FIX, SHARED -- see this function's own doc comment:
    -- THE SAME XPMintBudget bucket AwardXP already spends against, keyed by
    -- the SAME citizenid. Logic below is byte-identical to AwardXP's own
    -- budget block (including the defensive `amount > 0` re-check for the
    -- identical non-positive-amount footgun described there) -- kept as a
    -- second copy rather than factored into one shared helper because
    -- AwardXP's own copy is deliberately inlined for the same reason
    -- (this file's established style keeps each award entry point
    -- self-contained and independently auditable rather than routing both
    -- through one more layer of indirection for two call sites).
    if XPMintBudgetEnabled and amount > 0 then
        local budgetNow = GetGameTimer()
        local bucket = XPMintBudget[citizenid]
        if not bucket then
            bucket = { tokens = XP_MINT_BUDGET_STARTER_TOKENS, lastRefillAt = budgetNow }
            XPMintBudget[citizenid] = bucket
        else
            RefillMintBudget(bucket, budgetNow)
        end
        if bucket.tokens < amount then
            -- Silent no-op on trip -- same convention as AwardXP's own
            -- identical budget-exhaustion path.
            return
        end
        bucket.tokens = bucket.tokens - amount
    end

    local oldXp = HandlerXP[citizenid] or 0
    local oldTier = ResolveHandlerTier(oldXp)
    local newXp = oldXp + amount
    -- Update the in-memory cache SYNCHRONOUSLY, before the DB write below --
    -- same correctness reasoning as AwardXP's own K9XP write.
    HandlerXP[citizenid] = newXp
    local newTier = ResolveHandlerTier(newXp)

    -- Non-blocking write via K9Store.HandlerXP_UpsertAdd's own SafeWrite
    -- (boolean) contract -- see this function's own doc comment for why
    -- this differs from AwardXP's own pcall-around-a-throwing-call shape.
    CreateThread(function()
        local persisted = K9Store.HandlerXP_UpsertAdd(citizenid, amount)
        if not persisted then
            print(('[John-K9] progression: AwardHandlerXP UPSERT failed for citizenid %s -- %d XP for actionKey %q was NOT persisted to k9_progression.handler_xp (in-memory handler-tier/session effects already applied and are unaffected)'):format(citizenid, amount, actionKey))
        end
    end)

    -- CLIENT VISIBILITY (this pass) -- see PushHandlerTierSnapshot's own
    -- doc comment above for the full payload/discipline writeup. Only on a
    -- REAL tier crossing, only to a CURRENTLY connected player, mirroring
    -- AwardXP's own identical "resolve by citizenid, no-op if not
    -- currently online" shape -- an offline crossing is caught up by this
    -- citizenid's own next PlayerLoaded push instead (see that call site
    -- further down this file).
    if newTier ~= oldTier then
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            PushHandlerTierSnapshot(onlineSrc, citizenid, newXp, newTier)
        end
    end

    return amount
end

--- Awards an EXPLICIT XP amount, for /k9givexp only.
---
--- This deliberately breaks the invariant AwardXP above exists to protect.
--- AwardXP takes an actionKey and looks the amount up in config precisely so
--- that no caller -- and therefore, transitively, no client -- can ever name
--- an arbitrary number. Weakening AwardXP to accept an amount would have
--- removed that guarantee for every one of its callers, so this is a
--- separate entry point rather than a new parameter.
---
--- What bounds it instead:
---   * server/highcommand.lua is the ONLY caller, and re-resolves the
---     caller's rank server-side on every invocation.
---   * the amount is clamped to Config.HighCommand.maxXpPerGrant there.
---   * every grant is logged with granter, target, amount and new total.
---
--- ALSO deliberately NOT subject to IsXPProgressionPermittedForCitizenId
--- (AwardXP's own per-person block/grant gate, above) -- stated explicitly,
--- per this task's own "a decision, not an accident" requirement, not an
--- oversight matching AwardXP's own gap this pass closed. `block.XPProgression`
--- exists to stop a citizenid from FARMING XP through ordinary gameplay;
--- /k9givexp is the opposite of farming -- a deliberate, rank-gated, capped,
--- fully-audited human decision to hand someone a specific amount. Gating it
--- on the same block would mean high command could no longer manually
--- correct/compensate the exact citizenid they most plausibly WANT to grant
--- to (someone already flagged and restricted), which is a strictly worse
--- outcome than today's "the manual override always works, and is always in
--- the log" posture. If a future pass disagrees, that is a product decision
--- for whoever owns server/highcommand.lua's own header, not a silent
--- one-line addition here.
---
--- Deliberately NOT subject to AwardXPCooldown or the shared XP mint budget.
--- Those exist to bound how fast a PLAYER can farm XP through gameplay; a
--- high-command grant is an audited administrative act, and silently
--- swallowing one because a farming budget was exhausted would look to the
--- officer like the command simply did nothing.
---
--- @param citizenid string
--- @param amount number a positive integer; fractional values are floored
--- @param reason string? free-text, for the failure log only
--- @return number|nil newTotal nil if the award was rejected
function AwardXPDirect(citizenid, amount, reason)
    if not Config.Features.XPProgression then return nil end
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    -- amount ~= amount catches NaN, which would otherwise poison the total.
    if type(amount) ~= 'number' or amount ~= amount or amount <= 0 then return nil end
    if amount == math.huge then return nil end
    amount = math.floor(amount)

    local oldXp = K9XP[citizenid] or 0
    local oldTier = ResolveTier(oldXp)
    local newXp = oldXp + amount
    K9XP[citizenid] = newXp

    -- Non-blocking, matching AwardXP's own persistence shape: a fresh thread
    -- so the .await is real (and so the pcall around it can actually catch a
    -- DB error -- a pcall around a non-await MySQL call catches nothing,
    -- because the worker runs the query long after the pcall frame is gone).
    CreateThread(function()
        local ok, err = pcall(K9Store.XP_UpsertAdd, citizenid, amount)
        if not ok then
            print(('[John-K9] progression: AwardXPDirect UPSERT failed for %s -- %d XP (%s) granted in memory but NOT persisted: %s')
                :format(citizenid, amount, tostring(reason), tostring(err)))
        end
    end)

    local newTier = ResolveTier(newXp)
    if newTier ~= oldTier then
        FireOutboundEvent('john-k9:events:xpTierReached', citizenid, CopyTier(newTier), CopyTier(oldTier))
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            PushTierSnapshot(onlineSrc, citizenid, newTier)
        end
    end

    return newXp
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then return end

    local xp = LoadXPForCitizenid(citizenid)

    -- Authoritative snapshot on every login, unconditionally (not just on a
    -- "change" from some prior value) — a freshly connected client has no
    -- prior client-side tier state to diff against at all, so there is
    -- nothing to compare here. See client/progression.lua's own
    -- xpTierChanged handler for how it avoids treating this as a fresh
    -- level-up notification.
    local targetSrc = Player.PlayerData.source
    if type(targetSrc) == 'number' then
        PushTierSnapshot(targetSrc, citizenid, ResolveTier(xp))
    end

    -- HANDLER XP cache warm -- same "keep it warmed/kept in sync regardless
    -- of the flag" posture as LoadXPForCitizenid's own call two lines above
    -- (cheap, one already-happening login-time query, and avoids a citizenid
    -- with real accumulated handler_xp reading back as 0 for the rest of
    -- this session just because AwardHandlerXP has not fired yet this
    -- session -- AwardHandlerXP's own `HandlerXP[citizenid] or 0` read would
    -- otherwise silently treat an un-warmed cache as "starts from zero,"
    -- exactly the same class of staleness LoadXPForCitizenid already exists
    -- to prevent for the K9 side).
    --
    -- CLIENT PUSH, ADDED THIS PASS -- see PushHandlerTierSnapshot's own doc
    -- comment for the full payload/discipline writeup. UNCONDITIONAL, same
    -- as the K9-side push two lines above -- NOT gated on
    -- Config.Features.HandlerXPProgression (that flag's current value rides
    -- along in the payload's own `.live` field instead, per this pass's own
    -- "do not gate the push itself on the flag" requirement). This is what
    -- makes "a handler who is offline when they cross a rank sees it on
    -- next login" true: LoadHandlerXPForCitizenid always re-reads the REAL
    -- persisted total fresh from the database, so whatever crossed while
    -- this citizenid was offline is already reflected in the very first
    -- snapshot they receive this session.
    local handlerXp = LoadHandlerXPForCitizenid(citizenid)
    if type(targetSrc) == 'number' then
        PushHandlerTierSnapshot(targetSrc, citizenid, handlerXp, ResolveHandlerTier(handlerXp))
    end
end)

-- STRUCTURAL GAP backfill (mirrors server/main.lua's identical backfill for
-- Certifications, same rationale restated here for THIS cache): a
-- `/restart john-k9` while players are already online does not re-fire
-- PlayerLoaded for them, so their K9XP entry would sit at the default
-- ResolveTier(0) baseline (silently losing their real tier's scent/speed
-- bonus for the remainder of their session) until their next reconnect —
-- unless this loop re-warms the cache immediately at resource start.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- PERFORMANCE FIX (QA pass): AwardXP (this file's ONLY write path to
    -- `k9_progression`) is itself a no-op whenever Config.Features.XPProgression
    -- is false, so on a server where the flag has never been enabled no
    -- citizenid can have a real row to warm here -- this loop was still
    -- running a real MySQL.scalar.await per connected player
    -- (LoadXPForCitizenid) for a cache PushTierSnapshot immediately
    -- discards anyway (it's gated on the same flag). Gated here the same
    -- way the write path already is.
    --
    -- KNOWN TRADE-OFF, disclosed rather than silently accepted: GetXP/
    -- GetXPTier (server/exports.lua, and this file's own doc comments) are
    -- deliberately NOT gated on this flag, so an operator who enables it,
    -- lets a citizenid earn real XP, disables it again, then restarts this
    -- resource while that citizenid is still online reintroduces this
    -- loop's own original "cache sits at 0 until next reconnect" gap for
    -- that narrow case. Accepted here for the same reason
    -- server/partnership.lua's identical-shape fix accepts the mirror
    -- case: earning XP at all already required the flag to have been
    -- deliberately turned on once; the common "flag has always been
    -- false" default-install case this fix targets cannot exhibit it.
    --
    -- WIDENED (HANDLER XP pass, coder-backend) to also cover
    -- Config.Features.HandlerXPProgression -- this loop must not return
    -- early just because XPProgression is off if HandlerXPProgression is
    -- independently on (and vice versa): the two are separate flags gating
    -- two separate caches (K9XP/HandlerXP) on the SAME k9_progression row.
    -- Each half below is still independently gated on its OWN flag, same
    -- "no wasted query for a sub-feature that is off" discipline the
    -- original fix established -- widening the OUTER early-return alone,
    -- without also gating each half inside the loop, would have
    -- reintroduced exactly the wasted-K9XP-query case this fix was written
    -- to close, for any server running HandlerXPProgression alone.
    if not (Config.Features.XPProgression or Config.Features.HandlerXPProgression) then return end

    -- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (boot-order-race
    -- audit, this pass -- same fix already shipped for
    -- server/certtiers.lua/server/permissionkeycatalog.lua/server/xptiers.lua/
    -- server/k9profiles.lua, simply missed here when it landed for those
    -- four -- see server/datastore.lua's own "BOOT-ORDER SETTLEMENT" header
    -- for the exact race this closes). LoadXPForCitizenid/LoadHandlerXPForCitizenid
    -- below (K9Store.XP_Get/K9Store.HandlerXP_Get) each read a single
    -- column from k9_progression -- narrower than the full column set that
    -- table is checked against -- so without this, this loop could warm
    -- K9XP/HandlerXP straight from a foreign table the full probe would
    -- correctly reject as a collision, during the one window before that
    -- probe's own yielding query has returned. On a `false` return (the
    -- probe genuinely had not settled within the wait budget), this skips
    -- every citizenid below rather than trust an unconfirmed database
    -- state -- their cache entry simply stays at whatever default it
    -- already had (0 XP, same as a never-warmed cache), identical to what
    -- already happens today whenever LoadXPForCitizenid's own read fails --
    -- the next PlayerLoaded, or a restart once the check has had time to
    -- finish, re-syncs it as normal.
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] progression: the schema-collision check had not finished within its wait budget -- skipping this restart\'s XP-cache backfill for every already-connected officer (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next PlayerLoaded (or a restart once the check has had time to finish) re-syncs it as normal.')
        return
    end

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                local citizenid = Player.PlayerData.citizenid
                if Config.Features.XPProgression then
                    local xp = LoadXPForCitizenid(citizenid)
                    PushTierSnapshot(src, citizenid, ResolveTier(xp))
                end
                if Config.Features.HandlerXPProgression then
                    -- Gated on the flag here for the SAME perf reason the
                    -- K9-side branch above is not: if this flag has NEVER
                    -- been turned on, no citizenid can have a real
                    -- handler_xp row to warm, so a query here would be
                    -- wasted (same PERFORMANCE FIX rationale already
                    -- documented above this handler for the K9 side).
                    -- KNOWN TRADE-OFF, same disclosed shape as the K9
                    -- side's own: an operator who enables this flag, lets a
                    -- citizenid earn real handler XP, disables it again,
                    -- then restarts this resource while that citizenid is
                    -- still online reintroduces the "cache/push sits at
                    -- default until next reconnect" gap for that narrow
                    -- case -- accepted for the identical reason the K9 side
                    -- already accepts it.
                    local handlerXp = LoadHandlerXPForCitizenid(citizenid)
                    PushHandlerTierSnapshot(src, citizenid, handlerXp, ResolveHandlerTier(handlerXp))
                end
            end
        end
    end
end)

-- Regression-test-class fix, applied proactively (mirrors
-- server/certifications/'s own documented fix for the identical shape of
-- bug on its `Certifications` cache): K9XP is keyed by citizenid and would
-- otherwise accumulate one entry per distinct citizenid ever loaded this
-- session with nothing ever evicting an entry — not a correctness bug (a
-- stale cached total for a now-offline citizenid is simply never read again
-- until PlayerLoaded repopulates it fresh), just unbounded memory growth on
-- a long-running server. Resolve the citizenid for the disconnecting source
-- via qbx_core (still resolvable here — playerDropped fires before the
-- framework fully tears down the player object, same timing
-- server/certifications/'s own playerDropped handler already relies on)
-- and drop its cache entry.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        K9XP[citizenid] = nil
        -- Same bounded-memory-growth rationale as K9XP's own eviction
        -- immediately above, applied to its handler-facing twin.
        HandlerXP[citizenid] = nil
        -- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass): same
        -- bounded-memory-growth reasoning, applied to the bookkeeping flag
        -- that backs the operator message and the resync sweep. A
        -- disconnected citizenid has no live source for that sweep to act
        -- on anyway; their next PlayerLoaded re-attempts the read fresh.
        XPLoadUnresolved[citizenid] = nil
        -- Drops every actionKey entry AwardXPCooldown holds for this
        -- citizenid in one call (NewNestedCooldown's :Clear(primaryKey)
        -- shape) — see that tracker's own declaration comment for why this
        -- is a per-citizenid prune rather than :RegisterPlayerDropped().
        -- Not a correctness requirement (a stale entry for an offline
        -- citizenid is simply never read again until they reconnect and
        -- earn XP fresh), same bounded-memory-growth rationale as the K9XP
        -- eviction above it.
        AwardXPCooldown.Clear(citizenid)

        -- XPMintBudget (the EIGHTH-XP-farm-fix shared cross-mechanic budget)
        -- is DELIBERATELY NOT cleared here, unlike K9XP/AwardXPCooldown
        -- immediately above -- see that tracker's own declaration comment
        -- for the full reasoning. Clearing it on disconnect would hand a
        -- farmer a fresh, full budget just by reconnecting, defeating the
        -- entire point of the fix this pass exists to close. It is bounded
        -- for memory instead by its own periodic sweep thread, which only
        -- evicts an entry once it would already have refilled to full
        -- capacity anyway.
    end
end)

-- ======================================================================
-- COULD-NOT-DETERMINE RESYNC SWEEP (lifecycle QA pass, this pass) --
-- mirrors server/certifications/'s own resync sweep for
-- CertificationCheckUnresolved, applied here to XPLoadUnresolved. See
-- LoadXPForCitizenid's own doc comment for the full contract this closes
-- the loop on. Lower stakes than the certification case (see that
-- function's own "SEVERITY" note -- a cosmetic tier/speed display, never
-- access), but the same self-heal-without-reconnect goal applies.
--
-- ALWAYS RUNS, UNCONDITIONALLY -- not gated behind Config.Features.
-- XPProgression/HandlerXPProgression: LoadXPForCitizenid is already called
-- unconditionally from PlayerLoaded (line ~2759 above) regardless of
-- either flag, so XPLoadUnresolved can gain entries on any install
-- regardless of which optional features are on. Matches this resource's
-- own established "a thread governed by something that can change at
-- runtime starts unconditionally and re-checks that thing fresh inside the
-- loop" convention -- see server/certifications/'s own resync sweep and
-- server/runtimecontrol.lua's FEATURE_TIERS entry on server/combat.lua's
-- maintenance threads for the precedent. Cheap on an idle server either
-- way: the overwhelmingly common case is an EMPTY XPLoadUnresolved table.
-- ======================================================================

local XP_RESYNC_SWEEP_INTERVAL_MS = 30000

--- One resync pass: retries LoadXPForCitizenid for every citizenid
--- currently recorded in XPLoadUnresolved, but ONLY for a citizenid who is
--- CURRENTLY ONLINE -- an offline citizenid's own next PlayerLoaded already
--- attempts a fresh read from a clean state. A successful retry needs no
--- separate bookkeeping here: LoadXPForCitizenid itself clears
--- XPLoadUnresolved[citizenid] the instant it confirms ANY answer -- this
--- function only needs to keep calling it, and push a fresh tier snapshot
--- when it does (mirroring PlayerLoaded's own post-load push) so an
--- officer who was stuck at the base tier display sees the correction
--- immediately rather than only on their next tier crossing.
local function ResyncUnresolvedXP()
    for citizenid in pairs(XPLoadUnresolved) do
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local targetSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(targetSrc) == 'number' then
            local xp = LoadXPForCitizenid(citizenid)
            if not XPLoadUnresolved[citizenid] then
                -- Confirmed this pass (LoadXPForCitizenid already cleared
                -- the flag) -- push the corrected tier now rather than
                -- waiting for this citizenid's next real tier crossing.
                PushTierSnapshot(targetSrc, citizenid, ResolveTier(xp))
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(XP_RESYNC_SWEEP_INTERVAL_MS)

        -- Cheap early-exit, checked fresh every tick -- see this sweep's
        -- own header above for why this table is expected to be empty
        -- essentially always.
        if next(XPLoadUnresolved) ~= nil then
            local ok, err = pcall(ResyncUnresolvedXP)
            if not ok then
                print(('[John-K9] progression: XP resync sweep tick error: %s'):format(tostring(err)))
            end
        end
    end
end)
