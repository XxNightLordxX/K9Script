--[[
    john-k9/server/propattachment.lua

    Config.Features.PropAttachments (still `false` by default — see
    config.lua's own "ship disabled until acceptance criteria are fully
    met" convention). A certified handler, while their OWN character is a
    recognized K9 model, may toggle a visible cosmetic prop (a vest/harness)
    attached to their own ped, visible to everyone. NEW FILE PAIR (this file
    + client/propattachment.lua), not folded into server/kennel.lua or
    server/main.lua — same "one responsibility per file" convention those
    two files' own headers already establish; a prop-attach registry is a
    different lifecycle/ownership shape than a placed world object (kennel)
    or a small stateless relay (main.lua's bark/door-scratch).

    ======================================================================
    THE RESEARCH BLOCKER AND THE REFRAME (read before touching boneIndex
    anywhere in this file or config.lua's Config.PropAttachments):
    AttachEntityToEntity takes a bone INDEX, not a name — no documented bone
    NAME exists for a quadruped/animal skeleton in this codebase's own
    research, and none of this resource's existing combat/drag code needed
    one either (client/combat.lua's PropDragging attach call already uses a
    bare numeric bone index, 0, against a PLAYER ped for exactly this
    reason). The correct way to find the RIGHT index for "on the K9's back"
    is an in-engine visual sweep, not more documentation searching — see
    client/bonetool.lua / server/bonetool.lua, the dev-only tool built
    alongside this feature specifically to answer that question on a real
    dev server. Config.PropAttachments.boneIndex defaults to 0 (the root
    bone — present on virtually any skeleton) so an unconfirmed value
    degrades to "attached at the wrong point, visibly wrong," never a
    crash — see this file's own model/attach validation below for why a bad
    boneIndex can never become a security or entity-leak problem either.
    ======================================================================

    ======================================================================
    WHY THIS NEVER ACCEPTS A CLIENT-CLAIMED TARGET PED, UNLIKE KENNEL'S
    PICKUP/CONFIRM FLOW: every action in this file operates ONLY on the
    calling player's OWN ped, resolved server-side via GetPlayerPed(source)
    — there is no "attach to netId X" event anywhere in this contract, and
    no such event should ever be added without re-deriving this reasoning.
    This is a STRONGER posture than server/kennel.lua's own
    confirmKennelPlaced (which has to accept a client-claimed netId because
    a kennel is a brand-new object with no pre-existing entity to anchor to)
    — here there IS a pre-existing entity to anchor to (the caller's own
    ped), so accepting a claimed netId for it at all would be an unforced
    trust boundary this file simply does not create. The one place a netId
    IS accepted from the client (confirmPropAttached below) is the object
    the CLIENT just created in response to this file's own instruction —
    and even then, this file does not trust that claim blindly: see
    HandleConfirmPropAttached's defense-in-depth checks (model allowlist +
    live-position tolerance against the caller's own ped, mirroring
    server/kennel.lua's KENNEL_CONFIRM_DISTANCE_TOLERANCE pattern) before
    that netId is ever stored in `PropAttachmentState` (and therefore ever
    reachable by a future DeleteEntity call).
    ======================================================================

    ======================================================================
    FIRST-WRITER-WINS PROP-HIJACK RACE — FOUND AND CLOSED: the GLOBAL
    NETID-UNIQUENESS GUARD below (FindOtherPropAttachmentByNetId) only
    rejects a netId ALREADY present in `PropAttachmentState` — i.e. only
    ever catches a collision against an entry some EARLIER confirm already
    wrote. It has no way to stop a SECOND, certified handler standing
    within Config.PropAttachments.confirmDistanceTolerance of a FIRST
    handler who is mid-handshake (server already told them to
    attachK9Prop; their client already created+attached a REAL networked
    object; their own confirmPropAttached has not yet reached this server)
    from observing that real object appear nearby — ordinary OneSync
    entity-relevance replication, independent of and frequently faster
    than the FIRST handler's own queued TriggerServerEvent actually
    arriving here — and racing their OWN confirmPropAttached in FIRST,
    reporting the FIRST handler's genuine netId as their own. Model and
    position both pass (it really is a configured prop, really within
    tolerance of the SECOND handler, who simply chose to stand close) —
    proximity alone can never tell "this is genuinely my own object" apart
    from "I am standing near someone else's". Before the fix below, that
    bogus SECOND-handler confirm landed FIRST and therefore won the GLOBAL
    NETID-UNIQUENESS check outright (nothing had claimed the netId yet),
    and the FIRST handler's own, entirely legitimate, later confirm was
    the one that then hit "already tracked" and was rejected — sending
    THEM 'john-k9:client:rejectK9PropAttach', which deletes THEIR OWN
    real, just-created object. A guard built to stop a hijack had inverted
    into a denial-of-service against the genuine owner instead.
    THE FIX — HandleConfirmPropAttached's NETWORK-OWNERSHIP GUARD (see that
    function's own comment for the full trace and native-verification
    notes): every confirm that has already passed the model+position checks
    must additionally prove the caller is the reported entity's own CURRENT
    OneSync network owner (NetworkGetEntityOwner(entity) == src), BEFORE the
    GLOBAL NETID-UNIQUENESS check and the final registry write. Since
    a networked object is owned by the client that created it (this
    feature's own client/propattachment.lua AttachPropToOwnPed call), the
    SECOND handler's bogus confirm now fails at THIS check — before it can
    ever write into `PropAttachmentState` — regardless of which of the two
    confirms' own network messages happens to reach this server first. The
    FIRST handler's later, genuine confirm therefore never encounters
    anything already claiming their netId at all: the race is closed at its
    root (the bogus write can no longer happen), not papered over after the
    fact.
    ======================================================================

    EVENT/CALLBACK CONTRACT:
    Server events (RegisterNetEvent, client->server):
    1. 'john-k9:server:requestToggleK9PropAttachment' () [THIS FILE]
       No arguments — see "WHY THIS NEVER ACCEPTS" above. If the caller
       currently has an active attachment on record, this is a REMOVE
       (immediate, no round trip needed — nothing to confirm when taking
       something off). Otherwise this is an ADD: validates flag/access/own
       model/cooldown, opens a short-lived pending slot, and instructs the
       SAME client to create+attach the prop to its own ped (event 3).
    2. 'john-k9:server:confirmPropAttached' (netId: number) [THIS FILE]
       Client reports the network id of the object it actually created in
       response to event 3. Re-validates everything event 1 already
       checked, PLUS the object's model (allowlist), live position
       (tolerance against the caller's own live ped coords), AND that the
       caller is the object's own CURRENT OneSync network owner — see
       HandleConfirmPropAttached's own NETWORK-OWNERSHIP GUARD comment for
       why position+model tolerance alone cannot distinguish "this is
       genuinely my own object" from "I am simply standing near someone
       else's".
    3. 'john-k9:server:cancelPropAttachRequest' () [THIS FILE]
       Client reports its own attach attempt failed (model never loaded) —
       frees the pending slot immediately, mirrors
       server/kennel.lua's 'john-k9:server:cancelKennelPlacement'.
    4. 'john-k9:server:reportOwnK9PropAttachDeath' () [THIS FILE]
       Self-report: "my own ped, which currently owns an active prop
       attachment, just died." Self-reported facts about the reporting
       player's OWN state are an already-accepted trust category in this
       resource (server/tracking.lua's relayDamageEvent/relayWeaponFire —
       "victim/shooter reports their own event" — and
       server/wellbeing.lua's consumption of those same relays); the worst
       a lie here can do is remove the reporter's OWN cosmetic attachment
       early, which is not a security-relevant outcome. Re-verifies
       ownership (PropAttachmentState[citizenid].ownerSrc == src) before
       acting regardless.

    Client events (RegisterNetEvent, server->client), both sent ONLY to the
    one client the action concerns, never broadcast:
    5. 'john-k9:client:attachK9Prop' () [client/propattachment.lua]
       Instruction: create+attach the configured prop to your OWN ped, then
       report its netId back via event 2.
    6. 'john-k9:client:rejectK9PropAttach' () [client/propattachment.lua]
       This file rejected a confirm (event 2) after the client already
       created+attached something locally — tells that client to undo it.
    7. 'john-k9:client:removeK9PropAttachment' (netId: number)
       [client/propattachment.lua] — broadcast (-1) cleanup backstop for a
       removal (manual toggle-off, disconnect, resource stop, or a death
       report), same CLEANUP CONFIDENCE NOTE/reasoning as
       server/kennel.lua's own 'john-k9:client:removeKennel' broadcast:
       a direct server-side DeleteEntity is attempted first; this broadcast
       is the belt-and-suspenders backstop for whichever connected client
       currently holds real OneSync network ownership of that entity, in
       case the server-side delete turns out to be a no-op for this exact
       FXServer build (not independently re-verified in this sandbox).

    Commands: '/k9propattach' toggle command lives in client/propattachment.lua
    (self-administered action, same "client-side entry point calling a
    client-side global" convention as client/kennel.lua's '/k9deploykennel'
    — see that file's header for the fuller version of this reasoning).

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)` and `IsConfiguredK9Model(modelHash)`,
      both exposed by server/certifications/ — do not re-derive either
      check here.
    - THIS FILE calls `NewCooldown()` (server/cooldowns.lua) at file-load
      time — must load after that file, same requirement every other
      consumer already states.
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)`
      (server/entities.lua) — do not re-implement the resolve/
      existence-guard sequence here.
    - THIS FILE owns `PropAttachmentState` (citizenid -> { netId, ownerSrc })
      and `PendingPropAttachConfirm` (citizenid -> { src, expiresAt }), both
      local to this file. Nothing outside this file reads them directly.
    - THIS FILE exposes NO resource-global functions — no other file in this
      resource, and no consumer of the FetchMechanic feature, needs to call
      into prop-attachment state directly. What IS shared with FetchMechanic
      is client-side (see client/propattachment.lua's own FILE-TO-FILE
      CONTRACT: AttachPropToOwnPed/DetachAndDeleteProp) and the dev-only
      bone-index tool (client/bonetool.lua + server/bonetool.lua) — neither
      of those lives in this file.

    CONFIG THIS FILE ASSUMES EXISTS (not owned by this file; see
    config.lua/fxmanifest.lua/.luacheckrc). Config.Features.PropAttachments
    already exists in config.lua (still `false`) — no new feature flag is
    needed for this file. New shape required, asserted at resource start
    below exactly like server/admin.lua's own config-safety-guard convention:
      Config.PropAttachments.propModel                : string
      Config.PropAttachments.fallbackPropModel         : string
      Config.PropAttachments.boneIndex                 : number (integer >= 0)
      Config.PropAttachments.offsetX/offsetY/offsetZ    : number
      Config.PropAttachments.rotX/rotY/rotZ             : number
      Config.PropAttachments.toggleCooldownMs          : number
      Config.PropAttachments.pendingConfirmTtlMs       : number
      Config.PropAttachments.confirmDistanceTolerance  : number
]]

-- PropAttachmentState[citizenid] = { netId: number, ownerSrc: number }
-- At most one active attachment per citizenid. Local: nothing outside this
-- file should read it directly.
local PropAttachmentState = {}

-- PendingPropAttachConfirm[citizenid] = { src: number, expiresAt: number } —
-- mirrors server/kennel.lua's PendingKennelPlacements shape (a request
-- awaiting a client-side follow-up action, with a TTL so an unanswered one
-- doesn't linger forever). Local: nothing outside this file should read it
-- directly.
local PendingPropAttachConfirm = {}

-- DEVELOPER_REFERENCE.md item 1 convention (server/cooldowns.lua): per-source
-- rate limit on toggling the attachment — spam/abuse guard only, distinct
-- from the one-active-attachment-per-citizenid limit enforced separately
-- below. Threshold supplied per-call from Config.PropAttachments.toggleCooldownMs,
-- matching server/kennel.lua's DeployCooldown shape (no default baked in at
-- construction).
local ToggleCooldown = NewCooldown()
ToggleCooldown.RegisterPlayerDropped()

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies across this resource). It is now
-- server/notify.lua's single shared resource-global implementation -- see
-- that file's own header for the extraction writeup. Every call site below
-- is unchanged: this file never passed a custom title, which is
-- server/notify.lua's own default.

--- Resolves the calling source's own citizenid, or nil if it can't be
--- resolved (disconnected mid-flight, qbx_core not ready yet, etc.). Every
--- handler in this file bails out on nil, same defensive posture as every
--- other file in this resource that keys state by citizenid.
--- @param src number
--- @return string? citizenid
local function ResolveCitizenId(src)
    local player = exports.qbx_core:GetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

--- Precomputed set of allowed prop model hashes (primary + configured
--- fallback). Built once at file load, same pattern as
--- server/kennel.lua's own KennelModelHashes. Used ONLY by
--- HandleConfirmPropAttached's defense-in-depth model check below — this is
--- what makes "the attach path can't be used to attach an arbitrary
--- caller-supplied netId" concretely true: even a fully-forged confirm
--- payload can only ever be accepted if it names something that already
--- has one of these two exact models.
local PropAttachmentModelHashes

--- GLOBAL NETID-UNIQUENESS GUARD — mirrors server/fetch.lua's own
--- FindOtherBallByNetId/GLOBAL NETID-UNIQUENESS INVARIANT exactly, ported
--- to this file's own single-table registry shape. At most one
--- `PropAttachmentState[citizenid]` entry may ever have `.netId == N` for
--- any given N at any moment. Without this, a second citizen standing near
--- a first citizen's already-tracked, real vest object could report THAT
--- netId as their own confirm — the model check passes (it really is a
--- configured prop model) and the distance check passes (it really is
--- close to the caller's own live ped, because the caller placed
--- themselves next to it) — leaving two PropAttachmentState entries
--- pointing at one physical entity, and a stale-registry desync when
--- either citizen later removes it (RemovePropAttachmentForCitizenid
--- deletes the shared entity out from under the other's still-believed-
--- valid entry). `excludeCitizenId` lets HandleConfirmPropAttached's own
--- caller not treat its OWN prior entry (there should never be one here —
--- the already-active check above already rejects that race — but this
--- keeps the shape identical to fetch.lua's own reusable helper rather
--- than hand-rolling a narrower one-off).
---
--- RACE-HARDENING NOTE (see this file's header FIRST-WRITER-WINS
--- PROP-HIJACK RACE section for the full writeup): this scan can ONLY ever
--- catch a collision against an entry an EARLIER confirm already wrote --
--- it has no visibility into a still-in-flight OTHER citizen's pending
--- confirm, which carries no netId at all until it actually arrives. It
--- therefore could not, by itself, stop a bogus confirm that arrives
--- BEFORE the genuine owner's own confirm -- the genuine owner's LATER
--- confirm was the one left hitting this check instead.
--- HandleConfirmPropAttached's own NETWORK-OWNERSHIP GUARD (run BEFORE
--- this check) closes that gap at its root: a caller who is not the
--- reported entity's current OneSync network owner is rejected before ever
--- reaching this scan, so this scan should now be effectively unreachable
--- in practice for any confirm using this feature's own established
--- create-then-report flow. It stays in place, unweakened, as the same
--- "layered checks over a single point of failure" defense-in-depth this
--- file's other guards already establish — including for the residual,
--- harder case the ownership guard's own comment discloses (an attacker
--- who additionally, actively steals OneSync control of an already-active
--- vest via the client-side NetworkRequestControlOfEntity native): a
--- genuine hit here still means two DIFFERENT citizens' confirms both
--- independently satisfied ownership for the SAME entity at their own
--- respective times, which is unresolvable ambiguity, not proof the second
--- claimant is the rightful one — rejecting (never adopting/evicting the
--- other citizen's entry) is the correct, conservative response, since
--- adopting would hand a successful ownership-theft attacker a path to
--- later delete the true owner's real, active prop via their own ordinary
--- toggle-off.
--- @param netId number
--- @param excludeCitizenId string?
--- @return string? otherCitizenId
local function FindOtherPropAttachmentByNetId(netId, excludeCitizenId)
    for citizenid, attachment in pairs(PropAttachmentState) do
        if citizenid ~= excludeCitizenId and attachment.netId == netId then
            return citizenid
        end
    end
    return nil
end

--- Builds/rebuilds PropAttachmentModelHashes from live config. Deferred
--- into a function (rather than a bare file-load-time block like
--- server/kennel.lua's KennelModelHashes) purely so the onResourceStart
--- config-safety guard below can run BEFORE this reads
--- Config.PropAttachments.propModel/fallbackPropModel — that guard
--- clamp-and-warns each field to a known-good string fallback (never
--- throws) rather than letting this call GetHashKey against a
--- missing/non-string value, so this always builds from two valid model
--- names by the time it runs, never silently out of nil hashes.
local function BuildPropAttachmentModelHashes()
    PropAttachmentModelHashes = {
        [GetHashKey(Config.PropAttachments.propModel)] = true,
        [GetHashKey(Config.PropAttachments.fallbackPropModel)] = true,
    }
end

--- Removes citizenid's active prop attachment: server-side DeleteEntity
--- attempt + broadcast backstop (see this file's header CLEANUP CONFIDENCE
--- NOTE on event 7), then clears the registry entry. Shared by the manual
--- toggle-off path, the death-report path, the playerDropped path, and the
--- onResourceStop path, so there is exactly one place that mutates
--- `PropAttachmentState` on removal — mirrors server/kennel.lua's
--- RemoveKennelForCitizenid exactly.
--- @param citizenid string
local function RemovePropAttachmentForCitizenid(citizenid)
    local attachment = PropAttachmentState[citizenid]
    if not attachment then return end
    PropAttachmentState[citizenid] = nil
    -- CROSS-FEATURE NETID CLAIM REGISTRY (see server/entities.lua's own
    -- header section for the full writeup): releases this citizenid's
    -- claim on attachment.netId so the netId can be legitimately
    -- reused/reclaimed afterward without tripping IsNetworkEntityClaimedByOther
    -- for anyone else. A no-op if this exact (feature, ownerId) pair never
    -- held the claim.
    ReleaseNetworkEntity(attachment.netId, 'propattachment', citizenid)

    local entity = ResolveNetworkEntity(attachment.netId)
    if entity then
        DeleteEntity(entity)
    end

    TriggerClientEvent('john-k9:client:removeK9PropAttachment', -1, attachment.netId)
end

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE — everything below (all four
-- RegisterNetEvent handlers, the playerDropped/onResourceStop cleanup
-- hooks, and the onResourceStart config-safety guard) is now inside this
-- single `if`, evaluated once at this file's own load time. Config.lua is
-- a shared_scripts file, loaded in full before any server_scripts file
-- runs, so Config.Features.PropAttachments already holds its real
-- true/false value by the time this line executes — this is NOT a
-- load-order gamble.
-- WHY THIS MATTERS BEYOND THE EXISTING PER-HANDLER `if not
-- Config.Features.PropAttachments then return end` CHECKS ALREADY INSIDE
-- each handler below (kept, deliberately, as defense-in-depth — same
-- "layered checks over a single point of failure" posture as the
-- SOURCE-ORIGIN GUARD in client/propattachment.lua remaining even though
-- the feature gate also exists): a per-handler check still means
-- 'john-k9:server:requestToggleK9PropAttachment' (etc.) IS a registered,
-- reachable event on a server with the feature left off — a client can
-- still fire it, still reach this file's Lua, and only then get turned
-- away. Wrapping the registration itself in the flag means an operator who
-- has never opted into PropAttachments has a server where these events do
-- not exist AT ALL — genuinely inert, not merely hidden behind an early
-- return. This resource's own established convention already does this at
-- COMMAND-registration time (server/bonetool.lua's '/k9bonetool' is only
-- ever RegisterCommand'd inside its own flag-checked onResourceStart) —
-- this applies the identical reasoning to RegisterNetEvent/AddEventHandler.
-- ======================================================================
if Config.Features.PropAttachments then

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.PropAttachments
--- flag) is already checked by the REGISTRATION-TIME FEATURE GATE this
--- function lives inside, before it is ever reached. Consulted ONLY on the
--- ADD branch of requestToggleK9PropAttachment below -- never on the REMOVE
--- branch (already active -> take it off), which runs BEFORE this check and
--- must stay unconditional: a handler taking their own vest off is this
--- feature's "no unbounded trap" exit path, the identical posture
--- this resource's own termination convention documents for detaching a leash/dropping a
--- ball/exiting a kennel/ending training.
---   2. an explicit block.PropAttachments grant -> DENY
---   3. PropAttachments listed in RequireGrant -> ALLOW only with an active
---      feature.PropAttachments grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsPropAttachmentsPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.PropAttachments') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.PropAttachments == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.PropAttachments') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Step 1: toggle. See this file's header EVENT/CALLBACK CONTRACT item 1.
RegisterNetEvent('john-k9:server:requestToggleK9PropAttachment', function()
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    -- Already active -> this request means "take it off." No round trip
    -- needed to remove something, unlike placing it. UNCONDITIONAL -- see
    -- IsPropAttachmentsPermittedForCitizenId's own doc comment above for why
    -- this branch is never gated on a block -- AND, same reasoning, never
    -- gated on the global Config.Features.PropAttachments flag either. Gate
    -- the START of a thing, never the STOP -- this resource's own
    -- established rule, stated in so many words by every comparable
    -- mechanic's own comments: server/fetch.lua's releaseFetchBall/
    -- reportFetchCarrierDown ("expiry enforcement must never be delayed or
    -- conditioned on anything"), server/kennel.lua's requestExitKennel/
    -- requestPutDownKennel ("NEVER gated on Config.Features.DeployableKennel
    -- or any cooldown"), server/main.lua's detachLeash, and
    -- server/combat.lua's releaseBiteHold/releaseTakedown/releaseDrag.
    -- BUG FIX: the Config.Features.PropAttachments check used to run FIRST,
    -- before this branch was ever reached, at the very top of this handler.
    -- Sequence that produced a permanent stuck cosmetic: server boots with
    -- the flag on -> a handler attaches the vest -> an operator flips the
    -- flag off live (server/runtimecontrol.lua's runtimeSetFeature writes
    -- Config.Features in place) -> that same handler fires this exact event
    -- again to take it off -> the flag check returned before ever reaching
    -- this branch -> silent no-op, no notify, the object never deleted,
    -- for as long as the flag stayed off -- only death, disconnect, or a
    -- resource restart cleared it, none of which is an acceptable way to
    -- take off a cosmetic prop. The flag legitimately gates STARTING a new
    -- attachment (see the ADD path below); it must never gate STOPPING an
    -- existing one, so the check moved below this branch entirely.
    if PropAttachmentState[citizenid] then
        RemovePropAttachmentForCitizenid(citizenid)
        NotifyPlayer(src, locale('propattachment.removed_success'), 'success')
        return
    end

    -- Everything from here down is the ADD path only. The global feature
    -- flag legitimately gates STARTING a new attachment -- see the REMOVE
    -- branch's own comment above for why it must never gate stopping one.
    if not Config.Features.PropAttachments then return end -- silent no-op, matches every other feature-flag gate in this resource

    -- Eligibility is re-checked BEFORE consuming the cooldown below —
    -- mirrors server/kennel.lua's requestDeployKennel ordering exactly
    -- (HasK9Access checked before DeployCooldown.Consume there), so an
    -- ineligible caller repeatedly hitting this event never burns down
    -- their own cooldown allowance for attempts that were always going to
    -- be rejected anyway.
    if not HasK9Access(src) then
        NotifyPlayer(src, locale('propattachment.not_authorized_equipment'), 'error')
        return
    end

    -- PER-PERSON FEATURE CONTROL -- see IsPropAttachmentsPermittedForCitizenId
    -- above. Checked BEFORE ToggleCooldown.Consume below, same ordering
    -- reasoning as the HasK9Access check immediately above.
    if not IsPropAttachmentsPermittedForCitizenId(citizenid) then
        NotifyPlayer(src, locale('propattachment.not_authorized_equipment'), 'error')
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end -- defensive: src disconnected between the event firing and this line

    -- WIDENED (K9 role/model decoupling, server/appearance.lua): a caller
    -- who holds the decoupled K9 ROLE (HasK9Role) but is not currently on
    -- a configured K9 model may still attach a prop -- same
    -- `type(...) == 'function'` guard/fail-closed reasoning as
    -- server/fetch.lua's identical widening of its own carry-eligibility
    -- check.
    if not (IsConfiguredK9Model(GetEntityModel(ped)) or (type(HasK9Role) == 'function' and HasK9Role(src))) then
        NotifyPlayer(src, locale('propattachment.requires_k9_form'), 'error')
        return
    end

    if PendingPropAttachConfirm[citizenid] then
        return -- an attach is already in flight for this citizenid; don't open a second pending slot
    end

    if not ToggleCooldown.Consume(src, Config.PropAttachments.toggleCooldownMs) then
        return -- silent no-op: rate-limited, matches bark/leash-request/certify-action convention
    end

    PendingPropAttachConfirm[citizenid] = {
        src = src,
        expiresAt = GetGameTimer() + Config.PropAttachments.pendingConfirmTtlMs,
    }

    TriggerClientEvent('john-k9:client:attachK9Prop', src)
end)

--- Step 2: client reports the network id of the object it actually
--- created+attached. See this file's header "WHY THIS NEVER ACCEPTS..."
--- block for the full reasoning on why this is still independently
--- re-validated even though the id names an entity the client was JUST
--- instructed to create.
--- @param netId number
RegisterNetEvent('john-k9:server:confirmPropAttached', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local pending = PendingPropAttachConfirm[citizenid]
    if not pending or pending.src ~= src then
        return -- no matching pending request for this citizenid/source pair — ignore, never trust an unsolicited confirm
    end
    PendingPropAttachConfirm[citizenid] = nil -- consumed either way, success or rejected below

    if GetGameTimer() > pending.expiresAt then
        NotifyPlayer(src, locale('propattachment.attach_timed_out'), 'error')
        -- ORPHANED-PROP FIX: this branch used to notify but never send
        -- 'john-k9:client:rejectK9PropAttach' — unlike every one of this
        -- handler's sibling failure branches below (model/position
        -- checks), which correctly pair their own NotifyPlayer with this
        -- same event. The client already created a real, attached,
        -- networked vest object before this confirm was even sent
        -- (client/propattachment.lua's own attachK9Prop handler) —
        -- notifying without this event left that object permanently
        -- untracked both server- and client-side (see that file's own
        -- STALE-VEST GUARD comment, which documents this exact gap and the
        -- narrower client-only mitigation it added without owning this
        -- file). No netId-trust concern here (unlike server/fetch.lua's
        -- equivalent fix): this event takes no argument — the client's own
        -- handler deletes ITS OWN locally-tracked `myVestEntity`, never a
        -- server-supplied netId, so there is no equivalent to that file's
        -- GLOBAL NETID-UNIQUENESS collision risk to reason about here.
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    -- Re-validate — a certification revoke, a feature-flag toggle, or a
    -- second attachment landing during the round trip must all be caught
    -- again here, exactly like server/kennel.lua's confirmKennelPlaced.
    --
    -- ORPHANED-PROP FIX: all three re-checks below used to `return` with
    -- nothing sent back at all — not even a NotifyPlayer — leaving the
    -- client's just-created, just-attached vest object both untracked here
    -- and un-signalled that anything failed. See the TTL-expiry branch's
    -- own comment above for why sending
    -- 'john-k9:client:rejectK9PropAttach' here carries none of
    -- server/fetch.lua's netId-trust concerns.
    if not Config.Features.PropAttachments then
        -- Unreachable in current practice — nothing in this codebase ever
        -- reassigns Config.Features.PropAttachments at runtime (config.lua
        -- is a shared_scripts file, loaded once, synchronously, identically
        -- on both sides before either side's own code runs; verified no
        -- assignment to this field exists anywhere else in this resource).
        -- Kept as genuine defense-in-depth, same "layered checks over a
        -- single point of failure" posture this file's own REGISTRATION-
        -- TIME FEATURE GATE header already argues for — in case a future
        -- live-reconfiguration path ever makes this reachable.
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end
    if not HasK9Access(src) then
        NotifyPlayer(src, locale('propattachment.not_authorized_equipment'), 'error')
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end
    if PropAttachmentState[citizenid] then
        -- No NotifyPlayer here deliberately: this citizenid already has a
        -- confirmed, active attachment on record (a race between two
        -- in-flight confirms) — that is the true, correct state, so an
        -- "attach failed" toast would be actively misleading. The cleanup
        -- event is still required: it targets THIS confirm's own
        -- just-created object (client/propattachment.lua's attachK9Prop
        -- handler sets `myVestEntity = obj` synchronously, before firing
        -- this very confirm), not the other, already-tracked one.
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    local ped = GetPlayerPed(src)
    if ped == 0 then
        -- DISCONNECT-MID-FLIGHT FIX: this branch used to `return`
        -- completely silently — the one remaining branch in this handler
        -- that did not, unlike every sibling failure branch above and
        -- below it. GetPlayerPed(src) == 0 does not necessarily mean `src`
        -- has fully disconnected — see the identical "defensive: src
        -- disconnected between the event firing and this line" comment on
        -- requestToggleK9PropAttachment's own ped==0 check earlier in this
        -- file — it can also mean src's ped is momentarily unresolvable (a
        -- respawn race) while src's own network connection is still live.
        -- Deciding whether a rejection is even deliverable: if `src`
        -- genuinely has disconnected, TriggerClientEvent to it is a safe,
        -- silent no-op (FiveM has nowhere to route it and does not error) —
        -- so sending it here is never wrong, and it is the only way to close
        -- the exact same orphaned-object gap the ORPHANED-PROP FIX closed on
        -- every other branch in this handler: the client already created
        -- and attached a real, networked object in response to this file's
        -- own instruction before this line ever runs. No NotifyPlayer is
        -- sent, matching this file's own established "ped==0 mid-flight"
        -- convention elsewhere (silent — a genuinely disconnected target
        -- could never see a toast anyway, and there is no better message for
        -- "your character disappeared"). Nothing further to do on the
        -- registry side: PendingPropAttachConfirm[citizenid] was already
        -- consumed above, and this netId was never written into
        -- PropAttachmentState, so there is no stale entry to clean up here.
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    -- GetEntityType expectedEntityType = 3 (object) — see
    -- server/entities.lua's own ResolveNetworkEntity doc comment for the
    -- GetEntityType numbering.
    local entity = ResolveNetworkEntity(netId, 3)
    if not entity then
        NotifyPlayer(src, locale('propattachment.attach_failed_unconfirmed'), 'error')
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    -- DEFENSE-IN-DEPTH MODEL CHECK — mirrors server/kennel.lua's own
    -- KennelModelHashes check on confirmKennelPlaced verbatim: confirms the
    -- reported entity is actually one of the two configured prop models,
    -- not an arbitrary pre-existing networked object a modified client
    -- could report instead of a genuinely newly-created vest.
    if not PropAttachmentModelHashes[GetEntityModel(entity)] then
        NotifyPlayer(src, locale('propattachment.attach_failed_wrong_model'), 'error')
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    -- DEFENSE-IN-DEPTH POSITION CHECK — same role as server/kennel.lua's
    -- KENNEL_CONFIRM_DISTANCE_TOLERANCE, checked against the CALLER'S OWN
    -- live ped position (a moving attach point) rather than a fixed
    -- placement spot, since that's what this feature actually anchors to.
    -- This is what turns "a modified client reports an arbitrary
    -- pre-existing networked entity's netId" from "this file now tracks
    -- and will later DeleteEntity someone else's unrelated object" into a
    -- rejected confirm — a real object of the right model sitting far from
    -- the caller's own ped cannot be the vest this file just asked that
    -- caller's client to create.
    local pedCoords = GetEntityCoords(ped)
    local entityCoords = GetEntityCoords(entity)
    local dx = entityCoords.x - pedCoords.x
    local dy = entityCoords.y - pedCoords.y
    local dz = entityCoords.z - pedCoords.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > Config.PropAttachments.confirmDistanceTolerance then
        NotifyPlayer(src, locale('propattachment.attach_failed_too_far'), 'error')
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    -- NETWORK-OWNERSHIP GUARD (closes the FIRST-WRITER-WINS PROP-HIJACK
    -- RACE — see this file's own header section for the full trace). Model
    -- + live-position tolerance above can both be satisfied by a client
    -- that merely stands near someone ELSE's real, already-networked
    -- object — neither one proves the reported netId is the confirming
    -- caller's OWN creation. This check asks the one question that does:
    -- is `src` the entity's CURRENT OneSync network owner right now? A
    -- networked object created via client/propattachment.lua's own
    -- AttachPropToOwnPed call is owned, at creation, by the client that
    -- created it — never by a merely-nearby OTHER client, no matter how
    -- quickly that other client reacts or how close it stands.
    --
    -- NATIVE VERIFICATION (not assumed from memory): the more direct
    -- question this check would ideally ask — "is `entity` CURRENTLY
    -- attached to MY OWN ped" (GetEntityAttachedTo) — is CLIENT-ONLY per the
    -- official CFX native docs (https://docs.fivem.net/natives/?_0x48C2BED9180FE123=),
    -- confirmed via WebSearch, NOT callable here. NetworkGetEntityOwner
    -- IS documented as callable SERVER-side, returning the server id of the
    -- entity's current network owner
    -- (https://docs.fivem.net/natives/?_0x55E86AF2712B36A1=). Confidence:
    -- MEDIUM-HIGH (official CFX docs), not independently re-verified
    -- in-engine — same confidence class already attached to this
    -- resource's own SOURCE-ORIGIN GUARD precedent
    -- (client/propattachment.lua's own `source ~= 65535` check).
    --
    -- DISCLOSED RESIDUAL GAP, not silently assumed away (see the GLOBAL
    -- NETID-UNIQUENESS GUARD's own RACE-HARDENING NOTE below for how this
    -- file responds if it is ever actually hit): OneSync entity ownership
    -- CAN migrate, and any client can explicitly ask to become an entity's
    -- owner via the client-side NetworkRequestControlOfEntity native
    -- (client/combat.lua's own header documents this native's real,
    -- best-effort-not-guaranteed behavior in this exact codebase). A
    -- sufficiently active attacker — one who additionally, deliberately
    -- calls that native against another player's already-active vest,
    -- rather than merely observing and reporting a nearby netId — could in
    -- principle still pass this check. That is a materially harder, more
    -- expensive attack than the "sniff a nearby netId and report it" race
    -- this check closes, and is not what this fix targets.
    if NetworkGetEntityOwner(entity) ~= src then
        NotifyPlayer(src, locale('propattachment.attach_failed_unconfirmed'), 'error')
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    -- GLOBAL NETID-UNIQUENESS GUARD — mirrors server/fetch.lua's own
    -- FindOtherBallByNetId check verbatim: reject a confirm that names a
    -- netId ALREADY claimed by a DIFFERENT citizenid's own active
    -- PropAttachmentState entry (e.g. a second citizen standing next to
    -- the first and reporting the first's own real, already-tracked
    -- vest's netId as their own). `citizenid` is confirmed above (the
    -- already-active re-check) to have no entry of its own yet, so any hit
    -- here is necessarily a genuine cross-citizenid collision, never this
    -- same citizenid's own prior value. Without this, a client-supplied
    -- netId could let one player bind another player's already-tracked
    -- entity into their own registry — exactly the property this file's own
    -- header "WHY THIS NEVER ACCEPTS A CLIENT-CLAIMED TARGET" section
    -- argues this file does not allow.
    --
    -- CROSS-FEATURE NETID CLAIM REGISTRY: this file's NETWORK-OWNERSHIP
    -- GUARD above already independently closes the cross-feature version
    -- of this same class of gap (a client-reported netId naming another
    -- citizen's real, live server/kennel.lua kennel or server/fetch.lua
    -- ball, both sharing this exact prop model per config.lua, can never
    -- pass that guard, since its true OneSync owner is that OTHER client,
    -- never `src`) -- so this addition is defense-in-depth consistency
    -- with server/kennel.lua/server/fetch.lua's own equivalent checks, not
    -- independently load-bearing here. See server/entities.lua's own
    -- header section for the full writeup.
    if FindOtherPropAttachmentByNetId(netId, citizenid) or IsNetworkEntityClaimedByOther(netId, 'propattachment', citizenid) then
        NotifyPlayer(src, locale('propattachment.attach_failed_already_tracked'), 'error')
        TriggerClientEvent('john-k9:client:rejectK9PropAttach', src)
        return
    end

    PropAttachmentState[citizenid] = { netId = netId, ownerSrc = src }
    -- Records this claim in the shared cross-feature registry so
    -- server/kennel.lua's and server/fetch.lua's own equivalent checks can
    -- see it too -- see server/entities.lua's own header section.
    ClaimNetworkEntity(netId, 'propattachment', citizenid)
    NotifyPlayer(src, locale('propattachment.attached_success'), 'success')
end)

--- Client reports its own attach attempt failed (model never loaded) —
--- frees the pending slot immediately. Mirrors server/kennel.lua's
--- 'john-k9:server:cancelKennelPlacement' exactly.
RegisterNetEvent('john-k9:server:cancelPropAttachRequest', function()
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local pending = PendingPropAttachConfirm[citizenid]
    if pending and pending.src == src then
        PendingPropAttachConfirm[citizenid] = nil
    end
end)

--- Self-report: "my own ped just died, and it currently owns an active
--- attachment." See this file's header event 4 for the full trust-category
--- reasoning (self-reported fact about the reporter's own state, same
--- category as server/tracking.lua's relayDamageEvent/relayWeaponFire).
--- Ownership is still re-verified below before anything is removed.
RegisterNetEvent('john-k9:server:reportOwnK9PropAttachDeath', function()
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    local attachment = PropAttachmentState[citizenid]
    if not attachment or attachment.ownerSrc ~= src then
        return -- nothing to remove, or this source isn't the one holding it on record — ignore
    end

    RemovePropAttachmentForCitizenid(citizenid)
end)

-- Handler-disconnect cleanup (an attached prop must not leak permanently
-- into the world). Resolves citizenid for the disconnecting source BEFORE
-- the framework fully tears down the player object, same established
-- pattern as server/kennel.lua's own playerDropped handler.
AddEventHandler('playerDropped', function(_reason)
    local src = source

    local citizenid = ResolveCitizenId(src)
    if not citizenid then return end

    if PendingPropAttachConfirm[citizenid] and PendingPropAttachConfirm[citizenid].src == src then
        PendingPropAttachConfirm[citizenid] = nil
    end

    if PropAttachmentState[citizenid] and PropAttachmentState[citizenid].ownerSrc == src then
        RemovePropAttachmentForCitizenid(citizenid)
    end

    -- ToggleCooldown already registered its own playerDropped handler via
    -- :RegisterPlayerDropped() above — nothing to do for it here.
end)

-- Resource-stop cleanup (same class of gap client/vehicle.lua's own
-- onResourceStop comment calls "ship-blocking" for its own entity-state
-- case): a resource restart must not leave any currently-attached prop
-- behind as a permanent, orphaned world object. This handles attachments
-- whose ORIGINAL creating client already disconnected earlier in the
-- session — client/propattachment.lua's own onResourceStop handler
-- independently covers the (more common) case of a still-connected client
-- cleaning up its own creation.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, attachment in pairs(PropAttachmentState) do
        local entity = ResolveNetworkEntity(attachment.netId)
        if entity then
            DeleteEntity(entity)
        end
    end
    -- Deliberately NOT also broadcasting 'john-k9:client:removeK9PropAttachment'
    -- here — same reasoning as server/kennel.lua's own onResourceStop
    -- handler: every other client's copy of this resource is stopping at
    -- essentially the same time, making a broadcast from this handler
    -- unreliable busywork rather than a real backstop.
end)

-- ======================================================================
-- CONFIG-SAFETY GUARD — mirrors server/admin.lua's own onResourceStart
-- convention: Config.Features.PropAttachments already exists in config.lua
-- (still `false`), so no assert on the flag itself is needed here (a
-- missing/false flag is a normal, supported state, not a misconfiguration).
-- Once the flag IS `true`, Config.PropAttachments must exist as a table (kept
-- as a hard assert below — a WHOLE missing table is a far more severe
-- misconfiguration than one malformed field, and every field read below
-- would otherwise error against a nil `cfg` anyway) — but every INDIVIDUAL
-- field within it is now CLAMP-AND-WARNED, never asserted. This used to be
-- nine bare per-field `assert`s in a row: a throw from ANY one of them
-- aborted this entire handler on the spot, which ALSO meant
-- BuildPropAttachmentModelHashes() (below) never ran, leaving
-- PropAttachmentModelHashes built from whatever it held before (nil/empty
-- on a first start) — every attach request would then fail its model-hash
-- check for the rest of this resource's uptime, on top of the missing
-- startup confirmation print, over one operator typo in a config section
-- config.lua's own header explicitly invites tuning of (boneIndex,
-- offsets/rotation, cooldowns).
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not (Config.Features and Config.Features.PropAttachments == true) then return end

    local cfg = Config.PropAttachments
    assert(type(cfg) == 'table', '[John-K9] Config.Features.PropAttachments is true but Config.PropAttachments is missing.')

    --- Warns ONCE (this handler only ever runs once per resource start) and
    --- forces `cfg[key]` to `fallback` when `predicate(cfg[key])` is false.
    --- `fallback` is always one of config.lua's own shipped defaults for
    --- this field, matching this codebase's established clamp-and-warn
    --- convention (server/cooldowns.lua's ResolveConfiguredThresholdMs,
    --- server/certifications/'s autoAccessGrade guard, etc.) rather than
    --- guessing a "safer" number.
    --- @param key string
    --- @param predicate fun(value: any): boolean
    --- @param fallback any
    --- @param description string -- plain-English requirement, used only in the printed warning
    local function ResolvePropAttachmentField(key, predicate, fallback, description)
        local value = cfg[key]
        if not predicate(value) then
            print(
                ('[John-K9] WARNING: Config.PropAttachments.%s %s (found: %s) -- using the built-in ' ..
                 'fallback %s instead of aborting this file\'s entire PropAttachments registration over one ' ..
                 'field. Fix Config.PropAttachments.%s in config.lua to silence this warning.'
                ):format(key, description, tostring(value), tostring(fallback), key)
            )
            cfg[key] = fallback
        end
    end

    ResolvePropAttachmentField('propModel', function(v) return type(v) == 'string' and v ~= '' end, 'prop_bodyarmour_02', 'must be a non-empty string')
    ResolvePropAttachmentField('fallbackPropModel', function(v) return type(v) == 'string' and v ~= '' end, 'prop_tennis_ball', 'must be a non-empty string')
    ResolvePropAttachmentField('boneIndex', function(v) return type(v) == 'number' and v >= 0 end, 0, 'must be a number >= 0')
    for _, key in ipairs({ 'offsetX', 'offsetY', 'offsetZ', 'rotX', 'rotY', 'rotZ' }) do
        ResolvePropAttachmentField(key, function(v) return type(v) == 'number' end, 0.0, 'must be a number')
    end
    -- `> 0`, not `>= 0`: ToggleCooldown is a NewCooldown() with no
    -- constructor default, so this value is read fresh at call time, where
    -- server/cooldowns.lua treats a non-positive threshold as permanently ON
    -- rather than as "no cooldown". A 0 set to mean "unthrottled" would
    -- instead lock every player out of toggling their vest again for the
    -- rest of the resource's uptime, after their first toggle. Matches
    -- server/admin.lua and server/bonetool.lua, which both require > 0.
    ResolvePropAttachmentField('toggleCooldownMs', function(v) return type(v) == 'number' and v > 0 end, 2000,
        'must be a number > 0 -- 0 or negative does NOT mean "no cooldown" here, it means the vest toggle fails ' ..
        'closed (permanently blocked) after one use; see server/cooldowns.lua\'s fail-closed threshold handling')
    ResolvePropAttachmentField('pendingConfirmTtlMs', function(v) return type(v) == 'number' and v > 0 end, 15000, 'must be a positive number')
    ResolvePropAttachmentField('confirmDistanceTolerance', function(v) return type(v) == 'number' and v > 0 end, 5.0, 'must be a positive number')

    BuildPropAttachmentModelHashes()

    print('[John-K9] propattachment.lua: PropAttachments feature is enabled and config-validated.')
end)

end -- if Config.Features.PropAttachments -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
