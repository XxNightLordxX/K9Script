--[[
    john-k9/client/progression.lua

    Phase 4. Client half of `Config.Features.XPProgression`
    (server/progression.lua owns the server-authoritative half — award
    logic, persistence, the tier lookup). THIS FILE has NO authority of its
    own: it only ever RECEIVES an already-resolved, server-computed tier and
    reflects it locally — it never computes XP, never claims a tier to the
    server, and never accumulates anything (DEVELOPER_REFERENCE.md §13.0 Decision 3:
    XP and its derived tier are server-authoritative state, full stop).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4. Identical in format to
    client/tracking.lua's own contract block.

    Callbacks: none.

    Server events (client->server): NONE for XP itself — see
    server/progression.lua's own header for why no "I earned XP" event
    exists or should ever exist.

    Client events (RegisterNetEvent, server->client):
    1. 'john-k9:client:xpTierChanged' (newTier: table — a full entry from
       Config.XPTiers: { xp, label, speedMultiplier, scentRangeMultiplier })
       [THIS FILE] — sent on PlayerLoaded/resource-start backfill (an
       authoritative snapshot, not a "level up") and on any real tier
       crossing (server/progression.lua's AwardXP). This file cannot tell
       those two cases apart from the payload alone, and doesn't need to for
       CORRECTNESS (the speedMultiplier is applied identically either way) —
       it only matters for whether to show a "tier up" notification, handled
       below via `hasReceivedInitialTier` (never notify on the very first
       snapshot a session receives, since there is no prior client-side tier
       to have "leveled up" from).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        GetCurrentXPTier() -> table|nil
            The last tier snapshot pushed by the server this session, or nil
            before the first 'john-k9:client:xpTierChanged' arrives
            (briefly, right after connect, before PlayerLoaded's server-side
            backfill round-trips back). Exposed for a future HUD/display
            need (DEVELOPER_REFERENCE.md §13.4.1's own "additive read, not a new
            authorization surface" framing) — not currently consumed
            anywhere else in this resource.
    - COORDINATION POINT WITH THE SHARED MOVE-RATE COMPOSER (DEVELOPER_REFERENCE.md
      §13.0 Decision 2, §13.5): multiple independent systems want to call
      SetPedMoveRateOverride on the K9's own ped (this file, PropDragging,
      the wellbeing subsystem) — last-caller-wins on that native means
      uncoordinated calls silently clobber each other. The shared answer is
      a SINGLE composer, `RecomputeK9MoveRate()` + a `K9MoveRateModifiers`
      table (both defined in client/movement.lua), where every contributing
      system sets its OWN named slot (`K9MoveRateModifiers.xpTier` for this
      file) and calls `RecomputeK9MoveRate()` rather than calling the
      native directly. THIS FILE THEREFORE NEVER CALLS
      SetPedMoveRateOverride ITSELF — doing so would be exactly the
      uncoordinated-caller bug this composer exists to prevent. Instead:
        - `CachedXPTierSpeedMultiplier` (below) always holds the latest
          server-pushed tier's speedMultiplier, updated on every
          xpTierChanged event.
        - `ApplyXPTierMoveRateEffect()` (below) is THIS FILE's own
          clearly-named, separately-callable contribution: if
          `K9MoveRateModifiers` exists (a plain table check, not a function
          call — it is a shared table, not a function), it writes
          `K9MoveRateModifiers.xpTier = CachedXPTierSpeedMultiplier` and
          then calls `RecomputeK9MoveRate()` IF that also exists
          (`type(...) == 'function'` guard, mirroring server/search.lua's
          established `type(AwardXP) == 'function'` soft-dependency
          convention, kept here as a defensive guard against a future
          load-order change rather than as an assumption the composer
          might still be missing today). `client/movement.lua` defines
          both symbols — its `K9MoveRateModifiers` table has an
          `xpTier = 1.0,` entry (commented "client/progression.lua,
          Config.Features.XPProgression") and `RecomputeK9MoveRate()` is
          defined a few lines below it, the exact slot name and table
          shape this file assumes. If the composer were ever absent, this
          function would be a harmless no-op beyond updating the cached
          value — it does NOT fall back to calling SetPedMoveRateOverride
          directly.
    ======================================================================

    TOP-OF-FILE FEATURE GATE: without it, 'john-k9:client:xpTierChanged'
    would be reachable, and ApplyXPTierMoveRateEffect() would feed a forged
    payload's speedMultiplier straight into the shared move-rate composer,
    with XPProgression = false -- breaking this resource's "flag off means
    genuinely inert" invariant (client/hud.lua / client/vision.lua /
    client/partnership.lua / client/combat.lua precedent). Gated at the top
    of the file, not per-handler, because -- like client/partnership.lua --
    this file's ONLY responsibility is Config.Features.XPProgression's client
    half; there is no other concern here that would be wrongly silenced by a
    file-wide gate. GetCurrentXPTier() simply does not exist while the flag is
    off (no current caller anywhere in this resource, confirmed by grep), the
    same posture client/partnership.lua's IsPartnered()/GetPartnerServerId()
    already establish for a single-concern file.
    ======================================================================

    ======================================================================
    AN UNBOUNDED TRAP, IDENTICAL IN SHAPE TO THE ONE client/wellbeing.lua's
    "LIVE FEATURE FLAGS" section already closed for its own five flags
    (read that section in full -- this fix reuses its exact reasoning and
    shape, applied to this file's one flag).

    CLOSED, BOTH HALVES (coder-backend, restart/reconnect audit follow-up):
    THIS FILE's own half was already correct and already covered by
    tests/clientprogression_spec.lua's `.live = false` assertions (nothing
    changed here). The SERVER half this section used to describe as
    "documented here, not applied in this file" is now applied, exactly as
    specified below (kept verbatim as the historical record of the fix,
    not rewritten as an "already done" summary, since the two code blocks
    below are byte-for-byte what actually shipped in
    server/progression.lua's PushTierSnapshot/RefreshXPProgressionLiveStateForAllOnline
    and server/runtimecontrol.lua's ApplyFeatureOverride -- see those two
    files for the real, current source; re-verify against them directly
    rather than trusting this comment if the two ever appear to disagree).
    tests/runtimecontrol_spec.lua and tests/progression_spec.lua both cover
    the server half end to end (an XPProgression toggle now reaches an
    already-online K9 within the same tick, no reconnect/restart needed).

    THE TRAP: the top-of-file gate above reads Config.Features.XPProgression
    exactly ONCE, at THIS CLIENT's own resource start -- this client's own
    static copy of config.lua, never updated afterward. server/runtimecontrol.lua
    classifies XPProgression as `tier = 'live'` specifically because
    server/progression.lua's AwardXP and PushTierSnapshot both re-check
    Config.Features.XPProgression fresh on every call -- a genuinely LIVE,
    immediate, no-restart toggle, server-side. But server/runtimecontrol.lua's
    own header states plainly it "does not push a live Config update to
    already-connected CLIENTS" for anything other than its unrelated tablet-
    theme broadcast -- so an already-connected client's OWN
    Config.Features.XPProgression NEVER changes when high command flips the
    flag off via the tablet, mid-session, without a restart. Concretely: a
    K9 earns a real tier (say speedMultiplier = 1.10), this file writes
    K9MoveRateModifiers.xpTier = 1.10 via ApplyXPTierMoveRateEffect(). High
    command then disables XPProgression at runtime. PushTierSnapshot
    (server/progression.lua) ALSO gates on the same flag and simply stops
    sending 'john-k9:client:xpTierChanged' at all from that instant on
    (its own early return, no exception) -- there is no OTHER push/poll
    left anywhere in this resource that would ever tell this file to
    reconsider. K9MoveRateModifiers.xpTier=1.10 -- and the composed
    SetPedMoveRateOverride effect derived from it -- is stuck at that value
    until this client relogs or the resource restarts, exactly the
    unbounded trap this resource's own rules forbid, and the SAME root cause
    (a server-side toggle with literally nothing telling an already-
    connected client) client/wellbeing.lua's own header already documents
    finding and fixing for FatigueSystem.

    UNLIKE wellbeing, THIS FILE CANNOT FULLY CLOSE THE LOOP ON ITS OWN:
    wellbeing could piggyback a `featureFlags` table onto its own ALREADY-
    UNCONDITIONAL periodic wellbeingUpdate push (that push keeps firing for
    a connected K9 regardless of any ONE of its five flags, because at
    least one of the other four might still be live) -- this file's ONLY
    push, PushTierSnapshot, is gated on the very same single flag this fix
    needs to detect going false, so it stops sending ANYTHING the instant
    the flag flips, with no recurring channel left to reuse. Closing this
    completely needs a small, server-side change (server/*.lua is out of
    this file's scope) -- see below for the exact change needed; it is
    documented here, not applied in this file. What THIS file does, right
    now, unconditionally:
      1. Tracks `LiveXPProgressionEnabled`, mirroring
         client/wellbeing.lua's `LiveFeatureFlags` shape exactly (seeded
         true -- by construction, reaching this line already required this
         client's own static Config.Features.XPProgression to be true, per
         the top-of-file gate above).
      2. Reads an OPTIONAL `.live` boolean field off every
         'john-k9:client:xpTierChanged' payload (absent on an
         unpatched server -- left untouched, never invented, exactly
         mirroring client/wellbeing.lua's ApplyWellbeingSnapshot ingest
         guard for its own `featureFlags` sub-table).
      3. THE FIX ITSELF, THE RULE THAT OUTRANKS EVERYTHING: whenever
         `LiveXPProgressionEnabled` reads false, CachedXPTierSpeedMultiplier
         is force-reset to the neutral 1.0 baseline regardless of whatever
         speedMultiplier the payload carries, which ApplyXPTierMoveRateEffect()
         then writes into K9MoveRateModifiers.xpTier as always -- this reset
         path is NOT itself gated on the feature being on (that is
         precisely the trap): it runs from inside the SAME always-
         registered handler as every other branch, so once a `.live=false`
         signal ever does arrive, the reset is unconditional.

    THE EXACT SERVER-SIDE CHANGE THIS DEPENDS ON TO EVER BE INVOKED WHILE
    THE FEATURE IS OFF (belongs in server/*.lua, outside this file's scope
    -- not applied here). Two small, additive edits, reusing the EXISTING
    'john-k9:client:xpTierChanged' channel end to end -- no new event
    name, no new lib.callback, no new poll thread:
      a) server/progression.lua's `PushTierSnapshot` (currently: `if not
         Config.Features.XPProgression then return end` before ever
         calling TriggerClientEvent -- a hard no-op that sends nothing at
         all while the flag is off) must stop early-returning and instead
         ALWAYS send, with the live flag riding along on the payload:
             local function PushTierSnapshot(targetSrc, tier)
                 local snapshot = CopyTier(tier)  -- MUST copy -- tier is
                     -- often a live reference into Config.XPTiers[n]
                     -- (ResolveTier's own documented by-reference return);
                     -- writing snapshot.live directly onto that shared
                     -- reference would corrupt it for every other
                     -- citizenid in the same bracket.
                 snapshot.live = Config.Features.XPProgression == true
                 TriggerClientEvent('john-k9:client:xpTierChanged', targetSrc, snapshot)
             end
         This alone changes nothing observable while the flag stays on
         (every existing call site keeps behaving identically -- `.live`
         is simply `true`); it only stops the payload from being withheld
         entirely once the flag goes off.
      b) That alone is not suffient -- PushTierSnapshot is only ever
         CALLED from PlayerLoaded, the resource-start backfill loop, and a
         tier CROSSING inside AwardXP/AwardXPDirect, none of which fire at
         the moment an operator flips the flag mid-session. A new
         resource-global, e.g. `RefreshXPProgressionLiveStateForAllOnline()`
         in server/progression.lua, should iterate GetPlayers() (same shape
         as the existing onResourceStart backfill loop) and call
         `PushTierSnapshot(src, GetXPTier(citizenid))` for each currently
         connected, resolvable citizenid -- deliberately WITHOUT that
         backfill loop's own `if not Config.Features.XPProgression then
         return end` early exit, since this function's entire purpose is
         to run precisely when that flag may have just gone false. Then,
         server/runtimecontrol.lua's `ApplyFeatureOverride(name, value)`
         (server/runtimecontrol.lua:1174, the SINGLE mutation point for
         every path that changes Config.Features[name] at runtime -- both
         runtimeSetFeature and runtimeResetFeature already funnel through
         it) should call this new function, behind the same soft-
         dependency `type(...) == 'function'` guard this codebase already
         uses pervasively (server/search.lua's `type(AwardXP) ==
         'function'`, this file's own `type(RecomputeK9MoveRate) ==
         'function'`):
             local function ApplyFeatureOverride(name, value)
                 if type(Config.Features) == 'table' and Config.Features[name] ~= nil then
                     Config.Features[name] = value
                     if name == 'XPProgression' and type(RefreshXPProgressionLiveStateForAllOnline) == 'function' then
                         RefreshXPProgressionLiveStateForAllOnline()
                     end
                 end
                 -- ... existing body continues unchanged
             end
         This is a single, precise hook at the ONE real transition point
         (immediate, zero staleness -- unlike wellbeing's up-to-one-tick-
         interval bound, since this flag has no recurring tick to piggyback
         on) -- not a new poll thread, and not a second channel.
      Until both (a) and (b) land, `newTier.live` is always absent on every
      real server, `LiveXPProgressionEnabled` never moves off its seeded
      `true`, and this file's own fix above is inert but harmless (it costs
      nothing, changes no current behavior, and is the ready-to-activate
      client half the moment the two-file server patch ships).
    ======================================================================
]]

-- ======================================================================
-- HANDLER XP LADDER (owner-directed, this pass: "add both those features
-- and do progression put in the tablet").
--
-- DELIBERATELY ABOVE THIS FILE'S OWN `if not Config.Features.XPProgression
-- then return end` GATE, and this placement is the whole point, not a
-- stylistic choice. The two ladders are INDEPENDENT switches:
-- Config.Features.XPProgression governs the K9's ladder, and
-- Config.Features.HandlerXPProgression governs the handler's. Putting this
-- receiver below that gate would mean a server running handler progression
-- with K9 progression off never receives a single handler tier update, and
-- the failure would be completely silent -- no error, no log, just a rank
-- that never appears. That is this codebase's most-repeated bug shape (a
-- correct thing made unreachable by a gate one layer up), so it is closed
-- here by construction rather than guarded against.
--
-- THE GAP THIS CLOSES: server/progression.lua has been firing
-- 'john-k9:client:handlerXpTierChanged' at the handler's own client for
-- some time, carrying { totalXp, tier, live }. Nothing anywhere in client/
-- registered it -- it was the ONLY server-to-client event in this entire
-- resource with no receiver. Handlers earned real, cooldown-protected,
-- database-backed XP and had no way to see any of it. config.lua's own
-- justification for switching the feature on reads "the tablet advertises
-- the ranks... A rank a player can see and can never earn is worse than no
-- rank at all"; what actually shipped was the exact inverse -- earnable and
-- invisible.
-- ======================================================================

--- Last handler snapshot from the server this session, or nil before the
--- first event arrives. Read through GetHandlerXPState() below, never
--- directly.
--- @type { totalXp: number, tier: table }|nil
local handlerXPState = nil

--- Same "never announce a level-up on the initial snapshot" guard the K9
--- side above uses, for the same reason: the first payload of a session is
--- a state sync, not something the player just earned.
local hasReceivedInitialHandlerTier = false

--- The SERVER's current Config.Features.HandlerXPProgression value, kept
--- fresh by the `.live` field on every payload -- never this client's own
--- static copy, which is fixed at resource start and is not updated by a
--- runtime tablet toggle. Mirrors LiveXPProgressionEnabled below exactly.
--- Seeded true so an unpatched server (no `.live` field) behaves as it
--- always did.
local LiveHandlerXPEnabled = true

--- Resource-global, read by client/tablet.lua for the Progression screen.
--- Returns nil until the first snapshot lands, which callers must treat as
--- "not known yet" rather than "zero" -- a handler with genuinely 0 XP
--- still gets a real payload with totalXp = 0, so nil and 0 are different
--- answers and must not be collapsed.
--- @return { totalXp: number, tier: table, live: boolean }|nil
function GetHandlerXPState()
    if not handlerXPState then return nil end
    return {
        totalXp = handlerXPState.totalXp,
        tier = handlerXPState.tier,
        live = LiveHandlerXPEnabled,
    }
end

--- @param payload table -- { totalXp: number, tier: table, live: boolean? }
RegisterNetEvent('john-k9:client:handlerXpTierChanged', function(payload)
    -- SOURCE-ORIGIN GUARD, this resource's standard convention -- see
    -- client/combat.lua's own header block for the full confidence writeup.
    -- Matters less here than on the K9 side (nothing in this payload feeds
    -- a move rate or any other real effect -- it is display-only), but the
    -- convention is applied uniformly rather than case-by-case, so that a
    -- future change which DOES give this payload teeth inherits the guard
    -- instead of needing someone to remember to add it.
    if source ~= 65535 then return end

    if type(payload) ~= 'table' then return end
    if type(payload.totalXp) ~= 'number' or type(payload.tier) ~= 'table' then return end

    -- LIVE FLAG INGEST, before anything else reads it -- same ordering and
    -- same optionality as the K9 handler below. A missing or non-boolean
    -- field leaves the current value alone and never invents one.
    if type(payload.live) == 'boolean' then
        LiveHandlerXPEnabled = payload.live
    end

    local previous = handlerXPState
    handlerXPState = { totalXp = payload.totalXp, tier = payload.tier }

    -- RANK-UP NOTICE. Four conditions, each doing real work:
    --   * the live flag is on -- a push sent purely to tell this client the
    --     feature was just switched OFF must never read as a promotion;
    --   * the initial snapshot has already been seen -- otherwise every
    --     login announces a promotion the player earned days ago;
    --   * there is a previous tier to have moved FROM;
    --   * and the label genuinely changed -- defensive, since the server
    --     only pushes on a real crossing today, but this file does not
    --     assume that invariant holds forever.
    -- This mirrors the K9 tier-up notice below exactly, deliberately: a
    -- handler earning a rank should feel the same as a K9 earning one.
    if LiveHandlerXPEnabled
        and hasReceivedInitialHandlerTier
        and previous
        and previous.tier
        and previous.tier.label ~= payload.tier.label then
        lib.notify({
            title = locale('common.notify_title'),
            description = locale('progression.handler_tier_up', tostring(payload.tier.label)),
            type = 'success',
        })
    end

    hasReceivedInitialHandlerTier = true
end)

if not Config.Features.XPProgression then return end

--- Last tier snapshot received from the server this session, or nil before
--- the first 'john-k9:client:xpTierChanged' event arrives. Not exposed
--- directly — always go through GetCurrentXPTier().
--- @type table|nil
local currentXPTier = nil

--- Guards the "tier up" notification below from firing on the very first
--- snapshot a session receives (PlayerLoaded's own backfill push) — see
--- this file's EVENT/CALLBACK CONTRACT note above for why the payload alone
--- can't distinguish "initial snapshot" from "real tier change."
local hasReceivedInitialTier = false

--- Always holds the latest server-authoritative tier's speedMultiplier —
--- see the FILE-TO-FILE CONTRACT's "COORDINATION POINT" section above for
--- why this exists independently of whether the shared move-rate composer
--- has shipped yet.
local CachedXPTierSpeedMultiplier = 1.0

--- Mirrors client/wellbeing.lua's own `LiveFeatureFlags` pattern exactly --
--- see this file's header "AN UNBOUNDED TRAP" section for the full "why" and
--- the unbounded trap this closes. The SERVER's CURRENT
--- Config.Features.XPProgression value, kept fresh by an OPTIONAL `.live`
--- field on every 'john-k9:client:xpTierChanged' payload -- NOT this
--- client's own static Config.Features.XPProgression copy (fixed at this
--- client's own resource start, never updated by a runtime tablet toggle --
--- server/runtimecontrol.lua's own disclosed limitation). Seeded true: this
--- whole file already returned at this file's own top-of-file gate above if
--- this client's own static copy were false, so by construction it is true
--- the instant this line runs.
local LiveXPProgressionEnabled = true

--- Resource-global — see FILE-TO-FILE CONTRACT above.
--- @return table|nil
function GetCurrentXPTier()
    return currentXPTier
end

--- THIS FILE's own clearly-named, separately-callable contribution to the
--- shared move-rate composer described in the FILE-TO-FILE CONTRACT's
--- "COORDINATION POINT" section above. Deliberately NEVER calls
--- SetPedMoveRateOverride itself — see that section for the full reasoning.
local function ApplyXPTierMoveRateEffect()
    if K9MoveRateModifiers then
        K9MoveRateModifiers.xpTier = CachedXPTierSpeedMultiplier
    end
    -- else: defensive only now — the shared composer (client/movement.lua,
    -- DEVELOPER_REFERENCE.md §13.0 Decision 2) has shipped and is confirmed to
    -- define `K9MoveRateModifiers` (see this file's header, "COORDINATION
    -- POINT"), so this branch is not expected to be taken on a
    -- normal load order. Left in place as a harmless no-op rather than an
    -- assert, matching this resource's own soft-dependency convention
    -- (server/search.lua's `type(AwardXP) == 'function'` guard) for
    -- the case where some future refactor changes load order again.
    -- CachedXPTierSpeedMultiplier above still holds the correct, current,
    -- server-authoritative value regardless, and this function is
    -- specifically NOT a fallback direct SetPedMoveRateOverride call.

    if type(RecomputeK9MoveRate) == 'function' then
        RecomputeK9MoveRate()
    end
end

--- @param newTier table -- { xp, label, speedMultiplier, scentRangeMultiplier }, a full Config.XPTiers entry
RegisterNetEvent('john-k9:client:xpTierChanged', function(newTier)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block — read that for the full confidence writeup; not
    -- re-derived here). Without this, a modified client could locally
    -- fire `TriggerEvent('john-k9:client:xpTierChanged', {
    -- speedMultiplier = 999 })` — the shape check below only validates
    -- TYPE, never RANGE, so an arbitrary numeric speedMultiplier would
    -- pass it and feed straight into ApplyXPTierMoveRateEffect()'s
    -- move-rate composer — a real, uncapped self-benefit vector via zero
    -- server contact. Graded MEDIUM-HIGH, not certain: see
    -- client/combat.lua's own header for why (the `source ~= 65535`
    -- client-side sentinel is the official documented pattern for this,
    -- but was not empirically verified in-engine).
    if source ~= 65535 then return end

    -- Defensive shape validation even though this is server-authoritative
    -- (never a client-supplied claim) — cheap, and this codebase's own
    -- convention (e.g. client/tracking.lua's `not result or not
    -- result.found` guard on its own server callback response) is to never
    -- assume a network payload arrives well-formed, regardless of which
    -- side sent it.
    if type(newTier) ~= 'table' or type(newTier.speedMultiplier) ~= 'number' then
        return
    end

    -- LIVE FEATURE FLAG INGEST — see this file's header "AN UNBOUNDED TRAP"
    -- section. Done BEFORE CachedXPTierSpeedMultiplier is touched below, so
    -- the reset branch always acts on the freshest known flag state for
    -- THIS same payload. `.live` is OPTIONAL (absent on an unpatched
    -- server) — a missing/non-boolean field leaves LiveXPProgressionEnabled
    -- at its current value, never invents one, mirroring
    -- client/wellbeing.lua's own ApplyWellbeingSnapshot ingest guard for its
    -- `featureFlags` sub-table exactly.
    if type(newTier.live) == 'boolean' then
        LiveXPProgressionEnabled = newTier.live
    end

    local previousTier = currentXPTier
    currentXPTier = newTier
    -- THE FIX, PRIORITY 1 — THE RULE THAT OUTRANKS EVERYTHING: while the
    -- server's live flag reads OFF, this modifier is force-reset to the
    -- neutral 1.0 baseline regardless of whatever speedMultiplier the
    -- payload carries — never merely left at its previous, possibly
    -- non-neutral, value. This branch is NOT gated on the feature being on
    -- (it runs unconditionally, from inside this same always-registered
    -- handler) — that is precisely what makes it a real reset rather than
    -- another instance of the trap it exists to close. Mirrors
    -- client/wellbeing.lua's own ApplyMoveRateModifiers "a flag switched
    -- off mid-effect must REMOVE that effect, not merely stop re-applying
    -- it" fix, applied here to this file's one modifier slot.
    CachedXPTierSpeedMultiplier = LiveXPProgressionEnabled and newTier.speedMultiplier or 1.0

    ApplyXPTierMoveRateEffect()

    -- Only notify on a REAL tier change after this session's initial
    -- snapshot has already been received once — never on that first
    -- snapshot itself (there is no prior client-side tier to have "leveled
    -- up" from at that point), never for a no-op repeat of the same tier
    -- (defensive — server/progression.lua only pushes on an actual crossing
    -- today, but this file doesn't assume that invariant holds forever),
    -- and never while the live flag reads off — a live-off push exists
    -- purely to reset this file's own modifier, never to announce a
    -- "level up" the player did not actually just earn.
    if LiveXPProgressionEnabled and hasReceivedInitialTier and previousTier ~= newTier and previousTier and previousTier.label ~= newTier.label then
        lib.notify({
            title = locale('common.notify_title'),
            description = locale('progression.tier_up', tostring(newTier.label)),
            type = 'success',
        })
    end

    hasReceivedInitialTier = true
end)
