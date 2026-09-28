--[[
    qbx_k9unit/client/kennel.lua

    Phase 5 R&D scaffold (coder-architect structural pass). Owns the
    DeployableKennel feature's client-side placement mechanics and the
    "Pick Up Kennel"/"Rest in Kennel"/"Exit Kennel" ox_target entry points.
    See server/kennel.lua's header for the full event contract and the
    "server computes the placement coords" design rationale — this file
    only ever executes an instruction the server already validated, it
    never decides WHERE a kennel goes, WHO may attach to it, or whether an
    attach is authorized.

    NEW FILE (paired with server/kennel.lua), not folded into
    client/vehicle.lua or client/main.lua — same "one responsibility per
    file" convention as every other file pairing in this resource (see
    server/kennel.lua's header for the fuller version of this reasoning).

    ======================================================================
    K9-CAN-RIDE-ALONG PASS — CRITICAL SAFETY REDESIGN (this pass). Read
    server/kennel.lua's own header CRITICAL SAFETY / architecture section
    FIRST — this file is the client-side half of that same redesign, and
    repeats none of that reasoning here beyond what's specific to this
    file's own native calls.

    THE OCCUPANT IS ALWAYS A REAL, CURRENTLY-CONNECTED PLAYER'S OWN PED —
    owner's own explicit instruction, this pass: "Ensure its the k9 player
    that gets put in the cage not a spawned in dog." CONFIRMED: this file
    never calls CreatePed, anywhere. The "occupant" in every comment below
    means PlayerPedId() on THAT PLAYER'S OWN CLIENT (this file, running on
    their machine, reacting to their own 'qbx_k9unit:client:enterKennelConfirmed'),
    never an NPC and never a ped driven remotely from the handler's client.
    That occupant has their own live client throughout — they can move the
    camera, open the tablet, press keys, and disconnect, exactly like any
    other connected player, at every moment they are "resting" — nothing
    below ever assumes otherwise (see ReleaseKennelRest's own doc comment
    for the exit path this guarantees regardless of any of that).

    NO CROSS-PED DRIVING / NETWORK OWNERSHIP (owner's own explicit
    instruction, this pass): "Positioning is done to that player's own ped,
    on their own client... Do not try to drive another player's ped from
    the handler's client... Attaching one to the other crosses that
    boundary. client/combat.lua has extensive verified
    NetworkRequestControlOfEntity handling for exactly this situation; read
    it rather than inventing something." Read in full this pass (see that
    file's own "NETWORK OWNERSHIP OF THE TARGET PED" header section) rather
    than assumed. THIS FILE reuses that EXACT, already-verified pattern —
    a best-effort, fire-and-forget NetworkRequestControlOfEntity call on
    whichever entity is about to become the CHILD of an AttachEntityToEntity
    call THIS client does not already control, immediately before the
    attach itself, never a blocking wait (that file's own header explains
    why a wait loop would stall its one shared maintenance thread; this
    file's own maintenance thread, further below, would have the identical
    problem) — and never proceeds by attaching an entity this client does
    not itself own or have just requested control of onto ANOTHER PLAYER's
    ped. Concretely, two independent attach relationships exist, each
    maintained ONLY by whichever client is responsible for that
    relationship's own CHILD side:
      1. An occupant's OWN client attaches its OWN ped (the CHILD, always
         already self-owned — no control request needed, mirroring
         client/vehicle.lua's own EnterNearestK9Vehicle(), which attaches
         the player's own ped to a vehicle it does NOT necessarily own with
         zero NetworkRequestControlOfEntity calls anywhere in that file) to
         the kennel object (the PARENT, owned by whoever, irrelevant to this
         relationship).
      2. A carrying HANDLER's OWN client attaches the kennel OBJECT (the
         CHILD — NOT self-owned in general, since some other client
         created/last-touched it, exactly client/combat.lua's PropDragging
         scenario) to their OWN ped (the PARENT, always self-owned) —
         THIS is the relationship that needs NetworkRequestControlOfEntity,
         called on the kennel object, before every (re-)attach.
    Neither client ever attaches, detaches, or repositions the OTHER
    party's ped. The two relationships compose automatically into "the
    occupant moves with the handler" via the game engine's own transitive
    attachment hierarchy (a grandchild follows its parent's parent) — no
    code anywhere makes the occupant's ped and the handler's ped aware of
    each other at all.

    WHY A ONE-SHOT ATTACH (PLUS A COARSE, ~1s WATCHDOG RE-ASSERTION), NOT A
    PER-FRAME Wait(0) REASSERTION LOOP LIKE client/combat.lua's OWN
    PropDragging: that file's own header is explicit about WHY it reasserts
    every single frame — "a hostile TARGET can [detach] itself at any
    moment... the ONLY defense... is re-asserting... EVERY TICK." That
    reasoning is about an ADVERSARIAL party actively trying to break free.
    Neither relationship here has one: an occupant voluntarily rests inside
    a kennel it chose to enter, and a kennel object does not "fight" being
    carried. client/vehicle.lua's own EnterNearestK9Vehicle() — attaching a
    player's own, willing ped to a vehicle it does not own, the more
    directly analogous precedent for relationship 1 above — does a single
    ONE-SHOT AttachEntityToEntity call with NO per-frame reassertion loop
    at all, relying only on a coarse watchdog thread for backstop safety
    checks (has the vehicle despawned, has the rider died). This file
    follows THAT precedent for both relationships: attach once at the
    moment of entry/pickup, then let a single coarse (idle 2000ms / active
    1000ms, mirroring client/vehicle.lua's own dual-interval shape) shared
    watchdog thread (near the bottom of this file) handle: (a) safety
    backstops for BOTH relationships (own-death, entity-no-longer-
    resolvable with a debounced miss-streak, an occupant wandering out of
    range) that unconditionally self-release, and (b) — as a defensive
    middle ground for the ONE relationship that genuinely does cross an
    ownership boundary (the carry attach, relationship 2 above) — a
    periodic NetworkRequestControlOfEntity + AttachEntityToEntity
    re-assertion at that same ~1s cadence, cheap insurance against a rare
    silent detach without paying combat.lua's own Wait(0) cost for a
    feature with no adversarial party to defend against.

    ======================================================================
    EVENT/CALLBACK CONTRACT (client side; see server/kennel.lua for the
    full server-side version):
    Server events this file triggers (client->server):
      'qbx_k9unit:server:requestDeployKennel' ()
      'qbx_k9unit:server:confirmKennelPlaced' (netId: number)
      'qbx_k9unit:server:cancelKennelPlacement' ()
      'qbx_k9unit:server:requestPickupKennel' (netId: number)
      'qbx_k9unit:server:requestPutDownKennel' () -- NEW, this pass
      'qbx_k9unit:server:requestEnterKennel' (netId: number) -- NEW, this pass
      'qbx_k9unit:server:requestExitKennel' () -- NEW, this pass
    Client events this file registers (server->client):
      'qbx_k9unit:client:deployKennelAt' (x: number, y: number, z: number)
      'qbx_k9unit:client:removeKennel' (netId: number)
      'qbx_k9unit:client:pickupKennelConfirmed' (netId: number) -- NEW
      'qbx_k9unit:client:putDownKennelAt' (netId, x, y, z) -- NEW
      'qbx_k9unit:client:enterKennelConfirmed' (netId: number) -- NEW
      'qbx_k9unit:client:kennelCarrierLost' (netId: number) -- NEW
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes FOUR resource-globals (no `local`):
        RequestDeployKennel()
            Runs the command's own gating (feature flag, HasK9Access(),
            "already have one deployed" local check) and sends the deploy
            request — UNLESS this client is CURRENTLY CARRYING a kennel, in
            which case it means "put it back down instead" (see that
            function's own doc comment for why one entry point correctly
            serves both meanings, and why the carry branch is checked
            FIRST, ahead of even the feature-flag/HasK9Access() gates, the
            same "never gate an exit-adjacent action" doctrine
            client/vehicle.lua's own ExitK9Vehicle() already establishes).
            GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() --
            permission audit finding, this pass; see that function's own
            "GATE WIDENED" doc comment for the full reasoning.
            Exposed globally, not kept as a command-local closure, so a
            future radial item can call it directly — client/radial.lua's
            EXISTING "Deploy Kennel" item already does, unmodified, and
            gains the put-down behavior for free.
        IsRestingInKennel() -> boolean
            Whether THIS client's own ped is currently attached to a
            kennel as an occupant. WIRED (verified by reading
            client/appearance.lua directly): that file's own K9 model-swap
            refusal list (IsCurrentlyEngaged()) already checked the
            equivalently-shaped IsInK9Vehicle()/IsPropAttachmentEngaged() —
            this is the SAME shape, and client/appearance.lua has since
            added its own call to this function too, so a dog resting in a
            kennel now also refuses a mid-rest model swap.
        IsCarryingKennel() -> boolean
            Whether THIS client is currently carrying (has attached to
            its own hands) a kennel object.
        ExitKennelRest() -- THIS PASS (trap-hunt fix: see "CORRECTED" note
            on the shared watchdog thread's own former WANDER-OFF EXIT
            comment, further down, for the finding this responds to). The
            occupant's own ALWAYS-AVAILABLE exit entry point, exposed
            globally for the identical reason client/vehicle.lua's own
            ExitK9Vehicle() and client/movement.lua's own DetachLeash() are
            resource-globals. Its player-facing callers are the third-eye
            "Exit Kennel" option and the K9 menu's Kennel button (owner's
            choice -- the O key and the exit commands were removed); the
            server's forced exit reaches it too -- never a
            second, forked copy of the release logic (this resource's own
            "SAME FUNCTION, NEVER A FORKED ENTRY POINT" doctrine,
            client/keybinds.lua's own header cites the historical
            ScratchAtDoor/NudgeDoor incident this avoids). The pre-existing
            "Exit Kennel" ox_target option below now also calls this
            instead of ReleaseKennelRest() directly, for the same reason.
            A thin, deliberately gate-free wrapper over ReleaseKennelRest()
            -- see that function's own doc comment for why it is already
            unconditional (never gated on Config.Features.DeployableKennel,
            HasK9Access, certification, or any cooldown); this function
            must never add a gate of its own, on purpose.
    - THIS FILE calls client/main.lua's CanShowK9UI() and DenyK9UIAccess()
      before every SELF-ADMINISTERED K9 action (RequestEnterOwnKennel(), the
      "Rest in Kennel"/"Exit Kennel" ox_target options) -- ANY PED (this
      resource's own established convention): this file never calls
      IsOwnModelK9() anywhere, confirmed by this file's own test suite —
      CanShowK9UI() alone already internally decouples role from model
      (Config.K9Appearance.requireK9ModelForRole), so a second, redundant
      model check here would wrongly hide the "Rest in Kennel" option from a
      K9-role holder on a non-dog body. This is CORRECT and left unchanged:
      server/kennel.lua's own requestEnterKennel handler (via
      ResolveK9PedForKennelRest) gates on the SAME "looks like a K9 model OR
      holds the K9 role, AND HasK9Access" shape, because resting IN a kennel
      as a K9 genuinely requires being one.
      HUMAN HANDLER actions (RequestDeployKennel()'s deploy branch, "Pick Up
      Kennel") are gated on the lighter HasK9Access() alone instead, NOT
      CanShowK9UI() -- placing or carrying a kennel does not require
      currently being a dog. RequestDeployKennel()'s own "GATE WIDENED" doc
      comment (permission audit finding, this pass) has the full reasoning
      for its half of this; "Pick Up Kennel"'s own fa-user-tie/HasK9Access()
      comment below is the pre-existing precedent it matches.
    - THIS FILE calls client/main.lua's ResolveNetworkEntity(netId)
      (DEVELOPER_REFERENCE.md item 2) everywhere an entity needs to be
      resolved from a netId — do not re-implement the
      NetworkDoesEntityExistWithNetworkId/NetworkGetEntityFromNetworkId/
      DoesEntityExist sequence here.
    - THIS FILE does NOT call client/propattachment.lua's AttachPropToOwnPed
      for the carry mechanic (a DELIBERATE DEVIATION from this pass's
      original brief, which named that helper as the thing to reuse for
      "make the pickup feel real" — recorded here rather than silently
      dropped): that helper always CreateObjects a brand NEW, separate
      prop, which is exactly incompatible with the owner's own subsequent,
      more specific correction that the SAME real object — with any
      occupant still attached to it — must be the one that ends up in the
      handler's hands. This file instead re-attaches the EXISTING,
      already-tracked kennel object directly (see the header architecture
      section above) — a small, dedicated AttachEntityToEntity call of its
      own, not a reimplementation of that helper's model-loading/CreateObject
      logic (there is no new model to load; the object already exists).
    - THIS FILE does NOT touch client/vehicle.lua's or
      client/movement.lua's state — kennels are a wholly independent
      mechanic.
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
-- Milliseconds to wait for RequestModel to actually finish loading before
-- giving up. RequestModel/HasModelLoaded is the standard vanilla polling
-- pattern (no ox_lib model-loading helper is used elsewhere in this
-- resource to reuse instead) — 5s is a generous ceiling for a single small
-- prop model on typical connections, matching the general "fail loudly
-- rather than hang forever" convention already applied elsewhere in this
-- resource (e.g. LEASH_REQUEST_TTL_MS, PendingKennelPlacements' own TTL in
-- server/kennel.lua).
local REQUEST_MODEL_TIMEOUT_MS = 5000

-- Recognized kennel prop model hashes (primary + fallback, config.lua's
-- Config.DeployableKennel) -- built once at file load, used by the
-- removeKennel handler's defense-in-depth model check and by
-- kennelCarrierLost below. Not the same table client/main.lua's
-- K9ModelHashes covers (that one is PED models; this is the kennel OBJECT
-- prop), so it is not a duplicate of an existing global.
local KennelPropModelHashes = {
    [GetHashKey(Config.DeployableKennel.propModel)] = true,
    [GetHashKey(Config.DeployableKennel.fallbackPropModel)] = true,
}

-- ======================================================================
-- REST POSE (THIS PASS -- owner-reported: "make sure the dog actually
-- shows up in the kennel").
--
-- THE BUG THIS CLOSES: 'qbx_k9unit:client:enterKennelConfirmed' below
-- positioned and AttachEntityToEntity'd the occupant's own ped into the
-- kennel WITHOUT ever clearing its running tasks first, and never posed it
-- afterwards. Both halves were visible:
--   1. NO TASK CLEAR. You always arrive at a kennel by WALKING to it, so
--      the ped is essentially always carrying a live locomotion task at
--      the moment the confirmation lands. Attaching does not cancel that
--      task -- it only re-parents the transform -- so the dog kept playing
--      its walk/run cycle while pinned in place: visibly running on the
--      spot inside the cage. Every other "tuck the K9 into something"
--      path in this resource already clears first (client/vehicle.lua's
--      ForceLeaveVehicle, client/combat.lua's PlayBiteHoldStance,
--      client/findalert.lua's PlayFindAlertSitPose, client/movement.lua's
--      K9Sit and ScratchAtDoor) -- the kennel was the one that did not.
--   2. NO POSE. Even with tasks cleared, the result is a dog standing
--      bolt upright inside a cage, which does not read as "resting in a
--      kennel" at all -- the exact thing the owner was looking for.
--
-- Scenario table COPIED VERBATIM (not re-derived, not re-guessed) from
-- client/movement.lua's K9_SIT_SCENARIO_BY_MODEL_HASH -- see that file's
-- own doc comment, immediately above its K9Sit() function, for the full
-- native-api-assistant verification writeup (two independently maintained
-- community scenario dumps, DioneB/GTAV-Scenarios and kibook/spooner's
-- scenarios.lua, agreeing exactly that "WORLD_DOG_SIT" is not a real
-- scenario and that the genuine per-breed names are
-- WORLD_DOG_SITTING_SHEPHERD / _ROTTWEILER / _RETRIEVER / _SMALL).
--
-- WHY A DISCLOSED DUPLICATE RATHER THAN CALLING K9Sit(): identical
-- reasoning to client/findalert.lua's own header "WHY THIS FILE DOES NOT
-- CALL K9Sit()" section -- K9Sit() opens with `if not CanShowK9UI() then
-- DenyK9UIAccess() return end`, and routing a purely COSMETIC pose through
-- that gate is this codebase's own one-layer-up trap: the occupant has
-- already been authorized by the server (server/kennel.lua granted the
-- occupancy claim and wrote KennelOccupants[citizenid] before this event
-- was ever sent), so a second client-side authorization check here could
-- only ever produce a false refusal -- a silently un-posed dog plus a
-- spurious "you cannot use K9 features right now" toast fired immediately
-- after the player's own "you settle into the kennel" success notice.
-- This is a pose, not a capability; it must not carry a gate.
-- If this table is ever promoted to a shared resource-global (removing
-- both this duplicate and findalert.lua's), it needs a .luacheckrc
-- `globals` entry and small edits in all three files.
local KENNEL_REST_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd   = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop       = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists
    a_c_husky      = 'WORLD_DOG_SITTING_RETRIEVER',  -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit
}) do
    KENNEL_REST_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local KENNEL_REST_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD' -- fallback if playing an unmapped/future Config.Peds model, same default K9Sit() uses

--- Poses an already-attached occupant so it visibly RESTS in the kennel
--- rather than standing in it. Called AFTER AttachEntityToEntity, never
--- before: the attach sets the ped's parent transform, and an in-place
--- scenario animates the ped without moving its root, so this order lets
--- the attachment keep governing WHERE the dog is while the scenario
--- governs WHAT IT LOOKS LIKE. Posing first and attaching second would
--- risk the scenario's own entry transition (a real ped genuinely steps
--- into a scenario) fighting an attach applied a frame later.
---
--- playEnterAnim = FALSE, deliberately different from every other
--- TaskStartScenarioInPlace call in this resource (all of which pass
--- `true`): those pose a free-standing ped, where the walk-into-position
--- transition is exactly what you want. This ped is already pinned inside
--- a cage, so an enter transition would render as the dog sliding around
--- against an attachment that will not let it actually move. Snapping
--- straight into the resting pose is the correct read here.
---
--- NOT GATED on anything -- see this section's header for why a cosmetic
--- pose must not carry an authorization check.
--- @param ped number
local function PlayKennelRestPose(ped)
    local scenarioName = KENNEL_REST_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or KENNEL_REST_DEFAULT_SCENARIO
    TaskStartScenarioInPlace(ped, scenarioName, 0, false)
end

-- Currently-active kennel THIS client deployed, if any (nil otherwise).
-- Local-only, never read from another file. This is a CLIENT-SIDE MIRROR
-- of server/kennel.lua's authoritative Kennels[citizenid] entry, not an
-- independent source of truth — it exists only so (a) this file's own
-- onResourceStop handler below knows what to clean up, and (b)
-- RequestDeployKennel() can give an immediate "you already have one"
-- notice for the common case without a network round trip. The server
-- independently re-validates the one-kennel-per-citizenid limit regardless
-- of what this local variable currently believes (see
-- server/kennel.lua's requestDeployKennel handler).
local myKennelNetId = nil

-- Currently-active "I am resting inside a kennel" state for THIS client's
-- OWN ped, if any (nil otherwise). THIS PASS. Local-only. See
-- ReleaseKennelRest's own doc comment for the unconditional, always-
-- available exit this state's every consumer is built around.
--- @type { kennelNetId: number } | nil
local restState = nil

-- Network id of the kennel object THIS client is currently carrying
-- (attached to its own hands), if any (nil otherwise). THIS PASS.
-- Deliberately a NETWORK ID, not a cached raw entity handle, for the exact
-- reason client/vehicle.lua's own vehicleState stores a netId instead of a
-- handle (a handle can go stale if the entity streams out and back in over
-- a long carry) -- see ResolveNetworkEntity's own re-resolve-on-every-use
-- contract, used everywhere below instead of caching the handle across
-- calls.
local carriedKennelNetId = nil

--- Requests `modelName`'s hash and blocks (via Wait, same convention as
--- every other polling loop in this resource) until it loads or
--- REQUEST_MODEL_TIMEOUT_MS elapses.
--- @param modelName string
--- @return number? modelHash — nil if the model hash is invalid, or never finished loading in time
local function LoadModelWithTimeout(modelName)
    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then
        return nil -- not even a recognized model hash on this client's installed game data — don't bother requesting it
    end

    RequestModel(modelHash)
    local waited = 0
    while not HasModelLoaded(modelHash) and waited < REQUEST_MODEL_TIMEOUT_MS do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        -- LEAK FIX: RequestModel above increments this model's streaming
        -- reference count; failing to load in time is a real exit path
        -- that must still release it.
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end
    return modelHash
end

--- @return boolean
function IsRestingInKennel()
    return restState ~= nil
end

--- @return boolean
function IsCarryingKennel()
    return carriedKennelNetId ~= nil
end

--- Re-resolves the kennel this client's own ped is currently attached to,
--- from its network id -- never trusts a cached handle to stay valid for
--- the whole rest (this resource's established
--- ResolveNetworkEntity-everywhere convention, mirroring
--- client/vehicle.lua's own ResolveVehicleFromState).
--- @return number? entity
local function ResolveKennelFromRestState()
    if not restState then return nil end
    return ResolveNetworkEntity(restState.kennelNetId)
end

--- Occupant's own, ALWAYS-AVAILABLE local release. See this file's header
--- CRITICAL SAFETY / architecture section. Detaches THIS client's own ped
--- from whatever it is currently attached to and restores collision,
--- REGARDLESS of Config.Features.DeployableKennel, HasK9Access, whether
--- the server can even be reached, or the kennel's own carried/deployed
--- state — DetachEntity never depends on its former parent still
--- existing, so this is safe to call unconditionally from every exit path
--- below (manual "Exit Kennel", wandering out of range, own death, the
--- kennel being lost/removed, this client's own resource stop). Runs its
--- own native cleanup FIRST, then fires the best-effort server bookkeeping
--- event — an occupant is guaranteed to be standing free, unfrozen,
--- visible, and collidable the instant this function's own native calls
--- return, whether or not 'qbx_k9unit:server:requestExitKennel' is ever
--- received, or has anything left to receive it at all.
---
--- THIS PASS (trap-hunt fix): this is now reached from FOUR places, not
--- one -- the pre-existing "Exit Kennel" ox_target option (via
--- ExitKennelRest()), the new k9exitkennel keybind/command
--- (client/keybinds.lua), the new "Exit Kennel" radial item
--- (client/radial.lua), and the shared watchdog thread's own automatic
--- backstops below (own-death, entity-lost, the desync-only wander-off
--- case). ox_target/keybind/radial all route through ExitKennelRest()
--- rather than calling this local function directly, so there is exactly
--- ONE forked-entry-point risk surface (ExitKennelRest() itself), not
--- three independent copies of "which locale key to notify with."
--- @param notifyLocaleKey string?
--- THE ONE COPY of the occupant's own native cleanup: detach, restore
--- collision, end the rest pose. Every exit path in this file runs exactly
--- this, and runs it by calling this function -- never by repeating the
--- three calls inline.
---
--- EXTRACTED AFTER A REAL MISS (trap-hunt finding, immediately after the
--- rest-pose fix landed): these three natives used to be hand-duplicated in
--- TWO places -- ReleaseKennelRest below and the onResourceStop handler
--- further down -- and when ClearPedTasksImmediately was added to end the
--- pose, it landed in only ONE of them. The commit that added it claimed
--- resource stop was covered; it was not. A K9 resting when an operator
--- restarted the resource was left frozen in the sitting scenario, playing
--- on the spot, until they happened to press a movement key. Not a hard
--- trap (they were genuinely detached and collidable, so they could walk
--- away), but visibly wrong, and wrong in exactly the case the fix said it
--- had covered.
---
--- The duplication was the cause, so the duplication is what is fixed here
--- rather than just the one missing line: a future change to what "release
--- an occupant" means now has one place to land, and cannot half-apply.
---
--- GATE THE START OF A THING, NEVER THE STOP: this function takes no
--- condition of its own beyond the entity existing. It never reads
--- Config.Features.DeployableKennel, HasK9Access, certification, a
--- cooldown, or the kennel's own door state, and it must never start --
--- DetachEntity does not depend on the former parent still existing, so
--- this is safe to call unconditionally from every exit path, including
--- ones where the kennel is already gone.
--- @param ped number
local function ReleaseOccupantNatives(ped)
    if not DoesEntityExist(ped) then return end
    DetachEntity(ped, true, false)
    SetEntityCollision(ped, true, true)
    -- Ends the rest pose. Without it the sitting scenario keeps running
    -- until the player supplies movement input -- and on the automatic
    -- paths (own-death, kennel lost, kennel removed, resource stop) there
    -- is no input coming, so the exit looks like it did nothing.
    ClearPedTasksImmediately(ped)
end

local function ReleaseKennelRest(notifyLocaleKey)
    if not restState then return end
    restState = nil

    ReleaseOccupantNatives(PlayerPedId())

    if notifyLocaleKey then
        lib.notify({ title = locale('common.notify_title'), description = locale(notifyLocaleKey), type = 'success' })
    end

    TriggerServerEvent('qbx_k9unit:server:requestExitKennel')
end

--- Occupant's own, ALWAYS-AVAILABLE exit entry point -- THIS PASS
--- (trap-hunt fix). Exposed globally (not kept as an ox_target-local
--- closure), mirroring client/vehicle.lua's own ExitK9Vehicle() and
--- client/movement.lua's own DetachLeash() being resource-globals for the
--- identical reason -- see this file's header "FILE-TO-FILE CONTRACT" for
--- the full rationale and who calls this. Declared OUTSIDE the
--- REGISTRATION-TIME FEATURE GATE further down, same as
--- IsRestingInKennel()/IsCarryingKennel()/RequestDeployKennel() above:
--- reachable-but-inert even with Config.Features.DeployableKennel false at
--- THIS file's own load time, and -- the actually load-bearing case --
--- never re-reads that flag (or HasK9Access, or certification, or any
--- cooldown) on the way out even when the flag WAS true at load and got
--- toggled off later mid-session. GATE THE START OF A THING, NEVER THE
--- STOP: adds no condition of its own beyond whatever ReleaseKennelRest()
--- itself already does (or rather, deliberately does not do).
function ExitKennelRest()
    ReleaseKennelRest('kennel.exit_success')
end

--- Server-initiated forced exit -- the client half of
--- server/kennel.lua's RegisterBodyClaimReleaser('kennel_rest', ...), which
--- fires when server/certifications/'s EndK9AccessForCitizenId revokes
--- this player's K9 access while they are still resting inside a kennel.
---
--- WHY THE SERVER CANNOT JUST FORGET THEM. The server clearing its own
--- KennelOccupants row without this event would free the kennel for a
--- second occupant while this player is still physically attached to the
--- prop with collision disabled -- a silent double-occupancy. This event is
--- the other half of that release, and the two are deliberately inseparable
--- (see server/bodyclaims.lua's ForceReleaseBodyClaimForCitizenId header).
---
--- Registered OUTSIDE the registration-time feature gate further down, for
--- the same reason ExitKennelRest itself is: a release path must stay
--- reachable even when Config.Features.DeployableKennel was false at load,
--- or was toggled off mid-session. GATE THE START OF A THING, NEVER THE
--- STOP -- and doubly so here, where the whole point is that this player's
--- access has ALREADY been taken away.
---
--- Harmless when there is nothing to release: ReleaseKennelRest returns
--- immediately on a nil restState, so a duplicate or late event does
--- nothing. The requestExitKennel it fires back at the server is likewise a
--- no-op -- the server cleared its own row before sending this.
RegisterNetEvent('qbx_k9unit:client:forceExitKennelRest', function(_reason)
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
    ReleaseKennelRest('kennel.exit_access_revoked')
end)

--- Runs RequestDeployKennel()'s own client-side gating and, if it passes,
--- asks the server to compute a spawn point. See FILE-TO-FILE CONTRACT
--- above for why this is exposed globally rather than kept command-local,
--- and for the carry/put-down branch THIS PASS adds.
function RequestDeployKennel()
    if carriedKennelNetId then
        -- "Put it back down" -- deliberately checked FIRST, ahead of even
        -- the feature-flag/HasK9Access() gates below, mirroring
        -- client/vehicle.lua's own ExitK9Vehicle() precedent ("a handler
        -- whose certification lapses mid-ride must always be able to
        -- un-freeze/set down themselves"). server/kennel.lua's own
        -- requestPutDownKennel handler is itself unconditional for the
        -- identical reason -- see that handler's own doc comment.
        TriggerServerEvent('qbx_k9unit:server:requestPutDownKennel')
        return
    end

    if not Config.Features.DeployableKennel then return end

    -- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission
    -- audit finding, this pass): server/kennel.lua's requestDeployKennel
    -- handler gates access on `HasK9Access(src)` alone (confirmed by
    -- reading it directly, ~line 782: `if not HasK9Access(src) then
    -- NotifyPlayer(...); return end`) -- no model/role check anywhere in
    -- that handler. Deploying a kennel is a HUMAN HANDLER action (placing
    -- an object on the ground near yourself), not a self-administered K9
    -- action -- the exact same distinction this file's own "Pick Up
    -- Kennel" ox_target option (icon 'fas fa-user-tie', HasK9Access() only)
    -- already draws against "Rest in Kennel"/"Exit Kennel"
    -- (icon 'fas fa-dog' + CanShowK9UI(), which genuinely does require
    -- being the dog -- see ResolveK9PedForKennelRest, server/kennel.lua,
    -- backing requestEnterKennel's own gate, deliberately left unchanged
    -- above). This branch used to gate on the broader CanShowK9UI()
    -- combinator, so a High Command officer whose ONLY access came from the
    -- autoAccessGrade bypass (which CanShowK9UI()'s own IsOwnModelK9()/
    -- IsK9Role() component deliberately excludes) could never deploy a
    -- kennel through ANY route even though the server would gladly have
    -- granted it. Matches the identical, already-shipped "Pick Up Kennel"
    -- precedent in this same file -- not a new idiom.
    if not HasK9Access() then
        DenyK9UIAccess('combat.no_access')
        return
    end

    if myKennelNetId then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.already_deployed'), type = 'error' })
        return
    end

    -- This is a UX convenience only (avoids an obviously-pointless round
    -- trip) — server/kennel.lua's requestDeployKennel handler independently
    -- re-checks the real, authoritative one-kennel-per-citizenid limit
    -- regardless of what this local variable currently believes.
    TriggerServerEvent('qbx_k9unit:server:requestDeployKennel')
end

--- Explicit-only entry point (docs/history/COMMAND_CONSOLIDATION_SPEC.md #5's own
--- additive design -- there was previously NO standalone command for this
--- at all, only the "Rest in Kennel" ox_target option on the specific
--- kennel prop). Attempts to enter THIS client's OWN deployed kennel
--- (`myKennelNetId`) -- mirrors RegisterKennelOxTargetOption's own
--- 'qbx_k9unit:enterKennel' canInteract/onSelect pair EXACTLY (same
--- CanShowK9UI() gate, same IsInK9Vehicle() mutual guard, same
--- interactDistanceMeters proximity bound, same
--- 'qbx_k9unit:server:requestEnterKennel' event) -- a display-optimization
--- mirror only, same as that ox_target option's own canInteract: the
--- server's own requestEnterKennel handler independently re-verifies
--- everything regardless of what this function decided locally. Declared
--- OUTSIDE the REGISTRATION-TIME FEATURE GATE further down, same as
--- RequestDeployKennel() above -- reachable-but-inert with the feature off.
--- @return boolean ok -- false means "did not even attempt it" (nothing deployed, too far, blocked) -- callers that want to explain why use the more specific locale keys this function itself already notifies with
function RequestEnterOwnKennel()
    if not Config.Features.DeployableKennel then return false end
    if not myKennelNetId then return false end -- nothing of mine deployed to enter

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return false
    end

    -- MUTUAL GUARD vs. client/vehicle.lua's real vehicle seating -- see
    -- RegisterKennelOxTargetOption's own 'qbx_k9unit:enterKennel' onSelect
    -- comment for the full reasoning; mirrored verbatim.
    if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.blocked_by_vehicle'), type = 'error' })
        return false
    end

    local entity = ResolveNetworkEntity(myKennelNetId, 3)
    if not entity then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_too_far'), type = 'error' })
        return false
    end

    local myCoords = GetEntityCoords(PlayerPedId())
    local kennelCoords = GetEntityCoords(entity)
    if #(myCoords - kennelCoords) > Config.DeployableKennel.interactDistanceMeters then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_too_far'), type = 'error' })
        return false
    end

    TriggerServerEvent('qbx_k9unit:server:requestEnterKennel', myKennelNetId)
    return true
end

-- ======================================================================
-- CLOSEABLE KENNEL (owner-directed, docs/history/COMMAND_CONSOLIDATION_SPEC.md #5
-- extension, this pass) -- see server/kennel.lua's own "CLOSEABLE KENNEL"
-- header section for the full design writeup (what closed does and does
-- NOT gate, who may toggle it, why pickup/exit are untouched). This file's
-- own job is thin: resolve WHICH kennel this client means (its own
-- deployed one if it has one, else the one it's currently resting in --
-- covers both the owner-standing-outside and the occupant-riding-inside
-- cases with the SAME two already-existing local variables, no new state),
-- then ask the server. The server is the sole authority on WHETHER the
-- caller is actually allowed to toggle it (owner or current occupant) --
-- this file adds no client-side gate of its own beyond "is there a kennel
-- to act on at all", exactly mirroring RequestRecallFetchBall()'s own
-- "no access gate on the way out" posture for an action whose real
-- authorization is fully server-side.
-- ======================================================================

--- @return number? netId
local function ResolveKennelNetIdForDoorAction()
    if myKennelNetId then return myKennelNetId end
    if restState then return restState.kennelNetId end
    return nil
end

--- Explicit-only entry point (no ambient state safely disambiguates this
--- from ENTER for a bystander with nothing deployed and nothing entered --
--- silently does nothing in that case, same "nothing to act on" posture as
--- every other resolve-first helper in this file).
function RequestCloseKennelDoor()
    local netId = ResolveKennelNetIdForDoorAction()
    if not netId then return end
    TriggerServerEvent('qbx_k9unit:server:requestCloseKennel', netId)
end

--- Symmetric to RequestCloseKennelDoor() above.
function RequestOpenKennelDoor()
    local netId = ResolveKennelNetIdForDoorAction()
    if not netId then return end
    TriggerServerEvent('qbx_k9unit:server:requestOpenKennel', netId)
end

--- The bare '/k9kennel' contextual dispatch's OWN-DEPLOYED-KENNEL branch,
--- extracted so RequestKennelContextual() below stays a flat, readable
--- priority list. Unlike every OTHER branch in that dispatcher
--- (rest/carry are pure client-local booleans), this one genuinely cannot
--- be resolved from local state alone -- see server/kennel.lua's own
--- "CLIENT-SIDE VISIBILITY GAP" header paragraph for why -- so this awaits
--- a real server round trip (`getOwnKennelDoorState`) before deciding.
--- DISPLAY/DECISION AID ONLY: whichever real action this leads to
--- (requestEnterKennel/requestCloseKennel/requestOpenKennel) independently
--- re-validates everything server-side regardless of what this callback
--- most recently reported -- a stale answer can only ever cause a
--- harmless refusal on the follow-up request, never a security issue.
local function RequestOwnKennelDoorOrEnter()
    local entity = ResolveNetworkEntity(myKennelNetId, 3)
    if not entity then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_too_far'), type = 'error' })
        return
    end

    local myCoords = GetEntityCoords(PlayerPedId())
    local kennelCoords = GetEntityCoords(entity)
    if #(myCoords - kennelCoords) > Config.DeployableKennel.interactDistanceMeters then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_too_far'), type = 'error' })
        return
    end

    local result
    local ok = pcall(function()
        result = lib.callback.await('qbx_k9unit:server:getOwnKennelDoorState', K9_CALLBACK_TIMEOUT_MS)
    end)
    if not ok or not result or not result.ok then
        -- Callback unavailable/threw/reported no kennel after all (e.g. it
        -- was just picked up or removed in the round-trip window) -- fall
        -- back to the plain ENTER attempt, which re-validates everything
        -- itself and fails cleanly if there is genuinely nothing to enter.
        RequestEnterOwnKennel()
        return
    end

    if result.closed then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.contextual_opening'), type = 'inform' })
        RequestOpenKennelDoor()
    elseif result.occupied then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.contextual_closing'), type = 'inform' })
        RequestCloseKennelDoor()
    else
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.contextual_entering'), type = 'inform' })
        RequestEnterOwnKennel()
    end
end

-- ======================================================================
-- '/k9kennel' -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #5, ADDITIVE (not a
-- replacement -- see this file's header for why): k9deploykennel above and
-- k9exitkennel (client/keybinds.lua) are UNCHANGED, keep their own literal
-- names, and keep working for their existing RegisterKeyMapping bindings
-- and the radial menu's own direct calls -- this is a NEW, ADDITIONAL
-- entry point layered on top, calling the exact same
-- RequestDeployKennel()/ExitKennelRest()/RequestEnterOwnKennel() globals
-- those existing entry points already call. Neither k9deploykennel nor
-- k9exitkennel is a hidden alias of this command (they are not being
-- folded away) -- both stay fully first-class, documented commands in
-- their own right.
--
-- CONTEXTUAL DISPATCH: bare '/k9kennel' reads THIS CLIENT'S OWN real local
-- state and picks the one action that state actually implies --
--   IsRestingInKennel()  -> EXIT (ExitKennelRest()) -- highest priority,
--                           unconditional, and UNCHANGED by the closeable-
--                           kennel addition below: nothing else makes
--                           sense while resting, and this branch reads no
--                           door state at all.
--   IsCarryingKennel()   -> PUT DOWN (RequestDeployKennel(), whose own
--                           "put it back down" branch fires first).
--   myKennelNetId ~= nil -> genuinely undecidable from local state alone
--                           (is it occupied? open or closed?) -- awaits a
--                           real server round trip
--                           (RequestOwnKennelDoorOrEnter(), see its own doc
--                           comment) rather than guessing, then resolves to
--                           exactly one of ENTER / CLOSE / OPEN / a
--                           `kennel.enter_too_far` notice. Deploying a
--                           SECOND kennel is never attempted here, matching
--                           RequestDeployKennel()'s own
--                           `kennel.already_deployed` refusal.
--   none of the above    -> DEPLOY (RequestDeployKennel()).
-- Every branch calls a function that already re-runs its own real gate
-- (CanShowK9UI()/Config.Features.DeployableKennel/server-side owner-or-
-- occupant authorization/etc) -- this dispatcher performs no authorization
-- check of its own to skip, so the merge cannot widen access.
--
-- EXPLICIT OVERRIDE: '/k9kennel <deploy|enter|exit|close|open>' forces that
-- action directly, regardless of current state, identical to calling the
-- matching resource-global directly (deploy/exit are exactly what
-- k9deploykennel/k9exitkennel already do; close/open are reachable by
-- BOTH the owner outside and the occupant inside -- see
-- ResolveKennelNetIdForDoorAction()'s own doc comment).
--
-- REGISTERED UNCONDITIONALLY (NOT inside the REGISTRATION-TIME FEATURE
-- GATE below) -- same reasoning as k9exitkennel's own unconditional
-- registration in client/keybinds.lua: the 'exit' branch (both explicit
-- and contextual, when IsRestingInKennel() is true) must stay reachable
-- even with Config.Features.DeployableKennel off or toggled off mid-session
-- for an already-resting occupant. The deploy/enter branches themselves
-- still internally check the flag (RequestDeployKennel()/
-- RequestEnterOwnKennel() both already do) and simply no-op when it's off.
-- ======================================================================
--- Bare-dispatch body, extracted as its own resource-global -- same
--- "global helper, private per-file state" convention as
--- RequestDeployKennel()/ExitKennelRest()/RequestEnterOwnKennel() above,
--- specifically so client/radial.lua can call this EXACT SAME path.
--- DONE (verified against client/radial.lua as of this pass): its former
--- two flat 'k9_deploy_kennel'/'k9_exit_kennel' items are now the single
--- 'k9_kennel' entry that calls this function -- see that file's own
--- "MERGED, owner-directed decluttering pass" comment for the item
--- definition. Declared OUTSIDE the
--- REGISTRATION-TIME FEATURE GATE further down, same as every other
--- function in this block -- reachable-but-inert with the feature off (the
--- exit branch below still works regardless, matching every other
--- never-gate-the-stop path in this file).
function RequestKennelContextual()
    -- CONFIRMATION NAMES THE DECISION (project-owner's own requirement):
    -- notified BEFORE the resolved action runs.
    if IsRestingInKennel() then
        -- The K9 menu's Kennel button is one of the two ways out (the
        -- other is the third eye on the kennel) -- owner's choice.
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.contextual_exiting'), type = 'inform' })
        ExitKennelRest()
    elseif IsCarryingKennel() then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.contextual_putting_down'), type = 'inform' })
        RequestDeployKennel()
    elseif myKennelNetId then
        -- Genuinely undecidable from local state alone (occupied? closed?)
        -- -- see RequestOwnKennelDoorOrEnter()'s own doc comment for why
        -- this ONE branch awaits a server round trip instead of guessing.
        -- That function itself fires the "here's what I decided" notify,
        -- once it actually knows the real answer.
        RequestOwnKennelDoorOrEnter()
    else
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.contextual_deploying'), type = 'inform' })
        RequestDeployKennel()
    end
end

local KENNEL_EXPLICIT_ACTIONS = {
    deploy = function() RequestDeployKennel() end,
    enter = function() RequestEnterOwnKennel() end,
    -- CLOSEABLE KENNEL (this pass) -- explicit words, reachable by BOTH the
    -- owner standing outside (myKennelNetId) and the occupant resting
    -- inside (restState) -- see ResolveKennelNetIdForDoorAction()'s own
    -- doc comment above.
    close = function() RequestCloseKennelDoor() end,
    open = function() RequestOpenKennelDoor() end,
}

RegisterCommand('k9kennel', function(_source, args)
    local explicit = args[1] and KENNEL_EXPLICIT_ACTIONS[args[1]]
    if explicit then
        explicit()
        return
    end

    if args[1] then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.usage_k9kennel'), type = 'error' })
        return
    end

    -- Bare '/k9kennel' -- contextual dispatch, see RequestKennelContextual()
    -- above -- except leaving: that is the third eye or the K9 menu only.
    if IsRestingInKennel() then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.exit_use_third_eye'), type = 'inform' })
        return
    end
    RequestKennelContextual()
end, false)

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE (coder-frontend precedent) -- mirrors
-- client/propattachment.lua's own identically-shaped fix; read that file's
-- own "REGISTRATION-TIME FEATURE GATE" header before changing this one --
-- this block follows it, not a second independent design. Every net event
-- registration, ox_target registration, and the shared watchdog thread
-- below are inside this single `if`, evaluated once at this file's own
-- load time (config.lua is a shared_scripts file, loaded in full before
-- any client_scripts file runs). RequestDeployKennel()/IsRestingInKennel()/
-- IsCarryingKennel() above stay OUTSIDE this gate on purpose -- they
-- already gate themselves internally (or are trivially false/no-op with
-- the feature off) and must stay reachable-but-inert for client/radial.lua/
-- client/tablet.lua's own `type(...) == 'function'` call sites, exactly as
-- client/propattachment.lua's own header documents for
-- RequestToggleK9PropAttachment.
-- ======================================================================
if Config.Features.DeployableKennel then

RegisterCommand('k9deploykennel', function()
    RequestDeployKennel()
end, false)

--- Server-issued instruction (never a request to validate — see
--- server/kennel.lua's header "WHY THE SERVER COMPUTES THE PLACEMENT
--- COORDS" block): create the kennel object at exactly (x, y, z), ground
--- it, freeze it, and report the resulting network id back.
--- @param x number
--- @param y number
--- @param z number
RegisterNetEvent('qbx_k9unit:client:deployKennelAt', function(x, y, z)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD, see client/combat.lua's own header block
    if not Config.Features.DeployableKennel then return end
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    -- STALE-KENNEL GUARD (client/propattachment.lua's own "STALE-VEST
    -- GUARD" on attachK9Prop is the precedent this follows).
    if myKennelNetId then
        local staleEntity = ResolveNetworkEntity(myKennelNetId)
        if staleEntity then
            DeleteEntity(staleEntity)
        end
        myKennelNetId = nil
    end

    local modelHash = LoadModelWithTimeout(Config.DeployableKennel.propModel)
    local usedFallback = false
    if not modelHash then
        usedFallback = true
        modelHash = LoadModelWithTimeout(Config.DeployableKennel.fallbackPropModel)
    end

    if not modelHash then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.prop_load_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelKennelPlacement')
        return
    end

    if usedFallback then
        print(('[qbx_k9unit] DeployableKennel: propModel "%s" failed to load, used fallbackPropModel "%s" instead — see config.lua\'s Config.DeployableKennel comment (single-source, unconfirmed prop name).'):format(Config.DeployableKennel.propModel, Config.DeployableKennel.fallbackPropModel))
    end

    local obj = CreateObject(modelHash, x, y, z, true, true, false)
    SetModelAsNoLongerNeeded(modelHash)

    if not DoesEntityExist(obj) then
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.placement_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelKennelPlacement')
        return
    end

    local placedOk = PlaceObjectOnGroundProperly(obj)
    if not placedOk then
        DeleteEntity(obj)
        lib.notify({ title = locale('common.notify_title'), description = locale('kennel.no_suitable_ground'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelKennelPlacement')
        return
    end

    FreezeEntityPosition(obj, true)

    local netId = NetworkGetNetworkIdFromEntity(obj)
    myKennelNetId = netId
    TriggerServerEvent('qbx_k9unit:server:confirmKennelPlaced', netId)
end)

--- Cleanup backstop broadcast from server/kennel.lua — see that file's
--- RemoveKennelForCitizenid CLEANUP CONFIDENCE NOTE for why this exists
--- alongside the server's own direct DeleteEntity attempt. Safe no-op for
--- any client that doesn't have this netId streamed in.
---
--- THIS PASS: also the OCCUPANT's own defense-in-depth self-release check
--- — reachable far less often now that RemoveKennelForCitizenid itself
--- structurally refuses to run at all while occupied (see that function's
--- own doc comment), but kept as belt-and-suspenders in case some future
--- caller/admin action ever deletes a kennel out from under an occupant
--- anyway: this client must never depend on that never happening.
---
--- GATE THE START OF A THING, NEVER THE STOP (same doctrine as the "Exit
--- Kennel" ox_target option's own canInteract fix, this pass): the
--- self-release above must never be skippable by a stale/toggled
--- Config.Features.DeployableKennel reread, or the exact same
--- future-live-config-push trap applies here too — this handler no longer
--- rereads the flag at all. It is only ever registered while the feature
--- was on at THIS file's own load time (the REGISTRATION-TIME FEATURE GATE
--- further down already covers "genuinely inert with the feature off from
--- the start"); nothing below needs, or should have, a second, live check.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:removeKennel', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD, see client/combat.lua's own header block
    if type(netId) ~= 'number' then return end

    if restState and restState.kennelNetId == netId then
        ReleaseKennelRest('kennel.exit_kennel_removed')
    end

    if myKennelNetId == netId then
        myKennelNetId = nil
    end

    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    -- DEFENSE-IN-DEPTH MODEL CHECK — restricts the delete to an entity
    -- whose CURRENT model actually matches a configured kennel prop.
    if not KennelPropModelHashes[GetEntityModel(entity)] then return end

    DeleteEntity(entity)
end)

--- Server-issued instruction: the picker's own client attaches the SAME,
--- already-existing, real kennel object to its own hands. THIS PASS.
--- Never CreateObjects a new prop — see this file's header FILE-TO-FILE
--- CONTRACT note on why client/propattachment.lua's AttachPropToOwnPed is
--- deliberately NOT reused here.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:pickupKennelConfirmed', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if not Config.Features.DeployableKennel then return end
    if type(netId) ~= 'number' then return end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity or not KennelPropModelHashes[GetEntityModel(entity)] then
        -- The server already validated this before sending the
        -- instruction; a failure here means the object streamed out (or
        -- changed) in the brief round trip. Fail closed: don't attach
        -- anything, don't claim to be carrying anything.
        return
    end

    -- NETWORK OWNERSHIP -- see this file's header section. This client did
    -- not necessarily create/last-touch this object, so it must ask for
    -- control before attaching it to itself, mirroring
    -- client/combat.lua's own PropDragging precedent exactly (best-effort,
    -- fire-and-forget, never a blocking wait).
    NetworkRequestControlOfEntity(entity)

    -- Was frozen in place since deployment (or since its last put-down) —
    -- must be unfrozen before being repositioned via attachment, or the
    -- two would fight each other.
    FreezeEntityPosition(entity, false)

    local cfg = Config.DeployableKennel
    -- entity1 = the kennel OBJECT (not a ped) -- isPed = false, matching
    -- client/propattachment.lua's own vest-attach call shape exactly (same
    -- trailing flag set, same reasoning: a carried prop should not
    -- physically collide with its carrier, and should not use the
    -- ped-specific pitch/roll behavior since entity1 here is an object).
    AttachEntityToEntity(entity, PlayerPedId(), cfg.carryBoneIndex,
        cfg.carryOffsetX, cfg.carryOffsetY, cfg.carryOffsetZ,
        cfg.carryRotX, cfg.carryRotY, cfg.carryRotZ,
        true, false, false, false, 2, true)

    carriedKennelNetId = netId
end)

--- Server-issued instruction: detach the kennel this client is carrying,
--- reposition it at the server-computed drop point, and re-freeze it —
--- the mirror image of deployKennelAt, applied to an already-existing
--- object instead of a freshly created one. THIS PASS.
--- @param netId number
--- @param x number
--- @param y number
--- @param z number
RegisterNetEvent('qbx_k9unit:client:putDownKennelAt', function(netId, x, y, z)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if type(netId) ~= 'number' or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    if carriedKennelNetId == netId then
        carriedKennelNetId = nil
    end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity then return end -- nothing left to put down -- server already cleared its own bookkeeping regardless

    DetachEntity(entity, true, false)
    SetEntityCoords(entity, x, y, z, false, false, false, true)
    -- Not treated as fatal if this returns false (bad terrain under the
    -- drop point) — UNLIKE the fresh-deploy flow, this object can never be
    -- deleted on a placement failure here (it might have an occupant
    -- attached to it) — see server/kennel.lua's header CRITICAL SAFETY
    -- section. Freeze it wherever it ended up either way.
    PlaceObjectOnGroundProperly(entity)
    FreezeEntityPosition(entity, true)
end)

--- Server-issued instruction: this client's OWN ped attaches itself to the
--- kennel it just asked, and was authorized, to rest in. THIS PASS. Never
--- touches any OTHER player's ped — see this file's header NO CROSS-PED
--- DRIVING section.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:enterKennelConfirmed', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if not Config.Features.DeployableKennel then return end
    if type(netId) ~= 'number' then return end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity or not KennelPropModelHashes[GetEntityModel(entity)] then
        return -- streamed out / changed in the brief round trip -- fail closed
    end

    -- MUTUAL GUARD vs. client/vehicle.lua's real vehicle seating --
    -- re-checked HERE, not just at onSelect time, for the identical
    -- round-trip-window reason every other re-validate-after-a-server-trip
    -- check in this resource exists (client/vehicle.lua's own
    -- vehicleSeatClaimGranted handler re-checks its own drag/bite-hold/
    -- kennel-rest guards for the same reason): the player could have
    -- selected "Enter Vehicle" (a SEPARATE, ALSO server-arbitrated action)
    -- in the gap between this file's own onSelect guard passing and this
    -- confirmation arriving. server/kennel.lua's own requestEnterKennel
    -- handler already wrote KennelOccupants[citizenid] BEFORE sending this
    -- event -- refusing locally here without telling the server would leave
    -- that occupancy claim held forever (server/kennel.lua's own
    -- requestExitKennel is the ONLY thing that clears it short of a
    -- disconnect; there is no TTL on it at all, unlike
    -- client/vehicle.lua's own 10s seat-claim TTL backstop), so the release
    -- below is not optional. ReleaseKennelRest() is NOT used for this --
    -- restState was never set on this path, so it would see nothing to do
    -- and skip sending anything at all (see its own `if not restState then
    -- return end` guard) -- the release must be sent directly.
    --
    -- Soft dependency, this resource's established convention -- see this
    -- file's own "Rest in Kennel" canInteract/onSelect guards above for the
    -- same check.
    if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
        lib.notify({ title = locale('common.notify_title'), description = locale('combat.blocked_by_vehicle'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:requestExitKennel')
        return
    end

    local ped = PlayerPedId()
    local kennelCoords = GetEntityCoords(entity)
    local kennelHeading = GetEntityHeading(entity)

    -- TASKS CLEARED FIRST -- see this file's own REST POSE section above
    -- for the full writeup of the bug this closes. In short: you always
    -- WALK to a kennel, so the ped is essentially always carrying a live
    -- locomotion task at the moment this confirmation lands, and
    -- AttachEntityToEntity does not cancel tasks -- it only re-parents the
    -- transform. Without this, the dog kept playing its walk/run cycle
    -- while pinned in place, visibly running on the spot inside the cage.
    -- Runs BEFORE the reposition, not after, so the ped is genuinely idle
    -- for the whole position -> attach -> pose sequence below rather than
    -- being teleported mid-stride. Unconditional: this native is safe on a
    -- dead or ragdolled ped (client/vehicle.lua's own ForceLeaveVehicle
    -- calls it on exactly that case for the same reason).
    ClearPedTasksImmediately(ped)

    -- Positioned directly at the kennel's own coords/heading before
    -- attaching, so the very first rendered frame already shows the
    -- occupant genuinely inside the prop rather than snapping there over
    -- one visible tick.
    SetEntityCoords(ped, kennelCoords.x, kennelCoords.y, kennelCoords.z, false, false, false, true)
    SetEntityHeading(ped, kennelHeading)

    -- Collision disabled between the occupant and the (typically
    -- small-footprint) cage prop it now overlaps -- mirrors
    -- client/vehicle.lua's own EnterNearestK9Vehicle() precedent
    -- (SetEntityCollision(ped, false, false) while tucked into another
    -- entity's space) -- restored unconditionally by ReleaseKennelRest on
    -- every exit path.
    SetEntityCollision(ped, false, false)

    -- entity1 = the occupant's own PED -- isPed intentionally matches
    -- client/combat.lua's own PropDragging call (isPed = false) rather
    -- than this native's own doc-described "true for a ped" reading: that
    -- file's call also attaches a real ped (targetPed) as entity1 and is
    -- the only existing, shipped precedent in this codebase for this
    -- exact combination — matching a proven, already-integrated pattern
    -- was judged safer than a fresh, unverified deviation based on a
    -- doc-only reading with no live client available to test against this
    -- session. Config.DeployableKennel.restOffsetX/Y/Z default to 0,0,0
    -- (the prop's own origin) -- see that config field's own comment for
    -- why an untuned, disclosed placeholder was chosen over guessing a
    -- bone-specific offset.
    local cfg = Config.DeployableKennel
    AttachEntityToEntity(ped, entity, 0,
        cfg.restOffsetX, cfg.restOffsetY, cfg.restOffsetZ,
        0.0, 0.0, 0.0,
        true, false, false, false, 2, true)

    -- POSED LAST, after the attach -- see PlayKennelRestPose's own doc
    -- comment for why this order and not the reverse. This is what makes
    -- the dog actually READ as resting in the kennel rather than standing
    -- inside it.
    PlayKennelRestPose(ped)

    restState = { kennelNetId = netId }
    lib.notify({ title = locale('common.notify_title'), description = locale('kennel.enter_success'), type = 'success' })
end)

--- Carrier-disconnect safety net (server/kennel.lua's own playerDropped
--- handler, event 12) — see that file's own doc comment for the full
--- reasoning. Broadcast (-1): whichever connected client currently has
--- this object streamed in settles it, since the disconnecting carrier's
--- own client can no longer do so itself. Never touches KennelOccupants or
--- any occupant's own restState -- an occupant riding inside is completely
--- unaffected by who is or isn't carrying the object it is itself attached
--- to, and keeps its own, completely independent exit throughout.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:kennelCarrierLost', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD
    if not Config.Features.DeployableKennel then return end
    if type(netId) ~= 'number' then return end

    if carriedKennelNetId == netId then
        carriedKennelNetId = nil
    end

    local entity = ResolveNetworkEntity(netId)
    if not entity then return end
    if not KennelPropModelHashes[GetEntityModel(entity)] then return end

    -- Harmless no-op on an entity that's already detached/frozen -- safe
    -- for every client that happens to have this object streamed in to run
    -- this redundantly.
    DetachEntity(entity, true, false)
    FreezeEntityPosition(entity, true)
end)

-- Resource-restart safety net (same class of fix as client/vehicle.lua's
-- own onResourceStop handler, flagged there as a "ship-blocking QA
-- finding" for a different piece of entity state): if THIS client created
-- a kennel and the resource stops while it's still connected, delete it
-- locally rather than leaving a frozen, ownerless object behind that
-- nothing will ever clean up once this resource's own scripts (client and
-- server) are gone. Covers the common "still connected at resource
-- restart" case; server/kennel.lua's own onResourceStop loop covers
-- kennels whose creating client already disconnected earlier in the
-- session (see that file's header for why the two are complementary, not
-- redundant).
--
-- THIS PASS: also unconditionally releases THIS client's own restState
-- (detach own ped, restore collision -- exactly ReleaseKennelRest's own
-- native cleanup, run directly here rather than through that function
-- since there is no meaningful "notify" or "tell the server" step left to
-- run when this resource's own script instance is already stopping) and
-- carriedKennelNetId (detach only, NOT delete — the object itself is
-- server/kennel.lua's own onResourceStop sweep's responsibility, and that
-- sweep runs unconditionally, even for a carried/occupied kennel, exactly
-- because it is safe for it to: see that file's own doc comment for why
-- resource-restart deletion never depends on, and never endangers, an
-- occupant's own independent client-side release, which is exactly what
-- this handler performs regardless of what the server does to the shared
-- object).
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if myKennelNetId then
        local entity = ResolveNetworkEntity(myKennelNetId)
        if entity then
            DeleteEntity(entity)
        end
        myKennelNetId = nil
    end

    if restState then
        -- Routed through the SAME ReleaseOccupantNatives() every other exit
        -- path uses, rather than repeating its natives inline -- that
        -- inline copy is precisely what let the rest-pose fix half-land
        -- here; see that function's own doc comment. Deliberately NOT
        -- ReleaseKennelRest(): there is no meaningful notify or
        -- tell-the-server step left to run when this resource's own script
        -- instance is already stopping, and the server has its own
        -- onResourceStop sweep for the bookkeeping.
        ReleaseOccupantNatives(PlayerPedId())
        restState = nil
    end

    if carriedKennelNetId then
        local entity = ResolveNetworkEntity(carriedKennelNetId)
        if entity then
            DetachEntity(entity, true, false)
        end
        carriedKennelNetId = nil
    end
end)

-- ======================================================================
-- SHARED WATCHDOG THREAD -- see this file's header "WHY A ONE-SHOT ATTACH"
-- section for the full reasoning behind this shape (mirrors
-- client/vehicle.lua's own dual-interval watchdog thread, not
-- client/combat.lua's per-frame reassertion thread). Handles safety
-- backstops for BOTH the occupant relationship (restState) and the carry
-- relationship (carriedKennelNetId) independently -- either can be active
-- without the other, and this thread's own idle/active interval choice
-- reflects whichever (if either) currently is, exactly like
-- client/vehicle.lua's own vehicleState-driven sleepMs selection.
-- ======================================================================
local KENNEL_WATCHDOG_IDLE_MS = 2000
local KENNEL_WATCHDOG_ACTIVE_MS = 1000
local KENNEL_WATCHDOG_MISS_THRESHOLD = 3 -- consecutive misses before treating an entity as actually gone -- see client/vehicle.lua's own identical constant for why a single miss is not trusted alone

CreateThread(function()
    local restMissStreak = 0
    local carryMissStreak = 0

    while true do
        local sleepMs = KENNEL_WATCHDOG_IDLE_MS

        if restState then
            sleepMs = KENNEL_WATCHDOG_ACTIVE_MS
            local ped = PlayerPedId()

            if DoesEntityExist(ped) and IsEntityDead(ped) then
                -- OWN-DEATH RELEASE -- mirrors client/vehicle.lua's own
                -- OWN-DEATH RELEASE branch exactly. ReleaseKennelRest
                -- itself is what actually frees the player; this branch
                -- only decides WHEN to call it.
                restMissStreak = 0
                ReleaseKennelRest('kennel.exit_own_downed')
            else
                local kennelEntity = ResolveKennelFromRestState()
                if kennelEntity then
                    restMissStreak = 0
                    -- CORRECTED (this pass, trap-hunt finding) -- an
                    -- EARLIER version of this comment claimed "since this
                    -- feature deliberately never freezes or disables
                    -- control on the occupant, simply walking away is
                    -- ALREADY an unconditional, code-independent way out."
                    -- VERIFIED FALSE by reading how AttachEntityToEntity is
                    -- actually enforced elsewhere in THIS codebase:
                    -- client/combat.lua's own PROP DRAGGING header
                    -- ("HOLDER-SIDE ATTACH RE-ASSERTION") documents that the
                    -- ONLY thing that ever ends an AttachEntityToEntity
                    -- relationship is an explicit DetachEntity() call --
                    -- that file re-asserts its own attach every single tick
                    -- purely to defend against a HOSTILE TARGET calling
                    -- DetachEntity ON ITSELF, never because the position
                    -- relationship decays, or can be overridden by ordinary
                    -- movement input, without one. The occupant's own ped
                    -- IS attached here (see enterKennelConfirmed above) --
                    -- the engine re-clamps its position to the kennel's own
                    -- bone transform every tick regardless of WASD/task-
                    -- locomotion input, exactly like combat.lua's own
                    -- dragged target. Ordinary movement therefore CANNOT
                    -- move a genuinely-still-attached occupant away from a
                    -- still-existing kennel -- the distance check below can
                    -- practically never fire for that reason.
                    --
                    -- WHAT THIS BRANCH ACTUALLY CATCHES: the rare case
                    -- where the native-level attachment itself silently
                    -- ends (a desync, a migration edge case) while
                    -- restState (this file's own bookkeeping) hasn't been
                    -- told yet -- in exactly that scenario the occupant
                    -- really is free-standing and CAN walk away, and this
                    -- converts that into a clean, tracked exit (clears
                    -- server-side occupancy) instead of leaving a stale
                    -- KennelOccupants entry. A narrow backstop, NOT this
                    -- feature's real escape hatch.
                    --
                    -- THE REAL, ALWAYS-AVAILABLE ESCAPE HATCH: the "Exit
                    -- Kennel" ox_target option below, PLUS (this pass) the
                    -- k9exitkennel keybind (client/keybinds.lua) and the
                    -- "Exit Kennel" radial item (client/radial.lua) -- all
                    -- three call ExitKennelRest() (-> ReleaseKennelRest())
                    -- directly, which never depends on the occupant's own
                    -- ped being movable, targetable, or even visible at
                    -- all, unlike this distance check.
                    local dist = #(GetEntityCoords(ped) - GetEntityCoords(kennelEntity))
                    if dist > Config.DeployableKennel.interactDistanceMeters then
                        ReleaseKennelRest('kennel.exit_success')
                    end
                else
                    -- ENTITY-LOST WATCHDOG, debounced exactly like
                    -- client/vehicle.lua's own VEHICLE_WATCHDOG_MISS_THRESHOLD
                    -- (a single miss can be a momentary streaming hiccup,
                    -- not proof the object is actually gone).
                    restMissStreak = restMissStreak + 1
                    if restMissStreak >= KENNEL_WATCHDOG_MISS_THRESHOLD then
                        restMissStreak = 0
                        ReleaseKennelRest('kennel.exit_kennel_lost')
                    end
                end
            end
        else
            restMissStreak = 0
        end

        if carriedKennelNetId then
            sleepMs = KENNEL_WATCHDOG_ACTIVE_MS
            local ped = PlayerPedId()
            local kennelEntity = ResolveNetworkEntity(carriedKennelNetId)

            if DoesEntityExist(ped) and IsEntityDead(ped) then
                -- OWN-DEATH AUTO-DROP (carrier side) -- mirrors
                -- client/propattachment.lua's own OWN-DEATH AUTO-DETACH
                -- precedent. Reuses the SAME requestPutDownKennel flow an
                -- ordinary, voluntary put-down uses (server computes a
                -- fresh drop point from this now-downed ped's own live
                -- position and instructs the matching detach/reposition/
                -- refreeze) rather than a separate, duplicate native
                -- sequence here -- carriedKennelNetId is cleared by that
                -- response handler itself once it arrives, not here, so a
                -- delayed response still finds a consistent local state.
                carryMissStreak = 0
                lib.notify({ title = locale('common.notify_title'), description = locale('kennel.exit_own_downed'), type = 'error' })
                TriggerServerEvent('qbx_k9unit:server:requestPutDownKennel')
            elseif kennelEntity then
                carryMissStreak = 0
                -- PERIODIC RE-ASSERTION (this file's header "WHY A ONE-SHOT
                -- ATTACH" section) -- cheap insurance at this coarse
                -- cadence against a rare silent detach, for the one
                -- relationship that genuinely crosses an ownership
                -- boundary.
                NetworkRequestControlOfEntity(kennelEntity)
                local cfg = Config.DeployableKennel
                AttachEntityToEntity(kennelEntity, ped, cfg.carryBoneIndex,
                    cfg.carryOffsetX, cfg.carryOffsetY, cfg.carryOffsetZ,
                    cfg.carryRotX, cfg.carryRotY, cfg.carryRotZ,
                    true, false, false, false, 2, true)
            else
                carryMissStreak = carryMissStreak + 1
                if carryMissStreak >= KENNEL_WATCHDOG_MISS_THRESHOLD then
                    carryMissStreak = 0
                    carriedKennelNetId = nil
                    lib.notify({ title = locale('common.notify_title'), description = locale('kennel.exit_kennel_lost'), type = 'error' })
                end
            end
        else
            carryMissStreak = 0
        end

        Wait(sleepMs)
    end
end)

-- "Pick Up Kennel" / "Rest in Kennel" / "Exit Kennel" ox_target entry
-- points — target EITHER configured kennel model (primary or fallback,
-- see config.lua's comment on why both are legitimate) directly by model
-- hash via ox_target's addModel.
--
-- VISIBILITY VS. AUTHORIZATION: every canInteract below is a UX
-- convenience only (this resource's established standard,
-- server/certifications/'s own header: "client-side ox_target option
-- visibility... [is a] UX convenience only, not access control") —
-- server/kennel.lua's own handlers independently re-verify real
-- authorization/ownership/proximity/occupancy and reject (with a
-- notification, not silently) anyone who slips past a stale or
-- optimistic canInteract.
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call.
--
-- ICON/GATE CONVENTION (coder-frontend, cross-file input this pass):
-- 'fas fa-dog' + CanShowK9UI() marks an action the K9 itself performs on
-- itself (Enter/Exit Kennel, matching this resource's existing fa-dog
-- convention for self-administered K9 actions);
-- 'fas fa-user-tie' + a lighter HasK9Access()-only check marks the
-- separate HUMAN HANDLER action of picking the kennel up — a handler
-- carrying a box does not require currently being a dog, so this option
-- is deliberately NOT gated behind CanShowK9UI() the way it
-- was before this pass (that old gate meant only a player literally in K9
-- form could ever see "Pick Up Kennel" at all, which never made sense for
-- a handler-side action and is fixed here as part of the same pass that
-- widens WHO may perform it server-side).
--
-- LIFECYCLE FIX: extracted into a named function so these options can be
-- re-registered any time the resource actually backing the 'target'
-- system (re)starts, not just once at this file's own load time — mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory.
local function RegisterKennelOxTargetOption()
    if not Config.Features.DeployableKennel then return end

    K9Compat.Get('target').AddModel({
        GetHashKey(Config.DeployableKennel.propModel),
        GetHashKey(Config.DeployableKennel.fallbackPropModel),
    }, {
        {
            name = 'qbx_k9unit:pickupKennel',
            icon = 'fas fa-user-tie',
            label = locale('kennel.pickup_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.DeployableKennel then return false end
                if IsCarryingKennel() then return false end -- can't pick up a second one while already carrying one
                -- Soft dependency, this resource's established convention
                -- (client/vehicle.lua's own IsDragEngaged/IsBiteHoldEngaged
                -- guards) -- client/main.lua's HasK9Access() is a
                -- resource-global that always exists once that file loads,
                -- but guarded anyway for consistency with every other
                -- cross-file optional check in this file.
                return type(HasK9Access) == 'function' and HasK9Access()
            end,
            onSelect = function(data)
                if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                TriggerServerEvent('qbx_k9unit:server:requestPickupKennel', netId)
            end,
        },
        {
            name = 'qbx_k9unit:enterKennel',
            icon = 'fas fa-dog',
            label = locale('kennel.enter_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.DeployableKennel then return false end
                if IsRestingInKennel() or IsCarryingKennel() then return false end
                -- MUTUAL GUARD vs. client/vehicle.lua's real vehicle seating
                -- -- QA-reported real defect, this pass, closed from both
                -- sides at once (see this guard's own onSelect-side doc
                -- comment below for the full reasoning). Display-optimization
                -- mirror only: PerformSearch-style, the real refusal lives in
                -- onSelect and, defensively, in enterKennelConfirmed below.
                -- Soft dependency, this resource's established convention --
                -- IsInK9Vehicle() only exists once client/vehicle.lua's own
                -- Config.Features.VehicleEntryExit gate lets that file define
                -- it, and this file has no hard load-order requirement on it.
                if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then return false end
                -- ANY PED (this resource's own established convention,
                -- confirmed by this file's own test suite: "never calls
                -- IsOwnModelK9() anywhere") -- CanShowK9UI() alone already
                -- internally decouples role from model
                -- (Config.K9Appearance.requireK9ModelForRole), so a K9-role
                -- holder on a non-dog body is not wrongly hidden from this
                -- option by a second, redundant model check here.
                return CanShowK9UI()
            end,
            onSelect = function(data)
                if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                -- MUTUAL GUARD vs. client/vehicle.lua's real vehicle seating
                -- (SET_PED_INTO_VEHICLE) -- QA-reported real defect, this
                -- pass: neither file previously knew about the other, so a
                -- K9 already seated in a vehicle could still request
                -- entering a kennel, and 'qbx_k9unit:client:enterKennelConfirmed'
                -- below would AttachEntityToEntity the SAME ped the vehicle
                -- already owns via a real seat -- the two mechanics would
                -- then fight (the kennel watchdog re-asserting the attach
                -- every ~1s against a ped the vehicle also claims) or one
                -- would silently win, leaving the OTHER mechanic's own
                -- bookkeeping (vehicleState / restState) pointing at a state
                -- that is no longer true. Checked HERE, before
                -- requestEnterKennel is ever sent, for the same reason
                -- client/vehicle.lua's own kennel-rest guard is checked
                -- before its seat claim is requested: server/kennel.lua's
                -- requestEnterKennel writes KennelOccupants[citizenid]
                -- IMMEDIATELY, before this client ever attaches anything --
                -- an occupancy claim taken and then abandoned here would
                -- have NO timeout at all (unlike client/vehicle.lua's own
                -- 10s VEHICLE_SEAT_CLAIM_TTL_MS backstop), so it must never
                -- be requested in the first place while already in a
                -- vehicle, not merely refused after the fact.
                --
                -- Soft dependency, this resource's established convention --
                -- see the canInteract mirror above for the same guard.
                if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
                    lib.notify({ title = locale('common.notify_title'), description = locale('combat.blocked_by_vehicle'), type = 'error' })
                    return
                end
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                TriggerServerEvent('qbx_k9unit:server:requestEnterKennel', netId)
            end,
        },
        {
            name = 'qbx_k9unit:exitKennel',
            icon = 'fas fa-dog',
            label = locale('kennel.exit_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            -- GATE THE START OF A THING, NEVER THE STOP: this is the exact
            -- client-side half of server/kennel.lua's own requestExitKennel
            -- handler (that file's event 7' doc comment: "NEVER gated on
            -- Config.Features.DeployableKennel... or anything else outside
            -- the occupant's own citizenid"). ReleaseKennelRest itself is
            -- already unconditional (see its own doc comment) and does not
            -- read this flag either -- rereading it here bought nothing but
            -- a way for a future live config push to hide this option out
            -- from under a still-attached occupant and strand them inside
            -- the prop. No flag check belongs on an exit path.
            canInteract = function(entity, distance, coords, name)
                return IsRestingInKennel() and ResolveKennelFromRestState() == entity
            end,
            -- Calls the SAME ExitKennelRest() global client/keybinds.lua's
            -- k9exitkennel command/keybind and client/radial.lua's "Exit
            -- Kennel" item now also call (THIS PASS) -- never a second,
            -- independent copy of the release call. See ExitKennelRest()'s
            -- own doc comment above.
            onSelect = function()
                ExitKennelRest()
            end,
        },
        -- CLOSEABLE KENNEL, ox_target surface (owner-directed audit finding,
        -- THIS PASS -- "Allow the kennel to close" already had a chat
        -- command (/k9kennel close|open) and the contextual radial item, but
        -- NO ox_target option at all, unlike every other kennel action here.
        -- Reuses RequestCloseKennelDoor()/RequestOpenKennelDoor() (above)
        -- UNMODIFIED -- no new permission check invented, this file's own
        -- established "no client-side gate beyond 'is there a kennel to act
        -- on at all'" posture for those two functions, and real
        -- authorization (owner OR current occupant) is entirely server-side
        -- (server/kennel.lua's ResolveAuthorizedKennelForDoorToggle) --
        -- matching VISIBILITY VS. AUTHORIZATION above, a bystander with no
        -- relationship to this specific kennel sees the option too and gets
        -- a clean `kennel.door_not_authorized` notify on select, never a
        -- security issue.
        --
        -- WHY canInteract COMPARES THE TARGETED entity TO
        -- ResolveKennelNetIdForDoorAction()'s RESULT, NOT JUST "is the
        -- feature on" like Pick Up/Rest In Kennel above: those two options
        -- act on WHATEVER kennel prop the player is actually looking at
        -- (onSelect reads `data.entity`'s own netId), so any nearby kennel
        -- is a valid target for them. RequestCloseKennelDoor()/
        -- RequestOpenKennelDoor() do NOT take an entity/netId argument --
        -- they resolve WHICH kennel to act on from this client's own LOCAL
        -- STATE (myKennelNetId first, else restState -- see
        -- ResolveKennelNetIdForDoorAction()'s own doc comment). Without this
        -- check, a player standing near a STRANGER's kennel while their own
        -- kennel sits deployed somewhere else entirely would see "Close
        -- Kennel" on the stranger's prop, click it, and silently toggle
        -- THEIR OWN, completely different kennel instead of the one they
        -- are actually looking at -- a real correctness bug, not just a
        -- cosmetic one, even though it can never be a security issue (the
        -- server independently re-resolves ownership from whatever netId is
        -- actually sent). Mirrors the "Exit Kennel" option's own
        -- `ResolveKennelFromRestState() == entity` guard immediately above,
        -- applied to ResolveKennelNetIdForDoorAction() instead of
        -- restState -- same shape, same reason: only show the option on the
        -- EXACT kennel instance the resolve-first helper would actually act
        -- on, never a same-model lookalike elsewhere in the world.
        --
        -- NOT excluded while IsRestingInKennel() -- see server/kennel.lua's
        -- own "CLOSEABLE KENNEL" header ("WHO MAY OPEN/CLOSE: the kennel's
        -- OWNER... OR the CURRENT OCCUPANT"): an occupant resting inside is
        -- exactly as entitled to toggle the door as the owner standing
        -- outside, and ResolveKennelNetIdForDoorAction() already falls back
        -- to restState.kennelNetId for precisely that case.
        --
        -- EXCLUDED while IsCarryingKennel(), matching "Pick Up Kennel"'s own
        -- exclusion above -- there is no sensible reason to toggle the door
        -- of a kennel currently slung over this player's own shoulder, and
        -- excluding it here avoids ever presenting the option on an object
        -- that is, for the moment, attached to this player's own hands
        -- rather than sitting in the world.
        --
        -- THIS IS THE START OF A TOGGLE, NOT AN EXIT PATH -- gating it is
        -- correct and does not touch the "GATE THE START, NEVER THE STOP"
        -- rule the "Exit Kennel" option and ExitKennelRest() itself are
        -- built around: this option can never be the occupant's only way
        -- out (that is, and remains, the separate "Exit Kennel" option /
        -- ExitKennelRest() / the k9exitkennel keybind / the radial "Exit
        -- Kennel" item, all completely untouched by this addition, all
        -- still reading no field of this option's own gating at all).
        {
            name = 'qbx_k9unit:closeKennel',
            icon = 'fas fa-lock',
            label = locale('kennel.close_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.DeployableKennel then return false end
                if IsCarryingKennel() then return false end
                local netId = ResolveKennelNetIdForDoorAction()
                return netId ~= nil and ResolveNetworkEntity(netId) == entity
            end,
            onSelect = function()
                RequestCloseKennelDoor()
            end,
        },
        -- Symmetric to "Close Kennel" immediately above -- see that item's
        -- own doc comment for the full reasoning, identical here in every
        -- respect except which door-action global it calls. Both options
        -- are shown together regardless of the kennel's ACTUAL current
        -- open/closed state (this client has no reliable local knowledge of
        -- that -- see server/kennel.lua's own "CLIENT-SIDE VISIBILITY GAP"
        -- header paragraph for why even the bare '/k9kennel' contextual
        -- dispatch needs a real server round trip to know) -- picking the
        -- "wrong" one of the two costs nothing but a clean
        -- `kennel.already_closed`/`kennel.already_open` notify, the exact
        -- same "canInteract is a UX convenience only" tolerance this file's
        -- header already states for every option in this block.
        {
            name = 'qbx_k9unit:openKennel',
            icon = 'fas fa-lock-open',
            label = locale('kennel.open_target_label'),
            distance = Config.DeployableKennel.interactDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.DeployableKennel then return false end
                if IsCarryingKennel() then return false end
                local netId = ResolveKennelNetIdForDoorAction()
                return netId ~= nil and ResolveNetworkEntity(netId) == entity
            end,
            onSelect = function()
                RequestOpenKennelDoor()
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterKennelOxTargetOption()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterKennelOxTargetOption()
    end
end)

end -- if Config.Features.DeployableKennel -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
