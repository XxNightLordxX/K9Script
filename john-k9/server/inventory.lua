--[[
    john-k9/server/inventory.lua

    DEVELOPER_REFERENCE.md §13.4.2 ("K9 Inventory", `Config.Features.K9Inventory`)
    — read in full before this file was written, along with §13.2's
    `Config.K9Inventory` sketch, §13.3's file/module plan (this file +
    client/inventory.lua, a NEW pair, not folded into an existing file —
    the same real ox_inventory capability grant deserves the
    certification-file's level of scrutiny reasoning §11.3 already gives
    for splitting client/search.lua from client/tracking.lua by TRUST
    MODEL), and server/search.lua's own header/structure (this file's
    explicit modeling template: proximity-before-mutation, target
    re-verification, server-authoritative item consumption/transfer,
    TOCTOU-safe cooldown stamping via server/cooldowns.lua's shared
    constructors — no hand-rolled cooldown table). `Config.Features.K9Inventory`
    stays `false` shipped, per this resource's "ship disabled until
    acceptance criteria are fully met" convention (DEVELOPER_REFERENCE.md §9
    item 4 / DEVELOPER_REFERENCE.md §13.6 item 8 both still apply: every
    numeric placeholder in Config.K9Inventory needs a config-validator pass,
    and §13.6 item 7's ox_inventory export-signature verification pass —
    see the CONFIDENCE NOTEs below — has not fully happened).

    ======================================================================
    RESOLVED DESIGN DECISION — Config.K9Inventory.accessScope
    (DEVELOPER_REFERENCE.md §13.4.2 open question 1 / §13.6 item 3)

    CONFIRMED and independently RE-VERIFIED against the live, current
    `overextended/ox_inventory` `main` branch source (fetched fresh from
    source — modules/inventory/server.lua's `loadInventoryData`, root
    `server.lua`'s `openInventory`/`forceOpenInventory`,
    modules/bridge/server.lua's `hasGroup`, `registerStash`'s own doc
    comment): an earlier version of this header described
    `accessScope = 'ownerOnly'` as "a fully supported, symmetric code
    path... flippable per-deployment with zero code change." That claim was
    FALSE, and was itself part of the defect — 'ownerOnly' provided NO
    actual access control:

    - ox_inventory's stash-open path (`loadInventoryData`'s stash branch,
      and `openInventory`'s own post-resolve check) gates access
      EXCLUSIVELY via `stash.groups`/`right.groups`, through
      `server.hasGroup(player, groups)`. Both checks are written as
      `stash.groups and ... and not hasGroup(...)` / `right.groups and not
      hasGroup(...)` — a nil `groups` short-circuits straight to ALLOW, for
      every caller, unconditionally. `ResolveStashOwnerAndGroups`'s
      'ownerOnly' branch returned `groups = nil`.
    - `RegisterStash`'s `owner` argument (string OR the boolean `true`
      "personal locker" form) is used EXCLUSIVELY for `Inventories` table
      keying/partitioning (`Inventories[owner and
      ('%s:%s'):format(stash.name, owner) or stash.name]`) and DB
      persistence (`db.saveStash(inv.owner, ...)`) — it is NEVER compared
      against the calling player's own identity anywhere in either
      function. `registerStash`'s own upstream doc comment confirms this is
      intentional, not an oversight: it documents the boolean `true` form as
      "each player has a unique stash, but can request other player's
      stashes" — cross-owner access is upstream-documented, expected
      behavior for that form, not a bug this resource could rely on
      closing.
    - Net effect: once any K9's stash had been registered even once in a
      server session (trivially triggered by that K9 opening their own
      gear), ANY connected player who knew or guessed that citizenid could
      call `exports.ox_inventory:openInventory('stash', 'k9inv-<citizenid>')`
      directly from a modified client and get full read/write access —
      bypassing every check this resource makes (proximity, HasK9Access,
      IsAuthorizedForK9Inventory, the cooldown/mutex) and
      `Config.Features.K9Inventory` itself, since ox_inventory knows nothing
      about that flag.

    CONCLUSION: there is no ox_inventory mechanism this resource can hook to
    make a real, per-K9-owner ACL exist — `groups` (job/rank membership via
    `hasGroup`) is the only actual capability ox_inventory's stash system
    provides. `'department'` already uses exactly that mechanism correctly
    (`groupRank >= (requiredRank or 0)` grants any grade in a listed job,
    matching this resource's documented intent) and remains the shipped
    default below, UNCHANGED — "shared field equipment," the same framing
    this resource already gives `Config.K9Vehicles`' patrol-vehicle trunk
    access, chosen because the K9 in this resource is a full,
    independently-logged-in player character (DEVELOPER_REFERENCE.md §1/§4.5's
    post-correction model): a handler restocking their partner K9's gear
    while the K9 player is offline is the ordinary case this resource is
    built around, not an edge case. The real theft-risk tradeoff
    'department' creates (any officer in the department could pilfer a K9's
    stash) is the same social/administrative-abuse category
    `DEVELOPER_REFERENCE.md#contraband-search` §6's last bullet already
    accepts for search-capability misuse — not a code-level exploit any
    config value here can close.

    `accessScope` is therefore HARD-ENFORCED to `'department'` — the only
    value this file actually implements a real access control for — not
    left selectable with a caveat comment: a config value that can silently
    grant world-readable read/write access to every K9's inventory is
    exactly the class this resource would otherwise treat as a hard startup
    failure, per server/main.lua's `nudgeRequiresUnlocked` assert and
    server/search.lua's own `onResourceStart` config-invariant asserts.

    CHANGED FROM A HARD `assert` TO A WARN-AND-FORCE GUARD, deliberately NOT
    given the same treatment as those two sibling asserts: this field is
    the one case in this file (unlike a missing/wrong-type Config TABLE,
    which has no sane substitute) where an obvious, strictly NARROWER safe
    fallback exists — `'department'` is already the correct, intended,
    shipped value, and is the ONLY value this file implements real access
    control for at all. Aborting this file's ENTIRE `onResourceStart` chain
    (K9 stash registration, the `allowedItems` hook, everything else
    registered in that same handler) over one mistyped config field is a
    disproportionate failure mode when the one correct value is already
    known and unambiguous — unlike server/main.lua's/server/search.lua's
    own asserts, each of which guards a shape with no such safe substitute
    to fall back to. `ResolveConfiguredAccessScope` (below) — same
    clamp-and-warn SHAPE as server/cooldowns.lua's
    `ResolveConfiguredThresholdMs` — now WARNS LOUDLY, naming the exact bad
    value found, on any non-'department' value, then FORCES
    `Config.K9Inventory.accessScope` back to `'department'` for this
    session, writing the corrected value BACK onto
    `Config.K9Inventory.accessScope` itself (never just a local), exactly
    like server/pursuitsprint.lua's own
    `Config.PursuitSprint.speedMultiplier =
    ResolveConfiguredPositiveNumber(...)` precedent — so every other read of
    this field in this file (`ResolveStashOwnerAndGroups`,
    `IsAuthorizedForK9Inventory`, both of which re-read
    `Config.K9Inventory.accessScope` directly, never a cached value) also
    observes the corrected value, not just the guard itself.

    FAILURE DIRECTION, confirmed, not assumed: forcing to `'department'` can
    only ever NARROW access relative to whatever was misconfigured, never
    widen it — every OTHER value (including `'ownerOnly'`, and any typo)
    provides NO real ox_inventory access control at all (see above), i.e.
    the single MOST PERMISSIVE state this field could ever be in is exactly
    the one this fallback replaces; there is no value this field could hold
    that `'department'` would be widening access relative to.
    `ResolveStashOwnerAndGroups` and `IsAuthorizedForK9Inventory` below
    still fail closed for any non-'department' value as defense-in-depth (in
    case a future edit ever reads a DIFFERENT, uncorrected copy of this
    field without going through `ResolveConfiguredAccessScope`), but that
    code path is UNREACHABLE in a running resource today — 'ownerOnly' is
    not an implemented, selectable option, it is a rejected one. Still
    flagged for an explicit human product sign-off before
    `Config.Features.K9Inventory` ever defaults to `true` on a live server.

    ======================================================================
    CONFIDENCE NOTES — every ox_inventory export/shape this file's body
    depends on, graded honestly per the verification performed (or lack of
    it), same discipline server/search.lua's header and
    DEVELOPER_REFERENCE.md#contraband-search §1 already established for
    Phase 2's export surface:

    - `GetInventoryItems`/`GetContainerFromSlot` (server/search.lua's own
      confirmed exports) are NOT used by this file at all — K9Inventory
      never reads/sums a stash's contents server-side, it only registers the
      stash and hands back its id; ox_inventory's own client-side UI (opened
      via `openInventory` below) is what actually presents/moves items once
      access is granted.
    - `exports.ox_inventory:RegisterStash(id, label, slots, weight, owner,
      groups)` — VERIFIED directly against the current
      `overextended/ox_inventory` `main` branch `registerStash` function
      (root server.lua): signature is exactly `registerStash(name, label,
      slots, maxWeight, owner, groups, coords, instance)` — HIGH confidence,
      including for the DYNAMIC, per-player-registered-at-runtime call shape
      used here (one stash per K9 citizenid, registered lazily on first
      request); `registerStash` is fully generic over call timing, nothing
      in it special-cases "declared once at file-load" vs. "called
      lazily at runtime."
    - `owner`/`groups` semantics — VERIFIED directly against the same
      source, including `registerStash`'s own doc comment and the actual
      access-check code in `loadInventoryData`/`openInventory`
      (modules/inventory/server.lua, root server.lua): `groups` —
      `table<jobName, minGrade>` — IS the real, and ONLY, access gate,
      checked via `server.hasGroup(player, groups)` wherever `groups` is
      non-nil; `minGrade = 0` for every configured department (see
      K9InventoryDepartmentGroups below) is this file's own choice to mean
      "any grade in that job," confirmed correct against `hasGroup`'s
      `groupRank >= (requiredRank or 0)` logic. `owner` (string or boolean
      `true`) is NOT an access gate at all — confirmed used exclusively for
      `Inventories` table keying and DB persistence, never compared against
      the requesting player's identity anywhere in either function (see the
      RESOLVED DESIGN DECISION section above for the full trace).
    - `exports.ox_inventory:openInventory('stash', stashId)` (the CLIENT-side
      call, client/inventory.lua) — VERIFIED: this exact call shape
      (`'stash', stash.name`) appears in ox_inventory's own
      modules/inventory/client.lua. HIGH confidence.

    ======================================================================
    `Config.K9Inventory.allowedItems` ENFORCEMENT (previously "DELIBERATELY
    NOT IMPLEMENTED... has NO effect", per both this file's own prior
    header text and config.lua's own comment on the field). DONE (verified,
    issue-closer sweep, 2026-08-26): config.lua's own comment on
    Config.K9Inventory.allowedItems has since been updated to match --
    it now reads "That warning was correct when written and is now
    obsolete: server/inventory.lua enforces the list through ox_inventory's
    own `swapItems` hook." No further action needed on that side; both
    files agree.

    MECHANISM, and the source actually read to confirm it
    (raw.githubusercontent.com/overextended/ox_inventory, `main` branch,
    fetched fresh — no SHA pin available; GitHub's API was not reachable to
    resolve one, only the raw file endpoint was):

    - `exports.ox_inventory:registerHook(event, callback)` — confirmed real,
      `modules/hooks/server.lua`'s `TriggerEventHooks(event, payload)`: for
      EVERY registered hook on `event`, it `pcall`s the hook with `payload`
      and checks the return value. Returning the literal boolean `false`
      makes `TriggerEventHooks` return immediately WITHOUT setting
      `result.success = true` — any other return value (including `nil`,
      i.e. no explicit `return`) leaves `result.success` on track to become
      `true`. This is a REAL pre-mutation veto, not an advisory/observer-only
      callback (the distinction that mattered most to verify, since
      server/tracking.lua's own existing `'swapItems'` hook only ever
      LOGS and never rejects — this file's usage is the first place in this
      resource that relies on the reject path, so it could not simply be
      assumed to work the same way just because the registration call looks
      identical).
    - `modules/inventory/server.lua`'s `ox_inventory:swapItems` callback
      (the single server-side entry point that handles EVERY client-driven
      "move an item from inventory A to inventory B" action — drag-drop
      swap/stack/move onto an existing or empty slot, and drop-to-ground) —
      traced end to end, all four `TriggerEventHooks('swapItems',
      hookPayload)` call sites inside it (`action` = 'swap'/'stack'/'move',
      plus `dropItem`'s separate 'drop' case) — confirms `if not
      hooks.success then return end` runs BEFORE any of that action's actual
      mutation (`Inventory.SwapSlots`, `fromInventory.items[...] = ...`,
      `toInventory.items[...] = ...`). Rejecting from the hook genuinely
      prevents the item from ever being written into the destination
      inventory — not a race, not an after-the-fact undo.
    - `hookPayload.toInventory` is always the DESTINATION inventory's own id
      string (for a stash, exactly the id this file passes as
      `RegisterStash`'s first argument, i.e. `'k9inv-<citizenid>'` here) and
      `hookPayload.fromSlot` is always the FULL item table (`{name=...,
      count=...,  ...}`) being moved OUT of `fromInventory` INTO
      `toInventory` for every one of those branches — confirmed by reading
      each `hookPayload`/`TriggerEventHooks('swapItems', {...})` construction
      site directly, not inferred. This is what makes a per-stash,
      per-incoming-item filter possible from inside a single hook callback
      body without any `itemFilter`/`inventoryFilter`/`typeFilter`
      `registerHook` option (those exist in `modules/hooks/server.lua` too,
      but were deliberately NOT used here — `typeFilter` in particular
      would match `toType == 'stash'` for EVERY registered ox_inventory
      stash on the whole server, not just this resource's K9 gear stashes;
      doing the `'k9inv-'` id-prefix check inside the callback body instead,
      exactly like this file's own `EnsureK9Stash` already assumes that
      prefix is this resource's own naming convention, keeps the filter
      correctly scoped to only the stashes this resource itself registers).
    - `ox_inventory:giveItem` (player-to-player) and the shop `'buyItem'`
      hook were also traced and confirmed to NEVER target a stash
      `toInventory` at all (`giveItem` returns immediately unless
      `toInventory.player` is truthy; the shop's `TriggerEventHooks('buyItem',
      ...)` call always sets `toInventory = playerInv.id`, the buying
      player's own inventory) — so `swapItems` is confirmed the ONLY
      client-reachable path by which an item can end up owned by a stash,
      not merely the most obvious one.

    WHAT IS DELIBERATELY NEVER FILTERED (this resource's own "no unbounded
    trap" constraint, and this file's own "filter what goes IN, never what
    comes OUT" framing): the hook body below only inspects
    `payload.fromSlot` (the item entering `toInventory`) and only ever acts
    when `payload.toInventory` resolves to a K9 stash AND differs from
    `payload.fromInventory` — an item already inside a K9 stash moving to a
    DIFFERENT slot in that SAME stash (`fromInventory == toInventory`, e.g.
    reorganizing/restacking) is never re-filtered, and taking an item OUT
    of a K9 stash into any other inventory is structurally invisible to
    this filter (`toInventory` is the destination the OTHER inventory in
    that case, never the K9 stash) — ox_inventory's own slot/weight limits
    are the only restriction on withdrawals. This also means an item that
    was already sitting in a K9 stash before `allowedItems` was configured
    (or before it was tightened) is never retroactively stuck — it can
    always be taken back out, only never re-deposited once removed if it is
    no longer on the list.

    RUNTIME CAPABILITY GUARD: same posture the since-deleted
    `IsOxInventoryHookCapable` helper and server/tracking.lua's ScentTracking
    `onResourceStart` block originally established for this same
    `registerHook` export (that
    file's own header has the full "why a runtime check, not a
    `dependencies` version pin" writeup — not re-derived here). UPDATE: the
    small LOCAL copy of that capability check this file used to keep
    (`IsOxInventoryHookCapable`) has since been deleted outright — see
    `RegisterK9InventoryItemFilterHook`'s own doc comment below for the
    compat-layer migration — closing the former REFACTOR_ROADMAP duplicate
    this header used to flag here; the check is now performed once, per
    whatever backend `Config.Compat` resolves, inside
    `K9Compat.Get('inventory').RegisterHook` (shared/compat/inventory.lua),
    the same fix server/tracking.lua's identical duplicate already got. If
    that routed check fails while `Config.Features.K9Inventory` AND a
    non-nil `Config.K9Inventory.allowedItems` are both configured, this file
    prints ONE warning and leaves the whitelist genuinely unenforced (the
    stash itself keeps working, unfiltered) — never a fake/silent pass.
    This was NOT the path taken here: the mechanism above WAS independently
    verified against real, current ox_inventory source, so the hook is
    registered for real whenever the capability check passes (expected to
    be the normal case on any current ox_inventory install).

    ======================================================================
    EVENT/CALLBACK CONTRACT.

    Callbacks (ox_lib lib.callback):
    1. 'john-k9:server:openK9Inventory' (targetNetId: number)
       -> { ok: boolean, reason: string?, stashId: string? } [THIS FILE]
       See HandleOpenK9Inventory's own doc comment below for the full
       validation order. Returns the resolved, server-derived stash id ONLY
       to an interactor who passed every check below — the client then opens
       it via ox_inventory's own `openInventory` export (client/inventory.lua),
       whose OWN owner/groups check (set at RegisterStash time below) is the
       REAL access-control boundary, per DEVELOPER_REFERENCE.md §13.4.2's own framing:
       "the ox_target option's client-side visibility... is a UX convenience
       only... A modified client calling
       exports.ox_inventory:openInventory('stash', 'k9inv-<anyCitizenid>')
       directly must be rejected by ox_inventory's own owner/group check, not
       by anything this resource adds on top." The authorization re-check
       inside HandleOpenK9Inventory below is DEFENSE IN DEPTH on top of that
       real boundary (matches this file's own header claim of
       server/search.lua-level scrutiny), not a substitute for it — this
       resource's actual responsibility, per that same spec passage, is
       choosing correct, restrictive owner/groups values at registration
       time (ResolveStashOwnerAndGroups below), never re-implementing access
       control itself.

    Server events (RegisterNetEvent, client->server): none. Entirely
    request/response shaped, same posture server/search.lua's header
    documents for the identical reason — no legitimate reason for a
    fire-and-forget "I opened it" event to exist.

    ox_inventory hooks (exports.ox_inventory:registerHook, ox_inventory ->
    this file, NOT a client-reachable event at all):
    2. 'swapItems' — registered conditionally at THIS resource's own
       onResourceStart AND, so a later independent ox_inventory restart
       cannot silently disable enforcement for the rest of this resource's
       uptime, at ox_inventory's OWN onResourceStart too (see
       `RegisterK9InventoryItemFilterHook`/the `AddEventHandler` dispatching
       to it below), gated on Config.Features.K9Inventory AND a non-nil
       Config.K9Inventory.allowedItems AND a successful hook registration
       (mirrors server/tracking.lua's identical ScentTracking gating
       shape/reasoning for the same export — see this file's header
       "RUNTIME CAPABILITY GUARD" section). Enforces
       Config.K9Inventory.allowedItems for THIS resource's own K9 gear
       stashes only (`'k9inv-'`-prefixed ids) — see this file's header for
       the full mechanism/verification writeup and the "filter what goes
       IN, never what comes OUT" scope of what it does and does not touch.

    Client events (RegisterNetEvent, server->client): none.

    Commands: none.

    Automatic path: none. Stash registration is lazy (on first request), NOT
    on PlayerLoaded — DEVELOPER_REFERENCE.md §13.4.2 explicitly offers this as an
    equally-valid alternative to PlayerLoaded-time registration ("On
    PlayerLoaded (or lazily, on first interaction attempt)"), chosen here to
    avoid adding a second PlayerLoaded consumer/dependency for a capability
    most K9 characters may never actually use in a given session.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)` and `IsConfiguredK9Model(modelHash)`,
      resource-globals from server/certifications/ — reused, never
      re-derived, same rule server/search.lua and server/main.lua already
      follow.
    - THIS FILE exposes NO resource-global functions.
    - THIS FILE owns `K9InventoryOpenCooldown` and `K9InventoryOpenMutex`
      below as file-local state, each a server/cooldowns.lua tracker
      instance (DEVELOPER_REFERENCE.md item 1's established convention — no
      hand-rolled cooldown/mutex table).
    - THIS FILE calls `ResolveNetworkEntity(netId, expectedEntityType?)` and
      `ResolveConnectedPlayerFromPed(entity)`, both resource-globals from
      server/entities.lua (DEVELOPER_REFERENCE.md item 2/item 2b) — do not
      re-implement either resolve/existence-guard sequence here.
      HandleOpenK9Inventory below used to define its own bare
      `if entity == 0 then` check (no `DoesEntityExist` guard at all — the
      weakest surviving copy of this pattern in the whole resource) plus a
      small local copy of `ResolveConnectedPlayerFromPed`, duplicated from
      server/search.lua's function of the same name/purpose because, at the
      time this file was written, server/search.lua exposed no
      resource-global functions to reuse. Both are now the shared
      server/entities.lua globals instead — see HandleOpenK9Inventory's own
      comment for the exact migration.
    - THIS FILE also CONSUMES a second export from ox_inventory (a
      dependency in the "this file's runtime behavior is contingent on
      external code" sense, not a call THIS FILE initiates) —
      `exports.ox_inventory:registerHook('swapItems', ...)`, the same
      export/event name server/tracking.lua's ScentTracking branch already
      consumes for an unrelated purpose (log-only, never rejects). The two
      registrations are entirely independent (ox_inventory supports
      multiple hooks per event, confirmed against `modules/hooks/server.lua`'s
      `eventHooks[event]` being an ARRAY, not a single slot) — this file
      does not call, depend on, or need to know about server/tracking.lua's
      registration, and does not touch that file to add one either; this
      file runs its own independent capability check instead (see header
      RUNTIME CAPABILITY GUARD section for why). That check was once a small
      local duplicate of a `IsOxInventoryHookCapable` helper in
      server/tracking.lua; both were deleted in the compat-layer migration
      and both are now the boolean
      `K9Compat.Get('inventory').RegisterHook` returns.
    ======================================================================
]]

