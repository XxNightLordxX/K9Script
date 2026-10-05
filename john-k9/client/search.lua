--[[
    john-k9/client/search.lua

    Phase 2. Owns Search Vehicle / Search Person: the two
    ox_target options that play an alert "investigating" scenario for the
    duration of a progress bar, then await the server's real,
    server-computed contraband result — DEVELOPER_REFERENCE.md §11.1
    sub-phases 2b/2c, §11.3's `client/search.lua` row. CORRECTED (this
    pass, coder-frontend): this header used to claim "play a sniff
    animation" while the function below actually called nothing but
    lib.progressBar — a real drift between comment and code, not a
    documentation nuance. See PerformSearch's own SEARCH SCENARIO note
    below for exactly what plays now and the honest confidence grading on
    the scenario name chosen (no dog-specific "sniffing" scenario could be
    independently confirmed to exist this pass — see that note for what was
    tried and why this reuses an already-verified sibling instead of
    guessing). Deliberately a SEPARATE file
    from client/tracking.lua even though both are "K9 sniffs, a result
    appears" in flavor — the split is by TRUST MODEL, not feature name:
    tracking reveals a client-cosmetic trail (no real capability granted,
    informational only per §11.6); search reveals a target's REAL,
    server-verified inventory contents (a real capability grant, the same
    trust category as certification, per §11.3's "splitting by trust
    model... mirrors how Phase 1 split certifications.lua from main.lua"
    reasoning). Do not fold this file into client/tracking.lua, and do not
    let any of tracking.lua's trail-rendering logic grow into this file.

    Supplementary implementation detail (non-authoritative — DEVELOPER_REFERENCE.md §11 is
    the source of truth if anything here drifts from it):
    DEVELOPER_REFERENCE.md#contraband-search (the concrete ox_inventory
    export surface, validation order, and container-recursion requirement).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per DEVELOPER_REFERENCE.md §11.4 item 2. Server
    side lives in server/search.lua (read directly — see the resolved
    bystander-alert note below).

    Callbacks (ox_lib lib.callback):
    1. 'john-k9:server:searchTarget' (targetType: 'vehicle'|'person', targetNetId: number)
       -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
       [server/search.lua]
       THE SECURITY-CRITICAL CALLBACK. THIS FILE (the client side) only
       ever CONSUMES this callback's return value — it must never compute
       or pre-display a result on its own, and every field in the response
       is 100% server-computed, never an echo of anything this file sent
       (`targetType`/`targetNetId` are the only two fields THIS FILE
       controls, and only ever select WHICH entity gets checked, never the
       outcome).
       `reason` values handled below, per
       DEVELOPER_REFERENCE.md#contraband-search §3 and confirmed against
       server/search.lua's own header: 'invalid_target',
       'feature_disabled', 'no_access', 'search_in_progress', 'on_cooldown',
       'too_far', 'search_failed' (plus 'access_revoked' — see the DISCLOSED
       FINDING note in tests/clientsearch_spec.lua for why that one is
       genuinely reachable despite not appearing in this file's own
       original scaffold-era header text). `search_failed` is shown to the
       player as distinct from a clean result ("couldn't complete the
       search, try again" — NEVER "nothing found") — collapsing the two is
       the exact correctness bug that note's §3 step 10 and §6 flag
       explicitly.

       UX PASS (owner request: "make the 3rd eye easier to understand...
       never show an option that will just refuse... name the real
       reason, never a bare 'not permitted'"): every one of
       'too_far'/'feature_disabled'/'invalid_target'/'no_access'/
       'access_revoked' now gets its OWN plain-English notify naming that
       specific reason, instead of collapsing all five into one generic
       "Unable to search right now" message — see PerformSearch's
       rejection branch below. A genuinely unrecognized/missing reason
       still falls through to `search.generic_denied`; the catch-all is
       preserved, only the actually-documented reasons were pulled out of
       it. Separately, the "Search Vehicle" option's own canInteract now
       ALSO hides the option while `searchInProgress` is true (previously
       only onSelect checked it) — selecting it mid-search was already a
       guaranteed silent no-op, so a visible-but-inert option was exactly
       the "shows an option that will just refuse" complaint; this is a
       pure display change, not a new security boundary (PerformSearch's
       own defensive re-check and server/search.lua's real mutex are what
       actually enforce this, unchanged).

       COOLDOWN UX, CORRECTED (later pass): 'on_cooldown' and
       'search_in_progress' used to be a deliberate silent no-op here too,
       following this resource's usual low-key cooldown convention. That was
       wrong at THIS call site specifically, and the reason is worth keeping
       written down. The convention is sound for an INSTANT refusal -- press
       a key, nothing happens, the absence of a response is itself readable.
       But by the time the SERVER answers here, the player has already stood
       through the entire sniffAnimDurationMs progress bar with their
       movement disabled. Saying nothing at that point means the dog visibly
       searched and produced no result whatsoever, which a player cannot
       tell apart from the feature being broken -- and reports as such. Both
       now name themselves, in 'inform' styling rather than 'error': a
       cooldown is a normal rhythm of using the feature, not a mistake.

       The CLIENT-side `searchInProgress` double-click guard further down
       stays silent, and that is the same rule applied consistently rather
       than an inconsistency: it fires BEFORE any animation plays, so it
       really is the instant, self-explanatory refusal the convention was
       written for. What changed is not the convention -- it is recognising
       that a refusal costing four seconds is not the same kind of event as
       one costing nothing.

    RESOLVED — bystander-alert broadcast event (DEVELOPER_REFERENCE.md §11.4 item 2 does
    not name it, only that it broadcasts "the same way server/main.lua's
    relayBark does"). Confirmed by reading server/search.lua's own header
    directly (that file names and documents this exact event, payload, and
    receiving file — not guessed):
    2. 'john-k9:client:playContrabandAlert' (netId: number, alertTier: string)
       [server/search.lua broadcasts; THIS FILE receives, per
       server/search.lua's own header assigning the receive side here
       rather than to client/main.lua] — deliberately carries ONLY
       netId + alertTier, NEVER totalWeight/contrabandFound (those are
       private to the requester, returned solely via the callback above,
       per §11.4 item 2's "never broadcast" language and
       DEVELOPER_REFERENCE.md#contraband-search §6's "leaking exact contraband detail
       to the wrong audience" exploit note). Distance-filtered server-side
       (Config.SearchZones.alertBroadcastRadius) — NOT a global
       TriggerClientEvent(-1, ...) like relayBark, so a no-op if this
       client never receives it (out of range of the searched target).

    No server events (client->server) for THIS FILE beyond the callback
    above — result delivery to the requester is the callback; the
    bystander broadcast is server-initiated only.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes NO resource-global functions to other client
      files. Confirmed ox_target-only, mirroring how client/vehicle.lua's
      ox_target options call that file's OWN internal logic directly
      rather than exposing a cross-file global for it. client/radial.lua
      gets no "Search Vehicle/Person" item — DEVELOPER_REFERENCE.md §11.5's acceptance
      criteria only ever describe ox_target as the entry point for this
      feature.
    - THIS FILE calls client/main.lua's CanShowK9UI() inside each
      ox_target option's canInteract AND again, defensively, inside
      onSelect before awaiting the callback — mirrors client/vehicle.lua's
      enterVehicle option, which is exactly the kind of "hot call site"
      client/main.lua's header names as the reason HasK9Access() carries a
      short TTL cache (canInteract can run several times a second while
      hovering).
    - THIS FILE reads Config.SearchZones (confirmed in config.lua,
      including the alertBroadcastRadius amendment beyond §11.2's original
      text — that field is server/search.lua's own concern for filtering
      the broadcast, not read by this file directly).
      Config.SearchContrabandItems is NOT read by this file at all — the
      authoritative contraband list/detection lives server-side only, per
      §11.2's "single source of truth" framing; this file never duplicates
      contraband-detection logic client-side even for a preview.

    Ped/NPC search (a "person" search against a non-player ped) is
    explicitly a STRETCH item per §11.3's own scoping note, not required
    for Phase 2 — this file's player-only scope matches §11.4 item 2's
    server-side validation (NetworkGetPlayerIndexFromPed check).

    DEPENDENCY NOTE: no compile-time dependency on client/tracking.lua or
    client/vision.lua. Load order relative to those two doesn't matter.
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
--- Local-only UX guard against double-dispatching the SAME ox_target
--- option while a previous search is still awaiting its callback (e.g. a
--- double-click before the sniff animation/progress bar visually disables
--- the option). This is a UX nicety only, NOT the security boundary —
--- server/search.lua's own in-flight mutex (per
--- DEVELOPER_REFERENCE.md#contraband-search §4A) is what actually closes
--- the exploitable race; this local flag exists purely so this client
--- doesn't visibly fire two overlapping sniff animations/progress bars
--- against itself.
--- @type boolean
local searchInProgress = false

--- Is this K9 currently part-way through a search?
---
--- Exposed as a resource-global (not merely a file local) so the MUTUAL
--- GUARD below can be closed from BOTH sides: this file refuses to start a
--- search while a restraint or a vehicle already owns the ped, and
--- client/combat.lua refuses to start a bite / takedown / drag while a
--- search is running. A guard that only exists in one direction is not a
--- guard -- it just decides which of two conflicting mechanics has to be
--- started second, and this codebase has already had to fix that exact
--- half-a-guard shape once, between vehicle entry and dragging.
---
--- @return boolean
function IsSearchInProgress()
    return searchInProgress
end

--- Is something else already using this K9's body in a way a search would
--- fight with?
---
--- Deliberately the same question client/appearance.lua's own
--- IsCurrentlyEngaged() asks before a model swap, and answered by calling
--- the same resource-globals, because it is the same question: "is this
--- ped currently owned by another mechanic". Kept as a separate local
--- rather than reaching for that file's version because it is a `local
--- function` there, private to it -- duplicating four guarded calls is
--- better than making one file's internals another file's dependency.
---
--- Each call is `type(fn) == 'function'`-guarded: every one of these lives
--- in a file that may legitimately not be loaded (a server running with
--- that feature's Config.Features flag off never defines them), and this
--- resource's rule is that an absent optional global is a skipped check,
--- never an error.
---
--- A vehicle-seated K9 is included on purpose, and is the case that
--- actually shipped broken: a dog sitting in the back of a cruiser could
--- search a person standing outside it, through the door, because
--- ox_target's own reach does not care that the K9 is strapped in. Nothing
--- refused it -- not this file, not the server.
---
--- @return boolean engaged
--- @return string|nil reasonLocaleKey -- which message to show, when engaged
local function IsBusyWithSomethingElse()
    if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
        return true, 'combat.blocked_by_vehicle'
    end
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
        return true, 'search.blocked_while_engaged'
    end
    if type(IsDragEngaged) == 'function' and IsDragEngaged() then
        return true, 'search.blocked_while_engaged'
    end
    if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then
        return true, 'search.blocked_while_engaged'
    end
    if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then
        return true, 'search.blocked_while_engaged'
    end
    return false, nil
end

--- ======================================================================
--- SEARCH SCENARIO (this pass, coder-frontend) — closes the gap flagged by
--- this file's own former header ("plays a sniff animation") not matching
--- what PerformSearch actually did (nothing but lib.progressBar, no anim
--- code anywhere in this file — confirmed by grep before this pass, not
--- assumed).
---
--- VERIFICATION ATTEMPTED, THIS PASS: a genuine, dog-specific
--- "sniffing"/"searching"/"investigating" scenario for the WORLD_DOG_*
--- skeleton could NOT be independently confirmed. Tried, all from this
--- sandbox's own egress allowlist: raw.githubusercontent.com (confirmed
--- REACHABLE in general — two unrelated real repos on that same host
--- resolved fine — but both community scenario-dump paths this codebase's
--- own K9Sit()/door-scratch precedents cite, DioneB/GTAV-Scenarios and
--- kibook/spooner's scenarios.lua, 404 on every branch/filename guessed
--- this session), github.com repo pages (403), api.github.com code/repo
--- search (session is repo-scope-restricted, not a general search),
--- jsdelivr's gh package-file listing (no resolvable version for either
--- repo), grep.app (bot-walled), gtaforums/duckduckgo (bot-walled/no
--- usable results). native-api-assistant — this resource's own established
--- point of contact for exactly this kind of check — was not a reachable,
--- currently-running agent this session either. Recorded here, not
--- silently skipped, per this task's own "do not fabricate, say so"
--- instruction.
---
--- CHOICE MADE: rather than invent a "WORLD_DOG_SNIFFING_*"-shaped guess —
--- which would silently no-op forever if wrong, per FiveM's own
--- unregistered-scenario behavior — this REUSES the SAME already-verified,
--- already-shipped per-breed table client/movement.lua's K9Sit() action
--- uses (WORLD_DOG_SITTING_SHEPHERD/_ROTTWEILER/_RETRIEVER, itself
--- cross-checked there against two independently maintained scenario
--- dumps agreeing on these exact strings — see that file's own K9Sit()
--- doc comment for the full grading). Duplicated here as a small local
--- table rather than taken as a cross-file dependency on client/movement.lua
--- — mirrors this file's own IsBusyWithSomethingElse() precedent just
--- above for the identical "duplicate four guarded calls rather than make
--- one file's internals another file's dependency" tradeoff, and this
--- file's header already states no compile-time dependency on other client
--- files is wanted. CONFIDENCE: HIGH the scenario strings themselves are
--- real (inherited from K9Sit()'s own two-source verification); LOW/NONE
--- that "sitting" is the semantically ideal pose for "actively searching" —
--- an alert, stationary sit reads reasonably as "the dog has stopped to
--- focus on something" and, critically, is not a fabricated name, so it
--- either looks fine or (worst case) looks slightly odd — never silently
--- does nothing. FOLLOW-UP flagged in this pass's own report: get
--- native-api-assistant (or a session with real access to those two dumps)
--- to confirm a genuine sniff/investigate scenario before treating this as
--- final.
--- @type table<number, string>
local K9_SEARCH_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists (same substitution K9Sit() already makes)
    a_c_husky = 'WORLD_DOG_SITTING_RETRIEVER', -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit (same substitution K9Sit() already makes)
}) do
    K9_SEARCH_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_SEARCH_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD' -- fallback if playing an unmapped/future Config.Peds model, same posture as K9Sit()'s own default

--- Resolves the search scenario for the LOCAL player's CURRENT ped model —
--- called fresh at the top of every PerformSearch() call (not cached),
--- mirroring K9Sit()'s own per-call GetEntityModel() read, since a player's
--- ped model can change between searches (breed swap, appearance change)
--- and this must never play a stale scenario for a model the player no
--- longer has.
--- @return string
local function ResolveSearchScenario()
    local ped = PlayerPedId()
    return K9_SEARCH_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_SEARCH_DEFAULT_SCENARIO
end
--- ======================================================================

--- Shared implementation behind the two ox_target options below. Plays the
--- sniff animation/progress bar, awaits the server's authoritative result,
--- and renders feedback — never computes or guesses a result itself. Kept
--- as one function rather than two near-duplicate copies for the same
--- "textually identical acceptance criteria" reason client/tracking.lua's
--- StartTrack() helper documents for its own three callers.
--- @param targetType 'vehicle'|'person'
--- @param targetEntity number  -- resolved live entity handle from the ox_target callback's own `data.entity`
local function PerformSearch(targetType, targetEntity)
    -- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission
    -- audit finding, this pass): server/search.lua's searchTarget callback
    -- gates on `HasK9Access(source)` alone -- confirmed by reading it
    -- directly (both the initial check and the mid-flight re-check after
    -- the awaited ox_inventory call), no model/role check on the searching
    -- K9 anywhere in that callback. This used to gate on the broader
    -- CanShowK9UI(), silently withholding search from a High Command/
    -- autoAccessGrade-bypass holder the server would happily serve. Known
    -- reason -> 'combat.no_access', the house-standard "not certified"
    -- string, matching what this exact boolean failing actually means
    -- server-side.
    --
    -- Defensive re-check, same posture as every other gated action in this
    -- resource; canInteract below is a DISPLAY optimization only, the
    -- server independently re-validates HasK9Access(source) regardless
    -- (§11.4 item 2 step 3 per the contract note).
    if not HasK9Access() then
        DenyK9UIAccess('combat.no_access')
        return
    end

    -- Silent, routine double-click protection, not an error state worth a
    -- notification (mirrors DEVELOPER_REFERENCE.md#contraband-search
    -- §4's own "Rejection UX note" recommendation for
    -- on_cooldown/search_in_progress being low-key, not error-styled).
    if searchInProgress then return end

    -- MUTUAL GUARD, this file's half. UNLIKE the double-click case above
    -- this DOES get a message: being refused because your dog is currently
    -- biting someone, or is strapped into a car, is not routine traffic --
    -- it is a real reason the player can act on, and silence would read as
    -- the button being broken.
    --
    -- The progress bar's own `disable = { combat = true }` below is NOT
    -- this check and never was: that disables game CONTROLS for the
    -- bar's duration, which does nothing about this resource's own
    -- keybind-driven RequestBiteHold/RequestDrag (a registered command, not
    -- a game control) and nothing at all about a search STARTED while a
    -- bite is already running -- the direction this branch covers.
    local busy, reasonKey = IsBusyWithSomethingElse()
    if busy then
        lib.notify({ title = locale('common.notify_title'), description = locale(reasonKey), type = 'error' })
        return
    end

    if not DoesEntityExist(targetEntity) then
        lib.notify({ title = locale('common.notify_title'), description = locale('search.nothing_to_search'), type = 'error' })
        return
    end

    -- Resolve the netId NOW, before the sniff animation, not after. Entity
    -- handles get recycled once an entity is deleted/streamed out — if we
    -- held targetEntity raw across the full sniffAnimDurationMs delay and
    -- converted it only at the end, a target that disconnects/despawns
    -- mid-animation could have its handle reassigned to an unrelated
    -- entity by the time we call NetworkGetNetworkIdFromEntity, silently
    -- searching (and potentially broadcasting a contraband alert about)
    -- the wrong person/vehicle. Capturing it here, while targetEntity is
    -- still known-fresh from the ox_target callback that just fired,
    -- closes that window.
    local targetNetId = NetworkGetNetworkIdFromEntity(targetEntity)

    searchInProgress = true

    -- SEARCH SCENARIO (this pass) — see this file's own "SEARCH SCENARIO"
    -- section above ResolveSearchScenario() for the full verification
    -- writeup (what was tried, what confidence grading applies, and why
    -- this reuses K9Sit()'s already-verified WORLD_DOG_SITTING_* table
    -- instead of guessing a new name). Routed through lib.progressBar's OWN
    -- built-in `anim.scenario` field (confirmed against ox_lib's real
    -- resource/interface/client/progress.lua source: `TaskStartScenarioInPlace`
    -- is called once at the START of the bar, and — regardless of WHICH
    -- exit condition ends the bar's own `while progress do ... end` loop
    -- (a clean completion, canCancel, or an interruptProgress() hit for
    -- death/ragdoll/cuffed/falling/swimming, since useWhileDead = false
    -- below is exactly what makes death count as an interrupt) — the
    -- SAME code path unconditionally runs `ClearPedTasks(cache.ped)`
    -- immediately after that loop ends, before lib.progressBar ever
    -- returns) rather than this file calling TaskStartScenarioInPlace/
    -- ClearPedTasksImmediately directly, which would either fight ox_lib's
    -- own call or double it. This is what satisfies "cancelled/cleaned up
    -- on every exit path" for the search-cancelled, player-moved
    -- (movement itself is disabled for the bar's duration via
    -- `disable.move` below, so this can only mean the canCancel keybind),
    -- and player-died-mid-search cases; the resource-stopped case is NOT
    -- covered by ox_lib's own loop (that loop runs as a coroutine inside
    -- THIS resource's own Lua state, per `@ox_lib/init.lua` being a
    -- shared_script here rather than a separate resource's export — a stop
    -- of this resource kills that coroutine before it ever reaches its own
    -- post-loop cleanup) — see the dedicated onResourceStop handler this
    -- pass adds near this file's other AddEventHandler calls for that one
    -- remaining exit path.
    local completed = lib.progressBar({
        duration = Config.SearchZones.sniffAnimDurationMs,
        label = targetType == 'vehicle' and locale('search.progress_vehicle_label') or locale('search.progress_person_label'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
        anim = { scenario = ResolveSearchScenario() },
    })

    if not completed then
        searchInProgress = false
        return -- player cancelled/moved away mid-sniff; no server call made at all
    end

    -- Everything from the awaited callback through the result-rendering
    -- notifies below is wrapped in pcall so a throw anywhere in that span
    -- (the callback itself, or anything after it) can never leave
    -- searchInProgress stuck permanently true — mirrors the "always
    -- release/reset on every exit, success or error" posture
    -- server/search.lua's own SearchMutex already follows. searchInProgress
    -- is reset exactly once, unconditionally, after this pcall regardless
    -- of which branch inside it ran or whether it threw.
    local ok = pcall(function()
        local result = lib.callback.await('john-k9:server:searchTarget', K9_CALLBACK_TIMEOUT_MS, targetType, targetNetId)

        if not result or not result.ok then
            local reason = result and result.reason

            if reason == 'search_failed' then
                -- Kept structurally distinct from a clean result — NEVER the
                -- same copy as contrabandFound = false, per this file's
                -- EVENT/CALLBACK CONTRACT above.
                lib.notify({ title = locale('common.notify_title'), description = locale('search.failed'), type = 'error' })
            elseif reason == 'on_cooldown' then
                -- SPEAKS UP HERE, unlike this resource's usual silent
                -- cooldown convention, and the difference is deliberate.
                -- That convention exists for an INSTANT refusal: you press
                -- a key, nothing happens, and the absence of a response is
                -- itself readable. This refusal arrives only AFTER the
                -- player has already stood through the full
                -- sniffAnimDurationMs progress bar with their movement
                -- disabled -- the cost is already paid by the time the
                -- server answers. Saying nothing then means the dog
                -- visibly searched and produced no result at all, which is
                -- indistinguishable from a broken feature and reads as one.
                --
                -- Kept LOW-KEY rather than error-styled ('inform', not
                -- 'error'), which is the part of the convention that still
                -- applies: a cooldown is a normal rhythm of using the
                -- feature, not a mistake the player made.
                lib.notify({ title = locale('common.notify_title'), description = locale('search.on_cooldown_after_search'), type = 'inform' })
            elseif reason == 'search_in_progress' then
                -- Same reasoning as on_cooldown immediately above: paid for
                -- with a four-second animation, so it gets an answer. Named
                -- separately because it is a different fact -- another
                -- search is already running, which no amount of waiting out
                -- a cooldown explains.
                lib.notify({ title = locale('common.notify_title'), description = locale('search.already_searching_after_search'), type = 'inform' })
            elseif reason == 'too_far' then
                lib.notify({ title = locale('common.notify_title'), description = locale('search.too_far_denied'), type = 'error' })
            elseif reason == 'feature_disabled' then
                lib.notify({ title = locale('common.notify_title'), description = locale('search.feature_disabled_denied'), type = 'error' })
            elseif reason == 'invalid_target' then
                lib.notify({ title = locale('common.notify_title'), description = locale('search.invalid_target_denied'), type = 'error' })
            elseif reason == 'no_access' then
                lib.notify({ title = locale('common.notify_title'), description = locale('search.no_access_denied'), type = 'error' })
            elseif reason == 'access_revoked' then
                lib.notify({ title = locale('common.notify_title'), description = locale('search.access_revoked_denied'), type = 'error' })
            else
                -- A genuinely unrecognized/missing reason (or a future server
                -- value this file hasn't been taught yet): the one remaining
                -- generic catch-all. Every REAL, currently-documented reason
                -- above now names itself in plain English instead of
                -- collapsing into this bucket — see this file's header
                -- "UX PASS" note.
                lib.notify({ title = locale('common.notify_title'), description = locale('search.generic_denied'), type = 'error' })
            end

            return
        end

        -- Render feedback purely from result.contrabandFound / result.totalWeight
        -- (private to this requester, per §11.4 item 2 — "returned ONLY to the
        -- requesting caller... never broadcast").
        if result.contrabandFound then
            -- Local success feedback for the requester only. The
            -- bystander-audible broadcast alert (if Config.Features.ContrabandAlerts)
            -- is a SEPARATE thing server/search.lua triggers independently (see
            -- this file's header's RESOLVED note on which event backs it) —
            -- this function does not (and per §11.4 item 2's "never broadcast"
            -- language, must NOT) trigger any broadcast itself from the client
            -- side.
            lib.notify({
                title = locale('common.notify_title'),
                description = locale('search.contraband_found'),
                type = 'success',
            })
        else
            -- Explicit, NON-SILENT "nothing found" notification beat — per
            -- DEVELOPER_REFERENCE.md#contraband-search §5's explicit
            -- requirement ("the requester's own client must render some
            -- explicit 'nothing found' feedback... this doesn't need a server
            -- broadcast at all, since it's private feedback to the one client
            -- who asked and already has the answer in hand"). Do NOT leave
            -- this case silent.
            lib.notify({
                title = locale('common.notify_title'),
                description = locale('search.nothing_found'),
                type = 'info',
            })
        end
    end)

    if not ok then
        -- Same "search could not be completed" copy as the search_failed
        -- branch above — from the player's perspective an unhandled throw
        -- mid-search is indistinguishable from the server reporting
        -- search_failed, so it gets the same non-silent, distinct-from-
        -- "nothing found" treatment.
        lib.notify({ title = locale('common.notify_title'), description = locale('search.failed'), type = 'error' })
    end

    searchInProgress = false
end

-- "Search Vehicle" / "Search Person" target options — ROUTED THROUGH
-- K9Compat.Get('target') (shared/compat/target.lua), never a direct
-- `exports.ox_target` call — both canInteract/onSelect pairs below are
-- unchanged (still authored against ox_target's own convention), so an
-- operator running a different supported target script gets both options
-- translated automatically instead of losing them outright.
--
-- LIFECYCLE FIX: pulled into a named function so both can be re-run any
-- time the resource actually backing the 'target' system (re)starts, not
-- just once at this file's own load time. Every supported target script
-- keeps its own addGlobalVehicle/addGlobalPlayer-equivalent registries in
-- plain file-local Lua tables inside its OWN client chunk, cleared only by
-- that resource's own `onClientResourceStop` handler when the CALLING
-- resource (this one) stops — a bare restart of that resource while this
-- resource keeps running reloads that chunk with empty tables and nothing
-- else asks anyone to re-register. See the `AddEventHandler` immediately
-- below for the two triggers this now dispatches on, mirroring
-- server/tracking.lua's RegisterScentInventoryHook fix for the identical
-- bug class against ox_inventory. DUPLICATE-VS-REPLACE: both options below
-- always set `name`, and every adapter's own registration primitive
-- dedups/replaces by that same name (or label, per
-- shared/compat/target.lua's own per-adapter notes), so re-running this
-- never duplicates either entry.
local function RegisterSearchOxTargetOptions()
    -- "Search Vehicle" target option (K9Compat.Get('target').AddGlobalVehicle,
    -- mirroring client/vehicle.lua's existing AddGlobalVehicle registration
    -- shape exactly) — name 'john-k9:searchVehicle'. canInteract is a
    -- DISPLAY optimization only per DEVELOPER_REFERENCE.md §3/§4.5, same "not the security
    -- boundary" framing client/vehicle.lua's own header already documents for
    -- its enterVehicle option, since server/search.lua independently
    -- re-verifies everything (§11.4 item 2).
    K9Compat.Get('target').AddGlobalVehicle({
        {
            name = 'john-k9:searchVehicle',
            -- ROLE ICON: 'fas fa-dog' for every ox_target option only ever
            -- shown while the local player's own ped IS the K9
            -- (CanShowK9UI() below) — the same icon client/vehicle.lua's
            -- enter/exit-vehicle options and client/kennel.lua's
            -- pickup-kennel option already use, standardized on here rather
            -- than the unrelated magnifying-glass this option used before,
            -- so every K9-role option reads as one consistent visual family
            -- regardless of which specific action it performs.
            icon = 'fas fa-dog',
            label = locale('search.vehicle_target_label'),
            distance = Config.SearchZones.vehicleSearchDistance,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.SearchZones then return false end
                -- NEVER SHOW AN OPTION THAT WILL JUST REFUSE: while a search
                -- (this one or the other option) is already awaiting the
                -- server, selecting this again is a guaranteed silent no-op
                -- (searchInProgress guard inside PerformSearch above) — hide
                -- it for that window instead of leaving it visible but inert.
                -- Display-only, same as every other check in this predicate:
                -- PerformSearch's own defensive re-check and the server's
                -- independent mutex are what actually enforce this.
                if searchInProgress then return false end
                -- Same "never show an option that will just refuse"
                -- reasoning, for the MUTUAL GUARD above. Display-only:
                -- PerformSearch re-checks it defensively regardless.
                if (IsBusyWithSomethingElse()) then return false end
                -- Widened to HasK9Access() alone -- see PerformSearch's own
                -- header comment above for the full writeup.
                return HasK9Access()
            end,
            onSelect = function(data)
                PerformSearch('vehicle', data.entity)
            end,
        },
    })

    -- "Search Person" target option (K9Compat.Get('target').AddGlobalPlayer,
    -- mirroring client/movement.lua's existing AddGlobalPlayer registrations,
    -- e.g. its "Attach Leash" option's shape) — name 'john-k9:searchPerson'.
    -- Self-exclusion (NetworkGetPlayerIndexFromPed(entity) ~= PlayerId()) is a
    -- low-stakes UX judgment call, not addressed one way or the other by
    -- DEVELOPER_REFERENCE.md §11 — mirrors the self-exclusion already established for the
    -- leash and certify/revoke target options in client/movement.lua;
    -- server/search.lua's own proximity + entity-type checks make a
    -- self-search harmless even if attempted.
    -- Ped/NPC variant (non-player peds) is an explicit STRETCH item per §11.3
    -- — no addGlobalPed/AddModel registration added here, since
    -- server/search.lua's contract only validates a real connected player's
    -- ped for targetType == 'person'.
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'john-k9:searchPerson',
            -- ROLE ICON: same 'fas fa-dog' as "Search Vehicle" above and
            -- every other CanShowK9UI()-gated ox_target option across this
            -- resource (settled resource-wide scheme: fa-dog = K9-role,
            -- fa-user-tie = a separate human acting on/for a K9,
            -- fa-handshake = partnership, fa-id-badge = high
            -- command/credentialing) — this option is a PLAYER target.
            icon = 'fas fa-dog',
            label = locale('search.person_target_label'),
            distance = Config.SearchZones.personSearchDistance,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.SearchZones then return false end
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't search self
                -- Same "never show an option that will just refuse" fix as
                -- "Search Vehicle" above: selecting this while ANY search
                -- (either option) is already in flight is a guaranteed
                -- silent no-op (searchInProgress inside PerformSearch), so
                -- hide it for that window instead of leaving it clickable.
                if searchInProgress then return false end
                -- Same "never show an option that will just refuse"
                -- reasoning, for the MUTUAL GUARD above. Display-only:
                -- PerformSearch re-checks it defensively regardless.
                if (IsBusyWithSomethingElse()) then return false end
                -- Widened to HasK9Access() alone -- see PerformSearch's own
                -- header comment above for the full writeup.
                return HasK9Access()
            end,
            onSelect = function(data)
                PerformSearch('person', data.entity)
            end,
        },
    })
end

-- RESOURCE-STOP CLEANUP (this pass, coder-frontend) — the one exit path
-- lib.progressBar's own anim.scenario cleanup (see PerformSearch's own
-- SEARCH SCENARIO comment above) does NOT cover on its own: a stop of THIS
-- resource kills the coroutine running that bar's `while progress do ... end`
-- loop (and everything else in this resource's own Lua state — ox_lib is
-- pulled in via `@ox_lib/init.lua` in shared_scripts, i.e. it runs INSIDE
-- this resource, not as a separate resource's export) before it ever
-- reaches its own post-loop `ClearPedTasks` call, same "sticky native state
-- must be reversed on stop" class of bug client/movement.lua's own
-- onResourceStop handler already exists to prevent for
-- isFirstPersonK9View — mirrored here for the identical reason. Only acts
-- while `searchInProgress` is true, so a normal resource stop between
-- searches costs nothing. GTA's own scenario-task-on-a-player-ped behavior
-- (documented at K9_SEARCH_SCENARIO_BY_MODEL_HASH's own declaration
-- comment: it self-cancels the instant the player provides movement input)
-- would eventually self-correct even without this, since a stopped
-- resource can no longer disable movement controls either — this handler
-- just closes the gap immediately instead of leaving it to the player's
-- next footstep.
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if searchInProgress then
        ClearPedTasksImmediately(PlayerPedId())
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterSearchOxTargetOptions()
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
        RegisterSearchOxTargetOptions()
    end
end)

-- Bystander-audible contraband alert broadcast receiver. Mirrors
-- client/main.lua's existing playBark handler exactly (resolve the network
-- entity, no-op if not streamed in, play a sound) — see this file's header
-- for why the receive side lands here rather than in client/main.lua
-- (server/search.lua's own header explicitly assigns it to this file).
-- `alertTier` is one of Config.ContrabandAlertTiers' `alert` strings (e.g.
-- 'whine' / 'aggressive_bark') — deliberately never the requester's private
-- totalWeight/contrabandFound (those never leave the callback above).
RegisterNetEvent('john-k9:client:playContrabandAlert', function(netId, alertTier)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's own "SOURCE-ORIGIN
    -- GUARD" header block for the full sourced writeup/confidence grading,
    -- not re-derived here). Cosmetic-only payoff (a forged call just plays
    -- a sound naming an arbitrary alertTier string at an arbitrary netId),
    -- applied for resource-wide consistency with every other
    -- `john-k9:client:*` handler, not because this one carries real
    -- exploit severity on its own.
    if source ~= 65535 then return end
    -- Reuses the same placeholder sound-bank plumbing client/main.lua's
    -- playBark handler already establishes (DEVELOPER_REFERENCE.md §7: bark/alert audio
    -- needs bundled asset files that don't exist in this resource yet;
    -- PlaySoundFromEntity with an unrecognized sound name/set is a harmless
    -- no-op, not an error, so this is safe to ship ahead of real assets).
    -- `alertTier` is passed straight through as the sound name — 'clean'
    -- deliberately produces no meaningful sound today (no asset mapped),
    -- which is fine since a 'clean' result's requester-side feedback is
    -- already fully covered by PerformSearch()'s own local notify above;
    -- whether 'clean' should ALSO broadcast for bystander symmetry is a
    -- server/search.lua decision (DEVELOPER_REFERENCE.md#contraband-search §5), not
    -- something this receiver needs to special-case either way.
    PlaySoundOnNetworkEntity(netId, alertTier)
end)
