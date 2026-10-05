--[[
    john-k9/server/fetch.lua

    Config.Features.FetchMechanic (DEVELOPER_REFERENCE.md §6.7: "dog can pick up, carry
    (attached to mouth bone), and drop a physics prop ... on a handler
    command"). Ships `false`.

    ======================================================================
    SHARED BONE-INDEX SURFACE — COORDINATION NOTE (read before touching
    mouth-carry): the mouth/jaw bone-attach question this feature needs was
    the SAME unsolved problem `PropAttachments` (client/propattachment.lua,
    server/propattachment.lua) hit for its own vest/harness anchor —
    `AttachEntityToEntity` needs a raw bone INDEX, not a documented NAME, and
    no name was ever found for an `a_c_*` quadruped skeleton across three
    research passes. `server/bonetool.lua`'s dev-only `/k9bonetool` sweep
    tool (built concurrently, this same task round) is the one, shared
    answer to that question for BOTH features — see that file's own
    "EXPOSED SURFACE FOR FetchMechanic" header note. This pass does NOT
    build a second sweep tool. Per that coordination and per
    client/propattachment.lua's own shipped, simpler convention (a single
    flat `boneIndex` + offsets, not a per-`Config.Peds`-model table — a
    deliberate departure from an earlier DEVELOPER_REFERENCE.md draft's more
    elaborate `Config.K9BoneIndices[model]` sketch, superseded by what
    actually shipped), this feature's own mouth-carry config mirrors that
    same flat shape: `Config.FetchMechanic.mouthBoneIndex` (defaults to `0`,
    the root bone — a harmless, always-valid attach point, not a crash) plus
    `mouthOffsetX/Y/Z`, and `Config.FetchMechanic.mouthCarryMode` ('fake' by
    default, 'attach' only once a developer's own `/k9bonetool` session
    confirms a real mouth/jaw index and records it here). See
    client/fetch.lua's own header for the client-side half of this
    coordination (it reuses client/propattachment.lua's shared
    `AttachPropToOwnPed`/`DetachAndDeleteProp` mechanic directly, per that
    file's own documented cross-feature contract, rather than a third
    hand-rolled `AttachEntityToEntity` call).

    ======================================================================
    WHY THE THROWER, NOT AN AUTONOMOUS DOG, DOES THE "RETURN TO HANDLER" LEG:
    this resource's entire architecture (DEVELOPER_REFERENCE.md §1/§2, config.lua's own
    history note on the removed spawn/despawn/registry concept) is that the
    K9 IS a player's own persistent, player-CONTROLLED character — there is
    no NPC dog for a script to path-find around, and no precedent anywhere
    in this codebase for a script driving a connected player's own ped
    movement without their input (DEVELOPER_REFERENCE.md's own "Pursue: zero
    scripting" finding, already reached independently for the throw→pickup
    leg, applies identically here). A literal, scripted "K9 walks itself
    back to the handler" would mean hijacking a live player's controls —
    out of bounds for this codebase. This file instead gives the CARRYING
    K9 player a real, bounded, server-validated "Deliver to Handler" action
    (`requestDeliverFetchBall` below): the player walks back under their own
    control (exactly like the pickup leg), then explicitly hands the item
    off once genuinely in proximity to the player who threw it. This
    satisfies the full command→move→pick up→return→release cycle as a real,
    terminating, player-driven loop rather than a scripted one.

    ======================================================================
    STATE MACHINE — FetchBalls[throwerCitizenId] = {
        netId: number,        -- during the brief 'attach'-mode pickup
                               -- transition (see PendingFetchCarries) this is
                               -- STALE: it still names the OLD, already-
                               -- client-deleted entity until
                               -- confirmFetchBallCarried overwrites it with
                               -- the new mouth-attached replacement's netId.
                               -- It is NEVER actually nil'd out for this
                               -- window (see requestPickupFetchBall's own
                               -- comment) — `PendingFetchCarries[carrierSrc]`
                               -- being present is the ONLY correct way to
                               -- test "still mid-transition, nothing real
                               -- confirmed yet"; do not use `not ball.netId`
                               -- as a proxy for that (a prior version of the
                               -- playerDropped handler did exactly that and
                               -- it was dead code — see that handler's own
                               -- comment).
        state: 'thrown' | 'carried' | 'dropped',
        throwerSrc: number,
        carrierSrc: number?, carrierCitizenId: string?, mode: 'attach'|'fake'|nil,
        createdAt: number,    -- GetGameTimer() at throw-confirm time
        expiresAt: number,    -- createdAt + maxBallLifetimeMs -- ABSOLUTE,
                               -- never extended by a pickup/drop/carry
                               -- transition -- see the maintenance thread
                               -- below, this feature's "no unbounded trap"
                               -- guarantee (task requirement, mirrors
                               -- DEVELOPER_REFERENCE.md §12.0 item 4's maxDurationMs/
                               -- maxDragDistance precedent).
    }
    CarrierIndex[carrierSrc] = throwerCitizenId -- reverse lookup; release/
        deliver/death-report/disconnect all arrive keyed by the CARRIER's own
        source, but FetchBalls is keyed by the THROWER's citizenid.
    PendingFetchThrows[throwerCitizenId] = { src, expiresAt } -- mirrors
        server/kennel.lua's PendingKennelPlacements exactly.
    PendingFetchCarries[carrierSrc] = { throwerCitizenId, expiresAt } --
        'attach'-mode pickup only: the carrier's client must delete the old
        (thrown/dropped) entity and report a freshly `AttachPropToOwnPed`-
        created replacement's netId before the carry is fully confirmed.
    PendingFetchDrops[carrierSrc] = { throwerCitizenId, expiresAt } --
        'fake'-mode drop only: the carrier's client recreates a plain,
        unattached ball object at drop time and must report ITS netId.
    Every one of the four tables above is bounded by its own TTL, swept by
    the maintenance thread below — no table entry can outlive its own
    expiry unanswered, closing the "must always terminate" requirement for
    every transitional (not just terminal) state.

    ======================================================================
    ENTITY-THEFT / TRUST-BOUNDARY DISCIPLINE (task-mandated): no handler in
    this file ever attaches, deletes, or otherwise trusts a client-supplied
    netId on its own say-so. Every netId this file acts on is independently
    (a) resolved via server/entities.lua's `ResolveNetworkEntity` (existence
    guard, expectedEntityType = 3 = object), (b) checked against
    `FetchBallModelHashes` (the configured ball prop, never an arbitrary
    streamed-in entity — same shape client/kennel.lua's `removeKennel`
    handler already established and this file mirrors), AND (c), for the
    pickup/deliver paths specifically, cross-checked for EQUALITY against
    this file's OWN authoritative `FetchBalls` registry entry — mirroring
    server/kennel.lua's `requestPickupKennel`'s `kennel.netId ~= netId`
    ownership check, one step stronger than (a)+(b) alone.

    ======================================================================
    EVENT CONTRACT:
    Server events (client->server):
      requestThrowFetchBall ()
      confirmFetchBallThrown (netId)
      cancelFetchThrow ()
      requestPickupFetchBall (netId)
      confirmFetchBallCarried (netId)      -- 'attach'-mode pickup only
      cancelFetchCarryAttach ()             -- 'attach'-mode pickup only
      releaseFetchBall ()                   -- voluntary drop, no access gate
      confirmFetchBallDropped (netId)       -- 'fake'-mode drop only
      requestDeliverFetchBall (targetServerId)
      requestRecallFetchBall ()             -- thrower ends their own cycle early
      reportFetchCarrierDown ()             -- carrier's own client reports its ped died mid-carry
    Client events (server->client), each gated at REGISTRATION in
    client/fetch.lua, not inside the handler (client/hud.lua's own
    established convention — see that file's header):
      throwFetchBallAt (spawnX, spawnY, spawnZ, forceX, forceY, forceZ) [thrower only]
      carryFetchBall (netId, mode) [carrier only]
      endFetchCarry (mode, terminal) [carrier only]
      removeFetchBall (netId) [broadcast backstop, mirrors client/kennel.lua's removeKennel]

    FILE-TO-FILE CONTRACT:
    - Loads after server/cooldowns.lua (NewCooldown), server/entities.lua
      (ResolveNetworkEntity), and server/certifications/ (HasK9Access,
      IsConfiguredK9Model) — all called at file-load and/or runtime.
    - Exposes no resource-global functions of its own; nothing else in this
      codebase needs to reach into FetchMechanic's own state.

    CONFIG THIS FILE ASSUMES EXISTS — NOT owned by this file (config.lua/
    fxmanifest.lua/.luacheckrc are owned by the task's orchestrator this
    pass; see this pass's own report for the exact blocks needed):
      Config.FetchMechanic = {
        ballPropModel, throwForwardOffsetMeters, throwUpOffsetMeters,
        throwForceForward, throwForceUp, throwCooldownMs, pendingThrowTtlMs,
        maxBallLifetimeMs, pickupInteractDistanceMeters,
        deliverProximityMeters, maintenanceIntervalMs,
        mouthCarryMode, mouthBoneIndex, mouthOffsetX, mouthOffsetY, mouthOffsetZ,
        pickupCooldownMs, -- OPTIONAL; PickupCooldown below falls back to
          -- an in-file default (500ms) if absent OR invalid (non-positive/
          -- NaN/non-number), via ResolveConfiguredThresholdMs
          -- (server/cooldowns.lua) — so this file never errors on a
          -- config.lua that predates this hardening pass, AND never errors
          -- on an operator setting this to 0 meaning "no cooldown" either —
          -- see that local's own comment. (`releaseCooldownMs` is no longer
          -- read at all; see releaseFetchBall's doc comment for why its
          -- gate was removed rather than kept with a defensive default.)
      }

    ======================================================================
    GLOBAL NETID-UNIQUENESS INVARIANT (red-team hardening pass): at most ONE
    `FetchBalls[citizenid]` entry may ever have `.netId == N` for any given
    network id N, at any moment. `FindBallByNetId`'s first-match `pairs`
    scan is only safe to rely on (in confirmFetchBallThrown's "shouldn't be
    reachable" comment, in the pickup/deliver paths' ownership checks, etc.)
    if this invariant actually holds — a scan that can silently return
    either of two colliding entries depending on hash-table iteration order
    is not a substitute for actually preventing the collision. Every place
    that is about to WRITE a client-reported netId into the registry
    (confirmFetchBallThrown creating a new entry; confirmFetchBallCarried
    and confirmFetchBallDropped updating an existing entry's `.netId` field)
    MUST first confirm, via `FindOtherBallByNetId`, that no *other*
    citizenid's entry already claims that netId — otherwise a second
    player can register their own throw/carry/drop confirm against a netId
    that already belongs to someone else's active ball, creating two
    registry entries that both act on the same physical entity (one
    player's recall/delivery/expiry then deletes an entity the other
    player's entry still believes it owns). Do not remove these checks
    without replacing them with an equally strict alternative.

    CROSS-FEATURE EXTENSION OF THIS SAME INVARIANT (coder-architect, this
    pass): `FindOtherBallByNetId` only ever scans THIS file's own
    `FetchBalls` table — it has no visibility into server/kennel.lua's
    `Kennels` or server/propattachment.lua's `PropAttachmentState`, both of
    which share this file's exact `ballPropModel` ('prop_tennis_ball') per
    config.lua. Every one of the three WRITE sites named above (and every
    `safeToCleanup` rejection-branch cleanup gate) now ALSO requires
    server/entities.lua's `not IsNetworkEntityClaimedByOther(netId, 'fetch',
    <citizenid>)` — see each call site's own comment, and
    server/entities.lua's own header section for the full exploit (in both
    its rejection-branch and, more severely, its plain-success-path shapes)
    this closes. `FindOtherBallByNetId` itself is unchanged and stays in
    place, layered underneath the new cross-feature check, not replaced by
    it.
]]

-- GATE AT REGISTRATION, NOT INSIDE THE HANDLER — this file's whole purpose
-- is FetchMechanic, so the entire file is inert (zero handlers registered,
-- zero threads started) while the flag is off, mirroring client/hud.lua's
-- own "checked ONCE at file-load time" convention exactly (see that file's
-- header). Placed before ANY other top-level code, including the model-hash
-- table below, so this file never errors even if Config.FetchMechanic
-- itself doesn't exist yet on a server that hasn't applied this feature's
-- config additions.
if not Config.Features.FetchMechanic then return end

-- Precomputed allowlist of the one configured fetch-ball prop model —
-- task-mandated defense-in-depth, same shape server/kennel.lua's
-- KennelModelHashes already established.
local FetchBallModelHashes = {
    [GetHashKey(Config.FetchMechanic.ballPropModel)] = true,
}

local FetchBalls = {}
local CarrierIndex = {}
local PendingFetchThrows = {}
local PendingFetchCarries = {}
local PendingFetchDrops = {}

-- DEVELOPER_REFERENCE.md item 1 convention: dedicated cooldown, never a
-- hand-rolled table. Per-THROWER rate limit on requesting a NEW throw only
-- — distinct from the one-active-ball-per-citizenid limit enforced
-- separately below.
--
-- ResolveConfiguredThresholdMs (server/cooldowns.lua, this pass, QA sandbox
-- repro — see that file's header ADDENDUM) wraps the raw Config read below
-- rather than handing it straight to NewCooldown: an uncaught non-positive
-- value there would abort THIS FILE's load from that line onward instead of
-- just disabling this one cooldown. Fallback matches config.lua's own
-- shipped default.
local ThrowCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.FetchMechanic.throwCooldownMs, 5000, 'Config.FetchMechanic.throwCooldownMs'))
ThrowCooldown.RegisterPlayerDropped()

-- Red-team hardening: requestPickupFetchBall previously had no rate limit
-- at all (only the initial throw did) — a dedicated NewCooldown tracker,
-- per this file's own DEVELOPER_REFERENCE.md convention, never a hand-rolled
-- table. `Config.FetchMechanic.pickupCooldownMs` is an OPTIONAL tunable not
-- yet in every config.lua.
--
-- THE OLD `Config.FetchMechanic.pickupCooldownMs or 500` IDIOM HERE IS
-- REPLACED, NOT KEPT (this pass, QA sandbox repro): `or 500` only ever
-- guarded the field being ABSENT (nil) — `0 or 500` evaluates to `0` in
-- Lua, since 0 is truthy, so an operator explicitly setting
-- pickupCooldownMs = 0 (meaning "no cooldown", this resource's own
-- repeatedly-documented FOOTGUN) sailed straight through this fallback
-- unchanged and into NewCooldown's constructor guard, which then errored
-- and aborted this entire file's load — the exact inconsistency this pass's
-- audit flagged against ThrowCooldown immediately above, which had no
-- fallback idiom to even give that false impression. ResolveConfiguredThresholdMs
-- correctly treats missing AND non-positive as the same "invalid, use the
-- fallback and warn" case.
local PickupCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.FetchMechanic.pickupCooldownMs, 500, 'Config.FetchMechanic.pickupCooldownMs'))
PickupCooldown.RegisterPlayerDropped()

-- NotifyPlayer used to be defined here as its own local copy (a 13th
-- hand-rolled copy of this exact pattern, landed in this file after
-- DEVELOPER_REFERENCE.md's 12-copy dedup audit was already written -- see
-- server/notify.lua's own header for that audit and the extraction it
-- describes). It is now server/notify.lua's single shared resource-global
-- implementation. Every call site below is unchanged: this file never
-- passed a custom title, which is server/notify.lua's own default.

--- @param src number
--- @return string? citizenid
local function ResolveCitizenId(src)
    local player = exports.qbx_core:GetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid
end

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.FetchMechanic
--- flag) is already checked by the top-of-file gate above, before this
--- function is ever reached. Consulted at BOTH of this feature's two
--- "opening" actions -- requestThrowFetchBall (the thrower starting a new
--- cycle) and requestPickupFetchBall (a K9 starting to carry one) -- never
--- at a termination/continuation step (confirm handlers, cancel handlers,
--- releaseFetchBall, requestDeliverFetchBall, requestRecallFetchBall,
--- reportFetchCarrierDown): those either merely confirm/complete an
--- already-approved action or are the "let go" half of this file's own "no
--- unbounded trap" guarantee and must keep working exactly as
--- this resource's own termination convention documents for the identical reason.
---   2. an explicit block.FetchMechanic grant -> DENY
---   3. FetchMechanic listed in RequireGrant -> ALLOW only with an active
---      feature.FetchMechanic grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsFetchMechanicPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.FetchMechanic') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.FetchMechanic == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.FetchMechanic') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- @param netId number
--- @return string? citizenid
--- @return table? ball
local function FindBallByNetId(netId)
    for citizenid, entry in pairs(FetchBalls) do
        if entry.netId == netId then
            return citizenid, entry
        end
    end
    return nil, nil
end

--- Enforces this file's header GLOBAL NETID-UNIQUENESS INVARIANT. Returns
--- the citizenid of a DIFFERENT registry entry that already claims `netId`,
--- if one exists — `excludeCitizenId` lets a caller that is re-confirming/
--- updating its OWN entry's netId (confirmFetchBallCarried,
--- confirmFetchBallDropped) not treat its own prior value as a collision.
--- Every write of a client-reported netId into `FetchBalls` must be
--- guarded by this returning nil first.
--- @param netId number
--- @param excludeCitizenId string?
--- @return string? otherCitizenId
local function FindOtherBallByNetId(netId, excludeCitizenId)
    for citizenid, entry in pairs(FetchBalls) do
        if citizenid ~= excludeCitizenId and entry.netId == netId then
            return citizenid
        end
    end
    return nil
end

--- Shared terminal-cleanup path — every way a fetch cycle can permanently
--- end (recall, lifetime expiry, despawn detection, handler disconnect,
--- fake-mode carrier loss) funnels through here so there is exactly one
--- place that clears the registry, deletes the entity, and notifies the
--- carrier. Mirrors server/kennel.lua's RemoveKennelForCitizenid role.
--- @param citizenid string
--- @param ball table
local function EndFetchCycle(citizenid, ball)
    FetchBalls[citizenid] = nil

    if ball.carrierSrc then
        CarrierIndex[ball.carrierSrc] = nil
        PendingFetchCarries[ball.carrierSrc] = nil
        PendingFetchDrops[ball.carrierSrc] = nil
    end

    if ball.netId then
        -- Releases this citizenid's claim on ball.netId in the shared
        -- cross-feature registry (server/entities.lua) so the netId can be
        -- legitimately reused/reclaimed afterward without tripping
        -- IsNetworkEntityClaimedByOther for anyone else -- a no-op if this
        -- exact (feature, ownerId) pair never held the claim.
        ReleaseNetworkEntity(ball.netId, 'fetch', citizenid)
        local entity = ResolveNetworkEntity(ball.netId)
        if entity then
            DeleteEntity(entity)
        end
        -- Backstop broadcast — see server/kennel.lua's own CLEANUP
        -- CONFIDENCE NOTE for the full "whichever connected client
        -- currently holds real network ownership" reasoning, not
        -- re-derived here.
        TriggerClientEvent('john-k9:client:removeFetchBall', -1, ball.netId)
    end

    if ball.state == 'carried' and ball.carrierSrc then
        TriggerClientEvent('john-k9:client:endFetchCarry', ball.carrierSrc, ball.mode, true)
    end
end

--- Step 1: handler asks to throw a fetch ball. A HUMAN HANDLER action per
--- DEVELOPER_REFERENCE.md's own "on a handler command" wording — deliberately gated on
--- `HasK9Access(src)` ALONE, not also `IsConfiguredK9Model`, since the
--- thrower need not currently be riding a K9 model (DEVELOPER_REFERENCE.md
--- §14.4.3's own resolved design; this file calls HasK9Access directly
--- rather than adding a same-shape `CanActAsK9Handler()` combinator to
--- client/main.lua, since `HasK9Access` alone is exactly what that would
--- have returned).
RegisterNetEvent('john-k9:server:requestThrowFetchBall', function()
    local src = source

    if not HasK9Access(src) then
        NotifyPlayer(src, locale('fetch.not_authorized_equipment'), 'error')
        return
    end

    local citizenid = ResolveCitizenId(src)
    if not citizenid then
        NotifyPlayer(src, locale('common.unable_to_resolve_citizenid'), 'error')
        return
    end

    -- PER-PERSON FEATURE CONTROL -- see IsFetchMechanicPermittedForCitizenId
    -- above. Checked BEFORE ThrowCooldown.Consume below, matching
    -- server/pursuitsprint.lua's own "cheapest/no-side-effect checks first"
    -- discipline, so a blocked handler never burns their own throw cooldown
    -- for a request that was always going to be refused.
    if not IsFetchMechanicPermittedForCitizenId(citizenid) then
        NotifyPlayer(src, locale('fetch.not_authorized_equipment'), 'error')
        return
    end

    if not ThrowCooldown.Consume(src) then
        return -- silent no-op: rate-limited, matches this resource's bark/leash-request/certify-action convention
    end

    if FetchBalls[citizenid] then
        NotifyPlayer(src, locale('fetch.already_active_ball'), 'error')
        return
    end
    if PendingFetchThrows[citizenid] then
        NotifyPlayer(src, locale('fetch.throw_in_progress'), 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    local coords = GetEntityCoords(ped)

    -- NOT GetEntityForwardVector(ped) — CONFIRMED BROKEN SERVER-SIDE. See
    -- server/kennel.lua's requestDeployKennel handler for the full FXServer-
    -- source-level writeup (GET_ENTITY_FORWARD_VECTOR has no registered
    -- server-side native handler and silently resolves to vector3(0,0,0)
    -- forever, never erroring) — not re-derived here, same root cause, same
    -- fix. That comment flagged this exact call site (server/fetch.lua:345)
    -- as sharing the identical bug, worse here since the dead vector fed
    -- BOTH the spawn offset and the throw force: every ball has always
    -- spawned exactly on the thrower's own feet with zero horizontal
    -- impulse, dropping straight down.
    --
    -- Substitute: GetEntityHeading(ped) + the same heading->direction trig
    -- kennel.lua uses, not a second hand-rolled approach. `forward` here is
    -- already a unit vector (x = -sin(heading), y = cos(heading), so
    -- x^2+y^2 == 1) — exactly what ApplyForceToEntity (client/fetch.lua)
    -- expects to be scaled by a separate magnitude, mirroring how
    -- throwForwardOffsetMeters below scales the same unit vector for the
    -- spawn-position offset.
    local heading = GetEntityHeading(ped)
    local headingRad = math.rad(heading)
    local forward = { x = -math.sin(headingRad), y = math.cos(headingRad) }
    local cfg = Config.FetchMechanic

    local spawnX = coords.x + forward.x * cfg.throwForwardOffsetMeters
    local spawnY = coords.y + forward.y * cfg.throwForwardOffsetMeters
    local spawnZ = coords.z + cfg.throwUpOffsetMeters

    local forceX = forward.x * cfg.throwForceForward
    local forceY = forward.y * cfg.throwForceForward
    local forceZ = cfg.throwForceUp

    PendingFetchThrows[citizenid] = {
        src = src,
        expiresAt = GetGameTimer() + cfg.pendingThrowTtlMs,
    }

    TriggerClientEvent('john-k9:client:throwFetchBallAt', src, spawnX, spawnY, spawnZ, forceX, forceY, forceZ)
end)

--- Step 2: client reports the network id of the ball it actually created.
--- Deliberately does NOT tightly re-validate the reported position against
--- the server-chosen spawn point (unlike server/kennel.lua's
--- KENNEL_CONFIRM_DISTANCE_TOLERANCE) — a thrown, physics-simulated ball's
--- resting position legitimately moves before this confirm fires, and
--- nothing server-authoritative depends on exactly where it lands
--- (DEVELOPER_REFERENCE.md §14.4.3's own disclosed divergence, adopted verbatim).
---
--- ORPHANED-OBJECT FIX (coder-backend, this pass): every failure branch
--- below now tells `src` — and ONLY `src`, never a broadcast — to reclaim
--- the object it just created, via the same 'john-k9:client:removeFetchBall'
--- event EndFetchCycle already uses (client/fetch.lua's own handler for it
--- already does exactly what's needed here: clear its local
--- myThrownBallNetId if it matches, then independently resolve + model-check
--- + delete). Previously every branch below `return`ed with, at best, a
--- NotifyPlayer toast — the client's own already-created, already-networked
--- object was left with nothing to reclaim it until its own CONFIRM-FAILURE
--- BACKSTOP thread finally acted, up to maxBallLifetimeMs + 15s later (see
--- that thread's own header comment in client/fetch.lua for the full
--- writeup of the gap this closes).
---
--- `safeToCleanup` below is deliberately re-derived FIRST, before ANY of
--- this handler's other business-logic checks run, and reused by every
--- failure branch — never only the branches that happen to already resolve
--- the entity for their own unrelated reasons. It is NOT simply "did the
--- client report something real" — it independently re-proves the netId
--- (a) resolves to a real, currently-existing object, (b) of the configured
--- ball model, AND (c) is not already claimed by a DIFFERENT citizenid's own
--- FetchBalls entry (re-running the same FindOtherBallByNetId check the
--- success path below uses). That third condition is the one that actually
--- matters: without it, a caller could report ANOTHER citizen's real, active
--- fetch ball's netId, deliberately land on a failure branch that does NOT
--- itself re-check ownership (e.g. simply let its own pending throw expire,
--- or have HasK9Access revoked in the meantime), and this handler would
--- otherwise instruct that OTHER citizen's actual ball to be deleted via
--- THIS caller's own client — exactly the class of bug this file's header
--- ENTITY-THEFT/TRUST-BOUNDARY DISCIPLINE block exists to rule out. Every
--- branch that already independently reaches the GLOBAL NETID-UNIQUENESS
--- collision case gets `safeToCleanup == false` for free from this same
--- check, so it never sends a cleanup instruction for an entity this
--- citizenid does not actually own.
--- @param netId number
RegisterNetEvent('john-k9:server:confirmFetchBallThrown', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local pending = PendingFetchThrows[citizenid]
    if not pending or pending.src ~= src then return end
    PendingFetchThrows[citizenid] = nil

    -- See this handler's own doc comment above for why this is derived
    -- FIRST and reused by every failure branch below.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass): `FindOtherBallByNetId`
    -- alone only ever catches a collision against ANOTHER `FetchBalls`
    -- entry -- it has no visibility into server/kennel.lua's `Kennels` or
    -- server/propattachment.lua's `PropAttachmentState`, both of which
    -- share this exact prop model with `FetchBalls` per config.lua (see
    -- this file's header, and server/entities.lua's own CROSS-FEATURE
    -- NETID CLAIM REGISTRY section, for the full writeup). A netId naming
    -- another citizen's real, live kennel/vest is a real object of the
    -- right type/model, never recorded in `FetchBalls` at all, so it used
    -- to read as `safeToCleanup == true` here regardless.
    -- `IsNetworkEntityClaimedByOther` (server/entities.lua) closes that.
    --
    -- PRE-CONFIRMATION-WINDOW FIX (coder-architect, urgent red-team finding
    -- this pass — mirrors server/kennel.lua's own confirmKennelPlaced fix
    -- and server/propattachment.lua's original NETWORK-OWNERSHIP GUARD; see
    -- either one's own comment for the full trace): NEITHER
    -- `FindOtherBallByNetId` NOR `IsNetworkEntityClaimedByOther` can catch a
    -- netId before ITS OWN genuine owner's confirm has ever reached this
    -- server — both are only written on a SUCCESSFUL confirm, and a victim's
    -- client networks its ball via CreateObject well before it finishes
    -- ApplyForceToEntity/NetworkGetNetworkIdFromEntity and actually calls
    -- confirmFetchBallThrown. THIS HANDLER IS STRICTLY WORSE THAN
    -- server/kennel.lua's OWN EQUIVALENT HERE: this event has NO positional
    -- check at all (see this handler's own doc comment above: a thrown,
    -- physics-simulated ball's resting position legitimately moves, so
    -- nothing here compares against the server-chosen spawn point) — so the
    -- THEFT shape (not just the deletion shape) is the reachable-by-default
    -- outcome, needing nothing but the netId and winning the race: an
    -- attacker's own confirm names the victim's real, not-yet-confirmed
    -- ball, passes every check below including model, and lands on the
    -- plain SUCCESS path, `FetchBalls[attacker] = victim's real object`.
    -- `NetworkGetEntityOwner(entity) == src` closes this the same way as
    -- both of those other files' own guards: a networked object is owned,
    -- at creation, by the client that created it, never by a merely-faster
    -- OTHER client that only ever observed its netId over OneSync
    -- replication. Verified server-callable (`.luacheckrc`'s read_globals
    -- entry: apiset `shared`).
    local entity = ResolveNetworkEntity(netId, 3)
    local safeToCleanup = entity ~= nil
        and FetchBallModelHashes[GetEntityModel(entity)]
        and NetworkGetEntityOwner(entity) == src
        and not FindOtherBallByNetId(netId, citizenid)
        and not IsNetworkEntityClaimedByOther(netId, 'fetch', citizenid)

    --- @param message string?
    local function RejectThrow(message)
        if message then
            NotifyPlayer(src, message, 'error')
        end
        if safeToCleanup then
            TriggerClientEvent('john-k9:client:removeFetchBall', src, netId)
        end
    end

    if GetGameTimer() > pending.expiresAt then
        RejectThrow(locale('fetch.throw_timed_out'))
        return
    end

    if not HasK9Access(src) then
        RejectThrow(locale('fetch.not_authorized_equipment'))
        return
    end
    if FetchBalls[citizenid] then -- shouldn't be reachable, but never trust an invariant alone
        RejectThrow(locale('fetch.placement_failed_already_active'))
        return
    end

    if not entity then
        RejectThrow(locale('fetch.placement_failed_unconfirmed'))
        return
    end
    if not FetchBallModelHashes[GetEntityModel(entity)] then
        RejectThrow(locale('fetch.placement_failed_wrong_model'))
        return
    end

    -- GLOBAL NETID-UNIQUENESS INVARIANT (this file's header) — reject a
    -- confirm that names a netId ALREADY claimed by another citizenid's
    -- entry (e.g. someone else's real, already-thrown/carried ball).
    -- `citizenid` is confirmed above to have no entry of its own yet, so
    -- any hit here is necessarily a genuine cross-citizenid collision.
    -- `safeToCleanup` is already `false` in exactly this case (it re-runs
    -- this same check above), so RejectThrow correctly notifies but sends
    -- no cleanup instruction — never delete an entity this citizenid does
    -- not actually own.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass) — THE MORE SEVERE HALF
    -- of this pass's fix, found auditing this exact gate: WITHOUT
    -- IsNetworkEntityClaimedByOther below, a netId naming another citizen's
    -- real, live kennel/vest (never in `FetchBalls`, sharing this exact
    -- model per config.lua) sailed straight through this gate and got
    -- WRITTEN into `FetchBalls[citizenid]` below as if it were this
    -- citizenid's own genuine thrown ball -- no rejection branch needed at
    -- all. The attacker's own very next requestRecallFetchBall (a clean,
    -- ordinary, already-audited call) would then delete the victim's real
    -- kennel/vest via THIS file's own EndFetchCycle.
    --
    -- PRE-CONFIRMATION-WINDOW FIX (coder-architect, urgent red-team finding
    -- this pass): `NetworkGetEntityOwner(entity) ~= src` is ALSO a hard
    -- reject gating this exact write, not just part of `safeToCleanup`
    -- above -- this is the actual outright-theft shape (a victim's
    -- not-yet-confirmed real ball, thrown or otherwise, silently becoming
    -- the attacker's own FetchBalls entry) this pass's finding described as
    -- the DEFAULT outcome for this specific handler, since it has no
    -- positional check at all to accidentally narrow the window.
    if FindOtherBallByNetId(netId, citizenid) or IsNetworkEntityClaimedByOther(netId, 'fetch', citizenid) or NetworkGetEntityOwner(entity) ~= src then
        RejectThrow(locale('fetch.placement_failed_already_tracked'))
        return
    end

    local now = GetGameTimer()
    FetchBalls[citizenid] = {
        netId = netId,
        state = 'thrown',
        throwerSrc = src,
        carrierSrc = nil,
        carrierCitizenId = nil,
        mode = nil,
        createdAt = now,
        expiresAt = now + Config.FetchMechanic.maxBallLifetimeMs,
    }
    -- Records this claim in the shared cross-feature registry so
    -- server/kennel.lua's and server/propattachment.lua's own equivalent
    -- checks can see it too -- see server/entities.lua's own header section.
    ClaimNetworkEntity(netId, 'fetch', citizenid)

    NotifyPlayer(src, locale('fetch.thrown_success'), 'success')
end)

--- Client reports its own throw attempt failed (model never loaded,
--- CreateObject failed) — frees the pending slot immediately.
RegisterNetEvent('john-k9:server:cancelFetchThrow', function()
    local src = source
    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local pending = PendingFetchThrows[citizenid]
    if pending and pending.src == src then
        PendingFetchThrows[citizenid] = nil
    end
end)

--- Step 3: a K9 (own ped model OR the decoupled K9 ROLE required — this
--- leg IS K9-specific, unlike the throw) requests to pick up a specific
--- fetch ball by netId. NEVER trusts the reported netId alone — see this
--- file's header ENTITY-THEFT DISCIPLINE block.
--- @param netId number
RegisterNetEvent('john-k9:server:requestPickupFetchBall', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    if not HasK9Access(src) then
        NotifyPlayer(src, locale('fetch.not_authorized_equipment'), 'error')
        return
    end

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    -- PER-PERSON FEATURE CONTROL -- see IsFetchMechanicPermittedForCitizenId
    -- above. Checked BEFORE PickupCooldown.Consume below, same "cheapest/
    -- no-side-effect checks first" discipline as requestThrowFetchBall
    -- above, so a blocked K9 never burns their own pickup cooldown for a
    -- request that was always going to be refused.
    if not IsFetchMechanicPermittedForCitizenId(citizenid) then
        NotifyPlayer(src, locale('fetch.not_authorized_equipment'), 'error')
        return
    end

    if not PickupCooldown.Consume(src) then
        return -- silent no-op: rate-limited, matches ThrowCooldown's own convention
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end
    -- WIDENED (K9 role/model decoupling, server/appearance.lua): a
    -- caller who holds the decoupled K9 ROLE (HasK9Role) but is not
    -- currently on a configured K9 model may still carry -- see
    -- server/main.lua's CheckLeashEligibility for the identical
    -- `type(...) == 'function'` guard/fail-closed reasoning, applied here
    -- to the CALLER's own ped rather than a counterparty's.
    if not (IsConfiguredK9Model(GetEntityModel(ped)) or (type(HasK9Role) == 'function' and HasK9Role(src))) then
        NotifyPlayer(src, locale('fetch.carry_requires_k9_model'), 'error')
        return
    end

    if CarrierIndex[src] or PendingFetchCarries[src] then
        NotifyPlayer(src, locale('fetch.already_carrying'), 'error')
        return
    end

    local ownerCitizenId, ball = FindBallByNetId(netId)
    if not ball or (ball.state ~= 'thrown' and ball.state ~= 'dropped') then
        NotifyPlayer(src, locale('fetch.not_available_to_pickup'), 'error')
        return
    end

    -- Defense in depth, mirroring server/kennel.lua's confirmKennelPlaced
    -- discipline: independently re-confirm the model, not just the netId
    -- equality check FindBallByNetId already gives.
    local entity = ResolveNetworkEntity(netId, 3)
    if not entity or not FetchBallModelHashes[GetEntityModel(entity)] then
        NotifyPlayer(src, locale('fetch.pickup_unconfirmed'), 'error')
        return
    end

    -- RED-TEAM FIX: server-side proximity re-check. `distance` on the
    -- client's ox_target option (client/fetch.lua) is UI-only and trivially
    -- bypassed by firing this event directly with an arbitrary netId — this
    -- is the actual authority boundary, mirroring requestDeliverFetchBall's
    -- own live GetEntityCoords proximity check below (the in-file
    -- precedent) rather than inventing a new shape. Without this, any K9
    -- anywhere on the map could steal (and, via a subsequent release,
    -- relocate) another citizen's active ball.
    local dist = #(GetEntityCoords(ped) - GetEntityCoords(entity))
    if dist > Config.FetchMechanic.pickupInteractDistanceMeters then
        NotifyPlayer(src, locale('fetch.too_far_to_pickup'), 'error')
        return
    end

    local mode = Config.FetchMechanic.mouthCarryMode == 'attach' and 'attach' or 'fake'

    ball.state = 'carried'
    ball.carrierSrc = src
    ball.carrierCitizenId = citizenid
    ball.mode = mode
    CarrierIndex[src] = ownerCitizenId

    if mode == 'attach' then
        -- Two-phase: client/propattachment.lua's shared AttachPropToOwnPed
        -- always CREATES a new object (it has no "attach this existing
        -- handle" mode) — reused here per this file's header coordination
        -- note rather than hand-rolling a third AttachEntityToEntity call.
        -- The carrier's client deletes the old (thrown/dropped) entity and
        -- must report the freshly attached replacement's netId before this
        -- is fully confirmed. `ball.netId` is left pointing at the OLD,
        -- about-to-be-deleted entity in the meantime, and is NEVER nil'd out
        -- for this window — the maintenance thread's own
        -- `ball.state ~= 'carried'` despawn-check guard correctly leaves a
        -- 'carried' ball's stale netId untouched during this window, and a
        -- stale resolve elsewhere degrades to a no-op via
        -- ResolveNetworkEntity's own existence guard. The one place that DID
        -- need to distinguish "confirmed" from "still transitioning" here —
        -- the playerDropped disconnect handler below — must test
        -- `PendingFetchCarries[src]`, not netId nilness, for exactly that
        -- reason (see this file's header STATE MACHINE note and that
        -- handler's own comment).
        PendingFetchCarries[src] = {
            throwerCitizenId = ownerCitizenId,
            expiresAt = GetGameTimer() + Config.FetchMechanic.pendingThrowTtlMs,
        }
    end

    TriggerClientEvent('john-k9:client:carryFetchBall', src, netId, mode)
    NotifyPlayer(src, locale('fetch.picked_up_success'), 'success')
end)

--- 'attach'-mode pickup confirm — see requestPickupFetchBall's own comment.
---
--- STALE-BROADCAST-NETID FINDING, INVESTIGATED AND DELIBERATELY LEFT AS-IS
--- (coder-backend, this pass): both failure branches below call
--- EndFetchCycle while `ball.netId` still names the OLD, pre-pickup entity
--- (this client already deleted it locally back in 'john-k9:client:
--- carryFetchBall' — see requestPickupFetchBall's own comment) rather than
--- the NEW, real, currently-attached replacement this function's own
--- `netId` parameter names. EndFetchCycle's resulting server-side
--- DeleteEntity attempt and its 'john-k9:client:removeFetchBall'
--- broadcast therefore both act on an already-gone entity — a genuine
--- no-op — while the real orphaned object (the new attach) is addressed
--- only by EndFetchCycle's OTHER effect, the terminal
--- 'john-k9:client:endFetchCarry' send to `ball.carrierSrc` (this same
--- `src`), which client/fetch.lua's own endFetchCarry handler deliberately
--- does NOT resolve by re-trusting that broadcast's netId — it deletes its
--- own last-known `ActiveFetchCarry.netId` handle directly instead (see
--- that handler's own "DEFENSE-IN-DEPTH, NOT REDUNDANT" comment, which
--- documents this exact gap and why it closes it that way). That already
--- fully closes the leak in the ordinary case, so this was audited for
--- whether "just write `ball.netId = netId` before calling EndFetchCycle" is
--- a safe tightening anyway — it is NOT, for two different reasons matching
--- this handler's two failure branches:
---   1. Entity/model-mismatch branch: `netId` has not been proven to name
---      anything real or ball-shaped at this point (that is WHY this branch
---      is being taken) — writing an unverified, potentially fabricated
---      client-reported id into `ball.netId` and letting EndFetchCycle act
---      on it would hand a malicious carrier exactly the entity-theft
---      primitive this file's header ENTITY-THEFT/TRUST-BOUNDARY
---      DISCIPLINE block exists to rule out (EndFetchCycle's own
---      ResolveNetworkEntity + DeleteEntity has no model check of its own).
---   2. GLOBAL NETID-UNIQUENESS collision branch: `FindOtherBallByNetId`
---      matching here means this `netId` already legitimately belongs to a
---      DIFFERENT citizenid's own active ball. Writing it into THIS
---      citizenid's `ball.netId` and calling EndFetchCycle would delete and
---      broadcast the removal of that OTHER player's real, currently active
---      fetch ball — turning a same-citizenid cleanup into cross-player
---      griefing. The current stale value is actually the SAFE choice here,
---      not an oversight: it points at an entity this citizenid's own cycle
---      already owns (if now deleted), never at one it doesn't.
--- Conclusion: the staleness here is left unchanged. Flagged back rather
--- than "fixed" into either of the two regressions above.
--- @param netId number
RegisterNetEvent('john-k9:server:confirmFetchBallCarried', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local pending = PendingFetchCarries[src]
    if not pending then return end
    PendingFetchCarries[src] = nil

    if GetGameTimer() > pending.expiresAt then return end -- the maintenance sweep may already have force-ended this cycle

    local ball = FetchBalls[pending.throwerCitizenId]
    if not ball or ball.carrierSrc ~= src or ball.state ~= 'carried' then return end

    local entity = ResolveNetworkEntity(netId, 3)
    if not entity or not FetchBallModelHashes[GetEntityModel(entity)] then
        EndFetchCycle(pending.throwerCitizenId, ball)
        return
    end

    -- GLOBAL NETID-UNIQUENESS INVARIANT (this file's header) — a freshly
    -- AttachPropToOwnPed-created entity should never legitimately collide
    -- with another citizenid's existing entry, but this write is exactly
    -- the kind this file's header invariant exists to guard: end the cycle
    -- rather than let two entries point at the same physical object.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass): `FindOtherBallByNetId`
    -- alone has no visibility into server/kennel.lua's `Kennels` or
    -- server/propattachment.lua's `PropAttachmentState` -- a carrier's
    -- client could report a victim's real, live kennel/vest netId (sharing
    -- this exact model per config.lua) as its own freshly-attached
    -- replacement, and this write would have silently hijacked it into THIS
    -- citizenid's own `ball.netId`, reachable for deletion by any later
    -- release/recall/deliver/expiry. `IsNetworkEntityClaimedByOther`
    -- (server/entities.lua) closes that the same way as every other write
    -- site this pass touched.
    --
    -- PRE-CONFIRMATION-WINDOW FIX (coder-architect, urgent red-team finding
    -- this pass): a victim's OWN not-yet-confirmed real object (kennel,
    -- vest, or another citizen's own thrown/dropped ball) is unclaimed in
    -- EVERY registry above until its genuine owner's own confirm lands --
    -- `entity` is already confirmed non-nil by the guard above, so this is
    -- safe to call unconditionally. `NetworkGetEntityOwner(entity) ~= src`
    -- closes the theft shape the same way as confirmFetchBallThrown's own
    -- identical addition -- see that handler's own comment for the full
    -- trace.
    if FindOtherBallByNetId(netId, pending.throwerCitizenId) or IsNetworkEntityClaimedByOther(netId, 'fetch', pending.throwerCitizenId) or NetworkGetEntityOwner(entity) ~= src then
        EndFetchCycle(pending.throwerCitizenId, ball)
        return
    end

    -- Releases the OLD (pre-pickup, about-to-be-superseded) netId's claim
    -- and claims the NEW one, in the shared cross-feature registry
    -- (server/entities.lua) -- keeps the registry's view of `ball.netId`
    -- always current, exactly mirroring the field assignment on the very
    -- next line.
    ReleaseNetworkEntity(ball.netId, 'fetch', pending.throwerCitizenId)
    ball.netId = netId
    ClaimNetworkEntity(netId, 'fetch', pending.throwerCitizenId)
end)

--- 'attach'-mode pickup failed client-side (model never loaded, or
--- AttachPropToOwnPed otherwise returned nil) — nothing tangible survives
--- this failure (the old entity is already deleted client-side), so the
--- whole cycle must end rather than leaving a 'carried' ball with no real
--- entity behind it.
RegisterNetEvent('john-k9:server:cancelFetchCarryAttach', function()
    local src = source
    local pending = PendingFetchCarries[src]
    if not pending then return end
    PendingFetchCarries[src] = nil

    local ball = FetchBalls[pending.throwerCitizenId]
    if ball and ball.carrierSrc == src then
        EndFetchCycle(pending.throwerCitizenId, ball)
    end
end)

--- Voluntary drop. Deliberately NOT gated on HasK9Access/CanShowK9UI —
--- mirrors DetachLeash/ReleaseBiteHold/ReleaseDrag's established "always
--- let go" posture: a K9 that loses access mid-carry must still be able to
--- end it. Guards against the brief 'attach'-mode pickup transition window
--- (PendingFetchCarries) to avoid racing a not-yet-confirmed attach.
---
--- This handler used to open with a `ReleaseCooldown.Consume(src)` gate,
--- which contradicted the contract stated directly above it. Two reasons it
--- is gone:
---   1. The precedent it names does not have one. server/combat.lua's
---      `releaseBiteHold` is unconditional once ownership is verified —
---      no cooldown of any kind. This handler was the odd one out.
---   2. server/cooldowns.lua's IsOnCooldown treats a non-positive threshold
---      as FAIL CLOSED, deliberately: `<= 0` means "permanently on
---      cooldown", never "no cooldown". That is the right default for a
---      throttle, but it is the wrong one for an escape hatch. An operator
---      setting `releaseCooldownMs = 0` to mean "no throttle" would instead
---      permanently disable voluntary release for every source that had
---      released once — the same shape as the non-positive-cooldown footgun
---      server/cooldowns.lua's own header describes at length.
--- Spam is already bounded without a cooldown: the CarrierIndex lookup
--- below returns early for anyone who is not currently a carrier, so a
--- repeated call after the first release does nothing but a table read.
RegisterNetEvent('john-k9:server:releaseFetchBall', function()
    local src = source

    if PendingFetchCarries[src] then
        return -- still transitioning into the carry itself; nothing to release yet
    end

    local ownerCitizenId = CarrierIndex[src]
    if not ownerCitizenId then return end
    local ball = FetchBalls[ownerCitizenId]
    if not ball or ball.carrierSrc ~= src then
        CarrierIndex[src] = nil -- stale index entry, clean it up defensively
        return
    end

    local mode = ball.mode
    ball.state = 'dropped'
    ball.carrierSrc = nil
    ball.carrierCitizenId = nil
    ball.mode = nil
    CarrierIndex[src] = nil

    if mode == 'fake' then
        -- Nothing tangible exists right now (the world object was deleted
        -- at pickup) — the client must recreate one and report its netId
        -- before this ball is pickup-able again.
        PendingFetchDrops[src] = {
            throwerCitizenId = ownerCitizenId,
            expiresAt = GetGameTimer() + Config.FetchMechanic.pendingThrowTtlMs,
        }
    end

    TriggerClientEvent('john-k9:client:endFetchCarry', src, mode, false)
end)

--- 'fake'-mode drop confirm — the carrier's client recreated a plain,
--- unattached ball object at its own current position and reports its
--- netId so this file's registry stays in sync.
---
--- ORPHANED-OBJECT FIX (coder-backend, this pass): mirrors
--- confirmFetchBallThrown's own fix above — see that handler's doc comment
--- for the full reasoning behind `safeToCleanup` (re-derived FIRST, reused
--- by every failure branch, and why it must independently re-check the
--- GLOBAL NETID-UNIQUENESS INVARIANT before ever sending a cleanup
--- instruction). Every one of this handler's failure branches used to
--- `return` completely silently — not even a NotifyPlayer toast, unlike
--- confirmFetchBallThrown's own equivalents — while the carrier's own
--- client had already created a real, networked replacement ball object
--- moments before calling this event. Deliberately still no NotifyPlayer
--- text added on any branch here: the success path below has never
--- notified either (matches confirmFetchBallCarried's own equally silent
--- convention) — this fix closes the entity leak without changing that
--- established UX choice.
--- @param netId number
RegisterNetEvent('john-k9:server:confirmFetchBallDropped', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local pending = PendingFetchDrops[src]
    if not pending then return end
    PendingFetchDrops[src] = nil

    -- See confirmFetchBallThrown's own doc comment for why this is derived
    -- FIRST and reused by every failure branch below.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass): same
    -- IsNetworkEntityClaimedByOther addition as confirmFetchBallThrown's own
    -- `safeToCleanup` above -- see that handler's own comment for the full
    -- writeup, and server/entities.lua's header for the shared exploit this
    -- closes across all three of this resource's netId-confirm features.
    --
    -- PRE-CONFIRMATION-WINDOW FIX (coder-architect, urgent red-team finding
    -- this pass): same NetworkGetEntityOwner addition as
    -- confirmFetchBallThrown's own `safeToCleanup` above -- see that
    -- handler's own comment for the full trace (neither FindOtherBallByNetId
    -- nor IsNetworkEntityClaimedByOther can catch a netId before its own
    -- genuine owner's confirm has ever reached this server).
    local entity = ResolveNetworkEntity(netId, 3)
    local safeToCleanup = entity ~= nil
        and FetchBallModelHashes[GetEntityModel(entity)]
        and NetworkGetEntityOwner(entity) == src
        and not FindOtherBallByNetId(netId, pending.throwerCitizenId)
        and not IsNetworkEntityClaimedByOther(netId, 'fetch', pending.throwerCitizenId)

    local function RejectDrop()
        if safeToCleanup then
            TriggerClientEvent('john-k9:client:removeFetchBall', src, netId)
        end
    end

    if GetGameTimer() > pending.expiresAt then -- ball table entry may already be gone via recall/timeout
        RejectDrop()
        return
    end

    local ball = FetchBalls[pending.throwerCitizenId]
    if not ball or ball.state ~= 'dropped' then -- recalled/changed state in the meantime
        RejectDrop()
        return
    end

    if not entity or not FetchBallModelHashes[GetEntityModel(entity)] then
        RejectDrop()
        return
    end

    -- GLOBAL NETID-UNIQUENESS INVARIANT (this file's header) — reject if
    -- this freshly-created "recreated ball" object's netId somehow already
    -- matches another citizenid's live entry. `safeToCleanup` is already
    -- `false` in exactly this case, so RejectDrop correctly sends no
    -- cleanup instruction — never delete an entity this citizenid does not
    -- actually own.
    --
    -- CROSS-FEATURE FIX (coder-architect, this pass) — THE MORE SEVERE HALF,
    -- same shape as confirmFetchBallThrown's own success-write gate: without
    -- IsNetworkEntityClaimedByOther, a "recreated ball" report naming a
    -- victim's real, live kennel/vest netId (never in `FetchBalls`, sharing
    -- this exact model) would sail through this gate and get WRITTEN into
    -- `ball.netId` below, reachable for deletion by this citizenid's own
    -- very next release/recall/deliver.
    --
    -- PRE-CONFIRMATION-WINDOW FIX (coder-architect, urgent red-team finding
    -- this pass): same NetworkGetEntityOwner addition as
    -- confirmFetchBallThrown's own pre-write gate -- `entity` is already
    -- confirmed non-nil above, so this is safe to call unconditionally.
    if FindOtherBallByNetId(netId, pending.throwerCitizenId) or IsNetworkEntityClaimedByOther(netId, 'fetch', pending.throwerCitizenId) or NetworkGetEntityOwner(entity) ~= src then
        RejectDrop()
        return
    end

    -- Releases the OLD (pre-drop, about-to-be-superseded) netId's claim and
    -- claims the NEW one -- see confirmFetchBallCarried's own identical
    -- comment above.
    ReleaseNetworkEntity(ball.netId, 'fetch', pending.throwerCitizenId)
    ball.netId = netId
    ClaimNetworkEntity(netId, 'fetch', pending.throwerCitizenId)
end)

--- The "returns to handler and releases" leg — see this file's header for
--- why this is a real, player-driven, proximity-checked action rather than
--- scripted movement. Only deliverable to the ACTUAL thrower of THIS ball,
--- never an arbitrary nearby player, and only within
--- Config.FetchMechanic.deliverProximityMeters of that handler's own live,
--- server-side position (never a client-claimed distance).
--- @param targetServerId number
RegisterNetEvent('john-k9:server:requestDeliverFetchBall', function(targetServerId)
    local src = source
    if type(targetServerId) ~= 'number' then return end

    if PendingFetchCarries[src] then
        return -- still transitioning into the carry itself
    end

    local ownerCitizenId = CarrierIndex[src]
    if not ownerCitizenId then
        NotifyPlayer(src, locale('fetch.not_carrying'), 'error')
        return
    end
    local ball = FetchBalls[ownerCitizenId]
    if not ball or ball.carrierSrc ~= src then return end

    if ball.throwerSrc ~= targetServerId then
        NotifyPlayer(src, locale('fetch.wrong_deliver_target'), 'error')
        return
    end

    local carrierPed = GetPlayerPed(src)
    local handlerPed = GetPlayerPed(targetServerId)
    if carrierPed == 0 or handlerPed == 0 then return end

    local dist = #(GetEntityCoords(carrierPed) - GetEntityCoords(handlerPed))
    if dist > Config.FetchMechanic.deliverProximityMeters then
        NotifyPlayer(src, locale('fetch.too_far_to_deliver'), 'error')
        return
    end

    EndFetchCycle(ownerCitizenId, ball)
    NotifyPlayer(src, locale('fetch.delivered_success'), 'success')
    NotifyPlayer(targetServerId, locale('fetch.delivered_notice_handler'), 'success')
end)

--- Thrower-initiated early termination of their OWN cycle, from any state —
--- an explicit interrupt path independent of the carrier's own release,
--- satisfying the task's "must be interruptible" requirement from the
--- handler's side too.
RegisterNetEvent('john-k9:server:requestRecallFetchBall', function()
    local src = source
    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local ball = FetchBalls[citizenid]
    if not ball or ball.throwerSrc ~= src then
        NotifyPlayer(src, locale('fetch.no_active_ball_to_recall'), 'error')
        return
    end

    EndFetchCycle(citizenid, ball)
    NotifyPlayer(src, locale('fetch.recalled_success'), 'success')
end)

--- Carrier's own client reports its ped died mid-carry (client/fetch.lua's
--- own IsEntityDead poll, only running while actually carrying). 'attach'
--- mode degrades to a natural 'dropped' state (the ball entity still
--- physically exists); 'fake' mode must fully end the cycle (nothing
--- tangible exists to leave behind — the dead ped's own client cannot
--- reliably recreate/report a fresh object the way a normal voluntary drop
--- does).
RegisterNetEvent('john-k9:server:reportFetchCarrierDown', function()
    local src = source

    if PendingFetchCarries[src] then return end -- see releaseFetchBall's own comment

    local ownerCitizenId = CarrierIndex[src]
    if not ownerCitizenId then return end
    local ball = FetchBalls[ownerCitizenId]
    if not ball or ball.carrierSrc ~= src then return end

    local mode = ball.mode
    CarrierIndex[src] = nil

    if mode == 'fake' then
        EndFetchCycle(ownerCitizenId, ball)
        return
    end

    ball.state = 'dropped'
    ball.carrierSrc = nil
    ball.carrierCitizenId = nil
    ball.mode = nil

    TriggerClientEvent('john-k9:client:endFetchCarry', src, mode, false)
end)

-- Single shared maintenance thread — ALWAYS running (mirrors
-- server/combat.lua's own identical "expiry enforcement must never be
-- delayed or conditioned on anything" precedent), but a guaranteed genuine
-- no-op for the lifetime of this file's early-return gate above: every
-- table this loop scans is only ever populated by handlers that already
-- required Config.Features.FetchMechanic to be true (the whole file
-- wouldn't have loaded otherwise). Interval is deliberately independent of
-- any per-tick sampling need — this feature has none — so a coarse
-- interval is both correct and cheap.
-- VALIDATED (audit follow-up — same footgun this file's own ThrowCooldown/
-- PickupCooldown comments above already document and fix for their own
-- fields, missed here): `Config.FetchMechanic.maintenanceIntervalMs or
-- 2000` looks identical to the `Config.FetchMechanic.pickupCooldownMs or
-- 500` idiom this file's own header explicitly calls out as REPLACED, NOT
-- KEPT, for the exact reason it applies here too — `0 or 2000` evaluates to
-- `0` in Lua (0 is truthy), so an operator setting this to 0 would not get
-- "no throttle," they would get `Wait(0)` on the SAME thread this comment
-- block calls the "no unbounded trap" guarantee for a ball nobody ever
-- picks up, drops, delivers, or recalls — a tight busy-loop at best, and a
-- thread-killing throw at worst if the value is ever a non-number instead
-- of 0 (this `or` idiom guards against nil only, never against wrong
-- type), which would silently and permanently disable that entire
-- lifetime-ceiling enforcement for the rest of this resource's uptime.
-- Resolved with ResolveConfiguredThresholdMs (CLAMP AND WARN, never abort),
-- matching ThrowCooldown/PickupCooldown immediately above. Same fallback
-- (2000ms) as config.lua's own shipped default for this field.
local FETCH_MAINTENANCE_INTERVAL_MS = ResolveConfiguredThresholdMs(
    Config.FetchMechanic.maintenanceIntervalMs, 2000, 'Config.FetchMechanic.maintenanceIntervalMs')

CreateThread(function()
    while true do
        Wait(FETCH_MAINTENANCE_INTERVAL_MS)
        local now = GetGameTimer()

        -- (a) Absolute lifetime ceiling — THIS is the "no unbounded trap"
        -- guarantee for a ball nobody ever picks up, drops, delivers, or
        -- recalls, mirroring DEVELOPER_REFERENCE.md §12.0 item 4's maxDurationMs/
        -- maxDragDistance precedent. Checked unconditionally.
        for citizenid, ball in pairs(FetchBalls) do
            if now > ball.expiresAt then
                EndFetchCycle(citizenid, ball)
            elseif ball.netId and ball.state ~= 'carried' then
                -- (b) Despawn/unreachable-target detection: a 'thrown' or
                -- 'dropped' ball should always resolve to a real entity
                -- between confirms. If it doesn't (an external deletion, a
                -- desync, or any other despawn this resource doesn't
                -- control), don't leave a permanently stuck registry entry
                -- around for the rest of maxBallLifetimeMs.
                if not ResolveNetworkEntity(ball.netId) then
                    EndFetchCycle(citizenid, ball)
                end
            end
        end

        -- (c) Bounded transitional-state windows — 'attach'-mode pickup and
        -- 'fake'-mode drop can each get stuck in limbo if the carrier
        -- disconnects or their client errors between the request and its
        -- confirm; these TTLs guarantee that limbo always resolves.
        for carrierSrc, pending in pairs(PendingFetchCarries) do
            if now > pending.expiresAt then
                PendingFetchCarries[carrierSrc] = nil
                local ball = FetchBalls[pending.throwerCitizenId]
                if ball and ball.carrierSrc == carrierSrc then
                    EndFetchCycle(pending.throwerCitizenId, ball)
                end
            end
        end
        for carrierSrc, pending in pairs(PendingFetchDrops) do
            if now > pending.expiresAt then
                PendingFetchDrops[carrierSrc] = nil -- the ball itself, if it still exists, simply stays 'dropped' with its last-known netId — nothing further to force here
            end
        end
        for citizenid, pending in pairs(PendingFetchThrows) do
            if now > pending.expiresAt then
                PendingFetchThrows[citizenid] = nil
            end
        end
    end
end)

-- Handler-disconnect / carrier-disconnect cleanup (task requirement: a
-- fetch cycle must not leak permanently into the world).
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local citizenid = ResolveCitizenId(src)

    -- Thrower (handler) disconnect: end the ENTIRE cycle regardless of
    -- state.
    if citizenid and FetchBalls[citizenid] and FetchBalls[citizenid].throwerSrc == src then
        EndFetchCycle(citizenid, FetchBalls[citizenid])
    end

    if citizenid and PendingFetchThrows[citizenid] and PendingFetchThrows[citizenid].src == src then
        PendingFetchThrows[citizenid] = nil
    end

    -- Carrier disconnect (possibly a DIFFERENT citizenid than the thrower).
    -- 'attach' mode degrades to a natural 'dropped' state (the ball is left
    -- wherever it was — a real, still-existing networked entity); 'fake'
    -- mode must fully end the cycle (nothing tangible exists to leave
    -- behind, and only the now-disconnecting client could ever recreate it)
    -- — see EndFetchCycle's own carrier-loss framing for the identical
    -- reasoning applied to a death report instead of a disconnect.
    --
    -- TWO-PHASE 'attach' TRANSITION FIX (audit finding): the discriminator
    -- for "was this attach-mode pickup ever actually confirmed" must be
    -- `PendingFetchCarries[src]` (captured BELOW before it's cleared), never
    -- `not ball.netId` — `ball.netId` is NEVER nil'd during that transition
    -- (see this file's header STATE MACHINE note), so a prior `not
    -- ball.netId` check here was dead code that always took the "degrade to
    -- dropped" branch, even for a carrier that disconnects mid-transition
    -- (old entity already client-deleted, new mouth-attached entity maybe
    -- never even created, confirm never sent). Left uncorrected, that stale
    -- STILL-'attach'-mode ball would sit in the registry as 'dropped'
    -- pointing at an already-deleted netId — masked in practice only by the
    -- maintenance thread's own despawn re-check (ResolveNetworkEntity
    -- failing on that stale id) picking it up on its next sweep, which is a
    -- coincidental backstop, not correct-by-construction — so this is fixed
    -- at the source instead, exactly like cancelFetchCarryAttach's own
    -- "nothing tangible survives this failure" reasoning for the identical
    -- unconfirmed-transition case.
    local ownerCitizenId = CarrierIndex[src]
    if ownerCitizenId then
        CarrierIndex[src] = nil
        local wasPendingCarryAttach = PendingFetchCarries[src] ~= nil
        PendingFetchCarries[src] = nil
        PendingFetchDrops[src] = nil
        local ball = FetchBalls[ownerCitizenId]
        if ball and ball.carrierSrc == src then
            if ball.mode == 'fake' or wasPendingCarryAttach then
                EndFetchCycle(ownerCitizenId, ball)
            else
                ball.state = 'dropped'
                ball.carrierSrc = nil
                ball.carrierCitizenId = nil
                ball.mode = nil
            end
        end
    end

    -- ThrowCooldown/PickupCooldown each already registered their own
    -- playerDropped handler via :RegisterPlayerDropped() —
    -- DEVELOPER_REFERENCE.md item 1 convention, nothing to do for them here.
end)

-- Resource-stop cleanup (task requirement, same class of gap
-- server/kennel.lua's own onResourceStop comment addresses for a different
-- piece of entity state): a resource restart must not leave any active
-- fetch ball behind as a permanent, orphaned world object.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, ball in pairs(FetchBalls) do
        if ball.netId then
            local entity = ResolveNetworkEntity(ball.netId)
            if entity then
                DeleteEntity(entity)
            end
        end
    end
    -- Deliberately no client broadcast here — every connected client's own
    -- copy of this resource is stopping at essentially the same moment,
    -- mirroring server/kennel.lua's own onResourceStop reasoning verbatim
    -- (see that file's header for the full "unreliable busywork, not a real
    -- backstop" writeup), not re-derived here.
end)
