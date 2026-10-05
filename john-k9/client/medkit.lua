--[[
    john-k9/client/medkit.lua

    Phase 4 implementation. Owns Config.Features.K9Medkit's client-side
    "Treat K9" ox_target world interaction (DEVELOPER_REFERENCE.md §13.4.4) — the
    UX-only half of this feature's trust boundary. ALL real validation
    (using-player eligibility, live proximity, target-model re-verification,
    item possession/consumption, per-target cooldown) happens server-side in
    server/medkit.lua's `john-k9:server:useK9Medkit` callback — nothing
    below is a security boundary, per this codebase's established "client
    hides the option, server is the real gate" split (DEVELOPER_REFERENCE.md §4.1's
    security note, already applied identically to every other gated action
    in this resource).

    Deliberately does NOT check the using player's own job or medkit
    possession client-side beyond hiding the option when the feature flag
    is off — a "Treat K9" prompt shown to a non-eligible or empty-handed
    player is a harmless false-positive UX affordance (the server rejects
    it with a real, distinct reason the ox_lib notify below surfaces), not
    a new trust surface.

    ======================================================================
    OX_TARGET API — CONFIRMED AGAINST THE REAL SOURCE THIS SESSION
    (github.com/overextended/ox_target @ main, fetched and read directly):
    `exports.ox_target:addGlobalPlayer(options)` shares the exact same
    option/callback shape as `addGlobalVehicle` (already used, confirmed
    working, in client/vehicle.lua's own "Load/Release K9" options) — both
    are thin wrappers around the same internal `addTarget(store, ...)`
    dispatcher. `canInteract(entity, distance, coords, name, bone)` receives
    the targeted ped's entity handle (matches client/vehicle.lua's existing
    `canInteract(entity, distance, coords, name)` usage exactly).
    `onSelect(data)` receives a table whose `.entity` field is the SAME
    targeted ped handle (confirmed by reading ox_target's own
    `getResponse()`/NUI 'select' callback in client/main.lua: `response.entity
    = currentTarget.entity`). `addGlobalPlayer` (rather than `addGlobalPed`)
    is used deliberately — the target of this feature is always a
    currently-connected K9 PLAYER, never an NPC, so scoping the option to
    ox_target's own player-detection is a strictly better semantic match
    than filtering an `addGlobalPed` option down to K9 models by hand
    (server/medkit.lua re-verifies both facts independently regardless —
    this is a UX-quality choice, not a security boundary).
    CONFIDENCE: HIGH — read directly from real ox_target source this
    session, not assumed from memory.

    FILE-TO-FILE CONTRACT:
    - Calls client/main.lua's `IsEntityModelK9(entity)` (DEVELOPER_REFERENCE.md
      item 3) as its client-side display filter — deliberately NOT calling
      any server-global (`IsConfiguredK9Model` is server-only), since
      server/medkit.lua re-derives the target's real model server-side
      regardless. Used to build its own local `K9ModelHashes` set from
      `Config.Peds` (deleted this pass — see IsEntityModelK9's own doc
      comment in client/main.lua for the full "5 independent copies"
      finding this consolidation closes).
    - Calls client/main.lua's `ResolvePlayerServerIdFromPed(entity)`
      (DEVELOPER_REFERENCE.md item 2b) in the "Treat K9" onSelect handler
      below — used to be a local copy of this file's own; extracted once
      client/wellbeing.lua's "Pet K9"/"Feed K9" handlers turned out to be
      hand-copying the identical function.
    - Triggers `john-k9:server:useK9Medkit` (server/medkit.lua) and
      handles `john-k9:client:applyMedkitHeal` (server/medkit.lua) — see
      that file's header for the full event/callback contract.
    - THIS FILE exposes one resource-global function for a radial entry
      point: `RequestTreatNearestK9()` — see its own doc comment near the
      bottom of this file for the full contract. Added because, until this
      pass, every bit of "treat a K9" logic lived entirely inside the
      ox_target `onSelect` closure below with nothing else in this
      resource able to reach it — a radial "Treat K9" item had no global to
      call. Mirrors client/movement.lua's RequestLeashAttach() shape: a
      thin, re-checked entry point that funnels into the SAME
      request/response implementation the ox_target option already uses
      (RequestTreatK9(targetServerId) below), never a second, divergent
      treat-request code path.
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
--- Shared "ask the server to treat this specific K9" implementation —
--- called by both the ox_target `onSelect` below (targetServerId already
--- resolved from the interacted ped) and RequestTreatNearestK9() further
--- down (targetServerId resolved from a self-initiated nearest-K9 scan).
--- Kept as the ONE place that awaits the callback and interprets its
--- result, so a future reason value only needs updating here.
--- @param targetServerId number
local function RequestTreatK9(targetServerId)
    -- FAIL-CLOSED GUARD (dependency-verification finding, this pass):
    -- `lib.callback.await` throws rather than returning nil on a timeout
    -- or unregistered-callback rejection (see client/main.lua's
    -- HasK9Access() doc comment for the full ox_lib/FiveM source
    -- citation). pcall it; the very next line's `if not result then
    -- return end` already treats a nil result as a silent no-op, so a
    -- thrown failure now degrades to that exact same path instead of
    -- aborting this onSelect handler uncaught.
    local ok, result = pcall(lib.callback.await, 'john-k9:server:useK9Medkit', K9_CALLBACK_TIMEOUT_MS, targetServerId)
    if not ok then result = nil end
    if not result then return end

    -- DUPLICATE-TOAST FIX (this pass, coder-backend): a `result.ok` branch
    -- used to sit here and fire its own lib.notify(medkit.treated_success),
    -- on this SAME using player's client, for the SAME successful treat
    -- server/medkit.lua's RunUseK9MedkitMutation already notifies via
    -- NotifyPlayer(source, locale('medkit.treated_success'), 'success')
    -- (source there IS this client, the player who triggered this exact
    -- callback) -- traced both call sites this pass and confirmed they reach
    -- the identical player with the identical text for one successful
    -- treat. Removed here, kept server-side: the server is the authority on
    -- whether the treat actually succeeded (item consumption, cooldown,
    -- mutex, health clamp all resolve server-side), while this client-side
    -- branch only ever reflected an already-final `result.ok` it received
    -- FROM that same server call -- so it had nothing of its own to add, and
    -- dropping it cannot suppress any outcome the player wasn't already told
    -- about by the server. Inverted to `if not result.ok then ... end`
    -- (rather than an `if result.ok then <nothing> else ... end` shape) so
    -- there is no empty branch left behind for luacheck to flag. Every
    -- rejection reason below is UNCHANGED: server/medkit.lua notifies on NO
    -- rejection path (confirmed by reading HandleUseK9Medkit/
    -- RunUseK9MedkitMutation/the lib.callback.register wrapper in full), so
    -- this remains the ONLY feedback a player gets for every one of those
    -- reasons.
    if not result.ok then
        -- Mirrors client/search.lua's own "unrecognized reason ->
        -- plain error notify" fallback discipline — no client-side
        -- change is required if server/medkit.lua ever adds a new
        -- reason value. 'medkit_failed' and the unrecognized-reason
        -- fallback share the identical English sentence (confirmed before
        -- minting) and both point at medkit.reason_medkit_failed rather
        -- than duplicating it under a second key. `too_far` reuses
        -- common.too_far_from_k9 -- byte-for-byte identical to
        -- client/wellbeing.lua's own too_far rejection text (confirmed by
        -- grep before minting), promoted to common.* rather than kept as
        -- two drifting per-file copies.
        local reasonLabel = ({
            feature_disabled      = locale('medkit.reason_feature_disabled'),
            no_access             = locale('medkit.reason_no_access'),
            -- 'not_granted' — server/medkit.lua's own REASON SPLIT pass:
            -- distinct from 'no_access' above ("your job does not permit
            -- treating K9s at all") -- this one means "your job permits it,
            -- but this server additionally requires an explicit
            -- feature.K9Medkit grant you do not (yet) hold" (mirrors
            -- server/pursuitsprint.lua's own no_access/not_granted split
            -- for the identical class of gate). Before this mapping was
            -- added, this reason fell through to the unrecognized-reason
            -- fallback below (medkit_failed) -- a real, distinguishable
            -- refusal cause the server already computes, made invisible to
            -- the player again at this exact seam.
            not_granted           = locale('medkit.reason_not_granted'),
            invalid_target        = locale('medkit.reason_invalid_target'),
            -- 'target_dead' — server/medkit.lua's own correctness
            -- pass: a medkit heals an injured, ALIVE K9, never
            -- revives a dead one (that's a real laststand/EMS
            -- system's job, not a plain consumable's).
            target_dead           = locale('medkit.reason_target_dead'),
            too_far               = locale('common.too_far_from_k9'),
            on_cooldown           = locale('medkit.reason_on_cooldown'),
            no_item               = locale('medkit.reason_no_item'),
            treatment_in_progress = locale('medkit.reason_treatment_in_progress'),
            medkit_failed         = locale('medkit.reason_medkit_failed'),
        })[result.reason] or locale('medkit.reason_medkit_failed')

        lib.notify({ title = locale('common.notify_title'), description = reasonLabel, type = 'error' })
    end
end

-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never a
-- direct `exports.ox_target` call -- canInteract/onSelect below are
-- unchanged (still authored against ox_target's own convention), so an
-- operator running a different supported target script gets this option
-- translated automatically instead of losing it outright.
--
-- LIFECYCLE FIX (this pass): extracted into a named function, sole call
-- site the AddEventHandler('onResourceStart', ...) below, so this option
-- comes back after a bare restart of whatever resource actually backs the
-- 'target' system, not just after this resource's own restart -- every
-- supported target script keeps its own registry in a plain file-local Lua
-- table inside its own client chunk, reloaded empty on THAT resource's own
-- restart with nothing else prompting a re-add. Mirrors
-- server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. DUPLICATE-VS-REPLACE: the
-- option below always sets `name`, and every adapter's own registration
-- primitive dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running this
-- never duplicates the entry.
-- THIRD-EYE CLARITY PASS (this pass, owner-directed): icon changed from
-- fas fa-kit-medical to fas fa-user-tie, this resource's own "a separate
-- human acts on/for a K9" icon (confirmed with the sibling agent covering
-- the vehicle/object half of this same pass — fas fa-dog is reserved for
-- options only shown while the LOCAL player's own body IS the K9, which is
-- never this option's case: the using player here is whoever is treating
-- the K9, never the K9 itself). Deliberately NOT labeled with a "Handler:"
-- prefix the way this file's sibling movement.lua options now are: per
-- this file's own header, the using player here is job-gated (typically an
-- EMS role via Config.K9Medkit.emsJobs), not necessarily anyone holding an
-- actual K9 Handler certification, so a "Handler:" prefix would assert a
-- role the eligible user may not hold. Label reworded to plain English
-- instead; canInteract/onSelect are UNCHANGED.
local function RegisterMedkitOxTargetOption()
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'john-k9:treatK9',
            icon = 'fas fa-user-tie',
            label = locale('medkit.treat_target_label'),
            distance = Config.K9Medkit.range,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.K9Medkit then return false end
                -- WIDENED (K9 role/model decoupling) with
                -- IsK9RoleForPlayer(...) -- client/appearance.lua's own
                -- per-target-cached (1s TTL) server round trip for "does
                -- THAT player hold the K9 role" -- so a target on a
                -- human/custom model who already holds the role can still
                -- be treated. Short-circuited last: only reached on a
                -- cache miss for the (rare) case IsEntityModelK9 didn't
                -- already answer this.
                return IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
            end,
            onSelect = function(data)
                local targetServerId = ResolvePlayerServerIdFromPed(data.entity)
                if not targetServerId then return end

                RequestTreatK9(targetServerId)
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterMedkitOxTargetOption()
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
        RegisterMedkitOxTargetOption()
    end
end)

--- Same nearest-candidate scan shape as client/radial.lua's own
--- FindNearestLeashCandidate()/FindNearestPartnerCandidate() — duplicated
--- here rather than shared (this file has no import mechanism to reach
--- those, and per this task's file-ownership split client/radial.lua is
--- out of scope here) — for RequestTreatNearestK9()'s self-initiated
--- (radial) entry point below. Filters to a live K9 model OR the decoupled
--- K9 role (K9 role/model decoupling -- IsK9RoleForPlayer(...), same
--- widening and same reasoning as this file's own ox_target `canInteract`
--- above), unlike FindNearestLeashCandidate (which filters to none).
--- Display-only: server/medkit.lua's HandleUseK9Medkit independently
--- re-verifies the target's real model/role, aliveness, proximity, and
--- certification regardless of what this scan picks.
--- @return number? candidateServerId
local function FindNearestTreatableK9()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPlayer, nearestDist

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= PlayerId() then
            local targetPed = GetPlayerPed(playerId)
            if targetPed ~= 0 and DoesEntityExist(targetPed)
                and (IsEntityModelK9(targetPed) or IsK9RoleForPlayer(GetPlayerServerId(playerId))) then
                local dist = #(myCoords - GetEntityCoords(targetPed))
                if dist <= Config.K9Medkit.range and (not nearestDist or dist < nearestDist) then
                    nearestPlayer, nearestDist = playerId, dist
                end
            end
        end
    end

    if not nearestPlayer then return nil end
    return GetPlayerServerId(nearestPlayer)
end

--- Resource-global — radial self-service entry point (see FILE-TO-FILE
--- CONTRACT above).
---
--- CanShowK9UI() PRE-CHECK REMOVED, THIS PASS (permission audit finding):
--- this function used to re-check CanShowK9UI() itself, mirroring
--- client/movement.lua's RequestLeashAttach() shape -- WRONG for this
--- specific action. "Treat K9" is a HUMAN HANDLER action, not a K9 ability:
--- server/medkit.lua's own header states this by name ("Does NOT call
--- HasK9Access -- eligibility to USE a medkit ON a K9 is job-only, never
--- HasK9Access -- not the K9 being treated"), and its real authorization
--- gate, IsMedkitUserAuthorized(source), checks Config.Departments/EmsJobSet
--- job membership ONLY for the USING player -- never HasK9Access, model, or
--- role. CanShowK9UI() (IsK9Role() AND HasK9Access()) demanded the OPPOSITE
--- of that: that the TREATER themselves currently be an on-duty, certified
--- K9. A plain PD/EMS officer with zero K9 certification of their own --
--- not merely a High Command/autoAccessGrade-bypass edge case -- was
--- refused a mechanic the server would have granted. This also brings this
--- function in line with this file's OWN "Treat K9" ox_target `canInteract`
--- predicate just above, which has NEVER checked the treater's own
--- CanShowK9UI() (only that the TARGET looks like a K9) -- this self-service
--- entry point simply had not been kept consistent with it.
--- client/radial.lua's own 'k9_treat_nearest' item has had its matching,
--- redundant CanShowK9UI() pre-check removed in the same pass (see that
--- item's own comment) -- removing only one of the two would have left the
--- other still blocking exactly what this fix exists to unblock. The server
--- (IsMedkitUserAuthorized, plus every per-target proximity/model/aliveness/
--- cooldown check inside RequestTreatK9()'s own callback) remains the real,
--- independent authority regardless -- a non-eligible clicker now reaches
--- RequestTreatK9()'s own specific 'no_access'/'not_granted' rejection
--- (already mapped below) instead of this file's own generic denial, a
--- strictly more honest failure, not a weaker one.
--- Feature-flag/no-candidate cases are each notified distinctly so a
--- player understands why nothing happened, then funnels into the SAME
--- RequestTreatK9() implementation the ox_target option above uses.
function RequestTreatNearestK9()
    if not Config.Features.K9Medkit then
        -- Byte-for-byte identical to the reasonLabel table's own
        -- feature_disabled entry above (confirmed by grep before minting) --
        -- reused rather than duplicated under a second key.
        lib.notify({ title = locale('common.notify_title'), description = locale('medkit.reason_feature_disabled'), type = 'error' })
        return
    end

    local targetServerId = FindNearestTreatableK9()
    if not targetServerId then
        lib.notify({ title = locale('common.notify_title'), description = locale('medkit.no_nearby_k9'), type = 'error' })
        return
    end

    RequestTreatK9(targetServerId)
end

-- ======================================================================
-- CHAT COMMAND -- Treat K9, self-service path (menu-parity pass: "chat
-- commands, 3rd eye, and radial menus" -- every feature reachable from all
-- three). Before this pass, a handler with no visible nearby K9 (or who
-- simply preferred typing) had no self-initiated entry point at all -- only
-- the targeted "Treat K9" ox_target option on a specific K9 and
-- client/radial.lua's own 'k9_treat_nearest' Utility item existed.
--
-- A single one-shot action, not a toggle -- dispatches straight into the
-- SAME resource-global client/radial.lua's own item already calls, with no
-- pre-check of its own added here: RequestTreatNearestK9() is deliberately
-- UNGATED on CanShowK9UI() (see its own doc comment above -- "Treat K9" is a
-- human-handler action, authorized server-side on job/department membership
-- alone, never on K9 access/model/role for the TREATER), matching
-- client/radial.lua's own item and client/tablet.lua's own K9Medkit trigger
-- exactly. Adding a gate here would reintroduce the exact "refused a plain
-- officer the server would have granted" bug this file's own permission
-- audit already closed elsewhere -- not a safety improvement, just a
-- redundant permission check this pass was told to avoid writing.
--
-- REGISTERED UNCONDITIONALLY, outside the REGISTRATION-TIME FEATURE GATE
-- immediately below -- same "reachable-but-inert" posture that block's own
-- opening comment already establishes for the ox_target option/
-- RequestTreatNearestK9()/FindNearestTreatableK9() above: RequestTreatNearestK9()
-- itself already checks Config.Features.K9Medkit and notifies
-- 'feature_disabled' when it's off, so this command needs no flag check of
-- its own either.
-- ======================================================================
RegisterCommand('k9treat', function()
    RequestTreatNearestK9()
end, false)

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE (coder-security, this pass) -- mirrors
-- client/kennel.lua's own identically-shaped "REGISTRATION-TIME FEATURE
-- GATE" block (read that file's header before changing this one -- this
-- follows it, not a second independent design), applied here to exactly
-- ONE RegisterNetEvent call rather than this whole file: the ox_target
-- option/RequestTreatNearestK9()/FindNearestTreatableK9() above all stay
-- OUTSIDE this gate on purpose, unchanged -- RequestTreatNearestK9() must
-- stay reachable-but-inert for client/radial.lua's and client/tablet.lua's
-- own `type(RequestTreatNearestK9) == 'function'` call sites, exactly like
-- client/kennel.lua's RequestDeployKennel.
--
-- FINDING, THIS PASS: the "FEATURE GATE" comment immediately below used to
-- claim this handler matched "client/hud.lua / client/vision.lua /
-- client/combat.lua's 'gate at registration' precedent" -- it did not. The
-- code it sat above only checked Config.Features.K9Medkit as the FIRST
-- statement INSIDE the handler body; RegisterNetEvent itself ran
-- unconditionally at file load, so this event was always registered and
-- always reachable, feature flag or not. That is a real, different (and
-- weaker) pattern than the one the comment named: with the true
-- "gate at registration" shape those sibling files use, a client whose
-- server never enables K9Medkit never has ANY function listening on this
-- event name at all -- structurally unreachable, not merely
-- checked-and-declined every time something reaches it. Closed here by
-- wrapping the RegisterNetEvent call itself, matching the DEVELOPER_REFERENCE.md
-- "Flag-off-safety defect class" audit item that named this exact handler
-- (alongside client/kennel.lua's deployKennelAt/removeKennel and
-- client/progression.lua's xpTierChanged) as needing its own flag gate --
-- those other two already got the STRONGER registration-time form; this
-- one only got the weaker in-handler form, an inconsistency now fixed to
-- match. The inner check three lines below is KEPT regardless, as
-- deliberate defense-in-depth -- same "layered checks" posture as the
-- SOURCE-ORIGIN GUARD remaining even though this outer gate also exists,
-- and the thing that keeps this handler correct if a future edit ever
-- flattens the outer `if` back out without noticing what it was for.
-- ======================================================================
if Config.Features.K9Medkit then

--- Server-pushed heal application — see server/medkit.lua's header for why
--- this is client-self-applied rather than a direct server-side
--- SetEntityHealth call (DEVELOPER_REFERENCE.md §13.4.4 open question 1).
--- `newHealth` is an already-clamped ABSOLUTE health value computed
--- server-side — this handler never adds/interprets a delta of its own.
--- @param newHealth number
RegisterNetEvent('john-k9:client:applyMedkitHeal', function(newHealth)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- DEVELOPER_REFERENCE.md#trust-boundary for the full writeup;
    -- not re-derived here). Without this, a forged local
    -- `TriggerEvent('john-k9:client:applyMedkitHeal', <anything>)`
    -- would reach the exact same SetEntityHealth call a genuine server
    -- push does, with zero server contact. Confirmed against FiveM's own
    -- documented event model this pass (docs-backend.fivem.net,
    -- "Listening for events" / TriggerClientEvent references): 65535 is
    -- the documented sentinel identifying a genuine server-to-client
    -- dispatch; a same-resource `TriggerEvent(...)` never produces it.
    if source ~= 65535 then return end

    -- FEATURE GATE, KEPT AS DEFENSE-IN-DEPTH -- the REAL gate is now the
    -- registration-time `if Config.Features.K9Medkit then` this handler is
    -- wrapped in above (see this block's own opening comment for the
    -- finding that fixed this). This inner check is deliberately left in
    -- place rather than deleted as "now redundant": it is what keeps this
    -- handler correct on its own, with no reliance on the outer wrapper,
    -- exactly the same "never remove a working guard, only add to it"
    -- discipline this file already applies to the dead-K9 guard and the
    -- monotonic-heal floor below.
    if not Config.Features.K9Medkit then return end

    if type(newHealth) ~= 'number' then return end

    local ped = PlayerPedId()

    -- DEAD-K9 GUARD (coder-backend, correctness pass) -- server/medkit.lua
    -- already rejects a request targeting an already-dead K9 up front
    -- (HandleUseK9Medkit's own IsEntityDead check, reason 'target_dead'),
    -- but that check runs at REQUEST time, not at the moment this event is
    -- actually applied here. In the network-latency gap between the
    -- server computing `newHealth` (while this K9 was still alive) and
    -- this handler running, this K9 could have died from unrelated damage
    -- -- without this guard, a heal computed for a live K9 would still
    -- land as a de-facto revive via SetEntityHealth a moment after death,
    -- exactly the outcome server/medkit.lua's own header explains this
    -- item is deliberately NOT meant to cause (a medkit heals an injured,
    -- ALIVE K9; reviving a dead one is a real laststand/EMS system's job).
    -- Never treated as an error -- a stale heal for a K9 that died in
    -- transit is simply dropped, same as any other now-irrelevant queued
    -- effect.
    if IsEntityDead(ped) then return end

    -- RANGE CHECK (coder-security, this pass) -- `newHealth` was
    -- previously type-checked only, never range-checked. server/medkit.lua
    -- always computes it inside [currentHealth, GetEntityMaxHealth(ped)]
    -- (see that file's RunUseK9MedkitMutation), so this clamp is a
    -- true no-op for a genuine server push -- but is the ONLY thing that
    -- would have stopped a forged event carrying an arbitrary numeric
    -- newHealth (e.g. 99999) from being applied verbatim as a free,
    -- uncapped self-heal, independently of whether the origin guard above
    -- holds. Complementary, not redundant, with that guard.
    --
    -- MAX-HEALTH AGREEMENT -- server/medkit.lua's header, CORRECTNESS PASS
    -- finding 1: nothing in this resource ever modifies a K9 ped's real
    -- max health (confirmed by reading server/wellbeing.lua's Injury stat
    -- directly -- it's an entirely separate virtual per-citizenid float,
    -- never written back to the ped's native health fields), so this live
    -- GetEntityMaxHealth(ped) read and the server's own live
    -- GetEntityMaxHealth(targetPed) read at compute time are two reads of
    -- the same never-modified value and cannot disagree from anything this
    -- resource does. This clamp still re-reads it live (rather than
    -- trusting the server's number outright) so that if a THIRD-PARTY
    -- resource or a ped respawn ever DOES change the live ceiling in the
    -- gap between those two reads, the result can only be a safe
    -- under-heal capped to the lower of the two ceilings, never an
    -- overheal above whatever is actually live right now.
    --
    -- MONOTONIC-HEAL FLOOR (this pass, correctness fix): the lower bound
    -- here was previously a flat `0`, not this ped's own CURRENT live
    -- health. server/medkit.lua's RunUseK9MedkitMutation guarantees
    -- newHealth >= currentHealth only as measured AT COMPUTE TIME -- the
    -- exact same network-latency gap the DEAD-K9 GUARD above already
    -- accounts for also means a second, older/reordered/retried
    -- applyMedkitHeal for this same K9 could still arrive and be processed
    -- AFTER a newer one already raised this ped's live health past it. A
    -- "heal" handler applying a lower absolute value than the ped's CURRENT
    -- health would visibly reduce it -- the exact "heal event that hurts"
    -- outcome this file's own header explicitly says a medkit must never
    -- cause. Reading currentHealth live, right here, and using it (not 0)
    -- as the floor makes this call structurally a no-op-or-increase only,
    -- regardless of event ordering.
    local currentHealth = GetEntityHealth(ped)
    newHealth = math.max(currentHealth, math.min(newHealth, GetEntityMaxHealth(ped)))

    SetEntityHealth(ped, newHealth)
end)

end -- if Config.Features.K9Medkit -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
