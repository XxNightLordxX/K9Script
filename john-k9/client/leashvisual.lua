--[[
    john-k9/client/leashvisual.lua

    NEW FILE. Makes the leash mechanic client/movement.lua and
    server/main.lua already fully implement (consent handshake, server-
    authoritative LeashPairs, the constrained party's own elastic
    pull-back) actually VISIBLE: a real rope rendered between the handler's
    hand and the K9's own body for the entire duration of an active leash,
    gone the instant it ends. Before this file, nothing rendered anything
    at all -- the K9 was visibly tugged along by an invisible force.

    NEITHER client/movement.lua NOR server/main.lua is edited by this file.
    Both are owned by other agents and are "hot" (many concurrent edits) --
    this file was deliberately scoped to need no change in either: it
    listens to the SAME 'john-k9:client:leashAttached'/
    'john-k9:client:leashDetached' server->client events
    client/movement.lua already registers its own handler for
    (RegisterNetEvent supports multiple independent handlers per event
    name -- this file adds a second one; it never touches
    client/movement.lua's).

    ======================================================================
    BYSTANDER VISIBILITY -- READ THIS FIRST, STATED PLAINLY: ropes made via
    AddRope/AttachEntitiesToRope are 100% LOCAL to whichever client calls
    them -- there is no "networked rope" primitive in this engine the way
    CreateObject has an isNetwork flag. server/main.lua's leashAttached/
    leashDetached are TriggerClientEvent'd ONLY to the two participants
    (confirmed by reading server/main.lua:1177-1198 before writing this) --
    a third player standing nearby has no server-pushed way to learn a
    pairing exists at all.

    To make the rope visible to bystanders too (a hard requirement of this
    task, not optional), this file introduces this resource's FIRST
    statebag: an ENTITY-scoped (not Player()-scoped) key,
    'john-k9:leashVisual', set ONLY by the K9-role client on its OWN ped
    (never the officer's), read by every client via
    AddStateBagChangeHandler. This is a real, disclosed architectural
    choice, not a casual one -- client/appearance.lua's own header
    ("STATEBAG VS CACHED CALLBACK") previously considered and REJECTED
    introducing statebags into this resource for a different, narrower
    question (IsK9RoleForPlayer), citing "zero statebags today" and a
    disconnect-cleanup risk. That risk was specifically about Player()-
    SCOPED bags, which are indexed by SERVER SLOT NUMBER and can therefore
    silently apply a stale value to a DIFFERENT, unrelated player who later
    reconnects into the same slot. An ENTITY-scoped bag does not have that
    failure mode (a disconnect destroys that ped network-wide; a
    reconnecting player gets a brand-new ped with a brand-new network id,
    never inheriting the old entity's bag) -- and independently, every
    consumer below (CreateLocalRope, the reconciliation/liveness thread)
    re-validates DoesEntityExist/IsEntityDead on both peds before ever
    trusting the bag's payload, so even a hypothetically-stale value is
    harmless: at worst one client briefly tries to resolve a gone entity
    and no-ops. This is entirely self-contained inside this one new file --
    no server file was touched or needed to be.

    HONEST LIMIT, STATED PLAINLY: AddStateBagChangeHandler fires on a VALUE
    CHANGE, not on an entity re-entering streaming scope. If a bystander's
    locally-rendered rope is torn down because the K9/officer ped
    temporarily streamed out of that bystander's scope (they drove away and
    came back) while the underlying pairing's statebag value never
    changed, nothing re-triggers the ORIGINAL change event for that
    bystander. This is closed here by a reconciliation pass in the
    monitoring thread below (re-attempts CreateLocalRope for any pairing
    this client still has recorded but is not currently rendering), so the
    rope self-heals within one poll interval once the entity is
    resolvable again -- not left permanently gone for that bystander.

    ======================================================================
    NATIVES USED, EACH INDEPENDENTLY VERIFIED THIS PASS. Every
    ext/native-decls/<Name>.md URL below was actually fetched this session;
    a 404 fell back to runtime.fivem.net/doc/natives.json per this task's
    own instruction (a 404 on the .md is NOT proof of absence -- these are
    all pre-CFX-doc-era PHYSICS/ENTITY natives, the same generation as this
    resource's own AttachEntityToEntity/GetWorldPositionOfEntityBone, which
    client/propattachment.lua's header already established 404 the same
    way for the same reason):
      - RopeLoadTextures        PHYSICS 0x9B9039DBF2D258C1 -- natives.json (decl 404)
      - RopeAreTexturesLoaded   PHYSICS 0xF2D0E6A75CC05597 -- natives.json (decl 404)
      - AddRope                 PHYSICS 0xE832D760399EB220 -- natives.json (decl 404).
        natives.json's OWN "examples" field for this native ships a
        complete, official first-party Lua usage example covering
        RopeLoadTextures/RopeAreTexturesLoaded/AddRope/DoesRopeExist/
        DeleteRope together -- this is what settled the one real open
        question in researching this file: DeleteRope/DoesRopeExist's
        `ropeId` parameter is documented as type `int*` (a pointer), which
        raised the question of whether a Lua caller needs some kind of
        ref/wrapper value. The official example answers this directly:
        `DeleteRope(rope)` / `DoesRopeExist(rope)` are called with the
        plain integer handle AddRope returned, no wrapper of any kind (the
        C# example in the same natives.json entry DOES use `ref
        ropehandle`, because C# needs explicit ref syntax for an int*
        param where Lua's native invoker does not) -- this is
        primary-source-example confidence, not independently re-run
        in-engine (no live client available this session), stated honestly
        rather than overclaimed.
      - DoesRopeExist           PHYSICS 0xFD5448BE3111ED96 -- see AddRope note above for the calling-convention confirmation
      - AttachEntitiesToRope    PHYSICS 0x3D95EC8B6D940AC3 -- natives.json (decl 404).
        Params: ropeId, ent1, ent2, ent1_x/y/z, ent2_x/y/z, length, p10,
        p11, boneName1, boneName2 -- boneName1/boneName2 are `char*`
        (STRING bone names), NOT the same `int` boneIndex
        AttachEntityToEntity/GetWorldPositionOfEntityBone take. This
        resource's own prior research has never found a confirmed bone
        NAME (as opposed to a raw INDEX) for either an a_c_* K9 skeleton or
        a human hand (see config.lua's Config.PropAttachments header and
        client/bonetool.lua's header, both already true before this file
        existed) -- so this file passes boneName1/boneName2 = nil on both
        ends and instead feeds ent1_x/y/z / ent2_x/y/z a LOCAL offset it
        derives itself, on every attach, from a REAL bone INDEX via
        GetWorldPositionOfEntityBone (index-based, confirmed generic over
        any entity type) -> GetOffsetFromEntityGivenWorldCoords (the
        world-to-local inverse, confirmed below). The rope endpoints are
        therefore still driven by a real bone index end to end, never a
        hand-picked world/local constant -- just routed through this
        native's own offset mechanism instead of its (for this resource,
        unverified-by-name) bone-name mechanism. MEDIUM confidence that a
        nil boneName is accepted/ignored cleanly by this specific native
        (natives.json ships no worked example exercising this exact
        argument): this is extremely well-worn community practice for this
        exact native (every vehicle-tow-rope script that offsets from
        entity origin rather than a named hitch bone does exactly this),
        but was not independently re-verified against engine source this
        session. p10/p11 (undocumented BOOLs on this legacy native) are
        passed false/false, matching the near-universal community default
        for this native -- same MEDIUM confidence, no primary-source
        example to check against.
      - DeleteRope              PHYSICS 0x52B4829281364649 -- see AddRope note above
      - GetOffsetFromEntityGivenWorldCoords ENTITY 0x2274BC1C4885E333 --
        natives.json (decl 404). Entity-type-generic (declared over a
        generic `Entity`, not PED-only), same "works on a dog ped too"
        property client/propattachment.lua's header already established
        for its sibling GetWorldPositionOfEntityBone/
        GetOffsetFromEntityInWorldCoords (the latter already allowlisted in
        .luacheckrc for client/vehicle.lua's own use) -- this is that same
        native's documented INVERSE (world coords -> local offset, vs.
        local offset -> world coords), confirmed by its own params/result
        shape in natives.json (Entity, posX, posY, posZ -> Vector3), not
        assumed from the name alone.
      - AddStateBagChangeHandler, GetEntityFromStateBagName --
        ext/native-decls/<Name>.md, BOTH returned HTTP 200 this session
        (`ns: CFX`, `apiset: shared`) -- directly confirmed, not a
        natives.json fallback. (GetPlayerFromStateBagName was also fetched
        and confirmed HTTP 200/CFX/shared this session, but is deliberately
        NOT used below -- it resolves a `player:Source`-shaped bag name; the
        bag this file sets is entity-scoped (`entity:NetID`-shaped, per
        AddStateBagChangeHandler's own doc), so GetEntityFromStateBagName +
        NetworkGetPlayerIndexFromPed (an existing, already-relied-on native
        in this codebase -- see client/movement.lua's ox_target onSelect
        handlers) is the correct pair for THIS bag's shape, not
        GetPlayerFromStateBagName.)
      - Entity(handle).state -- NOT a native (no ext/native-decls entry --
        same category as `vector3`/`source`/`promise` in this repo's own
        .luacheckrc, which documents that whole class as "verified against
        the Lua runtime source instead" rather than native-decls). This
        exact accessor shape (`Entity(ped).state:set(key, value,
        replicate)` / `Entity(ped).state.someKey`) is already named as a
        live, considered design option in THIS repo's own
        client/appearance.lua header -- reused verbatim here, not
        independently re-derived. Could not re-fetch a primary doc page for
        this specific accessor this session (several guessed doc-repo
        paths all 404'd); this is standard, extremely widely used
        CitizenFX Lua runtime surface (every major FiveM framework uses
        this exact shape for player/entity metadata sync) -- stated at
        that level of confidence, not native-decls-verified, honestly.

    NOT USED, VERIFIED ANYWAY (idle in case a future pass wants dynamic
    reeling): StartRopeWinding (0x1461C72C889E343E), StartRopeUnwindingFront
    (0x538D1179EC1AA9A9), RopeForceLength (0xD009F759A723DB1B) -- all three
    confirmed present in natives.json. A physically-simulated rope with a
    fixed max length already droops when slack and pulls taut near that
    length on its own (the same visual a real leash has) with zero
    per-frame scripting once attached -- winding is for a rope that
    visibly reels in/out over time (a tow cable), which this feature does
    not need. ActivatePhysics (PHYSICS 0x710311ADF0E20730, confirmed
    present) is also not called: nothing in this file gives any entity a
    NEW physics/ragdoll state, so there is no dormant-physics entity here
    that would ever need waking.

    Deliberately never calls RopeUnloadTextures: natives.json's own
    official example shows it guarded behind `#GetAllRopes() == 0` (only
    unload if NO resource on the whole server still has an active rope) --
    RopeLoadTextures/RopeUnloadTextures are GLOBAL per-client state, not
    scoped to this resource, so unloading on this resource's own stop could
    break a totally unrelated resource's own active rope. The one-time,
    small, resident texture cost of never unloading is the safer trade.

    ======================================================================
    CLEANUP -- "NEVER GATE A TERMINATION PATH", applied to every path this
    task named:
      - Manual detach              -- 'john-k9:client:leashDetached' handler below, instant.
      - Certification lapsing      -- server/certifications/'s ForceDetachLeashForSource
                                       funnels through the SAME doDetachLeash ->
                                       leashDetached broadcast as manual detach, so it is
                                       covered by the exact same handler, no special case.
      - Partner disconnecting      -- covered twice: (a) server/main.lua's playerDropped
                                       cleanup broadcasts leashDetached to whichever party
                                       remains (instant for that party), and (b) independently,
                                       the monitoring thread's liveness pass (below) tears down
                                       a rendered rope on ANY client the moment either ped
                                       stops resolving/existing, whether or not (a) ever fired
                                       for that particular client.
      - Either player dying        -- CORRECTED (this pass): this row used to disclose a gap in
                                       the underlying mechanic -- "there is no death-triggered
                                       auto-detach in LeashPairs at all" -- that has since been
                                       closed: server/main.lua's ForceDetachLeashForSource is now
                                       also called from a dedicated death-poll thread there
                                       (`IsLeashPartyDead`, LEASH_DEATH_CHECK_INTERVAL_MS --
                                       confirmed by reading that file), so a death now does
                                       broadcast leashDetached the same as a manual detach.
                                       Independent of that server-side fix, this file's own
                                       visual/prop cleanup never depended on the mechanic
                                       detaching anyway: the death-poll below clears this
                                       client's own contribution (statebag write and/or handle
                                       prop) directly on IsEntityDead(), and the liveness pass
                                       tears down every OTHER client's rendered rope the same
                                       way, independent of LeashPairs.
      - Resource stop              -- onResourceStop below runs BOTH: this client's own
                                       statebag/prop cleanup (unconditionally, whichever role
                                       it was playing) and deletion of every rope THIS client
                                       is currently rendering (participant or bystander alike)
                                       -- same "onResourceStop is the last unconditional chance"
                                       convention as client/vehicle.lua's own handler.
      - Entity going out of scope  -- the SAME liveness pass covers this: DoesEntityExist
                                       failing for either ped (streamed out, despawned, whatever
                                       the cause) tears the local rope down exactly like a death
                                       would.
    Every one of these except the first two is enforced redundantly by BOTH
    an instant, event-driven path AND a periodic (1s) polling backstop --
    the same "primary control plus a slower safety-valve backstop" layering
    client/movement.lua's own elastic pull-back / hard-cap already
    establishes for the leash mechanic itself.
    ======================================================================
]]

-- luacheck: read_globals AddRope DeleteRope DoesRopeExist RopeLoadTextures RopeAreTexturesLoaded AttachEntitiesToRope GetOffsetFromEntityGivenWorldCoords AddStateBagChangeHandler GetEntityFromStateBagName Entity

-- ======================================================================
-- CONFIG SAFETY -- clamp-and-warn, NEVER a bare assert. Mirrors
-- server/cooldowns.lua's ResolveConfiguredThresholdMs (that file is
-- server-only, so this is a small client-local re-implementation of the
-- same PATTERN, not a call to that function) -- see this resource's
-- documented "config-abort" bug class this avoids: one bad
-- Config.LeashVisual field must never take down every registration below
-- it for the rest of this client's session.
-- ======================================================================

