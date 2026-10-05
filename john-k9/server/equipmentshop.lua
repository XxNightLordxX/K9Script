--[[
    john-k9/server/equipmentshop.lua

    K9 EQUIPMENT SHOP -- DEVELOPER_REFERENCE.md Part B §6 (coder-backend, this
    pass). "The cheapest of the three" per that doc: registers a "K9 Supply"
    shop via `ox_inventory`'s own `RegisterShop` export, selling the item
    names this codebase has already invented and left as documented
    PLACEHOLDERS with nowhere to buy them (`k9_medkit`, `k9_treat`,
    `k9_meat_bait`, `k9_ultrasonic_whistle` -- server/medkit.lua's
    Config.K9Medkit.itemName and server/wellbeing.lua's Mood/Distraction item
    names). Right now, on a fresh install with the wellbeing subsystem
    enabled (it is, by default, per DEVELOPER_REFERENCE.md), there is nothing to
    actually buy -- this file finishes that half-built loop, it does not
    start a new one.

    ======================================================================
    THE HARD CONSTRAINT THIS FILE IS BUILT UNDER (this task's own explicit
    instruction, restated here because it drives every choice below): this
    resource must never hardwire a NAMED third-party shop, banking or
    billing resource -- the operator's own custom systems are "not limited
    to any particular ones." `ox_inventory` is different in kind, not
    degree: it is already a DECLARED, HARD dependency of this resource
    (fxmanifest.lua's own `dependencies` block), already required for Phase
    2's own contraband search to function at all -- building on it directly
    here is not a new integration, it is using an existing one for one more
    thing. This file therefore:
      * calls ONLY `exports.ox_inventory:...` -- never any other named
        resource, never a `qb-shops`/similar assumption, never a specific
        banking export;
      * charges against `Config.K9EquipmentShop.currencyItem` -- an ITEM
        NAME ox_inventory itself already tracks (its own built-in cash
        item, conventionally `'money'`), not a separate banking resource --
        so an operator whose economy renames or omits that item still gets
        a clean warning (see WarnIfItemMissing below), never a silent
        assumption;
      * wraps the ENTIRE registration in `pcall`, so an ox_inventory version
        with a different/older `RegisterShop` shape degrades to one loud
        console line, never a resource-start failure.

    ======================================================================
    VERIFIED, NOT ASSUMED, AGAINST THE REAL, CURRENT ox_inventory SOURCE
    (overextended/ox_inventory, `modules/shops/server.lua` and
    `modules/shops/client.lua`, fetched and read directly this pass -- same
    "verify before believing" discipline this resource's own COORDINATION
    notes require for natives, applied here to an export instead) --
    RECORDED HERE so the next person to touch this file does not have to
    re-derive it from scratch:

      1. `exports.ox_inventory:RegisterShop(shopType, shopDetails)` is a
         real, current, server-side export. `shopDetails.inventory` is an
         array of `{ name, price, currency? }` -- `currency` defaults to
         `'money'` when omitted (ox_inventory's own `canAffordItem`/
         `removeCurrency`, which operate on it as a plain `GetItemCount`/
         `RemoveItem` ITEM NAME, never a banking API call).

      2. DELIBERATELY NOT passing `shopDetails.locations`/`.targets`.
         Supplying either would route this shop through ox_inventory's OWN
         internal `data/shops.lua`-driven marker/target system --
         `modules/shops/client.lua`'s `shopTypes` table (which is what that
         system actually reads) is populated ONLY from ox_inventory's own
         bundled `lib.load('data.shops')` at THAT resource's own client
         load time, with no server round-trip and no live sync of anything
         registered later via the `RegisterShop` export. In plain terms: a
         shop registered from an EXTERNAL resource (this one) never gains a
         walk-up marker/prompt of its own for free, no matter what fields
         are passed to `RegisterShop` -- registering WITHOUT `locations`
         instead yields a flat, immediately-open-able `Shops[shopType]`
         entry (`modules/shops/server.lua`'s `registerShopType`, the
         `else` branch, calling `setupShopItems(nil, ...)` so `.items` is
         populated directly), openable by TYPE ALONE with no `id`. This is
         why client/equipmentshop.lua (this pass's own small companion
         file) builds its OWN `ox_target` sphere zone rather than relying
         on anything ox_inventory auto-creates -- confirmed necessary by
         reading the real client module, not assumed from the doc's "one
         small config table + RegisterShop call" estimate, which undersold
         this by exactly this one client-side gap. Reported plainly here so
         a future audit does not "rediscover" a working design as broken.

      3. `exports.ox_inventory:openInventory('shop', { type = shopType })`
         (client/equipmentshop.lua's own call) is the exact, real client
         export (`client.lua`'s `exports('openInventory', client.openInventory)`)
         and the exact `{ type = ... }` shape `ox_inventory:openShop`'s own
         server callback expects when a shop has no `locations`/`.items` is
         already populated (see point 2) -- no `id` field needed for this
         shop's own registration shape.

      4. `groups` (job -> minimum grade) is ox_inventory's own real,
         existing shop-restriction field, enforced SERVER-SIDE inside its
         own `ox_inventory:openShop` callback (`server.hasGroup(playerInv,
         shop.groups)`) -- this file derives it from THIS resource's own,
         already-existing `Config.Departments` (no new config table needed
         for job restriction at all), so only a K9-eligible department may
         see or buy from this shop. The companion `ox_target` zone ALSO
         receives the same `groups` value on its own option (mirroring
         ox_inventory's own client module doing exactly the same thing for
         its internal shops) -- purely a VISUAL/UX filter, never the real
         boundary: per this resource's own "the tablet is a VIEW, it
         decides nothing" convention, the true authorization is
         ox_inventory's own server-side `hasGroup` check, which a modified
         client cannot bypass by pretending the option was visible.

    ======================================================================
    THE WARNING PATTERN -- mirrors server/wellbeing.lua's own
    `WarnIfItemMissing` (that file's own "STUCK-K9 SOFTLOCK FIX item 3")
    EXACTLY, duplicated here as this file's OWN small, self-contained copy
    rather than a shared cross-file call -- same "each file keeps its own
    tiny copy of a genuinely small, self-contained check" convention this
    resource already applies elsewhere (server/certifications/'s/
    server/partnership.lua's own independent `IsDuplicateKeyError`/
    `FireOutboundEvent` copies). A WARNING ONLY, never an assert, never a
    resource-start failure -- an operator's own item table is THEIR
    configuration, not a defect in this resource, and a missing item must
    never look like a broken FEATURE (the whole shop silently failing to
    register) OR a broken ITEM (one slot silently invisible with nothing
    explaining why) -- every configured item is checked and reported by
    name, and the shop registers with whatever DOES resolve rather than
    refusing outright over one bad entry.

    ======================================================================
    RUNTIME SHOP LOCATIONS (this pass, coder-frontend). The owner's own
    words: "make the shop a dog ped and i can change the locations in the
    config or add more locations remove locations etc along with in the
    high command tablet." Two things landed this pass:

      1. THE SHOP PED. client/equipmentshop.lua now spawns a real, visible
         ped at each shop location and targets THAT PED via ox_target's
         `addLocalEntity` -- not a bare invisible sphere. Which model, and
         any idle scenario it plays, is fully operator-configurable
         (Config.K9EquipmentShop.pedModel/pedHeading/pedScenario below, or
         a per-location override), never hardcoded, and never validated
         against Config.Peds -- a shop attendant is not a K9. See that
         file's own header for the full entity-lifecycle contract (what
         owns each ped's lifetime, what deletes it, and why these are
         local, non-networked entities -- no netId, no cross-client race).

      2. RUNTIME-EDITABLE LOCATIONS. Config.K9EquipmentShop.locations
         already covers "change in the config" (add/remove/reorder
         entries freely, no code change -- unchanged by this pass). NEW
         this pass: a database-backed pool of ADDITIONAL locations the
         high command tablet can add to, move within, and remove from AT
         RUNTIME, persisted across restarts (sql/migrations/0011_create_k9_equipment_shop_locations.sql
         + its audit-table companion, following the exact
         current-state-table + append-only-audit-table shape
         server/runtimecontrol.lua's own migration 0007 already
         established). SCOPE, stated plainly: these callbacks manage ONLY
         the database-native pool (`db:<id>` keys) -- a config.lua-defined
         location (`db:<n>` -- no, a config-sourced `cfg:<n>` key) is never
         overridden or suppressed from here; it stays editable only by
         hand-editing config.lua and restarting, exactly as before this
         pass. This is a deliberate decision, not an oversight: a stored
         override keyed to config.lua's own ARRAY INDEX would silently
         apply to the wrong location the instant an operator reorders that
         array -- which Config.K9EquipmentShop's own comment explicitly
         invites doing freely -- so this file does not introduce that
         hazard. The EFFECTIVE location list any player actually sees
         (BuildEffectiveLocations below) is always a pure UNION of both
         sources, never a conflict to resolve.

      PRIVILEGE, per this task's own explicit instruction: every mutating
      callback below (`equipmentShopAddLocation`/`MoveLocation`/
      `RemoveLocation`) re-verifies `IsHighCommand(source)` SERVER-SIDE, at
      the point of the action, every single call -- never a flag the NUI
      sent, never a cached client value, never a client-supplied grade.
      Mirrors server/runtimecontrol.lua's own CanManageRuntimeControl/
      CanManageTabletTheme shape as an independent, self-contained copy
      (this file owns no resource-global of runtimecontrol.lua's and calls
      none -- see that file's own header: "THIS FILE exposes no
      resource-global functions") -- same `IsHighCommand` first, then a
      `HasPermission(citizenid, 'k9.equipmentshoplocations')` escape hatch
      behind the usual `type(HasPermission) == 'function'` guard, which
      today always returns false (that key is not yet in
      Config.Permissions) so IsHighCommand alone gates this, exactly
      matching this resource's established "the permission-grant escape
      hatch activates automatically the moment that key is added, zero
      code change here" convention.

      Every mutation is followed by
      `TriggerClientEvent('john-k9:client:equipmentShopLocationsUpdated', -1, locations)`
      -- the FULL effective location table, same shape GetLocations
      returns -- so an already-connected player's own shop-ped thread (and
      any already-open tablet screen) updates live, without a reconnect or
      a tablet reopen, mirroring server/runtimecontrol.lua's own
      `themeUpdated` broadcast-on-change pattern exactly.

      Callbacks (ox_lib lib.callback), all in THIS file:
        'john-k9:server:equipmentShopGetLocations' (source) ->
            { ok, locations: table<string, ShopLocation> } -- open to ANY
            connected player (read-only, no privilege check), same
            openness as server/runtimecontrol.lua's GetTheme -- a player
            needs to know where a shop ped goes before they've done
            anything to earn special trust, exactly like the OLD sphere
            zone was reachable by anyone with no gate beyond the flag.
        'john-k9:server:equipmentShopAddLocation' (source, location:
            { x, y, z, heading?, model?, scenario?, label? }) ->
            { ok, locationKey, locations } | { ok = false, reason }
        'john-k9:server:equipmentShopMoveLocation' (source,
            locationKey: string, updates: { x?, y?, z?, heading?, model?,
            scenario?, label? }) -> { ok, locations } | { ok = false, reason }
            -- only valid on a `db:` key; see SCOPE above.
        'john-k9:server:equipmentShopRemoveLocation' (source,
            locationKey: string) -> { ok, locations } | { ok = false, reason }
            -- only valid on a `db:` key; see SCOPE above.
      Every response is a structured `{ ok, reason, ... }` outcome table,
      never player-facing prose -- matches server/runtimecontrol.lua's own
      established "no toast from this file, the tablet renders its own
      inline feedback from `reason`" precedent. No locale keys needed here
      for the identical reason that file states none are needed for itself.

      Client events (server->client), THIS file (server half) / the
      companion client/equipmentshop.lua (client half):
        'john-k9:client:equipmentShopLocationsUpdated' (locations: table)
            [broadcast to -1 on every successful mutation above]

    ======================================================================
    EVENT/CALLBACK CONTRACT (the ORIGINAL, unchanged shop-registration
    half of this file): no RegisterNetEvent/lib.callback of its own for
    the actual shop transaction. Every player-facing interaction (opening
    the shop, buying an item) already flows entirely through ox_inventory's
    own existing, already-security-reviewed `ox_inventory:openShop`/
    `ox_inventory:buyItem` callbacks. Adding a second, parallel purchase
    path of this resource's own would be pure duplication with a second
    place to get the authorization checks wrong. The RUNTIME SHOP LOCATIONS
    callbacks immediately above are new and additional to this paragraph,
    not a contradiction of it -- they manage WHERE a shop ped stands, never
    what it sells or what it costs.

    ======================================================================
    CONFIG THIS FILE NEEDS (reported, not added here -- config.lua has a
    live owner this session; see this pass's own report for the exact
    fields/comments/defaults):
      Config.Features.K9EquipmentShop : boolean
      Config.K9EquipmentShop : {
          shopType     : string  -- ox_inventory's own shop-type key
          label        : string  -- shown in the ox_target prompt and the ox_inventory UI header;
                          -- also this shop's DEFAULT per-location ox_target label (see below)
          currencyItem : string  -- an ox_inventory item name, e.g. 'money' -- NOT a banking resource
          items        : { { name: string, price: number }, ... }
          pedModel     : string  -- DEFAULT ped model for every shop location (NEW this pass) -- any
                          -- streamed ped, never validated against Config.Peds -- a shop attendant is
                          -- not a K9
          pedHeading   : number  -- DEFAULT heading (degrees) for every shop location (NEW this pass)
          pedScenario  : string|false -- DEFAULT idle scenario for every shop location, or false for
                          -- no scenario (NEW this pass) -- a REAL, VERIFIED scenario name, e.g.
                          -- 'WORLD_DOG_SITTING_SHEPHERD' (client/movement.lua's own K9Sit doc comment
                          -- has the verification this reuses)
          pedModelLoadTimeoutMs : number -- NEW this pass, same purpose/precedent as
                          -- Config.K9Appearance.modelLoadTimeoutMs
          locations    : { { x, y, z, model?, heading?, scenario?, label? }, ... } -- NOT read by
                          -- THIS file's RegisterShop call at all (see point 2 above for why this shop
                          -- is deliberately registered without a `locations` field on the ox_inventory
                          -- payload itself) -- consumed by BuildEffectiveLocations below (for the
                          -- runtime-locations callbacks' read side) and by client/equipmentshop.lua (to
                          -- actually place a ped and an ox_target interaction point per location).
                          -- Each entry may optionally override model/heading/scenario/label for that
                          -- ONE location only, falling back to the four shop-wide defaults above when
                          -- absent (NEW this pass -- previously plain { x, y, z } only). Listed here
                          -- anyway because it lives in the same config table and a server owner adding
                          -- one without the other would silently get a shop that exists but can never
                          -- be opened (server-side warning has no way to detect a client-side gap).
      }
    All fields are read defensively throughout both files (type-checked,
    never assumed) so a server that has not yet added them sees a clean,
    silent no-op -- not an error, not a stub with garbage data.

    FXMANIFEST.LUA PLACEMENT: DONE. This file is registered in
    server_scripts, and its client half in client_scripts. (This paragraph
    used to read "PLACEMENT REQUESTED ... not edited here", which stopped
    being true once the request was carried out and then sat here reading
    like an outstanding task.) No load-order requirement of its own -- this
    file calls no other file's resource-global on load, and nothing calls
    into this one -- so it is grouped alongside the other item-consuming
    features purely for readability.

    LOCALE: THIS FILE NOW OWNS SIX PLAYER-FACING KEYS, and this paragraph
    used to claim it owned none. Its console warnings are still operator-
    facing plain `print`, matching server/wellbeing.lua's own
    WarnIfItemMissing -- that part was and remains true. What changed is the
    REFUSAL messages: telling somebody why they cannot use the shop
    (equipmentshop.feature_disabled / not_granted / blocked_from_shop /
    requires_tier / requires_specialization / cannot_open_on_this_inventory)
    is squarely player-facing and squarely this file's business, since only
    this file knows which of those three quite different reasons applies.

    What genuinely IS still out of scope, and always was: the strings inside
    the actual shop UI -- item names, "you cannot afford that", "no room" --
    which belong to whichever inventory the server runs, not to this
    resource.
]]

-- ======================================================================
-- WarnIfItemMissing -- see this file's header "THE WARNING PATTERN"
-- section for the full precedent/reasoning. A WARNING ONLY -- never
-- throws, never prevents resource start.
--
-- COMPAT-LAYER FINDING (this pass, coder-backend), DELIBERATELY NOT ROUTED:
-- the `exports.ox_inventory:Items(itemName)` call below is left as a direct
-- call, NOT `K9Compat.Get('inventory')...` -- shared/compat/core.lua's
-- RequiredMethods.inventory table only lists `ItemExists` under the CLIENT
-- realm (`client = { 'OpenStash', 'OpenShop', 'UseItem', 'ItemExists' }`),
-- never under `server`. This function runs entirely server-side
-- (onResourceStart), so there is no server-side accessor in the current
-- contract this call could route through -- `K9Compat.Get('inventory')` on
-- the server realm exposes no `ItemExists` method at all, on ANY backend,
-- regardless of what is actually detected. Per this task's own explicit
-- instruction ("if a call site has no clean accessor, that is a finding,
-- not a licence to improvise"), this is reported rather than worked around:
-- adding a server-side ItemExists to the contract is a real, plausible fix,
-- but it is a contract change every adapter (ox_inventory, qb-inventory, and
-- the five unconfirmed stubs in shared/compat/inventory.lua) would need to
-- either implement or be silently skipped by verification -- exactly the
-- "adding one means every adapter must implement it or be skipped" risk
-- this task warns against taking unilaterally. Left alone here; reported to
-- main. Practical consequence: on a non-ox_inventory backend, this
-- item-existence pre-check simply never runs true (ox_inventory not
-- started -> GetResourceState guard fails closed inside the direct call's
-- own pcall below) -- the shop registration itself is now correctly
-- backend-agnostic (see RegisterShop below), but this one operator-facing
-- sanity warning stays ox_inventory-specific until the contract gains a
-- server-side ItemExists.
-- ======================================================================

--- @param itemName any
--- @param configPath string -- e.g. 'Config.K9EquipmentShop.items[2].name', for the printed message only
local function WarnIfItemMissing(itemName, configPath)
    if type(itemName) ~= 'string' or itemName == '' then
        print(('[John-K9] equipmentshop: WARNING: %s is not a valid item name (%s) -- cannot verify it against ox_inventory at all, and it will be SKIPPED from the shop rather than registered with garbage data.'):format(configPath, tostring(itemName)))
        return false
    end

    local ok, item = pcall(function() return exports.ox_inventory:Items(itemName) end)
    if not ok then
        print(('[John-K9] equipmentshop: WARNING: could not verify %s (%q) against ox_inventory -- the Items() export itself errored: %s. Confirm ox_inventory is installed and up to date.'):format(configPath, itemName, tostring(item)))
        return false
    end

    if not item then
        print(('[John-K9] equipmentshop: WARNING: %s (%q) does not exist in this server\'s ox_inventory item registry. This slot will be SKIPPED from the K9 Supply shop rather than sold as a broken, unusable entry -- add %q to your ox_inventory data/items.lua (or point %s at a real, existing item name) to actually sell it.'):format(configPath, itemName, itemName, configPath))
        return false
    end

    return true
end

-- ======================================================================
-- RUNTIME TOGGLE-ON FORWARD DECLARATIONS -- this pass (coder-backend),
-- closing the "the shop cannot be turned on at runtime" gap found by an
-- economy red-team pass. THE PROBLEM, CONFIRMED before writing a single
-- line below: both the original RegisterShop call (this section) and the
-- two ox_inventory purchase-enforcement hooks (this file's own "EQUIPMENT
-- SHOP ITEM CATALOG" section, far below) used to run ONLY inside their own
-- `onResourceStart` handlers, gated on Config.Features.K9EquipmentShop
-- being true AT THAT ONE MOMENT. `onResourceStart` fires exactly once.
-- server/runtimecontrol.lua's own `runtimeSetFeature` (confirmed by
-- reading it directly this pass) DOES flip the live `Config.Features.
-- K9EquipmentShop` table entry immediately when high command uses the
-- tablet -- but nothing was ever watching for that flip, so a server that
-- shipped with the flag false never gained a shop, no matter how long
-- after boot the flag was turned on. Failed in the SAFE direction (no
-- shop, not an unguarded one) -- but not genuinely toggleable, which this
-- resource's own owner has asked for repeatedly.
--
-- REGISTERING TWICE -- VERIFIED, NOT ASSUMED, against ox_inventory's real,
-- current source (overextended/ox_inventory main branch,
-- modules/shops/server.lua + modules/hooks/server.lua, fetched and read
-- directly this pass):
--   * `RegisterShop` (`registerShopType`) is a single, unconditional,
--     non-yielding `Shops[shopType] = { ... }` table OVERWRITE -- see this
--     file's own header, point 2, and the "EQUIPMENT SHOP ITEM CATALOG"
--     section's "THE EDIT/PURCHASE RACE" writeup for the fuller citation.
--     Safe to call any number of times, from any code path, at any time.
--   * `registerHook(event, ref, options)` is NOT idempotent and has NO
--     de-duplication of its own: `eventHooks[event]` is a plain,
--     ever-growing ARRAY (`eventHooks[event][#eventHooks[event] + 1] =
--     ref`), and `TriggerEventHooks` iterates every entry in it on every
--     single openShop/buyItem attempt. A second `registerHook('openShop',
--     ...)` call for the SAME logical hook does not replace the first --
--     it appends a second, fully redundant copy that fires forever
--     alongside it for the rest of the resource's life. ox_inventory does
--     expose a real `removeHooks(id)` export, but shared/compat/
--     inventory.lua's own `RegisterHook` wrapper discards the real
--     ox_inventory-assigned hookId (`local callOk = SafeExportCall(...)`
--     keeps only pcall's own success boolean, never the second return
--     value `registerHook` itself returns) -- there is currently no way
--     for THIS file to ask for that hookId back through the compat layer
--     at all. Reported to main/coder-backend as a shared/compat/
--     inventory.lua finding, not fixed here (out of this file's scope --
--     see this session's own report). The fix that stays entirely inside
--     THIS file: each hook-registration function below now registers with
--     ox_inventory AT MOST ONCE, ever, per server session, guarded by its
--     own dedicated flag (see EquipmentShopOpenHookRegistered/
--     EquipmentShopBuyHookRegistered far below) -- a later activation
--     attempt (a subsequent toggle-on edge, or an item-catalog edit
--     arriving before the shop was ever activated) always finds the
--     already-registered hook and skips straight past it, never appending
--     a duplicate.
--
-- HOOKS FIRST, ALWAYS -- ActivateEquipmentShopIfEnabled (defined at the
-- bottom of this file, once its own dependencies exist -- forward-declared
-- as a `local` immediately below, same idiom this file already uses for
-- ItemByKey/ItemOrder further down) registers BOTH ox_inventory
-- purchase-enforcement hooks and refuses to ever call RegisterShop unless
-- BOTH succeed. Confirmed against real source that this ordering is safe:
-- ox_inventory's own `openShop`/`buyItem` callbacks look up `Shops[shopType]`
-- FIRST and bail out (`if not shop then return end`) BEFORE ever invoking
-- `TriggerEventHooks` -- so a hook registered for a shopType that is not
-- (yet) in `Shops` is completely inert, never a live, unguarded shop with
-- no hook attached. The reverse -- RegisterShop succeeding while a hook
-- registration silently failed -- is exactly the bug this ordering
-- prevents: a shop that exists in ox_inventory with no per-person block
-- and no purchase-tier/specialization enforcement would be worse than no
-- shop at all, so a failed hook registration REFUSES the whole activation
-- and says why in the console, rather than opening an unguarded shop.
-- This closes a real, PRE-EXISTING gap in this exact ordering: before this
-- pass, the original RegisterShop call below ran in an EARLIER
-- onResourceStart handler than the hook registrations (this file's own
-- "EQUIPMENT SHOP ITEM CATALOG" section, far below) -- a hook-registration
-- failure at BOOT, not just at runtime, already left an unguarded shop
-- live. Also closes a second instance of the identical bug: every one of
-- the three item-catalog edit callbacks (equipmentShopItemsUpsert/Reorder/
-- Delete, far below) used to call LiveRefreshRegisteredShop() -- which
-- calls RegisterShop -- UNCONDITIONALLY, with no Config.Features check and
-- no dependency on the hooks ever having registered at all. An item-price
-- edit made by a `k9.equipmentshopitems` permission holder while the
-- master flag was OFF (hooks never registered) would silently create a
-- live, unguarded, purchasable shop. EnsureEquipmentShopReflectsCurrentCatalog
-- (also forward-declared below, real body at the bottom of this file) now
-- gates that: it only calls LiveRefreshRegisteredShop directly once the
-- shop is ALREADY fully activated (hooks confirmed); otherwise it routes
-- through ActivateEquipmentShopIfEnabled, the one and only gate that may
-- ever cause RegisterShop to run for the first time.
--
-- THE EXISTING LIVE-REFRESH PATH -- LiveRefreshRegisteredShop (this file's
-- own "EQUIPMENT SHOP ITEM CATALOG" section) is NOT duplicated or
-- reimplemented here. RegisterEquipmentShopFromConfig below is the
-- ORIGINAL, byte-for-byte UNCHANGED validation/registration logic this
-- section has always had (raw Config.K9EquipmentShop.items, no database
-- overlay) -- extracted into a named, callable-more-than-once function
-- rather than rewritten, so the boot-time-on path behaves EXACTLY as it
-- did before this pass (see tests/equipmentshop_spec.lua, entirely
-- unchanged by this pass). ActivateEquipmentShopIfEnabled below calls this
-- FIRST, then (like this file's own pre-existing boot sequence already
-- did) layers any k9_equipment_shop_items database overlay on top via the
-- EXISTING RefreshEquipmentShopItemCatalog + LiveRefreshRegisteredShop
-- pair -- two established, independent, already-tested functions
-- sequenced correctly behind the hooks, never a third, competing
-- implementation of "how to call RegisterShop."
--
-- TOGGLE-OFF MUST NOT STRAND ANYONE -- gate the OPENING, never the
-- CLOSING. Nothing added by this pass touches ox_inventory's own
-- inventory-close path at all (there is no such hook anywhere in this
-- file). A player with the shop UI already open when the flag flips off
-- keeps whatever ox_inventory itself allows for closing an already-open
-- inventory, completely untouched by this file. The two enforcement hooks
-- (openShop / buyItem) already re-check Config.Features.K9EquipmentShop
-- LIVE, fresh, on every single invocation (IsEquipmentShopPermittedForCitizenId's
-- own step 1) -- once registered, a toggle OFF is therefore enforced
-- immediately and correctly with NO further code needed here: the very
-- next open/buy attempt is vetoed. This is also exactly why hooks are
-- registered AT MOST ONCE, ever: they do not need to be re-registered on
-- every toggle to keep working correctly in both directions.
-- ======================================================================
local ActivateEquipmentShopIfEnabled
local EnsureEquipmentShopReflectsCurrentCatalog

-- ======================================================================
-- REGISTRATION -- gated at the TOP on Config.Features.K9EquipmentShop, so a
-- server that has not added the flag (or has it false) does ABSOLUTELY
-- NOTHING below this point: no warning prints, no ox_inventory calls, no
-- table allocation. Matches server/integrations.lua's own documented
-- "ABSENCE IS A CLEAN NO-OP" design principle, applied here to a feature
-- flag that may not exist yet at all rather than one that exists and is
-- merely off.
-- ======================================================================

--- Validates Config.K9EquipmentShop and, if usable, registers the K9
--- Supply shop with ox_inventory from its RAW config items (no database
--- overlay -- see RefreshEquipmentShopItemCatalog/LiveRefreshRegisteredShop
--- for that separate, already-existing layer). THE ORIGINAL, byte-for-byte
--- UNCHANGED validation/registration logic this section has always had,
--- from before this pass -- only extracted into a named function so it can
--- be called from ActivateEquipmentShopIfEnabled below as well as from
--- this section's own onResourceStart handler. Safe to call any number of
--- times (RegisterShop's own real implementation is a safe, unconditional
--- full overwrite -- see this file's header "THE EDIT/PURCHASE RACE").
--- @return boolean ok -- true only when RegisterShop was actually called and reported success
local function RegisterEquipmentShopFromConfig()
    local shopConfig = Config.K9EquipmentShop
    if type(shopConfig) ~= 'table' then
        print('[John-K9] equipmentshop: WARNING: Config.Features.K9EquipmentShop is true but Config.K9EquipmentShop is missing or not a table -- the K9 Supply shop will NOT be registered. Add Config.K9EquipmentShop (shopType/label/currencyItem/items) to config.lua.')
        return false
    end

    if type(shopConfig.shopType) ~= 'string' or shopConfig.shopType == '' then
        print('[John-K9] equipmentshop: WARNING: Config.K9EquipmentShop.shopType must be a non-empty string -- the K9 Supply shop will NOT be registered.')
        return false
    end

    if type(shopConfig.items) ~= 'table' or #shopConfig.items == 0 then
        print('[John-K9] equipmentshop: WARNING: Config.K9EquipmentShop.items must be a non-empty array -- the K9 Supply shop will NOT be registered (there would be nothing to sell).')
        return false
    end

    -- currencyItem defaults to ox_inventory's own 'money' item (its built-in
    -- cash item, NOT a banking resource -- see this file's header) when
    -- unset, matching ox_inventory's own per-item default. Warned about
    -- regardless, since a renamed/removed cash item would make EVERY item
    -- in this shop silently unpurchasable with no explanation.
    local currencyItem = shopConfig.currencyItem
    if type(currencyItem) ~= 'string' or currencyItem == '' then
        currencyItem = 'money'
    end
    WarnIfItemMissing(currencyItem, 'Config.K9EquipmentShop.currencyItem')

    -- Build the ox_inventory `inventory` array, SKIPPING (never
    -- substituting a fake/zero-price placeholder for) any entry that fails
    -- validation or does not resolve against this server's own ox_inventory
    -- item registry -- see WarnIfItemMissing's own doc comment for why a
    -- skip, not a hard failure of the whole shop, is the right response to
    -- one bad entry among several good ones.
    local inventoryItems = {}
    for i, entry in ipairs(shopConfig.items) do
        local configPath = ('Config.K9EquipmentShop.items[%d]'):format(i)
        if type(entry) ~= 'table' then
            print(('[John-K9] equipmentshop: WARNING: %s is not a table -- skipped.'):format(configPath))
        elseif type(entry.price) ~= 'number' or entry.price ~= entry.price or entry.price < 0 then
            print(('[John-K9] equipmentshop: WARNING: %s.price must be a non-negative number (got %s) -- skipped.'):format(configPath, tostring(entry and entry.price)))
        elseif WarnIfItemMissing(entry.name, configPath .. '.name') then
            inventoryItems[#inventoryItems + 1] = {
                name = entry.name,
                price = entry.price,
                -- Only set `currency` when it differs from ox_inventory's
                -- own default -- an explicit per-item override is
                -- supported (a future config could price one item in a
                -- different item-currency) but not required for the common
                -- case.
                currency = (entry.currency ~= nil and entry.currency ~= currencyItem) and entry.currency or nil,
            }
        end
    end

    if #inventoryItems == 0 then
        print('[John-K9] equipmentshop: WARNING: every configured item failed validation or does not exist in this server\'s ox_inventory -- the K9 Supply shop will NOT be registered (there is nothing left to sell). See the WARNING lines above for the exact item(s) to fix. docs/ox_inventory_items.lua in this resource has ready-to-paste entries for every K9 item.')
        return false
    end

    -- Job restriction, derived from THIS resource's own already-existing
    -- Config.Departments -- no new config table needed. `0` (grade 0) means
    -- "any grade in this department," matching this resource's own
    -- "K9-eligible department membership alone, no rank floor" posture for
    -- everything else that gates on Config.Departments membership.
    local groups = nil
    if type(Config.Departments) == 'table' then
        groups = {}
        for jobName in pairs(Config.Departments) do
            groups[jobName] = 0
        end
        if next(groups) == nil then groups = nil end
    end

    -- ROUTED THROUGH K9Compat.Get('inventory') (this pass, coder-backend) --
    -- shared/compat/core.lua's RequiredMethods.inventory.server.RegisterShop
    -- -- never a direct `exports.ox_inventory:RegisterShop` call. The
    -- adapter's own argument shape is `{ label, items, groups }` (NOT
    -- ox_inventory's native `{ name, inventory, groups }`) -- see
    -- shared/compat/inventory.lua's own RegisterShop doc comment, which
    -- translates this shape onto whatever the detected backend actually
    -- expects (ox_inventory's own `{ name = shopDetails.label, inventory =
    -- shopDetails.items, groups = shopDetails.groups }` for that adapter).
    -- `K9Compat.Get('inventory').RegisterShop` already pcall-wraps the
    -- underlying export call (BuildSafeAdapter, shared/compat/core.lua) and
    -- returns a plain boolean success/failure -- this file no longer needs
    -- its own pcall here, but also no longer has access to the underlying
    -- export's own error text on failure (a real, disclosed loss of detail
    -- in this file's own warning message below, traded for working on
    -- whatever inventory backend an operator actually runs -- reported to
    -- main as part of this pass).
    local shopLabel = type(shopConfig.label) == 'string' and shopConfig.label ~= '' and shopConfig.label or 'K9 Supply'
    local registered = K9Compat.Get('inventory').RegisterShop(shopConfig.shopType, {
        label = shopLabel,
        items = inventoryItems,
        groups = groups,
        -- Deliberately NO `locations`/`targets` field -- see this
        -- file's header, point 2, for why: this resource's OWN
        -- client/equipmentshop.lua builds the physical interaction
        -- point instead, via ox_target, which is the only way an
        -- externally-registered shop actually becomes reachable.
    })

    if not registered then
        print('[John-K9] equipmentshop: WARNING: RegisterShop failed -- the K9 Supply shop is NOT available this session. This can mean no compatible inventory backend is currently detected/running (see /k9compat, if enabled), or the detected backend rejected this shop\'s shape.')
        return false
    end

    print(('[John-K9] equipmentshop: K9 Supply shop registered (%d/%d configured items resolved).'):format(#inventoryItems, #shopConfig.items))
    return true
end

--- Boot entry point -- unconditionally routed through
--- ActivateEquipmentShopIfEnabled (real body far below, in this file's own
--- "EQUIPMENT SHOP ITEM CATALOG" section, once its own dependencies --
--- the two purchase-enforcement hooks and the item-catalog overlay --
--- exist) rather than calling RegisterEquipmentShopFromConfig directly, so
--- boot-time-on and a later runtime toggle-on share the exact same
--- hooks-first activation gate -- see this file's own "RUNTIME TOGGLE-ON
--- FORWARD DECLARATIONS" header above for the full "why" writeup.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end
    ActivateEquipmentShopIfEnabled()
end)

-- ======================================================================
-- RUNTIME SHOP LOCATIONS -- see this file's own header "RUNTIME SHOP
-- LOCATIONS" section for the full design/scope/privilege writeup. Every
-- helper and callback below is a SELF-CONTAINED addition: it shares no
-- local with the RegisterShop section above (other than reading the same
-- `Config.K9EquipmentShop` table) and can be read/reviewed independently
-- of it.
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- Server-authoritative: may `source` add/move/remove a runtime shop
--- location right now? Re-resolved fresh on every call, per this task's
--- explicit "re-verifies IsHighCommand() SERVER-SIDE at the point of the
--- action, never trusting a flag the NUI sent" instruction -- never
--- cached, never trusts a client claim of authority. Mirrors
--- server/runtimecontrol.lua's own CanManageRuntimeControl/
--- CanManageTabletTheme SHAPE as an independent, self-contained copy (see
--- this file's own header for why this is not a shared call into that
--- file) -- kept under its OWN permission key
--- ('k9.equipmentshoplocations', not 'k9.runtimecontrol'/'k9.tablettheme')
--- so a server could one day grant "may edit shop locations" without also
--- granting either of those, matching that file's own "kept SEPARATE"
--- reasoning for its own two keys.
--- @param source number
--- @return boolean, string? citizenid -- citizenid is returned when known, for the caller to use as the audit `changed_by`
local function CanManageShopLocations(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.equipmentshoplocations') == true then
        return true, citizenid
    end
    return false, citizenid
end

--- Console log line for every mutating call below -- matches
--- server/runtimecontrol.lua's/server/admin.lua's own "%s ran %s(%s) ->
--- %s" audit format exactly.
--- @param source number
--- @param action string
--- @param detail string
--- @param outcome string
local function LogShopLocationAudit(source, action, detail, outcome)
    local citizenid = ResolveCitizenId(source)
    local whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    print(('[John-K9] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

-- K9Store MIGRATION NOTE: this file used to hand-roll its own SafeQuery/
-- SafeWrite/SafeInsert pcall-wrapped MySQL.* helpers here (the ONLY 3 direct
-- MySQL.* call sites this file ever had, backing
-- k9_equipment_shop_locations/k9_equipment_shop_locations_audit -- migration
-- 0011, the newest table in this schema). Now replaced by
-- K9Store.ShopLocation_GetAll/Insert/Update/Delete and
-- K9Store.ShopLocationAudit_Insert (server/datastore.lua), which mirror
-- these exact same bespoke boolean/empty-table-never-throws contracts --
-- see that file's own section for those five functions -- so every call
-- site below needed NO change to its own surrounding logic beyond the
-- function name and argument list itself.

--- Rejects nil, non-number, NaN, and +/-infinity -- never a bare
--- `type(x) == 'number'` alone. Same NaN test as
--- server/runtimecontrol.lua's own SetTunable comment cites
--- (`newValue == newValue`, Lua's standard NaN idiom).
--- @param value any
--- @return boolean
local function IsFiniteNumber(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

--- Strict, small character-level filter for a short player/officer-typed
--- string (a shop ped's model/scenario/label) before it is ever persisted
--- -- a self-contained duplicate of server/runtimecontrol.lua's own
--- IsSafeHeaderTitle, same reasoning: defense in depth on top of whatever
--- renders it later (the tablet's own textContent-only discipline), so a
--- value that somehow reached a different, less careful renderer still
--- could not carry markup or a control sequence. Rejects empty, anything
--- over `maxLen`, and any of `< > & " ' \`` or a control/CR/LF/TAB byte.
--- @param value any
--- @param maxLen number
--- @return boolean
local function IsSafeShortString(value, maxLen)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > maxLen then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

--- In-memory mirror of every row currently in k9_equipment_shop_locations,
--- keyed by that row's own `db:<id>` location key -- populated once at
--- boot (below) and kept in sync by the three mutating callbacks below,
--- rather than re-querying the database on every GetLocations call or
--- every BuildEffectiveLocations build -- same "populated at boot, kept in
--- sync by Set/Reset... rather than re-querying the DB on every tablet
--- open" performance posture as server/runtimecontrol.lua's own
--- ActiveOverrides.
--- @type table<string, { x: number, y: number, z: number, heading: number, model: string?, scenario: string?, label: string? }>
local RuntimeShopLocations = {}

--- @class ShopLocation
--- @field x number
--- @field y number
--- @field z number
--- @field heading number
--- @field model string -- already resolved against Config.K9EquipmentShop.pedModel -- never nil/empty
--- @field scenario string -- already resolved against Config.K9EquipmentShop.pedScenario -- '' means "no scenario", never nil
--- @field label string -- already resolved against Config.K9EquipmentShop.label -- never nil/empty

--- Resolves ONE location's model/heading/scenario/label against this
--- shop's own pedModel/pedHeading/pedScenario/label defaults. Shared by
--- BOTH a Config.K9EquipmentShop.locations entry and a
--- k9_equipment_shop_locations database row below -- both use the exact
--- same optional-field-with-shop-wide-fallback shape, just sourced from a
--- Lua table vs. a SQL row (where a SQL NULL already reads back as Lua
--- `nil` via oxmysql, so no separate NULL-handling branch is needed here).
--- `scenario` distinguishes three states, matching config.lua's own
--- per-location `scenario = false` convention: `false` OR the literal
--- empty string `''` (the database's own way of persisting that same
--- "explicitly no scenario" choice, since SQL has no boolean-false-vs-
--- string type to reuse instead) means "no scenario, even if the shop-wide
--- default has one"; a non-empty string is a real override; `nil` (never
--- set at all) falls through to the shop-wide default.
--- @param x number @param y number @param z number
--- @param heading number? @param model string? @param scenario string|false|nil @param label string?
--- @param shopConfig table -- Config.K9EquipmentShop
--- @return ShopLocation
local function ResolveLocation(x, y, z, heading, model, scenario, label, shopConfig)
    local resolvedHeading = type(heading) == 'number' and heading or shopConfig.pedHeading
    if type(resolvedHeading) ~= 'number' then resolvedHeading = 0.0 end

    local resolvedModel = (type(model) == 'string' and model ~= '') and model or shopConfig.pedModel
    if type(resolvedModel) ~= 'string' or resolvedModel == '' then resolvedModel = 'a_c_shepherd' end

    local resolvedScenario
    if scenario == false or scenario == '' then
        resolvedScenario = ''
    elseif type(scenario) == 'string' then
        resolvedScenario = scenario
    elseif shopConfig.pedScenario == false then
        resolvedScenario = ''
    elseif type(shopConfig.pedScenario) == 'string' and shopConfig.pedScenario ~= '' then
        resolvedScenario = shopConfig.pedScenario
    else
        resolvedScenario = ''
    end

    local resolvedLabel = (type(label) == 'string' and label ~= '') and label
        or (type(shopConfig.label) == 'string' and shopConfig.label ~= '' and shopConfig.label)
        or 'K9 Supply'

    return { x = x, y = y, z = z, heading = resolvedHeading, model = resolvedModel, scenario = resolvedScenario, label = resolvedLabel }
end

--- The full, effective shop location list: every valid
--- Config.K9EquipmentShop.locations entry (keyed `cfg:<index>`) UNIONED
--- with every row currently in RuntimeShopLocations (keyed `db:<id>`) --
--- see this file's header "SCOPE" note for why this is always a pure
--- union, never a conflict to resolve. Safe to call with
--- Config.K9EquipmentShop missing/malformed (returns whatever runtime
--- locations exist, or an empty table) -- this function is read by
--- GetLocations (any connected player) and after every mutation below, so
--- it must never throw regardless of config shape.
--- @return table<string, ShopLocation>
local function BuildEffectiveLocations()
    local out = {}
    local shopConfig = Config.K9EquipmentShop

    if type(shopConfig) == 'table' and type(shopConfig.locations) == 'table' then
        for i, entry in ipairs(shopConfig.locations) do
            if type(entry) == 'table' and IsFiniteNumber(entry.x) and IsFiniteNumber(entry.y) and IsFiniteNumber(entry.z) then
                out['cfg:' .. i] = ResolveLocation(entry.x, entry.y, entry.z, entry.heading, entry.model, entry.scenario, entry.label, shopConfig)
            end
        end
    end

    for key, loc in pairs(RuntimeShopLocations) do
        out[key] = ResolveLocation(loc.x, loc.y, loc.z, loc.heading, loc.model, loc.scenario, loc.label, type(shopConfig) == 'table' and shopConfig or {})
    end

    return out
end

-- Anti-fat-finger cooldown, one shared instance keyed by the calling
-- officer's own source -- covers every mutating callback below. Mirrors
-- server/runtimecontrol.lua's RuntimeControlActionCooldown shape exactly,
-- as a SEPARATE instance (every caller here is already high command or an
-- explicit permission holder, i.e. already trusted -- this guards against
-- a held key or a double-submitted click, not abuse).
local EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS = 1000
local EquipmentShopLocationActionCooldown = NewCooldown(EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS)
EquipmentShopLocationActionCooldown.RegisterPlayerDropped()

-- ======================================================================
-- BOOT -- load every persisted runtime shop location. Deferred to
-- onResourceStart (not this file's own raw top-level), matching
-- server/runtimecontrol.lua's own documented "every existing DB-dependent
-- startup path in this resource defers its first real query into
-- onResourceStart" convention. Independent of the RegisterShop
-- onResourceStart handler above (AddEventHandler allows any number of
-- handlers for the same event; both run, in registration order, when the
-- event actually fires) -- deliberately NOT folded into that same handler,
-- since loading runtime locations must not depend on shopType/items
-- having validated successfully (a broken `items` list still leaves the
-- shop ped worth spawning at its configured spot; ox_inventory simply has
-- nothing to sell there until that's fixed, same as today).
--
-- UNCONDITIONAL ON Config.Features.K9EquipmentShop (this pass, coder-
-- backend) -- ANOTHER instance of the same "boot-only, does not respond to
-- a runtime toggle" class this pass's own task explicitly asked to hunt
-- for. Before this pass, this ENTIRE handler was gated on the flag being
-- true at boot -- so a server that shipped with the flag off, then turned
-- it on later from the tablet, would activate the shop (see
-- ActivateEquipmentShopIfEnabled above) with RuntimeShopLocations still
-- completely EMPTY: every `db:<id>` location a high-command officer had
-- ever added would be silently missing from BuildEffectiveLocations until
-- a full resource restart reloaded them, even though
-- equipmentShopGetLocations/AddLocation/MoveLocation/RemoveLocation were
-- already always registered and already re-checked the flag live. Loading
-- this small, harmless (no ox_inventory call, no player-visible effect on
-- its own -- equipmentShopGetLocations and friends remain the only thing
-- that ever exposes this table, and THEY still gate on the flag every
-- single call, unchanged) in-memory cache regardless of the flag closes
-- that gap for free. The diagnostic print stays flag-gated, not the load
-- itself -- purely so an operator who has never touched this feature does
-- not see a console line about it (matches tests/equipmentshop_spec.lua's
-- own "absence is a clean no-op" print-count assertions), never because
-- the load itself needs the flag to be safe.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (boot-order-race
    -- audit, this pass -- same fix already shipped for
    -- server/certtiers.lua/server/permissionkeycatalog.lua/server/xptiers.lua/
    -- server/k9profiles.lua, simply missed here when it landed for those
    -- four -- see server/datastore.lua's own "BOOT-ORDER SETTLEMENT" header
    -- for the exact race this closes). This handler is UNCONDITIONAL on
    -- Config.Features.K9EquipmentShop (see this section's own header above
    -- for why), so unlike the flag-gated activation handler elsewhere in
    -- this file, it runs this read on EVERY boot, making it the single
    -- most exposed instance of this race in this file. Without this,
    -- K9Store.ShopLocation_GetAll() below (a narrower SELECT than the
    -- columns k9_equipment_shop_locations is checked against) could run
    -- against a foreign table the full probe would correctly reject as a
    -- collision, during the one window before that probe's own yielding
    -- query has returned. On a `false` return (the probe genuinely had not
    -- settled within the wait budget), this skips the read entirely for
    -- this boot -- RuntimeShopLocations simply stays empty, identical to
    -- what a genuinely empty table would produce, and the next successful
    -- location add/move/remove (or a restart once the check has had time
    -- to finish) re-syncs it as normal.
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] equipmentshop: the schema-collision check had not finished within its wait budget -- no runtime shop locations loaded this session (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next successful location edit (or a restart once the check has had time to finish) will pick up any real persisted locations.')
        return
    end

    local rows = K9Store.ShopLocation_GetAll()
    for _, row in ipairs(rows) do
        RuntimeShopLocations['db:' .. row.id] = {
            x = row.x, y = row.y, z = row.z, heading = row.heading,
            model = row.model, scenario = row.scenario, label = row.label,
        }
    end

    if Config.Features and Config.Features.K9EquipmentShop == true then
        print(('[John-K9] equipmentshop.lua: %d runtime shop location(s) loaded from the database.'):format(#rows))
    end
end)

-- ======================================================================
-- PER-PERSON FEATURE CONTROL FOR K9EquipmentShop -- CORRECTED, THIS PASS.
--
-- A PRIOR analysis (this exact comment block, until this pass) concluded
-- K9EquipmentShop was STRUCTURALLY EXEMPT from a per-person block/grant,
-- reasoning that "the actual transaction never reaches this file's own
-- code at all" and that no callback/event/hook existed for this file to
-- gate a purchase attempt with. THAT REASONING WAS WRONG, not merely
-- superseded: re-reading ox_inventory's own real source
-- (modules/shops/server.lua, modules/hooks/server.lua) this pass found
-- that ox_inventory DOES fire exactly such a hook -- `registerHook('openShop',
-- ...)` (and separately `'buyItem'`) -- per attempt, server-side, with a
-- veto (`return false`) that genuinely prevents the shop from ever
-- opening for that one player. This resource's own K9Compat inventory
-- adapter already exposes a fully generic `RegisterHook(eventName,
-- callback)` pass-through (shared/compat/inventory.lua) capable of
-- registering exactly this. A real per-person `block.K9EquipmentShop` /
-- `feature.K9EquipmentShop` gate is therefore both possible and NOW
-- IMPLEMENTED -- see this file's own "EQUIPMENT SHOP ITEM CATALOG"
-- section below for IsEquipmentShopPermittedForCitizenId and the two
-- RegisterEquipmentShopOpenShopBlockHook/
-- RegisterEquipmentShopBuyItemRequirementHook registrations that gate
-- with it. The `equipmentShopGetLocations` "security theater" argument
-- (point 2 of the deleted analysis) was never wrong on its own terms and
-- remains true -- that specific read callback is still not a meaningful
-- place to gate anything -- but it was never the ONLY candidate, and
-- ox_inventory's own openShop/buyItem hooks are.
-- ======================================================================

-- ======================================================================
-- CALLBACKS -- see this file's header "RUNTIME SHOP LOCATIONS" section
-- for the full contract. ALWAYS registered, unconditionally -- each
-- re-checks Config.Features.K9EquipmentShop live, on every call, matching
-- this resource's "live"-tier convention (server/runtimecontrol.lua's own
-- header, "THE ENGINE CONSTRAINT").
-- ======================================================================

lib.callback.register('john-k9:server:equipmentShopGetLocations', function(source)
    if type(source) ~= 'number' or source <= 0 then
        return { ok = false, reason = 'invalid_source' }
    end
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end
    return { ok = true, locations = BuildEffectiveLocations() }
end)

lib.callback.register('john-k9:server:equipmentShopAddLocation', function(source, location)
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageShopLocations(source)
    if not authorized then
        LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not EquipmentShopLocationActionCooldown.Consume(source, EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(location) ~= 'table' or not IsFiniteNumber(location.x) or not IsFiniteNumber(location.y) or not IsFiniteNumber(location.z) then
        LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_coords')
        return { ok = false, reason = 'invalid_coords' }
    end

    local heading = 0.0
    if location.heading ~= nil then
        if not IsFiniteNumber(location.heading) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_heading')
            return { ok = false, reason = 'invalid_heading' }
        end
        heading = location.heading % 360
    end

    local model = nil
    if location.model ~= nil then
        if not IsSafeShortString(location.model, 64) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_model')
            return { ok = false, reason = 'invalid_model' }
        end
        model = location.model
    end

    local scenario = nil
    if location.scenario == false then
        scenario = ''
    elseif location.scenario ~= nil then
        if not IsSafeShortString(location.scenario, 64) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_scenario')
            return { ok = false, reason = 'invalid_scenario' }
        end
        scenario = location.scenario
    end

    local label = nil
    if location.label ~= nil then
        if not IsSafeShortString(location.label, 100) then
            LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'invalid_label')
            return { ok = false, reason = 'invalid_label' }
        end
        label = location.label
    end

    local insertOk, newId = K9Store.ShopLocation_Insert(location.x, location.y, location.z, heading, model, scenario, label, citizenid or 'unknown')
    if not insertOk then
        LogShopLocationAudit(source, 'equipmentShopAddLocation', 'n/a', 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    local locationKey = 'db:' .. newId
    RuntimeShopLocations[locationKey] = { x = location.x, y = location.y, z = location.z, heading = heading, model = model, scenario = scenario, label = label }

    K9Store.ShopLocationAudit_Insert(newId, 'add', location.x, location.y, location.z, heading, model, scenario, label, citizenid or 'unknown')

    LogShopLocationAudit(source, 'equipmentShopAddLocation', ('key=%s x=%.2f y=%.2f z=%.2f'):format(locationKey, location.x, location.y, location.z), 'ok')

    local effective = BuildEffectiveLocations()
    TriggerClientEvent('john-k9:client:equipmentShopLocationsUpdated', -1, effective)

    return { ok = true, locationKey = locationKey, locations = effective }
end)

lib.callback.register('john-k9:server:equipmentShopMoveLocation', function(source, locationKey, updates)
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageShopLocations(source)
    if not authorized then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(tostring(locationKey)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not EquipmentShopLocationActionCooldown.Consume(source, EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    -- Only ever valid on a `db:<id>` key -- see this file's header "SCOPE"
    -- note. A `cfg:<n>` key (or any other malformed string) is refused
    -- here, never silently accepted and dropped.
    local dbId = type(locationKey) == 'string' and locationKey:match('^db:(%d+)$')
    local current = dbId and RuntimeShopLocations[locationKey]
    if not dbId or not current then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(tostring(locationKey)), 'invalid_key')
        return { ok = false, reason = 'invalid_key' }
    end

    if type(updates) ~= 'table' then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_payload')
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Merge onto the CURRENT row (never onto an empty table) -- an admin
    -- moving only x/y/z must not accidentally blank model/scenario/label
    -- back to nil, mirroring server/runtimecontrol.lua's own SetTheme
    -- merge-then-validate discipline.
    local merged = { x = current.x, y = current.y, z = current.z, heading = current.heading, model = current.model, scenario = current.scenario, label = current.label }

    if updates.x ~= nil or updates.y ~= nil or updates.z ~= nil then
        local x = updates.x ~= nil and updates.x or current.x
        local y = updates.y ~= nil and updates.y or current.y
        local z = updates.z ~= nil and updates.z or current.z
        if not IsFiniteNumber(x) or not IsFiniteNumber(y) or not IsFiniteNumber(z) then
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_coords')
            return { ok = false, reason = 'invalid_coords' }
        end
        merged.x, merged.y, merged.z = x, y, z
    end

    if updates.heading ~= nil then
        if not IsFiniteNumber(updates.heading) then
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_heading')
            return { ok = false, reason = 'invalid_heading' }
        end
        merged.heading = updates.heading % 360
    end

    -- For model/scenario/label: `false` explicitly resets that field back
    -- to nil (i.e. "use the shop-wide default again"), a non-empty valid
    -- string overrides it, anything else is refused outright.
    if updates.model ~= nil then
        if updates.model == false then
            merged.model = nil
        elseif IsSafeShortString(updates.model, 64) then
            merged.model = updates.model
        else
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_model')
            return { ok = false, reason = 'invalid_model' }
        end
    end

    if updates.scenario ~= nil then
        if updates.scenario == false then
            merged.scenario = ''
        elseif IsSafeShortString(updates.scenario, 64) then
            merged.scenario = updates.scenario
        else
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_scenario')
            return { ok = false, reason = 'invalid_scenario' }
        end
    end

    if updates.label ~= nil then
        if updates.label == false then
            merged.label = nil
        elseif IsSafeShortString(updates.label, 100) then
            merged.label = updates.label
        else
            LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'invalid_label')
            return { ok = false, reason = 'invalid_label' }
        end
    end

    local wrote = K9Store.ShopLocation_Update(merged.x, merged.y, merged.z, merged.heading, merged.model, merged.scenario, merged.label, citizenid or 'unknown', tonumber(dbId))
    if not wrote then
        LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s'):format(locationKey), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    RuntimeShopLocations[locationKey] = merged

    K9Store.ShopLocationAudit_Insert(tonumber(dbId), 'move', merged.x, merged.y, merged.z, merged.heading, merged.model, merged.scenario, merged.label, citizenid or 'unknown')

    LogShopLocationAudit(source, 'equipmentShopMoveLocation', ('key=%s x=%.2f y=%.2f z=%.2f'):format(locationKey, merged.x, merged.y, merged.z), 'ok')

    local effective = BuildEffectiveLocations()
    TriggerClientEvent('john-k9:client:equipmentShopLocationsUpdated', -1, effective)

    return { ok = true, locations = effective }
end)

lib.callback.register('john-k9:server:equipmentShopRemoveLocation', function(source, locationKey)
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageShopLocations(source)
    if not authorized then
        LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(tostring(locationKey)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not EquipmentShopLocationActionCooldown.Consume(source, EQUIPMENT_SHOP_LOCATION_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    -- Only ever valid on a `db:<id>` key -- see this file's header "SCOPE"
    -- note. Removing a `cfg:<n>` location is not supported from here at
    -- all (never silently accepted and ignored) -- config.lua stays the
    -- one source of truth for its own entries.
    local dbId = type(locationKey) == 'string' and locationKey:match('^db:(%d+)$')
    local existing = dbId and RuntimeShopLocations[locationKey]
    if not dbId or not existing then
        LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(tostring(locationKey)), 'invalid_key')
        return { ok = false, reason = 'invalid_key' }
    end

    local wrote = K9Store.ShopLocation_Delete(tonumber(dbId))
    if not wrote then
        LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(locationKey), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    K9Store.ShopLocationAudit_Insert(tonumber(dbId), 'remove', existing.x, existing.y, existing.z, existing.heading, existing.model, existing.scenario, existing.label, citizenid or 'unknown')

    RuntimeShopLocations[locationKey] = nil

    LogShopLocationAudit(source, 'equipmentShopRemoveLocation', ('key=%s'):format(locationKey), 'ok')

    local effective = BuildEffectiveLocations()
    TriggerClientEvent('john-k9:client:equipmentShopLocationsUpdated', -1, effective)

    return { ok = true, locations = effective }
end)

-- ======================================================================
-- EQUIPMENT SHOP ITEM CATALOG (this pass). Owner's own words: "give high
-- command real control over the equipment shop" -- the RUNTIME SHOP
-- LOCATIONS section above already let the tablet add/move/remove WHERE a
-- shop ped stands; this section is the other half the owner's own ask
-- named explicitly: WHICH items are sold, at what price, in what order,
-- and under what certification-tier/specialization purchase requirement
-- -- all of which previously lived ONLY in Config.K9EquipmentShop.items
-- and needed a file edit plus a restart to change.
--
-- ======================================================================
-- THE PATTERN THIS FOLLOWS, ON EXPLICIT INSTRUCTION: server/certtiers.lua
-- ======================================================================
-- Exactly the same shape as that file's tier catalog: config.lua stays
-- the shipped DEFAULT item list; `k9_equipment_shop_items`
-- (sql/migrations/0014_create_k9_equipment_shop_items.sql) layers
-- high-command RUNTIME EDITS on top, keyed by `item_key` (an ox_inventory
-- item NAME). THE DATABASE WINS per key. A tombstoned row (`deleted = 1`)
-- excludes that key from the live, sellable catalog entirely, whether it
-- originated in Config.K9EquipmentShop.items or was created purely at
-- runtime from the tablet. See RefreshEquipmentShopItemCatalog below for
-- the exact merge algorithm -- byte-for-byte the same shape as
-- server/certtiers.lua's own RefreshCertificationTierCatalog.
--
-- WHY NO SEPARATE CAPABILITIES-STYLE SIBLING TABLE: see migration 0014's
-- own header, "WHY NO SEPARATE CAPABILITIES-STYLE SIBLING TABLE" -- an
-- item's purchase requirement is AT MOST one certification tier AND AT
-- MOST one specialization (an AND of at most one each, never an open
-- set), which two plain nullable columns represent completely.
--
-- ======================================================================
-- THE REAL ITEM SHAPE (confirmed by reading this file's own pre-existing
-- REGISTRATION section above, top to bottom, before writing any of this):
-- Config.K9EquipmentShop.items is `{ { name: string, price: number,
-- currency: string? }, ... }` -- a bare array, no `label` field of its
-- own (ox_inventory's own Items(name).label is what the shop UI has
-- always shown), no `order` field of its own (array index IS the order),
-- and NO purchase-requirement concept anywhere in this resource before
-- this pass. This section adds `label` (an OPTIONAL display override),
-- `sortOrder` (editable via Reorder only, exactly like
-- server/certtiers.lua's `ordinal`), and `requiredTierKey`/
-- `requiredSpecialization` (both optional, both independently nullable)
-- as NEW, purely additive, database-only concepts layered on top of the
-- exact same three config fields that have always existed.
--
-- ======================================================================
-- PRICE VALIDATION -- ECONOMY CODE, TREATED AS HOSTILE TERRITORY
-- ======================================================================
-- IsValidShopItemPrice below rejects: non-number, NaN (`value ~= value`),
-- +/-infinity, negative, fractional (`value ~= math.floor(value)` -- a
-- currency unit is a whole number in this resource; ox_inventory itself
-- computes `count * price` as a plain Lua number with no rounding step of
-- its own, so a fractional price here would silently produce a fractional
-- total the player-facing UI was never designed to render), and anything
-- above MAX_SHOP_ITEM_PRICE (an "absurdly large" ceiling, matching
-- server/certtiers.lua's own MAX_TIERS-style belt-and-suspenders cap
-- philosophy -- a high-command account is already highly trusted, but an
-- unbounded value is still an unforced footgun, e.g. a fat-fingered extra
-- zero making an item cost more than a 64-bit signed value could ever pay
-- out through ox_inventory's own item-count arithmetic).
--
-- ZERO IS EXPLICITLY ALLOWED (a legitimate free item) -- THIS PASS'S OWN
-- DISCLOSED DECISION, not left ambiguous: the ORIGINAL, pre-existing
-- REGISTRATION loop above this section has ALWAYS accepted `price = 0`
-- (its own guard is `entry.price < 0`, never `<= 0`) -- rejecting zero
-- here, in the NEW overlay validator, while the untouched original path
-- continues to accept it for a config-sourced item, would be an
-- inconsistency this pass refuses to introduce. A high-command officer
-- who wants to give away an item for free (e.g. a starter kit) can.
--
-- ======================================================================
-- THE PURCHASE PATH -- WAS IT ALREADY SAFE? YES, CONFIRMED AGAINST REAL
-- ox_inventory SOURCE (overextended/ox_inventory, main branch,
-- modules/shops/server.lua, fetched and read directly this pass -- same
-- "verify before believing" discipline this resource's own COORDINATION
-- notes require).
-- ======================================================================
-- Before this pass, this resource had NO purchase callback of its own at
-- all (this file's own pre-existing header already states this
-- plainly: "no RegisterNetEvent/lib.callback of its own for the actual
-- shop transaction... every player-facing interaction already flows
-- entirely through ox_inventory's own already-security-reviewed
-- ox_inventory:openShop/buyItem callbacks"). Confirmed, line by line, this
-- pass: ox_inventory's OWN `buyItem` callback captures `fromData =
-- shop.items[data.fromSlot]` (a reference into `Shops[shopType]`, a table
-- this resource writes ONLY via RegisterShop) and computes `price = count
-- * fromData.price` -- a fully SERVER-SIDE value, read from
-- ox_inventory's own internal registry, at the moment of purchase, NEVER
-- accepted from the client's own request payload (`data.fromSlot` is
-- only ever a SLOT INDEX, never a price). The client is never trusted for
-- a price, and no price is ever cached client-side and sent back. This
-- was ALREADY SAFE before this pass, and remains so -- this pass adds NO
-- new purchase callback of its own, on the identical "would be pure
-- duplication with a second place to get the authorization checks wrong"
-- reasoning this file's own header already gives.
--
-- WHAT THIS PASS DOES CHANGE: `Shops[shopType].items` used to be written
-- ONCE, at this resource's own onResourceStart, straight from
-- `Config.K9EquipmentShop.items` -- an EDIT made via the tablet would
-- therefore not take effect until a restart. LiveRefreshRegisteredShop
-- below re-calls `K9Compat.Get('inventory').RegisterShop` (the SAME
-- export the original REGISTRATION section already calls) after every
-- successful item edit, so a price/label/order/requirement change is
-- live for every already-connected player immediately -- see "THE
-- EDIT/PURCHASE RACE" below for why this is safe to do while a purchase
-- may be in flight.
--
-- ======================================================================
-- THE EDIT/PURCHASE RACE -- CONFIRMED AGAINST REAL SOURCE, NOT ASSUMED
-- ======================================================================
-- ox_inventory's own `registerShopType` (the function
-- `exports.ox_inventory:RegisterShop` ultimately calls) does a single,
-- UNCONDITIONAL, NON-YIELDING Lua table assignment: `Shops[shopType] =
-- { ... }` -- a full overwrite, never a merge, never a partial mutation
-- in place. Two consequences, both confirmed by reading that function
-- directly:
--   1. There is NO intermediate state a concurrent reader could ever
--      observe -- `Shops[shopType]` is, at every instant, either the
--      FULLY OLD table or the FULLY NEW one, never a half-old/half-new
--      mix. A "torn price" (part of one transaction computed against the
--      old price, the rest against the new one) is structurally
--      impossible, not merely unlikely.
--   2. `buyItem`'s own callback captures `local shop = ... Shops[shopType]`
--      and `fromData = shop.items[data.fromSlot]` as its OWN local
--      variables at the very top of a single, synchronous Lua callback
--      invocation, with no `await`/yield point between that capture and
--      the final `removeCurrency(playerInv, currency, price)` call --
--      FXServer's cooperative Lua scheduler cannot interleave a
--      RegisterShop call from a totally different resource invocation in
--      the MIDDLE of that one callback's own execution (a resource's Lua
--      VM only yields at an explicit await point, and this callback has
--      none between capture and charge).
-- Net effect: whichever price was live in `Shops[shopType]` at the
-- instant a given purchase attempt captured it is the price used for
-- that ENTIRE transaction, start to finish, consistently -- "which price
-- applies" has a clean, non-racy answer BY CONSTRUCTION of ox_inventory's
-- own execution model, not because this file adds a lock of its own
-- around ox_inventory's internal state (which this file has no access to
-- lock in the first place -- `Shops` is a `local` inside ox_inventory's
-- own resource).
--
-- WHAT THIS FILE'S OWN MUTEX (ShopItemEditMutex, below) THEREFORE ACTUALLY
-- PROTECTS: not that structurally-already-safe race, but the ONE race
-- this file's OWN code could otherwise produce -- two concurrent
-- high-command EDITS to the SAME item_key (e.g. one officer tombstones an
-- item while another is mid-upsert of that exact key), which could
-- otherwise interleave across the `MySQL.await` yield points inside
-- K9Store.ShopItem_Upsert/UpdateSortOrder/Tombstone and produce a lost
-- update or an inconsistent audit trail -- the SAME class of hazard
-- server/certtiers.lua's own header documents for TierEditMutex ("THE
-- DELETE-VS-ASSIGN RACE"), applied here to this file's own writes.
-- ShopItemsUpsert/Reorder/Delete all acquire this mutex, keyed by
-- item_key, around their own check-then-write critical section, exactly
-- mirroring TierEditMutex's own usage.
--
-- CANNOT DEADLOCK AGAINST TierEditMutex: ShopItemEditMutex is a SEPARATE
-- `NewMutex()` instance, keyed by a disjoint string space (ox_inventory
-- item names, never a certification tier key), and no code path in this
-- file ever acquires TierEditMutex, nor does any code path in
-- server/certtiers.lua ever acquire ShopItemEditMutex -- two independent
-- locks with no cross-acquisition anywhere in either direction cannot
-- form a lock-ordering cycle, which is the only way two mutexes can ever
-- deadlock each other.
--
-- ======================================================================
-- TOMBSTONE, NOT HARD-DELETE -- AND WHY THIS FILE NEEDS NO REFERENCE-COUNT
-- CHECK BEFORE ALLOWING ONE (UNLIKE server/certtiers.lua's DeleteTier)
-- ======================================================================
-- server/certtiers.lua's DeleteTier must refuse a delete while ANY
-- k9_certifications row still references the tier key, because deleting
-- that key out from under an existing reference would strand a REAL,
-- persisted row pointing at nothing. This resource keeps NO row of its
-- own that references an item_key at all -- ox_inventory owns the actual
-- player inventory grant (an item sitting in someone's bag is
-- ox_inventory's own row, not this resource's), and no OTHER item's
-- `required_tier_key`/`required_specialization` ever references another
-- item's `item_key` (those two columns reference a CERTIFICATION TIER /
-- SPECIALIZATION key, never another shop item). There is therefore
-- nothing this file's own schema could ever strand by tombstoning an
-- item_key -- ShopItemsDelete tombstones unconditionally once
-- authorization/validation pass, with no reference-count read at all.
-- Tombstoning (never a real DELETE) is still the right choice regardless,
-- for the SAME reason migration 0010 gives for tiers: a config-sourced
-- item_key has no row to delete FROM until first touched, so "remove
-- this item" has to mean "record that this key is now suppressed" -- and
-- it keeps a removed item from silently becoming buyable again the
-- moment a stale in-memory catalog snapshot elsewhere is rebuilt (a
-- tombstone row always wins over a config default for the same key, by
-- construction of the merge in RefreshEquipmentShopItemCatalog).
--
-- ======================================================================
-- PURCHASE REQUIREMENTS -- REAL ENFORCEMENT, NOT A COSMETIC FIELD
-- ======================================================================
-- server/certtiers.lua's own header ("CAPABILITY COMPOSITION", the
-- `specialized_equipment_access` capability) investigated wiring a
-- per-item purchase gate to this exact shop and found it needed "more
-- than a diff": ox_inventory's whole-shop RegisterShop/openShop/buyItem
-- design has no per-player, per-item ACL primitive built into the shop
-- registration shape itself. That finding is still correct for the shop
-- REGISTRATION shape -- but this pass found the ACTUAL enforcement point
-- that finding was not looking for: ox_inventory ALSO fires a
-- `registerHook('buyItem', ...)` event, PER PURCHASE ATTEMPT, with the
-- real `source`, `shopType` and `itemName` -- BEFORE currency is
-- deducted or the item is granted -- and a hook that returns the literal
-- `false` VETOES that one purchase outright (confirmed directly against
-- ox_inventory's own modules/hooks/server.lua: `TriggerEventHooks`
-- returns `hooks.success = false` the instant any registered hook returns
-- `false`, and `buyItem`'s own callback checks `if not hooks.success ...
-- then return false end` BEFORE calling `removeCurrency`/`SetSlot` at
-- all). This is exactly the "resource's own buy-item callback in front
-- of ox_inventory" mechanism server/certtiers.lua's header proposed as a
-- hypothetical -- except it needs no NEW callback of this resource's own
-- at all: `RegisterEquipmentShopBuyItemRequirementHook` below is a PURE
-- ADDITIVE HOOK on ox_inventory's OWN existing, already-reviewed purchase
-- path, never a parallel purchase pipeline, never a duplicate
-- currency-deduction/item-grant implementation of this file's own (which
-- would have needed a server-side AddItem export this resource's own
-- K9Compat inventory contract does not currently offer at all -- see
-- shared/compat/core.lua's RequiredMethods.inventory.server list;
-- confirmed absent before choosing this design, not discovered by
-- trial and error).
--
-- FAILS CLOSED ON AN UNRESOLVABLE BUYER IDENTITY, DELIBERATELY DIFFERENT
-- FROM TierCapabilityPermits' OWN DEFAULT-PERMISSIVE POSTURE: server/
-- certtiers.lua's TierCapabilityPermits is a FLOOR laid underneath THREE
-- other, already-independently-gating checks (Config.Features /
-- Config.FeatureControl / HasK9Access) -- it fails open on an
-- unclassifiable citizenid specifically because those three other gates
-- remain the real authority and TierCapabilityPermits must never WIDEN
-- what they already decided. The buyItem hook below is different in
-- kind: for an item an admin has explicitly gated, THIS hook is the ONLY
-- check standing between "no requirement" and "sold" -- there is no
-- other, independent gate underneath it for a restricted item. An
-- unresolvable buyer identity here is therefore treated as a DENIAL, not
-- an allow -- the conservative direction for the one and only gate a
-- purchase must pass.
--
-- REQUIREMENT SEMANTICS: an item may carry a `requiredTierKey` AND a
-- `requiredSpecialization` SIMULTANEOUSLY -- THIS PASS'S OWN DISCLOSED
-- DECISION: both, when both are set, are ANDed (a purchaser must satisfy
-- EVERY configured requirement, never merely one of several), matching
-- how every other multi-condition gate in this resource composes
-- (HasK9Access's own three routes are the one documented OR-composition
-- in this codebase, and that is a DIFFERENT question -- "is there any way
-- in" -- from "does this specific purchase meet every requirement its
-- own seller attached to it").
--
-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- THE GAP FOUND BY
-- tests/customizationregistry_spec.lua's OWN DRIFT GUARD (this pass,
-- addressed, not merely disclosed)
-- ======================================================================
-- Config.Features.K9EquipmentShop (server-wide on/off) already existed;
-- what did not, anywhere in this file, was a `block.K9EquipmentShop` /
-- `feature.K9EquipmentShop` per-person path -- the SAME 4-step
-- Config.FeatureControl resolution every other blockable feature in this
-- resource already implements (server/pursuitsprint.lua's own
-- IsPursuitSprintPermittedForCitizenId is THE canonical shape;
-- server/fetch.lua's IsFetchMechanicPermittedForCitizenId and
-- server/combat.lua's IsCombatFeaturePermittedForCitizenId are both
-- byte-for-byte copies of that same shape). IsEquipmentShopPermittedForCitizenId
-- below is this file's own copy, same four steps, same fail-closed
-- posture on missing machinery (step 2's block check simply cannot fire
-- when HasPermission is absent -- nobody could ever hold a block in that
-- case, which is a fully safe default-permissive outcome exactly like
-- every sibling copy's own doc comment states; step 3's grant check FAILS
-- CLOSED -- DENIES -- when RequireGrant demands an active grant this
-- resource is structurally unable to verify).
--
-- WHERE THIS IS GATED -- THE POINT THIS RESOURCE ACTUALLY "DECIDES TO
-- OPEN THE SHOP", FOUND BY READING REAL ox_inventory SOURCE, NOT ASSUMED:
-- this resource has no OpenStash-style wrapper of its own for this shop
-- (client/equipmentshop.lua calls `exports.ox_inventory:openInventory`
-- directly -- see this file's own header, point 3) -- so "gate the point
-- where this resource decides to open the shop" cannot mean "add a
-- server round-trip before that client call" without inventing a new
-- client/server contract this pass did not need to invent. ox_inventory
-- ALSO fires a `registerHook('openShop', ...)` event -- CONFIRMED against
-- modules/shops/server.lua this pass: the `openShop` lib.callback
-- computes the FULL hook payload (`source`, `shopType`, ...) and checks
-- `if not hooks.success then return end` BEFORE ever calling
-- `playerInv:openInventory(...)` or setting `playerInv.currentShop` --
-- i.e. a hook returning `false` here means the shop UI NEVER OPENS for
-- that one player, for that one attempt, and nothing else on the server
-- is affected. This is the real "opening" decision point, it is
-- PER-PLAYER (unlike shop registration, which is whole-server, once), and
-- it is SERVER-AUTHORITATIVE (ox_inventory's own callback, not a
-- client-side canInteract predicate a modified client could ignore).
-- RegisterEquipmentShopOpenShopBlockHook below gates exactly this event,
-- filtered to THIS shop's own shopType only (never any other shop on the
-- server) -- and ONLY this event: closing/leaving the shop UI is never
-- touched by anything in this section, matching this resource's
-- established "gate the request that OPENS an effect, never the release
-- that closes one" rule (server/certtiers.lua's own HAZARD 5;
-- server/combat.lua's ValidateCombatRequest doc comment states the
-- identical rule for its own effects). The buyItem hook below ALSO
-- re-checks the same per-person permit, defense-in-depth, in case a
-- future ox_inventory version's openShop hook translation ever silently
-- stops registering while buyItem's own keeps working -- belt-and-
-- suspenders, not the primary enforcement point.
-- ======================================================================

--- Server-authoritative: may `source` edit the K9 equipment shop's item
--- catalog (list/price/label/order/purchase-requirement) right now?
--- Re-resolved fresh on every call, same shape as this file's own
--- CanManageShopLocations immediately above -- kept under its OWN
--- permission key ('k9.equipmentshopitems', not
--- 'k9.equipmentshoplocations') so a server could one day grant "may edit
--- shop item prices" without also granting "may move the shop ped",
--- matching that function's own "kept SEPARATE" reasoning for its two
--- keys.
--- @param source number
--- @return boolean, string? citizenid
local function CanManageShopItems(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.equipmentshopitems') == true then
        return true, citizenid
    end
    return false, citizenid
end

--- PER-PERSON FEATURE CONTROL for K9EquipmentShop -- see this section's
--- own header for the full writeup and for exactly why this is gated at
--- ox_inventory's own `openShop`/`buyItem` hooks rather than inside a
--- shop-registration step this resource has no per-player control over.
--- Step 1 (the global Config.Features.K9EquipmentShop flag) is folded
--- into THIS function, unlike server/fetch.lua's/server/combat.lua's own
--- copies (which rely on a separate "top of file"/caller-side gate) --
--- this function's own two call sites are ox_inventory-fired HOOKS, not a
--- request handler with a natural "top of file" of its own, so keeping
--- the flag check self-contained here is safer than trusting every future
--- call site to remember it independently.
--- WORKFLOW CLARITY FIX (this pass -- "buying, cannot afford, no space,
--- using each item" walkthrough): this function used to return a bare
--- boolean, and BOTH call sites below reported every refusal through the
--- SAME `equipmentshop.blocked_from_shop` text -- "High Command has
--- blocked you from using the K9 equipment shop." -- even for the OTHER
--- two reasons this function can refuse for, neither of which is a
--- personal High Command decision at all: the shop being turned off
--- server-wide (step 1), and this server requiring an explicit
--- feature.K9EquipmentShop grant that this citizenid simply never
--- received (step 3, the RequireGrant branch). Telling someone "High
--- Command has blocked you" for either of those is not just imprecise,
--- it is WRONG -- it blames a person for a decision nobody made about
--- them individually. Every sibling feature with this same three-way
--- shape (server/pursuitsprint.lua, server/findalert.lua) already returns
--- a `reason` string so its call sites can word each refusal accurately
--- instead of blaming a person; this function now does the same. Note the
--- reason SET is two or three wide depending on the file, not uniformly
--- three: pursuitsprint top-level `return`s when its feature flag is off,
--- so a 'feature_disabled' reason is unreachable in its permitted-check,
--- and findalert returns only 'blocked'/'not_granted'. This function does
--- need all three, because Config.Features.K9EquipmentShop is re-read per
--- call rather than gating the file's load.
--- @param citizenid string
--- @return boolean allowed
--- @return string? reason -- 'feature_disabled' | 'blocked' | 'not_granted', present only when allowed is false
local function IsEquipmentShopPermittedForCitizenId(citizenid)
    -- step 1: global off beats everything.
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return false, 'feature_disabled' end

    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.K9EquipmentShop') == true then
        return false, 'blocked' -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.K9EquipmentShop == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        if hasPermissionAvailable and HasPermission(citizenid, 'feature.K9EquipmentShop') == true then
            return true
        end
        return false, 'not_granted'
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow
end

--- Shared by both ox_inventory hooks below -- maps
--- IsEquipmentShopPermittedForCitizenId's own `reason` string to the
--- locale key that actually names what happened, instead of every call
--- site repeating its own if/elseif over the same three strings.
--- @param reason string?
--- @return string localeText
local function EquipmentShopDenialText(reason)
    if reason == 'feature_disabled' then
        return locale('equipmentshop.feature_disabled')
    elseif reason == 'not_granted' then
        return locale('equipmentshop.not_granted')
    end
    return locale('equipmentshop.blocked_from_shop') -- 'blocked', or an unrecognized future reason -- never silent
end

-- Defensive cap on total live (non-tombstoned) item count -- same
-- reasoning as server/certtiers.lua's own MAX_TIERS.
local MAX_SHOP_ITEMS = 200

-- Absurdly-large-price ceiling -- see this section's own header "PRICE
-- VALIDATION". One BILLION whole currency units.
local MAX_SHOP_ITEM_PRICE = 1000000000

--- 1-50 chars, lowercase-start, lowercase/digit/underscore only -- an
--- ox_inventory item-name shape. Comfortably inside
--- k9_equipment_shop_items.item_key's VARCHAR(50) (migration 0014). Also
--- reused, unchanged, to validate an OPTIONAL `currency` override (which
--- is itself just another ox_inventory item name).
--- @param key any
--- @return boolean
local function IsValidShopItemKey(key)
    if type(key) ~= 'string' then return false end
    local len = #key
    if len < 1 or len > 50 then return false end
    return key:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- See this section's own header "PRICE VALIDATION" for the full
--- reasoning behind every one of these five rejections, and for why ZERO
--- is deliberately NOT one of them.
--- @param value any
--- @return boolean
local function IsValidShopItemPrice(value)
    return type(value) == 'number'
        and value == value                      -- reject NaN
        and value > -math.huge and value < math.huge -- reject +/-infinity
        and value >= 0                           -- reject negative; ZERO IS ALLOWED (a free item)
        and value <= MAX_SHOP_ITEM_PRICE         -- reject absurdly large
        and value == math.floor(value)           -- reject fractional -- whole currency units only
end

-- Live, in-memory catalog state -- rebuilt wholesale by
-- RefreshEquipmentShopItemCatalog below, never partially mutated in
-- place. Same discipline as server/certtiers.lua's TierByKey/TierOrder.
local ItemByKey
local ItemOrder

--- Builds a fresh item_key -> { price, currency, label, requiredTierKey,
--- requiredSpecialization, sortOrder } map from
--- Config.K9EquipmentShop.items ONLY -- does NOT consult the database
--- (see RefreshEquipmentShopItemCatalog for the merge step that layers
--- runtime overrides on top). A malformed entry (not a table, or no valid
--- string `name`) is warned about and excluded from THIS map -- it is
--- NOT thereby excluded from the ORIGINAL REGISTRATION section's own,
--- entirely separate and UNCHANGED validation loop above, which
--- independently warns about and skips the identical entry in its own
--- pass over the raw config array; this is disclosed, harmless
--- duplication (two warnings for one bad entry), never a silent gap,
--- chosen specifically to leave that pre-existing, already-tested loop
--- byte-for-byte untouched by this section.
--- @param shopConfig any -- Config.K9EquipmentShop
--- @return table<string, table>
local function BuildCatalogFromConfigItemDefaults(shopConfig)
    local map = {}
    if type(shopConfig) == 'table' and type(shopConfig.items) == 'table' then
        for i, entry in ipairs(shopConfig.items) do
            if type(entry) ~= 'table' or type(entry.name) ~= 'string' or entry.name == '' then
                print(('[John-K9] equipmentshop: WARNING: Config.K9EquipmentShop.items[%d] is not a table or has no valid string name -- excluded from the item-catalog overlay used for tablet editing / live refresh (the original shop-registration loop above evaluates this entry independently).'):format(i))
            else
                map[entry.name] = {
                    price = entry.price, currency = entry.currency, label = nil,
                    requiredTierKey = nil, requiredSpecialization = nil, sortOrder = i,
                }
            end
        end
    end
    return map
end

-- Initial SYNCHRONOUS population from config defaults ONLY, at this
-- file's own load time -- same reasoning/safety property as
-- server/certtiers.lua's own identical block: makes ItemByKey/ItemOrder
-- safe to read even before onResourceStart fires for this resource. The
-- onResourceStart handler at the bottom of this section layers the
-- database on top a moment later.
ItemByKey = BuildCatalogFromConfigItemDefaults(Config.K9EquipmentShop)
do
    local order = {}
    for key in pairs(ItemByKey) do order[#order + 1] = key end
    table.sort(order, function(a, b) return ItemByKey[a].sortOrder < ItemByKey[b].sortOrder end)
    ItemOrder = order
end

--- Rebuilds `ItemByKey`/`ItemOrder` from Config.K9EquipmentShop.items
--- merged with the current `k9_equipment_shop_items` database state --
--- THE DATABASE WINS per key. Byte-for-byte the same merge shape as
--- server/certtiers.lua's own RefreshCertificationTierCatalog. Called
--- once at this file's own onResourceStart (see bottom of this section)
--- and again after every successful ShopItemsUpsert/Reorder/Delete.
--- @return boolean hasOverlay -- true if at least one row exists in
--- k9_equipment_shop_items (touched or tombstoned) -- used at boot ONLY
--- to decide whether a live shop re-registration is actually needed (see
--- LiveRefreshRegisteredShop's own call site at the bottom of this
--- section for why: a fresh install with zero tablet edits ever made must
--- stay BYTE-FOR-BYTE identical, including registering the shop exactly
--- ONCE, to this resource's behavior before this pass -- the same
--- "zero-behavior-change-until-touched" guarantee server/certtiers.lua's
--- own header calls HAZARD 1).
local function RefreshEquipmentShopItemCatalog()
    local merged = BuildCatalogFromConfigItemDefaults(Config.K9EquipmentShop)

    local overrideRows = K9Store.ShopItem_GetAllRows()
    local hasOverlay = #overrideRows > 0
    for _, row in ipairs(overrideRows) do
        if row.deleted == 1 or row.deleted == true then
            -- TOMBSTONE: exclude entirely -- see this section's own header
            -- "TOMBSTONE, NOT HARD-DELETE".
            merged[row.item_key] = nil
        else
            merged[row.item_key] = {
                price = tonumber(row.price), currency = row.currency, label = row.label,
                requiredTierKey = row.required_tier_key, requiredSpecialization = row.required_specialization,
                sortOrder = tonumber(row.sort_order) or 0,
            }
        end
    end

    local order = {}
    for key in pairs(merged) do order[#order + 1] = key end
    table.sort(order, function(a, b)
        if merged[a].sortOrder ~= merged[b].sortOrder then return merged[a].sortOrder < merged[b].sortOrder end
        return a < b -- stable, deterministic tie-break -- same as server/certtiers.lua's own CONCURRENT-ADD ORDINAL TIE handling
    end)

    ItemByKey = merged
    ItemOrder = order
    return hasOverlay
end

--- How many shop items currently require certification tier `tierKey`
--- before anyone may buy them.
---
--- WHY THIS EXISTS, AND WHY IT LIVES HERE. server/certtiers.lua refuses to
--- delete a tier that anything still points at, and already counts the
--- k9_certifications rows referencing it. Shop items were the OTHER
--- referrer nobody had counted: delete a tier that an item requires and
--- that item becomes unbuyable by every single player on the server, with
--- the refusal naming a tier that no longer exists and can never be
--- granted to anybody. Nothing warned the officer doing the deleting, and
--- nothing in the shop said why it had stopped selling something.
---
--- It has to live in THIS file rather than in certtiers.lua or K9Store,
--- because only the MERGED catalog knows the answer: `required_tier_key`
--- lives on the database overlay rows, and an overlay row can tombstone an
--- item entirely (RefreshEquipmentShopItemCatalog above). Counting raw
--- database rows would count items that have since been deleted; reading
--- config.lua alone would find nothing at all, since config item entries
--- never carry a tier requirement in the first place.
---
--- A resource-global rather than an export, and called through a
--- `type(fn) == 'function'` guard at its one call site, because
--- fxmanifest.lua loads server/certtiers.lua BEFORE this file -- the same
--- convention this resource already uses for every other cross-file
--- global. By the time any tablet callback can run, both files exist.
---
--- @param tierKey string
--- @return number count
--- @return string[] itemKeys -- the item keys themselves, so the refusal can name them
function CountEquipmentShopItemsRequiringTier(tierKey)
    local matched = {}
    if type(tierKey) ~= 'string' or tierKey == '' then return 0, matched end
    if type(ItemByKey) ~= 'table' then return 0, matched end

    -- Walks ItemOrder rather than pairs(ItemByKey) so the names come back
    -- in the same order the tablet lists them, and the refusal a person
    -- reads matches the screen they are looking at.
    for _, key in ipairs(ItemOrder or {}) do
        local entry = ItemByKey[key]
        if type(entry) == 'table' and entry.requiredTierKey == tierKey then
            matched[#matched + 1] = key
        end
    end
    return #matched, matched
end

--- How many shop items currently require role `roleKey`, and their keys
--- in tablet order. server/roles.lua refuses to delete a role any item
--- still needs -- otherwise that item could never be bought again and the
--- refusal would name a role nobody can see.
--- @param roleKey string
--- @return integer count
--- @return string[] itemKeys
function CountEquipmentShopItemsRequiringRole(roleKey)
    local matched = {}
    if type(roleKey) ~= 'string' or roleKey == '' then return 0, matched end
    if type(ItemByKey) ~= 'table' then return 0, matched end
    for _, key in ipairs(ItemOrder or {}) do
        local entry = ItemByKey[key]
        if type(entry) == 'table' and entry.requiredSpecialization == roleKey then
            matched[#matched + 1] = key
        end
    end
    return #matched, matched
end

--- Display label for the tablet's own item list -- an explicit DB
--- override wins; otherwise this resource asks ox_inventory itself for
--- the item's own real label (never hardcoded, never duplicated into this
--- resource's own storage as a required field); if THAT is unavailable
--- (ox_inventory not running, or the item genuinely does not exist in its
--- registry -- e.g. a not-yet-installed item an admin pre-configured), the
--- raw item_key itself is shown rather than nothing at all.
--- @param key string
--- @param overrideLabel string?
--- @return string
local function ResolveShopItemDisplayLabel(key, overrideLabel)
    if type(overrideLabel) == 'string' and overrideLabel ~= '' then return overrideLabel end
    local ok, item = pcall(function() return exports.ox_inventory:Items(key) end)
    if ok and type(item) == 'table' and type(item.label) == 'string' and item.label ~= '' then
        return item.label
    end
    return key
end

--- Ordered (by sortOrder ascending) snapshot of the live item catalog for
--- the tablet's own editing screen -- a COPY, not the live tables, same
--- "caller cannot mutate this file's own authoritative state" reasoning
--- as server/certtiers.lua's own ListCertificationTiers.
--- @return table[]
local function ListEquipmentShopItems()
    local list = {}
    for _, key in ipairs(ItemOrder) do
        local entry = ItemByKey[key]
        list[#list + 1] = {
            key = key,
            label = ResolveShopItemDisplayLabel(key, entry.label),
            price = entry.price,
            currency = entry.currency,
            sortOrder = entry.sortOrder,
            requiredTierKey = entry.requiredTierKey,
            requiredSpecialization = entry.requiredSpecialization,
        }
    end
    return list
end

--- Builds the `{name,price,currency?}[]` array `RegisterShop` expects
--- from the LIVE MERGED catalog (config ∪ database overlay) -- the exact
--- same per-entry price-shape + WarnIfItemMissing validation as the
--- ORIGINAL REGISTRATION loop above, parameterized over the merged
--- catalog instead of the raw config array (that original loop is left
--- completely untouched -- see this section's own header for why running
--- both, independently, is a deliberate, disclosed, harmless choice, not
--- an oversight).
--- @param currencyItem string
--- @return table[]
local function BuildValidatedShopInventoryArray(currencyItem)
    local inventoryItems = {}
    for _, key in ipairs(ItemOrder) do
        local entry = ItemByKey[key]
        local diagnosticPath = ('k9_equipment_shop_items[%q]'):format(key)
        if not IsValidShopItemPrice(entry.price) then
            print(('[John-K9] equipmentshop: WARNING: %s has an invalid price (%s) -- skipped from the live shop refresh.'):format(diagnosticPath, tostring(entry.price)))
        elseif WarnIfItemMissing(key, diagnosticPath .. '.name') then
            inventoryItems[#inventoryItems + 1] = {
                name = key,
                price = entry.price,
                currency = (entry.currency ~= nil and entry.currency ~= currencyItem) and entry.currency or nil,
            }
        end
    end
    return inventoryItems
end

--- Re-registers the K9 Supply shop from the LIVE merged catalog -- makes
--- a tablet item edit take effect for every already-connected player
--- IMMEDIATELY, with no restart. Safe to call at any time, any number of
--- times (registerShopType's own real implementation is an unconditional
--- table overwrite -- see this section's own header "THE EDIT/PURCHASE
--- RACE"). A WARNING ONLY on failure, never a thrown error -- mirrors
--- this file's own pre-existing REGISTRATION section's identical posture.
--- @return boolean ok -- true only when RegisterShop was actually called and reported success (this pass, coder-backend -- so ActivateEquipmentShopIfEnabled can tell whether activation via the overlay path actually succeeded)
local function LiveRefreshRegisteredShop()
    local shopConfig = Config.K9EquipmentShop
    if type(shopConfig) ~= 'table' or type(shopConfig.shopType) ~= 'string' or shopConfig.shopType == '' then
        return false -- nothing to refresh -- the original REGISTRATION handler already warned about this shape problem
    end

    local currencyItem = shopConfig.currencyItem
    if type(currencyItem) ~= 'string' or currencyItem == '' then currencyItem = 'money' end

    local inventoryItems = BuildValidatedShopInventoryArray(currencyItem)
    if #inventoryItems == 0 then
        print('[John-K9] equipmentshop: WARNING: the merged item catalog has nothing left to sell after validation -- the live shop refresh was skipped (ox_inventory keeps whatever it last had registered, if anything).')
        return false
    end

    local groups = nil
    if type(Config.Departments) == 'table' then
        groups = {}
        for jobName in pairs(Config.Departments) do groups[jobName] = 0 end
        if next(groups) == nil then groups = nil end
    end

    local shopLabel = type(shopConfig.label) == 'string' and shopConfig.label ~= '' and shopConfig.label or 'K9 Supply'
    local registered = K9Compat.Get('inventory').RegisterShop(shopConfig.shopType, {
        label = shopLabel,
        items = inventoryItems,
        groups = groups,
    })

    if not registered then
        print('[John-K9] equipmentshop: WARNING: live shop refresh (RegisterShop) failed -- the most recent item edit will not be visible to players until the next resource restart.')
        return false
    end

    return true
end

-- Cross-file-pattern critical-section lock, keyed by item_key -- see this
-- section's own header "THE EDIT/PURCHASE RACE" for exactly what this
-- protects (concurrent EDITS to the same item, never the already-safe
-- ox_inventory purchase path itself) and for why it cannot deadlock
-- against server/certtiers.lua's TierEditMutex.
local ShopItemEditMutex = NewMutex()

-- Anti-fat-finger/double-submit rate limit, keyed by the ACTING officer's
-- own source -- a SEPARATE instance from EquipmentShopLocationActionCooldown
-- above (a different concern, a different budget), mirroring
-- server/certtiers.lua's own CertTierActionCooldown shape exactly.
local EQUIPMENT_SHOP_ITEM_ACTION_COOLDOWN_MS = 1000
local EquipmentShopItemActionCooldown = NewCooldown(EQUIPMENT_SHOP_ITEM_ACTION_COOLDOWN_MS)
EquipmentShopItemActionCooldown.RegisterPlayerDropped()

--- @param action string
--- @param itemKey string
--- @param detail string
--- @param changedBy string
local function WriteShopItemAudit(action, itemKey, detail, changedBy)
    -- AUDIT-SWALLOW FIX (this pass): ShopItemAudit_Append's own boolean
    -- return used to be discarded here -- every call site above already
    -- checked its OWN primary write before ever reaching this helper, so
    -- the action genuinely happened and this file's own `ok = true`
    -- responses remain correct either way -- but a failed audit-trail
    -- insert must not vanish without a trace tying it to this specific
    -- action/key. Mirrors server/runtimecontrol.lua's own identical
    -- "AUDIT-SWALLOW FIX (this pass)" comment/shape exactly.
    if not K9Store.ShopItemAudit_Append(action, itemKey, detail, changedBy or 'unknown') then
        print(('[John-K9] equipmentshop.lua: audit-trail write failed for action=%s itemKey=%s (the action itself still succeeded and was persisted).'):format(tostring(action), tostring(itemKey)))
    end
end

-- ======================================================================
-- CALLBACKS -- all four re-verify CanManageShopItems(source) as their own
-- first action, mirroring server/certtiers.lua's own certTiersList/
-- certTiersUpsert/certTiersReorder/certTiersDelete shape and response
-- convention (`{ ok, reason, ... }`) exactly.
-- ======================================================================

lib.callback.register('john-k9:server:equipmentShopItemsList', function(source)
    local authorized = CanManageShopItems(source)
    if not authorized then return { ok = false, reason = 'denied' } end
    return { ok = true, items = ListEquipmentShopItems() }
end)

lib.callback.register('john-k9:server:equipmentShopItemsUpsert', function(source, payload)
    local authorized, citizenid = CanManageShopItems(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not EquipmentShopItemActionCooldown.Consume(source, EQUIPMENT_SHOP_ITEM_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(payload) ~= 'table' or type(payload.key) ~= 'string' then
        return { ok = false, reason = 'invalid_payload' }
    end

    local key = payload.key
    if not IsValidShopItemKey(key) then
        return { ok = false, reason = 'invalid_key' }
    end
    if not IsValidShopItemPrice(payload.price) then
        return { ok = false, reason = 'invalid_price' }
    end

    local label = nil
    if payload.label ~= nil then
        if not IsSafeShortString(payload.label, 60) then
            return { ok = false, reason = 'invalid_label' }
        end
        label = payload.label
    end

    local currency = nil
    if payload.currency ~= nil then
        if not IsValidShopItemKey(payload.currency) then
            return { ok = false, reason = 'invalid_currency' }
        end
        currency = payload.currency
    end

    local requiredTierKey = nil
    if payload.requiredTierKey ~= nil then
        if type(payload.requiredTierKey) ~= 'string'
            or type(IsKnownCertificationTierKey) ~= 'function'
            or not IsKnownCertificationTierKey(payload.requiredTierKey) then
            return { ok = false, reason = 'invalid_required_tier' }
        end
        requiredTierKey = payload.requiredTierKey
    end

    local requiredSpecialization = nil
    if payload.requiredSpecialization ~= nil then
        if type(payload.requiredSpecialization) ~= 'string'
            or type(Config.K9Specializations) ~= 'table'
            or Config.K9Specializations[payload.requiredSpecialization] == nil then
            return { ok = false, reason = 'invalid_required_specialization' }
        end
        requiredSpecialization = payload.requiredSpecialization
    end

    if not ShopItemEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    -- `existing` is nil both for a genuinely brand-new key AND for one
    -- currently tombstoned (ItemByKey excludes tombstoned keys entirely)
    -- -- `priorRow` below (a direct DB read, ignoring the tombstone
    -- filter) is what actually distinguishes "create" from "restore" for
    -- the audit trail -- same pattern as server/certtiers.lua's own
    -- certTiersUpsert.
    local existing = ItemByKey[key]
    local isNewOrRestoring = existing == nil

    if isNewOrRestoring then
        local liveCount = 0
        for _ in pairs(ItemByKey) do liveCount = liveCount + 1 end
        if liveCount >= MAX_SHOP_ITEMS then
            ShopItemEditMutex.Release(key)
            return { ok = false, reason = 'too_many_items' }
        end
    end

    local sortOrder
    if isNewOrRestoring then
        -- Append at the end -- both for a genuinely new key and for one
        -- being restored from a tombstone (a restore does not attempt to
        -- reclaim its old position -- same reasoning as
        -- server/certtiers.lua's own UpsertTier).
        local maxOrder = 0
        for _, entry in pairs(ItemByKey) do
            if entry.sortOrder > maxOrder then maxOrder = entry.sortOrder end
        end
        sortOrder = maxOrder + 1
    else
        -- Editing an already-live item: sortOrder is untouched here. The
        -- ONLY way to change an existing item's order is
        -- equipmentShopItemsReorder below.
        sortOrder = existing.sortOrder
    end

    local priorRow = K9Store.ShopItem_GetDeletedFlagByKey(key)[1]

    local wrote = K9Store.ShopItem_Upsert(key, label, payload.price, currency, sortOrder, requiredTierKey, requiredSpecialization, citizenid or 'unknown')
    ShopItemEditMutex.Release(key)

    if not wrote then
        return { ok = false, reason = 'db_error' }
    end

    local action
    if not isNewOrRestoring then
        action = 'item_update'
    elseif priorRow ~= nil and (priorRow.deleted == 1 or priorRow.deleted == true) then
        action = 'item_restore'
    else
        action = 'item_create'
    end

    WriteShopItemAudit(action, key,
        ('label=%s price=%d currency=%s required_tier=%s required_specialization=%s'):format(
            label or '(default)', payload.price, currency or '(default)', requiredTierKey or '(none)', requiredSpecialization or '(none)'),
        citizenid or 'unknown')

    RefreshEquipmentShopItemCatalog()
    EnsureEquipmentShopReflectsCurrentCatalog()

    return { ok = true, items = ListEquipmentShopItems() }
end)

lib.callback.register('john-k9:server:equipmentShopItemsReorder', function(source, orderedKeys)
    local authorized, citizenid = CanManageShopItems(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not EquipmentShopItemActionCooldown.Consume(source, EQUIPMENT_SHOP_ITEM_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(orderedKeys) ~= 'table' or #orderedKeys > MAX_SHOP_ITEMS then
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Must be EXACTLY a permutation of every currently-known
    -- (non-tombstoned) item key -- no partial reorder, ever -- same
    -- "HAZARD 3"-style rule as server/certtiers.lua's own ReorderTiers.
    local currentKeys, expectedCount = {}, 0
    for key in pairs(ItemByKey) do
        currentKeys[key] = true
        expectedCount = expectedCount + 1
    end

    local seen, cleanOrder = {}, {}
    for _, key in ipairs(orderedKeys) do
        if type(key) ~= 'string' or not currentKeys[key] or seen[key] then
            return { ok = false, reason = 'invalid_key_set' }
        end
        seen[key] = true
        cleanOrder[#cleanOrder + 1] = key
    end
    if #cleanOrder ~= expectedCount then
        return { ok = false, reason = 'must_include_every_item' }
    end

    local beforeParts = {}
    for _, key in ipairs(cleanOrder) do
        beforeParts[#beforeParts + 1] = ('%s=%d'):format(key, ItemByKey[key].sortOrder)
    end

    -- `writeFailedKeys` collects only a genuine post-acquire DB write
    -- failure (SafeWrite contract: ShopItem_UpdateSortOrder degrades a
    -- thrown DB error to `false` rather than propagating) -- NOT a
    -- busy-skip, which remains the pre-existing, already-disclosed, benign
    -- contention outcome (logged, sort order left unchanged, overall
    -- response still `ok = true`) and is deliberately left untouched
    -- below. A write failure is a different, more serious class -- an
    -- actual DB error, not ordinary lock contention -- so it alone
    -- escalates the response. Mirrors server/certtiers.lua's own
    -- ReorderTiers exactly.
    local afterParts, writeFailedKeys = {}, {}
    for index, key in ipairs(cleanOrder) do
        -- Per-key mutex, held only for THIS key's own write -- same
        -- reasoning as server/certtiers.lua's own ReorderTiers: a busy key
        -- is skipped THIS pass (its order left unchanged) rather than
        -- blocking the rest of the reorder.
        if ShopItemEditMutex.TryAcquire(key) then
            local entry = ItemByKey[key]
            local wrote = K9Store.ShopItem_UpdateSortOrder(key, entry.label, entry.price, entry.currency, index, entry.requiredTierKey, entry.requiredSpecialization, citizenid or 'unknown')
            ShopItemEditMutex.Release(key)
            if wrote then
                afterParts[#afterParts + 1] = ('%s=%d'):format(key, index)
            else
                -- Acquired the lock but the write itself failed (SafeWrite
                -- contract: a thrown DB error degrades to `false`). Log it,
                -- and record the REAL unchanged sort order (never the
                -- intended `index`), since the write never actually
                -- landed.
                writeFailedKeys[#writeFailedKeys + 1] = key
                print(('[John-K9] equipmentshop ReorderItems: item %s sort order write failed (db_error) -- its sort order was left unchanged this pass'):format(key))
                afterParts[#afterParts + 1] = ('%s=%d'):format(key, entry.sortOrder)
            end
        else
            -- busy-key skip: this branch IS correctly handled, left
            -- unchanged -- see header comment above.
            print(('[John-K9] equipmentshop ReorderItems: item %s busy (concurrent edit) -- its sort order was left unchanged this pass'):format(key))
            afterParts[#afterParts + 1] = ('%s=%d'):format(key, index)
        end
    end

    WriteShopItemAudit('item_reorder', 'ALL',
        ('before=[%s] after=[%s]'):format(table.concat(beforeParts, ', '), table.concat(afterParts, ', ')),
        citizenid or 'unknown')

    RefreshEquipmentShopItemCatalog()
    EnsureEquipmentShopReflectsCurrentCatalog()

    if #writeFailedKeys > 0 then
        return {
            ok = false,
            reason = 'sort_order_write_failed',
            failedKeys = writeFailedKeys,
            items = ListEquipmentShopItems(),
        }
    end

    return { ok = true, items = ListEquipmentShopItems() }
end)

lib.callback.register('john-k9:server:equipmentShopItemsDelete', function(source, key)
    local authorized, citizenid = CanManageShopItems(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not EquipmentShopItemActionCooldown.Consume(source, EQUIPMENT_SHOP_ITEM_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(key) ~= 'string' or not ItemByKey[key] then
        return { ok = false, reason = 'unknown_item' }
    end

    if not ShopItemEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    -- No reference-count check before tombstoning -- see this section's
    -- own header "TOMBSTONE, NOT HARD-DELETE" for exactly why this file's
    -- own schema has nothing an item_key delete could ever strand.
    local entry = ItemByKey[key]
    local wrote = K9Store.ShopItem_Tombstone(key, entry.label, entry.price, entry.currency, entry.sortOrder, entry.requiredTierKey, entry.requiredSpecialization, citizenid or 'unknown')
    ShopItemEditMutex.Release(key)

    if not wrote then
        return { ok = false, reason = 'db_error' }
    end

    WriteShopItemAudit('item_delete', key, ('item %s removed from sale (tombstoned)'):format(key), citizenid or 'unknown')

    RefreshEquipmentShopItemCatalog()
    EnsureEquipmentShopReflectsCurrentCatalog()

    return { ok = true, items = ListEquipmentShopItems() }
end)

-- ======================================================================
-- PURCHASE-TIME ENFORCEMENT -- ox_inventory `registerHook` additions, see
-- this section's own header for the full design/verification writeup.
-- Both hooks are ONLY ever registered when Config.Features.K9EquipmentShop
-- is true at THIS resource's own onResourceStart (see the handler at the
-- bottom of this section) -- an ABSENT/false feature flag registers
-- neither, matching this file's own established "ABSENCE IS A CLEAN
-- NO-OP" posture. Both filter to THIS shop's own `shopType` ONLY, in
-- their very first line -- never touching any other shop registered by
-- ox_inventory itself or by any other resource.
-- ======================================================================

--- Gates ox_inventory's own `openShop` event -- see this section's own
--- header "WHERE THIS IS GATED" for the full "why this is the real
--- opening decision point" writeup. NEVER gates closing/leaving the shop
--- UI (there is no such hook here at all).
---
--- FAIL-CLOSED ON ERROR (this pass, coder-security review finding).
--- CONFIRMED against real source, not assumed: ox_inventory's own
--- `TriggerEventHooks` (modules/hooks/server.lua) invokes every registered
--- hook as `local _, response = pcall(hook, payload)` -- an ERROR thrown by
--- this hook is swallowed there, `response` becomes the error STRING (never
--- the literal `false`), so `response == false` is false and the loop
--- treats a THROWN hook identically to an ALLOWING hook. shared/compat/
--- inventory.lua's own RegisterHook wrapper (`local vetoOk, veto =
--- pcall(callback, payload); if vetoOk and veto == false then return false
--- end`) has the exact same gap one layer up: when `callback` (this
--- function's own body) throws, `vetoOk` is false and the wrapper falls
--- through to an implicit `return nil` -- also read as "no veto" by
--- ox_inventory. Two independent layers, same fail-open direction on an
--- unanticipated error -- exactly the "hook that fails open on error is a
--- free-items bug" case this pass was asked to rule out. This file cannot
--- fix the shared compat layer (reported to main/coder-backend instead,
--- shared/compat/inventory.lua:534-549) but CAN and DOES ensure that any
--- error raised by ITS OWN evaluation logic below never reaches either
--- swallowing layer as a thrown error in the first place -- pcall'd here,
--- one level in, with an EXPLICIT `false` (veto/deny) on failure, so an
--- unanticipated bug in this function denies the shop-open attempt instead
--- of silently granting it.
--- REGISTERS AT MOST ONCE, EVER, PER SERVER SESSION (this pass, coder-
--- backend -- see this file's own "RUNTIME TOGGLE-ON FORWARD DECLARATIONS"
--- header for the full citation). ox_inventory's own real `registerHook`
--- has no de-duplication of its own -- `eventHooks[event]` is a plain,
--- ever-growing array a second call would simply APPEND to, producing a
--- second, fully redundant copy of this exact veto logic that fires
--- forever alongside the first. This function may now be called any
--- number of times (a subsequent toggle-on edge, or an item-catalog edit
--- arriving before the shop was ever activated) -- EquipmentShopOpenHookRegistered
--- guards every call after the first successful one down to a plain
--- `return true`, never touching ox_inventory again.
--- @param shopType string -- Config.K9EquipmentShop.shopType, captured once at registration time
--- @return boolean ok
local EquipmentShopOpenHookRegistered = false
local function RegisterEquipmentShopOpenShopBlockHook(shopType)
    if EquipmentShopOpenHookRegistered then return true end

    local function EvaluateOpenShopHook(payload)
        if type(payload) ~= 'table' or payload.shopType ~= shopType then return end -- not our shop -- never touch anyone else's

        local source = payload.source
        local Player = type(source) == 'number' and exports.qbx_core:GetPlayer(source)
        local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
        if type(citizenid) ~= 'string' or citizenid == '' then
            return false -- cannot identify the requester at all -- fail closed, never open the shop for an unresolvable identity
        end

        local allowed, reason = IsEquipmentShopPermittedForCitizenId(citizenid)
        if not allowed then
            if type(NotifyPlayer) == 'function' and type(source) == 'number' then
                NotifyPlayer(source, EquipmentShopDenialText(reason), 'error')
            end
            return false -- VETO: the shop UI never opens for this one attempt
        end
        -- allowed -- return nil, no veto
    end

    local registered = K9Compat.Get('inventory').RegisterHook('openShop', function(payload)
        local evalOk, veto = pcall(EvaluateOpenShopHook, payload)
        if not evalOk then
            print(('[John-K9] equipmentshop: ERROR: openShop block hook threw while evaluating a shop-open attempt -- FAILING CLOSED (denying this one attempt) rather than risk a silent allow: %s'):format(tostring(veto)))
            return false -- FAIL CLOSED: an error evaluating this hook must never be read as "no veto"
        end
        return veto
    end)

    if registered then
        EquipmentShopOpenHookRegistered = true
    else
        print('[John-K9] equipmentshop: WARNING: could not register the openShop per-person block/grant hook -- a `block.K9EquipmentShop`/`feature.K9EquipmentShop` permission grant will NOT be enforced this session (expected/inert on a non-ox_inventory backend -- see shared/compat/inventory.lua\'s own "RegisterHook VOCABULARY" section: only ox_inventory currently translates the \'openShop\' event). The server-wide Config.Features.K9EquipmentShop flag is unaffected either way.')
    end

    return registered
end

--- Gates ox_inventory's own `buyItem` event with THIS item's own
--- `requiredTierKey`/`requiredSpecialization`, AND re-checks the same
--- per-person block/grant as RegisterEquipmentShopOpenShopBlockHook above
--- (defense-in-depth -- see this section's own header). NEVER gates a
--- termination/cleanup path -- there is no "give the item back" concept
--- here at all; a purchase either completes or it does not.
---
--- FAIL-CLOSED ON ERROR -- see RegisterEquipmentShopOpenShopBlockHook's own
--- doc comment immediately above for the full two-layer (ox_inventory's
--- own TriggerEventHooks + shared/compat/inventory.lua's RegisterHook)
--- swallow-to-allow finding this applies to as well. This hook is the
--- higher-stakes of the two to get this right for -- an uncaught error
--- inside `MeetsTierRequirement`/`HasSpecialization` (both calls into
--- OTHER files' code this function does not control) would otherwise sell
--- a tier/specialization-gated item to ANY buyer the instant either
--- function had a bug, with no purchase-time signal that the gate was ever
--- bypassed.
--- REGISTERS AT MOST ONCE, EVER, PER SERVER SESSION -- see
--- RegisterEquipmentShopOpenShopBlockHook's own doc comment immediately
--- above for the full "why" (ox_inventory's own registerHook has no
--- de-duplication of its own).
--- @param shopType string
--- @return boolean ok
--- The purchase refusal for a role-gated item, in the buyer's terms:
--- "needs the X role", or -- when they hold it but their XP has not
--- reached it yet -- how much XP it switches on at and how much they have.
--- @param citizenid string @param jobName string @param roleKey string
--- @return string
local function EquipmentShopRoleDenialText(citizenid, jobName, roleKey)
    local def = type(Config.K9Specializations) == 'table' and Config.K9Specializations[roleKey] or nil
    local label = (type(def) == 'table' and type(def.label) == 'string' and def.label ~= '') and def.label or roleKey
    local need = (type(def) == 'table' and type(def.xpRequired) == 'number') and def.xpRequired or 0
    local held = false
    if type(HasSpecializationGranted) == 'function' then
        held = HasSpecializationGranted(citizenid, jobName, roleKey) == true
    end
    if held and need > 0 and type(GetRoleXpForCitizen) == 'function' then
        local have = math.floor(tonumber(GetRoleXpForCitizen(citizenid)) or 0)
        if have < need then
            return locale('equipmentshop.requires_role_xp', label, math.floor(need), have)
        end
    end
    return locale('equipmentshop.requires_specialization', label)
end

local EquipmentShopBuyHookRegistered = false
local function RegisterEquipmentShopBuyItemRequirementHook(shopType)
    if EquipmentShopBuyHookRegistered then return true end

    local function EvaluateBuyItemHook(payload)
        if type(payload) ~= 'table' or payload.shopType ~= shopType then return end -- not our shop

        local source = payload.source
        local Player = type(source) == 'number' and exports.qbx_core:GetPlayer(source)
        local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
        local jobName = Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.name

        if type(citizenid) ~= 'string' or citizenid == '' then
            return false -- unresolvable identity -- fail closed (see header)
        end

        local allowed, reason = IsEquipmentShopPermittedForCitizenId(citizenid)
        if not allowed then
            if type(NotifyPlayer) == 'function' and type(source) == 'number' then
                NotifyPlayer(source, EquipmentShopDenialText(reason), 'error')
            end
            return false
        end

        local itemName = payload.itemName
        local entry = type(itemName) == 'string' and ItemByKey[itemName]
        if not entry then return end -- unknown to this file's own overlay -- nothing configured to gate here
        if entry.requiredTierKey == nil and entry.requiredSpecialization == nil then return end -- no requirement configured -- allow

        if type(jobName) ~= 'string' or jobName == '' then
            return false -- have a citizenid but no resolvable job -- cannot evaluate a job-scoped requirement -- fail closed
        end

        if entry.requiredTierKey ~= nil then
            local meets = type(MeetsTierRequirement) == 'function' and MeetsTierRequirement(citizenid, jobName, entry.requiredTierKey)
            if meets ~= true then
                if type(NotifyPlayer) == 'function' and type(source) == 'number' then
                    NotifyPlayer(source, locale('equipmentshop.requires_tier', entry.requiredTierKey), 'error')
                end
                return false
            end
        end

        -- requiredSpecialization names a ROLE (server/roles.lua): the item
        -- sells only to someone holding that role whose XP has reached it
        -- (HasSpecialization checks both).
        if entry.requiredSpecialization ~= nil then
            local has = type(HasSpecialization) == 'function' and HasSpecialization(citizenid, jobName, entry.requiredSpecialization)
            if has ~= true then
                if type(NotifyPlayer) == 'function' and type(source) == 'number' then
                    NotifyPlayer(source, EquipmentShopRoleDenialText(citizenid, jobName, entry.requiredSpecialization), 'error')
                end
                return false
            end
        end
        -- every configured requirement met -- allow (return nil, no veto)
    end

    local registered = K9Compat.Get('inventory').RegisterHook('buyItem', function(payload)
        local evalOk, veto = pcall(EvaluateBuyItemHook, payload)
        if not evalOk then
            print(('[John-K9] equipmentshop: ERROR: buyItem requirement hook threw while evaluating a purchase attempt -- FAILING CLOSED (denying this one purchase) rather than risk a silent allow of a gated item: %s'):format(tostring(veto)))
            return false -- FAIL CLOSED: an error evaluating this hook must never be read as "no veto"
        end
        return veto
    end)

    if registered then
        EquipmentShopBuyHookRegistered = true
    else
        print('[John-K9] equipmentshop: WARNING: could not register the buyItem purchase-requirement hook -- any tier/specialization requirement set on a shop item will NOT be enforced this session (expected/inert on a non-ox_inventory backend -- see shared/compat/inventory.lua\'s own "RegisterHook VOCABULARY" section: only ox_inventory currently translates the \'buyItem\' event).')
    end

    return registered
end

-- ======================================================================
-- ACTIVATION -- the single gate that may ever cause this shop to become
-- live in ox_inventory, on boot OR on a later runtime toggle-on. See this
-- file's own "RUNTIME TOGGLE-ON FORWARD DECLARATIONS" header (top of file)
-- for the full design writeup -- these are the real bodies for the two
-- names forward-declared there, assigned now (not `local function`) since
-- both are already `local` upvalues from that earlier declaration -- same
-- idiom this file already uses for ItemByKey/ItemOrder. Defined HERE,
-- after RegisterEquipmentShopOpenShopBlockHook/
-- RegisterEquipmentShopBuyItemRequirementHook/RefreshEquipmentShopItemCatalog/
-- LiveRefreshRegisteredShop all exist, because this function calls every
-- one of them.
-- ======================================================================

--- True once RegisterShop has actually succeeded at least once THIS
--- session (via either RegisterEquipmentShopFromConfig or
--- LiveRefreshRegisteredShop) AND both purchase-enforcement hooks are
--- confirmed registered. Once true, ActivateEquipmentShopIfEnabled becomes
--- a permanent no-op for the rest of this resource's life -- ongoing item
--- edits flow through EnsureEquipmentShopReflectsCurrentCatalog's OTHER
--- branch instead (a direct LiveRefreshRegisteredShop call, never back
--- through this function -- see that function's own doc comment).
local EquipmentShopFullyActivated = false

--- @see this file's own "RUNTIME TOGGLE-ON FORWARD DECLARATIONS" header
function ActivateEquipmentShopIfEnabled()
    if EquipmentShopFullyActivated then return end
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end

    local shopConfig = Config.K9EquipmentShop
    local shopType = type(shopConfig) == 'table' and shopConfig.shopType or nil

    if type(shopType) ~= 'string' or shopType == '' then
        -- No usable shopType to filter a hook on at all -- let
        -- RegisterEquipmentShopFromConfig print its own specific shape
        -- warning (table missing vs shopType missing/empty) exactly like
        -- it always has, and stop there.
        RegisterEquipmentShopFromConfig()
        return
    end

    -- HOOKS FIRST, ALWAYS -- see header "THE HOOKS ARE THE ENFORCEMENT" /
    -- "HOOKS FIRST, ALWAYS". Each call is individually idempotent (its own
    -- EquipmentShopOpenHookRegistered/EquipmentShopBuyHookRegistered guard)
    -- -- calling this whole function again later after a partial failure
    -- never re-registers a hook that already succeeded, and never appends
    -- a duplicate to ox_inventory's own ever-growing hook array.
    local openOk = RegisterEquipmentShopOpenShopBlockHook(shopType)
    local buyOk = RegisterEquipmentShopBuyItemRequirementHook(shopType)
    if not (openOk and buyOk) then
        print('[John-K9] equipmentshop: ERROR: REFUSING to activate the K9 Supply shop -- one or both ox_inventory purchase-enforcement hooks (openShop block / buyItem requirement) failed to register (see the WARNING line(s) immediately above for which, and why). A shop that exists in ox_inventory with no enforcement hook attached would have no per-person block and no purchase-tier/specialization requirement -- worse than no shop at all -- so RegisterShop is being skipped entirely this attempt. Will retry automatically on the next toggle-on edge or item-catalog edit.')
        return
    end

    -- BOTH the original, byte-for-byte-unchanged raw-config registration
    -- AND the existing database-overlay live-refresh -- the two pre-
    -- existing, independent, already-tested registration paths this file
    -- has always had, now simply sequenced correctly behind the hooks
    -- above, never a third, competing implementation of either.
    local baseOk = RegisterEquipmentShopFromConfig()

    -- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (boot-order-race
    -- audit, this pass -- same fix already shipped for
    -- server/certtiers.lua/server/permissionkeycatalog.lua/server/xptiers.lua/
    -- server/k9profiles.lua, simply missed here when it landed for those
    -- four -- see server/datastore.lua's own "BOOT-ORDER SETTLEMENT" header
    -- for the exact race this closes). This function is reached from BOTH
    -- of this file's own onResourceStart handlers (this file's top
    -- REGISTRATION section, and the later "BOOT" section) AND from a live
    -- runtime toggle-on -- calling WaitForSchemaCheckToSettle() here,
    -- rather than at each onResourceStart call site individually, covers
    -- all three with one guard: a runtime-toggle caller reaches this well
    -- after boot has settled, so it pays no real wait at all (the function
    -- returns instantly true), while both onResourceStart callers get
    -- correctly gated before RefreshEquipmentShopItemCatalog's own
    -- narrower SELECT (a different column set than k9_equipment_shop_items
    -- is checked against) can run against a foreign table the full probe
    -- would correctly reject as a collision. On a `false` return (the
    -- probe genuinely had not settled within the wait budget), this skips
    -- ONLY the database overlay for this attempt -- RegisterEquipmentShopFromConfig
    -- above (config.lua's own item list) already ran and is unaffected,
    -- exactly like `Config.Database.enabled == false` already leaves this
    -- shop fully usable on config alone. The next successful item-catalog
    -- edit (or a restart once the check has had time to finish) picks up
    -- any real persisted overlay as normal.
    local hasOverlay
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] equipmentshop: the schema-collision check had not finished within its wait budget -- activating the K9 Supply shop from config.lua only for this session (no database overlay read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next successful item-catalog edit (or a restart once the check has had time to finish) will pick up any real persisted overlay.')
        hasOverlay = false
    else
        hasOverlay = RefreshEquipmentShopItemCatalog()
    end
    local overlayOk = hasOverlay and LiveRefreshRegisteredShop() or false

    if baseOk or overlayOk then
        EquipmentShopFullyActivated = true
    end
end

--- Called after every successful item-catalog write
--- (equipmentShopItemsUpsert/Reorder/Delete). If the shop is already fully
--- activated this session, simply re-registers from the just-updated
--- merged catalog via the EXISTING LiveRefreshRegisteredShop -- never a
--- second, parallel implementation of "how to call RegisterShop." If the
--- shop has NOT yet been activated (e.g. Config.Features.K9EquipmentShop
--- was off at boot and an admin edited an item before ever toggling it
--- on), this does NOT call RegisterShop directly on its own -- it routes
--- through ActivateEquipmentShopIfEnabled instead, so an item-catalog edit
--- can never be the thing that creates a shop with no enforcement hooks
--- attached (see this file's own "RUNTIME TOGGLE-ON FORWARD DECLARATIONS"
--- header for the pre-existing bug this closes).
--- @see this file's own "RUNTIME TOGGLE-ON FORWARD DECLARATIONS" header
function EnsureEquipmentShopReflectsCurrentCatalog()
    if not (Config.Features and Config.Features.K9EquipmentShop == true) then return end
    if EquipmentShopFullyActivated then
        LiveRefreshRegisteredShop()
        return
    end
    ActivateEquipmentShopIfEnabled()
end

-- BOOT: the shop is activated once, by this file's first onResourceStart
-- handler (above, next to RegisterEquipmentShopFromConfig). There used to
-- be a second boot handler here as well. When activation failed (every
-- item missing from ox_inventory, say), the second one ran it again and
-- every warning printed twice.

-- ======================================================================
-- RUNTIME TOGGLE-ON WATCHER -- the actual fix for "the shop cannot be
-- turned on at runtime". Every boot-time path above only ever runs once
-- (onResourceStart fires exactly once); this is what makes a LATER
-- toggle-on (server/runtimecontrol.lua's own runtimeSetFeature, confirmed
-- by reading it directly this pass, flips the live Config.Features.
-- K9EquipmentShop table entry immediately, with no event of its own for
-- another file to react to) actually do something.
--
-- EDGE-TRIGGERED, not level-triggered: Config.Features.K9EquipmentShop is
-- re-read once per poll and compared against the last value THIS thread
-- itself last saw; ActivateEquipmentShopIfEnabled is attempted only on a
-- false -> true transition, never on every single tick while the flag
-- merely stays true. Two reasons, both deliberate: (1) once activated,
-- ActivateEquipmentShopIfEnabled is already a cheap, guarded no-op, so
-- re-calling it every tick would be harmless but wasteful; (2) if the
-- config is genuinely broken (e.g. no valid items), re-attempting on every
-- single tick would re-print the same shape warning forever for as long
-- as the flag stays on, which an edge-trigger avoids -- a fresh attempt,
-- and a fresh warning if it is still broken, happens once per toggle-on,
-- not once every EQUIPMENT_SHOP_ACTIVATION_POLL_MS forever.
--
-- BOUNDED LATENCY, DISCLOSED: up to EQUIPMENT_SHOP_ACTIVATION_POLL_MS
-- after a live toggle-on, never instant -- there is no push notification
-- anywhere in this resource for a Config.Features change (ApplyFeatureOverride,
-- server/runtimecontrol.lua, is a plain table write with no event fired),
-- so polling is the only mechanism available that stays entirely inside
-- this file. 5000ms matches this resource's own established tick-interval
-- magnitude elsewhere (server/wellbeing.lua's own default TICK_INTERVAL_MS).
--
-- TOGGLE-OFF IS NOT THIS THREAD'S JOB -- see this file's own "TOGGLE-OFF
-- MUST NOT STRAND ANYONE" header note: the two already-registered hooks
-- re-check the live flag on every single open/buy attempt on their own,
-- so a toggle OFF is enforced by them immediately, with nothing for this
-- watcher to do.
-- ======================================================================
local EQUIPMENT_SHOP_ACTIVATION_POLL_MS = 5000

CreateThread(function()
    local lastSeenEnabled = Config.Features and Config.Features.K9EquipmentShop == true
    while true do
        Wait(EQUIPMENT_SHOP_ACTIVATION_POLL_MS)

        local nowEnabled = Config.Features and Config.Features.K9EquipmentShop == true
        if nowEnabled and not lastSeenEnabled then
            ActivateEquipmentShopIfEnabled()
        end
        lastSeenEnabled = nowEnabled
    end
end)
