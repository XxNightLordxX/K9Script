--[[
    qbx_k9unit/client/main.lua

    Phase 1 scaffold only. REWRITTEN after DEVELOPER_REFERENCE.md's
    post-draft correction. Owns the two building-block checks every other
    client file gates on — "is my own character a K9 model" (display-only,
    client-side) and "does the server say I have K9 access" (the real
    security boundary) — plus the combinator both radial.lua and
    vehicle.lua should call before showing/allowing anything. Also owns
    the bark-playback receiver, since it's about the K9 ped/entity in
    general rather than any one specific subsystem (movement/radial/vehicle).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1 (full copy; see
    server/certifications/ for the most detailed version of this same
    block):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [server/certifications/]
       job.name ∈ Config.Departments AND active cert for that job (or
       autoAccessGrade bypass). Does NOT check ped model (§4.1/§4.5) —
       model is a grant-time-only check server-side, and a display-only
       self-check client-side (see IsOwnModelK9() below).

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [server/certifications/]
    3. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [server/certifications/]
    4. 'qbx_k9unit:server:relayBark' (barkType: string) [server/main.lua]
       Triggered from client/radial.lua's Bark item — no netId argument,
       the server resolves the sender's own ped.

    Client events (RegisterNetEvent, server->client):
    5. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [THIS FILE]

    Commands: both live in server/certifications/.

    REMOVED from the original (pre-correction) scaffold — do not
    resurrect: ped-selection context menu, SpawnK9/DespawnK9,
    GetCurrentK9/SetCurrentK9/ClearCurrentK9 "current K9" state,
    'qbx_k9unit:server:requestSpawnK9' callback,
    'qbx_k9unit:server:registerK9'/'unregisterK9' events,
    'qbx_k9unit:client:despawnK9' event. There is no ped to select, spawn,
    register, or despawn — the K9 player plays their own persistent
    character at all times (DEVELOPER_REFERENCE.md §1, §2).
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes three resource-global (no `local`) functions,
      used by client/movement.lua, client/radial.lua, and client/vehicle.lua,
      PLUS ResolveNetworkEntity() (see its own doc comment near
      PlaySoundOnNetworkEntity below — DEVELOPER_REFERENCE.md near-term item 2),
      PLUS ResolvePlayerServerIdFromPed() and IsEntityModelK9() (see their
      own doc comments below — DEVELOPER_REFERENCE.md item 2b and item 3
      respectively):
        IsOwnModelK9() -> boolean
            Pure local check (GetEntityModel(PlayerPedId()) against
            Config.Peds) — display-only, per §4.5, never treat this as a
            security boundary.
        HasK9Access() -> boolean
            Awaits the 'qbx_k9unit:server:hasK9Access' callback for the
            LOCAL player. This is a real network round-trip; per DEVELOPER_REFERENCE.md
            §4.1 ("checked... on every access point... not just once") it
            must be re-awaited at each point of use, not cached forever —
            but DOES cache it briefly (HAS_K9_ACCESS_CACHE_TTL_MS/
            hasK9AccessCache below, already implemented, not a pending TODO)
            so a hot call site like an ox_target `canInteract` predicate
            (which can run many times a second while hovering) doesn't
            flood the server.
        CanShowK9UI() -> boolean
            ROLE/MODEL DECOUPLING (client/appearance.lua): with
            Config.K9Appearance.requireK9ModelForRole at its false default,
            this is IsK9Role() and HasK9Access() — IsK9Role()
            (client/appearance.lua) is the server-authoritative "do I hold
            the K9 role right now" check (active certification for my job,
            OR an active 'k9.access' permission grant — see
            server/appearance.lua's header for why that's the right
            definition), deliberately NOT a model check, so a K9-role
            player on an unlisted or even human model still sees every K9
            UI element. With requireK9ModelForRole = true (or if
            client/appearance.lua somehow isn't loaded), this is
            IsOwnModelK9() and HasK9Access(). THIS is the function
            radial.lua/vehicle.lua/movement.lua should actually call for
            their gating decisions — don't call the other two directly
            from other files, so the "how do we combine these" policy
            lives in exactly one place.
      NOTE: server/certifications/ also exposes a function named
      `HasK9Access(source)`, on the SERVER side. These are different Lua
      VMs (client vs. server) so there's no actual name collision — the
      shared name is intentional, for readability (same concept, mirrored
      API), not a shared symbol.

    OPEN QUESTION (not decided here): does the first/third-person
    eye-height camera toggle (DEVELOPER_REFERENCE.md §6.1 bullet 2)
    and native run/jump/crouch (bullet 3) need to be gated by CanShowK9UI()
    at all, or are they baseline behavior available to anyone playing a
    K9-model character regardless of job/cert (the game already gives any
    ped model its native locomotion for free; gating a QoL camera toggle
    behind certification arguably adds friction without protecting
    anything, since the player is visibly a dog either way)? This
    scaffold's lean: do NOT gate camera/locomotion behind CanShowK9UI(),
    only gate the radial menu (leash/vehicle/bark, which are the actual
    granted capabilities) — but this is a judgment call, not a spec
    mandate; flag disagreement rather than silently building it the other
    way.
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
--- Precomputed set of Config.Peds model hashes, built once at file load.
--- Mirrors server/certifications/'s K9ModelHashes approach so both
--- sides stay generic over the config (DEVELOPER_REFERENCE.md §3 acceptance bullet 3) —
--- no hardcoded model name anywhere, including custom streamed entries.
local K9ModelHashes = {}
for _, pedEntry in ipairs(Config.Peds) do
    K9ModelHashes[GetHashKey(pedEntry.model)] = true
end

--- Is `entity`'s current model one of Config.Peds' recognized K9 models?
--- Client-side, display/targeting-plausibility only — NEVER a security
--- boundary; every server-side handler that cares about a target's real
--- model re-derives it itself (IsConfiguredK9Model, server/certifications/).
---
--- DEVELOPER_REFERENCE.md item 3. Promoted from client/movement.lua's local
--- `IsEntityModelK9`/`k9ModelHashesForTargeting` pair (which already had
--- this exact signature) to a resource-global here, reusing THIS file's
--- own `K9ModelHashes` table above rather than building a second,
--- identical one — this same boolean model-recognition table was
--- previously independently hand-copied 6 times across this resource
--- (client/main.lua, client/movement.lua, client/wellbeing.lua,
--- client/medkit.lua, client/inventory.lua, and client/partnership.lua —
--- this last one a previously untracked 6th instance found only while
--- consolidating the other five). This is now fully done: the
--- client/movement.lua/client/wellbeing.lua/client/medkit.lua copies were
--- deleted, and the client/inventory.lua and client/partnership.lua copies
--- were deleted too, once each was re-read and confirmed byte-identical in
--- behavior (same Config.Peds-driven model set, no extra guard/nil-check
--- divergence) — see those two files' own call sites for the direct
--- `IsEntityModelK9(entity)` calls that replaced them. Zero duplicate
--- copies of this check remain anywhere in `client/` as of this comment;
--- if a new one appears, update this count rather than letting it go
--- unrecorded again.
--- server/certifications/'s server-side `K9ModelHashes` is correctly
--- left alone per the roadmap's own note — a resource-global here can't
--- cross the client/server realm boundary.
--- @param entity number
--- @return boolean
function IsEntityModelK9(entity)
    return K9ModelHashes[GetEntityModel(entity)] == true
end

--- Client-side, display-only check: does the LOCAL player currently count
--- as a K9 for gating purposes? Still never used for security — see
--- DEVELOPER_REFERENCE.md §4.5 ("Convenience (client)" bullet) and this doc comment's own
--- audit note below.
---
--- ROLE/MODEL DECOUPLING (client/appearance.lua; the driving requirement:
--- "I also want everything to work with any ped" / "[an unlisted ped]...
--- can still be assigned a k9 role even if its human"): true if EITHER the
--- local player's live ped model is a recognized K9 model (the original,
--- unchanged check — IsEntityModelK9(PlayerPedId())), OR (when
--- Config.K9Appearance.requireK9ModelForRole is at its false default) the
--- server says this player holds the K9 role right now (IsK9Role(),
--- client/appearance.lua — active certification for their job, or an
--- active 'k9.access' permission grant; model-independent by
--- construction). This is a deliberate OR, not a replacement: a player who
--- is genuinely dog-modeled but holds no role at all (an uncertified K9
--- model, or a department outsider who somehow ended up on a K9 skin)
--- still passes via the model half exactly as before — nothing that used
--- to work stops working. `type(IsK9Role) == 'function'` is a genuine soft
--- dependency (client/appearance.lua may not be loaded, or
--- requireK9ModelForRole may be true), not a load-order assumption, this
--- resource's established convention.
---
--- WHY THIS FUNCTION SPECIFICALLY, AND NOT IsEntityModelK9(entity) IN
--- GENERAL: every other caller of IsEntityModelK9 targets SOME OTHER
--- entity (an ox_target canInteract predicate's `entity` parameter, e.g.
--- client/movement.lua's "Attach Leash" option) — this client has no cheap,
--- local way to know a DIFFERENT player's server-side role without a
--- per-target network round trip, so IsEntityModelK9(entity) for anyone but
--- the local player is intentionally left a PURE model guess ("cheap
--- client-side plausibility only... the server independently re-validates
--- everything for real", per those call sites' own comments) — there is
--- one disclosed, residual gap this leaves open (a human-shaped
--- role-holder is not targetable via that specific ox_target predicate by
--- someone else). IsOwnModelK9() is different: "own" always means the
--- LOCAL player, whose role this client CAN cheaply and safely ask about
--- via the same server-backed, TTL-cached callback HasK9Access() already
--- established the pattern for.
---
--- SECURITY AUDIT NOTE: grepped and read every real call site in this
--- resource (client/combat.lua, client/vision.lua, client/movement.lua,
--- client/wellbeing.lua, client/partnership.lua, client/exports.lua, plus
--- this file's own CanShowK9UI() below) — every one of them uses this
--- function's result ONLY for local UI/effect gating (show/hide a radial
--- item, apply/withhold a client-local visual or movement effect, an
--- ox_target predicate's display filter) or, transitively, feeds into
--- CanShowK9UI(), which is documented and used identically. NONE of them
--- treat a `true` result here as authorization for anything a server-side
--- handler doesn't independently re-verify (HasK9Access/HasK9Role/
--- IsConfiguredK9Model, all server-authoritative, all re-derived from live
--- server-side data, never from a client claim). CONFIRMED STILL TRUE:
--- this function is not, and must never become, a security boundary — a
--- modified client returning `true` here unconditionally gains nothing
--- beyond seeing UI it cannot actually use, because every real action
--- re-checks server-side regardless.
--- @return boolean
function IsOwnModelK9()
    if IsEntityModelK9(PlayerPedId()) then return true end

    if Config.K9Appearance and Config.K9Appearance.requireK9ModelForRole == false and type(IsK9Role) == 'function' then
        return IsK9Role()
    end

    return false
end

--- LIVE BUG FIX (owner report: "Keeps on spamming you are not a certified
--- k9 soon as a cop is on and everyone in city cop or not gets it").
---
--- THE BUG. Every K9 keybind in this resource is registered with
--- RegisterKeyMapping, and several of the default keys collide with
--- controls that EVERY player on the server presses constantly -- 'V' is
--- GTA V's own Change Camera View, 'C' is Look Behind, 'T' opens FiveM
--- chat. FiveM's key mappings do not replace the game's own binding, they
--- fire ALONGSIDE it, so every single player in the city -- civilian,
--- cop, anyone -- was silently running /k9sit and /k9bark dozens of times
--- an hour just by playing normally. Each of those commands ends in
--- DenyK9UIAccess() for anyone who is not a K9, which is a visible ox_lib
--- toast: hence a server-wide, unstoppable stream of "You are not
--- certified for K9 duty". The default keys are being moved off the
--- colliding controls in the same pass, but a key can be REBOUND by any
--- player to anything at all, so moving them is not on its own a fix --
--- this predicate is.
---
--- THE RULE. A refusal toast is correct when a player DELIBERATELY chose
--- a K9 action -- picked it from the radial menu, pressed a button in the
--- tablet, used an ox_target option on a dog. It is never correct for a
--- keypress, because a keypress carries no evidence that a K9 action was
--- what the player meant. So every keybind entry point in this resource
--- asks this first, and returns SILENTLY when the answer is no. Nothing
--- else changes: the radial/tablet/target paths keep their full, specific
--- refusal messages, and a player who genuinely IS a K9 still gets told
--- exactly why a keypress did nothing (their certification lapsed, High
--- Command blocked the ability, the feature is off) because they pass
--- this check and fall through to the real gate underneath.
---
--- CHEAP ON A KEYPRESS, BUT NOT FREE -- and the difference is worth
--- stating precisely, because an earlier version of this comment claimed
--- "no server traffic at all" and that was simply not true.
---
--- This runs on a keypress, which means it can run many times a second for
--- every player on the server at once. Two steps, in this order:
---   1. IsOwnModelK9() -- a pure local model read, no callback, no cache.
---      Whoever is currently wearing the K9 ped stops here.
---   2. client/appearance.lua's IsK9Role() -- which DOES await
---      'qbx_k9unit:server:hasK9Role', behind a 1-second TTL cache.
--- So an ordinary citizen mashing a bound key costs one model comparison
--- plus AT MOST ONE server callback per second, not one per keypress.
---
--- That is the real improvement over the behavior this fixed, where every
--- player in the city awaited 'qbx_k9unit:server:hasK9Access' -- uncached
--- -- on every single keypress, and got a refusal toast for it. One capped
--- callback per second and no toast is a different thing from zero
--- traffic; do not plan on this being free.
---
--- WHY THE TTL IS NOT SIMPLY LONGER: appearance.lua invalidates that cache
--- when the ped model is swapped, which covers becoming or ceasing to be
--- the dog -- but NOT a role granted or revoked server-side without a swap.
--- A longer TTL would leave a freshly-certified player pressing a key that
--- does nothing for the length of it. One second is the compromise.
---
--- NOT A SECURITY BOUNDARY, same as IsOwnModelK9() above -- it decides
--- whether to show a message, nothing more. Every action reached past it
--- still runs its own real CanShowK9UI()/HasK9Access() gate, and the
--- server re-authorizes independently regardless.
---
--- NEVER APPLIED TO A STOP/EXIT KEYBIND. 'k9exitkennel' (client/keybinds.lua)
--- deliberately does NOT consult this, per this resource's standing "gate
--- the START of a thing, never the STOP" rule -- it is already silent for
--- a player who is not resting in a kennel, so it was never part of this
--- bug in the first place.
--- @return boolean
function IsK9KeybindAudience()
    if IsOwnModelK9() then return true end
    return type(IsK9Role) == 'function' and IsK9Role() == true
end

-- Lightweight TTL cache for HasK9Access() below. Hot call sites (ox_target
-- canInteract predicates in client/vehicle.lua and client/movement.lua's
-- leash option in particular) can run several times a second while
-- hovering — without this, each of those would re-await the server
-- callback on every frame. ~1000ms keeps "checked... not just once"
-- (DEVELOPER_REFERENCE.md §4.1) true in spirit: this is a debounce, not a permanent
-- cache, and every gated server-side action independently re-verifies
-- access regardless of what this cache currently believes.
local HAS_K9_ACCESS_CACHE_TTL_MS = 1000
local hasK9AccessCache = { value = false, checkedAt = -HAS_K9_ACCESS_CACHE_TTL_MS }

--- Awaits the server's authoritative access check for the LOCAL player.
---
--- FAIL-CLOSED GUARD (confirmed by reading the real upstream source
--- directly): `lib.callback.await` does NOT return nil on a timeout or an
--- unregistered-callback response — ox_lib's `imports/callback/client.lua`
--- `triggerServerCallback` calls `promise:reject(...)` for both the
--- `SetTimeout(callbackTimeout, ...)` timeout path and the `cb_invalid`
--- (callback not registered server-side yet) path, and FiveM's own
--- `scheduler.lua` `Citizen.Await` THROWS (`error(promise.value, 2)`)
--- whenever `promise.state == 2 or promise.state == 4` (a rejected
--- promise) rather than returning its value. An uncaught throw here would
--- previously abort the calling thread entirely with no access decision at
--- all — this is a hot call site (ox_target canInteract predicates,
--- client/movement.lua's leash option), so pcall it and fail closed (deny)
--- on any throw.
--- @return boolean
--- The last answer HasK9Access() got from the server, WITHOUT asking again
--- (never yields). nil until the first real check. The K9 menu uses it to
--- leave out the dog's moves for a dog without access, while building the
--- menu -- the click itself still asks HasK9Access() properly.
--- @return boolean?
function HasK9AccessCached()
    if type(hasK9AccessCache.checkedAt) ~= "number" or hasK9AccessCache.checkedAt < 0 then return nil end
    return hasK9AccessCache.value
end

function HasK9Access()
    local now = GetGameTimer()
    if (now - hasK9AccessCache.checkedAt) < HAS_K9_ACCESS_CACHE_TTL_MS then
        return hasK9AccessCache.value
    end

    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:hasK9Access', K9_CALLBACK_TIMEOUT_MS)
    if not ok then
        -- Deliberately does NOT write to hasK9AccessCache: a timeout/
        -- cb_invalid throw is transient (server hiccup, resource restart
        -- mid-boot), and caching a false negative here would deny K9
        -- access for the FULL HAS_K9_ACCESS_CACHE_TTL_MS even after the
        -- server call would have succeeded again a moment later. Leaving
        -- `checkedAt` untouched (still stale from before this attempt)
        -- means the very next call re-attempts the awaited callback
        -- immediately instead of serving a stuck denial from a poisoned
        -- cache. Every gated server-side action re-verifies access
        -- independently regardless (see this cache's own declaration
        -- comment above), so returning false here for just this one call
        -- is a display-only fail-closed default, not a security decision.
        return false
    end

    hasK9AccessCache.value = result == true
    hasK9AccessCache.checkedAt = now
    return hasK9AccessCache.value
end

--- Combinator every other client file should call for K9 UI/feature
--- gating decisions. See FILE-TO-FILE CONTRACT above for the full
--- ROLE/MODEL DECOUPLING writeup on the CanShowK9UI() entry.
---
--- `type(IsK9Role) == 'function'` is a genuine soft dependency, not a
--- load-order assumption (this resource's established convention) —
--- client/appearance.lua defines it, and this file has no hard
--- requirement on loading after it. Falls back to the pre-decoupling
--- IsOwnModelK9()-based formula whenever requireK9ModelForRole is true OR
--- IsK9Role isn't available for any reason, so this never regresses
--- behavior for an operator who explicitly wants the stricter,
--- model-enforced mode.
--- @return boolean
function CanShowK9UI()
    if Config.K9Appearance and Config.K9Appearance.requireK9ModelForRole == false and type(IsK9Role) == 'function' then
        return IsK9Role() and HasK9Access()
    end
    return IsOwnModelK9() and HasK9Access()
end

--- Shared denial notification for "you cannot use this K9 feature right
--- now" refusals. This exact lib.notify() call was previously duplicated
--- verbatim across client/radial.lua, client/search.lua,
--- client/vehicle.lua, client/movement.lua, and client/tracking.lua. All
--- five have since been migrated to call this shared function directly.
--- RE-VERIFIED (by grepping for the raw `common.no_k9_access` locale key
--- across all of client/): zero raw copies remain anywhere. If a new raw
--- copy is ever reintroduced, re-flag it here rather than assuming this
--- stays true forever. Declared as a bare global here per this file's own
--- established "declare once, reuse everywhere" convention (see
--- CanShowK9UI/IsOwnModelK9 above).
---
--- REASON PARAMETER (ease-of-use audit finding, this pass): this is by far
--- the most-hit refusal in the resource — ~105 call sites across 28 client
--- files, 28 of them in client/radial.lua alone — and until now every one
--- of them showed the SAME generic `common.no_k9_access` sentence
--- ("You cannot use K9 features right now.") regardless of why: a civilian
--- clicking a radial icon out of curiosity, a K9 whose certification lapsed
--- mid-shift, and an officer in the wrong department all read the identical
--- text, with no hint of why or what to do next. `combat.no_access`
--- ("You are not certified for K9 duty -- ask a certifying officer to
--- certify you.") is this resource's own existing example of the same
--- refusal done right — this parameter lets a caller that ALREADY KNOWS
--- why (it just tested a specific gate before calling this) route to that
--- kind of specific, actionable string instead.
---
--- `reasonLocaleKey` is an OPTIONAL, ALREADY-RESOLVED locale key (not raw
--- text) — this function does the `locale()` lookup itself, exactly like
--- every other string this function has always shown. Two conventions this
--- resource's own call sites now follow (see client/radial.lua's own
--- per-item comments for which items know which):
---   - a caller that checked `HasK9Access()` directly (not the broader
---     `CanShowK9UI()` combinator) and got `false` KNOWS the specific cause
---     is "not currently a certified/access-granted K9" — pass
---     `'combat.no_access'`, the same house-standard string
---     server/combat.lua's own rejection path already uses for this exact
---     cause, rather than minting a duplicate.
---   - a caller that checked the broader `CanShowK9UI()` combinator (role
---     AND access — it cannot tell which half failed) should pass
---     `'common.no_k9_role_or_access'` — still strictly more specific than
---     the bare fallback below, and never factually wrong: EVERY
---     `CanShowK9UI() == false` case really does mean "not currently an
---     on-duty, access-granted K9 handler," regardless of which of the two
---     ANDed conditions was the actual cause. A WRONG specific reason is
---     worse than a vague one (this pass's own guiding rule) — so a caller
---     that cannot narrow it down further than that must never guess past
---     what it actually verified.
--- Any other/omitted value falls back to `common.no_k9_access_unknown`, an
--- upgraded generic default that — unlike the original bare
--- `common.no_k9_access` (kept verbatim; server/vehicle.lua,
--- and this file's own tablet help text quote it
--- unrelated to this function and must not drift) — still names a concrete
--- next step for a genuinely unclassified refusal.
--- @param reasonLocaleKey string? -- an already-valid locale() key for a caller that knows the specific reason; omit to use the improved generic fallback
function DenyK9UIAccess(reasonLocaleKey)
    local description = (type(reasonLocaleKey) == 'string' and reasonLocaleKey ~= '')
        and locale(reasonLocaleKey)
        or locale('common.no_k9_access_unknown')
    lib.notify({ title = locale('common.notify_title'), description = description, type = 'error' })
end

-- Placeholder sound reference. DEVELOPER_REFERENCE.md §7 flags that "bark sounds" need
-- bundled audio asset files (bark .ogg/.wav) that do not exist anywhere in
-- this resource yet, and that there's no native "make this canine ped
-- emit a bark voice line" the way human ped speech works — this is not a
-- zero-asset feature. The full playback path (network entity resolution +
-- native call) is wired for real below so dropping in a real sound bank
-- later is a one-line constant change, not new plumbing; until a real
-- asset/soundset exists, PlaySoundFromEntity with an unrecognized sound
-- name/set is a harmless no-op (it does not error), so this is safe to
-- ship as-is rather than gating the whole handler out. Real audio files,
-- once available, ship under html/sounds/ (see html/sounds/CREDITS.md for
-- the provenance/licensing convention already established there).
local BARK_SOUND_NAME = 'Bark'

--- Shared placeholder sound-bank name for every bark/alert-style sound
--- played on a network-resolved entity in this resource (this file's own
--- playBark handler below, and client/search.lua's contraband-alert
--- handler). Not a real shipped soundset yet — see the comment above.
local K9_SOUND_SET = 'qbx_k9unit_sounds'

--- Phase 5 (Config.Features.AdvancedBarkRadial, client/radial.lua): maps a
--- specific `barkType` string (config.lua's Config.AdvancedBarkRadial —
--- DEVELOPER_REFERENCE.md §6.7's "aggressive/alert/calm") to its own placeholder sound
--- name, built once at file load. Still all placeholder audio, same
--- K9_SOUND_SET convention as BARK_SOUND_NAME above —
--- DEVELOPER_REFERENCE.md#phase-5-research confirms a real per-variant soundset
--- needs authored `.awc`/REL audio-bank assets, not just a different string
--- here; this table only carries the plumbing. Built defensively against
--- Config.AdvancedBarkRadial not existing (older configs, or the feature
--- flag simply left off) since this table is populated unconditionally
--- regardless of Config.Features.AdvancedBarkRadial's value.
local BarkTypeSoundNames = {}
for _, variant in ipairs(Config.AdvancedBarkRadial or {}) do
    BarkTypeSoundNames[variant.barkType] = variant.sound
end

--- DEVELOPER_REFERENCE.md near-term item 2 ("resolve network entity
--- defensively" helper — 6 independent hand-written copies, 4 client-side
--- + 2 server-side). Resolves netId to a live, currently-streamed-in
--- entity handle on THIS client, or nil if it doesn't currently resolve to
--- anything real (not streamed in, deleted/recycled, or a bogus id).
---
--- Extracted from what were 3 independent client-side copies of the exact
--- same "NetworkDoesEntityExistWithNetworkId guard ->
--- NetworkGetEntityFromNetworkId -> DoesEntityExist guard" sequence:
--- PlaySoundOnNetworkEntity below (itself already the product of an
--- earlier dedup pass covering this file's playBark handler and
--- client/search.lua's playContrabandAlert handler — see that pass's own
--- comment, kept below for history), client/vehicle.lua's
--- ResolveVehicleFromState, and client/movement.lua's playDoorScratch
--- receiver. All three now call this single function instead. A 4th
--- named copy, client/search.lua's playContrabandAlert handler, already
--- goes through PlaySoundOnNetworkEntity (and therefore, transitively,
--- through this function) rather than resolving netId itself — it never
--- needed its own separate migration.
--- OPTIONAL BOUNDED RETRY. `attempts` defaults to 1, which is the plain
--- single synchronous check every existing caller has always relied on and
--- which never yields -- important, because several callers run this inside
--- per-frame maintenance loops where a Wait() would be wrong.
---
--- Pass a higher number ONLY from a net-event handler that has just been
--- told about an entity by the server. In that specific case a single check
--- can legitimately answer false: the event can arrive a fraction before the
--- entity finishes streaming in to this client, and the caller then treats a
--- perfectly real kennel/vehicle/prop as absent and silently does nothing.
---
--- WHY THIS PARAMETER EXISTS AT ALL: three call sites in client/kennel.lua
--- (the pickup, put-down and enter-kennel confirmations, all three fired
--- immediately after a server round trip) have been passing `3` as a second
--- argument since they were written. This function took ONE parameter, so
--- Lua silently discarded it -- no error, no warning, and no retry. They
--- were asking for exactly this and getting a single check. Rather than
--- delete the argument and leave the real race unhandled, the behaviour they
--- were asking for is now implemented.
--- @param netId number
--- @param attempts number? -- how many checks to make, default 1 (no waiting)
--- @return number? entity
function ResolveNetworkEntity(netId, attempts)
    -- Deliberately NOT `attempts or 1`: in Lua that falls through for a
    -- legitimate 0 the same way it does for nil, and this codebase has been
    -- bitten by that pattern before. A non-number, or anything below 1, means
    -- "just check once".
    local tries = 1
    if type(attempts) == 'number' and attempts > 1 then
        tries = math.floor(attempts)
    end

    for attempt = 1, tries do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(entity) then return entity end
        end

        -- Only wait BETWEEN attempts, never after the last one -- a caller
        -- asking for one attempt must be exactly as synchronous as it always
        -- was, and a caller asking for three must not pay for a fourth wait
        -- it will never use.
        if attempt < tries then Wait(0) end
    end

    return nil -- not streamed in, deleted/recycled, or a bogus id
end

--- Resolves a targeted ped entity to the server id of the player it
--- belongs to, or nil if it isn't (currently) a real player's own ped.
--- CLIENT-SIDE ONLY — NetworkGetPlayerIndexFromPed + GetPlayerServerId is
--- the standard, well-established client-side combo for this.
--- server/entities.lua's own ResolveConnectedPlayerFromPed doc comment
--- flags this SAME native combo as unverified SERVER-side only; that
--- caveat does not apply to this client-side use.
---
--- DEVELOPER_REFERENCE.md item 2b. Extracted from two independent,
--- byte-identical hand-written copies of this exact function:
--- client/medkit.lua's "Treat K9" onSelect handler and
--- client/wellbeing.lua's "Pet K9"/"Feed K9" onSelect handlers. Both now
--- call this single function instead.
--- @param entity number
--- @return number? targetServerId
function ResolvePlayerServerIdFromPed(entity)
    local playerIndex = NetworkGetPlayerIndexFromPed(entity)
    if playerIndex == -1 then return nil end

    local targetServerId = GetPlayerServerId(playerIndex)
    if not targetServerId or targetServerId == 0 then return nil end

    return targetServerId
end

--- Resolves netId to a live, currently-streamed-in entity and plays
--- soundName from it via this resource's shared placeholder sound set.
--- This exact "resolve netId -> guard DoesEntityExist -> PlaySoundFromEntity"
--- sequence was previously duplicated between this file's playBark handler
--- and client/search.lua's contraband-alert handler; the resolve half is
--- now ResolveNetworkEntity() above (DEVELOPER_REFERENCE.md near-term item 2).
---
--- Two playback paths run back-to-back, not either/or: the original
--- PlaySoundFromEntity native call stays exactly as it was (a harmless
--- no-op today against this resource's placeholder K9_SOUND_SET, ready to
--- start doing something the moment an operator ships a real RAGE audio
--- bank under that soundset name — see BARK_SOUND_NAME's own comment
--- above), immediately followed by client/audio.lua's PlayK9Sound NUI
--- bridge, which is the one that can actually make sound today if an
--- operator has dropped a matching .ogg into html/sounds/ (see that
--- file's header). PlayK9Sound is guarded with a `type(...) == 'function'`
--- existence check rather than called unconditionally: client/audio.lua
--- returns without defining it at all when Config.Features.
--- BasicBarkSounds is false, so the global genuinely may not exist (same
--- runtime-existence-guard convention config.lua's globals comment already
--- documents for AwardXP/GetXPTier). soundName here is
--- always either BARK_SOUND_NAME or a Config.AdvancedBarkRadial-authored
--- entry from BarkTypeSoundNames below — never a raw caller-supplied
--- string — so this passes PlayK9Sound the exact same trusted,
--- table-lookup-only value already trusted to reach PlaySoundFromEntity,
--- and PlayK9Sound's own ToAudioFileKey() never turns that into anything
--- more than a lookup/best-effort-transform of that already-trusted
--- string, not an arbitrary filename from player input. If no matching
--- .ogg has been shipped (true for every default install today, per this
--- resource's html/sounds/CREDITS.md), client/audio.lua's own contract
--- guarantees this degrades to a silent, zero-console-output no-op end to
--- end, same as the native call it sits beside.
--- @param netId number
--- @param soundName string
function PlaySoundOnNetworkEntity(netId, soundName)
    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    PlaySoundFromEntity(-1, soundName, entity, K9_SOUND_SET, false, 0)

    if type(PlayK9Sound) == 'function' then
        PlayK9Sound(netId, soundName)
    end
end

--- Plays a bark on the K9 identified by netId, for any client that has it
--- streamed in (broadcast via TriggerClientEvent(..., -1, ...) from
--- server/main.lua's relayBark handler).
--- @param netId number
--- @param barkType string
RegisterNetEvent('qbx_k9unit:client:playBark', function(netId, barkType)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup; not re-derived here). Confidence: MEDIUM-HIGH, the official
    -- documented pattern for distinguishing a genuine server-sent event
    -- from a local self-trigger, not independently verified in-engine.
    -- Note this is NOT a feature-flag gate (this file's own header
    -- already establishes BasicBarkSounds/AdvancedBarkRadial are not the
    -- "ships false, must be inert" class this resource's other gates
    -- protect -- forging this just plays a placeholder sound on whatever
    -- entity the supplied netId resolves to, via the same
    -- ResolveNetworkEntity() guard every caller of PlaySoundOnNetworkEntity
    -- already goes through).
    if source ~= 65535 then return end

    -- `barkType` is an opaque passthrough string from server/main.lua's
    -- relayBark handler (untouched by this feature — it never validates or
    -- interprets barkType itself, only length-caps it). Phase 1's single
    -- literal ('bark', client/radial.lua's non-AdvancedBarkRadial Bark item)
    -- won't be in BarkTypeSoundNames, so it falls back to the one generic
    -- BARK_SOUND_NAME below, same behavior as before this feature existed.
    -- Phase 5's AdvancedBarkRadial variants (client/radial.lua's bark
    -- submenu) DO resolve to their own distinct entry via
    -- Config.AdvancedBarkRadial (config.lua) — still placeholder audio
    -- either way, see BarkTypeSoundNames' own comment above.
    local soundName = BarkTypeSoundNames[barkType] or BARK_SOUND_NAME
    PlaySoundOnNetworkEntity(netId, soundName)
end)
