--[[
    john-k9/client/appearance.lua

    Client half of the K9 role/ped-model decoupling — see
    server/appearance.lua's header for the full design (role vs. model,
    what triggers a swap, the streaming-failure contract). This file owns
    exactly two things:
      1. IsK9Role() — the cached, network-backed "do I hold the K9 role"
         check, the same shape as client/main.lua's own HasK9Access() (same
         TTL, same fail-closed-on-throw posture), consulted by
         CanShowK9UI() (client/main.lua) when
         Config.K9Appearance.requireK9ModelForRole is false.
      2. The actual model swap: the 'john-k9:client:applyK9Ped' handler,
         which is the ONLY place in this resource that ever calls
         SetPlayerModel.

    ======================================================================
    PER-PED STATE ACROSS A MODEL SWAP — THE DECISION: REFUSE, don't
    force-clear. FiveM's SetPlayerModel keeps the SAME ped index across the
    swap (already confirmed and relied on elsewhere in this resource — see
    client/movement.lua's RecomputeK9MoveRate doc comment), which is
    exactly the "death reuses the same ped handle" hazard this resource has
    already been bitten by once (a K9 that died in a vehicle respawned
    frozen/invisible/attached — a past regression; see
    client/vehicle.lua's own header for the full account). A model swap is the
    SAME class of hazard: any resource-tracked per-ped state that assumes
    "this ped is a K9" (leashed, mid drag as either party, mid bite-hold,
    mid fetch-carry, inside a K9 vehicle) would silently carry over onto
    whatever the ped becomes next.

    This file does NOT own client/combat.lua, client/movement.lua,
    client/fetch.lua or client/vehicle.lua, so it cannot reach into their
    private state to force-clear it correctly (and guessing at a
    force-clear sequence for state this file doesn't own is exactly how
    the vehicle/frozen bug above happened in the first place). Every one of
    those files already exposes a cheap, resource-global "am I currently
    doing this" check for exactly this kind of cross-file consultation —
    reused here, read-only, never called to mutate anything:
        IsLeashed()               client/movement.lua
        IsBiteHoldEngaged()       client/combat.lua
        IsDragEngaged()           client/combat.lua
        IsFetchCarryEngaged()     client/fetch.lua
        IsInK9Vehicle()           client/vehicle.lua
        IsPropAttachmentEngaged() client/propattachment.lua
    If ANY of these is true, the swap is refused outright (before
    RequestModel is even called) and reported back to the server as
    'engaged' — never half-applied, never a guess at cleanup this file has
    no authority over. Each is guarded with the established
    `type(fn) == 'function'` soft-dependency check, since this file has no
    hard load-order requirement on any of theirs.

    client/propattachment.lua exposes IsPropAttachmentEngaged() (same
    shape/convention as the five predicates above), so a K9 mid-
    PropAttachment is covered below exactly like every other engagement
    kind.

    ======================================================================
    STREAMING — RequestModel/HasModelLoaded polling, timed out by
    Config.K9Appearance.modelLoadTimeoutMs, is the SAME pattern
    client/kennel.lua's LoadModelWithTimeout already established (down to
    the leak fix: SetModelAsNoLongerNeeded on EVERY exit path, including
    the timeout one, since RequestModel's streaming reference must always
    be released even when the model that was requested is never actually
    used). On timeout: SetModelAsNoLongerNeeded, report 'timeout' back to
    the server, and do nothing else — SetPlayerModel is never called, so
    the player is exactly as they were before this request arrived.

    ======================================================================
    STATEBAG VS CACHED CALLBACK — THE DECISION: ten ox_target canInteract
    predicates across client/movement.lua, client/medkit.lua,
    client/wellbeing.lua and client/partnership.lua need "does THAT OTHER
    player currently hold the K9 role", not just IsK9Role()'s own "do I". A
    replicated statebag (Player(source).state:set('isK9', bool, true) set
    server-side at every role-transition point — grant, revoke, ped-swap
    apply/revert/timeout, disconnect — read client-side via
    Entity(ped).state.isK9) was considered as the no-round-trip
    alternative.

    DECISION: cached callback (IsK9RoleForPlayer below), NOT a statebag.
    This resource has zero statebags today; introducing the pattern for
    exactly one predicate-convenience question is not worth the blast
    radius it would open — every one of the four bullet points above
    becomes a NEW place a role-transition can be missed (an unset on
    disconnect that never fires leaves a stale `true` broadcast to every
    client forever, until that slot is reused and overwritten — worse than
    a cached callback's own worst case, which self-heals within one TTL
    window with no additional code path required). A statebag write is also
    only reachable from server/appearance.lua (the one file that already
    owns every role-transition point HasK9Role's own cache backs onto), so
    the "four separate call sites, each must remember" risk is real, not
    theoretical — server/appearance.lua's own header above already
    documents ForceDetachLeashForSource-class cross-file coordination gaps
    as the recurring hazard class in this resource.

    The cached callback pays for this with an up-to-1000ms staleness window
    and a real (rate-bounded) round trip per newly-hovered target — both
    already true of every OTHER predicate in this resource that answers "is
    THAT OTHER player currently X" (see client/main.lua's own HasK9Access()
    TTL reasoning, identical shape), and per this file's own "A PREDICATE IS
    A CONVENIENCE GATE" rule below: canInteract only decides whether an
    ox_target OPTION is offered, never whether the resulting action
    succeeds — every one of those ten predicates' own onSelect handlers
    still triggers a server event/callback that independently re-derives
    "does this target hold the K9 role" via HasK9Role/HasK9Access, exactly
    as if the predicate had answered `true` for the wrong reason or a
    forged/stale value. A staleness window here can make a menu OPTION
    appear or vanish a beat late; it can never make the action itself
    succeed against a target who does not actually hold the role. If a
    future pass finds this round-trip volume actually costly in practice
    (not hypothetically), the statebag above remains the documented
    alternative — this decision is about NOT paying that cost today for a
    convenience-only surface, not a claim the pattern is wrong for this
    resource forever.

    ======================================================================
    EVENT CONTRACT — see server/appearance.lua's header for the full
    picture; this file registers the client end and triggers the confirm:
      'john-k9:client:applyK9Ped' (requestId: string, modelNameOrHash: string|number) [THIS FILE, server->client]
      'john-k9:server:confirmK9PedSwap' (requestId: string, ok: boolean, reason: string?) [THIS FILE, client->server]
      'john-k9:server:hasK9Role' (lib.callback) () -> boolean [server/appearance.lua]
      'john-k9:server:isK9RoleForTarget' (lib.callback) (targetServerId: number) -> boolean [server/appearance.lua] -- backs IsK9RoleForPlayer below
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
-- Same cache shape/TTL as client/main.lua's HasK9Access() — see that
-- function's own doc comment for the full "why 1000ms, why a debounce not
-- a permanent cache" reasoning, which applies identically here (this is
-- consulted from the exact same CanShowK9UI() combinator, so it needs the
-- same hot-call-site headroom).
local HAS_K9_ROLE_CACHE_TTL_MS = 1000
local hasK9RoleCache = { value = false, checkedAt = -HAS_K9_ROLE_CACHE_TTL_MS }

