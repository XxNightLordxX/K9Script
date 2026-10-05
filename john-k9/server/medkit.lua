--[[
    john-k9/server/medkit.lua

    Phase 4 implementation (coder-backend). Owns Config.Features.K9Medkit
    (DEVELOPER_REFERENCE.md §13.4.4): the `john-k9:server:useK9Medkit` callback —
    server-authoritative "use a medkit item on a nearby K9-model player"
    action. New, small file pair with client/medkit.lua, per DEVELOPER_REFERENCE.md
    §13.3's file plan ("real ox_inventory capability grant deserves the
    certification-file's level of scrutiny" — same reasoning
    server/search.lua's own header already gives for its trust-model split).

    SECURITY MODEL DELIBERATELY MIRRORS server/search.lua's already-reviewed
    pattern, per this task's explicit direction to reuse it as the template:
    proximity-before-mutation, target re-verification server-side (never
    trust a client-claimed entity/model — the target's REAL ped model is
    re-derived here via IsConfiguredK9Model, and the target must resolve to
    a currently-connected player, never an NPC), server-authoritative item
    consumption (the item is checked AND removed from the USING player's
    real ox_inventory server-side before any health change is applied — a
    client-reported "I used it" is never sufficient), and a TOCTOU-safe
    cooldown stamped BEFORE the mutating work, using server/cooldowns.lua's
    shared NewCooldown/NewMutex constructors (never a hand-rolled table,
    per DEVELOPER_REFERENCE.md item 1's established convention).

    ======================================================================
    OX_INVENTORY EXPORT SIGNATURES — CONFIRMED AGAINST THE REAL SOURCE THIS
    SESSION (github.com/overextended/ox_inventory @ main, fetched and read
    directly, not remembered/guessed — same methodology
    DEVELOPER_REFERENCE.md#contraband-search already used to confirm
    GetInventoryItems/GetContainerFromSlot for server/search.lua):
        exports.ox_inventory:GetItemCount(inv, itemName, metadata?, strict?) -> number
            (modules/inventory/server.lua, Inventory.GetItemCount, exported
            verbatim as 'GetItemCount')
        exports.ox_inventory:RemoveItem(inv, item, count, metadata?, slot?, ignoreTotal?, strict?) -> boolean success, string? response
            (modules/inventory/server.lua, Inventory.RemoveItem, exported
            verbatim as 'RemoveItem')
    Both resolve `inv` through ox_inventory's own internal `Inventory(inv)`
    helper, which accepts a connected player's own numeric server id
    directly — confirmed in the same source read, and exactly the same fact
    server/search.lua's own HandleSearchTarget already relies on for
    person-type searches ("a connected player's own inventory is keyed by
    their live numeric server id, already loaded while they're online — no
    lazy-load dance needed"). CONFIDENCE: HIGH — read directly from real
    ox_inventory source this session, not assumed from memory. Neither call
    yields/awaits internally (confirmed by reading both function bodies —
    no `.await`/`lib.callback.await` inside either), so unlike
    server/search.lua's `GetInventoryItems` (which CAN yield on an uncached
    vehicle trunk's lazy DB load), there is no genuine TOCTOU window
    between this file's cooldown/possession checks and its mutations — the
    cooldown is still stamped before the item is removed, purely to match
    this codebase's established discipline and to stay correct if a future
    ox_inventory version ever makes one of these calls yield.

    DELIBERATE DESIGN CHOICE — resolves DEVELOPER_REFERENCE.md §13.4.4 open
    question 2 (exact ox_inventory useable-item registration API) BY
    SIDESTEPPING IT rather than guessing at data/items.lua's
    client.export/server.export shape or the explicitly-`@deprecated`
    `Item(name, cb)` callback (confirmed deprecated in the real source read
    above — its own doc comment says "Use the 'ox_inventory:usedItem' event
    or the 'usingItem'/'buyItem' hooks" instead): this implementation does
    NOT register `k9_medkit` as a hotbar/UI "useable" item at all. It is a
    plain carried item, checked and consumed directly via the two confirmed
    exports above, triggered by an ox_target world interaction on the
    target K9 — the same "ox_target -> lib.callback -> server validates ->
    mutates state" shape already used everywhere else in this resource
    (leash, vehicle load/release, search), not ox_inventory's separate
    hotbar-use flow. This is a real implementation decision, not a
    workaround: it is MORE auditable than the hotbar-use event, since
    reading ox_inventory's real client flow this session confirmed that
    'ox_inventory:usedItem' fires with only (inventoryId, itemName, slot,
    metadata) — no interaction-target concept at all, so it could not carry
    "which K9 to heal" even if this file hooked it — and it needs no new
    data/items.lua wiring beyond a plain, non-special item definition.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4, K9Medkit only.

    Callbacks (ox_lib lib.callback):
    1. 'john-k9:server:useK9Medkit' (targetServerId: number)
       -> { ok: boolean, reason: string? }
       [THIS FILE] client/medkit.lua's "Treat K9" ox_target option.
       `targetServerId` is the K9 PLAYER's own server id (NOT a netId or
       entity handle) — client/medkit.lua resolves this via the standard,
       client-reliable NetworkGetPlayerIndexFromPed/GetPlayerServerId
       combo. That combo is safe CLIENT-side; server/search.lua's own
       header already flags that SAME combo as unverified SERVER-side,
       which is exactly why this file never calls it — it only ever calls
       GetPlayerPed(targetServerId) server-side, the same already-proven-
       server-reliable native server/search.lua's own
       ResolveConnectedPlayerFromPed already depends on.

    Server events (RegisterNetEvent, client->server): none — this feature
    is entirely request/response shaped, same posture as
    server/search.lua's searchTarget (there is no legitimate reason for a
    fire-and-forget "I healed my K9" event to exist).

    Client events (RegisterNetEvent, server->client):
    2. 'john-k9:client:applyMedkitHeal' (newHealth: number)
       [client/medkit.lua, TARGET K9 ONLY] — per DEVELOPER_REFERENCE.md §13.4.4's
       own open question 1: `SetEntityHealth`'s reliability when called
       server-side against a REMOTE-OWNED networked ped was not
       independently verified this session either way, so this file takes
       the spec's explicitly recommended, lower-risk path — the TARGET's
       OWN client self-applies the already-clamped ABSOLUTE health value
       this file computes from a live `GetEntityHealth`/`GetEntityMaxHealth`
       READ (reads are not the flagged uncertainty — only the cross-owner
       WRITE native is), mirroring every other "client self-applies to its
       own entity" pattern already established in this codebase (movement-
       rate modifiers, sprint/jump input blocks, DEVELOPER_REFERENCE.md §13.0
       Decision 3). The server still decides the real restored amount; the
       client only ever writes the exact number the server already computed
       and clamped — it cannot inflate or ignore the restore amount to gain
       anything, and never receives a raw "add N" delta it could reapply
       repeatedly.

    Commands: none. Automatic path: none.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Does NOT call `HasK9Access` — eligibility to USE a medkit ON a K9 is
      job-only (Config.Departments or Config.K9Medkit.emsJobs, or the
      optional override hook), deliberately NOT gated on the USING player's
      own K9 certification: treating a K9 is not itself a K9-handling
      action (an EMS medic with zero K9 certification is exactly the
      intended default use case per Config.K9Medkit.emsJobs). See
      IsMedkitUserAuthorized's own doc comment below.
    - Calls `IsConfiguredK9Model(modelHash)`, resource-global from
      server/certifications/ — reused, never re-derived, to verify the
      TARGET really is a configured K9 model server-side.
    - Owns `MedkitCooldown` and `MedkitMutex` below as file-local state,
      each a server/cooldowns.lua tracker instance (NewCooldown/NewMutex)
      — DEVELOPER_REFERENCE.md item 1's convention, no hand-rolled table.
    - Calls `GetXPTierMedkitCooldownMs(citizenid, baseCooldownMs)`,
      resource-global from server/progression.lua, ONLY IF THAT FUNCTION
      EXISTS (`type(...) == 'function'` guard, this resource's own
      soft-dependency convention) — resolves the
      Veteran-tier `medkitCooldownMultiplier` unlock (config.lua's own
      Config.XPTiers row) into the actual threshold RunUseK9MedkitMutation's
      own `MedkitCooldown.IsOnCooldown` call below is checked against,
      keyed on the TARGET's own citizenid (the K9 being healed), never the
      USING player's — see that call site's own comment for why. Falls back
      to `ResolveMedkitBaseCooldownMs()` (Config.K9Medkit.cooldownMs,
      VALIDATED FRESH on every call via ResolveConfiguredThresholdMs — see
      that function's own doc comment for the footgun this closes and why
      it must never be cached) when server/progression.lua hasn't defined
      the accessor, so this file works identically whether or
      not XPProgression is enabled.
      GAP CLOSED (this pass, coder-backend, no line in THIS file needed to
      change): server/k9profiles.lua's per-INDIVIDUAL-K9 override on
      `medkitCooldownMultiplier` now reaches this exact call TRANSITIVELY —
      `GetXPTierMedkitCooldownMs` (server/progression.lua, not owned by this
      pass) was updated to consult `GetK9EffectiveMultipliers(citizenid)`
      (GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE) instead of reading
      `GetXPTier(citizenid).medkitCooldownMultiplier` raw, so this file's own
      already-correct call site above picks up the composed value with no
      change of its own required. Traced end to end, not merely inferred:
      see tests/medkit_spec.lua's "GAP CLOSURE" section, which loads the
      REAL server/datastore.lua + server/progression.lua +
      server/k9profiles.lua alongside this file and proves a live
      k9ProfileUpsert override changes what MedkitCooldown.IsOnCooldown
      actually enforces.
    - Exposes NO resource-global functions of its own.

    ======================================================================
    CORRECTNESS PASS (coder-backend, this session) — three findings, all
    fixed below. Evidence and reasoning kept here rather than only in a
    commit message, per this file's own established documentation style.

    1. MAX-HEALTH AGREEMENT BETWEEN THE SERVER'S CLAMP AND THE CLIENT'S
       CLAMP — QA raised, this pass resolves it WITH EVIDENCE, not
       assumption:
       Grepped this entire resource for every native capable of changing a
       ped's REAL max-health ceiling (`SetPedMaxHealth`/`SET_PED_MAX_HEALTH`,
       any `SetEntityMaxHealth`-shaped call, any local assignment to a
       `maxHealth`/`healthMax` variable that is later written back to the
       entity rather than just read) — zero matches anywhere in this
       resource outside the two read-only `GetEntityMaxHealth` call sites
       already known (this file, and client/hud.lua's own read-only HUD
       normalization). server/wellbeing.lua's Injury stat — the "injury/
       wellbeing subsystem" the open question named was, while it existed,
       an entirely separate virtual per-citizenid float that never touched
       the ped's actual native health/max-health fields at all. So: nothing in this
       codebase ever modifies a K9 ped's real max health, meaning the
       server's `GetEntityMaxHealth(targetPed)` read (HandleUseK9Medkit,
       "compute" step) and the target's own client's later
       `GetEntityMaxHealth(ped)` read (client/medkit.lua's
       applyMedkitHeal) are two live reads of the SAME never-modified
       native value on the SAME entity — they cannot disagree from
       anything this resource does.
       That said, this file does not rely on "cannot disagree" as a excuse
       to skip a safety net for the one thing actually outside this
       resource's control: a THIRD-PARTY resource changing max health, or
       the target ped itself being swapped/respawned, in the network-latency
       gap between the server's compute-time read and the client's
       apply-time read. The client's own independent `GetEntityMaxHealth`
       clamp (client/medkit.lua, pre-existing, kept as-is) already covers
       this correctly by construction: it clamps the SERVER's number down to
       whatever the client's OWN live ceiling is at apply time, so any
       cross-owner drift can only ever produce a safe under-heal (capped to
       the lower of the two ceilings), never an overheal above the
       currently-live maximum. No code change was needed here — this is a
       documented resolution, not a fix.

    2. DEAD-K9 GATE (NEW, fixed below) — nothing previously stopped healing
       a K9 whose ped is already dead. This resource already has an
       established, reused answer for "should this interaction be usable on
       a dead target" — server/combat.lua's `ValidateCombatRequest`
       rejects a dead target by default via `IsEntityDead(targetPed)` with
       reason `'target_dead'`, and its own header explains why: a scripted
       laststand/EMS "dead" state is a DIFFERENT thing from a raw
       `SetEntityHealth` bump, and reviving a player is the job of that
       real laststand/EMS flow, never a side effect of an unrelated item.
       A K9 medkit is documented everywhere in this file as restoring an
       INJURED (alive) K9's health — it was never meant to be a revive
       item, and letting it push a dead K9's raw health back up via the
       exact same client-self-applied `SetEntityHealth` this file already
       flags as cross-owner-uncertain would let a plain consumable silently
       stand in for whatever this server's real ambulance/laststand system
       is supposed to gate revival behind, with none of that system's own
       rules (cooldowns, animations, item costs it may impose, etc.)
       applying. HandleUseK9Medkit now rejects with `'target_dead'` the
       same way ValidateCombatRequest already does, checked immediately
       after the model re-verification (cheap, non-mutating, so it runs
       before the mutex/cooldown/item-possession work below, same
       "cheapest checks first" discipline this file's function doc comment
       already establishes). client/medkit.lua's `applyMedkitHeal` also
       gained a matching `IsEntityDead` guard for the one case the
       server-side gate cannot see: the K9 dying from unrelated damage in
       the network-latency window between the server's decision and the
       client actually receiving and applying it — without that guard, a
       heal computed while the K9 was alive could still land as a
       de-facto revive a moment after they died. Both gates fail the SAME
       direction (reject/no-op), never the opposite.

       ADDENDUM (native-sweep follow-up pass, coder-backend): the
       server-side half of this finding, as originally written, DID NOT
       ACTUALLY WORK — `IsEntityDead` has no FXServer server implementation
       (see PED_DEAD_HEALTH_THRESHOLD's own doc comment below for the
       primary-source finding) and always returned `false` server-side, so
       HandleUseK9Medkit's reject below never fired regardless of the
       target's real state. server/combat.lua's `ValidateCombatRequest`,
       named above as the "established, reused answer" this gate was
       modeled on, had the identical bug at the same time. Both are now
       fixed to use `GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD`
       instead — see this file's own doc comment on `PED_DEAD_HEALTH_THRESHOLD`
       below for the full writeup. client/medkit.lua's client-side
       `applyMedkitHeal` guard (mentioned above) is UNAFFECTED by any of
       this: `IsEntityDead` is confirmed client-callable (only its
       server-side registration is missing), so that guard was, and
       remains, real.

    3. MUTEX RELEASE UNDER AN UNCAUGHT ERROR (NEW, fixed below) — the
       previous shape released `MedkitMutex` only via the `finish(result)`
       wrapper, meaning every one of THIS function's own `return` statements
       released it correctly, but a hypothetical uncaught Lua error thrown
       by any native call inside the mutex-held region (never observed, but
       structurally possible if a future edit adds one) would propagate
       straight past every `return finish(...)` site to the OUTER
       `lib.callback.register` pcall without ever calling `Release` —
       permanently locking that one citizenid out of ever being treated
       again for the lifetime of the resource (a genuine unbounded trap: no
       sweep/TTL touches a mutex entry, by design, per server/cooldowns.lua's
       own NewMutex doc comment — "a mutex is acquire/release, not a
       cooldown pretending to have no expiry"). Fixed by moving the entire
       mutex-held mutation body into its own function and wrapping ONLY that
       call in a `pcall` whose very next line unconditionally releases the
       mutex, so release is no longer contingent on every internal return
       path being enumerated correctly — see RunUseK9MedkitMutation below.

    4. ITEM CONSUMPTION ORDERING (NEW, fixed below) — found by
       tests/medkit_spec.lua and independently confirmed by reading this
       function directly: the previous shape stamped the target's cooldown
       (then step 4) and called RemoveItem (then step 5) BEFORE computing
       the heal via GetEntityHealth/GetEntityMaxHealth (then step 6). Any
       failure in that read — a thrown error from either native, or any
       future code added at that point — ran strictly AFTER the item had
       already been removed and the cooldown already stamped, so the using
       player lost their medkit, the target's cooldown was burned, and no
       heal was ever applied, while the caller was told `medkit_failed`.
       Neither of those two mutations is reversible after the fact (there
       is no "give the item back" call, and rolling the cooldown stamp back
       would itself be a race against a second concurrent attempt), so the
       only correct fix is ordering, not a try/rollback: compute and
       validate the heal FIRST, then treat `RemoveItem` as the actual point
       of no return, and only stamp the cooldown / push the heal AFTER
       `RemoveItem` has confirmed success. RunUseK9MedkitMutation below now
       runs, in order: possession check -> compute+clamp the heal (can
       still fail; nothing consumed or stamped yet) -> RemoveItem (the
       real mutation; failure here is reported as `no_item` with nothing
       stamped) -> cooldown stamp -> TriggerClientEvent, with the two
       trailing notify calls now pcall-wrapped so a throw in either can
       never turn an already-committed heal into a reported failure.

       COOLDOWN DECISION: the cooldown stamp moved from "before RemoveItem"
       to "after RemoveItem succeeds" — i.e. the target's cooldown is now
       burned if and only if a medkit was actually consumed. The old
       "stamp before the mutating call" convention (mirrored from
       server/search.lua) exists to close a TOCTOU race between two
       concurrent requests racing past a check before either has mutated
       anything; that race is already closed here independently, by
       MedkitMutex serializing concurrent requests against the same target
       citizenid (see finding 3 and MedkitMutex's own comment below) and by
       neither ox_inventory call yielding (see OX_INVENTORY EXPORT
       SIGNATURES above) — so this handler never actually has two
       concurrent in-flight mutations against the same target to race
       between in the first place. With that race already closed by other
       means, stamping the cooldown before a mutation that might still
       legitimately fail (RemoveItem returning `false`) bought nothing but
       a real unfairness: a target blocked for the target's FULL cooldown
       window because someone else's attempt errored or desynced, for a
       heal that never happened. Stamping only on confirmed success removes
       that unfairness without reopening the double-heal race it used to
       guard against.

       RESIDUAL WINDOW (disclosed, not claimed away): once `RemoveItem`
       returns `true`, the item IS gone. The very next statement pushes
       `john-k9:client:applyMedkitHeal` to the target's own client with
       nothing fallible in between (no yield, no native call that can
       throw sits between them), so there is no synchronous window in
       which this SERVER script can still fail after that point. What
       cannot be closed from here: this is a fire-and-forget network event
       to a REMOTE client, not a transaction — the target's own client
       could still fail to receive or apply it (already-observed edges:
       the packet is simply lost, or the target dies from unrelated damage
       in the network-latency gap and its own `IsEntityDead` guard in
       client/medkit.lua's `applyMedkitHeal` correctly no-ops the heal — see
       finding 2's addendum). There is no shared transaction between
       ox_inventory (this server) and a networked ped's health (that
       client), and there cannot be one without a fundamentally different,
       server-authoritative-write design this task does not ask for — so
       this window is real, is not claimed to be zero, and is kept as
       small as ordering alone can make it rather than pretended away.

    5. COMPAT-LAYER MIGRATION + STUB-DEGRADE ANALYSIS (coder-backend, this
       pass) — `GetItemCount`/`RemoveItem` above are now routed through
       `K9Compat.Get('inventory')` (shared/compat/core.lua's
       RequiredMethods.inventory.server), never a direct
       `exports.ox_inventory:...` call. ox_inventory is a hard
       fxmanifest.lua dependency today, so this file's item-consumption path
       has never had to survive it being absent or swapped — routed through
       the compat layer, it now can be, so the actual question this task
       asks: what happens on the no-op stub? `GetItemCount` fails closed to
       `0` (documented adapter behavior, both confirmed backends) — the
       possession check above already treats `0` identically to "genuinely
       doesn't have one," so an undetected inventory reads as `no_item`,
       never a crash or a silent success. `RemoveItem` fails closed to
       `false` — reached only if `GetItemCount` somehow returned >= 1 while
       the inventory was actually unusable (should not happen in practice:
       both are the SAME adapter instance for the SAME backend within one
       call), and if it ever did, this function's own existing "should not
       happen" branch (immediately below RemoveItem's call site) already
       returns `no_item` with nothing stamped/consumed — the same reason
       string this file already used before this pass for an unexpected
       ox_inventory failure. Both outcomes are indistinguishable, from the
       caller's perspective, from "you don't have a medkit" — a clean,
       disclosed "feature switched off" degrade (a player-facing `no_item`
       notify via client/medkit.lua's existing reason handling), never a
       hang or an uncaught error. On qb-inventory specifically (the other
       CONFIRMED backend), both methods are REAL (composed onto
       `GetItemCount`/`RemoveItem` exports, per shared/compat/inventory.lua's
       own qb-inventory section) with no disclosed semantic gap for this
       file's usage (a plain possession check and a plain single-item
       removal — neither depends on any of that adapter's documented
       qb-inventory limitations, e.g. no container concept, no groups ACL).
    ======================================================================
]]

