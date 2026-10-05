--[[
    john-k9/client/inventory.lua

    DEVELOPER_REFERENCE.md §13.4.2 ("K9 Inventory",
    `Config.Features.K9Inventory`) — see server/inventory.lua's header for
    the full design writeup this file is the client half of (RESOLVED
    accessScope decision, CONFIDENCE NOTEs on every ox_inventory
    export/shape this file's body depends on, the whole validation-order
    discipline). `Config.Features.K9Inventory` stays `false` shipped.

    ======================================================================
    EVENT/CALLBACK CONTRACT — see server/inventory.lua for the full
    'john-k9:server:openK9Inventory' callback contract (THIS FILE is its
    only client-side caller).

    DEVELOPER_REFERENCE.md §13.4.2 describes the ox_target option appearing
    "on the K9 player's own ped," which server/inventory.lua's contract
    supports for BOTH a nearby department officer AND the K9 player
    accessing their own stash (see IsAuthorizedForK9Inventory's `isSelf`
    branch there — confirmed self-access still requires the acting
    player's own HasK9Access, same as every other path into this
    callback). Self-targeting via ox_target is awkward/unusual UX, so
    RequestOpenOwnK9Inventory() below is a dedicated self-service entry
    point — see its own doc comment for the full contract. A future
    client/radial.lua "Open My Gear" item can call it directly without
    reaching into ox_inventory itself, per this file's own established
    "radial calls a global, never the export directly" split.

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls the server's 'john-k9:server:openK9Inventory'
      lib.callback and, via K9Compat.Get('inventory').OpenStash
      (shared/compat/core.lua), whatever the operator's Config.Compat
      resolves for the inventory system (ox_inventory's own
      exports.ox_inventory:openInventory when that is what resolves) — see
      this file's header CONFIDENCE NOTE below for the underlying call's
      verification status.
    - This file's ox_target canInteract predicate below calls
      client/main.lua's resource-global `IsEntityModelK9(entity)`
      (DEVELOPER_REFERENCE.md item 3) rather than keeping its own small local
      copy — client/main.lua is loaded first (fxmanifest.lua's
      client_scripts order) and this call only ever happens at
      canInteract-invocation time (never at this file's own load time), so
      no runtime existence guard is needed, matching client/movement.lua's/
      client/partnership.lua's own established pattern for the same call.
      NOT a security check either way — the server independently
      re-verifies the real model via IsConfiguredK9Model.
    - THIS FILE exposes one resource-global function for a radial entry
      point: `RequestOpenOwnK9Inventory()` — see its own doc comment near
      the bottom of this file. It is the ONLY caller-facing seam into this
      file's request/response + exports.ox_inventory:openInventory
      sequence; a caller (a future client/radial.lua item) never needs its
      own exports.ox_inventory:openInventory call, matching this
      resource's convention (see client/movement.lua's/client/fetch.lua's
      own resource-global exports) that a radial item calls a thin global
      here, never a third-party export directly.
    ======================================================================

    CONFIDENCE NOTE: `exports.ox_inventory:openInventory('stash', stashId)`
    is cited directly by DEVELOPER_REFERENCE.md §13.4.2 as "the standard ox_target +
    ox_inventory pattern" — MEDIUM confidence, not independently
    re-verified against the real ox_inventory source or a live install this
    session (same status server/inventory.lua's header gives RegisterStash).
    Still the exact call `K9Compat.Get('inventory').OpenStash` performs for
    an ox_inventory backend -- see shared/compat/inventory.lua's own
    OpenStash doc comment, which independently re-confirms this shape
    against client/inventory.lua's own pre-existing call.

    COMPAT LAYER: OpenK9InventoryForNetId's call to open the stash UI, and
    its own runtime existence guard, go through `K9Compat.Get('inventory')`/
    `K9Compat.Which('inventory')` (shared/compat/core.lua) instead of
    `exports.ox_inventory:openInventory` directly -- matching this file's
    own target-side option (RegisterK9InventoryOption below), which is
    routed through K9Compat.Get('target') the same way. Never assume "the
    compat layer is already wired everywhere" without checking -- grep for
    `exports.ox_target:`/`exports.ox_inventory:` outside shared/compat/ to
    verify (see DEVELOPER_REFERENCE.md §21's account of that exact false
    assumption recurring). `IsInventoryOpenCapable()` immediately above
    OpenK9InventoryForNetId asks the compat layer's own detection result
    (`K9Compat.Which('inventory') ~= nil`) rather than probing
    `exports.ox_inventory` directly, so this guard -- and its warning --
    are correct for WHATEVER inventory Config.Compat resolved, not only
    ox_inventory. `K9Compat.Get('inventory').OpenStash` is already
    pcall-safe (see that method's own doc comment in
    shared/compat/inventory.lua), so no separate `pcall` is needed here
    wrapping the raw export call -- the safety is already built into what
    `K9Compat.Get` hands back, same as every other consumer in this
    resource.
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
--- Human-readable rejection messages for the openK9Inventory callback's
--- `reason` value. Mirrors server/main.lua's LEASH_REJECT_MESSAGES /
--- server/search.lua's reason-handling shape exactly.
-- NOTE: 'on_cooldown' and 'request_in_progress' are deliberately absent from
-- this table — both are routine, expected traffic (a double-click, a
-- hovering re-trigger), handled as a silent no-op below (never looked up
-- here at all), same treatment DEVELOPER_REFERENCE.md#contraband-search §4's
-- "Rejection UX note" already recommends for search's identical on_cooldown
-- case.
-- Each value below is a distinct locale() call (not a plain string) rather
-- than a table literal, since these must be resolved through ox_lib's
-- locale() at lookup time like every other player-facing string in this
-- resource — see DEVELOPER_REFERENCE.md §19. Kept as six SEPARATE keys (not
-- collapsed into one templated message): each reason is a genuinely
-- different failure cause (disabled feature vs. wrong target vs. no
-- certification vs. too far vs. not authorized vs. a stash-open failure),
-- the same non-collapsing discipline DEVELOPER_REFERENCE.md §19 documents for
-- server/kennel.lua's similarly-shaped NotifyPlayer messages.
local K9_INVENTORY_REASON_MESSAGES = {
    feature_disabled  = locale('inventory.reason_feature_disabled'),
    invalid_target    = locale('inventory.reason_invalid_target'),
    no_access         = locale('inventory.reason_no_access'),
    too_far           = locale('inventory.reason_too_far'),
    not_authorized    = locale('inventory.reason_not_authorized'),
    stash_failed      = locale('inventory.reason_stash_failed'),
}

--- RUNTIME EXISTENCE GUARD for the K9Compat-detected inventory's OpenStash
--- method, called below to actually present the stash UI once the server
--- has granted access. Routed through `K9Compat.Get('inventory')`
--- (shared/compat/core.lua) rather than `exports.ox_inventory:openInventory`
--- directly (see DEVELOPER_REFERENCE.md §21 for the same gap found and
--- fixed identically in client/tablet.lua's useItem call): `K9Compat.Which`
--- returns a non-nil resourceName only when a real, verified adapter is
--- currently active for THIS realm, so this guard -- and its warning below
--- -- are correct for WHATEVER inventory Config.Compat resolved, not only
--- ox_inventory. `K9Compat.Get('inventory')` itself is NEVER nil (see
--- core.lua's own header) so it cannot be used for this existence check on
--- its own -- its no-op stub would silently satisfy a bare
--- `type(...) == 'table'` test.
--- @return boolean
local function IsInventoryOpenCapable()
    return K9Compat.Which('inventory') ~= nil
end

--- Shared "ask the server to open this stash, then open it client-side"
--- implementation — called by both the ox_target `onSelect` below (netId
--- resolved from the interacted ped) and RequestOpenOwnK9Inventory()
--- further down (netId resolved from the local player's own ped). Kept as
--- the ONE place that awaits the callback, interprets its `reason`, and
--- calls exports.ox_inventory:openInventory — so a future reason value, or
--- the ox_inventory open call itself, only needs updating here, and no
--- caller of RequestOpenOwnK9Inventory ever needs its own
--- exports.ox_inventory:openInventory call (this file's header's own
--- "radial calls a global, never the export directly" contract).
--- @param netId number
local function OpenK9InventoryForNetId(netId)
    -- FAIL-CLOSED GUARD: `lib.callback.await` throws rather than returning
    -- nil on a timeout or unregistered-callback rejection (see
    -- client/main.lua's HasK9Access() doc comment for the full ox_lib/
    -- FiveM source citation). pcall it; the `not result` branch immediately
    -- below already covers a pcall-caught nil `result` byte-for-byte the
    -- same as any other falsy response (reason stays nil, so this degrades
    -- to the existing silent-return path rather than aborting uncaught).
    local ok, result = pcall(lib.callback.await, 'john-k9:server:openK9Inventory', K9_CALLBACK_TIMEOUT_MS, netId)
    if not ok then result = nil end

    if not result or not result.ok then
        local reason = result and result.reason
        -- 'on_cooldown'/'request_in_progress' are routine, expected
        -- traffic (a double-click, a hovering re-trigger) — same
        -- silent-no-op treatment DEVELOPER_REFERENCE.md#contraband-search §4's
        -- "Rejection UX note" already recommends for search's
        -- identical on_cooldown case, applied here to this file's
        -- two analogous reasons.
        if reason and reason ~= 'on_cooldown' and reason ~= 'request_in_progress' then
            lib.notify({
                title = locale('common.notify_title'),
                description = K9_INVENTORY_REASON_MESSAGES[reason] or locale('inventory.unable_to_open_generic'),
                type = 'error',
            })
        end
        return
    end

    -- The server has already granted access (EnsureK9Stash succeeded
    -- server-side) by the time we get here — a failure past this point is
    -- purely "could not present the UI client-side," never a
    -- re-litigation of access, so it always gets the same generic
    -- unable-to-open copy rather than any of K9_INVENTORY_REASON_MESSAGES
    -- (those are all server-decision reasons, not applicable here).
    if not IsInventoryOpenCapable() then
        print(('[John-K9] WARNING: server granted K9 stash %s but no usable inventory ' ..
            'adapter is currently detected (Config.Compat) -- the stash UI could not be opened. ' ..
            'Run /k9compat (if enabled) to see why.')
            :format(tostring(result.stashId)))
        lib.notify({
            title = locale('common.notify_title'),
            description = locale('inventory.unable_to_open_generic'),
            type = 'error',
        })
        return
    end

    -- K9Compat.Get('inventory').OpenStash is already pcall-safe (see
    -- shared/compat/inventory.lua's own OpenStash doc comment) and returns
    -- `false` (never throws) if the underlying export call itself fails —
    -- no additional pcall needed here beyond the IsInventoryOpenCapable()
    -- check above, same posture as client/tablet.lua's own UseItem call.
    local openOk = K9Compat.Get('inventory').OpenStash(result.stashId)

    if not openOk then
        lib.notify({
            title = locale('common.notify_title'),
            description = locale('inventory.unable_to_open_generic'),
            type = 'error',
        })
    end
end

--- Register the "Open K9 Gear" ox_target option on nearby player peds whose
--- live model is (plausibly, client-side) a configured K9 model. Display
--- optimization only — server/inventory.lua's openK9Inventory callback
--- independently re-validates feature flag, target model/certification,
--- proximity, and interactor authorization for real; this predicate does
--- not need to be perfect (same posture client/movement.lua's own
--- attachLeash option documents for its analogous canInteract).
---
--- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never
--- a direct `exports.ox_target` call -- canInteract/onSelect below are
--- unchanged (still authored against ox_target's own convention), so an
--- operator running a different supported target script gets this option
--- translated automatically instead of losing it outright.
---
--- LIFECYCLE: extracted into a named function, sole call site the
--- `AddEventHandler('onResourceStart', ...)` below, so this option comes
--- back after a bare restart of whatever resource actually backs the
--- 'target' system and not just after this resource's own restart — see
--- that handler's own doc comment (mirrors server/tracking.lua's
--- RegisterScentInventoryHook / server/inventory.lua's
--- RegisterK9InventoryItemFilterHook fixes for the identical bug class:
--- every supported target script keeps its own registry in a plain
--- file-local Lua table inside its own client chunk, reloaded empty on
--- THAT resource's own restart with nothing else prompting a re-add).
--- DUPLICATE-VS-REPLACE: the option below always sets `name`, and every
--- adapter's own registration primitive dedups/replaces by that same name
--- (or label, per shared/compat/target.lua's own per-adapter notes), so
--- re-running this never duplicates the entry.
local function RegisterK9InventoryOxTargetOption()
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'john-k9:openK9Inventory',
            icon = 'fas fa-briefcase',
            label = locale('inventory.open_gear_target_label'),
            distance = Config.K9Inventory.interactRange,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.K9Inventory then return false end
                if not IsEntityModelK9(entity) then return false end

                -- The K9 player accessing their OWN stash is always authorized
                -- server-side (see server/inventory.lua's
                -- IsAuthorizedForK9Inventory `isSelf` branch) — always show the
                -- option for self, independent of accessScope or job.
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then
                    return true
                end

                -- Otherwise, DISPLAY-ONLY approximation of accessScope: only
                -- show the option to a player whose own job is a configured
                -- department. `accessScope ~= 'department'` is UNREACHABLE
                -- today — server/inventory.lua's onResourceStart assert
                -- hard-enforces accessScope == 'department' (any other value,
                -- including 'ownerOnly', provided no real ox_inventory access
                -- control at all) — kept as defense-in-depth so this UI never
                -- shows a stale/misleading option if that invariant is ever
                -- loosened. QBX.PlayerData is the live-updated client-side job
                -- cache this resource's fxmanifest.lua already documents as
                -- the standard source for this, per
                -- '@qbx_core/modules/playerdata.lua'.
                if Config.K9Inventory.accessScope ~= 'department' then
                    return false
                end

                local job = QBX.PlayerData and QBX.PlayerData.job
                return job ~= nil and Config.Departments[job.name] ~= nil
            end,
            onSelect = function(data)
                local netId = NetworkGetNetworkIdFromEntity(data.entity)
                OpenK9InventoryForNetId(netId)
            end,
        },
    })
end

-- Sole call site for RegisterK9InventoryOxTargetOption(): this resource's
-- own start, or ox_target's own start — mirrors server/tracking.lua's
-- RegisterScentInventoryHook / server/inventory.lua's
-- RegisterK9InventoryItemFilterHook fixes for the identical class of gap
-- against ox_inventory.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterK9InventoryOxTargetOption()
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
        RegisterK9InventoryOxTargetOption()
    end
end)

--- Resource-global — radial self-service entry point (see FILE-TO-FILE
--- CONTRACT above and this file's own header note). Mirrors
--- client/movement.lua's RequestLeashAttach() / client/medkit.lua's
--- RequestTreatNearestK9() shape: re-checks CanShowK9UI() itself rather
--- than trusting that a caller (a future client/radial.lua item) already
--- did, per this codebase's "must not be triggerable by a modified
--- client" spirit — the server re-validates independently regardless
--- (server/inventory.lua's HandleOpenK9Inventory, including its own
--- HasK9Access(targetServerId) check, which for a self-request means
--- `targetServerId == source`, i.e. the requester's OWN certification is
--- what gates this, exactly matching CanShowK9UI()'s own
--- IsOwnModelK9()-and-HasK9Access() gate below rather than being a looser
--- client-side check). This is an INITIATION action (starts an open-stash
--- request against the local player's own ped), not a release/termination
--- one, so — unlike a termination path — it is gated, not exempted, per
--- this resource's established initiation-vs-termination gating split.
--- No nearest-candidate scan needed (unlike RequestTreatNearestK9()): the
--- target is always the local player's own, already-known ped.
function RequestOpenOwnK9Inventory()
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if not Config.Features.K9Inventory then
        lib.notify({
            title = locale('common.notify_title'),
            description = K9_INVENTORY_REASON_MESSAGES.feature_disabled,
            type = 'error',
        })
        return
    end

    local netId = NetworkGetNetworkIdFromEntity(PlayerPedId())
    OpenK9InventoryForNetId(netId)
end

-- ======================================================================
-- CHAT COMMAND -- Open My Gear (menu-parity pass: "chat commands, 3rd eye,
-- and radial menus" -- every feature reachable from all three). Before this
-- pass, a K9 player's own gear stash was reachable ONLY via the "Open K9
-- Gear" ox_target option on one's own ped (awkward self-targeting UX, per
-- this file's own header) and client/radial.lua's own 'k9_open_inventory'
-- Utility item -- no chat command existed.
--
-- A single one-shot action, not a toggle -- RequestOpenOwnK9Inventory()
-- opens the same stash UI every time it succeeds; there is no "close" half
-- to resolve, so there is no context to dispatch on. This command therefore
-- adds NO pre-check of its own: RequestOpenOwnK9Inventory() already performs
-- its own real CanShowK9UI() gate internally (see its own doc comment a few
-- lines above) -- adding a second copy of that same check here would only
-- be a redundant permission check this pass was told to avoid writing, not
-- a safety improvement, and this command reaches the exact same
-- resource-global client/radial.lua's own item already calls.
-- ======================================================================
RegisterCommand('k9gear', function()
    RequestOpenOwnK9Inventory()
end, false)
