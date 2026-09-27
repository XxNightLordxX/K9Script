--[[
    qbx_k9unit/client/fetch.lua

    Client half of Config.Features.FetchMechanic — see server/fetch.lua's
    header for the full event contract, the state machine, the
    entity-theft/trust-boundary discipline, and the "why the return-to-
    handler leg is player-driven, not scripted" reasoning. Read that file
    first.

    ======================================================================
    SHARED BONE-INDEX / ATTACH SURFACE — COORDINATION NOTE: this file
    reuses client/propattachment.lua's `AttachPropToOwnPed(modelName,
    boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, isNetworked,
    timeoutMs) -> entity?` and `DetachAndDeleteProp(entity?)` directly, per
    that file's own documented cross-feature contract ("FetchMechanic's own
    client file should call those same two functions ... rather than
    hand-rolling a third copy of that mechanic") and server/bonetool.lua's
    "EXPOSED SURFACE FOR FetchMechanic" note — this file does NOT build a
    second bone-index sweep tool, and does NOT hand-write its own
    AttachEntityToEntity call for the 'attach' carry path.

    ONE ADAPTATION, DISCLOSED: `AttachPropToOwnPed` always CREATES a brand
    new object — it has no "attach this already-existing, already-thrown,
    already-server-tracked entity" mode, because PropAttachments' own vest
    is a purely cosmetic, always-freshly-spawned prop with no prior
    existence. A fetch ball, by contrast, already exists (the thrower's
    client created and threw it) before a K9 ever picks it up. Rather than
    hand-roll a second attach primitive for that one difference, this file
    deletes the pre-existing ball and calls `AttachPropToOwnPed` to create
    its mouth-carried replacement — visually identical to the player, and
    it means this file genuinely reuses the shared mechanic end-to-end
    rather than only borrowing its shape. The resulting NEW entity's netId
    is reported back to the server (`confirmFetchBallCarried`) so
    server/fetch.lua's registry stays in sync — see that file's own header
    for the full two-phase pickup design this implies.

    `Config.FetchMechanic.mouthBoneIndex`/`mouthOffsetX/Y/Z`/`mouthCarryMode`
    mirror `Config.PropAttachments`' own flat, single-value, no-per-model-
    table shape exactly (a deliberate departure from DEVELOPER_REFERENCE.md's
    earlier, more elaborate `Config.K9BoneIndices[model]` draft, superseded
    by what the concurrently-built sibling feature actually shipped) —
    `mouthBoneIndex` defaults to `0` (root bone, always valid, never a
    crash) and ships in `mouthCarryMode = 'fake'` until a developer's own
    `/k9bonetool` session confirms a real mouth/jaw index and a bark/pant-
    scenario clipping check passes for it.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE calls client/main.lua's CanShowK9UI()/DenyK9UIAccess()/
      HasK9Access()/ResolveNetworkEntity()/ResolvePlayerServerIdFromPed(),
      and client/propattachment.lua's AttachPropToOwnPed()/
      DetachAndDeleteProp() — must load after both of those files (see
      fxmanifest.lua's own ordering note for this file).
    - THIS FILE exposes four resource-global (no `local`) functions, for a
      future client/radial.lua entry to call — same "global helper, private
      per-file state" convention as client/kennel.lua's RequestDeployKennel:
        RequestThrowFetchBall() -- self-initiated; gated on HasK9Access()
        ReleaseFetchBall()      -- always available while carrying, no gate
        RequestRecallFetchBall() -- thrower's own early-interrupt
        IsFetchCarryEngaged() -> boolean
      client/radial.lua now calls all four of these (behind its own
      `type(fn) == 'function'` runtime existence guard, since none of them
      exist when Config.Features.FetchMechanic is false and this whole file
      returns early below). RegisterCommand entries below
      ('/k9throwfetchball', '/k9dropfetchball' (drop), '/k9recallfetchball')
      remain as an equally valid, independent entry point either way.
      "Pick Up Ball" and "Deliver to Handler" are ox_target options (both
      below).
]]

if not Config.Features.FetchMechanic then return end

local REQUEST_MODEL_TIMEOUT_MS = 5000

local FetchBallModelHashes = {
    [GetHashKey(Config.FetchMechanic.ballPropModel)] = true,
}

-- ActiveFetchCarry: nil, or { netId: number?, mode: 'attach'|'fake' } while
-- THIS client is currently carrying a fetch ball. netId is nil only for the
-- instant between deleting the old entity and AttachPropToOwnPed returning
-- the new one in 'attach' mode.
local ActiveFetchCarry = nil

-- myThrownBallNetId: netId of a fetch-related object THIS client most
-- recently created (a throw, or a 'fake'-mode drop recreate) and is still
-- tracked as active server-side — read by onResourceStop below (mirrors
-- client/kennel.lua's myKennelNetId exactly) AND by the CONFIRM-FAILURE
-- BACKSTOP thread further down this file.
local myThrownBallNetId = nil

-- myThrownBallDeadlineAt: GetGameTimer() value at/after which the CONFIRM-
-- FAILURE BACKSTOP thread below may reclaim myThrownBallNetId's entity even
-- without ever hearing back from the server. Set alongside every
-- myThrownBallNetId assignment; see that thread's own header comment for why
-- this specific bound is always safe.
local myThrownBallDeadlineAt = nil

-- Margin added on top of Config.FetchMechanic.maxBallLifetimeMs before the
-- CONFIRM-FAILURE BACKSTOP thread will act, purely to absorb round-trip/
-- timer jitter around the server's own maintenance-sweep despawn of a
-- legitimately-confirmed ball — never the actual reason a rejected confirm
-- eventually gets cleaned up (that's maxBallLifetimeMs itself).
local THROWN_BALL_BACKSTOP_MARGIN_MS = 15000

--- Sets myThrownBallNetId and its matching backstop deadline together —
--- every assignment site must go through this so the two never drift apart.
--- @param netId number
local function SetMyThrownBall(netId)
    myThrownBallNetId = netId
    myThrownBallDeadlineAt = GetGameTimer() + Config.FetchMechanic.maxBallLifetimeMs + THROWN_BALL_BACKSTOP_MARGIN_MS
end

--- Clears both together — every clear site must go through this for the
--- same reason as SetMyThrownBall above.
local function ClearMyThrownBall()
    myThrownBallNetId = nil
    myThrownBallDeadlineAt = nil
end

--- Duplicated per this resource's established "tiny helper, private per
--- file" convention (see client/kennel.lua's own LoadModelWithTimeout,
--- which this mirrors exactly) — used only for the two call sites that do
--- NOT go through client/propattachment.lua's AttachPropToOwnPed (the
--- initial throw, and a 'fake'-mode drop recreate — neither attaches
--- anything).
--- @param modelName string
--- @return number? modelHash
local function LoadModelWithTimeout(modelName)
    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then
        return nil
    end

    RequestModel(modelHash)
    local waited = 0
    while not HasModelLoaded(modelHash) and waited < REQUEST_MODEL_TIMEOUT_MS do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        -- LEAK FIX (client/kennel.lua's own identical, previously-fixed
        -- LEAK FIX precedent — "every RequestModel in this resource must
        -- have a matching SetModelAsNoLongerNeeded on every exit path,
        -- including this failure one"): RequestModel above already
        -- incremented this model's streaming reference count; giving up on
        -- the timeout without releasing it here leaves that reference held
        -- forever, since neither of this function's two call sites (the
        -- initial throw, the 'fake'-mode drop recreate) has any other
        -- reason to know THIS particular request ever happened once it
        -- returns nil.
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end
    return modelHash
end

--- WORLD_DOG_BARKING_* carry-pose stand-in for 'fake'-mode carry —
--- duplicated (not shared) from client/combat.lua's own
--- K9_BITE_HOLD_SCENARIO_BY_MODEL_HASH table per this resource's
--- established "duplicate a small table, don't reach into another file's
--- internals" convention (see that file's own header for the precedent).
--- CONFIDENCE: same as that table's own grading — HIGH that the scenario
--- strings exist, MEDIUM on the breed-to-scenario mapping for
--- a_c_chop/a_c_husky. OPEN QUESTION, NOT assumed resolved (DEVELOPER_REFERENCE.md
--- §14.4.3's own flagged item): no research pass has confirmed any
--- WORLD_DOG_BARKING_* scenario actually reads as "carrying something in
--- mouth" versus just "barking" — this is the best available stand-in, not
--- a verified-correct pose.
local K9_FETCH_CARRY_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_BARKING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_BARKING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_BARKING_ROTTWEILER',
    a_c_husky = 'WORLD_DOG_BARKING_RETRIEVER',
}) do
    K9_FETCH_CARRY_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_FETCH_CARRY_DEFAULT_SCENARIO = 'WORLD_DOG_BARKING_SHEPHERD'

local function PlayFetchCarryStance(ped)
    local scenarioName = K9_FETCH_CARRY_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_FETCH_CARRY_DEFAULT_SCENARIO
    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
end

--- @return boolean
--- @return boolean -- a ball THIS client threw is still out (thrown, carried or dropped)
function IsMyFetchBallOut()
    return myThrownBallNetId ~= nil
end

function IsFetchCarryEngaged()
    return ActiveFetchCarry ~= nil
end

--- Self-initiated throw trigger — a HUMAN HANDLER action (gated on
--- HasK9Access() alone, NOT CanShowK9UI()/IsOwnModelK9() — DEVELOPER_REFERENCE.md's own
--- "on a handler command" wording, DEVELOPER_REFERENCE.md §14.4.3's resolved
--- design: the thrower need not currently be riding a K9 model).
function RequestThrowFetchBall()
    if not HasK9Access() then
        DenyK9UIAccess()
        return
    end
    TriggerServerEvent('qbx_k9unit:server:requestThrowFetchBall')
end

RegisterCommand('k9throwfetchball', function()
    RequestThrowFetchBall()
end, false)

--- Server-issued instruction (never a request to validate — mirrors
--- client/kennel.lua's deployKennelAt exactly): create the ball object at
--- exactly (spawnX, spawnY, spawnZ) and apply the given one-shot throw
--- impulse.
RegisterNetEvent('qbx_k9unit:client:throwFetchBallAt', function(spawnX, spawnY, spawnZ, forceX, forceY, forceZ)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup, not re-derived here). 65535 is FiveM's documented
    -- client-side sentinel for "this event genuinely came from the
    -- server" (citizenfx/fivem-docs, "Secure your events"). Confidence:
    -- MEDIUM-HIGH, the official documented pattern, not independently
    -- verified in-engine.
    if source ~= 65535 then return end

    if type(spawnX) ~= 'number' or type(spawnY) ~= 'number' or type(spawnZ) ~= 'number'
        or type(forceX) ~= 'number' or type(forceY) ~= 'number' or type(forceZ) ~= 'number' then
        return
    end

    -- STALE-THROW GUARD (client/kennel.lua's own "STALE-KENNEL GUARD" on
    -- deployKennelAt / client/propattachment.lua's own "STALE-VEST GUARD" on
    -- attachK9Prop are the precedent this follows, not a second independent
    -- design -- read either one first). server/fetch.lua's own
    -- FetchBalls[citizenid]/PendingFetchThrows[citizenid] checks in its
    -- requestThrowFetchBall handler make a second throw succeeding for the
    -- same citizenid while a first one is still active hard to reach in the
    -- ordinary flow, but neither is a hard guarantee THIS handler can rely
    -- on never seeing two 'throwFetchBallAt' dispatches in a row before
    -- myThrownBallNetId is ever cleared (removeFetchBall / this file's own
    -- onResourceStop / the CONFIRM-FAILURE BACKSTOP thread below) -- a
    -- second dispatch would otherwise overwrite myThrownBallNetId below
    -- (via SetMyThrownBall) while the FIRST thrown ball's entity stays real
    -- and untracked: nothing left holds its netId, so nothing will ever
    -- delete it. No defense-in-depth model check needed on the stale
    -- entity here (unlike client/kennel.lua's removeKennel handler) --
    -- myThrownBallNetId is never set from an externally-supplied netId, only
    -- ever from this file's own prior CreateObject calls, so it is already
    -- inherently trusted.
    if myThrownBallNetId then
        local staleEntity = ResolveNetworkEntity(myThrownBallNetId)
        if staleEntity then
            DeleteEntity(staleEntity)
        end
        ClearMyThrownBall()
    end

    local modelHash = LoadModelWithTimeout(Config.FetchMechanic.ballPropModel)
    if not modelHash then
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.prop_load_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelFetchThrow')
        return
    end

    local obj = CreateObject(modelHash, spawnX, spawnY, spawnZ, true, true, false)
    SetModelAsNoLongerNeeded(modelHash)

    if not DoesEntityExist(obj) then
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.throw_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelFetchThrow')
        return
    end

    -- ApplyForceToEntity CONFIDENCE NOTE: MEDIUM — same grading, and the
    -- same forceType 3 (APPLY_TYPE_IMPULSE, a single instantaneous push),
    -- as client/movement.lua's own already-shipped door-nudge call, whose
    -- exact parameter shape this mirrors. Deliberately forceType 3, not the
    -- forceType 1 (continuous force) used by the one external community
    -- precedent this feature is otherwise modeled on
    -- (DEVELOPER_REFERENCE.md#phase-5-research) — a one-shot
    -- throw is semantically an impulse, and this codebase already has its
    -- own reasoned, shipped precedent for exactly that call shape, followed
    -- here instead of the external example.
    ApplyForceToEntity(obj, 3, forceX, forceY, forceZ, 0.0, 0.0, 0.0, 0, false, true, true, false, true)

    local netId = NetworkGetNetworkIdFromEntity(obj)
    SetMyThrownBall(netId)
    TriggerServerEvent('qbx_k9unit:server:confirmFetchBallThrown', netId)
end)

--- Server-issued instruction: this client just had its pickup request
--- accepted for netId, in `mode`. See this file's header for why 'attach'
--- mode deletes the old entity and creates a fresh, mouth-attached
--- replacement via the shared AttachPropToOwnPed rather than attaching the
--- existing handle.
--- @param netId number
--- @param mode string
RegisterNetEvent('qbx_k9unit:client:carryFetchBall', function(netId, mode)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see throwFetchBallAt's own comment above
    if type(netId) ~= 'number' or (mode ~= 'attach' and mode ~= 'fake') then return end

    -- STALE-CARRY GUARD (client/propattachment.lua's own "STALE-VEST GUARD"
    -- on attachK9Prop / client/kennel.lua's own "STALE-KENNEL GUARD" on
    -- deployKennelAt are the precedent this follows, not a second
    -- independent design -- read either one first). A second
    -- 'carryFetchBall' dispatch arriving before THIS client's own prior
    -- 'attach'-mode carry is ever cleared (endFetchCarry / removeFetchBall)
    -- would otherwise overwrite ActiveFetchCarry below while the OLD
    -- carry's mouth-attached entity stays attached to this ped, untracked
    -- -- nothing left holds its netId, so nothing (not endFetchCarry, not
    -- removeFetchBall, not this file's own onResourceStop) will ever
    -- detach or delete it. Only 'attach' mode has a real attached entity to
    -- leak this way ('fake' mode's ActiveFetchCarry.netId is always nil) --
    -- checked here, unconditionally, before branching on THIS dispatch's
    -- own `mode`, because that says nothing about what the PREVIOUS carry
    -- was.
    if ActiveFetchCarry and ActiveFetchCarry.mode == 'attach' and ActiveFetchCarry.netId then
        local staleEntity = ResolveNetworkEntity(ActiveFetchCarry.netId)
        if staleEntity then
            DetachAndDeleteProp(staleEntity)
        end
    end

    local oldEntity = ResolveNetworkEntity(netId)
    if oldEntity and not FetchBallModelHashes[GetEntityModel(oldEntity)] then
        -- DEFENSE-IN-DEPTH MODEL CHECK (client/kennel.lua's removeKennel
        -- precedent) — even though this is a server-issued instruction,
        -- never act on an entity that isn't genuinely the configured ball
        -- prop just because the server named a netId that happens to
        -- resolve to something else.
        return
    end

    local ped = PlayerPedId()

    if mode == 'fake' then
        if oldEntity then
            NetworkRequestControlOfEntity(oldEntity)
            DeleteEntity(oldEntity)
        end
        PlayFetchCarryStance(ped)
        ActiveFetchCarry = { netId = nil, mode = 'fake' }
        return
    end

    -- mode == 'attach'
    if oldEntity then
        NetworkRequestControlOfEntity(oldEntity)
        DeleteEntity(oldEntity)
    end

    local cfg = Config.FetchMechanic
    local boneIndex = cfg.mouthBoneIndex or 0
    local offsetX = cfg.mouthOffsetX or 0.0
    local offsetY = cfg.mouthOffsetY or 0.0
    local offsetZ = cfg.mouthOffsetZ or 0.0

    local newEntity = AttachPropToOwnPed(
        cfg.ballPropModel, boneIndex,
        offsetX, offsetY, offsetZ,
        0.0, 0.0, 0.0,
        true, -- isNetworked: every other client must see the carried ball
        nil
    )

    if not newEntity then
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.carry_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelFetchCarryAttach')
        return
    end

    local newNetId = NetworkGetNetworkIdFromEntity(newEntity)
    ActiveFetchCarry = { netId = newNetId, mode = 'attach' }
    TriggerServerEvent('qbx_k9unit:server:confirmFetchBallCarried', newNetId)
end)

--- Server-issued instruction: end THIS client's own current carry.
--- `terminal` distinguishes "the whole cycle is over" (recalled, delivered,
--- expired, despawned) from "just a drop" (still pickup-able afterward).
--- @param mode string
--- @param terminal boolean
RegisterNetEvent('qbx_k9unit:client:endFetchCarry', function(mode, terminal)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see throwFetchBallAt's own comment above
    if mode ~= 'attach' and mode ~= 'fake' then return end

    local ped = PlayerPedId()

    if mode == 'attach' then
        -- Non-terminal (a plain drop): detach only — the entity stays real
        -- and pickup-able, deletion is never appropriate here.
        --
        -- Terminal: normally a no-op too, because 'qbx_k9unit:client:
        -- removeFetchBall' (server/fetch.lua's EndFetchCycle, broadcast to
        -- -1 including this client) already deletes the entity and clears
        -- ActiveFetchCarry by matching netId BEFORE this event arrives, so
        -- the `ActiveFetchCarry and ActiveFetchCarry.netId` guard below is
        -- already false by the time this handler runs in that common case.
        --
        -- DEFENSE-IN-DEPTH, NOT REDUNDANT: server/fetch.lua's own
        -- confirmFetchBallCarried deliberately leaves `ball.netId` pointing
        -- at the OLD, pre-pickup entity for the whole 'attach' transition
        -- window (that file's own requestPickupFetchBall comment: "left
        -- pointing at the OLD, about-to-be-deleted entity ... and is NEVER
        -- nil'd out for this window"). If confirmFetchBallCarried's own
        -- validation then fails in that same window (entity not yet
        -- resolvable, or the GLOBAL NETID-UNIQUENESS INVARIANT collision
        -- check), EndFetchCycle broadcasts removeFetchBall using that STALE
        -- old netId — which this client already deleted itself back in
        -- 'qbx_k9unit:client:carryFetchBall' above — never the NEW netId
        -- ActiveFetchCarry actually holds. That broadcast's own delete
        -- degrades to a harmless no-op on the already-gone old entity, but
        -- the real, physical, currently-attached NEW entity this client
        -- just created is never addressed by it at all, and would otherwise
        -- only be detached here, never deleted — a permanently orphaned,
        -- untracked networked object left behind by a rejected confirm.
        -- Deleting THIS client's own last-known handle directly (not by
        -- re-resolving the broadcast's netId) closes that leak regardless
        -- of which netId the corresponding removeFetchBall broadcast
        -- carries, and is always safe: DetachAndDeleteProp is a DoesEntityExist-
        -- guarded no-op if the entity is already gone (the common case
        -- above).
        if ActiveFetchCarry and ActiveFetchCarry.netId then
            local entity = ResolveNetworkEntity(ActiveFetchCarry.netId)
            if entity then
                if terminal then
                    DetachAndDeleteProp(entity)
                else
                    DetachEntity(entity, true, false)
                end
            end
        end
    else -- 'fake'
        ClearPedTasksImmediately(ped)
        if not terminal then
            -- Regular drop: recreate a real, visible ball at the K9's
            -- current position and report its netId — this is what makes
            -- 'fake' mode a genuine delete-and-animate carry rather than a
            -- one-way disappearance.
            local modelHash = LoadModelWithTimeout(Config.FetchMechanic.ballPropModel)
            if modelHash then
                local coords = GetEntityCoords(ped)
                local obj = CreateObject(modelHash, coords.x, coords.y, coords.z, true, true, false)
                SetModelAsNoLongerNeeded(modelHash)
                if DoesEntityExist(obj) then
                    local netId = NetworkGetNetworkIdFromEntity(obj)
                    SetMyThrownBall(netId)
                    TriggerServerEvent('qbx_k9unit:server:confirmFetchBallDropped', netId)
                end
            end
        end
        -- terminal: nothing tangible to recreate — the world object was
        -- already deleted at pickup time and this cycle is now over.
    end

    ActiveFetchCarry = nil
end)

--- Cleanup backstop broadcast from server/fetch.lua — mirrors
--- client/kennel.lua's removeKennel handler exactly, including its
--- defense-in-depth model check.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:removeFetchBall', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see throwFetchBallAt's own comment above
    if type(netId) ~= 'number' then return end

    if myThrownBallNetId == netId then
        ClearMyThrownBall()
    end
    if ActiveFetchCarry and ActiveFetchCarry.netId == netId then
        ActiveFetchCarry = nil
    end

    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    if not FetchBallModelHashes[GetEntityModel(entity)] then return end

    DeleteEntity(entity)
end)

--- Always available while carrying — no access gate on the way out, same
--- posture as DetachLeash/ReleaseBiteHold/ReleaseDrag.
function ReleaseFetchBall()
    if not ActiveFetchCarry then return end
    TriggerServerEvent('qbx_k9unit:server:releaseFetchBall')
end

RegisterCommand('k9dropfetchball', function()
    ReleaseFetchBall()
end, false)

--- Thrower's own early-interrupt for their currently active fetch cycle
--- (any state) — deliberately NOT gated on HasK9Access()/CanShowK9UI(),
--- same "must still be able to call it off" reasoning as ReleaseFetchBall
--- above; server/fetch.lua's own ownership check (only the real thrower's
--- src may recall) is the actual authorization boundary.
function RequestRecallFetchBall()
    TriggerServerEvent('qbx_k9unit:server:requestRecallFetchBall')
end

RegisterCommand('k9recallfetchball', function()
    RequestRecallFetchBall()
end, false)

-- ======================================================================
-- '/k9fetch' -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #3, the merged entry point.
-- k9throwfetchball/k9dropfetchball/k9recallfetchball above stay registered
-- forever as HIDDEN ALIASES (unchanged bodies -- see
-- client/commandsuggestions.lua's HIDDEN_ALIAS_COMMANDS).
--
-- CONTEXTUAL DISPATCH (project-owner-directed redirect, mid-pass -- "do the
-- obviously-right thing" rather than requiring a subcommand word), THE
-- REFERENCE IMPLEMENTATION for this shape across the five families: a bare
-- '/k9fetch' reads THIS CLIENT'S OWN real local state (never guesses blind)
-- and picks the one action that state actually implies --
--   ActiveFetchCarry ~= nil   -> this client IS the K9 currently carrying
--                                the ball -> DROP (ReleaseFetchBall()).
--   myThrownBallNetId ~= nil  -> this client threw a ball that is still
--                                out there (thrown/carried/dropped, not yet
--                                ended) -> RECALL (RequestRecallFetchBall()).
--   neither                   -> nothing active for this client -> THROW
--                                (RequestThrowFetchBall()).
-- The logic itself is FetchContextual() above, shared with the radial's
-- one Fetch item and the tablet's Fetch button.
--
-- WHY THIS IS SAFE TO GUESS (never true for a destructive family):
-- throw/drop/recall are all reversible, low-stakes actions -- worst case of
-- a "wrong" guess is a no-op (ReleaseFetchBall() itself no-ops if
-- ActiveFetchCarry is nil; RequestRecallFetchBall() server-side no-ops with
-- no active cycle) or a redundant throw attempt the server independently
-- refuses. Contrast family #2 (dog record), where the equivalent guess
-- would touch another player's live appearance and stays explicit-only.
--
-- GATE NEVER WIDENED BY THE MERGE: every branch below calls the EXACT SAME
-- resource-global (RequestThrowFetchBall/ReleaseFetchBall/
-- RequestRecallFetchBall) the old standalone command of the same name
-- already called -- RequestThrowFetchBall() itself still re-runs
-- HasK9Access()/DenyK9UIAccess() every time it's invoked, from bare
-- '/k9fetch', from '/k9fetch throw', or from '/k9throwfetchball' alike.
-- This dispatcher performs no authorization check of its own to skip.
--
-- EXPLICIT OVERRIDE: '/k9fetch <throw|drop|recall>' forces that action
-- regardless of current state (identical body to the matching old
-- standalone command).
--
-- CONFIRMATION NAMES THE DECISION (project-owner's own requirement #3): a
-- short notify fires BEFORE the resolved action runs, so a player who gets
-- a result they didn't expect from the bare form can see what state this
-- client read and why -- the underlying Request*/Release* call still fires
-- its own success/failure notify on top, unchanged.
-- ======================================================================
--- ONE FETCH ACTION: drop the ball if your K9 is carrying it, call it back
--- if a ball you threw is still out, otherwise throw one. Shared by
--- /k9fetch (no argument), the radial's single Fetch item and the tablet's
--- Fetch button (the owner's rework pass) -- the radial used to be a
--- sub-menu with Throw/Drop and Recall as separate choices.
---
--- Recall keys off `myThrownBallNetId` -- the THROWER's own ball -- not the
--- carry state, so the handler who threw (usually not the carrier) still
--- gets Recall. Drop and Recall are never gated; Throw gates itself inside
--- RequestThrowFetchBall().
function FetchContextual()
    if ActiveFetchCarry then
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.contextual_dropping'), type = 'inform' })
        ReleaseFetchBall()
    elseif myThrownBallNetId then
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.contextual_recalling'), type = 'inform' })
        RequestRecallFetchBall()
    else
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.contextual_throwing'), type = 'inform' })
        RequestThrowFetchBall()
    end
end

local FETCH_EXPLICIT_ACTIONS = {
    throw = function() RequestThrowFetchBall() end,
    drop = function() ReleaseFetchBall() end,
    recall = function() RequestRecallFetchBall() end,
}

RegisterCommand('k9fetch', function(_source, args)
    local explicit = args[1] and FETCH_EXPLICIT_ACTIONS[args[1]]
    if explicit then
        explicit()
        return
    end

    if args[1] then
        -- An argument was given but it's not throw/drop/recall --
        -- docs/history/COMMAND_CONSOLIDATION_SPEC.md §4's no-argument/bad-subcommand
        -- discoverability convention, reused for "recognized command,
        -- unrecognized word" too.
        lib.notify({ title = locale('common.notify_title'), description = locale('fetch.usage_k9fetch'), type = 'error' })
        return
    end

    -- Bare '/k9fetch' -- contextual dispatch, see this block's own header.
    FetchContextual()
end, false)

-- "Pick Up Ball" / "Deliver to Handler" target options — ROUTED THROUGH
-- K9Compat.Get('target') (shared/compat/target.lua), never a direct
-- `exports.ox_target` call — canInteract/onSelect below are unchanged
-- (still authored against ox_target's own convention), so an operator
-- running a different supported target script gets both options
-- translated automatically instead of losing them outright.
--
-- LIFECYCLE FIX: pulled into a named function so it can be re-run any time
-- the resource actually backing the 'target' system (re)starts, not just
-- once at this file's own load time. Every supported target script keeps
-- its own addModel/addGlobalPlayer-equivalent registries in plain
-- file-local Lua tables inside its OWN client chunk, cleared only by that
-- resource's own `onClientResourceStop` handler when the CALLING resource
-- (this one) stops — a bare restart of that resource while this resource
-- keeps running reloads that chunk with empty tables and nothing else asks
-- anyone to re-register, silently and permanently losing both options for
-- the rest of this resource's uptime. See the `AddEventHandler` immediately
-- below for the two triggers this now dispatches on, mirroring
-- server/tracking.lua's RegisterScentInventoryHook fix for the identical
-- bug class against ox_inventory.
--
-- DUPLICATE-VS-REPLACE: every option below always has `name` set, and
-- every adapter's own registration primitive dedups/replaces by that same
-- name (or label, per shared/compat/target.lua's own per-adapter notes) —
-- i.e. re-running this against a registry that already holds an option
-- with the same name REPLACES it, it never duplicates. No extra
-- remove-before-add call is needed here; the exports themselves are
-- already idempotent.
local DELIVER_TARGET_DISTANCE_FACTOR = 0.5

local function RegisterFetchOxTargetOptions()
    -- "Pick Up Ball" target option -- targets the configured ball prop
    -- model directly by hash, mirroring client/kennel.lua's own AddModel
    -- pattern. Routed through K9Compat.Get('target')
    -- (shared/compat/target.lua), never a direct `exports.ox_target` call.
    K9Compat.Get('target').AddModel({
        GetHashKey(Config.FetchMechanic.ballPropModel),
    }, {
        {
            name = 'qbx_k9unit:pickupFetchBall',
            -- ROLE ICON (resource-wide settled scheme: fa-dog = K9-role/
            -- CanShowK9UI()-gated, fa-user-tie = a separate human acting
            -- on/for a K9, fa-handshake = partnership, fa-id-badge = high
            -- command/credentialing). This option is OBJECT-scope (AddModel
            -- on the ball prop) and only ever shown while the local
            -- player's own ped IS the K9 (CanShowK9UI() below), so it gets
            -- the same fa-dog every other K9-role ox_target option in this
            -- resource now uses -- not the old fa-baseball, which named the
            -- OBJECT rather than the ACTOR and was the only ox_target icon
            -- in this resource keyed off the target's model instead of who
            -- can act on it. "Deliver to Handler" immediately below is a
            -- PLAYERS-scope option, handled separately below.
            icon = 'fas fa-dog',
            label = locale('fetch.pickup_target_label'),
            distance = Config.FetchMechanic.pickupInteractDistanceMeters,
            canInteract = function(entity, distance, coords, name)
                -- NEVER SHOW AN OPTION THAT WILL JUST REFUSE: server/fetch.lua's
                -- requestPickupFetchBall rejects outright if the requester
                -- is already carrying (or about to carry) a fetch item
                -- (fetch.already_carrying) -- ActiveFetchCarry mirrors that
                -- exact condition client-side, so hide the option instead of
                -- letting the player fire a guaranteed-rejected request.
                -- Display-only, same as everywhere else in this resource:
                -- the server independently re-verifies this regardless.
                if ActiveFetchCarry then return false end
                return CanShowK9UI()
            end,
            onSelect = function(data)
                if not data or not data.entity or not DoesEntityExist(data.entity) then return end
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                TriggerServerEvent('qbx_k9unit:server:requestPickupFetchBall', netId)
            end,
        },
    })

    -- "Deliver to Handler" ox_target option on nearby player peds — the
    -- player-driven "return to handler" leg (server/fetch.lua's own header
    -- explains why this is a proximity interaction rather than scripted
    -- movement). DISPLAY optimization only: server/fetch.lua's
    -- requestDeliverFetchBall independently re-verifies ownership, the target's
    -- identity as the real thrower, and live proximity — this predicate doesn't
    -- need to be perfect (same posture client/partnership.lua's "Partner Up"
    -- canInteract predicate already documents in full). Routed through
    -- K9Compat.Get('target') (shared/compat/target.lua), never a direct
    -- `exports.ox_target` call.
    -- THIRD-EYE CLARITY PASS (owner-directed): icon changed from
    -- fas fa-hand-holding to fas fa-dog, this resource's own K9-role icon,
    -- since the ACTOR here is always the K9 carrying the ball
    -- (ActiveFetchCarry can only be set after this same client's own "Pick
    -- Up Ball" selection, itself gated on CanShowK9UI() above) -- never the
    -- human on the receiving end. Label reworded to plain English.
    -- canInteract/onSelect are UNCHANGED (a real test in
    -- tests/clientfetch_spec.lua pins this predicate's exact "no further
    -- gate beyond ActiveFetchCarry + not-self" shape).
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'qbx_k9unit:deliverFetchBall',
            icon = 'fas fa-dog',
            label = locale('fetch.deliver_target_label'),
            distance = DELIVER_TARGET_DISTANCE_FACTOR * Config.FetchMechanic.deliverProximityMeters,
            canInteract = function(entity, distance, coords, name)
                if not ActiveFetchCarry then return false end
                return NetworkGetPlayerIndexFromPed(entity) ~= PlayerId()
            end,
            onSelect = function(data)
                local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                if not targetServerId then return end
                TriggerServerEvent('qbx_k9unit:server:requestDeliverFetchBall', targetServerId)
            end,
        },
    })
end

-- Sole call site for RegisterFetchOxTargetOptions(): this resource's OWN
-- start (`onResourceStart` fires once for a resource's own boot, same idiom
-- this file's other `GetCurrentResourceName()` checks already use, just via
-- the start event instead of the stop event) OR a restart of whatever
-- resource actually backs the 'target' system — same two-branch shape as
-- server/tracking.lua's RegisterScentInventoryHook / server/inventory.lua's
-- RegisterK9InventoryItemFilterHook fixes for the identical class of gap
-- against ox_inventory. This file never names a third-party target
-- resource directly (see shared/compat/target.lua) -- K9Compat.Redetect()
-- is forced before checking K9Compat.Which('target') so this is correct
-- regardless of relative handler-registration order against
-- shared/compat/core.lua's own onResourceStart/onClientResourceStart
-- redetect hook for this SAME event.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterFetchOxTargetOptions()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterFetchOxTargetOptions()
    end
end)

-- OWN-DEATH AUTO-DETACH/DROP -- "if ... the K9 dies ... the cycle must end
-- cleanly." Lightweight poll, only running at all while this client is
-- actually carrying — mirrors client/propattachment.lua's own identical
-- IsEntityDead(PlayerPedId()) polling pattern for the same class of check,
-- itself modeled on client/vision.lua's/client/screenfx.lua's established
-- convention. Backs off to a coarse idle poll otherwise so this thread
-- costs nothing for the overwhelming majority of a session where
-- FetchMechanic isn't actively in use — never a tight per-frame loop.
CreateThread(function()
    while true do
        if ActiveFetchCarry then
            Wait(1000)
            if DoesEntityExist(PlayerPedId()) and IsEntityDead(PlayerPedId()) then
                -- Best-effort local cleanup immediately, in case the round
                -- trip to the server (and its own endFetchCarry response) is
                -- delayed — mirrors client/combat.lua's own DEFENSE-IN-DEPTH
                -- local-backstop reasoning for the identical class of
                -- "don't wait on the network for a known-terminal local
                -- condition" case.
                if ActiveFetchCarry.mode == 'attach' and ActiveFetchCarry.netId then
                    local entity = ResolveNetworkEntity(ActiveFetchCarry.netId)
                    if entity then
                        DetachEntity(entity, true, false)
                    end
                end
                ActiveFetchCarry = nil
                TriggerServerEvent('qbx_k9unit:server:reportFetchCarrierDown')
            end
        else
            Wait(2000) -- feature idle for this client — coarse poll only to notice re-engagement, never per-frame
        end
    end
end)

-- CONFIRM-FAILURE BACKSTOP: a rejected throw/drop confirm must never leave
-- its object behind forever. server/fetch.lua's confirmFetchBallThrown and
-- confirmFetchBallDropped handlers both have failure branches
-- (pending-TTL expiry, a stale HasK9Access re-check, an
-- unresolvable/wrong-model entity, or the GLOBAL NETID-UNIQUENESS INVARIANT
-- collision guard) that silently `return` on rejection — unlike
-- confirmFetchBallCarried's own sibling failure paths (which at least call
-- EndFetchCycle) or confirmPropAttached's dedicated rejectK9PropAttach
-- event (client/propattachment.lua), NEITHER of those two handlers ever
-- sends this client anything back on failure. This client's own
-- CreateObject already ran and myThrownBallNetId already points at a real,
-- physical, networked object before either confirm is even sent, so a
-- silent rejection otherwise leaves it behind with literally nothing left
-- to ever clean it up.
--
-- This thread is a bounded last resort, not a substitute for that missing
-- signal -- it never risks deleting a legitimately-confirmed, still-in-play
-- ball: in the SUCCESS case this same netId is always eventually cleared
-- well before this fires, via pickup (carryFetchBall), recall/delivery
-- (removeFetchBall), or the server's own maintenance sweep despawning it at
-- maxBallLifetimeMs — the exact ceiling (plus a jitter margin) this thread
-- itself waits for before ever acting. A single flat 5s poll either way
-- (mirrors client/propattachment.lua's own vest-death-poll thread, whose
-- identical "no branch needed, the idle case is already this cheap"
-- reasoning applies here just as well) — checking two locals costs
-- nothing, and the actual native calls below only ever run in the rare
-- deadline-reached branch.
CreateThread(function()
    while true do
        Wait(5000)
        if myThrownBallNetId and myThrownBallDeadlineAt and GetGameTimer() >= myThrownBallDeadlineAt then
            local entity = ResolveNetworkEntity(myThrownBallNetId)
            if entity then
                DeleteEntity(entity)
            end
            ClearMyThrownBall()
        end
    end
end)

-- Resource-restart safety net (same class of fix as client/kennel.lua's own
-- onResourceStop handler): if this client is mid-carry, or created a
-- 'fake'-mode drop replacement, when the resource stops while still
-- connected, clean it up locally rather than leaving it behind. Covers the
-- common "still connected at resource restart" case; server/fetch.lua's own
-- onResourceStop loop covers a ball whose thrower/carrier already
-- disconnected earlier in the session.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if ActiveFetchCarry then
        if ActiveFetchCarry.mode == 'attach' and ActiveFetchCarry.netId then
            local entity = ResolveNetworkEntity(ActiveFetchCarry.netId)
            if entity then
                DetachAndDeleteProp(entity)
            end
        end
        ActiveFetchCarry = nil
    end

    if myThrownBallNetId then
        local entity = ResolveNetworkEntity(myThrownBallNetId)
        if entity then
            DeleteEntity(entity)
        end
        ClearMyThrownBall()
    end
end)