-- Precomputed set of configured EMS job names, built once at file load —
-- same "O(1) membership test, built once" convention
-- server/search.lua's ContrabandItemSet already establishes.
local EmsJobSet = {}
for _, jobName in ipairs(Config.K9Medkit.emsJobs or {}) do
    EmsJobSet[jobName] = true
end

-- QUALITY FIX (this pass), REVISED after a cross-file follow-up finding
-- (server/runtimecontrol.lua's owner, reported against this file's own
-- first version of this fix — see that file's own "K9Medkit.cooldownMs" entry
-- (TUNABLE_REGISTRY, near "K9Medkit.range") for their independent trace of
-- the exact same regression -- UPDATE (issue-closer sweep, 2026-08-26): that
-- entry used to be titled "DELIBERATELY EXCLUDED" and
-- tests/runtimecontrol_spec.lua carried a matching "must never be exposed"
-- case; both have since been corrected/inverted to "is now safely exposed"
-- now that the fix described below has landed and been re-verified.
-- Config.K9Medkit.cooldownMs used to be read
-- raw, directly, at every call site below (RunUseK9MedkitMutation's
-- `effectiveCooldownMs`, and this sweep's own `staleAfterMs`) — the ONE
-- cooldown-backing config value in this file with no validation at all,
-- unlike every sibling file's identical-shaped config read
-- (server/kennel.lua's DeployCooldown, server/fetch.lua's ThrowCooldown/
-- PickupCooldown, server/propattachment.lua's ToggleCooldown's own
-- onResourceStart assert, server/partnership.lua's PartnerRequestCooldown,
-- all wrapped through this exact ResolveConfiguredThresholdMs helper or an
-- equivalent hard assert). server/cooldowns.lua's own IsOnCooldown treats a
-- non-positive threshold as PERMANENTLY on cooldown, never "no cooldown" —
-- an operator typo'ing Config.K9Medkit.cooldownMs to 0 (meaning "no
-- throttle") would instead have every SECOND medkit use against the SAME K9
-- silently rejected forever with reason 'on_cooldown' (the FIRST use per K9
-- always succeeds regardless, since `IsOnCooldown` returns `false` for a key
-- that has never been `Touch`ed at all — see that function's own doc
-- comment).
--
-- FIRST ATTEMPT, WRONG (this pass, self-corrected): resolving this ONCE, at
-- file-load, into a frozen local and reusing that local everywhere would
-- have closed the above footgun but silently reopened a DIFFERENT one —
-- both this file's own header (RunUseK9MedkitMutation's own comment) and
-- server/runtimecontrol.lua's live-tunable registry already document that
-- `Config.K9Medkit.cooldownMs` is read GENUINELY FRESH on every call by
-- design, matching Config.DoorInteraction.scratchCooldownMs's identical
-- "live, no restart required" contract (server/main.lua). A frozen local
-- would silently stop reflecting a live edit (whether via a future
-- runtime-tunable registration, or simply an operator editing config.lua
-- and the resource picking it up some other live-reload path) — worse, the
-- SWEEP's own staleAfterMs would then diverge from whatever the per-request
-- gate is ACTUALLY enforcing, which server/runtimecontrol.lua's own trace
-- shows can open a genuine bypass (a target's cooldown entry gets pruned
-- using a STALE, shorter window than the currently-configured one, letting
-- it be used again before the real, current cooldown has actually elapsed).
--
-- ACTUAL FIX: resolve the value FRESH, every time, via this tiny function —
-- never cached — so both the per-request gate and the sweep's staleAfterMs
-- always agree with each other AND with whatever Config.K9Medkit.cooldownMs
-- currently holds, while still degrading a non-positive/NaN/missing value to
-- a safe, working fallback instead of cooldowns.lua's own fail-closed
-- "permanently on" behavior. `ResolveConfiguredThresholdMs` is a cheap,
-- non-yielding, plain numeric check — safe to call on every request and
-- every sweep tick, not just once. Fallback matches config.lua's own
-- shipped default (60000ms).
local MEDKIT_COOLDOWN_FALLBACK_MS = 60000
local function ResolveMedkitBaseCooldownMs()
    return ResolveConfiguredThresholdMs(
        Config.K9Medkit.cooldownMs, MEDKIT_COOLDOWN_FALLBACK_MS, 'Config.K9Medkit.cooldownMs')
end

-- Per-target (K9 citizenid) cooldown backing Config.K9Medkit.cooldownMs —
-- keyed on the TARGET'S resolved, stable citizenid (never the raw,
-- recyclable/spoofable-adjacent client-supplied targetServerId), same
-- "resolved identity, not a raw session id" discipline
-- server/search.lua's TargetSearchCooldown already established for its
-- own per-target cooldown. Outlives any single connection (a K9 that
-- disconnects and reconnects should not get a free early re-heal), so it
-- needs its own independent TTL sweep rather than playerDropped-based
-- cleanup — mirrors server/search.lua's TargetSearchCooldown exactly.
local MedkitCooldown = NewCooldown()