--- Awaits the server's authoritative "do I hold the K9 role" check (see
--- server/appearance.lua's HasK9Role — active certification for my current
--- job, OR an active 'k9.access' permission grant; model-independent by
--- construction). Same FAIL-CLOSED-ON-THROW guard as HasK9Access(): a
--- rejected `lib.callback.await` (timeout / not-yet-registered) throws
--- rather than returning nil (client/main.lua's HasK9Access doc comment
--- has the full citation against real ox_lib/FiveM source, not repeated
--- here), so this is pcall'd and denies for just this one call on a
--- throw, WITHOUT poisoning the cache with a false negative — identical
--- reasoning to HasK9Access's own comment on why `checkedAt` is left
--- untouched on that path.
--- @return boolean
function IsK9Role()
    local now = GetGameTimer()
    if (now - hasK9RoleCache.checkedAt) < HAS_K9_ROLE_CACHE_TTL_MS then
        return hasK9RoleCache.value
    end

    local ok, result = pcall(lib.callback.await, 'john-k9:server:hasK9Role', K9_CALLBACK_TIMEOUT_MS)
    if not ok then
        return false
    end

    hasK9RoleCache.value = result == true
    hasK9RoleCache.checkedAt = now
    return hasK9RoleCache.value
end

-- Per-target cache, same TTL/shape as hasK9RoleCache above but keyed by
-- targetServerId -- ten ox_target canInteract predicates need "is THAT
-- OTHER player a K9-role holder", not just the local player (see
-- server/appearance.lua's isK9RoleForTarget callback doc comment for the
-- full list/reasoning). One cache per target rather than one shared value,
-- since a canInteract predicate can be evaluated against several different
-- nearby players in quick succession while the mouse moves.
local HAS_K9_ROLE_FOR_TARGET_CACHE_TTL_MS = 1000
local k9RoleForTargetCache = {} -- [targetServerId] = { value, checkedAt }

