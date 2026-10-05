--[[
    john-k9/client/propattachment.lua

    Client half of Config.Features.PropAttachments — see
    server/propattachment.lua's header for the full event contract, the
    "why this never accepts a client-claimed target ped" trust-boundary
    reasoning, and the bone-index research-blocker/reframe note. Read that
    file before changing anything here.

    ======================================================================
    FILE-TO-FILE CONTRACT — SHARED SURFACE WITH THE FetchMechanic FEATURE:
    the plain attach/detach mechanics below are generic over "attach some
    prop to my own ped at some bone index," not specific to a vest, so both
    PropAttachments and FetchMechanic can reuse them:
        AttachPropToOwnPed(modelName: string, boneIndex: number,
            offsetX: number, offsetY: number, offsetZ: number,
            rotX: number, rotY: number, rotZ: number,
            isNetworked: boolean, timeoutMs: number?) -> entity: number?
      Loads `modelName` (falls back to nothing — caller decides its own
      fallback model, same "one model per call" contract client/kennel.lua's
      LoadModelWithTimeout already established), creates an object at the
      caller's own current PlayerPedId() position, attaches it via
      AttachEntityToEntity at `boneIndex` with the given offset/rotation, and
      returns the resulting entity handle — or nil on ANY failure (bad model
      name, model never loads in time, CreateObject fails) — NEVER errors.
      `isNetworked` controls CreateObject's own isNetwork argument: pass
      `true` for anything meant to be visible to OTHER clients (this file's
      own vest use), `false` for a purely local visual aid with no other
      consumer (client/bonetool.lua's marker prop). The caller is entirely
      responsible for whatever server-side confirm/registration step its own
      feature needs on top of this — this function only ever creates a LOCAL
      handle, it never talks to the network layer beyond CreateObject's own
      isNetworked flag.
        DetachAndDeleteProp(entity: number?) -> nil
      Safe teardown: DetachEntity then DeleteEntity, guarded by
      DoesEntityExist so calling this with an already-gone or nil entity is
      always a harmless no-op. Every removal path in this file (manual
      toggle-off receipt, own-death auto-detach, onResourceStop) funnels
      through this one function so there is exactly one place that ever
      calls DetachEntity/DeleteEntity for a prop this file created.
    Neither function is gated on Config.Features.PropAttachments — they are
    generic mechanics, not the feature itself; the FEATURE gate lives at
    each of THIS FILE's own call sites below (RequestToggleK9PropAttachment,
    the attachK9Prop/removeK9PropAttachment event handlers), exactly like
    the "gate at the point of activation, not the primitive" split
    server/entities.lua's ResolveNetworkEntity already established for the
    server side.
    ======================================================================

    - THIS FILE calls client/main.lua's CanShowK9UI()/DenyK9UIAccess(), same
      as every other gated client action in this resource -- CanShowK9UI()
      alone is the actual gate used below (this file never calls
      IsOwnModelK9()).
]]

-- Milliseconds to wait for RequestModel to actually finish loading before
-- giving up — same value/reasoning as client/kennel.lua's own
-- REQUEST_MODEL_TIMEOUT_MS (a single small prop, generous ceiling).
-- Duplicated rather than shared per this resource's established "tiny
-- constant/helper, private per file" convention (see client/kennel.lua's
-- own NotifyPlayer-equivalent duplication note in server/kennel.lua).
local REQUEST_MODEL_TIMEOUT_MS = 5000

