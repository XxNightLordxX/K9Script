--[[
    john-k9/server/vehicle.lua (NEW FILE — SEAT-RACE FIX)

    Closes a real, demonstrated concurrency bug in client/vehicle.lua: that
    file's own header used to say "this file does not register or trigger
    any network event/callback ... vehicle entry/exit is purely a
    client-local action" and flagged that as "worth re-confirming." A
    concurrency audit confirmed it was wrong — two K9 handlers selecting
    "Enter Vehicle" on the same cruiser inside the same ~400ms door-open
    window each independently compute the SAME "best free seat" (neither has
    entered yet, so IS_VEHICLE_SEAT_FREE reads free for both, on each
    client's own network-latency-delayed replica), and since nothing
    anywhere arbitrated between the two requests, both SET_PED_INTO_VEHICLE
    calls landed on the identical vehicle/seat pair. Exactly the same bug
    class this resource already fixed for leash
    (requestLeashAttach/respondLeashAttach, server/main.lua) and kennel
    (requestEnterKennel/requestPickupKennel, server/kennel.lua) — this file
    follows their exact shape rather than inventing a new one: a single-slot
    claim table, checked and written in ONE non-yielding tick inside a
    RegisterNetEvent handler, so two requests can only ever be serialized by
    ordinary event-processing order, never actually concurrent.

    WHAT THIS FILE DOES NOT DO, DELIBERATELY: it never verifies that a seat
    is ACTUALLY, PHYSICALLY free in the live game world (no
    IS_VEHICLE_SEAT_FREE/GET_VEHICLE_MAX_NUMBER_OF_PASSENGERS call anywhere
    here — both are client-only natives per fxmanifest.lua's own
    .luacheckrc verification notes, not server-callable at all). This file's
    ONLY job is arbitrating BETWEEN TWO REQUESTS GOING THROUGH THIS SAME
    EVENT for the identical (vehicleNetId, seatIndex) pair — it has no way
    to see, and does not need to see, an ordinary human player sitting down
    in that same seat via vanilla game controls, which never reaches this
    file at all. client/vehicle.lua's own local IS_VEHICLE_SEAT_FREE
    re-check (run after a grant, right before SET_PED_INTO_VEHICLE) is what
    catches that case, unchanged from before this pass — the two checks are
    complementary, not redundant: this file's claim closes the RACE between
    two entries through this file; the client's own local check closes
    everything else.

    A CLAIM IS SHORT-LIVED ON PURPOSE, NOT A PER-RIDE REGISTRATION: it only
    exists to bridge the brief local delay between a client asking and that
    same client either genuinely occupying the seat (at which point
    GET_VEHICLE_PED_IS_IN/game-engine seat occupancy becomes the
    authoritative, networked truth every other client already observes, and
    the claim is released immediately) or giving up. See
    VEHICLE_SEAT_CLAIM_TTL_MS below for the bound on how long an
    unreleased claim can possibly linger, and this file's own playerDropped/
    onResourceStop/periodic-sweep sections for why a claim can never
    outlive the player or the vehicle it names.

    ======================================================================
    EVENT/CALLBACK CONTRACT:
      'john-k9:server:requestVehicleSeatClaim' (vehicleNetId: number, seatIndex: number, requestToken: number) [THIS FILE]
        client/vehicle.lua's EnterNearestK9Vehicle(), sent after every local
        pre-flight check already passes and BEFORE any door/seat native is
        touched. requestToken is opaque here — never interpreted, only ever
        echoed back verbatim in the matching grant/deny event below, purely
        so the CLIENT can tell a stale/late response for an abandoned
        request apart from its current one. Re-verifies, independently of
        anything the client claimed: Config.Features.VehicleEntryExit (this
        request's own "opening action" gate, silent no-op like every other
        feature-flag check in this resource), HasK9Access(src), that
        vehicleNetId resolves to a real, currently-existing VEHICLE (never a
        ped/object) whose model is in Config.K9Vehicles (never the client's
        word for it — mirrors server/kennel.lua's own KennelModelHashes
        check against a client-claimed netId exactly), and live proximity
        (Config.VehicleInteractMeters + a small tolerance, same role as
        server/kennel.lua's own KENNEL_INTERACT_DISTANCE_TOLERANCE — without
        it, a modified client could claim/refresh a seat in every K9 vehicle
        on the map from across it, a real griefing primitive the same way
        server/kennel.lua's own header describes for an unchecked
        proximity-free action).
      'john-k9:client:vehicleSeatClaimGranted' (vehicleNetId, seatIndex, requestToken) [client/vehicle.lua]
      'john-k9:client:vehicleSeatClaimDenied' (vehicleNetId, seatIndex, requestToken) [client/vehicle.lua]
        This file's two possible responses. Every denial branch also calls
        NotifyPlayer directly with the reason (matches
        server/kennel.lua's own requestEnterKennel convention — the server
        owns messaging for its own rejection reasons; the client's deny
        handler only resets its own local bookkeeping, no second notify).
      'john-k9:server:releaseVehicleSeatClaim' (vehicleNetId: number, seatIndex: number) [THIS FILE]
        client/vehicle.lua, fire-and-forget, sent the instant a granted
        claim's job is done (seated, aborted locally, resource stopping) so
        it never lingers for its own TTL once genuinely unneeded. Self-only
        by construction — clears the slot ONLY if it is currently recorded
        against THIS EXACT `source`, mirroring server/entities.lua's
        ReleaseNetworkEntity's own "never blindly clears whatever is there"
        discipline, so one client can never release a claim it does not
        itself hold.
    ======================================================================

    NEVER GATE A TERMINATION PATH: releaseVehicleSeatClaim above, the
    playerDropped handler, the onResourceStop handler, and the periodic
    sweep thread below are ALL unconditional — none of them re-checks
    Config.Features.VehicleEntryExit, HasK9Access, or anything else that
    could suppress a cleanup. A claim is a purely internal bookkeeping
    entry with no player-visible state of its own (unlike a kennel or a
    leash pairing, releasing one early has no observable effect on anyone —
    it just stops blocking a seat nobody is actually sitting in), so there
    is no "was this authorized" question to ask on the way out at all.

    A CLAIM MUST NEVER OUTLIVE THE PLAYER OR THE VEHICLE (the part of this
    file to be most careful about — a leaked claim is a permanently
    unusable seat for the rest of the server's uptime, a worse bug than the
    one this file exists to fix). FOUR independent, overlapping mechanisms,
    not just one:
      1. TTL, checked LAZILY at the moment a NEW request for the exact same
         (vehicleNetId, seatIndex) arrives (GetLiveClaim below) — an expired
         claim is treated as absent and silently overwritten. Bounds the
         damage to VEHICLE_SEAT_CLAIM_TTL_MS PROVIDED some future request
         ever touches that exact seat again.
      2. playerDropped — a disconnecting src's claims are dropped
         immediately, not left to the TTL.
      3. onResourceStop (this resource restarting) — the entire
         VehicleSeatClaims table is discarded; every claim was in-memory
         Lua state with no persistence across that boundary regardless.
      4. The periodic sweep thread below — unlike mechanism 1, this one
         does NOT depend on anyone ever touching that exact seat again: it
         actively walks every claim on a fixed interval and drops any that
         are either TTL-expired OR name a vehicleNetId that no longer
         resolves to a real, existing vehicle at all (deleted/despawned
         while a claim was held) — closing the one gap mechanism 1 alone
         would leave open (a vehicle destroyed mid-claim that nobody ever
         asks about again).

    ======================================================================
    EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) —
    closes a SECOND, independently confirmed race this file's own claim
    table never protected against: server/kennel.lua's requestEnterKennel
    granting kennel-rest occupancy to the SAME citizenid concurrently with
    (or, just as broken, at any point AFTER) this file granting a seat
    claim — neither file previously knew the other's registry existed.
    requestVehicleSeatClaim above now calls
    `IsBodyClaimedByOther(citizenid, 'vehicle_seat')` before ever resolving
    the target vehicle, and `ClaimBody(citizenid, 'vehicle_seat',
    VEHICLE_SEAT_CLAIM_TTL_MS)` at the exact same non-yielding write this
    file's own VehicleSeatClaims entry is created — reusing THIS file's own
    TTL constant so the shared claim can never outlive the authoritative
    one it mirrors. Every one of the four release mechanisms enumerated
    above (GetLiveClaim's lazy TTL expiry, ClearVehicleSeatClaim,
    playerDropped, the periodic sweep) now ALSO calls
    `ReleaseBody(claim.citizenid, 'vehicle_seat')` at the same point it
    clears its own VehicleSeatClaims entry — see server/bodyclaims.lua's own
    header for the full registry design, including why the leash is
    deliberately NOT a participant and why a combat-mechanic HOLDER's own
    busy-state (server/combat.lua's `IsK9CurrentlyHolding`/
    `GetActiveHoldEffectTypeForHolder`, both called directly by
    requestVehicleSeatClaim above) is answered by an existing accessor
    rather than a fourth participant in that registry.
]]

