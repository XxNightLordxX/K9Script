--[[
    qbx_k9unit/server/search.lua

    THIS IS THE SECURITY-CRITICAL FILE OF PHASE 2, per DEVELOPER_REFERENCE.md
    §11.1 sub-phase 2b (the piece that should be reviewed first, to confirm
    search results can't be client-claimed) and per
    DEVELOPER_REFERENCE.md#contraband-search's own framing ("designing
    early because the trust boundary doesn't move even if config field
    names do"). This implementation requires an explicit security review
    before it ships, the same standard server/certifications/'s header
    already sets for §4's grant/revoke flow.

    Owns (DEVELOPER_REFERENCE.md §11.3's `server/search.lua` row): the
    `qbx_k9unit:server:searchTarget` callback — server-authoritative
    "search vehicle/person for contraband" (§6.3/§11.5), including the
    contraband-alert broadcast (§11.4 item 2, gated on
    Config.Features.ContrabandAlerts). New file, not folded into
    server/main.lua, for the SAME "real capability grant deserves the
    certification-file's level of scrutiny" reasoning §11.3 gives for
    splitting client/search.lua from client/tracking.lua by TRUST MODEL,
    not feature name: this file reads a target's REAL, live ox_inventory
    contents — the same category of real capability grant as
    server/certifications/'s grant/revoke — whereas server/tracking.lua
    (this file's sibling) only ever reveals a client-cosmetic marker trail
    (DEVELOPER_REFERENCE.md §11.6, no real capability granted).

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE:
    1. DEVELOPER_REFERENCE.md §11.4 item 2 (event/callback contract) and §11.5's
       "Search vehicle/person + contraband alert tiers" acceptance
       criteria — the base contract this file satisfies.
    2. DEVELOPER_REFERENCE.md#contraband-search — supplements §11.4/
       §11.5 with the exact server-authoritative validation order (§3), the
       REAL confirmed ox_inventory export surface (§1 —
       `GetInventoryItems`, `GetContainerFromSlot`, read against the actual
       overextended/ox_inventory source, not guessed), the mandatory
       container-recursion requirement (§2), and the race-safe
       rate-limiting/mutex design (§4).
    3. DEVELOPER_REFERENCE.md#contraband-search — every BLOCKING
       finding in its §8 summary is implemented below as a hard
       requirement, not optional hardening:
         - Blocking: contraband alert broadcast is DISTANCE-FILTERED (see
           BroadcastContrabandAlert below), never a global `-1` broadcast
           like relayBark's (§1).
         - Blocking: broadcast payload carries `netId` + `alertTier` ONLY —
           never `totalWeight`/`contrabandFound` (§1).
         - Flat per-source cooldown on `searchTarget` (ANY target),
           independent of the existing per-TARGET cooldown (§2). CORRECTION:
           TargetSearchCooldown below is keyed
           purely on the resolved target identity (plate/citizenid) — it
           carries NO searcher dimension at all, so this is genuinely a
           per-target lock shared across every searcher, not a per-(source,
           target) pair as DEVELOPER_REFERENCE.md's original text and earlier comments in
           this file described. See HandleSearchTarget's own doc comment
           (§5 below) for the corrected, accurate description.
         - Per-target cooldown timestamp written BEFORE the awaited
           ox_inventory read, not after (§3).
         - Resolved entity's REAL type cross-validated against the claimed
           `targetType`; for 'person', confirmed to resolve to a
           currently-connected player before being treated as searchable
           (§4).
         - Explicit, stated decision (not a silent default) on whether a
           per-target-ONLY backstop cooldown exists — see HandleSearchTarget's
           doc comment below for the decision made and its rationale (§5).
         - citizenid, not raw ped netId, keys the person-search cooldown
           (§7).

    Config.SearchZones.alertBroadcastRadius
    is the max distance from the SEARCHED TARGET's own live coordinates
    for a bystander to receive the alert broadcast — never a global
    broadcast, per the security review above.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2. Identical in format to
    server/certifications/'s contract block.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:searchTarget' (targetType: 'vehicle'|'person', targetNetId: number)
       -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
       [THIS FILE]
       See HandleSearchTarget's own doc comment below for the full
       validation order.

    Server events (RegisterNetEvent, client->server): none. This feature
    is entirely request/response shaped — there is deliberately no
    fire-and-forget "I searched" event.

    Client events (RegisterNetEvent, server->client):
    2. 'qbx_k9unit:client:playContrabandAlert' (netId: number, alertTier: string)
       [client/search.lua] — the distance-filtered broadcast described in
       BroadcastContrabandAlert below. NOTE the DELIBERATE ABSENCE of
       `totalWeight`/`contrabandFound` in this payload — see the security
       review's blocking finding §1. `netId` here is the SEARCHED TARGET's
       own netId (the vehicle/ped that was flagged), not the requesting
       K9's — the client needs to know which entity to play the reaction
       on/near.

    Commands: none.

    Automatic path: none.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, resource-global from
      server/certifications/ — reused, never re-derived. Does NOT call
      `IsConfiguredK9Model` — a search requester's eligibility is pure
      job+certification (HasK9Access), same posture as
      server/tracking.lua's own FILE-TO-FILE CONTRACT note for the same
      reason. Called TWICE per search: once at the top of the callback
      registration (cheap request-time gate) and once more inside
      HandleSearchTarget immediately after the awaited
      `GetInventoryItems` call returns (mid-flight revocation re-check —
      see HandleSearchTarget's own doc comment, step 8) — deliberate,
      not a duplicate-by-accident, since certification.lua's revoke path
      can run to completion during that same await window.
    - THIS FILE exposes TWO resource-global functions (PERFORMANCE AUDIT
      PASS, this pass — was "exactly one" before `ForEachNearbyPlayer` was
      extracted; see that function's own doc comment, right above
      BroadcastContrabandAlert below, for the full writeup: a pure,
      read-only "who is near this point right now" helper with no gating of
      its own, reused by server/main.lua's relayBark/relayDoorScratch).
      `GetContrabandAlertTier(totalWeight)` — a thin pass-through to the
      file-local `ResolveAlertTier`, added purely as a test/inspection seam
      (same shape and same reason as server/progression.lua's
      `GetXPTier`/`ResolveTier` pair: identical pure, boundary-sensitive
      tier-walk logic worth driving directly in a test, without also
      needing to drive entity resolution, ox_inventory container
      recursion, natives, or this file's mutex/cooldown state). See
      GetContrabandAlertTier's own doc comment, right after
      ResolveAlertTier below, for why this does NOT weaken this file's
      trust boundary: it takes a plain number and returns a
      Config.ContrabandAlertTiers entry, with no access whatsoever to any
      target's real inventory, no proximity check, no HasK9Access check,
      and no cooldown state — the real capability grant this file's header
      calls "the same category as a certification grant" is the
      ox_inventory read inside HandleSearchTarget, which this wrapper
      never touches, shortcuts, or provides a path into.
      (Separately: its own `ResolveConnectedPlayerFromPed` WAS the
      original, most-documented implementation of that helper — see
      server/entities.lua for why it moved there under
      DEVELOPER_REFERENCE.md item 2b, and this file's HandleSearchTarget for
      the one remaining call site, unchanged besides now calling the
      shared global.)
    - THIS FILE owns `SearchMutex`, `SearchCooldown`, and
      `TargetSearchCooldown` below as file-local state (each a
      server/cooldowns.lua tracker instance, per DEVELOPER_REFERENCE.md item 1
      — see each one's own doc comment for why it exists and which original
      hand-rolled table it replaced).
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)`,
      exposed by server/entities.lua (DEVELOPER_REFERENCE.md near-term item 2),
      inside HandleSearchTarget below — do not re-implement the
      resolve/existence-guard sequence here. HandleSearchTarget's own
      targetType-vs-GetEntityType cross-check is NOT delegated to that
      helper and stays local to this file — see HandleSearchTarget's own
      comment for why.
    - PHASE 4 ADDITION: THIS FILE also calls
      `AwardXP(citizenid, actionKey)`, resource-global from
      server/progression.lua, from inside HandleSearchTarget once
      `contrabandFound == true` is known — via a
      `type(AwardXP) == 'function'` runtime existence guard, the same
      soft-dependency convention server/tracking.lua's own AwardXP/GetXPTier
      call sites already establish. No load-order assumption on server/progression.lua either
      way. See config.lua's `Config.XP.awards.searchContrabandFound` comment
      for the award's own design rationale.
    - SEARCHER-BUSY GUARD (server-side half of client/search.lua's own
      IsBusyWithSomethingElse(), commit a32a554 — see IsSearcherBusyElsewhere's
      own doc comment below for the full writeup): THIS FILE also calls
      `IsK9CurrentlyHolding(holderSrc)`, a READ-ONLY resource-global
      server/combat.lua exposes over its own file-local K9ActiveEffect table
      (same "global helper, private per-file state" shape as that file's own
      CountActiveHoldsByEffectType/EndActiveEffectForHolder) — via a
      `type(IsK9CurrentlyHolding) == 'function'` runtime existence guard,
      the same soft-dependency convention as the AwardXP/GetXPTier bullet
      immediately above. No load-order assumption on server/combat.lua
      either way; a server predating this accessor simply never blocks on
      this specific case, degrading to the pre-fix behavior for that one
      check only, never an error.
    - ECONOMY-AUDIT FIX: THIS FILE also owns `ContrabandXpState`
      below (per-resolved-target last-awarded contraband weight cache) —
      see that table's own declaration comment, right after
      TargetSearchCooldown, for the XP-farm hole it closes and why it is
      deliberately NOT a server/cooldowns.lua tracker instance despite the
      "always use NewCooldown" convention every OTHER piece of file-local
      state in this file follows.
    - FIFTH XP-FARM FIX (solo weight-toggle farm closure): THIS FILE also
      owns `ContrabandXpMintCooldown` below — a
      real server/cooldowns.lua NewCooldown() instance this time (unlike
      ContrabandXpState just above), ported from server/tracking.lua's own
      `TrackTicketMintCooldown`. A flat, per-SEARCHER cooldown on the XP
      MINT itself, required IN ADDITION TO (never instead of)
      ContrabandXpState's own weight-changed check, before AwardXP is ever
      called. See that tracker's own declaration comment, right after
      ContrabandXpState, and the CORRECTION note on ContrabandXpState's own
      declaration comment, for the exact farm this closes and why
      TargetSearchCooldown's per-target-only, no-searcher-dimension shape
      could never have closed it alone.
    - COOPERATIVE SEARCH BONUS (DEVELOPER_REFERENCE.md Part B §10): THIS FILE
      also owns `CoopSearchXpMintCooldown` (see its
      own declaration comment, right after the EIGHTH-XP-FARM-FIX
      cross-file pointer above, for the full spec/arithmetic) and calls two
      MORE resource-globals via `type(...) == 'function'` runtime existence
      guards, same soft-dependency convention as AwardXP/GetXPTier already
      established above: `GetActivePartnerCitizenId(citizenid)`
      (server/partnership.lua) and `GetXPTier(citizenid)`
      (server/progression.lua, already a dependency of this file). No new
      load-order requirement either way.
    ======================================================================
]]

-- CONFIG-SAFETY GUARDS (config-validator findings, both actioned in this
-- pass). Same "fail loudly at resource start instead of silently accepting
-- an unsafe value" posture as server/main.lua's existing
-- Config.DoorInteraction.nudgeRequiresUnlocked guard (see that file's
-- onResourceStart block for the precedent this follows). Deliberately
-- placed HERE rather than alongside that precedent: both config values
-- below are read exclusively by this file (ResolveAlertTier and
-- BroadcastContrabandAlert above), so the invariant lives next to the
-- code whose security model actually depends on it, the same reasoning
-- this file's own header already gives for splitting server/search.lua
-- out of server/main.lua by trust boundary rather than feature name.
-- main.lua's onResourceStart guard remains the right home for
-- nudgeRequiresUnlocked specifically because that flag has no owning
-- file yet (nudge-open isn't implemented anywhere in this resource).
-- Built-in fallback for Config.ContrabandAlertTiers -- byte-identical to
-- config.lua's own shipped default for this table. Used ONLY when the
-- configured table fails the validation below; kept as a single named
-- constant (rather than inlined) so both the warning text and the
-- substitution below stay obviously in sync.
local FALLBACK_CONTRABAND_ALERT_TIERS = {
    { minWeight = 0,    alert = 'clean' },
    { minWeight = 1,    alert = 'whine' },
    -- KEEP IN STEP WITH config.lua's own Config.ContrabandAlertTiers. This
    -- table is documented as byte-identical to what config.lua ships, and it
    -- is only ever reached when an operator's own table fails validation --
    -- so a drift here would mean the safety net quietly restores a threshold
    -- nobody uses any more. Raised 250 -> 3000 alongside it; see that key's
    -- own comment in config.lua for the arithmetic.
    { minWeight = 3000, alert = 'aggressive_bark' },
}

--- Validates the shape Finding 1 (below) documents: a mandatory
--- `{ minWeight = 0, alert = 'clean' }` baseline at index 1, then every
--- later entry a table with a numeric `minWeight` at or above the previous
--- entry's -- exactly what ResolveAlertTier's own walk assumes. Never
--- throws on a malformed non-baseline entry (e.g. a bare string in the
--- list) -- returns `false` instead, unlike the ORIGINAL bare-assert
--- version of this check, which would have raised an unrelated
--- "attempt to index a nil value" from deep inside the loop for that exact
--- shape rather than this function's own clear message.
--- @param tiers any
--- @return boolean valid
--- @return string? reason -- only set when valid is false
local function ValidateContrabandAlertTiers(tiers)
    if type(tiers) ~= 'table' or tiers[1] == nil or type(tiers[1]) ~= 'table'
        or tiers[1].minWeight ~= 0 or tiers[1].alert ~= 'clean' then
        return false, "index 1 must be { minWeight = 0, alert = 'clean' } (the mandatory clean-search baseline)"
    end
    for i = 2, #tiers do
        local tier = tiers[i]
        if type(tier) ~= 'table' or type(tier.minWeight) ~= 'number' then
            return false, ('index %d must be a table with a numeric minWeight'):format(i)
        end
        if tier.minWeight < tiers[i - 1].minWeight then
            return false, ('must stay sorted ascending by minWeight (index %d, minWeight=%s, is lower than index %d\'s minWeight=%s)')
                :format(i, tostring(tier.minWeight), i - 1, tostring(tiers[i - 1].minWeight))
        end
    end
    return true
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- Finding 1: Config.ContrabandAlertTiers' zero-baseline entry and sort
    -- order are documented (config.lua's own comment above that table,
    -- and README.md) as mandatory, but ResolveAlertTier above only
    -- defaults to index 1 and its own doc comment admits it "does not
    -- assume the list is sorted defensively." If a server owner reorders
    -- this list or drops the { minWeight = 0, alert = 'clean' } entry, a
    -- genuinely clean search (totalWeight = 0) can resolve to whatever
    -- tier sits at index 1 -- including a non-'clean' tier -- which
    -- BroadcastContrabandAlert would then broadcast as a FALSE contraband
    -- alert about an innocent player to every bystander in range.
    --
    -- CLAMP AND WARN, DELIBERATELY NEVER THROW -- this used to be a pair of
    -- bare `assert`s. ResolveAlertTier and GetContrabandAlertTier both read
    -- `Config.ContrabandAlertTiers` fresh on every call (never a value
    -- cached from this handler), so overwriting Config.ContrabandAlertTiers
    -- itself with the built-in fallback here is sufficient to make every
    -- later call see the corrected table -- not merely a boot-time check
    -- that would otherwise protect nothing.
    local tiers = Config.ContrabandAlertTiers
    local tiersValid, tiersInvalidReason = ValidateContrabandAlertTiers(tiers)
    if not tiersValid then
        print(
            ('[qbx_k9unit] WARNING: Config.ContrabandAlertTiers %s (found: %s). A missing/re-ordered baseline or ' ..
             'out-of-order list would let ResolveAlertTier resolve a genuinely clean search to a non-\'clean\' ' ..
             'tier, or a real stash to the wrong severity -- using the built-in default tier list instead of ' ..
             'aborting this resource\'s config-safety guard over it. Fix Config.ContrabandAlertTiers in ' ..
             'config.lua to silence this warning.'
            ):format(tiersInvalidReason, tostring(tiers))
        )
        Config.ContrabandAlertTiers = FALLBACK_CONTRABAND_ALERT_TIERS
    end

    -- Finding 2: this file's own header above quotes the security review's
    -- BLOCKING requirement that BroadcastContrabandAlert's radius-filtered
    -- broadcast must never become a de facto global one, because (unlike
    -- relayBark) its payload identifies a specific vehicle/person just
    -- flagged for contraband -- a map-wide broadcast leaks that fact to an
    -- accomplice anywhere on the server. Nothing enforced an upper bound on
    -- the config value driving that filter, so a server owner setting
    -- alertBroadcastRadius to e.g. 5000.0 ("so everyone hears it") would
    -- silently defeat that entire design while leaving the code path
    -- looking correct. 200.0m is chosen as the ceiling: it is 5x the
    -- largest other legitimate detection distance in this resource
    -- (Config.Tracking's Scent/Blood/Gunpowder maxRange, all 40.0m) --
    -- generous enough to cover a busy search scene (a full parking lot, a
    -- multi-vehicle pursuit stop) -- while staying unambiguously local:
    -- two orders of magnitude below a map traversal, so this radius can
    -- never functionally become "everyone on the server hears it." THIS
    -- 200.0 CEILING IS ENFORCED HERE IN CODE ONLY -- config.lua's own
    -- comment on this field does not mention it; see this file's own
    -- header pointer added alongside this pass for the fix to that gap.
    --
    -- CLAMP AND WARN, DELIBERATELY NEVER THROW -- this used to be a bare
    -- `assert`. BroadcastContrabandAlert reads
    -- `Config.SearchZones.alertBroadcastRadius` fresh on every call, so
    -- clamping the value in place here is sufficient for every later call
    -- to see the corrected radius.
    local rawRadius = Config.SearchZones.alertBroadcastRadius
    if type(rawRadius) ~= 'number' or rawRadius ~= rawRadius then
        print(
            ('[qbx_k9unit] WARNING: Config.SearchZones.alertBroadcastRadius (%s) is missing or not a number -- ' ..
             'using a built-in fallback of 40.0m (this resource\'s other legitimate detection distances\' own ' ..
             'maxRange) instead of aborting this resource\'s config-safety guard over it. Fix ' ..
             'Config.SearchZones.alertBroadcastRadius in config.lua to silence this warning.'
            ):format(tostring(rawRadius))
        )
        Config.SearchZones.alertBroadcastRadius = 40.0
    elseif rawRadius > 200.0 then
        print(
            ('[qbx_k9unit] WARNING: Config.SearchZones.alertBroadcastRadius (%s) exceeds the 200.0 hard safety ' ..
             'ceiling -- it is not a server-tunable-to-anything toggle. This resource\'s contraband alert ' ..
             "broadcast is deliberately distance-filtered (never a global TriggerClientEvent(-1, ...) like " ..
             "relayBark's) because its payload identifies a specific vehicle/person just flagged for " ..
             'contraband -- setting this radius above the ceiling would leak that fact to an accomplice ' ..
             'anywhere on the server. Clamping DOWN to 200.0 instead of aborting this resource\'s ' ..
             'config-safety guard over it. Fix Config.SearchZones.alertBroadcastRadius in config.lua to ' ..
             'silence this warning.'
            ):format(tostring(rawRadius))
        )
        Config.SearchZones.alertBroadcastRadius = 200.0
    end
end)

-- ======================================================================
-- PER-PERSON FEATURE CONTROL (Config.FeatureControl -- config.lua's own
-- header documents the 4-step resolution; step 1, Config.Features.<Name>,
-- is checked separately by each call site below before this function is
-- ever reached). Mirrors server/pursuitsprint.lua's
-- IsPursuitSprintPermittedForCitizenId shape verbatim (that file's own
-- header says to read it before writing another variant) -- GENERALIZED
-- (was hardcoded to 'SearchZones' only) to accept a `featureName`
-- parameter, same "one file, several independently-gated flags through the
-- identical shape" pattern server/tracking.lua's own
-- IsTrackingFeaturePermittedForCitizenId and server/wellbeing.lua's own
-- IsWellbeingFeaturePermittedForCitizenId already establish for exactly
-- this reason: this file now gates TWO independent Config.Features flags
-- (SearchZones, and ContrabandAlerts below) through one shared helper
-- rather than a near-duplicate second copy. BEHAVIOR UNCHANGED for both
-- existing SearchZones call sites below -- each now passes 'SearchZones'
-- explicitly where the string used to be a hardcoded literal inside this
-- function, so `HasPermission(citizenid, 'block.SearchZones')` /
-- `'feature.SearchZones'` / `RequireGrant.SearchZones` are read identically
-- to before this rename.
-- ======================================================================
--- @param citizenid string
--- @param featureName string -- exact Config.Features key: 'SearchZones' | 'ContrabandAlerts'
--- @return boolean allowed
local function IsSearchFeaturePermittedForCitizenId(citizenid, featureName)
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

--- Resolves the CALLING searcher's own citizenid -- shared by both
--- IsSearchFeaturePermittedForCitizenId call sites below (request-time and
--- the mid-flight re-check) so there is exactly one place this resolution
--- is written. Never anything client-supplied -- `source` is ox_lib's own
--- callback-verified value both times this is called.
--- @param source number
--- @return string? citizenid
local function ResolveSearcherCitizenidForPermission(source)
    local player = exports.qbx_core:GetPlayer(source)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

-- In-flight mutex per source (DEVELOPER_REFERENCE.md#contraband-search §4A). Set
-- synchronously, BEFORE any yielding work, checked immediately after the
-- cheap validation steps (payload shape, feature flag, access) and before
-- any cooldown/entity-resolution work, cleared on EVERY exit path
-- (success, failure, AND error) so a thrown error inside the ox_inventory
-- call doesn't permanently wedge that source out of ever searching again.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `SearchInFlight`
-- boolean table, now a NewMutex() instance (server/cooldowns.lua) — same
-- per-source key, same "reject outright" semantics (TryAcquire combines
-- the old table's check-then-set into one atomic call), same
-- playerDropped-based cleanup (see SearchMutex.RegisterPlayerDropped()
-- below), behavior unchanged.
local SearchMutex = NewMutex()
SearchMutex.RegisterPlayerDropped()

--- Is `source` currently the requester of a real, in-flight (server-side)
--- searchTarget call? Read-only accessor over this file's own file-local
--- SearchMutex — same "global helper, private per-file state" convention
--- as server/combat.lua's own CountActiveHoldsByEffectType/
--- EndActiveEffectForHolder. NOW WIRED (verified by reading
--- server/combat.lua directly): the "search remains chainable with combat
--- while the progress bar is running" question this section investigated
--- had TWO directions —
---   1. block a search from STARTING while the K9 is already mid-bite/
---      mid-takedown/mid-drag — CLOSED, see IsSearcherBusyElsewhere above
---      (IsK9CurrentlyHolding).
---   2. block a bite/takedown/drag from STARTING while a search is
---      genuinely mid-flight server-side (SearchMutex held for that
---      source) — this used to say NOT closed, pending an edit inside
---      server/combat.lua's ValidateCombatRequest outside this file's
---      ownership. That edit has since landed there verbatim: `if
---      type(IsSearchInProgressForSource) == 'function' and
---      IsSearchInProgressForSource(src) then return false, ...,
---      'busy_searching' end`, same soft-dependency-guard convention as
---      every other cross-file read in this codebase.
--- Never mutates SearchMutex, never affects an in-flight search's own
--- outcome — pure read.
--- @param source number
--- @return boolean
function IsSearchInProgressForSource(source)
    return SearchMutex.IsHeld(source)
end

-- Flat per-source cooldown — BLOCKING per
-- DEVELOPER_REFERENCE.md#contraband-search §2 ("nothing stops a single
-- source from searching many different targets back-to-back with zero
-- delay"). Sized around Config.SearchZones.sniffAnimDurationMs (that
-- finding's own suggestion). Mirrors BARK_COOLDOWN_MS/lastBarkAt's exact
-- shape in server/main.lua. Cleared on playerDropped.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastSearchAt`
-- table, now a NewCooldown() instance — same per-source key, same
-- playerDropped-based cleanup. NOTE the stamp for this cooldown still
-- happens inside HandleSearchTarget (via :Touch, alongside the per-target
-- cooldown), NOT at the point the check below runs — preserved exactly as
-- the original code was written (the flat cooldown is CHECKED early, in
-- the callback registration below, but only STAMPED later, once the
-- search actually proceeds past entity/type/proximity validation).
local SearchCooldown = NewCooldown()
SearchCooldown.RegisterPlayerDropped()

-- Per-resolved-target cooldown backing Config.SearchZones.searchCooldownMs
-- — keyed on the RESOLVED, STABLE identity (plate for vehicles; citizenid
-- for persons, per DEVELOPER_REFERENCE.md#contraband-search §7's "survives a
-- ped-recreation edge case" note), NOT the raw client-supplied
-- `targetNetId` (recyclable/spoofable-adjacent, DEVELOPER_REFERENCE.md#contraband-search
-- §4B). Outlives any single player's connection (a plate persists after
-- the searching officer disconnects), so — unlike SearchCooldown/SearchMutex
-- above — this table needs its OWN independent TTL-based sweep instead of
-- playerDropped-based cleanup, see the :StartSweep call below.
--
-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastTargetSearchAt`
-- table + `PruneTargetSearchCooldowns` sweep thread, now a NewCooldown()
-- instance with :StartSweep (server/cooldowns.lua) — same resolved-identity
-- string key, same staleness rule/interval, behavior unchanged.
local TargetSearchCooldown = NewCooldown()

-- Precomputed contraband item info, built once at file load (config.lua is
-- a shared_script loaded before this file). O(1) lookup instead of
-- re-scanning Config.SearchContrabandItems per inventory slot.
--
-- SPECIALIZATION CATEGORIES (owner-directed decluttering pass, 2026-08-26 --
-- see Config.SearchContrabandItems' own config.lua comment for the full
-- plain-English writeup). Config.SearchContrabandItems now mixes TWO entry
-- shapes in one table -- a plain array entry (`'weed_bud'`, integer key,
-- string value: UNCATEGORISED) and a keyed entry
-- (`coke_brick = 'narcotics'`, string key, string value: CATEGORISED by a
-- Config.K9Specializations key) -- iterating with a single `pairs()` pass
-- below naturally handles both without needing two separate loops: Lua's
-- `pairs()` visits every key regardless of whether it came from the
-- table's array part or its hash part, and `type(key)` alone tells the two
-- shapes apart unambiguously (a plain array's own keys are ALWAYS the
-- integers 1..n).
--
-- `ContrabandItemInfo[itemName] = { category = nil }` -- uncategorised,
-- found by every K9 with search access (the pre-existing behavior, and the
-- shipped default's own shape, so an upgrading server's results do not
-- change until an owner deliberately categorises an item).
-- `ContrabandItemInfo[itemName] = { category = 'narcotics' }` -- found
-- only by a searcher who currently holds that Config.K9Specializations key
-- (HasSpecialization, resolved per-request in HandleSearchTarget below).
--
-- CLAMP AND WARN (never assert -- a bare top-level assert in this codebase
-- kills every registration below it silently for the whole server uptime):
-- a keyed entry naming a category that is not a real Config.K9Specializations
-- key degrades to UNCATEGORISED (found by everyone) with one console
-- warning, rather than erroring or silently vanishing from the contraband
-- list entirely -- an unfindable-by-anyone item would be a much worse
-- failure mode for a search-and-detection feature than one that is simply
-- less selective than the (malformed) config asked for.
local ContrabandItemInfo = {}
do
    local knownSpecializations = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    local rawList = type(Config.SearchContrabandItems) == 'table' and Config.SearchContrabandItems or {}
    for key, value in pairs(rawList) do
        if type(key) == 'number' then
            -- Array entry: `value` is the item name, uncategorised.
            if type(value) == 'string' then
                ContrabandItemInfo[value] = { category = nil }
            end
        elseif type(key) == 'string' then
            -- Keyed entry: `key` is the item name, `value` is the category.
            if type(value) == 'string' and knownSpecializations[value] ~= nil then
                ContrabandItemInfo[key] = { category = value }
            else
                print(('[qbx_k9unit] WARNING: Config.SearchContrabandItems[%q] names category %q, which is not a key in Config.K9Specializations -- treating %q as UNCATEGORISED (found by every K9 with search access) instead. Fix Config.SearchContrabandItems or Config.K9Specializations in config.lua to silence this warning.'):format(key, tostring(value), key))
                ContrabandItemInfo[key] = { category = nil }
            end
        end
    end
end

--- Resolves the set of Config.K9Specializations categories `citizenid`
--- currently holds (HasSpecialization, server/certifications/ -- carries
--- that function's own High Command bypass). Used to scope
--- SumContrabandWeight below to only the CATEGORISED items this specific
--- searcher is entitled to, on top of the UNCATEGORISED baseline every K9
--- always gets (see ContrabandItemInfo's own header for the full,
--- deliberately monotonic design -- there is no "holds nothing -> counts
--- everything" fallback here: an empty/absent set here simply means zero
--- categorised items count, which is exactly correct, since uncategorised
--- items are never gated by this set at all).
--- @param citizenid string?
--- @param jobName string?
--- @return table<string, boolean> heldCategories
local function ResolveHeldContrabandCategoriesForCitizenId(citizenid, jobName)
    local held = {}
    if type(HasSpecialization) ~= 'function' or type(citizenid) ~= 'string' then
        return held -- soft dependency, this resource's established convention -- no specialization data available, so no categorised item can ever match (uncategorised items are unaffected -- see this function's own doc comment)
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

-- Container recursion depth cap (DEVELOPER_REFERENCE.md#contraband-search §2 —
-- "an explicitly chosen max depth (e.g. 3) — not unbounded, and not
-- skipped"). Deliberately a LOCAL implementation constant, not a
-- Config.* field — recursion depth is an internal defensive bound of this
-- file's own scan logic, not a server-owner tuning knob.
local MAX_CONTAINER_RECURSION_DEPTH = 3

--- Recursively sums the weight of every slot (top-level + nested
--- containers, up to MAX_CONTAINER_RECURSION_DEPTH) in `items` whose
--- `.name` is a configured contraband item (DEVELOPER_REFERENCE.md#contraband-search
--- §2 — "must-handle, not optional polish": a naive top-level-only scan
--- will not match a bag's OWN item name against Config.SearchContrabandItems,
--- so "put the drugs in a bag" would otherwise be a trivial, fully-defeating
--- bypass). `.weight` on each ItemSlot is ALREADY the total weight for
--- that slot (item.weight * slot.count, plus adjustments) per the
--- contract doc's confirmed read of the real ox_inventory source — do NOT
--- re-multiply by `.count` here, that would double-count.
--- @param inventoryId string|number -- needed to resolve child containers via GetContainerFromSlot
--- @param items table<number, table>? -- GetInventoryItems' return shape
--- @param depth number -- 1 for the initial top-level call
--- @param heldCategories table<string, boolean> -- ResolveHeldContrabandCategoriesForCitizenId's result for THIS searcher, reused unchanged across every recursive call so a category held/not-held decision can never drift mid-scan
--- @return number totalWeight
local function SumContrabandWeight(inventoryId, items, depth, heldCategories)
    local total = 0
    if not items then return total end

    for _, slot in pairs(items) do
        -- SPECIALIZATION-SCOPED (owner-directed decluttering pass,
        -- 2026-08-26) -- see ContrabandItemInfo's own header for the full
        -- writeup. An UNCATEGORISED item (`info.category == nil`) always
        -- counts, for every searcher, no matter what heldCategories
        -- contains -- this is the monotonic baseline. A CATEGORISED item
        -- only counts if `heldCategories` contains that exact category key.
        local info = ContrabandItemInfo[slot.name]
        if info and (info.category == nil or heldCategories[info.category]) then
            total = total + (slot.weight or 0)
        end

        if depth < MAX_CONTAINER_RECURSION_DEPTH then
            -- A non-container slot simply resolves to nil/false here —
            -- pcall-wrapped since a mid-scan entity/inventory change could
            -- make this error rather than cleanly return nil. ROUTED THROUGH
            -- K9Compat.Get('inventory') --
            -- shared/compat/core.lua's
            -- RequiredMethods.inventory.server.GetContainerFromSlot -- never
            -- a direct `exports.ox_inventory:GetContainerFromSlot` call. The
            -- adapter itself never throws (BuildSafeAdapter, shared/compat/
            -- core.lua) so this outer pcall is now pure defense-in-depth,
            -- kept unchanged rather than removed -- it cost nothing before
            -- and costs nothing now.
            local containerOk, containerInv = pcall(function()
                return K9Compat.Get('inventory').GetContainerFromSlot(inventoryId, slot.slot)
            end)
            if containerOk and containerInv and containerInv.items then
                total = total + SumContrabandWeight(containerInv.id or inventoryId, containerInv.items, depth + 1, heldCategories)
            end
        end
    end

    return total
end

--- Resolves `totalWeight` to a tier from Config.ContrabandAlertTiers.
--- The config's baseline
--- `{ minWeight = 0, alert = 'clean' }` entry is mandatory and sorted
--- first (ascending by minWeight) — walk the whole list and keep the LAST
--- tier whose minWeight the total meets or exceeds, so a zero-contraband
--- result always resolves to 'clean' rather than falling through
--- unhandled. Does not assume the list is sorted defensively (falls back
--- to the first entry if somehow none matched, which cannot happen given
--- the mandatory `minWeight = 0` baseline, but avoids ever returning nil).
--- @param totalWeight number
--- @return table tier -- { minWeight, alert }
local function ResolveAlertTier(totalWeight)
    local resolvedTier = Config.ContrabandAlertTiers[1]
    for _, tier in ipairs(Config.ContrabandAlertTiers) do
        if totalWeight >= tier.minWeight then
            resolvedTier = tier
        end
    end
    return resolvedTier
end

--- Resource-global test/inspection seam — see FILE-TO-FILE CONTRACT above.
--- Identical role to server/progression.lua's `GetXPTier` over its own
--- file-local `ResolveTier`: a thin, deliberately dumb pass-through that
--- lets a test agent exercise this file's pure, boundary-sensitive tier
--- walk directly, without also having to drive entity resolution,
--- recursive ox_inventory container reads, natives, or SearchMutex/
--- SearchCooldown/TargetSearchCooldown/ContrabandXpState.
---
--- DELIBERATELY NOT A NEW CAPABILITY GRANT (do not widen this signature to
--- accept a target/netId/source and resolve anything real internally —
--- that would reopen exactly the "map-wide contraband oracle" hole
--- HandleSearchTarget's own validation order exists to close). This
--- function only ever sees a plain `number` the caller already has and
--- returns a `Config.ContrabandAlertTiers` entry — it performs, and can
--- never be made to perform via any argument, an ox_inventory read, a
--- HasK9Access check, an entity/proximity check, or a cooldown check.
--- Calling this with a fabricated totalWeight teaches a caller nothing
--- about any real player's or vehicle's actual contraband; the one real
--- capability grant this file's header claims certifications.lua-level
--- scrutiny for — reading a target's REAL, live inventory — lives
--- entirely inside HandleSearchTarget above and is untouched by, and
--- unreachable through, this wrapper.
--- @param totalWeight number
--- @return table tier -- { minWeight, alert }
function GetContrabandAlertTier(totalWeight)
    return ResolveAlertTier(totalWeight)
end

--- Iterates every currently-connected player and calls
--- `callback(playerId, playerPed)` for each one currently within `radius`
--- meters of `coords` — a live, server-computed distance check, never a
--- client-claimed one. Pure read-only helper: never mutates any of this
--- file's own state, never gates on HasK9Access/Config.Features/anything
--- else — callers apply their own gating before or inside `callback`, same
--- division of responsibility as this codebase's other shared,
--- single-purpose accessors (e.g. server/combat.lua's
--- CountActiveHoldsByEffectType).
---
--- Extracted from BroadcastContrabandAlert's own original inline loop
--- (below) into a named, reusable, resource-global helper (this resource's
--- established "global helper, private per-file state" convention) so
--- server/main.lua's relayBark/relayDoorScratch — a PERFORMANCE fix, not a
--- security one, see those two handlers' own comments for why an
--- unfiltered `-1` broadcast was never a privacy leak for either of them,
--- unlike THIS file's own BroadcastContrabandAlert below — can reuse the
--- exact same "who is genuinely near this point right now" logic instead
--- of each hand-rolling its own GetPlayers()/GetPlayerPed()/distance loop.
--- Behavior is byte-identical to the original inline loop; this is a pure
--- extraction, not a rewrite.
--- @param coords vector3
--- @param radius number
--- @param callback fun(playerId: number, playerPed: number)
function ForEachNearbyPlayer(coords, radius, callback)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if playerId then
            local ped = GetPlayerPed(playerId)
            if ped ~= 0 then
                local dist = #(GetEntityCoords(ped) - coords)
                if dist <= radius then
                    callback(playerId, ped)
                end
            end
        end
    end
end

--- BLOCKING per DEVELOPER_REFERENCE.md#contraband-search §1: notifies only
--- players within Config.SearchZones.alertBroadcastRadius of the TARGET's
--- own live coordinates (via ForEachNearbyPlayer above) — NEVER a global
--- TriggerClientEvent(-1, ...) like relayBark's, since (unlike a bark) this
--- payload identifies a specific vehicle/person just flagged for
--- contraband; a global broadcast would leak that fact to an accomplice
--- anywhere on the map. Payload carries ONLY `targetNetId` + `alertTier` —
--- NEVER `totalWeight`/`contrabandFound` (security review §1's "secondary"
--- finding).
--- @param targetCoords vector3 -- the searched target's own live coords, resolved server-side
--- @param targetNetId number -- the searched target's own netId (client-supplied but already verified to resolve to this exact entity by the time this is called)
--- @param alertTierName string
local function BroadcastContrabandAlert(targetCoords, targetNetId, alertTierName)
    ForEachNearbyPlayer(targetCoords, Config.SearchZones.alertBroadcastRadius, function(playerId)
        TriggerClientEvent('qbx_k9unit:client:playContrabandAlert', playerId, targetNetId, alertTierName)
    end)
end

-- An entry older than its own cooldown window is by definition no longer
-- doing any rate-limiting work and is safe to drop (DEVELOPER_REFERENCE.md#contraband-search
-- §4). Not the same table/schedule as server/tracking.lua's TrackableLog
-- prune pass — unrelated tables, unrelated reasons, do not merge the
-- threads.
local TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS = 60000

TargetSearchCooldown.StartSweep(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    local staleAfterMs = Config.SearchZones.searchCooldownMs * 2
    return (now - loggedAt) > staleAfterMs
end)

-- ECONOMY-AUDIT FIX: Config.SearchZones.searchCooldownMs (the
-- per-TARGET-ONLY cooldown above — CORRECTION: no
-- searcher dimension at all, shared across every source) and
-- Config.SearchZones.sniffAnimDurationMs
-- (the flat per-source cooldown at HandleSearchTarget's own callback
-- registration below) exist ONLY to keep repeat searches from harassing the
-- same target or flooding this callback — neither was ever a
-- searcher-dimension XP throttle, and TargetSearchCooldown's key
-- (resolved target identity only) means it does not, and structurally
-- cannot, throttle ONE K9 rotating across MANY targets. A K9 planting
-- contraband in a small handful of their own stashes and rotating across
-- them lands a real (not on-cooldown) search roughly every
-- sniffAnimDurationMs regardless of how many stashes they own — with 3
-- stashes that is ~15 searches/min * Config.XP.awards.searchContrabandFound
-- (25) = ~22,500 XP/hr, reaching the top XP tier in well under ten minutes.
--
-- FIX: the XP side needed fixing here, not the
-- search side (search itself must stay fully responsive — HandleSearchTarget's
-- own doc comment above already documents multiple distinct legitimate K9
-- officers each searching the same target as intended behavior, and that
-- must keep working unchanged). XP for a given resolved target identity
-- (`cooldownKey` below — the exact same stable 'vehicle:<plate>' |
-- 'person:<citizenid>' string TargetSearchCooldown already keys on, never
-- anything client-supplied) is only ever paid the FIRST time contraband is
-- found there, and again only once that target's contraband composition has
-- genuinely CHANGED since the last time XP was paid for it (weight differs
-- — covers a top-up, a partial seizure, or a full seizure-then-replant).
-- Re-searching the SAME untouched stash — however many times, however fast
-- — pays zero additional XP: doing so reflects no new police work, just
-- repeat confirmation of a fact already rewarded once. A genuine officer
-- working a scene where contraband keeps changing (evidence intake, a
-- suspect topping up) keeps earning normally; a farmer who never actually
-- touches their own planted stash cannot re-earn from it no matter how many
-- stashes they rotate across or how tight the request cadence is.
--
-- CORRECTION (the paragraph above
-- overstated what a weight-changed check alone can guarantee): "no matter
-- how tight the request cadence is" was never true for a farmer who DOES
-- touch their own stash — a profile the paragraph's own final clause
-- ("a farmer who never actually touches...") already implicitly excluded,
-- but the surrounding sentence reads as a blanket cadence-proof guarantee,
-- which is misleading. A farmer who moves one
-- contraband item in or out of their own controlled vehicle trunk/stash
-- BETWEEN searches changes totalWeight on every single cycle, satisfying
-- `contrabandChangedSinceLastAward` below every time — and
-- TargetSearchCooldown above (Config.SearchZones.searchCooldownMs, 10s
-- shipped) is the ONLY other throttle in play, is keyed purely on the
-- resolved TARGET identity with no searcher dimension at all (shared
-- across every source, per this file's header CORRECTION note on that
-- table), and was never an XP throttle to begin with (see this table's own
-- opening paragraph above). Net effect: a single officer, alone, toggling
-- one item roughly every 10 seconds, cleared a fresh "changed since last
-- paid weight" reading on every search — Config.XP.awards.searchContrabandFound
-- (25 shipped) about six times a minute, ~9,000 XP/hr, roughly 7.5x
-- server/tracking.lua's own correctly-capped trackSourceResolved ceiling
-- (its TrackTicketMintCooldown, 30s @ 10 XP = 1,200 XP/hr) — solo, with no
-- collusion and no risk, at any cadence the officer cared to use.
--
-- FIFTH XP-FARM FIX: closed by
-- `ContrabandXpMintCooldown` below, ported from tracking.lua's own
-- TrackTicketMintCooldown shape — a flat, per-SEARCHER cooldown on the MINT
-- itself, required IN ADDITION TO (never instead of) this table's own
-- weight-changed check, gating only the AwardXP call inside
-- HandleSearchTarget's award block below (search success, the contraband
-- alert, ContrabandScreenFX, and the k9_search_log audit row are all
-- computed/fired earlier in that function and are entirely unaffected by
-- this cooldown). The NOW-ACCURATE claim, restated: a farmer cannot re-earn
-- from a given target faster than once per
-- CONTRABAND_XP_MINT_COOLDOWN_MS-worth of real time has passed for THAT
-- SEARCHER, regardless of how many stashes they rotate across, how tight
-- the request cadence is, or whether they touch the stash at all — see
-- ContrabandXpMintCooldown's own declaration comment, right after this
-- table, for the full mechanism.
--
-- Deliberately a plain per-target `{ weight, awardedAt }` cache, NOT a
-- NewCooldown/NewNestedCooldown instance from server/cooldowns.lua — this
-- is not a "has enough time elapsed" check, it's a "did the underlying fact
-- change" check, exactly the same "different shape entirely, do not force
-- it onto the cooldown constructors" reasoning server/cooldowns.lua's own
-- header already gives, almost verbatim, for server/tracking.lua's
-- TrackableLog (an aged/scanned log, not a `key -> lastTouchedAtMs` map).
--
-- FOURTH XP-FARM FIX (the "assume a fourth
-- farm exists" audit): this table used to be pruned by its own periodic
-- sweep, evicting any entry whose `awardedAt` was more than
-- CONTRABAND_XP_STATE_TTL_MS (30 minutes) old. That sweep silently
-- reopened the exact farm this table exists to close: `awardedAt` is only
-- ever refreshed by an actual NEW award, never by a re-search that found
-- the SAME unchanged weight (that case intentionally never writes to this
-- table at all — see `contrabandChangedSinceLastAward` at this table's
-- read/write site below, which only assigns a fresh entry when it's true).
-- So a farmer who planted one stash, got paid once, and then did
-- ABSOLUTELY NOTHING to it for 30 minutes caused their own entry to
-- silently expire — the very next re-search of that still-untouched stash
-- then read as brand new (`not priorAwardState`) and paid again, forever
-- repeatable on a ~30-minute cadence with zero re-work, zero risk, and any
-- number of parallel stashes. That flatly contradicts this fix's own
-- stated guarantee ("Re-searching the SAME untouched stash — however many
-- times, however fast — pays zero additional XP" / "cannot re-earn from it
-- no matter... how tight the request cadence is" above) — the guarantee
-- was never actually "no matter the cadence," only "no faster than once
-- per 30 minutes," and that was never disclosed as the real, much weaker
-- shape of the protection.
--
-- FIX: no time-based eviction at all. An entry, once created, is kept for
-- this resource's entire uptime — the "have we ever paid XP for this exact
-- target at this exact weight" fact this table exists to remember must
-- never silently reset itself, or the farm it closes reopens on whatever
-- cadence the eviction window allows, no matter how that window is sized.
-- Memory growth is bounded by genuine distinct-contraband-catch cardinality,
-- not attacker-inflatable for free: an entry is only ever created from
-- inside HandleSearchTarget's own `contrabandFound == true` branch below,
-- which already required a real HasK9Access(source) officer, a real
-- proximity-checked search, and a real non-empty ox_inventory read to
-- reach — the same "real work required per entry" property sql/install.sql's
-- own permanent, never-pruned `k9_search_log` audit table already accepts
-- for the exact same reason. Re-searching the SAME target, however many
-- times, adds nothing further to this table's size (it either updates the
-- one existing entry in place or touches nothing) — table growth is capped
-- by how many DIFFERENT real targets have ever been caught with contraband
-- on this server, not by how many times any of them is re-checked.
local ContrabandXpState = {} -- [cooldownKey] = { weight = number, awardedAt = <GetGameTimer() ms> } — permanent for this resource's uptime, see comment above for why it must never be time-evicted

-- FIFTH XP-FARM FIX — see the CORRECTION note on
-- ContrabandXpState's own declaration comment immediately above for the
-- full exploit writeup this closes. Ported from server/tracking.lua's
-- TrackTicketMintCooldown (see that file's own declaration comment for the
-- near-identical-shape economy-audit finding this mirrors): a flat,
-- per-SEARCHER (never per-target — that dimension is exactly what
-- TargetSearchCooldown above already covers, and exactly the dimension a
-- self-toggling or colluding searcher does not need to vary at all) cooldown
-- on ticket-MINTING itself, independent of how cheaply a fresh
-- weight-changed reading can be produced. Unlike ContrabandXpState above,
-- this really IS a flat "has enough time elapsed" check (not a "did the
-- underlying fact change" cache), so it gets the standard NewCooldown()
-- constructor like every other timing tracker in this file, rather than
-- ContrabandXpState's bespoke shape.
--
-- CONSUMED, not just checked, at the exact point a real award is about to
-- happen (see the call site inside HandleSearchTarget's AwardXP block
-- below) — deliberately ordered AFTER `contrabandChangedSinceLastAward` is
-- known to be true, mirroring TrackTicketMintCooldown's own "ordered after
-- not nearestEntry.ticketIssued" placement for the identical reason: a
-- re-search that finds the SAME unchanged weight was never going to pay
-- anything regardless, so it must never spend this per-searcher budget for
-- nothing. When a weight-changed search arrives while this budget is still
-- spent, it is NOT queued or retried — it simply doesn't pay THIS time, and
-- ContrabandXpState above is deliberately left UNUPDATED for that skipped
-- award (the write into ContrabandXpState and the AwardXP call share one
-- `if` condition at that call site) — so the next weight-changed search,
-- however much later, still correctly reads as "changed since the last PAID
-- weight" and pays once this cooldown allows, rather than the skipped
-- attempt being silently treated as though it had already been paid.
--
-- CONTRABAND_XP_MINT_COOLDOWN_MS is a LOCAL implementation constant, not a
-- Config.* field — same "internal defensive bound, not a server-owner
-- tuning knob" posture MAX_CONTAINER_RECURSION_DEPTH above already
-- establishes for this file, and the exact choice tracking.lua's own
-- TRACK_TICKET_MINT_COOLDOWN_MS makes for the identical reasoning: this is
-- an anti-farm floor on the economy, not a legitimate per-server tuning
-- preference the way e.g. searchCooldownMs's UX-harassment threshold is. An
-- operator being able to self-service this back down to an unsafe value (or
-- to 0, which server/cooldowns.lua's own NewCooldown documents as "fails
-- CLOSED, not disabled" — never a safe operator escape hatch) would reopen
-- exactly the farm this constant exists to close, with no assertion able to
-- catch a merely-too-low-but-still-positive value the way
-- AssertValidDefaultThreshold catches a non-positive one. Sized at 60000
-- (60s): at
-- Config.XP.awards.searchContrabandFound's shipped value of 25, this caps
-- the award at 1,500 XP/hr per searcher — the same order of magnitude as
-- server/tracking.lua's own trackSourceResolved ceiling (TrackTicketMintCooldown
-- @ 30s / 10 XP = 1,200 XP/hr), with headroom justified by contraband
-- search requiring genuine live proximity to a real target and a real
-- ox_inventory read on every single attempt (never true of a pure
-- resolve-then-arrive reveal), while landing nowhere close to the ~9,000
-- XP/hr this closes.
local ContrabandXpMintCooldown = NewCooldown()
ContrabandXpMintCooldown.RegisterPlayerDropped()
local CONTRABAND_XP_MINT_COOLDOWN_MS = 60000

-- EIGHTH XP-FARM FIX, CROSS-FILE POINTER (compound farm across mechanics):
-- this cooldown's own 1,500 XP/hr ceiling is real and
-- unchanged, but it was never summed against server/tracking.lua's
-- TrackTicketMintCooldown (1,200 XP/hr) or server/combat.lua's
-- BiteHoldXpMintCooldown/TakedownXpMintCooldown (1,200 + 1,800 XP/hr) --
-- all four keyed by the same acting player, combining to 5,700 XP/hr
-- uncapped. CLOSED by server/progression.lua's new SHARED, cross-mechanic
-- XP mint budget (XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS, consulted
-- inside AwardXP itself) -- see that file's own declaration comment for the
-- full derivation. Nothing in THIS file needed to change for that half of
-- the fix: AwardXP is the single chokepoint this file's own award call site
-- already goes through. ContrabandXpMintCooldown above is KEPT, unchanged
-- -- it still shapes how often THIS mechanic can mint; the shared budget in
-- server/progression.lua caps the TOTAL across mechanics.

-- ==========================================================================
-- COOPERATIVE SEARCH BONUS -- DEVELOPER_REFERENCE.md Part B §10.
-- When a search's own AwardXP('searchContrabandFound') actually
-- fires (i.e. already passed every existing gate below: HasK9Access,
-- proximity, TargetSearchCooldown, the weight-changed check, and
-- ContrabandXpMintCooldown), and the searcher currently has an ACTIVE
-- partner (server/partnership.lua's GetActivePartnerCitizenId) who is
-- ONLINE, PHYSICALLY PRESENT at the search scene, and TRAINED-TIER-OR-ABOVE
-- (server/progression.lua's GetXPTier -- SAME as the searcher, see the
-- SPEC DEFINITION below) -- award that partner a smaller bonus via a
-- SEPARATE actionKey, through the SAME AwardXP chokepoint everything else in
-- this file already uses. Never a new subsystem: reuses the partnership
-- registry, the XP award path, and this file's own existing success branch,
-- exactly as the doc's own "Needs" section describes.
--
-- SPEC DEFINITION, an explicit judgment call on the doc's own open question
-- ("same search, same session, physically both present?" -- worth a short
-- spec pass, not a design fork): "cooperative" here means ALL of --
--   1. an ACTIVE partnership (server/partnership.lua) between the searcher
--      and the receiving citizenid, at the moment of the find;
--   2. the partner currently ONLINE (co-op is real-time cooperation, not "I
--      have a partner registered somewhere");
--   3. the partner's live ped within COOP_SEARCH_PARTNER_PROXIMITY_METERS of
--      the SEARCHED TARGET's own live coords (contract_search's own
--      `targetCoords`, already resolved and validated by the time this
--      runs) -- "physically both present at the scene," not "anywhere on
--      the map";
--   4. BOTH the searcher and the partner at Trained tier or above
--      (Config.XPTiers[1].xp == 0 is the mandatory base-tier baseline per
--      server/progression.lua's own onResourceStart guard, so `tier.xp > 0`
--      correctly means "at or above the second tier" without hardcoding a
--      label or index) -- Part B §8's Trained-tier unlock
--      (server/progression.lua's own "XP TIER UNLOCKS" section), reserving
--      cooperative work for K9 teams who have each independently earned
--      past the base tier, not brand-new accounts.
-- Deliberately NOT extended to server/tracking.lua's own award -- out of
-- scope here (the doc's own narrower "Needs"
-- text names server/search.lua specifically) -- no edit needed
-- there.
--
-- WHY THIS CANNOT BECOME A NEW, EASIER-TO-HIDE FARM (the arithmetic that
-- rules it out):
--
--   UNCAPPED TAP RATE, if this bonus existed OUTSIDE the shared budget:
--     Config.XP.awards.coopSearchBonus (10 XP) is paid at most once per
--     CoopSearchXpMintCooldown's own 60,000ms window, PER RECEIVING
--     PARTNER (keyed by the partner's own citizenid, independent of which
--     partner is doing the searching) -- an uncapped ceiling of
--     3,600,000ms / 60,000ms * 10 XP = 60 * 10 = 600 XP/hr for ONE partner
--     continuously receiving the bonus from ONE actively-searching partner.
--   COMBINED WITH THE EXISTING UNCAPPED BASELINE: this project's own EIGHTH
--     XP-FARM FIX (server/progression.lua) already established the four
--     existing mechanics sum to 5,700 XP/hr uncapped for a single citizenid
--     round-robining all of them. A citizenid who ALSO receives this new
--     600 XP/hr tap (e.g. by having their partner search on their behalf
--     while they themselves grind everything else) reaches
--     5,700 + 600 = 6,300 XP/hr UNCAPPED -- comfortably over the existing
--     3,600 XP/hr shared budget ceiling. That means it MUST be routed
--     through the same budget, not around it.
--   ROUTED THROUGH THE SAME BUDGET, NOT AROUND IT: the payout below is
--     minted via AwardXP(partnerCitizenid, 'coopSearchBonus') -- the exact
--     same, single, resource-wide chokepoint every other actionKey already
--     goes through, with no special case. server/progression.lua's shared
--     XP_MINT_BUDGET_CAP_XP/XP_MINT_BUDGET_WINDOW_MS token bucket is keyed
--     PER CITIZENID, across EVERY actionKey -- it does not know or care
--     which mechanic is asking. Its own realized-throughput property (see
--     that file's own "Re-verified by direct simulation" note: continuous
--     max-rate draw from FOUR competing mechanics already converges to the
--     bucket's fixed REFILL rate, ~3,600 XP/hr, once aggregate demand
--     exceeds that supply -- which it already did at 5,700 XP/hr, before
--     this feature existed) means adding a FIFTH competing draw (this
--     bonus) cannot raise that ceiling: a supply-bound resource's payout
--     rate is set by its own refill rate, not by how many demand sources
--     compete for it. The receiving partner's TOTAL realized XP/hr (their
--     own actions plus every coop bonus they receive) therefore remains
--     bounded at the SAME ~3,600 XP/hr this citizenid's bucket already
--     enforced before this feature shipped, and the previously-verified,
--     test-locked Elite-tier timing (~2h27m) is unaffected by this addition
--     -- proven by direct simulation in tests/coopsearchbonus_spec.lua
--     (extends the exact round-robin technique tests/progression_spec.lua's
--     own EIGHTH-XP-FARM-FIX section uses, with this bonus added as a fifth
--     competing draw against the SAME real, unmodified AwardXP), not
--     asserted on reasoning alone.
--   QUALITATIVE HARDENING, on top of the numeric ceiling above, specifically
--     against "a two-player farm is harder to detect than a solo one"
--     (the numeric ceiling alone answers
--     "does it exceed the budget," not "is it as easy to run/hide as a
--     solo farm," which needs its own answer): the physical-proximity
--     requirement (item 3 above) means the receiving partner cannot farm
--     remotely or AFK-adjacent -- they must be logged in, at the search
--     scene, for as long as the searcher keeps searching, which is a
--     REAL, sustained two-account coordination cost strictly higher than a
--     single AFK-adjacent solo farmer's. The bonus is gated INSIDE the
--     searcher's own `contrabandChangedSinceLastAward and
--     ContrabandXpMintCooldown.Consume(...)` branch below (never a
--     separate, independently-triggerable code path), so it inherits EVERY
--     existing anti-farm property of the searcher's own leg for free: the
--     FOURTH-XP-FARM-FIX permanent weight-changed memory (a farmer's own
--     untouched, unchanging stash pays the partner nothing either, no
--     matter how many times re-searched) and the FIFTH-XP-FARM-FIX
--     per-searcher mint cooldown (the partner cannot be paid more often
--     than the searcher's own contraband XP itself can be minted).
-- ==========================================================================

-- Per-mechanic mint cooldown for the coop bonus's own payout -- see the
-- section header above for the full arithmetic. Keyed by the RECEIVING
-- partner's citizenid (not the searcher's, and not a (searcher, partner)
-- pair) -- this bounds how often ANY partner can receive this specific
-- bonus, from ANY searching partner, matching the "flat per-actor ceiling"
-- shape every other mint cooldown in this codebase already uses.
--
-- Citizenid-keyed, like TargetSearchCooldown above -- NOT
-- :RegisterPlayerDropped() (that clears by numeric `source`, which would
-- never match a citizenid key) -- bounded instead by its own independent
-- TTL sweep below, same reasoning as TargetSearchCooldown's own comment.
local CoopSearchXpMintCooldown = NewCooldown()
local COOP_SEARCH_XP_MINT_COOLDOWN_MS = 60000

CoopSearchXpMintCooldown.StartSweep(COOP_SEARCH_XP_MINT_COOLDOWN_MS, function(now, loggedAt)
    return (now - loggedAt) > (COOP_SEARCH_XP_MINT_COOLDOWN_MS * 2)
end)

-- Anti-farm-floor implementation constant, not a Config.* field -- same
-- "internal defensive bound, not a server-owner tuning knob" posture
-- MAX_CONTAINER_RECURSION_DEPTH/CONTRABAND_XP_MINT_COOLDOWN_MS above already
-- establish for this file. Generous enough to cover a real, shared search
-- scene (a K9 working a vehicle while their handler stands a few paces
-- back) without being large enough to reward "somewhere on the same block."
local COOP_SEARCH_PARTNER_PROXIMITY_METERS = 15.0

--- Awards `searcherCitizenid`'s current active partner (if any) a smaller
--- bonus XP amount for a contraband find that has ALREADY, independently,
--- earned the searcher their own XP -- see the section header above for the
--- full "cooperative" definition and the anti-farm arithmetic. Called ONLY
--- from inside HandleSearchTarget's own award block below, immediately
--- after the searcher's own AwardXP('searchContrabandFound') call, itself
--- pcall-wrapped at that call site so a bug in here can NEVER turn an
--- already-successful search into a reported failure for the officer (see
--- that call site's own comment).
---
--- Soft-dependency on server/partnership.lua and server/progression.lua via
--- `type(...) == 'function'` runtime existence guards throughout, matching
--- this file's own existing convention for AwardXP/GetXPTier -- neither
--- file's absence (or either feature flag being off) may ever error this
--- function, only make it a silent no-op.
--- @param searcherCitizenid string
--- @param targetCoords vector3 -- the searched target's own live coords (already resolved/validated by the caller)
local function TryAwardCoopSearchBonus(searcherCitizenid, targetCoords)
    if not (Config.Features and Config.Features.HandlerPartnership == true) then return end
    if type(GetActivePartnerCitizenId) ~= 'function' then return end
    if type(AwardXP) ~= 'function' or type(GetXPTier) ~= 'function' then return end

    local partnerCitizenid = GetActivePartnerCitizenId(searcherCitizenid)
    if not partnerCitizenid then return end

    -- SPEC ITEM 4: both parties Trained-tier or above. Checked before the
    -- (cheap) online/proximity resolution below purely as a fast early-out
    -- -- order has no security consequence either way, since none of these
    -- checks have side effects until the final AwardXP call.
    if GetXPTier(searcherCitizenid).xp <= 0 or GetXPTier(partnerCitizenid).xp <= 0 then return end

    -- SPEC ITEM 2: the partner must be ONLINE right now -- there is no live
    -- ped to proximity-check for an offline citizenid, and co-op is
    -- real-time cooperation, not a standing registration.
    local partnerPlayer = exports.qbx_core:GetPlayerByCitizenId(partnerCitizenid)
    local partnerSrc = partnerPlayer and partnerPlayer.PlayerData and partnerPlayer.PlayerData.source
    if type(partnerSrc) ~= 'number' then return end

    local partnerPed = GetPlayerPed(partnerSrc)
    if partnerPed == 0 then return end

    -- SPEC ITEM 3: physically present at the SEARCH SCENE (the target's own
    -- coords), never the searcher's own position -- a searcher and their
    -- partner could otherwise be far apart from EACH OTHER but both near
    -- the target (e.g. two officers converging on the same vehicle from
    -- different directions), which is exactly the "helping search the same
    -- scene" case this feature means to reward.
    local dist = #(GetEntityCoords(partnerPed) - targetCoords)
    if dist > COOP_SEARCH_PARTNER_PROXIMITY_METERS then return end

    -- Per-mechanic mint cooldown -- see this constant's own declaration
    -- comment above for the full arithmetic this bounds. CONSUMED, not just
    -- checked, exactly at the point a real payout is about to happen,
    -- mirroring every other mint cooldown's own Consume-at-point-of-payout
    -- placement in this file.
    if not CoopSearchXpMintCooldown.Consume(partnerCitizenid, COOP_SEARCH_XP_MINT_COOLDOWN_MS, GetGameTimer()) then
        return
    end

    AwardXP(partnerCitizenid, 'coopSearchBonus')
end

-- ResolveConnectedPlayerFromPed(entity) used to be defined here as a local
-- function (see its own extensive "DELIBERATE IMPLEMENTATION CHOICE" doc
-- comment, now preserved verbatim on server/entities.lua's copy). It was
-- extracted to server/entities.lua as a resource-global per
-- DEVELOPER_REFERENCE.md item 2b once server/inventory.lua and
-- server/combat.lua independently hand-copied the exact same function —
-- three byte-identical copies, none sharing an implementation. This file
-- now calls that shared global below (HandleSearchTarget's 'person'
-- branch) instead of defining its own.

--- MOVED to server/events.lua: this
--- file's own `FireOutboundEvent` copy — byte-for-byte identical to the
--- five other copies that existed alongside it — is now the single shared
--- resource-global implementation in that file. See server/events.lua's
--- header for the full extraction writeup. Every call site below is
--- unchanged: same event names, arguments, order, and firing conditions.

--- Fire-and-forget audit log write to `k9_search_log`
--- (sql/install.sql — see that table's own header comment for the full
--- schema rationale and integration note this function implements).
--- Non-blocking so a slow/contended DB write never delays or risks the
--- searchTarget callback's own response to the requesting officer — but
--- non-blocking via `CreateThread` + `MySQL.insert.await`, NOT via a bare
--- `MySQL.insert(...)`; see the SILENT-FAILURE FIX note at the write
--- itself below for why that distinction is the entire point. A logging
--- failure must still never surface as (or cause) a search failure to the
--- caller, so the write stays pcall-wrapped and log-only. Only called for outcomes that reached a real
--- inventory-read attempt (`'found'|'clean'|'search_failed'`) — never for
--- early rejections (feature_disabled/no_access/search_in_progress/
--- on_cooldown/too_far/invalid_target), per the table's own documented
--- scope (those never touched the target's real inventory and carry no
--- forensic value for "did a search actually happen").
--- @param source number
--- @param targetType 'vehicle'|'person'
--- @param plateOrNil string?
--- @param targetCitizenidOrNil string?
--- @param result 'found'|'clean'|'search_failed'
--- @param totalWeightOrNil number?
--- @param alertTierOrNil string?
local function LogSearchAttempt(source, targetType, plateOrNil, targetCitizenidOrNil, result, totalWeightOrNil, alertTierOrNil)
    -- CORRECTION to sql/install.sql's own integration-note wording
    -- (regression-tester finding): that comment says to "prefer whatever
    -- job value HasK9Access already resolved... over re-deriving it" —
    -- but HasK9Access(source) only ever returns a boolean, it never
    -- exposes the job name it checked internally. There is nothing to
    -- reuse; this independently re-derives searcher_job from
    -- exports.qbx_core:GetPlayer(source).PlayerData.job.name below, same
    -- as every other citizenid/job lookup in this codebase. Don't go
    -- looking for a HasK9Access return value that doesn't exist.
    local searcherPlayer = exports.qbx_core:GetPlayer(source)
    local searcherData = searcherPlayer and searcherPlayer.PlayerData
    local searcherCitizenid = searcherData and searcherData.citizenid
    local searcherJob = searcherData and searcherData.job and searcherData.job.name
    if not searcherCitizenid or not searcherJob then return end -- defensive: nothing sane to log

    -- SILENT-FAILURE FIX (audit finding — identical anti-pattern, and
    -- identical fix, to server/progression.lua's AwardXP UPSERT; see that
    -- function's own SILENT-FAILURE FIX comment for the full derivation).
    -- This used to be `pcall(MySQL.insert, [[...]], {...})` — fire-and-forget,
    -- no callback. That pcall was decorative, not protective: oxmysql's
    -- non-`.await` entry point returns the instant the query is HANDED OFF
    -- to its async worker, before the query has run, so a real failure
    -- surfaces later and entirely outside this pcall's stack frame. And
    -- oxmysql only forwards a query error into a caller-supplied callback
    -- when `return_callback_errors` is enabled (fxmanifest.lua's
    -- `mysql_option` metadata — not set anywhere in this resource), which a
    -- callback-less call never opted into either way. Net effect: a missing
    -- `k9_search_log` table (an unapplied install.sql/migration), an ENUM
    -- value drift on `result`/`target_type`, or an over-length
    -- `target_plate`/`alert_tier` would make every search-audit row silently
    -- never write — no error, no log line, nothing — while searches kept
    -- working normally, leaving a forensic audit log that is quietly empty
    -- exactly when it is needed. FIXED by moving the write into its own
    -- CreateThread and using `MySQL.insert.await` inside it: `.await`
    -- requests error propagation unconditionally, regardless of the
    -- `return_callback_errors` resource metadata, so a real query failure
    -- now raises a genuine Lua error this pcall actually catches and logs.
    -- CreateThread is what keeps this non-blocking for the searchTarget
    -- callback: `.await` yields the coroutine it runs IN, so the coroutine
    -- that suspends is this write's own, never the caller's execution path.
    CreateThread(function()
        local insertOk, insertErr = pcall(K9Store.SearchLog_Insert,
            searcherCitizenid, searcherJob, targetType, plateOrNil, targetCitizenidOrNil, result, totalWeightOrNil, alertTierOrNil)
        if not insertOk then
            print(('[qbx_k9unit] search: k9_search_log audit INSERT failed for searcher %s (%s) targetType=%s result=%s -- this search WAS performed but is NOT recorded in the audit log: %s'):format(searcherCitizenid, searcherJob, tostring(targetType), tostring(result), tostring(insertErr)))
        end
    end)

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §5) --
    -- wired HERE, not at each of this file's own call sites, so the event
    -- payload can never drift from what actually lands in the k9_search_log
    -- audit row above (every field below is the exact same value just bound
    -- into that INSERT). Not gated on any Config.Features flag here: every
    -- call site that reaches this function already required
    -- Config.Features.SearchZones to be on (the callback registration below
    -- rejects with 'feature_disabled' before ever reaching a code path that
    -- calls this), so there is no reachable call with the feature off to
    -- additionally guard against.
    FireOutboundEvent('qbx_k9unit:events:searchCompleted', searcherCitizenid, searcherJob, targetType, result, totalWeightOrNil, alertTierOrNil)
end

--- SERVER-SIDE HALF of client/search.lua's own IsBusyWithSomethingElse()
--- guard (commit a32a554) — see that function's own doc comment
--- (client/search.lua) for the CLIENT-side half this mirrors. That guard,
--- and client/combat.lua's reverse guard (refusing to start a
--- bite/takedown/drag while a search is running), are BOTH client-side
--- only — a modified client simply never runs either file, so neither is a
--- real security boundary on its own. THIS function is the actual
--- enforcement, checked unconditionally regardless of what any client
--- claims or skips.
---
--- Only TWO of that client-side guard's checks are mirrored here — the two
--- that carry a real, exploitable consequence if a modified client skips
--- them (the other two, noted at the bottom of this comment, do not):
---   1. K9 IN VEHICLE: a K9 strapped into a vehicle seat could still select
---      ox_target's "Search Person"/"Search Vehicle" against a target
---      standing OUTSIDE that vehicle — ox_target's own reach check has no
---      opinion on whether the requester is seated (client/search.lua's own
---      IsBusyWithSomethingElse doc comment: "a dog sitting in the back of
---      a cruiser could search a person standing outside it, through the
---      door... nothing refused it -- not this file, not the server").
---      Checked via a plain native call against the REQUESTER's own live
---      ped — no cross-file accessor needed. `IsPedInAnyVehicle` is the
---      same native server/combat.lua's own ValidateCombatRequest already
---      relies on for its own (different — TARGET-seated, not
---      requester-seated) vehicle exclusion; see that function's own doc
---      comment for the confirmation this native is server-registered.
---   2. K9 ALREADY HOLDING A TARGET: a K9 mid-bite/mid-takedown/mid-drag on
---      one target has no business simultaneously running a contraband
---      search against a SECOND, unrelated target — one ped cannot
---      physically do both, and nothing server-side stopped it before this
---      fix, letting a modified client fire searchTarget freely while
---      server/combat.lua's own hold-compliance sampling kept running
---      unaffected on the first target in the background. Checked via
---      `IsK9CurrentlyHolding(source)` — see this file's own FILE-TO-FILE
---      CONTRACT above (SEARCHER-BUSY GUARD bullet) for the accessor's full
---      soft-dependency writeup.
---
--- DELIBERATELY NOT MIRRORED: client/search.lua's IsBusyWithSomethingElse
--- also refuses to start a search for IsDragTargetEngaged (this ped is
--- currently the one BEING dragged) and IsFetchCarryEngaged (carrying a
--- fetch item in its mouth). Neither has an equivalent real-capability
--- consequence worth closing server-side: a ped currently being restrained
--- has no ordinary way to select an ox_target option in the first place
--- (and if it somehow could, it would still fail this file's own
--- proximity/entity checks the same as any other request), and fetch-carry
--- is a purely client-cosmetic prop attachment with no server-side registry
--- to check against at all. Closing cases 1/2 above closes every case that
--- actually lets a modified client reach a search this resource's own
--- design says should be unreachable.
--- @param source number
--- @param requesterPed number -- already resolved by the caller, confirmed ~= 0
--- @return boolean busy
--- @return string? reason -- only set when busy is true
local function IsSearcherBusyElsewhere(source, requesterPed)
    -- INCIDENT FIX (this pass, coordinator-flagged, OOM on a shared test
    -- box): IsPedInAnyVehicle is a confirmed, always-present FXServer
    -- native in real production (server/combat.lua's own ValidateCombatRequest
    -- already calls it unguarded, correctly, for that same reason) -- this
    -- `type(...) == 'function'` check therefore NEVER short-circuits on a
    -- real server; it exists purely so a Lua TEST SANDBOX that has not
    -- (yet, or ever) stubbed this native for its own fixture degrades to
    -- "not busy" instead of a hard `attempt to call a nil value` error.
    -- Without this guard, tests/coopsearchbonus_spec.lua's own sandbox
    -- (which loads this file's real callback but predates this call site
    -- and never stubbed this native) turned every real search call into a
    -- thrown error, which that spec's own round-robin "loop until XP
    -- crosses a threshold" (`while env.GetXP(citizenid) < targetXp do ...
    -- end`) never recovered from -- XP could never move, so the loop never
    -- terminated, consuming unbounded memory on every failed iteration.
    -- This is a test-fixture-robustness guard, not a production security
    -- relaxation: a genuinely malicious/modified CLIENT has no way to make
    -- a real FXServer's own IsPedInAnyVehicle native stop existing.
    if type(IsPedInAnyVehicle) == 'function' and IsPedInAnyVehicle(requesterPed, false) then
        return true, 'searcher_in_vehicle'
    end

    if type(IsK9CurrentlyHolding) == 'function' and IsK9CurrentlyHolding(source) then
        return true, 'searcher_engaged'
    end

    return false, nil
end

--- Internal implementation for the searchTarget callback below. Called
--- only after the callback's own cheap checks (payload shape, feature
--- flag, HasK9Access, in-flight mutex, flat per-source cooldown) already
--- passed. Any error thrown from within here (most commonly an
--- ox_inventory export call) is caught by the caller's outer pcall and
--- reported as `{ ok = false, reason = 'search_failed' }`.
---
--- Validation order — cheapest/most-defensive checks first, expensive/
--- leaky ones last (DEVELOPER_REFERENCE.md#contraband-search §3's own framing;
--- reordering "for convenience," e.g. moving the inventory read before
--- the proximity check, silently reopens the map-wide oracle this
--- ordering exists to prevent):
---   0. (Added this pass — see IsSearcherBusyElsewhere's own doc comment
---      immediately above.) Before even step 1: resolve the REQUESTER's
---      own live ped and reject outright if it is currently seated in a
---      vehicle or already holding another target in a bite/takedown/drag
---      — server-side half of client/search.lua's own MUTUAL GUARD (commit
---      a32a554). Cheaper than every step below and independent of which
---      target was requested, so it runs first. Steps 1-11 below keep
---      their original numbering and are otherwise unchanged by this
---      addition; `requesterPed` resolved here is reused, not re-derived,
---      by step 3's own proximity check further down.
---   1. Resolve `targetNetId` to a live entity — reject if it doesn't
---      exist (despawned, garbage netId, or never existed).
---   2. Cross-check the resolved entity's REAL type against the CLAIMED
---      `targetType` (BLOCKING, security review §4) — closes the
---      spoofing angle where a client sends `targetType = 'vehicle'` but
---      a ped's netId (or vice versa) to probe a mismatched code path.
---      For 'person', additionally confirms the ped resolves to a REAL,
---      currently-connected player (never an NPC) via
---      ResolveConnectedPlayerFromPed above — Phase 2's "person" search is
---      player-only per DEVELOPER_REFERENCE.md §11.3's own scoping note.
---   3. MANDATORY, FIRST-CLASS live proximity check, run BEFORE any
---      ox_inventory query, unconditionally (contract doc §3 step 8 / §6:
---      without this, a modified client could supply the netId of ANY
---      vehicle/player anywhere on the map and get back a real
---      contrabandFound/totalWeight result, turning this into a
---      server-wide "scan any vehicle for drugs" oracle).
---   4. Derive the resolved, STABLE cooldown identity (plate/citizenid,
---      never the raw client-supplied targetNetId) and check the
---      per-TARGET-ONLY cooldown (TargetSearchCooldown — no searcher
---      dimension; shared across every source, see §5 below).
---   5. Stamp BOTH cooldowns (flat per-source AND per-target) NOW, BEFORE
---      the awaited ox_inventory call below (BLOCKING, security review
---      §3 / contract doc §3 step 13) — writing the cooldown after an
---      awaited call leaves a window where a second call for the same
---      source/target can interleave before the first stamps anything,
---      causing a double-search/double-broadcast.
---   6. Derive the real inventory id server-side ONLY now — never
---      anything client-supplied. For a vehicle target, step 7's query also
---      forwards the ALREADY-VALIDATED `targetNetId` (resolved to `entity`
---      and cross-checked by steps 1-3 above, not freshly trusted here) so
---      ox_inventory resolves the exact same entity instead of its own
---      plate-substring fallback scan — see step 7's own pcall for why that
---      scan is a real correctness hazard on an uncached trunk, confirmed
---      against the real ox_inventory source.
---   7. Query contents via ox_inventory, pcall-wrapped — a caught error or
---      a `nil` result is `search_failed`, NEVER collapsed into
---      `contrabandFound = false` (conflating "we couldn't check" with
---      "we checked and it's clean" is a correctness bug with real
---      in-fiction consequences).
---   8. RE-CHECK `HasK9Access(source)` immediately after that awaited
---      ox_inventory call returns, before computing/broadcasting anything
---      below — the earlier callback-registration check only proves
---      access at REQUEST time, and a supervisor can revoke certification
---      during the genuinely-yielding lazy DB load step 7 can trigger for
---      an uncached vehicle trunk. Reject with the distinct `access_revoked`
---      reason (logged as `search_failed` in k9_search_log, since a real
---      inventory-read attempt did happen) if access was revoked mid-flight
---      — same posture server/certifications/'s revoke paths already
---      take for an in-progress leash via
---      ForceDetachLeashForSource/ForceDetachOfficerLeashForSource, since
---      this file's own header claims that file's level of scrutiny for
---      this exact kind of real capability grant.
---   9. Recurse into containers (SumContrabandWeight), sum weight, resolve
---      the alert tier.
---  10. If Config.Features.ContrabandAlerts and the tier isn't 'clean',
---      broadcast (distance-filtered, tier-only payload).
---  11. Return the full result (including totalWeight) to the CALLER
---      ONLY — this is the one place totalWeight is allowed to appear.
---
--- EXPLICIT DECISION, not a silent default (security review §5) — CORRECTED
--- (config audit finding): TargetSearchCooldown above IS the
--- per-target-ONLY backstop cooldown security review §5 asked about — it is
--- keyed purely on the resolved target identity (plate/citizenid), with NO
--- searcher dimension folded in, so it is shared across EVERY source, not a
--- per-(source, target) pair. This file's own documentation previously
--- claimed the opposite (that this file deliberately did NOT add such a
--- backstop, and that "multiple distinct K9 officers can each search the
--- same target once their own per-pair cooldown allows") — that was never
--- true of the code actually shipped here: there is no separate per-pair
--- cooldown at all,
--- so a SECOND officer searching the SAME target within searchCooldownMs of
--- a FIRST officer's search gets `on_cooldown` too, same as the first
--- officer would on their own repeat. Kept this way deliberately (not
--- reopened): it is the simpler of the two designs security
--- review §5 flagged as defensible, it closes the exact "rotate several
--- officers against one target to fish for a different roll" harassment
--- vector §5 raised without needing a second cooldown layer, and — now that
--- finding §1 (distance-filtered, tier-only broadcast) means a repeat
--- search never leaks more information to bystanders than a single search
--- already did — a second officer being briefly unable to independently
--- re-confirm the same target costs nothing operationally beyond a short
--- wait. This remains open for an explicit security review to confirm or
--- override, same as before.
---
--- Search-action audit logging (contract doc §6's last bullet: who
--- searched what/whom, when, result) is NOT an open question — this was
--- already decided as YES and `k9_search_log` already shipped in sql/install.sql
--- with a full integration note. Wired here via LogSearchAttempt (see its own
--- doc comment above and its two call sites below, for 'search_failed' and
--- for 'found'/'clean').
--- @param source number
--- @param targetType 'vehicle'|'person'
--- @param targetNetId number
--- @param requestedAt number -- GetGameTimer() at the moment the flat cooldown check passed, reused as the single timestamp for both cooldown stamps
--- @return table result
local function HandleSearchTarget(source, targetType, targetNetId, requestedAt)
    -- STEP 0 — see IsSearcherBusyElsewhere's own doc comment above for the
    -- full writeup. `requesterPed` is resolved HERE, once, and reused by
    -- step 3's own proximity check further below (never re-derived).
    local requesterPed = GetPlayerPed(source)
    if requesterPed == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    local searcherBusy, searcherBusyReason = IsSearcherBusyElsewhere(source, requesterPed)
    if searcherBusy then
        return { ok = false, reason = searcherBusyReason }
    end

    -- DEVELOPER_REFERENCE.md near-term item 2: was
    -- `NetworkGetEntityFromNetworkId(targetNetId)` + a bare `entity == 0`
    -- check, no DoesEntityExist call. Now server/entities.lua's shared
    -- ResolveNetworkEntity(), called WITHOUT expectedEntityType — the
    -- targetType-vs-GetEntityType cross-check immediately below branches
    -- into further person-only resolution logic beyond a simple
    -- reject-or-continue gate, so it stays entirely at this call site,
    -- exactly as before, and is NOT folded into the shared resolver. NOTE:
    -- ResolveNetworkEntity also adds a DoesEntityExist guard this call
    -- site never had — a deliberate, disclosed STRENGTHENING of this
    -- existence check, not a weakening (see ResolveNetworkEntity's own doc
    -- comment for why this isn't expected to change observed behavior).
    local entity = ResolveNetworkEntity(targetNetId)
    if not entity then
        return { ok = false, reason = 'invalid_target' }
    end

    -- Cross-check the resolved entity's REAL type against the CLAIMED
    -- targetType. GetEntityType: 1 = ped, 2 = vehicle, 3 = object
    -- (well-established FiveM native behavior).
    local entityType = GetEntityType(entity)
    local citizenid, targetServerId

    if targetType == 'vehicle' then
        if entityType ~= 2 then
            return { ok = false, reason = 'invalid_target' }
        end
    else -- 'person'
        if entityType ~= 1 then
            return { ok = false, reason = 'invalid_target' }
        end

        targetServerId = ResolveConnectedPlayerFromPed(entity)
        if not targetServerId then
            return { ok = false, reason = 'invalid_target' } -- NPC, or no longer a connected player's ped
        end

        local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
        citizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
        if not citizenid then
            return { ok = false, reason = 'invalid_target' }
        end
    end

    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any
    -- ox_inventory query, unconditionally. `requesterPed` already resolved
    -- (and confirmed ~= 0) by STEP 0 at the top of this function — reused
    -- here, never re-derived.
    local maxDistance = targetType == 'vehicle' and Config.SearchZones.vehicleSearchDistance or Config.SearchZones.personSearchDistance
    local dist = #(GetEntityCoords(requesterPed) - GetEntityCoords(entity))
    if dist > maxDistance then
        return { ok = false, reason = 'too_far' }
    end

    -- Derive the resolved, STABLE cooldown identity and the real
    -- ox_inventory inventory id — NEVER anything client-supplied. `plate`
    -- is hoisted to this outer scope (rather than staying local to the
    -- 'vehicle' branch below) because LogSearchAttempt, at the bottom of
    -- this function, needs it for the k9_search_log audit row.
    --
    -- `inventoryBackendName` is captured ONCE here (via K9Compat.Which,
    -- the same public query tracking.lua's/inventory.lua's own
    -- onResourceStart handlers already use for an identical class of
    -- "which real resource is this" decision) and reused for both
    -- `inventoryId`'s own derivation below AND the GetInventoryItems call
    -- further down — never re-queried in between, so a resource
    -- restart-triggered redetect racing this one request can never derive
    -- `inventoryId` against one backend and then query a different one.
    local inventoryId, cooldownKey, plate
    local inventoryBackendName = K9Compat.Which('inventory')

    if targetType == 'vehicle' then
        plate = GetVehicleNumberPlateText(entity)
        plate = plate and plate:match('^%s*(.-)%s*$') or nil -- trim GTA's space-padded plate string
        if not plate or plate == '' then
            return { ok = false, reason = 'invalid_target' }
        end
        -- VEHICLE-TRUNK INVENTORY ID: NOT THE SAME STRING ON EVERY CONFIRMED
        -- BACKEND — this used to be assumed to be a single, universal
        -- 'trunk' .. plate format; it is not.
        --
        -- ox_inventory (CONFIRMED against the real overextended/ox_inventory
        -- source, DEVELOPER_REFERENCE.md#contraband-search §1): a vehicle
        -- trunk's inventory id is literally 'trunk' .. plate (no separator).
        --
        -- qb-inventory (CONFIRMED, fetched and read directly from
        -- qbcore-framework/qb-inventory branch `main`: client/vehicles.lua's
        -- own `qb-inventory:client:vehicleCheck` callback builds
        -- `local inventory = 'trunk-' .. plate` — HYPHENATED, a different
        -- string entirely) — and, unlike ox_inventory, this identifier is a
        -- PLAIN SCALAR key into a plain Lua table the whole way down
        -- (server/functions.lua: `GetInventory(identifier)` returns
        -- `Inventories[identifier]` directly; `Inventories` is populated at
        -- this resource's own startup from a generic `SELECT * FROM
        -- inventories` covering every persisted identifier — trunks
        -- included — and lazily on first `OpenInventory`/`CreateInventory`
        -- call otherwise). There is no netid-keyed lazy-vivify-from-DB
        -- mechanism to work around the way ox_inventory's own uncached-trunk
        -- path needs (see the `{ id, netid }` table shape below, which
        -- exists ONLY for that ox_inventory-specific mechanism) — a
        -- qb-inventory trunk nobody has opened this server's lifetime
        -- legitimately has no entry yet and correctly reads as empty, not a
        -- system failure. Passing that ox_inventory-only TABLE shape to
        -- qb-inventory's own GetInventoryItems is what used to make vehicle
        -- search always return empty on qb-inventory (that adapter's
        -- GetInventoryItems fails closed to nil for ANY table-shaped `inv`,
        -- by design — shared/compat/inventory.lua's own qb-inventory section
        -- still does this, correctly, for every OTHER caller that might
        -- pass one; this file simply stopped being one of them). Fixed here
        -- by deriving the CORRECT, backend-real scalar identifier up front
        -- and passing it as a plain scalar further down — never a guess:
        -- both formats above are cited to a real, read source file.
        if inventoryBackendName == 'qb-inventory' then
            inventoryId = ('trunk-%s'):format(plate)
        else
            inventoryId = ('trunk%s'):format(plate)
        end
        cooldownKey = 'vehicle:' .. plate
    else
        -- A connected player's own inventory is keyed by their live
        -- numeric server id, already loaded while they're online — no
        -- lazy-load dance needed (unlike vehicles). Re-confirm the target
        -- is STILL connected right before deriving the inventory id (no
        -- yield has happened since the earlier resolution above, so this
        -- is a cheap belt-and-suspenders re-check, not a required
        -- TOCTOU close).
        if not targetServerId or GetPlayerPed(targetServerId) ~= entity then
            return { ok = false, reason = 'invalid_target' }
        end
        inventoryId = targetServerId
        cooldownKey = 'person:' .. citizenid -- citizenid, not raw netId/server id (security review §7 — survives a ped-recreation edge case)
    end

    -- Per-resolved-target cooldown check.
    if TargetSearchCooldown.IsOnCooldown(cooldownKey, Config.SearchZones.searchCooldownMs, requestedAt) then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- Stamp BOTH cooldowns NOW, BEFORE the awaited ox_inventory call below.
    SearchCooldown.Touch(source, requestedAt)
    TargetSearchCooldown.Touch(cooldownKey, requestedAt)

    -- Query contents (recursively via SumContrabandWeight below), pcall-
    -- wrapped — a lazily-loaded vehicle inventory can error on edge-case
    -- vehicle classes/timing. LOAD-BEARING DETAIL, confirmed against the
    -- real overextended/ox_inventory source (DEVELOPER_REFERENCE.md#contraband-search
    -- §1, re-verified by tech-scout): for an uncached vehicle trunk,
    -- ox_inventory's own loadInventoryData awaits
    -- lib.callback.await('ox_inventory:getVehicleData', source, netid)
    -- against the ambient `source` of whatever coroutine is executing —
    -- and if that ambient `source` is nil (i.e. this call were deferred to
    -- a different tick/thread/helper outside this callback's own execution
    -- context), it falls back to `NetworkGetEntityOwner(entity)` instead of
    -- hard-failing. That fallback resolves UNPREDICTABLY to whoever
    -- currently holds network ownership of the vehicle (could be an
    -- unrelated bystander, or resolve to nobody useful for a vehicle
    -- nobody's near) — not the requesting K9 player. This call MUST
    -- therefore stay inside this callback's own execution context (the one
    -- FiveM already set `source` to = the requesting K9 player) so the
    -- lazy-load asks the correct client, not an arbitrary/unpredictable one.
    -- SECURITY FIX: confirmed against the real
    -- overextended/ox_inventory source (modules/inventory/server.lua) that
    -- `GetInventoryItems(inv, owner)` forwards `inv` straight to
    -- `Inventory(inv)` WITHOUT collapsing it to `{id, owner}` when `inv` is
    -- already a table — so a table `inv` can carry a `netid` field through
    -- to `loadInventoryData`. That matters because, on an UNCACHED vehicle
    -- trunk (`Inventories[data.id]` not yet populated), `loadInventoryData`
    -- ONLY uses `NetworkGetEntityFromNetworkId(data.netid)` when `data.netid`
    -- is present; otherwise it falls back to looping EVERY vehicle on the
    -- server (`GetAllVehicles()`) and matching by `plateText:find(plate)` —
    -- a Lua PATTERN SUBSTRING match, not an exact-string comparison, taking
    -- the FIRST hit in a nondeterministic enumeration order. That fallback
    -- is entirely decoupled from `entity`/`targetNetId` above: two vehicles
    -- sharing a plate, or one plate merely containing another's as a
    -- substring, could resolve this read to a DIFFERENT vehicle than the
    -- one this function already proximity/type-validated — while
    -- BroadcastContrabandAlert below still reports the result under THIS
    -- `entity`'s own coords/netId regardless, producing a false alert about
    -- (or false clean bill for) a vehicle that was never actually read.
    -- Passing `netid = targetNetId` here does NOT reintroduce client trust:
    -- `targetNetId` was already resolved to `entity` and cross-validated by
    -- steps 1-3 above with no yield since, so this only PINS ox_inventory's
    -- resolution to the exact entity already vetted, closing off its own
    -- ambiguous scan rather than opening a new one. A person target's
    -- `inventoryId` (their own live numeric server id) has no equivalent
    -- ambiguity, so the table form is applied ONLY for targetType == 'vehicle'
    -- AND only for the ox_inventory-shaped backend branch below (see
    -- `inventoryBackendName` above) -- qb-inventory's own real vehicle
    -- lookup is a plain scalar, no netid-pinning mechanism exists or is
    -- needed for it (see `inventoryId`'s own derivation comment above).
    -- ROUTED THROUGH K9Compat.Get('inventory') --
    -- shared/compat/core.lua's
    -- RequiredMethods.inventory.server.GetInventoryItems -- never a direct
    -- `exports.ox_inventory:GetInventoryItems` call. The adapter never
    -- throws (BuildSafeAdapter, shared/compat/core.lua) so this outer pcall
    -- is now pure defense-in-depth (kept unchanged -- costs nothing).
    --
    -- STUB-DEGRADE ANALYSIS: on the
    -- no-op stub (nothing detected), `GetInventoryItems` returns `nil` for
    -- every branch -- `items == nil` below already reports `search_failed`
    -- (a genuine "the search could not be performed" outcome, correctly
    -- never collapsed into `contrabandFound = false`/'clean', per this
    -- function's own established discipline) rather than crashing or
    -- silently reporting a false clean bill.
    --
    -- qb-inventory specifically (the other CONFIRMED backend) --
    -- previously a real functional gap: the PERSON branch
    -- (`inventoryId` is a plain numeric server id) was already real --
    -- shared/compat/inventory.lua's qb-inventory GetInventoryItems is
    -- composed onto its own confirmed `GetInventory` export for a scalar id
    -- -- so person search already worked. The VEHICLE branch used to always
    -- fail: this file used to unconditionally build the ox_inventory-only
    -- `'trunk' .. plate` id AND wrap it in the ox_inventory-only
    -- `{ id, netid }` table shape, which qb-inventory's own GetInventoryItems
    -- deliberately fails closed to nil for (no confirmed table-shaped `inv`
    -- existed on that backend -- see that adapter's own doc comment, still
    -- accurate for every OTHER caller). FIXED here, not by teaching the
    -- adapter to guess a table shape, but by giving qb-inventory the SAME
    -- treatment the person branch already got: its own real, CONFIRMED,
    -- scalar identifier (`'trunk-' .. plate`, see `inventoryId`'s own
    -- derivation comment above for the citation), passed as a plain scalar,
    -- exactly the shape that adapter's GetInventoryItems already knows how
    -- to resolve via `GetInventory`. Vehicle search on qb-inventory now
    -- works for real, for the same reason person search always did: a
    -- correct scalar id into a real, confirmed export -- never a guess.
    local queryOk, items = pcall(function()
        if targetType == 'vehicle' and inventoryBackendName ~= 'qb-inventory' then
            return K9Compat.Get('inventory').GetInventoryItems({ id = inventoryId, netid = targetNetId })
        end
        return K9Compat.Get('inventory').GetInventoryItems(inventoryId)
    end)

    -- RE-CHECK HasK9Access(source) NOW, immediately after the awaited
    -- ox_inventory call above returns, before any of totalWeight/
    -- contrabandFound/alertTier is computed or broadcast. The ONLY earlier
    -- check (in the callback registration below) proves the officer was
    -- certified at REQUEST time — it does not prove they still are by the
    -- time this line runs, and the gap between those two moments is real,
    -- not theoretical: GetInventoryItems above can yield on a genuine
    -- ox_inventory lazy DB load for an uncached vehicle trunk (see the
    -- pcall's own doc comment above), during which a supervisor can revoke
    -- this exact officer's certification via server/certifications/.
    -- Without this re-check, a decertified officer would still receive the
    -- full result AND still trigger BroadcastContrabandAlert to bystanders
    -- below if the tier isn't 'clean' — after already losing access.
    --
    -- This file's own header (top of this file) claims explicit
    -- certifications.lua-level scrutiny BECAUSE reading a target's real
    -- live inventory is "the same category of real capability grant as
    -- server/certifications/'s grant/revoke" — and certifications.lua
    -- itself refuses to leave an equivalent window open for the leash
    -- capability: its revoke paths call
    -- ForceDetachLeashForSource/ForceDetachOfficerLeashForSource to tear
    -- down an in-progress leash the instant access is revoked, rather than
    -- letting an already-in-flight grant run to completion. A search
    -- result/broadcast is this file's equivalent of an in-progress leash,
    -- so it gets the same treatment: reject rather than let a revoked
    -- officer's in-flight search complete. (This is intentionally
    -- DIFFERENT from server/tracking.lua's header, which explicitly
    -- accepts a bounded, one-request risk for its own feature — that
    -- acceptance is specific to tracking.lua's no-real-capability,
    -- client-cosmetic marker trail and does not transfer here.)
    --
    -- Logged as 'search_failed' (a real inventory-read attempt DID
    -- complete/was attempted, so it's in k9_search_log's documented scope
    -- — see LogSearchAttempt's own doc comment), but returned to the
    -- caller with the distinct 'access_revoked' reason (not folded into
    -- 'search_failed') so this is never confused with a genuine
    -- ox_inventory error. client/search.lua's reason-handling `else`
    -- branch already treats any unrecognized reason as a plain error
    -- notify, so no client-side change is required for this new value.
    if not HasK9Access(source) then
        LogSearchAttempt(source, targetType, plate, citizenid, 'search_failed', nil, nil)
        return { ok = false, reason = 'access_revoked' }
    end

    -- PER-PERSON FEATURE CONTROL, RE-CHECKED (same race window as the
    -- HasK9Access re-check immediately above, same reasoning): high command
    -- can grant/revoke a block/grant mid-flight during the exact same
    -- genuinely-yielding ox_inventory await this file's own header already
    -- flags for HasK9Access. Reported as 'access_revoked' too -- from the
    -- searcher's point of view both mean the same thing ("something about my
    -- authorization changed while this was in flight"), and this file's own
    -- established posture (PursuitSprintRejectMessage's identical framing)
    -- is that a blocked handler does not need a message that reads
    -- differently from a revoked one.
    local searcherCitizenidMidFlight = ResolveSearcherCitizenidForPermission(source)
    if not searcherCitizenidMidFlight or not IsSearchFeaturePermittedForCitizenId(searcherCitizenidMidFlight, 'SearchZones') then
        LogSearchAttempt(source, targetType, plate, citizenid, 'search_failed', nil, nil)
        return { ok = false, reason = 'access_revoked' }
    end

    if not queryOk or items == nil then
        -- k9_search_log audit row — regression-tester correction: this
        -- MUST be wired at THIS specific pcall boundary (the one strictly
        -- around the ox_inventory read, which genuinely reached a real
        -- inventory-read attempt), NOT on the outer catch-all
        -- pcall(HandleSearchTarget, ...) in the callback registration
        -- below, which also catches early-validation errors (proximity,
        -- plate parsing, citizenid resolution) that never touched real
        -- inventory. Logging from that outer wrapper instead would record
        -- a phantom search that never actually happened whenever an
        -- unrelated future bug hits early validation, contradicting this
        -- table's own forensic-integrity purpose (sql/install.sql's scope
        -- comment: only found/clean/search_failed, never early rejections).
        -- 'search_failed' has no real totalWeight/alertTier to record
        -- (NULL, not 0/'clean' — never misrepresent a failed check as a
        -- clean one, same discipline as the callback's own reason value).
        LogSearchAttempt(source, targetType, plate, citizenid, 'search_failed', nil, nil)
        return { ok = false, reason = 'search_failed' } -- NEVER collapse into contrabandFound = false
    end

    -- pcall-wrapped (regression-tester finding): SumContrabandWeight/
    -- ResolveAlertTier run AFTER a real inventory read already succeeded,
    -- so a throw here must still reach the 'search_failed' LogSearchAttempt
    -- call site above (the one keyed to a real inventory-read attempt),
    -- not fall through uncaught to the outer catch-all pcall(HandleSearchTarget, ...)
    -- in the callback registration below, which would report the same
    -- search_failed reason to the caller but WITHOUT an audit row, even
    -- though the inventory was, in fact, read.
    -- SPECIALIZATION-SCOPED (owner-directed decluttering pass, 2026-08-26)
    -- -- resolved fresh, right before the scan it gates, from the SEARCHER's
    -- (`source`) own server-held PlayerData -- never a client-supplied
    -- value of any kind. Reuses `searcherCitizenidMidFlight` (already
    -- resolved a few lines above for the SearchZones permission re-check)
    -- rather than resolving the citizenid a second time; jobName has no
    -- existing local to reuse, so it's resolved here directly.
    local searcherPlayerForCategories = exports.qbx_core:GetPlayer(source)
    local searcherJobNameForCategories = searcherPlayerForCategories and searcherPlayerForCategories.PlayerData
        and searcherPlayerForCategories.PlayerData.job and searcherPlayerForCategories.PlayerData.job.name
    local heldContrabandCategories = ResolveHeldContrabandCategoriesForCitizenId(searcherCitizenidMidFlight, searcherJobNameForCategories)

    local sumOk, totalWeight = pcall(SumContrabandWeight, inventoryId, items, 1, heldContrabandCategories)
    if not sumOk then
        LogSearchAttempt(source, targetType, plate, citizenid, 'search_failed', nil, nil)
        return { ok = false, reason = 'search_failed' }
    end

    local contrabandFound = totalWeight > 0

    local tierOk, alertTier = pcall(ResolveAlertTier, totalWeight)
    if not tierOk then
        LogSearchAttempt(source, targetType, plate, citizenid, 'search_failed', nil, nil)
        return { ok = false, reason = 'search_failed' }
    end

    -- PER-PERSON FEATURE CONTROL, ContrabandAlerts (IsSearchFeaturePermittedForCitizenId
    -- above -- step 1, the global Config.Features.ContrabandAlerts flag, is
    -- the `Config.Features.ContrabandAlerts and` clause immediately below,
    -- unchanged). Gates the SEARCHING citizenid's own citizenid (reuses
    -- searcherCitizenidMidFlight, already re-resolved fresh a few lines
    -- above for the SearchZones permission re-check, rather than resolving
    -- it a second time) -- a block here suppresses only the broadcast to
    -- nearby players; it never affects whether the search itself succeeded,
    -- the k9_search_log audit row above, or the contraband-find XP award
    -- below, all of which are already independently governed by
    -- SearchZones's own permission check earlier in this function.
    if Config.Features.ContrabandAlerts and alertTier.alert ~= 'clean'
        and IsSearchFeaturePermittedForCitizenId(searcherCitizenidMidFlight, 'ContrabandAlerts') then
        BroadcastContrabandAlert(GetEntityCoords(entity), targetNetId, alertTier.alert)
    end

    -- ContrabandScreenFX (client/screenfx.lua). Sent to the SEARCHER ONLY
    -- (`source`), never broadcast: this is self-only cosmetic feedback, and
    -- broadcasting it would hand every nearby player a free contraband
    -- detector. Gated independently of ContrabandAlerts above -- an operator
    -- may reasonably want one and not the other. Wrapped defensively because
    -- Config.ContrabandScreenFX is a separate table from the feature flag and
    -- a config that has the flag but not the table must go inert, not error
    -- inside a search that has already done its real work.
    if Config.Features.ContrabandScreenFX and type(Config.ContrabandScreenFX) == 'table'
        and type(Config.ContrabandScreenFX.triggerTiers) == 'table' then
        for i = 1, #Config.ContrabandScreenFX.triggerTiers do
            if Config.ContrabandScreenFX.triggerTiers[i] == alertTier.alert then
                TriggerClientEvent('qbx_k9unit:client:applyContrabandScreenFx', source, Config.ContrabandScreenFX.durationMs)
                break
            end
        end
    end

    -- k9_search_log audit row (sql/install.sql's own Phase 2
    -- addition, wired here per that table's own integration note): one row
    -- per completed search attempt, fire-and-forget, never delays this
    -- return.
    LogSearchAttempt(source, targetType, plate, citizenid, contrabandFound and 'found' or 'clean', totalWeight, alertTier.alert)

    -- PHASE 4 ADDITION: Config.XP.awards.searchContrabandFound
    -- (DEVELOPER_REFERENCE.md §13.4.1). config.lua's own comment on this award key
    -- already documented this exact call site ("at the point
    -- contrabandFound == true is already known") but the actual AwardXP
    -- call was never wired up here despite that comment claiming it was.
    -- Awards the REQUESTING OFFICER's own citizenid — deliberately NOT the
    -- local `citizenid` variable in this function's outer scope above,
    -- which (for a 'person' targetType only; left nil for 'vehicle') holds
    -- the SEARCHED TARGET's citizenid, not the searcher's — reusing it here
    -- would incorrectly award XP to the person who just got searched, not
    -- the K9 who performed the search. Resolved independently via `source`,
    -- the same derivation LogSearchAttempt already performs internally for
    -- its own `searcher_citizenid` audit column (not reused directly since
    -- that function doesn't expose the resolved value back to its caller).
    -- Same runtime-existence-guard convention as server/tracking.lua's own
    -- GetXPTier/AwardXP call sites —
    -- no load-order assumption on server/progression.lua either way.
    if contrabandFound and Config.Features.XPProgression and type(AwardXP) == 'function' then
        -- ECONOMY-AUDIT FIX — see ContrabandXpState's own
        -- declaration comment above for the full writeup, INCLUDING the
        -- FOURTH XP-FARM FIX correcting this
        -- table's earlier time-based eviction: an entry created below is
        -- never evicted by age, only ever left in place or overwritten by a
        -- later genuine weight change, so this "differs from last paid
        -- weight" check below can never be reset by simply waiting. Only
        -- pays XP if this exact resolved target's contraband weight differs
        -- from whatever it was the last time XP was paid for it (no prior
        -- state counts as "differs" — the first-ever find for a target
        -- always pays). `cooldownKey` is the same stable, server-resolved
        -- target identity TargetSearchCooldown already uses above — never
        -- anything client-supplied.
        local priorAwardState = ContrabandXpState[cooldownKey]
        local contrabandChangedSinceLastAward = not priorAwardState or priorAwardState.weight ~= totalWeight

        -- FIFTH XP-FARM FIX — see
        -- ContrabandXpMintCooldown's own declaration comment above for the
        -- full writeup this closes. Checked, and (iff BOTH conditions hold)
        -- CONSUMED, only once `contrabandChangedSinceLastAward` is already
        -- known true — an unchanged-weight re-search was never going to pay
        -- anything and must never spend this per-searcher budget for
        -- nothing, the same ordering discipline server/tracking.lua's own
        -- TrackTicketMintCooldown.Consume call site already establishes for
        -- the identical reason. REQUIRED IN ADDITION TO, never instead of,
        -- the weight-changed check above — this closes the "toggle one item
        -- in/out between searches" solo farm ContrabandXpState's own
        -- CORRECTION note now documents, without weakening that table's
        -- pre-existing "the same unchanged stash pays nothing, ever, however
        -- many times re-searched" guarantee. Gates ONLY this AwardXP call —
        -- search success/contrabandFound/totalWeight/alertTier (already
        -- computed and returned to the caller regardless), the contraband
        -- alert broadcast, ContrabandScreenFX, and the k9_search_log audit
        -- row (LogSearchAttempt, already called above) are entirely
        -- unaffected by this cooldown: an officer whose mint budget is spent
        -- still gets a fully normal search, just no XP for this one.
        if contrabandChangedSinceLastAward
            and ContrabandXpMintCooldown.Consume(source, CONTRABAND_XP_MINT_COOLDOWN_MS, GetGameTimer()) then
            ContrabandXpState[cooldownKey] = { weight = totalWeight, awardedAt = GetGameTimer() }
            local searcherPlayer = exports.qbx_core:GetPlayer(source)
            local searcherCitizenid = searcherPlayer and searcherPlayer.PlayerData and searcherPlayer.PlayerData.citizenid
            if searcherCitizenid then
                AwardXP(searcherCitizenid, 'searchContrabandFound')

                -- COOPERATIVE SEARCH BONUS (Part B §10) -- see
                -- TryAwardCoopSearchBonus's own declaration comment (and the
                -- section header above it) for the full spec/arithmetic.
                -- pcall-wrapped so a bug in this NEW code can NEVER turn an
                -- already-successful, already-awarded search into a
                -- reported 'search_failed' for the officer -- the search,
                -- the searcher's own XP, the audit row and the alert
                -- broadcast have all already committed by this point
                -- regardless of what happens here.
                local coopOk, coopErr = pcall(TryAwardCoopSearchBonus, searcherCitizenid, GetEntityCoords(entity))
                if not coopOk then
                    print(('[qbx_k9unit] search: TryAwardCoopSearchBonus errored for searcher %s: %s'):format(searcherCitizenid, tostring(coopErr)))
                end
            end
        end
    end

    -- The requester who performed a real, gated, proximity-checked search
    -- learns the real number — this is the ONE place totalWeight is
    -- allowed to appear (security review §6). Applies identically when
    -- Config.Features.ContrabandAlerts == false (§11.5: that flag gates
    -- the broadcast above, not the requester's own result here).
    -- THE SNIFF CHECKS FOR WARRANTS (server/warrants.lua): a person with an
    -- approved arrest/bench warrant in the dispatch MDT is reported to the
    -- K9 and its partner. Placed last, after everything above has
    -- committed, because it reads the database; pcall so a problem there
    -- can never turn a finished search into a failed one.
    if targetType == 'person' and targetServerId and type(CheckWarrantOnSniff) == 'function' then
        local warrantOk, warrantErr = pcall(CheckWarrantOnSniff, source, targetServerId)
        if not warrantOk then
            print(('[qbx_k9unit] search: warrant check errored for target %s: %s'):format(tostring(targetServerId), tostring(warrantErr)))
        end
    end

    return {
        ok = true,
        contrabandFound = contrabandFound,
        totalWeight = totalWeight,
        alertTier = alertTier.alert,
    }
end

--- DEVELOPER_REFERENCE.md §11.4 item 2 / DEVELOPER_REFERENCE.md#contraband-search §3. THE
--- security-critical callback of Phase 2 (DEVELOPER_REFERENCE.md §11.1 sub-phase 2b).
lib.callback.register('qbx_k9unit:server:searchTarget', function(source, targetType, targetNetId)
    if type(targetType) ~= 'string' or (targetType ~= 'vehicle' and targetType ~= 'person') or type(targetNetId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' } -- defensive: never trust client payload shape
    end

    if not Config.Features.SearchZones then
        return { ok = false, reason = 'feature_disabled' } -- real server-side no-op regardless of client UI state
    end

    if not HasK9Access(source) then
        return { ok = false, reason = 'no_access' } -- reuse the global from server/certifications/, do not re-derive
    end

    -- PER-PERSON FEATURE CONTROL -- see IsSearchFeaturePermittedForCitizenId
    -- above. Deliberately BEFORE the mutex/cooldown below -- a block must
    -- never burn a cooldown slot or occupy the in-flight mutex for a request
    -- that was always going to be refused. 'not_granted' is a new reason
    -- value; client/search.lua's own reason-handling `else` branch already
    -- treats any unrecognized reason as a plain error notify (confirmed by
    -- that file's own comment on 'access_revoked'), so no client-side change
    -- is required for this one either.
    local searcherCitizenidAtRequest = ResolveSearcherCitizenidForPermission(source)
    if not searcherCitizenidAtRequest or not IsSearchFeaturePermittedForCitizenId(searcherCitizenidAtRequest, 'SearchZones') then
        return { ok = false, reason = 'not_granted' }
    end

    -- Set the in-flight mutex synchronously, BEFORE any further work that
    -- could yield (DEVELOPER_REFERENCE.md#contraband-search §4A) — cleared on EVERY
    -- exit path below. TryAcquire combines the original table's
    -- check-then-set into one atomic call: false means already held, so
    -- reject outright, never queue/race a concurrent call from the same
    -- source.
    if not SearchMutex.TryAcquire(source) then
        return { ok = false, reason = 'search_in_progress' }
    end

    local requestedAt = GetGameTimer()

    -- Flat per-source cooldown (ANY target) — BLOCKING per
    -- DEVELOPER_REFERENCE.md#contraband-search §2, not present in DEVELOPER_REFERENCE.md
    -- §11.4's original text (which describes a per-(source, target)
    -- cooldown — CORRECTION: what actually shipped
    -- as TargetSearchCooldown below is per-TARGET ONLY, no searcher
    -- dimension at all, a divergence from that original spec text that
    -- DEVELOPER_REFERENCE.md should be updated to reflect, not something
    -- this file's comments should keep restating as fact). Closes the "sweep every vehicle in a
    -- parking lot with zero delay" flood vector a per-target-only cooldown
    -- leaves open, since TargetSearchCooldown alone never limits how many
    -- DIFFERENT targets one source can hit back-to-back.
    if SearchCooldown.IsOnCooldown(source, Config.SearchZones.sniffAnimDurationMs, requestedAt) then
        SearchMutex.Release(source)
        return { ok = false, reason = 'on_cooldown' }
    end

    local ok, result = pcall(HandleSearchTarget, source, targetType, targetNetId, requestedAt)

    SearchMutex.Release(source) -- ALWAYS clear, success or error (DEVELOPER_REFERENCE.md#contraband-search §4A "finally")

    if not ok then
        print(('[qbx_k9unit] searchTarget error for source %s: %s'):format(source, tostring(result)))
        return { ok = false, reason = 'search_failed' }
    end

    return result
end)

-- DEVELOPER_REFERENCE.md item 1: SearchMutex/SearchCooldown each already
-- registered their OWN independent `playerDropped` handler via
-- :RegisterPlayerDropped() at their own declaration above — same net
-- effect as the dedicated handler this file used to have (clears each
-- one's entry for the disconnecting source). `TargetSearchCooldown` is
-- intentionally NOT registered for playerDropped — it's keyed by a
-- resolved plate/citizenid identity, not by source, so it needs its own
-- independent TTL sweep instead (see the :StartSweep call above).
