--[[
    john-k9/client/equipmentshop.lua

    K9 EQUIPMENT SHOP (client half) -- DEVELOPER_REFERENCE.md Part B §6. See
    server/equipmentshop.lua's own header for the full design and, in
    particular, its "VERIFIED, NOT ASSUMED" section point 2 for exactly why
    this small companion file exists at all: a shop registered from an
    EXTERNAL resource via `exports.ox_inventory:RegisterShop` gains no
    walk-up marker/prompt of its own -- ox_inventory's own internal
    marker/target system only ever reads shops from ITS OWN bundled
    `data/shops.lua`, never from anything registered later via that export.
    This file is the physical interaction point that makes the
    server-registered shop actually reachable.

    Every real check -- can this player see this shop, can they afford an
    item, is the item real -- happens entirely inside ox_inventory's own
    already-security-reviewed code, server-side. This resource decides
    nothing about the TRANSACTION here; it only places a door -- see
    "RUNTIME SHOP LOCATIONS" below for what that "door" actually is now.

    `groups` on the ox_target option is a VISUAL/UX filter ONLY, mirroring
    ox_inventory's own client module doing the identical thing for its
    internal shops -- it hides the prompt from an obviously-ineligible
    player as a convenience. It is NOT the authorization boundary: even if
    a modified client removed this filter and opened the shop anyway,
    ox_inventory's own server-side `hasGroup` check inside its
    `ox_inventory:openShop` callback (server/equipmentshop.lua's header,
    point 4) still decides what that player can actually see or buy.

    Reads `Config.K9EquipmentShop`/`Config.Features.K9EquipmentShop`
    defensively throughout -- see server/equipmentshop.lua's own header for
    the exact shape this expects and why a server that has not (yet) added
    either is a silent, total no-op here too: no ped, no ox_target call, no
    error.

    ======================================================================
    A REAL PED, NOT A BARE SPHERE. The owner's own words: "make the shop a
    dog ped." Previously this file built an invisible `ox_target` sphere
    zone at each configured location; it now spawns a real, visible ped
    there instead and targets THAT PED directly via
    `K9Compat.Get('target').AddLocalEntity` -- the correct primitive for
    a locally-created (non-networked) entity handle, originally confirmed by
    reading ox_target's own client/api.lua directly (`addEntity` takes a
    NETWORK ID and is for networked entities; `addLocalEntity` takes a raw
    entity handle and is the one this file's own non-networked peds need),
    and now also confirmed for qb-target/qtarget/sleepless_interact -- see
    shared/compat/target.lua's own per-adapter comments for the full,
    per-backend confirmation record this method goes through). Which model,
    and any idle scenario it plays, is fully operator-configurable
    (Config.K9EquipmentShop.pedModel/pedHeading/pedScenario, or a
    per-location override of any of those three plus `label`) -- never
    hardcoded, and never validated against Config.Peds, since a shop
    attendant is not a K9.

    ======================================================================
    COMPAT LAYER. Both third-party calls this file makes -- targeting the
    ped, and opening the shop UI -- go through `K9Compat.Get(...)`
    (shared/compat/core.lua) instead of a direct
    `exports.ox_target`/`exports.ox_inventory` call, so this feature keeps
    working on a server running qb-target/qtarget/sleepless_interact for
    targeting, or a non-ox_inventory backend for the shop UI, per
    Config.Compat. This closes a real gap: `AddLocalEntity`/
    `RemoveLocalEntity` were not originally part of the target adapter
    contract, because this shop-ped feature was built AFTER that contract
    was first written and nobody re-checked its call sites against it (see
    DEVELOPER_REFERENCE.md §21 for the fuller writeup of that failure
    shape). `K9Compat.Get('target')`/`K9Compat.Get('inventory')` are NEVER
    `nil` and every method on them is already `pcall`-safe (see core.lua's
    own header) -- this file adds no additional nil-check or pcall of its
    own around either call. If nothing usable is detected for a system,
    that system's methods are safe no-ops (return `nil`/do nothing) rather
    than an error: a shop with no usable target adapter places no
    interactive ped (silent, logged once by the compat layer itself, not by
    this file); a shop with no usable inventory adapter shows a ped that,
    once interacted with, opens nothing (the ped and its prompt still
    render -- the compat layer's own no-op stub has no way to hide a menu
    OPTION this file already built before calling it, only to make the
    underlying action itself go nowhere). `K9Compat`/`shared/compat/core.lua`
    are shared_scripts loaded ahead of every client_scripts entry (see
    fxmanifest.lua), so `K9Compat` is always defined by the time this file's
    own top-level code runs.

    NATIVES VERIFIED, against https://runtime.fivem.net/doc/natives.json
    (every one of these has NO decl page at
    https://raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/ --
    all nine returned HTTP 404 there, which per this resource's own
    "a 404 is NOT proof of absence -- most legacy R* natives have no decl
    page" convention is not disqualifying on its own; each one below WAS
    confirmed present in the natives.json dump, under its documented real
    name/params, with NO `apiset` key at all -- which that same convention
    reads as "client-only", exactly where every one of these is used, only
    ever from this client file):
      CREATE_PED, SET_ENTITY_HEADING (used implicitly via CreatePed's own
      heading parameter -- no separate call needed), SET_ENTITY_INVINCIBLE,
      SET_BLOCKING_OF_NON_TEMPORARY_EVENTS, SET_ENTITY_AS_MISSION_ENTITY,
      TASK_START_SCENARIO_IN_PLACE, SET_MODEL_AS_NO_LONGER_NEEDED,
      REQUEST_MODEL, HAS_MODEL_LOADED, IS_MODEL_VALID.
    FREEZE_ENTITY_POSITION / DOES_ENTITY_EXIST / DELETE_ENTITY are NOT
    re-verified here -- both already have established, working precedent
    elsewhere in this exact codebase (client/kennel.lua, client/movement.lua)
    and this resource's own convention is to verify a native before its
    FIRST use in this codebase, not on every subsequent reuse.

    ======================================================================
    ENTITY LIFECYCLE -- THE PART THIS CODEBASE HAS BEEN BURNED BY BEFORE
    (an arbitrary-entity-deletion bug in client/kennel.lua's history, and a
    netId race in prop attachment). Read this before touching anything
    below:

      WHY THESE PEDS ARE LOCAL, NEVER NETWORKED (`CreatePed(..., false,
      false)`): a shop attendant is pure decoration with zero gameplay
      state that needs to be consistent across clients -- every nearby
      player independently spawning their OWN local copy at the identical
      configured coordinate looks visually identical to a single shared
      networked entity, with none of a networked entity's failure modes
      this resource has already been bitten by (no netId to race on, no
      ownership migration between clients, nothing for a DIFFERENT
      client's stale netId broadcast to ever resolve to). This is a
      deliberate choice, not an oversight -- see server/equipmentshop.lua's
      own header for why the SERVER never creates or tracks these ped
      entities at all, only the ABSTRACT location data (coordinates/model/
      heading/scenario/label) they're spawned from.

      WHO OWNS EACH PED'S LIFETIME: THIS client, and only this client, for
      exactly as long as this resource keeps running on it. Every ped this
      file ever creates is recorded in `SpawnedPeds[locationKey]` at the
      moment of creation, by its own real entity handle -- NEVER resolved
      later by a proximity search, a model check against "any nearby ped
      that looks like a shop attendant", or any other indirect means. Every
      deletion in this file (`DespawnShopPed`) reads that SAME handle back
      out of that SAME table before deleting it, and clears the table entry
      in the same call -- there is no code path anywhere in this file that
      deletes an entity it did not itself create and record.

      WHAT DELETES A PED, AND WHEN (three independent, non-overlapping
      triggers, listed exhaustively):
        1. DISTANCE: the per-location worker thread (see
           `StartLocationWorker` below) despawns a location's ped once the
           local player is beyond `PED_DESPAWN_RADIUS` of it -- a shop
           attendant nobody is near has no reason to keep existing.
        2. CONTENT CHANGE: if a location's own data (coordinates/model/
           heading/scenario/label) changes while its ped is already
           spawned -- a tablet "move" landing while a player happens to be
           standing right there -- the worker despawns the stale ped and
           immediately respawns a fresh one at the new spec, rather than
           trying to reposition/re-skin a live entity in place.
        3. REMOVAL/RESOURCE STOP: if a location disappears from
           `ActiveLocations` entirely (a tablet "remove", or this resource
           itself stopping), its ped is despawned and that location's own
           worker thread exits -- see `StartLocationWorker`'s own loop
           body and the `onResourceStop` handler at the bottom of this
           file for the two respective call sites.

      NO DUPLICATION ACROSS A RESTART OR A LOCATION UPDATE: `SpawnShopPed`
      is a no-op if `SpawnedPeds[key]` is already set (guards every call
      site, both the distance-based spawn and content-change respawn
      paths) -- a location can never end up with two live peds recorded
      against the same key. A resource restart tears down this whole
      file's Lua state (every table above resets empty) and this file's own
      `onResourceStop` handler (below) deletes every currently-tracked ped
      BEFORE that happens, so a restart never leaves an orphaned entity
      behind for the next boot to duplicate alongside.

      NO ACCUMULATION AS PLAYERS STREAM IN/OUT: these peds are never
      created in response to another player connecting, discononecting, or
      streaming in/out -- the only two triggers that ever create one are
      the distance check and the content-change respawn above, both scoped
      to THIS client's own proximity to a FIXED, small set of configured/
      database-backed locations (never a per-player entity). A player
      streaming in or out changes nothing this file reads.

      NO UNBOUNDED TRAP: every per-location worker thread is a plain
      `while true do ... Wait(...) end` loop that exits via a normal `return`
      the moment its own location disappears from `ActiveLocations` --
      never a blocking wait with no exit condition, never a thread that
      outlives the data it was managing.

    ======================================================================
    RUNTIME SHOP LOCATIONS -- see server/equipmentshop.lua's own header
    "RUNTIME SHOP LOCATIONS" section for the full server-side design (the
    high-command-tablet add/move/remove callbacks, the privilege check,
    the SCOPE decision that this only ever manages the database-native
    `db:<id>` pool, never a config.lua `cfg:<n>` entry). THIS file's role
    is small and one-directional: fetch the server's already-fully-resolved
    effective location table once at startup
    (`john-k9:server:equipmentShopGetLocations`), and replace it wholesale
    whenever the server broadcasts a fresh one
    (`john-k9:client:equipmentShopLocationsUpdated`, sent to everyone on
    every successful tablet add/move/remove). This file does NOT re-derive
    the config-vs-database merge logic for the live/server-backed path at
    all -- only as a FALLBACK (`BuildConfigOnlyLocations` below) for the
    rare case the initial server round-trip itself never completes (a
    genuine, disclosed degradation: the shop's own config.lua-defined
    locations still work; a tablet-added one would be unavailable until
    that resolves), so this file's own always-live copy of the
    fallback-only merge rule stays a small, self-contained, easily-audited
    duplicate rather than a second full copy of the server's real logic.

    Client events (server->client), THIS file:
    - 'john-k9:client:equipmentShopLocationsUpdated' (locations: table)
      [SOURCE-ORIGIN GUARDED -- see the handler itself]

    ======================================================================
    FXMANIFEST.LUA PLACEMENT: `client/equipmentshop.lua` is already listed
    in client_scripts, no reordering needed. Reads only `Config`, already
    loaded via shared_scripts; calls only `K9Compat.Get(...)`
    (shared/compat/*.lua, ALSO loaded via shared_scripts, and therefore
    already defined by the time any client_scripts entry runs -- see
    fxmanifest.lua's own shared_scripts ordering), which in turn reaches
    `exports.ox_target`/`exports.ox_inventory` (or whatever else
    Config.Compat resolved) on this file's behalf; plus
    `lib.callback.await`, already a hard dependency of this whole resource
    via ox_lib.
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
-- ======================================================================
-- MODULE STATE -- see this file's own "ENTITY LIFECYCLE" header section
-- for the full ownership/deletion contract each of these participates in.
-- ======================================================================

--- The full, effective shop location table this client currently knows
--- about, keyed by location key ('cfg:<n>' | 'db:<id>') -> already-resolved
--- { x, y, z, heading, model, scenario, label }. Replaced WHOLESALE by the
--- initial server fetch and by every `equipmentShopLocationsUpdated`
--- broadcast -- never mutated field-by-field from this file.
--- @type table<string, table>
local ActiveLocations = {}

--- @type table<string, number> -- [locationKey] = live ped entity handle
local SpawnedPeds = {}

--- @type table<string, table> -- [locationKey] = the opaque handle K9Compat.Get('target').AddLocalEntity returned for SpawnedPeds[key], passed back to RemoveLocalEntity UNTOUCHED (see shared/compat/target.lua's own header on why this value's shape is private to whichever adapter produced it -- never inspected or reshaped here)
local SpawnedTargetHandles = {}

--- The exact location table object last used to spawn/respawn
--- `SpawnedPeds[key]`, compared field-by-field on every worker tick
--- (`LocationsEqual` below) to detect a content change (a tablet "move")
--- without forcing a wholesale respawn of every OTHER, unchanged location
--- whenever `ActiveLocations` itself is replaced wholesale.
--- @type table<string, table>
local SpawnedLocSnapshot = {}

--- @type table<string, boolean> -- [locationKey] = true once a per-location worker thread has been started for it
local WorkerStarted = {}

--- @type table<string, boolean> -- [locationKey] = true after a model-load/CreatePed failure, cleared once the player leaves PED_DESPAWN_RADIUS (see StartLocationWorker) so a later config/DB fix gets a fresh attempt without spamming a warning every tick while the player stands there
local FailedKeys = {}

--- ox_target `groups` filter (job -> minimum grade), same derivation as
--- server/equipmentshop.lua's own copy over Config.Departments -- see that
--- file's header point 4 for why this is a display-only convenience, never
--- the real authorization boundary. Computed once in the startup thread
--- below.
local ShopGroups = nil

--- Config.K9EquipmentShop.shopType, captured once in the startup thread --
--- every spawned ped's ox_target option closes over this single value.
local ShopType = nil

-- ======================================================================
-- CONFIG-ONLY FALLBACK MERGE -- see this file's header "RUNTIME SHOP
-- LOCATIONS" section for why this exists and how it differs in scope from
-- server/equipmentshop.lua's own real BuildEffectiveLocations/
-- ResolveLocation. Used ONLY when the initial server round-trip in the
-- startup thread below never completes.
-- ======================================================================

--- @param entry table -- one Config.K9EquipmentShop.locations[i] entry
--- @param shopConfig table -- Config.K9EquipmentShop
--- @return table -- { x, y, z, heading, model, scenario, label }
local function ResolveLocationFallback(entry, shopConfig)
    local heading = type(entry.heading) == 'number' and entry.heading or shopConfig.pedHeading
    if type(heading) ~= 'number' then heading = 0.0 end

    local model = (type(entry.model) == 'string' and entry.model ~= '') and entry.model or shopConfig.pedModel
    if type(model) ~= 'string' or model == '' then model = 'a_c_shepherd' end

    local scenario
    if entry.scenario == false then
        scenario = ''
    elseif type(entry.scenario) == 'string' and entry.scenario ~= '' then
        scenario = entry.scenario
    elseif shopConfig.pedScenario == false then
        scenario = ''
    elseif type(shopConfig.pedScenario) == 'string' and shopConfig.pedScenario ~= '' then
        scenario = shopConfig.pedScenario
    else
        scenario = ''
    end

    local label = (type(entry.label) == 'string' and entry.label ~= '') and entry.label
        or (type(shopConfig.label) == 'string' and shopConfig.label ~= '' and shopConfig.label)
        or 'K9 Supply'

    return { x = entry.x, y = entry.y, z = entry.z, heading = heading, model = model, scenario = scenario, label = label }
end

--- @param shopConfig table -- Config.K9EquipmentShop
--- @return table<string, table>
local function BuildConfigOnlyLocations(shopConfig)
    local out = {}
    if type(shopConfig.locations) ~= 'table' then return out end

    for i, entry in ipairs(shopConfig.locations) do
        -- config.lua stores these as plain { x, y, z } tables rather than
        -- live vector3() calls, matching every other coordinate table in
        -- config.lua: config.lua must stay loadable outside the game, and a
        -- vector3() call at its top level is not. The conversion belongs
        -- here, at the one place the value is actually handed to a native.
        if type(entry) == 'table' and type(entry.x) == 'number' and type(entry.y) == 'number' and type(entry.z) == 'number' then
            out['cfg:' .. i] = ResolveLocationFallback(entry, shopConfig)
        else
            print(('[John-K9] equipmentshop (client): Config.K9EquipmentShop.locations[%d] is not a { x = , y = , z = } table of numbers -- skipped. No shop ped is placed for it.'):format(i))
        end
    end

    return out
end

-- ======================================================================
-- MODEL LOADING -- same RequestModel/HasModelLoaded polling pattern,
-- including the leak fix, as client/kennel.lua's LoadModelWithTimeout and
-- client/appearance.lua's own copy of it -- see either for the full "why
-- this exact shape" writeup, not repeated here.
-- ======================================================================

--- @return number
local function PedModelLoadTimeoutMs()
    local timeout = Config.K9EquipmentShop and Config.K9EquipmentShop.pedModelLoadTimeoutMs
    if type(timeout) ~= 'number' or timeout <= 0 then return 10000 end
    return timeout
end

--- @param modelName string
--- @return number? modelHash -- nil if the model name is invalid, or never finished loading in time
local function LoadPedModelWithTimeout(modelName)
    if type(modelName) ~= 'string' or modelName == '' then return nil end

    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then
        return nil -- not even a recognized model hash on this client's installed game data
    end

    RequestModel(modelHash)
    local waited = 0
    local timeoutMs = PedModelLoadTimeoutMs()
    while not HasModelLoaded(modelHash) and waited < timeoutMs do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        -- LEAK FIX, same as client/kennel.lua's/client/appearance.lua's
        -- identical comment: RequestModel above incremented this model's
        -- streaming reference count; release it on this failure path too,
        -- or it is held forever.
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end
    return modelHash
end

-- ======================================================================
-- SPAWN / DESPAWN -- see this file's header "ENTITY LIFECYCLE" section
-- for the full ownership contract these two functions implement.
-- ======================================================================

--- @param a table? @param b table?
--- @return boolean
local function LocationsEqual(a, b)
    if not a or not b then return false end
    return a.x == b.x and a.y == b.y and a.z == b.z and a.heading == b.heading
        and a.model == b.model and a.scenario == b.scenario and a.label == b.label
end

--- No-op if `key` already has a live spawned ped -- never double-spawns.
--- On any failure (bad/slow model, CreatePed itself failing), warns ONCE
--- per key (until the player leaves PED_DESPAWN_RADIUS, see
--- StartLocationWorker) and leaves that ONE location without a ped rather
--- than aborting anything else -- matches this resource's established
--- "skip the one bad entry, not the whole feature" convention
--- (server/equipmentshop.lua's own WarnIfItemMissing).
--- @param key string
--- @param loc table -- { x, y, z, heading, model, scenario, label }
local function SpawnShopPed(key, loc)
    if SpawnedPeds[key] then return end

    local modelHash = LoadPedModelWithTimeout(loc.model)
    if not modelHash then
        if not FailedKeys[key] then
            FailedKeys[key] = true
            print(('[John-K9] equipmentshop (client): shop ped model %q for location %q failed to load within %dms -- skipped. This location has no visible ped (and is unreachable) until its model is fixed.'):format(tostring(loc.model), key, PedModelLoadTimeoutMs()))
        end
        return
    end

    local ped = CreatePed(4, modelHash, loc.x, loc.y, loc.z, loc.heading, false, false)
    -- Release the streaming reference regardless of whether CreatePed
    -- itself succeeded -- same leak-prevention discipline as every other
    -- RequestModel call site in this resource.
    SetModelAsNoLongerNeeded(modelHash)

    if not DoesEntityExist(ped) then
        if not FailedKeys[key] then
            FailedKeys[key] = true
            print(('[John-K9] equipmentshop (client): CreatePed failed for shop location %q -- skipped.'):format(key))
        end
        return
    end

    -- Prevent the game's own population/entity-cleanup systems from
    -- despawning this ped out from under this file's own tracking table --
    -- every deletion of this ped happens explicitly, from THIS file, via
    -- DespawnShopPed below, never implicitly by the engine.
    SetEntityAsMissionEntity(ped, true, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)

    if loc.scenario ~= '' then
        TaskStartScenarioInPlace(ped, loc.scenario, 0, true)
    end

    SpawnedPeds[key] = ped
    SpawnedLocSnapshot[key] = loc
    FailedKeys[key] = nil

    local label = (type(loc.label) == 'string' and loc.label ~= '') and loc.label or 'K9 Supply'

    -- Target THE PED directly (AddLocalEntity, a raw entity handle -- see
    -- this file's header for why this, not AddModel/a bare sphere zone).
    -- Routed through K9Compat (shared/compat/core.lua) rather than
    -- `exports.ox_target:addLocalEntity` directly -- see this file's own
    -- "COMPAT LAYER" header section. The returned handle is OPAQUE and
    -- private to whichever adapter produced it (see shared/compat/target.lua's
    -- own header) -- recorded here, passed to RemoveLocalEntity UNTOUCHED
    -- in DespawnShopPed below, never inspected. A `nil` handle (no usable
    -- target adapter detected) is recorded as-is; DespawnShopPed's own
    -- `if handle then` guard already treats that as "nothing to remove",
    -- so no ped is targetable but nothing errors.
    -- ROLE ICON (resource-wide settled scheme: fa-dog = K9-role/
    -- CanShowK9UI()-gated, fa-user-tie = a separate human acting on/for a
    -- K9, fa-handshake = partnership, fa-id-badge = high
    -- command/credentialing). This option carries NO CanShowK9UI() gate at
    -- all -- any eligible department member can walk up and buy gear, K9
    -- or not -- so it is a HANDLER-bucket action (fa-user-tie), not a
    -- K9-role one, even though it previously used a shopping-basket icon
    -- that named the ACTION rather than who performs it. `groups` below
    -- (ox_target's own department/grade filter) already keeps this option
    -- from ever appearing to someone outside the configured department at
    -- all -- see this file's header on why that is a real, engine-level
    -- filter, not merely a canInteract convenience.
    -- KNOWN, DISCLOSED GAP: a per-citizenid `block.K9EquipmentShop` grant
    -- (server/equipmentshop.lua's IsEquipmentShopPermittedForCitizenId,
    -- surfaced to the player only via equipmentshop.blocked_from_shop
    -- AFTER they already select this option and the shop UI refuses to
    -- open) is invisible to this file -- there is no existing round trip
    -- this client can cheaply read to hide the option in advance for a
    -- specifically-blocked player, and adding one is a server-side surface
    -- change outside this file's ownership. Flagged rather than silently
    -- left; every OTHER refusal this file could reach client-side is
    -- fixed.
    local handle = K9Compat.Get('target').AddLocalEntity(ped, {
        {
            name = 'john-k9:equipmentShop:' .. key,
            label = label,
            icon = 'fas fa-user-tie',
            groups = ShopGroups,
            onSelect = function()
                -- THE RETURN VALUE IS THE WHOLE POINT. It used to be
                -- thrown away, and on one entirely plausible configuration
                -- that made this the worst kind of bug: a real, visible dog
                -- ped standing at a real, configured supply point, with a
                -- working prompt, that does absolutely nothing when
                -- clicked. No message on screen. Nothing in console.
                --
                -- shared/compat/inventory.lua's qb-inventory adapter (and
                -- ps-inventory's, same architecture) returns nil for the
                -- CLIENT realm unconditionally -- correctly, and honestly
                -- disclosed in its own header: those backends genuinely
                -- have no client-callable "open this shop" primitive, their
                -- OpenShop is a server-side-only export. And an explicit
                -- `Config.Compat.Systems.inventory.override` does NOT fall
                -- through to the other candidates (shared/compat/core.lua).
                -- So an owner who overrides to qb-inventory -- a very
                -- ordinary thing to do, it is a common inventory -- ends up
                -- with the server half of their inventory working fine
                -- (the K9 medkit, contraband searches) and this one player-
                -- facing door silently welded shut.
                --
                -- OpenShop never throws (it is pcall-wrapped inside the
                -- compat layer) and returns false rather than erroring, so
                -- reading the result is all that is needed here.
                -- Deliberately NOT a "try again" message: on that
                -- configuration it will never work, and telling a player to
                -- retry something structurally impossible is worse than
                -- telling them nothing. It names the real cause and points
                -- at the person who can actually fix it.
                local openOk = K9Compat.Get('inventory').OpenShop(ShopType)
                if not openOk then
                    lib.notify({
                        title = locale('common.notify_title'),
                        description = locale('equipmentshop.cannot_open_on_this_inventory'),
                        type = 'error',
                    })
                end
            end,
        },
    })
    SpawnedTargetHandles[key] = handle
end

--- Deletes `key`'s currently-spawned ped BY ITS OWN RECORDED HANDLE -- never
--- by a proximity/model search. No-op if `key` has no spawned ped. Safe to
--- call even if the entity has already gone away on its own (defensive
--- DoesEntityExist guard) -- always clears this file's own bookkeeping
--- regardless.
--- @param key string
local function DespawnShopPed(key)
    local ped = SpawnedPeds[key]
    if not ped then return end

    local handle = SpawnedTargetHandles[key]
    SpawnedPeds[key] = nil
    SpawnedTargetHandles[key] = nil
    SpawnedLocSnapshot[key] = nil

    -- TARGET REMOVAL IS UNCONDITIONAL, AND DELIBERATELY OUTSIDE THE
    -- DoesEntityExist CHECK BELOW. It used to sit inside it, which meant a
    -- ped that had ALREADY ceased to exist -- streamed out, cleaned up by
    -- the game, or deleted by another resource -- skipped its own target
    -- removal entirely. And because SpawnedTargetHandles[key] is cleared a
    -- few lines above (correctly: this function must be re-entrant), the
    -- handle was gone too, so nothing could ever remove that registration
    -- afterwards. It leaked for the rest of the session, once per despawn
    -- that raced the entity disappearing.
    --
    -- GATE THE START OF A THING, NEVER THE STOP: DoesEntityExist is exactly
    -- the sort of condition that is false PRECISELY when cleanup matters
    -- most, so it must never stand in front of one. It still guards
    -- DeleteEntity, which is the only half that genuinely needs a live
    -- entity.
    --
    -- Safe to call with a stale handle: the ox_target adapter
    -- (shared/compat/target.lua) type-checks the handle and routes through
    -- SafeCall, and removing an option from an entity that no longer exists
    -- is a no-op in every adapter. This also makes that adapter's own
    -- doc-comment true again -- it states this caller "always tears it down
    -- completely, never partially", which is what the old placement
    -- quietly broke.
    if handle then
        K9Compat.Get('target').RemoveLocalEntity(handle)
    end

    if DoesEntityExist(ped) then
        DeleteEntity(ped)
    end
end

-- ======================================================================
-- PER-LOCATION WORKER THREADS -- see this file's header "ENTITY
-- LIFECYCLE" section, trigger 1/2/3, for exactly what each branch below
-- implements. One thread per KNOWN location key, started lazily
-- (StartLocationWorker is idempotent -- WorkerStarted guards against ever
-- starting a second thread for the same key) and self-terminating the
-- moment its own key disappears from ActiveLocations -- see "NO UNBOUNDED
-- TRAP" in that same header section.
--
-- Wait(PED_DISTANCE_CHECK_INTERVAL_MS) between checks, not Wait(0): a
-- walk-up shop ped has no need for per-frame responsiveness, and this
-- resource's own performance convention is to use the largest Wait() that
-- still meets a feature's real responsiveness need -- 1 second is
-- imperceptible for "a ped appears as you approach a shop", the exact
-- same order of magnitude as client/movement.lua's own LEASH_IDLE_TICK_MS.
-- ======================================================================

local PED_SPAWN_RADIUS = 30.0
local PED_DESPAWN_RADIUS = 40.0 -- hysteresis gap over the spawn radius, so a player standing near the boundary doesn't flicker the ped in and out every tick
local PED_DISTANCE_CHECK_INTERVAL_MS = 1000

--- @param key string
local function StartLocationWorker(key)
    if WorkerStarted[key] then return end
    WorkerStarted[key] = true

    CreateThread(function()
        while true do
            local loc = ActiveLocations[key]
            if not loc then
                -- Trigger 3 (removal): this location no longer exists (a
                -- tablet "remove", or ActiveLocations was replaced by a
                -- fresher payload that no longer includes this key). Clean
                -- up whatever this thread spawned and stop existing -- a
                -- future re-add gets a brand NEW key (a fresh db:<id>), so
                -- there is no "resurrect this exact worker" path needed.
                DespawnShopPed(key)
                WorkerStarted[key] = nil
                return
            end

            local playerCoords = GetEntityCoords(PlayerPedId())
            local dist = #(playerCoords - vector3(loc.x, loc.y, loc.z))

            if dist <= PED_SPAWN_RADIUS then
                if not SpawnedPeds[key] then
                    SpawnShopPed(key, loc)
                elseif not LocationsEqual(loc, SpawnedLocSnapshot[key]) then
                    -- Trigger 2 (content change): a tablet "move"/edit
                    -- landed while this location's ped was already
                    -- spawned. Respawn fresh rather than trying to
                    -- reposition/re-skin a live entity in place.
                    DespawnShopPed(key)
                    SpawnShopPed(key, loc)
                end
            elseif dist > PED_DESPAWN_RADIUS then
                -- Trigger 1 (distance): nobody is near this shop right now.
                if SpawnedPeds[key] then
                    DespawnShopPed(key)
                end
                -- Give a fresh model-load attempt the next time the player
                -- approaches, in case an operator fixed a bad model/config
                -- value in the meantime -- without this, a single bad
                -- config value would silently and permanently blank this
                -- location for the rest of the session.
                FailedKeys[key] = nil
            end

            Wait(PED_DISTANCE_CHECK_INTERVAL_MS)
        end
    end)
end

--- Starts a worker for every key currently in ActiveLocations that doesn't
--- already have one. Idempotent -- safe to call after every wholesale
--- replacement of ActiveLocations (the initial fetch, and every
--- `equipmentShopLocationsUpdated` broadcast).
local function ReconcileWorkers()
    for key in pairs(ActiveLocations) do
        StartLocationWorker(key)
    end
end

-- ======================================================================
-- LIVE UPDATES FROM THE SERVER -- see this file's header "RUNTIME SHOP
-- LOCATIONS" section.
-- ======================================================================

RegisterNetEvent('john-k9:client:equipmentShopLocationsUpdated', function(locations)
    -- SOURCE-ORIGIN GUARD, same pattern/confidence as every other
    -- server->client event in this resource (see client/main.lua's
    -- playBark handler for the fullest citation of this pattern). Without
    -- this, a locally-forged trigger of this event could hand this file's
    -- own ActiveLocations/worker-thread machinery an arbitrary, attacker-
    -- chosen location table -- not a privilege escalation on its own (it
    -- only affects what THIS client itself renders/targets, and opening
    -- the shop still goes through ox_inventory's own real, unaffected
    -- server-side authorization), but there is no reason to accept it from
    -- anywhere but the real server.
    if source ~= 65535 then return end
    if type(locations) ~= 'table' then return end

    ActiveLocations = locations
    ReconcileWorkers()
end)

-- ======================================================================
-- STARTUP
-- ======================================================================

CreateThread(function()
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end

    local shopConfig = Config.K9EquipmentShop
    if type(shopConfig) ~= 'table' or type(shopConfig.shopType) ~= 'string' or shopConfig.shopType == '' then
        -- server/equipmentshop.lua's own onResourceStart guard already
        -- warns loudly server-side for this exact case -- nothing further
        -- to print here, a silent client-side no-op is correct (this file
        -- has no server console to be seen in anyway).
        return
    end

    ShopType = shopConfig.shopType

    -- Same groups derivation as server/equipmentshop.lua's own copy, over
    -- the same already-existing Config.Departments -- kept as an
    -- independent copy rather than a shared read, since this is a
    -- CLIENT-side visual filter only (see this file's own header) and the
    -- two files have no other call-time dependency on each other.
    if type(Config.Departments) == 'table' then
        ShopGroups = {}
        for jobName in pairs(Config.Departments) do
            ShopGroups[jobName] = 0
        end
        if next(ShopGroups) == nil then ShopGroups = nil end
    end

    -- Fallback-first: build the config-only location set immediately, so
    -- this shop's own built-in locations work even if the server
    -- round-trip below never completes (see this file's header "RUNTIME
    -- SHOP LOCATIONS" section).
    ActiveLocations = BuildConfigOnlyLocations(shopConfig)
    if next(ActiveLocations) == nil then
        print('[John-K9] equipmentshop (client): Config.K9EquipmentShop.locations is missing or empty -- no shop ped can be placed from config.lua alone. A tablet-added (database) location may still be fetched from the server below.')
    end

    local ok, response = pcall(lib.callback.await, 'john-k9:server:equipmentShopGetLocations', K9_CALLBACK_TIMEOUT_MS)
    if ok and type(response) == 'table' and response.ok == true and type(response.locations) == 'table' then
        ActiveLocations = response.locations
    else
        print('[John-K9] equipmentshop (client): could not fetch the server\'s runtime shop location list -- using Config.K9EquipmentShop.locations only for this session. Any tablet-added location is unavailable until this resolves (e.g. after a reconnect).')
    end

    ReconcileWorkers()
end)

-- Resource-restart safety net, same class of fix as client/kennel.lua's/
-- client/movement.lua's own onResourceStop handlers: delete every
-- currently-spawned shop ped BEFORE this resource's own Lua state tears
-- down, so a restart never leaves an orphaned, ownerless entity behind for
-- the next boot's fresh worker threads to duplicate alongside. Snapshots
-- the key list first rather than iterating SpawnedPeds directly while
-- DespawnShopPed mutates it, purely for clarity (Lua's own semantics
-- already permit clearing an existing key mid-`pairs` traversal, but a
-- separate snapshot leaves no doubt for a future reader).
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    local keys = {}
    for key in pairs(SpawnedPeds) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        DespawnShopPed(key)
    end
end)