-- Server-side mirror of client/vehicle.lua's own K9VehicleHashes — built
-- once at file load from the SAME Config.K9Vehicles list, never trusting a
-- client-claimed netId's model without an independent, server-owned check.
-- Mirrors server/kennel.lua's KennelModelHashes precedent exactly.
local K9VehicleHashes = {}
for _, model in ipairs(Config.K9Vehicles) do
    K9VehicleHashes[GetHashKey(model)] = true
end

-- The only seat indices client/vehicle.lua's own SEAT_TO_DOOR_INDEX/
-- SEAT_PREFERENCE_ORDER ever produce (0/1/2/3/4/5/6, plus -1 for
-- completeness/symmetry even though the client never requests the driver's
-- seat). Bounding this set closes a real memory-growth vector: without it,
-- nothing would stop a modified client claiming an unbounded number of
-- distinct, never-repeating seatIndex values against the same real vehicle
-- netId, each one a brand-new table key VehicleSeatClaims[netId] would
-- otherwise accept forever.
local VALID_SEAT_INDICES = { [-1] = true, [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }

-- How long a granted-but-never-released claim can possibly linger before
-- this file's own lazy-expiry check (GetLiveClaim) and periodic sweep both
-- treat it as gone. Generous relative to the local sequence it exists to
-- bridge (door-open delay 400ms + a brief seat/door-shut tail, client/
-- vehicle.lua's own VEHICLE_DOOR_OPEN_DELAY_MS/VEHICLE_DOOR_SHUT_DELAY_MS)
-- while still being a HARD bound, not an indefinite one — same order of
-- magnitude as server/kennel.lua's own PendingKennelPlacements TTL
-- (Config.DeployableKennel.pendingPlacementTtlMs, default 15000).
local VEHICLE_SEAT_CLAIM_TTL_MS = 10000

-- How often the periodic sweep below walks every live claim looking for one
-- naming a vehicle that no longer exists. See this file's header "A CLAIM
-- MUST NEVER OUTLIVE..." section, mechanism 4, for why this is not
-- redundant with the TTL alone.
local VEHICLE_SEAT_CLAIM_SWEEP_INTERVAL_MS = 5000

-- Meters of slack over Config.VehicleInteractMeters allowed for this file's
-- own proximity check — same role, same value, and the same "security-
-- relevant tolerance stays in code, not Config" reasoning as
-- server/kennel.lua's own KENNEL_INTERACT_DISTANCE_TOLERANCE.
local VEHICLE_INTERACT_DISTANCE_TOLERANCE = 1.0

-- VehicleSeatClaims[vehicleNetId][seatIndex] = { src: number, citizenid: string, claimedAt: number }
-- Local: reached only through the two RegisterNetEvent handlers and the
-- cleanup paths below, never read directly by another file.
local VehicleSeatClaims = {}

--- Returns the currently-live claim on (netId, seatIndex), lazily dropping
--- and returning nil for one that has outlived VEHICLE_SEAT_CLAIM_TTL_MS —
--- see this file's header "A CLAIM MUST NEVER OUTLIVE..." section,
--- mechanism 1.
--- @param netId number
--- @param seatIndex number
--- @return table? claim
local function GetLiveClaim(netId, seatIndex)
    local perVehicle = VehicleSeatClaims[netId]
    if not perVehicle then return nil end

    local claim = perVehicle[seatIndex]
    if not claim then return nil end

    if GetGameTimer() - claim.claimedAt > VEHICLE_SEAT_CLAIM_TTL_MS then
        perVehicle[seatIndex] = nil
        if not next(perVehicle) then VehicleSeatClaims[netId] = nil end
        -- EXCLUSIVE BODY-CLAIM REGISTRY release -- mirrors the ClaimBody
        -- call in requestVehicleSeatClaim above. ReleaseBody is a no-op if
        -- this citizenid's own 'vehicle_seat' claim already separately
        -- expired via server/bodyclaims.lua's own TTL/sweep, so this is
        -- never a double-release hazard, only ever a cleanup that might
        -- occasionally arrive slightly ahead of that file's own.
        ReleaseBody(claim.citizenid, 'vehicle_seat')
        return nil
    end

    return claim
end

--- Is `citizenid` already holding a live seat claim on some OTHER seat?
--- Returns the offending claim's own coordinates so the caller can be
--- specific, or nil if this citizenid holds nothing anywhere else.
---
--- WHY THIS EXISTS (cross-change QA finding, this pass). This file's own
--- exclusivity has always been addressed by (vehicleNetId, seatIndex) --
--- correct for its original purpose, which was stopping two PEOPLE racing
--- for one seat. server/bodyclaims.lua then arrived addressing exclusivity
--- by CITIZENID, and the two schemes do not line up: a citizenid holding
--- seat 1 of vehicle A and then claiming seat 1 of vehicle B passes the
--- per-seat check (different seat, nobody else there), and ClaimBody reads
--- the second call as a RENEWAL of the same mechanic rather than a
--- collision, silently overwriting the first claim in that citizenid's
--- single registry slot. When vehicle A's claim is then released -- by the
--- client, by TTL, or by the sweep -- ReleaseBody(citizenid,
--- 'vehicle_seat') has no seat identity to check against and clears the
--- slot outright, even though vehicle B's seat is still genuinely held.
--- The registry then reports that citizenid as unclaimed while a real seat
--- claim is live, and a concurrent kennel-rest or bite-hold request is
--- granted -- reproducing the exact "two mechanics claim one body" race
--- the registry was written to close, just by a different route.
---
--- Neither file's own tests could see this: bodyclaims_spec only renews
--- the same logical claim, and vehicle_spec only ever collides two
--- requests on the identical (vehicle, seat) pair. The bug lives in the
--- seam between the two addressing schemes, which is exactly where a
--- per-file review cannot look.
---
--- Fixed HERE rather than in server/bodyclaims.lua, deliberately: making
--- the registry hold multiple claims per mechanic would weaken the
--- one-body-one-claim invariant every other participant depends on, to
--- accommodate a state this file should never have allowed in the first
--- place. server/kennel.lua already refuses a second kennel for one
--- citizenid the same way (its own single-slot KennelOccupants guard) --
--- this brings the seat table in line with that.
--- @param citizenid string
--- @param exceptNetId number -- the seat being requested right now, which must not count against itself
--- @param exceptSeatIndex number
--- @return { netId: number, seatIndex: number }|nil
local function FindOtherLiveSeatClaimFor(citizenid, exceptNetId, exceptSeatIndex)
    for netId, perVehicle in pairs(VehicleSeatClaims) do
        for seatIndex in pairs(perVehicle) do
            if not (netId == exceptNetId and seatIndex == exceptSeatIndex) then
                -- Routed through GetLiveClaim, never a raw table read, so an
                -- already-expired entry is swept and released here rather
                -- than counted as a live blocker -- a stale claim must never
                -- lock someone out of every seat on the server.
                local claim = GetLiveClaim(netId, seatIndex)
                if claim and claim.citizenid == citizenid then
                    return { netId = netId, seatIndex = seatIndex }
                end
            end
        end
    end
    return nil
end

-- ======================================================================
-- FORCED EXIT ON ACCESS LOSS -- this file's half of
-- server/bodyclaims.lua's ForceReleaseBodyClaimForCitizenId dispatcher.
--
-- Registered at file load so that when server/certifications/'s
-- EndK9AccessForCitizenId revokes someone's K9 access while they are
-- holding a seat claim, this file -- the only one that owns
-- VehicleSeatClaims -- performs its own teardown. See
-- RegisterBodyClaimReleaser's own doc comment for the contract.
--
-- GATE THE STOP, NEVER THE START. Consults nothing: not
-- Config.Features.VehicleEntryExit, not HasK9Access, not the per-person
-- feature control below, not any cooldown. Getting OUT of a vehicle and
-- giving up a claim are never gated on anything -- this file's own oldest
-- rule, and load-bearing here specifically, since the caller has ALREADY
-- revoked this citizenid's access and any access check would be guaranteed
-- false at this exact moment.
--
-- Sweeps EVERY seat rather than assuming one: FindOtherLiveSeatClaimFor's
-- own header documents how a citizenid could historically end up recorded
-- against two seats at once through the addressing-scheme seam. That is
-- fixed on the grant path now, but a teardown that stops after the first
-- match would silently leave the second behind if it ever recurred -- and a
-- teardown is the wrong place to assume an invariant holds.
if type(RegisterBodyClaimReleaser) == 'function' then
    RegisterBodyClaimReleaser('vehicle_seat', function(citizenid, reason)
        local held = {}
        for netId, perVehicle in pairs(VehicleSeatClaims) do
            for seatIndex, claim in pairs(perVehicle) do
                if claim.citizenid == citizenid then
                    held[#held + 1] = { netId = netId, seatIndex = seatIndex }
                end
            end
        end
        -- Raw table reads above, not GetLiveClaim: an EXPIRED entry for this
        -- citizenid still needs clearing, and routing through GetLiveClaim
        -- would both mutate the table mid-iteration and skip exactly the
        -- stale rows a teardown most wants gone.

        if #held == 0 then return false end

        for _, seat in ipairs(held) do
            local perVehicle = VehicleSeatClaims[seat.netId]
            if perVehicle then
                perVehicle[seat.seatIndex] = nil
                if not next(perVehicle) then VehicleSeatClaims[seat.netId] = nil end
            end
        end
        ReleaseBody(citizenid, 'vehicle_seat')

        -- Live source resolved FRESH, never a recorded claim.src: server ids
        -- are recycled, and a revoke can race a reconnect, so a stale source
        -- could belong to an unrelated player who would then be thrown out of
        -- their own vehicle.
        local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local liveSrc = player and player.PlayerData and player.PlayerData.source
        if liveSrc then
            TriggerClientEvent('john-k9:client:forceExitVehicleSeat', liveSrc, reason)
        end

        -- Offline is a success, not a failure -- see the kennel releaser's
        -- own identical note.
        return true
    end)
end
-- ======================================================================

--- Clears (netId, seatIndex)'s claim, but ONLY if it is currently recorded
--- against the EXACT `src` supplied — mirrors server/entities.lua's
--- ReleaseNetworkEntity's own "never blindly clears whatever is there"
--- discipline, so one client can never release a claim it does not itself
--- hold. A no-op if nothing is claimed, or claimed by someone else.
--- @param netId number
--- @param seatIndex number
--- @param src number
local function ClearVehicleSeatClaim(netId, seatIndex, src)
    local perVehicle = VehicleSeatClaims[netId]
    if not perVehicle then return end

    local claim = perVehicle[seatIndex]
    if claim and claim.src == src then
        perVehicle[seatIndex] = nil
        if not next(perVehicle) then VehicleSeatClaims[netId] = nil end
        -- EXCLUSIVE BODY-CLAIM REGISTRY release -- see GetLiveClaim's own
        -- identical release above for why this can never double-release
        -- unsafely.
        ReleaseBody(claim.citizenid, 'vehicle_seat')
    end
end

--- Per-person feature control for vehicle entry, in the exact four-step
--- shape every other server-enforced feature in this resource uses (see
--- server/kennel.lua's IsDeployableKennelPermittedForCitizenId, which this
--- mirrors step for step):
---   1. NOT consulted on any exit/release path -- getting OUT of a vehicle,
---      and giving up a claim, are never gated on anything. That is this
---      file's and this resource's oldest rule.
---   2. an explicit block.VehicleEntryExit grant -> DENY
---   3. VehicleEntryExit listed in Config.FeatureControl.RequireGrant ->
---      ALLOW only with an active feature.VehicleEntryExit grant
---   4. otherwise -> ALLOW
---
--- WHY THIS EXISTS NOW AND DID NOT BEFORE. Until vehicle entry gained a
--- server half it was tier='clientonly', and its only per-person block path
--- was client/featureblocks.lua -- which a modified client simply does not
--- run. The moment the server started arbitrating seat claims, the
--- resource's own drift guard (tests/customizationregistry_spec.lua) was
--- right to demand this: a feature the server enforces must be blockable
--- per person on the server too, or "High Command blocked you from vehicle
--- entry" is a suggestion rather than a rule.
---
--- @param citizenid string
--- @return boolean allowed
local function IsVehicleEntryPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- server/
    -- kennel.lua and server/pursuitsprint.lua carry the identical comment
    -- on their own copies of this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.VehicleEntryExit') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.VehicleEntryExit == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.VehicleEntryExit') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Step 1 (and only step): a K9 handler's client asks to claim a specific
--- seat in a specific vehicle. THE FIX — see this file's own header for the
--- full design. The CHECK (GetLiveClaim) and the WRITE
--- (VehicleSeatClaims[...][...] = {...}) below happen with NO yield of any
--- kind between them — no Wait, no awaited callback, nothing — so two
--- requests for the identical (vehicleNetId, seatIndex) pair can only ever
--- be serialized by ordinary FiveM event-processing order, exactly like
--- server/kennel.lua's requestEnterKennel/requestPickupKennel. If this ever
--- grows a yield between the two, the original bug is rebuilt on the
--- server.
--- @param vehicleNetId number
--- @param seatIndex number
--- @param requestToken number
RegisterNetEvent('john-k9:server:requestVehicleSeatClaim', function(vehicleNetId, seatIndex, requestToken)
    local src = source

    -- Defensive type checks first, never trust client payload shape —
    -- silent no-op on a malformed call, matching server/kennel.lua's own
    -- `if type(netId) ~= 'number' then return end` convention exactly (no
    -- notify, no deny event: a genuinely malformed call is not a normal
    -- rejection this client's own UI is waiting to hear about).
    if type(vehicleNetId) ~= 'number' or type(seatIndex) ~= 'number' or type(requestToken) ~= 'number' then return end
    if not VALID_SEAT_INDICES[seatIndex] then return end

    if not Config.Features.VehicleEntryExit then return end -- "opening" action -- silent no-op, matches requestDeployKennel's own gate

    local player = exports.qbx_core:GetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid
    if not citizenid then return end

    --- @param message string
    local function deny(message)
        NotifyPlayer(src, message, 'error')
        TriggerClientEvent('john-k9:client:vehicleSeatClaimDenied', src, vehicleNetId, seatIndex, requestToken)
    end

    -- PER-PERSON/ROLE ACCESS — the exact gap this pass's own audit flagged
    -- client/vehicle.lua's header as never having closed: this is the
    -- FIRST time vehicle entry has ever been re-verified server-side.
    if not HasK9Access(src) then
        deny(locale('common.no_k9_access'))
        return
    end

    -- PER-PERSON FEATURE CONTROL -- see IsVehicleEntryPermittedForCitizenId
    -- above. Deliberately AFTER HasK9Access (an uncertified caller is not
    -- owed a "you are blocked" message about a feature they could not use
    -- anyway) and BEFORE anything that resolves or touches the vehicle.
    if not IsVehicleEntryPermittedForCitizenId(citizenid) then
        deny(locale('vehicle.entry_not_permitted'))
        return
    end

    -- A K9 actively holding/dragging a suspect (BiteAndHold/NonLethalTakedown/
    -- PropDragging, server/combat.lua) cannot ALSO load into a vehicle at
    -- the same instant. Already this resource's INTENDED behavior --
    -- client/vehicle.lua's own EnterNearestK9Vehicle already carries this
    -- exact check (IsDragEngaged()/IsBiteHoldEngaged(), same locale keys
    -- reused below) -- but only CLIENT-side, and therefore just as racy
    -- against a concurrent grant as the kennel-vs-vehicle pair this pass's
    -- own audit traced concretely. Made server-authoritative here via the
    -- SAME already-tested, K9ActiveEffect-backed accessor server/kennel.lua's
    -- own requestEnterKennel now also calls -- see server/bodyclaims.lua's
    -- own header "WHY NOT THE HOLDER SIDE" paragraph for why this is a
    -- direct accessor call, not a ClaimBody/IsBodyClaimedByOther
    -- participant. Soft dependency, this resource's established convention
    -- -- server/combat.lua loads after this file in fxmanifest.lua's
    -- server_scripts.
    if type(IsK9CurrentlyHolding) == 'function' and IsK9CurrentlyHolding(src) then
        local effectType = type(GetActiveHoldEffectTypeForHolder) == 'function' and GetActiveHoldEffectTypeForHolder(src)
        deny(effectType == 'drag' and locale('vehicle.blocked_by_drag') or locale('vehicle.blocked_by_bite_hold'))
        return
    end

    -- EXCLUSIVE BODY-CLAIM REGISTRY (server/bodyclaims.lua, this pass) --
    -- closes the CONFIRMED kennel-vs-vehicle-seat race that file's own
    -- header documents in full (a K9 resting in a kennel -- attached to it
    -- server-confirmed, not merely client-claimed -- could still race this
    -- handler and claim a seat too, since neither file previously consulted
    -- the other's registry). ALSO closes this same claim's combat-target
    -- analogue for a PLAYER already the TARGET of a bite-hold/takedown/drag
    -- -- client/vehicle.lua's own IsDragTargetEngaged() guard already
    -- covers the drag-target case CLIENT-side (racy, same class of gap);
    -- this closes it server-side and extends the SAME protection to
    -- bite-hold/takedown targets, which the client never guarded against at
    -- all. `citizenid`, never `src`, is the identity checked -- server ids
    -- are recycled, this registry is keyed durably.
    do
        local claimedByOther, otherMechanic, detail = IsBodyClaimedByOther(citizenid, 'vehicle_seat')
        if claimedByOther then
            if otherMechanic == 'kennel_rest' then
                -- Reuses the SAME locale key client/vehicle.lua's own
                -- pre-existing (racy) kennel-rest guard already reuses for
                -- this exact scenario (see that file's IsRestingInKennel()
                -- check, further down its EnterNearestK9Vehicle) -- not a
                -- new string, an already-established cross-mechanic reuse
                -- this pass makes server-authoritative.
                deny(locale('kennel.enter_already_resting'))
            elseif detail == 'drag' then
                deny(locale('vehicle.blocked_by_being_dragged'))
            else
                -- bite/takedown target, or an unrecognized detail -- no
                -- existing vehicle.* string names this specific scenario;
                -- locales/en.json is outside this pass's file ownership, so
                -- this reuses the generic, already-shipped, honest fallback
                -- rather than inventing a misleading one.
                deny(locale('combat.reject_fallback'))
            end
            return
        end
    end

    -- Never trust the client's word for what vehicleNetId names — resolve
    -- it and verify it is a real, currently-existing VEHICLE (type 2, never
    -- a ped or object) whose model is actually a configured K9 vehicle.
    -- Mirrors server/kennel.lua's confirmKennelPlaced/requestEnterKennel
    -- verifying a claimed netId against KennelModelHashes rather than the
    -- client's own claim.
    local entity = ResolveNetworkEntity(vehicleNetId, 2) -- 2 = vehicle, per server/entities.lua's own GetEntityType convention
    if not entity or not K9VehicleHashes[GetEntityModel(entity)] then
        deny(locale('vehicle.entry_interrupted'))
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    local dist = #(GetEntityCoords(ped) - GetEntityCoords(entity))
    if dist > (Config.VehicleInteractMeters + VEHICLE_INTERACT_DISTANCE_TOLERANCE) then
        deny(locale('vehicle.claim_too_far'))
        return
    end

    -- THE CHECK-AND-CLAIM. `existing.src == src` (this same client
    -- re-requesting the exact seat it already holds — e.g. its own prior
    -- attempt aborted locally after being granted, and this is a fresh
    -- retry before the old claim's release message arrived) is treated as a
    -- renewal, not a collision: the write below simply refreshes
    -- claimedAt. Any OTHER src holding a still-live claim is the actual
    -- race this file exists to close.
    local existing = GetLiveClaim(vehicleNetId, seatIndex)
    if existing and existing.src ~= src then
        deny(locale('vehicle.no_seat_available'))
        return
    end

    -- ONE SEAT PER CITIZENID, ACROSS EVERY VEHICLE -- see
    -- FindOtherLiveSeatClaimFor's own doc comment above for the full
    -- writeup of the cross-file race this closes. Checked AFTER the
    -- per-seat check so the more specific refusal still wins when both
    -- apply, and deliberately BEFORE the claim is written, so no partial
    -- state exists to unwind. START GATE ONLY: nothing below is reachable
    -- from releaseVehicleSeatClaim, the TTL path, the disconnect handler or
    -- the sweep -- a player already holding a seat can always let go of it,
    -- and in fact must, since that is how they get a different one.
    if FindOtherLiveSeatClaimFor(citizenid, vehicleNetId, seatIndex) then
        deny(locale('vehicle.no_seat_available'))
        return
    end

    VehicleSeatClaims[vehicleNetId] = VehicleSeatClaims[vehicleNetId] or {}
    VehicleSeatClaims[vehicleNetId][seatIndex] = { src = src, citizenid = citizenid, claimedAt = GetGameTimer() }
    -- EXCLUSIVE BODY-CLAIM REGISTRY -- see server/bodyclaims.lua's own
    -- header EXPIRY POLICY section: 'vehicle_seat' reuses this file's own
    -- VEHICLE_SEAT_CLAIM_TTL_MS bound so this claim can never outlive the
    -- authoritative VehicleSeatClaims entry it mirrors. A `src == src`
    -- renewal (this same client re-requesting the exact seat it already
    -- holds) simply refreshes this claim's own expiry too -- ClaimBody's
    -- own RENEWAL semantics handle that for free, no special-case needed.
    ClaimBody(citizenid, 'vehicle_seat', VEHICLE_SEAT_CLAIM_TTL_MS)

    TriggerClientEvent('john-k9:client:vehicleSeatClaimGranted', src, vehicleNetId, seatIndex, requestToken)
end)

--- Self-only release — see this file's header EVENT/CALLBACK CONTRACT.
--- NEVER gated on Config.Features.VehicleEntryExit, HasK9Access, or
--- anything else: this is a termination/cleanup path, and gating one is
--- exactly how the unbounded trap this file's header warns about gets
--- built.
--- @param vehicleNetId number
--- @param seatIndex number
RegisterNetEvent('john-k9:server:releaseVehicleSeatClaim', function(vehicleNetId, seatIndex)
    local src = source
    if type(vehicleNetId) ~= 'number' or type(seatIndex) ~= 'number' then return end
    ClearVehicleSeatClaim(vehicleNetId, seatIndex, src)
end)

-- Disconnect cleanup — see this file's header "A CLAIM MUST NEVER
-- OUTLIVE..." section, mechanism 2. A K9 handler who crashes/disconnects
-- mid-claim (never sending releaseVehicleSeatClaim themselves) must not
-- leave that seat permanently reserved for a src that no longer exists.
-- Setting an existing field to nil while traversing with `pairs` is
-- explicitly well-defined by the Lua reference manual (only ASSIGNING a
-- previously-nonexistent field during traversal is undefined) -- safe here.
AddEventHandler('playerDropped', function(_reason)
    local src = source

    for netId, seats in pairs(VehicleSeatClaims) do
        for seatIndex, claim in pairs(seats) do
            if claim.src == src then
                seats[seatIndex] = nil
                -- EXCLUSIVE BODY-CLAIM REGISTRY release -- see
                -- GetLiveClaim's own identical release above for why this
                -- can never double-release unsafely.
                ReleaseBody(claim.citizenid, 'vehicle_seat')
            end
        end
        if not next(seats) then
            VehicleSeatClaims[netId] = nil
        end
    end
end)

-- Resource-stop cleanup — see this file's header "A CLAIM MUST NEVER
-- OUTLIVE..." section, mechanism 3. VehicleSeatClaims is a plain in-memory
-- Lua local with no persistence across a restart regardless; this just
-- makes that explicit and immediate rather than leaving every entry to be
-- silently discarded along with the rest of this chunk's state a moment
-- later.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    VehicleSeatClaims = {}
end)

-- Periodic sweep — see this file's header "A CLAIM MUST NEVER OUTLIVE..."
-- section, mechanism 4.
--
-- STARTED UNCONDITIONALLY, flag checked INSIDE the loop. This was gated on
-- Config.Features.VehicleEntryExit at file load, on the reasoning that the
-- flag is never toggled live. That reasoning was wrong, and wrong in the
-- one direction that matters:
--
--   * The claim handler above re-reads the flag on every request, so the
--     moment an operator turns this feature ON from the tablet, claims
--     start being granted.
--   * A thread gated at FILE LOAD saw the flag as it was at BOOT. On a
--     server that booted with the feature off, turning it on mid-session
--     therefore meant claims being created with nothing whatsoever running
--     to expire them -- and a stranded claim is a seat nobody can sit in
--     for the rest of the server's uptime. That is a worse bug than the
--     two-dogs-one-seat race this whole file exists to fix.
--
-- server/combat.lua and server/wellbeing.lua were each fixed for this exact
-- live-flip trap already, in the same direction, with the same trade-off
-- written down: the cost is one thread paying a single Wait() every sweep
-- interval on a server that never uses this feature, which is nothing next
-- to a mechanic that can start but never clean up. Following that
-- precedent rather than re-litigating it.
CreateThread(function()
    while true do
        Wait(VEHICLE_SEAT_CLAIM_SWEEP_INTERVAL_MS)

        -- Read LIVE, every pass -- never a boot-time snapshot. When the
        -- feature is off there is nothing to sweep, and the table is
        -- already emptied by playerDropped/onResourceStop regardless, so
        -- this costs one comparison.
        if Config.Features.VehicleEntryExit then
            local now = GetGameTimer()
            for netId, seats in pairs(VehicleSeatClaims) do
                -- VEHICLE-GONE CHECK -- the one thing lazy TTL expiry alone
                -- (GetLiveClaim, consulted only when a NEW request touches
                -- this exact seat again) would never catch on its own: a
                -- vehicle deleted/despawned mid-claim that nobody ever asks
                -- about again. expectedEntityType = 2 (vehicle) so a netId
                -- that now resolves to some unrelated entity is also
                -- correctly treated as "gone" for this claim's purposes.
                local vehicleGone = ResolveNetworkEntity(netId, 2) == nil

                for seatIndex, claim in pairs(seats) do
                    if vehicleGone or (now - claim.claimedAt > VEHICLE_SEAT_CLAIM_TTL_MS) then
                        seats[seatIndex] = nil
                        -- EXCLUSIVE BODY-CLAIM REGISTRY release -- see
                        -- GetLiveClaim's own identical release above for why
                        -- this can never double-release unsafely.
                        ReleaseBody(claim.citizenid, 'vehicle_seat')
                    end
                end

                if not next(seats) then
                    VehicleSeatClaims[netId] = nil
                end
            end
        end
    end
end)