-- Per-interactor-source cooldown on the openK9Inventory REQUEST itself
-- (distinct from, and much cheaper than, server/search.lua's per-target
-- searchCooldownMs — this action grants access to a persistent stash, not a
-- one-shot information probe, so the only real concern is request-spam, not
-- information-farming). Mirrors LEASH_REQUEST_COOLDOWN_MS's exact shape/
-- rationale in server/main.lua.
local K9_INVENTORY_OPEN_COOLDOWN_MS = 1000
local K9InventoryOpenCooldown = NewCooldown(K9_INVENTORY_OPEN_COOLDOWN_MS)
K9InventoryOpenCooldown.RegisterPlayerDropped()

-- Defensive per-interactor-source mutex, mirroring server/search.lua's
-- SearchMutex — added even though RegisterStash is NOT confirmed to be a
-- yielding call (see this file's header CONFIDENCE NOTE): if it turns out
-- to yield on some ox_inventory internal path not observed here, this
-- closes the exact same same-source concurrent-call race server/search.lua's
-- SearchMutex closes for GetInventoryItems, at negligible cost if it never
-- actually yields. Set synchronously before any potentially-yielding work,
-- cleared on every exit path.
local K9InventoryOpenMutex = NewMutex()
K9InventoryOpenMutex.RegisterPlayerDropped()

-- Ephemeral, session-only set of citizenids whose K9 stash has already been
-- RegisterStash'd this server session — avoids re-registering (and
-- re-deriving owner/groups) on every single open request. Deliberately
-- never evicted: unlike server/certifications/'s Certifications table
-- (which held security-relevant, potentially-stale state), a stale entry
-- here can never cause an incorrect access decision — it only ever skips a
-- redundant RegisterStash call for a citizenid this session has already
-- seen. Bounded in practice by the number of distinct K9 characters
-- actually accessed in one server session, not unbounded resource-lifetime
-- growth.
local EnsuredK9Stashes = {}

