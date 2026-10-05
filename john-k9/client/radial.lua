--[[
    john-k9/client/radial.lua

    Phase 1 scaffold. Thin ox_lib radial menu WIRING
    ONLY — this file must never implement anim/native gameplay logic
    directly. Every item's onSelect should do at most a cheap access check
    plus a single call into a global function exposed by client/main.lua,
    client/movement.lua, or client/vehicle.lua. If an item needs more than
    a couple of lines to decide what to do, that logic belongs in one of
    those files, not here — keeps this file from becoming an
    everything-file as later phases add more radial items.

    ======================================================================
    EVENT/CALLBACK CONTRACT — this file does not register or trigger any
    NETWORK event/callback directly (the one local-only exception, noted
    separately below this list, is an AddEventHandler for
    client/featureblocks.lua's purely client-side
    `john-k9:client:featureBlocksApplied` re-broadcast, which crosses no
    network boundary and needs no trust-boundary check). It calls:
      - client/main.lua's CanShowK9UI() to decide whether to show/allow
        the "K9 Unit" submenu at all.
      - client/movement.lua's ToggleK9Camera(), K9Sit(),
        RequestLeashAttach(targetServerId), DetachLeash(), IsLeashed().
      - client/vehicle.lua's EnterNearestK9Vehicle(), ExitK9Vehicle(),
        IsInK9Vehicle().
      - TriggerServerEvent('john-k9:server:relayBark', barkType) directly
        for the Bark item (the one place this file talks to the network
        itself, since there's no separate "bark module" file to delegate
        to — server/main.lua's relayBark handler is the other end).
      - client/partnership.lua's BreakPartnership(), RequestPartnerUp(targetServerId).
      - client/fetch.lua's RequestThrowFetchBall(), ReleaseFetchBall(),
        RequestRecallFetchBall(), IsFetchCarryEngaged().
      - client/propattachment.lua's RequestToggleK9PropAttachment().
      - client/kennel.lua's RequestDeployKennel(), ExitKennelRest() -- the
        latter added THIS PASS (trap-hunt fix, "Exit Kennel" item,
        registered UNCONDITIONALLY -- see that item's own comment for why
        it does NOT gate on IsRestingInKennel()/Config.Features.DeployableKennel
        the way Attach/Detach Leash gates on IsLeashed()).
      - client/inventory.lua's RequestOpenOwnK9Inventory().
      - client/medkit.lua's RequestTreatNearestK9().
      - client/main.lua's HasK9Access() directly (not just via CanShowK9UI())
        for Fetch's Throw branch, whose own source file documents that it
        is deliberately gated on HasK9Access() alone, not the full
        CanShowK9UI() combinator (see that item's own comment for why, it
        quotes client/fetch.lua's RequestThrowFetchBall() verbatim).
      - client/vision.lua's ToggleThermalVision()/ToggleNightVision() --
        REVERTED, SEPARATE AGAIN, this pass (owner reversal: "I want the
        thermal and night vision separate") -- their own
        "Thermal Vision"/"Night Vision" items' only calls, each
        independently flag-gated, no CanShowK9UI()/HasK9Access() gate of
        their own, see each item's own comment for why.
      - client/vision.lua's CycleVision() (see that function's own "CYCLE —
        EXTRA, OPTIONAL CONVENIENCE" header) -- the "K9 Vision" item's only
        call, kept as an extra alongside the two items immediately above,
        no CanShowK9UI()/HasK9Access() gate of its own either, see that
        item's own comment for why.
      - THIS PASS (top-level icon access gate, coder-security/coder-backend
        finding response): client/partnership.lua's IsPartnered(),
        client/kennel.lua's IsRestingInKennel()/IsCarryingKennel(),
        client/combat.lua's IsBiteHoldEngaged()/IsDragEngaged()/
        IsDragTargetEngaged() (both already-established call targets
        elsewhere in this file, now ALSO consulted here), and
        client/main.lua's HasK9Access() — all read-only, all called from
        ShouldShowK9RadialIcon()/IsK9RadialIconNeededForOngoingEngagement()
        at REGISTRATION time (inside RegisterK9RadialMenu(), triggered by
        this file's own onResourceStart dispatcher and the periodic
        refresh thread at the bottom of this file), never from an onSelect
        closure — safe for the identical reason given below for onSelect
        callers: `onResourceStart` for THIS resource fires only once every
        one of its own client_scripts has finished loading, so every
        global these two functions read already exists by the time either
        one first runs, regardless of client/radial.lua's own position
        first in fxmanifest.lua's client_scripts list.
      Every cross-file global added after Phase 1 is called behind
      a `type(fn) == 'function'` runtime existence guard (this codebase's
      established soft-dependency convention — see e.g. AwardXP
      in server/tracking.lua) because client/radial.lua loads FIRST among
      client_scripts (fxmanifest.lua), before every file listed above that
      defines one of these globals — the guard is never a load-order
      assumption, since by the time any of these onSelect closures actually
      RUNS (a player action, always well after this resource has finished
      loading), every one of those files has already executed and defined
      its own globals for real; it is kept anyway per this resource's own
      documented "runtime existence guard, not a load-order assumption"
      convention, matching every other guarded call site in this codebase.
    ======================================================================

    DEVELOPER_REFERENCE.md §6.1 / §8 step 7 Phase 1 radial item list: Bark, Sit,
    Attach/Detach Leash, Enter/Exit Vehicle — "each item only appears if
    its owning Config.Features flag is true AND the access check above
    passes."

    STRUCTURAL QUESTION, RESOLVED (see "OPEN STRUCTURAL QUESTION
    resolution" below, right before FindNearestLeashCandidate()): ox_lib's
    `lib.addRadialItem` registers items once; there's no built-in live
    "should this item be visible right now" predicate the way ox_target's
    `canInteract` works. Two ways to satisfy "each item only appears
    if... access check passes" (DEVELOPER_REFERENCE.md §3/§6.1):
      (a) A lightweight polling thread (e.g. every 2-3s while the local
          player is near/playing) that calls CanShowK9UI() and
          lib.addRadialItem/lib.removeRadialItem the whole "K9 Unit"
          submenu in/out of existence accordingly.
      (b) Register the submenu once, unconditionally, and gate purely
          inside each onSelect via CanShowK9UI() (and the item's own
          Config.Features flag), notifying+denying on failure — the menu
          entry always "appears" but does nothing for a non-qualifying
          player.
    DEVELOPER_REFERENCE.md's "only appears if" phrasing leans toward (a), but a live
    network round-trip (CanShowK9UI awaits a server callback) firing every
    couple of seconds for every player near a PD is more chatter than
    wanted — (b) is what this file implements; see the resolution comment
    below for the full reasoning. Documented here so "appears" in this
    file's own comments is understood to mean "is present in the radial
    wheel," not "is currently usable."

    QBOX/OX_LIB API FIX (verified against ox_lib's actual source —
    overextended/ox_lib
    resource/interface/client/radial.lua's registerRadial/addRadialItem/
    radialClick — not just the docs prose): the earlier draft of this file
    built ONE FLAT ARRAY containing an "opener" item (id='k9unit', no
    onSelect, no menu) plus the four action items, each of THOSE carrying
    `menu = 'k9unit'`, and passed the whole array to a single
    `lib.addRadialItem(k9RadialItems)` call with no `parentMenuId` and no
    matching `lib.registerRadial` call anywhere. That is not what `menu`
    means on an item: `menu` does not mean "this item lives inside
    submenu X" (grouping), it means "selecting this item navigates to the
    ALREADY-REGISTERED submenu with this id" — ox_lib's own radialClick
    NUI handler runs `if item.menu then ... showRadial(item.menu) end`
    BEFORE it ever calls the item's own `onSelect`, and `showRadial` on an
    id nobody registered via `lib.registerRadial` does
    `return error('No radial menu with such id found.')` — a hard Lua
    error that aborts the callback right there, so `onSelect` (the line
    that would have actually run K9Sit()/relayBark/RequestLeashAttach()/
    EnterNearestK9Vehicle()) never executes at all. On top of that, with
    no `parentMenuId` every one of these items (including the would-be
    "opener") lands in the GLOBAL root wheel `menuItems`, not tucked under
    a submenu — mixed in with every other resource's global radial items,
    not the single "K9 Unit" icon the rest of this file's comments
    describe. Net effect of the old code: every Phase 1 radial action was
    completely non-functional (hard error on select), not merely
    mis-labeled. Fixed below by actually calling `lib.registerRadial({id
    = 'k9unit', items = k9SubmenuItems})` for the real submenu contents
    (none of which carry their own `menu` field — they're terminal
    actions, not further navigation links) and a separate
    `lib.addRadialItem({...})` call for the single opener item that
    carries `menu = 'k9unit'` to link into it. Option (b)'s reasoning
    above (register unconditionally, gate in onSelect) is unchanged by
    this fix — only the registration mechanics were wrong, not the
    gating design.

    BARK TYPE NOTE: Phase 1 needs exactly one generic bark (§6.1: "Basic
    bark sound plays on a radial-triggered 'Bark' action" — the
    aggressive/alert/calm variety is Phase 5's AdvancedBarkRadial, not
    Phase 1). Use a single literal string, e.g. 'bark', consistently with
    server/main.lua's relayBark handler and client/main.lua's playBark
    handler — all three call sites must agree on the same literal.

    UPDATE (Phase 5, AdvancedBarkRadial implemented): when
    Config.Features.AdvancedBarkRadial is also true (still requires
    BasicBarkSounds underneath it), the Bark item below becomes a submenu of
    config-driven variants (Config.AdvancedBarkRadial, config.lua) instead of
    that single literal — see the Bark block below for the full contract.
    Every variant still triggers the exact same
    'john-k9:server:relayBark' event, just with a different `barkType`
    string; server/main.lua's handler was NOT changed for this, it already
    accepts any opaque, length-capped barkType. When AdvancedBarkRadial is
    off (the default), behavior is unchanged from the single-literal
    description above.

    OX_LIB RESTART LIFECYCLE FIX (verified against ox_lib's own source --
    overextended/ox_lib resource/interface/client/radial.lua, read
    directly): every `lib.registerRadial`/`lib.addRadialItem` call this file
    makes used to run ONCE, at this file's own load time, as bare top-level
    statements. That was fine for THIS resource's own lifecycle
    (fxmanifest.lua only loads this file once per resource start), but
    ox_lib keeps `menus` and `menuItems` -- the tables every one of those
    calls writes into -- as plain FILE-LOCAL Lua tables inside ox_lib's OWN
    client chunk, exactly the same shape client/movement.lua's own
    "LIFECYCLE FIX" comment documents for ox_target's
    addGlobalPlayer/addGlobalObject registries. ox_lib's
    `onClientResourceStop` handler only clears `menuItems` entries
    belonging to the STOPPING resource -- it never touches `menus` at all --
    but neither table survives ox_lib ITSELF restarting: that reloads the
    whole chunk from scratch, reconstructing both empty, with nothing in
    ox_lib re-populating them and nothing in the old version of this file
    ever prompting a re-add. The entire "K9 Unit" radial menu -- submenu,
    every nested submenu, and the root opener -- would silently vanish the
    moment ox_lib restarts, no error, no log line; and if the (now
    unregistered) 'k9unit'/'k9unit_bark' ids
    were ever still referenced via a stale `menu` field somewhere,
    ox_lib's `showRadial` does `return error('No radial menu with such id
    found.')` -- an UNCAUGHT hard Lua error, not a no-op.

    FIX: every registration call in this file now lives inside one
    idempotent function, RegisterK9RadialMenu() (see its own doc comment,
    right where it's defined, for the full writeup) -- called from a single
    `AddEventHandler('onResourceStart', ...)` dispatcher at the bottom of
    this file that fires on EITHER this resource's own start OR ox_lib's,
    mirroring the exact `resourceName == GetCurrentResourceName() or
    resourceName == '<dependency>'` idiom already established for ox_target
    in client/movement.lua/client/fetch.lua/client/medkit.lua/
    client/wellbeing.lua/client/search.lua -- just pointed at 'ox_lib'
    instead, since it's ox_lib's own registries this file's state lives
    inside. Verified idempotent against ox_lib's real dedup behavior (both
    `lib.registerRadial`'s key-based table write and `lib.addRadialItem`'s
    id-match replace-in-place never duplicate an entry on a repeat call --
    see RegisterK9RadialMenu()'s own comment for the full verification).
]]


--- Nearest other player within `range`, PREFERRING the other kind: a
--- human handler gets the nearest dog, the dog gets the nearest human. So
--- "stand next to your dog and press Leash / Partner Up" works even with a
--- bystander standing closer. Falls back to the nearest player of either
--- kind (the server then explains why that pairing is not possible).
--- @param range number
--- @return number? candidateServerId
local function FindNearestPairCandidate(range)
    local myCoords = GetEntityCoords(PlayerPedId())
    local iAmDog = type(IsOwnModelK9) == 'function' and IsOwnModelK9() or false
    local bestOther, bestOtherDist, bestAny, bestAnyDist

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= PlayerId() then
            local targetPed = GetPlayerPed(playerId)
            if targetPed ~= 0 and DoesEntityExist(targetPed) then
                local dist = #(myCoords - GetEntityCoords(targetPed))
                if dist <= range then
                    if not bestAnyDist or dist < bestAnyDist then bestAny, bestAnyDist = playerId, dist end
                    local isDog = type(IsEntityModelK9) == 'function' and IsEntityModelK9(targetPed) or false
                    if isDog ~= iAmDog and (not bestOtherDist or dist < bestOtherDist) then
                        bestOther, bestOtherDist = playerId, dist
                    end
                end
            end
        end
    end

    local pick = bestOther or bestAny
    return pick and GetPlayerServerId(pick) or nil
end

-- OPEN STRUCTURAL QUESTION resolution: option (b) was chosen — the "K9
-- Unit" submenu and its sub-items are registered ONCE, unconditionally
-- (subject to each item's own Config.Features flag at registration time,
-- satisfying DEVELOPER_REFERENCE.md §3's "read at the point... menu item visibility"),
-- and every onSelect below independently re-checks CanShowK9UI() before
-- doing anything, notifying+denying on failure. Rationale for (b) over
-- (a): every onSelect's own "if not CanShowK9UI() then notify + return"
-- shape only makes sense if the item can actually be seen/selected by a
-- non-qualifying player in the first place; (a) would make that branch
-- largely unreachable. (b) also avoids a polling thread that would
-- otherwise re-await the server's hasK9Access callback every couple of
-- seconds for every player near a PD. (NOTE: the actual
-- lib.registerRadial/lib.addRadialItem submenu-then-children mechanics
-- were separately verified against ox_lib's own source — see the
-- QBOX/OX_LIB API FIX note above — which found the original registration
-- call itself was broken; that is fixed independently of this
-- option-(b)-vs-(a) choice, which still stands.) "Appears" in this file's
-- own comments means "is present in the radial wheel," not "is currently
-- usable" — usability is enforced at onSelect time, same as every gated
-- server event is independently re-verified server-side regardless of
-- what the client shows.
--- Finds the nearest OTHER player within Config.LeashMaxDistance (the base
--- leash range, reused directly here as a search radius rather than via
--- a derived factor — see config.lua's comment on that field and
--- server/main.lua's header for the initiate-range check this mirrors),
--- for the Attach/Detach Leash radial item's self-initiated entry point.
--- Prefers the other kind (FindNearestPairCandidate above: your dog if
--- you are the handler); the server re-validates via CheckLeashEligibility
--- (server/main.lua) regardless.
--- @return number? candidateServerId
--- SEAM OPENED 2026-08-25: was `local`. client/tablet.lua calls this so the
--- tablet's own action routes through the SAME candidate-resolution logic the
--- radial uses, rather than carrying a second copy that would drift out of
--- sync the first time either is fixed. Kept a plain global to match this
--- resource's existing cross-file convention; callers guard with
--- type(fn) == 'function' since client/radial.lua returns early when its own
--- feature flag is off, in which case this is never defined.
function FindNearestLeashCandidate()
    return FindNearestPairCandidate(Config.LeashMaxDistance)
end
--- Same shape as FindNearestLeashCandidate() above, for the Partner Up
--- radial item's self-initiated entry point: nearest OTHER player within
--- Config.Partnership.ProximityMeters — that field is the REAL server-side
--- range client/partnership.lua's CheckPartnershipEligibility checks a
--- request against (both at request time and again at accept time), reused
--- directly here as the search radius for the identical reason
--- FindNearestLeashCandidate() reuses Config.LeashMaxDistance. Prefers the
--- other kind the same way -- a display-adjacent candidate pick, not a
--- security boundary; CheckPartnershipEligibility re-derives the real model
--- server-side regardless.
--- @return number? candidateServerId
--- SEAM OPENED 2026-08-25: was `local`. client/tablet.lua calls this so the
--- tablet's own action routes through the SAME candidate-resolution logic the
--- radial uses, rather than carrying a second copy that would drift out of
--- sync the first time either is fixed. Kept a plain global to match this
--- resource's existing cross-file convention; callers guard with
--- type(fn) == 'function' since client/radial.lua returns early when its own
--- feature flag is off, in which case this is never defined.
function FindNearestPartnerCandidate()
    return FindNearestPairCandidate(Config.Partnership.ProximityMeters)
end
--- Idempotent (re-)registration of every "K9 Unit" radial menu and
--- submenu this resource owns.
---
--- LIFECYCLE FIX (verified against ox_lib's own source --
--- overextended/ox_lib resource/interface/client/radial.lua, read
--- directly, not assumed): `menus` and `menuItems` inside that file are
--- plain FILE-LOCAL Lua tables in ox_lib's own client chunk, exactly the
--- same shape as ox_target's addGlobalPlayer/addGlobalObject registries
--- (see client/movement.lua's own "LIFECYCLE FIX" comment on
--- RegisterLeashOxTargetOption for that precedent, and client/fetch.lua's/
--- client/medkit.lua's/client/wellbeing.lua's/client/search.lua's matching
--- fixes for the identical bug class against ox_target). ox_lib's own
--- `AddEventHandler('onClientResourceStop', ...)` handler only clears
--- entries out of `menuItems` (the flat root wheel) belonging to the
--- STOPPING resource -- it never touches `menus` (the registerRadial
--- registry) at all, for ANY resource, ever. Neither table survives ox_lib
--- ITSELF restarting: a `restart ox_lib` reloads that whole client chunk
--- from scratch, reconstructing both `menus = {}` and `menuItems = {}`
--- empty, with nothing in ox_lib's own code re-populating them and nothing
--- in the old (pre-fix) version of this file ever prompting a re-add. The
--- entire "K9 Unit" radial menu -- the submenu itself, every nested
--- submenu, and the single root opener that links to it -- would silently
--- vanish the instant ox_lib restarts, with no error and no log line: the
--- player just finds the wheel gone (or, if this file's own opener item
--- happened to still be clicked via some other stale reference, ox_lib's
--- `showRadial` does `return error('No radial menu with such id found.')`
--- on any id nobody re-registered -- an UNCAUGHT hard Lua error, not a
--- no-op).
---
--- FIX: every `lib.registerRadial`/`lib.addRadialItem` call this file makes
--- now lives inside this one function, with the sole call site (the
--- `AddEventHandler('onResourceStart', ...)` dispatcher immediately below
--- this function) firing on EITHER this resource's own start OR ox_lib's,
--- same two-branch `resourceName == GetCurrentResourceName() or
--- resourceName == '<dependency>'` idiom already established at
--- client/movement.lua's "Sole call site for RegisterLeashOxTargetOption()"
--- comment (and its `ox_target` siblings in the four files named above) --
--- just pointed at `ox_lib` instead of `ox_target`, since it's ox_lib's
--- registries this file's own state lives inside, not ox_target's.
---
--- ORDERING PRESERVED: this function still registers every submenu
--- ('k9unit_bark', 'k9unit_utility') strictly BEFORE the
--- 'k9unit' registration that follows it and BEFORE the root opener
--- `lib.addRadialItem` call at the very end -- i.e. before anything that
--- references one of those submenu ids via an item's `menu` field. This
--- matters even on a RE-registration, not just the first one: `menu`
--- navigation is resolved against ox_lib's live `menus` table at CLICK
--- time (`showRadial` does `local radial = id and menus[id]`), so as long as
--- every submenu this function registers lands in `menus` before this
--- function returns and control is handed back to the player, click-time
--- order never matters -- only that no submenu is EVER left permanently
--- unregistered while something still points at it. The straight-line
--- top-to-bottom statement order below is unchanged from before this fix
--- (see the file-level "QBOX/OX_LIB API FIX" note above for why that order
--- is itself correct); this function only adds a name and a second/third
--- call site around it, nothing about the registration sequence itself was
--- reordered.
---
--- DUPLICATE-VS-REPLACE (verified against ox_lib's own source):
--- `lib.registerRadial` does `menus[radial.id] = radial` -- a plain
--- key-based table write, so re-running this function against a `menus`
--- table that already holds an entry for a given id (this resource's own
--- restart, without ox_lib itself having restarted) REPLACES that entry
--- wholesale with a freshly-built table, never duplicates or appends
--- anything. `lib.addRadialItem` (used here only for the single
--- 'k9unit_open' root opener) walks its target array looking for a
--- matching `id` and replaces in place if found, only appending when no
--- match exists -- so the opener is likewise never duplicated on a repeat
--- call. Every item built inside this function always carries a fixed,
--- literal `id` (never a generated/random one), which is what makes both
--- of ox_lib's own dedup mechanisms actually apply here.
---
--- NOTHING ELSE in this file needs invalidation handling on an ox_lib
--- restart: the only ox_lib state this file ever holds onto is the
--- registration calls themselves (rebuilt fresh, from scratch, every single
--- time this function runs -- `k9SubmenuItems` and friends below are local
--- to this function, never module-level state that could go stale) and the
--- one-shot `locale()`/`lib.notify` calls each onSelect closure makes at
--- CLICK time, which need no persistent handle to ox_lib at all.
--- ======================================================================
--- K9 UNIT RADIAL -- PER-PERSON BLOCK (client/featureblocks.lua -- see
--- that file's own header for the full contract). RadialMenu and
--- AdvancedBarkRadial are the only two of the twelve purely-client-side
--- features made blockable that live in THIS file, and both are handled
--- the SAME way, deliberately DIFFERENT from how every other blockable
--- feature elsewhere in this codebase is handled: at REGISTRATION time
--- inside RegisterK9RadialMenu() below, not inside an onSelect closure.
--- WHY THIS ONE FILE IS THE EXCEPTION (see client/featureblocks.lua's own
--- header "WHERE THE CHECK GOES" for the short version): both features
--- are themselves about what this file's OWN registration STRUCTURE looks
--- like (does the K9 Unit wheel exist for this client at all; does its
--- Bark entry expand into a variant submenu) -- not about a single
--- ability's own point-of-use the way ThermalVision/VehicleEntryExit/etc.
--- are. Gating ~17 individual onSelect closures instead (adding a second,
--- independent block check to EVERY item's own already-carefully-tuned
--- initiation-vs-termination gate) would have meant re-auditing every one
--- of Detach Leash/Release Bite & Hold/Release Drag/Break Partnership/
--- Fetch's Release+Recall/every Stop Tracking branch by hand to
--- make sure a NEW check could never land on one of them by mistake -- a
--- real risk on a file this size, for no honesty benefit over the simpler
--- alternative below (this file's header "DUPLICATE-VS-REPLACE" note
--- already proves the alternative is safe to lean on).
---
--- RadialMenu BLOCKED: the 'k9unit' submenu contents stop being registered
--- (harmless -- nothing links to it, same disclosed nuance the GLOBAL
--- Config.Features.RadialMenu=false path already has). The single root
--- OPENER item, unlike the submenu, STAYS VISIBLE -- it is REPLACED
--- in-place (never removed) with a version carrying no `menu` field and an
--- onSelect that explains the block, rather than one that silently
--- vanishes. THIS IS A DELIBERATE, DISCLOSED COMPROMISE, not the ideal:
--- the fully-honest "icon disappears entirely" behavior would need a
--- REMOVAL call this codebase has never verified as real against ox_lib's
--- own source (a prior draft of this file's header floated
--- `lib.removeRadialItem` as a hypothetical, unconfirmed option) --
--- `lib.registerRadial`/`lib.addRadialItem`'s own REGISTER/REPLACE
--- semantics ARE independently verified (see "DUPLICATE-VS-REPLACE"
--- above), so this design stays entirely within what is actually proven,
--- rather than assuming an unverified native/API call the way this
--- resource's own established discipline forbids elsewhere. Every OTHER
--- ability normally reached through the wheel stays fully reachable via
--- every OTHER surface (keybind, command, tablet trigger, export) -- a
--- RadialMenu block closes only this one entry point's USEFULNESS, never
--- an ability itself, and is still strictly more honest than gating every
--- individual onSelect would have been (nobody sees SOME items work and
--- others silently refuse inside the same open wheel -- the ONE entry
--- point itself says plainly why it does nothing).
---
--- AdvancedBarkRadial BLOCKED (while BasicBarkSounds/RadialMenu are NOT):
--- the Bark entry degrades to the SAME single, flat, generic-'bark'-type
--- item this file already ships when Config.Features.AdvancedBarkRadial
--- is globally false -- barking itself keeps working (BasicBarkSounds has
--- its OWN, separate, server-enforced block key, untouched here), only the
--- variant SUBMENU is withheld.
---
--- LIVE, NOT JUST AT NEXT RESTART: client/featureblocks.lua fires a local
--- `john-k9:client:featureBlocksApplied` event every time it processes
--- a server sync -- this file's own listener (see the bottom of this
--- file, alongside the existing onResourceStart/ox_lib dispatcher) simply
--- calls RegisterK9RadialMenu() again, which re-evaluates both conditions
--- below fresh and REPLACES the previous registration in place (never
--- duplicates -- see "DUPLICATE-VS-REPLACE" above). One disclosed, minor
--- edge case: a player with the radial UI already open, mid-navigation,
--- at the exact instant a rebuild lands could have that one click resolve
--- against whichever registration (old or new) ox_lib's `menus` table
--- holds at that exact frame (navigation is resolved live, at click time,
--- per "ORDERING PRESERVED" above) -- not a crash, not a security concern,
--- just a possible one-frame staleness on an already-rare coincidence.
---
--- `type(IsK9FeatureBlocked) == 'function'` guard throughout, per this
--- resource's soft-dependency convention -- fails OPEN (never blocked) if
--- client/featureblocks.lua has not loaded, matching every other call
--- site in this file.
--- @param featureName string -- 'RadialMenu' | 'AdvancedBarkRadial'
--- @return boolean
local function IsRadialFeatureBlockedForMe(featureName)
    return type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked(featureName)
end

-- ======================================================================
-- TOP-LEVEL ICON ACCESS GATE (this pass -- coder-security/coder-backend
-- finding response). See this function's own "K9 UNIT RADIAL -- PER-
-- PERSON BLOCK" header above for the sibling per-person block mechanism
-- this is deliberately separate from (that one answers "has an
-- operator/high-command blocked this feature for this specific person";
-- this one answers "does this person currently look like a K9 handler at
-- all"). FINDING: the 'k9unit_open' root opener used to register
-- unconditionally for EVERY connected player whenever
-- Config.Features.RadialMenu was true, regardless of department or K9
-- access -- a civilian, a mechanic, anyone whose job is not in
-- Config.Departments and who holds no K9 access grant saw a dog icon in
-- their own pie menu that led, at best, to a chain of "you are not
-- certified" refusals inside the submenu.
--
-- THREE THINGS THIS MUST GET RIGHT, in order of how badly getting them
-- wrong would hurt someone:
--
-- 1. NEVER GATE A WAY OUT. IsK9RadialIconNeededForOngoingEngagement()
--    below is checked FIRST and OR'd into the final answer, unconditionally
--    ahead of the department/access questions. Audited every
--    "release/stop/exit" action inside k9SubmenuItems above for whether it
--    has ANY OTHER reachable surface at all:
--      - Detach Leash: NO other surface. client/movement.lua's own
--        "Attach Leash" ox_target option explicitly refuses to show while
--        already leashed (`if IsLeashed() then return false end`), there
--        is no detach keybind/command, and client/tablet.lua's own Detach
--        action (~line 1907) is reachable only when
--        Config.Features.CommandTablet is ALSO on. LOAD-BEARING.
--      - Break Partnership: NO other surface besides the tablet (same
--        CommandTablet caveat) -- no keybind/command of its own.
--        LOAD-BEARING.
--      - Release Bite & Hold / Release Drag: ALSO reachable via their own
--        unconditional keybinds (client/keybinds.lua's k9bitehold/
--        k9dragtoggle both check the engaged-release branch BEFORE any
--        access gate) -- included below anyway for menu-based parity, not
--        because either is independently load-bearing.
--      - Exit Kennel: has its own unconditional keybind
--        (client/keybinds.lua's k9exitkennel) -- included below anyway.
--      - Release/Recall Fetch Ball: has its own commands, gated only on
--        Config.Features.FetchMechanic, never on access -- included below
--        anyway.
--    So this must include, at minimum, IsLeashed() and IsPartnered() --
--    every other predicate below is defense-in-depth, not load-bearing.
--
-- 2. FAIL OPEN, NOT CLOSED, on an unknown answer. See the grace-window
--    comment on K9_RADIAL_ICON_GRACE_MS below: a civilian who briefly sees
--    a useless icon for a few seconds after connecting is a cosmetic
--    annoyance; a genuine handler with no icon and no idea why, because
--    this client's own access answer had not resolved yet, is a support
--    ticket. HasK9Access() (client/main.lua) itself already fails CLOSED
--    on a genuine callback throw/timeout -- correct for ITS OWN callers
--    (hot call sites gating an action the server re-verifies regardless of
--    what this client believes), wrong for hiding this icon, which is why
--    this gate never trusts a single HasK9Access() read the moment this
--    client's own resource starts.
--
-- 3. LIVE, NOT JUST AT NEXT RESTART/RECONNECT. Department membership
--    (QBX.PlayerData.job.name, checked below) is free and instant --
--    QBX.PlayerData is qbx_core's own live-updated client cache (see
--    fxmanifest.lua's own manifest-convention note), so a job change is
--    reflected the very next time this runs with zero extra plumbing. K9
--    access (certification/permission-grant based, HasK9Access()) has no
--    equivalent live push in this resource today -- nothing fires a client
--    event when a handler is certified or decertified mid-session -- so
--    the periodic refresh thread further down this file (search
--    "K9_RADIAL_ICON_REFRESH_INTERVAL_MS") re-runs RegisterK9RadialMenu()
--    on a plain timer specifically so a newly-certified player sees the
--    icon appear within one interval, not only on their next reconnect.
-- ======================================================================

--- Audits every "am I currently mid-something only the radial's own
--- submenu can end" state predicate this file otherwise gates a release
--- action's UI on (see this function's own "TOP-LEVEL ICON ACCESS GATE"
--- header immediately above for which of these are load-bearing versus
--- defense-in-depth). `type(fn) == 'function'` guards throughout, per this
--- file's established soft-dependency convention -- absent means "cannot
--- currently be true" for that one predicate, never treated as an error.
--- @return boolean
local function IsK9RadialIconNeededForOngoingEngagement()
    if type(IsLeashed) == 'function' and IsLeashed() then return true end
    if type(IsPartnered) == 'function' and IsPartnered() then return true end
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then return true end
    if type(IsDragEngaged) == 'function' and IsDragEngaged() then return true end
    if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then return true end
    if type(IsRestingInKennel) == 'function' and IsRestingInKennel() then return true end
    if type(IsCarryingKennel) == 'function' and IsCarryingKennel() then return true end
    if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then return true end
    return false
end

-- Startup FAIL-OPEN grace window -- see point 2 above. Set on the FIRST
-- call to ShouldShowK9RadialIcon() in this client's own session (a
-- module-level `local`, so it is computed at most once regardless of how
-- many times RegisterK9RadialMenu() itself re-runs) and never recomputed
-- afterwards. 8 seconds comfortably covers a normal connect (this
-- resource's own server-side john-k9:server:hasK9Access callback is
-- registered at THAT resource's own boot, always well before any player's
-- client-side resource start in the ordinary case) and the one genuine
-- risk case this pass's own brief names -- an operator-initiated `restart
-- john-k9` racing an already-connected client's own onResourceStart
-- against the server side re-registering its callback -- without leaving
-- a stale "always show" answer around for meaningfully long afterwards.
local K9_RADIAL_ICON_GRACE_MS = 8000
local k9RadialIconGraceUntil

--- Decides whether the top-level 'k9unit_open' opener should be reachable
--- at all for the LOCAL player right now. See this function's own
--- "TOP-LEVEL ICON ACCESS GATE" header immediately above this section for
--- the full three-part writeup this implements.
--- @return boolean
local function ShouldShowK9RadialIcon()
    if IsK9RadialIconNeededForOngoingEngagement() then return true end

    local jobName = QBX and QBX.PlayerData and QBX.PlayerData.job and QBX.PlayerData.job.name
    if jobName and type(Config.Departments) == 'table' and Config.Departments[jobName] then
        return true
    end

    if not k9RadialIconGraceUntil then
        k9RadialIconGraceUntil = GetGameTimer() + K9_RADIAL_ICON_GRACE_MS
    end
    if GetGameTimer() < k9RadialIconGraceUntil then
        return true -- FAIL OPEN: still inside the startup grace window
    end

    return type(HasK9Access) == 'function' and HasK9Access()
end

--- Which menu was built last (dog or human) -- the refresh loop at the
--- bottom of this file rebuilds as soon as your character changes.
local lastBuiltRoleIsDog = nil

local function RegisterK9RadialMenu()
    -- Contents of the "K9 Unit" SUBMENU (registered via lib.registerRadial
    -- below) — none of these carry their own `menu` field, UNLESS noted
    -- otherwise (an opener that navigates into a nested sub-menu, same
    -- `menu`-field mechanic this file's header already documents for
    -- 'k9unit_bark'/'k9unit_utility'). Every other item
    -- here is a terminal action with
    -- its own onSelect, so `menu` must stay unset on all of those.
    local k9SubmenuItems = {}

    -- ======================================================================
    -- REGROUPING PASS (ease-of-use audit finding, Job 3): the "K9 Unit"
    -- submenu used to hold ~17-18 items at ONE flat level, with only five
    -- (Bark/Fetch) pushed into their own
    -- sub-menus — ox_lib pages the rest automatically, so finding an item
    -- near the end of that flat list meant paging through the wheel.
    --
    -- k9UtilitySubmenuItems below is the ONE new sub-menu this pass adds
    -- ('k9unit_utility') — see its own registration further down for the
    -- full "why these four, and not the ones the task's own suggested
    -- grouping named instead" writeup. Built as a SEPARATE local table, same
    -- shape as k9SubmenuItems itself, so its own registration can follow the
    -- identical `lib.registerRadial({id=..., items=...})` + one opener
    -- appended to k9SubmenuItems pattern already established for the other
    -- five nested sub-menus in this file — never a second, different
    -- mechanism.
    -- ======================================================================
    local k9UtilitySubmenuItems = {
        --- Sit — DEVELOPER_REFERENCE.md §6.1. No dedicated Config.Features flag (bundled
        --- under the general RadialMenu flag + access check, same as every
        --- other Phase 1 item here). MOVED into the new Utility sub-menu,
        --- this pass -- a pure, one-shot cosmetic action with no release/
        --- termination half of its own, so nesting it costs nothing (see
        --- the "REGROUPING PASS" header above this table for the full
        --- safety reasoning this decision follows).
        {
            id = 'k9_sit',
            label = locale('radial.sit_label'),
            icon = 'couch',
            onSelect = function()
                -- REASON ROUTING (ease-of-use audit, this pass): this item
                -- only ever checks the broad CanShowK9UI() combinator (role
                -- AND access), never HasK9Access() alone, so it cannot tell
                -- which half failed -- 'common.no_k9_role_or_access' is the
                -- most specific reason this call site can honestly claim
                -- (see DenyK9UIAccess's own doc comment in client/main.lua
                -- for the full routing policy). Every other CanShowK9UI()
                -- gate in this file below follows the identical convention;
                -- not re-explained at each one.
                if not CanShowK9UI() then
                    DenyK9UIAccess('common.no_k9_role_or_access')
                    return
                end
                -- type(...) == 'function' guard per this file's own header
                -- policy ("every cross-file global... called behind a
                -- type(fn) == 'function' runtime existence guard") --
                -- HEADER/CODE DRIFT FIX: this call, and every other one
                -- this fix touches below, used to call straight through
                -- unguarded, contradicting that stated blanket policy even
                -- though it was never actually reachable with a nil target
                -- in a real session (fxmanifest.lua loads
                -- client/movement.lua before any player action can fire
                -- this onSelect). Added for consistency with every other
                -- post-Phase-1 item in this file, and so the header's own
                -- claim is no longer false.
                if type(K9Sit) == 'function' then
                    K9Sit()
                end
            end,
        },
    }

    -- K9 Command Tablet. MOVED, this pass, out of a real found bug: this
    -- item used to be registered from a code position textually INSIDE the
    -- `if Config.Features.AdvancedBarkRadial and not
    -- IsRadialFeatureBlockedForMe('AdvancedBarkRadial') then` branch further
    -- below (a leftover of however the Advanced Bark Radial insertion was
    -- made) -- meaning "Command Tablet" only ever appeared when
    -- AdvancedBarkRadial was ALSO true, even though its own gate is (and was
    -- always meant to be) Config.Features.CommandTablet alone, entirely
    -- unrelated to bark variants. A server running CommandTablet=true with
    -- AdvancedBarkRadial at its false default (or blocked) never saw this
    -- item at all. Fixed by lifting it out to its own unconditional
    -- top-level block, added FIRST -- matching this item's own
    -- "Deliberately FIRST in the submenu" comment below, which was true in
    -- INTENT even while the actual code placement silently contradicted it.
    -- NOT folded into the new Utility sub-menu above: "burying it under
    -- [every other ability] would be backwards" (this item's own comment)
    -- applies just as much to a NEW sub-menu as to the old items it already
    -- named -- the one entry that reaches everything else stays the most
    -- prominent, not the most nested.
    if Config.Features.CommandTablet then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_open_tablet',
            label = locale('radial.tablet_label'),
            icon = 'tablet',
            onSelect = function()
                if type(OpenTablet) == 'function' then OpenTablet() end
            end,
        }
    end

    -- Utility sub-menu OPENER, appended here (right after Command Tablet)
    -- for prominence, even though 'k9unit_utility' itself is not actually
    -- REGISTERED via lib.registerRadial until later in this same function
    -- call (after every conditional utility item -- Toggle K9 Vest/Open My
    -- Gear/Treat K9 -- has had its chance to append into
    -- k9UtilitySubmenuItems). Safe per this function's own "ORDERING
    -- PRESERVED" header: click-time `menu` resolution only requires every
    -- submenu to exist in ox_lib's `menus` table by the time THIS function
    -- returns and control is handed back to the player -- statement order
    -- between an opener's append and its target submenu's own registration,
    -- within the same synchronous call, never matters. UNCONDITIONAL: Sit
    -- (k9UtilitySubmenuItems' first entry, above) carries no Config.Features
    -- flag of its own, so this sub-menu is never empty and this opener is
    -- always worth showing whenever the whole "K9 Unit" wheel is.
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_utility',
        label = locale('radial.utility_menu_label'),
        icon = 'toolbox',
        menu = 'k9unit_utility',
    }

    --- Bark — DEVELOPER_REFERENCE.md §6.1, §8 step 9. Config.Features.BasicBarkSounds gate.
    ---
    --- Phase 5's AdvancedBarkRadial (Config.Features.AdvancedBarkRadial, layered
    --- ON TOP of BasicBarkSounds — still requires it, matching how this resource
    --- layers every Phase 5 feature over its Phase 1 prerequisite elsewhere,
    --- e.g. ScentTracking/BloodTracking/GunpowderSniffing each standing alone
    --- under RadialMenu) swaps the single generic "Bark" action for a nested
    --- submenu of variants (Config.AdvancedBarkRadial, config.lua — DEVELOPER_REFERENCE.md
    --- §6.7: "aggressive/alert/calm"). Every variant still funnels through the
    --- SAME 'john-k9:server:relayBark' event with its own `barkType` string —
    --- server/main.lua's handler is UNCHANGED for this feature; it already
    --- accepts any opaque, length-capped barkType (BARK_TYPE_MAX_LENGTH = 16)
    --- with no enum validation, exactly the shape this needs. When
    --- AdvancedBarkRadial is off, behavior is byte-for-byte the same as before
    --- this feature existed: a single 'k9_bark' action sending the literal
    --- 'bark' string.
    ---
    --- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission
    --- audit finding, this pass): server/main.lua's relayBark handler gates
    --- on `HasK9Access(src)` alone -- confirmed by reading it directly, no
    --- model/role check anywhere in that handler -- while both onSelect
    --- branches below used to gate on the broader CanShowK9UI() combinator
    --- (IsK9Role() AND HasK9Access(), which HasK9Role deliberately EXCLUDES
    --- the High Command/autoAccessGrade bypasses from -- server/appearance.lua's
    --- own header). A handler whose ONLY access comes from that bypass
    --- therefore had a bark the server would gladly relay, silently withheld
    --- by this file alone. Matches the identical, already-shipped precedent
    --- this file's Fetch "Throw" item already uses (see that item's own
    --- comment below) -- not a new idiom.
    if Config.Features.BasicBarkSounds then
        -- Per-person block on the ADVANCED VARIANT SUBMENU specifically --
        -- see this function's own "K9 UNIT RADIAL -- PER-PERSON BLOCK"
        -- header above. Basic barking (the `else` branch below) is
        -- unaffected either way.
        if Config.Features.AdvancedBarkRadial and not IsRadialFeatureBlockedForMe('AdvancedBarkRadial') then
            -- Build the nested submenu's terminal action items from
            -- config.lua's Config.AdvancedBarkRadial list. Each `variant` here
            -- is a FRESH local per loop iteration (Lua's generic `for` rebinds
            -- its control variables every pass), so each onSelect closure
            -- safely captures its own variant, not a shared/last-iteration one.
            local barkSubmenuItems = {}
            for _, variant in ipairs(Config.AdvancedBarkRadial) do
                barkSubmenuItems[#barkSubmenuItems + 1] = {
                    id = 'k9_bark_' .. variant.barkType,
                    label = variant.label,
                    icon = variant.icon,
                    onSelect = function()
                        -- HasK9Access() alone, NOT CanShowK9UI() -- see this
                        -- block's own header above. Known reason ->
                        -- 'combat.no_access', the house-standard "not
                        -- certified" string, matching what this exact
                        -- boolean failing actually means server-side.
                        if not HasK9Access() then
                            DenyK9UIAccess('combat.no_access')
                            return
                        end
                        -- server re-validates Config.Features.BasicBarkSounds and
                        -- HasK9Access independently regardless — see server/main.lua.
                        TriggerServerEvent('john-k9:server:relayBark', variant.barkType)
                    end,
                }
            end

            lib.registerRadial({
                id = 'k9unit_bark',
                items = barkSubmenuItems,
            })

            -- Opener item inside the "K9 Unit" submenu: selecting THIS navigates
            -- into 'k9unit_bark' (registered just above), same `menu`-field
            -- navigation mechanic this file's header already documents for the
            -- top-level 'k9unit_open' opener — this item carries no onSelect of
            -- its own on purpose.
            k9SubmenuItems[#k9SubmenuItems + 1] = {
                id = 'k9_bark',
                label = locale('radial.bark_label'),
                icon = 'volume-high',
                menu = 'k9unit_bark',
            }
        else
            k9SubmenuItems[#k9SubmenuItems + 1] = {
                id = 'k9_bark',
                label = locale('radial.bark_label'),
                icon = 'volume-high',
                onSelect = function()
                    -- HasK9Access() alone, NOT CanShowK9UI() -- see this
                    -- block's own header above.
                    if not HasK9Access() then
                        DenyK9UIAccess('combat.no_access')
                        return
                    end
                    -- server re-validates Config.Features.BasicBarkSounds and
                    -- HasK9Access independently regardless — see server/main.lua.
                    TriggerServerEvent('john-k9:server:relayBark', 'bark')
                end,
            }
        end
    end

    --- Attach/Detach Leash — DEVELOPER_REFERENCE.md §6.1, §8 step 6-7. A single
    --- context-sensitive item: behaves as "Attach" when not currently
    --- leashed, "Detach" when leashed. Config.Features.LeashMechanics gate.
    --- See client/movement.lua's header for the full consent-based leash
    --- design (attach requires the OTHER player to accept; detach never
    --- does) — this item is one of two entry points into that same system
    --- (the other being the ox_target option client/movement.lua registers
    --- directly on nearby players).
    ---
    --- BUG FIX -- ITEM PRESENCE MUST NOT DEPEND ON THE FLAG ALONE ANYMORE:
    --- this used to be `if Config.Features.LeashMechanics then`, full stop
    --- — gating the item's very EXISTENCE in the menu on THIS CLIENT's own
    --- local copy of the flag, captured once at this client's own resource
    --- start (or the last featureBlocksApplied/ox_lib-restart rebuild) and
    --- never updated again for an already-connected client, even though
    --- server/runtimecontrol.lua's runtimeSetFeature can flip the
    --- server-side flag live at any time. A server that booted with
    --- LeashMechanics off, was flipped on live, formed a real pairing
    --- (server/main.lua's CheckLeashEligibility re-checks the flag LIVE,
    --- server-side — nothing client-side stopped the pairing from forming)
    --- left an actually-leashed player with no "Detach" item anywhere in
    --- their own radial menu: the button to press did not exist, and their
    --- only way out was client/movement.lua's elastic pull-back safety
    --- valve (walk far enough away) or a death/disconnect/resource
    --- restart — never an acceptable substitute for a deliberate manual
    --- detach. FIXED by widening this gate to `Config.Features.LeashMechanics
    --- OR IsLeashed()`: the item now also appears whenever this client is
    --- ACTUALLY leashed right now, regardless of what its own local flag
    --- copy says — a detach button should exist because you are on a
    --- leash, not because a setting says leashes exist. The ADD path
    --- inside onSelect below is UNCHANGED and still funnels through
    --- RequestLeashAttach()'s own CanShowK9UI()/IsOwnModelK9() checks and
    --- CheckLeashEligibility's own live, authoritative, server-side flag
    --- re-check either way, so widening this gate creates no new way to
    --- start a leash the flag/eligibility rules would otherwise refuse.
    --- See client/movement.lua's own 'john-k9:client:leashStateChanged'
    --- local re-broadcast (fired from its leashAttached/leashDetached
    --- handlers) and this file's own listener near the bottom for how this
    --- item's presence is actually kept live, tick to tick, rather than
    --- only at the rare moments RegisterK9RadialMenu() would otherwise run.
    if Config.Features.LeashMechanics or (type(IsLeashed) == 'function' and IsLeashed()) then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_leash',
            label = locale('radial.leash_toggle_label'),
            icon = 'link',
            onSelect = function()
                -- Detach never requires consent/access — always available
                -- while leashed, per DEVELOPER_REFERENCE.md §9 item 3b's hard requirement.
                -- type(...) == 'function' guards added below per this
                -- file's own header policy -- see k9_sit's identical note
                -- above for the full HEADER/CODE DRIFT FIX writeup. A
                -- absent IsLeashed() is treated as "not currently leashed"
                -- (falls through to the Attach branch), same short-circuit
                -- shape client/radial.lua already uses for
                -- IsFetchCarryEngaged() further down this file.
                if type(IsLeashed) == 'function' and IsLeashed() then
                    if type(DetachLeash) == 'function' then
                        DetachLeash()
                    end
                    return
                end

                -- NOT WIDENED TO HasK9Access() (permission audit finding,
                -- this pass, considered and rejected here specifically):
                -- server/main.lua's CheckLeashEligibility does NOT gate on
                -- HasK9Access() alone -- it requires AT LEAST ONE of the two
                -- parties to be a real K9 by model OR the decoupled K9 role
                -- (IsConfiguredK9Model(...) or HasK9Role(...)), a check that
                -- itself EXCLUDES the High Command/autoAccessGrade bypass,
                -- BEFORE HasK9Access(k9Src) is ever consulted for whichever
                -- party ends up cast as "the K9". A bypass-only holder with
                -- no model and no role can never be treated as the K9 side
                -- of a pairing regardless of what this client shows, so
                -- widening this gate would offer something the server would
                -- then genuinely refuse ('no_k9_party') -- exactly the "offer
                -- something that will just be refused" outcome this pass was
                -- told to avoid. Left on the broader combinator on purpose.
                -- Only the dog needs K9 access to ask; a human handler asks
                -- the server directly, which checks everything (the same
                -- rule RequestLeashAttach() itself follows). This used to be
                -- a plain CanShowK9UI() check, which refused every human
                -- handler -- the person who actually holds the leash.
                if IsOwnModelK9() and not CanShowK9UI() then
                    DenyK9UIAccess('common.no_k9_role_or_access')
                    return
                end

                local candidateServerId = FindNearestLeashCandidate()
                if not candidateServerId then
                    lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_leash_candidate'), type = 'error' })
                    return
                end

                -- This only SENDS a request — per the consent design, nothing
                -- attaches until the target accepts on their own client.
                -- RequestLeashAttach() itself notifies "request sent."
                if type(RequestLeashAttach) == 'function' then
                    RequestLeashAttach(candidateServerId)
                end
            end,
        }
    end

    --- Enter/Exit Vehicle — DEVELOPER_REFERENCE.md §6.1, §8 step 8. A single
    --- context-sensitive item mirroring the ox_target vehicle option
    --- client/vehicle.lua registers directly. Config.Features.VehicleEntryExit
    --- gate.
    ---
    --- ORDERING FIX, THIS PASS: the Exit branch used to sit BEHIND this
    --- item's own access gate — a K9 who lost access mid-ride (decertified,
    --- feature flag flip) would hit DenyK9UIAccess() before ever reaching
    --- the IsInK9Vehicle() check, with no way to exit via this item at all,
    --- exactly the "gate the START of a thing, never the STOP" rule this
    --- codebase holds every other toggle item in this file to (Attach/Detach
    --- Leash, Bite & Hold, Drag all check their own "already engaged" branch
    --- FIRST, ungated, before ever consulting CanShowK9UI()/HasK9Access()).
    --- client/vehicle.lua's own ExitK9Vehicle() doc comment already states
    --- it is "Deliberately NOT gated behind CanShowK9UI() — a K9 whose
    --- certification lapses mid-ride must always be able to get out"; this
    --- item simply did not honor that. Fixed by checking IsInK9Vehicle()
    --- FIRST, exactly mirroring the Leash/Bite & Hold/Drag items' own shape.
    ---
    --- ENTER BRANCH -- FOUND BEYOND THE NAMED LIST, WIDENED HERE (permission
    --- audit finding, this pass): server/vehicle.lua's requestVehicleSeatClaim
    --- gates on `HasK9Access(src)` alone (confirmed by reading it directly —
    --- no model/role check on the REQUESTER anywhere in that handler; only
    --- the VEHICLE itself is re-verified as a real K9 vehicle model), the
    --- identical shape as Bark/Search/Tracking above. RESIDUAL GAP CLOSED
    --- (permission audit follow-up, this pass): client/vehicle.lua's own
    --- EnterNearestK9Vehicle() was ALSO widened from CanShowK9UI() to
    --- HasK9Access() alone (see that function's own doc comment) — a High
    --- Command/autoAccessGrade-bypass holder now reaches the server
    --- end-to-end through this item, with no narrower re-gate left in the
    --- middle. (A separate, narrower, DISCLOSED gap remains in the ox_target
    --- "Load Into Vehicle" hover option's own canInteract predicate, which
    --- still hides on the narrower CanShowK9UI() — see that predicate's own
    --- comment in client/vehicle.lua; a bypass holder simply reaches this
    --- radial item instead.)
    if Config.Features.VehicleEntryExit then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_vehicle',
            label = locale('radial.vehicle_toggle_label'),
            icon = 'car',
            onSelect = function()
                -- Exit checked FIRST, unconditionally -- see this item's own
                -- "ORDERING FIX" header above. type(...) == 'function' guard
                -- -- see k9_sit's identical note above for the full
                -- HEADER/CODE DRIFT FIX writeup. An absent IsInK9Vehicle()
                -- is treated as "not currently in a K9 vehicle" (falls
                -- through to the Enter branch).
                if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
                    if type(ExitK9Vehicle) == 'function' then
                        ExitK9Vehicle()
                    end
                    return
                end

                -- Widened to HasK9Access() alone -- see this item's own
                -- header comment above. Known reason -> 'combat.no_access'.
                if not HasK9Access() then
                    DenyK9UIAccess('combat.no_access')
                    return
                end

                if type(EnterNearestK9Vehicle) == 'function' then
                    EnterNearestK9Vehicle()
                end
            end,
        }
    end

    --- ONE MERGED "K9: Search" ITEM (owner-directed decluttering pass,
    --- 2026-08-26 -- "merge all the scent tracking stuff into one thing so
    --- that way it[’s] less clutter and when certed for extra stuff it
    --- just does it"). REPLACES the three former separate Track Scent /
    --- Track Blood / Track Gunpowder items (DEVELOPER_REFERENCE.md §11.3/§11.5, Phase 2)
    --- with a single context-sensitive item, following the SAME
    --- toggle-vs-defer shape those three used to each implement
    --- independently: while a trail of ANY type is active it becomes a
    --- "Stop" cancel (calling the shared StopTracking(), which works
    --- regardless of which type is active); otherwise it starts the ONE
    --- merged action (StartCertifiedTrack(), client/tracking.lua) that
    --- asks the server to resolve whichever type(s) this specific K9 is
    --- currently entitled to (Config.SpecializationTracking +
    --- HasSpecialization, server-side, never decided here) and search all
    --- of them in one round trip. THIS FILE never picks a trackType, never
    --- reads Config.SpecializationTracking, and never calls
    --- HasSpecialization -- "the server resolves which types apply, the
    --- client must NOT decide this" per this pass's own explicit
    --- requirement; a client-side filter here would just be a filter a
    --- modified client could turn off.
    ---
    --- GATED ON "is at least one of the three underlying trail types even
    --- switched on" (a coarser, DISPLAY-ONLY check -- the real per-type
    --- gate is server-side, re-validated independently for every candidate
    --- type by findNearestTrackableSource regardless of this check) rather
    --- than on any ONE of the three flags alone, since which type(s) end
    --- up actually searchable for a given K9 is now a per-citizenid,
    --- server-resolved fact this file cannot and must not predict.
    --- client/tracking.lua's own 'k9track' chat command is the OTHER entry
    --- point to the exact same StartCertifiedTrack() -- this radial item
    --- adds no logic of its own beyond dispatching to it.
    -- GATE WIDENED TO HasK9Access() ALONE (permission audit finding, this
    -- pass): every real server-side track callback (findTrackableSource/
    -- findNearestTrackableSource, server/tracking.lua) gates on
    -- `HasK9Access(source)` alone -- confirmed by reading them directly. This
    -- item's own Start branch used to gate on the broader CanShowK9UI(),
    -- silently withholding tracking from a High Command/autoAccessGrade
    -- bypass holder the server would happily serve. client/tracking.lua's
    -- OWN StartTrack() already made this exact fix on itself (see that
    -- file's "ANY-PED SWEEP FIX"/"gating on HasK9Access() alone" comment,
    -- confirmed by reading it directly) -- this item was the one remaining
    -- caller still gating stricter than the function it calls into.
    if Config.Features.ScentTracking or Config.Features.BloodTracking or Config.Features.GunpowderSniffing then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_track_certified',
            label = locale('radial.track_certified_label'),
            icon = 'wind',
            onSelect = function()
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup. An
                -- absent GetActiveTrackType()/IsTracking() is treated as
                -- "nothing active" (falls through to the Start branch).
                if type(IsTracking) == 'function' and IsTracking() then
                    if type(StopTracking) == 'function' then
                        StopTracking()
                    end
                    return
                end

                -- HasK9Access() alone -- see this block's own header above.
                if not HasK9Access() then
                    DenyK9UIAccess('combat.no_access')
                    return
                end

                if type(StartCertifiedTrack) == 'function' then
                    StartCertifiedTrack()
                end
            end,
        }
    end

    --- Thermal Vision / Night Vision — REVERTED, SEPARATE AGAIN (owner
    --- reversal, coder-architect, this pass: "I want the thermal and night
    --- vision separate"). An earlier decluttering pass had removed each
    --- mode's own radial entry in favour of the single k9_vision_cycle item
    --- below; the owner has since asked for both to be first-class, visible
    --- controls again, "their own radial entry" specifically named as part
    --- of that. Each item here calls straight through to its own
    --- Toggle*Vision() (client/vision.lua) — no shared/merged logic between
    --- the two, matching the explicit, first-class command + keybind each
    --- already has again (john-k9:toggleThermalVision/K,
    --- john-k9:toggleNightVision/J).
    ---
    --- GATED HERE ON THE MODE'S OWN Config.Features FLAG ONLY — a coarser,
    --- DISPLAY-ONLY check, same convention as every other flag-gated item in
    --- this menu (e.g. k9_track_certified above): Toggle*Vision() itself
    --- re-checks the real IsOwnModelK9() gate on every actual turning-ON
    --- press regardless of what this item's own visibility decided.
    ---
    --- NO CanShowK9UI()/HasK9Access() GATE ON EITHER ITEM, DELIBERATELY —
    --- client/vision.lua's own "RESOLVED ACCESS-GATING DECISION" (do not
    --- re-litigate here): thermal/night vision is the K9's own innate
    --- perception, gated on IsOwnModelK9() alone, the SAME free/local check
    --- client/movement.lua's camera toggle uses, not the full departmental
    --- CanShowK9UI() combinator every OTHER item in this menu uses. Adding
    --- either check here would silently re-impose a certification/access
    --- requirement this feature has never had, for a player who is simply
    --- riding a K9 model right now. Toggle*Vision() already performs the
    --- real IsOwnModelK9() gate (and notifies on failure) on its own
    --- turning-ON branch; turning off is never gated at all, matching every
    --- other release/termination item here.
    if Config.Features.ThermalVision then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_thermal_vision',
            label = locale('radial.thermal_vision_label'),
            icon = 'fire',
            onSelect = function()
                if type(ToggleThermalVision) == 'function' then
                    ToggleThermalVision()
                end
            end,
        }
    end

    if Config.Features.NightVision then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_night_vision',
            label = locale('radial.night_vision_label'),
            icon = 'moon',
            onSelect = function()
                if type(ToggleNightVision) == 'function' then
                    ToggleNightVision()
                end
            end,
        }
    end

    --- Scent Vision — DISCOVERABILITY GAP, closed this pass. The ability
    --- has had its own command and keybind since it shipped, and no radial
    --- entry at all, so the only players who knew it existed were the ones
    --- who read the keybind list. That is the exact "someone may prefer the
    --- wheel" case the two items above were restored for.
    ---
    --- GATED ON Config.Features.ScentVision ALONE — display-only, same
    --- convention as every other flag-gated item here. NOT gated on the
    --- ScentVision *mode* (Config.Tracking.ScentVision.mode): a server
    --- running 'off' or 'always' still gets the item, and
    --- ToggleScentVision() answers with its own dedicated message for each
    --- ("turned off on this server" / "always on for you here, nothing to
    --- toggle"). Hiding the item in those modes would trade a clear
    --- explanation for a silently missing control, which is the opposite of
    --- what this entry is for. The mode is also resolvable live from the
    --- server, so a menu built at one moment could be wrong by the next.
    ---
    --- Access is left to ToggleScentVision()'s own CanShowK9UI() check,
    --- which runs on the turning-ON branch only -- turning off is never
    --- gated, matching every other release path in this file.
    if Config.Features.ScentVision then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_scent_vision',
            label = locale('radial.scent_vision_label'),
            icon = 'paw',
            onSelect = function()
                if type(ToggleScentVision) == 'function' then
                    ToggleScentVision()
                end
            end,
        }
    end

    --- The partner camera has no menu button: it is opened from the tablet
    --- only (owner's choice) -- see client/tablet.lua's
    --- FEATURE_TRIGGERS.CameraFeedPiP.

    --- K9 Vision — EXTRA, OPTIONAL CONVENIENCE, kept alongside the two
    --- explicit items immediately above (owner's own steer: "keep it as an
    --- extra... it costs nothing, someone may prefer it"), not a
    --- replacement for them. ONE item cycling Off -> Night -> Thermal ->
    --- Off, calling the SAME CycleVision() (client/vision.lua) the
    --- 'k9vision' chat command and keybind both call — no logic of its own
    --- beyond dispatching to it, same shape as k9_track_certified above.
    ---
    --- NOT THE SAME MERGE SHAPE AS TRACK ABOVE — see client/vision.lua's own
    --- "CYCLE — EXTRA, OPTIONAL CONVENIENCE" header for the full writeup
    --- this item only summarizes: Track's three types are alternative
    --- answers to one one-shot question, resolved server-side from
    --- certification. Thermal/Night are HELD STATES with no certification
    --- to resolve from, so this is a plain cycle, not a server-resolved pick
    --- — CycleVision() itself is what skips whichever mode is flag-off or
    --- feature-blocked, so this item never has to.
    ---
    --- GATED HERE ON "at least one of the two modes is even switched on" —
    --- a coarser, DISPLAY-ONLY check mirroring k9_track_certified's own
    --- `ScentTracking or BloodTracking or GunpowderSniffing` gate above, not
    --- a claim that CycleVision() itself needs it (it re-checks both flags
    --- on every press regardless, and degrades to an honest "nothing
    --- available" notify if a live tablet flip turns both off after this
    --- item was registered).
    ---
    --- NO CanShowK9UI()/HasK9Access() GATE ON THIS ITEM EITHER, for the
    --- identical reason given for the two explicit items immediately above.
    if Config.Features.NightVision or Config.Features.ThermalVision then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_vision_cycle',
            label = locale('radial.vision_cycle_label'),
            icon = 'eye',
            onSelect = function()
                if type(CycleVision) == 'function' then
                    CycleVision()
                end
            end,
        }
    end

    --- Bite & Hold / Release — DEVELOPER_REFERENCE.md §12.5.1. A single
    --- context-sensitive item, following the SAME toggle shape as Attach/Detach
    --- Leash above: client/combat.lua's RequestBiteHold()/ReleaseBiteHold()/
    --- IsBiteHoldEngaged() are a start/stop pair with an "am I engaged" query,
    --- exactly mirroring IsLeashed()-driven Attach/Detach — so this is written
    --- as ONE item, not two, per that established precedent (two separate
    --- always-visible "Bite & Hold" and "Release" entries would mean one of
    --- them is always a no-op click depending on current state, which is
    --- exactly the shape client/radial.lua's own Leash/Track items already
    --- rejected). CORRECTED (this pass -- the paragraph here previously said
    --- the opposite of what the code below it, and this item's own onSelect
    --- comment, both actually do; a stale, self-contradicting note, fixed
    --- rather than left to mislead a future reader into "fixing" the
    --- toggle's release half back into a gated trap): the Release branch,
    --- exactly LIKE Detach Leash above, skips the access gate entirely on
    --- the way out. client/combat.lua's ReleaseBiteHold() never re-checks
    --- HasK9Access/CanShowK9UI/the feature flag on the way out either (only
    --- that this src is genuinely the holder) — see this item's own
    --- onSelect below for the full "why gating this would strand a K9"
    --- reasoning, which applies here exactly as it does to Detach Leash.
    ---
    --- STRUCTURE CHOICE — flat top-level item, NOT nested under a "Combat"
    --- submenu: unlike Bark's submenu (which nests because Config.
    --- AdvancedBarkRadial is a variable-length, config.lua-driven LIST of
    --- variants sharing one action), BiteAndHold is a single fixed action, and
    --- this menu already has a precedent for keeping multiple thematically-
    --- related-but-functionally-distinct fixed actions flat rather than
    --- grouping them: the three Track items above (Scent/Blood/Gunpowder) are
    --- exactly that shape and were deliberately NOT nested under a "Track"
    --- submenu. BiteAndHold/NonLethalTakedown below follow that same flat
    --- precedent, not Bark's nesting one. Config.Features.BiteAndHold gate
    --- (stays `false` by default — see config.lua).
    ---
    --- START BRANCH WIDENED TO HasK9Access() ALONE (permission audit
    --- finding, this pass): server/combat.lua's shared ValidateCombatRequest
    --- (backing requestBiteHold/requestTakedown/requestDrag alike) gates on
    --- `HasK9Access(src)` alone — confirmed by reading it directly, no
    --- model/role check on the K9 anywhere in that validator — while this
    --- Start branch used to gate on the broader CanShowK9UI(). RESIDUAL GAP
    --- CLOSED (permission audit follow-up, this pass): client/combat.lua's
    --- own RequestBiteHold()/RequestTakedown()/RequestDrag() were ALSO
    --- widened from CanShowK9UI() to HasK9Access() alone (see each
    --- function's own doc comment) — a High Command/autoAccessGrade-bypass
    --- holder now reaches the server end-to-end through this item, with no
    --- narrower re-gate left in the middle. Their matching RELEASE halves
    --- (ReleaseBiteHold/ReleaseDrag, and the still-unwired ReleaseTakedown)
    --- were confirmed to already carry NO access gate of any kind, so this
    --- widening could not, and does not, touch them.
    if Config.Features.BiteAndHold then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_bite_hold',
            label = locale('radial.bite_hold_toggle_label'),
            icon = 'paw',
            onSelect = function()
                -- Release is NOT gated on CanShowK9UI(), matching the Detach
                -- Leash branch above and DEVELOPER_REFERENCE.md §9 item 3b's "no unbounded
                -- trap" requirement. ReleaseBiteHold()'s own doc comment claims
                -- exactly this exemption ("always available while engaged, same
                -- no consent/access gate on the way out"), and server/combat.lua's
                -- releaseBiteHold handler never re-checks HasK9Access or the
                -- feature flag on the way out either -- only that this src is
                -- genuinely the holder.
                --
                -- Gating this would strand a K9 that loses access WHILE engaged
                -- (decertified mid-hold by a supervisor, model swap, or an
                -- operator flipping the feature flag): DenyK9UIAccess() would
                -- fire, the menu would refuse, and the hold would persist to the
                -- server's timeout with no way for the holder to let go. Mid-
                -- action revocation is a real path in this resource, not a
                -- hypothetical -- see server/search.lua's mid-flight
                -- HasK9Access re-check and certifications.lua's
                -- ForceDetachLeashForSource teardown on revoke.
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
                    if type(ReleaseBiteHold) == 'function' then
                        ReleaseBiteHold()
                    end
                    return
                end

                -- HasK9Access() alone -- see this block's own header above.
                if not HasK9Access() then
                    DenyK9UIAccess('combat.no_access')
                    return
                end

                -- RequestBiteHold() itself finds the nearest eligible target and
                -- notifies "no eligible target in range" on failure — nothing
                -- further to do here, same "call straight through, no
                -- re-derived logic in this file" posture as Sit/Vehicle above.
                if type(RequestBiteHold) == 'function' then
                    RequestBiteHold()
                end
            end,
        }
    end

    --- Non-Lethal Takedown — DEVELOPER_REFERENCE.md §12.5.2. A CONTEXT-SENSITIVE
    --- TOGGLE, the same shape as Bite & Hold above and Drag / Release below.
    ---
    --- THIS USED TO BE A ONE-SHOT, and this paragraph used to justify that:
    --- "client/combat.lua exposes only RequestTakedown(), with no matching
    --- release/cancel counterpart and no IsTakedownEngaged()-style query —
    --- the forced ragdoll it triggers always ends on its own... never by a
    --- second player action the way releasing a bite hold does... the
    --- underlying capability itself has no second state to toggle back
    --- from." Every sentence of that was true when written. It stopped
    --- being true when client/combat.lua gained both ReleaseTakedown() and
    --- IsTakedownEngaged(), and this item was simply never updated -- so
    --- the release stayed reachable from nothing at all until the pass that
    --- rewrote this comment also wired the branch below.
    ---
    --- Kept flat (not nested), same "Track precedent over Bark precedent"
    --- reasoning as Bite & Hold above.
    --- Kept flat (not nested), same "Track precedent over Bark precedent"
    --- reasoning as Bite & Hold above. Config.Features.NonLethalTakedown gate
    --- (stays `false` by default — see config.lua).
    ---
    --- WIDENED TO HasK9Access() ALONE, SAME RESIDUAL GAP CLOSED AS BITE &
    --- HOLD -- see that item's own header comment above for the full
    --- writeup (shared ValidateCombatRequest, and client/combat.lua's own
    --- RequestTakedown() ALSO widened from CanShowK9UI() to HasK9Access()
    --- alone); applies here verbatim, not repeated in full.
    if Config.Features.NonLethalTakedown then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_takedown',
            label = locale('radial.takedown_label'),
            icon = 'zzz',
            onSelect = function()
                -- NOW A TOGGLE, matching Bite & Hold and Drag / Release
                -- above (completeness QA finding, this pass; the keybind
                -- half landed first, in client/keybinds.lua). This item's
                -- own header above used to argue at length that takedown
                -- was correctly a ONE-SHOT because "client/combat.lua
                -- exposes only RequestTakedown(), with no matching
                -- release/cancel counterpart and no IsTakedownEngaged()-
                -- style query... the underlying capability itself has no
                -- second state to toggle back from." That was true when
                -- written. Both functions exist now, and that header has
                -- been corrected alongside this change.
                --
                -- WHY IT MATTERS: RequestTakedown() picks the NEAREST
                -- eligible ped, which client/combat.lua's own comment
                -- admits is "not necessarily the intended one". Take down
                -- the wrong person in a crowd and they stayed force-
                -- ragdolled and damage-immune for the full configured
                -- duration with no undo, and no route at all for a solo
                -- K9, which this resource documents as a supported way to
                -- play.
                --
                -- RELEASE BRANCH FIRST AND UNGATED, exactly as Bite &
                -- Hold's own branch above documents for itself: this is
                -- the STOP half, so it asks no access question. Gating it
                -- would strand a K9 decertified mid-takedown. Only the
                -- request branch below carries a gate.
                if type(IsTakedownEngaged) == 'function' and IsTakedownEngaged() then
                    if type(ReleaseTakedown) == 'function' then
                        ReleaseTakedown()
                    end
                    return
                end

                if not HasK9Access() then
                    DenyK9UIAccess('combat.no_access')
                    return
                end

                -- RequestTakedown() itself finds the nearest eligible target and
                -- notifies on failure; the server independently re-derives
                -- eligibility (e.g. the fleeing/speed gate) from live position
                -- samples regardless of anything this client claims — see
                -- client/combat.lua's own comment on RequestTakedown() for why
                -- no local "is the target fleeing" pre-check belongs here.
                -- type(...) == 'function' guard -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(RequestTakedown) == 'function' then
                    RequestTakedown()
                end
            end,
        }
    end

    --- Drag / Release — DEVELOPER_REFERENCE.md §12.5.4. A single context-sensitive item,
    --- the SAME toggle shape as Bite & Hold / Attach-Detach Leash above:
    --- client/combat.lua's RequestDrag()/ReleaseDrag()/IsDragEngaged() are a
    --- start/stop pair with an "am I engaged" query, exactly mirroring
    --- IsBiteHoldEngaged()-driven Bite & Hold — so this is one item, not two,
    --- for the same reason given there (two always-visible entries would mean
    --- one is always a no-op click depending on current state). Kept flat (not
    --- nested), same "Track precedent over Bark precedent" reasoning as Bite &
    --- Hold/Non-Lethal Takedown above. Config.Features.PropDragging gate (stays
    --- `false` by default — see config.lua).
    ---
    --- RELEASE ORDERING — do not gate this on CanShowK9UI(): same "no
    --- unbounded trap" requirement as Detach Leash and Bite & Hold's own
    --- Release branch above (DEVELOPER_REFERENCE.md §9 item 3b — see Bite & Hold's comment
    --- block above for the full reasoning, which applies here verbatim).
    --- client/combat.lua's ReleaseDrag() itself never re-checks
    --- HasK9Access/feature-flag on the way out either (only that this src is a
    --- legitimate party to the drag, holder or target) — gating this client-side
    --- check would strand a K9 that loses access mid-drag (decertified,
    --- feature-flag flip, model swap) with no way to let go, stranding the drag
    --- until the server's maxDragDurationMs timeout. This was the exact mistake
    --- corrected for Bite & Hold above; not repeating it here.
    ---
    --- START BRANCH WIDENED TO HasK9Access() ALONE, SAME RESIDUAL GAP CLOSED
    --- AS BITE & HOLD/TAKEDOWN -- see Bite & Hold's own header comment above
    --- for the full writeup; applies here verbatim (shared
    --- ValidateCombatRequest, and client/combat.lua's own RequestDrag()
    --- ALSO widened from CanShowK9UI() to HasK9Access() alone).
    if Config.Features.PropDragging then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_drag',
            label = locale('radial.drag_toggle_label'),
            icon = 'hand',
            onSelect = function()
                -- Release is NOT gated on CanShowK9UI() — see this item's
                -- header comment above ("RELEASE ORDERING") for why.
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                -- Being dragged is its own release branch, asked FIRST --
                -- see client/keybinds.lua's k9dragtoggle for the full
                -- reasoning. It matters slightly less here than on the
                -- keybind (a dragged human suspect has no radial menu at
                -- all), but a K9 can itself be downed and dragged, and for
                -- that K9 this menu is the obvious place to look for the
                -- way out.
                if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then
                    if type(ReleaseDrag) == 'function' then
                        ReleaseDrag()
                    end
                    return
                end

                if type(IsDragEngaged) == 'function' and IsDragEngaged() then
                    if type(ReleaseDrag) == 'function' then
                        ReleaseDrag()
                    end
                    return
                end

                if not HasK9Access() then
                    DenyK9UIAccess('combat.no_access')
                    return
                end

                -- RequestDrag() itself finds the nearest eligible target and
                -- notifies "no eligible target in range" on failure — nothing
                -- further to do here, same "call straight through, no
                -- re-derived logic in this file" posture as Sit/Vehicle/Bite &
                -- Hold above.
                if type(RequestDrag) == 'function' then
                    RequestDrag()
                end
            end,
        }
    end

    --- Partner Up / Break Partnership -- ONE item (the owner's rework pass),
    --- like Attach/Detach Leash. It used to be two items shown side by side
    --- all the time, because the local partnership cache can be wrong after
    --- a reconnect; client/partnership.lua's TogglePartnership() now asks
    --- the server first and then does the right one. Breaking is never
    --- gated. Run in a thread because the server check yields.
    if Config.Features.HandlerPartnership then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_partner',
            label = locale('radial.partner_toggle_label'),
            icon = 'handshake',
            onSelect = function()
                if type(TogglePartnership) ~= 'function' then return end
                CreateThread(function() TogglePartnership() end)
            end,
        }
    end




    --- Fetch -- Phase 5 (FetchMechanic). client/fetch.lua exposes
    --- RequestThrowFetchBall()/ReleaseFetchBall()/RequestRecallFetchBall()/
    --- IsFetchCarryEngaged() specifically for a client/radial.lua entry to
    --- call (that file's own header); this submenu is that entry point.
    --- "Pick Up Ball" and "Deliver to Handler" stay ox_target options exactly
    --- as client/fetch.lua's own header already documents (targeted,
    --- proximity-driven actions on a specific ball/player, not a
    --- self-initiated radial verb) -- not duplicated here.
    ---
    --- FETCH -- ONE item, one click (the owner's rework pass). It used to open
    --- a sub-menu with Throw/Drop and Recall. client/fetch.lua's
    --- FetchContextual() picks the right one: drop if carrying, recall if a
    --- ball you threw is out (so the thrower, usually not the carrier, still
    --- gets Recall), otherwise throw. Drop and Recall are never gated; Throw
    --- gates itself (HasK9Access, a human-handler action).
    if Config.Features.FetchMechanic then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_fetch',
            label = locale('radial.fetch_menu_label'),
            icon = 'baseball',
            onSelect = function()
                if type(FetchContextual) == 'function' then FetchContextual() end
            end,
        }
    end

    --- Toggle K9 Vest -- Phase 5 R&D (PropAttachments). Closes a real gap:
    --- client/propattachment.lua exposes RequestToggleK9PropAttachment()
    --- specifically "so a future radial entry can call this directly without
    --- this file needing to change" (that function's own doc comment); this
    --- item is that entry point, alongside the existing '/k9propattach'
    --- command.
    ---
    --- A SINGLE FLAT TOGGLE ITEM, not two -- RequestToggleK9PropAttachment()
    --- is already a toggle by design (its own doc comment: "a toggle is a
    --- single request whose MEANING (add vs remove) is decided server-side by
    --- whether PropAttachmentState already has an entry"), so this item does
    --- NOT attempt to locally track "do I currently have a vest on" the way
    --- IsLeashed()/IsBiteHoldEngaged()/IsDragEngaged()/IsFetchCarryEngaged()
    --- key their own toggles -- there is no equivalent client-exposed query to
    --- read here, and the underlying function does not need one either: it
    --- always sends, and the server decides what that means.
    ---
    --- GATED ON CanShowK9UI() here too, even though
    --- RequestToggleK9PropAttachment() already re-checks it (and
    --- Config.Features.PropAttachments itself) internally -- same redundant
    --- "check here too, even though the callee already checks" posture every
    --- other gated item in this file already uses.
    -- MOVED into the Utility sub-menu, this pass (Job 3 regrouping) -- a
    -- pure toggle with no release/termination half worth protecting (see
    -- this function's own "REGROUPING PASS" header near k9UtilitySubmenuItems'
    -- declaration for the full safety reasoning).
    if Config.Features.PropAttachments then
        k9UtilitySubmenuItems[#k9UtilitySubmenuItems + 1] = {
            id = 'k9_prop_attachment',
            label = locale('radial.toggle_vest_label'),
            icon = 'vest',
            onSelect = function()
                -- NOT GATED HERE, DELIBERATELY -- and this is not the same
                -- question as "should this be widened".
                --
                -- The old comment here was right that the ADD path is
                -- stricter than HasK9Access() alone, so this item was
                -- correctly NOT widened. But it then checked CanShowK9UI()
                -- before calling the toggle, and the toggle is the function
                -- that decides whether this is an add or a REMOVE. That
                -- reintroduced, one layer up, a trap already found and fixed
                -- one layer down: a handler who lost their certification
                -- while wearing a vest was refused here, and the vest stayed
                -- welded on. Decertification does not tear prop attachments
                -- down server-side the way it does leashes, holds and
                -- partnerships, so this was genuinely the way out.
                --
                -- RequestToggleK9PropAttachment resolves intent first: if a
                -- vest is on, the removal goes through unconditionally;
                -- otherwise it applies the full ADD gate itself and calls
                -- DenyK9UIAccess() with the same reason this used to. So
                -- nothing is widened and no message is lost -- the strictness
                -- simply now lives at the point that knows which direction
                -- the player is going.
                if type(RequestToggleK9PropAttachment) == 'function' then
                    RequestToggleK9PropAttachment()
                end
            end,
        }
    end

    --- Deploy Kennel -- Phase 5 R&D (DeployableKennel). Closes a real gap:
    --- client/kennel.lua exposes RequestDeployKennel() specifically "so a
    --- future radial item can call it directly once client/radial.lua is
    --- available to extend again" (that function's own doc comment); this item
    --- was originally that entry point, alongside the existing
    --- '/k9deploykennel' command.
    ---
    --- HISTORICAL, NO LONGER CURRENT -- the two paragraphs immediately below
    --- ("DEPLOY-ONLY, BY DESIGN" and "GATED ON CanShowK9UI() here too")
    --- describe the item as it existed BEFORE the "MERGED" paragraph further
    --- down. Both are now false of the actual k9SubmenuItems entry
    --- registered below: it is no longer deploy-only (it also handles enter/
    --- exit/close/open) and it is no longer gated on CanShowK9UI() at all
    --- (see the "MERGED"/"NOW REGISTERED UNCONDITIONALLY"/"NO CanShowK9UI()
    --- GATE HERE EITHER" paragraphs, which are the current, accurate
    --- description). Left in place for the "why deploy-only was originally
    --- chosen" context, not as a description of current behavior.
    ---
    --- DEPLOY-ONLY, BY DESIGN, NOT A DISCLOSED OMISSION -- "Pick Up Kennel"
    --- stays client/kennel.lua's own established ox_target option on the
    --- physical prop (its own header names that as the entry point for that
    --- half); there is no location-independent "recall my kennel" global
    --- exposed anywhere in this resource to mirror here (unlike Fetch's
    --- RequestRecallFetchBall() above), so this item has no release/recall
    --- counterpart to add alongside it.
    ---
    --- GATED ON CanShowK9UI() here too, even though RequestDeployKennel()
    --- already re-checks it (and Config.Features.DeployableKennel, and its own
    --- "already have one deployed" local short-circuit) internally -- same
    --- redundant "check here too, even though the callee already checks"
    --- posture every other gated item in this file already uses.
    --- MERGED, owner-directed decluttering pass. This used to be a gated
    --- "Deploy Kennel" item, with a separate ungated "Exit Kennel" item
    --- below it -- two flat entries in this menu for what is one job. It is
    --- now ONE entry covering deploy, enter, exit, close and open.
    --- RequestKennelContextual() (client/kennel.lua) works out which of the
    --- five is meant from what is actually around you, asking the server for
    --- the facts a client is never told -- whether the kennel is occupied,
    --- and whether its door is shut -- rather than guessing at them.
    ---
    --- NOW REGISTERED UNCONDITIONALLY, where Deploy Kennel was gated on
    --- Config.Features.DeployableKennel. This is the load-bearing part of
    --- the merge and must not be "tidied" back behind the flag: the old Exit
    --- Kennel item was deliberately ungated because LEAVING a kennel is a
    --- termination path, and a player who is inside one when an admin
    --- switches the feature off would otherwise be sealed in with no way
    --- out. Folding the two together means this single item now carries that
    --- exit path, so it inherits that rule. RequestKennelContextual()
    --- re-runs every real check itself -- including the feature flag, for
    --- every action except the exit -- so a gate here would remove the way
    --- out and protect nothing.
    ---
    --- NO CanShowK9UI() GATE HERE EITHER, for the same reason and matching
    --- the old Exit Kennel item and Detach Leash, both of which skip the
    --- access gate entirely on the way out of a mechanic.
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_kennel',
        -- A person can put a kennel down, pick it up and open or close its
        -- door; only the dog can get in -- so the label says which.
        label = (type(IsOwnModelK9) == 'function' and not IsOwnModelK9()) and locale('radial.kennel_label_handler') or locale('radial.kennel_label'),
        icon = 'house-chimney',
        onSelect = function()
            if type(RequestKennelContextual) == 'function' then
                RequestKennelContextual()
            end
        end,
    }

    --- Exit Kennel -- trap-hunt fix, THIS PASS. A "Rest in Kennel" occupant
    --- (client/kennel.lua's enterKennelConfirmed) is attached at
    --- config.lua's Config.DeployableKennel.restOffsetX/Y/Z (0,0,0, by
    --- design, so the ped sits inside the small cage model's own bounds) --
    --- before this pass, the ONLY way out was re-selecting that same small,
    --- likely camera-occluding prop through ox_target. This item, plus the
    --- new k9exitkennel keybind (client/keybinds.lua), closes that gap --
    --- see client/kennel.lua's ExitKennelRest() doc comment for the full
    --- writeup, and this file's own file-load-time comment above (the
    --- master list of every global this file calls) already covers
    --- client/kennel.lua's other kennel entry points.
    ---
    --- REGISTERED UNCONDITIONALLY -- A DELIBERATE DEVIATION FROM THE
    --- ATTACH/DETACH LEASH ITEM'S OWN "WIDENED GATE" PRECEDENT ABOVE, found
    --- and disclosed while writing this pass's own test: that item's gate
    --- (`Config.Features.LeashMechanics or (IsLeashed() ...)`) is only
    --- actually "kept live, tick to tick" (that item's own comment's exact
    --- words) if something re-runs RegisterK9RadialMenu() at the moment
    --- IsLeashed() flips true -- its own comment CLAIMS
    --- client/movement.lua's 'john-k9:client:leashStateChanged' local
    --- re-broadcast is paired with "this file's own listener near the
    --- bottom" for exactly that -- but no such AddEventHandler for that
    --- event exists anywhere in this file (verified by reading, not
    --- assumed): RegisterK9RadialMenu() is in fact only ever re-run by
    --- 'onResourceStart' or 'john-k9:client:featureBlocksApplied', per
    --- this file's own file-load-time header list. That comment is
    --- therefore ALSO a stale/false claim, of the identical class this pass
    --- already found and fixed in client/kennel.lua's own WANDER-OFF EXIT
    --- comment -- flagged to the team, but fixing THAT pre-existing leash
    --- item is outside this pass's own scope (it is not the confining
    --- mechanic this pass was asked to fix, and it has other exits: the
    --- leash's own automatic hard-cap safety valve, and LeashMechanics
    --- ships `true` by default so the item is normally visible from
    --- resource start regardless).
    ---
    --- For THIS item, an equivalent widened-but-not-actually-live gate
    --- would recreate the exact same class of bug for a MUCH higher-stakes
    --- feature (an occupant physically inside a kennel prop, not merely
    --- leashed): if Config.Features.DeployableKennel happened to be false
    --- the one time RegisterK9RadialMenu() last ran, this item would simply
    --- never exist in the menu at all, REGARDLESS of IsRestingInKennel()'s
    --- live value, for as long as the resource stays up -- exactly the
    --- "hidden right when someone actually needs it" failure this whole
    --- pass exists to close. UNCONDITIONAL registration (same shape as Sit
    --- above, which also carries no Config.Features gate of its own) has no
    --- such gap: the item is simply always in the menu, and onSelect is a
    --- safe, harmless no-op via ExitKennelRest() -> ReleaseKennelRest()'s
    --- own `if not restState then return end` guard for the overwhelming
    --- common case of a player who was never resting at all.
    ---
    --- GATE THE START OF A THING, NEVER THE STOP: onSelect below calls
    --- ExitKennelRest() directly, with NO CanShowK9UI()/access gate of its
    --- own -- unlike every OTHER item in this file (including Deploy
    --- Kennel immediately above), an exit-adjacent action is never gated on
    --- the way out. Mirrors Detach Leash's own onSelect, which skips the
    --- access gate entirely for the identical reason (that item's own
    --- comment: "Detach never requires consent/access — always available
    --- while leashed").
    --- FOLDED INTO 'k9_kennel' ABOVE, which is now unconditional precisely so
    --- this exit path survives the feature being switched off. Everything the
    --- long comment above this describes still holds -- it is kept because it
    --- is the reasoning that makes the merged item safe, and losing it would
    --- invite somebody to gate that item and reintroduce the trap. The
    --- ExitKennelRest() call itself now happens inside
    --- RequestKennelContextual(), which resolves exit ahead of every other
    --- action for exactly this reason.

    --- Open My Gear -- Phase 4 (K9Inventory). Closes a real gap: client/inventory.lua
    --- exposes RequestOpenOwnK9Inventory() specifically as a "future
    --- client/radial.lua 'Open My Gear' item" entry point (see that file's own
    --- header, "RESOLVED" note); this item is that entry point -- the only
    --- other live entry point into a K9 player's own gear stash is the
    --- ox_target "Open K9 Gear" option on their own ped, awkward/unusual UX
    --- for targeting yourself (that file's own header names this exact
    --- awkwardness as the reason a self-service global was added).
    ---
    --- `RequestOpenOwnK9Inventory()` takes no arguments and re-checks both
    --- CanShowK9UI() and Config.Features.K9Inventory internally (confirmed by
    --- reading client/inventory.lua directly, not assumed) -- this item's own
    --- CanShowK9UI() gate below is therefore redundant with the callee, same
    --- "check here too, even though the callee already checks" posture every
    --- other gated item in this file already uses (Toggle K9 Vest/Deploy Kennel
    --- immediately above are the closest precedent: both call a self-contained,
    --- already-gated global the exact same way). This is an INITIATION action
    --- (opens a stash against the local player's own ped), not a
    --- release/termination one, so the "no unbounded trap" exemption given to
    --- Detach Leash/Recall/etc. above does not apply here.
    -- MOVED into the Utility sub-menu, this pass (Job 3 regrouping) -- a
    -- pure initiation action with no release/termination half (see this
    -- function's own "REGROUPING PASS" header near k9UtilitySubmenuItems'
    -- declaration for the full safety reasoning).
    if Config.Features.K9Inventory then
        k9UtilitySubmenuItems[#k9UtilitySubmenuItems + 1] = {
            id = 'k9_open_inventory',
            label = locale('radial.open_inventory_label'),
            icon = 'briefcase',
            onSelect = function()
                -- NOT WIDENED -- server/inventory.lua's own openK9Inventory
                -- (self-targeted here, targetServerId == source) requires
                -- HasK9Access(targetServerId) AND (a real K9 model OR the
                -- decoupled K9 role) for the K9 whose gear is being opened
                -- -- confirmed by reading it directly, and that file's own
                -- comment explicitly rejects dropping the model/role half
                -- ("HasK9Access is deliberately BROADER than the K9 role...
                -- neither of whom is actually the K9"). Same class as
                -- Leash/Partnership above; left on the broader combinator.
                if not CanShowK9UI() then
                    DenyK9UIAccess('common.no_k9_role_or_access')
                    return
                end

                if type(RequestOpenOwnK9Inventory) == 'function' then
                    RequestOpenOwnK9Inventory()
                end
            end,
        }
    end

    --- Treat K9 -- Phase 4 (K9Medkit). Closes a real gap: client/medkit.lua
    --- exposes RequestTreatNearestK9() specifically as a radial entry point
    --- (see that file's own header, "FILE-TO-FILE CONTRACT" -> "THIS FILE
    --- exposes one resource-global function for a radial entry point"); this
    --- item is that entry point -- the only other live entry point into the
    --- treat-request sequence is the ox_target "Treat K9" option on a
    --- specifically-targeted K9 player, leaving a handler with no visible
    --- nearby K9 (or who simply prefers the radial) no way to self-initiate the
    --- same request against the nearest eligible K9.
    ---
    --- Label reuses `medkit.treat_target_label` ("Treat K9") rather than
    --- minting a byte-identical second key -- same "reuse an existing key
    --- when the English matches exactly" convention this file already applies
    --- to Partner Up's `partnership.partner_up_target_label` and the opener's
    --- `${common.notify_title}` cross-reference (see this file's own header /
    --- DEVELOPER_REFERENCE.md).
    ---
    --- `RequestTreatNearestK9()` takes no arguments and re-checks
    --- Config.Features.K9Medkit internally.
    ---
    --- CanShowK9UI() PRE-CHECK REMOVED HERE, THIS PASS (permission audit
    --- finding): "Treat K9" is a HUMAN HANDLER action, not a K9 ability --
    --- server/medkit.lua's own header states this by name ("Does NOT call
    --- HasK9Access -- eligibility to USE a medkit ON a K9 is job-only, never
    --- HasK9Access -- not the K9 being treated") and its real gate,
    --- IsMedkitUserAuthorized(source), checks Config.Departments/EmsJobSet
    --- job membership ONLY, never HasK9Access, model, or role for the USING
    --- player. This item's own onSelect used to gate that human-officer
    --- action behind CanShowK9UI() -- IsK9Role() AND HasK9Access(), i.e.
    --- "must yourself currently be an on-duty, certified K9" -- which is not
    --- what the server asks of the treater at all, and is a STRICTER,
    --- FACTUALLY WRONG requirement for this specific action (not merely a
    --- High-Command-bypass edge case: a plain PD/EMS officer with ZERO K9
    --- certification of their own was refused a mechanic the server would
    --- have granted). This matches how client/medkit.lua's own "Treat K9"
    --- ox_target predicate has ALWAYS worked (it never checks the treater's
    --- own CanShowK9UI() either -- only that the TARGET looks like a K9) --
    --- this radial item's self-service entry point simply had not been
    --- brought in line with it. client/medkit.lua's RequestTreatNearestK9()
    --- has had its own matching, redundant CanShowK9UI() pre-check removed
    --- in that same pass (see its own doc comment) — removing only ONE of
    --- the two would have left the other blocking exactly what this fix
    --- exists to unblock. The server (IsMedkitUserAuthorized, per-target
    --- proximity/model/aliveness/cooldown checks) remains the real,
    --- independent authority regardless; a non-eligible clicker now gets
    --- RequestTreatK9()'s own specific 'no_access'/'not_granted' rejection
    --- instead of this file's generic denial -- a strictly more honest
    --- failure, not a weaker one.
    -- MOVED into the Utility sub-menu, this pass (Job 3 regrouping) -- a
    -- pure initiation action with no release/termination half (see this
    -- function's own "REGROUPING PASS" header near k9UtilitySubmenuItems'
    -- declaration for the full safety reasoning).
    if Config.Features.K9Medkit then
        k9UtilitySubmenuItems[#k9UtilitySubmenuItems + 1] = {
            id = 'k9_treat_nearest',
            label = locale('medkit.treat_target_label'),
            icon = 'kit-medical',
            onSelect = function()
                if type(RequestTreatNearestK9) == 'function' then
                    RequestTreatNearestK9()
                end
            end,
        }
    end

    -- Every conditional Utility item (Toggle K9 Vest/Open My Gear/Treat K9)
    -- above has now had its chance to append into k9UtilitySubmenuItems,
    -- on top of Sit (unconditional, appended at this table's own
    -- declaration) -- register the sub-menu itself NOW, same
    -- `lib.registerRadial({id=..., items=...})` shape as every other nested
    -- sub-menu in this file. The 'k9_utility' OPENER linking into this id
    -- was already appended to k9SubmenuItems earlier (right after Command
    -- Tablet) -- see that append's own comment for why registering here,
    -- after the opener already exists earlier in the array, is still safe.
    lib.registerRadial({
        id = 'k9unit_utility',
        items = k9UtilitySubmenuItems,
    })



    -- ======================================================================
    -- DISPLAY ORDER PASS (whole-menu ease-of-use audit, this pass). Every
    -- item above is appended to k9SubmenuItems in ACCRETION order -- wherever
    -- its own feature's code block happened to land as this menu grew across
    -- many separate passes -- never in the order a player should actually
    -- meet them. Reordered HERE, ONCE, right before registration: this
    -- touches no gate, no onSelect closure, no id, no Config.Features check,
    -- and changes which items exist for nobody -- only the sequence ox_lib's
    -- own wheel paginates them in. Every nested submenu (`k9unit_bark`/
    -- `k9unit_utility`) was already registered, in full,
    -- by the code above --
    -- this pass only ever reshuffles the flat list of OPENER/terminal items
    -- that live directly inside 'k9unit' itself; it never reaches inside a
    -- nested submenu's own item list.
    --
    -- THE ORDER CHOSEN, AND WHY (front-to-back):
    --   1. Command Tablet   -- unchanged from before this pass: "the one
    --      entry that reaches everything else stays the most prominent, not
    --      the most nested" (this item's own comment, still true).
    --   2-5. Bark, Attach/Detach Leash, Enter/Exit Vehicle, Utility -- the
    --      Phase 1 foundational actions (DEVELOPER_REFERENCE.md §6.1 names
    --      exactly this set, plus Sit, which the Utility opener now carries)
    --      plus their direct extension point, grouped together right after
    --      the Tablet. These are the single most-used, most one-shot actions
    --      in the whole wheel and used to be scattered by whichever pass
    --      added them (Utility sat 2nd, ahead of Bark, purely because that
    --      was where its own opener happened to be appended in the source).
    --   6-7. Partner Up, THEN Break Partnership -- swapped from before this
    --      pass (Break Partnership used to precede Partner Up). Every OTHER
    --      start/stop pair in this menu lists the start action before its
    --      own stop (Attach before Detach, Enter before Exit, Bite & Hold
    --      before Release, Drag before Release, Throw before Recall) --
    --      Partnership was the one place a termination action was ordered
    --      AHEAD of the initiation it terminates, backwards from every
    --      sibling convention and from the plain fact that you cannot break
    --      a partnership you have not formed yet. Nothing about either
    --      item's own gating changed -- Break Partnership still carries no
    --      CanShowK9UI() gate of any kind (see its own comment above,
    --      unaffected by display order).
    --   8-13. K9: Search (tracking), Thermal Vision, Night Vision, Scent
    --      Vision, K9 Camera Feed, Cycle Vision -- the perception family,
    --      grouped together and placed before Combat: a K9 finds/reads a
    --      scene before it acts on one. Scent Vision and Camera Feed were
    --      ADDED to this family (discoverability pass) -- both had a command
    --      and a keybind from the day they shipped and no wheel entry at
    --      all, so the only players who knew they existed were the ones who
    --      read the keybind list. Both sit after the two innate vision modes
    --      and before Cycle Vision, which stays last in the family as the
    --      catch-all convenience it has always been. Camera Feed is the one
    --      HANDLER-side perception item among them, grouped here by what it
    --      does (see through the dog) rather than by who presses it.
    --   14-16. Bite & Hold, Non-Lethal Takedown, Drag -- the combat family,
    --      immediately following Perception (search, then engage), ordered
    --      by escalation and with each engagement's own release living on
    --      the same item as the engagement that opened it.
    --   17-18. Fetch, then Kennel -- recreational/logistics items, kept
    --      together and placed last, after the serious combat cluster,
    --      matching how every other "not actually urgent" item in this list
    --      already trends toward the back.
    --
    -- FAIL-SAFE FOR A FUTURE ITEM: K9_SUBMENU_DISPLAY_ORDER is consulted by
    -- ID. Any id NOT listed here (a future item added above without a
    -- matching entry in this list) is APPENDED AFTER every explicitly
    -- ordered id, in the SAME relative order it already had among other
    -- unlisted ids (a stable partition, not a silent drop) -- so forgetting
    -- to place a brand-new item here never hides it, it only leaves that one
    -- item exactly as visible as this whole audit found the menu before this
    -- pass: at the back, in accretion order, the same "needs a design
    -- decision, not a bug" state every item in this list started in.
    -- ======================================================================
    local K9_SUBMENU_DISPLAY_ORDER = {
        'k9_open_tablet',
        'k9_bark', 'k9_leash', 'k9_vehicle', 'k9_partner',
        'k9_bite_hold', 'k9_takedown', 'k9_drag',
        'k9_track_certified', 'k9_scent_vision', 'k9_thermal_vision', 'k9_night_vision', 'k9_vision_cycle',
        'k9_utility',
        'k9_fetch', 'k9_kennel',
    }
    do
        local orderIndex = {}
        for i, id in ipairs(K9_SUBMENU_DISPLAY_ORDER) do orderIndex[id] = i end

        local ordered, unordered = {}, {}
        for _, item in ipairs(k9SubmenuItems) do
            if orderIndex[item.id] then
                ordered[#ordered + 1] = item
            else
                unordered[#unordered + 1] = item
            end
        end
        table.sort(ordered, function(a, b) return orderIndex[a.id] < orderIndex[b.id] end)
        for _, item in ipairs(unordered) do
            ordered[#ordered + 1] = item
        end
        k9SubmenuItems = ordered
    end

    -- ======================================================================
    -- GROUPS -- NO "MORE..." PAGES (the owner's rework pass: "super easy to
    -- use"). ox_lib's radial shows 6 slots a page and turns the 6th into
    -- "More..." whenever there are more items (web/src/features/menu/radial,
    -- PAGE_ITEMS = 6). This menu had about 17, so bite, takedown and drag sat
    -- on the THIRD page -- three presses deep in the middle of a pursuit.
    --
    -- Now the K9 menu holds at most six entries: Tablet, Bark, and four
    -- groups -- Partner & Leash (leash, vehicle, partner), Combat, Senses, and
    -- Utility (which also takes Fetch and Kennel). Every action is at most
    -- two presses away, and no page ever needs "More...".
    --
    -- Nothing is removed and no gate moves: each group is a plain sub-menu
    -- holding the SAME item tables built above, onSelect closures untouched.
    -- A group with only one available item on this server is not wrapped at
    -- all -- that item stays in the top menu, so nobody opens a sub-menu to
    -- find a single button.
    -- ======================================================================
    -- ======================================================================
    -- ONE MENU PER PLAYER (owner: "act like you are a player... super
    -- simple"). A human handler used to open the K9 menu and find it full
    -- of dog-only moves -- Sit, Bark, Bite, Scent Vision -- that could only
    -- ever refuse. Now the menu is built for who you are playing right now:
    --   the dog sees its own moves; a human sees the handler's.
    -- Shared buttons (tablet, leash, vehicle, partner, fetch, kennel) stay
    -- in both. Nothing is removed from the game: every keybind and command
    -- still works, and the menu is rebuilt the moment your character
    -- changes (see the refresh loop at the bottom of this file).
    -- "Gate the start, never the stop": a dog-only move that is still
    -- running (a bite or drag held while the character changes) keeps its
    -- button so it can always be let go.
    -- ======================================================================
    do
        local DOG_ONLY = {
            k9_sit = true, k9_bark = true, k9_track_certified = true, k9_vehicle = true,
            k9_scent_vision = true, k9_thermal_vision = true, k9_night_vision = true, k9_vision_cycle = true,
            k9_bite_hold = true, k9_takedown = true, k9_drag = true,
            k9_prop_attachment = true, k9_open_inventory = true,
        }
        local HUMAN_ONLY = { k9_treat_nearest = true }
        local STILL_RUNNING = {
            k9_bite_hold = function() return type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() end,
            k9_vehicle = function() return type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() end,
            k9_drag = function() return type(IsDragEngaged) == 'function' and IsDragEngaged() end,
            k9_track_certified = function() return type(IsTracking) == 'function' and IsTracking() end,
            k9_prop_attachment = function() return type(IsPropAttachmentEngaged) == 'function' and IsPropAttachmentEngaged() end,
            k9_fetch = function() return type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() end,
            k9_kennel = function() return type(IsRestingInKennel) == 'function' and IsRestingInKennel() end,
        }
        local amDog = type(IsOwnModelK9) == 'function' and IsOwnModelK9()
        local hide = amDog and HUMAN_ONLY or DOG_ONLY

        -- SHOW ONLY WHAT YOU CAN USE (owner: "what they have been certified
        -- in"): a button whose ability high command has blocked for you is
        -- left out, and a dog without K9 access (not certified) does not
        -- get the dog's moves. Leash and Partner Up are never hidden this
        -- way -- partnering is how an uncertified handler gets access.
        local FEATURE_OF_ITEM = {
            k9_bark = 'BasicBarkSounds', k9_vehicle = 'VehicleEntryExit', k9_track_certified = 'ScentTracking',
            k9_scent_vision = 'ScentVision', k9_thermal_vision = 'ThermalVision', k9_night_vision = 'NightVision',
            k9_bite_hold = 'BiteAndHold', k9_takedown = 'NonLethalTakedown', k9_drag = 'PropDragging',
            k9_fetch = 'FetchMechanic', k9_prop_attachment = 'PropAttachments', k9_kennel = 'DeployableKennel',
            k9_open_inventory = 'K9Inventory', k9_treat_nearest = 'K9Medkit',
        }
        local dogWithoutAccess = amDog and type(HasK9AccessCached) == 'function' and HasK9AccessCached() == false
        local baseHide = hide
        hide = setmetatable({}, { __index = function(_, id)
            if baseHide[id] then return true end
            if dogWithoutAccess and DOG_ONLY[id] then return true end
            local feature = FEATURE_OF_ITEM[id]
            if feature and type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked(feature) then return true end
            return nil
        end })
        local function keep(list)
            local out = {}
            for _, item in ipairs(list) do
                local running = STILL_RUNNING[item.id]
                if not hide[item.id] or (running and running()) then out[#out + 1] = item end
            end
            return out
        end
        k9SubmenuItems = keep(k9SubmenuItems)
        k9UtilitySubmenuItems = keep(k9UtilitySubmenuItems)
        lib.registerRadial({ id = 'k9unit_utility', items = k9UtilitySubmenuItems })
        lastBuiltRoleIsDog = amDog
    end

    local K9_SUBMENU_GROUPS = {
        { menuId = 'k9unit_handler', openerId = 'k9_group_handler', label = locale('radial.group_handler_label'), icon = 'people-arrows', members = { 'k9_leash', 'k9_vehicle', 'k9_partner' } },
        { menuId = 'k9unit_combat', openerId = 'k9_group_combat', label = locale('radial.group_combat_label'), icon = 'hand-fist', members = { 'k9_bite_hold', 'k9_takedown', 'k9_drag' } },
        { menuId = 'k9unit_senses', openerId = 'k9_group_senses', label = locale('radial.group_senses_label'), icon = 'eye', members = { 'k9_track_certified', 'k9_scent_vision', 'k9_thermal_vision', 'k9_night_vision', 'k9_vision_cycle' } },
    }
    -- Moved into the existing Utility sub-menu rather than a group of their own.
    local MOVE_TO_UTILITY = { k9_fetch = true, k9_kennel = true }
    do
        local byId = {}
        for _, item in ipairs(k9SubmenuItems) do byId[item.id] = item end

        local grouped = {}
        for _, group in ipairs(K9_SUBMENU_GROUPS) do
            local members = {}
            for _, id in ipairs(group.members) do
                if byId[id] then members[#members + 1] = byId[id] end
            end
            group.present = members
            if #members >= 2 then
                for _, item in ipairs(members) do grouped[item.id] = group end
            end
        end

        local movedToUtility = false
        local top, openerPlaced = {}, {}
        for _, item in ipairs(k9SubmenuItems) do
            local group = grouped[item.id]
            if group then
                if not openerPlaced[group.menuId] then
                    openerPlaced[group.menuId] = true
                    lib.registerRadial({ id = group.menuId, items = group.present })
                    top[#top + 1] = { id = group.openerId, label = group.label, icon = group.icon, menu = group.menuId }
                end
            elseif MOVE_TO_UTILITY[item.id] and byId.k9_utility then
                k9UtilitySubmenuItems[#k9UtilitySubmenuItems + 1] = item
                movedToUtility = true
            else
                top[#top + 1] = item
            end
        end
        if movedToUtility then
            -- Re-registered with the moved items; lib.registerRadial replaces
            -- a menu by id.
            lib.registerRadial({ id = 'k9unit_utility', items = k9UtilitySubmenuItems })
        end
        -- A Utility sub-menu left with nothing in it for this player
        -- loses its button instead of opening onto an empty wheel.
        if #k9UtilitySubmenuItems == 0 then
            for i = #top, 1, -1 do
                if top[i].id == 'k9_utility' then table.remove(top, i) end
            end
        end
        k9SubmenuItems = top
    end

    -- Per-person block on the WHOLE radial surface -- see this function's
    -- own "K9 UNIT RADIAL -- PER-PERSON BLOCK" header above.
    if Config.Features.RadialMenu then
        local radialMenuBlocked = IsRadialFeatureBlockedForMe('RadialMenu')
        -- TOP-LEVEL ICON ACCESS GATE -- see this function's own header
        -- above ("TOP-LEVEL ICON ACCESS GATE") for the full three-part
        -- writeup. Only consulted when NOT already blocked -- a
        -- featureblocks block is an operator decision that takes priority
        -- over this client's own department/access/engagement state, and
        -- keeps its own distinct message (DenyK9FeatureBlocked) rather
        -- than being folded into this one.
        local iconReachable = radialMenuBlocked or ShouldShowK9RadialIcon()

        -- The 'k9unit' submenu contents are only worth registering when
        -- reachable AT ALL -- an orphaned-but-populated submenu while
        -- blocked is harmless (same disclosed nuance the GLOBAL
        -- RadialMenu=false path already has -- nothing links to it).
        --
        -- DELIBERATELY NOT re-gated on `iconReachable` (the access/
        -- department/engagement answer) THE SAME WAY -- unlike the
        -- `radialMenuBlocked` check above, `iconReachable` can flip back
        -- and forth freely within a single session (the periodic refresh
        -- thread re-evaluates it on a timer, precisely so it CAN), and
        -- ox_lib's own `lib.registerRadial` has no verified removal
        -- capability (see the ROOT OPENER comment just below for the full,
        -- previously-verified citation) -- skipping this registration
        -- while temporarily unreachable would not un-register a submenu
        -- registered during an EARLIER, reachable pass; it would only
        -- leave that earlier pass's contents stale (never rebuilt with
        -- fresh onSelect closures) the next time this client becomes
        -- reachable again, for zero actual removal benefit in exchange.
        -- Registering it every time `not radialMenuBlocked`, exactly like
        -- before this pass, keeps its contents always fresh and is
        -- provably harmless either way: with the opener's own `menu` field
        -- cleared (see below), literally nothing ever navigates here.
        if not radialMenuBlocked then
            lib.registerRadial({
                id = 'k9unit',
                items = k9SubmenuItems,
            })
        end

        -- The ROOT OPENER, unlike the submenu above, is ALWAYS
        -- (re-)registered, every single time -- REPLACED in place, never
        -- removed. THIS IS DELIBERATE, not the "icon simply disappears"
        -- ideal this header's own design writeup would otherwise prefer:
        -- ox_lib's real, VERIFIED (see "DUPLICATE-VS-REPLACE" above)
        -- capability is REGISTER/REPLACE-by-id for `lib.addRadialItem` --
        -- there is no correspondingly VERIFIED removal call this codebase
        -- has confirmed against ox_lib's own source (a prior draft of this
        -- file's header floated `lib.removeRadialItem` as a hypothetical
        -- OPTION, never confirmed real -- see that history; this pass
        -- tried to reach native-api-assistant to settle it for real before
        -- committing to this compromise again and could not get a live
        -- answer this session, so the same disclosed, previously-verified
        -- compromise is kept rather than guessing), and this resource's
        -- own established discipline is to never call an unverified
        -- native/API function on an assumption. So: BLOCKED and
        -- no-access/no-department/no-ongoing-engagement BOTH swap the SAME
        -- id's `onSelect`/`menu` fields (still a REPLACE, still fully
        -- within the verified contract) to a stub that explains why,
        -- rather than navigating anywhere -- the icon stays visible, but
        -- is honest and inert, never silently doing nothing. If
        -- `lib.removeRadialItem` is ever confirmed real (ask
        -- native-api-assistant), this is the one spot to revisit for the
        -- fully-honest "icon vanishes" behavior this design would prefer,
        -- for BOTH the blocked and no-access cases.
        if radialMenuBlocked then
            lib.addRadialItem({
                {
                    id = 'k9unit_open',
                    label = locale('radial.menu_open_label'),
                    icon = 'dog',
                    onSelect = function()
                        if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
                    end,
                },
            })
        elseif not iconReachable then
            -- No department, no K9 access, and no ongoing engagement this
            -- client could need to end -- see this function's own header
            -- for the full gate this implements. Reuses DenyK9UIAccess()'s
            -- own 'common.no_k9_role_or_access' reason (ease-of-use audit,
            -- this pass): this is precisely the aggregate condition that
            -- string describes (not currently an on-duty, access-granted K9
            -- handler, and not mid-engagement) -- more specific than the
            -- bare fallback, and never factually wrong for this case.
            --
            -- NOW VERIFIED against ox_lib's own source
            -- (resource/interface/client/radial.lua): `lib.removeRadialItem(id)`
            -- is real -- it removes the item by id, does nothing if it is not
            -- there, and a later `lib.addRadialItem` puts it back. So a
            -- civilian or an officer with nothing to do with K9 no longer
            -- carries a dead "K9 Unit" button in their radial; the periodic
            -- refresh below re-adds it the moment they gain department /
            -- access. An ox_lib too old to have the function keeps the
            -- honest inert stub, exactly as before.
            if type(lib.removeRadialItem) == 'function' then
                lib.removeRadialItem('k9unit_open')
            else
                lib.addRadialItem({
                    {
                        id = 'k9unit_open',
                        label = locale('radial.menu_open_label'),
                        icon = 'dog',
                        onSelect = function()
                            if type(DenyK9UIAccess) == 'function' then DenyK9UIAccess('common.no_k9_role_or_access') end
                        end,
                    },
                })
            end
        else
            lib.addRadialItem({
                {
                    id = 'k9unit_open',
                    -- '${common.notify_title}' — ox_lib's own cross-reference
                    -- syntax (resolved once at lib.locale() load time), not a
                    -- coincidence: this opener's label and every lib.notify title
                    -- in this resource are the same "K9 Unit" string, so this
                    -- embeds that existing key rather than minting a byte-identical
                    -- duplicate under a different name (see DEVELOPER_REFERENCE.md).
                    label = locale('radial.menu_open_label'),
                    icon = 'dog',
                    menu = 'k9unit',
                },
            })
        end
    end
end

-- First call site for RegisterK9RadialMenu() -- this resource's own start,
-- or ox_lib's, same two-branch `onResourceStart` idiom as
-- client/movement.lua's RegisterLeashOxTargetOption() /
-- RegisterDoorInteractionOxTargetOptions(),
-- client/fetch.lua's RegisterFetchOxTargetOptions(), client/medkit.lua's and
-- client/wellbeing.lua's own matching dispatchers, and client/search.lua's --
-- all fixing the identical bug class against ox_target's own file-local
-- registries. Pointed at 'ox_lib' here instead of 'ox_target' since it's
-- ox_lib's `menus`/`menuItems` tables this file's own registrations live
-- inside -- see RegisterK9RadialMenu()'s own header comment above for the
-- full writeup of why that restart silently wipes this resource's entire
-- radial menu with no error, and why this dispatcher is the fix.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == 'ox_lib' then
        RegisterK9RadialMenu()
    end
end)

-- SECOND call site (client/featureblocks.lua -- see this function's own "K9
-- UNIT RADIAL -- PER-PERSON BLOCK" header above for the full contract). A
-- purely LOCAL event (client/featureblocks.lua's own TriggerEvent, never a
-- server round trip from here) fired every time this client processes a
-- fresh block-state sync -- re-running RegisterK9RadialMenu() here is what
-- makes a live RadialMenu/AdvancedBarkRadial block/unblock take effect
-- without waiting for either this resource or ox_lib to restart. Safe to
-- call this often (a rare event in practice -- join, reconnect, or a
-- high-command block action) because every registration inside
-- RegisterK9RadialMenu() REPLACES the previous one in place rather than
-- duplicating it -- see that function's own "DUPLICATE-VS-REPLACE" note.
AddEventHandler('john-k9:client:featureBlocksApplied', function()
    RegisterK9RadialMenu()
end)

-- LEASH STATE CHANGED -- the missing half of a contract client/movement.lua
-- has been holding up on its own. That file fires a purely LOCAL
-- 'john-k9:client:leashStateChanged' every time leashState flips, for
-- exactly one reason: so this file re-runs RegisterK9RadialMenu() and the
-- Attach/Detach Leash item re-evaluates IsLeashed() right then.
--
-- Until now no such listener existed here. Both that item's own comment and
-- client/movement.lua's comment CLAIMED the pairing was in place, and both
-- were wrong -- the menu was in fact only ever rebuilt by 'onResourceStart'
-- and 'john-k9:client:featureBlocksApplied' above. The practical effect:
-- a player who got leashed on a server booted with LeashMechanics off saw
-- no Detach item until something unrelated happened to rebuild the menu,
-- and had to discover the walk-away safety valve by accident instead.
--
-- Same "safe to call often" reasoning as the handler directly above: every
-- registration inside RegisterK9RadialMenu() REPLACES the previous one in
-- place rather than duplicating it, and a leash attach/detach is a rare
-- event, not a per-tick one.
AddEventHandler('john-k9:client:leashStateChanged', function()
    RegisterK9RadialMenu()
end)

-- PERIODIC ICON REFRESH -- see RegisterK9RadialMenu()'s own "TOP-LEVEL
-- ICON ACCESS GATE" header, point 3, for why this exists: unlike
-- department membership (QBX.PlayerData, live-updated for free) or the
-- leash/featureblocks state changes already covered by their own
-- dedicated local events immediately above, nothing in this resource
-- fires a client event when a handler is certified, decertified, or
-- granted/revoked K9 access mid-session. Re-running RegisterK9RadialMenu()
-- on a plain timer is the only way this client's own icon visibility ever
-- catches up to that without waiting for this resource (or ox_lib) to
-- restart, or for this player to reconnect.
--
-- 15s is generous -- this is a COSMETIC surface (one icon's presence),
-- never a security boundary or a time-critical prompt (every real action
-- behind it is independently, server-side gated regardless of what this
-- icon currently shows), so the largest interval that still feels
-- reasonably prompt to a freshly-certified handler wins over anything
-- tighter -- matches this codebase's own "no thread spinning faster than
-- the feature's real responsiveness need" standard.
--
-- Gated on Config.Features.RadialMenu at file-load time (same static read
-- every other top-level `if Config.Features.X then` in this file uses):
-- when that flag is off globally, no icon exists for anyone, on any
-- account, to reveal -- a thread that exists purely to reveal one would do
-- nothing every 15s but call a function that itself returns immediately
-- (RegisterK9RadialMenu()'s own outer `if Config.Features.RadialMenu
-- then` guard), forever, for the lifetime of every single connected
-- player's session. Not started at all in that case, rather than started
-- and left to idle.
if Config.Features.RadialMenu then
    local K9_RADIAL_ICON_REFRESH_INTERVAL_MS = 15000
    CreateThread(function()
        while true do
            Wait(K9_RADIAL_ICON_REFRESH_INTERVAL_MS)
            RegisterK9RadialMenu()
        end
    end)

    -- ONE MENU PER PLAYER: rebuild as soon as you switch between dog and
    -- human (a chief assigning or reverting the K9 look), instead of
    -- showing the old character's buttons for up to 15 seconds.
    local ROLE_CHECK_INTERVAL_MS = 1000
    CreateThread(function()
        while true do
            Wait(ROLE_CHECK_INTERVAL_MS)
            local amDog = type(IsOwnModelK9) == 'function' and IsOwnModelK9() or false
            if lastBuiltRoleIsDog ~= nil and amDog ~= lastBuiltRoleIsDog then
                RegisterK9RadialMenu()
            end
        end
    end)
end
