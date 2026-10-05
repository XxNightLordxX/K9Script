--[[
    john-k9/server/bodyclaims.lua

    EXCLUSIVE BODY-CLAIM REGISTRY — closes a real, demonstrated race: two
    independent "attach/override this citizenid's own ped" mechanics could
    each independently validate and grant against the SAME citizenid at the
    SAME time, because each one only ever guarded itself against the
    OTHER's own CLIENT-side committed state (checked before the network
    round trip that would have set it), and nothing on the server ever
    consulted the other mechanic's registry at all.

    CONFIRMED CONCRETE SEQUENCE (interaction audit, this pass): a K9 presses
    "Rest in Kennel" (client/kennel.lua's RequestEnterOwnKennel checks
    IsInK9Vehicle() — false, since vehicleState is only set once ITS OWN
    server round trip lands — fires requestEnterKennel, and sets no
    in-progress flag of its own). Before the reply lands, the same player
    picks "Enter Vehicle" (client/vehicle.lua's EnterNearestK9Vehicle checks
    IsRestingInKennel() — still false for the identical reason — and fires
    its own, independent requestVehicleSeatClaim). server/kennel.lua's
    requestEnterKennel and server/vehicle.lua's requestVehicleSeatClaim each
    validate and grant independently, in whatever order their two events
    happen to be processed, neither one referencing the other's registry
    (KennelOccupants vs VehicleSeatClaims) at all. Both replies land: the K9
    is now attached to a kennel object AND seated in a vehicle at once —
    something no single ATTACH/SET_PED_INTO_VEHICLE native can honestly
    represent, so one of the two physically loses, silently, with its own
    server-side bookkeeping never told.

    THE SAME STRUCTURAL GAP — "this grant handler never consults any OTHER
    exclusive mechanic's state before committing" — exists, independently,
    in server/main.lua's leash accept path and server/combat.lua's
    requestBiteHold/requestTakedown/requestDrag: none of the six grant
    handlers this file's three functions are now consulted by ever checked
    whether the SAME citizenid was already mid-grant somewhere else.

    ======================================================================
    WHERE THIS LIVES, AND WHY. server/kennel.lua (KennelOccupants),
    server/vehicle.lua (VehicleSeatClaims) and server/combat.lua
    (ActiveHolds/K9ActiveEffect) each already own a private, single-purpose
    registry for THEIR OWN mechanic — correctly; nothing here asks any of
    them to change that. The gap was never "each file's own bookkeeping is
    wrong," it was "nothing lets these three files ask one shared question
    about a citizenid without reaching directly into each other's private
    tables" — which is exactly how this became six independent, uncoupled
    guards in the first place, and reaching into each other's tables
    directly would only turn it into six MUTUALLY-coupled guards instead of
    fixing the actual gap. server/entities.lua already establishes this
    resource's answer to that shape of problem for a DIFFERENT question
    ("does some other feature already claim this netId" —
    ClaimNetworkEntity/ReleaseNetworkEntity/IsNetworkEntityClaimedByOther,
    see that file's own header): a single small shared file, loaded early,
    exposing a tiny set of resource-global verbs, with NO knowledge of any
    calling file's own internal state. This file is the identical pattern
    applied to a citizenid instead of a netId — deliberately its OWN file,
    not folded into server/entities.lua, for the same "one responsibility
    per shared file" reasoning that file's own header already gives for why
    it is not folded into server/cooldowns.lua: "is this citizenid's own
    body already claimed by an exclusive mechanic" is a genuinely different
    question from "does some other feature already claim this netId," and a
    shared file that answers both would make either responsibility harder
    to review in isolation.

    ======================================================================
    WHICH MECHANICS PARTICIPATE, AND UNDER WHAT NAME — decided by reading
    every grant handler and its own comments, not guessed:

    'kennel_rest'    — the CURRENT OCCUPANT of a deployed kennel
                        (server/kennel.lua's KennelOccupants; a real ped is
                        AttachEntityToEntity'd to the kennel object for as
                        long as this claim is held).
    'vehicle_seat'   — a citizenid with a currently-live, not yet
                        released/expired VehicleSeatClaims entry
                        (server/vehicle.lua; SET_PED_INTO_VEHICLE is about to
                        be, or was just, called on this exact citizenid's
                        ped).
    'combat_target'  — a PLAYER target currently named by an
                        server/combat.lua ActiveHolds entry (BiteAndHold,
                        NonLethalTakedown, OR PropDragging — see "why one
                        shared name for three mechanics" below). An `detail`
                        string ('bite' | 'takedown' | 'drag') rides alongside
                        the claim purely so a DENYING caller (kennel/vehicle)
                        can pick an accurate rejection message without
                        reaching into server/combat.lua's own ActiveHolds
                        table to find out — see IsBodyClaimedByOther's own
                        doc comment.

    WHY ONE SHARED NAME FOR ALL THREE COMBAT EFFECTS, not
    'bite_hold_target'/'takedown_target'/'drag_target' as three distinct
    mechanics: mutual exclusion AMONG the three combat effects on the same
    TARGET is already fully, independently enforced by server/combat.lua's
    own `ActiveHolds[targetNetId]` ('already_held' in that file's own
    ValidateCombatRequest) — a second, netId-keyed guard this file has no
    need to duplicate or second-guess. The only NEW cross-file question this
    registry needs to answer for combat targets is "is this citizenid
    ALREADY the target of ANY of the three effects" vs. "is this citizenid
    trying to claim a kennel/vehicle seat" — a single name answers that
    exactly as well as three would, with one fewer thing for a caller to get
    wrong.

    WHY NOT THE HOLDER SIDE OF BiteAndHold/NonLethalTakedown/PropDragging.
    A K9 actively holding/dragging a suspect is, separately and already,
    exactly as "busy" as this registry would otherwise need to express —
    server/combat.lua already exposes this as a real, tested, resource-
    global read-only accessor, `IsK9CurrentlyHolding(holderSrc)`
    (K9ActiveEffect-backed), plus `GetActiveHoldEffectTypeForHolder(holderSrc)`
    (this pass, alongside it) for message selection. server/kennel.lua's
    requestEnterKennel and server/vehicle.lua's requestVehicleSeatClaim both
    call THAT accessor directly (guarded, `type(...) == 'function'`, this
    resource's standard soft-dependency convention — server/combat.lua loads
    after both in fxmanifest.lua's server_scripts) rather than this file
    inventing a second, parallel way to express the identical fact. Src-keyed
    is correct there and NOT a citizenid-durability problem the way a
    persisted claim would be: it is read fresh, at the instant of the
    current request, against the CURRENT connection making that exact
    request — never stored, never compared against a stale value from
    earlier.

    THE REVERSE DIRECTION, THIS PASS: the paragraph above is about kennel/
    vehicle asking combat.lua "is the REQUESTING player busy holding
    something" — it is not, and was never, an argument that combat.lua
    should stay ignorant of THIS registry. server/combat.lua's own
    ValidateCombatRequest separately calls `IsBodyClaimed(holderSrc's own
    citizenid)` (below) before granting a NEW bite-hold/takedown/drag, so a
    citizenid already resting in a kennel or mid-vehicle-seat-claim cannot
    be granted as a HOLDER either — the two checks are symmetric halves of
    the same guarantee (kennel/vehicle refuse a busy combat holder; combat
    refuses a busy kennel/vehicle claimant), not duplicates of each other.
    `IsBodyClaimed` (not `IsBodyClaimedByOther`) is deliberately used for
    this direction — see that function's own doc comment for why a holder,
    which claims nothing of its own here, must never be checked with an
    "own mechanic" to exempt.

    ======================================================================
    DELIBERATELY EXCLUDED: THE LEASH (server/main.lua's LeashPairs). Not a
    guess — confirmed by reading client/movement.lua's own elastic
    pull-back thread, which ALREADY, explicitly, treats a leashed K9 resting
    in a kennel or loaded into a vehicle as a legitimate, anticipated
    combination: `elseif dist > pullZoneStart and not IsPedInAnyVehicle(...)
    and not (IsInK9Vehicle and IsInK9Vehicle()) and not (IsRestingInKennel
    and IsRestingInKennel()) then` — the pull-back constraint SUSPENDS
    itself specifically to avoid "fighting the AttachEntityToEntity that's
    holding the ped in place" (that thread's own comment, verbatim) while
    letting the leash PAIRING itself remain fully intact underneath. A
    leash never calls SET_PED_INTO_VEHICLE or AttachEntityToEntity on
    anyone — it is a soft, continuously-reasserted, continuously-yielding
    position nudge, never an exclusive claim on WHERE a ped's transform
    currently comes from — so there is no physical conflict for this
    registry to prevent in the first place, and adding leash to this
    registry's exclusion set would refuse a combination this resource's own
    client code already goes out of its way to support. An over-broad
    exclusion that refuses a legitimate combination is worse than the race
    it would be "fixing" — server/main.lua's own leash accept path
    (respondLeashAttach) is therefore left exactly as it already was by
    this pass; its own race (two leash requests landing on the same
    citizenid) is already independently closed by CheckLeashEligibility's
    `IsAlreadyLeashed` check plus PendingLeashRequests' own single-slot-
    per-target guard, both re-verified at accept time, neither of which
    needed anything from this file.

    ======================================================================
    EXPIRY POLICY — "every registry entry needs an owner and a way to
    expire, or a 300ms race becomes a permanent lockout":

    `ttlMs` is OPTIONAL per call, on purpose, because the six mechanics this
    file serves are not all the same SHAPE of claim:

      - 'vehicle_seat' claims are inherently short-lived (a claim only ever
        bridges the brief local delay between a request and that same
        client either genuinely sitting down or giving up — see
        server/vehicle.lua's own VEHICLE_SEAT_CLAIM_TTL_MS/header). Callers
        pass that SAME bound here, so this file's own copy of the claim can
        never outlive the mechanic's own authoritative one.
      - 'combat_target' claims mirror the underlying ActiveHolds entry's own
        hard `expiresAt` cap exactly (ttlMs = that hold's remaining
        duration at the moment this claim is taken) — DEVELOPER_REFERENCE.md
        §12.0 item 4's "no unbounded trap" guarantee already bounds the real
        mechanic this closely; this claim is never allowed to outlive it.
      - 'kennel_rest' claims are DELIBERATELY GIVEN NO TTL AT ALL
        (`ttlMs == nil`). A K9 legitimately resting in a kennel has no
        natural time limit — server/kennel.lua's own authoritative
        KennelOccupants registry has never had a TTL of its own either, for
        the identical reason, and is already an extensively reviewed,
        "CRITICAL SAFETY"-headlined piece of this codebase. Inventing a
        fixed timeout HERE that KennelOccupants itself does not have would
        not close a gap — it would OPEN one: once this file's own copy of
        the claim silently expired while the real occupant was still
        genuinely resting (KennelOccupants itself untouched, since that
        table has no TTL to drift against), a DIFFERENT mechanic
        (vehicle_seat) could be wrongly granted to a citizenid who is, in
        true authoritative state, still attached inside a kennel —
        reproducing the exact double-claim bug this whole file exists to
        prevent, just rarer. Correctness for 'kennel_rest' instead comes
        from the SAME two guarantees KennelOccupants itself already relies
        on and this pass does not change: (a) exhaustive explicit release
        at every one of kennel_rest's own existing termination paths
        (requestExitKennel's self-service exit, playerDropped's
        occupant-disconnect branch), and (b) a resource restart discarding
        this file's own `BodyClaims` table wholesale along with every other
        plain Lua local in this resource — a real, finite, operationally
        visible bound ("until the next restart"), not an indefinite one.

    A claim's own `expiresAt` (when supplied) is enforced TWO ways, mirroring
    server/vehicle.lua's own "TTL + periodic sweep" pattern exactly rather
    than inventing a third shape:
      1. Lazily, on every read (GetLiveBodyClaim, below) — bounds the damage
         PROVIDED some future call ever touches this exact citizenid again.
      2. The periodic sweep thread at the bottom of this file — does NOT
         depend on anyone ever touching this citizenid again; walks every
         live claim on a fixed interval and drops any past its own
         `expiresAt`. Started UNCONDITIONALLY (no feature-flag gate) since
         this file has no feature flag of its own to gate on and a claim
         from ANY of the six calling mechanics could exist regardless of
         which of THEIR OWN flags happen to be on — the cost, an empty-table
         `pairs()` walk on a server that never uses any of the six
         mechanics, is the same "free when unused" shape
         DoorScratchByDoorCooldown's own sweep in server/main.lua already
         establishes for an identical reason.
    A permanent (`expiresAt == nil`) claim is never touched by either path —
    see the 'kennel_rest' paragraph above for why that is the correct,
    reviewed-elsewhere-already trade-off rather than an oversight.

    CLAMP-AND-WARN, NEVER A BARE ASSERT: an invalid `ttlMs` (present but not
    a positive number — a future caller's bug, never expected from this
    file's own three current call sites) is clamped to
    BODY_CLAIM_FALLBACK_TTL_MS with one printed warning naming the bad
    value, rather than aborting the caller's own event handler outright —
    same posture server/cooldowns.lua's ResolveConfiguredThresholdMs already
    establishes for an identically-shaped "a bad number must degrade a
    guard, never crash the resource" concern.

    ======================================================================
    OWNERSHIP DISCIPLINE, why this file never reaches out on its own. This
    file does not register a `playerDropped`/`onResourceStop` handler of its
    own that tries to resolve "which citizenid was this disconnecting `src`"
    — every one of the three calling files ALREADY resolves that citizenid
    for its OWN registry's disconnect cleanup (server/kennel.lua's
    playerDropped occupant-disconnect branch, server/vehicle.lua's own
    playerDropped loop, server/combat.lua's EndHold, called from ITS OWN
    playerDropped handler) — asking THIS file to duplicate that resolution
    would either drift out of sync with the real cleanup condition each
    owning file already gets exactly right, or require this file to import
    each of their own citizenid-resolution quirks, exactly the "six files
    reach into each other's business" shape this whole design exists to
    avoid. Instead: every calling file releases ITS OWN claim at every one
    of ITS OWN already-audited termination paths — see server/kennel.lua's,
    server/vehicle.lua's, and server/combat.lua's own updated comments at
    each such call site.
    ======================================================================
]]

-- BodyClaims[citizenid] = { mechanic: string, detail: string?,
-- claimedAt: number, expiresAt: number? } -- expiresAt is nil for a
-- permanent (kennel_rest) claim, see this file's header EXPIRY POLICY
-- section. Local: reached only through the three functions below, never
-- read directly by another file -- exactly server/entities.lua's own
-- ClaimedNetworkEntities discipline, applied here to a citizenid instead of
-- a netId.
local BodyClaims = {}

-- Fallback used ONLY when a caller supplies a non-nil `ttlMs` that isn't a
-- positive number -- see this file's header CLAMP-AND-WARN paragraph. None
-- of this file's own three current call sites (server/kennel.lua,
-- server/vehicle.lua, server/combat.lua) can trigger this today; kept as a
-- defensive floor for whatever calls this file next, matching this
-- resource's "a bad number degrades a guard, it never crashes the
-- resource" standing convention (server/cooldowns.lua's
-- ResolveConfiguredThresholdMs).
local BODY_CLAIM_FALLBACK_TTL_MS = 15000

-- How often the periodic sweep below walks every live claim looking for one
-- past its own expiresAt. See this file's header EXPIRY POLICY section,
-- mechanism 2, for why this is not redundant with the lazy check
-- (GetLiveBodyClaim) alone. Deliberately coarser than
-- server/vehicle.lua's own VEHICLE_SEAT_CLAIM_SWEEP_INTERVAL_MS (5000) --
-- this table is typically far smaller (at most one entry per citizenid
-- currently mid-grant across THREE mechanics resource-wide, vs. one entry
-- per claimed seat) and a stale entry here costs nothing but table memory
-- until the next sweep or the next lazy read, whichever comes first.
local BODY_CLAIM_SWEEP_INTERVAL_MS = 15000

--- Returns the currently-live claim for `citizenid`, lazily dropping (and
--- returning nil for) one whose own `expiresAt` has already passed. A
--- permanent claim (`expiresAt == nil`) is always live -- see this file's
--- header EXPIRY POLICY section for why 'kennel_rest' claims are
--- deliberately built this way.
--- @param citizenid string
--- @return table? claim
local function GetLiveBodyClaim(citizenid)
    local claim = BodyClaims[citizenid]
    if not claim then return nil end

    if claim.expiresAt and GetGameTimer() > claim.expiresAt then
        BodyClaims[citizenid] = nil
        return nil
    end

    return claim
end

--- Attempts to claim `citizenid`'s own body for `mechanic`. Returns `false`
--- WITHOUT WRITING ANYTHING if a DIFFERENT mechanic already holds a live
--- claim on this citizenid -- the caller MUST treat `false` as "refuse this
--- grant," exactly like server/vehicle.lua's own GetLiveClaim/write pattern
--- this mirrors. Calling this again for the SAME (citizenid, mechanic) pair
--- is a RENEWAL, not a collision -- it simply refreshes `claimedAt`/
--- `expiresAt`/`detail`, the same "re-requesting the exact thing you already
--- hold" posture server/vehicle.lua's own requestVehicleSeatClaim already
--- documents for its own `existing.src == src` branch.
--- @param citizenid string
--- @param mechanic string -- 'kennel_rest' | 'vehicle_seat' | 'combat_target'
--- @param ttlMs number? -- omit for a permanent claim (see header EXPIRY POLICY -- 'kennel_rest' ONLY); any other mechanic MUST pass a real bound
--- @param detail string? -- OPTIONAL free-form context (e.g. 'bite'|'takedown'|'drag' for 'combat_target') -- read only by IsBodyClaimedByOther callers picking a rejection message, never consulted by this file's own exclusivity logic
--- @return boolean ok
function ClaimBody(citizenid, mechanic, ttlMs, detail)
    if type(citizenid) ~= 'string' or citizenid == '' or type(mechanic) ~= 'string' then
        return false -- defensive: never trust a malformed call into writing a bogus entry
    end

    local existing = GetLiveBodyClaim(citizenid)
    if existing and existing.mechanic ~= mechanic then
        return false -- genuinely claimed by someone else -- the race this file exists to close
    end

    local expiresAt = nil
    if ttlMs ~= nil then
        if type(ttlMs) ~= 'number' or ttlMs <= 0 then
            print(('[John-K9] bodyclaims: ClaimBody(%s, %s, ...) received a non-positive/invalid ttlMs (%s) -- clamping to the %dms fallback rather than granting either a permanent or a zero-length claim by accident.')
                :format(tostring(citizenid), tostring(mechanic), tostring(ttlMs), BODY_CLAIM_FALLBACK_TTL_MS))
            ttlMs = BODY_CLAIM_FALLBACK_TTL_MS
        end
        expiresAt = GetGameTimer() + ttlMs
    end

    BodyClaims[citizenid] = {
        mechanic = mechanic,
        detail = detail,
        claimedAt = GetGameTimer(),
        expiresAt = expiresAt,
    }
    return true
end

--- Releases `citizenid`'s claim, but ONLY if it is currently held by
--- EXACTLY this `mechanic` -- never blindly clears whatever is there,
--- mirroring server/entities.lua's ReleaseNetworkEntity's own "never clears
--- a claim it does not itself hold" discipline. A no-op if `citizenid` has
--- no live claim at all, or is currently claimed by a DIFFERENT mechanic
--- than the one supplied (that claim is not this caller's to clear).
--- @param citizenid string
--- @param mechanic string
function ReleaseBody(citizenid, mechanic)
    if type(citizenid) ~= 'string' or type(mechanic) ~= 'string' then return end
    local claim = BodyClaims[citizenid]
    if claim and claim.mechanic == mechanic then
        BodyClaims[citizenid] = nil
    end
end

--- Returns true if `citizenid` is CURRENTLY claimed by a DIFFERENT mechanic
--- than the one supplied. Returns false if unclaimed, expired, or already
--- claimed by this EXACT mechanic (a caller re-confirming its own prior
--- claim is never a collision with itself -- see ClaimBody's own RENEWAL
--- paragraph). The second and third return values name WHICH mechanic
--- holds the claim and its own optional `detail`, so a denying caller
--- (server/kennel.lua/server/vehicle.lua) can choose an accurate rejection
--- message without ever reaching into the CLAIMING mechanic's own private
--- registry to find out -- see this file's header "one shared name for
--- three combat effects" paragraph for why `detail` exists at all.
--- @param citizenid string
--- @param mechanic string
--- @return boolean claimedByOther
--- @return string? otherMechanic
--- @return string? detail
function IsBodyClaimedByOther(citizenid, mechanic)
    if type(citizenid) ~= 'string' then return false end
    local claim = GetLiveBodyClaim(citizenid)
    if not claim then return false end
    if claim.mechanic == mechanic then return false end
    return true, claim.mechanic, claim.detail
end

--- Returns true if `citizenid` currently holds ANY live claim at all,
--- regardless of which mechanic holds it. Unlike IsBodyClaimedByOther,
--- there is no "own mechanic" to exempt here -- this exists for a caller
--- that does not itself participate in this registry at all and only needs
--- "is this body doing something exclusive right now, no matter what."
---
--- WHY THIS IS A SEPARATE FUNCTION, NOT "IsBodyClaimedByOther(citizenid,
--- some_sentinel_mechanic)": server/combat.lua's ValidateCombatRequest uses
--- this for its own HOLDER-side check (a K9 resting in a kennel or
--- mid-vehicle-seat-claim must not be grantable as a bite-hold/takedown/
--- drag HOLDER) -- a holder never claims anything of its own in this
--- registry (see this file's header "WHY NOT THE HOLDER SIDE" paragraph),
--- so passing 'combat_target' as a fake "own mechanic" to
--- IsBodyClaimedByOther would WRONGLY exempt the one case that most needs
--- catching: a citizenid who is ALREADY the TARGET of a different combat
--- effect (a real 'combat_target' claim already held against them) trying
--- to ALSO become a holder against a third party. A dedicated function with
--- no "own mechanic" concept at all cannot make that mistake.
--- @param citizenid string
--- @return boolean claimed
--- @return string? mechanic
--- @return string? detail
function IsBodyClaimed(citizenid)
    if type(citizenid) ~= 'string' then return false end
    local claim = GetLiveBodyClaim(citizenid)
    if not claim then return false end
    return true, claim.mechanic, claim.detail
end

-- Periodic sweep -- see this file's header EXPIRY POLICY section, mechanism
-- 2, for why this is not redundant with GetLiveBodyClaim's own lazy check.
-- Started UNCONDITIONALLY at file load, same "no feature flag to gate on,
-- and gating a cleanup thread on one of the SIX calling mechanics' own
-- flags would leave the other five's claims unswept" reasoning
-- server/main.lua's own DoorScratchByDoorCooldown sweep already documents
-- for an identical shape.
CreateThread(function()
    while true do
        Wait(BODY_CLAIM_SWEEP_INTERVAL_MS)

        local now = GetGameTimer()
        for citizenid, claim in pairs(BodyClaims) do
            if claim.expiresAt and now > claim.expiresAt then
                BodyClaims[citizenid] = nil
            end
        end
    end
end)

-- ======================================================================
-- FORCED RELEASE -- "this citizenid just lost K9 access, let go of them"
--
-- WHY THIS EXISTS. server/certifications/'s EndK9AccessForCitizenId
-- tears down every session consequence of holding K9 access. Two
-- consequences were missing from that teardown: a K9 resting inside a
-- deployable kennel, and a K9 holding a vehicle seat claim. Both are
-- reachable states at the moment access is revoked, and both left the
-- decertified player still physically attached/seated with the server's
-- own registries still recording them as the occupant.
--
-- WHY IT IS A DISPATCHER AND NOT A DIRECT CLEAR. The obvious shortcut --
-- have EndK9AccessForCitizenId clear BodyClaims[citizenid] and be done --
-- is actively WORSE than the gap it closes. The body claim is only half
-- the state. server/kennel.lua's own KennelOccupants table and
-- server/vehicle.lua's own VehicleSeatClaims table are the other half, both
-- file-local by deliberate design (see each file's own "never read directly
-- by another file" note), and the affected player's CLIENT is a third half
-- again -- it is still attached to the kennel prop, or still sitting in the
-- seat, and nothing has told it otherwise. Clearing only the registry would
-- free the kennel/seat for a SECOND citizenid while the first is visibly
-- still in it: a silent double-occupancy, dressed up as a fix, of exactly
-- the kind this whole file exists to prevent.
--
-- So each owning mechanic registers its OWN releaser here, at its own file
-- load time, and keeps ownership of its own private table and its own
-- server->client event. This file only knows which mechanic holds the claim
-- and how to reach that mechanic's teardown. Nothing reaches across a file
-- boundary into someone else's state.
--
-- GATE THE STOP, NEVER THE START. Neither this function nor any releaser
-- registered with it may consult HasK9Access, any certification lookup, any
-- Config.Features flag, or any cooldown. The single caller is a teardown
-- for an ALREADY-CONFIRMED access loss; re-checking access here is exactly
-- how a decertified player would end up sealed inside their own kennel with
-- the thing that would have let them out now switched off. This is the
-- resource's oldest rule and it is load-bearing here.
-- ======================================================================

-- mechanic -> function(citizenid, reason) -> boolean released
-- File-local by the same discipline as BodyClaims itself.
local BodyClaimReleasers = {}

--- Registers `mechanic`'s own forced-release teardown, called by
--- ForceReleaseBodyClaimForCitizenId below when that mechanic is the one
--- holding a claim on a citizenid losing access.
---
--- THE CONTRACT A RELEASER MUST SATISFY, in one step with no yield between
--- its halves:
---   1. Clear the mechanic's OWN private registry entry for `citizenid`
---      (KennelOccupants[citizenid] / the matching VehicleSeatClaims row).
---   2. Resolve `citizenid`'s CURRENT live source FRESH (via
---      exports.qbx_core:GetPlayerByCitizenId) and fire the mechanic's own
---      server->client force-exit event to that source alone. Never reuse a
---      source captured earlier -- server ids are recycled, and a revoke
---      can race a reconnect.
--- Both halves, or neither. A registry clear without the client event is
--- the double-occupancy hazard described above.
---
--- A releaser MUST be a true no-op (returning false, never erroring) when
--- `citizenid` holds nothing in its registry -- the common case. If the
--- player is genuinely offline and no live source resolves, the registry
--- clear ALONE is correct and safe: there is no client rendering anything
--- to desync from. This mirrors ForceBreakPartnershipForCitizenId's own
--- established "OFFLINE-CAPABLE BY DESIGN" precedent at the same call site.
--- @param mechanic string
--- @param releaser fun(citizenid: string, reason: string?): boolean
function RegisterBodyClaimReleaser(mechanic, releaser)
    if type(mechanic) ~= 'string' or mechanic == '' or type(releaser) ~= 'function' then
        print(('[John-K9] bodyclaims: RegisterBodyClaimReleaser(%s, %s) ignored -- a releaser must be registered under a non-empty string mechanic name.')
            :format(tostring(mechanic), type(releaser)))
        return
    end
    BodyClaimReleasers[mechanic] = releaser
end

--- Releases whatever exclusive body claim `citizenid` currently holds,
--- tearing down the owning mechanic's own state and telling that player's
--- client to physically let go. Called from
--- server/certifications/'s EndK9AccessForCitizenId.
---
--- 'combat_target' IS DELIBERATELY NOT RELEASED HERE, and this is the one
--- exclusion worth reading twice. That claim is not held BY the citizenid;
--- it is held AGAINST them, by a DIFFERENT player who is currently biting,
--- taking down, or dragging them. Clearing it because the TARGET lost K9
--- access would end a third party's in-flight combat effect from the
--- registry side only, while that holder's own client carries happily on --
--- the same desync this function exists to avoid, merely pointed at someone
--- else. Those claims carry a real TTL and expire on their own (unlike
--- 'kennel_rest', which is deliberately permanent), so leaving them is
--- bounded, not a leak. Losing K9 access has never ended a bite already in
--- progress and does not start doing so here.
---
--- Returns false when there was nothing to do -- no claim, or a claim whose
--- mechanic has no registered releaser. Never errors: a releaser that
--- throws is caught, logged, and the body claim is still cleared, because
--- leaving a permanent 'kennel_rest' claim behind after a failed teardown
--- would block every other exclusive mechanic for that citizenid forever.
--- @param citizenid string
--- @param reason string? -- free-form, passed through to the releaser and on to the client for its notification
--- @return boolean released
function ForceReleaseBodyClaimForCitizenId(citizenid, reason)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end

    local claim = GetLiveBodyClaim(citizenid)
    if not claim then return false end

    local mechanic = claim.mechanic
    if mechanic == 'combat_target' then return false end

    local releaser = BodyClaimReleasers[mechanic]
    if not releaser then
        -- A mechanic claims bodies but never registered a teardown. Do NOT
        -- clear the claim: without a releaser there is no way to tell that
        -- mechanic or the client, so clearing would be precisely the
        -- registry-only half-release this file refuses to perform. Loud,
        -- because it means a new claiming mechanic shipped without one.
        print(('[John-K9] bodyclaims: ForceReleaseBodyClaimForCitizenId(%s) found a live "%s" claim with NO registered releaser -- leaving it intact rather than performing a registry-only release. Whichever file claims "%s" must call RegisterBodyClaimReleaser at its own load time.')
            :format(tostring(citizenid), tostring(mechanic), tostring(mechanic)))
        return false
    end

    local ok, err = pcall(releaser, citizenid, reason)
    if not ok then
        print(('[John-K9] bodyclaims: the "%s" releaser errored for %s: %s -- clearing the body claim anyway so this citizenid is not locked out of every other exclusive mechanic.')
            :format(tostring(mechanic), tostring(citizenid), tostring(err)))
    end

    -- Unconditional, and deliberately AFTER the releaser: a releaser is
    -- expected to release its own body claim as part of its ordinary
    -- teardown, and ReleaseBody is idempotent, so this is a backstop for the
    -- error path above, never a double-release hazard.
    ReleaseBody(citizenid, mechanic)
    return ok
end
