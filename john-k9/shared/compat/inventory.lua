--[[
    shared/compat/inventory.lua

    INVENTORY adapters for the resource-compatibility layer described in
    config.lua's `Config.Compat` block (read in full before touching this
    file -- it is the contract, and it is written for a non-technical
    owner, so every promise made there constrains what this file may do).
    Registers against shared/compat/core.lua's detection engine via:

        K9Compat.RegisterAdapter('inventory', '<resourceName>', factory)
        -- factory(realm) -> table | nil ; nil = present but unusable, skip me

    THIS FILE IS A SHARED SCRIPT (loaded once in the client Lua VM, once in
    the server Lua VM -- two entirely separate processes/states, per FXServer
    architecture). Every `K9Compat.RegisterAdapter(...)` call below therefore
    runs in BOTH realms; `factory(realm)` is what tells a single registered
    factory function which half to build, and it is written to be safe to
    call in the "wrong" realm too (every capability probe below fails
    closed to `false`/`nil` rather than erroring, regardless of which VM it
    runs in -- see IsResourceExportCapable's own doc comment).

    ======================================================================
    ADDENDUM: SERVER-REALM `ItemExists` ADDED TO THE CONTRACT.

    `K9Compat.RequiredMethods.inventory.server` used to stop at seven names
    (`ItemExists` was CLIENT-only). Two independent server files each
    already found and documented the resulting gap on their own, under the
    same "COMPAT-LAYER FINDING, DELIBERATELY NOT ROUTED" heading, and
    reported it here rather than working around it themselves (their own
    words: "if a call site has no clean accessor, that is a finding, not a
    licence to improvise"):
      - server/equipmentshop.lua's `WarnIfItemMissing` (its own onResourceStart
        sanity check for every configured K9 Supply shop item name)
      - server/wellbeing.lua's `WarnIfItemMissing` (the same check for
        Config.K9Medkit.itemName / Config.Wellbeing.Mood.feedItemName)
    Both stayed hardwired to a direct `exports.ox_inventory:Items(itemName)`
    pcall, unable to route through `K9Compat.Get('inventory')` at all,
    because the accessor this section now adds did not exist yet.

    THE CONTRACT CHANGE ADDS A REQUIRED METHOD, WHICH IS NOT FREE -- every
    registered adapter that returns a non-nil table for `realm == 'server'`
    MUST now expose a callable `ItemExists`, or `VerifyMethods` in core.lua
    rejects that WHOLE table (all eight methods lost, not just the missing
    one) -- this is exactly the "adding one means every adapter must
    implement it or be skipped" risk the two finding comments above named
    explicitly as the reason they did not make this change unilaterally.
    Resolved here, per adapter, rather than left open:
      - `ox_inventory` (BuildOxInventoryServer, below): CONFIRMED, for free --
        the CLIENT realm's own `ItemExists` already established that
        `Items` is registered identically on both realms (this file's own
        BuildOxInventoryClient comment, unchanged); the server implementation
        below is the byte-for-byte same body against the same export.
      - `qb-inventory` (BuildQbInventoryServer, below): NOT a new guess --
        this file's own qb-inventory section header already establishes,
        from a complete read of its server-side source, that no confirmed
        item-catalog-lookup export exists (`QBCore.Shared.Items` is a
        plausible client-side answer but reaching into a SPECIFIC
        framework's global from the inventory adapter is the exact coupling
        this file's header already forbids). Implemented as a disclosed,
        honest placeholder that always answers `true` ("assume present,
        cannot verify on this backend") rather than inventing an export --
        see that factory's own doc comment for why `true`, not `false`, is
        the correct direction for an UNVERIFIABLE answer to a existence
        check whose only current real consumer is an operator-facing
        "did you typo this item name" WARNING: an unverifiable `false` would
        read as "this item is missing" for an item that may well exist,
        actively misleading an operator into "fixing" something that was
        never broken; an unverifiable `true` reproduces today's status quo
        for every non-ox_inventory backend (no warning fires) rather than
        inventing a new false alarm.
      - The six UNCONFIRMED candidates (qs-inventory, ps-inventory,
        origen_inventory, codem-inventory, core_inventory, tgiann-inventory)
        need no change at all: every one of their factories already returns
        `nil` unconditionally for both realms, so `VerifyMethods` is never
        even reached for them.

    NOT DONE BY THIS ADDENDUM: the two real call sites
    (server/equipmentshop.lua, server/wellbeing.lua) still make their own
    direct `exports.ox_inventory:Items(...)` call today -- this addendum
    only makes the accessor they were asking for exist. Routing those two
    call sites onto `K9Compat.Get('inventory').ItemExists(itemName)` is a
    small, mechanical follow-up that has not been done here.

    ======================================================================
    RESEARCH DISCIPLINE: every signature below is either CONFIRMED against
    a primary source fetched and read directly this session (cited inline,
    with the exact file/function), or marked UNCONFIRMED and made to return
    `nil` from its factory rather than ship a guess. "A guessed signature is
    worse than no adapter: it detects as working and then silently does
    nothing" -- this file follows that rule even where it costs real
    coverage (see ps-inventory below, a real, found, actively-maintained
    project that still gets skipped because three of the required server
    methods -- seven at the time this was researched, now eight -- have no
    confirmed equivalent in its source).

    CONFIRMATION LEDGER, one line per candidate, fullest detail in each
    adapter's own section below:
      ox_inventory      CONFIRMED  (overextended/ox_inventory, branch `main`,
                                     fxmanifest.lua version '2.47.9' at fetch
                                     time -- fetched and read directly this
                                     session: server.lua, client.lua,
                                     modules/inventory/server.lua,
                                     modules/hooks/server.lua,
                                     modules/shops/server.lua,
                                     modules/items/server.lua)
      qb-inventory      CONFIRMED  (qbcore-framework/qb-inventory, branch
                                     `main`, fxmanifest.lua version '2.1.0' --
                                     fetched and read directly this session:
                                     server/main.lua, server/functions.lua,
                                     server/commands.lua, server/hooks.lua --
                                     ALL FOUR of that project's declared
                                     server_scripts (fxmanifest.lua's own
                                     `server_scripts` block confirmed to list
                                     exactly these four; an EARLIER revision
                                     of this ledger entry miscounted this as
                                     "server/main.lua, server/functions.lua,
                                     server/hooks.lua, client/main.lua" --
                                     THREE server files plus one client file
                                     passed off as "all four server_scripts",
                                     which silently skipped the real fourth
                                     one, server/commands.lua, and never
                                     actually re-derived from the manifest --
                                     corrected here after re-fetching and
                                     reading fxmanifest.lua directly; a
                                     re-read of the now-actually-complete set
                                     found nothing in server/commands.lua
                                     bearing on any claim already made below).
                                     client/main.lua, client/drops.lua, and
                                     client/vehicles.lua (all three of that
                                     project's declared client_scripts) were
                                     also fetched and read this session --
                                     client/vehicles.lua's own
                                     `qb-inventory:client:vehicleCheck`
                                     callback is what CONFIRMS the real
                                     vehicle-trunk/glovebox inventory id
                                     format used below (`'trunk-' .. plate`,
                                     `'glovebox-' .. plate`), and
                                     server/main.lua's own startup
                                     `SELECT * FROM inventories` plus
                                     server/functions.lua's `GetInventory`/
                                     `InitializeInventory` confirm those ids
                                     are plain scalar keys with no netid-based
                                     lazy-vivify mechanism. So absence claims
                                     below ("no container concept",
                                     "ItemDropped hook type is declared but
                                     never fired") are a completeness claim
                                     over its real, whole server-side source,
                                     not a sampling guess.)
      ps-inventory      FOUND, BUT SKIPPED -- see its own section below.
                                     (Project-Sloth/ps-inventory, branch
                                     `main` -- fetched and read
                                     server/main.lua + client/main.lua this
                                     session; 3 of the (then-7, now 8 --
                                     ItemExists was added after this ledger
                                     was first written and was not
                                     separately re-checked against this
                                     candidate) required server methods
                                     have no confirmed equivalent)
      qs-inventory      UNCONFIRMED -- no public source repository located
                                     this session (see "UNCONFIRMED
                                     CANDIDATES" section below for the search
                                     effort actually made).
      origen_inventory  UNCONFIRMED -- same as above.
      codem-inventory   UNCONFIRMED -- same as above.
      core_inventory    UNCONFIRMED -- same as above.
      tgiann-inventory  UNCONFIRMED -- same as above.

    ======================================================================
    THE `RegisterHook` VOCABULARY -- READ THIS BEFORE ADDING A THIRD EVENT
    OR WIRING A NEW CALLER.

    DEVELOPER_REFERENCE.md §21 (the cross-adapter contract doc, owned by
    shared/compat/core.lua's author) is explicit that parameter/payload
    shapes are NOT defined by core.lua -- "match the calling convention of
    the reference resource this pack was built against for that system
    (ox_inventory for inventory ...), since that's what every OTHER adapter
    for the same system needs to stay interchangeable with." An EARLIER
    revision of this file invented its own small abstract vocabulary
    ('itemEnteredInventory'/'itemDropped') instead -- reconciled here, after
    that README was read in full, to follow the stated convention instead:
    `eventName` is ox_inventory's OWN real event-name string (whatever its
    real `registerHook` accepts -- 'swapItems', 'buyItem', 'useItem',
    'createItem', ...), and the payload handed to `callback` matches
    ox_inventory's OWN real 'swapItems' field names (`source`,
    `fromInventory`, `fromSlot`, `toInventory`, `toType`), not a
    reinvented shape. This makes the ox_inventory adapter's own RegisterHook
    a PURE, fully generic pass-through (see BuildOxInventoryServer below --
    genuinely simpler AND more faithful than the abstracted version), and
    makes every OTHER adapter responsible for translating its own real
    hook mechanism INTO that same vocabulary, on a best-effort,
    only-what's-confirmed basis.

    THE ONLY EVENT NAME THIS FILE TRANSLATES FOR A NON-ox_inventory BACKEND
    is `'swapItems'` -- the one this resource's two REAL current consumers
    (server/inventory.lua's Config.K9Inventory.allowedItems veto,
    server/tracking.lua's ScentTracking drop-source log) actually need.
    Passing any OTHER event name to a non-ox_inventory adapter's
    RegisterHook returns `false` immediately, without probing or
    registering anything -- there is no confirmed mapping for
    'buyItem'/'useItem'/'createItem'/etc. on any other backend, and
    guessing one is exactly what this task's research discipline forbids.

    For 'swapItems' specifically, on qb-inventory (the one other CONFIRMED
    adapter): BOTH halves of ox_inventory's real 'swapItems' semantics are
    now reproduced, each via its own separate real qb-inventory hook. The
    "an item is being committed INTO a named inventory, reject with the
    literal false to veto" half is the real, confirmed `AddHook('ItemAdded',
    ...)` veto point -- covers Config.K9Inventory.allowedItems for real. The
    "item dropped to the ground" half (`payload.toType == 'drop'`,
    ScentTracking's actual usage) is ALSO now a CONFIRMED, real translation
    (corrected here -- an EARLIER revision of this paragraph recorded it as
    a permanent no-op, based on a claim that no call site ever fires
    `Events.ItemDropped`; re-fetching and re-reading qb-inventory's `main`
    branch directly this session found the real, current call site that
    earlier revision missed: server/main.lua's own
    `qb-inventory:server:createDrop` callback runs
    `TriggerHook('ItemDropped', hookData.item.type, hookData)` on every
    ground drop, with a payload -- `{ source, sourceInventory, coords, item,
    amount }`, `server/hooks.lua`'s `buildItemDroppedData` -- that supplies
    exactly what ScentTracking needs. See BuildQbInventoryServer's own
    RegisterHook doc comment, below, for the full citation and the exact
    translation). A caller registering for 'swapItems' on a qb-inventory
    backend now gets a real veto AND a real `payload.toType == 'drop'` event
    -- never faked, and no longer a silent gap either.

    ======================================================================
    SECURITY NOTE -- READ BEFORE WIRING RegisterStash's `groups` ARGUMENT
    TO ANY AUTHORIZATION DECISION. Per config.lua's own Config.Compat header
    and this task's own instruction, an inventory adapter must NEVER be the
    thing that grants permission -- and the way that promise actually holds
    differs by backend, not just in degree:

      - ox_inventory's `groups` argument to RegisterStash is a REAL,
        server-enforced ACL (`server.hasGroup`, confirmed against
        modules/inventory/server.lua this session -- same finding
        server/inventory.lua's own header already recorded for this exact
        export). It matters because ox_inventory's `openInventory` is a
        CLIENT export: a modified client can call
        `exports.ox_inventory:openInventory('stash', '<anyId>')` directly,
        bypassing this resource's own request/response callback entirely,
        so ox_inventory's OWN groups check is the last real backstop against
        that specific bypass.
      - qb-inventory (and, per its own header, ps-inventory) has NO
        equivalent per-inventory ACL concept at all -- `OpenInventory`/
        `OpenShop` are SERVER-side exports that take `source` and push a
        client event; there is no client-callable "open this identifier"
        primitive for a hostile client to call directly in the first place
        (a resource's server-side Lua exports are not reachable from a
        client at all). This adapter's qb-inventory `RegisterStash` accepts
        a `groups` argument for interface symmetry but CANNOT enforce it
        (documented per-call below) -- and, unlike ox_inventory, does not
        need to: the real boundary for a qb-inventory-backed stash is
        whatever THIS resource's own server code already checks before
        ever calling `OpenStash`/before handing an id to a client at all,
        which every caller in this codebase already does independently of
        this compat layer (see server/inventory.lua's own
        HandleOpenK9Inventory for the existing precedent). A caller must
        NEVER treat this adapter's RegisterStash `groups`/`owner` argument
        as a real access boundary on a non-ox_inventory backend -- only as
        a label ox_inventory happens to enforce for itself.

    Every rank/certification/ownership check this resource makes stays
    server-side, in this resource's OWN code, independent of which
    inventory was detected -- this file only ever executes what it is told,
    never decides who is allowed to ask.

    ======================================================================
    NEVER LET A THIRD-PARTY EXPORT THROW. Every export ACCESS and every
    export CALL below goes through the same two/three-step shape this
    codebase already established (the now-deleted IsOxInventoryHookCapable in server/tracking.lua,
    and server/inventory.lua's identical local copy -- both since deleted,
    their job now done by this layer's own IsExportCapable):
    `GetResourceState(name) == 'started'` checked FIRST and unconditionally
    (accessing `exports.<name>` at all on a non-started resource can itself
    throw), THEN a pcall'd export INDEX (proves the name resolves to a
    callable without performing the resource's own side effect), THEN,
    separately, a pcall'd export CALL (existence is not proof a specific
    call cannot still throw for some other reason -- a bad argument, an
    internal error in the other resource). See IsResourceExportCapable and
    SafeExportCall below -- every adapter method in this file is built on
    exactly those two helpers, never a naked `exports.x:y(...)` call.
]]

if type(K9Compat) ~= 'table' or type(K9Compat.RegisterAdapter) ~= 'function' then
    print('[John-K9] shared/compat/inventory.lua: WARNING: K9Compat is not available -- ' ..
        'shared/compat/core.lua is missing, failed to load, or is ordered AFTER this file in ' ..
        "fxmanifest.lua's shared_scripts block. No inventory adapters were registered this " ..
        'session; Config.Features.ResourceAutoDetect will find nothing for the inventory system ' ..
        'no matter what is actually running. Fix the load order (core.lua must come first) and ' ..
        'restart.')
    return
end

-- ======================================================================
-- SHARED HELPERS -- every adapter method in this file is built from these
-- two. Neither ever throws, by construction (pcall is the outermost thing
-- either function does), regardless of realm, resource state, or what the
-- target resource's own export body does.
-- ======================================================================

--- Capability probe: does `resourceName` currently expose a callable export
--- named `exportName`, IN THIS REALM (the exports table a client-side chunk
--- sees is a different, independent registry from what a server-side chunk
--- of the SAME shared script sees -- a client-only export like
--- ox_inventory's `openInventory` will correctly probe as absent when this
--- function runs in the server VM, and vice versa for a server-only export
--- like `RegisterStash`; no explicit realm check is needed here for that
--- reason, only for deciding WHICH probes are worth making at all).
--- @param resourceName string
--- @param exportName string
--- @return boolean
local function IsResourceExportCapable(resourceName, exportName)
    if GetResourceState(resourceName) ~= 'started' then
        return false
    end

    local ok, exportFn = pcall(function() return exports[resourceName][exportName] end)
    return ok and type(exportFn) == 'function'
end

--- pcall's an ALREADY CAPABILITY-CONFIRMED (IsResourceExportCapable already
--- returned true for this resourceName/exportName pair) export call, using
--- the same `proxy[exportName](proxy, ...)` shape `exports.res:method(...)`
--- colon-call syntax compiles to -- matching this codebase's own existing
--- call sites exactly (they always re-access via colon syntax for the real
--- call rather than reusing a captured dot-accessed reference; mirrored
--- here rather than assumed equivalent).
--- @param resourceName string
--- @param exportName string
--- @return boolean callOk, any ... -- callOk is `false` (no further values) if the call itself threw
local function SafeExportCall(resourceName, exportName, ...)
    local args = table.pack(...)
    -- `exports[resourceName]` is indexed INSIDE this same pcall, not before
    -- it: IsResourceExportCapable already confirmed capability at some
    -- earlier point, but that is not a guarantee the resource is STILL
    -- started by the time this specific call happens (an operator can
    -- restart the target resource in the gap between the two, and merely
    -- indexing `exports.<name>` on a non-started resource can itself throw
    -- -- see this file's header). Both the index and the call must fail
    -- into the same pcall.
    return pcall(function()
        local proxy = exports[resourceName]
        return proxy[exportName](proxy, table.unpack(args, 1, args.n))
    end)
end

-- Per-(resourceName) de-duplication for the "this candidate is a found but
-- unconfirmed/unusable resource" console warning below -- printed at most
-- once per realm per server session, not once per detection/redetect pass
-- (Config.Compat.redetectOnResourceRestart can call every factory again on
-- an unrelated resource restart; re-printing the same paragraph every time
-- would bury the one-line summary this whole layer promises the owner).
local WarnedUnconfirmed = {}

-- Prints, at most once per server session (never per RegisterHook call --
-- this could otherwise fire once per caller, e.g. once for
-- server/inventory.lua's allowedItems veto and once for
-- server/tracking.lua's ScentTracking hook), the qb-inventory-specific
-- warning for the rare case where the 'ItemAdded' half of 'swapItems'
-- registered successfully but the separate 'ItemDropped' half did not --
-- see BuildQbInventoryServer's own RegisterHook doc comment for the full
-- writeup of why these are two independent registrations on this backend.
local QbInventoryDropHookWarned = false

--- @param resourceName string
--- @param reasonNote string
local function WarnUnconfirmedOnce(resourceName, reasonNote)
    if WarnedUnconfirmed[resourceName] then return end
    WarnedUnconfirmed[resourceName] = true
    print(('[John-K9] shared/compat/inventory.lua: %s is not a confirmed inventory adapter -- %s ' ..
        'Skipped by design (factory returns nil), never guessed. If you run this inventory and can ' ..
        'point a maintainer at its real, current exports source, this adapter can be completed.')
        :format(resourceName, reasonNote))
end

-- ======================================================================
-- ox_inventory -- CONFIRMED. The reference this resource was built
-- against (fxmanifest.lua hard `dependencies` entry) and the only
-- candidate with every one of the twelve required methods (4 client + 8
-- server, since server-realm ItemExists was later added) backed by a
-- real, cited export.
-- ======================================================================

--- @return table|nil
local function BuildOxInventoryClient()
    if not IsResourceExportCapable('ox_inventory', 'openInventory') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'useItem') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'Items') then return nil end

    return {
        --- Mirrors client/inventory.lua's own existing, already-shipped
        --- `exports.ox_inventory:openInventory('stash', stashId)` call
        --- (client.lua's `exports('openInventory', client.openInventory)`,
        --- confirmed this session) byte-for-byte.
        --- @param stashId string|number
        --- @return boolean attempted
        OpenStash = function(stashId)
            if type(stashId) ~= 'string' and type(stashId) ~= 'number' then return false end
            local callOk = SafeExportCall('ox_inventory', 'openInventory', 'stash', stashId)
            return callOk
        end,

        --- Mirrors client/equipmentshop.lua's own existing
        --- `exports.ox_inventory:openInventory('shop', { type = shopType })`
        --- call.
        --- @param shopType string
        --- @return boolean attempted
        OpenShop = function(shopType)
            if type(shopType) ~= 'string' or shopType == '' then return false end
            local callOk = SafeExportCall('ox_inventory', 'openInventory', 'shop', { type = shopType })
            return callOk
        end,

        --- Mirrors client/tablet.lua's own existing
        --- `exports.ox_inventory:useItem(data, function(approved) ... end)`
        --- call. FAIL CLOSED, NO UNBOUNDED TRAP: `cb` is guaranteed to be
        --- invoked exactly once, synchronously with `false`, if the export
        --- call itself cannot even be attempted or throws -- a caller that
        --- awaits this callback (e.g. via a promise) must never hang
        --- forever waiting for a response ox_inventory was never going to
        --- send.
        --- @param data table
        --- @param cb fun(approved: boolean)
        UseItem = function(data, cb)
            local callOk = SafeExportCall('ox_inventory', 'useItem', data, cb)
            if not callOk and type(cb) == 'function' then
                pcall(cb, false)
            end
            return callOk
        end,

        --- Mirrors server/equipmentshop.lua's/server/wellbeing.lua's own
        --- existing `exports.ox_inventory:Items(itemName)` truthy check.
        --- ox_inventory's `Items` export is registered identically on
        --- both realms (modules/items/server.lua's `exports('Items', ...)`
        --- has a client-side counterpart of the same name/shape, confirmed
        --- via client/tablet.lua's own header citing
        --- `exports.ox_inventory:Items()` as a real, existing client call).
        --- @param itemName string
        --- @return boolean
        ItemExists = function(itemName)
            if type(itemName) ~= 'string' or itemName == '' then return false end
            local callOk, item = SafeExportCall('ox_inventory', 'Items', itemName)
            return callOk and item ~= nil
        end,
    }
end

--- @return table|nil
local function BuildOxInventoryServer()
    if not IsResourceExportCapable('ox_inventory', 'GetInventoryItems') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'GetContainerFromSlot') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'GetItemCount') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'RemoveItem') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'RegisterStash') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'RegisterShop') then return nil end
    if not IsResourceExportCapable('ox_inventory', 'registerHook') then return nil end
    -- DELIBERATELY NOT GATED ON 'Items' HERE, unlike the other seven: doing
    -- so would mean an ox_inventory install (or, just as importantly, a
    -- TEST FIXTURE in this resource's own suite) that is missing/hasn't
    -- stubbed only THIS ONE export loses ALL EIGHT capabilities at once --
    -- exactly the "adding one means every adapter must implement it or be
    -- skipped" risk this file's header ADDENDUM names explicitly. ItemExists
    -- below checks its own capability at call time via SafeExportCall
    -- (which already fails closed to `callOk = false` -- and therefore
    -- `false` -- when the export is absent), the same "no top-level gate,
    -- self-contained fail-closed body" pattern BuildQbInventoryServer's own
    -- GetContainerFromSlot already uses for a confirmed-absent capability.

    return {
        --- PASS-THROUGH, NATIVE SHAPE -- see this file's header on why
        --- item-slot shapes are never normalized across backends.
        --- Confirmed signature (modules/inventory/server.lua):
        --- `exports('GetInventoryItems', function(inv, owner) ... end)`,
        --- forwarding `inv` unchanged to `Inventory(inv)` -- this is what
        --- makes server/search.lua's existing `{ id = inventoryId, netid =
        --- targetNetId }` table-shaped `inv` argument (for an uncached
        --- vehicle trunk) work at all; preserved here unmodified.
        --- @param inv string|number|table
        --- @param owner string|number|nil
        --- @return table|nil items -- ox_inventory's own per-slot item array, or nil on failure/uncapable
        GetInventoryItems = function(inv, owner)
            local callOk, items = SafeExportCall('ox_inventory', 'GetInventoryItems', inv, owner)
            if not callOk then return nil end
            return items
        end,

        --- PASS-THROUGH, NATIVE SHAPE. Confirmed
        --- (`Inventory.GetContainerFromSlot(inv, slotId)`, exported
        --- verbatim as `GetContainerFromSlot`).
        --- @param inv string|number
        --- @param slotId number
        --- @return table|nil container
        GetContainerFromSlot = function(inv, slotId)
            local callOk, container = SafeExportCall('ox_inventory', 'GetContainerFromSlot', inv, slotId)
            if not callOk then return nil end
            return container
        end,

        --- Confirmed (`Inventory.GetItemCount(inv, itemName, metadata,
        --- strict)`, exported verbatim). FAILS CLOSED to `0` on any
        --- capability/call failure -- "possession assumed zero" already
        --- matches this codebase's own established convention for a
        --- missing/erroring item read (server/medkit.lua's own header:
        --- "unregistered, GetItemCount resolves 0 forever").
        --- @param inv string|number
        --- @param itemName string
        --- @param metadata table|nil
        --- @param strict boolean|nil
        --- @return number count
        GetItemCount = function(inv, itemName, metadata, strict)
            local callOk, count = SafeExportCall('ox_inventory', 'GetItemCount', inv, itemName, metadata, strict)
            if not callOk or type(count) ~= 'number' then return 0 end
            return count
        end,

        --- Confirmed (`Inventory.RemoveItem(inv, item, count, metadata,
        --- slot, ignoreTotal, strict)` -> `boolean, string?`, exported
        --- verbatim). Returns `false` (never a fabricated `true`) on any
        --- capability/call failure -- a removal this adapter cannot prove
        --- happened must never be reported as having happened.
        --- @return boolean success, string? reason
        RemoveItem = function(inv, item, count, metadata, slot, ignoreTotal, strict)
            local callOk, success, reason = SafeExportCall('ox_inventory', 'RemoveItem', inv, item, count, metadata, slot, ignoreTotal, strict)
            if not callOk then return false, 'compat_call_failed' end
            return success == true, reason
        end,

        --- Confirmed (`local function registerStash(name, label, slots,
        --- maxWeight, owner, groups, coords, instance)`, exported verbatim
        --- as `RegisterStash`). See this file's header SECURITY NOTE:
        --- `groups` IS a real, server-enforced ACL for this backend
        --- specifically.
        --- @return boolean success
        RegisterStash = function(id, label, slots, maxWeight, owner, groups, coords, instance)
            local callOk = SafeExportCall('ox_inventory', 'RegisterStash', id, label, slots, maxWeight, owner, groups, coords, instance)
            return callOk
        end,

        --- Confirmed (`exports('RegisterShop', function(shopType,
        --- shopDetails) ... end)`, modules/shops/server.lua). This
        --- adapter's OWN `shopDetails` shape (`{ label, items, groups }`,
        --- documented in this file's header) is translated here to
        --- ox_inventory's real expected shape (`{ name, inventory,
        --- groups }`) -- `items[n] = { name, price, currency? }` maps
        --- 1:1 onto ox_inventory's own confirmed `shopDetails.inventory`
        --- shape, no translation needed for the entries themselves.
        --- @param shopType string
        --- @param shopDetails table -- { label: string, items: {name,price,currency?}[], groups: table<string,number>? }
        --- @return boolean success
        RegisterShop = function(shopType, shopDetails)
            if type(shopDetails) ~= 'table' or type(shopDetails.items) ~= 'table' then return false end
            local callOk = SafeExportCall('ox_inventory', 'RegisterShop', shopType, {
                name = shopDetails.label,
                inventory = shopDetails.items,
                groups = shopDetails.groups,
            })
            return callOk
        end,

        --- See this file's header "THE RegisterHook VOCABULARY" section in
        --- full before changing anything below. Per shared/compat/
        --- README.md's own stated convention ("match the calling
        --- convention of the reference resource"), THIS adapter's
        --- RegisterHook is a PURE, fully generic pass-through onto
        --- ox_inventory's own real `registerHook(event, callback)` -- no
        --- restriction to a fixed event list, no payload translation: since
        --- ox_inventory IS the reference resource for this system, `eventName`
        --- and the `payload` handed to `callback` are exactly whatever
        --- ox_inventory's own real event fires ('swapItems', 'buyItem',
        --- 'useItem', 'createItem', ...), unmodified.
        ---
        --- RESOLVED 2026-08-25 -- this note used to disclose an unresolved
        --- worry, and the worry was wrong. It is kept, rather than deleted,
        --- because the reason it was wrong is a trap anyone reading this
        --- file could fall into next.
        ---
        --- The worry: ox_inventory's current `main` shows
        --- `exports('registerHook', function(event, ref, options) ...
        --- ref.resource = resource ... end)`, assigning a FIELD onto `ref`
        --- unconditionally. Tested in a standalone lua5.4 interpreter that
        --- throws "attempt to index a function value" for a plain closure --
        --- which is exactly the convention this resource uses everywhere.
        ---
        --- Why it does not throw in reality: a standalone interpreter is the
        --- wrong test bench. Confirmed against CitizenFX's own runtime
        --- (data/shared/citizen/scripting/lua/scheduler.lua), any Lua
        --- function crossing a resource-export boundary is msgpack-packed as
        --- EXT_FUNCREF and arrives on the far side as a callable TABLE with a
        --- `funcref_mt` metatable -- never as a raw function value. This
        --- happens even between two server-side resources in one FXServer
        --- process, because `exports.x:y(...)` is not a same-VM call. So by
        --- the time `registerHook`'s body runs, `ref` is a table,
        --- `ref.resource = resource` is an ordinary field write, and calling
        --- it still works through `__call`.
        ---
        --- The plain-function convention is therefore correct, and is the
        --- only one that has ever worked -- by design of the runtime, not in
        --- spite of it. server/tracking.lua and server/inventory.lua need no
        --- change. SafeExportCall's pcall stays as ordinary defence in
        --- depth; it is simply no longer guarding a real threat.
        ---
        --- THE TRANSFERABLE LESSON: reading a dependency's source in
        --- isolation tells you what the code says, not what the runtime
        --- does to its arguments before it gets there. When a read suggests
        --- that the entire ecosystem's documented convention is broken, the
        --- convention is rarely what is wrong.
        ---
        --- @param eventName string -- any real ox_inventory registerHook event name, e.g. 'swapItems'
        --- @param callback fun(payload: table): boolean|nil
        --- @return boolean success
        RegisterHook = function(eventName, callback)
            if type(eventName) ~= 'string' or eventName == '' then return false end
            if type(callback) ~= 'function' then return false end

            local callOk = SafeExportCall('ox_inventory', 'registerHook', eventName, function(payload)
                local vetoOk, veto = pcall(callback, payload)
                if vetoOk and veto == false then return false end
            end)
            if not callOk then
                print(('[John-K9] shared/compat/inventory.lua: ox_inventory RegisterHook(%q) failed -- ' ..
                    'registerHook threw (see this method\'s own doc comment for the confirmed-vs-live discrepancy ' ..
                    'this may indicate). Whatever this hook was meant to enforce/observe is NOT active this session.')
                    :format(eventName))
            end
            return callOk
        end,

        --- ADDED: see this file's header ADDENDUM for the full "why now"
        --- writeup. CONFIRMED, for free: identical body to
        --- BuildOxInventoryClient's own `ItemExists` above, against the
        --- SAME `Items` export -- that factory's own doc comment already
        --- establishes `Items` is registered identically on both realms, so
        --- no new research was needed to add this half.
        --- @param itemName string
        --- @return boolean
        ItemExists = function(itemName)
            if type(itemName) ~= 'string' or itemName == '' then return false end
            local callOk, item = SafeExportCall('ox_inventory', 'Items', itemName)
            return callOk and item ~= nil
        end,
    }
end

K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(realm)
    if realm == 'client' then return BuildOxInventoryClient() end
    if realm == 'server' then return BuildOxInventoryServer() end
    return nil
end)

-- ======================================================================
-- qs-inventory -- UNCONFIRMED. No public source repository located this
-- session (guessed likely owners/branches tried against
-- raw.githubusercontent.com and returned 404 for every one; this appears
-- to be a closed-source/marketplace-distributed script with no primary
-- source this session could read). Returning nil unconditionally rather
-- than shipping a signature this session never saw.
-- ======================================================================
K9Compat.RegisterAdapter('inventory', 'qs-inventory', function(_realm)
    WarnUnconfirmedOnce('qs-inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)

-- ======================================================================
-- qb-inventory -- CONFIRMED for a real subset of both realms; several
-- methods are DELIBERATE, DISCLOSED NO-OPS for a capability this backend's
-- own, complete server-side source (server/main.lua, server/functions.lua,
-- server/commands.lua, server/hooks.lua -- ALL FOUR of its declared
-- server_scripts, per fxmanifest.lua -- see this file's own CONFIRMATION
-- LEDGER at the top of the file for the correction to an earlier
-- three-server-plus-one-client miscount) confirms it genuinely does not
-- have, never a guess standing in for one.
--
-- CLIENT REALM: returns nil. qb-inventory's own architecture is
-- fundamentally SERVER-INITIATED, not client-callable, for every one of
-- the four required client methods -- confirmed by reading its complete
-- client/main.lua and server source this session:
--   * `OpenInventory(source, identifier, data)` / `OpenShop(source, name)`
--     are SERVER-side exports (both take `source` as their first
--     parameter) that internally `TriggerClientEvent(...)` -- there is no
--     client-side "ask to open this identifier" export at all for this
--     adapter to wrap.
--   * `UseItem(itemName, source, item, ...)` (server/functions.lua) is
--     likewise a SERVER export; client/main.lua's own item-use path is a
--     `RegisterNUICallback`/`TriggerServerEvent('qb-inventory:server:
--     useItem', ...)` pair, never a client-callable function returning an
--     approved/denied result the way ox_inventory's `useItem` does.
--   * `ItemExists` has no confirmed qb-inventory EXPORT on either realm at
--     all -- `QBCore.Shared.Items[name]` is a real, plausible client-side
--     answer, but reaching into a SPECIFIC framework's global from the
--     INVENTORY adapter would silently couple this adapter to one
--     particular Config.Compat `framework` choice, which this compat
--     layer's own system-independence (config.lua's own "systems ...
--     independently pluggable" design) says an inventory adapter must not
--     do. Disclosed here as a known, deliberate gap rather than a missed
--     shortcut.
-- A caller depending on K9Compat's inventory client adapter (opening a K9
-- stash/shop from ox_target, the tablet item flow) gets a clean "no client
-- inventory adapter available" no-op on a qb-inventory server -- the
-- documented consequence of an architectural mismatch, not a bug in this
-- file.
-- ======================================================================

--- @return table|nil
local function BuildQbInventoryServer()
    if not IsResourceExportCapable('qb-inventory', 'GetInventory') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'GetItemCount') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'RemoveItem') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'CreateInventory') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'CreateShop') then return nil end
    if not IsResourceExportCapable('qb-inventory', 'AddHook') then return nil end

    return {
        --- COMPOSED, not a single native export: confirmed
        --- `exports('GetInventory', function(identifier) return
        --- Inventories[identifier] end)` returns the whole inventory
        --- record; `.items` is the same field every confirmed mutator
        --- (AddItem/RemoveItem/InitializeInventory) reads and writes.
        --- PASS-THROUGH, NATIVE SHAPE (qb-inventory's own per-slot item
        --- table: `{name, amount, info, label, weight, slot, ...}` -- see
        --- this file's header on why this is never normalized to
        --- ox_inventory's `{name, count, weight, slot}` shape here).
        --- Table-shaped `inv` (the `{ id, netid }` vehicle-trunk form
        --- server/search.lua builds for ox_inventory's own uncached-trunk
        --- lazy-load mechanism) has NO confirmed qb-inventory equivalent --
        --- every real lookup path traced this session (`Inventories[identifier]`,
        --- `player.PlayerData.items`, `Drops[identifier].items`) takes a
        --- plain string/number key only, so a table `inv` fails closed to
        --- `nil` here rather than guessing what qb-inventory would do with
        --- one. This is NOT the same thing as "vehicle search does not work
        --- on qb-inventory": qb-inventory's own real vehicle-trunk inventory
        --- IS a plain scalar identifier (CONFIRMED, client/vehicles.lua's
        --- `qb-inventory:client:vehicleCheck` callback: `'trunk-' .. plate`,
        --- HYPHENATED -- a different string than ox_inventory's own
        --- `'trunk' .. plate`) -- server/search.lua now derives and passes
        --- THAT scalar form for this backend instead of the ox_inventory-only
        --- table shape (see its own `inventoryId` derivation comment), so
        --- vehicle search reaches this function's ordinary, working,
        --- scalar `GetInventory(inv)` path below, same as any stash id.
        --- @param inv string|number
        --- @return table|nil items
        GetInventoryItems = function(inv, _owner)
            if type(inv) == 'table' then return nil end
            local callOk, inventory = SafeExportCall('qb-inventory', 'GetInventory', inv)
            if not callOk or type(inventory) ~= 'table' then return nil end
            return inventory.items
        end,

        --- CONFIRMED-ABSENT CAPABILITY, not a guess: qb-inventory's
        --- complete server-side source (server/main.lua,
        --- server/functions.lua, server/hooks.lua) has zero mentions of a
        --- nested-container/bag-within-a-bag concept anywhere -- "no
        --- container exists at this slot" is the true, complete answer for
        --- every slot on this backend, not an unimplemented placeholder.
        --- server/search.lua's own recursive contraband scan (the one real
        --- caller) simply never descends further for this backend, which
        --- is correct: there is nowhere further to descend.
        --- @return nil
        GetContainerFromSlot = function(_inv, _slotId)
            return nil
        end,

        --- Confirmed (`exports('GetItemCount', GetItemCount)`,
        --- server/functions.lua: `function GetItemCount(source, items)`).
        --- Fails closed to `0`, same convention as the ox_inventory adapter
        --- above.
        --- @param inv string|number
        --- @param itemName string
        --- @return number count
        GetItemCount = function(inv, itemName, _metadata, _strict)
            local callOk, count = SafeExportCall('qb-inventory', 'GetItemCount', inv, itemName)
            if not callOk or type(count) ~= 'number' then return 0 end
            return count
        end,

        --- Confirmed (`exports('RemoveItem', RemoveItem)`,
        --- server/functions.lua: `function RemoveItem(identifier, item,
        --- amount, slot, reason, isInternalMove) -> boolean`). qb-inventory
        --- has no separate `reason` return value on failure -- only `nil`
        --- is returned here, matching the documented `string?` optionality.
        --- @return boolean success, string? reason
        RemoveItem = function(inv, item, count, _metadata, slot, _ignoreTotal, _strict)
            local callOk, success = SafeExportCall('qb-inventory', 'RemoveItem', inv, item, count, slot)
            if not callOk then return false, 'compat_call_failed' end
            return success == true, nil
        end,

        --- COMPOSED, and DELIBERATELY NOT a groups/owner-enforcing call --
        --- see this file's header SECURITY NOTE. Confirmed
        --- (`exports('CreateInventory', function(identifier, data) ...
        --- end)`, server/functions.lua) pre-creates the named inventory
        --- with the slots/maxweight THIS caller chose, rather than relying
        --- on `OpenInventory`'s own lazy-init fallback defaults. `owner`/
        --- `groups` are accepted for interface symmetry with the
        --- ox_inventory adapter and are INTENTIONALLY DISCARDED here --
        --- qb-inventory's confirmed source has no per-inventory ACL
        --- mechanism for this method to forward them to; see this file's
        --- header for why that is not a security gap for this specific
        --- backend (there is no client-reachable open primitive to bypass
        --- in the first place).
        --- @return boolean success
        RegisterStash = function(id, label, slots, maxWeight, _owner, _groups)
            local callOk = SafeExportCall('qb-inventory', 'CreateInventory', id, {
                label = label,
                slots = slots,
                maxweight = maxWeight,
            })
            return callOk
        end,

        --- Confirmed (`exports('CreateShop', CreateShop)`,
        --- server/functions.lua). DISCLOSED SEMANTIC DIFFERENCE from
        --- ox_inventory: qb-inventory shop slots are STOCK-LIMITED
        --- (`SetupShopItems`'s confirmed `amount = tonumber(item.amount)`
        --- field depletes as players buy -- there is no "infinite price
        --- list" mode this adapter can select). `shopDetails.items[n]` may
        --- optionally carry an `amount` field for this backend; when
        --- absent this adapter supplies a large, clearly-arbitrary default
        --- rather than silently mapping to an unlimited stock this backend
        --- does not actually support -- an operator relying on
        --- ox_inventory-style infinite stock will need to restock
        --- periodically on a qb-inventory server. Not a guess about the
        --- export's signature (that part is fully confirmed); a disclosed
        --- product-level default for a field ox_inventory's own shop
        --- concept has no equivalent of at all.
        --- @param shopType string
        --- @param shopDetails table -- { label, items: {name,price,amount?}[], groups (unsupported, see below) }
        --- @return boolean success
        RegisterShop = function(shopType, shopDetails)
            if type(shopDetails) ~= 'table' or type(shopDetails.items) ~= 'table' then return false end

            local items = {}
            for i, entry in ipairs(shopDetails.items) do
                items[i] = {
                    name = entry.name,
                    price = entry.price,
                    -- See doc comment above: qb-inventory shops are
                    -- stock-limited; this is a disclosed default, not a
                    -- confirmed "unlimited" mode.
                    amount = entry.amount or 999999,
                }
            end

            local callOk = SafeExportCall('qb-inventory', 'CreateShop', {
                name = shopType,
                label = shopDetails.label,
                items = items,
                -- `groups` has no qb-inventory CreateShop equivalent
                -- (confirmed: RegisteredShops/SetupShopItems carry no
                -- groups/job field anywhere in the traced source) --
                -- silently dropped, never forwarded as a fake ACL.
            })
            return callOk
        end,

        --- See this file's header "THE RegisterHook VOCABULARY" section.
        --- Per DEVELOPER_REFERENCE.md §21's "match the reference resource's
        --- calling convention" rule, `eventName` is ox_inventory's OWN real
        --- vocabulary -- but qb-inventory only has a confirmed translation
        --- for ONE of those names: `'swapItems'`, and only the
        --- "item entering a named inventory, veto with the literal false"
        --- HALF of what ox_inventory's real 'swapItems' can express. Any
        --- other `eventName` (including one this file simply has no
        --- confirmed qb-inventory mapping for) returns `false` immediately,
        --- never a guess.
        ---
        --- 'swapItems' maps onto the CONFIRMED, real
        --- `AddHook('ItemAdded', callback)` veto point
        --- (server/functions.lua's `AddItem`: `local mutatedInfo =
        --- TriggerHook('ItemAdded', pendingItem.type, hookData); if
        --- mutatedInfo == false then return false end` -- traced end to
        --- end this session, including `buildItemAddedData`'s confirmed
        --- `{ toId, toInventory, toType, toSlot, item, amount, reason,
        --- resource }` payload shape, server/hooks.lua). The payload handed
        --- to `callback` is translated onto ox_inventory's OWN real
        --- 'swapItems' field names (`fromInventory`, `fromSlot`,
        --- `toInventory`, `toType`, `source`) -- NOT this backend's own
        --- `hookData` field names, which differ in both naming AND type
        --- (qb-inventory's own `hookData.toInventory` is the RESOLVED
        --- inventory DATA table, not an id string; ox_inventory's
        --- `toInventory` is always the id STRING -- `hookData.toId` is the
        --- field that actually matches ox_inventory's `toInventory`
        --- semantic, and is what this wrapper uses). Confirmed-absent from
        --- qb-inventory's ItemAdded payload, and therefore always `nil`
        --- here: `fromInventory` (no source-inventory identifier exists in
        --- this event at all) and `source` (no player id is threaded
        --- through `buildItemAddedData`). `toType` is forwarded
        --- best-effort from `hookData.toType` (qb-inventory's own
        --- `GetInventoryType` result) but its exact value vocabulary was
        --- NOT cross-checked against ox_inventory's own `toType` strings
        --- this session -- do not branch on a specific `toType` STRING
        --- VALUE for this backend without confirming it first; branching on
        --- `toInventory`'s id (as Config.K9Inventory.allowedItems' own
        --- `'k9inv-'` prefix check already does) does not depend on this.
        ---
        --- DISCLOSED, UNCONFIRMED EDGE CASE: ox_inventory's real
        --- 'swapItems' never fires for a same-stash slot-to-slot reorganize
        --- in a way this file can detect on qb-inventory (there is no
        --- combined from+to payload the way ox_inventory's single event
        --- carries both sides) -- `AddItem`'s own `isInternalMove` parameter
        --- can suppress the `ItemAdded` hook entirely for an internal
        --- transfer, but this session did not trace every call site that
        --- passes it, so whether a same-stash reorganize on qb-inventory
        --- ever reaches this wrapper at all was not fully confirmed either
        --- way. Not a guess this file's callback logic makes (there is
        --- nothing here that COULD detect "same stash" from an `ItemAdded`
        --- payload alone -- no `fromInventory` exists to compare against);
        --- flagged for whoever next verifies qb-inventory live.
        ---
        --- 'swapItems' with `payload.toType == 'drop'` (ScentTracking's real
        --- usage) is now a SECOND, SEPARATE CONFIRMED TRANSLATION, not the
        --- permanent no-op an earlier revision of this comment recorded.
        --- CORRECTION (re-fetched and re-read qbcore-framework/qb-inventory's
        --- `main` branch directly, fxmanifest.lua still version '2.1.0'):
        --- the earlier claim that "no call site anywhere ever fires
        --- `TriggerHook('ItemDropped', ...)`" was WRONG -- server/main.lua's
        --- own
        --- `QBCore.Functions.CreateCallback('qb-inventory:server:createDrop',
        --- ...)` (the server side of the client's `DropItem` NUI callback,
        --- client/drops.lua -- the ONLY place a ground `Drops[...]` entry is
        --- ever constructed in this backend's complete source, confirmed by
        --- grepping every `Drops[` write site) contains, verbatim:
        ---   `local hookData = buildHookData('ItemDropped', src, Player, playerCoords, item.fromSlot, item.amount)`
        ---   `if TriggerHook('ItemDropped', hookData.item.type, hookData) == false then cb(false) return end`
        --- -- run BEFORE the drop is created, so it can genuinely veto it
        --- (matches ox_inventory's own real 'swapItems' semantics: returning
        --- `false` for a drop cancels it). `buildItemDroppedData`
        --- (server/hooks.lua) confirms the exact payload shape handed to
        --- every `AddHook('ItemDropped', ...)` callback: `{ source,
        --- sourceInventory, coords, item, amount }` -- `source` (the
        --- dropping player's server id) and `item`/`amount` are exactly what
        --- this translation, and ScentTracking's own real usage
        --- (server/tracking.lua's `RegisterScentInventoryHook`, which reads
        --- only `payload.toType` and `payload.source`), need. `dropId`/
        --- `netId` are NOT present at this point (confirmed: `hookData.dropId`/
        --- `hookData.netId` are assigned in server/main.lua only AFTER this
        --- `TriggerHook` call already returned, and only inside the
        --- `RemoveItem(...)`-succeeded branch) -- never fabricated here.
        --- Translated onto ox_inventory's own 'swapItems'-with-`toType ==
        --- 'drop'` shape: `toType` is hardcoded to the literal string
        --- `'drop'` (not read from any qb-inventory field -- there is no
        --- `toType` field on this event at all; the LITERAL VALUE is what is
        --- confirmed, because `AddHook('ItemDropped', ...)` firing at all
        --- IS, unambiguously, ox_inventory's 'drop' semantic -- an item
        --- leaving a player's inventory onto the ground -- never a guess
        --- about a payload field, a translation of a whole confirmed event
        --- TYPE into this vocabulary's one matching value). `toInventory`/
        --- `fromInventory` are confirmed absent (a ground drop has no
        --- destination inventory identifier at this point) and stay `nil` --
        --- safe for server/inventory.lua's own K9Inventory allowedItems veto
        --- callback too, which already treats a non-string `toInventory` as
        --- "not a K9 stash, never filter" (see that file's own
        --- RegisterK9InventoryItemFilterHook). Registered as a SEPARATE
        --- `AddHook('ItemDropped', ...)` call, independent of the
        --- `AddHook('ItemAdded', ...)` one above -- ox_inventory models both
        --- halves as one native event; qb-inventory genuinely does not, so
        --- one abstract 'swapItems' registration here faithfully becomes TWO
        --- real qb-inventory hook registrations, exactly the
        --- "translate its own real hook mechanism into that same
        --- vocabulary" job this file's header assigns every non-ox_inventory
        --- adapter. The two registrations are independent for capability
        --- purposes too, and this is NOT purely theoretical: fxmanifest.lua's
        --- `dependencies` mechanism has no version-constraint syntax at all
        --- (confirmed elsewhere in this codebase, server/tracking.lua's own
        --- COMPAT-LAYER MIGRATION note) -- an operator could genuinely be
        --- running an OLDER qb-inventory build that predates this session's
        --- `ItemDropped` discovery (or a fork that dropped it while keeping
        --- `ItemAdded`), in which case `Events.ItemDropped` would not exist
        --- at all and `AddHook('ItemDropped', ...)` fails closed to `nil`
        --- (its own confirmed "Invalid hook type" branch,
        --- server/functions.lua) -- a REAL, not merely hypothetical, way for
        --- exactly this divergence to happen. When it does, this method
        --- still returns `true` (the veto capability this backend has always
        --- genuinely provided keeps working) and prints ONE distinct,
        --- dedicated warning naming the drop-specific gap, rather than
        --- either silently losing the ScentTracking capability or rolling it
        --- into the unrelated ItemAdded failure message.
        --- @param eventName string -- only 'swapItems' has a confirmed translation on this backend
        --- @param callback fun(payload: table): boolean|nil
        --- @return boolean success
        RegisterHook = function(eventName, callback)
            if type(callback) ~= 'function' then return false end
            if eventName ~= 'swapItems' then return false end

            local callOk, hookIdx = SafeExportCall('qb-inventory', 'AddHook', 'ItemAdded', function(_itemType, hookData)
                if type(hookData) ~= 'table' then return end
                local item = hookData.item
                if type(item) ~= 'table' or type(item.name) ~= 'string' then return end
                if hookData.toId == nil then return end

                local vetoOk, veto = pcall(callback, {
                    toInventory = tostring(hookData.toId),
                    fromInventory = nil, -- confirmed absent from this event, see doc comment above
                    fromSlot = { name = item.name, count = hookData.amount },
                    toType = type(hookData.toType) == 'string' and hookData.toType or nil, -- best-effort, see doc comment above
                    source = nil, -- confirmed absent from this event, see doc comment above
                })
                if vetoOk and veto == false then return false end
            end)
            if not callOk or hookIdx == nil then
                print("[John-K9] shared/compat/inventory.lua: qb-inventory RegisterHook('swapItems') failed -- " ..
                    'AddHook did not return a hook index. The allowedItems-style veto this backs is NOT enforced this session.')
                return false
            end

            -- SEPARATE, CONFIRMED translation for the ground-drop half --
            -- see this method's own doc comment above for the full citation
            -- (server/main.lua's `qb-inventory:server:createDrop` callback,
            -- `buildItemDroppedData`, server/hooks.lua).
            local dropCallOk, dropHookIdx = SafeExportCall('qb-inventory', 'AddHook', 'ItemDropped', function(_itemType, hookData)
                if type(hookData) ~= 'table' then return end
                if type(hookData.source) ~= 'number' then return end

                local item = hookData.item
                local vetoOk, veto = pcall(callback, {
                    toInventory = nil, -- confirmed absent -- see doc comment above
                    fromInventory = nil, -- confirmed absent -- see doc comment above
                    fromSlot = (type(item) == 'table' and type(item.name) == 'string')
                        and { name = item.name, count = hookData.amount } or nil,
                    toType = 'drop', -- SYNTHESIZED literal, not a guessed field -- see doc comment above for why this is confirmed, not guessed
                    source = hookData.source,
                })
                if vetoOk and veto == false then return false end
            end)
            if not dropCallOk or dropHookIdx == nil then
                if not QbInventoryDropHookWarned then
                    QbInventoryDropHookWarned = true
                    print("[John-K9] shared/compat/inventory.lua: WARNING: qb-inventory RegisterHook('swapItems') " ..
                        "registered the ItemAdded veto point successfully, but the separate AddHook('ItemDropped', ...) " ..
                        'registration this backend needs for the ground-drop half of \'swapItems\' (payload.toType == ' ..
                        "'drop', ScentTracking's own usage) FAILED. Everything else this hook backs (e.g. the K9 gear " ..
                        'stash item whitelist) keeps working normally; only a caller that specifically needs to observe ' ..
                        'a ground drop on this backend (scent tracking) will never see one this session.')
                end
            end

            return true
        end,

        --- ADDED: see this file's header ADDENDUM for the full "why now"
        --- writeup. DISCLOSED PLACEHOLDER, NOT A GUESSED EXPORT: this
        --- backend's complete server-side source (server/main.lua,
        --- server/functions.lua, server/commands.lua, server/hooks.lua) has
        --- no confirmed item-catalog-lookup export this method could call --
        --- reaching into `QBCore.Shared.Items` would couple this INVENTORY
        --- adapter to one specific FRAMEWORK choice, which this file's own
        --- header (see "THE `RegisterHook` VOCABULARY", and the
        --- qb-inventory CLIENT realm's own identical refusal a few sections
        --- up) already establishes this compat layer's systems must not do
        --- to stay independently pluggable.
        ---
        --- Always answers `true` ("assume present"), never `false`
        --- ("assume absent") -- deliberately, not arbitrarily: this method's
        --- one current real-world consumer (a startup sanity WARNING for a
        --- misconfigured item name, see server/equipmentshop.lua's/
        --- server/wellbeing.lua's own WarnIfItemMissing) would, on a
        --- guessable-but-wrong `false`, tell an operator a real item is
        --- missing when this adapter genuinely cannot check -- an active,
        --- misleading false alarm. Answering `true` unconditionally instead
        --- reproduces exactly today's status quo for every non-ox_inventory
        --- backend (that warning simply never fires), adding no new failure
        --- mode. If qb-inventory ever gains a confirmed, real catalog-lookup
        --- export, replace this body with a real call the same way every
        --- other CONFIRMED method above does -- do not read this as
        --- "qb-inventory has no items," only as "this file found no export
        --- to ask it with."
        --- @param _itemName any
        --- @return boolean
        ItemExists = function(_itemName)
            return true
        end,
    }
end

K9Compat.RegisterAdapter('inventory', 'qb-inventory', function(realm)
    if realm == 'client' then return nil end -- see section header: no confirmed client-callable equivalent exists
    if realm == 'server' then return BuildQbInventoryServer() end
    return nil
end)

-- ======================================================================
-- ps-inventory -- FOUND (Project-Sloth/ps-inventory, branch `main`, a real
-- actively-maintained qb-inventory-derived rewrite), but SKIPPED. Its
-- complete server/main.lua (2827 lines, the only server file its own
-- fxmanifest.lua declares) was read this session and confirmed to have NO
-- export named/shaped like `GetInventoryItems`, `RegisterStash`, or any
-- hook-registration mechanism at all (`AddHook`/`TriggerHook`/
-- `registerHook` -- zero matches for "Hook" anywhere in the file). That is
-- 3 of the required server methods (7 at the time this was researched, now
-- 8 -- `ItemExists` was added after this section was first written and was
-- NOT separately re-checked against ps-inventory's source, so its status
-- here is simply unknown, not confirmed either way) with no confirmed real
-- equivalent -- `OpenInventory`/`OpenShop` are, like qb-inventory,
-- SERVER-side exports taking `source`, so the client realm has the
-- identical architectural mismatch as qb-inventory on top of that.
--
-- A caller COULD compose a partial server table (GetItemCount via
-- possession-scanning, RemoveItem is a confirmed real export) and let
-- core's required-method check skip it anyway -- but shipping a
-- half-built table here would only make the SKIP reason harder to find
-- later. Returning nil directly, with the reasoning on record.
-- ======================================================================
K9Compat.RegisterAdapter('inventory', 'ps-inventory', function(_realm)
    WarnUnconfirmedOnce('ps-inventory', "a real source repository was found and read this session " ..
        '(Project-Sloth/ps-inventory) but at least 3 of the 8 required server methods -- GetInventoryItems, ' ..
        'RegisterStash, and any hook-registration mechanism at all -- have no confirmed real export ' ..
        'in its source, and its OpenInventory/OpenShop are server-side-only exports with no ' ..
        'client-callable equivalent (same architecture as qb-inventory).')
    return nil
end)

-- ======================================================================
-- origen_inventory / codem-inventory / core_inventory / tgiann-inventory --
-- UNCONFIRMED. No public source repository located this session for any of
-- these four (a range of plausible owner/org names were tried against
-- raw.githubusercontent.com's `main`/`master` branches and every one
-- returned 404; GitHub's own search/API was not reachable from this
-- session for arbitrary repositories). These read as
-- closed-source/marketplace-distributed scripts this session had no
-- primary source to verify against. Returning nil unconditionally.
-- ======================================================================
K9Compat.RegisterAdapter('inventory', 'origen_inventory', function(_realm)
    WarnUnconfirmedOnce('origen_inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)

K9Compat.RegisterAdapter('inventory', 'codem-inventory', function(_realm)
    -- Researched twice. There is genuinely no public source repository --
    -- this is a paid, Tebex-distributed script -- and while its real
    -- documentation does exist (codem.gitbook.io), it was unreachable from
    -- the network the research ran on, so nothing could be read verbatim.
    --
    -- ONE LEAD FOR WHOEVER PICKS THIS UP, worth more than the absence: a
    -- third-party integrator's own merged fix (jim_bridge PR #38) ABANDONED
    -- the obvious client export `exports[codem]:OpenStash(...)` and replaced
    -- it with a server event, `codem-inventory:server:openstash`, saying
    -- that is what makes stashes actually work. So the intuitive
    -- client-export shape is likely the wrong one. That is third-party
    -- integration code rather than this script's own source, which is
    -- exactly why it is recorded here as a lead and NOT wired into an
    -- adapter -- but it is real evidence against the guess someone would
    -- otherwise make first.
    WarnUnconfirmedOnce('codem-inventory', 'it is a paid script with no public source repository, and its own ' ..
        'documentation could not be reached to confirm real export names and argument shapes. See this file for ' ..
        'the one concrete lead found (a third-party bridge uses a SERVER EVENT for stashes, not a client export).')
    return nil
end)

K9Compat.RegisterAdapter('inventory', 'core_inventory', function(_realm)
    -- Researched twice. Paid script, no public source repository, and its
    -- documentation (docs.c8re.store) was unreachable from the network the
    -- research ran on.
    --
    -- THE FINDING WORTH KEEPING is what happened when the researcher fell
    -- back on web search: two separate queries for the SAME export returned
    -- two different, mutually incompatible signatures. Neither was shipped.
    -- That contradiction is the most useful thing learned here, because it
    -- is direct evidence that a search-engine paraphrase of this particular
    -- site cannot be trusted for an exact signature -- and a wrong
    -- signature would detect as working and then silently do nothing, which
    -- is the single most expensive bug class this codebase has.
    --
    -- One correction to a natural assumption, for whoever follows up: this
    -- inventory DOES appear to have real nested containers (backpacks,
    -- cases). So "no container concept", which is the true answer for
    -- qb-inventory, would be the WRONG answer here. Confirm, do not
    -- transplant.
    WarnUnconfirmedOnce('core_inventory', 'it is a paid script with no public source repository, and its own ' ..
        'documentation could not be reached. Web-search results for its exports contradicted each other across ' ..
        'queries, so no signature was trusted. Confirm against a live install rather than searching.')
    return nil
end)

K9Compat.RegisterAdapter('inventory', 'tgiann-inventory', function(_realm)
    WarnUnconfirmedOnce('tgiann-inventory', 'no public source repository could be located this session ' ..
        '(likely a closed-source/marketplace script) to confirm its real export names and argument shapes against.')
    return nil
end)