local MEDKIT_COOLDOWN_PRUNE_INTERVAL_MS = 60000
MedkitCooldown.StartSweep(MEDKIT_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    -- Resolved FRESH on every sweep tick, exactly like RunUseK9MedkitMutation's
    -- own effectiveCooldownMs below -- see ResolveMedkitBaseCooldownMs's own
    -- doc comment for why a frozen, file-load-time value here would let this
    -- prune window silently drift out of sync with whatever cooldown is
    -- actually being enforced right now.
    local staleAfterMs = ResolveMedkitBaseCooldownMs() * 2
    return (now - loggedAt) > staleAfterMs
end)

-- ==========================================================================
-- HANDLER XP MINT COOLDOWN for handlerTreatK9 (WIRING PASS, coder-backend --
-- closes the "top handler rank unreachable" audit finding). See this file's
-- own "HANDLER XP TIER UNLOCK" comment on RunUseK9MedkitMutation below (and
-- server/progression.lua's GetHandlerXPTierMedkitCooldownMs doc comment,
-- "THE NUMBERS" section) for the full worst-case arithmetic this is sized
-- against: MedkitCooldown itself, once BOTH the target K9's own Veteran-tier
-- reduction (0.75) and a Master Handler's own reduction (0.70) stack, floors
-- at 60000 * 0.75 * 0.70 = 31500ms -- and MedkitCooldown is keyed by the
-- TARGET's citizenid, not the treating handler's, so it cannot see (let
-- alone throttle) one actor round-robining several different K9s at that
-- combined floor. This tracker is the dedicated, ACTOR-keyed mint cooldown
-- config.lua's own Config.Features.HandlerXPProgression header names as the
-- binding requirement for wiring this award at all -- entirely separate
-- from MedkitCooldown (never derived from it: MedkitCooldown is itself now
-- handler-rank-shortened, so treating it as a mint gate would let a higher
-- rank both mint AND shorten its own throttle in the same action).
--
-- WINDOW: 30 real minutes, DELIBERATELY far longer than the 31500ms
-- rank-reduced target-cooldown floor alone would suggest is "enough" -- see
-- server/progression.lua's own "BINDING REQUIREMENT" note: sizing this near
-- that floor would still let a single actor mint on the order of 1,371
-- XP/hr solo (already over a third of the whole shared 3,600 XP/hr budget
-- from ONE actor), with MedkitCooldown powerless to stop them round-robining
-- targets to sustain it. At 12 XP (Config.HandlerXP.awards.handlerTreatK9) /
-- 30 minutes = 24 XP/hr per actor, this action cannot plausibly dominate a
-- citizenid's hourly total, and round-robining targets buys nothing (this
-- tracker never looks at which K9 was treated).
--
-- FILE-LOCAL CONSTANT, NOT A CONFIG KEY -- same reasoning as every other
-- *_XP_MINT_COOLDOWN_MS in this codebase (server/certifications/'s
-- CERTIFY_XP_MINT_COOLDOWN_MS, server/search.lua's
-- COOP_SEARCH_XP_MINT_COOLDOWN_MS, and config.lua's own "THE REAL CEILING...
-- AND WHY IT IS NOT A SETTING IN THIS FILE" header): this is a security
-- floor, not an operator-tunable balance knob -- a merely-too-low
-- operator-set value would pass every existing validity check while
-- silently reopening the exact farm this exists to close. The only way to
-- weaken it is to edit this file's own source under code review.
--
-- KEYED ON THE USING PLAYER'S DURABLE CITIZENID, SURVIVES DISCONNECT/
-- RECONNECT -- deliberately NOT :RegisterPlayerDropped() (server ids are
-- recycled; a cooldown keyed by a durable citizenid that reset on reconnect
-- would not be a cooldown at all -- see server/certifications/'s
-- CertifyXpMintCooldown for the identical precedent this mirrors, including
-- its own "NOT :RegisterPlayerDropped()" reasoning). Bounded instead by its
-- own independent TTL sweep, same shape as MedkitCooldown's own sweep
-- immediately above.
local TREAT_XP_MINT_COOLDOWN_MS = 30 * 60 * 1000 -- 30 real minutes
local HandlerTreatXpMintCooldown = NewCooldown()
HandlerTreatXpMintCooldown.StartSweep(TREAT_XP_MINT_COOLDOWN_MS, function(now, loggedAt)
    return (now - loggedAt) > (TREAT_XP_MINT_COOLDOWN_MS * 2)
end)

-- Per-target (K9 citizenid) mutex — prevents two concurrent
-- 'john-k9:server:useK9Medkit' calls (e.g. two medics treating the same
-- K9 at the same instant) from both passing the possession/cooldown checks
-- before either has consumed an item, which would double-count the heal
-- for the cost of one item on a genuinely racing pair of requests. Belt-
-- and-suspenders alongside the cooldown stamp below (this handler never
-- actually yields — see this file's OX_INVENTORY EXPORT SIGNATURES note —
-- so the two calls cannot truly interleave mid-handler today, but the
-- mutex keeps this file correct if a future change, e.g. an awaited audit
-- log write, ever introduces a
-- real yield point here). Released on EVERY exit path, mirroring
-- server/search.lua's SearchMutex discipline exactly.
local MedkitMutex = NewMutex()

--- NATIVE-AVAILABILITY FIX (this pass, coder-backend, native-sweep
--- follow-up): the dead-K9 gate below (CORRECTNESS PASS finding 2 in this
--- file's own header) was written using `IsEntityDead`, which has NO
--- FXServer server implementation at all -- confirmed against the primary
--- source, not just the 404 on its `ext/native-decls` doc page. Traced
--- `citizenfx/fivem`'s own C++ native-registration list
--- (code/components/citizen-server-impl/src/state/ServerGameState_Scripting.cpp,
--- the exact file that implements every entity/ped-related native FXServer
--- DOES expose server-side): zero `RegisterNativeHandler` call for
--- `IS_ENTITY_DEAD` anywhere in it, or anywhere else in the repo (a
--- full-repo source search for the literal string `"IS_ENTITY_DEAD"`
--- returns zero matches) -- while `GET_ENTITY_HEALTH` (already used
--- elsewhere in this exact file, two lines below in
--- RunUseK9MedkitMutation) IS registered there. FXServer does not throw on
--- an unregistered native, it silently no-ops and never writes the result
--- buffer, so `IsEntityDead(targetPed)` in HandleUseK9Medkit ALWAYS
--- returned `false` -- meaning the dead-K9 gate this file's header
--- documents as "fixed below," and the CHANGELOG entry recording it as
--- closed, never actually worked: a dead K9's health could always be
--- pushed back up via this item, exactly the bug that gate was written to
--- close. Rewritten below to use `GetEntityHealth`, confirmed registered
--- and already relied on elsewhere in this file.
---
--- THRESHOLD: `PED_DEAD_HEALTH_THRESHOLD = 100`, matching
--- server/combat.lua's OWN identical fix and identical reasoning (see that
--- file's own doc comment on its own `PED_DEAD_HEALTH_THRESHOLD` constant
--- for the full writeup) -- restated briefly here since this file does not
--- share a module with combat.lua: GTA peds are conventionally declared
--- dead once health drops to (or below) 100, not 0 (the reason a ped's
--- default max health is 200, not 100 -- the bottom 100 points are the
--- "already dead" floor). Using `<= 0` here would make this check a
--- near-permanent no-op again (a K9 ped's health essentially never reaches
--- literal 0 before the engine already considers it dead at 100),
--- reproducing this exact bug while looking fixed. `<= 100` also does NOT
--- falsely reject a merely-badly-INJURED (alive) K9 -- a K9's real health
--- only drops that low when genuinely dying/dead, which is precisely the
--- case this gate exists to reject; an injured-but-alive K9 (the item's
--- actual intended target) sits well above this floor.
local PED_DEAD_HEALTH_THRESHOLD = 100

--- Server-authoritative eligibility check for the USING player: does
--- `source` hold a job allowed to use a K9 medkit? Deliberately NOT
--- HasK9Access — see this file's header FILE-TO-FILE CONTRACT note.
--- @param source number
--- @return boolean
local function IsMedkitUserAuthorized(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local job = Player and Player.PlayerData and Player.PlayerData.job
    if not job or not job.name then return false end

    if Config.Departments[job.name] or EmsJobSet[job.name] then
        return true
    end

    -- Optional forward-looking override hook (DEVELOPER_REFERENCE.md §13.4.4 open
    -- question 3) — pcall-wrapped so a misbehaving server-owner-supplied
    -- function can never crash this callback; a thrown error is treated as
    -- "not authorized", never as "authorized" (fail closed).
    if type(Config.K9Medkit.IsMedkitUserAuthorizedOverride) == 'function' then
        local ok, result = pcall(Config.K9Medkit.IsMedkitUserAuthorizedOverride, source)
        return ok and result == true
    end

    return false
end

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

--- The mutex-HELD mutation body — everything from proximity through the
--- actual heal/Injury restore. Split out from HandleUseK9Medkit purely so
--- that function can `pcall` this one call and unconditionally release
--- MedkitMutex on the very next line regardless of outcome — see this
--- file's header, CORRECTNESS PASS finding 3, for why release must not
--- depend on every internal `return` path being enumerated correctly.
---
--- Validation order — cheapest/most-defensive checks first, mutating work
--- last, same discipline server/search.lua's HandleSearchTarget already
--- establishes for this codebase's security-critical files:
---   1. MANDATORY, FIRST-CLASS live proximity check between the USING
---      player's own live position and the TARGET's own live position —
---      never a client-claimed distance.
---   2. Per-target cooldown check.
---   3. Item possession check via GetItemCount — reject if the using
---      player doesn't actually carry the configured medkit item.
---   4. Compute AND validate the clamped new health value from a live
---      GetEntityHealth/GetEntityMaxHealth read — BEFORE the item is
---      removed (CORRECTNESS PASS finding 4: this used to run AFTER
---      RemoveItem, so any failure here consumed the item and burned the
---      cooldown for a heal that was never applied). See CORRECTNESS PASS
---      finding 1 for why this read can never disagree with the target
---      client's own later read.
---   5. Remove exactly one medkit item via RemoveItem — the genuine point
---      of no return: everything fallible in the normal sense (step 4) has
---      already succeeded by this line. If RemoveItem itself unexpectedly
---      fails despite step 3's check having just passed (should not happen
---      given neither ox_inventory call yields in between, but never
---      assumed), reject WITHOUT stamping the cooldown and WITHOUT applying
---      any health change — nothing was actually consumed, so
---      nothing should be charged against the target's cooldown either.
---   6. Stamp the cooldown NOW that the item is confirmed consumed, then
---      immediately push the heal to the target's own client to
---      self-apply (see this file's header on why the client self-applies,
---      and CORRECTNESS PASS finding 4 for the residual, honestly-disclosed
---      window that remains between "item removed" and "heal actually
---      landing on the target's own client").
---   7. Notify both players — wrapped so a throw can never flip an
---      already-committed heal back to a reported failure.
--- @param usingPed number
--- @param targetPed number
--- @param source number
--- @param targetServerId number
--- @param targetCitizenid string
--- @param usingCitizenid string?
--- @param requestedAt number
--- @return table result
local function RunUseK9MedkitMutation(usingPed, targetPed, source, targetServerId, targetCitizenid, usingCitizenid, requestedAt)
    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any
    -- ox_inventory query or state mutation, unconditionally. Without this,
    -- a modified client could supply the server id of ANY connected K9
    -- player anywhere on the map and heal/consume-item against them
    -- remotely — the same "map-wide oracle" risk
    -- DEVELOPER_REFERENCE.md#contraband-search §3 step 8 flags for search, applied
    -- here to a mutation instead of a read.
    local dist = #(GetEntityCoords(usingPed) - GetEntityCoords(targetPed))
    if dist > Config.K9Medkit.range then
        return { ok = false, reason = 'too_far' }
    end

    -- XP TIER UNLOCK (server/progression.lua's GetXPTierMedkitCooldownMs):
    -- keyed on the TARGET's own citizenid, not the using player's -- the
    -- tier that shortens this cooldown is the tier of the K9 being healed,
    -- since MedkitCooldown itself is a per-TARGET cooldown (see this
    -- function's own header, "THE PER-TARGET COOLDOWN"). Soft dependency,
    -- this resource's established `type(...) == 'function'` convention
    -- falls back
    -- to the FRESHLY-resolved base cooldown (ResolveMedkitBaseCooldownMs,
    -- see that function's own doc comment for why this must be re-resolved
    -- on every call, never cached) when server/progression.lua hasn't
    -- defined the accessor.
    --
    -- CORRECTED CLAIM (this pass): this comment used to assert
    -- "GetXPTierMedkitCooldownMs's own contract never returns a
    -- non-positive number" -- reading that function's real implementation
    -- (server/progression.lua) shows this is only true when its OWN
    -- `baseCooldownMs` argument is already positive to begin with: a
    -- non-positive `baseCooldownMs` is returned UNCHANGED (that function's
    -- own early-return guard), never clamped/floored. Passing the raw,
    -- unvalidated `Config.K9Medkit.cooldownMs` in here would therefore have
    -- let a misconfigured 0/negative value flow straight through this
    -- accessor and into IsOnCooldown's own PERMANENTLY-on-cooldown fail
    -- state regardless -- see `ResolveMedkitBaseCooldownMs`'s own doc
    -- comment above for the real fix (validated fresh, on every call, via
    -- ResolveConfiguredThresholdMs) that actually makes the "never
    -- non-positive" property hold here.
    local baseCooldownMs = ResolveMedkitBaseCooldownMs()
    local effectiveCooldownMs = baseCooldownMs
    if type(GetXPTierMedkitCooldownMs) == 'function' then
        effectiveCooldownMs = GetXPTierMedkitCooldownMs(targetCitizenid, baseCooldownMs)
    end

    -- HANDLER XP TIER UNLOCK (dead-config-field pass, coder-backend):
    -- Config.HandlerXPTiers' medkitTreatCooldownMultiplier, consulted via
    -- GetHandlerXPTierMedkitCooldownMs (server/progression.lua) -- same
    -- soft-dependency shape as the K9-side call immediately above, but
    -- keyed on the USING player's own citizenid (`usingCitizenid`, the
    -- person actually performing the treat action), never the target's --
    -- this is the HANDLER's own rank reward, not the K9's. Chained ON TOP
    -- of the K9-side reduction above (effectiveCooldownMs, not
    -- baseCooldownMs, is what gets passed in) rather than replacing it, so
    -- a high-tier handler treating a high-tier K9 gets BOTH reductions at
    -- once. THIS MATTERS FOR handlerTreatK9's OWN AWARD, NOT JUST THIS
    -- COOLDOWN: this cooldown is RANK-REDUCED, down to a combined worst-case
    -- floor of 31500ms (60000ms base * 0.75 Veteran-K9 * 0.70 Master-Handler,
    -- the shipped multipliers) -- see GetHandlerXPTierMedkitCooldownMs's own
    -- doc comment (server/progression.lua, "THE NUMBERS" section) for the
    -- full arithmetic. handlerTreatK9 is now WIRED (this pass, coder-backend
    -- -- see the "HANDLER XP" block near the end of RunUseK9MedkitMutation,
    -- below), through a DEDICATED, separate, actor-keyed mint cooldown
    -- (HandlerTreatXpMintCooldown, declared alongside MedkitCooldown above,
    -- 30 real minutes) sized well below that 31500ms floor -- never derived
    -- from MedkitCooldown itself (target-keyed, and rank-shortened, which is
    -- exactly why it cannot be reused as a mint gate; see
    -- HandlerTreatXpMintCooldown's own declaration comment for the full
    -- arithmetic this closes). tests/medkit_spec.lua carries a SOURCE AUDIT
    -- test confirming that companion tracker stays present alongside the
    -- award.
    if type(GetHandlerXPTierMedkitCooldownMs) == 'function' then
        effectiveCooldownMs = GetHandlerXPTierMedkitCooldownMs(usingCitizenid, effectiveCooldownMs)
    end

    if MedkitCooldown.IsOnCooldown(targetCitizenid, effectiveCooldownMs, requestedAt) then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- Item possession check — cheap, non-mutating, run before the cooldown
    -- is stamped so a player with no medkit never burns the target's
    -- cooldown window for nothing.
    --
    -- ROUTED THROUGH K9Compat.Get('inventory') (this pass, coder-backend) --
    -- shared/compat/core.lua's RequiredMethods.inventory.server.GetItemCount
    -- -- never a direct `exports.ox_inventory:GetItemCount` call. The
    -- adapter already fails closed to `0` on any capability/call failure
    -- (see shared/compat/inventory.lua's own GetItemCount doc comment on
    -- both the ox_inventory and qb-inventory adapters), matching this file's
    -- own pre-existing `not carriedCount or carriedCount < 1` guard exactly
    -- -- no behavior change on either confirmed backend.
    local carriedCount = K9Compat.Get('inventory').GetItemCount(source, Config.K9Medkit.itemName)
    if not carriedCount or carriedCount < 1 then
        return { ok = false, reason = 'no_item' }
    end

    -- CORRECTNESS PASS finding 4 (see this file's header): compute AND
    -- validate the heal BEFORE the item is removed, not after. This used
    -- to run after RemoveItem, which meant any failure here (the reads
    -- below, or anything added here in future) consumed the caller's item
    -- and burned the target's cooldown for a heal that was never actually
    -- applied. Server-authoritative clamp: reads are not the flagged
    -- SetEntityHealth-reliability uncertainty (see this file's header) —
    -- only the WRITE, which happens on the target's OWN client below.
    local currentHealth = GetEntityHealth(targetPed)
    local maxHealth = GetEntityMaxHealth(targetPed)
    local newHealth = math.min(currentHealth + Config.K9Medkit.healthRestore, maxHealth)
    -- Never move health downward from whatever it currently is, even if a
    -- future config value were ever negative by mistake.
    newHealth = math.max(newHealth, currentHealth)

    -- RemoveItem is the genuine point of no return for this function: it is
    -- the one call here that both mutates real state AND can legitimately
    -- fail (returns `false`). Everything that can still fail in the normal
    -- sense (the health reads/clamp above) has already run and succeeded
    -- by this line — see CORRECTNESS PASS finding 4.
    --
    -- ROUTED THROUGH K9Compat.Get('inventory') (this pass, coder-backend) --
    -- shared/compat/core.lua's RequiredMethods.inventory.server.RemoveItem
    -- -- never a direct `exports.ox_inventory:RemoveItem` call. The
    -- adapter returns `false` (never a fabricated `true`) on any
    -- capability/call failure, same fail-closed contract this file already
    -- relied on.
    local removed = K9Compat.Get('inventory').RemoveItem(source, Config.K9Medkit.itemName, 1)
    if not removed then
        -- Should not happen given the possession check above (neither
        -- ox_inventory call yields, per this file's header) — never
        -- treated as "item consumed" if this ever does fail. The
        -- cooldown below is NOT stamped in this branch either — nothing
        -- was actually consumed or healed, so the target's cooldown must
        -- stay untouched (see CORRECTNESS PASS finding 4's cooldown
        -- discussion).
        return { ok = false, reason = 'no_item' }
    end

    -- Cooldown is stamped ONLY once the item has been genuinely consumed —
    -- see CORRECTNESS PASS finding 4 for why this moved from "before
    -- RemoveItem" to "after RemoveItem succeeds".
    MedkitCooldown.Touch(targetCitizenid, requestedAt)

    -- The heal push is sent on the very next line after the point of no
    -- return, with nothing fallible in between — see CORRECTNESS PASS
    -- finding 4 for the one residual, undocumented-away window that
    -- remains here regardless (there is no cross-system transaction
    -- between ox_inventory and a networked client entity).
    TriggerClientEvent('john-k9:client:applyMedkitHeal', targetServerId, newHealth)

    -- Everything below this line is best-effort and MUST NOT be able to
    -- flip the result back to ok=false — the item is gone and the heal has
    -- already been pushed, so from the caller's perspective the treat has
    -- already succeeded. The notify calls are wrapped for that reason (see
    -- CORRECTNESS PASS finding 4).

    -- HANDLER XP (WIRING PASS, coder-backend): handlerTreatK9, paid to the
    -- USING player -- never the K9 -- and ONLY for a GENUINE heal
    -- (`newHealth > currentHealth`, i.e. the target was actually below max
    -- health and something was actually restored). A treat against an
    -- already-full-health K9 still succeeds above (item consumed, cooldown
    -- stamped, `ok = true` returned unchanged) -- this gate never turns that
    -- into a failure (see this file's own "MEANINGFUL ACTION" note on
    -- RunUseK9MedkitMutation's header) -- it only decides whether the action
    -- was real K9 care worth a handler's own XP, never whether the item
    -- works. Gated on usingCitizenid resolving at all (never a rejection
    -- elsewhere in this function if it doesn't -- see the HANDLER XP TIER
    -- UNLOCK comment above) AND on HandlerTreatXpMintCooldown, the dedicated
    -- per-actor mint cooldown declared above -- never derived from
    -- MedkitCooldown (target-keyed, and itself handler-rank-shortened; see
    -- that tracker's own declaration comment for why reusing it here would
    -- reopen the exact loop this dedicated tracker exists to close).
    -- Soft dependency (`type(AwardHandlerXP) == 'function'`), same
    -- convention as GetXPTierMedkitCooldownMs above -- this
    -- file works identically whether or not server/progression.lua is
    -- loaded or Config.Features.HandlerXPProgression is on (AwardHandlerXP
    -- itself re-checks that flag and is a real no-op while it is off).
    if usingCitizenid and newHealth > currentHealth and type(AwardHandlerXP) == 'function'
        and HandlerTreatXpMintCooldown.Consume(usingCitizenid, TREAT_XP_MINT_COOLDOWN_MS, requestedAt) then
        AwardHandlerXP(usingCitizenid, 'handlerTreatK9')
    end

    local notifyOk, notifyErr = pcall(function()
        NotifyPlayer(source, locale('medkit.treated_success'), 'success')
        if targetServerId ~= source then
            NotifyPlayer(targetServerId, locale('medkit.target_treated_notice'), 'info')
        end
    end)
    if not notifyOk then
        print(('[John-K9] useK9Medkit post-heal notify error for citizenid %s: %s'):format(targetCitizenid, tostring(notifyErr)))
    end

    return { ok = true }
end

--- Internal implementation for the useK9Medkit callback below. Called only
--- after the callback's own cheap checks (payload shape, feature flag,
--- IsMedkitUserAuthorized) already passed.
---
--- Cheap, non-mutating resolution/rejection checks live directly in this
--- function; the mutex-held mutation is delegated to
--- RunUseK9MedkitMutation above:
---   1. Resolve the USING player's own live ped — reject if unavailable.
---   2. Resolve `targetServerId` to a live, currently-connected player's
---      ped via GetPlayerPed (server-reliable, per this file's header) —
---      reject if it doesn't resolve to anyone online right now.
---   3. Re-derive the TARGET's REAL ped model server-side and confirm it's
---      a configured K9 model (IsConfiguredK9Model) — never trust that the
---      client's target selection actually was a K9.
---   4. Reject if the TARGET is already dead (GetEntityHealth <=
---      PED_DEAD_HEALTH_THRESHOLD, see that constant's own doc comment
---      above) — a K9 medkit
---      restores an INJURED, alive K9; it is not a revive item. See this
---      file's header, CORRECTNESS PASS finding 2, for why this must not
---      fall through to a real laststand/EMS system's own revive flow.
---   5. Resolve the target's citizenid — needed for the cooldown key.
---      Also resolve the USING player's own
---      citizenid (dead-config-field pass) — needed only for the handler's
---      own medkitTreatCooldownMultiplier rank-reduction lookup inside
---      RunUseK9MedkitMutation; never a rejection if it fails to resolve.
---   6. Acquire the per-target mutex — reject outright if already held
---      (another treat-K9 request for this exact K9 is in flight) —
---      release is GUARANTEED via the pcall below, not contingent on any
---      return path inside RunUseK9MedkitMutation.
--- @param source number
--- @param targetServerId number
--- @param requestedAt number
--- @return table result
local function HandleUseK9Medkit(source, targetServerId, requestedAt)
    local usingPed = GetPlayerPed(source)
    if usingPed == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    -- GetPlayerPed on a bogus/offline/out-of-range server id returns 0 —
    -- the same server-reliable resolution primitive server/search.lua's
    -- own ResolveConnectedPlayerFromPed relies on, applied here directly
    -- since the client already supplies a server id rather than a netId
    -- needing entity resolution (see this file's header, callback contract
    -- item 1).
    local targetPed = GetPlayerPed(targetServerId)
    if targetPed == 0 or targetPed == usingPed then
        return { ok = false, reason = 'invalid_target' }
    end

    -- Re-derive the TARGET's REAL model server-side — never trust that the
    -- client's ox_target selection was actually a K9. WIDENED (K9
    -- role/model decoupling, server/appearance.lua) to also accept a
    -- target who holds the decoupled K9 ROLE (HasK9Role) on a model
    -- IsConfiguredK9Model doesn't recognize -- same `type(...) ==
    -- 'function'` guard/fail-closed reasoning as every other widened site
    -- this pass (see server/main.lua's CheckLeashEligibility for the
    -- fullest writeup).
    if not (IsConfiguredK9Model(GetEntityModel(targetPed)) or (type(HasK9Role) == 'function' and HasK9Role(targetServerId))) then
        return { ok = false, reason = 'invalid_target' }
    end

    -- A medkit heals an INJURED, ALIVE K9 — never a dead one. See this
    -- file's header, CORRECTNESS PASS finding 2, AND the native-availability
    -- fix doc comment on PED_DEAD_HEALTH_THRESHOLD above (this check was
    -- `IsEntityDead(targetPed)`, which always silently returned false
    -- server-side -- this gate never actually worked until this pass).
    -- Mirrors server/combat.lua's own ValidateCombatRequest reject, same
    -- reason string ('target_dead'), same "cheap, non-mutating, checked
    -- before the mutex/cooldown/item work below" placement, same
    -- GetEntityHealth-based mechanism (also fixed there this pass).
    if GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD then
        return { ok = false, reason = 'target_dead' }
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not targetCitizenid then
        return { ok = false, reason = 'invalid_target' }
    end

    -- HANDLER XP TIER UNLOCK (dead-config-field pass): the USING player's
    -- own citizenid, needed only for GetHandlerXPTierMedkitCooldownMs's
    -- rank-reduction lookup inside RunUseK9MedkitMutation below -- never
    -- for authorization (IsK9MedkitPermittedForCitizenId, further up this
    -- file's own call chain, already gates on it). Deliberately NOT a
    -- rejection if this fails to resolve (unlike targetCitizenid above,
    -- which the cooldown KEY itself depends on) -- a missing/unresolvable
    -- using-side citizenid just means no handler-tier reduction applies
    -- this call (GetHandlerXPTierMedkitCooldownMs's own defensive
    -- `citizenid` handling degrades a nil the same way an unranked
    -- 'Rookie Handler' does: no multiplier field, baseCooldownMs
    -- unchanged) -- never a reason to block a heal that every earlier gate
    -- already allowed.
    local usingPlayer = exports.qbx_core:GetPlayer(source)
    local usingCitizenid = usingPlayer and usingPlayer.PlayerData and usingPlayer.PlayerData.citizenid

    if not MedkitMutex.TryAcquire(targetCitizenid) then
        return { ok = false, reason = 'treatment_in_progress' }
    end

    -- GUARANTEED release — see this file's header, CORRECTNESS PASS
    -- finding 3. Release happens on the very next line after the pcall
    -- returns, regardless of whether RunUseK9MedkitMutation returned
    -- normally or threw, so a future edit that adds a fallible call inside
    -- the mutation body can never leak this citizenid's mutex entry.
    local ok, result = pcall(RunUseK9MedkitMutation, usingPed, targetPed, source, targetServerId, targetCitizenid, usingCitizenid, requestedAt)
    MedkitMutex.Release(targetCitizenid)

    if not ok then
        print(('[John-K9] useK9Medkit mutation error for source %s targeting citizenid %s: %s'):format(source, targetCitizenid, tostring(result)))
        return { ok = false, reason = 'medkit_failed' }
    end

    return result
end

--- PER-PERSON FEATURE CONTROL -- this resource's documented 4-step
--- resolution (config.lua's own Config.FeatureControl header), implemented
--- in the EXACT shape server/pursuitsprint.lua's own
--- IsPursuitSprintPermittedForCitizenId establishes -- that file's own
--- header says to read it before writing a variant, so this is a copy of
--- its shape, not a new one. Step 1 (the global Config.Features.K9Medkit
--- flag) is already checked by the callback below, before this function is
--- ever reached. Gates the USING player (`source` below) -- see this
--- file's own FILE-TO-FILE CONTRACT for why eligibility to USE a medkit is
--- job-only, never HasK9Access -- not the K9 being treated:
---   2. an explicit block.K9Medkit grant -> DENY
---   3. K9Medkit listed in RequireGrant -> ALLOW only with an active
---      feature.K9Medkit grant
---   4. otherwise -> ALLOW
--- @param citizenid string
--- @return boolean allowed
local function IsK9MedkitPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.K9Medkit') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.K9Medkit == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.K9Medkit') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- DEVELOPER_REFERENCE.md §13.4.4. Server-authoritative "use a K9 medkit" callback.
lib.callback.register('john-k9:server:useK9Medkit', function(source, targetServerId)
    if type(targetServerId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' } -- defensive: never trust client payload shape
    end

    if not Config.Features.K9Medkit then
        return { ok = false, reason = 'feature_disabled' } -- real server-side no-op regardless of client UI state
    end

    if not IsMedkitUserAuthorized(source) then
        return { ok = false, reason = 'no_access' }
    end

    -- PER-PERSON FEATURE CONTROL -- see IsK9MedkitPermittedForCitizenId
    -- above. Checked BEFORE MedkitMutex/RunUseK9MedkitMutation below,
    -- matching server/pursuitsprint.lua's own "cheapest/no-side-effect
    -- checks first, mutation last" discipline, so a blocked USING player
    -- never burns the TARGET's own per-K9 treatment cooldown for a request
    -- that was always going to be refused.
    --
    -- REASON SPLIT (this pass, coder-backend): this branch used to ALSO
    -- return 'no_access' -- the exact same reason string
    -- IsMedkitUserAuthorized's own job-based rejection above already uses --
    -- conflating two genuinely different causes into one indistinguishable
    -- player-facing message: "your job does not permit treating K9s at
    -- all" (the check above) versus "your job permits it, but this server
    -- additionally requires an explicit feature.K9Medkit grant you do not
    -- (yet) hold" (this check). Copies server/pursuitsprint.lua's own
    -- distinct `no_access` vs. `not_granted`-shaped reason split for the
    -- identical class of gate. A player told "you aren't authorized" for
    -- either cause cannot tell which one to fix; a distinct reason string
    -- lets the client eventually tell them.
    --
    -- `not_granted` is a reason value this callback did not emit before the
    -- REASON SPLIT pass above. client/medkit.lua's own reasonLabel lookup
    -- table has since been updated (confirmed by reading it) to map this
    -- reason to `locale('medkit.reason_not_granted')` instead of falling
    -- through to the generic medkit_failed notify -- that fallback still
    -- exists for genuinely unrecognized reasons, but this one is no longer
    -- among them. `locale('medkit.reason_not_granted')` (locales/en.json)
    -- was added alongside this reason so the string existed the moment the
    -- client-side mapping landed.
    local usingPlayer = exports.qbx_core:GetPlayer(source)
    local usingCitizenid = usingPlayer and usingPlayer.PlayerData and usingPlayer.PlayerData.citizenid
    if not usingCitizenid then
        return { ok = false, reason = 'no_access' } -- cannot even resolve who is asking -- closest existing fit, not a new third cause worth inventing for an edge case that should not occur for a genuinely connected player
    end
    if not IsK9MedkitPermittedForCitizenId(usingCitizenid) then
        return { ok = false, reason = 'not_granted' }
    end

    local requestedAt = GetGameTimer()

    -- Purely a defensive outer net for anything thrown BEFORE
    -- HandleUseK9Medkit even reaches MedkitMutex.TryAcquire (e.g. a
    -- corrupted qbx_core player object inside GetPlayerPed/GetPlayer
    -- itself) — no mutex was ever acquired at that point, so there is
    -- nothing to release here. Once the mutex IS acquired,
    -- HandleUseK9Medkit's own inner pcall around RunUseK9MedkitMutation
    -- guarantees release unconditionally on the very next line (see this
    -- file's header, CORRECTNESS PASS finding 3) — this outer pcall never
    -- needs to reason about that mutex at all.
    local ok, result = pcall(HandleUseK9Medkit, source, targetServerId, requestedAt)
    if not ok then
        print(('[John-K9] useK9Medkit error for source %s: %s'):format(source, tostring(result)))
        return { ok = false, reason = 'medkit_failed' }
    end

    return result
end)