-- Precomputed `table<jobName, minGrade>` for the 'department' accessScope
-- shape, built once at file load from Config.Departments (generic over that
-- table per this codebase's existing convention — DEVELOPER_REFERENCE.md §3 acceptance
-- bullet 3 — no hardcoded job name). `minGrade = 0` for every configured
-- department: this resource's own choice to mean "any grade within that
-- job may access," not a verified ox_inventory default (see this file's
-- header CONFIDENCE NOTE).
local K9InventoryDepartmentGroups = {}
for jobName in pairs(Config.Departments) do
    K9InventoryDepartmentGroups[jobName] = 0
end

-- CONFIG-SAFETY GUARD (originally a hard assert, changed to a
-- warn-and-force guard — see this file's header RESOLVED DESIGN DECISION
-- section for the full before/after reasoning and the failure-direction
-- proof). `'department'` is the ONLY `Config.K9Inventory.accessScope`
-- value this file implements a real ox_inventory access control for --
-- `'ownerOnly'` (or any other value) relies on ox_inventory's `owner`
-- RegisterStash argument, which is never checked against the calling
-- player's identity anywhere in ox_inventory's own open-inventory path
-- (independently verified against the live, current
-- `overextended/ox_inventory` source): `groups` via `server.hasGroup` is
-- the only real gate, and a nil `groups` (what 'ownerOnly' produces)
-- short-circuits to ALLOW for every caller. Warning loudly and forcing the
-- one safe value here, at resource start, rather than letting a
-- misconfigured value silently grant world-readable read/write access to
-- every K9's stash — placed in THIS file (not centralized) because this is
-- the file whose security model actually depends on it, same reasoning
-- server/search.lua's own header already gives for that placement choice.
--- Same clamp-and-warn SHAPE as server/cooldowns.lua's
--- ResolveConfiguredThresholdMs: validate, and on failure, print ONE loud
--- (never silent) warning naming the exact bad value found and what is
--- being substituted, then return the safe value — NEVER throws, NEVER
--- aborts the caller.
--- @return string accessScope -- always 'department'
local function ResolveConfiguredAccessScope()
    local configured = Config.K9Inventory.accessScope
    if configured == 'department' then
        return 'department'
    end

    print(
        ("[John-K9] server/inventory.lua: Config.K9Inventory.accessScope is not 'department' " ..
         "(found: %s). 'department' is the ONLY accessScope value this file implements a real " ..
         "ox_inventory access control for -- ox_inventory's RegisterStash only gates stash access via " ..
         'its `groups` argument (server.hasGroup); the `owner` argument (what every other value, ' ..
         "including 'ownerOnly', relies on) is never checked against the calling player's identity " ..
         "anywhere in ox_inventory's own open-inventory path. Left uncorrected, this would silently let " ..
         "ANY connected player who knows or guesses a K9's citizenid open that K9's stash directly via " ..
         "exports.ox_inventory:openInventory('stash', 'k9inv-<citizenid>'), bypassing every check this " ..
         'resource makes (proximity, HasK9Access, IsAuthorizedForK9Inventory, the cooldown/mutex) and ' ..
         "Config.Features.K9Inventory itself. FORCING Config.K9Inventory.accessScope back to " ..
         "'department' for this session so K9 stashes stay gated to department membership instead -- " ..
         'find Config.K9Inventory.accessScope in config.lua and set it to \'department\' to clear this ' ..
         'warning.'
        ):format(tostring(configured))
    )
    return 'department'
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- Writes the resolved value BACK onto Config.K9Inventory.accessScope
    -- itself (never just a local) so every other read of this field in this
    -- file (ResolveStashOwnerAndGroups/IsAuthorizedForK9Inventory below, both
    -- of which re-read Config.K9Inventory.accessScope directly) observes the
    -- corrected value too, not just this guard.
    Config.K9Inventory.accessScope = ResolveConfiguredAccessScope()
