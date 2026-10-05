--[[
    john-k9/client/vehicle.lua

    Owns K9 vehicle entry/exit only — self-administered (the K9 player
    interacts with the vehicle themselves, nobody does it to them, per
    DEVELOPER_REFERENCE.md §6.1). Never touches leash/ox_target-on-peds
    (that's client/movement.lua's job) — keep that split.

    REAL SEATING, NOT AN ATTACH-BASED APPROXIMATION (owner-reported real
    defect fix): entry used to hide/freeze/collision-disable the K9's own
    ped and AttachEntityToEntity it to a boot/trunk offset behind the vehicle.
    That put the dog in the wrong place (behind the car, not in it) AND made
    it invisible, so nobody — not even the K9's own handler in the passenger
    seat — could ever see a police dog riding along, the entire point of the
    feature. This file now finds a genuinely free passenger seat (rear
    preferred, never the driver's) via IS_VEHICLE_SEAT_FREE, opens that seat's
    real door, seats the ped into it with SET_PED_INTO_VEHICLE (a real,
    game-recognized vehicle occupant — visible, collidable, not attached to
    anything), and shuts the door behind it. See FindBestK9Seat()/
    SEAT_TO_DOOR_INDEX below for the exact seat/door native verification and
    mapping rationale.

    ======================================================================
    EVENT/CALLBACK CONTRACT (REWRITTEN THIS PASS — SEAT-RACE FIX). Until
    now this section said "this file does not register or trigger any
    network event/callback ... vehicle entry/exit is purely a client-local
    action" and flagged that assumption "worth re-confirming." A
    concurrency audit confirmed it was wrong: two K9 handlers selecting
    "Enter Vehicle" on the same cruiser within the same ~400ms door-open
    window each independently compute the SAME "best free seat" (neither
    has entered yet, so IS_VEHICLE_SEAT_FREE reads free for both), and since
    nothing anywhere arbitrated between them, both SET_PED_INTO_VEHICLE
    calls landed on the identical vehicle/seat pair. Exactly the same bug
    class this resource already fixed for leash
    (requestLeashAttach/respondLeashAttach, server/main.lua) and kennel
    (requestEnterKennel/requestPickupKennel, server/kennel.lua) — this was
    the one paired mechanic still relying on "nobody else could possibly be
    doing this at the same time," and it was wrong here for the same reason
    it was wrong there.

    THE FIX — a server-side seat claim, server/vehicle.lua (NEW FILE), same
    check-then-write-with-no-yield discipline as server/kennel.lua's own
    requestEnterKennel/requestPickupKennel:
      'john-k9:server:requestVehicleSeatClaim' (vehicleNetId: number, seatIndex: number, requestToken: number) [server/vehicle.lua]
        Sent immediately after this file's own local pre-flight checks pass
        (feature flag, HasK9Access — UPDATED, permission audit follow-up:
        was CanShowK9UI(), widened to match this same file's own
        requestVehicleSeatClaim handler, which gates access on
        HasK9Access(src) alone — per-person block, drag/bite-hold mutual
        guard, IsPedInAnyVehicle, nearest-vehicle, FindBestK9Seat) and BEFORE
        any door/seat native is ever touched — a denial therefore never has
        to undo a door it already opened. requestToken is an opaque,
        per-request, monotonically increasing local counter this file
        generates and the server only ever echoes back verbatim (never
        interpreted server-side) — see pendingSeatClaim below for why:
        vehicleEntryInProgress means at most one request is ever actually
        outstanding at a time, but a response can still arrive AFTER this
        file has already given up and abandoned it (see
        VEHICLE_SEAT_CLAIM_TIMEOUT_MS below) — the token lets that stale
        response be told apart from the current one rather than acted on by
        mistake.
      'john-k9:client:vehicleSeatClaimGranted' (vehicleNetId, seatIndex, requestToken) [THIS FILE]
        Server granted the claim. ONLY NOW does this file open the door and
        run the existing DOOR_OPEN_DELAY/re-validate/seat/DOOR_SHUT_DELAY
        sequence (unchanged in substance from before this pass), releasing
        the claim (see below) the instant it either genuinely seats the ped
        or aborts for a purely local reason (drag/bite-hold started mid-
        delay, vehicle/ped gone, the seat taken by an ordinary human via
        vanilla controls) — none of which the server's own claim registry
        can see or needs to; it only ever arbitrates between two requests
        going through THIS event.
      'john-k9:client:vehicleSeatClaimDenied' (vehicleNetId, seatIndex, requestToken) [THIS FILE]
        Server refused (not certified, invalid/wrong-model vehicle, too far,
        or — the actual race this pass exists to close — someone else
        already holds this exact seat's claim). The server has already told
        the player why via NotifyPlayer server-side (matches
        server/kennel.lua's own requestEnterKennel convention: the server
        owns messaging for its OWN rejection reasons) — this handler only
        resets this file's local bookkeeping; no local notify.
      'john-k9:server:releaseVehicleSeatClaim' (vehicleNetId: number, seatIndex: number) [server/vehicle.lua]
        Fire-and-forget, sent the instant a granted claim's job is done
        (seated, or aborted locally) so it never lingers for its own
        server-side TTL once genuinely unneeded — a freshly-vacated seat
        would otherwise wrongly read "taken" to the next comer until the
        stale claim expires. Also sent, best-effort, from this file's own
        onResourceStop handler and from the give-up timeout below — never
        gated on anything, per this file's own "never gate a termination
        path" doctrine (see ExitK9Vehicle() below).

    server/vehicle.lua independently re-verifies HasK9Access(src) and the
    claimed vehicle's model against Config.K9Vehicles, server-side — BOTH
    are new, and BOTH close the exact gap this section used to flag ("a
    modified client ... had the same freedom ... flagged for independent
    confirmation"): a modified client can no longer claim a seat in a K9
    vehicle at all without passing the same access check every other paired
    mechanic in this resource already enforces server-side.

    ExitK9Vehicle() below is COMPLETELY UNCHANGED by this pass and stays
    100% local, with no server contact of any kind — once a ped is
    genuinely SET_PED_INTO_VEHICLE'd, GET_VEHICLE_PED_IS_IN/game-engine seat
    occupancy is itself the authoritative, networked truth every other
    client already observes, so there is nothing left for a server-side
    arbiter to decide on the way out. Per this resource's "gate the start of
    a thing, never the stop" rule, exiting must never depend on a round trip
    that could fail, time out, or leave a player waiting to get out of a
    car — see client/kennel.lua's/server/kennel.lua's own comments on this
    exact rule, which this file's own design was checked against before
    writing a line of the fix above.

    NOT ACTUALLY INVISIBLE TO OTHER PLAYERS (worth stating explicitly since
    it's a real change from before): SET_PED_INTO_VEHICLE/
    SET_VEHICLE_DOOR_OPEN/SET_VEHICLE_DOOR_SHUT act on networked entities
    (the acting player's own ped, and a vehicle that already exists as a
    networked entity in the world), and seat occupancy + door state are core
    CPed/CVehicle attributes the game engine replicates to every other client
    automatically — the SAME sync mechanism every other player's ordinary
    vehicle seating and door state already relies on, with no custom
    networking code needed here, before or after this change. This does NOT
    change the trust model described above: a modified client already had
    the same freedom to place/attach/hide its own ped however it liked
    (the exact capability the old attach-based code exercised); genuinely
    occupying a real seat instead is a different VISUAL manifestation of the
    same pre-existing "client controls its own ped" trust boundary, not a
    new capability. Flagged for independent confirmation rather than
    asserted unilaterally, per this file's own established practice above.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        EnterNearestK9Vehicle()
        ExitK9Vehicle()
        IsInK9Vehicle() -> boolean
      IsInK9Vehicle() reports true only once the ped is genuinely,
      game-recognized SET_PED_INTO_VEHICLE'd into a seat — NOT during the
      brief door-open animation window between a player selecting "Enter
      Vehicle" and actually being seated (see EnterNearestK9Vehicle()'s own
      comment on why that window is safe for every consumer of this
      function: client/combat.lua's mutual guard, client/movement.lua's
      leash pull-back skip, and client/radial.lua's/client/tablet.lua's own
      toggle logic).
    - THIS FILE calls client/main.lua's global HasK9Access() (UPDATED,
      permission audit follow-up this pass — was CanShowK9UI(), widened in
      EnterNearestK9Vehicle() to match server/vehicle.lua's own
      requestVehicleSeatClaim gate) before acting on the ENTER path only;
      ExitK9Vehicle() stays completely ungated, on purpose — see its own
      doc comment. Also calls client/main.lua's global
      ResolveNetworkEntity(netId) inside ResolveVehicleFromState() below
      (DEVELOPER_REFERENCE.md near-term item 2 — was this file's own
      independent copy of the same defensive-resolve sequence).
      NOTE: the ox_target "Load Into Vehicle" option's own canInteract
      predicate (RegisterVehicleOxTargetOptions() below) still hides the
      option on the narrower CanShowK9UI() — a purely cosmetic,
      out-of-scope-this-pass gap deliberately left alone (see that
      predicate's own comment): a High Command/autoAccessGrade-bypass
      holder still reaches EnterNearestK9Vehicle() end-to-end via
      client/radial.lua's own k9_vehicle item, just not via this hover
      option, until that predicate gets the same widening.
]]

-- ======================================================================
-- FILE-TOP FEATURE GATE -- this file previously had NO such gate at all:
-- EnterNearestK9Vehicle()/ExitK9Vehicle()/IsInK9Vehicle() each self-checked
-- Config.Features.VehicleEntryExit internally, but the onResourceStart
-- handler that registers the "Load/Release" ox_target options and the
-- vehicle-despawn/own-death watchdog thread below both ran unconditionally
-- regardless of the flag -- breaking this resource's "flag off means
-- genuinely inert" invariant (client/fetch.lua / client/audio.lua /
-- client/hud.lua precedent for this exact shape of top-level gate).
--
-- WHY A PLAIN TOP-LEVEL RETURN IS SAFE HERE, NOT AN UNBOUNDED TRAP --
-- worked out deliberately, not assumed, because this file's own watchdog
-- thread exists specifically to prevent a player being stranded mid-ride:
--   1. STALENESS NOTE (SEAT-RACE FIX pass): server/runtimecontrol.lua's own
--      FEATURE_TIERS still lists VehicleEntryExit as `tier = 'clientonly'`
--      ("zero occurrences in any server/*.lua file") as of this pass's own
--      start -- that specific factual claim is now stale, since
--      server/vehicle.lua (NEW FILE, this pass) does check
--      Config.Features.VehicleEntryExit, per-request, inside its own
--      requestVehicleSeatClaim handler (the same 'live'-tier shape
--      DeployableKennel's own FEATURE_TIERS entry already documents for
--      server/kennel.lua). Flagged to coder-architect/whoever owns
--      server/runtimecontrol.lua to correct that entry rather than silently
--      left to drift, since this file does not own that one. What does NOT
--      change: Config.Features itself is still a plain static table in
--      config.lua (no metatable, no live-reload proxy -- confirmed by
--      reading config.lua directly), on BOTH realms independently, so there
--      is still no code path, anywhere in this resource, that changes what
--      THIS CLIENT's own Config.Features.VehicleEntryExit evaluates to for
--      the lifetime of this file's current load -- an operator "disabling
--      it" can only mean editing config.lua's source and restarting this
--      resource (and, independently, the server process, for its own copy
--      of the same flag). A same-session, no-restart toggle simply cannot
--      happen for THIS CLIENT's flag, by construction, so this gate cannot
--      fire out from under a rider whose current script instance already
--      loaded with the flag true -- the reasoning below is otherwise
--      unaffected by server/vehicle.lua's new existence.
--   2. The one real path that DOES change the flag's value for this client
--      -- editing config.lua and restarting this resource -- necessarily
--      stops the OLD script instance first (FXServer fires `onResourceStop`
--      for every client running this resource's client scripts as part of
--      that restart, before the new instance with the new config value ever
--      loads). This file's own `onResourceStop` handler below is registered
--      by that OLD instance while the flag was still true, and is NOT
--      affected by what the NEW instance's top-level gate above will decide
--      -- it already runs today, unconditionally, on every stop of this
--      resource, and releases a mid-ride player exactly as it always has.
--      The watchdog thread below needs no equivalent carve-out: it is a
--      loop inside that same OLD, still-running instance, not something the
--      new instance's gate could reach into and stop early.
--   3. Net effect: a rider mid-ride when the flag flips off (via the only
--      real mechanism above) is released by the existing onResourceStop
--      handler at the moment of restart, same as today; a fresh session
--      that boots with the flag already off never lets a player into a
--      vehicle through this file in the first place (EnterNearestK9Vehicle's
--      own internal check already prevented that before this gate existed),
--      so vehicleState can never be non-nil for that session and the
--      watchdog never has anything to guard. Gating registration here adds
--      no new way to get stuck; it only stops the watchdog/ox_target
--      registration from running at all in a session that could never have
--      produced a mid-ride player to begin with.
-- If a future change ever gives this feature a live, no-restart toggle
-- path, this reasoning must be re-verified before relying on it again.
-- ======================================================================
if not Config.Features.VehicleEntryExit then return end

-- Local-only "am I currently tucked into a vehicle" state. Not exposed
-- directly — always go through IsInK9Vehicle()/EnterNearestK9Vehicle()/
-- ExitK9Vehicle(). Stores the vehicle's NETWORK id, not a raw entity
-- handle — see ResolveVehicleFromState() below for why (a cached raw
-- handle can go stale over a ride of unknown length; client/movement.lua's
-- leash pull-back thread established this exact re-resolve-every-use
-- pattern for the same reason on a ped handle). `seatIndex` is kept purely
-- for diagnostics/testability — nothing in this file re-reads it after
-- entry (the ped's actual current seat is always re-resolved live via
-- GET_VEHICLE_PED_IS_IN where it matters, e.g. ForceLeaveVehicle() below,
-- never trusted from this cached copy).
--- @type { vehicleNetId: number, seatIndex: number } | nil
local vehicleState = nil

-- Set for the short window between a player selecting "Enter Vehicle" and
-- the ped actually being seated (door-open animation delay) — see
-- EnterNearestK9Vehicle()'s own header comment for why this window is safe
-- for every OTHER file's IsInK9Vehicle() check to simply not know about
-- (they only need to know "seated or not," not "mid-entry"), and exists
-- here purely to stop a double-click/double-select from racing two
-- concurrent entry sequences against the same ped.
local vehicleEntryInProgress = false

--- SEAT-RACE FIX — the single outstanding server seat-claim request this
--- client may have in flight at any time (vehicleEntryInProgress above
--- already guarantees at most one exists). Covers BOTH phases of a request
--- uniformly — "still waiting on requestVehicleSeatClaim's response" AND
--- "granted, mid local door/seat sequence" — deliberately, so every cleanup
--- path (the give-up timeout, onResourceStop) only has to check ONE field
--- to know whether there is a live server-side claim to release. Cleared
--- the instant the request is settled one way or another: granted-and-then-
--- seated-or-aborted, denied, or timed out locally. See this file's own
--- EVENT/CALLBACK CONTRACT header section above for the full request/
--- response design.
--- @type { token: number, vehicle: number, ped: number, doorIndex: number?, seatIndex: number, vehicleNetId: number, granted: boolean } | nil
local pendingSeatClaim = nil
local seatClaimTokenSeq = 0

--- @return boolean
function IsInK9Vehicle()
    return vehicleState ~= nil
end

-- Precomputed set of Config.K9Vehicles model hashes, built once at file
-- load — no hardcoded model name anywhere, generic over the config
-- (DEVELOPER_REFERENCE.md §3 acceptance bullet 3 spirit, applied here to vehicles too).
local K9VehicleHashes = {}
for _, model in ipairs(Config.K9Vehicles) do
    K9VehicleHashes[GetHashKey(model)] = true
end

-- ======================================================================
-- SEAT / DOOR NATIVE VERIFICATION — every native named in this section was
-- checked against the citizenfx/fivem native-decls repo first; every one
-- of them 404'd there (a 404 is NOT proof of absence, per this resource's
-- own standing rule), so all are instead verified against the documented
-- fallback, https://runtime.fivem.net/doc/natives.json, which DOES carry
-- each of them with a real hash and parameter list:
--   IS_VEHICLE_SEAT_FREE     0x22AC59A870E6A669 (VEHICLE) -- (vehicle, seatIndex) -> BOOL
--   SET_PED_INTO_VEHICLE     0xF75B0D629E1C063D (PED)     -- (ped, vehicle, seatIndex) -> void
--   GET_VEHICLE_MAX_NUMBER_OF_PASSENGERS
--                            0xA7C4F2C6E744A550 (VEHICLE) -- (vehicle) -> int
--   SET_VEHICLE_DOOR_OPEN    0x7C65DAC73C35C862 (VEHICLE) -- (vehicle, doorIndex, loose, openInstantly) -> void
--   SET_VEHICLE_DOOR_SHUT    0x93D9BD300D7789E5 (VEHICLE) -- (vehicle, doorIndex, closeInstantly) -> void
--   TASK_LEAVE_VEHICLE       0xD3DBCE61A490BE02 (TASK)    -- (ped, vehicle, flags) -> void
--   CLEAR_PED_TASKS_IMMEDIATELY
--                            0xAAA34F8A7CB32098 (TASK)    -- (ped) -> void
--   NETWORK_REQUEST_CONTROL_OF_ENTITY
--                            0xB69317BF5E782347 (NETWORK) -- (entity) -> BOOL
-- GET_VEHICLE_PED_IS_IN (0x9A9112A0FE9A4713, PED) and IS_PED_IN_ANY_VEHICLE
-- (0x997ABD671D25CA0B, PED) both DO have a live native-decls page:
--   https://raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/GetVehiclePedIsIn.md
--   https://raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/IsPedInAnyVehicle.md
--
-- SEAT INDEX MAPPING (eSeatPosition, taken verbatim from
-- IS_VEHICLE_SEAT_FREE's own natives.json description — not guessed):
--   -1 = front, driver's side       (NEVER a candidate here — the human driver's seat)
--    0 = front, passenger's side
--    1 = back,  driver's side       -- REAR, preferred
--    2 = back,  passenger's side    -- REAR, preferred
--    3 = alt front, driver's side   (extended-cab/third-front-seat vehicles only)
--    4 = alt front, passenger's side
--    5 = alt back,  driver's side   -- REAR, preferred (third-row/van seating)
--    6 = alt back,  passenger's side
-- "Rear seats first, never the driver's seat" (owner's own words) therefore
-- means trying 1, 2, 5, 6 before falling back to 0, 3, 4, with -1 never in
-- this list at all. Seat indices range from -1 to
-- GET_VEHICLE_MAX_NUMBER_OF_PASSENGERS(vehicle) - 1 (also stated verbatim in
-- that same natives.json description) — FindBestK9Seat() below bounds-checks
-- every candidate against that before ever calling IS_VEHICLE_SEAT_FREE on
-- it, so a normal 4-seat cruiser (max passengers = 3, valid seats -1..2)
-- never even queries 3/4/5/6.
local SEAT_PREFERENCE_ORDER = { 1, 2, 5, 6, 0, 3, 4 }

-- DOOR INDEX MAPPING (eDoorId, taken verbatim from SET_VEHICLE_DOOR_SHUT's
-- own natives.json description, which documents the full enum):
--   0 = VEH_EXT_DOOR_DSIDE_F (driver's side,    front)
--   1 = VEH_EXT_DOOR_DSIDE_R (driver's side,    rear)
--   2 = VEH_EXT_DOOR_PSIDE_F (passenger's side, front)
--   3 = VEH_EXT_DOOR_PSIDE_R (passenger's side, rear)
--   4 = bonnet, 5 = boot (not doors K9s sit behind — never used here)
-- THIS IS DELIBERATELY *NOT* "doorIndex = seatIndex + 1" — that would be
-- wrong for exactly the pair that matters most here: doors are grouped
-- SIDE-then-front/rear, while seats are grouped front/rear-THEN-side, so
-- the two numberings diverge starting at the rear pair. Worked through
-- concretely: seat 1 is "back, driver's side" -> its door must be
-- VEH_EXT_DOOR_DSIDE_R = door 1, NOT door 2 (a "+1" guess would have opened
-- VEH_EXT_DOOR_PSIDE_F, the FRONT door on the WRONG side, for a K9 climbing
-- into the back-left seat). Verified against the enum text itself, not
-- assumed from the seat numbering's own shape.
-- Only seats -1/0/1/2 (the four doors every standard 4-door vehicle has)
-- have a natives.json-verified mapping. The "Alt" seats (3/4/5/6 —
-- extended-cab/third-row vehicles only) have NO documented door index of
-- their own: eDoorId only runs 0-5 (four side doors plus bonnet/boot), so a
-- vehicle with more than four seats necessarily reuses one of the same four
-- door slots for its extra row, in a way that varies per model (sliding
-- panel-van doors, crew-cab truck doors, etc.) and has no single verified
-- formula. The mapping below reuses each Alt seat's nearest non-Alt
-- equivalent as a best-effort approximation for those cases ONLY — stated
-- here plainly as UNVERIFIED for Alt seats, not asserted as correct. Every
-- Config.K9Vehicles entry (`police`, `police2`, `police3`, `police4`,
-- `sheriff`, `sheriff2` per DEVELOPER_REFERENCE.md §5) is an ordinary
-- 4-seat cruiser, so this approximation is not expected to be exercised by
-- this resource's actual shipped config; flagged for native-api-assistant
-- re-confirmation if a K9 van/SUV with a third row is ever added to that
-- list.
local SEAT_TO_DOOR_INDEX = {
    [-1] = 0, [0] = 2, [1] = 1, [2] = 3,
    [3] = 0, [4] = 2, [5] = 1, [6] = 3,
}

-- Short, hand-picked local constants (not Config-exposed): no operator
-- config.lua edit could ever reach these, so — per server/cooldowns.lua's
-- own documented decision test ("does an operator's config.lua edit alone
-- reach this value?") — they stay plain literals here, not routed through
-- a ResolveConfiguredThresholdMs-style clamp-and-warn (that machinery exists
-- for OPERATOR-EDITABLE Config fields, and adding one here would be a
-- schema change to a HOT, additive-only file for no config value this
-- feature actually needs to expose).
local VEHICLE_DOOR_OPEN_DELAY_MS = 400  -- door swings open before the K9 is seated
local VEHICLE_DOOR_SHUT_DELAY_MS = 300  -- brief pause once seated before the door swings shut
local EXIT_STALL_FALLBACK_MS = 4000     -- ExitK9Vehicle()'s own graceful-exit stall fallback (see below)

-- SEAT-RACE FIX — task requirement "the client must still degrade sanely
-- if the server never answers": how long this file waits for
-- requestVehicleSeatClaim's response before giving up locally and treating
-- it exactly like a denial. Generous relative to an ordinary round trip
-- (normally well under a second) without leaving a player who clicked
-- "Enter Vehicle" wondering indefinitely — same order of magnitude as this
-- file's own EXIT_STALL_FALLBACK_MS above and server/main.lua's
-- LEASH_REQUEST_TTL_MS-style bounded waits elsewhere in this resource.
local VEHICLE_SEAT_CLAIM_TIMEOUT_MS = 5000

--- @param maxDistance number
--- @return number? vehicle
local function FindNearestK9Vehicle(maxDistance)
    local myCoords = GetEntityCoords(PlayerPedId())
    local vehicles = GetGamePool('CVehicle')
    local nearestVehicle, nearestDist

    for i = 1, #vehicles do
        local vehicle = vehicles[i]
        if K9VehicleHashes[GetEntityModel(vehicle)] then
            local dist = #(myCoords - GetEntityCoords(vehicle))
            if dist <= maxDistance and (not nearestDist or dist < nearestDist) then
                nearestVehicle, nearestDist = vehicle, dist
            end
        end
    end

    return nearestVehicle
end

--- Finds the best free, non-driver seat for a K9 to ride in — rear seats
--- preferred, front passenger as fallback, never the driver's seat, and
--- never a seat IS_VEHICLE_SEAT_FREE reports as occupied (by a human or
--- anything else) — see SEAT_PREFERENCE_ORDER's own header comment for the
--- full verified seat-index rationale.
--- @param vehicle number
--- @return number? seatIndex
-- ======================================================================
-- HOW A K9 SITS ONCE IT IS IN (owner-directed, this pass).
--
-- GTA has no "dog riding in a car" animation. SET_PED_INTO_VEHICLE puts a
-- quadruped into a seat and the engine plays its ordinary human sit-in
-- pose, which is what made a K9 in a car read wrong. These play a real dog
-- scenario on the seated ped instead.
--
-- Per-breed lookup, copied verbatim from client/movement.lua's own
-- native-api-assistant-verified K9_SIT_SCENARIO_BY_MODEL_HASH -- see that
-- file's doc comment above K9Sit() for the full verification writeup (two
-- independent community scenario dumps agreeing WORLD_DOG_SIT is NOT real
-- and the genuine names are per-breed). Same disclosed-duplicate posture
-- client/findalert.lua and client/kennel.lua already use for their own
-- copies, and for the same reason: K9Sit() opens with a CanShowK9UI gate,
-- and a cosmetic pose must never carry an authorization check.
--
-- THERE IS NO VERIFIED LYING-DOWN SCENARIO NAME. That is why
-- Config.K9VehicleRide.rearPose ships 'sit' rather than 'lie' -- inventing
-- a lie-down name would be a silent no-op, the exact failure class this
-- resource keeps having to dig out. An operator who has a confirmed one
-- names it in lieScenarioOverride and flips the pose.
local K9_RIDE_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd   = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop       = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists
    a_c_husky      = 'WORLD_DOG_SITTING_RETRIEVER',  -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit
}) do
    K9_RIDE_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_RIDE_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD'

--- Rear seats are 1, 2, 5 and 6 (see SEAT_PREFERENCE_ORDER above and the
--- seat-index enum block with it). 0, 3 and 4 are front passenger seats.
--- Seat -1 never reaches here -- it is not in the preference order at all.
--- @param seatIndex number
--- @return boolean
local function IsRearSeat(seatIndex)
    return seatIndex == 1 or seatIndex == 2 or seatIndex == 5 or seatIndex == 6
end

--- Resolves which pose this seat should use and plays it on the local ped.
--- NOT GATED on anything -- a cosmetic pose is not a capability, and by the
--- time this runs the server has already granted the seat claim. Same
--- reasoning client/kennel.lua's own PlayKennelRestPose documents.
---
--- 'none' is honoured as a real choice (some operators will prefer the
--- engine's default), and a 'lie' with no configured scenario name falls
--- back to the sit pose rather than playing nothing -- a half-finished
--- setting must never leave the dog standing upright in a car seat.
--- @param ped number
--- @param seatIndex number
local function PlayK9RidePose(ped, seatIndex)
    local cfg = type(Config.K9VehicleRide) == 'table' and Config.K9VehicleRide or {}
    local pose = IsRearSeat(seatIndex) and cfg.rearPose or cfg.frontPose
    if pose == 'none' then return end

    local scenarioName
    if pose == 'lie' and type(cfg.lieScenarioOverride) == 'string' and cfg.lieScenarioOverride ~= '' then
        scenarioName = cfg.lieScenarioOverride
    else
        scenarioName = K9_RIDE_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_RIDE_DEFAULT_SCENARIO
    end

    -- playEnterAnim = false, same reasoning as client/kennel.lua's rest
    -- pose: this ped is already fixed in a seat, so an enter transition
    -- would render as sliding against a position it cannot actually leave.
    TaskStartScenarioInPlace(ped, scenarioName, 0, false)
end

local function FindBestK9Seat(vehicle)
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)
    for _, seatIndex in ipairs(SEAT_PREFERENCE_ORDER) do
        -- Seat indices range from -1 to maxPassengers - 1 (natives.json's own
        -- documented bound for IS_VEHICLE_SEAT_FREE) — bounds-check BEFORE
        -- querying so a normal 4-seat cruiser never asks about seats 3-6 at
        -- all.
        if seatIndex <= maxPassengers - 1 and IsVehicleSeatFree(vehicle, seatIndex) then
            return seatIndex
        end
    end
    return nil
end

--- Re-resolves the vehicle referenced by vehicleState back to a live
--- entity handle via its network id, rather than trusting a raw handle
--- cached at entry time to stay valid for the whole ride (the vehicle can
--- be streamed out and back in, in which case the old handle silently
--- refers to nothing/something else). Mirrors client/movement.lua's leash
--- pull-back thread, which re-resolves its partner ped from a server id
--- every tick for the identical reason ("a cached ped handle can go
--- stale"). The actual resolve-and-guard sequence is now
--- client/main.lua's shared ResolveNetworkEntity() (DEVELOPER_REFERENCE.md
--- near-term item 2) — this function's only remaining job is the
--- vehicleState-nil short-circuit, which is specific to this file's own
--- local state and doesn't belong in the generic resolver.
--- @return number? vehicle
local function ResolveVehicleFromState()
    if not vehicleState then return nil end
    return ResolveNetworkEntity(vehicleState.vehicleNetId)
end

--- @param ped number
--- @return number? vehicle
local function CurrentVehiclePedIsIn(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle ~= 0 then return vehicle end
    return nil
end

--- Forces `ped` out of whatever vehicle it is CURRENTLY, ACTUALLY seated in
--- — re-resolved fresh from the ped itself via GET_VEHICLE_PED_IS_IN, never
--- trusted from vehicleState's possibly-stale cached netId, so this works
--- correctly even if the two have diverged (e.g. the ped somehow ended up in
--- a different vehicle than the one this file was tracking). No-ops
--- entirely if the ped isn't in any vehicle at all — the common case now
--- that seating is real: the player's own ordinary "exit vehicle" control
--- already works unaided (see ExitK9Vehicle()'s own comment), and the game
--- engine itself force-ejects any occupant when a vehicle is deleted, so
--- there is frequently nothing left to do by the time this runs.
---
--- TWO PATHS, chosen by whether the ped can still run tasks at all:
---   ALIVE: TASK_LEAVE_VEHICLE with flag 16 ("teleports outside, door kept
---   closed" per that native's own natives.json flag documentation) — this
---   queues a real engine-level CTask against the ped/vehicle, which is
---   entity/engine state, NOT bound to this Lua resource's own lifetime —
---   the exact same "keeps applying independent of this script still
---   running" property this file's header already relied on for the old
---   frozen/attach/visible/collision native states, so queuing it from
---   onResourceStop (this file's own hard termination path, below) is safe:
---   it keeps executing even if this resource finishes unloading a tick
---   later.
---   DEAD: TASK_LEAVE_VEHICLE does not reliably apply to a dead/ragdolled
---   ped (no task capacity while dead) — falls back to the same blunt
---   CLEAR_PED_TASKS_IMMEDIATELY + manual reposition this file has always
---   used for its own-death release path, which does not depend on the
---   ped's ability to run a task at all.
--- @param ped number
local function ForceLeaveVehicle(ped)
    local vehicle = CurrentVehiclePedIsIn(ped)
    if not vehicle then return end -- already out; see this function's own header

    if DoesEntityExist(ped) and IsEntityDead(ped) then
        ClearPedTasksImmediately(ped)
        local exitCoords = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -3.0, 0.0)
        SetEntityCoords(ped, exitCoords.x, exitCoords.y, exitCoords.z, false, false, false, true)
        SetEntityHeading(ped, GetEntityHeading(vehicle))
    else
        TaskLeaveVehicle(ped, vehicle, 16)
    end
end

--- Finds the nearest vehicle within Config.VehicleInteractMeters whose
--- model is in Config.K9Vehicles, finds it the best free non-driver seat
--- (rear preferred — see FindBestK9Seat()), opens that seat's door, and
--- seats the K9 into it for real, matching DEVELOPER_REFERENCE.md §6.1's
--- vehicle bullet, which describes this real-seating behavior directly.
---
--- GATE WIDENED TO HasK9Access() ALONE (permission audit follow-up, this
--- pass — closes client/radial.lua's own disclosed "RESIDUAL GAP" note on
--- its k9_vehicle item's Enter branch): server/vehicle.lua's
--- requestVehicleSeatClaim handler gates access on `HasK9Access(src)` alone,
--- confirmed by reading it directly — no model/role check on the requester
--- anywhere in that handler, only the vehicle itself is re-verified as a
--- real K9 vehicle model. This is the ENTER half only; ExitK9Vehicle() below
--- is a wholly separate function, deliberately never gated on
--- CanShowK9UI()/HasK9Access() at all — widening this one cannot touch that
--- one.
function EnterNearestK9Vehicle()
    if not Config.Features.VehicleEntryExit then return end

    -- Widened to HasK9Access() alone -- see this function's own header
    -- above. Known reason -> 'combat.no_access', the same house-standard
    -- string server/combat.lua's own rejection path uses for this exact
    -- cause (server/vehicle.lua's own denial message,
    -- locale('common.no_k9_access'), is unrelated and unchanged — see that
    -- file's own comment on it).
    if not HasK9Access() then
        DenyK9UIAccess('combat.no_access')
        return
    end

    -- Per-person block (client/featureblocks.lua -- see that file's header
    -- for the full contract). Checked here, in EnterNearestK9Vehicle()
    -- itself -- the single resource-global every entry point (radial,
    -- keybind/command, tablet trigger) already routes through, per this
    -- file's own header precedent -- so no second copy of this check is
    -- needed anywhere else. ExitK9Vehicle() below is, and stays, completely
    -- unaffected: that function's own doc comment already states it is
    -- deliberately never gated on CanShowK9UI() at all, for the same
    -- "never leave a player stuck" reasoning this block check must not
    -- violate either.
    if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('VehicleEntryExit') then
        if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
        return
    end

    -- `vehicleEntryInProgress` covers the brief door-open window between a
    -- previous call starting and this ped actually being seated -- without
    -- it, a double-click/double-select during that window would race two
    -- concurrent entry sequences against the same ped. Silent no-op on a
    -- repeat call here matches this same function's own pre-existing
    -- `if IsInK9Vehicle() then return end` convention just below.
    if vehicleEntryInProgress or IsInK9Vehicle() then return end

    -- MUTUAL GUARD vs. client/combat.lua's PropDragging/BiteAndHold: this
    -- function seats the SAME ped (PlayerPedId()) that combat.lua's shared
    -- maintenance thread re-attaches EVERY TICK as the HOLDER anchor of an
    -- active drag (AttachEntityToEntity(targetPed, PlayerPedId(), ...), see
    -- that file's "ActiveDragAsHolder" block) or plays a one-shot cosmetic
    -- stance on for an active bite hold (PlayBiteHoldStance). Checked here
    -- (not just left to RequestDrag()'s own symmetric IsInK9Vehicle() guard)
    -- because the two triggers are reachable in EITHER order -- a K9
    -- already mid-drag/mid-hold selecting "Enter Vehicle" is the direction
    -- RequestDrag()'s own guard cannot catch. Re-checked again just before
    -- the ped is actually seated, below, since the door-open delay gives
    -- either effect a window to start in between.
    --
    -- Soft dependency, `type(...) == 'function'` runtime existence guard —
    -- this resource's established convention (see every other client file's
    -- identical guard on this exact function) — because IsBiteHoldEngaged/
    -- IsDragEngaged only exist at all once client/combat.lua's own top-level
    -- gate (`Config.Features.BiteAndHold/NonLethalTakedown/PropDragging`)
    -- lets that file's globals get defined; VehicleEntryExit can be enabled
    -- on a server that runs none of those three, in which case neither
    -- global is ever declared.
    if type(IsDragEngaged) == 'function' and IsDragEngaged() then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.blocked_by_drag'), type = 'error' })
        return
    end
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.blocked_by_bite_hold'), type = 'error' })
        return
    end

    -- SEAT-RACE FIX pass — DELIBERATE ADDITION, the reverse of the two
    -- guards above. IsDragTargetEngaged() (client/combat.lua) answers "am I
    -- the one CURRENTLY BEING dragged" — a ped attached to another ped via
    -- AttachEntityToEntity every tick (combat.lua's own "ActiveDragAsHolder"
    -- maintenance block). SET_PED_INTO_VEHICLE on a ped that is simultaneously
    -- a rigid child of another entity is a nested-attachment case nobody
    -- designed for, physically nonsensical for the identical reason
    -- IsBlockedByVehicleTuck() already refuses a drag/bite/takedown attempt
    -- against a vehicle-tucked K9 (client/combat.lua) — this closes the
    -- corresponding gap in THIS direction. A K9 (or any ped this resource
    -- lets a human control) can genuinely be a drag TARGET, per
    -- FindNearestDraggableCandidate's own "any ped in range" search, so this
    -- is a real, reachable case, not a hypothetical. Went WITH refusing it,
    -- for the same reasoning as the two checks immediately above: soft
    -- dependency guard, since IsDragTargetEngaged only exists once
    -- client/combat.lua's own PropDragging gate lets that global get
    -- defined.
    if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.blocked_by_being_dragged'), type = 'error' })
        return
    end

    -- MUTUAL GUARD vs. client/kennel.lua's "Rest in Kennel" -- QA-reported
    -- real defect, this pass, same shape as the IsBlockedByVehicleTuck()
    -- pairing client/combat.lua carries against THIS exact function
    -- (see that function's own doc comment for the full "a guard in only
    -- one direction is not a guard" reasoning, not repeated here). A K9
    -- resting in a kennel is genuinely AttachEntityToEntity'd to the kennel
    -- prop (client/kennel.lua's enterKennelConfirmed handler) -- seating that
    -- SAME ped into a vehicle on top of that would either fight the kennel's
    -- own ~1s watchdog re-assertion every tick (client/kennel.lua's shared
    -- watchdog thread, restState branch) or silently win and leave
    -- IsRestingInKennel() reporting true (and server/kennel.lua's own
    -- KennelOccupants entry still held) for a ped that is no longer actually
    -- resting anywhere. Checked here, BEFORE the seat claim is ever
    -- requested (per this pass's own finding that vehicle entry is now
    -- server-arbitrated, server/vehicle.lua) -- refusing only after a grant
    -- would take a real seat claim and then abandon it, leaving that exact
    -- seat unusable by anyone else until VEHICLE_SEAT_CLAIM_TTL_MS elapses
    -- (server/vehicle.lua's own header "A CLAIM MUST NEVER OUTLIVE...").
    --
    -- Soft dependency, `type(...) == 'function'` runtime existence guard --
    -- this resource's established convention (see the IsDragEngaged/
    -- IsBiteHoldEngaged/IsDragTargetEngaged guards immediately above) --
    -- IsRestingInKennel() only exists once client/kennel.lua loads, which is
    -- unconditional at that file's own top (declared outside its
    -- Config.Features.DeployableKennel registration gate) but this file has
    -- no hard load-order requirement on it regardless.
    --
    -- LOCALE KEY: reuses 'kennel.enter_already_resting' ("You are already
    -- resting in a kennel.") rather than minting a new key -- this file is
    -- not locales/en.json's owner, and that string is already the accurate,
    -- honest reason for this refusal (mirrors client/search.lua's own
    -- IsBusyWithSomethingElse() reusing 'combat.blocked_by_vehicle' across
    -- files for the identical "the real-world reason is the same, so is the
    -- message" precedent).
    if type(IsRestingInKennel) == 'function' and IsRestingInKennel() then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_already_resting'), type = 'error' })
        return
    end

    local ped = PlayerPedId()
    -- Real-defect guard: IS_PED_IN_ANY_VEHICLE (verified against the Cfx
    -- native reference, PED namespace, BOOL return) catches the case where
    -- this ped is already a genuine occupant of SOME vehicle via ordinary
    -- game controls (any ped model, including a K9 model, can be walked up
    -- to a car and seated with the vanilla "enter vehicle" control --
    -- nothing about that path goes through this file). vehicleState only
    -- tracks OUR OWN entry, so IsInK9Vehicle() above reads false in that
    -- case and would otherwise let this function try to seat a ped the
    -- game already considers seated somewhere else.
    if IsPedInAnyVehicle(ped, false) then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.already_in_vehicle'), type = 'error' })
        return
    end

    local vehicle = FindNearestK9Vehicle(Config.VehicleInteractMeters)
    if not vehicle then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.no_vehicle_nearby'), type = 'error' })
        return
    end

    -- "Auto-find the perfect spot" (owner's own words): rear seats first,
    -- never the driver's seat, never a seat that's actually occupied. If
    -- literally nothing qualifies, refuse with a clear reason instead of
    -- silently falling back to anything else (the old trunk-attach
    -- behavior this file replaces).
    local seatIndex = FindBestK9Seat(vehicle)
    if not seatIndex then
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.no_seat_available'), type = 'error' })
        return
    end

    vehicleEntryInProgress = true

    -- Best-effort ownership ask, fire-and-forget — client/combat.lua's own
    -- "NETWORK OWNERSHIP OF THE TARGET PED" header (that file's extensively
    -- verified precedent, reused here rather than re-deriving it) explains
    -- why: SET_PED_INTO_VEHICLE/SET_VEHICLE_DOOR_OPEN/SET_VEHICLE_DOOR_SHUT
    -- on a vehicle this client doesn't already own network control of can
    -- silently do nothing, but NETWORK_HAS_CONTROL_OF_ENTITY's own blocking
    -- wait idiom is deliberately NOT used here either, matching that same
    -- file's audited conclusion — proceed regardless, disclosed as
    -- best-effort rather than presented as solved.
    NetworkRequestControlOfEntity(vehicle)

    -- SEAT-RACE FIX — ask the server to claim this exact (vehicle, seat)
    -- pair BEFORE touching a single door/seat native. See this file's own
    -- EVENT/CALLBACK CONTRACT header section above for the full design;
    -- everything below this point is unchanged in substance from before
    -- this pass, just deferred until 'john-k9:client:vehicleSeatClaimGranted'
    -- confirms nobody else already holds this seat.
    seatClaimTokenSeq = seatClaimTokenSeq + 1
    local token = seatClaimTokenSeq
    local vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)

    pendingSeatClaim = {
        token = token,
        vehicle = vehicle,
        ped = ped,
        doorIndex = SEAT_TO_DOOR_INDEX[seatIndex],
        seatIndex = seatIndex,
        vehicleNetId = vehicleNetId,
        granted = false,
    }

    TriggerServerEvent('john-k9:server:requestVehicleSeatClaim', vehicleNetId, seatIndex, token)

    -- GIVE-UP TIMEOUT — task requirement "the client must still degrade
    -- sanely if the server never answers": if neither
    -- vehicleSeatClaimGranted nor vehicleSeatClaimDenied has settled THIS
    -- exact request (token match) within VEHICLE_SEAT_CLAIM_TIMEOUT_MS,
    -- treat it exactly like a denial rather than leaving
    -- vehicleEntryInProgress stuck true forever with no door ever having
    -- opened. The `not pendingSeatClaim.granted` guard means this never
    -- fires once a grant has actually been received — from that point on,
    -- the bounded local door/seat sequence below is what governs
    -- completion, exactly as it always has.
    CreateThread(function()
        Wait(VEHICLE_SEAT_CLAIM_TIMEOUT_MS)
        if pendingSeatClaim and pendingSeatClaim.token == token and not pendingSeatClaim.granted then
            pendingSeatClaim = nil
            vehicleEntryInProgress = false
            -- Best-effort: in case the server's grant is genuinely just
            -- slow rather than lost and arrives a moment after this fires,
            -- this frees the seat immediately instead of leaving it
            -- reserved for the rest of the server's own claim TTL. Safe
            -- no-op if nothing was ever actually granted.
            TriggerServerEvent('john-k9:server:releaseVehicleSeatClaim', vehicleNetId, seatIndex)
            lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.entry_interrupted'), type = 'error' })
        end
    end)
end

--- Server granted this client's outstanding seat claim — see this file's
--- own EVENT/CALLBACK CONTRACT header section for the full design. Runs the
--- same door-open/re-validate/seat/door-shut sequence this file always has,
--- just now gated on a real server grant instead of a purely local
--- assumption that nobody else could be doing the same thing at once.
--- @param vehicleNetId number
--- @param seatIndex number
--- @param token number
RegisterNetEvent('john-k9:client:vehicleSeatClaimGranted', function(vehicleNetId, seatIndex, token)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see client/combat.lua's own header block for the full writeup
    if not pendingSeatClaim or pendingSeatClaim.token ~= token then return end -- stale/unmatched — see pendingSeatClaim's own doc comment
    pendingSeatClaim.granted = true
    local claim = pendingSeatClaim

    local vehicle, ped, doorIndex = claim.vehicle, claim.ped, claim.doorIndex

    if doorIndex then
        SetVehicleDoorOpen(vehicle, doorIndex, false, false)
    end

    -- Deferred so the door has a moment to visibly swing open before the
    -- K9 appears seated ("a short animation-friendly delay") -- run in a
    -- dedicated thread rather than a bare Wait() in this function body so
    -- this doesn't depend on every caller (a net event handler here) already
    -- running inside a yield-safe coroutine context.
    CreateThread(function()
        Wait(VEHICLE_DOOR_OPEN_DELAY_MS)

        -- Re-validate everything that could have changed during the delay:
        -- the vehicle itself, our own ped's state, the chosen seat (someone
        -- else could have taken it in the meantime — never displace them;
        -- the server's own claim only ever arbitrates between two requests
        -- going through this same event, it has no way to see an ordinary
        -- human sitting down via vanilla controls), and the same drag/
        -- bite-hold mutual guard checked before the claim was requested
        -- (either effect could have started during this exact window). Any
        -- failure here aborts cleanly: shuts the door back if it was
        -- opened, clears the in-progress flag, releases the now-unneeded
        -- claim, and tells the player why, rather than forcing the seat
        -- regardless.
        local abortReason = nil
        if not DoesEntityExist(vehicle) then
            abortReason = 'vehicle.entry_interrupted'
        elseif not DoesEntityExist(ped) or IsEntityDead(ped) then
            abortReason = 'vehicle.entry_interrupted'
        elseif IsPedInAnyVehicle(ped, false) then
            abortReason = 'vehicle.entry_interrupted'
        elseif not IsVehicleSeatFree(vehicle, seatIndex) then
            abortReason = 'vehicle.no_seat_available'
        elseif type(IsDragEngaged) == 'function' and IsDragEngaged() then
            abortReason = 'vehicle.blocked_by_drag'
        elseif type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
            abortReason = 'vehicle.blocked_by_bite_hold'
        elseif type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then
            -- Mirrors the pre-flight guard above — see its own doc comment
            -- for the full reasoning; re-checked here because the delay
            -- gives this effect the same window to start in between that
            -- drag/bite-hold already get re-checked for.
            abortReason = 'vehicle.blocked_by_being_dragged'
        elseif type(IsRestingInKennel) == 'function' and IsRestingInKennel() then
            -- Mirrors the pre-flight kennel-rest guard above — see its own
            -- doc comment for the full reasoning. Re-checked here for the
            -- identical "the door-open delay is a window too" reason as
            -- every other guard in this chain: "Rest in Kennel" is its own
            -- independent, server-arbitrated round trip
            -- (client/kennel.lua's requestEnterKennel/enterKennelConfirmed)
            -- that can complete during this exact VEHICLE_DOOR_OPEN_DELAY_MS
            -- window even though it wasn't true at the moment the seat claim
            -- was first requested. Same reused locale key as the pre-flight
            -- guard above ('kennel.enter_already_resting') -- see that
            -- guard's own doc comment for why.
            abortReason = 'kennel.enter_already_resting'
        end

        if abortReason then
            if doorIndex and DoesEntityExist(vehicle) then
                SetVehicleDoorShut(vehicle, doorIndex, false)
            end
            vehicleEntryInProgress = false
            if pendingSeatClaim == claim then pendingSeatClaim = nil end
            TriggerServerEvent('john-k9:server:releaseVehicleSeatClaim', vehicleNetId, seatIndex)
            lib.notify({ title = locale('common.notify_title'), description = locale(abortReason), type = 'error' })
            return
        end

        NetworkRequestControlOfEntity(vehicle) -- control can be lost again during the delay; re-ask once more, same fire-and-forget posture
        SetPedIntoVehicle(ped, vehicle, seatIndex)
        -- Genuinely seated now — GET_VEHICLE_PED_IS_IN/game-engine seat
        -- occupancy is itself authoritative from this instant on, so the
        -- server-side claim has done its job and is released immediately
        -- rather than left to linger for its own TTL.
        if pendingSeatClaim == claim then pendingSeatClaim = nil end
        TriggerServerEvent('john-k9:server:releaseVehicleSeatClaim', vehicleNetId, seatIndex)

        Wait(VEHICLE_DOOR_SHUT_DELAY_MS)
        if doorIndex and DoesEntityExist(vehicle) then
            SetVehicleDoorShut(vehicle, doorIndex, false)
        end

        -- Store the NETWORK id, not the raw `vehicle` handle above — see
        -- ResolveVehicleFromState()'s doc comment for why the handle itself
        -- isn't trusted to stay valid for the whole ride.
        vehicleState = { vehicleNetId = vehicleNetId, seatIndex = seatIndex }
        vehicleEntryInProgress = false

        -- THE RIDE POSE. Applied after the door-shut wait above, which is
        -- itself past the engine's own get-in animation -- playing it any
        -- earlier means the get-in anim overrides it the instant it runs.
        -- Re-checked against live state rather than assumed: the dog may
        -- have been pulled out, died, or had the vehicle vanish during the
        -- wait, and posing a ped that is no longer seated would leave a
        -- sitting dog standing in the road.
        local poseCfg = type(Config.K9VehicleRide) == 'table' and Config.K9VehicleRide or {}
        local poseDelay = type(poseCfg.poseDelayMs) == 'number' and poseCfg.poseDelayMs or 900
        CreateThread(function()
            Wait(poseDelay)
            local livePed = PlayerPedId()
            if not vehicleState then return end
            if not DoesEntityExist(livePed) or IsEntityDead(livePed) then return end
            if not IsPedInAnyVehicle(livePed, false) then return end
            PlayK9RidePose(livePed, seatIndex)
        end)
        lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.loaded'), type = 'success' })
    end)
end)

--- Server refused this client's outstanding seat claim — either a real
--- rejection (not certified, invalid vehicle, too far) or the actual race
--- this pass exists to close (someone else already holds this exact seat's
--- claim). The server has already told the player why via NotifyPlayer
--- server-side (matches server/kennel.lua's own requestEnterKennel
--- convention) — this handler only resets local bookkeeping.
--- @param vehicleNetId number
--- @param seatIndex number
--- @param token number
RegisterNetEvent('john-k9:client:vehicleSeatClaimDenied', function(vehicleNetId, seatIndex, token)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see client/combat.lua's own header block for the full writeup
    if not pendingSeatClaim or pendingSeatClaim.token ~= token or pendingSeatClaim.granted then return end -- stale/unmatched/already-granted — see pendingSeatClaim's own doc comment
    pendingSeatClaim = nil
    vehicleEntryInProgress = false
end)

--- Releases the K9 from its vehicle seat and clears vehicleState.
--- No-op if not currently in a vehicle. Deliberately NOT gated behind
--- CanShowK9UI() — a K9 whose certification lapses mid-ride must always
--- be able to get out; this mirrors the same "never leave a player stuck"
--- principle DEVELOPER_REFERENCE.md §9 item 3b establishes as a hard
--- requirement for leash detach, applied here by extension since exiting
--- your own vehicle seat isn't itself a security-relevant capability grant.
--- Not spelled out verbatim in DEVELOPER_REFERENCE.md — a deliberate
--- client-logic judgment call, flagged here rather than made silently.
---
--- vehicleState is cleared IMMEDIATELY, synchronously, before anything
--- below runs — unlike the old attach-based model, this is now always safe
--- to do unconditionally up front: the ped is either genuinely,
--- game-recognized seated (in which case the graceful exit below, or the
--- player's own ordinary "exit vehicle" control, is all that's left to
--- finish) or already out by ordinary means (nothing left to release at
--- all). Either way, this file's own bookkeeping should stop claiming the
--- ride is active the instant the player asks to end it, not only once an
--- animation finishes playing.
--- @param notifyLocaleKey string? -- defaults to 'vehicle.released'. Mirrors
--- client/kennel.lua's ReleaseKennelRest(notifyLocaleKey) shape, so a
--- caller with a more specific reason (a forced exit on access loss, say)
--- can say so instead of firing a second, contradicting notification.
function ExitK9Vehicle(notifyLocaleKey)
    -- Default resolved HERE, into the parameter itself, rather than inline
    -- at the locale() call below. tests/localecallsites_spec.lua resolves a
    -- locale() argument that is a bare function parameter by tracing this
    -- file's own call sites; an `x or 'literal'` expression at the call is
    -- opaque to it and would have to be allowlisted as unresolvable
    -- instead. Same shape as client/kennel.lua's ReleaseKennelRest.
    notifyLocaleKey = notifyLocaleKey or 'vehicle.released'
    if not IsInK9Vehicle() then return end

    local ped = PlayerPedId()
    vehicleState = nil

    if not IsPedInAnyVehicle(ped, false) then
        -- Already out — through the ped's own ordinary "exit vehicle"
        -- control, which just works now that this is a real seat, unlike
        -- the old attach model. Nothing left to do.
        return
    end

    -- Graceful path: normal exit animation, door opens (flag 0 — "normal
    -- exit and closes door," per TASK_LEAVE_VEHICLE's own natives.json flag
    -- documentation).
    local vehicle = CurrentVehiclePedIsIn(ped)
    if vehicle then
        TaskLeaveVehicle(ped, vehicle, 0)
    end

    -- Bulletproof fallback (owner's own requirement): TASK_LEAVE_VEHICLE is
    -- an animated task, not an instant guarantee — a jammed door, a moving
    -- vehicle, or any other stall could leave it never actually completing.
    -- This one-shot thread (not a persistent loop — it runs at most once,
    -- checks once every 250ms, and always terminates within
    -- EXIT_STALL_FALLBACK_MS either by seeing the ped already out or by
    -- forcing it) tops up with ForceLeaveVehicle()'s hard path if the
    -- graceful one hasn't finished in time.
    CreateThread(function()
        local waited = 0
        while waited < EXIT_STALL_FALLBACK_MS do
            Wait(250)
            waited = waited + 250
            if not DoesEntityExist(ped) or not IsPedInAnyVehicle(ped, false) then return end
        end
        ForceLeaveVehicle(ped)
    end)

    lib.notify({ title = locale('common.notify_title'), description = locale(notifyLocaleKey), type = 'success' })
end

--- Server-initiated forced exit -- the client half of
--- server/vehicle.lua's RegisterBodyClaimReleaser('vehicle_seat', ...),
--- which fires when server/certifications/'s EndK9AccessForCitizenId
--- revokes this player's K9 access while they still hold a seat claim.
---
--- WHY THE SERVER CANNOT JUST FORGET THEM. Clearing the seat row without
--- this event would let a second citizenid be granted the exact seat this
--- player is visibly still sitting in. The registry clear and this event
--- are deliberately inseparable -- see server/bodyclaims.lua's
--- ForceReleaseBodyClaimForCitizenId header.
---
--- GATE THE STOP, NEVER THE START: no feature flag, no HasK9Access, no
--- per-person feature control, no cooldown -- getting out is never gated,
--- and the caller has ALREADY revoked this player's access, so any such
--- check would be false exactly when it matters. ExitK9Vehicle's own
--- IsInK9Vehicle() early return makes a duplicate or late event a harmless
--- no-op, and its stall fallback means a jammed door still cannot strand
--- anyone.
--- ASYMMETRY WITH client/kennel.lua's OWN forceExitKennelRest, deliberate
--- and safe: that one is registered OUTSIDE its file's feature gate,
--- because client/kennel.lua keeps loading past the gate and its exit paths
--- must survive an operator toggling DeployableKennel off mid-session. THIS
--- file returns outright at its own gate (see the early return near the
--- top), so when Config.Features.VehicleEntryExit is false AT LOAD nothing
--- in here exists at all -- including every path that could have seated a
--- K9 or claimed a seat in the first place. A client that never loaded the
--- vehicle system cannot be holding a seat, so there is nothing for an
--- always-on handler to release. A client that loaded WITH the feature on
--- and saw it toggled off later has already registered this handler, and
--- keeps it. Either way the release path is reachable exactly when a
--- release is possible.
RegisterNetEvent('john-k9:client:forceExitVehicleSeat', function(_reason)
    -- SOURCE-ORIGIN GUARD, matching every other server->client handler in
    -- this file (see client/combat.lua's own header block for the full
    -- writeup). Added after this handler shipped without one: the effect
    -- of a forged local trigger is self-only and harmless today (you can
    -- already leave voluntarily), but this resource treats the guard as
    -- mandatory on EVERY server->client event precisely so nobody has to
    -- re-derive that per-event judgement -- and so a later change that
    -- gives this event a meaningful payload cannot quietly become
    -- forgeable.
    if source ~= 65535 then return end
    ExitK9Vehicle('vehicle.exit_access_revoked')
end)

-- ======================================================================
-- CHAT COMMAND -- Enter/Exit K9 Vehicle (menu-parity pass: "chat commands,
-- 3rd eye, and radial menus" -- every feature reachable from all three).
-- Before this pass, this mechanic had the "Load Into Vehicle" ox_target
-- option AND client/radial.lua's own 'k9_vehicle' item, but no chat command
-- at all.
--
-- SAME CONTEXTUAL-DISPATCH SHAPE AS client/radial.lua's own 'k9_vehicle'
-- item AND client/tablet.lua's FEATURE_TRIGGERS.VehicleEntryExit (read both
-- before changing this) -- ONE command: IsInK9Vehicle() resolved FIRST,
-- UNGATED, before ever touching HasK9Access(). ExitK9Vehicle() itself is
-- deliberately never gated (see its own doc comment: "a K9 whose
-- certification lapses mid-ride must always be able to get out") -- this is
-- the exact ordering mistake this resource already shipped once in a
-- wrapper just like this one (client/radial.lua's own "ORDERING FIX, THIS
-- PASS" note), so Exit is checked first here on purpose, not as an
-- afterthought. The Enter branch below matches client/tablet.lua's own
-- VehicleEntryExit trigger (same 'combat.no_access' reason). Reaches the
-- SAME two resource-globals (ExitK9Vehicle()/EnterNearestK9Vehicle())
-- either way -- neither is reimplemented, and EnterNearestK9Vehicle()
-- performs its own real HasK9Access() gate internally regardless of this
-- pre-check.
-- ======================================================================
RegisterCommand('k9vehicle', function()
    if IsInK9Vehicle() then
        ExitK9Vehicle()
        return
    end

    if not HasK9Access() then
        DenyK9UIAccess('combat.no_access')
        return
    end

    EnterNearestK9Vehicle()
end, false)

-- Resource-restart safety net (adapted for real seating): vehicleState is
-- a plain Lua local, so it resets to nil on `restart john-k9`, but a
-- ped SET_PED_INTO_VEHICLE'd into a real seat does NOT get magically
-- ejected just because the script that seated it unloads — the seat
-- assignment is engine/entity state, not script state. Without this
-- handler, restarting this resource mid-ride would leave the new script
-- instance booting with vehicleState = nil (so IsInK9Vehicle() reports
-- false and ExitK9Vehicle() immediately no-ops) while the ped is still
-- actually sitting in the vehicle.
--
-- NEVER GATE A TERMINATION PATH: this handler does not check
-- Config.Features.VehicleEntryExit, CanShowK9UI(), or anything else that
-- could suppress it — only whether there's an active ride to release at
-- all (`if not vehicleState then return end`), per this file's own
-- top-level-gate header section's proof that a fresh instance booting with
-- the flag off can never have vehicleState set in the first place.
--
-- IMPORTANT — this is a strictly SMALLER blast radius than the old
-- attach-based version needed: because SET_PED_INTO_VEHICLE makes this a
-- REAL seat, a player whose restart happens to land in the split-second
-- window between vehicleEntryInProgress being set and vehicleState actually
-- being written (see EnterNearestK9Vehicle()'s deferred thread, which this
-- restart necessarily kills along with every other thread this resource
-- owns) is NOT stranded either way: if SET_PED_INTO_VEHICLE hadn't run yet,
-- they're just standing normally next to the vehicle (never frozen,
-- attached, invisible, or collisionless at any point in this file's new
-- design); if it had already run, they're a genuine, game-recognized
-- vehicle occupant who can already use the ordinary "exit vehicle" control
-- with no help from this script at all. The one cosmetic residue possible
-- in that exact window is a door left open with nobody having climbed in —
-- self-correcting on the next entry/exit through this file, and never a
-- player-blocking condition.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- SEAT-RACE FIX — a resource restart does not disconnect the player, so
    -- server/vehicle.lua's own playerDropped cleanup never fires for this
    -- case; without this, any claim this client currently holds (waiting on
    -- a response, or already granted and mid door/seat sequence) would sit
    -- reserved for the remainder of its own server-side TTL for no reason.
    -- Best-effort and unconditional, same posture as every other release
    -- call in this file — never gated on anything, per this file's own
    -- "never gate a termination path" doctrine.
    if pendingSeatClaim then
        TriggerServerEvent('john-k9:server:releaseVehicleSeatClaim', pendingSeatClaim.vehicleNetId, pendingSeatClaim.seatIndex)
        pendingSeatClaim = nil
    end

    if not vehicleState then return end

    ForceLeaveVehicle(PlayerPedId())
    vehicleState = nil
end)

-- Vehicle-lifecycle watchdog (substantially simplified from an earlier
-- version -- see below for why the old streaming-hiccup debounce no
-- longer applies to this file's primary detection). Two things this
-- thread exists to catch that no event tells this file about:
--   1. OWN-DEATH RELEASE (the softlock this branch exists to close): the
--      standard FiveM respawn flow REUSES the same ped handle rather than
--      allocating a new one (client/combat.lua's own repeatedly-verified
--      finding, its MaintenanceTick() function's death branches), so a K9
--      that dies mid-ride needs an explicit release or it could respawn
--      still nominally "in" the vehicle's seat with no self-service
--      recovery (no keybind for this, and the ox_target "Release From
--      Vehicle" option below requires hovering the vehicle, awkward at
--      best while dead). Reuses ForceLeaveVehicle() (whose own DEAD branch
--      is exactly built for this) rather than a separate dead-ped code
--      path.
--   2. VEHICLE-LOST NOTIFICATION: with real seating, the game engine itself
--      already force-ejects any occupant when their vehicle is deleted —
--      unlike the old attach-based ped, which had no such protection and
--      needed this file to notice and self-release. What's left to detect
--      here is much narrower: purely WHETHER TO TELL THE PLAYER something
--      happened to the vehicle, not whether to release them (they're
--      already safely out by the time this runs, either way).
--
-- SIMPLIFICATION FROM THE OLD VERSION, STATED HONESTLY: the previous
-- watchdog needed a missStreak/consecutive-misses debounce because its
-- PRIMARY detection signal was resolving the tracked vehicle by network id
-- (ResolveNetworkEntity), which can read nil for a vehicle that's merely
-- not currently streamed in to this client, not only for one that's
-- actually gone — a single miss was not reliable proof of anything. This
-- version's primary detection signal is IS_PED_IN_ANY_VEHICLE on THIS
-- CLIENT'S OWN local ped, which is always immediately, reliably available
-- (never subject to streaming) — so no debounce is needed for the
-- release decision itself. The vehicle-resolve read below is used ONLY to
-- decide which of two equally-harmless notification strings to show
-- (cosmetic wording, not a release-gating condition) — a streaming
-- false-negative there means, at worst, the player is told "lost the
-- vehicle" when they actually got out some other way, never a stranding
-- risk, so it is not worth re-adding the debounce complexity purely for
-- notification-copy accuracy.
--
-- One persistent thread for the resource's whole lifetime, matching
-- client/movement.lua's leash pull-back thread's own established
-- idle/active dual-interval convention, rather than spawning a new thread
-- per ride — sleeps at a long interval whenever no ride is active, so this
-- costs nothing on the ~0.01ms resmon idle benchmark while unused.
local VEHICLE_WATCHDOG_IDLE_MS = 2000
local VEHICLE_WATCHDOG_ACTIVE_MS = 1000

CreateThread(function()
    while true do
        local sleepMs = VEHICLE_WATCHDOG_IDLE_MS

        if vehicleState then
            sleepMs = VEHICLE_WATCHDOG_ACTIVE_MS
            local ped = PlayerPedId()

            if DoesEntityExist(ped) and IsEntityDead(ped) then
                -- OWN-DEATH RELEASE — see this thread's own header comment
                -- above. Checked BEFORE the "still seated?" branch below on
                -- purpose: death must release regardless of whether the ped
                -- is still nominally in the vehicle's seat.
                ForceLeaveVehicle(ped)
                vehicleState = nil
                lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.released_on_death'), type = 'error' })
            elseif not IsPedInAnyVehicle(ped, false) then
                -- No longer seated in ANY vehicle -- either the player used
                -- their own ordinary "exit vehicle" control (works unaided
                -- now that this is a real seat), or the vehicle was deleted
                -- and the engine's own occupant-eject already dropped them
                -- somewhere safe. Nothing left to release either way; only
                -- decide whether it's worth telling them the vehicle itself
                -- is the reason.
                local vehicleStillThere = ResolveVehicleFromState() ~= nil
                vehicleState = nil
                if not vehicleStillThere then
                    lib.notify({ title = locale('common.notify_title'), description = locale('vehicle.vehicle_lost'), type = 'error' })
                end
            end
            -- else: still genuinely seated -- nothing to do this pass.
        end

        Wait(sleepMs)
    end
end)

-- Register the ox_target vehicle options for every model in
-- Config.K9Vehicles, labeled contextually ("Load Into Vehicle" /
-- "Release From Vehicle" via two separate canInteract predicates rather
-- than one dynamic label, since ox_lib/ox_target options don't have a
-- documented live "recompute this label" hook this session verified).
-- The enter option's canInteract uses CanShowK9UI() (not just
-- IsOwnModelK9()) — this is EXACTLY the "hot call site" client/main.lua's
-- header names as the reason HasK9Access() has a short TTL cache, since
-- canInteract can run several times a second while hovering.
-- DISCLOSED, LEFT DELIBERATELY AS-IS THIS PASS (permission audit follow-up):
-- EnterNearestK9Vehicle() itself was widened to HasK9Access() alone (see its
-- own doc comment above) to match server/vehicle.lua's requestVehicleSeatClaim
-- gate, but this canInteract predicate below was NOT — narrowing this file's
-- change to only the function named in that audit rather than sweeping every
-- CanShowK9UI() call site in the file. Net effect: a High Command/
-- autoAccessGrade-bypass holder (HasK9Access() true, CanShowK9UI() false)
-- will not see the "Load Into Vehicle" hover option, but reaches the same
-- action end-to-end via client/radial.lua's k9_vehicle item regardless,
-- which routes through HasK9Access() already. A real, narrower, same-shape
-- gap as the one this pass closed — flagged here rather than silently
-- widened without re-confirming this predicate's own hot-call-site
-- performance characteristics stay correct under the change.
-- Gate visibility with Config.Features.VehicleEntryExit AND the access
-- check above — this is a DISPLAY optimization per DEVELOPER_REFERENCE.md
-- §3/§4.5, not the security boundary. UPDATED (SEAT-RACE FIX pass): this
-- action now DOES have a real server round trip
-- (requestVehicleSeatClaim/vehicleSeatClaimGranted/Denied, above) that
-- independently re-verifies HasK9Access and the vehicle's model
-- server-side — the "if that turns out to be the wrong call, the fix is
-- adding a thin gated server event here" this comment used to end on has
-- now happened. What's still true, unchanged: canInteract itself remains
-- pure UX (hides the option rather than letting onSelect show a rejection),
-- and EnterNearestK9Vehicle() re-checks everything canInteract already
-- checked regardless of what canInteract decided — the real boundary is,
-- and stays, server-side.
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call -- both canInteract/onSelect pairs below
-- are unchanged (still authored against ox_target's own convention), so an
-- operator running a different supported target script gets both options
-- translated automatically instead of losing them outright.
--
-- LIFECYCLE FIX: extracted into a named function, sole call site the
-- AddEventHandler('onResourceStart', ...) below, so both options come back
-- after a bare restart of whatever resource actually backs the 'target'
-- system, not just after this resource's own restart -- every supported
-- target script keeps its own registry in a plain file-local Lua table
-- inside its own client chunk, reloaded empty on THAT resource's own
-- restart with nothing else prompting a re-add. Mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. DUPLICATE-VS-REPLACE: both
-- options below always set `name`, and every adapter's own registration
-- primitive dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running this
-- never duplicates either entry.
local function RegisterVehicleOxTargetOptions()
    K9Compat.Get('target').AddGlobalVehicle({
        {
            name = 'john-k9:enterVehicle',
            icon = 'fas fa-dog',
            label = locale('vehicle.target_enter_label'),
            distance = Config.VehicleInteractMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.VehicleEntryExit then return false end
                if vehicleEntryInProgress or IsInK9Vehicle() then return false end
                -- DISPLAY-OPTIMIZATION MIRROR of EnterNearestK9Vehicle()'s own
                -- load-bearing mutual guard above — hides the option instead of
                -- letting onSelect show a rejection notify for the common case.
                -- Not the real boundary (that's inside EnterNearestK9Vehicle()
                -- itself, which re-checks this regardless of what canInteract
                -- decided), same "canInteract is a UX convenience" posture this
                -- file already documents for every other predicate here.
                if type(IsDragEngaged) == 'function' and IsDragEngaged() then return false end
                if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then return false end
                if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then return false end
                -- DISPLAY-OPTIMIZATION MIRROR of EnterNearestK9Vehicle()'s own
                -- kennel-rest mutual guard above — see its own doc comment.
                if type(IsRestingInKennel) == 'function' and IsRestingInKennel() then return false end
                if not K9VehicleHashes[GetEntityModel(entity)] then return false end
                -- DISPLAY-OPTIMIZATION MIRROR of EnterNearestK9Vehicle()'s own
                -- FindBestK9Seat() refusal (this resource's own "never show an
                -- option that will just refuse" convention): hide the option
                -- entirely once every non-driver seat is genuinely occupied,
                -- rather than letting onSelect show vehicle.no_seat_available
                -- for the common "every seat's full" case. Not the real
                -- boundary — EnterNearestK9Vehicle() re-runs FindBestK9Seat()
                -- itself regardless of what canInteract decided (a seat can
                -- fill in the moment between this hover check and the click),
                -- same posture as every other predicate here.
                if not FindBestK9Seat(entity) then return false end
                return CanShowK9UI()
            end,
            onSelect = function()
                EnterNearestK9Vehicle()
            end,
        },
        {
            name = 'john-k9:exitVehicle',
            icon = 'fas fa-dog',
            label = locale('vehicle.target_exit_label'),
            distance = Config.VehicleInteractMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.VehicleEntryExit then return false end
                return IsInK9Vehicle() and ResolveVehicleFromState() == entity
            end,
            onSelect = function()
                ExitK9Vehicle()
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterVehicleOxTargetOptions()
        return
    end

    -- This file never names a third-party target resource directly (see
    -- shared/compat/target.lua) -- whichever one actually backs the
    -- 'target' system is asked of K9Compat itself. Redetect() is forced
    -- here rather than relying on shared/compat/core.lua's own
    -- onResourceStart/onClientResourceStart redetect hook having already
    -- run for this SAME event, so this check is correct regardless of
    -- relative handler-registration order between the two files.
    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterVehicleOxTargetOptions()
    end
end)

-- ======================================================================
-- RIDING: THE NORMAL ENTER KEY, AND NEVER THE DRIVER'S SEAT
-- (owner-directed, this pass, and stated three times in escalating
-- specificity: "make it where its part of the normal getting in a
-- vehicle", then "Not a 3rd eye function a normal get in vehicle", then
-- "disable it where it trys to get in a driver seat of a vehicle it wont
-- allow it or attempt to get in a driver seat... i want it to be fluid".)
--
-- WHAT WAS WRONG. Loading a K9 into a car was reachable only through this
-- resource's own surfaces -- a command, a radial item, a target option.
-- Pressing the key every other player in the server presses to get into a
-- car did one of two unhelpful things: nothing, or the ordinary engine
-- behaviour, which happily walks a dog round to the driver's door and puts
-- it behind the wheel. Neither is what anyone expects, and the second is
-- the specific thing the owner asked to be made impossible.
--
-- WHAT THIS DOES. Two independent jobs in one thread, because they share
-- the same "am I a K9 right now" question and splitting them would mean
-- asking it twice per tick for no gain:
--
--   1. CAPTURE THE ENTER KEY, but only in the moment it matters. The
--      game's own enter action is disabled ONLY while a K9 is on foot AND
--      genuinely within reach of an eligible vehicle. In that window the
--      press routes into this file's own seating flow, which picks a rear
--      seat first and never seat -1. Outside that window the control is
--      left completely alone -- being on foot is otherwise unchanged, and
--      a K9 nowhere near a car has a totally ordinary keyboard.
--
--   2. EVICT FROM THE DRIVER'S SEAT. The seat picker already never OFFERS
--      seat -1, but that only governs seats this resource assigns. A dog
--      can still arrive behind the wheel by routes this file never sees:
--      an admin teleport, another resource seating them, or simply
--      pressing enter during the window before this resource finished
--      loading. This catches those and puts the dog out.
--
-- WHY A POLLING THREAD AND NOT A PER-FRAME ONE. It idles at 500ms and only
-- drops to per-frame while a K9 is actually standing next to an eligible
-- vehicle -- the one moment the key could be pressed. DisableControlAction
-- has to run every frame to hold, so there is no way to capture a control
-- from a slow loop, but there is also no reason to pay that cost while the
-- player is nowhere near a car. This mirrors the dual-interval shape this
-- file's own watchdog and client/combat.lua's maintenance thread already
-- use.
--
-- GATE THE START OF A THING, NEVER THE STOP: this thread only ever ADDS a
-- way in and REMOVES a wrong seat. It never touches any exit path -- a K9
-- in a passenger seat still leaves by every route it already had, and the
-- driver-seat eviction is itself an exit, so it is deliberately
-- unconditional rather than gated on access.
-- ======================================================================
CreateThread(function()
    local IDLE_MS = 500
    local ACTIVE_MS = 0

    while true do
        local sleep = IDLE_MS
        local cfg = type(Config.K9VehicleRide) == 'table' and Config.K9VehicleRide or {}

        -- HasK9Access() alone, matching this file's own EnterNearestK9Vehicle
        -- gate exactly (widened there in the permission audit for the same
        -- reason). Soft-guarded: client/main.lua defines it unconditionally,
        -- but this file keeps the convention so it can load standalone.
        local isK9 = type(HasK9Access) == 'function' and HasK9Access()

        if isK9 then
            local ped = PlayerPedId()

            -- (2) DRIVER-SEAT EVICTION. Checked first and unconditionally:
            -- this is a correction, not a capability, and a dog behind the
            -- wheel must not survive a single extra tick because some other
            -- condition below happened to be false.
            if cfg.preventDriverSeat ~= false and DoesEntityExist(ped) and not IsEntityDead(ped) then
                local occupied = GetVehiclePedIsIn(ped, false)
                if occupied ~= 0 and GetPedInVehicleSeat(occupied, -1) == ped then
                    -- TaskLeaveVehicle rather than a hard reposition: it is
                    -- the same native this file's own ForceLeaveVehicle
                    -- already uses for a live ped, and it plays the real
                    -- get-out animation instead of teleporting the dog into
                    -- the road, which is the "fluid" the owner asked for.
                    TaskLeaveVehicle(ped, occupied, 0)
                    -- Local state is cleared too, if this resource happened
                    -- to be the one tracking that seat -- otherwise a stale
                    -- vehicleState would keep claiming the dog is riding.
                    if vehicleState then vehicleState = nil end
                    lib.notify({
                        title = locale('common.notify_title'),
                        description = locale('vehicle.no_driver_seat'),
                        type = 'error',
                    })
                    sleep = IDLE_MS
                end
            end

            -- (1) ENTER-KEY CAPTURE. Only while on foot and genuinely in
            -- reach -- FindNearestK9Vehicle applies this resource's own
            -- eligibility and distance rules, so the control is never taken
            -- for a vehicle the dog could not ride in anyway.
            if cfg.captureNativeEnterKey ~= false and not IsPedInAnyVehicle(ped, false) then
                local nearby = FindNearestK9Vehicle(Config.VehicleInteractMeters)
                if nearby then
                    sleep = ACTIVE_MS
                    local control = type(cfg.enterControl) == 'number' and cfg.enterControl or 23
                    DisableControlAction(0, control, true)
                    if IsDisabledControlJustPressed(0, control) then
                        EnterNearestK9Vehicle()
                    end
                end
            end
        end

        Wait(sleep)
    end
end)