--- @param configuredValue any
--- @param fallbackValue number
--- @param configKeyName string
--- @return number
local function ResolvePositiveNumber(configuredValue, fallbackValue, configKeyName)
    if type(configuredValue) == 'number' and configuredValue == configuredValue and configuredValue > 0 then
        return configuredValue
    end
    print(('[John-K9] leashvisual.lua: Config.LeashVisual.%s is missing or not a positive number (found: %s). Using %s instead.')
        :format(configKeyName, tostring(configuredValue), tostring(fallbackValue)))
    return fallbackValue
end

--- Bone INDEX validity is a DIFFERENT test from a length/timeout: 0 is a
--- real, meaningful, always-safe value here (the root bone -- see
--- config.lua's own Config.PropAttachments precedent, "Default 0 is the
--- root bone: always valid, never crashes, looks wrong"), so this must
--- NEVER be written as `configuredValue or fallback` -- exactly the
--- zero-is-truthy trap this task explicitly warns about (`0 or fallback`
--- evaluates to `fallback` in Lua, silently discarding a deliberate, valid
--- root-bone configuration).
--- @param configuredValue any
--- @param fallbackValue number
--- @param configKeyName string
--- @return number
local function ResolveBoneIndex(configuredValue, fallbackValue, configKeyName)
    if type(configuredValue) == 'number' and configuredValue == configuredValue
        and configuredValue >= 0 and configuredValue == math.floor(configuredValue) then
        return configuredValue
    end
    print(('[John-K9] leashvisual.lua: Config.LeashVisual.%s is missing or not a non-negative integer (found: %s). Using %s instead.')
        :format(configKeyName, tostring(configuredValue), tostring(fallbackValue)))
    return fallbackValue
end

--- ropeType is a zero-based index into ropedata.xml -- AddRope's own doc
--- states "Using an index which does not exist will crash the game," valid
--- range 0-7 (game build 3258). Clamped, never merely defaulted, so an
--- operator typo (8, -1, 99, ...) can never reach AddRope at all.
--- @param configuredValue any
--- @param fallbackValue number
--- @param configKeyName string
--- @return number
local function ResolveRopeType(configuredValue, fallbackValue, configKeyName)
    if type(configuredValue) == 'number' and configuredValue == configuredValue then
        local floored = math.floor(configuredValue)
        if floored >= 0 and floored <= 7 then return floored end
    end
    print(('[John-K9] leashvisual.lua: Config.LeashVisual.%s must be an integer 0-7 (found: %s). Using %s instead -- an out-of-range value crashes the game per AddRope\'s own documented contract.')
        :format(configKeyName, tostring(configuredValue), tostring(fallbackValue)))
    return fallbackValue
end

local cfg = (type(Config.LeashVisual) == 'table') and Config.LeashVisual or {}
if type(Config.LeashVisual) ~= 'table' then
    print('[John-K9] leashvisual.lua: Config.LeashVisual is missing or not a table -- using built-in defaults for every field. Add a Config.LeashVisual block to config.lua (see that file\'s LEASH section) to customize.')
end

-- VISUAL_ENABLED gates EVERY registration below (statebag listener, the two
-- net-event handlers, the monitoring thread, onResourceStop) -- matching
-- this resource's established "gate at registration, not inside the
-- handler" convention (see client/propattachment.lua's own
-- REGISTRATION-TIME FEATURE GATE section for the full reasoning this
-- mirrors). There is no separate Config.Features entry for this file (see
-- config.lua's own Config.LeashVisual header) -- `enabled` is purely an
-- extra operator kill-switch for the VISUAL layer specifically.
local VISUAL_ENABLED = cfg.enabled ~= false

local ROPE_TYPE               = ResolveRopeType(cfg.ropeType, 0, 'ropeType')
local ROPE_MAX_LENGTH_M       = ResolvePositiveNumber(
    cfg.ropeMaxLengthMeters,
    (type(Config.LeashMaxDistance) == 'number' and Config.LeashMaxDistance > 0 and Config.LeashMaxDistance or 8.0) * 1.5,
    'ropeMaxLengthMeters'
)
-- 0.0 is a valid, meaningful "can go fully slack" value -- same
-- zero-is-truthy trap as bone indices, so this is its own explicit
-- non-negative check, never `cfg.ropeMinLengthMeters or 0.0`.
local ROPE_MIN_LENGTH_M = (type(cfg.ropeMinLengthMeters) == 'number' and cfg.ropeMinLengthMeters == cfg.ropeMinLengthMeters and cfg.ropeMinLengthMeters >= 0)
    and cfg.ropeMinLengthMeters or 0.0
local K9_BONE_INDEX            = ResolveBoneIndex(cfg.k9BoneIndex, 0, 'k9BoneIndex')
local OFFICER_BONE_INDEX       = ResolveBoneIndex(cfg.officerBoneIndex, 0, 'officerBoneIndex')
local ROPE_TEXTURE_TIMEOUT_MS  = ResolvePositiveNumber(cfg.ropeTextureTimeoutMs, 5000, 'ropeTextureTimeoutMs')
local HANDLE_PROP_MODEL        = (type(cfg.handleModel) == 'string' and cfg.handleModel ~= '') and cfg.handleModel or 'p_ing_dogleash01x'
local HANDLE_PROP_FALLBACK     = (type(cfg.handleFallbackModel) == 'string' and cfg.handleFallbackModel ~= '') and cfg.handleFallbackModel or 'prop_tennis_ball'

-- Entity-scoped statebag key -- see this file's header BYSTANDER
-- VISIBILITY section for the full design writeup. Set ONLY by the K9-role
-- client on its OWN ped; read by every client (participants and
-- bystanders alike).
local LEASH_VISUAL_STATE_KEY = 'john-k9:leashVisual'

-- MONITOR_TICK_MS: how often the reconciliation/liveness/own-death pass
-- below runs. 1000ms, matching client/propattachment.lua's/
-- client/vehicle.lua's own established own-death-poll interval for this
-- exact class of "not per-frame, just needs to eventually notice and clean
-- up" work -- a leash rope disappearing within ~1s of a death/disconnect/
-- scope-loss is more than responsive enough, and this is far below the
-- "no tight Wait(0) loop when the work doesn't need per-frame execution"
-- threshold this task's own performance rules set.
local MONITOR_TICK_MS = 1000

if not VISUAL_ENABLED then
    -- Genuinely inert: nothing below this point ever registers. Matches
    -- client/propattachment.lua's own "a disabled feature ships clients
    -- where the command/events do not exist AT ALL" posture, not merely
    -- hidden behind a per-handler early return.
    return
end

-- ======================================================================
-- ROPE TEXTURE LOADING -- bounded wait, give up LOUDLY (task requirement:
-- an invisible rope from unloaded textures is otherwise a silent failure
-- nobody finds out about). Same bounded-poll shape as
-- client/kennel.lua's/client/propattachment.lua's RequestModel polling,
-- adapted to RopeAreTexturesLoaded's own no-argument boolean-poll contract
-- instead.
-- ======================================================================
local ropeTexturesReady = false
local ropeTextureLoadGaveUp = false
local ropeTextureLoadNotified = false

--- @return boolean ready
local function EnsureRopeTexturesLoaded()
    if ropeTexturesReady then return true end
    if ropeTextureLoadGaveUp then return false end -- already gave up once this session -- see below; never re-poll a doomed load every single attach attempt

    if RopeAreTexturesLoaded() then
        ropeTexturesReady = true
        return true
    end

    RopeLoadTextures()
    local waited = 0
    while not RopeAreTexturesLoaded() and waited < ROPE_TEXTURE_TIMEOUT_MS do
        Wait(50)
        waited = waited + 50
    end

    if RopeAreTexturesLoaded() then
        ropeTexturesReady = true
        return true
    end

    -- GIVE UP LOUDLY. Console print (an operator diagnosing "no rope ever
    -- shows up" needs this in F8/server console) PLUS one player-facing
    -- notify for the client actually experiencing it (never spammed --
    -- latched via ropeTextureLoadNotified) -- this is the SAME total-failure
    -- severity client/propattachment.lua's own "both models fail" branch
    -- uses (locale('propattachment.vest_prop_load_failed')), not the
    -- quieter console-only fallback-breadcrumb one degree below it.
    ropeTextureLoadGaveUp = true
    print(('[John-K9] leashvisual.lua: RopeAreTexturesLoaded() never returned true within %dms -- the leash MECHANIC (client/movement.lua) is unaffected, but no leash rope will ever render on THIS client for the rest of this session. Check Config.LeashVisual.ropeTextureTimeoutMs if this is a slow-loading connection rather than a real failure.')
        :format(ROPE_TEXTURE_TIMEOUT_MS))
    if not ropeTextureLoadNotified then
        ropeTextureLoadNotified = true
        lib.notify({ title = locale('common.notify_title'), description = locale('leashvisual.rope_textures_unavailable'), type = 'error' })
    end
    return false
end

-- ======================================================================
-- ROPE RENDERING -- one local rope per K9-role server id THIS CLIENT
-- currently renders (participant or bystander -- every watching client
-- keeps its own independent rope entity; see this file's header for why
-- ropes cannot be shared/networked at the engine level). Keyed by the
-- K9's OWN server id (the statebag's writer), never by ped handle -- a
-- cached ped handle can go stale across a respawn, same reasoning
-- client/movement.lua's own elastic pull-back thread documents for
-- re-resolving its partner ped fresh every use rather than caching it.
-- ======================================================================

--- @type table<number, { ropeId: number, k9ServerId: number, officerServerId: number }>
local activeRopesByK9ServerId = {}

--- Last known statebag payload per K9 server id, kept even once the rope
--- itself is torn down (e.g. a temporary out-of-scope blip) -- see this
--- file's header "HONEST LIMIT" paragraph for exactly why this exists: it
--- is what lets the monitoring thread below RE-ATTEMPT a rope once an
--- entity streams back into scope, since AddStateBagChangeHandler itself
--- only fires again on an actual value CHANGE, never on re-entering scope.
--- @type table<number, { officerServerId: number }>
local knownLeashPairings = {}

--- @param k9ServerId number
local function DeleteLocalRope(k9ServerId)
    local entry = activeRopesByK9ServerId[k9ServerId]
    if not entry then return end
    activeRopesByK9ServerId[k9ServerId] = nil
    if DoesRopeExist(entry.ropeId) then
        DeleteRope(entry.ropeId)
    end
end

--- Computes the LOCAL offset (relative to `entity`'s own position/heading)
--- of `boneIndex` on that entity, via a real bone-index lookup -- never a
--- hand-picked world/local constant. See this file's header for the two
--- natives this composes and their verification.
--- GetWorldPositionOfEntityBone's own documented graceful-degradation for
--- an out-of-range index is the entity's own position (see
--- client/bonetool.lua's header) -- feeding that straight back through
--- GetOffsetFromEntityGivenWorldCoords degrades to (0,0,0), i.e. attach at
--- the entity's own origin, never a crash or a wild offset.
--- @param entity number
--- @param boneIndex number
--- @return number x, number y, number z
local function GetBoneLocalOffset(entity, boneIndex)
    local worldPos = GetWorldPositionOfEntityBone(entity, boneIndex)
    local offset = GetOffsetFromEntityGivenWorldCoords(entity, worldPos.x, worldPos.y, worldPos.z)
    return offset.x, offset.y, offset.z
end

--- Creates (once -- idempotent per k9ServerId) THIS client's own local
--- rope for a pairing. Every failure path is a silent-to-the-mechanic,
--- loud-to-the-console-or-player no-op -- the leash MECHANIC itself never
--- depends on this succeeding.
--- @param k9ServerId number
--- @param k9Ped number
--- @param officerServerId number
local function CreateLocalRope(k9ServerId, k9Ped, officerServerId)
    if activeRopesByK9ServerId[k9ServerId] then return end -- already rendering this pairing
    if k9ServerId == officerServerId then return end -- defensive: never a real payload shape, but cheap to refuse outright
    if not DoesEntityExist(k9Ped) or IsEntityDead(k9Ped) then return end

    local officerPlayer = GetPlayerFromServerId(officerServerId)
    if not officerPlayer or officerPlayer == -1 then return end
    local officerPed = GetPlayerPed(officerPlayer)
    if not officerPed or officerPed == 0 or not DoesEntityExist(officerPed) or IsEntityDead(officerPed) then return end

    if not EnsureRopeTexturesLoaded() then return end

    local k9Coords = GetEntityCoords(k9Ped)
    -- Param order/shape verified against AddRope's own natives.json entry
    -- (see this file's header) -- initLength is set equal to maxLength
    -- (matching that entry's own official example's initLength==maxLength
    -- choice) so the rope does not visually "snap" taut on its very first
    -- frame, before AttachEntitiesToRope repositions both ends a moment
    -- later this same tick.
    local ropeId = AddRope(
        k9Coords.x, k9Coords.y, k9Coords.z,
        0.0, 0.0, 0.0,
        ROPE_MAX_LENGTH_M,
        ROPE_TYPE,
        ROPE_MAX_LENGTH_M,
        ROPE_MIN_LENGTH_M,
        1.0,   -- lengthChangeRate -- irrelevant here (winding is never started, see header), kept a plausible positive number rather than 0
        false, -- onlyPPU
        false, -- collisionOn -- a cosmetic leash must never physically interact with the world (no yanking hazard, no perf cost from collision checks)
        false, -- lockFromFront -- irrelevant per this native's own documented conditional (only matters when maxLength is zero, which it never is here)
        1.0,   -- timeMultiplier -- normal physics rate
        false, -- breakable -- no in-world way to "shoot" a non-colliding cosmetic rope regardless
        0      -- unkPtr -- "always 0 in original scripts" per this native's own doc
    )

    if not DoesRopeExist(ropeId) then
        print('[John-K9] leashvisual.lua: AddRope did not return a valid rope handle -- skipping this rope (the leash mechanic itself is unaffected).')
        return
    end

    local k9OffsetX, k9OffsetY, k9OffsetZ = GetBoneLocalOffset(k9Ped, K9_BONE_INDEX)
    local officerOffsetX, officerOffsetY, officerOffsetZ = GetBoneLocalOffset(officerPed, OFFICER_BONE_INDEX)

    AttachEntitiesToRope(
        ropeId,
        k9Ped, officerPed,
        k9OffsetX, k9OffsetY, k9OffsetZ,
        officerOffsetX, officerOffsetY, officerOffsetZ,
        ROPE_MAX_LENGTH_M,
        false, false, -- p10/p11 -- undocumented BOOLs on this legacy native; see this file's header confidence note
        nil, nil      -- boneName1/boneName2 -- no confirmed bone NAME string for either skeleton (see header); offsets above already derive from a real bone INDEX instead
    )

    activeRopesByK9ServerId[k9ServerId] = { ropeId = ropeId, k9ServerId = k9ServerId, officerServerId = officerServerId }
end

-- ======================================================================
-- STATEBAG LISTENER -- runs on EVERY client (participants and bystanders
-- alike). See this file's header BYSTANDER VISIBILITY section for the
-- full design.
-- ======================================================================
AddStateBagChangeHandler(LEASH_VISUAL_STATE_KEY, nil, function(bagName, _key, value)
    local k9Ped = GetEntityFromStateBagName(bagName)
    if not k9Ped or k9Ped == 0 then return end

    local k9Player = NetworkGetPlayerIndexFromPed(k9Ped)
    if not k9Player or k9Player == -1 then return end -- defensive: this key is only ever written by this file's own writer below, always on a player ped
    local k9ServerId = GetPlayerServerId(k9Player)

    if type(value) == 'table' and type(value.officerServerId) == 'number' then
        knownLeashPairings[k9ServerId] = { officerServerId = value.officerServerId }
        CreateLocalRope(k9ServerId, k9Ped, value.officerServerId)
    else
        knownLeashPairings[k9ServerId] = nil
        DeleteLocalRope(k9ServerId)
    end
end)

-- ======================================================================
-- PARTICIPANT-SIDE WRITER + HANDLE PROP -- reacts to the SAME
-- 'john-k9:client:leashAttached'/'john-k9:client:leashDetached'
-- events client/movement.lua already registers its own handler for. This
-- file adds a second, independent handler for each -- see this file's
-- header for why that is safe and why no change to client/movement.lua
-- was needed.
-- ======================================================================

--- This client's OWN bookkeeping: did I (as the K9-role party) write the
--- statebag, and/or do I (as the officer-role party) currently have a
--- handle prop attached. Independent of activeRopesByK9ServerId above
--- (which tracks RENDERED ropes -- every nearby client, participants
--- included, keeps its own copy of that) -- these two track
--- PARTICIPANT-ONLY actions THIS client is personally responsible for
--- undoing, on any termination path, unconditionally.
local myLeashVisualStateWritten = false
local myHandleProp = nil

local function ClearMyLeashVisualState()
    if myLeashVisualStateWritten then
        myLeashVisualStateWritten = false
        local ped = PlayerPedId()
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            Entity(ped).state:set(LEASH_VISUAL_STATE_KEY, false, true)
        end
    end
    if myHandleProp then
        DetachAndDeleteProp(myHandleProp)
        myHandleProp = nil
    end
end

--- Step 1 of THIS FILE's own reaction to the leash forming -- see
--- client/movement.lua's own identical-named handler for the consent
--- handshake this is downstream of; this file does nothing until the
--- pairing is already server-confirmed.
--- @param partnerServerId number
--- @param isConstrained boolean -- true only on the K9-role party's client, per client/movement.lua's own documented contract for this event
RegisterNetEvent('john-k9:client:leashAttached', function(partnerServerId, isConstrained)
    -- SOURCE-ORIGIN GUARD -- same convention/confidence grading as
    -- client/movement.lua's own handler for this identical event (see
    -- that file's header for the full writeup, not re-derived here).
    if source ~= 65535 then return end
    if type(partnerServerId) ~= 'number' then return end

    if isConstrained then
        -- I am the K9-role party -- I am the SINGLE writer of the
        -- statebag that drives rendering on every observing client,
        -- participants and bystanders alike (see this file's header for
        -- why only this side ever writes, never both).
        local ped = PlayerPedId()
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            Entity(ped).state:set(LEASH_VISUAL_STATE_KEY, { officerServerId = partnerServerId }, true)
            myLeashVisualStateWritten = true
        end
    else
        -- I am the officer/handler-role party -- attach a leash-handle
        -- prop to my own hand (task item 3), via
        -- client/propattachment.lua's shared, already-verified
        -- AttachPropToOwnPed helper (never re-implemented here).
        -- Independent of whether the rope itself ever renders anywhere
        -- (e.g. rope textures failed on some OTHER client, or even on this
        -- one -- unrelated failure domains; this prop's success never
        -- depends on the rope's).
        if myHandleProp then
            -- STALE-STATE GUARD, same shape/reasoning as
            -- client/propattachment.lua's own attachK9Prop guard: a retried
            -- leashAttached delivery (e.g. a reconnect mid-flight) must
            -- never leave a first, orphaned handle prop un-tracked while a
            -- second one is created.
            DetachAndDeleteProp(myHandleProp)
            myHandleProp = nil
        end

        myHandleProp = AttachPropToOwnPed(
            HANDLE_PROP_MODEL, OFFICER_BONE_INDEX,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            true -- isNetworked: bystanders must see this too, same as client/propattachment.lua's own vest
        )

        if not myHandleProp then
            myHandleProp = AttachPropToOwnPed(
                HANDLE_PROP_FALLBACK, OFFICER_BONE_INDEX,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                true
            )
            if myHandleProp then
                print(('[John-K9] leashvisual.lua: handleModel "%s" failed to load, used handleFallbackModel "%s" instead -- see config.lua\'s Config.LeashVisual comment.')
                    :format(HANDLE_PROP_MODEL, HANDLE_PROP_FALLBACK))
            else
                print('[John-K9] leashvisual.lua: both handleModel and handleFallbackModel failed to load -- no handle prop for this leash (the rope and the leash mechanic itself are both unaffected).')
            end
        end
    end
end)

--- The pairing has ended, for ANY reason (manual detach, cert revocation,
--- partner disconnect) -- clears whichever of this client's own
--- contributions is active, unconditionally, no consent/role check of its
--- own (mirrors client/movement.lua's own DetachLeash() contract: works at
--- any time, for either role, with zero confirmation).
RegisterNetEvent('john-k9:client:leashDetached', function(_reason)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD -- see leashAttached above
    ClearMyLeashVisualState()
end)

-- ======================================================================
-- MONITORING THREAD -- the real termination/self-heal backstop. Runs
-- continuously at MONITOR_TICK_MS regardless of whether anything is
-- currently active (a near-no-op single `pairs()` walk over what is
-- typically an empty table the overwhelming majority of the time) --
-- same "one persistent low-frequency poll thread, cheap when idle" posture
-- client/propattachment.lua's own OWN-DEATH AUTO-DETACH thread already
-- establishes in this exact codebase, not something QA has ever flagged
-- as wasteful there. See this file's header CLEANUP section for the full
-- per-termination-path mapping this thread is part of.
-- ======================================================================
CreateThread(function()
    while true do
        Wait(MONITOR_TICK_MS)

        -- OWN-DEATH cleanup for whichever role THIS client is currently
        -- playing. Task requirement: "either player dying" -- when this file
        -- was written, server/main.lua's LeashPairs had NO death-triggered
        -- auto-detach of its own; that gap has SINCE been closed there (a
        -- dedicated death-poll thread, `IsLeashPartyDead`, now calls
        -- ForceDetachLeashForSource -- confirmed by reading that file), so
        -- a death today also fires leashDetached server-side. This poll is
        -- kept regardless, not made redundant by that fix: it is this
        -- client's own, purely local, zero-round-trip cleanup for its own
        -- ped, and still the only thing that clears a dead K9's statebag
        -- (or a dead officer's handle prop) instantly rather than waiting
        -- on the server's own ~2s poll cadence and a network round trip.
        local myPed = PlayerPedId()
        if (myLeashVisualStateWritten or myHandleProp) and myPed and myPed ~= 0 and IsEntityDead(myPed) then
            ClearMyLeashVisualState()
        end

        -- RENDERED-ROPE LIVENESS -- runs for every pairing THIS client
        -- currently renders a rope for (participant or bystander alike),
        -- independent of whether the statebag's OWN writer ever clears it.
        -- This is the real "never gate a termination path" backstop: even
        -- if the K9's own client never clears the statebag (crashed, hung,
        -- or a disconnect whose statebag-removal semantics this file does
        -- not assume -- see header BYSTANDER VISIBILITY section), every
        -- OTHER client rendering that pairing's rope independently notices
        -- via DoesEntityExist/IsEntityDead on the SAME networked peds and
        -- tears its own copy down regardless. Also covers "entity going
        -- out of scope" (a streamed-out ped just reads as
        -- not-DoesEntityExist here, same handling as a death).
        local toRemove = nil
        for k9ServerId, entry in pairs(activeRopesByK9ServerId) do
            local k9Player = GetPlayerFromServerId(entry.k9ServerId)
            local k9Ped = (k9Player and k9Player ~= -1) and GetPlayerPed(k9Player) or 0
            local officerPlayer = GetPlayerFromServerId(entry.officerServerId)
            local officerPed = (officerPlayer and officerPlayer ~= -1) and GetPlayerPed(officerPlayer) or 0

            local stillValid = k9Ped ~= 0 and DoesEntityExist(k9Ped) and not IsEntityDead(k9Ped)
                and officerPed ~= 0 and DoesEntityExist(officerPed) and not IsEntityDead(officerPed)
                and DoesRopeExist(entry.ropeId)

            if not stillValid then
                toRemove = toRemove or {}
                toRemove[#toRemove + 1] = k9ServerId
            end
        end
        if toRemove then
            for _, k9ServerId in ipairs(toRemove) do
                DeleteLocalRope(k9ServerId)
            end
        end

        -- RECONCILIATION -- see this file's header "HONEST LIMIT"
        -- paragraph: re-attempts a rope for any pairing this client still
        -- believes is active (per the last statebag value it saw) but is
        -- not currently rendering, e.g. because the K9/officer ped had
        -- temporarily streamed out of THIS client's scope when the value
        -- last changed, or because EnsureRopeTexturesLoaded() had not yet
        -- succeeded on the first attempt. CreateLocalRope is itself a safe
        -- no-op if the pairing genuinely still is not resolvable this
        -- tick, so this loop costs nothing extra beyond one more table
        -- walk (typically also empty) when nothing needs healing.
        for k9ServerId, pairing in pairs(knownLeashPairings) do
            if not activeRopesByK9ServerId[k9ServerId] then
                local k9Player = GetPlayerFromServerId(k9ServerId)
                local k9Ped = (k9Player and k9Player ~= -1) and GetPlayerPed(k9Player) or 0
                if k9Ped ~= 0 and DoesEntityExist(k9Ped) then
                    CreateLocalRope(k9ServerId, k9Ped, pairing.officerServerId)
                end
            end
        end
    end
end)

-- ======================================================================
-- RESOURCE STOP -- the last unconditional chance to clean up, same
-- convention/placement as client/vehicle.lua's own onResourceStop handler
-- (see that file's header for the "why onResourceStop is mandatory, not
-- merely nice to have" writeup this mirrors). Clears BOTH this client's
-- own participant-side contribution (whichever role it was playing, if
-- any) AND every rope THIS client is currently rendering as an observer
-- (participant or bystander) -- a rope handle that outlives its owning
-- script instance is a permanent local-physics artifact for that one
-- client until their own game process ends, which is exactly the "never
-- leave a stray world artifact behind" rule this task's cleanup
-- requirement exists to enforce.
-- ======================================================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    ClearMyLeashVisualState()

    local allK9ServerIds = {}
    for k9ServerId in pairs(activeRopesByK9ServerId) do
        allK9ServerIds[#allK9ServerIds + 1] = k9ServerId
    end
    for _, k9ServerId in ipairs(allK9ServerIds) do
        DeleteLocalRope(k9ServerId)
    end
end)