end)

-- ======================================================================
-- Config.K9Inventory.allowedItems ENFORCEMENT — see this file's header for
-- the full mechanism/verification writeup. Everything below this point
-- (through the onResourceStart block that calls registerHook) implements
-- this; nothing above this comment is part of it.
-- ======================================================================

-- Precomputed `table<itemName, true>` lookup, built once at file load from
-- Config.K9Inventory.allowedItems — same "precompute a set from a config
-- array, once, at file load" convention server/search.lua's own
-- ContrabandItemSet already establishes for Config.SearchContrabandItems
-- (both are plain arrays of item-name strings; O(1) membership test instead
-- of re-scanning the config array on every filtered transfer). Stays `nil`
-- (never an empty table) when Config.K9Inventory.allowedItems is `nil`,
-- matching that field's own documented "nil = no item whitelist enforced"
-- meaning exactly — this is also what the onResourceStart block below
-- checks to decide whether to register the hook at all.
local K9InventoryAllowedItemSet = nil
if Config.K9Inventory.allowedItems then
    K9InventoryAllowedItemSet = {}
    for _, itemName in ipairs(Config.K9Inventory.allowedItems) do
        K9InventoryAllowedItemSet[itemName] = true
    end
end

--- COMPAT-LAYER MIGRATION: the local `IsOxInventoryHookCapable()`
--- runtime-capability probe that used to live here (a byte-for-byte
--- duplicate of server/tracking.lua's function of the same name —
--- `GetResourceState('ox_inventory') == 'started'` + pcall'd export-access,
--- run BEFORE the actual `registerHook` call below) is DELETED outright,
--- not kept alongside the new call. `K9Compat.Get('inventory').RegisterHook`
--- (shared/compat/core.lua's RequiredMethods.inventory.server.RegisterHook,
--- registered against real signatures in shared/compat/inventory.lua)
--- already performs the identical capability check internally, per-adapter,
--- for WHATEVER inventory backend Config.Compat actually resolved — a
--- second, ox_inventory-only copy here would answer the wrong question on a
--- qb-inventory server (ox_inventory not started -> always `false`, even
--- when qb-inventory's own real hook mechanism IS available), so it is not
--- kept as defense-in-depth, it is removed as a hardcoded-backend
--- regression waiting to happen. `RegisterK9InventoryItemFilterHook` below
--- now reads `RegisterHook`'s own boolean return value to decide whether to
--- print the "unenforced" warning, preserving the exact "warn once, whitelist
--- genuinely unenforced, stash itself keeps working" behavior this file's
--- own header already documents — see that function's own doc comment for
--- the full updated writeup.
---
--- Config.K9Inventory.allowedItems ENFORCEMENT. GATED AT REGISTRATION, same
--- "config-gated registration, not just config-gated behavior" convention
--- server/tracking.lua's ScentTracking block already establishes for this
--- identical export: if Config.Features.K9Inventory is false, OR
--- Config.K9Inventory.allowedItems is nil (no whitelist configured —
--- nothing to enforce), the hook is never registered at all. If a
--- whitelist IS configured but the hook registration fails, this
--- prints ONE warning and leaves the whitelist genuinely unenforced (the K9
--- stash itself keeps working, unfiltered) rather than pretending — same
--- honest-soft-disable posture server/tracking.lua's ScentTracking block
--- already established for this exact export.
---
--- Invoked from `onResourceStart` on TWO triggers (see the `AddEventHandler`
--- below this function's body for the dispatch), not just THIS resource's
--- own start: ox_inventory is a hard `fxmanifest.lua` dependency, so by the
--- time THIS resource's own onResourceStart fires, ox_inventory is already
--- running (or knowably not) — no player-facing stash interaction can occur
--- before this resource itself has finished starting anyway — but a bare
--- `restart ox_inventory` later in the same session wipes ox_inventory's own
--- hook table clean without touching this resource at all, so this function
--- must ALSO re-run on ox_inventory's own onResourceStart or the whitelist
--- goes silently unenforced for the rest of this resource's uptime. See the
--- `local function RegisterK9InventoryItemFilterHook()` line just below for
--- the full writeup of this lifecycle fix.
---
--- See this file's header for the full verified mechanism (why returning
--- `false` from this hook is a real pre-mutation veto, why only
--- `payload.fromSlot` against a `'k9inv-'`-prefixed, differing
--- `payload.toInventory` is ever inspected, and why that scope can never
--- trap an item already inside a K9 stash).
---
--- PULLED OUT TO A NAMED FUNCTION (LIFECYCLE FIX) so it can be invoked from
--- BOTH lifecycle points registered below it -- THIS resource's own
--- onResourceStart (the original call site) and ox_inventory's OWN
--- onResourceStart. Mirrors server/tracking.lua's RegisterScentInventoryHook
--- fix for the identical gap against the identical export -- see that
--- function's own doc comment for the full source-verified "ox_inventory's
--- `eventHooks` table is a plain file-local Lua variable, re-initialized
--- empty on every ox_inventory (re)load, with no symmetric mechanism to ask
--- a still-running OTHER resource to re-register after ox_inventory itself
--- restarts" writeup (not re-derived here). Without the second trigger, a
--- bare `restart ox_inventory` (a normal ops action, e.g. after an
--- ox_inventory update) that does not also restart john-k9 would leave
--- allowedItems enforcement silently, permanently disabled for the rest of
--- john-k9's uptime -- worse than the already-accepted "silently inert,
--- loudly warned ONCE" posture below, since in that specific case no
--- warning would ever print either (nothing about THIS resource changed to
--- trigger one). Idempotent to call repeatedly across however many times
--- either resource restarts, for the same reason RegisterScentInventoryHook
--- is: each ox_inventory restart already wiped its own hook table clean
--- first, so there is never anything stale here to duplicate.
local function RegisterK9InventoryItemFilterHook()
    if not Config.Features.K9Inventory then return end -- nothing to gate for; do not probe/warn about a disabled-by-default feature
    if not K9InventoryAllowedItemSet then return end -- no whitelist configured -- Config.K9Inventory.allowedItems' own documented `nil` meaning; inert by config choice, not by missing capability, so no warning either

    -- ROUTED THROUGH K9Compat.Get('inventory') --
    -- shared/compat/core.lua's RequiredMethods.inventory.server.RegisterHook
    -- -- never a direct `exports.ox_inventory:registerHook` call. The
    -- capability check that used to gate this call (`IsOxInventoryHookCapable()`,
    -- deleted above) is now performed inside the adapter itself, per
    -- whatever backend Config.Compat actually resolved -- `RegisterHook`
    -- returns `false` (never throws) whenever nothing usable is available,
    -- which is exactly what the warning below now branches on, preserving
    -- the same "warn once, whitelist genuinely unenforced, stash itself
    -- keeps working unfiltered" behavior this file's own header documents.
    --
    -- EVENT-NAME SCOPE, unchanged: 'swapItems' is the only event name any
    -- non-ox_inventory adapter has a confirmed translation for (see
    -- shared/compat/inventory.lua's own "RegisterHook VOCABULARY" section) --
    -- this file already only ever registered for 'swapItems', so no change
    -- was needed here on that front.
    --
    -- PAYLOAD SHAPE, unchanged: the callback body below reads
    -- `payload.fromInventory`, `payload.toInventory`, `payload.fromSlot` --
    -- exactly ox_inventory's own real 'swapItems' field names, which is also
    -- the exact vocabulary every adapter's RegisterHook is contracted to
    -- translate onto (never a reinvented shape) -- so this callback body
    -- needed NO change to work against any backend's adapter, only the
    -- registration call itself.
    local registered = K9Compat.Get('inventory').RegisterHook('swapItems', function(payload)
        -- An item already inside a K9 stash moving to a DIFFERENT SLOT in
        -- that SAME stash (reorganizing/restacking) is not an incoming
        -- transfer from outside -- never re-filtered (header "WHAT IS
        -- DELIBERATELY NEVER FILTERED").
        if payload.fromInventory == payload.toInventory then return end

        -- Only ever restrict THIS resource's own K9 gear stashes
        -- (`'k9inv-<citizenid>'`, this file's own EnsureK9Stash naming
        -- convention) -- never any other ox_inventory stash on the server
        -- (player houses, gang stashes, evidence lockers, etc). Deliberately
        -- an id-prefix check inside the callback body rather than a
        -- `typeFilter` registerHook option, which would match `toType ==
        -- 'stash'` for EVERY stash on the server (see header).
        if type(payload.toInventory) ~= 'string' or not payload.toInventory:find('^k9inv%-') then
            return
        end

        -- The item ENTERING toInventory -- confirmed against source to
        -- always be the full item table for every swapItems branch that can
        -- reach a stash toInventory (see header). Defensive type checks
        -- only: a shape mismatch here means some other resource/ox_inventory
        -- version is driving this hook differently than confirmed here --
        -- fail OPEN (never filter) rather than reject on a shape this file
        -- cannot actually interpret, matching this file's own "never a
        -- fake/silent pass, but also never a confidently-wrong reject"
        -- posture.
        local incomingItem = payload.fromSlot
        if type(incomingItem) ~= 'table' or type(incomingItem.name) ~= 'string' then
            return
        end

        if not K9InventoryAllowedItemSet[incomingItem.name] then
            return false -- REJECT: not on Config.K9Inventory.allowedItems -- verified pre-mutation veto (see header)
        end
    end)

    if not registered then
        print('[John-K9] WARNING: Config.K9Inventory.allowedItems is configured but ' ..
            'no compatible inventory backend hook registration succeeded (see /k9compat, if ' ..
            'enabled, for exactly why) -- the K9 gear stash item whitelist is NOT enforced. The ' ..
            'stash itself still functions normally (any item can be deposited); only the ' ..
            'allowedItems restriction is disabled.')
    end
end

-- LIFECYCLE FIX: dispatches to RegisterK9InventoryItemFilterHook() above on
-- TWO distinct triggers, not just one -- see that function's own doc
-- comment for the full writeup of why the second branch is required
-- (mirrors server/tracking.lua's identical fix for the identical
-- export/gap).
--
-- Branch 1 (original, unchanged behavior): THIS resource's own start.
-- Branch 2 (COMPAT-LAYER MIGRATION): used to hardcode
-- `resourceName == 'ox_inventory'` -- now asks K9Compat itself which
-- resource actually backs the 'inventory' system, same pattern
-- client/inventory.lua's own RegisterK9InventoryOxTargetOption dispatch
-- already establishes for the 'target' system. `K9Compat.Redetect()` is
-- forced here (not relying on shared/compat/core.lua's own
-- onResourceStart redetect hook having already run for this SAME event)
-- so this check is correct regardless of relative handler-registration
-- order between the two files. Hardcoding 'ox_inventory' here would have
-- silently reopened exactly the single-backend gap this fix exists to
-- close: a qb-inventory server restarting qb-inventory would never
-- re-trigger this branch at all.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterK9InventoryItemFilterHook()
        return
    end

    K9Compat.Redetect()
    if resourceName == K9Compat.Which('inventory') then
        RegisterK9InventoryItemFilterHook()
    end
end)

-- ResolveConnectedPlayerFromPed(entity) used to be defined here as a small
-- local copy of server/search.lua's function of the same name/purpose.
-- Extracted to server/entities.lua as a resource-global per
-- DEVELOPER_REFERENCE.md item 2b (three independent copies existed by then —
-- this file, server/search.lua, server/combat.lua) — see this file's
-- header FILE-TO-FILE CONTRACT and server/entities.lua's own doc comment
-- for the full "why not GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))"
-- rationale, preserved there. HandleOpenK9Inventory below now calls the
-- shared global instead.

--- Resolves the `owner`/`groups` RegisterStash arguments for a given K9
--- citizenid, per Config.K9Inventory.accessScope. See this file's header
--- RESOLVED DESIGN DECISION section for the full reasoning. The
--- onResourceStart guard above (ResolveConfiguredAccessScope, which WARNS
--- and FORCES Config.K9Inventory.accessScope back to 'department' rather
--- than asserting) guarantees accessScope is always 'department' in a
--- running resource — the branch below is UNREACHABLE dead code today,
--- kept only as defense-in-depth (fails to the most restrictive shape,
--- single-owner/no-groups, rather than the more permissive 'department'
--- reading) in case a future edit ever reads a different, uncorrected copy
--- of this field without going through that guard.
--- @param citizenid string
--- @return string|boolean owner
--- @return table? groups
local function ResolveStashOwnerAndGroups(citizenid)
    if Config.K9Inventory.accessScope == 'department' then
        return false, K9InventoryDepartmentGroups
    end

    -- UNREACHABLE in a running resource (see doc comment above) — defense
    -- in depth only. Fails CLOSED to the most restrictive shape
    -- (single-owner, no groups) rather than silently treating a typo as the
    -- more permissive 'department' reading. NOTE: unlike the real
    -- 'department' path above, this shape provides NO actual ox_inventory
    -- access control at all (see header) — it is not a safe fallback to
    -- rely on, only a non-worse one.
    return citizenid, nil
end

--- Defense-in-depth authorization check for the INTERACTING player (never
--- the real access boundary — see this file's header EVENT/CALLBACK
--- CONTRACT section for why ox_inventory's own owner/groups check, set via
--- ResolveStashOwnerAndGroups above at registration time, is the actual
--- security boundary). Mirrors CheckLeashEligibility's officer-side rule in
--- server/main.lua: department membership only, no certification required
--- of the interactor — matches DEVELOPER_REFERENCE.md §13.2's own "any player whose
--- job ∈ Config.Departments may open it" framing for the 'department' scope.
--- @param interactorJobName string?
--- @param isSelf boolean
--- @return boolean authorized
local function IsAuthorizedForK9Inventory(interactorJobName, isSelf)
    if isSelf then return true end -- the K9 player accessing their own stash is always authorized, independent of accessScope

    if Config.K9Inventory.accessScope == 'department' then
        return interactorJobName ~= nil and Config.Departments[interactorJobName] ~= nil
    end

    -- UNREACHABLE in a running resource (the onResourceStart guard above,
    -- ResolveConfiguredAccessScope, guarantees accessScope == 'department')
    -- — fails closed, same direction/reasoning as ResolveStashOwnerAndGroups
    -- above, kept only as defense-in-depth.
    return false
end

--- Idempotent (per server session) stash registration for `citizenid`. Only
--- calls the (session-unverified, see this file's header) RegisterStash
--- export once per citizenid per session.
---
--- ROUTED THROUGH K9Compat.Get('inventory') --
--- shared/compat/core.lua's RequiredMethods.inventory.server.RegisterStash
--- -- never a direct `exports.ox_inventory:RegisterStash` call.
--- `K9Compat.Get('inventory').RegisterStash` already pcall-wraps the
--- underlying export call (BuildSafeAdapter, shared/compat/core.lua) and
--- returns a plain boolean -- the pcall this function used to wrap the raw
--- export call in is no longer needed, but this also means a genuine
--- underlying error's text is no longer available for the warning below
--- (same disclosed trade-off as this file's RegisterShop-equivalent sibling,
--- server/equipmentshop.lua).
---
--- STUB-DEGRADE ANALYSIS (this is the security-critical mutation this file
--- grants, so it is answered here explicitly): ox_inventory is a hard
--- fxmanifest.lua dependency today, so this call has never had to survive
--- it being absent. Routed through K9Compat, a fully undetected inventory
--- (the no-op stub) makes RegisterStash return `nil` (falsy) -- this
--- function returns `false`, HandleOpenK9Inventory's caller
--- (lib.callback.register('john-k9:server:openK9Inventory', ...)) reports
--- `{ ok = false, reason = 'stash_failed' }`, and client/inventory.lua's own
--- K9_INVENTORY_REASON_MESSAGES table already has a `stash_failed` entry
--- (`locale('inventory.reason_stash_failed')`) wired to a player-facing
--- error notify -- a genuinely clean "feature switched off" degrade, not a
--- hang or an uncaught error, and not a NEW code path either: this is the
--- exact same reason value/notify this file already returned before this
--- change whenever the (previously ox_inventory-only) pcall'd RegisterStash
--- call failed. On qb-inventory specifically (the other CONFIRMED backend),
--- RegisterStash is REAL (composed onto `CreateInventory`, per
--- shared/compat/inventory.lua's own qb-inventory section) so the K9
--- stash itself is genuinely created -- but this file's own onResourceStart
--- guard (ResolveConfiguredAccessScope) already forces
--- `Config.K9Inventory.accessScope == 'department'`, and qb-inventory's
--- `groups`/`owner` arguments are silently
--- discarded by that adapter (no per-inventory ACL concept exists on that
--- backend at all, per that adapter's own header) -- meaning the real access
--- boundary for a qb-inventory-backed K9 stash is ENTIRELY this file's own
--- server-side checks (HasK9Access, IsAuthorizedForK9Inventory, proximity),
--- never anything qb-inventory itself enforces. That is unchanged (those
--- checks all ran before EnsureK9Stash is ever reached, and still do) --
--- flagged here only because it is the one place "which backend is active"
--- changes what is actually the security boundary, which is worth a reader
--- knowing explicitly rather than assuming ox_inventory's groups-based
--- enforcement is universal.
--- @param citizenid string
--- @return boolean ok
local function EnsureK9Stash(citizenid)
    if EnsuredK9Stashes[citizenid] then
        return true
    end

    local owner, groups = ResolveStashOwnerAndGroups(citizenid)
    local stashId = ('k9inv-%s'):format(citizenid)
    local label = locale('inventory.stash_label')

    local registered = K9Compat.Get('inventory').RegisterStash(stashId, label, Config.K9Inventory.slots, Config.K9Inventory.maxWeight, owner, groups)

    if not registered then
        print(('[John-K9] RegisterStash failed for %s -- no compatible inventory backend is currently detected/running, or it rejected this stash (see /k9compat, if enabled).'):format(stashId))
        return false
    end

    EnsuredK9Stashes[citizenid] = true
    return true
end

--- Internal implementation for the openK9Inventory callback below. Called
--- only after the callback's own cheap checks (payload shape, feature flag,
--- in-flight mutex, cooldown) already passed. Mirrors
--- server/search.lua's HandleSearchTarget validation-order discipline
--- exactly, applied to a different capability grant:
---   1-2. Resolve `targetNetId` to a live, currently-existing entity AND
---      cross-check its REAL type is a ped in one call — never trust a
---      claimed type (there's no client-supplied targetType here at all,
---      unlike search.lua, since this feature only ever targets a K9 ped).
---      DEVELOPER_REFERENCE.md item 2: was this function's own bare
---      `if entity == 0 then` check — no `DoesEntityExist` call, no
---      netId-type guard at all, the weakest surviving copy of this
---      pattern in the resource — followed by a SEPARATE
---      `GetEntityType(entity) ~= 1` check. Both are now
---      server/entities.lua's shared `ResolveNetworkEntity()`, called with
---      expectedEntityType = 1 (ped-only, same restriction as before, not
---      loosened) to fold both into one call and add the missing
---      `DoesEntityExist` guard.
---   3. Resolve the entity to a currently-connected player (never an NPC).
---   4. Confirm the target's LIVE server-side ped model is a configured K9
---      model (IsConfiguredK9Model) — this is specifically a "K9 gear"
---      interaction, not a generic player-inventory bridge.
---   5. Confirm the target currently HasK9Access — a decertified K9 has lost
---      the underlying K9 capability set, same posture certification revoke
---      already takes for leash pairings (server/certifications/'s
---      ForceDetachLeashForSource).
---   6. MANDATORY, FIRST-CLASS live proximity check, run BEFORE any
---      mutation (stash registration/access grant) — same "never trust a
---      client-claimed target is actually nearby" discipline
---      server/search.lua's step 3 and server/main.lua's
---      relayDoorScratch/CheckLeashEligibility all already apply.
---   7. Resolve the interactor's own citizenid/job server-side (never
---      client-claimed) and defense-in-depth authorize via
---      IsAuthorizedForK9Inventory.
---   8. Stamp the cooldown NOW, before the (session-unverified,
---      possibly-yielding — see this file's header) RegisterStash call.
---   9. EnsureK9Stash — the real, server-authoritative capability grant.
---  10. Return the resolved stash id to the caller only.
--- @param source number
--- @param targetNetId number
--- @return table result
local function HandleOpenK9Inventory(source, targetNetId)
    -- GetEntityType: 1 = ped, 2 = vehicle, 3 = object. Ped-only restriction
    -- preserved exactly (see this function's own doc comment above).
    local entity = ResolveNetworkEntity(targetNetId, 1)
    if not entity then
        return { ok = false, reason = 'invalid_target' }
    end

    local targetServerId = ResolveConnectedPlayerFromPed(entity)
    if not targetServerId then
        return { ok = false, reason = 'invalid_target' } -- NPC, or no longer a connected player's ped
    end

    -- WIDENED (K9 role/model decoupling, server/appearance.lua), NOT
    -- DELETED: removing this check outright was considered and rejected,
    -- reasoning that the HasK9Access(targetServerId) check immediately
    -- below already "is" the role check. That reasoning does not hold up:
    -- HasK9Access is deliberately BROADER than the K9 role (HasK9Role) --
    -- it also returns true for a high-command bypass
    -- (server/highcommand.lua's IsHighCommand) or an officer above
    -- Config.Departments' autoAccessGrade threshold, NEITHER of whom is
    -- actually the K9 in a handler/K9 pairing. Deleting this line outright
    -- would have made ANY such officer's own citizenid a valid target for
    -- "open their K9 gear inventory" the moment they were merely standing
    -- near another player, on their own ordinary human model, holding
    -- neither a K9 model nor the K9 role -- a real widening of who can be
    -- treated as "the K9 gear" beyond this file's own doc comment above
    -- ("this is specifically a 'K9 gear' interaction, not a generic
    -- player-inventory bridge"). OR-ing in HasK9Role(targetServerId)
    -- instead keeps that invariant intact: only a live K9 model OR a
    -- genuine K9-role holder can be targeted at all, and HasK9Access below
    -- still independently confirms that access hasn't since lapsed. Same
    -- `type(...) == 'function'` guard/fail-closed reasoning as every other
    -- site widened the same way (server/main.lua's CheckLeashEligibility
    -- has the fullest writeup).
    if not (IsConfiguredK9Model(GetEntityModel(entity)) or (type(HasK9Role) == 'function' and HasK9Role(targetServerId))) then
        return { ok = false, reason = 'invalid_target' } -- not currently playing a recognized K9 model, and does not hold the decoupled K9 role either
    end

    if not HasK9Access(targetServerId) then
        return { ok = false, reason = 'no_access' } -- target is not (or is no longer) a certified, working K9
    end

    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any mutation.
    local interactorPed = GetPlayerPed(source)
    if interactorPed == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    local dist = #(GetEntityCoords(interactorPed) - GetEntityCoords(entity))
    if dist > Config.K9Inventory.interactRange then
        return { ok = false, reason = 'too_far' }
    end

    local isSelf = source == targetServerId
    local interactorPlayer = exports.qbx_core:GetPlayer(source)
    local interactorJobName = interactorPlayer and interactorPlayer.PlayerData and interactorPlayer.PlayerData.job and interactorPlayer.PlayerData.job.name

    if not IsAuthorizedForK9Inventory(interactorJobName, isSelf) then
        return { ok = false, reason = 'not_authorized' }
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not targetCitizenid then
        return { ok = false, reason = 'invalid_target' }
    end

    -- Stamp the cooldown NOW, before the possibly-yielding RegisterStash
    -- call below (DEVELOPER_REFERENCE.md#contraband-search §3 step 13's
    -- exact "stamp before the awaited work" discipline, applied here
    -- defensively even though RegisterStash is not confirmed to yield).
    K9InventoryOpenCooldown.Touch(source)

    if not EnsureK9Stash(targetCitizenid) then
        return { ok = false, reason = 'stash_failed' }
    end

    return { ok = true, stashId = ('k9inv-%s'):format(targetCitizenid) }
end

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.K9Inventory
--- flag) is already checked by the callback below, before this function is
--- ever reached. Gates the INTERACTOR (`source` in the callback below) --
--- the person requesting to open a K9's gear stash, whether that is the
--- K9's own player opening their own gear or a departmental handler opening
--- a partner's -- not the target K9 the stash belongs to:
---   2. an explicit block.K9Inventory grant -> DENY
---   3. K9Inventory listed in RequireGrant -> ALLOW only with an active
---      feature.K9Inventory grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsK9InventoryPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.K9Inventory') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.K9Inventory == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.K9Inventory') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- DEVELOPER_REFERENCE.md §13.4.2. THE security-critical callback of this file, per
--- this file's own header claim of server/search.lua-level scrutiny.
lib.callback.register('john-k9:server:openK9Inventory', function(source, targetNetId)
    if type(targetNetId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' } -- defensive: never trust client payload shape
    end

    if not Config.Features.K9Inventory then
        return { ok = false, reason = 'feature_disabled' } -- real server-side no-op regardless of client UI state
    end

    -- PER-PERSON FEATURE CONTROL -- see IsK9InventoryPermittedForCitizenId
    -- above. Checked BEFORE the cooldown/mutex below, matching
    -- server/pursuitsprint.lua's own "cheapest/no-side-effect checks first"
    -- discipline, so a blocked interactor never burns their own cooldown
    -- window for a request that was always going to be refused. Gates the
    -- INTERACTOR (`source`), never the target -- HandleOpenK9Inventory's own
    -- IsAuthorizedForK9Inventory already answers "is this interactor
    -- generally allowed to open K9 gear at all"; this answers the
    -- orthogonal "has high command specifically switched this OFF for this
    -- one interactor" question.
    local interactorPlayer = exports.qbx_core:GetPlayer(source)
    local interactorCitizenid = interactorPlayer and interactorPlayer.PlayerData and interactorPlayer.PlayerData.citizenid
    if not interactorCitizenid or not IsK9InventoryPermittedForCitizenId(interactorCitizenid) then
        return { ok = false, reason = 'not_authorized' }
    end

    if K9InventoryOpenCooldown.IsOnCooldown(source) then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- Set the in-flight mutex synchronously, BEFORE any further work —
    -- cleared on EVERY exit path below, same "finally" discipline
    -- server/search.lua's SearchMutex already established.
    if not K9InventoryOpenMutex.TryAcquire(source) then
        return { ok = false, reason = 'request_in_progress' }
    end

    local ok, result = pcall(HandleOpenK9Inventory, source, targetNetId)

    K9InventoryOpenMutex.Release(source) -- ALWAYS clear, success or error

    if not ok then
        print(('[John-K9] openK9Inventory error for source %s: %s'):format(source, tostring(result)))
        return { ok = false, reason = 'stash_failed' }
    end

    return result
end)