--- Awaits the server's authoritative "does THAT player hold the K9 role"
--- check. CONVENIENCE ONLY, same posture as every other ox_target
--- canInteract predicate in this resource -- callers must not treat a
--- `true` here as authorization for anything; the real action still goes
--- through a server-side HasK9Role/HasK9Access re-check regardless. Same
--- fail-closed-on-throw-without-poisoning-the-cache guard as IsK9Role()/
--- HasK9Access() above.
--- @param targetServerId number
--- @return boolean
function IsK9RoleForPlayer(targetServerId)
    if type(targetServerId) ~= 'number' then return false end

    local now = GetGameTimer()
    local cached = k9RoleForTargetCache[targetServerId]
    if cached and (now - cached.checkedAt) < HAS_K9_ROLE_FOR_TARGET_CACHE_TTL_MS then
        return cached.value
    end

    local ok, result = pcall(lib.callback.await, 'john-k9:server:isK9RoleForTarget', K9_CALLBACK_TIMEOUT_MS, targetServerId)
    if not ok then
        return false
    end

    k9RoleForTargetCache[targetServerId] = { value = result == true, checkedAt = now }
    return result == true
end

--- @return boolean
local function IsCurrentlyEngaged()
    if type(IsLeashed) == 'function' and IsLeashed() then return true end
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then return true end
    if type(IsDragEngaged) == 'function' and IsDragEngaged() then return true end
    if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then return true end
    if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then return true end
    if type(IsPropAttachmentEngaged) == 'function' and IsPropAttachmentEngaged() then return true end
    -- ======================================================================
    -- TARGET-SIDE ADDITIONS (this pass) -- every check above is HOLDER-side
    -- (or, for IsInK9Vehicle/IsPropAttachmentEngaged, a self-administered
    -- state): none of them ask whether THIS ped is the TARGET of something
    -- another client's own per-tick native calls are currently driving.
    -- server/combat.lua's ActiveHolds is keyed by the TARGET's own netId
    -- (grep-confirmed in that file) -- a model swap here does not merely
    -- risk a stale bookkeeping entry, it changes the very ped that hold's
    -- own client-side enforcement (DisableControlAction / the move-rate
    -- override / a live AttachEntityToEntity relationship) is running
    -- against, mid-flight, out from under a hold the server (and, for a
    -- drag, another player's client) still believes is running against a
    -- consistent, unchanging body. REFUSE, not force-clear, same doctrine as
    -- every check above -- this file has no more authority to reach into
    -- client/combat.lua's target-side state than into its holder-side state.
    --
    -- IsDragTargetEngaged() (client/combat.lua) already exists as a
    -- resource-global answering exactly this for PropDragging -- added to
    -- .luacheckrc's globals when it shipped, consumed here for the first
    -- time this pass.
    if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then return true end
    -- IsLocalPlayerForceRagdolled() (client/combat.lua) answers the
    -- identical question for NonLethalTakedown's own target-side state
    -- (ActiveForcedRagdoll -- the ragdoll/damage-immunity bracket) -- already
    -- a resource-global (added for client/tablet.lua's own force-close
    -- watch thread), consumed here for the first time this pass. Same class
    -- of hazard as the drag case above: a swap mid-ragdoll would leave that
    -- damage-immunity bracket running against a ped the server's own hold no
    -- longer coherently describes.
    if type(IsLocalPlayerForceRagdolled) == 'function' and IsLocalPlayerForceRagdolled() then return true end
    -- IsBiteHoldTargetEngaged() -- LANDED (verified by reading
    -- client/combat.lua directly: a real, complete function, `return
    -- ActiveBiteHold ~= nil`, with its own doc comment explaining exactly
    -- this target-side gap). This paragraph used to say the function DID
    -- NOT EXIST YET -- that BiteAndHold's target-side state (ActiveBiteHold,
    -- client/combat.lua) was a bare file `local` with no exposed predicate,
    -- unlike ActiveDragSpeedLimit/ActiveForcedRagdoll above -- and that this
    -- call site was wired in ahead of the function existing, the same way
    -- server/tablet.lua's own call to the not-yet-defined
    -- ForceRevertK9Appearance was wired in ahead of server/appearance.lua
    -- defining it. client/combat.lua's owner has since added the function,
    -- so the `type(...) == 'function'` guard below now genuinely fires
    -- rather than skipping -- no further patch was needed here, exactly as
    -- designed.
    if type(IsBiteHoldTargetEngaged) == 'function' and IsBiteHoldTargetEngaged() then return true end
    -- IsRestingInKennel() (client/kennel.lua) -- a dog attached inside a
    -- kennel object (AttachEntityToEntity, client/kennel.lua's
    -- enterKennelConfirmed handler) is exactly the same "another mechanic's
    -- native state currently depends on this ped's present form" hazard
    -- IsInK9Vehicle()/IsPropAttachmentEngaged() above already gate --
    -- IsCurrentlyEngaged() simply never asked it. Already a resource-global,
    -- already allowlisted (see .luacheckrc's own comment: "exposed for a
    -- future client/appearance.lua model-swap guard, not yet wired there")
    -- -- wired in for the first time this pass.
    if type(IsRestingInKennel) == 'function' and IsRestingInKennel() then return true end
    -- ======================================================================
    return false
end

--- @return number
local function ModelLoadTimeoutMs()
    local timeout = Config.K9Appearance and Config.K9Appearance.modelLoadTimeoutMs
    if type(timeout) ~= 'number' or timeout <= 0 then return 10000 end
    return timeout
end

--- Same RequestModel/HasModelLoaded polling pattern, INCLUDING the leak
--- fix, as client/kennel.lua's LoadModelWithTimeout — see that function's
--- own doc comment for the full "why this exact shape" writeup, not
--- repeated here. The one difference: this takes an already-resolved HASH
--- (a caller-supplied model name is hashed by the caller below, and a
--- revert's original-model hash never had a name to begin with — see
--- server/appearance.lua's own comment on why original_model_hash is
--- stored as a hash, not a name).
--- @param modelHash number
--- @return boolean ok
local function LoadModelWithTimeout(modelHash)
    if not IsModelValid(modelHash) then
        return false -- not even a recognized model hash on this client's installed game data
    end

    RequestModel(modelHash)
    local waited = 0
    local timeoutMs = ModelLoadTimeoutMs()
    while not HasModelLoaded(modelHash) and waited < timeoutMs do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        -- LEAK FIX, same as client/kennel.lua's identical comment: RequestModel
        -- above incremented this model's streaming reference count; release it
        -- on this failure path too, or it is held forever.
        SetModelAsNoLongerNeeded(modelHash)
        return false
    end
    return true
end

--- @param requestId string
--- @param ok boolean
--- @param reason string?
local function ConfirmSwap(requestId, ok, reason)
    TriggerServerEvent('john-k9:server:confirmK9PedSwap', requestId, ok, reason)
end

--- @param modelNameOrHash string|number
--- @return number
local function ResolveModelHash(modelNameOrHash)
    if type(modelNameOrHash) == 'string' then
        return GetHashKey(modelNameOrHash)
    end
    return modelNameOrHash
end

--- The ONLY call site for SetPlayerModel in this resource. See this file's
--- header for the full "refuse, don't force-clear" and streaming-timeout
--- contracts.
--- @param requestId string
--- @param modelNameOrHash string|number
RegisterNetEvent('john-k9:client:applyK9Ped', function(requestId, modelNameOrHash)
    -- SOURCE-ORIGIN GUARD, same pattern/confidence as every other
    -- server->client event in this resource (see client/main.lua's
    -- playBark handler for the fullest citation of this pattern).
    if source ~= 65535 then return end

    if type(requestId) ~= 'string' or requestId == '' then return end
    if type(modelNameOrHash) ~= 'string' and type(modelNameOrHash) ~= 'number' then return end

    if IsCurrentlyEngaged() then
        ConfirmSwap(requestId, false, 'engaged')
        return
    end

    local modelHash = ResolveModelHash(modelNameOrHash)
    if not LoadModelWithTimeout(modelHash) then
        ConfirmSwap(requestId, false, 'timeout')
        return
    end

    -- RE-CHECK ENGAGEMENT: LoadModelWithTimeout above can YIELD one or more
    -- times (its own Wait(50) polling loop) while this model streams in --
    -- up to ModelLoadTimeoutMs() (10s by default). The IsCurrentlyEngaged()
    -- check above only proves this ped was NOT
    -- leashed/mid-drag/mid-bite-hold/mid-fetch-carry/in-a-K9-vehicle/
    -- mid-PropAttachment at the INSTANT this handler started -- it says
    -- nothing about whatever happened during however long the wait above
    -- actually took. Any of those six mechanics can be started by an
    -- independent action (another player leashing this one, a drag/bite
    -- landing, etc.) entirely outside this handler's control while it was
    -- suspended here. Applying SetPlayerModel now would carry exactly the
    -- "per-ped state assumes this ped is a K9" hazard this file's own header
    -- ("PER-PED STATE ACROSS A MODEL SWAP") already refuses to force-clear
    -- for -- there is no reason that hazard applies only at the moment this
    -- handler was DISPATCHED and not at the moment it is about to actually
    -- act. SetModelAsNoLongerNeeded releases the streaming reference this
    -- successful LoadModelWithTimeout call just took -- the model loaded
    -- fine, it simply is not going to be used now.
    if IsCurrentlyEngaged() then
        SetModelAsNoLongerNeeded(modelHash)
        ConfirmSwap(requestId, false, 'engaged')
        return
    end

    SetPlayerModel(PlayerId(), modelHash)

    -- THE PED IS INVISIBLE WITHOUT THIS. Reported from a live server: a
    -- player certified with /k9certify turned into "air" -- the swap
    -- happened, the dog model was correct, and nothing rendered at all.
    --
    -- SET_PLAYER_MODEL builds the new ped with NO component variation set.
    -- A human ped mostly survives that (it falls back to a default outfit);
    -- an animal ped does not -- every part of the dog IS a component, so a
    -- ped with none set has nothing to draw. The player is standing right
    -- there, collides, can be targeted, and is completely invisible to
    -- everybody including themselves.
    --
    -- SET_PED_DEFAULT_COMPONENT_VARIATION applies each component's default,
    -- which for a_c_shepherd / a_c_rottweiler / a_c_husky is simply "the
    -- dog". Verified rather than assumed, the same way this resource
    -- verifies every native it calls: its CFX decl page 404s (a legacy R*
    -- native with no page written, which is never grounds to reject one),
    -- so it was checked against the natives.json hash database instead --
    -- namespace PED, hash 0x45EEE61580806D63, no `apiset` key, which in
    -- that database means the default, client-only. This file is a client
    -- file, so the realm is right. That check matters here more than most:
    -- an unregistered native does not throw on FiveM, it returns nothing
    -- forever with nothing logged, and this fix would have looked like it
    -- worked while changing nothing at all.
    --
    -- PlayerPedId() is re-read rather than captured from before the swap.
    -- FiveM keeps the same ped INDEX across SetPlayerModel (this file's own
    -- header says so, and this resource relies on it elsewhere), so this is
    -- belt and braces rather than a known bug -- but reading it fresh costs
    -- nothing and does not depend on that guarantee holding.
    local swappedPed = PlayerPedId()
    if swappedPed ~= 0 then
        SetPedDefaultComponentVariation(swappedPed)
    end

    -- AND ONCE MORE ON THE NEXT FRAME. On some builds the ped is not fully
    -- constructed until the frame after SET_PLAYER_MODEL returns, and a
    -- variation applied to a half-built ped is silently dropped -- the same
    -- invisible result, intermittently, which is far harder to diagnose
    -- than a consistent one. Re-applying a frame later costs a single
    -- native call and makes the outcome the same on every build.
    --
    -- GUARDED, so this can never fire against something it should not: it
    -- re-reads the ped and its model, and does nothing unless the ped is
    -- still wearing the exact model this handler just applied. If anything
    -- swapped the player again inside that one frame -- another resource, a
    -- revoke racing a certify, a death and respawn -- this is a no-op
    -- rather than a stomp on whatever they legitimately became.
    CreateThread(function()
        Wait(0)
        local ped = PlayerPedId()
        if ped ~= 0 and GetEntityModel(ped) == modelHash then
            SetPedDefaultComponentVariation(ped)
        end
    end)

    SetModelAsNoLongerNeeded(modelHash)

    -- Local role-check cache may now be answering for the model we just
    -- left — force the next CanShowK9UI()/IsK9Role() consultation to
    -- re-await rather than serve a value cached from before this swap.
    -- (IsOwnModelK9() itself has no cache to invalidate — it always reads
    -- the ped's current model live.)
    hasK9RoleCache.checkedAt = -HAS_K9_ROLE_CACHE_TTL_MS

    ConfirmSwap(requestId, true, nil)
end)

-- ======================================================================
-- K9 IDENTITY (THIS PASS) -- see server/appearance.lua's own "K9 IDENTITY"
-- section header for the full design/reasoning; this is the client half:
-- a new "Identify K9" ox_target(-equivalent) option, ROUTED THROUGH
-- K9Compat.Get('target') (shared/compat/target.lua) exactly like every
-- other target option in this resource, never a direct `exports.ox_target`
-- call -- so it keeps working under qb-target/qtarget/sleepless_interact,
-- not just ox_target.
--
-- WHY A SEPARATE OPTION, NOT THE LABEL ITSELF: see server/appearance.lua's
-- own header, "WHY NOT PUT THE NAME IN THE ox_target OPTION'S OWN `label`
-- FIELD" -- every backend this resource supports fixes an option's label
-- at registration time, the same for every player and every look; there is
-- no per-hover "who am I looking at" text slot to fill in dynamically
-- across all of them. The label below names the ACTION
-- (locale('appearance.identity_target_label'), "Identify K9"); selecting
-- it reveals the resolved identity via one lib.notify call -- READ ON
-- TARGET, NEVER PER FRAME, exactly this task's own cheapness rule.
--
-- SAME canInteract GATE AS "Pet K9"/"Feed K9" (client/wellbeing.lua):
-- `IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))`
-- -- a CONVENIENCE gate only (this file's own IsK9RoleForPlayer doc
-- comment), never itself a security boundary: the server's own
-- k9Identity callback independently re-verifies HasK9Role, distance and
-- Config.K9Identity.enabled regardless of what this predicate answered.
-- Config.K9Identity.enabled is also checked HERE so the option never even
-- shows when an operator has switched the feature off -- a static,
-- boot-time config read, same posture as every other Config.K9Appearance.*
-- field this file already reads directly (not part of the live
-- Config.Features admin-override system, by design -- this is cosmetic,
-- not a security-relevant feature toggle).
--
-- LIFECYCLE FIX pattern copied from client/wellbeing.lua's own
-- RegisterMoodOxTargetOptions/AddEventHandler('onResourceStart', ...) pair
-- (see that file's own comment for the full "why this needs to survive a
-- bare restart of whatever resource actually backs 'target'" reasoning) --
-- not re-derived here, applied identically.
-- ======================================================================
do
    --- @param result table? -- { ok = true, name: string, callsign: string?, handlerName: string? } | { ok = false, reason: string } | nil (pcall failure)
    local function NotifyIdentity(result)
        if not (result and result.ok == true and type(result.name) == 'string' and result.name ~= '') then
            -- Silent no-op on any failure (disabled/too_far/not_k9/
            -- invalid_target, or a thrown/rejected lib.callback.await) --
            -- the target walking out of range or losing the role between
            -- canInteract's own guess and this real server round trip is
            -- not worth a bystander-facing error message, same posture as
            -- every other onSelect handler in this resource that treats a
            -- falsy/failed result as a quiet no-op (see
            -- client/wellbeing.lua's own NotifyResult).
            return
        end

        local lines = { locale('appearance.identity_line_name'):format(result.name) }
        if type(result.callsign) == 'string' and result.callsign ~= '' then
            lines[#lines + 1] = locale('appearance.identity_line_callsign'):format(result.callsign)
        end
        if type(result.handlerName) == 'string' and result.handlerName ~= '' then
            lines[#lines + 1] = locale('appearance.identity_line_handler'):format(result.handlerName)
        end

        lib.notify({
            title = locale('appearance.identity_notify_title'),
            description = table.concat(lines, '\n'),
            type = 'inform',
        })
    end

    local function RegisterIdentityOxTargetOptions()
        K9Compat.Get('target').AddGlobalPlayer({
            {
                name = 'john-k9:k9Identity',
                icon = 'fas fa-id-badge',
                label = locale('appearance.identity_target_label'),
                distance = 3.0,
                canInteract = function(entity)
                    if not (Config.K9Identity and Config.K9Identity.enabled == true) then return false end
                    return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
                end,
                onSelect = function(data)
                    local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                    if not targetServerId then return end

                    -- FAIL-CLOSED GUARD -- same reasoning as every other
                    -- onSelect handler in this resource that awaits a
                    -- lib.callback (see client/wellbeing.lua's "Pet K9"
                    -- onSelect for the full ox_lib/FiveM source citation):
                    -- lib.callback.await throws rather than returning nil
                    -- on a timeout/unregistered-callback rejection.
                    -- NotifyIdentity's own guard already treats a nil
                    -- `result` as a silent no-op.
                    local ok, result = pcall(lib.callback.await, 'john-k9:server:k9Identity', K9_CALLBACK_TIMEOUT_MS, targetServerId)
                    if not ok then result = nil end
                    NotifyIdentity(result)
                end,
            },
        })
    end

    -- Sole call site for RegisterIdentityOxTargetOptions() above: this
    -- resource's own start, or whichever resource backs 'target'
    -- restarting -- see this section's own header for the full citation.
    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName == GetCurrentResourceName() then
            RegisterIdentityOxTargetOptions()
            return
        end

        K9Compat.Redetect()
        if resourceName == K9Compat.Which('target') then
            RegisterIdentityOxTargetOptions()
        end
    end)
end
