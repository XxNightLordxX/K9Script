--[[
    john-k9/server/entities.lua

    Consolidates two responsibilities shared across several files:
    resolving a client-claimed network id to a live entity defensively, and
    a cross-feature netId claim registry that stops one feature's confirm
    handshake from hijacking another feature's already-claimed object. See
    DEVELOPER_REFERENCE.md's near-term item 2 ("Extract the 'resolve network
    entity defensively' helper — same call, now backed by several real
    instances") for the origin of ResolveNetworkEntity below: a pure
    structural extraction, not a redesign.

    WHY A SEPARATE FILE FROM server/cooldowns.lua: a shared file is scoped
    to ONE responsibility so it doesn't balloon into an everything-file --
    "does this client-claimed netId actually resolve to something real" is
    a genuinely different responsibility than a cooldown/mutex timer, so
    this primitive gets its own file rather than becoming a second concern
    bolted onto cooldowns.lua, which stays scoped to timing/mutex state only.

    Loaded in fxmanifest.lua's server_scripts immediately after
    server/cooldowns.lua and before server/main.lua/server/search.lua.
    ResolveNetworkEntity() below is only ever called at RUN time from
    inside an event/callback handler, so this file's exact position
    relative to main.lua/search.lua isn't itself load-bearing the way
    cooldowns.lua's constructors are -- it's placed alongside cooldowns.lua,
    before both consumers, to read in the same "shared primitive first"
    order.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes TWO resource-global (no `local`) functions:
        ResolveNetworkEntity(netId: number, expectedEntityType: number?) -> number?
      Used by server/main.lua's relayDoorScratch (called WITH
      expectedEntityType = 3, restricting the resolve to objects only --
      see that call site's own comment for why that number) and
      server/search.lua's HandleSearchTarget (called WITHOUT
      expectedEntityType -- that file's own targetType-vs-GetEntityType
      cross-check branches into further target-specific logic beyond a
      simple reject-or-continue gate, so it stays entirely AT that call
      site, deliberately not folded in here; see HandleSearchTarget's own
      comment). Both call sites' existing entity-type/proximity checks are
      preserved exactly -- this file only consolidates the common
      "resolve + existence-guard" prefix both of them already did
      independently. Per DEVELOPER_REFERENCE.md item 2, also reused by
      server/kennel.lua (3 call sites) and server/inventory.lua (1 call
      site) -- see each call site's own comment for exactly what moved here
      and what deliberately did not.
        ResolveConnectedPlayerFromPed(entity: number) -> number?
      DEVELOPER_REFERENCE.md item 2b ("scan connected players, match by ped,
      return the server id" -- same responsibility as ResolveNetworkEntity
      above, not a new shared-utility concern). Its own "DELIBERATE
      IMPLEMENTATION CHOICE" doc comment below (reasoning about why this
      scans GetPlayers()/GetPlayerPed() rather than the unverified
      GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity)) combo) applies
      equally to every caller: server/search.lua's HandleSearchTarget
      ('person' branch), server/inventory.lua's HandleOpenK9Inventory, and
      server/combat.lua's ValidateCombatRequest (player-vs-NPC resolution).

      CROSS-FEATURE NETID CLAIM REGISTRY, closing a residual gap that
      spans files none of them could close alone:
        ClaimNetworkEntity(netId: number, feature: string, ownerId: string)
        ReleaseNetworkEntity(netId: number, feature: string, ownerId: string)
        IsNetworkEntityClaimedByOther(netId: number, feature: string, ownerId: string) -> boolean
      See this file's own dedicated header section below (immediately above
      `ClaimedNetworkEntities`'s declaration) for the full exploit this
      closes and why a shared table was chosen here over retrofitting
      server/propattachment.lua's own NetworkGetEntityOwner-based guard
      into the other two files. Used by server/kennel.lua's
      confirmKennelPlaced, server/fetch.lua's confirmFetchBallThrown/
      confirmFetchBallCarried/confirmFetchBallDropped, and
      server/propattachment.lua's confirmPropAttached -- every call site's
      own comment says exactly which of the three functions it calls and
      why.
    ======================================================================
]]