--- Shared attach/detach mechanic — see this file's header FILE-TO-FILE
--- CONTRACT block for the full parameter/return contract. NEVER errors:
--- every failure path returns nil instead.
--- @param modelName string
--- @param boneIndex number
--- @param offsetX number
--- @param offsetY number
--- @param offsetZ number
--- @param rotX number
--- @param rotY number
--- @param rotZ number
--- @param isNetworked boolean
--- @param timeoutMs number?
--- @return number? entity
function AttachPropToOwnPed(modelName, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, isNetworked, timeoutMs)
    if type(modelName) ~= 'string' or modelName == '' then return nil end

    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then
        return nil -- not even a recognized model hash on this client's installed game data
    end

    RequestModel(modelHash)
    local waited = 0
    local timeout = timeoutMs or REQUEST_MODEL_TIMEOUT_MS
    while not HasModelLoaded(modelHash) and waited < timeout do
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
        -- forever — this function's callers (client/fetch.lua's own
        -- 'attach'-mode carry, this file's attachK9Prop primary/fallback
        -- attempt) only ever call SetModelAsNoLongerNeeded on a modelHash
        -- they actually went on to CreateObject with, so a timed-out
        -- request's own hash would otherwise never be released at all.
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end

    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    local obj = CreateObject(modelHash, pedCoords.x, pedCoords.y, pedCoords.z, isNetworked == true, true, false)
    SetModelAsNoLongerNeeded(modelHash)

    if not DoesEntityExist(obj) then
        return nil
    end

    -- Same argument shape as client/combat.lua's PropDragging attach call
    -- (AttachEntityToEntity(targetPed, PlayerPedId(), 0, 0.0, -0.6, 0.0,
    -- 0.0, 0.0, 0.0, true, false, false, false, 2, true)) — reused
    -- deliberately rather than inventing a new flag combination, so this
    -- call inherits that call site's own confidence grading rather than a
    -- fresh, independently-unverified one. Collision (arg 11) is left
    -- false here too: a cosmetic/diagnostic prop riding along on a ped
    -- should never physically interact with the world.
    AttachEntityToEntity(obj, ped, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, true, false, false, false, 2, true)

    return obj
end

--- Safe teardown — see this file's header FILE-TO-FILE CONTRACT block.
--- @param entity number?
function DetachAndDeleteProp(entity)
    if not entity or not DoesEntityExist(entity) then return end
    DetachEntity(entity, true, false)
    DeleteEntity(entity)
end

-- This client's own currently-attached vest entity, if any (nil otherwise).
-- Read from client/appearance.lua (IsPropAttachmentEngaged() below);
-- otherwise local-only. This is a CLIENT-SIDE MIRROR of
-- server/propattachment.lua's authoritative PropAttachmentState entry, not
-- an independent source of truth — see client/kennel.lua's own
-- myKennelNetId comment for the identical reasoning applied here.
local myVestEntity = nil

--- Resource-global convenience predicate — "does THIS client currently have
--- a prop attached to its own ped via this feature". Closes the KNOWN GAP
--- client/appearance.lua's header previously flagged: a K9 model swap
--- (SetPlayerModel) must refuse while a vest is attached, the same way it
--- already refuses for IsLeashed()/IsBiteHoldEngaged()/IsDragEngaged()/
--- IsFetchCarryEngaged()/IsInK9Vehicle() — this was the missing sixth check,
--- left as a disclosed gap rather than silently guessed at. Declared OUTSIDE
--- the `if Config.Features.PropAttachments then` gate below, same as
--- myVestEntity itself and this file's other shared mechanics, so a caller
--- can consult it unconditionally via the established
--- `type(IsPropAttachmentEngaged) == 'function'` soft-dependency check
--- regardless of whether this feature is enabled on this server (with the
--- feature off, myVestEntity is never set and this always reads false).
--- @return boolean
function IsPropAttachmentEngaged()
    return myVestEntity ~= nil and DoesEntityExist(myVestEntity)
end

-- DEFENSE-IN-DEPTH MODEL ALLOWLIST — same role as client/kennel.lua's own
-- KennelPropModelHashes on its removeKennel handler: even with the
-- SOURCE-ORIGIN GUARD below, a DeleteEntity driven entirely by a
-- caller-supplied netId should never trust that the resolved entity is
-- actually one of THIS feature's own props. Built LAZILY (not at file-load
-- time like KennelPropModelHashes) because Config.PropAttachments is only
-- guaranteed to exist once the feature is genuinely enabled and
-- server/propattachment.lua's own onResourceStart config-safety guard has
-- already validated its shape — reading cfg.propModel/fallbackPropModel at
-- file-load time here would error on a server that ships this file with the
-- feature left off (its shipped default), since Config.PropAttachments
-- itself does not exist in that state.
--- @return table<number, boolean>? modelHashes nil if Config.PropAttachments isn't a valid table yet
local PropAttachmentModelHashes = nil
local function GetPropAttachmentModelHashes()
    if PropAttachmentModelHashes then return PropAttachmentModelHashes end

    local cfg = Config.PropAttachments
    if type(cfg) ~= 'table' then return nil end

    local hashes = {}
    if type(cfg.propModel) == 'string' and cfg.propModel ~= '' then
        hashes[GetHashKey(cfg.propModel)] = true
    end
    if type(cfg.fallbackPropModel) == 'string' and cfg.fallbackPropModel ~= '' then
        hashes[GetHashKey(cfg.fallbackPropModel)] = true
    end

    if next(hashes) == nil then return nil end -- malformed config -- never allowlist an empty set (that would vacuously reject everything anyway, but be explicit)
    PropAttachmentModelHashes = hashes
    return PropAttachmentModelHashes
end

--- Requests the toggle. Exposed globally rather than kept as a
--- command-local closure, mirroring client/kennel.lua's
--- RequestDeployKennel() — so a future radial entry can call this directly
--- without this file needing to change.
function RequestToggleK9PropAttachment()
    -- RESOLVE INTENT BEFORE GATING — "gate the START of a thing, never the
    -- STOP", and this function used to break that rule in the one way that
    -- was easy to miss. Both gates below sit above a call whose MEANING is
    -- decided server-side: add if you have no vest, REMOVE if you do. So
    -- gating the call gated the removal too.
    --
    -- The trap that produced, found by a trap-hunt pass: a handler puts the
    -- vest on, then loses their certification (an ordinary thing — a
    -- revoke, a department change). CanShowK9UI() is a live server-backed
    -- check with about a one-second cache, so within a second every route
    -- to taking the vest off — this command, the radial item, and the
    -- tablet button, all three of which call this one function — returned
    -- here without ever telling the server. server/propattachment.lua's own
    -- REMOVE branch is deliberately unconditional and was itself a fix for
    -- exactly this bug class; the gate up here quietly reinstated it one
    -- layer above. Worse, client/appearance.lua refuses to swap a K9 back to
    -- a human model while a vest is attached, so the player could not undo
    -- it that way either. There was no self-service way out short of dying.
    --
    -- So: if a vest is already on, the request goes through unconditionally.
    -- Same shape client/kennel.lua's RequestDeployKennel() uses (resolve
    -- "am I already carrying something" before any flag or access gate) and
    -- every other start-gated request uses (only check access
    -- when switching ON, never when switching OFF).
    --
    -- This grants nothing. Taking off a vest you are already wearing is not
    -- a capability, and the server re-derives add-vs-remove from its own
    -- PropAttachmentState either way — a client claiming to be removing one
    -- it does not have simply lands in the add branch and is gated there.
    if IsPropAttachmentEngaged() then
        TriggerServerEvent('john-k9:server:requestToggleK9PropAttachment')
        return
    end

    if not Config.Features.PropAttachments then return end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- No client-side "already have one" short-circuit before the server
    -- round trip the way client/kennel.lua has one — unlike a kennel
    -- placement (a genuinely new action every time), a toggle is a single
    -- request whose MEANING (add vs remove) is decided server-side by
    -- whether PropAttachmentState already has an entry; this file doesn't
    -- need to predict that to know whether to send the request.
    TriggerServerEvent('john-k9:server:requestToggleK9PropAttachment')