--- Resolves a client-claimed network id to a live, currently-existing
--- entity handle, server-side. Returns nil (never 0, and never a
--- stale/nonexistent handle) if `netId` isn't a number, doesn't currently
--- resolve to anything real, or (when `expectedEntityType` is supplied)
--- resolves to an entity whose GetEntityType doesn't match.
---
--- Extracted from two independent hand-written copies of this exact
--- "resolve -> existence-guard" prefix:
--- - server/main.lua's relayDoorScratch: was
---     local doorEntity = NetworkGetEntityFromNetworkId(doorNetId)
---     if doorEntity == 0 or not DoesEntityExist(doorEntity) then return end
---   followed, a few lines later (after the proximity check), by a
---   SEPARATE `if GetEntityType(doorEntity) ~= 3 then return end`. Both
---   checks are preserved here exactly -- relayDoorScratch now passes
---   expectedEntityType = 3, which performs the identical type-3-only
---   restriction as one call instead of two, still failing closed on any
---   mismatch. GetEntityType: 1 = ped, 2 = vehicle, 3 = object.
--- - server/search.lua's HandleSearchTarget: was
---     local entity = NetworkGetEntityFromNetworkId(targetNetId)
---     if entity == 0 then return { ok = false, reason = 'invalid_target' } end
---   -- no DoesEntityExist call. This helper's existence guard therefore
---   adds that check for every caller including this one: a DELIBERATE,
---   DISCLOSED STRENGTHENING of that call site's existence check, never a
---   weakening. Flagged explicitly, not silently folded in: in practice
---   this is not expected to change observed behavior, since
---   NetworkGetEntityFromNetworkId returning a nonzero handle for an
---   entity that fails DoesEntityExist in the very same tick is not a
---   case this native is documented or observed to produce -- the
---   existing "0 or not DoesEntityExist" pairing already treated in
---   relayDoorScratch's own pre-extraction code is belt-and-suspenders,
---   not two independently load-bearing conditions. HandleSearchTarget's
---   targetType cross-check (GetEntityType vs. the caller-claimed
---   'vehicle'/'person', which branches into further person-only
---   resolution logic) is NOT passed as expectedEntityType here and stays
---   entirely at that call site -- see server/search.lua's own comment.
--- SECURITY BOUNDARY -- exactly what this function does and does not
--- guarantee, spelled out explicitly since every caller layers its own
--- additional checks on top of this one and needs to know where this
--- function's own guarantee ends (audited as a security primitive, not
--- just a convenience wrapper):
---
--- GUARANTEES (enforced, not advisory -- every one of these is a hard
--- `return nil`, never a soft/logged pass-through):
---   - `netId` is actually a number (rejects a client payload of the wrong
---     Lua type outright -- see NOTE below on what "a number" does NOT mean).
---   - The entity EXISTS AT THE INSTANT OF THIS CALL (DoesEntityExist,
---     checked in addition to NetworkGetEntityFromNetworkId's own `~= 0`
---     result -- this is a real strengthening over one of the two original
---     pre-extraction call sites, see the doc comment below).
---   - IF `expectedEntityType` is supplied, GetEntityType(entity) matches it
---     EXACTLY. This is enforced, not a hint: a mismatch is a hard `nil`
---     return, identical to a nonexistent entity. There is no partial/
---     advisory mode -- a caller either passes the type it needs and gets a
---     hard reject on mismatch, or omits it and gets zero type filtering at
---     all (see server/search.lua's HandleSearchTarget, which deliberately
---     omits it to run its own richer targetType-vs-GetEntityType branch).
---
--- DOES NOT GUARANTEE (every one of these is the CALLER's own
--- responsibility, and every current caller in this resource does layer
--- its own check for whichever of these it actually needs -- see each call
--- site's own "expectedEntityType = N" / proximity-check comment):
---   - Ownership or proximity. This function has no concept of "belongs to
---     the requesting player" or "is anywhere near the requesting player" --
---     a client can name ANY currently-networked entity of the right type
---     anywhere on the map (another player's vehicle, another player's own
---     ped if expectedEntityType = 1, a prop on the far side of the map) and
---     this function will happily resolve it. Every caller that needs
---     "near me" (server/main.lua's relayDoorScratch) or "belongs to a
---     specific player" (server/combat.lua's self-target reject,
---     server/search.lua's ResolveConnectedPlayerFromPed cross-check) adds
---     that check itself, separately, AFTER this call succeeds.
---   - A specific model/allowlist. GetEntityType only distinguishes
---     ped/vehicle/object (1/2/3) -- it says nothing about WHICH ped model,
---     vehicle model, or object model. Every caller that needs "specifically
---     a K9" (IsConfiguredK9Model) or "specifically a door prop" layers that
---     model check on top, separately, after this call succeeds. Passing
---     expectedEntityType = 1 (ped) narrows "any networked entity" down to
---     "any networked ped" -- it does NOT narrow it to "a K9" or "a specific
---     player's ped".
---   - Continued existence AFTER this call returns. The returned handle is
---     only proven live at the instant this function checked it. It is NOT
---     re-checked, and this function has no way to re-check it later -- a
---     caller that yields (Wait, an `await`ed DB/inventory call) between
---     calling this and actually USING the handle must re-resolve or
---     otherwise re-validate before that later use if the gap matters for
---     its own correctness. Several callers in this resource already do
---     this explicitly (e.g. server/combat.lua's HandleTakedownRequest
---     re-running its full ValidateCombatRequest, including a fresh
---     ResolveNetworkEntity, after its own Wait(); server/search.lua's
---     HandleSearchTarget re-checking `GetPlayerPed(targetServerId) ~=
---     entity` immediately after its own awaited ox_inventory call for the
---     'person' branch) -- that re-validation is the CALLER's job, not
---     something this function can retroactively provide.
---   - That a numeric `netId` is a sane/in-range network id. `type(netId)
---     == 'number'` rejects the wrong Lua type only (a string, a table, nil)
---     -- it does not range-check, floor a non-integer float, or reject a
---     negative number. Any of those simply fail to resolve to a real
---     entity via NetworkGetEntityFromNetworkId (which returns 0 for
---     anything it doesn't recognize) and fall through to this function's
---     own `entity == 0` guard below, so they're still rejected -- just via
---     the existence check, not the type check.
--- @param netId number
--- @param expectedEntityType number? -- 1 = ped, 2 = vehicle, 3 = object (GetEntityType); omit to skip this check. Enforced (hard reject on mismatch), not advisory -- see this doc comment's GUARANTEES section above.
--- @return number? entity
function ResolveNetworkEntity(netId, expectedEntityType)
    if type(netId) ~= 'number' then return nil end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    if expectedEntityType and GetEntityType(entity) ~= expectedEntityType then
        return nil
    end

    return entity
end

--- Resolves a ped entity to the currently-connected player's server id it
--- belongs to, or nil if it doesn't belong to any currently-connected
--- player (an NPC, or a stale/despawned handle).
---
--- DEVELOPER_REFERENCE.md item 2b. Extracted from three independent,
--- byte-identical hand-written copies of this exact function:
--- server/search.lua's original (the first-written, most-documented copy,
--- whose own doc comment is preserved below verbatim), server/inventory.lua's
--- `HandleOpenK9Inventory`, and server/combat.lua's `ValidateCombatRequest`
--- player-vs-NPC resolution. All three now call this single function
--- instead.
---
--- DELIBERATE IMPLEMENTATION CHOICE (preserved from server/search.lua's
--- original doc comment -- this reasoning applies equally to every caller,
--- not just the one that first wrote it): the design notes server/search.lua
--- was built from (DEVELOPER_REFERENCE.md#contraband-search §3 step 9, and
--- that file's own prior scaffold) suggested
--- `GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))` for this
--- resolution. That combination was never independently re-verified as
--- reliably callable SERVER-side (both natives are historically associated
--- with the client-side "local player pool" concept, which the FXServer
--- process -- running no game-world simulation at all -- may not expose the
--- same way). Rather than depend on an unverified native combo for a
--- security-relevant check, this resolves the same fact (does this entity
--- belong to a real, currently-connected player?) using only natives
--- already proven reliable SERVER-side elsewhere in this exact codebase
--- (`GetPlayers()`/`GetPlayerPed(source)` -- already used in
--- server/certifications/ and server/main.lua): scan every connected
--- player's own ped and match by entity handle. This is strictly more
--- conservative (it can only ever match an entity that IS some connected
--- player's own ped) and avoids introducing a new, unverified native
--- dependency on this security-sensitive check.
--- @param entity number
--- @return number? targetServerId
function ResolveConnectedPlayerFromPed(entity)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if playerId and GetPlayerPed(playerId) == entity then
            return playerId
        end
    end
    return nil
end

--[[
    ======================================================================
    CROSS-FEATURE NETID CLAIM REGISTRY.

    THE GAP THIS CLOSES: three independent features each run a client-claimed-
    netId confirm handshake and each already guards its OWN registry against
    a same-feature collision -- server/kennel.lua's FindKennelOwnerByNetId
    (Kennels), server/fetch.lua's FindOtherBallByNetId (FetchBalls),
    server/propattachment.lua's FindOtherPropAttachmentByNetId
    (PropAttachmentState) -- but none of the three can see the other two's
    registries. config.lua configures Config.DeployableKennel.fallbackPropModel,
    Config.FetchMechanic.ballPropModel, and Config.PropAttachments.fallbackPropModel
    to the IDENTICAL 'prop_tennis_ball' model (the one prop in this resource
    with a confirmed-real, source-verified track record -- see config.lua's
    own comment on why the other two are unverified guesses this resource
    deliberately does not replace, and why substituting a distinct model for
    two of the three would trade a security gap for a silent "prop never
    loads" gap instead). A netId naming another citizen's real, live object
    from a DIFFERENT feature is therefore a real object, of a model every one
    of the three files' own allowlists accepts, that is simply absent from
    the checking file's OWN registry -- passing that file's own same-feature
    check.

    TWO exploitable shapes this was found to enable, not just one:
      (a) The originally-scoped shape: the netId lands on a REJECTION branch
          (TTL expiry, a feature-flag toggle, a certification revoke, an
          already-active-limit race, too-far-from-spawn) whose own
          `safeToCleanup`-style gate only re-checked the SAME registry, so it
          read as "safe" and the cross-feature victim's real object was
          deleted/instructed-to-be-deleted.
      (b) The more severe shape: the netId reaches a file's own SUCCESS path
          outright (no rejection branch needed at all) because it is
          genuinely unclaimed IN THAT FILE'S registry -- e.g.
          server/fetch.lua's confirmFetchBallThrown writing
          `FetchBalls[citizenid] = { netId = <a victim's real kennel's netId>, ... }`,
          after which the attacker's own subsequent, ordinary
          requestRecallFetchBall deletes the victim's kennel. Every WRITE
          site (a brand-new registry entry, or overwriting an existing
          entry's `.netId` field) needed the identical fix as every
          REJECTION-branch cleanup gate, not just the latter.

    THE FIX: a single shared table below, plus three resource-global
    functions. Every one of the three files' own successful WRITES calls
    `ClaimNetworkEntity`; every one of their own REMOVALS (or netId
    overwrites -- release the OLD value, then claim the NEW one) calls
    `ReleaseNetworkEntity`; and every one of their own safeToCleanup/pre-write
    uniqueness checks additionally consults `IsNetworkEntityClaimedByOther`
    -- see each call site's own comment in server/kennel.lua/server/fetch.lua/
    server/propattachment.lua for exactly which of the three it calls and
    why. This is ADDITIVE, never a replacement for each file's own existing
    same-feature FindXByNetId check -- both stay in place, layered, per this
    resource's established "layered checks over a single point of failure"
    convention (server/propattachment.lua's own GLOBAL NETID-UNIQUENESS
    GUARD/NETWORK-OWNERSHIP GUARD pairing is the precedent this mirrors).

    WHY A SHARED TABLE, NOT server/propattachment.lua's NetworkGetEntityOwner-
    BASED GUARD (a stronger, native-backed check that file already uses for
    its own, narrower first-writer-wins race): considered, and rejected for
    server/kennel.lua and server/fetch.lua specifically. Retrofitting a
    NetworkGetEntityOwner mock into those two files' already-large,
    already-green spec suites would mean auditing and updating the implicit
    "who currently network-owns this handle" assumption on nearly every
    existing test case that registers an entity -- a much larger,
    higher-regression-risk diff for no closer a fix. The shared registry
    closes the exact same class of gap (a client-reported netId genuinely
    belongs to someone else's real object) without touching either file's
    existing entity model, and is purely additive: it cannot change the
    outcome for any existing honest-flow test, since the new condition is
    only ever false when a DIFFERENT feature or DIFFERENT owner already
    legitimately holds that exact netId, which never happens for an honest
    client naming its own, never-yet-claimed creation.
    server/propattachment.lua's own NetworkGetEntityOwner guard stays exactly
    as it is and already independently closes this same class of gap for
    that file (a cross-citizen/cross-feature attacker can never be the
    current network owner of an entity they did not create) -- this registry
    is layered ON TOP of it there too, both for defense-in-depth consistency
    across all three files and because server/kennel.lua's and
    server/fetch.lua's own checks need propattachment's claims recorded here
    to see them at all.

    NO NEW "UNBOUNDED TRAP": this registry only ever makes an existing
    safeToCleanup/pre-write check MORE conservative (an additional `and`
    condition, never a removed one) or blocks a WRITE that would otherwise
    have hijacked a foreign object into the wrong registry -- it never gates
    a genuine owner's own termination/cleanup path (RemoveKennelForCitizenid,
    EndFetchCycle, RemovePropAttachmentForCitizenid, and every
    playerDropped/onResourceStop/maintenance-thread sweep that funnels
    through them) on anything. See each of those three files' own updated
    call sites for the walk-through of why disconnect/resource-stop/TTL-
    expiry cleanup for a GENUINE owner is unaffected.

    LOAD ORDER: this file already loads before server/kennel.lua,
    server/fetch.lua, and server/propattachment.lua (fxmanifest.lua's
    server_scripts list) for ResolveNetworkEntity's sake -- no new ordering
    requirement.
    ======================================================================
]]

-- ClaimedNetworkEntities[netId] = { feature: string, ownerId: string } --
-- see this file's own CROSS-FEATURE NETID CLAIM REGISTRY header section
-- immediately above. Local: reached only through the three functions below,
-- never read directly by another file.
local ClaimedNetworkEntities = {}

--- Records that `netId` is now claimed by `feature` (a short, fixed string
--- identifying the calling file -- every current caller passes exactly one
--- of 'kennel' / 'fetch' / 'propattachment', though this function does not
--- itself enforce that list) on behalf of `ownerId` (that feature's own
--- citizenid). MUST be called at every point one of those three files writes
--- a client-reported netId into its own registry -- a brand-new entry, or
--- overwriting an existing entry's `.netId` field (release the OLD value
--- first via ReleaseNetworkEntity, THEN claim the new one here, so the
--- registry never simultaneously double-claims a netId that briefly used to
--- belong to the same citizenid's own prior value). Safe to call repeatedly
--- for the same (netId, feature, ownerId) triple -- simply overwrites.
--- Silently does nothing if `netId` is not a number (defensive; every
--- current caller has already resolved a real, live entity from `netId`
--- before reaching this call, so this guard is not expected to trigger in
--- practice).
--- @param netId number
--- @param feature string
--- @param ownerId string
function ClaimNetworkEntity(netId, feature, ownerId)
    if type(netId) ~= 'number' then return end
    ClaimedNetworkEntities[netId] = { feature = feature, ownerId = ownerId }
end

--- Clears `netId`'s claim, but ONLY if it is currently recorded against the
--- EXACT (feature, ownerId) pair supplied -- this function never blindly
--- clears whatever is there, so one feature/citizen can never accidentally
--- (or via a bug elsewhere) release a claim it does not itself hold. MUST be
--- called at every point one of the three files above stops tracking a netId
--- it previously claimed: a full registry-entry removal
--- (RemoveKennelForCitizenid, EndFetchCycle, RemovePropAttachmentForCitizenid),
--- or overwriting an entry's `.netId` field with a NEW value (release the
--- OLD value here first, then ClaimNetworkEntity the new one). A no-op if
--- `netId` was never claimed, or is currently claimed by a DIFFERENT
--- (feature, ownerId) pair than the one supplied.
--- @param netId number
--- @param feature string
--- @param ownerId string
function ReleaseNetworkEntity(netId, feature, ownerId)
    if type(netId) ~= 'number' then return end
    local claim = ClaimedNetworkEntities[netId]
    if claim and claim.feature == feature and claim.ownerId == ownerId then
        ClaimedNetworkEntities[netId] = nil
    end
end

--- Returns true if `netId` is CURRENTLY claimed by anyone OTHER than
--- (feature, ownerId) -- a different feature entirely, or the same feature
--- under a different ownerId. Returns false if `netId` is unclaimed, or
--- already claimed by this exact (feature, ownerId) pair (a caller
--- re-confirming/overwriting its OWN prior claim is never a collision with
--- itself). Every one of the three files' own safeToCleanup-style
--- rejection-branch checks and pre-write uniqueness checks MUST additionally
--- require this to return false before either (a) treating a client-reported
--- netId as safe to delete/instruct-a-delete-for, or (b) writing it into
--- that file's own registry -- see this file's own header section above for
--- the exact exploit (in both its rejection-branch and plain-success-path
--- shapes) this closes. Returns false (never claimed) if `netId` is not a
--- number.
--- @param netId number
--- @param feature string
--- @param ownerId string
--- @return boolean
function IsNetworkEntityClaimedByOther(netId, feature, ownerId)
    if type(netId) ~= 'number' then return false end
    local claim = ClaimedNetworkEntities[netId]
    if not claim then return false end
    return claim.feature ~= feature or claim.ownerId ~= ownerId
end