end

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE — the command below, all three
-- RegisterNetEvent handlers, the own-death auto-detach thread, and the
-- onResourceStop hook are now all inside this single `if`, evaluated once
-- at this file's own load time (config.lua is a shared_scripts file,
-- loaded in full before any client_scripts file runs, so
-- Config.Features.PropAttachments already holds its real value here —
-- not a load-order gamble). AttachPropToOwnPed/DetachAndDeleteProp/
-- GetPropAttachmentModelHashes/RequestToggleK9PropAttachment above stay
-- OUTSIDE this gate on purpose — see this file's own FILE-TO-FILE CONTRACT
-- header ("Neither function is gated on Config.Features.PropAttachments")
-- for AttachPropToOwnPed/DetachAndDeleteProp specifically (client/bonetool.lua
-- calls both regardless of THIS flag, gated instead on its own
-- BoneSweepDevTool flag); RequestToggleK9PropAttachment already gates
-- itself internally and must stay reachable-but-inert for a future radial
-- entry per its own doc comment, same as client/kennel.lua's
-- RequestDeployKennel.
-- WHY THIS MATTERS BEYOND THE EXISTING PER-HANDLER `if not
-- Config.Features.PropAttachments then return end` CHECKS ALREADY INSIDE
-- each handler below (kept, deliberately, as defense-in-depth, same
-- "layered checks" posture as the SOURCE-ORIGIN GUARD remaining even though
-- the feature gate also exists): a per-handler check still means
-- '/k9propattach' and all three 'john-k9:client:*' events ARE registered
-- and reachable on a client with the feature left off. Wrapping the
-- registration itself means a server that has never opted into
-- PropAttachments ships clients where this command/these events do not
-- exist AT ALL, and the death-poll thread never starts — genuinely inert,
-- not merely hidden behind an early return, matching this resource's own
-- server/bonetool.lua precedent (its '/k9bonetool' command is only ever
-- RegisterCommand'd inside its own flag-checked onResourceStart).
-- ======================================================================
if Config.Features.PropAttachments then

RegisterCommand('k9propattach', function()
    RequestToggleK9PropAttachment()
end, false)

--- Server-issued instruction: create+attach the configured prop to your OWN
--- ped, then report its netId back (or cancel if it never loads).
RegisterNetEvent('john-k9:client:attachK9Prop', function()
    -- SOURCE-ORIGIN GUARD — see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup, not re-derived here. 65535 is FiveM's documented
    -- client-side sentinel for "this event genuinely came from the
    -- server" (citizenfx/fivem-docs, "Secure your events"). Confidence:
    -- MEDIUM-HIGH, the official documented pattern, not independently
    -- verified in-engine.
    if source ~= 65535 then return end

    -- FEATURE GATE — this handler must never fire real effects while the
    -- flag is off, matching every other gated handler's own per-handler
    -- gating convention in this resource (client/kennel.lua's
    -- deployKennelAt/removeKennel are the closest precedent).
    if not Config.Features.PropAttachments then return end

    -- STALE-VEST GUARD: belt-and-braces against a second vest on retry.
    -- myVestEntity from a first, silently-rejected attempt can survive
    -- untouched into a second 'attachK9Prop' dispatch (e.g. the player
    -- simply retries '/k9propattach' after the first attempt visibly did
    -- nothing). Without this guard, that second dispatch would create and
    -- track a SECOND vest object while overwriting the only handle this
    -- file had to the first one, permanently orphaning it (two visible
    -- vests, only one ever cleanable again). This does not by itself close
    -- every way that first vest could go untracked (a single failed
    -- attempt the player never retries still has no client-observable
    -- failure signal at all — that gap can only be closed by adding a
    -- rejectK9PropAttach call on every server-side failure branch) but it
    -- does guarantee THIS file never simultaneously tracks, or silently
    -- drops the only handle to, more than one vest of its own creation.
    if myVestEntity and DoesEntityExist(myVestEntity) then
        DetachAndDeleteProp(myVestEntity)
    end
    myVestEntity = nil

    local cfg = Config.PropAttachments
    local obj = AttachPropToOwnPed(
        cfg.propModel, cfg.boneIndex,
        cfg.offsetX, cfg.offsetY, cfg.offsetZ,
        cfg.rotX, cfg.rotY, cfg.rotZ,
        true, -- isNetworked: other players must see this
        nil
    )

    local usedFallback = false
    if not obj then
        usedFallback = true
        obj = AttachPropToOwnPed(
            cfg.fallbackPropModel, cfg.boneIndex,
            cfg.offsetX, cfg.offsetY, cfg.offsetZ,
            cfg.rotX, cfg.rotY, cfg.rotZ,
            true, nil
        )
    end

    if not obj then
        lib.notify({ title = locale('common.notify_title'), description = locale('propattachment.vest_prop_load_failed'), type = 'error' })
        TriggerServerEvent('john-k9:server:cancelPropAttachRequest')
        return
    end

    if usedFallback then
        -- Low-key server-console breadcrumb, not a player-facing error —
        -- same posture/wording convention as client/kennel.lua's own
        -- fallback breadcrumb.
        print(('[John-K9] PropAttachments: propModel "%s" failed to load, used fallbackPropModel "%s" instead — see config.lua\'s Config.PropAttachments comment.'):format(cfg.propModel, cfg.fallbackPropModel))
    end

    myVestEntity = obj
    local netId = NetworkGetNetworkIdFromEntity(obj)
    TriggerServerEvent('john-k9:server:confirmPropAttached', netId)
end)

--- Server rejected this client's own just-created attachment (failed the
--- server's model/position defense-in-depth checks) — undo it locally.
RegisterNetEvent('john-k9:client:rejectK9PropAttach', function()
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see attachK9Prop's own comment above
    if not Config.Features.PropAttachments then return end

    DetachAndDeleteProp(myVestEntity)
    myVestEntity = nil
end)

--- Cleanup backstop broadcast from server/propattachment.lua — see that
--- file's RemovePropAttachmentForCitizenid CLEANUP CONFIDENCE NOTE for why
--- this exists alongside the server's own direct DeleteEntity attempt. Safe
--- no-op for any client that doesn't have this netId streamed in.
--- @param netId number
RegisterNetEvent('john-k9:client:removeK9PropAttachment', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see attachK9Prop's own comment above
    if not Config.Features.PropAttachments then return end
    if type(netId) ~= 'number' then return end

    -- DEVELOPER_REFERENCE.md near-term item 2: this was previously a
    -- hand-rolled "NetworkDoesEntityExistWithNetworkId ->
    -- NetworkGetEntityFromNetworkId -> DoesEntityExist" sequence, the exact
    -- pattern this resource already centralised into client/main.lua's
    -- ResolveNetworkEntity (see that function's own doc comment for the
    -- prior copies it already replaced). Do not re-introduce a hand-rolled
    -- copy of this sequence anywhere in this file.
    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    -- DEFENSE-IN-DEPTH MODEL CHECK — mirrors client/kennel.lua's own
    -- removeKennel handler verbatim: server/propattachment.lua's own
    -- dispatch site only ever broadcasts a genuine vest's netId, but nothing
    -- upstream of this line re-derives that fact here. Restricting the
    -- delete to an entity whose CURRENT model actually matches one of the
    -- two configured prop models turns "arbitrary entity deletion" into, at
    -- worst, "delete some other player's legitimately attached vest prop" —
    -- should the origin guard above ever be defeated by something that
    -- could not be evaluated here (see that guard's own confidence note). A
    -- nil return from GetPropAttachmentModelHashes() (malformed/missing
    -- config) fails closed — never deletes anything.
    local modelHashes = GetPropAttachmentModelHashes()
    if not modelHashes or not modelHashes[GetEntityModel(entity)] then return end

    if myVestEntity == entity then
        myVestEntity = nil
    end

    DetachAndDeleteProp(entity)
end)

-- OWN-DEATH AUTO-DETACH: an attached prop must be cleaned up on K9 death.
-- Lightweight poll, only running at all while this client actually has a
-- vest attached — mirrors client/vision.lua's/client/screenfx.lua's own
-- existing IsEntityDead(PlayerPedId()) polling pattern for the same class
-- of "is my own ped currently dead" check. Self-reported to the server
-- (see server/propattachment.lua's header event 4 for the trust-category
-- reasoning) rather than assumed handled purely client-side, so the
-- SERVER's own PropAttachmentState (and therefore the broadcast backstop
-- to every other client) is cleared too, not just this client's local
-- view.
CreateThread(function()
    while true do
        Wait(1000)
        if myVestEntity and DoesEntityExist(PlayerPedId()) and IsEntityDead(PlayerPedId()) then
            DetachAndDeleteProp(myVestEntity)
            myVestEntity = nil
            TriggerServerEvent('john-k9:server:reportOwnK9PropAttachDeath')
        end
    end
end)

-- Resource-restart safety net (same class of fix as client/kennel.lua's own
-- onResourceStop handler, for a different piece of entity state): if THIS
-- client attached a vest and the resource stops while it's still
-- connected, delete it locally rather than leaving a frozen, ownerless
-- object behind. Covers the common "still connected at resource restart"
-- case; server/propattachment.lua's own onResourceStop loop covers
-- attachments whose creating client already disconnected earlier in the
-- session.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not myVestEntity then return end

    DetachAndDeleteProp(myVestEntity)
    myVestEntity = nil
end)

end -- if Config.Features.PropAttachments -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
